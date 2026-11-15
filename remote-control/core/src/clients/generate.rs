//! `generate --all | --group G | --client C` (port of `generate.sh`): every
//! node's client proxies are rendered from its profile (`render::client_section`,
//! no SSH), per-client `config.yaml` files are rendered from the group
//! template into `<data dir>/generated/<group>/<client>/`. Configs are
//! replaced atomically and only after every proxy was resolved, so a node
//! without a usable profile never leaves a client with a partial config.
//! Server-side listener users follow with `node apply`.

use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::cli::Invocation;
use crate::clients::{client_nodes, find_client, find_group, group_nodes, require_one, templates};
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::locking::LockKind;
use crate::log::Level;
use crate::model::{Client, Config};
use crate::nodes::required;
use crate::secure_fs;
use crate::state::StatePaths;
use crate::validation;

/// Display name of a client's AmneziaWG proxy in its config.
const AWG_DISPLAY: &str = "  - name: \"AmneziaWG 3.1\"";
const NAME_PREFIX: &str = "  - name:";
/// v1 `$GENERATED_DIR`: rendered client configs, local to this device.
pub fn generated_dir(paths: &StatePaths) -> PathBuf {
    paths.root().join("generated")
}

/// A group or client name usable as one path component under `generated/`.
pub fn generated_name_valid(name: &str) -> bool {
    validation::name_valid(name)
}

/// `generated/<group>/<client>/config.yaml` of a client (no IO).
pub fn client_config_path(paths: &StatePaths, client: &Client) -> Result<PathBuf> {
    if !generated_name_valid(&client.name) || !generated_name_valid(&client.group) {
        return Err(RcError::new("invalid", format!(
            "Недопустимое имя клиента «{}» или его группы в конфигурации.", client.name)).with_extra("name", client.name.clone()));
    }
    Ok(generated_dir(paths).join(&client.group).join(&client.name).join("config.yaml"))
}

/// The client's generated config file: a regular file reached through real
/// directories. `None` when absent.
pub fn config_file(paths: &StatePaths, client: &Client) -> Result<Option<Vec<u8>>> {
    let path = client_config_path(paths, client)?;
    let mut dir = generated_dir(paths);
    for part in [client.group.as_str(), client.name.as_str()] {
        if !real_dir(&dir, false)? {
            return Ok(None);
        }
        dir.push(part);
    }
    if !real_dir(&dir, false)? {
        return Ok(None);
    }
    match std::fs::symlink_metadata(&path) {
        Ok(meta) if meta.is_file() => {}
        Ok(_) => return Ok(None),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    }
    Ok(Some(std::fs::read(&path)?))
}

/// The client's rendered config when it is ready to publish: `config_file`
/// with at least one non-blank byte (v1 `_subscription_config_ready`).
/// `None` when absent or blank.
pub fn rendered_config(paths: &StatePaths, client: &Client) -> Result<Option<Vec<u8>>> {
    Ok(config_file(paths, client)?.filter(|bytes| has_content(bytes)))
}

/// `[^[:space:]]` in the C locale.
fn has_content(bytes: &[u8]) -> bool {
    bytes.iter().any(|b| !matches!(b, b' ' | b'\t' | b'\n' | b'\r' | 0x0b | 0x0c))
}

/// `true` when `path` is a directory that is not a symlink; with `create` a
/// missing one is created owner-only. Anything else at the path is refused.
fn real_dir(path: &Path, create: bool) -> io::Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.is_dir() => Ok(true),
        Ok(_) if create => Err(io::Error::new(io::ErrorKind::AlreadyExists, "not a directory")),
        Ok(_) => Ok(false),
        Err(error) if error.kind() == io::ErrorKind::NotFound && create => {
            match secure_fs::create_dir(path) {
                Ok(()) => Ok(true),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => real_dir(path, false),
                Err(error) => Err(error),
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

/// Atomic, owner-only `generated/<group>/<client>/config.yaml`; every
/// directory on the way must be a real directory inside the data dir.
fn write_config(paths: &StatePaths, group: &str, client: &str, bytes: &[u8]) -> io::Result<()> {
    let mut dir = generated_dir(paths);
    real_dir(&dir, true)?;
    for part in [group, client] {
        dir.push(part);
        real_dir(&dir, true)?;
    }
    secure_fs::atomic_write(&dir.join("config.yaml"), bytes)
}

/// Outcome lists of one generation (v1 `GENERATE_*`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Report {
    pub ok: Vec<String>,
    pub skipped: Vec<String>,
    pub failed: Vec<String>,
    pub nodes_ok: Vec<String>,
    pub nodes_failed: Vec<String>,
    /// Nodes whose server state lags behind (`node apply` needed).
    pub nodes_pending: Vec<String>,
}

impl Report {
    fn fields(&self, dir: &Path) -> [(&'static str, Value); 7] {
        [
            ("ok", json!(self.ok)),
            ("skipped", json!(self.skipped)),
            ("failed", json!(self.failed)),
            ("nodes_ok", json!(self.nodes_ok)),
            ("nodes_failed", json!(self.nodes_failed)),
            ("nodes_pending", json!(self.nodes_pending)),
            ("dir", json!(dir.to_string_lossy())),
        ]
    }

    /// No client and no node failed (skips and pending nodes are not failures).
    pub fn complete(&self) -> bool {
        self.failed.is_empty() && self.nodes_failed.is_empty()
    }

    /// Success data, or `partial` carrying the same fields when any client
    /// or node failed (skips are not failures).
    fn finish(&self, dir: &Path) -> Result<Value> {
        if self.complete() {
            return Ok(Value::Object(self.fields(dir).into_iter().map(|(k, v)| (k.to_owned(), v)).collect()));
        }
        Err(self.fields(dir).into_iter()
            .fold(RcError::new("partial", "Генерация завершена с ошибками."), |error, (k, v)| error.with_extra(k, v)))
    }
}

/// What one operation generates and which nodes it renders.
struct Scope {
    /// `(group, only this client)` in generation order.
    targets: Vec<(String, Option<String>)>,
    nodes: Vec<String>,
}

fn push_unique(list: &mut Vec<String>, items: impl IntoIterator<Item = String>) {
    for item in items {
        if !item.is_empty() && !list.contains(&item) {
            list.push(item);
        }
    }
}

fn group_members<'a>(config: &'a Config, group: &str) -> Vec<&'a Client> {
    config.clients.iter().filter(|client| client.group == group).collect()
}

