//! WARP: script output, registration conditions, the `warp-wg` block.

use super::*;
use crate::model::{NodeParams, NodeWarp, Profile};

const PRIVATE: &str = "cGZhbHNlcHJpdmF0ZWtleXZhbHVlZm9yd2FycGxvY2Fs";
const PUBLIC: &str = "bmV0Y2xvdWRmbGFyZXB1YmxpY2tleXZhbHVlYWJjZGVm";

fn key(text: &str) -> String {
    format!("{}=", &text[..43])
}

#[test]
fn script_output_is_parsed_from_its_tail() {
    let out = format!("noise\nprivate_key={}\npublic_key={}\nipv4=172.16.0.2\nipv6=2606:4700:110:8a36::1\nplus=true\n", key(PRIVATE), key(PUBLIC));
    let registered = parse_output(&out).unwrap();
    assert_eq!((registered.private_key.as_str(), registered.public_key.as_str()), (key(PRIVATE).as_str(), key(PUBLIC).as_str()));
    assert_eq!((registered.ipv4.as_str(), registered.ipv6.as_deref(), registered.plus), ("172.16.0.2", Some("2606:4700:110:8a36::1"), true));
    let free = format!("private_key={}\npublic_key={}\nipv4=172.16.0.2\nipv6=\nplus=false\n", key(PRIVATE), key(PUBLIC));
    let registered = parse_output(&free).unwrap();
    assert!(registered.ipv6.is_none() && !registered.plus);
    for bad in [
        free.replace("ipv4=172.16.0.2", "ipv4=999.1.1.1"), free.replace("ipv6=\n", "ipv6=zz::\n"),
        free.replace(&key(PRIVATE), "short="), "plus=true\n".to_owned(),
    ] {
        assert!(parse_output(&bad).is_none(), "{bad}");
    }
    let command = register_command(true);
    assert!(command.starts_with("bash -c '") && command.ends_with(" essence-warp 1") && command.contains("2.3.0"));
    assert!(!command.contains("__WGCF_VERSION__"));
    assert!(register_command(false).ends_with(" essence-warp 0"));
}

#[test]
fn the_warp_plus_key_stays_out_of_argv_and_env_and_is_bound_on_any_account() {
    // wgcf reads `license_key` from its account file (viper config).
    assert!(!REGISTER.contains("WGCF_LICENSE_KEY") && !REGISTER.contains("--license-key") && !REGISTER.contains("new=1"));
    let umask = REGISTER.find("umask 077\n").unwrap();
    assert!(umask < REGISTER.find("mkdir -p /root/wgcf").unwrap());
}

/// The part of [`REGISTER`] from `start` up to (without) `end`.
#[cfg(unix)]
fn script_part(start: &str, end: &str) -> &'static str {
    let from = REGISTER.find(start).unwrap();
    &REGISTER[from..from + REGISTER[from..].find(end).unwrap()]
}

#[cfg(unix)]
fn bash(dir: &std::path::Path, script: &str, env: &[(&str, &str)]) -> std::process::Output {
    std::process::Command::new("bash").arg("-c").arg(script).current_dir(dir).envs(env.iter().copied()).output().unwrap()
}

#[cfg(unix)]
#[test]
fn the_license_reaches_wgcf_update_only_through_the_account_file() {
    use std::os::unix::fs::PermissionsExt;
    let block = script_part("if [[ -n \"$key\" ]]; then\n", "rm -f wgcf-profile.conf\n");
    let script = format!("set -u\numask 077\nkey='KEY-1'\nplus=false\nrestore() {{ echo restore-called >&2; }}\n{block}printf '%s' \"$plus\"\n");
    let account = "access_token = 'a'\nlicense_key = 'OLD'\nprivate_key = 'p'\n";
    // The fake wgcf fails when the key is in its argv or environment.
    let fake = "#!/bin/sh\n[ \"$*\" = update ] || exit 2\nenv | grep -q KEY-1 && exit 3\n\
        [ \"$(grep -c license_key wgcf-account.toml)\" = 1 ] && grep -qx \"license_key = 'KEY-1'\" wgcf-account.toml || exit 4\n\
        exit \"${FAKE_EXIT:-0}\"\n";
    for (exit, plus) in [("0", "true"), ("1", "false")] {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("wgcf"), fake).unwrap();
        std::fs::set_permissions(dir.path().join("wgcf"), std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(dir.path().join("wgcf-account.toml"), account).unwrap();
        let output = bash(dir.path(), &script, &[("FAKE_EXIT", exit)]);
        assert_eq!(String::from_utf8_lossy(&output.stdout), plus, "{}", String::from_utf8_lossy(&output.stderr));
        let file = dir.path().join("wgcf-account.toml");
        let saved = std::fs::read_to_string(&file).unwrap();
        if plus == "true" {
            assert_eq!(saved, "license_key = 'KEY-1'\naccess_token = 'a'\nprivate_key = 'p'\n");
            assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        } else {
            assert_eq!(saved, account, "a failed bind keeps the previous account file");
        }
        let names: Vec<_> = std::fs::read_dir(dir.path()).unwrap().map(|entry| entry.unwrap().file_name()).collect();
        assert_eq!(names.len(), 2, "{names:?}");
    }
    // Only moving the previous file back fails (a `mv` that refuses this one
    // move): the copy stays intact, the script fails and names it.
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("wgcf"), fake).unwrap();
    std::fs::set_permissions(dir.path().join("wgcf"), std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(dir.path().join("wgcf-account.toml"), account).unwrap();
    let failing = format!("mv() {{ [[ \"$2\" == wgcf-account.toml.prev ]] && return 1; command mv \"$@\"; }}\n{script}");
    let output = bash(dir.path(), &failing, &[("FAKE_EXIT", "1")]);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success() && output.stdout.is_empty(), "{output:?}");
    assert!(stderr.contains("Прежний файл аккаунта WARP не восстановлен: копия сохранена в ")
        && stderr.contains("/wgcf-account.toml.prev") && stderr.contains("restore-called"), "{stderr}");
    assert_eq!(std::fs::read_to_string(dir.path().join("wgcf-account.toml.prev")).unwrap(), account);
}

