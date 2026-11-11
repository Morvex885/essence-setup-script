//! Black-box serve v2 and CLI contract tests against the plan specification.
use serde_json::{json, Value};
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
    sync::atomic::{AtomicU64, Ordering},
    thread,
    time::{Duration, Instant},
};

static NEXT_DIR: AtomicU64 = AtomicU64::new(0);

struct TestDir(PathBuf);
impl TestDir {
    fn new() -> Self {
        let id = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("essence-serve-test-{}-{id}", std::process::id()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn path(&self) -> &Path { &self.0 }
}
impl Drop for TestDir {
    fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
}

fn command(dir: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_essence-rc"));
    command.env("ESSENCE_RC_DATA_DIR", dir)
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    command
}

// Drain both pipes concurrently and bound every spawned command, including failures.
fn run(dir: &Path, args: &[&str], input: &[u8]) -> Output {
    let mut child = command(dir).args(args).spawn().unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let out = thread::spawn(move || { let mut b = Vec::new(); stdout.read_to_end(&mut b).unwrap(); b });
    let err = thread::spawn(move || { let mut b = Vec::new(); stderr.read_to_end(&mut b).unwrap(); b });
    let deadline = Instant::now() + Duration::from_secs(20);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() { break status; }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("command timed out: {args:?}");
        }
        thread::sleep(Duration::from_millis(10));
    };
    Output { status, stdout: out.join().unwrap(), stderr: err.join().unwrap() }
}

fn lines(output: &[u8]) -> Vec<Value> {
    std::str::from_utf8(output).unwrap().lines().map(|line| {
        serde_json::from_str(line).unwrap_or_else(|error| panic!("invalid JSON line {line:?}: {error}"))
    }).collect()
}

#[test]
fn serve_hello_batch_ids_secrets_and_protocol_errors() {
    let dir = TestDir::new();
    let secret = "do-not-echo-serve-secret";
    let requests = [
        json!({"id":"first", "argv":["session", "status"]}).to_string(),
        json!({"id":42, "argv":["not-a-noun"], "secrets":{"password":secret}}).to_string(),
        json!({"id":null, "argv":["self", "not-a-verb"]}).to_string(),
        json!({"id":"nul", "argv":["self", "ver\u{0}sion"]}).to_string(),
        json!({"id":"stdin", "argv":["self", "version", "--secrets-stdin"]}).to_string(),
        "{malformed".to_string(),
    ];
    let output = run(dir.path(), &["serve"], format!("{}\n", requests.join("\n")).as_bytes());
    assert!(output.status.success(), "serve failed: {}", String::from_utf8_lossy(&output.stderr));
    assert!(!String::from_utf8_lossy(&output.stdout).contains(secret), "secret leaked in serve output");
    assert!(!String::from_utf8_lossy(&output.stderr).contains(secret), "secret leaked in diagnostics");
    let events = lines(&output.stdout);
    assert_eq!(events.first(), Some(&json!({"event":"hello", "protocol":2, "version":include_str!("../../../VERSION").trim()})));
    let expected = [json!("first"), json!(42), Value::Null, json!("nul"), json!("stdin"), Value::Null];
    let mut replies = Vec::new();
    for event in &events[1..] {
        if event.get("event") == Some(&json!("log")) {
            assert!(replies.len() < expected.len(), "log after final response: {event}");
            assert_eq!(event.get("id"), Some(&expected[replies.len()]), "log must belong to active request");
            let level = event["level"].as_str().expect("native log level");
            assert!(["info", "success", "warn", "error", "output"].contains(&level));
            let text = event["text"].as_str().expect("log text");
            assert!(!text.chars().any(|c| c.is_control()), "unsanitized control in {event}");
        } else {
            let index = replies.len();
            assert!(index < expected.len(), "extra reply: {event}");
            assert_eq!(event.get("id"), Some(&expected[index]), "responses must be strictly sequential");
            assert!(event["ok"].is_boolean(), "missing boolean ok: {event}");
            replies.push(event);
        }
    }
    assert_eq!(replies.len(), expected.len(), "exactly one response per request");
    assert_eq!(replies[0]["ok"], true, "a valid request succeeds");
    for reply in &replies[1..] {
        assert_eq!(reply["ok"], false);
        assert_eq!(reply["error"]["code"], "usage");
    }
}

