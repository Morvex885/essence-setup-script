//! `source *` commands and the GitHub half of `session open` (v1 `source.sh`,
//! `cmd_core.sh` source handlers, `session.sh`). Decisions arrive as flags and
//! secrets; a missing decision is a `*_required` error before any change, and
//! every remote or destructive change happens after `Plan::confirm`.

use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::store::{self, Mode, PendingRepo, RepoDecisions, WorkSession};
use super::vault::{self, Keys, Snapshot};
use super::{BRANCH, REPO_NAME, Storage, SyncStatus, Target, fail, login_valid, prefixed, random_hex, utc_stamp};
use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::{DispatchMode, Session};
use crate::error::{RcError, Result};
use crate::locking::{LockKind, LockManager};
use crate::log::Level;
use crate::model::{Config, Source, SourceType};
use crate::nodes::setup::{self, LocalOnboarding, OnboardingPlan};
use crate::request_secrets::Secrets;
use crate::secure_fs;
use crate::state::{State, StatePaths, read_optional};
use crate::transport::{RemoteSession, RemoteTransport};

/// The open GitHub source of a session.
pub struct GithubSession {
    pub target: Target,
    pub work: Option<WorkSession>,
    pub storage: Storage,
    pub keys: Option<Keys>,
    pub sync: SyncStatus,
    /// `{nodes,clients,groups}` of the last snapshot read (recovery plans).
    pub last_counts: Value,
    /// `vault_version` of the last snapshot read.
    pub last_version: Option<u64>,
}

impl GithubSession {
    fn new(target: Target, work: WorkSession, sync: SyncStatus) -> Self {
        Self { target, work: Some(work), storage: Storage::Plain, keys: None, sync, last_counts: Value::Null, last_version: None }
    }

    pub fn work(&self) -> Result<&WorkSession> {
        self.work.as_ref().ok_or_else(|| fail("подготовка рабочей копии конфигурации", "Рабочая копия конфигурации GitHub недоступна."))
    }

    /// Write the snapshot into the worktree (nothing is committed).
    pub fn checkpoint(&self, snapshot: &Snapshot) -> Result<()> {
        vault::checkpoint(&self.work()?.worktree, self.storage, self.keys.as_ref(), snapshot)
    }

    pub fn flush(&mut self, paths: &StatePaths) -> Result<()> {
        let work = self.work()?.clone();
        store::flush(paths, &self.target, &work, self.storage, &mut self.sync)
    }

    pub fn close(&mut self) -> Result<()> {
        if let Some(work) = &self.work {
            store::close(work)?;
        }
        self.work = None;
        self.keys = None;
        Ok(())
    }

    /// v1 `github_config_open`: storage mode, allowlist, unlock, decrypt and the
    /// format check. Unlock order: this session's key, the remembered key,
    /// then the `vault-password` secret.
    pub fn read_vault(&mut self, paths: &StatePaths, secrets: &Secrets, remember: bool, migrate: bool,
        log: &mut dyn FnMut(Level, &str)) -> Result<Snapshot>
    {
        let worktree = self.work()?.worktree.clone();
        self.storage = vault::read_storage(&worktree)?;
        if self.storage == Storage::Age {
            let recipient = vault::read_recipient(&worktree)?;
            self.unlock(paths, &worktree, &recipient, secrets, remember, log)?;
        }
        let raw = vault::read_raw(&worktree, self.storage, self.keys.as_ref())?;
        self.last_counts = vault::counts_of(&raw);
        self.last_version = raw.get("vault_version").and_then(Value::as_u64);
        vault::upgrade(raw, migrate)
    }

    fn unlock(&mut self, paths: &StatePaths, worktree: &Path, recipient: &str, secrets: &Secrets, remember: bool,
        log: &mut dyn FnMut(Level, &str)) -> Result<()>
    {
        if self.keys.as_ref().is_some_and(|keys| keys.recipient == recipient) {
            if remember {
                remember_key(paths, self.keys.as_ref().expect("checked"), log);
            }
            return Ok(());
        }
        self.keys = None;
        if let Some(text) = read_optional(&paths.remembered_key())? {
            match std::str::from_utf8(&text).ok().and_then(Keys::parse) {
                Some(keys) if keys.recipient == recipient => {
                    self.keys = Some(keys);
                    return Ok(());
                }
                _ => log(Level::Warn, "Сохранённый ключ расшифровки не подходит к текущему хранилищу."),
            }
        }
        let Some(password) = secrets.get("vault-password") else {
            return Err(RcError::new("vault_password_required", "Требуется пароль доступа к конфигурации GitHub (секрет vault-password).")
                .with_extra("secret", "vault-password"));
        };
        password_line_valid(password)?;
        let unlock = read_optional(&worktree.join("unlock.age"))?.unwrap_or_default();
        let keys = vault::unwrap_identity(&unlock, password)?.ok_or_else(|| {
            RcError::new("vault_password_invalid", "Пароль доступа к конфигурации GitHub не подошёл.").with_extra("secret", "vault-password")
        })?;
        if keys.recipient != recipient {
            return Err(vault::format_error("invalid", "Ключ из unlock.age не соответствует recipient текущего хранилища.", None, None));
        }
        if remember {
            remember_key(paths, &keys, log);
        }
        self.keys = Some(keys);
        Ok(())
    }
}

fn remember_key(paths: &StatePaths, keys: &Keys, log: &mut dyn FnMut(Level, &str)) {
    let saved = secure_fs::create_dir_all(&paths.credentials())
        .and_then(|()| secure_fs::atomic_write(&paths.remembered_key(), keys.identity_file().as_bytes()));
    if saved.is_err() {
        log(Level::Warn, "Не удалось сохранить ключ расшифровки на этом устройстве; текущий сеанс продолжится без сохранённого ключа.");
    }
}

fn password_line_valid(password: &str) -> Result<()> {
    if password.ends_with(['\r', '\n']) {
        return Err(RcError::new("invalid", "Пароль доступа не должен заканчиваться переводом строки."));
    }
    Ok(())
}

pub(super) fn new_vault_password(secrets: &Secrets) -> Result<&str> {
    let password = secrets.get("new-vault-password").filter(|p| !p.is_empty()).ok_or_else(|| {
        RcError::new("new_vault_password_required", "Требуется новый пароль доступа к конфигурации GitHub (секрет new-vault-password).")
            .with_extra("secret", "new-vault-password")
    })?;
    password_line_valid(password)?;
    Ok(password)
}

// ─── Session plumbing ────────────────────────────────────────────────────────

fn root(session: &Session) -> StatePaths {
    session.state.paths().local()
}

fn locks(session: &Session) -> LockManager {
    session.state.locks().clone()
}

fn install(session: &mut Session, github: GithubSession) {
    let paths = root(session);
    session.state = State::with_locks(paths.runtime(), locks(session));
    session.github = Some(github);
}

fn use_local(session: &mut Session) {
    let paths = root(session);
    session.state = State::with_locks(paths, locks(session));
    session.github = None;
}

