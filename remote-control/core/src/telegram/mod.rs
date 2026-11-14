//! `telegram *`: Telegram Web Proxy as a node role (port of
//! `setup-essence/modules/telegram-proxy.sh` without the menu and without
//! direct MTProto). `set`, `remove`, `rotate-secret` and `tag` change the
//! configuration and leave the node `pending`; `node apply` renders the role
//! (`server::render`) and the executor builds and starts it
//! (`node-agent/steps/telegram.sh`). `link` reads the stored secret.
//! `status`, `restart` and `diagnostics` talk to the nodes.

mod status;

use std::future::{Future, poll_fn};
use std::pin::Pin;
use std::task::Poll;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::Semaphore;
use zeroize::Zeroizing;

use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::model::{Config, Node, TelegramProxy};
use crate::nodes::{self, COMMAND_TIMEOUT, required, require_portable};
use crate::request_secrets::Secrets;
use crate::state::State;
use crate::transport::RemoteTransport;
use crate::validation::{domain_valid, telegram_hex_valid};

use status::{Network, Reach, evaluate, parse_probe, plain, probe_command, redact};

/// Upstream relay repository and its pinned revision: both go to the node
/// (`TG_REPO`, `TG_REVISION` in the executor spec) and into the node digest.
pub const TPROXY_REPO: &str = "https://github.com/telegramdesktop/tproxy-server.git";
pub const TPROXY_REVISION: &str = "f7a6acc4d536a787d442fd7df3ba4ebfd728f406";
/// Go used to build the relay when the node has no Go 1.20+
/// (`_telegram_proxy_install_pinned_go`).
pub const GO_VERSION: &str = "1.26.5";
pub const GO_SHA256: &str = "5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053";

/// Nodes probed at the same time by `telegram status`.
const PARALLEL: usize = 4;
const RESTART_COMMAND: &str = "systemctl restart mtproxy.service tproxy-server.service";
const RESTART_TIMEOUT: Duration = Duration::from_secs(120);
/// `telegram_proxy_diagnostics`: service journals of the last 30 minutes and
/// the relay metrics.
const DIAGNOSTICS_COMMAND: &str = "echo '-- Журнал службы MTProxy --'\n\
journalctl -u mtproxy.service -u tproxy-firewall.service -u refresh-mtproxy-config.timer --since '30 minutes ago' --no-pager 2>/dev/null | tail -n 200\n\
echo '-- Метрики Web Proxy --'\n\
curl --fail --silent --max-time 5 http://127.0.0.1:8081/metrics 2>/dev/null | tail -n 200\n\
echo '-- Журнал Web Proxy --'\n\
journalctl -u tproxy-server.service --since '30 minutes ago' --no-pager 2>/dev/null | tail -n 200\n\
true";

pub async fn route<T: RemoteTransport>(noun: &str, verb: &str, invocation: &Invocation, secrets: &Secrets,
    session: &mut Session, connect: &dyn Fn() -> T) -> Result<Value>
{
    let _ = noun;
    match verb {
        "status" => status(session, invocation, connect, &Network).await,
        "set" => set(session, invocation),
        "remove" => remove(session, invocation),
        "link" => link(session, invocation),
        "rotate-secret" => rotate_secret(session, invocation),
        "tag" => tag(session, invocation, secrets),
        "restart" => restart(session, invocation, connect).await,
        "diagnostics" => diagnostics(session, invocation, connect).await,
        _ => Err(RcError::new("usage", "Неизвестная команда.")),
    }
}

/// Secret ids of a node's role.
fn secret_id(node: &Node) -> String { format!("node:{}:telegram-secret", node.id) }
fn tag_id(node: &Node) -> String { format!("node:{}:telegram-tag", node.id) }

fn not_enabled(name: &str) -> RcError {
    RcError::new("not_found", format!("Telegram Proxy на ноде «{name}» не включён: telegram set --name {name} --domain D."))
        .with_extra("name", name)
}

