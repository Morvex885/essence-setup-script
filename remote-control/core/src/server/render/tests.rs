//! Tests of `render`: topology, files, spec, plan lines and digest.

use super::*;
use crate::model::{
    Applied, AmneziaWg, Client, ClientCredentials, Connection, ConnectionGroup, Hysteria2, NodeAwg, NodeParams,
    NodeReality, PortOnly, SubscriptionHost, TelegramProxy, Xhttp,
};

const UUID: &str = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";

fn profile() -> Profile {
    Profile {
        name: "main".into(), mihomo_version: "v1.19.18".into(), acme_email: "admin@example.com".into(),
        vless_tcp: true, ..Profile::default()
    }
}

fn sni(profile: Profile) -> Profile {
    Profile { reality_mode: RealityMode::Sni, sni_domain: Some("www.example.org".into()), ..profile }
}

fn node() -> Node {
    Node {
        id: "a".repeat(32), name: "de".into(), ip: "198.51.100.7".into(), port: 22, user: "root".into(),
        profile: Some("main".into()), domain: Some("de.example.com".into()),
        params: NodeParams {
            reality: Some(NodeReality { public_key: "PUBKEY".into(), short_id: "0123456789abcdef".into() }),
            xhttp_path: Some("/0123456789abcdef".into()), grpc_service: Some("grpc-01234567".into()),
            hy2_obfs_password: Some("f".repeat(24)), ..NodeParams::default()
        },
        ..Node::default()
    }
}

fn client(name: &str, password: &str) -> Client {
    Client {
        name: name.into(), group: "PC".into(),
        credentials: Some(ClientCredentials { vless_uuid: UUID.into(), hy2_password: password.into(), ..ClientCredentials::default() }),
        ..Client::default()
    }
}

/// One node, client `alpha` in PC using every connection on it.
fn config(profile: Profile) -> Config {
    Config {
        profiles: vec![profile],
        nodes: vec![node()],
        clients: vec![client("alpha", "alpha-pass")],
        connections: vec![Connection { node: "de".into(), groups: vec![ConnectionGroup {
            name: "PC".into(), proxies: CONNECTION_NAMES.iter().map(|name| name.to_string()).collect(),
        }] }],
        ..Config::default()
    }
}

use crate::model::CONNECTION_NAMES;

const TG_SECRET: &str = "0123456789abcdef0123456789abcdef";

fn secrets() -> NodeSecrets {
    NodeSecrets {
        reality_key: Some(Zeroizing::new("PRIVKEY".into())), telegram_secret: Some(Zeroizing::new(TG_SECRET.into())),
        ..NodeSecrets::default()
    }
}

fn render(config: &Config) -> Desired {
    desired(config, &config.nodes[0], Some(&secrets())).unwrap()
}

fn content<'a>(desired: &'a Desired, path: &str) -> &'a str {
    desired.files.iter().find(|file| file.path == path).map(|file| file.content.as_str())
        .unwrap_or_else(|| panic!("no {path}"))
}

fn spec<'a>(desired: &'a Desired, key: &str) -> &'a str {
    desired.spec.iter().find(|(k, _)| *k == key).map(|(_, v)| v.as_str()).unwrap_or_else(|| panic!("no {key}"))
}

fn paths(desired: &Desired) -> Vec<&str> {
    desired.files.iter().map(|file| file.path.as_str()).collect()
}

fn yaml(text: &str) -> saphyr::Yaml<'_> {
    use saphyr::LoadableYamlNode;
    saphyr::Yaml::load_from_str(text).unwrap().into_iter().next().unwrap()
}

#[test]
fn self_steal_front_serves_reality_on_443_with_the_node_site() {
    let config = config(profile());
    let desired = render(&config);
    let mihomo = content(&desired, MIHOMO_CONFIG_PATH);
    assert!(mihomo.contains("# --- vless-tcp ---\n  - name: VLESS TCP\n    type: vless\n    listen: 0.0.0.0\n    port: 443\n"), "{mihomo}");
    assert!(mihomo.contains("      dest: \"127.0.0.1:8443\"\n      private-key: \"PRIVKEY\"\n"));
    assert!(mihomo.contains("      server-names:\n        - \"de.example.com\"\n"));
    assert!(mihomo.contains(&format!("      - username: alpha\n        uuid: {UUID}\n        flow: xtls-rprx-vision\n")));
    assert!(mihomo.contains("ipv6: false\n") && !mihomo.contains("#@"));
    let site = content(&desired, "/etc/nginx/sites-available/de.example.com");
    assert!(site.starts_with("# Essence site de.example.com\nserver {\n    listen 127.0.0.1:8443 ssl http2;\n    server_name de.example.com;\n"), "{site}");
    assert!(!site.contains("{{") && !site.contains("location /0123"));
    assert_eq!(content(&desired, "/etc/nginx/sites-enabled/de.example.com"), "/etc/nginx/sites-available/de.example.com");
    assert_eq!(paths(&desired), [MIHOMO_CONFIG_PATH, MIHOMO_SERVICE_PATH, SYSCTL_PATH,
        "/etc/nginx/sites-available/de.example.com", "/etc/nginx/sites-enabled/de.example.com"]);
    assert_eq!((spec(&desired, "NGINX"), spec(&desired, "NGINX_STREAM"), spec(&desired, "SITE_REQUIRE_200")), ("true", "false", "true"));
    assert_eq!((spec(&desired, "SITE_NAME"), spec(&desired, "SITE_SOURCE")), ("de.example.com", "simple"));
    assert_eq!(spec(&desired, "CERTS"), "de.example.com:/var/www/de.example.com");
    assert_eq!(spec(&desired, "DNS_DOMAINS"), "de.example.com");
    assert_eq!((spec(&desired, "UFW_RULES"), spec(&desired, "HY2_CERT")), ("443/tcp", "false"));
    assert_eq!(spec(&desired, "SUPPORTED_OS"), crate::server::os::spec_value());
    let client = client_section(&config, &config.nodes[0]).unwrap();
    assert!(client.starts_with("proxies:\n  - name: \"VLESS TCP\"\n    type: vless\n    server: de.example.com\n    port: 443\n"), "{client}");
    assert!(client.contains("    servername: \"de.example.com\"\n") && client.ends_with("---\n"));
    assert_eq!(desired.lines, [
        "Нода: de  198.51.100.7:22", "Профиль: main", "Mihomo: v1.19.18", "Reality: Self-Steal",
        "Сайт-заглушка: de.example.com (simple)", "VLESS TCP: порт 443, клиентов 1",
        "Первая установка: UFW будет включён, если выключен (SSH TCP/22 разрешён).",
    ]);
}

#[test]
fn self_steal_without_reality_on_443_leaves_443_to_the_site() {
    // gRPC on 20000 and xHTTP through nginx: no Reality listener on 443.
    let profile = Profile {
        vless_tcp: false, vless_grpc: Some(PortOnly { port: 20000 }),
        vless_xhttp: Some(Xhttp { topology: XhttpTopology::Nginx, port: None }), ..profile()
    };
    let config = config(profile);
    let desired = render(&config);
    let site = content(&desired, "/etc/nginx/sites-available/de.example.com");
    assert!(site.starts_with("# Essence site de.example.com\nserver {\n    listen 443 ssl http2;\n    listen [::]:443 ssl http2;\n"), "{site}");
    assert!(site.contains("location /0123456789abcdef"));
    let mihomo = content(&desired, MIHOMO_CONFIG_PATH);
    assert!(mihomo.contains("  - name: VLESS gRPC\n    type: vless\n    listen: 0.0.0.0\n    port: 20000\n"), "{mihomo}");
    assert!(mihomo.contains("      dest: \"127.0.0.1:443\"\n") && mihomo.contains("        - \"de.example.com\"\n"));
    assert!(!mihomo.contains("    port: 443\n"));
    assert_eq!((spec(&desired, "SITE_REQUIRE_200"), spec(&desired, "UFW_RULES")), ("false", "443/tcp 20000/tcp"));
    assert_eq!(spec(&desired, "LISTEN_TCP"), "443 8447 20000");
    let client = client_section(&config, &config.nodes[0]).unwrap();
    assert!(client.contains("  - name: \"VLESS xHTTP\"\n    type: vless\n    server: de.example.com\n    port: 443\n"), "{client}");

    // The same in SNI mode has no site: nothing of Essence answers 443.
    let sni_profile = Profile { vless_xhttp: None, ..sni(config.profiles[0].clone()) };
    let mut sni_config = self::config(sni_profile);
    sni_config.nodes[0].domain = None;
    sni_config.nodes[0].port = 443;
    let desired = render(&sni_config);
    assert_eq!((spec(&desired, "NGINX"), spec(&desired, "UFW_RULES"), spec(&desired, "LISTEN_TCP")), ("false", "20000/tcp", "20000"));
}

