//! `web run` и `web open` (план 2.4, П8, П9): клиент локального демона.
//!
//! Открытие панели: `web link` → ссылка в stdout → без `--no-open` браузер.
//! Одноразовая ссылка не попадает в аргументы внешних программ: в каталог
//! времени выполнения пишется `<h>-open-<16 hex>.html` (только владелец) с
//! `<meta http-equiv="refresh">`, браузер открывает путь к этому файлу;
//! файл удаляется через 30 с либо при выходе CLI.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use essence_rc_client::{self as client, Client, DaemonClient, Endpoint, Reply, Request, SpawnDaemon};
use rc_core::VERSION;
use rc_core::cli::Invocation;
use rc_core::error::{RcError, Result};
use rc_core::secure_fs;
use rc_core::state::StatePaths;
use serde_json::{Value, json};

use crate::oneshot::{self, Outcome, Output, local};

/// Сколько живёт файл перенаправления.
const OPEN_FILE_LIFETIME: Duration = Duration::from_secs(30);
/// Сколько ждать демон после чужого `self update`.
const UPDATE_RECONNECT: Duration = Duration::from_secs(30);
const RECONNECT_RETRY: Duration = Duration::from_millis(500);
/// Период проверки сигнала остановки между событиями демона.
const POLL: Duration = Duration::from_millis(200);

// ─── Чистые части ────────────────────────────────────────────────────────────

/// Экранирование значения HTML-атрибута.
fn escape_attribute(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '&' => escaped.push_str("&amp;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#39;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            _ => escaped.push(ch),
        }
    }
    escaped
}

/// Страница перенаправления на `url`.
fn redirect_page(url: &str) -> String {
    let url = escape_attribute(url);
    format!(
        "<!doctype html>\n<html lang=\"ru\"><head><meta charset=\"utf-8\">\
         <meta name=\"referrer\" content=\"no-referrer\">\
         <meta http-equiv=\"refresh\" content=\"0;url={url}\">\
         <title>essence-rc</title></head><body></body></html>\n"
    )
}

/// `<h>-open-<16 hex>.html`.
fn open_file_name(endpoint_id: &str, random: u64) -> String {
    format!("{endpoint_id}-open-{random:016x}.html")
}

/// Программа, открывающая файл в браузере: `xdg-open` / `open` / `explorer`
/// (не `cmd /C start`: разбор `& ^ %` командной строкой cmd).
fn opener(path: &Path) -> (&'static str, Vec<String>) {
    let path = path.to_string_lossy().into_owned();
    if cfg!(windows) {
        ("explorer", vec![path])
    } else if cfg!(target_os = "macos") {
        ("open", vec![path])
    } else {
        ("xdg-open", vec![path])
    }
}

/// Событие конца чужого (или своего) `self update`.
fn update_finished(event: &Value) -> bool {
    event["event"] == "activity" && event["state"] == "end" && event["command"] == "self update"
}

// ─── Файл перенаправления ────────────────────────────────────────────────────

/// Удаляет файл при выходе (и через 30 с — фоновым потоком).
struct OpenFile(PathBuf);

impl Drop for OpenFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn write_open_file(endpoint: &Endpoint, url: &str) -> io::Result<PathBuf> {
    client::verify_runtime_dir(&endpoint.runtime_dir)?;
    let path = endpoint.runtime_dir.join(open_file_name(&endpoint.id, rand::random()));
    let mut file = secure_fs::create_new(&path)?;
    if let Err(error) = file.write_all(redirect_page(url).as_bytes()).and_then(|()| file.sync_all()) {
        let _ = fs::remove_file(&path);
        return Err(error);
    }
    Ok(path)
}

