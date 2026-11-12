//! `web install-service`, `web uninstall-service` (план 3.1, П5, П9, П12):
//! автозапуск постоянного демона с веб-панелью.
//!
//! Linux с systemd — unit `essence-rc-web.service` (системный от root,
//! иначе пользовательский); macOS — LaunchAgent `com.essence-rc.web`;
//! Windows — задача `essence-rc-web` планировщика, при отказе — файл
//! `essence-rc-web.cmd` в папке автозагрузки. Каталог данных передаётся
//! флагом `--data-dir`, `ESSENCE_RC_RUNTIME_DIR` — только заданный явно.
//! Внешние программы запускаются без shell; вся генерация — чистые функции.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::{Duration, Instant};

use essence_rc_client::{self as client, Client, DaemonClient, Endpoint, Input, Request, Secrets};
use rc_core::cli::Invocation;
use rc_core::error::{RcError, Result};
use rc_core::secure_fs;
use rc_core::state::StatePaths;
use serde_json::{Value, json};

use crate::oneshot::{self, Output};

pub const UNIT_NAME: &str = "essence-rc-web.service";
pub const PLIST_LABEL: &str = "com.essence-rc.web";
pub const TASK_NAME: &str = "essence-rc-web";
const STARTUP_FILE: &str = "essence-rc-web.cmd";
/// Признак systemd (тесты подменяют `ESSENCE_RC_SYSTEMD_DIR`).
const SYSTEMD_DIR: &str = "/run/systemd/system";
/// Сколько ждать выхода остановленного демона.
const STOP_WAIT: Duration = Duration::from_secs(30);
/// Сколько ждать запущенную службу, чтобы узнать `web.open`.
const STATUS_WAIT: Duration = Duration::from_secs(5);
/// Пауза между попытками `launchctl bootstrap` (после `bootout` агент
/// выгружается асинхронно).
const RETRY_PAUSE: Duration = Duration::from_millis(500);

// ─── Что запускать ───────────────────────────────────────────────────────────

/// Команда службы: исполняемый файл, каталог данных, флаги слушателя и
/// (если задан явно) каталог времени выполнения.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Launch {
    pub exe: PathBuf,
    pub data_dir: PathBuf,
    pub flags: Vec<String>,
    pub runtime_dir: Option<PathBuf>,
}

impl Launch {
    /// `<exe> daemon <verb> --web --data-dir <каталог> <флаги>`.
    fn argv(&self, verb: &str) -> Vec<String> {
        let mut argv = vec![
            self.exe.to_string_lossy().into_owned(),
            "daemon".into(),
            verb.into(),
            "--web".into(),
            "--data-dir".into(),
            self.data_dir.to_string_lossy().into_owned(),
        ];
        argv.extend(self.flags.iter().cloned());
        argv
    }
}

/// Windows: `canonicalize` даёт `\\?\C:\…`; задаче и файлу автозагрузки
/// нужен обычный путь с буквой диска (UNC-форму `\\?\UNC\` не трогаем).
fn strip_verbatim(path: PathBuf) -> PathBuf {
    match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
        Some(rest) if rest.as_bytes().get(1) == Some(&b':') => PathBuf::from(rest),
        _ => path,
    }
}

/// Управляющие символы в путях и аргументах службы недопустимы.
fn reject_control(launch: &Launch) -> Result<()> {
    let mut words = launch.argv("run");
    if let Some(dir) = &launch.runtime_dir {
        words.push(dir.to_string_lossy().into_owned());
    }
    if words.iter().any(|word| word.chars().any(char::is_control)) {
        return Err(RcError::new("invalid", "Путь или аргумент службы содержит управляющие символы."));
    }
    Ok(())
}

// ─── systemd ─────────────────────────────────────────────────────────────────

/// Значение в двойных кавычках по правилам systemd: `\\`, `\"`, `%%`;
/// `$` → `$$` только в `ExecStart` (подстановка переменных).
fn systemd_quote(value: &str, exec: bool) -> String {
    let mut quoted = String::with_capacity(value.len() + 2);
    quoted.push('"');
    for ch in value.chars() {
        match ch {
            '\\' => quoted.push_str("\\\\"),
            '"' => quoted.push_str("\\\""),
            '%' => quoted.push_str("%%"),
            '$' if exec => quoted.push_str("$$"),
            _ => quoted.push(ch),
        }
    }
    quoted.push('"');
    quoted
}