#[test]
fn self_steal_with_reality_on_443_keeps_the_site_behind_it() {
    let profile = Profile { vless_grpc: Some(PortOnly { port: 20000 }), ..profile() };
    let desired = render(&config(profile));
    let site = content(&desired, "/etc/nginx/sites-available/de.example.com");
    assert!(site.starts_with("# Essence site de.example.com\nserver {\n    listen 127.0.0.1:8443 ssl http2;\n"), "{site}");
    assert!(content(&desired, MIHOMO_CONFIG_PATH).contains("      dest: \"127.0.0.1:8443\"\n"));
    assert_eq!((spec(&desired, "UFW_RULES"), spec(&desired, "LISTEN_TCP")), ("443/tcp 20000/tcp", "443 8443 20000"));
}

#[test]
fn the_reality_key_and_short_id_are_escaped_in_the_server_config() {
    let mut config = config(profile());
    config.nodes[0].params.reality.as_mut().unwrap().short_id = "ab\"\n  - x".into();
    let secrets = NodeSecrets { reality_key: Some(Zeroizing::new("K\"\n  - name: open".into())), ..NodeSecrets::default() };
    let desired = desired(&config, &config.nodes[0], Some(&secrets)).unwrap();
    let mihomo = content(&desired, MIHOMO_CONFIG_PATH);
    assert!(mihomo.contains("      private-key: \"K\\\"\\n  - name: open\"\n      short-id:\n        - \"ab\\\"\\n  - x\"\n"), "{mihomo}");
    // Generated values (base64url key, hex short id) are written unchanged.
    let key = "Ab-_".repeat(10) + "xyz";
    assert_eq!(yaml_escape(&key), key.as_str());
    assert!(matches!(yaml_escape("0123456789abcdef"), std::borrow::Cow::Borrowed(_)));
}

#[test]
fn without_secrets_only_paths_digest_lines_and_ports() {
    let config = config(profile());
    let bare = desired(&config, &config.nodes[0], None).unwrap();
    let full = render(&config);
    assert!(bare.files.iter().all(|file| file.content.is_empty()));
    assert_eq!((paths(&bare), &bare.digest, &bare.lines, &bare.ports), (paths(&full), &full.digest, &full.lines, &full.ports));
    let mut broken = config.clone();
    broken.nodes[0].params.reality = None;
    assert_eq!(desired(&broken, &broken.nodes[0], None).err().map(|error| error.code), Some("invalid"));
}

#[test]
fn bare_and_stream_fronts_share_the_client_block() {
    let mut config = config(sni(profile()));
    config.nodes[0].domain = None;
    let bare = render(&config);
    let mihomo = content(&bare, MIHOMO_CONFIG_PATH);
    assert!(mihomo.contains("    listen: 0.0.0.0\n    port: 443\n"));
    assert!(mihomo.contains("      dest: \"www.example.org:443\"\n") && mihomo.contains("        - \"www.example.org\"\n"));
    assert_eq!(paths(&bare), [MIHOMO_CONFIG_PATH, MIHOMO_SERVICE_PATH, SYSCTL_PATH]);
    assert_eq!((spec(&bare, "NGINX"), spec(&bare, "SITE_NAME"), spec(&bare, "CERTS")), ("false", "", ""));
    let bare_client = client_section(&config, &config.nodes[0]).unwrap();
    assert!(bare_client.contains("    server: 198.51.100.7\n    port: 443\n") && bare_client.contains("servername: \"www.example.org\""));

    // A Telegram role on 443 turns the front into the nginx stream.
    config.telegram.push(TelegramProxy { node: "de".into(), hostname: "tg.example.com".into(), secret_mark: "0123abcd".into(), tag_mark: None });
    let stream = render(&config);
    let mihomo = content(&stream, MIHOMO_CONFIG_PATH);
    assert!(mihomo.contains("    listen: 127.0.0.1\n    port: 8444\n"), "{mihomo}");
    assert_eq!((spec(&stream, "NGINX"), spec(&stream, "NGINX_STREAM")), ("true", "true"));
    assert_eq!(content(&stream, STREAM_PATH), "stream {\n    map $ssl_preread_server_name $backend {\n        tg.example.com telegram_proxy;\n\
        \x20       default mihomo;\n    }\n    upstream telegram_proxy { server 127.0.0.1:8446; }\n    upstream mihomo { server 127.0.0.1:8444; }\n\
        \x20   server {\n        listen 443;\n        listen [::]:443;\n        proxy_pass $backend;\n        ssl_preread on;\n    }\n}\n");
    assert_eq!(client_section(&config, &config.nodes[0]).unwrap(), bare_client, "clients keep their config");
    assert_ne!(stream.digest, bare.digest);

    // A subscription host on 443 joins the map; on another port it does not.
    config.subscription_host = Some(SubscriptionHost { node: "de".into(), hostname: "sub.example.com".into(), port: 443,
        base_url: "https://sub.example.com".into(), sub_dir: SUB_DIR.into(), nginx_group: "www-data".into() });
    assert!(content(&render(&config), STREAM_PATH).contains("        sub.example.com subscription;\n        tg.example.com telegram_proxy;\n"));
}

use crate::model::SUB_DIR;

#[test]
fn free_front_without_reality_opens_only_protocol_ports() {
    let mut profile = sni(profile());
    profile.vless_tcp = false;
    profile.hysteria2 = Some(Hysteria2 { port: 8843, obfs: false });
    let mut config = config(profile);
    config.nodes[0].domain = None;
    let desired = render(&config);
    assert_eq!(spec(&desired, "UFW_RULES"), "8843/udp 8843/tcp");
    assert_eq!(desired.ports, ["8843/udp", "8843/tcp"]);
    assert_eq!(spec(&desired, "NGINX"), "false");
}

#[test]
fn hysteria2_uses_the_site_certificate_or_a_self_signed_one() {
    let mut with_site = profile();
    with_site.hysteria2 = Some(Hysteria2 { port: 8843, obfs: true });
    let config_site = config(with_site.clone());
    let desired = render(&config_site);
    let mihomo = content(&desired, MIHOMO_CONFIG_PATH);
    assert!(mihomo.contains("    certificate: /etc/nginx/ssl/de.example.com/fullchain.pem\n    private-key: /etc/nginx/ssl/de.example.com/privkey.pem\n"));
    assert!(mihomo.contains("      alpha: \"alpha-pass\"\n") && mihomo.contains(&format!("    obfs-password: \"{}\"\n", "f".repeat(24))));
    assert_eq!((spec(&desired, "HY2_CERT"), spec(&desired, "HY2_CN")), ("false", ""));
    assert_eq!(spec(&desired, "UFW_RULES"), "443/tcp 8843/udp 8843/tcp");
    let client = client_section(&config_site, &config_site.nodes[0]).unwrap();
    assert!(client.contains("  - name: \"Hysteria2\"\n    type: hysteria2\n    server: de.example.com\n    port: 8843\n    password: \"placeholder\"\n    sni: \"de.example.com\"\n    skip-cert-verify: false\n"), "{client}");

    let mut config_sni = config(sni(with_site));
    config_sni.nodes[0].domain = None;
    let desired = render(&config_sni);
    let mihomo = content(&desired, MIHOMO_CONFIG_PATH);
    assert!(mihomo.contains("    certificate: /etc/mihomo/certs/hy2/server.crt\n    private-key: /etc/mihomo/certs/hy2/server.key\n"));
    assert_eq!((spec(&desired, "HY2_CERT"), spec(&desired, "HY2_CN")), ("true", "www.example.org"));
    let client = client_section(&config_sni, &config_sni.nodes[0]).unwrap();
    assert!(client.contains("    server: 198.51.100.7\n    port: 8843\n    password: \"placeholder\"\n    sni: \"www.example.org\"\n    skip-cert-verify: true\n"));
}

#[test]
fn listeners_without_users_are_not_rendered_and_sections_stay_sequences() {
    let mut config = config(profile());
    config.connections[0].groups[0].proxies = vec!["Hysteria2".into()];
    let desired = render(&config);
    let mihomo = content(&desired, MIHOMO_CONFIG_PATH);
    assert!(mihomo.contains("\nproxies: []\n") && mihomo.contains("\nlisteners: []\n"), "{mihomo}");
    let document = yaml(mihomo);
    assert!(document["proxies"].is_sequence() && document["listeners"].is_sequence());
    assert!(desired.lines.contains(&"VLESS TCP: нет клиентов — входное подключение не создаётся.".to_owned()));
    // With users the listeners section is a sequence of one mapping.
    let mihomo = content(&render(&self::config(profile())), MIHOMO_CONFIG_PATH).to_owned();
    let document = yaml(&mihomo);
    assert_eq!(document["listeners"].as_vec().map(Vec::len), Some(1));
}

