//! Share-URI parsing (`common/protocols/uri.sh`): percent coding, server/port
//! extraction and `vless://` / `hy2://` / `hysteria2://` → cascade exit YAML.

use std::fmt::Write as _;

use super::hy2::{self, Hy2};
use super::{vless_grpc, vless_tcp, vless_xhttp, Vless};

/// Why a share URI cannot become an exit proxy. `Display` is the v1 message.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum UriError {
    #[error("Некорректное percent-кодирование в VLESS URI")]
    VlessPercent,
    #[error("Некорректное percent-кодирование в Hysteria2 URI")]
    Hy2Percent,
    /// `note` is the informational line v1 printed before failing.
    #[error("Неизвестный транспорт VLESS: {transport}. Поддерживаются: tcp, xhttp, grpc")]
    UnknownTransport { transport: String, note: String },
    #[error("Неизвестный протокол. Поддерживаются: vless://, hysteria2://, hy2://")]
    UnknownScheme,
    #[error("Недопустимое значение «{field}» в ссылке выхода")]
    Field { field: &'static str },
}

/// A parsed exit proxy: its YAML block and the informational lines v1 showed
/// while parsing (e.g. `VLESS tcp: host:443 (SNI: sni)`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExitProxy {
    pub yaml: String,
    pub notes: Vec<String>,
}

/// Server and port of a share URI; `port` is empty when the URI has none.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ServerPort {
    pub server: String,
    pub port: String,
}

/// RFC 3986 percent-encoding: every byte outside the unreserved set
/// (`A-Z a-z 0-9 - . _ ~`) becomes `%XX` (upper-case hex).
pub fn percent_encode(input: impl AsRef<[u8]>) -> String {
    let input = input.as_ref();
    let mut out = String::with_capacity(input.len());
    for &byte in input {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(byte as char);
        } else {
            let _ = write!(out, "%{byte:02X}");
        }
    }
    out
}

/// Strict percent-decoding. `None` for a truncated or non-hex escape and for
/// `%00`. The result is raw bytes (it need not be UTF-8).
pub fn percent_decode(input: &str) -> Option<Vec<u8>> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = bytes.get(i + 1..i + 3)?;
            let hex = std::str::from_utf8(hex).ok()?;
            if !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
                return None;
            }
            let value = u8::from_str_radix(hex, 16).ok()?;
            if value == 0 {
                return None;
            }
            out.push(value);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    Some(out)
}

/// Parts of a scheme-less `userinfo@host:port?params#fragment`.
struct Split<'a> {
    userinfo: &'a str,
    server: &'a str,
    port: &'a str,
    params: &'a str,
}

/// One trailing CR and the fragment are dropped; userinfo ends at the last
/// `@`; a bracketed IPv6 host is returned unbracketed.
fn split(uri: &str) -> Split<'_> {
    let uri = uri.strip_suffix('\r').unwrap_or(uri);
    let uri = uri.split('#').next().unwrap_or_default();
    let (uri, params) = uri.split_once('?').unwrap_or((uri, ""));
    let (userinfo, hostport) = uri.rsplit_once('@').unwrap_or(("", uri));
    let bracketed = hostport
        .strip_prefix('[')
        .and_then(|rest| rest.split_once(']'));
    let (server, port) = match bracketed {
        Some((server, rest)) => (server, rest.strip_prefix(':').unwrap_or("")),
        None => match hostport.split_once(':') {
            Some((server, _)) => (server, hostport.rsplit_once(':').map_or("", |(_, port)| port)),
            None => (hostport, ""),
        },
    };
    Split { userinfo, server, port, params }
}

/// Server and port of a `vless://`, `hysteria2://` or `hy2://` URI.
pub fn server_port(uri: &str) -> ServerPort {
    let uri = uri.strip_prefix("vless://").unwrap_or(uri);
    let uri = uri.strip_prefix("hysteria2://").unwrap_or(uri);
    let uri = uri.strip_prefix("hy2://").unwrap_or(uri);
    let parts = split(uri);
    ServerPort { server: parts.server.to_owned(), port: parts.port.to_owned() }
}

