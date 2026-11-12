//! Terminal requests (`node shell`, `telegram menu`): the registry of nodes
//! with an open terminal, the protocol console and the terminal threads.
//!
//! `conn.rs` reserves a node (`Preparing`) when it accepts the request; the
//! core thread prepares the job and hands it to a `terminal-<node>` thread,
//! which runs it against the requester's connection until it ends or is
//! cancelled (close + 2 s, owner gone, password change, shutdown). The
//! registry entry is removed by the thread's drop guard.

use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::task::{Context, Poll};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use rc_core::dispatch::Envelope;
use rc_core::error::RcError;
use rc_core::log::Level;
use rc_core::terminal::TerminalJob;
use rc_core::transport::{ConsoleEvent, RawConsole, RemoteTransport, remote_failure};
use serde::Serialize;
use serde_json::Value;
use tokio::runtime::Handle;
use tokio::sync::mpsc::error::TrySendError;
use tokio::sync::{mpsc, watch};

use super::conn::{Conn, line};
use super::core::TerminalRequest;
use super::{Shared, lock};

/// Unsent output above which a terminal thread waits for its client.
pub const OUTPUT_LIMIT: usize = 1 << 20;
/// A client that reads nothing for this long ends the terminal.
pub const OUTPUT_WAIT: Duration = Duration::from_secs(60);
/// After `{"close":true}` the remote side gets this long to exit on EOF.
pub const CLOSE_GRACE: Duration = Duration::from_secs(2);
/// Shutdown waits this long for cancelled terminal threads.
pub const STOP_WAIT: Duration = Duration::from_secs(5);
/// Input events queued for one terminal before its session reads them.
pub const INPUT_QUEUE: usize = 64;
/// Decoded input bytes queued for one terminal (one `stdin` message decodes
/// to at most 3 MiB, so a single message always fits).
pub const INPUT_LIMIT: usize = 4 << 20;

/// The connection side of a terminal's input: bounded by [`INPUT_QUEUE`]
/// events and [`INPUT_LIMIT`] bytes; never waits. `key` names this terminal
/// in the [`Registry`] (unique per request, even when an id is reused).
#[derive(Clone)]
pub struct InputSender {
    sender: mpsc::Sender<ConsoleEvent>,
    queued: Arc<AtomicUsize>,
    pub key: String,
}

/// The session side of a terminal's input; reading releases the bytes.
pub struct InputReceiver {
    receiver: mpsc::Receiver<ConsoleEvent>,
    queued: Arc<AtomicUsize>,
    pub key: String,
}

/// The input queue would exceed a limit: the terminal is to be closed.
#[derive(Debug, PartialEq, Eq)]
pub struct InputOverflow;

pub fn input_channel(key: String) -> (InputSender, InputReceiver) {
    let (sender, receiver) = mpsc::channel(INPUT_QUEUE);
    let queued = Arc::new(AtomicUsize::new(0));
    (InputSender { sender, queued: queued.clone(), key: key.clone() }, InputReceiver { receiver, queued, key })
}

fn input_bytes(event: &ConsoleEvent) -> usize {
    match event {
        ConsoleEvent::Input(data) => data.len(),
        _ => 0,
    }
}

impl InputSender {
    /// Queues `event`; a gone session is not an error (its input is moot).
    pub fn send(&self, event: ConsoleEvent) -> Result<(), InputOverflow> {
        if self.sender.is_closed() {
            return Ok(());
        }
        let size = input_bytes(&event);
        if self.queued.fetch_add(size, Ordering::SeqCst) + size > INPUT_LIMIT {
            self.queued.fetch_sub(size, Ordering::SeqCst);
            return Err(InputOverflow);
        }
        match self.sender.try_send(event) {
            Ok(()) => Ok(()),
            Err(TrySendError::Closed(_)) => {
                self.queued.fetch_sub(size, Ordering::SeqCst);
                Ok(())
            }
            Err(TrySendError::Full(_)) => {
                self.queued.fetch_sub(size, Ordering::SeqCst);
                Err(InputOverflow)
            }
        }
    }
}

impl InputReceiver {
    /// Every sender is gone: the client closed the terminal (or overflowed it).
    pub fn is_closed(&self) -> bool {
        self.receiver.is_closed()
    }

    fn poll_recv(&mut self, cx: &mut Context<'_>) -> Poll<Option<ConsoleEvent>> {
        let polled = self.receiver.poll_recv(cx);
        if let Poll::Ready(Some(event)) = &polled {
            self.queued.fetch_sub(input_bytes(event), Ordering::SeqCst);
        }
        polled
    }

