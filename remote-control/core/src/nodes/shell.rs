//! `node shell --name N`: the server menu (`setup-essence.sh`) on a remote
//! pseudo-terminal bound to the operator's console (v1 `cli_cmd_node_shell`
//! and `run_remote`). Requires a console before any remote effect; the
//! session has no deadline and raw mode is restored on every exit path.

use serde_json::{Value, json};

use crate::cli::Invocation;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::transport::{PtyRequest, RemoteTransport};

use super::{connect, find, require_portable, required, scripts, sh_quote};

fn tty_required() -> RcError {
    RcError::new("tty_required", "Меню сервера требует терминала.")
}

pub async fn shell<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, transport: &mut T) -> Result<Value> {
    let name = required(invocation, "name")?;
    if !session.console().is_some_and(|console| console.available()) {
        return Err(tty_required());
    }
    let node = find(&session.state.load_config()?, name)?.clone();
    require_portable(session, &node)?;
    session.log(Level::Info, &format!("Подключаемся к {} ({}@{}:{})...", node.name, node.user, node.ip, node.port));
    connect(transport, &session.state, &node).await?;
    session.log(Level::Success, "Соединение установлено");
    if scripts::ensure_current(&*transport, &node.name, false).await?.uploaded {
        session.log(Level::Success, "Скрипты загружены");
    }
    session.log(Level::Info, &format!("Открываю интерактивную SSH-сессию на {} ({})...", node.name, node.ip));
    session.log(Level::Output, "  (введите 0 в меню сервера для выхода)");
    let command = format!("bash {}", sh_quote(&format!("{}/setup-essence.sh", scripts::REMOTE_DIR)));
    let failed = || RcError::new("remote_failed", format!("SSH-сессия с нодой «{}» завершилась с ошибкой.", node.name))
        .with_extra("name", node.name.clone());
    let status = {
        let console = session.console().ok_or_else(tty_required)?;
        let pty = PtyRequest { term: console.term(), size: console.size() };
        let mut raw = console.raw().map_err(|_| tty_required())?;
        transport.interactive(&command, pty, &mut *raw).await
    };
    match status {
        Ok(0) => {}
        Ok(code) => return Err(failed().with_extra("exit_status", code)),
        Err(error) => {
            let reason = error.extra.get("reason").cloned().unwrap_or(Value::Null);
            return Err(failed().with_extra("reason", reason));
        }
    }
    session.log(Level::Info, "SSH-сессия завершена.");
    Ok(json!({}))
}

#[cfg(test)]
mod tests {
    use std::{cell::RefCell, io, rc::Rc, task::{Context, Poll}};

