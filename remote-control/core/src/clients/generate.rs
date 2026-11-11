//! `generate --all | --group G | --client C` (port of `generate.sh`): node
//! client configs are read over SSH, missing AmneziaWG peers are created,
//! per-client `config.yaml` files are rendered from the group template into
//! `<data dir>/generated/<group>/<client>/`, and the listener users of every
//! touched node are synchronized. Each node is handled over one connection
//! (peers → config → listener users); rendering itself never touches SSH.
//! Configs are replaced atomically and only after every proxy was resolved,
//! so a failed node never leaves a client with a partial config.

use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::cli::Invocation;
use crate::clients::{client_nodes, find_client, find_group, group_nodes, require_one, templates};
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::locking::LockKind;
use crate::log::Level;
use crate::model::{Client, Config, Node};
use crate::nodes::scripts::{self, REMOTE_DIR};
use crate::nodes::{self, COMMAND_TIMEOUT, LONG_TIMEOUT, required, sh_quote};
use crate::protocols::listener_users;
use crate::secure_fs;
use crate::state::StatePaths;
use crate::transport::{RemoteSession, RemoteTransport};
use crate::validation;

/// Node client config plus every AmneziaWG peer's mihomo proxy (v1 prefetch).
pub const FETCH_COMMAND: &str =
    "cat /etc/mihomo/client-config.txt 2>/dev/null; cat /etc/mihomo/amnezia/*/mihomo-proxy.yaml 2>/dev/null; true";

/// Display name of a client's AmneziaWG proxy in its config.
const AWG_DISPLAY: &str = "  - name: \"AmneziaWG 3.1\"";
const NAME_PREFIX: &str = "  - name:";

/// Node config section header → listener marker of `listener-users.sh`.
const LISTENER_MARKERS: [(&str, &str); 4] = [
    ("--- VLESS TCP ---", "vless-tcp"),
    ("--- VLESS xHTTP ---", "vless-xhttp"),
    ("--- VLESS gRPC ---", "vless-grpc"),
    ("--- Hysteria2 ---", "hy2"),
];

/// Reads `marker count` records and their user lines from stdin, so client
/// uuids and passwords never enter argv (v1 `_listener_users_remote_cmd`).
const LISTENER_LOOP: &str = r##"_sync_rc=0
while IFS=' ' read -r _m _n; do
    [ -n "$_m" ] || continue
    case "$_m" in vless-tcp|vless-xhttp|vless-grpc|hy2) ;; *) exit 1 ;; esac
    case "$_n" in ''|*[!0-9]*) exit 1 ;; esac
    _u=''
    while [ "$_n" -gt 0 ]; do
        IFS= read -r _l || exit 1
        _u="$_u$_l
"
        _n=$((_n - 1))
    done
    _u=${_u%?}
"##;

/// Generation: the first failure stops before mihomo is restarted.
const STRICT_TAIL: &str = r##"    _sync_listener_users "$_m" "$_u" || exit 1
done
systemctl restart mihomo
"##;

/// Client deletion: markers absent on the node are skipped, failures add up.
const LENIENT_TAIL: &str = r##"    if grep -q "^# --- $_m ---\$" /etc/mihomo/config.yaml 2>/dev/null; then
        _sync_listener_users "$_m" "$_u" || _sync_rc=1
    fi
done
if [ -f /etc/mihomo/config.yaml ]; then systemctl restart mihomo || _sync_rc=1; fi
exit "$_sync_rc"
"##;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ListenerMode {
    Strict,
    Lenient,
}

fn listener_command(mode: ListenerMode) -> String {
    let module = sh_quote(&format!("{REMOTE_DIR}/common/listener-users.sh"));
    let tail = match mode {
        ListenerMode::Strict => STRICT_TAIL,
        ListenerMode::Lenient => LENIENT_TAIL,
    };
    format!("source {module} || exit 1\n{LISTENER_LOOP}{tail}")
}

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

/// The client's rendered config when it is ready to publish: a regular file
/// reached through real directories with at least one non-blank byte
/// (v1 `_subscription_config_ready`). `None` when absent or blank.
pub fn rendered_config(paths: &StatePaths, client: &Client) -> Result<Option<Vec<u8>>> {
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
    let bytes = std::fs::read(&path)?;
    Ok(has_content(&bytes).then_some(bytes))
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
}

