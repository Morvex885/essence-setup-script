//! Machine-local SSH passwords. `secret.key` is 32 random bytes, published only
//! on the first password write, never derived from a machine identifier.
//!
//! Schema 1 values are base64(nonce[12] || AES-256-GCM ciphertext || tag[16]).
//! The encryption key is SHA-256(secret.key); the exact UTF-8 secret ID is GCM
//! associated data, so moving a value to another ID fails authentication.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{ErrorKind, Read};

use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce, Tag};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::error::{RcError, Result};
use crate::locking::{LockKind, LockManager};
use crate::secure_fs;
use crate::state::{StatePaths, read_optional};
use crate::validation::secret_id_valid;

const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;

#[derive(Deserialize, Serialize)]
struct SecretsFile {
    schema_version: u32,
    node_passwords: BTreeMap<String, String>,
}

impl Default for SecretsFile {
    fn default() -> Self {
        Self {
            schema_version: 1,
            node_passwords: BTreeMap::new(),
        }
    }
}

pub struct SecretStore {
    paths: StatePaths,
    locks: LockManager,
}

impl SecretStore {
    /// Inject the owning State's manager; do not create an independent manager
    /// inside an already locked transaction. Prefer State::secret_store().
    pub fn new(paths: StatePaths, locks: LockManager) -> Self {
        Self { paths, locks }
    }

    /// Validate the global encrypted container without requiring a machine key
    /// or decrypting individual entries. An absent container is valid empty state.
    pub fn validate(&self) -> Result<()> {
        self.load_container()?;
        Ok(())
    }

    /// IDs of every stored secret (sorted), without decrypting any.
    pub fn ids(&self) -> Result<Vec<String>> {
        Ok(self.load_container()?.map(|container| container.node_passwords.into_keys().collect()).unwrap_or_default())
    }

    /// An absent entry is None; an existing but unusable entry is missing_secret.
    /// Neither case creates a directory, key, or container.
    pub fn get(&self, secret_id: &str) -> Result<Option<Zeroizing<String>>> {
        validate_id(secret_id)?;
        let Some(container) = self.load_container()? else {
            return Ok(None);
        };
        let Some(encoded) = container.node_passwords.get(secret_id) else {
            return Ok(None);
        };
        let key = self.load_key()?.ok_or_else(missing_secret)?;
        let sealed = Zeroizing::new(STANDARD.decode(encoded).map_err(|_| missing_secret())?);
        let mut body = open_with(&key[..], secret_id.as_bytes(), &sealed)?;
        if body.is_empty() || body.contains(&0) {
            return Err(missing_secret());
        }
        // All plaintext, including a UTF-8 error's owned bytes, remains in wiping buffers.
        let password = Zeroizing::new(
            String::from_utf8(std::mem::take(&mut *body)).map_err(|error| {
                let _bytes = Zeroizing::new(error.into_bytes());
                missing_secret()
            })?,
        );
        Ok(Some(password))
    }

    /// The lock covers the entire read-modify-write and key initialization, not
    /// just publication, preserving independent concurrent password updates.
    pub fn set(&self, secret_id: &str, password: Zeroizing<String>) -> Result<()> {
        validate_id(secret_id)?;
        validate_password(&password)?;
        let _guard = self.locks.acquire(LockKind::Mutation, "secret set")?;
        let existing = self.load_container()?;
        let key = self.key_or_create(existing.as_ref())?;
        let sealed = seal_with(&key[..], secret_id.as_bytes(), password.as_bytes())?;
        let mut container = existing.unwrap_or_default();
        container.node_passwords.insert(secret_id.to_owned(), STANDARD.encode(&*sealed));
        self.save_container(&container)
    }

