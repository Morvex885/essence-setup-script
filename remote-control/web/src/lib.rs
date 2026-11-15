//! Сетевой слушатель веб-панели essence-rc: HTTP(S) со встроенными ассетами
//! (`assets/`) и WebSocket-мост строк протокола v3 к демону.
//!
//! Крейт не знает протокола: каждое принятое WebSocket-соединение отдаётся
//! демону как [`Accepted`] — входящие текстовые кадры приходят строками в
//! `incoming`, строки из `outgoing` уходят кадрами. Криптопровайдер TLS —
//! только `ring`.
//!
//! Проверки запросов (план 2.1 и поправка П9):
//! - слушатель на loopback: `Host` — `127.0.0.1`, `localhost` или `[::1]` с
//!   портом слушателя, иначе 403 для всех маршрутов;
//! - иной адрес: `Host` — IP-литерал или `localhost` с портом слушателя либо
//!   DNS-имя из SAN сертификата слушателя, иначе 403 для всех маршрутов;
//! - `/ws`: `Origin`, если есть, совпадает с `Host` по хосту и порту (порты
//!   по умолчанию — по схеме), `Origin: null` → 403.

use std::{
    collections::HashMap,
    fmt, io,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    pin::Pin,
    sync::{Arc, Mutex},
    task::{Context, Poll},
    time::Duration,
};

use axum::{
    Extension, Router,
    body::{Body, Bytes},
    extract::{
        Path, Request, State,
        ws::{
            CloseFrame, Message, WebSocket, WebSocketUpgrade, close_code,
            rejection::WebSocketUpgradeRejection,
        },
    },
    http::{HeaderMap, HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
};
use hyper_util::{
    rt::{TokioExecutor, TokioIo, TokioTimer},
    server::conn::auto,
    service::TowerToHyperService,
};
use include_dir::{Dir, include_dir};
use rustls::{
    ServerConfig,
    client::verify_server_name,
    pki_types::{CertificateDer, ServerName},
    server::ParsedCertificate,
};
use sha2::{Digest, Sha256};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, ReadBuf},
    net::{TcpListener, TcpStream},
    sync::{OwnedSemaphorePermit, Semaphore, mpsc, watch},
    task::{JoinHandle, JoinSet},
};
use tokio_rustls::TlsAcceptor;
use zeroize::Zeroizing;

static ASSETS: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/assets");

/// Предел сообщения WebSocket (протокол v3).
pub const MAX_MESSAGE: usize = 4 * 1024 * 1024;
const STOP_WAIT: Duration = Duration::from_secs(5);
const TLS_HANDSHAKE: Duration = Duration::from_secs(10);
const CHANNEL: usize = 64;

/// Политика содержимого до и после `connect-src`: между ними — `'self'` и
/// точный адрес WebSocket проверенного `Host` (не во всех браузерах `'self'`
/// разрешает `ws:`/`wss:`).
const CSP_HEAD: &str = "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'";
const CSP_TAIL: &str = "; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

const SECURITY_HEADERS: [(&str, &str); 4] = [
    ("x-content-type-options", "nosniff"),
    ("x-frame-options", "DENY"),
    ("referrer-policy", "no-referrer"),
    ("cache-control", "no-store"),
];

/// Режим TLS слушателя.
pub enum Tls {
    Off,
    /// PEM: цепочка сертификатов и закрытый ключ.
    Pem {
        cert: Vec<u8>,
        key: Zeroizing<Vec<u8>>,
    },
}

pub struct ListenerConfig {
    pub bind: IpAddr,
    /// `0` — порт выбирает ОС; фактический — в [`Listener::addr`].
    pub port: u16,
    pub tls: Tls,
}

/// Принятое WebSocket-соединение: строки от браузера и к браузеру.
pub struct Accepted {
    pub peer: SocketAddr,
    pub incoming: mpsc::Receiver<Zeroizing<String>>,
    pub outgoing: mpsc::Sender<Zeroizing<String>>,
}

