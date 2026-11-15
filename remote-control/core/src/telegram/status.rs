//! Telegram Web Proxy status: one read-only probe on the node (`key=value`
//! lines: units, readiness, certificate date) plus the operator-side HTTPS
//! check of the hostname over IPv4 and IPv6, folded into one row code —
//! 0 ok, 3 not installed, 4 degraded. Also the redaction applied to every
//! server-provided text that reaches a result row or the journal.

use std::collections::BTreeMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::time::Duration;

use crate::nodes::sh_quote;

const UNCHECKED: &str = "не проверено";

/// Units of the role, in probe order, with their Russian labels.
const UNITS: [(&str, &str); 4] = [
    ("mtproxy", "Служба MTProxy"),
    ("tproxy-server", "Web Proxy (tproxy-server)"),
    ("tproxy-firewall", "Межсетевой экран"),
    ("refresh-mtproxy-config.timer", "Автоматическое обновление"),
];

/// IPv6 reachability of the hostname.
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
}

/// Real network checks.
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
}

/// One read-only command: whether the role is installed, the state of each
/// unit, relay readiness and the certificate expiry of `hostname`.
pub(crate) fn probe_command(hostname: &str) -> String {
    let mut command = String::from("[ -f /etc/systemd/system/tproxy-server.service ] && echo installed=yes || echo installed=no\n");
    for (unit, _) in UNITS {
        command.push_str(&format!("printf '{unit}=%s\\n' \"$(systemctl is-active {unit} 2>/dev/null)\"\n"));
    }
    command.push_str("curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:8081/readyz 2>/dev/null && echo readiness=ok || echo readiness=failed\n");
    command.push_str(&format!("printf 'certificate=%s\\n' \"$(openssl x509 -enddate -noout -in {} 2>/dev/null | cut -d= -f2)\"\ntrue",
        sh_quote(&format!("/etc/nginx/ssl/{hostname}/fullchain.pem"))));
    command
}

/// `key=value` lines of the probe.
pub(crate) fn parse_probe(stdout: &[u8]) -> BTreeMap<String, String> {
    String::from_utf8_lossy(stdout).lines()
        .filter_map(|line| line.trim_end_matches('\r').split_once('='))
        .map(|(key, value)| (key.to_owned(), value.to_owned())).collect()
}

/// Evaluated status of one node.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Evaluation {
    pub code: u8,
    pub reason: Option<String>,
    pub summary: Vec<String>,
}

fn unit_human(state: &str) -> &'static str {
    match state {
        "active" => "работает",
        "inactive" => "остановлена",
        "failed" => "ошибка",
        "activating" | "reloading" => "запускается",
        _ => UNCHECKED,
    }
}

