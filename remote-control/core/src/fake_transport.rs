//! Deterministic, in-memory remote effects for command and recovery tests.
//!
//! Each effect consumes exactly one matching front-of-queue step when its future
//! is first polled. A mutex makes matching, consumption, and journaling atomic;
//! there are no internal suspension points. Concurrent callers therefore follow
//! first-poll/lock-acquisition order, not future-creation order. Tests requiring a
//! particular order must poll/await effects in that order. Unexpected calls are
//! journaled, leave the expected step pending, and make `assert_finished` fail.
//! Scripted failures consume their step, allowing recovery to follow explicitly.
//!
//! `hold` is a local lease operation, journaled but not scripted. Its lease shares
//! the script and journal and stays authenticated after its primary is dropped or
//! reconnects unsuccessfully. No network, filesystem, subprocess, or state-store
//! effects occur. Authentication values and stdin bytes are never retained.
//! An interactive step journals its command and pty parameters, writes its
//! scripted output to the raw console and never reads console input.

use std::{
    collections::VecDeque,
    fmt,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard},
    time::Duration,
};

use crate::{
    error::Result,
    model::Fingerprint,
    transport::{Authentication, ConnectOptions, ExecResult, HostKeyPolicy, PtyRequest, RawConsole, RemoteSession,
        RemoteTransport, remote_failure},
};

/// Only the authentication method is observable, never credentials.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthMethod {
    Password,
    Key,
    System,
}

/// The non-secret connection arguments that a script expects and journals.
/// Identity contents, password/passphrase values, and their lengths are omitted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConnectExpectation {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub auth: AuthMethod,
    pub expected_fingerprint: Option<Fingerprint>,
    pub known_fingerprints: Vec<Fingerprint>,
    pub timeout: Duration,
}

impl ConnectExpectation {
    pub fn new(host: impl Into<String>, port: u16, user: impl Into<String>, auth: AuthMethod, timeout: Duration) -> Self {
        Self {
            host: host.into(), port, user: user.into(), auth,
            expected_fingerprint: None, known_fingerprints: Vec::new(), timeout,
        }
    }

    pub fn with_host_key(mut self, policy: HostKeyPolicy) -> Self {
        self.expected_fingerprint = policy.expected;
        self.known_fingerprints = policy.known;
        self
    }

    fn from_options(options: &ConnectOptions) -> Self {
        let auth = match &options.auth {
            Authentication::Password(_) => AuthMethod::Password,
            Authentication::Key { .. } => AuthMethod::Key,
            Authentication::System => AuthMethod::System,
        };
        Self {
            host: options.host.clone(), port: options.port, user: options.user.clone(), auth,
            expected_fingerprint: options.host_key.expected.clone(),
            known_fingerprints: options.host_key.known.clone(), timeout: options.timeout,
        }
    }
}

/// Ordered, credential-free record of attempted operations, including failures.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Operation {
    Connect(ConnectExpectation),
    Exec { command: String, stdin_len: usize, timeout: Duration },
    /// `private`: `upload_private` (owner-only modes on the node).
    Upload { local_dir: PathBuf, remote_dir: String, timeout: Duration, private: bool },
    Interactive { command: String, pty: PtyRequest },
    Hold,
}

impl Operation {
    fn kind(&self) -> &'static str {
        match self {
            Self::Connect(_) => "connect",
            Self::Exec { .. } => "exec",
            Self::Upload { .. } => "upload",
            Self::Interactive { .. } => "interactive",
            Self::Hold => "hold",
        }
    }
}

enum Outcome {
    Unit(Result<()>),
    Exec(Result<ExecResult>),
    Interactive { output: Vec<u8>, status: Result<u32> },
}

/// One expected effect and its explicit response. No implicit successes exist.
/// Debug intentionally omits response bytes and caller-supplied error contents.
pub struct ScriptStep {
    expected: Operation,
    outcome: Outcome,
    any_local_dir: bool,
}

impl ScriptStep {
    pub fn connect(expected: ConnectExpectation, outcome: Result<()>) -> Self {
        Self { expected: Operation::Connect(expected), outcome: Outcome::Unit(outcome), any_local_dir: false }
    }

    /// Matches stdin by byte count, without retaining its contents.
    pub fn exec(command: impl Into<String>, stdin_len: usize, timeout: Duration, outcome: Result<ExecResult>) -> Self {
        Self { expected: Operation::Exec { command: command.into(), stdin_len, timeout }, outcome: Outcome::Exec(outcome), any_local_dir: false }
    }

