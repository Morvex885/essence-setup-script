//! Single dispatch entry for the one-shot CLI and the serve transport.
//!
//! Both transports hand over the original argument vector, the request secrets
//! and one long-lived session. Parsing, secret whitelisting and consent happen
//! here; no handler asks questions or mutates before consent. Handlers report
//! progress through the session's journal sink, owned by the transport.

use serde::Serialize;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::{
    cli::{self, Invocation},
    confirmation::Plan,
    error::{RcError, Result},
    github::{self, commands::GithubSession, switch},
    locking::LockKind,
    log::{Level, LogSink},
    request_secrets::Secrets,
    self_manage,
    state::State,
    status,
    transport::Console,
};

/// Which transport owns this dispatch loop.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DispatchMode {
    /// One process per command: protected commands auto-open the local session.
    OneShot,
    /// Long-lived serve loop: only an explicit `session open` authorizes.
    Serve,
}

/// A reply envelope. `id` is assigned by the requesting transport.
#[derive(Debug, Serialize)]
pub struct Envelope {
    pub id: Value,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RcError>,
    /// Present only on success in GitHub mode: clean | pending | offline.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sync: Option<String>,
}

impl Envelope {
    pub fn success(data: Value) -> Self {
        Self { id: Value::Null, ok: true, data: Some(data), error: None, sync: None }
    }

    pub fn failure(error: RcError) -> Self {
        Self { id: Value::Null, ok: false, data: None, error: Some(error), sync: None }
    }

    pub fn exit_code(&self) -> u8 {
        self.error.as_ref().map_or(0, RcError::exit_code)
    }
}

/// Secrets that open a one-shot session for any protected command. In v1
/// they arrived through the transport rather than the command's own grammar.
const SESSION_SECRETS: [&str; 2] = ["script-password", "vault-password"];

/// One authenticated source session for a sequence of commands. For an open
/// GitHub source `state` points at `github-runtime/`; it always shares the
/// session's single lock manager.
pub struct Session {
    pub state: State,
    pub github: Option<GithubSession>,
    mode: DispatchMode,
    sink: Box<dyn LogSink>,
    pub open: bool,
    pub authorized: bool,
    pub remember_key: bool,
    /// The operator's terminal for TTY commands; never set by serve.
    console: Option<Box<dyn Console>>,
}

/// A mutation that reached the configuration: success or `partial`.
fn persists<T>(result: &Result<T>) -> bool {
    result.as_ref().map_or_else(|error| error.code == "partial", |_| true)
}

impl Session {
    pub fn new(state: State, mode: DispatchMode, sink: Box<dyn LogSink>) -> Self {
        Self { state, github: None, mode, sink, open: false, authorized: false, remember_key: false, console: None }
    }

    /// Attach the operator's terminal: the one-shot CLI for `!tty` commands,
    /// and the TUI's private `serve --inner` child (it shares the TUI's
    /// controlling terminal while the menu is suspended). A public serve
    /// never attaches one, so its `!tty` commands answer `tty_required`.
    pub fn set_console(&mut self, console: Box<dyn Console>) {
        self.console = Some(console);
    }

    /// The attached terminal, if the transport attached one.
    pub(crate) fn console(&mut self) -> Option<&mut (dyn Console + 'static)> {
        self.console.as_deref_mut()
    }

    pub fn mode(&self) -> DispatchMode {
        self.mode
    }

    pub(crate) fn log(&mut self, level: Level, text: &str) {
        self.sink.log(level, text);
    }

