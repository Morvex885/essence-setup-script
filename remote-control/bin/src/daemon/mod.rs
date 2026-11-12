//! `essence-rc daemon run`: the one long-lived owner of the core.
//!
//! The core thread owns the `Session` (and with it the lock manager and the
//! password store) and executes queued jobs strictly one at a time. Runtime
//! tasks accept local connections, serve one connection each, watch for
//! idleness and signals. Terminal jobs run on their own threads after the
//! core thread prepared them. Every client — TUI, CLI, browser — speaks the
//! same protocol v3 of JSON lines.

mod commands;
mod conn;
mod core;
mod local;
mod terminal;

use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use essence_rc_client::{Endpoint, Origin, endpoint_for, prepare_runtime_dir};
use rc_core::state::StatePaths;
use serde_json::Value;
use tokio::sync::{mpsc, watch};

use self::conn::{Conn, Out};
use self::core::{CoreSnapshot, Job};
use self::terminal::Registry;

/// How the daemon was started.
pub struct Options {
    /// `--web` (phase 2): never exits when idle.
    pub persistent: bool,
}

/// Idle time before an on-demand daemon exits (seconds, 1–6 digits).
const LINGER_ENV: &str = "ESSENCE_RC_DAEMON_LINGER";
const DEFAULT_LINGER: Duration = Duration::from_secs(5);
/// An on-demand daemon nobody connected to exits after this long.
const FIRST_CLIENT_WAIT: Duration = Duration::from_secs(10);
/// Idle checks of the accept loop.
const IDLE_TICK: Duration = Duration::from_millis(100);
/// Pending replies get this long to reach their clients before exit.
const FLUSH_WAIT: Duration = Duration::from_secs(2);

/// State shared by the runtime tasks, the core thread and terminal threads.
pub(crate) struct Shared {
    pub persistent: bool,
    /// Canonical path of the daemon executable (`hello`, `daemon status`, restart).
    pub exe: PathBuf,
    pub started: Instant,
    pub terminals: Registry,
    /// Published by the core thread after start and after every job.
    pub snapshot: watch::Receiver<CoreSnapshot>,
    conns: Mutex<BTreeMap<u64, Arc<Conn>>>,
    next_conn: AtomicU64,
    ever_connected: AtomicBool,
    jobs: mpsc::UnboundedSender<Job>,
    /// Queued and executing jobs.
    pending: AtomicUsize,
    /// `noun verb` of the executing job.
    busy: Mutex<Option<String>>,
    stopping: AtomicBool,
    stop: watch::Sender<bool>,
    /// A successful `self update` in persistent mode: exec the new binary.
    restart: AtomicBool,
}

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Shared {
    fn new(persistent: bool, exe: PathBuf, jobs: mpsc::UnboundedSender<Job>, snapshot: watch::Receiver<CoreSnapshot>) -> Self {
        Self {
            persistent,
            exe,
            started: Instant::now(),
            terminals: Registry::default(),
            snapshot,
            conns: Mutex::default(),
            next_conn: AtomicU64::new(1),
            ever_connected: AtomicBool::new(false),
            jobs,
            pending: AtomicUsize::new(0),
            busy: Mutex::new(None),
            stopping: AtomicBool::new(false),
            stop: watch::channel(false).0,
            restart: AtomicBool::new(false),
        }
    }

    /// A new connection with its outgoing channel.
    pub fn register(&self, origin: Origin, out: mpsc::UnboundedSender<Out>) -> Arc<Conn> {
        let conn = Arc::new(Conn::new(self.next_conn.fetch_add(1, Ordering::Relaxed), origin, out));
        lock(&self.conns).insert(conn.id, conn.clone());
        self.ever_connected.store(true, Ordering::SeqCst);
        conn
    }

    /// The connection ended: its terminals are cancelled (reservations
    /// dropped), not yet started jobs of it are discarded by the core thread.
    pub fn disconnect(&self, conn: &Conn) {
        conn.mark_closed();
        self.terminals.drop_conn(conn.id);
        lock(&self.conns).remove(&conn.id);
    }

    pub fn connections(&self) -> Vec<Arc<Conn>> {
        lock(&self.conns).values().cloned().collect()
    }

    /// `false` when the core thread is gone: the requester is answered
    /// `daemon_stopping` instead of losing its request.
    pub fn enqueue(&self, job: Job) -> bool {
        self.pending.fetch_add(1, Ordering::SeqCst);
        if self.jobs.send(job).is_ok() {
            return true;
        }
        self.pending.fetch_sub(1, Ordering::SeqCst);
        false
    }

    pub fn job_done(&self) {
        self.pending.fetch_sub(1, Ordering::SeqCst);
    }

    pub fn busy(&self) -> Option<String> {
        lock(&self.busy).clone()
    }

    pub fn set_busy(&self, label: Option<String>) {
        *lock(&self.busy) = label;
    }

    pub fn is_stopping(&self) -> bool {
        self.stopping.load(Ordering::SeqCst)
    }

    /// Start the graceful stop once: stop accepting, answer every queued job
    /// `daemon_stopping`, then `Job::Shutdown` (terminals, `Session::close`,
    /// the initiator's reply). `false` when a stop is already under way.
    pub fn begin_stop(&self, initiator: Option<(Arc<Conn>, Value)>) -> bool {
        if self.stopping.swap(true, Ordering::SeqCst) {
            return false;
        }
        self.stop.send_replace(true);
        let _ = self.jobs.send(Job::Shutdown { initiator });
        true
    }

    /// No connections, no queued or executing jobs, no terminals.
    fn is_idle(&self) -> bool {
        lock(&self.conns).is_empty() && self.pending.load(Ordering::SeqCst) == 0 && self.terminals.is_empty()
    }

    /// `activity` events go to watchers: local ones, network ones only when authorized.
    pub fn activity(&self, event: &Value) {
        for conn in self.connections() {
            if conn.watching() && (conn.origin == Origin::Local || conn.is_authorized()) {
                conn.send(event);
            }
        }
    }

    /// The script password hash changed during a job of `requester`: every
    /// other connection loses its authorization and its terminals.
    pub fn password_changed(&self, requester: u64) {
        let reset: Vec<u64> = self.connections().into_iter()
            .filter(|conn| conn.id != requester)
            .map(|conn| {
                conn.set_authorized(false);
                conn.id
            })
            .collect();
        self.terminals.cancel_conns(&reset);
    }
}