/// Пределы слушателя; [`Limits::default`] — рабочие значения.
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    /// От подключения до конца заголовков запроса; дольше — соединение закрывается.
    pub header_timeout: Duration,
    /// Одновременные TCP-соединения, включая открытые WebSocket; лишние закрываются сразу.
    pub max_connections: usize,
    /// Из них ещё не приславшие заголовки первого запроса (включая
    /// TLS-рукопожатие); лишние закрываются сразу. Молчащие соединения не
    /// занимают весь `max_connections`.
    pub max_pending: usize,
    /// Те же ожидающие соединения с одного IP-адреса: один источник не
    /// занимает весь `max_pending`.
    pub max_pending_per_source: usize,
    /// Период ping WebSocket; без единого кадра от браузера за период — Close.
    pub ping_every: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            header_timeout: Duration::from_secs(30),
            max_connections: 128,
            max_pending: 32,
            max_pending_per_source: 8,
            ping_every: Duration::from_secs(30),
        }
    }
}

#[derive(Debug)]
pub enum ListenError {
    PortInUse(u16),
    Tls(String),
    Io(io::Error),
}

impl fmt::Display for ListenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PortInUse(port) => write!(f, "Порт {port} уже занят."),
            Self::Tls(message) => f.write_str(message),
            Self::Io(error) => write!(f, "Не удалось запустить веб-панель: {error}."),
        }
    }
}

impl std::error::Error for ListenError {}

/// Работающий слушатель. `stop` закрывает приём и все соединения; падение
/// значения без `stop` тоже останавливает слушатель (без ожидания).
pub struct Listener {
    pub addr: SocketAddr,
    pub tls: bool,
    /// `SHA256:<64 hex>` первого сертификата при TLS.
    pub fingerprint: Option<String>,
    shutdown: watch::Sender<bool>,
    task: Option<JoinHandle<()>>,
    /// Закрывается, когда завершились все мосты WebSocket (они держат `Shared`).
    bridges: mpsc::Receiver<()>,
}

impl Listener {
    pub async fn start(
        config: ListenerConfig,
        accepted: mpsc::Sender<Accepted>,
    ) -> Result<Self, ListenError> {
        Self::start_with_limits(config, accepted, Limits::default()).await
    }

    /// [`Listener::start`] с иными пределами (тесты — короткие сроки).
    pub async fn start_with_limits(
        config: ListenerConfig,
        accepted: mpsc::Sender<Accepted>,
        limits: Limits,
    ) -> Result<Self, ListenError> {
        let bind = config.bind.to_canonical();
        let (acceptor, cert) = match &config.tls {
            Tls::Off => (None, None),
            Tls::Pem { cert, key } => {
                let (server, leaf) = server_config(cert, key)?;
                (Some(TlsAcceptor::from(server)), Some(leaf))
            }
        };
        let listener = TcpListener::bind(SocketAddr::new(bind, config.port))
            .await
            .map_err(|error| {
                if error.kind() == io::ErrorKind::AddrInUse {
                    ListenError::PortInUse(config.port)
                } else {
                    ListenError::Io(error)
                }
            })?;
        let addr = listener.local_addr().map_err(ListenError::Io)?;
        let fingerprint = cert.as_ref().map(der_fingerprint);
        let tls = acceptor.is_some();
        let (shutdown, stop) = watch::channel(false);
        let (alive, bridges) = mpsc::channel(1);
        let shared = Arc::new(Shared {
            port: addr.port(),
            loopback: bind.is_loopback(),
            tls,
            cert,
            accepted,
            shutdown: stop.clone(),
            ping_every: limits.ping_every,
            _alive: alive,
        });
        let router = router(shared);
        let task = tokio::spawn(serve(listener, acceptor, router, stop, limits));
        Ok(Self {
            addr,
            tls,
            fingerprint,
            shutdown,
            task: Some(task),
            bridges,
        })
    }

    /// Перестать принимать соединения и закрыть открытые: HTTP обрываются,
    /// WebSocket получают Close; мосты ждутся до 5 с.
    pub async fn stop(mut self) {
        let _ = self.shutdown.send(true);
        if let Some(task) = self.task.take() {
            let _ = task.await;
        }
        let _ = tokio::time::timeout(STOP_WAIT, self.bridges.recv()).await;
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        let _ = self.shutdown.send(true);
    }
}

