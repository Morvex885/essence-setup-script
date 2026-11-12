//! Слушатель веб-панели на loopback и 0.0.0.0: ассеты и заголовки
//! безопасности, 404, проверки Host/Origin, обмен строками по WebSocket,
//! TLS с самоподписанным сертификатом, занятый порт.
use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::{Arc, Mutex},
    time::Duration,
};

use essence_rc_web::{
    Accepted, Limits, ListenError, Listener, ListenerConfig, Tls, fingerprint, self_signed,
};
use rustls::{
    ClientConfig, DigitallySignedStruct, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::{CryptoProvider, verify_tls12_signature, verify_tls13_signature},
    pki_types::{CertificateDer, ServerName, UnixTime},
};
use sha2::{Digest, Sha256};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::TcpStream,
    sync::mpsc,
    time::timeout,
};
use zeroize::Zeroizing;

const LOOPBACK: IpAddr = IpAddr::V4(Ipv4Addr::LOCALHOST);
const WAIT: Duration = Duration::from_secs(10);

async fn start(bind: IpAddr, tls: Tls) -> (Listener, mpsc::Receiver<Accepted>) {
    let (sender, accepted) = mpsc::channel(4);
    let listener = Listener::start(ListenerConfig { bind, port: 0, tls }, sender)
        .await
        .expect("слушатель запущен");
    assert_ne!(listener.addr.port(), 0, "фактический порт вместо 0");
    (listener, accepted)
}

fn local(listener: &Listener) -> SocketAddr {
    SocketAddr::new(LOOPBACK, listener.addr.port())
}

struct Reply {
    status: u16,
    head: String,
    body: Vec<u8>,
}

impl Reply {
    fn header(&self, name: &str) -> Option<String> {
        self.head.lines().find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.eq_ignore_ascii_case(name)
                .then(|| value.trim().to_owned())
        })
    }
}

async fn exchange<S: AsyncRead + AsyncWrite + Unpin>(
    mut stream: S,
    path: &str,
    host: &str,
    extra: &[(&str, &str)],
) -> Reply {
    let mut request = format!("GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n");
    for (name, value) in extra {
        request.push_str(&format!("{name}: {value}\r\n"));
    }
    request.push_str("\r\n");
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut raw = Vec::new();
    timeout(WAIT, stream.read_to_end(&mut raw))
        .await
        .expect("ответ вовремя")
        .unwrap();
    parse(&raw)
}

fn parse(raw: &[u8]) -> Reply {
    let split = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .expect("конец заголовков");
    let head = String::from_utf8(raw[..split].to_vec()).unwrap();
    let status = head.split(' ').nth(1).unwrap().parse().unwrap();
    Reply {
        status,
        head,
        body: raw[split + 4..].to_vec(),
    }
}

async fn get(addr: SocketAddr, path: &str, host: &str, extra: &[(&str, &str)]) -> Reply {
    exchange(TcpStream::connect(addr).await.unwrap(), path, host, extra).await
}

fn assert_security_headers(reply: &Reply) {
    assert_eq!(
        reply.header("content-security-policy").as_deref(),
        Some(
            "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
        )
    );
    assert_eq!(
        reply.header("x-content-type-options").as_deref(),
        Some("nosniff")
    );
    assert_eq!(reply.header("x-frame-options").as_deref(), Some("DENY"));
    assert_eq!(
        reply.header("referrer-policy").as_deref(),
        Some("no-referrer")
    );
    assert_eq!(reply.header("cache-control").as_deref(), Some("no-store"));
}

