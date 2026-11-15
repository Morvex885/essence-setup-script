//! Optional session authentication as an Argon2id PHC string in `auth.txt`.
//! Missing state is read-only and unconfigured. A present malformed hash is an
//! authentication failure, never an invitation to bypass authentication.
//!
//! The only supported PHC profile is the one generated here: Argon2id v19,
//! m=19456 KiB, t=2, p=1, a 16-byte salt and a 32-byte output. Profile checks
//! precede password verification so hostile file contents cannot request
//! unbounded Argon2 memory or CPU. Other profiles are not a compatibility API.

use argon2::password_hash::{Error as PasswordHashError, PasswordHash, SaltString};
use argon2::{Argon2, Params, PasswordHasher, PasswordVerifier};
use zeroize::Zeroizing;

use crate::error::{RcError, Result};
use crate::locking::{LockKind, LockManager};
use crate::secrets::{random_bytes, validate_password};
use crate::secure_fs;
use crate::state::{StatePaths, read_optional};

pub struct AuthStore {
    paths: StatePaths,
    locks: LockManager,
}

impl AuthStore {
    /// Share the transaction/session manager supplied by State::auth_store().
    pub fn new(paths: StatePaths, locks: LockManager) -> Self {
        Self { paths, locks }
    }

    pub fn is_configured(&self) -> Result<bool> {
        let Some(bytes) = read_optional(self.paths.auth())? else {
            return Ok(false);
        };
        parse_hash(&bytes)?;
        Ok(true)
    }

    /// No configured password means there is nothing to verify. A wrong password
    /// returns false; malformed PHC metadata fails closed with auth_failed.
    pub fn verify(&self, password: &str) -> Result<bool> {
        let Some(bytes) = read_optional(self.paths.auth())? else {
            return Ok(false);
        };
        let hash = parse_hash(&bytes)?;
        if password.is_empty() || password.contains('\0') {
            return Ok(false);
        }
        match Argon2::default().verify_password(password.as_bytes(), &hash) {
            Ok(()) => Ok(true),
            Err(PasswordHashError::Password) => Ok(false),
            Err(_) => Err(invalid_hash()),
        }
    }

    pub fn set(&self, password: Zeroizing<String>) -> Result<()> {
        validate_password(&password)?;
        let mut salt = [0u8; 16];
        random_bytes(&mut salt)?;
        let salt = SaltString::encode_b64(&salt)
            .map_err(|_| RcError::new("failed", "Не удалось создать соль пароля."))?;
        let hash = Argon2::default().hash_password(password.as_bytes(), &salt)
            .map_err(|_| RcError::new("failed", "Не удалось вычислить хеш пароля."))?;
        let mut encoded = hash.to_string();
        encoded.push('\n');
        let _guard = self.locks.acquire(LockKind::Mutation, "auth set")?;
        secure_fs::atomic_write(self.paths.auth(), encoded.as_bytes())?;
        Ok(())
    }

    /// The stored PHC string, validated; the GitHub snapshot carries it.
    pub fn hash(&self) -> Result<Option<String>> {
        let Some(bytes) = read_optional(self.paths.auth())? else {
            return Ok(None);
        };
        Ok(Some(parse_hash(&bytes)?.to_string()))
    }

    /// Publish a hash materialized from a GitHub snapshot (same strict profile).
    pub fn set_hash(&self, hash: &str) -> Result<()> {
        parse_hash(hash.as_bytes()).map_err(|_| {
            RcError::new("invalid", "Хеш пароля запуска в конфигурации GitHub имеет некорректный формат.")
        })?;
        let _guard = self.locks.acquire(LockKind::Mutation, "auth set")?;
        secure_fs::atomic_write(self.paths.auth(), format!("{hash}\n").as_bytes())?;
        Ok(())
    }

    pub fn remove(&self) -> Result<()> {
        if !self.paths.root().try_exists()? {
            return Ok(());
        }
        let _guard = self.locks.acquire(LockKind::Mutation, "auth remove")?;
        match std::fs::remove_file(self.paths.auth()) {
            Ok(()) => {
                #[cfg(unix)]
                std::fs::File::open(self.paths.root())?.sync_all()?;
                Ok(())
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        }
    }
}

fn parse_hash(bytes: &[u8]) -> Result<PasswordHash<'_>> {
    let text = std::str::from_utf8(bytes).map_err(|_| invalid_hash())?;
    let text = text.strip_suffix('\n').unwrap_or(text);
    let text = text.strip_suffix('\r').unwrap_or(text);
    let hash = PasswordHash::new(text).map_err(|_| invalid_hash())?;
    if hash.algorithm.as_str() != "argon2id" || hash.version != Some(19)
        || hash.params.iter().count() != 3
        || hash.params.get_decimal("m") != Some(Params::DEFAULT_M_COST)
        || hash.params.get_decimal("t") != Some(Params::DEFAULT_T_COST)
        || hash.params.get_decimal("p") != Some(Params::DEFAULT_P_COST)
        || hash.hash.as_ref().is_none_or(|output| output.len() != Params::DEFAULT_OUTPUT_LEN)
    {
        return Err(invalid_hash());
    }
    let salt = hash.salt.ok_or_else(invalid_hash)?;
    let mut decoded_salt = [0u8; 16];
    let decoded_salt = salt.decode_b64(&mut decoded_salt).map_err(|_| invalid_hash())?;
    if decoded_salt.len() != 16 {
        return Err(invalid_hash());
    }
    Ok(hash)
}

