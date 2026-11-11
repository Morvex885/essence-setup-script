//! Process-level GitHub source scenarios (plan step 5) against real `git`.
//!
//! "GitHub" is a set of local bare repositories: a test-only global git config
//! rewrites `https://github.com/<owner>/essence-remote-control-config.git` to
//! `file://…/<owner>.git` (`url.insteadOf`), so essence-rc runs its production
//! remote code path without any network. github.com is never contacted.
//!
//! `gh` is this very test executable (`harness = false`): copied as `gh` /
//! `gh.exe` into a directory placed first on PATH, it serves the gh calls from
//! files in `FAKE_GH_STATE` and refuses to run if a token variable leaks into
//! its environment. Portable to Windows: no shell scripts are involved except
//! one git `pre-receive` hook (git runs hooks with its own shell everywhere).

use std::collections::BTreeMap;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::LazyLock;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{Value, json};

const REPO: &str = "essence-remote-control-config";

// ─── fake gh ─────────────────────────────────────────────────────────────────

fn fake_gh() -> i32 {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let state = PathBuf::from(std::env::var_os("FAKE_GH_STATE").expect("FAKE_GH_STATE"));
    for leaked in ["GH_TOKEN", "GITHUB_TOKEN", "GH_HOST"] {
        if std::env::var_os(leaked).is_some() {
            eprintln!("{leaked} leaked into gh");
            return 99;
        }
    }
    let profile = std::env::var_os("GH_CONFIG_DIR").map(PathBuf::from);
    let mut log = fs::OpenOptions::new().create(true).append(true).open(state.join("calls.log")).unwrap();
    let scope = profile.as_ref().map_or("global".into(), |p| p.file_name().unwrap().to_string_lossy().into_owned());
    writeln!(log, "{scope}|{}", args.join(" ")).unwrap();
    let offline = state.join("offline").exists();
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let global = fs::read_to_string(state.join("global")).unwrap_or_default();
    let profile_login = || profile.as_ref().and_then(|p| fs::read_to_string(p.join("hosts.yml")).ok())
        .and_then(|text| text.strip_prefix("login: ").map(|l| l.trim().to_owned()));
    let repo_file = |repo: &str| state.join("repos").join(repo.replace('/', "__"));
    match words.as_slice() {
        ["api", "user", "--jq", ".login"] => {
            if offline {
                eprintln!("dial tcp 140.82.121.6:443: connection timed out");
                return 1;
            }
            let login = match &profile { Some(_) => profile_login(), None => global.lines().next().map(str::to_owned) };
            match login {
                Some(login) => { println!("{login}"); 0 }
                None => { eprintln!("You are not logged into any GitHub hosts."); 1 }
            }
        }
        ["auth", "token", "--hostname", "github.com", "--user", user] => {
            if global.lines().any(|l| l == *user) { println!("gho_fake_{user}"); 0 } else { 1 }
        }
        ["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--with-token"] => {
            let mut token = String::new();
            std::io::stdin().read_to_string(&mut token).unwrap();
            let Some(login) = token.trim().strip_prefix("gho_fake_") else { return 1 };
            fs::write(profile.unwrap().join("hosts.yml"), format!("login: {login}\n")).unwrap();
            0
        }
        ["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web"] => {
            match fs::read_to_string(state.join("web-login")) {
                Ok(login) => {
                    eprintln!("! First copy your one-time code: ABCD-1234");
                    fs::write(profile.unwrap().join("hosts.yml"), format!("login: {}\n", login.trim())).unwrap();
                    0
                }
                Err(_) => { eprintln!("authentication failed token=ghp_WebSecret123"); 1 }
            }
        }
        ["repo", "view", repo, "--json", "visibility"] => {
            if offline {
                eprintln!("connection timed out");
                return 1;
            }
            match fs::read_to_string(repo_file(repo)) {
                Ok(visibility) => { println!("{{\"visibility\":\"{}\"}}", visibility.trim()); 0 }
                Err(_) => { eprintln!("GraphQL: Could not resolve to a Repository with the name '{repo}'."); 1 }
            }
        }
        ["repo", "create", repo, "--private", "--description", _] => { fs::write(repo_file(repo), "PRIVATE").unwrap(); 0 }
        ["repo", "edit", repo, "--visibility", "private", "--accept-visibility-change-consequences"] => {
            fs::write(repo_file(repo), "PRIVATE").unwrap();
            0
        }
        ["repo", "delete", repo, "--yes"] => { fs::remove_file(repo_file(repo)).map_or(1, |()| 0) }
        _ => { eprintln!("fake gh: unsupported {args:?}"); 2 }
    }
}

// ─── environment ─────────────────────────────────────────────────────────────

static NEXT: AtomicU64 = AtomicU64::new(0);

