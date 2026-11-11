//! Clients, groups/templates, generation and subscriptions: serve-only screens
//! (v1 `tui/clients.sh` plus the share bundle of `tui/client.sh`).
//!
//! Deliberate v1 fixes: the TTL is a cancellable menu (12h/30d/2w, keep/none,
//! or a custom value) instead of free text; a built-in template shows no
//! `null` path; EOF while answering a question cancels only that action;
//! editor changes are imported through the same frozen-plan confirmation as
//! file imports (v1 passed a blind `--yes`); read failures of a screen offer
//! an explicit retry. Partial results are read from `error` (serve v2 sends
//! no `data` with a failure).
use std::{env, fs, io::{self, Write}, path::{Path, PathBuf}, process::{Command, Stdio}};
use ratatui::{style::Style, text::{Line, Span}};
use serde_json::Value;
use crate::{app::{Context, Navigation, Screen}, confirm::run_confirmed, serve::{argv, Reply, Secrets}, ui::{self, Item, View}};

pub struct Clients;
pub struct Groups;
pub struct Templates;
pub struct Generate;
pub struct Subscriptions;
impl Screen for Clients { fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> { clients(ctx)?; Ok(Navigation::Back) } }
impl Screen for Groups { fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> { groups(ctx)?; Ok(Navigation::Back) } }
impl Screen for Templates { fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> { templates(ctx)?; Ok(Navigation::Back) } }
impl Screen for Generate { fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> { generation(ctx)?; Ok(Navigation::Back) } }
impl Screen for Subscriptions { fn run(&mut self, ctx: &mut Context<'_>) -> io::Result<Navigation> { subscriptions(ctx)?; Ok(Navigation::Back) } }

// ─── Shared helpers ──────────────────────────────────────────────────────────

/// Empty multi-select state of this module's toggles.
const EMPTY: &str = "Нет вариантов для выбора";
fn text(v: &Value) -> &str { v.as_str().unwrap_or("—") }
fn scalar(v: &Value) -> String {
    match v { Value::String(s) => s.clone(), Value::Null => "—".into(), other => other.to_string() }
}
fn rows(v: &Value) -> &[Value] { v.as_array().map(Vec::as_slice).unwrap_or_default() }
fn names(v: &Value) -> Vec<String> { rows(v).iter().filter_map(|r| r["name"].as_str().map(str::to_owned)).collect() }
fn strings(v: &Value) -> Vec<String> { rows(v).iter().filter_map(|r| r.as_str().map(str::to_owned)).collect() }
fn joined(v: &Value) -> String { let items = strings(v); if items.is_empty() { "нет".into() } else { items.join(", ") } }
fn find_row(data: &Value, name: &str) -> Option<Value> { rows(data).iter().find(|r| r["name"] == name).cloned() }
fn index(input: &str, count: usize) -> Option<usize> {
    if input.is_empty() || input.starts_with('0') || !input.bytes().all(|b| b.is_ascii_digit()) { return None; }
    input.parse::<usize>().ok().filter(|n| *n > 0 && *n <= count).map(|n| n - 1)
}
fn back() -> Item { Item::new(0, "Назад", ui::NC) }
fn colored(label: &str, color: ratatui::style::Color, rest: &str) -> Line<'static> {
    Line::from(vec![Span::styled(label.to_owned(), Style::default().fg(color)), Span::raw(rest.to_owned())])
}
/// One question; `None` on EOF (cancels the action, not the screen).
fn ask(ctx: &mut Context<'_>, title: &str) -> io::Result<Option<String>> {
    let mut view = View::new(title);
    view.prompt = format!("{title}: ");
    ctx.choose(&view)
}
fn required(ctx: &mut Context<'_>, title: &str, missing: &str) -> io::Result<Option<String>> {
    let answer = ask(ctx, title)?;
    if answer.as_deref() == Some("") { ctx.ui.notice(ui::warn(missing)); return Ok(None); }
    Ok(answer)
}
/// Read-only frame: kept until Enter/0/EOF, without pseudo-hotkeys.
fn present(ctx: &mut Context<'_>, view: &View) -> io::Result<()> {
    let mut view = view.clone();
    view.prompt = "Enter — продолжить: ".into();
    loop {
        match ctx.choose(&view)?.as_deref() {
            None | Some("") | Some("0") => return Ok(()),
            _ => ctx.invalid(),
        }
    }
}
fn execute(ctx: &mut Context<'_>, words: &[&str]) -> io::Result<Reply> {
    let reply = ctx.call(words)?;
    if !reply.ok { ctx.failed(); }
    Ok(reply)
}
fn confirmed(ctx: &mut Context<'_>, title: &str, question: &str, words: &[&str]) -> io::Result<Reply> {
    let reply = run_confirmed(ctx, title, question, &argv(words), &Secrets::default())?;
    if !reply.ok && !matches!(reply.code(), "confirmation_required" | "plan_changed") { ctx.failed(); }
    Ok(reply)
}
/// One-shot read inside an action: a failure warns and ends the action.
fn fetch(ctx: &mut Context<'_>, words: &[&str]) -> io::Result<Option<Value>> {
    let reply = execute(ctx, words)?;
    Ok(reply.ok.then_some(reply.data))
}
/// Screen read: `not_found` leaves the screen; other failures offer a retry.
fn load(ctx: &mut Context<'_>, title: &str, words: &[&str]) -> io::Result<Option<Value>> {
    loop {
        let reply = ctx.call(words)?;
        if reply.ok { return Ok(Some(reply.data)); }
        if reply.code() == "not_found" { return Ok(None); }
        ctx.failed();
        let mut view = View::menu(title, vec![Item::new('r', "Повторить", ui::YELLOW), back()]);
        view.context.push(ui::text("Данные недоступны", ui::YELLOW));
        loop {
            match ctx.choose(&view)?.map(|s| s.to_ascii_lowercase()).as_deref() {
                None | Some("0") => return Ok(None),
                Some("r") => break,
                _ => ctx.invalid(),
            }
        }
    }
}
fn node_label(row: &Value) -> String { format!("{}  {}:{}", text(&row["name"]), text(&row["ip"]), scalar(&row["port"])) }
/// v1 `tui_pick_node|client|group`: the name of the chosen row.
fn pick(ctx: &mut Context<'_>, kind: &str, title: &str) -> io::Result<Option<String>> {
    let Some(data) = fetch(ctx, &[kind, "list"])? else { return Ok(None); };
    let labels: Vec<_> = rows(&data).iter().map(|r| if kind == "node" { node_label(r) } else { text(&r["name"]).to_owned() }).collect();
    Ok(ctx.select(title, &labels)?.map(|n| text(&data[n]["name"]).to_owned()))
}
/// Numbered list section (or a DIM empty line), then the actions.
fn list_view(title: &str, labels: &[String], empty: &str, actions: Vec<Item>) -> View {
    let mut view = View::menu(title, actions);
    if labels.is_empty() { view.context.push(ui::text(empty, ui::DIM)); }
    else { view.sections.insert(0, labels.iter().enumerate().map(|(i, s)| Item::new(i + 1, s, ui::CYAN)).collect()); }
    view
}
/// A node command retried only after the shared node-code handler fixed it.
fn node_request(ctx: &mut Context<'_>, node: &str, words: &[&str]) -> io::Result<Option<Value>> {
    loop {
        let reply = ctx.call(words)?;
        if reply.ok { return Ok(Some(reply.data)); }
        if crate::nodes::handle_node_codes(ctx, &reply, node)? { continue; }
        ctx.failed();
        return Ok(None);
    }
}
/// Result frame: empty fields are omitted; failures YELLOW.
fn summary(ctx: &mut Context<'_>, title: &str, data: &Value, fields: &[(&str, &str)], empty: &str) -> io::Result<()> {
    let mut view = View::new(title);
    for (field, label) in fields {
        let value = match &data[*field] {
            Value::Array(_) => strings(&data[*field]).join(", "),
            Value::String(s) => s.clone(),
            Value::Number(n) if n.as_u64() != Some(0) => n.to_string(),
            _ => String::new(),
        };
        if value.is_empty() { continue; }
        let color = if field.contains("failed") { ui::YELLOW } else { ui::NC };
        view.context.push(ui::text(format!("{label}: {value}"), color));
    }
    if view.context.is_empty() { view.context.push(ui::text(empty, ui::DIM)); }
    present(ctx, &view)
}
/// `generate …`; the summary is shown on success and on `partial` (whose
/// fields arrive in `error`).
fn generate(ctx: &mut Context<'_>, scope: &[&str]) -> io::Result<()> {
    let mut words = vec!["generate"];
    words.extend_from_slice(scope);
    let reply = ctx.call(&words)?;
    let data = if reply.ok { &reply.data } else if reply.code() == "partial" { &reply.error } else { ctx.failed(); return Ok(()); };
    summary(ctx, "Итог генерации", data,
        &[("ok", "Готово"), ("skipped", "Пропущено"), ("failed", "Ошибки"), ("nodes_failed", "Ноды с ошибкой"), ("dir", "Каталог")],
        "Нет результатов")
}

// ─── Clients ─────────────────────────────────────────────────────────────────

fn clients(ctx: &mut Context<'_>) -> io::Result<()> {
    loop {
        let Some(data) = load(ctx, "Клиенты", &["client", "list"])? else { return Ok(()); };
        let list = names(&data);
        let labels: Vec<String> = rows(&data).iter().map(|r| format!("{}  ({})", text(&r["name"]), text(&r["group"]))).collect();
        let view = list_view("Клиенты", &labels, "Нет клиентов",
            vec![Item::new('a', "Добавить клиента", ui::GREEN), Item::new('d', "Удалить клиентов", ui::RED), back()]);
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        match choice.to_ascii_lowercase().as_str() {
            "0" => return Ok(()),
            "a" => if let Some(name) = required(ctx, "Имя клиента", "Имя клиента не указано.")? {
                if let Some(group) = pick(ctx, "group", "Группа клиента")? {
                    execute(ctx, &["client", "add", "--name", &name, "--group", &group])?;
                }
            },
            "d" => delete_clients(ctx, &list)?,
            _ => match index(&choice, list.len()) { Some(i) => client_card(ctx, list[i].clone())?, None => ctx.invalid() },
        }
    }
}
fn delete_clients(ctx: &mut Context<'_>, targets: &[String]) -> io::Result<()> {
    let Some(selected) = ctx.toggle("Удаление клиентов", targets, vec![false; targets.len()], EMPTY)? else { return Ok(()); };
    if selected.is_empty() { ctx.ui.notice(ui::warn("Ничего не выбрано.")); return Ok(()); }
    let mut words = vec!["client", "delete"];
    for i in selected { words.extend(["--name", targets[i].as_str()]); }
    confirmed(ctx, "Удаление клиентов", "Удалить выбранных клиентов?", &words)?;
    Ok(())
}
fn subscription_state(row: &Value) -> String {
    let sub = &row["subscription"];
    if sub["published"] != true { "нет".into() }
    else if let Some(expires) = sub["expires_at"].as_str().filter(|s| !s.is_empty()) { format!("опубликована до {expires}") }
    else { "опубликована, без срока".into() }
}
/// v1 `tui_client_card`: reads `client list` (no credentials) each redraw.
fn client_card(ctx: &mut Context<'_>, mut name: String) -> io::Result<()> {
    loop {
        let Some(data) = load(ctx, "Клиент", &["client", "list"])? else { return Ok(()); };
        let Some(row) = find_row(&data, &name) else {
            ctx.ui.notice(ui::warn(format!("Клиент «{name}» не найден.")));
            return Ok(());
        };
        let inherit = row["inherit_nodes"] != false;
        let mut view = View::menu(format!("Клиент: {name}"),
            vec![Item::new('v', "Показать данные подключения", ui::CYAN), Item::new('s', "Подписка", ui::CYAN)]);
        view.context = vec![
            ui::text(format!("Группа: {}", text(&row["group"])), ui::NC),
            ui::text(format!("Ноды: {} ({})", if inherit { "от группы" } else { "свои" }, joined(&row["nodes"])), ui::NC),
            ui::text(format!("Подписка: {}", subscription_state(&row)), ui::NC),
        ];
        view.sections.push(vec![
            Item::new('f', "Сгенерировать конфиг", ui::YELLOW), Item::new('n', "Ноды клиента", ui::YELLOW),
            Item::new('p', "Подключения по нодам", ui::YELLOW), Item::new('g', "Сменить группу", ui::YELLOW),
            Item::new('r', "Переименовать", ui::YELLOW), Item::new('d', "Удалить клиента", ui::RED), back(),
        ]);
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        match choice.to_ascii_lowercase().as_str() {
            "0" => return Ok(()),
            "v" => show_client(ctx, &name)?,
            "s" => client_subscription(ctx, &name)?,
            "f" => generate(ctx, &["--client", &name])?,
            "n" => client_nodes(ctx, &name, inherit, &strings(&row["nodes"]))?,
            "p" => if inherit { ctx.ui.notice(ui::warn("Подключения настраиваются только для клиента со своими нодами.")); }
                else { client_connections(ctx, &name, &strings(&row["nodes"]))?; },
            "g" => if let Some(group) = pick(ctx, "group", "Новая группа клиента")? {
                confirmed(ctx, "Смена группы клиента", "Сменить группу?", &["client", "set-group", "--name", &name, "--group", &group])?;
            },
            "r" => if let Some(new) = required(ctx, "Новое имя клиента", "Имя клиента не указано.")? {
                let reply = confirmed(ctx, "Переименование клиента", "Переименовать клиента?", &["client", "rename", "--name", &name, "--new-name", &new])?;
                let renamed = if reply.ok { reply.data["name"].as_str() } else if reply.code() == "partial" { reply.error["name"].as_str() } else { None };
                if let Some(renamed) = renamed { name = renamed.to_owned(); }
            },
            "d" => {
                let reply = confirmed(ctx, "Удаление клиента", "Удалить клиента?", &["client", "delete", "--name", &name])?;
                if reply.ok || (reply.code() == "partial" && strings(&reply.error["deleted"]).contains(&name)) { return Ok(()); }
            },
            _ => ctx.invalid(),
        }
    }
}
/// Explicit request: credentials are shown here and only here.
fn show_client(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    let Some(data) = fetch(ctx, &["client", "show", "--name", name])? else { return Ok(()); };
    let mut view = View::new(format!("Данные клиента: {name}"));
    let subscription = &data["subscription"];
    let link = if subscription.is_null() { "нет" } else { subscription["url"].as_str().unwrap_or("ссылка недоступна") };
    for line in [
        format!("Группа: {}", text(&data["group"])),
        format!("Ноды: {}", joined(&data["nodes"])),
        format!("VLESS UUID: {}", text(&data["credentials"]["vless_uuid"])),
        format!("Hysteria2 пароль: {}", text(&data["credentials"]["hy2_password"])),
        format!("Конфиг: {} ({})", text(&data["config"]["path"]), if data["config"]["exists"] == true { "создан" } else { "не создан" }),
        format!("Подписка: {link}"),
    ] { view.context.push(ui::text(line, ui::NC)); }
    if !rows(&data["connections"]).is_empty() {
        view.context.push(ui::text("Подключения по нодам:", ui::CYAN));
        for row in rows(&data["connections"]) {
            let mode = if row["mode"] == "own" { "свои" } else { "от группы" };
            view.context.push(ui::text(format!("  {} ({mode}): {}", text(&row["node"]), joined(&row["proxies"])), ui::NC));
        }
    }
    present(ctx, &view)
}
fn client_nodes(ctx: &mut Context<'_>, name: &str, inherit: bool, current: &[String]) -> io::Result<()> {
    let (state, choices) = if inherit { ("от группы", vec!["Назначить свои ноды".to_owned()]) }
        else { ("свои", vec!["Изменить свои ноды".to_owned(), "Вернуть ноды от группы".to_owned()]) };
    let Some(choice) = ctx.select(&format!("Ноды клиента: {name} (сейчас {state})"), &choices)? else { return Ok(()); };
    if choice == 1 {
        confirmed(ctx, "Ноды клиента", "Вернуть ноды от группы?", &["client", "nodes", "--name", name, "--inherit"])?;
        return Ok(());
    }
    let Some(data) = fetch(ctx, &["node", "list"])? else { return Ok(()); };
    let targets = names(&data);
    let labels: Vec<String> = rows(&data).iter().map(node_label).collect();
    // The current (effective) nodes are the starting state, like v1.
    let flags = targets.iter().map(|n| current.contains(n)).collect();
    let Some(selected) = ctx.toggle(&format!("Свои ноды клиента: {name}"), &labels, flags, EMPTY)? else { return Ok(()); };
    if selected.is_empty() { ctx.ui.notice(ui::warn("Ничего не выбрано.")); return Ok(()); }
    let mut words = vec!["client", "nodes", "--name", name];
    for i in selected { words.extend(["--node", targets[i].as_str()]); }
    execute(ctx, &words)?;
    Ok(())
}
fn client_connections(ctx: &mut Context<'_>, name: &str, own: &[String]) -> io::Result<()> {
    if own.is_empty() { ctx.ui.notice(ui::warn("У клиента нет своих нод.")); return Ok(()); }
    let Some(data) = fetch(ctx, &["node", "list"])? else { return Ok(()); };
    let available: Vec<&Value> = own.iter().filter_map(|n| rows(&data).iter().find(|r| r["name"] == n.as_str())).collect();
    if available.is_empty() { ctx.ui.notice(ui::warn("Назначенные ноды больше недоступны.")); return Ok(()); }
    let labels: Vec<String> = available.iter().map(|r| node_label(r)).collect();
    let Some(i) = ctx.select(&format!("Подключения клиента: {name}"), &labels)? else { return Ok(()); };
    let node = text(&available[i]["name"]).to_owned();
    let actions = ["Настроить подключения".to_owned(), "Сбросить на групповые".to_owned()];
    let Some(action) = ctx.select(&format!("Подключения: {name} на {node}"), &actions)? else { return Ok(()); };
    if action == 1 {
        confirmed(ctx, "Сброс подключений", "Сбросить подключения ноды?", &["client", "connections", "--name", name, "--node", &node, "--reset"])?;
        return Ok(());
    }
    let Some(assigned) = fetch(ctx, &["client", "connections", "--name", name])? else { return Ok(()); };
    let current: Vec<String> = rows(&assigned).iter().filter(|r| r["node"] == node.as_str()).flat_map(|r| strings(&r["proxies"])).collect();
    let Some(found) = node_request(ctx, &node, &["conn", "list", "--name", &node, "--discover"])? else { return Ok(()); };
    let proxies = strings(&found[0]["discovered"]);
    let flags = proxies.iter().map(|p| current.contains(p)).collect();
    let Some(selected) = ctx.toggle(&format!("Подключения клиента на {node}"), &proxies, flags, EMPTY)? else { return Ok(()); };
    if selected.is_empty() { ctx.ui.notice(ui::warn("Ничего не выбрано.")); return Ok(()); }
    let mut words = vec!["client", "connections", "--name", name, "--node", &node];
    for i in selected { words.extend(["--proxy", proxies[i].as_str()]); }
    execute(ctx, &words)?;
    Ok(())
}

// ─── Client subscription and headers ─────────────────────────────────────────

/// `Some(None)` publishes without `--ttl` (the core keeps a current expiry).
fn ttl(ctx: &mut Context<'_>, current: Option<&str>) -> io::Result<Option<Option<String>>> {
    let keep = current.map_or_else(|| "Без срока".to_owned(), |e| format!("Оставить текущий срок (до {e})"));
    let labels = [keep, "12 часов (12h)".into(), "30 дней (30d)".into(), "2 недели (2w)".into(), "Другой срок".into()];
    Ok(match ctx.select("Срок действия подписки", &labels)? {
        None => None,
        Some(0) => Some(None),
        Some(1) => Some(Some("12h".into())),
        Some(2) => Some(Some("30d".into())),
        Some(3) => Some(Some("2w".into())),
        Some(_) => required(ctx, "Срок действия (число и h, d или w, например 7d)", "Срок не указан.")?.map(Some),
    })
}
fn client_subscription(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    loop {
        let Some(data) = load(ctx, "Подписка клиента", &["client", "list"])? else { return Ok(()); };
        let Some(row) = find_row(&data, name) else {
            ctx.ui.notice(ui::warn(format!("Клиент «{name}» не найден.")));
            return Ok(());
        };
        // v1 `tui_call sub host || true`: an unreadable host only hides the line.
        let host = ctx.call(&["subscription", "host"])?;
        let host = if host.ok { host.data["node"].as_str().filter(|s| !s.is_empty()).map(str::to_owned) } else { None };
        let mut view = View::menu(format!("Подписка клиента: {name}"), vec![
            Item::new('p', "Опубликовать", ui::GREEN), Item::new('v', "Показать ссылку", ui::CYAN),
            Item::new('i', "Итоговые заголовки", ui::CYAN), Item::new('h', "Заголовки клиента", ui::YELLOW),
            Item::new('r', "Сменить токен", ui::RED), Item::new('x', "Отозвать подписку", ui::RED), back(),
        ]);
        view.context.push(match &host {
            Some(node) => ui::text(format!("Хост подписок: {node}"), ui::NC),
            None => ui::text("Хост подписок не задан — раздел s", ui::DIM),
        });
        view.context.push(ui::text(format!("Подписка: {}", subscription_state(&row)), ui::NC));
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        match choice.to_ascii_lowercase().as_str() {
            "0" => return Ok(()),
            "p" => {
                let sub = &row["subscription"];
                let current = if sub["published"] == true { sub["expires_at"].as_str().filter(|s| !s.is_empty()) } else { None };
                if let Some(ttl) = ttl(ctx, current)? {
                    let mut words = vec!["subscription", "publish", "--name", name];
                    if let Some(ttl) = &ttl { words.extend(["--ttl", ttl.as_str()]); }
                    // partial: saved, only the HTTP check failed — the link is still needed.
                    let reply = ctx.call(&words)?;
                    if reply.ok || reply.code() == "partial" { share(ctx, name)?; } else { ctx.failed(); }
                }
            },
            "v" => share(ctx, name)?,
            "i" => resolved_headers(ctx, name)?,
            "h" => headers(ctx, "client", name)?,
            "r" => {
                let reply = confirmed(ctx, "Смена токена подписки", "Сменить токен?", &["subscription", "rotate", "--name", name])?;
                if reply.ok || reply.code() == "partial" { share(ctx, name)?; }
            },
            "x" => { confirmed(ctx, "Отзыв подписки", "Отозвать подписку?", &["subscription", "revoke", "--name", name])?; },
            _ => ctx.invalid(),
        }
    }
}
/// QR code lines of `url`, which is passed on stdin (never argv); empty when
/// the program is missing or fails.
fn qr_lines(command: &mut Command, url: &str) -> Vec<String> {
    let Ok(mut child) = command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn() else { return vec![]; };
    if let Some(mut stdin) = child.stdin.take() { let _ = stdin.write_all(url.as_bytes()); }
    match child.wait_with_output() {
        Ok(output) if output.status.success() => String::from_utf8_lossy(&output.stdout).lines().map(str::to_owned).collect(),
        _ => vec![],
    }
}
/// v1 `tui_render_share_bundle` from `subscription show`: link, expiry,
/// headers, curl and JSON lines, then the QR code when available.
fn share_view(data: &Value, qr: &[String]) -> View {
    let url = text(&data["url"]);
    let mut view = View::new(format!("Подписка: {}", text(&data["client"])));
    view.context.push(colored("URL: ", ui::GREEN, url));
    if let Some(expires) = data["expires_at"].as_str().filter(|s| !s.is_empty()) {
        view.context.push(colored("Срок действия: ", ui::YELLOW, expires));
    }
    if !rows(&data["headers"]).is_empty() {
        view.context.push(ui::text("Сервер отдаст эти заголовки:", ui::DIM));
        for row in rows(&data["headers"]) {
            view.context.push(ui::text(format!("  {}: {}", text(&row["name"]), text(&row["value"])), ui::NC));
        }
    }
    view.context.push(Line::default());
    view.context.push(ui::text(format!("curl '{}'", url.replace('\'', "'\\''")), ui::NC));
    view.context.push(ui::text(serde_json::json!({ "url": url }).to_string(), ui::NC));
    if !qr.is_empty() {
        view.context.push(Line::default());
        view.context.extend(qr.iter().map(|line| Line::raw(line.clone())));
    }
    view
}
fn share(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    let Some(data) = fetch(ctx, &["subscription", "show", "--name", name])? else { return Ok(()); };
    let qr = match data["url"].as_str() {
        Some(url) if executable("qrencode") => qr_lines(Command::new("qrencode").args(["-t", "UTF8"]), url),
        _ => vec![],
    };
    present(ctx, &share_view(&data, &qr))
}
fn header_line(row: &Value, with_source: bool) -> Line<'static> {
    let source = if with_source {
        let label = match row["source"].as_str() { Some("default") => "по умолчанию", Some("group") => "группа", Some("client") => "клиент", Some(other) => other, None => "—" };
        format!("  [{label}]")
    } else { String::new() };
    ui::text(format!("{}: {}{source}", text(&row["name"]), text(&row["value"])), ui::NC)
}
fn header_lines(view: &mut View, data: &Value, with_source: bool) {
    if rows(data).is_empty() { view.context.push(ui::text("Нет заголовков", ui::DIM)); }
    view.context.extend(rows(data).iter().map(|row| header_line(row, with_source)));
}
fn resolved_headers(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    let Some(data) = fetch(ctx, &["subscription", "headers", "--client", name])? else { return Ok(()); };
    let mut view = View::new(format!("Итоговые заголовки: {name}"));
    header_lines(&mut view, &data, true);
    present(ctx, &view)
}
/// v1 `tui_headers client|group NAME`: a client deletes only its own headers.
fn headers(ctx: &mut Context<'_>, kind: &str, name: &str) -> io::Result<()> {
    let flag = format!("--{kind}");
    let client = kind == "client";
    loop {
        let Some(data) = load(ctx, "Заголовки подписки", &["subscription", "headers", &flag, name])? else { return Ok(()); };
        let mut view = View::menu(format!("Заголовки подписки: {name}"),
            vec![Item::new('a', "Установить", ui::YELLOW), Item::new('d', "Удалить", ui::RED), back()]);
        header_lines(&mut view, &data, client);
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        match choice.to_ascii_lowercase().as_str() {
            "0" => return Ok(()),
            "a" => {
                let Some(header) = ask(ctx, "Имя заголовка")? else { continue; };
                let Some(value) = ask(ctx, "Значение")? else { continue; };
                if header.is_empty() || value.is_empty() { ctx.ui.notice(ui::warn("Имя и значение заголовка обязательны.")); continue; }
                execute(ctx, &["subscription", "headers", &flag, name, "--set", &format!("{header}={value}")])?;
            },
            "d" => {
                let own: Vec<String> = rows(&data).iter().filter(|r| !client || r["source"] == "client").map(|r| text(&r["name"]).to_owned()).collect();
                if let Some(i) = ctx.select("Удаление заголовка", &own)? {
                    execute(ctx, &["subscription", "headers", &flag, name, "--unset", &own[i]])?;
                }
            },
            _ => ctx.invalid(),
        }
    }
}

