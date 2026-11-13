//! Schema-v3 logical state. Ordinary serde models normalize absent/null/default
//! fields; schema 2 is upgraded by [`Config::parse`] (only `subscription_host`
//! changed shape and is dropped). Validation is local and effect-free:
//! resource existence belongs to storage.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::str::FromStr;

use base64::Engine;
use serde::{Deserialize, Deserializer, Serialize};

use crate::error::{RcError, Result};
use crate::validation as v;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Config {
    pub schema_version: u32,
    pub nodes: Vec<Node>,
    pub groups: Vec<Group>,
    pub clients: Vec<Client>,
    pub connections: Vec<Connection>,
    #[serde(default)]
    pub profiles: Vec<Profile>,
    #[serde(default)]
    pub cascades: Vec<Cascade>,
    #[serde(default)]
    pub telegram: Vec<TelegramProxy>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subscription_host: Option<SubscriptionHost>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subscription_default_headers: Option<Vec<SubscriptionHeader>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub minimum_remote_control_version: Option<String>,
}

pub const SCHEMA_VERSION: u32 = 3;

impl Default for Config {
    fn default() -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            nodes: Vec::new(),
            groups: ["ROUTER", "PC", "MOBILE"].into_iter().map(|name| Group {
                name: name.into(), ..Group::default()
            }).collect(),
            clients: Vec::new(),
            connections: Vec::new(),
            profiles: Vec::new(),
            cascades: Vec::new(),
            telegram: Vec::new(),
            subscription_host: None,
            subscription_default_headers: None,
            minimum_remote_control_version: None,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Auth { #[default] Key, Password }

/// Unknown node members are rejected, including the forbidden schema-1 `pass`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Node {
    pub id: String,
    pub name: String,
    pub ip: String,
    pub port: u16,
    pub user: String,
    pub auth: Auth,
    #[serde(default)]
    pub identity: Option<String>,
    // Unlike an ordinary Option, the key must be present, including explicit
    // null for key auth. deserialize_with prevents serde's missing-Option default.
    #[serde(deserialize_with = "required_nullable")]
    pub secret_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    #[serde(default)]
    pub aliases: BTreeMap<String, String>,
    /// Server profile applied to the node; `None` — the node is only an SSH target.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub domain: Option<String>,
    /// Per-node port overrides, keys [`NODE_PORT_KEYS`].
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub ports: BTreeMap<String, u16>,
    #[serde(default, skip_serializing_if = "NodeParams::is_empty")]
    pub params: NodeParams,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub applied: Option<Applied>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation: Option<String>,
}

fn required_nullable<'de, D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Option<String>, D::Error> {
    Option::<String>::deserialize(deserializer)
}

/// Keys of [`Node::ports`].
pub const NODE_PORT_KEYS: [&str; 4] = ["vless-xhttp", "vless-grpc", "hysteria2", "amneziawg"];

/// Connection names a node can serve (cascades add their own names).
pub const CONNECTION_NAMES: [&str; 5] = ["VLESS TCP", "VLESS xHTTP", "VLESS gRPC", "Hysteria2", "AWG"];

