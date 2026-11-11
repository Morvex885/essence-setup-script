//! Cascade DNAT rules (`common/protocols/iptables-dnat.sh`) as shell text for
//! the node. IPv6 targets use `ip6tables`, IPv6 forwarding and a bracketed
//! `--to-destination [addr]:port`.

use crate::nodes::sh_quote;

/// One cascade forward: `local_port` on the node → `remote:remote_port`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Dnat<'a> {
    /// Cascade name, used in the `cascade-dnat:<name>` rule comment.
    pub name: &'a str,
    /// Target address; IPv6 may be given bracketed or bare.
    pub remote: &'a str,
    pub remote_port: &'a str,
    pub local_port: &'a str,
}

/// Rule operation: `-A` (append) or `-D` (delete).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    Append,
    Delete,
}

impl Dnat<'_> {
    fn host(&self) -> &str {
        self.remote
            .strip_prefix('[')
            .and_then(|host| host.strip_suffix(']'))
            .unwrap_or(self.remote)
    }

    fn ipv6(&self) -> bool {
        self.host().contains(':')
    }

    /// Argv of the four rules: PREROUTING DNAT and POSTROUTING MASQUERADE,
    /// each for tcp and udp.
    pub fn rules(&self, op: Op) -> Vec<Vec<String>> {
        let (tool, destination) = if self.ipv6() {
            ("ip6tables", format!("[{}]:{}", self.host(), self.remote_port))
        } else {
            ("iptables", format!("{}:{}", self.host(), self.remote_port))
        };
        let op = match op {
            Op::Append => "-A",
            Op::Delete => "-D",
        };
        let comment = format!("cascade-dnat:{}", self.name);
        let mut rules = Vec::with_capacity(4);
        for proto in ["tcp", "udp"] {
            rules.push(
                [tool, "-t", "nat", op, "PREROUTING", "-p", proto, "--dport", self.local_port, "-j", "DNAT"]
                    .into_iter()
                    .chain(["--to-destination", &destination, "-m", "comment", "--comment", &comment])
                    .map(str::to_owned)
                    .collect(),
            );
        }
        for proto in ["tcp", "udp"] {
            rules.push(
                [tool, "-t", "nat", op, "POSTROUTING", "-p", proto, "-d", self.host(), "--dport", self.remote_port]
                    .into_iter()
                    .chain(["-j", "MASQUERADE", "-m", "comment", "--comment", &comment])
                    .map(str::to_owned)
                    .collect(),
            );
        }
        rules
    }

    /// Enables forwarding, persists it by replacing an existing sysctl key
    /// or appending a missing key, then appends rules. Missing port → `None`.
    pub fn apply_script(&self) -> Option<String> {
        if self.local_port.is_empty() {
            return None;
        }
        let (key, pattern) = if self.ipv6() {
            ("net.ipv6.conf.all.forwarding", "net[.]ipv6[.]conf[.]all[.]forwarding")
        } else {
            ("net.ipv4.ip_forward", "net[.]ipv4[.]ip_forward")
        };
        let mut script = format!(
            r#"sysctl -w {key}=1 > /dev/null || return 1
if ! grep -qxF '{key}=1' /etc/sysctl.conf 2>/dev/null; then
    if grep -q '^#*[[:space:]]*{pattern}=' /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^#*[[:space:]]*{pattern}=.*/{key}=1/' /etc/sysctl.conf || return 1
    else
        printf '%s=1\n' '{key}' >> /etc/sysctl.conf || return 1
    fi
fi
"#
        );
        for (index, rule) in self.rules(Op::Append).iter().enumerate() {
            script.push_str(&command(rule));
            if index < 3 {
                script.push_str(" || return 1");
            }
            script.push('\n');
        }
        Some(script)
    }

    /// Deletes the rules; missing rules are not an error. Missing port → `None`.
    pub fn remove_script(&self) -> Option<String> {
        if self.local_port.is_empty() {
            return None;
        }
        Some(self.rules(Op::Delete)
            .iter()
            .map(|rule| format!("{} 2>/dev/null || true\n", command(rule)))
            .collect())
    }
}

