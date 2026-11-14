//! `cascade list|add|delete`: clients of an entry node leave through another
//! managed node or an external server. The entry listener routes the cascade
//! users (`<client>--<C>`) to the `<C>-outbound` group; `node apply` renders
//! both nodes (`render.rs`).

use serde_json::{Value, json};

use crate::cli::Invocation;
use crate::clients::client::uuid_v4;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::github::random_hex;
use crate::log::Level;
use crate::model::{Cascade, CascadeExit, CascadeListener, Config, ExitProxy, NodeExit, UriExit, CONNECTION_NAMES};
use crate::nodes::required;
use crate::protocols::uri::parse_proxy_uri;
use crate::request_input::Input;
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
    if CONNECTION_NAMES.contains(&name.as_str()) {
        return Err(invalid(format!("Имя каскада «{name}» совпадает с именем подключения ноды.")));
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
        return Err(invalid(format!("Недопустимое имя каскада «{name}»: латиница, цифры, «.», «_», «-».")));
    }
    let exit = match (invocation.value("exit-node"), invocation.value("exit-proxy"), input.get("file")) {
        (Some(node), Some(proxy), None) => CascadeExit::Node(NodeExit {
            node: node.to_owned(),
            proxy: parse(proxy, "Укажите --exit-proxy \"VLESS TCP\"|\"VLESS xHTTP\"|\"VLESS gRPC\"|Hysteria2.")?,
        }),
        (None, None, Some(text)) => {
            let line = text.split('\n').next().unwrap_or_default().trim();
            parse_proxy_uri(&name, line).map_err(|error| invalid(error.to_string()))?;
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

/// Removes the cascade name from the entry node's group and client connections.
fn unassign(config: &mut Config, cascade: &Cascade) {
    for connection in config.connections.iter_mut().filter(|connection| connection.node == cascade.entry) {
        connection.groups.iter_mut().for_each(|group| group.proxies.retain(|proxy| *proxy != cascade.name));
    }
    for client in &mut config.clients {
        for connection in client.connections.iter_mut().flatten().filter(|connection| connection.node == cascade.entry) {
            connection.proxies.retain(|proxy| *proxy != cascade.name);
        }
    }
}

fn delete(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let config = session.state.load_config()?;
    let cascade = config.cascades.iter().find(|cascade| cascade.name == name).ok_or_else(|| not_found(&name))?.clone();
    Plan::new(vec![format!("Каскад «{name}» будет удалён; назначения подключения «{name}» группам и клиентам будут сняты.")], "")
        .confirm(invocation)?;
    session.mutate("cascade delete", |state| {
        let mut config = state.load_config()?;
        let cascade = config.cascades.iter().find(|cascade| cascade.name == name).ok_or_else(|| not_found(&name))?.clone();
        config.cascades.retain(|other| other.name != name);
        unassign(&mut config, &cascade);
        state.save_config(&config)
    })?;
    session.log(Level::Success, &format!("Каскад «{name}» удалён"));
    apply_hint(session, &cascade);
    Ok(json!({"name": name}))
}

#[cfg(test)]
mod tests;
