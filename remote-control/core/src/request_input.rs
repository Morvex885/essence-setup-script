//! Request input: file contents a client read for the command (`@name`
//! tokens of the catalog), a JSON object of strings.
//!
//! Values live only in `Zeroizing` buffers and may hold sensitive text (age
//! keys). The type deliberately implements neither `Debug`, `Clone` nor
//! `Serialize`, and its errors never contain a supplied name or value. Parser
//! scratch buffers inside serde_json are outside this guarantee.

use std::{collections::BTreeMap, fmt};

use serde::de::{self, Deserialize, Deserializer, MapAccess, Visitor};
use zeroize::Zeroizing;

use crate::error::{RcError, Result};

#[derive(Default)]
pub struct Input {
    values: BTreeMap<String, Zeroizing<String>>,
}

fn invalid_shape() -> RcError {
    RcError::new("usage", "Поле input должно быть JSON-объектом строк.")
}

fn too_large() -> RcError {
    RcError::new("invalid", "Входные данные превышают 1 МиБ.")
}

fn unsupported() -> RcError {
    RcError::new("usage", "Поле input не поддерживается командой.")
}

const TOO_LARGE: &str = "input too large";
const TOO_MANY: &str = "input names";

impl Input {
    /// Largest value in bytes.
    pub const MAX_VALUE: usize = 1 << 20;
    /// Most names in one request; no command declares more.
    pub const MAX_NAMES: usize = 4;

    /// Strict decode: an object of strings without duplicate names, at most
    /// `MAX_NAMES` names and `MAX_VALUE` bytes per value.
    pub fn from_json(text: &str) -> Result<Self> {
        let mut deserializer = serde_json::Deserializer::from_str(text);
        let input = Input::deserialize(&mut deserializer).map_err(|error| {
            let text = error.to_string();
            if text.starts_with(TOO_LARGE) {
                too_large()
            } else if text.starts_with(TOO_MANY) {
                unsupported()
            } else {
                invalid_shape()
            }
        })?;
        deserializer.end().map_err(|_| invalid_shape())?;
        Ok(input)
    }

    pub fn get(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(|value| value.as_str())
    }

    pub fn insert(&mut self, name: &str, value: Zeroizing<String>) -> Result<()> {
        if value.len() > Self::MAX_VALUE {
            return Err(too_large());
        }
        if !self.values.contains_key(name) && self.values.len() >= Self::MAX_NAMES {
            return Err(unsupported());
        }
        self.values.insert(name.to_owned(), value);
        Ok(())
    }

    /// Every supplied name must be an `@name` token of the command.
    pub fn validate_allowed(&self, allowed: &[&str]) -> Result<()> {
        if self.values.keys().all(|name| allowed.contains(&name.as_str())) { Ok(()) } else { Err(unsupported()) }
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }
}

impl<'de> Deserialize<'de> for Input {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        struct InputVisitor;

        impl<'de> Visitor<'de> for InputVisitor {
            type Value = Input;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("an object of strings")
            }

            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> std::result::Result<Input, A::Error> {
                let mut input = Input::default();
                while let Some(name) = map.next_key::<String>()? {
                    let value = Zeroizing::new(map.next_value::<String>()?);
                    if input.values.contains_key(&name) {
                        return Err(de::Error::custom("duplicate input"));
                    }
                    if value.len() > Input::MAX_VALUE {
                        return Err(de::Error::custom(TOO_LARGE));
                    }
                    if input.values.len() >= Input::MAX_NAMES {
                        return Err(de::Error::custom(TOO_MANY));
                    }
                    input.values.insert(name, value);
                }
                Ok(input)
            }
        }

        deserializer.deserialize_map(InputVisitor)
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    const SENTINEL: &str = "input-SENTINEL-value";

    fn object(values: &[(&str, String)]) -> String {
        let map: serde_json::Map<String, serde_json::Value> =
            values.iter().map(|(name, value)| ((*name).to_owned(), json!(value))).collect();
        serde_json::Value::Object(map).to_string()
    }

    #[test]
    fn accepts_strings_up_to_the_bounds() {
        let input = Input::from_json(&object(&[("file", "a".repeat(Input::MAX_VALUE))])).unwrap();
        assert_eq!(input.get("file").map(str::len), Some(Input::MAX_VALUE));
        assert!(input.validate_allowed(&["file"]).is_ok());
        assert!(Input::from_json("{}").unwrap().is_empty());
        let four: Vec<(&str, String)> = ["a", "b", "c", "d"].iter().map(|name| (*name, String::new())).collect();
        assert!(Input::from_json(&object(&four)).is_ok());

        let mut built = Input::default();
        for name in ["a", "b", "c", "d"] {
            built.insert(name, Zeroizing::new(String::new())).unwrap();
        }
        built.insert("a", Zeroizing::new("again".into())).unwrap();
        assert_eq!(built.get("a"), Some("again"));
        assert_eq!(built.insert("e", Zeroizing::new(String::new())).unwrap_err().code, "usage");
        let large = Zeroizing::new("x".repeat(Input::MAX_VALUE + 1));
        let error = Input::default().insert("file", large).unwrap_err();
        assert_eq!((error.code, error.message.as_str()), ("invalid", "Входные данные превышают 1 МиБ."));
    }

    #[test]
    fn rejects_shapes_sizes_counts_and_names_without_echo() {
        let five: Vec<(&str, String)> = ["a", "b", "c", "d", "e"].iter().map(|name| (*name, String::new())).collect();
        for (text, code, message) in [
            (String::new(), "usage", "Поле input должно быть JSON-объектом строк."),
            ("[]".into(), "usage", "Поле input должно быть JSON-объектом строк."),
            (r#"{"file":7}"#.into(), "usage", "Поле input должно быть JSON-объектом строк."),
            (format!(r#"{{"file":"{SENTINEL}","file":"b"}}"#), "usage", "Поле input должно быть JSON-объектом строк."),
            (format!(r#"{{"file":"{SENTINEL}"}} trailing"#), "usage", "Поле input должно быть JSON-объектом строк."),
            (object(&[("file", format!("{SENTINEL}{}", "x".repeat(Input::MAX_VALUE)))]), "invalid", "Входные данные превышают 1 МиБ."),
            (object(&five), "usage", "Поле input не поддерживается командой."),
        ] {
            let error = Input::from_json(&text).err().expect("rejected");
            assert_eq!((error.code, error.message.as_str()), (code, message));
            let rendered = format!("{error:?} {error} {}", serde_json::to_string(&error).unwrap());
            assert!(!rendered.contains(SENTINEL));
        }
        let input = Input::from_json(&object(&[(SENTINEL, String::new())])).unwrap();
        let error = input.validate_allowed(&["file"]).unwrap_err();
        assert_eq!((error.code, error.message.as_str()), ("usage", "Поле input не поддерживается командой."));
        assert!(!format!("{error:?}").contains(SENTINEL));
        assert_eq!(input.validate_allowed(&[]).unwrap_err().code, "usage");
    }
}
