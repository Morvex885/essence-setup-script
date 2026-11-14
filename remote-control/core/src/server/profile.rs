//! `profile list|show|add|set|delete|warp-license`: node profiles, the
//! desired server setup shared by nodes.

use std::collections::BTreeMap;

use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::model::{
    AmneziaWg, Config, Hysteria2, Ipv6, PortOnly, Profile, RealityMode, SiteSource, Xhttp, XhttpTopology,
    default_awg_dns,
};
use crate::nodes::required;
use crate::request_secrets::Secrets;
use crate::validation as v;

use super::keys::{ensure_generated, hex, uniform};
use super::ports::RESERVED_PORTS;

const MIHOMO_LATEST: &str = "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest";

pub async fn route(verb: &str, invocation: &Invocation, secrets: &Secrets, session: &mut Session) -> Result<Value> {
    match verb {
        "list" => list(session),
        "show" => show(session, invocation),
        "add" => add(session, invocation).await,
        "set" => set(session, invocation),
        "delete" => delete(session, invocation),
        "warp-license" => warp_license(session, invocation, secrets),
        _ => Err(RcError::new("usage", "Неизвестная команда.")),
    }
}

fn not_found(name: &str) -> RcError {
    RcError::new("not_found", format!("Профиль «{name}» не найден.")).with_extra("name", name)
}

fn find<'a>(config: &'a Config, name: &str) -> Result<&'a Profile> {
    config.find_profile(name).ok_or_else(|| not_found(name))
}

fn nodes_of(config: &Config, name: &str) -> Vec<String> {
    config.nodes.iter().filter(|node| node.profile.as_deref() == Some(name)).map(|node| node.name.clone()).collect()
}

/// Every profile field, its nodes and whether a WARP+ license is set.
fn view(config: &Config, profile: &Profile) -> Value {
    let mut value = serde_json::to_value(profile).unwrap_or(Value::Null);
    if let Some(object) = value.as_object_mut() {
        object.insert("warp_plus".into(), json!(profile.warp_plus.is_some()));
        object.insert("nodes".into(), json!(nodes_of(config, &profile.name)));
    }
    value
}

fn list(session: &mut Session) -> Result<Value> {
    let config = session.state.load_config()?;
    Ok(json!({"profiles": config.profiles.iter().map(|profile| view(&config, profile)).collect::<Vec<_>>()}))
}

fn show(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let config = session.state.load_config()?;
    Ok(view(&config, find(&config, required(invocation, "name")?)?))
}

fn usage(message: String) -> RcError { RcError::new("usage", message) }

fn on_off(invocation: &Invocation, flag: &str) -> Result<Option<bool>> {
    match invocation.value(flag) {
        None => Ok(None),
        Some("on") => Ok(Some(true)),
        Some("off") => Ok(Some(false)),
        Some(_) => Err(usage(format!("Флаг --{flag} принимает on или off."))),
    }
}

fn port_flag(invocation: &Invocation, flag: &str) -> Result<Option<u16>> {
    invocation.value(flag).map(v::parse_ssh_port).transpose()
}

/// A random port in `low..=high` free in the profile and not reserved.
fn random_port(profile: &Profile, low: u32, high: u32) -> Result<u16> {
    let (tcp, udp) = profile.listen_ports(&BTreeMap::new());
    loop {
        let port = u16::try_from(uniform(low, high)?).unwrap_or(0);
        if port != 0 && !RESERVED_PORTS.contains(&port) && !tcp.iter().chain(&udp).any(|(_, used)| *used == port) {
            return Ok(port);
        }
    }
}

/// `user<8 hex>@<6 hex>.com`, as `acme_select_email`.
fn random_email() -> Result<String> {
    Ok(format!("user{}@{}.com", hex(8)?, hex(6)?))
}

