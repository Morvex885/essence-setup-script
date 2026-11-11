//! gh accounts and repositories, the bare mirror, session worktrees and flush
//! (v1 `_github_prepare_account`, `github_sync_init`, `github_sync_flush`).

use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};

use zeroize::Zeroizing;

use super::exec::{self, NETWORK_TIMEOUT, Output};
use super::vault::{self, TreeMode};
use super::{SyncStatus, Storage, Target, auth_fail, fail, login_valid, random_hex, safe_error, utc_stamp};
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::secure_fs;
use crate::state::StatePaths;

const AUTHOR: [&str; 4] = ["-c", "user.name=Essence Remote Control", "-c", "user.email=remote-control@localhost"];
const ACCOUNT_STAGE: &str = "проверка аккаунта GitHub";
const PUSH_STAGE: &str = "отправка конфигурации в GitHub";

/// Journal callback of the running command.
pub type Log<'a> = &'a mut dyn FnMut(Level, &str);

fn args<'a>(list: &'a [&'a str]) -> Vec<&'a OsStr> {
    list.iter().map(OsStr::new).collect()
}

// ─── Accounts (isolated GH_CONFIG_DIR per login) ─────────────────────────────

pub fn prepare_profile(paths: &StatePaths, login: &str) -> Result<PathBuf> {
    if !login_valid(login) {
        return Err(RcError::new("usage", format!("Некорректный логин GitHub: {}.", safe_error(login))));
    }
    let profile = paths.gh_profile(login);
    secure_fs::create_dir_all(&profile)?;
    match fs::symlink_metadata(profile.join("hosts.yml")) {
        Ok(meta) if !meta.is_file() => Err(fail("авторизация аккаунта GitHub", "Файл hosts.yml профиля имеет недопустимый тип.")),
        _ => Ok(profile),
    }
}

fn has_profile(paths: &StatePaths, login: &str) -> bool {
    let profile = paths.gh_profile(login);
    fs::symlink_metadata(&profile).is_ok_and(|m| m.is_dir())
        && fs::symlink_metadata(profile.join("hosts.yml")).is_ok_and(|m| m.is_file())
}

fn auth_failure_confirmed(output: &str) -> bool {
    let lower = output.to_lowercase();
    let has_401 = lower.match_indices("401").any(|(i, _)| {
        let before = lower[..i].chars().next_back().is_none_or(|c| !c.is_ascii_digit());
        let after = lower[i + 3..].chars().next().is_none_or(|c| !c.is_ascii_digit());
        before && after
    });
    has_401 || ["bad credentials", "not logged", "not authenticated", "authentication failed", "authentication required",
        "token is invalid", "token invalid", "token is expired", "token expired", "token is revoked", "token revoked"]
        .iter().any(|needle| lower.contains(needle))
}

fn login_hint(paths: &StatePaths, login: &str) -> String {
    format!("Выполните: GH_CONFIG_DIR={} gh auth login --hostname github.com --web", paths.gh_profile(login).display())
}

/// `gh api user --jq .login` in the profile must name exactly `login`.
pub fn account_login(paths: &StatePaths, login: &str) -> Result<()> {
    let profile = prepare_profile(paths, login)?;
    let mut command = exec::gh(Some(&profile));
    command.args(["api", "user", "--jq", ".login"]);
    let out = exec::run(command, None, NETWORK_TIMEOUT)?;
    if !out.success {
        let detail = out.diagnostic();
        return Err(if auth_failure_confirmed(&detail) {
            auth_fail(ACCOUNT_STAGE, detail, Some(login_hint(paths, login)))
        } else {
            fail(ACCOUNT_STAGE, detail)
        });
    }
    let actual = out.text();
    if actual != login {
        let shown = if actual.is_empty() { "неизвестный пользователь".into() } else { safe_error(&actual) };
        return Err(auth_fail(ACCOUNT_STAGE, format!("Профиль {login} авторизован как {shown}."), Some(login_hint(paths, login))));
    }
    Ok(())
}

/// Copy a token from the global gh login into the isolated profile; the token
/// passes from one child's stdout to the other's stdin in a wiping buffer.
fn import_account(paths: &StatePaths, login: &str) -> Result<bool> {
    let profile = prepare_profile(paths, login)?;
    let mut token = exec::gh(None);
    token.args(["auth", "token", "--hostname", "github.com", "--user", login]);
    let out = exec::run(token, None, NETWORK_TIMEOUT)?;
    let value = Zeroizing::new(out.text().into_bytes());
    if !out.success || value.is_empty() {
        return Ok(false);
    }
    let mut command = exec::gh(Some(&profile));
    command.args(["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--with-token"]);
    Ok(exec::run(command, Some(&value), NETWORK_TIMEOUT)?.success)
}

/// v1 `_github_prepare_account`: verify a saved profile or import the global
/// login. Failures carry `auth_relevant` and a login hint.
pub fn prepare_account(paths: &StatePaths, login: &str) -> Result<()> {
    if has_profile(paths, login) {
        return account_login(paths, login);
    }
    if import_account(paths, login)? && account_login(paths, login).is_ok() {
        return Ok(());
    }
    Err(auth_fail("авторизация аккаунта GitHub", format!("Учётные данные аккаунта {login} недоступны или не совпадают."),
        Some(login_hint(paths, login))))
}

pub fn auth_required(paths: &StatePaths, login: &str, message: String) -> RcError {
    RcError::new("github_auth_required", message)
        .with_extra("login", login)
        .with_extra("hint", login_hint(paths, login))
}

/// Browser login into the isolated profile; gh's device code reaches the
/// journal as sanitized lines.
pub fn web_login(paths: &StatePaths, login: &str, log: Log<'_>) -> Result<()> {
    let profile = prepare_profile(paths, login)?;
    let mut command = exec::gh(Some(&profile));
    command.env_remove("GH_PROMPT_DISABLED");
    command.args(["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web"]);
    let ok = exec::run_streaming(command, exec::WEB_LOGIN_TIMEOUT, |line| log(Level::Output, &safe_error(line)))?;
    if ok && account_login(paths, login).is_ok() {
        return Ok(());
    }
    Err(auth_required(paths, login, format!("Не удалось войти в GitHub как {login}.")))
}

pub fn global_login() -> Option<String> {
    let mut command = exec::gh(None);
    command.args(["api", "user", "--jq", ".login"]);
    let out = exec::run(command, None, NETWORK_TIMEOUT).ok()?;
    let login = out.text();
    (out.success && login_valid(&login)).then_some(login)
}

pub fn accounts(paths: &StatePaths) -> Vec<String> {
    let mut list: Vec<String> = fs::read_dir(paths.credentials().join("gh")).into_iter().flatten().flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| login_valid(name) && has_profile(paths, name))
        .collect();
    list.sort();
    list
}

