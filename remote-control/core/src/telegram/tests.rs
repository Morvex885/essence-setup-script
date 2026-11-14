//! `telegram *`: role records, secrets, link and the remote commands.

use std::cell::RefCell;
use std::collections::VecDeque;

use super::*;
use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeScript, FakeTransport, ScriptStep};
use crate::model::{Auth, Fingerprint, test_profile};
use crate::nodes::testing::{Journal, fingerprint, invocation, session};
use crate::nodes::{CONNECT_TIMEOUT, pin};
use crate::transport::{ExecResult, HostKeyPolicy};
use status::Ipv6;
use status::tests::{FakeReach, HEALTHY};

const NODES: [(&str, &str); 2] = [("de", "203.0.113.7"), ("nl", "203.0.113.8")];

fn pin_fp() -> Fingerprint {
    format!("SHA256:{}", "A".repeat(43)).parse().unwrap()
}

/// Nodes `de` and `nl` with profile `main`; `bare` without one.
fn fixture(root: &std::path::Path) -> (Session, Journal) {
    let (session, journal) = session(root);
    let mut config = session.state.load_config().unwrap();
    config.profiles = vec![test_profile("main")];
    config.nodes = NODES.iter().enumerate().map(|(index, (name, ip))| Node {
        id: format!("{index:032x}"), name: (*name).into(), ip: (*ip).into(), port: 22, user: "root".into(), auth: Auth::Key,
        profile: Some("main".into()), domain: Some(format!("{name}.example.com")), ..Node::default()
    }).collect();
    config.nodes.push(Node { id: "f".repeat(32), name: "bare".into(), ip: "203.0.113.9".into(), port: 22, user: "root".into(),
        auth: Auth::Key, ..Node::default() });
    crate::server::keys::ensure_generated(&session.state, &mut config).unwrap();
    session.state.save_config(&config).unwrap();
    for (_, ip) in NODES {
        pin(&session.state, ip, 22, vec![pin_fp()]).unwrap();
    }
    (session, journal)
}

fn run(session: &mut Session, argv: &[&str], secrets: &Secrets) -> Result<Value> {
    run_with(session, argv, secrets, &|| panic!("no connection expected"))
}

fn run_with(session: &mut Session, argv: &[&str], secrets: &Secrets, connect: &dyn Fn() -> FakeTransport) -> Result<Value> {
    let invocation = invocation(argv);
    tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap()
        .block_on(route("telegram", &invocation.verb.clone(), &invocation, secrets, session, connect))
}

fn none() -> Secrets {
    Secrets::default()
}

fn stored(session: &Session, suffix: &str) -> Option<String> {
    session.state.secret_store().get(&format!("node:{:032x}:{suffix}", 0)).unwrap().map(|secret| secret.to_string())
}