    /// The next event (tests drive the session side by hand).
    #[cfg(test)]
    pub(super) async fn recv(&mut self) -> Option<ConsoleEvent> {
        std::future::poll_fn(|cx| self.poll_recv(cx)).await
    }

    #[cfg(test)]
    pub(super) fn queued_bytes(&self) -> usize {
        self.queued.load(Ordering::SeqCst)
    }
}

/// Unsent terminal output of one terminal, in bytes. The terminal thread
/// adds before queueing a line; the connection writer releases (by dropping
/// the [`Credit`]) after the line is written or discarded.
pub struct Pressure {
    state: Mutex<PressureState>,
    ready: Condvar,
}

#[derive(Default)]
struct PressureState {
    pending: usize,
    aborted: bool,
}

/// Bytes of one queued output line; released on drop.
pub struct Credit {
    pressure: Arc<Pressure>,
    bytes: usize,
}

impl Drop for Credit {
    fn drop(&mut self) {
        let mut state = lock(&self.pressure.state);
        state.pending -= self.bytes;
        drop(state);
        self.pressure.ready.notify_all();
    }
}

impl Pressure {
    pub fn new() -> Arc<Self> {
        Arc::new(Self { state: Mutex::default(), ready: Condvar::new() })
    }

    /// Waits while more than [`OUTPUT_LIMIT`] bytes are unsent, then counts
    /// `bytes`. Fails when `closed()`, after [`abort`](Self::abort), or when
    /// the wait exceeds `wait`.
    pub fn reserve(self: &Arc<Self>, bytes: usize, wait: Duration, closed: &dyn Fn() -> bool) -> io::Result<Credit> {
        let deadline = Instant::now() + wait;
        let mut state = lock(&self.state);
        loop {
            if state.aborted || closed() {
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "Терминал закрыт."));
            }
            if state.pending <= OUTPUT_LIMIT {
                break;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "Клиент не принимает вывод терминала."));
            }
            // Wake at least every second to notice a closed connection.
            state = self.ready.wait_timeout(state, left.min(Duration::from_secs(1)))
                .unwrap_or_else(|poisoned| poisoned.into_inner()).0;
        }
        state.pending += bytes;
        Ok(Credit { pressure: self.clone(), bytes })
    }

    /// Wakes and fails a waiting terminal thread for good (cancellation).
    pub fn abort(&self) {
        lock(&self.state).aborted = true;
        self.ready.notify_all();
    }

    #[cfg(test)]
    fn pending(&self) -> usize {
        lock(&self.state).pending
    }
}

/// A node with a terminal: reserved by `conn.rs`, running after preparation.
pub enum TerminalHandle {
    Preparing { conn: u64, request: String, token: u64 },
    Running { conn: u64, request: String, token: u64, cancel: watch::Sender<bool>, pressure: Arc<Pressure>, thread: Option<JoinHandle<()>> },
}

impl TerminalHandle {
    fn conn(&self) -> u64 {
        match self {
            Self::Preparing { conn, .. } | Self::Running { conn, .. } => *conn,
        }
    }

    fn request(&self) -> &str {
        match self {
            Self::Preparing { request, .. } | Self::Running { request, .. } => request,
        }
    }

    fn token(&self) -> u64 {
        match self {
            Self::Preparing { token, .. } | Self::Running { token, .. } => *token,
        }
    }

    fn cancel(&self) {
        if let Self::Running { cancel, pressure, .. } = self {
            cancel.send_replace(true);
            pressure.abort();
        }
    }
}

/// The reservation of a node by one request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reservation {
    pub node: String,
    token: u64,
}

#[derive(Default)]
pub struct Registry {
    entries: Mutex<HashMap<String, TerminalHandle>>,
    tokens: AtomicU64,
}

impl Registry {
    /// Reserves `node` for request `request` of connection `conn`; `None`
    /// when the node already has a terminal (preparing or running).
    pub fn reserve(&self, node: &str, conn: u64, request: &str) -> Option<Reservation> {
        let mut entries = lock(&self.entries);
        if entries.contains_key(node) {
            return None;
        }
        let token = self.tokens.fetch_add(1, Ordering::Relaxed);
        entries.insert(node.to_owned(), TerminalHandle::Preparing { conn, request: request.to_owned(), token });
        Some(Reservation { node: node.to_owned(), token })
    }

