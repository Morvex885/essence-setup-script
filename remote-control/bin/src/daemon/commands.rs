//! `daemon status|stop` and `web status|start|stop|link`: answered by the
//! daemon itself, without the core queue (the core state comes from its
//! published snapshot). Also the listener flags shared by `web start` and
//! `daemon run --web`.

use std::net::{IpAddr, Ipv4Addr};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use essence_rc_client::{Origin, PROTOCOL};
use essence_rc_web::{Accepted, ListenError, Listener, ListenerConfig, Tls};
use rc_core::cli::Invocation;
use rc_core::dispatch::Envelope;
use rc_core::error::{RcError, Result};
use rc_core::secure_fs;
use rc_core::VERSION;
use serde_json::{Value, json};
use tokio::sync::mpsc;
use zeroize::Zeroizing;

use super::conn::{self, Conn, daemon_stopping};
use super::{Shared, WebInfo, lock};

pub const DEFAULT_PORT: u16 = 8377;
/// Accepted WebSocket connections waiting for the daemon.
const ACCEPT_QUEUE: usize = 16;
pub const OPEN_PANEL_WARNING: &str = "Пароль запуска не задан: панель доступна всем в сети.";

pub fn run(shared: &Arc<Shared>, conn: &Arc<Conn>, id: &Value, invocation: &Invocation) {
    match invocation.verb.as_str() {
        "status" => conn.reply(id, Envelope::success(status(shared))),
        // The reply `{"stopping":true}` comes from the core thread once the
        // session is closed.
        "stop" => {
            if !shared.begin_stop(Some((conn.clone(), id.clone()))) {
                conn.fail(id, daemon_stopping());
            }
        }
        _ => conn.fail(id, RcError::new("usage", "Неизвестная команда.")),
    }
}

pub fn status(shared: &Shared) -> Value {
    let snapshot = shared.snapshot.borrow().clone();
    let clients: Vec<Value> = shared.connections().iter()
        .map(|conn| json!({"origin": conn.origin, "since_s": conn.since.elapsed().as_secs()}))
        .collect();
    let web = shared.web_info().is_some().then(|| web_status(shared));
    json!({
        "pid": std::process::id(),
        "version": VERSION,
        "protocol": PROTOCOL,
        "exe": shared.exe,
        "uptime_s": shared.started.elapsed().as_secs(),
        "persistent": shared.is_persistent(),
        "busy": shared.busy(),
        "clients": clients,
        "session": {"open": snapshot.open, "source": snapshot.source},
        "terminals": shared.terminals.running(),
        "web": web,
    })
}

// ─── web ─────────────────────────────────────────────────────────────────────

/// `web *` of a connection; `start` and `stop` wait for the listener.
pub async fn web(shared: Arc<Shared>, conn: Arc<Conn>, id: Value, invocation: Invocation) {
    let result = match invocation.verb.as_str() {
        "status" => Ok(web_status(&shared)),
        "start" => start(&shared, &invocation).await,
        "stop" => Ok(stop(&shared).await),
        "link" => link(&shared),
        _ => Err(RcError::new("usage", "Неизвестная команда.")),
    };
    match result {
        Ok(data) => conn.reply(&id, Envelope::success(data)),
        Err(error) => conn.fail(&id, error),
    }
}

/// `{"enabled","url","bind","port","tls","fingerprint","clients","open"}`.
pub fn web_status(shared: &Shared) -> Value {
    let Some(info) = shared.web_info() else {
        return json!({"enabled": false, "url": null, "bind": null, "port": null, "tls": false,
            "fingerprint": null, "clients": 0, "open": false});
    };
    let clients = shared.connections().iter().filter(|conn| conn.origin == Origin::Network).count();
    json!({
        "enabled": true,
        "url": info.url(),
        "bind": info.bind.to_string(),
        "port": info.port,
        "tls": info.tls,
        "fingerprint": info.fingerprint,
        "clients": clients,
        "open": !info.loopback() && !shared.snapshot.borrow().password_set,
    })
}

pub(super) async fn start(shared: &Arc<Shared>, invocation: &Invocation) -> Result<Value> {
    let plan = listener_plan(invocation)?;
    let mut slot = shared.web.lock().await;
    if slot.is_some() {
        return Err(RcError::new("conflict", "Веб-панель уже запущена."));
    }
    if shared.is_stopping() {
        return Err(daemon_stopping());
    }
    let started = open_listener(&plan, &shared.data_dir).await?;
    install(shared, &mut slot, started);
    drop(slot);
    Ok(web_status(shared))
}