/// The node and its role record.
fn role<'a>(config: &'a Config, name: &str) -> Result<(&'a Node, &'a TelegramProxy)> {
    let node = nodes::find(config, name)?;
    let proxy = config.telegram.iter().find(|proxy| proxy.node == node.name).ok_or_else(|| not_enabled(name))?;
    Ok((node, proxy))
}

fn view(proxy: &TelegramProxy) -> Value {
    json!({"node": proxy.node, "hostname": proxy.hostname, "tag": proxy.tag_mark.is_some()})
}

fn apply_hint(session: &mut Session, name: &str) {
    session.log(Level::Info, &format!("Примените изменения: node apply --name {name}"));
}

fn mark() -> Result<String> {
    crate::server::keys::hex(8)
}

/// The stored secret of the role, checked.
fn stored_secret(state: &State, node: &Node) -> Result<Zeroizing<String>> {
    let secret = state.secret_store().get(&secret_id(node))?.ok_or_else(|| RcError::new("missing_secret",
        format!("Секрет Telegram Proxy ноды «{}» не сохранён.", node.name)).with_extra("name", node.name.clone()))?;
    if !telegram_hex_valid(&secret) {
        return Err(RcError::new("invalid", format!("Секрет Telegram Proxy ноды «{}» повреждён: telegram rotate-secret --name {0}.", node.name))
            .with_extra("name", node.name.clone()));
    }
    Ok(secret)
}

// ─── Configuration ──────────────────────────────────────────────────────────

/// The domain fits the node: valid and no other vhost of the node uses it.
fn check_domain(config: &Config, node: &Node, domain: &str) -> Result<()> {
    if node.profile.is_none() {
        return Err(RcError::new("invalid", format!("У ноды «{0}» нет профиля: node profile --name {0} --profile P.", node.name))
            .with_extra("name", node.name.clone()));
    }
    if !domain_valid(domain) {
        return Err(RcError::new("invalid", format!("Некорректный домен «{domain}».")));
    }
    let taken = node.domain.as_deref() == Some(domain)
        || config.subscription_host.as_ref().is_some_and(|host| host.node == node.name && host.hostname == domain)
        || config.telegram.iter().any(|proxy| proxy.node != node.name && proxy.hostname == domain);
    if taken {
        return Err(RcError::new("invalid", format!("Домен «{domain}» уже занят сайтом, хостом подписок или другим Telegram Proxy."))
            .with_extra("name", node.name.clone()));
    }
    Ok(())
}

/// `telegram set --name N --domain D`: enable the role (with a new secret) or
/// change its domain.
fn set(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let domain = required(invocation, "domain")?.to_owned();
    {
        let config = session.state.load_config()?;
        check_domain(&config, nodes::find(&config, &name)?, &domain)?;
    }
    let proxy = session.mutate("telegram set", |state| {
        let mut config = state.load_config()?;
        let node = nodes::find(&config, &name)?.clone();
        check_domain(&config, &node, &domain)?;
        let proxy = match config.telegram.iter_mut().find(|proxy| proxy.node == node.name) {
            Some(proxy) => {
                proxy.hostname = domain.clone();
                proxy.clone()
            }
            None => {
                state.secret_store().set(&secret_id(&node), Zeroizing::new(crate::github::random_hex(16)))?;
                let proxy = TelegramProxy { node: node.name.clone(), hostname: domain.clone(), secret_mark: mark()?, tag_mark: None };
                config.telegram.push(proxy.clone());
                proxy
            }
        };
        state.save_config(&config)?;
        Ok(proxy)
    })?;
    session.log(Level::Success, &format!("Telegram Proxy на ноде «{name}»: {domain}"));
    apply_hint(session, &name);
    Ok(view(&proxy))
}