#[test]
fn every_listener_routes_through_the_inbound_sub_rule() {
    // TCP, xHTTP (reality), gRPC and Hysteria2 listeners.
    let profile = Profile {
        vless_xhttp: Some(Xhttp { topology: XhttpTopology::Reality, port: Some(2083) }),
        vless_grpc: Some(PortOnly { port: 2053 }), hysteria2: Some(Hysteria2 { port: 8843, obfs: true }), ..profile()
    };
    let mihomo = content(&render(&config(profile)), MIHOMO_CONFIG_PATH).to_owned();
    let document = yaml(&mihomo);
    let listeners = document["listeners"].as_vec().unwrap();
    assert_eq!(listeners.len(), 4);
    for listener in listeners {
        assert_eq!(listener["rule"].as_str(), Some("essence-in"), "{mihomo}");
    }
    assert!(!mihomo.contains("\n    proxy: "), "no listener bypasses the rules: {mihomo}");
    let rules: Vec<&str> = document["sub-rules"]["essence-in"].as_vec().unwrap().iter().map(|rule| rule.as_str().unwrap()).collect();
    // Without `no-resolve`: a domain that resolves into a rejected range is
    // rejected too. The node's own address comes last.
    assert_eq!(rules, [
        "IP-CIDR,127.0.0.0/8,REJECT", "IP-CIDR6,::1/128,REJECT", "IP-CIDR,169.254.0.0/16,REJECT",
        "IP-CIDR,10.0.0.0/8,REJECT", "IP-CIDR,172.16.0.0/12,REJECT", "IP-CIDR,192.168.0.0/16,REJECT",
        "IP-CIDR,100.64.0.0/10,REJECT", "IP-CIDR6,fc00::/7,REJECT", "IP-CIDR6,fe80::/10,REJECT",
        "IP-CIDR,198.51.100.7/32,REJECT", "MATCH,outbound",
    ]);
    assert!(!mihomo.contains("no-resolve"), "{mihomo}");
}

#[test]
fn the_node_rejects_its_own_address() {
    let mut config = config(profile());
    config.nodes[0].ip = "2001:db8::7".into();
    let mihomo = content(&render(&config), MIHOMO_CONFIG_PATH).to_owned();
    assert!(mihomo.contains("    - IP-CIDR6,2001:db8::7/128,REJECT\n"), "{mihomo}");
    // A host name cannot be matched by address.
    config.nodes[0].ip = "de.example.com".into();
    let mihomo = content(&render(&config), MIHOMO_CONFIG_PATH).to_owned();
    assert!(!mihomo.contains("de.example.com/"), "{mihomo}");
}

#[test]
fn a_client_without_connections_on_the_node_uses_every_listener() {
    let mut config = config(profile());
    config.clients.push(Client { inherit_nodes_from_group: false, nodes: Some(vec!["de".into()]),
        group: "MOBILE".into(), ..client("beta", "beta-pass") });
    let mihomo = content(&render(&config), MIHOMO_CONFIG_PATH).to_owned();
    assert!(mihomo.contains("      - username: beta\n"), "{mihomo}");
    config.clients[0].credentials.as_mut().unwrap().vless_uuid = "bad".into();
    assert_eq!(desired(&config, &config.nodes[0], None).err().unwrap().code, "invalid");
}

#[test]
fn a_site_needs_the_node_domain() {
    let mut config = config(profile());
    config.nodes[0].domain = None;
    let error = desired(&config, &config.nodes[0], None).err().unwrap();
    assert_eq!((error.code, error.message.as_str()), ("domain_required", "Для ноды «de» нужен домен: node domain --name de --domain D."));
    assert_eq!(error.extra["name"], "de");
    assert!(client_section(&config, &config.nodes[0]).is_none());
    assert_eq!(status(&config, &config.nodes[0]), "pending");
}

#[test]
fn ports_conflicting_with_ssh_or_tproxy_are_invalid_and_overrides_apply() {
    let mut profile = profile();
    profile.vless_grpc = Some(PortOnly { port: 2053 });
    let mut config = config(profile);
    config.nodes[0].port = 2053;
    let error = desired(&config, &config.nodes[0], None).err().unwrap();
    assert_eq!((error.code, error.extra["port"].clone()), ("invalid", serde_json::json!(2053)));
    config.nodes[0].port = 443;
    assert!(desired(&config, &config.nodes[0], None).err().unwrap().message.contains("443"));
    // The self-steal site behind Reality listens on 8443.
    config.nodes[0].port = SITE_PORT;
    assert_eq!(desired(&config, &config.nodes[0], None).err().unwrap().extra["port"], serde_json::json!(SITE_PORT));
    config.nodes[0].port = 22;

    config.nodes[0].ports.insert("vless-grpc".into(), 2083);
    let desired_override = render(&config);
    assert!(content(&desired_override, MIHOMO_CONFIG_PATH).contains("  - name: VLESS gRPC\n    type: vless\n    listen: 0.0.0.0\n    port: 2083\n"));
    assert_eq!(spec(&desired_override, "UFW_RULES"), "443/tcp 2083/tcp");
    assert!(client_section(&config, &config.nodes[0]).unwrap().contains("  - name: \"VLESS gRPC\"\n    type: vless\n    server: de.example.com\n    port: 2083\n"));

    config.profiles[0].amneziawg = Some(AmneziaWg { port: 51820, dns: "1.1.1.1".into() });
    config.nodes[0].params.awg = Some(NodeAwg { public_key: "k".into(), header_protection_key: "h".into(), tproxy_port: 2083,
        jc: 4, s1: 20, s2: 30, s3: 40 });
    assert!(desired(&config, &config.nodes[0], None).err().unwrap().message.contains("AmneziaWG"));
}

#[test]
fn three_ipv6_states() {
    let mut config = config(profile());
    let default = render(&config);
    assert!(content(&default, MIHOMO_CONFIG_PATH).contains("\nipv6: false\n"));
    assert_eq!(content(&default, SYSCTL_PATH), SYSCTL);
    config.profiles[0].ipv6 = Ipv6::Enabled;
    let enabled = render(&config);
    assert!(content(&enabled, MIHOMO_CONFIG_PATH).contains("\nipv6: true\n"));
    assert_eq!(content(&enabled, SYSCTL_PATH), format!("{SYSCTL}\n# IPv6 включён по запросу пользователя\n\
        net.ipv6.conf.all.disable_ipv6 = 0\nnet.ipv6.conf.default.disable_ipv6 = 0\nnet.ipv6.conf.lo.disable_ipv6 = 0\n"),
        "leaving Disabled turns IPv6 back on under `sysctl --system`");
    config.profiles[0].ipv6 = Ipv6::Disabled;
    let disabled = render(&config);
    assert!(content(&disabled, MIHOMO_CONFIG_PATH).contains("\nipv6: false\n"));
    let sysctl = content(&disabled, SYSCTL_PATH);
    assert!(!sysctl.contains("net.ipv6.conf.all.forwarding"));
    assert!(sysctl.ends_with("net.ipv4.tcp_tw_reuse = 1\n\n# IPv6 отключён по запросу пользователя\nnet.ipv6.conf.all.disable_ipv6 = 1\n\
        net.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1\n"), "{sysctl}");
    assert_ne!(default.digest, disabled.digest);
}

#[test]
fn xhttp_through_nginx_adds_the_location_and_the_inner_listener() {
    let mut profile = profile();
    profile.vless_xhttp = Some(Xhttp { topology: XhttpTopology::Nginx, port: None });
    let config = config(profile);
    let desired = render(&config);
    let site = content(&desired, "/etc/nginx/sites-available/de.example.com");
    assert!(site.contains("    index index.html;\n\n    location /0123456789abcdef {\n        proxy_pass http://127.0.0.1:8447;\n"), "{site}");
    assert!(site.contains("        client_body_timeout 300s;\n    }\n    location / {\n"));
    let mihomo = content(&desired, MIHOMO_CONFIG_PATH);
    assert!(mihomo.contains("# --- vless-xhttp ---\n  - name: VLESS xHTTP\n    type: vless\n    listen: 127.0.0.1\n    port: 8447\n"), "{mihomo}");
    assert!(mihomo.contains("    allow-insecure: true\n"));
    assert_eq!(spec(&desired, "UFW_RULES"), "443/tcp");
    let client = client_section(&config, &config.nodes[0]).unwrap();
    assert!(client.contains("  - name: \"VLESS xHTTP\"\n    type: vless\n    server: de.example.com\n    port: 443\n"), "{client}");
    let xhttp = client.split("  - name: \"VLESS xHTTP\"").nth(1).unwrap();
    assert!(!xhttp.contains("reality-opts"));

    // Without Reality transports the site answers 443 itself.
    let mut config = config;
    config.profiles[0].vless_tcp = false;
    let free = render(&config);
    assert!(content(&free, "/etc/nginx/sites-available/de.example.com")
        .starts_with("# Essence site de.example.com\nserver {\n    listen 443 ssl http2;\n    listen [::]:443 ssl http2;\n"));
    assert_eq!((spec(&free, "UFW_RULES"), spec(&free, "SITE_REQUIRE_200")), ("443/tcp", "false"));
}