fn release(session: &Session) {
    let _ = session.state.locks().release_all();
}

fn read_source(paths: &StatePaths, locks: &LockManager) -> Result<Target> {
    let state = State::with_locks(paths.clone(), locks.clone());
    let source = state.load_source()
        .map_err(|_| fail("проверка настроек источника GitHub", "source.json содержит неполные или некорректные параметры GitHub."))?
        .ok_or_else(|| fail("проверка настроек источника GitHub", "Источник GitHub не настроен."))?;
    Target::from_repo(&source.repo, &source.branch)
        .ok_or_else(|| fail("проверка настроек источника GitHub", "source.json содержит неполные или некорректные параметры GitHub."))
}

pub fn write_source(paths: &StatePaths, target: &Target) -> Result<()> {
    let source = Source { source_type: SourceType::Github, repo: target.repo(), branch: target.branch.clone(), private_verified: true };
    source.validate()?;
    let mut bytes = serde_json::to_vec_pretty(&source)?;
    bytes.push(b'\n');
    secure_fs::atomic_write(paths.source(), &bytes)?;
    Ok(())
}

/// Hold the session lock, finish an interrupted account change and prepare
/// the session worktree of the saved repository.
fn begin(session: &mut Session) -> Result<GithubSession> {
    let paths = root(session);
    let manager = locks(session);
    manager.acquire(LockKind::Session, "github-session")?;
    super::switch::recover(&paths, &manager, &mut |level, text| session.log(level, text))?;
    let target = read_source(&paths, &manager)?;
    let prepared = store::sync_init(&paths, &target, &paths.github_store(), &paths.github_sessions(), Mode::Resume,
        RepoDecisions::default(), &mut |level, text| session.log(level, text))
        .map_err(|error| prefixed(error, "Не удалось подготовить локальную рабочую копию репозитория", "source_failed"))?;
    Ok(GithubSession::new(target, prepared.work, prepared.sync))
}

/// v1 `config_source_startup` for a GitHub source.
pub fn open_github(session: &mut Session, secrets: &Secrets, remember: bool) -> Result<()> {
    close_github(session);
    let result = (|| {
        let mut github = begin(session)?;
        let paths = root(session);
        let opened = github.read_vault(&paths, secrets, remember, false, &mut |level, text| session.log(level, text))
            .and_then(|snapshot| vault::materialize(&paths, &locks(session), &snapshot));
        match opened {
            Ok(()) => Ok(github),
            Err(error) => {
                let _ = github.close();
                Err(error)
            }
        }
    })();
    match result {
        Ok(github) => {
            install(session, github);
            Ok(())
        }
        Err(error) => {
            release(session);
            Err(prefixed(error, "Не удалось открыть источник GitHub", "source_failed"))
        }
    }
}

/// Transport close: send pending work, remove the worktree, drop the lock.
pub fn close_github(session: &mut Session) {
    let paths = root(session);
    if let Some(mut github) = session.github.take() {
        if session.open && github.sync == SyncStatus::Pending {
            let _ = github.flush(&paths);
        }
        let _ = github.close();
    }
    use_local(session);
}

fn require_github(session: &Session) -> Result<()> {
    if session.github.is_none() {
        return Err(RcError::new("not_configured", "Источник GitHub не подключён: source github-connect --login LOGIN."));
    }
    Ok(())
}

fn require_age(session: &Session) -> Result<()> {
    require_github(session)?;
    if session.github.as_ref().map(|g| g.storage) != Some(Storage::Age) {
        return Err(RcError::new("invalid", "Конфигурация GitHub хранится без шифрования: команда относится только к хранению age."));
    }
    Ok(())
}

fn github(session: &mut Session) -> &mut GithubSession {
    session.github.as_mut().expect("GitHub source checked by the handler")
}

fn sync_data(session: &Session) -> Value {
    json!({"sync": session.github.as_ref().map(|g| g.sync.as_str())})
}

// ─── Decisions and plans ─────────────────────────────────────────────────────

/// Flag decisions (v1 `_cli_source_decisions`); invalid values are `usage`.
#[derive(Default)]
pub(super) struct Decisions {
    create_repo: bool,
    make_private: bool,
    pub(super) storage: Option<Storage>,
    existing: Option<String>,
    provision: Option<bool>,
    remember: bool,
    replace_target: bool,
}

pub(super) fn decisions(invocation: &Invocation) -> Result<Decisions> {
    let storage = match invocation.value("storage") {
        None => None,
        Some(value) => Some(Storage::parse(value).ok_or_else(|| RcError::new("usage", "Флаг --storage принимает age или none."))?),
    };
    let existing = invocation.value("existing").map(str::to_owned);
    if existing.as_deref().is_some_and(|value| !matches!(value, "remote" | "local" | "migrate")) {
        return Err(RcError::new("usage", "Флаг --existing принимает remote, local или migrate."));
    }
    let provision = match invocation.value("provision-keys") {
        None => None,
        Some("yes") => Some(true),
        Some("no") => Some(false),
        Some(_) => return Err(RcError::new("usage", "Флаг --provision-keys принимает yes или no.")),
    };
    Ok(Decisions {
        create_repo: invocation.has("create-repo"),
        make_private: invocation.has("make-private"),
        storage,
        existing,
        provision,
        remember: invocation.has("remember-key"),
        replace_target: invocation.has("replace-target"),
    })
}

fn required_login(invocation: &Invocation) -> Result<String> {
    let login = invocation.value("login").filter(|l| !l.is_empty())
        .ok_or_else(|| RcError::new("usage", "Укажите аккаунт GitHub: --login LOGIN."))?;
    if !login_valid(login) {
        return Err(RcError::new("usage", format!("Некорректный логин GitHub: {}.", super::safe_error(login))));
    }
    Ok(login.to_owned())
}

/// Plan lines with a risk flag: only risky plans need consent (v1 `GITHUB_PLAN_RISKY`).
struct GithubPlan {
    lines: Vec<String>,
    risky: bool,
}

impl GithubPlan {
    fn begin(title: &str, target: &Target, pending: PendingRepo) -> Self {
        let mut plan = Self { lines: vec![title.into(), format!("Репозиторий: {} (ветка {})", target.repo(), target.branch)], risky: false };
        match pending {
            PendingRepo::Create => plan.lines.push("Будет создан приватный репозиторий.".into()),
            PendingRepo::Private => {
                plan.lines.push("Публичный репозиторий станет приватным.".into());
                plan.risky = true;
            }
            PendingRepo::None => {}
        }
        plan
    }

    fn storage(&mut self, storage: Storage) {
        if storage == Storage::Plain {
            self.lines.extend(plaintext_lines());
            self.risky = true;
        } else {
            self.lines.push("Хранение: зашифровано паролем доступа (age).".into());
        }
    }

