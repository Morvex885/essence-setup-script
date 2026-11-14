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

/// Node secrets suffixes stored under `node:<id>:<suffix>`.
pub const NODE_SECRET_SUFFIXES: [&str; 6] =
    ["ssh-password", "reality-key", "awg-key", "warp-key", "telegram-secret", "telegram-tag"];

/// `node:<32 hex>:<suffix>` for [`NODE_SECRET_SUFFIXES`] or `profile:<name>:warp-license`.
pub fn secret_id_valid(value: &str) -> bool {
    if let Some(rest) = value.strip_prefix("node:") {
        return rest.split_once(':').is_some_and(|(id, suffix)| node_id_valid(id) && NODE_SECRET_SUFFIXES.contains(&suffix));
    }
    value.strip_prefix("profile:").and_then(|v| v.strip_suffix(":warp-license")).is_some_and(name_valid)
}

/// The owner of a valid secret ID: `Node(id)` or `Profile(name)`.
pub enum SecretOwner<'a> { Node(&'a str), Profile(&'a str) }

pub fn secret_owner(value: &str) -> Option<SecretOwner<'_>> {
    if !secret_id_valid(value) { return None; }
    if let Some(rest) = value.strip_prefix("node:") {
        return rest.split_once(':').map(|(id, _)| SecretOwner::Node(id));
    }
    value.strip_prefix("profile:").and_then(|v| v.strip_suffix(":warp-license")).map(SecretOwner::Profile)
}

pub fn secret_id_matches(value: &str, node_id: &str) -> bool {
    node_id_valid(node_id)
        && value.strip_prefix("node:").and_then(|v| v.strip_suffix(":ssh-password")) == Some(node_id)
}

/// The stored value fits its secret: generated keys keep their encodings
/// (they are written into server configs); other values are non-empty
/// without NUL.
pub fn secret_value_valid(id: &str, value: &str) -> bool {
    match id.rsplit_once(':').map(|(_, suffix)| suffix) {
        // 32 bytes: unpadded base64url / padded standard base64.
        Some("reality-key") => value.len() == 43
            && value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'),
        Some("awg-key" | "warp-key") => value.len() == 44 && value.ends_with('=')
            && value.as_bytes()[..43].iter().all(|b| b.is_ascii_alphanumeric() || *b == b'+' || *b == b'/'),
        _ => !value.is_empty() && !value.contains('\0'),
    }
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

/// `acme_email_valid` (common/cert.sh): `^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$`.
pub fn acme_email_valid(value: &str) -> bool {
    let Some((local, domain)) = value.split_once('@') else { return false; };
    let label = |part: &str| !part.is_empty() && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');
    !local.is_empty() && local.bytes().all(|b| b.is_ascii_alphanumeric() || b"._%+-".contains(&b))
        && domain.contains('.') && domain.split('.').all(label)
}

/// DNS name: 1–253 characters, labels `[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?`, at least one dot.
pub fn domain_valid(value: &str) -> bool {
    let label = |part: &str| (1..=63).contains(&part.len())
        && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        && !part.starts_with('-') && !part.ends_with('-');
    (1..=253).contains(&value.len()) && value.contains('.') && value.split('.').all(label)
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
    fn secret_ids_cover_node_roles_and_profile_licenses() {
        let id = "ab".repeat(16);
        for suffix in NODE_SECRET_SUFFIXES {
            assert!(secret_id_valid(&format!("node:{id}:{suffix}")), "{suffix}");
        }
        assert!(secret_id_valid("profile:main-1:warp-license"));
        for bad in [format!("node:{id}:other"), format!("node:{id}"), "node:abc:ssh-password".into(),
            "profile::warp-license".into(), "profile:a b:warp-license".into(), "profile:a:b:warp-license".into(),
            "profile:main:ssh-password".into(), format!("node:{id}:reality-key\n")] {
            assert!(!secret_id_valid(&bad), "{bad}");
        }
        assert!(matches!(secret_owner(&format!("node:{id}:awg-key")), Some(SecretOwner::Node(owner)) if owner == id));
        assert!(matches!(secret_owner("profile:main:warp-license"), Some(SecretOwner::Profile("main"))));
        assert!(!secret_id_matches(&format!("node:{id}:reality-key"), &id), "only the SSH password links a node");
    }

    #[test]
    fn acme_emails_and_domains_follow_the_bash_rules() {
        for good in ["a@b.co", "first.last+tag%x_y-z@mail-1.example.org"] { assert!(acme_email_valid(good), "{good}"); }
        for bad in ["", "a@b", "@b.co", "a@@b.co", "a@b..co", "a@.b.co", "a b@c.de", "a@b_c.de", "a@b.co\n"] {
            assert!(!acme_email_valid(bad), "{bad}");
        }
        for good in ["a.b", "sub-1.example.com", "1.2.3.4", &format!("{}.{}", "a".repeat(63), "b".repeat(63))] {
            assert!(domain_valid(good), "{good}");
        }
        let long = format!("{}.com", ["a".repeat(62), "a".repeat(62), "a".repeat(62), "a".repeat(62)].join("."));
        assert_eq!(long.len(), 255);
        for bad in ["", "localhost", "-a.b", "a-.b", "a..b", ".a.b", "a.b.", "a_b.c", "é.com", &format!("{}.b", "a".repeat(64)), &long] {
            assert!(!domain_valid(bad), "{bad}");
        }
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
