//! Console access for the one-shot CLI and the menu: hidden secret input and
//! the raw terminal of interactive commands (`node shell`, `telegram menu`).
//!
//! Cross-platform through crossterm raw mode on the controlling console
//! (Unix `/dev/tty`, Windows console API — never `/dev/tty` paths on Windows).
//! The prompt itself goes to stderr; stdout stays reserved for the single
//! response. Redirected one-shot stdin is only read with `--secrets-stdin`.
//! Raw mode is restored by its guard on every return path and by the panic
//! hook, which exits without unwinding.

use std::io::{self, IsTerminal, Write};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, TryLockError};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use essence_rc_client::{TermEvent, TerminalIo};
use zeroize::Zeroizing;

/// Prompt labels for the whitelisted secrets, Russian v1 wording.
pub fn secret_prompt(name: &str) -> &'static str {
    match name {
        "password" => "  Пароль SSH ноды: ",
        "current-password" => "  Текущий пароль запуска: ",
        "vault-password" => "  Пароль доступа к конфигурации GitHub: ",
        "new-vault-password" => "  Новый пароль доступа к конфигурации GitHub: ",
        // script-password and any future whitelisted name.
        _ => "  Введите пароль: ",
    }
}

/// A hidden entry is possible only when stdin itself is the console (v1
/// `[[ -t 0 ]]` gate) and the console accepts raw mode. Redirected or closed
/// stdin disables prompting instead of blocking.
pub fn console_available() -> bool {
    std::io::stdin().is_terminal() && raw_mode_works()
}

fn raw_mode_works() -> bool {
    RawModeGuard::enable().is_ok()
}

/// Raw mode currently enabled by a guard (read by the panic hook and the
/// terminating-signal handlers). The lock spans the mode switch itself, so a
/// concurrent restore either runs before raw mode starts or sees it active —
/// never in between.
static RAW_ACTIVE: Mutex<bool> = Mutex::new(false);

fn raw_state() -> MutexGuard<'static, bool> {
    RAW_ACTIVE.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Restores cooked mode on every exit path, including early returns.
struct RawModeGuard;

impl RawModeGuard {
    fn enable() -> std::io::Result<Self> {
        let mut active = raw_state();
        crossterm::terminal::enable_raw_mode()?;
        *active = true;
        Ok(Self)
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        let mut active = raw_state();
        if std::mem::take(&mut *active) {
            let _ = crossterm::terminal::disable_raw_mode();
        }
    }
}

/// How long a restore waits for another thread's mode switch to finish.
const RESTORE_ATTEMPTS: u32 = 200;

/// Panic hook and terminating signals: the process exits right after without
/// unwinding, so guards never run. The lock is kept until exit so no thread
/// re-enters raw mode in between. A panic inside a mode switch on this very
/// thread holds the lock; the bounded wait keeps that case from hanging.
pub fn restore_console() {
    for _ in 0..RESTORE_ATTEMPTS {
        let mut active = match RAW_ACTIVE.try_lock() {
            Ok(active) => active,
            Err(TryLockError::Poisoned(poisoned)) => poisoned.into_inner(),
            Err(TryLockError::WouldBlock) => {
                std::thread::sleep(Duration::from_millis(5));
                continue;
            }
        };
        if std::mem::take(&mut *active) {
            let _ = crossterm::terminal::disable_raw_mode();
        }
        std::mem::forget(active);
        return;
    }
}

/// Read one hidden line from the console. `Ok(None)` means the entry was
/// cancelled (Ctrl+C / Ctrl+D) or the console disappeared; the value may be
/// empty and always stays zeroized. Nothing is echoed: raw mode starts before
/// the prompt, so keys typed early are never echoed either.
pub fn read_hidden_line(prompt: &str) -> std::io::Result<Option<Zeroizing<String>>> {
    let _raw = RawModeGuard::enable()?;
    {
        let mut stderr = std::io::stderr().lock();
        write!(stderr, "{prompt}")?;
        stderr.flush()?;
    }
    let mut value = Zeroizing::new(String::new());
    loop {
        match crossterm::event::read()? {
            Event::Key(key) => {
                // Terminals with release reporting also deliver Release events;
                // only Press/Repeat are real input.
                if !matches!(key.kind, KeyEventKind::Press | KeyEventKind::Repeat) {
                    continue;
                }
                match key.code {
                    KeyCode::Enter | KeyCode::Char('\r') | KeyCode::Char('\n') => break,
                    KeyCode::Backspace => {
                        value.pop();
                    }
                    KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        return cancel();
                    }
                    KeyCode::Char('d') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        return cancel();
                    }
                    // A password line can never contain NUL (v1 `read -r` lines).
                    KeyCode::Char('\0') => {}
                    KeyCode::Char(c) => value.push(c),
                    _ => {}
                }
            }
            _ => {}
        }
    }
    echo_newline();
    Ok(Some(value))
}

