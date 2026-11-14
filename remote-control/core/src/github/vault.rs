//! The portable vault snapshot and its repository encodings.
//!
//! Snapshot (format 1): `vault_version`, `minimum_remote_control_version`,
//! `portability`, `access{script_password_hash}`, `config`, `secrets`
//! (schema 2, plaintext passwords), `templates{name:{content,source,sha256}}`,
//! `ssh{identities{id:{private,public}},known_hosts}`. The decrypted snapshot
//! lives only in memory; the repository holds `storage.json` plus either the
//! age set (`recipient.txt`, `unlock.age`, `state.json.age`) or plain files.
//! `github-runtime/` is the materialized working copy with machine-encrypted
//! passwords; it never enters git.

use std::collections::BTreeMap;
use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::path::{Path, PathBuf};
use std::str::FromStr;

use age::secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use super::{Storage, exec, fail, random_hex, utc_stamp};
use crate::error::{RcError, Result};
use crate::locking::LockManager;
use crate::model::{
    Access, Auth, Config, KnownHosts, Manifest, Portability, PortabilityIssue, PortabilityReason,
    TemplateMetadata, endpoint_key,
};
use crate::secure_fs;
use crate::state::{State, StatePaths, read_optional};
use crate::validation as v;

/// Current snapshot format and the oldest essence-rc that reads it.
pub const FORMAT: u64 = 1;
pub const FORMAT_MIN_VERSION: &str = "2.1.0";

/// Registered format migrations `(from, step)`; none exist for format 1.
const MIGRATIONS: &[(u64, fn(Value) -> Option<Value>)] = &[];

const READ_STAGE: &str = "чтение конфигурации GitHub";
const FORMAT_STAGE: &str = "проверка формата конфигурации GitHub";
const TREE_STAGE: &str = "проверка файлов репозитория GitHub";

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub vault_version: u64,
    pub minimum_remote_control_version: String,
    pub portability: Portability,
    pub access: Access,
    pub config: Config,
    pub secrets: PortableSecrets,
    pub templates: BTreeMap<String, VaultTemplate>,
    pub ssh: VaultSsh,
    /// Owned secrets (other than SSH passwords) this machine could not
    /// decrypt; `checkpoint` keeps their previous vault values. Never written.
    #[serde(skip)]
    pub unreadable: Vec<String>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PortableSecrets {
    pub schema_version: u32,
    pub node_passwords: BTreeMap<String, Zeroizing<String>>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VaultTemplate {
    pub content: String,
    pub source: String,
    pub sha256: String,
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VaultSsh {
    pub identities: BTreeMap<String, VaultIdentity>,
    pub known_hosts: KnownHosts,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VaultIdentity {
    pub private: Zeroizing<String>,
    pub public: String,
}

fn invalid_format() -> RcError {
    format_error("invalid", "Снимок конфигурации имеет некорректную структуру.", None, None)
}

/// `github_format_{outdated|newer|invalid}` with v1's `{version, required}`.
pub fn format_error(kind: &str, message: impl Into<String>, version: Option<u64>, required: Option<String>) -> RcError {
    let code = match kind {
        "outdated" => "github_format_outdated",
        "newer" => "github_format_newer",
        _ => "github_format_invalid",
    };
    RcError::new(code, message)
        .with_extra("stage", FORMAT_STAGE)
        .with_extra("version", version.map(|v| v.to_string()))
        .with_extra("required", required)
}

pub fn is_format_error(error: &RcError) -> bool {
    error.code.starts_with("github_format_")
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn version_gt(left: &str, right: &str) -> bool {
    match (semver::Version::parse(left), semver::Version::parse(right)) {
        (Ok(left), Ok(right)) => left > right,
        _ => false,
    }
}

/// A portable secret belongs to an existing node or profile.
fn secret_owned(config: &Config, id: &str) -> bool {
    match v::secret_owner(id) {
        Some(v::SecretOwner::Node(node)) => config.nodes.iter().any(|candidate| candidate.id == node),
        Some(v::SecretOwner::Profile(name)) => config.find_profile(name).is_some(),
        None => false,
    }
}

impl Snapshot {
    pub fn counts(&self) -> Value {
        json!({"nodes": self.config.nodes.len(), "clients": self.config.clients.len(), "groups": self.config.groups.len()})
    }

    /// v1 `github_config_validate`: structure, linkage and portability agree.
    pub fn validate(&self) -> Result<()> {
        let check = |ok: bool| if ok { Ok(()) } else { Err(invalid_format()) };
        check(self.vault_version == FORMAT && self.secrets.schema_version == 2)?;
        check(v::version_valid(&self.minimum_remote_control_version))?;
        self.config.validate().map_err(|_| invalid_format())?;
        for (id, password) in &self.secrets.node_passwords {
            check(secret_owned(&self.config, id) && v::secret_value_valid(id, password))?;
        }
        let issues = &self.portability.issues;
        check(Portability::from_issues(issues.clone()) == self.portability)?;
        for issue in issues {
            check(self.config.nodes.iter().any(|node| node.id == issue.node_id))?;
        }
        for node in &self.config.nodes {
            let missing = issues.iter().any(|i| i.node_id == node.id && i.reason == PortabilityReason::MissingSecret);
            match node.auth {
                Auth::Password => {
                    let present = node.secret_id.as_ref().is_some_and(|id| self.secrets.node_passwords.contains_key(id));
                    check(present != missing)?;
                }
                Auth::Key => {
                    check(!missing)?;
                    match node.identity.as_deref() {
                        None | Some("" | "system") => {
                            check(issues.iter().any(|i| i.node_id == node.id && i.reason == PortabilityReason::MissingIdentity))?;
                        }
                        Some(id) => check(self.ssh.identities.contains_key(id))?,
                    }
                }
            }
        }
        for name in self.templates.keys() {
            check(v::template_filename_valid(name))?;
        }
        for (id, identity) in &self.ssh.identities {
            check(v::node_id_valid(id) && !identity.private.is_empty() && !identity.public.is_empty())?;
        }
        Ok(())
    }
}

/// Raw JSON → current snapshot (v1 `github_config_upgrade`). Newer formats and
/// newer minimum versions are refused; older formats migrate only on request.
/// A snapshot of the Bash 1.x client (its own format numbering, minimum below
/// [`FORMAT_MIN_VERSION`]) is not a newer format: v2 does not read it, so it is
/// `github_format_invalid` (the repository content may be replaced), never
/// «обновите essence-rc».
pub fn upgrade(mut raw: Value, migrate: bool) -> Result<Snapshot> {
    if !raw.is_object() {
        return Err(invalid_format());
    }
    let version = raw.get("vault_version").and_then(Value::as_u64).ok_or_else(invalid_format)?;
    let minimum = match raw.get("minimum_remote_control_version") {
        None | Some(Value::Null) => None,
        Some(Value::String(text)) if v::version_valid(text) => Some(text.clone()),
        Some(_) => return Err(format_error("invalid", "Снимок конфигурации имеет некорректную структуру.", Some(version), None)),
    };
    if let Some(legacy) = minimum.as_deref().filter(|minimum| version > FORMAT && version_gt(FORMAT_MIN_VERSION, minimum)) {
        return Err(format_error("invalid", format!(
            "Конфигурация GitHub создана Remote Control {legacy} (Bash-версия, формат v{version}) и не поддерживается этой версией."),
            Some(version), None));
    }
    if let Some(minimum) = minimum.filter(|minimum| version_gt(minimum, crate::VERSION)) {
        return Err(format_error("newer", format!(
            "Конфигурация GitHub создана Remote Control {minimum}; установлена версия {}. Обновите essence-rc и запустите снова.",
            crate::VERSION), Some(version), Some(minimum)));
    }
    if version > FORMAT {
        return Err(format_error("newer", format!(
            "Конфигурация GitHub имеет формат v{version}; эта версия поддерживает до v{FORMAT}. Обновите essence-rc и запустите снова."),
            Some(version), None));
    }
    let mut current = version;
    while current < FORMAT {
        if !migrate {
            return Err(format_error("outdated", format!(
                "Конфигурация GitHub в формате v{version}; текущий формат v{FORMAT}. Требуется преобразование."),
                Some(version), None));
        }
        let step = MIGRATIONS.iter().find(|(from, _)| *from == current).map(|(_, step)| *step);
        raw = step.and_then(|step| step(raw.clone())).ok_or_else(|| format_error("invalid", format!(
            "Не удалось преобразовать конфигурацию GitHub из формата v{version}."), Some(version), None))?;
        current += 1;
    }
    if let Some(config) = raw.get_mut("config") {
        Config::upgrade_value(config);
    }
    let snapshot: Snapshot = serde_json::from_value(raw).map_err(|_| invalid_format())?;
    snapshot.validate()?;
    Ok(snapshot)
}

// ─── Serialization from a state directory ────────────────────────────────────

fn regular_file(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_file() => Ok(true),
        Ok(_) => Err(RcError::new("unsafe_path", format!("Недопустимый тип пути: {}", path.display()))),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error.into()),
    }
}

fn read_text(path: &Path) -> Result<Option<Zeroizing<String>>> {
    if !regular_file(path)? {
        return Ok(None);
    }
    let bytes = read_optional(path)?.unwrap_or_default();
    String::from_utf8(bytes.to_vec()).map(|text| Some(Zeroizing::new(text)))
        .map_err(|_| RcError::new("invalid", format!("Файл не в UTF-8: {}", path.display())))
}

fn yaml_names(dir: &Path) -> Result<Vec<String>> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.into()),
    };
    let mut names = Vec::new();
    for entry in entries {
        let name = entry?.file_name().to_string_lossy().into_owned();
        if v::template_filename_valid(&name) && regular_file(&dir.join(&name))? {
            names.push(name);
        }
    }
    names.sort();
    Ok(names)
}