    /// Drops the entry if it still belongs to `reservation`.
    pub fn release(&self, reservation: &Reservation) {
        let mut entries = lock(&self.entries);
        if entries.get(&reservation.node).is_some_and(|entry| entry.token() == reservation.token) {
            entries.remove(&reservation.node);
        }
    }

    /// Reserved → running; `false` when the reservation is gone (owner left).
    fn start(&self, reservation: &Reservation, cancel: watch::Sender<bool>, pressure: Arc<Pressure>) -> bool {
        let mut entries = lock(&self.entries);
        let Some(entry) = entries.get_mut(&reservation.node).filter(|entry| entry.token() == reservation.token) else { return false };
        let TerminalHandle::Preparing { conn, request, token } = entry else { return false };
        *entry = TerminalHandle::Running { conn: *conn, request: std::mem::take(request), token: *token, cancel, pressure, thread: None };
        true
    }

    fn set_thread(&self, reservation: &Reservation, handle: JoinHandle<()>) {
        if let Some(TerminalHandle::Running { token, thread, .. }) = lock(&self.entries).get_mut(&reservation.node)
            && *token == reservation.token
        {
            *thread = Some(handle);
        }
    }

    /// `{"close":true}` grace period over: cancel if still running. `request`
    /// is the terminal's [`InputSender::key`], so a later terminal that reuses
    /// the request id is not touched.
    pub fn cancel_request(&self, conn: u64, request: &str) {
        for entry in lock(&self.entries).values() {
            if entry.conn() == conn && entry.request() == request {
                entry.cancel();
            }
        }
    }

    /// The owner connection is gone: reservations drop, sessions cancel.
    pub fn drop_conn(&self, conn: u64) {
        lock(&self.entries).retain(|_, entry| {
            if entry.conn() != conn {
                return true;
            }
            entry.cancel();
            matches!(entry, TerminalHandle::Running { .. })
        });
    }

    /// Connections that lost their authorization lose their terminals.
    pub fn cancel_conns(&self, conns: &[u64]) {
        for entry in lock(&self.entries).values() {
            if conns.contains(&entry.conn()) {
                entry.cancel();
            }
        }
    }

    /// Shutdown: cancel every terminal; the threads to wait for.
    pub fn cancel_all(&self) -> Vec<JoinHandle<()>> {
        let mut entries = lock(&self.entries);
        entries.values_mut().filter_map(|entry| {
            entry.cancel();
            match entry {
                TerminalHandle::Running { thread, .. } => thread.take(),
                TerminalHandle::Preparing { .. } => None,
            }
        }).collect()
    }

    /// Nodes with a running terminal (`daemon status.terminals`).
    pub fn running(&self) -> Vec<String> {
        let mut nodes: Vec<String> = lock(&self.entries).iter()
            .filter(|(_, entry)| matches!(entry, TerminalHandle::Running { .. }))
            .map(|(node, _)| node.clone())
            .collect();
        nodes.sort();
        nodes
    }

    pub fn is_empty(&self) -> bool {
        lock(&self.entries).is_empty()
    }
}

/// Removes the registry entry when the terminal thread ends, however it ends.
struct EntryGuard<'a> {
    registry: &'a Registry,
    reservation: &'a Reservation,
}

impl Drop for EntryGuard<'_> {
    fn drop(&mut self) {
        self.registry.release(self.reservation);
    }
}

#[derive(Serialize)]
struct OutputEvent<'a> {
    id: &'a Value,
    event: &'static str,
    data: &'a str,
}

/// The requester's console as seen by the remote session: input events
/// from the connection, output as base64 `output` events with backpressure.
pub struct ProtocolConsole {
    input: InputReceiver,
    conn: Arc<Conn>,
    id: Value,
    pressure: Arc<Pressure>,
}

impl RawConsole for ProtocolConsole {
    fn poll_event(&mut self, cx: &mut Context<'_>) -> Poll<ConsoleEvent> {
        self.input.poll_recv(cx).map(|event| event.unwrap_or(ConsoleEvent::Closed))
    }

    fn output(&mut self, data: &[u8]) -> io::Result<()> {
        if data.is_empty() {
            return Ok(());
        }
        let encoded = zeroize::Zeroizing::new(STANDARD.encode(data));
        let line = line(&OutputEvent { id: &self.id, event: "output", data: &encoded });
        let conn = &self.conn;
        let credit = self.pressure.reserve(line.len(), OUTPUT_WAIT, &|| conn.is_closed())?;
        self.conn.send_counted(line, credit)
    }
}

/// Resolves once the cancel flag is set (never when the sender is gone).
async fn cancelled(mut cancel: watch::Receiver<bool>) {
    if cancel.wait_for(|cancelled| *cancelled).await.is_err() {
        std::future::pending::<()>().await;
    }
}

