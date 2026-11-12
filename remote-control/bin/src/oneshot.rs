//! Разовый CLI через демон: секреты и входные файлы читаются здесь, команда
//! уходит демону по локальному сокету (или удалённому по `--connect`), ответ
//! печатается конвертом JSON или русским человекочитаемым выводом.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{self, ErrorKind, Read, Write};
use std::path::Path;
use std::process::ExitCode;

use essence_rc_client::{self as client, Client, DaemonClient, Endpoint, Progress, Reply, Request, SpawnDaemon};
use essence_rc_client::files::InputFileError;
use rc_core::cli::{self, Invocation};
use rc_core::clients::templates;
use rc_core::confirmation::Plan;
use rc_core::error::{RcError, Result, exit_code_for};
use rc_core::log::{self, Level};
use rc_core::request_secrets::Secrets;
use rc_core::state::StatePaths;
use rc_core::VERSION;
use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use crate::remote::{self, Target};
use crate::terminal;

/// Скрытый ввод секрета: максимум три попытки на имя (цикл сессии v1).
const MAX_SECRET_ATTEMPTS: u8 = 3;
/// Секреты неявного `session open`; разовый вызов принимает их для любой
/// команды, которой предшествует открытие сессии. `access-token` — код
/// доступа сетевого демона (одноразовый: после принятия не повторяется).
const SESSION_SECRETS: [&str; 3] = ["script-password", "vault-password", "access-token"];
const ACCESS_TOKEN: &str = "access-token";
/// Предел пути сокета агента, принимаемый демоном.
const MAX_AGENT_SOCKET: usize = 4096;

// ─── Сигналы: SIGINT не рвёт команду и ответ; SIGPIPE уже игнорируется ───────

/// Пока держится, SIGINT принимает зарегистрированный обработчик, а фоновая
/// задача его сливает — процесс не завершается. Регистрация синхронная: к
/// возврату из `install_on` сигнал уже перехвачен. SIGPIPE среда выполнения
/// Rust игнорирует: запись в закрытый канал вернёт io-ошибку.
///
/// Завершающие сигналы (Unix SIGTERM/SIGHUP/SIGQUIT; Windows закрытие консоли,
/// Ctrl+Break, выход из системы, выключение) по-прежнему завершают процесс,
/// но сначала возвращают консоль из raw mode (`node shell`, скрытый ввод).
struct SignalGuard(Vec<tokio::task::JoinHandle<()>>);

/// Восстановить консоль и выйти с кодом, принятым для сигнала.
fn terminate(code: i32) -> ! {
    terminal::restore_console();
    std::process::exit(code)
}

impl SignalGuard {
    fn install_on(runtime: &tokio::runtime::Runtime) -> Self {
        let _context = runtime.enter();
        let mut tasks = Vec::new();
        #[cfg(unix)]
        {
            use tokio::signal::unix::{SignalKind, signal};
            if let Ok(mut stream) = signal(SignalKind::interrupt()) {
                tasks.push(runtime.spawn(async move { while stream.recv().await.is_some() {} }));
            }
            for (kind, number) in [(SignalKind::terminate(), libc::SIGTERM), (SignalKind::hangup(), libc::SIGHUP),
                (SignalKind::quit(), libc::SIGQUIT)]
            {
                if let Ok(mut stream) = signal(kind) {
                    tasks.push(runtime.spawn(async move {
                        if stream.recv().await.is_some() {
                            terminate(128 + number);
                        }
                    }));
                }
            }
        }
        #[cfg(windows)]
        {
            use tokio::signal::windows;
            if let Ok(mut stream) = windows::ctrl_c() {
                tasks.push(runtime.spawn(async move { while stream.recv().await.is_some() {} }));
            }
            // STATUS_CONTROL_C_EXIT, the code Windows reports for console-event exits.
            const CONTROL_EXIT: i32 = 0xC000_013A_u32 as i32;
            macro_rules! on_event {
                ($constructor:path) => {
                    if let Ok(mut stream) = $constructor() {
                        tasks.push(runtime.spawn(async move {
                            if stream.recv().await.is_some() {
                                terminate(CONTROL_EXIT);
                            }
                        }));
                    }
                };
            }
            on_event!(windows::ctrl_break);
            on_event!(windows::ctrl_close);
            on_event!(windows::ctrl_logoff);
            on_event!(windows::ctrl_shutdown);
        }
        Self(tasks)
    }
}

impl Drop for SignalGuard {
    fn drop(&mut self) {
        for handle in self.0.drain(..) {
            handle.abort();
        }
    }
}

// ─── Итог вызова ─────────────────────────────────────────────────────────────

/// Итог разового вызова: ответ демона либо локальная ошибка. `exit` в stdout
/// не печатается — это код выхода процесса.
pub struct Output {
    ok: bool,
    data: Option<Value>,
    error: Option<Value>,
    sync: Option<String>,
    exit: u8,
}

impl Output {
    pub fn success(data: Value) -> Self {
        Self { ok: true, data: Some(data), error: None, sync: None, exit: 0 }
    }

    pub fn from_error(error: RcError) -> Self {
        let exit = error.exit_code();
        let error = serde_json::to_value(&error).unwrap_or_else(|_| json!({"code": "failed", "message": error.message}));
        Self { ok: false, data: None, error: Some(error), sync: None, exit }
    }

    fn from_reply(reply: Reply) -> Self {
        let error = (!reply.error.is_null()).then_some(reply.error);
        let exit = if reply.ok {
            0
        } else {
            let code = error.as_ref().and_then(|error| error["code"].as_str()).unwrap_or("failed");
            reply.exit.unwrap_or_else(|| exit_code_for(code))
        };
        Self {
            ok: reply.ok,
            data: (reply.ok || !reply.data.is_null()).then_some(reply.data),
            error,
            sync: reply.sync.as_str().map(str::to_owned),
            exit,
        }
    }

