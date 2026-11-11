//! `essence-rc serve` — протокол JSON-строк v2 (stdio).
//!
//! stdout несёт только протокол: приветствие `hello`, затем на каждый запрос
//! события журнала и ровно одну строку-ответ. Диагностика — на stderr. Запросы
//! выполняются строго по одному; SIGINT/SIGPIPE не прерывают выполняемую
//! команду (v1 `trap '' INT PIPE` на всё время serve); EOF stdin закрывает
//! сессию и завершает процесс с кодом 0. Паника ядра получает один аварийный
//! ответ для активного id (хук в main), без payload на stderr.

use std::cell::RefCell;
use std::io::{self, BufRead, Write};
use std::process::ExitCode;
use std::rc::Rc;

use rc_core::dispatch::{self, DispatchMode, Envelope, Session};
use rc_core::error::RcError;
use rc_core::log::{self, Level, LogSink};
use rc_core::request_secrets::Secrets;
use rc_core::state::{State, StatePaths};
use rc_core::VERSION;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use zeroize::Zeroizing;

use crate::{panic_state, SignalGuard};

const SERVE_HELP: &str = "
  Использование: essence-rc serve [--inner]

  Протокол JSON-строк для интерфейсов (TUI, веб, приложение).
  stdout, первая строка:  {\"event\":\"hello\",\"protocol\":2,\"version\":\"X\"}
  Запрос (строка stdin):  {\"id\":1,\"argv\":[\"group\",\"list\"],\"secrets\":{\"password\":\"…\"}}
    id — строка, число или null; argv — массив строк; secrets — необязательный объект строк.
  События до ответа:      {\"id\":1,\"event\":\"log\",\"level\":\"info|success|warn|error|output\",\"text\":\"…\"}
  Ответ:                  {\"id\":1,\"ok\":true,\"data\":…} или {\"id\":1,\"ok\":false,\"error\":{\"code\",\"message\",…}}

  Сначала session open (секрет script-password), иначе session_closed.
  Опасная команда без --yes отвечает confirmation_required с plan и plan_token;
  выполнение — тот же argv с --yes --plan-token T, изменившийся план — plan_changed.
  Запросы выполняются по одному; Ctrl+C не прерывает команду; EOF stdin завершает serve.
  --inner — приватный режим терминального меню: терминальные команды (node shell,
  telegram menu) работают на управляющем терминале, пока меню приостановлено.
";

/// Разбор аргументов после `serve` и запуск сессии протокола.
pub fn run(args: &[String]) -> ExitCode {
    let mut inner = false;
    for arg in args {
        match arg.as_str() {
            // The TUI's private child: it shares the TUI's controlling terminal,
            // so `!tty` commands run here, inside the one open session (a
            // second one-shot process would hit the session lock: `locked`).
            "--inner" => inner = true,
            "--secrets-stdin" => {
                let _ = writeln!(io::stderr().lock(), "  [!] В serve секреты передаются полем secrets.");
                return ExitCode::from(2);
            }
            "--help" | "-h" | "help" => {
                let mut stdout = io::stdout().lock();
                let _ = stdout.write_all(SERVE_HELP.as_bytes());
                let _ = stdout.flush();
                return ExitCode::SUCCESS;
            }
            _ => {
                let _ = writeln!(
                    io::stderr().lock(),
                    "  [!] Неизвестный аргумент serve. Справка: essence-rc serve --help"
                );
                return ExitCode::from(2);
            }
        }
    }
    session(inner)
}

/// id активного запроса, общий для цикла serve и приёмника журнала.
type ActiveId = Rc<RefCell<Value>>;

/// Журнал команды → события `log` протокола с id активного запроса.
struct ProtocolSink(ActiveId);

#[derive(Serialize)]
struct LogEvent<'a> {
    id: &'a Value,
    event: &'static str,
    level: Level,
    text: String,
}

impl LogSink for ProtocolSink {
    fn log(&mut self, level: Level, text: &str) {
        let id = self.0.borrow();
        // Ошибка записи всплывёт на строке ответа и завершит serve.
        let _ = write_line(&LogEvent { id: &id, event: "log", level, text: log::sanitize(text) });
    }
}

fn session(inner: bool) -> ExitCode {
    panic_state().serve_mode();
    let state = match StatePaths::discover().map(State::new) {
        Ok(state) => state,
        Err(error) => {
            let _ = writeln!(io::stderr().lock(), "  [✗] {}", error.message);
            return ExitCode::FAILURE;
        }
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            let _ = writeln!(io::stderr().lock(), "  [✗] Не удалось запустить среду выполнения: {error}");
            return ExitCode::FAILURE;
        }
    };
    // v1 `trap '' INT PIPE`: сигналы игнорируются всё время serve, завершение — EOF.
    let _signals = SignalGuard::install_on(&runtime);
    let active = ActiveId::default();
    let mut session = Session::new(state, DispatchMode::Serve, Box::new(ProtocolSink(active.clone())));
    if inner {
        session.set_console(Box::new(crate::terminal::TerminalConsole));
    }
    if let Err(error) = greet() {
        let _ = writeln!(io::stderr().lock(), "  [✗] Не удалось записать приветствие serve: {error}");
        let _ = session.close();
        return ExitCode::FAILURE;
    }
    let result = requests(&runtime, &mut session, &active);
    let _ = session.close();
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            let _ = writeln!(io::stderr().lock(), "  [✗] Протокол serve прерван: {error}");
            ExitCode::FAILURE
        }
    }
}

