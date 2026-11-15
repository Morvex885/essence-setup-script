//! `node apply` against scripted nodes (`FakeTransport`, paused time).

use std::cell::RefCell;
use std::collections::VecDeque;

use super::*;
use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeScript, FakeTransport, Operation, ScriptStep};
use crate::model::{Client, ClientCredentials, Connection, ConnectionGroup, NodeParams, NodeReality, Profile};
use crate::nodes::testing::{self, Journal, Live, fingerprint, invocation};
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
    let (session, journal, _) = fixture_live(root);
    (session, journal)
}

/// [`fixture`] that also records the live lines.
fn fixture_live(root: &std::path::Path) -> (Session, Journal, Live) {
    let (session, journal, live) = testing::session_live(root);
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
    (session, journal, live)
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

const DEBIAN: &str = "os=debian\nversion=12\nsystemd=yes\nsshd=22\nlisten tcp 0.0.0.0:22\n";
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
        ScriptStep::upload_private_any_local(ops_dir(op), LONG_TIMEOUT, Ok(())),
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
async fn an_incomplete_rollback_is_reported_apart() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    let de = node(1, "de");
    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)];
    steps.extend(start_steps(OP));
    steps.push(exec(status_command(OP), "unit=inactive\nstage=config\nresult=rollback_failed\nerror=config\n"));
    steps.push(exec(log_command(OP), "[✗] restore failed\n"));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "config", "code": "rollback_failed",
        "message": "откат на этапе «конфигурация и проверка» не завершён: резервные копии оставлены на ноде"}]));
    // First apply: the attempt's files and ports stay ours, the node pending.
    let saved = config(&session);
    let node = &saved.nodes[0];
    assert!(node.operation.is_none());
    let applied = node.applied.as_ref().expect("the attempt is kept");
    assert_eq!(applied.digest, render::incomplete_digest());
    assert!(applied.files.contains_key(render_paths::MIHOMO_CONFIG_PATH) && applied.ports == ["443/tcp"]);
    assert_eq!(render::status(&saved, node), "pending");
    // Our own listener on 443 is not busy; the plan says why it runs; the
    // attempt's hashes are not reported as manual edits.
    let probe = format!("{DEBIAN}agent=ok\nlisten tcp 0.0.0.0:443\nmissing {}\n", render_paths::MIHOMO_CONFIG_PATH);
    let hosts = Hosts::new(vec![vec![connect_step(node, Ok(())), probe_step(node, &probe)]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.code, "confirmation_required");
    let plan = error.extra["plan"].as_array().unwrap();
    assert!(plan.contains(&json!("de: прошлое применение не завершило откат — следующее применение перезапишет файлы.")));
    assert!(!plan.iter().any(|line| line.as_str().unwrap().starts_with("Изменено вручную")), "{plan:?}");
}

#[tokio::test(start_paused = true)]
async fn an_incomplete_rollback_of_a_reapply_keeps_both_sets() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.nodes[0].applied = Some(crate::model::Applied {
            digest: "b".repeat(64), files: [(render_paths::SYSCTL_PATH.to_owned(), "d".repeat(64))].into(),
            ports: vec!["2053/tcp".into()], at: "2026-01-01T00:00:00Z".into(),
        });
        state.save_config(&config)
    }).unwrap();
    let de = config(&session).nodes[0].clone();
    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let hashes = format!("{}  {}\n", "d".repeat(64), render_paths::SYSCTL_PATH);
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, &format!("{DEBIAN}{hashes}"))];
    steps.extend(start_steps(OP));
    steps.push(exec(status_command(OP), "unit=inactive\nstage=config\nresult=rollback_failed\nerror=config\n"));
    steps.push(exec(log_command(OP), ""));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.extra["failed"][0]["code"], "rollback_failed");
    let applied = config(&session).nodes[0].applied.clone().unwrap();
    assert_eq!(applied.digest, render::incomplete_digest());
    assert!(applied.files.contains_key(render_paths::SYSCTL_PATH) && applied.files.contains_key(render_paths::MIHOMO_CONFIG_PATH));
    assert_eq!(applied.ports, ["2053/tcp", "443/tcp"]);

    // Found unwatched, the same settlement is planned and recorded.
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    set_operation(&mut session, Some(recorded("a")));
    let de = config(&session).nodes[0].clone();
    let probe = format!("{DEBIAN}agent=ok\nunit=inactive\nstage=config\nresult=rollback_failed\n");
    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, &probe)]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    hosts.finish();
    assert!(error.extra["plan"].as_array().unwrap().contains(&json!(
        "de: прошлое применение не завершило откат — его файлы и порты остаются за Essence до следующего применения.")));
}

