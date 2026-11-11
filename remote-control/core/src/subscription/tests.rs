//! Subscription commands against scripted remote hosts (`FakeTransport`) and a
//! loopback HTTP endpoint for the post-publication check.

use std::cell::RefCell;
use std::collections::VecDeque;

use serde_json::{json, Value};

use super::remote::{self, CONF_COMMAND, SNIPPETS_DIR};
use super::*;
use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeScript, FakeTransport, Operation, ScriptStep};
use crate::log::Level;
use crate::model::{Auth, Fingerprint, Group, Node, Subscription, SubscriptionHost};
use crate::nodes::testing::{self, Journal, fingerprint, invocation};
use crate::nodes::{COMMAND_TIMEOUT, CONNECT_TIMEOUT, pin};
use crate::transport::{ExecResult, HostKeyPolicy};

const OLD_DIR: &str = "/srv/old-sub";
const NEW_DIR: &str = "/srv/new-sub";

fn alpha_token() -> String { "a1".repeat(32) }
fn orphan_token() -> String { "c".repeat(64) }

fn fp(byte: u8) -> Fingerprint {
    use base64::Engine;
    format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode([byte; 32])).parse().unwrap()
}

fn node(index: u8, name: &str) -> Node {
    Node {
        id: format!("{index:032x}"), name: name.into(), ip: format!("192.0.2.{index}"), port: 22, user: "root".into(),
        auth: Auth::Key, identity: Some("system".into()), secret_id: None, tag: None, aliases: Default::default(),
    }
}

/// Nodes `old` (host) and `new`; client `alpha` published with a TTL and its
/// own header, `beta` unpublished; both have generated configs.
fn fixture(root: &std::path::Path, base_url: &str) -> (Session, Journal) {
    let (session, journal) = testing::session(root);
    let nodes = vec![node(1, "old"), node(2, "new")];
    for node in &nodes {
        pin(&session.state, &node.ip, node.port, vec![fp(node.id.as_bytes()[31])]).unwrap();
    }
    let mut config = Config::default();
    config.nodes = nodes;
    config.clients = vec![
        Client { name: "alpha".into(), group: "MOBILE".into(), subscription: Some(Subscription {
            token: Some(alpha_token()), created_at: Some("2026-01-01T00:00:00Z".into()),
            expires_at: Some("2030-01-01T00:00:00Z".into()),
            headers: Some(vec![SubscriptionHeader { name: "User-Agent".into(), value: "test".into() }]),
        }), ..Client::default() },
        Client { name: "beta".into(), group: "MOBILE".into(), ..Client::default() },
    ];
    config.subscription_host = Some(SubscriptionHost {
        node: "old".into(), base_url: base_url.into(), sub_dir: "/stale/cache".into(), nginx_group: "www-data".into(),
    });
    config.subscription_default_headers = Some(Vec::new());
    session.state.save_config(&config).unwrap();
    for client in ["alpha", "beta"] {
        let dir = root.join("generated/MOBILE").join(client);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("config.yaml"), "proxies: []\n").unwrap();
    }
    (session, journal)
}

fn connect_step(index: u8) -> ScriptStep {
    let node = node(index, "x");
    ScriptStep::connect(ConnectExpectation::new(node.ip, 22, "root", AuthMethod::System, CONNECT_TIMEOUT)
        .with_host_key(HostKeyPolicy { expected: None, known: vec![fp(node.id.as_bytes()[31])] }), Ok(()))
}

fn exec_ok(command: String, stdin_len: usize, stdout: &str) -> ScriptStep {
    ScriptStep::exec(command, stdin_len, COMMAND_TIMEOUT,
        Ok(ExecResult { stdout: stdout.as_bytes().to_vec(), stderr: Vec::new(), exit_status: 0 }))
}

fn exec_status(command: String, stdin_len: usize, stdout: &str, status: u32) -> ScriptStep {
    ScriptStep::exec(command, stdin_len, COMMAND_TIMEOUT,
        Ok(ExecResult { stdout: stdout.as_bytes().to_vec(), stderr: b"nginx: [emerg] secret path".to_vec(), exit_status: status }))
}

fn conf_step(dir: &str, base_url: &str) -> ScriptStep {
    exec_ok(CONF_COMMAND.into(), 0, &format!("SUB_HOSTNAME=h\nSUB_BASE_URL={base_url}\nSUB_DIR={dir}\nNGINX_GROUP=www-data\n"))
}

/// Upload of `count` subscriptions: YAML, snippets, then the apply script
/// with the tag and the tokens in stdin.
fn upload_steps(dir: &str, count: usize, apply_status: u32) -> Vec<ScriptStep> {
    let mut steps = vec![
        ScriptStep::upload_any_local(dir, COMMAND_TIMEOUT, Ok(())),
        ScriptStep::upload_any_local(SNIPPETS_DIR, COMMAND_TIMEOUT, Ok(())),
        exec_status(remote::apply_command(dir, "www-data"), 17 + 65 * count, "", apply_status),
    ];
    if apply_status != 0 {
        steps.push(exec_ok(remote::cleanup_command(dir), 17, ""));
    }
    steps
}