/// Текст unit-файла; `system` — системный (от root).
fn unit_text(launch: &Launch, system: bool) -> String {
    let exec: Vec<String> = launch.argv("run").iter().map(|word| systemd_quote(word, true)).collect();
    let mut text = String::from("[Unit]\nDescription=essence-rc web panel\nAfter=network-online.target\n\n[Service]\n");
    text.push_str(&format!("ExecStart={}\nRestart=always\nRestartSec=2\n", exec.join(" ")));
    if let Some(dir) = &launch.runtime_dir {
        let assignment = format!("ESSENCE_RC_RUNTIME_DIR={}", dir.to_string_lossy());
        text.push_str(&format!("Environment={}\n", systemd_quote(&assignment, false)));
    }
    let target = if system { "multi-user.target" } else { "default.target" };
    text.push_str(&format!("\n[Install]\nWantedBy={target}\n"));
    text
}

// ─── launchd ─────────────────────────────────────────────────────────────────

fn xml_escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&apos;"),
            _ => escaped.push(ch),
        }
    }
    escaped
}

fn plist_text(launch: &Launch) -> String {
    let mut text = String::from(concat!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n",
        "<plist version=\"1.0\">\n<dict>\n",
    ));
    text.push_str(&format!("  <key>Label</key>\n  <string>{PLIST_LABEL}</string>\n  <key>ProgramArguments</key>\n  <array>\n"));
    for word in launch.argv("run") {
        text.push_str(&format!("    <string>{}</string>\n", xml_escape(&word)));
    }
    text.push_str("  </array>\n  <key>RunAtLoad</key>\n  <true/>\n  <key>KeepAlive</key>\n  <true/>\n");
    if let Some(dir) = &launch.runtime_dir {
        text.push_str(&format!(
            "  <key>EnvironmentVariables</key>\n  <dict>\n    <key>ESSENCE_RC_RUNTIME_DIR</key>\n    <string>{}</string>\n  </dict>\n",
            xml_escape(&dir.to_string_lossy())
        ));
    }
    text.push_str("</dict>\n</plist>\n");
    text
}

// ─── Windows ─────────────────────────────────────────────────────────────────

/// Аргумент командной строки Windows (правила `CommandLineToArgvW`).
fn windows_quote(arg: &str) -> String {
    if !arg.is_empty() && !arg.contains([' ', '\t', '"']) {
        return arg.to_owned();
    }
    let mut quoted = String::from('"');
    let mut backslashes = 0;
    for ch in arg.chars() {
        match ch {
            '\\' => backslashes += 1,
            '"' => {
                quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
                quoted.push('"');
                backslashes = 0;
            }
            _ => {
                quoted.push_str(&"\\".repeat(backslashes));
                quoted.push(ch);
                backslashes = 0;
            }
        }
    }
    quoted.push_str(&"\\".repeat(backslashes * 2));
    quoted.push('"');
    quoted
}

/// Командная строка задачи (`/TR`): `daemon start` вместо `daemon run`.
fn task_command(launch: &Launch) -> String {
    launch.argv("start").iter().map(|word| windows_quote(word)).collect::<Vec<_>>().join(" ")
}

fn schtasks_create(launch: &Launch) -> Vec<String> {
    ["/Create", "/TN", TASK_NAME, "/SC", "ONLOGON", "/RL", "LIMITED", "/F", "/TR"]
        .iter()
        .map(|word| (*word).to_owned())
        .chain([task_command(launch)])
        .collect()
}

/// Слово строки `.cmd`: всегда в двойных кавычках (внутри них `& ^ | ( )`
/// не разбираются, а `"` в путях Windows невозможна), `%` удваивается.
fn cmd_word(word: &str) -> String {
    // Обратные косые черты в конце удваиваются: иначе `\"` экранирует кавычку
    // (`CommandLineToArgvW`), как в `windows_quote`.
    let trailing = word.len() - word.trim_end_matches('\\').len();
    format!("\"{}{}\"", word.replace('%', "%%"), "\\".repeat(trailing))
}

