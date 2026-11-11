//! `source github-change-account` and its crash-recoverable journal
//! `account-switch/transaction.json` (v1 `github_account_switch_*`,
//! `github_source_change_account`).
//!
//! Phases: `prepared` (nothing remote happened: roll back), `push_unknown`
//! (a push to the new repository may have landed: verify, then finish or roll
//! back), `target_committed` (the switch can only go forward) and
//! `local_committed` (only cleanup remains). The old repository is never
//! changed. `old-state.sealed`/`target-state.sealed` are snapshots sealed with
//! the machine key inside the 0700 journal directory, needed after a crash.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::commands::{GithubSession, write_source};
use super::store::{self, Mode, PendingRepo, RepoDecisions};
use super::vault::{self, Keys, Snapshot};
use super::{Storage, SyncStatus, Target, fail, prefixed};
use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::locking::LockManager;
use crate::log::Level;
use crate::request_secrets::Secrets;
use crate::secure_fs;
use crate::state::{State, StatePaths, read_optional};

const STAGE: &str = "восстановление смены аккаунта GitHub";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Phase { Prepared, PushUnknown, TargetCommitted, LocalCommitted }

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Marker {
    version: u32,
    /// Random transaction id; binds the sealed snapshots to this journal.
    id: String,
    phase: Phase,
    old_repo: String,
    new_repo: String,
    branch: String,
    initial_login: String,
    expected_head: Option<String>,
    old_state_available: bool,
    repo_created: bool,
    repo_privatized: bool,
}

impl Marker {
    fn valid(&self) -> bool {
        let hex = |text: &str| text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
        let head_ok = self.expected_head.as_deref().is_none_or(|head| matches!(head.len(), 40 | 64) && hex(head));
        self.version == 1 && self.id.len() == 32 && hex(&self.id) && head_ok && super::login_valid(&self.initial_login)
            && Target::from_repo(&self.old_repo, &self.branch).is_some()
            && Target::from_repo(&self.new_repo, &self.branch).is_some()
    }

    fn new_target(&self) -> Target {
        Target::from_repo(&self.new_repo, &self.branch).expect("validated marker")
    }
}

fn journal(paths: &StatePaths, name: &str) -> PathBuf {
    paths.account_switch().join(name)
}

fn read_marker(paths: &StatePaths) -> Result<Option<Marker>> {
    let path = journal(paths, "transaction.json");
    if fs::symlink_metadata(&path).is_err() {
        return Ok(None);
    }
    let corrupt = || fail(STAGE, "Транзакция смены аккаунта GitHub повреждена и требует ручного вмешательства.");
    let bytes = read_optional(&path).map_err(|_| corrupt())?.unwrap_or_default();
    let marker: Marker = serde_json::from_slice(&bytes).map_err(|_| corrupt())?;
    if !marker.valid() {
        return Err(corrupt());
    }
    Ok(Some(marker))
}

fn write_marker(paths: &StatePaths, marker: &Marker) -> Result<()> {
    if !marker.valid() {
        return Err(fail(STAGE, "Параметры транзакции смены аккаунта имеют некорректный формат."));
    }
    secure_fs::create_dir_all(&paths.account_switch())?;
    let mut bytes = serde_json::to_vec_pretty(marker)?;
    bytes.push(b'\n');
    secure_fs::atomic_write(&journal(paths, "transaction.json"), &bytes)?;
    Ok(())
}

fn set_phase(paths: &StatePaths, marker: &mut Marker, phase: Phase, head: Option<String>) -> Result<()> {
    marker.phase = phase;
    marker.expected_head = head;
    write_marker(paths, marker)
}

fn remove(path: &Path) -> std::io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

/// Journal snapshots contain node passwords: they are sealed with the machine
/// key (AES-256-GCM, AAD = file role + transaction id), never stored in clear.
fn state_aad(name: &str, id: &str) -> String {
    format!("essence-rc account-switch {name} {id}")
}

fn write_state(paths: &StatePaths, locks: &LockManager, id: &str, name: &str, snapshot: &Snapshot) -> Result<()> {
    secure_fs::create_dir_all(&paths.account_switch())?;
    let plaintext = zeroize::Zeroizing::new(serde_json::to_vec(snapshot)?);
    let sealed = State::with_locks(paths.local(), locks.clone()).secret_store().seal(&state_aad(name, id), &plaintext)?;
    secure_fs::atomic_write(&journal(paths, name), &sealed)?;
    Ok(())
}