/// Transports handed out in order; each keeps its own script.
struct Hosts {
    queue: RefCell<VecDeque<FakeTransport>>,
    scripts: Vec<FakeScript>,
}

impl Hosts {
    fn new(transports: Vec<Vec<ScriptStep>>) -> Self {
        let transports: Vec<FakeTransport> = transports.into_iter().map(FakeTransport::new).collect();
        let scripts = transports.iter().map(FakeTransport::script).collect();
        Self { queue: RefCell::new(transports.into()), scripts }
    }

    fn connect(&self) -> FakeTransport {
        self.queue.borrow_mut().pop_front().expect("unexpected connection")
    }

    /// Every script consumed, nothing unexpected, no token in any command.
    fn finish(&self, tokens: &[&str]) {
        assert!(self.queue.borrow().is_empty(), "unused transports");
        for script in &self.scripts {
            script.assert_finished();
            for operation in script.journal() {
                if let Operation::Exec { command, .. } = operation {
                    assert!(tokens.iter().all(|token| !command.contains(token)), "token in a remote command");
                }
            }
        }
    }
}

async fn run(session: &mut Session, hosts: &Hosts, argv: &[&str]) -> Result<Value> {
    let invocation = invocation(argv);
    route("subscription", &invocation.verb.clone(), &invocation, &Secrets::default(), session, &|| hosts.connect()).await
}

/// Loopback endpoint answering every request with `code`.
async fn http(code: u16) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let mut buffer = [0u8; 4096];
            let _ = tokio::io::AsyncReadExt::read(&mut stream, &mut buffer).await;
            let response = format!("HTTP/1.1 {code} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            let _ = tokio::io::AsyncWriteExt::write_all(&mut stream, response.as_bytes()).await;
        }
    });
    format!("http://{address}")
}

fn config(session: &Session) -> Config {
    session.state.load_config().unwrap()
}

fn client<'a>(config: &'a Config, name: &str) -> &'a Client {
    config.clients.iter().find(|client| client.name == name).unwrap()
}

fn warned(journal: &Journal, text: &str) -> bool {
    journal.borrow().iter().any(|(level, line)| *level == Level::Warn && line == text)
}

// ─── Pure rules ──────────────────────────────────────────────────────────────

#[test]
fn snippet_headers_ttl_and_time_follow_v1() {
    let mut config = Config::default();
    let group = Group { name: "PC".into(), subscription_headers: Some(vec![
        SubscriptionHeader { name: "profile-update-interval".into(), value: "12".into() },
        SubscriptionHeader { name: "X-Group".into(), value: "it's".into() },
    ]), ..Group::default() };
    config.groups = vec![group];
    let client = Client { name: "c".into(), group: "PC".into(), subscription: Some(Subscription {
        headers: Some(vec![SubscriptionHeader { name: "X-Group".into(), value: "C:\\new".into() }]), ..Subscription::default()
    }), ..Client::default() };
    let annotated: Vec<(String, &str)> = annotated_headers(&config, &client).into_iter()
        .map(|(header, source)| (format!("{}={}", header.name, header.value), source)).collect();
    assert_eq!(annotated, [
        ("Content-Disposition=attachment; filename=\"config.yaml\"".to_owned(), "default"),
        ("X-Group=C:\\new".to_owned(), "client"),
        ("profile-update-interval=12".to_owned(), "group"),
    ]);
    let token = alpha_token();
    let snippet = render_snippet(&token, "/var/lib/essence-sub", &effective_headers(&config, &client));
    assert_eq!(snippet, format!("location = /sub/{token} {{\n    alias /var/lib/essence-sub/{token}.yaml;\n    \
        default_type application/yaml;\n    add_header Cache-Control \"no-store\" always;\n    \
        add_header X-Content-Type-Options nosniff always;\n    \
        add_header Content-Disposition 'attachment; filename=\"config.yaml\"' always;\n    \
        add_header X-Group 'C:\\\\new' always;\n    add_header profile-update-interval '12' always;\n    \
        limit_req zone=sub burst=5 nodelay;\n}}\n"));
    assert_eq!(nginx_quote("it's \"q\" \\"), "\"it's \\\"q\\\" \\\\\"");

    assert!(validate_header("X-Ok", "v").is_ok());
    for (name, value) in [("bad name", "v"), ("X", "a\nb"), ("X", "a\r"), ("X", "a\\"), ("X", "a$b")] {
        assert!(validate_header(name, value).is_err(), "{name:?}={value:?}");
    }

    assert_eq!(ttl_expiry("12h", 100), Some(100 + 12 * 3600));
    assert_eq!(ttl_expiry("30d", 0), Some(30 * 86_400));
    assert_eq!(ttl_expiry("2w", 0), Some(2 * 604_800));
    for bad in ["", "h", "1m", "0d", "01d", "1234567d", "-1d", "1.5d", "d1", "30д", "д"] {
        assert_eq!(ttl_expiry(bad, 0), None, "{bad}");
    }
    assert_eq!(iso(0), "1970-01-01T00:00:00Z");
    assert_eq!(iso(2_000_000_000), "2033-05-18T03:33:20Z");
    assert_eq!(parse_iso("2033-05-18T03:33:20Z"), Some(2_000_000_000));
    assert_eq!(parse_iso("2033-05-18T06:33:20+03:00"), Some(2_000_000_000));
    assert_eq!(parse_iso("2033-05-18T00:03:20-0330"), Some(2_000_000_000));
    assert_eq!(parse_iso("2024-02-29T00:00:00Z"), Some(1_709_164_800));
    for bad in ["2023-02-29T00:00:00Z", "2030-13-01T00:00:00Z", "2030-01-01 00:00:00Z", "2030-01-01T00:00:00", "2030-01-01T00:00:00+3"] {
        assert_eq!(parse_iso(bad), None, "{bad}");
    }
    assert_eq!(remote::HostConf::parse("SUB_DIR=/a/b\r\nSUB_BASE_URL=https://h:2096\nX=1\n").sub_dir(), Some("/a/b"));
    assert_eq!(remote::HostConf::parse("SUB_DIR=/a/../b\n").sub_dir(), None);
}

