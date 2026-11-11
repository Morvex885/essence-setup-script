//! `subscription host|list|show|headers|publish|publish-all|rotate|revoke|migrate`.

use serde_json::{json, Value};

use super::remote::{self, Item, Removal, UploadFailure};
use super::{annotated_headers, check_headers, client_token, defaults, find_client, host_node, iso, link,
    new_token, no_subscription, not_configured, not_generated, now, parse_iso, render_snippet, rendered, ttl_expiry,
    validate_header};
use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::model::{Client, Config, SubscriptionHeader, SubscriptionHost};
use crate::nodes::{self, required};
use crate::transport::RemoteTransport;

/// A stored token of any shape (v1 `(.subscription.token // "") != ""`).
fn has_token(client: &Client) -> bool {
    client.subscription.as_ref().and_then(|s| s.token.as_deref()).is_some_and(|t| !t.is_empty())
}

fn host_json(config: &Config) -> Value {
    serde_json::to_value(&config.subscription_host).unwrap_or(Value::Null)
}

fn with_data(mut error: RcError, data: &Value) -> RcError {
    if let Some(fields) = data.as_object() {
        for (key, value) in fields {
            error = error.with_extra(key.clone(), value.clone());
        }
    }
    error
}

fn upload_warning(failure: UploadFailure, client: &str) -> String {
    match failure {
        UploadFailure::Yaml => format!("Не удалось загрузить YAML-конфигурацию для {client}."),
        UploadFailure::Snippet => format!("Не удалось загрузить фрагмент конфигурации для {client}."),
        UploadFailure::Apply => format!("Не удалось применить конфигурацию для {client} (проверка nginx, права или перезагрузка)."),
    }
}

fn batch_warning(failure: UploadFailure) -> &'static str {
    match failure {
        UploadFailure::Yaml => "Не удалось загрузить пакет YAML-конфигураций.",
        UploadFailure::Snippet => "Не удалось загрузить пакет фрагментов конфигурации.",
        UploadFailure::Apply => "Не удалось применить пакет конфигураций (проверка nginx, права или перезагрузка).",
    }
}

/// v1 `_sub_verify_http`: after saving, the link must answer 200; otherwise
/// `partial` carrying the command data (the subscription is already saved).
async fn verify(data: Value) -> Result<Value> {
    let Some(url) = data["url"].as_str() else { return Ok(data) };
    let code = match remote::http_status(url).await {
        remote::HttpCheck::Status(200) => return Ok(data),
        remote::HttpCheck::Untrusted => return Err(with_data(RcError::new("partial",
            "Подписка сохранена, но сертификат сервера подписок не подтверждён. Проверьте сертификат домена подписки."), &data)),
        remote::HttpCheck::Status(code) => code.to_string(),
        remote::HttpCheck::NoResponse => "нет ответа".to_owned(),
    };
    Err(with_data(RcError::new("partial", format!(
        "Подписка сохранена, но проверка HTTP: {code} (ожидалось 200). Проверьте журнал ошибок nginx на сервере.")), &data))
}

// ─── host / list / show ──────────────────────────────────────────────────────

/// Without `--name`: the configured host. With it: read the node's hosting
/// settings and make it the host (only while no subscription is published
/// elsewhere — moving published links is `migrate`).
pub(super) async fn host<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T)
    -> Result<Value>
{
    let config = session.state.load_config()?;
    if !invocation.has("name") {
        return Ok(host_json(&config));
    }
    let node = required(invocation, "name")?;
    nodes::find(&config, node)?;
    let conflict = |config: &Config| {
        let current = config.subscription_host.as_ref().map_or("", |host| host.node.as_str());
        if !current.is_empty() && current != node && config.clients.iter().any(has_token) {
            return Err(RcError::new("conflict", format!(
                "Есть опубликованные подписки. Для смены хост-ноды используйте subscription migrate --name {node}."))
                .with_extra("name", node));
        }
        Ok(())
    };
    conflict(&config)?;
    let conf = {
        let transport = remote::connect_node(session, &config, node, connect).await?;
        remote::read_conf(&transport, node, "Хост-нода подписок недоступна.").await?
    };
    let (Some(sub_dir), Some(nginx_group), true) = (conf.sub_dir(), conf.nginx_group(), conf.complete()) else {
        return Err(RcError::new("invalid", "Конфигурация хостинга подписок неполна.").with_extra("name", node));
    };
    let host = SubscriptionHost { node: node.into(), base_url: conf.base_url.clone(), sub_dir: sub_dir.into(), nginx_group };
    session.mutate("subscription_set_host", |state| {
        let mut config = state.load_config()?;
        nodes::find(&config, node)?;
        conflict(&config)?;
        config.subscription_host = Some(host);
        state.save_config(&config)
    })?;
    session.log(Level::Success, &format!("Хост-нода подписок: {node} ({})", conf.base_url));
    Ok(host_json(&session.state.load_config()?))
}