    /// Sync status of an open GitHub source (envelope `sync`).
    pub fn sync(&self) -> Option<&'static str> {
        self.github.as_ref().filter(|_| self.open).map(|github| github.sync.as_str())
    }

    /// Send pending GitHub work, close the worktree and release every lock.
    pub fn close(&mut self) -> Result<()> {
        github::commands::close_github(self);
        self.state.locks().release_all()?;
        self.open = false;
        self.authorized = false;
        Ok(())
    }

    /// v1: configured means a device-local `config.json` or `source.json`.
    pub(crate) fn configured(&self) -> Result<bool> {
        let paths = self.state.paths().local();
        Ok(paths.config().try_exists()? || paths.source().try_exists()?)
    }

    fn source_kind(&self) -> Result<Option<&'static str>> {
        if !self.configured()? {
            return Ok(None);
        }
        // source.json exists only for GitHub sources; absence means local.
        Ok(Some(if self.state.paths().source().try_exists()? { "github" } else { "local" }))
    }

    /// `{source, repo, sync}` of the open session.
    fn data(&self) -> Value {
        match &self.github {
            Some(github) => json!({"source": "github", "repo": github.target.repo(), "sync": github.sync.as_str()}),
            None => json!({"source": "local", "repo": null, "sync": null}),
        }
    }

    /// Open the source and verify the script password. One-shot auto-open
    /// treats absent state as an open local session so read-only commands on a
    /// fresh installation keep working; an explicit `session open` does not.
    /// The script password hash of a GitHub source arrives with its snapshot,
    /// so the source opens first.
    pub(crate) fn open_source(&mut self, secrets: &Secrets, explicit: bool) -> Result<Value> {
        let configured = self.configured()?;
        if !configured && explicit {
            return Err(RcError::new(
                "not_configured",
                "Конфигурация не создана: source init-local или source github-connect.",
            ));
        }
        if !self.open {
            if configured && self.state.paths().source().try_exists()? {
                github::commands::open_github(self, secrets, self.remember_key)?;
            }
            self.open = true;
        }
        if !self.authorized {
            if self.state.auth_store().is_configured()? {
                let password = secrets.get("script-password").ok_or_else(|| {
                    RcError::new("auth_required", "Требуется пароль запуска.")
                        .with_extra("secret", "script-password")
                })?;
                if !self.state.auth_store().verify(password)? {
                    return Err(RcError::new("auth_failed", "Неверный пароль запуска.")
                        .with_extra("secret", "script-password"));
                }
            }
            self.authorized = true;
        }
        Ok(self.data())
    }

    fn ensure_authorized(&mut self, secrets: &Secrets) -> Result<()> {
        if self.open && self.authorized {
            return Ok(());
        }
        match self.mode {
            DispatchMode::OneShot => self.open_source(secrets, false).map(drop),
            DispatchMode::Serve => {
                Err(RcError::new("session_closed", "Сначала откройте сессию: session open."))
            }
        }
    }

    /// The single mutation path (v1 `state_action`): mutation lock → change →
    /// checkpoint. For GitHub the runtime is serialized into the worktree and
    /// flushed; a failure before the commit is pinned restores the runtime
    /// (and `auth.txt`) and the worktree, a failed push after it keeps the
    /// result and leaves `pending`.
    pub fn mutate<T>(&mut self, label: &str, apply: impl FnOnce(&State) -> Result<T>) -> Result<T> {
        let locks = self.state.locks().clone();
        let _guard = locks.acquire(LockKind::Mutation, label)?;
        let Some(github) = self.github.as_mut() else {
            let result = apply(&self.state);
            if persists(&result) {
                if let Err(error) = self.state.checkpoint() {
                    self.sink.log(Level::Warn, "Не удалось сохранить локальную точку восстановления. Проверьте результат операции перед повтором.");
                    return Err(error);
                }
            }
            return result;
        };
        let backup = github::vault::DirSnapshot::take(self.state.paths().state_dir(), &[self.state.paths().auth()])?;
        let result = apply(&self.state);
        if !persists(&result) {
            return result;
        }
        let published = (|| {
            self.state.checkpoint()?;
            let snapshot = github::vault::serialize(&self.state)?;
            github.checkpoint(&snapshot)
        })();
        if let Err(error) = published {
            let _ = backup.restore();
            return Err(github::prefixed(error, "Не удалось сохранить изменение в GitHub", "source_failed"));
        }
        let sync_before = github.sync;
        match github.try_flush(self.state.paths()) {
            Ok(()) => {}
            Err(failure) if failure.pinned => {
                self.sink.log(Level::Warn, &format!("Не удалось отправить изменение в GitHub: {}", failure.error.message));
                self.sink.log(Level::Warn, "Изменения сохранены локально и ожидают отправки.");
            }
            Err(failure) => {
                // Nothing was committed: the change is not saved anywhere, so
                // the runtime, the worktree and the sync status return to
                // their state before it.
                let restored = backup.restore().and_then(|()| github::vault::serialize(&self.state))
                    .and_then(|snapshot| github.checkpoint(&snapshot));
                github.sync = sync_before;
                if restored.is_err() {
                    self.sink.log(Level::Warn, "Не удалось вернуть конфигурацию и рабочую копию GitHub к прежнему состоянию: проверьте конфигурацию перед следующим изменением.");
                }
                return Err(github::prefixed(failure.error, "Не удалось сохранить изменение в GitHub", "source_failed"));
            }
        }
        result
    }
}

