//! `node shell --name N`: the server menu (`setup-essence.sh`) on a remote
//! pseudo-terminal bound to the requester's console (v1 `cli_cmd_node_shell`
//! and `run_remote`). `prepare` does the session part: lookup, connection,
//! current scripts and the journal; the returned job runs on the console
//! without the session and without a deadline.

use crate::cli::Invocation;
use crate::dispatch::Session;
use crate::error::Result;
use crate::log::Level;
use crate::terminal::TerminalJob;
use crate::transport::RemoteTransport;

use super::{connect, find, require_portable, required, scripts, sh_quote};

pub async fn prepare<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, mut transport: T)
    -> Result<TerminalJob<T>>
{
    let name = required(invocation, "name")?;
    let node = find(&session.state.load_config()?, name)?.clone();
    require_portable(session, &node)?;
    session.log(Level::Info, &format!("Подключаемся к {} ({}@{}:{})...", node.name, node.user, node.ip, node.port));
    connect(&mut transport, &session.state, &node).await?;
    session.log(Level::Success, "Соединение установлено");
    if scripts::ensure_current(&transport, &node.name, false).await?.uploaded {
        session.log(Level::Success, "Скрипты загружены");
    }
    session.log(Level::Info, &format!("Открываю интерактивную SSH-сессию на {} ({})...", node.name, node.ip));
    session.log(Level::Output, "  (введите 0 в меню сервера для выхода)");
    let command = format!("bash {}", sh_quote(&format!("{}/setup-essence.sh", scripts::REMOTE_DIR)));
    let failure = format!("SSH-сессия с нодой «{}» завершилась с ошибкой.", node.name);
    Ok(TerminalJob::new(node.name, command, failure, "SSH-сессия завершена.", transport))
}

#[cfg(test)]
mod tests {
    use std::{cell::RefCell, io, rc::Rc, task::{Context, Poll}};

    use serde_json::{Value, json};