/// Файл автозагрузки (запасной путь): та же команда, что у задачи.
fn startup_script(launch: &Launch) -> String {
    let mut text = String::from("@echo off\r\n");
    if let Some(dir) = &launch.runtime_dir {
        text.push_str(&format!("set \"ESSENCE_RC_RUNTIME_DIR={}\"\r\n", dir.to_string_lossy().replace('%', "%%")));
    }
    let line: Vec<String> = launch.argv("start").iter().map(|word| cmd_word(word)).collect();
    text.push_str(&line.join(" "));
    text.push_str("\r\n");
    text
}

// ─── Служба от root ──────────────────────────────────────────────────────────

/// Владелец и режим пути (`None` — не существует).
type Lookup<'a> = &'a dyn Fn(&Path) -> Option<(u32, u32)>;

/// euid 0: путь и все его предки — владелец root, без записи группой и
/// прочими; несуществующие хвосты пропускаются.
fn root_tree_reason(path: &Path, lookup: Lookup<'_>) -> Option<String> {
    for dir in path.ancestors().filter(|dir| !dir.as_os_str().is_empty()) {
        let Some((uid, mode)) = lookup(dir) else { continue };
        if uid != 0 || mode & 0o022 != 0 {
            return Some(format!(
                "{} должен принадлежать root и быть недоступен на запись группе и прочим.",
                dir.display()
            ));
        }
    }
    None
}

#[cfg(unix)]
fn euid() -> u32 {
    // SAFETY: geteuid has no preconditions and cannot fail.
    unsafe { libc::geteuid() }
}

#[cfg(unix)]
fn check_root_owned(launch: &Launch) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    if euid() != 0 {
        return Ok(());
    }
    let lookup = |path: &Path| fs::symlink_metadata(path).ok().map(|meta| (meta.uid(), meta.mode()));
    for path in [&launch.exe, &launch.data_dir] {
        // Существующая часть пути — без ссылок: проверяются настоящие каталоги.
        let resolved = canonical_prefix(path);
        if let Some(reason) = root_tree_reason(&resolved, &lookup) {
            return Err(RcError::new("unsafe_path", format!("Служба от root небезопасна: {reason}")));
        }
    }
    Ok(())
}

/// Каноническая существующая часть пути плюс несуществующий хвост.
#[cfg(unix)]
fn canonical_prefix(path: &Path) -> PathBuf {
    for base in path.ancestors() {
        if let Ok(canonical) = fs::canonicalize(base) {
            return path.strip_prefix(base).map_or(canonical.clone(), |rest| canonical.join(rest));
        }
    }
    path.to_owned()
}

#[cfg(not(unix))]
fn check_root_owned(_: &Launch) -> Result<()> {
    Ok(())
}

// ─── Платформа ───────────────────────────────────────────────────────────────

#[derive(Clone, Debug, PartialEq, Eq)]
enum Kind {
    /// Unit-файл и признак системного (root).
    Systemd { unit: PathBuf, system: bool },
    Launchd { plist: PathBuf },
    Windows { startup: PathBuf },
    Unsupported,
}

fn systemd_present() -> bool {
    let dir = std::env::var_os("ESSENCE_RC_SYSTEMD_DIR").map_or_else(|| PathBuf::from(SYSTEMD_DIR), PathBuf::from);
    dir.is_dir()
}

/// `$XDG_CONFIG_HOME` (абсолютный), иначе `~/.config`.
fn config_home() -> Option<PathBuf> {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|dir| dir.is_absolute())
        .or_else(|| dirs::home_dir().map(|home| home.join(".config")))
}

fn kind() -> Kind {
    if cfg!(windows) {
        let startup = std::env::var_os("APPDATA").map(|appdata| {
            PathBuf::from(appdata).join(r"Microsoft\Windows\Start Menu\Programs\Startup").join(STARTUP_FILE)
        });
        return startup.map_or(Kind::Unsupported, |startup| Kind::Windows { startup });
    }
    if cfg!(target_os = "macos") {
        return dirs::home_dir().map_or(Kind::Unsupported, |home| Kind::Launchd {
            plist: home.join("Library/LaunchAgents").join(format!("{PLIST_LABEL}.plist")),
        });
    }
    #[cfg(unix)]
    if cfg!(target_os = "linux") && systemd_present() {
        if euid() == 0 {
            return Kind::Systemd { unit: Path::new("/etc/systemd/system").join(UNIT_NAME), system: true };
        }
        return config_home().map_or(Kind::Unsupported, |config| Kind::Systemd {
            unit: config.join("systemd/user").join(UNIT_NAME),
            system: false,
        });
    }
    Kind::Unsupported
}

