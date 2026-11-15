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

fn secrets() -> NodeSecrets {
    NodeSecrets { reality_key: Some(Zeroizing::new("PRIVKEY".into())), ..NodeSecrets::default() }
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
    // Without `no-resolve`: a domain pointing into these networks is rejected too.
    assert_eq!(rules, [
        "IP-CIDR,127.0.0.0/8,REJECT", "IP-CIDR6,::1/128,REJECT", "IP-CIDR,169.254.0.0/16,REJECT",
        "IP-CIDR,10.0.0.0/8,REJECT", "IP-CIDR,172.16.0.0/12,REJECT", "IP-CIDR,192.168.0.0/16,REJECT",
        "IP-CIDR,100.64.0.0/10,REJECT", "IP-CIDR6,fc00::/7,REJECT", "IP-CIDR6,fe80::/10,REJECT",
        "MATCH,outbound",
    ]);
    assert!(!mihomo.contains("no-resolve"));
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
