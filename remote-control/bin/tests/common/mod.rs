//! Shared helpers of the process tests: an isolated runtime directory per
//! test, one-shot runs that wait for their on-demand daemon to exit, a raw
//! JSON-lines connection to the daemon and a `daemon run` child.
#![allow(dead_code)]

use std::{
    ffi::OsString,
    io::{self, Read},
    path::{Path, PathBuf},
    process::{Child, Command, Output, Stdio},
    sync::mpsc,
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use essence_rc_client::{Endpoint, endpoint_in};
use serde_json::{Value, json};

pub const BIN: &str = env!("CARGO_BIN_EXE_essence-rc");
/// How long a one-shot helper waits for its daemon to leave the endpoint.
pub const GONE_WAIT: Duration = Duration::from_secs(15);

/// `ESSENCE_RC_RUNTIME_DIR` of one test: owner-only, outside the data
/// directory and the cargo target, short enough for a socket path.
pub fn runtime_dir() -> tempfile::TempDir {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        tempfile::Builder::new().prefix("rc").permissions(std::fs::Permissions::from_mode(0o700))
            .tempdir_in("/tmp").expect("runtime directory")
    }
    #[cfg(not(unix))]
    { tempfile::Builder::new().prefix("rc").tempdir().expect("runtime directory") }
}

pub fn endpoint(runtime: &Path, data: &Path) -> Endpoint {
    endpoint_in(runtime, data).expect("endpoint")
}

/// The daemon listens: the socket file exists (Unix); the pipe can be opened
/// or is busy (Windows — a pipe is not a file `exists` can see reliably).
pub fn alive(endpoint: &Endpoint) -> bool {
    #[cfg(unix)]
    { endpoint.socket.exists() }
    #[cfg(windows)]
    {
        const ERROR_FILE_NOT_FOUND: i32 = 2;
        match std::fs::OpenOptions::new().read(true).write(true).open(&endpoint.pipe) {
            Ok(_) => true,
            // ERROR_PIPE_BUSY and the like: an instance exists.
            Err(error) => error.raw_os_error() != Some(ERROR_FILE_NOT_FOUND),
        }
    }
}

pub fn wait_gone(endpoint: &Endpoint, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while alive(endpoint) {
        if Instant::now() >= deadline {
            return false;
        }
        // Each Windows probe is a connection: poll gently.
        thread::sleep(Duration::from_millis(if cfg!(windows) { 100 } else { 20 }));
    }
    true
}

/// Ask a running daemon to stop and wait for its endpoint to disappear.
pub fn stop(endpoint: &Endpoint) {
    if !alive(endpoint) {
        return;
    }
    if let Ok(mut conn) = Raw::connect(endpoint) && conn.hello(Duration::from_secs(10)).is_some() {
        conn.send(&json!({"id": "stop", "argv": ["daemon", "stop"]}));
        let _ = conn.reply("stop", Duration::from_secs(30));
    }
    assert!(wait_gone(endpoint, Duration::from_secs(30)), "the daemon did not leave {}", endpoint.id);
}

/// Run a command with a deadline, draining stdout/stderr concurrently.
pub fn output(mut command: Command, stdin: &[u8], timeout: Duration) -> Output {
    use std::io::Write as _;
    command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command.spawn().expect("spawn essence-rc");
    let mut pipe = child.stdin.take().unwrap();
    let _ = pipe.write_all(stdin);
    drop(pipe);
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let out = thread::spawn(move || { let mut bytes = Vec::new(); let _ = stdout.read_to_end(&mut bytes); bytes });
    let err = thread::spawn(move || { let mut bytes = Vec::new(); let _ = stderr.read_to_end(&mut bytes); bytes });
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("command timed out after {timeout:?}");
        }
        thread::sleep(Duration::from_millis(5));
    };
    Output { status, stdout: out.join().unwrap(), stderr: err.join().unwrap() }
}

/// A raw protocol connection: JSON lines in both directions.
pub struct Raw {
    to: Option<tokio::sync::mpsc::UnboundedSender<String>>,
    from: mpsc::Receiver<String>,
    /// Messages of other requests read while waiting for one reply.
    stash: std::cell::RefCell<std::collections::VecDeque<Value>>,
    thread: Option<JoinHandle<()>>,
}

