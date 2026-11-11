//! Client, group and template domain (plan step 7): port of `groups.sh`,
//! `templates.sh`, `clients.sh` and their `cmd_clients.sh` handlers. Every
//! state change goes through `Session::mutate`; server effects (AmneziaWG
//! clients, listener users, subscriptions) go through the generate, awg and
//! subscription domains over `RemoteTransport`.

pub mod client;
pub mod generate;
pub mod groups;
pub mod templates;

use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::cli::Invocation;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::model::{Client, Config, Group};
use crate::request_secrets::Secrets;
use crate::state::StatePaths;
use crate::transport::RemoteTransport;

/// Dispatch of the domain's commands; `connect` creates a fresh transport per node.
pub async fn route<T: RemoteTransport>(noun: &str, verb: &str, invocation: &Invocation, _secrets: &Secrets,
    session: &mut Session, connect: &dyn Fn() -> T) -> Result<Value>
{
    match (noun, verb) {
        ("generate", _) => generate::generate(session, invocation, connect).await,
        ("group", "list") => groups::list(session),
        ("group", "add") => groups::add(session, invocation),
        ("group", "delete") => groups::delete(session, invocation),
        ("group", "set-template") => groups::set_template(session, invocation),
        ("template", "list") => templates::list_command(session),
        ("template", "show") => templates::show(session, invocation),
        ("template", "create") => templates::create(session, invocation),
        ("template", "export") => templates::export(session, invocation),
        ("template", "import") => templates::import(session, invocation),
        ("client", "list") => client::list(session, invocation),
        ("client", "show") => client::show(session, invocation),
        ("client", "connections") => client::connections(session, invocation),
        ("client", "add") => client::add(session, invocation),
        ("client", "rename") => client::rename(session, invocation, connect).await,
        ("client", "nodes") => client::nodes(session, invocation),
        ("client", "set-group") => client::set_group(session, invocation, connect).await,
        ("client", "delete") => client::delete(session, invocation, connect).await,
        _ => Err(RcError::new("usage", "Неизвестная команда.")),
    }
}

pub fn group_not_found(name: &str) -> RcError {
    RcError::new("not_found", format!("Группа «{name}» не найдена.")).with_extra("name", name)
}

pub fn client_not_found(name: &str) -> RcError {
    RcError::new("not_found", format!("Клиент «{name}» не найден.")).with_extra("name", name)
}

pub fn find_group<'a>(config: &'a Config, name: &str) -> Result<&'a Group> {
    config.groups.iter().find(|group| group.name == name).ok_or_else(|| group_not_found(name))
}

pub fn find_client<'a>(config: &'a Config, name: &str) -> Result<&'a Client> {
    config.clients.iter().find(|client| client.name == name).ok_or_else(|| client_not_found(name))
}

/// v1 `_group_nodes_csv`: nodes with a connection assigned to the group, sorted, unique.
pub fn group_nodes(config: &Config, group: &str) -> Vec<String> {
    let mut nodes: Vec<String> = config.connections.iter()
        .filter(|connection| connection.groups.iter().any(|g| g.name == group))
        .map(|connection| connection.node.clone()).collect();
    nodes.sort();
    nodes.dedup();
    nodes
}

/// v1 `_collect_client_nodes`: the group's nodes or the client's own list.
pub fn client_nodes(config: &Config, client: &Client) -> Vec<String> {
    if client.inherit_nodes_from_group {
        group_nodes(config, &client.group)
    } else {
        client.nodes.clone().unwrap_or_default()
    }
}

fn is_awg(proxy: &str) -> bool {
    proxy == "AWG" || proxy.starts_with("awg-")
}

/// v1 `_client_awg_nodes`: the client's nodes (for `group` instead of its
/// current group) where its own or the group's connections include AmneziaWG.
pub fn client_awg_nodes(config: &Config, client: &Client, group: Option<&str>) -> Vec<String> {
    let group = group.unwrap_or(&client.group);
    let nodes = if client.inherit_nodes_from_group { group_nodes(config, group) } else { client.nodes.clone().unwrap_or_default() };
    nodes.into_iter().filter(|node| {
        let own = client.connections.iter().flatten().filter(|c| &c.node == node).flat_map(|c| &c.proxies);
        let shared = config.connections.iter().filter(|c| &c.node == node)
            .flat_map(|c| &c.groups).filter(|g| g.name == group).flat_map(|g| &g.proxies);
        own.chain(shared).any(|proxy| is_awg(proxy))
    }).collect()
}

/// v1 `_awg_capable_nodes`: configured nodes (in order) where any group or
/// client connection includes AmneziaWG.
pub fn awg_capable_nodes(config: &Config) -> Vec<String> {
    config.nodes.iter().map(|node| &node.name).filter(|name| {
        config.connections.iter().filter(|c| &c.node == *name).flat_map(|c| &c.groups).flat_map(|g| &g.proxies)
            .chain(config.clients.iter().flat_map(|c| c.connections.iter().flatten())
                .filter(|c| &c.node == *name).flat_map(|c| &c.proxies))
            .any(|proxy| is_awg(proxy))
    }).cloned().collect()
}

/// `<generated>/<group>/<client>`; invalid stored names → `invalid`.
pub fn client_dir(paths: &StatePaths, client: &Client) -> Result<PathBuf> {
    let file = generate::client_config_path(paths, client)?;
    Ok(file.parent().expect("a client config has a directory").to_path_buf())
}

/// The directory entry exists (a dangling symlink counts).
pub fn entry_exists(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error.into()),
    }
}

