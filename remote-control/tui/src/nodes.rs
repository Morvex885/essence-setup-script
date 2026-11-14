//! Node, node profile, SSH, connection, AmneziaWG and Telegram screens (v1
//! `tui/nodes.sh`) over the daemon protocol only.
//!
//! Lists keep their own menu section; dangerous actions consume the core's
//! frozen plan through `confirm`. Terminal commands (`node shell`,
//! `telegram menu`) are terminal requests while the UI is suspended. Changes
//! of the desired node state reach a node only through `node apply` (`apply`).
use std::io;
use serde_json::Value;
use ratatui::style::Color;
use essence_rc_client::{argv, Reply, Secrets};
use crate::{app::{Context, Navigation, Screen}, confirm::{self, set_flag}, ui::{self, Item, View}};

pub struct Nodes;
pub struct Connections;
pub struct AmneziaWg;
pub struct Telegram;
pub struct Profiles;
struct NodeCard(String);
struct ProfileCard(String);

/// Conditions of a node the shared handler resolves (`handle_node_codes`).
const NODE_CODES: [&str; 4] = ["missing_secret", "host_key_changed", "host_key_unknown", "needs_setup"];
/// Empty multi-select state (the same wording as `Context::select`).
const EMPTY: &str = "Нет объектов для выбора";

fn rows(value: &Value) -> &[Value] { value.as_array().map(Vec::as_slice).unwrap_or(&[]) }
fn text(value: &Value) -> String { value.as_str().map(str::to_owned).unwrap_or_else(|| if value.is_null() { String::new() } else { value.to_string() }) }
fn names(value: &Value) -> Vec<String> { rows(value).iter().map(|v| text(&v["name"])).collect() }
fn joined(value: &Value) -> String { rows(value).iter().map(text).collect::<Vec<_>>().join(", ") }
fn index(choice: &str, count: usize) -> Option<usize> {
    if choice.starts_with('0') || !choice.bytes().all(|b| b.is_ascii_digit()) { return None; }
    choice.parse::<usize>().ok().filter(|n| *n > 0 && *n <= count).map(|n| n - 1)
}
fn ask(ctx: &mut Context<'_>, title: &str, prompt: &str) -> io::Result<Option<String>> {
    let mut view = View::new(title);
    view.prompt = format!("{prompt}: ");
    ctx.choose(&view)
}
/// The core's message is already in the journal; a refused plan is no failure.
fn outcome(ctx: &mut Context<'_>, reply: &Reply) {
    if !reply.ok && !matches!(reply.code(), "confirmation_required" | "plan_changed") { ctx.failed(); }
}
/// v1 `confirm_yn … Y` for harmless repeats: Enter = yes, EOF = no.
fn yes_default(ctx: &mut Context<'_>, title: &str, question: &str) -> io::Result<bool> {
    let mut view = View::new(title);
    view.prompt = format!("{question} (Y/n): ");
    loop {
        match ctx.choose(&view)?.as_deref() {
            None | Some("n" | "N") => return Ok(false),
            Some("" | "y" | "Y") => return Ok(true),
            Some(_) => ctx.ui.notice(ui::warn("Введите y или n.")),
        }
    }
}
fn read_failed(ctx: &mut Context<'_>, title: &str) -> io::Result<bool> {
    ctx.failed();
    let mut view = View::menu(title, vec![Item::new('r', "Повторить чтение", ui::CYAN), Item::new(0, "Назад", ui::NC)]);
    view.context.push(ui::text("Не удалось получить данные", ui::YELLOW));
    loop {
        match ctx.choose(&view)?.as_deref() {
            Some("r" | "R") => return Ok(true),
            Some("0") | None => return Ok(false),
            _ => ctx.invalid(),
        }
    }
}
/// Hidden entry; `None` when cancelled (Enter/EOF). The value lives only in
/// the request's `secrets` and is wiped right after the call.
fn store_password(ctx: &mut Context<'_>, name: &str) -> io::Result<Option<Reply>> {
    let Some(password) = ctx.secret(&format!("Нода: {name}"), "Пароль SSH (Enter — отмена)")? else { return Ok(None); };
    if password.is_empty() { return Ok(None); }
    let mut secrets = Secrets::default();
    secrets.insert_hidden("password", password);
    let reply = ctx.request(&argv(&["node", "password", "--name", name]), &secrets);
    secrets.clear();
    reply.map(Some)
}
/// v1 `tui_handle_node_codes`: true when the condition was resolved and the
/// caller may repeat its command; the caller reports any remaining failure.
pub fn handle_node_codes(ctx: &mut Context<'_>, reply: &Reply, name: &str) -> io::Result<bool> {
    match reply.code() {
        "missing_secret" => {
            if !ctx.confirm(View::new(format!("Нода: {name}")), "Пароль SSH для ноды не сохранён. Сохранить сейчас?")? { return Ok(false); }
            Ok(store_password(ctx, name)?.is_some_and(|saved| saved.ok))
        }
        "host_key_changed" | "host_key_unknown" => {
            let Some(fingerprint) = rows(&reply.error["fingerprints"]).first().and_then(Value::as_str) else { return Ok(false); };
            let words = argv(&["node", "trust-host-key", "--name", name, "--host-key", fingerprint]);
            Ok(confirm::run_confirmed(ctx, "Ключ сервера изменился", "Доверять новому ключу?", &words, &Secrets::default())?.ok)
        }
        "needs_setup" => {
            ctx.ui.notice(ui::warn("Нода требует SSH-настройки: раздел n → h."));
            Ok(false)
        }
        "domain_required" => {
            // `node apply --name N` names the node in `extra.name` too.
            let target = reply.error["name"].as_str().filter(|s| !s.is_empty()).unwrap_or(name).to_owned();
            set_domain(ctx, &target)
        }
        _ => Ok(false),
    }
}
/// The domain question of `domain_required` → `node domain`; true when saved.
fn set_domain(ctx: &mut Context<'_>, name: &str) -> io::Result<bool> {
    if name.is_empty() { return Ok(false); }
    let Some(domain) = ask_valid(ctx, &format!("Нода: {name}"), "Домен ноды (Enter — отмена)", |d| d.is_empty() || domain_valid(d), DOMAIN_INVALID)? else { return Ok(false); };
    if domain.is_empty() { return Ok(false); }
    Ok(ctx.call(&["node", "domain", "--name", name, "--domain", &domain])?.ok)
}
/// v1 `_tui_node_try` / `_tui_node_confirmed` (`review` = plan title and question).
fn node_request(ctx: &mut Context<'_>, name: &str, words: &[String], review: Option<(&str, &str)>) -> io::Result<Reply> {
    loop {
        let reply = match review {
            Some((title, question)) => confirm::run_confirmed(ctx, title, question, words, &Secrets::default())?,
            None => ctx.request(words, &Secrets::default())?,
        };
        if reply.ok { return Ok(reply); }
        if handle_node_codes(ctx, &reply, name)? { continue; }
        outcome(ctx, &reply);
        return Ok(reply);
    }
}
/// `node shell` / `telegram menu`: a terminal request; the daemon runs the
/// remote PTY and the local console relays it while the UI is suspended.
fn interactive(ctx: &mut Context<'_>, name: &str, telegram: bool) -> io::Result<()> {
    let words = if telegram { argv(&["telegram", "menu", "--name", name]) } else { argv(&["node", "shell", "--name", name]) };
    loop {
        let reply = ctx.interactive(&words)?;
        if reply.ok { return Ok(()); }
        if handle_node_codes(ctx, &reply, name)? { continue; }
        outcome(ctx, &reply);
        return Ok(());
    }
}
fn node_label(node: &Value) -> String { format!("{}  {}:{}", text(&node["name"]), text(&node["ip"]), text(&node["port"])) }
/// The list row: label, then the apply state (`node list .status`) when the node has one.
fn node_items(data: &Value, problems: bool) -> Vec<Item> {
    rows(data).iter().enumerate().map(|(i, node)| {
        let problem = problems && ((node["auth"] == "password" && node["password"] != "ok") || !rows(&node["issues"]).is_empty());
        let state = if problems { apply_state(node) } else { None };
        let label = match state { Some((state, _)) => format!("{}  · {state}", node_label(node)), None => node_label(node) };
        let pending = state.is_some_and(|(_, color)| color == ui::YELLOW);
        Item::new(i + 1, label, if problem || pending { ui::YELLOW } else { ui::CYAN })
    }).collect()
}

// ─── Ноды ────────────────────────────────────────────────────────────────────

impl Screen for Nodes {
    fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> {
        loop {
            let reply = ctx.call(&["node", "list"])?;
            if !reply.ok {
                if read_failed(ctx, "Ноды")? { continue; }
                return Ok(Navigation::Back);
            }
            let status = ctx.call(&["status"])?;
            let pending = status.ok && status.data["ssh_setup_pending"] == true;
            let mut view = View::new("Ноды");
            view.prompt = "Выберите действие: ".into();
            let list = node_items(&reply.data, true);
            if list.is_empty() { view.context.push(ui::text("Нет нод", ui::DIM)); } else { view.sections.push(list); }
            let waiting = pending_count(&reply.data);
            let mut actions = vec![Item::new('a', "Добавить ноду", ui::GREEN)];
            if waiting > 0 { actions.push(Item::new('y', format!("Применить на всех ожидающих ({waiting})"), ui::GREEN)); }
            if pending { actions.push(Item::new('h', "Завершить отложенную SSH-настройку", ui::YELLOW)); }
            actions.push(Item::new(0, "Назад", ui::NC));
            view.sections.push(actions);
            let Some(choice) = ctx.choose(&view)? else { return Ok(Navigation::Back); };
            match choice.as_str() {
                "a" | "A" => add_node(ctx)?,
                "y" | "Y" if waiting > 0 => { apply(ctx, &argv(&["node", "apply", "--pending"]), "")?; }
                "h" | "H" if pending => setup_ssh(ctx)?,
                "0" => return Ok(Navigation::Back),
                _ => match index(&choice, rows(&reply.data).len()) {
                    Some(i) => { NodeCard(text(&reply.data[i]["name"])).run(ctx)?; }
                    None => ctx.invalid(),
                },
            }
        }
    }
}
fn card_view(name: &str, node: &Value, password: bool) -> View {
    let mut view = View::new(format!("Нода: {name}"));
    view.prompt = "Выберите действие: ".into();
    let plain = |line: String| ui::text(line, ui::NC);
    view.context.push(plain(format!("Адрес: {}:{}", text(&node["ip"]), text(&node["port"]))));
    view.context.push(plain(format!("Пользователь: {}", text(&node["user"]))));
    if password {
        view.context.push(plain("Вход: по паролю".into()));
        // `error` — хранилище секретов не прочитано: это не «нет пароля».
        view.context.push(match node["password"].as_str() {
            Some("ok") => ui::text("Пароль SSH: сохранён", ui::GREEN),
            Some("error") => ui::text("Пароль SSH: не удалось прочитать", ui::RED),
            _ => ui::text("Пароль SSH: нет", ui::YELLOW),
        });
    } else {
        view.context.push(plain("Вход: по ключу".into()));
    }
    view.context.push(plain(format!("Тег: {}", text(&node["tag"]))));
    let profile = text(&node["profile"]);
    view.context.push(plain(format!("Профиль: {}", if profile.is_empty() { "нет" } else { &profile })));
    let domain = text(&node["domain"]);
    view.context.push(plain(format!("Домен: {}", if domain.is_empty() { "нет" } else { &domain })));
    if let Some(ports) = node["ports"].as_object().filter(|ports| !ports.is_empty()) {
        let list: Vec<String> = ports.iter().map(|(key, port)| format!("{key}: {}", text(port))).collect();
        view.context.push(plain(format!("Порты ноды: {}", list.join(", "))));
    }
    if let Some((state, color)) = apply_state(node) { view.context.push(ui::text(format!("Применение: {state}"), color)); }
    if !profile.is_empty() { view.context.push(plain(format!("WARP: {}", warp_label(node)))); }
    let issues = joined(&node["issues"]);
    if !issues.is_empty() { view.context.push(ui::text(format!("Требует настройки: {issues}"), ui::YELLOW)); }
    let groups = joined(&node["groups"]);
    view.context.push(plain(format!("Группы: {}", if groups.is_empty() { "нет" } else { &groups })));
    view.context.push(plain(format!("Клиентов: {}", text(&node["clients"]))));
    view.sections.push(vec![
        Item::new('y', "Применить", ui::GREEN),
        Item::new('o', "Оболочка", ui::CYAN), Item::new('t', "Telegram Proxy на ноде", ui::CYAN),
        Item::new('p', "Подключения ноды", ui::CYAN), Item::new('a', "Клиенты AmneziaWG", ui::CYAN),
        Item::new('k', "Проверить подключение", ui::CYAN),
    ]);
    let mut actions = vec![
        Item::new('f', "Профиль", ui::YELLOW), Item::new('m', "Домен", ui::YELLOW), Item::new('i', "Порты", ui::YELLOW),
        Item::new('h', "Усилить защиту SSH", ui::YELLOW), Item::new('r', "Переименовать", ui::YELLOW), Item::new('e', "Тег", ui::YELLOW),
    ];
    if password { actions.push(Item::new('w', "Пароль SSH", ui::YELLOW)); }
    actions.extend([Item::new('l', "Псевдонимы подключений", ui::YELLOW), Item::new('d', "Удалить ноду", ui::RED), Item::new(0, "Назад", ui::NC)]);
    view.sections.push(actions);
    view
}
impl Screen for NodeCard {
    fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> {
        loop {
            let reply = ctx.call(&["node", "show", "--name", &self.0])?;
            if !reply.ok {
                if reply.code() != "not_found" && read_failed(ctx, &format!("Нода: {}", self.0))? { continue; }
                return Ok(Navigation::Back);
            }
            let node = &reply.data;
            let password = node["auth"] == "password";
            let Some(choice) = ctx.choose(&card_view(&self.0, node, password))? else { return Ok(Navigation::Back); };
            let name = self.0.clone();
            match choice.as_str() {
                "o" | "O" => interactive(ctx, &name, false)?,
                "t" | "T" => interactive(ctx, &name, true)?,
                "p" | "P" => connection_node(ctx, &name)?,
                "a" | "A" => awg_node(ctx, &name)?,
                "k" | "K" => { node_request(ctx, &name, &argv(&["node", "check", "--name", &name]), None)?; }
                "y" | "Y" => { apply(ctx, &argv(&["node", "apply", "--name", &name]), &name)?; }
                "f" | "F" => node_profile(ctx, &name, node)?,
                "m" | "M" => node_domain(ctx, &name, node)?,
                "i" | "I" => node_ports(ctx, &name, node)?,
                "h" | "H" => harden(ctx, &name)?,
                "r" | "R" => {
                    // Esc/Ctrl+D cancel only the rename; Ctrl+C leaves the card.
                    let Some(new) = ask(ctx, "Переименование ноды", "Новое имя ноды")? else { if ctx.ui.interrupted() { return Ok(Navigation::Back); } continue; };
                    if new.is_empty() { continue; }
                    let renamed = ctx.call(&["node", "rename", "--name", &name, "--new-name", &new])?;
                    if renamed.ok { self.0 = renamed.data["name"].as_str().unwrap_or(&new).to_owned(); } else { outcome(ctx, &renamed); }
                }
                "e" | "E" => {
                    let Some(tag) = ask(ctx, "Тег ноды", "Тег")? else { if ctx.ui.interrupted() { return Ok(Navigation::Back); } continue; };
                    let changed = ctx.call(&["node", "tag", "--name", &name, "--tag", &tag])?;
                    outcome(ctx, &changed);
                }
                "w" | "W" if password => { if let Some(saved) = store_password(ctx, &name)? { outcome(ctx, &saved); } }
                "l" | "L" => aliases(ctx, &name)?,
                "d" | "D" => if delete_node(ctx, &name, node)? { return Ok(Navigation::Back); },
                "0" => return Ok(Navigation::Back),
                _ => ctx.invalid(),
            }
        }
    }
}
/// Scopes come only from `node show .delete_options[]`; true when the node is gone.
fn delete_node(ctx: &mut Context<'_>, name: &str, node: &Value) -> io::Result<bool> {
    let options = rows(&node["delete_options"]);
    if options.is_empty() {
        ctx.ui.notice(ui::warn("Нет доступных вариантов удаления."));
        return Ok(false);
    }
    let labels: Vec<String> = options.iter().map(|option| text(&option["label"])).collect();
    let Some(i) = ctx.select("Объём удаления ноды", &labels)? else { return Ok(false); };
    let mut words = argv(&["node", "delete", "--name", name, "--scope", &text(&options[i]["scope"])]);
    if options[i]["revoke_key"] == true { words.push("--revoke-key".into()); }
    let reply = node_request(ctx, name, &words, Some(("Удаление ноды", "Удалить ноду в выбранном объёме?")))?;
    Ok(reply.ok || reply.error["deleted"] == true)
}

// ─── Добавление ──────────────────────────────────────────────────────────────