/// Published subscriptions with their state; links stay out of the listing.
pub(super) fn list(session: &mut Session) -> Result<Value> {
    let config = session.state.load_config()?;
    let now = now();
    Ok(Value::Array(config.clients.iter().filter(|client| has_token(client)).map(|client| {
        let expires = client.subscription.as_ref().and_then(|s| s.expires_at.as_deref()).filter(|e| !e.is_empty());
        let state = match expires.map(parse_iso) {
            None => "unlimited",
            Some(None) => "unknown",
            Some(Some(epoch)) if epoch <= now => "expired",
            Some(Some(_)) => "active",
        };
        json!({"client": client.name, "expires_at": expires, "state": state})
    }).collect()))
}

/// The link of one client (explicit request), its expiry and effective headers.
pub(super) fn show(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?;
    let config = session.state.load_config()?;
    let client = find_client(&config, name)?;
    let token = client_token(client)?.ok_or_else(|| no_subscription(name))?;
    let url = link(&config, &token);
    if url.is_null() {
        return Err(not_configured());
    }
    let expires = client.subscription.as_ref().and_then(|s| s.expires_at.as_deref()).filter(|e| !e.is_empty());
    Ok(json!({"client": name, "url": url, "expires_at": expires, "headers": super::effective_headers(&config, client)}))
}

// ─── headers ─────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind { Client, Group, Default }

fn headers_json(config: &Config, kind: Kind, target: &str) -> Value {
    match kind {
        Kind::Client => match config.clients.iter().find(|client| client.name == target) {
            Some(client) => Value::Array(annotated_headers(config, client).into_iter().map(|(header, source)| {
                json!({"name": header.name, "value": header.value, "source": source})
            }).collect()),
            None => json!([]),
        },
        Kind::Group => json!(config.groups.iter().find(|group| group.name == target)
            .and_then(|group| group.subscription_headers.clone()).unwrap_or_default()),
        Kind::Default => json!(defaults(config)),
    }
}

/// Apply `--set` pairs, then `--unset` names (a name is replaced in place of
/// its old position at the end of the list, like v1).
fn apply_ops(headers: &mut Vec<SubscriptionHeader>, sets: &[(String, String)], unsets: &[String]) {
    for (name, value) in sets {
        headers.retain(|header| header.name != *name);
        headers.push(SubscriptionHeader { name: name.clone(), value: value.clone() });
    }
    for name in unsets {
        headers.retain(|header| header.name != *name);
    }
}

