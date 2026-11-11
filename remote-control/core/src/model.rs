//! Schema-v2 logical state. Ordinary serde models normalize absent/null/default
//! fields; this is a clean schema cutover, not a legacy compatibility layer.
//! Validation is local and effect-free: resource existence belongs to storage.

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subscription_host: Option<SubscriptionHost>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subscription_default_headers: Option<Vec<SubscriptionHeader>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub minimum_remote_control_version: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            schema_version: 2,
            nodes: Vec::new(),
            groups: ["ROUTER", "PC", "MOBILE"].into_iter().map(|name| Group {
                name: name.into(), ..Group::default()
            }).collect(),
            clients: Vec::new(),
            connections: Vec::new(),
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
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
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
}

fn required_nullable<'de, D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Option<String>, D::Error> {
    Option::<String>::deserialize(deserializer)
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
}

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

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SubscriptionHost {
    pub node: String,
    pub base_url: String,
    pub sub_dir: String,
    #[serde(default = "default_nginx_group")]
    pub nginx_group: String,
}

impl Config {
    /// Canonical name/tag and linkage validation, shared with mutation inputs.
    /// Template resource existence is checked separately by storage/commands.
    pub fn validate(&self) -> Result<()> {
        if self.schema_version != 2 {
            return Err(invalid("Ожидается schema_version: 2."));
        }
        if self.minimum_remote_control_version.as_deref().is_some_and(|s| !s.is_empty() && !v::version_valid(s)) {
            return Err(invalid("Некорректная minimum_remote_control_version."));
        }
        let mut ids = BTreeSet::new();
        let mut names = BTreeSet::new();
        for node in &self.nodes {
            node.validate()?;
            if !ids.insert(node.id.as_str()) || !names.insert(node.name.as_str()) {
                return Err(invalid("Повторяющийся идентификатор или имя ноды."));
            }
        }
        unique_names(self.groups.iter().map(|g| g.name.as_str()))?;
        unique_names(self.clients.iter().map(|c| c.name.as_str()))?;
        let require_node = |name: &str| {
            if names.contains(name) { Ok(()) } else { Err(invalid("Ссылка на неизвестную ноду.")) }
        };
        for connection in &self.connections { require_node(&connection.node)?; }
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
        Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use serde_json::{Value, json};

    fn fixture() -> Value {
        serde_json::from_str(include_str!("../../../tests/fixtures/sample_config.json")).unwrap()
    }

    #[test]
    fn real_fixture_roundtrips_domain_fields() {
        let original = fixture();
        let config: Config = serde_json::from_value(original.clone()).unwrap();
        config.validate().unwrap();
        assert_eq!(serde_json::to_value(config).unwrap(), original);
    }

    #[test]
    fn subscription_headers_and_metadata_are_retained() {
        let mut original = fixture();
        original["subscription_host"] = json!({"node":"de-vps","base_url":"https://example","sub_dir":"/srv/sub","nginx_group":"www-data"});
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
            "schema_version":2,"nodes":[],"groups":[
                {"name":"ROUTER","template":"default.yaml"},
                {"name":"PC","template":"default.yaml"},
                {"name":"MOBILE","template":"default.yaml"}],"clients":[],"connections":[]
        }));
        Config::default().validate().unwrap();
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
