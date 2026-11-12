//! One client connection: protocol v3 messages in, events and replies out.
//!
//! Routing order of a request (П4): parse and whitelist (`dispatch::checked`)
//! → `client_side` → `local_only` → `help` → connection authorization →
//! `daemon`/`web` → `requires_tty` →
//! `session open` → queued command. Only `help`, `session status`,
//! `session open` (and, locally, `self version`, `daemon *`, `web *`) work
//! before the connection authorized itself with `session open`. Network
//! connections arrive from the web listener and obey the limits of
//! [`access`](super::access).

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use essence_rc_client::protocol::MAX_MESSAGE;
use essence_rc_client::{Origin, PROTOCOL, TerminalSpec, WindowSize};
use rc_core::cli::{self, Invocation};
use rc_core::dispatch::{self, Envelope};
use rc_core::error::RcError;
use rc_core::log::Level;
use rc_core::request_input::Input;
use rc_core::request_secrets::Secrets;
use rc_core::terminal::tty_required;
use rc_core::transport::{ConsoleEvent, ConsoleSize, PtyRequest};
use rc_core::VERSION;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use serde_json::value::RawValue;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::sync::{Notify, mpsc, oneshot};
use zeroize::Zeroizing;

use super::access::{self, OpenOutcome};
use super::core::{Job, Request, TerminalRequest};
use super::local::LineReader;
use super::terminal::{self, CLOSE_GRACE, Credit, InputSender};
use super::{Shared, commands, lock};

/// Longest `SSH_AUTH_SOCK` path accepted in the request `env`.
const MAX_AGENT_PATH: usize = 4096;
/// Bytes of events and replies queued for a client that does not read; more
/// disconnects it (terminal output is bounded by its own credits).
const MAX_QUEUED: usize = 4 * MAX_MESSAGE;
/// How often an authorized network connection notices a lost authorization.
const AUTHORIZATION_RECHECK: std::time::Duration = std::time::Duration::from_secs(1);

/// A message for the connection's writer task.
pub enum Out {
    /// One protocol line (with its `\n`); terminal output carries the
    /// backpressure credit released once the line is written.
    Line(Zeroizing<String>, Option<Credit>),
    /// Flush what is queued and close the connection (daemon exit).
    Close,
}

/// One protocol line with its newline; the serialized text is wiped.
pub fn line(value: &impl Serialize) -> Zeroizing<String> {
    let text = Zeroizing::new(serde_json::to_string(value).expect("protocol messages always serialize"));
    let mut line = Zeroizing::new(String::with_capacity(text.len() + 1));
    line.push_str(&text);
    line.push('\n');
    line
}

/// Final reply: `{"id","ok":true,"data","sync"?}` or `{"id","ok":false,"error","exit"}`.
#[derive(Serialize)]
struct Wire<'a> {
    id: &'a Value,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<&'a Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<&'a RcError>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sync: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    exit: Option<u8>,
}

#[derive(Serialize)]
struct LogEvent<'a> {
    id: &'a Value,
    event: &'static str,
    level: Level,
    text: &'a str,
}

/// Key of a request id in per-connection maps (ids are scalars).
fn key(id: &Value) -> String {
    id.to_string()
}

pub struct Conn {
    pub id: u64,
    pub origin: Origin,
    pub since: Instant,
    /// The connection proved the right to control (`session open`).
    /// Written only by the core thread.
    authorized: AtomicBool,
    watch: AtomicBool,
    closed: AtomicBool,
    /// A network `session open` of this connection is under way.
    opening: AtomicBool,
    out: mpsc::UnboundedSender<Out>,
    /// Bytes of uncredited lines sent to the writer and not yet written.
    queued: AtomicUsize,
    /// Stops the writer at once (a client that stopped reading).
    kill: Notify,
    /// Requests of this connection not yet answered.
    in_flight: Mutex<HashSet<String>>,
    /// Console input of this connection's terminal requests.
    terminals: Mutex<HashMap<String, InputSender>>,
    /// Numbers this connection's terminals (registry keys stay unique when a
    /// request id is reused).
    next_terminal: AtomicU64,
}

impl Conn {
    pub fn new(id: u64, origin: Origin, out: mpsc::UnboundedSender<Out>) -> Self {
        Self {
            id,
            origin,
            since: Instant::now(),
            authorized: AtomicBool::new(false),
            watch: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            opening: AtomicBool::new(false),
            out,
            queued: AtomicUsize::new(0),
            kill: Notify::new(),
            in_flight: Mutex::default(),
            terminals: Mutex::default(),
            next_terminal: AtomicU64::new(0),
        }
    }

    pub fn is_authorized(&self) -> bool {
        self.authorized.load(Ordering::SeqCst)
    }

    pub fn authorized_flag(&self) -> &AtomicBool {
        &self.authorized
    }

    pub fn set_authorized(&self, authorized: bool) {
        self.authorized.store(authorized, Ordering::SeqCst);
    }

