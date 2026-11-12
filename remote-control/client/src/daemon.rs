//! [`DaemonClient`]: protocol v3 over the local socket (or test channels).
use std::{io, path::{Path, PathBuf}, process::Child, sync::mpsc::{self, Receiver, RecvTimeoutError, Sender},
    thread::JoinHandle, time::{Duration, Instant}};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Serialize;
use serde_json::Value;
use tokio::{io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt}, sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel}};
use zeroize::Zeroizing;
use crate::{client::{Client, Progress, Request, TermEvent, TerminalIo, argv},
    endpoint::Endpoint,
    protocol::{Hello, Input, Log, MAX_MESSAGE, PROTOCOL, Reply, Secrets, TICK, TerminalMessage, TerminalSpec, WindowSize, WireRequest},
    spawn::{SpawnDaemon, journal_tail}};

/// How long `connect_local` keeps retrying while a daemon starts or stops.
const CONNECT_WAIT: Duration = Duration::from_secs(60);
const CONNECT_RETRY: Duration = Duration::from_millis(50);
/// How long a stopped idle daemon of another version may take to disconnect.
const STOP_WAIT: Duration = Duration::from_secs(30);
const READ_CHUNK: usize = 64 << 10;
/// How long `close()` waits for the I/O thread before detaching it.
const CLOSE_WAIT: Duration = Duration::from_secs(2);

/// Everything the request loop waits for arrives through one channel.
pub(crate) enum Incoming { Line(Zeroizing<String>), Term(TermEvent), Closed(io::Error) }

pub(crate) enum Outgoing { Socket(UnboundedSender<Zeroizing<String>>), Channel(Sender<Zeroizing<String>>) }
impl Outgoing {
    fn send(&self, line: Zeroizing<String>) -> io::Result<()> {
        match self {
            Self::Socket(sender) => sender.send(line).map_err(|_| core_exited()),
            Self::Channel(sender) => sender.send(line).map_err(|_| core_exited()),
        }
    }
}

/// Parameters of `connect_local`, kept for reconnection after `daemon_stopping`.
struct Reconnect { endpoint: Endpoint, spawn: Option<SpawnDaemon>, expected_version: Option<String>, expected_exe: Option<PathBuf> }
impl Reconnect {
    fn matches(&self, hello: &Hello) -> bool {
        self.expected_version.as_deref().is_none_or(|version| version == hello.version)
            && self.expected_exe.as_deref().is_none_or(|exe| hello.exe.as_deref() == Some(exe))
    }
}

pub struct DaemonClient {
    incoming: Receiver<Incoming>,
    /// Feeds terminal events into `incoming`.
    events: Sender<Incoming>,
    outgoing: Option<Outgoing>,
    io_thread: Option<JoinHandle<()>>,
    hello: Hello,
    next_id: u64,
    /// The connection ended; every further request fails at once.
    dead: bool,
    reconnect: Option<Reconnect>,
}

pub(crate) fn protocol(message: &str) -> io::Error { io::Error::new(io::ErrorKind::InvalidData, message) }
fn core_exited() -> io::Error { io::Error::new(io::ErrorKind::UnexpectedEof, "Ядро remote-control завершилось.") }
fn connection_closed() -> io::Error { io::Error::new(io::ErrorKind::BrokenPipe, "Соединение с демоном закрыто.") }
fn other_version(version: &str) -> io::Error {
    io::Error::other(format!("Запущен демон другой версии ({version}). Остановите его: essence-rc daemon stop."))
}
fn busy_other_version(version: &str) -> io::Error {
    io::Error::other(format!("Запущен демон другой версии ({version}) с активными клиентами. Остановите его: essence-rc daemon stop."))
}
/// The message plus the last lines of the daemon journal.
fn with_journal(endpoint: &Endpoint, message: &str) -> io::Error {
    let tail = journal_tail(endpoint);
    io::Error::other(if tail.is_empty() { message.to_owned() } else { format!("{message}\n{tail}") })
}
fn start_failed(endpoint: &Endpoint) -> io::Error { with_journal(endpoint, "Не удалось запустить демон essence-rc.") }
fn not_responding(endpoint: &Endpoint) -> io::Error { with_journal(endpoint, "Демон essence-rc не отвечает.") }