/// Build the portable snapshot of a state directory (v1 `github_config_serialize`).
/// Unreadable passwords and unfinished SSH portability become issues; this is
/// the only boundary that exports machine-encrypted passwords as plaintext.
pub fn serialize(state: &State) -> Result<Snapshot> {
    let config = state.load_config()?;
    let manifest = state.load_manifest()?;
    let known_hosts = state.load_known_hosts()?;
    let store = state.secret_store();
    store.validate()?;
    let mut issues = Vec::new();
    let mut passwords = BTreeMap::new();
    let mut identities = BTreeMap::new();
    for node in &config.nodes {
        let mut issue = |reason| issues.push(PortabilityIssue { node_id: node.id.clone(), reason });
        match node.auth {
            Auth::Password => {
                let id = node.secret_id.as_deref().unwrap_or_default();
                match store.get(id) {
                    Ok(Some(password)) => { passwords.insert(id.to_owned(), password); }
                    Ok(None) => issue(PortabilityReason::MissingSecret),
                    Err(error) if error.code == "missing_secret" => issue(PortabilityReason::MissingSecret),
                    Err(error) => return Err(error),
                }
            }
            Auth::Key => match node.identity.as_deref() {
                None | Some("" | "system") => issue(PortabilityReason::MissingIdentity),
                Some(id) => {
                    let private = read_text(&state.paths().identities().join(id))?;
                    let public = read_text(&state.paths().identities().join(format!("{id}.pub")))?;
                    let (Some(private), Some(public)) = (private, public) else {
                        return Err(RcError::new("invalid", format!("Нет переносимого SSH-ключа ноды «{}».", node.name)));
                    };
                    identities.insert(id.to_owned(), VaultIdentity { private, public: public.to_string() });
                }
            },
        }
        let pinned = endpoint_key(&node.ip, node.port).ok()
            .and_then(|key| known_hosts.0.get(&key)).is_some_and(|fps| !fps.is_empty());
        if !pinned {
            issue(PortabilityReason::MissingHostKey);
        }
    }
    // Every other machine secret of an existing node or profile travels too.
    // One this machine cannot decrypt (lost machine key) is not dropped from
    // the vault: `checkpoint` keeps its previous value. Unlike an SSH password
    // it cannot be entered again, and the vault may hold the only copy.
    let mut unreadable = Vec::new();
    for id in store.ids()? {
        if !secret_owned(&config, &id) || id.ends_with(":ssh-password") {
            continue;
        }
        match store.get(&id) {
            Ok(Some(secret)) => { passwords.insert(id, secret); }
            Ok(None) => {}
            Err(error) if error.code == "missing_secret" => unreadable.push(id),
            Err(error) => return Err(error),
        }
    }
    let mut templates = BTreeMap::new();
    for name in yaml_names(state.paths().templates())? {
        let content = read_text(&state.paths().templates().join(&name))?.unwrap_or_default();
        let source = manifest.templates.get(&name).and_then(|m| m.source.clone()).unwrap_or_else(|| "custom".into());
        templates.insert(name, VaultTemplate { sha256: sha256_hex(content.as_bytes()), content: content.to_string(), source });
    }
    let snapshot = Snapshot {
        vault_version: FORMAT,
        minimum_remote_control_version: FORMAT_MIN_VERSION.into(),
        portability: Portability::from_issues(issues),
        access: Access { script_password_hash: state.auth_store().hash()? },
        config,
        secrets: PortableSecrets { schema_version: 2, node_passwords: passwords },
        templates,
        ssh: VaultSsh { identities, known_hosts },
        unreadable,
    };
    snapshot.validate()?;
    Ok(snapshot)
}

/// The snapshot of an empty configuration (account change without a cache).
pub fn empty_snapshot() -> Snapshot {
    Snapshot {
        vault_version: FORMAT,
        minimum_remote_control_version: FORMAT_MIN_VERSION.into(),
        portability: Portability::default(),
        access: Access::default(),
        config: Config::default(),
        secrets: PortableSecrets { schema_version: 2, node_passwords: BTreeMap::new() },
        templates: BTreeMap::new(),
        ssh: VaultSsh::default(),
        unreadable: Vec::new(),
    }
}

// ─── Repository tree allowlist ───────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum TreeMode { Auto, Age, Plain }

impl From<Storage> for TreeMode {
    fn from(storage: Storage) -> Self {
        match storage {
            Storage::Age => Self::Age,
            Storage::Plain => Self::Plain,
        }
    }
}

const AGE_FILES: [&str; 4] = ["storage.json", "recipient.txt", "unlock.age", "state.json.age"];
const PLAIN_FILES: [&str; 5] = ["storage.json", "config.json", "secrets.json", "manifest.json", "ssh/known-hosts.json"];
const PLAIN_DIRS: [&str; 3] = ["templates", "ssh", "ssh/identities"];

fn allowed_file(mode: TreeMode, rel: &str) -> bool {
    let age = mode != TreeMode::Plain && AGE_FILES.contains(&rel);
    let plain = mode != TreeMode::Age && (PLAIN_FILES.contains(&rel)
        || rel.strip_prefix("templates/").is_some_and(v::template_filename_valid)
        || rel.strip_prefix("ssh/identities/").is_some_and(|name| v::node_id_valid(name.strip_suffix(".pub").unwrap_or(name))));
    age || plain
}

fn allowed_dir(mode: TreeMode, rel: &str) -> bool {
    mode != TreeMode::Age && PLAIN_DIRS.contains(&rel)
}

fn tree_error(rel: &str) -> RcError {
    fail(TREE_STAGE, format!("В хранилище конфигурации GitHub обнаружен недопустимый путь: {rel}"))
}