/// Самоподписанный сертификат для имён (DNS-имена и IP-литералы → SAN).
/// Возвращает PEM сертификата и PEM закрытого ключа.
pub fn self_signed(names: &[String]) -> Result<(String, Zeroizing<String>), String> {
    // Внутренние буферы ключа в rcgen/ring не обнуляются — оговорённое
    // исключение (как буферы кадров в библиотеках, П9); наружу ключ уходит
    // только в `Zeroizing`.
    let certified = rcgen::generate_simple_self_signed(names.to_vec())
        .map_err(|error| format!("Не удалось создать сертификат веб-панели: {error}."))?;
    Ok((
        certified.cert.pem(),
        Zeroizing::new(certified.key_pair.serialize_pem()),
    ))
}

/// `SHA256:<64 hex>` от DER первого сертификата PEM; `None`, если сертификата нет.
pub fn fingerprint(cert_pem: &[u8]) -> Option<String> {
    let first = rustls_pemfile::certs(&mut &cert_pem[..]).next()?.ok()?;
    Some(der_fingerprint(&first))
}

fn der_fingerprint(cert: &CertificateDer<'_>) -> String {
    format!("SHA256:{}", hex::encode(Sha256::digest(cert.as_ref())))
}

fn server_config(
    cert: &[u8],
    key: &[u8],
) -> Result<(Arc<ServerConfig>, CertificateDer<'static>), ListenError> {
    let chain = rustls_pemfile::certs(&mut &cert[..])
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| {
            ListenError::Tls(format!(
                "Не удалось прочитать сертификат веб-панели: {error}."
            ))
        })?;
    let leaf = chain.first().cloned().ok_or_else(|| {
        ListenError::Tls("В файле сертификата веб-панели нет сертификата.".into())
    })?;
    let key = rustls_pemfile::private_key(&mut &key[..])
        .map_err(|error| {
            ListenError::Tls(format!(
                "Не удалось прочитать закрытый ключ веб-панели: {error}."
            ))
        })?
        .ok_or_else(|| ListenError::Tls("В файле ключа веб-панели нет закрытого ключа.".into()))?;
    let invalid = |error: rustls::Error| {
        ListenError::Tls(format!(
            "Сертификат или ключ веб-панели не подходят: {error}."
        ))
    };
    let mut config =
        ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .map_err(invalid)?
            .with_no_client_auth()
            .with_single_cert(chain, key)
            .map_err(invalid)?;
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok((Arc::new(config), leaf))
}

// ─── Приём соединений ───────────────────────────────────────────────────────

async fn serve(
    listener: TcpListener,
    acceptor: Option<TlsAcceptor>,
    router: Router,
    mut stop: watch::Receiver<bool>,
    limits: Limits,
) {
    let permits = Arc::new(Semaphore::new(limits.max_connections));
    let pending = Arc::new(Semaphore::new(limits.max_pending));
    let sources = Sources::new(limits.max_pending_per_source);
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            _ = stop.changed() => break,
            accepted = listener.accept() => {
                let (stream, peer) = match accepted {
                    Ok(pair) => pair,
                    // Нехватка дескрипторов и подобное: не крутить цикл вхолостую.
                    Err(_) => { tokio::time::sleep(Duration::from_millis(100)).await; continue; }
                };
                // Сверх пределов — закрыть сразу, не читая.
                let Some(source) = sources.take(peer.ip()) else { drop(stream); continue; };
                let Ok(global) = pending.clone().try_acquire_owned() else { drop(stream); continue; };
                let Ok(permit) = permits.clone().try_acquire_owned() else { drop(stream); continue; };
                let slot = Slot(Arc::new(Mutex::new(Some(permit))));
                let waiting = Waiting(Arc::new(Mutex::new(Some((global, source)))));
                let service = router.clone().layer(Extension(Peer(peer))).layer(Extension(slot)).layer(Extension(waiting));
                connections.spawn(connection(stream, acceptor.clone(), service, limits.header_timeout));
            }
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
    connections.shutdown().await;
}

async fn connection(
    stream: TcpStream,
    acceptor: Option<TlsAcceptor>,
    service: Router,
    header_timeout: Duration,
) {
    match acceptor {
        None => http(stream, service, header_timeout).await,
        Some(acceptor) => {
            if let Ok(Ok(stream)) =
                tokio::time::timeout(TLS_HANDSHAKE, acceptor.accept(stream)).await
            {
                http(stream, service, header_timeout).await;
            }
        }
    }
}

