//! Subscription hosting (port of `subscription.sh` and the `sub` handlers of
//! `cmd_clients.sh`): a host node serves each client's generated config at
//! `<base_url>/sub/<token>` through a per-token nginx snippet. Tokens are 64
//! lowercase hex; they reach remote commands only through stdin, never argv
//! or diagnostics. Every state change goes through `Session::mutate`; every
//! remote effect goes through `RemoteTransport`.

mod commands;
mod remote;
#[cfg(test)]
mod tests;

use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::cli::Invocation;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::model::{Client, Config, SubscriptionHeader};
use crate::request_secrets::Secrets;
use crate::transport::RemoteTransport;
use crate::validation::subscription_token_valid;

/// Dispatch of `subscription *`; `connect` creates a fresh transport per node.
pub async fn route<T: RemoteTransport>(noun: &str, verb: &str, invocation: &Invocation, secrets: &Secrets,
    session: &mut Session, connect: &dyn Fn() -> T) -> Result<Value>
{
    let _ = (noun, secrets);
    match verb {
        "host" => commands::host(session, invocation, connect).await,
        "list" => commands::list(session),
        "show" => commands::show(session, invocation),
        "headers" => commands::headers(session, invocation),
        "publish" => commands::publish(session, invocation, connect).await,
        "publish-all" => commands::publish_all(session, invocation, connect).await,
        "rotate" => commands::rotate(session, invocation, connect).await,
        "revoke" => commands::revoke(session, invocation, connect).await,
        "migrate" => commands::migrate(session, invocation, connect).await,
        _ => Err(RcError::new("usage", "Неизвестная команда subscription.")),
    }
}

/// v1 `_resolve_headers`: defaults (the built-in pair while the config has no
/// `subscription_default_headers`) → group → client; a later source wins by
/// name; the result is sorted by name.
pub fn effective_headers(config: &Config, client: &Client) -> Vec<SubscriptionHeader> {
    annotated_headers(config, client).into_iter().map(|(header, _)| header).collect()
}

/// Republish a client's subscription with its current TTL (v1
/// `subscription_publish CLIENT ""`): `{client, url, expires_at}`; a failed HTTP
/// check after saving is `partial` with the same fields.
pub async fn publish<T: RemoteTransport>(session: &mut Session, client: &str, connect: &dyn Fn() -> T) -> Result<Value> {
    commands::publish_client(session, client, None, connect).await
}

/// v1 `_subscription_revoke_silent`: remove the client's link from the host,
/// then drop its token and dates (headers stay). Without a token nothing
/// happens; a remote failure leaves the local data unchanged.
pub async fn revoke_quiet<T: RemoteTransport>(session: &mut Session, client: &str, connect: &dyn Fn() -> T) -> Result<()> {
    commands::revoke_client(session, client, connect).await
}

// ─── Shared rules ────────────────────────────────────────────────────────────

const NOT_SET: &str = "Хост-нода подписок не задана: subscription host --name NAME.";

fn default_headers() -> Vec<SubscriptionHeader> {
    vec![
        SubscriptionHeader { name: "Content-Disposition".into(), value: "attachment; filename=\"config.yaml\"".into() },
        SubscriptionHeader { name: "profile-update-interval".into(), value: "24".into() },
    ]
}

/// Defaults of the configuration or the built-in pair (never written back).
fn defaults(config: &Config) -> Vec<SubscriptionHeader> {
    config.subscription_default_headers.clone().unwrap_or_else(default_headers)
}

/// Effective headers with their source (`default`, `group`, `client`).
fn annotated_headers(config: &Config, client: &Client) -> Vec<(SubscriptionHeader, &'static str)> {
    let group = config.groups.iter().find(|group| group.name == client.group)
        .and_then(|group| group.subscription_headers.clone()).unwrap_or_default();
    let own = client.subscription.as_ref().and_then(|s| s.headers.clone()).unwrap_or_default();
    let mut merged: BTreeMap<String, (String, &'static str)> = BTreeMap::new();
    for (headers, source) in [(defaults(config), "default"), (group, "group"), (own, "client")] {
        for header in headers {
            merged.insert(header.name, (header.value, source));
        }
    }
    merged.into_iter().map(|(name, (value, source))| (SubscriptionHeader { name, value }, source)).collect()
}

fn header_name_valid(name: &str) -> bool {
    !name.is_empty() && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// v1 `_sub_header_validate`: the name goes into nginx unquoted; the value
/// has no line breaks and no trailing backslash. nginx 1.24 expands `$var`
/// inside quoted values and `\$` does not escape it, so values containing `$`
/// are rejected outright (user-approved fallback) — on setting and on
/// publishing anything previously stored.
fn validate_header(name: &str, value: &str) -> Result<()> {
    if !header_name_valid(name) {
        return Err(RcError::new("invalid", "Некорректное имя заголовка: допустимы латинские буквы, цифры и дефис."));
    }
    if value.contains(['\r', '\n']) {
        return Err(RcError::new("invalid", "Значение не может содержать переводы строк."));
    }
    if value.ends_with('\\') {
        return Err(RcError::new("invalid", "Значение не может оканчиваться на \\."));
    }
    if value.contains('$') {
        return Err(RcError::new("invalid", "Значение не может содержать «$»: nginx подставляет переменные даже в кавычках."));
    }
    Ok(())
}

/// The configuration may come from GitHub: headers are re-checked before
/// anything is rendered or uploaded.
fn check_headers(config: &Config, client: &Client) -> Result<Vec<SubscriptionHeader>> {
    let headers = effective_headers(config, client);
    if headers.iter().any(|header| validate_header(&header.name, &header.value).is_err()) {
        return Err(RcError::new("invalid", format!(
            "Недопустимый заголовок подписки в конфигурации клиента «{}» — исправьте его через subscription headers.",
            client.name)).with_extra("name", client.name.clone()));
    }
    Ok(headers)
}

/// nginx quoted string. Backslashes are always escaped: nginx unescapes `\n`,
/// `\t`, `\\` inside both quote styles.
fn nginx_quote(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\");
    if value.contains('\'') {
        format!("\"{}\"", escaped.replace('"', "\\\""))
    } else {
        format!("'{escaped}'")
    }
}

/// v1 `_render_subscription_snippet`: `location = /sub/<token>` with headers.
fn render_snippet(token: &str, sub_dir: &str, headers: &[SubscriptionHeader]) -> String {
    let mut text = format!(
        "location = /sub/{token} {{\n    alias {sub_dir}/{token}.yaml;\n    default_type application/yaml;\n    \
         add_header Cache-Control \"no-store\" always;\n    add_header X-Content-Type-Options nosniff always;\n");
    for header in headers {
        text.push_str(&format!("    add_header {} {} always;\n", header.name, nginx_quote(&header.value)));
    }
    text.push_str("    limit_req zone=sub burst=5 nodelay;\n}\n");
    text
}

fn find_client<'a>(config: &'a Config, name: &str) -> Result<&'a Client> {
    config.clients.iter().find(|client| client.name == name).ok_or_else(|| {
        RcError::new("not_found", format!("Клиент «{name}» не найден.")).with_extra("name", name)
    })
}