    pub fn watching(&self) -> bool {
        self.watch.load(Ordering::SeqCst)
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// Marks the connection gone; its terminals see their input end.
    pub fn mark_closed(&self) {
        self.closed.store(true, Ordering::SeqCst);
        lock(&self.terminals).clear();
    }

    /// Events and replies. A client that let [`MAX_QUEUED`] bytes pile up is
    /// disconnected: nothing is dropped from a connection that stays.
    pub fn send(&self, value: &impl Serialize) {
        if self.is_closed() {
            return;
        }
        let line = line(value);
        let size = line.len();
        if self.queued.fetch_add(size, Ordering::SeqCst) + size > MAX_QUEUED {
            self.mark_closed();
            self.kill.notify_one();
            return;
        }
        let _ = self.out.send(Out::Line(line, None));
    }

    /// Terminal output: fails once the connection is gone.
    pub fn send_counted(&self, line: Zeroizing<String>, credit: Credit) -> io::Result<()> {
        let gone = || io::Error::new(io::ErrorKind::BrokenPipe, "Соединение закрыто.");
        if self.is_closed() {
            return Err(gone());
        }
        self.out.send(Out::Line(line, Some(credit))).map_err(|_| gone())
    }

    pub fn log(&self, id: &Value, level: Level, text: &str) {
        self.send(&LogEvent { id, event: "log", level, text });
    }

    /// The one reply of a request; errors carry the CLI exit status.
    pub fn reply(&self, id: &Value, envelope: Envelope) {
        lock(&self.in_flight).remove(&key(id));
        let exit = (!envelope.ok).then(|| envelope.exit_code());
        self.send(&Wire {
            id,
            ok: envelope.ok,
            data: envelope.data.as_ref(),
            error: envelope.error.as_ref(),
            sync: envelope.sync.as_deref(),
            exit,
        });
    }

    pub fn fail(&self, id: &Value, error: RcError) {
        self.reply(id, Envelope::failure(error));
    }

    /// A reply that does not end the request it names: a message rejected
    /// before its request began (or beside a running one) must not free an
    /// id another request still uses.
    pub fn reject(&self, id: &Value, error: RcError) {
        self.send(&Wire { id, ok: false, data: None, error: Some(&error), sync: None, exit: Some(error.exit_code()) });
    }

    /// Registers a running request id; `false` when it already runs here.
    fn begin(&self, id: &Value) -> bool {
        lock(&self.in_flight).insert(key(id))
    }

    /// A fresh input channel for terminal request `id`, keyed uniquely.
    pub fn terminal_channel(&self, id: &Value) -> (InputSender, terminal::InputReceiver) {
        terminal::input_channel(format!("{}#{}", key(id), self.next_terminal.fetch_add(1, Ordering::Relaxed)))
    }

    fn in_flight(&self) -> usize {
        lock(&self.in_flight).len()
    }

    pub fn link_terminal(&self, id: &Value, input: InputSender) {
        if !self.is_closed() {
            lock(&self.terminals).insert(key(id), input);
        }
    }

    pub fn unlink_terminal(&self, id: &Value) {
        lock(&self.terminals).remove(&key(id));
    }

    fn terminal_input(&self, id: &Value) -> Option<InputSender> {
        lock(&self.terminals).get(&key(id)).cloned()
    }

    pub fn close_output(&self) {
        let _ = self.out.send(Out::Close);
    }

    /// The network `session open` of this connection is answered: the next
    /// one is accepted. Cleared before the reply goes out, so a client that
    /// sends the next `session open` right after the reply is not refused.
    pub(super) fn finish_open(&self) {
        self.opening.store(false, Ordering::SeqCst);
    }
}

pub fn invalid_request() -> RcError {
    RcError::new("usage", "Неверный запрос.")
}

pub fn session_closed() -> RcError {
    RcError::new("session_closed", "Сначала откройте сессию: session open.")
}

pub fn daemon_stopping() -> RcError {
    RcError::new("daemon_stopping", "Демон останавливается. Повторите команду.")
}

/// What to do with a parsed request (pure: the routing table of П4).
#[derive(Debug)]
pub enum Route {
    Fail(RcError),
    Help,
    /// `daemon status|stop`: answered without the queue.
    Daemon,
    /// `web *`: answered without the queue.
    Web,
    /// `node shell`, `telegram menu` with a console: `Job::TerminalPrep`.
    Terminal,
    SessionOpen,
    /// A queued command; `needs_auth` is re-checked by the core thread.
    Command { needs_auth: bool },
}

/// Commands a connection may run before `session open` authorized it.
fn open_to_unauthorized(invocation: &Invocation, origin: Origin) -> bool {
    match (invocation.noun.as_str(), invocation.verb.as_str()) {
        ("session", "status" | "open") => true,
        ("self", "version") | ("daemon", _) | ("web", _) => origin == Origin::Local,
        _ => false,
    }
}

pub fn decide(invocation: &Invocation, origin: Origin, authorized: bool, terminal: bool) -> Route {
    if invocation.client_side() {
        return Route::Fail(RcError::new("usage", "Команда выполняется на стороне клиента."));
    }
    if invocation.local_only() && origin != Origin::Local {
        return Route::Fail(RcError::new("local_only", "Команда доступна только на машине демона."));
    }
    if invocation.help {
        return Route::Help;
    }
    let open = open_to_unauthorized(invocation, origin);
    if !authorized && !open {
        return Route::Fail(session_closed());
    }
    match invocation.noun.as_str() {
        "daemon" => return Route::Daemon,
        "web" => return Route::Web,
        _ => {}
    }
    if invocation.requires_tty() {
        return if terminal { Route::Terminal } else { Route::Fail(tty_required(&invocation.noun)) };
    }
    if (invocation.noun.as_str(), invocation.verb.as_str()) == ("session", "open") {
        return Route::SessionOpen;
    }
    Route::Command { needs_auth: !open }
}

/// `noun verb` of a command (`status` alone has no verb).
pub fn label(invocation: &Invocation) -> String {
    if invocation.verb.is_empty() { invocation.noun.clone() } else { format!("{} {}", invocation.noun, invocation.verb) }
}

/// Every field a client message may carry. Secrets and input stay raw
/// slices of the (wiped) line and are decoded straight into their
/// zeroizing containers.
#[derive(Deserialize)]
struct Message<'a> {
    #[serde(default)]
    id: Value,
    #[serde(default)]
    argv: Option<Value>,
    #[serde(default, borrow)]
    secrets: Option<&'a RawValue>,
    #[serde(default, borrow)]
    input: Option<&'a RawValue>,
    #[serde(default)]
    env: Option<Value>,
    #[serde(default)]
    terminal: Option<Value>,
    #[serde(default)]
    watch: Option<Value>,
    #[serde(default)]
    stdin: Option<Zeroizing<String>>,
    #[serde(default)]
    resize: Option<Value>,
    #[serde(default)]
    close: Option<Value>,
}

fn valid_id(id: &Value) -> bool {
    match id {
        Value::String(text) => !text.contains('\0'),
        Value::Number(_) | Value::Null => true,
        _ => false,
    }
}

fn parse_argv(value: Option<&Value>) -> Option<Vec<String>> {
    value?.as_array()?.iter()
        .map(|item| item.as_str().filter(|text| !text.contains('\0')).map(str::to_owned))
        .collect()
}