#[tokio::test(start_paused = true)]
async fn a_recognised_failure_tells_what_to_do() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    let de = node(1, "de");
    for (hint, tail) in [("kernel_headers", Some("обновите ядро")), ("unknown_id", None)] {
        NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
        let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)];
        steps.extend(start_steps(OP));
        steps.push(exec(status_command(OP), &format!("unit=inactive\nstage=prepare\nresult=failed\nerror=prepare\nhint={hint}\n")));
        steps.push(exec(log_command(OP), ""));
        let hosts = Hosts::new(vec![steps]);
        let error = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap_err();
        hosts.finish();
        let message = error.extra["failed"][0]["message"].as_str().unwrap();
        match tail {
            Some(tail) => assert!(message.starts_with("ошибка на этапе «подготовка компонентов»: ") && message.contains(tail)
                && message.contains("перезагрузите сервер"), "{message}"),
            None => assert_eq!(message, "ошибка на этапе «подготовка компонентов»"),
        }
    }
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
    // A transient failure is retried once, then the node fails.
    let hosts = Hosts::new(vec![vec![connect_step(&de, Err(remote_failure("connect"))), connect_step(&de, Err(remote_failure("timeout")))], steps]);
    let error = run(&mut session, &hosts, &["node", "apply", "--pending", "--yes"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.code, "partial");
    assert_eq!(error.extra["applied"], json!(["nl"]));
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "probe", "code": "remote_failed",
        "message": "Не удалось подключиться к «de»."}]));

    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, "os=centos\nversion=\"9\"\nsystemd=yes\n")]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "probe", "code": "unsupported_os",
        "message": "ОС ноды «centos 9» не поддерживается: нужна Debian 12/13 или Ubuntu 22.04/24.04/26.04 с systemd"}]));

    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, "os=ubuntu\nversion=26.04\nsystemd=yes\nlisten tcp [::]:443\n")]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "probe", "code": "port_busy",
        "message": "порт 443 уже занят", "port": 443}]));
}

#[tokio::test(start_paused = true)]
async fn the_probe_retries_a_lost_handshake_once_but_not_a_refused_login() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    let de = node(1, "de");
    let hosts = Hosts::new(vec![vec![connect_step(&de, Err(remote_failure("connect"))), connect_step(&de, Ok(())), probe_step(&de, DEBIAN)]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.code, "confirmation_required");
    for refused in [remote_failure("authentication"), RcError::new("host_key_changed", "x")] {
        let hosts = Hosts::new(vec![vec![connect_step(&de, Err(refused))]]);
        let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
        hosts.finish();
        assert_eq!(error.code, "partial");
    }
}

#[tokio::test(start_paused = true)]
async fn a_changed_host_key_keeps_its_fingerprint_in_the_failed_entry() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    let de = node(1, "de");
    let presented = fp(b'Z');
    let refused = RcError::new("host_key_changed", "Ключ SSH-сервера не подтверждён.").with_extra("host", de.ip.clone())
        .with_extra("port", 22).with_extra("fingerprints", json!([presented])).with_extra("cause", "x");
    let hosts = Hosts::new(vec![vec![connect_step(&de, Err(refused))]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "probe", "code": "host_key_changed",
        "message": "Ключ сервера ноды «de» изменился.", "host": de.ip, "fingerprints": [presented]}]));
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

    let hosts = Hosts::new(vec![vec![connect_step(&nl, Ok(())), probe_step(&nl, "os=ubuntu\nversion=24.04\nsystemd=yes\nlisten tcp [::]:443\n")]]);
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
async fn an_operation_finished_unwatched_is_settled_after_confirmation() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    // Committed after RC gave up: the plan is built on the recorded upload
    // (here: nothing else to do); the record is written only with --yes.
    let digest = render::desired(&config(&session), &config(&session).nodes[0], None).unwrap().digest;
    let mut operation = recorded("a");
    operation.digest = digest;
    set_operation(&mut session, Some(operation));
    let de = config(&session).nodes[0].clone();
    let probe = format!("{DEBIAN}agent=ok\nlisten tcp 0.0.0.0:443\n{}  /etc/mihomo/config.yaml\nunit=inactive\nstage=cleanup\nresult=committed\n",
        "c".repeat(64));
    let before = fingerprint(root.path());
    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, &probe)]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.code, "confirmation_required");
    assert_eq!(error.extra["plan"], json!(["de: прошлое применение завершилось успешно — результат будет записан."]));
    assert_eq!(fingerprint(root.path()), before, "an unconfirmed apply changes nothing");

    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, &probe)]]);
    let data = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap();
    hosts.finish();
    assert_eq!(data, json!({"applied": [], "failed": [], "unchanged": ["de"]}));
    let node = &config(&session).nodes[0];
    assert!(node.operation.is_none() && node.applied.is_some());
}

