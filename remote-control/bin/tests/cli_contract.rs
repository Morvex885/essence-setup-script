//! Процесс-интеграционные тесты контракта: бинарник `essence-rc`
//! запускается как реальный процесс (разовый CLI через демон по требованию
//! и сам демон `daemon run`).
//!
//! Инварианты проверяются по контракту, а не по деталям реализации:
//! ровно одна JSON-строка на вызов в `--json`, коды выхода {0..4},
//! грамматика всего каталога A.1, подтверждение планом, пароль запуска,
//! секреты без утечек и протокол демона v3.
//!
//! Деструктивные команды (`self uninstall`) выполняются ТОЛЬКО на одноразовой
//! копии исполняемого файла — cargo-бинарник никогда не удаляется.

mod common;

use std::{
    collections::BTreeMap,
    fs,
    hash::{Hash, Hasher},
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::atomic::{AtomicU32, Ordering},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use proptest::prelude::*;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

const BIN: &str = env!("CARGO_BIN_EXE_essence-rc");
const VERSION_FILE: &str = include_str!("../../../VERSION");

fn version() -> &'static str {
    VERSION_FILE.trim()
}

// ─── Окружение теста ─────────────────────────────────────────────────────────

static DIR_COUNTER: AtomicU32 = AtomicU32::new(0);

/// Каталог теста лежит в CARGO_TARGET_TMPDIR — на одной файловой системе с
/// бинарником, поэтому одноразовые копии делаются hard-link'ом. Каталог
/// времени выполнения демона — свой у каждого теста.
struct TestEnv {
    root: PathBuf,
    runtime: tempfile::TempDir,
}

impl TestEnv {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let seq = DIR_COUNTER.fetch_add(1, Ordering::Relaxed);
        let base = PathBuf::from(env!("CARGO_TARGET_TMPDIR"));
        fs::create_dir_all(&base).expect("создать базовый каталог тестов");
        let root = base.join(format!("essence-rc-cli-contract-{}-{seq}-{nonce}", std::process::id()));
        fs::create_dir_all(root.join("home")).expect("создать HOME теста");
        Self { root, runtime: common::runtime_dir() }
    }

    /// Окружение процессов теста (демоны запускаются с ним же).
    fn ctx(&self) -> common::Ctx {
        let tools = self.root.join("no-tools");
        let _ = fs::create_dir_all(&tools);
        common::Ctx {
            data: self.data(),
            runtime: self.runtime.path().to_path_buf(),
            vars: vec![("HOME".into(), self.home().into()), ("PATH".into(), tools.into())],
        }
    }

    fn data(&self) -> PathBuf {
        self.root.join("data")
    }

    fn home(&self) -> PathBuf {
        self.root.join("home")
    }

    /// Одноразовая копия исполняемого файла для деструктивных команд.
    fn disposable_bin(&self) -> PathBuf {
        let dir = self.root.join("exe");
        fs::create_dir_all(&dir).expect("создать каталог для копии бинарника");
        let name = if cfg!(windows) { "essence-rc.exe" } else { "essence-rc" };
        let path = dir.join(name);
        if path.exists() {
            fs::remove_file(&path).expect("убрать старую копию бинарника");
        }
        if fs::hard_link(BIN, &path).is_err() {
            fs::copy(BIN, &path).expect("скопировать бинарник в одноразовый каталог");
        }
        path
    }
}

impl Drop for TestEnv {
    fn drop(&mut self) {
        common::stop(&self.ctx().endpoint());
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// Путь бинарника: cargo-сборка (`BIN`) или одноразовая копия (`PathBuf`).
/// PATH указывает на пустой каталог: команды GitHub не достанут настоящие
/// `git`/`gh` и сеть (их сценарии — в `github_source`).
fn base_command(bin: impl AsRef<Path>, env: &TestEnv) -> Command {
    let mut cmd = env.ctx().command(bin);
    cmd.current_dir(&env.root);
    cmd
}

struct RunResult {
    code: Option<i32>,
    stdout: String,
    stderr: String,
    timed_out: bool,
}

fn exec(mut cmd: Command, stdin: Option<&str>, timeout: Duration) -> RunResult {
    cmd.stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().expect("запустить essence-rc");
    if let Some(text) = stdin {
        {
            let mut pipe = child.stdin.take().expect("stdin процесса");
            let _ = pipe.write_all(text.as_bytes());
        }
    }
    let mut stdout_pipe = child.stdout.take().expect("stdout процесса");
    let mut stderr_pipe = child.stderr.take().expect("stderr процесса");
    let stdout_reader = thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout_pipe.read_to_end(&mut buf);
        buf
    });
    let stderr_reader = thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stderr_pipe.read_to_end(&mut buf);
        buf
    });

    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait().expect("ожидание процесса") {
            break Some(status);
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        thread::sleep(Duration::from_millis(5));
    };

    let stdout = stdout_reader
        .join()
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default();
    let stderr = stderr_reader
        .join()
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default();
    RunResult { code: status.and_then(|s| s.code()), stdout, stderr, timed_out: status.is_none() }
}

/// Разовый вызов; возвращается после выхода его демона по требованию.
fn run(bin: impl AsRef<Path>, env: &TestEnv, args: &[&str], stdin: Option<&str>, timeout: Duration) -> RunResult {
    let mut cmd = base_command(bin, env);
    cmd.args(args);
    let result = exec(cmd, stdin, timeout);
    env.ctx().settle();
    result
}

/// Вызов с гарантией --json: ответ обязан быть ровно одной JSON-строкой.
fn run_json(bin: impl AsRef<Path>, env: &TestEnv, args: &[&str], stdin: Option<&str>) -> RunResult {
    let mut all: Vec<&str> = args.to_vec();
    if !all.contains(&"--json") {
        all.push("--json");
    }
    let result = run(bin, env, &all, stdin, Duration::from_secs(30));
    assert!(!result.timed_out, "команда {:?} зависла", args);
    result
}

/// Секреты разового вызова — только через `--secrets-stdin` (JSON на stdin).
fn run_secrets(bin: impl AsRef<Path>, env: &TestEnv, args: &[&str], secrets: &str) -> RunResult {
    let mut all: Vec<&str> = args.to_vec();
    all.push("--secrets-stdin");
    run_json(bin, env, &all, Some(secrets))
}

// ─── Разбор ответов ──────────────────────────────────────────────────────────

/// В `--json` stdout — ровно одна строка, и это валидный JSON-объект.
fn envelope(result: &RunResult) -> Value {
    assert!(!result.timed_out, "процесс завис");
    let trimmed = result.stdout.trim_end_matches('\n');
    assert!(
        !trimmed.is_empty() && !trimmed.contains('\n'),
        "ожидалась ровно одна JSON-строка, получено: {:?}",
        result.stdout
    );
    serde_json::from_str(trimmed).expect("строка stdout — валидный JSON")
}

fn error_code(value: &Value) -> &str {
    value["error"]["code"]
        .as_str()
        .unwrap_or_else(|| panic!("в ошибке нет поля error.code: {value}"))
}