/// Fails closed: an unreadable snapshot keeps the journal for manual recovery.
fn read_state(paths: &StatePaths, locks: &LockManager, id: &str, name: &str) -> Result<Snapshot> {
    let path = journal(paths, name);
    let sealed = read_optional(&path)?.ok_or_else(|| fail(STAGE, "Снимок целевой конфигурации недоступен."))?;
    let plaintext = State::with_locks(paths.local(), locks.clone()).secret_store().open(&state_aad(name, id), &sealed)
        .map_err(|_| fail(STAGE, format!(
            "Снимок смены аккаунта {} не расшифровывается машинным ключом (secret.key отсутствует, повреждён или заменён). Журнал сохранён для ручного восстановления.",
            path.display())))?;
    let raw: Value = serde_json::from_slice(&plaintext).map_err(|_| fail(STAGE, "Снимок целевой конфигурации повреждён."))?;
    vault::upgrade(raw, false)
}

/// Undo an uncommitted switch: the target store and all journal files go.
fn rollback(paths: &StatePaths) -> Result<()> {
    let mut ok = true;
    for name in ["target-store", "target-sessions", "cached-sessions", "old-source.json", "old-state.sealed", "target-state.sealed", "transaction.json"] {
        ok &= remove(&journal(paths, name)).is_ok();
    }
    let _ = fs::remove_dir(paths.account_switch());
    if ok { Ok(()) } else { Err(fail(STAGE, "Не удалось отменить незавершённую смену аккаунта.")) }
}

fn cleanup(paths: &StatePaths) -> Result<()> {
    for name in ["old-store", "target-sessions", "cached-sessions", "old-source.json", "old-state.sealed", "target-state.sealed", "transaction.json"] {
        remove(&journal(paths, name)).map_err(|_| fail(STAGE, "Не удалось очистить завершённую смену аккаунта."))?;
    }
    let _ = fs::remove_dir(paths.account_switch());
    Ok(())
}

/// Install the target store as `github-store`, keeping the old one aside.
fn finalize(paths: &StatePaths, marker: &Marker) -> Result<()> {
    let stage = "локальная финализация смены аккаунта GitHub";
    let target_store = journal(paths, "target-store");
    let old_store = journal(paths, "old-store");
    if fs::symlink_metadata(&target_store).is_ok_and(|m| m.is_dir()) {
        remove(&old_store).map_err(|_| fail(stage, "Не удалось подготовить резерв прежнего хранилища."))?;
        if store::store_exists(&paths.github_store()) {
            fs::rename(paths.github_store(), &old_store).map_err(|_| fail(stage, "Не удалось переместить прежнее хранилище GitHub."))?;
        }
        fs::rename(&target_store, paths.github_store()).map_err(|_| fail(stage, "Не удалось установить новое хранилище GitHub."))?;
    } else if store::origin(&paths.github_store())?.as_deref() != Some(marker.new_target().url().as_str()) {
        return Err(fail(stage, "Хранилище транзакции не соответствует выбранному репозиторию."));
    }
    Ok(())
}

/// Committed switch: install the store, materialize the target state, point
/// `source.json` at the new repository and record `local_committed`. The
/// sealed snapshot is opened first, so an unreadable one changes nothing.
fn finish_target(paths: &StatePaths, locks: &LockManager, marker: &mut Marker) -> Result<()> {
    let snapshot = read_state(paths, locks, &marker.id, "target-state.sealed")?;
    finalize(paths, marker)?;
    vault::materialize(paths, locks, &snapshot)?;
    write_source(paths, &marker.new_target())?;
    set_phase(paths, marker, Phase::LocalCommitted, None)
}

