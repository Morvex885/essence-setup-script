//! The shared "server scripts are current" step of the remaining
//! script-driven commands (v1 `_remote_scripts_probe`,
//! `ensure_remote_scripts_current`). The server kit is published by
//! `ServerBundle` in one SFTP operation (VERSION last).

use crate::bundle::ServerBundle;
use crate::error::{RcError, Result};
use crate::transport::RemoteSession;

use super::{COMMAND_TIMEOUT, LONG_TIMEOUT, sh_quote};

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
                    "На ноде «{node_name}» версия скриптов неизвестна или установка повреждена."))
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake_transport::{FakeTransport, Operation, ScriptStep};
    use crate::fake_transport::{AuthMethod, ConnectExpectation};
    use crate::transport::{Authentication, ConnectOptions, ExecResult, HostKeyPolicy, RemoteTransport};

    fn probe_step(stdout: &str) -> ScriptStep {
        ScriptStep::exec(probe_command(), 0, COMMAND_TIMEOUT,
            Ok(ExecResult { stdout: stdout.as_bytes().to_vec(), stderr: Vec::new(), exit_status: 0 }))
    }

    async fn connected(steps: Vec<ScriptStep>) -> FakeTransport {
        let timeout = std::time::Duration::from_secs(5);
        let mut all = vec![ScriptStep::connect(ConnectExpectation::new("h", 22, "root", AuthMethod::System, timeout), Ok(()))];
        all.extend(steps);
        let mut transport = FakeTransport::new(all);
        transport.connect(ConnectOptions { host: "h".into(), port: 22, user: "root".into(), auth: Authentication::System,
            host_key: HostKeyPolicy::default(), timeout }).await.unwrap();
        transport
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
    async fn current_scripts_stay_and_missing_ones_are_uploaded_once() {
        let local = local_version().unwrap();
        let transport = connected(vec![probe_step(&format!("PRESENT\n{local}\n"))]).await;
        assert!(!ensure_current(&transport, "de", false).await.unwrap().uploaded);
        transport.assert_finished();

        let transport = connected(vec![probe_step("MISSING"), ScriptStep::upload_any_local(REMOTE_DIR, LONG_TIMEOUT, Ok(())),
            probe_step(&format!("PRESENT\n{local}\n"))]).await;
        assert!(ensure_current(&transport, "de", false).await.unwrap().uploaded);
        transport.assert_finished();
        assert_eq!(transport.journal().iter().filter(|op| matches!(op, Operation::Upload { .. })).count(), 1);

        let transport = connected(vec![probe_step("BROKEN")]).await;
        let error = ensure_current(&transport, "de", false).await.unwrap_err();
        assert_eq!((error.code, error.extra["state"].as_str()), ("invalid", Some("broken")));
    }
}