/// Counts serialized bytes so the wire buffer is allocated once at its final size.
struct ByteCount(usize);
impl io::Write for ByteCount {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> { self.0 += data.len(); Ok(data.len()) }
    fn flush(&mut self) -> io::Result<()> { Ok(()) }
}

/// JSON of a message (possibly with secrets) without any unzeroized
/// intermediate copy: exact-size buffer, then moved into the string.
fn serialize_zeroizing(message: &impl Serialize) -> io::Result<Zeroizing<String>> {
    let mut count = ByteCount(0);
    serde_json::to_writer(&mut count, message).map_err(io::Error::other)?;
    let mut buffer = Zeroizing::new(Vec::with_capacity(count.0));
    serde_json::to_writer(&mut *buffer, message).map_err(io::Error::other)?;
    debug_assert_eq!(buffer.len(), count.0, "serialization is deterministic");
    let bytes = std::mem::take(&mut *buffer);
    match String::from_utf8(bytes) {
        Ok(text) => Ok(Zeroizing::new(text)),
        Err(error) => { drop(Zeroizing::new(error.into_bytes())); Err(io::Error::other("JSON не в UTF-8")) }
    }
}

/// `hello` with another protocol number: the payload of the `InvalidData`
/// error, so a remote connection can report it as such.
#[derive(Debug)]
pub(crate) struct ProtocolMismatch(pub Value);
impl std::fmt::Display for ProtocolMismatch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { write!(f, "Несовместимый протокол демона: {}.", self.0) }
}
impl std::error::Error for ProtocolMismatch {}

/// `hello` must be the first message: protocol 3 with a version and an origin.
fn parse_hello(line: &str) -> io::Result<Hello> {
    let value: Value = serde_json::from_str(line).map_err(|_| protocol("Некорректный ответ демона"))?;
    if value["event"] != "hello" { return Err(protocol("Демон не прислал приветствие")); }
    if value["protocol"] != PROTOCOL {
        return Err(io::Error::new(io::ErrorKind::InvalidData, ProtocolMismatch(value["protocol"].clone())));
    }
    serde_json::from_value(value).map_err(|_| protocol("Некорректное приветствие демона"))
}

/// Socket reader and writer of one connection. Every read byte stays in
/// zeroized buffers; a line becomes `Incoming::Line`. Ends at EOF, on a read
/// error, when the client is gone or when the outgoing channel closes. After
/// a write error it keeps reading to EOF, so a reply already sent is not lost.
async fn pump<S: AsyncRead + AsyncWrite>(stream: S, mut outgoing: UnboundedReceiver<Zeroizing<String>>, incoming: Sender<Incoming>) {
    let (mut reader, mut writer) = tokio::io::split(stream);
    let mut pending = Zeroizing::new(Vec::<u8>::with_capacity(READ_CHUNK));
    let mut chunk = Zeroizing::new(vec![0u8; READ_CHUNK]);
    let mut broken = false;
    loop {
        tokio::select! {
            read = reader.read(&mut chunk[..]) => {
                let n = match read { Ok(0) | Err(_) => { let _ = incoming.send(Incoming::Closed(core_exited())); return; } Ok(n) => n };
                if pending.len() + n > pending.capacity() {
                    // Grow into a fresh buffer so no stale copy is left behind unzeroized.
                    let mut grown = Zeroizing::new(Vec::with_capacity((pending.capacity() * 2).max(pending.len() + n)));
                    grown.extend_from_slice(&pending);
                    pending = grown;
                }
                pending.extend_from_slice(&chunk[..n]);
                while let Some(end) = pending.iter().position(|&b| b == b'\n') {
                    let line = match std::str::from_utf8(&pending[..end]) {
                        Ok(text) => Zeroizing::new(text.to_owned()),
                        Err(_) => { let _ = incoming.send(Incoming::Closed(protocol("Некорректный ответ демона"))); return; }
                    };
                    pending.drain(..=end);
                    if incoming.send(Incoming::Line(line)).is_err() { return; }
                }
                if pending.len() > MAX_MESSAGE {
                    let _ = incoming.send(Incoming::Closed(protocol("Сообщение демона превышает 4 МиБ")));
                    return;
                }
            }
            message = outgoing.recv() => match message {
                // A broken write side drops further messages; reading continues.
                Some(_) if broken => {}
                Some(line) => {
                    let written = async { writer.write_all(line.as_bytes()).await?; writer.write_all(b"\n").await?; writer.flush().await }.await;
                    broken = written.is_err();
                }
                None => { let _ = writer.shutdown().await; return; }
            },
        }
    }
}

