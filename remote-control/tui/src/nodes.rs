//! Node, node profile, cascade, SSH, connection and Telegram screens (v1
//! `tui/nodes.sh`) over the daemon protocol only.
//!
//! Lists keep their own menu section; dangerous actions consume the core's
//! frozen plan through `confirm`. The terminal command `node shell` is a
//! terminal request while the UI is suspended. Changes of the desired node
//! state (profile, Telegram Proxy role) reach a node only through `node apply`
//! (`apply`).
use std::io;
use serde_json::Value;
use ratatui::style::Color;
use essence_rc_client::{argv, Input, Reply, Secrets};
use crate::{app::{Context, Navigation, Screen}, confirm::{self, set_flag}, ui::{self, Item, View}};

pub struct Nodes;
pub struct Connections;
pub struct Telegram;
pub struct Profiles;
pub struct Cascades;
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
    let Some(domain) = ask_valid(ctx, &format!("Нода: {name}"), "Домен ноды (Enter — отмена)", domain_check)? else { return Ok(false); };
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
/// `node shell`: a terminal request; the daemon runs the remote PTY and the
/// local console relays it while the UI is suspended.
fn shell(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    let words = argv(&["node", "shell", "--name", name]);
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
        let label = if problems && !profiled(node) { format!("{label}  · профиль не указан") } else { label };
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
            let unprofiled: Vec<&Value> = rows(&reply.data).iter().filter(|node| !profiled(node)).collect();
            let mut actions = vec![Item::new('a', "Добавить ноду", ui::GREEN)];
            if !unprofiled.is_empty() { actions.push(Item::new('f', format!("Указать профиль (нод без профиля: {})", unprofiled.len()), ui::GREEN)); }
            if waiting > 0 { actions.push(Item::new('y', format!("Применить на всех ожидающих ({waiting})"), ui::GREEN)); }
            if pending { actions.push(Item::new('h', "Завершить отложенную SSH-настройку", ui::YELLOW)); }
            actions.push(Item::new(0, "Назад", ui::NC));
            view.sections.push(actions);
            let Some(choice) = ctx.choose(&view)? else { return Ok(Navigation::Back); };
            match choice.as_str() {
                "a" | "A" => add_node_among(ctx, names(&reply.data))?,
                "f" | "F" if !unprofiled.is_empty() => {
                    let labels: Vec<String> = unprofiled.iter().map(|node| node_label(node)).collect();
                    let picked = if unprofiled.len() == 1 { Some(0) } else { ctx.select("Нода без профиля", &labels)? };
                    if let Some(i) = picked { node_profile(ctx, &text(&unprofiled[i]["name"]), unprofiled[i])?; }
                }
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
fn profiled(node: &Value) -> bool { !text(&node["profile"]).is_empty() }
/// One-sentence explanations of the domains of a node («Роли и домены»).
const ROLE_DOMAIN: &str = "адрес сайта-заглушки; DNS этого домена ведёт на IP ноды";
const ROLE_TELEGRAM: &str = "отдельный домен, через который Telegram подключается к ноде";
const ROLE_SUBSCRIPTION: &str = "домен, с которого приложения клиентов скачивают подписки";
/// «Роли и домены» of a node: (label, value or `None` when unset, unset text, explanation).
fn node_roles(node: &Value) -> [(&'static str, Option<String>, &'static str, &'static str); 3] {
    let set = |value: String| (!value.is_empty()).then_some(value);
    let sub = &node["subscription"];
    let host = sub.is_object().then(|| if sub["port"] == 443 { text(&sub["hostname"]) } else { format!("{}:{}", text(&sub["hostname"]), text(&sub["port"])) });
    [
        ("Домен ноды (сайт-заглушка, Reality)", set(text(&node["domain"])), "не задан", ROLE_DOMAIN),
        ("Telegram Web Proxy", set(text(&node["telegram"]["hostname"])), "выключен", ROLE_TELEGRAM),
        ("Хост подписок", host, "не назначен", ROLE_SUBSCRIPTION),
    ]
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
    let has_profile = profiled(node);
    view.context.push(if has_profile { plain(format!("Профиль: {}", text(&node["profile"]))) } else { ui::text("Профиль: не указан — f) Указать профиль", ui::YELLOW) });
    if let Some(ports) = node["ports"].as_object().filter(|ports| !ports.is_empty()) {
        let list: Vec<String> = ports.iter().map(|(key, port)| format!("{key}: {}", text(port))).collect();
        view.context.push(plain(format!("Порты ноды: {}", list.join(", "))));
    }
    if let Some((state, color)) = apply_state(node) { view.context.push(ui::text(format!("Применение: {state}"), color)); }
    if let Some(label) = warp_label(node) { view.context.push(plain(format!("WARP: {label}"))); }
    let issues = joined(&node["issues"]);
    if !issues.is_empty() { view.context.push(ui::text(format!("Требует настройки: {issues}"), ui::YELLOW)); }
    let groups = joined(&node["groups"]);
    view.context.push(plain(format!("Группы: {}", if groups.is_empty() { "нет" } else { &groups })));
    view.context.push(plain(format!("Клиентов: {}", text(&node["clients"]))));
    view.context.push(plain("Роли и домены:".into()));
    for (i, (label, value, unset, hint)) in node_roles(node).into_iter().enumerate() {
        let line = match value {
            Some(value) => ui::text(format!("• {label}: {value}"), ui::GREEN),
            // Telegram and subscriptions need the node's profile first.
            None if i > 0 && !has_profile => ui::text(format!("• {label}: {unset} (сначала укажите профиль)"), ui::DIM),
            None => ui::text(format!("• {label}: {unset}"), ui::DIM),
        };
        view.context.push(line);
        view.context.push(plain(format!("  {hint}")));
    }
    view.sections.push(vec![
        Item::new('y', "Применить", ui::GREEN),
        Item::new('o', "Оболочка", ui::CYAN),
        Item::new('p', "Подключения ноды", ui::CYAN), Item::new('k', "Проверить подключение", ui::CYAN),
    ]);
    let [domain, telegram, subscription] = node_roles(node).map(|(_, value, ..)| value.is_some());
    let mut roles = vec![
        if has_profile { Item::new('f', "Профиль", ui::YELLOW) } else { Item::new('f', "Указать профиль", ui::GREEN) },
        Item::new('m', if domain { "Домен ноды" } else { "Задать домен ноды" }, ui::YELLOW),
    ];
    if has_profile {
        roles.push(if telegram { Item::new('t', "Telegram Web Proxy", ui::CYAN) } else { Item::new('t', "Включить Telegram Web Proxy", ui::GREEN) });
        roles.push(if subscription { Item::new('s', "Хост подписок: сменить домен или порт", ui::YELLOW) } else { Item::new('s', "Сделать хостом подписок", ui::GREEN) });
    }
    view.sections.push(roles);
    let mut actions = vec![
        Item::new('i', "Порты", ui::YELLOW),
        Item::new('h', "Усилить защиту SSH", ui::YELLOW), Item::new('r', "Переименовать", ui::YELLOW), Item::new('e', "Тег", ui::YELLOW),
    ];
    if warp_label(node).is_some() { actions.push(Item::new('g', "Перерегистрировать WARP", ui::YELLOW)); }
    if password { actions.push(Item::new('w', "Пароль SSH", ui::YELLOW)); }
    actions.extend([Item::new('l', "Псевдонимы подключений", ui::YELLOW), Item::new('d', "Удалить ноду", ui::RED), Item::new(0, "Назад", ui::NC)]);
    view.sections.push(actions);
    view
}
/// What `set_subscription_host` did.
enum HostSet { Saved(String), Declined, Failed }
/// Makes `name` the subscription host on `domain` (`port` empty — 443): a
/// host on another node is named and the move confirmed first. `Saved(old
/// host node or "")`; `Declined` — the move refused; `Failed` — a command failed.
fn set_subscription_host(ctx: &mut Context<'_>, name: &str, domain: &str, port: &str) -> io::Result<HostSet> {
    let host = ctx.call(&["subscription", "host"])?;
    if !host.ok { outcome(ctx, &host); return Ok(HostSet::Failed); }
    let old = text(&host.data["node"]);
    let old = if old == name { String::new() } else { old };
    if !old.is_empty() {
        let mut view = View::new(format!("Хост подписок: {name}"));
        view.context.push(ui::text(format!("Сейчас хост подписок — нода «{old}» ({}).", text(&host.data["hostname"])), ui::YELLOW));
        view.context.push(ui::text("После переноса обе ноды нужно применить, затем обновить подписки (subscription publish-all).", ui::NC));
        if !ctx.confirm(view, &format!("Перенести хост подписок на ноду «{name}»?"))? { return Ok(HostSet::Declined); }
    }
    let mut words = argv(&["subscription", "host", "--name", name, "--domain", domain]);
    // The core's default port is not passed (the web's `subscriptionSetHost`).
    if !port.is_empty() && port != "443" { words.extend(argv(&["--port", port])); }
    let reply = ctx.request(&words, &Secrets::default())?;
    if !reply.ok { outcome(ctx, &reply); return Ok(HostSet::Failed); }
    Ok(HostSet::Saved(old))
}
/// `domain` is one of the node's other domains; DNS names compare
/// case-insensitively, as in the core.
fn domain_taken(taken: &[impl AsRef<str>], domain: &str) -> bool {
    taken.iter().any(|other| other.as_ref().eq_ignore_ascii_case(domain))
}
const DOMAIN_TAKEN: &str = "Этот домен уже занят другой ролью ноды — нужен отдельный домен (поддомен).";
/// «Сделать хостом подписок» / «Хост подписок»: domain and port →
/// `subscription host`; both the node and a former host then wait for `node apply`.
fn subscription_role(ctx: &mut Context<'_>, name: &str, node: &Value) -> io::Result<()> {
    let title = format!("Хост подписок: {name}");
    let own = &node["subscription"];
    let (keep, keep_port) = (text(&own["hostname"]), text(&own["port"]));
    let taken = [text(&node["domain"]), text(&node["telegram"]["hostname"])];
    let domain = loop {
        let prompt = if keep.is_empty() { "Домен для подписок, например sub.example.com (Enter — отмена)".to_owned() } else { format!("Домен для подписок [{keep}]") };
        let Some(domain) = ask_valid(ctx, &title, &prompt, domain_check)? else { return Ok(()); };
        let domain = if domain.is_empty() { keep.clone() } else { domain };
        if domain.is_empty() { return Ok(()); }
        if domain_taken(&taken, &domain) { ctx.ui.notice(ui::warn(DOMAIN_TAKEN)); continue; }
        break domain;
    };
    let prompt = if keep_port.is_empty() { "Порт подписок (Enter — 443)".to_owned() } else { format!("Порт подписок [{keep_port}]") };
    let Some(port) = ask_valid(ctx, &title, &prompt, port_check)? else { return Ok(()); };
    let port = if port.is_empty() { keep_port } else { port };
    let HostSet::Saved(old) = set_subscription_host(ctx, name, &domain, &port)? else { return Ok(()); };
    offer_apply_on(ctx, &[name.to_owned(), old])
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
                "o" | "O" => shell(ctx, &name)?,
                "p" | "P" => connection_node(ctx, &name)?,
                "g" | "G" if warp_label(node).is_some() => warp_reregister(ctx, &name)?,
                "k" | "K" => { node_request(ctx, &name, &argv(&["node", "check", "--name", &name]), None)?; }
                "y" | "Y" => { apply(ctx, &argv(&["node", "apply", "--name", &name]), &name)?; }
                "f" | "F" => node_profile(ctx, &name, node)?,
                "m" | "M" => node_domain(ctx, &name, node)?,
                "t" | "T" if profiled(node) => if node["telegram"].is_object() { telegram_card(ctx, &name)? } else { telegram_domain(ctx, &name)? },
                "s" | "S" if profiled(node) => subscription_role(ctx, &name, node)?,
                "i" | "I" => node_ports(ctx, &name, node)?,
                "h" | "H" => harden(ctx, &name)?,
                "r" | "R" => {
                    // Esc/Ctrl+D cancel only the rename; Ctrl+C leaves the card.
                    let Some(new) = ask_valid(ctx, "Переименование ноды", "Новое имя ноды (Enter — отмена)", name_check)? else { if ctx.ui.interrupted() { return Ok(Navigation::Back); } continue; };
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
/// «Перерегистрировать WARP»: the core's plan → `node warp-reregister`; the
/// node then waits for `node apply`, offered right away.
fn warp_reregister(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    let words = argv(&["node", "warp-reregister", "--name", name]);
    let reply = node_request(ctx, name, &words, Some(("Перерегистрация WARP", "Перерегистрировать аккаунт WARP?")))?;
    if reply.ok { offer_apply_on(ctx, &[name.to_owned()])?; }
    Ok(())
}

// ─── Добавление ──────────────────────────────────────────────────────────────

#[cfg(test)]
fn add_node(ctx: &mut Context<'_>) -> io::Result<()> { add_node_among(ctx, Vec::new()) }
/// The add wizard; the name suggestion avoids the existing node names `taken`.
fn add_node_among(ctx: &mut Context<'_>, taken: Vec<String>) -> io::Result<()> {
    let mut secrets = Secrets::default();
    let result = add_node_with(ctx, &mut secrets, taken);
    secrets.clear();
    result
}
/// An optional role domain (Enter — none) other than the domains in `taken`.
fn ask_role_domain(ctx: &mut Context<'_>, title: &str, prompt: &str, taken: &[&str]) -> io::Result<Option<String>> {
    loop {
        let Some(value) = ask_valid(ctx, title, prompt, domain_check)? else { return Ok(None); };
        if value.is_empty() || !domain_taken(taken, &value) { return Ok(Some(value)); }
        ctx.ui.notice(ui::warn(DOMAIN_TAKEN));
    }
}
const ROLE_TELEGRAM_NAME: &str = "Telegram Web Proxy";
const ROLE_SUBSCRIPTION_NAME: &str = "хост подписок";
/// A role command of the add wizard failed (the core's message is in the
/// journal): «Повторить» asks the domain again (Enter keeps the typed one),
/// «Пропустить» — `None`, with the place to set it later.
fn role_retry(ctx: &mut Context<'_>, role: &str, domain: &str) -> io::Result<Option<String>> {
    ctx.ui.notice(ui::warn(format!("Не удалось задать {role} с доменом «{domain}». Позже: карточка ноды → Роли и домены.")));
    let choices: [String; 2] = ["Повторить".into(), "Пропустить".into()];
    if ctx.select(&format!("{role}: не задан"), &choices)? != Some(0) { return Ok(None); }
    let Some(value) = ask_valid(ctx, "Добавление ноды", &format!("Домен: {role} [{domain}]"), domain_check)? else { return Ok(None); };
    Ok(Some(if value.is_empty() { domain.to_owned() } else { value }))
}
fn add_node_with(ctx: &mut Context<'_>, secrets: &mut Secrets, taken: Vec<String>) -> io::Result<()> {
    const TITLE: &str = "Добавление ноды";
    let Some(name) = ask_checked(ctx, TITLE, "Название, например vps-1 [vps-1]", name_check, taken)? else { return Ok(()); };
    let name = if name.is_empty() { "vps-1".to_owned() } else { name };
    let Some(ip) = ask(ctx, TITLE, "IP")? else { return Ok(()); };
    if ip.is_empty() {
        ctx.ui.notice(ui::warn("IP не указан."));
        return Ok(());
    }
    let Some(port) = ask_valid(ctx, TITLE, "SSH-порт [22]", port_check)? else { return Ok(()); };
    let port = if port.is_empty() { "22".to_owned() } else { port };
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
    // Profile (no profiles — no question), the node domain when its site needs
    // one, then the optional Telegram Web Proxy and subscription domains.
    let profiles = ctx.call(&["profile", "list"])?;
    let profiles = if profiles.ok { rows(&profiles.data["profiles"]).to_vec() } else { vec![] };
    let (mut profile, mut domain, mut telegram, mut subscription) = (String::new(), String::new(), String::new(), String::new());
    if !profiles.is_empty() {
        let mut labels = vec!["Без профиля".to_owned()];
        labels.extend(profiles.iter().map(|p| text(&p["name"])));
        let Some(i) = ctx.select_with("Профиль ноды", vec![ui::text(PROFILE_EXPLAINED, ui::NC)], &labels)? else { return Ok(()); };
        if i > 0 {
            profile = text(&profiles[i - 1]["name"]);
            if needs_domain(&profiles[i - 1]) {
                let prompt = "Домен ноды (сайт-заглушка), например node.example.com";
                let Some(value) = ask_required(ctx, TITLE, prompt, domain_check, "Домен ноды не указан.")? else { return Ok(()); };
                domain = value;
            }
            let Some(value) = ask_role_domain(ctx, TITLE, "Домен для Telegram Web Proxy, например tg.example.com (Enter — не нужен)", &[&domain])? else { return Ok(()); };
            telegram = value;
            let Some(value) = ask_role_domain(ctx, TITLE, "Домен для подписок, например sub.example.com (Enter — не нужен)", &[&domain, &telegram])? else { return Ok(()); };
            subscription = value;
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
            let deferred = reply.data["needs_setup"] == true;
            if deferred { ctx.ui.notice(ui::warn("Нода сохранена, но требует SSH-настройки: раздел n → h.")); }
            // A node with a profile gets its roles, then one apply under the plan installs everything.
            if !profile.is_empty() {
                let saved = reply.data["name"].as_str().filter(|s| !s.is_empty()).unwrap_or(&name).to_owned();
                let mut words = argv(&["node", "apply", "--name", &saved]);
                while !telegram.is_empty() {
                    if ctx.call(&["telegram", "set", "--name", &saved, "--domain", &telegram])?.ok { break; }
                    telegram = role_retry(ctx, ROLE_TELEGRAM_NAME, &telegram)?.unwrap_or_default();
                }
                while !subscription.is_empty() {
                    match set_subscription_host(ctx, &saved, &subscription, "")? {
                        HostSet::Saved(old) => { if !old.is_empty() { words.extend(argv(&["--name", &old])); } break; }
                        HostSet::Declined => break,
                        HostSet::Failed => subscription = role_retry(ctx, ROLE_SUBSCRIPTION_NAME, &subscription)?.unwrap_or_default(),
                    }
                }
                // Deferred SSH setup: the node is not reachable yet, nothing to apply.
                if deferred {
                    ctx.ui.notice(ui::warn("Применение отложено: завершите SSH-настройку (раздел n → h), затем примените ноду (карточка ноды → y)."));
                } else {
                    apply(ctx, &words, &saved)?;
                }
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

// ─── Telegram ────────────────────────────────────────────────────────────────

/// Nodes with the Web Proxy role (`node list .telegram`), in list order.
fn telegram_nodes(list: &Value) -> Vec<&Value> { rows(list).iter().filter(|node| node["telegram"].is_object()).collect() }
fn telegram_label(node: &Value) -> String {
    let role = &node["telegram"];
    let tag = if role["tag"] == true { "да" } else { "нет" };
    let mut label = format!("{}  {}  · тег: {tag}", text(&node["name"]), text(&role["hostname"]));
    if let Some((state, _)) = apply_state(node) { label.push_str(&format!("  · {state}")); }
    label
}
/// «нода  статус  причина» and the summary lines of every `results` row
/// (data on success, error otherwise). False when the reply has no results.
fn telegram_table(ctx: &mut Context<'_>, reply: &Reply) -> io::Result<bool> {
    let results = if reply.ok { rows(&reply.data["results"]) } else { rows(&reply.error["results"]) };
    if results.is_empty() { return Ok(false); }
    let mut view = View::new("Состояние Telegram Proxy");
    view.status.push(ui::text("нода  статус  причина", ui::NC));
    for row in results {
        let (status, color) = match row["status"].as_str() {
            Some("ok") => ("готово", ui::GREEN),
            Some("not_installed") => ("не установлено", ui::YELLOW),
            Some("partial") => ("частично", ui::YELLOW),
            _ => ("ошибка", ui::RED),
        };
        view.context.push(ui::text(format!("{}  {status}  {}", text(&row["node"]), text(&row["reason"])), color));
        for line in rows(&row["summary"]) { view.context.push(ui::text(format!("  {}", text(line)), ui::NC)); }
    }
    crate::clients::present(ctx, &view)?;
    Ok(true)
}
/// After `telegram set|tag|rotate-secret|remove` the node waits for `node apply`.
fn telegram_changed(ctx: &mut Context<'_>, name: &str, reply: &Reply) -> io::Result<()> {
    if reply.ok { return offer_apply_on(ctx, &[name.to_owned()]); }
    outcome(ctx, reply);
    Ok(())
}
/// The Web Proxy domain (Enter — cancel) → `telegram set`.
fn telegram_domain(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    let title = format!("Telegram Proxy: {name}");
    let Some(domain) = ask_valid(ctx, &title, "Домен Web Proxy, например tg.example.com (Enter — отмена)", domain_check)? else { return Ok(()); };
    if domain.is_empty() { return Ok(()); }
    let reply = ctx.call(&["telegram", "set", "--name", name, "--domain", &domain])?;
    telegram_changed(ctx, name, &reply)
}
/// «Включить на ноде»: a node with a profile and without the role, then its domain.
fn telegram_enable(ctx: &mut Context<'_>, list: &Value) -> io::Result<()> {
    let candidates: Vec<&Value> = rows(list).iter().filter(|node| node["telegram"].is_null() && !text(&node["profile"]).is_empty()).collect();
    // The same answer as the web panel (`enableTelegram`): no empty list.
    if candidates.is_empty() { ctx.ui.notice(ui::warn("Нет нод с профилем без Telegram Proxy.")); return Ok(()); }
    let labels: Vec<String> = candidates.iter().map(|node| node_label(node)).collect();
    let Some(i) = ctx.select("Включение Telegram Proxy", &labels)? else { return Ok(()); };
    telegram_domain(ctx, &text(&candidates[i]["name"]))
}
/// «Ссылка»: shown in a frame with its QR code, never in the journal.
fn telegram_link(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    let reply = ctx.call(&["telegram", "link", "--name", name])?;
    if !reply.ok { outcome(ctx, &reply); return Ok(()); }
    let link = text(&reply.data["link"]);
    let mut view = View::new(format!("Ссылка Telegram Proxy: {name}"));
    view.context.push(ui::text(link.clone(), ui::GREEN));
    crate::clients::push_qr(&mut view, &crate::clients::qr_code(&link));
    crate::clients::present(ctx, &view)
}
const TAG_INVALID: &str = "Спонсорский тег — 32 шестнадцатеричных символа.";
/// «Спонсорский тег»: hidden entry (Enter/EOF — cancel) → `telegram tag` with
/// the tag only in the `password` secret, wiped on any outcome.
fn telegram_tag(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    let tag = loop {
        let Some(tag) = ctx.secret(&format!("Telegram Proxy: {name}"), "Спонсорский тег (Enter — отмена)")? else { return Ok(()); };
        if tag.is_empty() { return Ok(()); }
        if tag.len() == 32 && tag.bytes().all(|b| b.is_ascii_hexdigit()) { break tag; }
        ctx.ui.notice(ui::warn(TAG_INVALID));
    };
    let mut secrets = Secrets::default();
    secrets.insert_hidden("password", tag);
    let reply = ctx.request(&argv(&["telegram", "tag", "--name", name]), &secrets);
    secrets.clear();
    telegram_changed(ctx, name, &reply?)
}
/// The role of one node; the card returns to the list once the role is gone.
fn telegram_card(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    let title = format!("Telegram Proxy: {name}");
    loop {
        let listed = ctx.call(&["node", "list"])?;
        if !listed.ok {
            if read_failed(ctx, &title)? { continue; }
            return Ok(());
        }
        let Some(node) = telegram_nodes(&listed.data).into_iter().find(|node| node["name"] == name) else { return Ok(()); };
        let tagged = node["telegram"]["tag"] == true;
        let mut view = View::new(title.clone());
        view.prompt = "Выберите действие: ".into();
        view.context.push(ui::text(format!("Домен: {}", text(&node["telegram"]["hostname"])), ui::NC));
        view.context.push(if tagged { ui::text("Спонсорский тег: задан", ui::GREEN) } else { ui::text("Спонсорский тег: нет", ui::DIM) });
        if let Some((state, color)) = apply_state(node) { view.context.push(ui::text(format!("Применение: {state}"), color)); }
        view.sections.push(vec![Item::new('l', "Ссылка", ui::CYAN), Item::new('d', "Диагностика", ui::CYAN)]);
        let mut actions = vec![
            Item::new('m', "Сменить домен", ui::YELLOW), Item::new('k', "Сменить секрет", ui::YELLOW),
            Item::new('g', "Спонсорский тег", ui::YELLOW),
        ];
        if tagged { actions.push(Item::new('u', "Убрать тег", ui::RED)); }
        actions.extend([Item::new('r', "Перезапустить", ui::YELLOW), Item::new('x', "Убрать", ui::RED), Item::new(0, "Назад", ui::NC)]);
        view.sections.push(actions);
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        match choice.as_str() {
            "l" | "L" => telegram_link(ctx, name)?,
            "d" | "D" => { node_request(ctx, name, &argv(&["telegram", "diagnostics", "--name", name]), None)?; }
            "m" | "M" => telegram_domain(ctx, name)?,
            "k" | "K" => {
                let words = argv(&["telegram", "rotate-secret", "--name", name]);
                let reply = confirm::run_confirmed(ctx, "Смена секрета Telegram Proxy", "Сменить секрет? Прежняя ссылка перестанет работать.", &words, &Secrets::default())?;
                telegram_changed(ctx, name, &reply)?;
            }
            "g" | "G" => telegram_tag(ctx, name)?,
            "u" | "U" if tagged => {
                let reply = ctx.call(&["telegram", "tag", "--name", name, "--clear"])?;
                telegram_changed(ctx, name, &reply)?;
            }
            "r" | "R" => {
                let words = argv(&["telegram", "restart", "--name", name]);
                node_request(ctx, name, &words, Some(("Перезапуск Telegram Proxy", "Перезапустить службы?")))?;
            }
            "x" | "X" => {
                let words = argv(&["telegram", "remove", "--name", name]);
                let reply = confirm::run_confirmed(ctx, "Отключение Telegram Proxy", "Убрать Telegram Proxy с ноды?", &words, &Secrets::default())?;
                telegram_changed(ctx, name, &reply)?;
            }
            "0" => return Ok(()),
            _ => ctx.invalid(),
        }
    }
}
impl Screen for Telegram {
    fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> {
        loop {
            let reply = ctx.call(&["node", "list"])?;
            if !reply.ok {
                if read_failed(ctx, "Telegram Proxy")? { continue; }
                return Ok(Navigation::Back);
            }
            let nodes = telegram_nodes(&reply.data);
            let mut view = View::new("Telegram Proxy");
            view.prompt = "Выберите действие: ".into();
            if nodes.is_empty() {
                view.context.push(ui::text("Нет нод с Telegram Proxy", ui::DIM));
            } else {
                view.sections.push(nodes.iter().enumerate()
                    .map(|(i, node)| Item::new(i + 1, telegram_label(node), if node["status"] == "pending" { ui::YELLOW } else { ui::CYAN }))
                    .collect());
            }
            view.sections.push(vec![Item::new('s', "Статус", ui::CYAN), Item::new('a', "Включить на ноде", ui::GREEN), Item::new(0, "Назад", ui::NC)]);
            let Some(choice) = ctx.choose(&view)? else { return Ok(Navigation::Back); };
            match choice.as_str() {
                "s" | "S" => {
                    let status = ctx.call(&["telegram", "status"])?;
                    if !telegram_table(ctx, &status)? { outcome(ctx, &status); }
                }
                "a" | "A" => telegram_enable(ctx, &reply.data)?,
                "0" => return Ok(Navigation::Back),
                _ => match index(&choice, nodes.len()) {
                    Some(i) => telegram_card(ctx, &text(&nodes[i]["name"]))?,
                    None => ctx.invalid(),
                },
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
/// `node show .warp`: `None` — WARP is off in the node's profile (no line, no
/// reregistration); the core's rule, shared with the web.
fn warp_label(node: &Value) -> Option<&'static str> {
    match node["warp"].as_str() { Some("free") => Some("бесплатный"), Some("plus") => Some("WARP+"), Some("none") => Some("не зарегистрирован"), _ => None }
}
/// `node apply …` under its plan; `name` — the node of `--name` (node codes
/// and the top-level `domain_required` are resolved, then the command is
/// repeated). The report (success or `partial`) goes to the journal, one
/// `name: message` line per failure; for bulk nodes failed with
/// `domain_required` the domain is asked, other node codes go to
/// `handle_node_codes`, and after a resolved one the command is repeated once.
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
            let mut resolved = false;
            for entry in failed.iter().filter(|entry| entry["code"] == "domain_required") {
                resolved |= set_domain(ctx, &text(&entry["name"]))?;
            }
            for entry in failed.iter().filter(|entry| entry["code"] != "domain_required") {
                let failure = Reply { error: (*entry).clone(), ..Reply::default() };
                resolved |= handle_node_codes(ctx, &failure, &text(&entry["name"]))?;
            }
            if !resolved { return Ok(reply); }
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
/// Nodes pending after a change: `node apply --pending` opens the core's plan
/// at once (its confirmation is the only question).
pub(crate) fn offer_apply(ctx: &mut Context<'_>) -> io::Result<()> {
    let listed = ctx.call(&["node", "list"])?;
    if !listed.ok || pending_count(&listed.data) == 0 { return Ok(()); }
    apply(ctx, &argv(&["node", "apply", "--pending"]), "")?;
    Ok(())
}
/// After a change that leaves `nodes` waiting for `node apply`: one
/// `node apply --name …` for all of them under the core's plan (its
/// confirmation is the only question; nothing without a node).
pub(crate) fn offer_apply_on(ctx: &mut Context<'_>, nodes: &[String]) -> io::Result<()> {
    let mut targets: Vec<&str> = vec![];
    for node in nodes { if !node.is_empty() && !targets.contains(&node.as_str()) { targets.push(node); } }
    let Some(&first) = targets.first() else { return Ok(()); };
    let mut words = argv(&["node", "apply"]);
    for node in &targets { words.extend(argv(&["--name", node])); }
    apply(ctx, &words, if targets.len() == 1 { first } else { "" })?;
    Ok(())
}

// ─── Профиль, домен и порты ноды ─────────────────────────────────────────────

const DOMAIN_INVALID: &str = "Домен — части из латинских букв, цифр и дефисов через точку, например node.example.com.";
const PORT_INVALID: &str = "Порт должен быть числом от 1 до 65535.";
const EMAIL_INVALID: &str = "Email в виде имя@домен, например admin@example.com.";
const VERSION_INVALID: &str = "Версия в виде vX.Y.Z не ниже v1.19.18, например v1.19.18.";
/// What a name may contain (`validation::name_valid` of the core: no length limit).
pub(crate) const NAME_RULE: &str = "Только латинские буквы, цифры и символы . _ - без пробелов. Например: edge-full.";
/// `validation::domain_valid` of the core: labels, at least one dot.
pub(crate) fn domain_valid(value: &str) -> bool {
    (1..=253).contains(&value.len()) && value.contains('.') && value.split('.').all(|label| {
        (1..=63).contains(&label.len()) && label.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            && !label.starts_with('-') && !label.ends_with('-')
    })
}
/// `validation::name_valid` of the core.
pub(crate) fn name_valid(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')) && value.bytes().any(|b| b != b'.')
}
/// `validation::TRANSLIT` of the core (shared vectors: `core/tests/validation_vectors.json`).
const TRANSLIT: &[(char, &str)] = &[
    ('а', "a"), ('б', "b"), ('в', "v"), ('г', "g"), ('д', "d"), ('е', "e"), ('ё', "e"), ('ж', "zh"), ('з', "z"),
    ('и', "i"), ('й', "y"), ('к', "k"), ('л', "l"), ('м', "m"), ('н', "n"), ('о', "o"), ('п', "p"), ('р', "r"),
    ('с', "s"), ('т', "t"), ('у', "u"), ('ф', "f"), ('х', "kh"), ('ц', "ts"), ('ч', "ch"), ('ш', "sh"),
    ('щ', "shch"), ('ъ', ""), ('ы', "y"), ('ь', ""), ('э', "e"), ('ю', "yu"), ('я', "ya"),
    ('і', "i"), ('ї', "yi"), ('є', "ye"), ('ґ', "g"), ('ў', "u"),
    ('à', "a"), ('á', "a"), ('â', "a"), ('ã', "a"), ('ä', "a"), ('å', "a"), ('ā', "a"), ('ą', "a"), ('æ', "ae"),
    ('ç', "c"), ('ć', "c"), ('č', "c"), ('ď', "d"), ('đ', "d"), ('ð', "d"),
    ('è', "e"), ('é', "e"), ('ê', "e"), ('ë', "e"), ('ē', "e"), ('ę', "e"), ('ě', "e"), ('ğ', "g"),
    ('ì', "i"), ('í', "i"), ('î', "i"), ('ï', "i"), ('ī', "i"), ('ı', "i"), ('ł', "l"),
    ('ñ', "n"), ('ń', "n"), ('ň', "n"), ('ò', "o"), ('ó', "o"), ('ô', "o"), ('õ', "o"), ('ö', "o"), ('ø', "o"),
    ('ō', "o"), ('ő', "o"), ('œ', "oe"), ('ř', "r"), ('ś', "s"), ('š', "s"), ('ş', "s"), ('ș', "s"), ('ß', "ss"),
    ('ť', "t"), ('ţ', "t"), ('ț', "t"), ('þ', "th"), ('ù', "u"), ('ú', "u"), ('û', "u"), ('ü', "u"), ('ū', "u"),
    ('ů', "u"), ('ű', "u"), ('ý', "y"), ('ÿ', "y"), ('ź', "z"), ('ż', "z"), ('ž', "z"),
];
/// `validation::suggest_name` of the core: letters lowercased and
/// transliterated, combining accents dropped, other runs one `-`, separators
/// trimmed («VLESS TCP HY2» → «vless-tcp-hy2»), unique against `taken` (`-2`, `-3`, …).
pub(crate) fn suggest_name(value: &str, taken: &[String]) -> Option<String> {
    let mut out = String::new();
    for c in value.chars().flat_map(char::to_lowercase) {
        if c.is_ascii_alphanumeric() || matches!(c, '.' | '_') { out.push(c); }
        else if ('\u{300}'..='\u{36f}').contains(&c) { continue; }
        else if let Some((_, latin)) = TRANSLIT.iter().find(|(letter, _)| *letter == c) { out.push_str(latin); }
        else if !out.ends_with('-') { out.push('-'); }
    }
    let base = out.trim_matches(|c| matches!(c, '-' | '.' | '_')).to_owned();
    if !name_valid(&base) { return None; }
    if !taken.contains(&base) { return Some(base); }
    (2..).map(|n| format!("{base}-{n}")).find(|name| !taken.contains(name))
}
/// `validation::parse_ssh_port` of the core: 1–5 digits, 1…65535 (`080` too); empty — the question's default.
fn port_valid(value: &str) -> bool {
    value.is_empty() || ((1..=5).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_digit()) && value.parse::<u16>().is_ok_and(|p| p != 0))
}
fn problem(message: &str, fix: Option<String>) -> ui::Problem { ui::Problem { message: message.to_owned(), fix } }
/// Live check of an object name with a valid suggestion not in `taken` (Tab).
pub(crate) fn name_check(value: &str, taken: &[String]) -> Result<(), ui::Problem> {
    if name_valid(value) { Ok(()) } else { Err(problem(NAME_RULE, suggest_name(value, taken))) }
}
/// Live check of a domain; a pasted address (`https://host/…`) offers its host.
pub(crate) fn domain_check(value: &str, _: &[String]) -> Result<(), ui::Problem> {
    let value = value.trim();
    if domain_valid(value) { return Ok(()); }
    let host = value.rsplit("://").next().unwrap_or(value).split(['/', ':']).next().unwrap_or("").to_ascii_lowercase();
    Err(problem(DOMAIN_INVALID, (domain_valid(&host) && host != value).then_some(host)))
}
fn port_check(value: &str, _: &[String]) -> Result<(), ui::Problem> {
    if port_valid(value.trim()) { Ok(()) } else { Err(problem(PORT_INVALID, None)) }
}
fn email_check(value: &str, _: &[String]) -> Result<(), ui::Problem> {
    if email_valid(value.trim()) { Ok(()) } else { Err(problem(EMAIL_INVALID, None)) }
}
/// `vX.Y.Z` not below v1.19.18 (the core's minimum); `1.19.20` offers `v1.19.20`.
fn version_check(value: &str, _: &[String]) -> Result<(), ui::Problem> {
    let value = value.trim();
    if version_valid(value) { return Ok(()); }
    let fixed = format!("v{value}");
    Err(problem(VERSION_INVALID, (!value.starts_with('v') && version_valid(&fixed)).then_some(fixed)))
}
/// A question with a live check of the typed text: the terminal refuses a
/// failing answer, another UI's answer is checked again here. Returns the
/// trimmed answer (empty passes: cancel or default for the caller); `None` on cancel.
fn ask_valid(ctx: &mut Context<'_>, title: &str, prompt: &str, check: ui::Check) -> io::Result<Option<String>> {
    ask_checked(ctx, title, prompt, check, Vec::new())
}
/// `ask_valid` with the names already in use (a name suggestion avoids them).
fn ask_checked(ctx: &mut Context<'_>, title: &str, prompt: &str, check: ui::Check, taken: Vec<String>) -> io::Result<Option<String>> {
    let mut view = View::new(title);
    view.prompt = format!("{prompt}: ");
    view.check = Some(check);
    view.taken = taken;
    loop {
        let Some(value) = ctx.choose(&view)? else { return Ok(None); };
        let value = value.trim().to_owned();
        match check(&value, &view.taken) {
            Err(problem) if !value.is_empty() => ctx.ui.notice(ui::warn(problem.message)),
            _ => return Ok(Some(value)),
        }
    }
}
/// `ask_valid` that repeats an empty answer with `missing`.
fn ask_required(ctx: &mut Context<'_>, title: &str, prompt: &str, check: ui::Check, missing: &str) -> io::Result<Option<String>> {
    loop {
        let Some(value) = ask_valid(ctx, title, prompt, check)? else { return Ok(None); };
        if !value.is_empty() { return Ok(Some(value)); }
        ctx.ui.notice(ui::warn(missing));
    }
}
const PROFILE_EXPLAINED: &str = "Профиль — набор протоколов и настроек сервера; нода с профилем настраивается командой «Применить».";
/// «Профиль» / «Указать профиль»: a profile or «Без профиля» → `node profile`;
/// without profiles the profile wizard is offered first. A node given a
/// profile waits for `node apply`, offered right away.
fn node_profile(ctx: &mut Context<'_>, name: &str, node: &Value) -> io::Result<()> {
    let listed = ctx.call(&["profile", "list"])?;
    if !listed.ok { ctx.failed(); return Ok(()); }
    let title = format!("Профиль ноды: {name}");
    let profiles = names(&listed.data["profiles"]);
    let chosen = if profiles.is_empty() {
        let mut view = View::new(title.as_str());
        view.context.push(ui::text(PROFILE_EXPLAINED, ui::NC));
        if !ctx.confirm(view, "Профилей ещё нет. Создать профиль сейчас?")? { return Ok(()); }
        let Some(created) = add_profile(ctx)? else { return Ok(()); };
        created
    } else {
        let mut values = vec![String::new()];
        values.extend(profiles);
        let current = text(&node["profile"]);
        let labels: Vec<String> = values.iter().map(|v| {
            let label = if v.is_empty() { "Без профиля".to_owned() } else { v.clone() };
            if *v == current { format!("{label} (сейчас)") } else { label }
        }).collect();
        let Some(i) = ctx.select_with(&title, vec![ui::text(PROFILE_EXPLAINED, ui::NC)], &labels)? else { return Ok(()); };
        if values[i] == current { ctx.ui.notice(ui::warn("Изменений нет.")); return Ok(()); }
        values.swap_remove(i)
    };
    let reply = ctx.call(&["node", "profile", "--name", name, "--profile", &chosen])?;
    if !reply.ok { outcome(ctx, &reply); return Ok(()); }
    if !chosen.is_empty() { offer_apply_on(ctx, &[name.to_owned()])?; }
    Ok(())
}
/// «Домен ноды»: Enter clears the domain → `node domain`; the node then waits for `node apply`.
fn node_domain(ctx: &mut Context<'_>, name: &str, node: &Value) -> io::Result<()> {
    let Some(domain) = ask_valid(ctx, &format!("Домен ноды: {name}"), "Домен (Enter — без домена)", domain_check)? else { return Ok(()); };
    if domain == text(&node["domain"]) { ctx.ui.notice(ui::warn("Изменений нет.")); return Ok(()); }
    let reply = ctx.call(&["node", "domain", "--name", name, "--domain", &domain])?;
    if !reply.ok { outcome(ctx, &reply); return Ok(()); }
    if !text(&node["profile"]).is_empty() { offer_apply_on(ctx, &[name.to_owned()])?; }
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
    let Some(port) = ask_valid(ctx, &format!("Порты ноды: {name}"), "Порт (Enter — порт профиля)", port_check)? else { return Ok(()); };
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
const SITE_SOURCES: [Choice; 4] = [
    ("random", "Случайный шаблон", "сайт выбирается случайно из всех наборов — подходит почти всегда"),
    ("simple", "Набор simple-web-templates", "простые сайты-визитки"),
    ("sni", "Набор sni-templates", "страницы в стиле онлайн-сервисов"),
    ("nothing", "Набор nothing-sni", "минималистичные страницы-заглушки"),
];
const IPV6: [Choice; 3] = [
    ("default", "Как в системе", "настройки IPv6 сервера не меняются"),
    ("enabled", "Включить", "нода работает и по IPv6, если провайдер выдал ей IPv6-адрес"),
    ("disabled", "Отключить", "IPv6 на сервере выключается — если он работает плохо или мешает сайтам верно определять страну"),
];

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
/// `vX.Y.Z` not below v1.19.18 (`model::MIHOMO_MIN_VERSION` of the core).
fn version_valid(value: &str) -> bool {
    let Some(rest) = value.strip_prefix('v') else { return false; };
    let parts: Vec<&str> = rest.split('.').collect();
    if parts.len() != 3 || !parts.iter().all(|p| !p.is_empty() && p.len() <= 9 && p.bytes().all(|b| b.is_ascii_digit())) { return false; }
    let numbers: Vec<u64> = parts.iter().map(|p| p.parse().unwrap_or(0)).collect();
    numbers.as_slice() >= [1, 19, 18].as_slice()
}
/// (value, label, one-sentence explanation for a non-specialist) of a choice.
type Choice = (&'static str, &'static str, &'static str);
const REALITY: [Choice; 2] = [
    ("self-steal", "Self-Steal — свой домен", "нода маскируется под собственный сайт-заглушку на вашем домене; нужен домен, направленный на IP ноды."),
    ("sni", "SNI — чужой сайт", "нода выдаёт себя за известный чужой сайт (например, www.microsoft.com); свой домен не нужен."),
];
const XHTTP_TOPOLOGIES: [Choice; 2] = [
    ("reality", "Reality — отдельный порт", "xHTTP работает сам по себе на своём порту и маскируется под чужой сайт, как VLESS TCP. Проще и не зависит от вашего сайта."),
    ("nginx", "Через ваш сайт (nginx, порт 443)", "xHTTP прячется внутри сайта-заглушки на 443 по секретному адресу: снаружи это обычные заходы на ваш сайт. Лучше проходит строгую фильтрацию, но нужен домен ноды."),
];
const OBFS: [Choice; 2] = [
    ("on", "Включить", "Скрывает, что это Hysteria2: помогает, если провайдер режет такой трафик; все клиенты должны поддерживать obfs."),
    ("off", "Выключить", "Обычный Hysteria2, совместим со всеми клиентами."),
];
/// One sentence per protocol of `PROTOCOLS`, in its order.
const PROTOCOL_HINTS: [&str; 6] = [
    "основной протокол: быстрый и надёжный, оставьте включённым",
    "выглядит как обычные HTTP-запросы",
    "выглядит как gRPC-трафик",
    "быстрый протокол поверх UDP",
    "VPN на основе WireGuard с маскировкой",
    "сайты видят адрес Cloudflare вместо адреса ноды",
];
const SITE_EXPLAINED: &str = "Сайт-заглушка — страница, которую увидит обычный посетитель домена ноды: сервер выглядит как обычный сайт.";
const XHTTP_EXPLAINED: &str = "Как подключение xHTTP будет выглядеть для провайдера:";
const MIHOMO_EXPLAINED: &str = "mihomo — программа-прокси на сервере; обычно выбирайте последнюю версию.";
/// One of `options` by number, each explained above the list; the current
/// value is marked, highlighted and kept by Enter.
fn choose_option(ctx: &mut Context<'_>, title: &str, intro: Option<&str>, options: &[Choice], current: Option<&str>) -> io::Result<Option<String>> {
    let mut context: Vec<_> = intro.into_iter().map(|line| ui::text(line, ui::NC)).collect();
    context.extend(options.iter().map(|(_, label, hint)| ui::text(format!("• {label}: {hint}"), ui::NC)));
    let labels: Vec<String> = options.iter().map(|(value, label, _)| if current == Some(*value) { format!("{label} (сейчас)") } else { (*label).to_owned() }).collect();
    let at = options.iter().position(|(value, ..)| current == Some(*value));
    Ok(ctx.select_with_current(title, context, &labels, at)?.map(|i| options[i].0.to_owned()))
}
/// The mihomo version: «Последняя (vX)», the recent versions and «Ввести
/// вручную» from `profile mihomo-versions`; manual entry (format hint, live
/// check) also when the list is unavailable. `current` (editing) is marked,
/// highlighted and kept on Enter. `Some("")` — the latest by the core; `None` — cancelled.
fn choose_version(ctx: &mut Context<'_>, title: &str, current: Option<&str>) -> io::Result<Option<String>> {
    let listed = ctx.call(&["profile", "mihomo-versions"])?;
    let latest = text(&listed.data["latest"]);
    if listed.ok && !latest.is_empty() {
        let mut values = vec![latest.clone()];
        values.extend(rows(&listed.data["versions"]).iter().map(text).filter(|v| *v != latest));
        if let Some(current) = current.filter(|c| !c.is_empty() && !values.iter().any(|v| v == c)) { values.insert(1, current.to_owned()); }
        let mut labels: Vec<String> = values.iter().enumerate().map(|(i, value)| {
            let label = if i == 0 { format!("Последняя ({value})") } else { value.clone() };
            if current == Some(value.as_str()) { format!("{label} (сейчас)") } else { label }
        }).collect();
        labels.push("Ввести вручную".into());
        let at = values.iter().position(|value| current == Some(value.as_str()));
        let Some(i) = ctx.select_with_current("Версия mihomo", vec![ui::text(MIHOMO_EXPLAINED, ui::NC)], &labels, at)? else { return Ok(None); };
        if i < values.len() { return Ok(Some(values.swap_remove(i))); }
    }
    let prompt = match current.filter(|c| !c.is_empty()) {
        Some(current) => format!("Версия mihomo в виде vX.Y.Z, например v1.19.18 [{current}]"),
        None => "Версия mihomo в виде vX.Y.Z, например v1.19.18 (Enter — последняя)".to_owned(),
    };
    let Some(version) = ask_valid(ctx, title, &prompt, version_check)? else { return Ok(None); };
    Ok(Some(if version.is_empty() { current.unwrap_or_default().to_owned() } else { version }))
}
/// The profile wizard (plan order): name → Reality → masking domain or site
/// source → protocols → xHTTP topology → ports → obfs → AmneziaWG DNS → IPv6 →
/// email → mihomo version. Every technical choice explains its options.
/// `current` — the answers to start from (the profile being edited or a
/// failed attempt), Enter keeps each of them; `rename` asks the name
/// (adding), editing skips it; the name suggestion avoids `taken`. `None` — cancelled.
fn profile_wizard(ctx: &mut Context<'_>, current: Option<&ProfileForm>, rename: bool) -> io::Result<Option<ProfileForm>> {
    profile_wizard_among(ctx, current, rename, Vec::new())
}
/// The wizard with the existing profile names `taken`.
fn profile_wizard_among(ctx: &mut Context<'_>, current: Option<&ProfileForm>, rename: bool, taken: Vec<String>) -> io::Result<Option<ProfileForm>> {
    let editing = current.is_some();
    let mut form = current.cloned().unwrap_or_default();
    let title = if rename { "Добавление профиля".to_owned() } else { format!("Профиль: {}", form.name) };
    let mark = |value: &str| editing.then_some(value.to_owned());
    if rename {
        // A retried attempt keeps its name on Enter; a new one cancels on Enter.
        let prompt = if form.name.is_empty() { "Имя профиля, например edge-full (Enter — отмена)".to_owned() } else { format!("Имя профиля [{}]", form.name) };
        let Some(name) = ask_checked(ctx, &title, &prompt, name_check, taken)? else { return Ok(None); };
        if !name.is_empty() { form.name = name; }
        if form.name.is_empty() { return Ok(None); }
    }
    let Some(mode) = choose_option(ctx, "Режим Reality", Some("Как нода прячет VPN-трафик от провайдера:"), &REALITY, mark(&form.reality).as_deref())? else { return Ok(None); };
    form.reality = mode;
    if form.reality == "sni" {
        let keep = editing && !form.sni_domain.is_empty();
        let prompt = if keep { format!("Чужой сайт для маскировки, например www.microsoft.com [{}]", form.sni_domain) } else { "Чужой сайт для маскировки, например www.microsoft.com".to_owned() };
        let domain = if keep { ask_valid(ctx, &title, &prompt, domain_check)? } else { ask_required(ctx, &title, &prompt, domain_check, "Домен не указан.")? };
        let Some(domain) = domain else { return Ok(None); };
        if !domain.is_empty() { form.sni_domain = domain; }
    } else {
        let Some(source) = choose_option(ctx, "Сайт-заглушка", Some(SITE_EXPLAINED), &SITE_SOURCES, mark(&form.site_source).as_deref())? else { return Ok(None); };
        form.site_source = source;
    }
    let labels: Vec<String> = PROTOCOLS.iter().map(|(_, label, _)| (*label).to_owned()).collect();
    let hints: Vec<_> = PROTOCOLS.iter().zip(PROTOCOL_HINTS).map(|((_, label, _), hint)| ui::text(format!("• {label}: {hint}"), ui::NC)).collect();
    loop {
        let flags = PROTOCOLS.iter().map(|(value, ..)| form.on(value)).collect();
        let Some(chosen) = ctx.toggle_with("Протоколы профиля", hints.clone(), &labels, flags, EMPTY)? else { return Ok(None); };
        if chosen.is_empty() { ctx.ui.notice(ui::warn("Выберите хотя бы один протокол.")); continue; }
        form.protocols = chosen.into_iter().map(|i| PROTOCOLS[i].0.to_owned()).collect();
        break;
    }
    if form.on("xhttp") {
        if form.reality == "sni" { form.xhttp = "reality".into(); } else {
            let Some(topology) = choose_option(ctx, "Топология xHTTP", Some(XHTTP_EXPLAINED), &XHTTP_TOPOLOGIES, mark(&form.xhttp).as_deref())? else { return Ok(None); };
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
        let Some(port) = ask_valid(ctx, &title, &prompt, port_check)? else { return Ok(None); };
        if !port.is_empty() || !keep { *field = port; }
    }
    if form.on("hysteria2") {
        let current = editing.then_some(if form.hysteria2_obfs { "on" } else { "off" });
        let Some(obfs) = choose_option(ctx, "Hysteria2: обфускация (obfs)", None, &OBFS, current)? else { return Ok(None); };
        form.hysteria2_obfs = obfs == "on";
    }
    if form.on("amneziawg") {
        let prompt = if form.amneziawg_dns.is_empty() { "DNS AmneziaWG (Enter — 1.1.1.1, 1.0.0.1)".to_owned() } else { format!("DNS AmneziaWG [{}]", form.amneziawg_dns) };
        let Some(dns) = ask(ctx, &title, &prompt)? else { return Ok(None); };
        if !dns.trim().is_empty() { form.amneziawg_dns = dns.trim().to_owned(); }
    }
    let Some(ipv6) = choose_option(ctx, "IPv6", None, &IPV6, mark(&form.ipv6).as_deref())? else { return Ok(None); };
    form.ipv6 = ipv6;
    let keep = editing && !form.acme_email.is_empty();
    let prompt = if keep { format!("Email для Let's Encrypt (уведомления о сертификатах) [{}]", form.acme_email) } else { "Email для Let's Encrypt (уведомления о сертификатах; Enter — случайный адрес)".to_owned() };
    let Some(email) = ask_valid(ctx, &title, &prompt, email_check)? else { return Ok(None); };
    if !email.is_empty() || !keep { form.acme_email = email; }
    let current = editing.then_some(form.mihomo_version.clone());
    let Some(version) = choose_version(ctx, &title, current.as_deref())? else { return Ok(None); };
    form.mihomo_version = version;
    Ok(Some(form))
}
/// «Добавить профиль»: the wizard → `profile add`; the saved name, `None`
/// when cancelled or failed. A failed `profile add` (`confirm::retryable`)
/// reopens the wizard with the answers, name included.
fn add_profile(ctx: &mut Context<'_>) -> io::Result<Option<String>> { add_profile_among(ctx, Vec::new()) }
/// `add_profile` whose name suggestion avoids the existing profile names `taken`.
fn add_profile_among(ctx: &mut Context<'_>, taken: Vec<String>) -> io::Result<Option<String>> {
    let mut draft = None;
    loop {
        let Some(form) = profile_wizard_among(ctx, draft.as_ref(), true, taken.clone())? else { return Ok(None); };
        let added = ctx.request(&profile_add_argv(&form), &Secrets::default())?;
        if added.ok { return Ok(Some(added.data["name"].as_str().filter(|s| !s.is_empty()).unwrap_or(&form.name).to_owned())); }
        outcome(ctx, &added);
        if !confirm::retryable(&added) { return Ok(None); }
        draft = Some(form);
    }
}
/// «Изменить»: `profile set` with the changed flags; a failed command reopens
/// the wizard with the answers.
fn edit_profile(ctx: &mut Context<'_>, name: &str, profile: &Value) -> io::Result<()> {
    let mut current = profile.clone();
    let mut draft = ProfileForm::from_profile(profile);
    loop {
        let Some(form) = profile_wizard(ctx, Some(&draft), false)? else { return Ok(()); };
        let Some(words) = profile_set_argv(name, &form, &current) else { ctx.ui.notice(ui::warn("Изменений нет.")); return Ok(()); };
        let reply = ctx.request(&words, &Secrets::default())?;
        outcome(ctx, &reply);
        if !confirm::retryable(&reply) { return Ok(()); }
        // A failure after the local write (e.g. the checkpoint) may have saved
        // part of it: the next command is computed against the saved profile,
        // the wizard keeps the user's answers.
        let shown = ctx.call(&["profile", "show", "--name", name])?;
        if !shown.ok { return Ok(()); }
        current = shown.data;
        draft = form;
    }
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
                "a" | "A" => if let Some(name) = add_profile_among(ctx, names(&reply.data["profiles"]))? { ProfileCard(name).run(ctx)?; },
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
    view.context.push(plain(format!("VLESS xHTTP: {}", off(xhttp, if xhttp["topology"] == "nginx" { "через ваш сайт (nginx, порт 443)".into() } else { format!("отдельный порт {} (Reality)", port_text(xhttp)) }))));
    view.context.push(plain(format!("VLESS gRPC: {}", off(&profile["vless_grpc"], format!("порт {}", port_text(&profile["vless_grpc"]))))));
    let hy2 = &profile["hysteria2"];
    view.context.push(plain(format!("Hysteria2: {}", off(hy2, format!("порт {}{}", port_text(hy2), if hy2["obfs"] == true { ", obfs" } else { "" })))));
    let awg = &profile["amneziawg"];
    view.context.push(plain(format!("AmneziaWG: {}", off(awg, format!("порт {}, DNS {}", port_text(awg), text(&awg["dns"]))))));
    view.context.push(plain(format!("WARP: {}", if profile["warp"] != true { "выкл." } else if profile["warp_plus"] == true { "вкл., ключ WARP+ задан" } else { "вкл." })));
    let ipv6 = text(&profile["ipv6"]);
    view.context.push(plain(format!("IPv6: {}", IPV6.iter().find(|(v, ..)| *v == ipv6).map_or(ipv6.as_str(), |(_, l, _)| l))));
    view.context.push(plain(format!("Email ACME: {}", text(&profile["acme_email"]))));
    view.context.push(plain(format!("Версия mihomo: {}", text(&profile["mihomo_version"]))));
    let nodes = joined(&profile["nodes"]);
    view.context.push(plain(format!("Ноды: {}", if nodes.is_empty() { "нет" } else { &nodes })));
    if needs_domain(profile) { view.context.push(ui::text("Ноде этого профиля нужен домен", ui::YELLOW)); }
    let mut actions = vec![
        Item::new('y', "Применить на нодах профиля", ui::GREEN), Item::new('e', "Изменить", ui::YELLOW),
        Item::new('w', "Ключ WARP+", ui::YELLOW),
    ];
    if profile["warp_plus"] == true { actions.push(Item::new('u', "Убрать ключ WARP+", ui::RED)); }
    actions.extend([Item::new('d', "Удалить профиль", ui::RED), Item::new(0, "Назад", ui::NC)]);
    view.sections.push(actions);
    view
}
/// «Ключ WARP+»: hidden entry (Enter/EOF — cancel) → `profile warp-license`
/// with the key only in the `password` secret, wiped on any outcome.
fn warp_license(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    let Some(key) = ctx.secret(&format!("Профиль: {name}"), "Ключ WARP+ (Enter — отмена)")? else { return Ok(()); };
    if key.is_empty() { return Ok(()); }
    let mut secrets = Secrets::default();
    secrets.insert_hidden("password", key);
    let reply = ctx.request(&argv(&["profile", "warp-license", "--name", name]), &secrets);
    secrets.clear();
    outcome(ctx, &reply?);
    Ok(())
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
                "e" | "E" => edit_profile(ctx, &name, profile)?,
                "w" | "W" => warp_license(ctx, &name)?,
                "u" | "U" if profile["warp_plus"] == true => {
                    let reply = ctx.call(&["profile", "warp-license", "--name", &name, "--clear"])?;
                    outcome(ctx, &reply);
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

// ─── Каскады ─────────────────────────────────────────────────────────────────

/// (`cascade add --listener` value, connection name) of the cascade listeners and exits.
const CASCADE_PROXIES: [(&str, &str); 4] = [
    ("vless-tcp", "VLESS TCP"), ("vless-xhttp", "VLESS xHTTP"), ("vless-grpc", "VLESS gRPC"), ("hysteria2", "Hysteria2"),
];
/// The cascade-capable connections of a node (`node list .proxies`).
fn cascade_proxies(node: &Value) -> Vec<(&'static str, &'static str)> {
    CASCADE_PROXIES.iter().copied().filter(|(_, proxy)| rows(&node["proxies"]).iter().any(|p| p.as_str() == Some(*proxy))).collect()
}
/// «имя  вход (подключение) → выход»; a URI exit is never returned, only marked.
fn cascade_line(cascade: &Value) -> String {
    let id = text(&cascade["listener"]);
    let listener = CASCADE_PROXIES.iter().find(|(value, _)| *value == id).map_or(id.as_str(), |&(_, label)| label);
    let exit = &cascade["exit"];
    let exit = if exit["uri"] == true { "внешний сервер".to_owned() } else { format!("{} ({})", text(&exit["node"]), text(&exit["proxy"])) };
    format!("{}  {} ({listener}) → {exit}", text(&cascade["name"]), text(&cascade["entry"]))
}
/// The nodes a cascade change leaves waiting for `node apply`: the entry and a node exit.
fn cascade_nodes(cascade: &Value) -> Vec<String> {
    let mut nodes = vec![text(&cascade["entry"])];
    if let Some(exit) = cascade["exit"]["node"].as_str() { nodes.push(exit.to_owned()); }
    nodes
}
/// `cascade list` with add and delete; every change offers `node apply` on its nodes.
impl Screen for Cascades {
    fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> {
        loop {
            let reply = ctx.call(&["cascade", "list"])?;
            if !reply.ok {
                if read_failed(ctx, "Каскады")? { continue; }
                return Ok(Navigation::Back);
            }
            let list = rows(&reply.data["cascades"]);
            let mut view = View::new("Каскады");
            view.prompt = "Выберите действие: ".into();
            if list.is_empty() { view.context.push(ui::text("Нет каскадов", ui::DIM)); }
            view.context.extend(list.iter().map(|cascade| ui::text(cascade_line(cascade), ui::NC)));
            let mut actions = vec![Item::new('a', "Добавить каскад", ui::GREEN)];
            if !list.is_empty() { actions.push(Item::new('d', "Удалить каскад", ui::RED)); }
            actions.push(Item::new(0, "Назад", ui::NC));
            view.sections.push(actions);
            let Some(choice) = ctx.choose(&view)? else { return Ok(Navigation::Back); };
            match choice.as_str() {
                "a" | "A" => add_cascade(ctx)?,
                "d" | "D" if !list.is_empty() => delete_cascade(ctx, list)?,
                "0" => return Ok(Navigation::Back),
                _ => ctx.invalid(),
            }
        }
    }
}
/// Name → entry node (with a profile) → its listener → exit: another profiled
/// node and its connection, or a hidden external-server URI sent as input `file`.
fn add_cascade(ctx: &mut Context<'_>) -> io::Result<()> {
    const TITLE: &str = "Добавление каскада";
    let Some(name) = ask_valid(ctx, TITLE, "Имя каскада, например eu-exit (Enter — отмена)", name_check)? else { return Ok(()); };
    if name.is_empty() { return Ok(()); }
    let listed = ctx.call(&["node", "list"])?;
    if !listed.ok { ctx.failed(); return Ok(()); }
    // Entry and exit nodes serve at least one listener connection (the web's `entryNodes`/`exitNodes`).
    let profiled: Vec<&Value> = rows(&listed.data).iter()
        .filter(|node| !text(&node["profile"]).is_empty() && !cascade_proxies(node).is_empty()).collect();
    if profiled.is_empty() {
        ctx.ui.notice(ui::warn("Нет нод с профилем и включёнными VLESS или Hysteria2 — сначала назначьте ноде профиль."));
        return Ok(());
    }
    let labels: Vec<String> = profiled.iter().map(|node| node_label(node)).collect();
    let Some(i) = ctx.select("Входная нода каскада", &labels)? else { return Ok(()); };
    let entry = text(&profiled[i]["name"]);
    let listeners = cascade_proxies(profiled[i]);
    let labels: Vec<String> = listeners.iter().map(|(_, label)| (*label).to_owned()).collect();
    let Some(i) = ctx.select(&format!("Подключение входа: {entry}"), &labels)? else { return Ok(()); };
    let mut words = argv(&["cascade", "add", "--name", &name, "--entry", &entry, "--listener", listeners[i].0]);
    let kinds: [String; 2] = ["Нода из списка".into(), "URI внешнего сервера".into()];
    let Some(kind) = ctx.select("Выход каскада", &kinds)? else { return Ok(()); };
    let reply = if kind == 0 {
        let exits: Vec<&Value> = profiled.iter().copied().filter(|node| text(&node["name"]) != entry).collect();
        let labels: Vec<String> = exits.iter().map(|node| node_label(node)).collect();
        let Some(i) = ctx.select("Выходная нода каскада", &labels)? else { return Ok(()); };
        let exit = text(&exits[i]["name"]);
        let proxies = cascade_proxies(exits[i]);
        let labels: Vec<String> = proxies.iter().map(|(_, label)| (*label).to_owned()).collect();
        let Some(j) = ctx.select(&format!("Подключение выхода: {exit}"), &labels)? else { return Ok(()); };
        words.extend(argv(&["--exit-node", &exit, "--exit-proxy", proxies[j].1]));
        ctx.request(&words, &Secrets::default())?
    } else {
        let Some(uri) = ctx.secret(TITLE, "URI внешнего сервера vless:// или hysteria2:// (Enter — отмена)")? else { return Ok(()); };
        if uri.trim().is_empty() { return Ok(()); }
        let mut input = Input::default();
        input.insert("file", uri);
        let reply = ctx.request_with(&words, &Secrets::default(), &input);
        input.clear();
        reply?
    };
    if !reply.ok { outcome(ctx, &reply); return Ok(()); }
    offer_apply_on(ctx, &cascade_nodes(&reply.data))
}
/// A cascade of the list → `cascade delete` under its plan; `node apply` on
/// the nodes of the cascade actually deleted (the reply, not the list row).
fn delete_cascade(ctx: &mut Context<'_>, list: &[Value]) -> io::Result<()> {
    let labels: Vec<String> = list.iter().map(cascade_line).collect();
    let Some(i) = ctx.select("Удаление каскада", &labels)? else { return Ok(()); };
    let words = argv(&["cascade", "delete", "--name", &text(&list[i]["name"])]);
    let reply = confirm::run_confirmed(ctx, "Удаление каскада", "Удалить каскад?", &words, &Secrets::default())?;
    if !reply.ok { outcome(ctx, &reply); return Ok(()); }
    offer_apply_on(ctx, &cascade_nodes(&reply.data))
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
        ("node", "warp-reregister", "name="), ("profile", "warp-license", "name= clear"),
        ("cascade", "list", ""), ("cascade", "add", "name= entry= listener= exit-node= exit-proxy="), ("cascade", "delete", "name="),
        ("telegram", "status", "name+ all"), ("telegram", "set", "name= domain="), ("telegram", "remove", "name="),
        ("telegram", "link", "name="), ("telegram", "rotate-secret", "name="), ("telegram", "tag", "name= clear"),
        ("telegram", "restart", "name="), ("telegram", "diagnostics", "name="),
        ("profile", "mihomo-versions", ""), ("subscription", "host", "name= domain= port= remove"),
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
        assert!(!parses(&argv(&["telegram", "status", "--node", "n"])));
        assert!(parses(&argv(&["telegram", "status", "--name", "a", "--name", "b"])));
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
        // The bad ports are refused by the live check, the empty password and tag are warned.
        assert_eq!((ui.rejected.len(), ui.notices.len()), (3, 2));
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
    fn card_routes_harden_and_connections_both_cases() {
        for key in ["h", "H", "p", "P"] {
            let mut steps = vec![show()];
            let mut inputs = vec![key];
            match key.to_ascii_lowercase().as_str() {
                "h" => { inputs.push(""); steps.push(step(&["node", "harden", "--name", "n"], ok(json!({"name": "n", "port": 50000, "auth": "key"})))); }
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
    #[test]
    fn card_warp_line_reregistration_and_apply_offer() {
        let shown = |warp: &str| {
            let mut node = node();
            node["profile"] = json!("edge");
            node["warp"] = json!(warp);
            step(&["node", "show", "--name", "n"], ok(node))
        };
        let words = argv(&["node", "warp-reregister", "--name", "n"]);
        let apply_words = argv(&["node", "apply", "--name", "n"]);
        // Consent → reregistration → the node waits: `node apply --name n` under its plan at once
        // (no own question); a refused plan sends nothing more and offers no apply.
        let (client, ui) = screen(&mut NodeCard("n".into()), &["G", "y", "y", "g", "n", "0"], vec![
            shown("plus"),
            (words.clone(), plan("confirmation_required", "w")), (with_yes(&words, "w"), ok(json!({"name": "n"}))),
            (apply_words.clone(), plan("confirmation_required", "a")), (with_yes(&apply_words, "a"), ok(json!({"applied": ["n"], "failed": [], "unchanged": []}))),
            shown("free"),
            (words.clone(), plan("confirmation_required", "w")),
            shown("free"),
        ]);
        assert_eq!(client.calls.iter().filter(|call| call[..2] == ["node", "warp-reregister"]).count(), 3);
        assert!(noticed(&ui, "Применено: n"));
        assert!(ui.views[0].context.iter().any(|l| l.to_string() == "WARP: WARP+"));
        let item = ui.views[0].sections.iter().flatten().find(|i| i.key == "g").unwrap();
        assert_eq!(item.color, ui::YELLOW);
        assert!(ui.views.iter().any(|v| v.context.iter().any(|l| l.to_string() == "WARP: бесплатный")));
        // Not registered yet: the line says so and reregistration registers it.
        let (client, ui) = screen(&mut NodeCard("n".into()), &["g", "n", "0"], vec![
            shown("none"), (words.clone(), plan("confirmation_required", "w")), shown("none"),
        ]);
        assert_eq!(client.calls.iter().filter(|call| call[..2] == ["node", "warp-reregister"]).count(), 1);
        assert!(ui.views[0].context.iter().any(|l| l.to_string() == "WARP: не зарегистрирован"));
        // WARP off in the profile: no line and no action.
        let (_, ui) = screen(&mut NodeCard("n".into()), &["g", "0"], vec![shown("off"), shown("off")]);
        assert!(noticed(&ui, "Неверный выбор."));
        assert!(!ui.views[0].context.iter().any(|l| l.to_string().starts_with("WARP:")));
        assert!(!ui.views[0].sections.iter().flatten().any(|i| i.key == "g"));
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

    // ─── Telegram ────────────────────────────────────────────────────────────

    /// n1 and n4 have the role (n1 with a tag, n4 waiting for apply); n2 has a
    /// profile without the role; n3 has no profile.
    fn tg_nodes(n1: bool) -> Value {
        json!([
            {"name": "n1", "ip": "192.0.2.1", "port": 22, "profile": "edge", "status": "applied",
                "telegram": if n1 { json!({"hostname": "tg.example.com", "tag": true}) } else { Value::Null }},
            {"name": "n2", "ip": "192.0.2.2", "port": 22, "profile": "edge", "status": "applied", "telegram": null},
            {"name": "n3", "ip": "192.0.2.3", "port": 22, "profile": null, "telegram": null},
            {"name": "n4", "ip": "192.0.2.4", "port": 22, "profile": "edge", "status": "pending", "telegram": {"hostname": "t4.example.com", "tag": false}},
        ])
    }
    fn tg_list() -> (Vec<String>, Reply) { step(&["node", "list"], ok(tg_nodes(true))) }
    fn item_keys(view: &View) -> Vec<String> { view.sections.iter().flatten().map(|i| i.key.clone()).collect() }
    fn applied(name: &str) -> (Vec<String>, Reply) { step(&["node", "apply", "--name", name], ok(json!({"applied": [name], "unchanged": [], "failed": []}))) }
    #[test]
    fn telegram_lists_role_nodes_with_hostname_tag_and_state() {
        let (_, ui) = screen(&mut Telegram, &["0"], vec![tg_list()]);
        let view = &ui.views[0];
        let labels: Vec<(String, Color)> = view.sections[0].iter().map(|i| (i.label.clone(), i.color)).collect();
        assert_eq!(labels, [
            ("n1  tg.example.com  · тег: да  · применено".to_owned(), ui::CYAN),
            ("n4  t4.example.com  · тег: нет  · ожидает применения".to_owned(), ui::YELLOW),
        ]);
        assert_eq!(item_keys(view), ["1", "2", "s", "a", "0"]);
        let (_, ui) = screen(&mut Telegram, &["0"], vec![step(&["node", "list"], ok(json!([])))]);
        assert_eq!(colors(&ui.views[0]), [Some(ui::DIM)]);
        assert_eq!(item_keys(&ui.views[0]), ["s", "a", "0"]);
    }
    #[test]
    fn telegram_status_table_labels_colours_and_summarises_every_row() {
        for key in ["s", "S"] {
            let results = json!({"results": [
                {"node": "a", "hostname": "a.example.com", "code": 0, "status": "ok", "reason": null, "summary": ["web: active"]},
                {"node": "b", "code": 3, "status": "not_installed", "reason": "не установлен", "summary": []},
                {"node": "c", "code": 4, "status": "partial", "reason": "x", "summary": []},
                {"node": "d", "code": 1, "status": "error", "reason": "offline"}]});
            let (_, ui) = screen(&mut Telegram, &[key, "x", "", "0"], vec![tg_list(), step(&["telegram", "status"], err("partial", results)), tg_list()]);
            // The table waits for Enter: an unknown key keeps it on screen.
            let tables: Vec<&View> = ui.views.iter().filter(|v| v.title == "Состояние Telegram Proxy").collect();
            assert_eq!(tables.len(), 2);
            assert_eq!(ui.views.last().unwrap().title, "Telegram Proxy");
            let table = tables[0];
            assert_eq!(colors(table), [Some(ui::GREEN), Some(ui::NC), Some(ui::YELLOW), Some(ui::YELLOW), Some(ui::RED)]);
            let lines: Vec<String> = table.context.iter().map(|l| l.to_string()).collect();
            assert_eq!(lines, ["a  готово  ", "  web: active", "b  не установлено  не установлен", "c  частично  x", "d  ошибка  offline"]);
            assert!(table.sections.is_empty() && !table.prompt.is_empty());
            assert_eq!(ui.notices.len(), 1, "only the invalid key");
        }
        let (_, ui) = screen(&mut Telegram, &["s", "0"], vec![tg_list(), step(&["telegram", "status"], Reply::failure("invalid")), tg_list()]);
        assert_eq!(ui.notices.len(), 1);
    }
    #[test]
    fn telegram_enable_offers_profiled_nodes_without_the_role_then_applies() {
        for key in ["a", "A"] {
            let (client, ui) = screen(&mut Telegram, &[key, "1", "bad", "t2.example.com", "0"], vec![
                tg_list(), step(&["telegram", "set", "--name", "n2", "--domain", "t2.example.com"], ok(json!({"node": "n2", "hostname": "t2.example.com", "tag": false}))),
                applied("n2"), tg_list(),
            ]);
            let select = ui.views.iter().find(|v| v.title == "Включение Telegram Proxy").unwrap();
            assert_eq!(select.sections[0].iter().map(|i| i.label.clone()).collect::<Vec<_>>(), ["n2  192.0.2.2:22", "Отмена"]);
            assert_eq!(ui.rejected, ["bad"]);
            assert_eq!(confirms(&ui), 0, "node apply runs at once; its plan is the only question");
            assert!(client.secret_names.iter().all(Vec::is_empty));
        }
        // Enter cancels the domain; a refused apply plan applies nothing.
        screen(&mut Telegram, &["a", "1", "", "0"], vec![tg_list(), tg_list()]);
        screen(&mut Telegram, &["a", "0", "0"], vec![tg_list(), tg_list()]);
        screen(&mut Telegram, &["a", "1", "t2.example.com", "n", "0"], vec![
            tg_list(), step(&["telegram", "set", "--name", "n2", "--domain", "t2.example.com"], ok(json!({"node": "n2", "hostname": "t2.example.com", "tag": false}))),
            step(&["node", "apply", "--name", "n2"], plan("confirmation_required", "a")), tg_list(),
        ]);
    }
    #[test]
    fn telegram_enable_without_candidates_warns_like_the_web() {
        let mut list = tg_nodes(true);
        list[1]["telegram"] = json!({"hostname": "t2.example.com", "tag": false});
        let listed = || step(&["node", "list"], ok(list.clone()));
        let (_, ui) = screen(&mut Telegram, &["a", "0"], vec![listed(), listed()]);
        assert!(noticed(&ui, "Нет нод с профилем без Telegram Proxy."));
        assert!(!ui.views.iter().any(|v| v.title == "Включение Telegram Proxy"));
    }
    #[test]
    fn telegram_card_actions_and_the_link_stays_off_the_journal() {
        const LINK: &str = "tg://webproxy?server=tg.example.com&port=443&secret=ee0123456789abcdef";
        let link = |name: &str| step(&["telegram", "link", "--name", name], ok(json!({"link": LINK})));
        for key in ["l", "L"] {
            let (client, ui) = screen(&mut Telegram, &["1", key, "", "0", "0"], vec![tg_list(), tg_list(), link("n1"), tg_list(), tg_list()]);
            let card = ui.views.iter().find(|v| v.title == "Telegram Proxy: n1").unwrap();
            assert_eq!(item_keys(card), ["l", "d", "m", "k", "g", "u", "r", "x", "0"]);
            let shown = ui.views.iter().find(|v| v.title == "Ссылка Telegram Proxy: n1").unwrap();
            assert!(shown.context.iter().any(|l| l.to_string() == LINK));
            assert!(!ui.notices.iter().any(|l| l.to_string().contains("secret=")));
            assert!(!ui.logs.iter().any(|l| l.text.contains("secret=")));
            assert!(!client.calls.iter().flatten().any(|w| w.contains("secret=")));
        }
        // Without a tag there is nothing to clear.
        let (_, ui) = screen(&mut Telegram, &["2", "u", "0", "0"], vec![tg_list(), tg_list(), tg_list(), tg_list()]);
        assert!(!item_keys(ui.views.iter().find(|v| v.title == "Telegram Proxy: n4").unwrap()).contains(&"u".to_owned()));
        assert!(noticed(&ui, "Неверный выбор."));
        for key in ["m", "M"] {
            screen(&mut Telegram, &["1", key, "new.example.com", "0", "0"], vec![
                tg_list(), tg_list(), step(&["telegram", "set", "--name", "n1", "--domain", "new.example.com"], ok(json!({"node": "n1", "hostname": "new.example.com", "tag": true}))),
                applied("n1"), tg_list(), tg_list(),
            ]);
        }
        for key in ["u", "U"] {
            let (_, ui) = screen(&mut Telegram, &["1", key, "n", "0", "0"], vec![
                tg_list(), tg_list(), step(&["telegram", "tag", "--name", "n1", "--clear"], ok(json!({"node": "n1", "tag": false}))),
                step(&["node", "apply", "--name", "n1"], plan("confirmation_required", "a")), tg_list(), tg_list(),
            ]);
            assert_eq!(confirms(&ui), 1, "the apply plan, refused");
        }
        for key in ["r", "R"] {
            // The core's plan first; a missing password after consent → saved → the plan again.
            let restart = argv(&["telegram", "restart", "--name", "n1"]);
            let (client, ui) = screen(&mut Telegram, &["1", key, "y", "y", "pw", "y", "0", "0"], vec![
                tg_list(), tg_list(), (restart.clone(), plan("confirmation_required", "r")),
                (with_yes(&restart, "r"), err("missing_secret", json!({"name": "n1", "secret": "password"}))),
                step(&["node", "password", "--name", "n1"], ok(json!({"name": "n1"}))),
                (restart.clone(), plan("confirmation_required", "r")), (with_yes(&restart, "r"), ok(json!({"node": "n1"}))), tg_list(), tg_list(),
            ]);
            assert_eq!(client.secret_names[4], ["password"]);
            assert_eq!(confirms(&ui), 3, "the plan twice and the password question");
            // A refused plan sends nothing more.
            let (client, _) = screen(&mut Telegram, &["1", key, "n", "0", "0"], vec![
                tg_list(), tg_list(), (restart.clone(), plan("confirmation_required", "r")), tg_list(), tg_list(),
            ]);
            assert_eq!(client.calls.iter().filter(|call| call[..2] == ["telegram", "restart"]).count(), 1);
        }
        for key in ["d", "D"] {
            let journal = Reply { logs: vec![Log { level: "info".into(), text: "telegram-web: started".into() }], ..ok(json!({"node": "n1"})) };
            let (_, ui) = screen(&mut Telegram, &["1", key, "0", "0"], vec![tg_list(), tg_list(), step(&["telegram", "diagnostics", "--name", "n1"], journal), tg_list(), tg_list()]);
            assert!(ui.logs.iter().any(|l| l.text == "telegram-web: started"));
        }
    }
    #[test]
    fn telegram_sponsor_tag_is_sent_only_as_the_password_secret() {
        const TAG: &str = "0123456789abcdef0123456789ABCDEF";
        for key in ["g", "G"] {
            let (client, ui) = screen(&mut Telegram, &["1", key, "not-hex", TAG, "0", "0"], vec![
                tg_list(), tg_list(), step(&["telegram", "tag", "--name", "n1"], ok(json!({"node": "n1", "tag": true}))), applied("n1"), tg_list(), tg_list(),
            ]);
            assert_eq!(client.secret_names[2], ["password"]);
            assert!(noticed(&ui, TAG_INVALID));
            assert!(!client.calls.iter().flatten().any(|w| w.contains(TAG) || w.contains("not-hex")));
            assert!(!ui.views.iter().flat_map(View::lines).any(|l| l.to_string().contains(TAG)));
            assert!(!ui.notices.iter().any(|l| l.to_string().contains(TAG)));
        }
        // Enter cancels without a request.
        screen(&mut Telegram, &["1", "g", "", "0", "0"], vec![tg_list(), tg_list(), tg_list(), tg_list()]);
    }
    #[test]
    fn telegram_rotate_and_remove_go_through_the_plan_then_offer_apply() {
        for key in ["k", "K"] {
            let words = argv(&["telegram", "rotate-secret", "--name", "n1"]);
            let (_, ui) = screen(&mut Telegram, &["1", key, "y", "0", "0"], vec![
                tg_list(), tg_list(), (words.clone(), plan("confirmation_required", "rot")), (with_yes(&words, "rot"), ok(json!({"node": "n1"}))),
                applied("n1"), tg_list(), tg_list(),
            ]);
            assert_eq!(confirms(&ui), 1, "the plan; node apply follows at once");
            // A refused plan is no failure and offers nothing.
            let (_, ui) = screen(&mut Telegram, &["1", key, "n", "0", "0"], vec![tg_list(), tg_list(), (words.clone(), plan("confirmation_required", "rot")), tg_list(), tg_list()]);
            assert!(ui.notices.is_empty());
        }
        for key in ["x", "X"] {
            let words = argv(&["telegram", "remove", "--name", "n1"]);
            let gone = || step(&["node", "list"], ok(tg_nodes(false)));
            let (_, ui) = screen(&mut Telegram, &["1", key, "y", "0"], vec![
                tg_list(), tg_list(), (words.clone(), plan("confirmation_required", "rm")), (with_yes(&words, "rm"), ok(json!({"node": "n1"}))),
                applied("n1"), gone(), gone(),
            ]);
            assert_eq!(confirms(&ui), 1);
            assert_eq!(ui.views.last().unwrap().title, "Telegram Proxy", "the card closes once the role is gone");
        }
    }

    // ─── Терминальные команды ────────────────────────────────────────────────

    /// `node shell` is a terminal request, never a plain send.
    fn term(words: &[String], reply: Reply) -> Step { Step::terminal(words.to_vec(), reply) }
    /// An empty script: no request is expected.
    fn none() -> Vec<Step> { Vec::new() }
    #[test]
    fn terminal_commands_run_suspended_as_terminal_requests_both_cases() {
        let words = argv(&["node", "shell", "--name", "n"]);
        for key in ["o", "O"] {
            let (_, ui) = screen(&mut NodeCard("n".into()), &[key, "0"], vec![show().into(), term(&words, ok(json!({}))), show().into()]);
            assert_eq!(ui.suspensions, 1);
            assert!(!ui.suspended_now);
            assert!(!item_keys(&ui.views[0]).contains(&"t".to_owned()), "no Telegram item on the node card");
        }
        let (_, client, ui) = run(vec![
            term(&words, err("missing_secret", json!({"name": "n", "secret": "password"}))),
            step(&["node", "password", "--name", "n"], ok(json!({"name": "n"}))).into(), term(&words, ok(json!({}))),
        ], &["y", "pw"], |ctx| shell(ctx, "n"));
        assert_eq!(ui.suspensions, 2);
        assert_eq!(client.secret_names[1], ["password"]);
    }

    // ─── Профили, применение ─────────────────────────────────────────────────

    fn edge() -> Value {
        json!({"name": "edge", "reality_mode": "self-steal", "sni_domain": null, "site_source": "random", "vless_tcp": true,
            "vless_xhttp": {"topology": "nginx", "port": null}, "vless_grpc": {"port": 20000}, "hysteria2": {"port": 30000, "obfs": true},
            "amneziawg": null, "warp": false, "warp_plus": false, "ipv6": "default", "mihomo_version": "v1.19.18",
            "acme_email": "a@example.com", "nodes": ["n"]})
    }
    fn versions() -> (Vec<String>, Reply) {
        step(&["profile", "mihomo-versions"], ok(json!({"latest": "v1.19.20", "versions": ["v1.19.20", "v1.19.19", "v1.19.18"]})))
    }
    fn no_versions() -> (Vec<String>, Reply) { step(&["profile", "mihomo-versions"], err("failed", json!({"message": "Не удалось получить список версий mihomo."}))) }
    #[test]
    fn profile_wizard_builds_the_add_argv_in_plan_order() {
        // Self-Steal, random site, + xHTTP (nginx), gRPC (port after an invalid one), Hysteria2 (random port, obfs);
        // an invalid name and port are refused by the live check; the latest mihomo from the list.
        let (form, _, ui) = run(vec![versions()], &["VLESS TCP", "edge", "1", "1", "2", "3", "4", "", "2", "70000", "20000", "", "1", "1", "", "1"],
            |ctx| profile_wizard(ctx, None, true));
        assert_eq!(profile_add_argv(&form.unwrap()), argv(&["profile", "add", "--name", "edge", "--reality", "self-steal", "--site-source", "random",
            "--vless-tcp", "on", "--xhttp", "nginx", "--grpc", "on", "--grpc-port", "20000", "--hysteria2", "on", "--hysteria2-obfs", "on",
            "--amneziawg", "off", "--warp", "off", "--ipv6", "default", "--random-acme-email", "--mihomo-version", "v1.19.20"]));
        assert_eq!(ui.rejected, ["VLESS TCP", "70000"]);
        // Every technical choice explains its options above the list.
        for title in ["Режим Reality", "Сайт-заглушка", "Протоколы профиля", "Топология xHTTP", "Hysteria2: обфускация (obfs)", "IPv6", "Версия mihomo"] {
            let view = ui.views.iter().find(|v| v.title == title).unwrap();
            assert!(!view.context.is_empty(), "{title}");
        }
        let topology = ui.views.iter().find(|v| v.title == "Топология xHTTP").unwrap();
        assert_eq!(topology.sections[0].iter().map(|i| i.label.as_str()).collect::<Vec<_>>(), ["Reality — отдельный порт", "Через ваш сайт (nginx, порт 443)", "Отмена"]);
        let version = ui.views.iter().find(|v| v.title == "Версия mihomo").unwrap();
        assert_eq!(version.sections[0].iter().map(|i| i.label.as_str()).collect::<Vec<_>>(),
            ["Последняя (v1.19.20)", "v1.19.19", "v1.19.18", "Ввести вручную", "Отмена"]);
        // SNI: the masking domain is checked; no version list — manual entry with its format hint.
        let (form, _, ui) = run(vec![no_versions()], &["sni", "2", "bad", "www.example.com", "", "3", "me@example.com", "1.19.20", "v1.19.17", "v1.19.20"],
            |ctx| profile_wizard(ctx, None, true));
        assert_eq!(profile_add_argv(&form.unwrap()), argv(&["profile", "add", "--name", "sni", "--reality", "sni", "--sni-domain", "www.example.com",
            "--vless-tcp", "on", "--xhttp", "off", "--grpc", "off", "--hysteria2", "off", "--amneziawg", "off", "--warp", "off", "--ipv6", "disabled",
            "--acme-email", "me@example.com", "--mihomo-version", "v1.19.20"]));
        assert_eq!(ui.rejected, ["bad", "1.19.20", "v1.19.17"]);
        let manual = ui.views.last().unwrap();
        assert!(manual.prompt.contains("vX.Y.Z") && manual.prompt.contains("v1.19.18"));
        assert_eq!(version_check("1.19.20", &[]).unwrap_err().fix.as_deref(), Some("v1.19.20"));
        // «Ввести вручную» from the list.
        let (form, ..) = run(vec![versions()], &["m", "2", "www.example.com", "", "1", "", "4", "v1.19.30"], |ctx| profile_wizard(ctx, None, true));
        assert_eq!(form.unwrap().mihomo_version, "v1.19.30");
        // Cancelled at any question (Enter at the name, Esc later): nothing.
        assert!(run(none(), &[""], |ctx| profile_wizard(ctx, None, true)).0.is_none());
        let (form, _, _) = run(none(), &["edge", "1"], |ctx| profile_wizard(ctx, None, true));
        assert!(form.is_none());
    }
    #[test]
    fn names_are_checked_live_with_a_suggestion() {
        let problem = name_check("VLESS TCP HY2", &[]).unwrap_err();
        assert_eq!((problem.message.as_str(), problem.fix.as_deref()), (NAME_RULE, Some("vless-tcp-hy2")));
        assert!(name_check("edge-full", &[]).is_ok());
        assert_eq!(domain_check("https://Sub.Example.com/path", &[]).unwrap_err().fix.as_deref(), Some("sub.example.com"));
        // The frame draws the failing input red with the rule and the Tab fix (not a taken name) under the prompt.
        let mut view = View::new("Добавление профиля");
        view.prompt = "Имя профиля: ".into();
        view.check = Some(name_check);
        view.taken = vec!["vless-tcp".into()];
        let layout = ui::layout(&view, "VLESS TCP", false, &[], None, 30);
        let prompt: Vec<String> = layout.prompt.iter().map(|l| l.to_string()).collect();
        assert_eq!(prompt[0], "Имя профиля: VLESS TCP");
        assert_eq!(layout.prompt[0].spans.iter().find(|s| s.content == "VLESS TCP").unwrap().style.fg, Some(ui::RED));
        assert!(prompt.iter().any(|l| l.contains("без пробелов")) && prompt.iter().any(|l| l.contains("Tab — подставить «vless-tcp-2»")));
        assert_eq!(ui::layout(&view, "vless-tcp", false, &[], None, 30).prompt.len(), 1);
        // The profiles screen passes its names: the suggestion avoids them.
        let (_, ui) = screen(&mut Profiles, &["a", "", "0"], vec![step(&["profile", "list"], ok(json!({"profiles": [edge()]}))),
            step(&["profile", "list"], ok(json!({"profiles": [edge()]})))]);
        assert_eq!(ui.views[1].taken, ["edge"]);
    }
    /// The core's shared vectors (`core/tests/validation_vectors.json`) hold for the menu's copies.
    #[test]
    fn shared_validation_vectors() {
        let vectors: Value = serde_json::from_str(include_str!("../../core/tests/validation_vectors.json")).unwrap();
        let list = |path: &str| -> Vec<String> { rows(vectors.pointer(path).unwrap()).iter().map(text).collect() };
        let check = |kind: &str, rule: &dyn Fn(&str) -> bool| {
            for value in list(&format!("/{kind}/valid")) { assert!(rule(&value), "{kind} valid: {value:?}"); }
            for value in list(&format!("/{kind}/invalid")) { assert!(!rule(&value), "{kind} invalid: {value:?}"); }
        };
        check("names", &name_valid);
        check("domains", &domain_valid);
        check("ports", &|value| !value.is_empty() && port_valid(value));
        check("emails", &email_valid);
        check("versions", &version_valid);
        for case in rows(&vectors["suggestions"]) {
            let taken: Vec<String> = rows(&case["taken"]).iter().map(text).collect();
            assert_eq!(suggest_name(&text(&case["value"]), &taken).as_deref(), case["suggestion"].as_str(), "{case}");
        }
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
        // The edit wizard keeps every answer on Enter (selectors start at the
        // current item, the nginx topology is not first; the current mihomo
        // version is marked and highlighted): no change, no command.
        let (_, ui) = screen(&mut ProfileCard("edge".into()), &["e", "", "", "", "", "", "", "", "", "", "", "0"], vec![
            step(&["profile", "show", "--name", "edge"], ok(edge())), versions(), step(&["profile", "show", "--name", "edge"], ok(edge())),
        ]);
        assert!(noticed(&ui, "Изменений нет."));
        let topology = ui.views.iter().find(|v| v.title == "Топология xHTTP").unwrap();
        assert_eq!(topology.cursor, Some(1));
        let version = ui.views.iter().find(|v| v.title == "Версия mihomo").unwrap();
        assert_eq!((version.sections[0][2].label.as_str(), version.cursor), ("v1.19.18 (сейчас)", Some(2)));
        let (value, _, _) = run(none(), &[""], |ctx| choose_option(ctx, "IPv6", None, &IPV6, Some("disabled")));
        assert_eq!(value.as_deref(), Some("disabled"));
        // A current version no longer listed is offered right after the latest.
        let (version, ..) = run(vec![step(&["profile", "mihomo-versions"], ok(json!({"latest": "v1.19.30", "versions": ["v1.19.30"]})))], &["2"],
            |ctx| choose_version(ctx, "t", Some("v1.19.18")));
        assert_eq!(version.as_deref(), Some("v1.19.18"));
        assert!(needs_domain(&edge()) && !needs_domain(&json!({"reality_mode": "sni", "vless_tcp": true})));
    }
    #[test]
    fn failed_profile_add_or_set_reopens_the_wizard_with_the_answers() {
        let list = || step(&["profile", "list"], ok(json!({"profiles": []})));
        let first = ProfileForm { name: "edge".into(), ..ProfileForm::default() };
        let second = ProfileForm { name: "edge2".into(), ..first.clone() };
        let mut renamed = edge();
        renamed["name"] = json!("edge2");
        // `exists`: the name is asked again with the old one kept by Enter, the
        // other answers are kept; the corrected add opens the card. Without
        // the version list the version is typed (Enter — the latest).
        let (client, ui) = screen(&mut Profiles, &["a", "edge", "1", "1", "", "1", "", "", "edge2", "", "", "", "", "", "", "0", "0"], vec![
            list(), no_versions(), (profile_add_argv(&first), err("exists", json!({}))), no_versions(), (profile_add_argv(&second), ok(json!({"name": "edge2"}))),
            step(&["profile", "show", "--name", "edge2"], ok(renamed)), list(),
        ]);
        assert!(ui.views.iter().any(|v| v.prompt.contains("Имя профиля [edge]")));
        assert_eq!(client.calls.len(), 7);
        // A failed `profile set` reopens the edit wizard with the changed IPv6
        // (now the current item); Enter everywhere repeats the same command.
        let set = argv(&["profile", "set", "--name", "edge", "--ipv6", "enabled"]);
        let show = || step(&["profile", "show", "--name", "edge"], ok(edge()));
        let mut keys = vec!["e", "", "", "", "", "", "", "", "2", "", ""];
        keys.extend([""; 10]);
        keys.push("0");
        let (_, ui) = screen(&mut ProfileCard("edge".into()), &keys, vec![
            show(), no_versions(), (set.clone(), err("locked", json!({}))), show(), no_versions(), (set, ok(json!({}))), show(),
        ]);
        let ipv6: Vec<_> = ui.views.iter().filter(|v| v.title == "IPv6").collect();
        assert_eq!(ipv6.iter().map(|v| v.cursor).collect::<Vec<_>>(), [Some(0), Some(1)]);
        // Cancelling the reopened wizard sends nothing more.
        screen(&mut ProfileCard("edge".into()), &["e", "", "", "", "", "", "", "", "2", "", "", "0", "0"], vec![
            show(), no_versions(), (argv(&["profile", "set", "--name", "edge", "--ipv6", "enabled"]), err("locked", json!({}))), show(), show(),
        ]);
        // The failed set was saved (checkpoint error after the local write):
        // the retry is computed against the re-read profile, so returning
        // IPv6 to «default» is sent along with the new email.
        let mut saved = edge();
        saved["ipv6"] = json!("disabled");
        let mut keys = vec!["e", "", "", "", "", "", "", "", "3", "", ""];
        keys.extend(["", "", "", "", "", "", "", "1", "b@example.com", "", "0"]);
        let (_, ui) = screen(&mut ProfileCard("edge".into()), &keys, vec![
            show(), no_versions(), (argv(&["profile", "set", "--name", "edge", "--ipv6", "disabled"]), err("checkpoint_failed", json!({}))),
            step(&["profile", "show", "--name", "edge"], ok(saved)), no_versions(),
            (argv(&["profile", "set", "--name", "edge", "--ipv6", "default", "--acme-email", "b@example.com"]), ok(json!({}))), show(),
        ]);
        let ipv6: Vec<_> = ui.views.iter().filter(|v| v.title == "IPv6").collect();
        assert_eq!(ipv6[1].cursor, Some(2), "the reopened wizard shows the user's answer");
    }
    #[test]
    fn bulk_apply_resolves_node_codes_of_failed_nodes_and_repeats_once() {
        let words = argv(&["node", "apply", "--pending"]);
        let entry = json!({"name":"de","stage":"probe","code":"missing_secret","message":"Пароль SSH для «de» не сохранён."});
        let partial = || err("partial", json!({"applied": [], "unchanged": [], "failed": [entry.clone()]}));
        let (reply, client, _) = run(vec![
            (words.clone(), plan("confirmation_required", "a")), (with_yes(&words, "a"), partial()),
            step(&["node", "password", "--name", "de"], ok(json!({"name": "de"}))),
            (words.clone(), plan("confirmation_required", "b")), (with_yes(&words, "b"), ok(json!({"applied": ["de"], "failed": [], "unchanged": []}))),
        ], &["y", "y", "pw", "y"], |ctx| apply(ctx, &words, ""));
        assert!(reply.ok);
        assert_eq!(client.secret_names[2], ["password"]);
        // Refusing to save the password keeps the report without repeating.
        let (reply, client, _) = run(vec![(words.clone(), plan("confirmation_required", "a")), (with_yes(&words, "a"), partial())],
            &["y", "n"], |ctx| apply(ctx, &words, ""));
        assert_eq!(reply.code(), "partial");
        assert_eq!(client.calls.len(), 2);
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
    fn profile_warp_license_is_a_hidden_secret_and_clear_needs_a_key() {
        let show = |plus: bool| {
            let mut profile = edge();
            profile["warp"] = json!(true);
            profile["warp_plus"] = json!(plus);
            step(&["profile", "show", "--name", "edge"], ok(profile))
        };
        // Key → `password` secret; Enter cancels; «Убрать» only with a key (U then invalid).
        let (client, ui) = screen(&mut ProfileCard("edge".into()), &["w", "WARP-PLUS-KEY", "W", "", "u", "U", "0"], vec![
            show(false), step(&["profile", "warp-license", "--name", "edge"], ok(json!({"name": "edge", "warp_plus": true}))),
            show(true), show(true),
            step(&["profile", "warp-license", "--name", "edge", "--clear"], ok(json!({"name": "edge", "warp_plus": false}))),
            show(false), show(false),
        ]);
        assert_eq!(client.secret_names[1], ["password"]);
        assert!(client.secret_names[4].is_empty());
        assert!(!client.calls.iter().flatten().any(|w| w.contains("WARP-PLUS-KEY")));
        assert!(!ui.views.iter().flat_map(View::lines).any(|l| l.to_string().contains("WARP-PLUS-KEY")));
        assert!(noticed(&ui, "Неверный выбор."));
        let keys = |view: &View| view.sections.iter().flatten().map(|i| i.key.clone()).collect::<Vec<_>>();
        assert_eq!(keys(&ui.views[0]), ["y", "e", "w", "d", "0"]);
        let with_key = ui.views.iter().find(|v| keys(v).contains(&"u".to_owned())).unwrap();
        assert_eq!(with_key.sections.iter().flatten().find(|i| i.key == "u").unwrap().color, ui::RED);
        assert!(with_key.context.iter().any(|l| l.to_string() == "WARP: вкл., ключ WARP+ задан"));
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
        assert_eq!(ui.rejected, ["bad"]);
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
            {"name":"de","stage":"probe","code":"unsupported_os","message":"ОС ноды «ubuntu 25.10» не поддерживается: нужна Debian 12/13 или Ubuntu 22.04/24.04/26.04 с systemd"}]}));
        let (_, _, ui) = run(vec![(words.clone(), plan("confirmation_required", "a")), (with_yes(&words, "a"), partial)], &["y"], |ctx| apply(ctx, &words, ""));
        for line in ["Применено: a", "de: откат на этапе «конфигурация и проверка»", "de: порт 443 уже занят",
            "de: Не удалось подключиться к «de».", "de: ОС ноды «ubuntu 25.10» не поддерживается: нужна Debian 12/13 или Ubuntu 22.04/24.04/26.04 с systemd"] {
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
        pending["profile"] = json!("edge");
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
        ], &["", "192.0.2.1", "", "", "1", "tag", "2", "de.example.com", "", "", "y"], add_node);
        assert_eq!(client.calls.len(), 4);
        // «Без профиля»: no domain, no role questions, no apply.
        run(vec![step(&["profile", "list"], ok(json!({"profiles": [edge()]}))), (add_words("key", ACCEPT), added(false))],
            &["", "192.0.2.1", "", "", "1", "tag", "1"], add_node);
    }
    #[test]
    fn add_with_role_domains_sets_them_before_one_apply() {
        let words = add_words("key", &["--profile", "edge", "--domain", "de.example.com", "--accept-new-host-key"]);
        let apply = argv(&["node", "apply", "--name", "vps-1", "--name", "old"]);
        let host = step(&["subscription", "host"], ok(json!({"node": "old", "hostname": "sub.old.example.com", "port": 443})));
        // An invalid name is refused live; a role domain equal to the node's is asked again; the host moves after a confirmation.
        let (_, client, ui) = run(vec![
            step(&["profile", "list"], ok(json!({"profiles": [edge()]}))), (words, added(false)),
            step(&["telegram", "set", "--name", "vps-1", "--domain", "tg.example.com"], ok(json!({}))),
            host, step(&["subscription", "host", "--name", "vps-1", "--domain", "sub.example.com"], ok(json!({}))),
            (apply.clone(), plan("confirmation_required", "a")), (with_yes(&apply, "a"), ok(json!({"applied": ["vps-1", "old"], "failed": [], "unchanged": []}))),
        ], &["my vps", "", "192.0.2.1", "", "", "1", "tag", "2", "de.example.com", "de.example.com", "tg.example.com", "bad", "sub.example.com", "y", "y"], add_node);
        assert_eq!(client.calls.len(), 7);
        assert_eq!(ui.rejected, ["my vps", "bad"]);
        assert!(noticed(&ui, DOMAIN_TAKEN));
        assert!(ui.views.iter().any(|v| v.context.iter().any(|l| l.to_string().contains("нода «old»"))));
        // A refused move keeps the old host; the node is applied alone.
        let apply = argv(&["node", "apply", "--name", "vps-1"]);
        run(vec![
            step(&["profile", "list"], ok(json!({"profiles": [edge()]}))), (add_words("key", &["--profile", "edge", "--domain", "de.example.com", "--accept-new-host-key"]), added(false)),
            step(&["subscription", "host"], ok(json!({"node": "old", "hostname": "sub.old.example.com", "port": 443}))),
            (apply.clone(), plan("confirmation_required", "a")), (with_yes(&apply, "a"), ok(json!({"applied": ["vps-1"], "failed": [], "unchanged": []}))),
        ], &["", "192.0.2.1", "", "", "1", "tag", "2", "de.example.com", "", "sub.example.com", "n", "y"], add_node);
    }
    #[test]
    fn add_wizard_retries_or_skips_a_failed_role_and_defers_apply_without_ssh() {
        let words = || add_words("key", &["--profile", "edge", "--domain", "de.example.com", "--accept-new-host-key"]);
        let apply = argv(&["node", "apply", "--name", "vps-1"]);
        let applied = || ok(json!({"applied": ["vps-1"], "failed": [], "unchanged": []}));
        // A failed `telegram set`: «Повторить» with a new domain, then one apply.
        let (_, client, ui) = run(vec![
            step(&["profile", "list"], ok(json!({"profiles": [edge()]}))), (words(), added(false)),
            step(&["telegram", "set", "--name", "vps-1", "--domain", "tg.example.com"], err("invalid", json!({"message": "занят"}))),
            step(&["telegram", "set", "--name", "vps-1", "--domain", "tg2.example.com"], ok(json!({}))),
            (apply.clone(), plan("confirmation_required", "a")), (with_yes(&apply, "a"), applied()),
        ], &["", "192.0.2.1", "", "", "1", "tag", "2", "de.example.com", "tg.example.com", "", "1", "tg2.example.com", "y"], add_node);
        assert_eq!(client.calls.len(), 6);
        assert!(noticed(&ui, "Роли и домены"));
        // A failed `subscription host`: «Пропустить», the node is still applied.
        run(vec![
            step(&["profile", "list"], ok(json!({"profiles": [edge()]}))), (words(), added(false)),
            step(&["subscription", "host"], ok(Value::Null)),
            step(&["subscription", "host", "--name", "vps-1", "--domain", "sub.example.com"], err("invalid", json!({}))),
            (apply.clone(), plan("confirmation_required", "a")), (with_yes(&apply, "a"), applied()),
        ], &["", "192.0.2.1", "", "", "1", "tag", "2", "de.example.com", "", "sub.example.com", "2", "y"], add_node);
        // Deferred SSH setup: roles are saved, nothing is applied, what is left is said.
        let (_, _, ui) = run(vec![
            step(&["profile", "list"], ok(json!({"profiles": [edge()]}))), (words(), added(true)),
            step(&["telegram", "set", "--name", "vps-1", "--domain", "tg.example.com"], ok(json!({}))),
        ], &["", "192.0.2.1", "", "", "1", "tag", "2", "de.example.com", "tg.example.com", ""], add_node);
        assert!(noticed(&ui, "Применение отложено"));
        // SSH ports follow the core: `080` is accepted, `000080` and `0` are refused live.
        let (_, _, ui) = run(vec![no_profiles(), (argv(&["node", "add", "--name", "vps-1", "--ip", "192.0.2.1", "--port", "080", "--user", "root",
            "--auth", "key", "--tag", "tag", "--accept-new-host-key"]), added(false))],
            &["", "192.0.2.1", "000080", "0", "080", "", "1", "tag"], add_node);
        assert_eq!(ui.rejected, ["000080", "0"]);
    }
    fn profiled_node() -> Value {
        let mut node = node();
        node["profile"] = json!("edge");
        node["domain"] = json!("de.example.com");
        node["status"] = json!("applied");
        node
    }
    #[test]
    fn card_lists_roles_and_domains_with_actions() {
        let card = |node: &Value| card_view("n", node, false);
        let text_of = |view: &View| view.context.iter().map(|l| l.to_string()).collect::<Vec<_>>().join("\n");
        // Without a profile: «Указать профиль», roles need the profile first, no role actions.
        let bare = card(&node());
        assert!(text_of(&bare).contains("Профиль: не указан"));
        assert!(text_of(&bare).contains("Telegram Web Proxy: выключен (сначала укажите профиль)"));
        assert_eq!(bare.sections[1].iter().map(|i| (i.key.as_str(), i.label.as_str())).collect::<Vec<_>>(), [("f", "Указать профиль"), ("m", "Задать домен ноды")]);
        // With a profile and without roles: each domain explained, each role offered.
        let view = card(&profiled_node());
        let context = text_of(&view);
        for needle in ["Роли и домены:", "Домен ноды (сайт-заглушка, Reality): de.example.com", "Telegram Web Proxy: выключен", "Хост подписок: не назначен",
            ROLE_DOMAIN, ROLE_TELEGRAM, ROLE_SUBSCRIPTION] {
            assert!(context.contains(needle), "{needle}");
        }
        assert_eq!(view.sections[1].iter().map(|i| i.label.as_str()).collect::<Vec<_>>(),
            ["Профиль", "Домен ноды", "Включить Telegram Web Proxy", "Сделать хостом подписок"]);
        // With both roles: their domains (a non-443 port is shown).
        let mut roles = profiled_node();
        roles["telegram"] = json!({"hostname": "tg.example.com", "tag": false});
        roles["subscription"] = json!({"hostname": "sub.example.com", "port": 8443});
        let context = text_of(&card(&roles));
        assert!(context.contains("Telegram Web Proxy: tg.example.com") && context.contains("Хост подписок: sub.example.com:8443"));
    }
    #[test]
    fn card_role_actions_send_the_role_commands_and_offer_apply() {
        let shown = || step(&["node", "show", "--name", "n"], ok(profiled_node()));
        let apply = argv(&["node", "apply", "--name", "n"]);
        // «Включить Telegram Web Proxy»: domain → telegram set → node apply under its plan.
        screen(&mut NodeCard("n".into()), &["t", "tg.example.com", "y", "0"], vec![
            shown(), step(&["telegram", "set", "--name", "n", "--domain", "tg.example.com"], ok(json!({}))),
            (apply.clone(), plan("confirmation_required", "a")), (with_yes(&apply, "a"), ok(json!({"applied": ["n"], "failed": [], "unchanged": []}))),
            shown(),
        ]);
        // «Сделать хостом подписок»: no host yet, domain (the node's own is refused,
        // in any case) and port → subscription host.
        let (_, ui) = screen(&mut NodeCard("n".into()), &["S", "de.example.com", "DE.Example.com", "sub.example.com", "8443", "n", "0"], vec![
            shown(), step(&["subscription", "host"], ok(Value::Null)),
            step(&["subscription", "host", "--name", "n", "--domain", "sub.example.com", "--port", "8443"], ok(json!({}))),
            (apply.clone(), plan("confirmation_required", "a")), shown(),
        ]);
        assert_eq!(ui.notices.iter().filter(|l| l.to_string().contains(DOMAIN_TAKEN)).count(), 2);
        assert_eq!(confirms(&ui), 1, "the apply plan only");
        // The host on another node: the move is confirmed first; refused — nothing sent.
        let (client, ui) = screen(&mut NodeCard("n".into()), &["s", "sub.example.com", "", "n", "0"], vec![
            shown(), step(&["subscription", "host"], ok(json!({"node": "old", "hostname": "sub.old.example.com", "port": 443}))), shown(),
        ]);
        assert!(!client.calls.iter().any(|call| call.len() > 2 && call[..2] == ["subscription", "host"]));
        assert!(ui.views.iter().any(|v| v.prompt.contains("Перенести хост подписок")));
    }
    #[test]
    fn unprofiled_nodes_get_their_profile_from_the_list_or_a_new_one() {
        // The list offers «Указать профиль»: one node without a profile — straight to the profiles.
        let set = argv(&["node", "profile", "--name", "n", "--profile", "edge"]);
        let apply = argv(&["node", "apply", "--name", "n"]);
        let (_, ui) = screen(&mut Nodes, &["f", "2", "y", "0"], vec![
            step(&["node", "list"], ok(json!([node()]))), step(&["status"], ok(json!({}))),
            step(&["profile", "list"], ok(json!({"profiles": [edge()]}))), (set.clone(), ok(json!({}))),
            (apply.clone(), plan("confirmation_required", "a")), (with_yes(&apply, "a"), ok(json!({"applied": ["n"], "failed": [], "unchanged": []}))),
            step(&["node", "list"], ok(json!([profiled_node()]))), step(&["status"], ok(json!({}))),
        ]);
        let select = ui.views.iter().find(|v| v.title == "Профиль ноды: n").unwrap();
        assert_eq!(select.sections[0].iter().map(|i| i.label.as_str()).collect::<Vec<_>>(), ["Без профиля (сейчас)", "edge", "Отмена"]);
        assert!(!ui.views.last().unwrap().sections.iter().flatten().any(|item| item.key == "f"));
        // No profiles yet: the wizard is offered, the new profile is set.
        let add = argv(&["profile", "add", "--name", "edge", "--reality", "sni", "--sni-domain", "www.example.com", "--vless-tcp", "on", "--xhttp", "off",
            "--grpc", "off", "--hysteria2", "off", "--amneziawg", "off", "--warp", "off", "--ipv6", "default", "--random-acme-email", "--mihomo-version", "v1.19.20"]);
        run(vec![
            step(&["profile", "list"], ok(json!({"profiles": []}))), versions(), (add, ok(json!({"name": "edge"}))), (set.clone(), ok(json!({}))),
            (apply.clone(), plan("confirmation_required", "a")),
        ], &["y", "edge", "2", "www.example.com", "", "1", "", "1", "n"], |ctx| node_profile(ctx, "n", &node()));
        // Refused: nothing is created.
        run(vec![step(&["profile", "list"], ok(json!({"profiles": []})))], &["n"], |ctx| node_profile(ctx, "n", &node()));
    }
    #[test]
    fn card_profile_domain_and_ports_send_only_changes() {
        let mut with_profile = node();
        with_profile["profile"] = json!("edge");
        with_profile["ports"] = json!({"hysteria2": 31000});
        let apply = || step(&["node", "apply", "--name", "n"], plan("confirmation_required", "a"));
        run(vec![step(&["profile", "list"], ok(json!({"profiles": [edge()]}))), step(&["node", "profile", "--name", "n", "--profile", "edge"], ok(json!({}))), apply()],
            &["2", "n"], |ctx| node_profile(ctx, "n", &node()));
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

    // ─── Каскады ─────────────────────────────────────────────────────────────

    fn cascade_nodes_list() -> (Vec<String>, Reply) {
        step(&["node", "list"], ok(json!([
            {"name": "de", "ip": "192.0.2.1", "port": 22, "profile": "edge", "proxies": ["VLESS TCP", "Hysteria2", "eu"]},
            {"name": "bare", "ip": "192.0.2.2", "port": 22, "profile": null, "proxies": []},
            {"name": "ru", "ip": "192.0.2.3", "port": 22, "profile": "edge", "proxies": ["VLESS gRPC", "VLESS xHTTP"]},
            {"name": "aw", "ip": "192.0.2.4", "port": 22, "profile": "awg", "proxies": ["AWG"]}])))
    }
    fn cascades(list: Value) -> (Vec<String>, Reply) { step(&["cascade", "list"], ok(json!({"cascades": list}))) }
    fn via_ru() -> Value { json!({"name": "eu", "entry": "de", "listener": "hysteria2", "exit": {"node": "ru", "proxy": "VLESS gRPC"}}) }
    fn via_uri() -> Value { json!({"name": "ext", "entry": "de", "listener": "vless-tcp", "exit": {"uri": true}}) }
    fn labels(view: &View) -> Vec<String> { view.sections.iter().flatten().map(|item| item.label.clone()).collect() }
    #[test]
    fn cascade_add_through_a_node_exit_offers_apply_on_both_nodes() {
        let add = argv(&["cascade", "add", "--name", "eu", "--entry", "de", "--listener", "hysteria2", "--exit-node", "ru", "--exit-proxy", "VLESS gRPC"]);
        let apply = argv(&["node", "apply", "--name", "de", "--name", "ru"]);
        // Name, entry de, listener Hysteria2, «Нода из списка», exit ru, VLESS gRPC, the apply plan (no own question).
        let (client, ui) = screen(&mut Cascades, &["a", "eu", "1", "2", "1", "1", "2", "y", "0"], vec![
            cascades(json!([])), cascade_nodes_list(), (add, ok(via_ru())),
            (apply.clone(), plan("confirmation_required", "a")), (with_yes(&apply, "a"), ok(json!({"applied": ["de", "ru"], "failed": [], "unchanged": []}))),
            cascades(json!([via_ru()])),
        ]);
        assert!(client.input_names.iter().all(Vec::is_empty));
        assert!(noticed(&ui, "Применено: de, ru"));
        let titled = |title: &str| ui.views.iter().find(|v| v.title == title).unwrap();
        // Only profiled nodes; only the four listener connections (not a cascade name); never the entry as exit.
        assert_eq!(labels(titled("Входная нода каскада")), ["de  192.0.2.1:22", "ru  192.0.2.3:22", "Отмена"]);
        assert_eq!(labels(titled("Подключение входа: de")), ["VLESS TCP", "Hysteria2", "Отмена"]);
        assert_eq!(labels(titled("Выходная нода каскада")), ["ru  192.0.2.3:22", "Отмена"]);
        assert_eq!(labels(titled("Подключение выхода: ru")), ["VLESS xHTTP", "VLESS gRPC", "Отмена"]);
        assert!(!ui.views.iter().any(|v| v.prompt.contains("сейчас?")), "no question before the core's plan");
        let last = ui.views.last().unwrap();
        assert!(last.context.iter().any(|l| l.to_string() == "eu  de (Hysteria2) → ru (VLESS gRPC)"));
    }
    #[test]
    fn cascade_uri_exit_is_hidden_input_file_and_applies_only_the_entry() {
        const URI: &str = "vless://SECRET-UUID@203.0.113.1:443?security=reality";
        let add = argv(&["cascade", "add", "--name", "ext", "--entry", "de", "--listener", "vless-tcp"]);
        let apply = argv(&["node", "apply", "--name", "de"]);
        let registry = Registry { screens: vec![], github_wizard: None };
        let mut client = ScriptedClient::new([
            cascade_nodes_list(), (add, ok(via_uri())),
            (apply.clone(), plan("confirmation_required", "a")), (with_yes(&apply, "a"), ok(json!({"applied": ["de"], "failed": [], "unchanged": []}))),
        ]);
        let mut ui = HiddenUi { script: ScriptedUi::new(&["ext", "1", "1", "2", URI, "y"]), hidden: vec![] };
        add_cascade(&mut Context::for_test(&mut client, &mut ui, &registry)).unwrap();
        client.assert_finished();
        assert_eq!(ui.hidden, [false, false, false, false, true, false]);
        assert_eq!(client.input_names[1], ["file"]);
        assert!(client.secret_names.iter().all(Vec::is_empty));
        assert!(!client.calls.iter().flatten().any(|w| w.contains("SECRET-UUID")));
        assert!(!ui.script.views.iter().flat_map(View::lines).any(|l| l.to_string().contains("SECRET-UUID")));
        assert!(noticed(&ui.script, "Применено: de"));
        // Enter at the URI cancels without a request.
        let (_, client, _) = run(vec![cascade_nodes_list()], &["ext", "1", "1", "2", ""], add_cascade);
        assert_eq!(client.calls.len(), 1);
    }
    #[test]
    fn cascade_add_without_listener_nodes_warns_and_asks_nothing_more() {
        let list = step(&["node", "list"], ok(json!([{"name": "aw", "ip": "192.0.2.4", "port": 22, "profile": "awg", "proxies": ["AWG"]},
            {"name": "bare", "ip": "192.0.2.2", "port": 22, "profile": null, "proxies": []}])));
        let (_, client, ui) = run(vec![list], &["ext"], add_cascade);
        assert_eq!(client.calls.len(), 1);
        assert!(noticed(&ui, "Нет нод с профилем и включёнными VLESS или Hysteria2"));
        assert!(!ui.views.iter().any(|v| v.title == "Входная нода каскада"));
    }
    #[test]
    fn cascade_delete_is_plan_gated_and_applies_on_the_nodes_of_the_deleted_cascade() {
        let delete = argv(&["cascade", "delete", "--name", "eu"]);
        // Recreated after the list was read: the deleted cascade (the reply) runs fr → nl, not de → ru.
        let deleted = json!({"name": "eu", "entry": "fr", "listener": "hysteria2", "exit": {"node": "nl", "proxy": "VLESS gRPC"}});
        let apply = argv(&["node", "apply", "--name", "fr", "--name", "nl"]);
        // A refused plan deletes nothing; a confirmed one goes straight to the apply plan (refused here).
        let (client, ui) = screen(&mut Cascades, &["D", "2", "n", "d", "2", "y", "n", "0"], vec![
            cascades(json!([via_uri(), via_ru()])), (delete.clone(), plan("confirmation_required", "d")),
            cascades(json!([via_uri(), via_ru()])), (delete.clone(), plan("confirmation_required", "d")), (with_yes(&delete, "d"), ok(deleted)),
            (apply, plan("confirmation_required", "a")),
            cascades(json!([via_uri()])),
        ]);
        assert!(!client.calls.iter().any(|call| call.contains(&"--yes".to_owned()) && call[0] == "node"), "a refused plan applies nothing");
        assert!(!ui.views.iter().any(|v| v.prompt.contains("сейчас?")), "no question before the core's plan");
        assert_eq!(confirms(&ui), 3);
        assert!(ui.views[0].context.iter().any(|l| l.to_string() == "ext  de (VLESS TCP) → внешний сервер"));
        let actions: Vec<_> = ui.views[0].sections.iter().flatten().map(|i| (i.key.clone(), i.color)).collect();
        assert_eq!(actions, [("a".to_owned(), ui::GREEN), ("d".to_owned(), ui::RED), ("0".to_owned(), ui::NC)]);
    }
    #[test]
    fn empty_cascades_offer_only_add_and_no_profiled_node_ends_the_add() {
        let (client, ui) = screen(&mut Cascades, &["d", "A", "eu", "0"], vec![
            cascades(json!([])), cascades(json!([])),
            step(&["node", "list"], ok(json!([{"name": "bare", "ip": "192.0.2.2", "port": 22, "profile": null, "proxies": []}]))),
            cascades(json!([])),
        ]);
        assert!(noticed(&ui, "Неверный выбор."));
        assert!(!client.calls.iter().any(|call| call[..2] == ["cascade", "add"]));
        assert_eq!(labels(&ui.views[0]), ["Добавить каскад", "Назад"]);
        assert!(ui.views[0].context.iter().any(|l| l.to_string() == "Нет каскадов"));
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
        assert_eq!(view.sections[0][0].label, "n  192.0.2.1:22  · профиль не указан");
        assert_eq!(view.sections[1].iter().map(|i| (i.key.as_str(), i.color)).collect::<Vec<_>>(), [("a", ui::GREEN), ("f", ui::GREEN), ("h", ui::YELLOW), ("0", ui::NC)]);
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
        for key in ['n', 't', 'p', 'k'] { assert!(registry.screens.iter().any(|entry| entry.key == key)); }
        assert!(!registry.screens.iter().any(|entry| entry.key == 'a'), "the AmneziaWG screen is gone");
    }
}
