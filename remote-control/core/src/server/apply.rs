//! `node apply`: probe every target node, show one plan, then run the
//! executor on each node as a detached systemd unit and poll its status file
//! (reconnecting after drops) until it commits or rolls back.

use std::collections::BTreeMap;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::time::Instant;

use crate::cli::Invocation;
use crate::clients::require_one;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::locking::LockKind;
use crate::log::Level;
use crate::model::{Applied, Config, Node};
use crate::nodes::{self, COMMAND_TIMEOUT, LONG_TIMEOUT, required, sh_quote};
use crate::state::State;
use crate::transport::RemoteTransport;

use super::bundle::{NODE_ROOT, agent_dir, materialize_agent};
use super::render::{self, Desired, NodeSecrets, RenderedFile};

const POLL_PAUSE: Duration = Duration::from_secs(2);
const RECONNECT_PAUSES: [u64; 5] = [1, 2, 4, 8, 15];
const OFFLINE_LIMIT: Duration = Duration::from_secs(10 * 60);
const OPERATION_LIMIT: Duration = Duration::from_secs(60 * 60);

fn ops_dir(op_id: &str) -> String {
    format!("{NODE_ROOT}/ops/{op_id}")
}

/// A fresh operation id (tests may fix the next one).
fn new_op_id() -> String {
    #[cfg(test)]
    if let Some(id) = tests::NEXT_OP_ID.with(|next| next.borrow_mut().take()) {
        return id;
    }
    crate::github::random_hex(16)
}

/// The Russian label of an executor stage (or failure id).
pub fn stage_label(stage: &str) -> &str {
    match stage {
        "packages" => "установка пакетов",
        "system" => "системные настройки",
        "mihomo" => "установка mihomo",
        "dns" => "проверка DNS",
        "site" => "сайт-заглушка",
        "certificate" => "сертификаты",
        "prepare" => "подготовка компонентов",
        "config" => "конфигурация и проверка",
        "firewall" => "правила UFW",
        "cleanup" => "очистка",
        "locked" => "другая операция",
        other => other,
    }
}

/// One read-only command: OS, systemd, executor integrity, listening sockets,
/// hashes of the applied files and the status of an unfinished operation.
pub fn probe_command(node: &Node) -> String {
    let agent = sh_quote(&agent_dir());
    let mut command = format!(
        ". /etc/os-release; printf 'os=%s\\n' \"$ID\"\n\
         [ -d /run/systemd/system ] && echo systemd=yes\n\
         (cd {agent} 2>/dev/null && sha256sum -c --quiet MANIFEST >/dev/null 2>&1) && echo agent=ok\n\
         ss -H -tuln | awk '{{print \"listen\", $1, $5}}'\n");
    let files: Vec<String> = node.applied.iter().flat_map(|applied| applied.files.keys()).map(|path| sh_quote(path)).collect();
    if !files.is_empty() {
        command.push_str(&format!(
            "for f in {}; do if [ -f \"$f\" ]; then sha256sum \"$f\"; else echo \"missing $f\"; fi; done\n", files.join(" ")));
    }
    if let Some(op_id) = &node.operation {
        command.push_str(&format!("cat {} 2>/dev/null\n", sh_quote(&format!("{}/status", ops_dir(op_id)))));
    }
    command.push_str("true");
    command
}

pub fn status_command(op_id: &str) -> String {
    format!("cat {}", sh_quote(&format!("{}/status", ops_dir(op_id))))
}

pub fn log_command(op_id: &str) -> String {
    format!("tail -n 40 {}", sh_quote(&format!("{}/log", ops_dir(op_id))))
}

pub fn start_command(op_id: &str) -> String {
    format!("systemd-run --unit=essence-apply-{op_id} --collect --quiet /bin/bash {} {}",
        sh_quote(&format!("{}/apply.sh", agent_dir())), sh_quote(&ops_dir(op_id)))
}

pub fn agent_reset_command() -> String {
    format!("rm -rf {}", sh_quote(&agent_dir()))
}

