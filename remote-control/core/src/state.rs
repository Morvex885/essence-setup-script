//! Read-only discovery and schema-v2 local storage. Constructors and all loaders
//! leave an absent data directory absent; only successful mutations create it.

use std::fs::File;
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};

use zeroize::Zeroizing;

use crate::auth::AuthStore;
use crate::error::{RcError, Result};
use crate::locking::{LockKind, LockManager};
use crate::model::{Auth, Config, KnownHosts, Manifest, Portability, PortabilityIssue, PortabilityReason, Source};
use crate::secrets::SecretStore;
use crate::secure_fs;

/// Native schema-v2 layout. Every accessor borrows a cached path; none performs IO.
/// The logical state files live in the state directory: the data root for the
/// local source, `github-runtime/` for an open GitHub source. `auth.txt`,
/// `secret.key`, `source.json` and the lock always stay in the root.
#[derive(Clone, Debug)]
pub struct StatePaths {
    root: PathBuf,
    state_dir: PathBuf,
    config: PathBuf,
    secrets: PathBuf,
    manifest: PathBuf,
    known_hosts: PathBuf,
    auth: PathBuf,
    secret_key: PathBuf,
    source: PathBuf,
    templates: PathBuf,
    identities: PathBuf,
}

impl StatePaths {
    pub fn new(root: impl AsRef<Path>) -> Self {
        let root = root.as_ref().to_path_buf();
        Self::layout(root.clone(), root)
    }

    fn layout(root: PathBuf, state_dir: PathBuf) -> Self {
        Self {
            config: state_dir.join("config.json"),
            secrets: state_dir.join("secrets.json"),
            manifest: state_dir.join("manifest.json"),
            known_hosts: state_dir.join("ssh/known-hosts.json"),
            templates: state_dir.join("templates"),
            identities: state_dir.join("ssh/identities"),
            auth: root.join("auth.txt"),
            secret_key: root.join("secret.key"),
            source: root.join("source.json"),
            state_dir,
            root,
        }
    }

    /// The same root with the logical state files in `dir` (staging, runtime).
    pub fn with_state_dir(&self, dir: impl AsRef<Path>) -> Self {
        Self::layout(self.root.clone(), dir.as_ref().to_path_buf())
    }

    /// The device-local layout of this root.
    pub fn local(&self) -> Self {
        Self::new(&self.root)
    }

    /// The materialized GitHub working state.
    pub fn runtime(&self) -> Self {
        self.with_state_dir(self.github_runtime())
    }

    pub fn discover() -> Result<Self> {
        if let Some(root) = std::env::var_os("ESSENCE_RC_DATA_DIR") {
            if root.is_empty() {
                return Err(RcError::new("invalid", "ESSENCE_RC_DATA_DIR не должен быть пустым."));
            }
            return Ok(Self::new(PathBuf::from(root)));
        }
        let root = dirs::data_dir().ok_or_else(|| {
            RcError::new("failed", "Не удалось определить каталог данных пользователя.")
        })?;
        Ok(Self::new(root.join("essence-remote-control")))
    }

    pub fn root(&self) -> &Path { &self.root }
    pub fn state_dir(&self) -> &Path { &self.state_dir }
    pub fn config(&self) -> &Path { &self.config }
    pub fn secrets(&self) -> &Path { &self.secrets }
    pub fn manifest(&self) -> &Path { &self.manifest }
    pub fn known_hosts(&self) -> &Path { &self.known_hosts }
    pub fn auth(&self) -> &Path { &self.auth }
    pub fn secret_key(&self) -> &Path { &self.secret_key }
    pub fn source(&self) -> &Path { &self.source }
    pub fn templates(&self) -> &Path { &self.templates }
    pub fn identities(&self) -> &Path { &self.identities }
    pub fn github_store(&self) -> PathBuf { self.root.join("github-store") }
    pub fn github_sessions(&self) -> PathBuf { self.root.join("github-sessions") }
    pub fn github_runtime(&self) -> PathBuf { self.root.join("github-runtime") }
    pub fn credentials(&self) -> PathBuf { self.root.join("credentials") }
    pub fn gh_profile(&self, login: &str) -> PathBuf { self.credentials().join("gh").join(login) }
    pub fn remembered_key(&self) -> PathBuf { self.credentials().join("github-config.agekey") }
    pub fn account_switch(&self) -> PathBuf { self.root.join("account-switch") }
    pub fn import_backups(&self) -> PathBuf { self.root.join("import-backups") }
}

