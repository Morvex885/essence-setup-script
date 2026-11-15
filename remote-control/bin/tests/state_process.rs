mod common;

use std::{
    fs,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

/// One-shot `status --json` through its own on-demand daemon (isolated
/// runtime directory, gone before this returns).
fn status_json(data: &Path) -> std::process::Output {
    let runtime = common::runtime_dir();
    let ctx = common::Ctx { data: data.to_path_buf(), runtime: runtime.path().to_path_buf(), vars: Vec::new() };
    ctx.run(&["status", "--json"], b"")
}

use std::ops::{Deref, DerefMut};
use rc_core::state::{State, StatePaths};
use zeroize::Zeroizing;

struct Worker(Child);

impl Deref for Worker {
    type Target = Child;
    fn deref(&self) -> &Child { &self.0 }
}

impl DerefMut for Worker {
    fn deref_mut(&mut self) -> &mut Child { &mut self.0 }
}

impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
use rc_core::{locking::{LockKind, LockManager}, secure_fs};

struct TestDir(PathBuf);

impl TestDir {
    fn new() -> Self {
        // Clock resolution is coarse on macOS (µs): the counter keeps
        // directories created in the same tick distinct.
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let sequence = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("essence-state-test-{}-{nonce}-{sequence}", std::process::id()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn spawn_worker(action: &str, dir: &Path) -> Worker {
    Worker(Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "state_worker", "--nocapture"])
        .env("ESSENCE_STATE_TEST_ACTION", action)
        .env("ESSENCE_STATE_TEST_DIR", dir)
        .stdout(Stdio::null())
        .spawn()
        .unwrap())
}

fn wait_success(child: &mut Child) {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success(), "state worker failed: {status}");
            return;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("state worker timed out");
        }
        thread::sleep(Duration::from_millis(10));
    }
}

// Re-executed as a separate process; the normal harness invocation does nothing.
#[test]
fn state_worker() {
    let Ok(action) = std::env::var("ESSENCE_STATE_TEST_ACTION") else { return };
    let dir = PathBuf::from(std::env::var_os("ESSENCE_STATE_TEST_DIR").unwrap());
    match action.as_str() {
        "increment" => {
            let locks = LockManager::new(&dir);
            for _ in 0..25 {
                let _guard = locks.acquire(LockKind::Mutation, "process-test").unwrap();
                let path = dir.join("counter");
                let value: u32 = fs::read_to_string(&path).unwrap().parse().unwrap();
                thread::sleep(Duration::from_millis(2));
                secure_fs::atomic_write(&path, (value + 1).to_string().as_bytes()).unwrap();
            }
        }
        "hold" => {
            let locks = LockManager::new(&dir);
            let _guard = locks.acquire(LockKind::Mutation, "abandoned-process").unwrap();
            fs::write(dir.join("held"), b"ready").unwrap();
            loop {
                thread::sleep(Duration::from_secs(1));
            }
        }
        "create" => {
            let outcome = match secure_fs::create_new(&dir.join("exclusive")) {
                Ok(_) => "created",
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => "exists",
                Err(error) => panic!("unexpected create_new error: {error}"),
            };
            fs::write(dir.join(format!("{outcome}-{}", std::process::id())), b"").unwrap();
        }
        "write" => {
            let path = dir.join("snapshot");
            for i in 0..100 {
                let bytes = if i % 2 == 0 { vec![b'A'; 8192] } else { vec![b'B'; 8192] };
                secure_fs::atomic_write(&path, &bytes).unwrap();
            }
        }
        "expect-blocked" => {
            let locks = LockManager::new(&dir);
            match locks.acquire_with_timeout(LockKind::Mutation, "blocked", Duration::from_millis(100)) {
                Err(error) => assert_eq!(error.code, "locked"),
                Ok(_) => panic!("another process acquired a held lock"),
            }
        }
        "acquire-once" => {
            let locks = LockManager::new(&dir);
            let _guard = locks.acquire(LockKind::Mutation, "after-reclaim").unwrap();
            fs::write(dir.join("reacquired"), b"yes").unwrap();
        }
        "secret-first" | "secret-second" => {
            let (digit, value) = if action == "secret-first" { ('1', "first") } else { ('2', "second") };
            let id = format!("node:{}:ssh-password", digit.to_string().repeat(32));
            let store = State::new(StatePaths::new(&dir)).secret_store();
            store.set(&id, Zeroizing::new(value.to_owned())).unwrap();
        }
        #[cfg(unix)]
        "restrictive-umask" => {
            use std::os::unix::fs::PermissionsExt;
            // This worker is a separate process, so no sibling test's umask changes.
            unsafe { libc::umask(0o777) };
            for (name, recursive) in [("all", true), ("exclusive-dir", false)] {
                let path = dir.join(name);
                if recursive { secure_fs::create_dir_all(&path).unwrap(); }
                else { secure_fs::create_dir(&path).unwrap(); }
                assert_eq!(fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o700);
            }
        }
        #[cfg(unix)]
        "tighten-cwd" => {
            use std::os::unix::fs::PermissionsExt;
            std::env::set_current_dir(&dir).unwrap();
            secure_fs::create_dir_all(Path::new(".")).unwrap();
            assert_eq!(fs::metadata(".").unwrap().permissions().mode() & 0o777, 0o700);
        }
        _ => panic!("unknown worker action"),
    }
}

