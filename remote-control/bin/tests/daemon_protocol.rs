//! Black-box protocol v3 of `essence-rc daemon run` over the local socket,
//! plus the one-shot CLI contract that runs through an on-demand daemon.
mod common;

#[cfg(unix)]
use std::{path::Path, process::Command};
use std::{
    thread,
    time::{Duration, Instant},
};

#[cfg(unix)]
use common::Raw;
use common::{BIN, Ctx, Daemon, lines};
use serde_json::{Value, json};

const VERSION: &str = include_str!("../../../VERSION");

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

    #[cfg(unix)]
    fn data(&self) -> std::path::PathBuf {
        self.root.path().join("data")
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

/// A local configuration with the script password `pw`.
fn configured(ctx: &Ctx, pw: &str) {
    let init = ctx.run(&["source", "init-local", "--json"], b"");
    assert_eq!(init.status.code(), Some(0), "{}", String::from_utf8_lossy(&init.stdout));
    let set = ctx.run(&["self", "password-set", "--secrets-stdin", "--json"], format!(r#"{{"password":"{pw}"}}"#).as_bytes());
    assert_eq!(set.status.code(), Some(0), "{}{}", String::from_utf8_lossy(&set.stdout), String::from_utf8_lossy(&set.stderr));
}

#[test]
fn hello_ordering_log_levels_usage_and_no_leaks() {
    let env = Env::new();
    let ctx = env.ctx();
    let daemon = Daemon::spawn(&ctx);
    assert_eq!(daemon.hello["event"], "hello");
    assert_eq!(daemon.hello["protocol"], 3);
    assert_eq!(daemon.hello["origin"], "local");
    assert_eq!(daemon.hello["version"], VERSION.trim());
    assert!(daemon.hello.get("listener").is_none(), "local hello has no listener: {}", daemon.hello);

    let secret = "do-not-echo-daemon-secret";
    let input = "do-not-echo-daemon-input";
    let mut conn = daemon.connect();
    let requests = [
        json!({"id": "first", "argv": ["session", "status"]}),
        json!({"id": 42, "argv": ["not-a-noun"], "secrets": {"password": secret}}),
        json!({"id": null, "argv": ["self", "not-a-verb"]}),
        json!({"id": "nul", "argv": ["self", "ver\u{0}sion"]}),
        json!({"id": "stdin", "argv": ["self", "version", "--secrets-stdin"]}),
        json!({"id": "input", "argv": ["session", "status"], "input": {"file": input}}),
        json!({"id": "big", "argv": ["template", "import", "--name", "t"], "input": {"file": "x".repeat((1 << 20) + 1)}}),
        json!({"id": "open", "argv": ["session", "open"]}),
    ];
    for request in &requests {
        conn.send(request);
    }
    conn.send_line("{malformed");
    conn.send(&json!({"id": [1], "argv": ["status"]}));
    let expected = [json!("first"), json!(42), Value::Null, json!("nul"), json!("stdin"), json!("input"), json!("big"), json!("open"), Value::Null, Value::Null];
    let mut replies = Vec::new();
    while replies.len() < expected.len() {
        let message = conn.next(Duration::from_secs(30)).expect("a reply for every request");
        if message.get("event").is_some() {
            assert_eq!(message["event"], "log", "{message}");
            assert!(["info", "success", "warn", "error", "output"].contains(&message["level"].as_str().unwrap()), "{message}");
            assert!(!message["text"].as_str().unwrap().chars().any(char::is_control), "{message}");
            continue;
        }
        assert!(message["ok"].is_boolean(), "{message}");
        replies.push(message);
    }
    let mut ids: Vec<Value> = replies.iter().map(|reply| reply["id"].clone()).collect();
    let mut sorted = expected.to_vec();
    ids.sort_by_key(Value::to_string);
    sorted.sort_by_key(Value::to_string);
    assert_eq!(ids, sorted, "exactly one reply per request");
    let by_id = |id: Value| replies.iter().find(|reply| reply["id"] == id).unwrap().clone();
    assert!(ok(&by_id(json!("first"))));
    for id in [json!(42), json!("nul"), json!("stdin"), json!("input")] {
        let reply = by_id(id.clone());
        assert_eq!((code(&reply), reply["exit"].clone()), ("usage", json!(2)), "{reply}");
    }
    assert_eq!(by_id(json!("stdin"))["error"]["message"], "Секреты передаются полем secrets.");
    assert_eq!(by_id(json!("input"))["error"]["message"], "Поле input не поддерживается командой.");
    assert_eq!(code(&by_id(json!("big"))), "invalid");
    let open = by_id(json!("open"));
    assert_eq!((code(&open), open["exit"].clone()), ("not_configured", json!(1)), "{open}");
    let nulls: Vec<&Value> = replies.iter().filter(|reply| reply["id"].is_null()).collect();
    assert_eq!(nulls.len(), 3);
    for reply in nulls {
        assert_eq!(code(reply), "usage", "{reply}");
    }
    let invalid = replies.iter().filter(|reply| reply["error"]["message"] == "Неверный запрос.").count();
    assert_eq!(invalid, 3, "malformed line, bad id and NUL in argv: {replies:?}");

    // Replies of one connection keep the order of its requests.
    let mut conn = daemon.connect();
    for index in 0..5 {
        conn.send(&json!({"id": index, "argv": ["session", "status"]}));
    }
    for index in 0..5 {
        assert_eq!(conn.reply(index, Duration::from_secs(30)).1["id"], index);
    }

    let journal = daemon.journal();
    let everything = format!("{journal}{replies:?}");
    assert!(!everything.contains(secret) && !everything.contains(input), "secret or input leaked");
}

#[test]
fn connections_authorize_separately_and_the_bypass_is_closed() {
    let env = Env::new();
    let ctx = env.ctx();
    configured(&ctx, "pw-one");
    let daemon = Daemon::spawn(&ctx);
    let mut first = daemon.connect();
    let (_, opened) = first.request("open", &["session", "open"], json!({"script-password": "pw-one"}));
    assert!(ok(&opened), "{opened}");
    assert!(ok(&first.request("groups", &["group", "list"], json!({})).1));

    // The core session is open, the second connection is not authorized.
    let mut second = daemon.connect();
    for (id, argv) in [("status", &["session", "status"][..]), ("daemon", &["daemon", "status"]), ("version", &["self", "version"]), ("help", &["help"])] {
        let (_, reply) = second.request(id, argv, json!({}));
        assert!(ok(&reply), "{argv:?} without authorization: {reply}");
        let (_, refused) = second.request(&format!("{id}-groups"), &["group", "list"], json!({}));
        assert_eq!(code(&refused), "session_closed", "after {argv:?}: {refused}");
    }
    let (_, status) = second.request("status2", &["session", "status"], json!({}));
    assert_eq!((status["data"]["open"].clone(), status["data"]["authorized"].clone()), (json!(true), json!(false)), "{status}");
    for (id, argv) in [
        ("nodes", &["node", "list"][..]), ("accounts", &["source", "github-accounts"]),
        ("replace", &["source", "github-replace-with-local", "--yes"]), ("generate", &["generate", "--all"]),
    ] {
        let (_, reply) = second.request(id, argv, json!({}));
        assert_eq!(code(&reply), "session_closed", "{argv:?}: {reply}");
    }
    second.send(&json!({"id": "shell", "argv": ["node", "shell", "--name", "ghost"], "terminal": {"term": "xterm", "cols": 80, "rows": 24}}));
    assert_eq!(code(&second.reply("shell", Duration::from_secs(30)).1), "session_closed");

    let (_, wrong) = second.request("wrong", &["session", "open"], json!({"script-password": "bad"}));
    assert_eq!((code(&wrong), wrong["error"]["secret"].clone()), ("auth_failed", json!("script-password")), "{wrong}");
    let (_, missing) = second.request("missing", &["session", "open"], json!({}));
    assert_eq!(code(&missing), "auth_required", "an open core session does not authorize: {missing}");
    let (_, right) = second.request("right", &["session", "open"], json!({"script-password": "pw-one"}));
    assert!(ok(&right), "{right}");
    assert!(ok(&second.request("groups", &["group", "list"], json!({})).1));
    let (_, status) = second.request("status3", &["session", "status"], json!({}));
    assert_eq!(status["data"]["authorized"], json!(true));

    // The first connection was never disturbed.
    assert!(ok(&first.request("groups2", &["group", "list"], json!({})).1));
}

/// Fresh data directory: the first connection is authorized without a
/// source (`not_configured`), sets a password; a new connection then needs it.
#[test]
fn an_open_absent_session_does_not_authorize_other_connections() {
    let env = Env::new();
    let ctx = env.ctx();
    let daemon = Daemon::spawn(&ctx);
    let mut first = daemon.connect();
    assert_eq!(code(&first.request("open", &["session", "open"], json!({})).1), "not_configured");
    assert!(ok(&first.request("init", &["source", "init-local"], json!({})).1));
    assert!(ok(&first.request("set", &["self", "password-set"], json!({"password": "pw"})).1));
    let mut second = daemon.connect();
    let (_, reply) = second.request("open", &["session", "open"], json!({}));
    assert_eq!((code(&reply), reply["error"]["secret"].clone()), ("auth_required", json!("script-password")), "{reply}");
    assert!(ok(&second.request("open2", &["session", "open"], json!({"script-password": "pw"})).1));
}

#[test]
fn terminal_requests_need_a_terminal_field_and_a_known_node() {
    let env = Env::new();
    let ctx = env.ctx();
    assert_eq!(ctx.run(&["source", "init-local", "--json"], b"").status.code(), Some(0));
    let daemon = Daemon::spawn(&ctx);
    let mut conn = daemon.connect();
    assert!(ok(&conn.request("open", &["session", "open"], json!({})).1));
    let (_, plain) = conn.request("plain", &["node", "shell", "--name", "ghost"], json!({}));
    assert_eq!((code(&plain), plain["error"]["message"].clone(), plain["exit"].clone()),
        ("tty_required", json!("Меню сервера требует терминала."), json!(2)), "{plain}");
    let (_, menu) = conn.request("menu", &["telegram", "menu", "--name", "ghost"], json!({}));
    assert_eq!(menu["error"]["message"], "Меню Telegram Proxy требует терминала.");
    conn.send(&json!({"id": "term", "argv": ["node", "shell", "--name", "ghost"], "terminal": {"term": "xterm", "cols": 80, "rows": 24}}));
    let (events, reply) = conn.reply("term", Duration::from_secs(30));
    assert_eq!(code(&reply), "not_found", "{reply}");
    assert!(events.iter().all(|event| event["event"] != "terminal"), "no terminal opens for an unknown node: {events:?}");
    let (_, status) = conn.request("daemon", &["daemon", "status"], json!({}));
    assert_eq!(status["data"]["terminals"], json!([]), "{status}");
}

/// The test process holds the real mutation lock, so a mutation waits in the
/// core (`RC_LOCK_WAIT` of the daemon) while other requests queue behind it.
#[cfg(unix)]
fn hold_mutation_lock(data: &Path) -> rc_core::locking::LockGuard {
    use rc_core::locking::{LockKind, LockManager};
    let locks = LockManager::new(data);
    locks.acquire_with_timeout(LockKind::Mutation, "test holds the lock", Duration::from_secs(5)).unwrap()
}

#[cfg(unix)]
/// Poll `daemon status` (no queue, no authorization needed) until `ready`
/// holds for its reply.
fn wait_status(probe: &mut Raw, what: &str, ready: impl Fn(&Value) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    for attempt in 0.. {
        let (_, status) = probe.request(&format!("probe-{attempt}"), &["daemon", "status"], json!({}));
        if ready(&status) {
            return;
        }
        assert!(Instant::now() < deadline, "not within 10 s: {what}; last {status}");
        thread::sleep(Duration::from_millis(20));
    }
}

#[cfg(unix)]
fn busy_with(label: &'static str) -> impl Fn(&Value) -> bool {
    move |status| status["data"]["busy"] == label
}

#[cfg(unix)]
#[test]
fn queued_requests_wait_and_a_password_change_resets_the_others() {
    let env = Env::new();
    let ctx = env.ctx();
    configured(&ctx, "q-one");
    let daemon = Daemon::spawn_with(&ctx, &[("RC_LOCK_WAIT", "30")]);
    let mut first = daemon.connect();
    let mut second = daemon.connect();
    let mut probe = daemon.connect();
    assert!(ok(&first.request("open", &["session", "open"], json!({"script-password": "q-one"})).1));
    assert!(ok(&second.request("open", &["session", "open"], json!({"script-password": "q-one"})).1));

    // A group mutation blocks on the held lock; the other connection queues.
    let guard = hold_mutation_lock(&env.data());
    first.send(&json!({"id": "slow", "argv": ["group", "add", "--name", "SLOW"]}));
    wait_status(&mut probe, "group add runs", busy_with("group add"));
    second.send(&json!({"id": "queued", "argv": ["group", "list"]}));
    let wait = second.next(Duration::from_secs(10)).expect("a waiting event");
    assert_eq!((wait["id"].clone(), wait["event"].clone(), wait["level"].clone()), (json!("queued"), json!("log"), json!("info")), "{wait}");
    assert_eq!(wait["text"], "Ожидание: выполняется «group add».");
    assert!(second.next(Duration::from_millis(800)).is_none(), "no reply before the lock is released");
    drop(guard);
    assert!(ok(&first.reply("slow", Duration::from_secs(40)).1));
    let (_, listed) = second.reply("queued", Duration::from_secs(40));
    assert!(listed["data"].as_array().unwrap().iter().any(|group| group["name"] == "SLOW"), "{listed}");

    // A job queued behind a password change of another connection is refused.
    let guard = hold_mutation_lock(&env.data());
    first.send(&json!({"id": "pw", "argv": ["self", "password-set"], "secrets": {"password": "q-two", "current-password": "q-one"}}));
    wait_status(&mut probe, "password-set runs", busy_with("self password-set"));
    second.send(&json!({"id": "after", "argv": ["group", "list"]}));
    let wait = second.next(Duration::from_secs(10)).expect("queued behind the password change");
    assert_eq!((wait["id"].clone(), wait["event"].clone()), (json!("after"), json!("log")), "{wait}");
    drop(guard);
    assert!(ok(&first.reply("pw", Duration::from_secs(40)).1));
    assert_eq!(code(&second.reply("after", Duration::from_secs(40)).1), "session_closed");
    assert!(ok(&first.request("still", &["group", "list"], json!({})).1), "the requester keeps its authorization");
}

#[cfg(unix)]
#[test]
fn daemon_stop_answers_queued_requests_and_exits_cleanly() {
    let env = Env::new();
    let ctx = env.ctx();
    assert_eq!(ctx.run(&["source", "init-local", "--json"], b"").status.code(), Some(0));
    let mut daemon = Daemon::spawn_with(&ctx, &[("RC_LOCK_WAIT", "30")]);
    let mut first = daemon.connect();
    let mut second = daemon.connect();
    let mut third = daemon.connect();
    let mut probe = daemon.connect();
    assert!(ok(&first.request("open", &["session", "open"], json!({})).1));
    assert!(ok(&second.request("open", &["session", "open"], json!({})).1));
    let guard = hold_mutation_lock(&env.data());
    first.send(&json!({"id": "slow", "argv": ["group", "add", "--name", "SLOW"]}));
    wait_status(&mut probe, "group add runs", busy_with("group add"));
    second.send(&json!({"id": "queued", "argv": ["group", "list"]}));
    let wait = second.next(Duration::from_secs(10)).expect("the queued request waits");
    assert_eq!((wait["id"].clone(), wait["event"].clone()), (json!("queued"), json!("log")), "{wait}");
    third.send(&json!({"id": "stop", "argv": ["daemon", "stop"]}));
    wait_status(&mut probe, "the stop began", |status| code(status) == "daemon_stopping");
    let (_, late) = second.request("late", &["session", "status"], json!({}));
    assert_eq!(code(&late), "daemon_stopping", "a new request during the stop: {late}");
    drop(guard);
    // The queued job is answered without running; the executing one completes.
    let (_, refused) = second.reply("queued", Duration::from_secs(40));
    assert_eq!((code(&refused), refused["error"]["message"].clone(), refused["exit"].clone()),
        ("daemon_stopping", json!("Демон останавливается. Повторите команду."), json!(1)), "{refused}");
    assert!(ok(&first.reply("slow", Duration::from_secs(40)).1), "the executing request completes");
    let (_, stopped) = third.reply("stop", Duration::from_secs(40));
    assert_eq!(stopped["data"], json!({"stopping": true}), "{stopped}");
    let status = daemon.wait_exit(Duration::from_secs(20)).expect("the daemon exits");
    assert_eq!(status.code(), Some(0));
    assert!(!daemon.endpoint.socket.exists(), "the socket is removed");
    assert!(first.closed(Duration::from_secs(5)) && second.closed(Duration::from_secs(5)));
}

#[test]
fn daemon_stop_exits_zero_and_removes_the_endpoint() {
    let env = Env::new();
    let ctx = env.ctx();
    let mut daemon = Daemon::spawn(&ctx);
    let (_, stopped) = daemon.conn().request("stop", &["daemon", "stop"], json!({}));
    assert_eq!(stopped["data"], json!({"stopping": true}));
    let status = daemon.wait_exit(Duration::from_secs(20)).expect("the daemon exits");
    assert_eq!(status.code(), Some(0));
    assert!(common::wait_gone(&daemon.endpoint, Duration::from_secs(5)));
}

#[test]
fn an_idle_on_demand_daemon_exits_after_the_last_client() {
    let env = Env::new();
    let ctx = env.ctx();
    let mut daemon = Daemon::spawn_with(&ctx, &[("ESSENCE_RC_DAEMON_LINGER", "1")]);
    let extra = daemon.connect();
    daemon.disconnect();
    thread::sleep(Duration::from_millis(1500));
    assert!(daemon.child.try_wait().unwrap().is_none(), "a connected client keeps the daemon");
    let started = Instant::now();
    extra.close();
    let status = daemon.wait_exit(Duration::from_secs(15)).expect("the idle daemon exits");
    assert_eq!(status.code(), Some(0));
    assert!(started.elapsed() >= Duration::from_millis(900), "the linger time is honoured");
    assert!(common::wait_gone(&daemon.endpoint, Duration::from_secs(5)));
}

/// Eight one-shot commands at once on an empty runtime directory: all succeed
/// and exactly one daemon serves the endpoint.
#[test]
fn parallel_one_shot_commands_share_one_daemon() {
    let env = Env::new();
    let ctx = env.ctx();
    let children: Vec<_> = (0..8).map(|_| {
        let ctx = ctx.clone();
        thread::spawn(move || {
            let mut command = ctx.command(BIN);
            command.args(["status", "--json"]).env("ESSENCE_RC_DAEMON_LINGER", "30");
            common::output(command, b"", Duration::from_secs(90))
        })
    }).collect();
    for child in children {
        let output = child.join().unwrap();
        assert_eq!(output.status.code(), Some(0), "{}{}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
        assert_eq!(lines(&output.stdout)[0]["ok"], true);
    }
    let mut command = ctx.command(BIN);
    command.args(["daemon", "status", "--json"]).env("ESSENCE_RC_DAEMON_LINGER", "30");
    let status = lines(&common::output(command, b"", Duration::from_secs(30)).stdout)[0].clone();
    let pid = status["data"]["pid"].as_u64().expect("daemon pid");
    assert!(pid > 0, "{status}");
    #[cfg(target_os = "linux")]
    {
        // Losers of the start race exit; the lock holder is the only daemon left.
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let daemons = daemons_of(&ctx.runtime);
            if daemons == [pid] { break; }
            assert!(Instant::now() < deadline, "daemons of this endpoint: {daemons:?}, serving {pid}");
            thread::sleep(Duration::from_millis(100));
        }
    }
    common::stop(&ctx.endpoint());
}

/// `essence-rc daemon run` processes whose environment names `runtime`.
#[cfg(target_os = "linux")]
fn daemons_of(runtime: &Path) -> Vec<u64> {
    let marker = format!("ESSENCE_RC_RUNTIME_DIR={}", runtime.display());
    let mut pids = Vec::new();
    for entry in std::fs::read_dir("/proc").unwrap().flatten() {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<u64>() else { continue };
        let Ok(cmdline) = std::fs::read(entry.path().join("cmdline")) else { continue };
        let args: Vec<&[u8]> = cmdline.split(|byte| *byte == 0).collect();
        if !(args.len() >= 3 && args[1] == b"daemon" && args[2] == b"run") { continue; }
        let Ok(environ) = std::fs::read(entry.path().join("environ")) else { continue };
        if environ.split(|byte| *byte == 0).any(|var| var == marker.as_bytes()) {
            pids.push(pid);
        }
    }
    pids
}

/// П12, Windows: the detached daemon must not inherit the CLI's stdout, so
/// a reader of a one-shot command gets EOF when the command exits, not when
/// the daemon (lingering 30 s) does.
#[cfg(windows)]
#[test]
fn one_shot_stdout_reaches_eof_before_the_daemon_exits() {
    use std::io::Read as _;
    use std::process::Stdio;
    let env = Env::new();
    let ctx = env.ctx();
    let mut command = ctx.command(BIN);
    command.args(["status", "--json"]).env("ESSENCE_RC_DAEMON_LINGER", "30")
        .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    let mut child = command.spawn().unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let (sender, receiver) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let mut text = String::new();
        let _ = stdout.read_to_string(&mut text);
        let _ = sender.send(text);
    });
    let text = receiver.recv_timeout(Duration::from_secs(20)).expect("stdout reaches EOF long before the daemon's linger ends");
    assert_eq!(lines(text.as_bytes())[0]["ok"], true, "{text}");
    assert!(child.wait().unwrap().success());
    assert!(common::alive(&ctx.endpoint()), "the daemon is still lingering");
}

// ─── One-shot CLI through the daemon ─────────────────────────────────────────

#[test]
fn cli_exit_codes_and_plan_token_without_yes() {
    let env = Env::new();
    let ctx = env.ctx();
    let version = ctx.run(&["self", "version", "--json"], b"");
    assert_eq!(version.status.code(), Some(0), "{}{}", String::from_utf8_lossy(&version.stdout), String::from_utf8_lossy(&version.stderr));
    let version_lines = lines(&version.stdout);
    assert_eq!(version_lines.len(), 1);
    assert_eq!(version_lines[0]["ok"], true);
    assert!(version_lines[0].get("exit").is_none(), "exit is never printed: {}", version_lines[0]);

    // stdin "y" must not confirm anything; --plan-token without --yes is usage.
    for args in [vec!["unknown-noun", "--json"], vec!["self", "unknown-verb", "--json"], vec!["self", "version", "--plan-token", "wrong", "--json"]] {
        let output = ctx.run(&args, b"y\n");
        assert_eq!(output.status.code(), Some(2), "{args:?}: {}", String::from_utf8_lossy(&output.stderr));
        let output = lines(&output.stdout);
        assert_eq!(output.len(), 1);
        assert_eq!(output[0]["ok"], false);
        assert_eq!(output[0]["error"]["code"], "usage");
    }
}

#[test]
fn confirmation_lifecycle_and_secrets_stdin_pipe() {
    let env = Env::new();
    let ctx = env.ctx();
    assert_eq!(ctx.run(&["source", "init-local", "--json"], b"").status.code(), Some(0));
    // Set a script password via --secrets-stdin (pipe, so no /dev/tty prompt).
    let set = ctx.run(&["self", "password-set", "--secrets-stdin", "--json"], br#"{"password":"pass-one","current-password":""}"#);
    assert_eq!(set.status.code(), Some(0), "{}", String::from_utf8_lossy(&set.stderr));
    let set = lines(&set.stdout);
    assert_eq!(set.len(), 1);
    assert_eq!(set[0]["ok"], true);

    // Once a password exists every protected one-shot command needs the
    // session secret; an empty new password is then rejected by command
    // semantics, not by the decoder.
    let empty = ctx.run(&["self", "password-set", "--secrets-stdin", "--json"],
        br#"{"password":"","current-password":"pass-one","script-password":"pass-one"}"#);
    assert_eq!(empty.status.code(), Some(1));
    let empty = lines(&empty.stdout);
    assert_eq!(empty.len(), 1);
    assert_eq!(empty[0]["error"]["code"], "invalid");

    // Removal is a mutating command: exact plan first, token then consent.
    let planned = ctx.run(&["self", "password-remove", "--secrets-stdin", "--json"],
        br#"{"current-password":"pass-one","script-password":"pass-one"}"#);
    assert_eq!(planned.status.code(), Some(2));
    let planned_lines = lines(&planned.stdout);
    assert_eq!(planned_lines.len(), 1, "exactly one envelope");
    assert_eq!(planned_lines[0]["error"]["code"], "confirmation_required");
    assert_eq!(planned_lines[0]["error"]["plan"],
        json!(["Пароль запуска remote-control будет удалён.", "Локальные данные и SSH-ключи сохранятся."]));
    let token = planned_lines[0]["error"]["plan_token"].as_str().expect("plan token").to_string();
    assert_eq!(token.len(), 16);
    assert!(token.chars().all(|c| c.is_ascii_hexdigit()));

    let wrong = ctx.run(&["self", "password-remove", "--secrets-stdin", "--yes", "--plan-token", "0000000000000000", "--json"],
        br#"{"current-password":"pass-one","script-password":"pass-one"}"#);
    assert_eq!(wrong.status.code(), Some(2));
    assert_eq!(lines(&wrong.stdout)[0]["error"]["code"], "plan_changed");

    let right = ctx.run(&["self", "password-remove", "--secrets-stdin", "--yes", "--plan-token", &token, "--json"],
        br#"{"current-password":"pass-one","script-password":"pass-one"}"#);
    assert_eq!(right.status.code(), Some(0), "{}", String::from_utf8_lossy(&right.stderr));
    assert_eq!(lines(&right.stdout)[0]["ok"], true);

    // Re-set the password (no current-password required once removed), then a
    // stale current-password must fail authentication.
    let reset = ctx.run(&["self", "password-set", "--secrets-stdin", "--json"], br#"{"password":"pass-two"}"#);
    assert_eq!(reset.status.code(), Some(0), "{}", String::from_utf8_lossy(&reset.stderr));
    let stale = ctx.run(&["self", "password-remove", "--secrets-stdin", "--json"],
        br#"{"current-password":"pass-one","script-password":"pass-two"}"#);
    let stale_lines = lines(&stale.stdout);
    assert_eq!(stale_lines.len(), 1);
    assert_eq!(stale_lines[0]["error"]["code"], "auth_failed");
}

/// SIGTERM/SIGHUP while the console is in raw mode: the terminal must come
/// back in cooked mode and the process must exit with 128+signal. The child
/// runs on a real pseudo-terminal (libc `openpty`, the child's controlling
/// terminal via `setsid` + `TIOCSCTTY`); the raw console is the hidden
/// script-password prompt of a one-shot `status`, observed through the
/// slave's termios (`ICANON`/`ECHO`, the flags `stty -g` would print).
#[cfg(unix)]
#[test]
fn termination_signals_restore_the_raw_console() {
    use std::os::unix::process::CommandExt as _;
    for (signal, name) in [(libc::SIGTERM, "SIGTERM"), (libc::SIGHUP, "SIGHUP")] {
        let env = Env::new();
        let ctx = env.ctx();
        configured(&ctx, "tty-pass");

        let (mut master, mut slave) = (0, 0);
        // `*mut` coerces to the `*const` Linux signature and matches macOS's `*mut`.
        assert_eq!(unsafe { libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut()) }, 0);
        let slave_path = unsafe { std::ffi::CStr::from_ptr(libc::ptsname(master)) }.to_owned();
        let lflag = |fd| {
            let mut termios: libc::termios = unsafe { std::mem::zeroed() };
            assert_eq!(unsafe { libc::tcgetattr(fd, &mut termios) }, 0);
            termios.c_lflag
        };
        let cooked = lflag(slave);
        assert!(cooked & libc::ICANON != 0 && cooked & libc::ECHO != 0, "a fresh pty starts cooked");
        let stdio = |fd: i32| unsafe { std::process::Stdio::from_raw_fd_dup(fd) };
        let mut child: Command = ctx.command(BIN);
        child.arg("status").stdin(stdio(slave)).stdout(stdio(slave)).stderr(stdio(slave));
        unsafe {
            child.pre_exec(move || {
                if libc::setsid() < 0 || libc::ioctl(slave, libc::TIOCSCTTY as _, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let spawned = child.spawn().unwrap();
        // The Command keeps its own copies of the slave fds; close them so the
        // master reaches EOF once the child exits.
        drop(child);
        let mut child = spawned;
        // Drain the pty so the prompt never blocks on a full buffer.
        let drain = thread::spawn(move || {
            let mut buffer = [0u8; 1024];
            while unsafe { libc::read(master, buffer.as_mut_ptr().cast(), buffer.len()) } > 0 {}
        });
        let deadline = Instant::now() + Duration::from_secs(20);
        while lflag(slave) & libc::ICANON != 0 {
            assert!(Instant::now() < deadline, "{name}: the hidden prompt never entered raw mode");
            assert!(child.try_wait().unwrap().is_none(), "{name}: exited before the prompt");
            thread::sleep(Duration::from_millis(20));
        }
        unsafe { libc::kill(child.id() as i32, signal) };
        let status = child.wait().unwrap();
        assert_eq!(status.code(), Some(128 + signal), "{name}: conventional exit code");
        // macOS revokes the session leader's terminal when it exits, so the
        // held slave fd is dead; a fresh open sees the same pty's termios.
        let fresh = unsafe { libc::open(slave_path.as_ptr(), libc::O_RDWR | libc::O_NOCTTY) };
        assert!(fresh >= 0, "{name}: reopen the pty slave");
        let restored = lflag(fresh);
        unsafe { libc::close(fresh) };
        assert!(restored & libc::ICANON != 0 && restored & libc::ECHO != 0, "{name}: terminal left in raw mode");
        unsafe { libc::close(slave) };
        let _ = drain.join();
        unsafe { libc::close(master) };
        ctx.settle();
    }
}

#[cfg(unix)]
trait FromRawFdDup {
    /// A Stdio owning a duplicate of `fd` (the test keeps its own copy).
    unsafe fn from_raw_fd_dup(fd: i32) -> std::process::Stdio;
}

#[cfg(unix)]
impl FromRawFdDup for std::process::Stdio {
    unsafe fn from_raw_fd_dup(fd: i32) -> std::process::Stdio {
        use std::os::fd::FromRawFd as _;
        unsafe { std::process::Stdio::from_raw_fd(libc::dup(fd)) }
    }
}
