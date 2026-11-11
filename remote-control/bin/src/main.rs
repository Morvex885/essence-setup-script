//! `essence-rc` — фронтенд: разовый CLI и serve v2.
//!
//! Никакой логики команд здесь нет: argv проходит через общий парсер и
//! единственный асинхронный dispatch ядра. Бинарник отвечает только за
//! транспорт — конверт JSON или русский человекочитаемый вывод, скрытый ввод
//! секретов с консоли, защиту от сигналов, протокол serve и аварийный ответ
//! при панике.

mod serve;
mod terminal;

use std::collections::HashMap;
use std::io::{self, IsTerminal, Read, Write};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use rc_core::cli::{self, Invocation};
use rc_core::dispatch::{self, DispatchMode, Envelope, Session};
use rc_core::error::{RcError, Result};
use rc_core::log::{self, Level, LogSink};
use rc_core::request_secrets::Secrets;
use rc_core::state::{State, StatePaths};
use rc_core::VERSION;
use serde_json::Value;
use zeroize::Zeroizing;

/// Скрытый ввод секрета: максимум три попытки на имя (цикл сессии v1).
const MAX_SECRET_ATTEMPTS: u8 = 3;

fn main() -> ExitCode {
    install_panic_hook();
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.is_empty() && io::stdin().is_terminal() && io::stdout().is_terminal() {
        // The menu runs in this process (library crate without rc-core); it
        // installs its own panic hook and signal policy and spawns this same
        // executable as `serve --inner` for every core operation.
        return essence_rc_tui::run_terminal();
    }
    // --version/-V обслуживается бинарником до парсера.
    if argv.iter().any(|arg| arg == "--version" || arg == "-V") {
        println!("essence-rc {VERSION}");
        return ExitCode::SUCCESS;
    }
    if argv.first().is_some_and(|arg| arg == "serve") {
        return serve::run(&argv[1..]);
    }
    one_shot(argv)
}

// ─── Паника: один аварийный ответ, без payload ───────────────────────────────

/// Общее состояние паники: активный id запроса serve и режим ответа. Хук
/// никогда не печатает payload паники — там могут оказаться секреты.
struct PanicState {
    serve: AtomicBool,
    json: AtomicBool,
    responded: AtomicBool,
    active: Mutex<Option<Value>>,
}

fn panic_state() -> &'static PanicState {
    static STATE: PanicState = PanicState {
        serve: AtomicBool::new(false),
        json: AtomicBool::new(false),
        responded: AtomicBool::new(false),
        active: Mutex::new(None),
    };
    &STATE
}

