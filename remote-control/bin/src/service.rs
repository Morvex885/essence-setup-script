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
/// Сколько ждать, пока запущенная служба поднимет веб-панель.
const READY_WAIT: Duration = Duration::from_secs(10);
/// Запись об установленной службе в каталоге данных: `self uninstall` и
/// `web uninstall-service` находят службу и при другом окружении
/// (`XDG_CONFIG_HOME`, `HOME`), чем у установившего её процесса.
const RECORD: &str = "web/autostart.json";
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
        return systemd_unit().map_or(Kind::Unsupported, |(unit, system)| Kind::Systemd { unit, system });
    }
    Kind::Unsupported
}

/// Unit-файл службы и признак системного (root); `None` — нет домашнего каталога.
#[cfg(unix)]
fn systemd_unit() -> Option<(PathBuf, bool)> {
    if euid() == 0 {
        return Some((Path::new("/etc/systemd/system").join(UNIT_NAME), true));
    }
    config_home().map(|config| (config.join("systemd/user").join(UNIT_NAME), false))
}

/// Есть ли файл; ошибка доступа — не «нет», а сбой проверки.
fn present(path: &Path) -> Result<bool> {
    path.try_exists()
        .map_err(|error| RcError::new("failed", format!("Не удалось проверить автозапуск: {}: {error}", path.display())))
}

/// Установлен ли автозапуск: служба из записи каталога данных `data_dir`
/// (там, где её поставили) или в стандартном месте этого процесса — unit-файл
/// (на Linux — и без признака systemd: оставшийся unit тоже считается),
/// plist, задача или файл автозагрузки. Ошибка — проверить не удалось (это
/// не «не установлен»).
pub fn installed(data_dir: &Path) -> Result<bool> {
    if let Some(record) = read_record(data_dir)?
        && recorded_present(&record, data_dir)?
    {
        return Ok(true);
    }
    #[cfg(unix)]
    if cfg!(target_os = "linux") {
        return systemd_unit().map_or(Ok(false), |(unit, _)| present(&unit));
    }
    match kind() {
        Kind::Systemd { unit, .. } => present(&unit),
        Kind::Launchd { plist } => present(&plist),
        Kind::Windows { startup } => Ok(present(&startup)? || task_exists()?),
        Kind::Unsupported => Ok(false),
    }
}

// ─── Запись об установке ─────────────────────────────────────────────────────

/// Записанная служба: ответ `web install-service` (`service`, `unit`).
#[derive(Debug, PartialEq, Eq)]
struct Record {
    service: String,
    unit: String,
}

fn record_path(data_dir: &Path) -> PathBuf {
    data_dir.join(RECORD)
}

/// Без записи обе команды проверяют стандартное место службы.
fn damaged(path: &Path) -> RcError {
    RcError::new("invalid", format!("Файл {} повреждён: удалите его и повторите команду.", path.display()))
}

/// Запись; `None` — её нет. Повреждённая — ошибка (не «не установлено»).
fn read_record(data_dir: &Path) -> Result<Option<Record>> {
    let path = record_path(data_dir);
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(RcError::new("failed", format!("Не удалось прочитать {}: {error}", path.display()))),
    };
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| damaged(&path))?;
    match (value["service"].as_str(), value["unit"].as_str()) {
        (Some(service @ ("systemd" | "launchd" | "schtasks" | "startup")), Some(unit)) if !unit.is_empty() => {
            Ok(Some(Record { service: service.to_owned(), unit: unit.to_owned() }))
        }
        _ => Err(damaged(&path)),
    }
}

fn write_record(data_dir: &Path, installed: &Value) -> Result<()> {
    let record = json!({"service": installed["service"], "unit": installed["unit"]});
    write_service_file(&record_path(data_dir), &format!("{record}\n"))
}

fn remove_record(data_dir: &Path) -> Result<()> {
    let path = record_path(data_dir);
    match fs::remove_file(&path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => {
            Err(RcError::new("failed", format!("Не удалось удалить {}: {error}", path.display())))
        }
        _ => Ok(()),
    }
}