#[test]
fn reality_without_users_on_443_leaves_443_to_the_site() {
    // TCP and xHTTP through nginx, the client uses only xHTTP: no TCP
    // listener is rendered, so the site answers 443 itself.
    let mut profile = profile();
    profile.vless_xhttp = Some(Xhttp { topology: XhttpTopology::Nginx, port: None });
    let mut config = config(profile);
    config.connections[0].groups[0].proxies = vec!["VLESS xHTTP".into()];
    let desired = render(&config);
    assert!(!content(&desired, MIHOMO_CONFIG_PATH).contains("# --- vless-tcp ---"));
    assert!(content(&desired, "/etc/nginx/sites-available/de.example.com")
        .starts_with("# Essence site de.example.com\nserver {\n    listen 443 ssl http2;\n    listen [::]:443 ssl http2;\n"));
    assert_eq!((spec(&desired, "LISTEN_TCP"), spec(&desired, "SITE_REQUIRE_200")), ("443 8447", "false"));
    assert_eq!(spec(&desired, "UFW_RULES"), "443/tcp");

    // SNI mode without a role: no Reality listener on 443, nothing opens it.
    let mut sni_config = self::config(sni(self::profile()));
    sni_config.nodes[0].domain = None;
    sni_config.connections[0].groups[0].proxies = vec!["Hysteria2".into()];
    let desired = render(&sni_config);
    assert_eq!((spec(&desired, "UFW_RULES"), spec(&desired, "LISTEN_TCP")), ("", ""));
}

#[test]
fn digest_ignores_the_profile_name_and_follows_clients() {
    let config_a = config(profile());
    let base = render(&config_a).digest;
    let mut renamed = config_a.clone();
    renamed.profiles[0].name = "other".into();
    renamed.nodes[0].profile = Some("other".into());
    assert_eq!(render(&renamed).digest, base);
    let mut more = config_a.clone();
    more.clients.push(client("gamma", "gamma-pass"));
    assert_ne!(render(&more).digest, base);
    assert_eq!(desired(&config_a, &config_a.nodes[0], None).unwrap().digest, base, "secrets do not enter the digest");
    assert!(desired(&config_a, &config_a.nodes[0], None).unwrap().files.iter().all(|file| file.content.is_empty()));
}

#[test]
fn status_and_removed_files_follow_the_applied_set() {
    let mut config = config(profile());
    assert_eq!(status(&config, &config.nodes[0]), "pending");
    let desired_now = render(&config);
    let mut files = file_hashes(&desired_now.files);
    assert!(!files.contains_key("/etc/nginx/sites-enabled/de.example.com"), "links are not recorded");
    files.insert("/etc/nginx/sites-available/old.example.com".into(), "x".into());
    config.nodes[0].applied = Some(Applied { digest: desired_now.digest.clone(), files, ports: desired_now.ports.clone(), at: "t".into() });
    assert_eq!(status(&config, &config.nodes[0]), "applied");
    config.nodes[0].operation = Some(crate::model::Operation { id: "0".repeat(32), digest: "d".repeat(64), ..Default::default() });
    assert_eq!(status(&config, &config.nodes[0]), "running");
    config.nodes[0].operation = None;
    let next = render(&config);
    assert_eq!(next.remove, ["/etc/nginx/sites-available/old.example.com", "/etc/nginx/sites-enabled/old.example.com"]);
    assert_eq!(spec(&next, "RELEASE_CERTS"), "old.example.com:/var/www/old.example.com");
    assert!(next.lines.contains(&"Будет удалено: /etc/nginx/sites-available/old.example.com".to_owned()));
    assert!(next.lines.contains(&"Будет удалён сертификат и сайт: old.example.com".to_owned()));
    assert!(!next.lines.iter().any(|line| line.starts_with("Первая установка")));
    config.clients.push(client("gamma", "gamma-pass"));
    assert_eq!(status(&config, &config.nodes[0]), "pending");
}

#[test]
fn removing_the_profile_tears_everything_down() {
    let mut config = config(profile());
    let desired_now = render(&config);
    config.nodes[0].applied = Some(Applied { digest: desired_now.digest, files: file_hashes(&desired_now.files),
        ports: desired_now.ports, at: "t".into() });
    config.nodes[0].profile = None;
    assert_eq!(status(&config, &config.nodes[0]), "pending");
    let teardown = desired(&config, &config.nodes[0], Some(&secrets())).unwrap();
    assert!(teardown.teardown && teardown.files.is_empty());
    assert_eq!(teardown.remove, ["/etc/mihomo", MIHOMO_CONFIG_PATH, "/etc/nginx/sites-available/de.example.com",
        "/etc/nginx/sites-enabled/de.example.com", SYSCTL_PATH, MIHOMO_SERVICE_PATH]);
    assert_eq!((spec(&teardown, "OP_MODE"), spec(&teardown, "REMOVE_FEATURES")), ("teardown", "awg sub telegram"));
    assert_eq!(spec(&teardown, "RELEASE_CERTS"), "de.example.com:/var/www/de.example.com");
    assert_eq!(teardown.lines[1], "Профиль снят: всё установленное Essence будет удалено.");
    config.nodes[0].applied = Some(Applied { digest: teardown.digest, ..Applied::default() });
    assert_eq!(status(&config, &config.nodes[0]), "applied");
    config.nodes[0].applied = None;
    assert_eq!(status(&config, &config.nodes[0]), "none");
    assert_eq!(desired(&config, &config.nodes[0], None).err().unwrap().message, "У ноды «de» нет профиля.");
}

#[test]
fn proxies_list_enabled_protocols_and_cascades() {
    let mut profile = profile();
    profile.vless_grpc = Some(PortOnly { port: 2053 });
    profile.hysteria2 = Some(Hysteria2 { port: 8843, obfs: false });
    profile.amneziawg = Some(AmneziaWg { port: 51820, dns: "1.1.1.1".into() });
    let mut config = config(profile);
    config.cascades.push(crate::model::Cascade {
        name: "hop".into(), entry: "de".into(), listener: crate::model::CascadeListener::VlessTcp,
        exit: crate::model::CascadeExit::Uri(crate::model::UriExit { uri: "vless://x@y:1".into() }),
        uuid: String::new(), password: String::new(),
    });
    assert_eq!(proxies(&config, &config.nodes[0]), ["VLESS TCP", "VLESS gRPC", "Hysteria2", "AWG", "hop"]);
    config.nodes[0].profile = None;
    assert!(proxies(&config, &config.nodes[0]).is_empty());
}

/// A profile with AmneziaWG; clients alpha (index 3) and beta (index 2) are peers.
fn awg_config() -> Config {
    let mut profile = profile();
    profile.amneziawg = Some(AmneziaWg { port: 51820, dns: "1.1.1.1, 1.0.0.1".into() });
    let mut config = config(profile);
    config.nodes[0].params.awg = Some(NodeAwg { public_key: "SERVERPUB".into(), header_protection_key: "HPK".into(),
        tproxy_port: 23456, jc: 5, s1: 20, s2: 30, s3: 40 });
    config.clients.push(client("beta", "beta-pass"));
    let keys = [("alpha", 3, [7u8; 32]), ("beta", 2, [9u8; 32])];
    for (name, index, key) in keys {
        let credentials = config.clients.iter_mut().find(|c| c.name == name).unwrap().credentials.as_mut().unwrap();
        credentials.awg_index = index;
        credentials.awg_private_key = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, key);
        credentials.awg_preshared_key = format!("PSK-{name}");
    }
    config
}

fn awg_secrets() -> NodeSecrets {
    NodeSecrets { reality_key: Some(Zeroizing::new("PRIVKEY".into())), awg_key: Some(Zeroizing::new("SERVERPRIV".into())), ..NodeSecrets::default() }
}

#[test]
fn amneziawg_renders_the_server_config_peers_and_tproxy() {
    let config = awg_config();
    let desired = desired(&config, &config.nodes[0], Some(&awg_secrets())).unwrap();
    let conf = content(&desired, AWG_CONF_PATH);
    assert!(conf.starts_with("[Interface]\nPrivateKey = SERVERPRIV\nAddress = 10.10.0.1/16\nListenPort = 51820\nJc = 5\nJmin = 10\nJmax = 50\n\
        S1 = 20\nS2 = 30\nS3 = 40\nS4 = 12\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nHeaderProtectionKey = HPK\nContentPaddingAddition = 10-100\n\
        RekeyAfterTime = 100-120\nRekeyTimeout = 3-7\nRejectAfterTime = 150-180\nKeepaliveTimeout = 5-15\nMaxHandshakeAttempts = 15-20\n\
        RandomTrailers = on\nDisableCookies = on\nPostUp = "), "{conf}");
    assert!(conf.contains("--on-port 23456 --tproxy-mark 1") && !conf.contains("10.10.8"));
    // Peers are isolated: no forward between them, and only the server's own
    // address skips TPROXY (other peers go through mihomo's rejects).
    let (up, down) = conf.split_once("\nPostDown = ").unwrap();
    assert!(up.contains("PostUp = iptables -I FORWARD -i %i -o %i -j DROP; "), "{conf}");
    assert!(down.starts_with("iptables -D FORWARD -i %i -o %i -j DROP || true; "), "{conf}");
    assert!(up.contains("-d 10.10.0.1/32 -j RETURN") && !conf.contains("-d 10.10.0.0/16"), "{conf}");
    let beta = conf.find("# peer: beta").unwrap();
    let alpha = conf.find("# peer: alpha").unwrap();
    assert!(beta < alpha, "peers by ascending index");
    assert!(conf.contains("\n# peer: beta\n[Peer]\nPublicKey = ") && conf.contains("PresharedKey = PSK-beta\nAllowedIPs = 10.10.0.2/32\n"));
    assert!(conf.contains("AllowedIPs = 10.10.0.3/32\n"));
    let public = crate::server::keys::wg_public(&config.clients[0].credentials.as_ref().unwrap().awg_private_key).unwrap();
    assert!(conf.contains(&format!("# peer: alpha\n[Peer]\nPublicKey = {public}\n")));
    let mihomo = content(&desired, MIHOMO_CONFIG_PATH);
    assert!(!mihomo.contains("tproxy-port:"), "the top-level tproxy port would bypass the inbound rejects");
    assert!(mihomo.contains("  - name: awg-tproxy\n    type: tproxy\n    listen: 0.0.0.0\n    port: 23456\n    udp: true\n    rule: essence-in\n"), "{mihomo}");
    assert_eq!((spec(&desired, "FEATURES"), spec(&desired, "AWG_PORT")), ("awg", "51820"));
    assert_eq!(spec(&desired, "UFW_RULES"), "443/tcp 51820/udp");
    assert_eq!(spec(&desired, "LISTEN_TCP"), "443 8443 23456");
    assert!(desired.lines.contains(&"AWG: порт 51820, клиентов 2".to_owned()));
    assert_eq!(awg::peer_ip(258), "10.10.1.2");

    // A client without AWG in its connections is no peer.
    let mut config = config;
    config.connections[0].groups[0].proxies = vec!["VLESS TCP".into()];
    assert!(!content(&self::desired(&config, &config.nodes[0], Some(&awg_secrets())).unwrap(), AWG_CONF_PATH).contains("# peer:"));
}

