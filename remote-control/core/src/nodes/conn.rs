//! `conn list|set|sync`: per-group proxy assignments of nodes (port of
//! `connections.sh`). Discovery reads the node's mihomo client config over
//! SSH; it is authoritative for pruning and never adds assignments.

use std::collections::BTreeSet;

use serde_json::{json, Value};

use super::{COMMAND_TIMEOUT, find, required};
use crate::cli::Invocation;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::model::{Config, Connection, ConnectionGroup, Node};
use crate::transport::RemoteTransport;

/// A missing client config means mihomo is not set up: reachable, no proxies.
pub const DISCOVER_COMMAND: &str = r#"f=/etc/mihomo/client-config.txt; [ -e "$f" ] || exit 0; cat "$f""#;

/// Proxy names a node offers: connect under its pins, read the client config,
/// extract names. Deferred GitHub nodes are refused before any connection.
pub(crate) async fn discover<T: RemoteTransport>(session: &Session, node: &Node, transport: &mut T) -> Result<Vec<String>> {
    super::require_portable(session, node)?;
    super::connect(transport, &session.state, node).await?;
    let failed = || RcError::new("remote_failed", format!("Не удалось обнаружить подключения на «{}».", node.name))
        .with_extra("name", node.name.clone());
    let result = transport.exec(DISCOVER_COMMAND, &[], COMMAND_TIMEOUT).await.map_err(|error| {
        match error.extra.get("reason") {
            Some(reason) => failed().with_extra("reason", reason.clone()),
            None => failed(),
        }
    })?;
    if result.exit_status != 0 {
        return Err(failed().with_extra("exit_status", result.exit_status));
    }
    Ok(parse_discovered(&String::from_utf8_lossy(&result.stdout)))
}

/// Names of VLESS, Hysteria2 and cascade proxies plus `AWG` for an AmneziaWG
/// section, sorted bytewise and unique. Only YAML `name:` keys count (block
/// `- name: x` or flow `{name: x, …}`), quoted or not, CR-tolerant.
pub(crate) fn parse_discovered(config: &str) -> Vec<String> {
    let mut names = BTreeSet::new();
    for raw in config.lines() {
        let line = raw.trim_end_matches('\r');
        if line.starts_with("--- AmneziaWG ---") {
            names.insert("AWG".to_owned());
        }
        for name in yaml_names(line) {
            let lower = name.to_lowercase();
            if ["vless", "hy2", "hysteria", "cascade"].iter().any(|keyword| lower.contains(keyword)) {
                names.insert(name);
            }
        }
    }
    names.into_iter().collect()
}

/// Values of `name:` keys on one line; prose such as `Service name:` is not a key.
fn yaml_names(line: &str) -> Vec<String> {
    let mut names = Vec::new();
    let mut consumed = 0;
    for (index, _) in line.match_indices("name:") {
        if index < consumed {
            continue;
        }
        let before = line[..index].trim();
        let flow = before.ends_with('{') || before.ends_with(',');
        if !(before.is_empty() || before == "-" || flow) {
            continue;
        }
        let start = index + "name:".len();
        let value = line[start..].trim_start();
        let offset = line.len() - value.len();
        let (name, length) = match value.chars().next() {
            Some(quote @ ('"' | '\'')) => quoted_scalar(&value[1..], quote),
            _ => {
                let end = if flow { value.find([',', '}']).unwrap_or(value.len()) } else { value.len() };
                let scalar = &value[..end];
                let scalar = scalar.find(" #").map_or(scalar, |comment| &scalar[..comment]);
                (scalar.trim().to_owned(), end)
            }
        };
        consumed = offset + length;
        if !name.is_empty() {
            names.push(name);
        }
    }
    names
}