/// v1 `_github_validate_tree`: only allowlisted regular files and directories;
/// symlinks, special files and unknown names fail. `.git` at the root may be
/// the worktree's gitdir pointer file.
pub fn validate_tree(root: &Path, mode: TreeMode) -> Result<()> {
    let meta = fs::symlink_metadata(root).map_err(|_| fail(TREE_STAGE, "Корень рабочей копии GitHub недоступен."))?;
    if !meta.is_dir() {
        return Err(fail(TREE_STAGE, "Корень рабочей копии GitHub не является обычным каталогом."));
    }
    let mut pending = vec![(root.to_path_buf(), String::new())];
    while let Some((dir, prefix)) = pending.pop() {
        for entry in fs::read_dir(&dir)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            let rel = if prefix.is_empty() { name.clone() } else { format!("{prefix}/{name}") };
            let kind = fs::symlink_metadata(entry.path())?.file_type();
            if prefix.is_empty() && name == ".git" {
                if kind.is_symlink() || !(kind.is_file() || kind.is_dir()) {
                    return Err(fail(TREE_STAGE, "Служебный путь .git имеет недопустимый тип."));
                }
                continue;
            }
            if kind.is_file() && allowed_file(mode, &rel) {
                continue;
            }
            if kind.is_dir() && allowed_dir(mode, &rel) {
                pending.push((entry.path(), rel));
                continue;
            }
            return Err(tree_error(&rel));
        }
    }
    Ok(())
}

/// v1 `_github_validate_tracked_tree`: every index entry is an allowlisted
/// regular blob (100644/100755) at stage 0.
pub fn validate_index(worktree: &Path, mode: TreeMode) -> Result<()> {
    let out = exec::tree_git(worktree, &["ls-files".as_ref(), "--stage".as_ref(), "-z".as_ref()])?;
    if !out.success {
        return Err(fail(TREE_STAGE, "Не удалось проверить список файлов репозитория GitHub."));
    }
    for entry in out.stdout.split(|b| *b == 0).filter(|e| !e.is_empty()) {
        let entry = String::from_utf8_lossy(entry);
        let (meta, rel) = entry.split_once('\t').unwrap_or((&entry, ""));
        let fields: Vec<&str> = meta.split(' ').collect();
        let valid = fields.len() == 3 && matches!(fields[0], "100644" | "100755") && fields[2] == "0" && allowed_file(mode, rel);
        if !valid {
            return Err(fail(TREE_STAGE, format!("В индексе GitHub обнаружен недопустимый путь или тип: {rel}")));
        }
    }
    Ok(())
}

// ─── storage.json ────────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StorageFile {
    storage_version: u32,
    encryption: String,
}

pub fn read_storage(worktree: &Path) -> Result<Storage> {
    validate_tree(worktree, TreeMode::Auto)?;
    let bytes = match read_text(&worktree.join("storage.json")) {
        Ok(Some(text)) if !text.is_empty() => text,
        _ => return Err(fail("чтение параметров хранения GitHub", "Не удалось прочитать параметры хранения конфигурации GitHub.")),
    };
    serde_json::from_str::<StorageFile>(&bytes).ok()
        .filter(|file| file.storage_version == 1)
        .and_then(|file| Storage::parse(&file.encryption))
        .ok_or_else(|| fail("проверка параметров хранения GitHub", "Параметры хранения конфигурации GitHub имеют некорректный формат."))
}

pub fn write_storage(worktree: &Path, storage: Storage) -> Result<()> {
    let text = format!("{{\"storage_version\":1,\"encryption\":\"{}\"}}\n", storage.as_str());
    secure_fs::atomic_write(&worktree.join("storage.json"), text.as_bytes())?;
    Ok(())
}

// ─── Plain repository files ──────────────────────────────────────────────────

#[derive(Serialize, Deserialize)]
struct PlainTemplate {
    source: String,
    sha256: String,
}

#[derive(Serialize, Deserialize)]
struct PlainManifest {
    vault_version: Value,
    #[serde(default)]
    minimum_remote_control_version: Option<String>,
    portability: Portability,
    access: Access,
    #[serde(default)]
    templates: BTreeMap<String, PlainTemplate>,
}

fn json_bytes(value: &impl Serialize) -> Result<Zeroizing<Vec<u8>>> {
    let mut bytes = Zeroizing::new(serde_json::to_vec_pretty(value)?);
    bytes.push(b'\n');
    Ok(bytes)
}

fn write_plain_tree(dir: &Path, snapshot: &Snapshot) -> Result<()> {
    secure_fs::create_dir_all(&dir.join("templates"))?;
    secure_fs::create_dir_all(&dir.join("ssh/identities"))?;
    secure_fs::atomic_write(&dir.join("config.json"), &json_bytes(&snapshot.config)?)?;
    secure_fs::atomic_write(&dir.join("secrets.json"), &json_bytes(&snapshot.secrets)?)?;
    let manifest = PlainManifest {
        vault_version: json!(snapshot.vault_version),
        minimum_remote_control_version: Some(snapshot.minimum_remote_control_version.clone()),
        portability: snapshot.portability.clone(),
        access: snapshot.access.clone(),
        templates: snapshot.templates.iter()
            .map(|(name, t)| (name.clone(), PlainTemplate { source: t.source.clone(), sha256: t.sha256.clone() })).collect(),
    };
    secure_fs::atomic_write(&dir.join("manifest.json"), &json_bytes(&manifest)?)?;
    secure_fs::atomic_write(&dir.join("ssh/known-hosts.json"), &json_bytes(&snapshot.ssh.known_hosts)?)?;
    for (name, template) in &snapshot.templates {
        secure_fs::atomic_write(&dir.join("templates").join(name), template.content.as_bytes())?;
    }
    for (id, identity) in &snapshot.ssh.identities {
        secure_fs::atomic_write(&dir.join("ssh/identities").join(id), identity.private.as_bytes())?;
        secure_fs::atomic_write(&dir.join("ssh/identities").join(format!("{id}.pub")), identity.public.as_bytes())?;
    }
    Ok(())
}

fn remove_path(path: &Path) -> std::io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_dir() => fs::remove_dir_all(path),
        Ok(_) => fs::remove_file(path),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

const PLAIN_TOP: [&str; 5] = ["config.json", "secrets.json", "manifest.json", "ssh", "templates"];

/// Publish the plain file set: stage a complete tree, move the previous one
/// aside, then move the staged paths in; any failure restores the old tree.
fn write_plain(worktree: &Path, snapshot: &Snapshot) -> Result<()> {
    validate_tree(worktree, TreeMode::Auto)?;
    let stage = worktree.join(format!(".plain-write.{}", random_hex(6)));
    let backup = worktree.join(format!(".plain-backup.{}", random_hex(6)));
    secure_fs::create_dir(&stage)?;
    let result = (|| -> Result<()> {
        write_plain_tree(&stage, snapshot)?;
        secure_fs::create_dir(&backup)?;
        let mut moved = Vec::new();
        let mut published = Vec::new();
        let outcome = (|| -> std::io::Result<()> {
            for name in PLAIN_TOP {
                if fs::symlink_metadata(worktree.join(name)).is_ok() {
                    fs::rename(worktree.join(name), backup.join(name))?;
                    moved.push(name);
                }
            }
            for name in PLAIN_TOP {
                fs::rename(stage.join(name), worktree.join(name))?;
                published.push(name);
            }
            Ok(())
        })();
        if let Err(error) = outcome {
            for name in published {
                let _ = remove_path(&worktree.join(name));
            }
            for name in moved {
                let _ = fs::rename(backup.join(name), worktree.join(name));
            }
            return Err(error.into());
        }
        Ok(())
    })();
    let _ = remove_path(&stage);
    let _ = remove_path(&backup);
    result.map_err(|error| fail("сохранение снимка конфигурации GitHub", format!("Не удалось сохранить снимок в рабочей копии GitHub: {}", error.message)))
}

fn parse_json<T: for<'de> Deserialize<'de>>(text: &str) -> Result<T> {
    serde_json::from_str(text).map_err(|_| invalid_format())
}