/// Group nodes plus the own nodes of its clients that do not inherit.
fn group_scope_nodes(config: &Config, group: &str) -> Vec<String> {
    let mut nodes = Vec::new();
    push_unique(&mut nodes, group_nodes(config, group));
    for client in group_members(config, group).into_iter().filter(|client| !client.inherit_nodes_from_group) {
        push_unique(&mut nodes, client.nodes.clone().unwrap_or_default());
    }
    nodes
}

/// A node may have several entries (client-owned or group connections): the
/// union of their proxies, each once in order of first mention — a repeat
/// would put the same proxy block into the client config twice.
fn own_connections(client: &Client, node: &str) -> Vec<String> {
    let mut proxies = Vec::new();
    push_unique(&mut proxies, client.connections.iter().flatten().filter(|c| c.node == node).flat_map(|c| c.proxies.iter().cloned()));
    proxies
}

pub(crate) fn group_connections(config: &Config, group: &str, node: &str) -> Vec<String> {
    let mut proxies = Vec::new();
    push_unique(&mut proxies, config.connections.iter().filter(|c| c.node == node)
        .flat_map(|c| c.groups.iter().filter(|g| g.name == group))
        .flat_map(|g| g.proxies.iter().cloned()));
    proxies
}

/// Connections a client uses on a node: its own when set, else its group's.
pub(crate) fn effective_connections(config: &Config, client: &Client, node: &str) -> Vec<String> {
    let own = own_connections(client, node);
    if own.is_empty() { group_connections(config, &client.group, node) } else { own }
}

/// A client assigned to a node with its credentials for the node's listeners.
pub(crate) struct User<'a> {
    pub client: &'a Client,
    pub name: &'a str,
    pub uuid: &'a str,
    pub password: &'a str,
}

/// Clients assigned to a node (via their group or own nodes) with credentials
/// for its listeners; `None` when any name or credential is invalid.
pub(crate) fn node_users<'a>(config: &'a Config, node: &str) -> Option<Vec<User<'a>>> {
    let mut users = Vec::new();
    for client in &config.clients {
        let assigned = if client.inherit_nodes_from_group {
            config.connections.iter().any(|c| c.node == node && c.groups.iter().any(|g| g.name == client.group))
        } else {
            client.nodes.iter().flatten().any(|n| n == node)
        };
        if !assigned {
            continue;
        }
        let (uuid, password) = client.credentials.as_ref()
            .map_or(("", ""), |c| (c.vless_uuid.as_str(), c.hy2_password.as_str()));
        if !generated_name_valid(&client.name) || (!uuid.is_empty() && !validation::vless_uuid_valid(uuid))
            || (!password.is_empty() && !validation::hy2_password_valid(password)) {
            return None;
        }
        users.push(User { client, name: &client.name, uuid, password });
    }
    Some(users)
}

/// Command substitution: trailing newlines go.
fn trim_newlines(text: &str) -> &str {
    text.trim_end_matches('\n')
}

/// Proxy lines of the `proxies:` … `---` sections of a node config; unquoted
/// names are quoted. CR line endings are dropped.
fn proxy_section(remote: &str) -> String {
    let mut lines = Vec::new();
    let mut inside = false;
    for line in remote.split('\n').map(|line| line.strip_suffix('\r').unwrap_or(line)) {
        if !inside {
            inside = line.starts_with("proxies:");
            continue;
        }
        if line.starts_with("---") {
            inside = false;
            continue;
        }
        if line.starts_with("proxies:") {
            continue;
        }
        match line.strip_prefix("  - name: ") {
            Some(rest) if !rest.is_empty() && !rest.starts_with('"') => lines.push(format!("  - name: \"{rest}\"")),
            _ => lines.push(line.to_owned()),
        }
    }
    trim_newlines(&lines.join("\n")).to_owned()
}

/// Proxy name of a `  - name:` line without quotes and trailing spaces.
fn block_name(line: &str) -> &str {
    let name = line[NAME_PREFIX.len()..].trim_start_matches(' ');
    let name = name.strip_prefix('"').unwrap_or(name);
    let name = name.trim_end_matches(' ');
    name.strip_suffix('"').unwrap_or(name)
}

/// Every proxy block named `name`, each up to the next `  - name:` line.
fn select_blocks(section: &str, name: &str) -> String {
    let (mut blocks, mut buffer, mut found) = (Vec::new(), String::new(), false);
    for line in section.split('\n') {
        if line.starts_with(NAME_PREFIX) {
            if found {
                blocks.push(std::mem::take(&mut buffer));
            }
            buffer = line.to_owned();
            found = block_name(line) == name;
        } else if !buffer.is_empty() {
            buffer.push('\n');
            buffer.push_str(line);
        }
    }
    if found {
        blocks.push(buffer);
    }
    trim_newlines(&blocks.join("\n")).to_owned()
}

/// v1 `_yaml_set_field`: a line containing `    FIELD: ` keeps its text
/// before the first occurrence and ends with `    FIELD: VALUE`.
fn set_field(block: &str, field: &str, value: &str) -> String {
    let key = format!("    {field}: ");
    block.split('\n').map(|line| match line.find(&key) {
        Some(at) => format!("{}{key}{value}", &line[..at]),
        None => line.to_owned(),
    }).collect::<Vec<_>>().join("\n")
}