#[test]
fn mutation_lock_serializes_separate_processes() {
    let dir = TestDir::new();
    fs::write(dir.0.join("counter"), "0").unwrap();
    let mut first = spawn_worker("increment", &dir.0);
    let mut second = spawn_worker("increment", &dir.0);
    wait_success(&mut first);
    wait_success(&mut second);
    assert_eq!(fs::read_to_string(dir.0.join("counter")).unwrap(), "50");
}

#[test]
fn abandoned_process_lock_is_reclaimed() {
    let dir = TestDir::new();
    let mut holder = spawn_worker("hold", &dir.0);
    let deadline = Instant::now() + Duration::from_secs(15);
    while !dir.0.join("held").exists() {
        if let Some(status) = holder.try_wait().unwrap() {
            panic!("lock holder exited early: {status}");
        }
        if Instant::now() >= deadline {
            let _ = holder.kill();
            let _ = holder.wait();
            panic!("lock holder did not become ready");
        }
        thread::sleep(Duration::from_millis(10));
    }
    holder.kill().unwrap();
    holder.wait().unwrap();
    let locks = LockManager::new(&dir.0);
    let guard = locks.acquire(LockKind::Mutation, "reclaim-test").unwrap();
    let mut contender = spawn_worker("expect-blocked", &dir.0);
    wait_success(&mut contender);
    drop(guard);
    let mut successor = spawn_worker("acquire-once", &dir.0);
    wait_success(&mut successor);
    assert_eq!(fs::read(dir.0.join("reacquired")).unwrap(), b"yes");
    assert!(!dir.0.join(".rc-lock").exists(), "released mutation lock remains");
}

#[test]
fn secure_create_is_exclusive_across_processes() {
    let dir = TestDir::new();
    let mut first = spawn_worker("create", &dir.0);
    let mut second = spawn_worker("create", &dir.0);
    wait_success(&mut first);
    wait_success(&mut second);
    let names: Vec<_> = fs::read_dir(&dir.0).unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names.iter().filter(|name| name.starts_with("created-")).count(), 1);
    assert_eq!(names.iter().filter(|name| name.starts_with("exists-")).count(), 1);
}

#[test]
fn atomic_replacement_never_exposes_partial_content() {
    let dir = TestDir::new();
    let path = dir.0.join("snapshot");
    fs::write(&path, vec![b'A'; 8192]).unwrap();
    let mut writer = spawn_worker("write", &dir.0);
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let bytes = fs::read(&path).unwrap();
        assert_eq!(bytes.len(), 8192);
        assert!(bytes.iter().all(|b| *b == b'A') || bytes.iter().all(|b| *b == b'B'));
        if let Some(status) = writer.try_wait().unwrap() {
            assert!(status.success(), "state writer failed: {status}");
            break;
        }
        if Instant::now() >= deadline {
            let _ = writer.kill();
            let _ = writer.wait();
            panic!("state writer timed out");
        }
    }
    assert_eq!(fs::read(&path).unwrap(), vec![b'B'; 8192]);
}

