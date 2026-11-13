//! Network access to `essence-rc daemon run --web --port 0` (П4): admission
//! by one-time code, script password and resume token, the message limit of
//! unauthorized connections (the in-flight limits are unit tests in
//! `daemon/conn.rs`), certificate pinning of `--connect` and the one-shot
//! CLI against a remote daemon.
mod common;

use std::time::{Duration, Instant};

use common::{BIN, Ctx, Daemon, Raw};
use serde_json::{Value, json};

const WAIT: Duration = Duration::from_secs(15);

/// Data and runtime directories of one test; the daemon (if any) is gone on drop.
struct Env {
    root: tempfile::TempDir,
    runtime: tempfile::TempDir,
}

impl Env {
    fn new() -> Self {
        Self { root: tempfile::tempdir().unwrap(), runtime: common::runtime_dir() }
    }

    fn ctx(&self) -> Ctx {
        let home = self.root.path().join("home");
        let tools = self.root.path().join("no-tools");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&tools).unwrap();
        Ctx {
            data: self.root.path().join("data"),
            runtime: self.runtime.path().to_path_buf(),
            vars: vec![("HOME".into(), home.into()), ("PATH".into(), tools.into())],
        }
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        common::stop(&self.ctx().endpoint());
    }
}

fn ok(reply: &Value) -> bool {
    reply["ok"] == json!(true)
}

fn code(reply: &Value) -> &str {
    reply["error"]["code"].as_str().unwrap_or("")
}