// ─── Groups ──────────────────────────────────────────────────────────────────

fn groups(ctx: &mut Context<'_>) -> io::Result<()> {
    loop {
        let Some(data) = load(ctx, "Группы", &["group", "list"])? else { return Ok(()); };
        let list = names(&data);
        let labels: Vec<String> = rows(&data).iter().map(|r| format!("{}  ({})", text(&r["name"]), text(&r["template"]))).collect();
        let view = list_view("Группы", &labels, "Нет групп", vec![Item::new('a', "Добавить группу", ui::GREEN), back()]);
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        match choice.to_ascii_lowercase().as_str() {
            "0" => return Ok(()),
            "a" => if let Some(name) = required(ctx, "Название группы", "Название не указано.")? {
                execute(ctx, &["group", "add", "--name", &name])?;
            },
            _ => match index(&choice, list.len()) { Some(i) => group_card(ctx, &list[i])?, None => ctx.invalid() },
        }
    }
}
fn group_card(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    loop {
        let Some(data) = load(ctx, "Группа", &["group", "list"])? else { return Ok(()); };
        let Some(row) = find_row(&data, name) else {
            ctx.ui.notice(ui::warn(format!("Группа «{name}» не найдена.")));
            return Ok(());
        };
        let template = text(&row["template"]).to_owned();
        let mut view = View::menu(format!("Группа: {name}"), vec![
            Item::new('t', "Шаблон", ui::YELLOW), Item::new('h', "Заголовки подписки группы", ui::YELLOW),
            Item::new('f', "Сгенерировать конфиги группы", ui::YELLOW), Item::new('d', "Удалить группу", ui::RED), back(),
        ]);
        view.context = vec![
            ui::text(format!("Шаблон: {template}"), ui::NC),
            ui::text(format!("Клиентов: {}", scalar(&row["clients"])), ui::NC),
            ui::text(format!("Ноды: {}", joined(&row["nodes"])), ui::NC),
        ];
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        match choice.to_ascii_lowercase().as_str() {
            "0" => return Ok(()),
            "t" => group_template(ctx, name, &template)?,
            "h" => headers(ctx, "group", name)?,
            "f" => generate(ctx, &["--group", name])?,
            "d" => if confirmed(ctx, "Удаление группы", "Удалить группу?", &["group", "delete", "--name", name])?.ok { return Ok(()); },
            _ => ctx.invalid(),
        }
    }
}
fn group_template(ctx: &mut Context<'_>, name: &str, current: &str) -> io::Result<()> {
    let Some(data) = fetch(ctx, &["template", "list"])? else { return Ok(()); };
    let mut labels = names(&data);
    let count = labels.len();
    labels.push("Создать новый шаблон".into());
    let Some(i) = ctx.select(&format!("Шаблон группы: {name} (текущий: {current})"), &labels)? else { return Ok(()); };
    if i < count {
        execute(ctx, &["group", "set-template", "--name", name, "--template", &labels[i]])?;
        return Ok(());
    }
    let Some(new) = required(ctx, "Имя нового шаблона", "Имя шаблона не указано.")? else { return Ok(()); };
    let reply = execute(ctx, &["template", "create", "--name", &new, "--group", name])?;
    if let Some(created) = reply.data["name"].as_str().filter(|_| reply.ok) { edit_template(ctx, created)?; }
    Ok(())
}