/// Unix: the peer must run under our effective uid (`SO_PEERCRED`/`getpeereid`).
#[cfg(unix)]
fn verify_server(stream: &tokio::net::UnixStream) -> io::Result<()> {
    // SAFETY: geteuid has no preconditions and cannot fail.
    let uid = unsafe { libc::geteuid() };
    if stream.peer_cred()?.uid() != uid {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "Сокет демона принадлежит другому пользователю."));
    }
    Ok(())
}

/// Windows: the pipe server process must run under our user SID.
#[cfg(windows)]
fn verify_server(pipe: &tokio::net::windows::named_pipe::NamedPipeClient) -> io::Result<()> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::{Foundation::{CloseHandle, HANDLE}, Security::EqualSid, System::{Pipes::GetNamedPipeServerProcessId,
        Threading::{GetCurrentProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION}}};
    let foreign = || io::Error::new(io::ErrorKind::PermissionDenied, "Канал демона принадлежит другому пользователю.");
    let mut pid = 0u32;
    // SAFETY: the handle is a live pipe owned by `pipe`; `pid` is a valid out pointer.
    if unsafe { GetNamedPipeServerProcessId(pipe.as_raw_handle() as HANDLE, &mut pid) } == 0 { return Err(io::Error::last_os_error()); }
    // SAFETY: OpenProcess has no memory preconditions; a null result is handled.
    let server = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if server.is_null() { return Err(foreign()); }
    let theirs = token_user(server);
    // SAFETY: `server` was opened above and is closed exactly once.
    unsafe { CloseHandle(server); }
    let theirs = theirs.map_err(|_| foreign())?;
    // SAFETY: the pseudo handle of the current process needs no closing.
    let ours = token_user(unsafe { GetCurrentProcess() })?;
    // SAFETY: both buffers hold a TOKEN_USER filled by GetTokenInformation.
    if unsafe { EqualSid(sid(&theirs), sid(&ours)) } == 0 { return Err(foreign()); }
    Ok(())
}

/// The `TOKEN_USER` of a process, in a pointer-aligned buffer.
#[cfg(windows)]
fn token_user(process: windows_sys::Win32::Foundation::HANDLE) -> io::Result<Vec<usize>> {
    use windows_sys::Win32::{Foundation::{CloseHandle, HANDLE}, Security::{GetTokenInformation, TOKEN_QUERY, TokenUser},
        System::Threading::OpenProcessToken};
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: `token` is a valid out pointer.
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 { return Err(io::Error::last_os_error()); }
    let mut length = 0u32;
    // SAFETY: a size query with a null buffer; `length` is a valid out pointer.
    unsafe { GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut length); }
    let mut buffer = vec![0usize; (length as usize).div_ceil(size_of::<usize>()).max(1)];
    // SAFETY: the buffer holds at least `length` bytes and is pointer-aligned.
    let ok = unsafe { GetTokenInformation(token, TokenUser, buffer.as_mut_ptr().cast(), length, &mut length) };
    let error = io::Error::last_os_error();
    // SAFETY: `token` was opened above and is closed exactly once.
    unsafe { CloseHandle(token); }
    if ok == 0 { return Err(error); }
    Ok(buffer)
}

#[cfg(windows)]
fn sid(token_user: &[usize]) -> windows_sys::Win32::Security::PSID {
    // SAFETY: the buffer was filled with a TOKEN_USER by `token_user`.
    unsafe { (*token_user.as_ptr().cast::<windows_sys::Win32::Security::TOKEN_USER>()).User.Sid }
}

#[cfg(windows)]
fn pipe_busy(error: &io::Error) -> bool {
    error.raw_os_error() == Some(windows_sys::Win32::Foundation::ERROR_PIPE_BUSY as i32)
}
#[cfg(unix)]
fn pipe_busy(_: &io::Error) -> bool { false }