impl PanicState {
    fn serve_mode(&self) {
        self.serve.store(true, Ordering::SeqCst);
    }
    fn json_mode(&self, json: bool) {
        self.json.store(json, Ordering::SeqCst);
    }
    fn is_serve(&self) -> bool {
        self.serve.load(Ordering::SeqCst)
    }
    fn is_json(&self) -> bool {
        self.json.load(Ordering::SeqCst)
    }
    fn set_active(&self, id: Value) {
        *self.lock_active() = Some(id);
    }
    fn clear_active(&self) {
        *self.lock_active() = None;
    }
    fn take_active(&self) -> Option<Value> {
        self.lock_active().take()
    }
    fn lock_active(&self) -> std::sync::MutexGuard<'_, Option<Value>> {
        self.active.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

fn install_panic_hook() {
    std::panic::set_hook(Box::new(|_| respond_to_panic()));
}

/// Ровно один аварийный ответ для активного id и выход 1. Сообщение —
/// фиксированная sanitized строка; payload паники отбрасывается намеренно.
/// Выход без раскрутки стека: сырой режим консоли восстанавливается здесь.
fn respond_to_panic() {
    terminal::restore_console();
    let state = panic_state();
    if state.responded.swap(true, Ordering::SeqCst) {
        std::process::exit(1);
    }
    let message = if state.is_serve() {
        "Ядро завершилось аварийно."
    } else {
        "Команда прервана."
    };
    if state.is_serve() || state.is_json() {
        let id = if state.is_serve() { state.take_active().unwrap_or(Value::Null) } else { Value::Null };
        let line = serde_json::json!({
            "id": id,
            "ok": false,
            "error": {"code": "failed", "message": message},
        });
        let _ = writeln!(io::stdout().lock(), "{line}");
    }
    let _ = writeln!(io::stderr().lock(), "  [✗] {message}");
    std::process::exit(1);
}

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

/// Журнал разового вызова — в stderr с префиксами v1 (и при --json: stdout
/// отдан единственному конверту).
struct StderrSink;

impl LogSink for StderrSink {
    fn log(&mut self, level: Level, text: &str) {
        let _ = writeln!(io::stderr().lock(), "{}{}", level.prefix(), log::sanitize(text));
    }
}

// ─── Разовый CLI ─────────────────────────────────────────────────────────────

fn one_shot(argv: Vec<String>) -> ExitCode {
    let json = argv.iter().any(|arg| arg == "--json");
    panic_state().json_mode(json);
    let invocation = match cli::parse(&argv) {
        Ok(invocation) => invocation,
        Err(error) => return finish(Envelope::failure(error), json, None),
    };
    let mut secrets = Secrets::default();
    if invocation.secrets_stdin {
        match read_stdin_secrets() {
            Ok(read) => secrets = read,
            Err(error) => return finish(Envelope::failure(error), json, Some(&invocation)),
        }
    }
    let state = match StatePaths::discover().map(State::new) {
        Ok(state) => state,
        Err(error) => return finish(Envelope::failure(error), json, Some(&invocation)),
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            let error = RcError::new("failed", format!("Не удалось запустить среду выполнения: {error}"));
            return finish(Envelope::failure(error), json, Some(&invocation));
        }
    };
    // Поздний Ctrl+C не должен оборвать ни команду, ни запись ответа.
    let _signals = SignalGuard::install_on(&runtime);
    let mut session = Session::new(state, DispatchMode::OneShot, Box::new(StderrSink));
    // Терминальные команды (node shell) работают с управляющим терминалом.
    if invocation.requires_tty() {
        session.set_console(Box::new(terminal::TerminalConsole));
    }
    let mut prompts = SecretPrompts::default();
    let mut envelope = runtime.block_on(dispatch::dispatch(&argv, &secrets, &mut session));
    // Повтор только для отказа до мутации: пусто/неверно/отсутствует.
    while prompts.missing(&invocation, &mut secrets, &envelope) {
        envelope = runtime.block_on(dispatch::dispatch(&argv, &secrets, &mut session));
    }
    if let Err(error) = session.close() {
        let _ = writeln!(io::stderr().lock(), "  [!] Не удалось закрыть сессию: {}", error.message);
    }
    finish(envelope, json, Some(&invocation))
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

/// Вывод финального конверта: с --json — ровно одна строка JSON на stdout;
/// без него — русский человекочитаемый вывод (сообщение ошибки на stderr).
fn finish(envelope: Envelope, json: bool, invocation: Option<&Invocation>) -> ExitCode {
    if emit(&envelope, json, invocation).is_err() {
        // stdout закрыт (EPIPE): json-ответ хотя бы на stderr.
        if json {
            if let Ok(line) = serde_json::to_string(&envelope) {
                let _ = writeln!(io::stderr().lock(), "{line}");
            }
        }
        return ExitCode::FAILURE;
    }
    ExitCode::from(envelope.exit_code())
}

fn emit(envelope: &Envelope, json: bool, invocation: Option<&Invocation>) -> io::Result<()> {
    if json {
        let line = serde_json::to_string(envelope).map_err(io::Error::other)?;
        let mut stdout = io::stdout().lock();
        writeln!(stdout, "{line}")?;
        stdout.flush()
    } else {
        render_human(envelope, invocation)
    }
}

// ─── Повтор со скрытым вводом секрета ────────────────────────────────────────

/// Консольные попытки по именам секретов (как счётчики сессии v1).
#[derive(Default)]
struct SecretPrompts {
    attempts: HashMap<&'static str, u8>,
}

impl SecretPrompts {
    /// Спросить недостающий секрет и перезапустить команду. Только коды
    /// отказа до мутации, только разрешённые командой секреты, только при
    /// живой консоли; подтверждения никогда не спрашиваются.
    fn missing(&mut self, invocation: &Invocation, secrets: &mut Secrets, envelope: &Envelope) -> bool {
        if envelope.ok || !terminal::console_available() {
            return false;
        }
        let Some(error) = &envelope.error else {
            return false;
        };
        if !matches!(error.code, "auth_required" | "auth_failed" | "missing_secret"
            | "vault_password_required" | "vault_password_invalid" | "new_vault_password_required") {
            return false;
        }
        let Some(name) = prompt_target(invocation, secrets, error) else {
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

/// Какой секрет спросить: подсказка ядра (`extra.secret`), иначе единственный
/// незаполненный секрет команды. Секреты сессии разового вызова
/// (script-password, vault-password) допустимы для любой защищённой команды.
fn prompt_target(invocation: &Invocation, secrets: &Secrets, error: &RcError) -> Option<&'static str> {
    const SESSION: [&str; 2] = ["script-password", "vault-password"];
    let allowed = invocation.allowed_secrets();
    let find = |name: &str| allowed.iter().chain(SESSION.iter()).copied().find(|candidate| *candidate == name);
    let hint = error.extra.get("secret").and_then(Value::as_str).and_then(find);
    match error.code {
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

fn render_human(envelope: &Envelope, invocation: Option<&Invocation>) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    if envelope.ok {
        if let Some(invocation) = invocation.filter(|invocation| invocation.help) {
            write!(stdout, "{}", cli::render_help(invocation.help_noun()))?;
            return stdout.flush();
        }
        if let Some(data) = &envelope.data {
            for line in render_value(data, "") {
                writeln!(stdout, "{line}")?;
            }
        }
        return stdout.flush();
    }
    let error = envelope
        .error
        .as_ref()
        .expect("конверт с ok:false несёт ошибку");
    // v1: сообщение ошибки печатает rc_fail; рендерер добавляет extra и данные.
    let _ = writeln!(io::stderr().lock(), "  [✗] {}", error.message);
    if error.code == "confirmation_required" || error.code == "plan_changed" {
        writeln!(stdout, "Требуется подтверждение:")?;
        if let Some(Value::Array(lines)) = error.extra.get("plan") {
            for line in lines {
                writeln!(stdout, "  {}", cell(line))?;
            }
        }
        let _ = writeln!(io::stderr().lock(), "  [!] Повторите команду с --yes.");
    }
    for (key, value) in &error.extra {
        // План уже напечатан; `secret` — подсказка для повторного ввода.
        if matches!(key.as_str(), "plan" | "plan_token" | "secret") {
            continue;
        }
        writeln!(stdout, "  {key}: {}", cell(value))?;
    }
    if let Some(data) = &envelope.data {
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

    #[test]
    fn objects_render_as_indented_key_value() {
        let lines = render_value(
            &serde_json::json!({"version": "2.0.0", "counts": {"nodes": 2, "clients": 0}}),
            "",
        );
        assert_eq!(
            lines,
            vec!["version: 2.0.0", "counts:", "  nodes: 2", "  clients: 0"]
        );
    }

    #[test]
    fn object_arrays_render_as_tables() {
        let lines = render_value(
            &serde_json::json!([{"name": "lab", "port": 22}, {"name": "long-name", "port": null}]),
            "",
        );
        assert_eq!(lines[0], "name       port");
        assert_eq!(lines[1], "lab        22");
        assert_eq!(lines[2], "long-name  —");
    }

    #[test]
    fn scalars_use_v1_words() {
        assert_eq!(cell(&Value::Null), "—");
        assert_eq!(cell(&Value::Bool(true)), "да");
        assert_eq!(cell(&Value::Bool(false)), "нет");
        assert_eq!(cell(&serde_json::json!(["a", true, null])), "a, да, —");
        assert_eq!(cell(&serde_json::json!([])), "—");
        assert_eq!(cell(&serde_json::json!(1.5)), "1.5");
    }
}
