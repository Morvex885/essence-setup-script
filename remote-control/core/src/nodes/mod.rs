//! Node and connection domain (plan step 6): port of `nodes.sh`,
//! `hardening.sh`, `connections.sh` and the node/conn handlers of
//! `cmd_nodes.sh`. Every state change goes through `Session::mutate`; every
//! remote effect goes through `RemoteTransport`. Host trust lives only in
//! `ssh/known-hosts.json` keyed `[host]:port` and changes only through an
//! agreed fingerprint (flag or confirmed plan).

pub mod add;
pub mod basic;
pub mod conn;
pub mod delete;
pub mod harden;
pub mod scripts;
pub mod setup;
pub mod shell;

use std::time::Duration;

use serde_json::Value;

use crate::cli::Invocation;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::model::{Auth, Config, Fingerprint, KnownHosts, Manifest, Node, Portability, PortabilityIssue, PortabilityReason, endpoint_key};
use crate::request_secrets::Secrets;
use crate::state::State;
use crate::transport::{Authentication, ConnectOptions, HostKeyPolicy, RemoteTransport};

/// SSH handshake and authentication bound.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
/// Ordinary remote commands.
pub const COMMAND_TIMEOUT: Duration = Duration::from_secs(60);
/// `setup-essence.sh uninstall --force` and other long server work.
pub const LONG_TIMEOUT: Duration = Duration::from_secs(900);

/// Dispatch of `node *` and `conn *`. Handlers are generic over the transport
/// so tests drive them with `FakeTransport` or the loopback SSH server.
pub async fn route<T: RemoteTransport>(noun: &str, verb: &str, invocation: &Invocation, secrets: &Secrets,
    session: &mut Session, transport: &mut T) -> Result<Value>
{
    match (noun, verb) {
        ("node", "list") => basic::list(session),
        ("node", "show") => basic::show(session, invocation),
        ("node", "aliases") => basic::aliases(session, invocation, transport).await,
        ("node", "rename") => basic::rename(session, invocation),
        ("node", "tag") => basic::tag(session, invocation),
        ("node", "password") => basic::password(session, invocation, secrets),
        ("node", "check") => basic::check(session, invocation, transport).await,
        ("node", "trust-host-key") => basic::trust_host_key(session, invocation, transport).await,
        ("node", "add") => add::add(session, invocation, secrets, transport).await,
        ("node", "delete") => delete::delete(session, invocation, transport).await,
        ("node", "upload-scripts") => scripts::upload(session, invocation, transport).await,
        ("node", "harden") => harden::harden(session, invocation, transport).await,
        ("node", "setup-ssh") => setup::setup_ssh(session, invocation, transport).await,
        ("node", "shell") => shell::shell(session, invocation, transport).await,
        ("conn", "list") => conn::list(session, invocation, transport).await,
        ("conn", "set") => conn::set(session, invocation),
        ("conn", "sync") => conn::sync(session, invocation, transport).await,
        _ => Err(RcError::new("usage", "Неизвестная команда.")),
    }
}

/// A required flag value (`--name` and friends): absent or empty is `usage`.
pub fn required<'a>(invocation: &'a Invocation, flag: &str) -> Result<&'a str> {
    invocation.value(flag).filter(|value| !value.is_empty())
        .ok_or_else(|| RcError::new("usage", format!("Укажите --{flag}.")))
}

pub fn not_found(name: &str) -> RcError {
    RcError::new("not_found", format!("Нода «{name}» не найдена.")).with_extra("name", name)
}

pub fn find<'a>(config: &'a Config, name: &str) -> Result<&'a Node> {
    config.nodes.iter().find(|node| node.name == name).ok_or_else(|| not_found(name))
}

/// Known SHA256 pins of the node's `[host]:port`.
pub fn pins(known: &KnownHosts, node: &Node) -> Result<Vec<Fingerprint>> {
    let key = endpoint_key(&node.ip, node.port)?;
    Ok(known.0.get(&key).cloned().unwrap_or_default())
}

/// Replace the pins of `[host]:port` with exactly `fingerprints` (agreed by
/// the caller). Other endpoints are untouched.
pub fn pin(state: &State, host: &str, port: u16, fingerprints: Vec<Fingerprint>) -> Result<()> {
    let mut known = state.load_known_hosts()?;
    let key = endpoint_key(host, port)?;
    if fingerprints.is_empty() {
        known.0.remove(&key);
    } else {
        known.0.insert(key, fingerprints);
    }
    state.save_known_hosts(&known)
}

/// The data directory belongs to a GitHub source (portability rules apply).
pub fn is_github(session: &Session) -> bool {
    session.github.is_some()
}

/// Open portability issues that block SSH for this node (GitHub only).
pub fn pending_setup(manifest: &Manifest, node: &Node) -> bool {
    manifest.portability.issues.iter().any(|issue| issue.node_id == node.id
        && matches!(issue.reason, PortabilityReason::MissingIdentity | PortabilityReason::MissingHostKey))
}

/// v1 `ssh_require_portable`: a GitHub node with deferred SSH setup is not
/// contacted until `node setup-ssh` finishes it.
pub fn require_portable(session: &Session, node: &Node) -> Result<()> {
    if is_github(session) && pending_setup(&session.state.load_manifest()?, node) {
        return Err(RcError::new("needs_setup", format!(
            "Для ноды «{}» отложена SSH-настройка: выполните node setup-ssh.", node.name)).with_extra("name", node.name.clone()));
    }
    Ok(())
}

