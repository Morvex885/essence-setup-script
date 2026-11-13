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

/// Replace the proxies of `group` in the node's assignment (in place, a new
/// group appended); without proxies the group is unassigned.
fn assign(config: &mut Config, node: &str, group: &str, proxies: &[String]) {
    let mut first = true;
    for connection in config.connections.iter_mut().filter(|connection| connection.node == node) {
        if first && !proxies.is_empty() {
            match connection.groups.iter_mut().find(|existing| existing.name == group) {
                Some(existing) => existing.proxies = proxies.to_vec(),
                None => connection.groups.push(ConnectionGroup { name: group.to_owned(), proxies: proxies.to_vec() }),
            }
        } else {
            connection.groups.retain(|existing| existing.name != group);
        }
        first = false;
    }
    if first && !proxies.is_empty() {
        config.connections.push(Connection {
            node: node.to_owned(),
            groups: vec![ConnectionGroup { name: group.to_owned(), proxies: proxies.to_vec() }],
        });
    }
    config.connections.retain(|connection| connection.node != node || !connection.groups.is_empty());
}

/// Proxies of `group` on `node` as a set.
fn assigned(config: &Config, node: &str, group: &str) -> BTreeSet<String> {
    config.connections.iter().filter(|connection| connection.node == node)
        .flat_map(|connection| &connection.groups)
        .filter(|existing| existing.name == group)
        .flat_map(|existing| existing.proxies.iter().cloned()).collect()
}

/// `--assign G=P` values, one proxy per flag (a proxy name may hold any
/// character, commas included): (group, unique proxies in order) per group
/// in order of first mention; `G=` — none. `G=` together with `G=P` is
/// ambiguous — `usage`.
fn assignments(invocation: &Invocation) -> Result<Vec<(String, Vec<String>)>> {
    if !invocation.has("assign") {
        return Err(RcError::new("usage", "Укажите --assign ГРУППА=ПОДКЛЮЧЕНИЕ."));
    }
    // (group, proxies, unassigned with `G=`)
    let mut parsed: Vec<(String, Vec<String>, bool)> = Vec::new();
    for value in invocation.values("assign") {
        let Some((group, proxy)) = value.split_once('=').filter(|(group, _)| !group.is_empty()) else {
            return Err(RcError::new("invalid", format!("Назначение «{value}»: нужно ГРУППА=ПОДКЛЮЧЕНИЕ.")));
        };
        let index = match parsed.iter().position(|(seen, ..)| seen == group) {
            Some(index) => index,
            None => { parsed.push((group.to_owned(), Vec::new(), false)); parsed.len() - 1 }
        };
        let entry = &mut parsed[index];
        if proxy.is_empty() { entry.2 = true; } else { entry.1.push(proxy.to_owned()); }
        if entry.2 && !entry.1.is_empty() {
            return Err(RcError::new("usage", format!("Группа «{group}»: --assign {group}= снимает назначение и не сочетается с {group}=ПОДКЛЮЧЕНИЕ.")));
        }
    }
    Ok(parsed.into_iter().map(|(group, proxies, _)| (group, unique(&proxies))).collect())
}

/// The assignments that differ from the state (as sets of proxies); the node
/// and every group must exist.
fn changed_assignments(config: &Config, node: &str, wanted: &[(String, Vec<String>)]) -> Result<Vec<(String, Vec<String>)>> {
    find(config, node)?;
    if let Some((group, _)) = wanted.iter().find(|(group, _)| !config.groups.iter().any(|known| known.name == *group)) {
        return Err(RcError::new("not_found", format!("Группа «{group}» не найдена.")).with_extra("group", group.clone()));
    }
    Ok(wanted.iter()
        .filter(|(group, proxies)| assigned(config, node, group) != proxies.iter().cloned().collect())
        .cloned().collect())
}

