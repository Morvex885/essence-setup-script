//! Native SSH and SFTP effects; no subprocesses or persistent trust mutations.
//!
//! Upload publishes regular files in place, retaining unrelated remote entries.
//! Earlier replacements remain published on failure; only the root VERSION is
//! staged and atomically renamed last. A server without POSIX rename may publish
//! a previously absent VERSION, but cannot safely replace an existing VERSION.

use std::{
    collections::VecDeque,
    future::{Future, poll_fn},
    path::{Component, Path, PathBuf},
    pin::Pin,
    sync::{Arc, Mutex},
    time::Duration,
};

use rand::RngCore;
use russh::{
    Channel, ChannelMsg, ChannelWriteHalf,
    client::{self, Handle},
    keys::{self, HashAlg, PrivateKey, PrivateKeyWithHashAlg, PublicKeyOrCertificate,
        agent::{AgentIdentity, client::{AgentClient, AgentStream}}},
};
use russh_sftp::{
    client::{RawSftpSession, error::Error as SftpError, rawsession::Limits},
    protocol::{FileAttributes, OpenFlags, Packet, StatusCode},
};
use tokio::{io::AsyncReadExt, time::{Instant, timeout_at}};
use zeroize::Zeroizing;

use crate::{
    error::{RcError, Result},
    transport::{Authentication, ConnectOptions, ConsoleEvent, ExecResult, HostKeyPolicy, PtyRequest,
        RawConsole, RemoteSession, RemoteTransport, remote_failure},
    validation::{ssh_host_valid, ssh_user_valid},
};

type RejectedKey = Arc<Mutex<Option<RcError>>>;
type NativeAgent = AgentClient<Box<dyn AgentStream + Send + Unpin>>;

/// An authenticated connection. Dropping the adapter does not revoke held leases.
/// System authentication uses only the agent passed by the requesting client
/// (`with_agent`); the default transport uses no agent at all.
#[derive(Default)]
pub struct SshTransport {
    connection: Option<Arc<Connection>>,
    agent: Option<PathBuf>,
}

impl SshTransport {
    /// A transport whose system authentication may use the SSH agent at
    /// `agent_socket` (Unix socket path or Windows named pipe); `None` → no agent.
    pub fn with_agent(agent_socket: Option<&Path>) -> Self {
        Self { connection: None, agent: agent_socket.map(Path::to_path_buf) }
    }
}

/// An independent lease on the already authenticated connection, never a relogin.
#[derive(Clone)]
pub struct HeldSession {
    connection: Arc<Connection>,
}

struct Connection {
    handle: Handle<HostVerifier>,
    rejected: RejectedKey,
}

struct HostVerifier {
    host: String,
    port: u16,
    policy: HostKeyPolicy,
    rejected: RejectedKey,
}

impl client::Handler for HostVerifier {
    type Error = russh::Error;

    async fn check_server_key(&mut self, key: &PublicKeyOrCertificate)
        -> std::result::Result<bool, Self::Error>
    {
        // Compare the actual server key, not a CA or a process-global known_hosts.
        let fingerprint = match key {
            PublicKeyOrCertificate::PublicKey { key, .. } => key.fingerprint(HashAlg::Sha256),
            PublicKeyOrCertificate::Certificate(cert) => cert.public_key().fingerprint(HashAlg::Sha256),
        }.to_string();
        let code = if let Some(expected) = &self.policy.expected {
            if expected.as_str() == fingerprint { return Ok(true); }
            "host_key_mismatch"
        } else if self.policy.known.iter().any(|pin| pin.as_str() == fingerprint) {
            return Ok(true);
        } else if self.policy.known.is_empty() {
            "host_key_unknown"
        } else {
            "host_key_changed"
        };
        let error = RcError::new(code, "Ключ SSH-сервера не подтверждён.")
            .with_extra("host", self.host.clone())
            .with_extra("port", self.port)
            .with_extra("fingerprints", serde_json::json!([fingerprint]));
        // russh otherwise reduces a rejected callback to UnknownKey. Retain our
        // structured result independently, including during a later rekey.
        *self.rejected.lock().unwrap_or_else(|p| p.into_inner()) = Some(error);
        Ok(false)
    }
}

fn rejected_key(rejected: &RejectedKey) -> Option<RcError> {
    rejected.lock().unwrap_or_else(|p| p.into_inner()).take()
}

