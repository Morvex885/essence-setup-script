//! `cascade list|add|delete`.

use super::*;
use crate::model::{Client, ClientConnection, Connection, ConnectionGroup, Hysteria2, Node, Profile, test_profile};
use crate::nodes::testing::{fingerprint, invocation, session};

fn run(session: &mut Session, argv: &[&str], file: Option<&str>) -> Result<Value> {
    let invocation = invocation(argv);
    let mut input = Input::default();
    if let Some(text) = file {
        input.insert("file", zeroize::Zeroizing::new(text.to_owned())).unwrap();
    }
    route(&invocation.verb.clone(), &invocation, &input, session)
}

fn node(id: char, name: &str, profile: Option<&str>) -> Node {
    Node {
        id: id.to_string().repeat(32), name: name.into(), ip: "198.51.100.7".into(), port: 22, user: "root".into(),
        profile: profile.map(str::to_owned), domain: Some(format!("{name}.example.com")), ..Node::default()
    }
}

/// `de` and `nl` on profile `main` (VLESS TCP, Hysteria2), `bare` without a
/// profile; client `alpha` and group PC use `hop` on `de`.
fn setup(root: &std::path::Path) -> Session {
    let (session, _) = session(root);
    let mut config = session.state.load_config().unwrap();
    config.profiles = vec![Profile { hysteria2: Some(Hysteria2 { port: 20443, obfs: false }), ..test_profile("main") }];
    config.nodes = vec![node('a', "de", Some("main")), node('b', "nl", Some("main")), node('c', "bare", None)];
    config.clients = vec![Client {
        name: "alpha".into(), group: "PC".into(),
        connections: Some(vec![ClientConnection { node: "de".into(), proxies: vec!["VLESS TCP".into(), "hop".into()] }]),
        ..Client::default()
    }];
    config.connections = vec![Connection { node: "de".into(), groups: vec![ConnectionGroup {
        name: "PC".into(), proxies: vec!["VLESS TCP".into(), "hop".into()],
    }] }];
    crate::server::keys::ensure_generated(&session.state, &mut config).unwrap();
    session.state.save_config(&config).unwrap();
    session
}

const ADD: &[&str] = &["cascade", "add", "--name", "hop", "--entry", "de", "--listener", "vless-tcp"];

fn with(extra: &[&'static str]) -> Vec<&'static str> {
    [ADD, extra].concat()
}

#[test]
fn add_through_a_node_lists_without_secrets() {
    let root = tempfile::tempdir().unwrap();
    let mut session = setup(root.path());
    let data = run(&mut session, &with(&["--exit-node", "nl", "--exit-proxy", "Hysteria2"]), None).unwrap();
    assert_eq!(data, json!({"name": "hop", "entry": "de", "listener": "vless-tcp", "exit": {"node": "nl", "proxy": "Hysteria2"}}));
    let config = session.state.load_config().unwrap();
    let cascade = &config.cascades[0];
    assert!(v::vless_uuid_valid(&cascade.uuid) && v::hy2_password_valid(&cascade.password));
    assert_eq!(render::proxies(&config, &config.nodes[0]), ["VLESS TCP", "Hysteria2", "hop"]);
    assert_eq!(run(&mut session, &["cascade", "list"], None).unwrap(), json!({"cascades": [data]}));
    assert_eq!(run(&mut session, &with(&["--exit-node", "nl", "--exit-proxy", "Hysteria2"]), None).unwrap_err().code, "exists");
}

#[test]
fn add_through_an_external_uri_keeps_the_first_line() {
    let root = tempfile::tempdir().unwrap();
    let mut session = setup(root.path());
    let uri = "hysteria2://secret@203.0.113.5:443?sni=exit.example.com#exit";
    // The client reads `--file` into the `file` input.
    let data = run(&mut session, ADD, Some(&format!("{uri}\r\nignored\n"))).unwrap();
    assert_eq!(data["exit"], json!({"uri": true}));
    let config = session.state.load_config().unwrap();
    assert!(matches!(&config.cascades[0].exit, CascadeExit::Uri(exit) if exit.uri == uri));
    assert!(!serde_json::to_string(&run(&mut session, &["cascade", "list"], None).unwrap()).unwrap().contains("secret"));
}

#[test]
fn add_refuses_reserved_names_and_client_user_clashes() {
    let root = tempfile::tempdir().unwrap();
    let mut session = setup(root.path());
    let exit = ["--exit-node", "nl", "--exit-proxy", "VLESS TCP"];
    let before = fingerprint(root.path());
    for name in ["DIRECT", "REJECT", "GLOBAL", "outbound", "warp-wg", "hop-outbound", "awg-hop", "a--b", "AWG"] {
        let argv = [&["cascade", "add", "--name", name, "--entry", "de", "--listener", "vless-tcp"][..], &exit].concat();
        let error = run(&mut session, &argv, None).unwrap_err();
        assert_eq!((error.code, error.extra["name"].clone()), ("invalid", json!(name)), "{name}");
    }
    assert_eq!(fingerprint(root.path()), before);
    // A client `beta--hop` would share the listener user of `beta` through `hop`.
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.clients.push(Client { name: "beta--hop".into(), group: "PC".into(), ..Client::default() });
        state.save_config(&config)
    }).unwrap();
    let error = run(&mut session, &with(&exit), None).unwrap_err();
    assert_eq!((error.code, error.extra["name"].clone()), ("invalid", json!("beta--hop")));
    // With the cascade in place such a client cannot be saved either.
    session.mutate("t", |state| {
        let mut config = state.load_config()?;
        config.clients.retain(|client| client.name != "beta--hop");
        state.save_config(&config)
    }).unwrap();
    run(&mut session, &with(&exit), None).unwrap();
    let mut config = session.state.load_config().unwrap();
    config.clients.push(Client { name: "cascade--hop".into(), group: "PC".into(), ..Client::default() });
    let error = session.state.save_config(&config).unwrap_err();
    assert_eq!((error.code, error.message.as_str()), ("invalid", "Имя клиента «cascade--hop» совпадает с пользователем каскада «hop»."));
}

