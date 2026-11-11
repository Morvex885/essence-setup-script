//! Real loopback russh/SFTP consumer scenarios; no host daemon or OpenSSH dependency.
use std::{
    collections::{HashMap, VecDeque},
    fs::{self, File, OpenOptions},
    future::Future,
    io::{Read, Seek, SeekFrom, Write},
    net::{Shutdown, SocketAddr},
    path::{Component, Path, PathBuf},
    sync::{Arc, Mutex, atomic::{AtomicBool, AtomicUsize, Ordering}},
    task::{Context, Poll, Waker},
    time::{Duration, Instant},
};

use rand::RngCore;
use rc_core::{
    error::RcError,
    locking::LockKind,
    model::Fingerprint,
    ssh::SshTransport,
    state::{State, StatePaths},
    transport::{Authentication, ConnectOptions, ConsoleEvent, ConsoleSize, HostKeyPolicy, PtyRequest, RawConsole,
        RemoteSession, RemoteTransport},
};
use russh::{Channel, ChannelId, ChannelMsg, Pty, keys::{HashAlg, PrivateKey, PublicKey, ssh_key},
    server::{self, Auth, ChannelOpenHandle, Msg, Session, VerifiedPublicKey}};
use russh_sftp::protocol::{Attrs, Data, FileAttributes, Handle, Name, OpenFlags, Packet, Status, StatusCode, Version};
use tempfile::TempDir;
use tokio::{net::TcpListener, task::JoinHandle, time::{sleep, timeout}};
use zeroize::Zeroizing;

const WAIT: Duration = Duration::from_secs(12);
const SCENARIO: Duration = Duration::from_secs(40);
const SECRET: &str = "wire-secret-SENTINEL-never-journal-7b82";
const BULK: usize = 8 * 1024 * 1024;
const REMOTE: &str = "/bundle with spaces;$literal";

fn key() -> PrivateKey {
    let mut seed = Zeroizing::new([0u8; 32]);
    rand::rngs::OsRng.fill_bytes(&mut *seed);
    ssh_key::private::Ed25519Keypair::from_seed(&seed).into()
}

fn fingerprint(key: &PublicKey) -> Fingerprint {
    key.fingerprint(HashAlg::Sha256).to_string().parse().unwrap()
}

fn write_key(root: &Path, name: &str, key: &PrivateKey) -> PathBuf {
    let path = root.join(name);
    key.write_openssh_file(&path, ssh_key::LineEnding::LF).unwrap();
    path
}

fn private_error(error: &RcError) {
    for representation in [error.to_string(), format!("{error:?}"), serde_json::to_string(error).unwrap()] {
        assert!(!representation.contains(SECRET), "authentication secret escaped into an error");
    }
}

#[derive(Default)]
struct Workers {
    jobs: Mutex<Vec<JoinHandle<()>>>,
    sockets: Mutex<Vec<std::net::TcpStream>>,
}

impl Workers {
    fn spawn(self: &Arc<Self>, work: impl Future<Output = ()> + Send + 'static) {
        self.jobs.lock().unwrap().push(tokio::spawn(async move {
            timeout(SCENARIO * 2, work).await.expect("fixture worker exceeded its deadline");
        }));
    }

    fn stop(&self) -> Vec<JoinHandle<()>> {
        for socket in self.sockets.lock().unwrap().drain(..) {
            let _ = socket.shutdown(Shutdown::Both);
        }
        let jobs = std::mem::take(&mut *self.jobs.lock().unwrap());
        for job in &jobs { job.abort(); }
        jobs
    }
}

struct Shared {
    root: Arc<TempDir>,
    authorized: PublicKey,
    revoked: AtomicBool,
    accepted: AtomicUsize,
    journal: Mutex<Vec<String>>,
    drip_closed: tokio::sync::Notify,
    modes: Mutex<HashMap<String, u32>>,
    refuse_publication: AtomicBool,
    workers: Arc<Workers>,
}

impl Shared {
    fn record(&self, operation: String) { self.journal.lock().unwrap().push(operation); }

    fn path(&self, remote: &str) -> Result<PathBuf, StatusCode> {
        let mut path = self.root.path().to_owned();
        for part in Path::new(remote).components() {
            match part {
                Component::RootDir | Component::CurDir => (),
                Component::Normal(name) => path.push(name),
                _ => return Err(StatusCode::PermissionDenied),
            }
        }
        Ok(path)
    }
}

struct Fixture {
    address: SocketAddr,
    pin: Fingerprint,
    shared: Arc<Shared>,
}

