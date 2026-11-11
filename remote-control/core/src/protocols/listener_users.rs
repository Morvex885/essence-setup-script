//! Client users inside mihomo listeners (`common/listener-users.sh`): the
//! users YAML blocks and the replacement of the `# client-users-start` …
//! `# client-users-end` section of one listener in `config.yaml`.

/// Splits `name secret` lines like Bash `IFS=' ' read -r name secret`:
/// leading/trailing spaces are dropped, the secret is the rest of the line
/// after the first run of spaces, and one trailing CR is removed from it.
pub fn parse_user_lines(input: &str) -> Vec<(&str, &str)> {
    input
        .split('\n')
        .map(|l| {
            let l = l.trim_matches(' ');
            let (name, rest) = l.split_once(' ').unwrap_or((l, ""));
            let rest = rest.trim_start_matches(' ');
            (name, rest.strip_suffix('\r').unwrap_or(rest))
        })
        .collect()
}

/// Users block of a VLESS listener (`marker` `vless-tcp` adds the Vision
/// flow). Pairs with an empty name or uuid are skipped.
pub fn vless_users_yaml<'a>(marker: &str, users: impl IntoIterator<Item = (&'a str, &'a str)>) -> String {
    let mut out = String::new();
    for (name, uuid) in users.into_iter().filter(|(n, u)| !n.is_empty() && !u.is_empty()) {
        out.push_str(&format!("      - username: {name}\n        uuid: {uuid}\n"));
        if marker == "vless-tcp" {
            out.push_str("        flow: xtls-rprx-vision\n");
        }
    }
    out
}

/// Users block of the Hysteria2 listener; pairs with an empty name or
/// password are skipped. Passwords are double-quoted YAML strings.
pub fn hy2_users_yaml<'a>(users: impl IntoIterator<Item = (&'a str, &'a str)>) -> String {
    let mut out = String::new();
    for (name, password) in users.into_iter().filter(|(n, p)| !n.is_empty() && !p.is_empty()) {
        out.push_str(&format!("      {name}: \"{}\"\n", super::yaml_escape(password)));
    }
    out
}

const USERS_START: &str = "# client-users-start";
const USERS_END: &str = "# client-users-end";

/// Replaces the client users of the `# --- <marker> ---` listener block in
/// `config` with `users_yaml` (empty → no client users). `None` when the block
/// is not closed or does not hold exactly one users start marker followed by
/// exactly one end marker: a second, unclosed start would otherwise swallow
/// the closing listener marker and everything after it. Cascade users outside
/// the markers are kept.
pub fn sync(config: &str, marker: &str, users_yaml: &str) -> Option<String> {
    let start = format!("# --- {marker} ---");
    let end = format!("# --- /{marker} ---");
    let lines: Vec<&str> = config.strip_suffix('\n').unwrap_or(config).split('\n').collect();
    let lines = if config.is_empty() { Vec::new() } else { lines };

    let (mut in_range, mut closed, mut ordered) = (false, false, true);
    let (mut starts, mut ends) = (0usize, 0usize);
    for l in &lines {
        if *l == start {
            in_range = true;
        } else if *l == end {
            closed = true;
            break;
        } else if in_range && l.contains(USERS_START) {
            starts += 1;
        } else if in_range && l.contains(USERS_END) {
            ordered &= starts > 0;
            ends += 1;
        }
    }
    if !(in_range && closed && ordered && starts == 1 && ends == 1) {
        return None;
    }

    let mut out = String::with_capacity(config.len() + users_yaml.len());
    let (mut in_block, mut skipping) = (false, false);
    for l in lines {
        if l == start {
            in_block = true;
        }
        if l == end {
            in_block = false;
        }
        if in_block && l.contains(USERS_START) {
            out.push_str("      # client-users-start\n");
            if !users_yaml.is_empty() {
                for user in users_yaml.split('\n') {
                    out.push_str(user);
                    out.push('\n');
                }
            }
            out.push_str("      # client-users-end\n");
            skipping = true;
            continue;
        }
        if in_block && skipping && l.contains(USERS_END) {
            skipping = false;
            continue;
        }
        if !skipping {
            out.push_str(l);
            out.push('\n');
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn users_keep_last_line_and_strip_cr() {
        let pairs = parse_user_lines("alice  u1\r\n\n  \nbad\nbob u2");
        assert_eq!(vless_users_yaml("vless-grpc", pairs.iter().copied()), "      - username: alice\n        uuid: u1\n      - username: bob\n        uuid: u2\n");
        assert_eq!(hy2_users_yaml(parse_user_lines("a\tb\nc p#&\nd x\"y\\z\r\n")), "      c: \"p#&\"\n      d: \"x\\\"y\\\\z\"\n");
    }

    #[test]
    fn sync_replaces_only_the_marked_block() {
        let config = "# --- hy2 ---\n    users:\n      # client-users-start\n      old: pw\n      # client-users-end\n# cascade-user:a\n# --- /hy2 ---\n# --- x ---\n      # client-users-start\n";
        assert_eq!(
            sync(config, "hy2", "      new: p\\n").unwrap(),
            "# --- hy2 ---\n    users:\n      # client-users-start\n      new: p\\n\n      # client-users-end\n# cascade-user:a\n# --- /hy2 ---\n# --- x ---\n      # client-users-start\n"
        );
        assert_eq!(sync(config, "vless-tcp", ""), None);
        assert_eq!(sync("# --- hy2 ---\n# --- /hy2 ---\n      # client-users-start\n", "hy2", ""), None);
    }

    #[test]
    fn incomplete_listener_markers_fail_without_replacing_text() {
        for config in [
            "# --- hy2 ---\n      # client-users-start\n# --- /hy2 ---\n",
            "# --- hy2 ---\n      # client-users-end\n      # client-users-start\n# --- /hy2 ---\n",
            "# --- hy2 ---\n      # client-users-start\n      # client-users-end\n",
            "# --- hy2 ---\n      # client-users-start\n      # client-users-end\n      # client-users-start\n# --- /hy2 ---\ntail: keep\n",
            "# --- hy2 ---\n      # client-users-start\n      # client-users-end\n      # client-users-start\n      # client-users-end\n# --- /hy2 ---\n",
            "# --- hy2 ---\n      # client-users-end\n      # client-users-start\n      # client-users-end\n# --- /hy2 ---\n",
            "# --- hy2 ---\n      # client-users-start\n      # client-users-end\n      # client-users-end\n# --- /hy2 ---\n",
        ] {
            assert_eq!(sync(config, "hy2", "      new: pw"), None);
        }
    }
}