/// Assemble the raw snapshot JSON from plain files (v1 `_github_plain_read`).
fn read_plain(worktree: &Path) -> Result<Value> {
    validate_tree(worktree, TreeMode::Plain)?;
    validate_index(worktree, TreeMode::Plain)?;
    let required = |name: &str| -> Result<Zeroizing<String>> {
        read_text(&worktree.join(name))?.ok_or_else(|| fail(READ_STAGE, format!("В конфигурации GitHub нет файла {name}.")))
    };
    let manifest: PlainManifest = parse_json(&required("manifest.json")?)?;
    let config: Value = parse_json(&required("config.json")?)?;
    let secrets: Value = parse_json(&required("secrets.json")?)?;
    let known_hosts: Value = match read_text(&worktree.join("ssh/known-hosts.json"))? {
        Some(text) => parse_json(&text)?,
        None => json!({}),
    };
    let mut templates = serde_json::Map::new();
    for name in yaml_names(&worktree.join("templates"))? {
        let content = read_text(&worktree.join("templates").join(&name))?.unwrap_or_default();
        let source = manifest.templates.get(&name).map_or("custom", |t| t.source.as_str());
        templates.insert(name, json!({"content": content.as_str(), "source": source, "sha256": sha256_hex(content.as_bytes())}));
    }
    let mut identities = serde_json::Map::new();
    let dir = worktree.join("ssh/identities");
    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries {
            let name = entry?.file_name().to_string_lossy().into_owned();
            if name.ends_with(".pub") {
                if read_text(&dir.join(name.trim_end_matches(".pub")))?.is_none() {
                    return Err(invalid_format());
                }
                continue;
            }
            let private = read_text(&dir.join(&name))?.unwrap_or_default();
            let public = read_text(&dir.join(format!("{name}.pub")))?.ok_or_else(invalid_format)?;
            identities.insert(name, json!({"private": private.as_str(), "public": public.as_str()}));
        }
    }
    Ok(json!({
        "vault_version": manifest.vault_version,
        "minimum_remote_control_version": manifest.minimum_remote_control_version,
        "portability": manifest.portability,
        "access": manifest.access,
        "config": config,
        "secrets": secrets,
        "templates": templates,
        "ssh": {"identities": identities, "known_hosts": known_hosts},
    }))
}

// ─── age: x25519 recipient + scrypt-wrapped identity ─────────────────────────

/// The vault key of an open session; never persisted except `--remember-key`.
#[derive(Clone)]
pub struct Keys {
    pub identity: age::x25519::Identity,
    pub recipient: String,
}

impl Keys {
    pub fn generate() -> Self {
        let identity = age::x25519::Identity::generate();
        let recipient = identity.to_public().to_string();
        Self { identity, recipient }
    }

    /// age-keygen identity file text.
    pub fn identity_file(&self) -> Zeroizing<String> {
        let stamp = utc_stamp();
        let created = format!("{}-{}-{}T{}:{}:{}Z", &stamp[0..4], &stamp[4..6], &stamp[6..8], &stamp[9..11], &stamp[11..13], &stamp[13..15]);
        Zeroizing::new(format!("# created: {created}\n# public key: {}\n{}\n", self.recipient, self.identity.to_string().expose_secret()))
    }

    /// Parse age-keygen output (comments ignored); exactly one X25519 key.
    pub fn parse(text: &str) -> Option<Self> {
        let mut keys = text.lines().map(str::trim).filter(|line| !line.is_empty() && !line.starts_with('#'));
        let identity = age::x25519::Identity::from_str(keys.next()?).ok()?;
        if keys.next().is_some() {
            return None;
        }
        let recipient = identity.to_public().to_string();
        Some(Self { identity, recipient })
    }
}

pub fn recipient_valid(text: &str) -> bool {
    text.starts_with("age1") && age::x25519::Recipient::from_str(text).is_ok()
}

fn age_failed(stage: &str, message: &str) -> RcError {
    fail(stage, message)
}

pub fn encrypt_to(recipient: &str, plaintext: &[u8]) -> Result<Vec<u8>> {
    let stage = "шифрование снимка конфигурации GitHub";
    let recipient = age::x25519::Recipient::from_str(recipient).map_err(|_| age_failed(stage, "Некорректный recipient хранилища."))?;
    let encryptor = age::Encryptor::with_recipients(std::iter::once(&recipient as &dyn age::Recipient))
        .map_err(|_| age_failed(stage, "Не удалось подготовить шифрование age."))?;
    let mut output = Vec::new();
    let mut writer = encryptor.wrap_output(&mut output)?;
    writer.write_all(plaintext)?;
    writer.finish()?;
    Ok(output)
}

pub fn decrypt_with(identity: &age::x25519::Identity, ciphertext: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
    let decryptor = age::Decryptor::new(ciphertext).ok()?;
    if decryptor.is_scrypt() {
        return None;
    }
    let mut reader = decryptor.decrypt(std::iter::once(identity as &dyn age::Identity)).ok()?;
    let mut plaintext = Zeroizing::new(Vec::new());
    reader.read_to_end(&mut plaintext).ok()?;
    Some(plaintext)
}

/// scrypt `log_n` of a new `unlock.age`: age's default (v1 wrote it through
/// `age -j batchpass`), fixed rather than calibrated to the creating machine,
/// so every device opens the file within [`SCRYPT_MAX_WORK_FACTOR`].
const SCRYPT_WORK_FACTOR: u8 = 18;
/// The highest `log_n` accepted from a repository (the reference age cap).
const SCRYPT_MAX_WORK_FACTOR: u8 = 22;

/// `unlock.age`: the identity file encrypted with an scrypt passphrase.
pub fn wrap_identity(keys: &Keys, password: &str) -> Result<Vec<u8>> {
    let mut recipient = age::scrypt::Recipient::new(SecretString::from(password.to_owned()));
    recipient.set_work_factor(SCRYPT_WORK_FACTOR);
    let encryptor = age::Encryptor::with_recipients(std::iter::once(&recipient as &dyn age::Recipient))
        .map_err(|_| age_failed("шифрование ключа конфигурации GitHub", "Не удалось подготовить шифрование age."))?;
    let mut output = Vec::new();
    let mut writer = encryptor.wrap_output(&mut output)?;
    writer.write_all(keys.identity_file().as_bytes())?;
    writer.finish()?;
    Ok(output)
}

/// `None`: wrong passphrase. A malformed envelope or key is a format error;
/// an over-limit work factor is neither, so it never reads as foreign data.
pub fn unwrap_identity(unlock: &[u8], password: &str) -> Result<Option<Keys>> {
    let decryptor = age::Decryptor::new(unlock).map_err(|_| invalid_format())?;
    if !decryptor.is_scrypt() {
        return Err(invalid_format());
    }
    let mut identity = age::scrypt::Identity::new(SecretString::from(password.to_owned()));
    identity.set_max_work_factor(SCRYPT_MAX_WORK_FACTOR);
    let mut reader = match decryptor.decrypt(std::iter::once(&identity as &dyn age::Identity)) {
        Ok(reader) => reader,
        Err(age::DecryptError::DecryptionFailed | age::DecryptError::NoMatchingKeys | age::DecryptError::KeyDecryptionFailed) => return Ok(None),
        Err(age::DecryptError::ExcessiveWork { required, .. }) => return Err(RcError::new("vault_work_excessive", format!(
            "Файл unlock.age защищён слишком сложным параметром scrypt (2^{required}, допустимо не больше 2^{SCRYPT_MAX_WORK_FACTOR}): расшифровка остановлена."))
            .with_extra("required", required).with_extra("max", SCRYPT_MAX_WORK_FACTOR)),
        Err(_) => return Err(invalid_format()),
    };
    let mut text = Zeroizing::new(Vec::new());
    reader.read_to_end(&mut text).map_err(|_| invalid_format())?;
    let text = std::str::from_utf8(&text).map_err(|_| invalid_format())?;
    Keys::parse(text).map(Some).ok_or_else(invalid_format)
}

/// Write `recipient.txt` and `unlock.age` together; a failure restores both.
pub fn publish_keys(worktree: &Path, keys: &Keys, password: &str) -> Result<()> {
    let unlock = wrap_identity(keys, password)?;
    let old: Vec<(PathBuf, Option<Zeroizing<Vec<u8>>>)> = ["recipient.txt", "unlock.age"].iter()
        .map(|name| Ok((worktree.join(name), read_optional(&worktree.join(name))?)))
        .collect::<Result<_>>()?;
    let result = secure_fs::atomic_write(&worktree.join("recipient.txt"), format!("{}\n", keys.recipient).as_bytes())
        .and_then(|()| secure_fs::atomic_write(&worktree.join("unlock.age"), &unlock));
    if result.is_err() {
        for (path, bytes) in old {
            let _ = match bytes {
                Some(bytes) => secure_fs::atomic_write(&path, &bytes),
                None => remove_path(&path),
            };
        }
        return Err(fail("сохранение параметров шифрования", "Не удалось опубликовать комплект ключей age."));
    }
    Ok(())
}