/// `env`: only `SSH_AUTH_SOCK` (an absolute path) and only locally.
fn parse_env(value: Option<&Value>, origin: Origin) -> Result<Option<PathBuf>, ()> {
    let Some(value) = value.filter(|value| !value.is_null()) else { return Ok(None) };
    if origin != Origin::Local {
        return Err(());
    }
    let map = value.as_object().ok_or(())?;
    if map.keys().any(|name| name != "SSH_AUTH_SOCK") {
        return Err(());
    }
    let Some(path) = map.get("SSH_AUTH_SOCK") else { return Ok(None) };
    let path = path.as_str().ok_or(())?;
    if path.is_empty() || path.len() > MAX_AGENT_PATH || path.contains('\0') {
        return Err(());
    }
    let path = PathBuf::from(path);
    if !path.is_absolute() {
        return Err(());
    }
    Ok(Some(path))
}

/// `terminal`: `{term, cols, rows}` of the requester's console.
fn parse_terminal(value: Option<&Value>) -> Result<Option<PtyRequest>, ()> {
    let Some(value) = value.filter(|value| !value.is_null()) else { return Ok(None) };
    let spec: TerminalSpec = serde_json::from_value(value.clone()).map_err(|_| ())?;
    let term_ok = (1..=64).contains(&spec.term.len()) && spec.term.bytes().all(|byte| byte.is_ascii_graphic());
    if !term_ok || spec.cols == 0 || spec.rows == 0 {
        return Err(());
    }
    Ok(Some(PtyRequest { term: spec.term, size: ConsoleSize { cols: spec.cols, rows: spec.rows } }))
}

/// `hello`: local clients learn the daemon executable and its mode,
/// network clients the kind of listener they came through.
#[derive(Serialize)]
struct Hello<'a> {
    event: &'static str,
    protocol: u32,
    version: &'static str,
    origin: Origin,
    #[serde(skip_serializing_if = "Option::is_none")]
    exe: Option<&'a std::path::Path>,
    #[serde(skip_serializing_if = "Option::is_none")]
    persistent: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    listener: Option<ListenerHello>,
}

/// `hello.listener` of a network connection.
#[derive(Clone, Copy, Debug, Serialize)]
pub struct ListenerHello {
    pub loopback: bool,
    pub tls: bool,
}

/// Serves one accepted (and already registered) connection until either
/// side closes it.
pub async fn serve<S>(shared: Arc<Shared>, conn: Arc<Conn>, outgoing: mpsc::UnboundedReceiver<Out>, stream: S)
where
    S: AsyncRead + AsyncWrite + Send + 'static,
{
    // Accepted while the daemon decided to stop: closed without hello.
    if shared.is_stopping() {
        shared.disconnect(&conn);
        return;
    }
    let (reader, writer) = tokio::io::split(stream);
    let origin = conn.origin;
    conn.send(&Hello {
        event: "hello", protocol: PROTOCOL, version: VERSION, origin,
        exe: Some(&shared.exe), persistent: Some(shared.is_persistent()), listener: None,
    });
    let mut writer = tokio::spawn(write_loop(writer, outgoing, conn.clone()));
    let mut lines = LineReader::new(reader, MAX_MESSAGE);
    loop {
        tokio::select! {
            line = lines.next() => match line {
                Ok(Some(line)) => handle_line(&shared, &conn, &line).await,
                _ => break,
            },
            // The writer stopped (write error, a client that does not read,
            // daemon exit): the connection is over for both directions.
            _ = &mut writer => break,
        }
    }
    // A client that closed its side is gone: results are dropped.
    shared.disconnect(&conn);
    writer.abort();
}

async fn write_loop<W: AsyncWrite>(writer: W, mut outgoing: mpsc::UnboundedReceiver<Out>, conn: Arc<Conn>) {
    tokio::pin!(writer);
    loop {
        let message = tokio::select! {
            () = conn.kill.notified() => return,
            message = outgoing.recv() => match message {
                Some(message) => message,
                None => return,
            },
        };
        match message {
            Out::Line(line, credit) => {
                let written = tokio::select! {
                    () = conn.kill.notified() => return,
                    written = async { writer.write_all(line.as_bytes()).await?; writer.flush().await } => written,
                };
                if credit.is_none() {
                    conn.queued.fetch_sub(line.len(), Ordering::SeqCst);
                }
                drop(credit);
                if written.is_err() {
                    conn.mark_closed();
                    return;
                }
            }
            Out::Close => {
                let _ = writer.shutdown().await;
                return;
            }
        }
    }
}

/// Serves the WebSocket connections of one listener until it stops.
pub async fn accept_network(shared: Arc<Shared>, mut accepted: mpsc::Receiver<essence_rc_web::Accepted>, listener: ListenerHello) {
    while let Some(socket) = accepted.recv().await {
        // Dropping the accepted socket closes it: during a stop, and beyond
        // the limit of connections that have not authorized themselves.
        if shared.is_stopping() || shared.unauthorized_network() >= access::MAX_UNAUTHORIZED {
            continue;
        }
        let (out, outgoing) = mpsc::unbounded_channel();
        let conn = shared.register(Origin::Network, out);
        tokio::spawn(serve_network(shared.clone(), conn, outgoing, socket, listener));
    }
}

