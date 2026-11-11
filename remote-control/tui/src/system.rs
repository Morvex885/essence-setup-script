//! Startup gate (first run, `session open`, GitHub recovery), dashboard and
//! settings — v1 `tui/system.sh`. Source screens and the GitHub wizard live in
//! `source.rs`; the recovery commands share its `recovery_run`.
use std::io;
use ratatui::{style::{Color, Style}, text::{Line, Span}};
use serde_json::Value;
use zeroize::Zeroizing;
use crate::{app::{Context, Navigation, Screen}, confirm::run_confirmed, serve::{argv, Reply, Secrets}, source::{recovery_run, report}, ui::{self, Item, View}};

/// `v` prefix exactly once (v1 `_tui_version`).
pub fn version_label(version: &str) -> String { format!("v{}", version.strip_prefix('v').unwrap_or(version)) }
/// Sync state word and colour of a GitHub source (`clean`/`pending`/other).
pub fn sync_state(sync: &Value) -> (&'static str, Color) {
    match sync.as_str() {
        Some("clean") => ("синхронизировано", ui::GREEN),
        Some("pending") => ("ожидает отправки", ui::YELLOW),
        _ => ("нет связи", ui::YELLOW),
    }
}
/// A new password entered twice; empty or mismatching input cancels with a warning.
pub fn new_password(context: &mut Context<'_>, title: &str) -> io::Result<Option<Zeroizing<String>>> {
    let Some(first) = context.secret(title, "Новый пароль")? else { return Ok(None); };
    if first.is_empty() { context.ui.notice(ui::warn("Пароль не может быть пустым.")); return Ok(None); }
    let Some(second) = context.secret(title, "Повторите пароль")? else { return Ok(None); };
    if first != second { context.ui.notice(ui::warn("Пароли не совпадают.")); return Ok(None); }
    Ok(Some(first))
}
/// v1 `startup_recovery_menu TITLE true`: `1` retries, `0`/EOF exits.
fn retry(context: &mut Context<'_>, title: &str) -> io::Result<bool> {
    let mut view = View::menu("Восстановление запуска", vec![Item::new(1, "Повторить", ui::CYAN), Item::new(0, "Выход", ui::NC)]);
    view.mode = ui::Mode::Root;
    view.context.push(ui::warn(title));
    loop {
        match context.choose(&view)?.as_deref() {
            Some("1") => return Ok(true),
            None | Some("0") => return Ok(false),
            _ => context.invalid(),
        }
    }
}

// ─── Startup ─────────────────────────────────────────────────────────────────