// ─── host / list / show / headers ────────────────────────────────────────────

#[tokio::test(flavor = "current_thread")]
async fn host_requires_migration_with_published_tokens_and_reads_the_node() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, journal) = fixture(root.path(), "https://old.example");
    let before = fingerprint(root.path());
    let none = Hosts::new(vec![]);
    let error = run(&mut session, &none, &["subscription", "host", "--name", "new"]).await.unwrap_err();
    assert_eq!((error.code, error.message.as_str()),
        ("conflict", "Есть опубликованные подписки. Для смены хост-ноды используйте subscription migrate --name new."));
    assert_eq!(fingerprint(root.path()), before);
    assert_eq!(run(&mut session, &none, &["subscription", "host"]).await.unwrap()["node"], "old");

    // Not installed: not_installed, nothing written.
    let hosts = Hosts::new(vec![vec![connect_step(1), exec_status(CONF_COMMAND.into(), 0, "", 3)]]);
    let error = run(&mut session, &hosts, &["subscription", "host", "--name", "old"]).await.unwrap_err();
    hosts.finish(&[]);
    assert_eq!((error.code, error.message.as_str()), ("not_installed", "На ноде «old» не установлен хостинг подписок."));
    assert_eq!(fingerprint(root.path()), before);

    // Same host: refreshes the cached settings from the node.
    let hosts = Hosts::new(vec![vec![connect_step(1), conf_step(OLD_DIR, "https://fresh.example")]]);
    let data = run(&mut session, &hosts, &["subscription", "host", "--name", "old"]).await.unwrap();
    hosts.finish(&[]);
    assert_eq!(data, json!({"node": "old", "base_url": "https://fresh.example", "sub_dir": OLD_DIR, "nginx_group": "www-data"}));
    assert_eq!(journal.borrow().last().unwrap().1, "Хост-нода подписок: old (https://fresh.example)");

    // Without published tokens the host may change.
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.clients.iter_mut().for_each(|client| client.subscription = None);
        state.save_config(&config)
    }).unwrap();
    let hosts = Hosts::new(vec![vec![connect_step(2), conf_step(NEW_DIR, "https://new.example")]]);
    run(&mut session, &hosts, &["subscription", "host", "--name", "new"]).await.unwrap();
    hosts.finish(&[]);
    assert_eq!(config(&session).subscription_host.unwrap().node, "new");
    let error = run(&mut session, &none, &["subscription", "host", "--name", "ghost"]).await.unwrap_err();
    assert_eq!(error.code, "not_found");
}

#[tokio::test(flavor = "current_thread")]
async fn list_hides_links_and_show_exposes_them() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _) = fixture(root.path(), "https://old.example");
    let none = Hosts::new(vec![]);
    let list = run(&mut session, &none, &["subscription", "list"]).await.unwrap();
    assert_eq!(list, json!([{"client": "alpha", "expires_at": "2030-01-01T00:00:00Z", "state": "active"}]));
    assert!(!list.to_string().contains(&alpha_token()));
    let show = run(&mut session, &none, &["subscription", "show", "--name", "alpha"]).await.unwrap();
    assert_eq!(show, json!({"client": "alpha", "url": format!("https://old.example/sub/{}", alpha_token()),
        "expires_at": "2030-01-01T00:00:00Z", "headers": [{"name": "User-Agent", "value": "test"}]}));
    let error = run(&mut session, &none, &["subscription", "show", "--name", "beta"]).await.unwrap_err();
    assert_eq!((error.code, error.message.as_str()), ("invalid", "У клиента «beta» нет подписки."));
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.subscription_host = None;
        state.save_config(&config)
    }).unwrap();
    for argv in [&["subscription", "show", "--name", "alpha"][..], &["subscription", "publish-all"][..],
        &["subscription", "publish", "--name", "alpha"][..], &["subscription", "migrate", "--name", "new"][..]] {
        let error = run(&mut session, &none, argv).await.unwrap_err();
        assert_eq!((error.code, error.message.as_str()),
            ("not_configured", "Хост-нода подписок не задана: subscription host --name NAME."), "{argv:?}");
    }
    none.finish(&[]);
}