/// Runs a prepared terminal job on its own thread for request `id` of
/// `conn`. Answers the request itself (the core thread does not). Generic
/// over the transport so tests can run a job that never ends.
pub fn launch<T: RemoteTransport + Send + 'static>(shared: &Arc<Shared>, handle: &Handle, conn: Arc<Conn>, id: Value,
    job: TerminalJob<T>, terminal: TerminalRequest)
{
    let TerminalRequest { pty, reservation, input } = terminal;
    let reservation = match reservation {
        Some(reservation) => reservation,
        None => match shared.terminals.reserve(&job.node, conn.id, &input.key) {
            Some(reservation) => reservation,
            None => {
                conn.unlink_terminal(&id);
                let error = RcError::new("conflict", format!("Терминал ноды «{}» уже открыт.", job.node)).with_extra("name", job.node.clone());
                return conn.fail(&id, error);
            }
        },
    };
    let (cancel, cancel_receiver) = watch::channel(false);
    let pressure = Pressure::new();
    // The owner left while the job was prepared: the job (and its SSH
    // connection) is dropped unanswered.
    if conn.is_closed() {
        shared.terminals.release(&reservation);
        return;
    }
    // The client closed the terminal (or overflowed its input) before it
    // opened: nothing starts, the request ends like a closed terminal.
    if input.is_closed() {
        shared.terminals.release(&reservation);
        return conn.fail(&id, remote_failure("closed").with_extra("name", job.node.clone()));
    }
    if !shared.terminals.start(&reservation, cancel, pressure.clone()) {
        shared.terminals.release(&reservation);
        return;
    }
    conn.send(&serde_json::json!({"id": id, "event": "terminal", "state": "open"}));
    let (thread_shared, thread_handle, thread_reservation) = (shared.clone(), handle.clone(), reservation.clone());
    let (thread_conn, thread_id) = (conn.clone(), id.clone());
    let spawned = std::thread::Builder::new().name(format!("terminal-{}", reservation.node)).spawn(move || {
        let (shared, conn, id, reservation) = (thread_shared, thread_conn, thread_id, thread_reservation);
        let guard = EntryGuard { registry: &shared.terminals, reservation: &reservation };
        let node = job.node.clone();
        let done_log = job.done_log;
        let mut console = ProtocolConsole { input, conn: conn.clone(), id: id.clone(), pressure };
        let result = thread_handle.block_on(async {
            tokio::select! {
                result = job.run(pty, &mut console) => result,
                () = cancelled(cancel_receiver) => Err(remote_failure("closed").with_extra("name", node)),
            }
        });
        drop(console);
        // Free the node before answering: the client may reopen at once.
        drop(guard);
        conn.unlink_terminal(&id);
        match result {
            Ok(data) => {
                conn.log(&id, Level::Info, done_log);
                conn.reply(&id, Envelope::success(data));
            }
            Err(error) => conn.fail(&id, error),
        }
    });
    match spawned {
        Ok(thread) => shared.terminals.set_thread(&reservation, thread),
        Err(error) => {
            shared.terminals.release(&reservation);
            conn.unlink_terminal(&id);
            conn.fail(&id, RcError::new("failed", format!("Не удалось запустить поток терминала: {error}")));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credits_release_on_drop_and_block_above_the_limit() {
        let pressure = Pressure::new();
        let open = || false;
        let big = pressure.reserve(OUTPUT_LIMIT, OUTPUT_WAIT, &open).unwrap();
        let small = pressure.reserve(1, OUTPUT_WAIT, &open).unwrap();
        assert_eq!(pressure.pending(), OUTPUT_LIMIT + 1);
        let timeout = pressure.reserve(1, Duration::from_millis(30), &open).err().unwrap();
        assert_eq!(timeout.kind(), io::ErrorKind::TimedOut);
        // The writer releases from another thread; the waiter proceeds.
        let waiter = {
            let pressure = pressure.clone();
            std::thread::spawn(move || pressure.reserve(5, OUTPUT_WAIT, &|| false).map(|credit| credit.bytes))
        };
        std::thread::sleep(Duration::from_millis(50));
        drop(big);
        assert_eq!(waiter.join().unwrap().unwrap(), 5);
        drop(small);
        assert_eq!(pressure.pending(), 0);
    }

    #[test]
    fn a_closed_connection_or_abort_fails_the_waiter() {
        let pressure = Pressure::new();
        let _held = pressure.reserve(OUTPUT_LIMIT + 1, OUTPUT_WAIT, &|| false).unwrap();
        assert_eq!(pressure.reserve(1, OUTPUT_WAIT, &|| true).err().unwrap().kind(), io::ErrorKind::BrokenPipe);
        let waiter = {
            let pressure = pressure.clone();
            std::thread::spawn(move || pressure.reserve(1, OUTPUT_WAIT, &|| false).err().map(|error| error.kind()))
        };
        std::thread::sleep(Duration::from_millis(50));
        pressure.abort();
        assert_eq!(waiter.join().unwrap(), Some(io::ErrorKind::BrokenPipe));
    }

    #[test]
    fn registry_reserves_once_and_forgets_dropped_owners() {
        let registry = Registry::default();
        let first = registry.reserve("n1", 1, "7").unwrap();
        assert!(registry.reserve("n1", 2, "1").is_none(), "conflict while preparing");
        assert!(registry.running().is_empty(), "status shows running terminals only");
        registry.drop_conn(1);
        assert!(registry.is_empty());
        assert!(!registry.start(&first, watch::channel(false).0, Pressure::new()), "a dropped reservation never starts");

        let second = registry.reserve("n1", 2, "1").unwrap();
        registry.release(&first);
        assert!(!registry.is_empty(), "a stale reservation releases nothing");
        let (cancel, receiver) = watch::channel(false);
        assert!(registry.start(&second, cancel, Pressure::new()));
        assert_eq!(registry.running(), ["n1"]);
        registry.drop_conn(2);
        assert!(*receiver.borrow(), "the owner's running terminal is cancelled");
        assert_eq!(registry.running(), ["n1"], "the thread's guard removes it");
        registry.release(&second);
        assert!(registry.is_empty());
    }

    #[test]
    fn cancellation_targets_requests_and_connections() {
        let registry = Registry::default();
        let mut receivers = Vec::new();
        for (node, conn, request) in [("a", 1, "1"), ("b", 1, "2"), ("c", 2, "1")] {
            let reservation = registry.reserve(node, conn, request).unwrap();
            let (cancel, receiver) = watch::channel(false);
            assert!(registry.start(&reservation, cancel, Pressure::new()));
            receivers.push(receiver);
        }
        let cancelled = |receivers: &[watch::Receiver<bool>]| receivers.iter().map(|receiver| *receiver.borrow()).collect::<Vec<_>>();
        registry.cancel_request(1, "2");
        assert_eq!(cancelled(&receivers), [false, true, false]);
        registry.cancel_conns(&[2]);
        assert_eq!(cancelled(&receivers), [false, true, true]);
        assert!(registry.cancel_all().is_empty(), "no threads in this test");
        assert_eq!(cancelled(&receivers), [true, true, true]);
    }

    /// The delayed cancel of a closed terminal names its own key: a new
    /// terminal that reuses the request id (`"7"#0` → `"7"#1`) survives it.
    #[test]
    fn a_late_cancel_spares_a_terminal_that_reuses_the_id() {
        let registry = Registry::default();
        let (old, _) = input_channel("\"7\"#0".into());
        let (new, _) = input_channel("\"7\"#1".into());
        let reservation = registry.reserve("n1", 1, &new.key).unwrap();
        let (cancel, receiver) = watch::channel(false);
        assert!(registry.start(&reservation, cancel, Pressure::new()));
        registry.cancel_request(1, &old.key);
        assert!(!*receiver.borrow(), "the earlier terminal's timer misses the new one");
        registry.cancel_request(1, &new.key);
        assert!(*receiver.borrow());
    }

    #[test]
    fn input_is_bounded_by_events_and_bytes() {
        let (sender, receiver) = input_channel("k".into());
        assert_eq!(sender.send(ConsoleEvent::Input(vec![0; INPUT_LIMIT])), Ok(()));
        assert_eq!(sender.send(ConsoleEvent::Input(vec![0; 1])), Err(InputOverflow), "bytes");
        assert_eq!(sender.send(ConsoleEvent::Closed), Ok(()), "control events cost no bytes");
        drop(receiver);
        assert_eq!(sender.send(ConsoleEvent::Input(vec![0; INPUT_LIMIT])), Ok(()), "a gone session is not an overflow");
        let (sender, _receiver) = input_channel("k".into());
        for _ in 0..INPUT_QUEUE {
            sender.send(ConsoleEvent::Closed).unwrap();
        }
        assert_eq!(sender.send(ConsoleEvent::Closed), Err(InputOverflow), "events");
    }
}