impl Fixture {
    async fn start(client: &PrivateKey) -> Self {
        let host = key();
        let pin = fingerprint(host.public_key());
        let workers = Arc::new(Workers::default());
        let shared = Arc::new(Shared {
            root: Arc::new(tempfile::tempdir().unwrap()),
            authorized: client.public_key().clone(),
            revoked: AtomicBool::new(false), accepted: AtomicUsize::new(0),
            journal: Mutex::new(Vec::new()), modes: Mutex::new(HashMap::new()),
            drip_closed: tokio::sync::Notify::new(),
            refuse_publication: AtomicBool::new(false), workers: workers.clone(),
        });
        let listener = timeout(WAIT, TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)))
            .await.unwrap().unwrap();
        let address = listener.local_addr().unwrap();
        assert!(address.ip().is_loopback());
        let config = Arc::new(server::Config {
            keys: vec![host],
            auth_rejection_time: Duration::ZERO,
            auth_rejection_time_initial: Some(Duration::ZERO),
            window_size: 64 * 1024,
            // Permit input transport buffering while the application deliberately writes first.
            channel_buffer_size: 1024,
            inactivity_timeout: Some(SCENARIO),
            ..Default::default()
        });
        let state = shared.clone();
        workers.spawn(async move {
            loop {
                let (socket, peer) = listener.accept().await.unwrap();
                assert!(peer.ip().is_loopback());
                let socket = socket.into_std().unwrap();
                state.workers.sockets.lock().unwrap().push(socket.try_clone().unwrap());
                let socket = tokio::net::TcpStream::from_std(socket).unwrap();
                let handler = SshHandler { shared: state.clone(), channels: HashMap::new(), commands: HashMap::new() };
                let config = config.clone();
                state.workers.spawn(async move {
                    // Rejected host pins and authentication can legitimately close the socket.
                    if let Ok(session) = server::run_stream(config, socket, handler).await {
                        let _ = session.await;
                    }
                });
            }
        });
        Self { address, pin, shared }
    }

    fn options(&self, auth: Authentication) -> ConnectOptions {
        ConnectOptions {
            host: self.address.ip().to_string(), port: self.address.port(), user: "wire-user".into(),
            auth, host_key: HostKeyPolicy { expected: Some(self.pin.clone()), known: vec![] }, timeout: WAIT,
        }
    }

    async fn password(&self) -> SshTransport {
        let mut ssh = SshTransport::default();
        ssh.connect(self.options(Authentication::Password(Zeroizing::new(SECRET.into())))).await.unwrap();
        ssh
    }

    async fn finish(self) {
        let jobs = self.shared.workers.stop();
        for job in jobs {
            match timeout(WAIT, job).await.expect("fixture task did not stop") {
                Ok(()) => (),
                Err(error) if error.is_cancelled() => (),
                Err(error) => panic!("fixture worker panicked: {error}"),
            }
        }
        assert!(!format!("{:?}", self.shared.journal.lock().unwrap()).contains(SECRET));
    }
}

impl Drop for Fixture {
    fn drop(&mut self) { self.shared.workers.stop(); }
}

struct SshHandler {
    shared: Arc<Shared>,
    channels: HashMap<ChannelId, Channel<Msg>>,
    commands: HashMap<ChannelId, String>,
}

