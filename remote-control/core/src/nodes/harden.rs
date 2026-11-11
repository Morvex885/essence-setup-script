//! `node harden` (v1 `hardening.sh`: `core_harden_pick_port`,
//! `core_node_harden_plan`, `core_node_harden`). A portable key is installed
//! and verified, password login is disabled and SSH moves to a new port while
//! the original authenticated session is held as the recovery channel. The
//! new port is proven by a fresh connect with the new key; any failure
//! restores the sshd configuration through the held session. The state
//! changes once, after the verification.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::setup::{self, FileBackup, PortableKey, identity_paths, public_fingerprint, run};
use super::{COMMAND_TIMEOUT, CONNECT_TIMEOUT, connect, connect_options, find, pins, require_portable, required};
use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::locking::LockKind;
use crate::log::Level;
use crate::model::{Auth, Fingerprint, Node, endpoint_key};
use crate::state::State;
use crate::transport::{Authentication, ConnectOptions, HostKeyPolicy, RemoteSession, RemoteTransport};

const SSHD_CONFIG: &str = "/etc/ssh/sshd_config";
/// Copy of the original sshd_config kept on the server until success.
const SSHD_BACKUP: &str = "/etc/ssh/sshd_config.essence-backup";

/// Replace `$c` by `lines` followed by its own (or `$src`) lines without
/// those matched by the extended regex `drop`.
fn rewrite(source: &str, lines: &[String], drop: &str) -> String {
    let lines: Vec<String> = lines.iter().map(|line| super::sh_quote(line)).collect();
    format!("{{ printf '%s\\n' {}; sed -E -e '/^[#[:space:]]*({drop})[[:space:]]/d' \"{source}\"; }} > \"$c.essence-new\" && \
cat \"$c.essence-new\" > \"$c\" && rm -f \"$c.essence-new\" || exit 1", lines.join(" "))
}

const RESTART: &str = "systemctl daemon-reload >/dev/null 2>&1; systemctl restart ssh.socket 2>/dev/null || systemctl restart sshd 2>/dev/null || \
systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null || service ssh restart 2>/dev/null";

/// `free`/`occupied` for a TCP listen port (local address column of `ss -tln`).
pub fn port_probe_command(port: u16) -> String {
    format!("ss -tln > /dev/null || exit 1; if ss -tln | awk '{{print $4}}' | grep -Eq ':{port}$'; then echo occupied; else echo free; fi")
}

/// Save the original config, then put key-only login first (ahead of any
/// `Include` or `Match`, so it wins) and validate. Takes effect on restart.
pub fn disable_password_command() -> String {
    format!("c={SSHD_CONFIG}; cp -p \"$c\" {SSHD_BACKUP} || exit 1; {}; sshd -t",
        rewrite(SSHD_BACKUP, &["PubkeyAuthentication yes".into(), "PasswordAuthentication no".into(), "KbdInteractiveAuthentication no".into()],
            "PubkeyAuthentication|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication"))
}