/// Decoded body of a quoted scalar (after the opening quote) and the bytes
/// consumed including both quotes. Double quotes decode the escapes the
/// builders emit (`\\`, `\"`, `\n`, `\r`; others stay verbatim); single quotes
/// decode `''`. An unterminated scalar runs to the end of the line.
fn quoted_scalar(body: &str, quote: char) -> (String, usize) {
    let mut name = String::new();
    let mut chars = body.char_indices().peekable();
    while let Some((index, ch)) = chars.next() {
        match ch {
            '\\' if quote == '"' => match chars.next() {
                Some((_, '\\')) => name.push('\\'),
                Some((_, '"')) => name.push('"'),
                Some((_, 'n')) => name.push('\n'),
                Some((_, 'r')) => name.push('\r'),
                Some((_, other)) => { name.push('\\'); name.push(other); }
                None => name.push('\\'),
            },
            '\'' if quote == '\'' && chars.peek().is_some_and(|&(_, next)| next == '\'') => {
                chars.next();
                name.push('\'');
            }
            _ if ch == quote => return (name, index + 2),
            _ => name.push(ch),
        }
    }
    (name, body.len() + 1)
}

fn node_groups(config: &Config, node: &str) -> Value {
    let groups: Vec<&ConnectionGroup> = config.connections.iter()
        .filter(|connection| connection.node == node)
        .flat_map(|connection| &connection.groups).collect();
    json!(groups)
}

/// Order-preserving unique non-empty values.
fn unique(values: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    values.iter().filter(|value| !value.is_empty() && seen.insert(value.as_str())).cloned().collect()
}

pub async fn list<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, transport: &mut T) -> Result<Value> {
    let discovering = invocation.has("discover");
    if discovering && !invocation.has("name") {
        return Err(RcError::new("usage", "Флаг --discover требует --name."));
    }
    let config = session.state.load_config()?;
    let only = match invocation.has("name") {
        true => Some(find(&config, invocation.value("name").unwrap_or_default())?.clone()),
        false => None,
    };
    let mut entries: Vec<Value> = config.nodes.iter()
        .filter(|node| only.as_ref().is_none_or(|only| only.name == node.name))
        .map(|node| json!({"node": node.name, "groups": node_groups(&config, &node.name)}))
        .collect();
    if let (true, Some(node)) = (discovering, only.as_ref()) {
        let discovered = discover(session, node, transport).await?;
        for entry in &mut entries {
            entry["discovered"] = json!(discovered);
        }
    }
    Ok(Value::Array(entries))
}

/// Replace the proxies of `groups` in the node's assignment (in place, new
/// groups appended); without proxies the groups are unassigned.
fn assign(config: &mut Config, node: &str, groups: &[String], proxies: &[String]) {
    let mut first = true;
    for connection in config.connections.iter_mut().filter(|connection| connection.node == node) {
        if first && !proxies.is_empty() {
            for group in groups {
                match connection.groups.iter_mut().find(|existing| existing.name == *group) {
                    Some(existing) => existing.proxies = proxies.to_vec(),
                    None => connection.groups.push(ConnectionGroup { name: group.clone(), proxies: proxies.to_vec() }),
                }
            }
        } else {
            connection.groups.retain(|existing| !groups.contains(&existing.name));
        }
        first = false;
    }
    if first && !proxies.is_empty() {
        config.connections.push(Connection {
            node: node.to_owned(),
            groups: groups.iter().map(|group| ConnectionGroup { name: group.clone(), proxies: proxies.to_vec() }).collect(),
        });
    }
    config.connections.retain(|connection| connection.node != node || !connection.groups.is_empty());
}

pub fn set(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let node = required(invocation, "name")?.to_owned();
    if !invocation.has("group") {
        return Err(RcError::new("usage", "Укажите --group."));
    }
    let groups = unique(invocation.values("group"));
    let proxies = unique(invocation.values("proxy"));
    if groups.is_empty() {
        return Err(RcError::new("invalid", "Не выбрана ни одна группа."));
    }
    if let Some(proxy) = proxies.iter().find(|proxy| proxy.contains(',')) {
        return Err(RcError::new("invalid", format!("Недопустимое имя подключения: «{proxy}».")));
    }
    session.mutate("assign_connections", |state| {
        let mut config = state.load_config()?;
        find(&config, &node)?;
        if let Some(group) = groups.iter().find(|group| !config.groups.iter().any(|known| known.name == **group)) {
            return Err(RcError::new("not_found", format!("Группа «{group}» не найдена.")).with_extra("group", group.clone()));
        }
        assign(&mut config, &node, &groups, &proxies);
        state.save_config(&config)
    })?;
    for group in &groups {
        let text = if proxies.is_empty() { format!("{node} -> {group}: назначение снято") } else { format!("{node} -> {group} сохранено") };
        session.log(Level::Success, &text);
    }
    Ok(json!({"node": node, "groups": groups, "proxies": proxies}))
}