fn fail(message: impl std::fmt::Display) -> ExitCode {
    let _ = writeln!(io::stderr().lock(), "  [✗] {message}");
    ExitCode::FAILURE
}

/// Panic: one fixed line on stderr (the journal), never the payload, exit 1.
/// Clients see the connection break and answer for the request themselves.
fn install_panic_hook() {
    std::panic::set_hook(Box::new(|_| {
        let _ = writeln!(io::stderr().lock(), "Ядро завершилось аварийно.");
        std::process::exit(1);
    }));
}

/// `ESSENCE_RC_DAEMON_LINGER`: unset → 5 s; otherwise 1–6 decimal digits.
fn parse_linger(value: Option<&OsStr>) -> Result<Duration, String> {
    let Some(value) = value else { return Ok(DEFAULT_LINGER) };
    let text = value.to_str().unwrap_or("");
    if text.is_empty() || text.len() > 6 || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(format!("{LINGER_ENV} должна содержать от 1 до 6 цифр."));
    }
    text.parse().map(Duration::from_secs).map_err(|_| format!("{LINGER_ENV} должна содержать от 1 до 6 цифр."))
}

/// The data directory as an absolute path (the daemon changes its working
/// directory) and its endpoint, with the runtime directory prepared.
fn locate() -> Result<(StatePaths, Endpoint), String> {
    let root = StatePaths::discover().map_err(|error| error.message)?.root().to_path_buf();
    let root = std::path::absolute(&root).map_err(|error| format!("Каталог данных недоступен: {error}"))?;
    let endpoint = endpoint_for(&root).map_err(|error| error.to_string())?;
    prepare_runtime_dir(&endpoint).map_err(|error| error.to_string())?;
    Ok((StatePaths::new(&endpoint.data_dir), endpoint))
}

