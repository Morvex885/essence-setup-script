//! `telegram *`: Telegram Proxy on many nodes (port of the remote-control
//! `telegram-proxy.sh` lifecycle and the `telegram` handlers of
//! `cmd_nodes.sh`).
//!
//! A batch is three phases. Preflight reads everything first: the selection
//! and every node's SSH parameters, secret and host pins come from one config
//! snapshot; each node gets its own transport from `connect()` and its server
//! scripts are probed (read-only, concurrently). Then one plan gate covers
//! every node, including script uploads; the SHA-256 of the embedded server
//! bundle and its VERSION are part of the token. Finally workers act on the
//! frozen preflight (the already authenticated transports), concurrently; a
//! node that failed preflight becomes an error row while the others proceed.
//! `status` is read-only: no plan and no uploads.

mod status;

use std::future::{Future, poll_fn};
use std::path::Path;
use std::pin::Pin;
use std::task::Poll;
use std::time::Duration;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::Semaphore;

use crate::bundle::ServerBundle;
use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::model::Node;
use crate::nodes::{self, find, not_found, required, require_portable, scripts, sh_quote};
use crate::nodes::scripts::{ScriptsState, Version};
use crate::request_secrets::Secrets;
use crate::state::State;
use crate::terminal::TerminalJob;
use crate::transport::{ExecResult, RemoteTransport};

use status::{Network, Reach, evaluate, plain, redact, status_object};

/// Nodes handled at the same time (v1 ran four worker slots).
const PARALLEL: usize = 4;

/// Dispatch of the domain's commands; `connect` creates a fresh transport per node.
pub async fn route<T: RemoteTransport>(noun: &str, verb: &str, invocation: &Invocation, _secrets: &Secrets,
    session: &mut Session, connect: &dyn Fn() -> T) -> Result<Value>
{
    match (noun, verb) {
        ("telegram", verb) => batch(session, invocation, verb, connect, &Network).await,
        _ => Err(RcError::new("usage", "Неизвестная команда.")),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    Status,
    Install,
    RefreshIp,
    WebUpdate,
    WebRestart,
    BackendRestart,
    RemoveWeb,
    RemoveMtproto,
    RemoveAll,
}

impl Action {
    fn parse(verb: &str, invocation: &Invocation) -> Result<Self> {
        let action = match verb {
            "status" => Self::Status,
            "install" => Self::Install,
            "refresh-ip" => Self::RefreshIp,
            "web-update" => Self::WebUpdate,
            "web-restart" => Self::WebRestart,
            "backend-restart" => Self::BackendRestart,
            "remove-all" => Self::RemoveAll,
            "remove" => return match required(invocation, "component")? {
                "web" => Ok(Self::RemoveWeb),
                "mtproto" => Ok(Self::RemoveMtproto),
                _ => Err(RcError::new("usage", "Флаг --component принимает web или mtproto.")),
            },
            _ => return Err(RcError::new("usage", "Неизвестная команда.")),
        };
        if invocation.has("component") {
            return Err(RcError::new("usage", "Флаг --component используется только с telegram remove."));
        }
        Ok(action)
    }

    /// `setup-essence.sh telegram-proxy …` arguments. Destructive actions
    /// carry `--force`: consent is the plan, the server never asks.
    fn arguments(self) -> &'static str {
        match self {
            Self::Status => "status --json",
            Self::Install => "mtproto install --force",
            Self::RefreshIp => "mtproto refresh-ip",
            Self::WebUpdate => "web update",
            Self::WebRestart => "web restart",
            Self::BackendRestart => "backend restart",
            Self::RemoveWeb => "web remove --force",
            Self::RemoveMtproto => "mtproto remove --force",
            Self::RemoveAll => "remove-all --force",
        }
    }

    fn command(self) -> String {
        format!("bash {} telegram-proxy {}", sh_quote(&format!("{}/setup-essence.sh", scripts::REMOTE_DIR)), self.arguments())
    }

    fn timeout(self) -> Duration {
        Duration::from_secs(match self {
            Self::Status => 60,
            Self::RefreshIp | Self::WebRestart | Self::BackendRestart => 120,
            Self::RemoveWeb | Self::RemoveMtproto | Self::RemoveAll => 300,
            Self::WebUpdate | Self::Install => 1200,
        })
    }

    /// Plan heading and its explanation (v1 `_telegram_proxy_remote_plan_lines`).
    fn describe(self) -> (&'static str, &'static str) {
        match self {
            Self::Status => ("Общий статус нод", "Проверка состояния Telegram Proxy."),
            Self::Install => ("Включение MTProto Proxy",
                "В межсетевом экране провайдера разрешите TCP/2398 и запретите TCP/8888. Служба MTProxy устанавливается автоматически."),
            Self::RemoveWeb => ("Отключение Web Proxy",
                "Ссылки этого способа перестанут работать. Служба MTProxy будет удалена, если это последний способ доступа."),
            Self::RemoveMtproto => ("Отключение MTProto Proxy",
                "Ссылки этого способа перестанут работать. Служба MTProxy будет удалена, если это последний способ доступа."),
            Self::RemoveAll => ("Отключение Telegram Proxy",
                "Web Proxy, MTProto Proxy и служба MTProxy будут удалены. Все ссылки перестанут работать."),
            Self::BackendRestart => ("Перезапуск службы MTProxy", "Подключения Web Proxy и MTProto Proxy будут прерваны."),
            Self::WebRestart => ("Перезапуск Web Proxy", "Подключения Web Proxy будут прерваны."),
            Self::WebUpdate => ("Обновление Web Proxy", "Обновление Web Proxy на выбранных нодах."),
            Self::RefreshIp => ("Обновление IP-адреса MTProto Proxy", "Обновление адреса MTProto Proxy на выбранных нодах."),
        }
    }
}