    /// SSH onboarding of the nodes about to move to GitHub (v1
    /// `_github_plan_onboarding`): the `--provision-keys` decision, portable
    /// keys to create and server keys to pin (read from the servers). Any
    /// such line makes the plan need consent.
    async fn onboarding<T: RemoteTransport>(&mut self, transport: &mut T, state: &State, config: &Config, provision: Option<bool>)
        -> Result<Option<OnboardingPlan>>
    {
        if config.nodes.is_empty() {
            return Ok(None);
        }
        let provision = setup::provision_decision(config, provision)?;
        let plan = setup::plan_onboarding(transport, state, config, provision).await?;
        if !plan.lines.is_empty() {
            self.lines.extend(plan.lines.iter().cloned());
            self.risky = true;
        }
        Ok(Some(plan))
    }

    fn confirm(self, invocation: &Invocation) -> Result<()> {
        if self.risky { Plan::new(self.lines, "").confirm(invocation) } else { Ok(()) }
    }
}

fn plaintext_lines() -> [String; 2] {
    ["Пароли SSH и ключи будут храниться в GitHub без шифрования".into(), "и навсегда останутся в истории Git.".into()]
}

fn config_counts(config: &Config) -> Value {
    json!({"nodes": config.nodes.len(), "clients": config.clients.len(), "groups": config.groups.len()})
}

fn label(counts: &Value) -> String {
    vault::counts_label(counts)
}

/// v1 `_github_decide_existing_action`.
fn decide_existing(choice: Option<&str>, allow_local: bool, outdated: bool, remote: Value, local: Value) -> Result<String> {
    let mut choices = vec![if outdated { "migrate" } else { "remote" }];
    if allow_local {
        choices.push("local");
    }
    match choice {
        Some(choice) if choices.contains(&choice) => Ok(choice.to_owned()),
        _ => Err(RcError::new("existing_config_action_required",
            format!("В репозитории уже есть конфигурация: --existing {}.", choices.join("|")))
            .with_extra("choices", choices)
            .with_extra("remote_counts", remote)
            .with_extra("local_counts", local)),
    }
}

pub(super) fn storage_decision(storage: Option<Storage>, log: &mut dyn FnMut(Level, &str)) -> Result<Storage> {
    let storage = storage.ok_or_else(|| RcError::new("storage_mode_required", "Выберите способ хранения конфигурации GitHub: --storage age|none.")
        .with_extra("choices", ["age", "none"]))?;
    if storage == Storage::Plain {
        log(Level::Warn, "В режиме без шифрования пароли SSH и приватные ключи доступны читателям репозитория и сохраняются в истории Git.");
    }
    Ok(storage)
}

/// Write, commit and push; a failed flush keeps the work pending (v1 rc 0 path).
fn publish(paths: &StatePaths, github: &mut GithubSession, snapshot: &Snapshot, log: &mut dyn FnMut(Level, &str)) -> Result<()> {
    github.checkpoint(snapshot)?;
    if let Err(error) = github.flush(paths) {
        log(Level::Warn, &format!("Не удалось отправить конфигурацию в GitHub: {}", error.message));
        log(Level::Warn, "Изменения сохранены локально и ожидают отправки.");
    }
    Ok(())
}

// ─── source init-local / status / accounts / login ───────────────────────────

pub fn init_local(session: &mut Session) -> Result<Value> {
    if session.configured()? {
        return Err(RcError::new("conflict", "Конфигурация уже создана."));
    }
    let paths = root(session);
    session.mutate("open-local", |state| {
        if state.paths().source().try_exists()? || state.paths().config().try_exists()? {
            return Err(RcError::new("conflict", "Конфигурация уже создана другим процессом."));
        }
        state.save_config(&Config::default())
    })?;
    session.open = true;
    session.authorized = !session.state.auth_store().is_configured()?;
    session.log(Level::Success, &format!("Локальная конфигурация создана: {}", paths.root().display()));
    Ok(json!({"source": "local", "config_dir": paths.root().to_string_lossy()}))
}

pub fn status(session: &Session) -> Result<Value> {
    let Some(github) = &session.github else {
        return Ok(json!({"type": "local", "repo": null, "branch": null, "storage": null, "sync": null, "key_saved": null}));
    };
    let key_saved = (github.storage == Storage::Age).then(|| {
        fs::symlink_metadata(root(session).remembered_key()).is_ok_and(|m| m.is_file())
    });
    Ok(json!({"type": "github", "repo": github.target.repo(), "branch": github.target.branch,
        "storage": github.storage.as_str(), "sync": github.sync.as_str(), "key_saved": key_saved}))
}

pub fn accounts(session: &Session) -> Value {
    json!({"accounts": store::accounts(&root(session)), "global_login": store::global_login()})
}

pub fn login(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let login = required_login(invocation)?;
    let paths = root(session);
    store::web_login(&paths, &login, &mut |level, text| session.log(level, text))?;
    session.log(Level::Success, &format!("Вход в GitHub выполнен: {login}."));
    Ok(json!({"login": login}))
}

// ─── source github-connect ───────────────────────────────────────────────────

/// Paths a failed connect must not leave behind (v1 `_github_enable_snapshot`).
/// Taken and rolled back under the session lock, so another process can
/// neither change the snapshotted files nor lose its own to the rollback.
struct ConnectUndo {
    /// Entries of a root this connect created (the lock only): a failure
    /// removes everything else but keeps the root and its `.rc-lock`.
    fresh_root: Option<Vec<OsString>>,
    created: Vec<PathBuf>,
    source: Option<zeroize::Zeroizing<Vec<u8>>>,
    auth: Option<zeroize::Zeroizing<Vec<u8>>>,
    store_refs: Option<(Vec<(String, String)>, Option<String>)>,
}

fn exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

const LOCK_DIR: &str = ".rc-lock";

impl ConnectUndo {
    /// `root_existed` is observed before the lock, whose acquisition creates the root.
    fn take(paths: &StatePaths, login: &str, root_existed: bool) -> Result<Self> {
        let mut created: Vec<PathBuf> = [paths.github_store(), paths.github_sessions(), paths.github_runtime()]
            .into_iter().filter(|path| !exists(path)).collect();
        let profile_levels = [paths.credentials(), paths.credentials().join("gh"), paths.gh_profile(login)];
        if let Some(first) = profile_levels.into_iter().find(|path| !exists(path)) {
            created.push(first);
        }
        if !exists(&paths.remembered_key()) {
            created.push(paths.remembered_key());
        }
        let store_refs = if store::store_exists(&paths.github_store()) {
            let out = super::exec::store_git(&paths.github_store(), &["for-each-ref".as_ref(), "--format=%(objectname) %(refname)".as_ref()])?;
            // An unread ref list would make the rollback delete every existing ref.
            if !out.success {
                return Err(fail("проверка локальной копии репозитория", out.diagnostic()));
            }
            let refs = out.text().lines().filter_map(|line| line.split_once(' ')).map(|(o, r)| (o.to_owned(), r.to_owned())).collect();
            Some((refs, store::origin(&paths.github_store())?))
        } else {
            None
        };
        let fresh_root = if root_existed {
            None
        } else {
            Some(fs::read_dir(paths.root())?.map(|entry| entry.map(|entry| entry.file_name())).collect::<std::io::Result<Vec<_>>>()?)
        };
        Ok(Self { fresh_root, created, source: read_optional(paths.source())?, auth: read_optional(paths.auth())?, store_refs })
    }

