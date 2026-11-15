//! `cascade list|add|delete`: clients of an entry node leave through another
//! managed node or an external server. The entry listener routes the cascade
//! users (`<client>--<C>`) to the `<C>-outbound` group; `node apply` renders
//! both nodes (`render.rs`).

use serde_json::{Value, json};

use crate::cli::Invocation;
use crate::clients::client::uuid_v4;
use crate::clients::generate::{effective_connections, group_connections};
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::github::random_hex;
use crate::log::Level;
use crate::model::{Cascade, CascadeExit, CascadeListener, Client, Config, ExitProxy, NodeExit, UriExit, cascade_name_reserved, cascade_user_clash};
use crate::nodes::required;
use crate::protocols::uri::parse_exit_uri;
use crate::request_input::Input;
use crate::state::State;
use crate::validation as v;

use super::keys::ensure_generated;
use super::render;

pub fn route(verb: &str, invocation: &Invocation, input: &Input, session: &mut Session) -> Result<Value> {
    match verb {
        "list" => list(session),
        "add" => add(session, invocation, input),
        "delete" => delete(session, invocation),
        _ => Err(RcError::new("usage", "Неизвестная команда.")),
    }
}

/// Connection name of the entry listener.
pub fn listener_name(listener: CascadeListener) -> &'static str {
    match listener {
        CascadeListener::VlessTcp => "VLESS TCP",
        CascadeListener::VlessXhttp => "VLESS xHTTP",
        CascadeListener::VlessGrpc => "VLESS gRPC",
        CascadeListener::Hysteria2 => "Hysteria2",
    }
}

/// Connection name of the exit node's listener.
pub fn exit_proxy_name(proxy: ExitProxy) -> &'static str {
    match proxy {
        ExitProxy::VlessTcp => "VLESS TCP",
        ExitProxy::VlessXhttp => "VLESS xHTTP",
        ExitProxy::VlessGrpc => "VLESS gRPC",
        ExitProxy::Hysteria2 => "Hysteria2",
    }
}

/// Nodes a cascade renders on: the entry, then a managed exit.
pub fn nodes(cascade: &Cascade) -> Vec<&str> {
    let mut nodes = vec![cascade.entry.as_str()];
    if let CascadeExit::Node(exit) = &cascade.exit {
        nodes.push(exit.node.as_str());
    }
    nodes
}

fn view(cascade: &Cascade) -> Value {
    let exit = match &cascade.exit {
        CascadeExit::Node(exit) => json!({"node": exit.node, "proxy": exit.proxy}),
        CascadeExit::Uri(_) => json!({"uri": true}),
    };
    json!({"name": cascade.name, "entry": cascade.entry, "listener": cascade.listener, "exit": exit})
}

fn list(session: &mut Session) -> Result<Value> {
    let config = session.state.load_config()?;
    Ok(json!({"cascades": config.cascades.iter().map(view).collect::<Vec<_>>()}))
}

fn usage(message: &str) -> RcError { RcError::new("usage", message) }

fn invalid(message: String) -> RcError { RcError::new("invalid", message) }

fn not_found(name: &str) -> RcError {
    RcError::new("not_found", format!("Каскад «{name}» не найден.")).with_extra("name", name)
}

fn node_not_found(name: &str) -> RcError {
    RcError::new("not_found", format!("Нода «{name}» не найдена.")).with_extra("name", name)
}

/// A kebab-case flag value of a serde enum.
fn parse<T: serde::de::DeserializeOwned>(value: &str, message: &str) -> Result<T> {
    serde_json::from_value(json!(value)).map_err(|_| usage(message))
}

