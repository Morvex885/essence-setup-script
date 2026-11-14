//! Pure render of a node's desired server state: mihomo config, systemd unit,
//! sysctl, nginx site and stream front, the executor spec, firewall ports,
//! plan lines and the digest that decides whether a node needs `node apply`.
//! Nothing here touches the network or the data directory.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::clients::generate::{User, effective_connections, node_users};
use crate::error::{RcError, Result};
use crate::model::{Config, Ipv6, Node, Profile, RealityMode, SiteSource, XhttpTopology};
use crate::protocols::vless_xhttp::NginxListener;
use crate::protocols::{Vless, VlessListener, hy2, listener_users, vless_grpc, vless_tcp, vless_xhttp, yaml_escape};

use super::paths::{MIHOMO_CONFIG_PATH, MIHOMO_SERVICE_PATH, SITES_AVAILABLE, SITES_ENABLED, STREAM_PATH, SYSCTL_PATH};
use super::ports::{REALITY_INNER_PORT, SITE_PORT, SUB_INNER_PORT, TG_INNER_PORT, XHTTP_NGINX_PORT};

/// Bumped whenever rendered files change for an unchanged configuration.
pub const RENDER_REVISION: u32 = 4;

const MIHOMO_CONFIG: &str = include_str!("assets/mihomo-config.yaml");
const MIHOMO_SERVICE: &str = include_str!("assets/mihomo.service");
const SYSCTL: &str = include_str!("assets/sysctl.conf");
const SYSCTL_IPV6_DISABLED: &str = include_str!("assets/sysctl-ipv6-disabled.txt");
const SYSCTL_IPV6_ENABLED: &str = include_str!("assets/sysctl-ipv6-enabled.txt");
const SYSCTL_IPV6_FORWARDING: &str = "net.ipv6.conf.all.forwarding = 1";
const NGINX_SITE: &str = include_str!("assets/nginx-site.conf");
const NGINX_XHTTP: &str = include_str!("assets/nginx-xhttp-location.conf");

/// Credentials of the client blocks; `generate` replaces them per client.
pub const PLACEHOLDER_UUID: &str = "00000000-0000-0000-0000-000000000000";
pub const PLACEHOLDER_PASSWORD: &str = "placeholder";

/// Who owns the public 443 of the node.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Front { SelfSteal, Stream, Bare, Free }

/// One managed file. `mode` is four octal digits or `link` (content = target).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RenderedFile {
    pub path: String,
    pub mode: &'static str,
    pub owner: &'static str,
    pub group: &'static str,
    /// Empty when rendered without secrets.
    pub content: Zeroizing<String>,
}

/// Private node values from the secret store (read by the caller).
#[derive(Default)]
pub struct NodeSecrets {
    pub reality_key: Option<Zeroizing<String>>,
    pub awg_key: Option<Zeroizing<String>>,
    pub warp_key: Option<Zeroizing<String>>,
    pub telegram_secret: Option<Zeroizing<String>>,
    pub telegram_tag: Option<Zeroizing<String>>,
}