#[tokio::test(start_paused = true)]
async fn a_dead_executor_is_not_resumed_and_its_attempt_stays_ours() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    // Killed without writing a result (unwatched): not resumed; its files and
    // ports stay ours until an apply commits.
    set_operation(&mut session, Some(recorded("a")));
    let de = config(&session).nodes[0].clone();
    let dead = format!("{DEBIAN}agent=ok\nlisten tcp 0.0.0.0:443\nunit=inactive\nstage=config\n");
    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, &dead)]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.code, "confirmation_required", "our own 443 is not busy: {error:?}");
    assert!(error.extra["plan"].as_array().unwrap().contains(&json!(
        "de: прошлое применение прервалось без результата — его файлы и порты остаются за Essence до следующего применения.")));

    let next = "fedcba9876543210fedcba9876543210";
    NEXT_OP_ID.with(|id| *id.borrow_mut() = Some(next.into()));
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, &dead)];
    steps.extend(start_steps(next).into_iter().skip(2));
    // While polling (watched): the unit dies without a result.
    steps.push(exec(status_command(next), "unit=failed\nstage=mihomo\n"));
    steps.push(exec(log_command(next), "Killed\n"));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap_err();
    hosts.finish();
    assert!(error.extra.get("plan").is_none());
    assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "mihomo", "code": "failed",
        "message": "исполнитель остановился без результата на этапе «установка mihomo»"}]));
    let saved = config(&session);
    let node = &saved.nodes[0];
    assert!(node.operation.is_none(), "a dead operation is not kept for resuming");
    let applied = node.applied.as_ref().expect("the attempt is kept");
    assert_eq!(applied.digest, render::incomplete_digest());
    assert!(applied.files.contains_key(render_paths::MIHOMO_CONFIG_PATH) && applied.ports == ["443/tcp"]);
    assert_ne!(applied.files[render_paths::MIHOMO_CONFIG_PATH], "c".repeat(64), "the watched attempt's hashes win");
    assert_eq!(render::status(&saved, node), "pending");
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

#[tokio::test(start_paused = true)]
async fn a_start_with_an_unknown_result_is_settled_by_polling() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    let de = node(1, "de");
    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    // The connection drops during systemd-run, the unit did start and commits.
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)];
    steps.extend(start_steps(OP).into_iter().take(3));
    steps.push(ScriptStep::exec(start_command(OP), 0, COMMAND_TIMEOUT, Err(remote_failure("connection_lost"))));
    steps.push(connect_step(&de, Ok(())));
    steps.push(exec(status_command(OP), "unit=inactive\nstage=cleanup\nresult=committed\n"));
    let hosts = Hosts::new(vec![steps]);
    let data = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap();
    hosts.finish();
    assert_eq!(data["applied"], json!(["de"]));
    assert!(config(&session).nodes[0].applied.is_some());

    // Unreachable after the drop: the operation stays for the next apply.
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)];
    steps.extend(start_steps(OP).into_iter().take(3));
    steps.push(ScriptStep::exec(start_command(OP), 0, COMMAND_TIMEOUT, Err(remote_failure("connection_lost"))));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap_err();
    assert_eq!(error.extra["failed"][0]["code"], "timeout");
    assert_eq!(config(&session).nodes[0].operation.as_ref().map(|operation| operation.id.as_str()), Some(OP));

    // A refused start certainly did not happen: the operation is cleared.
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)];
    steps.extend(start_steps(OP).into_iter().take(3));
    steps.push(ScriptStep::exec(start_command(OP), 0, COMMAND_TIMEOUT,
        Ok(ExecResult { stdout: Vec::new(), stderr: Vec::new(), exit_status: 1 })));
    let hosts = Hosts::new(vec![steps]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(error.extra["failed"][0]["code"], "start");
    assert!(config(&session).nodes[0].operation.is_none());
}

#[test]
fn the_probe_hashes_the_files_of_a_recorded_operation_too() {
    let mut de = node(1, "de");
    de.operation = Some(recorded("a"));
    de.operation.as_mut().unwrap().files.insert(render_paths::SYSCTL_PATH.to_owned(), "d".repeat(64));
    de.applied = Some(crate::model::Applied {
        digest: "b".repeat(64), files: [(render_paths::MIHOMO_CONFIG_PATH.to_owned(), "c".repeat(64))].into(),
        ports: Vec::new(), at: String::new(),
    });
    let command = probe_command(&de);
    assert!(command.contains(&format!("for f in '{}' '{}'; do", render_paths::MIHOMO_CONFIG_PATH, render_paths::SYSCTL_PATH)), "{command}");
}

#[tokio::test(start_paused = true)]
async fn a_missing_reality_key_fails_the_node_with_the_way_back() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    let de = node(1, "de");
    session.state.secret_store().remove(&format!("node:{}:reality-key", de.id)).unwrap();
    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap_err();
    hosts.finish();
    assert_eq!(hosts.uploads(), 0);
    let failed = &error.extra["failed"][0];
    assert_eq!((failed["stage"].as_str(), failed["code"].as_str()), (Some("start"), Some("missing_secret")));
    let message = failed["message"].as_str().unwrap();
    assert!(message.contains("source github-fetch") && message.contains("node delete --name de --scope local"), "{message}");
    assert!(config(&session).nodes[0].operation.is_none());
}

fn warp_output(plus: bool) -> String {
    let key = |seed: char| format!("{}=", seed.to_string().repeat(43));
    format!("private_key={}\npublic_key={}\nipv4=172.16.0.2\nipv6=\nplus={plus}\n", key('A'), key('B'))
}

