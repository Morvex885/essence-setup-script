//! `node upload-scripts` and the shared "server scripts are current" step
//! (v1 `_remote_scripts_probe`, `upload_scripts`, `ensure_remote_scripts_current`).
//! The server kit is published by `ServerBundle` in one SFTP operation
//! (VERSION last) instead of v1's seven ssh/scp round trips.

use serde_json::{Value, json};

use crate::bundle::ServerBundle;
use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::transport::{RemoteSession, RemoteTransport};

use super::{COMMAND_TIMEOUT, LONG_TIMEOUT, connect, find, require_portable, required, sh_quote};

/// Server installation directory (v1 `REMOTE_DIR`).
pub const REMOTE_DIR: &str = "/root/essence-setup";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScriptsState {
    Missing,
    Ready,
    Broken,
    Unknown,
}

impl ScriptsState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Missing => "missing",
            Self::Ready => "ready",
            Self::Broken => "broken",
            Self::Unknown => "unknown",
        }
    }
}

/// Server scripts after `ensure_current`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Scripts {
    pub state: ScriptsState,
    pub version: Option<String>,
    pub uploaded: bool,
}

/// Normalized `X.Y.Z` server kit version.
pub type Version = (u32, u32, u32);

/// v1 `_remote_scripts_normalize_version`: one trailing CR and a leading `v`
/// are dropped; exactly three groups of 1–9 digits.
fn parse_version(raw: &str) -> Option<Version> {
    let raw = raw.strip_suffix('\r').unwrap_or(raw);
    let raw = raw.strip_prefix('v').unwrap_or(raw);
    let mut parts = raw.split('.').map(|part| {
        ((1..=9).contains(&part.len()) && part.bytes().all(|b| b.is_ascii_digit())).then(|| part.parse::<u32>().ok()).flatten()
    });
    let version = (parts.next()??, parts.next()??, parts.next()??);
    parts.next().is_none().then_some(version)
}

pub fn format_version((major, minor, patch): Version) -> String {
    format!("{major}.{minor}.{patch}")
}

/// Version of the embedded server kit.
pub fn local() -> Result<Version> {
    parse_version(crate::VERSION)
        .ok_or_else(|| RcError::new("invalid", "Некорректный локальный VERSION: подготовка скриптов остановлена."))
}

/// Normalized version of the embedded server kit (`X.Y.Z`).
pub fn local_version() -> Result<String> {
    local().map(format_version)
}

