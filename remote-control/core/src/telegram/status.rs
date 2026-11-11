//! Telegram Proxy status evaluation (v1 `_telegram_proxy_status_result`):
//! the server answers one JSON object; the client adds its own external
//! reachability checks (HTTPS/TLS of the WEB hostname over IPv4 and IPv6,
//! TCP/2398 of the MTProto address) and folds everything into one row
//! code — 0 ok, 3 not installed, 4 degraded. Also the redaction applied to
//! every server-provided text that reaches a result row or the journal.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::time::Duration;

use serde_json::{Map, Value};

const UNCHECKED: &str = "не проверено";
const SERVICE: &[&str] = &["active", "inactive", "failed"];
const PROBE: &[&str] = &["ok", "failed"];

/// IPv6 reachability of the WEB hostname.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Ipv6 {
    Ok,
    Failed,
    /// The hostname has no AAAA record.
    NotPresent,
    /// The hostname has AAAA but this machine has no IPv6 route.
    Unverified,
}

impl Ipv6 {
    fn human(self) -> &'static str {
        match self {
            Self::Ok => "успешно",
            Self::Failed => "ошибка",
            Self::NotPresent => "отсутствует",
            Self::Unverified => UNCHECKED,
        }
    }
}

/// External reachability checks run from the operator's machine.
pub(crate) trait Reach {
    /// `https://<hostname>/` answers without an HTTP error over IPv4 with a
    /// valid certificate, plus the IPv6 verdict.
    async fn https(&self, hostname: &str) -> (bool, Ipv6);
    /// TCP/2398 accepts a connection within five seconds.
    async fn mtproto(&self, address: Ipv4Addr) -> bool;
}

/// Real network checks (v1 used curl, `openssl s_client` and `/dev/tcp`).
pub(crate) struct Network;

async fn https_ok(hostname: &str, local: IpAddr) -> bool {
    let client = reqwest::Client::builder()
        .local_address(local)
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .build();
    let Ok(client) = client else { return false };
    client.get(format!("https://{hostname}/")).send().await
        .is_ok_and(|response| !response.status().is_client_error() && !response.status().is_server_error())
}

impl Reach for Network {
    async fn https(&self, hostname: &str) -> (bool, Ipv6) {
        let ipv4 = https_ok(hostname, IpAddr::V4(Ipv4Addr::UNSPECIFIED)).await;
        let target = tokio::net::lookup_host((hostname, 443)).await
            .ok().and_then(|mut addresses| addresses.find(SocketAddr::is_ipv6));
        let ipv6 = match target {
            None => Ipv6::NotPresent,
            // A UDP connect sends nothing; it fails when no IPv6 route exists.
            Some(address) if UdpSocket::bind((Ipv6Addr::UNSPECIFIED, 0)).and_then(|socket| socket.connect(address)).is_err() => {
                Ipv6::Unverified
            }
            Some(_) if https_ok(hostname, IpAddr::V6(Ipv6Addr::UNSPECIFIED)).await => Ipv6::Ok,
            Some(_) => Ipv6::Failed,
        };
        (ipv4, ipv6)
    }

    async fn mtproto(&self, address: Ipv4Addr) -> bool {
        matches!(tokio::time::timeout(Duration::from_secs(5), tokio::net::TcpStream::connect((address, 2398))).await, Ok(Ok(_)))
    }
}

/// Evaluated status of one node.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Evaluation {
    pub code: u8,
    pub reason: Option<String>,
    pub summary: Vec<String>,
}

fn observation<'a>(json: &'a Map<String, Value>, key: &str, allowed: &[&str]) -> &'a str {
    let value = match json.get(key) {
        Some(Value::String(value)) => value.as_str(),
        Some(Value::Bool(true)) => "true",
        Some(Value::Bool(false)) => "false",
        _ => "",
    };
    if !value.is_empty() && allowed.contains(&value) { value } else { UNCHECKED }
}

fn human(value: &str) -> &'static str {
    match value {
        "active" => "работает",
        "inactive" => "остановлена",
        "failed" | "FAILED" => "ошибка",
        "ok" | "OK" => "успешно",
        "true" => "доступен",
        "false" => "недоступен",
        "current" => "актуален",
        "changed" => "изменился — обновите IP",
        "NOT_PRESENT" => "отсутствует",
        _ => UNCHECKED,
    }
}

fn first_string<'a>(json: &'a Map<String, Value>, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| json.get(*key).and_then(Value::as_str))
}

fn valid_hostname(hostname: &str) -> bool {
    (1..=253).contains(&hostname.len()) && hostname.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
}