fn proxy_type(block: &str) -> Option<&str> {
    block.split('\n').find(|line| line.contains("    type:")).and_then(|line| line.split_whitespace().nth(1))
}

/// Proxies of one client from the nodes' client sections (v1
/// `_fetch_proxies_for_client`): allowed connections, client credentials,
/// AmneziaWG display name, aliases and tag. `None` when a node section is
/// missing, a selected connection (an AmneziaWG peer included) is not in its
/// node's section or credentials are missing or invalid.
fn client_proxies(config: &Config, client: &Client, nodes: &[String], sections: &BTreeMap<String, String>,
    log: &mut dyn FnMut(Level, &str)) -> Option<String>
{
    let name = client.name.as_str();
    let (uuid, password) = client.credentials.as_ref()
        .map_or(("", ""), |c| (c.vless_uuid.as_str(), c.hy2_password.as_str()));
    if uuid.is_empty() || password.is_empty() {
        log(Level::Warn, &format!("{name}: нет учётных данных клиента — назначьте ноде профиль заново (node profile), чтобы их создать"));
        return None;
    }
    if !validation::vless_uuid_valid(uuid) || !validation::hy2_password_valid(password) {
        log(Level::Warn, &format!("{name}: недопустимые учётные данные в конфигурации"));
        return None;
    }
    let mut complete = true;
    let mut all = String::new();
    for node_name in nodes {
        let own = own_connections(client, node_name);
        let group = group_connections(config, &client.group, node_name);
        if !own.is_empty() && !group.is_empty() {
            for proxy in own.iter().filter(|proxy| !group.contains(proxy)) {
                log(Level::Warn, &format!("{name}: подключение «{proxy}» на {node_name} отсутствует в группе {}", client.group));
            }
        }
        let Some(remote) = sections.get(node_name) else {
            complete = false;
            continue;
        };
        let section = proxy_section(remote);
        // Without connections on the node the client takes every proxy of the
        // section, as the node's listeners accept it on all of them.
        let selected = !own.is_empty() || !group.is_empty();
        let allowed = if !own.is_empty() {
            own
        } else if selected {
            group
        } else {
            let mut every = Vec::new();
            push_unique(&mut every, section.split('\n').filter(|line| line.starts_with(NAME_PREFIX)).map(|line| block_name(line).to_owned()));
            every
        };
        let mut filtered = String::new();
        for connection in &allowed {
            let awg = connection == "AWG";
            let target = if awg { format!("awg-{name}") } else { connection.clone() };
            let mut block = select_blocks(&section, &target);
            if block.is_empty() {
                if selected {
                    log(Level::Warn, &format!("{name}: подключения «{connection}» нет в профиле ноды {node_name} — выполните conn sync или измените назначение"));
                    complete = false;
                }
                continue;
            }
            let kind = proxy_type(&block).map(str::to_owned);
            match kind.as_deref() {
                Some("vless") => {
                    block = set_field(&block, "uuid", uuid);
                    block = trim_newlines(&crate::protocols::vless_xhttp::normalize_proxy_yaml(&block)).to_owned();
                }
                Some("hysteria2") => block = set_field(&block, "password", password),
                _ => {}
            }
            if awg {
                block = match block.split_once('\n') {
                    Some((_, rest)) => format!("{AWG_DISPLAY}\n{}", trim_newlines(rest)),
                    None => format!("{AWG_DISPLAY}\n"),
                };
            }
            filtered.push_str(&block);
            filtered.push('\n');
        }
        let mut section = filtered;
        if section.is_empty() {
            continue;
        }
        if let Some(node) = config.nodes.iter().find(|node| node.name == *node_name) {
            for (original, alias) in &node.aliases {
                section = section.replace(&format!("{NAME_PREFIX} \"{original}\""), &format!("{NAME_PREFIX} \"{alias}\""));
            }
            if let Some(tag) = node.tag.as_deref().filter(|tag| !tag.is_empty()) {
                section = section.replace(&format!("{NAME_PREFIX} \""), &format!("{NAME_PREFIX} \"{tag} "));
            }
        }
        all.push_str(&section);
        all.push('\n');
    }
    complete.then(|| spaced(&all))
}

/// One blank line before every proxy but the first (v1 awk spacing).
fn spaced(all: &str) -> String {
    if all.is_empty() {
        return String::new();
    }
    let mut lines = Vec::new();
    for (index, line) in all.split('\n').enumerate() {
        if index > 0 && line.starts_with(NAME_PREFIX) {
            lines.push("");
        }
        lines.push(line);
    }
    trim_newlines(&lines.join("\n")).to_owned()
}

/// Sorted proxy names that occur more than once.
fn duplicate_names(entries: &str) -> Vec<&str> {
    let mut seen = BTreeMap::<&str, usize>::new();
    for line in entries.split('\n') {
        if let Some(name) = line.strip_prefix("  - name: \"").and_then(|rest| rest.strip_suffix('"')).filter(|n| !n.contains('"')) {
            *seen.entry(name).or_default() += 1;
        }
    }
    seen.into_iter().filter(|(_, count)| *count > 1).map(|(name, _)| name).collect()
}

/// The processed template with the proxies after each `proxies:` line;
/// `None` when there are proxies but no anchor.
fn render(processed: &str, entries: &str) -> Option<String> {
    let mut out = String::new();
    let mut anchored = false;
    for line in processed.split('\n') {
        out.push_str(line);
        out.push('\n');
        if line == "proxies:" {
            anchored = true;
            if !entries.is_empty() {
                out.push_str(entries);
                out.push('\n');
            }
        }
    }
    (entries.is_empty() || anchored).then_some(out)
}

/// `cat -s`: runs of empty lines become one.
fn squeeze_blank(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut previous_blank = false;
    for line in text.split_inclusive('\n') {
        let blank = line == "\n";
        if !(blank && previous_blank) {
            out.push_str(line);
        }
        previous_blank = blank;
    }
    out
}

