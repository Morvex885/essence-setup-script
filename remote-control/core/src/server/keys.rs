//! Keys and parameters generated once and never changed: Reality and
//! AmneziaWG key pairs, transport paths, client AmneziaWG credentials and the
//! deterministic cascade credentials. Private node keys live only in the
//! machine secret store (`node:<id>:reality-key`, `node:<id>:awg-key`).

use std::collections::BTreeSet;

use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

use crate::error::{RcError, Result};
use crate::model::{ClientCredentials, Config, NodeAwg, NodeReality};
use crate::secrets::random_bytes;
use crate::state::State;

/// Highest AmneziaWG host index (the subnet is a /16 without its broadcast).
pub const AWG_INDEX_MAX: u32 = 65533;
/// The first client index; `.1` belongs to the server.
pub const AWG_INDEX_MIN: u32 = 2;

/// A clamped X25519 private key and its public key.
fn x25519_pair() -> Result<(Zeroizing<[u8; 32]>, [u8; 32])> {
    let mut private = Zeroizing::new([0u8; 32]);
    random_bytes(&mut *private)?;
    private[0] &= 248;
    private[31] &= 127;
    private[31] |= 64;
    let secret = StaticSecret::from(*private);
    let public = PublicKey::from(&secret);
    Ok((private, public.to_bytes()))
}

/// Reality `(private, public)`: unpadded base64url, as `mihomo generate reality-keypair`.
pub fn reality_keypair() -> Result<(Zeroizing<String>, String)> {
    let (private, public) = x25519_pair()?;
    Ok((Zeroizing::new(URL_SAFE_NO_PAD.encode(*private)), URL_SAFE_NO_PAD.encode(public)))
}

/// WireGuard `(private, public)`: padded standard base64, as `wg genkey | wg pubkey`.
pub fn wg_keypair() -> Result<(Zeroizing<String>, String)> {
    let (private, public) = x25519_pair()?;
    Ok((Zeroizing::new(STANDARD.encode(*private)), STANDARD.encode(public)))
}

/// 32 random bytes in standard base64 (`wg genpsk`).
pub fn wg_key() -> Result<Zeroizing<String>> {
    let mut bytes = Zeroizing::new([0u8; 32]);
    random_bytes(&mut *bytes)?;
    Ok(Zeroizing::new(STANDARD.encode(*bytes)))
}

/// `chars` random lowercase hex characters.
pub fn hex(chars: usize) -> Result<String> {
    let mut bytes = Zeroizing::new(vec![0u8; chars.div_ceil(2)]);
    random_bytes(&mut bytes)?;
    let mut text = hex::encode(&*bytes);
    text.truncate(chars);
    Ok(text)
}

/// Uniform integer in `low..=high` (rejection sampling over a random u32).
pub(crate) fn uniform(low: u32, high: u32) -> Result<u32> {
    let span = u64::from(high - low) + 1;
    let limit = (1u64 << 32) / span * span;
    loop {
        let mut bytes = [0u8; 4];
        random_bytes(&mut bytes)?;
        let value = u64::from(u32::from_le_bytes(bytes));
        if value < limit {
            return Ok(low + u32::try_from(value % span).unwrap_or(0));
        }
    }
}

/// AmneziaWG junk parameters `(jc, s1, s2, s3)`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AwgParams { pub jc: u8, pub s1: u16, pub s2: u16, pub s3: u16 }

/// The `_awg_gen_params` rule: S1, S2, S3 and S4 = 12 pairwise different, and
/// the padded handshake sizes S1+148, S2+92, S3+64 pairwise different.
pub fn awg_params_valid(s1: u16, s2: u16, s3: u16) -> bool {
    let sizes = [s1, s2, s3, 12];
    let distinct = sizes.iter().collect::<BTreeSet<_>>().len() == sizes.len();
    let padded = [s1 + 148, s2 + 92, s3 + 64];
    distinct && padded.iter().collect::<BTreeSet<_>>().len() == padded.len()
}

