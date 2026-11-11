//! External `git` and `gh` children (plan B.4). No shell is involved: every
//! child is a `std::process::Command` with an explicitly edited environment,
//! so the same code runs natively on Windows. Tokens and passwords travel only
//! through stdin pipes, never through arguments or the environment.

use std::ffi::OsStr;
use std::io::{Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use zeroize::Zeroizing;

use crate::error::{RcError, Result};

/// Network operations (fetch, push, ls-remote, gh API) are bounded by 30 s.
pub const NETWORK_TIMEOUT: Duration = Duration::from_secs(30);
/// Local repository maintenance has a generous bound against a wedged child.
pub const LOCAL_TIMEOUT: Duration = Duration::from_secs(120);
/// A browser login waits for a human.
pub const WEB_LOGIN_TIMEOUT: Duration = Duration::from_secs(900);

/// Credentials that must never reach a child: the isolated profile decides.
const REMOVED: [&str; 9] = [
    "GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
    "SSH_ASKPASS", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
];

pub struct Output {
    pub success: bool,
    pub timed_out: bool,
    pub stdout: Zeroizing<Vec<u8>>,
    pub stderr: Vec<u8>,
}

impl Output {
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).trim_end_matches(['\r', '\n']).to_owned()
    }

    /// Diagnostic text: stderr, else stdout; redacted by the caller's stage error.
    pub fn diagnostic(&self) -> String {
        let text = if self.stderr.is_empty() { &self.stdout[..] } else { &self.stderr[..] };
        let text = String::from_utf8_lossy(text).trim().to_owned();
        if self.timed_out {
            format!("истекло время ожидания. {text}")
        } else {
            text
        }
    }
}

fn scrubbed(program: &str) -> Command {
    let mut command = Command::new(program);
    for name in REMOVED {
        command.env_remove(name);
    }
    command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    command
}

/// Plain git without network credentials: prompts are impossible on every OS.
/// An empty GIT_ASKPASS is skipped by git (it only runs a non-empty program),
/// `core.askPass=` covers platforms that drop empty environment values, and
/// GIT_TERMINAL_PROMPT=0 refuses the terminal fallback.
pub fn git() -> Command {
    let mut command = scrubbed("git");
    command.env("GIT_TERMINAL_PROMPT", "0").env("GIT_ASKPASS", "").env("GCM_INTERACTIVE", "never");
    command.args(["-c", "core.askPass=", "-c", "credential.helper="]);
    command
}

/// git for github.com: the only credential helper is `gh auth git-credential`
/// from the account's isolated GH_CONFIG_DIR.
pub fn remote_git(profile: &Path, login: &str) -> Command {
    let mut command = git();
    command.env("GH_CONFIG_DIR", profile).env("GH_PROMPT_DISABLED", "1").env("NO_COLOR", "1");
    command.args([
        "-c", "credential.https://github.com.helper=!gh auth git-credential",
        "-c", &format!("credential.https://github.com.username={login}"),
    ]);
    command
}

/// gh in an isolated profile; `None` selects the user's global gh profile.
pub fn gh(profile: Option<&Path>) -> Command {
    let mut command = scrubbed("gh");
    match profile {
        Some(profile) => command.env("GH_CONFIG_DIR", profile),
        None => command.env_remove("GH_CONFIG_DIR"),
    };
    command.env("NO_COLOR", "1").env("GH_PROMPT_DISABLED", "1").env("GH_NO_UPDATE_NOTIFIER", "1");
    command
}

fn spawn_failed(command: &Command) -> RcError {
    let program = command.get_program().to_string_lossy().into_owned();
    RcError::new("deps_missing", format!("Не найдена или не запускается команда {program}."))
}

fn reader(mut source: impl Read + Send + 'static) -> mpsc::Receiver<Vec<u8>> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut buffer = Vec::new();
        let _ = source.read_to_end(&mut buffer);
        let _ = sender.send(buffer);
    });
    receiver
}

/// Run to completion within `timeout`, feeding `stdin` (zeroized by the caller).
/// On timeout the child is killed; readers whose pipes a grandchild keeps open
/// are abandoned rather than awaited.
pub fn run(mut command: Command, stdin: Option<&[u8]>, timeout: Duration) -> Result<Output> {
    if stdin.is_some() {
        command.stdin(Stdio::piped());
    }
    let mut child = command.spawn().map_err(|_| spawn_failed(&command))?;
    let writer = stdin.map(|bytes| {
        let mut pipe = child.stdin.take().expect("stdin is piped");
        let bytes = Zeroizing::new(bytes.to_vec());
        thread::spawn(move || {
            let _ = pipe.write_all(&bytes);
        })
    });
    let stdout = reader(child.stdout.take().expect("stdout is piped"));
    let stderr = reader(child.stderr.take().expect("stderr is piped"));
    let started = Instant::now();
    let (status, timed_out) = loop {
        match child.try_wait() {
            Ok(Some(status)) => break (Some(status), false),
            Ok(None) if started.elapsed() >= timeout => {
                let _ = child.kill();
                let _ = child.wait();
                break (None, true);
            }
            Ok(None) => thread::sleep(Duration::from_millis(5)),
            Err(_) => {
                let _ = child.kill();
                break (None, false);
            }
        }
    };
    if let Some(writer) = writer {
        let _ = writer.join();
    }
    let grace = if timed_out { Duration::from_millis(200) } else { Duration::from_secs(5) };
    let stdout = Zeroizing::new(stdout.recv_timeout(grace).unwrap_or_default());
    let stderr = stderr.recv_timeout(grace).unwrap_or_default();
    Ok(Output { success: status.is_some_and(|s| s.success()), timed_out, stdout, stderr })
}