/// Exactly one JSON object, nothing else (v1 `_telegram_proxy_status_object`):
/// noisy or malformed output is a failure, never a healthy node.
pub(crate) fn status_object(stdout: &[u8]) -> Option<Map<String, Value>> {
    let mut values = serde_json::Deserializer::from_slice(stdout).into_iter::<Value>();
    let first = values.next()?.ok()?;
    if values.next().is_some() {
        return None;
    }
    match first {
        Value::Object(object) => Some(object),
        _ => None,
    }
}

/// `None` is a protocol error: flags missing or inconsistent with the exit code.
pub(crate) async fn evaluate<R: Reach>(json: &Map<String, Value>, server_rc: u32, reach: &R) -> Option<Evaluation> {
    let flag = |key: &str| json.get(key).and_then(Value::as_bool);
    let (installed, web, mtproto) = (flag("installed")?, flag("web_enabled")?, flag("mtproto_enabled")?);
    let services = [observation(json, "backend", SERVICE), observation(json, "firewall", SERVICE), observation(json, "timer", SERVICE)];
    let mut summary = vec![
        "Состояние на ноде:".to_owned(),
        format!("  Служба MTProxy: {}", human(services[0])),
        format!("  Межсетевой экран: {}", human(services[1])),
        format!("  Автоматическое обновление: {}", human(services[2])),
    ];
    if server_rc == 3 {
        if installed || web || mtproto {
            return None;
        }
        summary.extend(["  Web Proxy: выключен", "  MTProto Proxy: выключен", "Внешняя доступность:",
            "  Web Proxy: не проверено (выключен)", "  MTProto Proxy: не проверено (выключен)"].map(str::to_owned));
        return Some(Evaluation { code: 3, reason: Some("не установлен".into()), summary });
    }
    if server_rc != 0 || !installed || !(web || mtproto) {
        return None;
    }
    let (mut degraded, mut unverified) = (false, false);
    let mut mark = |state: &str| {
        degraded |= matches!(state, "inactive" | "failed");
        unverified |= state == UNCHECKED;
    };
    services.iter().for_each(|state| mark(state));
    let mut external = Vec::new();
    if web {
        let checks = [observation(json, "relay", SERVICE), observation(json, "health", PROBE), observation(json, "readiness", PROBE)];
        summary.push(format!("  Web Proxy: включён; служба: {}; проверка работы: {}; готовность: {}",
            human(checks[0]), human(checks[1]), human(checks[2])));
        checks.iter().for_each(|state| mark(state));
        match first_string(json, &["web_hostname", "hostname"]).filter(|hostname| valid_hostname(hostname)) {
            Some(hostname) => {
                let (ipv4, ipv6) = reach.https(hostname).await;
                degraded |= !ipv4 || ipv6 == Ipv6::Failed;
                unverified |= ipv6 == Ipv6::Unverified;
                let verdict = if ipv4 { "успешно" } else { "недоступен" };
                external.push(format!("  Web Proxy: HTTPS/TLS {verdict}; IPv6: {}", ipv6.human()));
            }
            None => {
                unverified = true;
                external.push(format!("  Web Proxy: HTTPS/TLS {UNCHECKED}; IPv6: {UNCHECKED}"));
            }
        }
    } else {
        summary.push("  Web Proxy: выключен".into());
        external.push("  Web Proxy: не проверено (выключен)".into());
    }
    if mtproto {
        let listener = observation(json, "mtproto_listener", &["true", "false"]);
        let ip_state = match observation(json, "mtproto_ip_state", &["current", "changed", "unknown"]) {
            "unknown" => UNCHECKED,
            state => state,
        };
        summary.push(format!("  MTProto Proxy: включён; приём подключений: {}; IPv4: {}", human(listener), human(ip_state)));
        degraded |= listener == "false" || ip_state == "changed";
        unverified |= listener == UNCHECKED || ip_state == UNCHECKED;
        match first_string(json, &["mtproto_ipv4", "mtproto_ip"]).and_then(|ip| ip.parse::<Ipv4Addr>().ok()) {
            Some(address) => {
                let reachable = reach.mtproto(address).await;
                degraded |= !reachable;
                external.push(format!("  MTProto Proxy: TCP/2398 {}", if reachable { "успешно" } else { "недоступен" }));
            }
            None => {
                unverified = true;
                external.push(format!("  MTProto Proxy: TCP/2398 {UNCHECKED}"));
            }
        }
    } else {
        summary.push("  MTProto Proxy: выключен".into());
        external.push("  MTProto Proxy: не проверено (выключен)".into());
    }
    summary.push("Внешняя доступность:".into());
    summary.extend(external);
    let unchecked = "не проверено: часть проверок не выполнена";
    let (code, reason) = match (degraded, unverified) {
        (true, true) => (4, Some(format!("неисправность на ноде или внешняя недоступность; {unchecked}"))),
        (true, false) => (4, Some("неисправность на ноде или внешняя недоступность".to_owned())),
        (false, true) => (0, Some(unchecked.to_owned())),
        (false, false) => (0, None),
    };
    Some(Evaluation { code, reason, summary })
}