/// jc 4–6, s1/s2 12–149, s3 12–63 satisfying [`awg_params_valid`].
pub fn awg_params() -> Result<AwgParams> {
    let jc = u8::try_from(uniform(4, 6)?).unwrap_or(4);
    loop {
        let s1 = u16::try_from(uniform(12, 149)?).unwrap_or(12);
        let s2 = u16::try_from(uniform(12, 149)?).unwrap_or(12);
        let s3 = u16::try_from(uniform(12, 63)?).unwrap_or(12);
        if awg_params_valid(s1, s2, s3) {
            return Ok(AwgParams { jc, s1, s2, s3 });
        }
    }
}

/// Fill every missing generated value: node parameters of the transports the
/// node's profile enables (private keys go to the secret store) and client
/// credentials. Existing values are never changed. Runs inside `Session::mutate`.
pub fn ensure_generated(state: &State, config: &mut Config) -> Result<()> {
    let profiles = config.profiles.clone();
    let store = state.secret_store();
    for node in &mut config.nodes {
        let Some(profile) = node.profile.as_deref().and_then(|name| profiles.iter().find(|p| p.name == name)) else {
            continue;
        };
        let params = &mut node.params;
        if params.reality.is_none() && profile.has_reality() {
            let (private, public_key) = reality_keypair()?;
            store.set(&format!("node:{}:reality-key", node.id), private)?;
            params.reality = Some(NodeReality { public_key, short_id: hex(16)? });
        }
        if params.xhttp_path.is_none() && profile.vless_xhttp.is_some() {
            params.xhttp_path = Some(format!("/{}", hex(16)?));
        }
        if params.grpc_service.is_none() && profile.vless_grpc.is_some() {
            params.grpc_service = Some(format!("grpc-{}", hex(8)?));
        }
        if params.hy2_obfs_password.is_none() && profile.hysteria2.as_ref().is_some_and(|hy2| hy2.obfs) {
            params.hy2_obfs_password = Some(hex(24)?);
        }
        if params.awg.is_none() && profile.amneziawg.is_some() {
            let (private, public_key) = wg_keypair()?;
            store.set(&format!("node:{}:awg-key", node.id), private)?;
            let AwgParams { jc, s1, s2, s3 } = awg_params()?;
            params.awg = Some(NodeAwg {
                public_key, header_protection_key: wg_key()?.to_string(),
                tproxy_port: u16::try_from(uniform(10000, 60000)?).unwrap_or(10000), jc, s1, s2, s3,
            });
        }
    }
    let mut used: BTreeSet<u32> = config.clients.iter()
        .filter_map(|client| client.credentials.as_ref().map(|c| c.awg_index)).filter(|index| *index != 0).collect();
    for client in &mut config.clients {
        let credentials = client.credentials.get_or_insert_with(ClientCredentials::default);
        if credentials.vless_uuid.is_empty() {
            credentials.vless_uuid = crate::clients::client::uuid_v4();
        }
        if credentials.hy2_password.is_empty() {
            credentials.hy2_password = crate::github::random_hex(16);
        }
        if credentials.awg_private_key.is_empty() {
            credentials.awg_private_key = wg_keypair()?.0.to_string();
        }
        if credentials.awg_preshared_key.is_empty() {
            credentials.awg_preshared_key = wg_key()?.to_string();
        }
        if credentials.awg_index == 0 {
            let index = (AWG_INDEX_MIN..=AWG_INDEX_MAX).find(|index| !used.contains(index))
                .ok_or_else(|| RcError::new("invalid", "Слишком много клиентов для подсети AmneziaWG."))?;
            used.insert(index);
            credentials.awg_index = index;
        }
    }
    Ok(())
}