/// `conn set --name N --assign G=P…`: each listed group gets exactly its
/// proxies on the node (`G=` unassigns); other groups stay. A group whose
/// proxies are already the same set is unchanged; nothing changed — no
/// mutation (no checkpoint, no GitHub commit).
pub fn set(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let node = required(invocation, "name")?.to_owned();
    let wanted = assignments(invocation)?;
    let mut changed = changed_assignments(&session.state.load_config()?, &node, &wanted)?;
    if !changed.is_empty() {
        changed = session.mutate("assign_connections", |state| {
            let mut config = state.load_config()?;
            let changed = changed_assignments(&config, &node, &wanted)?;
            for (group, proxies) in &changed {
                assign(&mut config, &node, group, proxies);
            }
            state.save_config(&config)?;
            Ok(changed)
        })?;
    }
    for (group, proxies) in &changed {
        let text = if proxies.is_empty() { format!("{node} -> {group}: назначение снято") } else { format!("{node} -> {group} сохранено") };
        session.log(Level::Success, &text);
    }
    Ok(json!({
        "node": node,
        "changed": changed.iter().map(|(group, proxies)| json!({"group": group, "proxies": proxies})).collect::<Vec<_>>(),
    }))
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

    #[test]
    fn set_assigns_exact_lists_per_group_and_changes_only_what_differs() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = session(root.path());
        let mut config = session.state.load_config().unwrap();
        config.nodes = vec![node(1, "de", Auth::Key)];
        config.connections = vec![Connection { node: "de".into(), groups: vec![group("ROUTER", &["old"]), group("PC", &["pc", "x"])] }];
        session.state.save_config(&config).unwrap();
        let run = |session: &mut Session, assign: &[&str]| {
            let mut argv = vec!["conn", "set", "--name", "de"];
            for value in assign { argv.extend(["--assign", value]); }
            set(session, &invocation(&argv))
        };
        // ROUTER replaced in place, MOBILE appended (deduped, in order), PC
        // the same set in another order: unchanged and not reported.
        let data = run(&mut session, &["ROUTER=b", "MOBILE=a", "ROUTER=a", "MOBILE=b", "MOBILE=a", "PC=x", "PC=pc"]).unwrap();
        assert_eq!(data, json!({"node": "de", "changed": [
            {"group": "ROUTER", "proxies": ["b", "a"]}, {"group": "MOBILE", "proxies": ["a", "b"]}]}));
        assert_eq!(session.state.load_config().unwrap().connections[0].groups,
            vec![group("ROUTER", &["b", "a"]), group("PC", &["pc", "x"]), group("MOBILE", &["a", "b"])]);
        let logged: Vec<String> = journal.borrow().iter().map(|(_, text)| text.clone()).collect();
        assert_eq!(logged, ["de -> ROUTER сохранено", "de -> MOBILE сохранено"]);

        // Every group sent again, nothing different: no write at all.
        let before = fingerprint(root.path());
        let data = run(&mut session, &["ROUTER=a", "ROUTER=b", "MOBILE=b", "MOBILE=a", "PC=pc", "PC=x"]).unwrap();
        assert_eq!(data, json!({"node": "de", "changed": []}));
        assert_eq!(fingerprint(root.path()), before);
        assert_eq!(journal.borrow().len(), 2);

        // `G=` unassigns; groups not mentioned stay.
        run(&mut session, &["ROUTER=", "MOBILE="]).unwrap();
        assert_eq!(session.state.load_config().unwrap().connections[0].groups, vec![group("PC", &["pc", "x"])]);
        assert_eq!(journal.borrow().last().unwrap().1, "de -> MOBILE: назначение снято");
        run(&mut session, &["PC=", "PC="]).unwrap();
        assert!(session.state.load_config().unwrap().connections.is_empty());

        // A proxy name with a comma (or `=`) stays one proxy.
        let data = run(&mut session, &["PC=vless,backup", "PC=a=b"]).unwrap();
        assert_eq!(data["changed"], json!([{"group": "PC", "proxies": ["vless,backup", "a=b"]}]));
        assert_eq!(session.state.load_config().unwrap().connections[0].groups, vec![group("PC", &["vless,backup", "a=b"])]);

        let before = fingerprint(root.path());
        let error = run(&mut session, &["PC=a", "NOPE=a"]).unwrap_err();
        assert_eq!((error.code, error.message.as_str(), error.extra["group"].clone()), ("not_found", "Группа «NOPE» не найдена.", json!("NOPE")));
        let error = set(&mut session, &invocation(&["conn", "set", "--name", "ghost", "--assign", "PC=a"])).unwrap_err();
        assert_eq!(error.code, "not_found");
        for bad in [&["PC"][..], &["=a"]] {
            assert_eq!(run(&mut session, bad).unwrap_err().code, "invalid", "{bad:?}");
        }
        for bad in [&["PC=a", "PC="][..], &["PC=", "PC=a"]] {
            assert_eq!(run(&mut session, bad).unwrap_err().code, "usage", "{bad:?}");
        }
        assert_eq!(set(&mut session, &invocation(&["conn", "set", "--name", "de"])).unwrap_err().code, "usage");
        assert_eq!(fingerprint(root.path()), before);
    }

    #[test]
    fn set_reads_a_group_from_every_entry_of_the_node() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = session(root.path());
        let mut config = session.state.load_config().unwrap();
        config.nodes = vec![node(1, "de", Auth::Key)];
        config.connections = vec![
            Connection { node: "de".into(), groups: vec![group("PC", &["p1"])] },
            Connection { node: "de".into(), groups: vec![group("PC", &["p2"]), group("ROUTER", &["r"])] },
        ];
        session.state.save_config(&config).unwrap();
        let run = |session: &mut Session, assign: &[&str]| {
            let mut argv = vec!["conn", "set", "--name", "de"];
            for value in assign { argv.extend(["--assign", value]); }
            set(session, &invocation(&argv)).unwrap()
        };
        // The union of both entries is the group's set: nothing changed.
        let before = fingerprint(root.path());
        assert_eq!(run(&mut session, &["PC=p2", "PC=p1"])["changed"], json!([]));
        assert_eq!(fingerprint(root.path()), before);
        // A new set lands in the first entry and leaves the second.
        run(&mut session, &["PC=p1", "PC=p2", "PC=p3"]);
        let connections = session.state.load_config().unwrap().connections;
        assert_eq!(connections[0].groups, vec![group("PC", &["p1", "p2", "p3"])]);
        assert_eq!(connections[1].groups, vec![group("ROUTER", &["r"])]);
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