pub fn read_recipient(worktree: &Path) -> Result<String> {
    let recipient = read_text(&worktree.join("recipient.txt"))?.map(|text| text.trim().to_owned()).unwrap_or_default();
    if !recipient_valid(&recipient) {
        return Err(format_error("invalid", "В зашифрованной конфигурации GitHub отсутствует единственный корректный recipient.", None, None));
    }
    Ok(recipient)
}

// ─── Worktree checkpoint and read ────────────────────────────────────────────

/// `snapshot` with the previous vault values of its unreadable secrets, or
/// `None` when there is nothing to carry (no unreadable secret, no previous
/// snapshot, or the previous one lacks them as well).
fn carry_unreadable(worktree: &Path, keys: Option<&Keys>, snapshot: &Snapshot) -> Result<Option<Snapshot>> {
    if snapshot.unreadable.is_empty() || read_optional(&worktree.join("storage.json"))?.is_none() {
        return Ok(None);
    }
    let previous = read_storage(worktree).and_then(|storage| read_raw(worktree, storage, keys)).map_err(|error| {
        fail("сохранение снимка конфигурации GitHub", format!(
            "Секреты, которые это устройство не может расшифровать, сохранились бы только в прежнем снимке, \
             но его не удалось прочитать: {}", error.message))
    })?;
    let mut merged = snapshot.clone();
    for id in &snapshot.unreadable {
        if let Some(value) = previous["secrets"]["node_passwords"][id.as_str()].as_str() {
            merged.secrets.node_passwords.insert(id.clone(), Zeroizing::new(value.to_owned()));
        }
    }
    Ok((merged.secrets.node_passwords.len() != snapshot.secrets.node_passwords.len()).then_some(merged))
}

/// v1 `github_config_checkpoint`: write the snapshot into the worktree in the
/// repository's storage mode, creating `storage.json` on first use. Nothing
/// is committed here. Secrets this machine could not decrypt
/// (`snapshot.unreadable`) keep their values from the snapshot already in
/// the worktree; if that snapshot cannot be read, nothing is written.
pub fn checkpoint(worktree: &Path, storage: Storage, keys: Option<&Keys>, snapshot: &Snapshot) -> Result<()> {
    let carried;
    let snapshot = match carry_unreadable(worktree, keys, snapshot)? {
        Some(merged) => {
            carried = merged;
            &carried
        }
        None => snapshot,
    };
    snapshot.validate()?;
    validate_tree(worktree, TreeMode::Auto)?;
    let created_storage = read_optional(&worktree.join("storage.json"))?.is_none();
    if created_storage {
        write_storage(worktree, storage)?;
    }
    let result = match storage {
        Storage::Plain => write_plain(worktree, snapshot),
        Storage::Age => (|| {
            let recipient = match keys {
                Some(keys) => keys.recipient.clone(),
                None => read_recipient(worktree)?,
            };
            let plaintext = Zeroizing::new(serde_json::to_vec(snapshot)?);
            let ciphertext = encrypt_to(&recipient, &plaintext)?;
            secure_fs::atomic_write(&worktree.join("state.json.age"), &ciphertext)
                .map_err(|_| fail("сохранение снимка конфигурации GitHub", "Не удалось атомарно зашифровать снимок конфигурации GitHub."))
        })(),
    };
    if result.is_err() && created_storage {
        let _ = fs::remove_file(worktree.join("storage.json"));
    }
    result
}

/// Read the raw snapshot JSON: plain files, or `state.json.age` decrypted with
/// `keys` (the caller unlocked them against `recipient.txt`).
pub fn read_raw(worktree: &Path, storage: Storage, keys: Option<&Keys>) -> Result<Value> {
    validate_tree(worktree, storage.into())?;
    validate_index(worktree, storage.into())?;
    match storage {
        Storage::Plain => read_plain(worktree),
        Storage::Age => {
            let keys = keys.ok_or_else(|| fail(READ_STAGE, "Ключ расшифровки недоступен."))?;
            let ciphertext = read_optional(&worktree.join("state.json.age"))?.filter(|bytes| !bytes.is_empty())
                .ok_or_else(|| fail(READ_STAGE, "Зашифрованная конфигурация GitHub не содержит state.json.age."))?;
            let plaintext = decrypt_with(&keys.identity, &ciphertext)
                .ok_or_else(|| fail("расшифровка конфигурации GitHub", "Не удалось расшифровать конфигурацию GitHub."))?;
            serde_json::from_slice(&plaintext).map_err(|_| invalid_format())
        }
    }
}

pub fn counts_of(raw: &Value) -> Value {
    let count = |key: &str| raw.pointer(&format!("/config/{key}")).and_then(Value::as_array).map_or(0, Vec::len);
    json!({"nodes": count("nodes"), "clients": count("clients"), "groups": count("groups")})
}

/// «нод N, клиентов M, групп K» or «не читается».
pub fn counts_label(counts: &Value) -> String {
    match (counts["nodes"].as_u64(), counts["clients"].as_u64(), counts["groups"].as_u64()) {
        (Some(nodes), Some(clients), Some(groups)) => format!("нод {nodes}, клиентов {clients}, групп {groups}"),
        _ => "не читается".into(),
    }
}

// ─── Materialization into github-runtime/ ────────────────────────────────────

fn write_runtime(state: &State, snapshot: &Snapshot) -> Result<()> {
    let paths = state.paths();
    secure_fs::create_dir_all(paths.templates())?;
    secure_fs::create_dir_all(paths.identities())?;
    state.save_config(&snapshot.config)?;
    state.save_known_hosts(&snapshot.ssh.known_hosts)?;
    let store = state.secret_store();
    for (id, password) in &snapshot.secrets.node_passwords {
        store.set(id, password.clone())?;
    }
    let templates = snapshot.templates.iter().map(|(name, t)| (name.clone(), TemplateMetadata {
        content: None, source: Some(t.source.clone()), snapshot_sha256: Some(t.sha256.clone()), ignored_builtin_sha256: None,
    })).collect();
    state.save_manifest(&Manifest {
        schema_version: 2,
        minimum_remote_control_version: snapshot.minimum_remote_control_version.clone(),
        portability: snapshot.portability.clone(),
        access: snapshot.access.clone(),
        templates,
    })?;
    for (name, template) in &snapshot.templates {
        secure_fs::atomic_write(&paths.templates().join(name), template.content.as_bytes())?;
    }
    for (id, identity) in &snapshot.ssh.identities {
        secure_fs::atomic_write(&paths.identities().join(id), identity.private.as_bytes())?;
        secure_fs::atomic_write(&paths.identities().join(format!("{id}.pub")), identity.public.as_bytes())?;
    }
    // Read everything back through the normal loaders before publication.
    state.load_config()?;
    state.load_manifest()?;
    state.load_known_hosts()?;
    state.secret_store().validate()?;
    Ok(())
}

