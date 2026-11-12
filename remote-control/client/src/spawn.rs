//! Detached start of a local daemon.
use std::{ffi::OsString, fs::File, io, path::PathBuf, process::{Child, Command, Stdio}};
use crate::endpoint::{Endpoint, prepare_runtime_dir};

/// How to start the daemon (`essence-rc daemon run`) when none is listening.
#[derive(Clone, Debug)]
pub struct SpawnDaemon {
    pub exe: PathBuf,
    pub args: Vec<String>,
    /// Extra environment, applied after `ESSENCE_RC_DATA_DIR` and `ESSENCE_RC_RUNTIME_DIR`.
    pub env: Vec<(OsString, OsString)>,
}

impl SpawnDaemon {
    /// stdin/stdout are null, stderr is appended to the endpoint journal; the
    /// child leaves the session (Unix) or console (Windows) of the caller.
    pub(crate) fn spawn(&self, endpoint: &Endpoint) -> io::Result<Child> {
        prepare_runtime_dir(endpoint)?;
        let journal = open_journal(endpoint)?;
        let exe = std::path::absolute(&self.exe)?;
        let mut command = Command::new(&exe);
        command.args(&self.args)
            .env("ESSENCE_RC_DATA_DIR", &endpoint.data_dir)
            .env(crate::endpoint::RUNTIME_DIR_ENV, &endpoint.runtime_dir)
            .envs(self.env.iter().map(|(name, value)| (name, value)))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::from(journal));
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.current_dir("/");
            // SAFETY: the closure only calls the async-signal-safe setsid.
            unsafe {
                command.pre_exec(|| if libc::setsid() == -1 { Err(io::Error::last_os_error()) } else { Ok(()) });
            }
            command.spawn()
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            use windows_sys::Win32::System::Threading::{CREATE_NEW_PROCESS_GROUP, CREATE_NO_WINDOW};
            if let Some(dir) = exe.parent() { command.current_dir(dir); }
            command.creation_flags(CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP);
            without_inherited_std_handles(|| command.spawn())
        }
    }
}

fn open_journal(endpoint: &Endpoint) -> io::Result<File> {
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    options.open(&endpoint.log)
}

/// The last five lines of the daemon journal (empty when unreadable).
pub(crate) fn journal_tail(endpoint: &Endpoint) -> String {
    let text = std::fs::read(&endpoint.log).map(|bytes| String::from_utf8_lossy(&bytes).into_owned()).unwrap_or_default();
    let lines: Vec<&str> = text.lines().filter(|line| !line.trim().is_empty()).collect();
    lines[lines.len().saturating_sub(5)..].join("\n")
}

/// The daemon must not keep the caller's stdin/stdout/stderr open (a reader
/// of the CLI's stdout pipe would otherwise wait for the daemon to exit):
/// their inherit flag is cleared around `spawn` and restored afterwards.
#[cfg(windows)]
fn without_inherited_std_handles<T>(spawn: impl FnOnce() -> T) -> T {
    use windows_sys::Win32::{Foundation::{GetHandleInformation, HANDLE_FLAG_INHERIT, INVALID_HANDLE_VALUE, SetHandleInformation},
        System::Console::{GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE}};
    let mut restore = Vec::new();
    for which in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE] {
        // SAFETY: plain Win32 calls on the process' own standard handles.
        unsafe {
            let handle = GetStdHandle(which);
            if handle.is_null() || handle == INVALID_HANDLE_VALUE || restore.contains(&handle) { continue; }
            let mut flags = 0u32;
            if GetHandleInformation(handle, &mut flags) != 0 && flags & HANDLE_FLAG_INHERIT != 0
                && SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0) != 0 {
                restore.push(handle);
            }
        }
    }
    let result = spawn();
    for handle in restore {
        // SAFETY: the handle was valid above and is still owned by this process.
        unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT); }
    }
    result
}