/// A percent-decoded URI component that must be UTF-8 without control
/// characters: it ends up in a single-line YAML value.
fn decode_value(raw: &str, error: &UriError) -> Result<String, UriError> {
    percent_decode(raw)
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .filter(|value| !value.chars().any(char::is_control))
        .ok_or_else(|| error.clone())
}

/// Decoded `key=value` query params (a param without `=` is its own value).
fn params(query: &str, error: UriError) -> Result<Vec<(&str, String)>, UriError> {
    query
        .split('&')
        .filter(|param| !param.is_empty())
        .map(|param| {
            let key = param.split('=').next().unwrap_or_default();
            let value = param.split_once('=').map_or(param, |(_, value)| value);
            decode_value(value, &error).map(|value| (key, value))
        })
        .collect()
}

/// `vless://uuid@server:port?params#fragment` → exit YAML for its transport
/// (`tcp` by default, `xhttp`, `grpc`).
pub fn parse_vless_uri(name: &str, uri: &str) -> Result<ExitProxy, UriError> {
    parse_vless(name, uri, false)
}

/// The port as rendered: an exit link's (already checked) port in canonical
/// decimal — YAML reads `00443` as octal 291; the v1 parser keeps it as is.
fn port(raw: &str, exit: bool) -> std::borrow::Cow<'_, str> {
    match raw.parse::<u16>() {
        Ok(port) if exit => port.to_string().into(),
        _ => raw.into(),
    }
}

/// [`parse_vless_uri`]; for an `exit` link the TCP flow defaults to
/// `xtls-rprx-vision` only with REALITY (`security=reality`, or no
/// `security` with a `pbk`): a TLS server without flow rejects it. The v1
/// parser (Bash parity) always defaults it.
fn parse_vless(name: &str, uri: &str, exit: bool) -> Result<ExitProxy, UriError> {
    let parts = split(uri.strip_prefix("vless://").unwrap_or(uri));
    let uuid = decode_value(parts.userinfo, &UriError::VlessPercent)?;
    let (mut sni, mut public_key, mut short_id, mut flow) = (String::new(), String::new(), String::new(), String::new());
    let (mut fingerprint, mut transport, mut security) = ("chrome".to_owned(), "tcp".to_owned(), String::new());
    let (mut path, mut mode, mut service) = (String::new(), "auto".to_owned(), String::new());
    for (key, value) in params(parts.params, UriError::VlessPercent)? {
        let slot = match key {
            "sni" => &mut sni,
            "pbk" => &mut public_key,
            "sid" => &mut short_id,
            "flow" => &mut flow,
            "fp" => &mut fingerprint,
            "type" => &mut transport,
            "security" => &mut security,
            "path" => &mut path,
            "mode" => &mut mode,
            "serviceName" => &mut service,
            _ => continue,
        };
        *slot = value;
    }
    let sni = if sni.is_empty() { parts.server } else { &sni };
    let port = port(parts.port, exit);
    let vless = Vless {
        name,
        server: parts.server,
        port: &port,
        uuid: &uuid,
        sni,
        public_key: &public_key,
        short_id: &short_id,
    };
    let reality = security == "reality" || (security.is_empty() && !public_key.is_empty());
    let default_flow = if exit && !reality { "" } else { vless_tcp::FLOW };
    let note = format!("VLESS {transport}: {}:{port} (SNI: {sni})", parts.server);
    let yaml = match transport.as_str() {
        "tcp" => vless_tcp::exit_yaml(&vless, super::or(&flow, default_flow), &fingerprint),
        "xhttp" => vless_xhttp::exit_yaml(&vless, super::or(&path, "/"), &mode),
        "grpc" => vless_grpc::exit_yaml(&vless, super::or(&service, "grpc"), &fingerprint),
        _ => return Err(UriError::UnknownTransport { transport, note }),
    };
    Ok(ExitProxy { yaml, notes: vec![note] })
}

/// `hysteria2://` / `hy2://pass@server:port?params` → exit YAML. Only
/// `insecure=1` disables certificate verification.
pub fn parse_hy2_uri(name: &str, uri: &str) -> Result<ExitProxy, UriError> {
    parse_hy2(name, uri, false)
}

