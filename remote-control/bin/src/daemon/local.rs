//! The local endpoint: single-instance lock, Unix socket or Windows named
//! pipe, peer checks, the accept loop with its idle decision, the journal,
//! signals and the restart after `self update`.

use std::ffi::OsString;
use std::io;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use essence_rc_client::{Endpoint, Origin};
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::sync::mpsc;
use zeroize::Zeroizing;

use super::{Shared, conn};

/// Retry step while another daemon starts or stops.
const RETRY: Duration = Duration::from_millis(50);
/// How long a new daemon waits for the previous one to release the endpoint.
const TAKEOVER_WAIT: Duration = Duration::from_secs(60);
const READ_CHUNK: usize = 64 << 10;

/// Line splitter over a byte stream; every buffer holding request bytes is
/// zeroized. Lines longer than `max` end the stream with an error.
pub struct LineReader<R> {
    reader: R,
    pending: Zeroizing<Vec<u8>>,
    chunk: Zeroizing<Vec<u8>>,
    /// Bytes of `pending` already known to hold no newline.
    scanned: usize,
    max: usize,
}

impl<R: AsyncRead + Unpin> LineReader<R> {
    pub fn new(reader: R, max: usize) -> Self {
        Self {
            reader,
            pending: Zeroizing::new(Vec::with_capacity(READ_CHUNK)),
            chunk: Zeroizing::new(vec![0; READ_CHUNK]),
            scanned: 0,
            max,
        }
    }

    /// The next line without `\n` (and a trailing `\r`); `None` at EOF.
    pub async fn next(&mut self) -> io::Result<Option<Zeroizing<Vec<u8>>>> {
        loop {
            if let Some(offset) = self.pending[self.scanned..].iter().position(|&byte| byte == b'\n') {
                let end = self.scanned + offset;
                if end > self.max {
                    return Err(too_long());
                }
                let mut line = Zeroizing::new(self.pending[..end].to_vec());
                if line.last() == Some(&b'\r') {
                    line.pop();
                }
                self.pending.drain(..=end);
                self.scanned = 0;
                return Ok(Some(line));
            }
            self.scanned = self.pending.len();
            if self.pending.len() > self.max {
                return Err(too_long());
            }
            let read = self.reader.read(&mut self.chunk[..]).await?;
            if read == 0 {
                return Ok(None);
            }
            if self.pending.len() + read > self.pending.capacity() {
                // Grow into a fresh buffer so no stale copy stays unzeroized.
                let mut grown = Zeroizing::new(Vec::with_capacity((self.pending.capacity() * 2).max(self.pending.len() + read)));
                grown.extend_from_slice(&self.pending);
                self.pending = grown;
            }
            self.pending.extend_from_slice(&self.chunk[..read]);
        }
    }
}

fn too_long() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "Сообщение превышает 4 МиБ.")
}

/// When an on-demand daemon exits.
pub struct IdlePolicy {
    pub persistent: bool,
    pub linger: Duration,
    /// Nobody connected yet: exit this long after start.
    pub first_client: Duration,
    pub tick: Duration,
}

/// Pure idle decision: `idle_since` is when the daemon last became idle.
pub(super) fn idle_expired(now: Instant, idle_since: Option<Instant>, ever_connected: bool, started: Instant, policy: &IdlePolicy) -> bool {
    if policy.persistent {
        return false;
    }
    let Some(since) = idle_since else { return false };
    if ever_connected {
        now.duration_since(since) >= policy.linger
    } else {
        now.duration_since(started) >= policy.first_client
    }
}