impl Raw {
    pub fn connect(endpoint: &Endpoint) -> io::Result<Raw> {
        let (to, mut outgoing) = tokio::sync::mpsc::unbounded_channel::<String>();
        let (incoming, from) = mpsc::channel();
        let (ready, connected) = mpsc::channel();
        let endpoint = endpoint.clone();
        let thread = thread::spawn(move || {
            use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _};
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            runtime.block_on(async move {
                #[cfg(unix)]
                let stream = tokio::net::UnixStream::connect(&endpoint.socket).await;
                #[cfg(windows)]
                let stream = tokio::net::windows::named_pipe::ClientOptions::new().open(&endpoint.pipe);
                let stream = match stream {
                    Ok(stream) => { let _ = ready.send(Ok(())); stream }
                    Err(error) => { let _ = ready.send(Err(error)); return; }
                };
                let (read, mut write) = tokio::io::split(stream);
                let mut lines = tokio::io::BufReader::new(read).lines();
                let mut writing = true;
                loop {
                    tokio::select! {
                        line = lines.next_line() => match line {
                            Ok(Some(line)) => if incoming.send(line).is_err() { break },
                            _ => break,
                        },
                        message = outgoing.recv(), if writing => match message {
                            Some(mut line) => {
                                line.push('\n');
                                if write.write_all(line.as_bytes()).await.is_err() { break; }
                            }
                            // У именованного канала Windows нет полузакрытия: `shutdown` ничего
                            // не передаёт, и демон не увидит конца ввода. Канал закрывается целиком.
                            None if cfg!(windows) => break,
                            None => { writing = false; let _ = write.shutdown().await; }
                        },
                    }
                }
            });
        });
        connected.recv().map_err(|_| io::Error::other("connection thread died"))??;
        Ok(Raw { to: Some(to), from, stash: Default::default(), thread: Some(thread) })
    }

    /// Connect, retrying while the daemon starts.
    pub fn connect_wait(endpoint: &Endpoint, timeout: Duration) -> Raw {
        let deadline = Instant::now() + timeout;
        loop {
            match Raw::connect(endpoint) {
                Ok(raw) => return raw,
                Err(error) if Instant::now() >= deadline => panic!("no daemon at {}: {error}", endpoint.id),
                Err(_) => thread::sleep(Duration::from_millis(50)),
            }
        }
    }

    /// A plain WebSocket connection to a daemon's web listener
    /// (`ws://host:port/ws`): one protocol message per text frame.
    pub fn websocket(url: &str) -> io::Result<Raw> {
        let (to, mut outgoing) = tokio::sync::mpsc::unbounded_channel::<String>();
        let (incoming, from) = mpsc::channel();
        let (ready, connected) = mpsc::channel();
        let url = url.to_owned();
        let thread = thread::spawn(move || {
            use futures_util::{SinkExt as _, StreamExt as _};
            use tokio_tungstenite::tungstenite::Message;
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            runtime.block_on(async move {
                let address = url.trim_start_matches("ws://").split('/').next().unwrap_or_default().to_owned();
                let opened = async {
                    let tcp = tokio::net::TcpStream::connect(&address).await?;
                    tokio_tungstenite::client_async(url.as_str(), tcp).await.map_err(io::Error::other)
                }.await;
                let socket = match opened {
                    Ok((socket, _)) => { let _ = ready.send(Ok(())); socket }
                    Err(error) => { let _ = ready.send(Err(error)); return; }
                };
                let (mut sink, mut stream) = socket.split();
                let mut writing = true;
                loop {
                    tokio::select! {
                        message = stream.next() => match message {
                            Some(Ok(Message::Text(text))) => if incoming.send(text.to_string()).is_err() { break },
                            Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                            Some(Ok(_)) => {}
                        },
                        line = outgoing.recv(), if writing => match line {
                            Some(line) => if sink.send(Message::Text(line.into())).await.is_err() { break },
                            None => { writing = false; let _ = sink.close().await; }
                        },
                    }
                }
            });
        });
        connected.recv().map_err(|_| io::Error::other("connection thread died"))??;
        Ok(Raw { to: Some(to), from, stash: Default::default(), thread: Some(thread) })
    }

    pub fn send_line(&mut self, line: &str) {
        self.to.as_ref().expect("connection open").send(line.to_owned()).expect("connection alive");
    }

    pub fn send(&mut self, value: &Value) {
        self.send_line(&value.to_string());
    }

    /// The next message (stashed ones first); `None` at the deadline or EOF.
    pub fn next(&self, timeout: Duration) -> Option<Value> {
        if let Some(message) = self.stash.borrow_mut().pop_front() {
            return Some(message);
        }
        self.read(timeout)
    }

    fn read(&self, timeout: Duration) -> Option<Value> {
        let line = self.from.recv_timeout(timeout).ok()?;
        Some(serde_json::from_str(&line).unwrap_or_else(|error| panic!("daemon line is not JSON ({error}): {line}")))
    }

    /// The daemon closed the connection within `timeout` (nothing else arrived).
    pub fn closed(&self, timeout: Duration) -> bool {
        matches!(self.from.recv_timeout(timeout), Err(mpsc::RecvTimeoutError::Disconnected))
    }

    pub fn hello(&self, timeout: Duration) -> Option<Value> {
        self.next(timeout).filter(|hello| hello["event"] == "hello")
    }

    /// Events of request `id` and its reply, in order; messages of other
    /// requests are kept for later reads.
    pub fn reply(&self, id: impl Into<Value>, timeout: Duration) -> (Vec<Value>, Value) {
        let id = id.into();
        let deadline = Instant::now() + timeout;
        let mut events = Vec::new();
        let mut stashed: std::collections::VecDeque<Value> = std::mem::take(&mut *self.stash.borrow_mut());
        let mut others = std::collections::VecDeque::new();
        let result = loop {
            let message = match stashed.pop_front() {
                Some(message) => message,
                None => {
                    let left = deadline.saturating_duration_since(Instant::now());
                    match self.read(left) {
                        Some(message) => message,
                        None => break None,
                    }
                }
            };
            if message["id"] != id {
                others.push_back(message);
            } else if message.get("event").is_some() {
                events.push(message);
            } else {
                break Some(message);
            }
        };
        others.extend(stashed);
        *self.stash.borrow_mut() = others;
        let reply = result.unwrap_or_else(|| panic!("no reply to {id} within {timeout:?}; events {events:?}"));
        (events, reply)
    }

    /// One request and its reply.
    pub fn request(&mut self, id: &str, argv: &[&str], secrets: Value) -> (Vec<Value>, Value) {
        let mut request = json!({"id": id, "argv": argv});
        if secrets.as_object().is_some_and(|map| !map.is_empty()) {
            request["secrets"] = secrets;
        }
        self.send(&request);
        self.reply(id, Duration::from_secs(60))
    }

    /// Close our side (Unix — half-close; Windows — the whole pipe) and wait
    /// for the connection to end.
    pub fn close(mut self) {
        self.to.take();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for Raw {
    fn drop(&mut self) {
        self.to.take();
    }
}

/// Environment of the processes of one test.
#[derive(Clone)]
pub struct Ctx {
    pub data: PathBuf,
    pub runtime: PathBuf,
    /// Extra variables (HOME, PATH, fake tools …).
    pub vars: Vec<(OsString, OsString)>,
}

impl Ctx {
    pub fn endpoint(&self) -> Endpoint {
        endpoint(&self.runtime, &self.data)
    }

    pub fn command(&self, bin: impl AsRef<Path>) -> Command {
        let mut command = Command::new(bin.as_ref());
        command.env("ESSENCE_RC_DATA_DIR", &self.data)
            .env("ESSENCE_RC_RUNTIME_DIR", &self.runtime)
            .env("ESSENCE_RC_DAEMON_LINGER", "0")
            .envs(self.vars.iter().map(|(name, value)| (name, value)));
        command
    }

    /// A one-shot run; returns after its on-demand daemon left the endpoint.
    pub fn run(&self, args: &[&str], stdin: &[u8]) -> Output {
        let mut command = self.command(BIN);
        command.args(args);
        let result = output(command, stdin, Duration::from_secs(60));
        self.settle();
        result
    }

    /// Wait for the on-demand daemon of this context to exit.
    pub fn settle(&self) {
        assert!(wait_gone(&self.endpoint(), GONE_WAIT), "the on-demand daemon did not exit within {GONE_WAIT:?}");
    }

    /// The `SpawnDaemon.env` of in-process clients.
    pub fn spawn_env(&self) -> Vec<(OsString, OsString)> {
        let mut env = vec![("ESSENCE_RC_DAEMON_LINGER".into(), "0".into())];
        env.extend(self.vars.iter().cloned());
        env
    }
}

/// `essence-rc daemon run` as a child; its own connection keeps it from
/// exiting idle until `disconnect`.
pub struct Daemon {
    pub child: Child,
    pub endpoint: Endpoint,
    conn: Option<Raw>,
    pub hello: Value,
    journal: Option<JoinHandle<Vec<u8>>>,
}

impl Daemon {
    pub fn spawn(ctx: &Ctx) -> Daemon {
        Self::spawn_with(ctx, &[])
    }

    pub fn spawn_with(ctx: &Ctx, vars: &[(&str, &str)]) -> Daemon {
        Self::spawn_args(ctx, &[], vars)
    }

    /// `daemon run ARGS…` (e.g. `--web --port 0`).
    pub fn spawn_args(ctx: &Ctx, args: &[&str], vars: &[(&str, &str)]) -> Daemon {
        Self::spawn_exe(ctx, Path::new(BIN), args, vars)
    }

    /// `EXE daemon run ARGS…`: a disposable copy for tests that may uninstall it.
    pub fn spawn_exe(ctx: &Ctx, exe: &Path, args: &[&str], vars: &[(&str, &str)]) -> Daemon {
        let endpoint = ctx.endpoint();
        stop(&endpoint);
        let mut command = ctx.command(exe);
        command.args(["daemon", "run"]).args(args).envs(vars.iter().copied())
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
        let mut child = command.spawn().expect("spawn daemon run");
        let mut stderr = child.stderr.take().unwrap();
        let journal = thread::spawn(move || { let mut bytes = Vec::new(); let _ = stderr.read_to_end(&mut bytes); bytes });
        let mut conn = Raw::connect_wait(&endpoint, Duration::from_secs(15));
        let hello = conn.hello(Duration::from_secs(15)).expect("hello");
        let (_, status) = conn.request("pid", &["daemon", "status"], json!({}));
        assert_eq!(status["data"]["pid"], json!(child.id()), "the endpoint belongs to this child: {status}");
        Daemon { child, endpoint, conn: Some(conn), hello, journal: Some(journal) }
    }

    /// The helper's own connection.
    pub fn conn(&mut self) -> &mut Raw {
        self.conn.as_mut().expect("connection kept")
    }

    /// Close the helper's own connection (the daemon may now go idle).
    pub fn disconnect(&mut self) {
        if let Some(conn) = self.conn.take() {
            conn.close();
        }
    }

    /// A further connection with its `hello` consumed.
    pub fn connect(&self) -> Raw {
        let raw = Raw::connect_wait(&self.endpoint, Duration::from_secs(10));
        raw.hello(Duration::from_secs(10)).expect("hello");
        raw
    }

    /// Wait for the child to exit by itself.
    pub fn wait_exit(&mut self, timeout: Duration) -> Option<std::process::ExitStatus> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                return Some(status);
            }
            if Instant::now() >= deadline {
                return None;
            }
            thread::sleep(Duration::from_millis(20));
        }
    }

    /// The daemon journal (its stderr and `<h>.log`).
    pub fn journal(&self) -> String {
        std::fs::read_to_string(&self.endpoint.log).unwrap_or_default()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            if let Ok(mut conn) = Raw::connect(&self.endpoint) && conn.hello(Duration::from_secs(5)).is_some() {
                conn.send(&json!({"id": "drop", "argv": ["daemon", "stop"]}));
                let _ = conn.next(Duration::from_secs(30));
            }
            if self.wait_exit(Duration::from_secs(30)).is_none() {
                let _ = self.child.kill();
                let _ = self.child.wait();
            }
        }
        let _ = wait_gone(&self.endpoint, Duration::from_secs(5));
        if let Some(journal) = self.journal.take() {
            let _ = journal.join();
        }
    }
}

/// JSON lines of a process output.
pub fn lines(bytes: &[u8]) -> Vec<Value> {
    std::str::from_utf8(bytes).unwrap().lines()
        .map(|line| serde_json::from_str(line).unwrap_or_else(|error| panic!("invalid JSON line {line:?}: {error}")))
        .collect()
}