/// The fake `gh` (a copy of this executable) shared by all scenarios.
static TOOLS: LazyLock<PathBuf> = LazyLock::new(|| {
    let dir = std::env::temp_dir().join(format!("essence-gh-tools-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    fs::copy(std::env::current_exe().unwrap(), dir.join(format!("gh{}", std::env::consts::EXE_SUFFIX))).unwrap();
    dir
});

fn tools() -> &'static Path {
    &TOOLS
}

fn file_url(path: &Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    if text.starts_with('/') { format!("file://{text}") } else { format!("file:///{text}") }
}

struct Env {
    root: PathBuf,
    data: PathBuf,
    state: PathBuf,
    gitconfig: PathBuf,
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

impl Env {
    fn new(owners: &[&str]) -> Self {
        let root = std::env::temp_dir().join(format!("essence-gh-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
        let _ = fs::remove_dir_all(&root);
        let state = root.join("gh-state");
        fs::create_dir_all(state.join("repos")).unwrap();
        fs::create_dir_all(root.join("home")).unwrap();
        fs::create_dir_all(root.join("remotes")).unwrap();
        fs::write(state.join("global"), owners.join("\n")).unwrap();
        let env = Self { data: root.join("data"), gitconfig: root.join("gitconfig"), state, root };
        let mut config = String::from("[protocol \"file\"]\n\tallow = always\n[init]\n\tdefaultBranch = main\n");
        for owner in owners {
            let remote = env.remote(owner);
            env.git(&["init", "-q", "--bare", &remote.to_string_lossy()]);
            config.push_str(&format!("[url \"{}\"]\n\tinsteadOf = https://github.com/{owner}/{REPO}.git\n", file_url(&remote)));
        }
        fs::write(&env.gitconfig, config).unwrap();
        env
    }

    fn remote(&self, owner: &str) -> PathBuf {
        self.root.join("remotes").join(format!("{owner}.git"))
    }

    fn private(&self, owner: &str) {
        fs::write(self.state.join("repos").join(format!("{owner}__{REPO}")), "PRIVATE").unwrap();
    }

    fn git_command(&self) -> Command {
        let mut command = Command::new("git");
        command.env("GIT_CONFIG_GLOBAL", &self.gitconfig).env("GIT_CONFIG_NOSYSTEM", "1").env("HOME", self.root.join("home"))
            .env("GIT_AUTHOR_NAME", "Other Device").env("GIT_AUTHOR_EMAIL", "other@localhost")
            .env("GIT_COMMITTER_NAME", "Other Device").env("GIT_COMMITTER_EMAIL", "other@localhost");
        command
    }

    fn git(&self, args: &[&str]) -> String {
        let out = self.git_command().args(args).output().unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    fn show(&self, owner: &str, path: &str) -> Option<String> {
        let out = self.git_command().arg("--git-dir").arg(self.remote(owner)).args(["show", &format!("main:{path}")]).output().unwrap();
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
    }

    fn head(&self, owner: &str) -> Option<String> {
        let out = self.git_command().arg("--git-dir").arg(self.remote(owner)).args(["rev-parse", "--verify", "-q", "main"]).output().unwrap();
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
    }

    /// Commit a file change to `owner`'s remote from "another device".
    fn push_external(&self, owner: &str, path: &str, edit: impl FnOnce(String) -> String) {
        let clone = self.root.join(format!("clone-{}", NEXT.fetch_add(1, Ordering::Relaxed)));
        self.git(&["clone", "-q", "-b", "main", &self.remote(owner).to_string_lossy(), &clone.to_string_lossy()]);
        let file = clone.join(path);
        let text = fs::read_to_string(&file).unwrap_or_default();
        fs::write(&file, edit(text)).unwrap();
        let dir = clone.to_string_lossy().into_owned();
        self.git(&["-C", &dir, "commit", "-q", "-am", "other device"]);
        self.git(&["-C", &dir, "push", "-q", "origin", "main"]);
        fs::remove_dir_all(clone).unwrap();
    }

    fn calls(&self) -> String {
        fs::read_to_string(self.state.join("calls.log")).unwrap_or_default()
    }

    /// essence-rc with the fake GitHub: fake gh first on PATH, the rewriting
    /// git config, and token variables that must never reach a child.
    fn essence(&self) -> Command {
        let mut path = vec![tools().to_path_buf()];
        path.extend(std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()));
        let mut command = Command::new(env!("CARGO_BIN_EXE_essence-rc"));
        command.env("ESSENCE_RC_DATA_DIR", &self.data).env("HOME", self.root.join("home"))
            .env("GIT_CONFIG_GLOBAL", &self.gitconfig).env("GIT_CONFIG_NOSYSTEM", "1")
            .env("PATH", std::env::join_paths(path).unwrap()).env("FAKE_GH_STATE", &self.state)
            .env("GH_TOKEN", "ghp_must_not_reach_children").env("GITHUB_TOKEN", "ghp_must_not_reach_children")
            .env("RC_LOCK_WAIT", "5")
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        command
    }

    /// One-shot `essence-rc ARGS --json --secrets-stdin`.
    fn rc(&self, args: &[&str], secrets: Value) -> Reply {
        let mut child = self.essence().args(args).args(["--json", "--secrets-stdin"]).spawn().unwrap();
        child.stdin.take().unwrap().write_all(secrets.to_string().as_bytes()).unwrap();
        let out = child.wait_with_output().unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        assert_eq!(stdout.lines().count(), 1, "exactly one envelope for {args:?}: {stdout}\n{stderr}");
        let envelope: Value = serde_json::from_str(stdout.trim()).unwrap();
        Reply { envelope, code: out.status.code().unwrap_or(-1), stderr }
    }

    fn ok(&self, args: &[&str], secrets: Value) -> Value {
        let reply = self.rc(args, secrets);
        assert_eq!(reply.envelope["ok"], true, "{args:?} failed: {}\n{}", reply.envelope, reply.stderr);
        reply.envelope
    }

    fn fail(&self, args: &[&str], secrets: Value, code: &str) -> Value {
        let reply = self.rc(args, secrets);
        assert_eq!(reply.envelope["error"]["code"], code, "{args:?}: {}\n{}", reply.envelope, reply.stderr);
        assert_eq!(reply.code, if code.ends_with("_required") || code == "usage" { 2 } else { 1 });
        reply.envelope["error"].clone()
    }

    /// Consent round: the plan, then `--yes --plan-token` with the same flags.
    fn confirmed(&self, args: &[&str], secrets: Value) -> (Value, Value) {
        let error = self.fail(args, secrets.clone(), "confirmation_required");
        let token = error["plan_token"].as_str().unwrap().to_owned();
        let mut confirmed = args.to_vec();
        confirmed.extend(["--yes", "--plan-token", &token]);
        (error, self.ok(&confirmed, secrets))
    }

    fn fingerprint(&self) -> BTreeMap<String, Vec<u8>> {
        let mut map = BTreeMap::new();
        let mut pending = vec![self.data.clone()];
        while let Some(dir) = pending.pop() {
            let Ok(entries) = fs::read_dir(&dir) else { continue };
            for entry in entries.flatten() {
                let path = entry.path();
                // Keys use `/` on every OS, matching the paths the assertions name.
                let rel = path.strip_prefix(&self.data).unwrap().to_string_lossy().replace('\\', "/");
                if path.is_dir() {
                    map.insert(format!("{rel}/"), Vec::new());
                    pending.push(path);
                } else {
                    map.insert(rel, fs::read(&path).unwrap());
                }
            }
        }
        map
    }

    fn connect_plain(&self, owner: &str) -> Value {
        self.private(owner);
        self.confirmed(&["source", "github-connect", "--login", owner, "--storage", "none"], json!({})).1
    }

    /// The real TUI screens (scripted keys) over this environment's
    /// `serve --inner` with the data directory `data`. The walk must use every
    /// key, exit 0, and never report a failure: only `ok` and decision codes.
    fn tui(&self, data: &Path, keys: &[&str]) -> Vec<(Vec<String>, String)> {
        let mut command = self.essence();
        command.env("ESSENCE_RC_DATA_DIR", data).args(["serve", "--inner"]);
        let mut client = Recording { inner: essence_rc_tui::serve::ProcessClient::spawn(&mut command).unwrap(), calls: vec![] };
        let mut ui = essence_rc_tui::app::ScriptedUi::new(keys);
        let code = essence_rc_tui::app::run(&mut client, &mut ui, &essence_rc_tui::app::registrations()).unwrap();
        let notices: Vec<String> = ui.notices.iter().map(ToString::to_string).collect();
        let trail = format!("calls: {:#?}\nnotices: {notices:#?}\nlast frame: {:?}", client.calls, ui.views.last().map(|view| &view.title));
        assert_eq!(code, 0, "{trail}");
        assert!(ui.inputs.is_empty(), "walk derailed: {trail}");
        assert!(!notices.iter().any(|n| n.starts_with("[✗]") || n.contains("Операция завершилась ошибкой")), "{trail}");
        assert!(client.calls.iter().all(|(_, code)| code == "ok" || code.ends_with("_required")), "{trail}");
        assert_eq!(ui.busy.len(), client.calls.len(), "every request shows its status line first");
        client.calls
    }
}

struct Reply {
    envelope: Value,
    code: i32,
    stderr: String,
}

/// Records the outcome of every request the real screens send.
struct Recording {
    inner: essence_rc_tui::serve::ProcessClient,
    calls: Vec<(Vec<String>, String)>,
}

impl essence_rc_tui::serve::ServeClient for Recording {
    fn version(&self) -> &str {
        essence_rc_tui::serve::ServeClient::version(&self.inner)
    }

    fn send(&mut self, argv: &[String], secrets: &essence_rc_tui::serve::Secrets,
        progress: &mut dyn FnMut(essence_rc_tui::serve::Progress<'_>)) -> std::io::Result<essence_rc_tui::serve::Reply>
    {
        let reply = self.inner.send(argv, secrets, progress)?;
        self.calls.push((argv.to_vec(), if reply.ok { "ok".into() } else { reply.code().to_owned() }));
        Ok(reply)
    }

    fn close(&mut self) -> std::io::Result<()> {
        self.inner.close()
    }
}

/// Paths added, removed or rewritten between two fingerprints.
fn changed(before: &BTreeMap<String, Vec<u8>>, after: &BTreeMap<String, Vec<u8>>) -> Vec<String> {
    before.keys().chain(after.keys()).filter(|k| before.get(*k) != after.get(*k)).cloned()
        .collect::<std::collections::BTreeSet<_>>().into_iter().collect()
}

fn assert_no_leak(env: &Env, text: &str) {
    assert!(!env.calls().contains("ghp_must_not_reach_children"));
    for secret in ["ghp_WebSecret123", "ghp_must_not_reach_children"] {
        assert!(!text.contains(secret), "{secret} leaked: {text}");
    }
}

// ─── scenarios ───────────────────────────────────────────────────────────────

/// Fresh install into an empty repository: every missing decision is a
/// `*_required` code with the data directory untouched (absent), the repo is
/// created only after consent, and the plain tree lands in `main`.
fn connect_into_empty_repository() {
    let env = Env::new(&["alice"]);
    let base = ["source", "github-connect", "--login", "alice"];
    let error = env.fail(&base, json!({}), "repo_create_required");
    assert_eq!(error["repo"], format!("alice/{REPO}"));
    let create = [&base[..], &["--create-repo"]].concat();
    assert_eq!(env.fail(&create, json!({}), "storage_mode_required")["choices"], json!(["age", "none"]));
    let age = [&create[..], &["--storage", "age"]].concat();
    env.fail(&age, json!({}), "new_vault_password_required");
    let plain = [&create[..], &["--storage", "none"]].concat();
    let plan = env.fail(&plain, json!({}), "confirmation_required");
    let lines = plan["plan"].to_string();
    assert!(lines.contains(&format!("Репозиторий: alice/{REPO} (ветка main)")) && lines.contains("без шифрования"), "{lines}");
    assert!(!env.data.exists(), "a refused fresh connect leaves no data directory");
    assert!(env.head("alice").is_none() && !env.calls().contains("repo create"));

    let (_, done) = env.confirmed(&plain, json!({}));
    assert_eq!(done["data"], json!({"repo": format!("alice/{REPO}"), "storage": "none", "sync": "clean"}));
    assert_eq!(done["sync"], "clean");
    assert!(env.calls().contains(&format!("alice|repo create alice/{REPO} --private")));
    let storage: Value = serde_json::from_str(&env.show("alice", "storage.json").unwrap()).unwrap();
    assert_eq!(storage, json!({"storage_version": 1, "encryption": "none"}));
    assert!(env.show("alice", "config.json").unwrap().contains("\"ROUTER\""));
    let source: Value = serde_json::from_slice(&fs::read(env.data.join("source.json")).unwrap()).unwrap();
    assert_eq!(source, json!({"type": "github", "repo": format!("alice/{REPO}"), "branch": "main", "private_verified": true}));
    assert!(env.data.join("github-runtime/config.json").exists() && env.data.join("github-store").exists());
    assert_eq!(env.fail(&plain, json!({}), "conflict")["code"], "conflict");
    let status = env.ok(&["source", "status"], json!({}));
    assert_eq!(status["data"], json!({"type": "github", "repo": format!("alice/{REPO}"), "branch": "main",
        "storage": "none", "sync": "clean", "key_saved": null}));
    assert_no_leak(&env, &status.to_string());
}

/// Mutations go through checkpoint → commit → push; offline they stay pending
/// (result preserved, envelope `sync:"pending"`), and a later push is clean.
fn offline_pending_then_clean() {
    let env = Env::new(&["alice"]);
    env.connect_plain("alice");
    let set = env.ok(&["self", "password-set"], json!({"password": "pw-one"}));
    assert_eq!(set["sync"], "clean");
    let manifest: Value = serde_json::from_str(&env.show("alice", "manifest.json").unwrap()).unwrap();
    assert!(manifest["access"]["script_password_hash"].as_str().unwrap().starts_with("$argon2id$"));
    let published = env.head("alice").unwrap();

    let parked = env.root.join("parked.git");
    fs::rename(env.remote("alice"), &parked).unwrap();
    fs::write(env.state.join("offline"), "").unwrap();
    let removed = env.ok(&["self", "password-remove", "--yes"], json!({"current-password": "pw-one", "script-password": "pw-one"}));
    assert_eq!(removed["sync"], "pending", "{removed}");
    assert!(!env.data.join("auth.txt").exists(), "the mutation result is kept");
    let status = env.ok(&["status"], json!({}));
    assert_eq!(status["data"]["source"]["sync"], "pending");
    assert_eq!(status["sync"], "pending");

    fs::rename(&parked, env.remote("alice")).unwrap();
    fs::remove_file(env.state.join("offline")).unwrap();
    assert_eq!(env.head("alice").unwrap(), published, "nothing reached the remote while offline");
    let pushed = env.ok(&["source", "github-push"], json!({}));
    assert_eq!(pushed["data"], json!({"sync": "clean"}));
    assert_ne!(env.head("alice").unwrap(), published);
    let manifest: Value = serde_json::from_str(&env.show("alice", "manifest.json").unwrap()).unwrap();
    assert!(manifest["access"]["script_password_hash"].is_null());
    assert_eq!(env.ok(&["status"], json!({}))["sync"], "clean");
    // Local behind remote: the next session fast-forwards and materializes it.
    env.push_external("alice", "config.json", |text| text.replace("\"MOBILE\"", "\"TABLET\""));
    let remote_head = env.head("alice").unwrap();
    assert_eq!(env.ok(&["status"], json!({}))["sync"], "clean");
    assert!(fs::read_to_string(env.data.join("github-runtime/config.json")).unwrap().contains("TABLET"));
    let store = env.data.join("github-store");
    assert_eq!(env.git(&["--git-dir", &store.to_string_lossy(), "rev-parse", "main"]), remote_head);
}

/// Independent local and remote commits: the session refuses to open, nothing
/// is merged and neither side moves.
fn diverged_history_is_refused() {
    let env = Env::new(&["alice"]);
    env.connect_plain("alice");
    let parked = env.root.join("parked.git");
    fs::rename(env.remote("alice"), &parked).unwrap();
    assert_eq!(env.ok(&["self", "password-set"], json!({"password": "pw"}))["sync"], "pending");
    fs::rename(&parked, env.remote("alice")).unwrap();
    env.push_external("alice", "config.json", |text| text.replace("\"MOBILE\"", "\"TABLET\""));
    let remote_head = env.head("alice").unwrap();
    let store = env.data.join("github-store");
    let local_head = env.git(&["--git-dir", &store.to_string_lossy(), "rev-parse", "main"]);
    let error = env.fail(&["status"], json!({"script-password": "pw"}), "source_failed");
    assert_eq!(error["stage"], "сверка локальных и удалённых изменений", "{error}");
    assert_eq!(env.git(&["--git-dir", &store.to_string_lossy(), "rev-parse", "main"]), local_head);
    assert_eq!(env.head("alice").unwrap(), remote_head);
}

/// A remote snapshot that cannot be materialized (invalid script password
/// hash) leaves the previous runtime and `auth.txt` byte-identical.
fn materialization_failure_rolls_back() {
    let env = Env::new(&["alice"]);
    env.connect_plain("alice");
    let before = env.fingerprint();
    let runtime = |map: &BTreeMap<String, Vec<u8>>| map.iter()
        .filter(|(k, _)| k.starts_with("github-runtime") || k.as_str() == "auth.txt")
        .map(|(k, v)| (k.clone(), v.clone())).collect::<BTreeMap<_, _>>();
    env.push_external("alice", "manifest.json", |text| {
        let mut manifest: Value = serde_json::from_str(&text).unwrap();
        manifest["access"]["script_password_hash"] = json!("$6$salt$not-argon2");
        serde_json::to_string_pretty(&manifest).unwrap()
    });
    let error = env.fail(&["status"], json!({}), "source_failed");
    assert_eq!(error["stage"], "восстановление пароля запуска", "{error}");
    assert_eq!(runtime(&env.fingerprint()), runtime(&before));
    assert!(!env.data.join("auth.txt").exists());
}

/// age storage: vault password codes, remember-key, rewrap, rotation and
/// recovery key import; plaintext never reaches the repository.
fn age_vault_lifecycle() {
    let env = Env::new(&["alice"]);
    env.private("alice");
    let connect = ["source", "github-connect", "--login", "alice", "--storage", "age"];
    let done = env.ok(&[&connect[..], &["--yes"]].concat(), json!({"new-vault-password": "vault-one"}));
    assert_eq!(done["data"]["storage"], "age");
    let tree = env.git(&["--git-dir", &env.remote("alice").to_string_lossy(), "ls-tree", "--name-only", "main"]);
    assert_eq!(tree.lines().collect::<Vec<_>>(), ["recipient.txt", "state.json.age", "storage.json", "unlock.age"]);
    assert!(!env.show("alice", "state.json.age").unwrap().contains("ROUTER"));

    env.fail(&["status"], json!({}), "vault_password_required");
    env.fail(&["status"], json!({"vault-password": "wrong"}), "vault_password_invalid");
    env.ok(&["status"], json!({"vault-password": "vault-one"}));
    env.ok(&["session", "open", "--remember-key"], json!({"vault-password": "vault-one"}));
    let key = env.data.join("credentials/github-config.agekey");
    assert!(fs::read_to_string(&key).unwrap().contains("AGE-SECRET-KEY-1"));
    assert_eq!(env.ok(&["source", "status"], json!({}))["data"]["key_saved"], true);

    env.ok(&["source", "github-rewrap-password"], json!({"vault-password": "vault-one", "new-vault-password": "vault-two"}));
    let old_key = env.root.join("old.agekey");
    fs::copy(&key, &old_key).unwrap();
    fs::remove_file(&key).unwrap();
    env.fail(&["status"], json!({"vault-password": "vault-one"}), "vault_password_invalid");
    env.ok(&["status"], json!({"vault-password": "vault-two"}));

    let recipient = env.show("alice", "recipient.txt").unwrap();
    env.ok(&["session", "open", "--remember-key"], json!({"vault-password": "vault-two"}));
    let plan = env.fail(&["source", "github-rotate-key"], json!({"new-vault-password": "vault-three"}), "confirmation_required");
    assert_eq!(plan["plan"][0], "Будет создан новый ключ, и текущая конфигурация будет зашифрована заново.");
    env.ok(&["source", "github-rotate-key", "--yes"], json!({"new-vault-password": "vault-three"}));
    assert_ne!(env.show("alice", "recipient.txt").unwrap(), recipient);
    assert!(fs::read_to_string(&key).unwrap().contains(env.show("alice", "recipient.txt").unwrap().trim()), "the saved key follows rotation");
    let import = env.fail(&["source", "github-import-recovery-key", "--file", &old_key.to_string_lossy()], json!({}), "invalid");
    assert!(import["message"].as_str().unwrap().contains("не подходит к текущему хранилищу"));
    let fresh_key = env.root.join("fresh.agekey");
    fs::copy(&key, &fresh_key).unwrap();
    env.ok(&["source", "github-import-recovery-key", "--file", &fresh_key.to_string_lossy()], json!({}));
    fs::remove_file(&key).unwrap();
    env.fail(&["status"], json!({"vault-password": "vault-two"}), "vault_password_invalid");
    env.ok(&["status"], json!({"vault-password": "vault-three"}));
}

/// Format versions: outdated without a migration path, newer, and the
/// replace-with-local recovery that republishes the device's configuration.
fn format_recovery_and_replace_with_local() {
    let env = Env::new(&["alice"]);
    env.ok(&["source", "init-local"], json!({}));
    env.connect_plain("alice");
    let set_version = |version: Value| env.push_external("alice", "manifest.json", |text| {
        let mut manifest: Value = serde_json::from_str(&text).unwrap();
        manifest["vault_version"] = version;
        serde_json::to_string_pretty(&manifest).unwrap()
    });
    set_version(json!(99));
    assert_eq!(env.fail(&["status"], json!({}), "github_format_newer")["version"], "99");
    env.fail(&["source", "github-replace-with-local"], json!({}), "github_format_newer");
    env.fail(&["source", "github-migrate-format"], json!({}), "nothing_pending");
    set_version(json!(0));
    env.fail(&["session", "open"], json!({}), "github_format_outdated");
    env.fail(&["source", "github-migrate-format", "--yes"], json!({}), "github_format_invalid");
    let (plan, done) = env.confirmed(&["source", "github-replace-with-local"], json!({}));
    assert!(plan["plan"].to_string().contains("Будет опубликована конфигурация только этого компьютера."));
    assert_eq!(done["data"], json!({"published": true, "refreshed": true}));
    let manifest: Value = serde_json::from_str(&env.show("alice", "manifest.json").unwrap()).unwrap();
    assert_eq!(manifest["vault_version"], 1);
    env.ok(&["status"], json!({}));
}

/// A second device: an existing repository needs `--existing`; switch-local
/// and delete-repo return to the local source.
fn existing_repository_switch_local_and_delete() {
    let env = Env::new(&["alice"]);
    env.connect_plain("alice");
    let second = Env::new(&["alice"]);
    fs::remove_dir_all(second.remote("alice")).unwrap();
    fs::rename(env.remote("alice"), second.remote("alice")).unwrap();
    second.private("alice");
    second.ok(&["source", "init-local"], json!({}));
    let before = second.fingerprint();
    let error = second.fail(&["source", "github-connect", "--login", "alice"], json!({}), "existing_config_action_required");
    assert_eq!(error["choices"], json!(["remote", "local"]));
    assert_eq!(error["remote_counts"], json!({"nodes": 0, "clients": 0, "groups": 3}));
    assert_eq!(second.fingerprint(), before, "a required decision leaves the data directory byte-identical");
    second.ok(&["source", "github-connect", "--login", "alice", "--existing", "remote"], json!({}));

    let local = second.ok(&["source", "github-switch-local"], json!({}));
    assert_eq!(local["data"], json!({"source": "local"}));
    assert!(local.get("sync").is_none());
    assert!(!second.data.join("source.json").exists());
    assert_eq!(fs::read_dir(second.data.join("import-backups")).unwrap().count(), 1);
    assert_eq!(second.ok(&["session", "status"], json!({}))["data"]["source"], "local");

    second.ok(&["source", "github-connect", "--login", "alice", "--existing", "remote"], json!({}));
    second.confirmed(&["source", "github-delete-repo"], json!({}));
    assert!(second.calls().contains(&format!("alice|repo delete alice/{REPO} --yes")));
    assert!(!second.data.join("source.json").exists());
}

/// Account change with a push of unknown outcome, then recovery after a
/// "crash" in both directions: the push never landed (rollback) or landed
/// (the switch is finished from the journal).
fn account_switch_journal_recovery() {
    let env = Env::new(&["alice", "bob"]);
    env.connect_plain("alice");
    env.private("bob");
    // A password node from "another device", so the journal snapshots carry a secret.
    let id = "e".repeat(32);
    let secret_id = format!("node:{id}:ssh-password");
    env.push_external("alice", "secrets.json", |text| {
        let mut secrets: Value = serde_json::from_str(&text).unwrap();
        secrets["node_passwords"][&secret_id] = json!("sentinel-pw-9183");
        serde_json::to_string_pretty(&secrets).unwrap()
    });
    env.push_external("alice", "config.json", |text| {
        let mut config: Value = serde_json::from_str(&text).unwrap();
        config["nodes"] = json!([{"id": id, "name": "n1", "ip": "10.0.0.1", "port": 22, "user": "root",
            "auth": "password", "identity": null, "secret_id": secret_id, "aliases": {}}]);
        serde_json::to_string_pretty(&config).unwrap()
    });
    assert_eq!(env.ok(&["status"], json!({}))["data"]["counts"]["nodes"], 1);
    let alice_head = env.head("alice");
    let before = env.fingerprint();
    let change = ["source", "github-change-account", "--login", "bob"];
    env.fail(&change, json!({}), "storage_mode_required");
    // Every one-shot run re-materializes the runtime and fetches: only the fresh
    // GCM nonces of github-runtime/secrets.json and git's FETCH_HEAD may differ.
    let stable = |mut map: BTreeMap<String, Vec<u8>>| {
        map.remove("github-runtime/secrets.json");
        map.remove("github-store/FETCH_HEAD");
        map
    };
    assert_eq!(changed(&stable(before.clone()), &stable(env.fingerprint())), Vec::<String>::new(), "a required decision changes no state");
    assert!(!env.data.join("account-switch").exists() && !env.data.join("credentials/gh/bob").exists());

    // The remote refuses the push: outcome unknown, journal kept.
    let hook = env.remote("bob").join("hooks/pre-receive");
    fs::write(&hook, "#!/bin/sh\nexit 1\n").unwrap();
    #[cfg(unix)]
    fs::set_permissions(&hook, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let flags = [&change[..], &["--storage", "none"]].concat();
    let plan = env.fail(&flags, json!({}), "confirmation_required");
    let token = plan["plan_token"].as_str().unwrap().to_owned();
    let confirmed = [&flags[..], &["--yes", "--plan-token", &token]].concat();
    env.fail(&confirmed, json!({}), "source_failed");
    let marker: Value = serde_json::from_slice(&fs::read(env.data.join("account-switch/transaction.json")).unwrap()).unwrap();
    assert_eq!(marker["phase"], "push_unknown");
    for name in ["old-state.sealed", "target-state.sealed", "transaction.json"] {
        let bytes = fs::read(env.data.join("account-switch").join(name)).unwrap();
        assert!(!String::from_utf8_lossy(&bytes).contains("sentinel-pw-9183"), "{name} holds the password in clear");
    }
    // Next start: bob has no branch → the push never landed → roll back.
    env.ok(&["status"], json!({}));
    assert!(!env.data.join("account-switch").exists());
    let source = fs::read_to_string(env.data.join("source.json")).unwrap();
    assert!(source.contains("alice/"), "{source}");

    // Again, but the push lands while the process "crashes" before recording it.
    env.fail(&confirmed, json!({}), "source_failed");
    let marker: Value = serde_json::from_slice(&fs::read(env.data.join("account-switch/transaction.json")).unwrap()).unwrap();
    let expected = marker["expected_head"].as_str().unwrap().to_owned();
    fs::remove_file(&hook).unwrap();
    let target_store = env.data.join("account-switch/target-store");
    env.git(&["--git-dir", &target_store.to_string_lossy(), "push", "-q", &file_url(&env.remote("bob")), &format!("{expected}:refs/heads/main")]);
    let status = env.ok(&["source", "status"], json!({}));
    assert_eq!(status["data"]["repo"], format!("bob/{REPO}"), "{status}");
    assert!(!env.data.join("account-switch").exists());
    assert_eq!(env.head("alice"), alice_head, "the old repository is never changed");
    assert!(env.show("bob", "storage.json").is_some());
    let summary = env.ok(&["status"], json!({}));
    assert_eq!((summary["data"]["counts"]["nodes"].clone(), summary["data"]["password_missing"].clone()), (json!(1), json!([])),
        "the sealed target snapshot restored the node and its password: {summary}");
    let mutated = env.ok(&["self", "password-set"], json!({"password": "after-switch"}));
    assert_eq!(mutated["sync"], "clean");
    assert_ne!(env.head("bob").unwrap(), expected);
}

/// Account change targets: foreign files need `--replace-target`; a valid
/// configuration needs `--existing`, and `remote` adopts it as is.
fn change_account_targets() {
    let env = Env::new(&["alice", "bob"]);
    env.connect_plain("alice");
    env.private("bob");
    let seed = env.root.join("seed");
    let dir = seed.to_string_lossy().into_owned();
    env.git(&["init", "-q", "-b", "main", &dir]);
    fs::write(seed.join("README.md"), "foreign\n").unwrap();
    env.git(&["-C", &dir, "add", "README.md"]);
    env.git(&["-C", &dir, "commit", "-q", "-m", "foreign"]);
    env.git(&["-C", &dir, "push", "-q", &file_url(&env.remote("bob")), "main"]);
    let change = ["source", "github-change-account", "--login", "bob", "--storage", "none"];
    let error = env.fail(&change, json!({}), "target_replace_required");
    assert_eq!((error["repo"].clone(), error["tracked_files"].clone()), (json!(format!("bob/{REPO}")), json!(1)));
    let (plan, done) = env.confirmed(&[&change[..], &["--replace-target"]].concat(), json!({}));
    assert!(plan["plan"].to_string().contains("будут удалены все файлы (1)"), "{plan}");
    assert_eq!(done["data"]["repo"], format!("bob/{REPO}"));
    assert_eq!(done["data"]["old_repo_settings_url"], format!("https://github.com/alice/{REPO}/settings"));
    assert!(env.show("bob", "README.md").is_none() && env.show("bob", "storage.json").is_some());

    let back = ["source", "github-change-account", "--login", "alice"];
    let error = env.fail(&back, json!({}), "existing_config_action_required");
    assert_eq!(error["choices"], json!(["remote", "local"]));
    let alice_head = env.head("alice");
    let done = env.ok(&[&back[..], &["--existing", "remote"]].concat(), json!({}));
    assert_eq!(done["data"]["repo"], format!("alice/{REPO}"));
    assert_eq!(env.head("alice"), alice_head, "adopting the remote configuration pushes nothing");
    assert!(fs::read_to_string(env.data.join("source.json")).unwrap().contains("alice/"));
}

/// Regression: the configuration repository left by the Bash v1 client (plain
/// layout with `ssh/known_hosts`, snapshot format 2 for 1.x) is not a v2
/// configuration. Connecting must not stop at the tree allowlist: it is a
/// `target_replace_required` decision with the reason, the data directory
/// stays untouched, and `--replace-target` replaces the files after consent.
fn connect_replaces_foreign_v1_repository() {
    let env = Env::new(&["alice"]);
    env.private("alice");
    let seed = env.root.join("seed");
    let dir = seed.to_string_lossy().into_owned();
    env.git(&["init", "-q", "-b", "main", &dir]);
    fs::create_dir_all(seed.join("ssh")).unwrap();
    fs::create_dir_all(seed.join("templates")).unwrap();
    fs::write(seed.join("storage.json"), "{\"storage_version\":1,\"encryption\":\"none\"}\n").unwrap();
    fs::write(seed.join("config.json"), "{\"schema_version\":2,\"nodes\":[],\"clients\":[],\"groups\":[],\"connections\":{}}\n").unwrap();
    fs::write(seed.join("secrets.json"), "{\"schema_version\":2,\"node_passwords\":{}}\n").unwrap();
    fs::write(seed.join("manifest.json"), "{\"vault_version\":2,\"minimum_remote_control_version\":\"1.1.0\",\
        \"portability\":{\"status\":\"ready\",\"issues\":[]},\"access\":{\"script_password_hash\":null},\"templates\":{}}\n").unwrap();
    fs::write(seed.join("ssh/known_hosts"), "").unwrap();
    fs::write(seed.join("templates/default.yaml"), "mode: rule\n").unwrap();
    env.git(&["-C", &dir, "add", "-A"]);
    env.git(&["-C", &dir, "commit", "-q", "-m", "remote-control: sync state"]);
    env.git(&["-C", &dir, "push", "-q", &file_url(&env.remote("alice")), "main"]);
    let v1_head = env.head("alice");
    env.ok(&["source", "init-local"], json!({}));
    let before = env.fingerprint();

    let connect = ["source", "github-connect", "--login", "alice"];
    let error = env.fail(&connect, json!({}), "target_replace_required");
    assert_eq!((error["repo"].clone(), error["tracked_files"].clone()), (json!(format!("alice/{REPO}")), json!(6)), "{error}");
    assert!(error["reason"].as_str().unwrap().contains("ssh/known_hosts"), "{error}");
    assert_eq!(env.fingerprint(), before, "a required decision leaves the data directory byte-identical");
    assert_eq!(env.head("alice"), v1_head);

    let replace = [&connect[..], &["--replace-target"]].concat();
    assert_eq!(env.fail(&replace, json!({}), "storage_mode_required")["choices"], json!(["age", "none"]));
    let plain = [&replace[..], &["--storage", "none"]].concat();
    let (plan, done) = env.confirmed(&plain, json!({}));
    let lines = plan["plan"].to_string();
    assert!(lines.contains("будут удалены все файлы (6)") && lines.contains("ssh/known_hosts"), "{lines}");
    assert_eq!(done["data"], json!({"repo": format!("alice/{REPO}"), "storage": "none", "sync": "clean"}));
    assert!(env.show("alice", "ssh/known_hosts").is_none() && env.show("alice", "ssh/known-hosts.json").is_some());
    let manifest: Value = serde_json::from_str(&env.show("alice", "manifest.json").unwrap()).unwrap();
    assert_eq!(manifest["vault_version"], 1);
    assert_eq!(env.ok(&["source", "status"], json!({}))["data"]["sync"], "clean");
}

/// The real screens against the real `serve --inner` (the TUI's own child)
/// and the fake GitHub: every decision of the GitHub wizard is a question,
/// none ends in «Операция завершилась ошибкой». Paths: the user's report
/// (local configuration, «Источник» → «Подключить GitHub» over a v1
/// repository), a first run that creates an encrypted repository, and a
/// second device that adopts it with the vault password.
fn tui_wizard_walks_github_paths() {
    let env = Env::new(&["alice", "bob"]);
    env.private("alice");
    let seed = env.root.join("seed");
    let dir = seed.to_string_lossy().into_owned();
    env.git(&["init", "-q", "-b", "main", &dir]);
    fs::create_dir_all(seed.join("ssh")).unwrap();
    fs::write(seed.join("storage.json"), "{\"storage_version\":1,\"encryption\":\"none\"}\n").unwrap();
    fs::write(seed.join("ssh/known_hosts"), "").unwrap();
    env.git(&["-C", &dir, "add", "-A"]);
    env.git(&["-C", &dir, "commit", "-q", "-m", "v1"]);
    env.git(&["-C", &dir, "push", "-q", &file_url(&env.remote("alice")), "main"]);
    env.ok(&["source", "init-local"], json!({}));
    // Dashboard → i → g → account 1 (alice) → replace? y → storage 2 (none) → plan y → back → exit.
    let calls = env.tui(&env.data, &["i", "g", "1", "y", "2", "y", "0", "0"]);
    assert!(calls.iter().any(|(argv, code)| argv.contains(&"github-connect".to_owned()) && code == "target_replace_required"), "{calls:?}");
    assert!(env.show("alice", "ssh/known_hosts").is_none() && env.show("alice", "ssh/known-hosts.json").is_some());

    // First run, other login, missing repository, age storage.
    let device = env.root.join("device-2");
    let calls = env.tui(&device, &["2", "2", "bob", "y", "1", "vault-pw", "vault-pw", "0"]);
    assert!(calls.iter().any(|(_, code)| code == "repo_create_required") && calls.iter().any(|(_, code)| code == "new_vault_password_required"), "{calls:?}");
    assert!(env.show("bob", "state.json.age").is_some());

    // Second device: vault password, do not remember the key, use the GitHub configuration.
    let second = env.root.join("device-3");
    let calls = env.tui(&second, &["2", "2", "bob", "vault-pw", "n", "1", "0"]);
    let codes: Vec<&str> = calls.iter().map(|(_, code)| code.as_str()).collect();
    assert!(codes.contains(&"vault_password_required") && codes.contains(&"existing_config_action_required"), "{calls:?}");
}

/// serve keeps one GitHub session: replies carry `sync`, the session lock
/// turns a concurrent process away, EOF removes the worktree and the lock.
fn serve_holds_one_github_session() {
    use std::io::{BufRead, BufReader};
    let env = Env::new(&["alice"]);
    env.connect_plain("alice");
    let mut child = env.essence().arg("serve").spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut reply = || loop {
        let mut line = String::new();
        assert!(stdout.read_line(&mut line).unwrap() > 0, "serve closed stdout");
        let value: Value = serde_json::from_str(&line).unwrap();
        if value.get("event").is_none() {
            break value;
        }
    };
    let mut send = |value: Value| writeln!(stdin, "{value}").unwrap();
    send(json!({"id": 1, "argv": ["session", "open"]}));
    let open = reply();
    assert_eq!(open["data"], json!({"source": "github", "repo": format!("alice/{REPO}"), "sync": "clean"}), "{open}");
    assert_eq!(open["sync"], "clean");
    env.fail(&["status"], json!({}), "locked");
    send(json!({"id": 2, "argv": ["self", "password-set"], "secrets": {"password": "serve-pw"}}));
    let set = reply();
    assert_eq!((set["ok"].clone(), set["sync"].clone()), (json!(true), json!("clean")), "{set}");
    drop(send);
    drop(stdin);
    assert!(child.wait().unwrap().success());
    assert_eq!(fs::read_dir(env.data.join("github-sessions")).unwrap().count(), 0, "EOF closes the worktree");
    assert!(!env.data.join(".rc-lock").exists());
    let manifest: Value = serde_json::from_str(&env.show("alice", "manifest.json").unwrap()).unwrap();
    assert!(manifest["access"]["script_password_hash"].is_string());
}

/// Accounts, browser login with the device code in the journal, and the
/// redacted failure.
fn accounts_and_login() {
    let env = Env::new(&["alice"]);
    fs::write(env.state.join("web-login"), "carol").unwrap();
    let login = env.rc(&["source", "github-login", "--login", "carol"], json!({}));
    assert_eq!(login.envelope["data"], json!({"login": "carol"}), "{}", login.stderr);
    assert!(login.stderr.contains("ABCD-1234"));
    let accounts = env.ok(&["source", "github-accounts"], json!({}));
    assert_eq!(accounts["data"], json!({"accounts": ["carol"], "global_login": "alice"}));
    fs::remove_file(env.state.join("web-login")).unwrap();
    let failed = env.rc(&["source", "github-login", "--login", "dave"], json!({}));
    assert_eq!(failed.envelope["error"]["code"], "github_auth_required");
    assert!(failed.envelope["error"]["hint"].as_str().unwrap().contains("gh auth login --hostname github.com --web"));
    assert_no_leak(&env, &format!("{}{}", failed.envelope, failed.stderr));
    env.fail(&["source", "github-login", "--login", "bad/name"], json!({}), "usage");
}

fn main() {
    let exe = std::env::current_exe().unwrap();
    if exe.file_stem().is_some_and(|stem| stem == "gh") {
        std::process::exit(fake_gh());
    }
    if Command::new("git").arg("--version").output().is_err() {
        println!("git недоступен: сценарии GitHub пропущены");
        return;
    }
    let filter = std::env::args().nth(1).filter(|arg| !arg.starts_with('-'));
    let scenarios: &[(&str, fn())] = &[
        ("connect_into_empty_repository", connect_into_empty_repository),
        ("offline_pending_then_clean", offline_pending_then_clean),
        ("diverged_history_is_refused", diverged_history_is_refused),
        ("materialization_failure_rolls_back", materialization_failure_rolls_back),
        ("age_vault_lifecycle", age_vault_lifecycle),
        ("format_recovery_and_replace_with_local", format_recovery_and_replace_with_local),
        ("existing_repository_switch_local_and_delete", existing_repository_switch_local_and_delete),
        ("account_switch_journal_recovery", account_switch_journal_recovery),
        ("accounts_and_login", accounts_and_login),
        ("serve_holds_one_github_session", serve_holds_one_github_session),
        ("change_account_targets", change_account_targets),
        ("connect_replaces_foreign_v1_repository", connect_replaces_foreign_v1_repository),
        ("tui_wizard_walks_github_paths", tui_wizard_walks_github_paths),
    ];
    let mut failed = Vec::new();
    let mut ran = 0;
    for (name, scenario) in scenarios {
        if filter.as_deref().is_some_and(|filter| !name.contains(filter)) {
            continue;
        }
        ran += 1;
        match std::panic::catch_unwind(scenario) {
            Ok(()) => println!("test {name} ... ok"),
            Err(_) => {
                println!("test {name} ... FAILED");
                failed.push(*name);
            }
        }
    }
    let _ = fs::remove_dir_all(tools());
    println!("\ntest result: {}. {} passed; {} failed", if failed.is_empty() { "ok" } else { "FAILED" }, ran - failed.len(), failed.len());
    if !failed.is_empty() {
        std::process::exit(1);
    }
}