    fn rollback(&self, paths: &StatePaths) {
        for path in &self.created {
            let _ = if path.is_dir() { fs::remove_dir_all(path) } else { fs::remove_file(path) };
        }
        for (path, bytes) in [(paths.source(), &self.source), (paths.auth(), &self.auth)] {
            let _ = match bytes {
                Some(bytes) => secure_fs::atomic_write(path, bytes),
                None => fs::remove_file(path).or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) }),
            };
        }
        if let Some((refs, origin)) = &self.store_refs {
            let store_path = paths.github_store();
            let git = |list: &[&str]| super::exec::store_git(&store_path, &list.iter().map(std::ffi::OsStr::new).collect::<Vec<_>>());
            let _ = match origin {
                Some(url) => git(&["remote", "set-url", "origin", url]),
                None => git(&["remote", "remove", "origin"]),
            };
            if let Ok(out) = git(&["for-each-ref", "--format=%(refname)"]) {
                for name in out.text().lines().filter(|name| !refs.iter().any(|(_, r)| r == name)) {
                    let _ = git(&["update-ref", "-d", name]);
                }
            }
            for (oid, name) in refs {
                let _ = git(&["update-ref", name, oid]);
            }
        }
        if let Some(kept) = &self.fresh_root {
            for entry in fs::read_dir(paths.root()).into_iter().flatten().flatten() {
                let name = entry.file_name();
                if name == LOCK_DIR || kept.contains(&name) {
                    continue;
                }
                let _ = if entry.file_type().is_ok_and(|kind| kind.is_dir()) { fs::remove_dir_all(entry.path()) } else { fs::remove_file(entry.path()) };
            }
        }
    }
}

pub async fn connect<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, secrets: &Secrets, transport: &mut T)
    -> Result<Value>
{
    let login = required_login(invocation)?;
    let configured = session.configured()?;
    if configured {
        if !(session.open && session.authorized) {
            match session.mode() {
                DispatchMode::OneShot => { session.open_source(secrets, false)?; }
                DispatchMode::Serve => return Err(RcError::new("session_closed", "Сначала откройте сессию: session open.")),
            }
        }
        if session.github.is_some() {
            return Err(RcError::new("conflict", "Источник GitHub уже подключён."));
        }
    }
    let choices = decisions(invocation)?;
    let paths = root(session);
    let root_existed = exists(paths.root());
    locks(session).acquire(LockKind::Session, "github-session")?;
    if !configured && session.configured()? {
        release(session);
        return Err(RcError::new("conflict", "Конфигурация уже создана другим процессом."));
    }
    let undo = match ConnectUndo::take(&paths, &login, root_existed) {
        Ok(undo) => undo,
        Err(error) => {
            release(session);
            return Err(prefixed(error, "Не удалось подключить GitHub", "source_failed"));
        }
    };
    match connect_locked(session, &paths, &login, &choices, invocation, secrets, transport).await {
        Ok(data) => {
            if !configured {
                session.authorized = !session.state.auth_store().is_configured()?;
            }
            session.open = true;
            session.log(Level::Success, "Источник GitHub подключён.");
            Ok(data)
        }
        Err(error) => {
            undo.rollback(&paths);
            release(session);
            Err(prefixed(error, "Не удалось подключить GitHub", "source_failed"))
        }
    }
}

async fn connect_locked<T: RemoteTransport>(session: &mut Session, paths: &StatePaths, login: &str, choices: &Decisions,
    invocation: &Invocation, secrets: &Secrets, transport: &mut T) -> Result<Value>
{
    let target = Target::new(login, REPO_NAME, BRANCH);
    // Live progress for the TUI (serve log events) during the slow gh/git calls.
    session.log(Level::Info, &format!("Проверка аккаунта GitHub {login}…"));
    store::prepare_account(paths, login).map_err(|error| if super::is_auth_relevant(&error) {
        store::auth_required(paths, login, format!("Аккаунт GitHub {login} не авторизован: source github-login --login {login}."))
    } else {
        error
    })?;
    session.log(Level::Info, &format!("Получение репозитория {}…", target.repo()));
    let prepared = store::sync_init(paths, &target, &paths.github_store(), &paths.github_sessions(), Mode::Onboarding,
        RepoDecisions { create: choices.create_repo, make_private: choices.make_private },
        &mut |level, text| session.log(level, text))?;
    let pending = prepared.pending;
    let mut github = GithubSession::new(target.clone(), prepared.work, prepared.sync);
    let result = connect_publish(session, paths, &mut github, pending, choices, invocation, secrets, transport).await;
    match result {
        Ok((snapshot, onboarded)) => {
            let materialized = write_source(paths, &target).and_then(|()| vault::materialize(paths, &locks(session), &snapshot));
            if let Err(error) = materialized {
                if let Some(onboarded) = onboarded {
                    onboarded.cancel(&mut |level, text| session.log(level, text)).await;
                }
                let _ = github.close();
                return Err(error);
            }
            let data = json!({"repo": target.repo(), "storage": github.storage.as_str(), "sync": github.sync.as_str()});
            install(session, github);
            Ok(data)
        }
        Err(error) => {
            let _ = github.close();
            Err(error)
        }
    }
}

/// Run the agreed onboarding of the device-local nodes (rollback mode).
async fn onboard<T: RemoteTransport>(transport: &mut T, local: &State, config: &Config, plan: Option<&OnboardingPlan>,
    log: &mut dyn FnMut(Level, &str)) -> Result<Option<LocalOnboarding<T::Held>>>
{
    match plan {
        Some(plan) => Ok(Some(setup::onboard_local(transport, local, config, plan, log).await?)),
        None => Ok(None),
    }
}

/// A failed step after onboarding revokes its keys and restores the device files.
async fn settle<V, H: RemoteSession>(result: Result<V>, onboarded: Option<LocalOnboarding<H>>, log: &mut dyn FnMut(Level, &str))
    -> Result<(V, Option<LocalOnboarding<H>>)>
{
    match result {
        Ok(value) => Ok((value, onboarded)),
        Err(error) => {
            if let Some(onboarded) = onboarded {
                onboarded.cancel(log).await;
            }
            Err(error)
        }
    }
}

