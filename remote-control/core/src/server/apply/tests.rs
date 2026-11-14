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
const PUBLIC_KEY: &str = "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP";

fn fp(byte: u8) -> crate::model::Fingerprint {
    use base64::Engine;
    format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode([byte; 32])).parse().unwrap()
}

fn node(index: u8, name: &str) -> Node {
    Node {
        id: format!("{index:032x}"), name: name.into(), ip: format!("192.0.2.{index}"), port: 22, user: "root".into(),
        identity: Some("system".into()), profile: Some("main".into()), domain: Some(format!("{name}.example.com")),
        params: NodeParams {
            reality: Some(NodeReality { public_key: PUBLIC_KEY.into(), short_id: "0123456789abcdef".into() }), ..NodeParams::default()
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

const DEBIAN: &str = "os=debian\nsystemd=yes\nsshd=22\nlisten tcp 0.0.0.0:22\n";
/// The executor unit is still running.
const LIVE: &str = "unit=active\n";

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

fn set_operation(session: &mut Session, operation: Option<crate::model::Operation>) {
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.nodes[0].operation = operation;
        state.save_config(&config)
    }).unwrap();
}

/// An operation recorded for `de` with a digest of its own.
fn recorded(digest: &str) -> crate::model::Operation {
    crate::model::Operation {
        id: OP.into(), digest: digest.repeat(64), files: [(render_paths::MIHOMO_CONFIG_PATH.to_owned(), "c".repeat(64))].into(),
        ports: vec!["443/tcp".into()], teardown: false,
    }
}

use super::super::paths as render_paths;

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
    steps.push(exec(status_command(OP), &format!("{LIVE}stage=packages\n")));
    steps.push(exec(status_command(OP), "unit=inactive\nstage=cleanup\nresult=committed\n"));
    let hosts = Hosts::new(vec![steps]);
    let data = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap();
    hosts.finish();
    assert_eq!(data, json!({"applied": ["de"], "failed": [], "unchanged": []}));
    let saved = config(&session);
    let node = &saved.nodes[0];
    assert!(node.operation.is_none());
    let applied = node.applied.as_ref().unwrap();
    assert_eq!(applied.digest, render::desired(&saved, node, None).unwrap().digest);
    assert!(applied.files.contains_key(render_paths::MIHOMO_CONFIG_PATH) && applied.ports == ["443/tcp"]);
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
        probe_step(node, &format!("{DEBIAN}agent=ok\nmissing {}\n", render_paths::MIHOMO_CONFIG_PATH))]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    assert_eq!(error.code, "confirmation_required");
    assert!(error.extra["plan"].as_array().unwrap().contains(&json!("Изменено вручную, будет перезаписано: /etc/mihomo/config.yaml")));
}

#[test]
fn the_operation_directory_allows_every_ssh_port() {
    let root = tempfile::tempdir().unwrap();
    let (session, _journal) = fixture(root.path());
    let config = config(&session);
    let mut desired = render::desired(&config, &config.nodes[0], Some(&NodeSecrets {
        reality_key: Some(Zeroizing::new("K".repeat(43))), ..NodeSecrets::default() })).unwrap();
    desired.add_ssh_port(2222);
    desired.add_ssh_port(22);
    let dir = operation_dir(OP, &desired).unwrap();
    let spec = std::fs::read_to_string(dir.path().join("spec.sh")).unwrap();
    assert!(spec.contains("\nSSH_PORTS='22 2222'\n") && spec.contains("\nLISTEN_TCP='443 8443'\n"), "{spec}");
    assert!(start_command(OP).contains(&format!("systemd-run --unit=essence-apply-{OP} --collect --quiet --setenv=HOME=/root /bin/bash ")));
    assert!(start_command(OP).starts_with(&format!("(cd '{}' 2>/dev/null && [ \"$(sha256sum < MANIFEST", agent_dir())));
}