impl Connection {
    fn failure(&self, reason: &'static str) -> RcError {
        rejected_key(&self.rejected).unwrap_or_else(|| {
            remote_failure(if self.handle.is_closed() { "connection_closed" } else { reason })
        })
    }
}

impl RemoteTransport for SshTransport {
    type Held = HeldSession;

    async fn connect(&mut self, options: ConnectOptions) -> Result<()> {
        // A failed replacement must not leave an earlier endpoint active here.
        self.connection = None;
        validate_endpoint(&options)?;
        let deadline = Instant::now() + options.timeout;
        let connection = timeout_at(deadline, connect_native(options, self.agent.as_deref())).await
            .map_err(|_| remote_failure("timeout"))??;
        self.connection = Some(Arc::new(connection));
        Ok(())
    }

    fn hold(&self) -> Result<HeldSession> {
        let connection = self.connection.as_ref().ok_or_else(|| remote_failure("not_connected"))?;
        if connection.handle.is_closed() { return Err(connection.failure("connection_closed")); }
        Ok(HeldSession { connection: Arc::clone(connection) })
    }

    async fn interactive(&self, command: &str, pty: PtyRequest, console: &mut dyn RawConsole) -> Result<u32> {
        let connection = self.connection.as_ref().ok_or_else(|| remote_failure("not_connected"))?;
        interactive(connection, command, pty, console).await
    }
}

impl RemoteSession for SshTransport {
    async fn exec(&self, command: &str, stdin: &[u8], timeout: Duration) -> Result<ExecResult> {
        let connection = self.connection.as_ref().ok_or_else(|| remote_failure("not_connected"))?;
        execute(connection, command, stdin, timeout).await
    }

    async fn upload(&self, local_dir: &Path, remote_dir: &str, timeout: Duration) -> Result<()> {
        let connection = self.connection.as_ref().ok_or_else(|| remote_failure("not_connected"))?;
        upload(connection, local_dir, remote_dir, timeout).await
    }
}

impl RemoteSession for HeldSession {
    async fn exec(&self, command: &str, stdin: &[u8], timeout: Duration) -> Result<ExecResult> {
        execute(&self.connection, command, stdin, timeout).await
    }

    async fn upload(&self, local_dir: &Path, remote_dir: &str, timeout: Duration) -> Result<()> {
        upload(&self.connection, local_dir, remote_dir, timeout).await
    }
}

fn validate_endpoint(options: &ConnectOptions) -> Result<()> {
    if !ssh_host_valid(&options.host) || !ssh_user_valid(&options.user) || options.port == 0 {
        return Err(RcError::new("invalid", "Некорректный адрес, пользователь или порт SSH."));
    }
    Ok(())
}

async fn connect_native(options: ConnectOptions, agent: Option<&Path>) -> Result<Connection> {
    // Resolve managed-key/setup errors before DNS or opening a network socket.
    let auth = match options.auth {
        Authentication::Password(password) => {
            if password.is_empty() { return Err(missing_secret()); }
            PreparedAuth::Password(password)
        }
        Authentication::Key { identity, passphrase } => {
            let key = load_key(identity, passphrase).await?;
            PreparedAuth::Key(key)
        }
        Authentication::System => PreparedAuth::System,
    };
    let rejected = Arc::new(Mutex::new(None));
    let handler = HostVerifier {
        host: options.host.clone(), port: options.port,
        policy: options.host_key, rejected: Arc::clone(&rejected),
    };
    let config = client::Config {
        keepalive_interval: Some(Duration::from_secs(5)), keepalive_max: 3,
        ..Default::default()
    };
    let mut handle = client::connect(Arc::new(config), (options.host.as_str(), options.port), handler)
        .await.map_err(|_| rejected_key(&rejected).unwrap_or_else(|| remote_failure("connect")))?;
    let authenticated = match auth {
        // russh owns and zeroizes this API's required String in auth::Method's
        // Drop, and redacts Method's Debug. Our retained source stays Zeroizing.
        PreparedAuth::Password(password) => handle.authenticate_password(&options.user, password.as_str())
            .await.map_err(|_| remote_failure("authentication"))?.success(),
        PreparedAuth::Key(key) => authenticate_key(&mut handle, &options.user, key).await?,
        PreparedAuth::System => authenticate_system(&mut handle, &options.user, agent).await?,
    };
    if !authenticated { return Err(remote_failure("authentication")); }
    Ok(Connection { handle, rejected })
}