    /// The machine key, created on first use. A non-empty password container
    /// without its key is never given a new one (its values would be lost).
    /// Callers hold the mutation lock.
    fn key_or_create(&self, existing: Option<&SecretsFile>) -> Result<Zeroizing<[u8; 32]>> {
        match self.load_key()? {
            Some(key) => Ok(key),
            None if existing.is_some_and(|container| !container.node_passwords.is_empty()) => Err(missing_secret()),
            None => {
                let mut key = Zeroizing::new([0u8; 32]);
                random_bytes(&mut *key)?;
                // Only lock holders create keys, and atomic_write publishes a
                // complete 32-byte file. Unlocked readers cannot see a prefix.
                secure_fs::atomic_write(self.paths.secret_key(), &*key)?;
                Ok(key)
            }
        }
    }

    /// Encrypt another private payload with the machine key (same AES-256-GCM
    /// scheme as the passwords); `aad` binds the payload to its role.
    pub fn seal(&self, aad: &str, plaintext: &[u8]) -> Result<Vec<u8>> {
        let _guard = self.locks.acquire(LockKind::Mutation, "machine key")?;
        let existing = self.load_container()?;
        let key = self.key_or_create(existing.as_ref())?;
        Ok(seal_with(&key[..], aad.as_bytes(), plaintext)?.to_vec())
    }

    /// Decrypt a `seal` payload. A missing or wrong key, a different `aad` or
    /// tampering is `missing_secret`; nothing is created.
    pub fn open(&self, aad: &str, sealed: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
        let key = self.load_key()?.ok_or_else(missing_secret)?;
        open_with(&key[..], aad.as_bytes(), sealed)
    }

    pub fn remove(&self, secret_id: &str) -> Result<()> {
        validate_id(secret_id)?;
        if !self.paths.root().try_exists()? {
            return Ok(());
        }
        let _guard = self.locks.acquire(LockKind::Mutation, "secret remove")?;
        let Some(mut container) = self.load_container()? else {
            return Ok(());
        };
        if container.node_passwords.remove(secret_id).is_some() {
            self.save_container(&container)?;
        }
        Ok(())
    }

    fn load_container(&self) -> Result<Option<SecretsFile>> {
        let Some(bytes) = read_optional(self.paths.secrets())? else {
            return Ok(None);
        };
        let container: SecretsFile = serde_json::from_slice(&bytes)?;
        if container.schema_version != 1
            || container.node_passwords.keys().any(|id| !secret_id_valid(id))
        {
            return Err(RcError::new("invalid", "Некорректный контейнер паролей SSH."));
        }
        Ok(Some(container))
    }

    fn load_key(&self) -> Result<Option<Zeroizing<[u8; 32]>>> {
        let mut file = match File::open(self.paths.secret_key()) {
            Ok(file) => file,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(missing_secret()),
        };
        let mut key = Zeroizing::new([0u8; 32]);
        file.read_exact(&mut *key).map_err(|_| missing_secret())?;
        let mut trailing = Zeroizing::new([0u8; 1]);
        if file.read(&mut *trailing).map_err(|_| missing_secret())? != 0 {
            return Err(missing_secret());
        }
        Ok(Some(key))
    }

    fn save_container(&self, container: &SecretsFile) -> Result<()> {
        let mut bytes = Zeroizing::new(serde_json::to_vec_pretty(container)?);
        bytes.push(b'\n');
        secure_fs::atomic_write(self.paths.secrets(), &bytes)?;
        Ok(())
    }
}

fn validate_id(secret_id: &str) -> Result<()> {
    if !secret_id_valid(secret_id) {
        return Err(RcError::new("invalid", "Некорректный идентификатор пароля SSH."));
    }
    Ok(())
}

pub(crate) fn validate_password(password: &str) -> Result<()> {
    if password.is_empty() || password.contains('\0') {
        return Err(RcError::new("invalid", "Пароль не должен быть пустым или содержать NUL."));
    }
    Ok(())
}

