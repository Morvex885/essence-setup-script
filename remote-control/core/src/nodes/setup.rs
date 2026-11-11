//! `node setup-ssh` and portable SSH keys (v1 `hardening.sh`:
//! `onboarding_plan_lines`, `_github_initial_portable_onboarding`,
//! `_provision_portable_identity`, `_revoke_managed_remote_key_value`).
//!
//! Onboarding runs in two halves: every remote step first (server key
//! fingerprints agreed in the plan, new keys installed and verified, each
//! through a held session kept as its revocation channel), then one state
//! change (`Onboarding::apply`). A failure before the state change revokes
//! the installed keys, so nothing has to be restored locally.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use russh::keys::ssh_key::{LineEnding, private::{Ed25519Keypair, KeypairData}};
use russh::keys::{HashAlg, PrivateKey, PublicKey};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{COMMAND_TIMEOUT, CONNECT_TIMEOUT, connect_options, is_github, pins, set_issue, sh_quote};
use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::locking::LockKind;
use crate::log::Level;
use crate::model::{Auth, Config, Fingerprint, KnownHosts, Manifest, Node, PortabilityReason, PortabilityStatus, endpoint_key};
use crate::secure_fs;
use crate::state::{State, read_optional};
use crate::transport::{Authentication, ConnectOptions, HostKeyPolicy, RemoteSession, RemoteTransport, remote_failure};

pub type Log<'a> = dyn FnMut(Level, &str) + 'a;

// ─── Remote commands ─────────────────────────────────────────────────────────

/// Run a remote command; a non-zero exit is `remote_failed`.
pub(crate) async fn run<S: RemoteSession>(session: &S, command: &str, timeout: Duration) -> Result<String> {
    let result = session.exec(command, b"", timeout).await?;
    if result.exit_status != 0 {
        return Err(remote_failure("exit_status").with_extra("exit_status", result.exit_status));
    }
    Ok(String::from_utf8_lossy(&result.stdout).into_owned())
}