/// Apply the profile flags of `profile add|set`; only given flags change.
/// Protocols switched on without a port get a random free one.
fn apply_flags(profile: &mut Profile, invocation: &Invocation) -> Result<()> {
    match (invocation.value("acme-email"), invocation.has("random-acme-email")) {
        (Some(_), true) => return Err(usage("Укажите только один из флагов --acme-email и --random-acme-email.".into())),
        (Some(email), false) => profile.acme_email = email.to_owned(),
        (None, true) => profile.acme_email = random_email()?,
        (None, false) => {}
    }
    match invocation.value("reality") {
        None => {}
        Some("self-steal") => {
            profile.reality_mode = RealityMode::SelfSteal;
            profile.sni_domain = None;
        }
        Some("sni") => profile.reality_mode = RealityMode::Sni,
        Some(_) => return Err(usage("Флаг --reality принимает self-steal или sni.".into())),
    }
    if let Some(domain) = invocation.value("sni-domain") {
        profile.sni_domain = (!domain.is_empty()).then(|| domain.to_owned());
    }
    match invocation.value("site-source") {
        None => {}
        Some("simple") => profile.site_source = SiteSource::Simple,
        Some("sni") => profile.site_source = SiteSource::Sni,
        Some("nothing") => profile.site_source = SiteSource::Nothing,
        Some("random") => profile.site_source = SiteSource::Random,
        Some(_) => return Err(usage("Флаг --site-source принимает simple, sni, nothing или random.".into())),
    }
    if let Some(version) = invocation.value("mihomo-version") {
        profile.mihomo_version = version.to_owned();
    }
    if let Some(on) = on_off(invocation, "vless-tcp")? {
        profile.vless_tcp = on;
    }
    match invocation.value("xhttp") {
        None => {}
        Some("off") => profile.vless_xhttp = None,
        Some("nginx") => profile.vless_xhttp = Some(Xhttp { topology: XhttpTopology::Nginx, port: None }),
        Some("reality") => {
            let port = profile.vless_xhttp.as_ref().filter(|x| x.topology == XhttpTopology::Reality).and_then(|x| x.port);
            profile.vless_xhttp = Some(Xhttp { topology: XhttpTopology::Reality, port });
        }
        Some(_) => return Err(usage("Флаг --xhttp принимает off, reality или nginx.".into())),
    }
    if let Some(on) = on_off(invocation, "grpc")? {
        if !on {
            profile.vless_grpc = None;
        } else if profile.vless_grpc.is_none() {
            profile.vless_grpc = Some(PortOnly { port: 0 });
        }
    }
    if let Some(on) = on_off(invocation, "hysteria2")? {
        if !on {
            profile.hysteria2 = None;
        } else if profile.hysteria2.is_none() {
            profile.hysteria2 = Some(Hysteria2 { port: 0, obfs: false });
        }
    }
    if let Some(on) = on_off(invocation, "amneziawg")? {
        if !on {
            profile.amneziawg = None;
        } else if profile.amneziawg.is_none() {
            profile.amneziawg = Some(AmneziaWg { port: 0, dns: default_awg_dns() });
        }
    }
    if let Some(on) = on_off(invocation, "warp")? {
        profile.warp = on;
    }
    match invocation.value("ipv6") {
        None => {}
        Some("default") => profile.ipv6 = Ipv6::Default,
        Some("enabled") => profile.ipv6 = Ipv6::Enabled,
        Some("disabled") => profile.ipv6 = Ipv6::Disabled,
        Some(_) => return Err(usage("Флаг --ipv6 принимает default, enabled или disabled.".into())),
    }
    let disabled = |flag: &str| usage(format!("Флаг --{flag} задаётся только для включённого протокола."));
    if let Some(port) = port_flag(invocation, "xhttp-port")? {
        match profile.vless_xhttp.as_mut() {
            Some(xhttp) if xhttp.topology == XhttpTopology::Reality => xhttp.port = Some(port),
            _ => return Err(usage("Флаг --xhttp-port задаётся только для --xhttp reality.".into())),
        }
    }
    if let Some(port) = port_flag(invocation, "grpc-port")? {
        profile.vless_grpc.as_mut().ok_or_else(|| disabled("grpc-port"))?.port = port;
    }
    if let Some(port) = port_flag(invocation, "hysteria2-port")? {
        profile.hysteria2.as_mut().ok_or_else(|| disabled("hysteria2-port"))?.port = port;
    }
    if let Some(on) = on_off(invocation, "hysteria2-obfs")? {
        profile.hysteria2.as_mut().ok_or_else(|| disabled("hysteria2-obfs"))?.obfs = on;
    }
    if let Some(port) = port_flag(invocation, "amneziawg-port")? {
        profile.amneziawg.as_mut().ok_or_else(|| disabled("amneziawg-port"))?.port = port;
    }
    if let Some(dns) = invocation.value("amneziawg-dns") {
        let awg = profile.amneziawg.as_mut().ok_or_else(|| disabled("amneziawg-dns"))?;
        awg.dns = if dns.is_empty() { default_awg_dns() } else { dns.to_owned() };
    }
    // Ports of protocols switched on without one.
    if profile.vless_xhttp.as_ref().is_some_and(|x| x.topology == XhttpTopology::Reality && x.port.is_none())
        && invocation.value("xhttp") == Some("reality")
    {
        let port = random_port(profile, 10000, 65535)?;
        if let Some(xhttp) = profile.vless_xhttp.as_mut() { xhttp.port = Some(port); }
    }
    if profile.vless_grpc.as_ref().is_some_and(|grpc| grpc.port == 0) {
        let port = random_port(profile, 10000, 65535)?;
        if let Some(grpc) = profile.vless_grpc.as_mut() { grpc.port = port; }
    }
    if profile.hysteria2.as_ref().is_some_and(|hy2| hy2.port == 0) {
        let port = random_port(profile, 10000, 65535)?;
        if let Some(hy2) = profile.hysteria2.as_mut() { hy2.port = port; }
    }
    if profile.amneziawg.as_ref().is_some_and(|awg| awg.port == 0) {
        let port = random_port(profile, 30000, 50000)?;
        if let Some(awg) = profile.amneziawg.as_mut() { awg.port = port; }
    }
    Ok(())
}

