//! «Источник конфигурации» and the GitHub wizard — v1 `tui/system.sh`
//! (`tui_source`, `tui_github_wizard`, `_tui_wizard_loop`, `_tui_recovery_run`).
//! Decisions are core replies: each `*_required` code becomes one question and
//! the retry gains its flag (`confirm::decision_flag`) or secret. Passwords live
//! only in request secrets, dropped (zeroized) on every exit.
use std::io;
use ratatui::{style::Style, text::{Line, Span}};
use serde_json::Value;
use crate::{
    app::{Context, Navigation, Screen},
    confirm::{decision_flag, run_confirmed, set_flag},
    serve::{argv, Reply, Secrets},
    system::{new_password, sync_state},
    ui::{self, Item, View},
};

/// Warn after a failed operation; a refused plan is a cancellation, not a failure.
pub fn report(context: &mut Context<'_>, reply: &Reply) {
    if !reply.ok && !matches!(reply.code(), "confirmation_required" | "plan_changed") { context.failed(); }
}
fn cancelled(context: &mut Context<'_>) { context.ui.notice(ui::text("Отменено.", ui::CYAN)); }
fn manual_link(context: &mut Context<'_>, value: &Value, label: &str) {
    if let Some(url) = value.as_str().filter(|url| !url.is_empty()) {
        context.ui.notice(ui::text(format!("{label}: {url}"), ui::CYAN));
    }
}
fn ask(context: &mut Context<'_>, title: &str, prompt: &str) -> io::Result<Option<String>> {
    let mut view = View::new(title);
    view.prompt = format!("{prompt}: ");
    context.choose(&view)
}
/// v1 `confirm_yn … Y`: Enter means yes; anything but y/n asks again.
fn confirm_default_yes(context: &mut Context<'_>, title: &str, question: &str) -> io::Result<bool> {
    let mut view = View::new(title);
    view.prompt = format!("{question} (Y/n): ");
    loop {
        match context.choose(&view)?.as_deref() {
            None => return Ok(false),
            Some("" | "y" | "Y") => return Ok(true),
            Some("n" | "N") => return Ok(false),
            Some(_) => context.ui.notice(ui::warn("Введите y или n.")),
        }
    }
}
/// `key_provisioning_required{nodes}` → `--provision-keys yes|no` (default no).
fn provision(context: &mut Context<'_>, reply: &Reply, words: &mut Vec<String>) -> io::Result<()> {
    let nodes: Vec<&str> = reply.error["nodes"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    let mut view = View::new("Переносимый SSH-ключ");
    view.context.push(Line::raw(format!("Ноды: {}", nodes.join(", "))));
    let yes = context.confirm(view, "Создать переносимый SSH-ключ для этих нод?")?;
    set_flag(words, decision_flag("key_provisioning_required").expect("mapped"), Some(if yes { "yes" } else { "no" }));
    Ok(())
}

/// Recovery commands (`github-migrate-format`, `github-replace-with-local`)
/// under their frozen plan: own script password (auth_*), the vault password
/// and the portable-key decision. `None` — the user cancelled a password.
pub fn recovery_run(context: &mut Context<'_>, title: &str, question: &str, verb: &str, secrets: &mut Secrets) -> io::Result<Option<Reply>> {
    let mut words = argv(&["source", verb]);
    let (mut script_tries, mut vault_tries) = (0, 0);
    loop {
        let reply = run_confirmed(context, title, question, &words, secrets)?;
        if reply.ok { return Ok(Some(reply)); }
        match reply.code() {
            "auth_required" | "auth_failed" if script_tries < 3 => {
                script_tries += 1;
                let Some(password) = context.secret(title, "Введите пароль")? else { return Ok(None); };
                secrets.insert_hidden("script-password", password);
            },
            "vault_password_required" | "vault_password_invalid" if vault_tries < 3 => {
                vault_tries += 1;
                let Some(password) = context.secret(title, "Пароль доступа к конфигурации GitHub")? else { return Ok(None); };
                secrets.insert_hidden("vault-password", password);
            },
            "key_provisioning_required" => provision(context, &reply, &mut words)?,
            _ => return Ok(Some(reply)),
        }
    }
}

pub struct Source;
fn source_view(data: &Value) -> View {
    let mut view = View::new("Источник конфигурации");
    let mut maintenance = vec![];
    if data["type"] == "github" {
        let encrypted = data["storage"] == "age";
        view.context.push(Line::raw(format!("GitHub: {}", data["repo"].as_str().unwrap_or(""))));
        view.context.push(Line::raw(format!("Ветка: {}", data["branch"].as_str().unwrap_or(""))));
        view.context.push(Line::raw(if encrypted { "Хранение: зашифровано" } else { "Хранение: без шифрования" }));
        let (label, color) = sync_state(&data["sync"]);
        view.context.push(Line::from(vec![Span::raw("Синхронизация: "), Span::styled(label, Style::default().fg(color))]));
        let mut sync = vec![Item::new('f', "Загрузить из GitHub", ui::YELLOW), Item::new('p', "Отправить в GitHub", ui::YELLOW), Item::new('c', "Сменить аккаунт", ui::YELLOW)];
        if encrypted {
            sync.extend([Item::new('r', "Сменить пароль доступа", ui::YELLOW), Item::new('v', "Новый ключ шифрования", ui::RED), Item::new('k', "Импортировать ключ восстановления", ui::YELLOW)]);
        }
        view.sections.push(sync);
        maintenance.extend([
            Item::new('e', "Работать локально без синхронизации", ui::YELLOW),
            Item::new('l', "Заменить GitHub локальной конфигурацией", ui::RED),
            Item::new('d', "Удалить репозиторий", ui::RED),
        ]);
    } else {
        view.context.push(Line::raw("Источник: локальная"));
        maintenance.push(Item::new('g', "Подключить GitHub", ui::GREEN));
    }
    maintenance.push(Item::new(0, "Назад", ui::NC));
    view.sections.push(maintenance);
    view.prompt = "Выберите действие: ".into();
    view
}
impl Screen for Source {
    fn run(&mut self, context: &mut Context<'_>) -> io::Result<Navigation> {
        loop {
            let status = context.call(&["source", "status"])?;
            if !status.ok { context.failed(); return Ok(Navigation::Back); }
            let github = status.data["type"] == "github";
            let encrypted = github && status.data["storage"] == "age";
            let Some(choice) = context.choose(&source_view(&status.data))? else { return Ok(Navigation::Back); };
            let key = choice.to_ascii_lowercase();
            if !github {
                match key.as_str() {
                    "g" => { context.wizard("connect")?; },
                    "0" => return Ok(Navigation::Back),
                    _ => context.invalid(),
                }
                continue;
            }
            match key.as_str() {
                "f" => { let reply = context.call(&["source", "github-fetch"])?; report(context, &reply); },
                "p" => { let reply = context.call(&["source", "github-push"])?; report(context, &reply); },
                "c" => { context.wizard("change")?; },
                "r" if encrypted => {
                    let mut secrets = Secrets::default();
                    let Some(current) = context.secret("Смена пароля доступа", "Текущий пароль доступа")? else { continue; };
                    secrets.insert_hidden("vault-password", current);
                    let Some(new) = new_password(context, "Смена пароля доступа")? else { continue; };
                    secrets.insert_hidden("new-vault-password", new);
                    let reply = context.request(&argv(&["source", "github-rewrap-password"]), &secrets)?;
                    report(context, &reply);
                },
                "v" if encrypted => {
                    let Some(new) = new_password(context, "Новый ключ шифрования")? else { continue; };
                    let mut secrets = Secrets::default();
                    secrets.insert_hidden("new-vault-password", new);
                    let reply = run_confirmed(context, "Новый ключ шифрования", "Создать новый ключ?", &argv(&["source", "github-rotate-key"]), &secrets)?;
                    report(context, &reply);
                },
                "k" if encrypted => {
                    let Some(path) = ask(context, "Импорт ключа восстановления", "Путь к файлу")? else { continue; };
                    if !path.is_empty() {
                        let reply = context.call(&["source", "github-import-recovery-key", "--file", &path])?;
                        report(context, &reply);
                    }
                },
                "e" => { let reply = context.call(&["source", "github-switch-local"])?; report(context, &reply); },
                "l" => {
                    let mut secrets = Secrets::default();
                    if let Some(reply) = recovery_run(context, "Замена конфигурации GitHub", "Заменить конфигурацию в GitHub?", "github-replace-with-local", &mut secrets)? {
                        report(context, &reply);
                    }
                },
                "d" => {
                    let reply = run_confirmed(context, "Удаление репозитория", "Удалить репозиторий?", &argv(&["source", "github-delete-repo"]), &Secrets::default())?;
                    if !reply.ok { manual_link(context, &reply.error["settings_url"], "Удалите репозиторий вручную"); }
                    report(context, &reply);
                },
                "0" => return Ok(Navigation::Back),
                _ => context.invalid(),
            }
        }
    }
}

/// `connect` (first run, local source) or `change` (GitHub source). `true` —
/// the command succeeded. Refusal or EOF at any step → «Отменено.», no call.
pub fn github_wizard(context: &mut Context<'_>, mode: &str) -> io::Result<bool> {
    let change = mode == "change";
    let (verb, title) = if change { ("github-change-account", "Смена аккаунта GitHub") } else { ("github-connect", "Подключение GitHub") };
    let reply = context.call(&["source", "github-accounts"])?;
    if !reply.ok { context.failed(); return Ok(false); }
    let mut accounts: Vec<String> = reply.data["accounts"].as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect();
    if let Some(global) = reply.data["global_login"].as_str().filter(|login| !login.is_empty()) {
        if !accounts.iter().any(|account| account == global) { accounts.push(global.into()); }
    }
    let mut labels = accounts.clone();
    labels.push("Указать другой логин".into());
    let Some(index) = context.select("Аккаунт GitHub", &labels)? else { cancelled(context); return Ok(false); };
    let login = if index == accounts.len() {
        match ask(context, "Аккаунт GitHub", "Логин GitHub")? {
            Some(login) if !login.is_empty() => login,
            _ => { cancelled(context); return Ok(false); },
        }
    } else { accounts.swap_remove(index) };
    let mut words = argv(&["source", verb, "--login", &login]);
    let mut secrets = Secrets::default();
    let mut vault_tries = 0;
    loop {
        let reply = run_confirmed(context, title, "Выполнить?", &words, &secrets)?;
        if reply.ok {
            if change { manual_link(context, &reply.data["old_repo_settings_url"], "Прежний репозиторий можно удалить вручную"); }
            return Ok(true);
        }
        let code = reply.code();
        let decided = match code {
            "github_auth_required" => {
                if !confirm_default_yes(context, "Вход в GitHub", "Войти в GitHub через браузер сейчас?")? { false }
                else {
                    let auth = context.call(&["source", "github-login", "--login", &login])?;
                    if !auth.ok { context.failed(); return Ok(false); }
                    true
                }
            },
            "repo_create_required" => {
                let question = format!("Создать приватный репозиторий {}?", reply.error["repo"].as_str().unwrap_or(""));
                let yes = context.confirm(View::new("Создание репозитория"), &question)?;
                if yes { set_flag(&mut words, decision_flag(code).expect("mapped"), None); }
                yes
            },
            // Privacy is confirmed once, by the core plan.
            "repo_private_required" => { set_flag(&mut words, decision_flag(code).expect("mapped"), None); true },
            // Foreign files (e.g. the repository of the Bash 1.x client): say why
            // first; the deletion itself is confirmed again in the core plan.
            "target_replace_required" => {
                let mut view = View::new("Репозиторий GitHub");
                view.context.push(Line::raw(format!("Репозиторий {} не содержит конфигурации Remote Control 2.", reply.error["repo"].as_str().unwrap_or(""))));
                if let Some(reason) = reply.error["reason"].as_str().filter(|reason| !reason.is_empty()) {
                    view.context.push(Line::raw(format!("Причина: {reason}")));
                }
                view.context.push(Line::raw(format!("Файлов в репозитории: {}; после замены они останутся только в истории Git.", reply.error["tracked_files"])));
                let yes = context.confirm(view, "Заменить их конфигурацией этого устройства?")?;
                if yes { set_flag(&mut words, decision_flag(code).expect("mapped"), None); }
                yes
            },
            "storage_mode_required" => {
                let choices: Vec<String> = reply.error["choices"].as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect();
                let labels: Vec<String> = choices.iter().map(|choice| match choice.as_str() {
                    "age" => "Зашифровать паролем (age)".into(),
                    "none" => "Без шифрования".into(),
                    other => other.into(),
                }).collect();
                match context.select("Хранение конфигурации GitHub", &labels)? {
                    Some(index) => { set_flag(&mut words, decision_flag(code).expect("mapped"), Some(choices[index].as_str())); true },
                    None => false,
                }
            },
            "new_vault_password_required" => match new_password(context, title)? {
                Some(password) => { secrets.insert_hidden("new-vault-password", password); true },
                None => false,
            },
            "existing_config_action_required" => {
                let choices: Vec<String> = reply.error["choices"].as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect();
                let labels: Vec<String> = choices.iter().map(|choice| match choice.as_str() {
                    "remote" => {
                        let counts = &reply.error["remote_counts"];
                        let counts = if counts.is_object() { format!("ноды {}, клиенты {}", counts["nodes"], counts["clients"]) } else { "состав неизвестен".into() };
                        format!("Использовать конфигурацию из GitHub ({counts})")
                    },
                    "local" => "Заменить её конфигурацией с этого устройства".into(),
                    "migrate" => "Преобразовать конфигурацию из GitHub".into(),
                    other => other.into(),
                }).collect();
                match context.select("Конфигурация в GitHub", &labels)? {
                    Some(index) => { set_flag(&mut words, decision_flag(code).expect("mapped"), Some(choices[index].as_str())); true },
                    None => false,
                }
            },
            "vault_password_required" | "vault_password_invalid" if vault_tries < 3 => {
                vault_tries += 1;
                match context.secret(title, "Пароль доступа к конфигурации GitHub")? {
                    Some(password) => {
                        secrets.insert_hidden("vault-password", password);
                        if !change && context.confirm(View::new("Ключ расшифровки"), "Сохранить ключ расшифровки на этом устройстве?")? {
                            set_flag(&mut words, "--remember-key", None);
                        }
                        true
                    },
                    None => false,
                }
            },
            "key_provisioning_required" => { provision(context, &reply, &mut words)?; true },
            "cache_skip_required" => {
                let yes = context.confirm(View::new("Локальный кэш"), "Продолжить смену аккаунта без локального кэша?")?;
                if yes { set_flag(&mut words, decision_flag(code).expect("mapped"), None); }
                yes
            },
            _ => { report(context, &reply); return Ok(false); },
        };
        if !decided { cancelled(context); return Ok(false); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{app::{Registry, ScriptedUi}, serve::{Log, ScriptedClient}, system::tests::{assert_frames, error, ok, plan, words}};
    use serde_json::json;
    fn registry() -> Registry { Registry { screens: vec![], github_wizard: Some(github_wizard) } }
    fn keys(view: &View) -> Vec<String> { view.sections.iter().flatten().map(|i| i.key.clone()).collect() }
    fn yes(base: &[String], token: &str) -> Vec<String> { let mut w = base.to_vec(); w.extend(words(&["--yes", "--plan-token", token])); w }
    fn status(storage: &str) -> (Vec<String>, Reply) {
        (words(&["source", "status"]), Reply::success(json!({"type":"github","repo":"o/r","branch":"main","storage":storage,"sync":"clean","key_saved":false})))
    }
    fn local() -> (Vec<String>, Reply) {
        (words(&["source", "status"]), Reply::success(json!({"type":"local","repo":null,"branch":null,"storage":null,"sync":null,"key_saved":null})))
    }
    fn accounts() -> (Vec<String>, Reply) { (words(&["source", "github-accounts"]), Reply::success(json!({"accounts":["test-owner"],"global_login":"glob"}))) }
    fn source(client: &mut ScriptedClient, ui: &mut ScriptedUi) -> Navigation { Source.run(&mut Context { client, ui, registry: &registry() }).unwrap() }
    fn wizard(client: &mut ScriptedClient, ui: &mut ScriptedUi, mode: &str) -> bool { github_wizard(&mut Context { client, ui, registry: &registry() }, mode).unwrap() }
    fn notices(ui: &ScriptedUi) -> Vec<String> { ui.notices.iter().map(ToString::to_string).collect() }

    #[test] fn source_menu_items_follow_storage_and_colours() {
        let age = source_view(&status("age").1.data);
        assert_eq!(keys(&age), ["f", "p", "c", "r", "v", "k", "e", "l", "d", "0"]);
        for item in age.sections.iter().flatten() {
            assert_eq!(item.color, match item.key.as_str() { "v" | "l" | "d" => ui::RED, "0" => ui::NC, _ => ui::YELLOW }, "{}", item.key);
        }
        assert_eq!(age.context[3].spans[1].style.fg, Some(ui::GREEN));
        let plain = source_view(&status("none").1.data);
        assert_eq!(keys(&plain), ["f", "p", "c", "e", "l", "d", "0"]);
        let local_view = source_view(&local().1.data);
        assert_eq!(keys(&local_view), ["g", "0"]);
        assert_eq!(local_view.sections[0][0].color, ui::GREEN);
        assert_frames(&[age, plain, local_view]);
    }
    #[test] fn sync_switch_and_recovery_key_send_real_commands_in_both_cases() {
        let mut client = ScriptedClient::new([status("age"), (words(&["source", "github-fetch"]), Reply::success(json!({"sync":"clean"}))),
            status("age"), (words(&["source", "github-push"]), error("source_failed", json!({"message":"push rejected"}))),
            status("age"), (words(&["source", "github-switch-local"]), Reply::success(json!({"source":"local"}))),
            status("age"), (words(&["source", "github-import-recovery-key", "--file", "/tmp/key.txt"]), ok()),
            status("age"), status("age")]);
        let mut ui = ScriptedUi::new(&["f", "P", "E", "k", "/tmp/key.txt", "", "0"]);
        assert!(matches!(source(&mut client, &mut ui), Navigation::Back));
        client.assert_finished();
        let texts = notices(&ui);
        assert!(texts.iter().any(|n| n.contains("Операция завершилась ошибкой")));
        assert_eq!(texts.iter().filter(|n| n.contains("push rejected")).count(), 1, "core message shown once (centrally)");
        assert!(texts.iter().any(|n| n.contains("Неверный выбор.")));
        // Plain storage: the key actions are invalid and call nothing.
        let mut client = ScriptedClient::new([status("none"), status("none"), status("none"), status("none")]);
        let mut ui = ScriptedUi::new(&["r", "V", "k", "0"]);
        source(&mut client, &mut ui);
        client.assert_finished();
        assert_eq!(notices(&ui).iter().filter(|n| n.contains("Неверный выбор.")).count(), 3);
        // Failed read returns to the dashboard; EOF leaves too.
        let mut client = ScriptedClient::new([(words(&["source", "status"]), error("source_failed", json!({})))]);
        assert!(matches!(source(&mut client, &mut ScriptedUi::new(&[])), Navigation::Back));
        client.assert_finished();
    }
    #[test] fn cancelled_recovery_key_path_keeps_the_source_screen() {
        let mut client = ScriptedClient::new([status("age"), status("age")]);
        let mut ui = ScriptedUi::new(&[]);
        ui.inputs.extend([Some("k".into()), None, Some("0".into())]);
        assert!(matches!(source(&mut client, &mut ui), Navigation::Back));
        client.assert_finished();
        assert!(ui.inputs.is_empty());
    }
    #[test] fn rewrap_and_rotate_send_passwords_only_as_secrets() {
        let rewrap = words(&["source", "github-rewrap-password"]);
        let rotate = words(&["source", "github-rotate-key"]);
        let mut client = ScriptedClient::new([status("age"), (rewrap, Reply::success(json!({"sync":"clean"}))), status("age"), status("age"),
            (rotate.clone(), plan("T1")), status("age"), (rotate.clone(), plan("T1")), (yes(&rotate, "T1"), ok()), status("age")]);
        let mut ui = ScriptedUi::new(&["r", "old-pass", "new-pass", "new-pass", "R", "old-pass", "new-pass", "other",
            "v", "n1", "n1", "n", "V", "n1", "n1", "y", "0"]);
        source(&mut client, &mut ui);
        client.assert_finished();
        assert_eq!(client.secret_names[1], ["new-vault-password", "vault-password"]);
        assert_eq!(client.secret_names[4], ["new-vault-password"]);
        assert_eq!(client.secret_names[7], ["new-vault-password"]);
        assert!(notices(&ui).iter().any(|n| n.contains("Пароли не совпадают.")));
        assert!(!notices(&ui).iter().any(|n| n.contains("Операция завершилась ошибкой")), "refusal is not a failure");
        for secret in ["old-pass", "new-pass", "n1"] { assert!(!format!("{:?}{:?}", ui.views, client.calls).contains(secret)); }
    }
    #[test] fn replace_asks_provisioning_and_delete_shows_settings_link() {
        let replace = words(&["source", "github-replace-with-local"]);
        let provisioned = words(&["source", "github-replace-with-local", "--provision-keys", "yes"]);
        let delete = words(&["source", "github-delete-repo"]);
        let mut client = ScriptedClient::new([status("age"), (replace, error("key_provisioning_required", json!({"nodes":["de","nl"]}))),
            (provisioned.clone(), plan("T1")), (yes(&provisioned, "T1"), Reply::success(json!({"published":true,"refreshed":true}))),
            status("age"), (delete.clone(), plan("T2")), status("age"), (delete.clone(), plan("T2")),
            (yes(&delete, "T2"), error("remote_failed", json!({"settings_url":"https://github.com/o/r/settings"}))), status("age")]);
        let mut ui = ScriptedUi::new(&["l", "y", "y", "d", "n", "D", "y", "0"]);
        source(&mut client, &mut ui);
        client.assert_finished();
        assert!(ui.views.iter().any(|v| v.context.iter().any(|l| l.to_string() == "Ноды: de, nl")));
        assert!(notices(&ui).iter().any(|n| n == "Удалите репозиторий вручную: https://github.com/o/r/settings"));
    }
    #[test] fn local_source_offers_only_the_connect_wizard() {
        fn probe(_: &mut Context<'_>, mode: &str) -> io::Result<bool> { assert_eq!(mode, "connect"); Ok(false) }
        let registry = Registry { screens: vec![], github_wizard: Some(probe) };
        let mut client = ScriptedClient::new([local(), local(), local()]);
        let mut ui = ScriptedUi::new(&["G", "f", "0"]);
        Source.run(&mut Context { client: &mut client, ui: &mut ui, registry: &registry }).unwrap();
        client.assert_finished();
        assert_eq!(notices(&ui).iter().filter(|n| n.contains("Неверный выбор.")).count(), 1);
    }
    #[test] fn connect_wizard_maps_every_decision_code_to_its_flag_or_secret() {
        let base = words(&["source", "github-connect", "--login", "test-owner"]);
        let create = words(&["source", "github-connect", "--login", "test-owner", "--create-repo"]);
        let storage = words(&["source", "github-connect", "--login", "test-owner", "--create-repo", "--storage", "age"]);
        let keys_no = words(&["source", "github-connect", "--login", "test-owner", "--create-repo", "--storage", "age", "--provision-keys", "no"]);
        let mut login = Reply::success(json!({"login":"test-owner"}));
        login.logs.push(Log { level: "info".into(), text: "Код устройства: ABCD-1234".into() });
        let mut client = ScriptedClient::new([accounts(),
            (base.clone(), error("github_auth_required", json!({"login":"test-owner","hint":"h"}))),
            (words(&["source", "github-login", "--login", "test-owner"]), login),
            (base, error("repo_create_required", json!({"repo":"test-owner/essence-config"}))),
            (create.clone(), error("storage_mode_required", json!({"choices":["age","none"]}))),
            (storage.clone(), error("new_vault_password_required", json!({"secret":"new-vault-password"}))),
            (storage, error("key_provisioning_required", json!({"nodes":["de"]}))),
            (keys_no.clone(), plan("T1")), (yes(&keys_no, "T1"), Reply::success(json!({"repo":"test-owner/essence-config","storage":"age","sync":"clean"})))]);
        let mut ui = ScriptedUi::new(&["1", "", "y", "1", "vp", "vp", "n", "y"]);
        assert!(wizard(&mut client, &mut ui, "connect"));
        client.assert_finished();
        assert_eq!(ui.logs.len(), 1, "device code shown live");
        assert_eq!(keys(&ui.views[0]), ["1", "2", "3", "0"]);
        assert_eq!(ui.views[0].sections[0][1].label, "glob");
        assert_eq!(client.secret_names[6], ["new-vault-password"]);
        assert_eq!(client.secret_names[8], ["new-vault-password"]);
        assert!(!format!("{:?}{:?}", ui.views, client.calls).contains("vp\""));
        assert_frames(&ui.views);
    }
    #[test] fn connect_wizard_vault_password_existing_choice_and_other_login() {
        let base = words(&["source", "github-connect", "--login", "other-owner"]);
        let remember = words(&["source", "github-connect", "--login", "other-owner", "--remember-key"]);
        let existing = words(&["source", "github-connect", "--login", "other-owner", "--remember-key", "--existing", "local"]);
        let mut client = ScriptedClient::new([accounts(), (base, error("vault_password_required", json!({}))),
            (remember, error("existing_config_action_required", json!({"choices":["remote","local"],"remote_counts":{"nodes":2,"clients":1,"groups":3},"local_counts":{"nodes":0,"clients":0,"groups":0}}))),
            (existing.clone(), plan("T1")), (yes(&existing, "T1"), ok())]);
        let mut ui = ScriptedUi::new(&["3", "other-owner", "vp", "y", "2", "y"]);
        assert!(wizard(&mut client, &mut ui, "connect"));
        client.assert_finished();
        let chooser = ui.views.iter().find(|v| v.title == "Конфигурация в GitHub").unwrap();
        assert_eq!(chooser.sections[0][0].label, "Использовать конфигурацию из GitHub (ноды 2, клиенты 1)");
        assert_eq!(client.secret_names[4], ["vault-password"]);
    }
    #[test] fn storage_choices_come_from_the_reply() {
        let base = words(&["source", "github-connect", "--login", "test-owner"]);
        let none = words(&["source", "github-connect", "--login", "test-owner", "--storage", "none"]);
        let mut client = ScriptedClient::new([accounts(), (base, error("storage_mode_required", json!({"choices":["none"]}))), (none, ok())]);
        let mut ui = ScriptedUi::new(&["1", "1"]);
        assert!(wizard(&mut client, &mut ui, "connect"));
        client.assert_finished();
        assert_eq!(ui.views[1].sections[0][0].label, "Без шифрования");
    }
    #[test] fn change_wizard_cache_target_privacy_and_old_repository_link() {
        let base = words(&["source", "github-change-account", "--login", "glob"]);
        let cache = words(&["source", "github-change-account", "--login", "glob", "--without-cache"]);
        let target = words(&["source", "github-change-account", "--login", "glob", "--without-cache", "--replace-target"]);
        let private = words(&["source", "github-change-account", "--login", "glob", "--without-cache", "--replace-target", "--make-private"]);
        let mut client = ScriptedClient::new([accounts(), (base, error("cache_skip_required", json!({}))),
            (cache, error("target_replace_required", json!({"repo":"glob/essence-config","tracked_files":3}))),
            (target, error("repo_private_required", json!({"repo":"glob/essence-config"}))), (private.clone(), plan("T1")),
            (yes(&private, "T1"), Reply::success(json!({"repo":"glob/essence-config","sync":"clean","old_repo_settings_url":"https://github.com/test-owner/essence-config/settings"})))]);
        let mut ui = ScriptedUi::new(&["2", "y", "y", "y"]);
        assert!(wizard(&mut client, &mut ui, "change"));
        client.assert_finished();
        assert!(notices(&ui).iter().any(|n| n == "Прежний репозиторий можно удалить вручную: https://github.com/test-owner/essence-config/settings"));
        // The change wizard never offers to remember the key.
        let base = words(&["source", "github-change-account", "--login", "glob"]);
        let mut client = ScriptedClient::new([accounts(), (base.clone(), error("vault_password_required", json!({}))), (base, ok())]);
        let mut ui = ScriptedUi::new(&["2", "vp"]);
        assert!(wizard(&mut client, &mut ui, "change"));
        client.assert_finished();
    }
    /// The v1 repository case: the reason reaches the question, consent adds
    /// `--replace-target` (then the storage choice and the plan), refusal
    /// sends nothing more. Every request had its busy status first.
    #[test] fn connect_wizard_asks_before_replacing_a_foreign_repository() {
        let base = words(&["source", "github-connect", "--login", "test-owner"]);
        let replace = words(&["source", "github-connect", "--login", "test-owner", "--replace-target"]);
        let none = words(&["source", "github-connect", "--login", "test-owner", "--replace-target", "--storage", "none"]);
        let foreign = || error("target_replace_required", json!({"repo":"test-owner/essence-config","tracked_files":6,
            "reason":"В хранилище конфигурации GitHub обнаружен недопустимый путь: ssh/known_hosts"}));
        let mut client = ScriptedClient::new([accounts(), (base.clone(), foreign()),
            (replace, error("storage_mode_required", json!({"choices":["age","none"]}))), (none.clone(), plan("T1")), (yes(&none, "T1"), ok())]);
        let mut ui = ScriptedUi::new(&["1", "y", "2", "y"]);
        assert!(wizard(&mut client, &mut ui, "connect"));
        client.assert_finished();
        let question = ui.views.iter().find(|v| v.title == "Репозиторий GitHub").unwrap();
        let text = question.lines().iter().map(ToString::to_string).collect::<Vec<_>>().join(" ");
        assert!(text.contains("ssh/known_hosts") && text.contains("Файлов в репозитории: 6"), "{text}");
        assert_eq!(ui.busy, ["Проверка аккаунтов GitHub…", "Подключение к GitHub…", "Подключение к GitHub…", "Подключение к GitHub…", "Подключение к GitHub…"]);
        assert!(notices(&ui).is_empty(), "a decision is never reported as a failure: {:?}", notices(&ui));
        assert_frames(&ui.views);
        let mut client = ScriptedClient::new([accounts(), (base, foreign())]);
        let mut ui = ScriptedUi::new(&["1", "n"]);
        assert!(!wizard(&mut client, &mut ui, "connect"));
        client.assert_finished();
        assert_eq!(notices(&ui), ["Отменено."]);
    }
    #[test] fn refusal_or_eof_cancels_without_further_calls() {
        let base = words(&["source", "github-connect", "--login", "test-owner"]);
        for inputs in [&["1", "n"][..], &["1", ""][..], &["1"][..]] {
            let mut client = ScriptedClient::new([accounts(), (base.clone(), error("repo_create_required", json!({"repo":"test-owner/essence-config"})))]);
            let mut ui = ScriptedUi::new(inputs);
            assert!(!wizard(&mut client, &mut ui, "connect"));
            client.assert_finished();
            assert!(notices(&ui).iter().any(|n| n == "Отменено."));
        }
        for inputs in [&[][..], &["0"][..], &["3", ""][..]] {
            let mut client = ScriptedClient::new([accounts()]);
            let mut ui = ScriptedUi::new(inputs);
            assert!(!wizard(&mut client, &mut ui, "connect"));
            client.assert_finished();
        }
        // Declining the browser login and refusing the plan send nothing more.
        let mut client = ScriptedClient::new([accounts(), (base.clone(), error("github_auth_required", json!({"login":"test-owner"})))]);
        let mut ui = ScriptedUi::new(&["1", "x", "n"]);
        assert!(!wizard(&mut client, &mut ui, "connect"));
        client.assert_finished();
        assert!(notices(&ui).iter().any(|n| n.contains("Введите y или n.")));
        let mut client = ScriptedClient::new([accounts(), (base, plan("T1"))]);
        let mut ui = ScriptedUi::new(&["1", "n"]);
        assert!(!wizard(&mut client, &mut ui, "connect"));
        client.assert_finished();
        assert!(!notices(&ui).iter().any(|n| n.contains("Операция завершилась ошибкой")));
    }
}