/// Everything `node apply` needs for one node.
pub struct Desired {
    /// The profile was removed: everything installed goes.
    pub teardown: bool,
    pub files: Vec<RenderedFile>,
    pub remove: Vec<String>,
    pub spec: Vec<(&'static str, String)>,
    /// Firewall rules (`443/tcp`, `8843/udp`).
    pub ports: Vec<String>,
    pub lines: Vec<String>,
    pub digest: String,
}

impl Desired {
    /// Also allow `port` (sshd's own port behind NAT) when UFW is enabled.
    pub fn add_ssh_port(&mut self, port: u16) {
        if let Some((_, ports)) = self.spec.iter_mut().find(|(key, _)| *key == "SSH_PORTS")
            && !ports.split(' ').any(|known| known == port.to_string())
        {
            ports.push_str(&format!(" {port}"));
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind { Tcp, Xhttp, XhttpNginx, Grpc, Hy2 }

/// One mihomo listener of the profile on this node.
#[derive(Clone, Copy, Debug)]
struct Listener {
    kind: Kind,
    /// Connection name (`VLESS TCP`), also the listener name.
    name: &'static str,
    /// `listener-users` marker.
    marker: &'static str,
    listen: &'static str,
    port: u16,
    /// What clients dial.
    client_port: u16,
}

/// The node's place in the topology, derived from its profile and roles.
struct Layout<'a> {
    config: &'a Config,
    node: &'a Node,
    profile: &'a Profile,
    front: Front,
    /// The node's own site (its domain) when the profile needs one.
    site: Option<&'a str>,
    /// Address clients dial.
    server: &'a str,
    /// Reality `dest` and SNI.
    dest: String,
    sni: &'a str,
    listeners: Vec<Listener>,
}

fn invalid(message: String) -> RcError { RcError::new("invalid", message) }

/// The effective port of a protocol: the node override, else the profile's.
fn effective(node: &Node, key: &str, port: u16) -> u16 {
    node.ports.get(key).copied().unwrap_or(port)
}

/// Whether the node serves a role on the public 443 (Telegram, subscriptions).
fn role_on_443(config: &Config, node: &Node) -> bool {
    config.telegram.iter().any(|proxy| proxy.node == node.name)
        || config.subscription_host.as_ref().is_some_and(|host| host.node == node.name && host.port == 443)
}

/// A self-steal profile serving Reality, xHTTP through nginx or Hysteria2
/// needs the node's own site (domain, certificate, stub pages).
fn needs_site(profile: &Profile) -> bool {
    profile.reality_mode == RealityMode::SelfSteal
        && (profile.has_reality() || profile.vless_xhttp.is_some() || profile.hysteria2.is_some())
}

/// Clients of a listener: assigned to the node and using the listener (a
/// client without connections on the node uses all of them), with the
/// credential the listener needs. A listener without them is not rendered.
fn listener_users<'u>(config: &Config, node: &Node, users: &'u [User<'u>], listener: &Listener) -> Vec<(&'u str, &'u str)> {
    users.iter().filter(|user| {
        let connections = effective_connections(config, user.client, &node.name);
        connections.is_empty() || connections.iter().any(|name| name == listener.name)
    }).map(|user| (user.name, if listener.kind == Kind::Hy2 { user.password } else { user.uuid }))
        .filter(|(_, credential)| !credential.is_empty()).collect()
}

/// Reality takes the 443 front only when one of its rendered listeners (with
/// users) is on 443; otherwise the node's site and roles answer 443 themselves.
fn front(config: &Config, node: &Node, profile: &Profile, users: &[User<'_>]) -> Front {
    let reality_on_443 = listeners(node, profile, Front::Free).iter().any(|listener| {
        listener.port == 443 && matches!(listener.kind, Kind::Tcp | Kind::Xhttp | Kind::Grpc)
            && !listener_users(config, node, users, listener).is_empty()
    });
    match (reality_on_443, profile.reality_mode) {
        (false, _) => Front::Free,
        (true, RealityMode::SelfSteal) => Front::SelfSteal,
        (true, RealityMode::Sni) if role_on_443(config, node) => Front::Stream,
        (true, RealityMode::Sni) => Front::Bare,
    }
}

fn listeners(node: &Node, profile: &Profile, front: Front) -> Vec<Listener> {
    // A Reality listener on 443 sits behind the stream front on 8444.
    let reality = |kind, name, marker, port: u16| match (port, front) {
        (443, Front::Stream) => Listener { kind, name, marker, listen: "127.0.0.1", port: REALITY_INNER_PORT, client_port: 443 },
        _ => Listener { kind, name, marker, listen: "0.0.0.0", port, client_port: port },
    };
    let mut out = Vec::new();
    if profile.vless_tcp {
        out.push(reality(Kind::Tcp, "VLESS TCP", "vless-tcp", 443));
    }
    match profile.vless_xhttp.as_ref() {
        Some(xhttp) if xhttp.topology == XhttpTopology::Reality => {
            out.push(reality(Kind::Xhttp, "VLESS xHTTP", "vless-xhttp", effective(node, "vless-xhttp", xhttp.port.unwrap_or(443))));
        }
        Some(_) => out.push(Listener {
            kind: Kind::XhttpNginx, name: "VLESS xHTTP", marker: "vless-xhttp", listen: "127.0.0.1",
            port: XHTTP_NGINX_PORT, client_port: 443,
        }),
        None => {}
    }
    if let Some(grpc) = &profile.vless_grpc {
        out.push(reality(Kind::Grpc, "VLESS gRPC", "vless-grpc", effective(node, "vless-grpc", grpc.port)));
    }
    if let Some(hy2) = &profile.hysteria2 {
        let port = effective(node, "hysteria2", hy2.port);
        out.push(Listener { kind: Kind::Hy2, name: "Hysteria2", marker: "hy2", listen: "0.0.0.0", port, client_port: port });
    }
    out
}

fn layout<'a>(config: &'a Config, node: &'a Node) -> Result<Option<Layout<'a>>> {
    let Some(profile) = node.profile.as_deref().and_then(|name| config.find_profile(name)) else { return Ok(None) };
    // Invalid users fail `desired` itself; here they only leave 443 to the site.
    let front = front(config, node, profile, &node_users(config, &node.name).unwrap_or_default());
    let site = if needs_site(profile) {
        Some(node.domain.as_deref().filter(|domain| !domain.is_empty()).ok_or_else(|| {
            RcError::new("domain_required", format!("Для ноды «{0}» нужен домен: node domain --name {0} --domain D.", node.name))
                .with_extra("name", node.name.clone())
        })?)
    } else {
        None
    };
    let sni_domain = profile.sni_domain.as_deref().unwrap_or_default();
    let (dest, sni) = match (profile.reality_mode, site) {
        // Self-steal borrows the node's own site: behind Reality on 8443, on
        // 443 itself when Reality listens elsewhere.
        (RealityMode::SelfSteal, Some(domain)) if front == Front::SelfSteal => (format!("127.0.0.1:{SITE_PORT}"), domain),
        (RealityMode::SelfSteal, Some(domain)) => ("127.0.0.1:443".to_owned(), domain),
        _ => (format!("{sni_domain}:443"), sni_domain),
    };
    let layout = Layout {
        config, node, profile, front, site, server: site.unwrap_or(&node.ip), dest, sni,
        listeners: listeners(node, profile, front),
    };
    layout.check_ports()?;
    Ok(Some(layout))
}

impl Layout<'_> {
    /// nginx answers the public 443 itself (site or roles without Reality).
    fn nginx_on_443(&self) -> bool {
        self.front == Front::Free && (self.site.is_some() || role_on_443(self.config, self.node))
    }

    fn nginx(&self) -> bool {
        self.site.is_some() || self.front == Front::Stream || role_on_443(self.config, self.node)
    }

    /// `(port, protocol)` rules of the firewall, in listener order.
    fn rules(&self) -> Vec<String> {
        let mut rules = Vec::new();
        let mut push = |rule: String| if !rules.contains(&rule) { rules.push(rule) };
        if self.front != Front::Free || self.nginx_on_443() {
            push("443/tcp".into());
        }
        for listener in &self.listeners {
            match listener.kind {
                Kind::XhttpNginx => {}
                Kind::Hy2 => {
                    push(format!("{}/udp", listener.port));
                    push(format!("{}/tcp", listener.port));
                }
                _ if listener.client_port != 443 => push(format!("{}/tcp", listener.port)),
                _ => {}
            }
        }
        rules
    }

    /// Listening ports must not collide with SSH or the AmneziaWG tproxy port.
    fn check_ports(&self) -> Result<()> {
        let mut tcp: BTreeSet<u16> = self.listeners.iter().map(|l| l.port).collect();
        if self.front != Front::Free || self.nginx_on_443() {
            tcp.insert(443);
        }
        if self.site.is_some() && self.front == Front::SelfSteal {
            tcp.insert(SITE_PORT);
        }
        if tcp.contains(&self.node.port) {
            return Err(invalid(format!("Порт {} ноды «{}» занят SSH.", self.node.port, self.node.name)).with_extra("port", self.node.port));
        }
        if let Some(awg) = &self.node.params.awg {
            let udp = self.profile.amneziawg.as_ref().map(|awg| effective(self.node, "amneziawg", awg.port));
            if tcp.contains(&awg.tproxy_port) || udp == Some(awg.tproxy_port) || awg.tproxy_port == self.node.port {
                return Err(invalid(format!("Порт {} ноды «{}» занят перехватом AmneziaWG.", awg.tproxy_port, self.node.name))
                    .with_extra("port", awg.tproxy_port));
            }
        }
        Ok(())
    }

    fn missing_params(&self) -> RcError {
        invalid(format!("У ноды «{}» нет сгенерированных параметров профиля.", self.node.name))
    }

    fn reality(&self) -> Result<(&str, &str)> {
        self.node.params.reality.as_ref().map(|r| (r.public_key.as_str(), r.short_id.as_str())).ok_or_else(|| self.missing_params())
    }

    fn xhttp_path(&self) -> Result<&str> {
        self.node.params.xhttp_path.as_deref().ok_or_else(|| self.missing_params())
    }

    fn grpc_service(&self) -> Result<&str> {
        self.node.params.grpc_service.as_deref().ok_or_else(|| self.missing_params())
    }

    fn hy2_obfs(&self) -> Result<&str> {
        match self.profile.hysteria2.as_ref() {
            Some(hy2) if hy2.obfs => self.node.params.hy2_obfs_password.as_deref().ok_or_else(|| self.missing_params()),
            _ => Ok(""),
        }
    }

    /// Hysteria2 uses the site certificate, otherwise a self-signed one.
    fn hy2_tls(&self) -> (String, String, &str, bool) {
        match self.site {
            Some(domain) => (format!("/etc/nginx/ssl/{domain}/fullchain.pem"), format!("/etc/nginx/ssl/{domain}/privkey.pem"), domain, false),
            None => (String::new(), String::new(), self.sni, true),
        }
    }

    fn users<'u>(&self, users: &'u [User<'u>], listener: &Listener) -> Vec<(&'u str, &'u str)> {
        listener_users(self.config, self.node, users, listener)
    }

    fn node_users(&self) -> Result<Vec<User<'_>>> {
        node_users(self.config, &self.node.name).ok_or_else(|| invalid(format!(
            "Недопустимое имя или учётные данные клиента ноды «{}» в конфигурации.", self.node.name)))
    }

    /// One wrapped listener block with all its users.
    fn listener_block(&self, listener: &Listener, users: &[(&str, &str)], private_key: &str) -> Result<String> {
        let (username, credential) = users[0];
        let port = listener.port.to_string();
        // The shared builders write these inside double quotes as given (Bash
        // parity); the server config escapes them. Generated values are
        // unchanged by escaping.
        let private_key = yaml_escape(private_key);
        let short_id = self.node.params.reality.as_ref().map(|reality| yaml_escape(&reality.short_id));
        let vless = |name| -> Result<VlessListener<'_>> {
            let short_id = short_id.as_deref().ok_or_else(|| self.missing_params())?;
            Ok(VlessListener {
                name, listen: listener.listen, port: &port, username, uuid: credential, dest: &self.dest,
                private_key: &private_key, short_id, sni: self.sni, proxy: "outbound",
            })
        };
        let block = match listener.kind {
            Kind::Tcp => vless_tcp::listener_yaml(&vless(listener.name)?),
            Kind::Xhttp => vless_xhttp::listener_yaml(&vless(listener.name)?, self.xhttp_path()?),
            Kind::Grpc => vless_grpc::listener_yaml(&vless(listener.name)?, self.grpc_service()?),
            Kind::XhttpNginx => vless_xhttp::nginx_listener_yaml(&NginxListener {
                name: listener.name, listen: listener.listen, port: &port, username, uuid: credential,
                path: self.xhttp_path()?, proxy: "outbound",
            }),
            Kind::Hy2 => {
                let (certificate, private_key, _, _) = self.hy2_tls();
                hy2::listener_yaml(&hy2::Hy2Listener {
                    name: listener.name, port: &port, user: username, password: credential, proxy: "outbound",
                    obfs_password: self.hy2_obfs()?, certificate: &certificate, private_key: &private_key,
                })
            }
        };
        // Inbound goes through the `essence-in` sub-rule instead of straight
        // to `outbound` (as Bash cascades do: `proxy:` becomes `rule:`).
        let routed = block.replacen(&format!("\n    proxy: {INBOUND_PROXY}\n"), &format!("\n    rule: {INBOUND_RULE}\n"), 1);
        if routed == block {
            return Err(RcError::new("failed", format!("Не удалось собрать листенер {}.", listener.name)));
        }
        let marker = listener.marker;
        let wrapped = format!("# --- {marker} ---\n{routed}# --- /{marker} ---\n");
        let users_yaml = if listener.kind == Kind::Hy2 {
            listener_users::hy2_users_yaml(users.iter().copied())
        } else {
            listener_users::vless_users_yaml(marker, users.iter().copied())
        };
        listener_users::sync(&wrapped, marker, &users_yaml)
            .ok_or_else(|| RcError::new("failed", format!("Не удалось собрать листенер {}.", listener.name)))
    }