/// `tag_name` of the latest mihomo release.
async fn latest_mihomo() -> Result<String> {
    let failed = || RcError::new("failed", "Не удалось получить последнюю версию mihomo: укажите --mihomo-version.");
    let client = crate::self_manage::metadata_client().map_err(|_| failed())?;
    let response = client.get(MIHOMO_LATEST).send().await.and_then(reqwest::Response::error_for_status).map_err(|_| failed())?;
    let body: Value = response.json().await.map_err(|_| failed())?;
    body.get("tag_name").and_then(Value::as_str).map(str::to_owned).ok_or_else(failed)
}

fn exists(name: &str) -> RcError {
    RcError::new("exists", format!("Профиль «{name}» уже существует.")).with_extra("name", name)
}

async fn add(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    if invocation.has("acme-email") == invocation.has("random-acme-email") {
        return Err(usage("Укажите ровно один из флагов: --acme-email | --random-acme-email.".into()));
    }
    if !v::name_valid(&name) {
        return Err(RcError::new("invalid", format!("Недопустимое имя профиля «{name}»: латиница, цифры, «.», «_», «-».")));
    }
    if session.state.load_config()?.find_profile(&name).is_some() {
        return Err(exists(&name));
    }
    let mut profile = Profile { name: name.clone(), site_source: SiteSource::Random, vless_tcp: true, ..Profile::default() };
    apply_flags(&mut profile, invocation)?;
    if !invocation.has("mihomo-version") {
        profile.mihomo_version = latest_mihomo().await?;
    }
    profile.validate()?;
    let saved = profile.clone();
    session.mutate("profile add", |state| {
        let mut config = state.load_config()?;
        if config.find_profile(&name).is_some() {
            return Err(exists(&name));
        }
        config.profiles.push(saved);
        ensure_generated(state, &mut config)?;
        state.save_config(&config)
    })?;
    session.log(Level::Success, &format!("Профиль «{name}» добавлен"));
    Ok(view(&session.state.load_config()?, &profile))
}

fn set(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let profile = session.mutate("profile set", |state| {
        let mut config = state.load_config()?;
        let profile = config.profiles.iter_mut().find(|profile| profile.name == name).ok_or_else(|| not_found(&name))?;
        apply_flags(profile, invocation)?;
        profile.validate()?;
        let profile = profile.clone();
        ensure_generated(state, &mut config)?;
        state.save_config(&config)?;
        Ok(profile)
    })?;
    let config = session.state.load_config()?;
    let pending = nodes_of(&config, &name);
    session.log(Level::Success, &format!("Профиль «{name}» сохранён"));
    if !pending.is_empty() {
        session.log(Level::Info, &format!("Примените изменения на нодах: node apply --profile {name}"));
    }
    Ok(view(&config, &profile))
}

fn in_use(name: &str, nodes: Vec<String>) -> RcError {
    RcError::new("in_use", format!("Профиль «{name}» назначен нодам: {}.", nodes.join(", ")))
        .with_extra("name", name).with_extra("nodes", nodes)
}

fn delete(session: &mut Session, invocation: &Invocation) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    let config = session.state.load_config()?;
    find(&config, &name)?;
    let nodes = nodes_of(&config, &name);
    if !nodes.is_empty() {
        return Err(in_use(&name, nodes));
    }
    Plan::new(vec![format!("Профиль «{name}» будет удалён.")], "").confirm(invocation)?;
    session.mutate("profile delete", |state| {
        let mut config = state.load_config()?;
        find(&config, &name)?;
        let nodes = nodes_of(&config, &name);
        if !nodes.is_empty() {
            return Err(in_use(&name, nodes));
        }
        config.profiles.retain(|profile| profile.name != name);
        state.save_config(&config)?;
        state.secret_store().remove(&format!("profile:{name}:warp-license"))
    })?;
    session.log(Level::Success, &format!("Профиль «{name}» удалён"));
    Ok(json!({"name": name}))
}