/// Установлен ли автозапуск: unit-файл, plist, задача или файл автозагрузки.
pub fn installed() -> bool {
    match kind() {
        Kind::Systemd { unit, .. } => unit.exists(),
        Kind::Launchd { plist } => plist.exists(),
        Kind::Windows { startup } => {
            startup.exists()
                || Command::new("schtasks").args(["/Query", "/TN", TASK_NAME]).output().is_ok_and(|out| out.status.success())
        }
        Kind::Unsupported => false,
    }
}

// ─── Внешние команды ─────────────────────────────────────────────────────────

/// Последние строки stderr (stdout, если stderr пуст).
fn tail(output: &std::process::Output) -> String {
    let text = if output.stderr.is_empty() { &output.stdout } else { &output.stderr };
    let text = String::from_utf8_lossy(text);
    let lines: Vec<&str> = text.lines().filter(|line| !line.trim().is_empty()).collect();
    lines[lines.len().saturating_sub(5)..].join("\n")
}

/// Запуск программы без shell; ненулевой выход — `failed` с хвостом вывода.
fn run(program: &str, args: &[String]) -> Result<()> {
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|error| RcError::new("failed", format!("Не удалось запустить {program}: {error}")))?;
    if output.status.success() {
        return Ok(());
    }
    let tail = tail(&output);
    let detail = if tail.is_empty() { String::new() } else { format!("\n{tail}") };
    Err(RcError::new("failed", format!("Команда {program} {} завершилась ошибкой.{detail}", args.join(" "))))
}

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

fn systemctl(system: bool, args: &[&str]) -> Vec<String> {
    let mut argv = if system { Vec::new() } else { words(&["--user"]) };
    argv.extend(words(args));
    argv
}

#[cfg(unix)]
fn gui_domain() -> String {
    format!("gui/{}", euid())
}
#[cfg(not(unix))]
fn gui_domain() -> String {
    String::new()
}

// ─── Демон ───────────────────────────────────────────────────────────────────

fn endpoint(data_dir: &Path) -> Result<Endpoint> {
    client::endpoint_for(data_dir).map_err(|error| oneshot::client_error(&error))
}

fn call(client: &mut DaemonClient, argv: &[&str]) -> Option<client::Reply> {
    let argv = words(argv);
    client.send(Request::new(&argv, &Secrets::default(), &Input::default()), &mut |_| {}).ok()
}