/// Run while forwarding every output line to `line` as it arrives (browser
/// login prints its device code before waiting).
pub fn run_streaming(mut command: Command, timeout: Duration, mut line: impl FnMut(&str)) -> Result<bool> {
    let mut child = command.spawn().map_err(|_| spawn_failed(&command))?;
    let (sender, receiver) = mpsc::channel::<String>();
    for source in [
        Box::new(child.stdout.take().expect("stdout is piped")) as Box<dyn Read + Send>,
        Box::new(child.stderr.take().expect("stderr is piped")),
    ] {
        let sender = sender.clone();
        thread::spawn(move || {
            let mut reader = std::io::BufReader::new(source);
            let mut buffer = Vec::new();
            loop {
                buffer.clear();
                match std::io::BufRead::read_until(&mut reader, b'\n', &mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        if sender.send(String::from_utf8_lossy(&buffer).trim_end().to_owned()).is_err() {
                            break;
                        }
                    }
                }
            }
        });
    }
    drop(sender);
    let started = Instant::now();
    loop {
        while let Ok(text) = receiver.try_recv() {
            if !text.is_empty() {
                line(&text);
            }
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                while let Ok(text) = receiver.recv_timeout(Duration::from_millis(100)) {
                    if !text.is_empty() {
                        line(&text);
                    }
                }
                return Ok(status.success());
            }
            Ok(None) if started.elapsed() >= timeout => {
                let _ = child.kill();
                let _ = child.wait();
                return Ok(false);
            }
            Ok(None) => thread::sleep(Duration::from_millis(20)),
            Err(_) => return Ok(false),
        }
    }
}

/// Convenience: `git --git-dir=<store> args…`.
pub fn store_git(store: &Path, args: &[&OsStr]) -> Result<Output> {
    let mut command = git();
    command.arg("--git-dir").arg(store).args(args);
    run(command, None, LOCAL_TIMEOUT)
}

/// Convenience: `git -C <worktree> args…`.
pub fn tree_git(worktree: &Path, args: &[&OsStr]) -> Result<Output> {
    let mut command = git();
    command.arg("-C").arg(worktree).args(args);
    run(command, None, LOCAL_TIMEOUT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn child_environment_is_isolated_and_cannot_prompt() {
        let command = remote_git(Path::new("profile"), "owner");
        let envs: Vec<_> = command.get_envs().map(|(k, v)| (k.to_string_lossy().into_owned(), v.map(|v| v.to_string_lossy().into_owned()))).collect();
        for name in ["GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "SSH_ASKPASS"] {
            assert!(envs.contains(&(name.to_owned(), None)), "{name} must be removed");
        }
        assert!(envs.contains(&("GIT_ASKPASS".into(), Some(String::new()))));
        assert!(envs.contains(&("GIT_TERMINAL_PROMPT".into(), Some("0".into()))));
        assert!(envs.contains(&("GH_CONFIG_DIR".into(), Some("profile".into()))));
        let args: Vec<_> = command.get_args().map(|a| a.to_string_lossy().into_owned()).collect();
        assert!(args.windows(2).any(|w| w == ["-c", "credential.helper="]));
        assert!(args.windows(2).any(|w| w == ["-c", "credential.https://github.com.helper=!gh auth git-credential"]));
        assert!(args.windows(2).any(|w| w == ["-c", "credential.https://github.com.username=owner"]));
        let global = gh(None);
        assert!(global.get_envs().any(|(k, v)| k == "GH_CONFIG_DIR" && v.is_none()));
    }

    #[test]
    fn real_git_runs_with_stdin_and_reports_failures() {
        let dir = tempfile::tempdir().unwrap();
        let store = dir.path().join("store");
        let init = { let mut c = git(); c.arg("init").arg("--bare").arg(&store); run(c, None, LOCAL_TIMEOUT).unwrap() };
        assert!(init.success, "{}", init.diagnostic());
        let mut hash = git();
        hash.arg("--git-dir").arg(&store).args(["hash-object", "--stdin"]);
        let out = run(hash, Some(b"payload"), LOCAL_TIMEOUT).unwrap();
        assert!(out.success);
        assert_eq!(out.text().len(), 40);
        let missing = store_git(&store, &["rev-parse".as_ref(), "--verify".as_ref(), "refs/heads/none".as_ref()]).unwrap();
        assert!(!missing.success && !missing.timed_out);
    }
}