/// What the probe saw on one node.
#[derive(Debug, Default)]
struct Probe {
    os: String,
    systemd: bool,
    agent_ok: bool,
    /// `(proto, port)` of listening sockets.
    listening: Vec<(String, u16)>,
    hashes: BTreeMap<String, Option<String>>,
    status: BTreeMap<String, String>,
}

fn parse_probe(stdout: &str) -> Probe {
    let mut probe = Probe::default();
    for line in stdout.lines().map(|line| line.trim_end_matches('\r')) {
        if let Some(os) = line.strip_prefix("os=") {
            probe.os = os.trim_matches('"').to_owned();
        } else if line == "systemd=yes" {
            probe.systemd = true;
        } else if line == "agent=ok" {
            probe.agent_ok = true;
        } else if let Some(rest) = line.strip_prefix("listen ") {
            let mut parts = rest.split_whitespace();
            let (Some(proto), Some(address)) = (parts.next(), parts.next()) else { continue };
            if let Some(port) = address.rsplit_once(':').and_then(|(_, port)| port.parse().ok()) {
                probe.listening.push((proto.to_owned(), port));
            }
        } else if let Some(path) = line.strip_prefix("missing ") {
            probe.hashes.insert(path.to_owned(), None);
        } else if let Some((key, value)) = line.split_once('=').filter(|(key, _)| matches!(*key, "stage" | "result" | "error")) {
            probe.status.insert(key.to_owned(), value.to_owned());
        } else if let Some((hash, path)) = line.split_once("  ").filter(|(hash, _)| hash.len() == 64) {
            probe.hashes.insert(path.to_owned(), Some(hash.to_owned()));
        }
    }
    probe
}

fn parse_status(stdout: &str) -> BTreeMap<String, String> {
    stdout.lines().filter_map(|line| line.trim_end_matches('\r').split_once('='))
        .map(|(key, value)| (key.to_owned(), value.to_owned())).collect()
}

/// A failed node of the report.
fn failure(name: &str, stage: &str, reason: impl Into<String>) -> Value {
    json!({"name": name, "stage": stage, "reason": reason.into()})
}

#[derive(Default)]
struct Report {
    applied: Vec<String>,
    failed: Vec<Value>,
    unchanged: Vec<String>,
}

impl Report {
    fn finish(self) -> Result<Value> {
        let data = json!({"applied": self.applied, "failed": self.failed, "unchanged": self.unchanged});
        if self.failed.is_empty() {
            return Ok(data);
        }
        Err(RcError::new("partial", "Применение завершено с ошибками.")
            .with_extra("applied", data["applied"].clone())
            .with_extra("failed", data["failed"].clone())
            .with_extra("unchanged", data["unchanged"].clone()))
    }
}

/// Target nodes of `--name N…`, `--profile P` or `--pending`.
fn targets(config: &Config, invocation: &Invocation) -> Result<Vec<String>> {
    require_one(invocation, &["name", "profile", "pending"])?;
    let names: Vec<String> = if invocation.has("name") {
        let mut names = Vec::new();
        for name in invocation.values("name") {
            let node = nodes::find(config, name)?;
            if node.profile.is_none() && node.applied.is_none() {
                return Err(RcError::new("invalid", format!("У ноды «{name}» нет профиля.")).with_extra("name", name.clone()));
            }
            if !names.contains(name) {
                names.push(name.clone());
            }
        }
        names
    } else if invocation.has("profile") {
        let profile = required(invocation, "profile")?;
        if config.find_profile(profile).is_none() {
            return Err(RcError::new("not_found", format!("Профиль «{profile}» не найден.")).with_extra("name", profile));
        }
        config.nodes.iter().filter(|node| node.profile.as_deref() == Some(profile)).map(|node| node.name.clone()).collect()
    } else {
        config.nodes.iter().filter(|node| matches!(render::status(config, node), "pending" | "running"))
            .map(|node| node.name.clone()).collect()
    };
    if names.is_empty() {
        return Err(RcError::new("nothing_pending", "Нет нод, ожидающих применения."));
    }
    Ok(names)
}

