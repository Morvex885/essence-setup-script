//! The core thread: the only owner of the `Session` (lock manager, password
//! store). Jobs run strictly one at a time in arrival order.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use rc_core::dispatch::{self, Envelope, Session};
use rc_core::error::Result;
use rc_core::log::{self, Level, LogSink};
use rc_core::request_input::Input;
use rc_core::request_secrets::Secrets;
use rc_core::state::{State, StatePaths};
use rc_core::transport::PtyRequest;
use serde_json::{Value, json};
use tokio::runtime::Handle;
use tokio::sync::{mpsc, watch};

use super::Shared;
use super::conn::{Conn, daemon_stopping, session_closed};
use super::terminal::{self, InputReceiver, Reservation, STOP_WAIT};

/// What the rest of the daemon may know about the core without asking it
/// (`daemon status`, phase 2 admission and listener warnings).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CoreSnapshot {
    pub open: bool,
    pub authorized: bool,
    pub configured: bool,
    pub source: Option<&'static str>,
    pub password_set: bool,
}

impl CoreSnapshot {
    fn of(session: &Session) -> Self {
        Self {
            open: session.open,
            authorized: session.authorized,
            configured: session.configured().unwrap_or(false),
            source: session.source_kind().ok().flatten(),
            password_set: session.state.auth_store().is_configured().unwrap_or(false),
        }
    }
}

/// A queued request of one connection.
pub struct Request {
    pub conn: Arc<Conn>,
    pub id: Value,
    /// `noun verb` (busy marker, activity events).
    pub label: String,
    pub argv: Vec<String>,
    pub secrets: Secrets,
    pub input: Input,
    /// `env.SSH_AUTH_SOCK` of a local client.
    pub agent: Option<PathBuf>,
    /// Re-checked against `conn` authorization when the job starts.
    pub needs_auth: bool,
}

/// The console side of a terminal request.
pub struct TerminalRequest {
    pub pty: PtyRequest,
    pub reservation: Option<Reservation>,
    pub input: InputReceiver,
}

pub enum Job {
    Command(Request),
    SessionOpen(Request),
    TerminalPrep(Request, TerminalRequest),
    /// The last job: terminals, `Session::close`, the initiator's reply.
    Shutdown { initiator: Option<(Arc<Conn>, Value)> },
}

/// The request whose journal the session currently produces.
type Current = Rc<RefCell<Option<(Arc<Conn>, Value)>>>;

/// Session journal → `log` events of the current request and `activity
/// log` events of watchers.
struct CoreSink {
    current: Current,
    shared: Arc<Shared>,
}

impl LogSink for CoreSink {
    fn log(&mut self, level: Level, text: &str) {
        let text = log::sanitize(text);
        if let Some((conn, id)) = self.current.borrow().as_ref() {
            conn.log(id, level, &text);
        }
        self.shared.activity(&json!({"event": "activity", "state": "log", "level": level, "text": text}));
    }
}

pub fn spawn(
    shared: Arc<Shared>,
    paths: StatePaths,
    jobs: mpsc::UnboundedReceiver<Job>,
    snapshot: watch::Sender<CoreSnapshot>,
    handle: Handle,
) -> std::io::Result<JoinHandle<()>> {
    std::thread::Builder::new().name("core".into()).spawn(move || {
        let runtime = handle.clone();
        runtime.block_on(core_loop(shared, paths, jobs, snapshot, handle));
    })
}

async fn core_loop(
    shared: Arc<Shared>,
    paths: StatePaths,
    mut jobs: mpsc::UnboundedReceiver<Job>,
    snapshot: watch::Sender<CoreSnapshot>,
    handle: Handle,
) {
    let current = Current::default();
    let mut session = Session::new(State::new(paths), Box::new(CoreSink { current: current.clone(), shared: shared.clone() }));
    snapshot.send_replace(CoreSnapshot::of(&session));
    while let Some(job) = jobs.recv().await {
        if let Job::Shutdown { initiator } = job {
            // Closed first: a later `enqueue` fails and its caller answers
            // `daemon_stopping`; jobs already buffered are drained below.
            jobs.close();
            shutdown(&shared, &mut session, initiator).await;
            snapshot.send_replace(CoreSnapshot::of(&session));
            while let Ok(job) = jobs.try_recv() {
                refuse(&shared, job);
            }
            return;
        }
        run_job(&shared, &mut session, &current, &handle, job).await;
        snapshot.send_replace(CoreSnapshot::of(&session));
    }
}