#[tokio::test(start_paused = true)]
async fn warp_is_registered_before_the_render_and_with_a_new_key_again() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, journal) = fixture(root.path());
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.profiles[0].warp = true;
        state.save_config(&config)
    }).unwrap();
    let de = node(1, "de");
    let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
    assert!(error.extra["plan"].as_array().unwrap().contains(&json!("WARP: будет зарегистрирован аккаунт Cloudflare.")));

    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN),
        ScriptStep::exec(super::super::warp::register_command(false), 1, LONG_TIMEOUT, ok(&warp_output(false)))];
    steps.extend(start_steps(OP));
    steps.push(exec(status_command(OP), "stage=cleanup\nresult=committed\n"));
    let hosts = Hosts::new(vec![steps]);
    let data = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap();
    hosts.finish();
    assert_eq!(data["applied"], json!(["de"]));
    let saved = config(&session);
    let warp = saved.nodes[0].params.warp.clone().unwrap();
    assert_eq!((warp.ipv4.as_str(), warp.plus, warp.plus_attempt), ("172.16.0.2", false, None));
    assert!(session.state.secret_store().get(&format!("node:{}:warp-key", saved.nodes[0].id)).unwrap().is_some());
    assert_eq!(render::status(&saved, &saved.nodes[0]), "applied");

    // A WARP+ key appears: one re-registration (stdin carries the key), it does not bind.
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.profiles[0].warp_plus = Some("0123abcd".into());
        state.secret_store().set("profile:main:warp-license", Zeroizing::new("KEY-123".into()))?;
        state.save_config(&config)
    }).unwrap();
    let node = config(&session).nodes[0].clone();
    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let applied: String = node.applied.as_ref().unwrap().files.iter().map(|(path, hash)| format!("{hash}  {path}\n")).collect();
    let mut steps = vec![connect_step(&node, Ok(())), probe_step(&node, &format!("{DEBIAN}agent=ok\n{applied}")),
        ScriptStep::exec(super::super::warp::register_command(true), "KEY-123\n".len(), LONG_TIMEOUT, ok(&warp_output(false)))];
    steps.extend(start_steps(OP).into_iter().skip(2));
    steps.push(exec(status_command(OP), "stage=cleanup\nresult=committed\n"));
    let hosts = Hosts::new(vec![steps]);
    run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap();
    hosts.finish();
    let saved = config(&session);
    assert_eq!(saved.nodes[0].params.warp.as_ref().unwrap().plus_attempt.as_deref(), Some("0123abcd"));
    assert!(journal.borrow().iter().any(|(level, text)| *level == Level::Warn && text.contains("ключ WARP+ не привязан")));
    assert!(super::super::warp::registration(&saved.profiles[0], &saved.nodes[0]).is_none(), "the same key is not retried");

    // A failed registration fails the node at stage `warp`.
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.nodes[0].params.warp = None;
        state.save_config(&config)
    }).unwrap();
    let node = config(&session).nodes[0].clone();
    let hosts = Hosts::new(vec![vec![connect_step(&node, Ok(())), probe_step(&node, DEBIAN),
        ScriptStep::exec(super::super::warp::register_command(false), "KEY-123\n".len(), LONG_TIMEOUT,
            Ok(ExecResult { exit_status: 1, stderr: b"E: Unable to fetch some archives\n".to_vec(), ..ExecResult::default() }))]]);
    let error = run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap_err();
    assert_eq!(error.extra["failed"][0]["stage"], "warp");
    assert_eq!(error.extra["failed"][0]["message"], "Не удалось зарегистрировать WARP.");
    assert!(journal.borrow().contains(&(Level::Output, "E: Unable to fetch some archives".into())), "the script's diagnostics reach the journal");
    assert_eq!(hosts.uploads(), 0);
}

/// A node transport during whose WARP registration another local process
/// saves a new domain of the node (`config save`).
struct Racing {
    inner: FakeTransport,
    root: std::path::PathBuf,
}

impl crate::transport::RemoteSession for Racing {
    async fn exec(&self, command: &str, stdin: &[u8], timeout: std::time::Duration) -> Result<ExecResult> {
        if command.contains("essence-warp") {
            let state = crate::state::State::new(crate::state::StatePaths::new(&self.root));
            let mut config = state.load_config()?;
            config.nodes[0].domain = Some("other.example.com".into());
            state.save_config(&config)?;
        }
        self.inner.exec(command, stdin, timeout).await
    }

    async fn upload(&self, local_dir: &std::path::Path, remote_dir: &str, timeout: std::time::Duration) -> Result<()> {
        self.inner.upload(local_dir, remote_dir, timeout).await
    }

    async fn upload_private(&self, local_dir: &std::path::Path, remote_dir: &str, timeout: std::time::Duration) -> Result<()> {
        self.inner.upload_private(local_dir, remote_dir, timeout).await
    }
}

impl crate::transport::RemoteTransport for Racing {
    type Held = crate::fake_transport::FakeHeldSession;

    async fn connect(&mut self, options: crate::transport::ConnectOptions) -> Result<()> {
        self.inner.connect(options).await
    }

    fn hold(&self) -> Result<Self::Held> {
        self.inner.hold()
    }
}