/// Secrets the node's files need; a missing one fails the node.
fn node_secrets(state: &State, config: &Config, node: &Node) -> Result<NodeSecrets> {
    let needs_reality = node.profile.as_deref().and_then(|name| config.find_profile(name)).is_some_and(|p| p.has_reality());
    let store = state.secret_store();
    let mut secrets = NodeSecrets::default();
    if needs_reality {
        let id = format!("node:{}:reality-key", node.id);
        secrets.reality_key = Some(store.get(&id)?.ok_or_else(|| RcError::new("missing_secret",
            format!("Ключ Reality ноды «{}» не сохранён.", node.name)).with_extra("name", node.name.clone()))?);
    }
    Ok(secrets)
}

/// The local operation directory: `spec.sh`, the lists and `files/<path>`.
fn operation_dir(op_id: &str, desired: &Desired) -> Result<tempfile::TempDir> {
    let dir = tempfile::Builder::new().prefix("essence-op-").tempdir()?;
    crate::secure_fs::create_dir_all(dir.path())?;
    let mut spec = format!("OP_ID={}\n", sh_quote(op_id));
    for (key, value) in &desired.spec {
        spec.push_str(&format!("{key}={}\n", sh_quote(value)));
    }
    std::fs::write(dir.path().join("spec.sh"), spec)?;
    let list: String = desired.files.iter().map(|f| format!("{} {} {} {}\n", f.mode, f.owner, f.group, f.path)).collect();
    std::fs::write(dir.path().join("files.list"), list)?;
    let remove: String = desired.remove.iter().map(|path| format!("{path}\n")).collect();
    std::fs::write(dir.path().join("remove.list"), remove)?;
    for RenderedFile { path, content, .. } in &desired.files {
        let target = dir.path().join("files").join(path.trim_start_matches('/'));
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(target, content.as_bytes())?;
    }
    Ok(dir)
}

/// Persist the node's running operation (`None` clears it).
fn set_operation(session: &mut Session, id: &str, operation: Option<String>) -> Result<()> {
    session.mutate("node apply start", |state| {
        let mut config = state.load_config()?;
        if let Some(node) = config.nodes.iter_mut().find(|node| node.id == id) {
            node.operation = operation;
        }
        state.save_config(&config)
    })
}

/// Outcome of one node's operation.
enum Outcome { Committed, Failed { stage: String, reason: String } }

/// One node through start and polling.
struct Run<'t, T> {
    node: Node,
    transport: &'t mut T,
    desired: Desired,
    op_id: String,
    started: Instant,
    stage: String,
    lost: Option<(Instant, usize, Instant)>,
    outcome: Option<Outcome>,
}

impl<'t, T: RemoteTransport> Run<'t, T> {
    fn fail(&mut self, stage: &str, reason: impl Into<String>) {
        self.outcome = Some(Outcome::Failed { stage: stage.to_owned(), reason: reason.into() });
    }

    /// Upload the executor when needed, the operation directory, then start it.
    async fn start(&mut self, session: &mut Session, agent_ok: bool) -> Result<()> {
        let name = self.node.name.clone();
        if !agent_ok {
            let reset = self.transport.exec(&agent_reset_command(), b"", COMMAND_TIMEOUT).await?;
            if reset.exit_status != 0 {
                return Err(RcError::new("remote_failed", "Не удалось подготовить каталог исполнителя."));
            }
            let agent = materialize_agent()?;
            self.transport.upload(agent.path(), &agent_dir(), LONG_TIMEOUT).await?;
            session.log(Level::Info, &format!("{name}: исполнитель загружен"));
        }
        let dir = operation_dir(&self.op_id, &self.desired)?;
        self.transport.upload(dir.path(), &ops_dir(&self.op_id), LONG_TIMEOUT).await?;
        let started = self.transport.exec(&start_command(&self.op_id), b"", COMMAND_TIMEOUT).await?;
        if started.exit_status != 0 {
            return Err(RcError::new("remote_failed", "Не удалось запустить исполнитель."));
        }
        Ok(())
    }

