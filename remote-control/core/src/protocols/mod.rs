//! Proxy protocol builders and parsers, ported from `common/protocols/*.sh`
//! and `common/listener-users.sh`.
//!
//! Every function is pure: it returns exactly the text the Bash function
//! printed on stdout (trailing newline included). Ports and other values are
//! passed through as text, as the YAML and URI forms need them. Empty optional
//! values select Bash defaults, except explicit empty TCP exit flow omits flow.
//! Byte parity with Bash is pinned by `tests/protocols_golden.rs`.

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

/// An unquoted exit-proxy string value (uuid, flow, keys, short id,
/// fingerprint, mode): kept as is when plain-safe — word characters and inner
/// spaces, no `:`, `#` or quotes, read back by YAML as this same string (Bash
/// output for every normal value) — else double-quoted with [`yaml_escape`].
/// So `01` stays the string `01` instead of the number 1. An empty value stays
/// empty (Bash output; mihomo reads the null as an empty string).
fn yaml_plain(value: &str) -> std::borrow::Cow<'_, str> {
    let safe = value.bytes().all(|b| b.is_ascii_alphanumeric() || b"._/+=- ".contains(&b))
        && !value.starts_with(' ') && !value.ends_with(' ') && !yaml_non_string(value);
    if safe {
        value.into()
    } else {
        format!("\"{}\"", yaml_escape(value)).into()
    }
}

/// An exit-proxy `port:`: digits stay a plain YAML integer, anything else is
/// a [`yaml_plain`] string.
fn yaml_port(value: &str) -> std::borrow::Cow<'_, str> {
    if !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()) {
        value.into()
    } else {
        yaml_plain(value)
    }
}

/// A proxy name in exit YAML and group `proxies:` lists: as is (Bash output),
/// double-quoted when a plain scalar would not read back as this string —
/// `null`, `true`, `123`, `-`, a leading indicator, `: `/` #`, outer spaces.
pub(crate) fn yaml_name(value: &str) -> std::borrow::Cow<'_, str> {
    let indicator = |c: char| ",[]{}#&*!|>'\"%@`".contains(c);
    let mut chars = value.chars();
    let lead = match (chars.next(), chars.next()) {
        (Some(first), _) if indicator(first) => false,
        (Some('-' | '?' | ':'), next) => next.is_some_and(|c| c != ' '),
        (Some(first), _) => first != ' ',
        (None, _) => false,
    };
    let plain = lead
        && !value.ends_with([' ', ':'])
        && !value.contains(": ")
        && !value.contains(" #")
        && !value.chars().any(char::is_control)
        && !yaml_non_string(value);
    if plain {
        value.into()
    } else {
        format!("\"{}\"", yaml_escape(value)).into()
    }
}

/// A non-empty plain scalar YAML (1.1 or 1.2 core, as mihomo's go-yaml) reads
/// as something other than this string: `~`/`null`, a boolean word, a number
/// (decimal, `0x`/`0o`/`0b`, float, `.inf`/`.nan`, `_` separators), or a lone
/// `-` (a sequence entry). Errs on the side of quoting.
fn yaml_non_string(value: &str) -> bool {
    const WORDS: [&str; 26] = [
        "~", "null", "Null", "NULL", "true", "True", "TRUE", "false", "False", "FALSE", "y", "Y", "yes", "Yes", "YES",
        "n", "N", "no", "No", "NO", "on", "On", "ON", "off", "Off", "OFF",
    ];
    if value == "-" || value.starts_with("- ") || WORDS.contains(&value) {
        return true;
    }
    let unsigned = value.strip_prefix(['+', '-']).unwrap_or(value).to_ascii_lowercase().replace('_', "");
    if matches!(unsigned.as_str(), ".inf" | ".nan") {
        return true;
    }
    if let Some(rest) = ["0x", "0o", "0b"].iter().find_map(|prefix| unsigned.strip_prefix(prefix)) {
        return !rest.is_empty() && rest.bytes().all(|b| b.is_ascii_hexdigit());
    }
    let (mantissa, exponent) = unsigned.split_once('e').map_or((unsigned.as_str(), None), |(m, e)| (m, Some(e)));
    let exponent_ok = exponent.is_none_or(|e| {
        let e = e.strip_prefix(['+', '-']).unwrap_or(e);
        !e.is_empty() && e.bytes().all(|b| b.is_ascii_digit())
    });
    mantissa.bytes().any(|b| b.is_ascii_digit())
        && mantissa.bytes().all(|b| b.is_ascii_digit() || b == b'.')
        && mantissa.matches('.').count() <= 1
        && exponent_ok
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

    #[test]
    fn values_yaml_would_retype_are_quoted() {
        for value in ["01", "1", "-1", "+1", "1_0", "0x1F", "0o7", "1e5", "1.5", ".5", "1E-3", ".inf", "-.Inf", ".NaN", "null", "~", "true", "No", "off", "-"] {
            assert_eq!(yaml_plain(value), format!("\"{value}\""), "{value}");
            assert_eq!(yaml_name(value), format!("\"{value}\""), "{value}");
        }
        assert_eq!(yaml_plain(""), "");
        assert_eq!(yaml_name(""), "\"\"");
        for value in ["abcd", "0e5f", "1.2.3", "1e", "xtls-rprx-vision", "chrome", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "a1", "nullx"] {
            assert_eq!(yaml_plain(value), value);
            assert_eq!(yaml_name(value), value);
        }
        for name in ["- a", "?", "a: b", "a #b", "a:", " a", "&a", "*a", "!a", "#a", "'a", "[a", "{a", "|", ">", "%a", "@a", "`a"] {
            assert!(yaml_name(name).starts_with('"'), "{name}");
        }
        for name in ["-a", "?a", ":a", "a:b", "a#b", "Выход 1", "my-proxy"] {
            assert_eq!(yaml_name(name), name);
        }
        assert_eq!(yaml_port("443"), "443");
        assert_eq!(yaml_port("4:43"), "\"4:43\"");
    }
}
