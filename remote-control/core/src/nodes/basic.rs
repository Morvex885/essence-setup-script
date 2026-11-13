//! Node records: list/show, connection aliases, rename, tag, SSH password,
//! reachability check and agreed host-key trust (port of `nodes.sh` and the
//! matching `cmd_nodes.sh` handlers).

use serde_json::{json, Value};
use zeroize::Zeroizing;

use super::{COMMAND_TIMEOUT, connect_options, find, is_github, not_found, pin, pins, required, set_issue};
use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::model::{Auth, CascadeExit, Config, Fingerprint, Node, PortabilityReason};
use crate::request_secrets::Secrets;
use crate::state::State;
use crate::transport::RemoteTransport;
use crate::validation as v;

/// `ok | missing | error` for password nodes, `null` for key nodes.
fn password_state(state: &State, node: &Node) -> Option<&'static str> {
    if node.auth != Auth::Password {
        return None;
    }
    Some(match node.secret_id.as_deref().map(|id| state.secret_store().get(id)) {
        Some(Ok(Some(_))) => "ok",
        Some(Ok(None)) | None => "missing",
        Some(Err(error)) if error.code == "missing_secret" => "missing",
        Some(Err(_)) => "error",
    })
}

/// Public view of a node (no id); portability issues exist only for GitHub.
fn node_view(session: &Session, node: &Node, issues: &[crate::model::PortabilityIssue]) -> Value {
    let identity = match node.identity.as_deref() {
        None | Some("") => Value::Null,
        Some("system") => json!("system"),
        Some(_) => json!("managed"),
    };
    let reasons: Vec<PortabilityReason> = issues.iter().filter(|issue| issue.node_id == node.id).map(|issue| issue.reason).collect();
    json!({
        "name": node.name, "ip": node.ip, "port": node.port, "user": node.user, "auth": node.auth,
        "tag": node.tag.as_deref().unwrap_or(""), "identity": identity,
        "password": password_state(&session.state, node), "issues": reasons,
    })
}

fn declared_issues(session: &Session) -> Result<Vec<crate::model::PortabilityIssue>> {
    Ok(if is_github(session) { session.state.load_manifest()?.portability.issues } else { Vec::new() })
}

pub fn list(session: &mut Session) -> Result<Value> {
    let config = session.state.load_config()?;
    let issues = declared_issues(session)?;
    Ok(Value::Array(config.nodes.iter().map(|node| node_view(session, node, &issues)).collect()))
}

pub fn delete_scope_label(scope: &str, revoke: bool) -> &'static str {
    match (scope, revoke) {
        ("local", false) => "Удалить только из remote-control; сервер и SSH-ключ оставить",
        ("local", true) => "Удалить из remote-control и отозвать управляемый SSH-ключ",
        ("server", false) => "Удалить из remote-control и все компоненты Essence на сервере",
        _ => "Удалить из remote-control, все компоненты Essence и отозвать SSH-ключ",
    }
}

/// Clients whose node set (inherited from the group or their own) includes `name`.
fn client_count(config: &Config, name: &str) -> usize {
    config.clients.iter().filter(|client| if client.inherit_nodes_from_group {
        config.connections.iter().any(|connection| connection.node == name
            && connection.groups.iter().any(|group| group.name == client.group))
    } else {
        client.nodes.as_ref().is_some_and(|nodes| nodes.iter().any(|node| node == name))
    }).count()
}

pub fn show(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?;
    let config = session.state.load_config()?;
    let node = find(&config, name)?;
    let mut view = node_view(session, node, &declared_issues(session)?);
    let mut groups: Vec<&str> = config.connections.iter().filter(|connection| connection.node == name)
        .flat_map(|connection| connection.groups.iter().map(|group| group.name.as_str())).collect();
    groups.sort_unstable();
    groups.dedup();
    let managed = is_github(session) && node.identity.as_deref() == Some(node.id.as_str());
    let options: Vec<Value> = ["local", "server"].into_iter()
        .flat_map(|scope| [false, true].into_iter().filter(move |revoke| !revoke || managed)
            .map(move |revoke| json!({"scope": scope, "revoke_key": revoke, "label": delete_scope_label(scope, revoke)})))
        .collect();
    view["aliases"] = json!(node.aliases);
    view["groups"] = json!(groups);
    view["clients"] = json!(client_count(&config, name));
    view["delete_options"] = Value::Array(options);
    Ok(view)
}