#[tokio::test(flavor = "current_thread")]
async fn headers_validate_every_pair_before_one_write() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _) = fixture(root.path(), "https://old.example");
    let none = Hosts::new(vec![]);
    let data = run(&mut session, &none, &["subscription", "headers", "--client", "alpha", "--set", "X-Test=a=b",
        "--set", "User-Agent=new", "--unset", "Missing"]).await.unwrap();
    assert_eq!(data, json!({"target": {"kind": "client", "name": "alpha"}, "headers": [
        {"name": "User-Agent", "value": "new", "source": "client"}, {"name": "X-Test", "value": "a=b", "source": "client"}]}));
    run(&mut session, &none, &["subscription", "headers", "--client", "alpha", "--unset", "X-Test"]).await.unwrap();
    assert_eq!(client(&config(&session), "alpha").subscription.as_ref().unwrap().headers.as_ref().unwrap().len(), 1);

    let before = fingerprint(root.path());
    for (argv, code) in [
        (&["subscription", "headers", "--group", "MOBILE", "--set", "X-A=1", "--set", "Invalid Header=v"][..], "invalid"),
        (&["subscription", "headers", "--client", "alpha", "--set", "X-A=$host"][..], "invalid"),
        (&["subscription", "headers", "--client", "alpha", "--set", "X-A=ends\\"][..], "invalid"),
        (&["subscription", "headers", "--client", "alpha", "--set", "novalue"][..], "usage"),
        (&["subscription", "headers", "--client", "alpha", "--set", "X-A="][..], "usage"),
        (&["subscription", "headers", "--default", "--set", "X-A=b"][..], "usage"),
        (&["subscription", "headers", "--client", "alpha", "--group", "PC"][..], "usage"),
        (&["subscription", "headers", "--group", "NOPE", "--set", "X-A=b"][..], "not_found"),
        (&["subscription", "headers", "--client", "ghost"][..], "not_found"),
    ] {
        assert_eq!(run(&mut session, &none, argv).await.unwrap_err().code, code, "{argv:?}");
    }
    assert_eq!(fingerprint(root.path()), before);

    run(&mut session, &none, &["subscription", "headers", "--group", "MOBILE", "--set", "X-Group=value"]).await.unwrap();
    let saved = config(&session);
    let group = saved.groups.iter().find(|group| group.name == "MOBILE").unwrap();
    assert_eq!(group.subscription_headers.as_ref().unwrap()[0].name, "X-Group");

    // Built-in defaults are shown without being written.
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.subscription_default_headers = None;
        state.save_config(&config)
    }).unwrap();
    let before = fingerprint(root.path());
    let defaults = run(&mut session, &none, &["subscription", "headers", "--default"]).await.unwrap();
    assert_eq!(defaults, json!([{"name": "Content-Disposition", "value": "attachment; filename=\"config.yaml\""},
        {"name": "profile-update-interval", "value": "24"}]));
    let annotated = run(&mut session, &none, &["subscription", "headers", "--client", "alpha"]).await.unwrap();
    assert_eq!(annotated.as_array().unwrap().iter().filter(|h| h["source"] == "default").count(), 2);
    assert_eq!(fingerprint(root.path()), before);
}

// ─── publish ─────────────────────────────────────────────────────────────────

#[tokio::test(flavor = "current_thread")]
async fn publish_uploads_then_saves_token_ttl_and_verifies_the_link() {
    let root = tempfile::tempdir().unwrap();
    let base = http(200).await;
    let (mut session, journal) = fixture(root.path(), &base);
    let mut steps = vec![connect_step(1), conf_step(OLD_DIR, &base)];
    steps.extend(upload_steps(OLD_DIR, 1, 0));
    steps.push(exec_ok(remote::expiry_command(OLD_DIR), 76, ""));
    let hosts = Hosts::new(vec![steps]);
    let started = now();
    let data = run(&mut session, &hosts, &["subscription", "publish", "--name", "beta", "--ttl", "30d"]).await.unwrap();
    let saved = config(&session);
    let subscription = client(&saved, "beta").subscription.clone().unwrap();
    let token = subscription.token.clone().unwrap();
    hosts.finish(&[&token]);
    assert!(subscription_token_valid(&token));
    let expires = parse_iso(subscription.expires_at.as_deref().unwrap()).unwrap();
    assert!((started + 30 * 86_400..=now() + 30 * 86_400).contains(&expires));
    assert!(parse_iso(subscription.created_at.as_deref().unwrap()).is_some());
    assert_eq!(data, json!({"client": "beta", "url": format!("{base}/sub/{token}"), "expires_at": subscription.expires_at}));
    assert!(journal.borrow().iter().all(|(_, line)| !line.contains(&token)));
    assert_eq!(saved.subscription_default_headers, Some(Vec::new()));

    // Republishing without a TTL keeps the token, expiry and creation time.
    let mut steps = vec![connect_step(1), conf_step(OLD_DIR, &base)];
    steps.extend(upload_steps(OLD_DIR, 1, 0));
    let hosts = Hosts::new(vec![steps]);
    let data = run(&mut session, &hosts, &["subscription", "publish", "--name", "beta"]).await.unwrap();
    hosts.finish(&[&token]);
    assert_eq!(client(&config(&session), "beta").subscription.as_ref().unwrap(), &subscription);
    assert_eq!(data["expires_at"], json!(subscription.expires_at));
}