#[tokio::test(start_paused = true)]
async fn a_change_during_the_warp_registration_is_a_changed_plan_of_the_command() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.profiles[0].warp = true;
        state.save_config(&config)
    }).unwrap();
    let de = node(1, "de");
    let script = |register: bool| {
        let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)];
        if register {
            steps.push(ScriptStep::exec(super::super::warp::register_command(false), 1, LONG_TIMEOUT, ok(&warp_output(false))));
        }
        FakeTransport::new(steps)
    };
    let racing = RefCell::new(Some(Racing { inner: script(false), root: root.path().to_path_buf() }));
    let connect = || racing.borrow_mut().take().unwrap();
    let error = apply(&mut session, &invocation(&["node", "apply", "--name", "de"]), &connect).await.unwrap_err();
    let token = error.extra["plan_token"].as_str().unwrap().to_owned();

    let transport = script(true);
    let finished = transport.script();
    let racing = RefCell::new(Some(Racing { inner: transport, root: root.path().to_path_buf() }));
    let connect = || racing.borrow_mut().take().unwrap();
    let error = apply(&mut session, &invocation(&["node", "apply", "--name", "de", "--yes", "--plan-token", &token]), &connect)
        .await.unwrap_err();
    finished.assert_finished();
    assert_eq!((error.code, error.exit), ("plan_changed", 2));
    assert!(error.extra["plan"].is_array() && error.extra["plan_token"].is_string() && error.extra.get("failed").is_none(), "{error:?}");
    // The registration saved nothing under the lock: the other change stays alone.
    let saved = config(&session);
    assert_eq!(saved.nodes[0].domain.as_deref(), Some("other.example.com"));
    assert!(saved.nodes[0].params.warp.is_none() && saved.nodes[0].operation.is_none());
}

#[test]
fn a_warp_registration_may_change_only_the_warp_parameters_of_the_confirmed_state() {
    let root = tempfile::tempdir().unwrap();
    let (session, _journal) = fixture(root.path());
    let mut confirmed = config(&session);
    confirmed.profiles[0].warp = true;
    let id = confirmed.nodes[0].id.clone();
    let mut registered = confirmed.clone();
    registered.nodes[0].params.warp = Some(crate::model::NodeWarp {
        public_key: format!("{}=", "B".repeat(43)), ipv4: "172.16.0.2".into(), ipv6: None, plus: false, plus_attempt: None,
    });
    let digest = render::desired(&registered, &registered.nodes[0], None).unwrap().digest;
    assert_ne!(digest, render::desired(&confirmed, &confirmed.nodes[0], None).unwrap().digest);
    assert_eq!(registered_digest(&confirmed, &registered, &id), Some(digest));
    // `config save` of another domain while the registration ran: a new plan.
    let mut changed = registered.clone();
    changed.nodes[0].domain = Some("other.example.com".into());
    assert_eq!(registered_digest(&confirmed, &changed, &id), None);
    let mut gone = registered;
    gone.nodes.clear();
    assert_eq!(registered_digest(&confirmed, &gone, &id), None);
}

#[test]
fn probe_output_parses() {
    let probe = parse_probe("os=\"ubuntu\"\r\nversion=\"26.04\"\nsystemd=yes\nsshd=2222\nagent=ok\nlisten udp 0.0.0.0:51820\nlisten tcp [::]:443\n\
        missing /etc/x\nabababababababababababababababababababababababababababababababab  /etc/y\nunit=active\nstage=config\n");
    assert_eq!((probe.os.as_str(), probe.version.as_str(), probe.systemd, probe.agent_ok, probe.sshd), ("ubuntu", "26.04", true, true, Some(2222)));
    assert_eq!(probe.listening, [("udp".to_owned(), 51820), ("tcp".to_owned(), 443)]);
    assert_eq!(probe.hashes["/etc/x"], None);
    assert_eq!(probe.hashes["/etc/y"].as_deref(), Some("ab".repeat(32).as_str()));
    assert_eq!((probe.status["stage"].as_str(), unit_gone(&probe.status)), ("config", false));
    assert!(parse_probe("sshd=\n").sshd.is_none());
    assert!(unit_gone(&parse_status("unit=inactive\nstage=config\n")) && unit_gone(&parse_status("stage=config\n")));
    assert!(unit_gone(&parse_status("unit=failed\nstage=config\n")));
    // systemd re-executing itself (needrestart in `packages`): no answer is not an exit.
    assert!(!unit_gone(&parse_status("unit=\nstage=packages\n")) && !unit_gone(&parse_status("unit=unknown\nstage=packages\n")));
}