// ─── Templates ───────────────────────────────────────────────────────────────

fn source_label(row: &Value) -> &'static str { if row["source"] == "builtin" { "встроенный" } else { "пользовательский" } }
fn templates(ctx: &mut Context<'_>) -> io::Result<()> {
    loop {
        let Some(data) = load(ctx, "Шаблоны", &["template", "list"])? else { return Ok(()); };
        let list = names(&data);
        let labels: Vec<String> = rows(&data).iter().map(|r| format!("{}  ({})", text(&r["name"]), source_label(r))).collect();
        let view = list_view("Шаблоны", &labels, "Нет шаблонов", vec![Item::new('a', "Создать шаблон", ui::GREEN), back()]);
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        match choice.to_ascii_lowercase().as_str() {
            "0" => return Ok(()),
            "a" => if let Some(name) = required(ctx, "Имя шаблона", "Имя шаблона не указано.")? {
                let reply = execute(ctx, &["template", "create", "--name", &name])?;
                if let Some(created) = reply.data["name"].as_str().filter(|_| reply.ok) { edit_template(ctx, created)?; }
            },
            _ => match index(&choice, list.len()) { Some(i) => template_card(ctx, &list[i])?, None => ctx.invalid() },
        }
    }
}
/// Only `~` and `~/…` expand (v1); `~user` stays literal.
fn expand_home(path: &str) -> PathBuf {
    if let Some(home) = env::var_os("HOME").or_else(|| env::var_os("USERPROFILE")) {
        if path == "~" { return PathBuf::from(home); }
        if let Some(suffix) = path.strip_prefix("~/") { return PathBuf::from(home).join(suffix); }
    }
    PathBuf::from(path)
}
fn template_card(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    loop {
        let Some(data) = load(ctx, "Шаблон", &["template", "list"])? else { return Ok(()); };
        let Some(row) = find_row(&data, name) else {
            ctx.ui.notice(ui::warn(format!("Шаблон «{name}» не найден.")));
            return Ok(());
        };
        let mut view = View::menu(format!("Шаблон: {name}"), vec![
            Item::new('v', "Показать", ui::CYAN), Item::new('x', "Экспорт в файл", ui::CYAN),
            Item::new('e', "Редактировать", ui::YELLOW), Item::new('i', "Импорт из файла", ui::YELLOW), back(),
        ]);
        view.context = vec![
            ui::text(format!("Источник: {}", source_label(&row)), ui::NC),
            ui::text(format!("Группы: {}", joined(&row["groups"])), ui::NC),
        ];
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        let choice = choice.to_ascii_lowercase();
        match choice.as_str() {
            "0" => return Ok(()),
            "v" => if let Some(data) = fetch(ctx, &["template", "show", "--name", name])? {
                let mut view = View::new(format!("Содержимое: {name}"));
                view.context.push(ui::text(format!("Путь: {}", data["path"].as_str().unwrap_or("встроенный шаблон")), ui::DIM));
                view.context.extend(text(&data["content"]).lines().map(|s| Line::raw(s.to_owned())));
                present(ctx, &view)?;
            },
            "e" => edit_template(ctx, name)?,
            "x" | "i" => if let Some(path) = required(ctx, "Путь к файлу", "Путь не указан.")? {
                let path = expand_home(&path).to_string_lossy().into_owned();
                if choice == "x" {
                    confirmed(ctx, "Экспорт шаблона", "Перезаписать файл?", &["template", "export", "--name", name, "--output", &path])?;
                } else {
                    confirmed(ctx, "Импорт шаблона", "Перезаписать шаблон?", &["template", "import", "--name", name, "--file", &path])?;
                }
            },
            _ => ctx.invalid(),
        }
    }
}
fn executable(name: &str) -> bool {
    env::var_os("PATH").is_some_and(|path| env::split_paths(&path).any(|dir| {
        let path = dir.join(name);
        #[cfg(unix)] { use std::os::unix::fs::PermissionsExt; fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0) }
        #[cfg(not(unix))] { path.is_file() || path.with_extension("exe").is_file() }
    }))
}
/// Split editor arguments without invoking a shell. Quotes/backslashes support
/// paths with spaces and flags; shell expansions and command substitution are
/// intentionally not evaluated.
fn editor_words(value: &str) -> io::Result<Vec<String>> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quote = None;
    let mut started = false;
    let mut chars = value.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' && quote != Some('\'')
            && chars.peek().is_some_and(|next| *next == '\\' || *next == '"' || (quote.is_none() && (*next == '\'' || next.is_whitespace())))
        {
            word.extend(chars.next());
            started = true;
        } else if let Some(q) = quote {
            if c == q { quote = None; } else { word.push(c); }
            started = true;
        } else if c == '\'' || c == '"' {
            quote = Some(c);
            started = true;
        } else if c.is_whitespace() {
            if started { words.push(std::mem::take(&mut word)); started = false; }
        } else {
            word.push(c);
            started = true;
        }
    }
    if quote.is_some() { return Err(io::Error::new(io::ErrorKind::InvalidInput, "Некорректные кавычки в команде редактора")); }
    if started { words.push(word); }
    if words.is_empty() || words[0].is_empty() { return Err(io::Error::new(io::ErrorKind::NotFound, "Редактор не задан")); }
    Ok(words)
}
/// Owner-only (0700) directory; `tempfile` creates its files 0600.
fn private_editor_dir() -> io::Result<tempfile::TempDir> {
    let mut builder = tempfile::Builder::new();
    builder.prefix("rc-template-");
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        builder.permissions(fs::Permissions::from_mode(0o700));
    }
    builder.tempdir()
}
/// `$VISUAL`, `$EDITOR`, then nano/vi (notepad on Windows).
fn editor() -> io::Result<Vec<String>> {
    for variable in ["VISUAL", "EDITOR"] {
        if let Ok(value) = env::var(variable) { if !value.trim().is_empty() { return editor_words(&value); } }
    }
    if cfg!(windows) { return Ok(vec!["notepad.exe".into()]); }
    for name in ["nano", "vi"] { if executable(name) { return Ok(vec![name.into()]); } }
    Err(io::Error::new(io::ErrorKind::NotFound, "Редактор не найден: установите nano или задайте EDITOR"))
}
fn edit_template(ctx: &mut Context<'_>, name: &str) -> io::Result<()> {
    let Some(data) = fetch(ctx, &["template", "show", "--name", name])? else { return Ok(()); };
    let result = (|| -> io::Result<()> {
        let content = data["content"].as_str().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "Нет содержимого шаблона"))?;
        let editor = editor()?;
        let dir = private_editor_dir()?;
        let mut file = tempfile::Builder::new().suffix(".yaml").tempfile_in(dir.path())?;
        file.write_all(content.as_bytes())?;
        file.flush()?;
        let (handle, path) = file.into_parts();
        drop(handle);
        edit_file(ctx, name, &editor, &path, content.as_bytes())
    })();
    if let Err(error) = result { ctx.ui.notice(ui::warn(format!("Изменения не сохранены: {error}"))); }
    Ok(())
}
/// Edit on the cooked terminal; unchanged content imports nothing.
fn edit_file(ctx: &mut Context<'_>, name: &str, editor: &[String], path: &Path, original: &[u8]) -> io::Result<()> {
    let mut command = Command::new(&editor[0]);
    command.args(&editor[1..]).arg(path);
    if !ctx.ui.suspended(&mut command)?.success() {
        ctx.ui.notice(ui::warn("Редактор завершился с ошибкой. Изменения не сохранены."));
        return Ok(());
    }
    if fs::read(path)? == original { ctx.ui.notice(ui::text("Изменений нет.", ui::DIM)); return Ok(()); }
    confirmed(ctx, "Импорт изменений шаблона", "Сохранить изменения шаблона?",
        &["template", "import", "--name", name, "--file", &path.to_string_lossy()])?;
    Ok(())
}

