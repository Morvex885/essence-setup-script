//! Native remote effects. Futures have no `Send` requirement: a command may hold
//! a thread-owned state lock and must stay on its dispatch thread across awaits.
//! Implementations never persist host trust or put authentication in child argv.

use std::{future::Future, io, path::{Path, PathBuf}, task::{Context, Poll}, time::Duration};

use zeroize::Zeroizing;

use crate::{error::{RcError, Result}, model::Fingerprint};

/// Authentication material is intentionally not Debug/Serialize.
pub enum Authentication {
    Password(Zeroizing<String>),
    Key { identity: PathBuf, passphrase: Option<Zeroizing<String>> },
    /// Native identity discovery under the current user's SSH directory.
    System,
}

#[derive(Clone, Debug, Default)]
pub struct HostKeyPolicy {
    /// An explicit operator-supplied fingerprint takes precedence over known pins.
    pub expected: Option<Fingerprint>,
    pub known: Vec<Fingerprint>,
}

/// Connection values are passed in memory, never to subprocesses or environment.
pub struct ConnectOptions {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub auth: Authentication,
    pub host_key: HostKeyPolicy,
    pub timeout: Duration,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct ExecResult {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub exit_status: u32,
}

/// Effects usable both from a normal connection and its independently held lease.
pub trait RemoteSession {
    fn exec<'a>(&'a self, command: &'a str, stdin: &'a [u8], timeout: Duration)
        -> impl Future<Output = Result<ExecResult>> + 'a;
    fn upload<'a>(&'a self, local_dir: &'a Path, remote_dir: &'a str, timeout: Duration)
        -> impl Future<Output = Result<()>> + 'a;
}

pub trait RemoteTransport: RemoteSession {
    type Held: RemoteSession;
    fn connect(&mut self, options: ConnectOptions) -> impl Future<Output = Result<()>> + '_;
    fn hold(&self) -> Result<Self::Held>;

    /// Run `command` on a remote pseudo-terminal wired to a raw console and
    /// return its exit status. There is no deadline: the operator ends the
    /// session; connection keepalive ends a dead link. Transports without
    /// interactive support refuse before any remote effect.
    fn interactive<'a>(&'a self, command: &'a str, pty: PtyRequest, console: &'a mut dyn RawConsole)
        -> impl Future<Output = Result<u32>> + 'a
    {
        let _ = (command, pty, console);
        std::future::ready(Err(remote_failure("interactive_unsupported")))
    }
}

/// Console size in character cells.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConsoleSize {
    pub cols: u16,
    pub rows: u16,
}

/// Pseudo-terminal parameters sent with the remote session request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PtyRequest {
    pub term: String,
    pub size: ConsoleSize,
}

/// Local console activity while it is in raw mode.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConsoleEvent {
    /// Keyboard input, already encoded as terminal bytes.
    Input(Vec<u8>),
    Resize(ConsoleSize),
    /// Local input ended (console gone); the remote side receives EOF.
    Closed,
}

/// The operator's terminal, provided by the frontend. Absent in a public
/// serve (only the TUI's `serve --inner` child attaches one) and whenever no
/// controlling terminal exists.
pub trait Console {
    /// A controlling terminal that accepts raw mode is attached. Checked
    /// before any remote effect.
    fn available(&mut self) -> bool;
    /// `TERM` for the remote pseudo-terminal.
    fn term(&self) -> String;
    fn size(&self) -> ConsoleSize;
    /// Enter raw mode and start delivering input. Cooked mode returns when
    /// the returned value drops, on every exit path.
    fn raw(&mut self) -> io::Result<Box<dyn RawConsole + '_>>;
}

/// A console in raw mode: the input event stream and the output stream.
pub trait RawConsole {
    /// Next input or resize event. `Pending` registers the waker.
    fn poll_event(&mut self, cx: &mut Context<'_>) -> Poll<ConsoleEvent>;
    /// Remote terminal output, written through unchanged.
    fn output(&mut self, data: &[u8]) -> io::Result<()>;
}

/// A timeout is a failed remote operation, never a synthetic successful exit.
pub fn remote_failure(reason: &'static str) -> RcError {
    RcError::new("remote_failed", "Удалённая операция не выполнена.").with_extra("reason", reason)
}