#[test]
fn cli_exit_codes_and_plan_token_without_yes() {
    let dir = TestDir::new();
    let version = run(dir.path(), &["self", "version", "--json"], b"");
    assert_eq!(version.status.code(), Some(0));
    let version_lines = lines(&version.stdout);
    assert_eq!(version_lines.len(), 1);
    assert_eq!(version_lines[0]["ok"], true);

    // stdin "y" must not confirm anything; --plan-token without --yes is usage.
    for args in [vec!["unknown-noun", "--json"], vec!["self", "unknown-verb", "--json"], vec!["self", "version", "--plan-token", "wrong", "--json"]] {
        let output = run(dir.path(), &args, b"y\n");
        assert_eq!(output.status.code(), Some(2), "{args:?}: {}", String::from_utf8_lossy(&output.stderr));
        let output = lines(&output.stdout);
        assert_eq!(output.len(), 1);
        assert_eq!(output[0]["ok"], false);
        assert_eq!(output[0]["error"]["code"], "usage");
    }
}

#[test]
fn confirmation_lifecycle_and_secrets_stdin_pipe() {
    let dir = TestDir::new();
    // Set a script password via --secrets-stdin (pipe, so no /dev/tty prompt).
    let set = run(dir.path(), &["self", "password-set", "--secrets-stdin", "--json"],
        br#"{"password":"pass-one","current-password":""}"#);
    assert_eq!(set.status.code(), Some(0), "{}", String::from_utf8_lossy(&set.stderr));
    let set = lines(&set.stdout);
    assert_eq!(set.len(), 1);
    assert_eq!(set[0]["ok"], true);

    // Once a password exists every protected one-shot command needs the
    // session secret; an empty new password is then rejected by command
    // semantics, not by the decoder.
    let empty = run(dir.path(), &["self", "password-set", "--secrets-stdin", "--json"],
        br#"{"password":"","current-password":"pass-one","script-password":"pass-one"}"#);
    assert_eq!(empty.status.code(), Some(1));
    let empty = lines(&empty.stdout);
    assert_eq!(empty.len(), 1);
    assert_eq!(empty[0]["error"]["code"], "invalid");

    // Removal is a mutating command: exact plan first, token then consent.
    let planned = run(dir.path(), &["self", "password-remove", "--secrets-stdin", "--json"],
        br#"{"current-password":"pass-one","script-password":"pass-one"}"#);
    assert_eq!(planned.status.code(), Some(2));
    let planned_lines = lines(&planned.stdout);
    assert_eq!(planned_lines.len(), 1, "exactly one envelope");
    assert_eq!(planned_lines[0]["error"]["code"], "confirmation_required");
    assert_eq!(planned_lines[0]["error"]["plan"],
        json!(["Пароль запуска remote-control будет удалён.", "Локальные данные и SSH-ключи сохранятся."]));
    let token = planned_lines[0]["error"]["plan_token"].as_str().expect("plan token").to_string();
    assert_eq!(token.len(), 16);
    assert!(token.chars().all(|c| c.is_ascii_hexdigit()));

    let wrong = run(dir.path(), &["self", "password-remove", "--secrets-stdin", "--yes", "--plan-token", "0000000000000000", "--json"],
        br#"{"current-password":"pass-one","script-password":"pass-one"}"#);
    assert_eq!(wrong.status.code(), Some(2));
    let wrong = lines(&wrong.stdout);
    assert_eq!(wrong[0]["error"]["code"], "plan_changed");

    let right = run(dir.path(), &["self", "password-remove", "--secrets-stdin", "--yes", "--plan-token", &token, "--json"],
        br#"{"current-password":"pass-one","script-password":"pass-one"}"#);
    assert_eq!(right.status.code(), Some(0), "{}", String::from_utf8_lossy(&right.stderr));
    let right = lines(&right.stdout);
    assert_eq!(right[0]["ok"], true);

    // Re-set the password (no current-password required once removed), then a
    // stale current-password must fail authentication.
    let reset = run(dir.path(), &["self", "password-set", "--secrets-stdin", "--json"],
        br#"{"password":"pass-two"}"#);
    assert_eq!(reset.status.code(), Some(0), "{}", String::from_utf8_lossy(&reset.stderr));
    let stale = run(dir.path(), &["self", "password-remove", "--secrets-stdin", "--json"],
        br#"{"current-password":"pass-one","script-password":"pass-two"}"#);
    let stale_lines = lines(&stale.stdout);
    assert_eq!(stale_lines.len(), 1);
    assert_eq!(stale_lines[0]["error"]["code"], "auth_failed");
}

/// SIGINT while a request is provably in flight. The test process holds the
/// real mutation lock (production `.rc-lock`, live owner), so
/// `self password-set` blocks in its lock wait (`RC_LOCK_WAIT`, a production
/// setting) and cannot reply before the lock is released. SIGINT is sent
/// while it waits; the reply must still arrive — only after the release — and
/// EOF must then end serve with exit 0.
#[cfg(unix)]
#[test]
fn sigint_during_in_flight_serve_command_does_not_kill_reply() {
    use rc_core::locking::{LockKind, LockManager};
    use std::os::unix::process::ExitStatusExt as _;
    use std::sync::mpsc;

    let dir = TestDir::new();
    let init = run(dir.path(), &["source", "init-local", "--json"], b"");
    assert_eq!(init.status.code(), Some(0), "{}", String::from_utf8_lossy(&init.stdout));
    let set = run(dir.path(), &["self", "password-set", "--secrets-stdin", "--json"], br#"{"password":"sig-one"}"#);
    assert_eq!(set.status.code(), Some(0), "{}", String::from_utf8_lossy(&set.stderr));

    let mut child = command(dir.path()).env("RC_LOCK_WAIT", "30").args(["serve"]).spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    use std::io::BufRead as _;
    let stdout = std::io::BufReader::new(child.stdout.take().unwrap());
    let (sender, lines) = mpsc::channel::<Value>();
    thread::spawn(move || {
        for line in stdout.lines().map_while(Result::ok) {
            if sender.send(serde_json::from_str(&line).expect("serve stdout is JSONL")).is_err() { break; }
        }
    });
    let reply = |timeout: Duration| -> Option<Value> {
        let deadline = Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match lines.recv_timeout(left) {
                Ok(value) if value.get("event").is_none() => return Some(value),
                Ok(_) => continue,
                Err(_) => return None,
            }
        }
    };
    let mut send = |line: &[u8]| {
        stdin.write_all(line).unwrap();
        stdin.write_all(b"\n").unwrap();
        stdin.flush().unwrap();
    };
    assert_eq!(lines.recv_timeout(Duration::from_secs(15)).unwrap()["event"], "hello");
    send(br#"{"id":"open","argv":["session","open"],"secrets":{"script-password":"sig-one"}}"#);
    assert_eq!(reply(Duration::from_secs(20)).expect("session open reply")["ok"], true);

    let locks = LockManager::new(dir.path());
    let guard = locks.acquire_with_timeout(LockKind::Mutation, "test holds the lock", Duration::from_secs(5)).unwrap();
    send(br#"{"id":"slow","argv":["self","password-set"],"secrets":{"password":"sig-two","current-password":"sig-one"}}"#);
    assert!(reply(Duration::from_millis(1500)).is_none(), "the command must be blocked on the held lock");
    unsafe { libc::kill(child.id() as i32, libc::SIGINT) };
    assert!(reply(Duration::from_millis(1500)).is_none(), "still in flight after SIGINT: no premature reply");
    assert!(child.try_wait().unwrap().is_none(), "SIGINT must not terminate serve");
    drop(guard);
    let slow = reply(Duration::from_secs(30)).expect("reply after the lock is released");
    assert_eq!((slow["id"].clone(), slow["ok"].clone()), (json!("slow"), json!(true)), "{slow}");

    drop(send);
    drop(stdin);
    let status = child.wait().unwrap();
    if let Some(signal) = status.signal() { panic!("serve killed by signal {signal}"); }
    assert_eq!(status.code(), Some(0), "EOF must close the session with exit 0");
    assert!(reply(Duration::from_millis(200)).is_none(), "exactly one reply per request");
    // The in-flight mutation really completed: the new password authorizes.
    let check = run(dir.path(), &["status", "--secrets-stdin", "--json"], br#"{"script-password":"sig-two"}"#);
    assert_eq!(check.status.code(), Some(0), "{}", String::from_utf8_lossy(&check.stdout));
}

/// SIGTERM/SIGHUP while the console is in raw mode: the terminal must come
/// back in cooked mode and the process must exit with 128+signal. The child
/// runs on a real pseudo-terminal (libc `openpty`, the child's controlling
/// terminal via `setsid` + `TIOCSCTTY`); the raw console is the hidden
/// script-password prompt of a one-shot `status`, observed through the
/// slave's termios (`ICANON`/`ECHO`, the flags `stty -g` would print).
#[cfg(unix)]
#[test]
fn termination_signals_restore_the_raw_console() {
    use std::os::unix::process::CommandExt as _;
    for (signal, name) in [(libc::SIGTERM, "SIGTERM"), (libc::SIGHUP, "SIGHUP")] {
        let dir = TestDir::new();
        assert_eq!(run(dir.path(), &["source", "init-local", "--json"], b"").status.code(), Some(0));
        let set = run(dir.path(), &["self", "password-set", "--secrets-stdin", "--json"], br#"{"password":"tty-pass"}"#);
        assert_eq!(set.status.code(), Some(0), "{}", String::from_utf8_lossy(&set.stderr));

        let (mut master, mut slave) = (0, 0);
        assert_eq!(unsafe { libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), std::ptr::null(), std::ptr::null()) }, 0);
        let lflag = |fd| {
            let mut termios: libc::termios = unsafe { std::mem::zeroed() };
            assert_eq!(unsafe { libc::tcgetattr(fd, &mut termios) }, 0);
            termios.c_lflag
        };
        let cooked = lflag(slave);
        assert!(cooked & libc::ICANON != 0 && cooked & libc::ECHO != 0, "a fresh pty starts cooked");
        let stdio = |fd: i32| unsafe { Stdio::from_raw_fd_dup(fd) };
        let mut child = Command::new(env!("CARGO_BIN_EXE_essence-rc"));
        child.env("ESSENCE_RC_DATA_DIR", dir.path()).arg("status")
            .stdin(stdio(slave)).stdout(stdio(slave)).stderr(stdio(slave));
        unsafe {
            child.pre_exec(move || {
                if libc::setsid() < 0 || libc::ioctl(slave, libc::TIOCSCTTY as _, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let spawned = child.spawn().unwrap();
        // The Command keeps its own copies of the slave fds; close them so the
        // master reaches EOF once the child exits.
        drop(child);
        let mut child = spawned;
        // Drain the pty so the prompt never blocks on a full buffer.
        let drain = thread::spawn(move || {
            let mut buffer = [0u8; 1024];
            while unsafe { libc::read(master, buffer.as_mut_ptr().cast(), buffer.len()) } > 0 {}
        });
        let deadline = Instant::now() + Duration::from_secs(20);
        while lflag(slave) & libc::ICANON != 0 {
            assert!(Instant::now() < deadline, "{name}: the hidden prompt never entered raw mode");
            assert!(child.try_wait().unwrap().is_none(), "{name}: exited before the prompt");
            thread::sleep(Duration::from_millis(20));
        }
        unsafe { libc::kill(child.id() as i32, signal) };
        let status = child.wait().unwrap();
        assert_eq!(status.code(), Some(128 + signal), "{name}: conventional exit code");
        let restored = lflag(slave);
        assert!(restored & libc::ICANON != 0 && restored & libc::ECHO != 0, "{name}: terminal left in raw mode");
        unsafe { libc::close(slave) };
        let _ = drain.join();
        unsafe { libc::close(master) };
    }
}

#[cfg(unix)]
trait FromRawFdDup {
    /// A Stdio owning a duplicate of `fd` (the test keeps its own copy).
    unsafe fn from_raw_fd_dup(fd: i32) -> Stdio;
}

#[cfg(unix)]
impl FromRawFdDup for Stdio {
    unsafe fn from_raw_fd_dup(fd: i32) -> Stdio {
        use std::os::fd::FromRawFd as _;
        unsafe { Stdio::from_raw_fd(libc::dup(fd)) }
    }
}