enum AliasEdit {
    Set(String, String),
    Unset(String),
}

pub async fn aliases<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, transport: &mut T) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let node = find(&session.state.load_config()?, &name)?.clone();
    if !invocation.has("set") && !invocation.has("unset") {
        let discovered = super::conn::discover(session, &node, transport).await?;
        return Ok(Value::Array(discovered.into_iter()
            .map(|proxy| json!({"alias": node.aliases.get(&proxy), "proxy": proxy})).collect()));
    }
    let mut edits = Vec::new();
    for entry in invocation.values("set") {
        match entry.split_once('=') {
            Some((original, alias)) if !original.is_empty() => edits.push(match alias.is_empty() {
                true => AliasEdit::Unset(original.to_owned()),
                false => AliasEdit::Set(original.to_owned(), alias.to_owned()),
            }),
            _ => return Err(RcError::new("usage", format!("Флаг --set ожидает ORIG=ALIAS, получено: {entry}."))),
        }
    }
    for original in invocation.values("unset") {
        if original.is_empty() {
            return Err(RcError::new("usage", "Флаг --unset ожидает имя подключения."));
        }
        edits.push(AliasEdit::Unset(original.clone()));
    }
    let aliases = session.mutate("node_aliases", |state| {
        let mut config = state.load_config()?;
        let node = config.nodes.iter_mut().find(|node| node.name == name).ok_or_else(|| not_found(&name))?;
        for edit in &edits {
            match edit {
                AliasEdit::Set(original, alias) => { node.aliases.insert(original.clone(), alias.clone()); }
                AliasEdit::Unset(original) => { node.aliases.remove(original); }
            }
        }
        let aliases = node.aliases.clone();
        state.save_config(&config)?;
        Ok(aliases)
    })?;
    session.log(Level::Success, &format!("Псевдонимы для «{name}» сохранены"));
    Ok(json!({"name": name, "aliases": aliases}))
}

/// Every reference to a node name moves with it, including cascades, Telegram
/// Proxy and the subscription host.
fn rename_references(config: &mut Config, old: &str, new: &str) {
    let rename = |value: &mut String| if value == old { *value = new.to_owned() };
    config.nodes.iter_mut().for_each(|node| rename(&mut node.name));
    config.connections.iter_mut().for_each(|connection| rename(&mut connection.node));
    for client in &mut config.clients {
        client.nodes.iter_mut().flatten().for_each(&rename);
        client.connections.iter_mut().flatten().for_each(|connection| rename(&mut connection.node));
    }
    for cascade in &mut config.cascades {
        rename(&mut cascade.entry);
        if let CascadeExit::Node(exit) = &mut cascade.exit {
            rename(&mut exit.node);
        }
    }
    config.telegram.iter_mut().for_each(|proxy| rename(&mut proxy.node));
    if let Some(host) = config.subscription_host.as_mut() {
        rename(&mut host.node);
    }
}

pub fn rename(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let old = required(invocation, "name")?.to_owned();
    let new = required(invocation, "new-name")?.to_owned();
    if !v::name_valid(&new) {
        return Err(RcError::new("invalid", format!("Недопустимое имя ноды «{new}»: латиница, цифры, «.», «_», «-».")));
    }
    session.mutate("rename_node", |state| {
        let mut config = state.load_config()?;
        find(&config, &old)?;
        if new == old {
            return Ok(());
        }
        if config.nodes.iter().any(|node| node.name == new) {
            return Err(RcError::new("conflict", format!("Нода с именем «{new}» уже существует.")).with_extra("name", new.clone()));
        }
        rename_references(&mut config, &old, &new);
        state.save_config(&config)
    })?;
    if new != old {
        session.log(Level::Success, &format!("Нода «{old}» переименована в «{new}»"));
    }
    Ok(json!({"name": new}))
}