/// Accepts local connections until a stop begins; the idle exit is decided
/// here, in the same `select!` as `accept`, so no accepted connection is
/// lost to it. Returns what must outlive the session close (Windows: one
/// pipe instance that keeps the name taken).
pub async fn accept_loop(shared: Arc<Shared>, mut listener: Listener, policy: IdlePolicy) -> Kept {
    let mut stop = shared.stop.subscribe();
    let mut tick = tokio::time::interval(policy.tick);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut idle_since: Option<Instant> = None;
    loop {
        tokio::select! {
            _ = stop.wait_for(|stopping| *stopping) => break,
            accepted = listener.accept() => {
                idle_since = None;
                match accepted {
                    Ok(stream) => {
                        let (out, outgoing) = mpsc::unbounded_channel();
                        let conn = shared.register(Origin::Local, out);
                        tokio::spawn(conn::serve(shared.clone(), conn, outgoing, stream));
                    }
                    Err(error) if error.kind() == io::ErrorKind::PermissionDenied => {
                        eprintln!("  [!] Отклонено подключение другого пользователя.");
                    }
                    Err(error) => {
                        eprintln!("  [!] Ошибка приёма подключения: {error}");
                        tokio::time::sleep(RETRY).await;
                    }
                }
            }
            _ = tick.tick(), if !policy.persistent => {
                let now = Instant::now();
                if shared.is_idle() {
                    let since = *idle_since.get_or_insert(now);
                    let ever = shared.ever_connected.load(std::sync::atomic::Ordering::SeqCst);
                    if idle_expired(now, Some(since), ever, shared.started, &policy) {
                        shared.begin_stop(None);
                        break;
                    }
                } else {
                    idle_since = None;
                }
            }
        }
    }
    listener.keep()
}

/// Stop on SIGTERM/SIGINT (Windows console events); SIGHUP is ignored,
/// SIGQUIT exits at once with 131. Needs the runtime context.
pub fn watch_signals(shared: &Arc<Shared>) {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        for kind in [SignalKind::terminate(), SignalKind::interrupt()] {
            if let Ok(mut stream) = signal(kind) {
                let shared = shared.clone();
                tokio::spawn(async move {
                    while stream.recv().await.is_some() {
                        shared.begin_stop(None);
                    }
                });
            }
        }
        if let Ok(mut stream) = signal(SignalKind::hangup()) {
            tokio::spawn(async move { while stream.recv().await.is_some() {} });
        }
        if let Ok(mut stream) = signal(SignalKind::quit()) {
            tokio::spawn(async move {
                if stream.recv().await.is_some() {
                    std::process::exit(128 + libc::SIGQUIT);
                }
            });
        }
    }
    #[cfg(windows)]
    {
        use tokio::signal::windows;
        macro_rules! stop_on {
            ($constructor:path) => {
                if let Ok(mut stream) = $constructor() {
                    let shared = shared.clone();
                    tokio::spawn(async move {
                        while stream.recv().await.is_some() {
                            shared.begin_stop(None);
                        }
                    });
                }
            };
        }
        stop_on!(windows::ctrl_c);
        stop_on!(windows::ctrl_break);
        stop_on!(windows::ctrl_close);
        stop_on!(windows::ctrl_logoff);
        stop_on!(windows::ctrl_shutdown);
    }
}

pub enum Bound {
    Listener(Listener),
    /// Windows: the pipe name is held by a running daemon of this user.
    #[cfg_attr(unix, allow(dead_code))]
    Running,
}

// ─── Unix ────────────────────────────────────────────────────────────────────

#[cfg(unix)]
pub use unix::*;

#[cfg(unix)]
mod unix {
    use std::fs::{File, OpenOptions, Permissions};
    use std::os::fd::{AsRawFd, FromRawFd, RawFd};
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
    use std::os::unix::process::CommandExt;

    use tokio::net::{UnixListener, UnixStream};

    use super::*;

    /// The lock descriptor handed to the process exec'ed by a restart.
    const LOCK_FD_ENV: &str = "ESSENCE_RC_DAEMON_LOCK_FD";

    pub struct Listener(UnixListener);
    /// Unix keeps nothing: the socket file stays (refusing) until removed.
    pub struct Kept;

    impl Listener {
        /// Under the lock: replace a stale socket, bind, 0600.
        pub async fn bind(endpoint: &Endpoint) -> io::Result<Bound> {
            match std::fs::remove_file(&endpoint.socket) {
                Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
                _ => {}
            }
            let listener = UnixListener::bind(&endpoint.socket)?;
            std::fs::set_permissions(&endpoint.socket, Permissions::from_mode(0o600))?;
            Ok(Bound::Listener(Self(listener)))
        }

        /// One connection of our own uid; others are dropped.
        pub(super) async fn accept(&mut self) -> io::Result<UnixStream> {
            let (stream, _) = self.0.accept().await?;
            if !same_user(&stream) {
                return Err(io::Error::new(io::ErrorKind::PermissionDenied, "foreign peer"));
            }
            Ok(stream)
        }

        pub(super) fn keep(self) -> Kept {
            Kept
        }
    }

