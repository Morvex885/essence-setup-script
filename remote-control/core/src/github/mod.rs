//! GitHub configuration source (plan step 5, port of `github-config.sh` and the
//! GitHub half of `source.sh`).
//!
//! Layout under the data directory: `github-store/` (bare mirror),
//! `github-sessions/<id>/worktree` (one git worktree per open session),
//! `github-runtime/` (the materialized working state the commands use),
//! `credentials/gh/<login>/` (isolated gh profiles),
//! `credentials/github-config.agekey` (only with `--remember-key`),
//! `account-switch/` (crash-recoverable account change journal) and
//! `import-backups/` (local files replaced by `github-switch-local`).

pub mod commands;
pub mod exec;
pub mod store;
pub mod switch;
pub mod vault;

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

use crate::error::RcError;
use crate::validation as v;

pub const REPO_NAME: &str = "essence-remote-control-config";
pub const BRANCH: &str = "main";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncStatus { Clean, Pending, Offline }

impl SyncStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Clean => "clean",
            Self::Pending => "pending",
            Self::Offline => "offline",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Storage { Age, Plain }

impl Storage {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Age => "age",
            Self::Plain => "none",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "age" => Some(Self::Age),
            "none" => Some(Self::Plain),
            _ => None,
        }
    }
}

/// The immutable repository target of one GitHub session.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub owner: String,
    pub name: String,
    pub branch: String,
}

impl Target {
    pub fn new(owner: &str, name: &str, branch: &str) -> Self {
        Self { owner: owner.into(), name: name.into(), branch: branch.into() }
    }

    pub fn from_repo(repo: &str, branch: &str) -> Option<Self> {
        let (owner, name) = repo.split_once('/')?;
        (login_valid(owner) && v::github_repo_valid(repo) && v::github_branch_valid(branch))
            .then(|| Self::new(owner, name, branch))
    }

    pub fn repo(&self) -> String {
        format!("{}/{}", self.owner, self.name)
    }

    pub fn url(&self) -> String {
        format!("https://github.com/{}/{}.git", self.owner, self.name)
    }
}

/// GitHub account names: ASCII letters, digits and hyphens.
pub fn login_valid(login: &str) -> bool {
    !login.is_empty() && login.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

// ─── Diagnostics ─────────────────────────────────────────────────────────────

const HIDDEN: &str = "[скрыто]";
const SECRET_PREFIXES: [&str; 6] = ["github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_"];
const SECRET_KEYS: [&str; 4] = ["password", "passwd", "secret", "token"];

fn redact_token(token: &str, hide_next: &mut bool) -> String {
    if std::mem::take(hide_next) {
        return HIDDEN.into();
    }
    let lower = token.to_ascii_lowercase();
    // https://user:password@host → https://[скрыто]@host
    if let Some(scheme) = lower.find("://") {
        let rest = &token[scheme + 3..];
        if let Some(at) = rest.find('@') {
            if rest[..at].contains(':') && !rest[..at].contains('/') {
                return format!("{}{HIDDEN}{}", &token[..scheme + 3], &rest[at..]);
            }
        }
    }
    for prefix in SECRET_PREFIXES {
        if let Some(start) = lower.find(prefix) {
            let end = token[start..].find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
                .map_or(token.len(), |offset| start + offset);
            let tail = redact_token(&token[end..], &mut false);
            return format!("{}{HIDDEN}{tail}", &token[..start]);
        }
    }
    for key in SECRET_KEYS {
        if let Some(start) = lower.find(key) {
            let after = &token[start + key.len()..];
            if let Some(separator) = after.find(['=', ':']).filter(|index| after[..*index].is_empty()) {
                let cut = start + key.len() + separator + 1;
                if token[cut..].is_empty() {
                    *hide_next = true;
                    return token.into();
                }
                return format!("{}{HIDDEN}", &token[..cut]);
            }
        }
    }
    if matches!(lower.as_str(), "bearer" | "token" | "basic") {
        *hide_next = true;
    }
    token.into()
}

/// v1 `_github_safe_error`: printable text on one line, credentials in URLs,
/// GitHub tokens, `Authorization`/`Bearer` values and `password=`-style values
/// replaced by «[скрыто]», at most 500 characters.
pub fn safe_error(message: &str) -> String {
    let flat: String = message.chars()
        .map(|c| if c == '\n' || c == '\r' || c == '\t' { ' ' } else { c })
        .filter(|c| !c.is_control())
        .collect();
    let mut hide_next = false;
    let text = flat.split_whitespace().map(|token| redact_token(token, &mut hide_next))
        .collect::<Vec<_>>().join(" ");
    let text: String = text.chars().take(500).collect();
    if text.is_empty() { "операция завершилась с ошибкой без дополнительного сообщения".into() } else { text }
}

/// A failed GitHub stage: `source_failed` with the stage and redacted detail.
pub fn fail(stage: &str, detail: impl AsRef<str>) -> RcError {
    RcError::new("source_failed", safe_error(detail.as_ref())).with_extra("stage", stage)
}

/// A stage failure that the user resolves by authorizing the account.
pub fn auth_fail(stage: &str, detail: impl AsRef<str>, hint: Option<String>) -> RcError {
    let mut error = fail(stage, detail).with_extra("auth_relevant", true);
    if let Some(hint) = hint {
        error = error.with_extra("hint", safe_error(&hint));
    }
    error
}

pub fn is_auth_relevant(error: &RcError) -> bool {
    error.extra.get("auth_relevant") == Some(&Value::Bool(true))
}

pub fn stage_of(error: &RcError) -> Option<&str> {
    error.extra.get("stage").and_then(Value::as_str)
}

/// Command boundary (v1 `_cli_source_fail`): a decision or explicit code is
/// returned unchanged; a stage failure becomes `code` with the prefixed message.
pub fn prefixed(mut error: RcError, prefix: &str, code: &'static str) -> RcError {
    if error.code != "source_failed" {
        return error;
    }
    if let Some(stage) = stage_of(&error).map(str::to_owned) {
        error.message = format!("{prefix} (этап: {stage}): {}", error.message);
    }
    error.code = code;
    error.exit = crate::error::exit_code_for(code);
    error
}

/// UTC `YYYYMMDDTHHMMSSZ` without a calendar dependency.
pub fn utc_stamp() -> String {
    let seconds = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let (days, rest) = (seconds / 86_400, seconds % 86_400);
    // Howard Hinnant's civil_from_days.
    let z = days as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}{month:02}{day:02}T{:02}{:02}{:02}Z", rest / 3600, rest % 3600 / 60, rest % 60)
}