/// Show (or with `--set`/`--unset` change) the headers of a client or group;
/// defaults are shown only. Every pair is checked before one write.
pub(super) fn headers(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let chosen: Vec<&str> = ["client", "group", "default"].into_iter().filter(|flag| invocation.has(flag)).collect();
    if chosen.len() != 1 {
        return Err(RcError::new("usage", "Укажите ровно один из флагов: --client | --group | --default."));
    }
    let config = session.state.load_config()?;
    let (kind, target) = match chosen[0] {
        "client" => {
            let target = invocation.value("client").unwrap_or("");
            find_client(&config, target)?;
            (Kind::Client, target)
        }
        "group" => {
            let target = invocation.value("group").unwrap_or("");
            group_exists(&config, target)?;
            (Kind::Group, target)
        }
        _ => (Kind::Default, ""),
    };
    if !invocation.has("set") && !invocation.has("unset") {
        return Ok(headers_json(&config, kind, target));
    }
    if kind == Kind::Default {
        return Err(RcError::new("usage", "Заголовки по умолчанию не изменяются; укажите --client или --group."));
    }
    let mut sets = Vec::new();
    for line in invocation.values("set") {
        let Some((name, value)) = line.split_once('=').filter(|(name, _)| !name.is_empty()) else {
            return Err(RcError::new("usage", format!("Флаг --set ожидает NAME=VALUE, получено: {line}.")));
        };
        if value.is_empty() {
            return Err(RcError::new("usage", "Имя и значение заголовка обязательны."));
        }
        validate_header(name, value)?;
        sets.push((name.to_owned(), value.to_owned()));
    }
    let unsets = invocation.values("unset");
    if unsets.iter().any(String::is_empty) {
        return Err(RcError::new("usage", "Флаг --unset ожидает имя заголовка."));
    }
    session.mutate("subscription_headers", |state| {
        let mut config = state.load_config()?;
        let list = match kind {
            Kind::Client => {
                find_client(&config, target)?;
                let client = config.clients.iter_mut().find(|client| client.name == target).expect("client exists");
                client.subscription.get_or_insert_with(Default::default).headers.get_or_insert_with(Vec::new)
            }
            _ => {
                group_exists(&config, target)?;
                let group = config.groups.iter_mut().find(|group| group.name == target).expect("group exists");
                group.subscription_headers.get_or_insert_with(Vec::new)
            }
        };
        apply_ops(list, &sets, unsets);
        state.save_config(&config)
    })?;
    if kind == Kind::Client {
        session.log(Level::Success, &format!("Заголовки подписки обновлены (клиент: {target})"));
        session.log(Level::Info, &format!("Запустите публикацию для {target} чтобы применить."));
    } else {
        session.log(Level::Success, &format!("Заголовки подписки обновлены (группа: {target})"));
        session.log(Level::Info, "Запустите 'Обновить все подписки' чтобы применить.");
    }
    let config = session.state.load_config()?;
    let kind_name = if kind == Kind::Client { "client" } else { "group" };
    Ok(json!({"target": {"kind": kind_name, "name": target}, "headers": headers_json(&config, kind, target)}))
}

fn group_exists(config: &Config, name: &str) -> Result<()> {
    if config.groups.iter().any(|group| group.name == name) {
        Ok(())
    } else {
        Err(RcError::new("not_found", format!("Группа «{name}» не найдена.")).with_extra("name", name))
    }
}

// ─── publish ─────────────────────────────────────────────────────────────────

pub(super) async fn publish<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T)
    -> Result<Value>
{
    let name = required(invocation, "name")?;
    publish_client(session, name, invocation.value("ttl").filter(|ttl| !ttl.is_empty()), connect).await
}