/// Outcome of the startup gate (v1 `tui_startup`: rc 0 / 2 / 1).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gate {
    /// The session is open; the dashboard may start.
    Open,
    /// «Выход» chosen on the first-run screen: a normal exit (code 0).
    Quit,
    /// The session could not be opened (read failure, EOF, declined
    /// recovery): the menu exits with code 1.
    Failed,
}
pub fn session_gate(context: &mut Context<'_>) -> io::Result<Gate> {
    let status = context.call(&["session", "status"])?;
    if !status.ok { context.failed(); return Ok(Gate::Failed); }
    if status.data["configured"] != true {
        let gate = first_run(context)?;
        if gate != Gate::Open { return Ok(gate); }
    }
    Ok(if open_session(context)? { Gate::Open } else { Gate::Failed })
}
fn first_run(context: &mut Context<'_>) -> io::Result<Gate> {
    let mut view = View::menu("Первый запуск", vec![
        Item::new(1, "Локальная конфигурация", ui::GREEN),
        Item::new(2, "Конфигурация в GitHub", ui::GREEN),
        Item::new(0, "Выход", ui::NC),
    ]);
    view.mode = ui::Mode::Root;
    view.prompt = "Выберите источник: ".into();
    loop {
        match context.choose(&view)?.as_deref() {
            Some("1") => { if context.call(&["source", "init-local"])?.ok { return Ok(Gate::Open); } context.failed(); },
            Some("2") => { if context.wizard("connect")? { return Ok(Gate::Open); } },
            Some("0") => return Ok(Gate::Quit),
            None => return Ok(Gate::Failed),
            _ => context.invalid(),
        }
    }
}
/// `session open` with accumulated secrets; every code per the startup plan.
fn open_session(context: &mut Context<'_>) -> io::Result<bool> {
    let mut secrets = Secrets::default();
    let (mut script_tries, mut vault_tries) = (0, 0);
    let mut remember = false;
    loop {
        let mut words = argv(&["session", "open"]);
        if remember { words.push("--remember-key".into()); }
        let reply = context.request(&words, &secrets)?;
        if reply.ok { return Ok(true); }
        match reply.code() {
            "vault_password_required" | "vault_password_invalid" => {
                if vault_tries >= 3 {
                    vault_tries = 0;
                    secrets.clear();
                    if !retry(context, "Доступ к конфигурации GitHub")? { return Ok(false); }
                    continue;
                }
                vault_tries += 1;
                let Some(password) = context.secret("Открытие сессии", "Пароль доступа к конфигурации GitHub")? else { return Ok(false); };
                secrets.insert_hidden("vault-password", password);
                remember = context.confirm(View::new("Ключ расшифровки"), "Сохранить ключ расшифровки на этом устройстве?")?;
            },
            "auth_required" | "auth_failed" => {
                if script_tries >= 3 {
                    script_tries = 0;
                    secrets.clear();
                    if !retry(context, "Восстановление доступа")? { return Ok(false); }
                    continue;
                }
                script_tries += 1;
                let Some(password) = context.secret("Открытие сессии", "Введите пароль")? else { return Ok(false); };
                secrets.insert_hidden("script-password", password);
            },
            "github_format_outdated" | "github_format_newer" | "github_format_invalid" => {
                if !github_recovery(context, &reply, &mut secrets)? { return Ok(false); }
            },
            "locked" => {
                secrets.clear();
                if !retry(context, "Конфигурация занята")? { return Ok(false); }
            },
            _ => {
                secrets.clear();
                if !retry(context, "Не удалось открыть конфигурацию")? { return Ok(false); }
            },
        }
    }
}
/// «Конфигурация GitHub требует восстановления». `true` — published, reopen.
/// The gate's secrets travel with the recovery commands (v1 kept them too).
fn github_recovery(context: &mut Context<'_>, reply: &Reply, secrets: &mut Secrets) -> io::Result<bool> {
    let code = reply.code();
    let outdated = code == "github_format_outdated";
    let newer = code == "github_format_newer";
    let mut view = View::new("Конфигурация GitHub требует восстановления");
    if let Some(message) = reply.error["message"].as_str().filter(|m| !m.is_empty()) { view.context.push(ui::text(message, ui::YELLOW)); }
    if let Some(version) = reply.error["version"].as_str().filter(|v| !v.is_empty()) { view.context.push(Line::raw(format!("Формат конфигурации: v{version}"))); }
    if let Some(required) = reply.error["required"].as_str().filter(|v| !v.is_empty()) { view.context.push(Line::raw(format!("Требуется remote-control: {}", version_label(required)))); }
    let mut items = vec![];
    if outdated { items.push(Item::new(1, "Преобразовать конфигурацию", ui::YELLOW)); }
    if !newer { items.push(Item::new(2, "Заменить конфигурацией с этого устройства", ui::RED)); }
    items.push(Item::new(0, "Выход", ui::NC));
    view.sections.push(items);
    view.mode = ui::Mode::Root;
    view.prompt = "Выберите действие: ".into();
    loop {
        let result = match context.choose(&view)?.as_deref() {
            Some("1") if outdated => recovery_run(context, "Преобразование конфигурации GitHub", "Преобразовать и опубликовать конфигурацию?", "github-migrate-format", secrets)?,
            Some("2") if !newer => recovery_run(context, "Замена конфигурации GitHub", "Заменить конфигурацию в GitHub?", "github-replace-with-local", secrets)?,
            None | Some("0") => return Ok(false),
            _ => { context.invalid(); continue; },
        };
        match result {
            Some(reply) if reply.ok => return Ok(true),
            Some(reply) => report(context, &reply),
            None => {},
        }
    }
}

// ─── Dashboard ───────────────────────────────────────────────────────────────

