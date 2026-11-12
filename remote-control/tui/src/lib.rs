//! Ratatui frontend, linked into `essence-rc` as a library: [`run_terminal`]
//! is the no-argument entrypoint. The core is reached only through the
//! daemon protocol ([`essence_rc_client::Client`]); see [`app`] for screen
//! registration and [`app::ScriptedUi`] for deterministic screen tests.
pub mod app;
pub mod confirm;
pub mod system;
pub mod ui;
pub mod source;
pub mod clients;
pub mod nodes;
pub use app::{Frontend, run_terminal};
