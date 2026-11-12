//! Remote transport against a local test daemon: TLS with self-signed, pinned
//! and CA-issued certificates, a mismatching key, plain WebSocket, `hello`.
use std::{collections::BTreeMap, net::SocketAddr, sync::Arc};
use futures_util::{SinkExt, StreamExt};
use rcgen::{BasicConstraints, CertificateParams, IsCa, KeyPair};
use rustls::{RootCertStore, ServerConfig,
    pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer},
    server::{ClientHello, ResolvesServerCert},
    sign::CertifiedKey};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;
use tokio_tungstenite::{accept_async, tungstenite::Message};
use super::*;
use crate::{Client, Input, Request, Secrets, argv};

struct Pins(BTreeMap<String, String>);
impl Trust for Pins {
    fn pinned(&self, host_port: &str) -> Option<String> { self.0.get(host_port).cloned() }
}
fn no_pins() -> Pins { Pins(BTreeMap::new()) }
fn pin(addr: SocketAddr, fingerprint: &str) -> Pins { Pins(BTreeMap::from([(format!("127.0.0.1:{}", addr.port()), fingerprint.to_owned())])) }

/// A certificate with its key; `signer` may be another key (wrong-key test).
#[derive(Debug)]
struct Fixed(Arc<CertifiedKey>);
impl ResolvesServerCert for Fixed {
    fn resolve(&self, _: ClientHello<'_>) -> Option<Arc<CertifiedKey>> { Some(self.0.clone()) }
}

fn private_key(key: &KeyPair) -> PrivateKeyDer<'static> {
    PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()))
}

fn certified(chain: Vec<CertificateDer<'static>>, signer: &KeyPair) -> Arc<CertifiedKey> {
    let signing = rustls::crypto::ring::sign::any_supported_type(&private_key(signer)).unwrap();
    Arc::new(CertifiedKey::new(chain, signing))
}

fn names() -> Vec<String> { vec!["127.0.0.1".into(), "localhost".into()] }

/// Self-signed leaf for 127.0.0.1/localhost and its key.
fn self_signed() -> (CertificateDer<'static>, KeyPair) {
    let key = KeyPair::generate().unwrap();
    let cert = CertificateParams::new(names()).unwrap().self_signed(&key).unwrap();
    (cert.der().clone(), key)
}

/// A test daemon: optional TLS, then WebSocket; sends `hello` with
/// `protocol` and answers every request with `{"ok":true,"data":{"argv":…}}`.
fn daemon(tls: Option<Arc<CertifiedKey>>, protocol: u32) -> SocketAddr {
    let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().unwrap();
    let listener = runtime.block_on(TcpListener::bind("127.0.0.1:0")).unwrap();
    let addr = listener.local_addr().unwrap();
    let acceptor = tls.map(|key| {
        let config = ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions().unwrap()
            .with_no_client_auth()
            .with_cert_resolver(Arc::new(Fixed(key)));
        TlsAcceptor::from(Arc::new(config))
    });
    std::thread::spawn(move || runtime.block_on(async move {
        loop {
            let Ok((tcp, _)) = listener.accept().await else { return };
            let acceptor = acceptor.clone();
            tokio::spawn(async move {
                match acceptor {
                    Some(acceptor) => if let Ok(stream) = acceptor.accept(tcp).await { serve(stream, protocol).await },
                    None => serve(tcp, protocol).await,
                }
            });
        }
    }));
    addr
}

async fn serve<S: AsyncRead + AsyncWrite + Unpin>(stream: S, protocol: u32) {
    let Ok(mut socket) = accept_async(stream).await else { return };
    let hello = json!({"event":"hello","protocol":protocol,"version":"9.9.9","origin":"network","listener":{"loopback":true,"tls":true}});
    if socket.send(Message::text(hello.to_string())).await.is_err() { return; }
    while let Some(Ok(frame)) = socket.next().await {
        let Message::Text(text) = frame else { continue };
        let request: Value = serde_json::from_str(text.as_str()).unwrap();
        let log = json!({"id": request["id"], "event":"log","level":"info","text":"работаю"});
        let reply = json!({"id": request["id"], "ok": true, "data": {"argv": request["argv"], "secrets": request["secrets"]}});
        if socket.send(Message::text(log.to_string())).await.is_err() || socket.send(Message::text(reply.to_string())).await.is_err() { return; }
    }
}