    pub fn upload(local_dir: impl Into<PathBuf>, remote_dir: impl Into<String>, timeout: Duration, outcome: Result<()>) -> Self {
        Self {
            expected: Operation::Upload { local_dir: local_dir.into(), remote_dir: remote_dir.into(), timeout, private: false },
            outcome: Outcome::Unit(outcome), any_local_dir: false,
        }
    }

    /// A pty-backed command: `output` reaches the console, then `status`.
    pub fn interactive(command: impl Into<String>, pty: PtyRequest, output: impl Into<Vec<u8>>, status: Result<u32>) -> Self {
        Self {
            expected: Operation::Interactive { command: command.into(), pty },
            outcome: Outcome::Interactive { output: output.into(), status }, any_local_dir: false,
        }
    }

    /// Explicitly permits a dynamically staged temporary local directory.
    /// Remote path and timeout still match exactly; the actual local path is
    /// journaled. Prefer `upload` whenever the expected local path is available.
    pub fn upload_any_local(remote_dir: impl Into<String>, timeout: Duration, outcome: Result<()>) -> Self {
        Self {
            expected: Operation::Upload { local_dir: PathBuf::new(), remote_dir: remote_dir.into(), timeout, private: false },
            outcome: Outcome::Unit(outcome), any_local_dir: true,
        }
    }

    /// `upload_any_local` through `upload_private`.
    pub fn upload_private_any_local(remote_dir: impl Into<String>, timeout: Duration, outcome: Result<()>) -> Self {
        Self {
            expected: Operation::Upload { local_dir: PathBuf::new(), remote_dir: remote_dir.into(), timeout, private: true },
            outcome: Outcome::Unit(outcome), any_local_dir: true,
        }
    }

    fn matches(&self, operation: &Operation) -> bool {
        if self.any_local_dir {
            match (&self.expected, operation) {
                (Operation::Upload { remote_dir: expected_remote, timeout: expected_timeout, private: expected_private, .. },
                 Operation::Upload { remote_dir, timeout, private, .. }) =>
                    expected_remote == remote_dir && expected_timeout == timeout && expected_private == private,
                _ => false,
            }
        } else {
            self.expected == *operation
        }
    }
}

impl fmt::Debug for ScriptStep {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ScriptStep").field("expected", &self.expected)
            .field("any_local_dir", &self.any_local_dir).finish_non_exhaustive()
    }
}

#[derive(Default)]
struct ScriptState {
    pending: VecDeque<ScriptStep>,
    journal: Vec<Operation>,
    unexpected: usize,
}

impl ScriptState {
    fn perform(&mut self, operation: Operation, connected: bool) -> Result<Outcome> {
        let actual_kind = operation.kind();
        let expected_kind = self.pending.front().map(|step| step.expected.kind());
        let matches = self.pending.front().is_some_and(|step| step.matches(&operation));
        self.journal.push(operation);
        let reason = if !connected {
            Some("fake_not_connected")
        } else if expected_kind.is_none() {
            Some("fake_script_exhausted")
        } else if !matches {
            Some("fake_script_mismatch")
        } else {
            None
        };
        if let Some(reason) = reason {
            self.unexpected += 1;
            return Err(remote_failure(reason)
                .with_extra("operation", actual_kind)
                .with_extra("expected_operation", expected_kind.unwrap_or("none"))
                .with_extra("journal_index", self.journal.len() - 1));
        }
        // A matching front step was established under this same lock.
        Ok(self.pending.pop_front().expect("matched script step").outcome)
    }

    fn hold(&mut self, connected: bool) -> Result<()> {
        self.journal.push(Operation::Hold);
        if !connected {
            self.unexpected += 1;
            return Err(remote_failure("fake_not_connected"));
        }
        Ok(())
    }
}

/// Cloneable observer of shared script state, also useful after dropping a lease.
#[derive(Clone, Default)]
pub struct FakeScript {
    state: Arc<Mutex<ScriptState>>,
}

impl FakeScript {
    fn lock(&self) -> MutexGuard<'_, ScriptState> {
        // No user code runs under this lock; preserving evidence after a test
        // panic is more useful than replacing it with a poisoning panic.
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn journal(&self) -> Vec<Operation> {
        self.lock().journal.clone()
    }

    pub fn remaining_steps(&self) -> usize {
        self.lock().pending.len()
    }

