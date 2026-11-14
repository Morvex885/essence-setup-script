//! WARP of a profiled node: the Cloudflare account is registered on the node
//! with wgcf (`_warp_prepare_account`, `setup-essence/modules/warp.sh`), its
//! WireGuard keys and addresses are kept by RC (`params.warp`, secret
//! `warp-key`) and rendered as the `warp-wg` proxy of the `outbound` group.

use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::cli::Invocation;
use crate::confirmation::Plan;
use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::log::Level;
use crate::model::{Node, NodeWarp, Profile};
use crate::nodes::{self, LONG_TIMEOUT, required, sh_quote};
use crate::transport::RemoteTransport;

/// The pinned wgcf release.
pub const WGCF_VERSION: &str = "2.3.0";

/// Remote registration: `$1` is `1` to recreate the account, stdin carries the
/// WARP+ key (or an empty line). Diagnostics go to stderr; the last stdout
/// lines are `private_key=`, `public_key=`, `ipv4=`, `ipv6=`, `plus=`.
pub const REGISTER: &str = r#"set -u
reregister="${1:-0}"
key=""
IFS= read -r key || true
key="${key%$'\r'}"
version="__WGCF_VERSION__"
valid_ipv4() {
    local address="$1" octet
    local -a octets
    IFS='.' read -r -a octets <<< "$address"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}