#[tokio::test]
async fn serves_index_and_assets_with_security_headers_and_404() {
    let (listener, _accepted) = start(LOOPBACK, Tls::Off).await;
    let addr = local(&listener);
    let host = format!("127.0.0.1:{}", addr.port());

    let index = get(addr, "/", &host, &[]).await;
    assert_eq!(index.status, 200);
    assert_eq!(
        index.header("content-type").as_deref(),
        Some("text/html; charset=utf-8")
    );
    assert!(String::from_utf8_lossy(&index.body).contains("/assets/js/app.js"));
    assert_security_headers(&index);

    let asset = get(addr, "/assets/js/app.js", &host, &[]).await;
    assert_eq!(asset.status, 200);
    assert_eq!(
        asset.header("content-type").as_deref(),
        Some("text/javascript; charset=utf-8")
    );
    assert_eq!(asset.body, include_bytes!("../assets/js/app.js"));
    assert_security_headers(&asset);
    let css = get(addr, "/assets/css/app.css", &host, &[]).await;
    assert_eq!(
        css.header("content-type").as_deref(),
        Some("text/css; charset=utf-8")
    );

    for path in [
        "/missing",
        "/assets/missing.js",
        "/assets/vendor/VENDOR.md",
        "/assets/../Cargo.toml",
        "/index.html",
    ] {
        let reply = get(addr, path, &host, &[]).await;
        assert_eq!(reply.status, 404, "{path}");
        assert_security_headers(&reply);
    }
    listener.stop().await;
}

#[tokio::test]
async fn loopback_listener_refuses_foreign_host_on_every_route() {
    let (listener, _accepted) = start(LOOPBACK, Tls::Off).await;
    let addr = local(&listener);
    let port = addr.port();
    for host in [
        format!("localhost:{port}"),
        format!("[::1]:{port}"),
        format!("127.0.0.1:{port}"),
    ] {
        assert_eq!(get(addr, "/", &host, &[]).await.status, 200, "{host}");
    }
    for host in [
        format!("evil.example:{port}"),
        format!("10.0.0.1:{port}"),
        format!("127.0.0.1:{}", port.wrapping_add(1)),
        "127.0.0.1".into(),
    ] {
        for path in ["/", "/assets/js/app.js", "/ws", "/missing"] {
            let reply = get(addr, path, &host, &[]).await;
            assert_eq!(reply.status, 403, "{host} {path}");
            assert_security_headers(&reply);
        }
    }
    listener.stop().await;
}

#[tokio::test]
async fn unspecified_listener_refuses_unknown_dns_host() {
    let (listener, _accepted) = start(IpAddr::V4(Ipv4Addr::UNSPECIFIED), Tls::Off).await;
    let addr = local(&listener);
    let port = addr.port();
    assert_eq!(
        get(addr, "/", &format!("evil.example:{port}"), &[])
            .await
            .status,
        403
    );
    assert_eq!(
        get(addr, "/", &format!("192.168.1.10:{port}"), &[])
            .await
            .status,
        200
    );
    assert_eq!(
        get(addr, "/", &format!("localhost:{port}"), &[])
            .await
            .status,
        200
    );
    listener.stop().await;
}

const WS_HEADERS: [(&str, &str); 4] = [
    ("Upgrade", "websocket"),
    ("Connection", "Upgrade"),
    ("Sec-WebSocket-Version", "13"),
    ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
];

async fn ws_request(addr: SocketAddr, host: &str, origin: Option<&str>) -> Reply {
    // `exchange` шлёт `Connection: close`: Origin проверяется раньше разбора
    // апгрейда, поэтому для отказа достаточно статуса ответа.
    let mut headers: Vec<(&str, &str)> = WS_HEADERS
        .iter()
        .filter(|(name, _)| *name != "Connection")
        .copied()
        .collect();
    if let Some(origin) = origin {
        headers.push(("Origin", origin));
    }
    get(addr, "/ws", host, &headers).await
}

#[tokio::test]
async fn websocket_refuses_foreign_and_null_origin() {
    let (listener, _accepted) = start(LOOPBACK, Tls::Off).await;
    let addr = local(&listener);
    let host = format!("127.0.0.1:{}", addr.port());
    for origin in [
        "http://evil.example",
        "null",
        &format!("http://127.0.0.1:{}", addr.port() + 1),
        &format!("https://127.0.0.1:{}", addr.port()),
    ] {
        let reply = ws_request(addr, &host, Some(origin)).await;
        assert_eq!(reply.status, 403, "{origin}");
        assert_security_headers(&reply);
    }
    listener.stop().await;
}