#[test]
fn amneziawg_client_blocks_and_native_config() {
    let config = awg_config();
    let section = client_section(&config, &config.nodes[0]).unwrap();
    let alpha_key = config.clients[0].credentials.as_ref().unwrap().awg_private_key.clone();
    assert!(section.contains(&format!("  - name: awg-alpha\n    type: wireguard\n    private-key: {alpha_key}\n    server: de.example.com\n    port: 51820\n\
        \x20   ip: 10.10.0.3\n    mtu: 1280\n    dns: ['1.1.1.1', '1.0.0.1']\n    public-key: SERVERPUB\n    pre-shared-key: PSK-alpha\n\
        \x20   allowed-ips: ['0.0.0.0/0', '::/0']\n    udp: true\n    persistent-keepalive: 25\n    amnezia-wg-option:\n      version: 3\n      jc: 5\n")), "{section}");
    assert!(section.contains("      random-trailers: true\n      disable-cookies: true\n") && section.ends_with("---\n"));
    let native = awg_client_config(&config, &config.nodes[0], &config.clients[0]).unwrap();
    assert!(native.starts_with(&format!("[Interface]\nAddress = 10.10.0.3/32\nDNS = 1.1.1.1, 1.0.0.1\nMTU = 1280\nPrivateKey = {alpha_key}\nJc = 5\n")));
    assert!(native.ends_with("\n[Peer]\nPublicKey = SERVERPUB\nPresharedKey = PSK-alpha\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = de.example.com:51820\nPersistentKeepalive = 25\n"));
    let mut other = config.clone();
    other.connections[0].groups[0].proxies = vec!["VLESS TCP".into()];
    assert_eq!(awg_client_config(&other, &other.nodes[0], &other.clients[0]).unwrap_err().code, "invalid");
    let plain = self::config(profile());
    assert_eq!(awg_client_config(&plain, &plain.nodes[0], &plain.clients[0]).unwrap_err().code, "invalid");
}

#[test]
fn awg_nodes_follow_the_peer_rule() {
    let mut config = awg_config();
    assert_eq!(awg_nodes(&config, &config.clients[0]), ["de"]);
    // No connections on the node: the client uses every one, AmneziaWG too.
    config.connections[0].groups[0].proxies.clear();
    assert_eq!(awg_nodes(&config, &config.clients[0]), ["de"]);
    assert!(awg_client_config(&config, &config.nodes[0], &config.clients[0]).is_ok());
    config.connections[0].groups[0].proxies = vec!["VLESS TCP".into()];
    assert!(awg_nodes(&config, &config.clients[0]).is_empty());
    let plain = self::config(profile());
    assert!(awg_nodes(&plain, &plain.clients[0]).is_empty());
}

#[test]
fn warp_adds_the_proxy_and_outbound_member() {
    let mut config = config(profile());
    config.profiles[0].warp = true;
    let pending = render(&config);
    assert!(pending.lines.contains(&"WARP: будет зарегистрирован аккаунт Cloudflare.".to_owned()));
    assert!(!content(&pending, MIHOMO_CONFIG_PATH).contains("warp-wg"), "no block before registration");
    config.nodes[0].params.warp = Some(crate::model::NodeWarp { public_key: "WPUB".into(), ipv4: "172.16.0.2".into(), ipv6: None,
        plus: false, plus_attempt: None });
    let secrets = NodeSecrets { reality_key: Some(Zeroizing::new("PRIVKEY".into())), warp_key: Some(Zeroizing::new("WPRIV".into())), ..NodeSecrets::default() };
    let desired = desired(&config, &config.nodes[0], Some(&secrets)).unwrap();
    let mihomo = content(&desired, MIHOMO_CONFIG_PATH);
    assert!(mihomo.contains("proxies:\n  - name: warp-wg\n    type: wireguard\n    private-key: \"WPRIV\"\n"), "{mihomo}");
    assert!(mihomo.contains("    proxies:\n      - warp-wg\n      - DIRECT\n"));
    assert_eq!(spec(&desired, "WARP"), "true");
    let document = yaml(mihomo);
    assert_eq!(document["proxies"].as_vec().map(Vec::len), Some(1));
    // Switching WARP off drops the block; the stored account does not count.
    let digest_on = desired.digest.clone();
    config.profiles[0].warp = false;
    let off = render(&config);
    assert!(!content(&off, MIHOMO_CONFIG_PATH).contains("warp-wg") && spec(&off, "WARP") == "false");
    let mut forgotten = config.clone();
    forgotten.nodes[0].params.warp = None;
    assert_eq!(render(&forgotten).digest, off.digest);
    assert_ne!(off.digest, digest_on);
}

const CASCADE_UUID: &str = "11111111-2222-4333-8444-555555555555";

/// `de` enters cascade `hop` through VLESS TCP and leaves through `nl`'s
/// `exit` connection; alpha uses `hop`.
fn cascade_config(exit: crate::model::ExitProxy) -> Config {
    use crate::model::{Cascade, CascadeExit, CascadeListener, NodeExit};
    let mut config = config(Profile { hysteria2: Some(Hysteria2 { port: 20443, obfs: false }), ..profile() });
    let mut nl = node();
    nl.id = "b".repeat(32);
    nl.name = "nl".into();
    nl.domain = Some("nl.example.com".into());
    nl.params.reality = Some(NodeReality { public_key: "NLPUB".into(), short_id: "fedcba9876543210".into() });
    config.nodes.push(nl);
    config.connections[0].groups[0].proxies.push("hop".into());
    config.cascades.push(Cascade {
        name: "hop".into(), entry: "de".into(), listener: CascadeListener::VlessTcp,
        exit: CascadeExit::Node(NodeExit { node: "nl".into(), proxy: exit }), uuid: CASCADE_UUID.into(), password: "c".repeat(32),
    });
    config
}

#[test]
fn cascade_names_and_short_ids_stay_yaml_strings() {
    for name in ["-", "null", "1e5"] {
        let mut config = cascade_config(crate::model::ExitProxy::VlessTcp);
        config.nodes[1].params.reality.as_mut().unwrap().short_id = "0123456789012345".into();
        config.cascades[0].name = name.into();
        *config.connections[0].groups[0].proxies.last_mut().unwrap() = name.into();
        let entry = render(&config);
        let mihomo = content(&entry, MIHOMO_CONFIG_PATH);
        let document = yaml(mihomo);
        let exit = document["proxies"].as_vec().unwrap().iter().find(|proxy| proxy["server"].as_str() == Some("nl.example.com")).unwrap();
        assert_eq!(exit["name"].as_str(), Some(name), "{mihomo}");
        assert_eq!(exit["reality-opts"]["short-id"].as_str(), Some("0123456789012345"), "{mihomo}");
        let group = document["proxy-groups"].as_vec().unwrap().iter()
            .find(|group| group["name"].as_str() == Some(format!("{name}-outbound").as_str())).unwrap();
        assert_eq!(group["proxies"][0].as_str(), Some(name), "{mihomo}");
    }
}

