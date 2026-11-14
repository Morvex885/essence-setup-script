//! Screen extension contract: implement `Screen::run`, return `Navigation`, and add
//! a `Registration` in `registrations()`. Screens receive only `Context` (daemon
//! client + UI); no state/SSH imports. Register a real factory, never an unfinished route.
//! The source screen also supplies `Registry::github_wizard` for first-run entry.
use std::{collections::{BTreeMap, VecDeque}, io::{self, IsTerminal, Write}, process::{Command, ExitCode}, time::Duration};
use crossterm::{event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers}, execute, terminal::{self, EnterAlternateScreen, LeaveAlternateScreen}};
use essence_rc_client::{Client, Input, Log, Origin, Progress, Reply, Request, Secrets, TermEvent, TerminalIo, agent_env};
use ratatui::{Terminal, backend::CrosstermBackend, text::Line};
use zeroize::Zeroizing;
use crate::ui::{self, Item, View};

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
static SIGNAL_INTERRUPT: AtomicBool = AtomicBool::new(false);
static COMMAND_ACTIVE: AtomicUsize = AtomicUsize::new(0);
/// OS Ctrl+C follows the raw keyboard policy, including cooked passthrough.
pub fn signal_interrupt() {
    if COMMAND_ACTIVE.load(Ordering::SeqCst)==0 { SIGNAL_INTERRUPT.store(true,Ordering::SeqCst); }
}
/// Marks a running request/editor/terminal command (nesting allowed).
struct CommandGuard;
impl CommandGuard { fn new()->Self { COMMAND_ACTIVE.fetch_add(1,Ordering::SeqCst);Self } }
impl Drop for CommandGuard { fn drop(&mut self) {COMMAND_ACTIVE.fetch_sub(1,Ordering::SeqCst);} }