async fn serve_network(
    shared: Arc<Shared>,
    conn: Arc<Conn>,
    mut outgoing: mpsc::UnboundedReceiver<Out>,
    socket: essence_rc_web::Accepted,
    listener: ListenerHello,
) {
    let essence_rc_web::Accepted { mut incoming, outgoing: sink, .. } = socket;
    conn.send(&Hello {
        event: "hello", protocol: PROTOCOL, version: VERSION, origin: Origin::Network,
        exe: None, persistent: None, listener: Some(listener),
    });
    let writer_conn = conn.clone();
    // One protocol message per WebSocket frame, without the newline. The
    // queue limit of `Conn::send` applies here too: a client that stopped
    // reading is cut off by `kill`, not buffered.
    let mut writer = tokio::spawn(async move {
        loop {
            let message = tokio::select! {
                () = writer_conn.kill.notified() => return,
                message = outgoing.recv() => message,
            };
            // `Out::Close` or the connection is gone: dropping the sink closes the socket.
            let Some(Out::Line(mut line, credit)) = message else { return };
            let size = line.len();
            if line.ends_with('\n') {
                line.pop();
            }
            let sent = tokio::select! {
                () = writer_conn.kill.notified() => return,
                sent = sink.send(line) => sent,
            };
            if credit.is_none() {
                writer_conn.queued.fetch_sub(size, Ordering::SeqCst);
            }
            drop(credit);
            if sent.is_err() {
                writer_conn.mark_closed();
                return;
            }
        }
    });
    // An unauthorized connection — new, or reset by a password change —
    // has 60 s to authorize itself; an authorized one is re-checked every
    // second so a lost authorization starts that clock.
    let mut unauthorized_since = Some(tokio::time::Instant::now());
    let mut recheck = tokio::time::interval(AUTHORIZATION_RECHECK);
    loop {
        let authorized = conn.is_authorized();
        if authorized {
            unauthorized_since = None;
        } else if unauthorized_since.is_none() {
            unauthorized_since = Some(tokio::time::Instant::now());
        }
        let deadline = unauthorized_since.map(|since| since + access::PREAUTH_TIMEOUT);
        tokio::select! {
            line = incoming.recv() => {
                // `web stop` closes the connection first: lines still in
                // flight are not executed.
                let Some(line) = line else { break };
                if conn.is_closed() {
                    break;
                }
                // The listener already assembled up to 4 MiB (`MAX_MESSAGE`)
                // before this check — an accepted exception: the 64 KiB limit
                // keeps unauthorized messages out of the parser and the queue.
                if !conn.is_authorized() && line.len() > access::PREAUTH_MESSAGE {
                    break;
                }
                handle_line(&shared, &conn, line.as_bytes()).await;
            }
            () = tokio::time::sleep_until(deadline.unwrap_or_else(tokio::time::Instant::now)), if deadline.is_some() => break,
            _ = recheck.tick(), if authorized => {}
            // The writer stopped (send error, a client that does not read,
            // `Out::Close`): the connection is over for both directions.
            _ = &mut writer => break,
        }
    }
    shared.disconnect(&conn);
    writer.abort();
}

/// One line from the client. Never fails the connection: bad messages get
/// a `usage` reply, terminal messages for unknown ids are ignored.
pub async fn handle_line(shared: &Arc<Shared>, conn: &Arc<Conn>, line: &[u8]) {
    let Ok(text) = std::str::from_utf8(line) else { return conn.reject(&Value::Null, invalid_request()) };
    if text.trim().is_empty() {
        return;
    }
    let Ok(message) = serde_json::from_str::<Message<'_>>(text) else { return conn.reject(&Value::Null, invalid_request()) };
    if !valid_id(&message.id) {
        return conn.reject(&Value::Null, invalid_request());
    }
    let id = message.id.clone();
    if message.stdin.is_some() || message.resize.is_some() || message.close.is_some() {
        return terminal_message(shared, conn, &id, message);
    }
    if let Some(watch) = &message.watch
        && message.argv.is_none()
    {
        match watch.as_bool() {
            Some(watch) => conn.watch.store(watch, Ordering::SeqCst),
            None => conn.reject(&id, invalid_request()),
        }
        return;
    }
    request(shared, conn, id, message);
}

fn terminal_message(shared: &Arc<Shared>, conn: &Arc<Conn>, id: &Value, message: Message<'_>) {
    let Some(input) = conn.terminal_input(id) else { return };
    if let Some(data) = message.stdin {
        let mut bytes = Zeroizing::new(Vec::new());
        if STANDARD.decode_vec(data.as_bytes(), &mut bytes).is_ok() {
            deliver(shared, conn, id, &input, ConsoleEvent::Input(std::mem::take(&mut *bytes)));
        }
    } else if let Some(resize) = message.resize {
        if let Ok(size) = serde_json::from_value::<WindowSize>(resize) {
            deliver(shared, conn, id, &input, ConsoleEvent::Resize(ConsoleSize { cols: size.cols, rows: size.rows }));
        }
    } else if message.close == Some(Value::Bool(true)) {
        // The remote side gets EOF first; a session that ignores it is
        // cancelled after the grace period. The link goes too: a terminal
        // still waiting for the core sees its input closed and never opens.
        deliver(shared, conn, id, &input, ConsoleEvent::Closed);
        conn.unlink_terminal(id);
        close_after_grace(shared, conn, &input);
    }
}

/// Never waits: the reader must stay free for `close` and new requests. A
/// terminal whose input queue is full — by events or by bytes (not started
/// yet, or stalled) — is closed: its link goes, so the session reads EOF
/// after the queued input.
fn deliver(shared: &Arc<Shared>, conn: &Conn, id: &Value, input: &InputSender, event: ConsoleEvent) {
    if input.send(event).is_err() {
        conn.unlink_terminal(id);
        conn.log(id, Level::Error, "Ввод терминала не успевает обрабатываться: терминал закрыт.");
        close_after_grace(shared, conn, input);
    }
}

/// Cancels exactly this terminal after the grace period, not a later one
/// that reuses the request id.
fn close_after_grace(shared: &Arc<Shared>, conn: &Conn, input: &InputSender) {
    let (shared, conn_id, request) = (shared.clone(), conn.id, input.key.clone());
    tokio::spawn(async move {
        tokio::time::sleep(CLOSE_GRACE).await;
        shared.terminals.cancel_request(conn_id, &request);
    });
}