/// v1 `subscription_publish`: every local check (TTL, generated config,
/// host, token, headers) precedes the upload; the token is saved only after
/// the host serves the files. Without a TTL an existing expiry is kept.
pub(super) async fn publish_client<T: RemoteTransport>(session: &mut Session, name: &str, ttl: Option<&str>,
    connect: &dyn Fn() -> T) -> Result<Value>
{
    let config = session.state.load_config()?;
    let client = find_client(&config, name)?;
    let expiry = match ttl {
        Some(ttl) => Some(ttl_expiry(ttl, now()).ok_or_else(|| {
            RcError::new("invalid", format!("Неверный формат TTL: {ttl} (пример: 12h, 30d, 2w)."))
        })?),
        None => None,
    };
    let yaml = rendered(session, client)?
        .ok_or_else(|| not_generated(name, &format!("Конфиг для «{name}» не найден или пуст.")))?;
    host_node(&config)?;
    let existing = client_token(client)?;
    let token = existing.clone().unwrap_or_else(new_token);
    let headers = check_headers(&config, client)?;

    let host = remote::open_host(session, &config, connect).await?;
    let item = Item { token: &token, yaml: &yaml, snippet: render_snippet(&token, &host.sub_dir, &headers) };
    if let Err(failure) = remote::upload(&host.transport, &host.sub_dir, &host.nginx_group, &[item]).await {
        session.log(Level::Warn, &upload_warning(failure, name));
        return Err(RcError::new("remote_failed", "Ошибка загрузки файла на сервер."));
    }
    // The host's expiry list gets the same instant as expires_at.
    if let Some(expiry) = expiry {
        if !remote::write_expiry(&host.transport, &host.sub_dir, &[(token.clone(), Some(expiry))]).await {
            if existing.is_some() {
                return Err(RcError::new("remote_failed",
                    "Конфиг подписки обновлён на хост-ноде, но новый срок записать не удалось; действует прежний срок."));
            }
            let (removal, warning) = remote::remove_token(&host.transport, &host.sub_dir, &token, None).await;
            if let Some(warning) = warning { session.log(Level::Warn, &warning); }
            let cleanup = if removal == Removal::Removed { "загруженная подписка удалена" }
                else { "удалить загруженную подписку не удалось — проверьте каталог подписок на хост-ноде" };
            return Err(RcError::new("remote_failed", format!(
                "Срок подписки не записан на хост-ноде; {cleanup}. Локальные данные не изменены.")));
        }
    }
    drop(host);

    let stamp = iso(now());
    let expires_at = expiry.map(iso);
    let saved = session.mutate("subscription_publish", |state| {
        let mut config = state.load_config()?;
        let client = config.clients.iter_mut().find(|client| client.name == name)
            .ok_or_else(|| RcError::new("not_found", format!("Клиент «{name}» не найден.")))?;
        let subscription = client.subscription.get_or_insert_with(Default::default);
        if subscription.token.as_deref() != Some(token.as_str()) {
            subscription.created_at = Some(stamp);
        }
        subscription.token = Some(token.clone());
        if expires_at.is_some() || existing.is_none() {
            subscription.expires_at = expires_at;
        }
        let saved = subscription.expires_at.clone();
        state.save_config(&config)?;
        Ok(saved)
    }).map_err(|error| RcError::new("failed",
        "Файл загружен на сервер, но данные подписки сохранить не удалось. Публикация не завершена.")
        .with_extra("cause", error.code))?;
    session.log(Level::Success, &format!("Подписка опубликована: {name}"));
    verify(json!({"client": name, "url": link(&config, &token), "expires_at": saved})).await
}

// ─── revoke / rotate ─────────────────────────────────────────────────────────

pub(super) async fn revoke<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T)
    -> Result<Value>
{
    let name = required(invocation, "name")?;
    let config = session.state.load_config()?;
    let client = find_client(&config, name)?;
    client_token(client)?.ok_or_else(|| no_subscription(name))?;
    let host = host_node(&config)?;
    Plan::new(vec![format!("Клиент: {name}"), format!("Хост-нода: {host}"),
        "Ссылка перестанет работать; конфиг клиента сохранится.".into()], "").confirm(invocation)?;
    revoke_client(session, name, connect).await?;
    Ok(json!({"client": name}))
}