valid_ipv6() {
    local address="$1" group rest i compressed=0 group_count=0
    local -a groups
    [[ "$address" == *:* ]] || return 1
    [[ "$address" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    [[ "$address" != *:::* ]] || return 1
    rest="$address"
    if [[ "$rest" == *::* ]]; then
        compressed=1
        rest="${rest#*::}"
        [[ "$rest" != *::* ]] || return 1
    fi
    [[ "$address" != :* || "$address" == ::* ]] || return 1
    [[ "$address" != *: || "$address" == *:: ]] || return 1
    IFS=':' read -r -a groups <<< "${address//::/:}"
    for ((i = 0; i < ${#groups[@]}; i++)); do
        group="${groups[$i]}"
        [[ -z "$group" ]] && continue
        if [[ "$group" == *.* ]]; then
            (( i == ${#groups[@]} - 1 )) || return 1
            valid_ipv4 "$group" || return 1
            ((group_count += 2))
        else
            [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
            ((group_count++))
        fi
    done
    if (( compressed )); then (( group_count < 8 )) || return 1; else (( group_count == 8 )) || return 1; fi
}
profile_value() {
    awk -v key="$1" '{
        separator=index($0, "="); if (!separator) next
        name=substr($0, 1, separator - 1); sub(/^[[:space:]]*/, "", name); sub(/[[:space:]]*$/, "", name)
        if (name != key) next
        value=substr($0, separator + 1); sub(/^[[:space:]]*/, "", value); sub(/[[:space:]\r]*$/, "", value)
        print value; exit
    }' "$2"
}
if ! command -v curl >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl >&2 || exit 1
fi
mkdir -p /root/wgcf && cd /root/wgcf || exit 1
if [[ ! -x ./wgcf ]] || ! ./wgcf --version 2>/dev/null | grep -qF "$version"; then
    case "$(uname -m)" in
        aarch64|arm64) arch=arm64 ;;
        armv7l|armv7) arch=armv7 ;;
        *) arch=amd64 ;;
    esac
    rm -f wgcf.new
    curl -fsSLo wgcf.new "https://github.com/ViRb3/wgcf/releases/download/v${version}/wgcf_${version}_linux_${arch}" >&2 || { rm -f wgcf.new; exit 1; }
    chmod 0755 wgcf.new && mv -f wgcf.new wgcf || exit 1
fi
backup=""
restore() {
    [[ -n "$backup" ]] || return 0
    rm -f wgcf-account.toml wgcf-profile.conf
    cp -a "$backup"/. . 2>/dev/null
    rm -rf "$backup"
}
if [[ "$reregister" == 1 && -f wgcf-account.toml ]]; then
    backup=$(mktemp -d) || exit 1
    cp -a wgcf-account.toml "$backup"/ || exit 1
    [[ -f wgcf-profile.conf ]] && { cp -a wgcf-profile.conf "$backup"/ || exit 1; }
    rm -f wgcf-account.toml wgcf-profile.conf
fi
new=0
if [[ ! -f wgcf-account.toml ]]; then
    printf 'y\n' | ./wgcf register >&2 || { restore; exit 1; }
    new=1
fi
plus=false
if [[ "$new" == 1 && -n "$key" ]]; then
    ./wgcf update --license-key "$key" >&2 && plus=true
fi
rm -f wgcf-profile.conf
./wgcf generate >&2 && [[ -s wgcf-profile.conf ]] || { restore; exit 1; }
private_key=$(profile_value PrivateKey wgcf-profile.conf)
public_key=$(profile_value PublicKey wgcf-profile.conf)
[[ "$private_key" =~ ^[A-Za-z0-9+/]{43}=$ && "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { restore; exit 1; }
ipv4="" ipv6=""
line=$(grep -m1 -E '^[[:space:]]*Address[[:space:]]*=' wgcf-profile.conf)
IFS=',' read -r -a entries <<< "${line#*=}"
for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -n "$entry" ]] || continue
    address="$entry" prefix=""
    if [[ "$entry" == */* ]]; then
        address="${entry%/*}" prefix="${entry##*/}"
        [[ "$prefix" =~ ^[0-9]{1,3}$ ]] || continue
    fi
    if valid_ipv4 "$address"; then
        [[ -z "$prefix" || 10#$prefix -le 32 ]] || continue
        [[ -n "$ipv4" ]] || ipv4="$address"
    elif valid_ipv6 "$address"; then
        [[ -z "$prefix" || 10#$prefix -le 128 ]] || continue
        [[ -n "$ipv6" ]] || ipv6="$address"
    fi
done
[[ -n "$ipv4" ]] || { restore; exit 1; }
[[ -n "$backup" ]] && rm -rf "$backup"
printf 'private_key=%s\npublic_key=%s\nipv4=%s\nipv6=%s\nplus=%s\n' "$private_key" "$public_key" "$ipv4" "$ipv6" "$plus"
"#;

/// The remote command (the script is one shell word; the key goes to stdin).
pub fn register_command(reregister: bool) -> String {
    format!("bash -c {} essence-warp {}", sh_quote(&REGISTER.replace("__WGCF_VERSION__", WGCF_VERSION)), u8::from(reregister))
}

/// The account the script reported.
pub struct Registered {
    pub private_key: Zeroizing<String>,
    pub public_key: String,
    pub ipv4: String,
    pub ipv6: Option<String>,
    pub plus: bool,
}

fn key_valid(key: &str) -> bool {
    key.len() == 44 && key.ends_with('=') && key[..43].bytes().all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
}

/// The `key=value` tail of the script output; `None` when incomplete or malformed.
pub fn parse_output(stdout: &str) -> Option<Registered> {
    let value = |key: &str| stdout.lines().rev().find_map(|line| line.trim_end_matches('\r').strip_prefix(key)?.strip_prefix('='));
    let (private_key, public_key, ipv4) = (value("private_key")?, value("public_key")?, value("ipv4")?);
    if !key_valid(private_key) || !key_valid(public_key) || ipv4.parse::<std::net::Ipv4Addr>().is_err() {
        return None;
    }
    let ipv6 = value("ipv6").filter(|ipv6| !ipv6.is_empty());
    if ipv6.is_some_and(|ipv6| ipv6.parse::<std::net::Ipv6Addr>().is_err()) {
        return None;
    }
    Some(Registered {
        private_key: Zeroizing::new(private_key.to_owned()), public_key: public_key.to_owned(), ipv4: ipv4.to_owned(),
        ipv6: ipv6.map(str::to_owned), plus: value("plus")? == "true",
    })
}

/// Registration `node apply` needs before rendering: `Some(false)` — the
/// first account, `Some(true)` — a new account to bind a new WARP+ key.
pub fn registration(profile: &Profile, node: &Node) -> Option<bool> {
    if !profile.warp {
        return None;
    }
    match &node.params.warp {
        None => Some(false),
        Some(warp) if profile.warp_plus.is_some() && !warp.plus && warp.plus_attempt != profile.warp_plus => Some(true),
        Some(_) => None,
    }
}

pub fn plan_line(reregister: bool) -> &'static str {
    if reregister { "WARP: аккаунт будет перерегистрирован для привязки WARP+." } else { "WARP: будет зарегистрирован аккаунт Cloudflare." }
}

/// The `warp-wg` proxy (`render_warp_yaml` without its markers).
pub fn warp_block(warp: &NodeWarp, private_key: &str) -> String {
    let mut out = format!("  - name: warp-wg\n    type: wireguard\n    private-key: \"{private_key}\"\n    server: engage.cloudflareclient.com\n    port: 2408\n    ip: {}\n", warp.ipv4);
    match &warp.ipv6 {
        Some(ipv6) => out.push_str(&format!("    ipv6: {ipv6}\n    public-key: \"{}\"\n    allowed-ips: ['0.0.0.0/0', '::/0']\n", warp.public_key)),
        None => out.push_str(&format!("    public-key: \"{}\"\n    allowed-ips: ['0.0.0.0/0']\n", warp.public_key)),
    }
    out.push_str("    udp: true\n    mtu: 1280\n");
    out
}

/// Register (or recreate) the node's WARP account over a connected
/// transport and keep its keys: secret `warp-key`, `params.warp`.
pub async fn register<T: RemoteTransport>(session: &mut Session, node: &Node, transport: &T, reregister: bool) -> Result<()> {
    let config = session.state.load_config()?;
    let profile = node.profile.as_deref().and_then(|name| config.find_profile(name))
        .ok_or_else(|| RcError::new("invalid", format!("У ноды «{}» нет профиля.", node.name)))?;
    let license = match profile.warp_plus {
        Some(_) => session.state.secret_store().get(&format!("profile:{}:warp-license", profile.name))?,
        None => None,
    };
    let mut stdin = Zeroizing::new(license.as_deref().map(String::as_str).unwrap_or_default().to_owned());
    stdin.push('\n');
    session.log(Level::Info, &format!("{}: {}", node.name,
        if reregister { "перерегистрация аккаунта WARP" } else { "регистрация аккаунта WARP" }));
    let failed = || RcError::new("remote_failed", format!("{}: не удалось зарегистрировать WARP.", node.name)).with_extra("name", node.name.clone());
    let result = transport.exec(&register_command(reregister), stdin.as_bytes(), LONG_TIMEOUT).await.map_err(|_| failed())?;
    if result.exit_status != 0 {
        return Err(failed());
    }
    let registered = parse_output(&String::from_utf8_lossy(&result.stdout)).ok_or_else(failed)?;
    if license.is_some() && !registered.plus {
        session.log(Level::Warn, &format!(
            "{}: ключ WARP+ не привязан (лимит 5 устройств или ключ не от официального приложения) — используется бесплатный WARP", node.name));
    }
    let attempt = profile.warp_plus.clone();
    let id = node.id.clone();
    session.mutate("warp register", |state| {
        let mut config = state.load_config()?;
        let node = config.nodes.iter_mut().find(|candidate| candidate.id == id).ok_or_else(|| nodes::not_found(&id))?;
        state.secret_store().set(&format!("node:{id}:warp-key"), registered.private_key.clone())?;
        node.params.warp = Some(NodeWarp {
            public_key: registered.public_key.clone(), ipv4: registered.ipv4.clone(), ipv6: registered.ipv6.clone(),
            plus: registered.plus, plus_attempt: attempt.clone(),
        });
        state.save_config(&config)
    })?;
    session.log(Level::Success, &format!("{}: WARP {}", node.name, if registered.plus { "WARP+" } else { "бесплатный" }));
    Ok(())
}

/// `node warp-reregister --name N [--yes]`: a new account on the node.
pub async fn reregister<T: RemoteTransport>(session: &mut Session, invocation: &Invocation, transport: &mut T) -> Result<Value> {
    let name = required(invocation, "name")?;
    let config = session.state.load_config()?;
    let node = nodes::find(&config, name)?.clone();
    let warp = node.profile.as_deref().and_then(|profile| config.find_profile(profile)).is_some_and(|profile| profile.warp);
    if !warp {
        return Err(RcError::new("invalid", format!("У профиля ноды «{name}» WARP выключен.")).with_extra("name", name));
    }
    Plan::new(vec![format!(
        "Нода «{name}»: аккаунт WARP будет создан заново; прежнее устройство останется привязанным к подписке, пока его не удалят в приложении 1.1.1.1.")], "")
        .confirm(invocation)?;
    nodes::require_portable(session, &node)?;
    nodes::connect(transport, &session.state, &node).await?;
    register(session, &node, &*transport, true).await?;
    session.log(Level::Info, &format!("Примените изменения: node apply --name {name}"));
    Ok(json!({"name": name}))
}

#[cfg(test)]
mod tests;