/// `telegram remove --name N`: drop the role and its secrets.
fn remove(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let hostname = role(&session.state.load_config()?, &name)?.1.hostname.clone();
    Plan::new(vec![
        format!("Telegram Proxy на ноде «{name}» ({hostname}) будет убран; его службы и файлы удалит node apply."),
        "Ссылки подключения перестанут работать.".to_owned(),
    ], "").confirm(invocation)?;
    session.mutate("telegram remove", |state| {
        let mut config = state.load_config()?;
        let node = role(&config, &name)?.0.clone();
        config.telegram.retain(|proxy| proxy.node != node.name);
        state.save_config(&config)?;
        state.secret_store().remove(&secret_id(&node))?;
        state.secret_store().remove(&tag_id(&node))
    })?;
    session.log(Level::Success, &format!("Telegram Proxy на ноде «{name}» убран"));
    apply_hint(session, &name);
    Ok(json!({"node": name}))
}

/// `telegram link --name N`: the Web Proxy link with the secret.
fn link(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?;
    let config = session.state.load_config()?;
    let (node, proxy) = role(&config, name)?;
    let secret = stored_secret(&session.state, node)?;
    Ok(json!({"link": format!("tg://webproxy?server={}&port=443&secret={}", proxy.hostname, secret.as_str())}))
}

/// `telegram rotate-secret --name N`: a new secret; old links stop working.
fn rotate_secret(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    role(&session.state.load_config()?, &name)?;
    Plan::new(vec!["Секрет будет заменён: прежние ссылки перестанут работать.".to_owned()], "").confirm(invocation)?;
    let mark = mark()?;
    session.mutate("telegram rotate-secret", |state| {
        let mut config = state.load_config()?;
        let node = role(&config, &name)?.0.clone();
        state.secret_store().set(&secret_id(&node), Zeroizing::new(crate::github::random_hex(16)))?;
        if let Some(proxy) = config.telegram.iter_mut().find(|proxy| proxy.node == node.name) {
            proxy.secret_mark = mark;
        }
        state.save_config(&config)
    })?;
    session.log(Level::Success, &format!("Секрет Telegram Proxy ноды «{name}» заменён"));
    apply_hint(session, &name);
    Ok(json!({"node": name}))
}

/// `telegram tag --name N [--clear]`: the sponsor tag (secret `password`).
fn tag(session: &mut Session, invocation: &Invocation, secrets: &Secrets) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    role(&session.state.load_config()?, &name)?;
    let clear = invocation.has("clear");
    let tag = if clear {
        None
    } else {
        let tag = secrets.get("password").filter(|tag| !tag.is_empty()).ok_or_else(|| {
            RcError::new("missing_secret", "Не передан спонсорский тег (секрет password).")
                .with_extra("name", name.clone()).with_extra("secret", "password")
        })?;
        if !telegram_hex_valid(tag) {
            return Err(RcError::new("invalid", "Спонсорский тег — 32 шестнадцатеричных символа (выдаёт @MTProxybot)."));
        }
        Some(Zeroizing::new(tag.to_ascii_lowercase()))
    };
    let mark = if clear { None } else { Some(mark()?) };
    session.mutate("telegram tag", |state| {
        let mut config = state.load_config()?;
        let node = role(&config, &name)?.0.clone();
        match tag {
            Some(tag) => state.secret_store().set(&tag_id(&node), tag)?,
            None => state.secret_store().remove(&tag_id(&node))?,
        }
        if let Some(proxy) = config.telegram.iter_mut().find(|proxy| proxy.node == node.name) {
            proxy.tag_mark = mark;
        }
        state.save_config(&config)
    })?;
    session.log(Level::Success, &if clear { format!("Спонсорский тег ноды «{name}» убран") } else { format!("Спонсорский тег ноды «{name}» сохранён") });
    apply_hint(session, &name);
    Ok(json!({"node": name, "tag": !clear}))
}

// ─── Remote ─────────────────────────────────────────────────────────────────

