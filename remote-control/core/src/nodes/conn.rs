//! `conn list|set|sync`: per-group proxy assignments of nodes (port of
//! `connections.sh`). The connections a node offers come from its profile
//! and cascades (`render::proxies`); they are authoritative for pruning and
//! never add assignments.

use std::collections::BTreeSet;

use serde_json::{json, Value};

use super::{find, required};
use crate::cli::Invocation;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::model::{Config, Connection, ConnectionGroup, Node};

/// Connection names the node offers: its profile's protocols and cascades.
pub(crate) fn discover(config: &Config, node: &Node) -> Vec<String> {
    crate::server::render::proxies(config, node)
}

/// The node's groups, each once (in order of first mention) with the union of
/// its proxies over every entry of the node, each proxy once — the set
/// `conn set` compares and generation uses.
fn node_groups(config: &Config, node: &str) -> Value {
    let mut groups: Vec<ConnectionGroup> = Vec::new();
    for group in config.connections.iter().filter(|connection| connection.node == node).flat_map(|connection| &connection.groups) {
        let index = match groups.iter().position(|seen| seen.name == group.name) {
            Some(index) => index,
            None => { groups.push(ConnectionGroup { name: group.name.clone(), proxies: Vec::new() }); groups.len() - 1 }
        };
        for proxy in &group.proxies {
            if !groups[index].proxies.contains(proxy) { groups[index].proxies.push(proxy.clone()); }
        }
    }
    json!(groups)
}

/// Order-preserving unique non-empty values.
fn unique(values: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    values.iter().filter(|value| !value.is_empty() && seen.insert(value.as_str())).cloned().collect()
}

