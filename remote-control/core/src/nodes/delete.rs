//! `node delete` (v1 `core_node_delete_plan` + `core_node_delete`).
//!
//! Remote work runs only after the plan is confirmed. Before the managed key
//! is revoked, the authenticated
//! connection is held as a recovery lease (v2's replacement for v1's private
//! ControlMaster socket): if anything later fails while the node is kept, the
//! revoked key is put back through that lease and a fresh login verifies it.
//! The state change is one `Session::mutate` transaction: node, its
//! connections, client references, cascades through it, its Telegram Proxy,
//! `subscription_host` (if it named the node), every `node:<id>:*` secret,
//! host pins (unless another node shares the endpoint), portability issues
//! and, last, the managed identity files.

use std::io::ErrorKind;
use std::path::PathBuf;

use serde_json::{Value, json};

use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result, exit_code_for};
use crate::log::Level;
use crate::model::{Cascade, CascadeExit, Config, Node, PortabilityReason};
use crate::state::State;
use crate::transport::{RemoteSession, RemoteTransport};

use super::add::transaction_files;
use super::setup::{self, FileBackup};
use super::{COMMAND_TIMEOUT, connect, connect_options, find, is_github, pin, pins, require_portable,
    required, set_issue, sh_quote};

/// v1 `_node_delete_scope_label`.
pub fn scope_label(server: bool, revoke: bool) -> &'static str {
    match (server, revoke) {
        (false, false) => "Удалить только из remote-control; сервер и SSH-ключ оставить",
        (false, true) => "Удалить из remote-control и отозвать управляемый SSH-ключ",
        (true, false) => "Удалить из remote-control и все компоненты Essence на сервере",
        (true, true) => "Удалить из remote-control, все компоненты Essence и отозвать SSH-ключ",
    }
}

/// Clients whose proxies include the node: explicit node lists, explicit
/// connections, or group inheritance through the node's connection groups.
fn affected_clients<'a>(config: &'a Config, name: &str) -> Vec<&'a str> {
    let groups: Vec<&str> = config.connections.iter().filter(|connection| connection.node == name)
        .flat_map(|connection| connection.groups.iter().map(|group| group.name.as_str())).collect();
    config.clients.iter().filter(|client| {
        client.nodes.as_ref().is_some_and(|nodes| nodes.iter().any(|node| node == name))
            || client.connections.as_ref().is_some_and(|list| list.iter().any(|connection| connection.node == name))
            || (client.inherit_nodes_from_group && groups.contains(&client.group.as_str()))
    }).map(|client| client.name.as_str()).collect()
}

fn plan(config: &Config, node: &Node, server: bool, revoke: bool) -> Vec<String> {
    let affected = affected_clients(config, &node.name);
    let mut lines = vec![
        format!("Нода: {}  {}:{}", node.name, node.ip, node.port),
        format!("Пользователь: {}", node.user),
        format!("Объём: {}", scope_label(server, revoke)),
        format!("Затронутые клиенты: {}", if affected.is_empty() { "нет".to_owned() } else { affected.join(" ") }),
    ];
    if server {
        match node.applied {
            Some(_) => lines.extend(crate::server::render::teardown(node).lines.into_iter().skip(1)),
            None => lines.push("Essence на ноду не применялся: сервер не изменится.".to_owned()),
        }
        lines.push("Пакеты, acme.sh и UFW остаются; SSH-доступ сохранится.".to_owned());
    }
    if config.subscription_host.as_ref().is_some_and(|host| host.node == node.name) {
        lines.push("Хостинг подписок размещён на этой ноде: его настройка (subscription_host) будет удалена.".to_owned());
    }
    let cascades: Vec<&str> = config.cascades.iter().filter(|cascade| cascade_uses(cascade, &node.name))
        .map(|cascade| cascade.name.as_str()).collect();
    if !cascades.is_empty() {
        lines.push(format!("Каскады через эту ноду будут удалены: {}", cascades.join(" ")));
    }
    if config.telegram.iter().any(|proxy| proxy.node == node.name) {
        lines.push("Telegram Proxy этой ноды будет удалён из конфигурации.".to_owned());
    }
    lines.push(if revoke { "Управляемый SSH-ключ будет отозван на ноде." } else { "SSH-ключ на ноде сохранится." }.to_owned());
    lines
}