/// Answers a job that will not run with `daemon_stopping`.
fn refuse(shared: &Shared, job: Job) {
    let (request, reservation) = match job {
        Job::Command(request) | Job::SessionOpen(request) => (request, None),
        Job::TerminalPrep(request, terminal) => (request, terminal.reservation),
        Job::Shutdown { .. } => return,
    };
    discard(shared, &request, reservation.as_ref());
    request.conn.fail(&request.id, daemon_stopping());
    shared.job_done();
}

/// Frees what a job that never started held.
fn discard(shared: &Shared, request: &Request, reservation: Option<&Reservation>) {
    if let Some(reservation) = reservation {
        shared.terminals.release(reservation);
    }
    request.conn.unlink_terminal(&request.id);
}

fn password_hash(session: &Session) -> Option<Option<String>> {
    session.state.auth_store().hash().ok()
}

async fn run_job(shared: &Arc<Shared>, session: &mut Session, current: &Current, handle: &Handle, job: Job) {
    let (request, kind) = match job {
        Job::Command(request) => (request, Kind::Command),
        Job::SessionOpen(request) => (request, Kind::SessionOpen),
        Job::TerminalPrep(request, terminal) => (request, Kind::Terminal(terminal)),
        Job::Shutdown { .. } => unreachable!("handled by core_loop"),
    };
    let conn = request.conn.clone();
    // Not yet started jobs of a closed connection are dropped unanswered.
    let refusal = if conn.is_closed() {
        Some(None)
    } else if shared.is_stopping() {
        Some(Some(daemon_stopping()))
    } else if request.needs_auth && !conn.is_authorized() {
        Some(Some(session_closed()))
    } else {
        None
    };
    if let Some(error) = refusal {
        let reservation = match &kind { Kind::Terminal(terminal) => terminal.reservation.as_ref(), _ => None };
        discard(shared, &request, reservation);
        if let Some(error) = error {
            conn.fail(&request.id, error);
        }
        shared.job_done();
        return;
    }

    shared.set_busy(Some(request.label.clone()));
    shared.activity(&json!({"event": "activity", "state": "start", "command": request.label, "origin": conn.origin}));
    *current.borrow_mut() = Some((conn.clone(), request.id.clone()));
    let before = password_hash(session);
    let agent = request.agent.as_deref();
    let reply = match kind {
        Kind::Command => {
            let mut envelope = dispatch::dispatch(&request.argv, &request.secrets, &request.input, agent, session).await;
            if request.label == "session status" && let Some(data) = envelope.data.as_mut() {
                let core = data["authorized"].as_bool().unwrap_or(false);
                data["authorized"] = Value::Bool(conn.is_authorized() && core);
            }
            Some(envelope)
        }
        Kind::SessionOpen => {
            let mut steps = SessionSteps { session: &mut *session, request: &request, agent };
            Some(open_session(&mut steps, conn.authorized_flag()).await)
        }
        Kind::Terminal(terminal) => {
            match dispatch::prepare_terminal(&request.argv, &request.secrets, &request.input, agent, session).await {
                Ok(job) => {
                    terminal::launch(shared, handle, conn.clone(), request.id.clone(), job, terminal);
                    None
                }
                Err(error) => {
                    discard(shared, &request, terminal.reservation.as_ref());
                    Some(Envelope::failure(error))
                }
            }
        }
    };
    *current.borrow_mut() = None;
    if password_hash(session) != before {
        shared.password_changed(conn.id);
    }
    let succeeded = reply.as_ref().is_some_and(|envelope| envelope.ok);
    if let Some(envelope) = reply {
        conn.reply(&request.id, envelope);
    }
    shared.activity(&json!({"event": "activity", "state": "end", "command": request.label, "origin": conn.origin}));
    shared.set_busy(None);
    shared.job_done();
    if succeeded {
        match request.label.as_str() {
            // The running binary is gone or replaced: stop after the reply;
            // a persistent daemon comes back as the new binary.
            "self update" => {
                if shared.persistent {
                    shared.restart.store(true, Ordering::SeqCst);
                }
                shared.begin_stop(None);
            }
            "self uninstall" => {
                shared.begin_stop(None);
            }
            _ => {}
        }
    }
}