// ─── Repository (gh repo …) ──────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Visibility { Private, Public, Missing }

fn gh_repo(paths: &StatePaths, target: &Target, list: &[&str]) -> Result<Output> {
    let profile = prepare_profile(paths, &target.owner)?;
    let mut command = exec::gh(Some(&profile));
    command.args(list);
    exec::run(command, None, NETWORK_TIMEOUT)
}

pub fn repo_view(paths: &StatePaths, target: &Target) -> Result<Visibility> {
    let out = gh_repo(paths, target, &["repo", "view", &target.repo(), "--json", "visibility"])?;
    if !out.success {
        let detail = out.diagnostic();
        let lower = detail.to_lowercase();
        if lower.contains("not found") || lower.contains("could not resolve to a repository") {
            return Ok(Visibility::Missing);
        }
        return Err(if auth_failure_confirmed(&detail) { auth_fail("проверка приватного репозитория", detail, None) }
            else { fail("проверка приватного репозитория", detail) });
    }
    let value: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or_default();
    Ok(if value["visibility"] == "PRIVATE" { Visibility::Private } else { Visibility::Public })
}

pub fn repo_create(paths: &StatePaths, target: &Target) -> Result<()> {
    let out = gh_repo(paths, target, &["repo", "create", &target.repo(), "--private", "--description", "Essence Remote Control configuration"])?;
    if !out.success {
        return Err(fail("создание приватного репозитория", out.diagnostic()));
    }
    Ok(())
}

pub fn repo_make_private(paths: &StatePaths, target: &Target) -> Result<()> {
    let out = gh_repo(paths, target, &["repo", "edit", &target.repo(), "--visibility", "private", "--accept-visibility-change-consequences"])?;
    if !out.success {
        return Err(fail("изменение видимости репозитория", out.diagnostic()));
    }
    if repo_view(paths, target)? != Visibility::Private {
        return Err(fail("проверка приватного репозитория", format!("Не удалось подтвердить приватность репозитория {}.", target.repo())));
    }
    Ok(())
}

pub fn repo_delete(paths: &StatePaths, target: &Target) -> Result<()> {
    let out = gh_repo(paths, target, &["repo", "delete", &target.repo(), "--yes"])?;
    if !out.success {
        return Err(fail("удаление репозитория GitHub", out.diagnostic()));
    }
    Ok(())
}

// ─── Bare store primitives ───────────────────────────────────────────────────

fn store_run(store: &Path, list: &[&str]) -> Result<Output> {
    exec::store_git(store, &args(list))
}

fn store_ok(store: &Path, stage: &str, list: &[&str]) -> Result<Output> {
    let out = store_run(store, list)?;
    if !out.success {
        return Err(fail(stage, out.diagnostic()));
    }
    Ok(out)
}