fn add_node(ctx: &mut Context<'_>) -> io::Result<()> {
    let mut secrets = Secrets::default();
    let result = add_node_with(ctx, &mut secrets);
    secrets.clear();
    result
}
fn add_node_with(ctx: &mut Context<'_>, secrets: &mut Secrets) -> io::Result<()> {
    const TITLE: &str = "Добавление ноды";
    let Some(name) = ask(ctx, TITLE, "Название [vps-1]")? else { return Ok(()); };
    let name = if name.is_empty() { "vps-1".to_owned() } else { name };
    let Some(ip) = ask(ctx, TITLE, "IP")? else { return Ok(()); };
    if ip.is_empty() {
        ctx.ui.notice(ui::warn("IP не указан."));
        return Ok(());
    }
    let port = loop {
        let Some(port) = ask(ctx, TITLE, "SSH-порт [22]")? else { return Ok(()); };
        let port = if port.is_empty() { "22".to_owned() } else { port };
        if port.bytes().all(|b| b.is_ascii_digit()) && port.parse::<u16>().is_ok_and(|p| p > 0) { break port; }
        ctx.ui.notice(ui::warn("Порт должен быть числом от 1 до 65535."));
    };
    let Some(user) = ask(ctx, TITLE, "Логин [root]")? else { return Ok(()); };
    let user = if user.is_empty() { "root".to_owned() } else { user };
    let Some(auth) = ctx.select("Способ входа", &["SSH-ключ".into(), "Пароль".into()])? else { return Ok(()); };
    let password = auth == 1;
    if password {
        loop {
            let Some(value) = ctx.secret(TITLE, "Пароль")? else { return Ok(()); };
            if !value.is_empty() { secrets.insert_hidden("password", value); break; }
            ctx.ui.notice(ui::warn("Пароль не может быть пустым."));
        }
    }
    let tag = loop {
        let Some(tag) = ask(ctx, TITLE, "Тег")? else { return Ok(()); };
        if !tag.is_empty() { break tag; }
        ctx.ui.notice(ui::warn("Тег не может быть пустым."));
    };
    // Profile (no profiles — no question) and, when its site needs one, the node domain.
    let profiles = ctx.call(&["profile", "list"])?;
    let profiles = if profiles.ok { rows(&profiles.data["profiles"]).to_vec() } else { vec![] };
    let mut profile = String::new();
    let mut domain = String::new();
    if !profiles.is_empty() {
        let mut labels = vec!["Без профиля".to_owned()];
        labels.extend(profiles.iter().map(|p| text(&p["name"])));
        let Some(i) = ctx.select("Профиль ноды", &labels)? else { return Ok(()); };
        if i > 0 {
            profile = text(&profiles[i - 1]["name"]);
            if needs_domain(&profiles[i - 1]) {
                let Some(value) = ask_valid(ctx, TITLE, "Домен ноды", domain_valid, DOMAIN_INVALID)? else { return Ok(()); };
                domain = value;
            }
        }
    }
    let mut base = argv(&["node", "add", "--name", &name, "--ip", &ip, "--port", &port, "--user", &user,
        "--auth", if password { "password" } else { "key" }, "--tag", &tag]);
    if !profile.is_empty() { base.extend(argv(&["--profile", &profile])); }
    if !domain.is_empty() { base.extend(argv(&["--domain", &domain])); }
    // v1 trusts a first-seen key (logged by the core); a changed one is
    // replaced only through the command's plan. Deferral checks no server key.
    let mut host_key = argv(&["--accept-new-host-key"]);
    let mut defer = false;
    loop {
        let mut words = base.clone();
        if defer { words.push("--defer-ssh-setup".into()); } else { words.extend(host_key.iter().cloned()); }
        let reply = if !defer && host_key[0] == "--replace-host-key" {
            confirm::run_confirmed(ctx, "Ключ сервера изменился", "Обновить ключ ноды?", &words, secrets)?
        } else {
            ctx.request(&words, secrets)?
        };
        if reply.ok {
            if reply.data["needs_setup"] == true { ctx.ui.notice(ui::warn("Нода сохранена, но требует SSH-настройки: раздел n → h.")); }
            // A node with a profile is applied right away, under the plan.
            if !profile.is_empty() {
                let saved = reply.data["name"].as_str().filter(|s| !s.is_empty()).unwrap_or(&name).to_owned();
                apply(ctx, &argv(&["node", "apply", "--name", &saved]), &saved)?;
            }
            return Ok(());
        }
        match reply.code() {
            "host_key_changed" if !defer => {
                let Some(fingerprint) = rows(&reply.error["fingerprints"]).first().and_then(Value::as_str) else { ctx.failed(); return Ok(()); };
                host_key = argv(&["--replace-host-key", fingerprint]);
            }
            "remote_failed" => {
                if !yes_default(ctx, TITLE, "Повторить попытку?")? { return Ok(()); }
                if password {
                    let Some(value) = ctx.secret(TITLE, "Новый пароль (Enter — прежний)")? else { return Ok(()); };
                    if !value.is_empty() { secrets.insert_hidden("password", value); }
                }
            }
            "onboarding_failed" => {
                let choices: [String; 2] = ["Повторить".into(), "Сохранить ноду и настроить позже".into()];
                match ctx.select("Не удалось настроить переносимый SSH-ключ", &choices)? {
                    Some(0) => {}
                    Some(_) => defer = true,
                    None => return Ok(()),
                }
            }
            _ => { outcome(ctx, &reply); return Ok(()); }
        }
    }
}

// ─── Усиление SSH ────────────────────────────────────────────────────────────

/// The core picks a deterministic free port without `--port`, so its plan is
/// confirmable as is; an explicit port is asked first and again on conflict.
fn harden(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    const TITLE: &str = "Усиление защиты SSH";
    const PORT: &str = "SSH-порт (Enter — подобрать свободный)";
    let harden_words = |port: &str| {
        let mut words = argv(&["node", "harden", "--name", name]);
        if !port.is_empty() { words.extend(argv(&["--port", port])); }
        words
    };
    let Some(port) = ask(ctx, TITLE, PORT)? else { return Ok(()); };
    let mut words = harden_words(&port);
    loop {
        let explicit = words.iter().any(|word| word == "--port");
        let asks_port = |reply: &Reply| reply.code() == "port_in_use" || (explicit && reply.code() == "invalid");
        let reply = ctx.request(&words, &Secrets::default())?;
        // The port may be taken before the plan and between the plan and
        // the confirmed run (the core refuses before any change): asked again.
        let reply = if asks_port(&reply) { reply } else {
            confirm::review_reply(ctx, TITLE, "Усилить защиту SSH?", &words, &Secrets::default(), reply, Some(2))?
        };
        if asks_port(&reply) {
            let Some(port) = ask(ctx, TITLE, PORT)? else { return Ok(()); };
            words = harden_words(&port);
            continue;
        }
        if reply.ok { return Ok(()); }
        if reply.code() == "hardening_failed" {
            if reply.error["console_required"] == true { ctx.ui.notice(ui::warn("Проверьте доступ через консоль провайдера.")); }
            ctx.failed();
            return Ok(());
        }
        if handle_node_codes(ctx, &reply, name)? { continue; }
        outcome(ctx, &reply);
        return Ok(());
    }
}

// ─── Отложенная SSH-настройка ────────────────────────────────────────────────

fn setup_ssh(ctx: &mut Context<'_>) -> io::Result<()> {
    let mut words = argv(&["node", "setup-ssh"]);
    loop {
        let reply = confirm::run_confirmed(ctx, "Завершение SSH-настройки", "Выполнить?", &words, &Secrets::default())?;
        if reply.ok {
            if reply.data["ready"] == true { ctx.ui.notice(ui::success("SSH-настройка завершена.")); }
            else {
                for node in rows(&reply.data["deferred"]) {
                    ctx.ui.notice(ui::warn(format!("Отложено: {} — {}", text(&node["name"]), text(&node["issue"]))));
                }
            }
            return Ok(());
        }
        match reply.code() {
            "key_provisioning_required" => {
                let mut view = View::new("Переносимый SSH-ключ");
                view.context.push(ui::text(format!("Ноды: {}", joined(&reply.error["nodes"])), ui::NC));
                let provision = ctx.confirm(view, "Создать переносимый SSH-ключ для этих нод?")?;
                let flag = confirm::decision_flag(reply.code()).expect("provisioning decision flag");
                set_flag(&mut words, flag, Some(if provision { "yes" } else { "no" }));
            }
            "onboarding_failed" => {
                let choices: [String; 2] = ["Повторить".into(), "Отложить проблемные ноды".into()];
                match ctx.select("Не удалось настроить переносимый SSH-ключ", &choices)? {
                    Some(0) => {}
                    Some(_) => set_flag(&mut words, "--on-failure", Some("defer")),
                    None => return Ok(()),
                }
            }
            // Reported by the journal; nothing failed.
            "nothing_pending" => return Ok(()),
            _ => { outcome(ctx, &reply); return Ok(()); }
        }
    }
}

// ─── Псевдонимы ──────────────────────────────────────────────────────────────

fn aliases(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    let reply = node_request(ctx, name, &argv(&["node", "aliases", "--name", name]), None)?;
    if !reply.ok { return Ok(()); }
    if rows(&reply.data).is_empty() {
        ctx.ui.notice(ui::text("Подключения на ноде не найдены.", ui::DIM));
        return Ok(());
    }
    let title = format!("Псевдонимы подключений: {name}");
    let (mut sets, mut unsets) = (vec![], vec![]);
    for entry in rows(&reply.data) {
        let (proxy, current) = (text(&entry["proxy"]), text(&entry["alias"]));
        let Some(value) = ask(ctx, &title, &format!("{proxy} [{current}] (- — удалить)"))? else { return Ok(()); };
        if value == "-" {
            if !current.is_empty() { unsets.extend(argv(&["--unset", &proxy])); }
        } else if !value.is_empty() && value != current {
            sets.extend(argv(&["--set", &format!("{proxy}={value}")]));
        }
    }
    if sets.is_empty() && unsets.is_empty() {
        ctx.ui.notice(ui::text("Изменений нет.", ui::DIM));
        return Ok(());
    }
    let mut words = argv(&["node", "aliases", "--name", name]);
    words.extend(sets);
    words.extend(unsets);
    let saved = ctx.request(&words, &Secrets::default())?;
    outcome(ctx, &saved);
    Ok(())
}

// ─── Подключения ─────────────────────────────────────────────────────────────

fn synced_node<'a>(sync: &'a Value, name: &str) -> Option<&'a Value> { rows(&sync["nodes"]).iter().find(|v| v["name"] == name) }
/// `conn sync` row states other than `synced`.
fn sync_problem(status: &Value) -> Option<&'static str> {
    match status.as_str() {
        Some("unreachable") => Some("недоступна"),
        Some("load_failed") => Some("не загружена"),
        Some("save_failed") => Some("не сохранена"),
        Some("skipped") => Some("пропущена"),
        _ => None,
    }
}
/// `conn sync` prunes and goes over SSH: only on entry and on `s`. Redraws read
/// `conn list` with discovery and reachability of the last sync.
impl Screen for Connections {
    fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> {
        let mut synced = Value::Null;
        let mut refresh = true;
        loop {
            if refresh {
                refresh = false;
                let reply = ctx.call(&["conn", "sync"])?;
                // A failed sync (reported) still shows the saved assignments:
                // a node may be opened to edit them without SSH.
                synced = if reply.ok { reply.data } else if reply.code() == "partial" { reply.error } else {
                    outcome(ctx, &reply);
                    Value::Null
                };
            }
            let reply = ctx.call(&["conn", "list"])?;
            if !reply.ok {
                if read_failed(ctx, "Подключения нод")? { continue; }
                return Ok(Navigation::Back);
            }
            let mut view = View::new("Подключения нод");
            view.prompt = "Выберите действие: ".into();
            if synced.is_null() { view.context.push(ui::text("Ноды не синхронизированы: подключения не проверены", ui::YELLOW)); }
            if rows(&reply.data).is_empty() { view.context.push(ui::text("Нет нод", ui::DIM)); }
            let mut items = vec![];
            for (i, entry) in rows(&reply.data).iter().enumerate() {
                let name = text(&entry["node"]);
                let state = synced_node(&synced, &name);
                items.push(Item::new(i + 1, name.clone(), ui::CYAN));
                if let Some(problem) = state.and_then(|s| sync_problem(&s["status"])) {
                    view.context.push(ui::text(format!("{name}  {problem}"), ui::YELLOW));
                    continue;
                }
                view.context.push(ui::text(name, ui::NC));
                let total = state.and_then(|s| s["discovered"].as_array()).map(Vec::len);
                for group in rows(&entry["groups"]) {
                    let assigned = rows(&group["proxies"]).len();
                    let color = match total { Some(n) if n > 0 && assigned >= n => ui::GREEN, Some(n) if n > 0 => ui::YELLOW, _ => ui::DIM };
                    let total = total.map_or_else(|| "?".to_owned(), |n| n.to_string());
                    view.context.push(ui::text(format!("  {}: {assigned}/{total}", text(&group["name"])), color));
                }
            }
            if !items.is_empty() { view.sections.push(items); }
            view.sections.push(vec![Item::new('s', "Синхронизировать с нодами", ui::YELLOW), Item::new(0, "Назад", ui::NC)]);
            let Some(choice) = ctx.choose(&view)? else { return Ok(Navigation::Back); };
            match choice.as_str() {
                "s" | "S" => refresh = true,
                "0" => return Ok(Navigation::Back),
                _ => match index(&choice, rows(&reply.data).len()) {
                    Some(i) => connection_node(ctx, &text(&reply.data[i]["node"]))?,
                    None => ctx.invalid(),
                },
            }
        }
    }
}
fn connection_node(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    let mut state = Value::Null;
    let (mut refresh, mut resolve) = (true, true);
    loop {
        if refresh {
            refresh = false;
            let reply = ctx.request(&argv(&["conn", "sync", "--name", name]), &Secrets::default())?;
            if reply.ok {
                state = synced_node(&reply.data, name).cloned().unwrap_or(Value::Null);
            } else if reply.code() == "partial" {
                state = synced_node(&reply.error, name).cloned().unwrap_or(Value::Null);
                let code = state["error"].as_str().unwrap_or("");
                if resolve && NODE_CODES.contains(&code) {
                    // The sync row names only the code; `node check` returns the
                    // condition with its details (fingerprints) for the handler.
                    resolve = false;
                    if node_request(ctx, name, &argv(&["node", "check", "--name", name]), None)?.ok { refresh = true; continue; }
                } else {
                    ctx.failed();
                }
            } else {
                if reply.code() == "not_found" { return Ok(()); }
                // A failed sync (reported) still shows the saved assignments,
                // unchecked: they can be edited without SSH.
                outcome(ctx, &reply);
                state = Value::Null;
            }
        }
        let listed = ctx.request(&argv(&["conn", "list", "--name", name]), &Secrets::default())?;
        if !listed.ok {
            if listed.code() != "not_found" { outcome(ctx, &listed); }
            return Ok(());
        }
        let groups = rows(&listed.data).iter().find(|entry| entry["node"] == name).map(|entry| rows(&entry["groups"])).unwrap_or(&[]);
        // `None` — the node was not read (the sync failed): nothing is «not found».
        let discovered: Option<Vec<String>> = state["discovered"].as_array().map(|list| list.iter().map(text).collect());
        let proxies: Vec<String> = discovered.clone().unwrap_or_default();
        let all: Vec<String> = groups.iter().flat_map(|g| rows(&g["proxies"]).iter().map(text)).collect();
        let (extra, stale) = unlisted(&all, discovered.as_deref());
        let shown: Vec<String> = proxies.iter().chain(&extra).cloned().collect();
        let assigned: Vec<Vec<String>> = shown.iter()
            .map(|proxy| groups.iter().filter(|g| rows(&g["proxies"]).iter().any(|p| p == proxy)).map(|g| text(&g["name"])).collect())
            .collect();
        let mut view = View::menu(format!("Подключения ноды: {name}"), vec![
            Item::new('b', "Назначить подключения группам", ui::YELLOW), Item::new('l', "Псевдонимы подключений", ui::YELLOW),
            Item::new('s', "Синхронизировать с нодой", ui::YELLOW), Item::new(0, "Назад", ui::NC),
        ]);
        if let Some(problem) = sync_problem(&state["status"]) {
            view.context.push(ui::text(format!("Нода {problem}"), ui::YELLOW));
        } else if discovered.is_none() {
            view.context.push(ui::text("Подключения ноды не проверены", ui::YELLOW));
        } else if proxies.is_empty() {
            view.context.push(ui::text("Подключения не найдены", ui::DIM));
        }
        for (proxy, groups) in shown.iter().zip(&assigned) {
            view.context.push(ui::text(format!("{}  [{}]", proxy_label(proxy, &stale), groups.join(", ")), ui::NC));
        }
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        match choice.as_str() {
            "b" | "B" => assign_connections(ctx, name, discovered.as_deref(), groups)?,
            "l" | "L" => aliases(ctx, name)?,
            "s" | "S" => { refresh = true; resolve = true; }
            "0" => return Ok(()),
            _ => ctx.invalid(),
        }
    }
}
/// Proxy by proxy: the menu lists the node's proxies (discovered, then
/// assigned ones no longer discovered) with their groups; a proxy opens a
/// toggle of every group, preselected with its current groups. Edits stay
/// local: «Сохранить» sends one `conn set` with an `--assign` for each group
/// whose proxy set changed (others are not sent: a stale form must not undo
/// concurrent changes), nothing changed — no command; a failed `conn set`
/// (e.g. `locked`) keeps the editor and its edits for a retry; `0`/EOF discards.
fn assign_connections(ctx: &mut Context<'_>, name: &str, discovered: Option<&[String]>, current: &[Value]) -> io::Result<()> {
    let listed = ctx.call(&["group", "list"])?;
    if !listed.ok { outcome(ctx, &listed); return Ok(()); }
    let groups = names(&listed.data);
    if groups.is_empty() { ctx.ui.notice(ui::warn("Нет групп.")); return Ok(()); }
    // Proxies of every group on the node, as edited (a group may sit in
    // several entries of the node: their proxies are merged, as in the core).
    let mut assignment: Vec<Vec<String>> = groups.iter()
        .map(|group| {
            let mut list: Vec<String> = Vec::new();
            for proxy in current.iter().filter(|entry| text(&entry["name"]) == *group).flat_map(|entry| rows(&entry["proxies"]).iter().map(text)) {
                if !list.contains(&proxy) { list.push(proxy); }
            }
            list
        })
        .collect();
    let all: Vec<String> = assignment.iter().flatten().cloned().collect();
    let (extra, stale) = unlisted(&all, discovered);
    let mut proxies = discovered.unwrap_or_default().to_vec();
    proxies.extend(extra);
    if proxies.is_empty() { ctx.ui.notice(ui::warn("Нет подключений для назначения: синхронизируйте ноду.")); return Ok(()); }
    let saved = assignment.clone();
    loop {
        let mut view = View::new(format!("Назначение подключений: {name}"));
        view.prompt = "Выберите подключение или действие: ".into();
        view.sections.push(proxies.iter().enumerate().map(|(i, proxy)| {
            let of: Vec<&str> = groups.iter().zip(&assignment).filter(|(_, list)| list.contains(proxy)).map(|(group, _)| group.as_str()).collect();
            Item::new(i + 1, format!("{}  [{}]", proxy_label(proxy, &stale), of.join(", ")), ui::CYAN)
        }).collect());
        view.sections.push(vec![Item::new('s', "Сохранить", ui::YELLOW), Item::new(0, "Отмена", ui::NC)]);
        if assignment.iter().zip(&saved).any(|(list, before)| !same_set(list, before)) {
            view.context.push(ui::text("Есть несохранённые изменения", ui::YELLOW));
        }
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        match choice.as_str() {
            "0" => return Ok(()),
            "s" | "S" => {
                let changed: Vec<(&str, &[String])> = groups.iter().zip(assignment.iter().zip(&saved))
                    .filter(|(_, (list, before))| !same_set(list, before))
                    .map(|(group, (list, _))| (group.as_str(), list.as_slice())).collect();
                if changed.is_empty() { ctx.ui.notice(ui::warn("Изменений нет.")); return Ok(()); }
                let reply = ctx.request(&conn_set_argv(name, &changed), &Secrets::default())?;
                outcome(ctx, &reply);
                if reply.ok { offer_apply(ctx)?; }
                if !confirm::retryable(&reply) { return Ok(()); }
            }
            _ => match index(&choice, proxies.len()) {
                Some(i) => {
                    let proxy = &proxies[i];
                    let flags = assignment.iter().map(|list| list.contains(proxy)).collect();
                    let Some(chosen) = ctx.toggle(&format!("Группы подключения {proxy}"), &groups, flags, EMPTY)? else { continue };
                    for (g, list) in assignment.iter_mut().enumerate() {
                        match (list.contains(proxy), chosen.contains(&g)) {
                            (false, true) => list.push(proxy.clone()),
                            (true, false) => list.retain(|p| p != proxy),
                            _ => {}
                        }
                    }
                }
                None => ctx.invalid(),
            },
        }
    }
}
/// The same proxies regardless of order (how `conn set` compares them).
pub(crate) fn same_set(a: &[String], b: &[String]) -> bool {
    a.iter().all(|p| b.contains(p)) && b.iter().all(|p| a.contains(p))
}
/// Assigned proxies the node did not report (unique, in order) and the
/// stale ones among them: AmneziaWG peers `awg-<peer>` are not stale while
/// the node reports `AWG` (discovery does not list peers); `discovered`
/// `None` — the node was not read: none is stale. Forms list the
/// unreported ones after the discovered, checked, so sending keeps them.
pub(crate) fn unlisted(assigned: &[String], discovered: Option<&[String]>) -> (Vec<String>, Vec<String>) {
    let found = discovered.unwrap_or_default();
    let awg = found.iter().any(|name| name == "AWG");
    let mut extra: Vec<String> = Vec::new();
    for proxy in assigned {
        if !found.contains(proxy) && !extra.contains(proxy) { extra.push(proxy.clone()); }
    }
    let stale = if discovered.is_none() { Vec::new() } else { extra.iter().filter(|proxy| !(awg && proxy.starts_with("awg-"))).cloned().collect() };
    (extra, stale)
}
/// A proxy in forms: one not found on the node is marked.
pub(crate) fn proxy_label(proxy: &str, stale: &[String]) -> String {
    if stale.iter().any(|name| name == proxy) { format!("{proxy} (не найдено на ноде)") } else { proxy.to_owned() }
}
/// `conn set --name N --assign G=P …` for the given groups: one `--assign`
/// per proxy (names may contain commas), `G=` unassigns.
pub(crate) fn conn_set_argv(node: &str, assignments: &[(&str, &[String])]) -> Vec<String> {
    let mut words = argv(&["conn", "set", "--name", node]);
    for (group, proxies) in assignments {
        if proxies.is_empty() {
            words.extend(argv(&["--assign", &format!("{group}=")]));
        }
        for proxy in *proxies {
            words.extend(argv(&["--assign", &format!("{group}={proxy}")]));
        }
    }
    words
}