/// Render the configs of `group` (only `only` when given) from the node sections.
fn generate_group(session: &mut Session, config: &Config, group: &str, only: Option<&str>, sections: &BTreeMap<String, String>,
    report: &mut Report)
{
    let members: Vec<&Client> = group_members(config, group).into_iter()
        .filter(|client| only.is_none_or(|only| client.name == only)).collect();
    let names = || members.iter().map(|client| client.name.clone());
    if !generated_name_valid(group) {
        session.log(Level::Warn, &format!("Недопустимое имя группы «{group}» в конфигурации — конфиги группы не сгенерированы."));
        report.failed.extend(names());
        return;
    }
    let template_name = templates::group_template(config, group);
    let template = match templates::resolve(&session.state, &template_name) {
        Ok(Some(template)) => template,
        Ok(None) => {
            let dir = session.state.paths().templates().display().to_string();
            session.log(Level::Warn, &format!("Шаблон «{template_name}» не найден для группы {group}. Поместите файл в {dir}/"));
            report.skipped.extend(names());
            return;
        }
        Err(error) => {
            session.log(Level::Warn, &format!("Шаблон «{template_name}» группы {group} не прочитан: {}", error.message));
            report.failed.extend(names());
            return;
        }
    };
    if members.is_empty() {
        match only {
            Some(only) => session.log(Level::Warn, &format!("Клиент {only} не найден в группе {group} — пропускаю.")),
            None => session.log(Level::Warn, &format!("В группе {group} нет клиентов — пропускаю.")),
        }
        return;
    }
    session.log(Level::Info, &format!("Группа {group} ({template_name})..."));
    let processed = templates::process(&template.content, group);
    let processed = trim_newlines(&processed);
    let inherited = group_nodes(config, group);
    for client in members {
        let name = client.name.as_str();
        if !generated_name_valid(name) {
            session.log(Level::Warn, &format!("Недопустимое имя клиента «{name}» в конфигурации — config.yaml не сгенерирован"));
            report.failed.push(name.to_owned());
            continue;
        }
        let nodes = if client.inherit_nodes_from_group { inherited.clone() } else { client.nodes.clone().unwrap_or_default() };
        let entries = if nodes.is_empty() {
            Some(String::new())
        } else {
            client_proxies(config, client, &nodes, sections, &mut |level, text| session.log(level, text))
        };
        let Some(entries) = entries else {
            session.log(Level::Warn, &format!("{name} — не удалось получить все подключения; конфиг сохранён без изменений"));
            report.failed.push(name.to_owned());
            continue;
        };
        let duplicates = duplicate_names(&entries);
        if !duplicates.is_empty() {
            session.log(Level::Warn, &format!("{name}: повторяющиеся имена прокси:"));
            for duplicate in duplicates {
                session.log(Level::Warn, &format!("  «{duplicate}» — задайте псевдоним через «Подключения» → «Переименовать»"));
            }
            session.log(Level::Warn, &format!("{name} — пропущен (повторяющиеся имена прокси)"));
            report.skipped.push(name.to_owned());
            continue;
        }
        let text = render(processed, &entries).map(|rendered| squeeze_blank(&format!("{}\n", trim_newlines(&rendered))));
        let written = text.filter(|text| has_content(text.as_bytes()))
            .is_some_and(|text| write_config(session.state.paths(), group, name, text.as_bytes()).is_ok());
        if !written {
            session.log(Level::Warn, &format!("{name} — config.yaml не сгенерирован"));
            report.failed.push(name.to_owned());
            continue;
        }
        report.ok.push(name.to_owned());
        session.log(Level::Success, &format!("{name} — сгенерирован"));
    }
}

/// Render the client sections of `scope.nodes`, then the configs of every
/// target group. A node without a usable profile fails its clients; a node
/// whose server state lags behind is reported as pending.
fn run(session: &mut Session, config: &Config, scope: Scope) -> Report {
    let mut sections = BTreeMap::new();
    let mut report = Report::default();
    for name in &scope.nodes {
        let Some(node) = config.nodes.iter().find(|node| node.name == *name) else {
            session.log(Level::Warn, &format!("Не удалось загрузить ноду «{name}»."));
            report.nodes_failed.push(name.clone());
            continue;
        };
        match crate::server::render::client_section(config, node) {
            Some(section) => {
                sections.insert(name.clone(), section);
                report.nodes_ok.push(name.clone());
            }
            None => {
                session.log(Level::Warn, &format!("{name}: профиль не готов (нет профиля, домена или ключей)"));
                report.nodes_failed.push(name.clone());
            }
        }
        if node.profile.is_some() && crate::server::render::status(config, node) != "applied" {
            session.log(Level::Warn, &format!("{name}: есть неприменённые изменения — выполните node apply"));
            report.nodes_pending.push(name.clone());
        }
    }
    for (group, only) in &scope.targets {
        generate_group(session, config, group, only.as_deref(), &sections, &mut report);
    }
    report
}

/// `generate (--all | --group G | --client C)`.
pub fn generate(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    require_one(invocation, &["all", "group", "client"])?;
    let config = session.state.load_config()?;
    let scope = if invocation.has("all") {
        let mut scope = Scope { targets: Vec::new(), nodes: Vec::new() };
        for group in &config.groups {
            scope.targets.push((group.name.clone(), None));
            push_unique(&mut scope.nodes, group_scope_nodes(&config, &group.name));
        }
        scope
    } else if invocation.has("group") {
        let group = required(invocation, "group")?;
        find_group(&config, group)?;
        Scope { targets: vec![(group.to_owned(), None)], nodes: group_scope_nodes(&config, group) }
    } else {
        let name = required(invocation, "client")?;
        let client = find_client(&config, name)?;
        let mut nodes = Vec::new();
        push_unique(&mut nodes, client_nodes(&config, client));
        Scope { targets: vec![(client.group.clone(), Some(name.to_owned()))], nodes }
    };
    let dir = generated_dir(session.state.paths());
    if scope.targets.is_empty() {
        session.log(Level::Warn, "Нет групп.");
        return Report::default().finish(&dir);
    }
    let _guard = session.state.locks().acquire(LockKind::Mutation, "generate")?;
    run(session, &config, scope).finish(&dir)
}