enum Kind {
    Command,
    SessionOpen,
    Terminal(TerminalRequest),
}

/// Cancel terminals and wait for them (≤ 5 s), close the session, answer
/// the initiator.
async fn shutdown(shared: &Shared, session: &mut Session, initiator: Option<(Arc<Conn>, Value)>) {
    let threads = shared.terminals.cancel_all();
    let deadline = Instant::now() + STOP_WAIT;
    while threads.iter().any(|thread| !thread.is_finished()) && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    if let Err(error) = session.close() {
        eprintln!("  [!] Не удалось закрыть сессию: {}", error.message);
    }
    if let Some((conn, id)) = initiator {
        conn.reply(&id, Envelope::success(json!({"stopping": true})));
    }
}

/// The session operations `session open` needs; a fake replaces them in tests.
pub(super) trait OpenSteps {
    fn verify_script_password(&self) -> Result<()>;
    fn configured(&self) -> Result<bool>;
    fn open_absent(&mut self) -> Result<bool>;
    fn password_hash(&self) -> Result<Option<String>>;
    async fn dispatch(&mut self) -> Envelope;
}

struct SessionSteps<'a> {
    session: &'a mut Session,
    request: &'a Request,
    agent: Option<&'a Path>,
}

impl OpenSteps for SessionSteps<'_> {
    fn verify_script_password(&self) -> Result<()> {
        self.session.verify_script_password(&self.request.secrets)
    }

    fn configured(&self) -> Result<bool> {
        self.session.configured()
    }

    fn open_absent(&mut self) -> Result<bool> {
        self.session.open_absent()
    }

    fn password_hash(&self) -> Result<Option<String>> {
        self.session.state.auth_store().hash()
    }

    async fn dispatch(&mut self) -> Envelope {
        let request = self.request;
        dispatch::dispatch(&request.argv, &request.secrets, &request.input, self.agent, self.session).await
    }
}

/// `session open` of connection `C` (П4, local steps 2, 4, 5, 6; the
/// network admission steps 1, 3, 7 wrap this in phase 2).
pub(super) async fn open_session(steps: &mut impl OpenSteps, authorized: &AtomicBool) -> Envelope {
    // 2. The script password first, before anything else happens.
    if let Err(error) = steps.verify_script_password() {
        return Envelope::failure(error);
    }
    // 4. Absent configuration: an empty local session, answered not_configured.
    match steps.configured() {
        Err(error) => return Envelope::failure(error),
        Ok(false) => {
            authorized.store(true, Ordering::SeqCst);
            if let Err(error) = steps.open_absent() {
                return Envelope::failure(error);
            }
            return steps.dispatch().await;
        }
        Ok(true) => {}
    }
    // 5. Opening may bring another password (a GitHub snapshot): prove it again.
    let before = match steps.password_hash() {
        Ok(hash) => hash,
        Err(error) => return Envelope::failure(error),
    };
    let envelope = steps.dispatch().await;
    if steps.password_hash().ok() != Some(before)
        && let Err(error) = steps.verify_script_password()
    {
        authorized.store(false, Ordering::SeqCst);
        return Envelope::failure(error);
    }
    // 6. The password is proven even when the source failed to open; the
    // core still refuses session commands until it opens.
    authorized.store(true, Ordering::SeqCst);
    envelope
}

#[cfg(test)]
mod tests {
    use rc_core::error::RcError;

    use super::*;

    /// A session whose password check, configuration and hash are scripted.
    #[derive(Default)]
    struct FakeSteps {
        /// Stored password (None: not set) and the supplied secret.
        password: Option<&'static str>,
        secret: Option<&'static str>,
        configured: bool,
        /// The password the source brings with it when it opens.
        opened_password: Option<Option<&'static str>>,
        dispatch_error: Option<&'static str>,
        calls: Vec<&'static str>,
    }