#[tokio::test(flavor = "current_thread")]
async fn publish_failures_keep_local_state() {
    let root = tempfile::tempdir().unwrap();
    let base = http(200).await;
    let (mut session, journal) = fixture(root.path(), &base);
    let before = fingerprint(root.path());

    // Snippet upload fails: temporary files are removed, nothing is saved.
    let hosts = Hosts::new(vec![vec![connect_step(1), conf_step(OLD_DIR, &base),
        ScriptStep::upload_any_local(OLD_DIR, COMMAND_TIMEOUT, Ok(())),
        ScriptStep::upload_any_local(SNIPPETS_DIR, COMMAND_TIMEOUT, Err(RcError::new("remote_failed", "x"))),
        exec_ok(remote::cleanup_command(OLD_DIR), 17, "")]]);
    let error = run(&mut session, &hosts, &["subscription", "publish", "--name", "alpha"]).await.unwrap_err();
    hosts.finish(&[&alpha_token()]);
    assert_eq!((error.code, error.message.as_str()), ("remote_failed", "Ошибка загрузки файла на сервер."));
    assert!(warned(&journal, "Не удалось загрузить фрагмент конфигурации для alpha."));
    assert_eq!(fingerprint(root.path()), before);

    // nginx rejects the snippet.
    let mut steps = vec![connect_step(1), conf_step(OLD_DIR, &base)];
    steps.extend(upload_steps(OLD_DIR, 1, 1));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["subscription", "publish", "--name", "beta"]).await.unwrap_err();
    hosts.finish(&[]);
    assert_eq!(error.code, "remote_failed");
    assert!(warned(&journal, "Не удалось применить конфигурацию для beta (проверка nginx, права или перезагрузка)."));
    assert_eq!(fingerprint(root.path()), before);

    // A new subscription whose expiry cannot be written is removed again.
    let mut steps = vec![connect_step(1), conf_step(OLD_DIR, &base)];
    steps.extend(upload_steps(OLD_DIR, 1, 0));
    steps.push(exec_status(remote::expiry_command(OLD_DIR), 76, "", 1));
    steps.push(exec_ok(remote::remove_command(OLD_DIR), 66, "removed\n"));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["subscription", "publish", "--name", "beta", "--ttl", "12h"]).await.unwrap_err();
    hosts.finish(&[]);
    assert_eq!(error.message, "Срок подписки не записан на хост-ноде; загруженная подписка удалена. Локальные данные не изменены.");
    assert_eq!(fingerprint(root.path()), before);

    // Local checks precede any connection.
    let none = Hosts::new(vec![]);
    for (argv, code) in [
        (&["subscription", "publish", "--name", "alpha", "--ttl", "1m"][..], "invalid"),
        (&["subscription", "publish", "--name", "ghost"][..], "not_found"),
        (&["subscription", "publish"][..], "usage"),
    ] {
        assert_eq!(run(&mut session, &none, argv).await.unwrap_err().code, code, "{argv:?}");
    }
    std::fs::write(root.path().join("generated/MOBILE/alpha/config.yaml"), " \n\t\n").unwrap();
    let error = run(&mut session, &none, &["subscription", "publish", "--name", "alpha"]).await.unwrap_err();
    assert_eq!((error.code, error.message.as_str()), ("needs_setup",
        "Конфиг для «alpha» не найден или пуст. Сгенерируйте его: generate --client alpha."));
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.clients[1].subscription = Some(Subscription { headers: Some(vec![
            SubscriptionHeader { name: "Bad Name".into(), value: "v".into() }]), ..Subscription::default() });
        state.save_config(&config)
    }).unwrap();
    let error = run(&mut session, &none, &["subscription", "publish", "--name", "beta"]).await.unwrap_err();
    assert_eq!(error.code, "invalid");
    none.finish(&[]);
}

#[tokio::test(flavor = "current_thread")]
async fn failed_http_check_after_saving_is_partial_with_the_link() {
    let root = tempfile::tempdir().unwrap();
    let base = http(502).await;
    let (mut session, _) = fixture(root.path(), &base);
    let mut steps = vec![connect_step(1), conf_step(OLD_DIR, &base)];
    steps.extend(upload_steps(OLD_DIR, 1, 0));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["subscription", "publish", "--name", "beta"]).await.unwrap_err();
    let token = client(&config(&session), "beta").subscription.as_ref().unwrap().token.clone().unwrap();
    hosts.finish(&[&token]);
    assert_eq!((error.code, error.message.as_str()), ("partial",
        "Подписка сохранена, но проверка HTTP: 502 (ожидалось 200). Проверьте журнал ошибок nginx на сервере."));
    assert_eq!(error.extra["url"], json!(format!("{base}/sub/{token}")));
    assert_eq!(error.extra["expires_at"], Value::Null);
}

#[test]
fn certificate_failures_are_told_apart_from_missing_answers() {
    use std::io::{Error, ErrorKind};
    let untrusted = Error::new(ErrorKind::InvalidData, "invalid peer certificate: UnknownIssuer");
    assert!(remote::certificate_rejected(Some(&untrusted)));
    assert!(remote::certificate_rejected(Some(&Error::other("peer sent no certificates"))));
    assert!(!remote::certificate_rejected(Some(&Error::new(ErrorKind::ConnectionRefused, "connection refused"))));
    assert!(!remote::certificate_rejected(None));
}