    /// Asserts both complete consumption and the absence of unexpected calls.
    /// Expected, explicitly scripted remote errors do not count as mismatches.
    pub fn assert_finished(&self) {
        let state = self.lock();
        assert_eq!(state.unexpected, 0, "unexpected fake remote effects");
        assert_eq!(state.pending.len(), 0, "unconsumed fake remote effects");
    }

    fn exec(&self, connected: bool, command: &str, stdin: &[u8], timeout: Duration) -> Result<ExecResult> {
        let operation = Operation::Exec { command: command.into(), stdin_len: stdin.len(), timeout };
        match self.lock().perform(operation, connected)? {
            Outcome::Exec(result) => result,
            _ => Err(remote_failure("fake_script_response_type")),
        }
    }

    fn upload(&self, connected: bool, local_dir: &Path, remote_dir: &str, timeout: Duration, private: bool) -> Result<()> {
        let operation = Operation::Upload { local_dir: local_dir.into(), remote_dir: remote_dir.into(), timeout, private };
        match self.lock().perform(operation, connected)? {
            Outcome::Unit(result) => result,
            _ => Err(remote_failure("fake_script_response_type")),
        }
    }

    fn interactive(&self, connected: bool, command: &str, pty: PtyRequest, console: &mut dyn RawConsole) -> Result<u32> {
        let operation = Operation::Interactive { command: command.into(), pty };
        // The script lock is released before console output is written.
        let outcome = self.lock().perform(operation, connected)?;
        match outcome {
            Outcome::Interactive { output, status } => {
                console.output(&output).map_err(|_| remote_failure("console"))?;
                status
            }
            _ => Err(remote_failure("fake_script_response_type")),
        }
    }
}

impl fmt::Debug for FakeScript {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let state = self.lock();
        f.debug_struct("FakeScript")
            .field("remaining_steps", &state.pending.len())
            .field("unexpected_calls", &state.unexpected)
            .field("journal", &state.journal)
            .finish()
    }
}

/// A strict scripted transport. The default has an empty script, not success.
#[derive(Debug, Default)]
pub struct FakeTransport {
    script: FakeScript,
    connected: bool,
}

impl FakeTransport {
    pub fn new(steps: impl IntoIterator<Item = ScriptStep>) -> Self {
        Self {
            script: FakeScript { state: Arc::new(Mutex::new(ScriptState {
                pending: steps.into_iter().collect(), ..ScriptState::default()
            })) },
            connected: false,
        }
    }

    pub fn script(&self) -> FakeScript { self.script.clone() }
    pub fn journal(&self) -> Vec<Operation> { self.script.journal() }
    pub fn remaining_steps(&self) -> usize { self.script.remaining_steps() }
    pub fn assert_finished(&self) { self.script.assert_finished(); }
}

/// An independently authenticated lease, sharing its primary's script/journal.
#[derive(Debug)]
pub struct FakeHeldSession {
    script: FakeScript,
}

impl FakeHeldSession {
    pub fn script(&self) -> FakeScript { self.script.clone() }
    pub fn journal(&self) -> Vec<Operation> { self.script.journal() }
    pub fn assert_finished(&self) { self.script.assert_finished(); }
}

impl RemoteTransport for FakeTransport {
    type Held = FakeHeldSession;

    async fn connect(&mut self, options: ConnectOptions) -> Result<()> {
        self.connected = false;
        let operation = Operation::Connect(ConnectExpectation::from_options(&options));
        match self.script.lock().perform(operation, true)? {
            Outcome::Unit(result) => result?,
            _ => return Err(remote_failure("fake_script_response_type")),
        }
        self.connected = true;
        Ok(())
    }

    fn hold(&self) -> Result<Self::Held> {
        self.script.lock().hold(self.connected)?;
        Ok(FakeHeldSession { script: self.script.clone() })
    }

    async fn interactive(&self, command: &str, pty: PtyRequest, console: &mut dyn RawConsole) -> Result<u32> {
        self.script.interactive(self.connected, command, pty, console)
    }
}

impl RemoteSession for FakeTransport {
    async fn exec(&self, command: &str, stdin: &[u8], timeout: Duration) -> Result<ExecResult> {
        self.script.exec(self.connected, command, stdin, timeout)
    }

    async fn upload(&self, local_dir: &Path, remote_dir: &str, timeout: Duration) -> Result<()> {
        self.script.upload(self.connected, local_dir, remote_dir, timeout, false)
    }

    async fn upload_private(&self, local_dir: &Path, remote_dir: &str, timeout: Duration) -> Result<()> {
        self.script.upload(self.connected, local_dir, remote_dir, timeout, true)
    }
}