/// Первые байты запроса не позже `wait`; `None` — молчание или закрытие.
async fn first_bytes<I: AsyncRead + Unpin>(io: &mut I, wait: Duration) -> Option<Vec<u8>> {
    let mut buffer = vec![0; 1024];
    match tokio::time::timeout(wait, io.read(&mut buffer)).await {
        Ok(Ok(read)) if read > 0 => {
            buffer.truncate(read);
            Some(buffer)
        }
        _ => None,
    }
}

/// Поток с уже прочитанным началом: сначала отдаёт `prefix`, затем `io`.
struct Prefixed<I> {
    prefix: Vec<u8>,
    offset: usize,
    io: I,
}

impl<I: AsyncRead + Unpin> AsyncRead for Prefixed<I> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if this.offset < this.prefix.len() {
            let count = buf.remaining().min(this.prefix.len() - this.offset);
            buf.put_slice(&this.prefix[this.offset..this.offset + count]);
            this.offset += count;
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut this.io).poll_read(cx, buf)
    }
}

impl<I: AsyncWrite + Unpin> AsyncWrite for Prefixed<I> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().io).poll_write(cx, buf)
    }
    fn poll_write_vectored(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bufs: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().io).poll_write_vectored(cx, bufs)
    }
    fn is_write_vectored(&self) -> bool {
        self.io.is_write_vectored()
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().io).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().io).poll_shutdown(cx)
    }
}

/// HTTP/1.1 с keep-alive (без него hyper добавил бы `close` и к ответу 101,
/// а клиенты WebSocket требуют `Connection: Upgrade`). Первые байты — не
/// позже `header_timeout`; заголовки каждого следующего запроса, включая
/// простой keep-alive-соединения, — по таймеру hyper (`TokioTimer`).
async fn http<I>(mut io: I, service: Router, header_timeout: Duration)
where
    I: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    // Таймер заголовков hyper заводится только после определения версии
    // протокола, которое ждёт первых байтов без срока: их ждём сами.
    let Some(prefix) = first_bytes(&mut io, header_timeout).await else {
        return;
    };
    let io = Prefixed {
        prefix,
        offset: 0,
        io,
    };
    let mut builder = auto::Builder::new(TokioExecutor::new()).http1_only();
    builder
        .http1()
        .timer(TokioTimer::new())
        .header_read_timeout(header_timeout);
    let _ = builder
        .serve_connection_with_upgrades(TokioIo::new(io), TowerToHyperService::new(service))
        .await;
}

// ─── Маршруты и проверки ────────────────────────────────────────────────────

#[derive(Clone, Copy)]
struct Peer(SocketAddr);

/// Место соединения в пределе `max_connections`: освобождается с соединением,
/// а при апгрейде переходит к мосту WebSocket.
#[derive(Clone)]
struct Slot(Arc<Mutex<Option<OwnedSemaphorePermit>>>);

/// Место в пределах `max_pending` и `max_pending_per_source`: освобождается,
/// когда получены заголовки первого запроса (или с соединением).
#[derive(Clone)]
struct Waiting(Arc<Mutex<Option<(OwnedSemaphorePermit, SourceSlot)>>>);

/// Счётчики ожидающих соединений по IP-адресу источника (IPv4 в IPv6 — как IPv4).
#[derive(Clone)]
struct Sources {
    limit: usize,
    counts: Arc<Mutex<HashMap<IpAddr, usize>>>,
}

/// Занятое место источника; освобождается при падении.
struct SourceSlot {
    ip: IpAddr,
    sources: Sources,
}

impl Sources {
    fn new(limit: usize) -> Self {
        Self { limit, counts: Arc::default() }
    }

    /// Место для `ip`; `None` — источник исчерпал свой предел.
    fn take(&self, ip: IpAddr) -> Option<SourceSlot> {
        let ip = ip.to_canonical();
        let mut counts = self.counts.lock().ok()?;
        let count = counts.entry(ip).or_default();
        if *count >= self.limit {
            return None;
        }
        *count += 1;
        Some(SourceSlot { ip, sources: self.clone() })
    }
}

impl Drop for SourceSlot {
    fn drop(&mut self) {
        // Отравленный мьютекс: `take` и так отказывает всем, счётчик не важен.
        if let Ok(mut counts) = self.sources.counts.lock()
            && let Some(count) = counts.get_mut(&self.ip)
        {
            *count -= 1;
            if *count == 0 {
                counts.remove(&self.ip);
            }
        }
    }
}