/// Stops the listener: network connections are closed first (lines they
/// already sent are not executed), their terminals cancelled, then the
/// listener closes the sockets. `{"enabled":false}` either way.
pub async fn stop(shared: &Shared) -> Value {
    let mut slot = shared.web.lock().await;
    if let Some(listener) = slot.take() {
        *lock(&shared.web_info) = None;
        for conn in shared.connections().iter().filter(|conn| conn.origin == Origin::Network) {
            shared.disconnect(conn);
        }
        listener.stop().await;
    }
    json!({"enabled": false})
}

fn link(shared: &Shared) -> Result<Value> {
    let Some(info) = shared.web_info() else {
        return Err(RcError::new("not_configured", "Веб-панель не запущена: essence-rc web run."));
    };
    let url = info.url();
    if shared.snapshot.borrow().password_set {
        return Ok(json!({"url": format!("{url}/")}));
    }
    let ticket = lock(&shared.tokens).issue_ticket(Instant::now());
    let link = Zeroizing::new(format!("{url}/#ticket={}", ticket.as_str()));
    Ok(json!({"url": link.as_str(), "expires_in": super::access::TICKET_TTL.as_secs()}))
}

// ─── Listener flags ──────────────────────────────────────────────────────────

#[derive(Debug, PartialEq, Eq)]
enum TlsChoice {
    Off,
    Files { cert: PathBuf, key: PathBuf },
    SelfSigned,
}

/// What the listener flags ask for.
#[derive(Debug, PartialEq, Eq)]
pub struct ListenerPlan {
    bind: IpAddr,
    port: u16,
    tls: TlsChoice,
}

impl ListenerPlan {
    /// The `daemon run --web` flags that bring this listener back on
    /// `port` (a restart after `self update`); certificate paths absolute,
    /// as they were read.
    fn daemon_flags(&self, port: u16) -> Vec<String> {
        let mut flags = vec!["--bind".to_owned(), self.bind.to_string(), "--port".to_owned(), port.to_string()];
        match &self.tls {
            TlsChoice::Off if !self.bind.is_loopback() => flags.push("--no-tls".to_owned()),
            TlsChoice::Files { cert, key } => {
                for (flag, path) in [("--tls-cert", cert), ("--tls-key", key)] {
                    let path = std::path::absolute(path).unwrap_or_else(|_| path.clone());
                    flags.extend([flag.to_owned(), path.to_string_lossy().into_owned()]);
                }
            }
            TlsChoice::Off | TlsChoice::SelfSigned => {}
        }
        flags
    }
}

/// `--bind --port --tls-cert --tls-key --no-tls` of `web start`, `web run`
/// and `daemon run --web`.
pub fn listener_plan(invocation: &Invocation) -> Result<ListenerPlan> {
    let bind = match invocation.value("bind") {
        None => IpAddr::V4(Ipv4Addr::LOCALHOST),
        Some(text) => text.parse::<IpAddr>()
            .map_err(|_| RcError::new("invalid", "Адрес --bind должен быть IP-адресом."))?
            .to_canonical(),
    };
    let port = match invocation.value("port") {
        None => DEFAULT_PORT,
        Some(text) => text.parse::<u16>()
            .ok()
            .filter(|_| text.bytes().all(|byte| byte.is_ascii_digit()))
            .ok_or_else(|| RcError::new("invalid", "Порт --port должен быть числом от 0 до 65535."))?,
    };
    let files = match (invocation.value("tls-cert"), invocation.value("tls-key")) {
        (None, None) => None,
        (Some(cert), Some(key)) => Some((PathBuf::from(cert), PathBuf::from(key))),
        _ => return Err(RcError::new("usage", "Флаги --tls-cert и --tls-key задаются вместе.")),
    };
    let no_tls = invocation.has("no-tls");
    let tls = match files {
        Some(_) if no_tls => return Err(RcError::new("usage", "Флаг --no-tls несовместим с --tls-cert и --tls-key.")),
        Some((cert, key)) => TlsChoice::Files { cert, key },
        None if bind.is_loopback() || no_tls => TlsChoice::Off,
        None => TlsChoice::SelfSigned,
    };
    Ok(ListenerPlan { bind, port, tls })
}

/// `daemon run|start`: the listener flags need `--web`; `None` without it.
pub fn daemon_web_plan(invocation: &Invocation) -> Result<Option<ListenerPlan>> {
    if invocation.has("web") {
        return listener_plan(invocation).map(Some);
    }
    if ["bind", "port", "tls-cert", "tls-key", "no-tls"].iter().any(|flag| invocation.has(flag)) {
        return Err(RcError::new("usage", "Флаги веб-панели задаются вместе с --web."));
    }
    Ok(None)
}

fn read_pem(path: &Path) -> Result<Vec<u8>> {
    std::fs::read(path).map_err(|error| RcError::new("invalid", format!("Не удалось прочитать {}: {error}.", path.display())))
}