#[cfg(unix)]
#[test]
fn a_failed_restore_keeps_the_backup() {
    let function = script_part("restore() {\n", "if [[ \"$reregister\" == 1");
    let dir = tempfile::tempdir().unwrap();
    let backup = dir.path().join("backup");
    std::fs::create_dir(&backup).unwrap();
    std::fs::write(backup.join("wgcf-account.toml"), "old").unwrap();
    // A directory in the way: `cp` fails (as root too).
    let work = dir.path().join("work");
    std::fs::create_dir_all(work.join("wgcf-account.toml/x")).unwrap();
    let script = format!("backup={}\n{function}restore\n", sh_quote(backup.to_str().unwrap()));
    let output = bash(&work, &script, &[]);
    assert!(backup.join("wgcf-account.toml").exists());
    assert!(String::from_utf8_lossy(&output.stderr).contains("Откат аккаунта WARP не завершён"), "{output:?}");
    // A successful restore removes it.
    std::fs::remove_dir_all(work.join("wgcf-account.toml")).unwrap();
    bash(&work, &script, &[]);
    assert_eq!(std::fs::read_to_string(work.join("wgcf-account.toml")).unwrap(), "old");
    assert!(!backup.exists());
}

#[cfg(unix)]
#[test]
fn a_failed_save_keeps_the_previous_warp_key_and_parameters() {
    let root = tempfile::tempdir().unwrap();
    let (session, _) = crate::nodes::testing::session(root.path());
    let mut config = session.state.load_config().unwrap();
    let old = NodeWarp { public_key: key(PUBLIC), ..registered(false, None) };
    config.nodes = vec![Node {
        id: "a".repeat(32), name: "de".into(), ip: "198.51.100.7".into(), port: 22, user: "root".into(),
        ..node(Some(old.clone()))
    }];
    session.state.save_config(&config).unwrap();
    let id = "a".repeat(32);
    let secret = format!("node:{id}:warp-key");
    session.state.secret_store().set(&secret, Zeroizing::new(key(PRIVATE))).unwrap();
    let new = Registered {
        private_key: Zeroizing::new(key(PUBLIC)), public_key: key(PUBLIC), ipv4: "172.16.0.9".into(), ipv6: None, plus: true,
    };
    // The configuration stays readable but can no longer be replaced.
    let path = session.state.paths().config().to_path_buf();
    let real = path.with_extension("real");
    std::fs::rename(&path, &real).unwrap();
    std::os::unix::fs::symlink(&real, &path).unwrap();
    assert!(store(&session.state, &id, &new, None).is_err());
    assert_eq!(session.state.secret_store().get(&secret).unwrap().unwrap().as_str(), key(PRIVATE));
    assert_eq!(session.state.load_config().unwrap().nodes[0].params.warp, Some(old));
    std::fs::remove_file(&path).unwrap();
    std::fs::rename(&real, &path).unwrap();
    store(&session.state, &id, &new, Some("0123abcd".into())).unwrap();
    assert_eq!(session.state.secret_store().get(&secret).unwrap().unwrap().as_str(), key(PUBLIC));
    assert_eq!(session.state.load_config().unwrap().nodes[0].params.warp.as_ref().unwrap().ipv4, "172.16.0.9");
}