enum PreparedAuth {
    Password(Zeroizing<String>),
    Key(PrivateKey),
    System,
}

fn missing_secret() -> RcError {
    RcError::new("missing_secret", "Не задан или недоступен секрет SSH.")
}

fn needs_setup() -> RcError {
    RcError::new("needs_setup", "Нужна настройка SSH-ключа или агента.")
}

async fn load_key(identity: PathBuf, passphrase: Option<Zeroizing<String>>) -> Result<PrivateKey> {
    // Key decryption can be expensive. The outer connection deadline remains
    // enforceable while a blocking worker owns the zeroizing input buffers.
    tokio::task::spawn_blocking(move || {
        let contents = Zeroizing::new(std::fs::read_to_string(identity).map_err(|_| needs_setup())?);
        if contents.trim_start().starts_with("-----BEGIN OPENSSH PRIVATE KEY-----") {
            let key = PrivateKey::from_openssh(contents.as_bytes()).map_err(|_| needs_setup())?;
            if key.is_encrypted() {
                let password = passphrase.as_ref().ok_or_else(missing_secret)?;
                key.decrypt(password.as_bytes()).map_err(|_| missing_secret())
            } else {
                Ok(key)
            }
        } else {
            if passphrase.is_none() && (contents.contains("ENCRYPTED") || contents.contains("Encryption: aes")) {
                return Err(missing_secret());
            }
            keys::decode_secret_key(&contents, passphrase.as_ref().map(|p| p.as_str()))
                .map_err(|error| {
                    if matches!(error, keys::Error::KeyIsEncrypted) || passphrase.is_some() {
                        missing_secret()
                    } else { needs_setup() }
                })
        }
    }).await.map_err(|_| needs_setup())?
}

async fn rsa_hash(handle: &Handle<HostVerifier>, rsa: bool) -> Result<Option<HashAlg>> {
    if !rsa { return Ok(None); }
    handle.best_supported_rsa_hash().await.map(|hash| hash.flatten())
        .map_err(|_| remote_failure("authentication"))
}

async fn authenticate_key(handle: &mut Handle<HostVerifier>, user: &str, key: PrivateKey) -> Result<bool> {
    let hash = rsa_hash(handle, key.algorithm().is_rsa()).await?;
    handle.authenticate_publickey(user, PrivateKeyWithHashAlg::new(Arc::new(key), hash)).await
        .map(|result| result.success()).map_err(|_| remote_failure("authentication"))
}

#[cfg(unix)]
async fn native_agent(socket: &Path) -> Option<NativeAgent> {
    AgentClient::connect_uds(socket).await.ok().map(|agent| agent.dynamic())
}

#[cfg(windows)]
async fn native_agent(pipe: &Path) -> Option<NativeAgent> {
    // The Windows OpenSSH agent pipe named by the client, not Pageant.
    AgentClient::connect_named_pipe(pipe).await.ok().map(|agent| agent.dynamic())
}

#[cfg(not(any(unix, windows)))]
async fn native_agent(_: &Path) -> Option<NativeAgent> { None }

async fn authenticate_system(handle: &mut Handle<HostVerifier>, user: &str, agent: Option<&Path>) -> Result<bool> {
    let mut attempted = false;
    let agent = match agent { Some(socket) => native_agent(socket).await, None => None };
    if let Some(mut agent) = agent {
        if let Some(binding) = handle.agent_session_binding() {
            // Older agents may reject this extension; unrestricted identities
            // remain usable, while a constrained agent still enforces its policy.
            let _ = agent.bind_session(binding, false).await;
        }
        if let Ok(identities) = agent.request_identities().await {
            for identity in identities {
                attempted = true;
                let hash = rsa_hash(handle, identity.public_key().algorithm().is_rsa()).await?;
                let result = match identity {
                    AgentIdentity::PublicKey { key, .. } =>
                        handle.authenticate_publickey_with(user, key, hash, &mut agent).await,
                    AgentIdentity::Certificate { certificate, .. } =>
                        handle.authenticate_certificate_with(user, certificate, hash, &mut agent).await,
                };
                if result.is_ok_and(|auth| auth.success()) { return Ok(true); }
                if handle.is_closed() { return Err(remote_failure("connection_closed")); }
            }
        }
    }
    let mut encrypted = false;
    if let Some(home) = dirs::home_dir() {
        for filename in ["id_ed25519", "id_ecdsa", "id_rsa", "id_dsa", "id_ed25519_sk", "id_ecdsa_sk"] {
            match load_key(home.join(".ssh").join(filename), None).await {
                Ok(key) => {
                    attempted = true;
                    if authenticate_key(handle, user, key).await? { return Ok(true); }
                }
                Err(error) if error.code == "missing_secret" => encrypted = true,
                Err(_) => {}
            }
        }
    }
    if attempted { Ok(false) } else if encrypted { Err(missing_secret()) } else { Err(needs_setup()) }
}

