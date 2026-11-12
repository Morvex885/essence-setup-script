//! Remote daemon over WebSocket: `http://host[:port]` → `ws://…/ws`,
//! `https://host[:port]` → `wss://…/ws` (port 8377 by default).
//!
//! Certificate check (П9): a pinned `host:port` (`--fingerprint` or the
//! file of known daemons) is accepted only when the leaf fingerprint matches
//! exactly, otherwise [`ConnectError::CertChanged`] — the CA chain is not
//! considered. Without a pin the chain must be valid for the name by the
//! `webpki-roots` anchors, otherwise [`ConnectError::CertUnknown`]. Handshake
//! signatures are always checked by `rustls::crypto` with the `ring`
//! algorithms. Lines travel in `Zeroizing` buffers; WebSocket frame buffers
//! inside the libraries are the stated exception.
use std::{fmt, io, net::IpAddr, sync::{Arc, Mutex, mpsc}, time::{Duration, Instant}};
use futures_util::{SinkExt, StreamExt};
use rustls::{ClientConfig, DigitallySignedStruct, RootCertStore, SignatureScheme,
    client::{WebPkiServerVerifier, danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier}},
    crypto::{CryptoProvider, verify_tls12_signature, verify_tls13_signature},
    pki_types::{CertificateDer, ServerName, UnixTime}};
use sha2::{Digest, Sha256};
use tokio::{io::{AsyncRead, AsyncWrite}, net::TcpStream, sync::mpsc::{UnboundedReceiver, unbounded_channel}};
use tokio_rustls::TlsConnector;
use tokio_tungstenite::{WebSocketStream, client_async_with_config,
    tungstenite::{Message, client::IntoClientRequest, protocol::WebSocketConfig}};
use zeroize::Zeroizing;
use crate::{daemon::{DaemonClient, Incoming, Outgoing, ProtocolMismatch, protocol},
    protocol::MAX_MESSAGE};

/// Port of a URL without one (the listener's default).
pub const DEFAULT_PORT: u16 = 8377;
/// TCP, TLS and WebSocket handshakes together; then `hello`.
const CONNECT_WAIT: Duration = Duration::from_secs(15);
const HELLO_WAIT: Duration = Duration::from_secs(15);
/// No frame at all (pings included) for this long: the daemon is gone. The
/// listener pings every 30 s, so long commands and terminals stay alive.
const SILENCE_LIMIT: Duration = Duration::from_secs(90);

/// A parsed `--connect` URL. `host` is lowercase, IPv6 without brackets.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteUrl { pub tls: bool, pub host: String, pub port: u16 }

impl RemoteUrl {
    /// `https://host[:port][/]` or `http://host[:port][/]`; anything else
    /// (paths, queries, user info, port 0) is refused with a Russian message.
    pub fn parse(text: &str) -> Result<Self, String> {
        let invalid = || format!("Неверный адрес демона: {text}. Укажите https://хост[:порт] или http://хост[:порт].");
        let lower = text.to_ascii_lowercase();
        let (tls, rest) = if lower.starts_with("https://") { (true, &text[8..]) }
            else if lower.starts_with("http://") { (false, &text[7..]) }
            else { return Err(invalid()) };
        let rest = rest.strip_suffix('/').unwrap_or(rest);
        if rest.is_empty() || rest.contains(['/', '?', '#', '@', ' ']) { return Err(invalid()); }
        let (host, port) = if let Some(inner) = rest.strip_prefix('[') {
            let (host, tail) = inner.split_once(']').ok_or_else(invalid)?;
            host.parse::<std::net::Ipv6Addr>().map_err(|_| invalid())?;
            match tail {
                "" => (host, None),
                tail => (host, Some(tail.strip_prefix(':').ok_or_else(invalid)?)),
            }
        } else {
            match rest.split_once(':') {
                Some((host, port)) => (host, Some(port)),
                None => (rest, None),
            }
        };
        if host.is_empty() || (host.contains(':') && !rest.starts_with('[')) { return Err(invalid()); }
        let port = match port {
            None => DEFAULT_PORT,
            Some(port) if !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) =>
                port.parse::<u16>().ok().filter(|port| *port != 0).ok_or_else(invalid)?,
            Some(_) => return Err(invalid()),
        };
        Ok(Self { tls, host: host.to_ascii_lowercase(), port })
    }

    /// `host:port` (IPv6 in brackets): the key of the known-daemons file.
    pub fn host_port(&self) -> String {
        if self.host.contains(':') { format!("[{}]:{}", self.host, self.port) } else { format!("{}:{}", self.host, self.port) }
    }

    /// A loopback IP literal (IPv4-mapped included). Names, `localhost`
    /// too, are not: their resolution is outside the user's command line.
    pub fn is_loopback(&self) -> bool {
        self.host.parse::<IpAddr>().is_ok_and(|ip| ip.to_canonical().is_loopback())
    }

    fn socket_url(&self) -> String {
        format!("{}://{}/ws", if self.tls { "wss" } else { "ws" }, self.host_port())
    }
}