pub struct State {
    paths: StatePaths,
    locks: LockManager,
}

impl State {
    pub fn new(paths: StatePaths) -> Self {
        let locks = LockManager::new(paths.root());
        Self::with_locks(paths, locks)
    }

    /// Inject the transaction/session lock manager for this same data directory.
    pub fn with_locks(paths: StatePaths, locks: LockManager) -> Self {
        Self { paths, locks }
    }

    pub fn paths(&self) -> &StatePaths { &self.paths }
    pub fn locks(&self) -> &LockManager { &self.locks }

    /// Stores share this State's reentrant transaction/session ownership.
    pub fn secret_store(&self) -> SecretStore {
        SecretStore::new(self.paths.clone(), self.locks.clone())
    }

    pub fn auth_store(&self) -> AuthStore {
        AuthStore::new(self.paths.clone(), self.locks.clone())
    }

    pub fn load_config(&self) -> Result<Config> {
        match read_optional(self.paths.config())? {
            Some(bytes) => Config::parse(&bytes),
            None => Ok(Config::default()),
        }
    }

    /// Validate and serialize before acquiring the mutation lock or creating files.
    /// Publication uses a private same-directory staging file and an atomic rename.
    pub fn save_config(&self, config: &Config) -> Result<()> {
        config.validate()?;
        let mut bytes = Zeroizing::new(serde_json::to_vec_pretty(config)?);
        bytes.push(b'\n');
        let _guard = self.locks.acquire(LockKind::Mutation, "config save")?;
        secure_fs::atomic_write(self.paths.config(), &bytes)?;
        Ok(())
    }

    pub fn load_manifest(&self) -> Result<Manifest> {
        let manifest = match read_optional(self.paths.manifest())? {
            Some(bytes) => serde_json::from_slice(&bytes)?,
            None => Manifest::default(),
        };
        manifest.validate()?;
        Ok(manifest)
    }

    pub fn save_manifest(&self, manifest: &Manifest) -> Result<()> {
        manifest.validate()?;
        let mut bytes = serde_json::to_vec_pretty(manifest)?;
        bytes.push(b'\n');
        let _guard = self.locks.acquire(LockKind::Mutation, "manifest save")?;
        secure_fs::atomic_write(self.paths.manifest(), &bytes)?;
        Ok(())
    }

    /// v1 `state_checkpoint`: after a persisted mutation the manifest records
    /// which password nodes lack a readable secret and mirrors the script
    /// password hash. Unconfigured state (no config.json) has no checkpoint.
    pub fn checkpoint(&self) -> Result<()> {
        if !self.paths.config().try_exists()? {
            return Ok(());
        }
        let config = self.load_config()?;
        let mut manifest = self.load_manifest()?;
        let store = self.secret_store();
        let mut issues: Vec<PortabilityIssue> = manifest.portability.issues.drain(..)
            .filter(|issue| issue.reason != PortabilityReason::MissingSecret
                && config.nodes.iter().any(|node| node.id == issue.node_id))
            .collect();
        for node in config.nodes.iter().filter(|node| node.auth == Auth::Password) {
            let readable = match node.secret_id.as_deref().map(|id| store.get(id)) {
                Some(Ok(value)) => value.is_some(),
                Some(Err(error)) if error.code == "missing_secret" => false,
                Some(Err(error)) => return Err(error),
                None => false,
            };
            if !readable {
                issues.push(PortabilityIssue { node_id: node.id.clone(), reason: PortabilityReason::MissingSecret });
            }
        }
        manifest.portability = Portability::from_issues(issues);
        manifest.access.script_password_hash = self.auth_store().hash()?;
        self.save_manifest(&manifest)
    }

    /// Host pins are keyed by validated host-plus-port endpoints, including 22.
    /// EndpointKey and Fingerprint reject malformed values during deserialization.
    pub fn load_known_hosts(&self) -> Result<KnownHosts> {
        match read_optional(self.paths.known_hosts())? {
            Some(bytes) => Ok(serde_json::from_slice(&bytes)?),
            None => Ok(KnownHosts::default()),
        }
    }