pub fn list(session: &mut Session, invocation: &Invocation) -> Result<Value> {
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
        let discovered = discover(&config, node);
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

/// Proxies of `group` on `node` as a set; `None` — the node has no entry
/// for the group at all (an entry with no proxies is still an assignment:
/// `group_nodes` counts it, so `G=` must remove it).
fn assigned(config: &Config, node: &str, group: &str) -> Option<BTreeSet<String>> {
    let mut entries = config.connections.iter().filter(|connection| connection.node == node)
        .flat_map(|connection| &connection.groups)
        .filter(|existing| existing.name == group)
        .peekable();
    entries.peek()?;
    Some(entries.flat_map(|existing| existing.proxies.iter().cloned()).collect())
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
        .filter(|(group, proxies)| assigned(config, node, group) != (!proxies.is_empty()).then(|| proxies.iter().cloned().collect()))
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

pub fn sync(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let only = match invocation.has("name") {
        true => Some(required(invocation, "name")?.to_owned()),
        false => None,
    };
    let config = session.state.load_config()?;
    if let Some(only) = &only {
        find(&config, only)?;
    }
    let nodes: Vec<&Node> = config.nodes.iter()
        .filter(|node| only.as_ref().is_none_or(|only| *only == node.name)).collect();
    let (mut ok, mut failed, mut stopped) = (0usize, 0usize, None::<String>);
    let mut items = Vec::with_capacity(nodes.len());
    for node in &nodes {
        let (mut discovered, mut removed, mut error) = (Value::Null, BTreeSet::new(), Value::Null);
        let status = if stopped.is_some() {
            "skipped"
        } else {
            let names = discover(&config, node);
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
    use crate::model::{Auth, Client, ClientConnection};
    use crate::nodes::testing::{fingerprint, invocation, session};

    fn node(index: u8, name: &str, auth: Auth) -> Node {
        let id = format!("{index:032x}");
        Node {
            secret_id: (auth == Auth::Password).then(|| format!("node:{id}:ssh-password")),
            id, name: name.into(), ip: format!("198.51.100.{index}"), port: 22, user: "root".into(), auth,
            identity: (auth == Auth::Key).then(|| "system".into()), tag: Some(String::new()), aliases: Default::default(),
            ..Node::default()
        }
    }

    fn group(name: &str, proxies: &[&str]) -> ConnectionGroup {
        ConnectionGroup { name: name.into(), proxies: proxies.iter().map(|p| p.to_string()).collect() }
    }

    fn setup(root: &std::path::Path, nodes: Vec<Node>, connections: Vec<Connection>, clients: Vec<Client>) -> Session {
        let (session, _) = session(root);
        let profiles = vec![crate::model::test_profile("main")];
        let config = Config { nodes, connections, clients, profiles, ..Config::default() };
        session.state.save_config(&config).unwrap();
        session
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

    #[test]
    fn a_proxy_repeated_across_entries_is_one_assignment() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = session(root.path());
        let mut config = session.state.load_config().unwrap();
        config.nodes = vec![node(1, "de", Auth::Key)];
        config.connections = vec![
            Connection { node: "de".into(), groups: vec![group("PC", &["vless-reality"])] },
            Connection { node: "de".into(), groups: vec![group("PC", &["vless-reality", "hy2"]), group("ROUTER", &["r"])] },
        ];
        config.validate().unwrap();
        session.state.save_config(&config).unwrap();
        // Views see each group once with each proxy once.
        assert_eq!(node_groups(&config, "de"), json!([{"name": "PC", "proxies": ["vless-reality", "hy2"]}, {"name": "ROUTER", "proxies": ["r"]}]));
        // The same set: nothing to change (generation reads the union once).
        let before = fingerprint(root.path());
        let unchanged = set(&mut session, &invocation(&["conn", "set", "--name", "de", "--assign", "PC=hy2", "--assign", "PC=vless-reality"])).unwrap();
        assert_eq!(unchanged["changed"], json!([]));
        assert_eq!(fingerprint(root.path()), before);
    }

    #[test]
    fn set_unassign_removes_an_entry_without_proxies() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = session(root.path());
        let mut config = session.state.load_config().unwrap();
        config.nodes = vec![node(1, "de", Auth::Key)];
        config.connections = vec![Connection { node: "de".into(), groups: vec![group("PC", &[]), group("ROUTER", &["r"])] }];
        session.state.save_config(&config).unwrap();
        let run = |session: &mut Session, assign: &str| set(session, &invocation(&["conn", "set", "--name", "de", "--assign", assign])).unwrap();
        // The empty entry still assigns the node to PC: `PC=` removes it.
        assert_eq!(run(&mut session, "PC=")["changed"], json!([{"group": "PC", "proxies": []}]));
        assert_eq!(session.state.load_config().unwrap().connections[0].groups, vec![group("ROUTER", &["r"])]);
        assert_eq!(journal.borrow().last().unwrap().1, "de -> PC: назначение снято");
        // No entry at all: nothing to change, no write.
        let before = fingerprint(root.path());
        assert_eq!(run(&mut session, "PC=")["changed"], json!([]));
        assert_eq!(fingerprint(root.path()), before);
    }

    #[test]
    fn sync_prunes_connections_the_profiles_no_longer_offer() {
        let root = tempfile::tempdir().unwrap();
        let (mut de, ru) = (node(1, "de", Auth::Key), node(2, "ru", Auth::Key));
        de.profile = Some("main".into());
        de.domain = Some("de.example.com".into());
        let connections = vec![
            Connection { node: "de".into(), groups: vec![group("ROUTER", &["VLESS TCP", "stale-proxy"]), group("PC", &["gone"])] },
            Connection { node: "ru".into(), groups: vec![group("ROUTER", &["r1"])] },
        ];
        let clients = vec![Client { name: "c1".into(), group: "ROUTER".into(), inherit_nodes_from_group: false,
            nodes: Some(vec!["de".into()]),
            connections: Some(vec![ClientConnection { node: "de".into(), proxies: vec!["gone".into()] },
                ClientConnection { node: "ru".into(), proxies: vec!["r1".into()] }]), ..Client::default() }];
        let mut session = setup(root.path(), vec![de, ru], connections, clients);
        let data = sync(&mut session, &invocation(&["conn", "sync"])).unwrap();
        assert_eq!((data["ok"].clone(), data["failed"].clone(), data["total"].clone()), (json!(2), json!(0), json!(2)));
        let first = &data["nodes"][0];
        assert_eq!((first["discovered"].clone(), first["removed"].clone()), (json!(["VLESS TCP"]), json!(["gone", "stale-proxy"])));
        assert_eq!(data["nodes"][1]["removed"], json!(["r1"]), "a node without a profile offers nothing");
        let config = session.state.load_config().unwrap();
        assert_eq!(config.connections, vec![Connection { node: "de".into(), groups: vec![group("ROUTER", &["VLESS TCP"])] }]);
        let owned = config.clients[0].connections.as_ref().unwrap();
        assert_eq!((owned[0].proxies.len(), owned[1].proxies.len()), (0, 0));

        let before = fingerprint(root.path());
        let data = sync(&mut session, &invocation(&["conn", "sync", "--name", "de"])).unwrap();
        assert_eq!((data["ok"].clone(), data["nodes"][0]["status"].clone()), (json!(1), json!("synced")));
        assert_eq!(fingerprint(root.path()), before, "nothing to prune, nothing written");

        assert_eq!(list(&mut session, &invocation(&["conn", "list", "--discover"])).unwrap_err().code, "usage");
        let data = list(&mut session, &invocation(&["conn", "list", "--name", "de", "--discover"])).unwrap();
        assert_eq!(data, json!([{"node": "de", "groups": [{"name": "ROUTER", "proxies": ["VLESS TCP"]}], "discovered": ["VLESS TCP"]}]));
        assert_eq!(sync(&mut session, &invocation(&["conn", "sync", "--name", "ghost"])).unwrap_err().code, "not_found");
    }
}