pub fn tag(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let tag = invocation.value("tag").ok_or_else(|| RcError::new("usage", "Укажите --tag."))?.to_owned();
    if !v::node_tag_valid(&tag) {
        return Err(RcError::new("invalid", format!(
            "Недопустимый тег «{tag}»: до 32 символов, без управляющих символов и ;\"'`$\\|&<>{{}}[]#,:/.")));
    }
    session.mutate("set_node_tag", |state| {
        let mut config = state.load_config()?;
        let node = config.nodes.iter_mut().find(|node| node.name == name).ok_or_else(|| not_found(&name))?;
        node.tag = Some(tag.clone());
        state.save_config(&config)
    })?;
    session.log(Level::Success, &format!("Тег ноды «{name}» сохранён"));
    Ok(json!({"name": name, "tag": tag}))
}

pub fn password(session: &mut Session, invocation: &Invocation, secrets: &Secrets) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let node = find(&session.state.load_config()?, &name)?.clone();
    let Some(secret_id) = node.secret_id.as_deref().filter(|_| node.auth == Auth::Password) else {
        return Err(RcError::new("invalid", format!("Нода «{name}» использует вход по ключу; пароль не нужен.")));
    };
    // The node and its auth are checked first, so a terminal is only asked for a password that is needed.
    let password = secrets.get("password").filter(|password| !password.is_empty()).ok_or_else(|| {
        RcError::new("missing_secret", "Не передан секрет password (--password-stdin или поле secrets).")
            .with_extra("name", name.clone()).with_extra("secret", "password")
    })?;
    session.mutate("save_node_password", |state| {
        let config = state.load_config()?;
        if find(&config, &name)?.secret_id.as_deref() != Some(secret_id) {
            return Err(not_found(&name));
        }
        state.secret_store().set(secret_id, Zeroizing::new(password.to_owned()))
    })?;
    session.log(Level::Success, &format!("Пароль SSH ноды «{name}» сохранён."));
    Ok(json!({"name": name}))
}

/// A stored node with unusable SSH fields never reaches the transport.
fn load_valid(session: &Session, name: &str) -> Result<Node> {
    let node = find(&session.state.load_config()?, name)?.clone();
    node.validate().map_err(|_| RcError::new("invalid", format!("Запись ноды «{name}» повреждена или неполна.")))?;
    Ok(node)
}

pub async fn check<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, transport: &mut T) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let node = load_valid(session, &name)?;
    super::require_portable(session, &node)?;
    session.log(Level::Info, &format!("Подключаемся к {} ({}@{}:{})...", node.name, node.user, node.ip, node.port));
    super::connect(transport, &session.state, &node).await?;
    let unreachable = || RcError::new("remote_failed", format!("Не удалось подключиться к «{name}».")).with_extra("name", name.clone());
    let result = transport.exec("echo ok", &[], COMMAND_TIMEOUT).await.map_err(|error| match error.extra.get("reason") {
        Some(reason) => unreachable().with_extra("reason", reason.clone()),
        None => unreachable(),
    })?;
    if result.exit_status != 0 || !String::from_utf8_lossy(&result.stdout).lines().any(|line| line.trim_end_matches('\r') == "ok") {
        return Err(unreachable().with_extra("exit_status", result.exit_status));
    }
    session.log(Level::Success, "Соединение установлено");
    session.log(Level::Success, &format!("Нода «{name}» доступна"));
    Ok(json!({"name": name, "reachable": true}))
}

/// The plan of `node trust-host-key`: the node, its pinned and the new fingerprint.
fn trust_plan(name: &str, node: &Node, previous: &[Fingerprint], fingerprint: &Fingerprint) -> Plan {
    let known = previous.iter().map(Fingerprint::as_str).collect::<Vec<_>>().join(", ");
    Plan::new(vec![
        format!("Нода: {name} {}:{}", node.ip, node.port),
        format!("Прежние отпечатки: {}", if known.is_empty() { "нет" } else { &known }),
        format!("Новый отпечаток: {fingerprint}"),
        "Прежние записи known_hosts для узла будут удалены.".to_owned(),
    ], "")
}

/// `trust_plan` again under the mutation lock: another node under the name or
/// a different plan (address, pins) is `plan_changed` with the current plan.
fn trust_recheck(state: &crate::state::State, name: &str, node: &Node, fingerprint: &Fingerprint, planned: &Plan,
    invocation: &Invocation) -> Result<()>
{
    let config = state.load_config()?;
    let current = find(&config, name)?;
    let plan = trust_plan(name, current, &pins(&state.load_known_hosts()?, current)?, fingerprint);
    if current.id != node.id || plan.lines != planned.lines {
        return Err(plan.changed(invocation));
    }
    Ok(())
}