struct Shared {
    port: u16,
    loopback: bool,
    tls: bool,
    cert: Option<CertificateDer<'static>>,
    accepted: mpsc::Sender<Accepted>,
    shutdown: watch::Receiver<bool>,
    ping_every: Duration,
    /// Держится каждым мостом через `Arc<Shared>`; см. `Listener::bridges`.
    _alive: mpsc::Sender<()>,
}

fn router(shared: Arc<Shared>) -> Router {
    Router::new()
        .route("/", get(index).fallback(not_found))
        .route("/assets/{*path}", get(asset).fallback(not_found))
        .route("/ws", get(socket).fallback(not_found))
        .fallback(not_found)
        .layer(middleware::from_fn_with_state(shared.clone(), host_guard))
        .layer(middleware::from_fn_with_state(shared.clone(), security_headers))
        .layer(middleware::from_fn(head_received))
        .with_state(shared)
}

/// Заголовки запроса получены: соединение больше не ждёт первых байтов.
async fn head_received(request: Request, next: Next) -> Response {
    if let Some(Waiting(held)) = request.extensions().get::<Waiting>() {
        drop(held.lock().ok().and_then(|mut held| held.take()));
    }
    next.run(request).await
}

async fn security_headers(State(shared): State<Arc<Shared>>, request: Request, next: Next) -> Response {
    let host = host_of(request.headers(), shared.tls).filter(|host| shared.host_allowed(host));
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_SECURITY_POLICY, content_security_policy(host.as_ref(), shared.tls));
    for (name, value) in SECURITY_HEADERS {
        headers.insert(name, HeaderValue::from_static(value));
    }
    response
}

/// CSP; `connect-src` дополняется адресом WebSocket допустимого `Host`.
fn content_security_policy(host: Option<&Authority>, tls: bool) -> HeaderValue {
    let mut policy = String::from(CSP_HEAD);
    if let Some(Authority { host, port }) = host {
        let scheme = if tls { "wss" } else { "ws" };
        if host.contains(':') {
            policy.push_str(&format!(" {scheme}://[{host}]:{port}"));
        } else {
            policy.push_str(&format!(" {scheme}://{host}:{port}"));
        }
    }
    policy.push_str(CSP_TAIL);
    // Host уже разобран и проверен: в нём только видимые ASCII-символы.
    HeaderValue::from_str(&policy).unwrap_or_else(|_| HeaderValue::from_static("default-src 'none'"))
}

async fn host_guard(State(shared): State<Arc<Shared>>, request: Request, next: Next) -> Response {
    // Абсолютная форма (`GET http://host/ …`) обошла бы проверку `Host`.
    if request.uri().authority().is_some() {
        return forbidden();
    }
    match host_of(request.headers(), shared.tls) {
        Some(host) if shared.host_allowed(&host) => next.run(request).await,
        _ => forbidden(),
    }
}

fn forbidden() -> Response {
    (StatusCode::FORBIDDEN, "Доступ запрещён.\n").into_response()
}

async fn not_found() -> Response {
    (StatusCode::NOT_FOUND, "Не найдено.\n").into_response()
}

async fn index() -> Response {
    file("index.html")
}

async fn asset(Path(path): Path<String>) -> Response {
    file(&path)
}

fn file(path: &str) -> Response {
    let (Some(file), Some(kind)) = (ASSETS.get_file(path), content_type(path)) else {
        return (StatusCode::NOT_FOUND, "Не найдено.\n").into_response();
    };
    ([(header::CONTENT_TYPE, kind)], Body::from(file.contents())).into_response()
}

/// Тип содержимого по расширению; прочие файлы не отдаются.
fn content_type(path: &str) -> Option<&'static str> {
    Some(match path.rsplit_once('.')?.1 {
        "html" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "svg" => "image/svg+xml",
        "json" => "application/json",
        "woff2" => "font/woff2",
        _ => return None,
    })
}

async fn socket(
    State(shared): State<Arc<Shared>>,
    Extension(Peer(peer)): Extension<Peer>,
    Extension(slot): Extension<Slot>,
    headers: HeaderMap,
    upgrade: Result<WebSocketUpgrade, WebSocketUpgradeRejection>,
) -> Response {
    let Some(host) = host_of(&headers, shared.tls) else {
        return forbidden();
    };
    if !origin_allowed(&headers, &host, shared.tls) {
        return forbidden();
    }
    let upgrade = match upgrade {
        Ok(upgrade) => upgrade,
        Err(rejection) => return rejection.into_response(),
    };
    upgrade
        .max_message_size(MAX_MESSAGE)
        .max_frame_size(MAX_MESSAGE)
        .on_upgrade(move |socket| async move {
            let _permit = slot.0.lock().ok().and_then(|mut held| held.take());
            bridge(socket, peer, shared).await;
        })
}