// Cancellation must close only this channel, not disconnect the leased login.
// These tasks contain owned native channel handles, never dispatch/state guards.
struct PendingChannel(Option<Channel<client::Msg>>);
impl Drop for PendingChannel {
    fn drop(&mut self) {
        if let Some(channel) = self.0.take() {
            tokio::spawn(async move { let _ = channel.close().await; });
        }
    }
}

struct CommandWriter(Option<ChannelWriteHalf<client::Msg>>);
impl Drop for CommandWriter {
    fn drop(&mut self) {
        if let Some(writer) = self.0.take() {
            tokio::spawn(async move { let _ = writer.close().await; });
        }
    }
}

async fn execute(connection: &Connection, command: &str, stdin: &[u8], timeout: Duration) -> Result<ExecResult> {
    timeout_at(Instant::now() + timeout, async {
        if connection.handle.is_closed() { return Err(connection.failure("connection_closed")); }
        let channel = connection.handle.channel_open_session().await
            .map_err(|_| connection.failure("channel_open"))?;
        let (mut reader, writer) = channel.split();
        let guard = CommandWriter(Some(writer));
        let writer = guard.0.as_ref().expect("owned command writer");
        writer.exec(true, command.as_bytes()).await.map_err(|_| connection.failure("exec_request"))?;
        let input = async {
            writer.data(stdin).await?;
            writer.eof().await
        };
        tokio::pin!(input);
        let mut input_done = false;
        let mut input_failed = false;
        let mut result = ExecResult::default();
        let mut status = None;
        loop {
            tokio::select! {
                sent = &mut input, if !input_done => {
                    input_done = true;
                    input_failed = sent.is_err();
                }
                message = reader.wait() => match message {
                    Some(ChannelMsg::Data { data }) => result.stdout.extend_from_slice(&data),
                    Some(ChannelMsg::ExtendedData { data, ext: 1 }) => result.stderr.extend_from_slice(&data),
                    Some(ChannelMsg::ExitStatus { exit_status }) => status = Some(exit_status),
                    Some(ChannelMsg::ExitSignal { .. }) => return Err(remote_failure("exit_signal")),
                    Some(ChannelMsg::Failure | ChannelMsg::OpenFailure(_)) => return Err(remote_failure("exec_rejected")),
                    Some(ChannelMsg::Close) => break,
                    None => return Err(connection.failure(if input_failed { "stdin" } else { "missing_exit_status" })),
                    _ => {}
                }
            }
        }
        // A command may deliberately stop reading stdin and exit early. Its
        // actual exit status is authoritative, including any nonzero value.
        result.exit_status = status.ok_or_else(|| connection.failure("missing_exit_status"))?;
        Ok(result)
    }).await.map_err(|_| remote_failure("timeout"))?
}

/// Bound for opening the channel and the pty request; the session itself has none.
const INTERACTIVE_SETUP: Duration = Duration::from_secs(15);
/// Console events buffered while the channel cannot take more input.
const INPUT_QUEUE: usize = 64;

enum Outgoing {
    Data(Vec<u8>),
    Resize(u32, u32),
    Eof,
}

type Sending<'w> = Pin<Box<dyn Future<Output = std::result::Result<(), russh::Error>> + 'w>>;

fn send<'w>(writer: &'w ChannelWriteHalf<client::Msg>, outgoing: Outgoing) -> Sending<'w> {
    match outgoing {
        Outgoing::Data(data) => Box::pin(writer.data_bytes(data)),
        Outgoing::Resize(cols, rows) => Box::pin(writer.window_change(cols, rows, 0, 0)),
        Outgoing::Eof => Box::pin(writer.eof()),
    }
}