/// v1 `github_account_switch_recover`, run before every GitHub session start.
pub fn recover(paths: &StatePaths, locks: &LockManager, log: &mut dyn FnMut(Level, &str)) -> Result<()> {
    let Some(mut marker) = read_marker(paths)? else { return Ok(()) };
    match marker.phase {
        Phase::Prepared => rollback(paths),
        Phase::PushUnknown => {
            let target = marker.new_target();
            let target_store = journal(paths, "target-store");
            let Some(expected) = marker.expected_head.clone().filter(|_| store::store_exists(&target_store)) else {
                return Err(fail(STAGE, "Транзакция смены аккаунта GitHub неполна и требует ручного вмешательства."));
            };
            store::account_login(paths, &target.owner)?;
            match store::ls_remote_has_branch(paths, &target, &target_store)? {
                None => Err(fail(STAGE, format!("Не удалось проверить отправку в {}.", target.repo()))),
                // No branch on the remote: the push never landed.
                Some(false) => rollback(paths),
                Some(true) => {
                    if !store::fetch(paths, &target, &target_store)?.success {
                        return Err(fail(STAGE, format!("Не удалось загрузить {} для проверки отправки.", target.repo())));
                    }
                    let head = store::rev(&target_store, &format!("refs/remotes/origin/{}", target.branch))?
                        .ok_or_else(|| fail(STAGE, "Не удалось прочитать загруженную ветку."))?;
                    if head == expected || store::is_ancestor(&target_store, &expected, &head)? {
                        store::update_ref(&target_store, &format!("refs/heads/{}", target.branch), &head)?;
                        set_phase(paths, &mut marker, Phase::TargetCommitted, Some(head))?;
                        finish_target(paths, locks, &mut marker)?;
                        log(Level::Info, &format!("Смена аккаунта GitHub завершена: {}.", target.repo()));
                        cleanup(paths)
                    } else {
                        rollback(paths)
                    }
                }
            }
        }
        Phase::TargetCommitted => {
            finish_target(paths, locks, &mut marker)?;
            log(Level::Info, &format!("Смена аккаунта GitHub завершена: {}.", marker.new_repo));
            cleanup(paths)
        }
        Phase::LocalCommitted => cleanup(paths),
    }
}

/// Another live worktree on the store means another running instance.
fn other_instances(store_path: &Path, current: Option<&Path>) -> Result<bool> {
    if !store::store_exists(store_path) {
        return Ok(false);
    }
    let _ = super::exec::store_git(store_path, &["worktree".as_ref(), "prune".as_ref()])?;
    let out = super::exec::store_git(store_path, &["worktree".as_ref(), "list".as_ref(), "--porcelain".as_ref()])?;
    let current = current.and_then(|path| fs::canonicalize(path).ok());
    Ok(out.text().lines().filter_map(|line| line.strip_prefix("worktree ")).any(|path| {
        let path = Path::new(path);
        path != store_path && fs::canonicalize(path).ok() != fs::canonicalize(store_path).ok()
            && fs::canonicalize(path).ok() != current
    }))
}

struct Choice {
    desired: Snapshot,
    push: bool,
    storage: Storage,
    keys: Option<Keys>,
    password: Option<String>,
    replace: bool,
    /// The target repository holds a valid configuration.
    target_valid: bool,
}

pub fn change_account(session: &mut Session, invocation: &Invocation, secrets: &Secrets) -> Result<Value> {
    if session.github.is_none() {
        return Err(RcError::new("not_configured", "Источник GitHub не подключён: source github-connect --login LOGIN."));
    }
    super::commands::decisions(invocation)?;
    let login = invocation.value("login").filter(|l| super::login_valid(l))
        .ok_or_else(|| RcError::new("usage", "Укажите аккаунт GitHub: --login LOGIN."))?.to_owned();
    let paths = session.state.paths().local();
    let profile_levels = [paths.credentials(), paths.credentials().join("gh"), paths.gh_profile(&login)];
    let profile_root = profile_levels.into_iter().find(|path| fs::symlink_metadata(path).is_err());
    let result = change_account_inner(session, invocation, secrets, &paths, &login);
    if result.is_err() && fs::symlink_metadata(journal(&paths, "transaction.json")).is_err() {
        if let Some(root) = profile_root {
            let _ = remove(&root);
        }
    }
    result.map_err(|error| prefixed(error, "Не удалось сменить аккаунт GitHub", "source_failed"))
}