/// `future`, прерываемый остановкой слушателя: `None` — остановлен.
async fn unless_stopped<F: Future>(
    stop: &mut watch::Receiver<bool>,
    future: F,
) -> Option<F::Output> {
    tokio::select! {
        output = future => Some(output),
        () = until_stop(stop) => None,
    }
}

/// Остановка слушателя (или его исчезновение). `Ref` наблюдателя не
/// переживает `await`: будущее остаётся `Send`.
async fn until_stop(stop: &mut watch::Receiver<bool>) {
    let _ = stop.wait_for(|stopped| *stopped).await.map(drop);
}

/// Мост WebSocket ↔ строки демона: только текстовые кадры; ping каждые
/// `ping_every`, и если с прошлого ping от браузера не пришло ни одного кадра —
/// Close. Любое ожидание прерывается остановкой слушателя.
async fn bridge(mut socket: WebSocket, peer: SocketAddr, shared: Arc<Shared>) {
    // Два приёмника: один ждёт остановку в `select!`, другой прерывает
    // ожидания внутри ветвей.
    let mut stop = shared.shutdown.clone();
    let mut stopping = shared.shutdown.clone();
    let (to_daemon, incoming) = mpsc::channel(CHANNEL);
    let (outgoing, mut from_daemon) = mpsc::channel::<Zeroizing<String>>(CHANNEL);
    let handed = unless_stopped(
        &mut stop,
        shared.accepted.send(Accepted {
            peer,
            incoming,
            outgoing,
        }),
    )
    .await;
    if !matches!(handed, Some(Ok(()))) {
        let _ = socket.send(Message::Close(None)).await;
        return;
    }
    let every = shared.ping_every;
    let mut ping = tokio::time::interval_at(tokio::time::Instant::now() + every, every);
    let mut heard = true;
    let stopped = || {
        Some(CloseFrame {
            code: close_code::AWAY,
            reason: "Веб-панель остановлена.".into(),
        })
    };
    let close = loop {
        tokio::select! {
            frame = socket.recv() => {
                heard = true;
                match frame {
                    Some(Ok(Message::Text(text))) => {
                        match unless_stopped(&mut stop, to_daemon.send(Zeroizing::new(text.as_str().to_owned()))).await {
                            Some(Ok(())) => {}
                            Some(Err(_)) => break None,
                            None => break stopped(),
                        }
                    }
                    Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
                    Some(Ok(Message::Binary(_))) => {
                        break Some(CloseFrame { code: close_code::UNSUPPORTED, reason: "Только текстовые кадры.".into() });
                    }
                    Some(Ok(Message::Close(_)) | Err(_)) | None => return,
                }
            }
            line = from_daemon.recv() => match line {
                Some(line) => match unless_stopped(&mut stop, socket.send(Message::text(line.as_str()))).await {
                    Some(Ok(())) => {}
                    Some(Err(_)) => return,
                    None => break stopped(),
                },
                None => break None,
            },
            _ = ping.tick() => {
                if !heard {
                    break Some(CloseFrame { code: close_code::AWAY, reason: "Нет ответа на ping.".into() });
                }
                heard = false;
                match unless_stopped(&mut stop, socket.send(Message::Ping(Bytes::new()))).await {
                    Some(Ok(())) => {}
                    Some(Err(_)) => return,
                    None => break stopped(),
                }
            }
            () = until_stop(&mut stopping) => break stopped(),
        }
    };
    // Close не должен держать остановку дольше её ожидания.
    let _ = tokio::time::timeout(STOP_WAIT, socket.send(Message::Close(close))).await;
}

// ─── Host и Origin ──────────────────────────────────────────────────────────

/// Хост (в нижнем регистре, IPv6 без скобок) и порт адреса `host[:port]`.
#[derive(Debug, PartialEq, Eq)]
struct Authority {
    host: String,
    port: u16,
}

fn default_port(tls: bool) -> u16 {
    if tls { 443 } else { 80 }
}

