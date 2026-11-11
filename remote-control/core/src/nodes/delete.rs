//! `node delete` (v1 `core_node_delete_plan` + `core_node_delete`).
//!
//! Remote work runs only after the plan is confirmed. Before the managed key
//! is revoked or the server components are removed, the authenticated
//! connection is held as a recovery lease (v2's replacement for v1's private
//! ControlMaster socket): if anything later fails while the node is kept, the
//! revoked key is put back through that lease and a fresh login verifies it.
//! The state change is one `Session::mutate` transaction: node, its
//! connections, client references, `subscription_host` (if it named the node),
//! password secret, host pins (unless another node shares the endpoint),
//! portability issues and, last, the managed identity files.

use std::io::ErrorKind;
use std::path::PathBuf;

use serde_json::{Value, json};

use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result, exit_code_for};
use crate::log::Level;
use crate::model::{Config, Node, PortabilityReason};
use crate::state::State;
use crate::transport::{RemoteSession, RemoteTransport};

use super::add::transaction_files;
use super::setup::{self, FileBackup};
use super::scripts::{REMOTE_DIR, ensure_current};
use super::{COMMAND_TIMEOUT, LONG_TIMEOUT, connect, connect_options, find, is_github, pin, pins, require_portable,
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
        lines.extend([
            "Mihomo: бинарь, служба, конфигурация и клиентские записи.",
            "AmneziaWG: служба, конфигурация, ключи и все клиенты.",
            "WARP: /root/wgcf и профиль.",
            "Сайты nginx Essence, webroot и /etc/nginx/ssl целиком.",
            "Хостинг подписок, Telegram Proxy и acme.sh.",
            "/etc/sysctl.d/99-vpn-speedup.conf; IPv6 будет восстановлен.",
            "Пакеты nginx и AmneziaWG не удаляются.",
            "Правила UFW будут сброшены. Настройки SSH сохранятся.",
        ].map(str::to_owned));
        lines.push(if node.port == 22 {
            "UFW будет отключён.".to_owned()
        } else {
            format!("UFW останется включён: открыт только SSH TCP/{}.", node.port)
        });
    }
    if config.subscription_host.as_ref().is_some_and(|host| host.node == node.name) {
        lines.push("Хостинг подписок размещён на этой ноде: его настройка (subscription_host) будет удалена.".to_owned());
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

fn uninstall_command() -> String {
    format!("bash {} uninstall --force", sh_quote(&format!("{REMOTE_DIR}/setup-essence.sh")))
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
    if config.subscription_host.as_ref().is_some_and(|host| host.node == node.name) {
        config.subscription_host = None;
    }
    state.save_config(&config)?;
    if let Some(secret_id) = node.secret_id.as_deref() {
        state.secret_store().remove(secret_id)?;
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
            ensure_current(&*transport, name, false).await
                .map_err(|error| remote_failed(SERVER_NOT_REMOVED).with_extra("cause", error.message))?;
        }
        let held = transport.hold().map_err(|_| remote_failed(NO_RECOVERY_LEASE))?;
        if let Some(public) = public.as_deref() {
            match run(&*transport, &key_probe_command(public), COMMAND_TIMEOUT).await.as_deref() {
                Some("present") => {
                    // Marked before sending: a lost reply may follow a successful revocation.
                    revoked = true;
                    if run(&*transport, &key_revoke_command(public), COMMAND_TIMEOUT).await.is_none() {
                        let restored = restore_key(session, transport, &held, &node, public).await;
                        return Err(remote_failed("SSH-ключ не отозван. Нода сохранена в remote-control.")
                            .with_extra("key_restored", restored));
                    }
                }
                Some("absent") => {}
                _ => return Err(remote_failed("Не удалось проверить SSH-ключ. Нода сохранена в remote-control.")),
            }
        }
        if server {
            session.log(Level::Info, &format!("Удаляем компоненты Essence на ноде «{name}»..."));
            if run(&*transport, &uninstall_command(), LONG_TIMEOUT).await.is_none() {
                let mut error = remote_failed(SERVER_NOT_REMOVED);
                if revoked {
                    let restored = restore_key(session, transport, &held, &node, public.as_deref().unwrap_or_default()).await;
                    error = error.with_extra("key_restored", restored);
                }
                return Err(error);
            }
            remote_removed = true;
        }
        lease = Some(held);
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
    use super::*;
    use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeTransport, Operation, ScriptStep};
    use crate::github::{SyncStatus, Storage, Target, commands::GithubSession};
    use crate::model::{Auth, Client, Connection, ConnectionGroup, Fingerprint, SubscriptionHost};
    use crate::nodes::{CONNECT_TIMEOUT, scripts, testing};
    use crate::transport::{ExecResult, HostKeyPolicy};

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
            tag: Some("T".into()), aliases: Default::default(),
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

    fn position(journal: &[Operation], wanted: &Operation) -> usize {
        journal.iter().position(|operation| operation == wanted).expect("operation journaled")
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
        assert_eq!(plan[plan.len() - 2], "UFW будет отключён.");
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
        session.state.save_config(&Config {
            nodes: vec![node("de", ID, Auth::Password), twin],
            connections: vec![
                Connection { node: "de".into(), groups: vec![] },
                Connection { node: "twin".into(), groups: vec![] },
            ],
            clients: vec![Client { name: "alice".into(), group: "g".into(), nodes: Some(vec!["de".into(), "twin".into()]), ..Client::default() }],
            subscription_host: Some(SubscriptionHost { node: "de".into(), base_url: "https://x".into(), sub_dir: "s".into(), nginx_group: "www-data".into() }),
            ..Config::default()
        }).unwrap();
        session.state.secret_store().set(&format!("node:{ID}:ssh-password"), "pw".to_owned().into()).unwrap();
        pin(&session.state, "198.51.100.7", 22, vec![fp()]).unwrap();
        let mut transport = FakeTransport::new([]);
        let data = delete(&mut session, &testing::invocation(&["node", "delete", "--name", "de", "--yes"]), &mut transport).await.unwrap();
        assert_eq!(data, json!({"name": "de", "scope": "local"}));
        let config = session.state.load_config().unwrap();
        assert_eq!(config.nodes.iter().map(|n| n.name.as_str()).collect::<Vec<_>>(), ["twin"]);
        assert_eq!(config.connections.len(), 1);
        assert_eq!(config.clients[0].nodes.as_deref(), Some(&["twin".to_owned()][..]));
        assert!(config.subscription_host.is_none());
        assert_eq!(session.state.secret_store().get(&format!("node:{ID}:ssh-password")).unwrap(), None);
        // "twin" shares the endpoint: its pin stays.
        assert_eq!(pins(&session.state.load_known_hosts().unwrap(), &config.nodes[0]).unwrap(), vec![fp()]);
        assert!(transport.journal().is_empty());
    }

    #[tokio::test]
    async fn server_failure_after_revoke_restores_the_key_through_the_held_session() {
        let root = tempfile::tempdir().unwrap();
        let mut session = github_session(root.path());
        let before = testing::fingerprint(root.path());
        let local = scripts::local_version().unwrap();
        let mut steps = vec![
            key_connect(),
            ScriptStep::exec(scripts::probe_command(), 0, COMMAND_TIMEOUT, ok(&format!("PRESENT\n{local}\n"), 0)),
            ScriptStep::exec(key_probe_command(PUBLIC), 0, COMMAND_TIMEOUT, ok("present", 0)),
            ScriptStep::exec(key_revoke_command(PUBLIC), 0, COMMAND_TIMEOUT, ok("", 0)),
            ScriptStep::exec(uninstall_command(), 0, LONG_TIMEOUT, ok("", 1)),
        ];
        steps.extend(restore_steps());
        let mut transport = FakeTransport::new(steps);
        let error = delete(&mut session,
            &testing::invocation(&["node", "delete", "--name", "de", "--scope", "server", "--revoke-key", "--yes"]), &mut transport)
            .await.unwrap_err();
        transport.assert_finished();
        assert_eq!((error.code, error.message.as_str()), ("remote_failed", SERVER_NOT_REMOVED));
        assert_eq!(error.extra["key_restored"], json!(true));
        let journal = transport.journal();
        let restore = Operation::Exec { command: setup::install_command(PUBLIC), stdin_len: 0, timeout: COMMAND_TIMEOUT };
        assert!(position(&journal, &Operation::Hold) < position(&journal, &restore));
        assert_eq!(testing::fingerprint(root.path()), before, "node kept byte-identical");
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
}