    /// One poll: read the status or try to reconnect.
    async fn poll(&mut self, session: &mut Session) {
        let now = Instant::now();
        if now.duration_since(self.started) > OPERATION_LIMIT {
            return self.fail("timeout", "Операция не завершилась за 60 минут.");
        }
        if let Some((since, attempt, next)) = self.lost {
            if now.duration_since(since) > OFFLINE_LIMIT {
                return self.fail("timeout", "Нет связи с нодой больше 10 минут.");
            }
            if now < next {
                return;
            }
            if nodes::connect(self.transport, &session.state, &self.node).await.is_ok() {
                self.lost = None;
            } else {
                let pause = RECONNECT_PAUSES[(attempt + 1).min(RECONNECT_PAUSES.len() - 1)];
                self.lost = Some((since, attempt + 1, now + Duration::from_secs(pause)));
                return;
            }
        }
        let status = match self.transport.exec(&status_command(&self.op_id), b"", COMMAND_TIMEOUT).await {
            Ok(result) if result.exit_status == 0 => parse_status(&String::from_utf8_lossy(&result.stdout)),
            Ok(_) => return,
            Err(_) => {
                session.log(Level::Warn, &format!("{}: связь потеряна, переподключение…", self.node.name));
                self.lost = Some((now, 0, now + Duration::from_secs(RECONNECT_PAUSES[0])));
                return;
            }
        };
        if let Some(stage) = status.get("stage").filter(|stage| **stage != self.stage) {
            self.stage = stage.clone();
            if stage != "init" {
                session.log(Level::Info, &format!("{}: {}", self.node.name, stage_label(stage)));
            }
        }
        match status.get("result").map(String::as_str) {
            None => {}
            Some("committed") => self.outcome = Some(Outcome::Committed),
            Some(result) => {
                let stage = status.get("error").cloned().unwrap_or_else(|| self.stage.clone());
                let what = if result == "rolled_back" { "откат" } else { "ошибка" };
                if let Ok(log) = self.transport.exec(&log_command(&self.op_id), b"", COMMAND_TIMEOUT).await {
                    for line in String::from_utf8_lossy(&log.stdout).lines() {
                        session.log(Level::Output, line);
                    }
                }
                let reason = format!("{}: {what} на этапе «{}»", self.node.name, stage_label(&stage));
                session.log(Level::Warn, &reason);
                self.fail(&stage, reason);
            }
        }
    }

    /// Record the result: `applied` after a commit, the operation cleared always.
    fn record(&self, session: &mut Session) -> Result<()> {
        let committed = matches!(self.outcome, Some(Outcome::Committed));
        let desired = &self.desired;
        session.mutate("node apply", |state| {
            let mut config = state.load_config()?;
            if let Some(node) = config.nodes.iter_mut().find(|node| node.id == self.node.id) {
                node.operation = None;
                if committed {
                    node.applied = (!desired.teardown).then(|| Applied {
                        digest: desired.digest.clone(), files: render::file_hashes(&desired.files),
                        ports: desired.ports.clone(), at: crate::github::utc_stamp(),
                    });
                }
            }
            state.save_config(&config)
        })
    }
}

