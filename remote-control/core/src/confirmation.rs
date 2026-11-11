//! Plan-token confirmation, ported byte-for-byte from the Bash core.
//!
//! The scope is `noun verb` (including the trailing space for bare nouns)
//! followed by every original flag argument except the consent globals. The
//! token is the first 16 hex characters of SHA-256 over the scope, each plan
//! line and the opaque extra, each followed by a newline except the extra.

use sha2::{Digest, Sha256};

use crate::{cli::Invocation, error::{RcError, Result}};

/// A mutation plan: human-readable lines plus an opaque token component.
#[derive(Clone, Debug, Default)]
pub struct Plan {
    pub lines: Vec<String>,
    pub extra: String,
}

impl Plan {
    pub fn new(lines: Vec<String>, extra: impl Into<String>) -> Self {
        Self { lines, extra: extra.into() }
    }

    /// Consent scope over the original command flags, excluding consent globals.
    pub fn scope(noun: &str, verb: &str, argv: &[String]) -> String {
        let mut scope = format!("{noun} {verb}");
        let mut skip_value = false;
        for argument in argv {
            if skip_value {
                skip_value = false;
                continue;
            }
            match argument.as_str() {
                "--yes" | "--json" => continue,
                _ if argument.starts_with("--plan-token=") => continue,
                "--plan-token" => {
                    skip_value = true;
                    continue;
                }
                _ => {}
            }
            scope.push('\n');
            scope.push_str(argument);
        }
        scope
    }

    /// First 16 hex characters of SHA-256 over the scope, lines and extra.
    pub fn token(&self, noun: &str, verb: &str, argv: &[String]) -> String {
        let mut hasher = Sha256::new();
        hasher.update(Self::scope(noun, verb, argv));
        hasher.update(b"\n");
        for line in &self.lines {
            hasher.update(line.as_bytes());
            hasher.update(b"\n");
        }
        hasher.update(self.extra.as_bytes());
        hex::encode(&hasher.finalize()[..8])
    }

    /// Enforce consent before any mutation, over the invocation's original
    /// flag arguments. `--yes` alone consents; a supplied token must match the
    /// current plan exactly. `--plan-token` without `--yes` is rejected earlier
    /// by the parser (`usage`).
    pub fn confirm(&self, invocation: &Invocation) -> Result<()> {
        let token = self.token(&invocation.noun, &invocation.verb, invocation.confirmation_args());
        if !invocation.yes {
            return Err(RcError::new(
                "confirmation_required",
                "Требуется подтверждение: повторите команду с --yes.",
            ).with_extra("plan", serde_json::json!(&self.lines))
             .with_extra("plan_token", token));
        }
        if let Some(supplied) = invocation.plan_token.as_deref() {
            if !supplied.is_empty() && supplied != token {
                return Err(RcError::new(
                    "plan_changed",
                    "План изменился: проверьте его и подтвердите заново.",
                ).with_extra("plan", serde_json::json!(&self.lines))
                 .with_extra("plan_token", token));
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|arg| arg.to_string()).collect()
    }

    /// Literal tokens produced by the v1 Bash core (`_rc_confirm_scope` in
    /// cli.sh and `rc_plan_token` in state.sh, openssl SHA-256) for the same
    /// scope arguments, plan lines and extra.
    #[test]
    fn tokens_match_bash_reference_outputs() {
        let remove = Plan::new(args(&[
            "Пароль запуска remote-control будет удалён.",
            "Локальные данные и SSH-ключи сохранятся.",
        ]), "");
        let remove_args = args(&["--json", "--yes", "--plan-token=abc"]);
        assert_eq!(Plan::scope("self", "password-remove", &remove_args), "self password-remove");
        assert_eq!(remove.token("self", "password-remove", &remove_args), "09c26975fdb6404d");

        let delete = Plan::new(args(&["Нода «тест» будет удалена.", "Second line"]), "bundle-sha256:0f0e");
        let delete_args = args(&["--name", "n1", "--plan-token", "0123456789abcdef", "--yes", "--scope", "server"]);
        assert_eq!(Plan::scope("node", "delete", &delete_args), "node delete\n--name\nn1\n--scope\nserver");
        assert_eq!(delete.token("node", "delete", &delete_args), "5f4bd8ff7d3c630c");

        let bare = Plan::new(Vec::new(), "2.0.0");
        let bare_args = args(&["--all"]);
        assert_eq!(Plan::scope("generate", "", &bare_args), "generate \n--all");
        assert_eq!(bare.token("generate", "", &bare_args), "e79bb8ecf88e25ff");
    }

    #[test]
    fn consent_requires_yes_and_matches_only_the_current_token() {
        let plan = Plan::new(args(&["Удалить пароль запуска."]), "");
        let parse = |list: &[&str]| crate::cli::parse(&args(list)).unwrap();
        let error = plan.confirm(&parse(&["self", "password-remove"])).unwrap_err();
        assert_eq!((error.code, error.exit), ("confirmation_required", 2));
        assert_eq!(error.extra["plan"], serde_json::json!(["Удалить пароль запуска."]));
        let token = error.extra["plan_token"].as_str().unwrap().to_owned();
        assert!(plan.confirm(&parse(&["self", "password-remove", "--yes", "--plan-token", &token])).is_ok());
        assert!(plan.confirm(&parse(&["--yes", "self", "password-remove", &format!("--plan-token={token}")])).is_ok());
        assert!(plan.confirm(&parse(&["self", "password-remove", "--yes"])).is_ok());
        // --secrets-stdin is a transport flag, outside the scope.
        assert!(plan.confirm(&parse(&["self", "password-remove", "--secrets-stdin", "--yes", "--plan-token", &token])).is_ok());
        let changed = plan.confirm(&parse(&["self", "password-remove", "--yes", "--plan-token", "0000000000000000"]))
            .unwrap_err();
        assert_eq!((changed.code, changed.exit), ("plan_changed", 2));
        assert_eq!(changed.extra["plan_token"], token.as_str());
    }
}
