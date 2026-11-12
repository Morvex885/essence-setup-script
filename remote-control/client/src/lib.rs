//! Client side of the essence-rc daemon protocol v3: wire types, the
//! [`Client`] trait used by every front end, the local transport with daemon
//! start ([`DaemonClient`]) and the [`ScriptedClient`] test fake.
pub mod client;
pub mod daemon;
pub mod endpoint;
pub mod protocol;
pub mod scripted;
pub mod spawn;

pub use client::{Client, Progress, Request, TermEvent, TerminalIo, argv};
pub use daemon::DaemonClient;
pub use endpoint::{Endpoint, endpoint_for, endpoint_in, prepare_runtime_dir, runtime_dir, verify_runtime_dir};
pub use protocol::{Hello, Input, ListenerInfo, Log, Origin, PROTOCOL, Reply, Secrets, TICK, TerminalSpec, WindowSize};
pub use scripted::{ScriptedClient, Step};
pub use spawn::SpawnDaemon;

#[cfg(test)]
mod tests;