/// One pty-backed command. Input is queued and sent by a single in-flight
/// write while output keeps draining, so a large paste cannot deadlock
/// against a remote side that is itself blocked on output.
async fn interactive(connection: &Connection, command: &str, pty: PtyRequest,
    console: &mut dyn RawConsole) -> Result<u32>
{
    let (mut reader, guard) = timeout_at(Instant::now() + INTERACTIVE_SETUP, async {
        if connection.handle.is_closed() { return Err(connection.failure("connection_closed")); }
        let channel = connection.handle.channel_open_session().await
            .map_err(|_| connection.failure("channel_open"))?;
        let (mut reader, writer) = channel.split();
        let guard = CommandWriter(Some(writer));
        let writer = guard.0.as_ref().expect("owned command writer");
        writer.request_pty(true, &pty.term, pty.size.cols.into(), pty.size.rows.into(), 0, 0, &[]).await
            .map_err(|_| connection.failure("pty_request"))?;
        loop {
            match reader.wait().await {
                Some(ChannelMsg::Success) => break,
                Some(ChannelMsg::Failure) => return Err(remote_failure("pty_rejected")),
                Some(ChannelMsg::Close) | None => return Err(connection.failure("pty_request")),
                _ => {}
            }
        }
        writer.exec(true, command.as_bytes()).await.map_err(|_| connection.failure("exec_request"))?;
        Ok((reader, guard))
    }).await.map_err(|_| remote_failure("timeout"))??;
    let writer = guard.0.as_ref().expect("owned command writer");
    let mut queue = VecDeque::new();
    let mut sending: Option<Sending<'_>> = None;
    let mut input_open = true;
    let mut status = None;
    loop {
        if sending.is_none() {
            sending = queue.pop_front().map(|outgoing| send(writer, outgoing));
        }
        let accepting = input_open && queue.len() < INPUT_QUEUE;
        tokio::select! {
            sent = async { sending.as_mut().expect("in-flight input").await }, if sending.is_some() => {
                sending = None;
                if sent.is_err() {
                    // The remote side stopped taking input; keep draining output.
                    input_open = false;
                    queue.clear();
                }
            }
            event = poll_fn(|cx| console.poll_event(cx)), if accepting => match event {
                ConsoleEvent::Input(data) => queue.push_back(Outgoing::Data(data)),
                ConsoleEvent::Resize(size) => {
                    // Only the latest pending size matters.
                    if let Some(Outgoing::Resize(..)) = queue.back() { queue.pop_back(); }
                    queue.push_back(Outgoing::Resize(size.cols.into(), size.rows.into()));
                }
                ConsoleEvent::Closed => {
                    input_open = false;
                    queue.push_back(Outgoing::Eof);
                }
            },
            message = reader.wait() => match message {
                Some(ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. }) => {
                    console.output(&data).map_err(|_| remote_failure("console"))?;
                }
                Some(ChannelMsg::ExitStatus { exit_status }) => status = Some(exit_status),
                Some(ChannelMsg::ExitSignal { .. }) => return Err(remote_failure("exit_signal")),
                Some(ChannelMsg::Failure | ChannelMsg::OpenFailure(_)) => return Err(remote_failure("exec_rejected")),
                Some(ChannelMsg::Close) => break,
                None => return Err(connection.failure("missing_exit_status")),
                _ => {}
            }
        }
    }
    status.ok_or_else(|| connection.failure("missing_exit_status"))
}

struct LocalEntry {
    local: PathBuf,
    relative: String,
    directory: bool,
}

fn unsafe_path() -> RcError {
    RcError::new("unsafe_path", "Загрузка допускает только обычные файлы и каталоги без переходов по ссылкам.")
}

fn local_path_valid(path: &Path) -> bool {
    !path.as_os_str().is_empty() && !path.components().any(|part| matches!(part, Component::ParentDir))
}

fn remote_path_valid(path: &str) -> bool {
    !path.is_empty() && !path.contains('\0') && path.split('/').all(|part| part != "..")
}

fn metadata_safe(metadata: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 { return false; } // FILE_ATTRIBUTE_REPARSE_POINT
    }
    !metadata.file_type().is_symlink() && (metadata.is_dir() || metadata.is_file())
}