#[test]
fn a_cascade_routes_its_users_on_the_entry_node_to_the_exit_node() {
    let mut config = cascade_config(crate::model::ExitProxy::VlessTcp);
    let entry = render(&config);
    let mihomo = content(&entry, MIHOMO_CONFIG_PATH);
    let user = super::super::keys::cascade_uuid(UUID, "hop");
    assert!(mihomo.contains(&format!("      - username: alpha\n        uuid: {UUID}\n        flow: xtls-rprx-vision\n\
        \x20     - username: alpha--hop\n        uuid: {user}\n        flow: xtls-rprx-vision\n")), "{mihomo}");
    let tcp = mihomo.split("# --- vless-tcp ---").nth(1).unwrap().split("# --- /vless-tcp ---").next().unwrap();
    assert!(tcp.contains("    rule: vless-tcp-shared\n") && !tcp.contains("    proxy: outbound"));
    let hy2 = mihomo.split("# --- hy2 ---").nth(1).unwrap().split("# --- /hy2 ---").next().unwrap();
    assert!(hy2.contains("    rule: essence-in\n") && !hy2.contains("alpha--hop"), "other listeners keep the plain inbound rule");
    assert!(mihomo.contains(&format!("proxies:\n  - name: hop\n    type: vless\n    server: nl.example.com\n    port: 443\n    uuid: {CASCADE_UUID}\n\
        \x20   network: tcp\n    udp: true\n    flow: xtls-rprx-vision\n    tls: true\n    servername: \"nl.example.com\"\n\
        \x20   reality-opts:\n      public-key: NLPUB\n      short-id: fedcba9876543210\n    client-fingerprint: chrome\n")), "{mihomo}");
    assert!(mihomo.contains("      - DIRECT\n    url: https://www.gstatic.com/generate_204\n    interval: 10\n    timeout: 3000\n    lazy: false\n\
        \x20 - name: hop-outbound\n    type: fallback\n    proxies:\n      - hop\n      - DIRECT\n"));
    // The shared sub-rule rejects as `essence-in` does: no `no-resolve`, the node's own address.
    let rejects: String = INBOUND_REJECT.iter().map(|rule| format!("    - {rule},REJECT\n"))
        .chain([format!("    - IP-CIDR,{}/32,REJECT\n", config.nodes[0].ip)]).collect();
    assert!(mihomo.contains(&format!("sub-rules:\n  essence-in:\n{rejects}    - MATCH,outbound\n  vless-tcp-shared:\n{rejects}\
        \x20   - IN-USER,alpha--hop,hop-outbound\n    - MATCH,outbound\nrule-providers:")), "{mihomo}");
    assert!(!mihomo.contains("no-resolve"), "{mihomo}");
    let document = yaml(mihomo);
    assert_eq!(document["sub-rules"]["vless-tcp-shared"].as_vec().map(Vec::len), Some(INBOUND_REJECT.len() + 3));
    assert!(entry.lines.contains(&"Каскад «hop»: вход VLESS TCP, выход — нода nl (VLESS TCP), клиентов 1".to_owned()), "{:?}", entry.lines);
    let section = client_section(&config, &config.nodes[0]).unwrap();
    assert!(section.contains(&format!("  - name: \"hop\"\n    type: vless\n    server: de.example.com\n    port: 443\n    uuid: {PLACEHOLDER_UUID}\n")));

    let exit = desired(&config, &config.nodes[1], Some(&secrets())).unwrap();
    let mihomo = content(&exit, MIHOMO_CONFIG_PATH);
    assert!(mihomo.contains(&format!("      - username: cascade--hop\n        uuid: {CASCADE_UUID}\n        flow: xtls-rprx-vision\n")), "{mihomo}");
    assert!(!mihomo.contains("-shared") && !mihomo.contains("hop-outbound"));
    assert!(exit.lines.contains(&"Каскад «hop»: выход через VLESS TCP этой ноды.".to_owned()));
    // Only the cascade uses the exit node's Reality listener on 443: it is
    // rendered, so Reality takes the 443 front with the site behind it.
    assert!(exit.lines.contains(&"VLESS TCP: порт 443, клиентов 0".to_owned()), "{:?}", exit.lines);
    assert_eq!(spec(&exit, "SITE_REQUIRE_200"), "true");

    // The exit node's client parameters are part of the entry digest.
    config.nodes[1].params.reality.as_mut().unwrap().public_key = "NEWPUB".into();
    assert_ne!(render(&config).digest, entry.digest);
}

#[test]
fn hysteria2_and_uri_exits_and_broken_cascades() {
    use crate::model::{CascadeExit, CascadeListener, UriExit};
    let mut config = cascade_config(crate::model::ExitProxy::Hysteria2);
    let mihomo = content(&render(&config), MIHOMO_CONFIG_PATH).to_owned();
    assert!(mihomo.contains(&format!("  - name: hop\n    type: hysteria2\n    server: nl.example.com\n    port: 20443\n    password: \"{}\"\n", "c".repeat(32))), "{mihomo}");
    let exit = content(&desired(&config, &config.nodes[1], Some(&secrets())).unwrap(), MIHOMO_CONFIG_PATH).to_owned();
    assert!(exit.contains(&format!("      cascade--hop: \"{}\"\n", "c".repeat(32))), "{exit}");

    // An entry through Hysteria2 derives the client password.
    config.cascades[0].listener = CascadeListener::Hysteria2;
    let mihomo = content(&render(&config), MIHOMO_CONFIG_PATH).to_owned();
    assert!(mihomo.contains(&format!("      alpha--hop: \"{}\"\n", super::super::keys::cascade_password("alpha-pass", "hop"))));
    let rejects: String = INBOUND_REJECT.iter().map(|rule| format!("    - {rule},REJECT\n"))
        .chain([format!("    - IP-CIDR,{}/32,REJECT\n", config.nodes[0].ip)]).collect();
    assert!(mihomo.contains("    rule: hy2-shared\n") && mihomo.contains(&format!("  hy2-shared:\n{rejects}    - IN-USER,alpha--hop,hop-outbound\n")));

    config.cascades[0].exit = CascadeExit::Uri(UriExit { uri: "hysteria2://secret@203.0.113.5:443?sni=exit.example.com#x".into() });
    let mihomo = content(&render(&config), MIHOMO_CONFIG_PATH).to_owned();
    assert!(mihomo.contains("  - name: hop\n    type: hysteria2\n    server: 203.0.113.5\n    port: 443\n"), "{mihomo}");

    config.cascades[0].exit = CascadeExit::Uri(UriExit { uri: "ftp://203.0.113.5".into() });
    assert_eq!(desired(&config, &config.nodes[0], None).err().map(|e| e.code), Some("invalid"));
    assert_eq!(status(&config, &config.nodes[0]), "pending");

    // A listener the profile no longer enables leaves the cascade idle.
    config.cascades[0].listener = CascadeListener::VlessGrpc;
    let idle = render(&config);
    assert!(idle.lines.contains(&"Каскад «hop»: подключение «VLESS gRPC» не включено в профиле — каскад не работает.".to_owned()));
    assert!(!content(&idle, MIHOMO_CONFIG_PATH).contains("hop"));
    assert!(!client_section(&config, &config.nodes[0]).unwrap().contains("\"hop\""));
}

fn sub_host(port: u16) -> SubscriptionHost {
    SubscriptionHost { node: "de".into(), hostname: "sub.example.com".into(), port,
        base_url: SubscriptionHost::base_url_for("sub.example.com", port), sub_dir: SUB_DIR.into(), nginx_group: "www-data".into() }
}

fn sub_listen(desired: &Desired) -> Vec<&str> {
    content(desired, "/etc/nginx/sites-available/essence-sub").lines().filter(|line| line.trim_start().starts_with("listen ")).collect()
}

#[test]
fn subscription_host_behind_self_steal_with_its_files_and_spec() {
    let mut config = config(profile());
    config.subscription_host = Some(sub_host(443));
    let desired = render(&config);
    let site = content(&desired, "/etc/nginx/sites-available/essence-sub");
    assert!(site.starts_with("# Essence site essence-sub\nserver {\n    listen 127.0.0.1:8443 ssl http2;\n    server_name sub.example.com;\n\n\
        \x20   ssl_certificate     /etc/nginx/ssl/sub.example.com/fullchain.pem;\n"), "{site}");
    assert!(site.contains("    location ~ \"^/sub/([a-f0-9]{64})$\" {\n        alias /var/lib/essence-sub/$1.yaml;\n"));
    assert!(site.contains("    include /etc/nginx/snippets/essence-sub/sub-*.conf;\n") && !site.contains("{{"));
    assert_eq!(content(&desired, "/etc/nginx/sites-enabled/essence-sub"), "/etc/nginx/sites-available/essence-sub");
    assert_eq!(content(&desired, "/etc/nginx/conf.d/essence-sub-limit.conf"), "limit_req_zone $binary_remote_addr zone=sub:1m rate=10r/m;\n");
    let cleanup = desired.files.iter().find(|file| file.path == "/usr/local/bin/essence-sub-cleanup").unwrap();
    assert_eq!(cleanup.mode, "0755");
    assert!(cleanup.content.starts_with("#!/bin/bash\nSUB_DIR=/var/lib/essence-sub\nLIST=\"${SUB_DIR}/expiry.list\"\n"));
    assert!(content(&desired, "/etc/systemd/system/essence-sub-cleanup.timer").contains("OnUnitActiveSec=5min\n"));
    assert!(content(&desired, "/etc/systemd/system/essence-sub-cleanup.service").contains("ExecStart=/usr/local/bin/essence-sub-cleanup\n"));
    assert_eq!(content(&desired, "/var/www/sub.example.com/.essence-sub"), "");
    assert_eq!(spec(&desired, "CERTS"), "de.example.com:/var/www/de.example.com sub.example.com:/var/www/sub.example.com");
    assert_eq!(spec(&desired, "DNS_DOMAINS"), "de.example.com sub.example.com");
    assert_eq!((spec(&desired, "FEATURES"), spec(&desired, "SUB_HOST"), spec(&desired, "UFW_RULES")), ("sub", "sub.example.com", "443/tcp"));
    assert!(desired.lines.contains(&"Хост подписок: https://sub.example.com".to_owned()));

    // Its own port opens in the firewall and must not clash with a listener.
    config.subscription_host = Some(sub_host(2096));
    let own = render(&config);
    assert_eq!(sub_listen(&own), ["    listen 0.0.0.0:2096 ssl http2;"]);
    assert_eq!(spec(&own, "UFW_RULES"), "443/tcp 2096/tcp");
    assert_eq!(spec(&own, "LISTEN_TCP"), "443 2096 8443");
    config.subscription_host = Some(sub_host(443 + 1));
    config.profiles[0].hysteria2 = Some(Hysteria2 { port: 444, obfs: false });
    let error = desired_error(&config);
    assert_eq!((error.code, error.extra["port"].clone()), ("invalid", json!(444)));
}