fn recorded_present(record: &Record, data_dir: &Path) -> Result<bool> {
    match record.service.as_str() {
        "schtasks" => task_exists(),
        _ => present(Path::new(&record.unit)).map_err(|error| {
            RcError::new(error.code, format!("{} (запись: {})", error.message, record_path(data_dir).display()))
        }),
    }
}

/// Служба для удаления: из записи (unit-файл и plist — где их поставили),
/// иначе стандартная для этого процесса.
fn recorded_kind(record: Option<Record>) -> Kind {
    match record {
        Some(Record { service, unit }) if service == "systemd" => Kind::Systemd { unit: PathBuf::from(unit), system: is_root() },
        Some(Record { service, unit }) if service == "launchd" => Kind::Launchd { plist: PathBuf::from(unit) },
        _ => kind(),
    }
}

#[cfg(unix)]
fn is_root() -> bool {
    euid() == 0
}
#[cfg(not(unix))]
fn is_root() -> bool {
    false
}

/// Есть ли задача планировщика. Полный список задач (`/Query /FO CSV /NH`)
/// отличает отсутствие задачи от сбоя запроса (у `/Query /TN` оба — код 1).
fn task_exists() -> Result<bool> {
    let args = words(&["/Query", "/FO", "CSV", "/NH"]);
    let output = output("schtasks", &args)?;
    if !output.status.success() {
        return Err(command_failed("schtasks", &args, &output));
    }
    let name = format!("\"\\{TASK_NAME}\"");
    Ok(String::from_utf8_lossy(&output.stdout).lines().any(|line| line.starts_with(&name)))
}

// ─── Внешние команды ─────────────────────────────────────────────────────────

/// Последние строки stderr (stdout, если stderr пуст).
fn tail(output: &std::process::Output) -> String {
    let text = if output.stderr.is_empty() { &output.stdout } else { &output.stderr };
    let text = String::from_utf8_lossy(text);
    let lines: Vec<&str> = text.lines().filter(|line| !line.trim().is_empty()).collect();
    lines[lines.len().saturating_sub(5)..].join("\n")
}

fn output(program: &str, args: &[String]) -> Result<std::process::Output> {
    Command::new(program)
        .args(args)
        .output()
        .map_err(|error| RcError::new("failed", format!("Не удалось запустить {program}: {error}")))
}

fn command_failed(program: &str, args: &[String], output: &std::process::Output) -> RcError {
    let tail = tail(output);
    let detail = if tail.is_empty() { String::new() } else { format!("\n{tail}") };
    RcError::new("failed", format!("Команда {program} {} завершилась ошибкой.{detail}", args.join(" ")))
}

/// Запуск программы без shell; ненулевой выход, который не принимает
/// `accept`, — `failed` с хвостом вывода.
fn run_accepting(program: &str, args: &[String], accept: fn(&std::process::Output) -> bool) -> Result<()> {
    let output = output(program, args)?;
    if output.status.success() || accept(&output) {
        return Ok(());
    }
    Err(command_failed(program, args, &output))
}

fn run(program: &str, args: &[String]) -> Result<()> {
    run_accepting(program, args, |_| false)
}

/// `launchctl bootout` агента, который не загружен: код 3 (ESRCH, «No such
/// process») или 113 («Could not find specified service»). Прочие коды —
/// сбой выгрузки.
fn bootout_not_loaded(output: &std::process::Output) -> bool {
    matches!(output.status.code(), Some(3 | 113))
}

