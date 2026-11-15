//! `web install-service` / `web uninstall-service` on Linux with a fake
//! `systemctl` first on `PATH` (it records its arguments) and an overridden
//! `XDG_CONFIG_HOME`; systemd is detected through `ESSENCE_RC_SYSTEMD_DIR`.
//! Tests that write a unit are skipped as root: root's unit lives in
//! `/etc/systemd/system`, which a test must never touch.
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
    /// An environment for tests that write a unit; `None` (skipped) as root.
    fn installable() -> Option<Self> {
        // SAFETY: geteuid has no preconditions and cannot fail.
        if unsafe { libc::geteuid() } == 0 {
            eprintln!("skipped as root: the unit would go to /etc/systemd/system");
            return None;
        }
        Some(Self::new())
    }

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
        // Records its arguments; the first call of each verb listed in
        // FAKE_SYSTEMCTL_FAIL_ON fails, later calls succeed (so a rollback can
        // succeed; `is-enabled`/`is-active` failing = disabled/inactive).
        // `restart` starts the unit's ExecStart in the background, as systemd
        // would, unless FAKE_SYSTEMCTL_NO_START is set.
        let script = format!(
            concat!(
                "#!/bin/sh\necho \"$*\" >> '{log}'\n",
                "case \" $FAKE_SYSTEMCTL_FAIL_ON \" in *\" $2 \"*)\n",
                "  if [ ! -e '{root}/failed-'\"$2\" ]; then : > '{root}/failed-'\"$2\"; echo \"Failed to $2 unit: boom\" >&2; exit 1; fi;;\n",
                "esac\n",
                "if [ \"$2\" = restart ] && [ -z \"$FAKE_SYSTEMCTL_NO_START\" ]; then\n",
                "  eval \"set -- $(sed -n 's/^ExecStart=//p' \"$XDG_CONFIG_HOME/systemd/user/$3\")\"\n",
                "  \"$@\" </dev/null >/dev/null 2>&1 &\n",
                "fi\nexit 0\n",
            ),
            log = log.display(),
            root = root.path().display(),
        );
        fs::write(bin.join("systemctl"), script).unwrap();
        fs::set_permissions(bin.join("systemctl"), fs::Permissions::from_mode(0o755)).unwrap();
        Self { _root: root, data, runtime, config, systemd, bin, log }
    }

    fn record(&self) -> PathBuf {
        self.data.join("web/autostart.json")
    }

    fn unit(&self) -> PathBuf {
        self.config.join("systemd/user/essence-rc-web.service")
    }

    fn calls(&self) -> Vec<String> {
        fs::read_to_string(&self.log).unwrap_or_default().lines().map(str::to_owned).collect()
    }

    fn run(&self, args: &[&str], fail_on: &str, systemd: &Path) -> Value {
        self.run_env(args, fail_on, systemd, &[])
    }

    /// `extra` overrides the environment set here.
    fn run_env(&self, args: &[&str], fail_on: &str, systemd: &Path, extra: &[(&str, &Path)]) -> Value {
        let output = self.command(systemd).args(args).arg("--json").env("FAKE_SYSTEMCTL_FAIL_ON", fail_on)
            .envs(extra.iter().copied())
            .output()
            .unwrap();
        let stdout = String::from_utf8(output.stdout).unwrap();
        serde_json::from_str(stdout.trim()).unwrap_or_else(|_| panic!("stdout: {stdout}\nstderr: {}", String::from_utf8_lossy(&output.stderr)))
    }

    fn command(&self, systemd: &Path) -> Command {
        let path = format!("{}:{}", self.bin.display(), std::env::var("PATH").unwrap_or_default());
        let mut command = Command::new(BIN);
        command
            .env("PATH", path)
            .env("ESSENCE_RC_DATA_DIR", &self.data)
            .env("ESSENCE_RC_RUNTIME_DIR", &self.runtime)
            .env("XDG_CONFIG_HOME", &self.config)
            .env("ESSENCE_RC_SYSTEMD_DIR", systemd);
        command
    }
}

/// A daemon started by the fake `systemctl restart` does not outlive the test.
impl Drop for Env {
    fn drop(&mut self) {
        let endpoint = essence_rc_client::endpoint_in(&self.runtime, &self.data).unwrap();
        if std::os::unix::net::UnixStream::connect(&endpoint.socket).is_ok() {
            let _ = self.command(&self.systemd).args(["daemon", "stop", "--json"]).output();
        }
    }
}