#[test]
fn add_validates_before_any_change() {
    let root = tempfile::tempdir().unwrap();
    let mut session = setup(root.path());
    let before = fingerprint(root.path());
    let exit = ["--exit-node", "nl", "--exit-proxy", "VLESS TCP"];
    let cases: Vec<(Vec<&str>, Option<&str>, &str)> = vec![
        (ADD.to_vec(), None, "usage"),
        (with(&["--exit-node", "nl"]), None, "usage"),
        (with(&["--exit-node", "nl", "--exit-proxy", "VLESS TCP"]), Some("vless://x"), "usage"),
        (with(&["--exit-node", "nl", "--exit-proxy", "AWG"]), None, "usage"),
        ([&["cascade", "add", "--name", "hop", "--entry", "de", "--listener", "awg"][..], &exit].concat(), None, "usage"),
        ([&["cascade", "add", "--name", "VLESS TCP", "--entry", "de", "--listener", "vless-tcp"][..], &exit].concat(), None, "invalid"),
        ([&["cascade", "add", "--name", "../x", "--entry", "de", "--listener", "vless-tcp"][..], &exit].concat(), None, "invalid"),
        ([&["cascade", "add", "--name", "hop", "--entry", "ghost", "--listener", "vless-tcp"][..], &exit].concat(), None, "not_found"),
        ([&["cascade", "add", "--name", "hop", "--entry", "bare", "--listener", "vless-tcp"][..], &exit].concat(), None, "invalid"),
        ([&["cascade", "add", "--name", "hop", "--entry", "de", "--listener", "vless-grpc"][..], &exit].concat(), None, "invalid"),
        (with(&["--exit-node", "de", "--exit-proxy", "VLESS TCP"]), None, "invalid"),
        (with(&["--exit-node", "nl", "--exit-proxy", "VLESS gRPC"]), None, "invalid"),
        (with(&["--exit-node", "bare", "--exit-proxy", "VLESS TCP"]), None, "invalid"),
        (ADD.to_vec(), Some("ftp://example.com"), "invalid"),
        (ADD.to_vec(), Some("vless://aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee@203.0.113.5:443?type=ws"), "invalid"),
        // Decoded fields must match their formats: no YAML-breaking flow or key, a numeric port.
        (ADD.to_vec(), Some("vless://aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee@203.0.113.5:443?flow=x%3A%20y&pbk=k%20%23c"), "invalid"),
        (ADD.to_vec(), Some("vless://aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee@203.0.113.5:notaport"), "invalid"),
    ];
    for (argv, file, code) in cases {
        assert_eq!(run(&mut session, &argv, file).unwrap_err().code, code, "{argv:?}");
    }
    assert_eq!(fingerprint(root.path()), before);
}

#[test]
fn delete_is_gated_and_removes_the_assignments() {
    let root = tempfile::tempdir().unwrap();
    let mut session = setup(root.path());
    run(&mut session, &with(&["--exit-node", "nl", "--exit-proxy", "VLESS TCP"]), None).unwrap();
    let before = fingerprint(root.path());
    let error = run(&mut session, &["cascade", "delete", "--name", "hop"], None).unwrap_err();
    assert_eq!((error.code, error.extra["plan"].clone()), ("confirmation_required",
        json!(["Каскад «hop» будет удалён; назначения подключения «hop» группам и клиентам будут сняты."])));
    assert_eq!(fingerprint(root.path()), before);
    assert_eq!(run(&mut session, &["cascade", "delete", "--name", "hop", "--yes"], None).unwrap(), json!({"name": "hop"}));
    let config = session.state.load_config().unwrap();
    assert!(config.cascades.is_empty());
    assert_eq!(config.connections[0].groups[0].proxies, ["VLESS TCP"]);
    assert_eq!(config.clients[0].connections.as_ref().unwrap()[0].proxies, ["VLESS TCP"]);
    assert_eq!(run(&mut session, &["cascade", "delete", "--name", "hop", "--yes"], None).unwrap_err().code, "not_found");
}