/// A local configuration, optionally with the script password `pw`.
fn configured(ctx: &Ctx, pw: Option<&str>) {
    let init = ctx.run(&["source", "init-local", "--json"], b"");
    assert_eq!(init.status.code(), Some(0), "{}", String::from_utf8_lossy(&init.stdout));
    if let Some(pw) = pw {
        let set = ctx.run(&["self", "password-set", "--secrets-stdin", "--json"], format!(r#"{{"password":"{pw}"}}"#).as_bytes());
        assert_eq!(set.status.code(), Some(0), "{}", String::from_utf8_lossy(&set.stdout));
    }
}

/// A daemon with a web listener on an OS-chosen port, and its `web status`.
fn networked(ctx: &Ctx, flags: &[&str]) -> (Daemon, Value) {
    let args: Vec<&str> = ["--web", "--port", "0"].iter().chain(flags).copied().collect();
    let mut daemon = Daemon::spawn_args(ctx, &args, &[]);
    let (_, status) = daemon.conn().request("web", &["web", "status"], json!({}));
    assert!(ok(&status) && status["data"]["enabled"] == true, "{status}");
    assert_ne!(status["data"]["port"], 0, "the actual port: {status}");
    (daemon, status["data"].clone())
}

/// A WebSocket connection with its `hello` checked.
fn network(web: &Value) -> Raw {
    let url = web["url"].as_str().unwrap().replacen("http://", "ws://", 1);
    let raw = Raw::websocket(&format!("{url}/ws")).expect("websocket");
    let hello = raw.hello(WAIT).expect("hello");
    assert_eq!((hello["origin"].as_str(), hello["protocol"].as_u64()), (Some("network"), Some(3)), "{hello}");
    assert_eq!(hello["listener"], json!({"loopback": true, "tls": false}));
    assert!(hello.get("exe").is_none(), "no executable path over the network: {hello}");
    raw
}

/// `session open` with `secrets`: its events and reply.
fn open(raw: &mut Raw, id: &str, secrets: Value) -> (Vec<Value>, Value) {
    raw.request(id, &["session", "open"], secrets)
}

fn resume_token(events: &[Value]) -> Option<String> {
    events.iter().find(|event| event["event"] == "access").and_then(|event| event["resume"].as_str()).map(str::to_owned)
}

fn ticket(link: &Value) -> String {
    let url = link["data"]["url"].as_str().unwrap();
    url.split_once("/#ticket=").unwrap_or_else(|| panic!("no code in {link}")).1.to_owned()
}

#[test]
fn a_loopback_panel_without_a_password_admits_by_code_then_by_resume_token() {
    let env = Env::new();
    let ctx = env.ctx();
    configured(&ctx, None);
    let (mut daemon, web) = networked(&ctx, &[]);
    assert_eq!((web["tls"].clone(), web["open"].clone(), web["clients"].clone()), (json!(false), json!(false), json!(0)));

    let mut first = network(&web);
    // Before authorization only help, session status and session open.
    assert_eq!(code(&first.request("list", &["node", "list"], json!({})).1), "session_closed");
    assert_eq!(code(&first.request("version", &["self", "version"], json!({})).1), "session_closed");
    assert_eq!(code(&first.request("stop", &["daemon", "stop"], json!({})).1), "local_only");
    assert_eq!(code(&first.request("link", &["web", "link"], json!({})).1), "local_only");
    assert_eq!(first.request("status", &["session", "status"], json!({})).1["data"]["authorized"], false);

    let (events, refused) = open(&mut first, "no-code", json!({}));
    assert_eq!((code(&refused), refused["error"]["secret"].as_str()), ("auth_required", Some("access-token")), "{refused}");
    assert!(resume_token(&events).is_none());

    let (_, link) = daemon.conn().request("link", &["web", "link"], json!({}));
    assert_eq!(link["data"]["expires_in"], 300, "{link}");
    let code_value = ticket(&link);
    assert_eq!(code_value.len(), 64);
    let (events, opened) = open(&mut first, "code", json!({"access-token": code_value}));
    assert!(ok(&opened), "{opened}");
    let resume = resume_token(&events).expect("an access event before the reply");
    assert_eq!(resume.len(), 64);
    assert!(ok(&first.request("groups", &["group", "list"], json!({})).1));
    let (_, status) = daemon.conn().request("web2", &["web", "status"], json!({}));
    assert_eq!(status["data"]["clients"], 1, "{status}");

    // The code is spent; the resume token admits a new connection.
    let mut second = network(&web);
    let (_, spent) = open(&mut second, "again", json!({"access-token": code_value}));
    assert_eq!((code(&spent), spent["error"]["secret"].as_str()), ("auth_failed", Some("access-token")), "{spent}");
    let (_, resumed) = open(&mut second, "resume", json!({"access-token": resume}));
    assert!(ok(&resumed), "{resumed}");
    assert!(ok(&second.request("groups", &["group", "list"], json!({})).1));
}

#[test]
fn the_password_admits_and_its_change_voids_resume_tokens() {
    let env = Env::new();
    let ctx = env.ctx();
    configured(&ctx, Some("pw"));
    let (mut daemon, web) = networked(&ctx, &[]);

    let mut remote = network(&web);
    let (_, wrong) = open(&mut remote, "wrong", json!({"script-password": "nope"}));
    assert_eq!((code(&wrong), wrong["error"]["secret"].as_str()), ("auth_failed", Some("script-password")), "{wrong}");
    // A code does not replace the password.
    let (_, link) = daemon.conn().request("link", &["web", "link"], json!({}));
    assert!(link["data"]["url"].as_str().unwrap().ends_with('/') && link["data"].get("expires_in").is_none(), "{link}");
    let (events, opened) = open(&mut remote, "right", json!({"script-password": "pw"}));
    assert!(ok(&opened), "{opened}");
    let resume = resume_token(&events).expect("access event");

    // The password changes on the local connection: the network one is reset
    // and the resume token is void.
    let local = daemon.conn();
    assert!(ok(&local.request("open", &["session", "open"], json!({"script-password": "pw"})).1));
    assert!(ok(&local.request("set", &["self", "password-set"], json!({"password": "pw2", "current-password": "pw"})).1));
    assert_eq!(code(&remote.request("groups", &["group", "list"], json!({})).1), "session_closed");
    let mut late = network(&web);
    let (_, void) = open(&mut late, "resume", json!({"access-token": resume}));
    assert_eq!(code(&void), "auth_failed", "{void}");
    assert!(ok(&open(&mut late, "new", json!({"script-password": "pw2"})).1));
}

#[test]
fn an_unauthorized_connection_is_closed_on_a_message_over_64_kib() {
    let env = Env::new();
    let ctx = env.ctx();
    configured(&ctx, Some("pw"));
    let (_daemon, web) = networked(&ctx, &[]);
    let big = "x".repeat(65 * 1024);

    let mut stranger = network(&web);
    stranger.send(&json!({"id": big, "argv": ["help"]}));
    assert!(stranger.closed(WAIT), "closed without an answer");

    // After authorization the 4 MiB protocol limit applies.
    let mut member = network(&web);
    assert!(ok(&open(&mut member, "open", json!({"script-password": "pw"})).1));
    let (_, help) = member.request(&big, &["help"], json!({}));
    assert!(ok(&help), "{help}");
}

#[test]
fn wrong_passwords_are_answered_one_after_another_with_growing_pauses() {
    // 7 attempts: pauses 0, 0, 0, 1, 2, 4, 8 s. (16 would wait 271 s, longer
    // than the 60 s an unauthorized connection may stay.)
    const ATTEMPTS: usize = 7;
    let env = Env::new();
    let ctx = env.ctx();
    configured(&ctx, Some("pw"));
    let (_daemon, web) = networked(&ctx, &[]);
    let started = Instant::now();
    let attempts: Vec<_> = (0..ATTEMPTS).map(|i| {
        let web = web.clone();
        std::thread::spawn(move || {
            let mut raw = network(&web);
            let (_, reply) = raw.request(&format!("wrong-{i}"), &["session", "open"], json!({"script-password": "bad"}));
            (code(&reply).to_owned(), started.elapsed())
        })
    }).collect();
    let mut finished: Vec<Duration> = attempts.into_iter().map(|attempt| {
        let (code, at) = attempt.join().unwrap();
        assert_eq!(code, "auth_failed");
        at
    }).collect();
    finished.sort();
    assert!(started.elapsed() >= Duration::from_secs(1 + 2 + 4 + 8), "pauses add up: {finished:?}");
    // The last answer waited for the 8 s pause after the 4 s one before it.
    assert!(finished[ATTEMPTS - 1] - finished[ATTEMPTS - 2] >= Duration::from_secs(7), "{finished:?}");
}

/// A one-shot CLI process against `url`; never touches the local endpoint.
fn remote_cli(ctx: &Ctx, args: &[&str], stdin: &[u8]) -> (Option<i32>, Value) {
    let mut command = ctx.command(BIN);
    command.args(args);
    let output = common::output(command, stdin, Duration::from_secs(60));
    let text = String::from_utf8_lossy(&output.stdout).into_owned();
    let value = serde_json::from_str(text.trim()).unwrap_or_else(|_| panic!("one JSON envelope: {text:?} / {}", String::from_utf8_lossy(&output.stderr)));
    (output.status.code(), value)
}

#[test]
fn the_one_shot_cli_works_against_a_remote_daemon() {
    let env = Env::new();
    let ctx = env.ctx();
    configured(&ctx, Some("pw"));
    let (_daemon, web) = networked(&ctx, &[]);
    let url = web["url"].as_str().unwrap();
    let secrets = br#"{"script-password":"pw"}"#;
    let (exit, groups) = remote_cli(&ctx, &["--connect", url, "group", "list", "--json", "--secrets-stdin"], secrets);
    assert_eq!(exit, Some(0), "{groups}");
    assert!(ok(&groups), "{groups}");
    let (exit, wrong) = remote_cli(&ctx, &["--connect", url, "group", "list", "--json", "--secrets-stdin"], br#"{"script-password":"bad"}"#);
    assert_eq!((exit, code(&wrong)), (Some(1), "auth_failed"), "{wrong}");
    // Commands a local daemon answers before authorization need it over the network.
    for words in [&["self", "version"][..], &["daemon", "status"], &["web", "status"]] {
        let argv: Vec<&str> = ["--connect", url].iter().chain(words).chain(&["--json", "--secrets-stdin"]).copied().collect();
        let (exit, reply) = remote_cli(&ctx, &argv, secrets);
        assert_eq!(exit, Some(0), "{words:?}: {reply}");
    }
    // Local-only commands stay local.
    let (_, stop) = remote_cli(&ctx, &["--connect", url, "daemon", "stop", "--json"], b"");
    assert_eq!(code(&stop), "local_only", "{stop}");
}

#[test]
fn certificates_are_confirmed_pinned_or_refused() {
    let env = Env::new();
    let ctx = env.ctx();
    configured(&ctx, Some("pw"));
    // Not loopback: a self-signed certificate in the data directory.
    let (_daemon, web) = networked(&ctx, &["--bind", "0.0.0.0"]);
    assert_eq!(web["tls"], true, "{web}");
    let fingerprint = web["fingerprint"].as_str().expect("fingerprint").to_owned();
    assert!(fingerprint.starts_with("SHA256:") && fingerprint.len() == 71, "{fingerprint}");
    let port = web["port"].as_u64().unwrap();
    let url = format!("https://127.0.0.1:{port}");

    let (exit, unknown) = remote_cli(&ctx, &["--connect", &url, "session", "status", "--json"], b"");
    assert_eq!((exit, code(&unknown)), (Some(2), "daemon_cert_unknown"), "{unknown}");
    assert_eq!(unknown["error"]["fingerprint"], fingerprint.as_str(), "the CLI shows the listener's fingerprint");

    let (exit, pinned) = remote_cli(&ctx, &["--connect", &url, "--fingerprint", &fingerprint, "session", "status", "--json"], b"");
    assert_eq!(exit, Some(0), "{pinned}");
    assert!(ok(&pinned));

    let other = format!("SHA256:{}", "0".repeat(64));
    std::fs::create_dir_all(&ctx.data).unwrap();
    std::fs::write(ctx.data.join("known-daemons.json"), json!({format!("127.0.0.1:{port}"): other}).to_string()).unwrap();
    let (exit, changed) = remote_cli(&ctx, &["--connect", &url, "session", "status", "--json"], b"");
    assert_eq!((exit, code(&changed)), (Some(1), "daemon_cert_changed"), "{changed}");
    assert_eq!(changed["error"]["fingerprint"], fingerprint.as_str());
}