/// An unsupported version or a missing systemd fails the node in the probe,
/// before any plan, naming what was found and what is supported.
#[tokio::test(start_paused = true)]
async fn an_unsupported_os_version_is_refused_before_the_plan() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal) = fixture(root.path());
    let de = node(1, "de");
    let wanted = "нужна Debian 12/13 или Ubuntu 22.04/24.04/26.04 с systemd";
    for (stdout, message) in [
        ("os=ubuntu\nversion=\"25.10\"\nsystemd=yes\n", format!("ОС ноды «ubuntu 25.10» не поддерживается: {wanted}")),
        ("os=debian\nversion=11\nsystemd=yes\n", format!("ОС ноды «debian 11» не поддерживается: {wanted}")),
        ("os=debian\nversion=\nsystemd=yes\n", format!("ОС ноды «debian» не поддерживается: {wanted}")),
        ("", format!("не удалось определить ОС ноды: {wanted}")),
        ("os=ubuntu\nversion=26.04\n", format!("на ноде «ubuntu 26.04» нет systemd: {wanted}")),
    ] {
        let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, stdout)]]);
        let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
        hosts.finish();
        assert_eq!(error.code, "partial", "no plan for {stdout:?}");
        assert_eq!(error.extra["failed"], json!([{"name": "de", "stage": "probe", "code": "unsupported_os", "message": message}]));
    }
    for (id, version, _) in crate::server::os::SUPPORTED_OS {
        let hosts = Hosts::new(vec![vec![connect_step(&de, Ok(())), probe_step(&de, &format!("os={id}\nversion={version}\nsystemd=yes\n"))]]);
        let error = run(&mut session, &hosts, &["node", "apply", "--name", "de"]).await.unwrap_err();
        hosts.finish();
        assert_eq!(error.code, "confirmation_required", "{id} {version}");
    }
}

/// The failure tail drops PEM blocks (also one cut by the start of the read
/// or never closed), ANSI colours and blank lines and puts the executor's
/// warnings and errors first.
#[test]
fn the_log_tail_is_cleaned_and_problems_come_first() {
    let raw = "MIIBcut+off+pem+line\n-----END CERTIFICATE-----\n\
        \u{1b}[36m  [*]\u{1b}[0m Этап: certificate\n\
        [Sat Nov 14] Your cert is in: /root/.acme.sh/x/x.cer\n\
        -----BEGIN CERTIFICATE-----\nMIIFsecret\nAAAA==\n-----END CERTIFICATE-----\n\
        \n\u{1b}[33m  [!]\u{1b}[0m Порт 80 занят\n\
        progress 10%\rprogress 100%\n\
        \u{1b}]8;;https://x\u{7}ссылка\u{1b}]8;;\u{1b}\\\n\
        -----BEGIN RSA PRIVATE KEY-----\nKEYDATA\n\
        \u{1b}[31m  [✗]\u{1b}[0m mihomo -t: ошибка\n\
        [✗] выпуск сертификата не удался\n";
    let tail = log_tail(raw);
    assert_eq!(tail, [
        "[!] Порт 80 занят", "[✗] mihomo -t: ошибка", "[✗] выпуск сертификата не удался",
        "[*] Этап: certificate", "[Sat Nov 14] Your cert is in: /root/.acme.sh/x/x.cer", "progress 100%", "ссылка",
    ]);
    assert!(!tail.iter().any(|line| line.contains("MII") || line.contains("KEYDATA") || line.contains("AAAA")));
    let many: String = (0..60).map(|index| format!("line {index}\n")).collect::<String>()
        + &(0..12).map(|index| format!("  [!] warn {index}\n")).collect::<String>();
    let tail = log_tail(&many);
    assert_eq!(tail.len(), LOG_SHOWN);
    assert_eq!((tail[0].as_str(), tail[9].as_str()), ("[!] warn 2", "[!] warn 11"));
    // Older problems beyond the first ten stay among the last lines, in order.
    assert_eq!((tail[10].as_str(), tail[22].as_str(), tail[24].as_str()), ("line 47", "line 59", "[!] warn 1"));
}

#[test]
fn a_foreign_listener_on_the_tproxy_port_is_busy_until_it_is_ours() {
    let probe = parse_probe("listen tcp 127.0.0.1:23456\n");
    let desired = Desired { teardown: false, files: Vec::new(), remove: Vec::new(), spec: Vec::new(), ports: vec!["443/tcp".into()],
        listen: vec!["443/tcp".into(), "23456/tcp".into(), "23456/udp".into()], lines: Vec::new(), digest: String::new() };
    let mut node = Node::default();
    let failure = busy_port(&probe, &node, &desired).unwrap();
    assert_eq!((failure.code.as_str(), failure.port), ("port_busy", Some(23456)));
    node.applied = Some(Applied { digest: String::new(), files: Default::default(), ports: desired.listen.clone(), at: String::new() });
    assert!(busy_port(&probe, &node, &desired).is_none(), "our own mihomo holds it");
}