/// Saves the current rules with `netfilter-persistent`, installing
/// `iptables-persistent` first when it is missing.
pub const PERSIST_SCRIPT: &str = "if ! command -v netfilter-persistent >/dev/null 2>&1; then\n    \
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q iptables-persistent > /dev/null 2>&1\n\
fi\n\
netfilter-persistent save > /dev/null 2>&1\n";

fn command(argv: &[String]) -> String {
    let mut words = argv.iter();
    let mut text = words.next().cloned().unwrap_or_default();
    for word in words {
        text.push(' ');
        text.push_str(&sh_quote(word));
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ipv6_target_uses_ip6tables_and_brackets() {
        let dnat = Dnat { name: "v6", remote: "[2001:db8::5]", remote_port: "443", local_port: "8443" };
        let rules = dnat.rules(Op::Append);
        assert_eq!(rules[0][0], "ip6tables");
        assert!(rules[0].contains(&"[2001:db8::5]:443".to_owned()));
        assert!(rules[2].contains(&"2001:db8::5".to_owned()));
        assert!(dnat.apply_script().unwrap().starts_with("sysctl -w net.ipv6.conf.all.forwarding=1"));
    }

    #[test]
    fn remove_script_quotes_and_tolerates_missing_rules() {
        let dnat = Dnat { name: "my 'node'", remote: "203.0.113.5", remote_port: "443", local_port: "8443" };
        let script = dnat.remove_script().unwrap();
        assert_eq!(script.lines().count(), 4);
        assert!(script.starts_with("iptables '-t' 'nat' '-D' 'PREROUTING' '-p' 'tcp' '--dport' '8443' "));
        assert!(script.contains("'cascade-dnat:my '\\''node'\\''' 2>/dev/null || true\n"));
    }

    #[test]
    fn empty_local_port_is_rejected_before_building_commands() {
        let dnat = Dnat { remote: "203.0.113.5", remote_port: "443", ..Dnat::default() };
        assert_eq!(dnat.apply_script(), None);
        assert_eq!(dnat.remove_script(), None);
    }

    // GNU sed (`sed -i` without a suffix): the script targets Linux servers.
    #[cfg(target_os = "linux")]
    #[test]
    fn forwarding_persistence_replaces_or_appends_without_touching_other_keys() {
        use std::{fs, process::Command};

        for (remote, key) in [
            ("203.0.113.5", "net.ipv4.ip_forward"),
            ("2001:db8::5", "net.ipv6.conf.all.forwarding"),
        ] {
            for (before, after) in [
                (format!("#  {key}=0\nkeep=9\n"), format!("{key}=1\nkeep=9\n")),
                ("keep=9\n".to_owned(), format!("keep=9\n{key}=1\n")),
                (format!("{key}=1\nkeep=9\n"), format!("{key}=1\nkeep=9\n")),
                // Dots must be literal: an unrelated key must not be replaced.
                (format!("{}=0\n", key.replace('.', "X")), format!("{}=0\n{key}=1\n", key.replace('.', "X"))),
            ] {
                let temp = tempfile::tempdir().unwrap();
                let config = temp.path().join("sysctl.conf");
                fs::write(&config, &before).unwrap();
                let dnat = Dnat { name: "n", remote, remote_port: "443", local_port: "8443" };
                let script = dnat.apply_script().unwrap().replace(
                    "/etc/sysctl.conf",
                    &sh_quote(config.to_str().unwrap()),
                );
                // Real grep/sed/printf operate on the temp file; no host
                // forwarding or firewall changes can run.
                let program = format!(
                    "sysctl() {{ :; }}\niptables() {{ :; }}\nip6tables() {{ :; }}\napply_rules() {{\n{script}}}\napply_rules\n"
                );
                let output = Command::new("bash").args(["-c", &program]).output().unwrap();
                assert!(output.status.success(), "{:?}", output.stderr);
                assert_eq!(fs::read_to_string(&config).unwrap(), after, "remote={remote}, before={before:?}");
            }
        }
    }
}