pub(super) async fn revoke_client<T: RemoteTransport>(session: &mut Session, name: &str, connect: &dyn Fn() -> T)
    -> Result<()>
{
    let config = session.state.load_config()?;
    let Some(token) = client_token(find_client(&config, name)?)? else { return Ok(()) };
    let not_revoked = format!("Подписка «{name}» не отозвана: ссылка может оставаться действующей.");
    let host = match remote::open_host(session, &config, connect).await {
        Ok(host) => host,
        Err(error) => {
            session.log(Level::Warn, &not_revoked);
            return Err(error);
        }
    };
    let (removal, warning) = remote::remove_token(&host.transport, &host.sub_dir, &token, None).await;
    drop(host);
    if let Some(warning) = warning { session.log(Level::Warn, &warning); }
    if removal != Removal::Removed {
        return Err(RcError::new("remote_failed", not_revoked).with_extra("name", name));
    }
    session.mutate("subscription_revoke", |state| {
        let mut config = state.load_config()?;
        let subscription = config.clients.iter_mut().find(|client| client.name == name)
            .and_then(|client| client.subscription.as_mut())
            .filter(|subscription| subscription.token.as_deref() == Some(token.as_str()));
        if let Some(subscription) = subscription {
            subscription.token = None;
            subscription.created_at = None;
            subscription.expires_at = None;
            state.save_config(&config)?;
        }
        Ok(())
    })?;
    session.log(Level::Success, &format!("Подписка отозвана: {name}"));
    Ok(())
}

/// New token → upload → removal of the old link (its expiry entry moves to
/// the new token) → local save. A failed removal restores the old link and
/// then removes the new copy; the local token changes only after success.
pub(super) async fn rotate<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T)
    -> Result<Value>
{
    let name = required(invocation, "name")?;
    let config = session.state.load_config()?;
    let client = find_client(&config, name)?;
    let old = client_token(client)?.ok_or_else(|| no_subscription(name))?;
    let yaml = rendered(session, client)?
        .ok_or_else(|| not_generated(name, &format!("Конфиг для «{name}» не найден или пуст.")))?;
    let host_name = host_node(&config)?;
    let headers = check_headers(&config, client)?;
    Plan::new(vec![format!("Клиент: {name}"), format!("Хост-нода: {host_name}"),
        "Старая ссылка перестанет работать; новая ссылка будет показана после завершения.".into()], "")
        .confirm(invocation)?;

    let host = remote::open_host(session, &config, connect).await?;
    let token = new_token();
    let item = Item { token: &token, yaml: &yaml, snippet: render_snippet(&token, &host.sub_dir, &headers) };
    if let Err(failure) = remote::upload(&host.transport, &host.sub_dir, &host.nginx_group, &[item]).await {
        session.log(Level::Warn, &upload_warning(failure, name));
        return Err(RcError::new("remote_failed", "Смена токена не выполнена: новая подписка не загружена."));
    }
    let (removal, warning) = remote::remove_token(&host.transport, &host.sub_dir, &old, Some(&token)).await;
    if let Some(warning) = warning { session.log(Level::Warn, &warning); }
    if removal != Removal::Removed {
        if removal == Removal::Restored {
            let (cleanup, warning) = remote::remove_token(&host.transport, &host.sub_dir, &token, None).await;
            if let Some(warning) = warning { session.log(Level::Warn, &warning); }
            if cleanup != Removal::Removed {
                session.log(Level::Warn, "Старая подписка восстановлена; удаление новой копии не подтверждено.");
            }
        } else {
            session.log(Level::Warn, "Новая подписка сохранена на хосте: доступность старой ссылки не подтверждена. \
                Локально остался старый токен; перед повтором проверьте хост-ноду.");
        }
        return Err(RcError::new("remote_failed", "Смена токена не завершена: удаление старой ссылки не подтверждено."));
    }
    drop(host);
    let stamp = iso(now());
    session.mutate("subscription_rotate", |state| {
        let mut config = state.load_config()?;
        let client = config.clients.iter_mut().find(|client| client.name == name)
            .ok_or_else(|| RcError::new("not_found", format!("Клиент «{name}» не найден.")))?;
        let subscription = client.subscription.get_or_insert_with(Default::default);
        subscription.token = Some(token.clone());
        subscription.created_at = Some(stamp);
        state.save_config(&config)
    }).map_err(|error| RcError::new("failed",
        "Старый токен удалён, но новый токен не удалось сохранить локально. Смена токена не завершена.")
        .with_extra("cause", error.code))?;
    session.log(Level::Success, &format!("Токен обновлён: {name}"));
    verify(json!({"client": name, "url": link(&config, &token)})).await
}

// ─── publish-all ─────────────────────────────────────────────────────────────

