//! `awg status|sync|remove` (port of `awg_peers.sh` and the awg handlers of
//! `cmd_nodes.sh`): AmneziaWG peers on a node compared with the clients that
//! use AmneziaWG there. Peers are created and removed by the server module
//! `amneziawg.sh`; the local state never changes.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use crate::cli::Invocation;
use crate::clients::{client_nodes, require_one, unique_values};
use crate::clients::generate::effective_connections;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::locking::LockKind;
use crate::log::Level;
use crate::model::{Client, Config, Node};
use crate::nodes::scripts::{self, REMOTE_DIR};
use crate::nodes::{self, COMMAND_TIMEOUT, LONG_TIMEOUT, find, required, sh_quote};
use crate::request_secrets::Secrets;
use crate::transport::RemoteTransport;

/// `NO_AWG`, or `AWG_OK` followed by the peer directories.
pub const STATUS_COMMAND: &str =
    "if [ ! -f /etc/amnezia/amneziawg/awg0.conf ]; then echo NO_AWG; else echo AWG_OK; ls /etc/mihomo/amnezia/; fi";

/// AmneziaWG on a node, as reported by `STATUS_COMMAND`.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Probe {
    Absent,
    Installed(Vec<String>),
}

/// `None` for any other answer. CR and trailing newlines are dropped.
pub(crate) fn parse_probe(stdout: &[u8]) -> Option<Probe> {
    let text = String::from_utf8_lossy(stdout).replace('\r', "");
    let text = text.trim_end_matches('\n');
    if text == "NO_AWG" {
        return Some(Probe::Absent);
    }
    let rest = if text == "AWG_OK" { "" } else { text.strip_prefix("AWG_OK\n")? };
    Some(Probe::Installed(rest.split('\n').filter(|line| !line.is_empty()).map(str::to_owned).collect()))
}

fn module() -> String {
    sh_quote(&format!("{REMOTE_DIR}/modules/amneziawg.sh"))
}

/// Create the named peers; the first failure stops.
pub(crate) fn create_command(peers: &[String]) -> String {
    peers.iter().fold(format!("source {}", module()), |command, peer| {
        format!("{command} && add_awg_peer_auto {}", sh_quote(peer))
    })
}

fn remove_command(peers: &[String]) -> String {
    peers.iter().fold(format!("source {}", module()), |command, peer| {
        format!("{command} && remove_awg_peer_by_name {}", sh_quote(peer))
    })
}

/// The client is assigned to the node and the connections it uses there
/// (its own, else its group's) include AmneziaWG.
pub(crate) fn needs_peer(config: &Config, client: &Client, node: &str) -> bool {
    client_nodes(config, client).iter().any(|assigned| assigned == node)
        && effective_connections(config, client, node).iter().any(|proxy| proxy == "AWG" || proxy.starts_with("awg-"))
}

/// Sorted names of the clients that need a peer on the node.
pub fn expected_peers(config: &Config, node: &str) -> Vec<String> {
    config.clients.iter().filter(|client| needs_peer(config, client, node))
        .map(|client| client.name.clone()).collect::<BTreeSet<_>>().into_iter().collect()
}