pub struct Dashboard;
/// Canonical key map: one ASCII letter, both cases, or `0`.
pub fn dashboard_route(key: &str) -> Option<char> {
    let mut chars = key.chars();
    let ch = chars.next()?.to_ascii_lowercase();
    (chars.next().is_none() && "ncgmpfsatio0".contains(ch)).then_some(ch)
}
/// The header and context come only from `status`.
pub fn dashboard_view(data: &Value, version: &str) -> View {
    let mut view = View::new(format!("Remote Control {}", version_label(data["version"].as_str().unwrap_or(version))));
    if data["update"]["available"] == true {
        let latest = version_label(data["update"]["latest"].as_str().unwrap_or(""));
        view.status.push(ui::text(format!("Доступно обновление {latest} — раздел o"), ui::YELLOW));
    }
    if data["source"]["type"] == "github" {
        let (label, color) = sync_state(&data["source"]["sync"]);
        let repo = data["source"]["repo"].as_str().unwrap_or("");
        view.context.push(Line::from(vec![Span::raw(format!("Источник: GitHub {repo} • ")), Span::styled(label, Style::default().fg(color))]));
    } else {
        view.context.push(Line::raw("Источник: локальная"));
    }
    let count = |key: &str| data["counts"][key].as_u64().unwrap_or(0);
    view.context.push(Line::raw(format!("Ноды: {}  Клиенты: {}  Группы: {}", count("nodes"), count("clients"), count("groups"))));
    match data["subscription_host"].as_str().filter(|host| !host.is_empty()) {
        Some(host) => view.context.push(Line::raw(format!("Хост подписок: {host}"))),
        None => view.context.push(ui::text("Хост подписок не задан", ui::DIM)),
    }
    let missing: Vec<&str> = data["password_missing"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    if !missing.is_empty() { view.context.push(ui::text(format!("Нет пароля SSH: {}", missing.join(", ")), ui::YELLOW)); }
    if data["ssh_setup_pending"] == true { view.context.push(ui::text("Отложена SSH-настройка нод — раздел n → h", ui::YELLOW)); }
    view.sections = vec![
        vec![
            Item::new('n', "Ноды", ui::GREEN), Item::new('c', "Клиенты", ui::GREEN), Item::new('g', "Группы", ui::GREEN), Item::new('m', "Шаблоны", ui::GREEN),
            Item::new('p', "Подключения", ui::YELLOW), Item::new('f', "Генерация конфигов", ui::YELLOW), Item::new('s', "Подписки", ui::YELLOW),
            Item::new('a', "AmneziaWG", ui::CYAN), Item::new('t', "Telegram Proxy", ui::CYAN),
        ],
        vec![Item::new('i', "Источник конфигурации", ui::CYAN), Item::new('o', "Настройки", ui::YELLOW), Item::new(0, "Выход", ui::NC)],
    ];
    view.mode = ui::Mode::Root;
    view.footer.push(ui::text(" ↑/↓ — выбор   Enter/→ — открыть   Esc/← — назад", ui::DIM));
    view.prompt = "Выберите действие: ".into();
    view
}
impl Screen for Dashboard {
    fn run(&mut self, context: &mut Context<'_>) -> io::Result<Navigation> {
        loop {
            let reply = context.call(&["status"])?;
            if !reply.ok {
                if retry(context, "Не удалось получить сводку")? { continue; }
                return Ok(Navigation::Back);
            }
            let view = dashboard_view(&reply.data, context.client.version());
            let Some(choice) = context.choose(&view)? else { return Ok(Navigation::Back); };
            match dashboard_route(&choice) {
                Some('0') => return Ok(Navigation::Back),
                Some(key) => match context.registry.screens.iter().find(|route| route.key == key) {
                    Some(route) => return Ok(Navigation::Push((route.factory)())),
                    None => context.invalid(),
                },
                None => context.invalid(),
            }
        }
    }
}

// ─── Settings ────────────────────────────────────────────────────────────────

pub struct Settings;
/// `self version` once per visit (network check), `status` on every redraw.
fn settings_view(version: &Reply, password: bool) -> (View, bool) {
    let mut view = View::new("Настройки");
    let available = version.ok && version.data["update_available"] == true;
    if version.ok {
        view.context.push(Line::raw(format!("Версия: {}", version_label(version.data["current"].as_str().unwrap_or("")))));
        if version.data["checked"] == true {
            view.context.push(Line::raw(format!("Последняя: {}", version_label(version.data["latest"].as_str().unwrap_or("")))));
        } else {
            view.context.push(ui::text("Не удалось проверить обновления", ui::DIM));
        }
    }
    view.context.push(Line::raw(if password { "Пароль запуска: установлен" } else { "Пароль запуска: не установлен" }));
    let mut items = vec![];
    if available { items.push(Item::new('u', "Обновить remote-control", ui::YELLOW)); }
    if password {
        items.push(Item::new('l', "Сменить пароль запуска", ui::YELLOW));
        items.push(Item::new('r', "Убрать пароль запуска", ui::RED));
    } else {
        items.push(Item::new('l', "Установить пароль запуска", ui::YELLOW));
    }
    items.push(Item::new('x', "Удалить remote-control", ui::RED));
    items.push(Item::new(0, "Назад", ui::NC));
    view.sections.push(items);
    view.prompt = "Выберите действие: ".into();
    (view, available)
}
impl Screen for Settings {
    fn run(&mut self, context: &mut Context<'_>) -> io::Result<Navigation> {
        let version = context.call(&["self", "version"])?;
        loop {
            let status = context.call(&["status"])?;
            let password = status.ok && status.data["script_password"] == true;
            let (view, available) = settings_view(&version, password);
            let Some(choice) = context.choose(&view)? else { return Ok(Navigation::Back); };
            match choice.to_ascii_lowercase().as_str() {
                "u" if available => {
                    let reply = run_confirmed(context, "Обновление", "Обновить remote-control?", &argv(&["self", "update"]), &Secrets::default())?;
                    if reply.ok { return Ok(Navigation::Exit(0)); }
                    report(context, &reply);
                },
                "l" => {
                    let mut secrets = Secrets::default();
                    if password {
                        let Some(current) = context.secret("Пароль запуска", "Текущий пароль запуска")? else { continue; };
                        secrets.insert_hidden("current-password", current);
                    }
                    let Some(new) = new_password(context, "Пароль запуска")? else { continue; };
                    secrets.insert_hidden("password", new);
                    let reply = context.request(&argv(&["self", "password-set"]), &secrets)?;
                    report(context, &reply);
                },
                "r" if password => {
                    let Some(current) = context.secret("Пароль запуска", "Текущий пароль запуска")? else { continue; };
                    let mut secrets = Secrets::default();
                    secrets.insert_hidden("current-password", current);
                    let reply = run_confirmed(context, "Пароль запуска", "Убрать пароль запуска?", &argv(&["self", "password-remove"]), &secrets)?;
                    report(context, &reply);
                },
                "x" => {
                    let labels = ["Сохранить локальные данные".to_owned(), "Удалить локальные данные".to_owned()];
                    let Some(scope) = context.select("Удаление remote-control", &labels)? else { continue; };
                    let mut words = argv(&["self", "uninstall"]);
                    if scope == 1 { words.push("--remove-data".into()); }
                    let reply = run_confirmed(context, "Удаление remote-control", "Удалить remote-control в выбранном объёме?", &words, &Secrets::default())?;
                    if reply.ok { return Ok(Navigation::Exit(0)); }
                    report(context, &reply);
                },
                "0" => return Ok(Navigation::Back),
                _ => context.invalid(),
            }
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{app::{Registration, Registry, ScriptedUi}, serve::ScriptedClient};
    use serde_json::json;
    pub(crate) fn error(code: &str, extra: Value) -> Reply {
        let mut reply = Reply::failure(code);
        for (key, value) in extra.as_object().into_iter().flatten() { reply.error[key] = value.clone(); }
        reply
    }
    pub(crate) fn plan(token: &str) -> Reply { error("confirmation_required", json!({"plan":["План: X"],"plan_token":token})) }
    pub(crate) fn ok() -> Reply { Reply::success(Value::Null) }
    pub(crate) fn words(parts: &[&str]) -> Vec<String> { argv(parts) }
    /// Frame rules on recorded views: 70 columns, no adjacent separators,
    /// a separator under the header whenever there is a body.
    pub(crate) fn assert_frames(views: &[View]) {
        for view in views {
            let lines: Vec<String> = view.lines().iter().map(ToString::to_string).collect();
            assert_eq!(lines[0], "");
            for line in &lines[1..] { assert_eq!(line.chars().count(), 70, "{line}"); }
            assert!(!lines.windows(2).any(|rows| rows[0].starts_with('├') && rows[1].starts_with('├')), "{lines:?}");
            let body = !view.context.is_empty() || view.sections.iter().any(|s| !s.is_empty());
            assert_eq!(lines.iter().any(|l| l.starts_with('├')), body, "{lines:?}");
            assert!(view.sections.iter().all(|s| !s.is_empty()), "empty section drawn");
        }
    }
    fn keys(view: &View) -> Vec<String> { view.sections.iter().flatten().map(|i| i.key.clone()).collect() }
    fn notice_texts(ui: &ScriptedUi) -> Vec<String> { ui.notices.iter().map(ToString::to_string).collect() }
    fn registry() -> Registry { Registry { screens: vec![], github_wizard: None } }
    fn configured() -> (Vec<String>, Reply) { (words(&["session", "status"]), Reply::success(json!({"configured":true,"source":"github","open":false,"authorized":false}))) }
    fn open() -> Vec<String> { words(&["session", "open"]) }
    fn gate(client: &mut ScriptedClient, ui: &mut ScriptedUi, registry: &Registry) -> bool {
        session_gate(&mut Context { client, ui, registry }).unwrap() == Gate::Open
    }

    #[test] fn first_run_local_wizard_exit_and_eof() {
        let unconfigured = (words(&["session", "status"]), Reply::success(json!({"configured":false,"source":null,"open":false,"authorized":false})));
        let mut client = ScriptedClient::new([unconfigured.clone(), (words(&["source", "init-local"]), error("conflict", json!({}))), (words(&["source", "init-local"]), Reply::success(json!({"source":"local"}))), (open(), Reply::success(json!({"source":"local"})))]);
        let mut ui = ScriptedUi::new(&["x", "", "1", "1"]);
        assert!(gate(&mut client, &mut ui, &registry()));
        client.assert_finished();
        assert!(notice_texts(&ui).iter().filter(|n| n.contains("Неверный выбор.")).count() == 2);
        assert_eq!(keys(&ui.views[0]), ["1", "2", "0"]);
        assert!(ui.views[0].sections[0][..2].iter().all(|i| i.color == ui::GREEN));
        assert_frames(&ui.views);
        fn wizard(_: &mut Context<'_>, mode: &str) -> io::Result<bool> { assert_eq!(mode, "connect"); Ok(true) }
        let with_wizard = Registry { screens: vec![], github_wizard: Some(wizard) };
        let mut client = ScriptedClient::new([unconfigured.clone(), (open(), ok())]);
        assert!(gate(&mut client, &mut ScriptedUi::new(&["2"]), &with_wizard));
        client.assert_finished();
        // v1 rc: «Выход» is a normal quit, EOF a failed start.
        for (inputs, expected) in [(&["0"][..], Gate::Quit), (&[][..], Gate::Failed)] {
            let mut client = ScriptedClient::new([unconfigured.clone()]);
            let mut ui = ScriptedUi::new(inputs);
            assert_eq!(session_gate(&mut Context { client: &mut client, ui: &mut ui, registry: &registry() }).unwrap(), expected);
            client.assert_finished();
        }
        let mut client = ScriptedClient::new([(words(&["session", "status"]), error("failed", json!({})))]);
        let mut ui = ScriptedUi::new(&[]);
        assert_eq!(session_gate(&mut Context { client: &mut client, ui: &mut ui, registry: &registry() }).unwrap(), Gate::Failed);
    }
    #[test] fn vault_password_and_remember_key_accumulate_until_open() {
        let mut client = ScriptedClient::new([configured(), (open(), error("vault_password_required", json!({"secret":"vault-password"}))),
            (open(), error("vault_password_invalid", json!({}))), (words(&["session", "open", "--remember-key"]), error("auth_required", json!({}))),
            (words(&["session", "open", "--remember-key"]), ok())]);
        let mut ui = ScriptedUi::new(&["p1", "n", "p2", "y", "script-pw"]);
        assert!(gate(&mut client, &mut ui, &registry()));
        client.assert_finished();
        assert_eq!(client.secret_names[2], ["vault-password"]);
        assert_eq!(client.secret_names[4], ["script-password", "vault-password"]);
        for secret in ["p1", "p2", "script-pw"] {
            assert!(!format!("{:?}{:?}", ui.views, client.calls).contains(secret));
        }
    }
    #[test] fn three_wrong_script_passwords_offer_retry_that_resets_secrets() {
        let mut steps = vec![configured()];
        steps.extend((0..4).map(|_| (open(), error("auth_failed", json!({})))));
        steps.extend([(open(), error("auth_required", json!({}))), (open(), ok())]);
        let mut client = ScriptedClient::new(steps);
        let mut ui = ScriptedUi::new(&["a", "b", "c", "?", "1", "d"]);
        assert!(gate(&mut client, &mut ui, &registry()));
        client.assert_finished();
        assert_eq!(client.secret_names[5], Vec::<String>::new(), "retry clears secrets");
        assert_eq!(client.secret_names[6], ["script-password"]);
        assert!(ui.views.iter().any(|v| v.title == "Восстановление запуска" && keys(v) == ["1", "0"]));
        let mut steps = vec![configured()];
        steps.extend((0..4).map(|_| (open(), error("auth_failed", json!({})))));
        let mut client = ScriptedClient::new(steps);
        assert!(!gate(&mut client, &mut ScriptedUi::new(&["a", "b", "c", "0"]), &registry()));
        client.assert_finished();
    }
    #[test] fn locked_and_source_failed_retry_explicitly_or_exit() {
        for code in ["locked", "source_failed"] {
            let mut client = ScriptedClient::new([configured(), (open(), error(code, json!({}))), (open(), ok())]);
            let mut ui = ScriptedUi::new(&["", "1"]);
            assert!(gate(&mut client, &mut ui, &registry()));
            client.assert_finished();
            let context = ui.views[0].context[0].to_string();
            assert!(context.contains(if code == "locked" { "Конфигурация занята" } else { "Не удалось открыть конфигурацию" }));
            let mut client = ScriptedClient::new([configured(), (open(), error(code, json!({})))]);
            assert!(!gate(&mut client, &mut ScriptedUi::new(&["0"]), &registry()));
            client.assert_finished();
        }
    }
    #[test] fn outdated_format_migrates_with_gate_secrets_and_own_password_then_reopens() {
        let migrate = words(&["source", "github-migrate-format"]);
        let mut confirmed = migrate.clone();
        confirmed.extend(words(&["--yes", "--plan-token", "T1"]));
        let mut client = ScriptedClient::new([configured(), (open(), error("vault_password_required", json!({}))),
            (open(), error("github_format_outdated", json!({"message":"Формат устарел","version":"1","required":null}))),
            (migrate.clone(), error("auth_required", json!({}))), (migrate.clone(), plan("T1")), (confirmed, ok()), (open(), ok())]);
        let mut ui = ScriptedUi::new(&["vp", "n", "1", "pw", "y"]);
        assert!(gate(&mut client, &mut ui, &registry()));
        client.assert_finished();
        assert_eq!(client.secret_names[3], ["vault-password"]);
        assert_eq!(client.secret_names[5], ["script-password", "vault-password"]);
        let recovery = ui.views.iter().find(|v| v.title == "Конфигурация GitHub требует восстановления").unwrap();
        assert_eq!(keys(recovery), ["1", "2", "0"]);
        let context: Vec<String> = recovery.context.iter().map(ToString::to_string).collect();
        assert!(context.contains(&"Формат конфигурации: v1".to_owned()));
        assert_frames(&ui.views);
    }
    #[test] fn newer_format_offers_only_exit_and_invalid_offers_replace() {
        let mut client = ScriptedClient::new([configured(), (open(), error("github_format_newer", json!({"version":"9","required":"9.9.9"})))]);
        let mut ui = ScriptedUi::new(&["1", "2", "0"]);
        assert!(!gate(&mut client, &mut ui, &registry()));
        client.assert_finished();
        assert_eq!(keys(&ui.views[0]), ["0"]);
        assert!(ui.views[0].context.iter().any(|l| l.to_string() == "Требуется remote-control: v9.9.9"));
        assert_eq!(ui.notices.len(), 2);
        // Refusing the replacement plan stays in the recovery menu without a failure warning.
        let replace = words(&["source", "github-replace-with-local"]);
        let mut client = ScriptedClient::new([configured(), (open(), error("github_format_invalid", json!({}))), (replace, plan("T1"))]);
        let mut ui = ScriptedUi::new(&["2", "n", "0"]);
        assert!(!gate(&mut client, &mut ui, &registry()));
        client.assert_finished();
        assert_eq!(keys(&ui.views[0]), ["2", "0"]);
        assert!(ui.views[0].sections[0][0].color == ui::RED);
        assert!(ui.notices.is_empty());
    }
    fn status_data() -> Value {
        json!({"version":"1.1.0","update":{"current":"1.1.0","latest":"v1.2.0","available":true},"script_password":false,
            "source":{"type":"github","repo":"o/r","sync":"pending"},"counts":{"nodes":2,"groups":3,"clients":1},
            "password_missing":["ru"],"ssh_setup_pending":true,"subscription_host":null})
    }
    #[test] fn dashboard_header_is_exactly_the_status_fields() {
        let view = dashboard_view(&status_data(), "0.0.0");
        assert_eq!(view.title, "Remote Control v1.1.0");
        assert_eq!(view.status[0].to_string(), "Доступно обновление v1.2.0 — раздел o");
        let context: Vec<String> = view.context.iter().map(ToString::to_string).collect();
        assert_eq!(context, ["Источник: GitHub o/r • ожидает отправки", "Ноды: 2  Клиенты: 1  Группы: 3", "Хост подписок не задан", "Нет пароля SSH: ru", "Отложена SSH-настройка нод — раздел n → h"]);
        assert_eq!(view.context[0].spans[1].style.fg, Some(ui::YELLOW));
        assert_eq!(view.context[2].style.fg, Some(ui::DIM));
        let local = json!({"version":"1.1.0","update":{"current":"1.1.0","latest":null,"available":false},"script_password":false,
            "source":{"type":"local","repo":null,"sync":null},"counts":{"nodes":0,"groups":3,"clients":0},"password_missing":[],"ssh_setup_pending":false,"subscription_host":"de"});
        let view = dashboard_view(&local, "0.0.0");
        assert!(view.status.is_empty());
        let context: Vec<String> = view.context.iter().map(ToString::to_string).collect();
        assert_eq!(context, ["Источник: локальная", "Ноды: 0  Клиенты: 0  Группы: 3", "Хост подписок: de"]);
        let clean = json!({"source":{"type":"github","repo":"o/r","sync":"clean"}});
        assert_eq!(dashboard_view(&clean, "1").context[0].spans[1].style.fg, Some(ui::GREEN));
        assert_frames(&[view]);
    }
    #[test] fn dashboard_keys_colours_and_both_cases() {
        for key in "ncgmpfsatio".chars() {
            assert_eq!(dashboard_route(&key.to_string()), Some(key));
            assert_eq!(dashboard_route(&key.to_ascii_uppercase().to_string()), Some(key));
        }
        for key in ["", "node", "10", "?", "web"] { assert_eq!(dashboard_route(key), None); }
        let view = dashboard_view(&status_data(), "1");
        assert_eq!(view.sections.len(), 2);
        for item in view.sections.iter().flatten() {
            assert_eq!(item.color, match item.key.as_str() { "n" | "c" | "g" | "m" => ui::GREEN, "p" | "f" | "s" | "o" => ui::YELLOW, "0" => ui::NC, _ => ui::CYAN }, "{}", item.key);
        }
        assert_eq!(keys(&view), ["n", "c", "g", "m", "p", "f", "s", "a", "t", "i", "o", "0"]);
    }
    struct Probe;
    impl Screen for Probe { fn run(&mut self, _: &mut Context<'_>) -> io::Result<Navigation> { Ok(Navigation::Back) } }
    #[test] fn dashboard_routes_registered_screens_and_retries_failed_status() {
        let registry = Registry { screens: vec![Registration { key: 'i', factory: || Box::new(Probe) }], github_wizard: None };
        let status = (words(&["status"]), Reply::success(status_data()));
        let mut client = ScriptedClient::new([(words(&["status"]), error("failed", json!({}))), status.clone(), status.clone(), status.clone()]);
        let mut ui = ScriptedUi::new(&["1", "", "z", "I"]);
        assert!(matches!(Dashboard.run(&mut Context { client: &mut client, ui: &mut ui, registry: &registry }).unwrap(), Navigation::Push(_)));
        client.assert_finished();
        assert_eq!(ui.notices.iter().filter(|n| n.to_string().contains("Неверный выбор.")).count(), 2);
        let mut client = ScriptedClient::new([(words(&["status"]), error("failed", json!({})))]);
        assert!(matches!(Dashboard.run(&mut Context { client: &mut client, ui: &mut ScriptedUi::new(&["0"]), registry: &registry }).unwrap(), Navigation::Back));
        let mut client = ScriptedClient::new([status]);
        assert!(matches!(Dashboard.run(&mut Context { client: &mut client, ui: &mut ScriptedUi::new(&[]), registry: &registry }).unwrap(), Navigation::Back));
    }
    fn version(available: bool) -> (Vec<String>, Reply) {
        (words(&["self", "version"]), Reply::success(json!({"current":"1.1.0","latest":if available {json!("v1.2.0")} else {Value::Null},"update_available":available,"checked":available})))
    }
    fn status(password: bool) -> (Vec<String>, Reply) { (words(&["status"]), Reply::success(json!({"script_password":password}))) }
    fn settings(client: &mut ScriptedClient, ui: &mut ScriptedUi) -> Navigation {
        Settings.run(&mut Context { client, ui, registry: &registry() }).unwrap()
    }
    #[test] fn settings_password_set_and_remove_send_secrets_only() {
        let set = words(&["self", "password-set"]);
        let remove = words(&["self", "password-remove"]);
        let mut confirmed = remove.clone();
        confirmed.extend(words(&["--yes", "--plan-token", "T1"]));
        let mut client = ScriptedClient::new([version(false), status(false), (set.clone(), Reply::success(json!({"password_set":true}))), status(true),
            (set, ok()), status(true), (remove.clone(), plan("T1")), (confirmed, Reply::success(json!({"password_set":false}))), status(false)]);
        let mut ui = ScriptedUi::new(&["l", "new-pw", "new-pw", "L", "cur-pw", "next-pw", "next-pw", "R", "cur-pw", "y", "0"]);
        assert!(matches!(settings(&mut client, &mut ui), Navigation::Back));
        client.assert_finished();
        assert_eq!(client.secret_names[2], ["password"]);
        assert_eq!(client.secret_names[4], ["current-password", "password"]);
        assert_eq!(client.secret_names[6], ["current-password"]);
        assert_eq!(client.secret_names[7], ["current-password"]);
        for secret in ["new-pw", "cur-pw", "next-pw"] { assert!(!format!("{:?}{:?}", ui.views, client.calls).contains(secret)); }
        assert_eq!(keys(&ui.views[0]), ["l", "x", "0"]);
        let with_password = ui.views.iter().find(|v| keys(v) == ["l", "r", "x", "0"]).unwrap();
        assert_eq!(with_password.sections[0][1].color, ui::RED);
        assert!(ui.views[0].context.iter().any(|l| l.to_string() == "Не удалось проверить обновления"));
        assert_frames(&ui.views);
    }
    #[test] fn settings_update_only_when_available_and_uninstall_scope() {
        let mut client = ScriptedClient::new([version(false), status(false), status(false)]);
        let mut ui = ScriptedUi::new(&["u", "0"]);
        assert!(matches!(settings(&mut client, &mut ui), Navigation::Back));
        client.assert_finished();
        assert_eq!(ui.notices.len(), 1);
        let update = words(&["self", "update"]);
        let mut confirmed = update.clone();
        confirmed.extend(words(&["--yes", "--plan-token", "T1"]));
        let mut client = ScriptedClient::new([version(true), status(false), (update.clone(), plan("T1")), status(false), (update, plan("T1")), (confirmed, ok())]);
        let mut ui = ScriptedUi::new(&["U", "n", "u", "y"]);
        assert!(matches!(settings(&mut client, &mut ui), Navigation::Exit(0)));
        client.assert_finished();
        assert_eq!(keys(&ui.views[0])[0], "u");
        assert!(ui.views[0].context.iter().any(|l| l.to_string() == "Последняя: v1.2.0"));
        let uninstall = words(&["self", "uninstall", "--remove-data"]);
        let mut confirmed = uninstall.clone();
        confirmed.extend(words(&["--yes", "--plan-token", "T1"]));
        let mut client = ScriptedClient::new([version(false), status(false), status(false), (uninstall, plan("T1")), (confirmed, Reply::success(json!({"removed":true})))]);
        let mut ui = ScriptedUi::new(&["x", "0", "X", "2", "y"]);
        assert!(matches!(settings(&mut client, &mut ui), Navigation::Exit(0)));
        client.assert_finished();
    }
}
