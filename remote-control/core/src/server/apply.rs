//! `node apply`: probe every target node, show one plan, then run the
//! executor on each node as a detached systemd unit and poll its status file
//! (reconnecting after drops) until it commits or rolls back.
//!
//! Locking: the configuration lock is held only while the plan is re-checked
//! and the operations are recorded (`claim`), and again for each result. The
//! executor itself runs and is polled without it: a recorded
//! `node.operation` (status `running`) and the node-side `flock` keep a second
//! operation off the node. `node delete --scope server` (`teardown`) goes
//! through the same `claim`, start, poll and record.

use std::collections::BTreeMap;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::time::Instant;

use crate::cli::Invocation;
use crate::clients::require_one;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::model::{Applied, Config, Node, Operation};
use crate::nodes::{self, COMMAND_TIMEOUT, LONG_TIMEOUT, required, sh_quote};
use crate::state::State;
use crate::transport::RemoteTransport;

use super::bundle::{NODE_ROOT, agent_dir, agent_sha, materialize_agent};
use super::render::{self, Desired, NodeSecrets, RenderedFile};

const POLL_PAUSE: Duration = Duration::from_secs(2);
const RECONNECT_PAUSES: [u64; 5] = [1, 2, 4, 8, 15];
const OFFLINE_LIMIT: Duration = Duration::from_secs(10 * 60);
const OPERATION_LIMIT: Duration = Duration::from_secs(60 * 60);
/// `systemctl is-active` states of a unit that is still running.
const LIVE_UNIT: [&str; 4] = ["active", "activating", "deactivating", "reloading"];

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

/// The Russian label of an executor stage.
fn stage_label(stage: &str) -> &str {
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
        "init" => "запуск исполнителя",
        other => other,
    }
}

/// The unit state, then the status file of an operation (lines `unit=`,
/// `stage=`, `result=`, `error=`). The unit is read first: once it is gone
/// the executor has exited and its status is final.
fn status_lines(op_id: &str) -> String {
    format!("printf 'unit=%s\\n' \"$(systemctl is-active essence-apply-{op_id} 2>/dev/null)\"\ncat {} 2>/dev/null\n",
        sh_quote(&format!("{}/status", ops_dir(op_id))))
}

/// The executor directory is complete and is the one this RC embeds.
fn agent_check() -> String {
    format!("cd {} 2>/dev/null && [ \"$(sha256sum < MANIFEST | cut -d' ' -f1)\" = {} ] && sha256sum -c --quiet MANIFEST >/dev/null 2>&1",
        sh_quote(&agent_dir()), agent_sha())
}

/// One read-only command: OS, systemd, sshd's own port, executor integrity,
/// listening sockets, hashes of the applied files and the state of a
/// recorded operation.
pub fn probe_command(node: &Node) -> String {
    let mut command = format!(
        ". /etc/os-release; printf 'os=%s\\n' \"$ID\"\n\
         [ -d /run/systemd/system ] && echo systemd=yes\n\
         printf 'sshd=%s\\n' \"${{SSH_CONNECTION##* }}\"\n\
         ({}) && echo agent=ok\n\
         ss -H -tuln | awk '{{print \"listen\", $1, $5}}'\n", agent_check());
    // A recorded operation may settle into `applied` with its own files.
    let files: Vec<String> = node.applied.iter().flat_map(|applied| applied.files.keys())
        .chain(node.operation.iter().flat_map(|operation| operation.files.keys()))
        .collect::<std::collections::BTreeSet<_>>().into_iter().map(|path| sh_quote(path)).collect();
    if !files.is_empty() {
        command.push_str(&format!(
            "for f in {}; do if [ -f \"$f\" ]; then sha256sum \"$f\"; else echo \"missing $f\"; fi; done\n", files.join(" ")));
    }
    if let Some(operation) = &node.operation {
        command.push_str(&status_lines(&operation.id));
    }
    command.push_str("true");
    command
}