fn parse_hy2(name: &str, uri: &str, exit: bool) -> Result<ExitProxy, UriError> {
    let uri = uri.strip_prefix("hysteria2://").unwrap_or(uri);
    let parts = split(uri.strip_prefix("hy2://").unwrap_or(uri));
    let password = percent_decode(parts.userinfo)
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .ok_or(UriError::Hy2Percent)?;
    let (mut sni, mut insecure, mut obfs_password) = (String::new(), String::new(), String::new());
    for (key, value) in params(parts.params, UriError::Hy2Percent)? {
        match key {
            "sni" => sni = value,
            "insecure" => insecure = value,
            "obfs-password" => obfs_password = value,
            _ => {}
        }
    }
    let port = port(parts.port, exit);
    let yaml = hy2::exit_yaml(&Hy2 {
        name,
        server: parts.server,
        port: &port,
        password: password.trim_end_matches('\n'),
        sni: &sni,
        skip_cert_verify: insecure == "1",
        obfs_password: &obfs_password,
    });
    let mut notes = vec![format!("Hysteria2: {}:{port}", parts.server)];
    if !obfs_password.is_empty() {
        notes.push("Obfs: salamander".to_owned());
    }
    Ok(ExitProxy { yaml, notes })
}

/// First line of `input` (one trailing CR dropped) parsed by its scheme.
pub fn parse_proxy_uri(name: &str, input: &str) -> Result<ExitProxy, UriError> {
    parse_line(name, input, false)
}

fn parse_line(name: &str, input: &str, exit: bool) -> Result<ExitProxy, UriError> {
    let line = input.split('\n').next().unwrap_or_default();
    let line = line.strip_suffix('\r').unwrap_or(line);
    if line.starts_with("vless://") {
        parse_vless(name, line, exit)
    } else if line.starts_with("hysteria2://") || line.starts_with("hy2://") {
        parse_hy2(name, line, exit)
    } else {
        Err(UriError::UnknownScheme)
    }
}

/// A cascade exit link: [`parse_proxy_uri`] after a strict check of every
/// field it renders (the v1 parser above keeps Bash parity and accepts more).
/// The empty path `/` after the authority (`hy2://p@h:443/?sni=s`, as the
/// Hysteria2 URI scheme writes it) is dropped first; the port is rendered in
/// canonical decimal; the VLESS TCP flow defaults only with REALITY.
/// Server — a host name or IP; port — 1–65535; VLESS — a UUID, `security`
/// `reality` or `tls` (the exit always speaks TLS), `flow`/`fp`/`mode` as
/// lower-case words, `pbk` as base64, `sid` as hex, `sni` as a host name,
/// `path`/`serviceName` as URI path characters; Hysteria2 — a password and
/// obfs password without control characters, `sni` as a host name.
pub fn parse_exit_uri(name: &str, input: &str) -> Result<ExitProxy, UriError> {
    let line = input.split('\n').next().unwrap_or_default();
    let line = strip_root_path(line.strip_suffix('\r').unwrap_or(line));
    check_exit_fields(&line)?;
    parse_line(name, &line, true)
}

/// `scheme://authority/?query#fragment` without the empty path `/`; any other
/// path is kept (and then fails the port check).
fn strip_root_path(line: &str) -> std::borrow::Cow<'_, str> {
    let Some((scheme, rest)) = line.split_once("://") else { return line.into() };
    let end = rest.find(['?', '#']).unwrap_or(rest.len());
    match rest[..end].strip_suffix('/') {
        Some(authority) if !authority.contains('/') => format!("{scheme}://{authority}{}", &rest[end..]).into(),
        _ => line.into(),
    }
}

fn chars_in(value: &str, max: usize, allowed: impl Fn(char) -> bool) -> bool {
    value.len() <= max && value.chars().all(allowed)
}

