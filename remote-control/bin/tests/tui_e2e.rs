//! Linux PTY cases drive the REAL `essence-rc` without arguments: the menu
//! runs in that process and talks to an on-demand daemon of the same
//! executable. Each case has its own HOME/data dir and runtime directory;
//! wait for prompts before sending keys. No network. Geometry/colour rules
//! are covered by TestBackend unit tests.
#![cfg(target_os = "linux")]
mod common;

use std::{
    fs::File,
    io::{self, Read, Write},
    os::{fd::{AsRawFd, FromRawFd, RawFd}, unix::process::CommandExt},
    path::Path,
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

use essence_rc_client::{Client, DaemonClient, Hello, Progress, Request, SpawnDaemon, TerminalIo};

const BINARY: &str = env!("CARGO_BIN_EXE_essence-rc");

const ROWS: usize = 45;
const COLS: usize = 90;

/// A minimal VT screen: ratatui only re-emits changed cells, so expectations
/// are checked against the screen contents, not the raw byte stream. Handles
/// cursor addressing/moves, erase, CR/LF/BS with scrolling; SGR/modes ignored.
struct Screen { grid: Vec<Vec<char>>, row: usize, col: usize, state: u8, params: String }

impl Screen {
    fn new() -> Self { Self { grid: vec![vec![' '; COLS]; ROWS], row: 0, col: 0, state: 0, params: String::new() } }
    fn feed(&mut self, text: &str) {
        for ch in text.chars() {
            match self.state {
                1 => match ch { '[' => { self.state = 2; self.params.clear(); } ']' => self.state = 3, _ => self.state = 0 },
                2 if ('@'..='~').contains(&ch) => { self.state = 0; self.csi(ch); }
                2 => self.params.push(ch),
                3 => match ch { '\u{7}' => self.state = 0, '\u{1b}' => self.state = 4, _ => {} },
                4 => self.state = if ch == '\\' { 0 } else { 3 },
                _ => match ch {
                    '\u{1b}' => self.state = 1,
                    '\r' => self.col = 0,
                    '\n' => self.line_feed(),
                    '\u{8}' => self.col = self.col.saturating_sub(1),
                    ch if ch.is_control() => {}
                    ch => {
                        if self.col >= COLS { self.col = 0; self.line_feed(); }
                        self.grid[self.row][self.col] = ch;
                        self.col += 1;
                    }
                },
            }
        }
    }
    fn line_feed(&mut self) {
        if self.row + 1 == ROWS { self.grid.remove(0); self.grid.push(vec![' '; COLS]); } else { self.row += 1; }
    }
    fn csi(&mut self, end: char) {
        if self.params.starts_with('?') { return; }
        let numbers: Vec<usize> = self.params.split(';').map(|p| p.parse().unwrap_or(0)).collect();
        let n = |i: usize| numbers.get(i).copied().filter(|v| *v > 0).unwrap_or(1);
        match end {
            'H' | 'f' => { self.row = (n(0) - 1).min(ROWS - 1); self.col = (n(1) - 1).min(COLS - 1); }
            'A' => self.row = self.row.saturating_sub(n(0)),
            'B' => self.row = (self.row + n(0)).min(ROWS - 1),
            'C' => self.col = (self.col + n(0)).min(COLS - 1),
            'D' => self.col = self.col.saturating_sub(n(0)),
            'G' => self.col = (n(0) - 1).min(COLS - 1),
            'J' => {
                let from = if numbers[0] == 0 { self.row * COLS + self.col } else { 0 };
                for cell in from..ROWS * COLS { self.grid[cell / COLS][cell % COLS] = ' '; }
            }
            'K' => for col in self.col..COLS { self.grid[self.row][col] = ' ' },
            _ => {}
        }
    }
    /// Screen text without whitespace (ratatui pads with spaces/moves).
    fn text(&self) -> String { self.grid.iter().flatten().filter(|c| !c.is_whitespace()).collect() }
    fn dump(&self) -> String { self.grid.iter().map(|row| row.iter().collect::<String>().trim_end().to_owned()).collect::<Vec<_>>().join("\n") }
}

fn compact(text: &str) -> String { text.chars().filter(|c| !c.is_whitespace()).collect() }

fn openpty() -> (File, File) {
    let (mut master, mut slave) = (-1, -1);
    let mut size = libc::winsize { ws_row: 45, ws_col: 90, ws_xpixel: 0, ws_ypixel: 0 };
    // `*mut` coerces to the `*const` Linux signature and matches macOS's `*mut`.
    assert_eq!(unsafe { libc::openpty(&mut master, &mut slave, std::ptr::null_mut(), std::ptr::null_mut(), &mut size) }, 0);
    (unsafe { File::from_raw_fd(master) }, unsafe { File::from_raw_fd(slave) })
}

/// Make `slave` the controlling terminal of the spawned child.
fn controlling_terminal(command: &mut Command, slave: RawFd) {
    unsafe {
        command.pre_exec(move || {
            if libc::setsid() < 0 || libc::ioctl(slave, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

struct PtySession { child: Child, master: File, slave: File, home: tempfile::TempDir, runtime: tempfile::TempDir, screen: Screen, partial: Vec<u8> }

impl PtySession {
    fn start() -> Self { Self::start_with(|_, _| {}) }
    /// `prepare` gets the process context (data and runtime directories)
    /// and the command before spawning.
    fn start_with(prepare: impl FnOnce(&common::Ctx, &mut Command)) -> Self {
        let home = tempfile::tempdir().unwrap();
        let runtime = common::runtime_dir();
        let (master, slave) = openpty();
        let flags = unsafe { libc::fcntl(master.as_raw_fd(), libc::F_GETFL) };
        assert_eq!(unsafe { libc::fcntl(master.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) }, 0);
        let ctx = common::Ctx { data: home.path().join("rc"), runtime: runtime.path().to_path_buf(), vars: vec![("HOME".into(), home.path().into())] };
        let mut command = ctx.command(BINARY);
        command.env("XDG_DATA_HOME", home.path().join("data")).env("TERM", "xterm-256color")
            .env_remove("VISUAL").env_remove("EDITOR")
            .stdin(Stdio::from(slave.try_clone().unwrap()))
            .stdout(Stdio::from(slave.try_clone().unwrap()))
            .stderr(Stdio::from(slave.try_clone().unwrap()));
        controlling_terminal(&mut command, slave.as_raw_fd());
        prepare(&ctx, &mut command);
        let child = command.spawn().unwrap();
        Self { child, master, slave, home, runtime, screen: Screen::new(), partial: vec![] }
    }
    fn data(&self) -> std::path::PathBuf { self.home.path().join("rc") }
    fn endpoint(&self) -> essence_rc_client::Endpoint { common::endpoint(self.runtime.path(), &self.data()) }
    fn pump(&mut self) {
        let mut buffer = [0; 8192];
        match self.master.read(&mut buffer) {
            Ok(n) if n > 0 => {
                self.partial.extend_from_slice(&buffer[..n]);
                // Keep an incomplete UTF-8 tail for the next read.
                let valid = match std::str::from_utf8(&self.partial) { Ok(_) => self.partial.len(), Err(e) if e.error_len().is_none() => e.valid_up_to(), Err(_) => self.partial.len() };
                let bytes: Vec<u8> = self.partial.drain(..valid).collect();
                self.screen.feed(&String::from_utf8_lossy(&bytes));
            }
            Err(e) if e.kind() != io::ErrorKind::WouldBlock && e.raw_os_error() != Some(libc::EIO) => panic!("PTY read: {e}"),
            _ => {}
        }
    }
    fn expect(&mut self, text: &str) {
        let start = Instant::now();
        let wanted = compact(text);
        loop {
            self.pump();
            if self.screen.text().contains(&wanted) { return; }
            assert!(start.elapsed() < Duration::from_secs(20), "Missing {text:?}:\n{}", self.screen.dump());
            if let Some(status) = self.child.try_wait().unwrap() {
                self.pump();
                if self.screen.text().contains(&wanted) { return; }
                panic!("Early exit {status}:\n{}", self.screen.dump());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    fn send(&mut self, input: &str) { self.master.write_all(input.replace('\n', "\r").as_bytes()).unwrap(); }
    fn finish(&mut self, code: i32) {
        let start = Instant::now();
        loop {
            if let Some(status) = self.child.try_wait().unwrap() { assert_eq!(status.code(), Some(code)); break; }
            assert!(start.elapsed() < Duration::from_secs(20), "PTY did not exit");
            let mut buffer = [0; 8192];
            let _ = self.master.read(&mut buffer);
            std::thread::sleep(Duration::from_millis(10));
        }
        // The menu's on-demand daemon exited and released the session lock.
        assert!(common::wait_gone(&self.endpoint(), common::GONE_WAIT), "the daemon outlived the menu");
        let lock = self.data().join(".rc-lock");
        let start = Instant::now();
        while lock.exists() && start.elapsed() < Duration::from_secs(5) { std::thread::sleep(Duration::from_millis(20)); }
        assert!(!lock.exists(), "the session lock survived the daemon");
        let mut settings = std::mem::MaybeUninit::uninit();
        assert_eq!(unsafe { libc::tcgetattr(self.slave.as_raw_fd(), settings.as_mut_ptr()) }, 0);
        let settings = unsafe { settings.assume_init() };
        assert_ne!(settings.c_lflag & libc::ICANON, 0);
        assert_ne!(settings.c_lflag & libc::ECHO, 0);
    }
}

impl Drop for PtySession {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        common::stop(&self.endpoint());
    }
}

#[test]
fn first_run_init_local_add_group_generate_and_exit() {
    let mut session = PtySession::start();
    session.expect("Первый запуск");
    session.send("1\n");
    session.expect("Remote Control v");
    session.send("G\n");
    session.expect("Группы");
    session.send("a\n");
    session.expect("Название группы");
    session.send("LAB\n");
    session.expect("Шаблон группы");
    session.send("1\n");
    session.expect("LAB");
    session.send("0\n");
    session.expect("Remote Control v");
    session.send("f\n");
    session.expect("Генерация конфигов");
    session.send("a\n");
    session.expect("generated");
    session.send("\n");
    session.expect("Генерация конфигов");
    session.send("0\n");
    session.expect("Remote Control v");
    session.send("0\n");
    session.finish(0);
    let config = std::fs::read_to_string(session.data().join("config.json")).unwrap();
    let config: serde_json::Value = serde_json::from_str(&config).unwrap();
    assert!(config["groups"].as_array().unwrap().iter().any(|group| group["name"] == "LAB"));
}

/// Menus driven by arrows: bare Enter picks the highlighted first item, ←
/// does nothing on the dashboard, ↓↓→ opens «Группы»; Esc answers «нет» to
/// the delete question and leaves the card, ← leaves the list; the
/// dashboard remembers «Группы» so ↑↑↑ wraps around to «Выход».
#[test]
fn arrow_keys_navigate_menus() {
    let mut session = PtySession::start();
    session.expect("Первый запуск");
    session.send("\n");
    session.expect("Remote Control v");
    session.send("\x1b[D");
    session.send("\x1b[B\x1b[B\x1b[B\x1b[C");
    session.send("a\n");
    session.expect("Название группы");
    session.send("ARROWS\n");
    session.expect("Шаблон группы");
    session.send("1\n");
    session.expect("ARROWS");
    session.send("1\n");
    session.expect("Сгенерировать конфиги группы");
    session.send("d\n");
    session.expect("Удалить группу?");
    session.send("\x1b");
    session.expect("Сгенерировать конфиги группы");
    session.send("\x1b");
    session.expect("Добавить группу");
    session.send("\x1b[D");
    session.expect("Remote Control v");
    session.send("\x1b[A\x1b[A\x1b[A\x1b[A\n");
    session.finish(0);
    let config = std::fs::read_to_string(session.data().join("config.json")).unwrap();
    let config: serde_json::Value = serde_json::from_str(&config).unwrap();
    assert!(config["groups"].as_array().unwrap().iter().any(|group| group["name"] == "ARROWS"));
}

/// v1 startup codes: «Выход» on first run is a normal quit (0); a core that
/// cannot start or a session that cannot be opened ends the menu with 1.
#[test]
fn startup_exit_codes_quit_0_failures_1() {
    let mut quit = PtySession::start();
    quit.expect("Первый запуск");
    quit.send("0\n");
    quit.finish(0);

    // An unusable data dir: the menu cannot reach a daemon.
    let mut broken = PtySession::start_with(|_, command| { command.env("ESSENCE_RC_DATA_DIR", ""); });
    broken.expect("ESSENCE_RC_DATA_DIR");
    broken.finish(1);

    // A corrupt launch-password hash: `session open` answers auth_failed;
    // cancelling the hidden prompt (Ctrl+D) leaves the session closed.
    let mut closed = PtySession::start_with(|ctx, _| {
        let init = ctx.run(&["source", "init-local", "--json"], b"");
        assert!(init.status.success());
        std::fs::write(ctx.data.join("auth.txt"), "garbage\n").unwrap();
    });
    closed.expect("Введите пароль");
    closed.send("\u{4}");
    closed.finish(1);
}

#[test]
fn menu_ctrl_c_exits_130_and_restores_terminal() {
    let mut session = PtySession::start();
    session.expect("Первый запуск");
    session.send("\u{3}");
    session.finish(130);
}

#[test]
fn os_sigint_in_menu_closes_session_with_130() {
    let mut session = PtySession::start();
    session.expect("Первый запуск");
    session.send("1\n");
    session.expect("Remote Control v");
    assert_eq!(unsafe { libc::kill(session.child.id() as i32, libc::SIGINT) }, 0);
    session.finish(130);
}

#[test]
fn dashboard_ctrl_c_releases_open_session() {
    let mut session = PtySession::start();
    session.expect("Первый запуск");
    session.send("1\n");
    session.expect("Remote Control v");
    session.send("\u{3}");
    session.finish(130);
}

/// Records every request the real screens send to the real daemon.
struct Recording { inner: DaemonClient, calls: Vec<(Vec<String>, String)> }

impl Recording {
    fn record(&mut self, argv: &[String], reply: &essence_rc_client::Reply) {
        self.calls.push((argv.to_vec(), if reply.ok { "ok".into() } else { reply.code().to_owned() }));
    }
}

impl Client for Recording {
    fn hello(&self) -> &Hello { self.inner.hello() }
    fn send(&mut self, request: Request<'_>, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<essence_rc_client::Reply> {
        let reply = self.inner.send(request, progress)?;
        self.record(request.argv, &reply);
        Ok(reply)
    }
    fn terminal(&mut self, request: Request<'_>, io: &mut dyn TerminalIo, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<essence_rc_client::Reply> {
        let reply = self.inner.terminal(request, io, progress)?;
        self.record(request.argv, &reply);
        Ok(reply)
    }
    fn close(&mut self) -> io::Result<()> { self.inner.close() }
}

/// The screens' argv against the REAL v2 grammar and core: a scripted walk
/// through every dashboard section on a fresh local configuration. No
/// request may be rejected by the parser (`usage`).
#[test]
fn screens_speak_the_real_v2_grammar() {
    let home = tempfile::tempdir().unwrap();
    let runtime = common::runtime_dir();
    let ctx = common::Ctx { data: home.path().join("rc"), runtime: runtime.path().to_path_buf(), vars: vec![("HOME".into(), home.path().into())] };
    let spawn = SpawnDaemon { exe: BINARY.into(), args: vec!["daemon".into(), "run".into()], env: ctx.spawn_env() };
    let inner = DaemonClient::connect_local(&ctx.endpoint(), Some(&spawn), None, None).unwrap();
    let mut client = Recording { inner, calls: vec![] };
    let export = home.path().join("exported.yaml").to_string_lossy().into_owned();
    let walk = WALK.replace("EXPORT", &export);
    let script: Vec<&str> = walk.split_whitespace().map(|key| if key == "_" { "" } else { key }).collect();
    let mut ui = essence_rc_tui::app::ScriptedUi::new(&script);
    let mut terminal = || -> Box<dyn TerminalIo> { panic!("the walk opens no terminal") };
    let code = essence_rc_tui::app::run(&mut client, &mut ui, &essence_rc_tui::app::registrations(), &mut terminal).unwrap();
    for (argv, code) in &client.calls { eprintln!("{code:>24}  {}", argv.join(" ")); }
    eprintln!("unused input: {:?}; last frame: {:?}", ui.inputs, ui.views.last().map(|view| &view.title));
    assert_eq!(code, 0);
    assert!(ui.inputs.is_empty(), "walk derailed");
    let rejected: Vec<_> = client.calls.iter().filter(|(_, code)| code == "usage").collect();
    assert!(rejected.is_empty(), "grammar rejected: {rejected:?}");
    // Node-scoped screens (card, awg, per-node telegram) need a reachable SSH
    // node; their argv are checked against the catalog in nodes.rs tests.
    // Settings is skipped: `self version` would query GitHub (no network).
    for noun in ["session", "source", "status", "group", "client", "template", "generate", "subscription", "node", "conn", "telegram", "profile"] {
        assert!(client.calls.iter().any(|(argv, _)| argv[0] == noun), "walk never reached {noun}");
    }
    // The profile wizard: Self-Steal, random site, VLESS TCP, IPv6 as is, random email, pinned mihomo (no GitHub query).
    assert!(client.calls.iter().any(|(argv, code)| argv.starts_with(&["profile".to_owned(), "add".to_owned()]) && code == "ok"), "profile add");
    assert!(client.calls.iter().any(|(argv, code)| argv.starts_with(&["template".to_owned(), "show".to_owned()]) && code == "ok"));
    // `g` on default.yaml offers only groups on other templates: none here
    // (an empty list reads no key); `template groups` is covered by cli_contract.
    assert!(client.calls.iter().any(|(argv, code)| argv.starts_with(&["template".to_owned(), "check".to_owned()]) && code == "ok"), "template check");
    assert!(Path::new(&export).is_file(), "the export is written by the menu itself");
    drop(client);
    ctx.settle();
}

/// Dashboard keys per section; `_` is Enter, EXPORT a temp file path.
const WALK: &str = "1 \
    g a LAB 1 4 t 1 f _ h 0 0 0 \
    c a alice 4 1 v _ f _ s 0 r bob 0 0 \
    m 1 v _ c _ g x EXPORT 0 0 \
    n 0 r a edge 1 1 _ 1 _ v1.19.18 0 0 p 0 a 0 t s 0 \
    f a _ 0 \
    s l _ 0 \
    i 0 \
    0";
