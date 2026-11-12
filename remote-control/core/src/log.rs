//! Command journal: native levels and a transport-owned sink.
//!
//! Handlers report progress through the session's sink; the daemon turns
//! entries into protocol `log` events tagged with the active request id, and
//! the CLI prints those to stderr. Secrets must never be passed as journal text.

use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Info,
    Success,
    Warn,
    Error,
    Output,
}

impl Level {
    /// v1 status prefixes (`common.sh`); plain output has none.
    pub fn prefix(self) -> &'static str {
        match self {
            Self::Info => "  [*] ",
            Self::Success => "  [✓] ",
            Self::Warn => "  [!] ",
            Self::Error => "  [✗] ",
            Self::Output => "",
        }
    }
}

/// Receives journal entries of the command currently being dispatched.
pub trait LogSink {
    fn log(&mut self, level: Level, text: &str);
}

/// Tab, printable ASCII and everything from U+00A0 survive; NUL, other C0,
/// DEL and C1 controls are removed (v1 serve pump filter).
pub fn sanitize(text: &str) -> String {
    text.chars().filter(|c| matches!(*c, '\t' | '\u{20}'..='\u{7e}' | '\u{a0}'..)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_strips_c0_c1_and_keeps_text() {
        assert_eq!(sanitize("a\tb"), "a\tb");
        assert_eq!(sanitize("a\0b\u{7f}c\u{9b}d\r\n"), "abcd");
        assert_eq!(sanitize("\u{1b}[31mкрасный\u{1b}[0m"), "[31mкрасный[0m");
        assert_eq!(sanitize("юникод \u{a0} сохраняется"), "юникод \u{a0} сохраняется");
    }
}