const KEYS: [&str; 9] = ["secret", "tag", "bridge", "query", "header", "credential", "token", "password", "uuid"];

/// `key[:=]value` with optional quotes around the key and the value; the
/// byte range of the value.
fn key_value(lower: &str, start: usize) -> Option<(usize, usize)> {
    let rest = &lower[start..];
    let key = KEYS.iter().find(|key| rest.starts_with(**key))?;
    let bytes = lower.as_bytes();
    let mut at = start + key.len();
    let skip = |at: &mut usize, quote: bool| {
        if quote && bytes.get(*at) == Some(&b'"') { *at += 1; }
        while bytes.get(*at).is_some_and(u8::is_ascii_whitespace) { *at += 1; }
    };
    skip(&mut at, true);
    if !matches!(bytes.get(at), Some(b':' | b'=')) {
        return None;
    }
    at += 1;
    skip(&mut at, false);
    if bytes.get(at) == Some(&b'"') { at += 1; }
    let value = at;
    while bytes.get(at).is_some_and(|b| !(b.is_ascii_whitespace() || matches!(b, b',' | b'}' | b'&' | b'"'))) {
        at += 1;
    }
    (at > value).then_some((value, at))
}

/// v1 `_telegram_proxy_redact`: credential-like `key=value` / `key: value`
/// pairs (query parameters included) and standalone 32–34 hex-digit runs
/// (MTProto secrets and tags) never reach rows or the journal.
pub(crate) fn redact(text: &str) -> String {
    let lower = text.to_ascii_lowercase();
    let mut pairs = String::with_capacity(text.len());
    let mut at = 0;
    while at < text.len() {
        if let Some((value, end)) = key_value(&lower, at) {
            pairs.push_str(&text[at..value]);
            pairs.push_str("[REDACTED]");
            at = end;
            continue;
        }
        let ch = text[at..].chars().next().expect("char boundary");
        pairs.push(ch);
        at += ch.len_utf8();
    }
    let mut out = String::with_capacity(pairs.len());
    let mut run = String::new();
    let flush = |run: &mut String, out: &mut String| {
        if (32..=34).contains(&run.len()) { out.push_str("[REDACTED]"); } else { out.push_str(run); }
        run.clear();
    };
    for ch in pairs.chars() {
        if ch.is_ascii_hexdigit() {
            run.push(ch);
        } else {
            flush(&mut run, &mut out);
            out.push(ch);
        }
    }
    flush(&mut run, &mut out);
    out
}

/// One display line: ANSI sequences and control characters removed, trimmed.
pub(crate) fn plain(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for ch in chars.by_ref() {
                    if ('\u{40}'..='\u{7e}').contains(&ch) { break; }
                }
            }
            continue;
        }
        out.push(ch);
    }
    crate::log::sanitize(&out).trim().to_owned()
}

#[cfg(test)]
pub(crate) mod tests {
    use std::cell::RefCell;

    use serde_json::json;

    use super::*;

    /// Scripted reachability: records every check it was asked for.
    pub(crate) struct FakeReach {
        pub https: (bool, Ipv6),
        pub mtproto: bool,
        pub calls: RefCell<Vec<String>>,
    }

    impl FakeReach {
        pub(crate) fn new(https: (bool, Ipv6), mtproto: bool) -> Self {
            Self { https, mtproto, calls: RefCell::default() }
        }
    }

    impl Reach for FakeReach {
        async fn https(&self, hostname: &str) -> (bool, Ipv6) {
            self.calls.borrow_mut().push(format!("https:{hostname}"));
            self.https
        }
        async fn mtproto(&self, address: Ipv4Addr) -> bool {
            self.calls.borrow_mut().push(format!("mtproto:{address}"));
            self.mtproto
        }
    }