fn desired_error(config: &Config) -> RcError {
    desired(config, &config.nodes[0], None).err().unwrap()
}

#[test]
fn subscription_host_behind_the_stream_and_on_a_free_443() {
    let mut config = config(sni(profile()));
    config.nodes[0].domain = None;
    config.subscription_host = Some(sub_host(443));
    let stream = render(&config);
    assert_eq!(sub_listen(&stream), ["    listen 127.0.0.1:8445 ssl http2;"]);
    assert!(content(&stream, STREAM_PATH).contains("        sub.example.com subscription;\n"));
    assert!(content(&stream, MIHOMO_CONFIG_PATH).contains("    listen: 127.0.0.1\n    port: 8444\n"));
    assert_eq!((spec(&stream, "NGINX_STREAM"), spec(&stream, "CERTS")), ("true", "sub.example.com:/var/www/sub.example.com"));
    assert_eq!(spec(&stream, "LISTEN_TCP"), "443 8444 8445");
    // The vhost's internal port is taken by SSH: refused before apply.
    config.nodes[0].port = 8445;
    let error = desired_error(&config);
    assert_eq!((error.code, error.extra["port"].clone()), ("invalid", json!(8445)));
    config.nodes[0].port = 22;

    // Without Reality nginx owns 443 itself.
    config.profiles[0].vless_tcp = false;
    config.profiles[0].hysteria2 = Some(Hysteria2 { port: 20443, obfs: false });
    let free = render(&config);
    assert_eq!(sub_listen(&free), ["    listen 443 ssl http2;", "    listen [::]:443 ssl http2;"]);
    assert_eq!((spec(&free, "NGINX"), spec(&free, "NGINX_STREAM")), ("true", "false"));
    assert!(spec(&free, "UFW_RULES").starts_with("443/tcp "));
}

#[test]
fn a_moved_subscription_host_releases_its_certificate() {
    let mut config = config(profile());
    config.subscription_host = Some(sub_host(443));
    let applied = render(&config);
    config.nodes[0].applied = Some(Applied { digest: applied.digest.clone(), files: file_hashes(&applied.files), ports: applied.ports.clone(), at: "t".into() });
    config.subscription_host.as_mut().unwrap().hostname = "subs.example.com".into();
    let renamed = render(&config);
    assert_eq!(spec(&renamed, "RELEASE_CERTS"), "sub.example.com:/var/www/sub.example.com");
    assert!(renamed.remove.contains(&"/var/www/sub.example.com/.essence-sub".to_owned()));
    assert_eq!(spec(&renamed, "REMOVE_FEATURES"), "");
    config.subscription_host = None;
    let gone = render(&config);
    assert_eq!((spec(&gone, "REMOVE_FEATURES"), spec(&gone, "RELEASE_CERTS"), spec(&gone, "SUB_HOST")),
        ("sub", "sub.example.com:/var/www/sub.example.com", ""));
    assert!(gone.remove.contains(&"/etc/nginx/sites-enabled/essence-sub".to_owned()));
    assert!(gone.lines.contains(&"Будет удалён сертификат и сайт: sub.example.com".to_owned()));
    assert_eq!(spec(&teardown(&config.nodes[0]), "RELEASE_CERTS"), "de.example.com:/var/www/de.example.com sub.example.com:/var/www/sub.example.com");
}

#[test]
fn the_subscription_role_stays_applied_while_other_changes_are_pending() {
    let mut config = config(profile());
    config.subscription_host = Some(sub_host(443));
    assert!(!sub_role_applied(&config, &config.nodes[0]), "not applied yet");
    let applied = render(&config);
    config.nodes[0].applied = Some(Applied { digest: applied.digest.clone(), files: file_hashes(&applied.files), ports: applied.ports.clone(), at: "t".into() });
    assert!(sub_role_applied(&config, &config.nodes[0]));
    // A new client of the node makes it pending; the role is still in place.
    config.clients.push(Client { inherit_nodes_from_group: false, nodes: Some(vec!["de".into()]), ..client("beta", "beta-pass") });
    assert_eq!(status(&config, &config.nodes[0]), "pending");
    assert!(sub_role_applied(&config, &config.nodes[0]));
    // A running operation that keeps the vhost does not block; teardown does.
    config.nodes[0].operation = Some(crate::model::Operation { id: "0".repeat(32), digest: "d".repeat(64),
        files: file_hashes(&applied.files), ..Default::default() });
    assert!(sub_role_applied(&config, &config.nodes[0]));
    config.nodes[0].operation = Some(crate::model::Operation { id: "0".repeat(32), digest: "d".repeat(64), teardown: true, ..Default::default() });
    assert!(!sub_role_applied(&config, &config.nodes[0]));
    config.nodes[0].operation = None;
    // A new hostname or listen port is not applied until `node apply`.
    config.subscription_host.as_mut().unwrap().hostname = "subs.example.com".into();
    assert!(!sub_role_applied(&config, &config.nodes[0]));
    config.subscription_host = Some(sub_host(2096));
    assert!(!sub_role_applied(&config, &config.nodes[0]));
}

fn telegram(config: &mut Config, tag: bool) {
    config.telegram.push(TelegramProxy { node: "de".into(), hostname: "tg.example.com".into(), secret_mark: "0123abcd".into(),
        tag_mark: tag.then(|| "89abcdef".into()) });
}

fn tg_listen(desired: &Desired) -> Vec<&str> {
    content(desired, "/etc/nginx/sites-available/essence-telegram-proxy").lines().filter(|line| line.trim_start().starts_with("listen ")).collect()
}

