//! `daemon status` and `daemon stop`: answered by the daemon itself, without
//! the core queue (the core state comes from its published snapshot).

use std::sync::Arc;

use essence_rc_client::PROTOCOL;
use rc_core::cli::Invocation;
use rc_core::dispatch::Envelope;
use rc_core::error::RcError;
use rc_core::VERSION;
use serde_json::{Value, json};

use super::Shared;
use super::conn::{Conn, daemon_stopping};

pub fn run(shared: &Arc<Shared>, conn: &Arc<Conn>, id: &Value, invocation: &Invocation) {
    match invocation.verb.as_str() {
        "status" => conn.reply(id, Envelope::success(status(shared))),
        // The reply `{"stopping":true}` comes from the core thread once the
        // session is closed.
        "stop" => {
            if !shared.begin_stop(Some((conn.clone(), id.clone()))) {
                conn.fail(id, daemon_stopping());
            }
        }
        _ => conn.fail(id, RcError::new("usage", "Неизвестная команда.")),
    }
}

pub fn status(shared: &Shared) -> Value {
    let snapshot = shared.snapshot.borrow().clone();
    let clients: Vec<Value> = shared.connections().iter()
        .map(|conn| json!({"origin": conn.origin, "since_s": conn.since.elapsed().as_secs()}))
        .collect();
    json!({
        "pid": std::process::id(),
        "version": VERSION,
        "protocol": PROTOCOL,
        "exe": shared.exe,
        "uptime_s": shared.started.elapsed().as_secs(),
        "persistent": shared.persistent,
        "busy": shared.busy(),
        "clients": clients,
        "session": {"open": snapshot.open, "source": snapshot.source},
        "terminals": shared.terminals.running(),
        "web": null,
    })
}