/// Poll every unfinished run in turn until all finish.
async fn drive<T: RemoteTransport>(session: &mut Session, runs: &mut [Run<'_, T>]) {
    loop {
        let mut active = false;
        for run in runs.iter_mut().filter(|run| run.outcome.is_none()) {
            run.poll(session).await;
            active |= run.outcome.is_none();
        }
        if !active {
            break;
        }
        tokio::time::sleep(POLL_PAUSE).await;
    }
}

/// Planned work on one probed node.
struct Planned<T> {
    name: String,
    transport: T,
    digest: String,
    agent_ok: bool,
    /// An unfinished operation to resume instead of starting a new one.
    resume: Option<String>,
}

/// Probe one node; `Err((stage, reason))` excludes it.
async fn probe<T: RemoteTransport>(session: &Session, transport: &mut T, node: &Node, desired: &Desired)
    -> std::result::Result<Probe, (String, String, Option<u16>)>
{
    let fail = |error: RcError| (error.code.to_owned(), error.message, None);
    nodes::require_portable(session, node).map_err(fail)?;
    nodes::connect(transport, &session.state, node).await.map_err(fail)?;
    let result = transport.exec(&probe_command(node), b"", COMMAND_TIMEOUT).await.map_err(fail)?;
    let probe = parse_probe(&String::from_utf8_lossy(&result.stdout));
    if !matches!(probe.os.as_str(), "debian" | "ubuntu") || !probe.systemd {
        return Err(("unsupported_os".into(), format!("Нода «{}»: нужна Debian или Ubuntu с systemd.", node.name), None));
    }
    let applied_ports = node.applied.as_ref().map(|applied| applied.ports.clone()).unwrap_or_default();
    for rule in desired.ports.iter().filter(|rule| !applied_ports.contains(rule)) {
        let Some((port, proto)) = rule.split_once('/').and_then(|(port, proto)| Some((port.parse::<u16>().ok()?, proto))) else { continue };
        if probe.listening.iter().any(|(listening, busy)| listening == proto && *busy == port) {
            return Err(("port_busy".into(), format!("Нода «{}»: порт {port} уже занят.", node.name), Some(port)));
        }
    }
    Ok(probe)
}

/// `node apply (--name N… | --profile P | --pending) [--yes]`.
pub async fn apply<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T) -> Result<Value> {
    let config = session.state.load_config()?;
    let names = targets(&config, invocation)?;
    let mut report = Report::default();
    let mut planned: Vec<Planned<T>> = Vec::new();
    let mut lines = Vec::new();
    let mut extra = Vec::new();
    for name in &names {
        let node = nodes::find(&config, name)?;
        let desired = match render::desired(&config, node, None) {
            Ok(desired) => desired,
            // An explicitly named node reports its configuration problem
            // (`domain_required`) so the front end can resolve and repeat.
            Err(error) if invocation.has("name") => return Err(error),
            Err(error) => {
                report.failed.push(failure(name, error.code, error.message));
                continue;
            }
        };
        let mut transport = connect();
        session.log(Level::Info, &format!("Проверка ноды {name}…"));
        let probe = match probe(session, &mut transport, node, &desired).await {
            Ok(probe) => probe,
            Err((stage, reason, port)) => {
                session.log(Level::Warn, &reason);
                let mut entry = failure(name, &stage, reason);
                if let Some(port) = port {
                    entry["port"] = json!(port);
                }
                report.failed.push(entry);
                continue;
            }
        };
        let resume = node.operation.clone().filter(|_| !probe.status.is_empty() && !probe.status.contains_key("result"));
        let applied = node.applied.as_ref();
        let drift: Vec<&String> = applied.iter().flat_map(|applied| applied.files.iter())
            .filter(|(path, hash)| desired.files.iter().any(|file| file.path == **path)
                && probe.hashes.get(*path).is_some_and(|remote| remote.as_ref() != Some(hash)))
            .map(|(path, _)| path).collect();
        if resume.is_none() && drift.is_empty() && applied.is_some_and(|applied| applied.digest == desired.digest) {
            report.unchanged.push(name.clone());
            continue;
        }
        lines.extend(desired.lines.iter().cloned());
        if resume.is_some() {
            lines.push(format!("{name}: продолжается незавершённое применение."));
        }
        lines.extend(drift.iter().map(|path| format!("Изменено вручную, будет перезаписано: {path}")));
        extra.push(format!("{name}={}", desired.digest));
        extra.extend(drift.iter().map(|path| format!("drift:{name}:{path}")));
        planned.push(Planned { name: name.clone(), transport, digest: desired.digest, agent_ok: probe.agent_ok, resume });
    }
    if planned.is_empty() {
        return report.finish();
    }
    extra.sort();
    let plan = Plan::new(lines, extra.join("\n"));
    plan.confirm(invocation)?;

    let locks = session.state.locks().clone();
    let _guard = locks.acquire(LockKind::Mutation, "node apply")?;
    let config = session.state.load_config()?;
    let mut runs = Vec::new();
    for item in &planned {
        let node = nodes::find(&config, &item.name)?;
        if render::desired(&config, node, None).map(|desired| desired.digest).ok().as_deref() != Some(item.digest.as_str()) {
            return Err(plan.changed(invocation));
        }
    }
    for item in &mut planned {
        let node = nodes::find(&config, &item.name)?.clone();
        let desired = match node_secrets(&session.state, &config, &node)
            .and_then(|secrets| render::desired(&config, &node, Some(&secrets)))
        {
            Ok(desired) => desired,
            Err(error) => {
                report.failed.push(failure(&item.name, error.code, error.message));
                continue;
            }
        };
        let mut run = Run {
            transport: &mut item.transport, desired, op_id: String::new(), started: Instant::now(),
            stage: String::new(), lost: None, outcome: None, node,
        };
        if let Some(op_id) = item.resume.clone() {
            session.log(Level::Info, &format!("{}: продолжаю незавершённое применение", item.name));
            run.op_id = op_id;
        } else {
            run.op_id = new_op_id();
            set_operation(session, &run.node.id, Some(run.op_id.clone()))?;
            if let Err(error) = run.start(session, item.agent_ok).await {
                set_operation(session, &run.node.id, None)?;
                session.log(Level::Warn, &format!("{}: не удалось запустить применение: {}", item.name, error.message));
                report.failed.push(failure(&item.name, "start", error.message));
                continue;
            }
            session.log(Level::Info, &format!("{}: применение запущено", item.name));
        }
        runs.push(run);
    }
    drive(session, &mut runs).await;
    for run in &runs {
        match &run.outcome {
            Some(Outcome::Committed) => {
                run.record(session)?;
                session.log(Level::Success, &format!("{}: применено", run.node.name));
                report.applied.push(run.node.name.clone());
            }
            Some(Outcome::Failed { stage, reason }) => {
                if stage != "timeout" {
                    run.record(session)?;
                }
                report.failed.push(failure(&run.node.name, stage, reason.clone()));
            }
            None => {}
        }
    }
    report.finish()
}

