//! Node operating systems `node apply` supports: the only list. The probe
//! refuses anything else before the plan; the executor gets the list as spec
//! `SUPPORTED_OS`, and its AmneziaWG step takes the Amnezia PPA suite from it.

/// `(ID, VERSION_ID, Amnezia PPA suite)` from `/etc/os-release`. Debian uses
/// the jammy build of the PPA (it has no Debian suites).
pub const SUPPORTED_OS: [(&str, &str, &str); 5] = [
    ("debian", "12", "jammy"),
    ("debian", "13", "jammy"),
    ("ubuntu", "22.04", "jammy"),
    ("ubuntu", "24.04", "noble"),
    ("ubuntu", "26.04", "resolute"),
];

pub fn supported(id: &str, version: &str) -> bool {
    SUPPORTED_OS.iter().any(|(known, release, _)| *known == id && *release == version)
}

/// «Debian 12/13 или Ubuntu 22.04/24.04/26.04».
pub fn supported_text() -> String {
    let mut groups: Vec<(&str, Vec<&str>)> = Vec::new();
    for (id, version, _) in SUPPORTED_OS {
        match groups.iter_mut().find(|(known, _)| *known == id) {
            Some((_, versions)) => versions.push(version),
            None => groups.push((id, vec![version])),
        }
    }
    groups.iter().map(|(id, versions)| format!("{} {}", display_name(id), versions.join("/"))).collect::<Vec<_>>().join(" или ")
}

fn display_name(id: &str) -> String {
    let mut chars = id.chars();
    chars.next().map(|first| first.to_uppercase().chain(chars).collect()).unwrap_or_default()
}

/// Spec `SUPPORTED_OS`: `ID:VERSION_ID:suite` separated by spaces.
pub fn spec_value() -> String {
    SUPPORTED_OS.iter().map(|(id, version, suite)| format!("{id}:{version}:{suite}")).collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_list_reads_as_text_and_as_spec() {
        assert_eq!(supported_text(), "Debian 12/13 или Ubuntu 22.04/24.04/26.04");
        assert_eq!(spec_value(), "debian:12:jammy debian:13:jammy ubuntu:22.04:jammy ubuntu:24.04:noble ubuntu:26.04:resolute");
        assert!(supported("ubuntu", "26.04") && supported("debian", "13"));
        assert!(!supported("ubuntu", "25.10") && !supported("debian", "") && !supported("centos", "9"));
    }
}