/// Клиентский кадр: текст, FIN, маска.
fn client_text_frame(text: &str) -> Vec<u8> {
    let payload = text.as_bytes();
    let mask = [1u8, 2, 3, 4];
    let mut frame = vec![0x81];
    match payload.len() {
        len if len < 126 => frame.push(0x80 | len as u8),
        len => {
            frame.push(0x80 | 126);
            frame.extend_from_slice(&(len as u16).to_be_bytes());
        }
    }
    frame.extend_from_slice(&mask);
    frame.extend(payload.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
    frame
}

/// Кадр сервера (без маски): `(opcode, payload)`.
async fn read_frame<S: AsyncRead + Unpin>(stream: &mut S) -> (u8, Vec<u8>) {
    let mut head = [0u8; 2];
    stream.read_exact(&mut head).await.unwrap();
    let len = match head[1] & 0x7f {
        126 => {
            let mut ext = [0u8; 2];
            stream.read_exact(&mut ext).await.unwrap();
            u16::from_be_bytes(ext) as usize
        }
        127 => {
            let mut ext = [0u8; 8];
            stream.read_exact(&mut ext).await.unwrap();
            u64::from_be_bytes(ext) as usize
        }
        len => len as usize,
    };
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload).await.unwrap();
    (head[0] & 0x0f, payload)
}

async fn open_websocket<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    host: &str,
    origin: &str,
) {
    let mut request = format!("GET /ws HTTP/1.1\r\nHost: {host}\r\nOrigin: {origin}\r\n");
    for (name, value) in WS_HEADERS {
        request.push_str(&format!("{name}: {value}\r\n"));
    }
    request.push_str("\r\n");
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut head = Vec::new();
    while !head.ends_with(b"\r\n\r\n") {
        let mut byte = [0u8; 1];
        timeout(WAIT, stream.read_exact(&mut byte))
            .await
            .expect("рукопожатие вовремя")
            .unwrap();
        head.push(byte[0]);
    }
    let head = String::from_utf8(head).unwrap();
    assert!(head.starts_with("HTTP/1.1 101"), "{head}");
    let connection = head
        .lines()
        .find(|line| line.to_ascii_lowercase().starts_with("connection:"))
        .unwrap_or_default();
    assert!(
        connection.eq_ignore_ascii_case("connection: upgrade"),
        "{head}"
    );
    assert!(
        head.to_ascii_lowercase()
            .contains("sec-websocket-accept: s3pplmbitxaq9kygzzhzrbk+xoo="),
        "{head}"
    );
}