    fn code(&self) -> &str {
        self.error.as_ref().and_then(|error| error["code"].as_str()).unwrap_or("")
    }

    pub fn exit_code(&self) -> u8 {
        self.exit
    }

    /// Текст ошибки (`error.message`); пусто для успеха.
    pub fn message(&self) -> &str {
        self.error.as_ref().and_then(|error| error["message"].as_str()).unwrap_or("")
    }

    /// `{"id":null,"ok",["data"],["error"],["sync"]}` — ровно в этом порядке.
    fn envelope(&self) -> Value {
        let mut map = Map::new();
        map.insert("id".into(), Value::Null);
        map.insert("ok".into(), Value::Bool(self.ok));
        if let Some(data) = &self.data {
            map.insert("data".into(), data.clone());
        }
        if let Some(error) = &self.error {
            map.insert("error".into(), error.clone());
        }
        if let Some(sync) = &self.sync {
            map.insert("sync".into(), Value::String(sync.clone()));
        }
        Value::Object(map)
    }
}

/// Итог по ответу демона (для команд вне `run`).
pub fn output_from_reply(reply: Reply) -> Output {
    Output::from_reply(reply)
}

/// Вывод итога: с --json — ровно одна строка JSON на stdout; без него —
/// русский человекочитаемый вывод (сообщение ошибки на stderr).
pub fn finish(output: Output, json: bool, invocation: Option<&Invocation>) -> ExitCode {
    if emit(&output, json, invocation).is_err() {
        // stdout закрыт (EPIPE): только фиксированное сообщение — конверт
        // может содержать токены и ссылки, в stderr он не дублируется.
        let _ = writeln!(io::stderr().lock(), "  [✗] Не удалось вывести ответ: stdout недоступен.");
        return ExitCode::FAILURE;
    }
    ExitCode::from(output.exit)
}

fn emit(output: &Output, json: bool, invocation: Option<&Invocation>) -> io::Result<()> {
    if json {
        let line = serde_json::to_string(&output.envelope()).map_err(io::Error::other)?;
        let mut stdout = io::stdout().lock();
        writeln!(stdout, "{line}")?;
        stdout.flush()
    } else {
        render_human(output, invocation)
    }
}

// ─── Подключение к демону ────────────────────────────────────────────────────

pub(crate) fn failed(message: impl Into<String>) -> RcError {
    RcError::new("failed", message)
}

/// Ошибка клиента протокола как код каталога.
pub(crate) fn client_error(error: &io::Error) -> RcError {
    let code = match error.kind() {
        ErrorKind::PermissionDenied => "unsafe_path",
        ErrorKind::InvalidInput => "invalid",
        _ => "failed",
    };
    RcError::new(code, error.to_string())
}

/// Обрыв соединения посреди запроса — аварийный ответ за демон.
pub(crate) fn request_error(error: &io::Error) -> RcError {
    if error.kind() == ErrorKind::UnexpectedEof {
        failed("Ядро завершилось аварийно.")
    } else {
        client_error(error)
    }
}

/// Локальный демон каталога данных; при отсутствии запускается этот же
/// исполняемый файл (`daemon run`).
pub fn connect() -> Result<(DaemonClient, Endpoint)> {
    connect_spawning(vec!["daemon".into(), "run".into()])
}

/// `connect` с аргументами запуска демона (`daemon run --web …`).
pub(crate) fn connect_spawning(args: Vec<String>) -> Result<(DaemonClient, Endpoint)> {
    let root = StatePaths::discover()?.root().to_owned();
    let endpoint = client::endpoint_for(&root).map_err(|error| client_error(&error))?;
    let exe = std::env::current_exe().map_err(|error| failed(format!("Не удалось определить исполняемый файл: {error}")))?;
    let spawn = SpawnDaemon { exe: exe.clone(), args, env: Vec::new() };
    let client = DaemonClient::connect_local(&endpoint, Some(&spawn), Some(VERSION), Some(&exe))
        .map_err(|error| client_error(&error))?;
    Ok((client, endpoint))
}

/// `SSH_AUTH_SOCK` из окружения CLI (только абсолютный путь); на Windows без
/// переменной — канал агента OpenSSH.
fn agent_env() -> Option<BTreeMap<String, String>> {
    let socket = match std::env::var("SSH_AUTH_SOCK") {
        Ok(socket) if !socket.is_empty() => socket,
        #[cfg(windows)]
        _ => r"\\.\pipe\openssh-ssh-agent".to_owned(),
        #[cfg(not(windows))]
        _ => return None,
    };
    (Path::new(&socket).is_absolute() && socket.len() <= MAX_AGENT_SOCKET)
        .then(|| BTreeMap::from([("SSH_AUTH_SOCK".to_owned(), socket)]))
}

/// Копии переданных секретов с именами из `names`.
fn wire_secrets(secrets: &Secrets, names: &[&str]) -> client::Secrets {
    let mut wire = client::Secrets::default();
    for name in names {
        if let Some(value) = secrets.get(name) {
            wire.insert_hidden(*name, Zeroizing::new(value.to_owned()));
        }
    }
    wire
}

fn print_log(entry: &client::Log) {
    let level = match entry.level.as_str() {
        "success" => Level::Success,
        "warn" => Level::Warn,
        "error" => Level::Error,
        "output" => Level::Output,
        _ => Level::Info,
    };
    let _ = writeln!(io::stderr().lock(), "{}{}", level.prefix(), log::sanitize(&entry.text));
}

// ─── Разовый CLI ─────────────────────────────────────────────────────────────