    fn euid() -> u32 {
        // SAFETY: geteuid has no preconditions and cannot fail.
        unsafe { libc::geteuid() }
    }

    fn same_user(stream: &UnixStream) -> bool {
        stream.peer_cred().is_ok_and(|cred| cred.uid() == euid())
    }

    pub enum Acquired {
        Held(File),
        Running,
    }

    /// The lock inherited across a restart's exec, if any. Called first in
    /// `run`, before any other thread of the daemon exists.
    pub fn take_inherited_lock() -> Option<File> {
        let value = std::env::var_os(LOCK_FD_ENV)?;
        // SAFETY: the daemon has not started any thread yet.
        unsafe { std::env::remove_var(LOCK_FD_ENV) };
        let fd: RawFd = value.to_str()?.parse().ok().filter(|fd| *fd > 2)?;
        // SAFETY: F_GETFD only queries the descriptor table.
        if unsafe { libc::fcntl(fd, libc::F_GETFD) } == -1 {
            return None;
        }
        // SAFETY: the descriptor is open and was handed over to this process
        // by its previous image, which owned it.
        let file = unsafe { File::from_raw_fd(fd) };
        // SAFETY: plain fcntl on a descriptor owned by `file`.
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
        Some(file)
    }

    /// `true` when the exclusive lock was taken; `false` when another holds it.
    fn try_lock(file: &File) -> io::Result<bool> {
        // SAFETY: the descriptor is owned by `file` for the whole call.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Ok(true);
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EWOULDBLOCK) { Ok(false) } else { Err(error) }
    }

    fn same_file(file: &File, path: &Path) -> bool {
        match (file.metadata(), std::fs::symlink_metadata(path)) {
            (Ok(open), Ok(named)) => open.dev() == named.dev() && open.ino() == named.ino(),
            _ => false,
        }
    }

    /// A daemon of ours answers on the socket.
    async fn daemon_answers(endpoint: &Endpoint) -> bool {
        UnixStream::connect(&endpoint.socket).await.is_ok_and(|stream| same_user(&stream))
    }

    /// One daemon per endpoint: `flock(LOCK_EX)` on `<h>.lock`, held for the
    /// whole life of the process (and across a restart's exec). Held by
    /// another: a daemon that answers means «already running»; otherwise the
    /// previous one is exiting and the lock is awaited up to 60 s.
    pub async fn acquire_lock(endpoint: &Endpoint, inherited: Option<File>) -> io::Result<Acquired> {
        if let Some(file) = inherited.filter(|file| same_file(file, &endpoint.lock))
            && try_lock(&file)?
        {
            return Ok(Acquired::Held(file));
        }
        let file = OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(&endpoint.lock)?;
        let deadline = Instant::now() + TAKEOVER_WAIT;
        loop {
            if try_lock(&file)? {
                return Ok(Acquired::Held(file));
            }
            if daemon_answers(endpoint).await {
                return Ok(Acquired::Running);
            }
            if Instant::now() >= deadline {
                return Err(io::Error::new(io::ErrorKind::WouldBlock,
                    format!("Блокировка демона «{}» занята дольше 60 с.", endpoint.lock.display())));
            }
            tokio::time::sleep(RETRY).await;
        }
    }

    /// stderr → `<h>.log`, truncated, 0600.
    pub fn redirect_stderr(endpoint: &Endpoint) -> io::Result<()> {
        let file = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600)
            .custom_flags(libc::O_NOFOLLOW).open(&endpoint.log)?;
        file.set_permissions(Permissions::from_mode(0o600))?;
        // SAFETY: both descriptors are valid; dup2 replaces fd 2 atomically.
        if unsafe { libc::dup2(file.as_raw_fd(), libc::STDERR_FILENO) } == -1 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    /// Persistent daemon after `self update`: become the new binary with the
    /// same arguments, keeping the lock. Returns only on failure.
    pub fn exec_restart(exe: &Path, args: &[OsString], data_dir: &Path, lock: &File) -> io::Error {
        let fd = lock.as_raw_fd();
        // SAFETY: plain fcntl on a descriptor owned by `lock`.
        if unsafe { libc::fcntl(fd, libc::F_SETFD, 0) } == -1 {
            return io::Error::last_os_error();
        }
        std::process::Command::new(exe).args(args)
            .env("ESSENCE_RC_DATA_DIR", data_dir)
            .env(LOCK_FD_ENV, fd.to_string())
            .exec()
    }
}

