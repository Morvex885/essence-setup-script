//! Pure canonical domain validators used for both persisted state and command
//! input. Neither host validation nor source validation performs I/O.

use crate::error::{RcError, Result};

fn component_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-')
}

/// Canonical node/client/group names (groups normalize case when created).
/// A leading hyphen and arbitrarily long names are intentionally supported.
pub fn name_valid(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(component_byte) && value.bytes().any(|b| b != b'.')
}

pub fn normalize_group_name(value: &str) -> Result<String> {
    if !name_valid(value) {
        return Err(RcError::new("invalid", "Недопустимое название группы."));
    }
    Ok(value.to_ascii_uppercase())
}

pub fn ssh_user_valid(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=32).contains(&bytes.len())
        && (bytes[0].is_ascii_alphabetic() || bytes[0] == b'_')
        && bytes[1..].iter().copied().all(component_byte)
}

/// This is the actual SSH argv allowlist, not a DNS/IP-address parser. In
/// particular IPv6, underscores and a lone ':' are accepted; brackets are not.
pub fn ssh_host_valid(value: &str) -> bool {
    let bytes = value.as_bytes();
    (1..=253).contains(&bytes.len())
        && (bytes[0].is_ascii_alphanumeric() || bytes[0] == b':')
        && bytes[1..].iter().all(|b| component_byte(*b) || *b == b':')
}

/// CLI ports are one to five decimal digits; leading zeroes are decimal.
pub fn parse_ssh_port(value: &str) -> Result<u16> {
    if !(1..=5).contains(&value.len()) || !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err(RcError::new("invalid", "Порт SSH должен быть числом от 1 до 65535."));
    }
    value.parse::<u16>().ok().filter(|p| *p != 0)
        .ok_or_else(|| RcError::new("invalid", "Порт SSH должен быть числом от 1 до 65535."))
}

/// Stable 16-byte hex node identifiers; both hex cases are accepted.
pub fn node_id_valid(value: &str) -> bool {
    value.len() == 32 && value.bytes().all(|b| b.is_ascii_hexdigit())
}

pub fn secret_id_valid(value: &str) -> bool {
    value.strip_prefix("node:").and_then(|v| v.strip_suffix(":ssh-password"))
        .is_some_and(node_id_valid)
}

pub fn secret_id_matches(value: &str, node_id: &str) -> bool {
    node_id_valid(node_id)
        && value.strip_prefix("node:").and_then(|v| v.strip_suffix(":ssh-password")) == Some(node_id)
}

/// Empty tags are valid; required-tag creation policy belongs to the command.
pub fn node_tag_valid(value: &str) -> bool {
    value.chars().count() <= 32
        && !value.chars().any(|c| c.is_control() || ";\"'`$\\|&<>{}[]#,:/".contains(c))
}

/// Template creation accepts dots-only bases, unlike client/node names.
pub fn template_name_valid(value: &str) -> bool {
    let base = value.strip_suffix(".yaml").unwrap_or(value);
    !base.is_empty() && base.bytes().all(component_byte)
}

pub fn template_filename_valid(value: &str) -> bool {
    value.strip_suffix(".yaml").is_some_and(|v| !v.is_empty() && v.bytes().all(component_byte))
}

/// Source metadata's actual allowlist is deliberately not git-check-ref-format:
/// dots, repeated slashes and leading slashes are accepted by persisted metadata.
pub fn github_repo_valid(value: &str) -> bool {
    let Some((owner, repo)) = value.split_once('/') else { return false; };
    !owner.is_empty() && !repo.is_empty()
        && owner.bytes().all(component_byte) && repo.bytes().all(component_byte)
}

pub fn github_branch_valid(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|b| component_byte(b) || b == b'/')
}

pub fn version_valid(value: &str) -> bool {
    let mut parts = value.split('.');
    (0..3).all(|_| parts.next().is_some_and(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit())))
        && parts.next().is_none()
}

pub fn vless_uuid_valid(value: &str) -> bool {
    value.len() == 36 && value.bytes().enumerate().all(|(i, b)| {
        if matches!(i, 8 | 13 | 18 | 23) { b == b'-' } else { b.is_ascii_hexdigit() }
    })
}

pub fn hy2_password_valid(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-'))
}