fn host_name(value: &str) -> bool {
    !value.is_empty() && chars_in(value, 253, |c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

fn word(value: &str) -> bool {
    chars_in(value, 32, |c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '-' | '_'))
}

fn check_exit_fields(line: &str) -> Result<(), UriError> {
    let field = |field: &'static str| UriError::Field { field };
    let (rest, vless) = if let Some(rest) = line.strip_prefix("vless://") {
        (rest, true)
    } else if let Some(rest) = line.strip_prefix("hysteria2://").or_else(|| line.strip_prefix("hy2://")) {
        (rest, false)
    } else {
        return Err(UriError::UnknownScheme);
    };
    let parts = split(rest);
    if !(host_name(parts.server) || parts.server.parse::<std::net::Ipv6Addr>().is_ok()) {
        return Err(field("server"));
    }
    let port_ok = !parts.port.is_empty() && parts.port.bytes().all(|b| b.is_ascii_digit())
        && parts.port.parse::<u16>().is_ok_and(|port| port != 0);
    if !port_ok {
        return Err(field("port"));
    }
    let percent = if vless { UriError::VlessPercent } else { UriError::Hy2Percent };
    let userinfo = decode_value(parts.userinfo, &percent)?;
    for (key, value) in params(parts.params, percent)? {
        let checked: Option<(&'static str, bool)> = match (vless, key) {
            (_, "sni") => Some(("sni", value.is_empty() || host_name(&value))),
            (true, "flow") => Some(("flow", word(&value))),
            (true, "security") => Some(("security", matches!(value.as_str(), "reality" | "tls"))),
            (true, "fp") => Some(("fp", word(&value))),
            (true, "mode") => Some(("mode", word(&value))),
            (true, "pbk") => Some(("pbk", chars_in(&value, 64, |c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '+' | '/' | '=')))),
            (true, "sid") => Some(("sid", chars_in(&value, 16, |c| c.is_ascii_hexdigit()))),
            (true, "path" | "serviceName") => Some(("path", chars_in(&value, 256, |c| c.is_ascii_alphanumeric() || "-._~/!$&'()*+,;=:@?%".contains(c)))),
            _ => None,
        };
        if let Some((name, false)) = checked {
            return Err(field(name));
        }
    }
    let user_ok = if vless { crate::validation::vless_uuid_valid(&userinfo) } else { !userinfo.is_empty() };
    if !user_ok {
        return Err(field(if vless { "uuid" } else { "password" }));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_round_trip_preserves_bytes() {
        let raw = "Сервер 🚀 #1 a&b=%".as_bytes();
        assert_eq!(percent_decode(&percent_encode(raw)).unwrap(), raw);
        assert_eq!(percent_decode("%ff%FE").unwrap(), [0xff, 0xfe]);
        assert_eq!(percent_decode("a%2"), None);
        assert_eq!(percent_decode("%Жx"), None);
        assert_eq!(percent_decode("%00"), None);
    }

    #[test]
    fn split_handles_ipv6_last_at_and_missing_port() {
        let parts = split("p@ss@[2001:db8::1]:443?a=1#x@y");
        assert_eq!((parts.userinfo, parts.server, parts.port, parts.params), ("p@ss", "2001:db8::1", "443", "a=1"));
        let parts = split("u@host?x=1");
        assert_eq!((parts.server, parts.port), ("host", ""));
    }

    #[test]
    fn decoded_line_breaks_are_rejected_instead_of_injected_into_yaml() {
        assert_eq!(
            parse_vless_uri("p", "vless://u@h:443?sni=a%0A%20%20%20%20evil:%201"),
            Err(UriError::VlessPercent)
        );
        assert_eq!(parse_hy2_uri("p", "hy2://pw@h:443?sni=%FF"), Err(UriError::Hy2Percent));
    }

    #[test]
    fn unknown_transport_and_scheme_fail() {
        assert_eq!(
            parse_proxy_uri("p", "vless://u@h:1?type=quic\n"),
            Err(UriError::UnknownTransport { transport: "quic".into(), note: "VLESS quic: h:1 (SNI: h)".into() })
        );
        assert_eq!(parse_proxy_uri("p", "https://x\n"), Err(UriError::UnknownScheme));
        assert_eq!(parse_proxy_uri("p", ""), Err(UriError::UnknownScheme));
    }

    #[test]
    fn hysteria_password_percent_encoding_round_trips() {
        let endpoint = Hy2 {
            name: "p", server: "h", port: "443", password: "p @#&%🔑",
            sni: "", skip_cert_verify: true, obfs_password: "",
        };
        let parsed = parse_hy2_uri("p", hy2::uri(&endpoint).trim_end()).unwrap();
        assert!(parsed.yaml.contains("    password: \"p @#&%🔑\"\n"));
        assert_eq!(parse_hy2_uri("p", "hy2://a%ZZ@h:443"), Err(UriError::Hy2Percent));
    }

    #[test]
    fn vless_uuid_is_percent_decoded_and_malformed_userinfo_fails() {
        let parsed = parse_vless_uri("p", "vless://11111111%2D2222@h:443?type=tcp").unwrap();
        assert!(parsed.yaml.contains("    uuid: 11111111-2222\n"), "{}", parsed.yaml);
        for uri in ["vless://u%ZZ@h:443", "vless://u%2@h:443", "vless://u%00@h:443", "vless://u%0A@h:443"] {
            assert_eq!(parse_vless_uri("p", uri), Err(UriError::VlessPercent), "{uri}");
        }
    }

    #[test]
    fn exit_link_accepts_root_path_and_keeps_string_values() {
        let parsed = parse_exit_uri("x", "hy2://p@exit.example:443/?sni=exit.example#f").unwrap();
        assert!(parsed.yaml.contains("    port: 443\n"), "{}", parsed.yaml);
        assert!(parse_exit_uri("x", "hysteria2://p@exit.example:443/").is_ok());
        assert_eq!(parse_exit_uri("x", "hy2://p@exit.example:443/x?sni=s"), Err(UriError::Field { field: "port" }));
        let uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
        let parsed = parse_exit_uri("null", &format!("vless://{uuid}@h.example:443/?security=reality&pbk=k&sid=01")).unwrap();
        assert!(parsed.yaml.starts_with("  - name: \"null\"\n"), "{}", parsed.yaml);
        assert!(parsed.yaml.contains("    port: 443\n"), "{}", parsed.yaml);
        assert!(parsed.yaml.contains("      short-id: \"01\"\n"), "{}", parsed.yaml);
    }

    #[test]
    fn exit_link_requires_tls_or_reality_security() {
        let uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
        for security in ["none", "", "xtls"] {
            let link = format!("vless://{uuid}@h.example:443?security={security}&type=tcp");
            assert_eq!(parse_exit_uri("x", &link), Err(UriError::Field { field: "security" }), "{security}");
        }
        for security in ["reality", "tls"] {
            assert!(parse_exit_uri("x", &format!("vless://{uuid}@h.example:443?security={security}")).is_ok());
        }
    }

    #[test]
    fn exit_link_ports_are_canonical_decimal() {
        let uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
        let parsed = parse_exit_uri("x", &format!("vless://{uuid}@h.example:00443?security=reality&pbk=k")).unwrap();
        assert!(parsed.yaml.contains("    port: 443\n") && parsed.notes[0].contains("h.example:443 "), "{parsed:?}");
        let parsed = parse_exit_uri("x", "hy2://p@h.example:00443/?sni=h.example").unwrap();
        assert!(parsed.yaml.contains("    port: 443\n"), "{}", parsed.yaml);
        // The v1 parser keeps Bash parity.
        assert!(parse_hy2_uri("x", "hy2://p@h:00443").unwrap().yaml.contains("    port: 00443\n"));
    }

    #[test]
    fn exit_link_tcp_flow_defaults_only_with_reality() {
        let uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
        let yaml = |query: &str| parse_exit_uri("x", &format!("vless://{uuid}@h.example:443/?{query}")).unwrap().yaml;
        assert!(!yaml("security=tls&type=tcp").contains("    flow:"));
        assert!(yaml("security=tls&type=tcp&flow=xtls-rprx-vision").contains("    flow: xtls-rprx-vision\n"));
        assert!(yaml("security=reality&pbk=k&type=tcp").contains("    flow: xtls-rprx-vision\n"));
        assert!(yaml("pbk=k").contains("    flow: xtls-rprx-vision\n"));
        assert!(parse_vless_uri("x", "vless://u@h:443?security=tls&type=tcp").unwrap().yaml.contains("    flow: xtls-rprx-vision\n"));
    }
}