fn request(shared: &Arc<Shared>, conn: &Arc<Conn>, id: Value, message: Message<'_>) {
    let Some(argv) = parse_argv(message.argv.as_ref()) else { return conn.reject(&id, invalid_request()) };
    if conn.origin == Origin::Network {
        let limit = if conn.is_authorized() { access::IN_FLIGHT } else { access::PREAUTH_IN_FLIGHT };
        if conn.in_flight() >= limit {
            return conn.reject(&id, RcError::new("usage", "Слишком много одновременных запросов."));
        }
    }
    if !conn.begin(&id) {
        // The running request keeps the id; this answer does not end it.
        return conn.reject(&id, RcError::new("usage", "Запрос с таким id уже выполняется."));
    }
    if shared.is_stopping() {
        return conn.fail(&id, daemon_stopping());
    }
    let secrets = match message.secrets.map(|raw| Secrets::from_json(raw.get())).transpose() {
        Ok(secrets) => secrets.unwrap_or_default(),
        Err(error) => return conn.fail(&id, error),
    };
    let input = match message.input.map(|raw| Input::from_json(raw.get())).transpose() {
        Ok(input) => input.unwrap_or_default(),
        Err(error) => return conn.fail(&id, error),
    };
    let Ok(agent) = parse_env(message.env.as_ref(), conn.origin) else { return conn.fail(&id, invalid_request()) };
    let Ok(pty) = parse_terminal(message.terminal.as_ref()) else { return conn.fail(&id, invalid_request()) };
    // The same parse and whitelist as the core: transport flags, foreign
    // secrets and inputs never reach a route, `daemon *` included.
    let invocation = match dispatch::checked(&argv, &secrets, &input) {
        Ok(invocation) => invocation,
        Err(error) => return conn.fail(&id, error),
    };
    let route = decide(&invocation, conn.origin, conn.is_authorized(), pty.is_some());
    let job = |needs_auth: bool| Request {
        conn: conn.clone(),
        id: id.clone(),
        label: label(&invocation),
        argv,
        secrets,
        input,
        agent,
        needs_auth,
    };
    match route {
        Route::Fail(error) => conn.fail(&id, error),
        Route::Help => conn.reply(&id, Envelope::success(cli::help(invocation.help_noun()))),
        Route::Daemon => commands::run(shared, conn, &id, &invocation),
        Route::Web => {
            tokio::spawn(commands::web(shared.clone(), conn.clone(), id, invocation));
        }
        Route::Terminal => {
            let (sender, receiver) = conn.terminal_channel(&id);
            let reservation = match invocation.value("name") {
                Some(node) => match shared.terminals.reserve(node, conn.id, &sender.key) {
                    Some(reservation) => Some(reservation),
                    None => {
                        let error = RcError::new("conflict", format!("Терминал ноды «{node}» уже открыт.")).with_extra("name", node);
                        return conn.fail(&id, error);
                    }
                },
                // The core answers for the missing --name.
                None => None,
            };
            conn.link_terminal(&id, sender);
            announce_wait(shared, conn, &id);
            let pty = pty.expect("Route::Terminal implies a terminal field");
            if !shared.enqueue(Job::TerminalPrep(job(true), TerminalRequest { pty, reservation: reservation.clone(), input: receiver })) {
                if let Some(reservation) = &reservation {
                    shared.terminals.release(reservation);
                }
                conn.unlink_terminal(&id);
                conn.fail(&id, daemon_stopping());
            }
        }
        Route::SessionOpen if conn.origin == Origin::Network => {
            // One at a time per connection; the daemon-wide throttle orders the rest.
            if conn.opening.swap(true, Ordering::SeqCst) {
                return conn.fail(&id, invalid_request());
            }
            tokio::spawn(network_open(shared.clone(), job(false)));
        }
        Route::SessionOpen => {
            announce_wait(shared, conn, &id);
            if !shared.enqueue(Job::SessionOpen(job(false), None)) {
                conn.fail(&id, daemon_stopping());
            }
        }
        Route::Command { needs_auth } => {
            announce_wait(shared, conn, &id);
            if !shared.enqueue(Job::Command(job(needs_auth))) {
                conn.fail(&id, daemon_stopping());
            }
        }
    }
}

/// A network `session open`: under the daemon-wide throttle, after the
/// pause its failure count asks for; the outcome moves the count.
async fn network_open(shared: Arc<Shared>, request: Request) {
    let conn = request.conn.clone();
    let id = request.id.clone();
    let mut failures = shared.throttle.lock().await;
    let pause = access::throttle(*failures);
    if !pause.is_zero() {
        tokio::time::sleep(pause).await;
    }
    announce_wait(&shared, &conn, &id);
    let (done, outcome) = oneshot::channel::<OpenOutcome>();
    if !shared.enqueue(Job::SessionOpen(request, Some(done))) {
        conn.finish_open();
        conn.fail(&id, daemon_stopping());
    } else if let Ok(outcome) = outcome.await {
        *failures = access::advance(*failures, outcome);
    }
    drop(failures);
    // The core clears it before its reply; a job dropped unanswered does not.
    conn.finish_open();
}