struct Target {
    name: String,
    yaml: Vec<u8>,
    headers: Vec<SubscriptionHeader>,
    token: Option<String>,
}

fn summary(published: &[String], skipped: &[String], failed: &[String], removed: u64) -> Value {
    json!({"published": published, "skipped": skipped, "failed": failed, "removed": removed})
}

/// Publish every client with a generated config in one batch, then delete
/// from the host the subscriptions no client owns. The plan (read-only SSH
/// listing; token prefixes only) is confirmed first; the exact orphan set is
/// bound into the plan token.
pub(super) async fn publish_all<T: RemoteTransport>(session: &mut Session, invocation: &Invocation,
    connect: &dyn Fn() -> T) -> Result<Value>
{
    let config = session.state.load_config()?;
    let host_name = host_node(&config)?;
    let (mut known, mut targets, mut skipped) = (Vec::new(), Vec::new(), Vec::new());
    for client in &config.clients {
        let token = client_token(client)?;
        known.extend(token.clone());
        match rendered(session, client)? {
            None => skipped.push(client.name.clone()),
            Some(yaml) => {
                let headers = check_headers(&config, client)?;
                targets.push(Target { name: client.name.clone(), yaml, headers, token });
            }
        }
    }
    if targets.is_empty() {
        for name in &skipped {
            session.log(Level::Info, &format!("{name}: пропущено — конфиг отсутствует или пуст"));
        }
        session.log(Level::Info, "Нет конфигов для публикации.");
        if !skipped.is_empty() {
            session.log(Level::Info, &format!("Пропущено (конфиг отсутствует или пуст): {}", skipped.len()));
        }
        return Ok(summary(&[], &skipped, &[], 0));
    }

    let host = remote::open_host(session, &config, connect).await?;
    let on_host = remote::list_tokens(&host.transport, &host.sub_dir).await?;
    if known.is_empty() && !on_host.is_empty() {
        return Err(RcError::new("failed", "В конфигурации нет ни одного токена подписки, а на хост-ноде есть \
            опубликованные подписки. Публикация отменена, на хосте ничего не удалено — проверьте конфигурацию."));
    }
    let orphans: Vec<String> = on_host.into_iter().filter(|token| !known.contains(token)).collect();
    let mut lines = vec![format!("Хост-нода: {host_name}"), format!("Будут опубликованы ({}):", targets.len())];
    lines.extend(targets.iter().map(|target| format!(" {}", target.name)));
    if orphans.is_empty() {
        lines.push("Подписок без клиента на хосте нет.".into());
    } else {
        lines.push(format!("Подписки без клиента в конфигурации будут удалены с хоста ({}):", orphans.len()));
        lines.extend(orphans.iter().map(|token| format!(" {}…", &token[..8])));
    }
    lines.push("nginx на хост-ноде будет перезагружен.".into());
    Plan::new(lines, orphans.join("\n")).confirm(invocation)?;

    for name in &skipped {
        session.log(Level::Info, &format!("{name}: пропущено — конфиг отсутствует или пуст"));
    }
    let tokens: Vec<String> = targets.iter().map(|target| target.token.clone().unwrap_or_else(new_token)).collect();
    let items: Vec<Item> = targets.iter().zip(&tokens).map(|(target, token)| Item {
        token, yaml: &target.yaml, snippet: render_snippet(token, &host.sub_dir, &target.headers),
    }).collect();
    let published: Vec<String> = targets.iter().map(|target| target.name.clone()).collect();
    if let Err(failure) = remote::upload(&host.transport, &host.sub_dir, &host.nginx_group, &items).await {
        session.log(Level::Warn, batch_warning(failure));
        for name in &published {
            session.log(Level::Warn, &format!("{name}: публикация не подтверждена"));
        }
        session.log(Level::Info, &format!("Опубликовано: 0; пропущено: {}; ошибка: {}", skipped.len(), published.len()));
        return Err(with_data(RcError::new("remote_failed", "Подписки не опубликованы: ошибка загрузки на хост-ноду."),
            &summary(&[], &skipped, &published, 0)));
    }
    drop(items);

    let fresh: Vec<(String, String)> = targets.iter().zip(&tokens).filter(|(target, _)| target.token.is_none())
        .map(|(target, token)| (target.name.clone(), token.clone())).collect();
    if !fresh.is_empty() {
        let stamp = iso(now());
        let saved = session.mutate("subscription_publish_all", |state| {
            let mut config = state.load_config()?;
            for (name, token) in &fresh {
                let Some(client) = config.clients.iter_mut().find(|client| client.name == *name) else { continue };
                let subscription = client.subscription.get_or_insert_with(Default::default);
                if subscription.token.as_deref().is_none_or(str::is_empty) {
                    subscription.token = Some(token.clone());
                    subscription.created_at = Some(stamp.clone());
                    subscription.expires_at = None;
                }
            }
            state.save_config(&config)
        });
        if saved.is_err() {
            let failed: Vec<String> = fresh.into_iter().map(|(name, _)| name).collect();
            let ok: Vec<String> = published.iter().filter(|name| !failed.contains(name)).cloned().collect();
            for name in &failed {
                session.log(Level::Warn, &format!("{name}: публикация не подтверждена"));
            }
            return Err(with_data(RcError::new("failed", "Файлы загружены пакетно, но новые токены сохранить не удалось. \
                Дальнейшие записи и очистка старых файлов остановлены."), &summary(&ok, &skipped, &failed, 0)));
        }
    }
    for name in &published {
        session.log(Level::Success, &format!("{name}: опубликовано"));
    }
    session.log(Level::Success, &format!("Опубликовано: {}", published.len()));
    session.log(Level::Info, &format!("Пропущено (конфиг отсутствует или пуст): {}", skipped.len()));
    session.log(Level::Info, "Ошибка: 0");

    // Only planned orphans that still belong to no client are deleted.
    let owned: Vec<String> = session.state.load_config()?.clients.iter()
        .filter_map(|client| client_token(client).ok().flatten()).collect();
    let prune: Vec<String> = orphans.into_iter().filter(|token| !owned.contains(token)).collect();
    let (removed, clean) = remote::prune(&host.transport, &host.sub_dir, &prune).await;
    if removed > 0 {
        session.log(Level::Info, &format!("Удалено осиротевших подписок: {removed}"));
    }
    let data = summary(&published, &skipped, &[], removed);
    if !clean {
        return Err(with_data(RcError::new("partial",
            "Подписки опубликованы, но не все подписки без клиента удалены с хост-ноды."), &data));
    }
    Ok(data)
}

