//! Request secrets: a JSON object of whitelisted string values.
//!
//! Values live only in `Zeroizing` buffers. The type deliberately implements
//! neither `Debug`, `Clone` nor `Serialize`, and its errors never contain a
//! supplied key or value. Parser scratch buffers inside serde_json are outside
//! this guarantee.

use std::{collections::BTreeMap, fmt};

use serde::de::{self, Deserialize, Deserializer, MapAccess, Visitor};
use zeroize::Zeroizing;

use crate::error::{RcError, Result};

/// Every secret name a command may declare.
pub const WHITELIST: [&str; 6] = [
    "password", "current-password", "vault-password", "new-vault-password", "script-password", "access-token",
];

#[derive(Default)]
pub struct Secrets {
    values: BTreeMap<&'static str, Zeroizing<String>>,
}

fn invalid_shape() -> RcError {
    RcError::new("usage", "Секреты должны быть JSON-объектом строк.")
}

fn unsupported() -> RcError {
    RcError::new("usage", "Секрет не поддерживается командой.")
}

fn known(name: &str) -> Option<&'static str> {
    WHITELIST.into_iter().find(|candidate| *candidate == name)
}

impl Secrets {
    /// Strict decode: an object of strings, whitelisted names, no duplicates
    /// and no NUL. Any failure is a sanitized `usage` error.
    pub fn from_json(text: &str) -> Result<Self> {
        let mut deserializer = serde_json::Deserializer::from_str(text);
        let secrets = Secrets::deserialize(&mut deserializer).map_err(|error| {
            if error.to_string().starts_with(UNSUPPORTED) { unsupported() } else { invalid_shape() }
        })?;
        deserializer.end().map_err(|_| invalid_shape())?;
        Ok(secrets)
    }

    pub fn get(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(|value| value.as_str())
    }

    pub fn insert(&mut self, name: &str, value: Zeroizing<String>) -> Result<()> {
        let name = known(name).ok_or_else(unsupported)?;
        if value.contains('\0') {
            return Err(invalid_shape());
        }
        self.values.insert(name, value);
        Ok(())
    }

    /// Every supplied secret must be declared by the command.
    pub fn validate_allowed(&self, names: &[&str]) -> Result<()> {
        if self.values.keys().all(|name| names.contains(name)) { Ok(()) } else { Err(unsupported()) }
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }
}

const UNSUPPORTED: &str = "unsupported secret";

impl<'de> Deserialize<'de> for Secrets {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        struct SecretsVisitor;

        impl<'de> Visitor<'de> for SecretsVisitor {
            type Value = Secrets;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("an object of strings")
            }

            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> std::result::Result<Secrets, A::Error> {
                let mut secrets = Secrets::default();
                while let Some(key) = map.next_key::<String>()? {
                    let Some(name) = known(&key) else {
                        return Err(de::Error::custom(UNSUPPORTED));
                    };
                    let value = Zeroizing::new(map.next_value::<String>()?);
                    if value.contains('\0') || secrets.values.contains_key(name) {
                        return Err(de::Error::custom("invalid secret"));
                    }
                    secrets.values.insert(name, value);
                }
                Ok(secrets)
            }
        }

        deserializer.deserialize_map(SecretsVisitor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SENTINEL: &str = "secret-SENTINEL-value";

    #[test]
    fn accepts_whitelisted_strings_including_empty() {
        let secrets = Secrets::from_json(r#"{"password":"a","current-password":""}"#).unwrap();
        assert_eq!(secrets.get("password"), Some("a"));
        assert_eq!(secrets.get("current-password"), Some(""));
        assert!(secrets.validate_allowed(&["password", "current-password"]).is_ok());
        assert_eq!(secrets.validate_allowed(&["password"]).unwrap_err().code, "usage");
        assert!(Secrets::from_json("{}").unwrap().is_empty());
    }

    #[test]
    fn rejects_shapes_names_duplicates_and_nul_without_echo() {
        for text in [
            "", "[]", "null", "{]", r#"{"password":7}"#, r#"{"password":null}"#,
            r#"{"password":"a","password":"b"}"#, r#"{"password":"a\u0000b"}"#,
            r#"{"password":"a"} trailing"#,
            &format!(r#"{{"{SENTINEL}":"x"}}"#), &format!(r#"{{"password":"{SENTINEL}","bogus":"y"}}"#),
        ] {
            let error = Secrets::from_json(text).err().expect("rejected");
            assert_eq!(error.code, "usage", "{text}");
            let rendered = format!("{error:?} {error} {}", serde_json::to_string(&error).unwrap());
            assert!(!rendered.contains(SENTINEL));
        }
    }
}