/// Разбор `host[:port]` / `[v6][:port]`; IPv6 без скобок недопустим.
fn authority(text: &str, default: u16) -> Option<Authority> {
    let (host, port) = if let Some(rest) = text.strip_prefix('[') {
        let (host, tail) = rest.split_once(']')?;
        host.parse::<Ipv6Addr>().ok()?;
        match tail {
            "" => (host, None),
            tail => (host, Some(tail.strip_prefix(':')?)),
        }
    } else {
        match text.split_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (text, None),
        }
    };
    if host.is_empty() || host.contains(':') && !text.starts_with('[') {
        return None;
    }
    let port = match port {
        None => default,
        Some(port) if !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) => {
            port.parse().ok()?
        }
        Some(_) => return None,
    };
    Some(Authority {
        host: host.to_ascii_lowercase(),
        port,
    })
}

fn host_of(headers: &HeaderMap, tls: bool) -> Option<Authority> {
    let mut values = headers.get_all(header::HOST).iter();
    let value = values.next()?;
    if values.next().is_some() {
        return None;
    }
    authority(value.to_str().ok()?, default_port(tls))
}

/// `Origin` отсутствует → допустимо; `null`, другая схема или иной хост/порт → нет.
fn origin_allowed(headers: &HeaderMap, host: &Authority, tls: bool) -> bool {
    let mut values = headers.get_all(header::ORIGIN).iter();
    let Some(value) = values.next() else {
        return true;
    };
    if values.next().is_some() {
        return false;
    }
    let Ok(value) = value.to_str() else {
        return false;
    };
    let Some((scheme, rest)) = value.split_once("://") else {
        return false;
    };
    let default = match scheme.to_ascii_lowercase().as_str() {
        "http" => 80,
        "https" => 443,
        _ => return false,
    };
    if (default == 443) != tls {
        return false;
    }
    authority(rest, default).is_some_and(|origin| origin == *host)
}

impl Shared {
    fn host_allowed(&self, host: &Authority) -> bool {
        if host.port != self.port {
            return false;
        }
        let ip = host.host.parse::<IpAddr>().ok();
        if self.loopback {
            return host.host == "localhost"
                || ip.is_some_and(|ip| {
                    ip == IpAddr::V4(Ipv4Addr::LOCALHOST) || ip == IpAddr::V6(Ipv6Addr::LOCALHOST)
                });
        }
        if host.host == "localhost" || ip.is_some() {
            return true;
        }
        self.cert
            .as_ref()
            .is_some_and(|cert| certificate_names(cert, &host.host))
    }
}