/// A connected transport to the node of a role.
async fn open<T: RemoteTransport>(session: &mut Session, name: &str, connect: &dyn Fn() -> T) -> Result<T> {
    let config = session.state.load_config()?;
    let node = role(&config, name)?.0;
    require_portable(session, node)?;
    let mut transport = connect();
    nodes::connect(&mut transport, &session.state, node).await?;
    Ok(transport)
}

/// `telegram restart --name N`.
async fn restart<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let transport = open(session, &name, connect).await?;
    let result = transport.exec(RESTART_COMMAND, b"", RESTART_TIMEOUT).await?;
    if result.exit_status != 0 {
        return Err(RcError::new("remote_failed", format!("Не удалось перезапустить Telegram Proxy на ноде «{name}».")).with_extra("name", name));
    }
    session.log(Level::Success, &format!("Telegram Proxy на ноде «{name}» перезапущен"));
    Ok(json!({"node": name}))
}

/// `telegram diagnostics --name N`: journals and metrics, redacted, to the journal.
async fn diagnostics<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let transport = open(session, &name, connect).await?;
    let result = transport.exec(DIAGNOSTICS_COMMAND, b"", COMMAND_TIMEOUT).await?;
    session.log(Level::Info, &format!("Диагностика Telegram Proxy ноды «{name}»"));
    for line in String::from_utf8_lossy(&result.stdout).lines() {
        let line = redact(&plain(line));
        if !line.is_empty() {
            session.log(Level::Output, &line);
        }
    }
    Ok(json!({"node": name}))
}

/// Await every future on the current task, concurrently (futures here are
/// not `Send`: they borrow the session state and the transports).
async fn join_all<F: Future>(futures: Vec<F>) -> Vec<F::Output> {
    let mut pending: Vec<Pin<Box<F>>> = futures.into_iter().map(Box::pin).collect();
    let mut outputs: Vec<Option<F::Output>> = pending.iter().map(|_| None).collect();
    poll_fn(|cx| {
        let mut done = true;
        for (future, output) in pending.iter_mut().zip(outputs.iter_mut()) {
            if output.is_none() {
                match future.as_mut().poll(cx) {
                    Poll::Ready(value) => *output = Some(value),
                    Poll::Pending => done = false,
                }
            }
        }
        if done { Poll::Ready(()) } else { Poll::Pending }
    }).await;
    outputs.into_iter().map(|output| output.expect("every joined future completed")).collect()
}

/// One result row of `telegram status`.
struct Outcome {
    code: u8,
    reason: Option<String>,
    summary: Vec<String>,
}

impl Outcome {
    fn error(reason: impl Into<String>) -> Self {
        Self { code: 1, reason: Some(reason.into()), summary: Vec::new() }
    }

    fn status(&self) -> &'static str {
        match self.code {
            0 => "ok",
            3 => "not_installed",
            4 => "partial",
            _ => "error",
        }
    }
}

/// Selected roles from one config snapshot: `--name N…` (deduplicated, in
/// order), otherwise every node with the role.
fn select(config: &Config, invocation: &Invocation) -> Result<Vec<(Node, String)>> {
    if invocation.has("all") && invocation.has("name") {
        return Err(RcError::new("usage", "Укажите --name или --all, но не оба."));
    }
    let mut selected: Vec<(Node, String)> = Vec::new();
    if invocation.has("name") {
        for name in invocation.values("name") {
            if name.is_empty() {
                return Err(RcError::new("usage", "Укажите --name."));
            }
            let (node, proxy) = role(config, name)?;
            if !selected.iter().any(|(known, _)| known.name == node.name) {
                selected.push((node.clone(), proxy.hostname.clone()));
            }
        }
    } else {
        for proxy in &config.telegram {
            selected.push((nodes::find(config, &proxy.node)?.clone(), proxy.hostname.clone()));
        }
    }
    if selected.is_empty() {
        return Err(RcError::new("invalid", "Telegram Proxy не включён ни на одной ноде."));
    }
    Ok(selected)
}