/// Append `public` to `~/.ssh/authorized_keys` unless the exact line exists;
/// a last line without a newline is terminated first.
pub fn install_command(public: &str) -> String {
    let key = sh_quote(public);
    format!("mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
{{ grep -qxF -e {key} ~/.ssh/authorized_keys || {{ if [ -s ~/.ssh/authorized_keys ] && [ -n \"$(tail -c 1 ~/.ssh/authorized_keys)\" ]; then \
echo >> ~/.ssh/authorized_keys; fi && printf '%s\\n' {key} >> ~/.ssh/authorized_keys; }}; }}")
}

/// Remove every line equal to `public` from `~/.ssh/authorized_keys`.
pub fn revoke_command(public: &str) -> String {
    let key = sh_quote(public);
    format!("if [ -f ~/.ssh/authorized_keys ]; then _essence_tmp=$(mktemp ~/.ssh/authorized_keys.XXXXXX) && \
_essence_key={key} awk '$0 != ENVIRON[\"_essence_key\"]' ~/.ssh/authorized_keys > \"$_essence_tmp\" && cat \"$_essence_tmp\" > ~/.ssh/authorized_keys && \
rm -f \"$_essence_tmp\"; fi")
}

pub async fn revoke<S: RemoteSession>(session: &S, public: &str) -> Result<()> {
    run(session, &revoke_command(public), COMMAND_TIMEOUT).await.map(drop)
}

/// SHA256 fingerprint of an OpenSSH public key line (empty when unparsable).
pub fn public_fingerprint(public: &str) -> String {
    PublicKey::from_openssh(public.trim()).map(|key| key.fingerprint(HashAlg::Sha256).to_string()).unwrap_or_default()
}

/// Revoke and report a key that could not be revoked; true when revoked.
async fn revoke_logged<S: RemoteSession>(session: &S, name: &str, public: &str, log: &mut Log<'_>) -> bool {
    if revoke(session, public).await.is_ok() {
        return true;
    }
    log(Level::Warn, &format!("Не удалось отозвать переносимый SSH-ключ ноды «{name}». Удалите его из authorized_keys вручную (отпечаток {}).",
        public_fingerprint(public)));
    false
}

// ─── Portable keys ───────────────────────────────────────────────────────────

/// Prior bytes of a set of files; `restore` puts them back (absent → removed).
pub struct FileBackup(Vec<(PathBuf, Option<Zeroizing<Vec<u8>>>)>);

impl FileBackup {
    pub fn take(paths: impl IntoIterator<Item = PathBuf>) -> Result<Self> {
        let mut files = Vec::new();
        for path in paths {
            let bytes = read_optional(&path)?;
            files.push((path, bytes));
        }
        Ok(Self(files))
    }

    pub fn restore(&self) -> Result<()> {
        let mut result = Ok(());
        for (path, bytes) in &self.0 {
            let restored = match bytes {
                Some(bytes) => secure_fs::atomic_write(path, bytes),
                None => std::fs::remove_file(path).or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) }),
            };
            if let Err(error) = restored {
                result = Err(error.into());
            }
        }
        result
    }
}

/// Managed identity files of a node: `<identities>/<id>` and `<id>.pub`.
pub fn identity_paths(state: &State, node_id: &str) -> [PathBuf; 2] {
    let dir = state.paths().identities();
    [dir.join(node_id), dir.join(format!("{node_id}.pub"))]
}

#[cfg(test)]
thread_local! {
    /// Deterministic key material for scripted remote commands in tests.
    pub(crate) static TEST_SEED: std::cell::Cell<Option<[u8; 32]>> = const { std::cell::Cell::new(None) };
}

fn seed() -> Zeroizing<[u8; 32]> {
    #[cfg(test)]
    if let Some(seed) = TEST_SEED.with(std::cell::Cell::get) {
        return Zeroizing::new(seed);
    }
    let mut seed = Zeroizing::new([0u8; 32]);
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut *seed);
    seed
}

fn key_error() -> RcError {
    RcError::new("failed", "Не удалось сгенерировать переносимый SSH-ключ.")
}

/// A new ed25519 key of a node, staged in a private temporary directory
/// until `store` writes it into the managed identities.
pub struct PortableKey {
    pub node_id: String,
    /// OpenSSH public key line (`ssh-ed25519 … essence:<id>`), no newline.
    pub public: String,
    private: Zeroizing<String>,
    dir: tempfile::TempDir,
}

impl PortableKey {
    fn generate(root: &Path, node_id: &str) -> Result<Self> {
        let key = PrivateKey::new(KeypairData::Ed25519(Ed25519Keypair::from_seed(&seed())), format!("essence:{node_id}"))
            .map_err(|_| key_error())?;
        let private = key.to_openssh(LineEnding::LF).map_err(|_| key_error())?;
        let public = key.public_key().to_openssh().map_err(|_| key_error())?;
        secure_fs::create_dir_all(root)?;
        let dir = tempfile::Builder::new().prefix(".identity.").tempdir_in(root)?;
        secure_fs::atomic_write(&dir.path().join(node_id), private.as_bytes())?;
        Ok(Self { node_id: node_id.to_owned(), public, private, dir })
    }

    /// The staged private key (connect with `Authentication::Key`).
    pub fn private_path(&self) -> PathBuf {
        self.dir.path().join(&self.node_id)
    }

    pub fn fingerprint(&self) -> String {
        public_fingerprint(&self.public)
    }

    /// Write `<id>` (OpenSSH PEM) and `<id>.pub` into the managed identities;
    /// the returned backup restores the previous pair.
    pub fn store(&self, state: &State) -> Result<FileBackup> {
        let backup = FileBackup::take(identity_paths(state, &self.node_id))?;
        if let Err(error) = self.write(state) {
            let _ = backup.restore();
            return Err(error);
        }
        Ok(backup)
    }

    fn write(&self, state: &State) -> Result<()> {
        let [private, public] = identity_paths(state, &self.node_id);
        secure_fs::create_dir_all(state.paths().identities())?;
        secure_fs::atomic_write(&private, self.private.as_bytes())?;
        secure_fs::atomic_write(&public, format!("{}\n", self.public).as_bytes())?;
        Ok(())
    }
}

/// A failed provisioning; `revoked` is false only when an installed key
/// could not be removed from the server again.
pub(crate) struct KeyFailure {
    pub error: RcError,
    pub revoked: bool,
}

/// v1 `_provision_portable_identity` over an authenticated `transport`:
/// install the new public key, then verify it on a fresh connect. Every
/// failure after the install attempt revokes through `held`.
pub(crate) async fn provision_with<T: RemoteTransport, H: RemoteSession>(transport: &mut T, held: &H, state: &State,
    node: &Node, pins: Vec<Fingerprint>, log: &mut Log<'_>) -> std::result::Result<PortableKey, KeyFailure>
{
    let key = PortableKey::generate(state.paths().root(), &node.id).map_err(|error| {
        log(Level::Warn, "Не удалось сгенерировать переносимый SSH-ключ.");
        KeyFailure { error, revoked: true }
    })?;
    log(Level::Info, "Копируем открытый переносимый SSH-ключ на сервер...");
    if let Err(error) = run(&*transport, &install_command(&key.public), COMMAND_TIMEOUT).await {
        log(Level::Warn, "Не удалось скопировать переносимый SSH-ключ на сервер.");
        let revoked = revoke_logged(held, &node.name, &key.public, log).await;
        return Err(KeyFailure { error, revoked });
    }
    log(Level::Info, "Проверяем авторизацию по переносимому SSH-ключу...");
    let options = ConnectOptions {
        host: node.ip.clone(), port: node.port, user: node.user.clone(),
        auth: Authentication::Key { identity: key.private_path(), passphrase: None },
        host_key: HostKeyPolicy { expected: None, known: pins }, timeout: CONNECT_TIMEOUT,
    };
    if let Err(error) = transport.connect(options).await {
        log(Level::Warn, "Авторизация по переносимому SSH-ключу не работает.");
        let revoked = revoke_logged(held, &node.name, &key.public, log).await;
        return Err(KeyFailure { error, revoked });
    }
    log(Level::Success, "Переносимый SSH-ключ установлен");
    Ok(key)
}

/// Provision a portable key for `node` over a `transport` already connected
/// and authenticated as the node. On success the transport is connected with
/// the new key; nothing is written to the state (see `PortableKey::store`).
/// A failed verification revokes the key through a held session.
pub async fn provision<T: RemoteTransport>(transport: &mut T, state: &State, node: &Node, pins: Vec<Fingerprint>,
    log: &mut Log<'_>) -> Result<PortableKey>
{
    let held = transport.hold()?;
    provision_with(transport, &held, state, node, pins, log).await.map_err(|failure| failure.error)
}

// ─── Onboarding ──────────────────────────────────────────────────────────────

/// Key-auth nodes using the operator's own SSH identity (no portable key).
pub fn needs_identity(node: &Node) -> bool {
    node.auth == Auth::Key && matches!(node.identity.as_deref(), None | Some("" | "system"))
}

fn keyless(config: &Config) -> Vec<String> {
    config.nodes.iter().filter(|node| needs_identity(node)).map(|node| node.name.clone()).collect()
}

fn pinned(known: &KnownHosts, node: &Node) -> bool {
    pins(known, node).is_ok_and(|pins| !pins.is_empty())
}

/// The `--provision-keys` decision: required while keyless nodes exist.
pub fn provision_decision(config: &Config, provision: Option<bool>) -> Result<bool> {
    let names = keyless(config);
    match provision {
        Some(provision) => Ok(provision),
        None if names.is_empty() => Ok(false),
        None => Err(RcError::new("key_provisioning_required",
            "Нужно решить, создавать ли переносимый SSH-ключ для нод со входом по ключу.").with_extra("nodes", names)),
    }
}

/// Plan lines and the server key fingerprints agreed by them.
pub struct OnboardingPlan {
    pub lines: Vec<String>,
    provision: bool,
    /// Unpinned node id → fingerprints shown in the plan (empty: unreadable).
    agreed: BTreeMap<String, Vec<Fingerprint>>,
}

/// The server key of an unpinned endpoint, learned from the refusal of a
/// connect without pins (before any authentication).
async fn scan<T: RemoteTransport>(transport: &mut T, options: ConnectOptions) -> Vec<Fingerprint> {
    match transport.connect(options).await {
        Err(error) if error.code == "host_key_unknown" => error.extra.get("fingerprints").and_then(Value::as_array)
            .map(|list| list.iter().filter_map(|fp| fp.as_str()?.parse().ok()).collect()).unwrap_or_default(),
        _ => Vec::new(),
    }
}

/// v1 `onboarding_plan_lines` (read-only): portable keys to create and the
/// server keys of unpinned nodes that will be pinned.
pub async fn plan_onboarding<T: RemoteTransport>(transport: &mut T, state: &State, config: &Config, provision: bool)
    -> Result<OnboardingPlan>
{
    let known = state.load_known_hosts()?;
    let names = keyless(config).join(", ");
    let mut lines = Vec::new();
    if !names.is_empty() {
        lines.push(if provision {
            format!("Будет создан переносимый SSH-ключ: {names}")
        } else {
            format!("Без переносимого ключа, настройка останется отложенной: {names}")
        });
    }
    let mut agreed = BTreeMap::new();
    for node in &config.nodes {
        if pinned(&known, node) {
            continue;
        }
        let fingerprints = match connect_options(state, node, None) {
            Err(error) if error.code == "missing_secret" => {
                lines.push(format!("Пароль SSH ноды {} не сохранён: SSH-настройка останется отложенной.", node.name));
                continue;
            }
            Err(_) => {
                lines.push(format!("Нода {}: запись повреждена, SSH-настройка не выполнится.", node.name));
                agreed.insert(node.id.clone(), Vec::new());
                continue;
            }
            Ok(options) => scan(transport, options).await,
        };
        lines.push(if fingerprints.is_empty() {
            format!("Ключ сервера {} ({}:{}) прочитать не удалось: закрепление не выполнится.", node.name, node.ip, node.port)
        } else {
            let list: Vec<&str> = fingerprints.iter().map(Fingerprint::as_str).collect();
            format!("Ключ сервера {} ({}:{}) будет закреплён: {}", node.name, node.ip, node.port, list.join(", "))
        });
        agreed.insert(node.id.clone(), fingerprints);
    }
    Ok(OnboardingPlan { lines, provision, agreed })
}

struct Installed<H> {
    name: String,
    key: PortableKey,
    /// Session authenticated before the key was installed: its revocation channel.
    held: H,
}

/// Remote results of onboarding, not yet recorded in the state.
pub struct Onboarding<H> {
    installed: Vec<Installed<H>>,
    pins: Vec<(String, u16, Vec<Fingerprint>)>,
}

fn onboarding_failed(node: &str, step: &str, rolled_back: bool) -> RcError {
    let message = if rolled_back {
        format!("Не удалось настроить SSH для ноды «{node}». Изменения отменены.")
    } else {
        format!("Не удалось настроить SSH для ноды «{node}». Не все изменения отменены: проверьте authorized_keys на сервере.")
    };
    RcError::new("onboarding_failed", message)
        .with_extra("node", node).with_extra("step", step).with_extra("rolled_back", rolled_back)
}

/// v1 `_github_portable_onboarding_steps` without state writes: pin agreed
/// server keys (in memory) and provision portable keys for keyless nodes.
/// `defer` keeps a failing node pending and continues; otherwise the first
/// failure revokes every installed key and returns `onboarding_failed`.
pub async fn onboard<T: RemoteTransport>(transport: &mut T, state: &State, config: &Config, plan: &OnboardingPlan,
    defer: bool, log: &mut Log<'_>) -> Result<Onboarding<T::Held>>
{
    let mut onboarding = Onboarding { installed: Vec::new(), pins: Vec::new() };
    let mut failure = None;
    for node in &config.nodes {
        let pin_failed = |log: &mut Log<'_>| if defer {
            log(Level::Warn, &format!("Не удалось закрепить SSH-ключ ноды «{}»; SSH-настройка отложена.", node.name));
            None
        } else {
            log(Level::Warn, &format!("Не удалось закрепить SSH-ключ ноды «{}».", node.name));
            Some((node.name.clone(), "pin", true))
        };
        let mut options = match connect_options(state, node, None) {
            Ok(options) => options,
            Err(error) if error.code == "missing_secret" => continue,
            Err(_) => {
                failure = pin_failed(log);
                if failure.is_some() { break } else { continue }
            }
        };
        let mut new_pin = false;
        if options.host_key.known.is_empty() {
            match plan.agreed.get(&node.id) {
                Some(fingerprints) if !fingerprints.is_empty() => {
                    options.host_key.known = fingerprints.clone();
                    onboarding.pins.push((node.ip.clone(), node.port, fingerprints.clone()));
                    new_pin = true;
                }
                _ => {
                    failure = pin_failed(log);
                    if failure.is_some() { break } else { continue }
                }
            }
        }
        if !needs_identity(node) || !plan.provision {
            continue;
        }
        let pins = options.host_key.known.clone();
        if let Err(error) = transport.connect(options).await {
            if error.code.starts_with("host_key") {
                if new_pin {
                    onboarding.pins.pop();
                }
                failure = pin_failed(log);
            } else if defer {
                log(Level::Warn, &format!("Переносимый SSH-ключ ноды «{}» не создан; SSH-настройка отложена.", node.name));
            } else {
                failure = Some((node.name.clone(), "provision", true));
            }
            if failure.is_some() { break } else { continue }
        }
        let held = match transport.hold() {
            Ok(held) => held,
            Err(_) if defer => continue,
            Err(_) => {
                failure = Some((node.name.clone(), "provision", true));
                break;
            }
        };
        match provision_with(transport, &held, state, node, pins, log).await {
            Ok(key) => onboarding.installed.push(Installed { name: node.name.clone(), key, held }),
            Err(_) if defer => {
                log(Level::Warn, &format!("Переносимый SSH-ключ ноды «{}» не создан; SSH-настройка отложена.", node.name));
            }
            Err(error) => {
                failure = Some((node.name.clone(), "provision", error.revoked));
                break;
            }
        }
    }
    if let Some((name, step, revoked)) = failure {
        let rolled_back = onboarding.revoke(log).await && revoked;
        return Err(onboarding_failed(&name, step, rolled_back));
    }
    Ok(onboarding)
}

/// Recompute the SSH-setup issues of every node from config and pins.
fn derive_issues(manifest: &mut Manifest, config: &Config, known: &KnownHosts) {
    for node in &config.nodes {
        set_issue(manifest, &node.id, PortabilityReason::MissingIdentity, needs_identity(node));
        set_issue(manifest, &node.id, PortabilityReason::MissingHostKey, !pinned(known, node));
    }
}

impl<H: RemoteSession> Onboarding<H> {
    /// Names of the nodes that received a new portable key.
    pub fn installed(&self) -> Vec<String> {
        self.installed.iter().map(|installed| installed.name.clone()).collect()
    }

    /// Record pins, key files and `identity` (and with `issues` the manifest
    /// portability issues). Caller holds the mutation lock. On error every
    /// touched file is restored; on success the backup undoes the change.
    pub fn apply(&self, state: &State, issues: bool) -> Result<FileBackup> {
        let mut files = vec![state.paths().config().to_path_buf(), state.paths().known_hosts().to_path_buf()];
        if issues {
            files.push(state.paths().manifest().to_path_buf());
        }
        for installed in &self.installed {
            files.extend(identity_paths(state, &installed.key.node_id));
        }
        let backup = FileBackup::take(files)?;
        let result = (|| {
            let mut known = state.load_known_hosts()?;
            if !self.pins.is_empty() {
                for (host, port, fingerprints) in &self.pins {
                    known.0.insert(endpoint_key(host, *port)?, fingerprints.clone());
                }
                state.save_known_hosts(&known)?;
            }
            let mut config = state.load_config()?;
            if !self.installed.is_empty() {
                for installed in &self.installed {
                    installed.key.write(state)?;
                    if let Some(node) = config.nodes.iter_mut().find(|node| node.id == installed.key.node_id) {
                        node.identity = Some(installed.key.node_id.clone());
                    }
                }
                state.save_config(&config)?;
            }
            if issues {
                let mut manifest = state.load_manifest()?;
                derive_issues(&mut manifest, &config, &known);
                state.save_manifest(&manifest)?;
            }
            Ok(())
        })();
        if let Err(error) = result {
            let _ = backup.restore();
            return Err(error);
        }
        Ok(backup)
    }

    /// Revoke every installed key through its held session; true when all were.
    pub async fn revoke(&self, log: &mut Log<'_>) -> bool {
        let mut revoked = true;
        for installed in &self.installed {
            revoked &= revoke_logged(&installed.held, &installed.name, &installed.key.public, log).await;
        }
        revoked
    }
}

/// Onboarding applied to the device-local state before it moves to GitHub
/// (v1 `_github_initial_portable_onboarding … rollback` in source.sh).
pub struct LocalOnboarding<H> {
    onboarding: Onboarding<H>,
    backup: FileBackup,
}

/// Run the agreed onboarding against the device-local `state` (rollback
/// mode) and record it there, so the snapshot serialized next carries it.
pub async fn onboard_local<T: RemoteTransport>(transport: &mut T, state: &State, config: &Config, plan: &OnboardingPlan,
    log: &mut Log<'_>) -> Result<LocalOnboarding<T::Held>>
{
    let onboarding = onboard(transport, state, config, plan, false, log).await?;
    let applied = state.locks().acquire(LockKind::Mutation, "github-onboarding")
        .and_then(|_guard| onboarding.apply(state, false));
    match applied {
        Ok(backup) => Ok(LocalOnboarding { onboarding, backup }),
        Err(error) => {
            onboarding.revoke(log).await;
            Err(error)
        }
    }
}

impl<H: RemoteSession> LocalOnboarding<H> {
    /// A later step failed: revoke the installed keys and restore the files.
    pub async fn cancel(self, log: &mut Log<'_>) {
        self.onboarding.revoke(log).await;
        if self.backup.restore().is_err() {
            log(Level::Warn, "Не удалось восстановить SSH-настройку нод этого компьютера после сбоя.");
        }
    }
}

// ─── node setup-ssh ──────────────────────────────────────────────────────────

fn actionable(manifest: &Manifest) -> bool {
    manifest.portability.issues.iter()
        .any(|issue| matches!(issue.reason, PortabilityReason::MissingIdentity | PortabilityReason::MissingHostKey))
}

/// v1 `cli_cmd_node_setup_ssh` + `core_node_setup_ssh` (GitHub only).
pub async fn setup_ssh<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, transport: &mut T) -> Result<Value> {
    let provision = match invocation.value("provision-keys") {
        None => None,
        Some("yes") => Some(true),
        Some("no") => Some(false),
        Some(_) => return Err(RcError::new("usage", "Флаг --provision-keys принимает yes или no.")),
    };
    let defer = match invocation.value("on-failure") {
        None | Some("rollback") => false,
        Some("defer") => true,
        Some(_) => return Err(RcError::new("usage", "Флаг --on-failure принимает rollback или defer.")),
    };
    if !is_github(session) {
        return Err(RcError::new("invalid", "Отложенная SSH-настройка доступна только для источника GitHub."));
    }
    if !actionable(&session.state.load_manifest()?) {
        return Err(RcError::new("nothing_pending", "Отложенной SSH-настройки нод нет."));
    }
    let config = session.state.load_config()?;
    let provision = provision_decision(&config, provision)?;
    let state = State::with_locks(session.state.paths().clone(), session.state.locks().clone());
    let plan = plan_onboarding(transport, &state, &config, provision).await?;
    let names: Vec<&str> = config.nodes.iter().map(|node| node.name.as_str()).collect();
    let mut lines = vec![format!("Ноды: {}", names.join(", "))];
    lines.extend(plan.lines.iter().cloned());
    lines.push(if defer { "При сбое проблемная нода останется отложенной." } else { "При сбое все изменения будут отменены." }.into());
    Plan::new(lines, "").confirm(invocation)?;

    let _guard = state.locks().acquire(LockKind::Mutation, "complete_portable_node_setup")?;
    let onboarding = onboard(transport, &state, &config, &plan, defer, &mut |level, text| session.log(level, text)).await?;
    if let Err(error) = session.mutate("complete_portable_node_setup", |state| onboarding.apply(state, true).map(drop)) {
        onboarding.revoke(&mut |level, text| session.log(level, text)).await;
        return Err(error);
    }

    let manifest = session.state.load_manifest()?;
    let config = session.state.load_config()?;
    let ready = manifest.portability.status == PortabilityStatus::Ready;
    let pending = actionable(&manifest);
    if ready {
        session.log(Level::Success, "Отложенная SSH-настройка нод завершена: SSH-ключи и ключи серверов готовы для синхронизации через GitHub.");
    } else if pending {
        session.log(Level::Warn, "Для части нод SSH-настройка всё ещё отложена. Повторите node setup-ssh позже.");
    } else {
        session.log(Level::Warn, "SSH-ключи настроены, но другим нодам требуются защищённые данные для входа.");
    }
    let deferred: Vec<Value> = manifest.portability.issues.iter().map(|issue| {
        let name = config.nodes.iter().find(|node| node.id == issue.node_id).map_or(issue.node_id.as_str(), |node| node.name.as_str());
        json!({"name": name, "issue": issue.reason})
    }).collect();
    Ok(json!({"ready": ready, "installed": onboarding.installed(), "deferred": deferred, "pending": pending}))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeTransport, Operation, ScriptStep};
    use crate::github::commands::GithubSession;
    use crate::github::store::WorkSession;
    use crate::github::{BRANCH, REPO_NAME, Storage, SyncStatus, Target};
    use crate::model::{Portability, PortabilityIssue};
    use crate::nodes::testing;
    use crate::transport::ExecResult;

    pub(crate) const SEED: [u8; 32] = [7; 32];
    pub(crate) const FP1: &str = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const FP2: &str = "SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA";

    /// The public line `provision` generates for `node_id` under `SEED`.
    pub(crate) fn test_public(node_id: &str) -> String {
        TEST_SEED.with(|seed| seed.set(Some(SEED)));
        let dir = tempfile::tempdir().unwrap();
        PortableKey::generate(dir.path(), node_id).unwrap().public
    }

    pub(crate) fn fp(text: &str) -> Fingerprint {
        text.parse().unwrap()
    }

    pub(crate) fn ok(stdout: &str) -> crate::error::Result<ExecResult> {
        Ok(ExecResult { stdout: stdout.as_bytes().to_vec(), ..ExecResult::default() })
    }

    pub(crate) fn expect(host: &str, port: u16, auth: AuthMethod, known: &[&str]) -> ConnectExpectation {
        ConnectExpectation::new(host, port, "root", auth, CONNECT_TIMEOUT)
            .with_host_key(HostKeyPolicy { expected: None, known: known.iter().map(|f| fp(f)).collect() })
    }

    fn unknown(host: &str, fingerprint: &str) -> crate::error::Result<()> {
        Err(RcError::new("host_key_unknown", "unknown").with_extra("host", host).with_extra("port", 22)
            .with_extra("fingerprints", json!([fingerprint])))
    }

    fn key_node(id: &str, name: &str, ip: &str) -> Node {
        serde_json::from_value(json!({"id": id, "name": name, "ip": ip, "port": 22, "user": "root",
            "auth": "key", "identity": null, "secret_id": null})).unwrap()
    }

    /// A GitHub session over `root` with keyless nodes pending SSH setup;
    /// its worktree lives outside the data directory.
    fn github(root: &Path, worktree: &Path, nodes: &[Node]) -> (Session, testing::Journal) {
        let (mut session, journal) = testing::session(root);
        let mut config = session.state.load_config().unwrap();
        config.nodes = nodes.to_vec();
        session.state.save_config(&config).unwrap();
        let mut manifest = session.state.load_manifest().unwrap();
        let issues = nodes.iter().flat_map(|node| [PortabilityReason::MissingIdentity, PortabilityReason::MissingHostKey]
            .map(|reason| PortabilityIssue { node_id: node.id.clone(), reason })).collect();
        manifest.portability = Portability::from_issues(issues);
        session.state.save_manifest(&manifest).unwrap();
        std::fs::create_dir_all(worktree).unwrap();
        session.github = Some(GithubSession {
            target: Target::new("alice", REPO_NAME, BRANCH),
            work: Some(WorkSession { store: worktree.join("store"), sessions: worktree.join("sessions"), id: "t".into(),
                worktree: worktree.to_path_buf(), branch: BRANCH.into(), origin: String::new() }),
            storage: Storage::Plain, keys: None, sync: SyncStatus::Clean, last_counts: Value::Null, last_version: None,
        });
        (session, journal)
    }

    const ID1: &str = "11111111111111111111111111111111";
    const ID2: &str = "22222222222222222222222222222222";

    #[tokio::test]
    async fn decisions_and_plan_leave_the_data_directory_byte_identical() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("data");
        let (mut session, _) = github(&root, &dir.path().join("work"), &[key_node(ID1, "n1", "192.0.2.10")]);
        let before = testing::fingerprint(&root);

        let mut fake = FakeTransport::new([]);
        let error = setup_ssh(&mut session, &testing::invocation(&["node", "setup-ssh"]), &mut fake).await.unwrap_err();
        assert_eq!((error.code, error.extra["nodes"].clone()), ("key_provisioning_required", json!(["n1"])));
        fake.assert_finished();

        let mut tokens = Vec::new();
        for _ in 0..2 {
            let mut fake = FakeTransport::new([
                ScriptStep::connect(expect("192.0.2.10", 22, AuthMethod::System, &[]), unknown("192.0.2.10", FP1)),
            ]);
            let error = setup_ssh(&mut session, &testing::invocation(&["node", "setup-ssh", "--provision-keys", "yes"]), &mut fake)
                .await.unwrap_err();
            assert_eq!(error.code, "confirmation_required");
            assert_eq!(error.extra["plan"], json!(["Ноды: n1", "Будет создан переносимый SSH-ключ: n1",
                format!("Ключ сервера n1 (192.0.2.10:22) будет закреплён: {FP1}"), "При сбое все изменения будут отменены."]));
            tokens.push(error.extra["plan_token"].clone());
            fake.assert_finished();
        }
        assert_eq!(tokens[0], tokens[1]);
        assert_eq!(testing::fingerprint(&root), before);
    }

    #[tokio::test]
    async fn provisioning_installs_then_verifies_and_records_the_key() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("data");
        let (mut session, _) = github(&root, &dir.path().join("work"), &[key_node(ID1, "n1", "192.0.2.10")]);
        let public = test_public(ID1);
        let mut fake = FakeTransport::new([
            ScriptStep::connect(expect("192.0.2.10", 22, AuthMethod::System, &[]), unknown("192.0.2.10", FP1)),
            ScriptStep::connect(expect("192.0.2.10", 22, AuthMethod::System, &[FP1]), Ok(())),
            ScriptStep::exec(install_command(&public), 0, COMMAND_TIMEOUT, ok("")),
            ScriptStep::connect(expect("192.0.2.10", 22, AuthMethod::Key, &[FP1]), Ok(())),
        ]);
        let data = setup_ssh(&mut session, &testing::invocation(&["node", "setup-ssh", "--provision-keys", "yes", "--yes"]), &mut fake)
            .await.unwrap();
        fake.assert_finished();
        assert_eq!(data, json!({"ready": true, "installed": ["n1"], "deferred": [], "pending": false}));
        let kinds: Vec<&str> = fake.journal().iter().map(|op| match op {
            Operation::Connect(c) if c.auth == AuthMethod::Key => "verify",
            Operation::Connect(_) => "connect",
            Operation::Exec { command, .. } if command.contains(">> ~/.ssh/authorized_keys") => "install",
            Operation::Hold => "hold",
            _ => "other",
        }).collect();
        assert_eq!(kinds, ["connect", "connect", "hold", "install", "verify"]);

        let state = &session.state;
        let node = state.load_config().unwrap().nodes.remove(0);
        assert_eq!(node.identity.as_deref(), Some(ID1));
        assert_eq!(pins(&state.load_known_hosts().unwrap(), &node).unwrap(), vec![fp(FP1)]);
        assert_eq!(state.load_manifest().unwrap().portability, Portability::default());
        let [private, public_path] = identity_paths(state, ID1);
        assert_eq!(std::fs::read_to_string(public_path).unwrap(), format!("{public}\n"));
        let private = PrivateKey::from_openssh(std::fs::read(private).unwrap()).unwrap();
        assert_eq!(private.public_key().to_openssh().unwrap(), public, "the stored private key matches the installed public key");
        assert!(std::fs::read_dir(&root).unwrap().flatten().all(|e| !e.file_name().to_string_lossy().starts_with(".identity.")));
    }

    #[tokio::test]
    async fn a_failed_provision_revokes_every_installed_key_and_changes_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("data");
        let (mut session, _) = github(&root, &dir.path().join("work"),
            &[key_node(ID1, "n1", "192.0.2.10"), key_node(ID2, "n2", "192.0.2.11")]);
        let before = testing::fingerprint(&root);
        let (first, second) = (test_public(ID1), test_public(ID2));
        let mut fake = FakeTransport::new([
            ScriptStep::connect(expect("192.0.2.10", 22, AuthMethod::System, &[]), unknown("192.0.2.10", FP1)),
            ScriptStep::connect(expect("192.0.2.11", 22, AuthMethod::System, &[]), unknown("192.0.2.11", FP2)),
            ScriptStep::connect(expect("192.0.2.10", 22, AuthMethod::System, &[FP1]), Ok(())),
            ScriptStep::exec(install_command(&first), 0, COMMAND_TIMEOUT, ok("")),
            ScriptStep::connect(expect("192.0.2.10", 22, AuthMethod::Key, &[FP1]), Ok(())),
            ScriptStep::connect(expect("192.0.2.11", 22, AuthMethod::System, &[FP2]), Ok(())),
            ScriptStep::exec(install_command(&second), 0, COMMAND_TIMEOUT, ok("")),
            ScriptStep::connect(expect("192.0.2.11", 22, AuthMethod::Key, &[FP2]), Err(remote_failure("authentication"))),
            ScriptStep::exec(revoke_command(&second), 0, COMMAND_TIMEOUT, ok("")),
            ScriptStep::exec(revoke_command(&first), 0, COMMAND_TIMEOUT, ok("")),
        ]);
        let error = setup_ssh(&mut session, &testing::invocation(&["node", "setup-ssh", "--provision-keys", "yes", "--yes"]), &mut fake)
            .await.unwrap_err();
        fake.assert_finished();
        assert_eq!(error.code, "onboarding_failed");
        assert_eq!((error.extra["node"].clone(), error.extra["step"].clone(), error.extra["rolled_back"].clone()),
            (json!("n2"), json!("provision"), json!(true)));
        assert_eq!(testing::fingerprint(&root), before);
    }

    #[tokio::test]
    async fn defer_keeps_the_failing_node_pending_and_records_the_rest() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("data");
        let (mut session, _) = github(&root, &dir.path().join("work"),
            &[key_node(ID1, "n1", "192.0.2.10"), key_node(ID2, "n2", "192.0.2.11")]);
        let first = test_public(ID1);
        let mut fake = FakeTransport::new([
            ScriptStep::connect(expect("192.0.2.10", 22, AuthMethod::System, &[]), unknown("192.0.2.10", FP1)),
            ScriptStep::connect(expect("192.0.2.11", 22, AuthMethod::System, &[]), Err(remote_failure("connect"))),
            ScriptStep::connect(expect("192.0.2.10", 22, AuthMethod::System, &[FP1]), Ok(())),
            ScriptStep::exec(install_command(&first), 0, COMMAND_TIMEOUT, ok("")),
            ScriptStep::connect(expect("192.0.2.10", 22, AuthMethod::Key, &[FP1]), Ok(())),
        ]);
        let argv = ["node", "setup-ssh", "--provision-keys", "yes", "--on-failure", "defer", "--yes"];
        let data = setup_ssh(&mut session, &testing::invocation(&argv), &mut fake).await.unwrap();
        fake.assert_finished();
        assert_eq!(data, json!({"ready": false, "installed": ["n1"], "pending": true,
            "deferred": [{"name": "n2", "issue": "missing_identity"}, {"name": "n2", "issue": "missing_host_key"}]}));
    }
}