fn assert_error(result: &RunResult, code: &str, exit: i32) -> Value {
    let value = envelope(result);
    assert_eq!(result.code, Some(exit), "код выхода для {code}: stdout={}", result.stdout);
    assert_eq!(value["ok"], json!(false), "ok=false: {value}");
    assert_eq!(error_code(&value), code, "тело: {value}");
    assert!(
        value["error"]["message"].as_str().is_some_and(|m| !m.is_empty()),
        "у ошибки есть непустое сообщение: {value}"
    );
    assert!(value.get("data").is_none(), "в ошибке нет data: {value}");
    value
}

fn assert_ok(result: &RunResult) -> Value {
    let value = envelope(result);
    assert_eq!(result.code, Some(0), "успех даёт выход 0: {value}");
    assert_eq!(value["ok"], json!(true), "ok=true: {value}");
    assert!(value.get("error").is_none(), "в успехе нет error: {value}");
    assert!(value.get("data").is_some(), "в успехе есть data: {value}");
    assert!(
        value.get("id").is_none_or(Value::is_null),
        "id одиночного вызова — null: {value}"
    );
    value
}

// ─── Снимки состояния и утечки ───────────────────────────────────────────────

fn snapshot(dir: &Path) -> BTreeMap<String, u64> {
    fn visit(base: &Path, rel: &Path, out: &mut BTreeMap<String, u64>) {
        let Ok(entries) = fs::read_dir(base.join(rel)) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            let sub = rel.join(entry.file_name());
            if path.is_dir() {
                visit(base, &sub, out);
            } else {
                let mut hasher = std::collections::hash_map::DefaultHasher::new();
                match fs::read(&path) {
                    Ok(bytes) => bytes.hash(&mut hasher),
                    Err(_) => hasher.write_u8(0),
                }
                sub.to_string_lossy().hash(&mut hasher);
                out.insert(sub.to_string_lossy().into_owned(), hasher.finish());
            }
        }
    }
    let mut out = BTreeMap::new();
    visit(dir, Path::new(""), &mut out);
    out
}

fn assert_state_unchanged(env: &TestEnv, before: &BTreeMap<String, u64>) {
    let after = snapshot(&env.data());
    assert_eq!(before, &after, "состояние не должно меняться при отказе");
}

/// Секрет не встречается ни в выводе процесса, ни в файлах состояния.
fn assert_no_leak(env: &TestEnv, result: &RunResult, secret: &str) {
    assert!(!result.stdout.contains(secret), "утечка секрета в stdout: {:?}", result.stdout);
    assert!(!result.stderr.contains(secret), "утечка секрета в stderr: {:?}", result.stderr);
    assert_dir_has_no_bytes(&env.data(), secret.as_bytes());
}

fn assert_dir_has_no_bytes(dir: &Path, needle: &[u8]) {
    fn visit(dir: &Path, needle: &[u8]) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                visit(&path, needle);
            } else if let Ok(bytes) = fs::read(&path) {
                assert!(
                    !bytes.windows(needle.len().max(1)).any(|w| w == needle),
                    "утечка секрета в файле {}",
                    path.display()
                );
            }
        }
    }
    visit(dir, needle);
}

/// Файлы с PHC-хешем argon2 (пароль запуска установлен).
fn argon_files(dir: &Path) -> Vec<PathBuf> {
    fn visit(dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                visit(&path, out);
            } else if let Ok(bytes) = fs::read(&path) {
                if bytes.starts_with(b"$argon2") {
                    out.push(path);
                }
            }
        }
    }
    let mut out = Vec::new();
    visit(dir, &mut out);
    out
}

fn has_cyrillic(text: &str) -> bool {
    text.chars().any(|c| ('А'..='я').contains(&c) || c == 'Ё' || c == 'ё')
}

// ─── Независимое вычисление токена плана ─────────────────────────────────────

/// Первые 16 hex SHA-256 от scope + '\n' + каждая строка плана + '\n' + extra.
fn plan_token_16hex(scope: &str, plan_lines: &[Value], extra: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.as_bytes());
    hasher.update(b"\n");
    for line in plan_lines {
        hasher.update(line.as_str().unwrap_or_default().as_bytes());
        hasher.update(b"\n");
    }
    hasher.update(extra.as_bytes());
    let digest = hasher.finalize();
    digest.iter().take(8).map(|b| format!("{b:02x}")).collect()
}

/// Область плана: «noun verb», затем исходные аргументы без --yes/--json/
/// --plan-token[=T] (значение флага тоже пропускается).
fn confirm_scope_variants(noun: &str, verb: &str, rest: &[&str]) -> Vec<String> {
    let mut kept: Vec<&str> = Vec::new();
    let mut skip = false;
    for arg in rest {
        if skip {
            skip = false;
            continue;
        }
        if *arg == "--yes" || *arg == "--json" || arg.starts_with("--plan-token=") {
            continue;
        }
        if *arg == "--plan-token" {
            skip = true;
            continue;
        }
        kept.push(arg);
    }
    // Контракт не фиксирует, входят ли позиционные noun/verb в повторный обход
    // argv; проверяем обе формы области.
    let mut head_only = format!("{noun} {verb}");
    let mut with_positionals = format!("{noun} {verb}\n{noun}\n{verb}");
    for arg in &kept {
        head_only.push('\n');
        head_only.push_str(arg);
        with_positionals.push('\n');
        with_positionals.push_str(arg);
    }
    vec![head_only, with_positionals]
}

/// Пароль запуска принадлежит созданной конфигурации: сначала source init-local.
fn install_script_password(env: &TestEnv, bin: impl AsRef<Path>, password: &str) {
    assert_ok(&run_json(&bin, env, &["source", "init-local"], None));
    let stdin = json!({"password": password}).to_string();
    let result = run_secrets(bin, env, &["self", "password-set"], &stdin);
    let value = assert_ok(&result);
    assert_eq!(value["data"]["password_set"], json!(true));
    assert_no_leak(env, &result, password);
    assert_eq!(
        argon_files(&env.data()).len(),
        1,
        "после установки пароля в состоянии ровно один PHC-файл"
    );
}

// ─── Версия и справка ────────────────────────────────────────────────────────

#[test]
fn version_flags_print_name_and_repo_version() {
    let env = TestEnv::new();
    for flag in ["--version", "-V"] {
        let result = run(BIN, &env, &[flag], None, Duration::from_secs(20));
        assert_eq!(result.code, Some(0), "флаг {flag} даёт выход 0");
        assert_eq!(result.stdout, format!("essence-rc {}\n", version()), "формат: essence-rc VERSION");
    }
}

#[test]
fn help_is_russian_text_without_args_and_with_help_flags() {
    let env = TestEnv::new();
    for args in [&[] as &[&str], &["help"], &["--help"], &["-h"]] {
        let result = run(BIN, &env, args, None, Duration::from_secs(20));
        assert_eq!(result.code, Some(0), "справка {:?} даёт выход 0", args);
        assert!(!result.stdout.trim().is_empty(), "справка не пуста для {:?}", args);
        assert!(!result.stdout.trim_start().starts_with('{'), "текстовая справка — не JSON");
        assert!(has_cyrillic(&result.stdout), "тексты справки — русские для {:?}", args);
    }
    let result = run(BIN, &env, &["help"], None, Duration::from_secs(20));
    assert!(result.stdout.contains("node add"), "в справке есть каталог команд");
    assert!(result.stdout.contains("session open"), "в справке есть session open");
}