/// Fold the probe and the external check of `hostname` into a row.
pub(crate) async fn evaluate<R: Reach>(probe: &BTreeMap<String, String>, hostname: &str, reach: &R) -> Evaluation {
    let value = |key: &str| probe.get(key).map(String::as_str).unwrap_or_default();
    if value("installed") == "no" {
        return Evaluation { code: 3, reason: Some("не установлен: выполните node apply".into()),
            summary: vec!["Состояние на ноде: Web Proxy не установлен.".into()] };
    }
    let (mut degraded, mut unverified) = (value("installed") != "yes", false);
    let mut summary = vec!["Состояние на ноде:".to_owned()];
    for (unit, label) in UNITS {
        let state = value(unit);
        degraded |= matches!(state, "inactive" | "failed");
        unverified |= unit_human(state) == UNCHECKED;
        summary.push(format!("  {label}: {}", unit_human(state)));
    }
    let ready = value("readiness") == "ok";
    degraded |= !ready;
    summary.push(format!("  Готовность Web Proxy: {}", if ready { "успешно" } else { "ошибка" }));
    let certificate = value("certificate");
    summary.push(format!("  Сертификат {hostname}: {}", if certificate.is_empty() { "не найден" } else { certificate }));
    degraded |= certificate.is_empty();
    let (ipv4, ipv6) = reach.https(hostname).await;
    degraded |= !ipv4 || ipv6 == Ipv6::Failed;
    unverified |= ipv6 == Ipv6::Unverified;
    summary.push("Внешняя доступность:".into());
    summary.push(format!("  HTTPS/TLS {hostname}: {}; IPv6: {}", if ipv4 { "успешно" } else { "недоступен" }, ipv6.human()));
    let unchecked = "не проверено: часть проверок не выполнена";
    let (code, reason) = match (degraded, unverified) {
        (true, true) => (4, Some(format!("неисправность на ноде или внешняя недоступность; {unchecked}"))),
        (true, false) => (4, Some("неисправность на ноде или внешняя недоступность".to_owned())),
        (false, true) => (0, Some(unchecked.to_owned())),
        (false, false) => (0, None),
    };
    Evaluation { code, reason, summary }
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

    use super::*;

    /// Scripted reachability: records every check it was asked for.
    pub(crate) struct FakeReach {
        pub https: (bool, Ipv6),
        pub calls: RefCell<Vec<String>>,
    }

    impl FakeReach {
        pub(crate) fn new(https: (bool, Ipv6)) -> Self {
            Self { https, calls: RefCell::default() }
        }
    }

    impl Reach for FakeReach {
        async fn https(&self, hostname: &str) -> (bool, Ipv6) {
            self.calls.borrow_mut().push(format!("https:{hostname}"));
            self.https
        }
    }

    pub(crate) const HEALTHY: &str = "installed=yes\nmtproxy=active\ntproxy-server=active\ntproxy-firewall=active\n\
        refresh-mtproxy-config.timer=active\nreadiness=ok\ncertificate=Feb  1 00:00:00 2027 GMT\n";

    fn run(stdout: &str, reach: &FakeReach) -> Evaluation {
        tokio::runtime::Builder::new_current_thread().build().unwrap()
            .block_on(evaluate(&parse_probe(stdout.as_bytes()), "tg.example.com", reach))
    }

    #[test]
    fn probe_lists_units_readiness_and_certificate() {
        let command = probe_command("tg.example.com");
        for part in ["systemctl is-active mtproxy ", "systemctl is-active refresh-mtproxy-config.timer ",
            "http://127.0.0.1:8081/readyz", "-in '/etc/nginx/ssl/tg.example.com/fullchain.pem'"] {
            assert!(command.contains(part), "{part} in {command}");
        }
        assert!(!command.contains("2398"));
        assert_eq!(parse_probe(b"a=1\r\nnoise\nb=x=y\n"), BTreeMap::from([("a".into(), "1".into()), ("b".into(), "x=y".into())]));
    }

    #[test]
    fn verdicts() {
        let reach = FakeReach::new((true, Ipv6::NotPresent));
        let ok = run(HEALTHY, &reach);
        assert_eq!((ok.code, ok.reason.as_deref()), (0, None));
        assert_eq!(*reach.calls.borrow(), ["https:tg.example.com"]);
        assert_eq!(ok.summary, [
            "Состояние на ноде:", "  Служба MTProxy: работает", "  Web Proxy (tproxy-server): работает",
            "  Межсетевой экран: работает", "  Автоматическое обновление: работает", "  Готовность Web Proxy: успешно",
            "  Сертификат tg.example.com: Feb  1 00:00:00 2027 GMT", "Внешняя доступность:",
            "  HTTPS/TLS tg.example.com: успешно; IPv6: отсутствует",
        ]);
        let absent = run("installed=no\n", &FakeReach::new((true, Ipv6::Ok)));
        assert_eq!(absent.code, 3);
        assert_eq!(run(&HEALTHY.replace("mtproxy=active", "mtproxy=failed"), &reach).code, 4);
        assert_eq!(run(&HEALTHY.replace("readiness=ok", "readiness=failed"), &reach).code, 4);
        assert_eq!(run(HEALTHY, &FakeReach::new((false, Ipv6::Ok))).code, 4);
        assert_eq!(run(HEALTHY, &FakeReach::new((true, Ipv6::Failed))).code, 4);
        let unverified = run(HEALTHY, &FakeReach::new((true, Ipv6::Unverified)));
        assert_eq!((unverified.code, unverified.reason.as_deref()), (0, Some("не проверено: часть проверок не выполнена")));
        let noisy = run(&HEALTHY.replace("tproxy-firewall=active", "tproxy-firewall=bogus"), &reach);
        assert_eq!((noisy.code, noisy.reason.as_deref()), (0, Some("не проверено: часть проверок не выполнена")));
        assert_eq!(run("garbage", &reach).code, 4, "an unreadable probe is never healthy");
    }

    #[test]
    fn redaction_and_plain_lines() {
        let secret = "0123456789abcdef0123456789abcdef";
        assert_eq!(redact(&format!("secret={secret} ok")), "secret=[REDACTED] ok");
        assert_eq!(redact(&format!("tg://webproxy?server=a&port=443&secret={secret}&x=1")), "tg://webproxy?server=a&port=443&secret=[REDACTED]&x=1");
        assert_eq!(redact("\"password\": \"hunter2\", user"), "\"password\": \"[REDACTED]\", user");
        assert_eq!(redact(&format!("raw {secret}.")), "raw [REDACTED].");
        assert_eq!(redact("Token: abc,def"), "Token: [REDACTED],def");
        assert_eq!(redact("короткий deadbeef и 1.2.3"), "короткий deadbeef и 1.2.3");
        assert_eq!(plain("  \u{1b}[1;31m[✗] Ошибка\u{1b}[0m\r"), "[✗] Ошибка");
    }
}