pub fn has_ref(store: &Path, name: &str) -> Result<bool> {
    Ok(store_run(store, &["show-ref", "--verify", "--quiet", name])?.success)
}

pub fn rev(store: &Path, name: &str) -> Result<Option<String>> {
    let out = store_run(store, &["rev-parse", "--verify", "--quiet", &format!("{name}^{{commit}}")])?;
    Ok(out.success.then(|| out.text()))
}

pub fn is_ancestor(store: &Path, ancestor: &str, descendant: &str) -> Result<bool> {
    Ok(store_run(store, &["merge-base", "--is-ancestor", ancestor, descendant])?.success)
}

pub fn update_ref(store: &Path, name: &str, oid: &str) -> Result<()> {
    store_ok(store, "обновление локальной копии репозитория", &["update-ref", name, oid]).map(drop)
}

fn delete_ref(store: &Path, name: &str) -> Result<()> {
    if !has_ref(store, name)? {
        return Ok(());
    }
    store_ok(store, "обновление локальной копии репозитория", &["update-ref", "-d", name]).map(drop)
}

/// The configured (not insteadOf-rewritten) origin URL.
pub fn origin(store: &Path) -> Result<Option<String>> {
    let out = store_run(store, &["config", "--get", "remote.origin.url"])?;
    Ok(out.success.then(|| out.text()))
}

pub fn store_exists(store: &Path) -> bool {
    fs::symlink_metadata(store).is_ok_and(|m| m.is_dir()) && store.join("objects").is_dir()
}

fn archive(store: &Path, oid: &str, label: &str) -> Result<()> {
    let name = format!("refs/archive/{label}-{}-{}", utc_stamp(), random_hex(4));
    store_ok(store, "сохранение локальной истории", &["update-ref", &name, oid]).map(drop)
}

fn remote(paths: &StatePaths, target: &Target, store: &Path, list: &[&str]) -> Result<Output> {
    let profile = prepare_profile(paths, &target.owner)?;
    let mut command = exec::remote_git(&profile, &target.owner);
    command.arg("--git-dir").arg(store).args(list);
    exec::run(command, None, NETWORK_TIMEOUT)
}

/// `Some(empty)` when the remote has no such branch, `None` when unreachable.
fn ls_remote(paths: &StatePaths, target: &Target, store: &Path) -> Result<Option<bool>> {
    let out = remote(paths, target, store, &["ls-remote", "origin", &format!("refs/heads/{}", target.branch)])?;
    Ok(out.success.then(|| out.stdout.iter().all(u8::is_ascii_whitespace)))
}

pub fn ls_remote_has_branch(paths: &StatePaths, target: &Target, store: &Path) -> Result<Option<bool>> {
    Ok(ls_remote(paths, target, store)?.map(|empty| !empty))
}

/// Force-updates only the remote-tracking ref: a rewritten remote history must
/// still be fetched; the local branch is reconciled by explicit ancestry checks.
fn tracking_refspec(branch: &str) -> String {
    format!("+refs/heads/{branch}:refs/remotes/origin/{branch}")
}

pub fn fetch(paths: &StatePaths, target: &Target, store: &Path) -> Result<Output> {
    remote(paths, target, store, &["fetch", "--no-tags", "origin", &tracking_refspec(&target.branch)])
}

// ─── Session worktrees ───────────────────────────────────────────────────────

/// One open session: `sessions/<id>/worktree` on branch `session/<id>`.
#[derive(Clone, Debug)]
pub struct WorkSession {
    pub store: PathBuf,
    pub sessions: PathBuf,
    pub id: String,
    pub worktree: PathBuf,
    pub branch: String,
    pub origin: String,
}

impl WorkSession {
    pub fn session_ref(&self) -> String {
        format!("refs/heads/session/{}", self.id)
    }

    pub fn tracked(&self) -> Result<Vec<String>> {
        let out = exec::tree_git(&self.worktree, &args(&["ls-files"]))?;
        if !out.success {
            return Err(fail("проверка существующего репозитория GitHub", "Не удалось проверить содержимое репозитория GitHub. Репозиторий не изменён."));
        }
        Ok(out.text().lines().filter(|l| !l.is_empty()).map(str::to_owned).collect())
    }

    pub fn head(&self) -> Result<String> {
        let out = exec::tree_git(&self.worktree, &args(&["rev-parse", "HEAD"]))?;
        if !out.success {
            return Err(fail("чтение локальной версии конфигурации", out.diagnostic()));
        }
        Ok(out.text())
    }

    /// `git rm -r -f -- .`: replace foreign files of a target repository.
    pub fn remove_all(&self) -> Result<()> {
        let out = exec::tree_git(&self.worktree, &args(&["rm", "-r", "-f", "-q", "--", "."]))?;
        if !out.success {
            return Err(fail("очистка целевого репозитория", out.diagnostic()));
        }
        Ok(())
    }