/// Каталог A.1 целиком: каждая команда из v1 (с заменой sub→subscription)
/// присутствует в данных help.
#[test]
fn help_json_lists_whole_v2_catalog() {
    let env = TestEnv::new();
    let result = run_json(BIN, &env, &["help"], None);
    let value = assert_ok(&result);
    let commands = value["data"]["commands"].as_array().expect("help.data.commands — массив");
    assert!(!commands.is_empty(), "каталог не пуст");
    let catalog = [
        "help",
        "status",
        "session status",
        "session open",
        "source init-local",
        "source status",
        "source github-accounts",
        "source github-login",
        "source github-connect",
        "source github-change-account",
        "source github-rewrap-password",
        "source github-rotate-key",
        "source github-import-recovery-key",
        "source github-fetch",
        "source github-push",
        "source github-switch-local",
        "source github-delete-repo",
        "source github-replace-with-local",
        "source github-migrate-format",
        "self version",
        "self update",
        "self uninstall",
        "self password-set",
        "self password-remove",
        "daemon status",
        "daemon stop",
        "daemon run",
        "daemon start",
        "node list",
        "node show",
        "node aliases",
        "node rename",
        "node tag",
        "node password",
        "node add",
        "node trust-host-key",
        "node delete",
        "node check",
        "node upload-scripts",
        "node harden",
        "node setup-ssh",
        "node shell",
        "conn list",
        "conn set",
        "conn sync",
        "awg status",
        "awg sync",
        "awg remove",
        "telegram status",
        "telegram install",
        "telegram refresh-ip",
        "telegram web-update",
        "telegram web-restart",
        "telegram backend-restart",
        "telegram remove",
        "telegram remove-all",
        "telegram menu",
        "group list",
        "group add",
        "group delete",
        "group set-template",
        "template list",
        "template show",
        "template create",
        "template export",
        "template import",
        "client list",
        "client show",
        "client config",
        "client connections",
        "client add",
        "client rename",
        "client nodes",
        "client set-group",
        "client delete",
        "generate",
        "subscription host",
        "subscription list",
        "subscription show",
        "subscription headers",
        "subscription publish",
        "subscription publish-all",
        "subscription rotate",
        "subscription revoke",
        "subscription migrate",
    ];
    for prefix in catalog {
        assert!(
            commands
                .iter()
                .any(|c| c["usage"].as_str().is_some_and(|u| u.starts_with(prefix))),
            "в каталоге help нет команды {prefix}"
        );
    }
    assert!(
        !commands
            .iter()
            .any(|c| c["usage"].as_str().is_some_and(|u| u.starts_with("sub "))),
        "существительное v1 «sub» переименовано в subscription"
    );
    // help по существительному — только его команды.
    let result = run_json(BIN, &env, &["help", "node"], None);
    let value = assert_ok(&result);
    let commands = value["data"]["commands"].as_array().expect("help node — массив");
    assert!(!commands.is_empty());
    assert!(
        commands
            .iter()
            .all(|c| c["usage"].as_str().is_some_and(|u| u.starts_with("node "))),
        "help node содержит только команды node"
    );
    // help по неизвестному существительному — usage.
    let result = run_json(BIN, &env, &["help", "bogus"], None);
    assert_error(&result, "usage", 2);
}

// ─── Грамматика каталога ─────────────────────────────────────────────────────