pub fn run(options: Options) -> ExitCode {
    install_panic_hook();
    // Read before anything else runs: the inherited lock of a restart.
    #[cfg(unix)]
    let inherited_lock = local::take_inherited_lock();
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let linger = match parse_linger(std::env::var_os(LINGER_ENV).as_deref()) {
        Ok(linger) => linger,
        Err(message) => return fail(message),
    };
    let (paths, endpoint) = match locate() {
        Ok(found) => found,
        Err(message) => return fail(message),
    };
    let exe = match std::env::current_exe().and_then(std::fs::canonicalize) {
        Ok(exe) => exe,
        Err(error) => return fail(format!("Не удалось определить исполняемый файл: {error}")),
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => return fail(format!("Не удалось запустить среду выполнения: {error}")),
    };

    // Single instance, then the endpoint: only the lock owner touches it.
    #[cfg(unix)]
    let instance_lock = match runtime.block_on(local::acquire_lock(&endpoint, inherited_lock)) {
        Ok(local::Acquired::Held(file)) => file,
        Ok(local::Acquired::Running) => {
            let _ = writeln!(io::stderr().lock(), "Демон уже запущен.");
            return ExitCode::SUCCESS;
        }
        Err(error) => return fail(error),
    };
    let listener = match runtime.block_on(local::Listener::bind(&endpoint)) {
        Ok(local::Bound::Listener(listener)) => listener,
        Ok(local::Bound::Running) => {
            let _ = writeln!(io::stderr().lock(), "Демон уже запущен.");
            return ExitCode::SUCCESS;
        }
        Err(error) => return fail(error),
    };
    if let Err(error) = local::redirect_stderr(&endpoint) {
        return fail(format!("Не удалось открыть журнал демона: {error}"));
    }
    if let Err(error) = std::env::set_current_dir(&endpoint.runtime_dir) {
        return fail(format!("Не удалось перейти в каталог времени выполнения: {error}"));
    }

    let (jobs, job_receiver) = mpsc::unbounded_channel();
    let (snapshot_sender, snapshot) = watch::channel(CoreSnapshot::default());
    let shared = Arc::new(Shared::new(options.persistent, exe, jobs, snapshot));
    let core_thread = match core::spawn(shared.clone(), paths, job_receiver, snapshot_sender, runtime.handle().clone()) {
        Ok(thread) => thread,
        Err(error) => return fail(format!("Не удалось запустить поток ядра: {error}")),
    };
    {
        let _context = runtime.enter();
        local::watch_signals(&shared);
    }
    let policy = local::IdlePolicy { persistent: options.persistent, linger, first_client: FIRST_CLIENT_WAIT, tick: IDLE_TICK };
    // Returns once a stop began; on Windows the result keeps one pipe
    // instance (not accepting) until the session is closed.
    let kept = runtime.block_on(local::accept_loop(shared.clone(), listener, policy));

    // The core thread answers the queue, cancels terminals, closes the session.
    if core_thread.join().is_err() {
        std::process::exit(1);
    }
    for conn in shared.connections() {
        conn.close_output();
    }
    runtime.block_on(async {
        let deadline = Instant::now() + FLUSH_WAIT;
        while !shared.connections().is_empty() && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    });

    #[cfg(unix)]
    {
        let local::Kept = kept;
        // The socket goes before the lock: a client never sees a free lock
        // next to a stale socket of this daemon.
        let _ = std::fs::remove_file(&endpoint.socket);
        if shared.restart.load(Ordering::SeqCst) {
            let error = local::exec_restart(&shared.exe, &args, &endpoint.data_dir, &instance_lock);
            let _ = writeln!(io::stderr().lock(), "  [✗] Не удалось перезапустить демон: {error}");
            std::process::exit(1);
        }
        drop(instance_lock);
    }
    #[cfg(windows)]
    {
        drop(kept);
        // Every server handle of this process closes before a successor starts.
        runtime.shutdown_timeout(Duration::from_secs(1));
        if shared.restart.load(Ordering::SeqCst) {
            if let Err(error) = local::spawn_restart(&shared.exe, &args, &endpoint.data_dir) {
                let _ = writeln!(io::stderr().lock(), "  [✗] Не удалось перезапустить демон: {error}");
                std::process::exit(1);
            }
        }
    }
    std::process::exit(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linger_defaults_to_five_seconds_and_takes_one_to_six_digits() {
        assert_eq!(parse_linger(None), Ok(Duration::from_secs(5)));
        assert_eq!(parse_linger(Some(OsStr::new("0"))), Ok(Duration::ZERO));
        assert_eq!(parse_linger(Some(OsStr::new("30"))), Ok(Duration::from_secs(30)));
        assert_eq!(parse_linger(Some(OsStr::new("999999"))), Ok(Duration::from_secs(999_999)));
        for bad in ["", "1234567", "-1", "1.5", " 5", "5s", "٣"] {
            assert!(parse_linger(Some(OsStr::new(bad))).is_err(), "{bad:?}");
        }
    }

    fn shared() -> (Arc<Shared>, mpsc::UnboundedReceiver<Job>) {
        let (jobs, receiver) = mpsc::unbounded_channel();
        let snapshot = watch::channel(CoreSnapshot::default()).1;
        (Arc::new(Shared::new(false, PathBuf::from("/bin/essence-rc"), jobs, snapshot)), receiver)
    }

    #[test]
    fn stop_begins_once_and_queues_shutdown() {
        let (shared, mut jobs) = shared();
        assert!(shared.begin_stop(None));
        assert!(!shared.begin_stop(None), "a second stop is daemon_stopping");
        assert!(shared.is_stopping());
        assert!(matches!(jobs.try_recv(), Ok(Job::Shutdown { initiator: None })));
        assert!(jobs.try_recv().is_err());
    }

    #[test]
    fn idleness_counts_connections_and_jobs() {
        let (shared, _jobs) = shared();
        assert!(shared.is_idle());
        let (out, _receiver) = mpsc::unbounded_channel();
        let conn = shared.register(Origin::Local, out);
        assert!(!shared.is_idle());
        shared.disconnect(&conn);
        assert!(shared.is_idle());
        shared.pending.fetch_add(1, Ordering::SeqCst);
        assert!(!shared.is_idle());
        shared.job_done();
        assert!(shared.is_idle());
    }

    #[test]
    fn password_change_resets_everyone_but_the_requester() {
        let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().unwrap();
        let (shared, _jobs) = shared();
        let conns: Vec<_> = (0..3).map(|_| shared.register(Origin::Local, mpsc::unbounded_channel().0)).collect();
        for conn in &conns {
            conn.set_authorized(true);
        }
        let _input = open_endless(&shared, &runtime, &conns[0], "n0");
        let _kept_input = open_endless(&shared, &runtime, &conns[1], "n1");
        shared.password_changed(conns[1].id);
        assert_eq!(conns.iter().map(|conn| conn.is_authorized()).collect::<Vec<_>>(), [false, true, false]);
        wait_until(|| shared.terminals.running() == ["n1"], "the reset connection's terminal is cancelled");
        shared.disconnect(&conns[1]);
        wait_until(|| shared.terminals.is_empty(), "the requester's terminal ends with its connection");
    }

    /// A transport whose terminal session never ends by itself.
    struct Endless;

    impl rc_core::transport::RemoteSession for Endless {
        async fn exec(&self, _: &str, _: &[u8], _: Duration) -> rc_core::error::Result<rc_core::transport::ExecResult> {
            Err(rc_core::transport::remote_failure("unused"))
        }
        async fn upload(&self, _: &std::path::Path, _: &str, _: Duration) -> rc_core::error::Result<()> {
            Err(rc_core::transport::remote_failure("unused"))
        }
    }

    impl rc_core::transport::RemoteTransport for Endless {
        type Held = Endless;
        async fn connect(&mut self, _: rc_core::transport::ConnectOptions) -> rc_core::error::Result<()> {
            Ok(())
        }
        fn hold(&self) -> rc_core::error::Result<Endless> {
            Ok(Endless)
        }
        async fn interactive(&self, _: &str, _: rc_core::transport::PtyRequest, _: &mut dyn rc_core::transport::RawConsole)
            -> rc_core::error::Result<u32>
        {
            std::future::pending().await
        }
    }

    fn wait_until(condition: impl Fn() -> bool, what: &str) {
        let deadline = Instant::now() + Duration::from_secs(3);
        while !condition() {
            assert!(Instant::now() < deadline, "not within 3 s: {what}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// A running terminal of `conn` on `node`, started as conn.rs and the
    /// core thread would; returns the console input sender.
    fn open_endless(shared: &Arc<Shared>, runtime: &tokio::runtime::Runtime, conn: &Arc<Conn>, node: &str)
        -> mpsc::Sender<rc_core::transport::ConsoleEvent>
    {
        let id = serde_json::json!(format!("term-{node}"));
        let reservation = shared.terminals.reserve(node, conn.id, &id.to_string()).expect("free node");
        let (input, receiver) = mpsc::channel(4);
        conn.link_terminal(&id, input.clone());
        let job = rc_core::terminal::TerminalJob::for_test(node.into(), "menu".into(), "failed".into(), "done", Endless);
        let pty = rc_core::transport::PtyRequest { term: "xterm".into(), size: rc_core::transport::ConsoleSize { cols: 80, rows: 24 } };
        terminal::launch(shared, runtime.handle(), conn.clone(), id, job, core::TerminalRequest { pty, reservation: Some(reservation), input: receiver });
        wait_until(|| shared.terminals.running().iter().any(|running| running == node), "the terminal starts");
        input
    }

    /// П10: a session that never ends is cancelled when its owner leaves;
    /// the reply goes nowhere and the on-demand daemon may then idle out.
    #[test]
    fn a_dropped_owner_ends_a_never_ending_terminal_and_the_daemon_idles_out() {
        let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().unwrap();
        let (shared, _jobs) = shared();
        let (out, mut lines) = mpsc::unbounded_channel();
        let conn = shared.register(Origin::Local, out);
        let _input = open_endless(&shared, &runtime, &conn, "n1");
        let opened = match lines.try_recv() {
            Ok(Out::Line(text, _)) => text.to_string(),
            _ => panic!("the terminal announces itself"),
        };
        assert!(opened.contains("\"state\":\"open\""), "{opened}");
        assert!(!shared.is_idle(), "a running terminal keeps the daemon");
        let dropped = Instant::now();
        shared.disconnect(&conn);
        wait_until(|| shared.terminals.is_empty(), "the registry empties after the owner left");
        assert!(dropped.elapsed() <= Duration::from_secs(3));
        std::thread::sleep(Duration::from_millis(100));
        while let Ok(message) = lines.try_recv() {
            if let Out::Line(text, _) = message {
                assert!(!text.contains("\"ok\""), "no reply to a dead connection: {}", text.as_str());
            }
        }
        assert!(shared.is_idle());
        let policy = local::IdlePolicy { persistent: false, linger: Duration::ZERO, first_client: Duration::from_secs(10), tick: Duration::from_millis(100) };
        let now = Instant::now();
        assert!(local::idle_expired(now, Some(now), shared.ever_connected.load(Ordering::SeqCst), shared.started, &policy),
            "the on-demand daemon exits on idle");
    }

    /// A terminal whose input was closed while it waited for the core (the
    /// client closed it, or overflowed its input) never starts and answers.
    #[test]
    fn a_terminal_closed_before_it_opened_does_not_start() {
        let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().unwrap();
        let (shared, _jobs) = shared();
        let (out, mut lines) = mpsc::unbounded_channel();
        let conn = shared.register(Origin::Local, out);
        let id = serde_json::json!("term-n1");
        let reservation = shared.terminals.reserve("n1", conn.id, &id.to_string()).expect("free node");
        let receiver = mpsc::channel(4).1;
        let job = rc_core::terminal::TerminalJob::for_test("n1".into(), "menu".into(), "failed".into(), "done", Endless);
        let pty = rc_core::transport::PtyRequest { term: "xterm".into(), size: rc_core::transport::ConsoleSize { cols: 80, rows: 24 } };
        terminal::launch(&shared, runtime.handle(), conn.clone(), id, job, core::TerminalRequest { pty, reservation: Some(reservation), input: receiver });
        assert!(shared.terminals.is_empty(), "the node is free again");
        let Ok(Out::Line(text, None)) = lines.try_recv() else { panic!("the request is answered") };
        assert!(text.contains(r#""ok":false"#) && text.contains(r#""reason":"closed""#), "{}", text.as_str());
        assert!(lines.try_recv().is_err(), "no terminal opened");
    }
}
