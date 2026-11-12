//! Terminal jobs: `node shell` and `telegram menu` split into a preparation
//! inside the session (lookup, connect, script checks, journal) and a run on
//! the requester's console that needs no session. The daemon prepares in its
//! core thread and runs the job on a terminal thread.

use serde_json::{Value, json};

use crate::error::{RcError, Result};
use crate::transport::{PtyRequest, RawConsole, RemoteTransport};

/// `tty_required` for a command that needs a console (`node shell`,
/// `telegram menu`) but the request carried none.
pub fn tty_required(noun: &str) -> RcError {
    let message = if noun == "telegram" { "Меню Telegram Proxy требует терминала." } else { "Меню сервера требует терминала." };
    RcError::new("tty_required", message)
}

/// A connected remote command waiting for a console.
pub struct TerminalJob<T: RemoteTransport> {
    /// The node name: the daemon's terminal registry key.
    pub node: String,
    /// Journal line after a successful session.
    pub done_log: &'static str,
    command: String,
    failure: String,
    transport: T,
}

impl<T: RemoteTransport> TerminalJob<T> {
    pub(crate) fn new(node: String, command: String, failure: String, done_log: &'static str, transport: T) -> Self {
        Self { node, done_log, command, failure, transport }
    }

    /// A job over any transport, for front-end tests (a fake whose
    /// `interactive` never ends); production jobs come from `prepare_terminal`.
    #[doc(hidden)]
    pub fn for_test(node: String, command: String, failure: String, done_log: &'static str, transport: T) -> Self {
        Self::new(node, command, failure, done_log, transport)
    }

    /// Ok(0) → Ok(json!({})); code ≠ 0 → remote_failed{name, exit_status};
    /// error → remote_failed{name, reason}.
    pub async fn run(self, pty: PtyRequest, console: &mut dyn RawConsole) -> Result<Value> {
        let status = self.transport.interactive(&self.command, pty, console).await;
        let failed = || RcError::new("remote_failed", self.failure.clone()).with_extra("name", self.node.clone());
        match status {
            Ok(0) => Ok(json!({})),
            Ok(code) => Err(failed().with_extra("exit_status", code)),
            Err(error) => Err(failed().with_extra("reason", error.extra.get("reason").cloned().unwrap_or(Value::Null))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tty_required_names_the_menu() {
        let node = tty_required("node");
        assert_eq!((node.code, node.message.as_str(), node.exit_code()), ("tty_required", "Меню сервера требует терминала.", 2));
        assert_eq!(tty_required("telegram").message, "Меню Telegram Proxy требует терминала.");
    }

    #[test]
    fn a_production_job_moves_to_a_terminal_thread() {
        fn send<J: Send>() {}
        send::<TerminalJob<crate::ssh::SshTransport>>();
    }
}