/// Status lines become one live line per second (the time ticks even when
/// the status repeats), the percent never goes back, the detail is cleaned,
/// and the journal still gets one line per stage only.
#[tokio::test(start_paused = true)]
async fn status_progress_becomes_a_live_line_without_journal_spam() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, journal, live) = fixture_live(root.path());
    let de = node(1, "de");
    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)];
    steps.extend(start_steps(OP));
    for status in [
        "stage=packages\nprogress=5\ndetail=обновление списков пакетов\n",
        "stage=packages\nprogress=12\ndetail=nginx: распаковка\n",
        // A lower percent never moves the line back; controls are cut.
        "stage=packages\nprogress=9\ndetail=nginx: \u{1b}[31mнастройка\u{7}\n",
        "stage=packages\nprogress=9\ndetail=nginx: \u{1b}[31mнастройка\u{7}\n",
        "stage=certificate\nprogress=47\ndetail=выпуск сертификата de.example.com\n",
    ] {
        steps.push(exec(status_command(OP), &format!("{LIVE}{status}")));
    }
    steps.push(exec(status_command(OP), "unit=inactive\nstage=cleanup\nprogress=100\nresult=committed\n"));
    let hosts = Hosts::new(vec![steps]);
    run(&mut session, &hosts, &["node", "apply", "--name", "de", "--yes"]).await.unwrap();
    hosts.finish();

    let lines = live.borrow().clone();
    let texts: Vec<&str> = lines.iter().map(|(_, _, text)| text.as_str()).collect();
    assert_eq!(texts.len(), 10, "two lines per poll until the commit: {texts:#?}");
    assert_eq!(texts[0], "Нода de: 5 % · этап 1/10 «установка пакетов» · обновление списков пакетов · 0:00");
    assert_eq!(texts[2], "Нода de: 12 % · этап 1/10 «установка пакетов» · nginx: распаковка · 0:02");
    assert_eq!(texts[4], "Нода de: 12 % · этап 1/10 «установка пакетов» · nginx: [31mнастройка · 0:04");
    assert_eq!(texts[8], "Нода de: 47 % · этап 6/10 «сертификаты» · выпуск сертификата de.example.com · 0:08");
    // The elapsed time ticks every second, also while the status repeats.
    let clocks: Vec<&str> = texts.iter().map(|text| text.rsplit(" · ").next().unwrap()).collect();
    assert_eq!(clocks, ["0:00", "0:01", "0:02", "0:03", "0:04", "0:05", "0:06", "0:07", "0:08", "0:09"]);
    let percents: Vec<u8> = lines.iter().map(|(_, percent, _)| *percent).collect();
    assert!(percents.windows(2).all(|pair| pair[0] <= pair[1]), "monotonic: {percents:?}");

    let journal = journal.borrow();
    let stages: Vec<&str> = journal.iter().map(|(_, text)| text.as_str()).filter(|text| text.starts_with("de: ")).collect();
    assert_eq!(stages, ["de: исполнитель загружен", "de: применение запущено", "de: установка пакетов", "de: сертификаты",
        "de: очистка", "de: применено"]);
    assert!(journal.iter().all(|(_, text)| !text.contains('%') && !text.contains("распаковка")), "{journal:?}");
}

/// A node transport whose first status reply (operation [`OP`]) takes `delay`.
struct Slow {
    inner: FakeTransport,
    delay: std::time::Duration,
    delayed: std::cell::Cell<bool>,
}

impl Slow {
    fn new(inner: FakeTransport, delay: std::time::Duration) -> Self {
        Self { inner, delay, delayed: std::cell::Cell::new(false) }
    }
}

impl crate::transport::RemoteSession for Slow {
    async fn exec(&self, command: &str, stdin: &[u8], timeout: std::time::Duration) -> Result<ExecResult> {
        if command == status_command(OP) && !self.delayed.replace(true) {
            tokio::time::sleep(self.delay).await;
        }
        self.inner.exec(command, stdin, timeout).await
    }

    async fn upload(&self, local_dir: &std::path::Path, remote_dir: &str, timeout: std::time::Duration) -> Result<()> {
        self.inner.upload(local_dir, remote_dir, timeout).await
    }

    async fn upload_private(&self, local_dir: &std::path::Path, remote_dir: &str, timeout: std::time::Duration) -> Result<()> {
        self.inner.upload_private(local_dir, remote_dir, timeout).await
    }
}

impl crate::transport::RemoteTransport for Slow {
    type Held = crate::fake_transport::FakeHeldSession;

    async fn connect(&mut self, options: crate::transport::ConnectOptions) -> Result<()> {
        self.inner.connect(options).await
    }

    fn hold(&self) -> Result<Self::Held> {
        self.inner.hold()
    }
}

/// While a status request waits for the node, the live line still comes
/// every second: the elapsed time moves, the state is the last one seen.
#[tokio::test(start_paused = true)]
async fn the_live_line_ticks_while_a_status_reply_is_awaited() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal, live) = fixture_live(root.path());
    let de = node(1, "de");
    NEXT_OP_ID.with(|next| *next.borrow_mut() = Some(OP.into()));
    let mut steps = vec![connect_step(&de, Ok(())), probe_step(&de, DEBIAN)];
    steps.extend(start_steps(OP));
    steps.push(exec(status_command(OP), &format!("{LIVE}stage=packages\nprogress=5\n")));
    steps.push(exec(status_command(OP), "unit=inactive\nstage=cleanup\nprogress=100\nresult=committed\n"));
    let transport = FakeTransport::new(steps);
    let script = transport.script();
    let slow = RefCell::new(Some(Slow::new(transport, Duration::from_secs(5))));
    let connect = || slow.borrow_mut().take().unwrap();
    apply(&mut session, &invocation(&["node", "apply", "--name", "de", "--yes"]), &connect).await.unwrap();
    script.assert_finished();

    let lines = live.borrow().clone();
    let texts: Vec<&str> = lines.iter().map(|(_, _, text)| text.as_str()).collect();
    let waiting: Vec<&str> = texts.iter().take_while(|text| !text.contains("5 %")).copied().collect();
    assert_eq!(waiting.len(), 4, "a line per second of the 5 s wait: {texts:#?}");
    let clocks: Vec<&str> = waiting.iter().map(|text| text.rsplit(" · ").next().unwrap()).collect();
    assert_eq!(clocks, ["0:01", "0:02", "0:03", "0:04"]);
    assert!(waiting.iter().all(|text| text.starts_with("Нода de: 0 %")), "{waiting:?}");
    assert_eq!(texts[4].rsplit(" · ").next(), Some("0:05"), "{texts:#?}");
}