async fn probe_one<T: RemoteTransport, R: Reach>(state: &State, node: &Node, hostname: &str, start: std::result::Result<T, String>,
    reach: &R, gate: &Semaphore) -> Outcome
{
    let mut transport = match start {
        Ok(transport) => transport,
        Err(reason) => return Outcome::error(reason),
    };
    let _permit = gate.acquire().await.ok();
    if let Err(error) = nodes::connect_retrying(&mut transport, state, node).await {
        return Outcome::error(error.message);
    }
    match transport.exec(&probe_command(hostname), b"", COMMAND_TIMEOUT).await {
        Ok(result) if result.exit_status == 0 => {
            let evaluation = evaluate(&parse_probe(&result.stdout), hostname, reach).await;
            Outcome { code: evaluation.code, reason: evaluation.reason, summary: evaluation.summary.iter().map(|line| redact(line)).collect() }
        }
        Ok(_) => Outcome::error("не удалось прочитать состояние Telegram Proxy"),
        Err(error) => Outcome::error(error.message),
    }
}

/// `telegram status [--name N… | --all]`.
async fn status<T: RemoteTransport, R: Reach>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T, reach: &R)
    -> Result<Value>
{
    let selected = select(&session.state.load_config()?, invocation)?;
    // Portability is decided before any transport exists for the node.
    let starts: Vec<std::result::Result<T, String>> = selected.iter().map(|(node, _)| match require_portable(session, node) {
        Ok(()) => Ok(connect()),
        Err(error) => Err(error.message),
    }).collect();
    let gate = Semaphore::new(PARALLEL);
    let outcomes = {
        let state = &session.state;
        join_all(selected.iter().zip(starts).map(|((node, hostname), start)| probe_one(state, node, hostname, start, reach, &gate))
            .collect()).await
    };
    session.log(Level::Info, "Результаты Telegram Proxy:");
    for ((node, hostname), outcome) in selected.iter().zip(&outcomes) {
        let title = format!("Telegram Proxy {} ({hostname})", node.name);
        let reason = outcome.reason.as_deref().unwrap_or_default();
        match outcome.code {
            0 if reason.is_empty() => session.log(Level::Success, &format!("{title}: успешно")),
            0 => session.log(Level::Warn, &format!("{title}: успешно ({reason})")),
            3 => session.log(Level::Info, &format!("{title}: {reason}")),
            4 => session.log(Level::Warn, &format!("{title}: частично — {reason}")),
            _ => session.log(Level::Warn, &format!("{title}: ошибка — {reason}")),
        }
        for line in &outcome.summary {
            session.log(Level::Output, &format!("    {line}"));
        }
    }
    let rows: Vec<Value> = selected.iter().zip(&outcomes).map(|((node, hostname), outcome)| json!({
        "node": node.name, "hostname": hostname, "code": outcome.code, "status": outcome.status(),
        "reason": outcome.reason, "summary": outcome.summary,
    })).collect();
    // Any error row → 1; else any partial → 4; else any not_installed → 3; else 0.
    let has = |code: u8| outcomes.iter().any(|outcome| outcome.code == code);
    if outcomes.iter().any(|outcome| !matches!(outcome.code, 0 | 3 | 4)) {
        Err(RcError::new("remote_failed", "Проверка Telegram Proxy завершилась ошибкой.").with_extra("results", rows))
    } else if has(4) {
        Err(RcError::new("partial", "Telegram Proxy работает не полностью.").with_extra("results", rows).with_exit(4))
    } else if has(3) {
        Err(RcError::new("not_installed", "Telegram Proxy не установлен на части нод: выполните node apply.")
            .with_extra("results", rows).with_exit(3))
    } else {
        Ok(json!({"results": rows}))
    }
}

#[cfg(test)]
mod tests;