/// Перед этими командами неявный `session open` не отправляется.
fn opens_session(invocation: &Invocation) -> bool {
    !(invocation.help
        || matches!((invocation.noun.as_str(), invocation.verb.as_str()),
            ("session", "status" | "open") | ("self", "version"))
        || matches!(invocation.noun.as_str(), "daemon" | "web"))
}

pub fn run(argv: &[String], invocation: &Invocation, target: Option<&Target>) -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            let error = failed(format!("Не удалось запустить среду выполнения: {error}"));
            return finish(Output::from_error(error), invocation.json, Some(invocation));
        }
    };
    // Поздний Ctrl+C не должен оборвать ни команду, ни запись ответа — от
    // подключения до вывода конверта, включая скрытый ввод и терминал.
    let _signals = SignalGuard::install_on(&runtime);
    let output = execute(argv, invocation, target).unwrap_or_else(|output| *output);
    finish(output, invocation.json, Some(invocation))
}

/// Ранний итог (ошибка до ответа команды) — в куче: `Output` велик.
pub(crate) type Outcome<T> = std::result::Result<T, Box<Output>>;

pub(crate) fn local(error: RcError) -> Box<Output> {
    Box::new(Output::from_error(error))
}

fn execute(argv: &[String], invocation: &Invocation, target: Option<&Target>) -> Outcome<Output> {
    let session = opens_session(invocation);
    let mut secrets = Secrets::default();
    if invocation.secrets_stdin {
        secrets = read_stdin_secrets().map_err(local)?;
    }
    let mut accepted = invocation.allowed_secrets().to_vec();
    if session {
        accepted.extend(SESSION_SECRETS.iter().filter(|name| !invocation.allowed_secrets().contains(name)));
    }
    secrets.validate_allowed(&accepted).map_err(local)?;
    let input = read_inputs(invocation).map_err(local)?;
    let export = (invocation.noun == "template" && invocation.verb == "export")
        .then(|| export_preflight(invocation))
        .transpose()
        .map_err(local)?;
    if invocation.client_side() && export.is_none() {
        return Err(local(RcError::new("usage", "Команда выполняется на стороне клиента.")));
    }
    let request_argv = match &export {
        Some(export) => vec!["template".into(), "show".into(), "--name".into(), export.name.clone()],
        // Пути сертификата `web start` — абсолютные: у демона другой рабочий каталог.
        None if (invocation.noun.as_str(), invocation.verb.as_str()) == ("web", "start") => {
            [vec!["web".to_owned(), "start".to_owned()], listener_flags(invocation).map_err(local)?].concat()
        }
        None => invocation.daemon_argv(argv),
    };
    // Агент SSH передаётся только локальному демону (сетевому `env` запрещён).
    let (mut client, env) = match target {
        Some(target) => (remote::connect(target).map_err(local)?, None),
        None => (connect().map_err(local)?.0, agent_env()),
    };
    if let Err(error) = refuse_key_in_data_dir(invocation, client.local_data_dir()) {
        let _ = client.close();
        return Err(local(error));
    }
    let mut prompts = SecretPrompts::default();
    if session {
        open_session(&mut client, &mut secrets, env.as_ref(), &mut prompts, invocation.requires_session())?;
    }
    let mut print = |progress: Progress<'_>| {
        if let Progress::Log(entry) = progress {
            print_log(entry);
        }
    };
    let interactive = invocation.requires_tty() && terminal::console_attached();
    let reply = loop {
        let wire = wire_secrets(&secrets, invocation.allowed_secrets());
        let request = Request { argv: &request_argv, secrets: &wire, input: &input, env: env.as_ref() };
        let reply = if interactive {
            client.terminal(request, &mut terminal::TerminalConsole::new(), &mut print)
        } else {
            client.send(request, &mut print)
        }
        .map_err(|error| { let _ = client.close(); local(request_error(&error)) })?;
        // Повтор только для отказа до мутации: пусто/неверно/отсутствует.
        if !prompts.missing(invocation, &mut secrets, &reply) {
            break reply;
        }
    };
    let _ = client.close();
    let output = Output::from_reply(reply);
    match export {
        Some(export) if output.ok => {
            let content = output.data.as_ref().and_then(|data| data["content"].as_str()).unwrap_or_default();
            let name = output.data.as_ref().and_then(|data| data["name"].as_str()).unwrap_or(&export.name).to_owned();
            write_export(&export, content).map_err(local)?;
            print_log(&client::Log { level: "success".into(), text: format!("Шаблон {name} сохранён в {}", export.output) });
            Ok(Output::success(json!({"name": name, "output": export.output})))
        }
        _ => Ok(output),
    }
}

/// Ошибки источника, после которых демон всё равно авторизует соединение
/// (пароль запуска проверен): команде без сессии — к ним относятся команды
/// восстановления источника — ядро ответит само.
const SOURCE_ERRORS: [&str; 7] = ["vault_password_required", "vault_password_invalid", "github_format_outdated",
    "github_format_newer", "github_format_invalid", "locked", "source_failed"];