pub fn status_command(op_id: &str) -> String {
    format!("{}true", status_lines(op_id))
}

pub fn log_command(op_id: &str) -> String {
    format!("tail -n 40 {}", sh_quote(&format!("{}/log", ops_dir(op_id))))
}

/// Start the executor if its directory is still intact.
pub fn start_command(op_id: &str) -> String {
    format!("({}) && systemd-run --unit=essence-apply-{op_id} --collect --quiet --setenv=HOME=/root /bin/bash {} {}",
        agent_check(), sh_quote(&format!("{}/apply.sh", agent_dir())), sh_quote(&ops_dir(op_id)))
}

pub fn agent_reset_command() -> String {
    format!("rm -rf {}", sh_quote(&agent_dir()))
}

/// What the probe saw on one node.
#[derive(Debug, Default)]
struct Probe {
    os: String,
    systemd: bool,
    /// The port sshd accepted this session on (differs from the dialed one behind NAT).
    sshd: Option<u16>,
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
        } else if let Some(port) = line.strip_prefix("sshd=") {
            probe.sshd = port.parse().ok().filter(|port| *port != 0);
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
        } else if let Some((key, value)) = line.split_once('=').filter(|(key, _)| matches!(*key, "unit" | "stage" | "result" | "error")) {
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

/// The unit of the operation has exited.
fn unit_gone(status: &BTreeMap<String, String>) -> bool {
    !status.get("unit").is_some_and(|unit| LIVE_UNIT.contains(&unit.as_str()))
}

/// A failed node of the report: `{name, stage, code, message, port?}` plus
/// the error's `NODE_CODE_EXTRA` keys. `stage` is the executor stage or
/// `probe`/`start`; `message` is shown after the node name.
#[derive(Clone, Debug)]
struct Failure {
    stage: String,
    code: String,
    message: String,
    port: Option<u16>,
    extra: Vec<(String, Value)>,
}

/// Error extra the front ends' node-code handlers read from a `failed[]`
/// entry (`host_key_*` fingerprints, the missing secret's name); none of
/// them is secret.
const NODE_CODE_EXTRA: [&str; 3] = ["fingerprints", "host", "secret"];

impl Failure {
    fn new(stage: &str, code: &str, message: impl Into<String>) -> Self {
        Self { stage: stage.to_owned(), code: code.to_owned(), message: message.into(), port: None, extra: Vec::new() }
    }

    fn of(stage: &str, error: RcError) -> Self {
        let extra = error.extra.into_iter().filter(|(key, _)| NODE_CODE_EXTRA.contains(&key.as_str())).collect();
        Self { extra, ..Self::new(stage, error.code, error.message) }
    }

    fn entry(&self, name: &str) -> Value {
        let mut entry = json!({"name": name, "stage": self.stage, "code": self.code, "message": self.message});
        if let Some(port) = self.port {
            entry["port"] = json!(port);
        }
        for (key, value) in &self.extra {
            entry[key.as_str()] = value.clone();
        }
        entry
    }
}

#[derive(Default)]
struct Report {
    applied: Vec<String>,
    failed: Vec<Value>,
    unchanged: Vec<String>,
}

impl Report {
    fn fail(&mut self, session: &mut Session, name: &str, failure: &Failure) {
        session.log(Level::Warn, &format!("{name}: {}", failure.message));
        self.failed.push(failure.entry(name));
    }

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
        let missing = || RcError::new("missing_secret", missing_reality_key(&node.name)).with_extra("name", node.name.clone());
        secrets.reality_key = Some(match store.get(&id) {
            Ok(Some(key)) => key,
            Ok(None) => return Err(missing()),
            Err(error) if error.code == "missing_secret" => return Err(missing()),
            Err(error) => return Err(error),
        });
    }
    Ok(secrets)
}