    use super::*;
    use crate::error::RcError;
    use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeScript, FakeTransport, Operation, ScriptStep};
    use crate::model::{Auth, Config, Fingerprint, Node};
    use crate::nodes::testing::{fingerprint, invocation, session};
    use crate::nodes::{COMMAND_TIMEOUT, CONNECT_TIMEOUT, LONG_TIMEOUT, pin};
    use crate::transport::{ConsoleEvent, ConsoleSize, ExecResult, HostKeyPolicy, PtyRequest, RawConsole, remote_failure};

    const SIZE: ConsoleSize = ConsoleSize { cols: 132, rows: 43 };

    /// A raw console that records the remote output.
    #[derive(Default)]
    struct TestConsole {
        output: Rc<RefCell<Vec<u8>>>,
    }

    impl RawConsole for TestConsole {
        /// The fake transport never reads input; the wire test covers it.
        fn poll_event(&mut self, _: &mut Context<'_>) -> Poll<ConsoleEvent> {
            Poll::Pending
        }
        fn output(&mut self, data: &[u8]) -> io::Result<()> {
            self.output.borrow_mut().extend_from_slice(data);
            Ok(())
        }
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

    /// A stored node with a pinned host key.
    fn fixture(root: &std::path::Path) -> (Session, crate::nodes::testing::Journal) {
        let (session, journal) = session(root);
        session.state.save_config(&Config { nodes: vec![node()], ..Config::default() }).unwrap();
        pin(&session.state, "203.0.113.7", 2222, vec![pin_fp()]).unwrap();
        (session, journal)
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

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread().build().unwrap()
    }

    /// `prepare` then `run` on the test console, as the daemon does; the
    /// script observer outlives the transport moved into the job.
    fn shell(session: &mut Session, name: &str, steps: Vec<ScriptStep>, console: &mut TestConsole)
        -> (Result<Value>, FakeScript)
    {
        let transport = FakeTransport::new(steps);
        let script = transport.script();
        let argv = invocation(&["node", "shell", "--name", name]);
        let runtime = runtime();
        let result = runtime.block_on(async {
            let job = prepare(session, &argv, transport).await?;
            assert_eq!((job.node.as_str(), job.done_log), (name, "SSH-сессия завершена."));
            job.run(pty(), console).await
        });
        (result, script)
    }

    #[test]
    fn unknown_node_is_not_found_before_any_remote_effect() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = fixture(root.path());
        let (result, script) = shell(&mut session, "beta", Vec::new(), &mut TestConsole::default());
        assert_eq!(result.unwrap_err().code, "not_found");
        assert!(script.journal().is_empty());
        assert!(journal.borrow().is_empty());
    }

    #[test]
    fn interactive_session_requests_a_pty_for_the_server_menu() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = fixture(root.path());
        let mut steps = vec![connect_step()];
        steps.extend(uploaded());
        steps.push(ScriptStep::interactive(COMMAND, pty(), b"\x1b[1mMENU\x1b[0m\r\n".to_vec(), Ok(0)));
        let before = fingerprint(root.path());
        let mut console = TestConsole::default();
        let (result, script) = shell(&mut session, "alpha", steps, &mut console);
        assert_eq!(result.unwrap(), json!({}));
        script.assert_finished();
        assert_eq!(script.journal().last(), Some(&Operation::Interactive { command: COMMAND.into(), pty: pty() }));
        assert_eq!(console.output.borrow().as_slice(), b"\x1b[1mMENU\x1b[0m\r\n");
        let lines: Vec<(Level, String)> = journal.borrow().clone();
        assert_eq!(lines, [
            (Level::Info, "Подключаемся к alpha (root@203.0.113.7:2222)...".to_owned()),
            (Level::Success, "Соединение установлено".to_owned()),
            (Level::Success, "Скрипты загружены".to_owned()),
            (Level::Info, "Открываю интерактивную SSH-сессию на alpha (203.0.113.7)...".to_owned()),
            (Level::Output, "  (введите 0 в меню сервера для выхода)".to_owned()),
        ], "the job owner journals the done line");
        assert_eq!(fingerprint(root.path()), before, "a shell session changes no local state");
    }

    #[test]
    fn nonzero_exit_or_broken_session_is_remote_failed() {
        for (status, reason) in [(Ok(3), None), (Err(remote_failure("exit_signal")), Some("exit_signal"))] {
            let root = tempfile::tempdir().unwrap();
            let (mut session, _journal) = fixture(root.path());
            let mut steps = vec![connect_step()];
            steps.extend(current());
            steps.push(ScriptStep::interactive(COMMAND, pty(), Vec::new(), status));
            let (result, script) = shell(&mut session, "alpha", steps, &mut TestConsole::default());
            script.assert_finished();
            let error = result.unwrap_err();
            assert_eq!(error.code, "remote_failed");
            assert_eq!(error.message, "SSH-сессия с нодой «alpha» завершилась с ошибкой.");
            assert_eq!(error.extra["name"], "alpha");
            match reason {
                None => assert_eq!(error.extra["exit_status"], 3),
                Some(reason) => assert_eq!(error.extra["reason"], reason),
            }
        }
    }

    #[test]
    fn changed_host_key_stops_before_the_menu() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = fixture(root.path());
        let changed = RcError::new("host_key_changed", "Ключ SSH-сервера не подтверждён.")
            .with_extra("host", "203.0.113.7").with_extra("port", 2222)
            .with_extra("fingerprints", json!([format!("SHA256:{}", "B".repeat(43))]));
        let steps = vec![ScriptStep::connect(
            ConnectExpectation::new("203.0.113.7", 2222, "root", AuthMethod::System, CONNECT_TIMEOUT)
                .with_host_key(HostKeyPolicy { expected: None, known: vec![pin_fp()] }),
            Err(changed),
        )];
        let before = fingerprint(root.path());
        let mut console = TestConsole::default();
        let (result, script) = shell(&mut session, "alpha", steps, &mut console);
        script.assert_finished();
        let error = result.unwrap_err();
        assert_eq!(error.code, "host_key_changed");
        assert_eq!(error.message, "Ключ сервера ноды «alpha» изменился.");
        assert!(console.output.borrow().is_empty());
        assert_eq!(fingerprint(root.path()), before);
    }
}
