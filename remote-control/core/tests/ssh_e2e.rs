//! Real OpenSSH coverage, enabled only by the disposable CI fixture.
use std::{env, fs, path::PathBuf, time::Duration};

use rc_core::{
    model::Fingerprint,
    ssh::SshTransport,
    transport::{Authentication, ConnectOptions, HostKeyPolicy, RemoteSession, RemoteTransport},
};
use zeroize::Zeroizing;

const TIMEOUT: Duration = Duration::from_secs(10);

struct Fixture {
    host: String,
    port: u16,
    user: String,
    password: String,
    key: PathBuf,
    fingerprint: Fingerprint,
    other_fingerprint: Fingerprint,
}

impl Fixture {
    fn from_env() -> Option<Self> {
        if env::var_os("E2E_SSH").as_deref() != Some(std::ffi::OsStr::new("1")) {
            return None;
        }
        let required = |name: &str| {
            let value = env::var(name).unwrap_or_else(|_| panic!("E2E_SSH=1 requires {name}"));
            assert!(!value.is_empty(), "E2E_SSH=1 requires nonempty {name}");
            value
        };
        let host = required("E2E_SSH_HOST");
        assert_eq!(host, "127.0.0.1", "SSH e2e must use the loopback fixture");
        let port = required("E2E_SSH_PORT").parse::<u16>().expect("invalid E2E_SSH_PORT");
        assert!(port > 1023, "SSH e2e requires an unprivileged fixture port");
        let key = PathBuf::from(required("E2E_SSH_KEY"));
        assert!(key.is_file(), "E2E_SSH_KEY must name the generated private key");
        Some(Self {
            host,
            port,
            user: required("E2E_SSH_USER"),
            password: required("E2E_SSH_PASSWORD"),
            key,
            fingerprint: required("E2E_SSH_FINGERPRINT").parse().expect("invalid fixture fingerprint"),
            other_fingerprint: required("E2E_SSH_OTHER_FINGERPRINT").parse().expect("invalid second fingerprint"),
        })
    }

    fn options(&self, auth: Authentication, expected: Option<Fingerprint>, known: Vec<Fingerprint>) -> ConnectOptions {
        ConnectOptions {
            host: self.host.clone(), port: self.port, user: self.user.clone(), auth,
            host_key: HostKeyPolicy { expected, known }, timeout: TIMEOUT,
        }
    }

    fn password(&self) -> Authentication {
        Authentication::Password(Zeroizing::new(self.password.clone()))
    }

    fn key(&self) -> Authentication {
        Authentication::Key { identity: self.key.clone(), passphrase: None }
    }
}

#[tokio::test]
async fn openssh_password_key_exec_upload_and_pins() {
    let Some(fixture) = Fixture::from_env() else { return };
    let temp = tempfile::tempdir().unwrap();

    let mut password = SshTransport::default();
    password.connect(fixture.options(fixture.password(), Some(fixture.fingerprint.clone()), vec![])).await.unwrap();
    let result = password.exec("cat; printf 'fixture-stderr' >&2; exit 23", b"fixture-stdin\n", TIMEOUT).await.unwrap();
    assert_eq!(result.stdout, b"fixture-stdin\n");
    assert_eq!(result.stderr, b"fixture-stderr");
    assert_eq!(result.exit_status, 23);
    let error = password.exec("sleep 5", b"", Duration::from_millis(150)).await.unwrap_err();
    assert_eq!(error.code, "remote_failed");
    assert_eq!(error.extra.get("reason").and_then(|v| v.as_str()), Some("timeout"));
    let result = password.exec("printf after-timeout", b"", TIMEOUT).await.unwrap();
    assert_eq!(result.stdout, b"after-timeout");
    assert_eq!(result.exit_status, 0);

    let mut key = SshTransport::default();
    key.connect(fixture.options(fixture.key(), None, vec![fixture.fingerprint.clone()])).await.unwrap();
    let held = key.hold().unwrap();
    drop(key);
    let result = held.exec("printf held", b"", TIMEOUT).await.unwrap();
    assert_eq!(result.stdout, b"held");
    assert_eq!(result.exit_status, 0);

    let local = temp.path().join("upload");
    fs::create_dir_all(local.join("nested")).unwrap();
    fs::write(local.join("nested/file.bin"), b"\0fixture\xff\n").unwrap();
    let remote = format!("/home/e2e/{}", temp.path().file_name().unwrap().to_str().unwrap());
    held.upload(&local, &remote, TIMEOUT).await.unwrap();
    let result = held.exec(&format!("cat '{remote}/nested/file.bin'"), b"", TIMEOUT).await.unwrap();
    assert_eq!(result.stdout, b"\0fixture\xff\n");
    assert_eq!(result.exit_status, 0);

    let mut mismatch = SshTransport::default();
    let error = mismatch.connect(fixture.options(fixture.password(), Some(fixture.other_fingerprint.clone()), vec![])).await.unwrap_err();
    assert_eq!(error.code, "host_key_mismatch");

    let mut changed = SshTransport::default();
    let error = changed.connect(fixture.options(fixture.password(), None, vec![fixture.other_fingerprint.clone()])).await.unwrap_err();
    assert_eq!(error.code, "host_key_changed");
    assert_eq!(error.extra.get("host").and_then(|v| v.as_str()), Some(fixture.host.as_str()));
    assert_eq!(error.extra.get("port").and_then(|v| v.as_u64()), Some(u64::from(fixture.port)));
    assert!(error.extra.get("fingerprints").and_then(|v| v.as_array()).unwrap().iter().any(|v| v.as_str() == Some(fixture.fingerprint.as_str())));

    let mut unknown = SshTransport::default();
    let error = unknown.connect(fixture.options(fixture.password(), None, vec![])).await.unwrap_err();
    assert_eq!(error.code, "host_key_unknown");

    let mut bad_password = SshTransport::default();
    let error = bad_password.connect(fixture.options(
        Authentication::Password(Zeroizing::new("incorrect-fixture-password".into())),
        Some(fixture.fingerprint.clone()), vec![],
    )).await.unwrap_err();
    assert_eq!(error.code, "remote_failed");
}