/// Selected nodes from one config snapshot: `--name N…` (deduplicated, in
/// order) or `--all`; `status` without a selector means every node.
fn select(session: &Session, invocation: &Invocation, action: Action) -> Result<Vec<Node>> {
    let config = session.state.load_config()?;
    let names = invocation.values("name");
    if invocation.has("all") && invocation.has("name") {
        return Err(RcError::new("usage", "Укажите --name или --all, но не оба."));
    }
    let nodes = if invocation.has("name") {
        let mut selected: Vec<Node> = Vec::new();
        for name in names {
            if name.is_empty() {
                return Err(RcError::new("usage", "Укажите --name."));
            }
            if !selected.iter().any(|node| &node.name == name) {
                selected.push(find(&config, name)?.clone());
            }
        }
        selected
    } else if invocation.has("all") || action == Action::Status {
        config.nodes
    } else {
        return Err(RcError::new("usage", "Укажите ноды: --name N… или --all."));
    };
    if nodes.is_empty() {
        return Err(RcError::new("invalid", "Нет нод для выполнения."));
    }
    Ok(nodes)
}

/// SHA-256 over the materialized server bundle: one `path sha256` line per
/// file, sorted (v1 `_telegram_proxy_remote_bundle_fingerprint`).
fn bundle_sha256() -> Result<String> {
    fn walk(root: &Path, dir: &Path, lines: &mut Vec<String>) -> Result<()> {
        for entry in std::fs::read_dir(dir)? {
            let path = entry?.path();
            if path.is_dir() {
                walk(root, &path, lines)?;
            } else {
                let relative: Vec<String> = path.strip_prefix(root).unwrap_or(&path).components()
                    .map(|component| component.as_os_str().to_string_lossy().into_owned()).collect();
                lines.push(format!("{} {}", relative.join("/"), hex::encode(Sha256::digest(std::fs::read(&path)?))));
            }
        }
        Ok(())
    }
    let directory = ServerBundle.materialize()?;
    let mut lines = Vec::new();
    walk(directory.path(), directory.path(), &mut lines)?;
    lines.sort();
    let mut hasher = Sha256::new();
    for line in &lines {
        hasher.update(line.as_bytes());
        hasher.update(b"\n");
    }
    Ok(hex::encode(hasher.finalize()))
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

const STALE: &str = "скрипты на ноде отсутствуют или устарели — они загрузятся при установке или другом действии Telegram Proxy";

/// Preflight verdict of one node.
enum Prep {
    Ready,
    /// Scripts missing, older than the embedded kit or damaged: upload after consent.
    Upload,
    Excluded(String),
}

struct Target<T> {
    node: Node,
    prep: Prep,
    /// The authenticated preflight connection, reused by the worker.
    transport: Option<T>,
}

async fn inspect<T: RemoteTransport>(state: &State, node: &Node, start: std::result::Result<T, String>, local: Version,
    gate: &Semaphore) -> (Prep, Option<T>)
{
    let mut transport = match start {
        Ok(transport) => transport,
        Err(reason) => return (Prep::Excluded(reason), None),
    };
    let _permit = gate.acquire().await.ok();
    if let Err(error) = nodes::connect(&mut transport, state, node).await {
        return (Prep::Excluded(error.message), None);
    }
    let prep = match scripts::probe(&transport).await {
        None => Prep::Excluded(format!("не удалось определить состояние скриптов на ноде «{}»", node.name)),
        Some((ScriptsState::Ready, Some(remote))) if local <= remote => Prep::Ready,
        Some(_) => Prep::Upload,
    };
    (prep, Some(transport))
}

/// One result row.
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

fn last_line(bytes: &[u8]) -> Option<String> {
    String::from_utf8_lossy(bytes).lines().rev().map(plain).find(|line| !line.is_empty())
}

/// The server's own explanation of a failure: its last meaningful line.
fn failure(result: &ExecResult) -> Outcome {
    if result.exit_status == 2 {
        return Outcome::error("скрипты на ноде не поддерживают эту команду Telegram Proxy");
    }
    let line = last_line(&result.stderr).or_else(|| last_line(&result.stdout))
        .unwrap_or_else(|| format!("код завершения {}", result.exit_status));
    Outcome::error(redact(&line))
}

fn transport_failure(error: &RcError) -> Outcome {
    match error.extra.get("reason").and_then(Value::as_str) {
        Some(reason) => Outcome::error(format!("{} ({reason})", error.message)),
        None => Outcome::error(error.message.clone()),
    }
}

async fn execute<T: RemoteTransport, R: Reach>(target: &Target<T>, action: Action, reach: &R, gate: &Semaphore) -> Outcome {
    let transport = match (&target.prep, &target.transport) {
        (Prep::Excluded(reason), _) => return Outcome::error(reason.clone()),
        (_, Some(transport)) => transport,
        (_, None) => return Outcome::error("нода недоступна"),
    };
    let _permit = gate.acquire().await.ok();
    if matches!(target.prep, Prep::Upload)
        && let Err(error) = scripts::ensure_current(transport, &target.node.name).await
    {
        return Outcome::error(error.message);
    }
    let result = match transport.exec(&action.command(), b"", action.timeout()).await {
        Ok(result) => result,
        Err(error) => return transport_failure(&error),
    };
    match (action, result.exit_status) {
        (Action::Status, rc @ (0 | 3)) => {
            let evaluation = match status_object(&result.stdout) {
                Some(json) => evaluate(&json, rc, reach).await,
                None => None,
            };
            match evaluation {
                Some(evaluation) => Outcome {
                    code: evaluation.code,
                    reason: evaluation.reason,
                    summary: evaluation.summary.iter().map(|line| redact(line)).collect(),
                },
                None => Outcome::error("Некорректный ответ сервера при запросе статуса Telegram Proxy."),
            }
        }
        (_, 0) => Outcome { code: 0, reason: None, summary: Vec::new() },
        (_, 3) => Outcome { code: 3, reason: Some("не установлен".into()), summary: Vec::new() },
        _ => failure(&result),
    }
}

fn truncated(text: &str) -> String {
    text.chars().take(120).collect()
}

/// `telegram status|install|refresh-ip|web-update|web-restart|backend-restart|remove|remove-all`.
async fn batch<T: RemoteTransport, R: Reach>(session: &mut Session, invocation: &Invocation, verb: &str,
    connect: &dyn Fn() -> T, reach: &R) -> Result<Value>
{
    let action = Action::parse(verb, invocation)?;
    let nodes = select(session, invocation, action)?;
    let local = scripts::local()?;
    let version = scripts::format_version(local);
    let total = nodes.len();
    // Portability is decided before any transport exists for the node.
    let starts: Vec<std::result::Result<T, String>> = nodes.iter().enumerate().map(|(index, node)| {
        session.log(Level::Info, &format!("Проверка ноды ({}/{total}): {}…", index + 1, node.name));
        match require_portable(session, node) {
            Ok(()) => Ok(connect()),
            Err(error) => Err(error.message),
        }
    }).collect();
    let gate = Semaphore::new(PARALLEL);
    let preflight = {
        let state = &session.state;
        join_all(nodes.iter().zip(starts).map(|(node, start)| inspect(state, node, start, local, &gate)).collect()).await
    };
    // The frozen snapshot every worker acts on.
    let targets: Vec<Target<T>> = nodes.into_iter().zip(preflight).map(|(node, (prep, transport))| {
        let prep = match prep {
            Prep::Upload if action == Action::Status => Prep::Excluded(STALE.into()),
            prep => prep,
        };
        Target { node, prep, transport }
    }).collect();
    for target in &targets {
        if let Prep::Excluded(reason) = &target.prep {
            session.log(Level::Warn, &format!("Нода «{}» исключена: {}.", target.node.name, reason.trim_end_matches('.')));
        }
    }
    let eligible = targets.iter().filter(|target| !matches!(target.prep, Prep::Excluded(_))).count();
    if action != Action::Status && eligible > 0 {
        let (label, explanation) = action.describe();
        let mut lines = vec![label.to_owned(), explanation.to_owned()];
        lines.extend(targets.iter().map(|target| {
            let suffix = match &target.prep {
                Prep::Ready => String::new(),
                Prep::Upload => format!(" — будут загружены скрипты v{version}"),
                Prep::Excluded(reason) => format!(" — исключена: {reason}"),
            };
            format!("{}  {}:{}{suffix}", target.node.name, target.node.ip, target.node.port)
        }));
        Plan::new(lines, format!("{} {version}", bundle_sha256()?)).confirm(invocation)?;
    }
    let outcomes = join_all(targets.iter().map(|target| execute(target, action, reach, &gate)).collect()).await;
    report(session, action, &targets, &outcomes);
    let rows: Vec<Value> = targets.iter().zip(&outcomes).map(|(target, outcome)| json!({
        "node": target.node.name, "code": outcome.code, "status": outcome.status(), "reason": outcome.reason,
    })).collect();
    // v1 `telegram_proxy_remote_batch` aggregate, kept as the public contract:
    // any error row → 1; else any partial → 4; else any not_installed → 3; else 0.
    let has = |code: u8| outcomes.iter().any(|outcome| outcome.code == code);
    let error = outcomes.iter().any(|outcome| !matches!(outcome.code, 0 | 3 | 4));
    if error {
        Err(RcError::new("remote_failed", "Действие Telegram Proxy завершилось ошибкой.").with_extra("results", rows))
    } else if has(4) {
        Err(RcError::new("partial", "Действие Telegram Proxy выполнено частично.").with_extra("results", rows).with_exit(4))
    } else if has(3) {
        Err(RcError::new("not_installed", "Компонент Telegram Proxy не установлен на части нод.")
            .with_extra("results", rows).with_exit(3))
    } else {
        Ok(json!({"results": rows}))
    }
}

/// Journal of the batch result (v1 `telegram_proxy_remote_batch` summary and
/// `_telegram_proxy_render_status_panel`).
fn report<T>(session: &mut Session, action: Action, targets: &[Target<T>], outcomes: &[Outcome]) {
    session.log(Level::Info, "Результаты Telegram Proxy:");
    for (target, outcome) in targets.iter().zip(outcomes) {
        let name = &target.node.name;
        let reason = outcome.reason.as_deref().map(truncated);
        if action == Action::Status {
            let title = format!("Telegram Proxy {name} ({})", target.node.ip);
            match (outcome.code, reason) {
                (0, None) => session.log(Level::Success, &format!("{title}: успешно")),
                (0, Some(reason)) => session.log(Level::Warn, &format!("{title}: успешно ({reason})")),
                (3, _) => session.log(Level::Info, &format!("{title}: пропущено — не установлен")),
                (4, reason) => session.log(Level::Warn, &format!("{title}: частично — {}",
                    reason.as_deref().unwrap_or("внешняя доступность не подтверждена"))),
                (_, reason) => session.log(Level::Warn, &format!("{title}: ошибка — {}",
                    reason.as_deref().unwrap_or("не удалось получить статус"))),
            }
            for line in &outcome.summary {
                session.log(Level::Output, &format!("    {line}"));
            }
            continue;
        }
        match (outcome.code, reason) {
            (0, reason) => {
                session.log(Level::Success, &match reason {
                    Some(reason) => format!("{name} — успешно: {reason}"),
                    None => format!("{name} — успешно"),
                });
                if action == Action::Install {
                    session.log(Level::Info, "Ссылки подключения: «Управление одной нодой» → «Показать ссылки подключения».");
                }
            }
            (3, _) => session.log(Level::Info, &format!("{name} — пропущено: не установлен")),
            (4, reason) => session.log(Level::Warn, &format!("{name} — частично: {}",
                reason.as_deref().unwrap_or("внешняя доступность не подтверждена"))),
            (_, reason) => session.log(Level::Warn, &format!("{name} — ошибка: {}", reason.unwrap_or_default())),
        }
    }
}

/// `telegram menu --name N`: the server Telegram Proxy menu on a remote
/// pseudo-terminal. Preflight of the one node brings its scripts to the
/// embedded version (as the batch actions do), then the returned job runs on
/// the requester's console.
pub async fn menu_prepare<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T)
    -> Result<TerminalJob<T>>
{
    let name = required(invocation, "name")?;
    let node = session.state.load_config()?.nodes.into_iter().find(|node| node.name == name).ok_or_else(|| not_found(name))?;
    require_portable(session, &node)?;
    session.log(Level::Info, &format!("Подключаемся к {} ({}@{}:{})...", node.name, node.user, node.ip, node.port));
    let mut transport = connect();
    nodes::connect(&mut transport, &session.state, &node).await?;
    if scripts::ensure_current(&transport, &node.name).await?.uploaded {
        session.log(Level::Info, &format!("Скрипты на ноде «{}» обновлены.", node.name));
    }
    session.log(Level::Info, &format!("Открываю меню Telegram Proxy на {} ({})...", node.name, node.ip));
    session.log(Level::Output, "  (введите 0 в меню для выхода)");
    let command = format!("bash {} telegram-proxy menu", sh_quote(&format!("{}/setup-essence.sh", scripts::REMOTE_DIR)));
    let failure = format!("SSH-сессия Telegram Proxy с нодой «{}» завершилась с ошибкой.", node.name);
    Ok(TerminalJob::new(node.name, command, failure, "SSH-сессия завершена.", transport))
}