    /// `reset --hard <head>`: undo a failed publication of key files.
    pub fn reset_hard(&self, head: &str) -> Result<()> {
        let out = exec::tree_git(&self.worktree, &args(&["reset", "-q", "--hard", head]))?;
        if !out.success {
            return Err(fail("откат рабочей копии GitHub", out.diagnostic()));
        }
        Ok(())
    }
}

pub fn new_session_id() -> String {
    format!("{}-{}-{}", utc_stamp(), std::process::id(), random_hex(4))
}

/// `worktree add -b session/<id> <dir>/worktree <branch>`.
pub fn open_worktree(store: &Path, sessions: &Path, branch: &str) -> Result<WorkSession> {
    let stage = "подготовка рабочей копии конфигурации";
    if !store_exists(store) || !has_ref(store, &format!("refs/heads/{branch}"))? {
        return Err(fail(stage, "Локальная ветка конфигурации GitHub недоступна."));
    }
    secure_fs::create_dir_all(sessions)?;
    let id = new_session_id();
    let dir = sessions.join(&id);
    secure_fs::create_dir(&dir)?;
    let worktree = dir.join("worktree");
    let mut command = exec::git();
    command.arg("--git-dir").arg(store).args(["worktree", "add", "-q", "-b", &format!("session/{id}")]).arg(&worktree).arg(branch);
    let out = exec::run(command, None, exec::LOCAL_TIMEOUT)?;
    if !out.success {
        let _ = fs::remove_dir_all(&dir);
        return Err(fail(stage, out.diagnostic()));
    }
    let origin = origin(store)?.unwrap_or_default();
    Ok(WorkSession { store: store.into(), sessions: sessions.into(), id, worktree, branch: branch.into(), origin })
}

/// v1 `github_config_close`: remove the worktree, its session branch and dir.
pub fn close(work: &WorkSession) -> Result<()> {
    if work.worktree.exists() {
        let mut command = exec::git();
        command.arg("--git-dir").arg(&work.store).args(["worktree", "remove", "--force"]).arg(&work.worktree);
        let out = exec::run(command, None, exec::LOCAL_TIMEOUT)?;
        if !out.success {
            return Err(fail("закрытие рабочей сессии GitHub", out.diagnostic()));
        }
    }
    if store_exists(&work.store) && has_ref(&work.store, &work.session_ref())? {
        store_ok(&work.store, "удаление ссылки рабочей сессии GitHub", &["update-ref", "-d", &work.session_ref()])?;
    }
    let dir = work.sessions.join(&work.id);
    if dir.exists() {
        fs::remove_dir(&dir).map_err(|_| fail("очистка каталога рабочей сессии GitHub", "Не удалось удалить пустой каталог завершённой сессии."))?;
    }
    Ok(())
}

// ─── github_sync_init ────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode { Resume, Onboarding }

/// Remote repository change deferred until after consent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PendingRepo { None, Create, Private }

#[derive(Clone, Copy, Default)]
pub struct RepoDecisions {
    pub create: bool,
    pub make_private: bool,
}

pub struct Prepared {
    pub work: WorkSession,
    pub sync: SyncStatus,
    pub pending: PendingRepo,
}

/// The branch holds committed configuration files, not just the initial empty state.
fn holds_snapshot(store: &Path, name: &str) -> Result<bool> {
    if !has_ref(store, name)? {
        return Ok(false);
    }
    let out = store_ok(store, "чтение локальной версии конфигурации", &["ls-tree", "--name-only", name])?;
    Ok(!out.text().is_empty())
}

fn pending_status(store: &Path, branch: &str) -> Result<SyncStatus> {
    let local = rev(store, &format!("refs/heads/{branch}"))?;
    let tracking = rev(store, &format!("refs/remotes/origin/{branch}"))?;
    Ok(match (local, tracking) {
        (Some(local), Some(tracking)) if local != tracking && is_ancestor(store, &tracking, &local)? => SyncStatus::Pending,
        (Some(_), None) => SyncStatus::Pending,
        _ => SyncStatus::Offline,
    })
}

