//! `client *` commands (v1 `clients.sh` and the client handlers of
//! `cmd_clients.sh`). Local changes go through `Session::mutate`; server
//! effects are delegated: AmneziaWG clients to `crate::awg`, listener users
//! and config rendering to `generate`, subscriptions to `crate::subscription`.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use serde_json::{Value, json};

use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::model::{Client, ClientConnection, ClientCredentials, Config};
use crate::nodes::required;
use crate::transport::RemoteTransport;
use crate::validation as v;

use super::{
    awg_capable_nodes, client_awg_nodes, client_dir, client_nodes, client_not_found, entry_exists, find_client,
    find_group, generate, generated_guard, generated_path_safe, group_nodes, node_line, remove_entry, require_one,
    templates, unique_values,
};

fn name_invalid() -> RcError {
    RcError::new("invalid", "Имя может содержать только буквы, цифры, точку, - и _")
}

fn token(client: &Client) -> Option<&str> {
    client.subscription.as_ref().and_then(|s| s.token.as_deref()).filter(|t| !t.is_empty())
}

fn view(config: &Config, client: &Client) -> Value {
    json!({
        "name": client.name,
        "group": client.group,
        "inherit_nodes": client.inherit_nodes_from_group,
        "nodes": client_nodes(config, client),
        "subscription": {
            "published": token(client).is_some(),
            "expires_at": client.subscription.as_ref().and_then(|s| s.expires_at.clone()),
        },
    })
}

/// Connections per effective node without SSH: own or the group's.
fn connections_view(config: &Config, client: &Client) -> Value {
    Value::Array(client_nodes(config, client).into_iter().map(|node| {
        match client.connections.iter().flatten().find(|c| c.node == node) {
            Some(own) => json!({"node": node, "mode": "own", "proxies": own.proxies}),
            None => {
                let proxies: Vec<&String> = config.connections.iter().filter(|c| c.node == node)
                    .flat_map(|c| &c.groups).filter(|g| g.name == client.group).flat_map(|g| &g.proxies).collect();
                json!({"node": node, "mode": "group", "proxies": proxies})
            }
        }
    }).collect())
}

pub fn list(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let config = session.state.load_config()?;
    let filter = invocation.has("group").then(|| invocation.value("group").unwrap_or(""));
    if let Some(group) = filter {
        find_group(&config, group)?;
    }
    Ok(Value::Array(config.clients.iter().filter(|c| filter.is_none_or(|g| c.group == g))
        .map(|client| view(&config, client)).collect()))
}

/// Includes the credentials and the subscription link (data, never argv/log).
pub fn show(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?;
    let config = session.state.load_config()?;
    let client = find_client(&config, name)?;
    let path = generate::client_config_path(session.state.paths(), client)?;
    let subscription = token(client).map(|token| {
        let base = config.subscription_host.as_ref().map(|h| h.base_url.as_str()).filter(|b| !b.is_empty());
        json!({
            "url": base.map(|base| format!("{base}/sub/{token}")),
            "expires_at": client.subscription.as_ref().and_then(|s| s.expires_at.clone()).filter(|e| !e.is_empty()),
            "headers": crate::subscription::effective_headers(&config, client),
        })
    });
    let mut data = view(&config, client);
    let object = data.as_object_mut().expect("client view is an object");
    object.insert("credentials".into(), json!({
        "vless_uuid": client.credentials.as_ref().map(|c| &c.vless_uuid),
        "hy2_password": client.credentials.as_ref().map(|c| &c.hy2_password),
    }));
    object.insert("connections".into(), connections_view(&config, client));
    object.insert("config".into(), json!({"path": path.display().to_string(), "exists": path.is_file()}));
    object.insert("subscription".into(), subscription.unwrap_or(Value::Null));
    Ok(data)
}

/// The generated config's text for download or display (with secrets, data
/// only). `content` is `null` until `generate` created the file.
pub fn config(session: &Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?;
    let config = session.state.load_config()?;
    let client = find_client(&config, name)?;
    let content = generate::config_file(session.state.paths(), client)?.map(String::from_utf8).transpose()
        .map_err(|_| RcError::new("invalid", format!("Конфиг клиента «{}» не в кодировке UTF-8.", client.name))
            .with_extra("name", client.name.clone()))?;
    Ok(json!({"name": client.name, "group": client.group, "exists": content.is_some(), "content": content}))
}

/// v1 `_client_connections_check`: own connections exist only for a client
/// with its own nodes and only on an assigned node.
fn connections_check(config: &Config, name: &str, node: &str) -> Result<()> {
    let client = find_client(config, name)?;
    if client.inherit_nodes_from_group {
        return Err(RcError::new("invalid", "Подключения настраиваются только для клиента со своими нодами."));
    }
    if !client.nodes.iter().flatten().any(|n| n == node) {
        return Err(RcError::new("invalid", format!("Нода «{node}» не назначена клиенту «{name}».")));
    }
    Ok(())
}

pub fn connections(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    if !invocation.has("node") && !invocation.has("proxy") && !invocation.has("reset") {
        let config = session.state.load_config()?;
        return Ok(connections_view(&config, find_client(&config, &name)?));
    }
    let node = required(invocation, "node")?.to_owned();
    require_one(invocation, &["proxy", "reset"])?;
    let proxies = unique_values(invocation, "proxy");
    if invocation.has("reset") {
        connections_check(&session.state.load_config()?, &name, &node)?;
        Plan::new(vec![format!("Клиент: {name}"), format!("Нода: {node}"),
            "Собственные подключения будут удалены; будут применены подключения группы.".into()], "").confirm(invocation)?;
    }
    session.mutate("set_client_connections", |state| {
        let mut config = state.load_config()?;
        connections_check(&config, &name, &node)?;
        let client = config.clients.iter_mut().find(|c| c.name == name).expect("checked client");
        let own = client.connections.get_or_insert_with(Vec::new);
        own.retain(|c| c.node != node);
        if !proxies.is_empty() {
            own.push(ClientConnection { node: node.clone(), proxies: proxies.clone() });
        }
        state.save_config(&config)
    })?;
    session.log(Level::Success, &format!("{name} → {node}: подключения сохранены"));
    Ok(json!({"name": name, "node": node, "proxies": proxies}))
}