/// `SHA256:` followed by exactly 64 hex digits.
pub fn valid_fingerprint(text: &str) -> bool {
    text.strip_prefix("SHA256:").is_some_and(|hex| hex.len() == 64 && hex.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// `SHA256:<64 lowercase hex>` of a DER certificate.
pub fn certificate_fingerprint(der: &[u8]) -> String {
    format!("SHA256:{}", hex::encode(Sha256::digest(der)))
}

/// Pins of remote daemons: the expected leaf fingerprint for `host:port`.
pub trait Trust {
    fn pinned(&self, host_port: &str) -> Option<String>;
}

#[derive(Debug)]
pub enum ConnectError {
    /// No pin and no valid chain: the user may confirm `fingerprint`.
    CertUnknown { host: String, port: u16, fingerprint: String },
    /// A pin exists and the presented leaf differs from it.
    CertChanged { host: String, port: u16, fingerprint: String },
    Unreachable(String),
    /// `hello` announced another protocol number.
    Protocol(serde_json::Value),
}

impl fmt::Display for ConnectError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::CertUnknown { .. } => f.write_str("Сертификат демона не подтверждён."),
            Self::CertChanged { .. } => f.write_str("Сертификат демона изменился."),
            Self::Unreachable(reason) => write!(f, "Не удалось подключиться к демону essence-rc: {reason}."),
            Self::Protocol(number) => write!(f, "Несовместимый протокол демона: {number}. Обновите более старую сторону."),
        }
    }
}

impl std::error::Error for ConnectError {}

/// Why the certificate was refused; read after a failed handshake.
#[derive(Clone, Debug)]
enum Refusal { Unknown(String), Changed(String) }

#[derive(Debug)]
struct PinningVerifier {
    pinned: Option<String>,
    chain: Arc<WebPkiServerVerifier>,
    provider: Arc<CryptoProvider>,
    refusal: Arc<Mutex<Option<Refusal>>>,
}

impl PinningVerifier {
    fn refuse(&self, refusal: Refusal) -> rustls::Error {
        if let Ok(mut slot) = self.refusal.lock() { *slot = Some(refusal); }
        rustls::Error::InvalidCertificate(rustls::CertificateError::ApplicationVerificationFailure)
    }
}

impl ServerCertVerifier for PinningVerifier {
    fn verify_server_cert(&self, end_entity: &CertificateDer<'_>, intermediates: &[CertificateDer<'_>], server_name: &ServerName<'_>,
        ocsp: &[u8], now: UnixTime) -> Result<ServerCertVerified, rustls::Error> {
        let fingerprint = certificate_fingerprint(end_entity);
        match &self.pinned {
            Some(pinned) if pinned.eq_ignore_ascii_case(&fingerprint) => Ok(ServerCertVerified::assertion()),
            Some(_) => Err(self.refuse(Refusal::Changed(fingerprint))),
            None => self.chain.verify_server_cert(end_entity, intermediates, server_name, ocsp, now)
                .map_err(|_| self.refuse(Refusal::Unknown(fingerprint))),
        }
    }
    fn verify_tls12_signature(&self, message: &[u8], cert: &CertificateDer<'_>, dss: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }
    fn verify_tls13_signature(&self, message: &[u8], cert: &CertificateDer<'_>, dss: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

/// The `webpki-roots` trust anchors.
fn public_roots() -> RootCertStore {
    RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() }
}

trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Stream for T {}

impl DaemonClient {
    /// Connects to a remote daemon (`--connect`); see the module docs for
    /// the certificate rules. `trust` supplies the pin of `host:port`.
    pub fn connect_remote(url: &str, trust: &dyn Trust) -> Result<Self, ConnectError> {
        connect_remote_with(url, trust, public_roots())
    }
}

/// `connect_remote` with explicit trust anchors (tests use their own CA).
pub(crate) fn connect_remote_with(url: &str, trust: &dyn Trust, roots: RootCertStore) -> Result<DaemonClient, ConnectError> {
    let target = RemoteUrl::parse(url).map_err(ConnectError::Unreachable)?;
    let unreachable = |error: &dyn fmt::Display| ConnectError::Unreachable(error.to_string());
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|error| unreachable(&error))?;
    let refusal = Arc::new(Mutex::new(None));
    let opened = runtime.block_on(async {
        tokio::time::timeout(CONNECT_WAIT, open(&target, trust.pinned(&target.host_port()), roots, refusal.clone())).await
            .unwrap_or_else(|_| Err("время ожидания истекло".to_owned()))
    });
    let socket = match opened {
        Ok(socket) => socket,
        Err(reason) => {
            let (host, port) = (target.host.clone(), target.port);
            return Err(match refusal.lock().ok().and_then(|mut slot| slot.take()) {
                Some(Refusal::Unknown(fingerprint)) => ConnectError::CertUnknown { host, port, fingerprint },
                Some(Refusal::Changed(fingerprint)) => ConnectError::CertChanged { host, port, fingerprint },
                None => ConnectError::Unreachable(reason),
            });
        }
    };
    let (outgoing, outgoing_receiver) = unbounded_channel();
    let (events, incoming) = mpsc::channel();
    let forward = events.clone();
    let io_thread = std::thread::Builder::new().name("essence-rc-ws".into())
        .spawn(move || runtime.block_on(pump(socket, outgoing_receiver, forward, SILENCE_LIMIT)))
        .map_err(|error| unreachable(&error))?;
    DaemonClient::start(incoming, events, Outgoing::Socket(outgoing), Some(io_thread), Some(Instant::now() + HELLO_WAIT))
        .map_err(|error| match error.get_ref().and_then(|inner| inner.downcast_ref::<ProtocolMismatch>()) {
            Some(mismatch) => ConnectError::Protocol(mismatch.0.clone()),
            None => unreachable(&error),
        })
}