fn tls_material(plan: &ListenerPlan, data_dir: &Path) -> Result<Tls> {
    match &plan.tls {
        TlsChoice::Off => Ok(Tls::Off),
        TlsChoice::Files { cert, key } => Ok(Tls::Pem { cert: read_pem(cert)?, key: Zeroizing::new(read_pem(key)?) }),
        TlsChoice::SelfSigned => self_signed(plan.bind, &data_dir.join("web")),
    }
}

/// `<data>/web/cert.pem` and `key.pem`, made when absent or unreadable.
fn self_signed(bind: IpAddr, dir: &Path) -> Result<Tls> {
    let (cert_path, key_path) = (dir.join("cert.pem"), dir.join("key.pem"));
    if let (Ok(cert), Ok(key)) = (std::fs::read(&cert_path), std::fs::read(&key_path)) {
        let key = Zeroizing::new(key);
        if essence_rc_web::fingerprint(&cert).is_some() && !key.is_empty() {
            return Ok(Tls::Pem { cert, key });
        }
    }
    let mut names = vec!["localhost".to_owned(), "127.0.0.1".to_owned(), "::1".to_owned()];
    if !bind.is_unspecified() && !names.contains(&bind.to_string()) {
        names.push(bind.to_string());
    }
    let (cert, key) = essence_rc_web::self_signed(&names).map_err(|message| RcError::new("failed", message))?;
    let write = |path: &Path, bytes: &[u8]| {
        secure_fs::atomic_write(path, bytes)
            .map_err(|error| RcError::new("failed", format!("Не удалось записать {}: {error}.", path.display())))
    };
    secure_fs::create_dir_all(dir)
        .map_err(|error| RcError::new("failed", format!("Не удалось создать {}: {error}.", dir.display())))?;
    write(&key_path, key.as_bytes())?;
    write(&cert_path, cert.as_bytes())?;
    Ok(Tls::Pem { cert: cert.into_bytes(), key: Zeroizing::new(key.as_bytes().to_vec()) })
}

/// A started listener before the daemon adopts it.
pub struct Started {
    listener: Listener,
    info: WebInfo,
    accepted: mpsc::Receiver<Accepted>,
}

pub async fn open_listener(plan: &ListenerPlan, data_dir: &Path) -> Result<Started> {
    let tls = tls_material(plan, data_dir)?;
    let (sender, accepted) = mpsc::channel(ACCEPT_QUEUE);
    let listener = Listener::start(ListenerConfig { bind: plan.bind, port: plan.port, tls }, sender).await
        .map_err(|error| match error {
            ListenError::PortInUse(port) => RcError::new("port_in_use", error.to_string()).with_extra("port", port),
            ListenError::Tls(message) => RcError::new("invalid", message),
            ListenError::Io(_) => RcError::new("failed", error.to_string()),
        })?;
    let info = WebInfo {
        bind: plan.bind,
        port: listener.addr.port(),
        tls: listener.tls,
        fingerprint: listener.fingerprint.clone(),
        flags: plan.daemon_flags(listener.addr.port()),
    };
    Ok(Started { listener, info, accepted })
}