/// The stored token (`None` without a subscription); a damaged token is `invalid`.
fn client_token(client: &Client) -> Result<Option<String>> {
    match client.subscription.as_ref().and_then(|s| s.token.as_deref()).filter(|t| !t.is_empty()) {
        None => Ok(None),
        Some(token) if subscription_token_valid(token) => Ok(Some(token.to_owned())),
        Some(_) => Err(RcError::new("invalid", format!("Токен подписки клиента «{}» в конфигурации повреждён.", client.name))
            .with_extra("name", client.name.clone())),
    }
}

fn new_token() -> String {
    crate::github::random_hex(32)
}

fn no_subscription(name: &str) -> RcError {
    RcError::new("invalid", format!("У клиента «{name}» нет подписки.")).with_extra("name", name)
}

fn link(config: &Config, token: &str) -> Value {
    match config.subscription_host.as_ref().map(|host| host.base_url.as_str()).filter(|url| !url.is_empty()) {
        Some(base) => json!(format!("{base}/sub/{token}")),
        None => Value::Null,
    }
}

fn not_configured() -> RcError {
    RcError::new("not_configured", NOT_SET)
}

fn host_node(config: &Config) -> Result<&str> {
    config.subscription_host.as_ref().map(|host| host.node.as_str()).filter(|node| !node.is_empty())
        .ok_or_else(not_configured)
}

/// Ready generated config of the client (v1 `_subscription_config_ready`).
fn rendered(session: &Session, client: &Client) -> Result<Option<Vec<u8>>> {
    crate::clients::generate::rendered_config(session.state.paths(), client)
}

/// The generated config is missing or blank: `needs_setup` naming `generate`.
fn not_generated(name: &str, prefix: &str) -> RcError {
    RcError::new("needs_setup", format!("{prefix} Сгенерируйте его: generate --client {name}."))
        .with_extra("name", name)
}

// ─── Time ────────────────────────────────────────────────────────────────────

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
}

/// `12h` / `30d` / `2w` → expiry epoch from `now` (count up to six digits).
fn ttl_expiry(ttl: &str, now: i64) -> Option<i64> {
    let (count, unit) = ttl.split_at(ttl.len().checked_sub(1)?);
    let mult = match unit { "h" => 3600, "d" => 86_400, "w" => 604_800, _ => return None };
    if count.is_empty() || count.len() > 6 || count.starts_with('0') || !count.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(now + count.parse::<i64>().ok()? * mult)
}

fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let yoe = year - era * 400;
    let doy = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Unix time → `YYYY-MM-DDTHH:MM:SSZ`.
fn iso(epoch: i64) -> String {
    let (days, secs) = (epoch.div_euclid(86_400), epoch.rem_euclid(86_400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", secs / 3600, secs % 3600 / 60, secs % 60)
}

/// v1 `_sub_iso_to_epoch`: `YYYY-MM-DDTHH:MM:SS` with `Z` or `±HH[:]MM`.
fn parse_iso(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.len() < 20 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' || bytes[13] != b':' || bytes[16] != b':' {
        return None;
    }
    let number = |range: std::ops::Range<usize>| -> Option<i64> {
        let part = text.get(range)?;
        part.bytes().all(|b| b.is_ascii_digit()).then(|| part.parse().ok()).flatten()
    };
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let month_days = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if !(1..=12).contains(&month) || day < 1 || day > month_days[month as usize - 1] || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    let offset = match &text[19..] {
        "Z" => 0,
        zone => {
            let sign = match zone.as_bytes()[0] { b'+' => 1, b'-' => -1, _ => return None };
            let rest = &zone[1..];
            if !rest.is_ascii() { return None; }
            let (h, m) = match rest.len() {
                4 => (&rest[0..2], &rest[2..4]),
                5 if rest.as_bytes()[2] == b':' => (&rest[0..2], &rest[3..5]),
                _ => return None,
            };
            if !h.bytes().chain(m.bytes()).all(|b| b.is_ascii_digit()) { return None; }
            sign * (h.parse::<i64>().ok()? * 3600 + m.parse::<i64>().ok()? * 60)
        }
    };
    Some(days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset)
}