/// Random RFC 4122 version-4 UUID, lowercase.
fn uuid_v4() -> String {
    let mut bytes = [0u8; 16];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = hex::encode(bytes);
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

/// A client with the group's nodes and fresh credentials (VLESS UUID,
/// 32-hex Hysteria2 password); credentials never reach argv or the journal.
pub fn add(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let group = required(invocation, "group")?.to_owned();
    if !v::name_valid(&name) { return Err(name_invalid()); }
    let credentials = ClientCredentials { vless_uuid: uuid_v4(), hy2_password: crate::github::random_hex(16) };
    if !v::vless_uuid_valid(&credentials.vless_uuid) || !v::hy2_password_valid(&credentials.hy2_password) {
        return Err(RcError::new("failed", "Не удалось создать учётные данные клиента."));
    }
    let nodes = session.mutate("add_client", |state| {
        let mut config = state.load_config()?;
        if config.clients.iter().any(|c| c.name == name) {
            return Err(RcError::new("conflict", format!("Клиент «{name}» уже существует.")).with_extra("name", name.clone()));
        }
        find_group(&config, &group)?;
        config.clients.push(Client { name: name.clone(), group: group.clone(), credentials: Some(credentials), ..Client::default() });
        state.save_config(&config)?;
        Ok(group_nodes(&config, &group))
    })?;
    if nodes.is_empty() {
        session.log(Level::Warn, &format!("У группы {group} нет нод. Назначьте прокси группе через Подключения."));
    } else {
        session.log(Level::Info, &format!("Ноды группы: {}", nodes.join(", ")));
    }
    session.log(Level::Success, &format!("Клиент {name} добавлен ({group}, ноды от группы)"));
    Ok(json!({"name": name, "group": group}))
}

struct RenamePlan {
    old_dir: PathBuf,
    new_dir: PathBuf,
    awg_nodes: Vec<String>,
    lines: Vec<String>,
}

/// v1 `core_client_rename_plan`: checks only; plan lines exist only when an
/// AmneziaWG client with the old name is removed on servers.
fn rename_plan(state: &crate::state::State, config: &Config, old: &str, new: &str) -> Result<RenamePlan> {
    let client = find_client(config, old)?;
    if config.clients.iter().any(|c| c.name == new) {
        return Err(RcError::new("conflict", format!("Клиент «{new}» уже существует.")).with_extra("name", new));
    }
    let paths = state.paths();
    let old_dir = client_dir(paths, client)?;
    let new_dir = old_dir.with_file_name(new);
    if entry_exists(&old_dir)? {
        generated_guard(paths, &old_dir)?;
        generated_guard(paths, &new_dir)?;
    }
    if entry_exists(&new_dir)? {
        return Err(RcError::new("conflict", format!(
            "Каталог конфигов «{}» уже существует — удалите его или выберите другое имя.", new_dir.display())));
    }
    let awg_nodes = client_awg_nodes(config, client, None);
    let mut lines = Vec::new();
    if !awg_nodes.is_empty() {
        lines.push(format!("Клиент: {old} → {new}"));
        lines.push(format!("Клиент AmneziaWG «{old}» будет удалён на нодах:"));
        lines.extend(awg_nodes.iter().map(|node| node_line(config, node)));
        lines.push(format!("Клиент AmneziaWG «{new}» будет создан при следующей генерации конфигов."));
    }
    Ok(RenamePlan { old_dir, new_dir, awg_nodes, lines })
}

/// `rename_plan` again under the mutation lock: a different plan (other
/// AmneziaWG nodes, another directory) is `plan_changed` with the current one.
fn rename_recheck(state: &crate::state::State, config: &Config, old: &str, new: &str, planned: &RenamePlan,
    invocation: &Invocation) -> Result<()>
{
    let current = rename_plan(state, config, old, new)?;
    if current.lines != planned.lines || current.new_dir != planned.new_dir {
        return Err(Plan::new(current.lines, "").changed(invocation));
    }
    Ok(())
}

/// The plan is rebuilt under the mutation lock (`plan_changed` when it
/// differs). The config directory moves before the record and moves back when the
/// record cannot be saved; AmneziaWG removal failures afterwards → partial.
pub async fn rename<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T) -> Result<Value> {
    let old = required(invocation, "name")?.to_owned();
    let new = required(invocation, "new-name")?.to_owned();
    let config = session.state.load_config()?;
    find_client(&config, &old)?;
    if !v::name_valid(&new) { return Err(name_invalid()); }
    if new == old { return Ok(json!({"name": new})); }
    let plan = rename_plan(&session.state, &config, &old, &new)?;
    if !plan.lines.is_empty() {
        Plan::new(plan.lines.clone(), "").confirm(invocation)?;
    }
    let (old_dir, new_dir) = (plan.old_dir.clone(), plan.new_dir.clone());
    let restore = |moved: bool| {
        if moved && fs::rename(&new_dir, &old_dir).is_err() {
            return Some(format!("Каталог конфигов не возвращён: перенесите «{}» в «{}» вручную.", new_dir.display(), old_dir.display()));
        }
        None
    };
    let mut moved = false;
    let saved = session.mutate("rename_client", |state| {
        let mut config = state.load_config()?;
        rename_recheck(state, &config, &old, &new, &plan, invocation)?;
        if fs::symlink_metadata(&old_dir).is_ok_and(|meta| meta.is_dir()) {
            fs::rename(&old_dir, &new_dir).map_err(|_| RcError::new("failed", format!(
                "Не удалось перенести каталог конфигов клиента «{old}»; клиент не переименован.")))?;
            moved = true;
        }
        config.clients.iter_mut().filter(|c| c.name == old).for_each(|c| c.name = new.clone());
        state.save_config(&config)
    });
    if let Err(error) = saved {
        // Also covers a failed GitHub checkpoint, which restores the record.
        let still_old = session.state.load_config().is_ok_and(|config| config.clients.iter().any(|c| c.name == old));
        if still_old && let Some(warning) = restore(moved) {
            session.log(Level::Warn, &warning);
        }
        return Err(error);
    }
    session.log(Level::Success, &format!("Клиент «{old}» переименован в «{new}»"));
    let mut failed = Vec::new();
    for node in &plan.awg_nodes {
        if let Err(error) = crate::awg::remove_peers(session, node, std::slice::from_ref(&old), connect).await {
            session.log(Level::Warn, &error.message);
            failed.push(node.clone());
        }
    }
    if !failed.is_empty() {
        return Err(RcError::new("partial", format!(
            "Клиент переименован, но клиента AmneziaWG «{old}» не удалось удалить на нодах: {}. Удалите его через awg remove.",
            failed.join(", "))).with_extra("name", new).with_extra("nodes", failed));
    }
    Ok(json!({"name": new}))
}