/// Decide, confirm and publish; returns the snapshot to materialize and the
/// device-local onboarding that a later failure must cancel.
#[allow(clippy::too_many_arguments)]
async fn connect_publish<T: RemoteTransport>(session: &mut Session, paths: &StatePaths, github: &mut GithubSession,
    pending: PendingRepo, choices: &Decisions, invocation: &Invocation, secrets: &Secrets, transport: &mut T)
    -> Result<(Snapshot, Option<LocalOnboarding<T::Held>>)>
{
    let local = State::with_locks(paths.clone(), locks(session));
    let local_config = local.load_config()?;
    let local_counts = config_counts(&local_config);
    let tracked = github.work()?.tracked()?;
    let mut log = |level: Level, text: &str| session.log(level, text);
    // An existing repository holds a v2 configuration (maybe outdated) or
    // foreign files, e.g. the layout of the Bash 1.x client: the latter is a
    // `--replace-target` decision, never a dead end.
    let (mut remote, mut outdated, mut foreign) = (None, false, None);
    if !tracked.is_empty() {
        if !tracked.iter().any(|path| path == "storage.json") {
            foreign = Some("нет файла storage.json".to_owned());
        } else {
            match github.read_vault(paths, secrets, choices.remember, false, &mut log) {
                Ok(snapshot) => remote = Some(snapshot),
                Err(error) if error.code == "github_format_outdated" => outdated = true,
                Err(error) if matches!(error.code, "source_failed" | "github_format_invalid" | "unsafe_path") => foreign = Some(error.message),
                Err(error) => return Err(error),
            }
        }
    }
    if let Some(reason) = &foreign {
        github.storage = Storage::Plain;
        github.keys = None;
        if !choices.replace_target {
            return Err(RcError::new("target_replace_required", format!(
                "Репозиторий {} содержит данные не в формате Remote Control 2: заменить их можно флагом --replace-target.", github.target.repo()))
                .with_extra("repo", github.target.repo()).with_extra("tracked_files", tracked.len()).with_extra("reason", reason.as_str()));
        }
    }
    if tracked.is_empty() || foreign.is_some() {
        let storage = storage_decision(choices.storage, &mut log)?;
        let password = if storage == Storage::Age { Some(new_vault_password(secrets)?.to_owned()) } else { None };
        let mut plan = GithubPlan::begin("Подключение GitHub", &github.target, pending);
        if let Some(reason) = &foreign {
            plan.lines.push(format!("В репозитории нет конфигурации Remote Control 2 ({reason})."));
            plan.lines.push(format!("Из {} будут удалены все файлы ({}); они останутся только в истории Git.", github.target.repo(), tracked.len()));
            plan.risky = true;
        }
        plan.lines.push(format!("В GitHub будет отправлена конфигурация этого компьютера: {}.", label(&local_counts)));
        plan.storage(storage);
        let onboarding = plan.onboarding(transport, &local, &local_config, choices.provision).await?;
        plan.confirm(invocation)?;
        let onboarded = onboard(transport, &local, &local_config, onboarding.as_ref(), &mut log).await?;
        let published = (|| -> Result<Snapshot> {
            store::apply_pending(paths, &github.target, pending)?;
            if foreign.is_some() {
                github.work()?.remove_all()?;
            }
            github.storage = storage;
            if let Some(password) = password {
                let keys = Keys::generate();
                vault::publish_keys(&github.work()?.worktree, &keys, &zeroize::Zeroizing::new(password))?;
                if choices.remember {
                    remember_key(paths, &keys, &mut log);
                }
                github.keys = Some(keys);
            }
            let snapshot = vault::serialize(&local)?;
            publish(paths, github, &snapshot, &mut log)?;
            Ok(snapshot)
        })();
        return settle(published, onboarded, &mut log).await;
    }
    let remote_counts = remote.as_ref().map_or(Value::Null, Snapshot::counts);
    let action = decide_existing(choices.existing.as_deref(), true, outdated, remote_counts.clone(), local_counts.clone())?;
    match action.as_str() {
        "local" => {
            let mut plan = GithubPlan::begin("Подключение GitHub с заменой конфигурации", &github.target, pending);
            plan.lines.push(format!("Конфигурация GitHub ({}) будет заменена конфигурацией этого компьютера ({}).",
                label(&remote_counts), label(&local_counts)));
            plan.lines.push("Текущая конфигурация GitHub останется только в истории Git.".into());
            plan.storage(github.storage);
            let onboarding = plan.onboarding(transport, &local, &local_config, choices.provision).await?;
            plan.risky = true;
            plan.confirm(invocation)?;
            let onboarded = onboard(transport, &local, &local_config, onboarding.as_ref(), &mut log).await?;
            let published = (|| -> Result<Snapshot> {
                store::apply_pending(paths, &github.target, pending)?;
                let snapshot = vault::serialize(&local)?;
                publish(paths, github, &snapshot, &mut log)?;
                Ok(snapshot)
            })();
            settle(published, onboarded, &mut log).await
        }
        "migrate" => {
            let snapshot = github.read_vault(paths, secrets, false, true, &mut log)?;
            migrate_plan(github, pending, &snapshot).confirm(invocation)?;
            store::apply_pending(paths, &github.target, pending)?;
            publish(paths, github, &snapshot, &mut log)?;
            Ok((snapshot, None))
        }
        _ => {
            let mut plan = GithubPlan::begin("Подключение GitHub", &github.target, pending);
            plan.lines.push(format!("Будет использована конфигурация GitHub: {}.", label(&remote_counts)));
            plan.risky = pending != PendingRepo::None;
            plan.confirm(invocation)?;
            store::apply_pending(paths, &github.target, pending)?;
            Ok((remote.expect("remote action has a snapshot"), None))
        }
    }
}

fn migrate_plan(github: &GithubSession, pending: PendingRepo, snapshot: &Snapshot) -> GithubPlan {
    let mut plan = GithubPlan::begin("Преобразование конфигурации GitHub", &github.target, pending);
    let from = github.last_version.map_or("?".into(), |v| v.to_string());
    plan.lines.push(format!("Формат: v{from} → v{}", vault::FORMAT));
    plan.lines.push(format!("Устройства с Remote Control старше {} перестанут читать конфигурацию.", vault::FORMAT_MIN_VERSION));
    plan.lines.push("Предыдущая версия останется в истории Git.".into());
    if github.storage == Storage::Plain {
        plan.lines.extend(plaintext_lines());
    }
    let missing: Vec<&str> = snapshot.config.nodes.iter()
        .filter(|n| snapshot.portability.issues.iter().any(|i| i.node_id == n.id && i.reason == crate::model::PortabilityReason::MissingSecret))
        .map(|n| n.name.as_str()).collect();
    if !missing.is_empty() {
        plan.lines.push(format!("Потребуется повторный ввод пароля: {}", missing.join(", ")));
    }
    plan.risky = true;
    plan
}

// ─── fetch / push ────────────────────────────────────────────────────────────