fn change_account_inner(session: &mut Session, invocation: &Invocation, secrets: &Secrets, paths: &StatePaths, login: &str) -> Result<Value> {
    let old = session.github.as_ref().expect("checked").target.clone();
    let target = Target::new(login, &old.name, &old.branch);
    store::prepare_account(paths, login).map_err(|error| if super::is_auth_relevant(&error) {
        store::auth_required(paths, login, format!("Аккаунт GitHub {login} не авторизован: source github-login --login {login}."))
    } else {
        error
    })?;
    let sync = session.github.as_ref().expect("checked").sync;
    if target == old {
        session.log(Level::Info, &format!("Уже используется аккаунт {login}."));
        return Ok(json!({"repo": old.repo(), "sync": sync.as_str(), "old_repo_settings_url": null}));
    }
    let old_state = vault::serialize(&session.state).ok();
    if old_state.is_none() && !invocation.has("without-cache") {
        return Err(RcError::new("cache_skip_required",
            "Последний локальный кэш прежнего аккаунта недоступен: продолжить можно флагом --without-cache."));
    }
    if read_marker(paths)?.is_some() {
        return Err(fail("подготовка смены аккаунта GitHub", "Обнаружена незавершённая или повреждённая смена аккаунта GitHub."));
    }
    let current = session.github.as_ref().and_then(|g| g.work.as_ref()).map(|w| w.worktree.clone());
    if other_instances(&paths.github_store(), current.as_deref())? {
        return Err(fail("проверка активных сессий GitHub",
            "Другой экземпляр уже использует рабочую копию GitHub. Закройте его и повторите смену аккаунта."));
    }
    let mut marker = Marker {
        version: 1, id: super::random_hex(16), phase: Phase::Prepared, old_repo: old.repo(), new_repo: target.repo(), branch: old.branch.clone(),
        initial_login: old.owner.clone(), expected_head: None, old_state_available: old_state.is_some(),
        repo_created: false, repo_privatized: false,
    };
    write_marker(paths, &marker)?;
    let result = switch_prepared(session, invocation, secrets, paths, &target, &old, old_state, &mut marker);
    if result.is_err() && read_marker(paths).ok().flatten().is_some_and(|m| m.phase == Phase::Prepared) {
        let _ = rollback(paths);
    }
    result
}

#[allow(clippy::too_many_arguments)]
fn switch_prepared(session: &mut Session, invocation: &Invocation, secrets: &Secrets, paths: &StatePaths, target: &Target,
    old: &Target, old_state: Option<Snapshot>, marker: &mut Marker) -> Result<Value>
{
    let locks = session.state.locks().clone();
    if let Some(state) = &old_state {
        write_state(paths, &locks, &marker.id, "old-state.sealed", state)?;
    }
    if let Some(bytes) = read_optional(paths.source())? {
        secure_fs::atomic_write(&journal(paths, "old-source.json"), &bytes)?;
    }
    let prepared = store::sync_init(paths, target, &journal(paths, "target-store"), &journal(paths, "target-sessions"),
        Mode::Onboarding, RepoDecisions { create: invocation.has("create-repo"), make_private: invocation.has("make-private") },
        &mut |level, text| session.log(level, text))?;
    let pending = prepared.pending;
    let mut next = GithubSession { target: target.clone(), work: Some(prepared.work), storage: Storage::Plain, keys: None,
        sync: SyncStatus::Clean, last_counts: Value::Null, last_version: None };
    let decided = decide(session, invocation, secrets, paths, &mut next, old_state);
    let choice = match decided {
        Ok(choice) => choice,
        Err(error) => {
            let _ = next.close();
            return Err(error);
        }
    };
    let committed = commit_target(session, invocation, paths, target, old, &mut next, pending, choice, marker);
    if let Err(error) = committed {
        let _ = next.close();
        if marker.phase != Phase::Prepared {
            suspend(session, &marker.phase);
        }
        return Err(error);
    }
    Ok(json!({"repo": target.repo(), "sync": session.github.as_ref().map_or("pending", |g| g.sync.as_str()),
        "old_repo_settings_url": format!("https://github.com/{}/settings", old.repo())}))
}

