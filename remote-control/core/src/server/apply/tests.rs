//! `node apply` against scripted nodes (`FakeTransport`, paused time).

use std::cell::RefCell;
use std::collections::VecDeque;

use super::*;
use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeScript, FakeTransport, Operation, ScriptStep};
use crate::model::{Client, ClientCredentials, Connection, ConnectionGroup, NodeParams, NodeReality, Profile};
use crate::nodes::testing::{self, Journal, fingerprint, invocation};
use crate::nodes::{CONNECT_TIMEOUT, pin};
use crate::transport::{ExecResult, HostKeyPolicy, remote_failure};

thread_local! {
    pub(crate) static NEXT_OP_ID: RefCell<Option<String>> = const { RefCell::new(None) };
}

const OP: &str = "0123456789abcdef0123456789abcdef";

fn fp(byte: u8) -> crate::model::Fingerprint {
    use base64::Engine;
    format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode([byte; 32])).parse().unwrap()
}

fn node(index: u8, name: &str) -> Node {
    Node {
        id: format!("{index:032x}"), name: name.into(), ip: format!("192.0.2.{index}"), port: 22, user: "root".into(),
        identity: Some("system".into()), profile: Some("main".into()), domain: Some(format!("{name}.example.com")),
        params: NodeParams {
            reality: Some(NodeReality { public_key: "PUB".into(), short_id: "0123456789abcdef".into() }), ..NodeParams::default()
        },
        ..Node::default()
    }
}