fn cancel() -> std::io::Result<Option<Zeroizing<String>>> {
    echo_newline();
    Ok(None)
}

fn echo_newline() {
    let mut stderr = std::io::stderr().lock();
    let _ = writeln!(stderr);
    let _ = stderr.flush();
}

// ─── Interactive console (node shell) ────────────────────────────────────────

/// Input polling interval; bounds how long closing the console waits for
/// its reader thread.
const INPUT_POLL: Duration = Duration::from_millis(50);

/// The controlling terminal is attached and accepts raw mode.
pub fn console_attached() -> bool {
    terminal_attached() && raw_mode_works()
}

/// The controlling terminal of a terminal request (v1 `</dev/tty >/dev/tty`).
#[derive(Default)]
pub struct TerminalConsole {
    raw: Option<RawTerminal>,
}

impl TerminalConsole {
    pub fn new() -> Self {
        Self { raw: None }
    }
}

impl TerminalIo for TerminalConsole {
    fn term(&self) -> String {
        std::env::var("TERM").ok().filter(|term| !term.is_empty()).unwrap_or_else(|| "xterm-256color".into())
    }

    fn size(&self) -> (u16, u16) {
        match crossterm::terminal::size() {
            Ok((cols, rows)) if cols > 0 && rows > 0 => (cols, rows),
            _ => (80, 24),
        }
    }

    fn start(&mut self, events: Box<dyn Fn(TermEvent) + Send>) -> io::Result<()> {
        self.stop();
        let output = console_output()?;
        let raw = RawModeGuard::enable()?;
        let stop = Arc::new(AtomicBool::new(false));
        let reader = {
            let stop = stop.clone();
            std::thread::Builder::new().name("console-input".into()).spawn(move || read_input(&stop, &*events))?
        };
        self.raw = Some(RawTerminal { output, stop, reader: Some(reader), _raw: raw });
        Ok(())
    }

    fn write(&mut self, data: &[u8]) -> io::Result<()> {
        let raw = self.raw.as_mut().ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "Терминал не открыт."))?;
        raw.output.write_all(data)?;
        raw.output.flush()
    }

    /// Stops the input thread, then leaves raw mode.
    fn stop(&mut self) {
        self.raw = None;
    }
}

#[cfg(unix)]
fn terminal_attached() -> bool {
    std::fs::OpenOptions::new().read(true).write(true).open("/dev/tty").is_ok()
}

/// The console itself (`CONIN$`/`CONOUT$`), independent of redirected stdio.
#[cfg(not(unix))]
fn terminal_attached() -> bool {
    let open = |name: &str| std::fs::OpenOptions::new().read(true).write(true).open(name).is_ok();
    open("CONIN$") && open("CONOUT$")
}

/// Remote output goes to the terminal itself, never into a redirected stdout.
#[cfg(unix)]
fn console_output() -> io::Result<Box<dyn Write>> {
    Ok(Box::new(std::fs::OpenOptions::new().write(true).open("/dev/tty")?))
}

#[cfg(not(unix))]
fn console_output() -> io::Result<Box<dyn Write>> {
    // Remote menus use ANSI sequences; enable console VT processing.
    #[cfg(windows)]
    let _ = crossterm::ansi_support::supports_ansi();
    Ok(Box::new(std::fs::OpenOptions::new().read(true).write(true).open("CONOUT$")?))
}

/// Field order matters: the reader stops (Drop) before raw mode ends.
struct RawTerminal {
    output: Box<dyn Write>,
    stop: Arc<AtomicBool>,
    reader: Option<std::thread::JoinHandle<()>>,
    _raw: RawModeGuard,
}