/// A request queued behind the executing one learns what it waits for;
/// an unauthorized network connection learns nothing about other work.
fn announce_wait(shared: &Shared, conn: &Conn, id: &Value) {
    if conn.origin == Origin::Network && !conn.is_authorized() {
        return;
    }
    if let Some(busy) = shared.busy() {
        conn.log(id, Level::Info, &format!("Ожидание: выполняется «{busy}»."));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(words: &[&str]) -> Invocation {
        cli::parse(&words.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>()).unwrap()
    }

    fn route(words: &[&str], origin: Origin, authorized: bool, terminal: bool) -> String {
        match decide(&parse(words), origin, authorized, terminal) {
            Route::Fail(error) => error.code.to_owned(),
            other => format!("{other:?}"),
        }
    }

    #[test]
    fn unauthorized_connections_reach_only_the_open_commands() {
        use Origin::{Local, Network};
        assert_eq!(route(&["help"], Network, false, false), "Help");
        assert_eq!(route(&["group", "list", "--help"], Network, false, false), "Help");
        assert_eq!(route(&["session", "status"], Network, false, false), "Command { needs_auth: false }");
        assert_eq!(route(&["session", "open"], Network, false, false), "SessionOpen");
        assert_eq!(route(&["self", "version"], Local, false, false), "Command { needs_auth: false }");
        assert_eq!(route(&["self", "version"], Network, false, false), "session_closed");
        assert_eq!(route(&["daemon", "status"], Local, false, false), "Daemon");
        assert_eq!(route(&["daemon", "status"], Network, false, false), "session_closed");
        assert_eq!(route(&["daemon", "stop"], Local, false, false), "Daemon");
        for words in [&["group", "list"][..], &["node", "list"], &["source", "github-accounts"],
            &["source", "github-replace-with-local"], &["source", "init-local"], &["status"]]
        {
            assert_eq!(route(words, Local, false, false), "session_closed", "{words:?}");
        }
        assert_eq!(route(&["node", "shell", "--name", "n"], Local, false, true), "session_closed");
    }

    #[test]
    fn authorized_connections_queue_commands_that_the_core_rechecks() {
        use Origin::{Local, Network};
        assert_eq!(route(&["group", "list"], Local, true, false), "Command { needs_auth: true }");
        assert_eq!(route(&["session", "status"], Local, true, false), "Command { needs_auth: false }");
        assert_eq!(route(&["session", "open"], Local, true, false), "SessionOpen");
        assert_eq!(route(&["node", "shell", "--name", "n"], Local, true, true), "Terminal");
        assert_eq!(route(&["node", "shell", "--name", "n"], Local, true, false), "tty_required");
        assert_eq!(route(&["telegram", "menu", "--name", "n"], Network, true, false), "tty_required");
        assert_eq!(route(&["daemon", "stop"], Network, true, false), "local_only");
        assert_eq!(route(&["daemon", "run"], Local, true, false), "usage");
        assert_eq!(route(&["template", "export", "--name", "t", "--output", "o"], Local, true, false), "usage");
        // `web *`: answered by the daemon; only `web status` reaches the network.
        assert_eq!(route(&["web", "start", "--port", "0"], Local, false, false), "Web");
        assert_eq!(route(&["web", "link"], Local, false, false), "Web");
        assert_eq!(route(&["web", "status"], Network, true, false), "Web");
        assert_eq!(route(&["web", "status"], Network, false, false), "session_closed");
        assert_eq!(route(&["web", "stop"], Network, true, false), "local_only");
        assert_eq!(route(&["web", "run"], Local, true, false), "usage");
        assert_eq!(route(&["session", "open"], Network, false, false), "SessionOpen");
    }

    #[test]
    fn tty_required_names_the_menu_and_needs_authorization_first() {
        let Route::Fail(error) = decide(&parse(&["telegram", "menu", "--name", "n"]), Origin::Local, true, false) else { panic!() };
        assert_eq!(error.message, "Меню Telegram Proxy требует терминала.");
        let Route::Fail(error) = decide(&parse(&["node", "shell", "--name", "n"]), Origin::Local, false, false) else { panic!() };
        assert_eq!(error.code, "session_closed");
    }

    #[test]
    fn env_accepts_only_a_local_absolute_agent_socket() {
        let env = |text: &str| serde_json::from_str::<Value>(text).unwrap();
        assert_eq!(parse_env(None, Origin::Network), Ok(None));
        assert_eq!(parse_env(Some(&env("{}")), Origin::Local), Ok(None));
        let absolute = if cfg!(windows) { r#"{"SSH_AUTH_SOCK":"C:\\agent"}"# } else { r#"{"SSH_AUTH_SOCK":"/run/agent.sock"}"# };
        assert!(parse_env(Some(&env(absolute)), Origin::Local).unwrap().is_some());
        assert!(parse_env(Some(&env(absolute)), Origin::Network).is_err());
        assert!(parse_env(Some(&env(r#"{"SSH_AUTH_SOCK":"agent.sock"}"#)), Origin::Local).is_err());
        assert!(parse_env(Some(&env(r#"{"HOME":"/root"}"#)), Origin::Local).is_err());
        assert!(parse_env(Some(&env(r#"{"SSH_AUTH_SOCK":1}"#)), Origin::Local).is_err());
        let long = format!(r#"{{"SSH_AUTH_SOCK":"/{}"}}"#, "a".repeat(MAX_AGENT_PATH));
        assert!(parse_env(Some(&env(&long)), Origin::Local).is_err());
    }

    #[test]
    fn terminal_field_is_a_sane_console_description() {
        let value = |text: &str| serde_json::from_str::<Value>(text).unwrap();
        let pty = parse_terminal(Some(&value(r#"{"term":"xterm-256color","cols":80,"rows":24}"#))).unwrap().unwrap();
        assert_eq!(pty, PtyRequest { term: "xterm-256color".into(), size: ConsoleSize { cols: 80, rows: 24 } });
        assert_eq!(parse_terminal(None), Ok(None));
        for bad in [r#"{"term":"","cols":80,"rows":24}"#, r#"{"term":"a b","cols":80,"rows":24}"#,
            r#"{"term":"xterm","cols":0,"rows":24}"#, r#"{"term":"xterm","cols":70000,"rows":24}"#, r#""xterm""#]
        {
            assert!(parse_terminal(Some(&value(bad))).is_err(), "{bad}");
        }
    }

    #[test]
    fn ids_are_scalars_without_nul() {
        assert!(valid_id(&Value::Null));
        assert!(valid_id(&serde_json::json!(7)));
        assert!(valid_id(&serde_json::json!("a")));
        assert!(!valid_id(&serde_json::json!("a\u{0}")));
        assert!(!valid_id(&serde_json::json!([1])));
        assert!(!valid_id(&serde_json::json!({"a":1})));
    }

    #[test]
    fn failure_replies_carry_the_exit_status() {
        let (out, mut lines) = mpsc::unbounded_channel();
        let conn = Conn::new(1, Origin::Local, out);
        assert!(conn.begin(&serde_json::json!(5)));
        assert!(!conn.begin(&serde_json::json!(5)));
        conn.fail(&serde_json::json!(5), session_closed());
        let Some(Out::Line(text, None)) = lines.try_recv().ok() else { panic!() };
        assert_eq!(text.as_str(), "{\"id\":5,\"ok\":false,\"error\":{\"code\":\"session_closed\",\"message\":\"Сначала откройте сессию: session open.\"},\"exit\":1}\n");
        assert!(conn.begin(&serde_json::json!(5)), "the reply ends the request");
        conn.reply(&serde_json::json!("x"), Envelope::success(serde_json::json!({"a":1})));
        let Some(Out::Line(text, None)) = lines.try_recv().ok() else { panic!() };
        assert_eq!(text.as_str(), "{\"id\":\"x\",\"ok\":true,\"data\":{\"a\":1}}\n");
    }

    #[test]
    fn rejections_do_not_free_a_running_id() {
        let (out, mut lines) = mpsc::unbounded_channel();
        let conn = Conn::new(1, Origin::Local, out);
        assert!(conn.begin(&serde_json::json!(5)));
        // A malformed message with the running id answers but ends nothing.
        conn.reject(&serde_json::json!(5), RcError::new("usage", "Запрос с таким id уже выполняется."));
        let Some(Out::Line(text, None)) = lines.try_recv().ok() else { panic!() };
        assert_eq!(text.as_str(), "{\"id\":5,\"ok\":false,\"error\":{\"code\":\"usage\",\"message\":\"Запрос с таким id уже выполняется.\"},\"exit\":2}\n");
        assert!(!conn.begin(&serde_json::json!(5)), "the original request still owns the id");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn unauthorized_network_connections_keep_four_requests_in_flight() {
        // The core never takes the jobs: every queued request stays in flight.
        let (shared, _jobs) = super::super::tests::shared();
        let (out, mut lines) = mpsc::unbounded_channel();
        let conn = shared.register(Origin::Network, out);
        for i in 0..5 {
            let line = format!(r#"{{"id":{i},"argv":["session","status"]}}"#);
            handle_line(&shared, &conn, line.as_bytes()).await;
        }
        let Ok(Out::Line(text, None)) = lines.try_recv() else { panic!("the fifth request is refused") };
        let reply: Value = serde_json::from_str(&text).unwrap();
        assert_eq!((reply["id"].clone(), reply["error"]["code"].clone()), (serde_json::json!(4), serde_json::json!("usage")));
        assert_eq!(reply["error"]["message"], "Слишком много одновременных запросов.");
        assert!(lines.try_recv().is_err());
        // Authorized: up to 32.
        conn.set_authorized(true);
        for i in 5..33 {
            let line = format!(r#"{{"id":{i},"argv":["session","status"]}}"#);
            handle_line(&shared, &conn, line.as_bytes()).await;
        }
        assert!(lines.try_recv().is_err(), "28 more fit: 32 in flight");
        handle_line(&shared, &conn, br#"{"id":33,"argv":["session","status"]}"#).await;
        let Ok(Out::Line(text, None)) = lines.try_recv() else { panic!("the 33rd request is refused") };
        assert!(text.contains("Слишком много одновременных запросов."), "{}", text.as_str());
    }

    #[test]
    fn a_closed_connection_sends_nothing() {
        let (out, mut lines) = mpsc::unbounded_channel();
        let conn = Conn::new(1, Origin::Local, out);
        conn.mark_closed();
        conn.log(&Value::Null, Level::Info, "x");
        assert!(lines.try_recv().is_err());
    }

    fn shared() -> Arc<Shared> {
        super::super::tests::shared().0
    }

    /// The flag of a network `session open` is cleared before its reply is
    /// queued: a client that answers the reply with the next `session open`
    /// is never refused as a duplicate. Nothing else clears it here (no
    /// `network_open` task), so the check is deterministic.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_network_open_frees_its_slot_before_the_reply() {
        let (shared, jobs) = super::super::tests::shared();
        let data = tempfile::tempdir().unwrap();
        let snapshot = tokio::sync::watch::channel(super::super::core::CoreSnapshot::default()).0;
        let paths = rc_core::state::StatePaths::new(data.path());
        let core = super::super::core::spawn(shared.clone(), paths, jobs, snapshot, tokio::runtime::Handle::current()).unwrap();
        let (out, mut lines) = mpsc::unbounded_channel();
        let conn = shared.register(Origin::Network, out);
        conn.opening.store(true, Ordering::SeqCst);
        let (done, _outcome) = oneshot::channel::<OpenOutcome>();
        let request = Request {
            conn: conn.clone(), id: serde_json::json!(1), label: "session open".into(), argv: vec!["session".into(), "open".into()],
            secrets: Secrets::default(), input: Input::default(), agent: None, needs_auth: false,
        };
        assert!(shared.enqueue(Job::SessionOpen(request, Some(done))));
        let reply = loop {
            let Some(Out::Line(text, None)) = lines.recv().await else { panic!("the connection stays open") };
            if text.contains(r#""id":1"#) && text.contains(r#""ok""#) {
                break text;
            }
        };
        assert!(!conn.opening.load(Ordering::SeqCst), "the slot is free when the reply is out: {}", reply.as_str());
        shared.begin_stop(None);
        tokio::task::spawn_blocking(move || core.join().unwrap()).await.unwrap();
    }

    /// Reads nothing, accepts no writes.
    struct BrokenPipe;

    impl AsyncRead for BrokenPipe {
        fn poll_read(self: std::pin::Pin<&mut Self>, _: &mut std::task::Context<'_>, _: &mut tokio::io::ReadBuf<'_>)
            -> std::task::Poll<io::Result<()>>
        {
            std::task::Poll::Pending
        }
    }

    impl AsyncWrite for BrokenPipe {
        fn poll_write(self: std::pin::Pin<&mut Self>, _: &mut std::task::Context<'_>, _: &[u8]) -> std::task::Poll<io::Result<usize>> {
            std::task::Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()))
        }
        fn poll_flush(self: std::pin::Pin<&mut Self>, _: &mut std::task::Context<'_>) -> std::task::Poll<io::Result<()>> {
            std::task::Poll::Ready(Ok(()))
        }
        fn poll_shutdown(self: std::pin::Pin<&mut Self>, _: &mut std::task::Context<'_>) -> std::task::Poll<io::Result<()>> {
            std::task::Poll::Ready(Ok(()))
        }
    }

    async fn served(shared: &Arc<Shared>, task: tokio::task::JoinHandle<()>) {
        tokio::time::timeout(std::time::Duration::from_secs(5), task).await.expect("the connection ends").unwrap();
        assert!(shared.connections().is_empty(), "the connection is unregistered");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_failed_write_ends_the_reader_too() {
        let shared = shared();
        let (out, outgoing) = mpsc::unbounded_channel();
        let conn = shared.register(Origin::Local, out);
        let task = tokio::spawn(serve(shared.clone(), conn.clone(), outgoing, BrokenPipe));
        served(&shared, task).await;
        assert!(conn.is_closed());
    }

    /// The WebSocket writer obeys the same limit: a browser that stopped
    /// reading is disconnected, the reader ends with it.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_network_watcher_that_stops_reading_is_disconnected() {
        let shared = shared();
        let (out, outgoing) = mpsc::unbounded_channel();
        let conn = shared.register(Origin::Network, out);
        let (_to_daemon, incoming) = mpsc::channel(1);
        let (sink, _unread) = mpsc::channel(1);
        let socket = essence_rc_web::Accepted { peer: "127.0.0.1:1".parse().unwrap(), incoming, outgoing: sink };
        let listener = ListenerHello { loopback: true, tls: false };
        let task = tokio::spawn(serve_network(shared.clone(), conn.clone(), outgoing, socket, listener));
        conn.set_authorized(true);
        conn.watch.store(true, Ordering::SeqCst);
        let text = "x".repeat(1 << 20);
        for _ in 0..(MAX_QUEUED >> 20) + 2 {
            shared.activity(&serde_json::json!({"event": "activity", "state": "log", "level": "info", "text": text}));
        }
        assert!(conn.is_closed(), "the queue limit closes the connection");
        served(&shared, task).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_watcher_that_stops_reading_is_disconnected_not_buffered() {
        let shared = shared();
        let (out, outgoing) = mpsc::unbounded_channel();
        let conn = shared.register(Origin::Local, out);
        let (_client, server) = tokio::io::duplex(1024);
        let task = tokio::spawn(serve(shared.clone(), conn.clone(), outgoing, server));
        conn.watch.store(true, Ordering::SeqCst);
        let text = "x".repeat(1 << 20);
        for _ in 0..(MAX_QUEUED >> 20) + 2 {
            shared.activity(&serde_json::json!({"event": "activity", "state": "log", "level": "info", "text": text}));
        }
        assert!(conn.is_closed(), "the queue limit closes the connection");
        assert!(conn.queued.load(Ordering::SeqCst) <= MAX_QUEUED + text.len() + 128);
        served(&shared, task).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_full_terminal_input_closes_the_terminal_without_blocking_the_reader() {
        let shared = shared();
        let (out, mut lines) = mpsc::unbounded_channel();
        let conn = shared.register(Origin::Local, out);
        let id = serde_json::json!("t");
        let (input, mut receiver) = conn.terminal_channel(&id);
        conn.link_terminal(&id, input);
        let message = format!(r#"{{"id":"t","stdin":"{}"}}"#, STANDARD.encode("k"));
        for _ in 0..=terminal::INPUT_QUEUE {
            tokio::time::timeout(std::time::Duration::from_secs(1), handle_line(&shared, &conn, message.as_bytes()))
                .await.expect("the reader never waits for the terminal");
        }
        assert!(conn.terminal_input(&id).is_none(), "the overflowing terminal is unlinked");
        let Ok(Out::Line(text, None)) = lines.try_recv() else { panic!("the requester learns why") };
        assert!(text.contains(r#""level":"error""#) && text.contains("терминал закрыт"), "{}", text.as_str());
        let mut queued = 0;
        while let Some(event) = receiver.recv().await {
            assert!(matches!(event, ConsoleEvent::Input(_)));
            queued += 1;
        }
        assert_eq!(queued, terminal::INPUT_QUEUE, "queued input is kept, then the session reads EOF");
    }

    /// A few large `stdin` messages to a terminal that is not reading yet:
    /// the byte budget closes it long before the event count would.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn terminal_input_is_bounded_by_bytes() {
        let shared = shared();
        let (out, mut lines) = mpsc::unbounded_channel();
        let conn = shared.register(Origin::Local, out);
        let id = serde_json::json!("t");
        let (input, mut receiver) = conn.terminal_channel(&id);
        conn.link_terminal(&id, input);
        let chunk = 1 << 20;
        let message = format!(r#"{{"id":"t","stdin":"{}"}}"#, STANDARD.encode(vec![b'k'; chunk]));
        for sent in 1..=terminal::INPUT_LIMIT / chunk {
            handle_line(&shared, &conn, message.as_bytes()).await;
            assert!(conn.terminal_input(&id).is_some(), "{sent} MiB fit");
            assert_eq!(receiver.queued_bytes(), sent * chunk);
        }
        handle_line(&shared, &conn, message.as_bytes()).await;
        assert!(conn.terminal_input(&id).is_none(), "one byte over the budget closes the terminal");
        let Ok(Out::Line(text, None)) = lines.try_recv() else { panic!("the requester learns why") };
        assert!(text.contains("терминал закрыт"), "{}", text.as_str());
        let mut delivered = 0;
        while let Some(ConsoleEvent::Input(data)) = receiver.recv().await {
            delivered += data.len();
        }
        assert_eq!((delivered, receiver.queued_bytes()), (terminal::INPUT_LIMIT, 0), "reading releases the budget");
    }

    /// `close` before the terminal opened unlinks its input, so the launch
    /// sees it closed; a later terminal that reuses the id gets a new key.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn close_before_open_closes_the_input_and_ids_get_fresh_keys() {
        let shared = shared();
        let conn = shared.register(Origin::Local, mpsc::unbounded_channel().0);
        let id = serde_json::json!("t");
        let (input, mut receiver) = conn.terminal_channel(&id);
        let first = input.key.clone();
        conn.link_terminal(&id, input);
        handle_line(&shared, &conn, br#"{"id":"t","close":true}"#).await;
        assert!(conn.terminal_input(&id).is_none());
        assert!(receiver.is_closed(), "launch refuses a terminal closed before it opened");
        assert!(matches!(receiver.recv().await, Some(ConsoleEvent::Closed)));
        assert!(receiver.recv().await.is_none());
        assert_ne!(conn.terminal_channel(&id).0.key, first, "a reused id names another terminal");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn daemon_commands_get_the_core_whitelist() {
        let shared = shared();
        let (out, mut lines) = mpsc::unbounded_channel();
        let conn = shared.register(Origin::Local, out);
        for message in [r#"{"id":1,"argv":["daemon","stop","--secrets-stdin"]}"#,
            r#"{"id":2,"argv":["daemon","stop"],"secrets":{"password":"x"}}"#,
            r#"{"id":3,"argv":["daemon","status"],"input":{"file":"x"}}"#]
        {
            handle_line(&shared, &conn, message.as_bytes()).await;
            let Ok(Out::Line(text, None)) = lines.try_recv() else { panic!("one reply") };
            let reply: Value = serde_json::from_str(&text).unwrap();
            assert_eq!((reply["ok"].as_bool(), reply["error"]["code"].as_str()), (Some(false), Some("usage")), "{message}");
        }
        assert!(!shared.is_stopping(), "a rejected stop stops nothing");
    }
}
