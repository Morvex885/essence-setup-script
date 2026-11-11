//! `node add` (v1 `cli_cmd_node_add` + `core_node_add`). Host trust comes
//! only from the connection itself: the transport reports the server
//! fingerprint on `host_key_unknown/mismatch/changed`, and nothing is written
//! unless a connection under the agreed key authenticated and ran `echo ok`.
//! In GitHub mode a key node gets its portable key (`setup::provision`)
//! before anything is written. Pin, password secret, portable key files,
//! portability issues and the node entry are written in one
//! `Session::mutate` transaction that restores every touched file when a
//! later step fails.

use std::path::PathBuf;

use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::model::{Auth, Fingerprint, Node, PortabilityReason, endpoint_key};
use crate::request_secrets::Secrets;
use crate::state::State;
use crate::transport::{Authentication, ConnectOptions, HostKeyPolicy, RemoteTransport};
use crate::validation::{name_valid, node_tag_valid, parse_ssh_port, ssh_host_valid, ssh_user_valid};

use super::setup::{self, FileBackup, PortableKey};
use super::{COMMAND_TIMEOUT, CONNECT_TIMEOUT, is_github, pin, required, set_issue};

/// The state files a node transaction may touch, plus `extra`. Local
/// `mutate` does not restore on a failed closure, so the closure restores a
/// `FileBackup` of these itself.
pub(super) fn transaction_files(state: &State, extra: impl IntoIterator<Item = PathBuf>) -> Vec<PathBuf> {
    let paths = state.paths();
    [paths.config(), paths.secrets(), paths.secret_key(), paths.manifest(), paths.known_hosts()].into_iter()
        .map(std::path::Path::to_path_buf).chain(extra).collect()
}

/// How the server key is agreed (v1 HOSTKEY_MODE).
enum HostKeyMode {
    /// Default: only an already pinned key is accepted.
    KnownOnly,
    /// Trust on first use; a pinned endpoint still must match its pins.
    AcceptNew,
    /// `--host-key`: the key must match; an endpoint pinned to another key is refused.
    Pin(Fingerprint),
    /// `--replace-host-key` (planned): the endpoint's pins become exactly this key.
    Replace(Fingerprint),
}

fn usage(message: &str) -> RcError {
    RcError::new("usage", message)
}

fn invalid(message: String) -> RcError {
    RcError::new("invalid", message)
}

fn fingerprint_flag(invocation: &Invocation, flag: &str) -> Result<Fingerprint> {
    invocation.value(flag).unwrap_or_default().parse()
        .map_err(|_| usage(&format!("Флаг --{flag} ожидает отпечаток вида SHA256:…")))
}

fn host_key_mode(invocation: &Invocation) -> Result<HostKeyMode> {
    let (pinned, accept, replace) =
        (invocation.has("host-key"), invocation.has("accept-new-host-key"), invocation.has("replace-host-key"));
    if pinned && accept {
        return Err(usage("Укажите только один из флагов: --host-key | --accept-new-host-key."));
    }
    if pinned && replace {
        return Err(usage("Укажите только один из флагов: --host-key | --replace-host-key."));
    }
    if accept && replace {
        return Err(usage("Укажите только один из флагов: --accept-new-host-key | --replace-host-key."));
    }
    Ok(if replace {
        HostKeyMode::Replace(fingerprint_flag(invocation, "replace-host-key")?)
    } else if pinned {
        HostKeyMode::Pin(fingerprint_flag(invocation, "host-key")?)
    } else if accept {
        HostKeyMode::AcceptNew
    } else {
        HostKeyMode::KnownOnly
    })
}

fn fingerprints(error: &RcError) -> Vec<String> {
    error.extra.get("fingerprints").and_then(Value::as_array)
        .map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

/// The node being added, before anything is written.
struct Draft<'a> {
    node: Node,
    password: Option<&'a str>,
    github: bool,
}