/// Execute one command. Exactly one envelope is returned for every call.
pub async fn dispatch(argv: &[String], secrets: &Secrets, session: &mut Session) -> Envelope {
    match dispatch_inner(argv, secrets, session).await {
        Ok(data) => {
            let mut envelope = Envelope::success(data);
            envelope.sync = session.sync().map(str::to_owned);
            envelope
        }
        Err(error) => Envelope::failure(error),
    }
}

async fn dispatch_inner(argv: &[String], secrets: &Secrets, session: &mut Session) -> Result<Value> {
    let invocation = cli::parse(argv)?;
    if invocation.secrets_stdin && session.mode == DispatchMode::Serve {
        return Err(RcError::new("usage", "В serve секреты передаются полем secrets."));
    }
    let mut accepted = invocation.allowed_secrets().to_vec();
    // github-connect opens an existing local session itself (v1 auto-open).
    let opens_session = invocation.requires_session() || (invocation.noun == "source" && invocation.verb == "github-connect");
    if session.mode == DispatchMode::OneShot && opens_session {
        for name in SESSION_SECRETS {
            if !accepted.contains(&name) {
                accepted.push(name);
            }
        }
    }
    secrets.validate_allowed(&accepted)?;
    if invocation.help {
        return Ok(cli::help(invocation.help_noun()));
    }
    if invocation.requires_session() {
        session.ensure_authorized(secrets)?;
    }
    route(&invocation, secrets, session).await
}

async fn route(invocation: &Invocation, secrets: &Secrets, session: &mut Session) -> Result<Value> {
    match (invocation.noun.as_str(), invocation.verb.as_str()) {
        ("status", "") => {
            let status = status::status(&session.state, session.sync())?;
            serde_json::to_value(status).map_err(|_| RcError::new("failed", "Не удалось сериализовать сводку."))
        }
        ("session", "status") => Ok(json!({
            "configured": session.configured()?,
            "source": session.source_kind()?,
            "open": session.open,
            "authorized": session.authorized,
        })),
        ("session", "open") => {
            session.remember_key = invocation.has("remember-key");
            let data = session.open_source(secrets, true)?;
            let text = if session.github.is_some() { "Сессия открыта: конфигурация GitHub." } else { "Сессия открыта: локальная конфигурация." };
            session.log(Level::Info, text);
            Ok(data)
        }
        ("source", verb) => route_source(verb, invocation, secrets, session).await,
        ("self", "version") => self_manage::version().await,
        ("self", "update") => {
            let plan = self_manage::prepare_update().await?;
            plan.plan.confirm(invocation)?;
            session.log(Level::Info, "Загрузка и проверка релиза…");
            let data = plan.apply().await?;
            session.log(Level::Success, "essence-rc обновлён.");
            session.log(Level::Warn, "Для загрузки новых функций запустите essence-rc заново.");
            Ok(data)
        }
        ("self", "uninstall") => {
            let plan = self_manage::prepare_uninstall(&session.state, invocation.has("remove-data"))?;
            plan.plan.confirm(invocation)?;
            let data = plan.apply()?;
            session.log(Level::Success, "essence-rc удалён.");
            if data["reboot_required"] == true {
                session.log(Level::Warn, "Исполняемый файл будет удалён после перезагрузки.");
            }
            Ok(data)
        }
        ("self", "password-set") => {
            check_current_password(session, secrets)?;
            // Absent: the front end prompts and repeats; explicitly empty: invalid.
            let password = secrets.get("password").ok_or_else(|| {
                RcError::new("missing_secret", "Не передан секрет password (--secrets-stdin или поле secrets).")
                    .with_extra("secret", "password")
            })?;
            if password.is_empty() {
                return Err(RcError::new("invalid", "Пароль не может быть пустым."));
            }
            if password.contains('\n') {
                return Err(RcError::new("invalid", "Пароль не может содержать перевод строки."));
            }
            let password = Zeroizing::new(password.to_owned());
            session.mutate("password-set", |state| state.auth_store().set(password))?;
            session.log(Level::Success, "Пароль сохранён");
            Ok(json!({"password_set": true}))
        }
        ("self", "password-remove") => {
            check_current_password(session, secrets)?;
            let plan = Plan::new(
                vec![
                    "Пароль запуска remote-control будет удалён.".into(),
                    "Локальные данные и SSH-ключи сохранятся.".into(),
                ],
                "",
            );
            plan.confirm(invocation)?;
            session.mutate("password-remove", |state| state.auth_store().remove())?;
            session.log(Level::Success, "Пароль убран");
            Ok(json!({"password_set": false}))
        }
        (noun @ ("node" | "conn"), verb) => {
            let mut transport = crate::ssh::SshTransport::default();
            crate::nodes::route(noun, verb, invocation, secrets, session, &mut transport).await
        }
        (noun @ ("group" | "template" | "client" | "generate"), verb) => {
            crate::clients::route(noun, verb, invocation, secrets, session, &crate::ssh::SshTransport::default).await
        }
        ("subscription", verb) => {
            crate::subscription::route("subscription", verb, invocation, secrets, session, &crate::ssh::SshTransport::default).await
        }
        ("awg", verb) => crate::awg::route("awg", verb, invocation, secrets, session, &crate::ssh::SshTransport::default).await,
        ("telegram", verb) => {
            crate::telegram::route("telegram", verb, invocation, secrets, session, &crate::ssh::SshTransport::default).await
        }
        // The parser only yields catalog commands; every one is routed above.
        _ => Err(RcError::new("usage", "Неизвестная команда.")),
    }
}

