//! `web install-service` / `web uninstall-service` on Linux with a fake
//! `systemctl` first on `PATH` (it records its arguments) and an overridden
//! `XDG_CONFIG_HOME`; systemd is detected through `ESSENCE_RC_SYSTEMD_DIR`.
#![cfg(target_os = "linux")]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;
use tempfile::TempDir;

const BIN: &str = env!("CARGO_BIN_EXE_essence-rc");

struct Env {
    _root: TempDir,
    data: PathBuf,
    runtime: PathBuf,
    config: PathBuf,
    systemd: PathBuf,
    bin: PathBuf,
    log: PathBuf,
}

impl Env {
    fn new() -> Self {
        let root = tempfile::Builder::new().prefix("rc").tempdir_in("/tmp").unwrap();
        let path = |name: &str| {
            let dir = root.path().join(name);
            fs::create_dir_all(&dir).unwrap();
            fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
            dir
        };
        let (data, runtime, config, systemd, bin) = (path("data"), path("run"), path("config"), path("systemd"), path("bin"));
        let log = root.path().join("systemctl.log");
        // Records its arguments; fails on the verb in FAKE_SYSTEMCTL_FAIL_ON.
        let script = format!(
            "#!/bin/sh\necho \"$*\" >> '{}'\nif [ -n \"$FAKE_SYSTEMCTL_FAIL_ON\" ] && [ \"$2\" = \"$FAKE_SYSTEMCTL_FAIL_ON\" ]; then echo \"Failed to $2 unit: boom\" >&2; exit 1; fi\nexit 0\n",
            log.display()
        );
        fs::write(bin.join("systemctl"), script).unwrap();
        fs::set_permissions(bin.join("systemctl"), fs::Permissions::from_mode(0o755)).unwrap();
        Self { _root: root, data, runtime, config, systemd, bin, log }
    }

    fn unit(&self) -> PathBuf {
        self.config.join("systemd/user/essence-rc-web.service")
    }

    fn calls(&self) -> Vec<String> {
        fs::read_to_string(&self.log).unwrap_or_default().lines().map(str::to_owned).collect()
    }

    fn run(&self, args: &[&str], fail_on: &str, systemd: &Path) -> Value {
        let path = format!("{}:{}", self.bin.display(), std::env::var("PATH").unwrap_or_default());
        let output = Command::new(BIN)
            .args(args)
            .arg("--json")
            .env("PATH", path)
            .env("ESSENCE_RC_DATA_DIR", &self.data)
            .env("ESSENCE_RC_RUNTIME_DIR", &self.runtime)
            .env("XDG_CONFIG_HOME", &self.config)
            .env("ESSENCE_RC_SYSTEMD_DIR", systemd)
            .env("FAKE_SYSTEMCTL_FAIL_ON", fail_on)
            .output()
            .unwrap();
        let stdout = String::from_utf8(output.stdout).unwrap();
        serde_json::from_str(stdout.trim()).unwrap_or_else(|_| panic!("stdout: {stdout}\nstderr: {}", String::from_utf8_lossy(&output.stderr)))
    }
}

#[test]
fn user_unit_is_installed_started_and_removed() {
    let env = Env::new();
    let installed = env.run(&["web", "install-service", "--port", "18999"], "", &env.systemd);
    assert_eq!(installed["ok"], true, "{installed}");
    assert_eq!(installed["data"]["service"], "systemd");
    assert_eq!(installed["data"]["started"], true);
    assert_eq!(installed["data"]["unit"], env.unit().to_string_lossy().as_ref());
    let text = fs::read_to_string(env.unit()).unwrap();
    assert!(text.contains(&format!("\"--data-dir\" \"{}\"", env.data.display())), "{text}");
    assert!(text.contains("\"daemon\" \"run\" \"--web\""), "{text}");
    assert!(text.contains("\"--port\" \"18999\""), "{text}");
    assert!(text.contains(&format!("Environment=\"ESSENCE_RC_RUNTIME_DIR={}\"", env.runtime.display())), "explicit runtime dir is kept: {text}");
    assert!(text.contains("WantedBy=default.target"));
    assert_eq!(env.calls(), ["--user daemon-reload", "--user enable essence-rc-web.service", "--user restart essence-rc-web.service"]);

    // Reinstall applies the new unit to the running service.
    let again = env.run(&["web", "install-service", "--port", "18998"], "", &env.systemd);
    assert_eq!(again["ok"], true, "{again}");
    assert!(fs::read_to_string(env.unit()).unwrap().contains("\"--port\" \"18998\""));
    assert_eq!(&env.calls()[3..], ["--user daemon-reload", "--user enable essence-rc-web.service", "--user restart essence-rc-web.service"]);

    let removed = env.run(&["web", "uninstall-service"], "", &env.systemd);
    assert_eq!(removed["data"], serde_json::json!({"removed": true}), "{removed}");
    assert!(!env.unit().exists());
    assert_eq!(&env.calls()[6..], ["--user disable --now essence-rc-web.service", "--user daemon-reload"]);

    let again = env.run(&["web", "uninstall-service"], "", &env.systemd);
    assert_eq!(again["data"], serde_json::json!({"removed": false}));
}

#[test]
fn failing_systemctl_leaves_no_unit_file() {
    let env = Env::new();
    let failed = env.run(&["web", "install-service"], "enable", &env.systemd);
    assert_eq!(failed["ok"], false, "{failed}");
    assert_eq!(failed["error"]["code"], "failed");
    assert!(failed["error"]["message"].as_str().unwrap().contains("Failed to enable unit: boom"), "{failed}");
    assert!(!env.unit().exists(), "the unit file is removed after a failure");
    assert_eq!(env.calls(), ["--user daemon-reload", "--user enable essence-rc-web.service", "--user disable --now essence-rc-web.service", "--user daemon-reload"]);
}

#[test]
fn failed_reinstall_restores_the_previous_unit() {
    let env = Env::new();
    assert_eq!(env.run(&["web", "install-service", "--port", "18997"], "", &env.systemd)["ok"], true);
    let before = fs::read_to_string(env.unit()).unwrap();
    let failed = env.run(&["web", "install-service", "--port", "18996"], "restart", &env.systemd);
    assert_eq!(failed["error"]["code"], "failed", "{failed}");
    assert_eq!(fs::read_to_string(env.unit()).unwrap(), before, "the previous unit is back");
    assert_eq!(&env.calls()[3..], ["--user daemon-reload", "--user enable essence-rc-web.service", "--user restart essence-rc-web.service",
        "--user daemon-reload", "--user restart essence-rc-web.service"]);
}

#[test]
fn listener_flags_are_checked_before_any_change() {
    let env = Env::new();
    let refused = env.run(&["web", "install-service", "--bind", "not-an-ip"], "", &env.systemd);
    assert_eq!(refused["error"]["code"], "invalid", "{refused}");
    assert!(!env.unit().exists());
    assert!(env.calls().is_empty());
}

#[test]
fn without_systemd_it_is_not_supported() {
    let env = Env::new();
    let missing = env.data.join("no-systemd");
    let refused = env.run(&["web", "install-service"], "", &missing);
    assert_eq!(refused["error"]["code"], "not_supported", "{refused}");
    assert!(env.calls().is_empty());
}

#[test]
fn connect_is_refused_for_service_commands() {
    let env = Env::new();
    let refused = env.run(&["--connect", "https://127.0.0.1:1", "web", "install-service"], "", &env.systemd);
    assert_eq!(refused["error"]["code"], "usage");
    assert_eq!(refused["error"]["message"], "Команда выполняется только на машине демона.");
}