#[tokio::test(start_paused = true)]
async fn sshd_behind_nat_is_planned() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    let de = node(1, "de");
    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, &DEBIAN.replace("sshd=22", "sshd=2222"))]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    assert!(error.extra["plan"].as_array().unwrap().contains(&json!("SSH на ноде слушает порт 2222: при включении UFW он тоже будет разрешён.")));
}

#[tokio::test(start_paused = true)]
async fn rollback_is_reported_with_the_log_and_clears_the_operation() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, journal) = fixture(root.path());
    let de = node(1, "de");
    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)];
    steps.extend(start_steps(OP));
    steps.push(exec(status_command(OP), "unit=inactive\nstage=config\nresult=rolled_back\nerror=config\n"));
    steps.push(exec(log_command(OP), "[✗] mihomo -t failed\n"));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.code, "partial");
    // The front ends' copies of the failed[] contract are taken from here.
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "config", "code": "rolled_back",
        "message": "откат на этапе «конфигурация и проверка»"}]));
    assert_eq!((error.extra["applied"].clone(), error.extra["unchanged"].clone()), (json!([]), json!([])));
    let node = &config(&session).nodes[0];
    assert!(node.operation.is_none() && node.applied.is_none());
    assert!(journal.borrow().contains(&(Level::Output, "[✗] mihomo -t failed".into())));
    assert!(journal.borrow().contains(&(Level::Warn, "de: откат на этапе «конфигурация и проверка»".into())));
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
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "probe", "code": "remote_failed",
        "message": "Не удалось подключиться к «de»."}]));

    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, "os=centos\nsystemd=yes\n")]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "probe", "code": "unsupported_os",
        "message": "нужна Debian или Ubuntu с systemd"}]));

    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, "os=ubuntu\nsystemd=yes\nlisten tcp [::]:443\n")]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "probe", "code": "port_busy",
        "message": "порт 443 уже занят", "port": 443}]));
}

#[tokio::test(start_paused = true)]
async fn a_missing_domain_fails_only_its_node_in_bulk() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.nodes[0].domain = None;
        state.save_config(&config)
    }).unwrap();
    let nl = node(2, "nl");
    let hosts = Hosts::new(vec![vec![connect_step(&nl, Ok(())), probe_step(&nl, DEBIAN)]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--pending"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.code, "confirmation_required");

    let hosts = Hosts::new(vec![vec![connect_step(&nl, Ok(())), probe_step(&nl, "os=ubuntu\nsystemd=yes\nlisten tcp [::]:443\n")]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--profile", "main"]).await.unwrap_err();
    assert_eq!(error.code, "partial");
    assert_eq!(error.extra["failed"][0], json!({"name": "de", "stage": "probe", "code": "domain_required",
        "message": "Для ноды «de» нужен домен: node domain --name de --domain D."}));
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
    assert!(config(&session).nodes[0].operation.is_none());
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
async fn a_resumed_operation_records_what_it_uploaded() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    set_operation(&mut session, Some(recorded("a")));
    // A client added after the operation started is not part of it.
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        let mut client = config.clients[0].clone();
        client.name = "beta".into();
        config.clients.push(client);
        state.save_config(&config)
    }).unwrap();
    let de = config(&session).nodes[0].clone();
    assert_eq!(render::status(&config(&session), &de), "running");
    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, &format!("{DEBIAN}agent=ok\n{LIVE}stage=config\n")),
        exec(status_command(OP), "stage=cleanup\nresult=committed\n")]]);
    let data = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap();
    hosts.finish();
    assert_eq!(data["applied"], json!(["de"]));
    assert_eq!(hosts.uploads(), 0);
    let saved = config(&session);
    let node = &saved.nodes[0];
    assert!(node.operation.is_none());
    assert_eq!(node.applied.as_ref().map(|applied| applied.digest.clone()), Some("a".repeat(64)));
    assert_eq!(render::status(&saved, node), "pending", "beta still has to be applied");
}