/// Keep only discovered proxies of `node`: in its group assignments (empty
/// groups and entries dropped) and in client-owned selections (entries kept,
/// so a client never silently falls back to its group). Per-peer `awg-<peer>`
/// assignments survive while the node reports AmneziaWG (`AWG`): discovery
/// does not list individual peers. Returns the removed names.
fn purge(config: &mut Config, node: &str, discovered: &[String]) -> BTreeSet<String> {
    let awg = discovered.iter().any(|name| name == "AWG");
    let mut removed = BTreeSet::new();
    let mut keep = |proxy: &String| {
        let valid = discovered.contains(proxy) || (awg && proxy.starts_with("awg-"));
        if !valid {
            removed.insert(proxy.clone());
        }
        valid
    };
    for connection in config.connections.iter_mut().filter(|connection| connection.node == node) {
        for group in &mut connection.groups {
            group.proxies.retain(&mut keep);
        }
        connection.groups.retain(|group| !group.proxies.is_empty());
    }
    config.connections.retain(|connection| connection.node != node || !connection.groups.is_empty());
    for selection in config.clients.iter_mut().filter_map(|client| client.connections.as_mut()) {
        for owned in selection.iter_mut().filter(|owned| owned.node == node) {
            owned.proxies.retain(&mut keep);
        }
    }
    removed
}

/// Discovery result applied under the mutation lock; an unchanged
/// configuration is not rewritten.
fn apply_discovery(session: &mut Session, node: &str, discovered: &[String]) -> Result<BTreeSet<String>> {
    let current = session.state.load_config()?;
    let mut candidate = current.clone();
    purge(&mut candidate, node, discovered);
    if candidate == current {
        return Ok(BTreeSet::new());
    }
    session.mutate("sync_connections", |state| {
        let mut config = state.load_config()?;
        let removed = purge(&mut config, node, discovered);
        state.save_config(&config)?;
        Ok(removed)
    })
}