/// A Reality key absent or not decryptable here. The key is generated once
/// with the node's parameters, so the ways back are the GitHub vault copy or
/// a node added anew (new keys, clients regenerated).
fn missing_reality_key(name: &str) -> String {
    format!("Ключ Reality ноды «{name}» отсутствует или не расшифровывается на этом устройстве. \
        При хранении в GitHub загрузите конфигурацию заново (source github-fetch) — ключ восстановится из хранилища. \
        Иначе удалите ноду только из remote-control (node delete --name {name} --scope local), добавьте её снова \
        с профилем и примените: будут созданы новые ключи, конфигурации клиентов нужно сгенерировать заново.")
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

/// End the node's operation: a commit records what the operation uploaded.
fn conclude(node: &mut Node, committed: bool) {
    if let Some(operation) = node.operation.take()
        && committed
    {
        node.applied = (!operation.teardown).then(|| Applied {
            digest: operation.digest, files: operation.files, ports: operation.ports, at: crate::github::utc_stamp(),
        });
    }
}

/// Persist the end of operation `op_id` of node `id` (if it is still the recorded one).
fn finish_operation(session: &mut Session, id: &str, op_id: &str, committed: bool) -> Result<()> {
    session.mutate("node apply", |state| {
        let mut config = state.load_config()?;
        if let Some(node) = config.nodes.iter_mut()
            .find(|node| node.id == id && node.operation.as_ref().is_some_and(|operation| operation.id == op_id))
        {
            conclude(node, committed);
        }
        state.save_config(&config)
    })
}

/// A node whose new operation is to be recorded, or why it cannot be.
type Claim = (String, Result<Desired>);
/// A node with its recorded operation and the files to upload, or why not.
type Claimed = (String, Result<(Operation, Desired)>);

/// Under the configuration lock: re-check the agreed plan (`recheck` fails
/// with `plan_changed` and may settle finished operations in `config`), then
/// record a new operation for every node it returns. A node that already has
/// an operation is refused (`in_use`).
fn claim(session: &mut Session, label: &str, recheck: impl FnOnce(&State, &mut Config) -> Result<Vec<Claim>>)
    -> Result<Vec<Claimed>>
{
    session.mutate(label, |state| {
        let mut config = state.load_config()?;
        let mut claimed = Vec::new();
        for (id, desired) in recheck(state, &mut config)? {
            let Some(node) = config.nodes.iter_mut().find(|node| node.id == id) else { continue };
            let claim = match desired {
                Ok(_) if node.operation.is_some() => Err(RcError::new("in_use", format!(
                    "На ноде «{0}» уже выполняется применение: дождитесь его завершения (node apply --name {0}).", node.name))
                    .with_extra("name", node.name.clone())),
                Ok(desired) => {
                    let operation = Operation {
                        id: new_op_id(), digest: desired.digest.clone(), files: render::file_hashes(&desired.files),
                        ports: desired.ports.clone(), teardown: desired.teardown,
                    };
                    node.operation = Some(operation.clone());
                    Ok((operation, desired))
                }
                Err(error) => Err(error),
            };
            claimed.push((id, claim));
        }
        state.save_config(&config)?;
        Ok(claimed)
    })
}

enum Outcome { Committed, Failed(Failure) }

/// One node through start and polling.
struct Run<'t, T> {
    node: Node,
    transport: &'t mut T,
    operation: Operation,
    started: Instant,
    stage: String,
    lost: Option<(Instant, usize, Instant)>,
    outcome: Option<Outcome>,
}

impl<'t, T: RemoteTransport> Run<'t, T> {
    fn new(node: Node, transport: &'t mut T, operation: Operation) -> Self {
        Self { node, transport, operation, started: Instant::now(), stage: String::new(), lost: None, outcome: None }
    }

    fn fail(&mut self, failure: Failure) {
        self.outcome = Some(Outcome::Failed(failure));
    }

    /// The last stage seen, or `start` before the first one.
    fn current_stage(&self) -> String {
        if self.stage.is_empty() { "start".to_owned() } else { self.stage.clone() }
    }