#[test]
fn telegram_behind_self_steal_with_its_files_and_spec() {
    let mut config = config(profile());
    telegram(&mut config, false);
    let desired = render(&config);
    assert_eq!(tg_listen(&desired), ["    listen 127.0.0.1:8443 ssl http2;"]);
    let site = content(&desired, "/etc/nginx/sites-available/essence-telegram-proxy");
    assert!(site.starts_with("# Essence site essence-telegram-proxy\nserver {\n"), "the executor removes only marked sites: {site}");
    assert!(site.contains("    server_name tg.example.com;\n    ssl_certificate /etc/nginx/ssl/tg.example.com/fullchain.pem;\n"), "{site}");
    assert!(site.contains("        proxy_pass http://127.0.0.1:8080;\n") && site.contains("proxy_set_header Host $http_host;"));
    assert_eq!(content(&desired, "/etc/nginx/sites-enabled/essence-telegram-proxy"), "/etc/nginx/sites-available/essence-telegram-proxy");
    let file = |path: &str| desired.files.iter().find(|file| file.path == path).unwrap();
    let env = file("/etc/mtproxy/mtproxy.env");
    assert_eq!((env.mode, env.owner, env.group), ("0640", "root", "mtproxy"));
    assert_eq!(env.content.as_str(), format!("MTPROXY_SECRET={TG_SECRET}\nMTPROXY_TAG_ARGS=\"\"\nMTPROXY_WORKERS=1\nMTPROXY_MAX_CONNECTIONS=4096\n"));
    let profiles = file("/etc/tproxy-server/profiles.json");
    assert_eq!((profiles.mode, profiles.group), ("0400", "tproxy"));
    assert_eq!(profiles.content.as_str(), format!("{{\"profiles\":[{{\"name\":\"default\",\"secret\":\"{TG_SECRET}\",\"backend\":\"127.0.0.1:2398\",\"carrier_mode\":\"https\"}}]}}\n"));
    let relay = file("/etc/tproxy-server/config.json");
    assert_eq!((relay.mode, relay.group), ("0640", "tproxy"));
    let relay: Value = serde_json::from_str(&relay.content).unwrap();
    assert_eq!(relay, json!({"public_hostname": "tg.example.com", "listen": "127.0.0.1:8080", "admin_listen": "127.0.0.1:8081",
        "public_dir": "/srv/tproxy-site", "profiles_file": "/run/credentials/tproxy-server.service/profiles.json"}));
    assert!(content(&desired, "/etc/tproxy-server/firewall.nft").contains("        iifname != \"lo\" tcp dport 2398 drop\n"));
    assert_eq!(content(&desired, "/var/www/tg.example.com/.essence-telegram"), "");
    assert_eq!(spec(&desired, "CERTS"), "de.example.com:/var/www/de.example.com tg.example.com:/var/www/tg.example.com");
    assert_eq!((spec(&desired, "FEATURES"), spec(&desired, "TG_HOST")), ("telegram", "tg.example.com"));
    assert_eq!((spec(&desired, "TG_REVISION"), spec(&desired, "TG_GO_VERSION")), (crate::telegram::TPROXY_REVISION, crate::telegram::GO_VERSION));
    assert_eq!((spec(&desired, "TG_GO_SHA256"), spec(&desired, "TG_REPO")), (crate::telegram::GO_SHA256, crate::telegram::TPROXY_REPO));
    assert_eq!(spec(&desired, "LISTEN_TCP"), "443 8443");
    assert!(desired.lines.contains(&"Telegram Web Proxy: tg.example.com (tproxy-server f7a6acc)".to_owned()));
    for path in desired.files.iter().map(|file| file.path.as_str()) {
        assert!(crate::server::paths::managed_file(path) || path.starts_with("/etc/nginx/sites-enabled/"), "{path} is managed");
    }

    // A sponsor tag joins the backend arguments; a damaged secret or tag fails the render.
    let mut tagged = config.clone();
    tagged.telegram[0].tag_mark = Some("89abcdef".into());
    let tag = "ABCDEF0123456789ABCDEF0123456789";
    let with_tag = NodeSecrets { telegram_tag: Some(Zeroizing::new(tag.into())), ..secrets() };
    let env = content(&desired_with(&tagged, &with_tag), "/etc/mtproxy/mtproxy.env").to_owned();
    assert!(env.contains(&format!("MTPROXY_TAG_ARGS=\"-P {}\"\n", tag.to_ascii_lowercase())), "{env}");
    assert_eq!(self::desired(&tagged, &tagged.nodes[0], Some(&secrets())).err().map(|e| e.code), Some("invalid"));
    let broken = NodeSecrets { telegram_secret: Some(Zeroizing::new("X".repeat(32))), ..secrets() };
    assert_eq!(self::desired(&config, &config.nodes[0], Some(&broken)).err().map(|e| e.code), Some("invalid"));

    // The secret changes the digest through its mark.
    let mut rotated = config.clone();
    rotated.telegram[0].secret_mark = "fedcba98".into();
    assert_ne!(render(&rotated).digest, desired.digest);
}

fn desired_with(config: &Config, secrets: &NodeSecrets) -> Desired {
    desired(config, &config.nodes[0], Some(secrets)).unwrap()
}

#[test]
fn telegram_behind_the_stream_and_on_a_free_443() {
    let mut config = config(sni(profile()));
    config.nodes[0].domain = None;
    telegram(&mut config, false);
    let stream = render(&config);
    assert_eq!(tg_listen(&stream), ["    listen 127.0.0.1:8446 ssl http2;"]);
    assert!(content(&stream, STREAM_PATH).contains("        tg.example.com telegram_proxy;\n"));
    assert_eq!(spec(&stream, "LISTEN_TCP"), "443 8444 8446");
    // The vhost's internal port is taken by SSH: refused before apply.
    config.nodes[0].port = 8446;
    let error = desired_error(&config);
    assert_eq!((error.code, error.extra["port"].clone()), ("invalid", json!(8446)));
    config.nodes[0].port = 22;

    config.profiles[0].vless_tcp = false;
    config.profiles[0].hysteria2 = Some(Hysteria2 { port: 20443, obfs: false });
    let free = render(&config);
    assert_eq!(tg_listen(&free), ["    listen 443 ssl http2;", "    listen [::]:443 ssl http2;"]);
    assert!(spec(&free, "UFW_RULES").starts_with("443/tcp "));
    assert_eq!(spec(&free, "LISTEN_TCP"), "443");
}

#[test]
fn a_removed_telegram_role_releases_its_certificate() {
    let mut config = config(profile());
    telegram(&mut config, false);
    let applied = render(&config);
    config.nodes[0].applied = Some(Applied { digest: applied.digest.clone(), files: file_hashes(&applied.files), ports: applied.ports.clone(), at: "t".into() });
    config.telegram.clear();
    let gone = render(&config);
    assert_eq!((spec(&gone, "REMOVE_FEATURES"), spec(&gone, "RELEASE_CERTS"), spec(&gone, "TG_HOST"), spec(&gone, "TG_REVISION")),
        ("telegram", "tg.example.com:/var/www/tg.example.com", "", ""));
    assert!(gone.remove.contains(&"/etc/mtproxy/mtproxy.env".to_owned()) && gone.remove.contains(&"/etc/nginx/sites-enabled/essence-telegram-proxy".to_owned()));
    assert_eq!(spec(&teardown(&config.nodes[0]), "RELEASE_CERTS"), "de.example.com:/var/www/de.example.com tg.example.com:/var/www/tg.example.com");
}

/// CI only: with `ESSENCE_RENDER_DUMP=<dir>` writes representative node
/// renders as `<dir>/<topology>/<absolute path>` (links as symlinks), which
/// `tests/ci/validate_render.sh` checks with the real `mihomo -t` and
/// `nginx -t`. Without the variable it does nothing.
#[cfg(unix)]
#[test]
fn dump_representative_renders() {
    use base64::Engine;
    use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
    let Some(root) = std::env::var_os("ESSENCE_RENDER_DUMP") else { return };
    let root = std::path::PathBuf::from(root);
    let secret = |text: String| Some(Zeroizing::new(text));
    let keys = NodeSecrets {
        reality_key: secret(URL_SAFE_NO_PAD.encode([1u8; 32])), awg_key: secret(STANDARD.encode([2u8; 32])),
        warp_key: secret(STANDARD.encode([3u8; 32])), telegram_secret: secret(TG_SECRET.into()), telegram_tag: None,
    };
    let subscription = SubscriptionHost { node: "de".into(), hostname: "sub.example.com".into(), port: 443,
        base_url: "https://sub.example.com".into(), sub_dir: SUB_DIR.into(), nginx_group: "www-data".into() };
    let telegram = TelegramProxy { node: "de".into(), hostname: "tg.example.com".into(), secret_mark: "0123abcd".into(), tag_mark: None };

    // Self-steal with every protocol, AmneziaWG, WARP and both roles behind the node site.
    let mut self_steal = awg_config();
    let full = &mut self_steal.profiles[0];
    full.vless_xhttp = Some(Xhttp { topology: XhttpTopology::Nginx, port: None });
    full.vless_grpc = Some(PortOnly { port: 2083 });
    full.hysteria2 = Some(Hysteria2 { port: 8843, obfs: true });
    full.warp = true;
    self_steal.nodes[0].params.warp = Some(crate::model::NodeWarp { public_key: STANDARD.encode([4u8; 32]),
        ipv4: "172.16.0.2".into(), ipv6: Some("2606:4700:110:8f0a::2".into()), plus: false, plus_attempt: None });
    self_steal.subscription_host = Some(subscription.clone());
    self_steal.telegram.push(telegram.clone());
    // SNI without a node domain: Telegram and subscriptions share 443 through the nginx stream.
    let mut stream = config(Profile { hysteria2: Some(Hysteria2 { port: 8843, obfs: false }), ..sni(profile()) });
    stream.nodes[0].domain = None;
    stream.subscription_host = Some(subscription);
    stream.telegram.push(telegram);
    // SNI without roles: mihomo owns 443.
    let mut bare = config(Profile { vless_grpc: Some(PortOnly { port: 2083 }), ..sni(profile()) });
    bare.nodes[0].domain = None;
    // No Reality: xHTTP behind nginx TLS and Hysteria2 with the site certificate.
    let free = config(Profile { vless_tcp: false, vless_xhttp: Some(Xhttp { topology: XhttpTopology::Nginx, port: None }),
        hysteria2: Some(Hysteria2 { port: 8843, obfs: false }), ..profile() });
    // The entry node of a cascade; mihomo checks the exit's Reality public key.
    let mut cascade = cascade_config(crate::model::ExitProxy::VlessTcp);
    cascade.nodes[1].params.reality.as_mut().unwrap().public_key = URL_SAFE_NO_PAD.encode([5u8; 32]);

    for (name, config) in [("self-steal", self_steal), ("stream", stream), ("bare", bare), ("free", free), ("cascade", cascade)] {
        let desired = desired(&config, &config.nodes[0], Some(&keys)).unwrap();
        for file in &desired.files {
            let path = root.join(name).join(file.path.trim_start_matches('/'));
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            if file.mode == "link" {
                std::os::unix::fs::symlink(file.content.as_str(), &path).unwrap();
            } else {
                std::fs::write(&path, file.content.as_bytes()).unwrap();
            }
        }
    }
}
