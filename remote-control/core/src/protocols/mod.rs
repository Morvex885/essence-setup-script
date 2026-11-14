//! Proxy protocol builders and parsers, ported from `common/protocols/*.sh`
//! and `common/listener-users.sh`.
//!
//! Every function is pure: it returns exactly the text the Bash function
//! printed on stdout (trailing newline included). Ports and other values are
//! passed through as text, as the YAML and URI forms need them. Empty optional
//! values select Bash defaults, except explicit empty TCP exit flow omits flow.
//! Byte parity with Bash is pinned by `tests/protocols_golden.rs`.

pub mod dnat;
pub mod hy2;
pub mod listener_users;
pub mod uri;
pub mod vless_grpc;
pub mod vless_tcp;
pub mod vless_xhttp;

pub use vless_xhttp::normalize_proxy_yaml as normalize_vless_xhttp_proxy_yaml;

/// A VLESS endpoint as seen by a client: proxy YAML, share URI and cascade
/// exit YAML. `name` is the proxy name in YAML and the URI fragment (an empty
/// fragment falls back to the transport's display name).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Vless<'a> {
    pub name: &'a str,
    pub server: &'a str,
    pub port: &'a str,
    pub uuid: &'a str,
    pub sni: &'a str,
    /// Reality public key; empty means no Reality options where optional.
    pub public_key: &'a str,
    pub short_id: &'a str,
}

/// A server-side VLESS Reality listener with its first user.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct VlessListener<'a> {
    pub name: &'a str,
    pub listen: &'a str,
    pub port: &'a str,
    pub username: &'a str,
    pub uuid: &'a str,
    /// Reality handshake destination (`host:port`).
    pub dest: &'a str,
    pub private_key: &'a str,
    pub short_id: &'a str,
    pub sni: &'a str,
    pub proxy: &'a str,
}

/// `value`, or `default` when `value` is empty (Bash `${n:-default}`).
fn or<'a>(value: &'a str, default: &'a str) -> &'a str {
    if value.is_empty() { default } else { value }
}

/// URI authority host: a bare IPv6 address is bracketed, everything else
/// (including an already bracketed address) is kept.
fn uri_host(server: &str) -> std::borrow::Cow<'_, str> {
    if server.contains(':') && !server.starts_with('[') {
        format!("[{server}]").into()
    } else {
        server.into()
    }
}

/// Escapes the contents of a double-quoted YAML scalar (client names, xHTTP
/// paths, gRPC service names, Hysteria2 passwords, Reality dest), matching
/// Bash: backslash, double quote, LF and CR. Identity (borrowed) for every
/// value without those characters.
pub(crate) fn yaml_escape(name: &str) -> std::borrow::Cow<'_, str> {
    if !name.contains(['\\', '"', '\n', '\r']) {
        return name.into();
    }
    let mut escaped = String::with_capacity(name.len());
    for ch in name.chars() {
        match ch {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            _ => escaped.push(ch),
        }
    }
    escaped.into()
}

/// Address for a YAML `server:`/`listen:` value. A bracketed IPv6 `[addr]`
/// loses its brackets (a plain scalar starting with `[` is a flow sequence);
/// an address ending with `:` (`::`, `2001:db8::`) is double-quoted, since a
/// `:` before the line break is a mapping indicator. Other addresses such as
/// `::1` or `2001:db8::1` stay plain strings, as Bash consumers read them.
fn yaml_host(server: &str) -> std::borrow::Cow<'_, str> {
    let host = server.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')).unwrap_or(server);
    if host.ends_with(':') {
        format!("\"{host}\"").into()
    } else {
        host.into()
    }
}

/// Appends `line` and a newline (Bash `echo "$line"`).
fn line(out: &mut String, text: &str) {
    out.push_str(text);
    out.push('\n');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uri_host_brackets_only_bare_ipv6() {
        assert_eq!(uri_host("h.example"), "h.example");
        assert_eq!(uri_host("2001:db8::1"), "[2001:db8::1]");
        assert_eq!(uri_host("[2001:db8::1]"), "[2001:db8::1]");
        assert_eq!(or("", "d"), "d");
        assert_eq!(or("v", "d"), "v");
        assert_eq!(yaml_host("[2001:db8::1]"), "2001:db8::1");
        assert_eq!(yaml_host("::1"), "::1");
        assert_eq!(yaml_host("::"), "\"::\"");
        assert_eq!(yaml_host("[::]"), "\"::\"");
        assert_eq!(yaml_host("[::1"), "[::1");
    }

    #[test]
    fn client_yaml_names_escape_backslashes_quotes_and_line_endings() {
        let name = "Выход \\ \"q\"\r\n";
        let quoted = "proxies:\n  - name: \"Выход \\\\ \\\"q\\\"\\r\\n\"\n";
        let vless = Vless { name, ..Vless::default() };
        let hy2 = hy2::Hy2 {
            name, server: "", port: "", password: "", sni: "",
            skip_cert_verify: true, obfs_password: "",
        };
        for yaml in [
            vless_tcp::client_yaml(&vless),
            vless_grpc::client_yaml(&vless, ""),
            vless_xhttp::client_yaml(&vless, ""),
            hy2::client_yaml(&hy2),
        ] {
            assert!(yaml.starts_with(quoted), "{yaml:?}");
        }
    }
}
