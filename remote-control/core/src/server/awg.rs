//! AmneziaWG of a profiled node: the server `awg0.conf` (`_awg_stage_server_config`),
//! its peers and the client configs (`_awg_create_peer`, `setup-essence/modules/amneziawg.sh`).
//! One key per client serves every node; the client's address comes from its
//! `awg_index` in `10.10.0.0/16`, so no state lives on the servers.

use crate::clients::client_nodes;
use crate::clients::generate::effective_connections;
use crate::error::Result;
use crate::model::{AmneziaWg, Client, Config, NodeAwg};

use super::keys::wg_public;

/// The server's address in the AmneziaWG subnet.
pub const SERVER_ADDRESS: &str = "10.10.0.1/16";
const SUBNET: &str = "10.10.0.0/16";

/// Fixed obfuscation parameters of `_awg_gen_params`.
const JMIN: u8 = 10;
const JMAX: u8 = 50;
const S4: u16 = 12;
const RANGES: [(&str, &str); 6] = [
    ("ContentPaddingAddition", "10-100"), ("RekeyAfterTime", "100-120"), ("RekeyTimeout", "3-7"),
    ("RejectAfterTime", "150-180"), ("KeepaliveTimeout", "5-15"), ("MaxHandshakeAttempts", "15-20"),
];

/// The client is assigned to the node and its connections there (its own,
/// else its group's) include AmneziaWG; a client without connections on the
/// node uses all of them, as for the other listeners.
pub(crate) fn needs_peer(config: &Config, client: &Client, node: &str) -> bool {
    if !client_nodes(config, client).iter().any(|assigned| assigned == node) {
        return false;
    }
    let connections = effective_connections(config, client, node);
    connections.is_empty() || connections.iter().any(|proxy| proxy == "AWG" || proxy.starts_with("awg-"))
}

/// Peers of the node: clients that need one and have AmneziaWG credentials,
/// by ascending `awg_index`.
pub fn expected_peers<'a>(config: &'a Config, node: &str) -> Vec<&'a Client> {
    let mut peers: Vec<&Client> = config.clients.iter()
        .filter(|client| needs_peer(config, client, node))
        .filter(|client| client.credentials.as_ref().is_some_and(|c| c.awg_index != 0 && !c.awg_private_key.is_empty()))
        .collect();
    peers.sort_by_key(|client| client.credentials.as_ref().map_or(0, |c| c.awg_index));
    peers
}

/// `10.10.<index / 256>.<index % 256>`.
pub fn peer_ip(index: u32) -> String {
    format!("10.10.{}.{}", index / 256, index % 256)
}

fn obfuscation(awg: &NodeAwg, out: &mut String, key: impl Fn(&str) -> String) {
    for (name, value) in [
        ("Jc", awg.jc.to_string()), ("Jmin", JMIN.to_string()), ("Jmax", JMAX.to_string()),
        ("S1", awg.s1.to_string()), ("S2", awg.s2.to_string()), ("S3", awg.s3.to_string()), ("S4", S4.to_string()),
        ("H1", "1".into()), ("H2", "2".into()), ("H3", "3".into()), ("H4", "4".into()),
        ("HeaderProtectionKey", awg.header_protection_key.clone()),
    ] {
        out.push_str(&format!("{} = {value}\n", key(name)));
    }
    for (name, value) in RANGES {
        out.push_str(&format!("{} = {value}\n", key(name)));
    }
    out.push_str(&format!("{} = on\n{} = on\n", key("RandomTrailers"), key("DisableCookies")));
}