/// Неявное открытие сессии: только `script-password`, `vault-password` и
/// (сетевой демон) `access-token`,
/// журнал не печатается; `not_configured` — продолжить к команде, как и
/// ошибка источника для команды без сессии (`needs_session == false`).
fn open_session(client: &mut DaemonClient, secrets: &mut Secrets, env: Option<&BTreeMap<String, String>>,
    prompts: &mut SecretPrompts, needs_session: bool) -> Outcome<()> {
    let argv = vec!["session".to_owned(), "open".to_owned()];
    let open = cli::parse(&argv).map_err(local)?;
    let input = client::Input::default();
    // Принятый код доступа погашен демоном: повтор (после вопроса о пароле)
    // идёт без него — соединение уже допущено.
    let mut token_spent = false;
    loop {
        let names: &[&str] = if token_spent { &SESSION_SECRETS[..2] } else { &SESSION_SECRETS };
        let wire = wire_secrets(secrets, names);
        let sent_token = names.contains(&ACCESS_TOKEN) && secrets.get(ACCESS_TOKEN).is_some();
        let reply = client
            .send(Request { argv: &argv, secrets: &wire, input: &input, env }, &mut |_| {})
            .map_err(|error| { let _ = client.close(); local(request_error(&error)) })?;
        if sent_token && reply.error["secret"] != ACCESS_TOKEN {
            token_spent = true;
        }
        if reply.ok || reply.code() == "not_configured" {
            return Ok(());
        }
        if !prompts.missing(&open, secrets, &reply) {
            if !needs_session && SOURCE_ERRORS.contains(&reply.code()) {
                return Ok(());
            }
            let _ = client.close();
            return Err(Box::new(Output::from_reply(reply)));
        }
    }
}

/// Флаги слушателя `--bind`, `--port`, `--tls-cert`, `--tls-key`, `--no-tls`
/// как argv. Пути сертификата — абсолютные: демон работает в своём каталоге.
pub fn listener_flags(invocation: &Invocation) -> Result<Vec<String>> {
    let mut flags = Vec::new();
    for name in ["bind", "port", "tls-cert", "tls-key"] {
        let Some(value) = invocation.value(name) else { continue };
        let value = if name.starts_with("tls-") { absolute_file(value)? } else { value.to_owned() };
        flags.extend([format!("--{name}"), value]);
    }
    if invocation.has("no-tls") {
        flags.push("--no-tls".into());
    }
    Ok(flags)
}

/// Путь файла от рабочего каталога CLI (у демона он свой).
fn absolute_file(value: &str) -> Result<String> {
    std::path::absolute(value)
        .map(|path| path.to_string_lossy().into_owned())
        .map_err(|_| RcError::new("invalid", format!("Файл {value} недоступен.")))
}

/// Предупреждение об открытой панели (`web.open`): не loopback, нет пароля.
pub fn warn_open_panel(web: &Value) {
    if web["open"] == true {
        let _ = writeln!(io::stderr().lock(), "  [!] Пароль запуска не задан: панель доступна всем в сети.");
    }
}

/// `daemon start [--web …]`: подключиться (запустив демон) и напечатать
/// точку и pid. С `--web` новый демон запускается со слушателем; уже
/// работающему без слушателя отправляется `web start` с теми же флагами.
pub fn daemon_start(invocation: &Invocation) -> ExitCode {
    let output = (|| -> Outcome<Output> {
        let web = invocation.has("web");
        let flags = listener_flags(invocation).map_err(local)?;
        if !web && !flags.is_empty() {
            return Err(local(RcError::new("usage", "Флаги слушателя указываются вместе с --web.")));
        }
        let mut args = vec!["daemon".to_owned(), "run".to_owned()];
        if web {
            args.push("--web".into());
            args.extend(flags.iter().cloned());
        }
        let (mut client, endpoint) = connect_spawning(args).map_err(local)?;
        let (secrets, input) = (client::Secrets::default(), client::Input::default());
        let ask = |client: &mut DaemonClient, argv: Vec<String>| {
            client.send(Request::new(&argv, &secrets, &input), &mut |_| {}).map_err(|error| local(request_error(&error)))
        };
        let mut status = ask(&mut client, vec!["daemon".into(), "status".into()])?;
        if status.ok && web && status.data["web"].is_null() {
            let started = ask(&mut client, [vec!["web".to_owned(), "start".to_owned()], flags].concat())?;
            if !started.ok {
                let _ = client.close();
                return Err(Box::new(Output::from_reply(started)));
            }
            status = ask(&mut client, vec!["daemon".into(), "status".into()])?;
        }
        let _ = client.close();
        if !status.ok {
            return Err(Box::new(Output::from_reply(status)));
        }
        #[cfg(unix)]
        let address = endpoint.socket.display().to_string();
        #[cfg(windows)]
        let address = endpoint.pipe.clone();
        let mut data = json!({"endpoint": address, "pid": status.data["pid"]});
        if web {
            warn_open_panel(&status.data["web"]);
            data["web"] = status.data["web"].clone();
        }
        Ok(Output::success(data))
    })()
    .unwrap_or_else(|output| *output);
    finish(output, invocation.json, Some(invocation))
}

/// `--secrets-stdin`: весь stdin — JSON-объект строк; значения сразу в
/// Zeroizing-структуре и дальше не покидают её.
fn read_stdin_secrets() -> Result<Secrets> {
    let mut raw = Zeroizing::new(String::with_capacity(4096));
    if io::stdin().read_to_string(&mut raw).is_err() {
        return Err(RcError::new("usage", "Не удалось прочитать секреты из stdin."));
    }
    Secrets::from_json(&raw)
}

// ─── Входные файлы ───────────────────────────────────────────────────────────

/// Содержимое `--имя ПУТЬ` каждого `@имя` команды; флаг обязателен.
fn read_inputs(invocation: &Invocation) -> Result<client::Input> {
    let mut input = client::Input::default();
    for name in invocation.inputs() {
        let path = invocation
            .value(name)
            .filter(|path| !path.is_empty())
            .ok_or_else(|| RcError::new("usage", format!("Укажите файл: --{name} PATH.")))?;
        input.insert(*name, read_input_file(path)?);
    }
    Ok(input)
}

/// Обычный файл в UTF-8 не больше 1 МиБ; ссылка отклоняется (`invalid`).
fn read_input_file(path: &str) -> Result<Zeroizing<String>> {
    client::files::read_input_file(Path::new(path)).map_err(|error| {
        let message = match error {
            InputFileError::Unavailable => format!("Файл {path} недоступен."),
            InputFileError::TooLarge => format!("Файл {path} больше 1 МиБ."),
            InputFileError::NotUtf8 => format!("Файл {path} не в кодировке UTF-8."),
        };
        RcError::new("invalid", message)
    })
}