    fn object(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    fn run(json: Value, rc: u32, reach: &FakeReach) -> Option<Evaluation> {
        tokio::runtime::Builder::new_current_thread().build().unwrap().block_on(evaluate(&object(json), rc, reach))
    }

    #[test]
    fn protocol_requires_consistent_boolean_flags() {
        let reach = FakeReach::new((true, Ipv6::Ok), true);
        for invalid in [json!({}), json!({"installed": "true", "web_enabled": false, "mtproto_enabled": false})] {
            assert_eq!(run(invalid, 0, &reach), None);
        }
        assert_eq!(run(json!({"installed": true, "web_enabled": false, "mtproto_enabled": false}), 0, &reach), None);
        assert_eq!(run(json!({"installed": false, "web_enabled": false, "mtproto_enabled": false}), 0, &reach), None);
        assert_eq!(run(json!({"installed": false, "web_enabled": false, "mtproto_enabled": true}), 3, &reach), None);
        let absent = run(json!({"installed": false, "web_enabled": false, "mtproto_enabled": false, "backend": "inactive"}), 3, &reach).unwrap();
        assert_eq!((absent.code, absent.reason.as_deref()), (3, Some("не установлен")));
        assert_eq!(absent.summary[1], "  Служба MTProxy: остановлена");
        assert!(reach.calls.borrow().is_empty(), "absent installation never probes endpoints");
        assert_eq!(status_object(b"{\"a\":1}\n{\"b\":2}"), None);
        assert_eq!(status_object(b"noise {\"a\":1}"), None);
        assert_eq!(status_object(b"[1]"), None);
        assert_eq!(status_object(b" {\"a\":1}\n"), Some(object(json!({"a": 1}))));
    }

    #[test]
    fn degraded_unverified_and_healthy_verdicts() {
        let healthy = json!({"installed": true, "web_enabled": true, "mtproto_enabled": true, "backend": "active",
            "firewall": "active", "timer": "active", "relay": "active", "health": "ok", "readiness": "ok",
            "web_hostname": "web.example.com", "mtproto_ipv4": "203.0.113.4", "mtproto_listener": true, "mtproto_ip_state": "current"});
        let reach = FakeReach::new((true, Ipv6::NotPresent), true);
        let ok = run(healthy.clone(), 0, &reach).unwrap();
        assert_eq!((ok.code, ok.reason), (0, None));
        assert_eq!(*reach.calls.borrow(), ["https:web.example.com", "mtproto:203.0.113.4"]);
        assert_eq!(ok.summary, [
            "Состояние на ноде:", "  Служба MTProxy: работает", "  Межсетевой экран: работает", "  Автоматическое обновление: работает",
            "  Web Proxy: включён; служба: работает; проверка работы: успешно; готовность: успешно",
            "  MTProto Proxy: включён; приём подключений: доступен; IPv4: актуален",
            "Внешняя доступность:", "  Web Proxy: HTTPS/TLS успешно; IPv6: отсутствует", "  MTProto Proxy: TCP/2398 успешно",
        ]);
        let mut stopped = healthy.clone();
        stopped["backend"] = json!("inactive");
        assert_eq!(run(stopped, 0, &reach).unwrap().code, 4);
        let failed_v6 = run(healthy.clone(), 0, &FakeReach::new((true, Ipv6::Failed), true)).unwrap();
        assert_eq!(failed_v6.code, 4);
        let unverified = run(healthy.clone(), 0, &FakeReach::new((true, Ipv6::Unverified), true)).unwrap();
        assert_eq!((unverified.code, unverified.reason.as_deref()), (0, Some("не проверено: часть проверок не выполнена")));
        let mut changed = healthy;
        changed["mtproto_ip_state"] = json!("changed");
        changed["timer"] = json!("bogus");
        let both = run(changed, 0, &reach).unwrap();
        assert_eq!(both.code, 4);
        assert_eq!(both.reason.as_deref(), Some("неисправность на ноде или внешняя недоступность; не проверено: часть проверок не выполнена"));
        let web_only = run(json!({"installed": true, "web_enabled": true, "mtproto_enabled": false, "backend": "inactive",
            "firewall": "active", "timer": "active", "relay": "active", "health": "ok", "readiness": "ok", "web_hostname": "web.example.com"}),
            0, &FakeReach::new((true, Ipv6::Ok), false)).unwrap();
        assert_eq!(web_only.code, 4, "an inactive backend degrades WEB-only installs too");
    }

    #[test]
    fn redaction_and_plain_lines() {
        let secret = "0123456789abcdef0123456789abcdef";
        assert_eq!(redact(&format!("secret={secret} ok")), "secret=[REDACTED] ok");
        assert_eq!(redact(&format!("tg://proxy?server=a&port=2398&secret=ee{secret}&x=1")), "tg://proxy?server=a&port=2398&secret=[REDACTED]&x=1");
        assert_eq!(redact("\"password\": \"hunter2\", user"), "\"password\": \"[REDACTED]\", user");
        assert_eq!(redact(&format!("raw {secret}.")), "raw [REDACTED].");
        assert_eq!(redact("Token: abc,def"), "Token: [REDACTED],def");
        assert_eq!(redact("короткий deadbeef и 1.2.3"), "короткий deadbeef и 1.2.3");
        assert_eq!(plain("  \u{1b}[1;31m[✗] Ошибка\u{1b}[0m\r"), "[✗] Ошибка");
    }
}