    /// Upload the executor when needed, the operation directory, then start
    /// it. A failure before `systemd-run` means nothing started (`Err`). A
    /// connection lost during `systemd-run` leaves the start uncertain: the
    /// run goes on reconnecting and polling, so the remote status decides.
    async fn start(&mut self, session: &mut Session, agent_ok: bool, desired: &Desired) -> Result<()> {
        let name = self.node.name.clone();
        let op_id = self.operation.id.clone();
        if !agent_ok {
            let reset = self.transport.exec(&agent_reset_command(), b"", COMMAND_TIMEOUT).await?;
            if reset.exit_status != 0 {
                return Err(RcError::new("remote_failed", "Не удалось подготовить каталог исполнителя."));
            }
            let agent = materialize_agent()?;
            self.transport.upload(agent.path(), &agent_dir(), LONG_TIMEOUT).await?;
            session.log(Level::Info, &format!("{name}: исполнитель загружен"));
        }
        let dir = operation_dir(&op_id, desired)?;
        self.transport.upload_private(dir.path(), &ops_dir(&op_id), LONG_TIMEOUT).await?;
        match self.transport.exec(&start_command(&op_id), b"", COMMAND_TIMEOUT).await {
            Ok(started) if started.exit_status != 0 => Err(RcError::new("remote_failed", "Не удалось запустить исполнитель.")),
            Ok(_) => Ok(()),
            Err(_) => {
                session.log(Level::Warn, &format!("{name}: связь потеряна при запуске, проверяю состояние…"));
                let now = Instant::now();
                self.lost = Some((now, 0, now + Duration::from_secs(RECONNECT_PAUSES[0])));
                Ok(())
            }
        }
    }

    /// Print the tail of the executor log.
    async fn show_log(&mut self, session: &mut Session) {
        if let Ok(log) = self.transport.exec(&log_command(&self.operation.id), b"", COMMAND_TIMEOUT).await {
            for line in String::from_utf8_lossy(&log.stdout).lines() {
                session.log(Level::Output, line);
            }
        }
    }