/// Ключ восстановления не берётся из служебного каталога данных локального
/// демона; каталог удалённого демона (`None`) не проверяется.
fn refuse_key_in_data_dir(invocation: &Invocation, data_dir: Option<&Path>) -> Result<()> {
    if (invocation.noun.as_str(), invocation.verb.as_str()) != ("source", "github-import-recovery-key") {
        return Ok(());
    }
    let (Some(file), Some(data_dir)) = (invocation.value("file"), data_dir) else { return Ok(()) };
    if client::files::inside_data_dir(Path::new(file), data_dir) {
        return Err(RcError::new("invalid", client::files::RECOVERY_KEY_REFUSED));
    }
    Ok(())
}

// ─── template export ─────────────────────────────────────────────────────────

struct Export {
    /// Имя шаблона для `template show` (как передано).
    name: String,
    output: String,
    /// Перезапись существующего пути подтверждена планом.
    replace: bool,
}

fn required<'a>(invocation: &'a Invocation, flag: &str) -> Result<&'a str> {
    invocation.value(flag).filter(|value| !value.is_empty())
        .ok_or_else(|| RcError::new("usage", format!("Укажите --{flag}.")))
}

/// До обращения к демону: каталог — `invalid`; существующий путь (ссылка
/// тоже) — план перезаписи с подтверждением.
fn export_preflight(invocation: &Invocation) -> Result<Export> {
    let name = required(invocation, "name")?.to_owned();
    let output = required(invocation, "output")?.to_owned();
    let replace = match fs::symlink_metadata(&output) {
        Ok(meta) if meta.is_dir() => {
            return Err(RcError::new("invalid", format!("Путь {output} — каталог; укажите файл.")));
        }
        Ok(_) => {
            let file = templates::file_name(&name);
            Plan::new(vec![format!("Файл {output} будет перезаписан шаблоном {file}.")], String::new()).confirm(invocation)?;
            true
        }
        Err(error) if error.kind() == ErrorKind::NotFound => false,
        Err(error) => return Err(error.into()),
    };
    Ok(Export { name, output, replace })
}

/// Атомарная запись: ссылка на месте `output` заменяется файлом, её цель не
/// трогается. Без подтверждённой перезаписи появившийся тем временем файл
/// сохраняется — `conflict`.
fn write_export(export: &Export, content: &str) -> Result<()> {
    let output = &export.output;
    client::files::write_file_atomic(Path::new(output), content.as_bytes(), export.replace).map_err(|error| {
        if error.kind() == ErrorKind::AlreadyExists {
            RcError::new("conflict", format!("Файл {output} появился во время экспорта: повторите команду."))
        } else {
            failed(format!("Не удалось записать {output}."))
        }
    })
}

// ─── Повтор со скрытым вводом секрета ────────────────────────────────────────

/// Консольные попытки по именам секретов (как счётчики сессии v1).
#[derive(Default)]
struct SecretPrompts {
    attempts: HashMap<&'static str, u8>,
}

impl SecretPrompts {
    /// Спросить недостающий секрет и перезапустить запрос. Только коды
    /// отказа до мутации, только разрешённые запросом секреты, только при
    /// живой консоли; подтверждения никогда не спрашиваются.
    fn missing(&mut self, invocation: &Invocation, secrets: &mut Secrets, reply: &Reply) -> bool {
        if reply.ok || !terminal::console_available() {
            return false;
        }
        let Some(name) = prompt_target(invocation, secrets, &reply.error) else {
            return false;
        };
        if self.attempts.get(name).is_some_and(|used| *used >= MAX_SECRET_ATTEMPTS) {
            return false;
        }
        let Some(value) = terminal::read_hidden_line(terminal::secret_prompt(name)).ok().flatten() else {
            return false;
        };
        *self.attempts.entry(name).or_insert(0) += 1;
        secrets.insert(name, value).is_ok()
    }
}

/// Какой секрет спросить: подсказка демона (`error.secret`), иначе
/// единственный незаполненный секрет запроса.
fn prompt_target(invocation: &Invocation, secrets: &Secrets, error: &Value) -> Option<&'static str> {
    let allowed = invocation.allowed_secrets();
    let hint = error["secret"].as_str().and_then(|name| allowed.iter().copied().find(|candidate| *candidate == name));
    match error["code"].as_str()? {
        "auth_required" | "missing_secret" | "vault_password_required" | "new_vault_password_required" => hint
            .filter(|name| secrets.get(name).is_none())
            .or_else(|| sole_missing(allowed, secrets)),
        // Неверное значение: спросить заново тот же секрет.
        "auth_failed" | "vault_password_invalid" => hint,
        _ => None,
    }
}