/// Remove everything Essence installed on a connected node (`node delete
/// --scope server`). `Ok` only after the executor committed.
pub async fn teardown<T: RemoteTransport>(session: &mut Session, node: &Node, transport: &mut T) -> Result<()> {
    let probe = transport.exec(&probe_command(&Node { applied: None, operation: None, ..node.clone() }), b"", COMMAND_TIMEOUT).await?;
    let agent_ok = parse_probe(&String::from_utf8_lossy(&probe.stdout)).agent_ok;
    let mut run = Run {
        node: node.clone(), transport, desired: render::teardown(node), op_id: new_op_id(),
        started: Instant::now(), stage: String::new(), lost: None, outcome: None,
    };
    set_operation(session, &node.id, Some(run.op_id.clone()))?;
    if let Err(error) = run.start(session, agent_ok).await {
        set_operation(session, &node.id, None)?;
        return Err(error);
    }
    drive(session, std::slice::from_mut(&mut run)).await;
    match run.outcome.take() {
        Some(Outcome::Committed) => {
            run.outcome = Some(Outcome::Committed);
            run.record(session)
        }
        Some(Outcome::Failed { stage, reason }) => {
            if stage != "timeout" {
                set_operation(session, &node.id, None)?;
            }
            Err(RcError::new("remote_failed", reason).with_extra("stage", stage))
        }
        None => Err(RcError::new("remote_failed", "Снятие не завершено.")),
    }
}

#[cfg(test)]
pub(crate) mod tests;