// ─── rotate / revoke ─────────────────────────────────────────────────────────

#[tokio::test(flavor = "current_thread")]
async fn rotate_and_revoke_without_yes_change_nothing() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _) = fixture(root.path(), "https://old.example");
    let before = fingerprint(root.path());
    let none = Hosts::new(vec![]);
    let error = run(&mut session, &none, &["subscription", "rotate", "--name", "alpha"]).await.unwrap_err();
    assert_eq!(error.code, "confirmation_required");
    assert_eq!(error.extra["plan"], json!(["Клиент: alpha", "Хост-нода: old",
        "Старая ссылка перестанет работать; новая ссылка будет показана после завершения."]));
    assert!(!serde_json::to_string(&error).unwrap().contains(&alpha_token()));
    let error = run(&mut session, &none, &["subscription", "revoke", "--name", "alpha"]).await.unwrap_err();
    assert_eq!(error.code, "confirmation_required");
    assert_eq!(error.extra["plan"], json!(["Клиент: alpha", "Хост-нода: old", "Ссылка перестанет работать; конфиг клиента сохранится."]));
    for verb in ["rotate", "revoke"] {
        let error = run(&mut session, &none, &["subscription", verb, "--name", "beta", "--yes"]).await.unwrap_err();
        assert_eq!((error.code, error.message.as_str()), ("invalid", "У клиента «beta» нет подписки."));
    }
    none.finish(&[]);
    assert_eq!(fingerprint(root.path()), before);
}

#[tokio::test(flavor = "current_thread")]
async fn rotate_replaces_the_link_or_restores_the_old_one() {
    let root = tempfile::tempdir().unwrap();
    let base = http(200).await;
    let (mut session, journal) = fixture(root.path(), &base);
    let before = fingerprint(root.path());
    let old = alpha_token();

    // Old link removal rolls back: the new copy is removed, local data unchanged.
    let mut steps = vec![connect_step(1), conf_step(OLD_DIR, &base)];
    steps.extend(upload_steps(OLD_DIR, 1, 0));
    steps.push(exec_status(remote::remove_command(OLD_DIR), 130, "restored\n", 1));
    steps.push(exec_ok(remote::remove_command(OLD_DIR), 66, "removed\n"));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["subscription", "rotate", "--name", "alpha", "--yes"]).await.unwrap_err();
    hosts.finish(&[&old]);
    assert_eq!((error.code, error.message.as_str()),
        ("remote_failed", "Смена токена не завершена: удаление старой ссылки не подтверждено."));
    assert_eq!(fingerprint(root.path()), before);

    // An uncertain rollback keeps the replacement on the host.
    let mut steps = vec![connect_step(1), conf_step(OLD_DIR, &base)];
    steps.extend(upload_steps(OLD_DIR, 1, 0));
    steps.push(exec_status(remote::remove_command(OLD_DIR), 130, "uncertain:uncertain:restored:restored\n", 1));
    let hosts = Hosts::new(vec![steps]);
    run(&mut session, &hosts, &["subscription", "rotate", "--name", "alpha", "--yes"]).await.unwrap_err();
    hosts.finish(&[&old]);
    assert!(warned(&journal, "Восстановление подписки: файлы — не подтверждены; срок — восстановлен; nginx — применён. \
        Резервная копия сохранена в каталоге подписок."));
    assert_eq!(fingerprint(root.path()), before);

    let mut steps = vec![connect_step(1), conf_step(OLD_DIR, &base)];
    steps.extend(upload_steps(OLD_DIR, 1, 0));
    steps.push(exec_ok(remote::remove_command(OLD_DIR), 130, "removed\n"));
    let hosts = Hosts::new(vec![steps]);
    let data = run(&mut session, &hosts, &["subscription", "rotate", "--name", "alpha", "--yes"]).await.unwrap();
    let saved = client(&config(&session), "alpha").subscription.clone().unwrap();
    let token = saved.token.unwrap();
    hosts.finish(&[&old, &token]);
    assert!(subscription_token_valid(&token) && token != old);
    assert_eq!(data, json!({"client": "alpha", "url": format!("{base}/sub/{token}")}));
    assert_eq!((saved.expires_at.as_deref(), saved.headers.unwrap()[0].value.as_str()), (Some("2030-01-01T00:00:00Z"), "test"));
}