/// Nodes `de` and `nl` with profile `main`, client `alpha` on both.
fn fixture(root: &std::path::Path) -> (Session, Journal) {
    let (session, journal) = testing::session(root);
    let nodes = vec![node(1, "de"), node(2, "nl")];
    for node in &nodes {
        pin(&session.state, &node.ip, node.port, vec![fp(node.id.as_bytes()[31])]).unwrap();
        session.state.secret_store().set(&format!("node:{}:reality-key", node.id), Zeroizing::new("PRIV".into())).unwrap();
    }
    let config = Config {
        profiles: vec![Profile {
            name: "main".into(), mihomo_version: "v1.19.18".into(), acme_email: "admin@example.com".into(),
            vless_tcp: true, ..Profile::default()
        }],
        connections: nodes.iter().map(|node| Connection { node: node.name.clone(),
            groups: vec![ConnectionGroup { name: "PC".into(), proxies: vec!["VLESS TCP".into()] }] }).collect(),
        nodes,
        clients: vec![Client { name: "alpha".into(), group: "PC".into(), credentials: Some(ClientCredentials {
            vless_uuid: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee".into(), hy2_password: "pw".into(), ..ClientCredentials::default() }),
            ..Client::default() }],
        ..Config::default()
    };
    session.state.save_config(&config).unwrap();
    (session, journal)
}

use zeroize::Zeroizing;

fn config(session: &Session) -> Config {
    session.state.load_config().unwrap()
}

fn connect_step(node: &Node, outcome: Result<()>) -> ScriptStep {
    ScriptStep::connect(ConnectExpectation::new(node.ip.clone(), 22, "root", AuthMethod::System, CONNECT_TIMEOUT)
        .with_host_key(HostKeyPolicy { expected: None, known: vec![fp(node.id.as_bytes()[31])] }), outcome)
}

fn ok(stdout: &str) -> Result<ExecResult> {
    Ok(ExecResult { stdout: stdout.as_bytes().to_vec(), stderr: Vec::new(), exit_status: 0 })
}

fn exec(command: String, stdout: &str) -> ScriptStep {
    ScriptStep::exec(command, 0, COMMAND_TIMEOUT, ok(stdout))
}

const DEBIAN: &str = "os=debian\nsystemd=yes\nlisten tcp 0.0.0.0:22\n";

fn probe_step(node: &Node, stdout: &str) -> ScriptStep {
    exec(probe_command(node), stdout)
}

/// Executor upload, operation upload, start.
fn start_steps(op: &str) -> Vec<ScriptStep> {
    vec![
        exec(agent_reset_command(), ""),
        ScriptStep::upload_any_local(agent_dir(), LONG_TIMEOUT, Ok(())),
        ScriptStep::upload_any_local(ops_dir(op), LONG_TIMEOUT, Ok(())),
        exec(start_command(op), ""),
    ]
}

/// Transports handed out in order.
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

    fn finish(&self) {
        self.scripts.iter().for_each(FakeScript::assert_finished);
    }

    fn uploads(&self) -> usize {
        self.scripts.iter().flat_map(FakeScript::journal).filter(|op| matches!(op, Operation::Upload { .. })).count()
    }
}

async fn run(session: &mut Session, hosts: &Hosts, argv: &[&str]) -> Result<Value> {
    let connect = || hosts.queue.borrow_mut().pop_front().expect("no transport scripted");
    apply(session, &invocation(argv), &connect).await
}

#[tokio::test(start_paused = true)]
async fn one_node_is_planned_then_applied_and_recorded() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, journal) = fixture(root.path());
    let de = node(1, "de");
    let before = fingerprint(root.path());
    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.code, "confirmation_required");
    assert_eq!(error.extra["plan"][0], "Нода: de  192.0.2.1:22");
    assert_eq!(hosts.uploads(), 0);
    assert_eq!(fingerprint(root.path()), before);

    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)];
    steps.extend(start_steps(OP));
    steps.push(exec(status_command(OP), "stage=packages\n"));
    steps.push(exec(status_command(OP), "stage=cleanup\nresult=committed\n"));
    let hosts = Hosts::new(vec![steps]);
    let data = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap();
    hosts.finish();
    assert_eq!(data, json!({"applied": ["de"], "failed": [], "unchanged": []}));
    let saved = config(&session);
    let node = &saved.nodes[0];
    assert!(node.operation.is_none());
    let applied = node.applied.as_ref().unwrap();
    assert_eq!(applied.digest, render::desired(&saved, node, None).unwrap().digest);
    assert!(applied.files.contains_key(render::MIHOMO_CONFIG_PATH) && applied.ports == ["443/tcp"]);
    assert_eq!(render::status(&saved, node), "applied");
    let logged: Vec<String> = journal.borrow().iter().map(|(_, text)| text.clone()).collect();
    assert!(logged.contains(&"de: исполнитель загружен".to_owned()) && logged.contains(&"de: установка пакетов".to_owned()));

    // Nothing changed and nothing drifted: unchanged, no plan.
    let hashes: String = applied.files.iter().map(|(path, hash)| format!("{hash}  {path}\n")).collect();
    let hosts = Hosts::new(vec![vec![connect_step(node, Ok(())), probe_step(node, &format!("{DEBIAN}agent=ok\n{hashes}"))]]);
    let data = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap();
    assert_eq!(data, json!({"applied": [], "failed": [], "unchanged": ["de"]}));

    // A manual edit drifts into the plan and changes its token.
    let hosts = Hosts::new(vec![vec![connect_step(node, Ok(())),
        probe_step(node, &format!("{DEBIAN}agent=ok\nmissing {}\n", render::MIHOMO_CONFIG_PATH))]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    assert_eq!(error.code, "confirmation_required");
    assert!(error.extra["plan"].as_array().unwrap().contains(&json!("Изменено вручную, будет перезаписано: /etc/mihomo/config.yaml")));
}

#[tokio::test(start_paused = true)]
async fn rollback_is_reported_with_the_log_and_clears_the_operation() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, journal) = fixture(root.path());
    let de = node(1, "de");
    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)];
    steps.extend(start_steps(OP));
    steps.push(exec(status_command(OP), "stage=config\nresult=rolled_back\nerror=config\n"));
    steps.push(exec(log_command(OP), "[✗] mihomo -t failed\n"));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.code, "partial");
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "config",
        "reason": "de: откат на этапе «конфигурация и проверка»"}]));
    assert_eq!((error.extra["applied"].clone(), error.extra["unchanged"].clone()), (json!([]), json!([])));
    let node = &config(&session).nodes[0];
    assert!(node.operation.is_none() && node.applied.is_none());
    assert!(journal.borrow().contains(&(Level::Output, "[✗] mihomo -t failed".into())));
}

#[tokio::test(start_paused = true)]
async fn a_dropped_connection_is_reestablished_while_polling() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    let de = node(1, "de");
    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)];
    steps.extend(start_steps(OP));
    steps.push(ScriptStep::exec(status_command(OP), 0, COMMAND_TIMEOUT, Err(remote_failure("connection_lost"))));
    steps.push(connect_step(&de, Err(remote_failure("connect"))));
    steps.push(connect_step(&de, Ok(())));
    steps.push(exec(status_command(OP), "stage=cleanup\nresult=committed\n"));
    let hosts = Hosts::new(vec![steps]);
    let data = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap();
    hosts.finish();
    assert_eq!(data["applied"], json!(["de"]));
}