async fn scan_local(root: &Path) -> Result<Vec<LocalEntry>> {
    if !local_path_valid(root) { return Err(unsafe_path()); }
    let metadata = tokio::fs::symlink_metadata(root).await.map_err(|_| unsafe_path())?;
    if !metadata_safe(&metadata) || !metadata.is_dir() { return Err(unsafe_path()); }
    // Resolve ancestors outside the selected tree (for example macOS /var's
    // system alias). The root itself and every entry below it must not be links.
    let absolute = tokio::fs::canonicalize(root).await.map_err(|_| unsafe_path())?;
    let mut pending = vec![(absolute, String::new())];
    let mut entries = Vec::new();
    while let Some((directory, prefix)) = pending.pop() {
        let metadata = tokio::fs::symlink_metadata(&directory).await.map_err(|_| unsafe_path())?;
        if !metadata_safe(&metadata) || !metadata.is_dir() { return Err(unsafe_path()); }
        let mut children = tokio::fs::read_dir(&directory).await.map_err(|_| unsafe_path())?;
        while let Some(child) = children.next_entry().await.map_err(|_| unsafe_path())? {
            let name = child.file_name().into_string().map_err(|_| unsafe_path())?;
            if name.is_empty() || name == "." || name == ".." || name.contains(['\0', '/']) {
                return Err(unsafe_path());
            }
            let relative = if prefix.is_empty() { name } else { format!("{prefix}/{name}") };
            let local = child.path();
            let metadata = tokio::fs::symlink_metadata(&local).await.map_err(|_| unsafe_path())?;
            if !metadata_safe(&metadata) || (relative == "VERSION" && !metadata.is_file()) {
                return Err(unsafe_path());
            }
            if metadata.is_dir() { pending.push((local.clone(), relative.clone())); }
            entries.push(LocalEntry { local, relative, directory: metadata.is_dir() });
        }
    }
    // Parents before descendants; root VERSION after all other entries.
    entries.sort_unstable_by(|a, b| {
        (a.relative == "VERSION").cmp(&(b.relative == "VERSION"))
            .then_with(|| a.relative.cmp(&b.relative))
    });
    Ok(entries)
}

fn join_remote(parent: &str, relative: &str) -> String {
    if parent == "/" { format!("/{relative}") } else { format!("{}/{relative}", parent.trim_end_matches('/')) }
}

fn sftp_error(error: SftpError) -> RcError {
    remote_failure(if matches!(error, SftpError::Timeout) { "timeout" } else { "sftp" })
}

async fn remote_metadata(session: &RawSftpSession, path: &str) -> Result<Option<FileAttributes>> {
    match session.lstat(path).await {
        Ok(attrs) => Ok(Some(attrs.attrs)),
        Err(SftpError::Status(status)) if status.status_code == StatusCode::NoSuchFile => Ok(None),
        Err(error) => Err(sftp_error(error)),
    }
}

fn remote_type(metadata: &FileAttributes) -> u32 {
    // A symlink's mode includes REG bits: bitflag containment is not a type test.
    metadata.permissions.unwrap_or_default() & 0o170000
}

async fn ensure_remote_dir(session: &RawSftpSession, path: &str) -> Result<()> {
    let mut current = if path.starts_with('/') { String::from("/") } else { String::new() };
    for part in path.split('/').filter(|part| !part.is_empty() && *part != ".") {
        if !current.is_empty() && current != "/" { current.push('/'); }
        current.push_str(part);
        match remote_metadata(session, &current).await? {
            Some(metadata) if remote_type(&metadata) == 0o040000 => {}
            Some(_) => return Err(remote_failure("remote_path_conflict")),
            None => {
                if let Err(error) = session.mkdir(current.as_str(), FileAttributes::empty()).await {
                    // Another uploader may have created the directory meanwhile.
                    if !remote_metadata(session, &current).await?
                        .is_some_and(|metadata| remote_type(&metadata) == 0o040000) {
                        return Err(sftp_error(error));
                    }
                }
            }
        }
    }
    Ok(())
}

struct UploadSession {
    session: Arc<RawSftpSession>,
    temporary: Option<String>,
}