impl server::Handler for SshHandler {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        let accepted = !self.shared.revoked.load(Ordering::SeqCst) && user == "wire-user" && password == SECRET;
        self.shared.record(format!("password-auth:{accepted}"));
        if accepted { self.shared.accepted.fetch_add(1, Ordering::SeqCst); }
        Ok(if accepted { Auth::Accept } else { Auth::reject() })
    }

    async fn auth_publickey(&mut self, user: &str, key: VerifiedPublicKey<'_>) -> Result<Auth, Self::Error> {
        let accepted = !self.shared.revoked.load(Ordering::SeqCst) && user == "wire-user"
            && key.public_key == &self.shared.authorized;
        self.shared.record(format!("key-auth:{accepted}"));
        if accepted { self.shared.accepted.fetch_add(1, Ordering::SeqCst); }
        Ok(if accepted { Auth::Accept } else { Auth::reject() })
    }

    async fn channel_open_session(&mut self, channel: Channel<Msg>, reply: ChannelOpenHandle,
        _: &mut Session) -> Result<(), Self::Error> {
        self.channels.insert(channel.id(), channel);
        reply.accept().await;
        Ok(())
    }

    async fn exec_request(&mut self, id: ChannelId, command: &[u8], session: &mut Session) -> Result<(), Self::Error> {
        let command = String::from_utf8(command.to_vec()).unwrap();
        assert!(["duplex", "recover", "missing-status", "drip", "menu"].contains(&command.as_str()));
        self.shared.record(format!("exec:{command}"));
        self.commands.insert(id, command.clone());
        session.channel_success(id)?;
        let channel = self.channels.remove(&id).unwrap();
        self.shared.workers.spawn(async move {
            let result: Result<(), russh::Error> = async {
                let (mut reader, writer) = channel.split();
                match command.as_str() {
                    "duplex" => {
                        // More than the client's initial channel window. A client which finishes
                        // writing large stdin before draining output cannot complete this exchange.
                        writer.data_bytes(vec![0x81; BULK]).await?;
                        writer.extended_data_bytes(1, vec![0xe7; BULK]).await?;
                        let mut received = Vec::new();
                        while let Some(message) = reader.wait().await {
                            match message {
                                ChannelMsg::Data { data } => received.extend_from_slice(&data),
                                ChannelMsg::Eof => break,
                                _ => (),
                            }
                        }
                        assert_eq!(received.len(), BULK);
                        assert!(received.iter().enumerate().all(|(i, byte)| *byte == (i % 251) as u8));
                        writer.exit_status(37).await?;
                    }
                    "recover" => {
                        writer.data_bytes(b"held session alive\0\xff".to_vec()).await?;
                        writer.exit_status(0).await?;
                    }
                    "missing-status" => { writer.data_bytes(b"not a successful exit".to_vec()).await?; }
                    "drip" => {
                        loop {
                            writer.data_bytes(b"still running".to_vec()).await?;
                            sleep(Duration::from_millis(30)).await;
                        }
                    }
                    "menu" => {
                        // A line-less menu: echoes every keystroke chunk, `q` quits.
                        writer.data_bytes(b"MENU> ".to_vec()).await?;
                        while let Some(message) = reader.wait().await {
                            if let ChannelMsg::Data { data } = message {
                                writer.data_bytes([b"echo:".as_slice(), &data, b"\r\n"].concat()).await?;
                                if data.contains(&b'q') { break; }
                            }
                        }
                        writer.exit_status(5).await?;
                    }
                    _ => unreachable!(),
                }
                writer.eof().await?;
                writer.close().await
            }.await;
            // A timeout is allowed to close its channel before the fixture finishes sending.
            if let Err(error) = result {
                assert!(matches!(error, russh::Error::SendError | russh::Error::Inconsistent | russh::Error::Disconnect));
            }
        });
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    async fn pty_request(&mut self, id: ChannelId, term: &str, cols: u32, rows: u32, _: u32, _: u32,
        _: &[(Pty, u32)], session: &mut Session) -> Result<(), Self::Error>
    {
        self.shared.record(format!("pty:{term}:{cols}x{rows}"));
        session.channel_success(id)?;
        Ok(())
    }

    async fn window_change_request(&mut self, id: ChannelId, cols: u32, rows: u32, _: u32, _: u32,
        session: &mut Session) -> Result<(), Self::Error>
    {
        self.shared.record(format!("resize:{cols}x{rows}"));
        session.data(id, format!("resized {cols}x{rows}\r\n").into_bytes())?;
        Ok(())
    }

    async fn subsystem_request(&mut self, id: ChannelId, name: &str, session: &mut Session) -> Result<(), Self::Error> {
        if name != "sftp" { session.channel_failure(id)?; return Ok(()); }
        session.channel_success(id)?;
        let channel = self.channels.remove(&id).unwrap();
        let handler = SftpHandler { shared: self.shared.clone(), files: HashMap::new(), next: 0 };
        self.shared.workers.spawn(russh_sftp::server::run(channel.into_stream(), handler));
        Ok(())
    }

    async fn channel_close(&mut self, id: ChannelId, _: &mut Session) -> Result<(), Self::Error> {
        self.channels.remove(&id);
        if self.commands.remove(&id).as_deref() == Some("drip") {
            self.shared.drip_closed.notify_one();
        }
        Ok(())
    }
}

struct OpenFile { file: File, remote: String }
struct SftpHandler { shared: Arc<Shared>, files: HashMap<String, OpenFile>, next: u64 }

fn status(id: u32) -> Status {
    Status { id, status_code: StatusCode::Ok, error_message: String::new(), language_tag: String::new() }
}