#[test]
fn set_link_rotate_tag_and_remove() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _) = fixture(root.path());
    let before = fingerprint(root.path());
    for (argv, code) in [
        (&["telegram", "set", "--name", "de"][..], "usage"),
        (&["telegram", "set", "--name", "bare", "--domain", "tg.example.com"], "invalid"),
        (&["telegram", "set", "--name", "de", "--domain", "bad domain"], "invalid"),
        (&["telegram", "set", "--name", "de", "--domain", "de.example.com"], "invalid"),
        (&["telegram", "set", "--name", "ghost", "--domain", "tg.example.com"], "not_found"),
        (&["telegram", "link", "--name", "de"], "not_found"),
        (&["telegram", "rotate-secret", "--name", "de", "--yes"], "not_found"),
    ] {
        assert_eq!(run(&mut session, argv, &none()).unwrap_err().code, code, "{argv:?}");
    }
    assert_eq!(fingerprint(root.path()), before);

    let data = run(&mut session, &["telegram", "set", "--name", "de", "--domain", "tg.example.com"], &none()).unwrap();
    assert_eq!(data, json!({"node": "de", "hostname": "tg.example.com", "tag": false}));
    let secret = stored(&session, "telegram-secret").unwrap();
    assert!(telegram_hex_valid(&secret) && secret == secret.to_ascii_lowercase());
    let config = session.state.load_config().unwrap();
    assert_eq!(crate::server::render::status(&config, &config.nodes[0]), "pending");
    assert_eq!(run(&mut session, &["telegram", "link", "--name", "de"], &none()).unwrap(),
        json!({"link": format!("tg://webproxy?server=tg.example.com&port=443&secret={secret}")}));
    assert_eq!(run(&mut session, &["telegram", "set", "--name", "nl", "--domain", "tg.example.com"], &none()).unwrap_err().code, "invalid",
        "one hostname per proxy");

    // A domain change keeps the secret.
    run(&mut session, &["telegram", "set", "--name", "de", "--domain", "tg2.example.com"], &none()).unwrap();
    assert_eq!(stored(&session, "telegram-secret").unwrap(), secret);

    let before = fingerprint(root.path());
    let error = run(&mut session, &["telegram", "rotate-secret", "--name", "de"], &none()).unwrap_err();
    assert_eq!((error.code, error.extra["plan"].clone()), ("confirmation_required",
        json!(["Секрет будет заменён: прежние ссылки перестанут работать."])));
    assert_eq!(fingerprint(root.path()), before);
    let mark = session.state.load_config().unwrap().telegram[0].secret_mark.clone();
    run(&mut session, &["telegram", "rotate-secret", "--name", "de", "--yes"], &none()).unwrap();
    assert_ne!(stored(&session, "telegram-secret").unwrap(), secret);
    assert_ne!(session.state.load_config().unwrap().telegram[0].secret_mark, mark);

    let tag = |value: &str| {
        let mut secrets = Secrets::default();
        secrets.insert("password", Zeroizing::new(value.to_owned())).unwrap();
        secrets
    };
    assert_eq!(run(&mut session, &["telegram", "tag", "--name", "de"], &none()).unwrap_err().code, "missing_secret");
    assert_eq!(run(&mut session, &["telegram", "tag", "--name", "de"], &tag("abc")).unwrap_err().code, "invalid");
    assert_eq!(run(&mut session, &["telegram", "tag", "--name", "de"], &tag(&"g".repeat(32))).unwrap_err().code, "invalid");
    assert_eq!(run(&mut session, &["telegram", "tag", "--name", "de"], &tag(&"AB".repeat(16))).unwrap(), json!({"node": "de", "tag": true}));
    assert_eq!(stored(&session, "telegram-tag").as_deref(), Some("ab".repeat(16).as_str()));
    assert!(session.state.load_config().unwrap().telegram[0].tag_mark.is_some());
    assert_eq!(run(&mut session, &["telegram", "tag", "--name", "de", "--clear"], &none()).unwrap(), json!({"node": "de", "tag": false}));
    assert!(stored(&session, "telegram-tag").is_none());

    let before = fingerprint(root.path());
    assert_eq!(run(&mut session, &["telegram", "remove", "--name", "de"], &none()).unwrap_err().code, "confirmation_required");
    assert_eq!(fingerprint(root.path()), before);
    assert_eq!(run(&mut session, &["telegram", "remove", "--name", "de", "--yes"], &none()).unwrap(), json!({"node": "de"}));
    assert!(session.state.load_config().unwrap().telegram.is_empty() && stored(&session, "telegram-secret").is_none());
}

fn connect_step(index: usize) -> ScriptStep {
    ScriptStep::connect(ConnectExpectation::new(NODES[index].1, 22, "root", AuthMethod::System, CONNECT_TIMEOUT)
        .with_host_key(HostKeyPolicy { expected: None, known: vec![pin_fp()] }), Ok(()))
}

fn exec(command: impl Into<String>, timeout: Duration, exit_status: u32, stdout: &str) -> ScriptStep {
    ScriptStep::exec(command, 0, timeout, Ok(ExecResult { stdout: stdout.into(), stderr: Vec::new(), exit_status }))
}

/// A `connect` factory handing out the given transports in order.
fn transports(scripts: Vec<Vec<ScriptStep>>) -> (impl Fn() -> FakeTransport, Vec<FakeScript>) {
    let transports: Vec<FakeTransport> = scripts.into_iter().map(FakeTransport::new).collect();
    let observers = transports.iter().map(FakeTransport::script).collect();
    let queue = RefCell::new(VecDeque::from(transports));
    (move || queue.borrow_mut().pop_front().expect("no transport scripted for this node"), observers)
}

fn enable(session: &mut Session) {
    run(session, &["telegram", "set", "--name", "de", "--domain", "tg.example.com"], &none()).unwrap();
    run(session, &["telegram", "set", "--name", "nl", "--domain", "tg.nl.example.com"], &none()).unwrap();
}