#[derive(Serialize)]
struct Hello {
    event: &'static str,
    protocol: u8,
    version: &'static str,
}

fn greet() -> io::Result<()> {
    write_line(&Hello { event: "hello", protocol: 2, version: VERSION })
}

/// Чтение строк запросов до EOF; строго последовательная обработка. Строка
/// запроса содержит секреты, поэтому буфер стирается.
fn requests(runtime: &tokio::runtime::Runtime, session: &mut Session, active: &ActiveId) -> io::Result<()> {
    let stdin = io::stdin();
    let mut reader = io::BufReader::new(stdin.lock());
    let mut buffer = Zeroizing::new(Vec::with_capacity(4096));
    loop {
        buffer.clear();
        // Ошибка чтения stdin эквивалентна EOF: сессия закрывается штатно.
        match reader.read_until(b'\n', &mut buffer) {
            Ok(0) | Err(_) => return Ok(()),
            Ok(_) => {}
        }
        let line = trim_eol(&buffer);
        if line.is_empty() {
            continue;
        }
        match std::str::from_utf8(line) {
            Ok(text) => handle(runtime, session, active, text)?,
            Err(_) => reply(Value::Null, RcError::new("usage", "Неверный запрос."))?,
        }
    }
}

/// Поля запроса кроме секретов; секреты разбираются отдельно сразу в
/// Zeroizing-контейнер. Прочие поля игнорируются, как в v1.
#[derive(Deserialize)]
struct Head {
    #[serde(default)]
    id: Value,
    #[serde(default)]
    argv: Value,
}

#[derive(Deserialize)]
struct Body {
    #[serde(default)]
    secrets: Option<Secrets>,
}

/// Корректный id сохраняется в ответе даже для неверного тела запроса (v1);
/// неразборчивая строка или неверный id — ответ с `id:null`.
fn handle(runtime: &tokio::runtime::Runtime, session: &mut Session, active: &ActiveId, text: &str) -> io::Result<()> {
    let Ok(head) = serde_json::from_str::<Head>(text) else {
        return reply(Value::Null, RcError::new("usage", "Неверный запрос."));
    };
    let id = match head.id {
        Value::String(text) if !text.contains('\0') => Value::String(text),
        id @ (Value::Number(_) | Value::Null) => id,
        _ => return reply(Value::Null, RcError::new("usage", "Неверный запрос.")),
    };
    let Some(argv) = parse_argv(&head.argv) else {
        return reply(id, RcError::new("usage", "Неверный запрос."));
    };
    let secrets = match serde_json::from_str::<Body>(text) {
        Ok(body) => body.secrets.unwrap_or_default(),
        Err(_) => return reply(id, RcError::new("usage", "Секреты должны быть JSON-объектом строк из списка разрешённых.")),
    };
    *active.borrow_mut() = id.clone();
    panic_state().set_active(id.clone());
    let mut envelope = runtime.block_on(dispatch::dispatch(&argv, &secrets, session));
    drop(secrets);
    panic_state().clear_active();
    *active.borrow_mut() = Value::Null;
    envelope.id = id;
    write_line(&envelope)
}

fn parse_argv(value: &Value) -> Option<Vec<String>> {
    value.as_array()?.iter()
        .map(|item| item.as_str().filter(|text| !text.contains('\0')).map(str::to_owned))
        .collect()
}

fn reply(id: Value, error: RcError) -> io::Result<()> {
    let mut envelope = Envelope::failure(error);
    envelope.id = id;
    write_line(&envelope)
}

fn write_line(value: &impl Serialize) -> io::Result<()> {
    let text = serde_json::to_string(value).map_err(io::Error::other)?;
    let mut stdout = io::stdout().lock();
    writeln!(stdout, "{text}")?;
    stdout.flush()
}

fn trim_eol(bytes: &[u8]) -> &[u8] {
    let line = bytes.strip_suffix(b"\n").unwrap_or(bytes);
    line.strip_suffix(b"\r").unwrap_or(line)
}