fn io_status(error: std::io::Error) -> StatusCode {
    match error.kind() {
        std::io::ErrorKind::NotFound => StatusCode::NoSuchFile,
        std::io::ErrorKind::PermissionDenied => StatusCode::PermissionDenied,
        _ => StatusCode::Failure,
    }
}

impl SftpHandler {
    fn attrs(&self, remote: &str) -> Result<FileAttributes, StatusCode> {
        let metadata = fs::symlink_metadata(self.shared.path(remote)?).map_err(io_status)?;
        Ok(FileAttributes::from(&metadata))
    }

    fn chmod(&self, remote: &str, attrs: FileAttributes) -> Result<(), StatusCode> {
        if let Some(mode) = attrs.permissions {
            self.shared.modes.lock().unwrap().insert(remote.to_owned(), mode & 0o7777);
            #[cfg(unix)] {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(self.shared.path(remote)?, fs::Permissions::from_mode(mode & 0o7777)).map_err(io_status)?;
            }
            self.shared.record(format!("chmod:{remote}"));
        }
        Ok(())
    }

    fn rename_file(&self, id: u32, old: &str, new: &str, overwrite: bool) -> Result<Status, StatusCode> {
        let old_path = self.shared.path(old)?;
        let new_path = self.shared.path(new)?;
        if new.ends_with("/VERSION") && self.shared.refuse_publication.load(Ordering::SeqCst) {
            return Err(StatusCode::PermissionDenied);
        }
        if !overwrite && new_path.exists() { return Err(StatusCode::Failure); }
        fs::rename(old_path, new_path).map_err(io_status)?;
        self.shared.record(format!("publish:{new}"));
        Ok(status(id))
    }
}

impl russh_sftp::server::Handler for SftpHandler {
    type Error = StatusCode;
    fn unimplemented(&self) -> Self::Error { StatusCode::OpUnsupported }

    async fn init(&mut self, _: u32, _: HashMap<String, String>) -> Result<Version, Self::Error> {
        let mut version = Version::new();
        version.extensions.insert("posix-rename@openssh.com".into(), "1".into());
        Ok(version)
    }

    async fn open(&mut self, id: u32, filename: String, flags: OpenFlags, attrs: FileAttributes) -> Result<Handle, Self::Error> {
        let options: OpenOptions = flags.into();
        let file = options.open(self.shared.path(&filename)?).map_err(io_status)?;
        self.chmod(&filename, attrs)?;
        self.shared.record(format!("open:{filename}"));
        self.next += 1;
        let handle = self.next.to_string();
        self.files.insert(handle.clone(), OpenFile { file, remote: filename });
        Ok(Handle { id, handle })
    }

    async fn write(&mut self, id: u32, handle: String, offset: u64, data: Vec<u8>) -> Result<Status, Self::Error> {
        let open = self.files.get_mut(&handle).ok_or(StatusCode::Failure)?;
        open.file.seek(SeekFrom::Start(offset)).map_err(io_status)?;
        open.file.write_all(&data).map_err(io_status)?;
        self.shared.record(format!("write:{}", open.remote));
        Ok(status(id))
    }

    async fn read(&mut self, id: u32, handle: String, offset: u64, len: u32) -> Result<Data, Self::Error> {
        let open = self.files.get_mut(&handle).ok_or(StatusCode::Failure)?;
        open.file.seek(SeekFrom::Start(offset)).map_err(io_status)?;
        let mut data = vec![0; len.min(1024 * 1024) as usize];
        let count = open.file.read(&mut data).map_err(io_status)?;
        if count == 0 { return Err(StatusCode::Eof); }
        data.truncate(count);
        Ok(Data { id, data })
    }

    async fn close(&mut self, id: u32, handle: String) -> Result<Status, Self::Error> {
        let open = self.files.remove(&handle).ok_or(StatusCode::Failure)?;
        open.file.sync_all().map_err(io_status)?;
        self.shared.record(format!("close:{}", open.remote));
        Ok(status(id))
    }

    async fn mkdir(&mut self, id: u32, path: String, attrs: FileAttributes) -> Result<Status, Self::Error> {
        fs::create_dir(self.shared.path(&path)?).map_err(io_status)?;
        self.chmod(&path, attrs)?;
        self.shared.record(format!("mkdir:{path}"));
        Ok(status(id))
    }