/// The client's VLESS UUID on a cascade: the first 16 bytes of
/// SHA-256("<uuid>:<cascade>") as an RFC 4122 version-4 UUID.
pub fn cascade_uuid(client_uuid: &str, cascade: &str) -> String {
    let digest = Sha256::digest(format!("{client_uuid}:{cascade}").as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = hex::encode(bytes);
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

/// The client's Hysteria2 password on a cascade: the first 32 hex of
/// SHA-256("<password>:<cascade>").
pub fn cascade_password(hy2_password: &str, cascade: &str) -> String {
    let mut hex = hex::encode(Sha256::digest(format!("{hy2_password}:{cascade}").as_bytes()));
    hex.truncate(32);
    hex
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{AmneziaWg, Client, Hysteria2, Node, PortOnly, Profile, Xhttp, XhttpTopology};
    use crate::state::StatePaths;
    use crate::validation as v;

    #[test]
    fn key_pairs_have_their_encodings_and_match() {
        let (private, public) = reality_keypair().unwrap();
        assert_eq!((private.len(), public.len()), (43, 43));
        assert!(!private.contains('=') && !private.contains('+') && !private.contains('/'));
        let raw: [u8; 32] = URL_SAFE_NO_PAD.decode(private.as_bytes()).unwrap().try_into().unwrap();
        assert_eq!(URL_SAFE_NO_PAD.encode(PublicKey::from(&StaticSecret::from(raw)).as_bytes()), public);
        let (private, public) = wg_keypair().unwrap();
        assert_eq!((private.len(), public.len()), (44, 44));
        assert!(private.ends_with('=') && public.ends_with('='));
        let raw: [u8; 32] = STANDARD.decode(private.as_bytes()).unwrap().try_into().unwrap();
        assert_eq!(raw[0] & 7, 0);
        assert_eq!(raw[31] & 0xc0, 0x40);
        assert_eq!(STANDARD.encode(PublicKey::from(&StaticSecret::from(raw)).as_bytes()), public);
        assert_eq!(STANDARD.decode(wg_key().unwrap().as_bytes()).unwrap().len(), 32);
        let text = hex(16).unwrap();
        assert!(text.len() == 16 && text.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()));
        assert_eq!(hex(7).unwrap().len(), 7);
    }

    #[test]
    fn awg_params_follow_the_bash_rule() {
        assert!(!awg_params_valid(12, 20, 30), "S1 equals S4");
        assert!(!awg_params_valid(20, 76, 30), "S1+148 equals S2+92");
        assert!(!awg_params_valid(20, 30, 30));
        assert!(awg_params_valid(20, 30, 40));
        for _ in 0..200 {
            let AwgParams { jc, s1, s2, s3 } = awg_params().unwrap();
            assert!((4..=6).contains(&jc) && (12..=149).contains(&s1) && (12..=149).contains(&s2) && (12..=63).contains(&s3));
            assert!(awg_params_valid(s1, s2, s3));
        }
    }

    #[test]
    fn cascade_credentials_are_deterministic_and_well_formed() {
        let uuid = cascade_uuid("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "via-de");
        assert_eq!(uuid, cascade_uuid("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "via-de"));
        assert_ne!(uuid, cascade_uuid("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "via-nl"));
        assert!(v::vless_uuid_valid(&uuid));
        assert_eq!(&uuid[14..15], "4");
        assert!(matches!(&uuid[19..20], "8" | "9" | "a" | "b"));
        let password = cascade_password("router-hy2-pass-0001", "via-de");
        let full = hex::encode(Sha256::digest(b"router-hy2-pass-0001:via-de"));
        assert_eq!(password, full[..32]);
    }

    fn profile() -> Profile {
        Profile {
            name: "main".into(), mihomo_version: "v1.19.18".into(), acme_email: "a@example.com".into(),
            vless_tcp: true, vless_xhttp: Some(Xhttp { topology: XhttpTopology::Nginx, port: None }),
            vless_grpc: Some(PortOnly { port: 2053 }), hysteria2: Some(Hysteria2 { port: 8443 + 1000, obfs: true }),
            amneziawg: Some(AmneziaWg { port: 51820, dns: crate::model::default_awg_dns() }),
            ..Profile::default()
        }
    }

    #[test]
    fn ensure_generated_fills_only_missing_values_and_stores_private_keys() {
        let dir = tempfile::tempdir().unwrap();
        let state = State::new(StatePaths::new(dir.path().join("data")));
        let id = "c".repeat(32);
        let mut config = Config::default();
        config.profiles.push(profile());
        config.nodes.push(Node { id: id.clone(), name: "de".into(), ip: "192.0.2.1".into(), port: 22, user: "root".into(),
            profile: Some("main".into()), ..Node::default() });
        config.nodes.push(Node { id: "d".repeat(32), name: "bare".into(), ip: "192.0.2.2".into(), port: 22,
            user: "root".into(), ..Node::default() });
        config.clients = vec![
            Client { name: "taken".into(), group: "PC".into(), credentials: Some(ClientCredentials {
                vless_uuid: "11111111-2222-4333-8444-555555555555".into(), hy2_password: "keep".into(),
                awg_index: 2, ..ClientCredentials::default() }), ..Client::default() },
            Client { name: "fresh".into(), group: "PC".into(), ..Client::default() },
        ];
        ensure_generated(&state, &mut config).unwrap();
        config.validate().unwrap();
        let params = config.nodes[0].params.clone();
        let reality = params.reality.clone().unwrap();
        assert_eq!(reality.short_id.len(), 16);
        assert!(params.xhttp_path.as_deref().is_some_and(|p| p.len() == 17 && p.starts_with('/')));
        assert!(params.grpc_service.as_deref().is_some_and(|s| s.len() == 13 && s.starts_with("grpc-")));
        assert_eq!(params.hy2_obfs_password.as_deref().map(str::len), Some(24));
        let awg = params.awg.clone().unwrap();
        assert!((10000..=60000).contains(&awg.tproxy_port));
        assert!(awg_params_valid(awg.s1, awg.s2, awg.s3));
        let store = state.secret_store();
        let private = store.get(&format!("node:{id}:reality-key")).unwrap().unwrap();
        let raw: [u8; 32] = URL_SAFE_NO_PAD.decode(private.as_bytes()).unwrap().try_into().unwrap();
        assert_eq!(URL_SAFE_NO_PAD.encode(PublicKey::from(&StaticSecret::from(raw)).as_bytes()), reality.public_key);
        assert!(store.get(&format!("node:{id}:awg-key")).unwrap().is_some());
        assert!(config.nodes[1].params.is_empty(), "a node without a profile gets nothing");

        let taken = config.clients[0].credentials.clone().unwrap();
        assert_eq!((taken.hy2_password.as_str(), taken.awg_index), ("keep", 2));
        assert_eq!(taken.vless_uuid, "11111111-2222-4333-8444-555555555555");
        let fresh = config.clients[1].credentials.clone().unwrap();
        assert!(v::vless_uuid_valid(&fresh.vless_uuid) && v::hy2_password_valid(&fresh.hy2_password));
        assert_eq!(fresh.awg_index, 3);
        assert_eq!(STANDARD.decode(&fresh.awg_private_key).unwrap().len(), 32);

        let before = config.clone();
        ensure_generated(&state, &mut config).unwrap();
        assert_eq!(config, before, "a second run changes nothing");
    }

    #[test]
    fn awg_index_overflow_is_invalid() {
        let dir = tempfile::tempdir().unwrap();
        let state = State::new(StatePaths::new(dir.path().join("data")));
        let mut clients: Vec<Client> = (AWG_INDEX_MIN..=AWG_INDEX_MAX).map(|index| Client {
            name: format!("c{index}"), group: "PC".into(), credentials: Some(ClientCredentials {
                vless_uuid: "x".into(), hy2_password: "x".into(), awg_private_key: "k".into(), awg_preshared_key: "p".into(),
                awg_index: index }), ..Client::default()
        }).collect();
        clients.push(Client { name: "extra".into(), group: "PC".into(), ..Client::default() });
        let mut config = Config { clients, ..Config::default() };
        let error = ensure_generated(&state, &mut config).unwrap_err();
        assert_eq!(error.code, "invalid");
        assert_eq!(error.message, "Слишком много клиентов для подсети AmneziaWG.");
    }
}