#[test]
fn the_reregister_plan_is_bound_to_the_node_and_its_warp_key() {
    let mut config = Config { profiles: vec![profile(true, None)], ..Config::default() };
    config.nodes = vec![Node {
        id: "a".repeat(32), name: "de".into(), ip: "198.51.100.7".into(), port: 22, user: "root".into(),
        profile: Some("main".into()), ..Node::default()
    }];
    let (plan, _) = reregister_plan(&config, "de").unwrap();
    let mut readded = config.clone();
    readded.nodes[0].id = "b".repeat(32);
    let mut moved = config.clone();
    moved.nodes[0].ip = "198.51.100.8".into();
    let mut keyed = config.clone();
    keyed.profiles[0].warp_plus = Some("0123abcd".into());
    for changed in [readded, moved, keyed] {
        let (other, _) = reregister_plan(&changed, "de").unwrap();
        assert_eq!(other.lines, plan.lines);
        assert_ne!(other.extra, plan.extra);
    }
    // Under the lock: the same plan passes, any other — or none — is `plan_changed`.
    let invocation = crate::nodes::testing::invocation(&["node", "warp-reregister", "--name", "de", "--yes"]);
    assert!(reregister_planned(&config, "de", &plan, &invocation).is_ok());
    let mut moved = config.clone();
    moved.nodes[0].port = 2222;
    let error = reregister_planned(&moved, "de", &plan, &invocation).unwrap_err();
    assert_eq!((error.code, error.extra["plan"].clone()), ("plan_changed", serde_json::json!(plan.lines)));
    let mut gone = config.clone();
    gone.nodes.clear();
    assert_eq!(reregister_planned(&gone, "de", &plan, &invocation).unwrap_err().code, "plan_changed");
    config.profiles[0].warp = false;
    assert_eq!(reregister_plan(&config, "de").unwrap_err().code, "invalid");
    let error = reregister_planned(&config, "de", &plan, &invocation).unwrap_err();
    assert_eq!(error.code, "plan_changed");
    assert!(error.message.ends_with("У профиля ноды «de» WARP выключен."), "{}", error.message);
}

#[test]
fn curl_is_installed_from_refreshed_package_lists() {
    // A fresh image ships stale lists: `install` alone gets 404 from the mirror.
    let update = REGISTER.find("apt-get -o DPkg::Lock::Timeout=300 update -q").unwrap();
    let install = REGISTER.find("apt-get -o DPkg::Lock::Timeout=300 install -y -q curl").unwrap();
    assert!(update < install);
}

fn profile(warp: bool, mark: Option<&str>) -> Profile {
    Profile { warp, warp_plus: mark.map(str::to_owned), ..crate::model::test_profile("main") }
}

fn node(warp: Option<NodeWarp>) -> Node {
    Node { params: NodeParams { warp, ..NodeParams::default() }, ..Node::default() }
}

fn registered(plus: bool, attempt: Option<&str>) -> NodeWarp {
    NodeWarp { public_key: "p".into(), ipv4: "172.16.0.2".into(), ipv6: None, plus, plus_attempt: attempt.map(str::to_owned) }
}

#[test]
fn registration_runs_first_and_again_only_for_a_new_key() {
    assert_eq!(registration(&profile(false, None), &node(None)), None);
    assert_eq!(registration(&profile(true, None), &node(None)), Some(false));
    assert_eq!(registration(&profile(true, Some("0123abcd")), &node(None)), Some(false));
    assert_eq!(registration(&profile(true, None), &node(Some(registered(false, None)))), None);
    assert_eq!(registration(&profile(true, Some("0123abcd")), &node(Some(registered(false, None)))), Some(true));
    assert_eq!(registration(&profile(true, Some("0123abcd")), &node(Some(registered(false, Some("0123abcd"))))), None,
        "the same key was already tried");
    assert_eq!(registration(&profile(true, Some("99999999")), &node(Some(registered(false, Some("0123abcd"))))), Some(true));
    assert_eq!(registration(&profile(true, Some("0123abcd")), &node(Some(registered(true, Some("11111111"))))), None);
    assert_eq!(plan_line(false), "WARP: будет зарегистрирован аккаунт Cloudflare.");
    assert_eq!(plan_line(true), "WARP: аккаунт будет перерегистрирован для привязки WARP+.");
}

#[test]
fn warp_block_with_and_without_ipv6() {
    let mut warp = registered(false, None);
    assert_eq!(warp_block(&warp, "PRIV"), "  - name: warp-wg\n    type: wireguard\n    private-key: \"PRIV\"\n    server: engage.cloudflareclient.com\n\
        \x20   port: 2408\n    ip: 172.16.0.2\n    public-key: \"p\"\n    allowed-ips: ['0.0.0.0/0']\n    udp: true\n    mtu: 1280\n");
    warp.ipv6 = Some("2606::1".into());
    assert!(warp_block(&warp, "PRIV").contains("    ip: 172.16.0.2\n    ipv6: 2606::1\n    public-key: \"p\"\n    allowed-ips: ['0.0.0.0/0', '::/0']\n"));
}