fn decide(session: &mut Session, invocation: &Invocation, secrets: &Secrets, paths: &StatePaths, next: &mut GithubSession,
    old_state: Option<Snapshot>) -> Result<Choice>
{
    let tracked = next.work()?.tracked()?;
    let mut log = |level: Level, text: &str| session.log(level, text);
    let mut target_state = None;
    let mut replace = None;
    if !tracked.is_empty() {
        match next.read_vault(paths, secrets, false, false, &mut log) {
            Ok(snapshot) => target_state = Some(snapshot),
            Err(error) if matches!(error.code, "vault_password_required" | "vault_password_invalid") => return Err(error),
            Err(error) if error.code == "github_format_outdated" => {
                return Err(fail("проверка формата конфигурации GitHub", format!(
                    "Репозиторий {} содержит конфигурацию устаревшего формата. Смена аккаунта прервана.", next.target.repo()))
                    .with_extra("hint", "Выполните source github-switch-local и подключите GitHub заново под новым аккаунтом (source github-connect --existing migrate)."));
            }
            Err(error) if error.code == "github_format_newer" => return Err(error),
            Err(error) => replace = Some(error.message),
        }
    }
    if let Some(remote) = target_state {
        let local_counts = old_state.as_ref().map_or(Value::Null, Snapshot::counts);
        let existing = invocation.value("existing");
        if existing == Some("migrate") {
            return Err(RcError::new("usage", "Флаг --existing принимает remote или local."));
        }
        let mut choices = vec!["remote"];
        if old_state.is_some() {
            choices.push("local");
        }
        return match existing.filter(|e| choices.contains(e)) {
            Some("remote") => Ok(Choice { desired: remote, push: false, storage: next.storage, keys: next.keys.clone(), password: None, replace: false, target_valid: true }),
            Some(_) => Ok(Choice { desired: old_state.expect("local allowed"), push: true, storage: next.storage, keys: next.keys.clone(), password: None, replace: false, target_valid: true }),
            None => Err(RcError::new("existing_config_action_required",
                format!("В репозитории уже есть конфигурация: --existing {}.", choices.join("|")))
                .with_extra("choices", choices).with_extra("remote_counts", remote.counts()).with_extra("local_counts", local_counts)),
        };
    }
    if let Some(reason) = replace.as_deref().filter(|_| !invocation.has("replace-target")) {
        return Err(RcError::new("target_replace_required", format!(
            "Репозиторий {} содержит посторонние файлы: заменить их можно флагом --replace-target.", next.target.repo()))
            .with_extra("repo", next.target.repo()).with_extra("tracked_files", tracked.len()).with_extra("reason", reason));
    }
    let storage = match invocation.value("storage").map(Storage::parse) {
        Some(Some(storage)) => storage,
        Some(None) => return Err(RcError::new("usage", "Флаг --storage принимает age или none.")),
        None => return Err(RcError::new("storage_mode_required", "Выберите способ хранения конфигурации GitHub: --storage age|none.")
            .with_extra("choices", ["age", "none"])),
    };
    let password = if storage == Storage::Age {
        let password = secrets.get("new-vault-password").filter(|p| !p.is_empty()).ok_or_else(|| {
            RcError::new("new_vault_password_required", "Требуется новый пароль доступа к конфигурации GitHub (секрет new-vault-password).")
                .with_extra("secret", "new-vault-password")
        })?;
        if password.ends_with(['\r', '\n']) {
            return Err(RcError::new("invalid", "Пароль доступа не должен заканчиваться переводом строки."));
        }
        Some(password.to_owned())
    } else {
        None
    };
    let push = true;
    let desired = old_state.unwrap_or_else(vault::empty_snapshot);
    Ok(Choice { desired, push, storage, keys: None, password, replace: replace.is_some(), target_valid: false })
}