    impl OpenSteps for FakeSteps {
        fn verify_script_password(&self) -> Result<()> {
            match (self.password, self.secret) {
                (None, _) => Ok(()),
                (Some(_), None) => Err(RcError::new("auth_required", "Требуется пароль запуска.")),
                (Some(stored), Some(given)) if stored == given => Ok(()),
                _ => Err(RcError::new("auth_failed", "Неверный пароль запуска.")),
            }
        }

        fn configured(&self) -> Result<bool> {
            Ok(self.configured)
        }

        fn open_absent(&mut self) -> Result<bool> {
            self.calls.push("open_absent");
            Ok(!self.configured)
        }

        fn password_hash(&self) -> Result<Option<String>> {
            Ok(self.password.map(|password| format!("hash:{password}")))
        }

        async fn dispatch(&mut self) -> Envelope {
            self.calls.push("dispatch");
            if !self.configured {
                return Envelope::failure(RcError::new("not_configured", "Конфигурация не создана."));
            }
            if let Some(password) = self.opened_password {
                self.password = password;
            }
            match self.dispatch_error {
                Some(code) => Envelope::failure(RcError::new(code, "источник")),
                None => Envelope::success(json!({"source": "local"})),
            }
        }
    }

    async fn open(steps: &mut FakeSteps, was: bool) -> (Option<&'static str>, bool) {
        let authorized = AtomicBool::new(was);
        let envelope = open_session(steps, &authorized).await;
        (envelope.error.map(|error| error.code), authorized.load(Ordering::SeqCst))
    }

    #[tokio::test(flavor = "current_thread")]
    async fn the_password_comes_before_everything() {
        let mut steps = FakeSteps { password: Some("p"), configured: true, ..FakeSteps::default() };
        assert_eq!(open(&mut steps, false).await, (Some("auth_required"), false));
        steps.secret = Some("bad");
        assert_eq!(open(&mut steps, false).await, (Some("auth_failed"), false));
        assert!(steps.calls.is_empty(), "nothing opens before the password: {:?}", steps.calls);
        steps.secret = Some("p");
        assert_eq!(open(&mut steps, false).await, (None, true));
        assert_eq!(steps.calls, ["dispatch"]);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn an_already_open_core_session_still_requires_the_password() {
        let mut steps = FakeSteps { password: Some("p"), configured: true, ..FakeSteps::default() };
        // The connection state alone decides: a second client proves itself.
        assert_eq!(open(&mut steps, false).await, (Some("auth_required"), false));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn absent_configuration_authorizes_and_answers_not_configured() {
        let mut steps = FakeSteps::default();
        assert_eq!(open(&mut steps, false).await, (Some("not_configured"), true));
        assert_eq!(steps.calls, ["open_absent", "dispatch"]);
        let mut guarded = FakeSteps { password: Some("p"), ..FakeSteps::default() };
        assert_eq!(open(&mut guarded, false).await, (Some("auth_required"), false));
        assert!(guarded.calls.is_empty());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn source_failures_after_the_password_still_authorize() {
        for code in ["vault_password_required", "vault_password_invalid", "github_format_outdated", "locked", "source_failed"] {
            let mut steps = FakeSteps { configured: true, dispatch_error: Some(code), ..FakeSteps::default() };
            assert_eq!(open(&mut steps, false).await, (Some(code), true), "{code}");
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_password_brought_by_the_source_is_proven_again() {
        // No local password, the GitHub snapshot carries one.
        let mut steps = FakeSteps { configured: true, opened_password: Some(Some("q")), ..FakeSteps::default() };
        assert_eq!(open(&mut steps, true).await, (Some("auth_required"), false), "authorization is withdrawn");
        let mut steps = FakeSteps { configured: true, opened_password: Some(Some("q")), secret: Some("q"), ..FakeSteps::default() };
        assert_eq!(open(&mut steps, false).await, (None, true));
        // The source removed the password: nothing to prove.
        let mut steps = FakeSteps { password: Some("p"), secret: Some("p"), configured: true, opened_password: Some(None), ..FakeSteps::default() };
        assert_eq!(open(&mut steps, false).await, (None, true));
    }
}