impl Drop for UploadSession {
    fn drop(&mut self) {
        if let Some(temporary) = self.temporary.take() {
            let session = Arc::clone(&self.session);
            tokio::spawn(async move {
                // Cancellation returns immediately. Cleanup uses the same SFTP
                // subsystem, is best effort on a lost connection, and is bounded.
                let _ = tokio::time::timeout(Duration::from_secs(2), session.remove(temporary)).await;
                let _ = session.close_session();
            });
        } else {
            let _ = self.session.close_session();
        }
    }
}

async fn upload(connection: &Connection, local_dir: &Path, remote_dir: &str, timeout: Duration) -> Result<()> {
    if !remote_path_valid(remote_dir) { return Err(unsafe_path()); }
    timeout_at(Instant::now() + timeout, async {
        let entries = scan_local(local_dir).await?;
        if connection.handle.is_closed() { return Err(connection.failure("connection_closed")); }
        let channel = connection.handle.channel_open_session().await
            .map_err(|_| connection.failure("channel_open"))?;
        let mut pending = PendingChannel(Some(channel));
        let channel = pending.0.as_mut().expect("owned SFTP channel");
        channel.request_subsystem(true, "sftp").await.map_err(|_| connection.failure("sftp_subsystem"))?;
        loop {
            match channel.wait().await {
                Some(ChannelMsg::Success) => break,
                Some(ChannelMsg::Failure | ChannelMsg::Close) | None =>
                    return Err(connection.failure("sftp_subsystem")),
                _ => {}
            }
        }
        let channel = pending.0.take().expect("confirmed SFTP channel");
        let mut session = RawSftpSession::new(channel.into_stream());
        session.set_timeout(timeout.as_secs().saturating_add(1));
        let version = session.init().await.map_err(sftp_error)?;
        if version.version != 3 { return Err(remote_failure("sftp_version")); }
        let posix_rename = version.extensions.get("posix-rename@openssh.com").is_some_and(|v| v == "1");
        let limits = if version.extensions.get("limits@openssh.com").is_some_and(|v| v == "1") {
            Limits::from(session.limits().await.map_err(sftp_error)?)
        } else { Limits::default() };
        session.set_limits(limits);
        let mut upload = UploadSession { session: Arc::new(session), temporary: None };
        let result = async {
        ensure_remote_dir(&upload.session, remote_dir).await?;
        for entry in entries {
            let target = join_remote(remote_dir, &entry.relative);
            if entry.directory {
                ensure_remote_dir(&upload.session, &target).await?;
                continue;
            }
            if remote_metadata(&upload.session, &target).await?
                .is_some_and(|metadata| remote_type(&metadata) != 0o100000) {
                return Err(remote_failure("remote_path_conflict"));
            }
            if entry.relative == "VERSION" {
                stage_version(&mut upload, &entry, remote_dir, limits).await?;
                let temp = upload.temporary.as_deref().expect("staged VERSION");
                publish_version(&upload.session, temp, &target, posix_rename).await?;
                upload.temporary = None;
            } else {
                write_remote_file(&upload.session, &entry, &target, limits).await?;
            }
        }
        Ok(())
        }.await;
        if result.is_err() {
            if let Some(temporary) = upload.temporary.as_deref() {
                // Ordinary failures clean up before returning. The drop guard
                // retains the name until removal succeeds, including if this
                // cleanup itself reaches the total operation deadline.
                if upload.session.remove(temporary).await.is_ok() {
                    upload.temporary = None;
                }
            }
        }
        result
    }).await.map_err(|_| remote_failure("timeout"))?
}

async fn open_local_file(path: &Path) -> Result<tokio::fs::File> {
    let mut options = tokio::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    #[cfg(windows)]
    options.custom_flags(0x00200000); // FILE_FLAG_OPEN_REPARSE_POINT
    let file = options.open(path).await.map_err(|_| unsafe_path())?;
    let metadata = file.metadata().await.map_err(|_| unsafe_path())?;
    if !metadata_safe(&metadata) || !metadata.is_file() { return Err(unsafe_path()); }
    Ok(file)
}