#[tokio::test(start_paused = true)]
async fn an_operation_finished_unwatched_is_settled_at_the_probe() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, journal) = fixture(root.path());
    // Committed after RC gave up: the uploaded state is recorded, the operation
    // cleared; the node is then compared as usual (here: unchanged).
    let digest = render::desired(&config(&session), &config(&session).nodes[0], None).unwrap().digest;
    let mut operation = recorded("a");
    operation.digest = digest;
    set_operation(&mut session, Some(operation));
    let de = config(&session).nodes[0].clone();
    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de,
        &format!("{DEBIAN}agent=ok\nlisten tcp 0.0.0.0:443\n{}  /etc/mihomo/config.yaml\nunit=inactive\nstage=cleanup\nresult=committed\n", "c".repeat(64)))]]);
    let data = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap();
    hosts.finish();
    assert_eq!(data, json!({"applied": [], "failed": [], "unchanged": ["de"]}));
    let node = &config(&session).nodes[0];
    assert!(node.operation.is_none() && node.applied.is_some());
    assert!(journal.borrow().contains(&(Level::Info, "de: прошлое применение завершилось успешно.".into())));
}

#[tokio::test(start_paused = true)]
async fn a_dead_executor_is_not_resumed() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, journal) = fixture(root.path());
    // Killed without writing a result: cleared and started anew.
    set_operation(&mut session, Some(recorded("a")));
    let de = config(&session).nodes[0].clone();
    let next = "fedcba9876543210fedcba9876543210";
    NEXT_OP_ID.with(|id| *id.borrow_mut() = Some(next.into()));
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, &format!("{DEBIAN}agent=ok\nunit=inactive\nstage=config\n"))];
    steps.extend(start_steps(next).into_iter().skip(2));
    // While polling: the unit dies without a result.
    steps.push(exec(status_command(next), "unit=failed\nstage=mihomo\n"));
    steps.push(exec(log_command(next), "Killed\n"));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap_err();
    hosts.finish();
    assert!(journal.borrow().contains(&(Level::Warn, "de: прошлое применение прервано без результата.".into())));
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "mihomo", "code": "failed",
        "message": "исполнитель остановился без результата на этапе «установка mihomo»"}]));
    assert!(config(&session).nodes[0].operation.is_none(), "a dead operation is not kept for resuming");
}

#[tokio::test(start_paused = true)]
async fn a_timeout_keeps_the_operation_for_the_next_apply() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    let de = node(1, "de");
    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)];
    steps.extend(start_steps(OP));
    // Then every reconnect fails (the script is exhausted).
    steps.push(ScriptStep::exec(status_command(OP), 0, COMMAND_TIMEOUT, Err(remote_failure("connection_lost"))));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap_err();
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "start", "code": "timeout",
        "message": "нет связи с нодой больше 10 минут"}]));
    assert_eq!(config(&session).nodes[0].operation.as_ref().map(|operation| operation.id.as_str()), Some(OP));
}

#[test]
fn probe_output_parses() {
    let probe = parse_probe("os=\"ubuntu\"\r\nsystemd=yes\nsshd=2222\nagent=ok\nlisten udp 0.0.0.0:51820\nlisten tcp [::]:443\n\
        missing /etc/x\nabababababababababababababababababababababababababababababababab  /etc/y\nunit=active\nstage=config\n");
    assert_eq!((probe.os.as_str(), probe.systemd, probe.agent_ok, probe.sshd), ("ubuntu", true, true, Some(2222)));
    assert_eq!(probe.listening, [("udp".to_owned(), 51820), ("tcp".to_owned(), 443)]);
    assert_eq!(probe.hashes["/etc/x"], None);
    assert_eq!(probe.hashes["/etc/y"].as_deref(), Some("ab".repeat(32).as_str()));
    assert_eq!((probe.status["stage"].as_str(), unit_gone(&probe.status)), ("config", false));
    assert!(parse_probe("sshd=\n").sshd.is_none());
    assert!(unit_gone(&parse_status("unit=inactive\nstage=config\n")) && unit_gone(&parse_status("stage=config\n")));
}