fn sole_missing(allowed: &[&'static str], secrets: &Secrets) -> Option<&'static str> {
    let mut missing = allowed.iter().copied().filter(|name| secrets.get(name).is_none());
    let only = missing.next()?;
    missing.next().is_none().then_some(only)
}

// ─── Человекочитаемый вывод (русские тексты v1) ──────────────────────────────

fn render_human(output: &Output, invocation: Option<&Invocation>) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    if output.ok {
        if let Some(invocation) = invocation.filter(|invocation| invocation.help) {
            write!(stdout, "{}", cli::render_help(invocation.help_noun()))?;
            return stdout.flush();
        }
        if let Some(data) = &output.data {
            for line in render_value(data, "") {
                writeln!(stdout, "{line}")?;
            }
        }
        return stdout.flush();
    }
    let error = output.error.as_ref().and_then(Value::as_object).cloned().unwrap_or_default();
    let code = output.code();
    // v1: сообщение ошибки печатает rc_fail; рендерер добавляет extra и данные.
    let message = error.get("message").and_then(Value::as_str).unwrap_or_default();
    let _ = writeln!(io::stderr().lock(), "  [✗] {message}");
    if code == "confirmation_required" || code == "plan_changed" {
        writeln!(stdout, "Требуется подтверждение:")?;
        if let Some(Value::Array(lines)) = error.get("plan") {
            for line in lines {
                writeln!(stdout, "  {}", cell(line))?;
            }
        }
        let _ = writeln!(io::stderr().lock(), "  [!] Повторите команду с --yes.");
    }
    for (key, value) in &error {
        // Код и сообщение уже выведены; план напечатан; `secret` — подсказка
        // для повторного ввода.
        if matches!(key.as_str(), "code" | "message" | "plan" | "plan_token" | "secret") {
            continue;
        }
        writeln!(stdout, "  {key}: {}", cell(value))?;
    }
    if let Some(data) = &output.data {
        for line in render_value(data, "") {
            writeln!(stdout, "{line}")?;
        }
    }
    stdout.flush()
}

fn render_value(value: &Value, indent: &str) -> Vec<String> {
    let mut lines = Vec::new();
    match value {
        Value::Array(items) if !items.is_empty() && items.iter().all(Value::is_object) => {
            lines.extend(render_table(items, indent));
        }
        Value::Array(items) if !items.is_empty() => {
            for item in items {
                lines.push(format!("{indent}{}", cell(item)));
            }
        }
        Value::Array(_) => {}
        Value::Object(map) => {
            for (key, item) in map {
                if item.as_object().is_some_and(|entries| !entries.is_empty())
                    || is_object_array(item)
                {
                    lines.push(format!("{indent}{key}:"));
                    lines.extend(render_value(item, &format!("{indent}  ")));
                } else {
                    lines.push(format!("{indent}{key}: {}", cell(item)));
                }
            }
        }
        other => lines.push(format!("{indent}{}", cell(other))),
    }
    lines
}

fn is_object_array(value: &Value) -> bool {
    value
        .as_array()
        .is_some_and(|items| !items.is_empty() && items.iter().all(Value::is_object))
}

/// Таблица объектов: колонки — объединение ключей в порядке появления,
/// выравнивание по ширине, две позиции между колонками (рендерер v1).
fn render_table(items: &[Value], indent: &str) -> Vec<String> {
    let mut columns: Vec<&str> = Vec::new();
    for item in items {
        for key in item.as_object().into_iter().flat_map(|map| map.keys()) {
            if !columns.contains(&key.as_str()) {
                columns.push(key.as_str());
            }
        }
    }
    let mut rows: Vec<Vec<String>> = vec![columns.iter().map(|key| (*key).to_string()).collect()];
    for item in items {
        let map = item.as_object().expect("таблица строится из объектов");
        rows.push(
            columns
                .iter()
                .map(|key| cell(map.get(*key).unwrap_or(&Value::Null)))
                .collect(),
        );
    }
    let widths: Vec<usize> = (0..columns.len())
        .map(|index| rows.iter().map(|row| row[index].chars().count()).max().unwrap_or(0))
        .collect();
    let mut lines = Vec::new();
    for row in &rows {
        let mut line = String::from(indent);
        for (index, cell_text) in row.iter().enumerate() {
            if index == row.len() - 1 {
                line.push_str(cell_text);
            } else {
                line.push_str(cell_text);
                let pad = widths[index].saturating_sub(cell_text.chars().count());
                line.push_str(&" ".repeat(pad));
                line.push_str("  ");
            }
        }
        lines.push(line);
    }
    lines
}

fn cell(value: &Value) -> String {
    match value {
        Value::Null => "—".to_string(),
        Value::Bool(true) => "да".to_string(),
        Value::Bool(false) => "нет".to_string(),
        Value::String(text) => text.clone(),
        Value::Number(number) => format_number(number),
        Value::Array(items) if items.iter().all(|item| !item.is_object() && !item.is_array()) => {
            if items.is_empty() {
                "—".to_string()
            } else {
                items.iter().map(cell_scalar).collect::<Vec<_>>().join(", ")
            }
        }
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

fn cell_scalar(value: &Value) -> String {
    match value {
        Value::Null => "—".to_string(),
        Value::Bool(true) => "да".to_string(),
        Value::Bool(false) => "нет".to_string(),
        Value::Number(number) => format_number(number),
        Value::String(text) => text.clone(),
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

fn format_number(number: &serde_json::Number) -> String {
    if let Some(value) = number.as_u64() {
        value.to_string()
    } else if let Some(value) = number.as_i64() {
        value.to_string()
    } else if let Some(value) = number.as_f64() {
        // jq печатает целые значения float без дробной части.
        if value.is_finite() && value.fract() == 0.0 && value.abs() < 1e15 {
            format!("{}", value as i64)
        } else {
            format!("{value}")
        }
    } else {
        number.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(words: &[&str]) -> Vec<String> {
        words.iter().map(|word| (*word).to_owned()).collect()
    }

    #[test]
    fn listener_flags_make_certificate_paths_absolute() {
        let cwd = std::env::current_dir().unwrap();
        for argv in [
            args(&["web", "start", "--tls-cert", "c.pem", "--tls-key=k/k.pem", "--port", "9", "--bind", "0.0.0.0"]),
            args(&["daemon", "start", "--web", "--tls-cert", "c.pem", "--tls-key=k/k.pem", "--port", "9", "--bind", "0.0.0.0"]),
        ] {
            let flags = listener_flags(&cli::parse_client(&argv).unwrap()).unwrap();
            let cert = cwd.join("c.pem").to_string_lossy().into_owned();
            let key = cwd.join("k/k.pem").to_string_lossy().into_owned();
            assert_eq!(flags, args(&["--bind", "0.0.0.0", "--port", "9", "--tls-cert", &cert, "--tls-key", &key]), "{argv:?}");
        }
        let absolute = if cfg!(windows) { r"C:\certs\c.pem" } else { "/certs/c.pem" };
        let flags = listener_flags(&cli::parse_client(&args(&["web", "start", "--tls-cert", absolute, "--tls-key", absolute, "--no-tls"])).unwrap()).unwrap();
        assert_eq!(flags, args(&["--tls-cert", absolute, "--tls-key", absolute, "--no-tls"]));
    }

    fn export(words: &[&str]) -> Result<Export> {
        export_preflight(&cli::parse_client(&args(words)).unwrap())
    }

    #[test]
    fn objects_render_as_indented_key_value() {
        let lines = render_value(&json!({"version": "2.0.0", "counts": {"nodes": 2, "clients": 0}}), "");
        assert_eq!(lines, vec!["version: 2.0.0", "counts:", "  nodes: 2", "  clients: 0"]);
    }

    #[test]
    fn object_arrays_render_as_tables() {
        let lines = render_value(&json!([{"name": "lab", "port": 22}, {"name": "long-name", "port": null}]), "");
        assert_eq!(lines[0], "name       port");
        assert_eq!(lines[1], "lab        22");
        assert_eq!(lines[2], "long-name  —");
    }

    #[test]
    fn scalars_use_v1_words() {
        assert_eq!(cell(&Value::Null), "—");
        assert_eq!(cell(&Value::Bool(true)), "да");
        assert_eq!(cell(&Value::Bool(false)), "нет");
        assert_eq!(cell(&json!(["a", true, null])), "a, да, —");
        assert_eq!(cell(&json!([])), "—");
        assert_eq!(cell(&json!(1.5)), "1.5");
    }

    #[test]
    fn envelope_keeps_key_order_and_omits_absent_fields() {
        let mut reply = Reply::success(json!({"n": 1}));
        reply.sync = json!("pending");
        let output = Output::from_reply(reply);
        assert_eq!(serde_json::to_string(&output.envelope()).unwrap(), r#"{"id":null,"ok":true,"data":{"n":1},"sync":"pending"}"#);
        assert_eq!(output.exit, 0);
        let mut reply = Reply::failure("usage");
        reply.error = json!({"code": "usage", "message": "m"});
        reply.exit = Some(2);
        let output = Output::from_reply(reply);
        assert_eq!(serde_json::to_string(&output.envelope()).unwrap(), r#"{"id":null,"ok":false,"error":{"code":"usage","message":"m"}}"#);
        assert_eq!(output.exit, 2);
        let local = Output::from_error(RcError::new("confirmation_required", "x").with_extra("plan", json!(["p"])));
        assert_eq!(local.exit, 2);
        assert_eq!(local.envelope(), json!({"id": null, "ok": false, "error": {"code": "confirmation_required", "message": "x", "plan": ["p"]}}));
    }

    #[test]
    fn exit_falls_back_to_the_catalog_rule() {
        let mut reply = Reply::failure("tty_required");
        reply.error = json!({"code": "tty_required", "message": "m"});
        assert_eq!(Output::from_reply(reply).exit, 2);
    }

    #[test]
    fn implicit_session_open_skips_status_and_daemon_commands() {
        let opens = |words: &[&str]| opens_session(&cli::parse_client(&args(words)).unwrap());
        assert!(opens(&["group", "list"]));
        assert!(opens(&["source", "github-connect"]));
        assert!(opens(&["status"]));
        for words in [&["session", "status"][..], &["session", "open"], &["self", "version"], &["daemon", "status"], &["help"]] {
            assert!(!opens(words), "{words:?}");
        }
    }

    #[test]
    fn input_files_are_required_read_and_validated() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("t.yaml");
        fs::write(&file, "mode: rule\n").unwrap();
        let file_arg = file.to_str().unwrap();
        let invocation = cli::parse_client(&args(&["template", "import", "--name", "t", "--file", file_arg])).unwrap();
        read_inputs(&invocation).unwrap();
        assert_eq!(invocation.daemon_argv(&args(&["template", "import", "--name", "t", "--file", file_arg])),
            args(&["template", "import", "--name", "t"]));
        let missing = cli::parse_client(&args(&["template", "import", "--name", "t"])).unwrap();
        let error = read_inputs(&missing).err().unwrap();
        assert_eq!((error.code, error.message.as_str()), ("usage", "Укажите файл: --file PATH."));
        let dir_arg = dir.path().to_str().unwrap();
        assert_eq!(read_input_file(dir_arg).err().unwrap().message, format!("Файл {dir_arg} недоступен."));
        let binary = dir.path().join("bin");
        fs::write(&binary, [0xff, 0x00]).unwrap();
        let error = read_input_file(binary.to_str().unwrap()).err().unwrap();
        assert_eq!(error.code, "invalid");
        assert!(error.message.ends_with("не в кодировке UTF-8."), "{}", error.message);
        let large = dir.path().join("large");
        fs::write(&large, vec![b'a'; client::files::MAX_INPUT + 1]).unwrap();
        let large_arg = large.to_str().unwrap();
        assert_eq!(read_input_file(large_arg).err().unwrap().message, format!("Файл {large_arg} больше 1 МиБ."));
        assert_eq!(client::files::MAX_INPUT, rc_core::request_input::Input::MAX_VALUE, "the daemon's input limit");
        #[cfg(unix)]
        {
            let link = dir.path().join("link.yaml");
            std::os::unix::fs::symlink(&file, &link).unwrap();
            let link_arg = link.to_str().unwrap();
            assert_eq!(read_input_file(link_arg).err().unwrap().message, format!("Файл {link_arg} недоступен."), "links are refused");
        }
    }

    /// Семантика удалённой `templates::export` ядра: каталог отклоняется,
    /// существующий файл требует подтверждения, ссылка не разыменовывается.
    #[test]
    fn export_gates_existing_entries_and_never_follows_links() {
        let out = tempfile::tempdir().unwrap();
        let target = out.path().join("t.yaml");
        let target_arg = target.to_str().unwrap();
        let fresh = export(&["template", "export", "--name", "default", "--output", target_arg]).unwrap();
        assert_eq!((fresh.name.as_str(), fresh.output.as_str(), fresh.replace), ("default", target_arg, false));
        // A file that appeared after the check is kept: the overwrite was not confirmed.
        fs::write(&target, "APPEARED\n").unwrap();
        let error = write_export(&fresh, "TEMPLATE\n").err().unwrap();
        assert_eq!((error.code, error.message), ("conflict", format!("Файл {target_arg} появился во время экспорта: повторите команду.")));
        assert_eq!(fs::read_to_string(&target).unwrap(), "APPEARED\n");
        fs::remove_file(&target).unwrap();
        write_export(&fresh, "TEMPLATE\n").unwrap();
        assert_eq!(fs::read_to_string(&target).unwrap(), "TEMPLATE\n");

        fs::write(&target, "IMPORTANT\n").unwrap();
        let error = export(&["template", "export", "--name", "default", "--output", target_arg]).err().unwrap();
        assert_eq!((error.code, error.exit), ("confirmation_required", 2));
        assert_eq!(error.extra["plan"], json!([format!("Файл {target_arg} будет перезаписан шаблоном default.yaml.")]));
        assert_eq!(fs::read_to_string(&target).unwrap(), "IMPORTANT\n");
        let confirmed = export(&["template", "export", "--name", "default", "--output", target_arg, "--yes"]).unwrap();
        assert!(confirmed.replace);
        write_export(&confirmed, "TEMPLATE\n").unwrap();
        assert_eq!(fs::read_to_string(&target).unwrap(), "TEMPLATE\n");

        let dir_arg = out.path().to_str().unwrap();
        assert_eq!(export(&["template", "export", "--name", "default", "--output", dir_arg, "--yes"]).err().unwrap().code, "invalid");
        assert_eq!(export(&["template", "export", "--name", "default"]).err().unwrap().code, "usage");
        let missing_parent = format!("{}/absent/victim", out.path().display());
        let orphan = export(&["template", "export", "--name", "default", "--output", &missing_parent]).unwrap();
        assert_eq!(write_export(&orphan, "x").err().unwrap().code, "failed");

        #[cfg(unix)]
        {
            let link = out.path().join("link");
            let pointed = out.path().join("newtarget");
            std::os::unix::fs::symlink(&pointed, &link).unwrap();
            let link_arg = link.to_str().unwrap();
            assert_eq!(export(&["template", "export", "--name", "default", "--output", link_arg]).err().unwrap().code,
                "confirmation_required");
            assert!(!pointed.exists());
            let link_export = export(&["template", "export", "--name", "default", "--output", link_arg, "--yes"]).unwrap();
            write_export(&link_export, "TEMPLATE\n").unwrap();
            assert!(!pointed.exists());
            assert!(fs::symlink_metadata(&link).unwrap().is_file());
        }
    }

    /// Паритет с ядром develop: ключ из каталога данных локального демона
    /// отклоняется тем же кодом и текстом; удалённый каталог не проверяется.
    #[test]
    fn recovery_key_inside_the_local_data_dir_is_refused() {
        let base = tempfile::tempdir().unwrap();
        let data = base.path().join("data");
        fs::create_dir_all(&data).unwrap();
        let (inside, outside) = (data.join("key.txt"), base.path().join("key.txt"));
        let import = |path: &Path| cli::parse_client(&args(&["source", "github-import-recovery-key", "--file", path.to_str().unwrap()])).unwrap();
        let error = refuse_key_in_data_dir(&import(&inside), Some(&data)).err().unwrap();
        assert_eq!((error.code, error.message.as_str()), ("invalid", client::files::RECOVERY_KEY_REFUSED));
        refuse_key_in_data_dir(&import(&outside), Some(&data)).unwrap();
        refuse_key_in_data_dir(&import(&inside), None).unwrap();
        let template = cli::parse_client(&args(&["template", "import", "--name", "t", "--file", inside.to_str().unwrap()])).unwrap();
        refuse_key_in_data_dir(&template, Some(&data)).unwrap();
    }

    #[test]
    fn client_errors_map_to_catalog_codes() {
        assert_eq!(client_error(&io::Error::new(ErrorKind::PermissionDenied, "x")).code, "unsafe_path");
        assert_eq!(client_error(&io::Error::new(ErrorKind::InvalidInput, "x")).code, "invalid");
        assert_eq!(client_error(&io::Error::other("x")).code, "failed");
        let crash = request_error(&io::Error::new(ErrorKind::UnexpectedEof, "x"));
        assert_eq!((crash.code, crash.message.as_str()), ("failed", "Ядро завершилось аварийно."));
    }

    #[test]
    fn session_secret_is_prompted_only_when_allowed() {
        let open = cli::parse(&args(&["session", "open"])).unwrap();
        let secrets = Secrets::default();
        assert_eq!(prompt_target(&open, &secrets, &json!({"code": "auth_required", "secret": "script-password"})), Some("script-password"));
        let list = cli::parse_client(&args(&["group", "list"])).unwrap();
        assert_eq!(prompt_target(&list, &secrets, &json!({"code": "auth_required", "secret": "script-password"})), None);
    }
}