/// Add or remove one portability issue; status follows the issue list.
pub fn set_issue(manifest: &mut Manifest, node_id: &str, reason: PortabilityReason, present: bool) {
    let mut issues: Vec<PortabilityIssue> = manifest.portability.issues.drain(..)
        .filter(|issue| !(issue.node_id == node_id && issue.reason == reason)).collect();
    if present {
        issues.push(PortabilityIssue { node_id: node_id.into(), reason });
    }
    manifest.portability = Portability::from_issues(issues);
}

/// Authentication for a stored node: its password secret, its managed key
/// file, or the user's own SSH identity (`system`).
pub fn authentication(state: &State, node: &Node) -> Result<Authentication> {
    match node.auth {
        Auth::Password => {
            let password = match node.secret_id.as_deref().map(|id| state.secret_store().get(id)) {
                Some(Ok(Some(password))) => Some(password),
                Some(Ok(None)) | None => None,
                Some(Err(error)) if error.code == "missing_secret" => None,
                Some(Err(error)) => return Err(error),
            };
            password.map(Authentication::Password).ok_or_else(|| {
                RcError::new("missing_secret", format!("Пароль SSH ноды «{}» не сохранён.", node.name))
                    .with_extra("name", node.name.clone()).with_extra("secret", "password")
            })
        }
        Auth::Key => match node.identity.as_deref() {
            None | Some("" | "system") => Ok(Authentication::System),
            Some(id) => Ok(Authentication::Key { identity: state.paths().identities().join(id), passphrase: None }),
        },
    }
}

/// Connection options with the node's known pins; `expected` overrides them
/// with an operator-agreed fingerprint.
pub fn connect_options(state: &State, node: &Node, expected: Option<Fingerprint>) -> Result<ConnectOptions> {
    node.validate()?;
    let known = pins(&state.load_known_hosts()?, node)?;
    Ok(ConnectOptions {
        host: node.ip.clone(),
        port: node.port,
        user: node.user.clone(),
        auth: authentication(state, node)?,
        host_key: HostKeyPolicy { expected, known },
        timeout: CONNECT_TIMEOUT,
    })
}

/// Connect to a stored node under its pins. A changed server key names the
/// node in the message; the structured `{host,port,fingerprints}` stays.
pub async fn connect<T: RemoteTransport>(transport: &mut T, state: &State, node: &Node) -> Result<()> {
    let options = connect_options(state, node, None)?;
    transport.connect(options).await.map_err(|mut error| {
        match error.code {
            "host_key_changed" => error.message = format!("Ключ сервера ноды «{}» изменился.", node.name),
            "host_key_unknown" => error.message = format!(
                "Ключ сервера ноды «{}» не закреплён: проверьте отпечаток и выполните node trust-host-key.", node.name),
            "remote_failed" => error.message = format!("Не удалось подключиться к «{}».", node.name),
            _ => {}
        }
        error.with_extra("name", node.name.clone())
    })
}

/// POSIX single-quoted shell word for remote command text.
pub fn sh_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(test)]
pub(crate) mod testing {
    //! Shared fixtures for node tests: an open local session in a temp dir.
    use std::{cell::RefCell, rc::Rc};

    use crate::dispatch::{DispatchMode, Session};
    use crate::log::{Level, LogSink};
    use crate::state::{State, StatePaths};

    pub type Journal = Rc<RefCell<Vec<(Level, String)>>>;

    struct Recorder(Journal);

    impl LogSink for Recorder {
        fn log(&mut self, level: Level, text: &str) {
            self.0.borrow_mut().push((level, text.to_owned()));
        }
    }

    /// An open, authorized local session over `root` (initialized config).
    pub fn session(root: &std::path::Path) -> (Session, Journal) {
        let journal = Journal::default();
        let state = State::new(StatePaths::new(root));
        state.save_config(&crate::model::Config::default()).unwrap();
        let mut session = Session::new(state, DispatchMode::OneShot, Box::new(Recorder(journal.clone())));
        session.open = true;
        session.authorized = true;
        (session, journal)
    }

    pub fn invocation(argv: &[&str]) -> crate::cli::Invocation {
        crate::cli::parse(&argv.iter().map(|a| a.to_string()).collect::<Vec<_>>()).unwrap()
    }

    /// Byte fingerprint of every file under the data directory.
    pub fn fingerprint(root: &std::path::Path) -> std::collections::BTreeMap<String, Vec<u8>> {
        let mut map = std::collections::BTreeMap::new();
        let mut pending = vec![root.to_path_buf()];
        while let Some(dir) = pending.pop() {
            let Ok(entries) = std::fs::read_dir(&dir) else { continue };
            for entry in entries.flatten() {
                let path = entry.path();
                let rel = path.strip_prefix(root).unwrap().to_string_lossy().into_owned();
                if path.is_dir() { pending.push(path); } else { map.insert(rel, std::fs::read(&path).unwrap()); }
            }
        }
        map
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoting_and_issue_bookkeeping() {
        assert_eq!(sh_quote("a'b"), "'a'\\''b'");
        let mut manifest = Manifest::default();
        set_issue(&mut manifest, "n1", PortabilityReason::MissingHostKey, true);
        set_issue(&mut manifest, "n1", PortabilityReason::MissingHostKey, true);
        assert_eq!(manifest.portability.issues.len(), 1);
        assert_eq!(manifest.portability.status, crate::model::PortabilityStatus::NeedsSetup);
        set_issue(&mut manifest, "n1", PortabilityReason::MissingHostKey, false);
        assert_eq!(manifest.portability, Portability::default());
    }
}