#[cfg(test)]
mod tests {
    use std::{cell::RefCell, collections::VecDeque, io, task::Context};

    use super::*;
    use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeScript, FakeTransport, Operation, ScriptStep};
    use crate::model::{Auth, Config, Fingerprint};
    use crate::nodes::testing::{Journal, fingerprint, invocation, session};
    use crate::nodes::{COMMAND_TIMEOUT, CONNECT_TIMEOUT, LONG_TIMEOUT, pin};
    use crate::transport::{ConsoleEvent, ConsoleSize, HostKeyPolicy, PtyRequest, RawConsole, remote_failure};
    use status::Ipv6;
    use status::tests::FakeReach;

    const NODES: [(&str, &str, u16); 3] = [("alpha", "203.0.113.7", 2222), ("beta", "203.0.113.8", 22), ("gamma", "203.0.113.9", 22)];

    fn pin_fp() -> Fingerprint {
        format!("SHA256:{}", "A".repeat(43)).parse().unwrap()
    }

    fn fixture(root: &Path) -> (Session, Journal) {
        let (session, journal) = session(root);
        let nodes = NODES.iter().enumerate().map(|(index, (name, ip, port))| Node {
            id: format!("{index:032x}"), name: (*name).into(), ip: (*ip).into(), port: *port, user: "root".into(),
            auth: Auth::Key, identity: None, secret_id: None, tag: None, aliases: Default::default(), ..Node::default()
        }).collect();
        session.state.save_config(&Config { nodes, ..Config::default() }).unwrap();
        for (_, ip, port) in NODES {
            pin(&session.state, ip, port, vec![pin_fp()]).unwrap();
        }
        (session, journal)
    }

    fn connect_step(index: usize, outcome: Result<()>) -> ScriptStep {
        let (_, ip, port) = NODES[index];
        ScriptStep::connect(
            ConnectExpectation::new(ip, port, "root", AuthMethod::System, CONNECT_TIMEOUT)
                .with_host_key(HostKeyPolicy { expected: None, known: vec![pin_fp()] }),
            outcome,
        )
    }

    fn exec(command: impl Into<String>, timeout: Duration, exit_status: u32, stdout: &str, stderr: &str) -> ScriptStep {
        ScriptStep::exec(command, 0, timeout, Ok(ExecResult { stdout: stdout.into(), stderr: stderr.into(), exit_status }))
    }

    fn current() -> ScriptStep {
        exec(scripts::probe_command(), COMMAND_TIMEOUT, 0, &format!("PRESENT\n{}\n", scripts::local_version().unwrap()), "")
    }

    fn missing() -> ScriptStep {
        exec(scripts::probe_command(), COMMAND_TIMEOUT, 0, "MISSING", "")
    }

    fn action(action: Action, exit_status: u32, stdout: &str) -> ScriptStep {
        exec(action.command(), action.timeout(), exit_status, stdout, "")
    }

    /// A `connect` factory handing out the given transports in order; the
    /// returned scripts observe them afterwards.
    fn transports(scripts: Vec<Vec<ScriptStep>>) -> (impl Fn() -> FakeTransport, Vec<FakeScript>) {
        let transports: Vec<FakeTransport> = scripts.into_iter().map(FakeTransport::new).collect();
        let observers = transports.iter().map(FakeTransport::script).collect();
        let queue = RefCell::new(VecDeque::from(transports));
        (move || queue.borrow_mut().pop_front().expect("no transport scripted for this node"), observers)
    }

    fn run(session: &mut Session, argv: &[&str], connect: &dyn Fn() -> FakeTransport, reach: &FakeReach) -> Result<Value> {
        let invocation = invocation(argv);
        tokio::runtime::Builder::new_current_thread().build().unwrap()
            .block_on(batch(session, &invocation, &invocation.verb.clone(), connect, reach))
    }

    fn reach() -> FakeReach {
        FakeReach::new((true, Ipv6::NotPresent), true)
    }

    fn rows(error: &RcError) -> Vec<(String, String, Option<String>)> {
        error.extra["results"].as_array().unwrap().iter().map(|row| (
            row["node"].as_str().unwrap().to_owned(), row["status"].as_str().unwrap().to_owned(), row["reason"].as_str().map(str::to_owned),
        )).collect()
    }

    #[test]
    fn preflight_probes_every_node_then_one_plan_without_yes_changes_nothing() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = fixture(root.path());
        let before = fingerprint(root.path());
        let (connect, observers) = transports(vec![
            vec![connect_step(0, Ok(())), current()],
            vec![connect_step(1, Ok(())), missing()],
        ]);
        let argv = ["telegram", "install", "--name", "alpha", "--name", "beta", "--name", "alpha"];
        let error = run(&mut session, &argv, &connect, &reach()).unwrap_err();
        assert_eq!((error.code, error.exit_code()), ("confirmation_required", 2));
        let version = scripts::local_version().unwrap();
        let lines = vec![
            "Включение MTProto Proxy".to_owned(),
            "В межсетевом экране провайдера разрешите TCP/2398 и запретите TCP/8888. Служба MTProxy устанавливается автоматически.".to_owned(),
            "alpha  203.0.113.7:2222".to_owned(),
            format!("beta  203.0.113.8:22 — будут загружены скрипты v{version}"),
        ];
        assert_eq!(error.extra["plan"], json!(lines));
        let parsed = invocation(&argv);
        let expected = Plan::new(lines, format!("{} {version}", bundle_sha256().unwrap()))
            .token(&parsed.noun, &parsed.verb, parsed.confirmation_args());
        assert_eq!(error.extra["plan_token"], expected, "the bundle SHA-256 and VERSION are part of the token");
        assert_eq!(bundle_sha256().unwrap(), bundle_sha256().unwrap());
        for observer in &observers {
            observer.assert_finished();
            assert!(!observer.journal().iter().any(|op| matches!(op, Operation::Upload { .. })));
        }
        assert_eq!(fingerprint(root.path()), before);
        assert!(journal.borrow().iter().any(|(_, text)| text == "Проверка ноды (2/2): beta…"));
    }

    #[test]
    fn unreachable_node_is_an_error_row_while_others_proceed() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = fixture(root.path());
        let (connect, observers) = transports(vec![
            vec![connect_step(0, Ok(())), current(), action(Action::WebRestart, 0, "Web Proxy перезапущен.\n")],
            vec![connect_step(1, Err(remote_failure("connect")))],
            // Preflight probe, then `ensure_current`: probe, upload, confirming probe.
            vec![connect_step(2, Ok(())), missing(), missing(), ScriptStep::upload_any_local(scripts::REMOTE_DIR, LONG_TIMEOUT, Ok(())),
                current(), action(Action::WebRestart, 0, "")],
        ]);
        let error = run(&mut session, &["telegram", "web-restart", "--all", "--yes"], &connect, &reach()).unwrap_err();
        // v1 aggregate: any error row makes the batch an error (exit 1), even next to ok rows.
        assert_eq!((error.code, error.exit_code()), ("remote_failed", 1));
        assert_eq!(rows(&error), [
            ("alpha".into(), "ok".into(), None),
            ("beta".into(), "error".into(), Some("Не удалось подключиться к «beta».".into())),
            ("gamma".into(), "ok".into(), None),
        ]);
        for observer in &observers {
            observer.assert_finished();
        }
        let journal = journal.borrow();
        assert!(journal.contains(&(Level::Warn, "Нода «beta» исключена: Не удалось подключиться к «beta».".into())));
        assert!(journal.contains(&(Level::Warn, "beta — ошибка: Не удалось подключиться к «beta».".into())));
        assert!(journal.contains(&(Level::Success, "gamma — успешно".into())));
    }

    #[test]
    fn not_installed_on_some_nodes_is_exit_three_and_server_failures_are_redacted_rows() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = fixture(root.path());
        let (connect, observers) = transports(vec![
            vec![connect_step(0, Ok(())), current(), action(Action::RemoveWeb, 0, "")],
            vec![connect_step(1, Ok(())), current(), action(Action::RemoveWeb, 3, "")],
        ]);
        let argv = ["telegram", "remove", "--component", "web", "--name", "alpha", "--name", "beta", "--yes"];
        let error = run(&mut session, &argv, &connect, &reach()).unwrap_err();
        assert_eq!((error.code, error.exit_code()), ("not_installed", 3), "v1: not installed on part of the nodes");
        let statuses: Vec<String> = rows(&error).into_iter().map(|(_, status, _)| status).collect();
        assert_eq!(statuses, ["ok", "not_installed"]);
        observers.iter().for_each(FakeScript::assert_finished);

        let secret = "0123456789abcdef0123456789abcdef";
        let (connect, observers) = transports(vec![vec![connect_step(0, Ok(())), current(),
            exec(Action::RemoveAll.command(), Action::RemoveAll.timeout(), 1, "шаг 1\n", &format!("\u{1b}[31m[✗] secret={secret}\u{1b}[0m\n\n"))]]);
        let error = run(&mut session, &["telegram", "remove-all", "--name", "alpha", "--yes"], &connect, &reach()).unwrap_err();
        assert_eq!((error.code, error.exit_code()), ("remote_failed", 1));
        assert_eq!(rows(&error), [("alpha".into(), "error".into(), Some("[✗] secret=[REDACTED]".into()))]);
        observers.iter().for_each(FakeScript::assert_finished);
    }

    #[test]
    fn status_is_read_only_and_evaluates_server_json() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = fixture(root.path());
        let before = fingerprint(root.path());
        let installed = r#"{"installed":true,"web_enabled":false,"mtproto_enabled":true,"backend":"active","firewall":"active","timer":"active","mtproto_ipv4":"198.51.100.4","mtproto_listener":true,"mtproto_ip_state":"current"}"#;
        let (connect, observers) = transports(vec![
            vec![connect_step(0, Ok(())), current(), action(Action::Status, 0, installed)],
            vec![connect_step(1, Ok(())), missing()],
            vec![connect_step(2, Ok(())), current(), action(Action::Status, 0, "warning\n{}")],
        ]);
        let reach = reach();
        let error = run(&mut session, &["telegram", "status"], &connect, &reach).unwrap_err();
        assert_eq!((error.code, error.exit_code()), ("remote_failed", 1));
        assert_eq!(rows(&error), [
            ("alpha".into(), "ok".into(), None),
            ("beta".into(), "error".into(), Some(STALE.into())),
            ("gamma".into(), "error".into(), Some("Некорректный ответ сервера при запросе статуса Telegram Proxy.".into())),
        ]);
        assert_eq!(*reach.calls.borrow(), ["mtproto:198.51.100.4"]);
        observers.iter().for_each(FakeScript::assert_finished);
        assert_eq!(fingerprint(root.path()), before);
        let journal = journal.borrow();
        assert!(journal.contains(&(Level::Success, "Telegram Proxy alpha (203.0.113.7): успешно".into())));
        assert!(journal.contains(&(Level::Output, "      MTProto Proxy: TCP/2398 успешно".into())));
        drop(journal);

        let (connect, observers) = transports(vec![vec![connect_step(0, Ok(())), current(),
            action(Action::Status, 3, r#"{"installed":false,"web_enabled":false,"mtproto_enabled":false}"#)]]);
        let error = run(&mut session, &["telegram", "status", "--name", "alpha"], &connect, &FakeReach::new((true, Ipv6::Ok), true)).unwrap_err();
        assert_eq!((error.code, error.exit_code()), ("not_installed", 3));
        observers.iter().for_each(FakeScript::assert_finished);
    }

    #[test]
    fn selection_and_flag_errors_precede_any_effect() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = fixture(root.path());
        let before = fingerprint(root.path());
        let never = || -> FakeTransport { panic!("no transport before validation") };
        for (argv, code) in [
            (&["telegram", "install"][..], "usage"),
            (&["telegram", "install", "--name", "alpha", "--all"], "usage"),
            (&["telegram", "install", "--name", "alpha", "--component", "web"], "usage"),
            (&["telegram", "remove", "--name", "alpha"], "usage"),
            (&["telegram", "remove", "--name", "alpha", "--component", "bogus"], "usage"),
            (&["telegram", "web-update", "--name", "missing"], "not_found"),
        ] {
            let error = run(&mut session, argv, &never, &reach()).unwrap_err();
            assert_eq!(error.code, code, "{argv:?}");
        }
        assert!(journal.borrow().is_empty());
        assert_eq!(fingerprint(root.path()), before);
    }

    /// A raw console that records the remote output.
    #[derive(Default)]
    struct TestConsole(Vec<u8>);

    const SIZE: ConsoleSize = ConsoleSize { cols: 100, rows: 30 };

    impl RawConsole for TestConsole {
        fn poll_event(&mut self, _: &mut Context<'_>) -> Poll<ConsoleEvent> { Poll::Pending }
        fn output(&mut self, data: &[u8]) -> io::Result<()> {
            self.0.extend_from_slice(data);
            Ok(())
        }
    }

    /// `menu_prepare` then `run`, as the daemon does.
    fn run_menu(session: &mut Session, connect: &dyn Fn() -> FakeTransport, console: &mut TestConsole) -> Result<Value> {
        let invocation = invocation(&["telegram", "menu", "--name", "alpha"]);
        tokio::runtime::Builder::new_current_thread().build().unwrap().block_on(async {
            let job = menu_prepare(session, &invocation, connect).await?;
            assert_eq!((job.node.as_str(), job.done_log), ("alpha", "SSH-сессия завершена."));
            job.run(PtyRequest { term: "xterm".into(), size: SIZE }, console).await
        })
    }

    #[test]
    fn menu_opens_the_server_menu_uploading_scripts_on_a_fresh_node() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = fixture(root.path());
        let command = "bash '/root/essence-setup/setup-essence.sh' telegram-proxy menu";
        let pty = PtyRequest { term: "xterm".into(), size: SIZE };
        let (connect, observers) = transports(vec![vec![connect_step(0, Ok(())), current(),
            ScriptStep::interactive(command, pty.clone(), b"MENU".to_vec(), Ok(0))]]);
        let mut console = TestConsole::default();
        assert_eq!(run_menu(&mut session, &connect, &mut console).unwrap(), json!({}));
        observers[0].assert_finished();
        assert_eq!(console.0, b"MENU");
        assert_eq!(journal.borrow().last().unwrap(), &(Level::Output, "  (введите 0 в меню для выхода)".to_owned()));

        let (connect, observers) = transports(vec![vec![connect_step(0, Ok(())), missing(),
            ScriptStep::upload_any_local(scripts::REMOTE_DIR, LONG_TIMEOUT, Ok(())), current(),
            ScriptStep::interactive(command, pty, b"MENU".to_vec(), Ok(0))]]);
        let mut console = TestConsole::default();
        assert_eq!(run_menu(&mut session, &connect, &mut console).unwrap(), json!({}));
        observers[0].assert_finished();
        assert_eq!(console.0, b"MENU");
        assert!(journal.borrow().contains(&(Level::Info, "Скрипты на ноде «alpha» обновлены.".to_owned())));
    }

    #[test]
    fn menu_failure_names_the_node() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = fixture(root.path());
        let command = "bash '/root/essence-setup/setup-essence.sh' telegram-proxy menu";
        let pty = PtyRequest { term: "xterm".into(), size: SIZE };
        let (connect, observers) = transports(vec![vec![connect_step(0, Ok(())), current(),
            ScriptStep::interactive(command, pty, Vec::new(), Ok(5))]]);
        let error = run_menu(&mut session, &connect, &mut TestConsole::default()).unwrap_err();
        observers[0].assert_finished();
        assert_eq!((error.code, error.message.as_str()), ("remote_failed", "SSH-сессия Telegram Proxy с нодой «alpha» завершилась с ошибкой."));
        assert_eq!((error.extra["name"].as_str(), error.extra["exit_status"].as_u64()), (Some("alpha"), Some(5)));
    }
}