    async fn stat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> { Ok(Attrs { id, attrs: self.attrs(&path)? }) }
    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> { Ok(Attrs { id, attrs: self.attrs(&path)? }) }
    async fn fstat(&mut self, id: u32, handle: String) -> Result<Attrs, Self::Error> {
        let open = self.files.get(&handle).ok_or(StatusCode::Failure)?;
        Ok(Attrs { id, attrs: self.attrs(&open.remote)? })
    }
    async fn setstat(&mut self, id: u32, path: String, attrs: FileAttributes) -> Result<Status, Self::Error> {
        self.chmod(&path, attrs)?;
        Ok(status(id))
    }
    async fn fsetstat(&mut self, id: u32, handle: String, attrs: FileAttributes) -> Result<Status, Self::Error> {
        let open = self.files.get(&handle).ok_or(StatusCode::Failure)?;
        self.chmod(&open.remote, attrs)?;
        Ok(status(id))
    }
    async fn remove(&mut self, id: u32, filename: String) -> Result<Status, Self::Error> {
        fs::remove_file(self.shared.path(&filename)?).map_err(io_status)?;
        self.shared.record(format!("remove:{filename}"));
        Ok(status(id))
    }
    async fn rename(&mut self, id: u32, old: String, new: String) -> Result<Status, Self::Error> {
        self.rename_file(id, &old, &new, false)
    }
    async fn realpath(&mut self, id: u32, path: String) -> Result<Name, Self::Error> {
        self.shared.path(&path)?;
        Ok(Name { id, files: vec![russh_sftp::protocol::File::dummy(&path)] })
    }
    async fn extended(&mut self, id: u32, request: String, data: Vec<u8>) -> Result<Packet, Self::Error> {
        if request != "posix-rename@openssh.com" { return Err(StatusCode::OpUnsupported); }
        fn string(bytes: &mut &[u8]) -> Result<String, StatusCode> {
            let length = bytes.get(..4).ok_or(StatusCode::BadMessage)?;
            let length = u32::from_be_bytes(length.try_into().unwrap()) as usize;
            *bytes = &bytes[4..];
            let value = bytes.get(..length).ok_or(StatusCode::BadMessage)?;
            let value = std::str::from_utf8(value).map_err(|_| StatusCode::BadMessage)?.to_owned();
            *bytes = &bytes[length..];
            Ok(value)
        }
        let mut bytes = data.as_slice();
        let old = string(&mut bytes)?;
        let new = string(&mut bytes)?;
        if !bytes.is_empty() { return Err(StatusCode::BadMessage); }
        self.rename_file(id, &old, &new, true).map(Packet::Status)
    }
}

#[tokio::test(flavor = "current_thread")]
async fn authentication_duplex_and_held_recovery_use_the_real_wire_under_a_state_guard() {
    timeout(SCENARIO, async {
        let client = key();
        let local = tempfile::tempdir().unwrap();
        let identity = write_key(local.path(), "client", &client);
        let other_identity = write_key(local.path(), "untrusted-client", &key());
        let fixture = Fixture::start(&client).await;
        let state = State::new(StatePaths::new(local.path().join("state")));
        let guard = state.locks().acquire(LockKind::Mutation, "native SSH wire scenario").unwrap();
        // This future deliberately remains !Send on its dispatch thread across every await.
        let mut ssh = SshTransport::default();
        ssh.connect(fixture.options(Authentication::Key { identity: identity.clone(), passphrase: None })).await.unwrap();
        let input: Vec<u8> = (0..BULK).map(|i| (i % 251) as u8).collect();
        let output = ssh.exec("duplex", &input, WAIT).await.unwrap();
        assert_eq!(output.exit_status, 37);
        assert_eq!(output.stdout, vec![0x81; BULK]);
        assert_eq!(output.stderr, vec![0xe7; BULK]);
        state.save_config(&state.load_config().unwrap()).unwrap(); // Same manager reenters, not a second lock owner.

        let password = fixture.password().await;
        assert_eq!(password.exec("recover", &[], WAIT).await.unwrap().exit_status, 0);
        drop(password);
        for auth in [
            Authentication::Password(Zeroizing::new(format!("wrong-{SECRET}"))),
            Authentication::Key { identity: other_identity, passphrase: None },
        ] {
            let error = SshTransport::default().connect(fixture.options(auth)).await.unwrap_err();
            assert_eq!(error.code, "remote_failed");
            private_error(&error);
        }

        {
            let journal = fixture.shared.journal.lock().unwrap();
            for outcome in ["key-auth:true", "key-auth:false", "password-auth:true", "password-auth:false"] {
                assert!(journal.iter().any(|entry| entry == outcome), "missing actual wire authentication: {outcome}");
            }
        }

        let held = ssh.hold().unwrap();
        fixture.shared.revoked.store(true, Ordering::SeqCst);
        drop(ssh);
        let accepted = fixture.shared.accepted.load(Ordering::SeqCst);
        let output = held.exec("recover", &[], WAIT).await.unwrap();
        assert_eq!(output.stdout, b"held session alive\0\xff");
        assert_eq!(output.exit_status, 0);
        assert_eq!(fixture.shared.accepted.load(Ordering::SeqCst), accepted, "held session must not authenticate again");
        let mut fresh = SshTransport::default();
        let error = fresh.connect(fixture.options(Authentication::Key { identity, passphrase: None })).await.unwrap_err();
        assert_eq!(error.code, "remote_failed");
        private_error(&error);
        drop(held);
        drop(guard);
        fixture.finish().await;
    }).await.expect("authentication/duplex/recovery scenario exceeded its deadline");
}