/// v1 `github_sync_init`: verify the account and the private repository, bring
/// the bare mirror up to date without merging and open a session worktree.
pub fn sync_init(paths: &StatePaths, target: &Target, store: &Path, sessions: &Path, mode: Mode,
    decisions: RepoDecisions, log: Log<'_>) -> Result<Prepared>
{
    let local_ref = format!("refs/heads/{}", target.branch);
    let remote_ref = format!("refs/remotes/origin/{}", target.branch);
    if let Err(error) = prepare_account(paths, &target.owner) {
        // A saved profile that is merely unreachable resumes the cached branch.
        let offline = mode == Mode::Resume && has_profile(paths, &target.owner) && !super::is_auth_relevant(&error)
            && store_exists(store) && origin(store)?.as_deref() == Some(target.url().as_str()) && has_ref(store, &local_ref)?;
        if !offline {
            return Err(error);
        }
        let work = open_worktree(store, sessions, &target.branch)?;
        let sync = pending_status(store, &target.branch)?;
        log(Level::Warn, "GitHub недоступен: открыта локальная копия конфигурации.");
        return Ok(Prepared { work, sync, pending: PendingRepo::None });
    }
    let repo = target.repo();
    let mut pending = PendingRepo::None;
    match repo_view(paths, target)? {
        Visibility::Private => {}
        Visibility::Missing if mode == Mode::Onboarding => {
            if !decisions.create {
                return Err(RcError::new("repo_create_required", format!("Репозиторий {repo} не найден: создайте его флагом --create-repo."))
                    .with_extra("repo", repo));
            }
            pending = PendingRepo::Create;
        }
        Visibility::Missing => return Err(fail("проверка приватного репозитория", format!("Репозиторий {repo} не найден."))),
        Visibility::Public if mode == Mode::Onboarding => {
            if !decisions.make_private {
                return Err(RcError::new("repo_private_required", format!("Репозиторий {repo} публичный: сделайте его приватным флагом --make-private."))
                    .with_extra("repo", repo));
            }
            pending = PendingRepo::Private;
        }
        Visibility::Public => return Err(fail("проверка приватного репозитория", format!("Репозиторий {repo} должен быть приватным."))),
    }
    secure_fs::create_dir_all(store)?;
    secure_fs::create_dir_all(sessions)?;
    if !store.join("objects").is_dir() {
        let mut command = exec::git();
        command.args(["init", "-q", "--bare"]).arg(store);
        let out = exec::run(command, None, exec::LOCAL_TIMEOUT)?;
        if !out.success {
            return Err(fail("подготовка локального репозитория", out.diagnostic()));
        }
    }
    let url = target.url();
    let mut remote_changed = false;
    match origin(store)? {
        Some(current) if current == url => {}
        Some(_) => {
            store_ok(store, "настройка адреса репозитория", &["remote", "set-url", "origin", &url])?;
            remote_changed = true;
        }
        None => { store_ok(store, "настройка адреса репозитория", &["remote", "add", "origin", &url])?; }
    }
    let fetched = fetch(paths, target, store)?;
    let fetch_ok = fetched.success && has_ref(store, &remote_ref)?;
    let mut sync = SyncStatus::Clean;
    if mode == Mode::Onboarding {
        if fetch_ok {
            let remote_oid = rev(store, &remote_ref)?.unwrap_or_default();
            if let Some(local_oid) = rev(store, &local_ref)? {
                if local_oid != remote_oid && !is_ancestor(store, &local_oid, &remote_oid)? {
                    archive(store, &local_oid, "onboarding")?;
                }
            }
            update_ref(store, &local_ref, &remote_oid)?;
        } else {
            let empty = if pending == PendingRepo::Create { Some(true) } else { ls_remote(paths, target, store)? };
            if empty != Some(true) {
                return Err(fail("загрузка репозитория GitHub", fetched.diagnostic()));
            }
            if let Some(previous) = rev(store, &local_ref)? {
                archive(store, &previous, "onboarding")?;
            }
            delete_ref(store, &local_ref)?;
            delete_ref(store, &remote_ref)?;
        }
    } else if fetch_ok {
        let remote_oid = rev(store, &remote_ref)?.unwrap_or_default();
        match rev(store, &local_ref)? {
            None => update_ref(store, &local_ref, &remote_oid)?,
            Some(local_oid) if local_oid == remote_oid => {}
            // A previous process committed locally while push was unavailable.
            Some(local_oid) if is_ancestor(store, &remote_oid, &local_oid)? => sync = SyncStatus::Pending,
            Some(local_oid) if is_ancestor(store, &local_oid, &remote_oid)? => update_ref(store, &local_ref, &remote_oid)?,
            Some(_) => return Err(fail("сверка локальных и удалённых изменений",
                "Локальная конфигурация и GitHub изменились независимо. Автоматическое объединение остановлено, чтобы не потерять данные.")),
        }
    } else {
        let empty = ls_remote(paths, target, store)?;
        if remote_changed {
            if empty != Some(true) {
                return Err(fail("загрузка нового репозитория GitHub", fetched.diagnostic()));
            }
            let previous = match rev(store, &local_ref)? { Some(oid) => Some(oid), None => rev(store, &remote_ref)? };
            if let Some(previous) = previous {
                archive(store, &previous, "remote-switch")?;
            }
            delete_ref(store, &local_ref)?;
            delete_ref(store, &remote_ref)?;
            log(Level::Info, "Репозиторий GitHub изменён: прежняя история сохранена локально, новый пустой репозиторий будет инициализирован отдельно.");
        } else if !has_ref(store, &local_ref)? && empty != Some(true) {
            return Err(fail("загрузка репозитория GitHub", fetched.diagnostic()));
        }
        sync = match empty {
            // No branch on GitHub yet: a pinned local snapshot still waits for push.
            Some(true) if holds_snapshot(store, &local_ref)? => SyncStatus::Pending,
            Some(true) => SyncStatus::Clean,
            _ => pending_status(store, &target.branch)?,
        };
    }
    if !has_ref(store, &local_ref)? {
        let stage = "создание локальной ветки конфигурации";
        let mut mktree = exec::git();
        mktree.arg("--git-dir").arg(store).arg("mktree");
        let tree = exec::run(mktree, Some(b""), exec::LOCAL_TIMEOUT)?;
        if !tree.success {
            return Err(fail(stage, tree.diagnostic()));
        }
        let mut list = AUTHOR.to_vec();
        let tree_oid = tree.text();
        list.extend(["commit-tree", &tree_oid, "-m", "Initial empty state"]);
        let commit = store_ok(store, stage, &list)?;
        update_ref(store, &local_ref, &commit.text())?;
    }
    let work = open_worktree(store, sessions, &target.branch)?;
    Ok(Prepared { work, sync, pending })
}

/// Apply the deferred repository creation or privatization after consent.
pub fn apply_pending(paths: &StatePaths, target: &Target, pending: PendingRepo) -> Result<()> {
    match pending {
        PendingRepo::None => Ok(()),
        PendingRepo::Create => repo_create(paths, target),
        PendingRepo::Private => repo_make_private(paths, target),
    }
}

// ─── Flush: stage allowlist → commit → update-ref → push ─────────────────────

fn target_guard(work: &WorkSession, target: &Target) -> Result<()> {
    let actual = origin(&work.store)?;
    if work.branch != target.branch || actual.as_deref() != Some(work.origin.as_str()) || work.origin != target.url() {
        return Err(fail("проверка цели рабочей сессии GitHub",
            "Запрошенный репозиторий или ветка не совпадает с неизменяемой целью текущей сессии."));
    }
    Ok(())
}

fn stage_allowlist(work: &WorkSession, storage: Storage) -> Result<()> {
    vault::validate_index(&work.worktree, storage.into())?;
    vault::validate_tree(&work.worktree, TreeMode::from(storage))?;
    let candidates: &[&str] = match storage {
        Storage::Age => &["storage.json", "recipient.txt", "unlock.age", "state.json.age"],
        Storage::Plain => &["storage.json", "config.json", "secrets.json", "manifest.json", "ssh", "templates"],
    };
    let tracked = work.tracked()?;
    let existing: Vec<&str> = candidates.iter().copied()
        .filter(|path| work.worktree.join(path).exists() || tracked.iter().any(|t| t == path || t.starts_with(&format!("{path}/"))))
        .collect();
    if existing.is_empty() {
        return Ok(());
    }
    let mut list = vec!["add", "-A", "--"];
    list.extend(existing);
    let out = exec::tree_git(&work.worktree, &args(&list))?;
    if !out.success {
        return Err(fail("подготовка файлов к отправке", "Не удалось подготовить разрешённые файлы конфигурации для commit."));
    }
    Ok(())
}

/// Stage and commit; pin the commit on the local branch before any network
/// I/O so a later process can recover it. `None`: nothing to publish. A
/// failure before the pin returns the session HEAD and index to where they
/// were, so an unpinned commit never reaches a later flush or push; the
/// worktree files stay for the caller to restore.
pub fn commit(work: &WorkSession, storage: Storage, pending: bool) -> Result<Option<String>> {
    let previous = work.head()?;
    commit_and_pin(work, storage, pending).map_err(|mut error| {
        let reset = exec::tree_git(&work.worktree, &args(&["reset", "-q", "--mixed", &previous]));
        if !reset.is_ok_and(|out| out.success) {
            error.message.push_str(" Рабочая копия GitHub не возвращена к прежнему commit.");
        }
        error
    })
}

fn commit_and_pin(work: &WorkSession, storage: Storage, pending: bool) -> Result<Option<String>> {
    let had_files = !work.tracked()?.is_empty();
    stage_allowlist(work, storage)?;
    let clean = exec::tree_git(&work.worktree, &args(&["diff", "--cached", "--quiet"]))?.success;
    if clean && !pending {
        return Ok(None);
    }
    if !clean {
        let message = if had_files { "remote-control: sync state" } else { "remote-control: initialize state" };
        let mut list = AUTHOR.to_vec();
        list.extend(["commit", "-q", "-m", message]);
        let out = exec::tree_git(&work.worktree, &args(&list))?;
        if !out.success {
            return Err(fail("сохранение локальных изменений Git", out.diagnostic()));
        }
    }
    let head = work.head()?;
    update_ref(&work.store, &format!("refs/heads/{}", work.branch), &head)
        .map_err(|_| fail("сохранение локальной точки восстановления", "Не удалось закрепить локальный commit конфигурации."))?;
    Ok(Some(head))
}

/// `push origin refs/heads/session/<id>:refs/heads/<branch>` after the account check.
pub fn push(paths: &StatePaths, target: &Target, work: &WorkSession, head: &str) -> Result<()> {
    account_login(paths, &target.owner)?;
    let refspec = format!("{}:refs/heads/{}", work.session_ref(), target.branch);
    let out = remote(paths, target, &work.store, &["push", "-q", "origin", &refspec])?;
    if !out.success {
        return Err(fail(PUSH_STAGE, out.diagnostic()));
    }
    let _ = update_ref(&work.store, &format!("refs/remotes/origin/{}", target.branch), head);
    Ok(())
}

/// A failed flush. `pinned`: the commit already sits on the local branch, so
/// the change survives as pending and must never be rolled back.
pub struct FlushFailure {
    pub error: RcError,
    pub pinned: bool,
}

/// v1 `github_sync_flush`. Any failure leaves `sync` pending; diverged remote
/// history is rejected by push, never merged.
pub fn flush(paths: &StatePaths, target: &Target, work: &WorkSession, storage: Storage, sync: &mut SyncStatus)
    -> std::result::Result<(), FlushFailure>
{
    let unpinned = |error: RcError| FlushFailure { error, pinned: false };
    let result = (|| {
        target_guard(work, target).map_err(unpinned)?;
        let Some(head) = commit(work, storage, *sync == SyncStatus::Pending).map_err(unpinned)? else {
            return Ok(());
        };
        // Every later failure (account check, gh/git not starting, push) is after the pin.
        push(paths, target, work, &head).map_err(|error| FlushFailure { error, pinned: true })
    })();
    *sync = if result.is_ok() { SyncStatus::Clean } else { SyncStatus::Pending };
    result
}

/// Test fixture under `dir`: a bare store on the initial empty state with
/// `target`'s origin and an open session worktree. GitHub is never reached:
/// a flush pins its commit, then the account check fails (pending).
#[cfg(test)]
pub(crate) fn test_work_session(dir: &Path, target: &Target) -> WorkSession {
    let store = dir.join("store.git");
    let mut init = exec::git();
    init.args(["init", "-q", "--bare"]).arg(&store);
    assert!(exec::run(init, None, exec::LOCAL_TIMEOUT).unwrap().success);
    store_ok(&store, "test", &["remote", "add", "origin", &target.url()]).unwrap();
    let tree = store_ok(&store, "test", &["mktree"]).unwrap().text();
    let mut list = AUTHOR.to_vec();
    list.extend(["commit-tree", &tree, "-m", "Initial empty state"]);
    let initial = store_ok(&store, "test", &list).unwrap().text();
    update_ref(&store, &format!("refs/heads/{}", target.branch), &initial).unwrap();
    open_worktree(&store, &dir.join("sessions"), &target.branch).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_failures_are_recognized_without_false_positives() {
        assert!(auth_failure_confirmed("HTTP 401: Bad credentials (https://api.github.com/user)"));
        assert!(auth_failure_confirmed("You are not logged into any GitHub hosts"));
        assert!(!auth_failure_confirmed("dial tcp: connection timed out after 4010ms"));
        assert!(!auth_failure_confirmed("error connecting to api.github.com"));
    }

    #[test]
    fn fetch_follows_rewritten_remote_history_without_touching_the_local_branch() {
        let dir = tempfile::tempdir().unwrap();
        let (origin, store) = (dir.path().join("origin.git"), dir.path().join("store.git"));
        for repo in [&origin, &store] {
            let mut init = exec::git();
            init.arg("init").arg("--bare").arg(repo);
            assert!(exec::run(init, None, exec::LOCAL_TIMEOUT).unwrap().success);
        }
        let commit = |message: &str, parent: Option<&str>| {
            let tree = store_ok(&origin, "test", &["mktree"]).unwrap().text();
            let mut list = AUTHOR.to_vec();
            list.extend(["--git-dir", origin.to_str().unwrap(), "commit-tree", &tree, "-m", message]);
            if let Some(parent) = parent {
                list.extend(["-p", parent]);
            }
            let mut command = exec::git();
            command.args(&list);
            let out = exec::run(command, None, exec::LOCAL_TIMEOUT).unwrap();
            assert!(out.success, "{}", out.diagnostic());
            out.text()
        };
        let fetch = || {
            let refspec = tracking_refspec("main");
            store_run(&store, &["fetch", "--no-tags", origin.to_str().unwrap(), &refspec]).unwrap()
        };
        let first = commit("first", None);
        let second = commit("second", Some(&first));
        update_ref(&origin, "refs/heads/main", &second).unwrap();
        assert!(fetch().success);
        update_ref(&store, "refs/heads/main", &second).unwrap();
        // Force-push of an unrelated history: a non-fast-forward for the tracking ref.
        let rewritten = commit("rewritten", None);
        update_ref(&origin, "refs/heads/main", &rewritten).unwrap();
        let out = fetch();
        assert!(out.success, "{}", out.diagnostic());
        assert_eq!(rev(&store, "refs/remotes/origin/main").unwrap().as_deref(), Some(rewritten.as_str()));
        assert_eq!(rev(&store, "refs/heads/main").unwrap().as_deref(), Some(second.as_str()));
        assert!(!is_ancestor(&store, &second, &rewritten).unwrap());
    }

    #[test]
    fn flush_reports_whether_its_commit_was_pinned() {
        let dir = tempfile::tempdir().unwrap();
        let paths = StatePaths::new(dir.path().join("data"));
        let target = Target::new("octo", "essence-remote-control-config", "main");
        let work = test_work_session(dir.path(), &target);
        let (store, local_ref) = (work.store.clone(), "refs/heads/main");
        let initial = rev(&store, local_ref).unwrap().unwrap();
        assert!(!holds_snapshot(&store, local_ref).unwrap(), "the initial empty state is not a snapshot");
        assert!(!holds_snapshot(&store, "refs/heads/none").unwrap());
        fs::write(work.worktree.join("config.json"), "{}\n").unwrap();

        // Refused before the commit: nothing is pinned.
        let mut sync = SyncStatus::Clean;
        let other = Target::new("other", "essence-remote-control-config", "main");
        let failure = flush(&paths, &other, &work, Storage::Plain, &mut sync).err().expect("foreign target");
        assert!(!failure.pinned && sync == SyncStatus::Pending);
        assert_eq!(rev(&store, local_ref).unwrap().as_deref(), Some(initial.as_str()));

        // The account check fails (gh absent or the empty profile is not
        // logged in), whatever its stage: the commit is already pinned.
        let failure = flush(&paths, &target, &work, Storage::Plain, &mut sync).err().expect("no GitHub account");
        assert!(failure.pinned, "{}", failure.error.message);
        let head = work.head().unwrap();
        assert_ne!(head, initial);
        assert_eq!(rev(&store, local_ref).unwrap(), Some(head));
        assert!(holds_snapshot(&store, local_ref).unwrap() && sync == SyncStatus::Pending);
    }

    #[test]
    fn a_failed_pin_rolls_the_session_commit_back() {
        let dir = tempfile::tempdir().unwrap();
        let paths = StatePaths::new(dir.path().join("data"));
        let target = Target::new("octo", "essence-remote-control-config", "main");
        let work = test_work_session(dir.path(), &target);
        let (local_ref, previous) = ("refs/heads/main", work.head().unwrap());
        fs::write(work.worktree.join("config.json"), "{\"rejected\":true}\n").unwrap();
        // A stale ref lock makes the pin fail right after the commit.
        let lock = work.store.join("refs/heads/main.lock");
        fs::write(&lock, "").unwrap();

        let mut sync = SyncStatus::Clean;
        let failure = flush(&paths, &target, &work, Storage::Plain, &mut sync).err().expect("the pin is blocked");
        assert!(!failure.pinned);
        assert_eq!(super::super::stage_of(&failure.error), Some("сохранение локальной точки восстановления"), "{}", failure.error.message);
        assert_eq!(work.head().unwrap(), previous, "the unpinned commit is dropped from the session branch");
        assert_eq!(rev(&work.store, local_ref).unwrap().as_deref(), Some(previous.as_str()));
        assert!(exec::tree_git(&work.worktree, &args(&["diff", "--cached", "--quiet"])).unwrap().success, "nothing stays staged");
        assert!(work.worktree.join("config.json").exists(), "the files are left for the caller to restore");

        // The caller restores the files; the next flush commits only that, on top of the old HEAD.
        fs::remove_file(&lock).unwrap();
        fs::write(work.worktree.join("config.json"), "{}\n").unwrap();
        assert!(flush(&paths, &target, &work, Storage::Plain, &mut sync).err().expect("no GitHub account").pinned);
        let head = work.head().unwrap();
        assert_eq!(rev(&work.store, local_ref).unwrap().as_deref(), Some(head.as_str()));
        assert_eq!(rev(&work.store, &format!("{head}^")).unwrap(), Some(previous));
    }
}