#[test]
fn status_probes_every_role_and_aggregates() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, journal) = fixture(root.path());
    assert_eq!(run(&mut session, &["telegram", "status"], &none()).unwrap_err().code, "invalid");
    enable(&mut session);
    let (connect, observers) = transports(vec![
        vec![connect_step(0), exec(probe_command("tg.example.com"), COMMAND_TIMEOUT, 0, HEALTHY)],
        vec![connect_step(1), exec(probe_command("tg.nl.example.com"), COMMAND_TIMEOUT, 0, "installed=no\n")],
    ]);
    let invocation = invocation(&["telegram", "status"]);
    let reach = FakeReach::new((true, Ipv6::NotPresent));
    let error = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap()
        .block_on(status(&mut session, &invocation, &connect, &reach)).unwrap_err();
    observers.iter().for_each(FakeScript::assert_finished);
    assert_eq!((error.code, error.exit_code()), ("not_installed", 3));
    let rows = error.extra["results"].as_array().unwrap();
    assert_eq!((rows[0]["node"].clone(), rows[0]["status"].clone(), rows[0]["hostname"].clone()), (json!("de"), json!("ok"), json!("tg.example.com")));
    assert_eq!(rows[1]["status"], "not_installed");
    assert!(rows[0]["summary"].as_array().unwrap().iter().any(|line| line == "  Служба MTProxy: работает"));
    assert_eq!(*reach.calls.borrow(), ["https:tg.example.com"]);
    assert!(journal.borrow().iter().any(|(_, line)| line == "Telegram Proxy de (tg.example.com): успешно"));
    assert_eq!(run(&mut session, &["telegram", "status", "--name", "bare"], &none()).unwrap_err().code, "not_found");
}

#[test]
fn status_repeats_a_lost_connection_once() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    enable(&mut session);
    let failed = |index: usize, reason: &'static str| ScriptStep::connect(
        ConnectExpectation::new(NODES[index].1, 22, "root", AuthMethod::System, CONNECT_TIMEOUT)
            .with_host_key(HostKeyPolicy { expected: None, known: vec![pin_fp()] }), Err(crate::transport::remote_failure(reason)));
    let (connect, observers) = transports(vec![
        vec![failed(0, "connect"), connect_step(0), exec(probe_command("tg.example.com"), COMMAND_TIMEOUT, 0, HEALTHY)],
        // A refused login is not repeated.
        vec![failed(1, "authentication")],
    ]);
    let invocation = invocation(&["telegram", "status"]);
    let reach = FakeReach::new((true, Ipv6::NotPresent));
    let error = tokio::runtime::Builder::new_current_thread().enable_all().start_paused(true).build().unwrap()
        .block_on(status(&mut session, &invocation, &connect, &reach)).unwrap_err();
    observers.iter().for_each(FakeScript::assert_finished);
    let rows = error.extra["results"].as_array().unwrap();
    assert_eq!((rows[0]["status"].clone(), rows[1]["status"].clone()), (json!("ok"), json!("error")));
}

#[test]
fn restart_and_diagnostics_reach_the_node_and_redact() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, journal) = fixture(root.path());
    enable(&mut session);
    let secret = stored(&session, "telegram-secret").unwrap();
    let (connect, observers) = transports(vec![
        vec![connect_step(0), exec(RESTART_COMMAND, RESTART_TIMEOUT, 0, "")],
        vec![connect_step(0), exec(RESTART_COMMAND, RESTART_TIMEOUT, 1, "")],
        vec![connect_step(0), exec(DIAGNOSTICS_COMMAND, COMMAND_TIMEOUT, 0, &format!("-- Журнал --\nstarted with secret={secret}\n\n\u{1b}[1mok\u{1b}[0m\n"))],
    ]);
    assert_eq!(run_with(&mut session, &["telegram", "restart", "--name", "de"], &none(), &connect).unwrap(), json!({"node": "de"}));
    assert_eq!(run_with(&mut session, &["telegram", "restart", "--name", "de"], &none(), &connect).unwrap_err().code, "remote_failed");
    assert_eq!(run_with(&mut session, &["telegram", "diagnostics", "--name", "de"], &none(), &connect).unwrap(), json!({"node": "de"}));
    observers.iter().for_each(FakeScript::assert_finished);
    let output: Vec<String> = journal.borrow().iter().filter(|(level, _)| *level == Level::Output).map(|(_, line)| line.clone()).collect();
    assert_eq!(output, ["-- Журнал --", "started with secret=[REDACTED]", "ok"]);
    assert!(!journal.borrow().iter().any(|(_, line)| line.contains(&secret)));
}