fn url(addr: SocketAddr, tls: bool) -> String {
    format!("{}://127.0.0.1:{}", if tls { "https" } else { "http" }, addr.port())
}

/// One request through the connected client: argv and secrets echoed, log seen.
fn round_trip(client: &mut DaemonClient) {
    let words = argv(&["group", "list"]);
    let mut secrets = Secrets::default();
    secrets.insert("access-token", "abc");
    let input = Input::default();
    let mut logs = Vec::new();
    let reply = client.send(Request::new(&words, &secrets, &input), &mut |progress| {
        if let crate::Progress::Log(entry) = progress { logs.push(entry.text.clone()); }
    }).unwrap();
    assert!(reply.ok);
    assert_eq!(reply.data["argv"], json!(["group", "list"]));
    assert_eq!(reply.data["secrets"], json!({"access-token": "abc"}));
    assert_eq!(logs, ["работаю"]);
    client.close().unwrap();
}

#[test]
fn unknown_self_signed_certificate_reports_its_fingerprint() {
    let (cert, key) = self_signed();
    let expected = certificate_fingerprint(&cert);
    let addr = daemon(Some(certified(vec![cert], &key)), 3);
    match DaemonClient::connect_remote(&url(addr, true), &no_pins()) {
        Err(ConnectError::CertUnknown { host, port, fingerprint }) => {
            assert_eq!((host.as_str(), port, fingerprint.as_str()), ("127.0.0.1", addr.port(), expected.as_str()));
        }
        Err(other) => panic!("ожидался CertUnknown: {other}"),
        Ok(_) => panic!("ожидался CertUnknown"),
    }
}

#[test]
fn pinned_fingerprint_is_accepted_and_lines_flow() {
    let (cert, key) = self_signed();
    let fingerprint = certificate_fingerprint(&cert).to_ascii_uppercase();
    let addr = daemon(Some(certified(vec![cert], &key)), 3);
    let mut client = DaemonClient::connect_remote(&url(addr, true), &pin(addr, &fingerprint)).unwrap();
    assert_eq!(client.hello().version, "9.9.9");
    assert_eq!(client.hello().origin, crate::Origin::Network);
    assert_eq!(client.local_data_dir(), None, "a remote daemon's data directory is not on this machine");
    round_trip(&mut client);
}

#[test]
fn other_pinned_fingerprint_is_cert_changed() {
    let (cert, key) = self_signed();
    let actual = certificate_fingerprint(&cert);
    let addr = daemon(Some(certified(vec![cert], &key)), 3);
    let other = format!("SHA256:{}", "0".repeat(64));
    match DaemonClient::connect_remote(&url(addr, true), &pin(addr, &other)) {
        Err(ConnectError::CertChanged { fingerprint, port, .. }) => assert_eq!((fingerprint, port), (actual, addr.port())),
        Err(other) => panic!("ожидался CertChanged: {other}"),
        Ok(_) => panic!("ожидался CertChanged"),
    }
}

#[test]
fn pinned_certificate_with_a_foreign_key_fails_the_handshake() {
    let (cert, _) = self_signed();
    let fingerprint = certificate_fingerprint(&cert);
    let impostor = KeyPair::generate().unwrap();
    let addr = daemon(Some(certified(vec![cert], &impostor)), 3);
    match DaemonClient::connect_remote(&url(addr, true), &pin(addr, &fingerprint)) {
        Err(ConnectError::Unreachable(_)) => {}
        Err(other) => panic!("ожидался отказ рукопожатия: {other}"),
        Ok(_) => panic!("подпись чужим ключом принята"),
    }
}

/// A CA of the test, a leaf it issued and the trust store with the CA.
fn issued() -> (Vec<CertificateDer<'static>>, KeyPair, RootCertStore) {
    let ca_key = KeyPair::generate().unwrap();
    let mut params = CertificateParams::new(Vec::<String>::new()).unwrap();
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    let ca = params.self_signed(&ca_key).unwrap();
    let leaf_key = KeyPair::generate().unwrap();
    let leaf = CertificateParams::new(names()).unwrap().signed_by(&leaf_key, &ca, &ca_key).unwrap();
    let mut roots = RootCertStore::empty();
    roots.add(ca.der().clone()).unwrap();
    (vec![leaf.der().clone(), ca.der().clone()], leaf_key, roots)
}