impl Drop for RawTerminal {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

/// Console events until stopped; a console error ends input with `Closed`.
fn read_input(stop: &AtomicBool, events: &(dyn Fn(TermEvent) + Send)) {
    while !stop.load(Ordering::SeqCst) {
        let event = match crossterm::event::poll(INPUT_POLL) {
            Ok(false) => continue,
            Ok(true) => crossterm::event::read(),
            Err(error) => Err(error),
        };
        let event = match event {
            Ok(Event::Key(key)) => key_bytes(key).map(|bytes| TermEvent::Input(Zeroizing::new(bytes))),
            Ok(Event::Paste(text)) => Some(TermEvent::Input(Zeroizing::new(text.into_bytes()))),
            Ok(Event::Resize(cols, rows)) => Some(TermEvent::Resize { cols, rows }),
            Ok(_) => None,
            Err(_) => {
                events(TermEvent::Closed);
                return;
            }
        };
        if let Some(event) = event {
            events(event);
        }
    }
}

/// A key press as the bytes an xterm-compatible terminal sends.
fn key_bytes(key: KeyEvent) -> Option<Vec<u8>> {
    if !matches!(key.kind, KeyEventKind::Press | KeyEventKind::Repeat) {
        return None;
    }
    let sequence: &[u8] = match key.code {
        KeyCode::Char(c) => {
            let mut bytes = Vec::with_capacity(5);
            if key.modifiers.contains(KeyModifiers::ALT) {
                bytes.push(0x1b);
            }
            match c {
                '@' | 'a'..='z' | 'A'..='Z' | '[' | '\\' | ']' | '^' | '_' | ' ' | '?'
                    if key.modifiers.contains(KeyModifiers::CONTROL) =>
                {
                    bytes.push(match c {
                        ' ' => 0,
                        '?' => 0x7f,
                        _ => c.to_ascii_uppercase() as u8 & 0x1f,
                    });
                }
                _ => bytes.extend_from_slice(c.encode_utf8(&mut [0; 4]).as_bytes()),
            }
            return Some(bytes);
        }
        KeyCode::Enter => b"\r",
        KeyCode::Tab => b"\t",
        KeyCode::BackTab => b"\x1b[Z",
        KeyCode::Backspace => b"\x7f",
        KeyCode::Esc => b"\x1b",
        KeyCode::Up => b"\x1b[A",
        KeyCode::Down => b"\x1b[B",
        KeyCode::Right => b"\x1b[C",
        KeyCode::Left => b"\x1b[D",
        KeyCode::Home => b"\x1b[H",
        KeyCode::End => b"\x1b[F",
        KeyCode::Insert => b"\x1b[2~",
        KeyCode::Delete => b"\x1b[3~",
        KeyCode::PageUp => b"\x1b[5~",
        KeyCode::PageDown => b"\x1b[6~",
        KeyCode::F(n) => match n {
            1 => b"\x1bOP",
            2 => b"\x1bOQ",
            3 => b"\x1bOR",
            4 => b"\x1bOS",
            5 => b"\x1b[15~",
            6 => b"\x1b[17~",
            7 => b"\x1b[18~",
            8 => b"\x1b[19~",
            9 => b"\x1b[20~",
            10 => b"\x1b[21~",
            11 => b"\x1b[23~",
            12 => b"\x1b[24~",
            _ => return None,
        },
        _ => return None,
    };
    Some(sequence.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn press(code: KeyCode, modifiers: KeyModifiers) -> Option<Vec<u8>> {
        key_bytes(KeyEvent::new(code, modifiers))
    }

    #[test]
    fn keys_encode_as_terminal_bytes() {
        assert_eq!(press(KeyCode::Char('0'), KeyModifiers::NONE), Some(b"0".to_vec()));
        assert_eq!(press(KeyCode::Char('я'), KeyModifiers::SHIFT), Some("я".as_bytes().to_vec()));
        assert_eq!(press(KeyCode::Char('c'), KeyModifiers::CONTROL), Some(vec![0x03]));
        assert_eq!(press(KeyCode::Char('D'), KeyModifiers::CONTROL), Some(vec![0x04]));
        assert_eq!(press(KeyCode::Char('x'), KeyModifiers::ALT), Some(b"\x1bx".to_vec()));
        assert_eq!(press(KeyCode::Enter, KeyModifiers::NONE), Some(b"\r".to_vec()));
        assert_eq!(press(KeyCode::Up, KeyModifiers::NONE), Some(b"\x1b[A".to_vec()));
        assert_eq!(press(KeyCode::F(5), KeyModifiers::NONE), Some(b"\x1b[15~".to_vec()));
        let mut release = KeyEvent::new(KeyCode::Char('a'), KeyModifiers::NONE);
        release.kind = KeyEventKind::Release;
        assert_eq!(key_bytes(release), None);
    }
}
