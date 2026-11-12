//! Wire types of protocol v3 shared by every front end.
use std::{collections::BTreeMap, path::PathBuf, time::Duration};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use zeroize::Zeroizing;

/// Protocol version announced by the daemon in `hello`.
pub const PROTOCOL: u32 = 3;
/// Upper bound of one protocol message (a line on the local socket).
pub const MAX_MESSAGE: usize = 4 << 20;
/// While a request is in flight the screen is woken this often (spinner,
/// elapsed time), so a slow daemon call never freezes the frame.
pub const TICK: Duration = Duration::from_millis(100);

/// Secrets are never Debug or rendered. Values and serialized wire buffers are wiped.
#[derive(Default, Serialize)]
#[serde(transparent)]
pub struct Secrets(BTreeMap<String, Zeroizing<String>>);
impl Secrets {
    pub fn insert(&mut self, name: impl Into<String>, value: impl Into<String>) { self.0.insert(name.into(), Zeroizing::new(value.into())); }
    pub fn insert_hidden(&mut self, name: impl Into<String>, value: Zeroizing<String>) { self.0.insert(name.into(), value); }
    pub fn clear(&mut self) { self.0.clear(); }
    pub fn remove(&mut self, name: &str) -> bool { self.0.remove(name).is_some() }
    pub fn contains(&self, name: &str) -> bool { self.0.contains_key(name) }
    pub fn is_empty(&self) -> bool { self.0.is_empty() }
    pub(crate) fn names(&self) -> Vec<String> { self.0.keys().cloned().collect() }
}

/// Request input data (`input` field): file contents read by the client.
/// Never Debug or rendered; values are wiped.
#[derive(Default, Serialize)]
#[serde(transparent)]
pub struct Input(BTreeMap<String, Zeroizing<String>>);
impl Input {
    pub fn insert(&mut self, name: impl Into<String>, value: Zeroizing<String>) { self.0.insert(name.into(), value); }
    pub fn clear(&mut self) { self.0.clear(); }
    pub fn is_empty(&self) -> bool { self.0.is_empty() }
    pub(crate) fn names(&self) -> Vec<String> { self.0.keys().cloned().collect() }
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Log { pub level: String, pub text: String }

/// Final answer to a request: `{"id","ok":true,"data","sync"?}` or
/// `{"id","ok":false,"error","exit"}`.
#[derive(Clone, Default, Deserialize)]
pub struct Reply {
    #[serde(default)] pub ok: bool,
    #[serde(default)] pub data: Value,
    #[serde(default)] pub error: Value,
    #[serde(default)] pub sync: Value,
    #[serde(default)] pub exit: Option<u8>,
    #[serde(skip)] pub logs: Vec<Log>,
}
impl Reply {
    pub fn code(&self) -> &str { self.error["code"].as_str().unwrap_or("") }
    pub fn success(data: Value) -> Self { Self { ok: true, data, ..Self::default() } }
    pub fn failure(code: &str) -> Self { Self { error: serde_json::json!({"code":code}), ..Self::default() } }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin { Local, Network }

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct ListenerInfo { pub loopback: bool, pub tls: bool }

/// The first message of every connection (`{"event":"hello","protocol":3,…}`).
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Hello {
    pub version: String,
    pub origin: Origin,
    #[serde(default)] pub listener: Option<ListenerInfo>,
    /// Canonical path of the daemon executable (local connections only).
    #[serde(default)] pub exe: Option<PathBuf>,
    /// The daemon does not exit when idle (`--web`).
    #[serde(default)] pub persistent: bool,
}

/// `terminal` field of a terminal request.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct TerminalSpec { pub term: String, pub cols: u16, pub rows: u16 }

/// Window size carried by `{"id","resize":{…}}`.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct WindowSize { pub cols: u16, pub rows: u16 }

/// Client → daemon request line.
#[derive(Serialize)]
pub(crate) struct WireRequest<'a> {
    pub id: u64,
    pub argv: &'a [String],
    #[serde(skip_serializing_if = "Secrets::is_empty")] pub secrets: &'a Secrets,
    #[serde(skip_serializing_if = "Input::is_empty")] pub input: &'a Input,
    #[serde(skip_serializing_if = "Option::is_none")] pub env: Option<&'a BTreeMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")] pub terminal: Option<TerminalSpec>,
}

/// Client → daemon messages of a running terminal request.
#[derive(Serialize)]
#[serde(untagged)]
pub(crate) enum TerminalMessage {
    Stdin { id: u64, stdin: Zeroizing<String> },
    Resize { id: u64, resize: WindowSize },
    Close { id: u64, close: bool },
}