#[test]
fn user_unit_is_installed_started_and_removed() {
    let Some(env) = Env::installable() else { return };
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
    let record: Value = serde_json::from_str(&fs::read_to_string(env.record()).unwrap()).unwrap();
    assert_eq!(record, serde_json::json!({"service": "systemd", "unit": env.unit().to_string_lossy()}), "where it was installed");

    // Reinstall applies the new unit to the running service.
    let again = env.run(&["web", "install-service", "--port", "18998"], "", &env.systemd);
    assert_eq!(again["ok"], true, "{again}");
    assert!(fs::read_to_string(env.unit()).unwrap().contains("\"--port\" \"18998\""));
    assert_eq!(&env.calls()[3..], ["--user is-enabled essence-rc-web.service", "--user is-active essence-rc-web.service",
        "--user daemon-reload", "--user enable essence-rc-web.service", "--user restart essence-rc-web.service"]);

    let removed = env.run(&["web", "uninstall-service"], "", &env.systemd);
    assert_eq!(removed["data"], serde_json::json!({"removed": true}), "{removed}");
    assert!(!env.unit().exists());
    assert!(!env.record().exists());
    assert_eq!(&env.calls()[8..], ["--user disable --now essence-rc-web.service", "--user daemon-reload"]);

    let again = env.run(&["web", "uninstall-service"], "", &env.systemd);
    assert_eq!(again["data"], serde_json::json!({"removed": false}));
}

#[test]
fn uninstall_uses_only_the_recorded_unit_under_another_environment() {
    let Some(env) = Env::installable() else { return };
    assert_eq!(env.run(&["web", "install-service", "--port", "0"], "", &env.systemd)["ok"], true);
    // Another HOME and config home: their default unit path holds a decoy,
    // which must stay; the recorded unit is removed.
    let (home, elsewhere) = (env.data.join("other-home"), env.data.join("other-config"));
    let decoy = elsewhere.join("systemd/user/essence-rc-web.service");
    fs::create_dir_all(decoy.parent().unwrap()).unwrap();
    fs::write(&decoy, "decoy").unwrap();
    let removed = env.run_env(&["web", "uninstall-service"], "", &env.systemd, &[("HOME", &home), ("XDG_CONFIG_HOME", &elsewhere)]);
    assert_eq!(removed["data"], serde_json::json!({"removed": true}), "{removed}");
    assert!(!env.unit().exists());
    assert!(!env.record().exists());
    assert_eq!(fs::read_to_string(&decoy).unwrap(), "decoy", "the default location is not touched");
}

#[test]
fn a_damaged_record_stops_uninstall_before_the_daemon_is_stopped() {
    let Some(env) = Env::installable() else { return };
    assert_eq!(env.run(&["web", "install-service", "--port", "0"], "", &env.systemd)["ok"], true);
    fs::write(env.record(), "{").unwrap();
    let failed = env.run(&["web", "uninstall-service"], "", &env.systemd);
    assert_eq!(failed["error"]["code"], "invalid", "{failed}");
    let endpoint = essence_rc_client::endpoint_in(&env.runtime, &env.data).unwrap();
    assert!(std::os::unix::net::UnixStream::connect(&endpoint.socket).is_ok(), "the daemon still runs");
    assert!(env.unit().exists());
    assert_eq!(env.calls().len(), 3, "no systemctl call");
}

#[test]
fn a_service_whose_panel_does_not_come_up_is_reported() {
    let Some(env) = Env::installable() else { return };
    let no_start = env.data.join("no-start");
    let failed = env.run_env(&["web", "install-service", "--port", "0"], "", &env.systemd, &[("FAKE_SYSTEMCTL_NO_START", &no_start)]);
    assert_eq!(failed["error"]["code"], "failed", "{failed}");
    let message = failed["error"]["message"].as_str().unwrap();
    assert!(message.contains("Служба установлена, но веб-панель не запустилась") && message.contains("journalctl --user"), "{failed}");
    assert!(env.unit().exists() && env.record().exists(), "the service stays installed");
}

#[test]
fn failing_systemctl_leaves_no_unit_file() {
    let Some(env) = Env::installable() else { return };
    let failed = env.run(&["web", "install-service"], "enable", &env.systemd);
    assert_eq!(failed["ok"], false, "{failed}");
    assert_eq!(failed["error"]["code"], "failed");
    assert!(failed["error"]["message"].as_str().unwrap().contains("Failed to enable unit: boom"), "{failed}");
    assert!(!env.unit().exists(), "the unit file is removed after a failure");
    assert_eq!(env.calls(), ["--user daemon-reload", "--user enable essence-rc-web.service", "--user disable --now essence-rc-web.service", "--user daemon-reload"]);
}