/// nonce[12] ‖ AES-256-GCM(SHA-256(key)) ciphertext ‖ tag[16], fresh nonce.
fn seal_with(raw_key: &[u8], aad: &[u8], plaintext: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    let cipher = make_cipher(raw_key)?;
    let mut buffer = Zeroizing::new(Vec::with_capacity(NONCE_LEN + plaintext.len() + TAG_LEN));
    buffer.resize(NONCE_LEN, 0);
    random_bytes(&mut buffer)?;
    buffer.extend_from_slice(plaintext);
    let (nonce, body) = buffer.split_at_mut(NONCE_LEN);
    let tag = cipher.encrypt_in_place_detached(Nonce::from_slice(nonce), aad, body)
        .map_err(|_| RcError::new("failed", "Не удалось зашифровать данные машинным ключом."))?;
    buffer.extend_from_slice(&tag);
    Ok(buffer)
}

fn open_with(raw_key: &[u8], aad: &[u8], sealed: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    if sealed.len() < NONCE_LEN + TAG_LEN {
        return Err(missing_secret());
    }
    let cipher = make_cipher(raw_key)?;
    let mut buffer = Zeroizing::new(sealed.to_vec());
    let plaintext_len = buffer.len() - NONCE_LEN - TAG_LEN;
    let (nonce, encrypted) = buffer.split_at_mut(NONCE_LEN);
    let (body, tag) = encrypted.split_at_mut(plaintext_len);
    cipher.decrypt_in_place_detached(Nonce::from_slice(nonce), aad, body, Tag::from_slice(tag))
        .map_err(|_| missing_secret())?;
    buffer.copy_within(NONCE_LEN..NONCE_LEN + plaintext_len, 0);
    buffer.truncate(plaintext_len);
    Ok(buffer)
}

fn make_cipher(raw_key: &[u8]) -> Result<Aes256Gcm> {
    let mut key = Zeroizing::new([0u8; 32]);
    let mut hash = Sha256::new();
    hash.update(raw_key);
    hash.finalize_into(sha2::digest::Output::<Sha256>::from_mut_slice(&mut *key));
    Aes256Gcm::new_from_slice(&*key)
        .map_err(|_| RcError::new("failed", "Не удалось инициализировать шифрование."))
}

pub(crate) fn random_bytes(bytes: &mut [u8]) -> Result<()> {
    OsRng.try_fill_bytes(bytes)
        .map_err(|_| RcError::new("failed", "Системный генератор случайных чисел недоступен."))
}