/// The new cascade fits the configuration: free name, the entry listener
/// and the exit connection are enabled in the nodes' profiles.
fn check(config: &Config, cascade: &Cascade) -> Result<()> {
    let name = &cascade.name;
    if config.cascades.iter().any(|other| &other.name == name) {
        return Err(RcError::new("exists", format!("Каскад «{name}» уже существует.")).with_extra("name", name.as_str()));
    }
    if cascade_name_reserved(name) {
        return Err(invalid(format!("Имя каскада «{name}» занято: подключения ноды, DIRECT, REJECT, outbound, warp-wg, \
            имена «awg-…», «…-outbound» и с «--» зарезервированы.")).with_extra("name", name.as_str()));
    }
    if let Some(client) = config.clients.iter().find(|client| cascade_user_clash(&client.name, name)) {
        return Err(invalid(format!("Имя клиента «{}» совпадает с пользователем каскада «{name}».", client.name))
            .with_extra("name", client.name.as_str()));
    }
    let profiled = |node_name: &str| -> Result<Vec<String>> {
        let node = config.nodes.iter().find(|node| node.name == node_name).ok_or_else(|| node_not_found(node_name))?;
        if node.profile.is_none() {
            return Err(invalid(format!("У ноды «{node_name}» нет профиля: node profile --name {node_name} --profile P."))
                .with_extra("name", node_name));
        }
        Ok(render::proxies(config, node))
    };
    let listener = listener_name(cascade.listener);
    if !profiled(&cascade.entry)?.iter().any(|proxy| proxy == listener) {
        return Err(invalid(format!("Подключение «{listener}» не включено в профиле ноды «{}».", cascade.entry))
            .with_extra("name", cascade.entry.as_str()));
    }
    if let CascadeExit::Node(exit) = &cascade.exit {
        if exit.node == cascade.entry {
            return Err(invalid("Входная и выходная ноды каскада совпадают.".to_owned()));
        }
        let proxy = exit_proxy_name(exit.proxy);
        if !profiled(&exit.node)?.iter().any(|name| name == proxy) {
            return Err(invalid(format!("Подключение «{proxy}» не включено в профиле ноды «{}».", exit.node))
                .with_extra("name", exit.node.as_str()));
        }
    }
    Ok(())
}

fn apply_hint(session: &mut Session, cascade: &Cascade) {
    let names: Vec<String> = nodes(cascade).iter().map(|node| format!("--name {node}")).collect();
    session.log(Level::Info, &format!("Примените изменения: node apply {}", names.join(" ")));
}

/// `cascade add --name C --entry N --listener L (--exit-node M --exit-proxy P | --file PATH)`.
fn add(session: &mut Session, invocation: &Invocation, input: &Input) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let entry = required(invocation, "entry")?.to_owned();
    let listener: CascadeListener = parse(required(invocation, "listener")?,
        "Укажите --listener vless-tcp|vless-xhttp|vless-grpc|hysteria2.")?;
    if !v::name_valid(&name) {
        let config = session.state.load_config()?;
        let taken: Vec<&str> = config.cascades.iter().map(|cascade| cascade.name.as_str()).collect();
        return Err(v::name_error("каскада", &name, &taken));
    }
    let exit = match (invocation.value("exit-node"), invocation.value("exit-proxy"), input.get("file")) {
        (Some(node), Some(proxy), None) => CascadeExit::Node(NodeExit {
            node: node.to_owned(),
            proxy: parse(proxy, "Укажите --exit-proxy \"VLESS TCP\"|\"VLESS xHTTP\"|\"VLESS gRPC\"|Hysteria2.")?,
        }),
        (None, None, Some(text)) => {
            let line = text.split('\n').next().unwrap_or_default().trim();
            parse_exit_uri(&name, line).map_err(|error| invalid(error.to_string()))?;
            CascadeExit::Uri(UriExit { uri: line.to_owned() })
        }
        _ => return Err(usage("Укажите выход: --exit-node M --exit-proxy P или --file PATH.")),
    };
    let cascade = Cascade { name: name.clone(), entry, listener, exit, uuid: uuid_v4(), password: random_hex(16) };
    check(&session.state.load_config()?, &cascade)?;
    let saved = cascade.clone();
    session.mutate("cascade add", |state| {
        let mut config = state.load_config()?;
        check(&config, &saved)?;
        config.cascades.push(saved);
        ensure_generated(state, &mut config)?;
        state.save_config(&config)
    })?;
    session.log(Level::Success, &format!("Каскад «{name}» добавлен"));
    apply_hint(session, &cascade);
    Ok(view(&cascade))
}

/// The configuration without the cascade: its name leaves the entry node's
/// group and client selections. A group left without connections there is
/// unassigned from the node (as `conn set --assign G=`), not kept empty — an
/// empty group selection would give its clients every connection of the node.
fn deleted(config: &Config, cascade: &Cascade) -> Config {
    let mut config = config.clone();
    config.cascades.retain(|other| other.name != cascade.name);
    for connection in config.connections.iter_mut().filter(|connection| connection.node == cascade.entry) {
        connection.groups.retain_mut(|group| {
            let used = group.proxies.contains(&cascade.name);
            group.proxies.retain(|proxy| *proxy != cascade.name);
            !used || !group.proxies.is_empty()
        });
    }
    config.connections.retain(|connection| connection.node != cascade.entry || !connection.groups.is_empty());
    for client in &mut config.clients {
        for connection in client.connections.iter_mut().flatten().filter(|connection| connection.node == cascade.entry) {
            connection.proxies.retain(|proxy| *proxy != cascade.name);
        }
    }
    config
}