/// v1 `_generated_path_safe`: the physical parent of `path` lies inside the
/// physical generated directory (names are validated, so `.`/`..` cannot occur).
pub fn generated_path_safe(paths: &StatePaths, path: &Path) -> bool {
    let root = generate::generated_dir(paths);
    let (Ok(root), Some(parent)) = (fs::canonicalize(root), path.parent()) else { return false };
    fs::canonicalize(parent).is_ok_and(|parent| parent.starts_with(&root)) && path.starts_with(generate::generated_dir(paths))
}

pub fn generated_guard(paths: &StatePaths, path: &Path) -> Result<()> {
    if generated_path_safe(paths, path) { return Ok(()); }
    Err(RcError::new("invalid", format!("Каталог «{}» вне каталога сгенерированных конфигов — операция отменена.", path.display())))
}

/// Remove a client directory without following a symlinked entry.
pub fn remove_entry(path: &Path) -> std::io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

/// `" name  ip:port"` review line of a node (or «не найдена»).
pub fn node_line(config: &Config, name: &str) -> String {
    match config.nodes.iter().find(|node| node.name == name) {
        Some(node) => format!(" {name}  {}:{}", node.ip, node.port),
        None => format!(" {name}  не найдена"),
    }
}

/// Unique non-empty values of a repeatable flag, in order (v1 `_cli_unique_lines`).
pub fn unique_values(invocation: &Invocation, flag: &str) -> Vec<String> {
    let mut values: Vec<String> = Vec::new();
    for value in invocation.values(flag) {
        if !value.is_empty() && !values.contains(value) {
            values.push(value.clone());
        }
    }
    values
}

/// Exactly one of the flags (v1 `cli_require_one`).
pub fn require_one(invocation: &Invocation, flags: &[&str]) -> Result<()> {
    if flags.iter().filter(|flag| invocation.has(flag)).count() == 1 { return Ok(()); }
    let list = flags.iter().map(|flag| format!("--{flag}")).collect::<Vec<_>>().join(" | ");
    Err(RcError::new("usage", format!("Укажите ровно один из флагов: {list}.")))
}

#[cfg(test)]
pub(crate) mod testing {
    //! Fixture shaped like the v1 BATS config: two nodes, ROUTER/PC clients.
    use crate::model::*;

    pub fn node(index: u8, name: &str, ip: &str, port: u16) -> Node {
        Node {
            id: format!("{index:032x}"), name: name.into(), ip: ip.into(), port, user: "root".into(),
            auth: Auth::Key, identity: None, secret_id: None, tag: None, aliases: Default::default(),
        }
    }

    pub fn config() -> Config {
        Config {
            nodes: vec![node(1, "de-vps", "1.2.3.4", 22), node(2, "ru-vps", "5.6.7.8", 2222)],
            connections: vec![
                Connection { node: "de-vps".into(), groups: vec![
                    ConnectionGroup { name: "PC".into(), proxies: vec!["vless-reality".into()] }] },
                Connection { node: "ru-vps".into(), groups: vec![
                    ConnectionGroup { name: "ROUTER".into(), proxies: vec!["vless-reality".into()] }] },
            ],
            clients: vec![
                Client {
                    name: "my-router".into(), group: "ROUTER".into(),
                    credentials: Some(ClientCredentials { vless_uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".into(), hy2_password: "router-hy2-pass-0001".into() }),
                    ..Client::default()
                },
                Client {
                    name: "my-pc".into(), group: "PC".into(), inherit_nodes_from_group: false,
                    nodes: Some(vec!["de-vps".into()]),
                    connections: Some(vec![ClientConnection { node: "de-vps".into(), proxies: vec!["vless-reality".into()] }]),
                    credentials: Some(ClientCredentials { vless_uuid: "11111111-2222-3333-4444-555555555555".into(), hy2_password: "pc-hy2-pass-0002".into() }),
                    ..Client::default()
                },
            ],
            ..Config::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::testing::config;

    #[test]
    fn effective_and_amneziawg_nodes() {
        let mut config = config();
        assert_eq!(group_nodes(&config, "ROUTER"), ["ru-vps"]);
        assert_eq!(client_nodes(&config, &config.clients[0]), ["ru-vps"]);
        assert_eq!(client_nodes(&config, &config.clients[1]), ["de-vps"]);
        assert!(awg_capable_nodes(&config).is_empty());
        config.connections[1].groups[0].proxies = vec!["AWG".into()];
        assert_eq!(client_awg_nodes(&config, &config.clients[0], None), ["ru-vps"]);
        assert!(client_awg_nodes(&config, &config.clients[0], Some("PC")).is_empty());
        config.clients[1].connections = Some(vec![crate::model::ClientConnection { node: "de-vps".into(), proxies: vec!["awg-x".into()] }]);
        assert_eq!(awg_capable_nodes(&config), ["de-vps", "ru-vps"]);
        assert_eq!(client_awg_nodes(&config, &config.clients[1], None), ["de-vps"]);
    }

    #[test]
    fn generated_paths_stay_physically_inside() {
        let root = tempfile::tempdir().unwrap();
        let paths = StatePaths::new(root.path());
        let generated = generate::generated_dir(&paths);
        fs::create_dir_all(generated.join("PC/c")).unwrap();
        let outside = root.path().join("outside");
        fs::create_dir_all(outside.join("c")).unwrap();
        assert!(generated_path_safe(&paths, &generated.join("PC/c")));
        assert!(generated_path_safe(&paths, &generated.join("PC/new")));
        assert!(!generated_path_safe(&paths, &outside.join("c")));
        assert!(!generated_path_safe(&paths, &generated.join("MISSING/c")));
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&outside, generated.join("LINK")).unwrap();
            assert!(!generated_path_safe(&paths, &generated.join("LINK/c")));
        }
    }
}