// ─── Generation ──────────────────────────────────────────────────────────────

fn generation(ctx: &mut Context<'_>) -> io::Result<()> {
    loop {
        let Some(data) = load(ctx, "Генерация конфигов", &["group", "list"])? else { return Ok(()); };
        let mut view = View::menu("Генерация конфигов", vec![
            Item::new('a', "Всем клиентам", ui::YELLOW), Item::new('g', "По группе", ui::YELLOW),
            Item::new('c', "Одному клиенту", ui::YELLOW), back(),
        ]);
        if rows(&data).is_empty() { view.context.push(ui::text("Нет групп", ui::DIM)); }
        view.context.extend(rows(&data).iter().map(|r| ui::text(format!("{} → {}", text(&r["name"]), text(&r["template"])), ui::NC)));
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        match choice.to_ascii_lowercase().as_str() {
            "0" => return Ok(()),
            "a" => generate(ctx, &["--all"])?,
            "g" => if let Some(group) = pick(ctx, "group", "Генерация по группе")? { generate(ctx, &["--group", &group])?; },
            "c" => if let Some(client) = pick(ctx, "client", "Генерация для клиента")? { generate(ctx, &["--client", &client])?; },
            _ => ctx.invalid(),
        }
    }
}

// ─── Subscriptions ───────────────────────────────────────────────────────────