/// Остановить работающий локальный демон и дождаться его выхода.
fn stop_running_daemon(endpoint: &Endpoint) {
    let Ok(mut client) = DaemonClient::connect_local(endpoint, None, None, None) else { return };
    if call(&mut client, &["daemon", "stop"]).is_none_or(|reply| !reply.ok) {
        return;
    }
    let deadline = Instant::now() + STOP_WAIT;
    while Instant::now() < deadline {
        if client.next_event(Duration::from_millis(200)).is_err() {
            break;
        }
    }
    let _ = client.close();
    // Сокет удаляется до снятия блокировки: ждать, пока точка не исчезнет.
    while Instant::now() < deadline && DaemonClient::connect_local(endpoint, None, None, None).is_ok() {
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// `web.open` запущенной службы (до [`STATUS_WAIT`]); `None` — не ответила.
fn service_web_status(endpoint: &Endpoint) -> Option<Value> {
    let deadline = Instant::now() + STATUS_WAIT;
    loop {
        if let Ok(mut client) = DaemonClient::connect_local(endpoint, None, None, None) {
            let status = call(&mut client, &["web", "status"]);
            let _ = client.close();
            if let Some(status) = status.filter(|status| status.ok && status.data["enabled"] == true) {
                return Some(status.data);
            }
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

// ─── Установка ───────────────────────────────────────────────────────────────

fn not_supported() -> RcError {
    RcError::new("not_supported", "Автозапуск на этой платформе не поддерживается. Запустите: essence-rc daemon run --web.")
}

fn launch_for(invocation: &Invocation) -> Result<Launch> {
    // Флаги проверяются той же функцией, что у `web start`, до любых изменений.
    crate::daemon::listener_plan(invocation)?;
    let flags = oneshot::listener_flags(invocation)?;
    let exe = std::env::current_exe()
        .and_then(fs::canonicalize)
        .map_err(|error| oneshot::failed(format!("Не удалось определить исполняемый файл: {error}")))?;
    let exe = strip_verbatim(exe);
    let root = StatePaths::discover()?.root().to_owned();
    let data_dir = std::path::absolute(&root)
        .map_err(|_| RcError::new("invalid", format!("Каталог данных {} недоступен.", root.display())))?;
    let runtime_dir = std::env::var_os("ESSENCE_RC_RUNTIME_DIR").filter(|dir| !dir.is_empty()).map(PathBuf::from);
    for path in [Some(&exe), Some(&data_dir), runtime_dir.as_ref()].into_iter().flatten() {
        if path.to_str().is_none() {
            return Err(RcError::new("invalid", format!("Путь {} не в кодировке UTF-8.", path.display())));
        }
    }
    let launch = Launch { exe, data_dir, flags, runtime_dir };
    reject_control(&launch)?;
    check_root_owned(&launch)?;
    Ok(launch)
}

/// Файл службы: каталог по необходимости, затем атомарная запись.
fn write_service_file(path: &Path, text: &str) -> Result<()> {
    let failed = |error: io::Error| RcError::new("failed", format!("Не удалось записать {}: {error}", path.display()));
    if let Some(parent) = path.parent() {
        secure_fs::create_dir_all(parent).map_err(failed)?;
    }
    secure_fs::atomic_write(path, text.as_bytes()).map_err(failed)
}

/// Шаг установки: программа, аргументы и число попыток (пауза 500 мс).
struct Step<'a> {
    program: &'a str,
    args: Vec<String>,
    attempts: u32,
}

impl<'a> Step<'a> {
    fn once(program: &'a str, args: Vec<String>) -> Self {
        Self { program, args, attempts: 1 }
    }

    fn run(&self) -> Result<()> {
        let mut attempt = 1;
        loop {
            match run(self.program, &self.args) {
                Err(_) if attempt < self.attempts => {
                    attempt += 1;
                    std::thread::sleep(RETRY_PAUSE);
                }
                result => return result,
            }
        }
    }
}

/// Записать файл и выполнить шаги. При сбое шага прежний файл
/// восстанавливается либо новый удаляется, затем `rollback(восстановлен)`
/// приводит службу в соответствие (ошибки отката не учитываются).
fn install_file(path: &Path, text: &str, steps: &[Step<'_>], rollback: &dyn Fn(bool)) -> Result<()> {
    let previous = fs::read(path).ok();
    write_service_file(path, text)?;
    for step in steps {
        if let Err(error) = step.run() {
            let restored = match &previous {
                Some(bytes) => secure_fs::atomic_write(path, bytes).is_ok(),
                None => {
                    let _ = fs::remove_file(path);
                    false
                }
            };
            rollback(restored);
            return Err(error);
        }
    }
    Ok(())
}

fn install_with(launch: &Launch, kind: Kind) -> Result<Value> {
    match kind {
        Kind::Systemd { unit, system } => {
            // `restart`, а не `--now`: повторная установка применяет новый unit
            // и к уже работающей службе.
            let steps = [
                Step::once("systemctl", systemctl(system, &["daemon-reload"])),
                Step::once("systemctl", systemctl(system, &["enable", UNIT_NAME])),
                Step::once("systemctl", systemctl(system, &["restart", UNIT_NAME])),
            ];
            // Откат: прежний unit — перечитать и вернуть в работу; нового не было —
            // выключить и перечитать.
            let rollback = |restored: bool| {
                if !restored {
                    let _ = run("systemctl", &systemctl(system, &["disable", "--now", UNIT_NAME]));
                }
                let _ = run("systemctl", &systemctl(system, &["daemon-reload"]));
                if restored {
                    let _ = run("systemctl", &systemctl(system, &["restart", UNIT_NAME]));
                }
            };
            install_file(&unit, &unit_text(launch, system), &steps, &rollback)?;
            if !system {
                let user = std::env::var("USER").or_else(|_| std::env::var("LOGNAME")).unwrap_or_else(|_| "$USER".into());
                let _ = writeln!(io::stderr().lock(), "  [*] Для запуска без входа в систему: loginctl enable-linger {user}");
            }
            Ok(json!({"service": "systemd", "unit": unit.to_string_lossy(), "started": true}))
        }
        Kind::Launchd { plist } => {
            let path = plist.to_string_lossy().into_owned();
            // Повторная установка: прежний агент выгружается (его может не быть).
            let _ = run("launchctl", &["bootout".into(), format!("{}/{PLIST_LABEL}", gui_domain())]);
            let bootstrap = vec!["bootstrap".into(), gui_domain(), path.clone()];
            // Откат: прежний агент загружается снова.
            let rollback = |restored: bool| {
                if restored {
                    let _ = run("launchctl", &bootstrap);
                }
            };
            let steps = [Step { program: "launchctl", args: bootstrap.clone(), attempts: 3 }];
            install_file(&plist, &plist_text(launch), &steps, &rollback)?;
            Ok(json!({"service": "launchd", "unit": path, "started": true}))
        }
        Kind::Windows { startup } => {
            if run("schtasks", &schtasks_create(launch)).is_ok() {
                // `/F` заменил задачу; работающий экземпляр прежней — остановить.
                let _ = run("schtasks", &words(&["/End", "/TN", TASK_NAME]));
                let started = run("schtasks", &words(&["/Run", "/TN", TASK_NAME])).is_ok();
                // Прежний запасной путь больше не нужен.
                let _ = fs::remove_file(&startup);
                return Ok(json!({"service": "schtasks", "unit": TASK_NAME, "started": started}));
            }
            // Планировщик недоступен (политика, права): папка автозагрузки;
            // прежняя задача, если осталась, удаляется, чтобы не было двух запусков.
            let _ = run("schtasks", &words(&["/Delete", "/TN", TASK_NAME, "/F"]));
            write_service_file(&startup, &startup_script(launch))?;
            let started = Command::new(&launch.exe).args(&launch.argv("start")[1..]).output().is_ok_and(|out| out.status.success());
            Ok(json!({"service": "startup", "unit": startup.to_string_lossy(), "started": started}))
        }
        Kind::Unsupported => Err(not_supported()),
    }
}

/// `web install-service [флаги]`.
pub fn install(invocation: &Invocation) -> ExitCode {
    let output = (|| -> Result<Output> {
        let launch = launch_for(invocation)?;
        let kind = kind();
        if kind == Kind::Unsupported {
            return Err(not_supported());
        }
        let endpoint = endpoint(&launch.data_dir)?;
        stop_running_daemon(&endpoint);
        let data = install_with(&launch, kind)?;
        let network = invocation.value("bind").and_then(|bind| bind.parse::<std::net::IpAddr>().ok())
            .is_some_and(|ip| !ip.to_canonical().is_loopback());
        if network && let Some(web) = service_web_status(&endpoint) {
            oneshot::warn_open_panel(&web);
        }
        Ok(Output::success(data))
    })();
    let output = output.unwrap_or_else(Output::from_error);
    oneshot::finish(output, invocation.json, Some(invocation))
}

// ─── Удаление ────────────────────────────────────────────────────────────────

fn uninstall_with(kind: Kind) -> Result<bool> {
    match kind {
        Kind::Systemd { unit, system } => {
            if !unit.exists() {
                return Ok(false);
            }
            // Уже выключенная служба — не ошибка удаления.
            let _ = run("systemctl", &systemctl(system, &["disable", "--now", UNIT_NAME]));
            fs::remove_file(&unit).map_err(|error| RcError::new("failed", format!("Не удалось удалить {}: {error}", unit.display())))?;
            run("systemctl", &systemctl(system, &["daemon-reload"]))?;
            Ok(true)
        }
        Kind::Launchd { plist } => {
            if !plist.exists() {
                return Ok(false);
            }
            let _ = run("launchctl", &[ "bootout".into(), format!("{}/{PLIST_LABEL}", gui_domain())]);
            fs::remove_file(&plist).map_err(|error| RcError::new("failed", format!("Не удалось удалить {}: {error}", plist.display())))?;
            Ok(true)
        }
        Kind::Windows { startup } => {
            let mut removed = false;
            let _ = run("schtasks", &words(&["/End", "/TN", TASK_NAME]));
            if run("schtasks", &words(&["/Delete", "/TN", TASK_NAME, "/F"])).is_ok() {
                removed = true;
            }
            if startup.exists() {
                fs::remove_file(&startup)
                    .map_err(|error| RcError::new("failed", format!("Не удалось удалить {}: {error}", startup.display())))?;
                removed = true;
            }
            Ok(removed)
        }
        Kind::Unsupported => Ok(false),
    }
}

/// `web uninstall-service`: сначала остановить локальный демон, затем
/// снять автозапуск. Службы нет → `{"removed":false}`.
pub fn uninstall(invocation: &Invocation) -> ExitCode {
    let output = (|| -> Result<Output> {
        let root = StatePaths::discover()?.root().to_owned();
        stop_running_daemon(&endpoint(&root)?);
        Ok(Output::success(json!({"removed": uninstall_with(kind())?})))
    })();
    let output = output.unwrap_or_else(Output::from_error);
    oneshot::finish(output, invocation.json, Some(invocation))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn launch(exe: &str, data: &str, runtime: Option<&str>) -> Launch {
        Launch {
            exe: PathBuf::from(exe),
            data_dir: PathBuf::from(data),
            flags: words(&["--bind", "0.0.0.0", "--port", "8443"]),
            runtime_dir: runtime.map(PathBuf::from),
        }
    }

    #[test]
    fn user_unit_without_runtime_dir() {
        let text = unit_text(&launch("/usr/local/bin/essence-rc", "/home/u/.local/share/essence-remote-control", None), false);
        assert_eq!(
            text,
            "[Unit]\nDescription=essence-rc web panel\nAfter=network-online.target\n\n[Service]\n\
             ExecStart=\"/usr/local/bin/essence-rc\" \"daemon\" \"run\" \"--web\" \"--data-dir\" \
             \"/home/u/.local/share/essence-remote-control\" \"--bind\" \"0.0.0.0\" \"--port\" \"8443\"\n\
             Restart=always\nRestartSec=2\n\n[Install]\nWantedBy=default.target\n"
        );
        assert!(!text.contains("Environment="), "the runtime dir is written only when set explicitly");
    }

    #[test]
    fn system_unit_escapes_spaces_percent_dollar_quotes_and_backslashes() {
        let text = unit_text(&launch("/opt/my rc/essence-rc", "/srv/50%$HOME/\"d\\", Some("/run/rc 1/%x")), true);
        assert!(text.contains("ExecStart=\"/opt/my rc/essence-rc\" "), "{text}");
        assert!(text.contains("\"--data-dir\" \"/srv/50%%$$HOME/\\\"d\\\\\""), "{text}");
        assert!(text.contains("Environment=\"ESSENCE_RC_RUNTIME_DIR=/run/rc 1/%%x\"\n"), "{text}");
        assert!(text.ends_with("WantedBy=multi-user.target\n"));
    }

    #[test]
    fn plist_escapes_xml_and_carries_environment() {
        let text = plist_text(&launch("/Applications/R&D <rc>/essence-rc", "/Users/u/data", Some("/tmp/r\"t")));
        assert!(text.contains("<string>com.essence-rc.web</string>"));
        assert!(text.contains("    <string>/Applications/R&amp;D &lt;rc&gt;/essence-rc</string>\n    <string>daemon</string>\n    <string>run</string>\n    <string>--web</string>\n    <string>--data-dir</string>\n    <string>/Users/u/data</string>"), "{text}");
        assert!(text.contains("<key>RunAtLoad</key>\n  <true/>\n  <key>KeepAlive</key>\n  <true/>"));
        assert!(text.contains("<key>ESSENCE_RC_RUNTIME_DIR</key>\n    <string>/tmp/r&quot;t</string>"));
        assert!(!plist_text(&launch("/a", "/b", None)).contains("EnvironmentVariables"));
    }

    #[test]
    fn schtasks_task_line_quotes_a_path_with_a_space() {
        let launch = launch(r"C:\Program Files\essence-rc\essence-rc.exe", r"C:\Users\A B\AppData\Roaming\essence", None);
        let args = schtasks_create(&launch);
        assert_eq!(&args[..9], words(&["/Create", "/TN", "essence-rc-web", "/SC", "ONLOGON", "/RL", "LIMITED", "/F", "/TR"]).as_slice());
        assert_eq!(
            args[9],
            r#""C:\Program Files\essence-rc\essence-rc.exe" daemon start --web --data-dir "C:\Users\A B\AppData\Roaming\essence" --bind 0.0.0.0 --port 8443"#
        );
    }

    #[test]
    fn windows_quoting_rules() {
        assert_eq!(windows_quote("plain"), "plain");
        assert_eq!(windows_quote(""), "\"\"");
        assert_eq!(windows_quote(r"C:\a b\"), r#""C:\a b\\""#);
        assert_eq!(windows_quote(r#"say "hi""#), r#""say \"hi\"""#);
    }

    #[test]
    fn startup_script_quotes_every_word_and_doubles_percent() {
        let text = startup_script(&launch(r"C:\R&D (x)\a^b|c\essence-rc.exe", r"C:\Users\100% & (u)\d", Some(r"C:\run\%TEMP%")));
        assert!(text.starts_with("@echo off\r\nset \"ESSENCE_RC_RUNTIME_DIR=C:\\run\\%%TEMP%%\"\r\n"), "{text}");
        let line = text.lines().nth(2).unwrap();
        assert_eq!(
            line,
            r#""C:\R&D (x)\a^b|c\essence-rc.exe" "daemon" "start" "--web" "--data-dir" "C:\Users\100%% & (u)\d" "--bind" "0.0.0.0" "--port" "8443""#
        );
        assert!(text.ends_with("\r\n"));
    }

    #[test]
    fn cmd_words_double_trailing_backslashes() {
        assert_eq!(cmd_word(r"D:\essence\"), r#""D:\essence\\""#);
        assert_eq!(cmd_word(r"D:\a\b"), r#""D:\a\b""#);
        assert_eq!(cmd_word("50%"), r#""50%%""#);
        let text = startup_script(&launch(r"C:\rc\essence-rc.exe", r"D:\essence\", None));
        assert!(text.contains(r#""--data-dir" "D:\essence\\" "--bind""#), "{text}");
    }

    #[test]
    fn verbatim_prefix_is_stripped_only_for_drive_paths() {
        assert_eq!(strip_verbatim(PathBuf::from(r"\\?\C:\rc\essence-rc.exe")), PathBuf::from(r"C:\rc\essence-rc.exe"));
        assert_eq!(strip_verbatim(PathBuf::from(r"\\?\UNC\srv\share\rc.exe")), PathBuf::from(r"\\?\UNC\srv\share\rc.exe"));
        assert_eq!(strip_verbatim(PathBuf::from("/usr/bin/essence-rc")), PathBuf::from("/usr/bin/essence-rc"));
    }

    #[test]
    fn control_characters_are_invalid() {
        assert!(reject_control(&launch("/bin/rc", "/data", None)).is_ok());
        assert_eq!(reject_control(&launch("/bin/r\nc", "/data", None)).unwrap_err().code, "invalid");
        assert_eq!(reject_control(&launch("/bin/rc", "/da\u{7}ta", None)).unwrap_err().code, "invalid");
        assert_eq!(reject_control(&launch("/bin/rc", "/data", Some("/run\t1"))).unwrap_err().code, "invalid");
    }

    #[test]
    fn root_tree_requires_root_owned_unshared_ancestors() {
        let tree = |entries: &'static [(&'static str, u32, u32)]| {
            move |path: &Path| entries.iter().find(|(name, _, _)| Path::new(name) == path).map(|(_, uid, mode)| (*uid, *mode))
        };
        let safe = tree(&[("/", 0, 0o755), ("/opt", 0, 0o755), ("/opt/rc", 0, 0o755)]);
        assert_eq!(root_tree_reason(Path::new("/opt/rc/new"), &safe), None, "missing tails are skipped");
        let foreign = tree(&[("/", 0, 0o755), ("/home", 0, 0o755), ("/home/u", 1000, 0o755)]);
        assert!(root_tree_reason(Path::new("/home/u/rc"), &foreign).unwrap().contains("/home/u"));
        let shared = tree(&[("/", 0, 0o755), ("/tmp", 0, 0o1777)]);
        assert!(root_tree_reason(Path::new("/tmp/rc"), &shared).is_some());
        let group = tree(&[("/", 0, 0o755), ("/srv", 0, 0o775)]);
        assert!(root_tree_reason(Path::new("/srv/rc"), &group).is_some());
    }

    #[cfg(unix)]
    #[test]
    fn output_tail_keeps_five_lines() {
        use std::os::unix::process::ExitStatusExt;
        let output = std::process::Output {
            status: std::process::ExitStatus::from_raw(256),
            stdout: b"ignored".to_vec(),
            stderr: b"1\n2\n\n3\n4\n5\n6\n".to_vec(),
        };
        assert_eq!(tail(&output), "2\n3\n4\n5\n6");
    }
}