/// The daemon takes over a started listener: its connections are served
/// from now on, and an open panel is noted in the journal.
pub fn install(shared: &Arc<Shared>, slot: &mut Option<Listener>, started: Started) {
    let Started { listener, info, accepted } = started;
    if !info.loopback() && !shared.snapshot.borrow().password_set {
        eprintln!("  [!] {OPEN_PANEL_WARNING}");
    }
    let hello = conn::ListenerHello { loopback: info.loopback(), tls: info.tls };
    *lock(&shared.web_info) = Some(info);
    *slot = Some(listener);
    tokio::spawn(conn::accept_network(shared.clone(), accepted, hello));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan(words: &[&str]) -> Result<ListenerPlan> {
        let argv: Vec<String> = ["web", "start"].iter().chain(words).map(|word| (*word).to_owned()).collect();
        listener_plan(&rc_core::cli::parse(&argv).unwrap())
    }

    fn code(words: &[&str]) -> &'static str {
        plan(words).err().map_or("ok", |error| error.code)
    }

    #[test]
    fn listener_flags_choose_address_port_and_tls() {
        assert_eq!(plan(&[]).unwrap(), ListenerPlan { bind: IpAddr::V4(Ipv4Addr::LOCALHOST), port: DEFAULT_PORT, tls: TlsChoice::Off });
        let any = plan(&["--bind", "0.0.0.0", "--port", "0"]).unwrap();
        assert_eq!((any.port, &any.tls), (0, &TlsChoice::SelfSigned));
        assert_eq!(plan(&["--bind", "0.0.0.0", "--no-tls"]).unwrap().tls, TlsChoice::Off);
        assert_eq!(plan(&["--bind", "::1", "--port", "65535"]).unwrap().tls, TlsChoice::Off);
        // An IPv4-mapped loopback is loopback.
        let mapped = plan(&["--bind", "::ffff:127.0.0.1"]).unwrap();
        assert_eq!((mapped.bind, mapped.tls), (IpAddr::V4(Ipv4Addr::LOCALHOST), TlsChoice::Off));
        assert_eq!(plan(&["--tls-cert", "c.pem", "--tls-key", "k.pem"]).unwrap().tls,
            TlsChoice::Files { cert: "c.pem".into(), key: "k.pem".into() });
        for bad in [&["--bind", "localhost"][..], &["--bind", ""], &["--port", "65536"], &["--port", "-1"], &["--port", "+80"], &["--port", "x"]] {
            assert_eq!(code(bad), "invalid", "{bad:?}");
        }
        for bad in [&["--tls-cert", "c"][..], &["--tls-key", "k"], &["--tls-cert", "c", "--tls-key", "k", "--no-tls"]] {
            assert_eq!(code(bad), "usage", "{bad:?}");
        }
    }

    #[test]
    fn daemon_listener_flags_need_web() {
        let parse = |words: &[&str]| {
            let argv: Vec<String> = words.iter().map(|word| (*word).to_owned()).collect();
            daemon_web_plan(&rc_core::cli::parse_client(&argv).unwrap())
        };
        assert_eq!(parse(&["daemon", "run"]).unwrap(), None);
        assert_eq!(parse(&["daemon", "run", "--web", "--port", "0"]).unwrap().unwrap().port, 0);
        for flags in [&["--port", "1"][..], &["--bind", "::1"], &["--no-tls"], &["--tls-cert", "c", "--tls-key", "k"]] {
            let words: Vec<&str> = ["daemon", "start"].iter().chain(flags).copied().collect();
            assert_eq!(parse(&words).err().map(|error| error.code), Some("usage"), "{flags:?}");
        }
    }

    #[test]
    fn a_restart_gets_the_flags_of_the_running_listener() {
        assert_eq!(plan(&["--port", "0"]).unwrap().daemon_flags(41000), ["--bind", "127.0.0.1", "--port", "41000"]);
        assert_eq!(plan(&["--bind", "0.0.0.0", "--no-tls"]).unwrap().daemon_flags(8377),
            ["--bind", "0.0.0.0", "--port", "8377", "--no-tls"]);
        assert_eq!(plan(&["--bind", "0.0.0.0"]).unwrap().daemon_flags(8377), ["--bind", "0.0.0.0", "--port", "8377"]);
        let files = plan(&["--tls-cert", "c.pem", "--tls-key", "/k.pem"]).unwrap().daemon_flags(1);
        let cert = std::path::absolute("c.pem").unwrap();
        assert_eq!(files[4..], ["--tls-cert".to_owned(), cert.to_string_lossy().into_owned(), "--tls-key".to_owned(),
            std::path::absolute("/k.pem").unwrap().to_string_lossy().into_owned()]);
        // The flags parse back as a `daemon run --web` plan.
        let argv: Vec<String> = ["daemon", "run", "--web"].map(str::to_owned).into_iter().chain(files).collect();
        assert!(daemon_web_plan(&rc_core::cli::parse_client(&argv).unwrap()).unwrap().is_some());
    }

    #[test]
    fn urls_name_a_reachable_host() {
        let url = |bind: &str, tls: bool| WebInfo { bind: bind.parse().unwrap(), port: 8377, tls, fingerprint: None, flags: Vec::new() }.url();
        assert_eq!(url("127.0.0.1", false), "http://127.0.0.1:8377");
        assert_eq!(url("0.0.0.0", true), "https://127.0.0.1:8377");
        assert_eq!(url("192.0.2.7", true), "https://192.0.2.7:8377");
        assert_eq!(url("::1", false), "http://[::1]:8377");
        assert_eq!(url("::", true), "https://[::1]:8377");
        assert_eq!(url("2001:db8::7", true), "https://[2001:db8::7]:8377");
    }

    #[test]
    fn self_signed_material_is_made_once_and_reused() {
        let dir = tempfile::tempdir().unwrap();
        let web = dir.path().join("web");
        let Tls::Pem { cert, .. } = self_signed("192.0.2.7".parse().unwrap(), &web).unwrap() else { panic!() };
        let Tls::Pem { cert: again, .. } = self_signed("192.0.2.7".parse().unwrap(), &web).unwrap() else { panic!() };
        assert_eq!(cert, again, "reused");
        std::fs::write(web.join("cert.pem"), "garbage").unwrap();
        let Tls::Pem { cert: fresh, .. } = self_signed("0.0.0.0".parse().unwrap(), &web).unwrap() else { panic!() };
        assert_ne!(fresh, cert, "an unreadable certificate is replaced");
        assert!(essence_rc_web::fingerprint(&fresh).is_some());
    }
}