pub async fn sync<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, transport: &mut T) -> Result<Value> {
    let only = match invocation.has("name") {
        true => Some(required(invocation, "name")?.to_owned()),
        false => None,
    };
    let config = session.state.load_config()?;
    if let Some(only) = &only {
        find(&config, only)?;
    }
    let nodes: Vec<Node> = config.nodes.into_iter()
        .filter(|node| only.as_ref().is_none_or(|only| *only == node.name)).collect();
    if !nodes.is_empty() {
        session.log(Level::Info, "Синхронизирую подключения с нодами...");
    }
    let (mut ok, mut failed, mut stopped) = (0usize, 0usize, None::<String>);
    let mut items = Vec::with_capacity(nodes.len());
    for node in &nodes {
        let (mut discovered, mut removed, mut error) = (Value::Null, BTreeSet::new(), Value::Null);
        let status = if stopped.is_some() {
            "skipped"
        } else {
            match discover(session, node, transport).await {
                Err(failure) if matches!(failure.code, "missing_secret" | "invalid") => {
                    session.log(Level::Warn, &format!("Не удалось загрузить ноду «{}»: {}", node.name, failure.message));
                    error = json!(failure.code);
                    "load_failed"
                }
                Err(failure) => {
                    session.log(Level::Warn, &format!("{}: нода недоступна, пропуск ({})", node.name, failure.message));
                    error = json!(failure.code);
                    "unreachable"
                }
                Ok(names) => {
                    discovered = json!(names);
                    match apply_discovery(session, &node.name, &names) {
                        Ok(names) => {
                            removed = names;
                            "synced"
                        }
                        Err(failure) => {
                            session.log(Level::Warn, &format!(
                                "{}: сохранение подключений не удалось; дальнейшая синхронизация остановлена.", node.name));
                            error = json!(failure.code);
                            stopped = Some(node.name.clone());
                            "save_failed"
                        }
                    }
                }
            }
        };
        match status {
            "synced" => ok += 1,
            "skipped" => {}
            _ => failed += 1,
        }
        let groups = session.state.load_config().map_or_else(|_| json!([]), |config| node_groups(&config, &node.name));
        items.push(json!({"name": node.name, "status": status, "discovered": discovered,
            "removed": removed, "groups": groups, "error": error}));
    }
    let total = nodes.len();
    let message = format!("Синхронизировано: {ok}/{total} нод");
    if failed > 0 {
        return Err(RcError::new("partial", format!("{message}."))
            .with_extra("nodes", items).with_extra("ok", ok).with_extra("failed", failed)
            .with_extra("total", total).with_extra("stopped_at", stopped));
    }
    if total > 0 {
        session.log(Level::Success, &message);
    }
    Ok(json!({"nodes": items, "ok": ok, "failed": failed, "total": total, "stopped_at": stopped}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeTransport, ScriptStep};
    use crate::model::{Auth, Client, ClientConnection, Fingerprint};
    use crate::nodes::testing::{fingerprint, invocation, session};
    use crate::nodes::{CONNECT_TIMEOUT, pin};
    use crate::transport::{ExecResult, HostKeyPolicy};

    fn fp(byte: u8) -> Fingerprint {
        use base64::Engine;
        format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode([byte; 32])).parse().unwrap()
    }

    fn node(index: u8, name: &str, auth: Auth) -> Node {
        let id = format!("{index:032x}");
        Node {
            secret_id: (auth == Auth::Password).then(|| format!("node:{id}:ssh-password")),
            id, name: name.into(), ip: format!("198.51.100.{index}"), port: 22, user: "root".into(), auth,
            identity: (auth == Auth::Key).then(|| "system".into()), tag: Some(String::new()), aliases: Default::default(),
        }
    }

    fn group(name: &str, proxies: &[&str]) -> ConnectionGroup {
        ConnectionGroup { name: name.into(), proxies: proxies.iter().map(|p| p.to_string()).collect() }
    }

    fn connect(node: &Node, outcome: Result<()>) -> ScriptStep {
        ScriptStep::connect(ConnectExpectation::new(node.ip.clone(), 22, "root", AuthMethod::System, CONNECT_TIMEOUT)
            .with_host_key(HostKeyPolicy { expected: None, known: vec![fp(node.id.as_bytes()[31])] }), outcome)
    }

    fn discover_step(stdout: &str) -> ScriptStep {
        ScriptStep::exec(DISCOVER_COMMAND, 0, COMMAND_TIMEOUT,
            Ok(ExecResult { stdout: stdout.as_bytes().to_vec(), stderr: Vec::new(), exit_status: 0 }))
    }

    fn setup(root: &std::path::Path, nodes: Vec<Node>, connections: Vec<Connection>, clients: Vec<Client>) -> Session {
        let (session, _) = session(root);
        for node in &nodes {
            pin(&session.state, &node.ip, node.port, vec![fp(node.id.as_bytes()[31])]).unwrap();
        }
        let config = Config { nodes, connections, clients, ..Config::default() };
        session.state.save_config(&config).unwrap();
        session
    }

    #[test]
    fn discovery_parses_proxy_names_only() {
        let config = "--- VLESS TCP ---\r\nService name:     vless-grpc-svc\r\nproxies:\r\n  - name: \"VLESS TCP\"\r\n    type: vless\r\n\
            --- Hysteria2 ---\nproxies:\n  - name:  \"Hysteria2\"\n    type: hysteria2\n  - {name: hy2-flow, type: hysteria2}\n\
            - name: vless-cascade [DE->RU]  # exit\n  - name: \"mixed-other\"\n--- AmneziaWG ---\n";
        assert_eq!(parse_discovered(config), ["AWG", "Hysteria2", "VLESS TCP", "hy2-flow", "vless-cascade [DE->RU]"]);
        assert!(parse_discovered("").is_empty());
        assert!(parse_discovered("  type: hysteria2\n").is_empty());
        let escaped = "  - name: \"vless \\\"q\\\" a\\\\b\\nc\"\n  - {name: 'hy2 it''s', type: hysteria2}\n  - name: \"vless-open\n";
        assert_eq!(parse_discovered(escaped), ["hy2 it's", "vless \"q\" a\\b\nc", "vless-open"]);
    }

    #[test]
    fn purge_keeps_peer_assignments_only_with_amneziawg() {
        let config = Config {
            connections: vec![Connection { node: "de".into(), groups: vec![group("PC", &["awg-alpha", "AWG", "vless"])] }],
            clients: vec![Client { name: "c1".into(), connections: Some(vec![ClientConnection {
                node: "de".into(), proxies: vec!["awg-beta".into(), "gone".into()] }]), ..Client::default() }],
            ..Config::default()
        };
        let mut with_awg = config.clone();
        let removed = purge(&mut with_awg, "de", &["AWG".into(), "vless".into()]);
        assert_eq!(removed.into_iter().collect::<Vec<_>>(), ["gone"]);
        assert_eq!(with_awg.connections[0].groups, vec![group("PC", &["awg-alpha", "AWG", "vless"])]);
        assert_eq!(with_awg.clients[0].connections.as_ref().unwrap()[0].proxies, ["awg-beta"]);
        let mut without = config;
        let removed = purge(&mut without, "de", &["vless".into()]);
        assert_eq!(removed.into_iter().collect::<Vec<_>>(), ["AWG", "awg-alpha", "awg-beta", "gone"]);
        assert_eq!(without.connections[0].groups, vec![group("PC", &["vless"])]);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_replaces_in_place_clears_and_rejects_unknown_groups() {
        let root = tempfile::tempdir().unwrap();
        let de = node(1, "de", Auth::Key);
        let mut session = setup(root.path(), vec![de.clone()], vec![Connection {
            node: "de".into(), groups: vec![group("ROUTER", &["old"]), group("PC", &["pc"])] }], vec![]);
        let data = set(&mut session, &invocation(&["conn", "set", "--name", "de", "--group", "ROUTER",
            "--group", "MOBILE", "--group", "ROUTER", "--proxy", "a", "--proxy", "b"])).unwrap();
        assert_eq!(data, json!({"node": "de", "groups": ["ROUTER", "MOBILE"], "proxies": ["a", "b"]}));
        assert_eq!(session.state.load_config().unwrap().connections[0].groups,
            vec![group("ROUTER", &["a", "b"]), group("PC", &["pc"]), group("MOBILE", &["a", "b"])]);

        set(&mut session, &invocation(&["conn", "set", "--name", "de", "--group", "ROUTER", "--group", "MOBILE"])).unwrap();
        assert_eq!(session.state.load_config().unwrap().connections[0].groups, vec![group("PC", &["pc"])]);
        set(&mut session, &invocation(&["conn", "set", "--name", "de", "--group", "PC"])).unwrap();
        assert!(session.state.load_config().unwrap().connections.is_empty());

        let before = fingerprint(root.path());
        let error = set(&mut session, &invocation(&["conn", "set", "--name", "de", "--group", "NOPE", "--proxy", "a"])).unwrap_err();
        assert_eq!((error.code, error.message.as_str()), ("not_found", "Группа «NOPE» не найдена."));
        let error = set(&mut session, &invocation(&["conn", "set", "--name", "ghost", "--group", "PC", "--proxy", "a"])).unwrap_err();
        assert_eq!(error.code, "not_found");
        let error = set(&mut session, &invocation(&["conn", "set", "--name", "de", "--group", "PC", "--proxy", "a,b"])).unwrap_err();
        assert_eq!(error.code, "invalid");
        assert_eq!(fingerprint(root.path()), before);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn sync_prunes_reachable_nodes_and_reports_partial() {
        let root = tempfile::tempdir().unwrap();
        let (de, ru, pw, empty) = (node(1, "de", Auth::Key), node(2, "ru", Auth::Key), node(3, "pw", Auth::Password), node(4, "empty", Auth::Key));
        let connections = vec![
            Connection { node: "de".into(), groups: vec![group("ROUTER", &["vless-reality", "stale-proxy"]), group("PC", &["gone"])] },
            Connection { node: "ru".into(), groups: vec![group("ROUTER", &["r1", "r2"])] },
            Connection { node: "empty".into(), groups: vec![group("PC", &["x"])] },
        ];
        let clients = vec![Client { name: "c1".into(), group: "ROUTER".into(), inherit_nodes_from_group: false,
            nodes: Some(vec!["de".into()]),
            connections: Some(vec![ClientConnection { node: "de".into(), proxies: vec!["gone".into()] },
                ClientConnection { node: "ru".into(), proxies: vec!["r1".into()] }]), ..Client::default() }];
        let mut session = setup(root.path(), vec![de.clone(), ru.clone(), pw.clone(), empty.clone()], connections, clients);
        let mut transport = FakeTransport::new([
            connect(&de, Ok(())),
            discover_step("proxies:\n  - name: \"vless-reality\"\n"),
            connect(&ru, Err(RcError::new("remote_failed", "x").with_extra("reason", "connection refused"))),
            // pw: no stored password, so no connection is attempted.
            connect(&empty, Ok(())),
            discover_step(""),
        ]);
        let error = sync(&mut session, &invocation(&["conn", "sync"]), &mut transport).await.unwrap_err();
        transport.assert_finished();
        assert_eq!((error.code, error.message.as_str()), ("partial", "Синхронизировано: 2/4 нод."));
        let statuses: Vec<&str> = error.extra["nodes"].as_array().unwrap().iter().map(|n| n["status"].as_str().unwrap()).collect();
        assert_eq!(statuses, ["synced", "unreachable", "load_failed", "synced"]);
        assert_eq!((error.extra["ok"].clone(), error.extra["failed"].clone(), error.extra["total"].clone()), (json!(2), json!(2), json!(4)));
        assert_eq!(error.extra["stopped_at"], Value::Null);
        let first = &error.extra["nodes"][0];
        assert_eq!((first["discovered"].clone(), first["removed"].clone()), (json!(["vless-reality"]), json!(["gone", "stale-proxy"])));
        assert_eq!(error.extra["nodes"][1]["discovered"], Value::Null);
        assert_eq!(error.extra["nodes"][2]["error"], "missing_secret");
        let config = session.state.load_config().unwrap();
        assert_eq!(config.connections, vec![
            Connection { node: "de".into(), groups: vec![group("ROUTER", &["vless-reality"])] },
            Connection { node: "ru".into(), groups: vec![group("ROUTER", &["r1", "r2"])] },
        ]);
        let owned = config.clients[0].connections.as_ref().unwrap();
        assert_eq!((owned[0].proxies.len(), owned[1].proxies.clone()), (0, vec!["r1".to_string()]));
        // A persisted partial checkpoints the manifest.
        assert!(session.state.paths().manifest().exists());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn sync_without_changes_writes_nothing_and_list_discovers() {
        let root = tempfile::tempdir().unwrap();
        let de = node(1, "de", Auth::Key);
        let mut session = setup(root.path(), vec![de.clone()],
            vec![Connection { node: "de".into(), groups: vec![group("ROUTER", &["vless-reality"])] }], vec![]);
        let before = fingerprint(root.path());
        let mut transport = FakeTransport::new([connect(&de, Ok(())), discover_step("  - name: \"vless-reality\"\n")]);
        let data = sync(&mut session, &invocation(&["conn", "sync", "--name", "de"]), &mut transport).await.unwrap();
        transport.assert_finished();
        assert_eq!((data["ok"].clone(), data["nodes"][0]["status"].clone()), (json!(1), json!("synced")));
        assert_eq!(fingerprint(root.path()), before);

        let error = list(&mut session, &invocation(&["conn", "list", "--discover"]), &mut FakeTransport::default()).await.unwrap_err();
        assert_eq!(error.code, "usage");
        let mut transport = FakeTransport::new([connect(&de, Ok(())),
            ScriptStep::exec(DISCOVER_COMMAND, 0, COMMAND_TIMEOUT, Ok(ExecResult { exit_status: 1, ..ExecResult::default() }))]);
        let error = list(&mut session, &invocation(&["conn", "list", "--name", "de", "--discover"]), &mut transport).await.unwrap_err();
        assert_eq!((error.code, error.message.as_str()), ("remote_failed", "Не удалось обнаружить подключения на «de»."));
        let mut transport = FakeTransport::new([connect(&de, Ok(())), discover_step("  - name: \"vless-new\"\n--- AmneziaWG ---\n")]);
        let data = list(&mut session, &invocation(&["conn", "list", "--name", "de", "--discover"]), &mut transport).await.unwrap();
        assert_eq!(data, json!([{"node": "de", "groups": [{"name": "ROUTER", "proxies": ["vless-reality"]}], "discovered": ["AWG", "vless-new"]}]));
        let error = sync(&mut session, &invocation(&["conn", "sync", "--name", "ghost"]), &mut FakeTransport::default()).await.unwrap_err();
        assert_eq!(error.code, "not_found");
    }
}