fn missing_secret() -> RcError {
    RcError::new("missing_secret", "Пароль SSH недоступен или повреждён.")
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIRST: &str = "node:0123456789abcdef0123456789abcdef:ssh-password";
    const SECOND: &str = "node:abcdef0123456789abcdef0123456789:ssh-password";

    fn setup() -> (tempfile::TempDir, StatePaths, SecretStore) {
        let parent = tempfile::tempdir().unwrap();
        let paths = StatePaths::new(parent.path().join("state"));
        let locks = LockManager::new(paths.root());
        let store = SecretStore::new(paths.clone(), locks);
        (parent, paths, store)
    }

    #[test]
    fn existing_empty_container_allows_first_key_initialization() {
        let (_parent, paths, store) = setup();
        secure_fs::create_dir_all(paths.root()).unwrap();
        store.save_container(&SecretsFile::default()).unwrap();
        assert!(!paths.secret_key().exists());
        store.set(FIRST, password()).unwrap();
        assert_eq!(std::fs::metadata(paths.secret_key()).unwrap().len(), 32);
        assert!(store.get(FIRST).unwrap().is_some());
    }

    fn password() -> Zeroizing<String> {
        Zeroizing::new("unique SSH password\nwith trailing newline\n".to_owned())
    }

    #[test]
    fn absent_reads_and_invalid_writes_are_side_effect_free() {
        let (_parent, paths, store) = setup();
        store.validate().unwrap();
        assert!(store.get(FIRST).unwrap().is_none());
        store.remove(FIRST).unwrap();
        assert!(store.set("invalid", password()).is_err());
        assert!(store.set(FIRST, Zeroizing::new(String::new())).is_err());
        assert!(store.set(FIRST, Zeroizing::new("a\0b".into())).is_err());
        assert!(!paths.root().exists());
    }

    #[test]
    fn key_persists_and_files_never_contain_passwords() {
        let (_parent, paths, store) = setup();
        store.set(FIRST, password()).unwrap();
        let key = Zeroizing::new(std::fs::read(paths.secret_key()).unwrap());
        assert_eq!(key.len(), 32);
        let reopened = SecretStore::new(paths.clone(), store.locks.clone());
        assert!(reopened.get(FIRST).unwrap().is_some_and(|value| *value == *password()));
        reopened.set(SECOND, Zeroizing::new("another password".into())).unwrap();
        let reopened_key = Zeroizing::new(std::fs::read(paths.secret_key()).unwrap());
        assert!(*reopened_key == *key);
        let serialized = std::fs::read(paths.secrets()).unwrap();
        let expected = password();
        assert!(!serialized.windows(expected.len()).any(|bytes| bytes == expected.as_bytes()));
        reopened.remove(FIRST).unwrap();
        assert!(reopened.get(FIRST).unwrap().is_none());
        assert!(reopened.get(SECOND).unwrap().is_some());
    }

    #[test]
    fn tampered_and_swapped_ciphertexts_fail_authentication() {
        let (_parent, _paths, store) = setup();
        store.set(FIRST, password()).unwrap();
        let mut container = store.load_container().unwrap().unwrap();
        let encoded = container.node_passwords.get(FIRST).unwrap().clone();
        container.node_passwords.insert(SECOND.into(), encoded.clone());
        let mut bytes = STANDARD.decode(encoded).unwrap();
        bytes[NONCE_LEN] ^= 1;
        container.node_passwords.insert(FIRST.into(), STANDARD.encode(bytes));
        store.save_container(&container).unwrap();
        assert_eq!(store.get(FIRST).err().unwrap().code, "missing_secret");
        assert_eq!(store.get(SECOND).err().unwrap().code, "missing_secret");
    }

    #[test]
    fn wrong_missing_and_truncated_keys_are_never_replaced() {
        let (_parent, paths, store) = setup();
        store.set(FIRST, password()).unwrap();
        let original = Zeroizing::new(std::fs::read(paths.secret_key()).unwrap());
        let mut wrong = Zeroizing::new(original.to_vec());
        wrong[0] ^= 1;
        secure_fs::atomic_write(paths.secret_key(), &wrong).unwrap();
        assert_eq!(store.get(FIRST).err().unwrap().code, "missing_secret");
        secure_fs::atomic_write(paths.secret_key(), &[0u8; 31]).unwrap();
        assert_eq!(store.get(FIRST).err().unwrap().code, "missing_secret");
        assert_eq!(store.set(SECOND, password()).err().unwrap().code, "missing_secret");
        assert_eq!(std::fs::metadata(paths.secret_key()).unwrap().len(), 31);
        std::fs::remove_file(paths.secret_key()).unwrap();
        assert_eq!(store.get(FIRST).err().unwrap().code, "missing_secret");
        assert_eq!(store.set(SECOND, password()).err().unwrap().code, "missing_secret");
        assert!(!paths.secret_key().exists());
        secure_fs::atomic_write(paths.secret_key(), &original).unwrap();
        assert!(store.get(FIRST).unwrap().is_some());
    }

    #[test]
    fn malformed_containers_are_fatal_even_without_a_key() {
        let (_parent, paths, store) = setup();
        secure_fs::create_dir_all(paths.root()).unwrap();
        for bytes in [
            "not JSON", "{}", "{\"schema_version\":2,\"node_passwords\":{}}",
            "{\"schema_version\":1,\"node_passwords\":[]}",
            "{\"schema_version\":1,\"node_passwords\":{\"bad-id\":\"value\"}}",
        ] {
            secure_fs::atomic_write(paths.secrets(), bytes.as_bytes()).unwrap();
            assert_eq!(store.validate().err().unwrap().code, "invalid");
            assert_eq!(store.get(FIRST).err().unwrap().code, "invalid");
            assert_eq!(store.set(FIRST, password()).err().unwrap().code, "invalid");
            assert!(!paths.secret_key().exists());
        }
    }
}