/// Запустить программу с отброшенным выводом; сбой игнорируется, процесс
/// дожидается фоновый поток.
fn spawn_quiet(program: &str, args: &[String], env: &[(&str, &Path)]) {
    let mut command = Command::new(program);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    for (name, value) in env {
        command.env(name, value);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    if let Ok(mut child) = command.spawn() {
        std::thread::spawn(move || {
            let _ = child.wait();
        });
    }
}

/// Удаление файла через 30 с процессом, переживающим CLI (`web open`
/// завершается сразу). Аргументом идёт только путь — без ссылки.
fn remove_later(path: &Path) {
    // Путь — переменной окружения: в текст сценария он не подставляется.
    let seconds = OPEN_FILE_LIFETIME.as_secs();
    let env = [("ESSENCE_RC_OPEN_FILE", path)];
    if cfg!(windows) {
        let script = format!("Start-Sleep -Seconds {seconds}; Remove-Item -LiteralPath $env:ESSENCE_RC_OPEN_FILE -Force -ErrorAction SilentlyContinue");
        spawn_quiet("powershell", &["-NoProfile".into(), "-NonInteractive".into(), "-Command".into(), script], &env);
    } else {
        let script = format!("sleep {seconds}; rm -f -- \"$ESSENCE_RC_OPEN_FILE\"");
        spawn_quiet("sh", &["-c".into(), script], &env);
    }
}

/// Открыть ссылку в браузере через файл перенаправления. `keep` — CLI
/// остаётся жить (`web run`): файл удаляет он сам; иначе — внешний таймер.
fn launch(endpoint: &Endpoint, url: &str, keep: bool) -> Option<OpenFile> {
    let path = write_open_file(endpoint, url).ok()?;
    let (program, args) = opener(&path);
    spawn_quiet(program, &args, &[]);
    if keep {
        let later = path.clone();
        std::thread::spawn(move || {
            std::thread::sleep(OPEN_FILE_LIFETIME);
            let _ = fs::remove_file(later);
        });
        Some(OpenFile(path))
    } else {
        remove_later(&path);
        None
    }
}

// ─── Запросы ─────────────────────────────────────────────────────────────────

fn call(client: &mut DaemonClient, argv: Vec<String>) -> Outcome<Reply> {
    let (secrets, input) = (client::Secrets::default(), client::Input::default());
    client
        .send(Request::new(&argv, &secrets, &input), &mut |_| {})
        .map_err(|error| local(oneshot::request_error(&error)))
}

/// Ответ команды или конверт её ошибки.
fn ok(reply: Reply) -> Outcome<Value> {
    if reply.ok { Ok(reply.data) } else { Err(Box::new(oneshot::output_from_reply(reply))) }
}

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

/// `web link` → ссылка (stdout или конверт) → браузер без `--no-open`.
fn open_panel(client: &mut DaemonClient, endpoint: &Endpoint, invocation: &Invocation, keep: bool) -> Outcome<(Value, Option<OpenFile>)> {
    let link = ok(call(client, words(&["web", "link"]))?)?;
    let url = link["url"].as_str().unwrap_or_default().to_owned();
    if !invocation.json {
        let mut stdout = io::stdout().lock();
        let _ = writeln!(stdout, "{url}");
        let _ = stdout.flush();
    }
    let file = if invocation.has("no-open") { None } else { launch(endpoint, &url, keep) };
    Ok((link, file))
}

fn print_line(text: &str) {
    let _ = writeln!(io::stderr().lock(), "{text}");
}

// ─── web open ────────────────────────────────────────────────────────────────

fn not_running() -> RcError {
    RcError::new("not_configured", "Веб-панель не запущена: essence-rc web run.")
}

/// Подключение к уже работающему демону (без запуска).
fn connect_existing() -> Result<(DaemonClient, Endpoint)> {
    let root = StatePaths::discover()?.root().to_owned();
    let endpoint = client::endpoint_for(&root).map_err(|error| oneshot::client_error(&error))?;
    let exe = std::env::current_exe().map_err(|error| oneshot::failed(format!("Не удалось определить исполняемый файл: {error}")))?;
    match DaemonClient::connect_local(&endpoint, None, Some(VERSION), Some(&exe)) {
        Ok(client) => Ok((client, endpoint)),
        Err(error) if matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused) => Err(not_running()),
        Err(error) => Err(oneshot::client_error(&error)),
    }
}

/// `web open`: панель не запущена → `not_configured`; иначе открытие.
pub fn open(invocation: &Invocation) -> ExitCode {
    let output = (|| -> Outcome<Output> {
        let (mut client, endpoint) = connect_existing().map_err(local)?;
        let status = ok(call(&mut client, words(&["web", "status"]))?)?;
        if status["enabled"] != true {
            return Err(local(not_running()));
        }
        let (link, _) = open_panel(&mut client, &endpoint, invocation, false)?;
        let _ = client.close();
        Ok(Output::success(link))
    })();
    finish_link(output, invocation)
}

/// Итог открытия: в человекочитаемом режиме ссылка уже напечатана.
fn finish_link(output: Outcome<Output>, invocation: &Invocation) -> ExitCode {
    match output {
        Ok(output) if !invocation.json => ExitCode::from(output.exit_code()),
        Ok(output) => oneshot::finish(output, true, Some(invocation)),
        Err(output) => oneshot::finish(*output, invocation.json, Some(invocation)),
    }
}

// ─── web run ─────────────────────────────────────────────────────────────────

