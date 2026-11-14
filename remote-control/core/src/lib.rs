//! Shared domain code for Essence Remote Control.
//!
//! The core does not depend on the terminal or a frontend transport.

/// Release version embedded from the repository's root `VERSION` file.
pub const VERSION: &str = env!("ESSENCE_RC_VERSION");

pub mod auth;
pub mod awg;
pub mod cli;
pub mod clients;
pub mod confirmation;
pub mod dispatch;
pub mod bundle;
pub mod error;
pub mod log;
pub mod fake_transport;
pub mod github;
pub mod locking;
pub mod model;
pub mod nodes;
pub mod process;
pub mod protocols;
pub mod secrets;
pub mod secure_fs;
pub mod request_input;
pub mod request_secrets;
pub mod server;
pub mod state;
pub mod self_manage;
pub mod ssh;
pub mod status;
pub mod subscription;
pub mod telegram;
pub mod terminal;
pub mod transport;
pub mod validation;
