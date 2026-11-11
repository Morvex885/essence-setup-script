use serde::Serialize;
use serde_json::{Map, Value};

/// A transport-independent command failure. Sensitive input must never enter it.
#[derive(Debug, thiserror::Error, Serialize)]
#[error("{message}")]
pub struct RcError {
    pub code: &'static str,
    pub message: String,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
    /// Process exit status for one-shot CLI runs; serve always reports 0.
    #[serde(skip)]
    pub exit: u8,
}

impl RcError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into(), extra: Map::new(), exit: exit_code_for(code) }
    }

    pub fn with_extra(mut self, key: impl Into<String>, value: impl Into<Value>) -> Self {
        self.extra.insert(key.into(), value.into());
        self
    }

    /// Override the derived exit status (reserved for multi-status commands).
    pub fn with_exit(mut self, exit: u8) -> Self {
        self.exit = exit;
        self
    }

    pub fn exit_code(&self) -> u8 {
        self.exit
    }
}

/// 0 never appears on errors; 2 marks decisions the caller must resolve,
/// `host_key_unknown` and changed plans; 1 is every other failure.
pub fn exit_code_for(code: &str) -> u8 {
    if code == "usage" || code == "host_key_unknown" || code == "plan_changed" || code.ends_with("_required") {
        2
    } else {
        1
    }
}

impl From<std::io::Error> for RcError {
    fn from(error: std::io::Error) -> Self {
        Self::new("failed", format!("Ошибка доступа к состоянию: {error}"))
    }
}

impl From<serde_json::Error> for RcError {
    fn from(_: serde_json::Error) -> Self {
        Self::new("invalid", "Некорректный JSON состояния.")
    }
}

pub type Result<T, E = RcError> = std::result::Result<T, E>;
