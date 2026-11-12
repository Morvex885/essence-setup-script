//! Deterministic screen fake; assertions include argv and keep secrets and
//! input values out of diagnostics (only their names are recorded).
use std::{collections::VecDeque, io};
use crate::{client::{Client, Progress, Request, TerminalIo}, protocol::{Hello, Origin, Reply}};

/// One scripted request: the expected argv and the reply. Terminal steps
/// answer only [`Client::terminal`], plain steps only [`Client::send`].
pub struct Step { pub argv: Vec<String>, pub reply: Reply, pub terminal: bool }
impl Step {
    pub fn send(argv: Vec<String>, reply: Reply) -> Self { Self { argv, reply, terminal: false } }
    pub fn terminal(argv: Vec<String>, reply: Reply) -> Self { Self { argv, reply, terminal: true } }
}
impl From<(Vec<String>, Reply)> for Step {
    fn from((argv, reply): (Vec<String>, Reply)) -> Self { Self::send(argv, reply) }
}

pub struct ScriptedClient {
    pub steps: VecDeque<Step>,
    pub calls: Vec<Vec<String>>,
    pub secret_names: Vec<Vec<String>>,
    pub input_names: Vec<Vec<String>>,
    pub closed: bool,
    hello: Hello,
}
impl ScriptedClient {
    pub fn new<S: Into<Step>>(steps: impl IntoIterator<Item = S>) -> Self {
        Self {
            steps: steps.into_iter().map(Into::into).collect(),
            calls: vec![],
            secret_names: vec![],
            input_names: vec![],
            closed: false,
            hello: Hello { version: "test".into(), origin: Origin::Local, listener: None, exe: None, persistent: false },
        }
    }
    pub fn assert_finished(&self) {
        let terminal = self.steps.iter().filter(|step| step.terminal).count();
        assert!(self.steps.is_empty(), "Unused scripted replies: {} ({terminal} terminal)", self.steps.len());
    }
    fn take(&mut self, request: Request<'_>, terminal: bool) -> Reply {
        self.calls.push(request.argv.to_vec());
        self.secret_names.push(request.secrets.names());
        self.input_names.push(request.input.names());
        let step = self.steps.pop_front().expect("Unexpected request");
        assert_eq!(request.argv, step.argv);
        assert_eq!(step.terminal, terminal, "terminal request ≠ scripted step kind for {:?}", step.argv);
        step.reply
    }
}
impl Client for ScriptedClient {
    fn hello(&self) -> &Hello { &self.hello }
    fn send(&mut self, request: Request<'_>, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply> {
        let reply = self.take(request, false);
        for entry in &reply.logs { progress(Progress::Log(entry)); }
        Ok(reply)
    }
    fn terminal(&mut self, request: Request<'_>, io: &mut dyn TerminalIo, progress: &mut dyn FnMut(Progress<'_>)) -> io::Result<Reply> {
        let reply = self.take(request, true);
        io.start(Box::new(|_| {}))?;
        for entry in &reply.logs { progress(Progress::Log(entry)); }
        io.stop();
        Ok(reply)
    }
    fn close(&mut self) -> io::Result<()> { self.closed = true; Ok(()) }
}