#[test]
fn status_on_absent_data_directory_is_read_only() {
    let dir = TestDir::new();
    let data = dir.0.join("not-created");
    let output = status_json(&data);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["ok"], true);
    assert_eq!(value["id"], serde_json::Value::Null);
    assert_eq!(value["data"]["counts"], serde_json::json!({"nodes":0,"groups":3,"clients":0}));
    assert_eq!(value["data"]["source"], serde_json::json!({"type":"local","repo":null,"sync":null}));
    assert_eq!(value["data"]["password_missing"], serde_json::json!([]));
    assert_eq!(value["data"]["script_password"], false);
    assert_eq!(value["data"]["ssh_setup_pending"], false);
    assert_eq!(value["data"]["subscription_host"], serde_json::Value::Null);
    assert!(!data.exists(), "status created the absent data directory");
}

#[cfg(unix)]
#[test]
fn secure_files_are_private() {
    use std::os::unix::fs::PermissionsExt;
    let dir = TestDir::new();
    let private = dir.0.join("private");
    secure_fs::create_dir_all(&private).unwrap();
    let secret = private.join("secret.key");
    drop(secure_fs::create_new(&secret).unwrap());
    assert_eq!(fs::metadata(&private).unwrap().permissions().mode() & 0o077, 0);
    assert_eq!(fs::metadata(&secret).unwrap().permissions().mode() & 0o077, 0);
    secure_fs::atomic_write(&secret, b"replacement").unwrap();
    assert_eq!(fs::metadata(&secret).unwrap().permissions().mode() & 0o077, 0);
}

#[test]
fn concurrent_secret_writers_preserve_each_others_values() {
    let dir = TestDir::new();
    let mut first = spawn_worker("secret-first", &dir.0);
    let mut second = spawn_worker("secret-second", &dir.0);
    wait_success(&mut first);
    wait_success(&mut second);
    let store = State::new(StatePaths::new(&dir.0)).secret_store();
    for (digit, expected) in [('1', "first"), ('2', "second")] {
        let id = format!("node:{}:ssh-password", digit.to_string().repeat(32));
        assert_eq!(store.get(&id).unwrap().as_deref().map(String::as_str), Some(expected));
    }
}

#[test]
fn protected_status_fails_closed_without_mutating_state() {
    let dir = TestDir::new();
    let paths = StatePaths::new(dir.0.join("state"));
    State::new(paths.clone()).auth_store()
        .set(Zeroizing::new("never-echo-this-password".into())).unwrap();
    let auth_before = fs::read(paths.auth()).unwrap();
    let output = status_json(paths.root());
    assert_eq!(output.status.code(), Some(2));
    let envelope: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(envelope["ok"], false);
    assert_eq!(envelope["error"]["code"], "auth_required");
    assert!(!String::from_utf8_lossy(&output.stdout).contains("never-echo-this-password"));
    assert!(output.stderr.is_empty());
    assert_eq!(fs::read(paths.auth()).unwrap(), auth_before);
    assert!(!paths.config().exists());
    assert!(!paths.secret_key().exists());
    assert!(!paths.root().join(".rc-lock").exists());
}

#[test]
fn invalid_state_status_reports_error_without_repairing_user_data() {
    let dir = TestDir::new();
    let malformed = b"{\"schema_version\":2,\"nodes\":\"malformed\"}";
    fs::write(dir.0.join("config.json"), malformed).unwrap();
    let output = status_json(&dir.0);
    assert_eq!(output.status.code(), Some(1));
    let envelope: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(envelope["ok"], false);
    assert_eq!(envelope["error"]["code"], "invalid");
    assert!(output.stderr.is_empty());
    assert_eq!(fs::read(dir.0.join("config.json")).unwrap(), malformed);
    assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 1);
}

#[cfg(unix)]
#[test]
fn private_directory_creation_handles_umask_and_current_directory() {
    use std::os::unix::fs::PermissionsExt;
    let dir = TestDir::new();
    let mut worker = spawn_worker("restrictive-umask", &dir.0);
    wait_success(&mut worker);
    fs::set_permissions(&dir.0, fs::Permissions::from_mode(0o755)).unwrap();
    let mut worker = spawn_worker("tighten-cwd", &dir.0);
    wait_success(&mut worker);
    assert_eq!(fs::metadata(&dir.0).unwrap().permissions().mode() & 0o777, 0o700);
}