// ─── migrate ─────────────────────────────────────────────────────────────────

struct Moving {
    name: String,
    token: String,
    yaml: Vec<u8>,
    headers: Vec<SubscriptionHeader>,
    expiry: Option<i64>,
}

/// Move every published subscription to another node: expiry entries and
/// files first, then the host switch, then removal of the old links. Tokens
/// stay; only the base URL changes. A failure before the switch leaves the
/// old host and links intact.
pub(super) async fn migrate<T: RemoteTransport>(session: &mut Session, invocation: &Invocation,
    connect: &dyn Fn() -> T) -> Result<Value>
{
    let config = session.state.load_config()?;
    let old = config.subscription_host.clone().filter(|host| !host.node.is_empty())
        .ok_or_else(not_configured)?;
    let target = required(invocation, "name")?;
    nodes::find(&config, target)?;
    if target == old.node {
        return Err(RcError::new("invalid", "Выбрана текущая хост-нода. Перенос не выполнен."));
    }
    let mut moving = Vec::new();
    for client in config.clients.iter().filter(|client| has_token(client)) {
        let name = &client.name;
        let token = client_token(client).ok().flatten().ok_or_else(|| RcError::new("invalid", format!(
            "Токен подписки клиента «{name}» в конфигурации повреждён. Перенос отменён.")).with_extra("name", name.clone()))?;
        let yaml = rendered(session, client)?
            .ok_or_else(|| not_generated(name, &format!("{name}: конфиг отсутствует или пуст. Перенос отменён.")))?;
        let headers = check_headers(&config, client)?;
        let expiry = match client.subscription.as_ref().and_then(|s| s.expires_at.as_deref()).filter(|e| !e.is_empty()) {
            Some(text) => Some(parse_iso(text).ok_or_else(|| RcError::new("invalid", format!(
                "{name}: срок подписки не распознан. Перенос отменён.")).with_extra("name", name.clone()))?),
            None => None,
        };
        moving.push(Moving { name: name.clone(), token, yaml, headers, expiry });
    }
    if moving.is_empty() {
        session.log(Level::Info, "Нет опубликованных подписок для переноса; хост не изменён.");
        return Ok(json!({"node": target, "base_url": null, "migrated": 0}));
    }

    let old_remote = remote::connect_node(session, &config, &old.node, connect).await?;
    let old_conf = remote::read_conf(&old_remote, &old.node, "Хост-нода подписок недоступна.").await?;
    let new_remote = remote::connect_node(session, &config, target, connect).await?;
    let new_conf = remote::read_conf(&new_remote, target, "Новая хост-нода подписок недоступна.").await?;
    let (Some(old_dir), Some(new_dir), Some(nginx_group), true) =
        (old_conf.sub_dir(), new_conf.sub_dir(), new_conf.nginx_group(), new_conf.complete()) else {
        return Err(RcError::new("invalid", "Конфигурация хостинга подписок неполна. Перенос отменён."));
    };
    let mut lines = vec![format!("Старая хост-нода: {}", old.node), format!("Базовый URL: {}", old.base_url),
        format!("Новая хост-нода: {target}"), format!("Базовый URL: {}", new_conf.base_url)];
    lines.extend(moving.iter().map(|m| m.name.clone()));
    lines.push("Все адреса подписок изменятся.".into());
    lines.push("Старые ссылки будут удалены только после загрузки всех подписок.".into());
    Plan::new(lines, "").confirm(invocation)?;

    // Expiry first: a stale entry of the token on the new host must not
    // delete the uploaded YAML.
    let pairs: Vec<(String, Option<i64>)> = moving.iter().map(|m| (m.token.clone(), m.expiry)).collect();
    let mut copied = remote::write_expiry(&new_remote, new_dir, &pairs).await;
    if copied {
        let items: Vec<Item> = moving.iter().map(|m| Item {
            token: &m.token, yaml: &m.yaml, snippet: render_snippet(&m.token, new_dir, &m.headers),
        }).collect();
        if let Err(failure) = remote::upload(&new_remote, new_dir, &nginx_group, &items).await {
            session.log(Level::Warn, batch_warning(failure));
            copied = false;
        }
    }
    drop(new_remote);
    if !copied {
        session.log(Level::Warn, "Перенос не завершён: старый хост и старые ссылки сохранены.");
        return Err(RcError::new("remote_failed", "На новой ноде могли остаться копии подписок."));
    }
    let host = SubscriptionHost { node: target.into(), base_url: new_conf.base_url.clone(), sub_dir: new_dir.into(), nginx_group };
    session.mutate("subscription_migrate", |state| {
        let mut config = state.load_config()?;
        config.subscription_host = Some(host);
        state.save_config(&config)
    })?;
    let data = json!({"node": target, "base_url": new_conf.base_url, "migrated": moving.len()});
    let mut clean = true;
    for m in &moving {
        let (removal, warning) = remote::remove_token(&old_remote, old_dir, &m.token, None).await;
        if let Some(warning) = warning { session.log(Level::Warn, &warning); }
        clean &= removal == Removal::Removed;
    }
    if !clean {
        return Err(with_data(RcError::new("partial",
            "Подписки перенесены, но старые ссылки не удалось полностью удалить. Требуется очистка старой ноды."), &data));
    }
    session.log(Level::Success, &format!("Перенесено {} подписок на «{target}»", moving.len()));
    session.log(Level::Info, &format!("Новый базовый URL: {}", new_conf.base_url));
    Ok(data)
}
