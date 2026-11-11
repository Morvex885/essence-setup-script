//! VLESS xHTTP builders (`common/protocols/vless-xhttp.sh`): Reality, or TLS
//! terminated by nginx in front of a plain listener.

use super::uri::percent_encode;
use super::vless_grpc::listener_head;
use super::vless_tcp::{push_reality_opts, reality_config};
use super::{line, or, uri_host, yaml_name, Vless, VlessListener};

/// A plain listener behind nginx TLS termination.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NginxListener<'a> {
    pub name: &'a str,
    pub listen: &'a str,
    pub port: &'a str,
    pub username: &'a str,
    pub uuid: &'a str,
    pub path: &'a str,
    pub proxy: &'a str,
}

fn xhttp_config(out: &mut String, path: &str) {
    line(out, "    xhttp-config:");
    line(out, &format!("      path: \"{path}\""));
    line(out, "      mode: auto");
}

/// Reality listener block for the server's `config.yaml`.
pub fn listener_yaml(listener: &VlessListener, path: &str) -> String {
    let mut out = listener_head(listener.name, listener.listen, listener.port, listener.username, listener.uuid);
    xhttp_config(&mut out, path);
    out.push_str(&reality_config(listener));
    out
}

/// Plain listener block behind nginx (nginx owns the public TLS).
pub fn nginx_listener_yaml(listener: &NginxListener) -> String {
    let mut out = listener_head(listener.name, listener.listen, listener.port, listener.username, listener.uuid);
    xhttp_config(&mut out, listener.path);
    line(&mut out, "    allow-insecure: true");
    line(&mut out, &format!("    proxy: {}", listener.proxy));
    out
}

/// Client config: Reality when `public_key` is set, otherwise TLS.
pub fn client_yaml(vless: &Vless, path: &str) -> String {
    let mut out = format!(
        "proxies:\n  - name: \"{}\"\n    type: vless\n    server: {}\n    port: {}\n    uuid: {}\n    network: xhttp\n    udp: true\n    tls: true\n    servername: {}\n    xhttp-opts:\n      path: \"{path}\"\n      mode: auto\n",
        yaml_name(vless.name), vless.server, vless.port, vless.uuid, vless.sni
    );
    if !vless.public_key.is_empty() {
        line(&mut out, "    reality-opts:");
        line(&mut out, &format!("      public-key: \"{}\"", vless.public_key));
        line(&mut out, &format!("      short-id: \"{}\"", vless.short_id));
    }
    line(&mut out, "    client-fingerprint: firefox");
    out
}

/// Share URI (query values and fragment percent-encoded); Reality when
/// `public_key` is set, otherwise TLS. Empty `name` → fragment `VLESS xHTTP`.
pub fn uri(vless: &Vless, path: &str) -> String {
    let sni = percent_encode(vless.sni);
    let security = if vless.public_key.is_empty() {
        format!("security=tls&sni={sni}&fp=firefox")
    } else {
        format!(
            "security=reality&sni={sni}&fp=firefox&pbk={}&sid={}",
            percent_encode(vless.public_key),
            percent_encode(vless.short_id)
        )
    };
    format!(
        "vless://{}@{}:{}?encryption=none&{security}&type=xhttp&path={}&mode=auto#{}\n",
        vless.uuid,
        uri_host(vless.server),
        vless.port,
        percent_encode(path),
        percent_encode(or(vless.name, "VLESS xHTTP"))
    )
}

/// Cascade exit proxy item; empty `mode` → `auto`. The fingerprint is always
/// `firefox` (the only one known to work with xHTTP).
pub fn exit_yaml(vless: &Vless, path: &str, mode: &str) -> String {
    let mut out = format!(
        "  - name: {}\n    type: vless\n    server: {}\n    port: {}\n    uuid: {}\n    network: xhttp\n    udp: true\n    xhttp-opts:\n      path: \"{path}\"\n      mode: {}\n    tls: true\n    servername: {}\n",
        vless.name,
        vless.server,
        vless.port,
        vless.uuid,
        or(mode, "auto"),
        vless.sni
    );
    push_reality_opts(&mut out, vless);
    line(&mut out, "    client-fingerprint: firefox");
    out
}

const FINGERPRINT_KEY: &str = "    client-fingerprint:";

/// Forces `client-fingerprint: firefox` on an extracted xHTTP proxy block
/// (replacing every existing fingerprint line, or appending one). Other
/// blocks are returned unchanged. Trailing newlines collapse into one; CRLF
/// blocks keep their line endings.
pub fn normalize_proxy_yaml(block: &str) -> String {
    let block = block.trim_end_matches('\n');
    let is_xhttp = block
        .split('\n')
        .any(|l| l.strip_prefix("    network: xhttp").is_some_and(|rest| rest.is_empty() || rest == "\r"));
    if !is_xhttp {
        return format!("{block}\n");
    }
    if !block.split('\n').any(|l| l.starts_with(FINGERPRINT_KEY)) {
        let eol = if block.contains('\r') { "\r" } else { "" };
        return format!("{block}\n{FINGERPRINT_KEY} firefox{eol}\n");
    }
    let mut out = String::with_capacity(block.len() + 16);
    for l in block.split('\n') {
        match l.strip_prefix(FINGERPRINT_KEY) {
            Some(rest) => {
                out.push_str(FINGERPRINT_KEY);
                out.push_str(" firefox");
                out.push_str(rest.find('\r').map_or("", |at| &rest[at..]));
            }
            None => out.push_str(l),
        }
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_replaces_appends_and_passes_through() {
        assert_eq!(
            normalize_proxy_yaml("  - name: n\r\n    network: xhttp\r\n    client-fingerprint: chrome\r\n"),
            "  - name: n\r\n    network: xhttp\r\n    client-fingerprint: firefox\r\n"
        );
        assert_eq!(
            normalize_proxy_yaml("  - name: n\n    network: xhttp\n\n"),
            "  - name: n\n    network: xhttp\n    client-fingerprint: firefox\n"
        );
        assert_eq!(normalize_proxy_yaml("  network: xhttp"), "  network: xhttp\n");
        assert_eq!(normalize_proxy_yaml(""), "\n");
    }

    #[test]
    fn uri_encodes_query_values() {
        let vless = Vless { uuid: "u", server: "h", port: "1", sni: "a&b", ..Vless::default() };
        assert_eq!(
            uri(&vless, "/p q"),
            "vless://u@h:1?encryption=none&security=tls&sni=a%26b&fp=firefox&type=xhttp&path=%2Fp%20q&mode=auto#VLESS%20xHTTP\n"
        );
    }
}