impl Draft<'_> {
    fn options(&self, expected: Option<Fingerprint>, known: Vec<Fingerprint>) -> ConnectOptions {
        ConnectOptions {
            host: self.node.ip.clone(),
            port: self.node.port,
            user: self.node.user.clone(),
            auth: match self.password {
                Some(password) => Authentication::Password(Zeroizing::new(password.to_owned())),
                None => Authentication::System,
            },
            host_key: HostKeyPolicy { expected, known },
            timeout: CONNECT_TIMEOUT,
        }
    }

    /// v1 wording of each connect failure; the transport's structured
    /// `{host, port, fingerprints, reason}` stays.
    fn connect_failure(&self, session: &mut Session, mut error: RcError) -> RcError {
        let (ip, port) = (&self.node.ip, self.node.port);
        match error.code {
            "host_key_unknown" => {
                session.log(Level::Info, &format!("Отпечатки ключа сервера {ip}:{port}: {}", fingerprints(&error).join(" ")));
                error.message = "Ключ сервера не закреплён. Проверьте отпечаток и повторите с --host-key <SHA256:…> или --accept-new-host-key.".into();
            }
            "host_key_changed" => {
                error.message = "Ключ сервера изменился. Проверьте отпечаток и повторите с --replace-host-key <SHA256:…>.".into();
            }
            "host_key_mismatch" => {
                error.message = format!("Отпечаток ключа сервера не совпадает. Получено: {}", fingerprints(&error).join(" "));
            }
            "remote_failed" => {
                error.message = format!("Не удалось подключиться к «{}».", self.node.name);
                if self.node.auth == Auth::Key && !self.github {
                    let hint = format!("ssh-copy-id {}@{ip}", self.node.user);
                    session.log(Level::Warn, &format!("Добавьте SSH-ключ на сервер командой: {hint}"));
                    error = error.with_extra("hint", hint);
                }
            }
            _ => {}
        }
        error.with_extra("name", self.node.name.clone())
    }

    /// Connect under the agreed host key; the fingerprint to pin, if the
    /// endpoint's pins change.
    async fn establish<T: RemoteTransport>(&self, session: &mut Session, transport: &mut T, mode: &HostKeyMode,
        pins: &[Fingerprint]) -> Result<Option<Fingerprint>>
    {
        let (ip, port) = (&self.node.ip, self.node.port);
        let pinned = match mode {
            HostKeyMode::KnownOnly => None,
            HostKeyMode::AcceptNew => match transport.connect(self.options(None, pins.to_vec())).await {
                Ok(()) => None,
                Err(error) if error.code == "host_key_unknown" => {
                    let fingerprint = fingerprints(&error).first().and_then(|fp| fp.parse::<Fingerprint>().ok())
                        .ok_or_else(|| RcError::new("remote_failed", format!("Не удалось получить ключ сервера {ip}:{port}.")))?;
                    session.log(Level::Info, &format!("Отпечатки ключа сервера {ip}:{port}: {fingerprint}"));
                    Some(fingerprint)
                }
                Err(error) => return Err(self.connect_failure(session, error)),
            },
            HostKeyMode::Pin(fingerprint) | HostKeyMode::Replace(fingerprint) => Some(fingerprint.clone()),
        };
        let result = match (mode, &pinned) {
            (HostKeyMode::AcceptNew, None) => Ok(()),
            (_, expected) => transport.connect(self.options(expected.clone(), pins.to_vec())).await,
        };
        result.map_err(|error| self.connect_failure(session, error))?;
        Ok(match (mode, pinned) {
            (_, None) => None,
            (HostKeyMode::Pin(fingerprint), _) if !pins.is_empty() && !pins.contains(fingerprint) => {
                // The server presented the operator's key, but this endpoint
                // trusts another one: replacing pins needs the planned flag.
                return Err(RcError::new("host_key_changed", format!(
                    "Ключ сервера {ip}:{port} уже известен и отличается от указанного. Проверьте отпечаток и повторите с --replace-host-key <SHA256:…>."))
                    .with_extra("host", ip.clone()).with_extra("port", port)
                    .with_extra("fingerprints", json!([fingerprint])).with_extra("name", self.node.name.clone()));
            }
            (_, Some(fingerprint)) if pins == std::slice::from_ref(&fingerprint) => None,
            (HostKeyMode::Pin(_), Some(fingerprint)) if pins.contains(&fingerprint) => None,
            (_, pinned) => pinned,
        })
    }

    /// The single transaction: pin, secret, portable key, node, issues, checkpoint.
    fn apply(&self, state: &State, pinned: Option<&Fingerprint>, key: Option<&PortableKey>, issues: &[PortabilityReason])
        -> Result<()>
    {
        let mut config = state.load_config()?;
        if config.nodes.iter().any(|node| node.name == self.node.name) {
            return Err(conflict(&self.node.name));
        }
        if let Some(fingerprint) = pinned {
            pin(state, &self.node.ip, self.node.port, vec![fingerprint.clone()])?;
        }
        if let (Some(secret_id), Some(password)) = (self.node.secret_id.as_deref(), self.password) {
            state.secret_store().set(secret_id, Zeroizing::new(password.to_owned()))?;
        }
        if let Some(key) = key {
            // The transaction backup covers these files; the pair's own backup is not needed.
            key.store(state)?;
        }
        config.nodes.push(self.node.clone());
        state.save_config(&config)?;
        if !issues.is_empty() {
            let mut manifest = state.load_manifest()?;
            for reason in issues {
                set_issue(&mut manifest, &self.node.id, *reason, true);
            }
            state.save_manifest(&manifest)?;
        }
        // Checkpoint inside the transaction so its failure is rolled back too.
        state.checkpoint()
    }
}

