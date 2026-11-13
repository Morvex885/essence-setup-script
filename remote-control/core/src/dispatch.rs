//! Single dispatch entry of the daemon's core thread.
//!
//! Every request hands over the original argument vector, the request secrets
//! and input, and the daemon's one long-lived session. Parsing, secret and
//! input whitelisting and consent happen here; no handler asks questions or
//! mutates before consent. Handlers report progress through the session's
//! journal sink, owned by the daemon. Terminal commands are prepared here
//! (`prepare_terminal`) and run by the caller on the requester's console.

use std::path::Path;

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
    request_input::Input,
    request_secrets::Secrets,
    self_manage,
    ssh::SshTransport,
    state::State,
    status,
    terminal::{TerminalJob, tty_required},
};

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

/// A protected command before `session open` authorized the session.
pub(crate) fn session_closed() -> RcError {
    RcError::new("session_closed", "Сначала откройте сессию: session open.")
}

/// One authenticated source session for a sequence of commands. For an open
/// GitHub source `state` points at `github-runtime/`; it always shares the
/// session's single lock manager.
pub struct Session {
    pub state: State,
    pub github: Option<GithubSession>,
    sink: Box<dyn LogSink>,
    pub open: bool,
    pub authorized: bool,
    pub remember_key: bool,
}

/// A mutation that reached the configuration: success or `partial`.
fn persists<T>(result: &Result<T>) -> bool {
    result.as_ref().map_or_else(|error| error.code == "partial", |_| true)
}