fn subscriptions(ctx: &mut Context<'_>) -> io::Result<()> {
    loop {
        let Some(host) = load(ctx, "Подписки", &["subscription", "host"])? else { return Ok(()); };
        let mut view = View::menu("Подписки", vec![
            Item::new('h', "Хост-нода подписок", ui::YELLOW), Item::new('l', "Список подписок", ui::CYAN),
            Item::new('u', "Обновить все подписки", ui::YELLOW), Item::new('m', "Перенос на другую ноду", ui::YELLOW),
            Item::new('c', "Подписка клиента", ui::CYAN), Item::new('g', "Заголовки группы", ui::YELLOW), back(),
        ]);
        match host["node"].as_str().filter(|s| !s.is_empty()) {
            Some(node) => {
                view.context.push(Line::from(vec![Span::raw("Хост-нода: "), Span::styled(node.to_owned(), Style::default().fg(ui::GREEN))]));
                view.context.push(ui::text(format!("Базовый URL: {}", text(&host["base_url"])), ui::NC));
            }
            None => view.context.push(ui::text("Хост-нода подписок не задана", ui::DIM)),
        }
        let Some(choice) = ctx.choose(&view)? else { return Ok(()); };
        match choice.to_ascii_lowercase().as_str() {
            "0" => return Ok(()),
            "h" => if let Some(node) = pick(ctx, "node", "Хост-нода подписок")? {
                node_request(ctx, &node, &["subscription", "host", "--name", &node])?;
            },
            "l" => subscription_list(ctx)?,
            "u" => {
                let reply = confirmed(ctx, "Обновление подписок", "Опубликовать подписки?", &["subscription", "publish-all"])?;
                // Failures after the upload attempt carry the summary in `error`.
                let data = if reply.ok { Some(&reply.data) } else { reply.error.get("published").map(|_| &reply.error) };
                if let Some(data) = data {
                    summary(ctx, "Итог публикации подписок", data,
                        &[("published", "Опубликовано"), ("skipped", "Пропущено"), ("failed", "Ошибки"), ("removed", "Удалено устаревших")],
                        "Нечего публиковать.")?;
                }
            },
            "m" => if let Some(node) = pick(ctx, "node", "Перенос подписок на ноду")? {
                confirmed(ctx, "Перенос подписок", "Перенести подписки?", &["subscription", "migrate", "--name", &node])?;
            },
            "c" => if let Some(name) = pick(ctx, "client", "Подписка клиента")? { client_subscription(ctx, &name)?; },
            "g" => if let Some(name) = pick(ctx, "group", "Заголовки группы")? { headers(ctx, "group", &name)?; },
            _ => ctx.invalid(),
        }
    }
}
fn subscription_list(ctx: &mut Context<'_>) -> io::Result<()> {
    let Some(data) = fetch(ctx, &["subscription", "list"])? else { return Ok(()); };
    let mut view = View::new("Список подписок");
    if rows(&data).is_empty() { view.context.push(ui::text("Нет опубликованных подписок", ui::DIM)); }
    for row in rows(&data) {
        let (state, color) = match row["state"].as_str() {
            Some("active") => ("действует", ui::GREEN),
            Some("expired") => ("истекла", ui::YELLOW),
            Some("unlimited") => ("без срока", ui::DIM),
            _ => ("срок неизвестен", ui::DIM),
        };
        view.context.push(Line::from(vec![
            Span::raw(format!("{}  {}  ", text(&row["client"]), text(&row["expires_at"]))),
            Span::styled(state, Style::default().fg(color)),
        ]));
    }
    present(ctx, &view)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{app::{Registry, ScriptedUi, UserInterface}, serve::{Log, ScriptedClient}};
    use ratatui::{backend::TestBackend, style::Color, Terminal};
    use serde_json::json;

    type Step = (Vec<String>, Reply);
    fn ok(words: &[&str], data: Value) -> Step { (argv(words), Reply::success(data)) }
    fn step(words: &[&str], reply: Reply) -> Step { (argv(words), reply) }
    fn yes(words: &[&str], data: Value) -> Step {
        let mut confirmed = argv(words);
        confirmed.extend(argv(&["--yes", "--plan-token", "T"]));
        (confirmed, Reply::success(data))
    }
    fn plan() -> Reply {
        Reply { error: json!({"code":"confirmation_required","plan":["Клиент: alice","Последствие: конфиг удалён"],"plan_token":"T"}), ..Reply::default() }
    }
    fn fail(code: &str, extra: Value) -> Reply {
        let mut reply = Reply::failure(code);
        if let Value::Object(fields) = extra { for (key, value) in fields { reply.error[key] = value; } }
        reply
    }
    fn drive(steps: Vec<Step>, inputs: &[&str], run: impl FnOnce(&mut Context<'_>) -> io::Result<()>) -> (ScriptedClient, ScriptedUi) {
        let registry = Registry { screens: vec![], github_wizard: None };
        let mut core = ScriptedClient::new(steps);
        let mut ui = ScriptedUi::new(inputs);
        run(&mut Context { client: &mut core, ui: &mut ui, registry: &registry }).unwrap();
        core.assert_finished();
        frames(&ui);
        (core, ui)
    }
    /// Frame rules: blank line, borders, one separator per non-empty section,
    /// never two separators in a row or an empty trailing section.
    fn frames(ui: &ScriptedUi) {
        for view in &ui.views {
            let plain: Vec<String> = view.lines().iter().map(ToString::to_string).collect();
            assert_eq!(plain[0], "");
            assert!(plain[1].starts_with('┌'));
            assert!(plain.last().unwrap().starts_with('└'));
            let sep = |s: &String| s.starts_with('├');
            assert!(!plain.windows(2).any(|w| sep(&w[0]) && (sep(&w[1]) || w[1].starts_with('└'))), "empty section: {}", view.title);
            let body = !view.context.is_empty() || view.sections.iter().any(|s| !s.is_empty());
            assert_eq!(body, plain.iter().any(sep), "header separator: {}", view.title);
            assert!(view.sections.iter().all(|s| !s.is_empty()), "empty section: {}", view.title);
            let mut terminal = Terminal::new(TestBackend::new(90, 60)).unwrap();
            terminal.draw(|f| ui::render(f, view, "", false, &[])).unwrap();
        }
    }
    fn content(view: &View) -> String { view.lines().iter().map(ToString::to_string).collect::<Vec<_>>().join("\n") }
    fn keys(view: &View) -> Vec<(String, Color)> { view.sections.iter().flatten().map(|i| (i.key.clone(), i.color)).collect() }
    fn notices(ui: &ScriptedUi, text: &str) -> usize { ui.notices.iter().filter(|l| l.to_string().contains(text)).count() }
    fn view<'a>(ui: &'a ScriptedUi, title: &str) -> &'a View { ui.views.iter().find(|v| v.title == title).unwrap_or_else(|| panic!("no view {title}")) }
    fn sent(core: &ScriptedClient, words: &[&str]) -> bool { core.calls.contains(&argv(words)) }

    fn row(name: &str, inherit: bool, subscription: Value) -> Value {
        json!({"name":name,"group":"PC","inherit_nodes":inherit,"nodes":["de"],"subscription":subscription})
    }
    fn unpublished() -> Value { json!({"published":false,"expires_at":null}) }
    fn alice(inherit: bool) -> Value { json!([row("alice", inherit, unpublished())]) }
    fn shown() -> Value {
        json!({"name":"alice","group":"PC","inherit_nodes":false,"nodes":["de"],
            "subscription":{"url":"https://h/sub/tok","expires_at":null,"headers":[]},
            "credentials":{"vless_uuid":"UUID-SECRET","hy2_password":"HY2-SECRET"},
            "connections":[{"node":"de","mode":"own","proxies":["p1"]}],
            "config":{"path":"/g/PC/alice/config.yaml","exists":true}})
    }
    fn nodes() -> Value { json!([{"name":"de","ip":"127.0.0.1","port":22},{"name":"ru","ip":"10.0.0.2","port":2222}]) }
    fn group_list() -> Value { json!([{"name":"PC","template":"default.yaml","clients":1,"nodes":["de"]}]) }
    fn host() -> Value { json!({"node":"de","base_url":"https://h","sub_dir":"/var/www/sub","nginx_group":"www-data"}) }
    fn bundle(url: &str) -> Value { json!({"client":"alice","url":url,"expires_at":null,"headers":[]}) }

    #[test]
    fn client_list_add_accepts_both_cases_and_empty_list_is_full_frame() {
        for key in ["A", "a"] {
            let (_, ui) = drive(vec![
                ok(&["client", "list"], json!([])), ok(&["group", "list"], group_list()),
                ok(&["client", "add", "--name", "new", "--group", "PC"], json!({"name":"new","group":"PC"})),
                ok(&["client", "list"], json!([])),
            ], &[key, "new", "1", "0"], clients);
            let list = &ui.views[0];
            assert_eq!(list.context[0].style.fg, Some(ui::DIM));
            assert_eq!(keys(list), [("a".into(), ui::GREEN), ("d".into(), ui::RED), ("0".into(), ui::NC)]);
        }
        let (core, ui) = drive(vec![ok(&["client", "list"], json!([])), ok(&["client", "list"], json!([]))], &["a", "", "0"], clients);
        assert_eq!(notices(&ui, "Имя клиента не указано."), 1);
        assert_eq!(core.calls.len(), 2);
    }
    #[test]
    fn client_list_opens_card_by_number() {
        let data = json!([row("alice", true, unpublished()), row("bob", true, unpublished())]);
        let (_, ui) = drive(vec![ok(&["client", "list"], data.clone()), ok(&["client", "list"], data.clone()), ok(&["client", "list"], data)],
            &["2", "0", "0"], clients);
        assert_eq!(ui.views[0].sections[0][1].label, "bob  (PC)");
        assert!(ui.views.iter().any(|v| v.title == "Клиент: bob"));
    }
    #[test]
    fn deletion_is_unchecked_enter_does_nothing_and_cancel_discards_flags() {
        for inputs in [vec!["D", "", "0"], vec!["d", "1", "0", "0"]] {
            let data = alice(true);
            let (core, ui) = drive(vec![ok(&["client", "list"], data.clone()), ok(&["client", "list"], data)], &inputs, clients);
            assert_eq!(core.calls.len(), 2);
            let toggle = view(&ui, "Удаление клиентов");
            assert!(toggle.sections[0][0].label.starts_with("[ ]"));
            assert_eq!(notices(&ui, "Ничего не выбрано."), usize::from(inputs[1].is_empty()));
        }
    }
    #[test]
    fn deletion_shows_one_frozen_plan_default_no() {
        let data = json!([row("alice", true, unpublished()), row("bob", true, unpublished())]);
        let words = ["client", "delete", "--name", "alice", "--name", "bob"];
        for consent in ["", "n", "N", "y", "Y"] {
            let mut steps = vec![ok(&["client", "list"], data.clone()), step(&words, plan())];
            if consent.eq_ignore_ascii_case("y") { steps.push(yes(&words, json!({"deleted":["alice","bob"]}))); }
            steps.push(ok(&["client", "list"], data.clone()));
            let (_, ui) = drive(steps, &["d", "1", "2", "", consent, "0"], clients);
            let reviews: Vec<_> = ui.views.iter().filter(|v| v.prompt.contains("(y/N)")).collect();
            assert_eq!(reviews.len(), 1);
            assert!(content(reviews[0]).contains("alice"));
        }
    }
    #[test]
    fn card_reads_list_and_shows_credentials_only_on_request() {
        let (core, ui) = drive(vec![
            ok(&["client", "list"], alice(false)), ok(&["client", "show", "--name", "alice"], shown()), ok(&["client", "list"], alice(false)),
        ], &["V", "", "0"], |ctx| client_card(ctx, "alice".into()));
        assert_eq!(core.calls[0], argv(&["client", "list"]));
        let card = &ui.views[0];
        assert!(!content(card).contains("UUID-SECRET"));
        assert_eq!(card.sections.len(), 2);
        assert_eq!(keys(card), [("v".into(), ui::CYAN), ("s".into(), ui::CYAN), ("f".into(), ui::YELLOW), ("n".into(), ui::YELLOW),
            ("p".into(), ui::YELLOW), ("g".into(), ui::YELLOW), ("r".into(), ui::YELLOW), ("d".into(), ui::RED), ("0".into(), ui::NC)]);
        let data = view(&ui, "Данные клиента: alice");
        for expected in ["UUID-SECRET", "HY2-SECRET", "https://h/sub/tok", "/g/PC/alice/config.yaml (создан)", "de (свои): p1"] {
            assert!(content(data).contains(expected), "{expected}");
        }
        assert!(data.sections.is_empty());
    }
    #[test]
    fn client_data_without_connections_or_link_has_no_empty_lines() {
        let mut data = shown();
        data["connections"] = json!([]);
        data["nodes"] = json!([]);
        data["subscription"] = json!({"url":null,"expires_at":null,"headers":[]});
        let (_, ui) = drive(vec![ok(&["client", "show", "--name", "alice"], data)], &[""], |ctx| show_client(ctx, "alice"));
        let text = content(&ui.views[0]);
        assert!(text.contains("Ноды: нет") && text.contains("ссылка недоступна") && !text.contains("Подключения по нодам"));
    }
    #[test]
    fn card_set_group_rename_partial_and_delete_partial_follow_error_extras() {
        let renamed = json!([row("alice.2", true, unpublished())]);
        let delete = ["client", "delete", "--name", "alice.2"];
        drive(vec![
            ok(&["client", "list"], alice(true)), ok(&["group", "list"], group_list()),
            step(&["client", "set-group", "--name", "alice", "--group", "PC"], plan()),
            yes(&["client", "set-group", "--name", "alice", "--group", "PC"], json!({"name":"alice","group":"PC"})),
            ok(&["client", "list"], alice(true)),
            step(&["client", "rename", "--name", "alice", "--new-name", "requested"], fail("partial", json!({"name":"alice.2","nodes":["de"]}))),
            ok(&["client", "list"], renamed),
            step(&delete, plan()),
            (yes(&delete, Value::Null).0, fail("partial", json!({"deleted":["alice.2"],"revoked":[],"awg_nodes":[]}))),
        ], &["G", "1", "y", "R", "requested", "D", "y"], |ctx| client_card(ctx, "alice".into()));
    }
    #[test]
    fn card_rename_success_follows_data_and_partial_delete_of_others_stays() {
        drive(vec![
            ok(&["client", "list"], alice(true)),
            ok(&["client", "rename", "--name", "alice", "--new-name", "Bob"], json!({"name":"Bob"})),
            ok(&["client", "list"], json!([row("Bob", true, unpublished())])),
            step(&["client", "delete", "--name", "Bob"], fail("remote_failed", json!({"deleted":[]}))),
            ok(&["client", "list"], json!([row("Bob", true, unpublished())])),
        ], &["r", "Bob", "d", "0"], |ctx| client_card(ctx, "alice".into()));
    }
    #[test]
    fn vanished_card_returns_without_input_and_inherited_connections_warn() {
        let (_, ui) = drive(vec![ok(&["client", "list"], json!([]))], &["untouched"], |ctx| client_card(ctx, "alice".into()));
        assert_eq!(ui.inputs.len(), 1);
        assert_eq!(notices(&ui, "не найден"), 1);
        let (_, ui) = drive(vec![ok(&["client", "list"], alice(true)), ok(&["client", "list"], alice(true))], &["P", "0"],
            |ctx| client_card(ctx, "alice".into()));
        assert_eq!(notices(&ui, "только для клиента со своими нодами"), 1);
    }
    #[test]
    fn client_nodes_mirror_current_nodes_and_returning_to_group_is_confirmed() {
        let (core, ui) = drive(vec![
            ok(&["node", "list"], nodes()),
            ok(&["client", "nodes", "--name", "alice", "--node", "de", "--node", "ru"], json!({})),
            step(&["client", "nodes", "--name", "alice", "--inherit"], plan()),
            yes(&["client", "nodes", "--name", "alice", "--inherit"], json!({})),
            step(&["client", "nodes", "--name", "alice", "--inherit"], plan()),
        ], &["1", "2", "", "2", "y", "2", "n", "2", "0"], |ctx| {
            client_nodes(ctx, "alice", false, &["de".into()])?;
            client_nodes(ctx, "alice", false, &["de".into()])?;
            client_nodes(ctx, "alice", false, &["de".into()])?;
            client_nodes(ctx, "alice", true, &["de".into()])
        });
        let toggle = view(&ui, "Свои ноды клиента: alice");
        assert_eq!(toggle.sections[0][0].label, "[x] de  127.0.0.1:22");
        assert_eq!(toggle.sections[0][1].label, "[ ] ru  10.0.0.2:2222");
        assert_eq!(notices(&ui, "Неверный выбор."), 1);
        assert_eq!(core.calls.len(), 5);
    }
    #[test]
    fn client_connections_discover_by_node_name_and_reset_needs_consent() {
        let (core, ui) = drive(vec![
            ok(&["node", "list"], nodes()),
            ok(&["client", "connections", "--name", "alice"], json!([{"node":"de","mode":"own","proxies":["p1"]}])),
            ok(&["conn", "list", "--name", "de", "--discover"], json!([{"node":"de","groups":[],"discovered":["p1","p2"]}])),
            ok(&["client", "connections", "--name", "alice", "--node", "de", "--proxy", "p1", "--proxy", "p2"], json!({})),
            ok(&["node", "list"], nodes()),
            step(&["client", "connections", "--name", "alice", "--node", "de", "--reset"], plan()),
        ], &["1", "1", "2", "", "1", "2", "n"], |ctx| {
            client_connections(ctx, "alice", &["de".into(), "gone".into()])?;
            client_connections(ctx, "alice", &["de".into()])?;
            client_connections(ctx, "alice", &[])
        });
        let picker = view(&ui, "Подключения клиента: alice");
        assert_eq!(picker.sections[0].len(), 2);
        assert!(ui.views.iter().any(|v| v.sections.iter().flatten().any(|i| i.label == "[x] p1")));
        assert_eq!(notices(&ui, "У клиента нет своих нод."), 1);
        assert!(!core.calls.iter().any(|c| c.contains(&"--yes".to_owned())));
    }
    #[test]
    fn ttl_menu_maps_values_and_cancellation_never_publishes() {
        for (selection, ttl) in [("1", None), ("2", Some("12h")), ("3", Some("30d")), ("4", Some("2w")), ("5", Some("7d")), ("0", None)] {
            let mut steps = vec![ok(&["client", "list"], alice(true)), ok(&["subscription", "host"], host())];
            let mut inputs = vec!["P", selection];
            if selection != "0" {
                let mut words = argv(&["subscription", "publish", "--name", "alice"]);
                if let Some(ttl) = ttl { words.extend(argv(&["--ttl", ttl])); }
                steps.push((words, fail("partial", json!({"client":"alice","url":"https://h/sub/tok","expires_at":null}))));
                steps.push(ok(&["subscription", "show", "--name", "alice"], bundle("https://h/sub/tok")));
                if selection == "5" { inputs.push("7d"); }
                inputs.push("");
            }
            steps.extend([ok(&["client", "list"], alice(true)), ok(&["subscription", "host"], host())]);
            inputs.push("0");
            let (_, ui) = drive(steps, &inputs, |ctx| client_subscription(ctx, "alice"));
            assert_eq!(view(&ui, "Срок действия подписки").sections[0][0].label, "Без срока");
        }
        let published = json!([row("alice", true, json!({"published":true,"expires_at":"2026-12-01T00:00:00Z"}))]);
        let (_, ui) = drive(vec![ok(&["client", "list"], published.clone()), ok(&["subscription", "host"], Value::Null),
            ok(&["client", "list"], published), ok(&["subscription", "host"], Value::Null)], &["p", "0", "0"], |ctx| client_subscription(ctx, "alice"));
        assert!(view(&ui, "Срок действия подписки").sections[0][0].label.starts_with("Оставить текущий срок"));
        assert!(content(&ui.views[0]).contains("Хост подписок не задан"));
    }
    #[test]
    fn failed_publish_shows_no_bundle() {
        let (core, _) = drive(vec![
            ok(&["client", "list"], alice(true)), ok(&["subscription", "host"], host()),
            step(&["subscription", "publish", "--name", "alice"], fail("needs_setup", json!({"name":"alice"}))),
            ok(&["client", "list"], alice(true)), ok(&["subscription", "host"], host()),
        ], &["p", "1", "0"], |ctx| client_subscription(ctx, "alice"));
        assert!(!core.calls.iter().any(|c| c[1] == "show"));
    }
    #[test]
    fn share_bundle_has_link_expiry_headers_curl_json_and_qr() {
        let data = json!({"client":"alice","url":"https://h/sub/tok","expires_at":"2026-12-01T00:00:00Z","headers":[{"name":"profile-title","value":"Essence"}]});
        let view = share_view(&data, &["QR-ROW".into()]);
        let text = content(&view);
        for expected in ["Подписка: alice", "https://h/sub/tok", "curl 'https://h/sub/tok'", r#"{"url":"https://h/sub/tok"}"#, "profile-title: Essence", "QR-ROW"] {
            assert!(text.contains(expected), "{expected}");
        }
        assert!(view.sections.is_empty());
        let first = |label: &str| view.context.iter().find(|l| l.spans[0].content == label).unwrap().spans[0].style.fg;
        assert_eq!(first("URL: "), Some(ui::GREEN));
        assert_eq!(first("Срок действия: "), Some(ui::YELLOW));
        let plain = share_view(&bundle("https://h/sub/tok"), &[]);
        assert!(!content(&plain).contains("Срок действия") && !content(&plain).contains("заголовки"));
        #[cfg(unix)] {
            let mut qr = Command::new("sh");
            qr.args(["-c", r#"read -r u; [ $# -eq 0 ] && printf 'QR:%s\n' "$u""#]);
            assert_eq!(qr_lines(&mut qr, "https://h/sub/tok"), ["QR:https://h/sub/tok"]);
        }
        assert!(qr_lines(&mut Command::new("/nonexistent/qrencode"), "u").is_empty());
    }
    #[test]
    fn rotate_and_revoke_use_plans_and_rotation_shows_the_new_bundle() {
        let (_, ui) = drive(vec![
            ok(&["client", "list"], alice(true)), ok(&["subscription", "host"], host()),
            step(&["subscription", "rotate", "--name", "alice"], plan()),
            yes(&["subscription", "rotate", "--name", "alice"], json!({"client":"alice","url":"https://h/sub/NEW"})),
            ok(&["subscription", "show", "--name", "alice"], bundle("https://h/sub/NEW")),
            ok(&["client", "list"], alice(true)), ok(&["subscription", "host"], host()),
            step(&["subscription", "revoke", "--name", "alice"], plan()),
            ok(&["client", "list"], alice(true)), ok(&["subscription", "host"], host()),
            ok(&["subscription", "headers", "--client", "alice"], json!([{"name":"X-A","value":"1","source":"group"}])),
            ok(&["client", "list"], alice(true)), ok(&["subscription", "host"], host()),
        ], &["R", "y", "", "X", "n", "I", "", "0"], |ctx| client_subscription(ctx, "alice"));
        assert!(ui.views.iter().any(|v| content(v).contains("https://h/sub/NEW")));
        assert!(content(view(&ui, "Итоговые заголовки: alice")).contains("X-A: 1  [группа]"));
        assert_eq!(keys(&ui.views[0]), [("p".into(), ui::GREEN), ("v".into(), ui::CYAN), ("i".into(), ui::CYAN), ("h".into(), ui::YELLOW),
            ("r".into(), ui::RED), ("x".into(), ui::RED), ("0".into(), ui::NC)]);
    }
    #[test]
    fn client_headers_delete_only_own_values_and_require_both_fields() {
        let data = json!([{"name":"X-Default","value":"a","source":"default"},{"name":"X-Own","value":"b","source":"client"}]);
        let read = ["subscription", "headers", "--client", "alice"];
        let (core, ui) = drive(vec![
            ok(&read, data.clone()),
            ok(&["subscription", "headers", "--client", "alice", "--set", "X-New=value"], json!({})),
            ok(&read, data.clone()), ok(&read, data.clone()),
            ok(&["subscription", "headers", "--client", "alice", "--unset", "X-Own"], json!({})),
            ok(&read, data),
        ], &["A", "X-New", "value", "a", "X", "", "D", "1", "0"], |ctx| headers(ctx, "client", "alice"));
        let picker = view(&ui, "Удаление заголовка");
        assert_eq!(picker.sections[0].len(), 2);
        assert_eq!(picker.sections[0][0].label, "X-Own");
        assert_eq!(notices(&ui, "Имя и значение заголовка обязательны."), 1);
        assert_eq!(core.calls.len(), 6);
    }
    #[test]
    fn group_headers_list_all_without_source() {
        let (_, ui) = drive(vec![
            ok(&["subscription", "headers", "--group", "PC"], json!([{"name":"X-G","value":"1"}])),
            ok(&["subscription", "headers", "--group", "PC", "--unset", "X-G"], json!({})),
            ok(&["subscription", "headers", "--group", "PC"], json!([])),
        ], &["d", "1", "0"], |ctx| headers(ctx, "group", "PC"));
        let text = content(&ui.views[0]);
        assert!(text.contains("X-G: 1") && !text.contains('['));
    }
    #[test]
    fn groups_add_card_set_template_and_confirmed_delete() {
        let templates = json!([{"name":"default.yaml","source":"builtin","groups":["PC"]},{"name":"m.yaml","source":"custom","groups":[]}]);
        let (_, ui) = drive(vec![
            ok(&["group", "list"], json!([])), ok(&["group", "add", "--name", "pc"], json!({"name":"PC"})),
            ok(&["group", "list"], group_list()), ok(&["group", "list"], group_list()),
            ok(&["template", "list"], templates),
            ok(&["group", "set-template", "--name", "PC", "--template", "m.yaml"], json!({})),
            ok(&["group", "list"], group_list()),
            step(&["group", "delete", "--name", "PC"], plan()), yes(&["group", "delete", "--name", "PC"], json!({"name":"PC"})),
            ok(&["group", "list"], json!([])),
        ], &["A", "pc", "1", "T", "2", "D", "y", "0"], groups);
        assert_eq!(keys(&ui.views[0]), [("a".into(), ui::GREEN), ("0".into(), ui::NC)]);
        let card = view(&ui, "Группа: PC");
        assert!(content(card).contains("Клиентов: 1"));
        assert_eq!(keys(card).last().unwrap(), &("0".into(), ui::NC));
        assert_eq!(keys(card)[3], ("d".into(), ui::RED));
    }
    #[test]
    fn group_new_template_choice_creates_bound_template_then_opens_editor() {
        let (_, ui) = drive(vec![
            ok(&["template", "list"], json!([{"name":"default.yaml","source":"builtin","groups":[]}])),
            ok(&["template", "create", "--name", "new", "--group", "PC"], json!({"name":"new.yaml","based_on":"default.yaml","group":"PC"})),
            step(&["template", "show", "--name", "new.yaml"], fail("not_found", json!({"name":"new.yaml"}))),
        ], &["2", "new"], |ctx| group_template(ctx, "PC", "default.yaml"));
        assert!(ui.views[0].sections[0][1].label.contains("Создать новый"));
        assert!(ui.views[0].title.contains("текущий: default.yaml"));
    }
    #[test]
    fn templates_list_sources_and_create_opens_editor() {
        let list = json!([{"name":"default.yaml","source":"builtin","groups":["PC"]},{"name":"m.yaml","source":"custom","groups":[]}]);
        let (_, ui) = drive(vec![
            ok(&["template", "list"], list.clone()),
            ok(&["template", "create", "--name", "x"], json!({"name":"x.yaml","based_on":"default.yaml","group":null})),
            step(&["template", "show", "--name", "x.yaml"], fail("not_found", json!({}))),
            ok(&["template", "list"], list),
        ], &["a", "x", "0"], templates);
        assert_eq!(ui.views[0].sections[0][0].label, "default.yaml  (встроенный)");
        assert_eq!(ui.views[0].sections[0][1].label, "m.yaml  (пользовательский)");
    }
    #[test]
    fn template_card_shows_content_and_export_import_are_plan_confirmed() {
        let list = json!([{"name":"m.yaml","source":"custom","groups":["PC"]}]);
        let imported = expand_home("~/in.yaml").to_string_lossy().into_owned();
        let import = ["template", "import", "--name", "m.yaml", "--file", imported.as_str()];
        let (_, ui) = drive(vec![
            ok(&["template", "list"], list.clone()),
            ok(&["template", "show", "--name", "m.yaml"], json!({"name":"m.yaml","source":"builtin","path":null,"content":"mode: rule\nproxies:\n"})),
            ok(&["template", "list"], list.clone()),
            step(&["template", "export", "--name", "m.yaml", "--output", "/tmp/export.yaml"], plan()),
            ok(&["template", "list"], list.clone()),
            step(&import, plan()), yes(&import, json!({"name":"m.yaml"})),
            ok(&["template", "list"], list),
        ], &["V", "", "X", "/tmp/export.yaml", "n", "I", "~/in.yaml", "y", "0"], |ctx| template_card(ctx, "m.yaml"));
        let shown = content(view(&ui, "Содержимое: m.yaml"));
        assert!(shown.contains("встроенный шаблон") && shown.contains("mode: rule") && !shown.contains("null"));
        assert_eq!(expand_home("~other/path"), PathBuf::from("~other/path"));
    }
    #[test]
    fn generation_summary_reads_partial_fields_from_error_and_omits_empty_lines() {
        let partial = fail("partial", json!({"ok":["a"],"skipped":["s"],"failed":["bad"],"nodes_ok":["de"],"nodes_failed":["ru"],"dir":"/g"}));
        let (_, ui) = drive(vec![
            ok(&["group", "list"], group_list()), step(&["generate", "--all"], partial),
            ok(&["group", "list"], group_list()), ok(&["group", "list"], group_list()),
            step(&["generate", "--group", "PC"], fail("remote_failed", json!({}))),
            ok(&["group", "list"], group_list()), ok(&["client", "list"], alice(true)),
            ok(&["generate", "--client", "alice"], json!({"ok":["alice"],"skipped":[],"failed":[],"nodes_ok":[],"nodes_failed":[],"dir":"/g"})),
            ok(&["group", "list"], group_list()),
        ], &["A", "", "g", "1", "C", "1", "", "0"], generation);
        let results: Vec<_> = ui.views.iter().filter(|v| v.title == "Итог генерации").collect();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].context.len(), 5);
        assert_eq!(results[0].context.iter().filter(|l| l.style.fg == Some(ui::YELLOW)).count(), 2);
        assert_eq!(results[1].context.len(), 2);
        assert!(results.iter().all(|v| v.sections.is_empty()));
        assert!(content(&ui.views[0]).contains("PC → default.yaml"));
    }
    #[test]
    fn subscription_list_colours_states_without_fake_actions() {
        let (_, ui) = drive(vec![ok(&["subscription", "list"], json!([
            {"client":"a","expires_at":"2030-01-01T00:00:00Z","state":"active"},{"client":"e","expires_at":"2020-01-01T00:00:00Z","state":"expired"},
            {"client":"u","expires_at":null,"state":"unlimited"},{"client":"k","expires_at":"bad","state":"unknown"}]))], &[""], subscription_list);
        let list = &ui.views[0];
        assert!(list.sections.is_empty());
        assert_eq!(list.context.iter().map(|l| l.spans[1].style.fg.unwrap()).collect::<Vec<_>>(), [ui::GREEN, ui::YELLOW, ui::DIM, ui::DIM]);
        assert!(content(list).contains("u  —  без срока"));
    }
    #[test]
    fn publish_all_summary_and_migration_by_node_name_are_confirmed() {
        let (core, ui) = drive(vec![
            ok(&["subscription", "host"], host()), step(&["subscription", "publish-all"], plan()),
            yes(&["subscription", "publish-all"], json!({"published":["alice"],"skipped":[],"failed":[],"removed":0})),
            ok(&["subscription", "host"], host()), ok(&["node", "list"], nodes()),
            step(&["subscription", "migrate", "--name", "ru"], plan()),
            ok(&["subscription", "host"], host()), step(&["subscription", "publish-all"], plan()),
            (yes(&["subscription", "publish-all"], Value::Null).0, fail("remote_failed", json!({"published":[],"skipped":[],"failed":["alice"],"removed":0}))),
            ok(&["subscription", "host"], host()),
        ], &["U", "y", "", "M", "2", "n", "u", "y", "", "0"], subscriptions);
        let results: Vec<_> = ui.views.iter().filter(|v| v.title == "Итог публикации подписок").map(content).collect();
        assert_eq!(results.len(), 2);
        assert!(results[0].contains("Опубликовано: alice") && !results[0].contains("Удалено"));
        assert!(results[1].contains("Ошибки: alice"));
        assert!(!sent(&core, &["subscription", "migrate", "--name", "ru", "--yes", "--plan-token", "T"]));
        assert_eq!(ui.views[0].context[0].spans[1].style.fg, Some(ui::GREEN));
        assert_eq!(keys(&ui.views[0]).len(), 7);
    }
    #[test]
    fn host_picker_resolves_missing_secret_without_password_in_argv() {
        let (core, ui) = drive(vec![
            ok(&["subscription", "host"], Value::Null), ok(&["node", "list"], nodes()),
            step(&["subscription", "host", "--name", "de"], fail("missing_secret", json!({"name":"de"}))),
            ok(&["node", "password", "--name", "de"], json!({})),
            ok(&["subscription", "host", "--name", "de"], host()),
            ok(&["subscription", "host"], host()),
        ], &["H", "1", "y", "PRIVATE-PASSWORD", "0"], subscriptions);
        assert_eq!(core.secret_names[3], ["password"]);
        assert!(core.secret_names.iter().enumerate().all(|(i, s)| i == 3 || s.is_empty()));
        assert!(!core.calls.iter().flatten().any(|s| s.contains("PRIVATE-PASSWORD")));
        assert!(!ui.views.iter().any(|v| content(v).contains("PRIVATE-PASSWORD")));
        assert!(content(&ui.views[0]).contains("Хост-нода подписок не задана"));
    }
    #[test]
    fn host_key_trust_refusal_never_retries_the_host_command() {
        let changed = fail("host_key_changed", json!({"host":"127.0.0.1","port":22,"fingerprints":["SHA256:key"]}));
        let (_, ui) = drive(vec![
            step(&["subscription", "host", "--name", "de"], changed),
            step(&["node", "trust-host-key", "--name", "de", "--host-key", "SHA256:key"], plan()),
        ], &["n"], |ctx| { assert!(node_request(ctx, "de", &["subscription", "host", "--name", "de"])?.is_none()); Ok(()) });
        assert_eq!(notices(&ui, "Операция завершилась ошибкой"), 1);
    }
    #[test]
    fn unknown_keys_and_enter_keep_every_menu() {
        type Run = fn(&mut Context<'_>) -> io::Result<()>;
        let cases: Vec<(Vec<Step>, Run)> = vec![
            (vec![ok(&["client", "list"], json!([]))], clients),
            (vec![ok(&["group", "list"], json!([]))], groups),
            (vec![ok(&["template", "list"], json!([]))], templates),
            (vec![ok(&["group", "list"], json!([]))], generation),
            (vec![ok(&["subscription", "host"], Value::Null)], subscriptions),
            (vec![ok(&["client", "list"], alice(false))], |ctx| client_card(ctx, "alice".into())),
            (vec![ok(&["client", "list"], alice(false)), ok(&["subscription", "host"], host())], |ctx| client_subscription(ctx, "alice")),
            (vec![ok(&["subscription", "headers", "--client", "alice"], json!([]))], |ctx| headers(ctx, "client", "alice")),
            (vec![ok(&["group", "list"], group_list())], |ctx| group_card(ctx, "PC")),
            (vec![ok(&["template", "list"], json!([{"name":"m.yaml","source":"custom","groups":[]}]))], |ctx| template_card(ctx, "m.yaml")),
        ];
        for (reads, run) in cases {
            let steps: Vec<Step> = (0..3).flat_map(|_| reads.clone()).collect();
            let (_, ui) = drive(steps, &["unknown", "", "0"], run);
            assert_eq!(notices(&ui, "Неверный выбор."), 2);
        }
    }
    #[test]
    fn failed_screen_read_offers_explicit_retry_only() {
        let (core, ui) = drive(vec![step(&["client", "list"], fail("remote_failed", json!({}))), ok(&["client", "list"], json!([]))],
            &["x", "R", "0"], clients);
        assert_eq!(core.calls.len(), 2);
        assert_eq!(keys(&ui.views[0]), [("r".into(), ui::YELLOW), ("0".into(), ui::NC)]);
        assert_eq!(notices(&ui, "Неверный выбор."), 1);
    }
    struct EditorUi { inner: ScriptedUi, replacement: Option<&'static [u8]>, succeeds: bool, suspended: usize }
    impl UserInterface for EditorUi {
        fn input(&mut self, view: &View, hidden: bool) -> io::Result<Option<zeroize::Zeroizing<String>>> { self.inner.input(view, hidden) }
        fn show(&mut self, view: &View) -> io::Result<()> { self.inner.show(view) }
        fn notice(&mut self, line: Line<'static>) { self.inner.notice(line) }
        fn log(&mut self, log: &Log) { self.inner.log(log) }
        fn suspended(&mut self, command: &mut Command) -> io::Result<std::process::ExitStatus> {
            self.suspended += 1;
            let file = PathBuf::from(command.get_args().last().unwrap());
            if let Some(content) = self.replacement { fs::write(file, content)?; }
            #[cfg(unix)] { use std::os::unix::process::ExitStatusExt; Ok(std::process::ExitStatus::from_raw(if self.succeeds { 0 } else { 256 })) }
            #[cfg(windows)] { use std::os::windows::process::ExitStatusExt; Ok(std::process::ExitStatus::from_raw(if self.succeeds { 0 } else { 1 })) }
        }
    }
    #[test]
    fn editor_no_change_and_failure_import_nothing_changes_are_plan_confirmed() {
        let changed = Some(b"changed".as_slice());
        for (replacement, succeeds, planned, consent, notice) in [
            (None, true, false, "", "Изменений нет."), (changed, false, false, "", "Редактор завершился с ошибкой"),
            (changed, true, true, "y", ""), (changed, true, true, "n", ""), (changed, true, false, "", ""),
        ] {
            let file = tempfile::NamedTempFile::new().unwrap();
            fs::write(file.path(), b"original").unwrap();
            let path = file.path().to_str().unwrap();
            let import = ["template", "import", "--name", "m.yaml", "--file", path];
            let mut steps = vec![];
            if replacement.is_some() && succeeds {
                if planned {
                    steps.push(step(&import, plan()));
                    if consent == "y" { steps.push(yes(&import, json!({"name":"m.yaml"}))); }
                } else { steps.push(ok(&import, json!({"name":"m.yaml"}))); }
            }
            let registry = Registry { screens: vec![], github_wizard: None };
            let mut core = ScriptedClient::new(steps);
            let mut ui = EditorUi { inner: ScriptedUi::new(&[consent]), replacement, succeeds, suspended: 0 };
            edit_file(&mut Context { client: &mut core, ui: &mut ui, registry: &registry }, "m.yaml", &["editor".into()], file.path(), b"original").unwrap();
            assert_eq!(ui.suspended, 1);
            core.assert_finished();
            if !notice.is_empty() { assert_eq!(notices(&ui.inner, notice), 1); }
            assert_eq!(ui.inner.views.iter().filter(|v| v.prompt.contains("(y/N)")).count(), usize::from(planned));
        }
    }
    #[test]
    fn vanished_template_never_opens_the_editor() {
        let (_, ui) = drive(vec![step(&["template", "show", "--name", "gone.yaml"], fail("not_found", json!({})))], &[], |ctx| edit_template(ctx, "gone.yaml"));
        assert_eq!(ui.suspensions, 0);
        assert_eq!(notices(&ui, "Операция завершилась ошибкой"), 1);
    }
    #[test]
    fn editor_argument_parser_handles_quotes_and_rejects_unclosed_quotes() {
        assert_eq!(editor_words("\"/path with spaces/editor\" --wait 'a b'").unwrap(), ["/path with spaces/editor", "--wait", "a b"]);
        assert_eq!(editor_words(r#""C:\Program Files\Editor\edit.exe" --wait"#).unwrap(), [r"C:\Program Files\Editor\edit.exe", "--wait"]);
        assert_eq!(editor_words("code -w").unwrap(), ["code", "-w"]);
        assert!(editor_words("\"unclosed").is_err());
        assert!(editor_words("").is_err());
    }
    #[test]
    fn editor_directory_and_file_are_private_and_cleaned_on_drop() {
        let dir = private_editor_dir().unwrap();
        let file = tempfile::Builder::new().suffix(".yaml").tempfile_in(dir.path()).unwrap();
        let path = dir.path().to_owned();
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o700);
            assert_eq!(file.as_file().metadata().unwrap().permissions().mode() & 0o777, 0o600);
        }
        drop(file);
        drop(dir);
        assert!(!path.exists());
    }
    #[test]
    fn selectors_reject_expressions_and_empty_lists_read_nothing() {
        let (_, ui) = drive(vec![], &["01", "+1", "1+1", "", "1", "0"], |ctx| {
            assert_eq!(ctx.toggle("Toggle", &["one".into()], vec![false], EMPTY)?, Some(vec![]));
            Ok(())
        });
        assert_eq!(notices(&ui, "Неверный выбор."), 3);
        assert_eq!(index("01", 1), None);
        assert_eq!(index(" 1", 1), None);
        let (_, ui) = drive(vec![ok(&["group", "list"], json!([]))], &["untouched"], |ctx| {
            assert!(pick(ctx, "group", "Empty")?.is_none());
            assert!(ctx.toggle("Empty toggle", &[], vec![], EMPTY)?.is_none());
            Ok(())
        });
        assert_eq!(ui.inputs.len(), 1);
        assert_eq!(ui.views.len(), 2);
    }
}