#[tokio::test(flavor = "current_thread")]
async fn host_pins_fail_closed_with_structured_errors_before_authentication() {
    timeout(SCENARIO, async {
        let fixture = Fixture::start(&key()).await;
        let wrong = fingerprint(key().public_key());
        for (policy, code) in [
            (HostKeyPolicy { expected: Some(wrong.clone()), known: vec![fixture.pin.clone()] }, "host_key_mismatch"),
            (HostKeyPolicy { expected: None, known: vec![wrong.clone()] }, "host_key_changed"),
            (HostKeyPolicy::default(), "host_key_unknown"),
        ] {
            let mut options = fixture.options(Authentication::Password(Zeroizing::new(SECRET.into())));
            options.host_key = policy;
            let error = SshTransport::default().connect(options).await.unwrap_err();
            assert_eq!(error.code, code);
            private_error(&error);
            if code == "host_key_changed" {
                assert_eq!(error.extra["host"], fixture.address.ip().to_string());
                assert_eq!(error.extra["port"], fixture.address.port());
                assert_eq!(error.extra["fingerprints"], serde_json::json!([fixture.pin.as_str()]));
            }
        }
        assert_eq!(fixture.shared.accepted.load(Ordering::SeqCst), 0);
        let mut options = fixture.options(Authentication::Password(Zeroizing::new(SECRET.into())));
        options.host_key = HostKeyPolicy { expected: None, known: vec![wrong, fixture.pin.clone()] };
        let mut ssh = SshTransport::default();
        ssh.connect(options).await.unwrap();
        assert_eq!(ssh.exec("recover", &[], WAIT).await.unwrap().exit_status, 0);
        drop(ssh);
        fixture.finish().await;
    }).await.expect("host pin scenario exceeded its deadline");
}

#[tokio::test(flavor = "current_thread")]
async fn execution_deadline_is_total_and_missing_status_is_not_success() {
    timeout(SCENARIO, async {
        let fixture = Fixture::start(&key()).await;
        let ssh = fixture.password().await;
        let missing = ssh.exec("missing-status", &[], WAIT).await.unwrap_err();
        assert_eq!(missing.code, "remote_failed");
        assert_eq!(missing.extra["reason"], "missing_exit_status");
        private_error(&missing);
        let start = Instant::now();
        let expired = ssh.exec("drip", &[], Duration::from_millis(180)).await.unwrap_err();
        assert_eq!(expired.code, "remote_failed");
        assert_eq!(expired.extra["reason"], "timeout");
        assert!(start.elapsed() < Duration::from_millis(1000), "receiving output must not reset the deadline");
        private_error(&expired);
        timeout(WAIT, fixture.shared.drip_closed.notified()).await
            .expect("server did not observe CLOSE for the timed-out drip command channel");
        let accepted = fixture.shared.accepted.load(Ordering::SeqCst);
        let recovered = ssh.exec("recover", &[], WAIT).await.unwrap();
        assert_eq!(recovered.stdout, b"held session alive\0\xff");
        assert_eq!(recovered.exit_status, 0);
        assert_eq!(fixture.shared.accepted.load(Ordering::SeqCst), accepted, "timeout must close only its command channel");
        drop(ssh);
        fixture.finish().await;
    }).await.expect("execution failure scenario exceeded its deadline");
}

/// Console events released once the output contains a marker.
struct ScriptedConsole {
    steps: VecDeque<(&'static [u8], ConsoleEvent)>,
    output: Vec<u8>,
    waker: Option<Waker>,
}

impl RawConsole for ScriptedConsole {
    fn poll_event(&mut self, cx: &mut Context<'_>) -> Poll<ConsoleEvent> {
        match self.steps.front() {
            Some((marker, _)) if self.output.windows(marker.len()).any(|window| window == *marker) =>
                Poll::Ready(self.steps.pop_front().expect("front step").1),
            _ => {
                self.waker = Some(cx.waker().clone());
                Poll::Pending
            }
        }
    }