impl Report {
    fn fields(&self, dir: &Path) -> [(&'static str, Value); 6] {
        [
            ("ok", json!(self.ok)),
            ("skipped", json!(self.skipped)),
            ("failed", json!(self.failed)),
            ("nodes_ok", json!(self.nodes_ok)),
            ("nodes_failed", json!(self.nodes_failed)),
            ("dir", json!(dir.to_string_lossy())),
        ]
    }

    /// No client and no node failed (skips are not failures).
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

/// Node configs read during one operation.
#[derive(Debug, Default)]
struct Fetched {
    configs: BTreeMap<String, String>,
    /// Nodes where needed AmneziaWG peers could not be checked or created.
    awg_failed: BTreeSet<String>,
}

/// Work done on one node over a single connection.
#[derive(Debug)]
struct NodeWork {
    name: String,
    /// Clients whose AmneziaWG peer must exist on the node.
    awg: Vec<String>,
    sync: bool,
}

/// What one operation generates and which nodes it touches.
struct Scope<'a> {
    /// `(group, only this client)` in generation order.
    targets: Vec<(String, Option<String>)>,
    /// Clients whose AmneziaWG peers are ensured where they need one.
    awg_clients: Vec<&'a Client>,
    fetch: Vec<String>,
    sync: Vec<String>,
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

fn own_connections(client: &Client, node: &str) -> Vec<String> {
    client.connections.iter().flatten().filter(|c| c.node == node).flat_map(|c| c.proxies.iter().cloned()).collect()
}

fn group_connections(config: &Config, group: &str, node: &str) -> Vec<String> {
    config.connections.iter().filter(|c| c.node == node)
        .flat_map(|c| c.groups.iter().filter(|g| g.name == group))
        .flat_map(|g| g.proxies.iter().cloned()).collect()
}

/// Connections a client uses on a node: its own when set, else its group's.
pub(crate) fn effective_connections(config: &Config, client: &Client, node: &str) -> Vec<String> {
    let own = own_connections(client, node);
    if own.is_empty() { group_connections(config, &client.group, node) } else { own }
}

/// Clients assigned to a node (via their group or own nodes) with credentials
/// for its listeners; `None` when any name or credential is invalid.
struct User<'a> {
    name: &'a str,
    uuid: &'a str,
    password: &'a str,
}

fn node_users<'a>(config: &'a Config, node: &str) -> Option<Vec<User<'a>>> {
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
        users.push(User { name: &client.name, uuid, password });
    }
    Some(users)
}