#[allow(clippy::too_many_arguments)]
fn commit_target(session: &mut Session, invocation: &Invocation, paths: &StatePaths, target: &Target, old: &Target,
    next: &mut GithubSession, pending: PendingRepo, choice: Choice, marker: &mut Marker) -> Result<()>
{
    let counts = |snapshot: &Snapshot| vault::counts_label(&snapshot.counts());
    let mut lines = vec!["Смена аккаунта GitHub".to_owned(), format!("Репозиторий: {} (ветка {})", target.repo(), target.branch)];
    let mut risky = false;
    match pending {
        PendingRepo::Create => lines.push("Будет создан приватный репозиторий.".into()),
        PendingRepo::Private => { lines.push("Публичный репозиторий станет приватным.".into()); risky = true; }
        PendingRepo::None => {}
    }
    lines.push(format!("Прежний репозиторий {} не изменится; синхронизация с ним прекратится.", old.repo()));
    let storage_lines = |lines: &mut Vec<String>, risky: &mut bool| if choice.storage == Storage::Plain {
        lines.push("Пароли SSH и ключи будут храниться в GitHub без шифрования".into());
        lines.push("и навсегда останутся в истории Git.".into());
        *risky = true;
    } else {
        lines.push("Хранение: зашифровано паролем доступа (age).".into());
    };
    if !choice.push {
        lines.push(format!("Будет использована конфигурация из {}: {}.", target.repo(), counts(&choice.desired)));
    } else if choice.target_valid {
        lines.push(format!("Конфигурация в {} будет заменена текущей ({}) и останется только в истории Git.", target.repo(), counts(&choice.desired)));
        storage_lines(&mut lines, &mut risky);
        risky = true;
    } else {
        if choice.replace {
            lines.push(format!("Из {} будут удалены все файлы ({}); они останутся только в истории Git.", target.repo(), next.work()?.tracked()?.len()));
            risky = true;
        }
        if marker.old_state_available {
            lines.push(format!("В {} будет отправлена текущая конфигурация: {}.", target.repo(), counts(&choice.desired)));
        } else {
            lines.push(format!("В {} будет отправлена пустая конфигурация: кэш прежнего аккаунта недоступен.", target.repo()));
        }
        storage_lines(&mut lines, &mut risky);
    }
    if risky {
        Plan::new(lines, "").confirm(invocation)?;
    }
    store::apply_pending(paths, target, pending)?;
    marker.repo_created = pending == PendingRepo::Create;
    marker.repo_privatized = pending == PendingRepo::Private;
    write_marker(paths, marker)?;
    if choice.replace {
        next.work()?.remove_all()?;
    }
    next.storage = choice.storage;
    next.keys = choice.keys;
    if let Some(password) = &choice.password {
        let keys = Keys::generate();
        vault::publish_keys(&next.work()?.worktree, &keys, password)?;
        next.keys = Some(keys);
    }
    write_state(paths, &session.state.locks().clone(), &marker.id, "target-state.sealed", &choice.desired)?;
    let head = if choice.push {
        next.checkpoint(&choice.desired)?;
        let work = next.work()?.clone();
        let head = match store::commit(&work, next.storage, false)? {
            Some(head) => head,
            None => work.head()?,
        };
        set_phase(paths, marker, Phase::PushUnknown, Some(head.clone()))?;
        store::push(paths, target, &work, &head)?;
        set_phase(paths, marker, Phase::TargetCommitted, Some(head.clone()))?;
        head
    } else {
        next.work()?.head()?
    };
    next.close()?;
    let manager = session.state.locks().clone();
    if let Some(mut current) = session.github.take() {
        current.close()?;
    }
    if !choice.push {
        set_phase(paths, marker, Phase::TargetCommitted, Some(head))?;
    }
    finish_target(paths, &manager, marker)?;
    cleanup(paths)?;
    let work = store::open_worktree(&paths.github_store(), &paths.github_sessions(), &target.branch)?;
    session.state = State::with_locks(paths.runtime(), manager);
    session.github = Some(GithubSession { target: target.clone(), work: Some(work), storage: next.storage, keys: next.keys.take(),
        sync: SyncStatus::Clean, last_counts: Value::Null, last_version: None });
    session.log(Level::Success, &format!("Аккаунт GitHub изменён: {}.", target.owner));
    Ok(())
}