/// The oldest mihomo a profile may install.
pub const MIHOMO_MIN_VERSION: [u64; 3] = [1, 19, 18];

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SiteSource { #[default] Simple, Sni, Nothing, Random }

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RealityMode { #[default] SelfSteal, Sni }

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Ipv6 { #[default] Default, Enabled, Disabled }

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum XhttpTopology { Reality, Nginx }

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Xhttp {
    pub topology: XhttpTopology,
    /// Reality topology only; `None` — 443.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PortOnly { pub port: u16 }

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Hysteria2 {
    pub port: u16,
    #[serde(default)]
    pub obfs: bool,
}

pub fn default_awg_dns() -> String { "1.1.1.1, 1.0.0.1".into() }

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AmneziaWg {
    pub port: u16,
    #[serde(default = "default_awg_dns")]
    pub dns: String,
}

/// Desired server setup shared by nodes.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Profile {
    pub name: String,
    pub mihomo_version: String,
    pub acme_email: String,
    #[serde(default)]
    pub site_source: SiteSource,
    #[serde(default)]
    pub reality_mode: RealityMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sni_domain: Option<String>,
    #[serde(default)]
    pub vless_tcp: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vless_xhttp: Option<Xhttp>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vless_grpc: Option<PortOnly>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hysteria2: Option<Hysteria2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub amneziawg: Option<AmneziaWg>,
    #[serde(default)]
    pub warp: bool,
    /// Mark of the stored WARP+ license: 8 hex, new on every key change.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warp_plus: Option<String>,
    #[serde(default)]
    pub ipv6: Ipv6,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NodeReality {
    pub public_key: String,
    pub short_id: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NodeAwg {
    pub public_key: String,
    pub header_protection_key: String,
    pub tproxy_port: u16,
    pub jc: u8,
    pub s1: u16,
    pub s2: u16,
    pub s3: u16,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NodeWarp {
    pub public_key: String,
    pub ipv4: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ipv6: Option<String>,
    #[serde(default)]
    pub plus: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plus_attempt: Option<String>,
}

/// Values generated once per node and never changed afterwards.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NodeParams {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reality: Option<NodeReality>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub xhttp_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grpc_service: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hy2_obfs_password: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub awg: Option<NodeAwg>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warp: Option<NodeWarp>,
}

impl NodeParams {
    pub fn is_empty(&self) -> bool { *self == Self::default() }
}

/// The last state applied to the node.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Applied {
    pub digest: String,
    #[serde(default)]
    pub files: BTreeMap<String, String>,
    #[serde(default)]
    pub ports: Vec<String>,
    pub at: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CascadeListener { VlessTcp, VlessXhttp, VlessGrpc, Hysteria2 }

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ExitProxy {
    #[serde(rename = "VLESS TCP")] VlessTcp,
    #[serde(rename = "VLESS xHTTP")] VlessXhttp,
    #[serde(rename = "VLESS gRPC")] VlessGrpc,
    #[serde(rename = "Hysteria2")] Hysteria2,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NodeExit { pub node: String, pub proxy: ExitProxy }

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UriExit { pub uri: String }

/// `{"node", "proxy"}` — another managed node; `{"uri"}` — an external proxy.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum CascadeExit { Node(NodeExit), Uri(UriExit) }

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Cascade {
    pub name: String,
    pub entry: String,
    pub listener: CascadeListener,
    pub exit: CascadeExit,
    pub uuid: String,
    pub password: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TelegramProxy {
    pub node: String,
    pub hostname: String,
    pub secret_mark: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tag_mark: Option<String>,
}

fn default_template() -> String { "default.yaml".into() }
fn default_nginx_group() -> String { "www-data".into() }
fn default_inherit() -> bool { true }

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Group {
    pub name: String,
    #[serde(default = "default_template")]
    pub template: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subscription_headers: Option<Vec<SubscriptionHeader>>,
}

impl Default for Group {
    fn default() -> Self {
        Self { name: String::new(), template: default_template(), subscription_headers: None }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Client {
    pub name: String,
    pub group: String,
    #[serde(default = "default_inherit")]
    pub inherit_nodes_from_group: bool,
    // Missing arrays represent group inheritance; explicit arrays represent
    // client-owned selections and must not be materialized on inherited clients.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nodes: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub connections: Option<Vec<ClientConnection>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credentials: Option<ClientCredentials>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subscription: Option<Subscription>,
}

impl Default for Client {
    fn default() -> Self {
        Self {
            name: String::new(), group: String::new(), inherit_nodes_from_group: true,
            nodes: None, connections: None, credentials: None, subscription: None,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ClientCredentials {
    pub vless_uuid: String,
    pub hy2_password: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub awg_private_key: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub awg_preshared_key: String,
    /// Host index in the AmneziaWG subnet; 0 — not assigned.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub awg_index: u32,
}

fn is_zero(value: &u32) -> bool { *value == 0 }

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Connection {
    pub node: String,
    pub groups: Vec<ConnectionGroup>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ConnectionGroup {
    pub name: String,
    pub proxies: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ClientConnection {
    pub node: String,
    pub proxies: Vec<String>,
}

/// May initially contain only headers, before the first publication.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Subscription {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<String>,
    #[serde(default)]
    pub expires_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub headers: Option<Vec<SubscriptionHeader>>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct SubscriptionHeader {
    pub name: String,
    pub value: String,
}

/// Subscription hosting on a profiled node.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SubscriptionHost {
    pub node: String,
    pub hostname: String,
    pub port: u16,
    pub base_url: String,
    pub sub_dir: String,
    #[serde(default = "default_nginx_group")]
    pub nginx_group: String,
}

/// Subscription files directory on the host node.
pub const SUB_DIR: &str = "/var/lib/essence-sub";

impl SubscriptionHost {
    /// `https://<hostname>` on 443, otherwise `https://<hostname>:<port>`.
    pub fn base_url_for(hostname: &str, port: u16) -> String {
        if port == 443 { format!("https://{hostname}") } else { format!("https://{hostname}:{port}") }
    }

    /// `(hostname, port)` of an `https://host[:port][/]` base URL.
    pub fn parse_base_url(url: &str) -> Option<(String, u16)> {
        let rest = url.strip_prefix("https://")?;
        let rest = rest.strip_suffix('/').unwrap_or(rest);
        match rest.rsplit_once(':') {
            Some((host, port)) => Some((host.to_owned(), v::parse_ssh_port(port).ok()?)),
            None => Some((rest.to_owned(), 443)),
        }
    }
}

impl Config {
    /// Reads `config.json` bytes, upgrading schema 2, and validates the result.
    pub fn parse(bytes: &[u8]) -> Result<Config> {
        let mut value: serde_json::Value = serde_json::from_slice(bytes)?;
        Self::upgrade_value(&mut value);
        let config: Config = serde_json::from_value(value)?;
        config.validate()?;
        Ok(config)
    }

    /// Schema 2 → 3 in place: only `subscription_host` changed shape, so it is
    /// dropped (the host is configured again). Other versions are left for
    /// [`Config::validate`] to refuse.
    pub fn upgrade_value(value: &mut serde_json::Value) {
        let Some(object) = value.as_object_mut() else { return };
        if object.get("schema_version").and_then(serde_json::Value::as_u64) == Some(2) {
            object.insert("schema_version".into(), SCHEMA_VERSION.into());
            object.remove("subscription_host");
        }
    }

    pub fn find_profile(&self, name: &str) -> Option<&Profile> {
        self.profiles.iter().find(|profile| profile.name == name)
    }

    /// Canonical name/tag and linkage validation, shared with mutation inputs.
    /// Template resource existence is checked separately by storage/commands.
    pub fn validate(&self) -> Result<()> {
        if self.schema_version != SCHEMA_VERSION {
            return Err(invalid("Ожидается schema_version: 3."));
        }
        if self.minimum_remote_control_version.as_deref().is_some_and(|s| !s.is_empty() && !v::version_valid(s)) {
            return Err(invalid("Некорректная minimum_remote_control_version."));
        }
        unique_names(self.profiles.iter().map(|p| p.name.as_str()))?;
        for profile in &self.profiles {
            profile.validate()?;
        }
        let mut ids = BTreeSet::new();
        let mut names = BTreeSet::new();
        let mut profiled = BTreeSet::new();
        for node in &self.nodes {
            node.validate()?;
            if !ids.insert(node.id.as_str()) || !names.insert(node.name.as_str()) {
                return Err(invalid("Повторяющийся идентификатор или имя ноды."));
            }
            if let Some(name) = &node.profile {
                let profile = self.find_profile(name).ok_or_else(|| invalid("Ссылка на неизвестный профиль."))?;
                let (tcp, udp) = profile.listen_ports(&node.ports);
                check_ports(&tcp, &udp)?;
                profiled.insert(node.name.as_str());
            }
        }
        unique_names(self.groups.iter().map(|g| g.name.as_str()))?;
        unique_names(self.clients.iter().map(|c| c.name.as_str()))?;
        let require_node = |name: &str| {
            if names.contains(name) { Ok(()) } else { Err(invalid("Ссылка на неизвестную ноду.")) }
        };
        let require_profiled = |name: &str| {
            require_node(name)?;
            if profiled.contains(name) { Ok(()) } else { Err(invalid("Нода без профиля не может обслуживать подключения.")) }
        };
        for connection in &self.connections {
            require_node(&connection.node)?;
            // `conn set` edits the first group of a name; a repeat would keep
            // stale proxies that reads still merge in.
            let mut groups = BTreeSet::new();
            if !connection.groups.iter().all(|group| groups.insert(group.name.as_str())) {
                return Err(invalid("Повторяющаяся группа в подключении ноды."));
            }
        }
        for client in &self.clients {
            if !v::name_valid(&client.group) {
                return Err(invalid("Некорректное имя группы клиента."));
            }
            if let Some(nodes) = &client.nodes {
                for node in nodes { require_node(node)?; }
            }
            if let Some(connections) = &client.connections {
                for connection in connections { require_node(&connection.node)?; }
            }
        }
        unique_names(self.cascades.iter().map(|c| c.name.as_str()))?;
        for cascade in &self.cascades {
            if CONNECTION_NAMES.contains(&cascade.name.as_str()) {
                return Err(invalid("Имя каскада совпадает с именем подключения ноды."));
            }
            require_profiled(&cascade.entry)?;
            // The entry node's credentials on the exit node; unused for a URI exit.
            let credentials_valid = v::vless_uuid_valid(&cascade.uuid) && v::hy2_password_valid(&cascade.password);
            match &cascade.exit {
                CascadeExit::Node(exit) => {
                    require_profiled(&exit.node)?;
                    if exit.node == cascade.entry {
                        return Err(invalid("Входная и выходная ноды каскада совпадают."));
                    }
                    if !credentials_valid {
                        return Err(invalid("Некорректные учётные данные каскада."));
                    }
                }
                CascadeExit::Uri(exit) => {
                    if exit.uri.is_empty() || exit.uri.chars().any(|c| c.is_control() || c.is_whitespace()) {
                        return Err(invalid("Некорректная ссылка выхода каскада."));
                    }
                    if !credentials_valid && !(cascade.uuid.is_empty() && cascade.password.is_empty()) {
                        return Err(invalid("Некорректные учётные данные каскада."));
                    }
                }
            }
        }
        let mut telegram_nodes = BTreeSet::new();
        for proxy in &self.telegram {
            require_profiled(&proxy.node)?;
            if !telegram_nodes.insert(proxy.node.as_str()) {
                return Err(invalid("На ноде может быть только один Telegram Proxy."));
            }
            if !v::domain_valid(&proxy.hostname) {
                return Err(invalid("Некорректный домен Telegram Proxy."));
            }
            if !mark_valid(&proxy.secret_mark) || proxy.tag_mark.as_deref().is_some_and(|mark| !mark_valid(mark)) {
                return Err(invalid("Некорректная метка секрета Telegram Proxy."));
            }
        }
        if let Some(host) = &self.subscription_host {
            require_profiled(&host.node)?;
            if !v::domain_valid(&host.hostname) || host.port == 0 {
                return Err(invalid("Некорректный адрес хостинга подписок."));
            }
        }
        Ok(())
    }
}

/// Marks of stored secrets: 8 lowercase hex.
fn mark_valid(value: &str) -> bool {
    value.len() == 8 && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// `vMAJOR.MINOR.PATCH` not below [`MIHOMO_MIN_VERSION`].
fn mihomo_version_check(value: &str) -> Result<()> {
    let parts: Option<Vec<u64>> = value.strip_prefix('v').filter(|rest| v::version_valid(rest))
        .map(|rest| rest.split('.').map(|part| part.parse().ok()).collect::<Option<Vec<u64>>>())
        .unwrap_or(None);
    match parts {
        None => Err(invalid("Некорректная версия mihomo: ожидается vX.Y.Z.")),
        Some(parts) if parts.as_slice() < MIHOMO_MIN_VERSION.as_slice() => Err(invalid("Нужен mihomo не ниже v1.19.18.")),
        Some(_) => Ok(()),
    }
}

/// Ports are distinct within TCP and within UDP and avoid internal ports.
fn check_ports(tcp: &[(&str, u16)], udp: &[(&str, u16)]) -> Result<()> {
    for list in [tcp, udp] {
        let mut seen = BTreeSet::new();
        for &(_, port) in list {
            if port == 0 {
                return Err(invalid("Порт должен быть от 1 до 65535."));
            }
            if crate::server::RESERVED_PORTS.contains(&port) {
                return Err(RcError::new("invalid", format!("Порт {port} зарезервирован для внутренних служб.")));
            }
            if !seen.insert(port) {
                return Err(RcError::new("invalid", format!("Порт {port} занят двумя подключениями.")));
            }
        }
    }
    Ok(())
}

/// `(key, port)` listeners of one L4 protocol.
pub type PortList = Vec<(&'static str, u16)>;

impl Profile {
    /// Whether the profile has a Reality transport (VLESS TCP, xHTTP over Reality, gRPC).
    pub fn has_reality(&self) -> bool {
        self.vless_tcp || self.vless_grpc.is_some()
            || self.vless_xhttp.as_ref().is_some_and(|x| x.topology == XhttpTopology::Reality)
    }

    /// Listening ports `(key, port)` by L4 protocol with node overrides applied.
    /// Hysteria2 is in both lists: its port must be free for TCP too.
    pub fn listen_ports(&self, overrides: &BTreeMap<String, u16>) -> (PortList, PortList) {
        let port = |key: &str, port: u16| overrides.get(key).copied().unwrap_or(port);
        let (mut tcp, mut udp) = (Vec::new(), Vec::new());
        if self.vless_tcp {
            tcp.push(("vless-tcp", 443));
        }
        if let Some(xhttp) = self.vless_xhttp.as_ref().filter(|x| x.topology == XhttpTopology::Reality) {
            tcp.push(("vless-xhttp", port("vless-xhttp", xhttp.port.unwrap_or(443))));
        }
        if let Some(grpc) = &self.vless_grpc {
            tcp.push(("vless-grpc", port("vless-grpc", grpc.port)));
        }
        if let Some(hy2) = &self.hysteria2 {
            let hy2 = port("hysteria2", hy2.port);
            tcp.push(("hysteria2", hy2));
            udp.push(("hysteria2", hy2));
        }
        if let Some(awg) = &self.amneziawg {
            udp.push(("amneziawg", port("amneziawg", awg.port)));
        }
        (tcp, udp)
    }

    pub fn validate(&self) -> Result<()> {
        if !v::name_valid(&self.name) {
            return Err(invalid("Некорректное имя профиля."));
        }
        mihomo_version_check(&self.mihomo_version)?;
        if !v::acme_email_valid(&self.acme_email) {
            return Err(invalid("Некорректный ACME email."));
        }
        match (self.reality_mode, self.sni_domain.as_deref()) {
            (RealityMode::Sni, Some(domain)) if v::domain_valid(domain) => {}
            (RealityMode::Sni, Some(_)) => return Err(invalid("Некорректный SNI-домен.")),
            (RealityMode::Sni, None) => return Err(invalid("Для режима sni нужен SNI-домен.")),
            (RealityMode::SelfSteal, Some(_)) => return Err(invalid("SNI-домен задаётся только в режиме sni.")),
            (RealityMode::SelfSteal, None) => {}
        }
        if let Some(xhttp) = self.vless_xhttp.as_ref().filter(|xhttp| xhttp.topology == XhttpTopology::Nginx) {
            if xhttp.port.is_some() {
                return Err(invalid("Порт xHTTP задаётся только для топологии reality."));
            }
            if self.reality_mode != RealityMode::SelfSteal {
                return Err(invalid("xHTTP через nginx требует режима self-steal."));
            }
        }
        if self.amneziawg.as_ref().is_some_and(|awg| awg.dns.is_empty() || awg.dns.chars().any(char::is_control)) {
            return Err(invalid("Некорректный DNS AmneziaWG."));
        }
        if self.warp_plus.as_deref().is_some_and(|mark| !mark_valid(mark)) {
            return Err(invalid("Некорректная метка ключа WARP+."));
        }
        let (tcp, udp) = self.listen_ports(&BTreeMap::new());
        check_ports(&tcp, &udp)
    }
}

impl Node {
    pub fn validate(&self) -> Result<()> {
        if !v::node_id_valid(&self.id) || !v::name_valid(&self.name)
            || !v::ssh_host_valid(&self.ip) || !v::ssh_user_valid(&self.user) || self.port == 0
            || self.tag.as_deref().is_some_and(|tag| !v::node_tag_valid(tag)) {
            return Err(invalid("Некорректные поля SSH ноды."));
        }
        if self.identity.as_deref().is_some_and(|s| !s.is_empty() && s != "system" && s != self.id) {
            return Err(invalid("Некорректная ссылка на SSH-ключ ноды."));
        }
        if self.domain.as_deref().is_some_and(|domain| !v::domain_valid(domain)) {
            return Err(invalid("Некорректный домен ноды."));
        }
        if self.ports.keys().any(|key| !NODE_PORT_KEYS.contains(&key.as_str())) {
            return Err(invalid("Некорректный ключ порта ноды."));
        }
        match self.auth {
            Auth::Key if self.secret_id.is_some() => Err(invalid("У ноды с ключом secret_id должен быть null.")),
            Auth::Password if !self.secret_id.as_deref().is_some_and(|s| v::secret_id_matches(s, &self.id)) => {
                Err(invalid("Некорректная ссылка на пароль ноды."))
            }
            _ => Ok(()),
        }
    }
}

fn unique_names<'a>(names: impl Iterator<Item = &'a str>) -> Result<()> {
    let mut seen = BTreeSet::new();
    for name in names {
        if !v::name_valid(name) { return Err(invalid("Некорректное имя в конфигурации.")); }
        if !seen.insert(name) { return Err(invalid("Повторяющееся имя в конфигурации.")); }
    }
    Ok(())
}

fn invalid(message: &str) -> RcError { RcError::new("invalid", message) }

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PortabilityStatus { #[default] Ready, NeedsSetup }

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PortabilityReason { MissingIdentity, MissingSecret, MissingHostKey }

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct PortabilityIssue {
    pub node_id: String,
    pub reason: PortabilityReason,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Portability {
    pub status: PortabilityStatus,
    pub issues: Vec<PortabilityIssue>,
}

impl Portability {
    /// Sorted unique issues; any issue means `needs_setup`.
    pub fn from_issues(mut issues: Vec<PortabilityIssue>) -> Self {
        issues.sort();
        issues.dedup();
        let status = if issues.is_empty() { PortabilityStatus::Ready } else { PortabilityStatus::NeedsSetup };
        Self { status, issues }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Access {
    pub script_password_hash: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct TemplateMetadata {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot_sha256: Option<String>,
    #[serde(default)]
    pub ignored_builtin_sha256: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Manifest {
    pub schema_version: u32,
    pub minimum_remote_control_version: String,
    pub portability: Portability,
    pub access: Access,
    pub templates: BTreeMap<String, TemplateMetadata>,
}

impl Default for Manifest {
    fn default() -> Self {
        Self {
            schema_version: 2,
            minimum_remote_control_version: crate::VERSION.into(),
            portability: Portability::default(), access: Access::default(), templates: BTreeMap::new(),
        }
    }
}

impl Manifest {
    pub fn validate(&self) -> Result<()> {
        if self.schema_version != 2 || !v::version_valid(&self.minimum_remote_control_version) {
            return Err(invalid("Некорректная версия manifest.json."));
        }
        // Reason/status types are checked by serde. Resource-dependent issues
        // cannot be recomputed without the filesystem and secrets store.
        Ok(())
    }

    pub fn has_actionable_ssh_issues(&self) -> bool {
        self.portability.issues.iter().any(|issue| matches!(issue.reason,
            PortabilityReason::MissingIdentity | PortabilityReason::MissingHostKey))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SourceType { Github }

/// No source file means local mode; a present file is exactly GitHub metadata.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Source {
    #[serde(rename = "type")]
    pub source_type: SourceType,
    pub repo: String,
    pub branch: String,
    pub private_verified: bool,
}

impl Source {
    pub fn validate(&self) -> Result<()> {
        if !v::github_repo_valid(&self.repo) || !v::github_branch_valid(&self.branch) || !self.private_verified {
            return Err(invalid("Некорректные параметры источника GitHub."));
        }
        Ok(())
    }
}

/// Uniform `[host]:port` encoding INCLUDES port 22. Hosts cannot contain brackets
/// under the SSH allowlist, preventing IPv6/DNS endpoint collisions. Host spelling
/// is preserved: this helper does not resolve DNS or normalize IPv6 addresses.
pub fn endpoint_key(host: &str, port: u16) -> Result<EndpointKey> {
    if !v::ssh_host_valid(host) || port == 0 { return Err(invalid("Некорректный SSH endpoint.")); }
    Ok(EndpointKey(format!("[{host}]:{port}")))
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(transparent)]
pub struct EndpointKey(String);

impl EndpointKey {
    pub fn new(host: &str, port: u16) -> Result<Self> { endpoint_key(host, port) }
    pub fn as_str(&self) -> &str { &self.0 }
    pub fn host(&self) -> &str { self.0.strip_prefix('[').unwrap().rsplit_once("]:").unwrap().0 }
    pub fn port(&self) -> u16 { self.0.rsplit_once(':').unwrap().1.parse().unwrap() }
}

impl fmt::Display for EndpointKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { f.write_str(&self.0) }
}

impl FromStr for EndpointKey {
    type Err = RcError;
    fn from_str(value: &str) -> Result<Self> {
        let (host, port) = value.strip_prefix('[').and_then(|s| s.rsplit_once("]:"))
            .ok_or_else(|| invalid("Ключ хоста должен иметь вид [host]:port."))?;
        let key = endpoint_key(host, v::parse_ssh_port(port)?)?;
        if key.as_str() != value { return Err(invalid("Неканонический ключ хоста.")); }
        Ok(key)
    }
}

impl<'de> Deserialize<'de> for EndpointKey {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        String::deserialize(deserializer)?.parse().map_err(serde::de::Error::custom)
    }
}

/// OpenSSH SHA256 fingerprint: canonical unpadded base64 of exactly 32 bytes.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(transparent)]
pub struct Fingerprint(String);

impl Fingerprint {
    pub fn as_str(&self) -> &str { &self.0 }
}

impl fmt::Display for Fingerprint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { f.write_str(&self.0) }
}

impl FromStr for Fingerprint {
    type Err = RcError;
    fn from_str(value: &str) -> Result<Self> {
        let encoded = value.strip_prefix("SHA256:").ok_or_else(|| invalid("Ожидается SHA256-отпечаток."))?;
        // decode_slice requires its conservative output estimate (33 bytes for
        // 43 base64 characters), even though a valid digest contains 32 bytes.
        let mut digest = [0u8; 33];
        if encoded.len() != 43 || base64::engine::general_purpose::STANDARD_NO_PAD.decode_slice(encoded, &mut digest).ok() != Some(32) {
            return Err(invalid("Некорректный SHA256-отпечаток."));
        }
        Ok(Self(value.into()))
    }
}

impl<'de> Deserialize<'de> for Fingerprint {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        String::deserialize(deserializer)?.parse().map_err(serde::de::Error::custom)
    }
}

/// Every key/fingerprint is validated at construction/deserialization; legacy
/// host-only entries cannot enter this map, including for the default port 22.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct KnownHosts(pub BTreeMap<EndpointKey, Vec<Fingerprint>>);

/// A minimal valid profile (VLESS TCP, self-steal) for tests.
#[cfg(test)]
pub(crate) fn test_profile(name: &str) -> Profile {
    Profile {
        name: name.into(), mihomo_version: "v1.19.18".into(), acme_email: "admin@example.com".into(),
        vless_tcp: true, ..Profile::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use serde_json::{Value, json};

    const FIXTURE: &str = include_str!("../../../tests/fixtures/sample_config.json");

    /// The schema-2 fixture as its schema-3 serialization.
    fn fixture() -> Value {
        let mut value: Value = serde_json::from_str(FIXTURE).unwrap();
        value["schema_version"] = json!(3);
        let object = value.as_object_mut().unwrap();
        for key in ["profiles", "cascades", "telegram"] {
            object.insert(key.into(), json!([]));
        }
        value
    }

    /// The fixture with a full profile on both nodes, roles and a host.
    fn profiled() -> Value {
        let mut raw = fixture();
        raw["profiles"] = json!([{
            "name": "main", "mihomo_version": "v1.19.18", "acme_email": "admin@example.com",
            "site_source": "random", "reality_mode": "self-steal", "vless_tcp": true,
            "vless_xhttp": {"topology": "reality", "port": 2083}, "vless_grpc": {"port": 2053},
            "hysteria2": {"port": 8843, "obfs": true}, "amneziawg": {"port": 51820, "dns": "1.1.1.1, 1.0.0.1"},
            "warp": true, "warp_plus": "0123abcd", "ipv6": "disabled"
        }]);
        for node in 0..2 {
            raw["nodes"][node]["profile"] = json!("main");
        }
        raw["nodes"][0]["domain"] = json!("de.example.com");
        raw["nodes"][0]["ports"] = json!({"hysteria2": 9443});
        raw["nodes"][0]["params"] = json!({"reality": {"public_key": "pk", "short_id": "0123456789abcdef"},
            "xhttp_path": "/0123456789abcdef", "awg": {"public_key": "pk", "header_protection_key": "hk", "tproxy_port": 12345,
            "jc": 4, "s1": 20, "s2": 30, "s3": 40}, "warp": {"public_key": "wk", "ipv4": "172.16.0.2", "plus": false}});
        raw["nodes"][0]["applied"] = json!({"digest": "d", "files": {"/etc/mihomo/config.yaml": "sha"}, "ports": ["443/tcp"], "at": "2026-11-14T00:00:00Z"});
        raw["cascades"] = json!([
            {"name": "via-ru", "entry": "de-vps", "listener": "vless-tcp", "exit": {"node": "ru-vps", "proxy": "VLESS TCP"},
             "uuid": "11111111-2222-4333-8444-555555555555", "password": "0123456789abcdef0123456789abcdef"},
            {"name": "outside", "entry": "ru-vps", "listener": "hysteria2", "exit": {"uri": "vless://u@h:443"},
             "uuid": "", "password": ""}]);
        raw["telegram"] = json!([{"node": "de-vps", "hostname": "tg.example.com", "secret_mark": "0123abcd"}]);
        raw["subscription_host"] = json!({"node": "ru-vps", "hostname": "sub.example.com", "port": 8444 + 1000,
            "base_url": "https://sub.example.com:9444", "sub_dir": SUB_DIR, "nginx_group": "www-data"});
        raw["clients"][0]["credentials"]["awg_private_key"] = json!("key");
        raw["clients"][0]["credentials"]["awg_preshared_key"] = json!("psk");
        raw["clients"][0]["credentials"]["awg_index"] = json!(2);
        raw
    }

    fn rejected(raw: Value) -> RcError {
        Config::parse(&serde_json::to_vec(&raw).unwrap()).unwrap_err()
    }

    /// Set the member at `pointer`, creating the last key when absent.
    fn set(raw: &mut Value, pointer: &str, value: Value) {
        let (parent, key) = pointer.rsplit_once('/').unwrap();
        let parent = raw.pointer_mut(parent).unwrap_or_else(|| panic!("{pointer}"));
        match parent {
            Value::Array(items) => items[key.parse::<usize>().unwrap()] = value,
            Value::Object(members) => { members.insert(key.into(), value); }
            _ => panic!("{pointer}"),
        }
    }

    #[test]
    fn real_fixture_roundtrips_domain_fields() {
        let config = Config::parse(FIXTURE.as_bytes()).unwrap();
        assert_eq!(serde_json::to_value(config).unwrap(), fixture());
        let original = profiled();
        let config = Config::parse(&serde_json::to_vec(&original).unwrap()).unwrap();
        assert_eq!(serde_json::to_value(config).unwrap(), original);
    }

    #[test]
    fn schema_two_upgrades_and_other_versions_are_invalid() {
        let mut raw: Value = serde_json::from_str(FIXTURE).unwrap();
        raw["subscription_host"] = json!({"node":"de-vps","base_url":"https://example","sub_dir":"/srv/sub","nginx_group":"www-data"});
        let config = Config::parse(&serde_json::to_vec(&raw).unwrap()).unwrap();
        assert_eq!(config.schema_version, 3);
        assert!(config.subscription_host.is_none() && config.profiles.is_empty());
        for version in [1, 4] {
            let mut raw = fixture();
            raw["schema_version"] = json!(version);
            let error = rejected(raw);
            assert_eq!((error.code, error.message.as_str()), ("invalid", "Ожидается schema_version: 3."));
        }
        let mut raw = fixture();
        raw["subscription_host"] = json!({"node":"de-vps","base_url":"https://example","sub_dir":"/srv/sub","nginx_group":"www-data"});
        assert!(Config::parse(&serde_json::to_vec(&raw).unwrap()).is_err(), "schema 3 keeps the new host shape");
    }

    #[test]
    fn profile_rules_are_enforced() {
        for (pointer, value, message) in [
            ("/profiles/0/name", json!("bad name"), "Некорректное имя в конфигурации."),
            ("/profiles/0/mihomo_version", json!("1.19.18"), "Некорректная версия mihomo: ожидается vX.Y.Z."),
            ("/profiles/0/mihomo_version", json!("v1.19"), "Некорректная версия mihomo: ожидается vX.Y.Z."),
            ("/profiles/0/mihomo_version", json!("v1.19.17"), "Нужен mihomo не ниже v1.19.18."),
            ("/profiles/0/mihomo_version", json!("v0.99.99"), "Нужен mihomo не ниже v1.19.18."),
            ("/profiles/0/acme_email", json!("admin@localhost"), "Некорректный ACME email."),
            ("/profiles/0/reality_mode", json!("sni"), "Для режима sni нужен SNI-домен."),
            ("/profiles/0/sni_domain", json!("www.example.com"), "SNI-домен задаётся только в режиме sni."),
            ("/profiles/0/vless_xhttp", json!({"topology": "nginx", "port": 2083}), "Порт xHTTP задаётся только для топологии reality."),
            ("/profiles/0/vless_xhttp", json!({"topology": "reality"}), "Порт 443 занят двумя подключениями."),
            ("/profiles/0/vless_grpc/port", json!(2083), "Порт 2083 занят двумя подключениями."),
            ("/profiles/0/vless_grpc/port", json!(8443), "Порт 8443 зарезервирован для внутренних служб."),
            ("/profiles/0/vless_grpc/port", json!(0), "Порт должен быть от 1 до 65535."),
            ("/profiles/0/amneziawg/port", json!(8843), "Порт 8843 занят двумя подключениями."),
            ("/profiles/0/amneziawg/port", json!(9090), "Порт 9090 зарезервирован для внутренних служб."),
            ("/profiles/0/warp_plus", json!("XYZ"), "Некорректная метка ключа WARP+."),
            ("/nodes/0/ports", json!({"vless-grpc": 2083}), "Порт 2083 занят двумя подключениями."),
            ("/nodes/0/ports", json!({"vless-tcp": 444}), "Некорректный ключ порта ноды."),
            ("/nodes/0/domain", json!("localhost"), "Некорректный домен ноды."),
            ("/nodes/0/domain", json!("-a.example"), "Некорректный домен ноды."),
        ] {
            let mut raw = profiled();
            set(&mut raw, pointer, value);
            let error = rejected(raw);
            assert_eq!((error.code, error.message.as_str()), ("invalid", message), "{pointer}");
        }
        // SNI mode with a domain is valid without xHTTP over nginx; nginx needs self-steal.
        let mut raw = profiled();
        raw["profiles"][0]["reality_mode"] = json!("sni");
        raw["profiles"][0]["sni_domain"] = json!("www.example.com");
        Config::parse(&serde_json::to_vec(&raw).unwrap()).unwrap();
        raw["profiles"][0]["vless_xhttp"] = json!({"topology": "nginx"});
        assert_eq!(rejected(raw).message, "xHTTP через nginx требует режима self-steal.");
        let mut raw = profiled();
        raw["profiles"][0]["reality_mode"] = json!("sni");
        raw["profiles"][0]["sni_domain"] = json!("bad_domain");
        assert_eq!(rejected(raw).message, "Некорректный SNI-домен.");
        // Hysteria2 and AmneziaWG may share a number with other protocols only across TCP/UDP.
        let mut raw = profiled();
        raw["profiles"][0]["vless_xhttp"] = json!(null);
        raw["profiles"][0]["amneziawg"]["port"] = json!(2053);
        Config::parse(&serde_json::to_vec(&raw).unwrap()).unwrap();
        let mut raw = profiled();
        raw["profiles"][0]["vless_tcp"] = json!(false);
        raw["profiles"][0]["vless_xhttp"] = json!({"topology": "reality"});
        Config::parse(&serde_json::to_vec(&raw).unwrap()).unwrap();
        let mut raw = profiled();
        raw["profiles"][0]["unknown"] = json!(1);
        assert!(Config::parse(&serde_json::to_vec(&raw).unwrap()).is_err());
    }

    #[test]
    fn reference_rules_are_enforced() {
        for (pointer, value, message) in [
            ("/nodes/0/profile", json!("ghost"), "Ссылка на неизвестный профиль."),
            ("/cascades/0/entry", json!("ghost"), "Ссылка на неизвестную ноду."),
            ("/cascades/0/exit/node", json!("de-vps"), "Входная и выходная ноды каскада совпадают."),
            ("/cascades/0/name", json!("Hysteria2"), "Имя каскада совпадает с именем подключения ноды."),
            ("/cascades/1/name", json!("via-ru"), "Повторяющееся имя в конфигурации."),
            ("/cascades/0/uuid", json!(""), "Некорректные учётные данные каскада."),
            ("/cascades/1/uuid", json!("bad"), "Некорректные учётные данные каскада."),
            ("/cascades/1/exit/uri", json!("vless://a b"), "Некорректная ссылка выхода каскада."),
            ("/telegram/0/node", json!("ghost"), "Ссылка на неизвестную ноду."),
            ("/telegram/0/hostname", json!("tg"), "Некорректный домен Telegram Proxy."),
            ("/telegram/0/secret_mark", json!("x"), "Некорректная метка секрета Telegram Proxy."),
            ("/subscription_host/node", json!("ghost"), "Ссылка на неизвестную ноду."),
            ("/subscription_host/hostname", json!("sub"), "Некорректный адрес хостинга подписок."),
        ] {
            let mut raw = profiled();
            set(&mut raw, pointer, value);
            let error = rejected(raw);
            assert_eq!((error.code, error.message.as_str()), ("invalid", message), "{pointer}");
        }
        let profiled_only = "Нода без профиля не может обслуживать подключения.";
        for (pointer, value) in [
            ("/cascades/0/entry", json!("de-vps")), ("/cascades/0/exit/node", json!("de-vps")),
            ("/telegram/0/node", json!("de-vps")), ("/subscription_host/node", json!("de-vps")),
        ] {
            let mut raw = profiled();
            raw["nodes"][0].as_object_mut().unwrap().remove("profile");
            if pointer == "/cascades/0/exit/node" {
                raw["cascades"][0]["entry"] = json!("ru-vps");
                raw["cascades"].as_array_mut().unwrap().truncate(1);
                raw["telegram"] = json!([]);
            } else if pointer != "/cascades/0/entry" {
                raw["cascades"] = json!([]);
                if pointer != "/telegram/0/node" { raw["telegram"] = json!([]); }
            }
            *raw.pointer_mut(pointer).unwrap() = value;
            assert_eq!(rejected(raw).message, profiled_only, "{pointer}");
        }
        let mut raw = profiled();
        raw["telegram"] = json!([{"node": "de-vps", "hostname": "a.example", "secret_mark": "0123abcd"},
            {"node": "de-vps", "hostname": "b.example", "secret_mark": "0123abcd"}]);
        assert_eq!(rejected(raw).message, "На ноде может быть только один Telegram Proxy.");
        let mut raw = profiled();
        let profile = raw["profiles"][0].clone();
        raw["profiles"] = json!([profile.clone(), profile]);
        assert_eq!(rejected(raw).message, "Повторяющееся имя в конфигурации.");
    }

    #[test]
    fn subscription_headers_and_metadata_are_retained() {
        let mut original = profiled();
        original["subscription_default_headers"] = json!([]);
        original["groups"][0]["subscription_headers"] = json!([{"name":"h","value":"v"}]);
        original["clients"][0]["subscription"] = json!({"token":"a".repeat(64),"created_at":"2026-11-09T00:00:00Z","expires_at":null,"headers":[{"name":"profile-update-interval","value":"12"}]});
        let config: Config = serde_json::from_value(original.clone()).unwrap();
        config.validate().unwrap();
        assert_eq!(serde_json::to_value(config).unwrap(), original);
    }

    #[test]
    fn ordinary_serde_normalizes_optional_defaults() {
        let mut raw = fixture();
        raw["unknown"] = json!({"ignored":true});
        raw["subscription_host"] = Value::Null;
        raw["groups"][0].as_object_mut().unwrap().remove("template");
        raw["clients"][0]["nodes"] = Value::Null;
        let config: Config = serde_json::from_value(raw).unwrap();
        assert_eq!(config.groups[0].template, "default.yaml");
        assert!(config.clients[0].nodes.is_none());
        let normalized = serde_json::to_value(config).unwrap();
        assert!(normalized.get("unknown").is_none());
        assert!(normalized.get("subscription_host").is_none());
        assert!(normalized["clients"][0].get("nodes").is_none());
    }

    #[test]
    fn default_is_real_initial_config() {
        assert_eq!(serde_json::to_value(Config::default()).unwrap(), json!({
            "schema_version":3,"nodes":[],"groups":[
                {"name":"ROUTER","template":"default.yaml"},
                {"name":"PC","template":"default.yaml"},
                {"name":"MOBILE","template":"default.yaml"}],"clients":[],"connections":[],
            "profiles":[],"cascades":[],"telegram":[]
        }));
        Config::default().validate().unwrap();
    }

    #[test]
    fn subscription_base_urls() {
        assert_eq!(SubscriptionHost::base_url_for("sub.example.com", 443), "https://sub.example.com");
        assert_eq!(SubscriptionHost::base_url_for("sub.example.com", 2096), "https://sub.example.com:2096");
        assert_eq!(SubscriptionHost::parse_base_url("https://h.example:2096/"), Some(("h.example".into(), 2096)));
        assert_eq!(SubscriptionHost::parse_base_url("https://h.example"), Some(("h.example".into(), 443)));
        assert_eq!(SubscriptionHost::parse_base_url("http://h.example"), None);
        assert_eq!(SubscriptionHost::parse_base_url("https://h.example:0"), None);
    }

    #[test]
    fn bad_linkage_references_and_duplicates_fail() {
        for (pointer, value) in [
            ("/schema_version", json!(1)), ("/nodes/0/port", json!(0)),
            ("/nodes/0/id", json!("../bad")), ("/nodes/0/name", json!("")),
            ("/nodes/0/name", json!("old display / имя")), ("/nodes/0/tag", json!("bad:tag")),
            ("/groups/0/name", json!("..")), ("/clients/0/name", json!("bad/name")),
            ("/nodes/0/user", json!("-option")), ("/nodes/0/ip", json!("host\n")),
            ("/nodes/0/identity", json!("../../key")),
            ("/nodes/0/secret_id", json!("node:11111111111111111111111111111111:ssh-password")),
            ("/nodes/1/secret_id", json!("node:11111111111111111111111111111111:ssh-password")),
            ("/connections/0/node", json!("unknown")),
            ("/connections/0/groups/1/name", json!("ROUTER")),
            ("/clients/1/nodes/0", json!("unknown")),
            ("/clients/1/connections/0/node", json!("unknown")),
            ("/nodes/1/id", json!("11111111111111111111111111111111")),
            ("/nodes/1/name", json!("de-vps")),
            ("/groups/1/name", json!("ROUTER")),
            ("/clients/1/name", json!("my-router")),
        ] {
            let mut raw = fixture(); *raw.pointer_mut(pointer).unwrap() = value;
            assert!(serde_json::from_value::<Config>(raw).unwrap().validate().is_err(), "accepted {pointer}");
        }
        for port in [json!(65536), json!(-1), json!(1.5), json!("22")] {
            let mut raw = fixture(); raw["nodes"][0]["port"] = port;
            assert!(serde_json::from_value::<Config>(raw).is_err());
        }
        let mut raw = fixture(); raw["nodes"][0]["pass"] = Value::Null;
        assert!(serde_json::from_value::<Config>(raw).is_err());
        let mut raw = fixture(); raw["nodes"][0].as_object_mut().unwrap().remove("secret_id");
        assert!(serde_json::from_value::<Config>(raw).is_err());
        let mut raw = fixture(); raw.as_object_mut().unwrap().remove("groups");
        assert!(serde_json::from_value::<Config>(raw).is_err());
    }

    #[test]
    fn unicode_tags_ipv6_and_hex_case_are_supported() {
        let mut raw = fixture();
        raw["nodes"][0]["id"] = json!("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        raw["nodes"][0]["tag"] = json!("🇩🇪 Германия");
        raw["nodes"][0]["ip"] = json!("2001:db8::1");
        serde_json::from_value::<Config>(raw).unwrap().validate().unwrap();
    }

    #[test]
    fn exact_manifest_and_source_shapes() {
        let original = json!({"schema_version":2,"minimum_remote_control_version":"1.1.0",
            "portability":{"status":"needs_setup","issues":[{"node_id":"id","reason":"missing_identity"}]},
            "access":{"script_password_hash":null},"templates":{"default.yaml":{"content":"proxies: []","source":"builtin","snapshot_sha256":"sha","ignored_builtin_sha256":null}}});
        let manifest: Manifest = serde_json::from_value(original.clone()).unwrap();
        manifest.validate().unwrap();
        assert!(manifest.has_actionable_ssh_issues());
        assert_eq!(serde_json::to_value(manifest).unwrap(), original);
        let raw = json!({"type":"github","repo":"owner/repo","branch":"main","private_verified":true});
        let source: Source = serde_json::from_value(raw.clone()).unwrap();
        source.validate().unwrap();
        assert_eq!(serde_json::to_value(source).unwrap(), raw);
        for (field, value) in [("repo", json!("owner/repo/extra")), ("branch", json!("a b")), ("private_verified", json!(false))] {
            let mut bad = raw.clone(); bad[field] = value;
            assert!(serde_json::from_value::<Source>(bad).unwrap().validate().is_err());
        }
        let mut bad = raw; bad["sync"] = json!("clean");
        assert!(serde_json::from_value::<Source>(bad).is_err());
    }

    #[test]
    fn host_keys_are_endpoint_scoped_and_fingerprints_strict() {
        let a = endpoint_key("::1", 22).unwrap();
        assert_eq!(a.as_str(), "[::1]:22");
        assert_eq!(a.host(), "::1"); assert_eq!(a.port(), 22);
        assert_ne!(a, endpoint_key("::1", 2222).unwrap());
        assert_eq!(endpoint_key("example.com", 22).unwrap().as_str(), "[example.com]:22");
        let fp = format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode([42u8;32]));
        assert!(fp.parse::<Fingerprint>().is_ok());
        for bad in ["SHA256:", "SHA256:abc", "MD5:00", &format!("{fp}="), &format!("{fp}\n")] { assert!(bad.parse::<Fingerprint>().is_err()); }
        let raw = json!({"[::1]:22":[fp]});
        let pins: KnownHosts = serde_json::from_value(raw.clone()).unwrap();
        assert_eq!(serde_json::to_value(pins).unwrap(), raw);
        for bad in ["host", "[host]:0", "[host]:022", "[host]:65536", "[[::1]]:22"] { assert!(bad.parse::<EndpointKey>().is_err()); }
        assert!(serde_json::from_value::<KnownHosts>(json!({"host":[]})).is_err());
    }

    proptest! {
        #[test]
        fn endpoint_keys_roundtrip_without_host_port_collisions(host in "[A-Za-z0-9:][A-Za-z0-9.:_-]{0,80}", port in 1u16..=u16::MAX) {
            let key = endpoint_key(&host, port).unwrap();
            prop_assert_eq!(key.host(), host.as_str());
            prop_assert_eq!(key.port(), port);
            prop_assert_eq!(key.as_str().parse::<EndpointKey>().unwrap(), key.clone());
            let other_port = if port == u16::MAX { 1 } else { port + 1 };
            prop_assert_ne!(key, endpoint_key(&host, other_port).unwrap());
        }
        #[test]
        fn arbitrary_sha256_digests_roundtrip(digest in any::<[u8;32]>()) {
            let encoded = format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode(digest));
            let fp: Fingerprint = encoded.parse().unwrap();
            prop_assert_eq!(fp.as_str(), encoded.as_str());
        }
    }
}