/// Представитель каждой команды каталога с валидными флагами: грамматика
/// принята (ответ не usage), код выхода в {0..4}. Выполняется на одноразовой
/// копии бинарника.
#[test]
fn catalog_grammar_is_accepted_for_every_command() {
    let env = TestEnv::new();
    let bin = env.disposable_bin();
    let rows: &[&[&str]] = &[
        &["status"],
        &["session", "status"],
        &["session", "open"],
        &["session", "open", "--remember-key"],
        &["source", "init-local"],
        &["source", "status"],
        &["source", "github-accounts"],
        &["source", "github-login", "--login", "owner"],
        &["source", "github-connect", "--login", "owner", "--create-repo", "--make-private", "--storage", "age", "--existing", "remote", "--provision-keys", "yes", "--remember-key"],
        &["source", "github-change-account", "--login", "owner", "--create-repo", "--make-private", "--storage", "none", "--existing", "local", "--without-cache", "--replace-target"],
        &["source", "github-rewrap-password"],
        &["source", "github-rotate-key"],
        &["source", "github-import-recovery-key", "--file", "recovery.age"],
        &["source", "github-fetch"],
        &["source", "github-push"],
        &["source", "github-switch-local"],
        &["source", "github-delete-repo"],
        &["source", "github-replace-with-local", "--provision-keys", "yes"],
        &["source", "github-migrate-format"],
        &["self", "password-set"],
        &["self", "password-remove"],
        &["self", "uninstall", "--remove-data"],
        &["node", "list"],
        &["node", "show", "--name", "n1"],
        &["node", "aliases", "--name", "n1", "--set", "a=1", "--set", "b=2", "--unset", "c"],
        &["node", "rename", "--name", "n1", "--new-name", "n2"],
        &["node", "tag", "--name", "n1", "--tag", "prod"],
        &["node", "tag", "--name", "n1", "--tag", ""],
        &["node", "password", "--name", "n1"],
        // Флаги осмысленны: команды шага 6 проверяют сочетания (а не только грамматику).
        &["node", "add", "--name", "n1", "--ip", "127.0.0.1", "--port", "22", "--user", "root", "--auth", "key", "--tag", "t", "--host-key", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"],
        &["node", "add", "--name", "n2", "--ip", "127.0.0.1", "--port", "22022", "--user", "ubuntu", "--auth", "key", "--tag", "t", "--accept-new-host-key"],
        &["node", "trust-host-key", "--name", "n1", "--host-key", "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"],
        &["node", "delete", "--name", "n1", "--scope", "server", "--revoke-key"],
        &["node", "check", "--name", "n1"],
        &["node", "upload-scripts", "--name", "n1", "--force"],
        &["node", "harden", "--name", "n1", "--port", "22"],
        &["node", "setup-ssh", "--provision-keys", "yes", "--on-failure", "rollback"],
        &["node", "shell", "--name", "n1"],
        &["conn", "list"],
        &["conn", "list", "--name", "n1", "--discover"],
        &["conn", "set", "--name", "n1", "--group", "G1", "--group", "G2", "--proxy", "p1", "--proxy", "p2"],
        &["conn", "sync", "--name", "n1"],
        &["awg", "status", "--name", "n1"],
        &["awg", "sync", "--name", "n1"],
        &["awg", "remove", "--name", "n1", "--peer", "p1", "--peer", "p2"],
        &["awg", "remove", "--name", "n1", "--orphans"],
        &["telegram", "status", "--name", "n1", "--name", "n2"],
        &["telegram", "status", "--all"],
        &["telegram", "install", "--name", "n1"],
        &["telegram", "refresh-ip", "--name", "n1"],
        &["telegram", "web-update", "--name", "n1"],
        &["telegram", "web-restart", "--name", "n1"],
        &["telegram", "backend-restart", "--name", "n1"],
        &["telegram", "remove", "--name", "n1", "--component", "web"],
        &["telegram", "remove-all", "--all"],
        &["telegram", "menu", "--name", "n1"],
        &["group", "list"],
        &["group", "add", "--name", "lab"],
        &["group", "delete", "--name", "LAB"],
        &["group", "set-template", "--name", "LAB", "--template", "default.yaml"],
        &["template", "list"],
        &["template", "show", "--name", "default"],
        &["template", "create", "--name", "t1", "--from", "default", "--group", "G1"],
        &["daemon", "status"],
        &["template", "import", "--name", "t2", "--file", "in.yaml"],
        &["client", "list"],
        &["client", "list", "--group", "G1"],
        &["client", "show", "--name", "c1"],
        &["client", "config", "--name", "c1"],
        &["client", "connections", "--name", "c1", "--node", "n1", "--proxy", "p1"],
        &["client", "connections", "--name", "c1", "--node", "n1", "--reset"],
        &["client", "add", "--name", "c1", "--group", "G1"],
        &["client", "rename", "--name", "c1", "--new-name", "c2"],
        &["client", "nodes", "--name", "c1", "--node", "n1", "--node", "n2"],
        &["client", "nodes", "--name", "c1", "--inherit"],
        &["client", "set-group", "--name", "c1", "--group", "G2"],
        &["client", "delete", "--name", "c1", "--name", "c2"],
        &["generate", "--all"],
        &["generate", "--group", "G1"],
        &["generate", "--client", "c1"],
        &["subscription", "host", "--name", "n1"],
        &["subscription", "list"],
        &["subscription", "show", "--name", "c1"],
        &["subscription", "headers", "--client", "c1", "--set", "X=1", "--unset", "Y"],
        &["subscription", "headers", "--group", "G1"],
        &["subscription", "headers", "--default"],
        &["subscription", "publish", "--name", "c1", "--ttl", "30d"],
        &["subscription", "publish-all"],
        &["subscription", "rotate", "--name", "c1"],
        &["subscription", "revoke", "--name", "c1"],
        &["subscription", "migrate", "--name", "n1"],
        &["--json", "status"],
    ];
    for row in rows {
        let result = run_json(&bin, &env, row, None);
        let value = envelope(&result);
        if value["ok"] == json!(false) {
            let code = error_code(&value);
            assert_ne!(code, "usage", "грамматика {:?} должна приниматься, получен usage", row);
            assert_ne!(code, "not_ready", "{row:?}: каталог перенесён целиком");
        }
        assert!(
            matches!(result.code, Some(0 | 1 | 2 | 3 | 4)),
            "код выхода {{0..4}} для {:?}, получен {:?}",
            row,
            result.code
        );
    }

    // Сетевые команды: метаданные могут быть недоступны на стенде без сети,
    // но грамматика и конверт обязаны работать.
    for row in [["self", "version"], ["self", "update"]] {
        let mut args: Vec<&str> = row.to_vec();
        args.push("--json");
        let result = run(&bin, &env, &args, None, Duration::from_secs(90));
        if result.timed_out {
            continue; // изолированная сеть стенда: пропуск
        }
        let value = envelope(&result);
        if value["ok"] == json!(false) {
            assert_ne!(error_code(&value), "usage", "грамматика {args:?} принята");
        }
        assert!(matches!(result.code, Some(0 | 1 | 2 | 3 | 4)));
    }
}

/// Явные нарушения грамматики — usage с выходом 2, ровно одна строка JSON,
/// состояние не меняется.
#[test]
fn grammar_violations_are_usage_errors() {
    let env = TestEnv::new();
    let rows: &[(&[&str], Option<&str>)] = &[
        (&["foo"], None),
        (&["foo", "bar"], None),
        (&["node", "frobnicate"], None),
        (&["node", "list", "--bogus"], None),
        (&["node", "list", "extra-positional"], None),
        (&["node", "add", "--name", "a", "--name", "b"], None),
        (&["node", "add", "--name", "a\nb"], None),
        (&["node", "tag", "--name", "n", "--tag", "x\ny"], None),
        (&["--plan-token", "feedfacefeedface", "status"], None),
        (&["status", "--plan-token=feedfacefeedface"], None),
        (&["--secrets-stdin", "group", "list"], Some("{\"current-password\":\"x\"}")),
        (&["group", "list", "--secrets-stdin"], Some("{\"password\":\"x\"}")),
        (&["self", "password-set", "--secrets-stdin"], Some("{]")),
        (&["self", "password-set", "--secrets-stdin"], Some("[]")),
        (&["self", "password-set", "--secrets-stdin"], Some("{\"password\": 7}")),
        (&["self", "password-set", "--secrets-stdin"], Some("{\"bogus-secret\":\"x\"}")),
        (&["node", "password", "--name", "n", "--password", "secret-value"], None),
        (&["client", "delete", "--name", "c", "--plan-token", "feedfacefeedface"], None),
        // v2: `--name` — единый селектор; прежние формы v1 не принимаются.
        (&["conn", "sync", "--node", "n1"], None),
        (&["subscription", "show", "--client", "c1"], None),
        (&["sub", "list"], None),
    ];
    let before = snapshot(&env.data());
    for (row, stdin) in rows {
        let result = run_json(BIN, &env, row, *stdin);
        assert_error(&result, "usage", 2);
        assert_state_unchanged(&env, &before);
    }

    // Без --json та же ошибка не печатает JSON-конверт в stdout.
    let result = run(BIN, &env, &["foo"], None, Duration::from_secs(20));
    assert_eq!(result.code, Some(2));
    assert!(
        !result.stdout.trim_start().starts_with('{'),
        "без --json ошибки не JSON: {:?}",
        result.stdout
    );

    // Глобальный флаг перед существительным тоже разбирается.
    let result = run_json(BIN, &env, &["--json", "foo"], None);
    assert_error(&result, "usage", 2);
}

// ─── Одиночный вызов: конверт и статусы ──────────────────────────────────────

#[test]
fn unknown_commands_do_not_report_success() {
    let output = Command::new(env!("CARGO_BIN_EXE_essence-rc"))
        .arg("__invalid_command")
        .output()
        .expect("run unsupported command");

    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
}

#[test]
fn status_on_absent_state_keeps_step2_success_behavior() {
    let env = TestEnv::new();
    let result = run_json(BIN, &env, &["status"], None);
    let value = assert_ok(&result);
    assert_eq!(value["data"]["version"], json!(version()), "status отдаёт версию бинарника");
    assert_eq!(value["data"]["counts"]["nodes"], json!(0));
    assert_eq!(value["data"]["counts"]["groups"], json!(3), "начальный снимок: ROUTER, PC, MOBILE");
    assert_eq!(value["data"]["counts"]["clients"], json!(0));

    // Человекочитаемый статус — русский текст, не JSON.
    let result = run(BIN, &env, &["status"], None, Duration::from_secs(20));
    assert_eq!(result.code, Some(0));
    assert!(has_cyrillic(&result.stdout), "статус без --json на русском: {:?}", result.stdout);
    assert!(!result.stdout.trim_start().starts_with('{'));
}

#[test]
fn session_status_works_without_session() {
    let env = TestEnv::new();
    let result = run_json(BIN, &env, &["session", "status"], None);
    assert_ok(&result);
}

/// Весь каталог перенесён: списки работают на свежей установке, не создавая
/// каталог данных.
#[test]
fn read_only_lists_work_on_a_fresh_install() {
    let env = TestEnv::new();
    for row in [
        &["template", "list"][..],
        &["client", "list"][..],
        &["group", "list"][..],
        &["subscription", "list"][..],
        &["node", "list"][..],
    ] {
        let result = run_json(BIN, &env, row, None);
        let value = envelope(&result);
        assert_eq!((value["ok"].clone(), result.code), (json!(true), Some(0)), "{row:?}: {value}");
    }
    assert!(!env.data().exists(), "списки не создают каталог данных");
}

// ─── Пароль запуска: гейт, смена, отказы ─────────────────────────────────────

#[test]
fn script_password_gates_session_until_secret_supplied() {
    let env = TestEnv::new();

    // До установки пароля статус доступен (step2-поведение пустого каталога).
    assert_ok(&run_json(BIN, &env, &["status"], None));

    // Установка пароля секретом из stdin.
    let result = run_secrets(BIN, &env, &["self", "password-set"], "{\"password\":\"alpha-secret-1\"}");
    assert_ok(&result);
    assert_no_leak(&env, &result, "alpha-secret-1");
    assert_eq!(argon_files(&env.data()).len(), 1, "PHC-хеш записан");

    // Без секрета сессия не открывается — состояние не меняется.
    let result = run_json(BIN, &env, &["status"], None);
    assert_error(&result, "auth_required", 2);

    // Секрет script-password открывает локальную сессию одиночного вызова.
    let result = run_secrets(BIN, &env, &["status"], "{\"script-password\":\"alpha-secret-1\"}");
    assert_ok(&result);
    assert_no_leak(&env, &result, "alpha-secret-1");

    // Неверный пароль — отказ, состояние не меняется.
    let guarded = snapshot(&env.data());
    let result = run_secrets(BIN, &env, &["status"], "{\"script-password\":\"wrong-password\"}");
    assert_error(&result, "auth_failed", 1);
    assert_state_unchanged(&env, &guarded);

    // Пустой и многострочный пароли отвергаются: с установленным паролем
    // смена требует current-password и открытую сессию.
    for bad in ["", "line1\nline2", "\nlead", "trail\n"] {
        let stdin = json!({"password": bad, "current-password": "alpha-secret-1", "script-password": "alpha-secret-1"}).to_string();
        let result = run_secrets(BIN, &env, &["self", "password-set"], &stdin);
        assert_error(&result, "invalid", 1);
        assert_state_unchanged(&env, &guarded);
        assert!(!result.stdout.contains("alpha-secret-1"));
    }

    // Смена пароля: нужен и session (script-password), и current-password.
    let stdin = json!({"password": "beta-secret-2", "current-password": "alpha-secret-1", "script-password": "alpha-secret-1"}).to_string();
    let result = run_secrets(BIN, &env, &["self", "password-set"], &stdin);
    assert_ok(&result);
    assert_no_leak(&env, &result, "alpha-secret-1");
    assert_no_leak(&env, &result, "beta-secret-2");

    // Старый пароль больше не работает, новый — работает.
    let result = run_secrets(BIN, &env, &["status"], "{\"script-password\":\"alpha-secret-1\"}");
    assert_error(&result, "auth_failed", 1);
    let result = run_secrets(BIN, &env, &["status"], "{\"script-password\":\"beta-secret-2\"}");
    assert_ok(&result);
    assert_no_leak(&env, &result, "beta-secret-2");

    // Неверный current-password не меняет пароль.
    let guarded = snapshot(&env.data());
    let stdin = json!({"password": "gamma-secret-3", "current-password": "wrong", "script-password": "beta-secret-2"}).to_string();
    let result = run_secrets(BIN, &env, &["self", "password-set"], &stdin);
    assert_error(&result, "auth_failed", 1);
    assert_state_unchanged(&env, &guarded);
    let result = run_secrets(BIN, &env, &["status"], "{\"script-password\":\"beta-secret-2\"}");
    assert_ok(&result);
}

// ─── Подтверждение планом ────────────────────────────────────────────────────

#[test]
fn password_remove_confirmation_lifecycle_honors_plan_token() {
    let env = TestEnv::new();
    const PW: &str = "confirm-pass-9";
    install_script_password(&env, BIN, PW);
    let secrets = json!({"current-password": PW, "script-password": PW}).to_string();
    let guarded = snapshot(&env.data());

    // 1. Без --yes — confirmation_required с планом и токеном.
    let result = run_secrets(BIN, &env, &["self", "password-remove"], &secrets);
    let first = assert_error(&result, "confirmation_required", 2);
    let plan = first["error"]["plan"].as_array().expect("план — массив строк").clone();
    assert!(!plan.is_empty(), "план не пуст: {first}");
    assert!(plan.iter().all(|l| l.is_string()), "строки плана — строки: {plan:?}");
    let token = first["error"]["plan_token"].as_str().expect("plan_token — строка").to_string();
    assert!(
        token.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
        "токен — 16 hex: {token}"
    );
    assert_eq!(token.len(), 16, "токен — первые 16 hex: {token}");
    assert_state_unchanged(&env, &guarded);
    assert_eq!(argon_files(&env.data()).len(), 1, "пароль не удалён без согласия");

    // 2. Токен воспроизводим и не зависит от --json (область его исключает).
    let result = run_secrets(BIN, &env, &["self", "password-remove"], &secrets);
    let second = assert_error(&result, "confirmation_required", 2);
    assert_eq!(second["error"]["plan_token"], json!(token), "токен стабилен между вызовами");

    // 3. Независимое вычисление: SHA-256(scope + строки плана + extra)[:16hex].
    let candidates: Vec<String> = confirm_scope_variants("self", "password-remove", &[])
        .iter()
        .map(|scope| plan_token_16hex(scope, &plan, ""))
        .collect();
    assert!(
        candidates.contains(&token),
        "токен {token} совпадает с независимым вычислением из {candidates:?} (план {plan:?})"
    );

    // 4. stdin «y» — не согласие и не секрет: отказ без мутаций.
    // Без --secrets-stdin stdin вообще не читается: команда отказывает
    // (нужен current-password), ничего не подтверждая.
    let result = run_json(BIN, &env, &["self", "password-remove"], Some("y\n"));
    let value = envelope(&result);
    assert_eq!(value["ok"], json!(false), "ввод y ничего не подтверждает: {value}");
    assert_ne!(error_code(&value), "plan_changed");
    assert_state_unchanged(&env, &guarded);

    // 5. --yes с чужим токеном — plan_changed с тем же настоящим токеном.
    let result = run_secrets(BIN, &env, &["self", "password-remove", "--yes", "--plan-token", "0000000000000000"], &secrets);
    let changed = assert_error(&result, "plan_changed", 2);
    assert_eq!(changed["error"]["plan_token"], json!(token));
    assert_state_unchanged(&env, &guarded);

    // 6. --plan-token без --yes — usage.
    let result = run_secrets(BIN, &env, &["self", "password-remove", "--plan-token", &token], &secrets);
    assert_error(&result, "usage", 2);
    assert_state_unchanged(&env, &guarded);

    // 7. --yes --plan-token <настоящий> — удаление (область исключает
    //    --yes/--plan-token/--json, поэтому токен от отказа остаётся верен).
    let result = run_secrets(BIN, &env, &["self", "password-remove", "--yes", "--plan-token", &token], &secrets);
    let done = assert_ok(&result);
    assert_eq!(done["data"]["password_set"], json!(false));
    assert!(argon_files(&env.data()).is_empty(), "PHC-хеш удалён");

    // После удаления статус снова доступен без секрета.
    let result = run_json(BIN, &env, &["status"], None);
    assert_ok(&result);
}

#[test]
fn password_remove_checks_secret_before_consent() {
    let env = TestEnv::new();
    const PW: &str = "bare-yes-pass-4";
    install_script_password(&env, BIN, PW);
    let secrets = json!({"current-password": PW, "script-password": PW}).to_string();

    let result = run_secrets(BIN, &env, &["self", "password-remove"], &secrets);
    let refusal = assert_error(&result, "confirmation_required", 2);
    let token = refusal["error"]["plan_token"].as_str().unwrap().to_string();
    assert_eq!(token.len(), 16);

    // --yes с неверным текущим паролем не удаляет (секрет проверяется раньше).
    let wrong = json!({"current-password": "nope", "script-password": PW}).to_string();
    let result = run_secrets(BIN, &env, &["self", "password-remove", "--yes"], &wrong);
    assert_error(&result, "auth_failed", 1);
    assert_eq!(argon_files(&env.data()).len(), 1, "пароль не удалён при неверном current-password");

    // --yes с верными секретами — согласие и без токена.
    let result = run_secrets(BIN, &env, &["self", "password-remove", "--yes"], &secrets);
    let done = assert_ok(&result);
    assert_eq!(done["data"]["password_set"], json!(false));
    assert!(argon_files(&env.data()).is_empty());
}

// ─── Демон: протокол v3 и журнал ─────────────────────────────────────────────

#[test]
fn daemon_protocol_hello_requests_and_disconnect() {
    let env = TestEnv::new();
    const PW: &str = "daemon-script-pass-7";
    install_script_password(&env, BIN, PW);
    let guarded = snapshot(&env.data());
    let daemon = common::Daemon::spawn(&env.ctx());
    assert_eq!(daemon.hello["event"], json!("hello"), "событие hello: {}", daemon.hello);
    assert_eq!(daemon.hello["protocol"], json!(3), "протокол v3: {}", daemon.hello);
    assert_eq!(daemon.hello["version"], json!(version()), "hello отдаёт версию: {}", daemon.hello);
    let mut conn = daemon.connect();
    let mut replies = Vec::new();
    let mut ask = |conn: &mut common::Raw, request: Value| -> Value {
        let id = request["id"].clone();
        conn.send(&request);
        let (_, reply) = conn.reply(id, Duration::from_secs(30));
        replies.push(reply.clone());
        reply
    };

    // Запрос до открытой сессии — отказ.
    let pre = ask(&mut conn, json!({"id": "pre", "argv": ["status", "--json"]}));
    assert_eq!((pre["ok"].clone(), error_code(&pre)), (json!(false), "session_closed"), "{pre}");
    // Неверный пароль при открытии — auth_failed, состояние не меняется.
    let wrong = ask(&mut conn, json!({"id": "wrong", "argv": ["session", "open", "--json"], "secrets": {"script-password": "definitely-wrong"}}));
    assert_eq!(error_code(&wrong), "auth_failed", "неверный пароль: {wrong}");
    assert_state_unchanged(&env, &guarded);
    let opened = ask(&mut conn, json!({"id": 1, "argv": ["session", "open", "--json"], "secrets": {"script-password": PW}}));
    assert_eq!((opened["id"].clone(), opened["ok"].clone()), (json!(1), json!(true)), "числовой id сохраняется числом: {opened}");
    // Авторизация соединения сохраняется.
    let after = ask(&mut conn, json!({"id": "after", "argv": ["status", "--json"]}));
    assert_eq!(after["ok"], json!(true), "{after}");
    let rm = ask(&mut conn, json!({"id": "rm", "argv": ["self", "password-remove", "--json"], "secrets": {"current-password": PW}}));
    assert_eq!(error_code(&rm), "confirmation_required", "план требуется и через демон: {rm}");
    assert_eq!(rm["exit"], json!(2));
    assert!(rm["error"]["plan_token"].as_str().is_some_and(|t| t.len() == 16));
    assert_state_unchanged(&env, &guarded);

    // Пустые строки пропускаются без ответа; «y» — мусор протокола, не согласие.
    conn.send_line("");
    assert!(conn.next(Duration::from_millis(400)).is_none(), "пустая строка без ответа");
    conn.send_line("y");
    let (_, y) = conn.reply(Value::Null, Duration::from_secs(20));
    assert_eq!(error_code(&y), "usage", "не-JSON запрос — usage: {y}");
    conn.send_line("{not json");
    let (_, bad) = conn.reply(Value::Null, Duration::from_secs(20));
    assert_eq!(error_code(&bad), "usage");
    assert_state_unchanged(&env, &guarded);
    let nul = ask(&mut conn, json!({"id": "nul", "argv": ["stat\u{0}us", "--json"]}));
    assert_eq!((nul["id"].clone(), error_code(&nul)), (json!("nul"), "usage"), "{nul}");
    let sec = ask(&mut conn, json!({"id": "sec", "argv": ["status", "--secrets-stdin"]}));
    assert_eq!(error_code(&sec), "usage");
    let unk = ask(&mut conn, json!({"id": "unk", "argv": ["self", "password-set", "--json"], "secrets": {"bogus": "v"}}));
    assert_eq!(error_code(&unk), "usage");
    for reply in replies.iter().chain([&y, &bad]) {
        assert_ne!(reply.get("data").is_some(), reply.get("error").is_some(), "ровно одно из data/error: {reply}");
        assert_eq!(reply.get("exit").is_some(), reply["ok"] == json!(false), "exit только у ошибки: {reply}");
    }
    // Ровно один ответ на запрос: лишних сообщений нет.
    assert!(conn.next(Duration::from_millis(500)).is_none(), "лишнее сообщение после всех ответов");
    conn.close();
    // Секрет не утёк ни в протокол, ни в журнал демона, ни в данные.
    assert!(!format!("{replies:?}{y}{bad}").contains(PW), "пароль не в ответах");
    assert!(!daemon.journal().contains(PW), "пароль не в журнале демона");
    assert_dir_has_no_bytes(&env.data(), PW.as_bytes());
}

/// Журнал команды: у демона — события `log` с id запроса строго до ответа; в
/// разовом CLI — строки с префиксами v1 в stderr (stdout — только конверт).
#[test]
fn command_journal_reaches_daemon_events_and_one_shot_stderr() {
    let env = TestEnv::new();
    const PW: &str = "journal-pass-5";
    assert_ok(&run_json(BIN, &env, &["source", "init-local"], None));
    let result = run_secrets(BIN, &env, &["self", "password-set"], &json!({"password": PW}).to_string());
    assert_ok(&result);
    assert!(result.stderr.contains("  [✓] Пароль сохранён"), "журнал в stderr: {:?}", result.stderr);
    assert_no_leak(&env, &result, PW);

    let daemon = common::Daemon::spawn(&env.ctx());
    let mut conn = daemon.connect();
    let (events, opened) = conn.request("open", &["session", "open"], json!({"script-password": PW}));
    assert_eq!(events, [json!({"id": "open", "event": "log", "level": "info", "text": "Сессия открыта: локальная конфигурация."})]);
    assert_eq!(opened["ok"], json!(true));
    conn.send(&json!({"id": 9, "argv": ["self", "password-remove", "--yes"], "secrets": {"current-password": PW}}));
    let (events, reply) = conn.reply(9, Duration::from_secs(30));
    assert_eq!(events, [json!({"id": 9, "event": "log", "level": "success", "text": "Пароль убран"})]);
    assert_eq!(reply["ok"], json!(true));
    conn.close();
    assert!(!daemon.journal().contains(PW));
}

// ─── Файлы на стороне клиента и конфиг клиента ───────────────────────────────

#[test]
fn template_import_reads_the_file_in_the_client() {
    let env = TestEnv::new();
    assert_ok(&run_json(BIN, &env, &["source", "init-local"], None));
    assert_ok(&run_json(BIN, &env, &["template", "create", "--name", "t1"], None));
    let file = env.root.join("in.yaml");
    fs::write(&file, "mode: rule\n").unwrap();
    let path = file.to_str().unwrap();
    let planned = run_json(BIN, &env, &["template", "import", "--name", "t1", "--file", path], None);
    let plan = assert_error(&planned, "confirmation_required", 2);
    assert_eq!(plan["error"]["plan"], json!(["Шаблон t1.yaml будет перезаписан."]));
    let imported = run_json(BIN, &env, &["template", "import", "--name", "t1", "--file", path, "--yes"], None);
    assert_eq!(assert_ok(&imported)["data"], json!({"name": "t1.yaml"}));
    let journal = fs::read_to_string(env.ctx().endpoint().log).unwrap_or_default();
    assert!(!journal.contains(path), "путь файла не доходит до демона: {journal}");
    let shown = assert_ok(&run_json(BIN, &env, &["template", "show", "--name", "t1"], None));
    assert_eq!(shown["data"]["content"], json!("mode: rule\n"));

    let missing = env.root.join("absent.yaml");
    let absent = run_json(BIN, &env, &["template", "import", "--name", "t1", "--file", missing.to_str().unwrap()], None);
    assert_error(&absent, "invalid", 1);
    let binary = env.root.join("bin.yaml");
    fs::write(&binary, [0xff, 0xfe]).unwrap();
    let not_utf8 = run_json(BIN, &env, &["template", "import", "--name", "t1", "--file", binary.to_str().unwrap()], None);
    assert_error(&not_utf8, "invalid", 1);
    let without = run_json(BIN, &env, &["template", "import", "--name", "t1"], None);
    let usage = assert_error(&without, "usage", 2);
    assert_eq!(usage["error"]["message"], json!("Укажите файл: --file PATH."));
}

#[test]
fn template_export_writes_the_file_and_requires_consent_to_overwrite() {
    let env = TestEnv::new();
    assert_ok(&run_json(BIN, &env, &["source", "init-local"], None));
    let shown = assert_ok(&run_json(BIN, &env, &["template", "show", "--name", "default"], None));
    let content = shown["data"]["content"].as_str().unwrap().to_owned();
    let target = env.root.join("out.yaml");
    let output = target.to_str().unwrap();
    let exported = assert_ok(&run_json(BIN, &env, &["template", "export", "--name", "default", "--output", output], None));
    assert_eq!(exported["data"], json!({"name": "default.yaml", "output": output}));
    assert_eq!(fs::read_to_string(&target).unwrap(), content);
    fs::write(&target, "IMPORTANT\n").unwrap();
    let planned = run_json(BIN, &env, &["template", "export", "--name", "default", "--output", output], None);
    let plan = assert_error(&planned, "confirmation_required", 2);
    assert_eq!(plan["error"]["plan"], json!([format!("Файл {output} будет перезаписан шаблоном default.yaml.")]));
    assert_eq!(fs::read_to_string(&target).unwrap(), "IMPORTANT\n");
    assert_ok(&run_json(BIN, &env, &["template", "export", "--name", "default", "--output", output, "--yes"], None));
    assert_eq!(fs::read_to_string(&target).unwrap(), content);
    let directory = run_json(BIN, &env, &["template", "export", "--name", "default", "--output", env.root.to_str().unwrap(), "--yes"], None);
    assert_error(&directory, "invalid", 1);
}

#[test]
fn client_config_returns_the_generated_content() {
    let env = TestEnv::new();
    assert_ok(&run_json(BIN, &env, &["source", "init-local"], None));
    assert_ok(&run_json(BIN, &env, &["client", "add", "--name", "c1", "--group", "PC"], None));
    let before = assert_ok(&run_json(BIN, &env, &["client", "config", "--name", "c1"], None));
    assert_eq!(before["data"], json!({"name": "c1", "group": "PC", "exists": false, "content": null}));
    let generated = run_json(BIN, &env, &["generate", "--client", "c1"], None);
    assert!(matches!(generated.code, Some(0 | 1)), "{}", generated.stdout);
    let after = assert_ok(&run_json(BIN, &env, &["client", "config", "--name", "c1"], None));
    let path = env.data().join("generated/PC/c1/config.yaml");
    assert_eq!(after["data"]["exists"], json!(path.is_file()), "{after}");
    if path.is_file() {
        assert_eq!(after["data"]["content"], json!(fs::read_to_string(&path).unwrap()));
    }
    assert_error(&run_json(BIN, &env, &["client", "config", "--name", "ghost"], None), "not_found", 1);
}

// ─── self uninstall: только одноразовая копия ────────────────────────────────

#[test]
fn uninstall_refusal_keeps_disposable_copy_and_state() {
    let env = TestEnv::new();
    let bin = env.disposable_bin();
    let before = snapshot(&env.data());

    // Без --yes — подтверждение (или root-гейт v1) без мутаций.
    let result = run_json(&bin, &env, &["self", "uninstall"], None);
    let value = envelope(&result);
    assert_eq!(value["ok"], json!(false), "без согласия удаления нет: {value}");
    assert!(
        ["confirmation_required", "root_required", "unsafe_path"].contains(&error_code(&value)),
        "код отказа удаления: {value}"
    );
    assert_eq!(result.code, Some(2));
    assert!(bin.exists(), "исполняемый файл не тронут без --yes");
    assert_state_unchanged(&env, &before);

    // Cargo-бинарник тем более на месте.
    assert!(Path::new(BIN).exists(), "cargo-бинарник никогда не удаляется тестами");
}

#[test]
fn uninstall_with_yes_removes_only_disposable_copy() {
    let env = TestEnv::new();
    let bin = env.disposable_bin();
    let data_marker = env.data().join("keep-marker");
    fs::create_dir_all(env.data()).unwrap();
    fs::write(&data_marker, b"state").unwrap();

    // Без --remove-data данные сохраняются.
    let result = run_json(&bin, &env, &["self", "uninstall", "--yes"], None);
    let value = envelope(&result);
    if value["ok"] == json!(true) {
        assert_eq!(result.code, Some(0));
        assert!(!bin.exists(), "удалён ровно одноразовый исполняемый файл");
        assert!(data_marker.exists(), "без --remove-data локальные данные сохраняются");
        assert_eq!(value["data"]["data_kept"], json!(true), "data_kept=true: {value}");
    } else {
        assert_eq!(result.code, Some(2));
        assert!(
            ["root_required", "unsafe_path"].contains(&error_code(&value)),
            "отказ удаления — только по гейтам: {value}"
        );
        assert!(bin.exists());
        assert!(data_marker.exists());
    }
    assert!(Path::new(BIN).exists(), "cargo-бинарник никогда не удаляется тестами");

    // С --remove-data данные уходят вместе с копией.
    let env2 = TestEnv::new();
    let bin2 = env2.disposable_bin();
    // Only a recognizable essence-rc data layout is removed recursively.
    let marker = env2.data().join("generated").join("marker");
    fs::create_dir_all(marker.parent().unwrap()).unwrap();
    fs::write(&marker, b"state").unwrap();
    let result = run_json(&bin2, &env2, &["self", "uninstall", "--remove-data", "--yes"], None);
    let value = envelope(&result);
    if value["ok"] == json!(true) {
        assert!(!bin2.exists(), "исполняемая копия удалена");
        assert!(!marker.exists(), "данные удалены с --remove-data");
        assert_eq!(value["data"]["data_kept"], json!(false), "data_kept=false: {value}");
    } else {
        assert_eq!(result.code, Some(2));
        assert!(bin2.exists());
        assert!(marker.exists());
    }
    assert!(Path::new(BIN).exists(), "cargo-бинарник никогда не удаляется тестами");
}

/// Демон основного бинарника простаивает; разовый `self uninstall` с
/// одноразовой копии останавливает его (другой исполняемый файл), работает
/// со своим демоном и удаляет только копию.
#[test]
fn uninstall_from_a_copy_next_to_a_daemon_of_the_main_binary() {
    let env = TestEnv::new();
    let mut daemon = common::Daemon::spawn_with(&env.ctx(), &[("ESSENCE_RC_DAEMON_LINGER", "30")]);
    assert_eq!(daemon.hello["exe"], json!(fs::canonicalize(BIN).unwrap()), "hello: {}", daemon.hello);
    daemon.disconnect();
    let bin = env.disposable_bin();
    let result = run_json(&bin, &env, &["self", "uninstall", "--yes"], None);
    let value = envelope(&result);
    assert!(daemon.wait_exit(Duration::from_secs(30)).is_some(), "демон основного бинарника остановлен: {value}");
    if value["ok"] == json!(true) {
        assert!(!bin.exists(), "удалена одноразовая копия");
    } else {
        assert!(["root_required", "unsafe_path"].contains(&error_code(&value)), "{value}");
        assert!(bin.exists());
    }
    assert!(Path::new(BIN).exists(), "cargo-бинарник цел");
}

// ─── proptest: случайные argv ────────────────────────────────────────────────

fn argv_token() -> BoxedStrategy<String> {
    prop_oneof![
        4 => Just("--json".to_owned()),
        2 => Just("--yes".to_owned()),
        1 => Just("--plan-token".to_owned()),
        1 => Just("--plan-token=deadbeefdeadbeef".to_owned()),
        1 => Just("--name".to_owned()),
        2 => Just("x".to_owned()),
        1 => Just("--node".to_owned()),
        1 => Just("n1".to_owned()),
        1 => Just("--secrets-stdin".to_owned()),
        1 => Just("--bogus".to_owned()),
        1 => Just("--password".to_owned()),
        1 => Just("--all".to_owned()),
        1 => Just("--force".to_owned()),
        1 => Just("-h".to_owned()),
        1 => Just("--help".to_owned()),
        1 => Just("--version".to_owned()),
        1 => Just("-V".to_owned()),
        1 => Just("--".to_owned()),
        1 => Just(String::new()),
        1 => Just("y".to_owned()),
        1 => Just("self".to_owned()),
        1 => Just("uninstall".to_owned()),
        1 => Just("password-set".to_owned()),
        1 => Just("password-remove".to_owned()),
        1 => Just("session".to_owned()),
        1 => Just("open".to_owned()),
        1 => Just("status".to_owned()),
        1 => Just("node".to_owned()),
        1 => Just("group".to_owned()),
        1 => Just("list".to_owned()),
        1 => Just("delete".to_owned()),
        1 => Just("add".to_owned()),
        1 => Just("Ω-тест".to_owned()),
        1 => Just("a\nb".to_owned()),
    ]
    .boxed()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    /// Случайные argv: код выхода {0..4}, ровно один конверт в --json,
    /// при отказе состояние не меняется. Деструктивные исходы возможны
    /// только на одноразовой копии бинарника.
    #[test]
    fn random_argv_preserve_envelope_invariants(argv in prop::collection::vec(argv_token(), 0..6)) {
        let env = TestEnv::new();
        let bin = env.disposable_bin();
        let mut args: Vec<String> = argv.clone();
        args.push("--json".to_owned());
        let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();

        let before = snapshot(&env.data());
        let result = run(&bin, &env, &arg_refs, None, Duration::from_secs(30));
        prop_assert!(!result.timed_out, "процесс завис на {:?}", arg_refs);

        let code = result.code.expect("процесс завершается кодом, а не сигналом");
        prop_assert!(matches!(code, 0..=4), "код выхода {{0..4}} для {:?}, получен {code}", arg_refs);

        // --help/-h/--version/-V и пустой argv обслуживаются бинарником до
        // конверта: текстовая справка и выход 0.
        let meta = args.iter().any(|a| matches!(a.as_str(), "-h" | "--help" | "--version" | "-V"))
            || arg_refs.is_empty();
        let looks_json = result.stdout.trim_start().starts_with('{');
        if meta && !looks_json {
            prop_assert_eq!(code, 0, "мета-флаги дают выход 0: {:?}", arg_refs);
            prop_assert!(!result.stdout.trim().is_empty(), "справка не пуста: {:?}", arg_refs);
        } else {
            let text = result.stdout.trim_end_matches('\n');
            prop_assert!(
                !text.is_empty() && !text.contains('\n'),
                "ровно одна строка JSON для {:?}: {:?}", arg_refs, result.stdout
            );
            let parsed: Result<Value, _> = serde_json::from_str(text);
            prop_assert!(parsed.is_ok(), "stdout не JSON: {text}");
            let value = parsed.unwrap();
            prop_assert!(value.get("ok").and_then(Value::as_bool).is_some(), "конверт содержит ok: {value}");
            if value["ok"] == json!(false) {
                prop_assert!(
                    value["error"]["code"].as_str().is_some_and(|c| !c.is_empty()),
                    "код ошибки: {value}"
                );
                prop_assert!(value.get("data").is_none(), "в ошибке нет data: {value}");
            } else {
                prop_assert!(value.get("data").is_some(), "в успехе есть data: {value}");
                prop_assert!(value.get("error").is_none(), "в успехе нет error: {value}");
            }
            prop_assert!(
                value.get("id").is_none_or(Value::is_null),
                "id одиночного вызова null: {value}"
            );
        }

        if code != 0 {
            let after = snapshot(&env.data());
            prop_assert_eq!(before, after, "отказ {:?} не меняет состояние", arg_refs);
        }
    }
}