/// Trust exactly the operator-supplied fingerprint: a successful connection
/// that expects it proves the server presents it. Nothing is written before
/// that proof and the confirmed plan.
pub async fn trust_host_key<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, transport: &mut T) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let fingerprint: Fingerprint = required(invocation, "host-key")?.parse()
        .map_err(|_| RcError::new("usage", "Отпечаток ключа ожидается в виде SHA256:…"))?;
    let node = load_valid(session, &name)?;
    let previous = pins(&session.state.load_known_hosts()?, &node)?;
    let options = connect_options(&session.state, &node, Some(fingerprint.clone()))?;
    transport.connect(options).await.map_err(|mut error| {
        match error.code {
            "host_key_mismatch" => error.message = format!(
                "Сервер {}:{} не предъявил ключ с отпечатком {fingerprint}.", node.ip, node.port),
            "remote_failed" => error.message = format!("Не удалось подключиться к «{name}»."),
            _ => {}
        }
        error.with_extra("name", name.clone())
    })?;
    let plan = trust_plan(&name, &node, &previous, &fingerprint);
    plan.confirm(invocation)?;
    session.mutate("trust_host_key", |state| {
        trust_recheck(state, &name, &node, &fingerprint, &plan, invocation)?;
        pin(state, &node.ip, node.port, vec![fingerprint.clone()])?;
        let mut manifest = state.load_manifest()?;
        if manifest.portability.issues.iter().any(|issue| issue.node_id == node.id && issue.reason == PortabilityReason::MissingHostKey) {
            set_issue(&mut manifest, &node.id, PortabilityReason::MissingHostKey, false);
            state.save_manifest(&manifest).map_err(|error| RcError::new("partial", format!(
                "Ключ сервера закреплён, но отметку переносимости обновить не удалось: {}", error.message)))?;
        }
        Ok(())
    })?;
    session.log(Level::Success, &format!("Новый ключ сервера ноды «{name}» закреплён"));
    Ok(json!({"name": name, "fingerprint": fingerprint}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeTransport, Operation, ScriptStep};
    use crate::model::{Cascade, CascadeListener, Client, ClientConnection, Connection, ConnectionGroup, ExitProxy, NodeExit,
        SubscriptionHost, TelegramProxy};
    use crate::nodes::testing::{fingerprint, invocation, session};
    use crate::nodes::CONNECT_TIMEOUT;
    use crate::transport::{ExecResult, HostKeyPolicy};

    fn fp(byte: u8) -> Fingerprint {
        use base64::Engine;
        format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode([byte; 32])).parse().unwrap()
    }

    fn node(index: u8, name: &str, auth: Auth) -> Node {
        let id = format!("{index:032x}");
        Node {
            secret_id: (auth == Auth::Password).then(|| format!("node:{id}:ssh-password")),
            id, name: name.into(), ip: format!("198.51.100.{index}"), port: 2222, user: "root".into(), auth,
            identity: (auth == Auth::Key).then(|| "system".into()), tag: Some("DE".into()), aliases: Default::default(),
            ..Node::default()
        }
    }

    fn setup(root: &std::path::Path, config: Config) -> Session {
        let (session, _) = session(root);
        session.state.save_config(&config).unwrap();
        session
    }

    fn expect(node: &Node, expected: Option<Fingerprint>, known: Vec<Fingerprint>, outcome: Result<()>) -> ScriptStep {
        ScriptStep::connect(ConnectExpectation::new(node.ip.clone(), node.port, "root", AuthMethod::System, CONNECT_TIMEOUT)
            .with_host_key(HostKeyPolicy { expected, known }), outcome)
    }

    fn host_key_error(code: &'static str, node: &Node, presented: &Fingerprint) -> RcError {
        RcError::new(code, "Ключ SSH-сервера не подтверждён.").with_extra("host", node.ip.clone())
            .with_extra("port", node.port).with_extra("fingerprints", json!([presented]))
    }

    #[test]
    fn rename_cascades_every_reference_including_subscription_host() {
        let root = tempfile::tempdir().unwrap();
        let (mut a, mut other) = (node(1, "a", Auth::Key), node(2, "other", Auth::Key));
        a.profile = Some("main".into());
        other.profile = Some("main".into());
        let mut session = setup(root.path(), Config {
            nodes: vec![a, other],
            profiles: vec![crate::model::test_profile("main")],
            connections: vec![Connection { node: "a".into(), groups: vec![ConnectionGroup { name: "PC".into(), proxies: vec!["p".into()] }] }],
            clients: vec![Client { name: "c".into(), group: "PC".into(), inherit_nodes_from_group: false,
                nodes: Some(vec!["a".into(), "other".into()]),
                connections: Some(vec![ClientConnection { node: "a".into(), proxies: vec!["p".into()] }]), ..Client::default() }],
            cascades: vec![Cascade { name: "via-other".into(), entry: "a".into(), listener: CascadeListener::VlessTcp,
                exit: CascadeExit::Node(NodeExit { node: "other".into(), proxy: ExitProxy::VlessTcp }),
                uuid: "11111111-2222-4333-8444-555555555555".into(), password: "0123456789abcdef".into() },
                Cascade { name: "back".into(), entry: "other".into(), listener: CascadeListener::Hysteria2,
                exit: CascadeExit::Node(NodeExit { node: "a".into(), proxy: ExitProxy::Hysteria2 }),
                uuid: "11111111-2222-4333-8444-555555555555".into(), password: "0123456789abcdef".into() }],
            telegram: vec![TelegramProxy { node: "a".into(), hostname: "tg.example".into(), secret_mark: "0123abcd".into(), tag_mark: None }],
            subscription_host: Some(SubscriptionHost { node: "a".into(), hostname: "s.example".into(), port: 443,
                base_url: "https://s.example".into(), sub_dir: "sub".into(), nginx_group: "www-data".into() }),
            ..Config::default()
        });
        assert_eq!(rename(&mut session, &invocation(&["node", "rename", "--name", "a", "--new-name", "b"])).unwrap(), json!({"name": "b"}));
        let config = session.state.load_config().unwrap();
        assert_eq!(config.nodes.iter().map(|n| n.name.as_str()).collect::<Vec<_>>(), ["b", "other"]);
        assert_eq!(config.connections[0].node, "b");
        assert_eq!(config.clients[0].nodes.as_deref().unwrap(), ["b", "other"]);
        assert_eq!(config.clients[0].connections.as_ref().unwrap()[0].node, "b");
        assert_eq!(config.subscription_host.unwrap().node, "b");
        assert_eq!((config.cascades[0].entry.as_str(), config.telegram[0].node.as_str()), ("b", "b"));
        assert!(matches!(&config.cascades[1].exit, CascadeExit::Node(exit) if exit.node == "b"));

        let before = fingerprint(root.path());
        let conflict = rename(&mut session, &invocation(&["node", "rename", "--name", "b", "--new-name", "other"])).unwrap_err();
        assert_eq!(conflict.code, "conflict");
        let missing = rename(&mut session, &invocation(&["node", "rename", "--name", "a", "--new-name", "z"])).unwrap_err();
        assert_eq!(missing.code, "not_found");
        let invalid = rename(&mut session, &invocation(&["node", "rename", "--name", "b", "--new-name", "../x"])).unwrap_err();
        assert_eq!(invalid.code, "invalid");
        assert_eq!(fingerprint(root.path()), before);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn trust_host_key_mismatch_and_unconfirmed_plan_write_nothing() {
        let root = tempfile::tempdir().unwrap();
        let a = node(1, "a", Auth::Key);
        let mut session = setup(root.path(), Config { nodes: vec![a.clone()], ..Config::default() });
        pin(&session.state, &a.ip, a.port, vec![fp(1)]).unwrap();
        let mut manifest = session.state.load_manifest().unwrap();
        set_issue(&mut manifest, &a.id, PortabilityReason::MissingHostKey, true);
        session.state.save_manifest(&manifest).unwrap();
        let wanted = fp(2);
        let argv = ["node", "trust-host-key", "--name", "a", "--host-key", wanted.as_str()];
        let before = fingerprint(root.path());

        let mut transport = FakeTransport::new([expect(&a, Some(wanted.clone()), vec![fp(1)],
            Err(host_key_error("host_key_mismatch", &a, &fp(3))))]);
        let error = trust_host_key(&mut session, &invocation(&argv), &mut transport).await.unwrap_err();
        transport.assert_finished();
        assert_eq!(error.code, "host_key_mismatch");
        assert_eq!(error.extra["fingerprints"], json!([fp(3)]));
        assert_eq!(fingerprint(root.path()), before);

        let mut transport = FakeTransport::new([expect(&a, Some(wanted.clone()), vec![fp(1)], Ok(()))]);
        let error = trust_host_key(&mut session, &invocation(&argv), &mut transport).await.unwrap_err();
        transport.assert_finished();
        assert_eq!((error.code, error.exit), ("confirmation_required", 2));
        assert_eq!(error.extra["plan"], json!([
            "Нода: a 198.51.100.1:2222", format!("Прежние отпечатки: {}", fp(1)),
            format!("Новый отпечаток: {wanted}"), "Прежние записи known_hosts для узла будут удалены."]));
        assert_eq!(fingerprint(root.path()), before);

        let mut transport = FakeTransport::new([expect(&a, Some(wanted.clone()), vec![fp(1)], Ok(()))]);
        let confirmed = [&argv[..], &["--yes"]].concat();
        let data = trust_host_key(&mut session, &invocation(&confirmed), &mut transport).await.unwrap();
        assert_eq!(data, json!({"name": "a", "fingerprint": wanted}));
        assert_eq!(pins(&session.state.load_known_hosts().unwrap(), &a).unwrap(), vec![wanted]);
        assert!(session.state.load_manifest().unwrap().portability.issues.is_empty());

        let error = trust_host_key(&mut session, &invocation(&["node", "trust-host-key", "--name", "a", "--host-key", "SHA256:short"]),
            &mut FakeTransport::default()).await.unwrap_err();
        assert_eq!(error.code, "usage");
    }

    #[test]
    fn trust_host_key_rechecks_the_plan_under_the_lock() {
        let root = tempfile::tempdir().unwrap();
        let a = node(1, "a", Auth::Key);
        let session = setup(root.path(), Config { nodes: vec![a.clone()], ..Config::default() });
        pin(&session.state, &a.ip, a.port, vec![fp(1)]).unwrap();
        let wanted = fp(2);
        let invocation = invocation(&["node", "trust-host-key", "--name", "a", "--host-key", wanted.as_str(), "--yes"]);
        let planned = trust_plan("a", &a, &[fp(1)], &wanted);
        trust_recheck(&session.state, "a", &a, &wanted, &planned, &invocation).unwrap();
        // Another pin was written meanwhile: the plan names it now.
        pin(&session.state, &a.ip, a.port, vec![fp(3)]).unwrap();
        let error = trust_recheck(&session.state, "a", &a, &wanted, &planned, &invocation).unwrap_err();
        assert_eq!(error.code, "plan_changed");
        assert_eq!(error.extra["plan"][1], json!(format!("Прежние отпечатки: {}", fp(3))));
        assert!(error.extra["plan_token"].is_string());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn check_reports_changed_key_with_fingerprints_and_success() {
        let root = tempfile::tempdir().unwrap();
        let a = node(1, "a", Auth::Key);
        let mut session = setup(root.path(), Config { nodes: vec![a.clone()], ..Config::default() });
        pin(&session.state, &a.ip, a.port, vec![fp(1)]).unwrap();
        let mut transport = FakeTransport::new([expect(&a, None, vec![fp(1)], Err(host_key_error("host_key_changed", &a, &fp(9))))]);
        let error = check(&mut session, &invocation(&["node", "check", "--name", "a"]), &mut transport).await.unwrap_err();
        transport.assert_finished();
        assert_eq!((error.code, error.message.as_str()), ("host_key_changed", "Ключ сервера ноды «a» изменился."));
        assert_eq!((error.extra["fingerprints"].clone(), error.extra["port"].clone()), (json!([fp(9)]), json!(2222)));

        let mut transport = FakeTransport::new([expect(&a, None, vec![fp(1)], Ok(())),
            ScriptStep::exec("echo ok", 0, COMMAND_TIMEOUT, Ok(ExecResult { stdout: b"ok\r\n".to_vec(), ..ExecResult::default() }))]);
        let data = check(&mut session, &invocation(&["node", "check", "--name", "a"]), &mut transport).await.unwrap();
        transport.assert_finished();
        assert_eq!(data, json!({"name": "a", "reachable": true}));

        // A corrupted record is refused before any remote effect.
        let mut config = session.state.load_config().unwrap();
        config.nodes[0].identity = Some("1".repeat(32));
        std::fs::write(session.state.paths().config(), serde_json::to_vec(&config).unwrap()).unwrap();
        let mut transport = FakeTransport::default();
        assert!(check(&mut session, &invocation(&["node", "check", "--name", "a"]), &mut transport).await.is_err());
        assert!(transport.journal().iter().all(|op| !matches!(op, Operation::Connect(_))));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn password_tag_aliases_list_and_show() {
        let root = tempfile::tempdir().unwrap();
        let (key, pw) = (node(1, "key", Auth::Key), node(2, "pw", Auth::Password));
        let mut session = setup(root.path(), Config { nodes: vec![key.clone(), pw.clone()], ..Config::default() });
        let listed = list(&mut session).unwrap();
        assert_eq!((listed[0]["password"].clone(), listed[1]["password"].clone()), (Value::Null, json!("missing")));
        assert_eq!((listed[0]["identity"].clone(), listed[1]["identity"].clone()), (json!("system"), Value::Null));

        let mut secrets = Secrets::default();
        secrets.insert("password", Zeroizing::new("s3cret".into())).unwrap();
        let error = password(&mut session, &invocation(&["node", "password", "--name", "key"]), &secrets).unwrap_err();
        assert_eq!(error.code, "invalid");
        let error = password(&mut session, &invocation(&["node", "password", "--name", "pw"]), &Secrets::default()).unwrap_err();
        assert_eq!((error.code, error.extra["secret"].clone()), ("missing_secret", json!("password")));
        let error = password(&mut session, &invocation(&["node", "password", "--name", "key"]), &Secrets::default()).unwrap_err();
        assert_eq!(error.code, "invalid");
        password(&mut session, &invocation(&["node", "password", "--name", "pw"]), &secrets).unwrap();
        assert_eq!(session.state.secret_store().get(pw.secret_id.as_deref().unwrap()).unwrap().unwrap().as_str(), "s3cret");
        assert_eq!(list(&mut session).unwrap()[1]["password"], "ok");

        assert_eq!(tag(&mut session, &invocation(&["node", "tag", "--name", "key", "--tag", ""])).unwrap(), json!({"name": "key", "tag": ""}));
        assert_eq!(tag(&mut session, &invocation(&["node", "tag", "--name", "key", "--tag", "a:b"])).unwrap_err().code, "invalid");

        let mut transport = FakeTransport::default();
        let data = aliases(&mut session, &invocation(&["node", "aliases", "--name", "key", "--set", "vless-r=Fast",
            "--set", "hy2=Slow", "--unset", "hy2"]), &mut transport).await.unwrap();
        assert_eq!(data, json!({"name": "key", "aliases": {"vless-r": "Fast"}}));
        assert!(transport.journal().is_empty());
        let error = aliases(&mut session, &invocation(&["node", "aliases", "--name", "key", "--set", "=x"]), &mut transport).await.unwrap_err();
        assert_eq!(error.code, "usage");

        let mut transport = FakeTransport::new([expect(&key, None, vec![], Ok(())),
            ScriptStep::exec(crate::nodes::conn::DISCOVER_COMMAND, 0, COMMAND_TIMEOUT,
                Ok(ExecResult { stdout: b"  - name: \"vless-r\"\n  - name: \"hy2-x\"\n".to_vec(), ..ExecResult::default() }))]);
        let data = aliases(&mut session, &invocation(&["node", "aliases", "--name", "key"]), &mut transport).await.unwrap();
        transport.assert_finished();
        assert_eq!(data, json!([{"proxy": "hy2-x", "alias": null}, {"proxy": "vless-r", "alias": "Fast"}]));

        let shown = show(&mut session, &invocation(&["node", "show", "--name", "key"])).unwrap();
        assert_eq!(shown["delete_options"].as_array().unwrap().iter().map(|o| o["scope"].as_str().unwrap()).collect::<Vec<_>>(), ["local", "server"]);
        assert_eq!((shown["clients"].clone(), shown["aliases"]["vless-r"].clone()), (json!(0), json!("Fast")));
        assert!(shown.get("id").is_none());
    }
}