    fn output(&mut self, data: &[u8]) -> std::io::Result<()> {
        self.output.extend_from_slice(data);
        if let Some(waker) = self.waker.take() { waker.wake(); }
        Ok(())
    }
}

#[tokio::test(flavor = "current_thread")]
async fn interactive_pty_round_trip_carries_input_resize_and_exit_status() {
    timeout(SCENARIO, async {
        let fixture = Fixture::start(&key()).await;
        let ssh = fixture.password().await;
        let mut console = ScriptedConsole {
            steps: VecDeque::from([
                (b"MENU> ".as_slice(), ConsoleEvent::Input(b"0\x1b[A".to_vec())),
                (b"echo:0\x1b[A".as_slice(), ConsoleEvent::Resize(ConsoleSize { cols: 100, rows: 40 })),
                (b"resized 100x40".as_slice(), ConsoleEvent::Input(b"q".to_vec())),
            ]),
            output: Vec::new(),
            waker: None,
        };
        let pty = PtyRequest { term: "xterm-256color".into(), size: ConsoleSize { cols: 132, rows: 43 } };
        let status = ssh.interactive("menu", pty, &mut console).await.unwrap();
        assert_eq!(status, 5, "the remote exit status is reported, not success");
        assert!(console.steps.is_empty(), "every scripted event was delivered");
        assert_eq!(console.output, b"MENU> echo:0\x1b[A\r\nresized 100x40\r\necho:q\r\n");
        {
            let journal = fixture.shared.journal.lock().unwrap();
            let at = |entry: &str| journal.iter().position(|item| item == entry).unwrap_or_else(|| panic!("missing {entry}"));
            assert!(at("pty:xterm-256color:132x43") < at("exec:menu"), "pty precedes the command");
            at("resize:100x40");
        }
        // The login stays usable for ordinary commands afterwards.
        assert_eq!(ssh.exec("recover", &[], WAIT).await.unwrap().exit_status, 0);
        drop(ssh);
        fixture.finish().await;
    }).await.expect("interactive pty scenario exceeded its deadline");
}

#[tokio::test(flavor = "current_thread")]
async fn missing_authentication_material_returns_typed_errors_without_authenticating() {
    timeout(SCENARIO, async {
        let fixture = Fixture::start(&key()).await;
        let local = tempfile::tempdir().unwrap();
        let malformed = local.path().join("malformed");
        fs::write(&malformed, b"not an SSH private key").unwrap();
        for (auth, code) in [
            (Authentication::Password(Zeroizing::new(String::new())), "missing_secret"),
            (Authentication::Key { identity: local.path().join("absent"), passphrase: None }, "needs_setup"),
            (Authentication::Key { identity: malformed, passphrase: None }, "needs_setup"),
        ] {
            let error = SshTransport::default().connect(fixture.options(auth)).await.unwrap_err();
            assert_eq!(error.code, code);
            private_error(&error);
        }
        assert!(fixture.shared.journal.lock().unwrap().is_empty());
        fixture.finish().await;
    }).await.expect("missing authentication material scenario exceeded its deadline");
}

#[cfg(unix)]
#[tokio::test(flavor = "current_thread")]
async fn native_system_identity_discovery_uses_an_isolated_home() {
    const CHILD: &str = "ESSENCE_SSH_SYSTEM_IDENTITY_CHILD";
    if std::env::var_os(CHILD).is_none() {
        let home = tempfile::tempdir().unwrap();
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "native_system_identity_discovery_uses_an_isolated_home", "--nocapture"])
            .env(CHILD, "1")
            .env("HOME", home.path())
            .env("SSH_AUTH_SOCK", home.path().join("absent-agent"))
            .output().unwrap();
        assert!(output.status.success(), "isolated identity scenario failed: {}{}",
            String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
        return;
    }
    timeout(SCENARIO, async {
        let client = key();
        let fixture = Fixture::start(&client).await;
        let mut ssh = SshTransport::default();
        let error = ssh.connect(fixture.options(Authentication::System)).await.unwrap_err();
        assert_eq!(error.code, "needs_setup");
        private_error(&error);
        let directory = dirs::home_dir().unwrap().join(".ssh");
        fs::create_dir(&directory).unwrap();
        write_key(&directory, "id_ed25519", &client);
        ssh.connect(fixture.options(Authentication::System)).await.unwrap();
        let output = ssh.exec("recover", &[], WAIT).await.unwrap();
        assert_eq!(output.stdout, b"held session alive\0\xff");
        assert_eq!(output.exit_status, 0);
        assert_eq!(fixture.shared.accepted.load(Ordering::SeqCst), 1);
        drop(ssh);
        fixture.finish().await;
    }).await.expect("native system identity scenario exceeded its deadline");
}