    pub fn save_known_hosts(&self, known_hosts: &KnownHosts) -> Result<()> {
        let mut bytes = Zeroizing::new(serde_json::to_vec_pretty(known_hosts)?);
        bytes.push(b'\n');
        let _guard = self.locks.acquire(LockKind::Mutation, "host pins save")?;
        secure_fs::create_dir_all(
            self.paths.known_hosts().parent().expect("known hosts have a parent"),
        )?;
        secure_fs::atomic_write(self.paths.known_hosts(), &bytes)?;
        Ok(())
    }

    pub fn load_source(&self) -> Result<Option<Source>> {
        let Some(bytes) = read_optional(self.paths.source())? else {
            return Ok(None);
        };
        let source: Source = serde_json::from_slice(&bytes)?;
        source.validate()?;
        Ok(Some(source))
    }
}

/// Read directly into a wiping buffer, including on a partial IO failure.
pub(crate) fn read_optional(path: &Path) -> Result<Option<Zeroizing<Vec<u8>>>> {
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let mut bytes = Zeroizing::new(Vec::new());
    file.read_to_end(&mut bytes)?;
    Ok(Some(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_state_reads_do_not_create_anything() {
        let parent = tempfile::tempdir().unwrap();
        let paths = StatePaths::new(parent.path().join("absent"));
        let state = State::new(paths.clone());
        assert_eq!(state.load_config().unwrap().groups.len(), 3);
        state.load_manifest().unwrap();
        assert!(state.load_source().unwrap().is_none());
        assert!(state.load_known_hosts().unwrap().0.is_empty());
        assert!(!paths.root().exists());
    }

    #[test]
    fn invalid_config_does_not_replace_published_bytes() {
        let parent = tempfile::tempdir().unwrap();
        let state = State::new(StatePaths::new(parent.path()));
        let mut config = Config::default();
        state.save_config(&config).unwrap();
        let before = std::fs::read(state.paths().config()).unwrap();
        config.schema_version = 1;
        assert!(state.save_config(&config).is_err());
        assert_eq!(std::fs::read(state.paths().config()).unwrap(), before);
    }

    #[test]
    fn host_pins_round_trip_without_legacy_host_only_keys() {
        let parent = tempfile::tempdir().unwrap();
        let state = State::new(StatePaths::new(parent.path()));
        let pins: KnownHosts = serde_json::from_str(
            r#"{"[example.com]:22":["SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]}"#,
        ).unwrap();
        state.save_known_hosts(&pins).unwrap();
        assert_eq!(state.load_known_hosts().unwrap(), pins);
        secure_fs::atomic_write(
            state.paths().known_hosts(),
            br#"{"example.com":["SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]}"#,
        ).unwrap();
        assert_eq!(state.load_known_hosts().err().unwrap().code, "invalid");
    }

    #[test]
    fn layout_uses_native_schema_two_names() {
        let paths = StatePaths::new("data");
        assert_eq!(paths.config(), Path::new("data/config.json"));
        assert_eq!(paths.auth(), Path::new("data/auth.txt"));
        assert_eq!(paths.secret_key(), Path::new("data/secret.key"));
        assert_eq!(paths.known_hosts(), Path::new("data/ssh/known-hosts.json"));
    }

    #[test]
    fn stores_share_outer_mutation_and_session_locks() {
        for kind in [LockKind::Mutation, LockKind::Session] {
            let parent = tempfile::tempdir().unwrap();
            let state = State::new(StatePaths::new(parent.path()));
            let guard = state.locks().acquire(kind, "outer transaction").unwrap();
            let secrets = state.secret_store();
            let auth = state.auth_store();
            let id = "node:0123456789abcdef0123456789abcdef:ssh-password";
            secrets.set(id, Zeroizing::new("SSH password".into())).unwrap();
            auth.set(Zeroizing::new("session password".into())).unwrap();
            state.save_config(&Config::default()).unwrap();
            assert!(secrets.get(id).unwrap().is_some());
            assert!(auth.verify("session password").unwrap());
            drop(guard);
            state.locks().release_all().unwrap();
        }
    }
}