impl RemoteSession for FakeHeldSession {
    async fn exec(&self, command: &str, stdin: &[u8], timeout: Duration) -> Result<ExecResult> {
        self.script.exec(true, command, stdin, timeout)
    }

    async fn upload(&self, local_dir: &Path, remote_dir: &str, timeout: Duration) -> Result<()> {
        self.script.upload(true, local_dir, remote_dir, timeout, false)
    }

    async fn upload_private(&self, local_dir: &Path, remote_dir: &str, timeout: Duration) -> Result<()> {
        self.script.upload(true, local_dir, remote_dir, timeout, true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::RcError;
    use zeroize::Zeroizing;

    const TIMEOUT: Duration = Duration::from_secs(30);
    const SECRET: &str = "FAKE-TRANSPORT-SECRET-SENTINEL";

    fn expected(auth: AuthMethod) -> ConnectExpectation {
        ConnectExpectation::new("example.test", 2222, "root", auth, TIMEOUT)
    }

    fn options(auth: Authentication) -> ConnectOptions {
        ConnectOptions {
            host: "example.test".into(), port: 2222, user: "root".into(), auth,
            host_key: HostKeyPolicy::default(), timeout: TIMEOUT,
        }
    }


    #[tokio::test]
    async fn mismatches_and_missing_responses_never_succeed_or_consume_expected_step() {
        let mut fake = FakeTransport::new([
            ScriptStep::connect(expected(AuthMethod::System), Ok(())),
            ScriptStep::exec("next", 2, TIMEOUT, Ok(ExecResult::default())),
        ]);
        fake.connect(options(Authentication::System)).await.unwrap();
        for (command, input, timeout) in [
            ("wrong", &b"xx"[..], TIMEOUT),
            ("next", &b"x"[..], TIMEOUT),
            ("next", &b"xx"[..], Duration::from_secs(1)),
        ] {
            assert_eq!(fake.exec(command, input, timeout).await.unwrap_err().extra["reason"], "fake_script_mismatch");
            assert_eq!(fake.remaining_steps(), 1);
        }
        assert_eq!(fake.upload(Path::new("local"), "remote", TIMEOUT).await.unwrap_err().extra["reason"], "fake_script_mismatch");
        fake.exec("next", b"xx", TIMEOUT).await.unwrap();
        assert_eq!(fake.exec("extra", b"", TIMEOUT).await.unwrap_err().extra["reason"], "fake_script_exhausted");
        assert!(std::panic::catch_unwind(|| fake.assert_finished()).is_err());
    }

    #[tokio::test]
    async fn connection_failure_does_not_authenticate_or_allow_hold() {
        let mut fake = FakeTransport::new([
            ScriptStep::connect(expected(AuthMethod::Password), Err(RcError::new("auth_failed", "rejected"))),
            ScriptStep::exec("forbidden", 0, TIMEOUT, Ok(ExecResult::default())),
        ]);
        assert!(fake.connect(options(Authentication::Password(Zeroizing::new(SECRET.into())))).await.is_err());
        assert!(fake.hold().is_err());
        assert_eq!(fake.exec("forbidden", b"", TIMEOUT).await.unwrap_err().extra["reason"], "fake_not_connected");
        assert_eq!(fake.remaining_steps(), 1);
        assert!(!format!("{fake:?}").contains(SECRET));
        assert!(FakeTransport::default().connect(options(Authentication::System)).await.is_err());
    }


    #[tokio::test]
    async fn credentials_and_stdin_never_enter_journal_debug_or_generated_errors() {
        for (method, auth) in [
            (AuthMethod::Password, Authentication::Password(Zeroizing::new(SECRET.into()))),
            (AuthMethod::Key, Authentication::Key { identity: "identity".into(), passphrase: Some(Zeroizing::new(SECRET.into())) }),
        ] {
            let step = ScriptStep::exec("receive", SECRET.len(), TIMEOUT, Ok(ExecResult::default()));
            assert!(!format!("{step:?}").contains(SECRET));
            let mut fake = FakeTransport::new([
                ScriptStep::connect(expected(method), Ok(())), step,
            ]);
            fake.connect(options(auth)).await.unwrap();
            let error = fake.exec("wrong", SECRET.as_bytes(), TIMEOUT).await.unwrap_err();
            assert!(!format!("{error:?} {error}").contains(SECRET));
            fake.exec("receive", SECRET.as_bytes(), TIMEOUT).await.unwrap();
            assert!(!format!("{fake:?} {:?} {:?}", fake.journal(), fake.script()).contains(SECRET));
        }
    }

}