/// Unix: the daemon holds `<h>.lock` while it lives. The probe takes a shared
/// non-blocking `flock` and releases it at once (closing the file).
#[cfg(unix)]
fn daemon_alive(endpoint: &Endpoint) -> bool {
    use std::os::{fd::AsRawFd, unix::fs::OpenOptionsExt};
    let Ok(file) = std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(&endpoint.lock) else { return false };
    // SAFETY: the descriptor is owned by `file` for the whole call.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } == 0 { return false; }
    io::Error::last_os_error().raw_os_error() == Some(libc::EWOULDBLOCK)
}
/// Windows: a missing pipe means no daemon; a starting daemon of another
/// client exits by itself (first pipe instance).
#[cfg(windows)]
fn daemon_alive(_: &Endpoint) -> bool { false }

/// A spawned daemon process; reaped in the background once it is ours no more.
struct Spawned(Option<Child>);
impl Spawned {
    /// `Some(success)` once the process has exited.
    fn exited(&mut self) -> io::Result<Option<bool>> {
        let Some(child) = self.0.as_mut() else { return Ok(None) };
        let status = child.try_wait()?;
        if status.is_some() { self.0 = None; }
        Ok(status.map(|status| status.success()))
    }
    fn running(&self) -> bool { self.0.is_some() }
}
impl Drop for Spawned {
    fn drop(&mut self) {
        // Unix: reap the daemon in the background so it never stays a zombie.
        #[cfg(unix)]
        if let Some(mut child) = self.0.take() { std::thread::spawn(move || { let _ = child.wait(); }); }
    }
}

impl DaemonClient {
    /// Connects to the local daemon of `endpoint`, starting it with `spawn`
    /// when none is listening (and its lock is free). A daemon of another
    /// version or executable is restarted only when it is idle and on demand.
    pub fn connect_local(endpoint: &Endpoint, spawn: Option<&SpawnDaemon>, expected_version: Option<&str>, expected_exe: Option<&Path>) -> io::Result<Self> {
        Self::connect_with(Reconnect {
            endpoint: endpoint.clone(),
            spawn: spawn.cloned(),
            expected_version: expected_version.map(str::to_owned),
            expected_exe: expected_exe.map(|exe| std::fs::canonicalize(exe).unwrap_or_else(|_| exe.to_owned())),
        })
    }

    /// Test transport: `incoming` yields daemon lines (the first is `hello`),
    /// `outgoing` receives client lines; closing `incoming` is a daemon exit.
    pub fn from_channels(incoming: Receiver<Zeroizing<String>>, outgoing: Sender<Zeroizing<String>>) -> io::Result<Self> {
        let (events, receiver) = mpsc::channel();
        let forward = events.clone();
        std::thread::spawn(move || {
            for line in incoming { if forward.send(Incoming::Line(line)).is_err() { return; } }
            let _ = forward.send(Incoming::Closed(core_exited()));
        });
        Self::start(receiver, events, Outgoing::Channel(outgoing), None, None)
    }