/// DNS-имя действительно для сертификата (SAN), по правилам webpki.
fn certificate_names(cert: &CertificateDer<'_>, name: &str) -> bool {
    let Ok(server) = ServerName::try_from(name.to_owned()) else {
        return false;
    };
    if !matches!(server, ServerName::DnsName(_)) {
        return false;
    }
    ParsedCertificate::try_from(cert)
        .is_ok_and(|parsed| verify_server_name(&parsed, &server).is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_source_cannot_take_the_pending_share_of_another() {
        let sources = Sources::new(2);
        let a: IpAddr = "192.0.2.1".parse().unwrap();
        let b: IpAddr = "2001:db8::1".parse().unwrap();
        let first = sources.take(a).unwrap();
        let second = sources.take(a).unwrap();
        assert!(sources.take(a).is_none(), "предел источника исчерпан");
        // IPv4 в IPv6 — тот же источник.
        assert!(sources.take("::ffff:192.0.2.1".parse().unwrap()).is_none());
        // Другой источник проходит, пока первый держит свою долю.
        let _other = sources.take(b).unwrap();
        drop(first);
        let again = sources.take(a).unwrap();
        drop((again, second));
        assert!(!sources.counts.lock().unwrap().contains_key(&a), "пустой счётчик удалён");
    }

    fn shared(loopback: bool, cert: Option<CertificateDer<'static>>) -> Shared {
        let (accepted, _) = mpsc::channel(1);
        let (_, shutdown) = watch::channel(false);
        let (alive, _) = mpsc::channel(1);
        Shared {
            port: 8377,
            loopback,
            tls: cert.is_some(),
            cert,
            accepted,
            shutdown,
            ping_every: Duration::from_secs(30),
            _alive: alive,
        }
    }

    fn host(text: &str) -> Authority {
        authority(text, 80).unwrap()
    }

    #[test]
    fn authority_parsing() {
        assert_eq!(
            host("Example.COM:8377"),
            Authority {
                host: "example.com".into(),
                port: 8377
            }
        );
        assert_eq!(
            host("[::1]:8377"),
            Authority {
                host: "::1".into(),
                port: 8377
            }
        );
        assert_eq!(
            host("localhost"),
            Authority {
                host: "localhost".into(),
                port: 80
            }
        );
        for bad in [
            "::1:8377",
            "[::1]8377",
            "host:",
            "host:+1",
            ":80",
            "[zz]:1",
            "host:99999",
            "a:1:2",
        ] {
            assert_eq!(authority(bad, 80), None, "{bad}");
        }
    }

    #[test]
    fn loopback_host_rule() {
        let s = shared(true, None);
        for ok in ["127.0.0.1:8377", "localhost:8377", "[::1]:8377"] {
            assert!(s.host_allowed(&host(ok)), "{ok}");
        }
        for bad in [
            "127.0.0.1:8378",
            "evil.example:8377",
            "10.0.0.1:8377",
            "127.0.0.1",
        ] {
            assert!(!s.host_allowed(&host(bad)), "{bad}");
        }
    }

    #[test]
    fn network_host_rule_uses_ip_literals_localhost_and_certificate_names() {
        let (pem, _) = self_signed(&["panel.example".into(), "10.0.0.5".into()]).unwrap();
        let cert = rustls_pemfile::certs(&mut pem.as_bytes())
            .next()
            .unwrap()
            .unwrap();
        let s = shared(false, Some(cert));
        for ok in [
            "10.0.0.5:8377",
            "192.168.1.2:8377",
            "[fe80::1]:8377",
            "localhost:8377",
            "panel.example:8377",
            "PANEL.example:8377",
        ] {
            assert!(s.host_allowed(&host(ok)), "{ok}");
        }
        for bad in ["evil.example:8377", "panel.example:8378", "panel.example"] {
            assert!(!s.host_allowed(&host(bad)), "{bad}");
        }
        assert!(!shared(false, None).host_allowed(&host("panel.example:8377")));
    }

    #[test]
    fn origin_rule() {
        let mut headers = HeaderMap::new();
        let here = host("127.0.0.1:8377");
        assert!(origin_allowed(&headers, &here, false));
        let check = |headers: &mut HeaderMap, origin: &str, host: &Authority, tls: bool| {
            headers.insert(header::ORIGIN, HeaderValue::from_str(origin).unwrap());
            origin_allowed(headers, host, tls)
        };
        assert!(check(&mut headers, "http://127.0.0.1:8377", &here, false));
        assert!(!check(&mut headers, "null", &here, false));
        assert!(!check(
            &mut headers,
            "http://evil.example:8377",
            &here,
            false
        ));
        assert!(!check(&mut headers, "http://127.0.0.1:8378", &here, false));
        assert!(!check(&mut headers, "https://127.0.0.1:8377", &here, false));
        // Порты по умолчанию для схемы.
        assert!(check(
            &mut headers,
            "https://panel.example",
            &authority("panel.example", 443).unwrap(),
            true
        ));
        assert!(check(
            &mut headers,
            "http://panel.example",
            &host("panel.example:80"),
            false
        ));
        assert!(!check(
            &mut headers,
            "http://panel.example",
            &host("panel.example:8377"),
            false
        ));
    }

    #[test]
    fn content_types() {
        assert_eq!(
            content_type("js/app.js"),
            Some("text/javascript; charset=utf-8")
        );
        assert_eq!(
            content_type("x.mjs"),
            Some("text/javascript; charset=utf-8")
        );
        assert_eq!(content_type("vendor/VENDOR.md"), None);
        assert_eq!(content_type("noext"), None);
    }

    #[test]
    fn fingerprint_of_self_signed() {
        let (pem, key) =
            self_signed(&["localhost".into(), "127.0.0.1".into(), "::1".into()]).unwrap();
        let value = fingerprint(pem.as_bytes()).unwrap();
        assert!(
            value.starts_with("SHA256:") && value.len() == 7 + 64,
            "{value}"
        );
        assert!(key.contains("PRIVATE KEY"));
        assert_eq!(fingerprint(b"not a pem"), None);
    }
}