fn conflict(name: &str) -> RcError {
    RcError::new("conflict", format!("Нода с именем «{name}» уже существует.")).with_extra("name", name)
}

/// `node add --name N --ip IP [--port 22] [--user root] --auth key|password --tag T
/// [--host-key FP | --accept-new-host-key | --replace-host-key FP] [--defer-ssh-setup]`.
pub async fn add<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, secrets: &Secrets, transport: &mut T)
    -> Result<Value>
{
    let name = required(invocation, "name")?;
    let ip = required(invocation, "ip")?;
    let auth_flag = required(invocation, "auth")?;
    if !invocation.has("tag") {
        return Err(usage("Укажите --tag."));
    }
    let password = secrets.get("password");
    let auth = match auth_flag {
        "key" if password.is_some() => return Err(usage("Секрет password используется только с --auth password.")),
        "key" => Auth::Key,
        "password" if password.is_some_and(|password| !password.is_empty()) => Auth::Password,
        "password" => return Err(usage("Для --auth password нужен секрет password (--password-stdin или поле secrets).")),
        _ => return Err(usage("Флаг --auth принимает key или password.")),
    };
    let mode = host_key_mode(invocation)?;
    let github = is_github(session);
    let defer = invocation.has("defer-ssh-setup");
    if defer && !github {
        return Err(usage("Флаг --defer-ssh-setup доступен только в режиме GitHub."));
    }
    if defer && !matches!(mode, HostKeyMode::KnownOnly) {
        return Err(usage("Флаг --defer-ssh-setup не сочетается с флагами ключа сервера: ключ закрепит node setup-ssh."));
    }

    if !name_valid(name) {
        return Err(invalid(format!("Недопустимое имя ноды «{name}»: латиница, цифры, «.», «_», «-».")).with_extra("name", name));
    }
    let config = session.state.load_config()?;
    if config.nodes.iter().any(|node| node.name == name) {
        return Err(conflict(name));
    }
    if !ssh_host_valid(ip) {
        return Err(invalid("Адрес сервера должен быть IP или именем хоста: латиница, цифры, «.», «:», «_», «-»; первый символ не «-».".into()));
    }
    let port = parse_ssh_port(invocation.value("port").filter(|port| !port.is_empty()).unwrap_or("22"))?;
    let user = invocation.value("user").filter(|user| !user.is_empty()).unwrap_or("root");
    if !ssh_user_valid(user) {
        return Err(invalid("Логин SSH: до 32 символов — латиница, цифры, «.», «_», «-»; первый символ — буква или «_».".into()));
    }
    let tag = invocation.value("tag").unwrap_or_default();
    if tag.is_empty() {
        return Err(invalid("Тег обязателен — он различает прокси разных нод.".into()));
    }
    if !node_tag_valid(tag) {
        return Err(invalid(format!("Недопустимый тег «{tag}»: до 32 символов, без управляющих символов и ;\"'`$\\|&<>{{}}[]#,:/.")));
    }
    let pins = session.state.load_known_hosts()?.0.get(&endpoint_key(ip, port)?).cloned().unwrap_or_default();

    if let HostKeyMode::Replace(fingerprint) = &mode {
        let known = pins.iter().map(Fingerprint::as_str).collect::<Vec<_>>().join(", ");
        Plan::new(vec![
            format!("Нода: {name} {ip}:{port}"),
            format!("Прежние отпечатки: {}", if known.is_empty() { "нет" } else { &known }),
            format!("Новый отпечаток: {fingerprint}"),
            "Прежние записи known_hosts для узла будут удалены.".to_owned(),
        ], "").confirm(invocation)?;
    }

    // The stable id is allocated before the connection test and never changes.
    let id = crate::github::random_hex(16);
    let mut draft = Draft {
        node: Node {
            id: id.clone(), name: name.to_owned(), ip: ip.to_owned(), port, user: user.to_owned(), auth,
            identity: (auth == Auth::Key).then(|| "system".to_owned()),
            secret_id: (auth == Auth::Password).then(|| format!("node:{id}:ssh-password")),
            tag: Some(tag.to_owned()), aliases: Default::default(),
        },
        password: password.filter(|_| auth == Auth::Password),
        github,
    };
    draft.node.validate()?;

    let mut issues = Vec::new();
    let mut key = None;
    let pinned = if defer {
        session.log(Level::Warn, &format!("SSH-настройка ноды «{name}» отложена: сервер не проверялся."));
        issues.push(PortabilityReason::MissingHostKey);
        if auth == Auth::Key {
            issues.push(PortabilityReason::MissingIdentity);
        }
        None
    } else {
        session.log(Level::Info, "Проверяем подключение...");
        let pinned = draft.establish(session, transport, &mode, &pins).await?;
        let check = transport.exec("echo ok", b"", COMMAND_TIMEOUT).await;
        let ok = check.as_ref().is_ok_and(|result| result.exit_status == 0
            && String::from_utf8_lossy(&result.stdout).lines().any(|line| line == "ok"));
        if !ok {
            let error = check.err().unwrap_or_else(|| RcError::new("remote_failed", "").with_extra("reason", Value::Null));
            return Err(draft.connect_failure(session, error));
        }
        session.log(Level::Success, "Подключение успешно");
        if github && auth == Auth::Key {
            // A GitHub node must be reachable from any device: its own key.
            let trusted = pinned.clone().map_or_else(|| pins.clone(), |fingerprint| vec![fingerprint]);
            let mut entries = Vec::new();
            let provisioned = setup::provision(transport, &session.state, &draft.node, trusted,
                &mut |level, text| entries.push((level, text.to_owned()))).await;
            for (level, text) in entries {
                session.log(level, &text);
            }
            let provisioned = provisioned.map_err(|error| {
                RcError::new("onboarding_failed", "Не удалось настроить переносимый SSH-ключ. Изменения отменены.")
                    .with_extra("name", name).with_extra("cause", error.message)
            })?;
            draft.node.identity = Some(id.clone());
            key = Some(provisioned);
        }
        pinned
    };
    let needs_setup = !issues.is_empty();

    let saved = session.mutate("node add", |state| {
        let extra = if key.is_some() { setup::identity_paths(state, &id).to_vec() } else { Vec::new() };
        let backup = FileBackup::take(transaction_files(state, extra))?;
        let Err(error) = draft.apply(state, pinned.as_ref(), key.as_ref(), &issues) else { return Ok(()) };
        if backup.restore().is_ok() {
            return Err(error);
        }
        let kept = state.load_config().map_or(true, |config| config.nodes.iter().any(|node| node.id == draft.node.id));
        if !kept {
            return Err(error);
        }
        Err(RcError::new("partial", format!("Нода «{name}» сохранена, но локальную точку восстановления сохранить не удалось."))
            .with_extra("name", name).with_extra("id", id.clone()).with_extra("needs_setup", needs_setup))
    });
    if let Err(error) = saved {
        // The node was not recorded: its new key must not stay authorized.
        if let Some(key) = key.as_ref().filter(|_| error.code != "partial") {
            if setup::revoke(&*transport, &key.public).await.is_err() {
                session.log(Level::Warn, &format!(
                    "Не удалось отозвать переносимый SSH-ключ ноды «{name}». Удалите его из authorized_keys вручную (отпечаток {}).",
                    key.fingerprint()));
            }
        }
        return Err(error);
    }

    if let Some(fingerprint) = &pinned {
        session.log(Level::Success, &format!("Ключ сервера {ip}:{port} закреплён ({fingerprint})"));
    }
    session.log(Level::Success, &format!("Нода «{name}» сохранена"));
    Ok(json!({"name": name, "id": id, "needs_setup": needs_setup}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake_transport::{AuthMethod, ConnectExpectation, FakeTransport, Operation, ScriptStep};
    use crate::nodes::testing;
    use crate::transport::ExecResult;

    const IP: &str = "198.51.100.7";

    fn fp(c: char) -> Fingerprint {
        format!("SHA256:{}A", c.to_string().repeat(42)).parse().unwrap()
    }

    fn host_key_error(code: &'static str, server: &Fingerprint) -> RcError {
        RcError::new(code, "Ключ SSH-сервера не подтверждён.")
            .with_extra("host", IP).with_extra("port", 22).with_extra("fingerprints", json!([server]))
    }

    fn connect(auth: AuthMethod, expected: Option<Fingerprint>, known: Vec<Fingerprint>, outcome: Result<()>) -> ScriptStep {
        ScriptStep::connect(
            ConnectExpectation::new(IP, 22, "root", auth, CONNECT_TIMEOUT).with_host_key(HostKeyPolicy { expected, known }),
            outcome,
        )
    }

    fn echo(stdout: &str) -> ScriptStep {
        ScriptStep::exec("echo ok", 0, COMMAND_TIMEOUT,
            Ok(ExecResult { stdout: stdout.as_bytes().to_vec(), stderr: Vec::new(), exit_status: 0 }))
    }

    fn argv<'a>(extra: &[&'a str]) -> Vec<&'a str> {
        let mut argv = vec!["node", "add", "--name", "de", "--ip", IP, "--tag", "DE"];
        argv.extend_from_slice(extra);
        argv
    }

    fn password() -> Secrets {
        let mut secrets = Secrets::default();
        secrets.insert("password", Zeroizing::new("s3cret".into())).unwrap();
        secrets
    }

    /// Runs `node add` and asserts the data directory did not change.
    async fn refused(root: &std::path::Path, session: &mut Session, extra: &[&str], secrets: &Secrets,
        steps: Vec<ScriptStep>) -> RcError
    {
        let before = testing::fingerprint(root);
        let mut transport = FakeTransport::new(steps);
        let error = add(session, &testing::invocation(&argv(extra)), secrets, &mut transport).await.unwrap_err();
        transport.assert_finished();
        assert_eq!(testing::fingerprint(root), before, "{} wrote state", error.code);
        error
    }

    #[tokio::test]
    async fn host_key_refusals_write_nothing() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = testing::session(root.path());
        let none = Secrets::default();

        let error = refused(root.path(), &mut session, &["--auth", "key"], &none,
            vec![connect(AuthMethod::System, None, vec![], Err(host_key_error("host_key_unknown", &fp('B'))))]).await;
        assert_eq!((error.code, error.exit_code()), ("host_key_unknown", 2));
        assert_eq!(error.extra["fingerprints"], json!([fp('B')]));

        let error = refused(root.path(), &mut session, &["--auth", "password", "--host-key", fp('A').as_str()], &password(),
            vec![connect(AuthMethod::Password, Some(fp('A')), vec![], Err(host_key_error("host_key_mismatch", &fp('B'))))]).await;
        assert_eq!(error.code, "host_key_mismatch");
        assert_eq!(error.message, format!("Отпечаток ключа сервера не совпадает. Получено: {}", fp('B')));

        pin(&session.state, IP, 22, vec![fp('A')]).unwrap();
        let error = refused(root.path(), &mut session, &["--auth", "key"], &none,
            vec![connect(AuthMethod::System, None, vec![fp('A')], Err(host_key_error("host_key_changed", &fp('B'))))]).await;
        assert_eq!(error.code, "host_key_changed");
        assert_eq!((&error.extra["host"], &error.extra["port"], &error.extra["fingerprints"]), (&json!(IP), &json!(22), &json!([fp('B')])));

        // The server shows the operator's key, but the endpoint trusts another.
        let error = refused(root.path(), &mut session, &["--auth", "key", "--host-key", fp('B').as_str()], &none,
            vec![connect(AuthMethod::System, Some(fp('B')), vec![fp('A')], Ok(()))]).await;
        assert_eq!(error.code, "host_key_changed");
        assert_eq!(error.extra["fingerprints"], json!([fp('B')]));

        // A failed command check after a good handshake writes nothing either.
        let error = refused(root.path(), &mut session, &["--auth", "key"], &none,
            vec![connect(AuthMethod::System, None, vec![fp('A')], Ok(())), echo("denied\n")]).await;
        assert_eq!((error.code, &error.extra["hint"]), ("remote_failed", &json!(format!("ssh-copy-id root@{IP}"))));
    }

    #[tokio::test]
    async fn success_writes_exactly_one_pin_secret_and_node() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = testing::session(root.path());
        let mut transport = FakeTransport::new([connect(AuthMethod::Password, Some(fp('A')), vec![], Ok(())), echo("ok\n")]);
        let data = add(&mut session, &testing::invocation(&argv(&["--auth", "password", "--host-key", fp('A').as_str(), "--port", "22"])),
            &password(), &mut transport).await.unwrap();
        transport.assert_finished();
        let id = data["id"].as_str().unwrap().to_owned();
        assert_eq!(data, json!({"name": "de", "id": id, "needs_setup": false}));
        assert_eq!(transport.journal().iter().filter(|op| matches!(op, Operation::Connect(_))).count(), 1);

        let known = session.state.load_known_hosts().unwrap();
        assert_eq!(known.0.len(), 1);
        assert_eq!(known.0[&endpoint_key(IP, 22).unwrap()], vec![fp('A')]);
        let config = session.state.load_config().unwrap();
        assert_eq!(config.nodes, vec![Node {
            id: id.clone(), name: "de".into(), ip: IP.into(), port: 22, user: "root".into(), auth: Auth::Password,
            identity: None, secret_id: Some(format!("node:{id}:ssh-password")), tag: Some("DE".into()), aliases: Default::default(),
        }]);
        assert_eq!(session.state.secret_store().get(&format!("node:{id}:ssh-password")).unwrap().as_deref().map(String::as_str), Some("s3cret"));
        assert!(session.state.load_manifest().unwrap().portability.issues.is_empty());
    }

    #[tokio::test]
    async fn accept_new_pins_the_presented_key() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = testing::session(root.path());
        let mut transport = FakeTransport::new([
            connect(AuthMethod::System, None, vec![], Err(host_key_error("host_key_unknown", &fp('C')))),
            connect(AuthMethod::System, Some(fp('C')), vec![], Ok(())),
            echo("ok\n"),
        ]);
        add(&mut session, &testing::invocation(&argv(&["--auth", "key", "--accept-new-host-key"])), &Secrets::default(), &mut transport)
            .await.unwrap();
        transport.assert_finished();
        assert_eq!(session.state.load_known_hosts().unwrap().0[&endpoint_key(IP, 22).unwrap()], vec![fp('C')]);
        assert_eq!(session.state.load_config().unwrap().nodes[0].identity.as_deref(), Some("system"));
    }

    #[tokio::test]
    async fn replace_host_key_requires_confirmation_then_replaces_pins() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = testing::session(root.path());
        pin(&session.state, IP, 22, vec![fp('A')]).unwrap();
        let error = refused(root.path(), &mut session, &["--auth", "key", "--replace-host-key", fp('B').as_str()],
            &Secrets::default(), vec![]).await;
        assert_eq!(error.code, "confirmation_required");
        assert_eq!(error.extra["plan"], json!([
            format!("Нода: de {IP}:22"), format!("Прежние отпечатки: {}", fp('A')), format!("Новый отпечаток: {}", fp('B')),
            "Прежние записи known_hosts для узла будут удалены.",
        ]));

        let mut transport = FakeTransport::new([connect(AuthMethod::System, Some(fp('B')), vec![fp('A')], Ok(())), echo("ok\n")]);
        add(&mut session, &testing::invocation(&argv(&["--auth", "key", "--replace-host-key", fp('B').as_str(), "--yes"])),
            &Secrets::default(), &mut transport).await.unwrap();
        transport.assert_finished();
        assert_eq!(session.state.load_known_hosts().unwrap().0[&endpoint_key(IP, 22).unwrap()], vec![fp('B')]);
    }

    #[tokio::test]
    async fn failure_inside_the_transaction_restores_the_pin() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = testing::session(root.path());
        // An unreadable secret container fails the write after the pin.
        std::fs::write(session.state.paths().secrets(), b"{").unwrap();
        let error = refused(root.path(), &mut session, &["--auth", "password", "--host-key", fp('A').as_str()], &password(),
            vec![connect(AuthMethod::Password, Some(fp('A')), vec![], Ok(())), echo("ok\n")]).await;
        assert_ne!(error.code, "partial");
    }

    #[tokio::test]
    async fn github_defer_saves_a_pending_node_without_contact() {
        use crate::github::{BRANCH, REPO_NAME, Storage, SyncStatus, Target, commands::GithubSession, store::WorkSession};
        let (root, worktree) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let (mut session, _journal) = testing::session(root.path());
        session.github = Some(GithubSession {
            target: Target::new("alice", REPO_NAME, BRANCH),
            work: Some(WorkSession { store: worktree.path().join("store"), sessions: worktree.path().join("sessions"), id: "t".into(),
                worktree: worktree.path().to_path_buf(), branch: BRANCH.into(), origin: String::new() }),
            storage: Storage::Plain, keys: None, sync: SyncStatus::Clean, last_counts: Value::Null, last_version: None,
        });
        let mut transport = FakeTransport::new([]);
        let data = add(&mut session, &testing::invocation(&argv(&["--auth", "key", "--defer-ssh-setup"])), &Secrets::default(), &mut transport)
            .await.unwrap();
        assert!(transport.journal().is_empty());
        assert_eq!(data["needs_setup"], json!(true));
        let id = data["id"].as_str().unwrap();
        let reasons: Vec<_> = session.state.load_manifest().unwrap().portability.issues.into_iter()
            .filter(|issue| issue.node_id == id).map(|issue| issue.reason).collect();
        assert_eq!(reasons, [PortabilityReason::MissingIdentity, PortabilityReason::MissingHostKey]);
        assert!(session.state.load_known_hosts().unwrap().0.is_empty());
        let error = super::super::require_portable(&session, &session.state.load_config().unwrap().nodes[0]).unwrap_err();
        assert_eq!(error.code, "needs_setup");
    }

    #[tokio::test]
    async fn validation_precedes_any_contact() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _journal) = testing::session(root.path());
        let none = Secrets::default();
        for (extra, secrets, code) in [
            (vec!["--auth", "key"], &password(), "usage"),
            (vec!["--auth", "password"], &none, "usage"),
            (vec!["--auth", "token"], &none, "usage"),
            (vec!["--auth", "key", "--host-key", "SHA256:x"], &none, "usage"),
            (vec!["--auth", "key", "--accept-new-host-key", "--replace-host-key", fp('A').as_str()], &none, "usage"),
            (vec!["--auth", "key", "--defer-ssh-setup"], &none, "usage"),
            (vec!["--auth", "key", "--port", "70000"], &none, "invalid"),
            (vec!["--auth", "key", "--user", "a@b"], &none, "invalid"),
        ] {
            let error = refused(root.path(), &mut session, &extra, secrets, vec![]).await;
            assert_eq!(error.code, code, "{extra:?}");
        }
        let mut transport = FakeTransport::new([]);
        let error = add(&mut session, &testing::invocation(&["node", "add", "--name", "a b", "--ip", IP, "--auth", "key", "--tag", "T"]),
            &none, &mut transport).await.unwrap_err();
        assert_eq!(error.code, "invalid");
        let error = add(&mut session, &testing::invocation(&["node", "add", "--name", "de", "--ip", "-oProxyCommand=x", "--auth", "key", "--tag", "T"]),
            &none, &mut transport).await.unwrap_err();
        assert_eq!(error.code, "invalid");
        transport.assert_finished();
    }
}