    /// Waits for `hello` (until `deadline`, if any; then `TimedOut`).
    pub(crate) fn start(incoming: Receiver<Incoming>, events: Sender<Incoming>, outgoing: Outgoing, io_thread: Option<JoinHandle<()>>, deadline: Option<Instant>) -> io::Result<Self> {
        let hello = loop {
            let message = match deadline {
                None => incoming.recv().map_err(|_| core_exited())?,
                Some(deadline) => match incoming.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                    Ok(message) => message,
                    Err(RecvTimeoutError::Timeout) => return Err(io::Error::new(io::ErrorKind::TimedOut, "Демон essence-rc не отвечает.")),
                    Err(RecvTimeoutError::Disconnected) => return Err(core_exited()),
                },
            };
            match message {
                Incoming::Line(line) => break parse_hello(&line)?,
                Incoming::Closed(error) => return Err(error),
                Incoming::Term(_) => {}
            }
        };
        Ok(Self { incoming, events, outgoing: Some(outgoing), io_thread, hello, next_id: 0, dead: false, reconnect: None })
    }

    fn connect_with(config: Reconnect) -> io::Result<Self> {
        let mut restarted = false;
        loop {
            let mut client = Self::establish(&config.endpoint, config.spawn.as_ref())?;
            if config.matches(&client.hello) {
                client.reconnect = Some(config);
                return Ok(client);
            }
            let version = client.hello.version.clone();
            if restarted || config.spawn.is_none() { return Err(other_version(&version)); }
            client.stop_idle(&version)?;
            restarted = true;
        }
    }

    /// Connect, retrying every 50 ms up to 60 s while a daemon is starting or
    /// stopping; start one only when nothing listens and the lock is free.
    fn establish(endpoint: &Endpoint, spawn: Option<&SpawnDaemon>) -> io::Result<Self> {
        let deadline = Instant::now() + CONNECT_WAIT;
        let mut spawned = Spawned(None);
        let mut ever_spawned = false;
        loop {
            let error = match Self::connect_once(endpoint, deadline) { Ok(client) => return Ok(client), Err(error) => error };
            if error.kind() == io::ErrorKind::TimedOut { return Err(not_responding(endpoint)); }
            let absent = matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused);
            let transient = matches!(error.kind(), io::ErrorKind::UnexpectedEof | io::ErrorKind::ConnectionReset) || pipe_busy(&error);
            if !absent && !transient { return Err(error); }
            if spawned.exited()? == Some(false) { return Err(start_failed(endpoint)); }
            if absent && !spawned.running() && !daemon_alive(endpoint) {
                let Some(spawn) = spawn else { return Err(error) };
                // `Other`, never `PermissionDenied`: a spawn failure is not `unsafe_path`.
                spawned.0 = Some(spawn.spawn(endpoint).map_err(|error| io::Error::other(format!("Не удалось запустить демон essence-rc: {error}")))?);
                ever_spawned = true;
            }
            if Instant::now() >= deadline { return Err(if ever_spawned { start_failed(endpoint) } else { not_responding(endpoint) }); }
            std::thread::sleep(CONNECT_RETRY);
        }
    }

    /// One attempt: check the runtime directory, connect, check the server
    /// owner (nothing is sent to a foreign peer), read `hello` by `deadline`.
    fn connect_once(endpoint: &Endpoint, deadline: Instant) -> io::Result<Self> {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
        #[cfg(unix)]
        let stream = {
            crate::endpoint::verify_runtime_dir(&endpoint.runtime_dir)?;
            let stream = runtime.block_on(tokio::net::UnixStream::connect(&endpoint.socket))?;
            verify_server(&stream)?;
            stream
        };
        #[cfg(windows)]
        let stream = {
            let pipe = {
                let _context = runtime.enter();
                tokio::net::windows::named_pipe::ClientOptions::new().open(&endpoint.pipe)?
            };
            verify_server(&pipe)?;
            pipe
        };
        let (outgoing, outgoing_receiver) = unbounded_channel();
        let (events, incoming) = mpsc::channel();
        let forward = events.clone();
        let io_thread = std::thread::Builder::new().name("essence-rc-io".into())
            .spawn(move || runtime.block_on(pump(stream, outgoing_receiver, forward)))?;
        Self::start(incoming, events, Outgoing::Socket(outgoing), Some(io_thread), Some(deadline))
    }

    /// Another version answered: stop it if it is an idle on-demand daemon
    /// and wait for it to disconnect; refuse when it serves anyone else.
    fn stop_idle(mut self, version: &str) -> io::Result<()> {
        let (secrets, input) = (Secrets::default(), Input::default());
        let status_argv = argv(&["daemon", "status"]);
        let status = self.exchange(Request::new(&status_argv, &secrets, &input), None, &mut |_| {})?;
        let data = &status.data;
        let busy = !status.ok
            || data["persistent"].as_bool() != Some(false)
            || data["clients"].as_array().is_none_or(|clients| clients.len() > 1)
            || data["terminals"].as_array().is_none_or(|terminals| !terminals.is_empty());
        if busy { return Err(busy_other_version(version)); }
        let stop_argv = argv(&["daemon", "stop"]);
        let stop = self.exchange(Request::new(&stop_argv, &secrets, &input), None, &mut |_| {})?;
        if !stop.ok { return Err(other_version(version)); }
        let deadline = Instant::now() + STOP_WAIT;
        while let Some(left) = deadline.checked_duration_since(Instant::now()) {
            match self.incoming.recv_timeout(left) {
                Ok(Incoming::Closed(_)) | Err(_) => break,
                Ok(_) => {}
            }
        }
        Ok(())
    }

    fn send_message(&mut self, message: &impl Serialize) -> io::Result<()> {
        let line = serialize_zeroizing(message)?;
        let sent = self.outgoing.as_ref().ok_or_else(connection_closed)?.send(line);
        if sent.is_err() { self.dead = true; }
        sent
    }

    /// One request and its events up to the reply, with ticks while silent.
    fn exchange<'t>(&mut self, request: Request<'_>, mut io: Option<&mut (dyn TerminalIo + 't)>, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply> {
        if self.dead { return Err(core_exited()); }
        self.next_id = self.next_id.checked_add(1).ok_or_else(|| protocol("Исчерпаны id запросов"))?;
        let id = self.next_id;
        let terminal = io.as_deref().map(|io| { let (cols, rows) = io.size(); TerminalSpec { term: io.term(), cols, rows } });
        self.send_message(&WireRequest { id, argv: request.argv, secrets: request.secrets, input: request.input, env: request.env, terminal })?;
        let mut state = TerminalState { started: false, failure: None };
        let result = self.await_reply(id, io.as_deref_mut(), &mut state, progress);
        if state.started && let Some(io) = io { io.stop(); }
        // A protocol or connection error leaves the stream in an unknown state.
        if result.is_err() { self.dead = true; }
        let reply = result?;
        match state.failure { Some(error) => Err(error), None => Ok(reply) }
    }

    fn await_reply<'t>(&mut self, id: u64, mut io: Option<&mut (dyn TerminalIo + 't)>, state: &mut TerminalState, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply> {
        let mut logs = Vec::new();
        loop {
            let message = match self.incoming.recv_timeout(TICK) {
                Ok(message) => message,
                // A running terminal owns the screen: no redraw ticks.
                Err(RecvTimeoutError::Timeout) => { if !state.started { progress(Progress::Tick); } continue; }
                Err(RecvTimeoutError::Disconnected) => Incoming::Closed(core_exited()),
            };
            let line = match message {
                Incoming::Line(line) => line,
                Incoming::Closed(error) => { self.dead = true; return Err(error); }
                Incoming::Term(event) => {
                    if state.started && state.failure.is_none() { self.send_message(&terminal_message(id, event))?; }
                    continue;
                }
            };
            let value: Value = serde_json::from_str(&line).map_err(|_| protocol("Некорректный ответ демона"))?;
            // Messages without id (activity, …) belong to nobody's request.
            let Some(message_id) = value.get("id") else { continue };
            let ours = message_id.as_u64() == Some(id);
            match value.get("event").and_then(Value::as_str) {
                None if value.get("event").is_none() => {
                    if !value["ok"].is_boolean() { return Err(protocol("Некорректный ответ демона")); }
                    if !ours { return Err(protocol("Неверный id ответа демона")); }
                    let mut reply: Reply = serde_json::from_value(value).map_err(|_| protocol("Некорректный ответ демона"))?;
                    reply.logs = logs;
                    return Ok(reply);
                }
                _ if !ours => {}
                Some("log") => {
                    let entry: Log = serde_json::from_value(value).map_err(|_| protocol("Некорректное событие журнала"))?;
                    progress(Progress::Log(&entry));
                    logs.push(entry);
                }
                Some("terminal") if value["state"] == "open" => {
                    let Some(io) = io.as_deref_mut() else { continue };
                    if state.started || state.failure.is_some() { continue; }
                    let events = self.events.clone();
                    match io.start(Box::new(move |event| { let _ = events.send(Incoming::Term(event)); })) {
                        Ok(()) => state.started = true,
                        Err(error) => { state.failure = Some(error); self.send_message(&TerminalMessage::Close { id, close: true })?; }
                    }
                }
                Some("output") => {
                    let Some(io) = io.as_deref_mut() else { continue };
                    if !state.started || state.failure.is_some() { continue; }
                    let data = Zeroizing::new(value["data"].as_str().and_then(|data| STANDARD.decode(data).ok())
                        .ok_or_else(|| protocol("Некорректный вывод терминала"))?);
                    if let Err(error) = io.write(&data) {
                        state.failure = Some(error);
                        self.send_message(&TerminalMessage::Close { id, close: true })?;
                    }
                }
                _ => {}
            }
        }
    }

    /// `{"watch":true|false}`: subscribe to `activity` events of all clients.
    pub fn set_watch(&mut self, on: bool) -> io::Result<()> {
        if self.dead { return Err(core_exited()); }
        self.send_message(&serde_json::json!({"watch": on}))
    }

    /// The next message without `id` (an `activity` event) within `wait`;
    /// `Ok(None)` when nothing came. Stray request events are skipped; a closed
    /// connection is an error. Only between requests.
    pub fn next_event(&mut self, wait: Duration) -> io::Result<Option<Value>> {
        if self.dead { return Err(core_exited()); }
        let deadline = Instant::now() + wait;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let line = match self.incoming.recv_timeout(left) {
                Ok(Incoming::Line(line)) => line,
                Ok(Incoming::Term(_)) => continue,
                Ok(Incoming::Closed(error)) => { self.dead = true; return Err(error); }
                Err(RecvTimeoutError::Timeout) => return Ok(None),
                Err(RecvTimeoutError::Disconnected) => { self.dead = true; return Err(core_exited()); }
            };
            let value: Value = serde_json::from_str(&line).map_err(|_| protocol("Некорректный ответ демона"))?;
            if value.get("id").is_none() { return Ok(Some(value)); }
        }
    }

    /// `exchange`, repeated once on a fresh connection after `daemon_stopping`.
    fn request<'t>(&mut self, request: Request<'_>, mut io: Option<&mut (dyn TerminalIo + 't)>, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply> {
        let reply = self.exchange(request, io.as_deref_mut(), progress)?;
        if reply.code() != "daemon_stopping" { return Ok(reply); }
        let Some(config) = self.reconnect.take() else { return Ok(reply) };
        self.close()?;
        *self = Self::connect_with(config)?;
        self.exchange(request, io, progress)
    }
}