/// The server `awg0.conf`: the interface, then one `# peer:` block per peer.
pub fn server_conf(config: &Config, node_name: &str, awg: &NodeAwg, port: u16, private_key: &str) -> Result<String> {
    let mut out = format!("[Interface]\nPrivateKey = {private_key}\nAddress = {SERVER_ADDRESS}\nListenPort = {port}\n");
    obfuscation(awg, &mut out, str::to_owned);
    let tproxy = awg.tproxy_port;
    out.push_str(&format!(
        "PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -I INPUT -m mark --mark 1 -j ACCEPT; ip rule add fwmark 1 table 100 || true; \
ip route add local 0.0.0.0/0 dev lo table 100 || true; iptables -t mangle -N MIHOMO_AWG || true; iptables -t mangle -F MIHOMO_AWG; \
iptables -t mangle -A MIHOMO_AWG -d {SUBNET} -j RETURN; iptables -t mangle -A MIHOMO_AWG -d 127.0.0.0/8 -j RETURN; \
iptables -t mangle -A MIHOMO_AWG -d 224.0.0.0/4 -j RETURN; \
iptables -t mangle -A MIHOMO_AWG -p tcp -j TPROXY --on-ip 127.0.0.1 --on-port {tproxy} --tproxy-mark 1; \
iptables -t mangle -A MIHOMO_AWG -p udp -j TPROXY --on-ip 127.0.0.1 --on-port {tproxy} --tproxy-mark 1; \
iptables -t mangle -A PREROUTING -i %i -j MIHOMO_AWG; iptables -t nat -A PREROUTING -i %i -p udp --dport 53 -j REDIRECT --to-ports 1053\n\
PostDown = iptables -D FORWARD -i %i -j ACCEPT || true; iptables -D INPUT -m mark --mark 1 -j ACCEPT || true; \
iptables -t mangle -D PREROUTING -i %i -j MIHOMO_AWG || true; iptables -t mangle -F MIHOMO_AWG || true; \
iptables -t mangle -X MIHOMO_AWG || true; iptables -t nat -D PREROUTING -i %i -p udp --dport 53 -j REDIRECT --to-ports 1053 || true; \
ip rule del fwmark 1 table 100 || true; ip route del local 0.0.0.0/0 dev lo table 100 || true\n"));
    for client in expected_peers(config, node_name) {
        let Some(credentials) = client.credentials.as_ref() else { continue };
        out.push_str(&format!("\n# peer: {}\n[Peer]\nPublicKey = {}\nPresharedKey = {}\nAllowedIPs = {}/32\n",
            client.name, wg_public(&credentials.awg_private_key)?, credentials.awg_preshared_key, peer_ip(credentials.awg_index)));
    }
    Ok(out)
}

/// `dns: ['1.1.1.1', '1.0.0.1']` items of the profile's DNS list.
fn dns_yaml(dns: &str) -> String {
    dns.split(',').map(str::trim).filter(|item| !item.is_empty())
        .map(|item| format!("'{}'", item.replace('\'', "''"))).collect::<Vec<_>>().join(", ")
}

/// The client's mihomo proxy `awg-<client>` (`mihomo-proxy.yaml` of `_awg_create_peer`).
pub fn proxy_block(client: &Client, server: &str, port: u16, profile: &AmneziaWg, awg: &NodeAwg) -> Option<String> {
    let credentials = client.credentials.as_ref()?;
    let mut out = format!(
        "  - name: awg-{}\n    type: wireguard\n    private-key: {}\n    server: {server}\n    port: {port}\n    ip: {}\n    mtu: 1280\n\
         \x20   dns: [{}]\n    public-key: {}\n    pre-shared-key: {}\n    allowed-ips: ['0.0.0.0/0', '::/0']\n    udp: true\n\
         \x20   persistent-keepalive: 25\n    amnezia-wg-option:\n      version: 3\n",
        client.name, credentials.awg_private_key, peer_ip(credentials.awg_index), dns_yaml(&profile.dns),
        awg.public_key, credentials.awg_preshared_key);
    for (name, value) in [
        ("jc", awg.jc.to_string()), ("jmin", JMIN.to_string()), ("jmax", JMAX.to_string()),
        ("s1", awg.s1.to_string()), ("s2", awg.s2.to_string()), ("s3", awg.s3.to_string()), ("s4", S4.to_string()),
        ("h1", "1".into()), ("h2", "2".into()), ("h3", "3".into()), ("h4", "4".into()),
        ("header-protection-key", awg.header_protection_key.clone()),
        ("content-padding-addition", RANGES[0].1.into()), ("rekey-after-time", RANGES[1].1.into()),
        ("rekey-timeout", RANGES[2].1.into()), ("reject-after-time", RANGES[3].1.into()),
        ("keepalive-timeout", RANGES[4].1.into()), ("max-handshake-attempts", RANGES[5].1.into()),
        ("random-trailers", "true".into()), ("disable-cookies", "true".into()),
    ] {
        out.push_str(&format!("      {name}: {value}\n"));
    }
    Some(out)
}

/// The native client `.conf` of `_awg_create_peer` (keepalive fixed at 25).
pub fn client_conf(client: &Client, server: &str, port: u16, profile: &AmneziaWg, awg: &NodeAwg) -> Option<String> {
    let credentials = client.credentials.as_ref()?;
    let mut out = format!("[Interface]\nAddress = {}/32\nDNS = {}\nMTU = 1280\nPrivateKey = {}\n",
        peer_ip(credentials.awg_index), profile.dns, credentials.awg_private_key);
    obfuscation(awg, &mut out, str::to_owned);
    out.push_str(&format!("\n[Peer]\nPublicKey = {}\nPresharedKey = {}\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = {}:{port}\nPersistentKeepalive = 25\n",
        awg.public_key, credentials.awg_preshared_key, endpoint_host(server)));
    Some(out)
}

/// A bare IPv6 address is bracketed in `Endpoint`.
fn endpoint_host(server: &str) -> String {
    if server.contains(':') && !server.starts_with('[') { format!("[{server}]") } else { server.to_owned() }
}