    use super::*;
    use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeTransport, Operation, ScriptStep};
    use crate::model::{Auth, Config, Fingerprint, Node};
    use crate::nodes::testing::{fingerprint, invocation, session};
    use crate::nodes::{COMMAND_TIMEOUT, CONNECT_TIMEOUT, LONG_TIMEOUT, pin};
    use crate::transport::{Console, ConsoleEvent, ConsoleSize, ExecResult, HostKeyPolicy, RawConsole, remote_failure};

    const SIZE: ConsoleSize = ConsoleSize { cols: 132, rows: 43 };

    #[derive(Default)]
    struct Record {
        raw_entered: usize,
        raw_active: bool,
        output: Vec<u8>,
    }

    /// A console that records raw-mode bracketing and output.
    struct TestConsole {
        available: bool,
        record: Rc<RefCell<Record>>,
    }

    struct TestRaw {
        record: Rc<RefCell<Record>>,
    }

    impl Console for TestConsole {
        fn available(&mut self) -> bool { self.available }
        fn term(&self) -> String { "xterm-256color".into() }
        fn size(&self) -> ConsoleSize { SIZE }
        fn raw(&mut self) -> io::Result<Box<dyn RawConsole + '_>> {
            let mut record = self.record.borrow_mut();
            record.raw_entered += 1;
            record.raw_active = true;
            Ok(Box::new(TestRaw { record: self.record.clone() }))
        }
    }

    impl RawConsole for TestRaw {
        /// The fake transport never reads input; the wire test covers it.
        fn poll_event(&mut self, _: &mut Context<'_>) -> Poll<ConsoleEvent> {
            Poll::Pending
        }
        fn output(&mut self, data: &[u8]) -> io::Result<()> {
            assert!(self.record.borrow().raw_active, "output outside raw mode");
            self.record.borrow_mut().output.extend_from_slice(data);
            Ok(())
        }
    }

    impl Drop for TestRaw {
        fn drop(&mut self) { self.record.borrow_mut().raw_active = false; }
    }

    fn pin_fp() -> Fingerprint {
        format!("SHA256:{}", "A".repeat(43)).parse().unwrap()
    }

    fn node() -> Node {
        Node {
            id: "0123456789abcdef0123456789abcdef".into(), name: "alpha".into(), ip: "203.0.113.7".into(),
            port: 2222, user: "root".into(), auth: Auth::Key, identity: None, secret_id: None, tag: None,
            aliases: Default::default(),
        }
    }

    /// A stored node with a pinned host key; console attached when given.
    fn fixture(root: &std::path::Path, available: Option<bool>) -> (Session, crate::nodes::testing::Journal, Rc<RefCell<Record>>) {
        let (mut session, journal) = session(root);
        session.state.save_config(&Config { nodes: vec![node()], ..Config::default() }).unwrap();
        pin(&session.state, "203.0.113.7", 2222, vec![pin_fp()]).unwrap();
        let record = Rc::new(RefCell::new(Record::default()));
        if let Some(available) = available {
            session.set_console(Box::new(TestConsole { available, record: record.clone() }));
        }
        (session, journal, record)
    }

    fn connect_step() -> ScriptStep {
        ScriptStep::connect(
            ConnectExpectation::new("203.0.113.7", 2222, "root", AuthMethod::System, CONNECT_TIMEOUT)
                .with_host_key(HostKeyPolicy { expected: None, known: vec![pin_fp()] }),
            Ok(()),
        )
    }

    fn pty() -> PtyRequest {
        PtyRequest { term: "xterm-256color".into(), size: SIZE }
    }

    fn probe(stdout: String) -> ScriptStep {
        ScriptStep::exec(scripts::probe_command(), 0, COMMAND_TIMEOUT,
            Ok(ExecResult { stdout: stdout.into_bytes(), stderr: Vec::new(), exit_status: 0 }))
    }

    /// Server scripts already at the local version: one probe.
    fn current() -> Vec<ScriptStep> {
        vec![probe(format!("PRESENT\n{}\n", scripts::local_version().unwrap()))]
    }

    /// Missing server scripts: probe, upload, confirming probe.
    fn uploaded() -> Vec<ScriptStep> {
        vec![
            probe("MISSING".into()),
            ScriptStep::upload_any_local(scripts::REMOTE_DIR, LONG_TIMEOUT, Ok(())),
            probe(format!("PRESENT\n{}\n", scripts::local_version().unwrap())),
        ]
    }

    const COMMAND: &str = "bash '/root/essence-setup/setup-essence.sh'";

    fn run(session: &mut Session, transport: &mut FakeTransport) -> Result<Value> {
        let argv = invocation(&["node", "shell", "--name", "alpha"]);
        tokio::runtime::Builder::new_current_thread().build().unwrap()
            .block_on(shell(session, &argv, transport))
    }

    #[test]
    fn without_console_or_unavailable_terminal_is_tty_required_with_zero_effects() {
        for available in [None, Some(false)] {
            let root = tempfile::tempdir().unwrap();
            let (mut session, journal, record) = fixture(root.path(), available);
            let before = fingerprint(root.path());
            let mut transport = FakeTransport::new([]);
            let error = run(&mut session, &mut transport).unwrap_err();
            assert_eq!((error.code, error.message.as_str(), error.exit_code()), ("tty_required", "Меню сервера требует терминала.", 2));
            assert!(transport.journal().is_empty(), "no transport effects: {:?}", transport.journal());
            transport.assert_finished();
            assert!(journal.borrow().is_empty());
            assert_eq!(record.borrow().raw_entered, 0);
            assert_eq!(fingerprint(root.path()), before);
        }
    }

    #[test]
    fn serve_session_uses_only_an_attached_console() {
        // Public serve attaches nothing → tty_required; the TUI's `serve
        // --inner` child attaches the shared terminal → the gate passes inside
        // the same open session (no second process, no session lock).
        for attached in [false, true] {
            let root = tempfile::tempdir().unwrap();
            let state = crate::state::State::new(crate::state::StatePaths::new(root.path()));
            state.save_config(&Config { nodes: vec![node()], ..Config::default() }).unwrap();
            let journal = crate::nodes::testing::Journal::default();
            struct Sink(crate::nodes::testing::Journal);
            impl crate::log::LogSink for Sink {
                fn log(&mut self, level: Level, text: &str) { self.0.borrow_mut().push((level, text.into())); }
            }
            let mut session = Session::new(state, crate::dispatch::DispatchMode::Serve, Box::new(Sink(journal.clone())));
            session.open = true;
            session.authorized = true;
            let record = Rc::new(RefCell::new(Record::default()));
            if attached {
                session.set_console(Box::new(TestConsole { available: true, record: record.clone() }));
            }
            let mut transport = FakeTransport::new([]);
            let argv = invocation(&["node", "shell", "--name", "beta"]);
            let error = tokio::runtime::Builder::new_current_thread().build().unwrap()
                .block_on(shell(&mut session, &argv, &mut transport)).unwrap_err();
            assert_eq!(error.code, if attached { "not_found" } else { "tty_required" });
            assert!(transport.journal().is_empty());
            assert!(journal.borrow().is_empty());
            assert_eq!(record.borrow().raw_entered, 0);
        }
    }

    #[test]
    fn unknown_node_is_not_found_before_any_remote_effect() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal, _record) = fixture(root.path(), Some(true));
        let mut transport = FakeTransport::new([]);
        let argv = invocation(&["node", "shell", "--name", "beta"]);
        let error = tokio::runtime::Builder::new_current_thread().build().unwrap()
            .block_on(shell(&mut session, &argv, &mut transport)).unwrap_err();
        assert_eq!(error.code, "not_found");
        assert!(transport.journal().is_empty());
    }

    #[test]
    fn interactive_session_requests_a_pty_for_the_server_menu() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal, record) = fixture(root.path(), Some(true));
        let mut steps = vec![connect_step()];
        steps.extend(uploaded());
        steps.push(ScriptStep::interactive(COMMAND, pty(), b"\x1b[1mMENU\x1b[0m\r\n".to_vec(), Ok(0)));
        let mut transport = FakeTransport::new(steps);
        let before = fingerprint(root.path());
        assert_eq!(run(&mut session, &mut transport).unwrap(), json!({}));
        transport.assert_finished();
        assert_eq!(transport.journal().last(), Some(&Operation::Interactive { command: COMMAND.into(), pty: pty() }));
        let record = record.borrow();
        assert_eq!((record.raw_entered, record.raw_active), (1, false), "raw mode entered once and restored");
        assert_eq!(record.output, b"\x1b[1mMENU\x1b[0m\r\n");
        let lines: Vec<(Level, String)> = journal.borrow().clone();
        assert_eq!(lines, [
            (Level::Info, "Подключаемся к alpha (root@203.0.113.7:2222)...".to_owned()),
            (Level::Success, "Соединение установлено".to_owned()),
            (Level::Success, "Скрипты загружены".to_owned()),
            (Level::Info, "Открываю интерактивную SSH-сессию на alpha (203.0.113.7)...".to_owned()),
            (Level::Output, "  (введите 0 в меню сервера для выхода)".to_owned()),
            (Level::Info, "SSH-сессия завершена.".to_owned()),
        ]);
        assert_eq!(fingerprint(root.path()), before, "a shell session changes no local state");
    }

    #[test]
    fn nonzero_exit_or_broken_session_is_remote_failed_and_restores_raw_mode() {
        for (status, reason) in [(Ok(3), None), (Err(remote_failure("exit_signal")), Some("exit_signal"))] {
            let root = tempfile::tempdir().unwrap();
            let (mut session, journal, record) = fixture(root.path(), Some(true));
            let mut steps = vec![connect_step()];
            steps.extend(current());
            steps.push(ScriptStep::interactive(COMMAND, pty(), Vec::new(), status));
            let mut transport = FakeTransport::new(steps);
            let error = run(&mut session, &mut transport).unwrap_err();
            transport.assert_finished();
            assert_eq!(error.code, "remote_failed");
            assert_eq!(error.message, "SSH-сессия с нодой «alpha» завершилась с ошибкой.");
            assert_eq!(error.extra["name"], "alpha");
            match reason {
                None => assert_eq!(error.extra["exit_status"], 3),
                Some(reason) => assert_eq!(error.extra["reason"], reason),
            }
            assert_eq!((record.borrow().raw_entered, record.borrow().raw_active), (1, false));
            assert!(!journal.borrow().iter().any(|(_, text)| text == "SSH-сессия завершена."));
        }
    }

    #[test]
    fn changed_host_key_stops_before_the_menu() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal, record) = fixture(root.path(), Some(true));
        let changed = RcError::new("host_key_changed", "Ключ SSH-сервера не подтверждён.")
            .with_extra("host", "203.0.113.7").with_extra("port", 2222)
            .with_extra("fingerprints", json!([format!("SHA256:{}", "B".repeat(43))]));
        let mut transport = FakeTransport::new([ScriptStep::connect(
            ConnectExpectation::new("203.0.113.7", 2222, "root", AuthMethod::System, CONNECT_TIMEOUT)
                .with_host_key(HostKeyPolicy { expected: None, known: vec![pin_fp()] }),
            Err(changed),
        )]);
        let before = fingerprint(root.path());
        let error = run(&mut session, &mut transport).unwrap_err();
        transport.assert_finished();
        assert_eq!(error.code, "host_key_changed");
        assert_eq!(error.message, "Ключ сервера ноды «alpha» изменился.");
        assert_eq!(record.borrow().raw_entered, 0);
        assert_eq!(fingerprint(root.path()), before);
    }
}