#[test]
fn valid_chain_without_pin_is_accepted_but_a_pin_ignores_the_chain() {
    let (chain, key, roots) = issued();
    let leaf = certificate_fingerprint(&chain[0]);
    let addr = daemon(Some(certified(chain, &key)), 3);
    let mut client = connect_remote_with(&url(addr, true), &no_pins(), roots.clone()).unwrap();
    round_trip(&mut client);
    let other = format!("SHA256:{}", "a".repeat(64));
    assert!(matches!(connect_remote_with(&url(addr, true), &pin(addr, &other), roots.clone()),
        Err(ConnectError::CertChanged { fingerprint, .. }) if fingerprint == leaf));
    // С чужим УЦ в хранилище та же цепочка неизвестна.
    let (_, _, foreign) = issued();
    assert!(matches!(connect_remote_with(&url(addr, true), &no_pins(), foreign),
        Err(ConnectError::CertUnknown { fingerprint, .. }) if fingerprint == leaf));
}

#[test]
fn plain_websocket_and_protocol_mismatch() {
    let addr = daemon(None, 3);
    let mut client = DaemonClient::connect_remote(&url(addr, false), &no_pins()).unwrap();
    round_trip(&mut client);
    let old = daemon(None, 2);
    assert!(matches!(DaemonClient::connect_remote(&url(old, false), &no_pins()), Err(ConnectError::Protocol(number)) if number == json!(2)));
}

#[test]
fn nothing_listening_is_unreachable() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    drop(listener);
    assert!(matches!(DaemonClient::connect_remote(&url(addr, false), &no_pins()), Err(ConnectError::Unreachable(_))));
}

#[test]
fn urls() {
    let parse = |text: &str| RemoteUrl::parse(text);
    assert_eq!(parse("https://Panel.Example").unwrap(), RemoteUrl { tls: true, host: "panel.example".into(), port: 8377 });
    assert_eq!(parse("http://10.0.0.5:9000/").unwrap(), RemoteUrl { tls: false, host: "10.0.0.5".into(), port: 9000 });
    let v6 = parse("HTTPS://[::1]:8443").unwrap();
    assert_eq!((v6.host.as_str(), v6.port, v6.host_port()), ("::1", 8443, "[::1]:8443".to_owned()));
    assert_eq!(v6.socket_url(), "wss://[::1]:8443/ws");
    for bad in ["ftp://x", "https://", "https://x/path", "https://x:0", "https://x:99999", "https://::1", "https://u@x", "https://x?y", "x:1", "https://x:"] {
        assert!(parse(bad).is_err(), "{bad}");
    }
    assert!(!parse("http://localhost:1").unwrap().is_loopback(), "names are never trusted as loopback");
    assert!(parse("http://127.0.0.2").unwrap().is_loopback());
    assert!(parse("http://[::ffff:127.0.0.1]").unwrap().is_loopback());
    assert!(!parse("http://10.0.0.1").unwrap().is_loopback());
    assert!(!parse("http://example.com").unwrap().is_loopback());
}

#[test]
fn fingerprints() {
    assert!(valid_fingerprint(&format!("SHA256:{}", "aB".repeat(32))));
    assert!(!valid_fingerprint(&format!("sha256:{}", "a".repeat(64))));
    assert!(!valid_fingerprint(&format!("SHA256:{}", "a".repeat(63))));
    assert!(!valid_fingerprint(&format!("SHA256:{}", "g".repeat(64))));
    assert_eq!(certificate_fingerprint(b"x").len(), 7 + 64);
}

#[test]
fn a_silent_connection_is_lost_but_pings_keep_it_open() {
    use tokio_tungstenite::tungstenite::protocol::Role;
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let (near, far) = tokio::io::duplex(4096);
        let client = WebSocketStream::from_raw_socket(near, Role::Client, None).await;
        let mut server = WebSocketStream::from_raw_socket(far, Role::Server, None).await;
        let (_outgoing, receiver) = unbounded_channel();
        let (events, incoming) = mpsc::channel();
        let started = Instant::now();
        let pinging = async {
            for _ in 0..4 {
                tokio::time::sleep(Duration::from_millis(150)).await;
                server.send(Message::Ping(Default::default())).await.unwrap();
            }
            assert!(incoming.try_recv().is_err(), "pings keep the connection");
        };
        // The server stays connected but silent after the pings.
        tokio::join!(pump(client, receiver, events, Duration::from_millis(300)), pinging);
        assert!(started.elapsed() >= Duration::from_millis(900));
        assert!(matches!(incoming.try_recv(), Ok(Incoming::Closed(_))));
        drop(server);
    });
}