async fn line_exchange<S: AsyncRead + AsyncWrite + Unpin>(
    mut stream: S,
    host: &str,
    origin: &str,
    accepted: &mut mpsc::Receiver<Accepted>,
) {
    open_websocket(&mut stream, host, origin).await;
    let mut connection = timeout(WAIT, accepted.recv())
        .await
        .expect("соединение передано демону")
        .unwrap();
    assert!(connection.peer.ip().is_loopback());

    let request = r#"{"id":1,"argv":["session","status"]}"#;
    stream.write_all(&client_text_frame(request)).await.unwrap();
    let line = timeout(WAIT, connection.incoming.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(line.as_str(), request);
    // Строка длиннее 125 байт — расширенная длина кадра.
    let long = format!(r#"{{"id":2,"argv":["help"],"pad":"{}"}}"#, "x".repeat(300));
    stream.write_all(&client_text_frame(&long)).await.unwrap();
    assert_eq!(
        timeout(WAIT, connection.incoming.recv())
            .await
            .unwrap()
            .unwrap()
            .as_str(),
        long
    );

    let hello = r#"{"event":"hello","protocol":3}"#;
    connection
        .outgoing
        .send(Zeroizing::new(hello.to_owned()))
        .await
        .unwrap();
    let (opcode, payload) = timeout(WAIT, read_frame(&mut stream)).await.unwrap();
    assert_eq!((opcode, payload.as_slice()), (1, hello.as_bytes()));

    // Демон закрыл свою сторону — браузер получает Close.
    drop(connection.outgoing);
    let (opcode, _) = timeout(WAIT, read_frame(&mut stream)).await.unwrap();
    assert_eq!(opcode, 8);
}

#[tokio::test]
async fn websocket_exchanges_text_lines() {
    let (listener, mut accepted) = start(LOOPBACK, Tls::Off).await;
    let addr = local(&listener);
    let host = format!("127.0.0.1:{}", addr.port());
    let origin = format!("http://{host}");
    line_exchange(
        TcpStream::connect(addr).await.unwrap(),
        &host,
        &origin,
        &mut accepted,
    )
    .await;
    // Без Origin (не браузер) — тоже допустимо.
    let mut stream = TcpStream::connect(addr).await.unwrap();
    let mut request = format!("GET /ws HTTP/1.1\r\nHost: {host}\r\n");
    for (name, value) in WS_HEADERS {
        request.push_str(&format!("{name}: {value}\r\n"));
    }
    request.push_str("\r\n");
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut head = [0u8; 12];
    stream.read_exact(&mut head).await.unwrap();
    assert_eq!(&head, b"HTTP/1.1 101");
    listener.stop().await;
}

#[tokio::test]
async fn stop_closes_open_websockets() {
    let (listener, mut accepted) = start(LOOPBACK, Tls::Off).await;
    let addr = local(&listener);
    let host = format!("127.0.0.1:{}", addr.port());
    let mut stream = TcpStream::connect(addr).await.unwrap();
    open_websocket(&mut stream, &host, &format!("http://{host}")).await;
    let _connection = timeout(WAIT, accepted.recv()).await.unwrap().unwrap();
    timeout(WAIT, listener.stop())
        .await
        .expect("остановка вовремя");
    let (opcode, _) = timeout(WAIT, read_frame(&mut stream)).await.unwrap();
    assert_eq!(opcode, 8);
    assert!(TcpStream::connect(addr).await.is_err(), "приём закрыт");
}

/// Проверка сертификата в тесте: принять любой, запомнив лист; подписи
/// рукопожатия проверяются функциями провайдера `ring`.
#[derive(Debug)]
struct Capture {
    leaf: Arc<Mutex<Option<Vec<u8>>>>,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for Capture {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        *self.leaf.lock().unwrap() = Some(end_entity.to_vec());
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[tokio::test]
async fn tls_with_self_signed_certificate_matches_fingerprint() {
    let (cert, key) = self_signed(&["localhost".into(), "127.0.0.1".into(), "::1".into()]).unwrap();
    let expected = fingerprint(cert.as_bytes()).unwrap();
    let tls = Tls::Pem {
        cert: cert.into_bytes(),
        key: Zeroizing::new(key.as_bytes().to_vec()),
    };
    let (listener, mut accepted) = start(LOOPBACK, tls).await;
    assert!(listener.tls);
    assert_eq!(listener.fingerprint.as_deref(), Some(expected.as_str()));
    let addr = local(&listener);
    let host = format!("127.0.0.1:{}", addr.port());

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let leaf = Arc::new(Mutex::new(None));
    let config = ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .unwrap()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(Capture {
            leaf: leaf.clone(),
            provider,
        }))
        .with_no_client_auth();
    let connector = tokio_rustls::TlsConnector::from(Arc::new(config));
    let name = ServerName::try_from("localhost").unwrap();

    let stream = connector
        .connect(name.clone(), TcpStream::connect(addr).await.unwrap())
        .await
        .unwrap();
    let index = exchange(stream, "/", &host, &[]).await;
    assert_eq!(index.status, 200);
    assert_security_headers(&index);
    let seen = leaf.lock().unwrap().clone().expect("сертификат предъявлен");
    assert_eq!(
        format!("SHA256:{}", hex::encode(Sha256::digest(&seen))),
        expected
    );

    // По TLS Origin со схемой https и портом слушателя.
    let stream = connector
        .connect(name, TcpStream::connect(addr).await.unwrap())
        .await
        .unwrap();
    line_exchange(stream, &host, &format!("https://{host}"), &mut accepted).await;
    listener.stop().await;
}

#[tokio::test]
async fn broken_pem_is_a_tls_error() {
    let (sender, _accepted) = mpsc::channel(1);
    let tls = Tls::Pem {
        cert: b"garbage".to_vec(),
        key: Zeroizing::new(b"garbage".to_vec()),
    };
    match Listener::start(
        ListenerConfig {
            bind: LOOPBACK,
            port: 0,
            tls,
        },
        sender,
    )
    .await
    {
        Err(ListenError::Tls(message)) => assert!(!message.is_empty()),
        Err(other) => panic!("ожидалась ошибка TLS: {other}"),
        Ok(_) => panic!("ожидалась ошибка TLS"),
    }
}

#[tokio::test]
async fn busy_port_is_port_in_use() {
    let (listener, _accepted) = start(LOOPBACK, Tls::Off).await;
    let port = listener.addr.port();
    let (sender, _second) = mpsc::channel(1);
    match Listener::start(
        ListenerConfig {
            bind: LOOPBACK,
            port,
            tls: Tls::Off,
        },
        sender,
    )
    .await
    {
        Err(ListenError::PortInUse(busy)) => assert_eq!(busy, port),
        Err(other) => panic!("ожидалось PortInUse: {other}"),
        Ok(_) => panic!("ожидалось PortInUse"),
    }
    listener.stop().await;
}

#[tokio::test]
async fn ipv4_mapped_bind_is_canonical_loopback() {
    let mapped = IpAddr::V6(Ipv4Addr::LOCALHOST.to_ipv6_mapped());
    let (listener, _accepted) = start(mapped, Tls::Off).await;
    assert_eq!(listener.addr.ip(), LOOPBACK);
    let addr = local(&listener);
    assert_eq!(
        get(addr, "/", &format!("evil.example:{}", addr.port()), &[])
            .await
            .status,
        403
    );
    listener.stop().await;
}

async fn start_limited(limits: Limits) -> (Listener, mpsc::Receiver<Accepted>) {
    let (sender, accepted) = mpsc::channel(4);
    let config = ListenerConfig {
        bind: LOOPBACK,
        port: 0,
        tls: Tls::Off,
    };
    let listener = Listener::start_with_limits(config, sender, limits)
        .await
        .expect("слушатель запущен");
    (listener, accepted)
}

/// Соединение закрыто сервером: чтение даёт EOF (или сброс) в пределах `WAIT`.
async fn closed_by_server(stream: &mut TcpStream) -> Vec<u8> {
    let mut raw = Vec::new();
    match timeout(WAIT, stream.read_to_end(&mut raw))
        .await
        .expect("сервер закрыл соединение")
    {
        Ok(_) | Err(_) => raw,
    }
}

#[tokio::test]
async fn silent_connection_is_closed_after_header_timeout() {
    let limits = Limits {
        header_timeout: Duration::from_millis(300),
        ..Limits::default()
    };
    let (listener, _accepted) = start_limited(limits).await;
    let addr = local(&listener);
    let started = tokio::time::Instant::now();
    let mut silent = TcpStream::connect(addr).await.unwrap();
    closed_by_server(&mut silent).await;
    assert!(
        started.elapsed() >= Duration::from_millis(250),
        "закрыто по сроку, а не сразу"
    );
    // Начатые и брошенные заголовки — тоже.
    let mut partial = TcpStream::connect(addr).await.unwrap();
    partial
        .write_all(b"GET / HTTP/1.1\r\nHost: 127.0.0.1")
        .await
        .unwrap();
    closed_by_server(&mut partial).await;
    listener.stop().await;
}

#[tokio::test]
async fn connections_over_the_limit_are_closed_at_once() {
    let limits = Limits {
        max_connections: 2,
        ..Limits::default()
    };
    let (listener, _accepted) = start_limited(limits).await;
    let addr = local(&listener);
    let host = format!("127.0.0.1:{}", addr.port());
    let first = TcpStream::connect(addr).await.unwrap();
    let second = TcpStream::connect(addr).await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let mut third = TcpStream::connect(addr).await.unwrap();
    let raw = closed_by_server(&mut third).await;
    assert!(raw.is_empty(), "лишнее соединение закрыто без ответа");
    drop((first, second));
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(
        get(addr, "/", &host, &[]).await.status,
        200,
        "место освободилось"
    );
    listener.stop().await;
}

#[tokio::test]
async fn absolute_form_request_is_forbidden() {
    let (listener, _accepted) = start(LOOPBACK, Tls::Off).await;
    let addr = local(&listener);
    let mut stream = TcpStream::connect(addr).await.unwrap();
    let request = format!(
        "GET http://evil.example/ HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nConnection: close\r\n\r\n",
        addr.port()
    );
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut raw = Vec::new();
    timeout(WAIT, stream.read_to_end(&mut raw))
        .await
        .unwrap()
        .unwrap();
    let reply = parse(&raw);
    assert_eq!(reply.status, 403);
    assert_security_headers(&reply);
    listener.stop().await;
}

#[tokio::test]
async fn websocket_without_pong_is_closed_after_next_ping() {
    let limits = Limits {
        ping_every: Duration::from_millis(200),
        ..Limits::default()
    };
    let (listener, mut accepted) = start_limited(limits).await;
    let addr = local(&listener);
    let host = format!("127.0.0.1:{}", addr.port());
    let mut stream = TcpStream::connect(addr).await.unwrap();
    open_websocket(&mut stream, &host, &format!("http://{host}")).await;
    let _connection = timeout(WAIT, accepted.recv()).await.unwrap().unwrap();
    let (opcode, _) = timeout(WAIT, read_frame(&mut stream)).await.unwrap();
    assert_eq!(opcode, 9, "ping");
    let (opcode, payload) = timeout(WAIT, read_frame(&mut stream)).await.unwrap();
    assert_eq!(opcode, 8, "Close без ответа на ping");
    assert_eq!(u16::from_be_bytes([payload[0], payload[1]]), 1001);
    listener.stop().await;
}

#[tokio::test]
async fn idle_keep_alive_connection_is_closed_after_header_timeout() {
    let limits = Limits {
        header_timeout: Duration::from_millis(300),
        ..Limits::default()
    };
    let (listener, _accepted) = start_limited(limits).await;
    let addr = local(&listener);
    let mut stream = TcpStream::connect(addr).await.unwrap();
    // Как браузер: keep-alive, второй запрос не приходит.
    let request = format!(
        "GET /assets/css/app.css HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n\r\n",
        addr.port()
    );
    stream.write_all(request.as_bytes()).await.unwrap();
    let started = tokio::time::Instant::now();
    let raw = closed_by_server(&mut stream).await;
    let reply = parse(&raw);
    assert_eq!(reply.status, 200);
    assert!(
        !reply
            .header("connection")
            .is_some_and(|value| value.eq_ignore_ascii_case("close")),
        "keep-alive"
    );
    assert_eq!(reply.body, include_bytes!("../assets/css/app.css"));
    assert!(
        started.elapsed() >= Duration::from_millis(250),
        "закрыто по сроку простоя"
    );
    listener.stop().await;
}
