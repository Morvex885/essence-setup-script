//! `essence-rc` — фронтенд: меню, разовый CLI и демон.
//!
//! Никакой логики команд здесь нет: ядро выполняется только в демоне
//! (`daemon run`), меню и разовый CLI — его клиенты по локальному сокету.
//! Бинарник отвечает за маршрутизацию, вывод конверта JSON или русского
//! человекочитаемого текста, скрытый ввод секретов с консоли, защиту от
//! сигналов и аварийный ответ при панике.

mod daemon;
mod oneshot;
mod terminal;

use std::io::{self, IsTerminal, Write};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};

use oneshot::Output;
use rc_core::VERSION;
use rc_core::cli;

fn main() -> ExitCode {
    install_panic_hook();
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.is_empty() && io::stdin().is_terminal() && io::stdout().is_terminal() {
        return run_menu();
    }
    // --version/-V обслуживается бинарником до парсера.
    if argv.iter().any(|arg| arg == "--version" || arg == "-V") {
        println!("essence-rc {VERSION}");
        return ExitCode::SUCCESS;
    }
    let json = argv.iter().any(|arg| arg == "--json");
    set_json_mode(json);
    let invocation = match cli::parse_client(&argv) {
        Ok(invocation) => invocation,
        Err(error) => return oneshot::finish(Output::from_error(error), json, None),
    };
    if invocation.help {
        return oneshot::finish(Output::success(cli::help(invocation.help_noun())), json, Some(&invocation));
    }
    match (invocation.noun.as_str(), invocation.verb.as_str()) {
        ("daemon", "run") => daemon::run(daemon::Options { persistent: false }),
        ("daemon", "start") => oneshot::daemon_start(&invocation),
        _ => oneshot::run(&argv, &invocation),
    }
}

/// Меню в этом процессе (библиотека без rc-core) поверх клиента демона; оно
/// само ставит хук паники и политику сигналов.
fn run_menu() -> ExitCode {
    match oneshot::connect() {
        Ok((client, _)) => essence_rc_tui::run_terminal(essence_rc_tui::Frontend {
            client: Box::new(client),
            terminal: Box::new(|| Box::new(terminal::TerminalConsole::new())),
        }),
        Err(error) => {
            let _ = writeln!(io::stderr().lock(), "  [!] {}", error.message);
            ExitCode::FAILURE
        }
    }
}

// ─── Паника: один аварийный ответ, без payload ───────────────────────────────

static JSON: AtomicBool = AtomicBool::new(false);
static RESPONDED: AtomicBool = AtomicBool::new(false);

fn set_json_mode(json: bool) {
    JSON.store(json, Ordering::SeqCst);
}

fn install_panic_hook() {
    std::panic::set_hook(Box::new(|_| respond_to_panic()));
}

/// Ровно один аварийный ответ и выход 1. Сообщение — фиксированная строка;
/// payload паники отбрасывается намеренно (там могут оказаться секреты).
/// Выход без раскрутки стека: сырой режим консоли восстанавливается здесь.
fn respond_to_panic() {
    terminal::restore_console();
    if RESPONDED.swap(true, Ordering::SeqCst) {
        std::process::exit(1);
    }
    let message = "Команда прервана.";
    if JSON.load(Ordering::SeqCst) {
        let line = serde_json::json!({"id": null, "ok": false, "error": {"code": "failed", "message": message}});
        let _ = writeln!(io::stdout().lock(), "{line}");
    }
    let _ = writeln!(io::stderr().lock(), "  [✗] {message}");
    std::process::exit(1);
}