async fn route_source(verb: &str, invocation: &Invocation, secrets: &Secrets, session: &mut Session) -> Result<Value> {
    use github::commands as source;
    match verb {
        "init-local" => source::init_local(session),
        "status" => source::status(session),
        "github-accounts" => Ok(source::accounts(session)),
        "github-login" => source::login(session, invocation),
        "github-connect" => source::connect(session, invocation, secrets, &mut crate::ssh::SshTransport::default()).await,
        "github-fetch" => source::fetch(session),
        "github-push" => source::push(session),
        "github-change-account" => switch::change_account(session, invocation, secrets),
        "github-rewrap-password" => source::rewrap_password(session, secrets),
        "github-rotate-key" => source::rotate_key(session, invocation, secrets),
        "github-import-recovery-key" => source::import_recovery_key(session, invocation),
        "github-switch-local" => source::switch_local(session),
        "github-replace-with-local" => source::replace_with_local(session, invocation, secrets, &mut crate::ssh::SshTransport::default()).await,
        "github-migrate-format" => source::migrate_format(session, invocation, secrets),
        "github-delete-repo" => source::delete_repo(session, invocation),
        _ => Err(RcError::new("usage", "Неизвестная команда source.")),
    }
}

/// The current script password is required whenever one is configured, even
/// for an already authorized session.
fn check_current_password(session: &Session, secrets: &Secrets) -> Result<()> {
    if !session.state.auth_store().is_configured()? {
        return Ok(());
    }
    let current = secrets.get("current-password").ok_or_else(|| {
        RcError::new("auth_required", "Требуется текущий пароль запуска.").with_extra("secret", "current-password")
    })?;
    if !session.state.auth_store().verify(current)? {
        return Err(RcError::new("auth_failed", "Неверный текущий пароль запуска.")
            .with_extra("secret", "current-password"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{cell::RefCell, rc::Rc};

    use super::*;
    use crate::state::StatePaths;

    type Journal = Rc<RefCell<Vec<(Level, String)>>>;

    struct Recorder(Journal);

    impl LogSink for Recorder {
        fn log(&mut self, level: Level, text: &str) {
            self.0.borrow_mut().push((level, text.to_owned()));
        }
    }

    fn session(root: &std::path::Path, mode: DispatchMode) -> (Session, Journal) {
        let journal = Journal::default();
        let session = Session::new(State::new(StatePaths::new(root)), mode, Box::new(Recorder(journal.clone())));
        (session, journal)
    }

    fn argv(list: &[&str]) -> Vec<String> {
        list.iter().map(|arg| arg.to_string()).collect()
    }

    fn secrets(text: &str) -> Secrets {
        Secrets::from_json(text).unwrap()
    }

    async fn run(session: &mut Session, list: &[&str], text: &str) -> Envelope {
        dispatch(&argv(list), &secrets(text), session).await
    }

    #[tokio::test(flavor = "current_thread")]
    async fn password_lifecycle_journals_and_gates_before_mutation() {
        let root = tempfile::tempdir().unwrap();
        let (mut one_shot, journal) = session(root.path(), DispatchMode::OneShot);
        let init = run(&mut one_shot, &["source", "init-local"], "{}").await;
        assert!(init.ok, "{:?}", init.error.map(|e| e.message));
        assert!(root.path().join("config.json").exists() && root.path().join("manifest.json").exists());
        let absent = run(&mut one_shot, &["self", "password-set"], "{}").await.error.unwrap();
        assert_eq!((absent.code, absent.extra["secret"].clone()), ("missing_secret", json!("password")), "the front end prompts");
        let empty = run(&mut one_shot, &["self", "password-set"], r#"{"password":""}"#).await.error.unwrap();
        assert_eq!(empty.code, "invalid");
        let set = run(&mut one_shot, &["self", "password-set"], r#"{"password":"first"}"#).await;
        assert!(set.ok);
        assert_eq!(journal.borrow().last().unwrap(), &(Level::Success, "Пароль сохранён".to_owned()));
        let manifest: Value = serde_json::from_slice(&std::fs::read(root.path().join("manifest.json")).unwrap()).unwrap();
        assert!(manifest["access"]["script_password_hash"].as_str().unwrap().starts_with("$argon2id$"), "checkpoint mirrors the hash");
        let again = run(&mut one_shot, &["source", "init-local"], "{}").await;
        assert_eq!(again.error.unwrap().code, "conflict");
        let auth = std::fs::read(root.path().join("auth.txt")).unwrap();

        let (mut serve, journal) = session(root.path(), DispatchMode::Serve);
        let closed = run(&mut serve, &["self", "password-remove"], r#"{"current-password":"first"}"#).await;
        assert_eq!(closed.error.unwrap().code, "session_closed");
        let wrong = run(&mut serve, &["session", "open"], r#"{"script-password":"bad"}"#).await;
        assert_eq!(wrong.error.unwrap().code, "auth_failed");
        assert!(run(&mut serve, &["session", "open"], r#"{"script-password":"first"}"#).await.ok);
        // Serve accepts only the command's own secrets.
        let foreign = run(&mut serve, &["status"], r#"{"script-password":"first"}"#).await;
        assert_eq!(foreign.error.unwrap().code, "usage");
        let gated = run(&mut serve, &["self", "password-remove"], r#"{"current-password":"first"}"#).await;
        let error = gated.error.unwrap();
        assert_eq!(error.code, "confirmation_required");
        assert_eq!(std::fs::read(root.path().join("auth.txt")).unwrap(), auth);
        let token = error.extra["plan_token"].as_str().unwrap().to_owned();
        let removed = run(&mut serve, &["self", "password-remove", "--yes", "--plan-token", &token],
            r#"{"current-password":"first"}"#).await;
        assert!(removed.ok);
        assert!(!root.path().join("auth.txt").exists());
        assert_eq!(journal.borrow().last().unwrap(), &(Level::Success, "Пароль убран".to_owned()));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn session_status_reports_state_without_creating_data() {
        let root = tempfile::tempdir().unwrap();
        let (mut one_shot, _) = session(&root.path().join("absent"), DispatchMode::OneShot);
        let status = run(&mut one_shot, &["session", "status"], "{}").await;
        assert_eq!(status.data.unwrap(), json!({"configured": false, "source": null, "open": false, "authorized": false}));
        // A protected one-shot command auto-opens the absent local state.
        assert!(run(&mut one_shot, &["group", "list"], "{}").await.ok);
        let status = run(&mut one_shot, &["session", "status"], "{}").await;
        assert_eq!(status.data.unwrap(), json!({"configured": false, "source": null, "open": true, "authorized": true}));
        let open = run(&mut one_shot, &["session", "open"], "{}").await;
        assert_eq!(open.error.unwrap().code, "not_configured");
        assert!(!root.path().join("absent").exists());
    }

    #[test]
    fn a_flush_failing_before_the_pin_saves_nothing() {
        use crate::github::{BRANCH, REPO_NAME, Storage, SyncStatus, Target, commands::GithubSession, stage_of, store};
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("data");
        let (mut session, journal) = session(&root, DispatchMode::OneShot);
        let paths = StatePaths::new(&root);
        session.state = State::with_locks(paths.runtime(), session.state.locks().clone());
        crate::secure_fs::create_dir_all(&paths.github_runtime()).unwrap();
        session.state.save_config(&crate::model::Config::default()).unwrap();
        let work = store::test_work_session(&dir.path().join("work"), &Target::new("alice", REPO_NAME, BRANCH));
        let (git_store, worktree) = (work.store.clone(), work.worktree.clone());
        let initial = store::rev(&git_store, "refs/heads/main").unwrap();
        // The session target no longer matches its worktree: flush stops before the commit.
        session.github = Some(GithubSession { target: Target::new("mallory", REPO_NAME, BRANCH), work: Some(work),
            storage: Storage::Plain, keys: None, sync: SyncStatus::Clean, last_counts: Value::Null, last_version: None });
        let before = crate::nodes::testing::fingerprint(&paths.github_runtime());

        let error = session.mutate("probe", |state| {
            let mut config = state.load_config()?;
            config.groups.push(crate::model::Group { name: "PROBE".into(), ..Default::default() });
            state.save_config(&config)
        }).unwrap_err();
        assert_eq!((error.code, stage_of(&error)), ("source_failed", Some("проверка цели рабочей сессии GitHub")), "{}", error.message);
        assert!(error.message.starts_with("Не удалось сохранить изменение в GitHub"), "{}", error.message);
        assert_eq!(crate::nodes::testing::fingerprint(&paths.github_runtime()), before, "the runtime is restored");
        assert!(!std::fs::read_to_string(worktree.join("config.json")).unwrap().contains("PROBE"), "the worktree is re-checkpointed");
        assert_eq!(store::rev(&git_store, "refs/heads/main").unwrap(), initial, "nothing is pinned");
        assert_eq!(session.github.as_ref().unwrap().sync, SyncStatus::Clean, "nothing waits for push");
        assert!(journal.borrow().iter().all(|(level, _)| *level != Level::Warn), "no false «saved locally» warning");
    }

    #[test]
    fn a_failed_pin_keeps_the_rejected_change_out_of_history() {
        use crate::github::{BRANCH, REPO_NAME, Storage, SyncStatus, Target, commands::GithubSession, exec, stage_of, store};
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("data");
        let (mut session, _journal) = session(&root, DispatchMode::OneShot);
        let paths = StatePaths::new(&root);
        session.state = State::with_locks(paths.runtime(), session.state.locks().clone());
        crate::secure_fs::create_dir_all(&paths.github_runtime()).unwrap();
        session.state.save_config(&crate::model::Config::default()).unwrap();
        let target = Target::new("alice", REPO_NAME, BRANCH);
        let work = store::test_work_session(&dir.path().join("work"), &target);
        let (git_store, previous) = (work.store.clone(), work.head().unwrap());
        session.github = Some(GithubSession { target, work: Some(work),
            storage: Storage::Plain, keys: None, sync: SyncStatus::Clean, last_counts: Value::Null, last_version: None });
        let add_group = |name: &'static str| move |state: &State| {
            let mut config = state.load_config()?;
            config.groups.push(crate::model::Group { name: name.into(), ..Default::default() });
            state.save_config(&config)
        };

        // A stale ref lock makes the pin fail right after the commit.
        let lock = git_store.join("refs/heads/main.lock");
        std::fs::write(&lock, "").unwrap();
        let error = session.mutate("probe", add_group("PROBE")).unwrap_err();
        assert_eq!((error.code, stage_of(&error)), ("source_failed", Some("сохранение локальной точки восстановления")), "{}", error.message);
        std::fs::remove_file(&lock).unwrap();

        // The next change is committed once, on top of the old HEAD, without the rejected one.
        session.mutate("next", add_group("NEXT")).unwrap();
        let log = exec::store_git(&git_store, &["log".as_ref(), "-p".as_ref(), "--format=%H %P".as_ref(), "refs/heads/main".as_ref()]).unwrap();
        let log = String::from_utf8_lossy(&log.stdout).into_owned();
        assert!(log.contains("NEXT") && !log.contains("PROBE"), "{log}");
        let head = store::rev(&git_store, "refs/heads/main").unwrap().unwrap();
        assert_eq!(store::rev(&git_store, &format!("{head}^")).unwrap(), Some(previous));
        assert_eq!(session.github.as_ref().unwrap().sync, SyncStatus::Pending, "pinned, the push is pending");
    }
}
