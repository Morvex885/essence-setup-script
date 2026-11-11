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
    let parts = split(uri.strip_prefix("vless://").unwrap_or(uri));
    let uuid = decode_value(parts.userinfo, &UriError::VlessPercent)?;
    let (mut sni, mut public_key, mut short_id, mut flow) = (String::new(), String::new(), String::new(), String::new());
    let (mut fingerprint, mut transport) = ("chrome".to_owned(), "tcp".to_owned());
    let (mut path, mut mode, mut service) = (String::new(), "auto".to_owned(), String::new());
    for (key, value) in params(parts.params, UriError::VlessPercent)? {
        let slot = match key {
            "sni" => &mut sni,
            "pbk" => &mut public_key,
            "sid" => &mut short_id,
            "flow" => &mut flow,
            "fp" => &mut fingerprint,
            "type" => &mut transport,
            "path" => &mut path,
            "mode" => &mut mode,
            "serviceName" => &mut service,
            _ => continue,
        };
        *slot = value;
    }
    let sni = if sni.is_empty() { parts.server } else { &sni };
    let vless = Vless {
        name,
        server: parts.server,
        port: parts.port,
        uuid: &uuid,
        sni,
        public_key: &public_key,
        short_id: &short_id,
    };
    let note = format!("VLESS {transport}: {}:{} (SNI: {sni})", parts.server, parts.port);
    let yaml = match transport.as_str() {
        "tcp" => vless_tcp::exit_yaml(&vless, super::or(&flow, vless_tcp::FLOW), &fingerprint),
        "xhttp" => vless_xhttp::exit_yaml(&vless, super::or(&path, "/"), &mode),
        "grpc" => vless_grpc::exit_yaml(&vless, super::or(&service, "grpc"), &fingerprint),
        _ => return Err(UriError::UnknownTransport { transport, note }),
    };
    Ok(ExitProxy { yaml, notes: vec![note] })
}

/// `hysteria2://` / `hy2://pass@server:port?params` → exit YAML. Only
/// `insecure=1` disables certificate verification.
pub fn parse_hy2_uri(name: &str, uri: &str) -> Result<ExitProxy, UriError> {
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
    let yaml = hy2::exit_yaml(&Hy2 {
        name,
        server: parts.server,
        port: parts.port,
        password: password.trim_end_matches('\n'),
        sni: &sni,
        skip_cert_verify: insecure == "1",
        obfs_password: &obfs_password,
    });
    let mut notes = vec![format!("Hysteria2: {}:{}", parts.server, parts.port)];
    if !obfs_password.is_empty() {
        notes.push("Obfs: salamander".to_owned());
    }
    Ok(ExitProxy { yaml, notes })
}

/// First line of `input` (one trailing CR dropped) parsed by its scheme.
pub fn parse_proxy_uri(name: &str, input: &str) -> Result<ExitProxy, UriError> {
    let line = input.split('\n').next().unwrap_or_default();
    let line = line.strip_suffix('\r').unwrap_or(line);
    if line.starts_with("vless://") {
        parse_vless_uri(name, line)
    } else if line.starts_with("hysteria2://") || line.starts_with("hy2://") {
        parse_hy2_uri(name, line)
    } else {
        Err(UriError::UnknownScheme)
    }
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
}