#[tokio::test(flavor = "current_thread")]
async fn revoke_removes_the_link_before_dropping_the_token() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, journal) = fixture(root.path(), "https://old.example");
    let before = fingerprint(root.path());
    let token = alpha_token();
    let hosts = Hosts::new(vec![vec![connect_step(1), conf_step(OLD_DIR, "https://old.example"),
        exec_status(remote::remove_command(OLD_DIR), 66, "unchanged\n", 1)]]);
    let error = run(&mut session, &hosts, &["subscription", "revoke", "--name", "alpha", "--yes"]).await.unwrap_err();
    hosts.finish(&[&token]);
    assert_eq!((error.code, error.message.as_str()),
        ("remote_failed", "Подписка «alpha» не отозвана: ссылка может оставаться действующей."));
    assert_eq!(fingerprint(root.path()), before);

    // Unreachable host: warned, the connection error is kept for the caller.
    let hosts = Hosts::new(vec![vec![ScriptStep::connect(ConnectExpectation::new("192.0.2.1", 22, "root", AuthMethod::System,
        CONNECT_TIMEOUT).with_host_key(HostKeyPolicy { expected: None, known: vec![fp(node(1, "old").id.as_bytes()[31])] }),
        Err(RcError::new("remote_failed", "x")))]]);
    let error = revoke_quiet(&mut session, "alpha", &|| hosts.connect()).await.unwrap_err();
    hosts.finish(&[]);
    assert_eq!(error.code, "remote_failed");
    assert!(warned(&journal, "Подписка «alpha» не отозвана: ссылка может оставаться действующей."));
    assert_eq!(fingerprint(root.path()), before);

    let hosts = Hosts::new(vec![vec![connect_step(1), conf_step(OLD_DIR, "https://old.example"),
        exec_ok(remote::remove_command(OLD_DIR), 66, "removed\n")]]);
    let data = run(&mut session, &hosts, &["subscription", "revoke", "--name", "alpha", "--yes"]).await.unwrap();
    hosts.finish(&[&token]);
    assert_eq!(data, json!({"client": "alpha"}));
    let saved = client(&config(&session), "alpha").subscription.clone().unwrap();
    assert_eq!((saved.token, saved.created_at, saved.expires_at), (None, None, None));
    assert_eq!(saved.headers.unwrap()[0].name, "User-Agent");
    // Without a token there is nothing to revoke remotely.
    revoke_quiet(&mut session, "alpha", &|| Hosts::new(vec![]).connect()).await.unwrap();
}

// ─── publish-all ─────────────────────────────────────────────────────────────

#[tokio::test(flavor = "current_thread")]
async fn publish_all_plans_orphans_and_reports_partial_sweep() {
    let root = tempfile::tempdir().unwrap();
    let base = "https://old.example";
    let (mut session, journal) = fixture(root.path(), base);
    let before = fingerprint(root.path());
    let (alpha, orphan) = (alpha_token(), orphan_token());
    let listing = format!("{alpha}\n{orphan}\nnot-a-token\n");
    let plan_steps = || vec![connect_step(1), conf_step(OLD_DIR, base),
        exec_ok(remote::list_command(OLD_DIR), 0, &listing)];

    let hosts = Hosts::new(vec![plan_steps()]);
    let error = run(&mut session, &hosts, &["subscription", "publish-all"]).await.unwrap_err();
    hosts.finish(&[]);
    assert_eq!(error.code, "confirmation_required");
    assert_eq!(error.extra["plan"], json!(["Хост-нода: old", "Будут опубликованы (2):", " alpha", " beta",
        "Подписки без клиента в конфигурации будут удалены с хоста (1):", " cccccccc…", "nginx на хост-ноде будет перезагружен."]));
    assert!(!serde_json::to_string(&error).unwrap().contains(&orphan));
    assert_eq!(fingerprint(root.path()), before);

    // Batch rejected by nginx: nothing saved, every target failed.
    let mut steps = plan_steps();
    steps.extend(upload_steps(OLD_DIR, 2, 1));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["subscription", "publish-all", "--yes"]).await.unwrap_err();
    hosts.finish(&[&alpha, &orphan]);
    assert_eq!((error.code, error.message.as_str()), ("remote_failed", "Подписки не опубликованы: ошибка загрузки на хост-ноду."));
    assert_eq!((error.extra["published"].clone(), error.extra["failed"].clone()), (json!([]), json!(["alpha", "beta"])));
    assert_eq!(fingerprint(root.path()), before);

    // Published, but the planned sweep fails.
    let mut steps = plan_steps();
    steps.extend(upload_steps(OLD_DIR, 2, 0));
    steps.push(exec_status(remote::prune_command(OLD_DIR), 65, "0 1\n", 1));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["subscription", "publish-all", "--yes"]).await.unwrap_err();
    let beta = client(&config(&session), "beta").subscription.clone().unwrap();
    hosts.finish(&[&alpha, &orphan, beta.token.as_deref().unwrap()]);
    assert_eq!((error.code, error.message.as_str()),
        ("partial", "Подписки опубликованы, но не все подписки без клиента удалены с хост-ноды."));
    assert_eq!(error.extra["published"], json!(["alpha", "beta"]));
    assert_eq!(error.extra["removed"], json!(0));
    assert!(subscription_token_valid(beta.token.as_deref().unwrap()) && beta.expires_at.is_none());
    assert!(journal.borrow().iter().any(|(level, line)| *level == Level::Success && line == "Опубликовано: 2"));
    assert_eq!(client(&config(&session), "alpha").subscription.as_ref().unwrap().token.as_deref(), Some(alpha.as_str()));
}