pub fn subscription_token_valid(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    #[test]
    fn canonical_names_have_one_policy() {
        for good in ["-", "_", "a1._-b", &"a".repeat(200)] { assert!(name_valid(good)); }
        for bad in ["", ".", "..", "my client", "клиент", "x\n", "../x", "x;id"] {
            assert!(!name_valid(bad));
        }
        assert_eq!(normalize_group_name("pc-test").unwrap(), "PC-TEST");
    }

    #[test]
    fn ssh_allowlists_and_decimal_ports() {
        for host in ["::1", ":", "host_name", "1.2.3.4", "a-b.example"] { assert!(ssh_host_valid(host)); }
        for host in ["", "-option", "[::1]", "host/path", "host\n", "é"] { assert!(!ssh_host_valid(host)); }
        assert!(ssh_host_valid(&"a".repeat(253)));
        assert!(!ssh_host_valid(&"a".repeat(254)));
        assert!(ssh_user_valid(&format!("_{}", "a".repeat(31))));
        for user in ["", "0root", "-root", "root\n", "a:b"] { assert!(!ssh_user_valid(user)); }
        assert!(!ssh_user_valid(&"a".repeat(33)));
        assert_eq!(parse_ssh_port("00022").unwrap(), 22);
        for port in ["0", "65536", "000022", "+22", "22\n", "1.0", " 22"] { assert!(parse_ssh_port(port).is_err()); }
    }

    #[test]
    fn ids_tags_templates_and_source_boundaries() {
        let id = "AB".repeat(16);
        assert!(node_id_valid(&id));
        assert!(secret_id_valid(&format!("node:{id}:ssh-password")));
        assert!(!secret_id_valid(&format!("node:{id}:ssh-password\n")));
        assert!(node_tag_valid("🇩🇪 Германия"));
        assert!(node_tag_valid(""));
        assert!(node_tag_valid(&"界".repeat(32)));
        assert!(!node_tag_valid(&"界".repeat(33)));
        for bad in ["bad/name", "bad:name", "x\u{85}", "x\0", "a\\b"] { assert!(!node_tag_valid(bad)); }
        assert!(template_name_valid(".."));
        assert!(template_filename_valid("...yaml"));
        assert!(!template_filename_valid(".yaml"));
        assert!(!template_filename_valid("../a.yaml"));
        assert!(github_repo_valid("./.."));
        assert!(!github_repo_valid("owner/repo/extra"));
        assert!(github_branch_valid("/a//../b"));
        assert!(!github_branch_valid("branch@{1}"));
    }

    #[test]
    fn credentials_tokens_and_versions_have_exact_boundaries() {
        assert!(vless_uuid_valid("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"));
        assert!(!vless_uuid_valid("aaaaaaaabbbbccccddddeeeeeeeeeeee----"));
        assert!(hy2_password_valid("router-hy2-pass-0001"));
        assert!(hy2_password_valid(&"x".repeat(128)));
        for bad in ["", "a.b", "a/b", "a:b", "a b", &"x".repeat(129)] {
            assert!(!hy2_password_valid(bad));
        }
        assert!(subscription_token_valid(&"a".repeat(64)));
        for bad in ["", &"a".repeat(63), &"a".repeat(65), &"A".repeat(64)] {
            assert!(!subscription_token_valid(bad));
        }
        assert!(version_valid("1.22.333"));
        for bad in ["", "1.2", "1.2.3.4", "1.2.x", "1.2.3\n"] {
            assert!(!version_valid(bad));
        }
    }

    proptest! {
        #[test]
        fn valid_creation_components_roundtrip(name in "[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}") {
            prop_assert!(name_valid(&name));
            prop_assert!(name_valid(&normalize_group_name(&name).unwrap()));
        }
        #[test]
        fn control_injection_is_rejected(prefix in "[A-Za-z]{1,16}", control in 0u8..32) {
            let value = format!("{prefix}{}", char::from(control));
            prop_assert!(!name_valid(&value));
            prop_assert!(!ssh_host_valid(&value));
            prop_assert!(!ssh_user_valid(&value));
            prop_assert!(!node_tag_valid(&value));
        }
        #[test]
        fn every_nonzero_u16_is_a_port(port in 1u16..=u16::MAX) {
            prop_assert_eq!(parse_ssh_port(&port.to_string()).unwrap(), port);
        }
        #[test]
        fn host_and_user_length_edges(length in 0usize..300) {
            prop_assert_eq!(ssh_host_valid(&"a".repeat(length)), (1..=253).contains(&length));
            prop_assert_eq!(ssh_user_valid(&"a".repeat(length)), (1..=32).contains(&length));
        }
        #[test]
        fn generated_ids_link_only_to_their_node(id in "[0-9a-f]{32}") {
            let secret = format!("node:{id}:ssh-password");
            prop_assert!(node_id_valid(&id));
            prop_assert!(secret_id_valid(&secret));
            prop_assert!(secret_id_matches(&secret, &id));
            prop_assert!(!secret_id_matches(&format!("{secret}/"), &id), "trailing slash cannot be a secret ID");
        }
    }
}