/// SIGINT/SIGTERM/SIGHUP (Windows: Ctrl+C, Ctrl+Break, закрытие консоли,
/// выход из системы, выключение) поднимают флаг остановки.
fn stop_signals(runtime: &tokio::runtime::Runtime, stop: &Arc<AtomicBool>) {
    let _context = runtime.enter();
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        for kind in [SignalKind::interrupt(), SignalKind::terminate(), SignalKind::hangup()] {
            if let Ok(mut stream) = signal(kind) {
                let stop = stop.clone();
                runtime.spawn(async move {
                    while stream.recv().await.is_some() {
                        stop.store(true, Ordering::SeqCst);
                    }
                });
            }
        }
    }
    #[cfg(windows)]
    {
        use tokio::signal::windows;
        macro_rules! on_event {
            ($constructor:path) => {
                if let Ok(mut stream) = $constructor() {
                    let stop = stop.clone();
                    runtime.spawn(async move {
                        while stream.recv().await.is_some() {
                            stop.store(true, Ordering::SeqCst);
                        }
                    });
                }
            };
        }
        on_event!(windows::ctrl_c);
        on_event!(windows::ctrl_break);
        on_event!(windows::ctrl_close);
        on_event!(windows::ctrl_logoff);
        on_event!(windows::ctrl_shutdown);
    }
}

/// Слушатель запущен этим вызовом: строка адреса, отпечаток сертификата
/// (TLS) и предупреждение об открытой панели.
fn announce(status: &Value) {
    oneshot::warn_open_panel(status);
    print_line(&format!("  [*] Веб-панель: {}", status["url"].as_str().unwrap_or_default()));
    // Сверяется с вопросом клиента `--connect` о неизвестном сертификате.
    if let Some(fingerprint) = status["fingerprint"].as_str() {
        print_line(&format!("  [*] Отпечаток сертификата: {fingerprint}"));
    }
}

