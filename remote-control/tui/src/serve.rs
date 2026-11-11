//! The only core boundary: a private serve-v2 child, never a core library.
use std::{collections::{BTreeMap, VecDeque}, io::{self, BufRead, BufReader, Read, Seek, Write}, process::{Child, ChildStdout, Command, Stdio},
    sync::mpsc::{self, Receiver, RecvTimeoutError}, time::Duration};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use zeroize::{Zeroize, Zeroizing};

/// While a request is in flight the screen is woken this often (spinner,
/// elapsed time), so a slow core call never freezes the frame.
pub const TICK: Duration = Duration::from_millis(100);

/// Secrets are never Debug or rendered. Values and serialized wire buffers are wiped.
#[derive(Default, Serialize)]
#[serde(transparent)]
pub struct Secrets(BTreeMap<String, Zeroizing<String>>);
impl Secrets {
    pub fn insert(&mut self, name: impl Into<String>, value: impl Into<String>) { self.0.insert(name.into(), Zeroizing::new(value.into())); }
    pub fn insert_hidden(&mut self, name: impl Into<String>, value: Zeroizing<String>) { self.0.insert(name.into(),value); }
    pub fn clear(&mut self) { self.0.clear(); }
    pub fn is_empty(&self) -> bool { self.0.is_empty() }
}
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Log { pub level: String, pub text: String }
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Reply {
    #[serde(default)] pub ok: bool,
    #[serde(default)] pub data: Value,
    #[serde(default)] pub error: Value,
    #[serde(default)] pub sync: Value,
    #[serde(skip)] pub logs: Vec<Log>,
}
impl Reply {
    pub fn code(&self) -> &str { self.error["code"].as_str().unwrap_or("") }
    pub fn success(data: Value) -> Self { Self { ok: true, data, ..Self::default() } }
    pub fn failure(code: &str) -> Self { Self { error: serde_json::json!({"code":code}), ..Self::default() } }
}
/// Progress of a request in flight: a journal event of the core, or a timer
/// tick (every [`TICK`] without output) for redraws.
pub enum Progress<'a> { Log(&'a Log), Tick }
/// Screens use this trait exclusively. `progress` is called before the final reply.
pub trait ServeClient {
    fn version(&self) -> &str;
    fn send(&mut self, argv: &[String], secrets: &Secrets, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply>;
    /// Closing stdin releases the core session; normal shutdown waits for the child.
    fn close(&mut self) -> io::Result<()> { Ok(()) }
}
type Lines = Receiver<io::Result<Zeroizing<String>>>;
pub struct ProcessClient {
    child: Child,
    input: Option<std::process::ChildStdin>,
    /// stdout lines from a reader thread: the UI thread never blocks on the pipe.
    output: Lines,
    version: String,
    next_id: u64,
    closed: bool,
}
fn protocol(message: &str) -> io::Error { io::Error::new(io::ErrorKind::InvalidData, message) }
fn core_exited() -> io::Error { io::Error::new(io::ErrorKind::UnexpectedEof, "Ядро remote-control завершилось.") }
/// The thread ends at EOF or a read error (after reporting it) or when the
/// client is gone; it is never joined, so a stuck pipe cannot hang shutdown.
fn read_lines(stdout: ChildStdout) -> Lines {
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let mut stdout = BufReader::new(stdout);
        loop {
            let mut line = Zeroizing::new(String::new());
            let result = match stdout.read_line(&mut line) { Ok(0) => Err(core_exited()), Ok(_) => Ok(line), Err(error) => Err(error) };
            let last = result.is_err();
            if sender.send(result).is_err() || last { break; }
        }
    });
    receiver
}
fn parse(line: io::Result<Zeroizing<String>>) -> io::Result<Value> {
    serde_json::from_str(&line?).map_err(|_| protocol("Некорректный ответ ядра"))
}
impl ProcessClient {
    /// The core is this very executable (`essence-rc`), never a PATH lookup.
    pub fn start() -> io::Result<Self> { Self::spawn(Command::new(std::env::current_exe()?).args(["serve", "--inner"])) }
    /// Serve diagnostics (stderr) go to a private anonymous temp file; a failed
    /// start reports its tail (v1: fatal with the tail of serve.log).
    pub fn spawn(command: &mut Command) -> io::Result<Self> {
        let mut diagnostics = tempfile::tempfile()?;
        let mut child = command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::from(diagnostics.try_clone()?)).spawn()?;
        let input = child.stdin.take();
        let output = read_lines(child.stdout.take().ok_or_else(|| protocol("Нет stdout ядра"))?);
        let mut client = Self { child, input, output, version: String::new(), next_id: 0, closed: false };
        let hello = match client.read_value() {
            Ok(hello) if hello["event"] == "hello" && hello["protocol"] == 2 && hello["version"].is_string() => hello,
            Ok(_) => return Err(protocol("Несовместимый протокол ядра")),
            Err(error) => {
                client.input.take();
                for _ in 0..20 { if client.child.try_wait().ok().flatten().is_some() { break; } std::thread::sleep(std::time::Duration::from_millis(50)); }
                if client.child.try_wait().ok().flatten().is_none() { let _ = client.child.kill(); }
                let _ = client.child.wait();
                client.closed = true;
                let mut tail = String::new();
                let _ = diagnostics.seek(io::SeekFrom::Start(0)).and_then(|_| diagnostics.read_to_string(&mut tail));
                let tail: String = tail.lines().rev().take(5).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n");
                return Err(io::Error::new(error.kind(), if tail.trim().is_empty() { error.to_string() } else { format!("{error}\n{tail}") }));
            }
        };
        client.version = hello["version"].as_str().unwrap_or_default().to_owned();
        Ok(client)
    }
    fn read_value(&mut self) -> io::Result<Value> { parse(self.output.recv().map_err(|_| core_exited())?) }
    /// The next line; `tick` runs every [`TICK`] while the core is silent.
    fn next_value(&mut self, tick: &mut dyn FnMut()) -> io::Result<Value> {
        loop {
            match self.output.recv_timeout(TICK) {
                Ok(line) => return parse(line),
                Err(RecvTimeoutError::Timeout) => tick(),
                Err(RecvTimeoutError::Disconnected) => return Err(core_exited()),
            }
        }
    }
}
impl ServeClient for ProcessClient {
    fn version(&self) -> &str { &self.version }
    fn send(&mut self, argv: &[String], secrets: &Secrets, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply> {
        self.next_id = self.next_id.checked_add(1).ok_or_else(|| protocol("Исчерпаны id запросов"))?;
        #[derive(Serialize)] struct Request<'a> { id: u64, argv: &'a [String], #[serde(skip_serializing_if="Secrets::is_empty")] secrets: &'a Secrets }
        let mut wire = Zeroizing::new(serde_json::to_vec(&Request { id: self.next_id, argv, secrets }).map_err(io::Error::other)?);
        wire.push(b'\n');
        let input = self.input.as_mut().ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "Сессия закрыта"))?;
        input.write_all(&wire)?;
        input.flush()?;
        wire.zeroize();
        let mut logs = Vec::new();
        loop {
            let value = self.next_value(&mut || progress(Progress::Tick))?;
            if value["id"].as_u64() != Some(self.next_id) { return Err(protocol("Неверный id ответа ядра")); }
            if value["event"] == "log" {
                let entry: Log = serde_json::from_value(value).map_err(|_| protocol("Некорректное событие журнала"))?;
                progress(Progress::Log(&entry));
                logs.push(entry);
            } else if value.get("event").is_none() && value["ok"].is_boolean() {
                let mut reply: Reply = serde_json::from_value(value).map_err(|_| protocol("Некорректный конверт ядра"))?;
                reply.logs = logs;
                return Ok(reply);
            } else { return Err(protocol("Неизвестное событие ядра")); }
        }
    }
    fn close(&mut self) -> io::Result<()> {
        self.input.take();
        if !self.closed { self.child.wait()?; self.closed = true; }
        Ok(())
    }
}
impl Drop for ProcessClient {
    fn drop(&mut self) {
        self.input.take();
        if !self.closed {
            // On a broken protocol the peer may no longer read stdin. Never hang cleanup.
            if self.child.try_wait().ok().flatten().is_none() { let _ = self.child.kill(); }
            let _ = self.child.wait();
        }
    }
}
/// Deterministic screen fake; assertions include argv and keep secrets out of diagnostics.
pub struct ScriptedClient {
    pub steps: VecDeque<(Vec<String>, Reply)>,
    pub calls: Vec<Vec<String>>,
    pub secret_names: Vec<Vec<String>>,
    pub closed: bool,
}
impl ScriptedClient {
    pub fn new(steps: impl IntoIterator<Item=(Vec<String>, Reply)>) -> Self { Self { steps: steps.into_iter().collect(), calls: vec![], secret_names: vec![], closed: false } }
    pub fn assert_finished(&self) { assert!(self.steps.is_empty(), "Unused scripted replies"); }
}
impl ServeClient for ScriptedClient {
    fn version(&self) -> &str { "test" }
    fn send(&mut self, argv: &[String], secrets: &Secrets, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply> {
        self.calls.push(argv.to_vec());
        self.secret_names.push(secrets.0.keys().cloned().collect());
        let (expected, reply) = self.steps.pop_front().expect("Unexpected request");
        assert_eq!(argv, expected);
        for entry in &reply.logs { progress(Progress::Log(entry)); }
        Ok(reply)
    }
    fn close(&mut self) -> io::Result<()> { self.closed = true; Ok(()) }
}
pub fn argv(words: &[&str]) -> Vec<String> { words.iter().map(|s| (*s).to_owned()).collect() }

/// The process tests drive `/bin/sh` children, so the module is Unix-only.
#[cfg(all(test, unix))] mod tests {
    use super::*;
    #[test] fn scripted_child_logs_ids_secrets_and_eof() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "printf '%s\\n' '{\"event\":\"hello\",\"protocol\":2,\"version\":\"9\"}'; read -r req; printf '%s\\n' '{\"id\":1,\"event\":\"log\",\"level\":\"info\",\"text\":\"working\"}' '{\"id\":1,\"ok\":true,\"data\":{}}'; read -r req; printf '%s\\n' '{\"id\":2,\"ok\":false,\"error\":{\"code\":\"panic\"}}'; read -r req"]);
        let mut client = ProcessClient::spawn(&mut command).unwrap();
        assert_eq!(client.version(), "9");
        let mut logs = vec![];
        assert!(client.send(&argv(&["status"]), &Secrets::default(), &mut |p| if let Progress::Log(l) = p { logs.push(l.clone()) }).unwrap().ok);
        assert_eq!(logs.len(), 1);
        assert_eq!(client.send(&argv(&["status"]), &Secrets::default(), &mut |_|{}).unwrap().code(), "panic");
        client.close().unwrap();
    }
    /// A slow core: the log arrives at once, the reply only later; the caller
    /// gets timer ticks in between, so the UI can redraw while it waits.
    #[test] fn slow_reply_ticks_while_in_flight() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "printf '%s\\n' '{\"event\":\"hello\",\"protocol\":2,\"version\":\"9\"}'; read -r req; printf '%s\\n' '{\"id\":1,\"event\":\"log\",\"level\":\"info\",\"text\":\"working\"}'; sleep 1; printf '%s\\n' '{\"id\":1,\"ok\":true,\"data\":{}}'; read -r req"]);
        let mut client = ProcessClient::spawn(&mut command).unwrap();
        let mut events = vec![];
        let reply = client.send(&argv(&["status"]), &Secrets::default(), &mut |p| events.push(match p { Progress::Log(l) => l.text.clone(), Progress::Tick => "tick".into() })).unwrap();
        assert!(reply.ok);
        let first_tick = events.iter().position(|e| e == "tick").expect("ticks while the reply is pending");
        assert_eq!(events[..first_tick], ["working".to_owned()], "the log event is delivered before any wait");
        assert!(events.iter().filter(|e| *e == "tick").count() >= 5, "{events:?}");
        client.close().unwrap();
    }
    #[test] fn child_eof_is_explicit() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "printf '%s\\n' '{\"event\":\"hello\",\"protocol\":2,\"version\":\"9\"}'; read -r req; exit 0"]);
        let mut client = ProcessClient::spawn(&mut command).unwrap();
        assert_eq!(client.send(&argv(&["status"]), &Secrets::default(), &mut |_|{}).unwrap_err().kind(), io::ErrorKind::UnexpectedEof);
    }
    #[test] fn failed_start_reports_serve_diagnostics_tail() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "echo '  [✗] state directory unusable' >&2; exit 1"]);
        let error = ProcessClient::spawn(&mut command).err().unwrap();
        assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof);
        assert!(error.to_string().contains("state directory unusable"), "{error}");
    }
}