    /// One poll: read the status or try to reconnect.
    async fn poll(&mut self, session: &mut Session) {
        let now = Instant::now();
        if now.duration_since(self.started) > OPERATION_LIMIT {
            return self.fail(Failure::new(&self.current_stage(), "timeout", "операция не завершилась за 60 минут"));
        }
        if let Some((since, attempt, next)) = self.lost {
            if now.duration_since(since) > OFFLINE_LIMIT {
                return self.fail(Failure::new(&self.current_stage(), "timeout", "нет связи с нодой больше 10 минут"));
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
        let status = match self.transport.exec(&status_command(&self.operation.id), b"", COMMAND_TIMEOUT).await {
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
            Some("committed") => self.outcome = Some(Outcome::Committed),
            Some(result) => {
                let stage = status.get("error").cloned().unwrap_or_else(|| self.current_stage());
                self.show_log(session).await;
                let failure = match (result, stage.as_str()) {
                    (_, "locked") => Failure::new(&self.current_stage(), "failed", "на ноде выполняется другая операция"),
                    ("rolled_back", _) => Failure::new(&stage, "rolled_back", format!("откат на этапе «{}»", stage_label(&stage))),
                    ("rollback_failed", _) => Failure::new(&stage, "rollback_failed",
                        format!("откат на этапе «{}» не завершён: резервные копии оставлены на ноде", stage_label(&stage))),
                    _ => Failure::new(&stage, "failed", format!("ошибка на этапе «{}»", stage_label(&stage))),
                };
                self.fail(failure);
            }
            None if unit_gone(&status) => {
                self.show_log(session).await;
                let stage = self.current_stage();
                self.fail(Failure::new(&stage, "failed",
                    format!("исполнитель остановился без результата на этапе «{}»", stage_label(&stage))));
            }
            None => {}
        }
    }

    /// Record the result: `applied` after a commit, the operation cleared
    /// always except after a timeout (the next `node apply` resumes it).
    fn record(&self, session: &mut Session) -> Result<()> {
        match &self.outcome {
            Some(Outcome::Committed) => finish_operation(session, &self.node.id, &self.operation.id, true),
            Some(Outcome::Failed(failure)) if failure.code != "timeout" => {
                finish_operation(session, &self.node.id, &self.operation.id, false)
            }
            _ => Ok(()),
        }
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

/// Start a claimed operation; a start that certainly did not happen clears
/// it again (an uncertain one is kept and settled by polling).
async fn launch<T: RemoteTransport>(session: &mut Session, run: &mut Run<'_, T>, agent_ok: bool, desired: &Desired)
    -> Result<()>
{
    if let Err(error) = run.start(session, agent_ok, desired).await {
        finish_operation(session, &run.node.id, &run.operation.id, false)?;
        return Err(error);
    }
    Ok(())
}

/// Planned work on one probed node.
struct Planned<T> {
    id: String,
    name: String,
    transport: T,
    digest: String,
    agent_ok: bool,
    sshd: Option<u16>,
    /// An unfinished operation to resume instead of starting a new one.
    resume: Option<String>,
    /// A finished or dead operation to record (`op_id`, committed) once the
    /// plan is confirmed.
    settle: Option<(String, bool)>,
    /// Run the executor (false: only the settlement is recorded).
    run: bool,
}

/// Connect and probe one node.
async fn probe<T: RemoteTransport>(session: &Session, transport: &mut T, node: &Node) -> std::result::Result<Probe, Failure> {
    let fail = |error: RcError| Failure::of("probe", error);
    nodes::require_portable(session, node).map_err(fail)?;
    nodes::connect_retrying(transport, &session.state, node).await.map_err(fail)?;
    let result = transport.exec(&probe_command(node), b"", COMMAND_TIMEOUT).await.map_err(fail)?;
    let probe = parse_probe(&String::from_utf8_lossy(&result.stdout));
    if !matches!(probe.os.as_str(), "debian" | "ubuntu") || !probe.systemd {
        return Err(Failure::new("probe", "unsupported_os", "нужна Debian или Ubuntu с systemd"));
    }
    Ok(probe)
}

/// A port the node does not listen on for us yet is taken by someone else.
fn busy_port(probe: &Probe, node: &Node, desired: &Desired) -> Option<Failure> {
    let ours: Vec<&String> = node.applied.iter().flat_map(|applied| &applied.ports)
        .chain(node.operation.iter().flat_map(|operation| &operation.ports)).collect();
    desired.ports.iter().filter(|rule| !ours.contains(rule)).find_map(|rule| {
        let (port, proto) = rule.split_once('/').and_then(|(port, proto)| Some((port.parse::<u16>().ok()?, proto)))?;
        probe.listening.iter().any(|(listening, busy)| listening == proto && *busy == port).then(|| Failure {
            port: Some(port), ..Failure::new("probe", "port_busy", format!("порт {port} уже занят"))
        })
    })
}

/// `node apply (--name N… | --profile P | --pending) [--yes]`.
pub async fn apply<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, connect: &dyn Fn() -> T) -> Result<Value> {
    let config = session.state.load_config()?;
    let names = targets(&config, invocation)?;
    let mut report = Report::default();
    let mut planned: Vec<Planned<T>> = Vec::new();
    let mut lines = Vec::new();
    let mut extra = Vec::new();
    // An explicitly named node reports its configuration problem (`domain_required`)
    // so the front end can resolve it and repeat; in bulk it fails the node.
    let named = invocation.has("name");
    for name in &names {
        let mut node = nodes::find(&config, name)?.clone();
        let mut desired = match render::desired(&config, &node, None) {
            Ok(desired) => desired,
            Err(error) if named => return Err(error),
            Err(error) => {
                report.fail(session, name, &Failure::of("probe", error));
                continue;
            }
        };
        let mut transport = connect();
        session.log(Level::Info, &format!("Проверка ноды {name}…"));
        let probe = match probe(session, &mut transport, &node).await {
            Ok(probe) => probe,
            Err(failure) => {
                report.fail(session, name, &failure);
                continue;
            }
        };
        let mut resume = None;
        let mut settle = None;
        if let Some(operation) = node.operation.clone() {
            let result = probe.status.get("result").map(String::as_str);
            if result.is_none() && !unit_gone(&probe.status) {
                resume = Some(operation.id);
            } else {
                // Finished while nobody watched, or the executor died: the plan
                // is built on the settled node; the settlement is recorded only
                // after confirmation, under the lock (`claim`).
                let committed = result == Some("committed");
                lines.push(match result {
                    Some("committed") => format!("{name}: прошлое применение завершилось успешно — результат будет записан."),
                    Some(_) => format!("{name}: прошлое применение завершилось неудачно — отметка будет снята."),
                    None => format!("{name}: прошлое применение прервано без результата — отметка будет снята."),
                });
                extra.push(format!("settle:{name}:{}:{committed}", operation.id));
                conclude(&mut node, committed);
                settle = Some((operation.id, committed));
                desired = match render::desired(&config, &node, None) {
                    Ok(desired) => desired,
                    Err(error) if named => return Err(error),
                    Err(error) => {
                        report.fail(session, name, &Failure::of("probe", error));
                        continue;
                    }
                };
            }
        }
        if let Some(failure) = busy_port(&probe, &node, &desired) {
            report.fail(session, name, &failure);
            continue;
        }
        let applied = node.applied.as_ref();
        let drift: Vec<&String> = applied.iter().flat_map(|applied| applied.files.iter())
            .filter(|(path, hash)| desired.files.iter().any(|file| file.path == **path)
                && probe.hashes.get(*path).is_some_and(|remote| remote.as_ref() != Some(hash)))
            .map(|(path, _)| path).collect();
        let run = resume.is_some() || !drift.is_empty() || !applied.is_some_and(|applied| applied.digest == desired.digest);
        if !run && settle.is_none() {
            report.unchanged.push(name.clone());
            continue;
        }
        if run {
            lines.extend(desired.lines.iter().cloned());
            if resume.is_some() {
                lines.push(format!("{name}: продолжается незавершённое применение."));
            }
            if let Some(sshd) = probe.sshd.filter(|port| *port != node.port && !desired.teardown) {
                lines.push(format!("SSH на ноде слушает порт {sshd}: при включении UFW он тоже будет разрешён."));
            }
            lines.extend(drift.iter().map(|path| format!("Изменено вручную, будет перезаписано: {path}")));
            extra.push(format!("{name}={}", desired.digest));
            extra.extend(drift.iter().map(|path| format!("drift:{name}:{path}")));
        }
        planned.push(Planned {
            id: node.id.clone(), name: name.clone(), transport, digest: desired.digest, agent_ok: probe.agent_ok,
            sshd: probe.sshd, resume, settle, run,
        });
    }
    if planned.is_empty() {
        return report.finish();
    }
    extra.sort();
    let plan = Plan::new(lines, extra.join("\n"));
    plan.confirm(invocation)?;

    let mut claims = claim(session, "node apply start", |state, config| {
        let mut claims = Vec::new();
        for item in &planned {
            let node = config.nodes.iter_mut().find(|node| node.name == item.name)
                .ok_or_else(|| plan.changed(invocation))?;
            if let Some((op_id, committed)) = &item.settle {
                if node.operation.as_ref().map(|operation| &operation.id) != Some(op_id) {
                    return Err(plan.changed(invocation));
                }
                conclude(node, *committed);
            }
            let node = nodes::find(config, &item.name)?;
            let digest = render::desired(config, node, None).map(|desired| desired.digest).ok();
            if node.id != item.id || node.operation.as_ref().map(|operation| &operation.id) != item.resume.as_ref()
                || digest.as_deref() != Some(item.digest.as_str())
            {
                return Err(plan.changed(invocation));
            }
            if item.run && item.resume.is_none() {
                claims.push((node.id.clone(), node_secrets(state, config, node)
                    .and_then(|secrets| render::desired(config, node, Some(&secrets)))));
            }
        }
        Ok(claims)
    })?;
    let config = session.state.load_config()?;
    let mut runs = Vec::new();
    for item in &mut planned {
        if !item.run {
            report.unchanged.push(item.name.clone());
            continue;
        }
        let node = nodes::find(&config, &item.name)?.clone();
        if item.resume.is_some() {
            let Some(operation) = node.operation.clone() else { continue };
            session.log(Level::Info, &format!("{}: продолжаю незавершённое применение", item.name));
            runs.push(Run::new(node, &mut item.transport, operation));
            continue;
        }
        let Some(index) = claims.iter().position(|(id, _)| *id == item.id) else { continue };
        let (operation, mut desired) = match claims.swap_remove(index).1 {
            Ok(claimed) => claimed,
            Err(error) => {
                report.fail(session, &item.name, &Failure::of("start", error));
                continue;
            }
        };
        if let Some(port) = item.sshd {
            desired.add_ssh_port(port);
        }
        let mut run = Run::new(node, &mut item.transport, operation);
        if let Err(error) = launch(session, &mut run, item.agent_ok, &desired).await {
            report.fail(session, &item.name, &Failure::new("start", "start", format!("не удалось запустить применение: {}", error.message)));
            continue;
        }
        session.log(Level::Info, &format!("{}: применение запущено", item.name));
        runs.push(run);
    }
    drive(session, &mut runs).await;
    for run in &runs {
        run.record(session)?;
        match &run.outcome {
            Some(Outcome::Committed) => {
                session.log(Level::Success, &format!("{}: применено", run.node.name));
                report.applied.push(run.node.name.clone());
            }
            Some(Outcome::Failed(failure)) => report.fail(session, &run.node.name, failure),
            None => {}
        }
    }
    report.finish()
}

/// Remove everything Essence installed on a connected node (`node delete
/// --scope server`). `Ok` only after the executor committed. A node with a
/// recorded operation is refused (`in_use`).
pub async fn teardown<T: RemoteTransport>(session: &mut Session, node: &Node, transport: &mut T) -> Result<()> {
    let output = transport.exec(&probe_command(&Node { applied: None, operation: None, ..node.clone() }), b"", COMMAND_TIMEOUT).await?;
    let probe = parse_probe(&String::from_utf8_lossy(&output.stdout));
    let claims = claim(session, "node delete", |_, config| {
        let current = config.nodes.iter().find(|current| current.id == node.id)
            .ok_or_else(|| RcError::new("not_found", format!("Нода «{}» не найдена.", node.name)))?;
        Ok(vec![(current.id.clone(), Ok(render::teardown(current)))])
    })?;
    let (operation, mut desired) = claims.into_iter().next().map(|(_, claim)| claim)
        .unwrap_or_else(|| Err(RcError::new("not_found", format!("Нода «{}» не найдена.", node.name))))?;
    if let Some(port) = probe.sshd {
        desired.add_ssh_port(port);
    }
    let mut run = Run::new(node.clone(), transport, operation);
    launch(session, &mut run, probe.agent_ok, &desired).await?;
    drive(session, std::slice::from_mut(&mut run)).await;
    run.record(session)?;
    match run.outcome.take() {
        Some(Outcome::Committed) => Ok(()),
        Some(Outcome::Failed(failure)) => {
            Err(RcError::new("remote_failed", failure.message).with_extra("stage", failure.stage).with_extra("code", failure.code))
        }
        None => Err(RcError::new("remote_failed", "Снятие не завершено.")),
    }
}

#[cfg(test)]
pub(crate) mod tests;