pub fn fetch(session: &mut Session) -> Result<Value> {
    require_github(session)?;
    let paths = root(session);
    let prefix = "Не удалось загрузить конфигурацию из GitHub";
    github(session).flush(&paths).map_err(|error| prefixed(error, prefix, "remote_failed"))?;
    let keys = github(session).keys.clone();
    let target = github(session).target.clone();
    let prepared = store::sync_init(&paths, &target, &paths.github_store(), &paths.github_sessions(), Mode::Resume,
        RepoDecisions::default(), &mut |level, text| session.log(level, text))
        .map_err(|error| prefixed(error, prefix, "remote_failed"))?;
    let mut fresh = GithubSession::new(target, prepared.work, prepared.sync);
    fresh.keys = keys;
    let opened = fresh.read_vault(&paths, &Secrets::default(), false, false, &mut |level, text| session.log(level, text))
        .and_then(|snapshot| vault::materialize(&paths, &locks(session), &snapshot));
    if let Err(error) = opened {
        let _ = fresh.close();
        return Err(prefixed(error, prefix, "remote_failed"));
    }
    if let Err(error) = github(session).close() {
        let _ = fresh.close();
        return Err(prefixed(error, prefix, "remote_failed"));
    }
    session.github = Some(fresh);
    session.log(Level::Success, "Конфигурация загружена из GitHub.");
    Ok(sync_data(session))
}

pub fn push(session: &mut Session) -> Result<Value> {
    require_github(session)?;
    let paths = root(session);
    if let Err(error) = github(session).flush(&paths) {
        session.log(Level::Warn, "Изменения сохранены локально и ожидают отправки.");
        return Err(prefixed(error, "Не удалось отправить конфигурацию в GitHub", "remote_failed"));
    }
    session.log(Level::Success, "Локальная конфигурация отправлена в GitHub.");
    Ok(sync_data(session))
}

// ─── age key operations ──────────────────────────────────────────────────────

/// Flush after a key change; a failure after the commit is pinned locally is
/// kept as pending, anything earlier restores the files and the worktree.
fn flush_or_restore(session: &mut Session, head: &str, saved: Vec<(PathBuf, Option<zeroize::Zeroizing<Vec<u8>>>)>, note: &str) -> Result<()> {
    let paths = root(session);
    let Err(error) = github(session).flush(&paths) else { return Ok(()) };
    if store::failed_after_pin(&error) {
        session.log(Level::Warn, &format!("{note}: {}", error.message));
        return Ok(());
    }
    let work = github(session).work()?.clone();
    work.reset_hard(head)?;
    for (path, bytes) in saved {
        match bytes {
            Some(bytes) => secure_fs::atomic_write(&path, &bytes)?,
            None => { let _ = fs::remove_file(&path); }
        }
    }
    Err(error)
}

fn saved_files(worktree: &Path, names: &[&str]) -> Result<Vec<(PathBuf, Option<zeroize::Zeroizing<Vec<u8>>>)>> {
    names.iter().map(|name| Ok((worktree.join(name), read_optional(&worktree.join(name))?))).collect()
}

pub fn rewrap_password(session: &mut Session, secrets: &Secrets) -> Result<Value> {
    require_age(session)?;
    let old = secrets.get("vault-password").filter(|p| !p.is_empty()).ok_or_else(|| {
        RcError::new("vault_password_required", "Требуется текущий пароль доступа к конфигурации GitHub (секрет vault-password).")
            .with_extra("secret", "vault-password")
    })?;
    let new = new_vault_password(secrets)?;
    password_line_valid(old)?;
    let worktree = github(session).work()?.worktree.clone();
    let recipient = vault::read_recipient(&worktree)?;
    let unlock = read_optional(&worktree.join("unlock.age"))?.unwrap_or_default();
    let keys = vault::unwrap_identity(&unlock, old)?.ok_or_else(|| {
        RcError::new("vault_password_invalid", "Текущий пароль доступа неверен или файл unlock.age повреждён.").with_extra("secret", "vault-password")
    })?;
    if keys.recipient != recipient {
        return Err(vault::format_error("invalid", "Ключ из unlock.age не соответствует recipient текущего хранилища.", None, None));
    }
    let head = github(session).work()?.head()?;
    let saved = saved_files(&worktree, &["unlock.age"])?;
    let wrapped = vault::wrap_identity(&keys, new)?;
    secure_fs::atomic_write(&worktree.join("unlock.age"), &wrapped)
        .map_err(|_| fail("шифрование ключа конфигурации", "Не удалось атомарно зашифровать ключ новым паролем."))?;
    flush_or_restore(session, &head, saved, "Новый пароль сохранён локально, но не отправлен в GitHub")
        .map_err(|error| prefixed(error, "Не удалось изменить пароль доступа", "source_failed"))?;
    session.log(Level::Success, "Пароль доступа изменён; ключ шифрования остался прежним.");
    Ok(sync_data(session))
}

pub fn rotate_key(session: &mut Session, invocation: &Invocation, secrets: &Secrets) -> Result<Value> {
    require_age(session)?;
    let password = new_vault_password(secrets)?.to_owned();
    Plan::new(vec![
        "Будет создан новый ключ, и текущая конфигурация будет зашифрована заново.".into(),
        "Пароли нод не изменятся.".into(),
        "Старые версии в истории GitHub останутся доступны по прежнему ключу.".into(),
    ], "").confirm(invocation)?;
    let paths = root(session);
    let key_saved = exists(&paths.remembered_key());
    let worktree = github(session).work()?.worktree.clone();
    let head = github(session).work()?.head()?;
    let saved = saved_files(&worktree, &["recipient.txt", "unlock.age", "state.json.age"])?;
    let old_keys = github(session).keys.clone();
    let keys = Keys::generate();
    let staged = (|| {
        vault::publish_keys(&worktree, &keys, &password)?;
        let snapshot = vault::serialize(&session.state)?;
        github(session).keys = Some(keys.clone());
        github(session).checkpoint(&snapshot)
    })();
    let result = staged.and_then(|()| flush_or_restore(session, &head, saved.clone(), "Новый ключ сохранён локально, но не отправлен в GitHub"));
    if let Err(error) = result {
        github(session).keys = old_keys;
        let work = github(session).work()?.clone();
        let _ = work.reset_hard(&head);
        for (path, bytes) in saved {
            if let Some(bytes) = bytes {
                let _ = secure_fs::atomic_write(&path, &bytes);
            }
        }
        return Err(prefixed(error, "Не удалось создать новый ключ шифрования", "source_failed"));
    }
    if key_saved {
        let mut failed = false;
        remember_key(&paths, &keys, &mut |_, _| failed = true);
        if failed {
            let _ = fs::remove_file(paths.remembered_key());
            session.log(Level::Warn, "Новый ключ не удалось сохранить на этом устройстве: следующий запуск попросит пароль доступа.");
        }
    }
    session.log(Level::Success, "Новый ключ создан; текущая конфигурация зашифрована заново.");
    Ok(sync_data(session))
}

fn inside(path: &Path, root: &Path) -> bool {
    let canonical = |p: &Path| fs::canonicalize(p).ok();
    let candidate = canonical(path).or_else(|| path.parent().and_then(canonical).map(|p| p.join(path.file_name().unwrap_or_default())));
    match (candidate, canonical(root)) {
        (Some(candidate), Some(root)) => candidate.starts_with(root),
        _ => false,
    }
}