async fn stage_version(upload: &mut UploadSession, entry: &LocalEntry, remote_dir: &str,
    limits: Limits) -> Result<()>
{
    let local = open_local_file(&entry.local).await?;
    let mut nonce = [0_u8; 16];
    rand::rngs::OsRng.fill_bytes(&mut nonce);
    let temporary = join_remote(remote_dir, &format!(".VERSION.{}.tmp", hex::encode(nonce)));
    let attrs = FileAttributes { permissions: Some(0o644), ..Default::default() };
    upload.temporary = Some(temporary);
    let target = upload.temporary.as_deref().expect("pending VERSION creation");
    let opened = upload.session.open(target,
        OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::EXCLUDE, attrs.clone()).await;
    let handle = match opened {
        Ok(handle) => handle.handle,
        Err(error) => {
            // A definite server rejection means the exclusive create did not
            // succeed. Never delete a preexisting name, even on nonce collision.
            // With a lost reply ownership is unknown: retain our unpredictable
            // pending name for best-effort cancellation cleanup.
            if matches!(&error, SftpError::Status(_)) { upload.temporary = None; }
            return Err(sftp_error(error));
        }
    };
    write_open_file(&upload.session, local, handle, attrs, limits).await
}

async fn write_remote_file(session: &RawSftpSession, entry: &LocalEntry, target: &str,
    limits: Limits) -> Result<()>
{
    let local = open_local_file(&entry.local).await?;
    let mode = if entry.relative.ends_with(".sh") { 0o755 } else { 0o644 };
    let attrs = FileAttributes { permissions: Some(mode), ..Default::default() };
    let handle = session.open(target, OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE,
        attrs.clone()).await.map_err(sftp_error)?.handle;
    write_open_file(session, local, handle, attrs, limits).await
}

async fn write_open_file(session: &RawSftpSession, mut local: tokio::fs::File, handle: String,
    attrs: FileAttributes, limits: Limits) -> Result<()>
{
    let result = async {
        let overhead = 25_u64 + handle.len() as u64;
        let chunk = limits.write_len.unwrap_or(32768).min(32768)
            .min(limits.packet_len.unwrap_or(u64::MAX).saturating_sub(overhead)) as usize;
        if chunk == 0 { return Err(remote_failure("sftp_limits")); }
        let mut offset = 0_u64;
        loop {
            // RawSftpSession::write requires an owned Vec; move each chunk rather
            // than making an additional whole-file or plaintext staging copy.
            let mut data = vec![0_u8; chunk];
            let count = local.read(&mut data).await.map_err(|_| remote_failure("local_read"))?;
            if count == 0 { break; }
            data.truncate(count);
            session.write(handle.as_str(), offset, data).await.map_err(sftp_error)?;
            offset += count as u64;
        }
        // OPEN permissions do not affect an existing file. FSETSTAT ensures
        // scripts are executable even on a reused destination and from Windows.
        session.fsetstat(handle.as_str(), attrs).await.map_err(sftp_error)?;
        Ok(())
    }.await;
    let closed = session.close(handle).await.map_err(sftp_error);
    result?;
    closed?;
    Ok(())
}

async fn publish_version(session: &RawSftpSession, temporary: &str, target: &str,
    posix_rename: bool) -> Result<()>
{
    if posix_rename {
        // OpenSSH's extension payload is exactly two SSH strings, without an
        // extra enclosing length. High-level russh-sftp 3.0.1 has no such API.
        let mut data = Vec::with_capacity(8 + temporary.len() + target.len());
        for path in [temporary, target] {
            let length = u32::try_from(path.len()).map_err(|_| unsafe_path())?;
            data.extend_from_slice(&length.to_be_bytes());
            data.extend_from_slice(path.as_bytes());
        }
        match session.extended("posix-rename@openssh.com", data).await.map_err(sftp_error)? {
            Packet::Status(status) if status.status_code == StatusCode::Ok => return Ok(()),
            Packet::Status(status) if status.status_code == StatusCode::OpUnsupported => {}
            Packet::Status(status) => return Err(sftp_error(SftpError::Status(status))),
            _ => return Err(remote_failure("sftp_protocol")),
        }
    }
    // SFTP v3 RENAME must fail if target already exists. Never remove a valid
    // VERSION to emulate overwrite: failure preserves the previously published
    // version and the caller removes only its temporary file.
    if remote_metadata(session, target).await?.is_some() {
        return Err(remote_failure("atomic_rename_unsupported"));
    }
    session.rename(temporary, target).await.map_err(sftp_error)?;
    Ok(())
}