/// `--inherit` (gated when own nodes or connections are dropped) or `--node N…`.
pub fn nodes(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    require_one(invocation, &["inherit", "node"])?;
    let inherit = invocation.has("inherit");
    let selected = unique_values(invocation, "node");
    if inherit {
        let config = session.state.load_config()?;
        let client = find_client(&config, &name)?;
        let own_nodes: Vec<String> = client.nodes.iter().flatten().map(|n| format!(" {n}")).collect();
        let own_connections: Vec<String> = client.connections.iter().flatten()
            .map(|c| format!(" {}: {}", c.node, c.proxies.join(", "))).collect();
        if !own_nodes.is_empty() || !own_connections.is_empty() {
            let mut lines = vec![format!("Клиент: {name}")];
            if !own_nodes.is_empty() {
                lines.push("Свои ноды будут сброшены:".into());
                lines.extend(own_nodes);
            }
            if !own_connections.is_empty() {
                lines.push("Собственные подключения будут удалены:".into());
                lines.extend(own_connections);
            }
            lines.push(format!("Будут использоваться ноды и подключения группы {}.", client.group));
            Plan::new(lines, "").confirm(invocation)?;
        }
    }
    let data = session.mutate(if inherit { "inherit_client_nodes" } else { "set_client_nodes" }, |state| {
        let mut config = state.load_config()?;
        find_client(&config, &name)?;
        for node in &selected {
            crate::nodes::find(&config, node)?;
        }
        let client = config.clients.iter_mut().find(|c| c.name == name).expect("checked client");
        client.inherit_nodes_from_group = inherit;
        if inherit {
            client.nodes = None;
            client.connections = None;
        } else {
            client.nodes = Some(selected.clone());
        }
        state.save_config(&config)?;
        let client = find_client(&config, &name)?;
        Ok(json!({"name": name, "inherit_nodes": inherit, "nodes": client_nodes(&config, client)}))
    })?;
    let message = if inherit {
        format!("{name}: ноды от группы")
    } else {
        format!("{name}: свои ноды — {}", if selected.is_empty() { "нет".to_owned() } else { selected.join(", ") })
    };
    session.log(Level::Success, &message);
    Ok(data)
}

struct SetGroupPlan {
    lines: Vec<String>,
    affected: Vec<String>,
    awg_drop: Vec<String>,
    old_dir: PathBuf,
    published: bool,
}

fn push_unique(list: &mut Vec<String>, items: impl IntoIterator<Item = String>) {
    for item in items {
        if !list.contains(&item) { list.push(item); }
    }
}

/// v1 `core_client_set_group_plan`: validation and impact review.
fn set_group_plan(session: &Session, config: &Config, name: &str, group: &str) -> Result<SetGroupPlan> {
    let client = find_client(config, name)?;
    find_group(config, group)?;
    if !generate::generated_name_valid(group) {
        return Err(RcError::new("invalid", format!("Недопустимое имя группы «{group}» в конфигурации.")));
    }
    let current = client.group.as_str();
    if group == current {
        return Err(RcError::new("invalid", format!("Клиент «{name}» уже в группе «{group}».")));
    }
    let mut affected = group_nodes(config, current);
    push_unique(&mut affected, group_nodes(config, group));
    if !client.inherit_nodes_from_group {
        push_unique(&mut affected, client.nodes.clone().unwrap_or_default());
    }
    let keep = client_awg_nodes(config, client, Some(group));
    let awg_drop: Vec<String> = client_awg_nodes(config, client, None).into_iter().filter(|n| !keep.contains(n)).collect();
    let paths = session.state.paths();
    let old_dir = client_dir(paths, client)?;
    if entry_exists(&old_dir)? {
        generated_guard(paths, &old_dir)?;
    }
    let published = token(client).is_some();

    let mut lines = vec![format!("Клиент: {name}"), format!("Группа: {current} → {group}")];
    let (old_template, new_template) = (templates::group_template(config, current), templates::group_template(config, group));
    if old_template != new_template {
        lines.push(format!("Шаблон: {old_template} → {new_template}"));
    }
    if client.inherit_nodes_from_group {
        let show = |nodes: Vec<String>| if nodes.is_empty() { "нет".to_owned() } else { nodes.join(", ") };
        lines.push(format!("Ноды клиента: {} → {}", show(group_nodes(config, current)), show(group_nodes(config, group))));
    }
    lines.push("Затронутые ноды:".into());
    if affected.is_empty() { lines.push(" нет".into()); }
    lines.extend(affected.iter().map(|node| node_line(config, node)));
    let own = client.connections.as_ref().map_or(0, Vec::len);
    if own > 0 {
        lines.push(format!("Собственные подключения ({own}) сохранятся — проверьте их: client connections --name {name}."));
    }
    if published {
        let changes = header_changes(config, client, group);
        if !changes.is_empty() {
            lines.push("Заголовки подписки изменятся:".into());
            lines.extend(changes);
        }
    }
    lines.push("Старый каталог конфигов (удаляется после генерации нового):".into());
    lines.push(format!(" {}", old_dir.display()));
    if published { lines.push("Подписка клиента будет обновлена.".into()); }
    if !awg_drop.is_empty() {
        lines.push(format!("Клиент AmneziaWG «{name}» будет удалён на нодах: {}", awg_drop.join(", ")));
    }
    if !affected.is_empty() {
        lines.push("Служба mihomo на затронутых нодах может быть перезапущена.".into());
    }
    Ok(SetGroupPlan { lines, affected, awg_drop, old_dir, published })
}

/// Effective subscription header differences (default → group → client)
/// when the client moves to `group`.
fn header_changes(config: &Config, client: &Client, group: &str) -> Vec<String> {
    let before = crate::subscription::effective_headers(config, client);
    let moved = Client { group: group.to_owned(), ..client.clone() };
    let after = crate::subscription::effective_headers(config, &moved);
    let value = |list: &[crate::model::SubscriptionHeader], key: &str| {
        list.iter().rev().find(|h| h.name == key).map(|h| h.value.clone())
    };
    let keys: BTreeSet<&str> = before.iter().chain(&after).map(|h| h.name.as_str()).collect();
    keys.into_iter().filter_map(|key| match (value(&before, key), value(&after, key)) {
        (None, Some(new)) => Some(format!(" + {key}: {new}")),
        (Some(old), None) => Some(format!(" - {key}: {old}")),
        (Some(old), Some(new)) if old != new => Some(format!(" {key}: {old} → {new}")),
        _ => None,
    }).collect()
}