    fn mihomo_config(&self, users: &[User<'_>], private_key: &str) -> Result<String> {
        let mut listeners = String::new();
        for listener in &self.listeners {
            let listener_users = self.users(users, listener);
            if !listener_users.is_empty() {
                listeners.push_str(&self.listener_block(listener, &listener_users, private_key)?);
            }
        }
        let ipv6 = if self.profile.ipv6 == Ipv6::Enabled { "ipv6: true" } else { "ipv6: false" };
        Ok(fill_template(MIHOMO_CONFIG, &[
            ("#@ipv6", ipv6.to_owned()), ("#@tproxy", String::new()), ("#@proxies", String::new()),
            ("#@outbound", String::new()), ("#@groups", String::new()), ("#@listeners", listeners),
            ("#@sub-rules", inbound_sub_rules()),
        ]))
    }

    /// `Enabled` sets `disable_ipv6 = 0` explicitly: `sysctl --system` only
    /// applies what files set, so a node leaving `Disabled` gets IPv6 back.
    fn sysctl(&self) -> String {
        match self.profile.ipv6 {
            Ipv6::Default => SYSCTL.to_owned(),
            Ipv6::Enabled => format!("{SYSCTL}{SYSCTL_IPV6_ENABLED}"),
            Ipv6::Disabled => {
                let mut text: String = SYSCTL.lines().filter(|line| *line != SYSCTL_IPV6_FORWARDING)
                    .map(|line| format!("{line}\n")).collect();
                text.push_str(SYSCTL_IPV6_DISABLED);
                text
            }
        }
    }

    fn site_config(&self, domain: &str) -> String {
        let listen = match self.front {
            Front::SelfSteal => format!("    listen 127.0.0.1:{SITE_PORT} ssl http2;"),
            _ => "    listen 443 ssl http2;\n    listen [::]:443 ssl http2;".to_owned(),
        };
        let location = match (self.profile.vless_xhttp.as_ref(), self.node.params.xhttp_path.as_deref()) {
            (Some(xhttp), Some(path)) if xhttp.topology == XhttpTopology::Nginx => NGINX_XHTTP
                .replace("{{path}}", path).replace("{{port}}", &XHTTP_NGINX_PORT.to_string()),
            _ => String::new(),
        };
        fill_template(&NGINX_SITE.replace("{{domain}}", domain), &[("{{listen}}", listen), ("{{xhttp_location}}", location)])
    }

    fn stream_config(&self) -> String {
        let sub = self.config.subscription_host.as_ref()
            .filter(|host| host.node == self.node.name && host.port == 443).map(|host| host.hostname.as_str());
        let telegram = self.config.telegram.iter().find(|proxy| proxy.node == self.node.name).map(|proxy| proxy.hostname.as_str());
        let mut text = String::from("stream {\n    map $ssl_preread_server_name $backend {\n");
        if let Some(host) = sub { text.push_str(&format!("        {host} subscription;\n")); }
        if let Some(host) = telegram { text.push_str(&format!("        {host} telegram_proxy;\n")); }
        text.push_str("        default mihomo;\n    }\n");
        if sub.is_some() { text.push_str(&format!("    upstream subscription {{ server 127.0.0.1:{SUB_INNER_PORT}; }}\n")); }
        if telegram.is_some() { text.push_str(&format!("    upstream telegram_proxy {{ server 127.0.0.1:{TG_INNER_PORT}; }}\n")); }
        text.push_str(&format!("    upstream mihomo {{ server 127.0.0.1:{REALITY_INNER_PORT}; }}\n"));
        text.push_str("    server {\n        listen 443;\n        listen [::]:443;\n        proxy_pass $backend;\n        ssl_preread on;\n    }\n}\n");
        text
    }

    /// Managed files; contents only with `secrets` (users and the Reality
    /// key), otherwise just the paths and modes.
    fn files(&self, secrets: Option<(&[User<'_>], &str)>) -> Result<Vec<RenderedFile>> {
        let text = |render: &dyn Fn() -> Result<String>| if secrets.is_some() { render() } else { Ok(String::new()) };
        let mut files = vec![
            file(MIHOMO_CONFIG_PATH, "0600", text(&|| {
                let (users, private_key) = secrets.unwrap_or_default();
                self.mihomo_config(users, private_key)
            })?),
            file(MIHOMO_SERVICE_PATH, "0644", text(&|| Ok(MIHOMO_SERVICE.to_owned()))?),
            file(SYSCTL_PATH, "0644", text(&|| Ok(self.sysctl()))?),
        ];
        if let Some(domain) = self.site {
            files.push(file(&format!("{SITES_AVAILABLE}{domain}"), "0644", text(&|| Ok(self.site_config(domain)))?));
            files.push(file(&format!("{SITES_ENABLED}{domain}"), "link", text(&|| Ok(format!("{SITES_AVAILABLE}{domain}")))?));
        }
        if self.front == Front::Stream {
            files.push(file(STREAM_PATH, "0644", text(&|| Ok(self.stream_config()))?));
        }
        Ok(files)
    }

    /// Every rendered listener has the generated parameters it needs (the
    /// same checks the file render makes, without rendering).
    fn check_params(&self, users: &[User<'_>]) -> Result<()> {
        for listener in self.listeners.iter().filter(|listener| !self.users(users, listener).is_empty()) {
            if matches!(listener.kind, Kind::Tcp | Kind::Xhttp | Kind::Grpc) {
                self.reality()?;
            }
            match listener.kind {
                Kind::Xhttp | Kind::XhttpNginx => { self.xhttp_path()?; }
                Kind::Grpc => { self.grpc_service()?; }
                Kind::Hy2 => { self.hy2_obfs()?; }
                Kind::Tcp => {}
            }
        }
        Ok(())
    }

    /// TCP ports that must listen once the configuration is active.
    fn listen_tcp(&self, users: &[User<'_>]) -> Vec<u16> {
        let mut ports: BTreeSet<u16> = self.listeners.iter()
            .filter(|listener| listener.kind != Kind::Hy2 && !self.users(users, listener).is_empty())
            .map(|listener| listener.port).collect();
        if self.site.is_some() {
            ports.insert(if self.front == Front::SelfSteal { SITE_PORT } else { 443 });
        }
        if self.front == Front::Stream || self.nginx_on_443() {
            ports.insert(443);
        }
        ports.into_iter().collect()
    }

    /// Canonical digest input: everything the rendered files depend on.
    fn digest(&self, users: &[User<'_>]) -> String {
        let mut profile = serde_json::to_value(self.profile).unwrap_or(Value::Null);
        if let Some(object) = profile.as_object_mut() {
            object.remove("name");
        }
        let mut listener_users = serde_json::Map::new();
        for listener in &self.listeners {
            let users = self.users(users, listener);
            if !users.is_empty() {
                listener_users.insert(listener.marker.into(), json!(users.iter().map(|(n, c)| [n, c]).collect::<Vec<_>>()));
            }
        }
        let host = self.config.subscription_host.as_ref().filter(|host| host.node == self.node.name);
        let telegram = self.config.telegram.iter().find(|proxy| proxy.node == self.node.name);
        digest_of(&json!({
            "revision": RENDER_REVISION, "profile": profile, "ip": self.node.ip, "port": self.node.port,
            "domain": self.node.domain, "ports": self.node.ports, "params": self.node.params, "users": listener_users,
            "awg_peers": [], "cascades": [], "subscription_host": host, "telegram": telegram, "tg_revision": null,
        }))
    }
}

/// The group every inbound connection ends in.
const INBOUND_PROXY: &str = "outbound";
/// The sub-rule every listener routes through (`rule:`).
pub const INBOUND_RULE: &str = "essence-in";
/// Destinations no client may reach through the node: its loopback,
/// link-local (cloud metadata) and private networks. Every inbound sub-rule
/// (cascades too) starts with these. Without `no-resolve`: a domain is
/// resolved and rejected when it points into these networks.
pub const INBOUND_REJECT: [&str; 9] = [
    "IP-CIDR,127.0.0.0/8", "IP-CIDR6,::1/128", "IP-CIDR,169.254.0.0/16", "IP-CIDR,10.0.0.0/8", "IP-CIDR,172.16.0.0/12",
    "IP-CIDR,192.168.0.0/16", "IP-CIDR,100.64.0.0/10", "IP-CIDR6,fc00::/7", "IP-CIDR6,fe80::/10",
];

/// `sub-rules:` with `essence-in`: the rejects, then `outbound`.
fn inbound_sub_rules() -> String {
    let mut text = format!("sub-rules:\n  {INBOUND_RULE}:\n");
    for rule in INBOUND_REJECT {
        text.push_str(&format!("    - {rule},REJECT\n"));
    }
    text.push_str(&format!("    - MATCH,{INBOUND_PROXY}\n"));
    text
}

fn file(path: &str, mode: &'static str, content: String) -> RenderedFile {
    RenderedFile { path: path.to_owned(), mode, owner: "root", group: "root", content: Zeroizing::new(content) }
}

fn digest_of(value: &Value) -> String {
    hex::encode(Sha256::digest(serde_json::to_vec(value).unwrap_or_default()))
}

/// Replace whole-line `keys` with their text (dropped when empty). A YAML
/// section header directly followed by an empty insertion becomes `[]`, so
/// `proxies:`/`listeners:` stay sequences instead of null.
fn fill_template(template: &str, inserts: &[(&str, String)]) -> String {
    let lookup = |line: &str| inserts.iter().find(|(key, _)| *key == line).map(|(_, text)| text.trim_end_matches('\n'));
    let lines: Vec<&str> = template.lines().collect();
    let mut out = String::with_capacity(template.len());
    for (index, line) in lines.iter().enumerate() {
        if let Some(text) = lookup(line) {
            if !text.is_empty() {
                out.push_str(text);
                out.push('\n');
            }
            continue;
        }
        let empty_section = line.ends_with(':') && !line.starts_with(' ')
            && lines.get(index + 1).and_then(|next| lookup(next)).is_some_and(str::is_empty);
        out.push_str(line);
        if empty_section {
            out.push_str(" []");
        }
        out.push('\n');
    }
    out
}

fn site_source(source: SiteSource) -> &'static str {
    match source {
        SiteSource::Simple => "simple",
        SiteSource::Sni => "sni",
        SiteSource::Nothing => "nothing",
        SiteSource::Random => "random",
    }
}

fn bool_text(value: bool) -> String { if value { "true" } else { "false" }.to_owned() }

/// Site names of an applied file set (`sites-available/<name>`).
fn applied_sites(node: &Node) -> Vec<String> {
    node.applied.iter().flat_map(|applied| applied.files.keys())
        .filter_map(|path| path.strip_prefix(SITES_AVAILABLE)).map(str::to_owned).collect()
}

/// Paths of the previous set that the new one no longer has, with the
/// `sites-enabled` link of every removed site.
fn removed(node: &Node, keep: &BTreeSet<&str>) -> Vec<String> {
    let mut remove = BTreeSet::new();
    for path in node.applied.iter().flat_map(|applied| applied.files.keys()) {
        if !keep.contains(path.as_str()) {
            remove.insert(path.clone());
            if let Some(site) = path.strip_prefix(SITES_AVAILABLE) {
                remove.insert(format!("{SITES_ENABLED}{site}"));
            }
        }
    }
    remove.into_iter().collect()
}

fn reality_line(profile: &Profile) -> String {
    match (profile.has_reality(), profile.reality_mode) {
        (false, _) => "Reality: нет".into(),
        (true, RealityMode::SelfSteal) => "Reality: Self-Steal".into(),
        (true, RealityMode::Sni) => format!("Reality: SNI {}", profile.sni_domain.as_deref().unwrap_or_default()),
    }
}

/// The desired state of a node. Without `secrets` the file contents stay
/// empty (status, plan); everything else is the same.
pub fn desired(config: &Config, node: &Node, secrets: Option<&NodeSecrets>) -> Result<Desired> {
    let Some(layout) = layout(config, node)? else {
        if node.applied.is_none() {
            return Err(invalid(format!("У ноды «{}» нет профиля.", node.name)).with_extra("name", node.name.clone()));
        }
        return Ok(teardown(node));
    };
    let users = layout.node_users()?;
    layout.check_params(&users)?;
    let contents = secrets.map(|s| (users.as_slice(), s.reality_key.as_deref().map(String::as_str).unwrap_or_default()));
    let files = layout.files(contents)?;
    let keep: BTreeSet<&str> = files.iter().map(|f| f.path.as_str()).collect();
    let remove = removed(node, &keep);
    let release: Vec<String> = applied_sites(node).into_iter().filter(|site| layout.site != Some(site.as_str())).collect();
    let ports = layout.rules();
    let profile = layout.profile;
    let (_, _, hy2_cn, hy2_cert) = layout.hy2_tls();
    let hy2_cert = hy2_cert && profile.hysteria2.is_some();
    let site = layout.site.unwrap_or_default();
    let spec = vec![
        ("OP_MODE", "apply".to_owned()),
        ("SSH_PORTS", node.port.to_string()),
        ("LISTEN_TCP", layout.listen_tcp(&users).iter().map(u16::to_string).collect::<Vec<_>>().join(" ")),
        ("MIHOMO_VERSION", profile.mihomo_version.clone()),
        ("NGINX", bool_text(layout.nginx())),
        ("NGINX_STREAM", bool_text(layout.front == Front::Stream)),
        ("SITE_NAME", site.to_owned()),
        ("SITE_SOURCE", if site.is_empty() { String::new() } else { site_source(profile.site_source).to_owned() }),
        ("SITE_REQUIRE_200", bool_text(!site.is_empty() && layout.front == Front::SelfSteal)),
        ("CERTS", if site.is_empty() { String::new() } else { format!("{site}:/var/www/{site}") }),
        ("ACME_EMAIL", profile.acme_email.clone()),
        ("DNS_DOMAINS", site.to_owned()),
        ("HY2_CERT", bool_text(hy2_cert)),
        ("HY2_CN", if hy2_cert { hy2_cn.to_owned() } else { String::new() }),
        ("UFW_RULES", ports.join(" ")),
        ("RELEASE_CERTS", release.iter().map(|name| format!("{name}:/var/www/{name}")).collect::<Vec<_>>().join(" ")),
        ("FEATURES", String::new()),
        ("REMOVE_FEATURES", String::new()),
    ];

    let mut lines = vec![
        format!("Нода: {}  {}:{}", node.name, node.ip, node.port),
        format!("Профиль: {}", profile.name),
        format!("Mihomo: {}", profile.mihomo_version),
        reality_line(profile),
        match layout.site {
            Some(domain) => format!("Сайт-заглушка: {domain} ({})", site_source(profile.site_source)),
            None => "Сайт-заглушка: нет".to_owned(),
        },
    ];
    for listener in &layout.listeners {
        let count = layout.users(&users, listener).len();
        lines.push(if count == 0 {
            format!("{}: нет клиентов — входное подключение не создаётся.", listener.name)
        } else {
            format!("{}: порт {}, клиентов {count}", listener.name, listener.client_port)
        });
    }
    lines.extend(remove.iter().map(|path| format!("Будет удалено: {path}")));
    lines.extend(release.iter().map(|name| format!("Будет удалён сертификат и сайт: {name}")));
    if node.applied.is_none() {
        lines.push(format!("Первая установка: UFW будет включён, если выключен (SSH TCP/{} разрешён).", node.port));
    }
    Ok(Desired { teardown: false, digest: layout.digest(&users), files, remove, spec, ports, lines })
}

fn teardown_digest() -> String {
    digest_of(&json!({"revision": RENDER_REVISION, "teardown": true}))
}

/// Removing everything installed from an applied node: a removed profile or
/// `node delete --scope server`.
pub fn teardown(node: &Node) -> Desired {
    let mut remove: BTreeSet<String> = BTreeSet::from(["/etc/mihomo".to_owned()]);
    for path in node.applied.iter().flat_map(|applied| applied.files.keys()) {
        remove.insert(path.clone());
        if let Some(site) = path.strip_prefix(SITES_AVAILABLE) {
            remove.insert(format!("{SITES_ENABLED}{site}"));
        }
    }
    let remove: Vec<String> = remove.into_iter().collect();
    let release = applied_sites(node);
    let mut lines = vec![
        format!("Нода: {}  {}:{}", node.name, node.ip, node.port),
        "Профиль снят: всё установленное Essence будет удалено.".to_owned(),
    ];
    lines.extend(remove.iter().map(|path| format!("Будет удалено: {path}")));
    lines.extend(release.iter().map(|name| format!("Будет удалён сертификат и сайт: {name}")));
    let spec = vec![
        ("OP_MODE", "teardown".to_owned()),
        ("SSH_PORTS", node.port.to_string()),
        ("UFW_RULES", String::new()),
        ("RELEASE_CERTS", release.iter().map(|name| format!("{name}:/var/www/{name}")).collect::<Vec<_>>().join(" ")),
        ("FEATURES", String::new()),
        ("REMOVE_FEATURES", "awg sub telegram".to_owned()),
    ];
    Desired { teardown: true, files: Vec::new(), remove, spec, ports: Vec::new(), lines, digest: teardown_digest() }
}

/// `none` (no profile, nothing applied), `running`, `applied` or `pending`
/// (including a configuration that does not render).
pub fn status(config: &Config, node: &Node) -> &'static str {
    if node.operation.is_some() {
        return "running";
    }
    if node.profile.is_none() && node.applied.is_none() {
        return "none";
    }
    match (desired(config, node, None), node.applied.as_ref()) {
        (Ok(desired), Some(applied)) if desired.digest == applied.digest => "applied",
        _ => "pending",
    }
}

/// Connection names the node serves: enabled protocols, then its cascades.
pub fn proxies(config: &Config, node: &Node) -> Vec<String> {
    let Some(profile) = node.profile.as_deref().and_then(|name| config.find_profile(name)) else { return Vec::new() };
    let mut names: Vec<String> = listeners(node, profile, Front::Free).iter().map(|l| l.name.to_owned()).collect();
    if profile.amneziawg.is_some() {
        names.push("AWG".into());
    }
    names.extend(config.cascades.iter().filter(|cascade| cascade.entry == node.name).map(|cascade| cascade.name.clone()));
    names
}

/// The node's client proxies in the `proxies:` … `---` form `generate`
/// parses, with placeholder credentials. `None` when the node has no profile,
/// lacks a needed domain or generated parameters.
pub fn client_section(config: &Config, node: &Node) -> Option<String> {
    let layout = layout(config, node).ok()??;
    let mut out = String::from("proxies:\n");
    for listener in &layout.listeners {
        let port = listener.client_port.to_string();
        let block = match listener.kind {
            Kind::Hy2 => {
                let (_, _, sni, skip_cert_verify) = layout.hy2_tls();
                hy2::client_yaml(&hy2::Hy2 {
                    name: listener.name, server: layout.server, port: &port, password: PLACEHOLDER_PASSWORD,
                    sni, skip_cert_verify, obfs_password: layout.hy2_obfs().ok()?,
                })
            }
            Kind::XhttpNginx => vless_xhttp::client_yaml(&Vless {
                name: listener.name, server: layout.server, port: &port, uuid: PLACEHOLDER_UUID,
                sni: layout.site.unwrap_or_default(), public_key: "", short_id: "",
            }, layout.xhttp_path().ok()?),
            kind => {
                let (public_key, short_id) = layout.reality().ok()?;
                let vless = Vless {
                    name: listener.name, server: layout.server, port: &port, uuid: PLACEHOLDER_UUID,
                    sni: layout.sni, public_key, short_id,
                };
                match kind {
                    Kind::Tcp => vless_tcp::client_yaml(&vless),
                    Kind::Xhttp => vless_xhttp::client_yaml(&vless, layout.xhttp_path().ok()?),
                    _ => vless_grpc::client_yaml(&vless, layout.grpc_service().ok()?),
                }
            }
        };
        out.push_str(block.split_once('\n').map_or("", |(_, rest)| rest));
    }
    out.push_str("---\n");
    Some(out)
}

/// SHA-256 of rendered file contents by path (links are not recorded).
pub fn file_hashes(files: &[RenderedFile]) -> BTreeMap<String, String> {
    files.iter().filter(|file| file.mode != "link")
        .map(|file| (file.path.clone(), hex::encode(Sha256::digest(file.content.as_bytes())))).collect()
}

#[cfg(test)]
mod tests;