pub fn import_recovery_key(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    require_age(session)?;
    let file = invocation.value("file").filter(|f| !f.is_empty())
        .ok_or_else(|| RcError::new("usage", "Укажите файл ключа: --file PATH."))?;
    let path = Path::new(file);
    let invalid = |message: &str| RcError::new("invalid", format!("Не удалось импортировать ключ восстановления: {message}"));
    let regular = fs::symlink_metadata(path).is_ok_and(|m| m.is_file());
    if !regular || inside(path, root(session).root()) {
        return Err(invalid("файл ключа восстановления не найден, имеет недопустимый тип или расположен внутри служебного каталога."));
    }
    let text = read_optional(path)?.unwrap_or_default();
    let keys = std::str::from_utf8(&text).ok().and_then(Keys::parse)
        .ok_or_else(|| invalid("файл не содержит корректный секретный ключ age."))?;
    let recipient = vault::read_recipient(&github(session).work()?.worktree)?;
    if keys.recipient != recipient {
        return Err(invalid("ключ восстановления не подходит к текущему хранилищу GitHub."));
    }
    github(session).keys = Some(keys);
    session.log(Level::Success, "Ключ восстановления импортирован для текущего сеанса.");
    Ok(json!({}))
}

// ─── switch-local / delete-repo ──────────────────────────────────────────────

fn copy_tree(from: &Path, to: &Path) -> Result<()> {
    secure_fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let kind = fs::symlink_metadata(entry.path())?.file_type();
        let target = to.join(entry.file_name());
        if kind.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else if kind.is_file() {
            secure_fs::atomic_write(&target, &read_optional(&entry.path())?.unwrap_or_default())?;
        } else {
            return Err(RcError::new("unsafe_path", format!("Недопустимый тип пути: {}", entry.path().display())));
        }
    }
    Ok(())
}

const LOCAL_ITEMS: [&str; 5] = ["config.json", "secrets.json", "manifest.json", "templates", "ssh"];

/// v1 `github_config_switch_local`: the GitHub working state becomes the
/// device-local state; the previous local files go to `import-backups/`.
fn switch_local_inner(session: &mut Session) -> Result<()> {
    let paths = root(session);
    session.state.load_config()?;
    session.state.load_manifest()?;
    session.state.secret_store().validate()?;
    let stage = paths.root().join(format!(".local-switch-stage.{}", random_hex(6)));
    let backup = paths.root().join(format!(".local-switch-backup.{}", random_hex(6)));
    let staged = copy_tree(&paths.github_runtime(), &stage)
        .and_then(|()| { secure_fs::create_dir_all(&stage.join("templates"))?; Ok(secure_fs::create_dir_all(&stage.join("ssh"))?) })
        .and_then(|()| State::with_locks(paths.with_state_dir(&stage), locks(session)).load_config().map(drop));
    if let Err(error) = staged {
        let _ = fs::remove_dir_all(&stage);
        return Err(fail("подготовка локальной копии", format!("Не удалось полностью скопировать рабочее состояние GitHub: {}", error.message)));
    }
    secure_fs::create_dir(&backup)?;
    let mut moved = Vec::new();
    let mut published = Vec::new();
    let swap = (|| -> std::io::Result<()> {
        for name in LOCAL_ITEMS.iter().copied().chain(["source.json"]) {
            if exists(&paths.root().join(name)) {
                fs::rename(paths.root().join(name), backup.join(name))?;
                moved.push(name);
            }
        }
        for name in LOCAL_ITEMS {
            if exists(&stage.join(name)) {
                fs::rename(stage.join(name), paths.root().join(name))?;
                published.push(name);
            }
        }
        Ok(())
    })();
    let closed = swap.as_ref().map_err(|_| ()).and_then(|()| github(session).close().map_err(|_| ()));
    if closed.is_err() {
        for name in &published {
            let item = paths.root().join(name);
            let _ = if item.is_dir() { fs::remove_dir_all(&item) } else { fs::remove_file(&item) };
        }
        for name in &moved {
            let _ = fs::rename(backup.join(name), paths.root().join(name));
        }
        let _ = fs::remove_dir_all(&stage);
        let _ = fs::remove_dir_all(&backup);
        return Err(fail("публикация локального состояния", "Не удалось опубликовать полный комплект локальных файлов."));
    }
    let _ = fs::remove_dir_all(&stage);
    let archive = paths.import_backups().join(format!("{}-{}", utc_stamp(), random_hex(4)));
    let archived = secure_fs::create_dir_all(&paths.import_backups()).and_then(|()| fs::rename(&backup, &archive));
    if archived.is_err() {
        session.log(Level::Warn, &format!("Прежняя локальная копия сохранена во временном каталоге: {}", backup.display()));
    }
    use_local(session);
    release(session);
    Ok(())
}

pub fn switch_local(session: &mut Session) -> Result<Value> {
    require_github(session)?;
    switch_local_inner(session).map_err(|error| prefixed(error, "Не удалось перейти на локальную конфигурацию", "source_failed"))?;
    session.log(Level::Success, "Используется локальная конфигурация; синхронизация с GitHub отключена.");
    Ok(json!({"source": "local"}))
}

pub fn delete_repo(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    require_github(session)?;
    let target = github(session).target.clone();
    let repo = target.repo();
    Plan::new(vec![
        format!("Будет удалён репозиторий GitHub: {repo}."),
        "Конфигурация останется локально, синхронизация будет отключена.".into(),
    ], "").confirm(invocation)?;
    let paths = root(session);
    store::prepare_account(&paths, &target.owner).map_err(|e| prefixed(e, "Не удалось удалить репозиторий GitHub", "source_failed"))?;
    switch_local_inner(session).map_err(|e| prefixed(e, "Не удалось удалить репозиторий GitHub", "source_failed"))?;
    if let Err(error) = store::repo_delete(&paths, &target) {
        let url = format!("https://github.com/{repo}/settings");
        return Err(RcError::new("remote_failed", format!(
            "Не удалось удалить репозиторий {repo} ({}): завершите удаление в Danger Zone: {url}", error.message))
            .with_extra("settings_url", url));
    }
    session.log(Level::Success, &format!("Репозиторий {repo} удалён. Конфигурация сохранена локально, синхронизация отключена."));
    Ok(json!({"repo": repo, "deleted": true}))
}

// ─── Recovery: replace-with-local / migrate-format ───────────────────────────

/// v1 `_cli_source_recovery_open`: own script password first, then the
/// source; a GitHub format error leaves the worktree open in recovery mode.
fn recovery_open(session: &mut Session, secrets: &Secrets) -> Result<Option<RcError>> {
    if !session.configured()? {
        return Err(RcError::new("not_configured", "Конфигурация не создана: source init-local или source github-connect."));
    }
    if !session.authorized && session.state.auth_store().is_configured()? {
        let password = secrets.get("script-password").ok_or_else(|| {
            RcError::new("auth_required", "Требуется пароль запуска (секрет script-password).").with_extra("secret", "script-password")
        })?;
        if !session.state.auth_store().verify(password)? {
            return Err(RcError::new("auth_failed", "Неверный пароль запуска.").with_extra("secret", "script-password"));
        }
        session.authorized = true;
    }
    if session.open {
        return Ok(None);
    }
    if !root(session).source().try_exists()? {
        session.open = true;
        return Ok(None);
    }
    close_github(session);
    let mut github = match begin(session) {
        Ok(github) => github,
        Err(error) => {
            release(session);
            return Err(error);
        }
    };
    let paths = root(session);
    let opened = github.read_vault(&paths, secrets, false, false, &mut |level, text| session.log(level, text));
    match opened.and_then(|snapshot| vault::materialize(&paths, &locks(session), &snapshot)) {
        Ok(()) => {
            install(session, github);
            session.open = true;
            Ok(None)
        }
        Err(error) if vault::is_format_error(&error) => {
            install(session, github);
            Ok(Some(error))
        }
        Err(error) => {
            let _ = github.close();
            release(session);
            Err(prefixed(error, "Не удалось открыть источник GitHub", "source_failed"))
        }
    }
}