/// Node peers first (`used` | `orphan`), then expected ones not on the node (`missing`).
fn classify(existing: &[String], expected: &[String]) -> Vec<(String, &'static str)> {
    let mut peers: Vec<(String, &'static str)> = existing.iter()
        .map(|peer| (peer.clone(), if expected.contains(peer) { "used" } else { "orphan" })).collect();
    peers.extend(expected.iter().filter(|peer| !existing.contains(peer)).map(|peer| (peer.clone(), "missing")));
    peers
}

fn names_with<'a>(peers: &'a [(String, &'static str)], state: &str) -> Vec<&'a str> {
    peers.iter().filter(|(_, s)| *s == state).map(|(name, _)| name.as_str()).collect()
}

/// Connect and classify; `None` when AmneziaWG is not installed.
async fn status_of<T: RemoteTransport>(session: &Session, config: &Config, node: &Node, transport: &mut T)
    -> Result<Option<Vec<(String, &'static str)>>>
{
    nodes::require_portable(session, node)?;
    nodes::connect(transport, &session.state, node).await?;
    let failed = || RcError::new("remote_failed", format!("Не удалось получить статус AmneziaWG на «{}».", node.name))
        .with_extra("name", node.name.clone());
    let result = transport.exec(STATUS_COMMAND, b"", COMMAND_TIMEOUT).await.map_err(|error| match error.extra.get("reason") {
        Some(reason) => failed().with_extra("reason", reason.clone()),
        None => failed(),
    })?;
    if result.exit_status != 0 {
        return Err(failed().with_extra("exit_status", result.exit_status));
    }
    match parse_probe(&result.stdout) {
        None => Err(RcError::new("remote_failed", format!("Неожиданный ответ о статусе AmneziaWG на «{}».", node.name))
            .with_extra("name", node.name.clone())),
        Some(Probe::Absent) => Ok(None),
        Some(Probe::Installed(existing)) => Ok(Some(classify(&existing, &expected_peers(config, &node.name)))),
    }
}

/// Scripts current, then one remote command, under the mutation lock.
async fn change<T: RemoteTransport>(session: &mut Session, transport: &T, node: &Node, command: &str, failure: String) -> Result<()> {
    let _guard = session.state.locks().acquire(LockKind::Mutation, "awg_peers")?;
    let failed = || RcError::new("remote_failed", failure.clone()).with_extra("name", node.name.clone());
    if let Err(error) = scripts::ensure_current(transport, &node.name, false).await {
        session.log(Level::Warn, &format!("Не удалось подготовить скрипты для ноды «{}»: {}", node.name, error.message));
        return Err(failed().with_extra("cause", error.code));
    }
    match transport.exec(command, b"", LONG_TIMEOUT).await {
        Ok(result) if result.exit_status == 0 => Ok(()),
        Ok(result) => Err(failed().with_extra("exit_status", result.exit_status)),
        Err(error) => Err(match error.extra.get("reason") {
            Some(reason) => failed().with_extra("reason", reason.clone()),
            None => failed(),
        }),
    }
}

/// Dispatch of the domain's commands; `connect` creates a fresh transport per node.
pub async fn route<T: RemoteTransport>(noun: &str, verb: &str, invocation: &Invocation, secrets: &Secrets,
    session: &mut Session, connect: &dyn Fn() -> T) -> Result<Value>
{
    let _ = (noun, secrets);
    match verb {
        "status" => status(session, invocation, connect).await,
        "sync" => sync(session, invocation, connect).await,
        "remove" => remove(session, invocation, connect).await,
        _ => Err(RcError::new("usage", "Неизвестная команда.")),
    }
}

/// `awg status --name N`.
pub async fn status<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T) -> Result<Value> {
    let name = required(invocation, "name")?;
    let config = session.state.load_config()?;
    let node = find(&config, name)?;
    let peers = status_of(session, &config, node, &mut connect()).await?;
    let installed = peers.is_some();
    let peers: Vec<Value> = peers.unwrap_or_default().into_iter().map(|(name, status)| json!({"name": name, "status": status})).collect();
    Ok(json!({"installed": installed, "peers": peers}))
}

/// `awg sync --name N`: create the missing peers.
pub async fn sync<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T) -> Result<Value> {
    let name = required(invocation, "name")?;
    let config = session.state.load_config()?;
    let node = find(&config, name)?;
    let mut transport = connect();
    let Some(peers) = status_of(session, &config, node, &mut transport).await? else {
        return Err(RcError::new("invalid", format!("AmneziaWG не установлен на ноде «{name}».")).with_extra("name", name));
    };
    let missing: Vec<String> = names_with(&peers, "missing").into_iter().map(str::to_owned).collect();
    if missing.is_empty() {
        session.log(Level::Info, "Все клиенты AmneziaWG уже созданы.");
    } else {
        change(session, &transport, node, &create_command(&missing), format!("Не удалось создать клиентов AmneziaWG на «{name}».")).await?;
        session.log(Level::Success, &format!("Клиенты AmneziaWG созданы на {name}: {}", missing.join(" ")));
    }
    Ok(json!({"created": missing}))
}

/// `awg remove --name N (--peer P… | --orphans)`: peers must exist on the
/// node; the plan is confirmed before any remote change.
pub async fn remove<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T) -> Result<Value> {
    let name = required(invocation, "name")?;
    require_one(invocation, &["peer", "orphans"])?;
    let config = session.state.load_config()?;
    let node = find(&config, name)?;
    let mut transport = connect();
    let status = status_of(session, &config, node, &mut transport).await?;
    let peers = if invocation.has("orphans") {
        status.as_deref().map(|peers| names_with(peers, "orphan").into_iter().map(str::to_owned).collect()).unwrap_or_default()
    } else {
        unique_values(invocation, "peer")
    };
    if peers.is_empty() {
        session.log(Level::Info, "Удалять нечего.");
        return Ok(json!({"removed": []}));
    }
    let Some(status) = status else {
        return Err(RcError::new("invalid", format!("AmneziaWG не установлен на «{name}».")).with_extra("name", name));
    };
    if let Some(peer) = peers.iter().find(|peer| !status.iter().any(|(n, s)| n == *peer && *s != "missing")) {
        return Err(RcError::new("invalid", format!("Клиент «{peer}» ещё не создан на ноде.")).with_extra("peer", peer.clone()));
    }
    Plan::new(vec![
        format!("Нода: {name} ({}:{})", node.ip, node.port),
        format!("Клиенты: {}", peers.join(" ")),
        "Ключи будут удалены, доступ прекратится.".to_owned(),
    ], "").confirm(invocation)?;
    change(session, &transport, node, &remove_command(&peers), format!("Не удалось удалить клиентов AmneziaWG на «{name}».")).await?;
    session.log(Level::Success, &format!("Клиенты AmneziaWG удалены на {name}: {}", peers.join(" ")));
    Ok(json!({"removed": peers}))
}

/// Remove peers by name in one command (client rename/delete/set-group);
/// a missing peer or AmneziaWG not installed is not a failure.
pub async fn remove_peers<T: RemoteTransport>(session: &mut Session, node: &str, peers: &[String], connect: &dyn Fn() -> T) -> Result<()> {
    let failed = |message: String| RcError::new("remote_failed", message).with_extra("name", node);
    let config = session.state.load_config()?;
    let Some(stored) = config.nodes.iter().find(|stored| stored.name == node) else {
        let message = format!("{node}: не удалось подготовить удаление клиентов AmneziaWG.");
        session.log(Level::Warn, &message);
        return Err(failed(message));
    };
    let _guard = session.state.locks().acquire(LockKind::Mutation, "awg_peers")?;
    let mut transport = connect();
    let prepared = match nodes::require_portable(session, stored) {
        Ok(()) => match nodes::connect(&mut transport, &session.state, stored).await {
            Ok(()) => scripts::ensure_current(&transport, node, false).await.map(drop),
            Err(error) => Err(error),
        },
        Err(error) => Err(error),
    };
    if let Err(error) = prepared {
        let message = format!("{node}: не удалось подготовить удаление клиентов AmneziaWG.");
        session.log(Level::Warn, &format!("{message} {}", error.message));
        return Err(failed(message).with_extra("cause", error.code));
    }
    let command = peers.iter().fold(
        format!("[ -f /etc/amnezia/amneziawg/awg0.conf ] || exit 0; source {} || exit 1; _remove_rc=0", module()),
        |command, peer| format!("{command}; remove_awg_peer_by_name {} || _remove_rc=1", sh_quote(peer)),
    ) + "; exit \"$_remove_rc\"";
    match transport.exec(&command, b"", LONG_TIMEOUT).await {
        Ok(result) if result.exit_status == 0 => Ok(()),
        _ => {
            let message = format!("{node}: не удалось удалить всех клиентов AmneziaWG.");
            session.log(Level::Warn, &message);
            Err(failed(message))
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use super::*;
    use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeTransport, ScriptStep};
    use crate::model::{Auth, ClientConnection, Connection, ConnectionGroup, Fingerprint, Group};
    use crate::nodes::testing::{fingerprint, invocation, session};
    use crate::nodes::{CONNECT_TIMEOUT, pin};
    use crate::transport::{ExecResult, HostKeyPolicy};

    fn fp() -> Fingerprint {
        format!("SHA256:{}A", "Q".repeat(42)).parse().unwrap()
    }

    fn de() -> Node {
        Node {
            id: "0123456789abcdef0123456789abcdef".into(), name: "de".into(), ip: "198.51.100.7".into(), port: 22,
            user: "root".into(), auth: Auth::Key, identity: Some("system".into()), secret_id: None, tag: None, aliases: Default::default(),
        }
    }

    /// alpha uses AWG via its group, beta via its own connections, gamma's
    /// own connections override the group's AWG.
    fn seeded(root: &std::path::Path) -> Session {
        let (session, _) = session(root);
        let own = |name: &str, proxies: &[&str]| Client {
            name: name.into(), group: "PC".into(), inherit_nodes_from_group: false, nodes: Some(vec!["de".into()]),
            connections: Some(vec![ClientConnection { node: "de".into(), proxies: proxies.iter().map(|p| p.to_string()).collect() }]),
            ..Client::default()
        };
        let config = Config {
            nodes: vec![de()],
            groups: vec![Group { name: "PC".into(), ..Group::default() }],
            clients: vec![Client { name: "alpha".into(), group: "PC".into(), ..Client::default() },
                own("beta", &["AWG"]), own("gamma", &["vless"])],
            connections: vec![Connection { node: "de".into(), groups: vec![ConnectionGroup { name: "PC".into(), proxies: vec!["AWG".into()] }] }],
            ..Config::default()
        };
        session.state.save_config(&config).unwrap();
        pin(&session.state, "198.51.100.7", 22, vec![fp()]).unwrap();
        session
    }

    fn ok(stdout: &str) -> Result<ExecResult> {
        Ok(ExecResult { stdout: stdout.as_bytes().to_vec(), stderr: Vec::new(), exit_status: 0 })
    }

    fn connect_step() -> ScriptStep {
        ScriptStep::connect(ConnectExpectation::new("198.51.100.7", 22, "root", AuthMethod::System, CONNECT_TIMEOUT)
            .with_host_key(HostKeyPolicy { expected: None, known: vec![fp()] }), Ok(()))
    }

    fn status_step(stdout: &str) -> ScriptStep {
        ScriptStep::exec(STATUS_COMMAND, 0, COMMAND_TIMEOUT, ok(stdout))
    }

    fn probe_step() -> ScriptStep {
        ScriptStep::exec(scripts::probe_command(), 0, COMMAND_TIMEOUT, ok(&format!("PRESENT\n{}\n", scripts::local_version().unwrap())))
    }

    fn transport(steps: Vec<ScriptStep>) -> (crate::fake_transport::FakeScript, RefCell<Option<FakeTransport>>) {
        let transport = FakeTransport::new(steps);
        (transport.script(), RefCell::new(Some(transport)))
    }

    #[test]
    fn probe_parsing_and_expected_peers() {
        assert_eq!(parse_probe(b"NO_AWG\r\n"), Some(Probe::Absent));
        assert_eq!(parse_probe(b"AWG_OK\n"), Some(Probe::Installed(vec![])));
        assert_eq!(parse_probe(b"AWG_OK\r\nalpha\r\n\norphan1\n"), Some(Probe::Installed(vec!["alpha".into(), "orphan1".into()])));
        assert_eq!(parse_probe(b"bash: ls: denied\n"), None);
        let root = tempfile::tempdir().unwrap();
        let session = seeded(root.path());
        assert_eq!(expected_peers(&session.state.load_config().unwrap(), "de"), ["alpha", "beta"]);
        assert_eq!(create_command(&["a b".into(), "c".into()]),
            "source '/root/essence-setup/modules/amneziawg.sh' && add_awg_peer_auto 'a b' && add_awg_peer_auto 'c'");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn status_classifies_used_orphan_and_missing_peers() {
        let root = tempfile::tempdir().unwrap();
        let mut session = seeded(root.path());
        let (script, cell) = transport(vec![connect_step(), status_step("AWG_OK\nalpha\norphan1\n")]);
        let connect = || cell.borrow_mut().take().unwrap();
        let data = status(&mut session, &invocation(&["awg", "status", "--name", "de"]), &connect).await.unwrap();
        script.assert_finished();
        assert_eq!(data, json!({"installed": true, "peers": [{"name": "alpha", "status": "used"},
            {"name": "orphan1", "status": "orphan"}, {"name": "beta", "status": "missing"}]}));

        let (_, cell) = transport(vec![connect_step(), ScriptStep::exec(STATUS_COMMAND, 0, COMMAND_TIMEOUT,
            Ok(ExecResult { exit_status: 255, ..ExecResult::default() }))]);
        let connect = || cell.borrow_mut().take().unwrap();
        let error = status(&mut session, &invocation(&["awg", "status", "--name", "de"]), &connect).await.unwrap_err();
        assert_eq!((error.code, error.message.as_str()), ("remote_failed", "Не удалось получить статус AmneziaWG на «de»."));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn sync_creates_only_missing_peers() {
        let root = tempfile::tempdir().unwrap();
        let mut session = seeded(root.path());
        let before = fingerprint(root.path());
        let (script, cell) = transport(vec![connect_step(), status_step("AWG_OK\nalpha\norphan1\n"), probe_step(),
            ScriptStep::exec(create_command(&["beta".into()]), 0, LONG_TIMEOUT, ok(""))]);
        let connect = || cell.borrow_mut().take().unwrap();
        let data = sync(&mut session, &invocation(&["awg", "sync", "--name", "de"]), &connect).await.unwrap();
        script.assert_finished();
        assert_eq!(data, json!({"created": ["beta"]}));
        assert_eq!(fingerprint(root.path()), before);

        let (_, cell) = transport(vec![connect_step(), status_step("NO_AWG\n")]);
        let connect = || cell.borrow_mut().take().unwrap();
        let error = sync(&mut session, &invocation(&["awg", "sync", "--name", "de"]), &connect).await.unwrap_err();
        assert_eq!((error.code, error.message.as_str()), ("invalid", "AmneziaWG не установлен на ноде «de»."));

        let (script, cell) = transport(vec![connect_step(), status_step("AWG_OK\nalpha\nbeta\n")]);
        let connect = || cell.borrow_mut().take().unwrap();
        let data = sync(&mut session, &invocation(&["awg", "sync", "--name", "de"]), &connect).await.unwrap();
        script.assert_finished();
        assert_eq!(data, json!({"created": []}));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn remove_requires_confirmation_and_existing_peers() {
        let root = tempfile::tempdir().unwrap();
        let mut session = seeded(root.path());
        let before = fingerprint(root.path());
        let (script, cell) = transport(vec![connect_step(), status_step("AWG_OK\nalpha\norphan1\n")]);
        let connect = || cell.borrow_mut().take().unwrap();
        let error = remove(&mut session, &invocation(&["awg", "remove", "--name", "de", "--orphans"]), &connect).await.unwrap_err();
        script.assert_finished();
        assert_eq!((error.code, error.exit_code()), ("confirmation_required", 2));
        assert_eq!(error.extra["plan"], json!(["Нода: de (198.51.100.7:22)", "Клиенты: orphan1", "Ключи будут удалены, доступ прекратится."]));
        assert_eq!(fingerprint(root.path()), before);

        let (script, cell) = transport(vec![connect_step(), status_step("AWG_OK\nalpha\norphan1\n"), probe_step(),
            ScriptStep::exec(remove_command(&["orphan1".into()]), 0, LONG_TIMEOUT, ok(""))]);
        let connect = || cell.borrow_mut().take().unwrap();
        let data = remove(&mut session, &invocation(&["awg", "remove", "--name", "de", "--orphans", "--yes"]), &connect).await.unwrap();
        script.assert_finished();
        assert_eq!(data, json!({"removed": ["orphan1"]}));

        let (_, cell) = transport(vec![connect_step(), status_step("AWG_OK\nalpha\n")]);
        let connect = || cell.borrow_mut().take().unwrap();
        let error = remove(&mut session, &invocation(&["awg", "remove", "--name", "de", "--peer", "beta", "--yes"]), &connect).await.unwrap_err();
        assert_eq!((error.code, error.message.as_str()), ("invalid", "Клиент «beta» ещё не создан на ноде."));

        let connect = FakeTransport::default;
        for argv in [&["awg", "remove", "--name", "de"][..], &["awg", "remove", "--name", "de", "--peer", "a", "--orphans"]] {
            assert_eq!(remove(&mut session, &invocation(argv), &connect).await.unwrap_err().code, "usage");
        }
        assert_eq!(fingerprint(root.path()), before);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn remove_peers_tolerates_missing_awg_and_reports_failures() {
        let root = tempfile::tempdir().unwrap();
        let mut session = seeded(root.path());
        let command = "[ -f /etc/amnezia/amneziawg/awg0.conf ] || exit 0; source '/root/essence-setup/modules/amneziawg.sh' || exit 1; \
            _remove_rc=0; remove_awg_peer_by_name 'alpha' || _remove_rc=1; exit \"$_remove_rc\"";
        let (script, cell) = transport(vec![connect_step(), probe_step(), ScriptStep::exec(command, 0, LONG_TIMEOUT, ok(""))]);
        let connect = || cell.borrow_mut().take().unwrap();
        remove_peers(&mut session, "de", &["alpha".into()], &connect).await.unwrap();
        script.assert_finished();

        let (_, cell) = transport(vec![connect_step(), probe_step(),
            ScriptStep::exec(command, 0, LONG_TIMEOUT, Ok(ExecResult { exit_status: 1, ..ExecResult::default() }))]);
        let connect = || cell.borrow_mut().take().unwrap();
        let error = remove_peers(&mut session, "de", &["alpha".into()], &connect).await.unwrap_err();
        assert_eq!((error.code, error.message.as_str()), ("remote_failed", "de: не удалось удалить всех клиентов AmneziaWG."));
    }
}