/// `printf present|absent` for the exact authorized_keys line; exit 1 when unreadable.
fn key_probe_command(public: &str) -> String {
    format!(r#"key={}
if [ ! -f ~/.ssh/authorized_keys ]; then printf absent
elif grep -qxF -- "$key" ~/.ssh/authorized_keys; then printf present
elif [ "$?" -eq 1 ]; then printf absent
else exit 1; fi"#, sh_quote(public))
}

/// `setup::revoke_command`, succeeding only once the exact line is gone.
fn key_revoke_command(public: &str) -> String {
    format!("{} && {{ grep -qxF -e {} ~/.ssh/authorized_keys; [ \"$?\" -eq 1 ]; }}", setup::revoke_command(public), sh_quote(public))
}

async fn run<S: RemoteSession>(session: &S, command: &str, timeout: std::time::Duration) -> Option<String> {
    let result = session.exec(command, b"", timeout).await.ok()?;
    (result.exit_status == 0).then(|| String::from_utf8_lossy(&result.stdout).into_owned())
}

fn remote_failed(message: &str) -> RcError {
    RcError::new("remote_failed", message)
}

const SERVER_NOT_REMOVED: &str = "Удаление компонентов на сервере не завершено. Нода сохранена в remote-control.";
const NO_RECOVERY_LEASE: &str = "Не удалось сохранить SSH-соединение для восстановления доступа. Ключ не отозван.";

/// Put the revoked key back through the held lease, then verify a fresh
/// login with it (the lease alone proves nothing about new logins).
async fn restore_key<T: RemoteTransport>(session: &mut Session, transport: &mut T, lease: &T::Held, node: &Node, public: &str)
    -> bool
{
    let mut restored = run(lease, &setup::install_command(public), COMMAND_TIMEOUT).await.is_some();
    if restored {
        restored = match connect_options(&session.state, node, None) {
            Ok(options) => transport.connect(options).await.is_ok() && run(&*transport, "true", COMMAND_TIMEOUT).await.is_some(),
            Err(_) => false,
        };
    }
    if !restored {
        session.log(Level::Warn, &format!(
            "Не удалось подтвердить восстановление SSH-доступа к ноде «{}»: проверьте ~/.ssh/authorized_keys на сервере.", node.name));
    }
    restored
}

fn cascade_uses(cascade: &Cascade, name: &str) -> bool {
    cascade.entry == name || matches!(&cascade.exit, CascadeExit::Node(exit) if exit.node == name)
}

/// Remove the node and everything that only it referenced.
fn remove(state: &State, node: &Node) -> Result<()> {
    let mut config = state.load_config()?;
    let count = config.nodes.len();
    config.nodes.retain(|candidate| candidate.id != node.id);
    if config.nodes.len() == count {
        return Err(super::not_found(&node.name));
    }
    config.connections.retain(|connection| connection.node != node.name);
    for client in &mut config.clients {
        if let Some(nodes) = client.nodes.as_mut() {
            nodes.retain(|name| *name != node.name);
        }
        if let Some(connections) = client.connections.as_mut() {
            connections.retain(|connection| connection.node != node.name);
        }
    }
    config.cascades.retain(|cascade| !cascade_uses(cascade, &node.name));
    config.telegram.retain(|proxy| proxy.node != node.name);
    if config.subscription_host.as_ref().is_some_and(|host| host.node == node.name) {
        config.subscription_host = None;
    }
    state.save_config(&config)?;
    let store = state.secret_store();
    let prefix = format!("node:{}:", node.id);
    for secret_id in store.ids()?.iter().filter(|id| id.starts_with(&prefix)) {
        store.remove(secret_id)?;
    }
    let shared = config.nodes.iter().any(|other| other.ip == node.ip && other.port == node.port);
    if !shared && !pins(&state.load_known_hosts()?, node)?.is_empty() {
        pin(state, &node.ip, node.port, Vec::new())?;
    }
    let mut manifest = state.load_manifest()?;
    if manifest.portability.issues.iter().any(|issue| issue.node_id == node.id) {
        for reason in [PortabilityReason::MissingIdentity, PortabilityReason::MissingSecret, PortabilityReason::MissingHostKey] {
            set_issue(&mut manifest, &node.id, reason, false);
        }
        state.save_manifest(&manifest)?;
    }
    state.checkpoint()
}

fn remove_identity(state: &State, id: &str) -> std::io::Result<()> {
    let [private, public] = setup::identity_paths(state, id);
    for path in [public, private] {
        match std::fs::remove_file(&path) {
            Err(error) if error.kind() != ErrorKind::NotFound => return Err(error),
            _ => {}
        }
    }
    Ok(())
}

fn with_outcome(error: RcError, name: &str, scope: &str, deleted: bool, remote_removed: bool) -> RcError {
    error.with_extra("name", name).with_extra("scope", scope)
        .with_extra("deleted", deleted).with_extra("remote_removed", remote_removed)
}

/// `node delete --name N [--scope local|server] [--revoke-key]`.
pub async fn delete<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, transport: &mut T) -> Result<Value> {
    let name = required(invocation, "name")?;
    let config = session.state.load_config()?;
    let node = find(&config, name)?.clone();
    let scope = invocation.value("scope").filter(|scope| !scope.is_empty()).unwrap_or("local");
    let server = match scope {
        "local" => false,
        "server" => true,
        _ => return Err(RcError::new("invalid", "Объём удаления должен быть local или server.")),
    };
    let revoke = invocation.has("revoke-key");
    let managed = node.identity.as_deref() == Some(node.id.as_str());
    if revoke && !(is_github(session) && managed) {
        return Err(RcError::new("invalid", "Отзыв ключа доступен только для управляемого ключа в режиме GitHub."));
    }
    if server {
        require_portable(session, &node)?;
        if node.operation.is_some() {
            return Err(RcError::new("in_use", format!(
                "На ноде «{name}» уже выполняется применение: дождитесь его завершения (node apply --name {name}).")).with_extra("name", name));
        }
    }
    Plan::new(plan(&config, &node, server, revoke), "").confirm(invocation)?;

    // Every rollback artifact is ready before anything remote changes.
    let public = if revoke {
        let path = session.state.paths().identities().join(format!("{}.pub", node.id));
        let public = std::fs::read_to_string(path).ok().map(|text| text.trim_end_matches(['\n', '\r']).to_owned())
            .filter(|text| !text.is_empty() && !text.contains('\n'));
        Some(public.ok_or_else(|| RcError::new("failed", "Не удалось подготовить отзыв SSH-ключа. Нода сохранена в remote-control."))?)
    } else {
        None
    };

    let mut lease = None;
    let mut revoked = false;
    let mut remote_removed = false;
    if server || revoke {
        connect(transport, &session.state, &node).await.map_err(|error| match error.code {
            "missing_secret" => RcError::new("missing_secret",
                format!("Пароль SSH ноды «{name}» недоступен. Нода сохранена в remote-control.")).with_extra("name", name),
            "remote_failed" => remote_failed(if server { SERVER_NOT_REMOVED } else { NO_RECOVERY_LEASE })
                .with_extra("reason", error.extra.get("reason").cloned().unwrap_or(Value::Null)),
            _ => error,
        })?;
        if server {
            if node.applied.is_some() {
                session.log(Level::Info, &format!("Удаляем компоненты Essence на ноде «{name}»..."));
                crate::server::apply::teardown(session, &node, transport).await
                    .map_err(|error| remote_failed(SERVER_NOT_REMOVED).with_extra("cause", error.message))?;
                remote_removed = true;
            } else {
                session.log(Level::Info, &format!("Essence на ноду «{name}» не применялся — сервер не изменится."));
            }
        }
        // The lease only serves putting a revoked key back.
        if let Some(public) = public.as_deref() {
            let kept = |error: RcError| if remote_removed {
                let restored = error.extra.get("key_restored").cloned();
                let partial = with_outcome(RcError::new("partial", format!("Компоненты на сервере удалены. {}", error.message)),
                    name, scope, false, true);
                match restored {
                    Some(restored) => partial.with_extra("key_restored", restored),
                    None => partial,
                }
            } else {
                error
            };
            let held = transport.hold().map_err(|_| kept(remote_failed(NO_RECOVERY_LEASE)))?;
            match run(&*transport, &key_probe_command(public), COMMAND_TIMEOUT).await.as_deref() {
                Some("present") => {
                    // Marked before sending: a lost reply may follow a successful revocation.
                    revoked = true;
                    if run(&*transport, &key_revoke_command(public), COMMAND_TIMEOUT).await.is_none() {
                        let restored = restore_key(session, transport, &held, &node, public).await;
                        return Err(kept(remote_failed("SSH-ключ не отозван. Нода сохранена в remote-control.")
                            .with_extra("key_restored", restored)));
                    }
                }
                Some("absent") => {}
                _ => return Err(kept(remote_failed("Не удалось проверить SSH-ключ. Нода сохранена в remote-control."))),
            }
            lease = Some(held);
        }
    }

    let outcome = session.mutate("node delete", |state| {
        let rollback = FileBackup::take(transaction_files(state, Vec::<PathBuf>::new()))?;
        if let Err(error) = remove(state, &node) {
            let restored = rollback.restore().is_ok();
            return Err(RcError::new("failed", "Удаление ноды отменено: локальное состояние не удалось сохранить.")
                .with_extra("cause", error.message).with_extra("restored", restored));
        }
        // Committed: the managed key files go last; their failure keeps the deletion.
        if managed {
            if let Err(error) = remove_identity(state, &node.id) {
                let path = state.paths().identities().join(&node.id);
                return Err(with_outcome(RcError::new("partial", format!(
                    "Нода удалена, но очистка локального SSH-ключа не завершена: {}", path.display())), name, scope, true, remote_removed)
                    .with_extra("cause", error.to_string()));
            }
        }
        Ok(())
    });
    if let Err(mut error) = outcome {
        let deleted = error.extra.get("deleted").and_then(Value::as_bool).unwrap_or(false);
        if !deleted {
            // The node stays: so must its access.
            if let (true, Some(held), Some(public)) = (revoked, lease.as_ref(), public.as_deref()) {
                let restored = restore_key(session, transport, held, &node, public).await;
                error = error.with_extra("key_restored", restored);
            }
            if remote_removed {
                error.message = format!("Компоненты на сервере удалены. {}", error.message);
                error.code = "partial";
                error.exit = exit_code_for("partial");
                error = with_outcome(error, name, scope, false, true);
            }
        }
        return Err(error);
    }
    drop(lease);
    session.log(Level::Success, &format!("Нода «{name}» удалена"));
    Ok(json!({"name": name, "scope": scope}))
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::time::Duration;

    use super::*;
    use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeTransport, ScriptStep};
    use crate::github::{SyncStatus, Storage, Target, commands::GithubSession};
    use crate::model::{Auth, CascadeListener, Client, Connection, ConnectionGroup, ExitProxy, Fingerprint, NodeExit,
        SubscriptionHost, TelegramProxy, UriExit};
    use crate::nodes::{CONNECT_TIMEOUT, testing};
    use crate::transport::{ConnectOptions, ExecResult, HostKeyPolicy, remote_failure};

    const ID: &str = "0123456789abcdef0123456789abcdef";
    const PUBLIC: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample essence:0123";

    fn fp() -> Fingerprint {
        format!("SHA256:{}A", "Z".repeat(42)).parse().unwrap()
    }

    fn node(name: &str, id: &str, auth: Auth) -> Node {
        Node {
            id: id.into(), name: name.into(), ip: "198.51.100.7".into(), port: 22, user: "root".into(), auth,
            identity: (auth == Auth::Key).then(|| id.to_owned()),
            secret_id: (auth == Auth::Password).then(|| format!("node:{id}:ssh-password")),
            tag: Some("T".into()), aliases: Default::default(), ..Node::default()
        }
    }

    fn ok(stdout: &str, exit_status: u32) -> Result<ExecResult> {
        Ok(ExecResult { stdout: stdout.as_bytes().to_vec(), stderr: Vec::new(), exit_status })
    }

    fn key_connect() -> ScriptStep {
        ScriptStep::connect(
            ConnectExpectation::new("198.51.100.7", 22, "root", AuthMethod::Key, CONNECT_TIMEOUT)
                .with_host_key(HostKeyPolicy { expected: None, known: vec![fp()] }),
            Ok(()),
        )
    }

    /// A GitHub-mode session (its source is never reached by these flows)
    /// with a managed-key node, its public key and its pin.
    fn github_session(root: &std::path::Path) -> Session {
        let (mut session, _journal) = testing::session(root);
        session.github = Some(GithubSession {
            target: Target::new("owner", "repo", "main"), work: None, storage: Storage::Plain, keys: None,
            sync: SyncStatus::Clean, last_counts: Value::Null, last_version: None,
        });
        session.state.save_config(&Config { nodes: vec![node("de", ID, Auth::Key)], ..Config::default() }).unwrap();
        pin(&session.state, "198.51.100.7", 22, vec![fp()]).unwrap();
        let identities = session.state.paths().identities().to_path_buf();
        std::fs::create_dir_all(&identities).unwrap();
        std::fs::write(identities.join(ID), b"private").unwrap();
        std::fs::write(identities.join(format!("{ID}.pub")), format!("{PUBLIC}\n")).unwrap();
        session
    }

    fn restore_steps() -> [ScriptStep; 3] {
        [
            ScriptStep::exec(setup::install_command(PUBLIC), 0, COMMAND_TIMEOUT, ok("", 0)),
            key_connect(),
            ScriptStep::exec("true", 0, COMMAND_TIMEOUT, ok("", 0)),
        ]
    }

    #[tokio::test]
    async fn unconfirmed_delete_changes_nothing_and_contacts_nobody() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = testing::session(root.path());
        session.state.save_config(&Config {
            nodes: vec![node("de", ID, Auth::Key)],
            connections: vec![Connection { node: "de".into(), groups: vec![ConnectionGroup { name: "g".into(), proxies: vec![] }] }],
            clients: vec![Client { name: "alice".into(), group: "g".into(), ..Client::default() }],
            ..Config::default()
        }).unwrap();
        let before = testing::fingerprint(root.path());
        let mut transport = FakeTransport::new([]);
        let error = delete(&mut session, &testing::invocation(&["node", "delete", "--name", "de", "--scope", "server"]), &mut transport)
            .await.unwrap_err();
        assert_eq!((error.code, error.exit_code()), ("confirmation_required", 2));
        let plan = error.extra["plan"].as_array().unwrap();
        assert_eq!(plan[0], "Нода: de  198.51.100.7:22");
        assert_eq!(plan[2], format!("Объём: {}", scope_label(true, false)));
        assert_eq!(plan[3], "Затронутые клиенты: alice");
        assert_eq!(plan[plan.len() - 3], "Essence на ноду не применялся: сервер не изменится.");
        assert_eq!(plan[plan.len() - 2], "Пакеты, acme.sh и UFW остаются; SSH-доступ сохранится.");
        assert_eq!(plan[plan.len() - 1], "SSH-ключ на ноде сохранится.");
        assert!(transport.journal().is_empty());
        assert_eq!(testing::fingerprint(root.path()), before);

        let error = delete(&mut session, &testing::invocation(&["node", "delete", "--name", "de", "--revoke-key", "--yes"]), &mut transport)
            .await.unwrap_err();
        assert_eq!(error.code, "invalid", "revocation needs GitHub mode");
        let error = delete(&mut session, &testing::invocation(&["node", "delete", "--name", "de", "--scope", "all", "--yes"]), &mut transport)
            .await.unwrap_err();
        assert_eq!(error.code, "invalid");
        assert_eq!(testing::fingerprint(root.path()), before);
    }

    #[tokio::test]
    async fn local_delete_removes_every_reference_but_shared_pins() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = testing::session(root.path());
        let other = "fedcba9876543210fedcba9876543210";
        let mut twin = node("twin", other, Auth::Key);
        twin.identity = Some("system".into());
        let mut de = node("de", ID, Auth::Password);
        de.profile = Some("main".into());
        twin.profile = Some("main".into());
        let cascade = |name: &str, entry: &str, exit: &str| Cascade {
            name: name.into(), entry: entry.into(), listener: CascadeListener::VlessTcp,
            exit: CascadeExit::Node(NodeExit { node: exit.into(), proxy: ExitProxy::VlessTcp }),
            uuid: "11111111-2222-4333-8444-555555555555".into(), password: "0123456789abcdef".into(),
        };
        session.state.save_config(&Config {
            nodes: vec![de, twin],
            profiles: vec![crate::model::test_profile("main")],
            connections: vec![
                Connection { node: "de".into(), groups: vec![] },
                Connection { node: "twin".into(), groups: vec![] },
            ],
            clients: vec![Client { name: "alice".into(), group: "g".into(), nodes: Some(vec!["de".into(), "twin".into()]), ..Client::default() }],
            cascades: vec![cascade("in", "de", "twin"), cascade("out", "twin", "de"),
                Cascade { exit: CascadeExit::Uri(UriExit { uri: "vless://x@y:1".into() }), ..cascade("ext", "twin", "de") }],
            telegram: vec![TelegramProxy { node: "de".into(), hostname: "tg.example".into(), secret_mark: "0123abcd".into(), tag_mark: None },
                TelegramProxy { node: "twin".into(), hostname: "tg2.example".into(), secret_mark: "0123abcd".into(), tag_mark: None }],
            subscription_host: Some(SubscriptionHost { node: "de".into(), hostname: "x.example".into(), port: 443,
                base_url: "https://x.example".into(), sub_dir: "s".into(), nginx_group: "www-data".into() }),
            ..Config::default()
        }).unwrap();
        for suffix in ["ssh-password", "reality-key", "awg-key", "warp-key", "telegram-secret", "telegram-tag"] {
            session.state.secret_store().set(&format!("node:{ID}:{suffix}"), "pw".to_owned().into()).unwrap();
        }
        session.state.secret_store().set(&format!("node:{other}:reality-key"), "keep".to_owned().into()).unwrap();
        pin(&session.state, "198.51.100.7", 22, vec![fp()]).unwrap();
        let mut transport = FakeTransport::new([]);
        let data = delete(&mut session, &testing::invocation(&["node", "delete", "--name", "de", "--yes"]), &mut transport).await.unwrap();
        assert_eq!(data, json!({"name": "de", "scope": "local"}));
        let config = session.state.load_config().unwrap();
        assert_eq!(config.nodes.iter().map(|n| n.name.as_str()).collect::<Vec<_>>(), ["twin"]);
        assert_eq!(config.connections.len(), 1);
        assert_eq!(config.clients[0].nodes.as_deref(), Some(&["twin".to_owned()][..]));
        assert!(config.subscription_host.is_none());
        assert_eq!(config.cascades.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["ext"]);
        assert_eq!(config.telegram.iter().map(|t| t.node.as_str()).collect::<Vec<_>>(), ["twin"]);
        assert_eq!(session.state.secret_store().ids().unwrap(), [format!("node:{other}:reality-key")]);
        // "twin" shares the endpoint: its pin stays.
        assert_eq!(pins(&session.state.load_known_hosts().unwrap(), &config.nodes[0]).unwrap(), vec![fp()]);
        assert!(transport.journal().is_empty());
    }

    /// A local session with an applied key node (system key) and its pin.
    fn applied_session(root: &std::path::Path) -> Session {
        let (session, _journal) = testing::session(root);
        let mut de = node("de", ID, Auth::Key);
        de.identity = Some("system".into());
        de.applied = Some(crate::model::Applied { digest: "d".repeat(64),
            files: [("/etc/mihomo/config.yaml".to_owned(), "a".repeat(64))].into(), ports: vec!["443/tcp".into()], at: "t".into() });
        session.state.save_config(&Config { nodes: vec![de], ..Config::default() }).unwrap();
        pin(&session.state, "198.51.100.7", 22, vec![fp()]).unwrap();
        session
    }

    fn teardown_steps(result: &str) -> Vec<ScriptStep> {
        use crate::server::apply::{agent_reset_command, start_command, status_command};
        let node = Node { applied: None, ..node("de", ID, Auth::Key) };
        let op = "ab".repeat(16);
        vec![
            ScriptStep::connect(ConnectExpectation::new("198.51.100.7", 22, "root", AuthMethod::System, CONNECT_TIMEOUT)
                .with_host_key(HostKeyPolicy { expected: None, known: vec![fp()] }), Ok(())),
            ScriptStep::exec(crate::server::apply::probe_command(&node), 0, COMMAND_TIMEOUT, ok("os=debian\nsystemd=yes\n", 0)),
            ScriptStep::exec(agent_reset_command(), 0, COMMAND_TIMEOUT, ok("", 0)),
            ScriptStep::upload_any_local(crate::server::bundle::agent_dir(), crate::nodes::LONG_TIMEOUT, Ok(())),
            ScriptStep::upload_private_any_local(format!("/root/essence-node/ops/{op}"), crate::nodes::LONG_TIMEOUT, Ok(())),
            ScriptStep::exec(start_command(&op), 0, COMMAND_TIMEOUT, ok("", 0)),
            ScriptStep::exec(status_command(&op), 0, COMMAND_TIMEOUT, ok(result, 0)),
        ]
    }

    #[tokio::test(start_paused = true)]
    async fn server_scope_tears_the_node_down_through_the_executor() {
        let root = tempfile::tempdir().unwrap();
        let mut session = applied_session(root.path());
        let invocation = testing::invocation(&["node", "delete", "--name", "de", "--scope", "server"]);
        let plan = delete(&mut session, &invocation, &mut FakeTransport::new([])).await.unwrap_err().extra["plan"].clone();
        assert!(plan.as_array().unwrap().contains(&json!("Будет удалено: /etc/mihomo/config.yaml")), "{plan}");

        crate::server::apply::tests::NEXT_OP_ID.with(|next| *next.borrow_mut() = Some("ab".repeat(16)));
        let mut steps = teardown_steps("stage=config\nresult=rolled_back\nerror=config\n");
        steps.push(ScriptStep::exec(crate::server::apply::log_command(&"ab".repeat(16)), 0, COMMAND_TIMEOUT, ok("", 0)));
        let mut transport = FakeTransport::new(steps);
        let argv = testing::invocation(&["node", "delete", "--name", "de", "--scope", "server", "--yes"]);
        let error = delete(&mut session, &argv, &mut transport).await.unwrap_err();
        transport.assert_finished();
        assert_eq!((error.code, error.message.as_str()), ("remote_failed", SERVER_NOT_REMOVED));
        let kept = session.state.load_config().unwrap();
        assert!(kept.nodes[0].applied.is_some() && kept.nodes[0].operation.is_none());

        crate::server::apply::tests::NEXT_OP_ID.with(|next| *next.borrow_mut() = Some("ab".repeat(16)));
        let mut transport = FakeTransport::new(teardown_steps("stage=cleanup\nresult=committed\n"));
        let data = delete(&mut session, &argv, &mut transport).await.unwrap();
        transport.assert_finished();
        assert_eq!(data, json!({"name": "de", "scope": "server"}));
        assert!(session.state.load_config().unwrap().nodes.is_empty());
    }

    #[tokio::test]
    async fn server_scope_waits_for_a_running_operation() {
        let root = tempfile::tempdir().unwrap();
        let mut session = applied_session(root.path());
        session.mutate("t", |state| {
            let mut config = state.load_config()?;
            config.nodes[0].operation = Some(crate::model::Operation { id: "ab".repeat(16), digest: "d".repeat(64), ..Default::default() });
            state.save_config(&config)
        }).unwrap();
        let argv = testing::invocation(&["node", "delete", "--name", "de", "--scope", "server", "--yes"]);
        let mut transport = FakeTransport::new([]);
        let error = delete(&mut session, &argv, &mut transport).await.unwrap_err();
        assert_eq!((error.code, error.extra["name"].as_str()), ("in_use", Some("de")));
        assert!(transport.journal().is_empty());
        assert_eq!(session.state.load_config().unwrap().nodes[0].operation.as_ref().map(|op| op.id.clone()), Some("ab".repeat(16)));
    }

    #[tokio::test]
    async fn state_failure_after_revoke_restores_the_key_and_keeps_the_node() {
        let root = tempfile::tempdir().unwrap();
        let mut session = github_session(root.path());
        let mut steps = vec![
            key_connect(),
            ScriptStep::exec(key_probe_command(PUBLIC), 0, COMMAND_TIMEOUT, ok("present", 0)),
            ScriptStep::exec(key_revoke_command(PUBLIC), 0, COMMAND_TIMEOUT, ok("", 0)),
        ];
        steps.extend(restore_steps());
        let mut transport = FakeTransport::new(steps);
        // This GitHub source has no worktree: publishing the deletion fails.
        let error = delete(&mut session, &testing::invocation(&["node", "delete", "--name", "de", "--revoke-key", "--yes"]), &mut transport)
            .await.unwrap_err();
        transport.assert_finished();
        assert_ne!(error.code, "partial");
        assert_eq!(error.extra["key_restored"], json!(true));
        assert_eq!(session.state.load_config().unwrap().nodes.len(), 1);
        assert!(session.state.paths().identities().join(ID).exists());
    }

    /// A [`FakeTransport`] whose connection closes before a lease is taken.
    struct ClosedBeforeHold(FakeTransport);

    impl RemoteSession for ClosedBeforeHold {
        fn exec<'a>(&'a self, command: &'a str, stdin: &'a [u8], timeout: Duration) -> impl Future<Output = Result<ExecResult>> + 'a {
            self.0.exec(command, stdin, timeout)
        }
        fn upload<'a>(&'a self, local_dir: &'a Path, remote_dir: &'a str, timeout: Duration) -> impl Future<Output = Result<()>> + 'a {
            self.0.upload(local_dir, remote_dir, timeout)
        }
        fn upload_private<'a>(&'a self, local_dir: &'a Path, remote_dir: &'a str, timeout: Duration)
            -> impl Future<Output = Result<()>> + 'a
        {
            self.0.upload_private(local_dir, remote_dir, timeout)
        }
    }

    impl RemoteTransport for ClosedBeforeHold {
        type Held = <FakeTransport as RemoteTransport>::Held;
        fn connect(&mut self, options: ConnectOptions) -> impl Future<Output = Result<()>> + '_ {
            self.0.connect(options)
        }
        fn hold(&self) -> Result<Self::Held> {
            Err(remote_failure("connection_closed"))
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_closed_connection_after_teardown_does_not_stop_a_server_delete() {
        let root = tempfile::tempdir().unwrap();
        let mut session = applied_session(root.path());
        crate::server::apply::tests::NEXT_OP_ID.with(|next| *next.borrow_mut() = Some("ab".repeat(16)));
        let mut transport = ClosedBeforeHold(FakeTransport::new(teardown_steps("stage=cleanup\nresult=committed\n")));
        let argv = testing::invocation(&["node", "delete", "--name", "de", "--scope", "server", "--yes"]);
        let data = delete(&mut session, &argv, &mut transport).await.unwrap();
        transport.0.assert_finished();
        assert_eq!(data, json!({"name": "de", "scope": "server"}));
        assert!(session.state.load_config().unwrap().nodes.is_empty());
    }

    #[tokio::test]
    async fn revocation_without_a_lease_changes_nothing() {
        let root = tempfile::tempdir().unwrap();
        let mut session = github_session(root.path());
        let before = testing::fingerprint(root.path());
        let mut transport = ClosedBeforeHold(FakeTransport::new([key_connect()]));
        let error = delete(&mut session, &testing::invocation(&["node", "delete", "--name", "de", "--revoke-key", "--yes"]), &mut transport)
            .await.unwrap_err();
        transport.0.assert_finished();
        assert_eq!((error.code, error.message.as_str()), ("remote_failed", NO_RECOVERY_LEASE));
        assert_eq!(testing::fingerprint(root.path()), before);
    }
}