// ─── Windows ─────────────────────────────────────────────────────────────────

#[cfg(windows)]
pub use windows::*;

#[cfg(windows)]
mod windows {
    use std::ffi::c_void;
    use std::os::windows::io::{AsRawHandle, IntoRawHandle};
    use std::os::windows::process::CommandExt;

    use tokio::net::windows::named_pipe::{ClientOptions, NamedPipeServer, ServerOptions};
    use windows_sys::Win32::Foundation::{CloseHandle, ERROR_ACCESS_DENIED, ERROR_PIPE_BUSY, HANDLE, LocalFree};
    use windows_sys::Win32::Security::Authorization::{ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
    use windows_sys::Win32::Security::{EqualSid, GetTokenInformation, PSID, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser};
    use windows_sys::Win32::System::Console::{STD_ERROR_HANDLE, SetStdHandle};
    use windows_sys::Win32::System::Pipes::{GetNamedPipeClientProcessId, GetNamedPipeServerProcessId, WaitNamedPipeW};
    use windows_sys::Win32::System::Threading::{CREATE_NEW_PROCESS_GROUP, CREATE_NO_WINDOW, GetCurrentProcess, OpenProcess,
        OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION};

    use super::*;

    /// The owner-only security descriptor of the pipe (LocalFree'd on drop).
    struct Security(*mut c_void);

    impl Drop for Security {
        fn drop(&mut self) {
            // SAFETY: allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW.
            unsafe { LocalFree(self.0) };
        }
    }

    // SAFETY: the descriptor is immutable after creation and only read by CreateNamedPipe.
    unsafe impl Send for Security {}

    impl Security {
        /// `D:P(A;;GA;;;<our SID>)`: only this user may open the pipe.
        fn owner_only() -> io::Result<Self> {
            let user = token_user(current_process())?;
            let mut text: *mut u16 = std::ptr::null_mut();
            // SAFETY: the SID comes from a TOKEN_USER buffer; `text` is a valid out pointer.
            if unsafe { ConvertSidToStringSidW(sid(&user), &mut text) } == 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: ConvertSidToStringSidW returned a NUL-terminated wide string.
            let length = (0..).take_while(|&index| unsafe { *text.add(index) } != 0).count();
            // SAFETY: `length` units were just read from that string.
            let sid_text = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(text, length) });
            // SAFETY: allocated by ConvertSidToStringSidW.
            unsafe { LocalFree(text.cast()) };
            let sddl: Vec<u16> = format!("D:P(A;;GA;;;{sid_text})").encode_utf16().chain([0]).collect();
            let mut descriptor: *mut c_void = std::ptr::null_mut();
            // SAFETY: `sddl` is NUL-terminated; `descriptor` is a valid out pointer.
            let ok = unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut descriptor, std::ptr::null_mut())
            };
            if ok == 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(Self(descriptor))
        }

        fn create(&self, name: &str, first: bool) -> io::Result<NamedPipeServer> {
            let mut attributes = SECURITY_ATTRIBUTES {
                nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: self.0,
                bInheritHandle: 0,
            };
            // SAFETY: `attributes` is a valid SECURITY_ATTRIBUTES for the call.
            unsafe {
                ServerOptions::new().first_pipe_instance(first).reject_remote_clients(true)
                    .create_with_security_attributes_raw(name, (&raw mut attributes).cast())
            }
        }
    }

    fn current_process() -> HANDLE {
        // SAFETY: the pseudo handle of the current process needs no closing.
        unsafe { GetCurrentProcess() }
    }

    /// The `TOKEN_USER` of a process, in a pointer-aligned buffer.
    fn token_user(process: HANDLE) -> io::Result<Vec<usize>> {
        let mut token: HANDLE = std::ptr::null_mut();
        // SAFETY: `token` is a valid out pointer.
        if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut length = 0u32;
        // SAFETY: a size query with a null buffer; `length` is a valid out pointer.
        unsafe { GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut length) };
        let mut buffer = vec![0usize; (length as usize).div_ceil(size_of::<usize>()).max(1)];
        // SAFETY: the buffer holds at least `length` bytes and is pointer-aligned.
        let ok = unsafe { GetTokenInformation(token, TokenUser, buffer.as_mut_ptr().cast(), length, &mut length) };
        let error = io::Error::last_os_error();
        // SAFETY: `token` was opened above and is closed exactly once.
        unsafe { CloseHandle(token) };
        if ok == 0 {
            return Err(error);
        }
        Ok(buffer)
    }

    fn sid(token_user: &[usize]) -> PSID {
        // SAFETY: the buffer was filled with a TOKEN_USER by `token_user`.
        unsafe { (*token_user.as_ptr().cast::<TOKEN_USER>()).User.Sid }
    }

    /// The process `pid` runs under our user SID.
    fn same_user(pid: u32) -> bool {
        // SAFETY: OpenProcess has no memory preconditions; a null result is handled.
        let process = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
        if process.is_null() {
            return false;
        }
        let theirs = token_user(process);
        // SAFETY: `process` was opened above and is closed exactly once.
        unsafe { CloseHandle(process) };
        let (Ok(theirs), Ok(ours)) = (theirs, token_user(current_process())) else { return false };
        // SAFETY: both buffers hold a TOKEN_USER filled by GetTokenInformation.
        unsafe { EqualSid(sid(&theirs), sid(&ours)) != 0 }
    }

    fn foreign() -> io::Error {
        io::Error::new(io::ErrorKind::PermissionDenied, "Канал демона принадлежит другому пользователю.")
    }

    pub struct Listener {
        name: String,
        security: Security,
        next: NamedPipeServer,
    }

    /// A pipe instance that keeps the name taken (clients see «busy», not
    /// «absent») until the session is closed.
    pub struct Kept(#[allow(dead_code)] NamedPipeServer);

    impl Listener {
        /// The first instance (`FILE_FLAG_FIRST_PIPE_INSTANCE`) is the
        /// single-instance check: taken by a daemon of ours → `Running`; by
        /// another user → `unsafe_path`; all instances busy (a start race of
        /// several clients) → wait for a free one and probe again; otherwise
        /// the previous daemon is exiting and the name is awaited up to 60 s.
        pub async fn bind(endpoint: &Endpoint) -> io::Result<Bound> {
            let security = Security::owner_only()?;
            let deadline = Instant::now() + TAKEOVER_WAIT;
            loop {
                match security.create(&endpoint.pipe, true) {
                    Ok(next) => return Ok(Bound::Listener(Self { name: endpoint.pipe.clone(), security, next })),
                    Err(error) if error.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32) => {
                        match probe(&endpoint.pipe) {
                            Ok(()) => return Ok(Bound::Running),
                            Err(error) if error.kind() == io::ErrorKind::PermissionDenied => return Err(error),
                            Err(_) if Instant::now() >= deadline => return Err(error),
                            // A live daemon whose instances are all connected is not
                            // an exiting one: no polling connections while it is busy.
                            Err(busy) if busy.raw_os_error() == Some(ERROR_PIPE_BUSY as i32) => wait_free_instance(&endpoint.pipe),
                            Err(_) => tokio::time::sleep(RETRY).await,
                        }
                    }
                    Err(error) => return Err(error),
                }
            }
        }

        /// A connected client of our user; the next instance is created first.
        pub(super) async fn accept(&mut self) -> io::Result<NamedPipeServer> {
            self.next.connect().await?;
            let next = self.security.create(&self.name, false)?;
            let connected = std::mem::replace(&mut self.next, next);
            let mut pid = 0u32;
            // SAFETY: the handle is a live pipe owned by `connected`; `pid` is a valid out pointer.
            let known = unsafe { GetNamedPipeClientProcessId(connected.as_raw_handle() as HANDLE, &mut pid) } != 0;
            if !known || !same_user(pid) {
                return Err(io::Error::new(io::ErrorKind::PermissionDenied, "foreign peer"));
            }
            Ok(connected)
        }

        pub(super) fn keep(self) -> Kept {
            Kept(self.next)
        }
    }

    /// Up to 1 s until an instance of `name` accepts a client (or the pipe
    /// is gone); connects nothing.
    fn wait_free_instance(name: &str) {
        let wide: Vec<u16> = name.encode_utf16().chain([0]).collect();
        // SAFETY: `wide` is a NUL-terminated wide string; failure (timeout, no pipe) is fine.
        unsafe { WaitNamedPipeW(wide.as_ptr(), 1000) };
    }

    /// Ok when the pipe answers and its server runs under our SID.
    fn probe(name: &str) -> io::Result<()> {
        let client = ClientOptions::new().open(name).map_err(|error| {
            if error.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32) { foreign() } else { error }
        })?;
        let mut pid = 0u32;
        // SAFETY: the handle is a live pipe owned by `client`; `pid` is a valid out pointer.
        if unsafe { GetNamedPipeServerProcessId(client.as_raw_handle() as HANDLE, &mut pid) } == 0 {
            return Err(io::Error::last_os_error());
        }
        if same_user(pid) { Ok(()) } else { Err(foreign()) }
    }

    /// stderr → `<h>.log`, truncated.
    pub fn redirect_stderr(endpoint: &Endpoint) -> io::Result<()> {
        let file = std::fs::OpenOptions::new().write(true).create(true).truncate(true).open(&endpoint.log)?;
        let handle = file.into_raw_handle();
        // SAFETY: the handle is a valid file handle now owned by the process.
        if unsafe { SetStdHandle(STD_ERROR_HANDLE, handle as HANDLE) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    /// Persistent daemon after `self update`: start the new binary detached
    /// (this process has closed its pipe and exits next).
    pub fn spawn_restart(exe: &Path, args: &[OsString], data_dir: &Path) -> io::Result<()> {
        let mut command = std::process::Command::new(exe);
        command.args(args)
            .env("ESSENCE_RC_DATA_DIR", data_dir)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .creation_flags(CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP);
        if let Some(dir) = exe.parent() {
            command.current_dir(dir);
        }
        command.spawn().map(drop)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy(persistent: bool) -> IdlePolicy {
        IdlePolicy { persistent, linger: Duration::from_secs(5), first_client: Duration::from_secs(10), tick: Duration::from_millis(100) }
    }

    #[test]
    fn idle_exit_waits_for_the_first_client_then_for_linger() {
        let started = Instant::now();
        let at = |seconds: u64| started + Duration::from_secs(seconds);
        let on_demand = policy(false);
        assert!(!idle_expired(at(9), Some(started), false, started, &on_demand), "nobody connected yet: 10 s");
        assert!(idle_expired(at(10), Some(started), false, started, &on_demand));
        assert!(!idle_expired(at(14), Some(at(10)), true, started, &on_demand), "after a client: linger");
        assert!(idle_expired(at(15), Some(at(10)), true, started, &on_demand));
        assert!(!idle_expired(at(100), None, true, started, &on_demand), "busy never expires");
        assert!(!idle_expired(at(100), Some(started), true, started, &policy(true)), "persistent never idles out");
        let immediate = IdlePolicy { linger: Duration::ZERO, ..policy(false) };
        assert!(idle_expired(at(1), Some(at(1)), true, started, &immediate));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn lines_split_strip_cr_and_end_at_eof() {
        let data: &[u8] = b"{\"a\":1}\r\n\n{\"b\":2}\npartial";
        let mut reader = LineReader::new(data, 64);
        assert_eq!(reader.next().await.unwrap().unwrap().as_slice(), b"{\"a\":1}");
        assert_eq!(reader.next().await.unwrap().unwrap().as_slice(), b"");
        assert_eq!(reader.next().await.unwrap().unwrap().as_slice(), b"{\"b\":2}");
        assert!(reader.next().await.unwrap().is_none(), "an unterminated tail is dropped at EOF");
    }

    #[tokio::test(flavor = "current_thread")]
    async fn long_lines_end_the_stream() {
        let long = [vec![b'x'; 100], b"\n".to_vec()].concat();
        let mut reader = LineReader::new(long.as_slice(), 64);
        assert_eq!(reader.next().await.unwrap_err().kind(), io::ErrorKind::InvalidData);
        let endless = vec![b'x'; READ_CHUNK * 3];
        let mut reader = LineReader::new(endless.as_slice(), READ_CHUNK);
        assert_eq!(reader.next().await.unwrap_err().kind(), io::ErrorKind::InvalidData);
        let exact = [vec![b'y'; READ_CHUNK * 2], b"\n".to_vec()].concat();
        let mut reader = LineReader::new(exact.as_slice(), READ_CHUNK * 2);
        assert_eq!(reader.next().await.unwrap().unwrap().len(), READ_CHUNK * 2, "lines across chunks grow the buffer");
    }
}