/// Publish a recovery snapshot; `refreshed` is false when only the runtime failed.
fn recovery_publish(session: &mut Session, snapshot: &Snapshot) -> Result<Value> {
    let paths = root(session);
    let auth_before = read_optional(paths.auth())?;
    let mut log = Vec::new();
    publish(&paths, github(session), snapshot, &mut |level, text| log.push((level, text.to_owned())))?;
    for (level, text) in log {
        session.log(level, &text);
    }
    let refreshed = vault::materialize(&paths, &locks(session), snapshot).is_ok();
    session.open = refreshed;
    if refreshed {
        let github = session.github.take().expect("checked");
        install(session, github);
    } else {
        session.log(Level::Warn, "Конфигурация GitHub опубликована, но рабочее состояние не обновилось: откройте сессию заново (session open).");
    }
    if read_optional(paths.auth())? != auth_before {
        session.authorized = false;
    }
    Ok(json!({"published": true, "refreshed": refreshed}))
}

pub async fn replace_with_local<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, secrets: &Secrets,
    transport: &mut T) -> Result<Value>
{
    let choices = decisions(invocation)?;
    let recovery = recovery_open(session, secrets)?;
    require_github(session)?;
    let recovery = match recovery {
        Some(mut error) if error.code == "github_format_newer" => {
            error.message = "Конфигурация GitHub создана более новой версией essence-rc: обновите essence-rc (self update).".into();
            return Err(error);
        }
        other => other,
    };
    let paths = root(session);
    let local = State::with_locks(paths.clone(), locks(session));
    if !paths.config().try_exists()? {
        return Err(RcError::new("not_found", "Конфигурация только этого компьютера отсутствует."));
    }
    let local_config = local.load_config()?;
    let local_counts = config_counts(&local_config);
    let github_counts = if recovery.is_some() { github(session).last_counts.clone() } else { config_counts(&session.state.load_config()?) };
    let github_ref = github(session);
    let mut plan = GithubPlan {
        lines: vec![
            "Замена конфигурации GitHub".into(),
            format!("Репозиторий: {} (ветка {})", github_ref.target.repo(), github_ref.target.branch),
            "Будет опубликована конфигурация только этого компьютера.".into(),
            format!("Этот компьютер: {}", label(&local_counts)),
            format!("GitHub: {}", label(&github_counts)),
            "Текущая конфигурация GitHub останется только в истории Git.".into(),
        ],
        risky: true,
    };
    if github_ref.storage == Storage::Plain {
        plan.lines.extend(plaintext_lines());
    }
    if recovery.is_none() && github_ref.sync == SyncStatus::Pending {
        plan.lines.push("Неотправленные изменения рабочей конфигурации GitHub будут заменены.".into());
    }
    if local_config.nodes.is_empty() && local_config.clients.is_empty() {
        plan.lines.push("Локальная конфигурация пуста.".into());
    }
    let onboarding = plan.onboarding(transport, &local, &local_config, choices.provision).await?;
    plan.confirm(invocation)?;
    let onboarded = onboard(transport, &local, &local_config, onboarding.as_ref(), &mut |level, text| session.log(level, text)).await?;
    let published = vault::serialize(&local).and_then(|snapshot| recovery_publish(session, &snapshot)
        .map_err(|e| prefixed(e, "Не удалось заменить конфигурацию GitHub", "source_failed")));
    let (data, _) = settle(published, onboarded, &mut |level, text| session.log(level, text)).await?;
    session.log(Level::Success, "Конфигурация GitHub заменена конфигурацией только этого компьютера.");
    Ok(data)
}

pub fn migrate_format(session: &mut Session, invocation: &Invocation, secrets: &Secrets) -> Result<Value> {
    let recovery = recovery_open(session, secrets)?;
    if recovery.as_ref().is_none_or(|error| error.code != "github_format_outdated") {
        return Err(RcError::new("nothing_pending", "Конфигурация GitHub не требует преобразования формата."));
    }
    let paths = root(session);
    let mut log = Vec::new();
    let snapshot = github(session).read_vault(&paths, secrets, false, true, &mut |level, text| log.push((level, text.to_owned())));
    for (level, text) in log {
        session.log(level, &text);
    }
    let snapshot = snapshot.map_err(|e| prefixed(e, "Не удалось преобразовать конфигурацию GitHub", "source_failed"))?;
    migrate_plan(github(session), PendingRepo::None, &snapshot).confirm(invocation)?;
    let data = recovery_publish(session, &snapshot).map_err(|e| prefixed(e, "Не удалось преобразовать конфигурацию GitHub", "source_failed"))?;
    session.log(Level::Success, &format!("Конфигурация GitHub преобразована в формат v{}.", vault::FORMAT));
    Ok(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unreadable_store_refs_abort_the_connect_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let paths = StatePaths::new(dir.path());
        // `objects/` makes it look like a store, but git cannot list its refs.
        fs::create_dir_all(paths.github_store().join("objects")).unwrap();
        let error = ConnectUndo::take(&paths, "octo", true).err().expect("an empty ref list must never be snapshotted");
        assert_eq!((error.code, super::super::stage_of(&error)), ("source_failed", Some("проверка локальной копии репозитория")));
    }

    #[test]
    fn failed_connect_cleans_a_fresh_root_but_keeps_it_and_its_lock() {
        let dir = tempfile::tempdir().unwrap();
        let paths = StatePaths::new(dir.path().join("data"));
        let locks = LockManager::new(paths.root());
        drop(locks.acquire(LockKind::Session, "github-session").unwrap());
        let undo = ConnectUndo::take(&paths, "octo", false).unwrap();
        for created in [paths.github_store(), paths.github_runtime(), paths.gh_profile("octo")] {
            fs::create_dir_all(created).unwrap();
        }
        fs::write(paths.source(), "{}").unwrap();
        fs::write(paths.secret_key(), "key").unwrap();
        undo.rollback(&paths);
        let left: Vec<OsString> = fs::read_dir(paths.root()).unwrap().map(|entry| entry.unwrap().file_name()).collect();
        assert_eq!(left, [OsString::from(LOCK_DIR)], "the held lock survives the rollback");
        locks.release_all().unwrap();
    }
}
