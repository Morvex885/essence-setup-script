//! `connect_remote` against the real web listener (`essence-rc-web`): the
//! WebSocket upgrade a browser and the CLI share, plain and with TLS.
use std::{collections::BTreeMap, net::{IpAddr, Ipv4Addr}};
use essence_rc_client::{Client, ConnectError, DaemonClient, Input, Request, Secrets, Trust, argv};
use essence_rc_web::{Accepted, Listener, ListenerConfig, Tls, fingerprint, self_signed};
use serde_json::{Value, json};
use tokio::sync::mpsc;
use zeroize::Zeroizing;

struct Pins(BTreeMap<String, String>);
impl Trust for Pins {
    fn pinned(&self, host_port: &str) -> Option<String> { self.0.get(host_port).cloned() }
}

/// A listener plus a minimal daemon behind it: `hello`, then an echo reply per request.
fn listener(tls: Tls) -> (Listener, tokio::runtime::Runtime) {
    let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
    let (sender, mut accepted) = mpsc::channel::<Accepted>(4);
    let config = ListenerConfig { bind: IpAddr::V4(Ipv4Addr::LOCALHOST), port: 0, tls };
    let listener = runtime.block_on(Listener::start(config, sender)).unwrap();
    runtime.spawn(async move {
        while let Some(mut connection) = accepted.recv().await {
            tokio::spawn(async move {
                let hello = json!({"event":"hello","protocol":3,"version":"9.9.9","origin":"network","listener":{"loopback":true,"tls":false}});
                if connection.outgoing.send(Zeroizing::new(hello.to_string())).await.is_err() { return; }
                while let Some(line) = connection.incoming.recv().await {
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let reply = json!({"id": request["id"], "ok": true, "data": {"argv": request["argv"]}});
                    if connection.outgoing.send(Zeroizing::new(reply.to_string())).await.is_err() { return; }
                }
            });
        }
    });
    (listener, runtime)
}

fn exchange(client: &mut DaemonClient) {
    let words = argv(&["session", "status"]);
    let reply = client.send(Request::new(&words, &Secrets::default(), &Input::default()), &mut |_| {}).unwrap();
    assert!(reply.ok);
    assert_eq!(reply.data["argv"], json!(["session", "status"]));
    client.close().unwrap();
}

#[test]
fn plain_listener_accepts_the_cli_websocket() {
    let (listener, runtime) = listener(Tls::Off);
    let url = format!("http://127.0.0.1:{}", listener.addr.port());
    let mut client = DaemonClient::connect_remote(&url, &Pins(BTreeMap::new())).unwrap();
    assert_eq!(client.hello().version, "9.9.9");
    exchange(&mut client);
    runtime.block_on(listener.stop());
}

#[test]
fn tls_listener_with_pinned_self_signed_certificate() {
    let (cert, key) = self_signed(&["localhost".into(), "127.0.0.1".into()]).unwrap();
    let expected = fingerprint(cert.as_bytes()).unwrap();
    let (listener, runtime) = listener(Tls::Pem { cert: cert.into_bytes(), key: Zeroizing::new(key.as_bytes().to_vec()) });
    let port = listener.addr.port();
    let url = format!("https://127.0.0.1:{port}");
    match DaemonClient::connect_remote(&url, &Pins(BTreeMap::new())) {
        Err(ConnectError::CertUnknown { fingerprint, .. }) => assert_eq!(fingerprint, expected),
        Err(other) => panic!("ожидался CertUnknown: {other}"),
        Ok(_) => panic!("ожидался CertUnknown"),
    }
    let pins = Pins(BTreeMap::from([(format!("127.0.0.1:{port}"), expected)]));
    let mut client = DaemonClient::connect_remote(&url, &pins).unwrap();
    exchange(&mut client);
    runtime.block_on(listener.stop());
}