pub fn random_hex(bytes: usize) -> String {
    let mut buffer = vec![0u8; bytes];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut buffer);
    hex::encode(buffer)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diagnostics_hide_credentials_and_stay_bounded() {
        let raw = "fatal: https://user:pa55@github.com/o/r.git ghp_AbC123 x=github_pat_11AAA Authorization: Bearer abc.def \
                   token qwerty password=hunter2 secret: s3cr3t\nline two\u{1b}[0m";
        let safe = safe_error(raw);
        for leaked in ["pa55", "AbC123", "11AAA", "abc.def", "qwerty", "hunter2", "s3cr3t", "\u{1b}"] {
            assert!(!safe.contains(leaked), "{leaked} leaked in {safe}");
        }
        assert!(safe.contains("https://[скрыто]@github.com/o/r.git") && safe.contains("line two"));
        assert_eq!(safe_error(&"a".repeat(900)).chars().count(), 500);
        assert_eq!(safe_error(" \n"), "операция завершилась с ошибкой без дополнительного сообщения");
    }

    #[test]
    fn stage_failures_are_prefixed_at_the_command_boundary() {
        let error = prefixed(fail("отправка конфигурации в GitHub", "push rejected"), "Не удалось отправить", "remote_failed");
        assert_eq!((error.code, error.exit), ("remote_failed", 1));
        assert_eq!(error.message, "Не удалось отправить (этап: отправка конфигурации в GitHub): push rejected");
        let decision = prefixed(RcError::new("storage_mode_required", "x"), "p", "remote_failed");
        assert_eq!((decision.code, decision.exit), ("storage_mode_required", 2));
    }

    #[test]
    fn stamps_targets_and_logins() {
        let stamp = utc_stamp();
        assert_eq!(stamp.len(), 16);
        assert!(stamp.starts_with("20") && stamp.ends_with('Z'));
        let target = Target::from_repo("owner-1/essence-remote-control-config", "main").unwrap();
        assert_eq!(target.url(), "https://github.com/owner-1/essence-remote-control-config.git");
        assert!(Target::from_repo("own_er/repo", "main").is_none());
        assert!(!login_valid("a/b") && login_valid("Test-Owner"));
    }
}