/// После обрыва из-за `self update`: подключиться (запустив демон) за 30 с
/// и вернуть слушатель, если новый демон пришёл без него.
fn reconnect(endpoint: &Endpoint, flags: &[String], stop: &AtomicBool) -> Option<DaemonClient> {
    let exe = std::env::current_exe().ok()?;
    let spawn = SpawnDaemon { exe, args: words(&["daemon", "run"]), env: Vec::new() };
    let deadline = Instant::now() + UPDATE_RECONNECT;
    loop {
        if stop.load(Ordering::SeqCst) {
            return None;
        }
        // Версия и исполняемый файл обновились: не сверяются.
        if let Ok(mut client) = DaemonClient::connect_local(endpoint, Some(&spawn), None, None) {
            let status = ok(call(&mut client, words(&["web", "status"])).ok()?).ok()?;
            if status["enabled"] != true {
                let started = ok(call(&mut client, [words(&["web", "start"]), flags.to_vec()].concat()).ok()?).ok()?;
                announce(&started);
            }
            client.set_watch(true).ok()?;
            return Some(client);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(RECONNECT_RETRY);
    }
}

enum Waited {
    Stop,
    DaemonGone,
}

/// Ждать сигнала остановки, удерживая соединение; обрыв после конца
/// `self update` — переподключение.
fn wait(client: &mut DaemonClient, endpoint: &Endpoint, flags: &[String], stop: &AtomicBool) -> Waited {
    let mut updating = false;
    loop {
        if stop.load(Ordering::SeqCst) {
            return Waited::Stop;
        }
        match client.next_event(POLL) {
            Ok(Some(event)) => {
                if event["state"] == "start" {
                    updating = false;
                }
                if update_finished(&event) {
                    updating = true;
                }
            }
            Ok(None) => {}
            Err(_) if updating => match reconnect(endpoint, flags, stop) {
                Some(fresh) => {
                    *client = fresh;
                    updating = false;
                }
                None if stop.load(Ordering::SeqCst) => return Waited::Stop,
                None => return Waited::DaemonGone,
            },
            Err(_) => return Waited::DaemonGone,
        }
    }
}

/// `web run [флаги] [--no-open]`.
pub fn run(invocation: &Invocation) -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            let error = oneshot::failed(format!("Не удалось запустить среду выполнения: {error}"));
            return oneshot::finish(Output::from_error(error), invocation.json, Some(invocation));
        }
    };
    let stop = Arc::new(AtomicBool::new(false));
    stop_signals(&runtime, &stop);
    let flags = match oneshot::listener_flags(invocation) {
        Ok(flags) => flags,
        Err(error) => return oneshot::finish(Output::from_error(error), invocation.json, Some(invocation)),
    };
    let started = (|| -> Outcome<Option<(DaemonClient, Endpoint, Option<OpenFile>)>> {
        let (mut client, endpoint) = oneshot::connect().map_err(local)?;
        let status = ok(call(&mut client, words(&["web", "status"]))?)?;
        if status["enabled"] == true {
            // Уже запущена (службой или другим вызовом): только открыть.
            let (link, _) = open_panel(&mut client, &endpoint, invocation, false)?;
            let _ = client.close();
            if invocation.json {
                oneshot::finish(Output::success(link), true, Some(invocation));
            }
            return Ok(None);
        }
        let status = ok(call(&mut client, [words(&["web", "start"]), flags.clone()].concat())?)?;
        let (link, file) = open_panel(&mut client, &endpoint, invocation, true)?;
        announce(&status);
        print_line("  [*] Ctrl+C — остановить.");
        if invocation.json {
            oneshot::finish(Output::success(json!({"web": status, "link": link})), true, Some(invocation));
        }
        client.set_watch(true).map_err(|error| local(oneshot::request_error(&error)))?;
        Ok(Some((client, endpoint, file)))
    })();
    let (mut client, endpoint, _file) = match started {
        Ok(Some(running)) => running,
        Ok(None) => return ExitCode::SUCCESS,
        Err(output) => return oneshot::finish(*output, invocation.json, Some(invocation)),
    };
    match wait(&mut client, &endpoint, &flags, &stop) {
        Waited::DaemonGone => {
            print_line("  [!] Демон остановлен.");
            ExitCode::FAILURE
        }
        Waited::Stop => {
            let stopped = call(&mut client, words(&["web", "stop"])).and_then(ok);
            let _ = client.close();
            match stopped {
                Ok(_) => {
                    print_line("  [*] Веб-панель остановлена.");
                    ExitCode::SUCCESS
                }
                // Конверт уже напечатан в режиме --json: ошибка — только в stderr.
                Err(output) if invocation.json => {
                    print_line(&format!("  [✗] {}", output.message()));
                    ExitCode::from(output.exit_code())
                }
                Err(output) => oneshot::finish(*output, false, Some(invocation)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redirect_page_escapes_the_link() {
        let page = redirect_page("http://127.0.0.1:8377/#ticket=ab\"><script>&'");
        assert!(page.contains("content=\"0;url=http://127.0.0.1:8377/#ticket=ab&quot;&gt;&lt;script&gt;&amp;&#39;\""), "{page}");
        assert!(!page.contains("<script>"));
        assert!(page.contains("<meta name=\"referrer\" content=\"no-referrer\">"));
        let plain = redirect_page("https://[::1]:8443/");
        assert!(plain.contains("content=\"0;url=https://[::1]:8443/\""));
    }

    #[test]
    fn open_file_names() {
        assert_eq!(open_file_name("0123456789abcdef", 0xab), "0123456789abcdef-open-00000000000000ab.html");
        assert_eq!(open_file_name("h", u64::MAX), "h-open-ffffffffffffffff.html");
    }

    #[test]
    fn opener_receives_only_the_file_path() {
        let path = Path::new("/run/essence-rc/h-open-1.html");
        let (program, args) = opener(path);
        assert!(!program.is_empty());
        assert_eq!(args.last().map(String::as_str), Some(path.to_string_lossy().as_ref()));
        assert!(args.iter().all(|arg| !arg.contains("ticket")));
        #[cfg(target_os = "linux")]
        assert_eq!((program, args.len()), ("xdg-open", 1));
    }

    #[test]
    fn update_end_is_recognised() {
        assert!(update_finished(&json!({"event":"activity","state":"end","command":"self update","origin":"local"})));
        assert!(!update_finished(&json!({"event":"activity","state":"start","command":"self update"})));
        assert!(!update_finished(&json!({"event":"activity","state":"end","command":"node list"})));
    }

    #[cfg(unix)]
    #[test]
    fn open_file_is_private_and_removed_on_drop() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::Builder::new().prefix("rc").tempdir_in("/tmp").unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let endpoint = client::endpoint_in(dir.path(), Path::new("/data")).unwrap();
        let path = write_open_file(&endpoint, "http://127.0.0.1:1/#ticket=x").unwrap();
        assert_eq!(path.parent(), Some(dir.path()));
        assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert!(fs::read_to_string(&path).unwrap().contains("ticket=x"));
        drop(OpenFile(path.clone()));
        assert!(!path.exists());
    }
}
