//! VLESS gRPC + Reality builders (`common/protocols/vless-grpc.sh`).

use super::uri::percent_encode;
use super::vless_tcp::{push_reality_opts, reality_config};
use super::{line, or, uri_host, yaml_escape, yaml_host, Vless, VlessListener};

/// Users block of a listener without flow (gRPC, xHTTP).
pub(super) fn listener_head(listener_name: &str, listen: &str, port: &str, username: &str, uuid: &str) -> String {
    let listen = yaml_host(listen);
    format!(
        "  - name: {listener_name}\n    type: vless\n    listen: {listen}\n    port: {port}\n    users:\n      # client-users-start\n      - username: {username}\n        uuid: {uuid}\n      # client-users-end\n"
    )
}

/// Listener block for the server's `config.yaml`.
pub fn listener_yaml(listener: &VlessListener, service: &str) -> String {
    let mut out = listener_head(listener.name, listener.listen, listener.port, listener.username, listener.uuid);
    line(&mut out, &format!("    grpc-service-name: \"{}\"", yaml_escape(service)));
    out.push_str(&reality_config(listener));
    out
}

/// Client config: a `proxies:` document with one quoted-name proxy.
pub fn client_yaml(vless: &Vless, service: &str) -> String {
    format!(
        "proxies:\n  - name: \"{}\"\n    type: vless\n    server: {}\n    port: {}\n    uuid: {}\n    network: grpc\n    udp: true\n    tls: true\n    servername: {}\n    grpc-opts:\n      grpc-service-name: \"{}\"\n    reality-opts:\n      public-key: \"{}\"\n      short-id: \"{}\"\n    client-fingerprint: chrome\n",
        yaml_escape(vless.name),
        yaml_host(vless.server),
        vless.port,
        vless.uuid,
        vless.sni,
        yaml_escape(service),
        vless.public_key,
        vless.short_id
    )
}

/// Share URI; an empty `name` gives the fragment `VLESS gRPC`.
pub fn uri(vless: &Vless, service: &str) -> String {
    let service = percent_encode(service);
    format!(
        "vless://{}@{}:{}?encryption=none&security=reality&sni={}&fp=chrome&pbk={}&sid={}&type=grpc&serviceName={service}#{}\n",
        percent_encode(vless.uuid),
        uri_host(vless.server),
        vless.port,
        percent_encode(vless.sni),
        percent_encode(vless.public_key),
        percent_encode(vless.short_id),
        percent_encode(or(vless.name, "VLESS gRPC"))
    )
}

/// Cascade exit proxy item; empty `fingerprint` → `chrome`.
pub fn exit_yaml(vless: &Vless, service: &str, fingerprint: &str) -> String {
    let mut out = format!(
        "  - name: {}\n    type: vless\n    server: {}\n    port: {}\n    uuid: {}\n    network: grpc\n    udp: true\n    grpc-opts:\n      grpc-service-name: \"{}\"\n    tls: true\n    servername: {}\n",
        vless.name,
        yaml_host(vless.server),
        vless.port,
        vless.uuid,
        yaml_escape(service),
        vless.sni
    );
    push_reality_opts(&mut out, vless);
    line(&mut out, &format!("    client-fingerprint: {}", or(fingerprint, "chrome")));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uri_defaults_fragment_and_brackets_ipv6() {
        let vless = Vless { server: "::1", port: "1", uuid: "u", ..Vless::default() };
        assert_eq!(
            uri(&vless, "g"),
            "vless://u@[::1]:1?encryption=none&security=reality&sni=&fp=chrome&pbk=&sid=&type=grpc&serviceName=g#VLESS%20gRPC\n"
        );
        assert!(!exit_yaml(&vless, "g", "").contains("reality-opts"));
    }

    #[test]
    fn yaml_escapes_service_and_unbrackets_server() {
        let vless = Vless { server: "[2001:db8::1]", ..Vless::default() };
        for yaml in [client_yaml(&vless, "a\"b\\c"), exit_yaml(&vless, "a\"b\\c", "")] {
            assert!(yaml.contains("    server: 2001:db8::1\n"), "{yaml}");
            assert!(yaml.contains("      grpc-service-name: \"a\\\"b\\\\c\"\n"), "{yaml}");
        }
    }
}