// ─── AmneziaWG ───────────────────────────────────────────────────────────────

impl Screen for AmneziaWg {
    fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> {
        loop {
            let reply = ctx.call(&["node", "list"])?;
            if !reply.ok {
                if read_failed(ctx, "AmneziaWG")? { continue; }
                return Ok(Navigation::Back);
            }
            let mut view = View::new("AmneziaWG");
            view.prompt = "Выберите ноду или действие: ".into();
            let items = node_items(&reply.data, false);
            if items.is_empty() { view.context.push(ui::text("Нет нод", ui::DIM)); } else { view.sections.push(items); }
            view.sections.push(vec![Item::new(0, "Назад", ui::NC)]);
            let Some(choice) = ctx.choose(&view)? else { return Ok(Navigation::Back); };
            if choice == "0" { return Ok(Navigation::Back); }
            match index(&choice, rows(&reply.data).len()) {
                Some(i) => awg_node(ctx, &text(&reply.data[i]["name"]))?,
                None => ctx.invalid(),
            }
        }
    }
}
fn awg_node(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    loop {
        let reply = node_request(ctx, name, &argv(&["awg", "status", "--name", name]), None)?;
        if !reply.ok { return Ok(()); }
        let installed = reply.data["installed"] == true;
        let peers = rows(&reply.data["peers"]);
        let mut view = View::new(format!("AmneziaWG: {name}"));
        view.prompt = "Выберите действие: ".into();
        if !installed {
            view.context.push(ui::text("AmneziaWG на ноде не установлен", ui::DIM));
        } else if peers.is_empty() {
            view.context.push(ui::text("Нет клиентов", ui::DIM));
        }
        if installed {
            for peer in peers {
                let (suffix, color) = match peer["status"].as_str() {
                    Some("used") => ("", ui::GREEN),
                    Some("orphan") => ("  не используется", ui::YELLOW),
                    _ => ("  не создан", ui::DIM),
                };
                view.context.push(ui::text(format!("{}{suffix}", text(&peer["name"])), color));
            }
        }
        let mut items = vec![Item::new('r', "Обновить", ui::CYAN)];
        if installed {
            items.extend([Item::new('c', "Создать недостающих", ui::GREEN), Item::new('d', "Удалить клиента", ui::RED), Item::new('x', "Удалить неиспользуемых", ui::RED)]);
        }
        items.push(Item::new(0, "Назад", ui::NC));
        view.sections.push(items);
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        match choice.as_str() {
            "r" | "R" => {}
            "c" | "C" if installed => { node_request(ctx, name, &argv(&["awg", "sync", "--name", name]), None)?; }
            "d" | "D" if installed => {
                let removable: Vec<String> = peers.iter().filter(|p| p["status"] != "missing").map(|p| text(&p["name"])).collect();
                if let Some(i) = ctx.select("Удаление клиента AmneziaWG", &removable)? {
                    let words = argv(&["awg", "remove", "--name", name, "--peer", &removable[i]]);
                    node_request(ctx, name, &words, Some(("Удаление клиента AmneziaWG", "Удалить?")))?;
                }
            }
            "x" | "X" if installed => {
                let words = argv(&["awg", "remove", "--name", name, "--orphans"]);
                node_request(ctx, name, &words, Some(("Удаление неиспользуемых клиентов AmneziaWG", "Удалить?")))?;
            }
            "0" => return Ok(()),
            _ => ctx.invalid(),
        }
    }
}

// ─── Telegram ────────────────────────────────────────────────────────────────

/// «нода  статус  причина» from `results` (data on success, error otherwise).
/// False when the reply carries no results table.
fn telegram_table(ctx: &mut Context<'_>, reply: &Reply) -> io::Result<bool> {
    let results = if reply.ok { rows(&reply.data["results"]) } else { rows(&reply.error["results"]) };
    if results.is_empty() { return Ok(false); }
    let mut view = View::new("Результат Telegram Proxy");
    view.status.push(ui::text("нода  статус  причина", ui::NC));
    for row in results {
        let (status, color) = match row["status"].as_str() {
            Some("ok") => ("готово", ui::GREEN),
            Some("not_installed") => ("не установлено", ui::YELLOW),
            Some("partial") => ("частично", ui::YELLOW),
            _ => ("ошибка", ui::RED),
        };
        view.context.push(ui::text(format!("{}  {status}  {}", text(&row["node"]), text(&row["reason"])), color));
    }
    // Kept on screen until Enter/0/EOF: the next menu frame would replace it.
    view.prompt = "Enter — продолжить: ".into();
    loop {
        match ctx.choose(&view)?.as_deref() {
            None | Some("" | "0") => return Ok(true),
            _ => ctx.invalid(),
        }
    }
}
/// v1 `_tui_telegram_batch`: unchecked node toggles → one `--name` per node →
/// the core's frozen plan → results table. A failed command (no results)
/// reopens the toggle with the same nodes checked.
fn telegram_batch(ctx: &mut Context<'_>, title: &str, words: Vec<String>) -> io::Result<()> {
    let listed = ctx.call(&["node", "list"])?;
    if !listed.ok { outcome(ctx, &listed); return Ok(()); }
    let nodes = names(&listed.data);
    let labels: Vec<String> = rows(&listed.data).iter().map(node_label).collect();
    let mut flags = vec![];
    loop {
        let Some(selected) = ctx.toggle(title, &labels, flags, EMPTY)? else { return Ok(()); };
        if selected.is_empty() { ctx.ui.notice(ui::warn("Ничего не выбрано.")); return Ok(()); }
        let mut command = words.clone();
        for &i in &selected { command.extend(argv(&["--name", &nodes[i]])); }
        let reply = confirm::run_confirmed(ctx, title, "Выполнить?", &command, &Secrets::default())?;
        if telegram_table(ctx, &reply)? { return Ok(()); }
        outcome(ctx, &reply);
        if !confirm::retryable(&reply) { return Ok(()); }
        flags = (0..labels.len()).map(|i| selected.contains(&i)).collect();
    }
}
impl Screen for Telegram {
    fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> {
        loop {
            let mut view = View::new("Telegram Proxy");
            view.prompt = "Выберите действие: ".into();
            view.sections.push(vec![Item::new('o', "Управление одной нодой", ui::CYAN), Item::new('s', "Общий статус нод", ui::CYAN)]);
            view.sections.push(vec![
                Item::new('i', "Включить MTProto Proxy", ui::GREEN), Item::new('p', "Обновить IP-адрес MTProto", ui::YELLOW),
                Item::new('w', "Обновить Web Proxy", ui::YELLOW), Item::new('r', "Перезапустить Web Proxy", ui::YELLOW),
                Item::new('b', "Перезапустить службу MTProxy", ui::YELLOW), Item::new('d', "Отключить способ доступа", ui::RED),
                Item::new('x', "Отключить Telegram Proxy полностью", ui::RED), Item::new(0, "Назад", ui::NC),
            ]);
            let Some(choice) = ctx.choose(&view)? else { return Ok(Navigation::Back); };
            match choice.as_str() {
                "o" | "O" => {
                    let listed = ctx.call(&["node", "list"])?;
                    if !listed.ok { outcome(ctx, &listed); continue; }
                    let labels: Vec<String> = rows(&listed.data).iter().map(node_label).collect();
                    if let Some(i) = ctx.select("Управление Telegram Proxy", &labels)? { interactive(ctx, &text(&listed.data[i]["name"]), true)?; }
                }
                "s" | "S" => {
                    let reply = ctx.call(&["telegram", "status", "--all"])?;
                    if !telegram_table(ctx, &reply)? { outcome(ctx, &reply); }
                }
                "i" | "I" => telegram_batch(ctx, "Включение MTProto Proxy", argv(&["telegram", "install"]))?,
                "p" | "P" => telegram_batch(ctx, "Обновление IP-адреса MTProto", argv(&["telegram", "refresh-ip"]))?,
                "w" | "W" => telegram_batch(ctx, "Обновление Web Proxy", argv(&["telegram", "web-update"]))?,
                "r" | "R" => telegram_batch(ctx, "Перезапуск Web Proxy", argv(&["telegram", "web-restart"]))?,
                "b" | "B" => telegram_batch(ctx, "Перезапуск службы MTProxy", argv(&["telegram", "backend-restart"]))?,
                "d" | "D" => {
                    let Some(i) = ctx.select("Отключение способа доступа", &["Web Proxy".into(), "MTProto Proxy".into()])? else { continue; };
                    let component = if i == 0 { "web" } else { "mtproto" };
                    telegram_batch(ctx, "Отключение способа доступа", argv(&["telegram", "remove", "--component", component]))?;
                }
                "x" | "X" => telegram_batch(ctx, "Полное отключение Telegram Proxy", argv(&["telegram", "remove-all"]))?,
                "0" => return Ok(Navigation::Back),
                _ => ctx.invalid(),
            }
        }
    }
}

// ─── Применение ──────────────────────────────────────────────────────────────

/// The apply state of a node (`node list|show .status`); none for a node without a profile.
fn apply_state(node: &Value) -> Option<(&'static str, Color)> {
    match node["status"].as_str() {
        Some("pending") => Some(("ожидает применения", ui::YELLOW)),
        Some("applied") => Some(("применено", ui::GREEN)),
        Some("running") => Some(("применяется…", ui::CYAN)),
        _ => None,
    }
}
fn pending_count(list: &Value) -> usize { rows(list).iter().filter(|node| node["status"] == "pending").count() }
fn warp_label(node: &Value) -> &'static str {
    match node["warp"].as_str() { Some("free") => "бесплатный", Some("plus") => "WARP+", _ => "не зарегистрирован" }
}
/// `node apply …` under its plan; `name` — the node of `--name` (node codes
/// and the top-level `domain_required` are resolved, then the command is
/// repeated). The report (success or `partial`) goes to the journal, one
/// `name: message` line per failure; for bulk nodes failed with
/// `domain_required` the domain is asked and the command repeated once.
pub(crate) fn apply(ctx: &mut Context<'_>, words: &[String], name: &str) -> io::Result<Reply> {
    let mut repeated = false;
    loop {
        let reply = confirm::run_confirmed(ctx, "Применение на нодах", "Применить?", words, &Secrets::default())?;
        if reply.ok || reply.code() == "partial" {
            let data = if reply.ok { &reply.data } else { &reply.error };
            let applied = joined(&data["applied"]);
            if !applied.is_empty() { ctx.ui.notice(ui::success(format!("Применено: {applied}"))); }
            let unchanged = joined(&data["unchanged"]);
            if !unchanged.is_empty() { ctx.ui.notice(ui::text(format!("Без изменений: {unchanged}"), ui::DIM)); }
            let failed = rows(&data["failed"]);
            for entry in failed {
                ctx.ui.notice(ui::warn(format!("{}: {}", text(&entry["name"]), text(&entry["message"]))));
            }
            if repeated { return Ok(reply); }
            let mut domains = false;
            for entry in failed.iter().filter(|entry| entry["code"] == "domain_required") {
                domains |= set_domain(ctx, &text(&entry["name"]))?;
            }
            if !domains { return Ok(reply); }
            repeated = true;
            continue;
        }
        // The core's message is already in the journal.
        if reply.code() == "nothing_pending" { return Ok(reply); }
        if handle_node_codes(ctx, &reply, name)? { continue; }
        outcome(ctx, &reply);
        return Ok(reply);
    }
}
/// Commands after whose success nodes may wait for `node apply`; the reads
/// `client nodes|connections --name C` (no change flag) are not among them.
pub(crate) fn offers_apply(words: &[&str]) -> bool {
    let changes = || words.iter().any(|w| matches!(*w, "--node" | "--inherit" | "--reset"));
    match words {
        ["client", "add" | "delete" | "set-group", ..] => true,
        ["client", "nodes" | "connections", ..] => changes(),
        ["conn", "set", ..] => true,
        _ => false,
    }
}
/// «Применить изменения на N нодах?» when `node list` has pending nodes → `node apply --pending`.
pub(crate) fn offer_apply(ctx: &mut Context<'_>) -> io::Result<()> {
    let listed = ctx.call(&["node", "list"])?;
    if !listed.ok { return Ok(()); }
    let count = pending_count(&listed.data);
    if count == 0 { return Ok(()); }
    if ctx.confirm(View::new("Применение на нодах"), &format!("Применить изменения на {count} нодах?"))? {
        apply(ctx, &argv(&["node", "apply", "--pending"]), "")?;
    }
    Ok(())
}

// ─── Профиль, домен и порты ноды ─────────────────────────────────────────────

const DOMAIN_INVALID: &str = "Некорректный домен.";
const PORT_INVALID: &str = "Порт должен быть числом от 1 до 65535.";
/// `validation::domain_valid` of the core: labels, at least one dot.
pub(crate) fn domain_valid(value: &str) -> bool {
    (1..=253).contains(&value.len()) && value.contains('.') && value.split('.').all(|label| {
        (1..=63).contains(&label.len()) && label.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            && !label.starts_with('-') && !label.ends_with('-')
    })
}
fn port_valid(value: &str) -> bool { value.is_empty() || (value.bytes().all(|b| b.is_ascii_digit()) && !value.starts_with('0') && value.parse::<u16>().is_ok()) }
/// A question repeated until `check` accepts the trimmed answer; `None` on cancel.
fn ask_valid(ctx: &mut Context<'_>, title: &str, prompt: &str, check: impl Fn(&str) -> bool, message: &str) -> io::Result<Option<String>> {
    loop {
        let Some(value) = ask(ctx, title, prompt)? else { return Ok(None); };
        let value = value.trim().to_owned();
        if check(&value) { return Ok(Some(value)); }
        ctx.ui.notice(ui::warn(message));
    }
}
/// «Профиль»: a profile or «Без профиля» → `node profile`.
fn node_profile(ctx: &mut Context<'_>, name: &str, node: &Value) -> io::Result<()> {
    let listed = ctx.call(&["profile", "list"])?;
    if !listed.ok { ctx.failed(); return Ok(()); }
    let mut values = vec![String::new()];
    values.extend(rows(&listed.data["profiles"]).iter().map(|p| text(&p["name"])));
    let labels: Vec<String> = values.iter().map(|v| if v.is_empty() { "Без профиля".to_owned() } else { v.clone() }).collect();
    let Some(i) = ctx.select(&format!("Профиль ноды: {name}"), &labels)? else { return Ok(()); };
    if values[i] == text(&node["profile"]) { ctx.ui.notice(ui::warn("Изменений нет.")); return Ok(()); }
    let reply = ctx.call(&["node", "profile", "--name", name, "--profile", &values[i]])?;
    outcome(ctx, &reply);
    Ok(())
}
/// «Домен»: Enter clears the domain → `node domain`.
fn node_domain(ctx: &mut Context<'_>, name: &str, node: &Value) -> io::Result<()> {
    let Some(domain) = ask_valid(ctx, &format!("Домен ноды: {name}"), "Домен (Enter — без домена)", |d| d.is_empty() || domain_valid(d), DOMAIN_INVALID)? else { return Ok(()); };
    if domain == text(&node["domain"]) { ctx.ui.notice(ui::warn("Изменений нет.")); return Ok(()); }
    let reply = ctx.call(&["node", "domain", "--name", name, "--domain", &domain])?;
    outcome(ctx, &reply);
    Ok(())
}
/// Protocols of a profile with a configurable port: (`node port --protocol` key, label, profile port).
fn port_protocols(profile: &Value) -> Vec<(&'static str, &'static str, String)> {
    let mut list = vec![];
    let xhttp = &profile["vless_xhttp"];
    if xhttp.is_object() && xhttp["topology"] != "nginx" { list.push(("vless-xhttp", "VLESS xHTTP", port_text(xhttp))); }
    for (field, key, label) in [("vless_grpc", "vless-grpc", "VLESS gRPC"), ("hysteria2", "hysteria2", "Hysteria2"), ("amneziawg", "amneziawg", "AmneziaWG")] {
        if profile[field].is_object() { list.push((key, label, port_text(&profile[field]))); }
    }
    list
}
/// «Порты»: a protocol of the profile with its effective port → `node port` (Enter — the profile's port).
fn node_ports(ctx: &mut Context<'_>, name: &str, node: &Value) -> io::Result<()> {
    let profile = text(&node["profile"]);
    if profile.is_empty() { ctx.ui.notice(ui::warn("У ноды нет профиля.")); return Ok(()); }
    let shown = ctx.call(&["profile", "show", "--name", &profile])?;
    if !shown.ok { ctx.failed(); return Ok(()); }
    let protocols = port_protocols(&shown.data);
    if protocols.is_empty() { ctx.ui.notice(ui::warn("В профиле нет протоколов с настраиваемым портом.")); return Ok(()); }
    let labels: Vec<String> = protocols.iter().map(|(key, label, port)| {
        let own = text(&node["ports"][*key]);
        if own.is_empty() { format!("{label}: {port} (профиль)") } else { format!("{label}: {own} (нода)") }
    }).collect();
    let Some(i) = ctx.select(&format!("Порты ноды: {name}"), &labels)? else { return Ok(()); };
    let Some(port) = ask_valid(ctx, &format!("Порты ноды: {name}"), "Порт (Enter — порт профиля)", port_valid, PORT_INVALID)? else { return Ok(()); };
    let reply = ctx.call(&["node", "port", "--name", name, "--protocol", protocols[i].0, "--port", &port])?;
    outcome(ctx, &reply);
    Ok(())
}