/// Move sshd to `port` and open it in the firewall; the old port stays open
/// until the new one is proven.
pub fn port_command(port: u16) -> String {
    format!("c={SSHD_CONFIG}; {}
if command -v ufw >/dev/null 2>&1; then ufw allow {port}/tcp >/dev/null 2>&1 || exit 1; fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then \
firewall-cmd --permanent --add-port={port}/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 || exit 1
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-enabled firewalld >/dev/null 2>&1; then exit 1; fi
sshd -t || exit 1; {RESTART}", rewrite("$c", &[format!("Port {port}")], "Port"))
}

/// Restore the saved config, close the new port and restart sshd.
pub fn rollback_command(port: u16) -> String {
    format!("c={SSHD_CONFIG}; if [ -f {SSHD_BACKUP} ]; then cat {SSHD_BACKUP} > \"$c\" && rm -f {SSHD_BACKUP} || exit 1; fi
if command -v ufw >/dev/null 2>&1; then ufw delete allow {port}/tcp >/dev/null 2>&1; fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then \
firewall-cmd --permanent --remove-port={port}/tcp >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
sshd -t || exit 1; {RESTART}")
}

/// After success: close the old SSH port (absent rules are not errors) and
/// drop the saved config.
pub fn finalize_command(old: u16, new: u16) -> String {
    let mut ufw = format!("ufw delete allow {old}/tcp >/dev/null 2>&1;");
    let mut firewalld = format!("firewall-cmd --permanent --remove-port={old}/tcp >/dev/null 2>&1;");
    if new != 22 {
        ufw.push_str(" ufw delete allow OpenSSH >/dev/null 2>&1; ufw delete allow 22/tcp >/dev/null 2>&1;");
        firewalld.push_str(" firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1;");
    }
    format!("if command -v ufw >/dev/null 2>&1; then {ufw} fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then {firewalld} firewall-cmd --reload >/dev/null 2>&1 || exit 1; fi
rm -f {SSHD_BACKUP}")
}

/// v1 port syntax: no leading zero, 1..=65535.
fn parse_port(value: &str) -> Result<u16> {
    let valid = (1..=5).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_digit()) && !value.starts_with('0');
    valid.then(|| value.parse::<u16>().ok()).flatten()
        .ok_or_else(|| RcError::new("invalid", "Порт должен быть числом от 1 до 65535."))
}

/// Candidate ports without `--port`: a fixed sequence derived from the node
/// id in 49152..=65535, so the plan (and its token) is the same on every run.
fn candidates(node: &Node) -> impl Iterator<Item = u16> + '_ {
    let digest = Sha256::digest(node.id.as_bytes());
    let base = u16::from_be_bytes([digest[0], digest[1]]) % 16384;
    (0..5u16).map(move |i| 49152 + (base + i * 3277) % 16384).filter(move |port| *port != node.port)
}

async fn port_free<S: RemoteSession>(session: &S, port: u16) -> Result<bool> {
    let failed = || RcError::new("remote_failed", "Не удалось проверить занятость SSH-порта на ноде.");
    match run(session, &port_probe_command(port), COMMAND_TIMEOUT).await.map_err(|_| failed())?.trim_end() {
        "free" => Ok(true),
        "occupied" => Ok(false),
        _ => Err(failed()),
    }
}

async fn pick_port<S: RemoteSession>(session: &S, node: &Node, requested: Option<u16>) -> Result<u16> {
    if let Some(port) = requested {
        if !port_free(session, port).await? {
            return Err(RcError::new("port_in_use", format!("Порт {port} на ноде занят.")).with_extra("port", port));
        }
        return Ok(port);
    }
    for port in candidates(node) {
        if port_free(session, port).await? {
            return Ok(port);
        }
    }
    Err(RcError::new("failed", "Не удалось найти свободный порт."))
}

fn hardening_failed(stage: &str, rolled_back: bool, console_required: bool) -> RcError {
    RcError::new("hardening_failed", format!("Усиление защиты SSH не выполнено (этап: {stage})."))
        .with_extra("stage", stage).with_extra("rolled_back", rolled_back).with_extra("console_required", console_required)
}

/// Undo through the held session: restore sshd and revoke the new key, then
/// prove the original login on a fresh connect.
async fn roll_back<T: RemoteTransport>(session: &mut Session, transport: &mut T, held: &T::Held, state: &State, node: &Node,
    key: &PortableKey, port: u16, stage: &str) -> RcError
{
    let restored = run(held, &rollback_command(port), COMMAND_TIMEOUT).await.is_ok();
    let revoked = setup::revoke(held, &key.public).await.is_ok();
    if !revoked {
        session.log(Level::Warn, &format!("Новый SSH-ключ ноды не отозван на сервере. Удалите его из ~/.ssh/authorized_keys вручную (отпечаток {}).",
            key.fingerprint()));
    }
    let reachable = restored && match connect_options(state, node, None) {
        Ok(options) => transport.connect(options).await.is_ok(),
        Err(_) => false,
    };
    if reachable {
        session.log(Level::Warn, &format!("SSH-порт возвращён на {}. Усиление защиты SSH прервано.", node.port));
    } else {
        session.log(Level::Warn, &format!("Не удалось подтвердить возврат SSH-порта. Проверьте порты {} и {port} через консоль провайдера.", node.port));
    }
    hardening_failed(stage, reachable && revoked, !reachable)
}

/// Record the hardened node: key files, port, key auth, pins of the new port;
/// the password secret goes last (`partial` if it cannot be removed).
fn persist(state: &State, node: &Node, port: u16, key: &PortableKey, pins: &[Fingerprint]) -> Result<()> {
    let mut files = vec![state.paths().config().to_path_buf(), state.paths().known_hosts().to_path_buf()];
    files.extend(identity_paths(state, &node.id));
    let backup = FileBackup::take(files)?;
    let saved = (|| {
        let mut config = state.load_config()?;
        let entry = config.nodes.iter_mut().find(|entry| entry.id == node.id).ok_or_else(|| super::not_found(&node.name))?;
        key.store(state)?;
        let mut known = state.load_known_hosts()?;
        known.0.insert(endpoint_key(&node.ip, port)?, pins.to_vec());
        state.save_known_hosts(&known)?;
        entry.port = port;
        entry.auth = Auth::Key;
        entry.identity = Some(node.id.clone());
        entry.secret_id = None;
        state.save_config(&config)
    })();
    if let Err(error) = saved {
        let _ = backup.restore();
        return Err(error);
    }
    if let Some(secret) = &node.secret_id {
        if state.secret_store().remove(secret).is_err() {
            return Err(RcError::new("partial", "Порт и SSH-ключ сохранены, но старый пароль не удалось удалить из локального состояния."));
        }
    }
    Ok(())
}

pub async fn harden<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, transport: &mut T) -> Result<Value> {
    let name = required(invocation, "name")?;
    let requested = if invocation.has("port") { Some(parse_port(required(invocation, "port")?)?) } else { None };
    let state = State::with_locks(session.state.paths().clone(), session.state.locks().clone());
    let node = find(&state.load_config()?, name)?.clone();
    super::authentication(&state, &node)?;
    require_portable(session, &node)?;
    connect(transport, &state, &node).await?;
    let port = pick_port(&*transport, &node, requested).await?;

    let [_, previous_path] = identity_paths(&state, &node.id);
    let previous = match node.identity.as_deref() == Some(node.id.as_str()) {
        true => std::fs::read_to_string(&previous_path).ok().map(|text| text.trim().to_owned()).filter(|text| !text.is_empty()),
        false => None,
    };
    let mut lines = vec![
        format!("Нода: {}  {}:{}", node.name, node.ip, node.port),
        format!("Пользователь: {}", node.user),
        format!("Ключ: {}", state.paths().identities().join(&node.id).display()),
        format!("Порт: {} → {port}", node.port),
        "Вход по паролю будет отключён.".into(),
        "Будет установлен SSH-ключ и изменены правила firewall для SSH.".into(),
        "При сбое может потребоваться консоль провайдера.".into(),
    ];
    if node.auth == Auth::Key && node.port != 22 {
        lines.push("Усиление защиты SSH уже выполнено; настройки будут изменены повторно.".into());
    }
    if previous.is_some() {
        lines.push("Прежний SSH-ключ ноды будет заменён новым и отозван на сервере.".into());
    }
    Plan::new(lines, "").confirm(invocation)?;

    let _guard = state.locks().acquire(LockKind::Mutation, "ssh_hardening")?;
    // The original authenticated session outlives every later connect.
    let held = transport.hold()?;
    let pins = pins(&state.load_known_hosts()?, &node)?;
    let key = match setup::provision_with(transport, &held, &state, &node, pins.clone(), &mut |level, text| session.log(level, text)).await {
        Ok(key) => key,
        Err(failure) => return Err(hardening_failed("key", failure.revoked, false)),
    };

    session.log(Level::Info, "Отключаем вход по паролю на сервере...");
    if run(&*transport, &disable_password_command(), COMMAND_TIMEOUT).await.is_err() {
        session.log(Level::Warn, "Не удалось изменить sshd_config.");
        return Err(roll_back(session, transport, &held, &state, &node, &key, port, "disable_password").await);
    }
    session.log(Level::Success, "Вход по паролю отключён (ожидает перезапуска SSH-сервиса)");

    session.log(Level::Info, &format!("Меняем SSH-порт на {port}..."));
    if run(&*transport, &port_command(port), COMMAND_TIMEOUT).await.is_err() {
        session.log(Level::Warn, "Не удалось применить новый SSH-порт.");
        return Err(roll_back(session, transport, &held, &state, &node, &key, port, "port").await);
    }
    let verify = ConnectOptions {
        host: node.ip.clone(), port, user: node.user.clone(),
        auth: Authentication::Key { identity: key.private_path(), passphrase: None },
        host_key: HostKeyPolicy { expected: None, known: pins.clone() }, timeout: CONNECT_TIMEOUT,
    };
    if transport.connect(verify).await.is_err() {
        session.log(Level::Warn, "Не удалось подключиться по новому порту.");
        return Err(roll_back(session, transport, &held, &state, &node, &key, port, "verify").await);
    }
    session.log(Level::Success, &format!("Подключение по порту {port} работает"));

    let saved = session.mutate("ssh_hardening", |state| persist(state, &node, port, &key, &pins));
    let secret_kept = match saved {
        Ok(()) => false,
        Err(error) if error.code == "partial" => {
            session.log(Level::Warn, &error.message);
            true
        }
        Err(_) => {
            session.log(Level::Warn, "Не удалось сохранить параметры усиления защиты SSH.");
            return Err(roll_back(session, transport, &held, &state, &node, &key, port, "save").await);
        }
    };
    if run(&*transport, &finalize_command(node.port, port), COMMAND_TIMEOUT).await.is_err() {
        session.log(Level::Warn, &format!("Не удалось закрыть прежний SSH-порт {} в firewall: закройте его вручную.", node.port));
    }
    if let Some(previous) = previous {
        session.log(Level::Info, "Отзываем прежний SSH-ключ ноды на сервере...");
        if setup::revoke(&*transport, &previous).await.is_err() {
            session.log(Level::Warn, &format!("Прежний SSH-ключ ноды не отозван на сервере. Удалите его из ~/.ssh/authorized_keys вручную (отпечаток {}).",
                public_fingerprint(&previous)));
        }
    }
    if secret_kept {
        return Err(hardening_failed("secret_delete", false, false));
    }
    session.log(Level::Success, "Усиление защиты SSH завершено!");
    session.log(Level::Info, &format!("Ключ: {}", state.paths().identities().join(&node.id).display()));
    session.log(Level::Info, &format!("Порт: {port}; вход по паролю отключён."));
    Ok(json!({"name": node.name, "port": port, "auth": "key"}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake_transport::{AuthMethod, FakeTransport, Operation, ScriptStep};
    use crate::nodes::setup::tests::{FP1, expect, fp, ok, test_public};
    use crate::nodes::setup::install_command;
    use crate::nodes::testing;
    use crate::transport::remote_failure;

    const ID: &str = "33333333333333333333333333333333";
    const SECRET: &str = "node:33333333333333333333333333333333:ssh-password";

    fn prepare(root: &std::path::Path) -> Session {
        let (session, _) = testing::session(root);
        let mut config = session.state.load_config().unwrap();
        config.nodes.push(serde_json::from_value(json!({"id": ID, "name": "n1", "ip": "192.0.2.10", "port": 22, "user": "root",
            "auth": "password", "identity": null, "secret_id": SECRET})).unwrap());
        session.state.save_config(&config).unwrap();
        session.state.secret_store().set(SECRET, zeroize::Zeroizing::new("pw".into())).unwrap();
        super::super::pin(&session.state, "192.0.2.10", 22, vec![fp(FP1)]).unwrap();
        session.state.checkpoint().unwrap();
        session
    }

    fn login() -> ScriptStep {
        ScriptStep::connect(expect("192.0.2.10", 22, AuthMethod::Password, &[FP1]), Ok(()))
    }

    fn probe(port: u16, answer: &str) -> ScriptStep {
        ScriptStep::exec(port_probe_command(port), 0, COMMAND_TIMEOUT, ok(answer))
    }

    #[tokio::test]
    async fn the_plan_and_its_token_are_stable_without_port() {
        let dir = tempfile::tempdir().unwrap();
        let mut session = prepare(dir.path());
        let before = testing::fingerprint(dir.path());
        let node = session.state.load_config().unwrap().nodes.remove(0);
        let mut ports = candidates(&node);
        let (busy, port) = (ports.next().unwrap(), ports.next().unwrap());
        let mut tokens = Vec::new();
        for _ in 0..2 {
            let mut fake = FakeTransport::new([login(), probe(busy, "occupied\n"), probe(port, "free\n")]);
            let error = harden(&mut session, &testing::invocation(&["node", "harden", "--name", "n1"]), &mut fake).await.unwrap_err();
            fake.assert_finished();
            assert_eq!(error.code, "confirmation_required");
            assert_eq!(error.extra["plan"][3], json!(format!("Порт: 22 → {port}")));
            tokens.push(error.extra["plan_token"].as_str().unwrap().to_owned());
        }
        assert_eq!(tokens[0], tokens[1]);
        assert_eq!(testing::fingerprint(dir.path()), before);

        let mut fake = FakeTransport::new([login(), probe(busy, "occupied\n"), probe(port, "free\n")]);
        let argv = ["node", "harden", "--name", "n1", "--yes", "--plan-token", &tokens[0]];
        let error = harden(&mut session, &testing::invocation(&argv), &mut fake).await.unwrap_err();
        assert_eq!(error.code, "hardening_failed", "the token is accepted; the script ends before the key install");
        assert!(fake.journal().contains(&Operation::Hold));
    }

    #[tokio::test]
    async fn an_occupied_port_is_refused_before_any_change() {
        let dir = tempfile::tempdir().unwrap();
        let mut session = prepare(dir.path());
        let before = testing::fingerprint(dir.path());
        let mut fake = FakeTransport::new([login(), probe(2222, "occupied\n")]);
        let error = harden(&mut session, &testing::invocation(&["node", "harden", "--name", "n1", "--port", "2222", "--yes"]), &mut fake)
            .await.unwrap_err();
        fake.assert_finished();
        assert_eq!((error.code, error.extra["port"].clone()), ("port_in_use", json!(2222)));
        assert_eq!(testing::fingerprint(dir.path()), before);
    }

    fn applied(public: &str) -> Vec<ScriptStep> {
        vec![
            login(),
            probe(2222, "free\n"),
            ScriptStep::exec(install_command(public), 0, COMMAND_TIMEOUT, ok("")),
            ScriptStep::connect(expect("192.0.2.10", 22, AuthMethod::Key, &[FP1]), Ok(())),
            ScriptStep::exec(disable_password_command(), 0, COMMAND_TIMEOUT, ok("")),
            ScriptStep::exec(port_command(2222), 0, COMMAND_TIMEOUT, ok("")),
        ]
    }

    #[tokio::test]
    async fn a_failed_verification_rolls_back_through_the_held_session() {
        let dir = tempfile::tempdir().unwrap();
        let mut session = prepare(dir.path());
        let before = testing::fingerprint(dir.path());
        let public = test_public(ID);
        let mut steps = applied(&public);
        steps.extend([
            ScriptStep::connect(expect("192.0.2.10", 2222, AuthMethod::Key, &[FP1]), Err(remote_failure("connect"))),
            ScriptStep::exec(rollback_command(2222), 0, COMMAND_TIMEOUT, ok("")),
            ScriptStep::exec(setup::revoke_command(&public), 0, COMMAND_TIMEOUT, ok("")),
            login(),
        ]);
        let mut fake = FakeTransport::new(steps);
        let error = harden(&mut session, &testing::invocation(&["node", "harden", "--name", "n1", "--port", "2222", "--yes"]), &mut fake)
            .await.unwrap_err();
        fake.assert_finished();
        assert_eq!(error.code, "hardening_failed");
        assert_eq!((error.extra["stage"].clone(), error.extra["rolled_back"].clone(), error.extra["console_required"].clone()),
            (json!("verify"), json!(true), json!(false)));
        let journal = fake.journal();
        let hold = journal.iter().position(|op| matches!(op, Operation::Hold)).unwrap();
        let install = journal.iter().position(|op| matches!(op, Operation::Exec { command, .. } if *command == install_command(&public))).unwrap();
        assert!(hold < install, "the original session is held before the first change");
        assert_eq!(testing::fingerprint(dir.path()), before, "config, pins, secrets and identities unchanged");
    }

    #[tokio::test]
    async fn a_failed_rollback_requires_the_console() {
        let dir = tempfile::tempdir().unwrap();
        let mut session = prepare(dir.path());
        let public = test_public(ID);
        let mut steps = applied(&public);
        steps.extend([
            ScriptStep::connect(expect("192.0.2.10", 2222, AuthMethod::Key, &[FP1]), Err(remote_failure("connect"))),
            ScriptStep::exec(rollback_command(2222), 0, COMMAND_TIMEOUT, Err(remote_failure("exit_status"))),
            ScriptStep::exec(setup::revoke_command(&public), 0, COMMAND_TIMEOUT, ok("")),
        ]);
        let mut fake = FakeTransport::new(steps);
        let error = harden(&mut session, &testing::invocation(&["node", "harden", "--name", "n1", "--port", "2222", "--yes"]), &mut fake)
            .await.unwrap_err();
        fake.assert_finished();
        assert_eq!((error.extra["rolled_back"].clone(), error.extra["console_required"].clone()), (json!(false), json!(true)));
        assert_eq!(session.state.load_config().unwrap().nodes[0].port, 22);
    }

    #[tokio::test]
    async fn success_records_port_key_pins_and_drops_the_password() {
        let dir = tempfile::tempdir().unwrap();
        let mut session = prepare(dir.path());
        let public = test_public(ID);
        let mut steps = applied(&public);
        steps.extend([
            ScriptStep::connect(expect("192.0.2.10", 2222, AuthMethod::Key, &[FP1]), Ok(())),
            ScriptStep::exec(finalize_command(22, 2222), 0, COMMAND_TIMEOUT, ok("")),
        ]);
        let mut fake = FakeTransport::new(steps);
        let data = harden(&mut session, &testing::invocation(&["node", "harden", "--name", "n1", "--port", "2222", "--yes"]), &mut fake)
            .await.unwrap();
        fake.assert_finished();
        assert_eq!(data, json!({"name": "n1", "port": 2222, "auth": "key"}));
        let node = session.state.load_config().unwrap().nodes.remove(0);
        assert_eq!((node.port, node.auth, node.identity.as_deref(), node.secret_id.as_deref()), (2222, Auth::Key, Some(ID), None));
        assert_eq!(pins(&session.state.load_known_hosts().unwrap(), &node).unwrap(), vec![fp(FP1)]);
        assert_eq!(session.state.secret_store().get(SECRET).unwrap(), None);
        let [_, public_path] = identity_paths(&session.state, ID);
        assert_eq!(std::fs::read_to_string(public_path).unwrap(), format!("{public}\n"));
    }
}