/// v1 `_config_source_materialize_state`: build `github-runtime/` in a private
/// stage, swap it in atomically, then publish the script password hash; a
/// failure of the hash restores the previous runtime and `auth.txt`.
pub fn materialize(root: &StatePaths, locks: &LockManager, snapshot: &Snapshot) -> Result<()> {
    snapshot.validate()?;
    let stage_dir = root.root().join(format!(".github-runtime.stage.{}", random_hex(6)));
    secure_fs::create_dir_all(root.root())?;
    secure_fs::create_dir(&stage_dir)?;
    let stage = State::with_locks(root.with_state_dir(&stage_dir), locks.clone());
    if let Err(error) = write_runtime(&stage, snapshot) {
        let _ = remove_path(&stage_dir);
        return Err(fail("подготовка рабочего состояния", format!("Восстановленное состояние GitHub не прошло проверку: {}", error.message)));
    }
    let runtime = root.github_runtime();
    let retired = root.root().join(format!(".github-runtime.retired.{}", random_hex(6)));
    let had_runtime = fs::symlink_metadata(&runtime).is_ok();
    let swap = (|| -> std::io::Result<()> {
        if had_runtime {
            fs::rename(&runtime, &retired)?;
        }
        if let Err(error) = fs::rename(&stage_dir, &runtime) {
            if had_runtime {
                fs::rename(&retired, &runtime)?;
            }
            return Err(error);
        }
        Ok(())
    })();
    if swap.is_err() {
        let _ = remove_path(&stage_dir);
        return Err(fail("публикация рабочего состояния", "Не удалось атомарно опубликовать новое рабочее состояние."));
    }
    let auth = root.local().auth().to_path_buf();
    let old_auth = read_optional(&auth)?;
    let auth_store = State::with_locks(root.local(), locks.clone()).auth_store();
    let published = match snapshot.access.script_password_hash.as_deref() {
        Some(hash) => auth_store.set_hash(hash),
        None => auth_store.remove(),
    };
    if let Err(error) = published {
        let _ = remove_path(&runtime);
        if had_runtime {
            let _ = fs::rename(&retired, &runtime);
        }
        let _ = match old_auth {
            Some(bytes) => secure_fs::atomic_write(&auth, &bytes),
            None => remove_path(&auth),
        };
        return Err(fail("восстановление пароля запуска", error.message));
    }
    let _ = remove_path(&retired);
    Ok(())
}

// ─── Rollback copies of a state directory ────────────────────────────────────

/// Every regular file under a directory, in memory, for transaction rollback.
pub struct DirSnapshot {
    root: PathBuf,
    files: Vec<(PathBuf, Zeroizing<Vec<u8>>)>,
    extra: Vec<(PathBuf, Option<Zeroizing<Vec<u8>>>)>,
}

impl DirSnapshot {
    pub fn take(root: &Path, extra_files: &[&Path]) -> Result<Self> {
        let mut files = Vec::new();
        let mut pending = vec![root.to_path_buf()];
        while let Some(dir) = pending.pop() {
            let entries = match fs::read_dir(&dir) {
                Ok(entries) => entries,
                Err(error) if error.kind() == ErrorKind::NotFound => continue,
                Err(error) => return Err(error.into()),
            };
            for entry in entries {
                let path = entry?.path();
                let kind = fs::symlink_metadata(&path)?.file_type();
                if kind.is_dir() {
                    pending.push(path);
                } else if kind.is_file() {
                    let bytes = read_optional(&path)?.unwrap_or_default();
                    files.push((path, bytes));
                }
            }
        }
        let extra = extra_files.iter().map(|path| Ok((path.to_path_buf(), read_optional(path)?))).collect::<Result<_>>()?;
        Ok(Self { root: root.to_path_buf(), files, extra })
    }