// ─── Профили нод ─────────────────────────────────────────────────────────────

/// (form value, label, list abbreviation) of the protocols of a profile.
const PROTOCOLS: [(&str, &str, &str); 6] = [
    ("vless-tcp", "VLESS TCP", "TCP"), ("xhttp", "VLESS xHTTP", "xHTTP"), ("grpc", "VLESS gRPC", "gRPC"),
    ("hysteria2", "Hysteria2", "HY2"), ("amneziawg", "AmneziaWG", "AWG"), ("warp", "WARP", "WARP"),
];
const SITE_SOURCES: [(&str, &str); 4] = [("random", "Случайный"), ("simple", "simple-web-templates"), ("sni", "sni-templates"), ("nothing", "nothing-sni")];
const IPV6: [(&str, &str); 3] = [("default", "Как в системе"), ("enabled", "Включить"), ("disabled", "Отключить")];

fn port_text(block: &Value) -> String { if block["port"].is_null() { String::new() } else { text(&block["port"]) } }
/// The answers of the profile wizard; the same fields as the web form.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ProfileForm {
    pub name: String, pub reality: String, pub sni_domain: String, pub site_source: String, pub protocols: Vec<String>,
    pub xhttp: String, pub xhttp_port: String, pub grpc_port: String, pub hysteria2_port: String, pub hysteria2_obfs: bool,
    pub amneziawg_port: String, pub amneziawg_dns: String, pub ipv6: String, pub acme_email: String, pub mihomo_version: String,
}
impl Default for ProfileForm {
    fn default() -> Self {
        Self { name: String::new(), reality: "self-steal".into(), sni_domain: String::new(), site_source: "random".into(),
            protocols: vec!["vless-tcp".into()], xhttp: "reality".into(), xhttp_port: String::new(), grpc_port: String::new(),
            hysteria2_port: String::new(), hysteria2_obfs: false, amneziawg_port: String::new(), amneziawg_dns: String::new(),
            ipv6: "default".into(), acme_email: String::new(), mihomo_version: String::new() }
    }
}
impl ProfileForm {
    fn on(&self, protocol: &str) -> bool { self.protocols.iter().any(|p| p == protocol) }
    /// The answers that describe an existing profile (`profile show`).
    pub(crate) fn from_profile(profile: &Value) -> Self {
        let sni = profile["reality_mode"] == "sni";
        Self {
            name: text(&profile["name"]), reality: if sni { "sni" } else { "self-steal" }.into(), sni_domain: text(&profile["sni_domain"]),
            site_source: Some(text(&profile["site_source"])).filter(|s| !s.is_empty()).unwrap_or_else(|| "random".into()),
            protocols: enabled_protocols(profile),
            xhttp: if profile["vless_xhttp"]["topology"] == "nginx" { "nginx" } else { "reality" }.into(),
            xhttp_port: port_text(&profile["vless_xhttp"]), grpc_port: port_text(&profile["vless_grpc"]),
            hysteria2_port: port_text(&profile["hysteria2"]), hysteria2_obfs: profile["hysteria2"]["obfs"] == true,
            amneziawg_port: port_text(&profile["amneziawg"]), amneziawg_dns: text(&profile["amneziawg"]["dns"]),
            ipv6: Some(text(&profile["ipv6"])).filter(|s| !s.is_empty()).unwrap_or_else(|| "default".into()),
            acme_email: text(&profile["acme_email"]), mihomo_version: text(&profile["mihomo_version"]),
        }
    }
}
fn enabled_protocols(profile: &Value) -> Vec<String> {
    let on = [profile["vless_tcp"] == true, profile["vless_xhttp"].is_object(), profile["vless_grpc"].is_object(),
        profile["hysteria2"].is_object(), profile["amneziawg"].is_object(), profile["warp"] == true];
    PROTOCOLS.iter().zip(on).filter(|(_, on)| *on).map(|((value, ..), _)| (*value).to_owned()).collect()
}
/// A node of this profile needs a domain: Self-Steal with a Reality transport, xHTTP or Hysteria2.
pub(crate) fn needs_domain(profile: &Value) -> bool {
    profile["reality_mode"] == "self-steal" && (profile["vless_tcp"] == true || profile["vless_xhttp"].is_object()
        || profile["vless_grpc"].is_object() || profile["hysteria2"].is_object())
}
fn protocols_label(profile: &Value) -> String {
    let on = enabled_protocols(profile);
    let list: Vec<&str> = PROTOCOLS.iter().filter(|(value, ..)| on.iter().any(|p| p == value)).map(|(.., short)| *short).collect();
    if list.is_empty() { "—".into() } else { list.join(" ") }
}
fn reality_label(profile: &Value) -> String {
    if profile["reality_mode"] == "sni" { format!("SNI {}", text(&profile["sni_domain"])) } else { "Self-Steal".into() }
}
/// The desired-profile flags of the answers in grammar order, without email and
/// mihomo version (add and set treat them differently).
fn profile_flags(form: &ProfileForm) -> Vec<(&'static str, Option<String>)> {
    let flag = |protocol: &str| Some(if form.on(protocol) { "on" } else { "off" }.to_owned());
    let value = |s: &str| Some(s.to_owned());
    let sni = form.reality == "sni";
    let mut flags = vec![("--reality", value(if sni { "sni" } else { "self-steal" }))];
    if sni { flags.push(("--sni-domain", value(&form.sni_domain))); } else { flags.push(("--site-source", value(&form.site_source))); }
    flags.push(("--vless-tcp", flag("vless-tcp")));
    // Under SNI the xHTTP topology is always Reality: the nginx one needs the node's site.
    let topology = if !form.on("xhttp") { "off" } else if sni || form.xhttp != "nginx" { "reality" } else { "nginx" };
    flags.push(("--xhttp", value(topology)));
    if topology == "reality" && !form.xhttp_port.is_empty() { flags.push(("--xhttp-port", value(&form.xhttp_port))); }
    flags.push(("--grpc", flag("grpc")));
    if form.on("grpc") && !form.grpc_port.is_empty() { flags.push(("--grpc-port", value(&form.grpc_port))); }
    flags.push(("--hysteria2", flag("hysteria2")));
    if form.on("hysteria2") {
        if !form.hysteria2_port.is_empty() { flags.push(("--hysteria2-port", value(&form.hysteria2_port))); }
        flags.push(("--hysteria2-obfs", value(if form.hysteria2_obfs { "on" } else { "off" })));
    }
    flags.push(("--amneziawg", flag("amneziawg")));
    if form.on("amneziawg") {
        if !form.amneziawg_port.is_empty() { flags.push(("--amneziawg-port", value(&form.amneziawg_port))); }
        if !form.amneziawg_dns.is_empty() { flags.push(("--amneziawg-dns", value(&form.amneziawg_dns))); }
    }
    flags.push(("--warp", flag("warp")));
    flags.push(("--ipv6", value(&form.ipv6)));
    flags
}
fn flatten(flags: Vec<(&'static str, Option<String>)>) -> Vec<String> {
    flags.into_iter().flat_map(|(flag, value)| std::iter::once(flag.to_owned()).chain(value)).collect()
}
/// `profile add`: an empty email — `--random-acme-email`, an empty version — the latest.
pub(crate) fn profile_add_argv(form: &ProfileForm) -> Vec<String> {
    let mut flags = profile_flags(form);
    flags.push(if form.acme_email.is_empty() { ("--random-acme-email", None) } else { ("--acme-email", Some(form.acme_email.clone())) });
    if !form.mihomo_version.is_empty() { flags.push(("--mihomo-version", Some(form.mihomo_version.clone()))); }
    let mut words = argv(&["profile", "add", "--name", &form.name]);
    words.extend(flatten(flags));
    words
}
/// `profile set` with the changed flags only; `None` — nothing changed.
pub(crate) fn profile_set_argv(name: &str, form: &ProfileForm, current: &Value) -> Option<Vec<String>> {
    let before = ProfileForm::from_profile(current);
    let previous = profile_flags(&before);
    let mut changed: Vec<_> = profile_flags(form).into_iter().filter(|(flag, value)| !previous.iter().any(|(f, v)| f == flag && v == value)).collect();
    if form.acme_email != before.acme_email {
        changed.push(if form.acme_email.is_empty() { ("--random-acme-email", None) } else { ("--acme-email", Some(form.acme_email.clone())) });
    }
    if !form.mihomo_version.is_empty() && form.mihomo_version != before.mihomo_version { changed.push(("--mihomo-version", Some(form.mihomo_version.clone()))); }
    if changed.is_empty() { return None; }
    let mut words = argv(&["profile", "set", "--name", name]);
    words.extend(flatten(changed));
    Some(words)
}
fn email_valid(value: &str) -> bool {
    let Some((local, domain)) = value.split_once('@') else { return false; };
    !local.is_empty() && local.bytes().all(|b| b.is_ascii_alphanumeric() || b"._%+-".contains(&b))
        && domain.split('.').count() >= 2 && domain.split('.').all(|l| !l.is_empty() && l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'))
}
fn version_valid(value: &str) -> bool {
    value.strip_prefix('v').is_some_and(|rest| { let parts: Vec<_> = rest.split('.').collect(); parts.len() == 3 && parts.iter().all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit())) })
}
/// One of `options` (value, label) by number; the current value is marked.
fn choose_option(ctx: &mut Context<'_>, title: &str, options: &[(&str, &str)], current: Option<&str>) -> io::Result<Option<String>> {
    let labels: Vec<String> = options.iter().map(|(value, label)| if current == Some(*value) { format!("{label} (сейчас)") } else { (*label).to_owned() }).collect();
    Ok(ctx.select(title, &labels)?.map(|i| options[i].0.to_owned()))
}
/// The profile wizard (plan order): name → Reality → masking domain or site
/// source → protocols → xHTTP topology → ports → obfs → AmneziaWG DNS → IPv6 →
/// email → mihomo version. Editing (`current`) skips the name; Enter keeps the
/// current answer. `None` — cancelled.
fn profile_wizard(ctx: &mut Context<'_>, current: Option<&ProfileForm>) -> io::Result<Option<ProfileForm>> {
    let editing = current.is_some();
    let mut form = current.cloned().unwrap_or_default();
    let title = if editing { format!("Профиль: {}", form.name) } else { "Добавление профиля".to_owned() };
    let mark = |value: &str| editing.then_some(value.to_owned());
    if !editing {
        loop {
            let Some(name) = ask(ctx, &title, "Имя профиля")? else { return Ok(None); };
            if !name.trim().is_empty() { form.name = name.trim().to_owned(); break; }
            ctx.ui.notice(ui::warn("Имя профиля не указано."));
        }
    }
    let reality = [("self-steal", "Self-Steal — у ноды свой домен"), ("sni", "SNI — маскировка под чужой домен, нода без домена")];
    let Some(mode) = choose_option(ctx, "Режим Reality", &reality, mark(&form.reality).as_deref())? else { return Ok(None); };
    form.reality = mode;
    if form.reality == "sni" {
        let keep = editing && !form.sni_domain.is_empty();
        let prompt = if keep { format!("Домен-маскировка [{}]", form.sni_domain) } else { "Домен-маскировка".to_owned() };
        let Some(domain) = ask_valid(ctx, &title, &prompt, |d| domain_valid(d) || (keep && d.is_empty()), DOMAIN_INVALID)? else { return Ok(None); };
        if !domain.is_empty() { form.sni_domain = domain; }
    } else {
        let Some(source) = choose_option(ctx, "Сайт-заглушка", &SITE_SOURCES, mark(&form.site_source).as_deref())? else { return Ok(None); };
        form.site_source = source;
    }
    let labels: Vec<String> = PROTOCOLS.iter().map(|(_, label, _)| (*label).to_owned()).collect();
    loop {
        let flags = PROTOCOLS.iter().map(|(value, ..)| form.on(value)).collect();
        let Some(chosen) = ctx.toggle("Протоколы профиля", &labels, flags, EMPTY)? else { return Ok(None); };
        if chosen.is_empty() { ctx.ui.notice(ui::warn("Выберите хотя бы один протокол.")); continue; }
        form.protocols = chosen.into_iter().map(|i| PROTOCOLS[i].0.to_owned()).collect();
        break;
    }
    if form.on("xhttp") {
        if form.reality == "sni" { form.xhttp = "reality".into(); } else {
            let Some(topology) = choose_option(ctx, "Топология xHTTP", &[("reality", "Reality"), ("nginx", "Через nginx сайта")], mark(&form.xhttp).as_deref())? else { return Ok(None); };
            form.xhttp = topology;
        }
    }
    let ports: [(&str, &str, bool); 4] = [
        ("xhttp", "VLESS xHTTP", form.on("xhttp") && form.xhttp == "reality"), ("grpc", "VLESS gRPC", form.on("grpc")),
        ("hysteria2", "Hysteria2", form.on("hysteria2")), ("amneziawg", "AmneziaWG", form.on("amneziawg")),
    ];
    for (key, label, asked) in ports {
        if !asked { continue; }
        let field = match key { "xhttp" => &mut form.xhttp_port, "grpc" => &mut form.grpc_port, "hysteria2" => &mut form.hysteria2_port, _ => &mut form.amneziawg_port };
        let keep = editing && !field.is_empty();
        let prompt = if keep { format!("Порт {label} [{field}]") } else { format!("Порт {label} (Enter — случайный)") };
        let Some(port) = ask_valid(ctx, &title, &prompt, port_valid, PORT_INVALID)? else { return Ok(None); };
        if !port.is_empty() || !keep { *field = port; }
    }
    if form.on("hysteria2") {
        let current = editing.then_some(if form.hysteria2_obfs { "on" } else { "off" });
        let Some(obfs) = choose_option(ctx, "Hysteria2: обфускация (obfs)", &[("on", "Включить"), ("off", "Выключить")], current)? else { return Ok(None); };
        form.hysteria2_obfs = obfs == "on";
    }
    if form.on("amneziawg") {
        let prompt = if form.amneziawg_dns.is_empty() { "DNS AmneziaWG (Enter — 1.1.1.1, 1.0.0.1)".to_owned() } else { format!("DNS AmneziaWG [{}]", form.amneziawg_dns) };
        let Some(dns) = ask(ctx, &title, &prompt)? else { return Ok(None); };
        if !dns.trim().is_empty() { form.amneziawg_dns = dns.trim().to_owned(); }
    }
    let Some(ipv6) = choose_option(ctx, "IPv6", &IPV6, mark(&form.ipv6).as_deref())? else { return Ok(None); };
    form.ipv6 = ipv6;
    let keep = editing && !form.acme_email.is_empty();
    let prompt = if keep { format!("Email ACME [{}]", form.acme_email) } else { "Email ACME (Enter — случайный адрес)".to_owned() };
    let Some(email) = ask_valid(ctx, &title, &prompt, |e| e.is_empty() || email_valid(e), "Некорректный email.")? else { return Ok(None); };
    if !email.is_empty() || !keep { form.acme_email = email; }
    let keep = editing && !form.mihomo_version.is_empty();
    let prompt = if keep { format!("Версия mihomo [{}]", form.mihomo_version) } else { "Версия mihomo (Enter — последняя)".to_owned() };
    let Some(version) = ask_valid(ctx, &title, &prompt, |v| v.is_empty() || version_valid(v), "Версия в виде vX.Y.Z.")? else { return Ok(None); };
    if !version.is_empty() || !keep { form.mihomo_version = version; }
    Ok(Some(form))
}
impl Screen for Profiles {
    fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> {
        loop {
            let reply = ctx.call(&["profile", "list"])?;
            if !reply.ok {
                if read_failed(ctx, "Профили нод")? { continue; }
                return Ok(Navigation::Back);
            }
            let list = rows(&reply.data["profiles"]);
            let mut view = View::new("Профили нод");
            view.prompt = "Выберите действие: ".into();
            if list.is_empty() { view.context.push(ui::text("Нет профилей", ui::DIM)); } else {
                view.sections.push(list.iter().enumerate().map(|(i, p)| Item::new(i + 1,
                    format!("{}  {}  {}  нод: {}", text(&p["name"]), reality_label(p), protocols_label(p), rows(&p["nodes"]).len()), ui::CYAN)).collect());
            }
            view.sections.push(vec![Item::new('a', "Добавить профиль", ui::GREEN), Item::new(0, "Назад", ui::NC)]);
            let Some(choice) = ctx.choose(&view)? else { return Ok(Navigation::Back); };
            match choice.as_str() {
                "a" | "A" => {
                    let Some(form) = profile_wizard(ctx, None)? else { continue; };
                    let added = ctx.request(&profile_add_argv(&form), &Secrets::default())?;
                    if added.ok { ProfileCard(added.data["name"].as_str().unwrap_or(&form.name).to_owned()).run(ctx)?; } else { outcome(ctx, &added); }
                }
                "0" => return Ok(Navigation::Back),
                _ => match index(&choice, list.len()) {
                    Some(i) => { ProfileCard(text(&list[i]["name"])).run(ctx)?; }
                    None => ctx.invalid(),
                },
            }
        }
    }
}
fn profile_view(name: &str, profile: &Value) -> View {
    let mut view = View::new(format!("Профиль: {name}"));
    view.prompt = "Выберите действие: ".into();
    let plain = |line: String| ui::text(line, ui::NC);
    let off = |block: &Value, on: String| if block.is_object() { on } else { "выкл.".into() };
    view.context.push(plain(format!("Reality: {}", reality_label(profile))));
    if profile["reality_mode"] != "sni" { view.context.push(plain(format!("Сайт-заглушка: {}", text(&profile["site_source"])))); }
    view.context.push(plain(format!("VLESS TCP: {}", if profile["vless_tcp"] == true { "вкл." } else { "выкл." })));
    let xhttp = &profile["vless_xhttp"];
    view.context.push(plain(format!("VLESS xHTTP: {}", off(xhttp, if xhttp["topology"] == "nginx" { "через nginx".into() } else { format!("Reality, порт {}", port_text(xhttp)) }))));
    view.context.push(plain(format!("VLESS gRPC: {}", off(&profile["vless_grpc"], format!("порт {}", port_text(&profile["vless_grpc"]))))));
    let hy2 = &profile["hysteria2"];
    view.context.push(plain(format!("Hysteria2: {}", off(hy2, format!("порт {}{}", port_text(hy2), if hy2["obfs"] == true { ", obfs" } else { "" })))));
    let awg = &profile["amneziawg"];
    view.context.push(plain(format!("AmneziaWG: {}", off(awg, format!("порт {}, DNS {}", port_text(awg), text(&awg["dns"]))))));
    view.context.push(plain(format!("WARP: {}", if profile["warp"] != true { "выкл." } else if profile["warp_plus"] == true { "вкл., ключ WARP+ задан" } else { "вкл." })));
    let ipv6 = text(&profile["ipv6"]);
    view.context.push(plain(format!("IPv6: {}", IPV6.iter().find(|(v, _)| *v == ipv6).map_or(ipv6.as_str(), |(_, l)| l))));
    view.context.push(plain(format!("Email ACME: {}", text(&profile["acme_email"]))));
    view.context.push(plain(format!("Версия mihomo: {}", text(&profile["mihomo_version"]))));
    let nodes = joined(&profile["nodes"]);
    view.context.push(plain(format!("Ноды: {}", if nodes.is_empty() { "нет" } else { &nodes })));
    if needs_domain(profile) { view.context.push(ui::text("Ноде этого профиля нужен домен", ui::YELLOW)); }
    view.sections.push(vec![
        Item::new('y', "Применить на нодах профиля", ui::GREEN), Item::new('e', "Изменить", ui::YELLOW),
        Item::new('d', "Удалить профиль", ui::RED), Item::new(0, "Назад", ui::NC),
    ]);
    view
}
impl Screen for ProfileCard {
    fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> {
        loop {
            let reply = ctx.call(&["profile", "show", "--name", &self.0])?;
            if !reply.ok {
                if reply.code() != "not_found" && read_failed(ctx, &format!("Профиль: {}", self.0))? { continue; }
                return Ok(Navigation::Back);
            }
            let profile = &reply.data;
            let name = self.0.clone();
            let Some(choice) = ctx.choose(&profile_view(&name, profile))? else { return Ok(Navigation::Back); };
            match choice.as_str() {
                "y" | "Y" => {
                    if rows(&profile["nodes"]).is_empty() { ctx.ui.notice(ui::warn("Профиль не назначен нодам.")); continue; }
                    apply(ctx, &argv(&["node", "apply", "--profile", &name]), "")?;
                }
                "e" | "E" => {
                    let Some(form) = profile_wizard(ctx, Some(&ProfileForm::from_profile(profile)))? else { continue; };
                    match profile_set_argv(&name, &form, profile) {
                        None => ctx.ui.notice(ui::warn("Изменений нет.")),
                        Some(words) => { let reply = ctx.request(&words, &Secrets::default())?; outcome(ctx, &reply); }
                    }
                }
                "d" | "D" => {
                    let words = argv(&["profile", "delete", "--name", &name]);
                    let reply = confirm::run_confirmed(ctx, "Удаление профиля", "Удалить профиль?", &words, &Secrets::default())?;
                    if reply.ok { return Ok(Navigation::Back); }
                    outcome(ctx, &reply);
                }
                "0" => return Ok(Navigation::Back),
                _ => ctx.invalid(),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::{Registry, ScriptedUi, UserInterface};
    use essence_rc_client::{Log, ScriptedClient, Step};
    use serde_json::json;

    fn ok(data: Value) -> Reply { Reply::success(data) }
    fn err(code: &str, extra: Value) -> Reply {
        let mut error = if extra.is_object() { extra } else { json!({}) };
        error["code"] = json!(code);
        Reply { error, ..Reply::default() }
    }
    fn plan(code: &str, token: &str) -> Reply { err(code, json!({"plan_token": token, "plan": ["Operation and consequences", "Targets: n"]})) }
    fn step(words: &[&str], reply: Reply) -> (Vec<String>, Reply) { (argv(words), reply) }
    fn with_yes(words: &[String], token: &str) -> Vec<String> { let mut w = words.to_vec(); w.extend(argv(&["--yes", "--plan-token", token])); w }
    fn noticed(ui: &ScriptedUi, needle: &str) -> bool { ui.notices.iter().any(|l| l.to_string().contains(needle)) }
    fn confirms(ui: &ScriptedUi) -> usize { ui.views.iter().filter(|v| v.prompt.contains("(y/N)")).count() }
    fn colors(view: &View) -> Vec<Option<ratatui::style::Color>> { view.context.iter().map(|l| l.style.fg).collect() }

    /// v2 grammar of every command this module sends (remote-control/core/src/cli.rs CATALOG).
    const TG: &str = "name+ all component=";
    const PROFILE: &str = "name= acme-email= random-acme-email reality= sni-domain= site-source= mihomo-version= vless-tcp= xhttp= xhttp-port= grpc= grpc-port= hysteria2= hysteria2-port= hysteria2-obfs= amneziawg= amneziawg-port= amneziawg-dns= warp= ipv6=";
    const GRAMMAR: &[(&str, &str, &str)] = &[
        ("status", "", ""), ("group", "list", ""),
        ("node", "list", ""), ("node", "show", "name="), ("node", "aliases", "name= set+ unset+"),
        ("node", "rename", "name= new-name="), ("node", "tag", "name= tag="), ("node", "password", "name="),
        ("node", "add", "name= ip= port= user= auth= tag= host-key= accept-new-host-key replace-host-key= defer-ssh-setup profile= domain="),
        ("node", "trust-host-key", "name= host-key="), ("node", "delete", "name= scope= revoke-key"), ("node", "check", "name="),
        ("node", "harden", "name= port="), ("node", "setup-ssh", "provision-keys= on-failure="),
        ("node", "profile", "name= profile="), ("node", "domain", "name= domain="), ("node", "port", "name= protocol= port="),
        ("node", "apply", "name+ profile= pending"),
        ("profile", "list", ""), ("profile", "show", "name="), ("profile", "add", PROFILE), ("profile", "set", PROFILE), ("profile", "delete", "name="),
        ("node", "shell", "name="), ("conn", "list", "name= discover"), ("conn", "set", "name= assign+"), ("conn", "sync", "name="),
        ("awg", "status", "name="), ("awg", "sync", "name="), ("awg", "remove", "name= peer+ orphans"),
        ("telegram", "status", TG), ("telegram", "install", TG), ("telegram", "refresh-ip", TG), ("telegram", "web-update", TG),
        ("telegram", "web-restart", TG), ("telegram", "backend-restart", TG), ("telegram", "remove", TG), ("telegram", "remove-all", TG),
        ("telegram", "menu", "name="),
    ];
    fn parses(words: &[String]) -> bool {
        let Some((noun, rest)) = words.split_first() else { return false; };
        let found = GRAMMAR.iter().filter(|(n, ..)| n == noun).find_map(|(_, verb, tokens)| {
            if verb.is_empty() { Some((*tokens, rest)) }
            else if rest.first().is_some_and(|w| w == verb) { Some((*tokens, &rest[1..])) }
            else { None }
        });
        let Some((tokens, flags)) = found else { return false; };
        let (mut seen, mut i) = (vec![], 0);
        while i < flags.len() {
            let Some(flag) = flags[i].strip_prefix("--") else { return false; };
            let spec = match flag {
                "yes" => "yes",
                "plan-token" => "plan-token=",
                _ => match tokens.split_whitespace().find(|t| t.trim_end_matches(['=', '+']) == flag) { Some(t) => t, None => return false },
            };
            if !spec.ends_with('+') { if seen.contains(&flag) { return false; } seen.push(flag); }
            if spec.ends_with(['=', '+']) { i += 1; if i >= flags.len() { return false; } }
            i += 1;
        }
        true
    }
    #[test]
    fn grammar_rejects_v1_selectors() {
        assert!(!parses(&argv(&["conn", "sync", "--node", "n"])));
        assert!(!parses(&argv(&["telegram", "install", "--node", "n"])));
        assert!(parses(&argv(&["telegram", "install", "--name", "a", "--name", "b"])));
    }

    /// Runs a flow over scripted daemon replies; every request is v2 grammar
    /// and every scripted input and reply is consumed.
    fn run<R, S: Into<Step>>(steps: Vec<S>, inputs: &[&str], flow: impl FnOnce(&mut Context<'_>) -> io::Result<R>) -> (R, ScriptedClient, ScriptedUi) {
        let registry = Registry { screens: vec![], github_wizard: None };
        let mut client = ScriptedClient::new(steps);
        let mut ui = ScriptedUi::new(inputs);
        let result = flow(&mut Context::for_test(&mut client, &mut ui, &registry)).unwrap();
        client.assert_finished();
        assert!(ui.inputs.is_empty(), "unused inputs: {:?}", ui.inputs);
        for call in &client.calls { assert!(parses(call), "not v2 grammar: {call:?}"); }
        (result, client, ui)
    }
    fn screen<S: Into<Step>>(screen: &mut dyn Screen, inputs: &[&str], steps: Vec<S>) -> (ScriptedClient, ScriptedUi) {
        let (navigation, client, ui) = run(steps, inputs, |ctx| screen.run(ctx));
        assert!(matches!(navigation, Navigation::Back));
        (client, ui)
    }
    fn node() -> Value {
        json!({"name": "n", "ip": "192.0.2.1", "port": 22, "user": "root", "auth": "password", "tag": "tag", "identity": null,
            "password": "ok", "issues": [], "aliases": {}, "groups": ["g"], "clients": 1, "delete_options": [
                {"scope": "local", "revoke_key": false, "label": "local"}, {"scope": "server", "revoke_key": false, "label": "server"},
                {"scope": "server", "revoke_key": true, "label": "server + revoke"}]})
    }
    fn show() -> (Vec<String>, Reply) { step(&["node", "show", "--name", "n"], ok(node())) }
    fn listing() -> Vec<(Vec<String>, Reply)> { vec![step(&["node", "list"], ok(json!([]))), step(&["status"], ok(json!({})))] }
    fn add_words(auth: &str, extra: &[&str]) -> Vec<String> {
        let mut words = argv(&["node", "add", "--name", "vps-1", "--ip", "192.0.2.1", "--port", "22", "--user", "root", "--auth", auth, "--tag", "tag"]);
        words.extend(argv(extra));
        words
    }
    const ACCEPT: &[&str] = &["--accept-new-host-key"];
    fn added(needs_setup: bool) -> Reply { ok(json!({"name": "vps-1", "id": "x", "needs_setup": needs_setup})) }
    /// The add wizard reads the profiles after the tag; none — no question.
    fn no_profiles() -> (Vec<String>, Reply) { step(&["profile", "list"], ok(json!({"profiles": []}))) }
    /// The apply offer reads `node list` after a change; no pending node — no question.
    fn nothing_pending() -> (Vec<String>, Reply) { step(&["node", "list"], ok(json!([]))) }

    // ─── Ноды, добавление ────────────────────────────────────────────────────

    #[test]
    fn add_uses_v1_defaults_and_sends_password_only_as_secret() {
        for key in ["a", "A"] {
            for (choice, auth) in [("1", "key"), ("2", "password")] {
                let mut inputs = vec![key, "", "192.0.2.1", "", "", choice];
                if auth == "password" { inputs.push("top-secret"); }
                inputs.extend(["tag", "0"]);
                let mut steps = listing();
                steps.extend([no_profiles(), (add_words(auth, ACCEPT), added(false))]);
                steps.extend(listing());
                let (client, ui) = screen(&mut Nodes, &inputs, steps);
                let expected: Vec<String> = if auth == "password" { vec!["password".into()] } else { vec![] };
                assert_eq!(client.secret_names[3], expected);
                assert!(!client.calls.iter().flatten().any(|s| s.contains("top-secret")));
                assert!(!ui.views.iter().flat_map(View::lines).any(|l| l.to_string().contains("top-secret")));
                assert!(ui.notices.is_empty());
            }
        }
    }
    struct HiddenUi { script: ScriptedUi, hidden: Vec<bool> }
    impl UserInterface for HiddenUi {
        fn input(&mut self, view: &View, hidden: bool) -> io::Result<Option<zeroize::Zeroizing<String>>> { self.hidden.push(hidden); self.script.input(view, hidden) }
        fn show(&mut self, view: &View) -> io::Result<()> { self.script.show(view) }
        fn log(&mut self, log: &Log) { self.script.log(log) }
        fn notice(&mut self, line: ratatui::text::Line<'static>) { self.script.notice(line) }
        fn suspended(&mut self, command: &mut std::process::Command) -> io::Result<std::process::ExitStatus> { self.script.suspended(command) }
    }
    #[test]
    fn passwords_are_read_hidden() {
        let registry = Registry { screens: vec![], github_wizard: None };
        let mut client = ScriptedClient::new([no_profiles(), (add_words("password", ACCEPT), added(false)), step(&["node", "password", "--name", "n"], ok(json!({"name": "n"})))]);
        let mut ui = HiddenUi { script: ScriptedUi::new(&["", "192.0.2.1", "", "", "2", "pw", "tag", "pw2"]), hidden: vec![] };
        let mut ctx = Context::for_test(&mut client, &mut ui, &registry);
        add_node(&mut ctx).unwrap();
        assert!(store_password(&mut ctx, "n").unwrap().unwrap().ok);
        client.assert_finished();
        assert_eq!(ui.hidden, [false, false, false, false, false, true, false, true]);
    }
    #[test]
    fn add_validates_ip_port_password_and_tag_and_cancels() {
        let (_, _, ui) = run(none(), &["", ""], add_node);
        assert!(noticed(&ui, "IP не указан"));
        let (_, _, ui) = run(vec![no_profiles(), (add_words("password", ACCEPT), added(false))],
            &["", "192.0.2.1", "0", "70000", "x", "", "", "2", "", "pw", "", "tag"], add_node);
        assert_eq!(ui.notices.len(), 5);
        // EOF at any question sends nothing.
        run(none(), &["", "192.0.2.1", "", "", "1"], add_node);
        run(none(), &["", "192.0.2.1", "", ""], add_node);
    }
    #[test]
    fn add_replaces_a_changed_key_only_through_its_plan() {
        let changed = err("host_key_changed", json!({"host": "192.0.2.1", "port": 22, "fingerprints": ["SHA256:new", "SHA256:old"], "name": "vps-1"}));
        let replace = add_words("password", &["--replace-host-key", "SHA256:new"]);
        let (_, client, ui) = run(vec![
            no_profiles(), (add_words("password", ACCEPT), changed.clone()), (replace.clone(), plan("confirmation_required", "one")),
            (with_yes(&replace, "one"), added(false)),
        ], &["", "192.0.2.1", "", "", "2", "pw", "tag", "y"], add_node);
        assert!(client.secret_names[1..].iter().all(|n| n == &["password"]));
        assert_eq!(confirms(&ui), 1);
        for no in ["", "n", "N"] {
            run(vec![no_profiles(), (add_words("key", ACCEPT), changed.clone()), (add_words("key", &["--replace-host-key", "SHA256:new"]), plan("confirmation_required", "one"))],
                &["", "192.0.2.1", "", "", "1", "tag", no], add_node);
        }
    }
    #[test]
    fn add_remote_failure_retries_on_consent_with_optional_new_password() {
        let failed = err("remote_failed", json!({"reason": "auth", "name": "vps-1"}));
        let (_, client, _) = run(vec![no_profiles(), (add_words("password", ACCEPT), failed.clone()), (add_words("password", ACCEPT), added(false))],
            &["", "192.0.2.1", "", "", "2", "pw", "tag", "", "second"], add_node);
        assert!(client.secret_names[1..].iter().all(|n| n == &["password"]));
        let (_, _, ui) = run(vec![no_profiles(), (add_words("key", ACCEPT), failed.clone()), (add_words("key", ACCEPT), added(false))],
            &["", "192.0.2.1", "", "", "1", "tag", "maybe", "Y"], add_node);
        assert!(noticed(&ui, "Введите y или n."));
        for no in ["n", "N"] { run(vec![no_profiles(), (add_words("key", ACCEPT), failed.clone())], &["", "192.0.2.1", "", "", "1", "tag", no], add_node); }
    }
    #[test]
    fn add_onboarding_failure_retries_or_defers_without_host_key_flags() {
        let failed = err("onboarding_failed", json!({"name": "vps-1", "cause": "x"}));
        let (_, _, ui) = run(vec![no_profiles(), (add_words("key", ACCEPT), failed.clone()), (add_words("key", &["--defer-ssh-setup"]), added(true))],
            &["", "192.0.2.1", "", "", "1", "tag", "2"], add_node);
        assert!(noticed(&ui, "требует SSH-настройки"));
        run(vec![no_profiles(), (add_words("key", ACCEPT), failed.clone()), (add_words("key", ACCEPT), added(false))], &["", "192.0.2.1", "", "", "1", "tag", "1"], add_node);
        run(vec![no_profiles(), (add_words("key", ACCEPT), failed)], &["", "192.0.2.1", "", "", "1", "tag", "0"], add_node);
    }

    // ─── Карточка ────────────────────────────────────────────────────────────

    #[test]
    fn card_keys_map_both_cases_to_v2_commands() {
        for key in ["k", "y", "r", "e", "w", "l", "d"] {
            for key in [key.to_owned(), key.to_ascii_uppercase()] {
                let mut inputs = vec![key.as_str()];
                let mut steps = vec![show()];
                let mut next = "n";
                match key.to_ascii_lowercase().as_str() {
                    "k" => steps.push(step(&["node", "check", "--name", "n"], ok(json!({"name": "n", "reachable": true})))),
                    "y" => {
                        let words = argv(&["node", "apply", "--name", "n"]);
                        inputs.push("y");
                        steps.extend([(words.clone(), plan("confirmation_required", "ap")), (with_yes(&words, "ap"), ok(json!({"applied": [], "failed": [], "unchanged": ["n"]})))]);
                    }
                    "r" => { inputs.push("renamed"); next = "renamed"; steps.push(step(&["node", "rename", "--name", "n", "--new-name", "renamed"], ok(json!({"name": "renamed"})))); }
                    "e" => { inputs.push(""); steps.push(step(&["node", "tag", "--name", "n", "--tag", ""], ok(json!({"name": "n", "tag": ""})))); }
                    "w" => { inputs.push("private"); steps.push(step(&["node", "password", "--name", "n"], ok(json!({"name": "n"})))); }
                    "l" => {
                        inputs.extend(["new", "", "-"]);
                        steps.push(step(&["node", "aliases", "--name", "n"], ok(json!([{"proxy": "p1", "alias": "old"}, {"proxy": "p2", "alias": null}, {"proxy": "p3", "alias": "gone"}]))));
                        steps.push(step(&["node", "aliases", "--name", "n", "--set", "p1=new", "--unset", "p3"], ok(json!({"name": "n", "aliases": {"p1": "new"}}))));
                    }
                    "d" => {
                        let words = argv(&["node", "delete", "--name", "n", "--scope", "server", "--revoke-key"]);
                        inputs.extend(["3", "y"]);
                        steps.extend([(words.clone(), plan("confirmation_required", "del")), (with_yes(&words, "del"), ok(json!({"name": "n", "scope": "server"})))]);
                    }
                    _ => unreachable!(),
                }
                if !key.eq_ignore_ascii_case("d") { inputs.push("0"); steps.push(step(&["node", "show", "--name", next], ok(node()))); }
                let (client, ui) = screen(&mut NodeCard("n".into()), &inputs, steps);
                if key.eq_ignore_ascii_case("w") { assert_eq!(client.secret_names[1], ["password"]); }
                assert!(!client.calls.iter().flatten().any(|s| s == "private"));
                assert!(ui.notices.iter().all(|l| l.to_string().starts_with("Без изменений")), "{key}: {:?}", ui.notices);
            }
        }
    }
    #[test]
    fn card_context_password_key_delete_options_and_refusals() {
        let mut key_node = node();
        key_node["auth"] = json!("key");
        key_node["password"] = Value::Null;
        key_node["groups"] = json!([]);
        key_node["delete_options"] = json!([]);
        key_node["issues"] = json!(["missing_host_key"]);
        let (_, ui) = screen(&mut NodeCard("n".into()), &["w", "d", "r", "", "0"], vec![
            step(&["node", "show", "--name", "n"], ok(key_node.clone())), step(&["node", "show", "--name", "n"], ok(key_node.clone())),
            step(&["node", "show", "--name", "n"], ok(key_node.clone())), step(&["node", "show", "--name", "n"], ok(key_node)),
        ]);
        let card = &ui.views[0];
        assert!(!card.sections.iter().flatten().any(|i| i.key == "w"));
        assert!(card.context.iter().any(|l| l.to_string() == "Группы: нет"));
        assert!(card.context.iter().any(|l| l.to_string().contains("missing_host_key") && l.style.fg == Some(ui::YELLOW)));
        assert!(noticed(&ui, "Неверный выбор.") && noticed(&ui, "Нет доступных вариантов удаления."));
        assert_eq!(ui.notices.len(), 2);
        let mut missing = node();
        missing["password"] = json!("missing");
        let (_, ui) = screen(&mut NodeCard("n".into()), &["0"], vec![step(&["node", "show", "--name", "n"], ok(missing))]);
        assert!(ui.views[0].context.iter().any(|l| l.to_string() == "Пароль SSH: нет" && l.style.fg == Some(ui::YELLOW)));
        let mut unread = node();
        unread["password"] = json!("error");
        let (_, ui) = screen(&mut NodeCard("n".into()), &["0"], vec![step(&["node", "show", "--name", "n"], ok(unread))]);
        assert!(ui.views[0].context.iter().any(|l| l.to_string() == "Пароль SSH: не удалось прочитать" && l.style.fg == Some(ui::RED)));
        for no in ["", "N", "n", "0"] {
            let (_, ui) = screen(&mut NodeCard("n".into()), &["y", no, "0"], vec![
                show(), step(&["node", "apply", "--name", "n"], plan("confirmation_required", "one")), show(),
            ]);
            assert_eq!(confirms(&ui), 1);
        }
        let (_, ui) = screen(&mut NodeCard("n".into()), &["d", "1", "", "0"], vec![
            show(), step(&["node", "delete", "--name", "n", "--scope", "local"], plan("confirmation_required", "one")), show(),
        ]);
        assert_eq!(confirms(&ui), 1);
        let card = &ui.views[0];
        let colors: Vec<_> = card.sections.iter().flatten().map(|i| (i.key.as_str(), i.color)).collect();
        assert!(colors.contains(&("d", ui::RED)) && colors.contains(&("o", ui::CYAN)) && colors.contains(&("y", ui::GREEN)) && colors.contains(&("0", ui::NC)));
        assert!(!colors.iter().any(|(key, _)| *key == "u"), "no forced script upload");
    }

    // ─── Усиление SSH ────────────────────────────────────────────────────────

    #[test]
    fn harden_confirms_the_plan_of_the_chosen_port() {
        let auto = argv(&["node", "harden", "--name", "n"]);
        let (_, _, ui) = run(vec![(auto.clone(), plan("confirmation_required", "one")), (with_yes(&auto, "one"), ok(json!({"name": "n", "port": 50000, "auth": "key"})))],
            &["", "y"], |ctx| harden(ctx, "n"));
        assert_eq!(confirms(&ui), 1);
        let (_, _, ui) = run(vec![
            step(&["node", "harden", "--name", "n", "--port", "2222"], err("port_in_use", json!({"port": 2222}))),
            step(&["node", "harden", "--name", "n", "--port", "abc"], Reply::failure("invalid")),
            (auto.clone(), plan("confirmation_required", "one")),
        ], &["2222", "abc", "", "n"], |ctx| harden(ctx, "n"));
        assert_eq!(confirms(&ui), 1);
        // The port taken between the plan and the confirmed run: asked again.
        let chosen = argv(&["node", "harden", "--name", "n", "--port", "2222"]);
        let (_, _, ui) = run(vec![
            (chosen.clone(), plan("confirmation_required", "one")), (with_yes(&chosen, "one"), err("port_in_use", json!({"port": 2222}))),
            (auto.clone(), plan("confirmation_required", "two")),
        ], &["2222", "y", "", "n"], |ctx| harden(ctx, "n"));
        assert_eq!(confirms(&ui), 2);
        assert!(ui.notices.is_empty(), "{:?}", ui.notices);
        // Without an explicit port, `invalid` is the core's verdict, not a port question.
        let (_, _, ui) = run(vec![(auto.clone(), Reply::failure("invalid"))], &[""], |ctx| harden(ctx, "n"));
        assert_eq!(ui.notices.len(), 1);
        run(none(), &[], |ctx| harden(ctx, "n"));
    }
    #[test]
    fn harden_replans_at_most_twice_and_warns_about_the_console() {
        let auto = argv(&["node", "harden", "--name", "n"]);
        let (_, _, ui) = run(vec![
            (auto.clone(), plan("confirmation_required", "one")), (with_yes(&auto, "one"), plan("plan_changed", "two")),
            (with_yes(&auto, "two"), plan("plan_changed", "three")), (with_yes(&auto, "three"), plan("plan_changed", "four")),
        ], &["", "y", "Y", "y"], |ctx| harden(ctx, "n"));
        assert_eq!(confirms(&ui), 3);
        assert!(noticed(&ui, "План продолжает меняться"));
        let (_, client, ui) = run(vec![
            (auto.clone(), err("missing_secret", json!({"name": "n", "secret": "password"}))), step(&["node", "password", "--name", "n"], ok(json!({"name": "n"}))),
            (auto.clone(), plan("confirmation_required", "one")),
            (with_yes(&auto, "one"), err("hardening_failed", json!({"stage": "verify", "rolled_back": false, "console_required": true}))),
        ], &["", "y", "pw", "y"], |ctx| harden(ctx, "n"));
        assert_eq!(client.secret_names[1], ["password"]);
        assert!(noticed(&ui, "консоль провайдера"));
    }
    #[test]
    fn card_routes_harden_awg_and_connections_both_cases() {
        for key in ["h", "H", "a", "A", "p", "P"] {
            let mut steps = vec![show()];
            let mut inputs = vec![key];
            match key.to_ascii_lowercase().as_str() {
                "h" => { inputs.push(""); steps.push(step(&["node", "harden", "--name", "n"], ok(json!({"name": "n", "port": 50000, "auth": "key"})))); }
                "a" => { inputs.push("0"); steps.push(step(&["awg", "status", "--name", "n"], ok(json!({"installed": false, "peers": []})))); }
                _ => {
                    inputs.push("0");
                    steps.push(step(&["conn", "sync", "--name", "n"], ok(json!({"nodes": [{"name": "n", "status": "synced", "discovered": []}]}))));
                    steps.push(step(&["conn", "list", "--name", "n"], ok(json!([{"node": "n", "groups": []}]))));
                }
            }
            steps.push(show());
            inputs.push("0");
            screen(&mut NodeCard("n".into()), &inputs, steps);
        }
    }

    // ─── Коды нод, SSH-настройка ─────────────────────────────────────────────

    #[test]
    fn node_codes_store_password_trust_key_and_only_warn_on_needs_setup() {
        let check = argv(&["node", "check", "--name", "n"]);
        let trust = argv(&["node", "trust-host-key", "--name", "n", "--host-key", "SHA256:new"]);
        let (reply, client, ui) = run(vec![
            (check.clone(), err("missing_secret", json!({"name": "n", "secret": "password"}))), step(&["node", "password", "--name", "n"], ok(json!({"name": "n"}))),
            (check.clone(), err("host_key_changed", json!({"host": "192.0.2.1", "port": 22, "fingerprints": ["SHA256:new"], "name": "n"}))),
            (trust.clone(), plan("confirmation_required", "trust")), (with_yes(&trust, "trust"), ok(json!({"name": "n", "fingerprint": "SHA256:new"}))),
            (check.clone(), err("needs_setup", json!({"name": "n"}))),
        ], &["y", "never-render", "y"], |ctx| node_request(ctx, "n", &check, None));
        assert!(!reply.ok);
        assert_eq!(client.secret_names[1], ["password"]);
        assert!(!client.calls.iter().flatten().any(|s| s == "never-render"));
        assert!(!ui.views.iter().flat_map(View::lines).any(|l| l.to_string().contains("never-render")));
        assert!(noticed(&ui, "раздел n → h"));
    }
    #[test]
    fn node_code_refusals_never_retry() {
        for inputs in [&[""][..], &["y", ""][..], &["y"][..]] {
            let (resolved, _, _) = run(none(), inputs, |ctx| handle_node_codes(ctx, &Reply::failure("missing_secret"), "n"));
            assert!(!resolved);
        }
        let (resolved, _, _) = run(none(), &[], |ctx| handle_node_codes(ctx, &Reply::failure("host_key_changed"), "n"));
        assert!(!resolved);
        let trust = argv(&["node", "trust-host-key", "--name", "n", "--host-key", "SHA256:new"]);
        let changed = err("host_key_changed", json!({"fingerprints": ["SHA256:new"]}));
        let (resolved, _, _) = run(vec![(trust, plan("confirmation_required", "t"))], &["n"], |ctx| handle_node_codes(ctx, &changed, "n"));
        assert!(!resolved);
    }
    #[test]
    fn setup_ssh_decides_provisioning_defers_failures_and_reports() {
        let setup = |extra: &[&str]| { let mut w = argv(&["node", "setup-ssh"]); w.extend(argv(extra)); w };
        let yes = setup(&["--provision-keys", "yes"]);
        let (_, _, ui) = run(vec![
            (setup(&[]), err("key_provisioning_required", json!({"nodes": ["a", "b"]}))), (yes.clone(), plan("confirmation_required", "s")),
            (with_yes(&yes, "s"), ok(json!({"ready": true, "installed": ["a"], "deferred": [], "pending": false}))),
        ], &["Y", "y"], setup_ssh);
        assert!(ui.views[0].context.iter().any(|l| l.to_string() == "Ноды: a, b"));
        assert!(noticed(&ui, "SSH-настройка завершена."));
        let no = setup(&["--provision-keys", "no"]);
        let deferred = setup(&["--provision-keys", "no", "--on-failure", "defer"]);
        let (_, _, ui) = run(vec![
            (setup(&[]), err("key_provisioning_required", json!({"nodes": ["a"]}))), (no.clone(), plan("confirmation_required", "s1")),
            (with_yes(&no, "s1"), err("onboarding_failed", json!({"node": "b", "step": "pin", "rolled_back": true}))),
            (deferred.clone(), plan("confirmation_required", "s2")),
            (with_yes(&deferred, "s2"), ok(json!({"ready": false, "installed": [], "deferred": [{"name": "b", "issue": "missing_host_key"}], "pending": true}))),
        ], &["", "y", "2", "y"], setup_ssh);
        assert!(noticed(&ui, "Отложено: b — missing_host_key"));
        let (_, _, ui) = run(vec![(setup(&[]), Reply::failure("nothing_pending"))], &[], setup_ssh);
        assert!(ui.notices.is_empty());
        for key in ["h", "H"] {
            let mut steps = vec![step(&["node", "list"], ok(json!([]))), step(&["status"], ok(json!({"ssh_setup_pending": true})))];
            steps.push(step(&["node", "setup-ssh"], Reply::failure("nothing_pending")));
            steps.extend(listing());
            screen(&mut Nodes, &[key, "0"], steps);
            let mut steps = listing();
            steps.extend(listing());
            let (_, ui) = screen(&mut Nodes, &[key, "0"], steps);
            assert!(noticed(&ui, "Неверный выбор."));
        }
    }
    #[test]
    fn aliases_report_no_changes_and_empty_lists_without_writes() {
        let list = step(&["node", "aliases", "--name", "n"], ok(json!([{"proxy": "p1", "alias": "old"}, {"proxy": "p2", "alias": null}])));
        let (_, _, ui) = run(vec![list.clone()], &["old", "-"], |ctx| aliases(ctx, "n"));
        assert!(noticed(&ui, "Изменений нет."));
        run(vec![list.clone()], &["new"], |ctx| aliases(ctx, "n"));
        let (_, _, ui) = run(vec![step(&["node", "aliases", "--name", "n"], ok(json!([])))], &[], |ctx| aliases(ctx, "n"));
        assert!(noticed(&ui, "не найдены"));
        run(vec![list, step(&["node", "aliases", "--name", "n", "--set", "p2=Fast"], ok(json!({})))], &["", "Fast"], |ctx| aliases(ctx, "n"));
    }

    // ─── Подключения ─────────────────────────────────────────────────────────

    #[test]
    fn connections_overview_syncs_on_entry_and_s_and_colours_counts() {
        let sync = err("partial", json!({"nodes": [
            {"name": "a", "status": "synced", "discovered": ["p1", "p2"], "removed": [], "groups": [], "error": null},
            {"name": "b", "status": "unreachable", "discovered": null, "removed": [], "groups": [], "error": "remote_failed"}]}));
        let list = ok(json!([
            {"node": "a", "groups": [{"name": "PC", "proxies": ["p1"]}, {"name": "ALL", "proxies": ["p1", "p2"]}]},
            {"node": "b", "groups": [{"name": "PC", "proxies": ["x"]}]}, {"node": "c", "groups": [{"name": "X", "proxies": ["p"]}]}]));
        let (_, ui) = screen(&mut Connections, &["z", "1", "0", "0"], vec![
            step(&["conn", "sync"], sync), step(&["conn", "list"], list.clone()), step(&["conn", "list"], list.clone()),
            step(&["conn", "sync", "--name", "a"], ok(json!({"nodes": [{"name": "a", "status": "synced", "discovered": ["p1", "p2"]}]}))),
            step(&["conn", "list", "--name", "a"], ok(json!([{"node": "a", "groups": []}]))), step(&["conn", "list"], list),
        ]);
        assert_eq!(colors(&ui.views[0]), [Some(ui::NC), Some(ui::YELLOW), Some(ui::GREEN), Some(ui::YELLOW), Some(ui::NC), Some(ui::DIM)]);
        assert!(ui.views[0].context[3].to_string().contains("недоступна"));
        assert_eq!(ui.views[0].sections.len(), 2);
        assert_eq!(ui.notices.len(), 1);
        for key in ["s", "S"] {
            screen(&mut Connections, &[key, "0"], vec![
                step(&["conn", "sync"], ok(json!({"nodes": []}))), step(&["conn", "list"], ok(json!([]))),
                step(&["conn", "sync"], ok(json!({"nodes": []}))), step(&["conn", "list"], ok(json!([]))),
            ]);
        }
        // A failed sync is reported; the saved assignments are still shown.
        let (_, ui) = screen(&mut Connections, &["0"], vec![step(&["conn", "sync"], Reply::failure("locked")),
            step(&["conn", "list"], ok(json!([{"node": "a", "groups": [{"name": "G", "proxies": ["p"]}]}])))]);
        assert_eq!(ui.notices.len(), 1);
        assert!(ui.views[0].context.iter().any(|l| l.to_string().contains("не проверены")), "{:?}", ui.views[0].context);
        assert!(ui.views[0].context.iter().any(|l| l.to_string() == "  G: 1/?"));
    }
    fn node_sync(discovered: Value) -> (Vec<String>, Reply) {
        step(&["conn", "sync", "--name", "n"], ok(json!({"nodes": [{"name": "n", "status": "synced", "discovered": discovered}]})))
    }
    fn node_list() -> (Vec<String>, Reply) { step(&["conn", "list", "--name", "n"], ok(json!([{"node": "n", "groups": [{"name": "old", "proxies": ["p1"]}]}]))) }
    #[test]
    fn connection_assignment_edits_per_proxy_and_sends_only_changed_groups() {
        let groups = || step(&["group", "list"], ok(json!([{"name": "old"}, {"name": "g2"}])));
        for key in ["b", "B"] {
            // p2 → g2; p1: off old, on g2. One command with both changed groups.
            let (_, _, ui) = run(vec![
                node_sync(json!(["p1", "p2"])), node_list(), groups(),
                step(&["conn", "set", "--name", "n", "--assign", "old=", "--assign", "g2=p2", "--assign", "g2=p1"], ok(json!({"node": "n", "changed": []}))), nothing_pending(), node_list(),
            ], &[key, "2", "2", "", "1", "1", "2", "", "s", "0"], |ctx| connection_node(ctx, "n"));
            assert!(ui.views[0].context.iter().any(|l| l.to_string() == "p1  [old]"));
            assert_eq!(ui.views[1].sections[0][0].label, "p1  [old]");
            assert!(ui.views[4].context.iter().any(|l| l.style.fg == Some(ui::YELLOW)), "unsaved edits are marked");
            assert!(ui.views[5].sections[0][0].label.starts_with("[x]") && ui.views[5].sections[0][1].label.starts_with("[ ]"));
            assert_eq!(ui.views[8].sections[0][0].label, "p1  [g2]");
        }
        // A cancelled form sends nothing; an unchanged one says so and sends nothing.
        run(vec![node_sync(json!(["p1", "p2"])), node_list(), groups(), node_list()], &["b", "1", "2", "", "0", "0"], |ctx| connection_node(ctx, "n"));
        let (_, _, ui) = run(vec![node_sync(json!(["p1"])), node_list(), groups(), node_list()],
            &["b", "1", "2", "", "1", "2", "", "s", "0"], |ctx| connection_node(ctx, "n"));
        assert!(noticed(&ui, "Изменений нет."));
        // Unreachable node: nothing discovered, an assigned proxy can still be removed.
        let unreachable = || step(&["conn", "sync", "--name", "n"], err("partial", json!({"nodes": [{"name": "n", "status": "unreachable", "error": "remote_failed"}]})));
        let (_, _, ui) = run(vec![unreachable(), node_list(), groups(),
            step(&["conn", "set", "--name", "n", "--assign", "old="], ok(json!({"node": "n", "changed": []}))), nothing_pending(), node_list()],
            &["b", "1", "1", "", "s", "0"], |ctx| connection_node(ctx, "n"));
        // (not read is not «not found»)
        assert!(ui.views[0].context.iter().any(|l| l.to_string() == "p1  [old]"), "{:?}", ui.views[0].context);
        assert_eq!(ui.views[1].sections[0][0].label, "p1  [old]");
        // A failed save keeps the editor and the edits: «s» again retries them.
        let set = || argv(&["conn", "set", "--name", "n", "--assign", "old="]);
        let (_, _, ui) = run(vec![unreachable(), node_list(), groups(), (set(), Reply::failure("locked")),
            (set(), ok(json!({"node": "n", "changed": []}))), nothing_pending(), node_list()],
            &["b", "1", "1", "", "s", "s", "0"], |ctx| connection_node(ctx, "n"));
        assert_eq!(ui.views[4].sections[0][0].label, "p1  []", "{:?}", ui.views[4]);
        // No proxies at all: nothing to edit.
        let empty = step(&["conn", "list", "--name", "n"], ok(json!([{"node": "n", "groups": []}])));
        let (_, _, ui) = run(vec![node_sync(json!([])), empty.clone(), groups(), empty], &["b", "0"], |ctx| connection_node(ctx, "n"));
        assert!(noticed(&ui, "Нет подключений для назначения: синхронизируйте ноду."));
    }
    #[test]
    fn connection_assignment_merges_entries_of_a_group_and_keeps_commas() {
        // The group sits in two entries of the node: both proxies are
        // preselected, adding p3 keeps them; a name with a comma is one value.
        let split = step(&["conn", "list", "--name", "n"], ok(json!([{"node": "n", "groups": [
            {"name": "old", "proxies": ["p1"]}, {"name": "old", "proxies": ["a,b"]}]}])));
        let (_, _, ui) = run(vec![
            node_sync(json!(["p1", "p3"])), split.clone(), step(&["group", "list"], ok(json!([{"name": "old"}]))),
            step(&["conn", "set", "--name", "n", "--assign", "old=p1", "--assign", "old=a,b", "--assign", "old=p3"], ok(json!({"node": "n", "changed": []}))), nothing_pending(), split,
        ], &["b", "2", "1", "", "s", "0"], |ctx| connection_node(ctx, "n"));
        assert_eq!(ui.views[1].sections[0][2].label, "a,b (не найдено на ноде)  [old]");
        assert!(ui.views[0].context.iter().any(|l| l.to_string() == "a,b (не найдено на ноде)  [old]"));
    }
    #[test]
    fn connection_node_sync_and_alias_hotkeys_both_cases() {
        for key in ["s", "S", "l", "L"] {
            let mut steps = vec![node_sync(json!([])), node_list()];
            if key.eq_ignore_ascii_case("s") { steps.push(node_sync(json!([]))); } else { steps.push(step(&["node", "aliases", "--name", "n"], ok(json!([])))); }
            steps.push(node_list());
            run(steps, &[key, "0"], |ctx| connection_node(ctx, "n"));
        }
        let (_, _, ui) = run(vec![step(&["conn", "sync", "--name", "n"], Reply::failure("not_found"))], &[], |ctx| connection_node(ctx, "n"));
        assert!(ui.views.is_empty() && ui.notices.is_empty());
        // A failed sync is reported; the saved assignments stay, unchecked.
        let (_, _, ui) = run(vec![step(&["conn", "sync", "--name", "n"], Reply::failure("locked")), node_list()], &["0"], |ctx| connection_node(ctx, "n"));
        assert_eq!(ui.notices.len(), 1);
        let shown: Vec<String> = ui.views[0].context.iter().map(|l| l.to_string()).collect();
        assert!(shown.iter().any(|l| l == "Подключения ноды не проверены") && shown.iter().any(|l| l == "p1  [old]"), "{shown:?}");
    }
    #[test]
    fn partial_node_sync_stays_and_resolves_node_codes_through_check() {
        let row = |status: &str, error: &str| err("partial", json!({"nodes": [{"name": "n", "status": status, "discovered": null, "error": error}]}));
        let sync = argv(&["conn", "sync", "--name", "n"]);
        let (_, _, ui) = run(vec![(sync.clone(), row("unreachable", "remote_failed")), node_list()], &["0"], |ctx| connection_node(ctx, "n"));
        assert_eq!(ui.views[0].context[0].style.fg, Some(ui::YELLOW));
        assert_eq!(ui.notices.len(), 1);
        let check = argv(&["node", "check", "--name", "n"]);
        let (_, client, _) = run(vec![
            (sync.clone(), row("load_failed", "missing_secret")), (check.clone(), err("missing_secret", json!({"name": "n"}))),
            step(&["node", "password", "--name", "n"], ok(json!({"name": "n"}))), (check.clone(), ok(json!({"name": "n", "reachable": true}))),
            node_sync(json!(["p1"])), node_list(),
        ], &["y", "pw", "0"], |ctx| connection_node(ctx, "n"));
        assert_eq!(client.secret_names[2], ["password"]);
        // A refused resolution is not retried; the screen stays with the node's state.
        run(vec![(sync, row("load_failed", "missing_secret")), (check, err("missing_secret", json!({"name": "n"}))), node_list()],
            &["", "0"], |ctx| connection_node(ctx, "n"));
    }

    // ─── AmneziaWG ───────────────────────────────────────────────────────────

    fn awg() -> Value { json!({"installed": true, "peers": [{"name": "used", "status": "used"}, {"name": "orphan", "status": "orphan"}, {"name": "missing", "status": "missing"}]}) }
    #[test]
    fn awg_keys_both_cases_and_peer_colours() {
        for key in ["c", "C", "d", "D", "x", "X", "r", "R"] {
            let status = || step(&["awg", "status", "--name", "n"], ok(awg()));
            let mut inputs = vec![key];
            let mut steps = vec![status()];
            match key.to_ascii_lowercase().as_str() {
                "c" => steps.push(step(&["awg", "sync", "--name", "n"], ok(json!({"created": ["missing"]})))),
                "d" => {
                    let words = argv(&["awg", "remove", "--name", "n", "--peer", "orphan"]);
                    inputs.extend(["2", "y"]);
                    steps.extend([(words.clone(), plan("confirmation_required", "p")), (with_yes(&words, "p"), ok(json!({"removed": ["orphan"]})))]);
                }
                "x" => {
                    let words = argv(&["awg", "remove", "--name", "n", "--orphans"]);
                    inputs.push("y");
                    steps.extend([(words.clone(), plan("confirmation_required", "o")), (with_yes(&words, "o"), ok(json!({"removed": ["orphan"]})))]);
                }
                _ => {}
            }
            steps.push(status());
            inputs.push("0");
            let (_, _, ui) = run(steps, &inputs, |ctx| awg_node(ctx, "n"));
            assert_eq!(colors(&ui.views[0]), [Some(ui::GREEN), Some(ui::YELLOW), Some(ui::DIM)]);
            if key.eq_ignore_ascii_case("d") { assert_eq!(ui.views[1].sections[0].len(), 3); }
        }
    }
    #[test]
    fn awg_not_installed_hides_management_and_node_codes_do_not_retry() {
        let absent = || step(&["awg", "status", "--name", "n"], ok(json!({"installed": false, "peers": []})));
        let (_, _, ui) = run(vec![absent(), absent(), absent(), absent()], &["c", "d", "x", "0"], |ctx| awg_node(ctx, "n"));
        assert_eq!(ui.notices.len(), 3);
        assert_eq!(ui.views[0].sections[0].iter().map(|i| i.key.as_str()).collect::<Vec<_>>(), ["r", "0"]);
        assert_eq!(colors(&ui.views[0]), [Some(ui::DIM)]);
        let (_, _, ui) = run(vec![step(&["awg", "status", "--name", "n"], Reply::failure("needs_setup"))], &[], |ctx| awg_node(ctx, "n"));
        assert!(noticed(&ui, "раздел n → h"));
        screen(&mut AmneziaWg, &["2", "0", "0"], vec![
            step(&["node", "list"], ok(json!([{"name": "n1", "ip": "192.0.2.1", "port": 22}, {"name": "n2", "ip": "192.0.2.2", "port": 22}]))),
            step(&["awg", "status", "--name", "n2"], ok(json!({"installed": false, "peers": []}))), step(&["node", "list"], ok(json!([]))),
        ]);
    }

    // ─── Telegram ────────────────────────────────────────────────────────────

    fn three_nodes() -> (Vec<String>, Reply) {
        step(&["node", "list"], ok(json!([{"name": "n1", "ip": "192.0.2.1", "port": 22}, {"name": "n2", "ip": "192.0.2.2", "port": 22}, {"name": "n3", "ip": "192.0.2.3", "port": 22}])))
    }
    #[test]
    fn telegram_batches_send_one_name_per_selected_node_through_the_plan() {
        for (key, verb) in [("i", "install"), ("p", "refresh-ip"), ("w", "web-update"), ("r", "web-restart"), ("b", "backend-restart"), ("x", "remove-all")] {
            for key in [key.to_owned(), key.to_ascii_uppercase()] {
                let words = argv(&["telegram", verb, "--name", "n1", "--name", "n3"]);
                let results = json!({"results": [{"node": "n1", "code": 0, "status": "ok", "reason": null}, {"node": "n3", "code": 0, "status": "ok", "reason": null}]});
                let (_, ui) = screen(&mut Telegram, &[&key, "1", "3", "", "y", "", "0"], vec![
                    three_nodes(), (words.clone(), plan("confirmation_required", "tg")), (with_yes(&words, "tg"), ok(results)),
                ]);
                assert!(ui.views[1].sections[0].iter().take(3).all(|i| i.label.starts_with("[ ]")));
                assert_eq!(confirms(&ui), 1);
                assert!(ui.views.iter().any(|v| v.title == "Результат Telegram Proxy"));
            }
        }
        for key in ["d", "D"] {
            for (choice, component) in [("1", "web"), ("2", "mtproto")] {
                let words = argv(&["telegram", "remove", "--component", component, "--name", "n2"]);
                screen(&mut Telegram, &[key, choice, "2", "", "y", "0"], vec![
                    three_nodes(), (words.clone(), plan("confirmation_required", "rm")), (with_yes(&words, "rm"), ok(json!({"results": []}))),
                ]);
            }
        }
        let (_, ui) = screen(&mut Telegram, &["i", "", "0"], vec![three_nodes()]);
        assert!(noticed(&ui, "Ничего не выбрано."));
        screen(&mut Telegram, &["i", "1", "0", "0"], vec![three_nodes()]);
        screen(&mut Telegram, &["d", "0", "0"], none());
        let words = argv(&["telegram", "install", "--name", "n1"]);
        let (_, ui) = screen(&mut Telegram, &["i", "1", "", "n", "0"], vec![three_nodes(), (words.clone(), plan("confirmation_required", "tg"))]);
        assert!(ui.notices.is_empty());
        // A failed command (no results) reopens the toggle with the nodes kept.
        let (_, ui) = screen(&mut Telegram, &["i", "1", "", "y", "0", "0"], vec![
            three_nodes(), (words.clone(), plan("confirmation_required", "tg")), (with_yes(&words, "tg"), Reply::failure("locked")),
        ]);
        // (toggle frames and the plan review share the title; the last one is the reopened toggle)
        let reopened = ui.views.iter().rev().find(|v| v.title == ui.views[1].title).unwrap();
        assert!(reopened.sections[0][0].label.starts_with("[x]") && reopened.sections[0][1].label.starts_with("[ ]"), "{reopened:?}");
        assert_eq!(ui.notices.len(), 1, "the failure is reported once");
    }
    #[test]
    fn telegram_results_table_labels_and_colours_every_row() {
        for key in ["s", "S"] {
            let results = json!({"results": [
                {"node": "a", "code": 0, "status": "ok", "reason": null}, {"node": "b", "code": 3, "status": "not_installed", "reason": "не установлен"},
                {"node": "c", "code": 4, "status": "partial", "reason": "x"}, {"node": "d", "code": 1, "status": "error", "reason": "offline"}]});
            let (_, ui) = screen(&mut Telegram, &[key, "x", "", "0"], vec![step(&["telegram", "status", "--all"], err("partial", results))]);
            // The table waits for Enter: an unknown key keeps it on screen.
            let tables: Vec<&View> = ui.views.iter().filter(|v| v.title == "Результат Telegram Proxy").collect();
            assert_eq!(tables.len(), 2);
            assert_eq!(ui.views.last().unwrap().title, "Telegram Proxy");
            let table = tables[0];
            assert_eq!(colors(table), [Some(ui::GREEN), Some(ui::YELLOW), Some(ui::YELLOW), Some(ui::RED)]);
            let lines: Vec<String> = table.context.iter().map(|l| l.to_string()).collect();
            assert_eq!(lines, ["a  готово  ", "b  не установлено  не установлен", "c  частично  x", "d  ошибка  offline"]);
            assert!(table.sections.is_empty() && !table.prompt.is_empty());
            assert_eq!(ui.notices.len(), 1, "only the invalid key");
        }
        let (_, ui) = screen(&mut Telegram, &["s", "0"], vec![step(&["telegram", "status", "--all"], Reply::failure("invalid"))]);
        assert_eq!(ui.notices.len(), 1);
    }

    // ─── Терминальные команды ────────────────────────────────────────────────

    /// `node shell` / `telegram menu` are terminal requests, never plain sends.
    fn term(words: &[String], reply: Reply) -> Step { Step::terminal(words.to_vec(), reply) }
    /// An empty script: no request is expected.
    fn none() -> Vec<Step> { Vec::new() }
    #[test]
    fn terminal_commands_run_suspended_as_terminal_requests_both_cases() {
        for key in ["o", "O", "t", "T"] {
            let words = if key.eq_ignore_ascii_case("t") { argv(&["telegram", "menu", "--name", "n"]) } else { argv(&["node", "shell", "--name", "n"]) };
            let (_, ui) = screen(&mut NodeCard("n".into()), &[key, "0"], vec![show().into(), term(&words, ok(json!({}))), show().into()]);
            assert_eq!(ui.suspensions, 1);
            assert!(!ui.suspended_now);
        }
        for key in ["o", "O"] {
            let (_, ui) = screen(&mut Telegram, &[key, "1", "0"], vec![three_nodes().into(), term(&argv(&["telegram", "menu", "--name", "n1"]), ok(json!({})))]);
            assert_eq!(ui.suspensions, 1);
        }
        let shell = argv(&["node", "shell", "--name", "n"]);
        let (_, client, ui) = run(vec![
            term(&shell, err("missing_secret", json!({"name": "n", "secret": "password"}))),
            step(&["node", "password", "--name", "n"], ok(json!({"name": "n"}))).into(), term(&shell, ok(json!({}))),
        ], &["y", "pw"], |ctx| interactive(ctx, "n", false));
        assert_eq!(ui.suspensions, 2);
        assert_eq!(client.secret_names[1], ["password"]);
        let (_, ui) = screen(&mut Telegram, &["o", "0"], vec![step(&["node", "list"], ok(json!([])))]);
        assert!(ui.views.iter().any(|v| v.context.iter().any(|l| l.style.fg == Some(ui::DIM))));
    }

    // ─── Профили, применение ─────────────────────────────────────────────────

    fn edge() -> Value {
        json!({"name": "edge", "reality_mode": "self-steal", "sni_domain": null, "site_source": "random", "vless_tcp": true,
            "vless_xhttp": {"topology": "nginx", "port": null}, "vless_grpc": {"port": 20000}, "hysteria2": {"port": 30000, "obfs": true},
            "amneziawg": null, "warp": false, "warp_plus": false, "ipv6": "default", "mihomo_version": "v1.19.18",
            "acme_email": "a@example.com", "nodes": ["n"]})
    }
    #[test]
    fn profile_wizard_builds_the_add_argv_in_plan_order() {
        // Self-Steal, random site, + xHTTP (nginx), gRPC (port after an invalid one), Hysteria2 (random port, obfs).
        let (form, _, ui) = run(none(), &["edge", "1", "1", "2", "3", "4", "", "2", "70000", "20000", "", "1", "1", "", ""],
            |ctx| profile_wizard(ctx, None));
        assert_eq!(profile_add_argv(&form.unwrap()), argv(&["profile", "add", "--name", "edge", "--reality", "self-steal", "--site-source", "random",
            "--vless-tcp", "on", "--xhttp", "nginx", "--grpc", "on", "--grpc-port", "20000", "--hysteria2", "on", "--hysteria2-obfs", "on",
            "--amneziawg", "off", "--warp", "off", "--ipv6", "default", "--random-acme-email"]));
        assert!(noticed(&ui, PORT_INVALID));
        // SNI: the masking domain is checked; email and version are passed.
        let (form, _, ui) = run(none(), &["sni", "2", "bad", "www.example.com", "", "3", "me@example.com", "v1.19.20"], |ctx| profile_wizard(ctx, None));
        assert_eq!(profile_add_argv(&form.unwrap()), argv(&["profile", "add", "--name", "sni", "--reality", "sni", "--sni-domain", "www.example.com",
            "--vless-tcp", "on", "--xhttp", "off", "--grpc", "off", "--hysteria2", "off", "--amneziawg", "off", "--warp", "off", "--ipv6", "disabled",
            "--acme-email", "me@example.com", "--mihomo-version", "v1.19.20"]));
        assert!(noticed(&ui, DOMAIN_INVALID));
        // Cancelled at any question: nothing.
        let (form, _, _) = run(none(), &["edge", "1"], |ctx| profile_wizard(ctx, None));
        assert!(form.is_none());
    }
    #[test]
    fn profile_set_sends_only_changed_flags() {
        let current = ProfileForm::from_profile(&edge());
        assert_eq!(profile_set_argv("edge", &current, &edge()), None);
        let mut changed = current.clone();
        changed.protocols.retain(|p| p != "grpc");
        changed.ipv6 = "enabled".into();
        assert_eq!(profile_set_argv("edge", &changed, &edge()), Some(argv(&["profile", "set", "--name", "edge", "--grpc", "off", "--ipv6", "enabled"])));
        let mut sni = current.clone();
        sni.reality = "sni".into();
        sni.sni_domain = "www.example.com".into();
        assert_eq!(profile_set_argv("edge", &sni, &edge()),
            Some(argv(&["profile", "set", "--name", "edge", "--reality", "sni", "--sni-domain", "www.example.com", "--xhttp", "reality"])));
        // The edit wizard keeps every answer on Enter: no change, no command.
        let (_, ui) = screen(&mut ProfileCard("edge".into()), &["e", "1", "1", "", "2", "", "", "1", "1", "", "", "0"], vec![
            step(&["profile", "show", "--name", "edge"], ok(edge())), step(&["profile", "show", "--name", "edge"], ok(edge())),
        ]);
        assert!(noticed(&ui, "Изменений нет."));
        assert!(needs_domain(&edge()) && !needs_domain(&json!({"reality_mode": "sni", "vless_tcp": true})));
    }
    #[test]
    fn profiles_list_card_apply_and_refused_delete() {
        let list = || step(&["profile", "list"], ok(json!({"profiles": [edge()]})));
        let show = || step(&["profile", "show", "--name", "edge"], ok(edge()));
        let apply = argv(&["node", "apply", "--profile", "edge"]);
        let delete = argv(&["profile", "delete", "--name", "edge"]);
        let (_, ui) = screen(&mut Profiles, &["1", "Y", "y", "d", "", "0", "0"], vec![
            list(), show(), (apply.clone(), plan("confirmation_required", "a")), (with_yes(&apply, "a"), ok(json!({"applied": ["n"], "failed": [], "unchanged": []}))),
            show(), (delete, plan("confirmation_required", "d")), show(), list(),
        ]);
        assert_eq!(ui.views[0].sections[0][0].label, "edge  Self-Steal  TCP xHTTP gRPC HY2  нод: 1");
        assert!(noticed(&ui, "Применено: n"));
        assert_eq!(confirms(&ui), 2);
        assert!(crate::app::registrations().screens.iter().any(|entry| entry.key == 'r'));
    }
    #[test]
    fn domain_required_asks_the_domain_and_repeats_apply() {
        let words = argv(&["node", "apply", "--name", "n"]);
        let (reply, client, ui) = run(vec![
            (words.clone(), err("domain_required", json!({"name": "n"}))),
            step(&["node", "domain", "--name", "n", "--domain", "de.example.com"], ok(json!({"name": "n"}))),
            (words.clone(), plan("confirmation_required", "a")), (with_yes(&words, "a"), ok(json!({"applied": ["n"], "failed": [], "unchanged": []}))),
        ], &["bad", "de.example.com", "y"], |ctx| apply(ctx, &words, "n"));
        assert!(reply.ok);
        assert!(noticed(&ui, DOMAIN_INVALID));
        assert_eq!(client.calls.len(), 4);
        // Cancelling the domain question stops without repeating.
        run(vec![(words.clone(), err("domain_required", json!({"name": "n"})))], &[""], |ctx| apply(ctx, &words, "n"));
    }
    #[test]
    fn bulk_apply_asks_domains_of_failed_nodes_and_repeats_once() {
        let words = argv(&["node", "apply", "--pending"]);
        let entry = json!({"name":"de","stage":"probe","code":"domain_required","message":"Для ноды «de» нужен домен: node domain --name de --domain D."});
        let partial = || err("partial", json!({"message": "Применение завершено с ошибками.", "applied": [], "unchanged": [], "failed": [entry.clone()]}));
        let (reply, client, ui) = run(vec![
            (words.clone(), plan("confirmation_required", "a")), (with_yes(&words, "a"), partial()),
            step(&["node", "domain", "--name", "de", "--domain", "de.example.com"], ok(json!({"name": "de"}))),
            (words.clone(), plan("confirmation_required", "b")), (with_yes(&words, "b"), partial()),
        ], &["y", "de.example.com", "y"], |ctx| apply(ctx, &words, ""));
        // The repeated apply is not followed by another domain question.
        assert_eq!(reply.code(), "partial");
        assert_eq!(client.calls.len(), 5);
        assert_eq!(ui.notices.iter().filter(|l| l.to_string().contains("de: Для ноды «de» нужен домен")).count(), 2);
        // Cancelling the domain question keeps the report without repeating.
        let (_, client, _) = run(vec![(words.clone(), plan("confirmation_required", "a")), (with_yes(&words, "a"), partial())],
            &["y", ""], |ctx| apply(ctx, &words, ""));
        assert_eq!(client.calls.len(), 2);
    }
    #[test]
    fn apply_partial_reports_one_message_per_failed_node() {
        let words = argv(&["node", "apply", "--pending"]);
        let partial = err("partial", json!({"applied": ["a"], "unchanged": [], "failed": [
            {"name":"de","stage":"config","code":"rolled_back","message":"откат на этапе «конфигурация и проверка»"},
            {"name":"de","stage":"probe","code":"port_busy","message":"порт 443 уже занят","port":443},
            {"name":"de","stage":"probe","code":"remote_failed","message":"Не удалось подключиться к «de»."},
            {"name":"de","stage":"probe","code":"unsupported_os","message":"нужна Debian или Ubuntu с systemd"}]}));
        let (_, _, ui) = run(vec![(words.clone(), plan("confirmation_required", "a")), (with_yes(&words, "a"), partial)], &["y"], |ctx| apply(ctx, &words, ""));
        for line in ["Применено: a", "de: откат на этапе «конфигурация и проверка»", "de: порт 443 уже занят",
            "de: Не удалось подключиться к «de».", "de: нужна Debian или Ubuntu с systemd"] {
            assert!(noticed(&ui, line), "{line}");
        }
        // Nothing pending: the core's message only, no report.
        let (_, _, ui) = run(vec![(words.clone(), err("nothing_pending", json!({})))], &[], |ctx| apply(ctx, &words, ""));
        assert!(!noticed(&ui, "Применено"));
    }
    #[test]
    fn node_list_shows_apply_state_and_applies_all_pending() {
        let mut pending = node();
        pending["status"] = json!("pending");
        let words = argv(&["node", "apply", "--pending"]);
        let (_, ui) = screen(&mut Nodes, &["y", "y", "0"], vec![
            step(&["node", "list"], ok(json!([pending]))), step(&["status"], ok(json!({}))),
            (words.clone(), plan("confirmation_required", "a")), (with_yes(&words, "a"), ok(json!({"applied": ["n"], "failed": [], "unchanged": []}))),
            step(&["node", "list"], ok(json!([node()]))), step(&["status"], ok(json!({}))),
        ]);
        let first = &ui.views[0];
        assert_eq!(first.sections[0][0].label, "n  192.0.2.1:22  · ожидает применения");
        assert_eq!(first.sections[0][0].color, ui::YELLOW);
        assert!(first.sections[1].iter().any(|item| item.key == "y"));
        // Nothing pending: no such action.
        assert!(!ui.views.last().unwrap().sections.iter().flatten().any(|item| item.key == "y"));
    }
    #[test]
    fn add_with_a_profile_asks_the_domain_and_applies_the_node() {
        let words = add_words("key", &["--profile", "edge", "--domain", "de.example.com", "--accept-new-host-key"]);
        let apply = argv(&["node", "apply", "--name", "vps-1"]);
        let (_, client, _) = run(vec![
            step(&["profile", "list"], ok(json!({"profiles": [edge()]}))), (words, added(false)),
            (apply.clone(), plan("confirmation_required", "a")), (with_yes(&apply, "a"), ok(json!({"applied": ["vps-1"], "failed": [], "unchanged": []}))),
        ], &["", "192.0.2.1", "", "", "1", "tag", "2", "de.example.com", "y"], add_node);
        assert_eq!(client.calls.len(), 4);
        // «Без профиля»: no domain, no apply.
        run(vec![step(&["profile", "list"], ok(json!({"profiles": [edge()]}))), (add_words("key", ACCEPT), added(false))],
            &["", "192.0.2.1", "", "", "1", "tag", "1"], add_node);
    }
    #[test]
    fn card_profile_domain_and_ports_send_only_changes() {
        let mut with_profile = node();
        with_profile["profile"] = json!("edge");
        with_profile["ports"] = json!({"hysteria2": 31000});
        run(vec![step(&["profile", "list"], ok(json!({"profiles": [edge()]}))), step(&["node", "profile", "--name", "n", "--profile", "edge"], ok(json!({})))],
            &["2"], |ctx| node_profile(ctx, "n", &node()));
        let (_, _, ui) = run(vec![step(&["profile", "list"], ok(json!({"profiles": [edge()]})))], &["2"], |ctx| node_profile(ctx, "n", &with_profile));
        assert!(noticed(&ui, "Изменений нет."));
        run(vec![step(&["node", "domain", "--name", "n", "--domain", "de.example.com"], ok(json!({})))], &["de.example.com"], |ctx| node_domain(ctx, "n", &node()));
        let (_, _, ui) = run(vec![step(&["profile", "show", "--name", "edge"], ok(edge())),
            step(&["node", "port", "--name", "n", "--protocol", "hysteria2", "--port", ""], ok(json!({})))], &["2", ""], |ctx| node_ports(ctx, "n", &with_profile));
        let labels: Vec<&str> = ui.views[0].sections[0].iter().map(|i| i.label.as_str()).collect();
        assert_eq!(&labels[..2], ["VLESS gRPC: 20000 (профиль)", "Hysteria2: 31000 (нода)"]);
        let (_, _, ui) = run(none(), &[], |ctx| node_ports(ctx, "n", &node()));
        assert!(noticed(&ui, "У ноды нет профиля."));
    }

    // ─── Пустые и ошибочные состояния, кадры ─────────────────────────────────

    #[test]
    fn empty_error_invalid_and_disappearing_card_states() {
        let mut steps = listing();
        steps.extend(listing());
        steps.extend(listing());
        let (_, ui) = screen(&mut Nodes, &["", "01", "0"], steps);
        assert_eq!(ui.notices.len(), 2);
        assert_eq!(colors(&ui.views[0]), [Some(ui::DIM)]);
        let (_, ui) = screen(&mut Nodes, &[], vec![step(&["node", "list"], Reply::failure("failed"))]);
        assert_eq!(ui.notices.len(), 1);
        let (_, ui) = screen(&mut NodeCard("n".into()), &[], vec![step(&["node", "show", "--name", "n"], Reply::failure("not_found"))]);
        assert!(ui.notices.is_empty() && ui.views.is_empty());
        screen(&mut AmneziaWg, &["0"], vec![step(&["node", "list"], ok(json!([])))]);
        let (selected, _, ui) = run(none(), &[], |ctx| ctx.toggle("empty", &[], vec![], EMPTY));
        assert_eq!(selected, None);
        assert_eq!(ui.views.len(), 1);
    }
    /// A UI after Ctrl+C: reads end with `None` and `interrupted()` is set.
    struct Interrupted(ScriptedUi);
    impl UserInterface for Interrupted {
        fn input(&mut self, view: &View, hidden: bool) -> io::Result<Option<zeroize::Zeroizing<String>>> { self.0.input(view, hidden) }
        fn show(&mut self, view: &View) -> io::Result<()> { self.0.show(view) }
        fn log(&mut self, log: &Log) { self.0.log(log) }
        fn notice(&mut self, line: ratatui::text::Line<'static>) { self.0.notice(line) }
        fn suspended(&mut self, command: &mut std::process::Command) -> io::Result<std::process::ExitStatus> { self.0.suspended(command) }
        fn interrupted(&self) -> bool { true }
    }
    #[test]
    fn cancelled_rename_or_tag_keeps_the_card_and_ctrl_c_leaves_it() {
        let registry = Registry { screens: vec![], github_wizard: None };
        for key in ["r", "E"] {
            let mut client = ScriptedClient::new(vec![show(), show()]);
            let mut ui = ScriptedUi::new(&[]);
            ui.inputs.extend([Some(key.into()), None, Some("0".into())]);
            let navigation = NodeCard("n".into()).run(&mut Context::for_test(&mut client, &mut ui, &registry)).unwrap();
            assert!(matches!(navigation, Navigation::Back));
            client.assert_finished();
            assert!(ui.inputs.is_empty());
            let mut client = ScriptedClient::new(vec![show()]);
            let mut ui = Interrupted(ScriptedUi::new(&[key]));
            let navigation = NodeCard("n".into()).run(&mut Context::for_test(&mut client, &mut ui, &registry)).unwrap();
            assert!(matches!(navigation, Navigation::Back));
            client.assert_finished();
        }
    }
    #[test]
    fn frames_keep_list_sections_colours_and_separator_geometry() {
        use ratatui::{Terminal, backend::TestBackend};
        let problem = json!({"name": "problem", "ip": "192.0.2.2", "port": 22, "auth": "password", "password": "missing", "issues": []});
        let deferred = json!({"name": "deferred", "ip": "192.0.2.3", "port": 22, "auth": "key", "password": null, "issues": ["missing_identity"]});
        let (_, ui) = screen(&mut Nodes, &["0"], vec![step(&["node", "list"], ok(json!([node(), problem, deferred]))), step(&["status"], ok(json!({"ssh_setup_pending": true})))]);
        let view = &ui.views[0];
        assert_eq!(view.sections.len(), 2);
        assert_eq!(view.sections[0].iter().map(|i| i.color).collect::<Vec<_>>(), [ui::CYAN, ui::YELLOW, ui::YELLOW]);
        assert_eq!(view.sections[0][0].label, "n  192.0.2.1:22");
        assert_eq!(view.sections[1].iter().map(|i| (i.key.as_str(), i.color)).collect::<Vec<_>>(), [("a", ui::GREEN), ("h", ui::YELLOW), ("0", ui::NC)]);
        let lines: Vec<_> = view.lines().iter().map(|l| l.to_string()).collect();
        assert!(lines[0].is_empty());
        assert!(!lines.windows(2).any(|w| w[0].starts_with('├') && w[1].starts_with('├')));
        assert_eq!(lines.iter().filter(|l| l.starts_with('├')).count(), 2);
        let mut terminal = Terminal::new(TestBackend::new(90, 35)).unwrap();
        terminal.draw(|frame| ui::render(frame, view, "", false, &[])).unwrap();
        assert!(terminal.backend().buffer().content.iter().any(|c| c.fg == ui::YELLOW));
        for view in &ui.views {
            assert!(view.sections.iter().flatten().all(|item| item.key.bytes().all(|b| b.is_ascii_digit()) || (item.key.len() == 1 && item.key.as_bytes()[0].is_ascii_lowercase())));
        }
    }
    #[test]
    fn read_errors_offer_explicit_retry_without_automatic_requests() {
        for key in ["r", "R"] {
            let mut steps = vec![step(&["node", "list"], Reply::failure("remote_failed"))];
            steps.extend(listing());
            let (_, ui) = screen(&mut Nodes, &[key, "0"], steps);
            assert!(!ui.views[0].context.is_empty());
            assert_eq!(ui.views[0].sections[0][0].key, "r");
            let lines: Vec<_> = ui.views[0].lines().iter().map(|l| l.to_string()).collect();
            assert_eq!(lines.iter().filter(|l| l.starts_with('├')).count(), 2);
        }
    }
    #[test]
    fn root_factories_are_registered() {
        let registry = crate::app::registrations();
        for key in ['n', 'a', 't', 'p'] { assert!(registry.screens.iter().any(|entry| entry.key == key)); }
    }
}