fn invalid_hash() -> RcError {
    RcError::new("auth_failed", "Файл аутентификации повреждён или имеет неподдерживаемый формат.")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> (tempfile::TempDir, StatePaths, AuthStore) {
        let parent = tempfile::tempdir().unwrap();
        let paths = StatePaths::new(parent.path().join("state"));
        let locks = LockManager::new(paths.root());
        let store = AuthStore::new(paths.clone(), locks);
        (parent, paths, store)
    }

    #[test]
    fn empty_auth_reads_are_side_effect_free() {
        let (_parent, paths, store) = setup();
        assert!(!store.is_configured().unwrap());
        assert!(!store.verify("password").unwrap());
        store.remove().unwrap();
        assert!(!paths.root().exists());
    }

    #[test]
    fn correct_wrong_and_removed_passwords() {
        let (_parent, paths, store) = setup();
        let password = Zeroizing::new("unusual password\nwith trailing newline\n".to_owned());
        store.set(password.clone()).unwrap();
        assert!(store.is_configured().unwrap());
        assert!(store.verify(&password).unwrap());
        assert!(!store.verify("wrong").unwrap());
        assert!(!store.verify("").unwrap());
        let contents = std::fs::read(paths.auth()).unwrap();
        assert!(contents.starts_with(b"$argon2id$v=19$"));
        assert!(!contents.windows(password.len()).any(|part| part == password.as_bytes()));
        assert!(!paths.secret_key().exists());
        store.remove().unwrap();
        assert!(!store.is_configured().unwrap());
    }

    #[test]
    fn malformed_auth_never_becomes_unconfigured() {
        let (_parent, paths, store) = setup();
        secure_fs::create_dir_all(paths.root()).unwrap();
        for text in [
            "", "not a PHC hash", "$argon2id$v=19$m=19456,t=2,p=1",
            "$argon2id$v=19$m=19456,t=2,p=4294967295$c2FsdHNhbHQ$YWJjZA",
            "$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$YWJjZA",
            "$argon2id$v=19$m=0,t=2,p=1$c2FsdHNhbHQ$YWJjZA",
        ] {
            secure_fs::atomic_write(paths.auth(), text.as_bytes()).unwrap();
            assert_eq!(store.is_configured().err().unwrap().code, "auth_failed");
            assert_eq!(store.verify("password").err().unwrap().code, "auth_failed");
        }
    }

    fn phc(memory: u32, time: u32, parallelism: u32, salt_len: usize, output_len: usize) -> String {
        use base64::Engine;
        let salt = SaltString::encode_b64(&vec![0u8; salt_len]).unwrap();
        let output = base64::engine::general_purpose::STANDARD_NO_PAD.encode(vec![0u8; output_len]);
        format!("$argon2id$v=19$m={memory},t={time},p={parallelism}${salt}${output}")
    }

    #[test]
    fn enormous_valid_argon2_costs_are_rejected_before_verification() {
        let (_parent, paths, store) = setup();
        secure_fs::create_dir_all(paths.root()).unwrap();
        for (memory, time) in [
            (u32::MAX, Params::DEFAULT_T_COST),
            (Params::DEFAULT_M_COST, u32::MAX),
            (u32::MAX, u32::MAX),
        ] {
            // Valid PHC syntax, salt and output: rejection must be the cost
            // policy, not an incidental malformed-hash or missing-field error.
            let text = phc(memory, time, Params::DEFAULT_P_COST, 16, 32);
            assert!(PasswordHash::new(&text).is_ok());
            assert_eq!(parse_hash(text.as_bytes()).err().unwrap().code, "auth_failed");
            secure_fs::atomic_write(paths.auth(), text.as_bytes()).unwrap();
            assert_eq!(store.is_configured().err().unwrap().code, "auth_failed");
            assert_eq!(store.verify("password").err().unwrap().code, "auth_failed");
        }
    }

    #[test]
    fn supported_profile_rejects_adjacent_costs_and_wrong_salt_or_output_lengths() {
        let memory = Params::DEFAULT_M_COST;
        let time = Params::DEFAULT_T_COST;
        let parallelism = Params::DEFAULT_P_COST;
        assert!(parse_hash(phc(memory, time, parallelism, 16, 32).as_bytes()).is_ok());
        for (m, t, p, salt_len, output_len) in [
            (memory - 1, time, parallelism, 16, 32),
            (memory + 1, time, parallelism, 16, 32),
            (memory, time - 1, parallelism, 16, 32),
            (memory, time + 1, parallelism, 16, 32),
            (memory, time, parallelism + 1, 16, 32),
            (memory, time, parallelism, 15, 32),
            (memory, time, parallelism, 17, 32),
            (memory, time, parallelism, 16, 31),
            (memory, time, parallelism, 16, 33),
        ] {
            let text = phc(m, t, p, salt_len, output_len);
            assert_eq!(parse_hash(text.as_bytes()).err().unwrap().code, "auth_failed");
        }
    }

    #[test]
    fn invalid_password_does_not_replace_auth() {
        let (_parent, paths, store) = setup();
        assert!(store.set(Zeroizing::new(String::new())).is_err());
        assert!(!paths.root().exists());
        store.set(Zeroizing::new("original".into())).unwrap();
        let before = std::fs::read(paths.auth()).unwrap();
        assert!(store.set(Zeroizing::new("a\0b".into())).is_err());
        assert_eq!(std::fs::read(paths.auth()).unwrap(), before);
    }
}