fn bootout_args() -> Vec<String> {
    vec!["bootout".into(), format!("{}/{PLIST_LABEL}", gui_domain())]
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

/// Остановить работающий локальный демон и дождаться его выхода. Демона нет
/// — `Ok`; он не остановился (отказ, нет ответа, точка подключения жива
/// дольше [`STOP_WAIT`]) — ошибка: служба не должна стартовать рядом с ним.
fn stop_running_daemon(endpoint: &Endpoint) -> Result<()> {
    let mut client = match DaemonClient::connect_local(endpoint, None, None, None) {
        Ok(client) => client,
        Err(error) if matches!(error.kind(), io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused) => return Ok(()),
        Err(error) => return Err(oneshot::client_error(&error)),
    };
    let refused = |detail: &str| {
        RcError::new("failed", format!("Не удалось остановить работающий демон{detail}. Остановите его: essence-rc daemon stop."))
    };
    match call(&mut client, &["daemon", "stop"]) {
        Some(reply) if reply.ok => {}
        Some(reply) => return Err(refused(&reply.error["message"].as_str().map_or(String::new(), |message| format!(": {message}")))),
        None => return Err(refused("")),
    }
    let deadline = Instant::now() + STOP_WAIT;
    while Instant::now() < deadline {
        if client.next_event(Duration::from_millis(200)).is_err() {
            break;
        }
    }
    let _ = client.close();
    // Сокет удаляется до снятия блокировки: ждать, пока точка не исчезнет.
    loop {
        if DaemonClient::connect_local(endpoint, None, None, None).is_err() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(RcError::new("failed", "Работающий демон не остановился за 30 с. Остановите его: essence-rc daemon stop."));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// `web status` запущенной службы, когда веб-панель поднята (до
/// [`READY_WAIT`]); `None` — не поднялась.
fn service_web_status(endpoint: &Endpoint) -> Option<Value> {
    let deadline = Instant::now() + READY_WAIT;
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

/// Служба установлена, но панель не поднялась: файл службы остаётся
/// (служба перезапускается сама), подсказка — где смотреть ошибку.
fn not_started(installed: &Value) -> RcError {
    let hint = match installed["service"].as_str() {
        Some("systemd") => {
            let user = if is_root() { "" } else { "--user " };
            format!(" Журнал службы: journalctl {user}-u {UNIT_NAME}")
        }
        _ => String::new(),
    };
    RcError::new("failed", format!(
        "Служба установлена, но веб-панель не запустилась за {} с.{hint} Удалить автозапуск: essence-rc web uninstall-service.",
        READY_WAIT.as_secs()
    ))
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

/// Шаг установки: программа, аргументы, число попыток (пауза 500 мс) и
/// какой ненулевой выход считать успехом.
struct Step<'a> {
    program: &'a str,
    args: Vec<String>,
    attempts: u32,
    accept: fn(&std::process::Output) -> bool,
}

impl<'a> Step<'a> {
    fn once(program: &'a str, args: Vec<String>) -> Self {
        Self { program, args, attempts: 1, accept: |_| false }
    }

    fn run(&self) -> Result<()> {
        let mut attempt = 1;
        loop {
            match run_accepting(self.program, &self.args, self.accept) {
                Err(_) if attempt < self.attempts => {
                    attempt += 1;
                    std::thread::sleep(RETRY_PAUSE);
                }
                result => return result,
            }
        }
    }
}

/// Записать файл и выполнить шаги. Прежний файл, который не удалось
/// прочитать, — ошибка до записи. При сбое шага прежний файл
/// восстанавливается либо новый удаляется, затем `rollback(восстановлен)`
/// приводит службу в соответствие (ошибки отката не учитываются).
fn install_file(path: &Path, text: &str, steps: &[Step<'_>], rollback: &dyn Fn(bool)) -> Result<()> {
    let previous = match fs::read(path) {
        Ok(bytes) => Some(bytes),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(RcError::new("failed", format!("Не удалось прочитать {}: {error}", path.display()))),
    };
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
            // Состояние прежнего unit (включён, работает) — до шагов: откат
            // возвращает именно его.
            let previous = if present(&unit)? {
                let state = |verb: &str| output("systemctl", &systemctl(system, &[verb, UNIT_NAME])).map(|out| out.status.success());
                Some((state("is-enabled")?, state("is-active")?))
            } else {
                None
            };
            // Откат: прежний unit — перечитать и вернуть прежнее состояние;
            // нового не было (или прежний не восстановлен) — выключить и перечитать.
            let rollback = |restored: bool| match previous.filter(|_| restored) {
                Some((enabled, active)) => {
                    let _ = run("systemctl", &systemctl(system, &["daemon-reload"]));
                    let _ = run("systemctl", &systemctl(system, &[if enabled { "enable" } else { "disable" }, UNIT_NAME]));
                    let _ = run("systemctl", &systemctl(system, &[if active { "restart" } else { "stop" }, UNIT_NAME]));
                }
                None => {
                    let _ = run("systemctl", &systemctl(system, &["disable", "--now", UNIT_NAME]));
                    let _ = run("systemctl", &systemctl(system, &["daemon-reload"]));
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
            let bootstrap = vec!["bootstrap".into(), gui_domain(), path.clone()];
            // Откат: прежний агент загружается снова.
            let rollback = |restored: bool| {
                if restored {
                    let _ = run("launchctl", &bootstrap);
                }
            };
            // Прежний агент выгружается только после записи нового plist (его
            // может не быть); сбой записи оставляет прежний агент загруженным.
            let steps = [
                Step { program: "launchctl", args: bootout_args(), attempts: 1, accept: bootout_not_loaded },
                Step { program: "launchctl", args: bootstrap.clone(), attempts: 3, accept: |_| false },
            ];
            install_file(&plist, &plist_text(launch), &steps, &rollback)?;
            Ok(json!({"service": "launchd", "unit": path, "started": true}))
        }
        Kind::Windows { startup } => {
            if run("schtasks", &schtasks_create(launch)).is_ok() {
                // `/F` заменил задачу; работающий экземпляр прежней — остановить.
                let _ = run("schtasks", &words(&["/End", "/TN", TASK_NAME]));
                // Запуск подтверждает проверка готовности панели.
                let _ = run("schtasks", &words(&["/Run", "/TN", TASK_NAME]));
                // Прежний запасной путь больше не нужен.
                let _ = fs::remove_file(&startup);
                return Ok(json!({"service": "schtasks", "unit": TASK_NAME, "started": true}));
            }
            // Планировщик недоступен (политика, права): папка автозагрузки;
            // прежняя задача, если осталась, удаляется, чтобы не было двух запусков.
            let _ = run("schtasks", &words(&["/Delete", "/TN", TASK_NAME, "/F"]));
            write_service_file(&startup, &startup_script(launch))?;
            let _ = Command::new(&launch.exe).args(&launch.argv("start")[1..]).output();
            Ok(json!({"service": "startup", "unit": startup.to_string_lossy(), "started": true}))
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
        stop_running_daemon(&endpoint)?;
        let data = install_with(&launch, kind)?;
        // Служба поставлена: запись — до проверки запуска, ведь файл службы
        // остаётся и при неудачном запуске.
        write_record(&launch.data_dir, &data)?;
        // `started` — только после подтверждения: панель поднята (Type=simple
        // и планировщик успех запуска не подтверждают).
        let web = service_web_status(&endpoint).ok_or_else(|| not_started(&data))?;
        let network = invocation.value("bind").and_then(|bind| bind.parse::<std::net::IpAddr>().ok())
            .is_some_and(|ip| !ip.to_canonical().is_loopback());
        if network {
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
            if !present(&unit)? {
                return Ok(false);
            }
            // Уже выключенная служба — успех `systemctl`; иначе unit остаётся.
            run("systemctl", &systemctl(system, &["disable", "--now", UNIT_NAME]))?;
            fs::remove_file(&unit).map_err(|error| RcError::new("failed", format!("Не удалось удалить {}: {error}", unit.display())))?;
            run("systemctl", &systemctl(system, &["daemon-reload"]))?;
            Ok(true)
        }
        Kind::Launchd { plist } => {
            if !present(&plist)? {
                return Ok(false);
            }
            // Не загруженный агент — не ошибка; прочие сбои оставляют plist.
            run_accepting("launchctl", &bootout_args(), bootout_not_loaded)?;
            fs::remove_file(&plist).map_err(|error| RcError::new("failed", format!("Не удалось удалить {}: {error}", plist.display())))?;
            Ok(true)
        }
        Kind::Windows { startup } => {
            let mut removed = false;
            let _ = run("schtasks", &words(&["/End", "/TN", TASK_NAME]));
            // Ошибка удаления оставшейся задачи — ошибка: задача запустит панель снова.
            if task_exists()? {
                run("schtasks", &words(&["/Delete", "/TN", TASK_NAME, "/F"]))?;
                removed = true;
            }
            if present(&startup)? {
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
/// снять автозапуск (записанный в каталоге данных, иначе стандартный) и
/// запись о нём. Службы нет → `{"removed":false}`.
pub fn uninstall(invocation: &Invocation) -> ExitCode {
    let output = (|| -> Result<Output> {
        let root = StatePaths::discover()?.root().to_owned();
        let root = std::path::absolute(&root)
            .map_err(|_| RcError::new("invalid", format!("Каталог данных {} недоступен.", root.display())))?;
        stop_running_daemon(&endpoint(&root)?)?;
        let removed = uninstall_with(recorded_kind(read_record(&root)?))?;
        remove_record(&root)?;
        Ok(Output::success(json!({"removed": removed})))
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

    #[cfg(unix)]
    #[test]
    fn only_a_not_loaded_bootout_is_accepted() {
        use std::os::unix::process::ExitStatusExt;
        let exited = |code: i32| std::process::Output {
            status: std::process::ExitStatus::from_raw(code << 8),
            stdout: Vec::new(),
            stderr: Vec::new(),
        };
        assert!(bootout_not_loaded(&exited(3)), "ESRCH: not loaded");
        assert!(bootout_not_loaded(&exited(113)), "service not found");
        for code in [1, 5, 37, 150] {
            assert!(!bootout_not_loaded(&exited(code)), "{code}");
        }
    }

    #[test]
    fn the_recorded_service_is_found_where_it_was_installed() {
        let data = tempfile::tempdir().unwrap();
        assert_eq!(read_record(data.path()).unwrap(), None);
        let unit = data.path().join("other-config").join(UNIT_NAME);
        write_record(data.path(), &json!({"service": "systemd", "unit": unit.to_string_lossy(), "started": true})).unwrap();
        let record = read_record(data.path()).unwrap().unwrap();
        assert_eq!(record, Record { service: "systemd".into(), unit: unit.to_string_lossy().into_owned() });
        assert!(!recorded_present(&record, data.path()).unwrap(), "the unit is gone");
        fs::create_dir_all(unit.parent().unwrap()).unwrap();
        fs::write(&unit, "").unwrap();
        assert!(installed(data.path()).unwrap(), "found whatever this process's config dir is");
        assert_eq!(recorded_kind(Some(record)), Kind::Systemd { unit, system: is_root() });

        remove_record(data.path()).unwrap();
        assert_eq!(read_record(data.path()).unwrap(), None);
        remove_record(data.path()).unwrap();
        for damaged in ["{", r#"{"service":"cron","unit":"x"}"#, r#"{"service":"systemd","unit":""}"#] {
            fs::write(record_path(data.path()), damaged).unwrap();
            // Same actionable error for `self uninstall` (installed) and `web uninstall-service` (read_record).
            for error in [read_record(data.path()).unwrap_err(), installed(data.path()).unwrap_err()] {
                assert_eq!(error.code, "invalid", "{damaged}");
                assert!(error.message.ends_with("повреждён: удалите его и повторите команду."), "{}", error.message);
                assert!(!error.message.contains("uninstall-service"), "no loop: {}", error.message);
            }
        }
        // Once the damaged record is deleted, the default location is checked.
        remove_record(data.path()).unwrap();
        assert_eq!(read_record(data.path()).unwrap(), None);
    }
}