/// One ticker serves a whole round of polls: replies shorter than a second
/// each, longer than a second together, still move the live line.
#[tokio::test(start_paused = true)]
async fn the_live_line_ticks_across_polls_shorter_than_a_second() {
    let root = tempfile::tempdir().unwrap();
    let (mut session, _journal, live) = fixture_live(root.path());
    let (de, nl) = (node(1, "de"), node(2, "nl"));
    let committed = "unit=inactive\nstage=cleanup\nprogress=100\nresult=committed\n";
    let transport = |node: &Node| FakeTransport::new(vec![connect_step(node, Ok(())), exec(status_command(OP), committed)]);
    let (first, second) = (transport(&de), transport(&nl));
    let scripts = [first.script(), second.script()];
    let (mut first, mut second) = (Slow::new(first, Duration::from_millis(900)), Slow::new(second, Duration::from_millis(900)));
    nodes::connect(&mut first, &session.state, &de).await.unwrap();
    nodes::connect(&mut second, &session.state, &nl).await.unwrap();
    let operation = || crate::model::Operation { id: OP.into(), ..Default::default() };
    let mut runs = vec![Run::new(de, &mut first, operation()), Run::new(nl, &mut second, operation())];
    drive(&mut session, &mut runs).await;
    assert!(runs.iter().all(|run| matches!(run.outcome, Some(Outcome::Committed))));
    drop(runs);
    scripts.iter().for_each(FakeScript::assert_finished);
    // de answers at 0.9 s, nl at 1.8 s: the line of the first second comes during nl's poll.
    let lines = live.borrow().clone();
    let clocks: Vec<&str> = lines.iter().map(|(_, _, text)| text.rsplit(" · ").next().unwrap()).collect();
    assert_eq!(clocks, ["0:01"], "{lines:#?}");
}

#[test]
fn several_nodes_share_one_live_line() {
    let operation = |teardown| crate::model::Operation { id: OP.into(), teardown, ..Default::default() };
    let (mut first, mut second, mut third) = (FakeTransport::new(vec![]), FakeTransport::new(vec![]), FakeTransport::new(vec![]));
    let mut runs = vec![
        Run::new(node(1, "de"), &mut first, operation(false)),
        Run::new(node(2, "nl"), &mut second, operation(false)),
        Run::new(node(3, "fi"), &mut third, operation(false)),
    ];
    let started = runs[0].started;
    (runs[0].stage, runs[0].percent, runs[0].detail) = ("packages".into(), 37, "nginx: распаковка".into());
    (runs[1].stage, runs[1].percent) = ("certificate".into(), 71);
    runs[2].outcome = Some(Outcome::Committed);
    let (percent, text) = live_line(&runs, started + Duration::from_secs(102)).unwrap();
    assert_eq!(percent, 69);
    assert_eq!(text, "Ноды: 69 % · готово 1/3 · de 37 % «установка пакетов» · nl 71 % «сертификаты» · 1:42");
    runs[1].lost = Some((started, 0, started));
    assert!(live_line(&runs, started).unwrap().1.contains("nl 71 % нет связи"));
    // A failed node is «ошибка»: neither done nor in the mean.
    runs[1].lost = None;
    runs[2].outcome = Some(Outcome::Failed(Failure { stage: "packages".into(), code: "start".into(), message: String::new(), port: None, extra: Vec::new() }));
    let (percent, text) = live_line(&runs, started + Duration::from_secs(102)).unwrap();
    assert_eq!(percent, 54);
    assert_eq!(text, "Ноды: 54 % · готово 0/3 · ошибка: fi · de 37 % «установка пакетов» · nl 71 % «сертификаты» · 1:42");

    // One node: stage of its own list; teardown counts its three stages.
    let mut fourth = FakeTransport::new(vec![]);
    let mut teardown = Run::new(node(1, "de"), &mut fourth, operation(true));
    teardown.stage = "firewall".into();
    let line = live_line(std::slice::from_ref(&teardown), teardown.started).unwrap().1;
    assert_eq!(line, "Нода de: 0 % · этап 2/3 «правила UFW» · 0:00");
    teardown.stage.clear();
    assert!(live_line(std::slice::from_ref(&teardown), teardown.started).unwrap().1.contains("«запуск исполнителя»"));
    assert!(live_line::<FakeTransport>(&[], teardown.started).is_none());
}

#[test]
fn details_are_cut_and_cleaned() {
    assert_eq!(clean_detail(" a\u{0}b\u{9b}c\r "), "abc");
    let long = "д".repeat(300);
    assert_eq!(clean_detail(&long).chars().count(), DETAIL_MAX);
}