pub type Wizard = fn(&mut Context<'_>, &str) -> io::Result<bool>;
pub struct Registration { pub key: char, pub factory: fn() -> Box<dyn Screen> }
pub struct Registry { pub screens: Vec<Registration>, pub github_wizard: Option<Wizard> }
pub fn registrations() -> Registry {
    Registry { screens: vec![
        Registration { key: 'n', factory: || Box::new(crate::nodes::Nodes) },
        Registration { key: 'r', factory: || Box::new(crate::nodes::Profiles) },
        Registration { key: 'p', factory: || Box::new(crate::nodes::Connections) },
        Registration { key: 'a', factory: || Box::new(crate::nodes::AmneziaWg) },
        Registration { key: 't', factory: || Box::new(crate::nodes::Telegram) },
        Registration { key: 'c', factory: || Box::new(crate::clients::Clients) },
        Registration { key: 'g', factory: || Box::new(crate::clients::Groups) },
        Registration { key: 'm', factory: || Box::new(crate::clients::Templates) },
        Registration { key: 'f', factory: || Box::new(crate::clients::Generate) },
        Registration { key: 's', factory: || Box::new(crate::clients::Subscriptions) },
        Registration { key: 'i', factory: || Box::new(crate::source::Source) },
        Registration { key: 'o', factory: || Box::new(crate::system::Settings) },
    ], github_wizard: Some(crate::source::github_wizard) }
}
pub enum Navigation { Back, Push(Box<dyn Screen>), Exit(i32) }
pub trait Screen { fn run(&mut self, context: &mut Context<'_>) -> io::Result<Navigation>; }
/// UI implementations make screen flows independently scriptable, without a tty.
pub trait UserInterface {
    fn input(&mut self, view: &View, hidden: bool) -> io::Result<Option<Zeroizing<String>>>;
    fn show(&mut self, view: &View) -> io::Result<()>;
    fn log(&mut self, log: &Log);
    fn notice(&mut self, line: Line<'static>);
    /// A request is about to be sent: draw `status` now (before any reply).
    fn busy(&mut self, _status: &str) -> io::Result<()> { Ok(()) }
    /// Timer tick while the request is in flight (spinner, elapsed time).
    fn tick(&mut self) {}
    /// The request finished: drop the busy status, keep type-ahead.
    fn command_finished(&mut self) -> io::Result<()> { Ok(()) }
    /// Run a local child (template editor) on the cooked terminal.
    fn suspended(&mut self, command: &mut Command) -> io::Result<std::process::ExitStatus>;
    /// Hand the terminal to a terminal command (`node shell`, `telegram menu`).
    fn suspend(&mut self) -> io::Result<()> { Ok(()) }
    fn resume(&mut self) -> io::Result<()> { Ok(()) }
    fn interrupted(&self) -> bool { false }
}
/// A local terminal factory: one fresh console per terminal request.
pub type TerminalFactory<'a> = &'a mut dyn FnMut() -> Box<dyn TerminalIo>;
pub struct Context<'a> {
    pub client: &'a mut dyn Client,
    pub ui: &'a mut dyn UserInterface,
    pub registry: &'a Registry,
    /// `None` (screen tests): a console whose input ends at once.
    pub terminal: Option<TerminalFactory<'a>>,
    /// `env` of every request: the operator's SSH agent for node connections.
    env: Option<BTreeMap<String, String>>,
}
/// The single place where a request is assembled: every request carries the agent `env`.
fn request<'r>(env: &'r Option<BTreeMap<String, String>>, words: &'r [String], secrets: &'r Secrets, input: &'r Input) -> Request<'r> {
    Request { env: env.as_ref(), ..Request::new(words, secrets, input) }
}
/// The console of `Context::for_test`: input ends at once.
struct ClosedTerminal;
impl TerminalIo for ClosedTerminal {
    fn term(&self) -> String { "dumb".into() }
    fn size(&self) -> (u16, u16) { (80, 24) }
    fn start(&mut self, events: Box<dyn Fn(TermEvent) + Send>) -> io::Result<()> { events(TermEvent::Closed); Ok(()) }
    fn write(&mut self, _: &[u8]) -> io::Result<()> { Ok(()) }
    fn stop(&mut self) {}
}
impl<'a> Context<'a> {
    pub fn new(client: &'a mut dyn Client, ui: &'a mut dyn UserInterface, registry: &'a Registry, terminal: TerminalFactory<'a>) -> Self {
        // A network daemon refuses `env`: the agent travels only to a local one.
        let env = if client.hello().origin == Origin::Local { agent_env(std::env::var_os("SSH_AUTH_SOCK")) } else { None };
        Self { client, ui, registry, terminal: Some(terminal), env }
    }
    /// Screen tests: no agent `env`; a terminal whose input ends at once.
    pub fn for_test(client: &'a mut dyn Client, ui: &'a mut dyn UserInterface, registry: &'a Registry) -> Self {
        Self { client, ui, registry, terminal: None, env: None }
    }
}
impl Context<'_> {
    pub fn call(&mut self, words: &[&str]) -> io::Result<Reply> { self.request(&essence_rc_client::argv(words), &Secrets::default()) }
    pub fn request(&mut self, words: &[String], secrets: &Secrets) -> io::Result<Reply> {
        self.request_with(words, secrets, &Input::default())
    }
    /// Every daemon request goes through here: the status line of the request
    /// is drawn before it is sent and animated until the reply (no screen
    /// ever freezes on a slow gh/git/SSH call), daemon log events stream live.
    pub fn request_with(&mut self, words: &[String], secrets: &Secrets, input: &Input) -> io::Result<Reply> {
        self.send(words, secrets, input, None)
    }
    /// A request whose failure `expected` is an answer the caller handles
    /// itself (startup `session open` → `not_configured`): it is not journaled.
    pub(crate) fn request_expecting(&mut self, words: &[String], secrets: &Secrets, expected: &str) -> io::Result<Reply> {
        self.send(words, secrets, &Input::default(), Some(expected))
    }
    fn send(&mut self, words: &[String], secrets: &Secrets, input: &Input, expected: Option<&str>) -> io::Result<Reply> {
        let _running=CommandGuard::new();
        self.ui.busy(activity(words))?;
        let ui = &mut self.ui;
        let result = self.client.send(request(&self.env, words, secrets, input),
            &mut |progress| match progress { Progress::Log(entry) => ui.log(entry), Progress::Tick => ui.tick() });
        self.ui.command_finished()?;
        let reply = result?;
        if expected.is_none_or(|code| code != reply.code()) { self.journal_error(&reply); }
        Ok(reply)
    }
    /// The daemon carries the core's failure text only in `error.message` (v1
    /// printed it through the journal). It is shown exactly once, here;
    /// screens never repeat it. Plans and `*_required` decisions become
    /// review frames/questions instead.
    fn journal_error(&mut self, reply: &Reply) {
        let code = reply.code();
        if reply.ok || matches!(code, "confirmation_required" | "plan_changed") || code.ends_with("_required") { return; }
        if let Some(message) = reply.error["message"].as_str().filter(|m| !m.is_empty()) {
            self.ui.notice(ui::text(format!("[✗] {message}"), ui::RED));
        }
    }
    /// Terminal commands (`node shell`, `telegram menu`): the daemon runs the
    /// remote PTY and this process relays it through a fresh local console.
    /// The UI is suspended (cooked mode, main screen) for the whole request
    /// and never reads the terminal meanwhile; Ctrl+C reaches only the remote.
    pub fn interactive(&mut self, words: &[String]) -> io::Result<Reply> {
        let _running=CommandGuard::new();
        let mut console = match self.terminal.as_mut() { Some(factory) => factory(), None => Box::new(ClosedTerminal) };
        self.ui.suspend()?;
        let ui = &mut self.ui;
        let (secrets, input) = (Secrets::default(), Input::default());
        let result = self.client.terminal(request(&self.env, words, &secrets, &input), &mut *console,
            &mut |progress| if let Progress::Log(entry) = progress { ui.log(entry) });
        drop(console);
        let resumed = self.ui.resume();
        let reply = result?;
        resumed?;
        self.ui.command_finished()?;
        self.journal_error(&reply);
        Ok(reply)
    }
    pub fn choose(&mut self, view: &View) -> io::Result<Option<String>> { Ok(self.ui.input(view, false)?.map(|s| s.to_string())) }
    pub fn secret(&mut self, title: &str, prompt: &str) -> io::Result<Option<Zeroizing<String>>> {
        let mut view = View::new(title); view.prompt = format!("{prompt}: ");
        self.ui.input(&view, true)
    }
    pub fn confirm(&mut self, mut view: View, question: &str) -> io::Result<bool> {
        view.prompt = format!("{question} (y/N): ");
        Ok(self.choose(&view)?.is_some_and(|s| s.eq_ignore_ascii_case("y")))
    }
    pub fn invalid(&mut self) { self.ui.notice(ui::warn("Неверный выбор.")); }
    pub fn failed(&mut self) { self.ui.notice(ui::warn("Операция завершилась ошибкой. Повторите действие из меню.")); }
    pub fn wizard(&mut self, mode: &str) -> io::Result<bool> {
        if let Some(wizard) = self.registry.github_wizard { wizard(self, mode) }
        else { self.invalid(); Ok(false) }
    }
    /// A selector never reads input when empty, never accepts leading zeroes,
    /// and returns no partial result on cancellation.
    pub fn select(&mut self, title: &str, labels: &[String]) -> io::Result<Option<usize>> {
        if labels.is_empty() { self.empty_list(title, "Нет объектов для выбора")?; return Ok(None); }
        let mut items: Vec<_> = labels.iter().enumerate().map(|(i,l)| Item::new(i+1,l,ui::CYAN)).collect();
        items.push(Item::new(0,"Отмена",ui::NC));
        let mut view = View::menu(title, items);
        view.mode = ui::Mode::Select;
        loop {
            let Some(choice) = self.choose(&view)? else { return Ok(None); };
            if choice == "0" { return Ok(None); }
            if let Some(i) = list_index(&choice, labels.len()) { return Ok(Some(i)); }
            self.invalid();
        }
    }
    /// v1 `toggle_select`: Enter commits the flags (indexes of checked labels),
    /// `0`/EOF drop partial changes; an empty list shows `empty` and reads
    /// nothing. Callers preselect only what mirrors the current state.
    pub fn toggle(&mut self, title: &str, labels: &[String], mut flags: Vec<bool>, empty: &str) -> io::Result<Option<Vec<usize>>> {
        if labels.is_empty() { self.empty_list(title, empty)?; return Ok(None); }
        flags.resize(labels.len(), false);
        loop {
            let mut items: Vec<_> = labels.iter().enumerate()
                .map(|(i, label)| Item::new(i + 1, format!("[{}] {label}", if flags[i] { 'x' } else { ' ' }), ui::CYAN)).collect();
            items.push(Item::new(0, "Отмена", ui::NC));
            let mut view = View::menu(title, items);
            view.mode = ui::Mode::Toggle;
            view.prompt = "Пробел/номер — переключить, Enter — сохранить, 0 — отмена: ".into();
            let Some(choice) = self.choose(&view)? else { return Ok(None); };
            if choice == "0" { return Ok(None); }
            if choice.is_empty() { return Ok(Some(flags.iter().enumerate().filter_map(|(i, on)| on.then_some(i)).collect())); }
            match list_index(&choice, labels.len()) { Some(i) => flags[i] = !flags[i], None => self.invalid() }
        }
    }
    fn empty_list(&mut self, title: &str, message: &str) -> io::Result<()> {
        let mut view = View::menu(title, vec![Item::new(0, "Отмена", ui::NC)]);
        view.context.push(ui::text(message, ui::DIM));
        self.ui.show(&view)
    }
}
/// 1-based list number → index; `0`, leading zeroes, signs and expressions are invalid.
fn list_index(choice: &str, count: usize) -> Option<usize> {
    if choice.starts_with('0') || !choice.bytes().all(|b| b.is_ascii_digit()) { return None; }
    choice.parse::<usize>().ok().filter(|n| *n > 0 && *n <= count).map(|n| n - 1)
}
/// The status line of a request in flight, by command: network and SSH calls
/// name what is being waited for; anything else is a generic «Выполняется…».
pub fn activity(words: &[String]) -> &'static str {
    let word = |i: usize| words.get(i).map_or("", String::as_str);
    match (word(0), word(1)) {
        ("session", "open") => "Открытие сессии…",
        ("status", _) => "Загрузка состояния…",
        ("source", "github-accounts") => "Проверка аккаунтов GitHub…",
        ("source", "github-login") => "Вход в GitHub: следуйте инструкциям в журнале и браузере…",
        ("source", "github-connect") => "Подключение к GitHub…",
        ("source", "github-change-account") => "Смена аккаунта GitHub…",
        ("source", "github-fetch") => "Загрузка конфигурации из GitHub…",
        ("source", "github-push" | "github-replace-with-local" | "github-migrate-format" | "github-rewrap-password" | "github-rotate-key") =>
            "Отправка конфигурации в GitHub…",
        ("source", "github-delete-repo") => "Удаление репозитория GitHub…",
        ("source", verb) if verb.starts_with("github-") => "Обмен данными с GitHub…",
        ("node" | "conn" | "awg" | "telegram", "list" | "show" | "aliases" | "rename" | "tag" | "profile" | "domain" | "port") => "Выполняется…",
        ("node", "apply") => "Применение на нодах…",
        ("node" | "conn" | "awg" | "telegram", _) => "Подключение к серверам…",
        ("subscription", "publish" | "publish-all" | "rotate" | "revoke" | "migrate" | "host") => "Публикация подписок на серверах…",
        ("self", "version" | "update") => "Проверка обновлений…",
        _ => "Выполняется…",
    }
}
pub fn run(client: &mut dyn Client, ui: &mut dyn UserInterface, registry: &Registry, terminal: TerminalFactory<'_>) -> io::Result<i32> {
    let result = (|| {
        let mut context = Context::new(client, ui, registry, terminal);
        match crate::system::session_gate(&mut context)? {
            _ if context.ui.interrupted() => return Ok(130),
            crate::system::Gate::Open => {},
            crate::system::Gate::Quit => return Ok(0),
            crate::system::Gate::Failed => return Ok(1),
        }
        let mut stack: Vec<Box<dyn Screen>> = vec![Box::new(crate::system::Dashboard)];
        loop {
            let Some(screen) = stack.last_mut() else { return Ok(0); };
            match screen.run(&mut context)? {
                Navigation::Back => { stack.pop(); if context.ui.interrupted() { return Ok(130); } },
                Navigation::Push(screen) => stack.push(screen),
                Navigation::Exit(code) => return Ok(if context.ui.interrupted() {130} else {code}),
            }
        }
    })();
    let close = client.close();
    result.and_then(|code| close.map(|_| code))
}
/// What the launcher hands to the menu: the daemon connection and the local
/// console factory for terminal commands.
pub struct Frontend {
    pub client: Box<dyn Client>,
    pub terminal: Box<dyn FnMut() -> Box<dyn TerminalIo>>,
}
/// The `essence-rc` entrypoint without arguments: the menu on this terminal,
/// talking to the daemon only through `frontend.client`.
///
/// Signals: SIGINT is consumed by a handler for the whole run. In a menu it
/// ends the menu (exit 130); while a request, editor or terminal command runs
/// it is ignored. TERM/HUP/QUIT restore the terminal and exit 128+N. A panic
/// restores the terminal and exits 1 without printing its payload (it may
/// carry secrets).
pub fn run_terminal(frontend: Frontend) -> ExitCode {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        eprintln!("  [!] Терминальное меню требует терминал stdin/stdout.");
        return ExitCode::FAILURE;
    }
    std::panic::set_hook(Box::new(|_| {
        restore_terminal();
        let _ = writeln!(io::stderr().lock(), "  [✗] Терминальное меню завершилось аварийно.");
        std::process::exit(1);
    }));
    let runtime = match tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => { eprintln!("  [!] Не удалось запустить обработчик сигналов: {error}"); return ExitCode::FAILURE; }
    };
    let signals = install_signals(&runtime);
    let Frontend { mut client, mut terminal } = frontend;
    let result = (|| {
        let mut ui = TerminalUi::new()?;
        run(&mut *client, &mut ui, &registrations(), &mut *terminal)
    })();
    for task in signals { task.abort(); }
    match result {
        Ok(code) => ExitCode::from(u8::try_from(code).unwrap_or(1)),
        Err(error) => { eprintln!("  [!] {error}"); ExitCode::FAILURE }
    }
}
fn restore_terminal() {
    let _ = terminal::disable_raw_mode();
    let _ = execute!(io::stdout(), LeaveAlternateScreen);
}
fn terminate(code: i32) -> ! { restore_terminal(); std::process::exit(code) }
fn install_signals(runtime: &tokio::runtime::Runtime) -> Vec<tokio::task::JoinHandle<()>> {
    let _entered = runtime.enter();
    let mut tasks = vec![];
    #[cfg(unix)] {
        use tokio::signal::unix::{signal, SignalKind};
        if let Ok(mut stream) = signal(SignalKind::interrupt()) {
            tasks.push(runtime.spawn(async move { while stream.recv().await.is_some() { signal_interrupt(); } }));
        }
        for (kind, code) in [(SignalKind::terminate(), 143), (SignalKind::hangup(), 129), (SignalKind::quit(), 131)] {
            if let Ok(mut stream) = signal(kind) { tasks.push(runtime.spawn(async move { if stream.recv().await.is_some() { terminate(code); } })); }
        }
    }
    #[cfg(windows)] {
        use tokio::signal::windows;
        if let Ok(mut stream) = windows::ctrl_c() { tasks.push(runtime.spawn(async move { while stream.recv().await.is_some() { signal_interrupt(); } })); }
        // STATUS_CONTROL_C_EXIT, as reported by Windows for console-event exits.
        const CONTROL_EXIT: i32 = 0xC000_013A_u32 as i32;
        macro_rules! on_event {
            ($make:path) => {
                if let Ok(mut stream) = $make() { tasks.push(runtime.spawn(async move { if stream.recv().await.is_some() { terminate(CONTROL_EXIT); } })); }
            };
        }
        on_event!(windows::ctrl_break);
        on_event!(windows::ctrl_close);
        on_event!(windows::ctrl_logoff);
        on_event!(windows::ctrl_shutdown);
    }
    tasks
}
#[derive(Debug, PartialEq, Eq)]
enum Step { Pass, Stay, Submit(String), Cancel }
/// Arrow-key selection of one frame with items; no terminal access.
struct Picker { keys: Vec<String>, mode: ui::Mode, cursor: usize }
impl Picker {
    /// `None` for a frame without items. `remembered` is the item key stored for this title.
    fn new(view: &View, remembered: Option<&str>) -> Option<Self> {
        let keys = view.keys();
        if keys.is_empty() { return None; }
        let cursor = remembered.and_then(|key| keys.iter().position(|k| k == key)).unwrap_or(0);
        Some(Self { keys, mode: view.mode, cursor })
    }
    /// Item shown highlighted: the cursor for empty input, else the item whose
    /// key equals the input ignoring ASCII case, else none.
    fn highlight(&self, input: &str) -> Option<usize> {
        if input.is_empty() { Some(self.cursor) } else { self.keys.iter().position(|k| k.eq_ignore_ascii_case(input)) }
    }
    fn key(&mut self, code: KeyCode, input: &mut String, typed_ahead: bool) -> Step {
        let n = self.keys.len();
        let zero = self.keys.iter().any(|k| k == "0");
        match code {
            KeyCode::Up | KeyCode::Down => {
                let base = self.highlight(input).unwrap_or(self.cursor);
                input.clear();
                self.cursor = if code == KeyCode::Up { (base + n - 1) % n } else { (base + 1) % n };
                Step::Stay
            }
            KeyCode::Enter => {
                if typed_ahead && input.is_empty() { return Step::Stay; }
                if input.is_empty() {
                    return if self.mode == ui::Mode::Toggle { Step::Submit(String::new()) } else { Step::Submit(self.keys[self.cursor].clone()) };
                }
                if let Some(i) = self.highlight(input) { self.cursor = i; }
                Step::Submit(input.clone())
            }
            KeyCode::Right => {
                if self.mode == ui::Mode::Toggle || (typed_ahead && input.is_empty()) { return Step::Stay; }
                match self.highlight(input) {
                    Some(i) => { self.cursor = i; Step::Submit(if input.is_empty() { self.keys[i].clone() } else { input.clone() }) }
                    None => Step::Stay,
                }
            }
            KeyCode::Char(' ') if self.mode == ui::Mode::Toggle => match self.highlight(input) {
                Some(i) if self.keys[i] != "0" => { self.cursor = i; Step::Submit(self.keys[i].clone()) }
                _ => Step::Stay,
            },
            KeyCode::Esc => {
                if self.mode == ui::Mode::Root { Step::Stay } else if zero { Step::Submit("0".into()) } else { Step::Cancel }
            }
            KeyCode::Left => {
                if matches!(self.mode, ui::Mode::Menu | ui::Mode::Select) && zero { Step::Submit("0".into()) } else { Step::Stay }
            }
            _ => Step::Pass,
        }
    }
}
pub struct TerminalUi {
    terminal: Terminal<CrosstermBackend<io::Stdout>>,
    view: View,
    journal: Vec<Line<'static>>,
    busy: Option<ui::Busy>,
    pending: VecDeque<Event>,
    interrupted: bool,
    active: bool,
    draw_error: Option<io::Error>,
    /// Highlighted item key by frame title, for the whole session.
    cursors: std::collections::HashMap<String, String>,
}
impl TerminalUi {
    pub fn new() -> io::Result<Self> {
        terminal::enable_raw_mode()?;
        if let Err(error) = execute!(io::stdout(), EnterAlternateScreen) { let _ = terminal::disable_raw_mode(); return Err(error); }
        let result = Terminal::new(CrosstermBackend::new(io::stdout()));
        match result {
            Ok(terminal) => Ok(Self { terminal, view: View::default(), journal: vec![], busy: None, pending: VecDeque::new(), interrupted: false, active: true, draw_error: None, cursors: std::collections::HashMap::new() }),
            Err(error) => { let _ = execute!(io::stdout(), LeaveAlternateScreen); let _ = terminal::disable_raw_mode(); Err(error) }
        }
    }
    fn draw(&mut self, input: &str, hidden: bool) -> io::Result<()> {
        if let Some(error) = self.draw_error.take() { return Err(error); }
        self.terminal.draw(|frame| ui::render_busy(frame, &self.view, input, hidden, &self.journal, self.busy.as_ref()))?;
        Ok(())
    }
    /// Redraw from a progress callback: a failure surfaces on the next draw.
    fn redraw(&mut self) {
        if self.active && let Err(error) = self.draw("",false) { self.draw_error=Some(error); }
    }
    fn scroll_view(&mut self,key:KeyCode)->io::Result<()> {
        let layout=ui::layout(&self.view,"",false,&self.journal,None,self.terminal.size()?.height);
        let (height,max)=(layout.body_height.max(1),layout.max_scroll);
        let current=self.view.scroll.min(max);
        self.view.scroll=match key {
            KeyCode::Home=>0,KeyCode::End=>max,
            KeyCode::PageUp=>current.saturating_sub(height),
            KeyCode::PageDown=>current.saturating_add(height).min(max),
            KeyCode::Up=>current.saturating_sub(1),
            KeyCode::Down=>current.saturating_add(1).min(max),
            _=>current,
        };
        Ok(())
    }
    /// Scroll the body just enough to show the highlighted item.
    fn reveal(&mut self) -> io::Result<()> {
        let Some((first, last)) = self.view.cursor_rows() else { return Ok(()); };
        let layout = ui::layout(&self.view, "", false, &self.journal, None, self.terminal.size()?.height);
        let (height, max) = (usize::from(layout.body_height.max(1)), usize::from(layout.max_scroll));
        self.view.scroll = follow((first, last), usize::from(self.view.scroll), height, max) as u16;
        Ok(())
    }
    fn leave(&mut self) -> io::Result<()> {
        terminal::disable_raw_mode()?;
        execute!(io::stdout(), LeaveAlternateScreen)?;
        self.active = false;
        Ok(())
    }
    fn enter(&mut self) -> io::Result<()> {
        terminal::enable_raw_mode()?;
        self.active = true;
        execute!(io::stdout(), EnterAlternateScreen)?;
        self.terminal.clear()?;
        Ok(())
    }
    fn read(&mut self, view: &View, hidden: bool) -> io::Result<Option<Zeroizing<String>>> {
        if self.interrupted || SIGNAL_INTERRUPT.load(Ordering::SeqCst) { self.interrupted=true; return Ok(None); }
        self.view = view.clone();
        let remembered = if view.mode == ui::Mode::Select { None } else { self.cursors.get(&view.title).map(String::as_str) };
        let mut picker = if hidden { None } else { Picker::new(view, remembered) };
        let mut shown: Option<Option<usize>> = None;
        let mut input = Zeroizing::new(String::new());
        loop {
            if SIGNAL_INTERRUPT.load(Ordering::SeqCst) {self.interrupted=true;return Ok(None);}
            let highlight = picker.as_ref().and_then(|p| p.highlight(&input));
            if shown != Some(highlight) {
                self.view.cursor = highlight;
                if highlight.is_some() { self.reveal()?; }
                shown = Some(highlight);
            }
            self.draw(&input, hidden)?;
            let (event, typed_ahead) = match self.pending.pop_front() {
                Some(event) => (event, true),
                None => {
                    if !event::poll(Duration::from_millis(100))? {continue;}
                    match event::read() {Ok(event)=>(event, false),Err(error) if error.kind()==io::ErrorKind::UnexpectedEof=>return Ok(None),Err(error)=>return Err(error)}
                }
            };
            if let Event::Key(key) = event {
                if key.kind == KeyEventKind::Release { continue; }
                if ctrl(key,'c') { self.interrupted=true; return Ok(None); }
                if ctrl(key,'d') { return Ok(None); }
                if let Some(picker) = picker.as_mut() {
                    let before = picker.cursor;
                    let step = picker.key(key.code, &mut input, typed_ahead);
                    if picker.cursor != before && picker.mode != ui::Mode::Select {
                        self.cursors.insert(view.title.clone(), picker.keys[picker.cursor].clone());
                    }
                    match step {
                        Step::Pass => {},
                        Step::Stay => continue,
                        Step::Submit(text) => { self.journal.clear(); return Ok(Some(Zeroizing::new(text))); },
                        Step::Cancel => return Ok(None),
                    }
                }
                match key.code {
                    key @ (KeyCode::PageUp|KeyCode::PageDown|KeyCode::Home|KeyCode::End|KeyCode::Up|KeyCode::Down)=>self.scroll_view(key)?,
                    KeyCode::Enter => { self.journal.clear(); return Ok(Some(input)); },
                    KeyCode::Backspace => { input.pop(); },
                    KeyCode::Esc => return Ok(None),
                    KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => input.push(c),
                    _ => {}
                }
            }
        }
    }
}
/// First visible row after the least scroll that shows rows `first..=last`
/// in a window of `height` rows; `max` is the largest valid scroll.
fn follow((first, last): (usize, usize), scroll: usize, height: usize, max: usize) -> usize {
    let current = scroll.min(max);
    let target = if first < current { first } else if last >= current + height { last + 1 - height } else { current };
    target.min(max)
}
/// The answer closes a frame with items, so its remembered item is dropped:
/// a menu reopened later starts on its first item. Only a return from a
/// submenu (any other answer) keeps the position. A saved multi-selection
/// (empty answer) closes too. Frames without items (a password or y/N
/// question titled like the card it serves) never touch the memory.
fn leaves(view: &View, hidden: bool, answer: Option<&str>) -> bool {
    if hidden || view.keys().is_empty() { return false; }
    match answer {
        None | Some("0") => true,
        Some("") => view.mode == ui::Mode::Toggle,
        Some(_) => false,
    }
}
fn ctrl(key: KeyEvent, letter: char) -> bool { key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char(letter) }
impl UserInterface for TerminalUi {
    fn input(&mut self, view: &View, hidden: bool) -> io::Result<Option<Zeroizing<String>>> {
        let result = self.read(view, hidden)?;
        if leaves(view, hidden, result.as_ref().map(|text| text.as_str())) { self.cursors.remove(&view.title); }
        Ok(result)
    }
    fn show(&mut self, view: &View) -> io::Result<()> { self.view=view.clone(); self.draw("",false) }
    fn log(&mut self, entry: &Log) {
        let color = match entry.level.as_str() { "success"=>ui::GREEN, "warn"=>ui::YELLOW, "error"=>ui::RED, _=>ui::CYAN };
        self.journal.push(ui::text(entry.text.clone(),color));
        if !self.active {
            // Suspended for a terminal command: the local console may already
            // be in raw mode, so end lines with an explicit CR.
            let prefix = match entry.level.as_str() { "success"=>"  [✓] ", "warn"=>"  [!] ", "error"=>"  [✗] ", "output"=>"", _=>"  [*] " };
            let mut stdout = io::stdout().lock();
            let _ = write!(stdout, "{prefix}{}\r\n", entry.text);
            let _ = stdout.flush();
            return;
        }
        self.view.scroll=u16::MAX;
        self.redraw();
    }
    fn notice(&mut self, line: Line<'static>) { self.journal.push(line); }
    fn busy(&mut self, status: &str) -> io::Result<()> {
        self.busy=Some(ui::Busy::new(status));
        if self.active { self.draw("",false) } else { Ok(()) }
    }
    fn tick(&mut self) { if self.busy.is_some() { self.redraw(); } }
    fn command_finished(&mut self) -> io::Result<()> {
        self.busy=None;
        // Raw-mode Ctrl+C does not signal the child. Discard ONLY those keys,
        // preserving type-ahead, including keys typed while a command runs.
        while event::poll(Duration::ZERO)? {
            let e=event::read()?;
            if !matches!(e, Event::Key(key) if ctrl(key,'c')) { self.pending.push_back(e); }
        }
        Ok(())
    }
    fn suspended(&mut self, command: &mut Command) -> io::Result<std::process::ExitStatus> {
        let _running=CommandGuard::new();
        self.leave()?;
        let status = command.status();
        let resumed = self.enter();
        status.and_then(|status| resumed.map(|_|status))
    }
    fn suspend(&mut self) -> io::Result<()> { self.leave() }
    fn resume(&mut self) -> io::Result<()> { self.enter() }
    fn interrupted(&self) -> bool { self.interrupted }
}
impl Drop for TerminalUi { fn drop(&mut self) { if self.active { let _ = self.leave(); } } }
/// Test UI records complete views, but never stores hidden input in those views.
#[derive(Default)]
pub struct ScriptedUi { pub inputs: VecDeque<Option<String>>, pub views: Vec<View>, pub notices: Vec<Line<'static>>, pub logs: Vec<Log>, pub busy: Vec<String>, pub suspensions: usize, pub suspended_now: bool }
impl ScriptedUi { pub fn new(inputs: &[&str]) -> Self { Self { inputs: inputs.iter().map(|s|Some((*s).into())).collect(), ..Self::default() } } }
impl UserInterface for ScriptedUi {
    fn input(&mut self, view: &View, _: bool) -> io::Result<Option<Zeroizing<String>>> { assert!(!self.suspended_now,"input while suspended"); self.views.push(view.clone()); Ok(self.inputs.pop_front().flatten().map(Zeroizing::new)) }
    fn show(&mut self, view: &View) -> io::Result<()> { self.views.push(view.clone()); Ok(()) }
    fn log(&mut self, log:&Log) { self.logs.push(log.clone()); }
    fn notice(&mut self, line:Line<'static>) { self.notices.push(line); }
    fn busy(&mut self, status: &str) -> io::Result<()> { self.busy.push(status.to_owned()); Ok(()) }
    fn suspended(&mut self, command:&mut Command)->io::Result<std::process::ExitStatus> { command.status() }
    fn suspend(&mut self) -> io::Result<()> { self.suspensions+=1; self.suspended_now=true; Ok(()) }
    fn resume(&mut self) -> io::Result<()> { self.suspended_now=false; Ok(()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use essence_rc_client::{argv, ScriptedClient};
    fn picker(keys: &[char], mode: ui::Mode, remembered: Option<&str>) -> Picker {
        let mut view = View::menu("T", keys.iter().map(|k| Item::new(k, "x", ui::CYAN)).collect());
        view.mode = mode;
        Picker::new(&view, remembered).unwrap()
    }
    fn press(picker: &mut Picker, code: KeyCode, input: &str) -> (Step, String) {
        let mut input = input.to_owned();
        (picker.key(code, &mut input, false), input)
    }
    fn submit(text: &str) -> Step { Step::Submit(text.into()) }
    #[test]
    fn arrows_wrap_around_and_enter_picks_the_highlighted_item() {
        assert!(Picker::new(&View::new("Question"), None).is_none());
        let mut menu = picker(&['n', 'c', '0'], ui::Mode::Menu, None);
        for _ in 0..3 { press(&mut menu, KeyCode::Down, ""); }
        assert_eq!(menu.cursor, 0);
        press(&mut menu, KeyCode::Up, "");
        assert_eq!(menu.cursor, 2);
        let mut menu = picker(&['n', 'c', '0'], ui::Mode::Menu, None);
        press(&mut menu, KeyCode::Down, "");
        assert_eq!(press(&mut menu, KeyCode::Enter, "").0, submit("c"));
        assert_eq!(picker(&['n', 'c', '0'], ui::Mode::Menu, Some("c")).cursor, 1);
        assert_eq!(picker(&['n', 'c', '0'], ui::Mode::Menu, Some("zzz")).cursor, 0);
    }
    #[test]
    fn typed_text_moves_the_highlight_and_arrows_clear_it() {
        let mut menu = picker(&['n', 'c', '0'], ui::Mode::Menu, None);
        assert_eq!(menu.highlight("C"), Some(1));
        assert_eq!(press(&mut menu, KeyCode::Enter, "C").0, submit("C"));
        assert_eq!(menu.cursor, 1);
        let mut menu = picker(&['n', 'c', '0'], ui::Mode::Menu, None);
        assert_eq!(menu.highlight("x"), None);
        assert_eq!(press(&mut menu, KeyCode::Enter, "x").0, submit("x"));
        assert_eq!(press(&mut menu, KeyCode::Right, "x").0, Step::Stay);
        assert_eq!(press(&mut menu, KeyCode::Down, "c"), (Step::Stay, String::new()));
        assert_eq!(menu.cursor, 2);
        assert_eq!(press(&mut menu, KeyCode::Char('n'), "").0, Step::Pass);
    }
    #[test]
    fn esc_and_left_go_back_except_in_root_frames() {
        for mode in [ui::Mode::Menu, ui::Mode::Select] {
            let mut menu = picker(&['n', 'c', '0'], mode, None);
            assert_eq!(press(&mut menu, KeyCode::Esc, "").0, submit("0"));
            assert_eq!(press(&mut menu, KeyCode::Left, "").0, submit("0"));
            press(&mut menu, KeyCode::Down, "");
            assert_eq!(press(&mut menu, KeyCode::Right, "").0, submit("c"));
        }
        let mut root = picker(&['n', '0'], ui::Mode::Root, None);
        assert_eq!(press(&mut root, KeyCode::Esc, "").0, Step::Stay);
        assert_eq!(press(&mut root, KeyCode::Left, "").0, Step::Stay);
        let mut no_zero = picker(&['r', 'y'], ui::Mode::Menu, None);
        assert_eq!(press(&mut no_zero, KeyCode::Esc, "").0, Step::Cancel);
        assert_eq!(press(&mut no_zero, KeyCode::Left, "").0, Step::Stay);
    }
    #[test]
    fn toggle_space_switches_enter_saves_and_side_arrows_do_nothing() {
        let mut toggle = picker(&['1', '2', '0'], ui::Mode::Toggle, None);
        assert_eq!(press(&mut toggle, KeyCode::Char(' '), "").0, submit("1"));
        assert_eq!(press(&mut toggle, KeyCode::Enter, "").0, submit(""));
        assert_eq!(press(&mut toggle, KeyCode::Left, "").0, Step::Stay);
        assert_eq!(press(&mut toggle, KeyCode::Right, "").0, Step::Stay);
        assert_eq!(press(&mut toggle, KeyCode::Esc, "").0, submit("0"));
        press(&mut toggle, KeyCode::Up, "");
        assert_eq!(press(&mut toggle, KeyCode::Char(' '), "").0, Step::Stay);
        assert_eq!(press(&mut toggle, KeyCode::Char(' '), "2").0, submit("2"));
        assert_eq!(toggle.cursor, 1);
    }
    /// The user's report: Клиенты → «Назад» → Клиенты must start on the first
    /// item again; only a return from a submenu keeps the position. A
    /// question sharing the card's title (password, y/N) keeps it as well.
    #[test]
    fn position_is_kept_only_for_a_return_from_a_submenu() {
        let frame = |mode| { let mut view = View::menu("Нода: de", vec![Item::new('c', "x", ui::CYAN), Item::new(0, "Назад", ui::NC)]); view.mode = mode; view };
        for mode in [ui::Mode::Menu, ui::Mode::Toggle] {
            assert!(leaves(&frame(mode), false, Some("0")), "back/cancel");
            assert!(leaves(&frame(mode), false, None), "Esc/Ctrl+D");
            assert!(!leaves(&frame(mode), false, Some("c")), "opened a submenu or toggled an item");
        }
        assert!(leaves(&frame(ui::Mode::Toggle), false, Some("")), "multi-selection saved");
        assert!(!leaves(&frame(ui::Mode::Menu), false, Some("")), "invalid empty answer keeps the menu open");
        let question = View::new("Нода: de");
        for answer in [None, Some("0"), Some("")] {
            assert!(!leaves(&question, false, answer), "y/N or text question");
            assert!(!leaves(&question, true, answer), "password prompt");
        }
        assert!(!leaves(&frame(ui::Mode::Menu), true, None), "hidden input never forgets");
    }
    /// The frame scrolls only as far as needed to show the whole highlighted item.
    #[test]
    fn scroll_follows_the_highlight_minimally() {
        // 10-row window over 30 rows (max scroll 20).
        assert_eq!(follow((3, 3), 0, 10, 20), 0, "visible: no scroll");
        assert_eq!(follow((12, 13), 0, 10, 20), 4, "below: last row at the bottom");
        assert_eq!(follow((5, 5), 8, 10, 20), 5, "above: first row at the top");
        assert_eq!(follow((29, 29), 0, 10, 20), 20, "wrap to the end");
        assert_eq!(follow((2, 2), 20, 10, 20), 2, "wrap to the start");
        assert_eq!(follow((25, 25), u16::MAX.into(), 10, 20), 20, "scroll past the end is clamped first");
    }
    #[test]
    fn typed_ahead_bare_enter_is_dropped_but_key_and_enter_work() {
        for mode in [ui::Mode::Menu, ui::Mode::Toggle] {
            let mut menu = picker(&['n', 'c', '0'], mode, None);
            let mut input = String::new();
            assert_eq!(menu.key(KeyCode::Enter, &mut input, true), Step::Stay);
            assert_eq!(menu.key(KeyCode::Right, &mut input, true), Step::Stay);
            let mut input = "n".to_owned();
            assert_eq!(menu.key(KeyCode::Enter, &mut input, true), submit("n"));
        }
    }
    #[test]
    fn selector_empty_does_not_consume_and_invalid_indexes_stay() {
        let registry=Registry {screens:vec![],github_wizard:None};
        let mut client=ScriptedClient::new(Vec::<essence_rc_client::Step>::new());
        let mut ui=ScriptedUi::new(&["01","+1","1+1","","2"]);
        let mut context=Context::for_test(&mut client,&mut ui,&registry);
        assert_eq!(context.select("Empty",&[]).unwrap(),None);
        assert_eq!(context.select("Choose",&["one".into(),"two".into()]).unwrap(),Some(1));
        assert_eq!(ui.notices.len(),4);
        assert_eq!(ui.views[0].sections[0][0].key,"0");
        assert!(ui.views[0].context.len()==1);
        client.assert_finished();
    }
    struct ChildScreen;
    impl Screen for ChildScreen {
        fn run(&mut self,context:&mut Context<'_>)->io::Result<Navigation> {
            assert!(context.call(&["node","list"])?.ok);
            Ok(Navigation::Back)
        }
    }
    #[test]
    fn dashboard_routes_uppercase_and_restores_parent_after_pop() {
        let registry=Registry {screens:vec![Registration{key:'n',factory:||Box::new(ChildScreen)}],github_wizard:None};
        let mut client=ScriptedClient::new([
            (argv(&["session","status"]),Reply::success(serde_json::json!({"configured":true}))),
            (argv(&["session","open"]),Reply::success(serde_json::Value::Null)),
            (argv(&["status"]),Reply::success(serde_json::json!({}))),
            (argv(&["node","list"]),Reply::success(serde_json::json!([]))),
            (argv(&["status"]),Reply::success(serde_json::json!({}))),
        ]);
        let mut ui=ScriptedUi::new(&["N","0"]);
        assert_eq!(run(&mut client,&mut ui,&registry,&mut || Box::new(ClosedTerminal) as Box<dyn TerminalIo>).unwrap(),0);
        assert!(client.closed);
        client.assert_finished();
    }
    fn failure(code:&str,message:&str)->Reply { Reply { error:serde_json::json!({"code":code,"message":message}),..Reply::default() } }
    /// UI and client sharing one flag: whether the UI is suspended right now.
    struct SharedUi { inner: ScriptedUi, suspended: std::rc::Rc<std::cell::Cell<bool>> }
    impl UserInterface for SharedUi {
        fn input(&mut self, view: &View, hidden: bool) -> io::Result<Option<Zeroizing<String>>> { self.inner.input(view, hidden) }
        fn show(&mut self, view: &View) -> io::Result<()> { self.inner.show(view) }
        fn log(&mut self, log: &Log) { self.inner.log(log) }
        fn notice(&mut self, line: Line<'static>) { self.inner.notice(line) }
        fn suspended(&mut self, command: &mut Command) -> io::Result<std::process::ExitStatus> { self.inner.suspended(command) }
        fn suspend(&mut self) -> io::Result<()> { self.suspended.set(true); self.inner.suspend() }
        fn resume(&mut self) -> io::Result<()> { self.suspended.set(false); self.inner.resume() }
    }
    /// Records the UI state at the moment the terminal request is made.
    struct Observed { inner: ScriptedClient, suspended: std::rc::Rc<std::cell::Cell<bool>>, during_terminal: Option<bool> }
    impl Client for Observed {
        fn hello(&self) -> &essence_rc_client::Hello { self.inner.hello() }
        fn send(&mut self, request: Request<'_>, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply> { self.inner.send(request, progress) }
        fn terminal(&mut self, request: Request<'_>, io: &mut dyn TerminalIo, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply> {
            self.during_terminal = Some(self.suspended.get());
            self.inner.terminal(request, io, progress)
        }
    }
    #[test]
    fn interactive_runs_a_terminal_request_while_suspended_and_journals_failure_once() {
        let registry=Registry {screens:vec![],github_wizard:None};
        let words=argv(&["node","shell","--name","de"]);
        let suspended=std::rc::Rc::new(std::cell::Cell::new(false));
        let mut client=Observed { inner: ScriptedClient::new([essence_rc_client::Step::terminal(words.clone(),failure("remote_failed","SSH failed"))]),
            suspended: suspended.clone(), during_terminal: None };
        let mut ui=SharedUi { inner: ScriptedUi::new(&[]), suspended: suspended.clone() };
        let mut consoles=0;
        let mut factory=|| { consoles+=1; Box::new(ClosedTerminal) as Box<dyn TerminalIo> };
        let reply=Context::new(&mut client,&mut ui,&registry,&mut factory).interactive(&words).unwrap();
        assert_eq!(reply.code(),"remote_failed");
        assert_eq!(consoles,1,"one fresh console per terminal request");
        assert_eq!(client.during_terminal,Some(true),"the UI is suspended while the terminal request runs");
        assert!(!suspended.get(),"resumed afterwards");
        assert_eq!((ui.inner.suspensions,ui.inner.suspended_now),(1,false));
        assert_eq!(ui.inner.notices.len(),1);
        client.inner.assert_finished();
    }
    #[test]
    fn decisions_and_plans_are_not_journaled_as_errors() {
        let registry=Registry {screens:vec![],github_wizard:None};
        let codes=["confirmation_required","plan_changed","repo_create_required","not_found","not_configured"];
        let mut client=ScriptedClient::new(codes.map(|code|(argv(&["status"]),failure(code,"text"))).into_iter()
            .chain([(argv(&["session","open"]),failure("not_configured","quiet"))]));
        let mut ui=ScriptedUi::new(&[]);
        let mut context=Context::for_test(&mut client,&mut ui,&registry);
        for _ in codes { context.call(&["status"]).unwrap(); }
        // Only the startup gate expects `not_configured`; elsewhere it is an error.
        assert_eq!(context.request_expecting(&argv(&["session","open"]),&Secrets::default(),"not_configured").unwrap().code(),"not_configured");
        assert_eq!(ui.notices.len(),2);
        assert!(ui.notices.iter().all(|line|line.spans.iter().any(|span|span.content.contains("text"))));
        client.assert_finished();
    }
    /// The same drawing path as `TerminalUi` (ui::render_busy) on a TestBackend;
    /// each frame is recorded with the moment it was drawn.
    struct DrawnUi { terminal: Terminal<ratatui::backend::TestBackend>, view: View, journal: Vec<Line<'static>>, busy: Option<ui::Busy>, frames: Vec<(std::time::Instant, String)> }
    impl DrawnUi {
        fn draw(&mut self) {
            let frame = self.terminal.draw(|f| ui::render_busy(f, &self.view, "", false, &self.journal, self.busy.as_ref())).unwrap();
            let text = frame.buffer.content.chunks(80).map(|row| row.iter().map(|c| c.symbol()).collect::<String>()).collect::<Vec<_>>().join("\n");
            self.frames.push((std::time::Instant::now(), text));
        }
    }
    impl UserInterface for DrawnUi {
        fn input(&mut self, _: &View, _: bool) -> io::Result<Option<Zeroizing<String>>> { Ok(None) }
        fn show(&mut self, view: &View) -> io::Result<()> { self.view = view.clone(); self.draw(); Ok(()) }
        fn log(&mut self, entry: &Log) { self.journal.push(ui::text(entry.text.clone(), ui::CYAN)); self.draw(); }
        fn notice(&mut self, line: Line<'static>) { self.journal.push(line); }
        fn busy(&mut self, status: &str) -> io::Result<()> { self.busy = Some(ui::Busy::new(status)); self.draw(); Ok(()) }
        fn tick(&mut self) { self.draw(); }
        fn command_finished(&mut self) -> io::Result<()> { self.busy = None; Ok(()) }
        fn suspended(&mut self, command: &mut Command) -> io::Result<std::process::ExitStatus> { command.status() }
    }
    /// A slow daemon reply (the fake daemon sleeps before answering): the
    /// status line is on screen before the request is even written, the
    /// daemon's log event appears live, and the spinner keeps redrawing until
    /// the reply.
    #[test]
    fn status_line_is_drawn_before_a_slow_reply_and_animates() {
        use std::sync::mpsc;
        let line = |value: serde_json::Value| Zeroizing::new(value.to_string());
        let (to_client, incoming) = mpsc::channel();
        let (outgoing, from_client) = mpsc::channel::<Zeroizing<String>>();
        to_client.send(line(serde_json::json!({"event":"hello","protocol":3,"version":"9","origin":"local"}))).unwrap();
        let daemon = std::thread::spawn(move || {
            let request: serde_json::Value = serde_json::from_str(&from_client.recv().unwrap()).unwrap();
            let id = request["id"].clone();
            to_client.send(line(serde_json::json!({"id":id,"event":"log","level":"info","text":"Проверка аккаунта GitHub"}))).unwrap();
            std::thread::sleep(std::time::Duration::from_secs(1));
            to_client.send(line(serde_json::json!({"id":id,"ok":false,"error":{"code":"repo_create_required"},"exit":2}))).unwrap();
            let _ = from_client.recv();
        });
        let mut client = essence_rc_client::DaemonClient::from_channels(incoming, outgoing).unwrap();
        let mut ui = DrawnUi { terminal: Terminal::new(ratatui::backend::TestBackend::new(80, 24)).unwrap(), view: View::menu("Источник конфигурации", vec![]),
            journal: vec![], busy: None, frames: vec![] };
        let registry = Registry { screens: vec![], github_wizard: None };
        let started = std::time::Instant::now();
        let reply = Context::for_test(&mut client, &mut ui, &registry).call(&["source", "github-connect", "--login", "o"]).unwrap();
        let replied = std::time::Instant::now();
        assert_eq!(reply.code(), "repo_create_required");
        assert!(replied.duration_since(started) >= std::time::Duration::from_millis(900));
        let (first_at, first) = &ui.frames[0];
        assert!(first.contains("Подключение к GitHub…"), "the first frame is the status line:\n{first}");
        assert!(first_at.duration_since(started) < std::time::Duration::from_millis(300), "drawn at once, not after the reply");
        let live = ui.frames.iter().filter(|(_, text)| text.contains("Проверка аккаунта GitHub") && text.contains("Подключение к GitHub…")).count();
        assert!(live >= 5, "the log event and the animated status stay on screen while waiting ({live} frames)");
        let spinners: std::collections::BTreeSet<char> = ui.frames.iter().filter_map(|(_, text)| text.lines().find(|l| l.contains("Подключение к GitHub…")).and_then(|l| l.chars().next())).collect();
        assert!(spinners.len() > 1, "the spinner advances: {spinners:?}");
        assert!(ui.frames.iter().all(|(at, _)| *at <= replied));
        client.close().unwrap();
        drop(client);
        daemon.join().unwrap();
    }
    #[test]
    fn os_interrupt_is_ignored_while_a_command_runs() {
        // Only the "command running" half is asserted: parallel tests may hold
        // their own guards, which can only make the counter larger.
        let _running=CommandGuard::new();
        signal_interrupt();
        assert!(!SIGNAL_INTERRUPT.load(Ordering::SeqCst));
    }
}