#[tokio::test(flavor = "current_thread")]
async fn publish_all_refuses_to_sweep_without_local_tokens_and_skips_without_configs() {
    let root = tempfile::tempdir().unwrap();
    let base = "https://old.example";
    let (mut session, _) = fixture(root.path(), base);
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.clients[0].subscription = None;
        state.save_config(&config)
    }).unwrap();
    let before = fingerprint(root.path());
    let hosts = Hosts::new(vec![vec![connect_step(1), conf_step(OLD_DIR, base),
        exec_ok(remote::list_command(OLD_DIR), 0, &format!("{}\n", orphan_token()))]]);
    let error = run(&mut session, &hosts, &["subscription", "publish-all", "--yes"]).await.unwrap_err();
    hosts.finish(&[]);
    assert_eq!(error.code, "failed");
    assert_eq!(fingerprint(root.path()), before);

    std::fs::remove_dir_all(root.path().join("generated")).unwrap();
    let data = run(&mut session, &Hosts::new(vec![]), &["subscription", "publish-all"]).await.unwrap();
    assert_eq!(data, json!({"published": [], "skipped": ["alpha", "beta"], "failed": [], "removed": 0}));
}

// ─── migrate ─────────────────────────────────────────────────────────────────

#[tokio::test(flavor = "current_thread")]
async fn migrate_plans_copies_switches_and_then_removes_old_links() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, journal) = fixture(root.path(), "https://old.example");
    let before = fingerprint(root.path());
    let token = alpha_token();
    let prepare = || (vec![connect_step(1), conf_step(OLD_DIR, "https://old.example")],
        vec![connect_step(2), conf_step(NEW_DIR, "https://new.example")]);

    let (old, new) = prepare();
    let hosts = Hosts::new(vec![old, new]);
    let error = run(&mut session, &hosts, &["subscription", "migrate", "--name", "new"]).await.unwrap_err();
    hosts.finish(&[]);
    assert_eq!(error.code, "confirmation_required");
    assert_eq!(error.extra["plan"], json!(["Старая хост-нода: old", "Базовый URL: https://old.example",
        "Новая хост-нода: new", "Базовый URL: https://new.example", "alpha",
        "Все адреса подписок изменятся.", "Старые ссылки будут удалены только после загрузки всех подписок."]));
    assert_eq!(fingerprint(root.path()), before);

    // Upload failure on the new node: old host and links untouched.
    let (old, mut new) = prepare();
    new.push(exec_ok(remote::expiry_command(NEW_DIR), 76, ""));
    new.extend(upload_steps(NEW_DIR, 1, 1));
    let hosts = Hosts::new(vec![old, new]);
    let error = run(&mut session, &hosts, &["subscription", "migrate", "--name", "new", "--yes"]).await.unwrap_err();
    hosts.finish(&[&token]);
    assert_eq!((error.code, error.message.as_str()), ("remote_failed", "На новой ноде могли остаться копии подписок."));
    assert!(warned(&journal, "Перенос не завершён: старый хост и старые ссылки сохранены."));
    assert_eq!(fingerprint(root.path()), before);

    // Local refusals before any connection.
    let none = Hosts::new(vec![]);
    let error = run(&mut session, &none, &["subscription", "migrate", "--name", "old", "--yes"]).await.unwrap_err();
    assert_eq!((error.code, error.message.as_str()), ("invalid", "Выбрана текущая хост-нода. Перенос не выполнен."));
    std::fs::write(root.path().join("generated/MOBILE/alpha/config.yaml"), "\n").unwrap();
    let error = run(&mut session, &none, &["subscription", "migrate", "--name", "new", "--yes"]).await.unwrap_err();
    assert_eq!((error.code, error.message.as_str()), ("needs_setup",
        "alpha: конфиг отсутствует или пуст. Перенос отменён. Сгенерируйте его: generate --client alpha."));
    std::fs::write(root.path().join("generated/MOBILE/alpha/config.yaml"), "proxies: []\n").unwrap();
    none.finish(&[]);
    assert_eq!(fingerprint(root.path()), before);

    // Success: expiry and copies first, host switch, old links removed (one fails → partial).
    let (mut old, mut new) = prepare();
    new.push(exec_ok(remote::expiry_command(NEW_DIR), 76, ""));
    new.extend(upload_steps(NEW_DIR, 1, 0));
    old.push(exec_status(remote::remove_command(OLD_DIR), 66, "restored\n", 1));
    let hosts = Hosts::new(vec![old, new]);
    let error = run(&mut session, &hosts, &["subscription", "migrate", "--name", "new", "--yes"]).await.unwrap_err();
    hosts.finish(&[&token]);
    assert_eq!(error.code, "partial");
    assert_eq!((error.extra["node"].clone(), error.extra["migrated"].clone()), (json!("new"), json!(1)));
    let saved = config(&session);
    assert_eq!(saved.subscription_host, Some(SubscriptionHost { node: "new".into(), base_url: "https://new.example".into(),
        sub_dir: NEW_DIR.into(), nginx_group: "www-data".into() }));
    assert_eq!(client(&saved, "alpha").subscription.as_ref().unwrap().token.as_deref(), Some(token.as_str()));

    // Nothing published: no work, no connection.
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.clients[0].subscription = None;
        state.save_config(&config)
    }).unwrap();
    let data = run(&mut session, &none, &["subscription", "migrate", "--name", "old"]).await.unwrap();
    assert_eq!(data, json!({"node": "old", "base_url": null, "migrated": 0}));
}