struct TerminalState { started: bool, failure: Option<io::Error> }

fn terminal_message(id: u64, event: TermEvent) -> TerminalMessage {
    match event {
        TermEvent::Input(data) => {
            let mut stdin = Zeroizing::new(String::with_capacity(base64::encoded_len(data.len(), true).unwrap_or(0)));
            STANDARD.encode_string(data.as_slice(), &mut stdin);
            TerminalMessage::Stdin { id, stdin }
        }
        TermEvent::Resize { cols, rows } => TerminalMessage::Resize { id, resize: WindowSize { cols, rows } },
        TermEvent::Closed => TerminalMessage::Close { id, close: true },
    }
}

impl Client for DaemonClient {
    fn hello(&self) -> &Hello { &self.hello }
    fn send(&mut self, request: Request<'_>, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply> { self.request(request, None, progress) }
    fn terminal(&mut self, request: Request<'_>, io: &mut dyn TerminalIo, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply> {
        self.request(request, Some(io), progress)
    }
    /// Only `connect_local` keeps an endpoint: WebSocket (`--connect`) and
    /// test channels answer `None`, so local path checks are skipped for them.
    fn local_data_dir(&self) -> Option<&Path> { self.reconnect.as_ref().map(|reconnect| reconnect.endpoint.data_dir.as_path()) }
    /// Ends the I/O thread; waits for it at most [`CLOSE_WAIT`], then detaches
    /// it, so a write stuck on a full socket cannot hang the caller.
    fn close(&mut self) -> io::Result<()> {
        self.outgoing.take();
        self.dead = true;
        if let Some(thread) = self.io_thread.take() {
            let deadline = Instant::now() + CLOSE_WAIT;
            while !thread.is_finished() && Instant::now() < deadline { std::thread::sleep(Duration::from_millis(5)); }
            if thread.is_finished() { let _ = thread.join(); }
        }
        Ok(())
    }
}

impl Drop for DaemonClient {
    /// Closing the outgoing channel ends the I/O thread; it is never joined
    /// here, so a stuck socket cannot hang shutdown.
    fn drop(&mut self) { self.outgoing.take(); }
}