#[test]
fn failed_reinstall_restores_the_previous_unit() {
    let Some(env) = Env::installable() else { return };
    assert_eq!(env.run(&["web", "install-service", "--port", "18997"], "", &env.systemd)["ok"], true);
    let before = fs::read_to_string(env.unit()).unwrap();
    let failed = env.run(&["web", "install-service", "--port", "18996"], "restart", &env.systemd);
    assert_eq!(failed["error"]["code"], "failed", "{failed}");
    assert_eq!(fs::read_to_string(env.unit()).unwrap(), before, "the previous unit is back");
    // Enabled and active before: both are restored.
    assert_eq!(&env.calls()[3..], ["--user is-enabled essence-rc-web.service", "--user is-active essence-rc-web.service",
        "--user daemon-reload", "--user enable essence-rc-web.service", "--user restart essence-rc-web.service",
        "--user daemon-reload", "--user enable essence-rc-web.service", "--user restart essence-rc-web.service"]);
    // The rollback restart succeeds: the previous panel answers on its port again.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while std::net::TcpStream::connect(("127.0.0.1", 18997)).is_err() {
        assert!(std::time::Instant::now() < deadline, "the previous panel is not back on 18997");
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

#[test]
fn failed_reinstall_restores_a_disabled_inactive_unit() {
    let Some(env) = Env::installable() else { return };
    assert_eq!(env.run(&["web", "install-service", "--port", "0"], "", &env.systemd)["ok"], true);
    let failed = env.run(&["web", "install-service", "--port", "0", "--bind", "127.0.0.1"], "is-enabled is-active restart", &env.systemd);
    assert_eq!(failed["error"]["code"], "failed", "{failed}");
    assert_eq!(&env.calls()[3..], ["--user is-enabled essence-rc-web.service", "--user is-active essence-rc-web.service",
        "--user daemon-reload", "--user enable essence-rc-web.service", "--user restart essence-rc-web.service",
        "--user daemon-reload", "--user disable essence-rc-web.service", "--user stop essence-rc-web.service"]);
}

#[test]
fn failing_disable_keeps_the_unit_file() {
    let Some(env) = Env::installable() else { return };
    assert_eq!(env.run(&["web", "install-service", "--port", "0"], "", &env.systemd)["ok"], true);
    let failed = env.run(&["web", "uninstall-service"], "disable", &env.systemd);
    assert_eq!(failed["error"]["code"], "failed", "{failed}");
    assert!(env.unit().exists(), "the service may still run: its unit stays");
    assert_eq!(&env.calls()[3..], ["--user disable --now essence-rc-web.service"]);
}

#[test]
fn an_unreadable_previous_unit_aborts_before_writing() {
    let Some(env) = Env::installable() else { return };
    assert_eq!(env.run(&["web", "install-service", "--port", "18995"], "", &env.systemd)["ok"], true);
    let before = fs::read_to_string(env.unit()).unwrap();
    fs::set_permissions(env.unit(), fs::Permissions::from_mode(0o000)).unwrap();
    let failed = env.run(&["web", "install-service", "--port", "18994"], "", &env.systemd);
    fs::set_permissions(env.unit(), fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(failed["error"]["code"], "failed", "{failed}");
    assert!(failed["error"]["message"].as_str().unwrap().contains("Не удалось прочитать"), "{failed}");
    assert_eq!(fs::read_to_string(env.unit()).unwrap(), before, "the previous unit is untouched");
    // Only the read-only state queries ran; nothing was changed.
    assert_eq!(&env.calls()[3..], ["--user is-enabled essence-rc-web.service", "--user is-active essence-rc-web.service"]);
}

/// A daemon at the endpoint that refuses `daemon stop`.
fn stubborn_daemon(env: &Env) -> std::os::unix::net::UnixListener {
    use std::io::{BufRead, BufReader, Write};
    let endpoint = essence_rc_client::endpoint_in(&env.runtime, &env.data).unwrap();
    let listener = std::os::unix::net::UnixListener::bind(&endpoint.socket).unwrap();
    let serving = listener.try_clone().unwrap();
    std::thread::spawn(move || {
        for stream in serving.incoming() {
            let Ok(mut stream) = stream else { return };
            let hello = r#"{"event":"hello","protocol":3,"version":"0.0.0","origin":"local","persistent":true}"#;
            let _ = writeln!(stream, "{hello}");
            let reader = BufReader::new(stream.try_clone().unwrap());
            for line in reader.lines() {
                let Ok(line) = line else { break };
                let Ok(request) = serde_json::from_str::<Value>(&line) else { continue };
                let reply = serde_json::json!({"id": request["id"], "ok": false, "error": {"code": "failed", "message": "Отказ."}, "exit": 1});
                let _ = writeln!(stream, "{reply}");
            }
        }
    });
    listener
}

#[test]
fn a_daemon_that_does_not_stop_aborts_install_and_uninstall() {
    let Some(env) = Env::installable() else { return };
    let _daemon = stubborn_daemon(&env);
    let failed = env.run(&["web", "install-service"], "", &env.systemd);
    assert_eq!(failed["error"]["code"], "failed", "{failed}");
    assert!(failed["error"]["message"].as_str().unwrap().contains("Не удалось остановить работающий демон: Отказ."), "{failed}");
    assert!(!env.unit().exists(), "nothing is installed next to the running daemon");
    assert!(env.calls().is_empty());
    let failed = env.run(&["web", "uninstall-service"], "", &env.systemd);
    assert_eq!(failed["error"]["code"], "failed", "{failed}");
    assert!(env.calls().is_empty());
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
