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