/// Whether the client's configuration includes the node (`node_users`).
fn on_node(config: &Config, client: &Client, node: &str) -> bool {
    if client.inherit_nodes_from_group {
        config.connections.iter().any(|c| c.node == node && c.groups.iter().any(|group| group.name == client.group))
    } else {
        client.nodes.iter().flatten().any(|name| name == node)
    }
}

/// `cascade delete` plan: the cascade instance (its uuid, new on every `add`,
/// is the token extra) and every selection on the entry node that loses it.
/// A client still on the node whose selection ends up empty gets every
/// connection of the node — the plan says so explicitly.
fn delete_plan(config: &Config, name: &str) -> Result<(Plan, Cascade)> {
    let cascade = config.cascades.iter().find(|cascade| cascade.name == name).ok_or_else(|| not_found(name))?.clone();
    let after = deleted(config, &cascade);
    let entry = cascade.entry.as_str();
    let exit = match &cascade.exit {
        CascadeExit::Node(exit) => format!("нода «{}» ({})", exit.node, exit_proxy_name(exit.proxy)),
        CascadeExit::Uri(_) => "внешний сервер по ссылке".to_owned(),
    };
    let mut lines = vec![format!("Каскад «{name}» будет удалён: вход — нода «{entry}» ({}), выход — {exit}.", listener_name(cascade.listener))];
    let mut groups: Vec<&str> = Vec::new();
    for group in config.connections.iter().filter(|c| c.node == entry).flat_map(|c| &c.groups) {
        if group.proxies.contains(&cascade.name) && !groups.contains(&group.name.as_str()) {
            groups.push(&group.name);
        }
    }
    for group in groups {
        let unassigned = !after.connections.iter().any(|c| c.node == entry && c.groups.iter().any(|g| g.name == group));
        lines.push(if unassigned {
            format!("Группа «{group}»: других подключений на ноде «{entry}» нет — назначение группы ноде будет снято.")
        } else {
            format!("Группа «{group}»: подключение «{name}» на ноде «{entry}» будет снято; останутся: {}.",
                group_connections(&after, group, entry).join(", "))
        });
    }
    // `deleted` keeps the clients in order: `remaining` is `client` after the deletion.
    for (client, remaining) in config.clients.iter().zip(&after.clients) {
        if client.connections.iter().flatten().any(|c| c.node == entry && c.proxies.contains(&cascade.name)) {
            lines.push(format!("Клиент «{}»: подключение «{name}» на ноде «{entry}» будет снято.", client.name));
        }
        if effective_connections(config, client, entry).contains(&cascade.name)
            && on_node(&after, remaining, entry)
            && effective_connections(&after, remaining, entry).is_empty()
        {
            lines.push(format!("Клиент «{}» останется без выбранных подключений на ноде «{entry}» и получит все её подключения.",
                client.name));
        }
    }
    Ok((Plan::new(lines, cascade.uuid.clone()), cascade))
}

/// Under the lock: the plan rebuilt from the current state must be the
/// confirmed one (a cascade re-created under the same name differs by its
/// uuid). Returns the deleted cascade.
fn delete_planned(state: &State, name: &str, planned: &Plan, invocation: &Invocation) -> Result<Cascade> {
    let config = state.load_config()?;
    let (plan, cascade) = delete_plan(&config, name)?;
    if plan.lines != planned.lines || plan.extra != planned.extra {
        return Err(plan.changed(invocation));
    }
    state.save_config(&deleted(&config, &cascade))?;
    Ok(cascade)
}

fn delete(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let (plan, _) = delete_plan(&session.state.load_config()?, &name)?;
    plan.confirm(invocation)?;
    let cascade = session.mutate("cascade delete", |state| delete_planned(state, &name, &plan, invocation))?;
    session.log(Level::Success, &format!("Каскад «{name}» удалён"));
    apply_hint(session, &cascade);
    Ok(view(&cascade))
}

#[cfg(test)]
mod tests;