/// Moves the client, regenerates the new group's configs, syncs the affected
/// nodes, drops AmneziaWG clients that lose access and republishes the
/// subscription. Any failure after the record changed → partial.
pub async fn set_group<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let group = required(invocation, "group")?.to_owned();
    let plan = set_group_plan(session, &session.state.load_config()?, &name, &group)?;
    Plan::new(plan.lines.clone(), "").confirm(invocation)?;
    session.mutate("change_client_group", |state| {
        let mut config = state.load_config()?;
        find_group(&config, &group)?;
        let client = config.clients.iter_mut().find(|c| c.name == name).ok_or_else(|| client_not_found(&name))?;
        client.group = group.clone();
        state.save_config(&config)
    })?;
    session.log(Level::Success, &format!("{name}: группа — {group}"));

    let mut failed = false;
    let generated = match generate::regenerate_group(session, &group, &plan.affected, connect).await {
        Ok(report) => {
            if !report.complete() {
                session.log(Level::Warn, "Генерация завершена с ошибками.");
                failed = true;
            }
            report.ok.contains(&name)
        }
        Err(error) => {
            session.log(Level::Warn, &error.message);
            failed = true;
            false
        }
    };
    for node in &plan.awg_drop {
        if let Err(error) = crate::awg::remove_peers(session, node, std::slice::from_ref(&name), connect).await {
            session.log(Level::Warn, &error.message);
            failed = true;
        }
    }
    // The old directory goes only once this regeneration wrote the client's
    // new config (even when other clients or nodes failed): a stale
    // config.yaml in the new directory is no proof, a failed or skipped
    // generation keeps the previous config as a fallback.
    let old_dir = &plan.old_dir;
    if generated {
        let config = session.state.load_config()?;
        let new_dir = client_dir(session.state.paths(), find_client(&config, &name)?)?;
        if *old_dir != new_dir && entry_exists(old_dir)? {
            if !generated_path_safe(session.state.paths(), old_dir) {
                session.log(Level::Warn, &format!("{name}: старая папка вне каталога сгенерированных конфигов — не удалена: {}", old_dir.display()));
                failed = true;
            } else if remove_entry(old_dir).is_err() {
                failed = true;
            }
        }
    } else {
        session.log(Level::Warn, &format!("{name}: новый config.yaml не сгенерирован — старая папка сохранена: {}", old_dir.display()));
        failed = true;
    }
    if plan.published {
        session.log(Level::Info, &format!("Обновляю подписку для {name}..."));
        if let Err(error) = crate::subscription::publish(session, &name, connect).await {
            session.log(Level::Warn, &error.message);
            failed = true;
        }
    } else {
        session.log(Level::Info, "У клиента нет подписки — пропуск publish.");
    }
    if failed {
        return Err(RcError::new("partial", "Группа изменена, но обновление конфигов или нод завершено не полностью.")
            .with_extra("name", name).with_extra("group", group));
    }
    Ok(json!({"name": name, "group": group}))
}

struct DeleteScan {
    targets: Vec<String>,
    peer_nodes: Vec<String>,
    affected: Vec<String>,
    dirs: Vec<PathBuf>,
    subscriptions: Vec<String>,
}

/// v1 `_client_delete_scan`. Every node with AmneziaWG in any connection is
/// scanned: an AmneziaWG client may remain there after a group change.
fn delete_scan(session: &Session, config: &Config, names: Vec<String>) -> Result<DeleteScan> {
    let mut scan = DeleteScan { targets: names, peer_nodes: awg_capable_nodes(config), affected: Vec::new(), dirs: Vec::new(), subscriptions: Vec::new() };
    let paths = session.state.paths();
    for name in &scan.targets {
        let client = find_client(config, name)?;
        push_unique(&mut scan.affected, client_nodes(config, client));
        let dir = client_dir(paths, client)?;
        if entry_exists(&dir)? {
            generated_guard(paths, &dir)?;
        }
        scan.dirs.push(dir);
        if token(client).is_some() { scan.subscriptions.push(name.clone()); }
    }
    Ok(scan)
}

fn delete_plan(config: &Config, scan: &DeleteScan) -> Vec<String> {
    let targets = scan.targets.join(", ");
    let mut lines = vec![format!("Клиенты: {targets}"), "Каталоги конфигов:".into()];
    lines.extend(scan.targets.iter().zip(&scan.dirs).map(|(name, dir)| format!(" {name}: {}", dir.display())));
    lines.push("Затронутые ноды:".into());
    if scan.affected.is_empty() { lines.push(" нет".into()); }
    lines.extend(scan.affected.iter().map(|node| node_line(config, node)));
    lines.push(format!("Клиенты AmneziaWG ({targets}) удаляются на нодах:"));
    if scan.peer_nodes.is_empty() { lines.push(" нет".into()); }
    lines.extend(scan.peer_nodes.iter().map(|node| format!(" {node}")));
    let subscriptions = if scan.subscriptions.is_empty() { "нет".to_owned() } else { scan.subscriptions.join(", ") };
    let host = config.subscription_host.as_ref().map_or("нет", |h| h.node.as_str());
    lines.extend([
        format!("Подписки: {subscriptions}"),
        format!("Хост подписок: {host}"),
        "Локальные записи и сгенерированные конфиги будут удалены.".into(),
        "Подписки будут отозваны.".into(),
        "Клиенты AmneziaWG будут удалены; доступ в mihomo будет убран.".into(),
        "Служба mihomo на затронутых нодах будет перезапущена.".into(),
    ]);
    lines
}

fn delete_outcome(error: RcError, deleted: &[String], revoked: &[String], awg_nodes: &[String]) -> RcError {
    error.with_extra("deleted", deleted).with_extra("revoked", revoked).with_extra("awg_nodes", awg_nodes)
}

