//! Hysteria2 builders (`common/protocols/hy2.sh`).

use super::uri::percent_encode;
use super::{line, or, uri_host, yaml_escape, yaml_host};

/// SNI used when none is given.
pub const DEFAULT_SNI: &str = "www.google.de";

/// A Hysteria2 endpoint as seen by a client. Empty `sni` → [`DEFAULT_SNI`];
/// empty `obfs_password` → no salamander obfuscation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Hy2<'a> {
    pub name: &'a str,
    pub server: &'a str,
    pub port: &'a str,
    pub password: &'a str,
    pub sni: &'a str,
    pub skip_cert_verify: bool,
    pub obfs_password: &'a str,
}

/// A server-side Hysteria2 listener with its first user.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Hy2Listener<'a> {
    pub name: &'a str,
    pub port: &'a str,
    pub user: &'a str,
    pub password: &'a str,
    pub proxy: &'a str,
    pub obfs_password: &'a str,
}

fn push_obfs(out: &mut String, obfs_password: &str) {
    if !obfs_password.is_empty() {
        line(out, "    obfs: salamander");
        line(out, &format!("    obfs-password: \"{}\"", yaml_escape(obfs_password)));
    }
}

/// Listener block for the server's `config.yaml`. Passwords are quoted: a
/// plain scalar breaks on ` #`, a leading indicator or a line break.
pub fn listener_yaml(listener: &Hy2Listener) -> String {
    let mut out = format!(
        "  - name: {}\n    type: hysteria2\n    listen: 0.0.0.0\n    port: {}\n    users:\n      # client-users-start\n      {}: \"{}\"\n      # client-users-end\n",
        listener.name, listener.port, listener.user, yaml_escape(listener.password)
    );
    push_obfs(&mut out, listener.obfs_password);
    line(&mut out, "    certificate: /etc/mihomo/certs/hy2/server.crt");
    line(&mut out, "    private-key: /etc/mihomo/certs/hy2/server.key");
    line(&mut out, &format!("    proxy: {}", listener.proxy));
    out
}

fn proxy_body(out: &mut String, hy2: &Hy2) {
    out.push_str(&format!(
        "    type: hysteria2\n    server: {}\n    port: {}\n    password: \"{}\"\n    sni: \"{}\"\n    skip-cert-verify: {}\n",
        yaml_host(hy2.server),
        hy2.port,
        yaml_escape(hy2.password),
        yaml_escape(or(hy2.sni, DEFAULT_SNI)),
        hy2.skip_cert_verify
    ));
    push_obfs(out, hy2.obfs_password);
}

/// Client config: a `proxies:` document with one quoted-name proxy.
pub fn client_yaml(hy2: &Hy2) -> String {
    let mut out = format!("proxies:\n  - name: \"{}\"\n", yaml_escape(hy2.name));
    proxy_body(&mut out, hy2);
    out
}

/// Share URI (`hysteria2://`); `name` and `skip_cert_verify` are not part of it.
pub fn uri(hy2: &Hy2) -> String {
    let obfs = if hy2.obfs_password.is_empty() {
        String::new()
    } else {
        format!("&obfs=salamander&obfs-password={}", percent_encode(hy2.obfs_password))
    };
    format!(
        "hysteria2://{}@{}:{}?insecure=1&sni={}{obfs}\n",
        percent_encode(hy2.password),
        uri_host(hy2.server),
        hy2.port,
        percent_encode(or(hy2.sni, DEFAULT_SNI))
    )
}

/// Cascade exit proxy item (unquoted name).
pub fn exit_yaml(hy2: &Hy2) -> String {
    let mut out = format!("  - name: {}\n", hy2.name);
    proxy_body(&mut out, hy2);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uri_brackets_ipv6_and_adds_obfs() {
        let hy2 = Hy2 {
            name: "n",
            server: "2001:db8::1",
            port: "443",
            password: "pw",
            sni: "",
            skip_cert_verify: false,
            obfs_password: "o",
        };
        assert_eq!(
            uri(&hy2),
            "hysteria2://pw@[2001:db8::1]:443?insecure=1&sni=www.google.de&obfs=salamander&obfs-password=o\n"
        );
        assert!(exit_yaml(&hy2).contains("    skip-cert-verify: false\n    obfs: salamander\n"));
    }

    #[test]
    fn yaml_quotes_passwords_and_unbrackets_server() {
        let hy2 = Hy2 {
            name: "n",
            server: "[2001:db8::1]",
            port: "443",
            password: "p #\"\\\n",
            sni: "",
            skip_cert_verify: true,
            obfs_password: "- o #",
        };
        for yaml in [client_yaml(&hy2), exit_yaml(&hy2)] {
            assert!(yaml.contains("    server: 2001:db8::1\n"), "{yaml}");
            assert!(yaml.contains("    password: \"p #\\\"\\\\\\n\"\n"), "{yaml}");
            assert!(yaml.contains("    obfs-password: \"- o #\"\n"), "{yaml}");
        }
        let listener = Hy2Listener { user: "u", password: "a #b", obfs_password: "o", ..Hy2Listener::default() };
        assert!(listener_yaml(&listener).contains("      u: \"a #b\"\n      # client-users-end\n    obfs: salamander\n    obfs-password: \"o\"\n"));
    }
}