/// The push outcome is unknown or the switch is committed but unfinished:
/// the journal stays; both sessions close and nothing syncs until the next
/// session open verifies and finishes or rolls back the switch.
fn suspend(session: &mut Session, phase: &Phase) {
    if let Some(mut current) = session.github.take() {
        let _ = current.close();
    }
    let paths = session.state.paths().local();
    session.state = State::with_locks(paths, session.state.locks().clone());
    session.open = false;
    let _ = session.state.locks().release_all();
    if *phase == Phase::PushUnknown {
        session.log(Level::Warn, "Результат отправки в новый репозиторий не подтверждён. Синхронизация и изменения приостановлены.");
    } else {
        session.log(Level::Warn, "Смена аккаунта GitHub не завершена. Синхронизация и изменения приостановлены.");
    }
    session.log(Level::Info, "Откройте сессию заново (session open): смена аккаунта будет проверена и завершена или отменена.");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marker(phase: Phase) -> Marker {
        Marker { version: 1, id: "0123456789abcdef0123456789abcdef".into(), phase, old_repo: "old-owner/essence-remote-control-config".into(),
            new_repo: "new-owner/essence-remote-control-config".into(), branch: "main".into(), initial_login: "old-owner".into(),
            expected_head: None, old_state_available: true, repo_created: false, repo_privatized: false }
    }

    #[test]
    fn journal_snapshots_are_sealed_and_fail_closed() {
        let dir = tempfile::tempdir().unwrap();
        let paths = StatePaths::new(dir.path());
        let locks = LockManager::new(dir.path());
        let id = "c".repeat(32);
        let mut snapshot = vault::empty_snapshot();
        snapshot.config.nodes.push(serde_json::from_value(serde_json::json!({
            "id": id, "name": "n1", "ip": "10.0.0.1", "port": 22, "user": "root", "auth": "password",
            "identity": null, "secret_id": format!("node:{id}:ssh-password"), "aliases": {}
        })).unwrap());
        snapshot.secrets.node_passwords.insert(format!("node:{id}:ssh-password"), zeroize::Zeroizing::new("sentinel-pw-7731".into()));
        let committed = marker(Phase::TargetCommitted);
        write_marker(&paths, &committed).unwrap();
        write_state(&paths, &locks, &committed.id, "target-state.sealed", &snapshot).unwrap();
        let on_disk = fs::read(journal(&paths, "target-state.sealed")).unwrap();
        assert!(!String::from_utf8_lossy(&on_disk).contains("sentinel-pw-7731") && !String::from_utf8_lossy(&on_disk).contains("ssh-password"));
        assert!(paths.secret_key().exists(), "the machine key is created on first use");
        let opened = read_state(&paths, &locks, &committed.id, "target-state.sealed").unwrap();
        assert_eq!(&*opened.secrets.node_passwords[&format!("node:{id}:ssh-password")], "sentinel-pw-7731");
        assert!(read_state(&paths, &locks, &"d".repeat(32), "target-state.sealed").is_err(), "bound to the transaction id");
        assert!(read_state(&paths, &locks, &committed.id, "old-state.sealed").is_err());

        fs::remove_file(paths.secret_key()).unwrap();
        let error = recover(&paths, &locks, &mut |_, _| {}).unwrap_err();
        assert!(error.message.contains("не расшифровывается"), "{}", error.message);
        assert!(journal(&paths, "transaction.json").exists() && journal(&paths, "target-state.sealed").exists(), "fail closed");
        assert!(!paths.github_runtime().exists() && !paths.source().exists());
        assert_eq!(read_marker(&paths).unwrap().unwrap().phase, Phase::TargetCommitted);
    }

    #[test]
    fn journal_is_strict_and_prepared_switches_roll_back() {
        let dir = tempfile::tempdir().unwrap();
        let paths = StatePaths::new(dir.path());
        let locks = LockManager::new(dir.path());
        assert!(read_marker(&paths).unwrap().is_none());
        let mut bad = marker(Phase::Prepared);
        bad.expected_head = Some("xyz".into());
        assert!(write_marker(&paths, &bad).is_err());
        write_marker(&paths, &marker(Phase::Prepared)).unwrap();
        fs::create_dir_all(journal(&paths, "target-store/objects")).unwrap();
        fs::write(journal(&paths, "old-state.sealed"), "{}").unwrap();
        recover(&paths, &locks, &mut |_, _| {}).unwrap();
        assert!(!paths.account_switch().exists(), "prepared phase removes the whole journal");

        secure_fs::create_dir_all(&paths.account_switch()).unwrap();
        fs::write(journal(&paths, "transaction.json"), r#"{"version":1}"#).unwrap();
        let error = recover(&paths, &locks, &mut |_, _| {}).unwrap_err();
        assert!(error.message.contains("повреждена"), "{}", error.message);
        assert!(journal(&paths, "transaction.json").exists(), "a corrupt journal is never discarded");
    }
}
