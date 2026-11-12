//! The front-end view of the daemon: screens and the CLI use [`Client`] exclusively.
use std::{collections::BTreeMap, io, path::Path};
use zeroize::Zeroizing;
use crate::protocol::{Hello, Input, Log, Reply, Secrets};

/// One request: argv, secrets, input data and, for local connections, the
/// client environment the daemon may use (`{"SSH_AUTH_SOCK": …}`).
#[derive(Clone, Copy)]
pub struct Request<'a> {
    pub argv: &'a [String],
    pub secrets: &'a Secrets,
    pub input: &'a Input,
    pub env: Option<&'a BTreeMap<String, String>>,
}
impl<'a> Request<'a> {
    pub fn new(argv: &'a [String], secrets: &'a Secrets, input: &'a Input) -> Self { Self { argv, secrets, input, env: None } }
}

/// Progress of a request in flight: a journal event of the core, or a timer
/// tick (every [`crate::TICK`] without output) for redraws.
pub enum Progress<'a> { Log(&'a Log), Tick }

/// Local terminal events forwarded to the daemon during a terminal request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TermEvent { Input(Zeroizing<Vec<u8>>), Resize { cols: u16, rows: u16 }, Closed }

/// The local side of a terminal request: raw mode, keyboard and screen.
pub trait TerminalIo {
    fn term(&self) -> String;
    fn size(&self) -> (u16, u16);
    /// Called once the daemon opened the remote terminal; `events` may be
    /// called from any thread until [`TerminalIo::stop`].
    fn start(&mut self, events: Box<dyn Fn(TermEvent) + Send>) -> io::Result<()>;
    fn write(&mut self, data: &[u8]) -> io::Result<()>;
    fn stop(&mut self);
}

/// `progress` is called before the final reply.
pub trait Client {
    fn hello(&self) -> &Hello;
    fn send(&mut self, request: Request<'_>, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply>;
    fn terminal(&mut self, request: Request<'_>, io: &mut dyn TerminalIo, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply>;
    /// Closes the connection; the daemon keeps running.
    fn close(&mut self) -> io::Result<()> { Ok(()) }
    /// The data directory of a daemon on this machine; `None` when it is
    /// unknown or remote, so local path checks against it do not apply.
    fn local_data_dir(&self) -> Option<&Path> { None }
}

pub fn argv(words: &[&str]) -> Vec<String> { words.iter().map(|s| (*s).to_owned()).collect() }