/// Regenerate `group` after a client changed groups (v1 set-group flow).
/// Client and node failures are in the report; `Err` only when nothing ran.
pub fn regenerate_group(session: &mut Session, group: &str) -> Result<Report> {
    let config = session.state.load_config()?;
    let _guard = session.state.locks().acquire(LockKind::Mutation, "generate")?;
    let scope = Scope { targets: vec![(group.to_owned(), None)], nodes: group_scope_nodes(&config, group) };
    Ok(run(session, &config, scope))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{
        Applied, ClientConnection, ClientCredentials, Connection, ConnectionGroup, Group, Hysteria2, Node, NodeParams,
        NodeReality, PortOnly, Profile, Xhttp, XhttpTopology,
    };
    use crate::nodes::testing::{Journal, fingerprint, invocation, session};

    const SAMPLE: &str = "proxies:\n  - name: \"vless-reality\"\n    type: vless\n    server: 1.2.3.4\n    port: 443\n\
        \x20   uuid: \"test-uuid-1234\"\n    network: tcp\n    tls: true\n    servername: example.com\n\n\
        \x20 - name: \"hy2-main\"\n    type: hysteria2\n    server: 1.2.3.4\n    port: 8443\n    password: \"testpass\"\n\n\
        \x20 - name: \"awg-my-router\"\n    type: wireguard\n    server: 1.2.3.4\n    port: 51820\n\n\
        ---\nproxy-groups:\n  - name: auto\n    type: url-test\n";
    const TEMPLATE: &str = "mixed-port: 7890\n\nproxies:\n\n\n# --- PC ---\npc-only: true\n# --- PC ---\nproxy-groups: []\n";
    const ROUTER_UUID: &str = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    const PC_UUID: &str = "11111111-2222-3333-4444-555555555555";

    fn client(name: &str, group: &str, own: Option<(&str, &[&str])>, uuid: &str, password: &str) -> Client {
        Client {
            name: name.into(), group: group.into(), inherit_nodes_from_group: own.is_none(),
            nodes: own.map(|(node, _)| vec![node.into()]),
            connections: own.map(|(node, proxies)| vec![ClientConnection { node: node.into(), proxies: proxies.iter().map(|p| p.to_string()).collect() }]),
            credentials: Some(ClientCredentials { vless_uuid: uuid.into(), hy2_password: password.into(), ..ClientCredentials::default() }),
            ..Client::default()
        }
    }

    fn connection(node: &str, groups: &[(&str, &[&str])]) -> Connection {
        Connection { node: node.into(), groups: groups.iter().map(|(name, proxies)| ConnectionGroup {
            name: (*name).into(), proxies: proxies.iter().map(|p| p.to_string()).collect() }).collect() }
    }

    /// A self-steal node with every VLESS transport and Hysteria2.
    fn profiled(index: u8, name: &str, tag: &str) -> Node {
        Node {
            id: format!("{index:032x}"), name: name.into(), ip: format!("198.51.100.{index}"), port: 22, user: "root".into(),
            tag: Some(tag.into()), profile: Some("full".into()), domain: Some(format!("{name}.example.com")),
            params: NodeParams {
                reality: Some(NodeReality { public_key: "P".repeat(43), short_id: "0123456789abcdef".into() }),
                xhttp_path: Some("/0123456789abcdef".into()), grpc_service: Some("grpc-01234567".into()),
                ..NodeParams::default()
            },
            ..Node::default()
        }
    }

    /// de (tag DE) and ru (alias VLESS TCP → RU-VLESS); ROUTER on both, PC on
    /// de; my-router inherits ROUTER, my-pc owns de with VLESS TCP only.
    fn fixture(root: &Path) -> (Session, Journal) {
        let (session, journal) = session(root);
        let de = profiled(1, "de", "DE");
        let mut ru = profiled(2, "ru", "");
        ru.aliases.insert("VLESS TCP".into(), "RU-VLESS".into());
        let all: &[&str] = &["VLESS TCP", "VLESS xHTTP", "VLESS gRPC", "Hysteria2"];
        let config = Config {
            profiles: vec![Profile {
                name: "full".into(), mihomo_version: "v1.19.18".into(), acme_email: "admin@example.com".into(),
                vless_tcp: true, vless_xhttp: Some(Xhttp { topology: XhttpTopology::Nginx, port: None }),
                vless_grpc: Some(PortOnly { port: 2053 }), hysteria2: Some(Hysteria2 { port: 8843, obfs: false }),
                ..Profile::default()
            }],
            nodes: vec![de, ru],
            groups: vec![Group { name: "ROUTER".into(), template: "t.yaml".into(), ..Group::default() },
                Group { name: "PC".into(), template: "t.yaml".into(), ..Group::default() }],
            clients: vec![client("my-router", "ROUTER", None, ROUTER_UUID, "router-hy2-pass-0001"),
                client("my-pc", "PC", Some(("de", &["VLESS TCP"])), PC_UUID, "pc-hy2-pass-0002")],
            connections: vec![connection("de", &[("ROUTER", all), ("PC", all)]), connection("ru", &[("ROUTER", &["VLESS TCP"])])],
            ..Config::default()
        };
        session.state.save_config(&config).unwrap();
        std::fs::create_dir_all(session.state.paths().templates()).unwrap();
        std::fs::write(session.state.paths().templates().join("t.yaml"), TEMPLATE).unwrap();
        (session, journal)
    }

    fn fetched(configs: &[(&str, &str)]) -> BTreeMap<String, String> {
        configs.iter().map(|(n, c)| (n.to_string(), c.to_string())).collect()
    }

    fn proxies(config: &Config, client: &str, nodes: &[&str], fetched: &BTreeMap<String, String>) -> (Option<String>, Vec<String>) {
        let client = config.clients.iter().find(|c| c.name == client).unwrap();
        let mut log = Vec::new();
        let nodes: Vec<String> = nodes.iter().map(|n| n.to_string()).collect();
        let out = client_proxies(config, client, &nodes, fetched, &mut |_, text| log.push(text.to_owned()));
        (out, log)
    }

    #[test]
    fn proxies_follow_connections_credentials_aliases_and_tags() {
        let root = tempfile::tempdir().unwrap();
        let (session, _) = fixture(root.path());
        let mut config = session.state.load_config().unwrap();
        config.connections = vec![connection("de", &[("ROUTER", &["vless-reality", "hy2-main"])]), connection("ru", &[("ROUTER", &["vless-reality"])])];
        config.nodes[1].aliases = [("vless-reality".to_owned(), "RU-VLESS".to_owned())].into();
        let cache = fetched(&[("de", SAMPLE), ("ru", &SAMPLE.replace('\n', "\r\n"))]);

        let (router, _) = proxies(&config, "my-router", &["de", "ru"], &cache);
        assert_eq!(router.unwrap(), format!("  - name: \"DE vless-reality\"\n    type: vless\n    server: 1.2.3.4\n    port: 443\n\
            \x20   uuid: {ROUTER_UUID}\n    network: tcp\n    tls: true\n    servername: example.com\n\n\
            \x20 - name: \"DE hy2-main\"\n    type: hysteria2\n    server: 1.2.3.4\n    port: 8443\n    password: router-hy2-pass-0001\n\n\n\
            \x20 - name: \"RU-VLESS\"\n    type: vless\n    server: 1.2.3.4\n    port: 443\n\
            \x20   uuid: {ROUTER_UUID}\n    network: tcp\n    tls: true\n    servername: example.com"));

        // A node without a section fails the client.
        assert_eq!(proxies(&config, "my-router", &["de", "ru"], &fetched(&[("de", SAMPLE)])).0, None);

        // xHTTP blocks get the client uuid and the firefox fingerprint.
        let xhttp = "proxies:\n  - name: \"vless-xhttp\"\n    type: vless\n    uuid: original\n    network: xhttp\n    client-fingerprint: chrome\n---\n";
        config.connections[0].groups[0].proxies = vec!["vless-xhttp".into()];
        let (out, _) = proxies(&config, "my-router", &["de"], &fetched(&[("de", xhttp)]));
        let out = out.unwrap();
        assert!(out.contains(&format!("uuid: {ROUTER_UUID}")) && out.contains("client-fingerprint: firefox") && !out.contains("chrome"));
    }

    #[test]
    fn a_proxy_repeated_across_entries_of_a_node_is_used_once() {
        let root = tempfile::tempdir().unwrap();
        let (session, _) = fixture(root.path());
        let mut config = session.state.load_config().unwrap();
        config.connections = vec![connection("de", &[("ROUTER", &["vless-reality", "hy2-main"])])];
        let cache = fetched(&[("de", SAMPLE)]);
        let (single, _) = proxies(&config, "my-router", &["de"], &cache);
        // A second entry of `de` names ROUTER's proxies again (overlapping sets).
        let mut split = config.clone();
        split.connections.push(connection("de", &[("ROUTER", &["hy2-main", "vless-reality"])]));
        split.validate().unwrap();
        assert_eq!(group_connections(&split, "ROUTER", "de"), ["vless-reality", "hy2-main"]);
        let (out, _) = proxies(&split, "my-router", &["de"], &cache);
        assert_eq!(out, single);
        assert!(duplicate_names(&out.unwrap()).is_empty());
    }

    #[test]
    fn awg_proxies_use_the_client_peer() {
        let root = tempfile::tempdir().unwrap();
        let (session, _) = fixture(root.path());
        let mut config = session.state.load_config().unwrap();
        config.connections[0].groups[0].proxies = vec!["AWG".into()];
        let awg = "proxies:\n  - name: \"awg-my-router\"\n    type: wireguard\n    ip: 10.10.8.2\n    amnezia-wg-option:\n      version: 3\n\
            proxies:\n  - name: \"awg-other\"\n    type: wireguard\n    server: 9.9.9.9\n---\n";
        let (out, _) = proxies(&config, "my-router", &["de"], &fetched(&[("de", awg)]));
        let out = out.unwrap();
        assert!(out.contains("  - name: \"DE AmneziaWG 3.1\"\n    type: wireguard\n    ip: 10.10.8.2\n    amnezia-wg-option:\n      version: 3"));
        assert!(!out.contains("9.9.9.9"));
    }

    #[test]
    fn rendering_inserts_after_the_anchor_and_squeezes_blank_lines() {
        assert_eq!(render("a\nproxies:\nb", "  - name: \"x\""), Some("a\nproxies:\n  - name: \"x\"\nb\n".into()));
        assert_eq!(render("a\nb", "  - name: \"x\""), None);
        assert_eq!(render("a", ""), Some("a\n".into()));
        assert_eq!(squeeze_blank("a\n\n\n\nb\n\n"), "a\n\nb\n\n");
        assert_eq!(duplicate_names("  - name: \"b\"\n  - name: \"a\"\n  - name: \"b\"\n  - name: \"a\"\n  - name: \"c\""), ["a", "b"]);
        assert_eq!(proxy_section("x\nproxies:\r\n  - name: plain\r\n---\nproxies:\n  - name: \"q\"\n"), "  - name: \"plain\"\n  - name: \"q\"");
    }

    #[test]
    fn generate_all_renders_every_proxy_from_the_profiles_without_ssh() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = fixture(root.path());
        let config = session.state.load_config().unwrap();
        let data = generate(&mut session, &invocation(&["generate", "--all"])).unwrap();
        let dir = generated_dir(session.state.paths());
        assert_eq!(data, json!({"ok": ["my-router", "my-pc"], "skipped": [], "failed": [], "nodes_ok": ["de", "ru"],
            "nodes_failed": [], "nodes_pending": ["de", "ru"], "dir": dir.to_string_lossy()}));
        assert!(journal.borrow().iter().any(|(_, text)| text == "de: есть неприменённые изменения — выполните node apply"));
        let router = std::fs::read_to_string(dir.join("ROUTER/my-router/config.yaml")).unwrap();
        for proxy in ["DE VLESS TCP", "DE VLESS xHTTP", "DE VLESS gRPC", "DE Hysteria2", "RU-VLESS"] {
            assert!(router.contains(&format!("  - name: \"{proxy}\"\n")), "{proxy} in {router}");
        }
        assert!(router.starts_with("mixed-port: 7890\n\nproxies:\n  - name: \"DE VLESS TCP\"\n    type: vless\n    server: de.example.com\n    port: 443\n"));
        assert_eq!(router.matches(&format!("uuid: {ROUTER_UUID}")).count(), 4);
        assert!(router.contains("    password: router-hy2-pass-0001\n") && !router.contains(crate::server::render::PLACEHOLDER_UUID));
        assert!(!router.contains("placeholder") && router.ends_with("proxy-groups: []\n") && !router.contains("pc-only"));
        assert!(!router.contains("\n\n\n"));
        let pc = std::fs::read_to_string(dir.join("PC/my-pc/config.yaml")).unwrap();
        assert!(pc.contains("pc-only: true\n") && pc.contains(PC_UUID) && !pc.contains("Hysteria2"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(dir.join("PC/my-pc/config.yaml")).unwrap().permissions().mode() & 0o777, 0o600);
        }
        let config_path = client_config_path(session.state.paths(), &config.clients[1]).unwrap();
        assert_eq!(rendered_config(session.state.paths(), &config.clients[1]).unwrap().unwrap(), std::fs::read(&config_path).unwrap());
        std::fs::write(&config_path, " \n\t\n").unwrap();
        assert_eq!(rendered_config(session.state.paths(), &config.clients[1]).unwrap(), None);
        let ghost = Client { name: "ghost".into(), group: "PC".into(), ..Client::default() };
        assert_eq!(rendered_config(session.state.paths(), &ghost).unwrap(), None);
        let invalid = Client { name: "..".into(), group: "PC".into(), ..Client::default() };
        assert_eq!(rendered_config(session.state.paths(), &invalid).unwrap_err().code, "invalid");
    }

    #[test]
    fn applied_nodes_are_not_pending() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = fixture(root.path());
        let mut config = session.state.load_config().unwrap();
        for index in 0..2 {
            let digest = crate::server::render::desired(&config, &config.nodes[index], None).unwrap().digest;
            config.nodes[index].applied = Some(Applied { digest, ..Applied::default() });
        }
        session.state.save_config(&config).unwrap();
        let data = generate(&mut session, &invocation(&["generate", "--group", "ROUTER"])).unwrap();
        assert_eq!(data["nodes_pending"], json!([]));
    }

    #[test]
    fn crlf_template_renders_like_the_lf_one() {
        let mut rendered = Vec::new();
        for template in [TEMPLATE.to_owned(), TEMPLATE.replace('\n', "\r\n")] {
            let root = tempfile::tempdir().unwrap();
            let (mut session, _) = fixture(root.path());
            std::fs::write(session.state.paths().templates().join("t.yaml"), &template).unwrap();
            generate(&mut session, &invocation(&["generate", "--all"])).unwrap();
            let dir = generated_dir(session.state.paths());
            rendered.push(["ROUTER/my-router", "PC/my-pc"].map(|client| std::fs::read_to_string(dir.join(client).join("config.yaml")).unwrap()));
        }
        assert_eq!(rendered[0], rendered[1]);
        assert!(rendered[1][1].contains("proxies:\n  - name: \"DE VLESS TCP\"\n") && rendered[1][1].contains("pc-only: true\n"));
        assert!(!rendered[1].iter().any(|config| config.contains('\r')));
    }

    #[test]
    fn a_node_without_a_usable_profile_fails_its_clients_and_keeps_their_config() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = fixture(root.path());
        let mut config = session.state.load_config().unwrap();
        config.nodes[0].domain = None;
        session.state.save_config(&config).unwrap();
        let previous = generated_dir(session.state.paths()).join("ROUTER/my-router");
        std::fs::create_dir_all(&previous).unwrap();
        std::fs::write(previous.join("config.yaml"), "previous\n").unwrap();
        let error = generate(&mut session, &invocation(&["generate", "--group", "ROUTER"])).unwrap_err();
        assert_eq!((error.code, error.message.as_str(), error.exit_code()), ("partial", "Генерация завершена с ошибками.", 1));
        assert_eq!((error.extra["ok"].clone(), error.extra["failed"].clone()), (json!([]), json!(["my-router"])));
        assert_eq!((error.extra["nodes_ok"].clone(), error.extra["nodes_failed"].clone()), (json!(["ru"]), json!(["de"])));
        assert_eq!(std::fs::read_to_string(previous.join("config.yaml")).unwrap(), "previous\n");
        let journal = journal.borrow();
        assert!(journal.iter().any(|(_, text)| text == "de: профиль не готов (нет профиля, домена или ключей)"));
        assert!(journal.iter().any(|(_, text)| text == "my-router — не удалось получить все подключения; конфиг сохранён без изменений"));
    }

    #[test]
    fn a_selected_connection_missing_from_the_profile_fails_the_client_and_keeps_its_config() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = fixture(root.path());
        let mut config = session.state.load_config().unwrap();
        config.clients[1].connections = Some(vec![ClientConnection { node: "de".into(), proxies: vec!["VLESS TCP".into(), "vless-reality".into()] }]);
        session.state.save_config(&config).unwrap();
        let previous = generated_dir(session.state.paths()).join("PC/my-pc");
        std::fs::create_dir_all(&previous).unwrap();
        std::fs::write(previous.join("config.yaml"), "previous\n").unwrap();
        let error = generate(&mut session, &invocation(&["generate", "--client", "my-pc"])).unwrap_err();
        assert_eq!(error.code, "partial");
        assert_eq!((error.extra["ok"].clone(), error.extra["failed"].clone()), (json!([]), json!(["my-pc"])));
        assert_eq!(std::fs::read_to_string(previous.join("config.yaml")).unwrap(), "previous\n");
        assert!(journal.borrow().iter().any(|(_, text)|
            text == "my-pc: подключения «vless-reality» нет в профиле ноды de — выполните conn sync или измените назначение"));

        // A group-selected connection is checked the same way.
        config.clients[1].connections = None;
        config.clients[1].inherit_nodes_from_group = true;
        config.connections[0].groups[1].proxies = vec!["AWG".into()];
        let (out, log) = proxies(&config, "my-pc", &["de"], &fetched(&[("de", SAMPLE)]));
        assert_eq!(out, None);
        assert_eq!(log, ["my-pc: подключения «AWG» нет в профиле ноды de — выполните conn sync или измените назначение"]);
    }

    #[test]
    fn a_client_without_credentials_fails_and_keeps_its_config() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = fixture(root.path());
        let previous = generated_dir(session.state.paths()).join("PC/my-pc");
        std::fs::create_dir_all(&previous).unwrap();
        std::fs::write(previous.join("config.yaml"), "previous\n").unwrap();
        for credentials in [None, Some(ClientCredentials { vless_uuid: PC_UUID.into(), ..ClientCredentials::default() })] {
            let mut config = session.state.load_config().unwrap();
            config.clients[1].credentials = credentials;
            session.state.save_config(&config).unwrap();
            let error = generate(&mut session, &invocation(&["generate", "--client", "my-pc"])).unwrap_err();
            assert_eq!((error.code, error.extra["ok"].clone(), error.extra["failed"].clone()), ("partial", json!([]), json!(["my-pc"])));
            assert_eq!(std::fs::read_to_string(previous.join("config.yaml")).unwrap(), "previous\n");
        }
        assert!(journal.borrow().iter().any(|(_, text)|
            text == "my-pc: нет учётных данных клиента — назначьте ноде профиль заново (node profile), чтобы их создать"));
    }

    #[test]
    fn a_node_without_connections_gives_every_proxy_with_the_client_credentials() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = fixture(root.path());
        let mut config = session.state.load_config().unwrap();
        config.connections.retain(|connection| connection.node != "de");
        config.clients[1].connections = None;
        session.state.save_config(&config).unwrap();
        let data = generate(&mut session, &invocation(&["generate", "--client", "my-pc"])).unwrap();
        assert_eq!(data["ok"], json!(["my-pc"]));
        let pc = std::fs::read_to_string(generated_dir(session.state.paths()).join("PC/my-pc/config.yaml")).unwrap();
        for proxy in ["DE VLESS TCP", "DE VLESS xHTTP", "DE VLESS gRPC", "DE Hysteria2"] {
            assert!(pc.contains(&format!("  - name: \"{proxy}\"\n")), "{proxy} in {pc}");
        }
        assert_eq!(pc.matches(&format!("uuid: {PC_UUID}")).count(), 3);
        assert!(pc.contains("    password: pc-hy2-pass-0002\n"));
        assert!(!pc.contains(crate::server::render::PLACEHOLDER_UUID) && !pc.contains(crate::server::render::PLACEHOLDER_PASSWORD));
    }

    #[test]
    fn generation_reports_write_failures_and_missing_templates() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = session(root.path());
        let config = Config {
            groups: vec![Group { name: "PC".into(), template: "t.yaml".into(), ..Group::default() },
                Group { name: "MOBILE".into(), template: "missing.yaml".into(), ..Group::default() }],
            clients: vec![client("bad", "PC", None, "", ""), client("good", "PC", None, "", ""), client("skipped", "MOBILE", None, "", "")],
            ..Config::default()
        };
        session.state.save_config(&config).unwrap();
        std::fs::create_dir_all(session.state.paths().templates()).unwrap();
        std::fs::write(session.state.paths().templates().join("t.yaml"), "proxies:\nproxy-groups: []\n").unwrap();
        let dir = generated_dir(session.state.paths());
        std::fs::create_dir_all(dir.join("PC")).unwrap();
        std::fs::write(dir.join("PC/bad"), "blocked\n").unwrap();
        let error = generate(&mut session, &invocation(&["generate", "--all"])).unwrap_err();
        assert_eq!(error.code, "partial");
        assert_eq!((error.extra["ok"].clone(), error.extra["skipped"].clone(), error.extra["failed"].clone()),
            (json!(["good"]), json!(["skipped"]), json!(["bad"])));
        assert_eq!(std::fs::read_to_string(dir.join("PC/good/config.yaml")).unwrap(), "proxies:\nproxy-groups: []\n");
        assert!(!dir.join("MOBILE").exists());

        std::fs::remove_file(dir.join("PC/bad")).unwrap();
        let data = generate(&mut session, &invocation(&["generate", "--client", "bad"])).unwrap();
        assert_eq!((data["ok"].clone(), data["failed"].clone()), (json!(["bad"]), json!([])));

        let before = fingerprint(root.path());
        for (argv, code) in [(&["generate"][..], "usage"), (&["generate", "--all", "--group", "PC"], "usage"),
            (&["generate", "--group", "NOPE"], "not_found"), (&["generate", "--client", "nobody"], "not_found")] {
            assert_eq!(generate(&mut session, &invocation(argv)).unwrap_err().code, code);
        }
        assert_eq!(fingerprint(root.path()), before);
    }
}
