//! One client connection: protocol v3 messages in, events and replies out.
//!
//! Routing order of a request (П4): parse → `client_side` → `local_only` →
//! `help` → connection authorization → `daemon` → `requires_tty` →
//! `session open` → queued command. Only `help`, `session status`,
//! `session open` (and, locally, `self version`, `daemon *`) work before
//! the connection authorized itself with `session open`.

use std::collections::{HashMap, HashSet};
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use essence_rc_client::protocol::MAX_MESSAGE;
use essence_rc_client::{Origin, PROTOCOL, TerminalSpec, WindowSize};
use rc_core::cli::{self, Invocation};
use rc_core::dispatch::Envelope;
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
use tokio::sync::mpsc;
use zeroize::Zeroizing;

use super::core::{Job, Request, TerminalRequest};
use super::local::LineReader;
use super::terminal::{CLOSE_GRACE, Credit};
use super::{Shared, commands, lock};

/// Longest `SSH_AUTH_SOCK` path accepted in the request `env`.
const MAX_AGENT_PATH: usize = 4096;
/// Terminal input queued per terminal before the connection reader waits.
const TERMINAL_INPUT_QUEUE: usize = 64;

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
    out: mpsc::UnboundedSender<Out>,
    /// Requests of this connection not yet answered.
    in_flight: Mutex<HashSet<String>>,
    /// Console input of this connection's terminal requests.
    terminals: Mutex<HashMap<String, mpsc::Sender<ConsoleEvent>>>,
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
            out,
            in_flight: Mutex::default(),
            terminals: Mutex::default(),
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

    pub fn send(&self, value: &impl Serialize) {
        if !self.is_closed() {
            let _ = self.out.send(Out::Line(line(value), None));
        }
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

    pub fn link_terminal(&self, id: &Value, input: mpsc::Sender<ConsoleEvent>) {
        if !self.is_closed() {
            lock(&self.terminals).insert(key(id), input);
        }
    }

    pub fn unlink_terminal(&self, id: &Value) {
        lock(&self.terminals).remove(&key(id));
    }

    fn terminal_input(&self, id: &Value) -> Option<mpsc::Sender<ConsoleEvent>> {
        lock(&self.terminals).get(&key(id)).cloned()
    }

    pub fn close_output(&self) {
        let _ = self.out.send(Out::Close);
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
    if invocation.noun == "daemon" {
        return Route::Daemon;
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

#[derive(Serialize)]
struct Hello<'a> {
    event: &'static str,
    protocol: u32,
    version: &'static str,
    origin: Origin,
    exe: &'a std::path::Path,
    persistent: bool,
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
    conn.send(&Hello { event: "hello", protocol: PROTOCOL, version: VERSION, origin, exe: &shared.exe, persistent: shared.persistent });
    let writer = tokio::spawn(write_loop(writer, outgoing, conn.clone()));
    let mut lines = LineReader::new(reader, MAX_MESSAGE);
    while let Ok(Some(line)) = lines.next().await {
        handle_line(&shared, &conn, &line).await;
    }
    // A client that closed its side is gone: results are dropped.
    shared.disconnect(&conn);
    writer.abort();
}

async fn write_loop<W: AsyncWrite>(writer: W, mut outgoing: mpsc::UnboundedReceiver<Out>, conn: Arc<Conn>) {
    tokio::pin!(writer);
    while let Some(message) = outgoing.recv().await {
        match message {
            Out::Line(line, credit) => {
                let written = async { writer.write_all(line.as_bytes()).await?; writer.flush().await }.await;
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
        return terminal_message(shared, conn, &id, message).await;
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

async fn terminal_message(shared: &Arc<Shared>, conn: &Arc<Conn>, id: &Value, message: Message<'_>) {
    let Some(input) = conn.terminal_input(id) else { return };
    if let Some(data) = message.stdin {
        let mut bytes = Zeroizing::new(Vec::new());
        if STANDARD.decode_vec(data.as_bytes(), &mut bytes).is_ok() {
            let _ = input.send(ConsoleEvent::Input(std::mem::take(&mut *bytes))).await;
        }
    } else if let Some(resize) = message.resize {
        if let Ok(size) = serde_json::from_value::<WindowSize>(resize) {
            let _ = input.send(ConsoleEvent::Resize(ConsoleSize { cols: size.cols, rows: size.rows })).await;
        }
    } else if message.close == Some(Value::Bool(true)) {
        // The remote side gets EOF first; a session that ignores it is
        // cancelled after the grace period.
        let _ = input.send(ConsoleEvent::Closed).await;
        let (shared, conn_id, request) = (shared.clone(), conn.id, key(id));
        tokio::spawn(async move {
            tokio::time::sleep(CLOSE_GRACE).await;
            shared.terminals.cancel_request(conn_id, &request);
        });
    }
}

fn request(shared: &Arc<Shared>, conn: &Arc<Conn>, id: Value, message: Message<'_>) {
    let Some(argv) = parse_argv(message.argv.as_ref()) else { return conn.reject(&id, invalid_request()) };
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
    let invocation = match cli::parse(&argv) {
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
        Route::Terminal => {
            let reservation = match invocation.value("name") {
                Some(node) => match shared.terminals.reserve(node, conn.id, &key(&id)) {
                    Some(reservation) => Some(reservation),
                    None => {
                        let error = RcError::new("conflict", format!("Терминал ноды «{node}» уже открыт.")).with_extra("name", node);
                        return conn.fail(&id, error);
                    }
                },
                // The core answers for the missing --name.
                None => None,
            };
            let (sender, receiver) = mpsc::channel(TERMINAL_INPUT_QUEUE);
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
        Route::SessionOpen => {
            announce_wait(shared, conn, &id);
            if !shared.enqueue(Job::SessionOpen(job(false))) {
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

/// A request queued behind the executing one learns what it waits for.
fn announce_wait(shared: &Shared, conn: &Conn, id: &Value) {
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

    #[test]
    fn a_closed_connection_sends_nothing() {
        let (out, mut lines) = mpsc::unbounded_channel();
        let conn = Conn::new(1, Origin::Local, out);
        conn.mark_closed();
        conn.log(&Value::Null, Level::Info, "x");
        assert!(lines.try_recv().is_err());
    }
}