/// `profile warp-license --name P [--clear]`: the WARP+ license (secret
/// `password`) of the profile; its mark changes on every new key.
fn warp_license(session: &mut Session, invocation: &Invocation, secrets: &Secrets) -> Result<Value> {
    let name = required(invocation, "name")?.to_owned();
    find(&session.state.load_config()?, &name)?;
    let clear = invocation.has("clear");
    let license = if clear {
        None
    } else {
        let key = secrets.get("password").filter(|key| !key.is_empty()).ok_or_else(|| {
            RcError::new("missing_secret", "Не передан ключ WARP+ (секрет password).")
                .with_extra("name", name.clone()).with_extra("secret", "password")
        })?;
        if !v::warp_license_valid(key) {
            return Err(RcError::new("invalid", "Ключ WARP+ состоит из латинских букв, цифр и дефисов (до 64 символов)."));
        }
        Some(Zeroizing::new(key.to_owned()))
    };
    let mark = if clear { None } else { Some(hex(8)?) };
    let id = format!("profile:{name}:warp-license");
    session.mutate("profile warp-license", |state| {
        let mut config = state.load_config()?;
        let profile = config.profiles.iter_mut().find(|profile| profile.name == name).ok_or_else(|| not_found(&name))?;
        profile.warp_plus = mark.clone();
        match license {
            Some(license) => state.secret_store().set(&id, license)?,
            None => state.secret_store().remove(&id)?,
        }
        state.save_config(&config)
    })?;
    session.log(Level::Success, &if clear { format!("Ключ WARP+ профиля «{name}» удалён") } else { format!("Ключ WARP+ профиля «{name}» сохранён") });
    Ok(json!({"name": name, "warp_plus": !clear}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Node;
    use crate::nodes::testing::{fingerprint, invocation, session};

    fn run(session: &mut Session, argv: &[&str]) -> Result<Value> {
        let invocation = invocation(argv);
        let secrets = Secrets::default();
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap()
            .block_on(route(&invocation.verb.clone(), &invocation, &secrets, session))
    }

    const ADD: &[&str] = &["profile", "add", "--name", "edge", "--acme-email", "admin@example.com", "--mihomo-version", "v1.19.18"];

    #[test]
    fn add_applies_defaults_and_random_ports() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = session(root.path());
        let mut argv = ADD.to_vec();
        argv.extend(["--grpc", "on", "--hysteria2", "on", "--hysteria2-obfs", "on", "--amneziawg", "on", "--xhttp", "reality"]);
        let data = run(&mut session, &argv).unwrap();
        assert_eq!((data["name"].clone(), data["site_source"].clone(), data["vless_tcp"].clone(), data["ipv6"].clone()),
            (json!("edge"), json!("random"), json!(true), json!("default")));
        assert_eq!((data["warp_plus"].clone(), data["nodes"].clone(), data["reality_mode"].clone()), (json!(false), json!([]), json!("self-steal")));
        let config = session.state.load_config().unwrap();
        let profile = &config.profiles[0];
        let grpc = profile.vless_grpc.as_ref().unwrap().port;
        let hy2 = profile.hysteria2.as_ref().unwrap();
        let awg = profile.amneziawg.as_ref().unwrap();
        let xhttp = profile.vless_xhttp.as_ref().unwrap().port.unwrap();
        assert!(grpc >= 10000 && hy2.port >= 10000 && xhttp >= 10000 && hy2.obfs);
        assert!((30000..=50000).contains(&awg.port) && awg.dns == "1.1.1.1, 1.0.0.1");
        assert_eq!(run(&mut session, ADD).unwrap_err().code, "exists");
        let list = run(&mut session, &["profile", "list"]).unwrap();
        assert_eq!(list["profiles"][0]["name"], "edge");
    }

    #[test]
    fn add_validates_before_any_change() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = session(root.path());
        let before = fingerprint(root.path());
        for (argv, code) in [
            (&["profile", "add", "--name", "e", "--mihomo-version", "v1.19.18"][..], "usage"),
            (&["profile", "add", "--name", "e", "--acme-email", "a@b.co", "--random-acme-email", "--mihomo-version", "v1.19.18"], "usage"),
            (&["profile", "add", "--name", "e", "--acme-email", "a@b.co", "--mihomo-version", "v1.19.17"], "invalid"),
            (&["profile", "add", "--name", "e", "--acme-email", "a@b.co", "--mihomo-version", "v1.19.18", "--reality", "sni"], "invalid"),
            (&["profile", "add", "--name", "e", "--acme-email", "a@b.co", "--mihomo-version", "v1.19.18", "--grpc", "maybe"], "usage"),
            (&["profile", "add", "--name", "e", "--acme-email", "a@b.co", "--mihomo-version", "v1.19.18", "--grpc-port", "2053"], "usage"),
            (&["profile", "add", "--name", "e", "--acme-email", "a@b.co", "--mihomo-version", "v1.19.18", "--hysteria2", "on", "--hysteria2-port", "8443"], "invalid"),
            (&["profile", "add", "--name", "bad name", "--acme-email", "a@b.co", "--mihomo-version", "v1.19.18"], "invalid"),
        ] {
            assert_eq!(run(&mut session, argv).unwrap_err().code, code, "{argv:?}");
        }
        assert_eq!(fingerprint(root.path()), before);
        let data = run(&mut session, &["profile", "add", "--name", "r", "--random-acme-email", "--mihomo-version", "v1.20.0"]).unwrap();
        let email = data["acme_email"].as_str().unwrap();
        assert!(email.starts_with("user") && email.ends_with(".com") && v::acme_email_valid(email) && email.len() == "user12345678@123456.com".len());
    }

    #[test]
    fn set_changes_only_given_fields_and_delete_needs_no_nodes() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = session(root.path());
        run(&mut session, ADD).unwrap();
        let data = run(&mut session, &["profile", "set", "--name", "edge", "--reality", "sni", "--sni-domain", "www.example.org"]).unwrap();
        assert_eq!((data["reality_mode"].clone(), data["sni_domain"].clone(), data["acme_email"].clone()),
            (json!("sni"), json!("www.example.org"), json!("admin@example.com")));
        assert_eq!(run(&mut session, &["profile", "set", "--name", "edge", "--xhttp", "nginx"]).unwrap_err().code, "invalid");
        let data = run(&mut session, &["profile", "set", "--name", "edge", "--reality", "self-steal"]).unwrap();
        assert!(data.get("sni_domain").is_none());
        assert_eq!(run(&mut session, &["profile", "set", "--name", "ghost"]).unwrap_err().code, "not_found");

        session.mutate("t", |state| {
            let mut config = state.load_config()?;
            config.nodes.push(Node { id: "a".repeat(32), name: "de".into(), ip: "192.0.2.1".into(), port: 22, user: "root".into(),
                profile: Some("edge".into()), domain: Some("de.example.com".into()), ..Node::default() });
            state.save_config(&config)
        }).unwrap();
        let error = run(&mut session, &["profile", "delete", "--name", "edge", "--yes"]).unwrap_err();
        assert_eq!((error.code, error.extra["nodes"].clone()), ("in_use", json!(["de"])));
        assert_eq!(run(&mut session, &["profile", "show", "--name", "edge"]).unwrap()["nodes"], json!(["de"]));
        session.mutate("t", |state| {
            let mut config = state.load_config()?;
            config.nodes.clear();
            state.save_config(&config)
        }).unwrap();
        assert_eq!(run(&mut session, &["profile", "delete", "--name", "edge"]).unwrap_err().code, "confirmation_required");
        run(&mut session, &["profile", "delete", "--name", "edge", "--yes"]).unwrap();
        assert!(session.state.load_config().unwrap().profiles.is_empty());
    }

    #[test]
    fn warp_license_is_a_profile_secret_with_a_mark() {
        let root = tempfile::tempdir().unwrap();
        let (mut session, _) = session(root.path());
        run(&mut session, ADD).unwrap();
        let invocation = invocation(&["profile", "warp-license", "--name", "edge"]);
        assert_eq!(warp_license(&mut session, &invocation, &Secrets::default()).unwrap_err().code, "missing_secret");
        let secrets = Secrets::from_json(r#"{"password":"abc-123"}"#).unwrap();
        assert_eq!(warp_license(&mut session, &invocation, &secrets).unwrap(), json!({"name": "edge", "warp_plus": true}));
        let mark = session.state.load_config().unwrap().profiles[0].warp_plus.clone().unwrap();
        assert_eq!(mark.len(), 8);
        assert_eq!(session.state.secret_store().get("profile:edge:warp-license").unwrap().unwrap().as_str(), "abc-123");
        let clear = crate::nodes::testing::invocation(&["profile", "warp-license", "--name", "edge", "--clear"]);
        warp_license(&mut session, &clear, &Secrets::default()).unwrap();
        assert!(session.state.load_config().unwrap().profiles[0].warp_plus.is_none());
        assert!(session.state.secret_store().get("profile:edge:warp-license").unwrap().is_none());
    }
}