/// stdin of the listener command: per marker `marker count` and the YAML
/// lines of its users (v1 `_listener_users_payload`), built by the
/// `listener-users.sh` builders so Hysteria2 passwords are quoted YAML strings.
fn listener_payload(markers: &[&str], users: &[User<'_>]) -> String {
    let mut payload = String::new();
    for marker in markers {
        let block = if *marker == "hy2" {
            listener_users::hy2_users_yaml(users.iter().map(|user| (user.name, user.password)))
        } else {
            listener_users::vless_users_yaml(marker, users.iter().map(|user| (user.name, user.uuid)))
        };
        payload.push_str(&format!("{marker} {}\n{block}", block.lines().count()));
    }
    payload
}

/// Listener markers present in a node's client config.
fn node_markers(remote: &str) -> Vec<&'static str> {
    LISTENER_MARKERS.iter()
        .filter(|(header, _)| remote.split('\n').any(|line| line.starts_with(header)))
        .map(|(_, marker)| *marker).collect()
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

/// Proxies of one client from the fetched node configs (v1
/// `_fetch_proxies_for_client`): allowed connections, client credentials,
/// AmneziaWG display name, aliases and tag. `None` when a node config is
/// missing, a needed AmneziaWG peer was not created or credentials are invalid.
fn client_proxies(config: &Config, client: &Client, nodes: &[String], fetched: &Fetched,
    log: &mut dyn FnMut(Level, &str)) -> Option<String>
{
    let name = client.name.as_str();
    let (uuid, password) = client.credentials.as_ref()
        .map_or(("", ""), |c| (c.vless_uuid.as_str(), c.hy2_password.as_str()));
    if (!uuid.is_empty() && !validation::vless_uuid_valid(uuid))
        || (!password.is_empty() && !validation::hy2_password_valid(password)) {
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
        let allowed = if own.is_empty() { group } else { own };
        let Some(remote) = fetched.configs.get(node_name) else {
            complete = false;
            continue;
        };
        let mut section = proxy_section(remote);
        // Filtered even for an empty node answer: a failed peer must be noticed.
        if !allowed.is_empty() {
            let mut filtered = String::new();
            for connection in &allowed {
                let awg = connection == "AWG";
                let target = if awg { format!("awg-{name}") } else { connection.clone() };
                let mut block = select_blocks(&section, &target);
                if block.is_empty() {
                    if awg && fetched.awg_failed.contains(node_name) {
                        log(Level::Warn, &format!("{name}: клиент AmneziaWG на {node_name} не создан"));
                        complete = false;
                    }
                    continue;
                }
                let kind = proxy_type(&block).map(str::to_owned);
                match kind.as_deref() {
                    Some("vless") => {
                        if !uuid.is_empty() {
                            block = set_field(&block, "uuid", uuid);
                        }
                        block = trim_newlines(&crate::protocols::vless_xhttp::normalize_proxy_yaml(&block)).to_owned();
                    }
                    Some("hysteria2") if !password.is_empty() => block = set_field(&block, "password", password),
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
            section = filtered;
        }
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

/// Render the configs of `group` (only `only` when given) from `fetched`.
fn generate_group(session: &mut Session, config: &Config, group: &str, only: Option<&str>, fetched: &Fetched, report: &mut Report) {
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
            client_proxies(config, client, &nodes, fetched, &mut |level, text| session.log(level, text))
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

/// Exit 0 output of a remote command.
async fn run_ok<S: RemoteSession>(session: &S, command: &str, stdin: &[u8], timeout: std::time::Duration) -> Option<Vec<u8>> {
    session.exec(command, stdin, timeout).await.ok().filter(|result| result.exit_status == 0).map(|result| result.stdout)
}

/// Server scripts are checked at most once per node connection.
async fn scripts_ready<S: RemoteSession>(session: &S, node: &str, ready: &mut bool) -> Result<()> {
    if !*ready {
        scripts::ensure_current(session, node, false).await?;
        *ready = true;
    }
    Ok(())
}

/// Create the missing AmneziaWG peers of `clients`; `false` when the state
/// of the peers is unknown or creation failed. No AmneziaWG is not a failure.
async fn ensure_peers<T: RemoteTransport>(session: &mut Session, transport: &T, node: &str, clients: &[String], ready: &mut bool) -> bool {
    let Some(stdout) = run_ok(transport, crate::awg::STATUS_COMMAND, b"", COMMAND_TIMEOUT).await else { return false };
    let existing = match crate::awg::parse_probe(&stdout) {
        None => return false,
        Some(crate::awg::Probe::Absent) => return true,
        Some(crate::awg::Probe::Installed(existing)) => existing,
    };
    let missing: Vec<String> = clients.iter().filter(|client| !existing.contains(client)).cloned().collect();
    if missing.is_empty() {
        return true;
    }
    session.log(Level::Info, &format!("Создаю клиентов AmneziaWG на {node}: {}...", missing.join(" ")));
    if let Err(error) = scripts_ready(transport, node, ready).await {
        session.log(Level::Warn, &format!("{node}: не удалось подготовить скрипты; клиенты AmneziaWG не изменены. {}", error.message));
        return false;
    }
    if run_ok(transport, &crate::awg::create_command(&missing), b"", LONG_TIMEOUT).await.is_none() {
        session.log(Level::Warn, &format!("Ошибка при создании клиентов AmneziaWG на {node}"));
        return false;
    }
    true
}

/// Push the node's users into its listeners; the outcome is logged.
async fn sync_node<T: RemoteTransport>(session: &mut Session, config: &Config, transport: &T, node: &str,
    markers: &[&str], mode: ListenerMode, ready: &mut bool) -> bool
{
    let Some(users) = node_users(config, node) else {
        session.log(Level::Warn, &format!(
            "{node}: недопустимое имя или учётные данные клиента в конфигурации — пользователи на ноде не изменены."));
        return false;
    };
    let payload = listener_payload(markers, &users);
    if let Err(error) = scripts_ready(transport, node, ready).await {
        session.log(Level::Warn, &format!("{node}: не удалось подготовить скрипты; входные подключения не изменены. {}", error.message));
        return false;
    }
    let synced = run_ok(transport, &listener_command(mode), payload.as_bytes(), LONG_TIMEOUT).await.is_some();
    let separator = if mode == ListenerMode::Strict { " —" } else { ":" };
    if synced {
        session.log(Level::Success, &format!("{node}{separator} входные подключения обновлены"));
    } else {
        session.log(Level::Warn, &format!("{node}{separator} не удалось обновить входные подключения"));
    }
    synced
}

/// Connect to a stored node; refusal and connection errors are logged.
async fn open<T: RemoteTransport>(session: &mut Session, transport: &mut T, node: &Node) -> bool {
    let opened = match nodes::require_portable(session, node) {
        Ok(()) => nodes::connect(transport, &session.state, node).await,
        Err(error) => Err(error),
    };
    if let Err(error) = &opened {
        session.log(Level::Warn, &format!("Не удалось подключиться к {}: {}", node.name, error.message));
    }
    opened.is_ok()
}

/// One connection: peers, then the client config, then listener users.
/// Returns the listener outcome when `work.sync`.
async fn node_pass<T: RemoteTransport>(session: &mut Session, config: &Config, transport: &mut T, work: &NodeWork,
    fetched: &mut Fetched) -> Option<bool>
{
    let name = work.name.as_str();
    let failed = work.sync.then_some(false);
    let Some(node) = config.nodes.iter().find(|node| node.name == name) else {
        session.log(Level::Warn, &format!("Не удалось загрузить ноду «{name}»."));
        return failed;
    };
    session.log(Level::Info, &format!("Подключаюсь к {name}..."));
    if !open(session, transport, node).await {
        session.log(Level::Warn, &format!("Не удалось получить конфиг с {name}"));
        if !work.awg.is_empty() {
            fetched.awg_failed.insert(name.to_owned());
        }
        return failed;
    }
    let mut ready = false;
    if !work.awg.is_empty() && !ensure_peers(session, transport, name, &work.awg, &mut ready).await {
        fetched.awg_failed.insert(name.to_owned());
    }
    let Some(stdout) = run_ok(&*transport, FETCH_COMMAND, b"", COMMAND_TIMEOUT).await else {
        session.log(Level::Warn, &format!("Не удалось получить конфиг с {name}"));
        return failed;
    };
    let remote = String::from_utf8_lossy(&stdout).into_owned();
    session.log(Level::Success, &format!("{name} — конфиг загружен"));
    let markers = node_markers(&remote);
    fetched.configs.insert(name.to_owned(), remote);
    if !work.sync {
        return None;
    }
    Some(sync_node(session, config, transport, name, &markers, ListenerMode::Strict, &mut ready).await)
}

/// Node passes, rendering, then the listener outcome of the sync nodes.
async fn run<T: RemoteTransport>(session: &mut Session, config: &Config, scope: Scope<'_>, connect: &dyn Fn() -> T) -> Report {
    let mut order = scope.fetch.clone();
    push_unique(&mut order, scope.sync.iter().cloned());
    let work: Vec<NodeWork> = order.into_iter().map(|name| NodeWork {
        awg: scope.awg_clients.iter().filter(|client| crate::awg::needs_peer(config, client, &name))
            .map(|client| client.name.clone()).collect(),
        sync: scope.sync.contains(&name),
        name,
    }).collect();
    let mut fetched = Fetched::default();
    let mut synced = BTreeMap::new();
    if !work.is_empty() {
        let mut transport = connect();
        for item in &work {
            if let Some(outcome) = node_pass(session, config, &mut transport, item, &mut fetched).await {
                synced.insert(item.name.clone(), outcome);
            }
        }
    }
    let mut report = Report::default();
    for (group, only) in &scope.targets {
        generate_group(session, config, group, only.as_deref(), &fetched, &mut report);
    }
    for node in scope.sync {
        if synced.get(&node) == Some(&true) {
            report.nodes_ok.push(node);
        } else {
            report.nodes_failed.push(node);
        }
    }
    report
}

/// `generate (--all | --group G | --client C)`.
pub async fn generate<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T) -> Result<Value> {
    require_one(invocation, &["all", "group", "client"])?;
    let config = session.state.load_config()?;
    let scope = if invocation.has("all") {
        let mut scope = Scope { targets: Vec::new(), awg_clients: Vec::new(), fetch: Vec::new(), sync: Vec::new() };
        for group in &config.groups {
            scope.targets.push((group.name.clone(), None));
            scope.awg_clients.extend(group_members(&config, &group.name));
            push_unique(&mut scope.fetch, group_scope_nodes(&config, &group.name));
        }
        scope.sync = scope.fetch.clone();
        scope
    } else if invocation.has("group") {
        let group = required(invocation, "group")?;
        find_group(&config, group)?;
        let nodes = group_scope_nodes(&config, group);
        Scope { targets: vec![(group.to_owned(), None)], awg_clients: group_members(&config, group), fetch: nodes.clone(), sync: nodes }
    } else {
        let name = required(invocation, "client")?;
        let client = find_client(&config, name)?;
        let mut nodes = Vec::new();
        push_unique(&mut nodes, client_nodes(&config, client));
        Scope { targets: vec![(client.group.clone(), Some(name.to_owned()))], awg_clients: vec![client], fetch: nodes.clone(), sync: nodes }
    };
    let dir = generated_dir(session.state.paths());
    if scope.targets.is_empty() {
        session.log(Level::Warn, "Нет групп.");
        return Report::default().finish(&dir);
    }
    let _guard = session.state.locks().acquire(LockKind::Mutation, "generate")?;
    run(session, &config, scope, connect).await.finish(&dir)
}

/// Regenerate `group` after a client changed groups (v1 set-group flow):
/// configs of `nodes` and the group's nodes are read, the group's peers are
/// ensured, its configs rendered and the users of `nodes` synchronized.
/// Client and node failures are in the report; `Err` only when nothing ran.
pub async fn regenerate_group<T: RemoteTransport>(session: &mut Session, group: &str, nodes: &[String], connect: &dyn Fn() -> T) -> Result<Report> {
    let config = session.state.load_config()?;
    let _guard = session.state.locks().acquire(LockKind::Mutation, "generate")?;
    let mut sync = Vec::new();
    push_unique(&mut sync, nodes.iter().cloned());
    let mut fetch = sync.clone();
    push_unique(&mut fetch, group_scope_nodes(&config, group));
    let scope = Scope { targets: vec![(group.to_owned(), None)], awg_clients: group_members(&config, group), fetch, sync };
    Ok(run(session, &config, scope, connect).await)
}

/// Remove deleted clients from the listeners of `nodes` (v1 client delete):
/// every listener marker is sent, markers absent on a node are skipped.
/// Returns the nodes that failed; outcomes are logged.
pub async fn sync_listeners<T: RemoteTransport>(session: &mut Session, nodes: &[String], connect: &dyn Fn() -> T) -> Vec<String> {
    let mut failed = Vec::new();
    let config = match session.state.load_config() {
        Ok(config) => config,
        Err(error) => {
            session.log(Level::Warn, &format!("Не удалось прочитать конфигурацию: {}", error.message));
            return nodes.to_vec();
        }
    };
    let markers: Vec<&str> = LISTENER_MARKERS.iter().map(|(_, marker)| *marker).collect();
    let mut transport = None;
    for name in nodes {
        let Some(node) = config.nodes.iter().find(|node| node.name == *name) else {
            session.log(Level::Warn, &format!("Не удалось загрузить ноду «{name}»."));
            failed.push(name.clone());
            continue;
        };
        let transport = transport.get_or_insert_with(connect);
        let mut ready = false;
        if !open(session, transport, node).await
            || !sync_node(session, &config, transport, name, &markers, ListenerMode::Lenient, &mut ready).await {
            failed.push(name.clone());
        }
    }
    failed
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use super::*;
    use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeScript, FakeTransport, ScriptStep};
    use crate::model::{Auth, ClientConnection, ClientCredentials, Connection, ConnectionGroup, Fingerprint, Group};
    use crate::nodes::testing::{Journal, fingerprint, invocation, session};
    use crate::nodes::{CONNECT_TIMEOUT, pin};
    use crate::transport::{ExecResult, HostKeyPolicy};

    const SAMPLE: &str = "proxies:\n  - name: \"vless-reality\"\n    type: vless\n    server: 1.2.3.4\n    port: 443\n\
        \x20   uuid: \"test-uuid-1234\"\n    network: tcp\n    tls: true\n    servername: example.com\n\n\
        \x20 - name: \"hy2-main\"\n    type: hysteria2\n    server: 1.2.3.4\n    port: 8443\n    password: \"testpass\"\n\n\
        \x20 - name: \"awg-my-router\"\n    type: wireguard\n    server: 1.2.3.4\n    port: 51820\n\n\
        ---\nproxy-groups:\n  - name: auto\n    type: url-test\n";
    const TEMPLATE: &str = "mixed-port: 7890\n\nproxies:\n\n\n# --- PC ---\npc-only: true\n# --- PC ---\nproxy-groups: []\n";
    const ROUTER_UUID: &str = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    const PC_UUID: &str = "11111111-2222-3333-4444-555555555555";

    fn fp(byte: u8) -> Fingerprint {
        use base64::Engine;
        format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode([byte; 32])).parse().unwrap()
    }

    fn node(index: u8, name: &str, tag: &str) -> Node {
        Node {
            id: format!("{index:032x}"), name: name.into(), ip: format!("198.51.100.{index}"), port: 22, user: "root".into(),
            auth: Auth::Key, identity: Some("system".into()), secret_id: None, tag: Some(tag.into()), aliases: Default::default(),
        }
    }

    fn client(name: &str, group: &str, own: Option<(&str, &[&str])>, uuid: &str, password: &str) -> Client {
        Client {
            name: name.into(), group: group.into(), inherit_nodes_from_group: own.is_none(),
            nodes: own.map(|(node, _)| vec![node.into()]),
            connections: own.map(|(node, proxies)| vec![ClientConnection { node: node.into(), proxies: proxies.iter().map(|p| p.to_string()).collect() }]),
            credentials: Some(ClientCredentials { vless_uuid: uuid.into(), hy2_password: password.into() }),
            ..Client::default()
        }
    }

    fn connection(node: &str, groups: &[(&str, &[&str])]) -> Connection {
        Connection { node: node.into(), groups: groups.iter().map(|(name, proxies)| ConnectionGroup {
            name: (*name).into(), proxies: proxies.iter().map(|p| p.to_string()).collect() }).collect() }
    }

    /// de (tag DE) and ru (alias vless-reality → RU-VLESS); ROUTER on both,
    /// PC on de; my-router inherits ROUTER, my-pc owns de with vless only.
    fn fixture(root: &Path) -> (Session, Journal) {
        let (session, journal) = session(root);
        let de = node(1, "de", "DE");
        let mut ru = node(2, "ru", "");
        ru.aliases.insert("vless-reality".into(), "RU-VLESS".into());
        for node in [&de, &ru] {
            pin(&session.state, &node.ip, 22, vec![fp(node.id.as_bytes()[31])]).unwrap();
        }
        let config = Config {
            nodes: vec![de, ru],
            groups: vec![Group { name: "ROUTER".into(), template: "t.yaml".into(), ..Group::default() },
                Group { name: "PC".into(), template: "t.yaml".into(), ..Group::default() }],
            clients: vec![client("my-router", "ROUTER", None, ROUTER_UUID, "router-hy2-pass-0001"),
                client("my-pc", "PC", Some(("de", &["vless-reality"])), PC_UUID, "pc-hy2-pass-0002")],
            connections: vec![connection("de", &[("ROUTER", &["vless-reality", "hy2-main"]), ("PC", &["vless-reality", "hy2-main"])]),
                connection("ru", &[("ROUTER", &["vless-reality"])])],
            ..Config::default()
        };
        session.state.save_config(&config).unwrap();
        std::fs::create_dir_all(session.state.paths().templates()).unwrap();
        std::fs::write(session.state.paths().templates().join("t.yaml"), TEMPLATE).unwrap();
        (session, journal)
    }

    fn ok(stdout: &str) -> Result<ExecResult> {
        Ok(ExecResult { stdout: stdout.as_bytes().to_vec(), stderr: Vec::new(), exit_status: 0 })
    }

    fn connect_step(node: &Node, outcome: Result<()>) -> ScriptStep {
        ScriptStep::connect(ConnectExpectation::new(node.ip.clone(), 22, "root", AuthMethod::System, CONNECT_TIMEOUT)
            .with_host_key(HostKeyPolicy { expected: None, known: vec![fp(node.id.as_bytes()[31])] }), outcome)
    }

    fn probe_step() -> ScriptStep {
        ScriptStep::exec(scripts::probe_command(), 0, COMMAND_TIMEOUT, ok(&format!("PRESENT\n{}\n", scripts::local_version().unwrap())))
    }

    /// A `connect` that hands out the scripted transport once.
    fn once(transport: FakeTransport) -> (FakeScript, RefCell<Option<FakeTransport>>) {
        (transport.script(), RefCell::new(Some(transport)))
    }

    fn fetched(configs: &[(&str, &str)]) -> Fetched {
        Fetched { configs: configs.iter().map(|(n, c)| (n.to_string(), c.to_string())).collect(), ..Fetched::default() }
    }

    fn proxies(config: &Config, client: &str, nodes: &[&str], fetched: &Fetched) -> (Option<String>, Vec<String>) {
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
        let config = session.state.load_config().unwrap();
        let cache = fetched(&[("de", SAMPLE), ("ru", &SAMPLE.replace('\n', "\r\n"))]);

        let (router, _) = proxies(&config, "my-router", &["de", "ru"], &cache);
        let router = router.unwrap();
        assert_eq!(router, format!("  - name: \"DE vless-reality\"\n    type: vless\n    server: 1.2.3.4\n    port: 443\n\
            \x20   uuid: {ROUTER_UUID}\n    network: tcp\n    tls: true\n    servername: example.com\n\n\
            \x20 - name: \"DE hy2-main\"\n    type: hysteria2\n    server: 1.2.3.4\n    port: 8443\n    password: router-hy2-pass-0001\n\n\n\
            \x20 - name: \"RU-VLESS\"\n    type: vless\n    server: 1.2.3.4\n    port: 443\n\
            \x20   uuid: {ROUTER_UUID}\n    network: tcp\n    tls: true\n    servername: example.com"));

        // Own connections override the group's: no hy2 for my-pc.
        let (pc, _) = proxies(&config, "my-pc", &["de"], &cache);
        let pc = pc.unwrap();
        assert!(pc.contains(&format!("uuid: {PC_UUID}")) && !pc.contains("hy2-main") && !pc.contains("test-uuid"));

        // A node without a fetched config fails the client.
        assert_eq!(proxies(&config, "my-router", &["de", "ru"], &fetched(&[("de", SAMPLE)])).0, None);

        // xHTTP blocks get the client uuid and the firefox fingerprint.
        let xhttp = "proxies:\n  - name: \"vless-xhttp\"\n    type: vless\n    uuid: original\n    network: xhttp\n    client-fingerprint: chrome\n---\n";
        let mut config_x = config.clone();
        config_x.connections[0].groups[0].proxies.push("vless-xhttp".into());
        let (out, _) = proxies(&config_x, "my-router", &["de"], &fetched(&[("de", xhttp)]));
        let out = out.unwrap();
        assert!(out.contains(&format!("uuid: {ROUTER_UUID}")) && out.contains("client-fingerprint: firefox") && !out.contains("chrome"));
    }

    #[test]
    fn awg_proxies_use_the_client_peer_and_fail_when_the_peer_was_not_created() {
        let root = tempfile::tempdir().unwrap();
        let (session, _) = fixture(root.path());
        let mut config = session.state.load_config().unwrap();
        config.connections[0].groups[0].proxies.push("AWG".into());
        let awg = "proxies:\n  - name: \"awg-my-router\"\n    type: wireguard\n    ip: 10.10.8.2\n    amnezia-wg-option:\n      version: 3\n\
            proxies:\n  - name: \"awg-other\"\n    type: wireguard\n    server: 9.9.9.9\n---\n";
        let (out, _) = proxies(&config, "my-router", &["de"], &fetched(&[("de", awg)]));
        let out = out.unwrap();
        assert!(out.contains("  - name: \"DE AmneziaWG 3.1\"\n    type: wireguard\n    ip: 10.10.8.2\n    amnezia-wg-option:\n      version: 3"));
        assert!(!out.contains("9.9.9.9"));

        let mut cache = fetched(&[("de", "")]);
        cache.awg_failed.insert("de".into());
        let (out, log) = proxies(&config, "my-router", &["de"], &cache);
        assert_eq!(out, None);
        assert!(log.contains(&"my-router: клиент AmneziaWG на de не создан".to_string()));
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
    fn listener_payload_and_commands_keep_credentials_on_stdin() {
        let users = [User { name: "r", uuid: ROUTER_UUID, password: "p1" }, User { name: "n", uuid: "", password: "" },
            User { name: "d", uuid: "", password: "-" }];
        assert_eq!(listener_payload(&["vless-tcp", "vless-grpc", "hy2"], &users), format!(
            "vless-tcp 3\n      - username: r\n        uuid: {ROUTER_UUID}\n        flow: xtls-rprx-vision\n\
             vless-grpc 2\n      - username: r\n        uuid: {ROUTER_UUID}\nhy2 2\n      r: \"p1\"\n      d: \"-\"\n"));
        assert_eq!(listener_payload(&["hy2"], &[]), "hy2 0\n");
        let strict = listener_command(ListenerMode::Strict);
        assert!(strict.starts_with("source '/root/essence-setup/common/listener-users.sh' || exit 1\n_sync_rc=0\n"));
        assert!(strict.ends_with("|| exit 1\ndone\nsystemctl restart mihomo\n") && !strict.contains(ROUTER_UUID));
        assert!(listener_command(ListenerMode::Lenient).ends_with("exit \"$_sync_rc\"\n"));
        assert_eq!(node_markers("x\n--- VLESS TCP ---\r\n--- Hysteria2 --- (8443)\n"), ["vless-tcp", "hy2"]);
    }

    fn node_steps(node: &Node, remote: &str, payload_len: usize) -> Vec<ScriptStep> {
        vec![connect_step(node, Ok(())), ScriptStep::exec(FETCH_COMMAND, 0, COMMAND_TIMEOUT, ok(remote)), probe_step(),
            ScriptStep::exec(listener_command(ListenerMode::Strict), payload_len, LONG_TIMEOUT, ok(""))]
    }

    #[tokio::test(flavor = "current_thread")]
    async fn generate_all_renders_every_client_and_syncs_listeners() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = fixture(root.path());
        let config = session.state.load_config().unwrap();
        let remote = format!("--- VLESS TCP ---\n{SAMPLE}");
        let de_users = listener_payload(&["vless-tcp"], &node_users(&config, "de").unwrap()).len();
        let ru_users = listener_payload(&["vless-tcp"], &node_users(&config, "ru").unwrap()).len();
        let mut steps = node_steps(&config.nodes[0], &remote, de_users);
        steps.extend(node_steps(&config.nodes[1], &remote, ru_users));
        let (script, cell) = once(FakeTransport::new(steps));
        let connect = || cell.borrow_mut().take().expect("one transport per command");
        let data = generate(&mut session, &invocation(&["generate", "--all"]), &connect).await.unwrap();
        script.assert_finished();
        let dir = generated_dir(session.state.paths());
        assert_eq!(data, json!({"ok": ["my-router", "my-pc"], "skipped": [], "failed": [], "nodes_ok": ["de", "ru"],
            "nodes_failed": [], "dir": dir.to_string_lossy()}));
        let router = std::fs::read_to_string(dir.join("ROUTER/my-router/config.yaml")).unwrap();
        assert!(router.starts_with("mixed-port: 7890\n\nproxies:\n  - name: \"DE vless-reality\"\n"));
        assert!(router.ends_with("    servername: example.com\n\nproxy-groups: []\n") && !router.contains("pc-only"));
        assert!(!router.contains("\n\n\n"));
        let pc = std::fs::read_to_string(dir.join("PC/my-pc/config.yaml")).unwrap();
        assert!(pc.contains("pc-only: true\n") && pc.contains(PC_UUID));
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

    #[tokio::test(flavor = "current_thread")]
    async fn failed_awg_peer_creation_keeps_the_client_config() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = fixture(root.path());
        let mut config = session.state.load_config().unwrap();
        config.connections[0].groups[0].proxies.push("AWG".into());
        session.state.save_config(&config).unwrap();
        let users = |node: &str| listener_payload(&[], &node_users(&config, node).unwrap()).len();
        let mut steps = vec![connect_step(&config.nodes[0], Ok(())),
            ScriptStep::exec(crate::awg::STATUS_COMMAND, 0, COMMAND_TIMEOUT, ok("AWG_OK\nmy-pc\n")), probe_step(),
            ScriptStep::exec(crate::awg::create_command(&["my-router".into()]), 0, LONG_TIMEOUT,
                Ok(ExecResult { exit_status: 1, ..ExecResult::default() })),
            ScriptStep::exec(FETCH_COMMAND, 0, COMMAND_TIMEOUT, ok("proxies:\n---\n")),
            ScriptStep::exec(listener_command(ListenerMode::Strict), users("de"), LONG_TIMEOUT, ok(""))];
        steps.extend(node_steps(&config.nodes[1], SAMPLE, users("ru")));
        let (script, cell) = once(FakeTransport::new(steps));
        let connect = || cell.borrow_mut().take().expect("one transport per command");
        let error = generate(&mut session, &invocation(&["generate", "--client", "my-router"]), &connect).await.unwrap_err();
        script.assert_finished();
        assert_eq!((error.extra["failed"].clone(), error.extra["nodes_ok"].clone()), (json!(["my-router"]), json!(["de", "ru"])));
        assert!(!generated_dir(session.state.paths()).join("ROUTER/my-router/config.yaml").exists());
        let journal = journal.borrow();
        for line in ["Ошибка при создании клиентов AmneziaWG на de", "my-router: клиент AmneziaWG на de не создан"] {
            assert!(journal.iter().any(|(_, text)| text == line), "{line}");
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn unreachable_node_fails_its_clients_and_keeps_their_previous_config() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = fixture(root.path());
        let config = session.state.load_config().unwrap();
        let previous = generated_dir(session.state.paths()).join("ROUTER/my-router");
        std::fs::create_dir_all(&previous).unwrap();
        std::fs::write(previous.join("config.yaml"), "previous\n").unwrap();
        let ru_users = listener_payload(&[], &node_users(&config, "ru").unwrap()).len();
        let mut steps = vec![connect_step(&config.nodes[0], Err(RcError::new("remote_failed", "x").with_extra("reason", "timeout")))];
        steps.extend(node_steps(&config.nodes[1], SAMPLE, ru_users));
        let (script, cell) = once(FakeTransport::new(steps));
        let connect = || cell.borrow_mut().take().expect("one transport per command");
        let error = generate(&mut session, &invocation(&["generate", "--group", "ROUTER"]), &connect).await.unwrap_err();
        script.assert_finished();
        assert_eq!((error.code, error.message.as_str(), error.exit_code()), ("partial", "Генерация завершена с ошибками.", 1));
        assert_eq!((error.extra["ok"].clone(), error.extra["failed"].clone()), (json!([]), json!(["my-router"])));
        assert_eq!((error.extra["nodes_ok"].clone(), error.extra["nodes_failed"].clone()), (json!(["ru"]), json!(["de"])));
        assert_eq!(std::fs::read_to_string(previous.join("config.yaml")).unwrap(), "previous\n");
        let journal = journal.borrow();
        assert!(journal.iter().any(|(_, text)| text == "my-router — не удалось получить все подключения; конфиг сохранён без изменений"));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn generation_reports_write_failures_and_missing_templates_without_ssh() {
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
        let connect = FakeTransport::default;
        let error = generate(&mut session, &invocation(&["generate", "--all"]), &connect).await.unwrap_err();
        assert_eq!(error.code, "partial");
        assert_eq!((error.extra["ok"].clone(), error.extra["skipped"].clone(), error.extra["failed"].clone()),
            (json!(["good"]), json!(["skipped"]), json!(["bad"])));
        assert_eq!(std::fs::read_to_string(dir.join("PC/good/config.yaml")).unwrap(), "proxies:\nproxy-groups: []\n");
        assert!(!dir.join("MOBILE").exists());

        std::fs::remove_file(dir.join("PC/bad")).unwrap();
        let data = generate(&mut session, &invocation(&["generate", "--client", "bad"]), &connect).await.unwrap();
        assert_eq!((data["ok"].clone(), data["failed"].clone()), (json!(["bad"]), json!([])));

        let before = fingerprint(root.path());
        for (argv, code) in [(&["generate"][..], "usage"), (&["generate", "--all", "--group", "PC"], "usage"),
            (&["generate", "--group", "NOPE"], "not_found"), (&["generate", "--client", "nobody"], "not_found")] {
            assert_eq!(generate(&mut session, &invocation(argv), &connect).await.unwrap_err().code, code);
        }
        assert_eq!(fingerprint(root.path()), before);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn lenient_sync_sends_every_marker_and_reports_failed_nodes() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = fixture(root.path());
        let config = session.state.load_config().unwrap();
        let markers: Vec<&str> = LISTENER_MARKERS.iter().map(|(_, m)| *m).collect();
        let de_len = listener_payload(&markers, &node_users(&config, "de").unwrap()).len();
        let (script, cell) = once(FakeTransport::new([
            connect_step(&config.nodes[0], Ok(())), probe_step(),
            ScriptStep::exec(listener_command(ListenerMode::Lenient), de_len, LONG_TIMEOUT, Ok(ExecResult { exit_status: 1, ..ExecResult::default() })),
            connect_step(&config.nodes[1], Ok(())), probe_step(),
            ScriptStep::exec(listener_command(ListenerMode::Lenient), listener_payload(&markers, &node_users(&config, "ru").unwrap()).len(), LONG_TIMEOUT, ok("")),
        ]));
        let connect = || cell.borrow_mut().take().expect("one transport per command");
        let failed = sync_listeners(&mut session, &["de".into(), "ru".into(), "ghost".into()], &connect).await;
        script.assert_finished();
        assert_eq!(failed, ["de", "ghost"]);
    }
}