/// TCP → (TLS) → WebSocket handshake. Errors are reasons for `Unreachable`;
/// a refused certificate is recorded in `refusal` by the verifier.
async fn open(target: &RemoteUrl, pinned: Option<String>, roots: RootCertStore, refusal: Arc<Mutex<Option<Refusal>>>)
    -> Result<WebSocketStream<Box<dyn Stream>>, String> {
    let tcp = TcpStream::connect((target.host.as_str(), target.port)).await.map_err(|error| error.to_string())?;
    let _ = tcp.set_nodelay(true);
    let stream: Box<dyn Stream> = if target.tls {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let chain = WebPkiServerVerifier::builder_with_provider(Arc::new(roots), provider.clone()).build()
            .map_err(|error| error.to_string())?;
        let verifier = PinningVerifier { pinned, chain, provider: provider.clone(), refusal };
        let config = ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions().map_err(|error| error.to_string())?
            .dangerous().with_custom_certificate_verifier(Arc::new(verifier))
            .with_no_client_auth();
        let name = ServerName::try_from(target.host.clone()).map_err(|error| error.to_string())?;
        Box::new(TlsConnector::from(Arc::new(config)).connect(name, tcp).await.map_err(|error| error.to_string())?)
    } else {
        Box::new(tcp)
    };
    let request = target.socket_url().into_client_request().map_err(|error| error.to_string())?;
    let config = WebSocketConfig::default().max_message_size(Some(MAX_MESSAGE)).max_frame_size(Some(MAX_MESSAGE));
    let (socket, _) = client_async_with_config(request, stream, Some(config)).await.map_err(|error| error.to_string())?;
    Ok(socket)
}

fn connection_lost() -> io::Error {
    io::Error::new(io::ErrorKind::ConnectionAborted, "Соединение с демоном потеряно.")
}

/// WebSocket reader and writer: a text frame is one line. Ends when the
/// daemon closes, on an error, after `silence` without a single frame, when
/// the client is gone or when the outgoing channel closes (then a Close frame
/// is sent). Pings are answered by tungstenite while reading.
async fn pump<S: AsyncRead + AsyncWrite + Unpin>(socket: WebSocketStream<S>, mut outgoing: UnboundedReceiver<Zeroizing<String>>,
    incoming: mpsc::Sender<Incoming>, silence: Duration) {
    let (mut sink, mut frames) = socket.split();
    let mut broken = false;
    let quiet = tokio::time::sleep(silence);
    tokio::pin!(quiet);
    loop {
        tokio::select! {
            frame = frames.next() => {
                quiet.as_mut().reset(tokio::time::Instant::now() + silence);
                match frame {
                    Some(Ok(Message::Text(text))) => {
                        if incoming.send(Incoming::Line(Zeroizing::new(text.as_str().to_owned()))).is_err() { return; }
                    }
                    Some(Ok(Message::Binary(_))) => {
                        let _ = incoming.send(Incoming::Closed(protocol("Некорректный ответ демона")));
                        return;
                    }
                    Some(Ok(Message::Close(_)) | Err(_)) | None => {
                        let _ = incoming.send(Incoming::Closed(connection_lost()));
                        return;
                    }
                    Some(Ok(_)) => {}
                }
            }
            () = &mut quiet => {
                let _ = incoming.send(Incoming::Closed(connection_lost()));
                return;
            }
            message = outgoing.recv() => match message {
                // A broken write side drops further messages; reading continues.
                Some(_) if broken => {}
                Some(line) => broken = sink.send(Message::text(line.as_str())).await.is_err(),
                None => { let _ = sink.close().await; return; }
            },
        }
    }
}

#[cfg(test)]
mod tests;