/// Exact remote probe text (v1 `_remote_scripts_probe`).
pub fn probe_command() -> String {
    format!(r#"dir={}
if [[ ! -e "$dir" && ! -L "$dir" ]]; then printf 'MISSING'; exit 0; fi
if [[ ! -d "$dir" ]]; then printf 'BROKEN'; exit 0; fi
[[ -r "$dir" && -x "$dir" ]] || exit 1
entries=$(ls -A "$dir" && printf '.') || exit 1
if [[ "$entries" == '.' ]]; then printf 'MISSING'; exit 0; fi
if [[ -x "$dir/setup-essence.sh" && -f "$dir/setup-essence.sh" ]]; then
    printf 'PRESENT'
else
    printf 'BROKEN'
fi
if [[ -e "$dir/VERSION" || -L "$dir/VERSION" ]]; then
    [[ -f "$dir/VERSION" && -r "$dir/VERSION" ]] || exit 1
    printf '\n'
    cat "$dir/VERSION" || exit 1
fi"#, sh_quote(REMOTE_DIR))
}

/// State and version of the server scripts; `None` when the probe failed or
/// answered something unrecognized.
pub async fn probe<S: RemoteSession>(session: &S) -> Option<(ScriptsState, Option<Version>)> {
    let result = session.exec(&probe_command(), b"", COMMAND_TIMEOUT).await.ok()?;
    if result.exit_status != 0 {
        return None;
    }
    let text = String::from_utf8(result.stdout).ok()?;
    // v1 read the answer through command substitution: trailing newlines go.
    let text = text.trim_end_matches('\n');
    let (head, version) = match text.split_once('\n') {
        Some((head, version)) => (head, Some(version)),
        None => (text, None),
    };
    let state = match head {
        "MISSING" if version.is_none() => return Some((ScriptsState::Missing, None)),
        "PRESENT" => ScriptsState::Ready,
        "BROKEN" => ScriptsState::Broken,
        _ => return None,
    };
    let version = version.and_then(parse_version);
    let state = if state == ScriptsState::Ready && version.is_none() { ScriptsState::Unknown } else { state };
    Some((state, version))
}

fn probe_failed(node_name: &str) -> RcError {
    RcError::new("remote_failed", format!("Не удалось определить состояние скриптов на ноде «{node_name}».")).with_extra("name", node_name)
}

/// v1 `ensure_remote_scripts_current [--force]` over an authenticated
/// session: without `force` the kit is uploaded only when it is missing or
/// older than the local one; `force` replaces it unconditionally (consent is
/// the caller's plan). After an upload the server must report the local version.
pub async fn ensure_current<S: RemoteSession>(session: &S, node_name: &str, force: bool) -> Result<Scripts> {
    let local = local()?;
    let (state, remote) = probe(session).await.ok_or_else(|| probe_failed(node_name))?;
    if !force {
        match state {
            ScriptsState::Ready if remote.is_some_and(|remote| local <= remote) => {
                return Ok(Scripts { state, version: remote.map(format_version), uploaded: false });
            }
            ScriptsState::Ready | ScriptsState::Missing => {}
            ScriptsState::Unknown | ScriptsState::Broken => {
                return Err(RcError::new("invalid", format!(
                    "На ноде «{node_name}» версия скриптов неизвестна или установка повреждена. Загрузите скрипты принудительно: node upload-scripts --force."))
                    .with_extra("name", node_name).with_extra("state", state.as_str()));
            }
        }
    }
    ServerBundle.upload(session, REMOTE_DIR, LONG_TIMEOUT).await.map_err(|error| {
        let failure = RcError::new("remote_failed", format!("Не удалось загрузить скрипты на ноду «{node_name}»."))
            .with_extra("name", node_name);
        match error.extra.get("reason") {
            Some(reason) => failure.with_extra("reason", reason.clone()),
            None => failure,
        }
    })?;
    match probe(session).await {
        Some((ScriptsState::Ready, Some(version))) if version == local => {
            Ok(Scripts { state: ScriptsState::Ready, version: Some(format_version(local)), uploaded: true })
        }
        _ => Err(RcError::new("remote_failed", format!("Версия скриптов на ноде «{node_name}» после загрузки не подтверждена."))
            .with_extra("name", node_name)),
    }
}

/// v1 `_remote_scripts_force_plan`.
fn force_plan(name: &str, ip: &str, local: Version, state: ScriptsState, remote: Option<Version>) -> Vec<String> {
    let remote_label = match (state, remote) {
        (ScriptsState::Missing, _) => "скрипты отсутствуют".to_owned(),
        (ScriptsState::Broken, Some(version)) => format!("установка повреждена (версия {})", format_version(version)),
        (ScriptsState::Broken, None) => "установка повреждена".to_owned(),
        (ScriptsState::Ready, Some(version)) => format_version(version),
        _ => "неизвестна".to_owned(),
    };
    vec![
        format!("Нода: {name} ({ip})"),
        format!("Локальная версия: {}", format_version(local)),
        format!("Серверная версия: {remote_label}"),
        "Локальные скрипты заменят серверные, включая ручные изменения;".to_owned(),
        "версия может быть понижена.".to_owned(),
    ]
}

/// `node upload-scripts --name N [--force]`.
pub async fn upload<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, transport: &mut T) -> Result<Value> {
    let name = required(invocation, "name")?;
    let node = find(&session.state.load_config()?, name)?.clone();
    require_portable(session, &node)?;
    let force = invocation.has("force");
    if force {
        // The plan names the replaced version; consent comes before any upload.
        let local = local()?;
        connect(transport, &session.state, &node).await?;
        let (state, remote) = probe(&*transport).await.ok_or_else(|| {
            RcError::new("remote_failed", format!("Не удалось проверить скрипты на ноде «{name}».")).with_extra("name", name)
        })?;
        Plan::new(force_plan(name, &node.ip, local, state, remote), "").confirm(invocation)?;
    } else {
        connect(transport, &session.state, &node).await?;
    }
    let scripts = ensure_current(&*transport, name, force).await?;
    if scripts.uploaded {
        session.log(Level::Success, &format!("Скрипты загружены на {}@{} ({REMOTE_DIR})", node.user, node.ip));
    }
    Ok(json!({"name": name, "state": scripts.state.as_str(), "version": scripts.version.unwrap_or_default()}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeTransport, Operation, ScriptStep};
    use crate::model::{Auth, Config, Fingerprint, Node};
    use crate::nodes::{CONNECT_TIMEOUT, pin, testing};
    use crate::transport::{ExecResult, HostKeyPolicy};

    fn fingerprint() -> Fingerprint {
        format!("SHA256:{}A", "Q".repeat(42)).parse().unwrap()
    }

    fn seed(session: &Session) {
        let node = Node {
            id: "0123456789abcdef0123456789abcdef".into(), name: "de".into(), ip: "198.51.100.7".into(), port: 22,
            user: "root".into(), auth: Auth::Key, identity: Some("system".into()), secret_id: None,
            tag: Some("DE".into()), aliases: Default::default(), ..Node::default()
        };
        session.state.save_config(&Config { nodes: vec![node], ..Config::default() }).unwrap();
        pin(&session.state, "198.51.100.7", 22, vec![fingerprint()]).unwrap();
    }

    fn connect_step() -> ScriptStep {
        ScriptStep::connect(
            ConnectExpectation::new("198.51.100.7", 22, "root", AuthMethod::System, CONNECT_TIMEOUT)
                .with_host_key(HostKeyPolicy { expected: None, known: vec![fingerprint()] }),
            Ok(()),
        )
    }

    fn probe_step(stdout: &str) -> ScriptStep {
        ScriptStep::exec(probe_command(), 0, COMMAND_TIMEOUT,
            Ok(ExecResult { stdout: stdout.as_bytes().to_vec(), stderr: Vec::new(), exit_status: 0 }))
    }

    fn present(version: &str) -> String {
        format!("PRESENT\n{version}\n")
    }

    #[test]
    fn versions_normalize_like_v1() {
        assert_eq!(parse_version("v01.2.3\r"), Some((1, 2, 3)));
        assert_eq!(parse_version("1.2"), None);
        assert_eq!(parse_version("1.2.3.4"), None);
        assert_eq!(parse_version("1.2.3\nx"), None);
        assert_eq!(parse_version("1234567890.0.0"), None);
        assert!(local_version().is_ok());
    }

    #[tokio::test]
    async fn current_scripts_are_not_uploaded() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = testing::session(root.path());
        seed(&session);
        let local = local_version().unwrap();
        let mut transport = FakeTransport::new([connect_step(), probe_step(&present(&local))]);
        let data = upload(&mut session, &testing::invocation(&["node", "upload-scripts", "--name", "de"]), &mut transport)
            .await.unwrap();
        assert_eq!(data, json!({"name": "de", "state": "ready", "version": local}));
        transport.assert_finished();
    }

    #[tokio::test]
    async fn missing_scripts_are_uploaded_once_and_confirmed() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = testing::session(root.path());
        seed(&session);
        let local = local_version().unwrap();
        let mut transport = FakeTransport::new([
            connect_step(),
            probe_step("MISSING"),
            ScriptStep::upload_any_local(REMOTE_DIR, LONG_TIMEOUT, Ok(())),
            probe_step(&present(&local)),
        ]);
        let data = upload(&mut session, &testing::invocation(&["node", "upload-scripts", "--name", "de"]), &mut transport)
            .await.unwrap();
        assert_eq!(data, json!({"name": "de", "state": "ready", "version": local}));
        transport.assert_finished();
        assert_eq!(transport.journal().iter().filter(|op| matches!(op, Operation::Upload { .. })).count(), 1);
        assert!(journal.borrow().iter().any(|(level, text)| *level == Level::Success && text.starts_with("Скрипты загружены")));
    }

    #[tokio::test]
    async fn broken_install_requires_force_and_unconfirmed_upload_after_wrong_version_fails() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = testing::session(root.path());
        seed(&session);
        let mut transport = FakeTransport::new([connect_step(), probe_step("BROKEN")]);
        let error = upload(&mut session, &testing::invocation(&["node", "upload-scripts", "--name", "de"]), &mut transport)
            .await.unwrap_err();
        assert_eq!(error.code, "invalid");
        transport.assert_finished();

        let mut transport = FakeTransport::new([
            connect_step(),
            probe_step("MISSING"),
            ScriptStep::upload_any_local(REMOTE_DIR, LONG_TIMEOUT, Ok(())),
            probe_step(&present("0.0.1")),
        ]);
        let error = upload(&mut session, &testing::invocation(&["node", "upload-scripts", "--name", "de"]), &mut transport)
            .await.unwrap_err();
        assert_eq!(error.code, "remote_failed");
        assert!(error.message.contains("после загрузки не подтверждена"));
        transport.assert_finished();
    }

    #[tokio::test]
    async fn forced_upload_plans_then_replaces_a_newer_server_version() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = testing::session(root.path());
        seed(&session);
        let local = local_version().unwrap();
        let before = testing::fingerprint(root.path());
        let mut transport = FakeTransport::new([connect_step(), probe_step(&present("999.0.0"))]);
        let error = upload(&mut session, &testing::invocation(&["node", "upload-scripts", "--name", "de", "--force"]), &mut transport)
            .await.unwrap_err();
        assert_eq!(error.code, "confirmation_required");
        assert_eq!(error.extra["plan"], json!([
            "Нода: de (198.51.100.7)", format!("Локальная версия: {local}"), "Серверная версия: 999.0.0",
            "Локальные скрипты заменят серверные, включая ручные изменения;", "версия может быть понижена.",
        ]));
        transport.assert_finished();
        assert_eq!(testing::fingerprint(root.path()), before);

        let mut transport = FakeTransport::new([
            connect_step(),
            probe_step(&present("999.0.0")),
            probe_step(&present("999.0.0")),
            ScriptStep::upload_any_local(REMOTE_DIR, LONG_TIMEOUT, Ok(())),
            probe_step(&present(&local)),
        ]);
        let data = upload(&mut session, &testing::invocation(&["node", "upload-scripts", "--name", "de", "--force", "--yes"]), &mut transport)
            .await.unwrap();
        assert_eq!(data, json!({"name": "de", "state": "ready", "version": local}));
        transport.assert_finished();
    }
}