#[tokio::test(flavor = "current_thread")]
async fn sftp_preserves_nested_bytes_modes_and_publishes_version_last_without_rollback() {
    timeout(SCENARIO, async {
        let fixture = Fixture::start(&key()).await;
        let ssh = fixture.password().await;
        let source = tempfile::tempdir().unwrap();
        fs::create_dir_all(source.path().join("modules")).unwrap();
        fs::create_dir_all(source.path().join("common/protocols")).unwrap();
        let binary: Vec<u8> = (0..180_000).map(|i| (i % 256) as u8).collect();
        for (path, data) in [
            ("setup-essence.sh", b"#!/bin/sh\nentry\n".as_slice()),
            ("modules/native.sh", b"#!/bin/sh\nmodule\n".as_slice()),
            ("common/common.sh", b"common\0\xff".as_slice()),
            ("common/protocols/nested.bin", binary.as_slice()),
            ("VERSION", b"2.0.0\n".as_slice()),
        ] { fs::write(source.path().join(path), data).unwrap(); }
        let remote = fixture.shared.path(REMOTE).unwrap();
        fs::create_dir_all(&remote).unwrap();
        fs::write(remote.join("VERSION"), b"1.0.0\n").unwrap();
        fs::write(remote.join("user-data.keep"), b"never delete me").unwrap();
        ssh.upload(source.path(), REMOTE, WAIT).await.unwrap();
        for path in ["setup-essence.sh", "modules/native.sh", "common/common.sh", "common/protocols/nested.bin", "VERSION"] {
            assert_eq!(fs::read(remote.join(path)).unwrap(), fs::read(source.path().join(path)).unwrap());
        }
        assert_eq!(fs::read(remote.join("user-data.keep")).unwrap(), b"never delete me");
        let journal = fixture.shared.journal.lock().unwrap().clone();
        assert_eq!(journal.last().unwrap(), &format!("publish:{REMOTE}/VERSION"));
        assert!(!journal.contains(&format!("open:{REMOTE}/VERSION")), "VERSION must be staged, not truncated in place");
        assert!(!journal.contains(&format!("remove:{REMOTE}/VERSION")), "publication must not remove the previous VERSION first");
        let modes = fixture.shared.modes.lock().unwrap();
        for path in ["setup-essence.sh", "modules/native.sh"] {
            assert_eq!(modes[&format!("{REMOTE}/{path}")] & 0o111, 0o111);
            #[cfg(unix)] {
                use std::os::unix::fs::PermissionsExt;
                assert_eq!(fs::metadata(remote.join(path)).unwrap().permissions().mode() & 0o111, 0o111);
            }
        }
        drop(modes);

        // A refused commit leaves the old version visible, retains earlier replacements,
        // and removes only the uploader's own temporary VERSION, never user data.
        fs::write(source.path().join("setup-essence.sh"), b"replacement survives failed publication\n").unwrap();
        fs::write(source.path().join("VERSION"), b"3.0.0\n").unwrap();
        fixture.shared.refuse_publication.store(true, Ordering::SeqCst);
        let error = ssh.upload(source.path(), REMOTE, WAIT).await.unwrap_err();
        assert_eq!(error.code, "remote_failed");
        private_error(&error);
        assert_eq!(fs::read(remote.join("VERSION")).unwrap(), b"2.0.0\n");
        assert_eq!(fs::read(remote.join("setup-essence.sh")).unwrap(), b"replacement survives failed publication\n");
        assert_eq!(fs::read(remote.join("user-data.keep")).unwrap(), b"never delete me");
        let mut entries: Vec<_> = fs::read_dir(&remote).unwrap().map(|entry| entry.unwrap().file_name()).collect();
        entries.sort();
        assert_eq!(entries, ["VERSION", "common", "modules", "setup-essence.sh", "user-data.keep"].map(std::ffi::OsString::from));
        drop(ssh);
        fixture.finish().await;
    }).await.expect("SFTP publication scenario exceeded its deadline");
}