#[tokio::test(start_paused = true)]
async fn unreachable_unsupported_and_busy_nodes_are_excluded() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    let (de, nl) = (node(1, "de"), node(2, "nl"));
    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let mut steps = vec![connect_step(&nl, Ok(())), probe_step(&nl, DEBIAN)];
    steps.extend(start_steps(OP));
    steps.push(exec(status_command(OP), "stage=cleanup\nresult=committed\n"));
    let hosts = Hosts::new(vec![vec![connect_step(&de, Err(remote_failure("connect")))], steps]);
    let error = run(&mut session, &hosts, &["node", "apply", "--pending", "--yes"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.code, "partial");
    assert_eq!(error.extra["applied"], json!(["nl"]));
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "remote_failed", "reason": "Не удалось подключиться к «de»."}]));

    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, "os=centos\nsystemd=yes\n")]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    assert_eq!(error.extra["failed"][0]["stage"], "unsupported_os");

    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, "os=ubuntu\nsystemd=yes\nlisten tcp [::]:443\n")]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    assert_eq!((error.extra["failed"][0]["stage"].clone(), error.extra["failed"][0]["port"].clone()), (json!("port_busy"), json!(443)));
}

#[tokio::test(start_paused = true)]
async fn a_client_added_after_the_plan_changes_it() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    let de = node(1, "de");
    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)]]);
    let token = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err().extra["plan_token"].clone();
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        let mut client = config.clients[0].clone();
        client.name = "beta".into();
        config.clients.push(client);
        state.save_config(&config)
    }).unwrap();
    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes", "--plan-token", token.as_str().unwrap()])
        .await.unwrap_err();
    assert_eq!(error.code, "plan_changed");
    assert_eq!(hosts.uploads(), 0);
}

#[tokio::test(start_paused = true)]
async fn nothing_pending_and_profileless_targets() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.nodes.iter_mut().for_each(|node| node.profile = None);
        state.save_config(&config)
    }).unwrap();
    let hosts = Hosts::new(vec![]);
    let error = run(&mut session, &hosts, &["node", "apply", "--pending"]).await.unwrap_err();
    assert_eq!((error.code, error.message.as_str()), ("nothing_pending", "Нет нод, ожидающих применения."));
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    assert_eq!((error.code, error.message.as_str()), ("invalid", "У ноды «de» нет профиля."));
    assert_eq!(run(&mut session, &hosts, &["node", "apply"]).await.unwrap_err().code, "usage");
}

#[tokio::test(start_paused = true)]
async fn an_unfinished_operation_is_resumed_without_upload() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.nodes[0].operation = Some(OP.into());
        state.save_config(&config)
    }).unwrap();
    let de = config(&session).nodes[0].clone();
    assert_eq!(render::status(&config(&session), &de), "running");
    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, &format!("{DEBIAN}agent=ok\nstage=config\n")),
        exec(status_command(OP), "stage=cleanup\nresult=committed\n")]]);
    let data = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap();
    hosts.finish();
    assert_eq!(data["applied"], json!(["de"]));
    assert_eq!(hosts.uploads(), 0);
    assert!(config(&session).nodes[0].operation.is_none());
}

#[tokio::test(start_paused = true)]
async fn a_missing_domain_of_a_named_node_is_its_own_error() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.nodes[0].domain = None;
        state.save_config(&config)
    }).unwrap();
    let error = run(&mut session, &Hosts::new(vec![]), &["node", "apply", "--name", "de"]).await.unwrap_err();
    assert_eq!((error.code, error.extra["name"].clone()), ("domain_required", json!("de")));
}

#[test]
fn probe_output_parses() {
    let probe = parse_probe("os=\"ubuntu\"\r\nsystemd=yes\nagent=ok\nlisten udp 0.0.0.0:51820\nlisten tcp [::]:443\n\
        missing /etc/x\nabababababababababababababababababababababababababababababababab  /etc/y\nstage=config\n");
    assert_eq!((probe.os.as_str(), probe.systemd, probe.agent_ok), ("ubuntu", true, true));
    assert_eq!(probe.listening, [("udp".to_owned(), 51820), ("tcp".to_owned(), 443)]);
    assert_eq!(probe.hashes["/etc/x"], None);
    assert_eq!(probe.hashes["/etc/y"].as_deref(), Some("ab".repeat(32).as_str()));
    assert_eq!(probe.status["stage"], "config");
    assert!(start_command(OP).starts_with(&format!("systemd-run --unit=essence-apply-{OP} --collect --quiet /bin/bash '/root/essence-node/agent/")));
}