/// Access is revoked first (subscriptions, then AmneziaWG clients); a failure
/// there keeps the local clients. Then the records and directories go and
/// the listener users of the affected nodes are synchronized.
pub async fn delete<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T) -> Result<Value> {
    let names = unique_values(invocation, "name");
    if names.is_empty() {
        return Err(RcError::new("usage", "Флаг --name не может быть пустым."));
    }
    let config = session.state.load_config()?;
    let scan = delete_scan(session, &config, names)?;
    Plan::new(delete_plan(&config, &scan), "").confirm(invocation)?;

    let mut revoked: Vec<String> = Vec::new();
    for name in &scan.subscriptions {
        if let Err(error) = crate::subscription::revoke_quiet(session, name, connect).await {
            session.log(Level::Warn, &error.message);
            let error = if revoked.is_empty() {
                RcError::new("remote_failed", "Удаление клиентов не завершено: подписки не удалось отозвать. Локальные клиенты сохранены.")
            } else {
                RcError::new("partial", format!("Удаление клиентов не завершено: подписка «{name}» не отозвана; отозваны: {}. Локальные клиенты сохранены.", revoked.join(", ")))
            };
            return Err(delete_outcome(error, &[], &revoked, &[]));
        }
        revoked.push(name.clone());
    }
    let mut awg_done: Vec<String> = Vec::new();
    let mut awg_failed = false;
    for node in &scan.peer_nodes {
        match crate::awg::remove_peers(session, node, &scan.targets, connect).await {
            Ok(()) => awg_done.push(node.clone()),
            Err(error) => {
                session.log(Level::Warn, &error.message);
                awg_failed = true;
            }
        }
    }
    if awg_failed {
        let error = if revoked.is_empty() && awg_done.is_empty() {
            RcError::new("remote_failed", "Удаление клиентов не завершено: клиентов AmneziaWG не удалось удалить. Локальные клиенты сохранены.")
        } else {
            RcError::new("partial", "Удаление клиентов не завершено: клиентов AmneziaWG удалось удалить не на всех нодах. Локальные клиенты сохранены.")
        };
        return Err(delete_outcome(error, &[], &revoked, &awg_done));
    }

    let removed = session.mutate("delete_client", |state| {
        let mut config = state.load_config()?;
        config.clients.retain(|c| !scan.targets.contains(&c.name));
        state.save_config(&config)
    });
    if let Err(error) = removed {
        let error = if revoked.is_empty() && awg_done.is_empty() { error } else {
            RcError::new("partial", format!("Доступ клиентов отозван, но локальные записи удалить не удалось: {}", error.message))
        };
        return Err(delete_outcome(error, &[], &revoked, &awg_done));
    }
    let mut failed = false;
    for dir in &scan.dirs {
        if !entry_exists(dir)? { continue; }
        if !generated_path_safe(session.state.paths(), dir) {
            session.log(Level::Warn, &format!("Каталог вне каталога сгенерированных конфигов не удалён: {}", dir.display()));
            failed = true;
        } else if remove_entry(dir).is_err() {
            session.log(Level::Warn, &format!("Не удалось удалить каталог конфигов: {}", dir.display()));
            failed = true;
        }
    }
    if !generate::sync_listeners(session, &scan.affected, connect).await.is_empty() {
        failed = true;
    }
    if failed {
        return Err(delete_outcome(RcError::new("partial", "Локальные клиенты удалены, но очистка завершена не полностью."),
            &scan.targets, &revoked, &awg_done));
    }
    session.log(Level::Success, &format!("Удалено клиентов: {} ({})", scan.targets.len(), scan.targets.join(", ")));
    Ok(json!({"deleted": scan.targets}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clients::testing::config;
    use crate::fake_transport::FakeTransport;
    use crate::model::{ConnectionGroup, Subscription, SubscriptionHeader, SubscriptionHost};
    use crate::nodes::testing::{Journal, fingerprint, invocation, session};

    fn no_ssh() -> FakeTransport {
        panic!("unexpected SSH connection")
    }

    fn setup(root: &std::path::Path, config: Config) -> (Session, Journal, PathBuf) {
        let (session, journal) = session(root);
        session.state.save_config(&config).unwrap();
        let generated = generate::generated_dir(session.state.paths());
        for (group, client, text) in [("ROUTER", "my-router", "keep router\n"), ("PC", "my-pc", "keep pc\n")] {
            fs::create_dir_all(generated.join(group).join(client)).unwrap();
            fs::write(generated.join(group).join(client).join("config.yaml"), text).unwrap();
        }
        (session, journal, generated)
    }

    async fn run(session: &mut Session, argv: &[&str], connect: &dyn Fn() -> FakeTransport) -> Result<Value> {
        let invocation = invocation(argv);
        match invocation.verb.as_str() {
            "list" => list(session, &invocation),
            "show" => show(session, &invocation),
            "config" => super::config(session, &invocation),
            "connections" => connections(session, &invocation),
            "add" => add(session, &invocation),
            "rename" => rename(session, &invocation, connect).await,
            "nodes" => nodes(session, &invocation),
            "set-group" => set_group(session, &invocation, connect).await,
            _ => delete(session, &invocation, connect).await,
        }
    }

    fn published(mut config: Config) -> Config {
        config.clients[0].subscription = Some(Subscription { token: Some("a".repeat(64)), ..Subscription::default() });
        config.subscription_host = Some(SubscriptionHost {
            node: "de-vps".into(), base_url: "https://sub.example".into(), sub_dir: "/srv/sub".into(), nginx_group: "www-data".into(),
        });
        config
    }

    fn with_awg(mut config: Config) -> Config {
        config.connections[1].groups[0].proxies = vec!["AWG".into()];
        config
    }

    #[tokio::test(flavor = "current_thread")]
    async fn add_generates_private_credentials_and_rejects_conflicts() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal, _) = setup(root.path(), config());
        let data = run(&mut session, &["client", "add", "--name", "new-client", "--group", "ROUTER"], &no_ssh).await.unwrap();
        assert_eq!(data, json!({"name": "new-client", "group": "ROUTER"}));
        let config = session.state.load_config().unwrap();
        let client = find_client(&config, "new-client").unwrap();
        let credentials = client.credentials.clone().unwrap();
        assert!(v::vless_uuid_valid(&credentials.vless_uuid) && credentials.vless_uuid == credentials.vless_uuid.to_lowercase());
        assert_eq!(credentials.vless_uuid.as_bytes()[14], b'4');
        assert!(credentials.hy2_password.len() == 32 && credentials.hy2_password.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)));
        assert!(client.inherit_nodes_from_group && client.nodes.is_none() && client.connections.is_none());
        let raw: Value = serde_json::from_slice(&fs::read(session.state.paths().config()).unwrap()).unwrap();
        assert!(raw["clients"][2].get("nodes").is_none() && raw["clients"][2].get("connections").is_none());
        assert!(journal.borrow().iter().all(|(_, text)| !text.contains(&credentials.vless_uuid) && !text.contains(&credentials.hy2_password)));
        assert!(journal.borrow().iter().any(|(_, text)| text == "Ноды группы: ru-vps"));
        let before = fingerprint(root.path());
        for (argv, code) in [
            (&["client", "add", "--name", "new-client", "--group", "ROUTER"][..], "conflict"),
            (&["client", "add", "--name", "other", "--group", "NOPE"], "not_found"),
            (&["client", "add", "--name", "bad name", "--group", "ROUTER"], "invalid"),
            (&["client", "add", "--name", ".", "--group", "ROUTER"], "invalid"),
            (&["client", "add", "--name", "x"], "usage"),
        ] {
            assert_eq!(run(&mut session, argv, &no_ssh).await.unwrap_err().code, code, "{argv:?}");
        }
        assert_eq!(fingerprint(root.path()), before);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn list_filters_by_group_and_show_returns_credentials_config_and_link() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _, generated) = setup(root.path(), published(config()));
        let before = fingerprint(root.path());
        let listed = run(&mut session, &["client", "list"], &no_ssh).await.unwrap();
        assert_eq!(listed, json!([
            {"name": "my-router", "group": "ROUTER", "inherit_nodes": true, "nodes": ["ru-vps"],
             "subscription": {"published": true, "expires_at": null}},
            {"name": "my-pc", "group": "PC", "inherit_nodes": false, "nodes": ["de-vps"],
             "subscription": {"published": false, "expires_at": null}},
        ]));
        assert_eq!(run(&mut session, &["client", "list", "--group", "PC"], &no_ssh).await.unwrap()[0]["name"], "my-pc");
        assert_eq!(run(&mut session, &["client", "list", "--group", "MOBILE"], &no_ssh).await.unwrap(), json!([]));
        assert_eq!(run(&mut session, &["client", "list", "--group", "NOPE"], &no_ssh).await.unwrap_err().code, "not_found");
        let shown = run(&mut session, &["client", "show", "--name", "my-router"], &no_ssh).await.unwrap();
        assert_eq!(shown["credentials"], json!({"vless_uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "hy2_password": "router-hy2-pass-0001"}));
        assert_eq!(shown["config"], json!({"path": generated.join("ROUTER").join("my-router").join("config.yaml").display().to_string(), "exists": true}));
        assert_eq!(shown["connections"], json!([{"node": "ru-vps", "mode": "group", "proxies": ["vless-reality"]}]));
        assert_eq!(shown["subscription"]["url"], format!("https://sub.example/sub/{}", "a".repeat(64)));
        assert!(shown["subscription"]["headers"].is_array());
        let pc = run(&mut session, &["client", "show", "--name", "my-pc"], &no_ssh).await.unwrap();
        assert_eq!(pc["subscription"], Value::Null);
        assert_eq!(pc["connections"], json!([{"node": "de-vps", "mode": "own", "proxies": ["vless-reality"]}]));
        assert_eq!(run(&mut session, &["client", "show", "--name", "nobody"], &no_ssh).await.unwrap_err().code, "not_found");
        assert_eq!(fingerprint(root.path()), before);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn connections_are_saved_per_node_and_reset_is_checked_then_gated() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _, _) = setup(root.path(), config());
        let data = run(&mut session, &["client", "connections", "--name", "my-pc", "--node", "de-vps",
            "--proxy", "vless-reality", "--proxy", "hy2", "--proxy", "hy2"], &no_ssh).await.unwrap();
        assert_eq!(data, json!({"name": "my-pc", "node": "de-vps", "proxies": ["vless-reality", "hy2"]}));
        let config = session.state.load_config().unwrap();
        assert_eq!(config.clients[1].connections, Some(vec![ClientConnection { node: "de-vps".into(), proxies: vec!["vless-reality".into(), "hy2".into()] }]));
        let before = fingerprint(root.path());
        for (argv, code) in [
            (&["client", "connections", "--name", "my-router", "--node", "de-vps", "--reset"][..], "invalid"),
            (&["client", "connections", "--name", "my-pc", "--node", "ru-vps", "--reset"], "invalid"),
            (&["client", "connections", "--name", "my-pc", "--node", "de-vps", "--reset", "--proxy", "x"], "usage"),
            (&["client", "connections", "--name", "my-pc", "--proxy", "x"], "usage"),
            (&["client", "connections", "--name", "nobody", "--node", "de-vps", "--proxy", "x"], "not_found"),
        ] {
            assert_eq!(run(&mut session, argv, &no_ssh).await.unwrap_err().code, code, "{argv:?}");
        }
        let error = run(&mut session, &["client", "connections", "--name", "my-pc", "--node", "de-vps", "--reset"], &no_ssh).await.unwrap_err();
        assert_eq!((error.code, error.exit), ("confirmation_required", 2));
        assert_eq!(error.extra["plan"], json!(["Клиент: my-pc", "Нода: de-vps",
            "Собственные подключения будут удалены; будут применены подключения группы."]));
        assert_eq!(fingerprint(root.path()), before);
        run(&mut session, &["client", "connections", "--name", "my-pc", "--node", "de-vps", "--reset", "--yes"], &no_ssh).await.unwrap();
        assert_eq!(session.state.load_config().unwrap().clients[1].connections, Some(vec![]));
        assert_eq!(run(&mut session, &["client", "connections", "--name", "my-pc"], &no_ssh).await.unwrap(),
            json!([{"node": "de-vps", "mode": "group", "proxies": ["vless-reality"]}]));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn returning_to_group_nodes_is_gated_only_when_own_selections_are_dropped() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _, _) = setup(root.path(), config());
        let before = fingerprint(root.path());
        let error = run(&mut session, &["client", "nodes", "--name", "my-pc", "--inherit"], &no_ssh).await.unwrap_err();
        assert_eq!(error.code, "confirmation_required");
        assert_eq!(error.extra["plan"], json!(["Клиент: my-pc", "Свои ноды будут сброшены:", " de-vps",
            "Собственные подключения будут удалены:", " de-vps: vless-reality", "Будут использоваться ноды и подключения группы PC."]));
        for (argv, code) in [
            (&["client", "nodes", "--name", "my-pc", "--inherit", "--node", "de-vps"][..], "usage"),
            (&["client", "nodes", "--name", "my-pc"], "usage"),
            (&["client", "nodes", "--name", "my-pc", "--node", "ghost"], "not_found"),
            (&["client", "nodes", "--name", "nobody", "--inherit"], "not_found"),
        ] {
            assert_eq!(run(&mut session, argv, &no_ssh).await.unwrap_err().code, code, "{argv:?}");
        }
        assert_eq!(fingerprint(root.path()), before);
        assert_eq!(run(&mut session, &["client", "nodes", "--name", "my-pc", "--inherit", "--yes"], &no_ssh).await.unwrap(),
            json!({"name": "my-pc", "inherit_nodes": true, "nodes": ["de-vps"]}));
        let raw: Value = serde_json::from_slice(&fs::read(session.state.paths().config()).unwrap()).unwrap();
        assert!(raw["clients"][1].get("nodes").is_none() && raw["clients"][1].get("connections").is_none());
        run(&mut session, &["client", "nodes", "--name", "my-router", "--inherit"], &no_ssh).await.unwrap();
        assert_eq!(run(&mut session, &["client", "nodes", "--name", "my-router", "--node", "de-vps", "--node", "de-vps"], &no_ssh).await.unwrap(),
            json!({"name": "my-router", "inherit_nodes": false, "nodes": ["de-vps"]}));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn rename_moves_the_generated_directory_and_refuses_conflicts() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _, generated) = setup(root.path(), config());
        assert_eq!(run(&mut session, &["client", "rename", "--name", "my-router", "--new-name", "renamed"], &no_ssh).await.unwrap(),
            json!({"name": "renamed"}));
        assert_eq!(fs::read_to_string(generated.join("ROUTER/renamed/config.yaml")).unwrap(), "keep router\n");
        assert!(!generated.join("ROUTER/my-router").exists());
        assert_eq!(session.state.load_config().unwrap().clients[0].name, "renamed");
        fs::create_dir_all(generated.join("ROUTER/r2")).unwrap();
        let before = fingerprint(root.path());
        for (argv, code) in [
            (&["client", "rename", "--name", "renamed", "--new-name", "r2"][..], "conflict"),
            (&["client", "rename", "--name", "renamed", "--new-name", "my-pc"], "conflict"),
            (&["client", "rename", "--name", "renamed", "--new-name", "../x"], "invalid"),
            (&["client", "rename", "--name", "nobody", "--new-name", "x"], "not_found"),
        ] {
            assert_eq!(run(&mut session, argv, &no_ssh).await.unwrap_err().code, code, "{argv:?}");
        }
        assert_eq!(run(&mut session, &["client", "rename", "--name", "renamed", "--new-name", "renamed"], &no_ssh).await.unwrap(),
            json!({"name": "renamed"}));
        assert_eq!(fingerprint(root.path()), before);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn rename_with_amneziawg_is_gated_and_a_failed_removal_is_partial() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _, generated) = setup(root.path(), with_awg(config()));
        let before = fingerprint(root.path());
        let argv = ["client", "rename", "--name", "my-router", "--new-name", "r3"];
        let error = run(&mut session, &argv, &no_ssh).await.unwrap_err();
        assert_eq!((error.code, error.exit), ("confirmation_required", 2));
        assert_eq!(error.extra["plan"], json!(["Клиент: my-router → r3", "Клиент AmneziaWG «my-router» будет удалён на нодах:",
            " ru-vps  5.6.7.8:2222", "Клиент AmneziaWG «r3» будет создан при следующей генерации конфигов."]));
        assert_eq!(fingerprint(root.path()), before);
        let failing = || FakeTransport::default();
        let error = run(&mut session, &[&argv[..], &["--yes"]].concat(), &failing).await.unwrap_err();
        assert_eq!(error.code, "partial");
        assert_eq!((error.extra["name"].clone(), error.extra["nodes"].clone()), (json!("r3"), json!(["ru-vps"])));
        assert_eq!(session.state.load_config().unwrap().clients[0].name, "r3");
        assert!(generated.join("ROUTER/r3/config.yaml").is_file());
    }

    #[test]
    fn rename_rechecks_the_plan_under_the_lock() {
        let root = tempfile::tempdir().unwrap();
        let (session, _, _) = setup(root.path(), config());
        let invocation = invocation(&["client", "rename", "--name", "my-router", "--new-name", "r3", "--yes"]);
        let planned = rename_plan(&session.state, &config(), "my-router", "r3").unwrap();
        assert!(planned.lines.is_empty());
        rename_recheck(&session.state, &config(), "my-router", "r3", &planned, &invocation).unwrap();
        // An AmneziaWG client appears meanwhile: the plan now removes it on a node.
        let error = rename_recheck(&session.state, &with_awg(config()), "my-router", "r3", &planned, &invocation).unwrap_err();
        assert_eq!(error.code, "plan_changed");
        assert_eq!(error.extra["plan"].as_array().unwrap().len(), 4);
        assert!(error.extra["plan_token"].is_string());
    }

    #[cfg(unix)]
    #[tokio::test(flavor = "current_thread")]
    async fn a_symlinked_group_directory_is_neither_moved_nor_deleted() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let (mut session, _, generated) = setup(root.path(), config());
        fs::create_dir_all(outside.path().join("my-pc")).unwrap();
        fs::write(outside.path().join("my-pc/config.yaml"), "outside\n").unwrap();
        fs::remove_dir_all(generated.join("PC")).unwrap();
        std::os::unix::fs::symlink(outside.path(), generated.join("PC")).unwrap();
        let before = fingerprint(root.path());
        for argv in [
            &["client", "rename", "--name", "my-pc", "--new-name", "moved-pc"][..],
            &["client", "delete", "--name", "my-pc", "--yes"],
            &["client", "set-group", "--name", "my-pc", "--group", "ROUTER", "--yes"],
        ] {
            assert_eq!(run(&mut session, argv, &no_ssh).await.unwrap_err().code, "invalid", "{argv:?}");
        }
        assert_eq!(fs::read_to_string(outside.path().join("my-pc/config.yaml")).unwrap(), "outside\n");
        assert!(!outside.path().join("moved-pc").exists());
        assert_eq!(fingerprint(root.path()), before);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_group_reviews_the_impact_without_changes() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _, generated) = setup(root.path(), config());
        let before = fingerprint(root.path());
        let error = run(&mut session, &["client", "set-group", "--name", "my-router", "--group", "PC"], &no_ssh).await.unwrap_err();
        assert_eq!((error.code, error.exit), ("confirmation_required", 2));
        assert_eq!(error.extra["plan"], json!([
            "Клиент: my-router", "Группа: ROUTER → PC", "Ноды клиента: ru-vps → de-vps", "Затронутые ноды:",
            " ru-vps  5.6.7.8:2222", " de-vps  1.2.3.4:22", "Старый каталог конфигов (удаляется после генерации нового):",
            format!(" {}", generated.join("ROUTER").join("my-router").display()),
            "Служба mihomo на затронутых нодах может быть перезапущена.",
        ]));
        for (argv, code) in [
            (&["client", "set-group", "--name", "my-router", "--group", "ROUTER"][..], "invalid"),
            (&["client", "set-group", "--name", "my-router", "--group", "NOPE"], "not_found"),
            (&["client", "set-group", "--name", "nobody", "--group", "PC"], "not_found"),
        ] {
            assert_eq!(run(&mut session, argv, &no_ssh).await.unwrap_err().code, code, "{argv:?}");
        }
        assert_eq!(fingerprint(root.path()), before);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_group_review_lists_subscription_header_and_amneziawg_changes() {
        let root = tempfile::tempdir().unwrap();
        let mut config = with_awg(published(config()));
        let header = |name: &str, value: &str| SubscriptionHeader { name: name.into(), value: value.into() };
        config.subscription_default_headers = Some(vec![header("profile-update-interval", "24")]);
        config.groups[0].subscription_headers = Some(vec![header("X-Old", "o")]);
        config.groups[1].subscription_headers = Some(vec![header("profile-update-interval", "6")]);
        config.groups[1].template = "alt.yaml".into();
        let (mut session, _, _) = setup(root.path(), config);
        let before = fingerprint(root.path());
        let error = run(&mut session, &["client", "set-group", "--name", "my-router", "--group", "PC"], &no_ssh).await.unwrap_err();
        let plan: Vec<String> = serde_json::from_value(error.extra["plan"].clone()).unwrap();
        for line in ["Шаблон: default.yaml → alt.yaml", "Заголовки подписки изменятся:", " profile-update-interval: 24 → 6",
            " - X-Old: o", "Подписка клиента будет обновлена.", "Клиент AmneziaWG «my-router» будет удалён на нодах: ru-vps"] {
            assert!(plan.iter().any(|l| l == line), "{line} in {plan:?}");
        }
        assert!(plan.iter().all(|l| !l.contains(&"a".repeat(64))));
        assert_eq!(fingerprint(root.path()), before);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_group_keeps_the_old_directory_when_the_client_was_not_regenerated() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _, generated) = setup(root.path(), config());
        let stale = generated.join("PC/my-router/config.yaml");
        fs::create_dir_all(stale.parent().unwrap()).unwrap();
        fs::write(&stale, "stale\n").unwrap();
        // Unreachable nodes: the generation fails, the stale file is no proof.
        let error = run(&mut session, &["client", "set-group", "--name", "my-router", "--group", "PC", "--yes"],
            &|| FakeTransport::default()).await.unwrap_err();
        assert_eq!(error.code, "partial");
        assert_eq!(find_client(&session.state.load_config().unwrap(), "my-router").unwrap().group, "PC");
        assert_eq!(fs::read_to_string(generated.join("ROUTER/my-router/config.yaml")).unwrap(), "keep router\n");
        assert_eq!(fs::read_to_string(&stale).unwrap(), "stale\n");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn delete_reviews_every_target_without_remote_or_local_changes() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _, generated) = setup(root.path(), with_awg(published(config())));
        let before = fingerprint(root.path());
        let error = run(&mut session, &["client", "delete", "--name", "my-router", "--name", "my-pc", "--name", "my-pc"], &no_ssh).await.unwrap_err();
        assert_eq!((error.code, error.exit), ("confirmation_required", 2));
        assert_eq!(error.extra["plan"], json!([
            "Клиенты: my-router, my-pc", "Каталоги конфигов:",
            format!(" my-router: {}", generated.join("ROUTER").join("my-router").display()),
            format!(" my-pc: {}", generated.join("PC").join("my-pc").display()),
            "Затронутые ноды:", " ru-vps  5.6.7.8:2222", " de-vps  1.2.3.4:22",
            "Клиенты AmneziaWG (my-router, my-pc) удаляются на нодах:", " ru-vps",
            "Подписки: my-router", "Хост подписок: de-vps",
            "Локальные записи и сгенерированные конфиги будут удалены.", "Подписки будут отозваны.",
            "Клиенты AmneziaWG будут удалены; доступ в mihomo будет убран.", "Служба mihomo на затронутых нодах будет перезапущена.",
        ]));
        assert!(!serde_json::to_string(&error.extra).unwrap().contains(&"a".repeat(64)));
        assert_eq!(run(&mut session, &["client", "delete", "--name", ""], &no_ssh).await.unwrap_err().code, "usage");
        assert_eq!(run(&mut session, &["client", "delete", "--name", "nobody", "--yes"], &no_ssh).await.unwrap_err().code, "not_found");
        assert_eq!(fingerprint(root.path()), before);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_failed_amneziawg_removal_keeps_local_clients() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _, generated) = setup(root.path(), with_awg(config()));
        let before = fingerprint(root.path());
        let error = run(&mut session, &["client", "delete", "--name", "my-router", "--yes"], &|| FakeTransport::default()).await.unwrap_err();
        assert_eq!(error.code, "remote_failed");
        assert_eq!((error.extra["deleted"].clone(), error.extra["revoked"].clone(), error.extra["awg_nodes"].clone()),
            (json!([]), json!([]), json!([])));
        assert_eq!(fingerprint(root.path()), before);
        assert!(generated.join("ROUTER/my-router/config.yaml").is_file());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn delete_without_server_access_removes_records_and_directories() {
        let root = tempfile::tempdir().unwrap();
        let mut config = config();
        config.connections.clear();
        config.clients[1].nodes = Some(vec![]);
        config.clients[1].connections = None;
        config.groups.push(crate::model::Group { name: "SPARE".into(), ..crate::model::Group::default() });
        config.connections.push(crate::model::Connection { node: "de-vps".into(), groups: vec![
            ConnectionGroup { name: "SPARE".into(), proxies: vec!["vless-reality".into()] }] });
        let (mut session, _, generated) = setup(root.path(), config);
        let data = run(&mut session, &["client", "delete", "--name", "my-router", "--name", "my-pc", "--yes"], &no_ssh).await.unwrap();
        assert_eq!(data, json!({"deleted": ["my-router", "my-pc"]}));
        assert!(session.state.load_config().unwrap().clients.is_empty());
        assert!(!generated.join("ROUTER/my-router").exists() && !generated.join("PC/my-pc").exists());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn config_returns_the_generated_text_or_null() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal, generated) = setup(root.path(), config());
        let before = fingerprint(root.path());
        assert_eq!(run(&mut session, &["client", "config", "--name", "my-pc"], &no_ssh).await.unwrap(),
            json!({"name": "my-pc", "group": "PC", "exists": true, "content": "keep pc\n"}));
        fs::remove_file(generated.join("ROUTER/my-router/config.yaml")).unwrap();
        assert_eq!(run(&mut session, &["client", "config", "--name", "my-router"], &no_ssh).await.unwrap(),
            json!({"name": "my-router", "group": "ROUTER", "exists": false, "content": null}));
        fs::write(generated.join("PC/my-pc/config.yaml"), [0xff, 0xfe]).unwrap();
        let error = run(&mut session, &["client", "config", "--name", "my-pc"], &no_ssh).await.unwrap_err();
        assert_eq!((error.code, error.message.as_str()), ("invalid", "Конфиг клиента «my-pc» не в кодировке UTF-8."));
        for (argv, code) in [(&["client", "config", "--name", "ghost"][..], "not_found"), (&["client", "config"], "usage")] {
            assert_eq!(run(&mut session, argv, &no_ssh).await.unwrap_err().code, code, "{argv:?}");
        }
        assert!(journal.borrow().is_empty(), "the config text never reaches the journal");
        let mut after = fingerprint(root.path());
        after.remove("generated/ROUTER/my-router/config.yaml");
        after.remove("generated/PC/my-pc/config.yaml");
        let mut expected = before;
        expected.remove("generated/ROUTER/my-router/config.yaml");
        expected.remove("generated/PC/my-pc/config.yaml");
        assert_eq!(after, expected, "reading the config changes nothing");
    }
}
