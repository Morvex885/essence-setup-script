//! VLESS TCP + Reality builders (`common/protocols/vless-tcp.sh`).

use super::uri::percent_encode;
use super::{line, or, uri_host, yaml_escape, yaml_host, Vless, VlessListener};

/// Flow used by every TCP Reality client.
pub const FLOW: &str = "xtls-rprx-vision";

/// Listener block for the server's `config.yaml`.
pub fn listener_yaml(listener: &VlessListener) -> String {
    format!(
        "  - name: {}\n    type: vless\n    listen: {}\n    port: {}\n    users:\n      # client-users-start\n      - username: {}\n        uuid: {}\n        flow: {FLOW}\n      # client-users-end\n{}",
        listener.name,
        yaml_host(listener.listen),
        listener.port,
        listener.username,
        listener.uuid,
        reality_config(listener)
    )
}

/// `reality-config` + `proxy` tail shared by the Reality listeners. `dest` and
/// the SNI are quoted: an IPv6 `[addr]:port` would otherwise start a YAML flow
/// sequence, and an SNI such as `::` is not a valid plain scalar.
pub(super) fn reality_config(listener: &VlessListener) -> String {
    format!(
        "    reality-config:\n      dest: \"{}\"\n      private-key: \"{}\"\n      short-id:\n        - \"{}\"\n      server-names:\n        - \"{}\"\n    proxy: {}\n",
        yaml_escape(listener.dest),
        listener.private_key,
        listener.short_id,
        yaml_escape(listener.sni),
        listener.proxy
    )
}

/// Client config: a `proxies:` document with one quoted-name proxy.
pub fn client_yaml(vless: &Vless) -> String {
    format!(
        "proxies:\n  - name: \"{}\"\n    type: vless\n    server: {}\n    port: {}\n    uuid: {}\n    network: tcp\n    udp: true\n    flow: {FLOW}\n    tls: true\n    servername: \"{}\"\n    reality-opts:\n      public-key: \"{}\"\n      short-id: \"{}\"\n    client-fingerprint: chrome\n",
        yaml_escape(vless.name),
        yaml_host(vless.server),
        vless.port,
        vless.uuid,
        yaml_escape(vless.sni),
        vless.public_key,
        vless.short_id
    )
}

/// Share URI; an empty `name` gives the fragment `VLESS TCP`.
pub fn uri(vless: &Vless) -> String {
    format!(
        "vless://{}@{}:{}?encryption=none&flow={FLOW}&security=reality&sni={}&fp=chrome&pbk={}&sid={}&type=tcp#{}\n",
        percent_encode(vless.uuid),
        uri_host(vless.server),
        vless.port,
        percent_encode(vless.sni),
        percent_encode(vless.public_key),
        percent_encode(vless.short_id),
        percent_encode(or(vless.name, "VLESS TCP"))
    )
}

/// Cascade exit proxy item. Empty `flow` omits flow; pass [`FLOW`] for the
/// default. Empty `fingerprint` → `chrome`; Reality only with a public key.
pub fn exit_yaml(vless: &Vless, flow: &str, fingerprint: &str) -> String {
    let mut out = format!(
        "  - name: {}\n    type: vless\n    server: {}\n    port: {}\n    uuid: {}\n    network: tcp\n    udp: true\n",
        vless.name, yaml_host(vless.server), vless.port, vless.uuid
    );
    if !flow.is_empty() {
        line(&mut out, &format!("    flow: {flow}"));
    }
    line(&mut out, "    tls: true");
    line(&mut out, &format!("    servername: \"{}\"", yaml_escape(vless.sni)));
    push_reality_opts(&mut out, vless);
    line(&mut out, &format!("    client-fingerprint: {}", or(fingerprint, "chrome")));
    out
}

/// Unquoted `reality-opts` of exit proxies, present only with a public key.
pub(super) fn push_reality_opts(out: &mut String, vless: &Vless) {
    if !vless.public_key.is_empty() {
        line(out, "    reality-opts:");
        line(out, &format!("      public-key: {}", vless.public_key));
        line(out, &format!("      short-id: {}", vless.short_id));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exit_yaml_omits_empty_flow_and_defaults_fingerprint() {
        let vless = Vless { name: "x", server: "h", port: "443", uuid: "u", sni: "s", ..Vless::default() };
        let yaml = exit_yaml(&vless, "", "");
        assert!(!yaml.contains("    flow:"));
        assert!(exit_yaml(&vless, FLOW, "").contains("    flow: xtls-rprx-vision\n"));
        assert!(yaml.ends_with("    servername: \"s\"\n    client-fingerprint: chrome\n"));
        let sni = Vless { sni: "::", ..vless };
        assert!(exit_yaml(&sni, "", "").contains("    servername: \"::\"\n"));
        assert!(client_yaml(&Vless { sni: "a\"b", ..vless }).contains("    servername: \"a\\\"b\"\n"));
        assert!(uri(&Vless { name: "", ..vless }).ends_with("&type=tcp#VLESS%20TCP\n"));
    }
}