impl Session {
    pub fn new(state: State, sink: Box<dyn LogSink>) -> Self {
        Self { state, github: None, sink, open: false, authorized: false, remember_key: false }
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
    pub fn configured(&self) -> Result<bool> {
        let paths = self.state.paths().local();
        Ok(paths.config().try_exists()? || paths.source().try_exists()?)
    }

    /// `local`, `github`, or `None` before the configuration exists.
    pub fn source_kind(&self) -> Result<Option<&'static str>> {
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

    /// `session open`: open the source and verify the script password. The
    /// script password hash of a GitHub source arrives with its snapshot, so
    /// the source opens first. Absent state is `not_configured`.
    pub fn open_source(&mut self, secrets: &Secrets) -> Result<Value> {
        if !self.configured()? {
            return Err(RcError::new(
                "not_configured",
                "Конфигурация не создана: source init-local или source github-connect.",
            ));
        }
        if !self.open {
            if self.state.paths().source().try_exists()? {
                github::commands::open_github(self, secrets, self.remember_key)?;
            }
            self.open = true;
        }
        if !self.authorized {
            self.verify_script_password(secrets)?;
            self.authorized = true;
        }
        Ok(self.data())
    }

    /// Absent state opens as an empty local session so read-only commands
    /// and the first-run commands work on a fresh installation. Creates
    /// nothing on disk; `false` (and no change) once the configuration exists.
    pub fn open_absent(&mut self) -> Result<bool> {
        if self.configured()? {
            return Ok(false);
        }
        self.open = true;
        self.authorized = true;
        Ok(true)
    }

    /// The `script-password` secret against the stored script password; no
    /// password configured passes.
    pub fn verify_script_password(&self, secrets: &Secrets) -> Result<()> {
        let auth = self.state.auth_store();
        if !auth.is_configured()? {
            return Ok(());
        }
        let password = secrets.get("script-password").ok_or_else(|| {
            RcError::new("auth_required", "Требуется пароль запуска.").with_extra("secret", "script-password")
        })?;
        if !auth.verify(password)? {
            return Err(RcError::new("auth_failed", "Неверный пароль запуска.").with_extra("secret", "script-password"));
        }
        Ok(())
    }

    fn ensure_authorized(&self) -> Result<()> {
        if self.open && self.authorized { Ok(()) } else { Err(session_closed()) }
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
/// `agent_socket` is the requesting client's SSH agent (`None` → no agent).
pub async fn dispatch(argv: &[String], secrets: &Secrets, input: &Input, agent_socket: Option<&Path>,
    session: &mut Session) -> Envelope
{
    match dispatch_inner(argv, secrets, input, agent_socket, session).await {
        Ok(data) => {
            let mut envelope = Envelope::success(data);
            envelope.sync = session.sync().map(str::to_owned);
            envelope
        }
        Err(error) => Envelope::failure(error),
    }
}

/// Parse and whitelist: the command's own secrets and inputs only. The daemon
/// applies it to every request before routing.
pub fn checked(argv: &[String], secrets: &Secrets, input: &Input) -> Result<Invocation> {
    let invocation = cli::parse(argv)?;
    if invocation.secrets_stdin {
        return Err(RcError::new("usage", "Секреты передаются полем secrets."));
    }
    secrets.validate_allowed(invocation.allowed_secrets())?;
    input.validate_allowed(invocation.inputs())?;
    Ok(invocation)
}

async fn dispatch_inner(argv: &[String], secrets: &Secrets, input: &Input, agent_socket: Option<&Path>,
    session: &mut Session) -> Result<Value>
{
    let invocation = checked(argv, secrets, input)?;
    if invocation.help {
        return Ok(cli::help(invocation.help_noun()));
    }
    if invocation.client_side() {
        return Err(RcError::new("usage", "Команда выполняется на стороне клиента."));
    }
    if invocation.requires_tty() {
        return Err(tty_required(&invocation.noun));
    }
    if invocation.requires_session() {
        session.ensure_authorized()?;
    }
    route(&invocation, secrets, input, agent_socket, session).await
}

/// The session part of a terminal command (`node shell`, `telegram menu`):
/// the same checks as `dispatch`, then lookup, connection and script checks.
/// The caller runs the returned job on the requester's console.
pub async fn prepare_terminal(argv: &[String], secrets: &Secrets, input: &Input, agent_socket: Option<&Path>,
    session: &mut Session) -> Result<TerminalJob<SshTransport>>
{
    let invocation = checked(argv, secrets, input)?;
    if invocation.requires_session() {
        session.ensure_authorized()?;
    }
    let connect = || SshTransport::with_agent(agent_socket);
    match (invocation.noun.as_str(), invocation.verb.as_str()) {
        ("node", "shell") => crate::nodes::shell::prepare(session, &invocation, connect()).await,
        ("telegram", "menu") => crate::telegram::menu_prepare(session, &invocation, &connect).await,
        _ => Err(RcError::new("usage", "Неизвестная команда.")),
    }
}

async fn route(invocation: &Invocation, secrets: &Secrets, input: &Input, agent_socket: Option<&Path>,
    session: &mut Session) -> Result<Value>
{
    let connect = || SshTransport::with_agent(agent_socket);
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
            let data = session.open_source(secrets)?;
            let text = if session.github.is_some() { "Сессия открыта: конфигурация GitHub." } else { "Сессия открыта: локальная конфигурация." };
            session.log(Level::Info, text);
            Ok(data)
        }
        ("source", verb) => route_source(verb, invocation, secrets, input, &connect, session).await,
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
        (noun @ ("node" | "conn"), verb) => crate::nodes::route(noun, verb, invocation, secrets, session, &mut connect()).await,
        (noun @ ("group" | "template" | "client" | "generate"), verb) => {
            crate::clients::route(noun, verb, invocation, secrets, input, session, &connect).await
        }
        ("subscription", verb) => crate::subscription::route("subscription", verb, invocation, secrets, session, &connect).await,
        ("awg", verb) => crate::awg::route("awg", verb, invocation, secrets, session, &connect).await,
        ("telegram", verb) => crate::telegram::route("telegram", verb, invocation, secrets, session, &connect).await,
        // The parser only yields catalog commands; every session command is
        // routed above. `daemon *` belongs to the daemon.
        _ => Err(RcError::new("usage", "Неизвестная команда.")),
    }
}

async fn route_source(verb: &str, invocation: &Invocation, secrets: &Secrets, input: &Input,
    connect: &dyn Fn() -> SshTransport, session: &mut Session) -> Result<Value>
{
    use github::commands as source;
    match verb {
        "init-local" => source::init_local(session),
        "status" => source::status(session),
        "github-accounts" => Ok(source::accounts(session)),
        "github-login" => source::login(session, invocation),
        "github-connect" => source::connect(session, invocation, secrets, &mut connect()).await,
        "github-fetch" => source::fetch(session),
        "github-push" => source::push(session),
        "github-change-account" => switch::change_account(session, invocation, secrets),
        "github-rewrap-password" => source::rewrap_password(session, secrets),
        "github-rotate-key" => source::rotate_key(session, invocation, secrets),
        "github-import-recovery-key" => source::import_recovery_key(session, input),
        "github-switch-local" => source::switch_local(session),
        "github-replace-with-local" => source::replace_with_local(session, invocation, secrets, &mut connect()).await,
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

    fn session(root: &std::path::Path) -> (Session, Journal) {
        let journal = Journal::default();
        let session = Session::new(State::new(StatePaths::new(root)), Box::new(Recorder(journal.clone())));
        (session, journal)
    }

    fn argv(list: &[&str]) -> Vec<String> {
        list.iter().map(|arg| arg.to_string()).collect()
    }

    fn secrets(text: &str) -> Secrets {
        Secrets::from_json(text).unwrap()
    }

    async fn run(session: &mut Session, list: &[&str], text: &str) -> Envelope {
        dispatch(&argv(list), &secrets(text), &Input::default(), None, session).await
    }

    async fn run_input(session: &mut Session, list: &[&str], input: &str) -> Envelope {
        dispatch(&argv(list), &Secrets::default(), &Input::from_json(input).unwrap(), None, session).await
    }

    fn code(envelope: Envelope) -> &'static str {
        envelope.error.map_or("ok", |error| error.code)
    }

    /// A local configuration with the script password `first`, closed.
    async fn configured(root: &std::path::Path) -> Session {
        let (mut session, _) = session(root);
        assert!(session.open_absent().unwrap());
        assert!(run(&mut session, &["source", "init-local"], "{}").await.ok);
        assert!(run(&mut session, &["self", "password-set"], r#"{"password":"first"}"#).await.ok);
        session.close().unwrap();
        session
    }

    #[tokio::test(flavor = "current_thread")]
    async fn password_lifecycle_journals_and_gates_before_mutation() {
        let root = tempfile::tempdir().unwrap();
        let (mut first, journal) = session(root.path());
        assert!(first.open_absent().unwrap());
        let init = run(&mut first, &["source", "init-local"], "{}").await;
        assert!(init.ok, "{:?}", init.error.map(|e| e.message));
        assert!(root.path().join("config.json").exists() && root.path().join("manifest.json").exists());
        let absent = run(&mut first, &["self", "password-set"], "{}").await.error.unwrap();
        assert_eq!((absent.code, absent.extra["secret"].clone()), ("missing_secret", json!("password")), "the front end prompts");
        let empty = run(&mut first, &["self", "password-set"], r#"{"password":""}"#).await.error.unwrap();
        assert_eq!(empty.code, "invalid");
        let set = run(&mut first, &["self", "password-set"], r#"{"password":"first"}"#).await;
        assert!(set.ok);
        assert_eq!(journal.borrow().last().unwrap(), &(Level::Success, "Пароль сохранён".to_owned()));
        let manifest: Value = serde_json::from_slice(&std::fs::read(root.path().join("manifest.json")).unwrap()).unwrap();
        assert!(manifest["access"]["script_password_hash"].as_str().unwrap().starts_with("$argon2id$"), "checkpoint mirrors the hash");
        let again = run(&mut first, &["source", "init-local"], "{}").await;
        assert_eq!(again.error.unwrap().code, "conflict");
        let auth = std::fs::read(root.path().join("auth.txt")).unwrap();

        let (mut second, journal) = session(root.path());
        let closed = run(&mut second, &["self", "password-remove"], r#"{"current-password":"first"}"#).await;
        assert_eq!(code(closed), "session_closed");
        let wrong = run(&mut second, &["session", "open"], r#"{"script-password":"bad"}"#).await;
        assert_eq!(code(wrong), "auth_failed");
        assert!(run(&mut second, &["session", "open"], r#"{"script-password":"first"}"#).await.ok);
        // Only the command's own secrets are accepted.
        let foreign = run(&mut second, &["status"], r#"{"script-password":"first"}"#).await;
        assert_eq!(code(foreign), "usage");
        let gated = run(&mut second, &["self", "password-remove"], r#"{"current-password":"first"}"#).await;
        let error = gated.error.unwrap();
        assert_eq!(error.code, "confirmation_required");
        assert_eq!(std::fs::read(root.path().join("auth.txt")).unwrap(), auth);
        let token = error.extra["plan_token"].as_str().unwrap().to_owned();
        let removed = run(&mut second, &["self", "password-remove", "--yes", "--plan-token", &token],
            r#"{"current-password":"first"}"#).await;
        assert!(removed.ok);
        assert!(!root.path().join("auth.txt").exists());
        assert_eq!(journal.borrow().last().unwrap(), &(Level::Success, "Пароль убран".to_owned()));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn protected_commands_need_an_open_session_and_absent_state_opens_without_writing() {
        let root = tempfile::tempdir().unwrap();
        let data = root.path().join("absent");
        let (mut session, journal) = session(&data);
        let status = run(&mut session, &["session", "status"], "{}").await;
        assert_eq!(status.data.unwrap(), json!({"configured": false, "source": null, "open": false, "authorized": false}));
        for list in [&["group", "list"][..], &["status"], &["client", "config", "--name", "c"], &["template", "list"],
            &["template", "check", "--name", "default"]] {
            assert_eq!(code(run(&mut session, list, "{}").await), "session_closed", "{list:?}");
        }
        assert_eq!(code(run(&mut session, &["session", "open"], "{}").await), "not_configured");
        assert!(session.open_absent().unwrap());
        assert!(run(&mut session, &["group", "list"], "{}").await.ok);
        let status = run(&mut session, &["session", "status"], "{}").await;
        assert_eq!(status.data.unwrap(), json!({"configured": false, "source": null, "open": true, "authorized": true}));
        assert!(!data.exists(), "absent state stays absent");
        assert!(journal.borrow().is_empty());

        // Configured state never opens without `session open`.
        let mut closed = configured(&root.path().join("data")).await;
        assert!(!closed.open_absent().unwrap());
        assert!(!closed.open && !closed.authorized);
        assert_eq!(code(run(&mut closed, &["group", "list"], "{}").await), "session_closed");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn script_password_verification_covers_every_case() {
        let root = tempfile::tempdir().unwrap();
        let (absent, _) = session(&root.path().join("absent"));
        assert!(absent.verify_script_password(&Secrets::default()).is_ok(), "no password configured");
        let session = configured(&root.path().join("data")).await;
        let missing = session.verify_script_password(&Secrets::default()).unwrap_err();
        assert_eq!((missing.code, missing.message.as_str(), missing.extra["secret"].clone()),
            ("auth_required", "Требуется пароль запуска.", json!("script-password")));
        let wrong = session.verify_script_password(&secrets(r#"{"script-password":"bad"}"#)).unwrap_err();
        assert_eq!((wrong.code, wrong.message.as_str(), wrong.extra["secret"].clone()),
            ("auth_failed", "Неверный пароль запуска.", json!("script-password")));
        assert!(session.verify_script_password(&secrets(r#"{"script-password":"first"}"#)).is_ok());
        assert!(!session.open && !session.authorized, "verification alone opens nothing");
        let before = session.state.auth_store().hash().unwrap();
        assert!(before.is_some_and(|hash| hash.starts_with("$argon2id$")));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn transport_flags_inputs_and_client_or_terminal_commands_are_refused() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = session(root.path());
        assert!(session.open_absent().unwrap());
        assert!(run(&mut session, &["source", "init-local"], "{}").await.ok);
        let before = crate::nodes::testing::fingerprint(root.path());
        let stdin = run(&mut session, &["group", "list", "--secrets-stdin"], "{}").await.error.unwrap();
        assert_eq!((stdin.code, stdin.message.as_str()), ("usage", "Секреты передаются полем secrets."));
        let foreign = run_input(&mut session, &["group", "list"], r#"{"file":"x"}"#).await.error.unwrap();
        assert_eq!((foreign.code, foreign.message.as_str()), ("usage", "Поле input не поддерживается командой."));
        let other = run_input(&mut session, &["template", "import", "--name", "t"], r#"{"other":"x"}"#).await;
        assert_eq!(code(other), "usage");
        assert_eq!(code(run(&mut session, &["template", "import", "--name", "t", "--file", "in.yaml"], "{}").await), "usage",
            "the client strips --file");
        for list in [&["template", "export", "--name", "default", "--output", "o"][..], &["daemon", "run"], &["daemon", "start"]] {
            let error = run(&mut session, list, "{}").await.error.unwrap();
            assert_eq!((error.code, error.message.as_str()), ("usage", "Команда выполняется на стороне клиента."), "{list:?}");
        }
        for list in [&["daemon", "status"][..], &["daemon", "stop"]] {
            let error = run(&mut session, list, "{}").await.error.unwrap();
            assert_eq!((error.code, error.message.as_str()), ("usage", "Неизвестная команда."), "{list:?}");
        }
        for (list, message) in [
            (&["node", "shell", "--name", "ghost"][..], "Меню сервера требует терминала."),
            (&["telegram", "menu", "--name", "ghost"], "Меню Telegram Proxy требует терминала."),
        ] {
            let error = run(&mut session, list, "{}").await.error.unwrap();
            assert_eq!((error.code, error.message.as_str(), error.exit_code()), ("tty_required", message, 2), "{list:?}");
        }
        assert_eq!(crate::nodes::testing::fingerprint(root.path()), before);
    }

    async fn prepare(session: &mut Session, list: &[&str]) -> Option<&'static str> {
        prepare_terminal(&argv(list), &Secrets::default(), &Input::default(), None, session).await.err().map(|e| e.code)
    }

    #[tokio::test(flavor = "current_thread")]
    async fn terminal_preparation_checks_the_session_before_any_connection() {
        let root = tempfile::tempdir().unwrap();
        let mut session = configured(root.path()).await;
        assert_eq!(prepare(&mut session, &["node", "shell", "--name", "ghost"]).await, Some("session_closed"));
        assert!(run(&mut session, &["session", "open"], r#"{"script-password":"first"}"#).await.ok);
        assert_eq!(prepare(&mut session, &["node", "shell", "--name", "ghost"]).await, Some("not_found"));
        assert_eq!(prepare(&mut session, &["telegram", "menu", "--name", "ghost"]).await, Some("not_found"));
        assert_eq!(prepare(&mut session, &["node", "shell", "--name", "ghost", "--secrets-stdin"]).await, Some("usage"));
        assert_eq!(prepare(&mut session, &["group", "list"]).await, Some("usage"));
        assert_eq!(prepare(&mut session, &["help"]).await, Some("usage"));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn template_import_and_client_config_go_through_dispatch() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, journal) = session(root.path());
        assert!(session.open_absent().unwrap());
        assert!(run(&mut session, &["source", "init-local"], "{}").await.ok);
        let content = crate::clients::templates::builtin("default.yaml").unwrap();
        let input = serde_json::to_string(&json!({"file": content})).unwrap();
        let imported = run_input(&mut session, &["template", "import", "--name", "lab"], &input).await;
        assert_eq!(imported.data, Some(json!({"name": "lab.yaml"})));
        let shown = run(&mut session, &["template", "show", "--name", "lab"], "{}").await;
        assert_eq!(shown.data.unwrap()["content"], content);
        let missing = run(&mut session, &["template", "import", "--name", "other"], "{}").await.error.unwrap();
        assert_eq!((missing.code, missing.message.as_str()), ("usage", "Передайте содержимое полем input.file."));
        // A template with problems needs confirmation; nothing is written before it.
        let before = crate::nodes::testing::fingerprint(root.path());
        let planned = run_input(&mut session, &["template", "import", "--name", "rough"], r#"{"file":"mode: rule\n"}"#).await;
        assert_eq!(code(planned), "confirmation_required");
        assert_eq!(crate::nodes::testing::fingerprint(root.path()), before);
        let checked = run_input(&mut session, &["template", "check"], r#"{"file":"mode: rule\n"}"#).await;
        assert_eq!(checked.data.unwrap()["problems"][0]["code"], "proxies");
        assert!(journal.borrow().iter().all(|(_, text)| !text.contains("mode: rule") && !text.contains("mixed-port")),
            "input never reaches the journal");

        assert!(run(&mut session, &["group", "add", "--name", "LAB"], "{}").await.ok);
        assert!(run(&mut session, &["client", "add", "--name", "pc", "--group", "LAB"], "{}").await.ok);
        let config = run(&mut session, &["client", "config", "--name", "pc"], "{}").await;
        assert_eq!(config.data, Some(json!({"name": "pc", "group": "LAB", "exists": false, "content": null})));
        assert_eq!(code(run(&mut session, &["client", "config", "--name", "ghost"], "{}").await), "not_found");
    }

    #[test]
    fn a_flush_failing_before_the_pin_saves_nothing() {
        use crate::github::{BRANCH, REPO_NAME, Storage, SyncStatus, Target, commands::GithubSession, stage_of, store};
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("data");
        let (mut session, journal) = session(&root);
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
        let (mut session, _journal) = session(&root);
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