    /// Rewrite the captured files, remove files created since, restore extras.
    pub fn restore(&self) -> Result<()> {
        let mut pending = vec![self.root.clone()];
        while let Some(dir) = pending.pop() {
            let Ok(entries) = fs::read_dir(&dir) else { continue };
            for entry in entries {
                let path = entry?.path();
                if fs::symlink_metadata(&path)?.is_dir() {
                    pending.push(path);
                } else if !self.files.iter().any(|(known, _)| *known == path) {
                    fs::remove_file(&path)?;
                }
            }
        }
        for (path, bytes) in &self.files {
            if let Some(parent) = path.parent() {
                secure_fs::create_dir_all(parent)?;
            }
            secure_fs::atomic_write(path, bytes)?;
        }
        for (path, bytes) in &self.extra {
            match bytes {
                Some(bytes) => secure_fs::atomic_write(path, bytes)?,
                None => remove_path(path)?,
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use crate::model::PortabilityStatus;

    /// C2SP age testkit vectors (`x25519`, `scrypt`), produced by an
    /// independent implementation: the payload's SHA-256 must match.
    const X25519_VECTOR: &str = "YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSBURWlGMHlwcXIrYnB2Y3FYTnlDVkpwTDdPdXdQZFZ3UEw3S1FFYkZET0NjCmhqYWJHWHdTTFE5YzNTNkx3MmkrUzJUdTJmaXdRSEhzbGJCTjZCNDFGTEUKLS0tIFd5SnA5Ri85Rk9aaDdnSmRoZXEyV0lKY3dIZ1ljOE5JVmgzZGR3aHJjTmcK7s9ix86RtDMnTmjU8vkTTLdMW/73vqpSyPC8DpksHoMx+2Y=";
    const X25519_IDENTITY: &str = "AGE-SECRET-KEY-1EGTZVFFV20835NWYV6270LXYVK2VKNX2MMDKWYKLMGR48UAWX40Q2P2LM0";
    const SCRYPT_VECTOR: &str = "YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IHNjcnlwdCByRjAvTndibFVISFRwZ1FnUnBlNUNRIDEwCmdVakV5bUZLTVZYUUVLZE1NSEwyNG9ZZXhqRTNUSUMwTzB6R1NxSjJhVVkKLS0tIElPWGlRWVN0a29UMW12WlcydEZPcVpkaFJWdmo1OGVnQUJ4L3NXZlpRYmMKGzXG5ofdANo6w3msn3QsIf0YWhuePe1znRSsappQEk24Ztg=";
    const PAYLOAD_SHA256: &str = "013f54400c82da08037759ada907a8b864e97de81c088a182062c4b5622fd2ab";

    fn vector(text: &str) -> Vec<u8> {
        base64::engine::general_purpose::STANDARD.decode(text).unwrap()
    }

    #[test]
    fn age_spec_vectors_decrypt_and_outputs_follow_the_spec_header() {
        let keys = Keys::parse(X25519_IDENTITY).unwrap();
        let plain = decrypt_with(&keys.identity, &vector(X25519_VECTOR)).unwrap();
        assert_eq!(sha256_hex(&plain), PAYLOAD_SHA256);
        let scrypt_file = vector(SCRYPT_VECTOR);
        let decryptor = age::Decryptor::new(&scrypt_file[..]).unwrap();
        let identity = age::scrypt::Identity::new(SecretString::from("password".to_owned()));
        let mut plain = Vec::new();
        decryptor.decrypt(std::iter::once(&identity as &dyn age::Identity)).unwrap().read_to_end(&mut plain).unwrap();
        assert_eq!(sha256_hex(&plain), PAYLOAD_SHA256);

        let ours = Keys::generate();
        let file = encrypt_to(&ours.recipient, b"snapshot").unwrap();
        let header = String::from_utf8_lossy(&file[..file.iter().position(|b| *b == b'-').unwrap() + 10]).into_owned();
        assert!(String::from_utf8_lossy(&file).starts_with("age-encryption.org/v1\n-> X25519 "), "{header}");
        assert_eq!(&decrypt_with(&ours.identity, &file).unwrap()[..], b"snapshot");
        let wrapped = wrap_identity(&ours, "vault-pass").unwrap();
        assert!(String::from_utf8_lossy(&wrapped).starts_with("age-encryption.org/v1\n-> scrypt "));
        // A fixed work factor within the unwrap limit; an over-limit one is
        // its own error, never a format error (which would offer replacement).
        let start = wrapped.iter().position(|b| *b == b'\n').unwrap() + 1;
        let end = start + wrapped[start..].iter().position(|b| *b == b'\n').unwrap();
        let stanza = std::str::from_utf8(&wrapped[start..end]).unwrap();
        let factor = stanza.rsplit(' ').next().unwrap();
        assert_eq!(factor, SCRYPT_WORK_FACTOR.to_string(), "{stanza}");
        assert!(SCRYPT_WORK_FACTOR <= SCRYPT_MAX_WORK_FACTOR);
        let mut heavy = wrapped[..end - factor.len()].to_vec();
        heavy.extend_from_slice((SCRYPT_MAX_WORK_FACTOR + 1).to_string().as_bytes());
        heavy.extend_from_slice(&wrapped[end..]);
        let error = unwrap_identity(&heavy, "vault-pass").err().expect("over-limit work factor");
        assert_eq!((error.code, &error.extra["required"]), ("vault_work_excessive", &json!(SCRYPT_MAX_WORK_FACTOR + 1)));
        assert!(unwrap_identity(&wrapped, "wrong").unwrap().is_none());
        let opened = unwrap_identity(&wrapped, "vault-pass").unwrap().unwrap();
        assert_eq!(opened.recipient, ours.recipient);
        let file = ours.identity_file();
        assert!(file.contains(&format!("# public key: {}\n", ours.recipient)) && file.contains("AGE-SECRET-KEY-1"));
        assert!(Keys::parse(&file).is_some() && recipient_valid(&ours.recipient) && !recipient_valid("age1bad"));
    }

    /// Interoperability with the reference `age` CLI, only where it is
    /// installed (it is not a build dependency); otherwise the C2SP vectors
    /// above are the format check.
    #[test]
    fn age_cli_interoperates_when_installed() {
        let available = std::process::Command::new("age").arg("--version").output().is_ok_and(|o| o.status.success());
        if !available {
            eprintln!("age CLI not on PATH: interoperability covered by the C2SP vectors only");
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let keys = Keys::generate();
        let identity = dir.path().join("identity.txt");
        fs::write(&identity, keys.identity_file().as_bytes()).unwrap();
        fs::write(dir.path().join("ours.age"), encrypt_to(&keys.recipient, b"from rust").unwrap()).unwrap();
        let decrypted = std::process::Command::new("age").arg("-d").arg("-i").arg(&identity).arg(dir.path().join("ours.age")).output().unwrap();
        assert_eq!(decrypted.stdout, b"from rust", "{}", String::from_utf8_lossy(&decrypted.stderr));
        fs::write(dir.path().join("plain.txt"), b"from age").unwrap();
        let encrypted = std::process::Command::new("age").args(["-r", &keys.recipient, "-o"]).arg(dir.path().join("theirs.age"))
            .arg(dir.path().join("plain.txt")).output().unwrap();
        assert!(encrypted.status.success());
        assert_eq!(&decrypt_with(&keys.identity, &fs::read(dir.path().join("theirs.age")).unwrap()).unwrap()[..], b"from age");
    }

    #[test]
    fn format_versions_are_classified() {
        let current = serde_json::to_value(empty_snapshot()).unwrap();
        assert!(upgrade(current.clone(), false).is_ok());
        let mut newer = current.clone();
        newer["vault_version"] = json!(2);
        let error = upgrade(newer, false).err().unwrap();
        assert_eq!((error.code, error.extra["version"].clone()), ("github_format_newer", json!("2")));
        let mut required = current.clone();
        required["minimum_remote_control_version"] = json!("99.0.0");
        let error = upgrade(required, false).err().unwrap();
        assert_eq!((error.code, error.extra["required"].clone()), ("github_format_newer", json!("99.0.0")));
        // The Bash 1.x snapshot (format 2, minimum 1.1.0) is foreign, not newer.
        let mut legacy = current.clone();
        legacy["vault_version"] = json!(2);
        legacy["minimum_remote_control_version"] = json!("1.1.0");
        let error = upgrade(legacy, false).err().unwrap();
        assert_eq!((error.code, error.extra["version"].clone()), ("github_format_invalid", json!("2")));
        assert!(error.message.contains("Bash-версия"), "{}", error.message);
        let mut outdated = current.clone();
        outdated["vault_version"] = json!(0);
        assert_eq!(upgrade(outdated.clone(), false).err().unwrap().code, "github_format_outdated");
        // No registered migration path from v0: migrate reports invalid.
        assert_eq!(upgrade(outdated, true).err().unwrap().code, "github_format_invalid");
        for bad in [json!([]), json!({"vault_version": "1"}), json!({"vault_version": 1})] {
            assert_eq!(upgrade(bad, false).err().unwrap().code, "github_format_invalid");
        }
    }

    #[test]
    fn snapshot_validation_rejects_inconsistent_portability() {
        let id = "a".repeat(32);
        let mut snapshot = empty_snapshot();
        snapshot.config.nodes.push(serde_json::from_value(json!({
            "id": id, "name": "n1", "ip": "10.0.0.1", "port": 22, "user": "root", "auth": "password",
            "identity": null, "secret_id": format!("node:{id}:ssh-password"), "aliases": {}
        })).unwrap());
        assert!(snapshot.validate().is_err(), "password node without secret or issue");
        snapshot.portability = Portability::from_issues(vec![PortabilityIssue { node_id: id.clone(), reason: PortabilityReason::MissingSecret }]);
        snapshot.validate().unwrap();
        snapshot.secrets.node_passwords.insert(format!("node:{id}:ssh-password"), Zeroizing::new("pw".into()));
        assert!(snapshot.validate().is_err(), "secret present and missing at once");
        snapshot.portability = Portability::default();
        snapshot.validate().unwrap();
        snapshot.secrets.node_passwords.insert(format!("node:{id}:ssh-password"), Zeroizing::new(String::new()));
        assert!(snapshot.validate().is_err(), "empty password");
        snapshot.portability.status = PortabilityStatus::NeedsSetup;
        assert!(snapshot.validate().is_err());
    }

    #[test]
    fn tree_allowlist_rejects_unknown_paths_and_links() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        fs::write(root.join("storage.json"), "{}").unwrap();
        fs::create_dir_all(root.join("templates")).unwrap();
        fs::write(root.join("templates/default.yaml"), "x").unwrap();
        validate_tree(root, TreeMode::Plain).unwrap();
        assert!(validate_tree(root, TreeMode::Age).is_err(), "plain dirs are not part of the age set");
        fs::write(root.join("templates/nested.txt"), "x").unwrap();
        assert!(validate_tree(root, TreeMode::Auto).is_err());
        fs::remove_file(root.join("templates/nested.txt")).unwrap();
        fs::write(root.join("runtime-vault.json"), "{}").unwrap();
        assert!(validate_tree(root, TreeMode::Auto).is_err());
        fs::remove_file(root.join("runtime-vault.json")).unwrap();
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink("/etc/passwd", root.join("config.json")).unwrap();
            assert!(validate_tree(root, TreeMode::Plain).is_err());
        }
    }

    #[test]
    fn plain_tree_round_trips_and_materializes_with_machine_secrets() {
        let dir = tempfile::tempdir().unwrap();
        let local = State::new(StatePaths::new(dir.path().join("data")));
        let id = "b".repeat(32);
        let mut config = Config::default();
        config.nodes.push(serde_json::from_value(json!({
            "id": id, "name": "n1", "ip": "10.0.0.1", "port": 22, "user": "root", "auth": "password",
            "identity": null, "secret_id": format!("node:{id}:ssh-password"), "aliases": {}
        })).unwrap());
        local.save_config(&config).unwrap();
        local.secret_store().set(&format!("node:{id}:ssh-password"), Zeroizing::new("fixture-secret-xyz".into())).unwrap();
        secure_fs::create_dir_all(local.paths().templates()).unwrap();
        fs::write(local.paths().templates().join("default.yaml"), "proxies: []\n").unwrap();
        let snapshot = serialize(&local).unwrap();
        assert_eq!(snapshot.portability.issues, vec![PortabilityIssue { node_id: id.clone(), reason: PortabilityReason::MissingHostKey }]);
        assert_eq!(&*snapshot.secrets.node_passwords[&format!("node:{id}:ssh-password")], "fixture-secret-xyz");

        let worktree = dir.path().join("worktree");
        fs::create_dir(&worktree).unwrap();
        checkpoint(&worktree, Storage::Plain, None, &snapshot).unwrap();
        validate_tree(&worktree, TreeMode::Plain).unwrap();
        let init = exec::tree_git(&worktree, &["init".as_ref(), "-q".as_ref()]).unwrap();
        assert!(init.success);
        let raw = read_plain(&worktree).unwrap();
        let reread = upgrade(raw, false).unwrap();
        assert_eq!(serde_json::to_value(&reread).unwrap(), serde_json::to_value(&snapshot).unwrap());

        materialize(local.paths(), local.locks(), &reread).unwrap();
        let runtime = State::with_locks(local.paths().runtime(), local.locks().clone());
        assert_eq!(runtime.load_config().unwrap(), config);
        assert_eq!(&*runtime.secret_store().get(&format!("node:{id}:ssh-password")).unwrap().unwrap(), "fixture-secret-xyz");
        let on_disk = fs::read_to_string(runtime.paths().secrets()).unwrap();
        assert!(!on_disk.contains("fixture-secret-xyz"), "runtime passwords stay machine-encrypted");
        assert_eq!(fs::read_to_string(runtime.paths().templates().join("default.yaml")).unwrap(), "proxies: []\n");
    }

    #[test]
    fn every_node_and_profile_secret_travels_and_orphans_stay_behind() {
        let dir = tempfile::tempdir().unwrap();
        let local = State::new(StatePaths::new(dir.path().join("data")));
        let id = "c".repeat(32);
        let mut config = Config::default();
        config.profiles.push(crate::model::test_profile("main"));
        config.nodes.push(serde_json::from_value(json!({
            "id": id, "name": "n1", "ip": "10.0.0.1", "port": 22, "user": "root", "auth": "key",
            "identity": null, "secret_id": null, "profile": "main"
        })).unwrap());
        local.save_config(&config).unwrap();
        let carried = ["reality-key", "awg-key", "warp-key", "telegram-secret", "telegram-tag"]
            .map(|suffix| format!("node:{id}:{suffix}")).into_iter()
            .chain(["profile:main:warp-license".to_owned()]).collect::<Vec<_>>();
        let store = local.secret_store();
        let value = |secret: &str| match secret.rsplit_once(':').map(|(_, suffix)| suffix) {
            Some("reality-key") => "R".repeat(43),
            Some("awg-key" | "warp-key") => format!("{}=", "W".repeat(43)),
            _ => format!("value of {secret}"),
        };
        for secret in &carried {
            store.set(secret, Zeroizing::new(value(secret))).unwrap();
        }
        store.set(&format!("node:{}:reality-key", "d".repeat(32)), Zeroizing::new("orphan".into())).unwrap();
        store.set("profile:gone:warp-license", Zeroizing::new("orphan".into())).unwrap();
        let snapshot = serialize(&local).unwrap();
        assert_eq!(snapshot.secrets.node_passwords.keys().cloned().collect::<std::collections::BTreeSet<_>>(),
            carried.iter().cloned().collect());

        let worktree = dir.path().join("worktree");
        fs::create_dir(&worktree).unwrap();
        checkpoint(&worktree, Storage::Plain, None, &snapshot).unwrap();
        assert!(exec::tree_git(&worktree, &["init".as_ref(), "-q".as_ref()]).unwrap().success);
        let reread = upgrade(read_plain(&worktree).unwrap(), false).unwrap();
        materialize(local.paths(), local.locks(), &reread).unwrap();
        let runtime = State::with_locks(local.paths().runtime(), local.locks().clone());
        for secret in &carried {
            assert_eq!(runtime.secret_store().get(secret).unwrap().unwrap().as_str(), value(secret));
        }

        let mut orphaned = serialize(&local).unwrap();
        orphaned.secrets.node_passwords.insert(format!("node:{}:awg-key", "e".repeat(32)), Zeroizing::new("x".into()));
        assert!(orphaned.validate().is_err(), "a secret of an unknown node");
        let mut orphaned = serialize(&local).unwrap();
        orphaned.secrets.node_passwords.insert("profile:gone:warp-license".into(), Zeroizing::new("x".into()));
        assert!(orphaned.validate().is_err(), "a license of an unknown profile");
        for (suffix, bad) in [("reality-key", "x\"\n  - name: open".to_owned()), ("reality-key", "R".repeat(44)),
            ("awg-key", "W".repeat(44)), ("warp-key", format!("{}\n=", "W".repeat(42)))] {
            let mut forged = serialize(&local).unwrap();
            forged.secrets.node_passwords.insert(format!("node:{id}:{suffix}"), Zeroizing::new(bad.clone()));
            assert!(forged.validate().is_err(), "{suffix} {bad:?}");
        }
    }

    #[test]
    fn a_lost_machine_key_keeps_the_vault_copy_of_node_keys() {
        let dir = tempfile::tempdir().unwrap();
        let local = State::new(StatePaths::new(dir.path().join("data")));
        let id = "c".repeat(32);
        let mut config = Config::default();
        config.profiles.push(crate::model::test_profile("main"));
        config.nodes.push(serde_json::from_value(json!({
            "id": id, "name": "n1", "ip": "10.0.0.1", "port": 22, "user": "root", "auth": "key",
            "identity": null, "secret_id": null, "profile": "main"
        })).unwrap());
        local.save_config(&config).unwrap();
        let (reality, tag) = (format!("node:{id}:reality-key"), format!("node:{id}:telegram-tag"));
        let store = local.secret_store();
        store.set(&reality, Zeroizing::new("R".repeat(43))).unwrap();
        store.set(&tag, Zeroizing::new("tag".into())).unwrap();
        let worktree = dir.path().join("worktree");
        fs::create_dir(&worktree).unwrap();
        checkpoint(&worktree, Storage::Plain, None, &serialize(&local).unwrap()).unwrap();
        assert!(exec::tree_git(&worktree, &["init".as_ref(), "-q".as_ref()]).unwrap().success);

        // A deliberately removed secret goes; one this machine can no longer
        // decrypt (another machine key) keeps its vault value.
        store.remove(&tag).unwrap();
        secure_fs::atomic_write(local.paths().secret_key(), &[7u8; 32]).unwrap();
        let snapshot = serialize(&local).unwrap();
        assert_eq!(snapshot.unreadable, std::slice::from_ref(&reality));
        assert!(snapshot.secrets.node_passwords.is_empty());
        checkpoint(&worktree, Storage::Plain, None, &snapshot).unwrap();
        let reread = upgrade(read_plain(&worktree).unwrap(), false).unwrap();
        assert_eq!(reread.secrets.node_passwords.keys().collect::<Vec<_>>(), [&reality]);
        assert_eq!(reread.secrets.node_passwords[&reality].as_str(), "R".repeat(43));

        // Without a readable previous snapshot nothing is written at all.
        fs::write(worktree.join("secrets.json"), b"not json").unwrap();
        assert!(checkpoint(&worktree, Storage::Plain, None, &snapshot).is_err());
        assert_eq!(fs::read(worktree.join("secrets.json")).unwrap(), b"not json");
    }

    #[test]
    fn a_deleted_template_leaves_the_plain_tree_and_its_manifest() {
        let dir = tempfile::tempdir().unwrap();
        let local = State::new(StatePaths::new(dir.path().join("data")));
        local.save_config(&Config::default()).unwrap();
        secure_fs::create_dir_all(local.paths().templates()).unwrap();
        fs::write(local.paths().templates().join("keep.yaml"), "proxies:\n").unwrap();
        fs::write(local.paths().templates().join("gone.yaml"), "proxies:\n").unwrap();
        let worktree = dir.path().join("worktree");
        fs::create_dir(&worktree).unwrap();
        checkpoint(&worktree, Storage::Plain, None, &serialize(&local).unwrap()).unwrap();
        assert!(worktree.join("templates/gone.yaml").exists());
        fs::remove_file(local.paths().templates().join("gone.yaml")).unwrap();
        checkpoint(&worktree, Storage::Plain, None, &serialize(&local).unwrap()).unwrap();
        assert!(!worktree.join("templates/gone.yaml").exists());
        assert!(worktree.join("templates/keep.yaml").exists());
        let manifest: Value = serde_json::from_slice(&fs::read(worktree.join("manifest.json")).unwrap()).unwrap();
        assert_eq!(manifest["templates"].as_object().unwrap().keys().collect::<Vec<_>>(), ["keep.yaml"]);
    }
}
