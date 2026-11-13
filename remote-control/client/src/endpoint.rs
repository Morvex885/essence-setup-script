//! Where the daemon of a data directory listens: runtime directory, socket
//! (Unix) or named pipe (Windows), lock and journal files.
use std::{ffi::OsString, io, path::{Path, PathBuf}};
use sha2::{Digest, Sha256};

/// Explicit runtime directory; must be an absolute path.
pub const RUNTIME_DIR_ENV: &str = "ESSENCE_RC_RUNTIME_DIR";
/// Unix socket paths longer than this do not fit `sun_path` on every platform.
#[cfg(unix)]
const MAX_SOCKET_PATH: usize = 100;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Endpoint {
    /// Absolute data directory the daemon serves (`ESSENCE_RC_DATA_DIR` of a spawned daemon).
    pub data_dir: PathBuf,
    pub runtime_dir: PathBuf,
    /// `h`: first 16 hex digits of SHA-256 of `<data dir>\n<runtime dir>`
    /// (raw path bytes; the data directory with its symlinks resolved).
    pub id: String,
    /// Unix socket `<runtime>/<h>.sock`.
    pub socket: PathBuf,
    /// Windows named pipe `\\.\pipe\essence-rc-<h>`.
    pub pipe: String,
    /// Single-instance lock `<runtime>/<h>.lock` (Unix).
    pub lock: PathBuf,
    /// Daemon journal (its stderr) `<runtime>/<h>.log`.
    pub log: PathBuf,
}

pub(crate) fn invalid(message: impl Into<String>) -> io::Error { io::Error::new(io::ErrorKind::InvalidInput, message.into()) }

/// The platform family that decides the default runtime directory.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Os { Linux, Mac, Windows }

fn current_os() -> Os {
    if cfg!(windows) { Os::Windows } else if cfg!(target_os = "macos") { Os::Mac } else { Os::Linux }
}

/// The runtime directory: `ESSENCE_RC_RUNTIME_DIR`, otherwise the platform default.
pub fn runtime_dir() -> io::Result<PathBuf> {
    #[cfg(unix)]
    // SAFETY: geteuid has no preconditions and cannot fail.
    let euid = unsafe { libc::geteuid() };
    #[cfg(not(unix))]
    let euid = u32::MAX;
    choose_runtime_dir(euid, &|name| std::env::var_os(name), dirs::home_dir().as_deref(), dirs::data_local_dir().as_deref(),
        current_os(), &directory_owner)
}

/// Owner uid of a real directory (not a link); `None` otherwise.
fn directory_owner(path: &Path) -> Option<u32> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        std::fs::symlink_metadata(path).ok().filter(|meta| meta.is_dir()).map(|meta| meta.uid())
    }
    #[cfg(not(unix))]
    { std::fs::symlink_metadata(path).ok().filter(|meta| meta.is_dir()).map(|_| 0) }
}

fn no_home() -> io::Error { io::Error::new(io::ErrorKind::NotFound, "Не удалось определить домашний каталог пользователя.") }

/// Pure choice of the runtime directory (П5). `env` reads variables, `owner`
/// tells the owner of an existing directory. Shared directories such as
/// `/tmp`, `XDG_RUNTIME_DIR` and `TMPDIR` are never used.
pub(crate) fn choose_runtime_dir(euid: u32, env: &dyn Fn(&str) -> Option<OsString>, home: Option<&Path>, local_data: Option<&Path>,
    os: Os, owner: &dyn Fn(&Path) -> Option<u32>) -> io::Result<PathBuf> {
    if let Some(dir) = env(RUNTIME_DIR_ENV) {
        if dir.is_empty() { return Err(invalid("ESSENCE_RC_RUNTIME_DIR не должен быть пустым.")); }
        let dir = PathBuf::from(dir);
        if !dir.is_absolute() { return Err(invalid("ESSENCE_RC_RUNTIME_DIR должен быть абсолютным путём.")); }
        return Ok(dir);
    }
    match os {
        Os::Windows => Ok(local_data.ok_or_else(no_home)?.join("essence-rc").join("run")),
        _ if euid == 0 => Ok(PathBuf::from(if owner(Path::new("/run")).is_some() { "/run/essence-rc" } else { "/var/run/essence-rc" })),
        Os::Mac => Ok(home.ok_or_else(no_home)?.join("Library/Caches/essence-rc/run")),
        Os::Linux => {
            let user = PathBuf::from(format!("/run/user/{euid}"));
            if owner(&user) == Some(euid) { return Ok(user.join("essence-rc")); }
            Ok(home.ok_or_else(no_home)?.join(".cache/essence-rc/run"))
        }
    }
}

/// The data directory with the symlinks of its longest existing ancestor
/// resolved and the missing tail appended: every spelling of one directory
/// names one daemon. Creates nothing.
pub(crate) fn resolved(path: &Path) -> PathBuf {
    let mut tail = Vec::new();
    let mut current = path;
    loop {
        if let Ok(real) = std::fs::canonicalize(current) {
            return tail.iter().rev().fold(real, |path, name| path.join(name));
        }
        match (current.parent(), current.file_name()) {
            (Some(parent), Some(name)) => {
                tail.push(name.to_owned());
                current = parent;
            }
            _ => return path.to_owned(),
        }
    }
}
/// Pure: the endpoint of `data_dir` inside `runtime_dir` (no environment).
pub fn endpoint_in(runtime_dir: &Path, data_dir: &Path) -> io::Result<Endpoint> {
    if !runtime_dir.is_absolute() { return Err(invalid("ESSENCE_RC_RUNTIME_DIR должен быть абсолютным путём.")); }
    let data_dir = std::path::absolute(data_dir)?;
    let mut hasher = Sha256::new();
    hasher.update(resolved(&data_dir).as_os_str().as_encoded_bytes());
    hasher.update(b"\n");
    hasher.update(runtime_dir.as_os_str().as_encoded_bytes());
    let digest = hasher.finalize();
    let id = hex::encode(&digest[..8]);
    let socket = runtime_dir.join(format!("{id}.sock"));
    #[cfg(unix)]
    if socket.as_os_str().len() > MAX_SOCKET_PATH {
        return Err(invalid("Путь сокета демона слишком длинный: задайте ESSENCE_RC_RUNTIME_DIR."));
    }
    Ok(Endpoint {
        pipe: format!(r"\\.\pipe\essence-rc-{id}"),
        lock: runtime_dir.join(format!("{id}.lock")),
        log: runtime_dir.join(format!("{id}.log")),
        runtime_dir: runtime_dir.to_owned(),
        data_dir,
        socket,
        id,
    })
}

/// The endpoint of `data_dir` in the runtime directory from the environment.
pub fn endpoint_for(data_dir: &Path) -> io::Result<Endpoint> { endpoint_in(&runtime_dir()?, data_dir) }

/// Creates the runtime directory (0700 on Unix) and checks it like [`verify_runtime_dir`].
pub fn prepare_runtime_dir(endpoint: &Endpoint) -> io::Result<()> {
    let dir = &endpoint.runtime_dir;
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        match std::fs::symlink_metadata(dir) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?,
            Err(error) => return Err(error),
            Ok(_) => {}
        }
    }
    #[cfg(windows)]
    std::fs::create_dir_all(dir)?;
    verify_runtime_dir(dir)
}

/// Unix: a real directory (not a symlink) owned by the effective uid without
/// group/other permissions; otherwise `PermissionDenied` (`unsafe_path`).
/// A missing directory is `NotFound`. Windows relies on the pipe owner check.
pub fn verify_runtime_dir(dir: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let meta = std::fs::symlink_metadata(dir)?;
        // SAFETY: geteuid has no preconditions and cannot fail.
        let uid = unsafe { libc::geteuid() };
        if !meta.is_dir() || meta.uid() != uid || meta.permissions().mode() & 0o077 != 0 {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied,
                format!("Небезопасный каталог времени выполнения «{}»: нужен собственный каталог с правами 0700.", dir.display())));
        }
    }
    #[cfg(windows)]
    let _ = dir;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vars(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<OsString> {
        move |name| pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| OsString::from(value))
    }

    #[test]
    fn root_runtime_dir_ignores_xdg_runtime_dir() {
        let home = Path::new("/root");
        let run = |path: &Path| (path == Path::new("/run")).then_some(0);
        let with_xdg = vars(&[("XDG_RUNTIME_DIR", "/run/user/0"), ("TMPDIR", "/tmp")]);
        let without = vars(&[]);
        let a = choose_runtime_dir(0, &with_xdg, Some(home), None, Os::Linux, &run).unwrap();
        let b = choose_runtime_dir(0, &without, Some(home), None, Os::Linux, &run).unwrap();
        assert_eq!((a.as_path(), b.as_path()), (Path::new("/run/essence-rc"), Path::new("/run/essence-rc")));
        // `/run/essence-rc` is an absolute path only on Unix hosts.
        if cfg!(unix) {
            let data = Path::new("/var/lib/essence");
            assert_eq!(endpoint_in(&a, data).unwrap().socket, endpoint_in(&b, data).unwrap().socket);
        }
        // No /run: /var/run; macOS root the same rule.
        assert_eq!(choose_runtime_dir(0, &without, Some(home), None, Os::Linux, &|_| None).unwrap(), Path::new("/var/run/essence-rc"));
        assert_eq!(choose_runtime_dir(0, &with_xdg, Some(home), None, Os::Mac, &run).unwrap(), Path::new("/run/essence-rc"));
    }

    #[test]
    fn user_runtime_dir_prefers_owned_run_user() {
        let home = Path::new("/home/u");
        let env = vars(&[("XDG_RUNTIME_DIR", "/elsewhere")]);
        let owned = |path: &Path| (path == Path::new("/run/user/1000")).then_some(1000);
        let foreign = |path: &Path| (path == Path::new("/run/user/1000")).then_some(0);
        assert_eq!(choose_runtime_dir(1000, &env, Some(home), None, Os::Linux, &owned).unwrap(), Path::new("/run/user/1000/essence-rc"));
        assert_eq!(choose_runtime_dir(1000, &env, Some(home), None, Os::Linux, &foreign).unwrap(), Path::new("/home/u/.cache/essence-rc/run"));
        assert_eq!(choose_runtime_dir(1000, &env, Some(home), None, Os::Linux, &|_| None).unwrap(), Path::new("/home/u/.cache/essence-rc/run"));
        assert_eq!(choose_runtime_dir(501, &env, Some(Path::new("/Users/u")), None, Os::Mac, &owned).unwrap(),
            Path::new("/Users/u/Library/Caches/essence-rc/run"));
        assert_eq!(choose_runtime_dir(1, &env, None, Some(Path::new(r"C:\Users\u\AppData\Local")), Os::Windows, &|_| None).unwrap(),
            Path::new(r"C:\Users\u\AppData\Local").join("essence-rc").join("run"));
    }

    #[test]
    fn explicit_runtime_dir_wins_and_is_validated() {
        // An absolute path of the host running the test.
        const EXPLICIT: &str = if cfg!(windows) { r"C:\srv\rc-run" } else { "/srv/rc-run" };
        let explicit = vars(&[("ESSENCE_RC_RUNTIME_DIR", EXPLICIT)]);
        assert_eq!(choose_runtime_dir(0, &explicit, None, None, Os::Linux, &|_| Some(0)).unwrap(), Path::new(EXPLICIT));
        assert!(choose_runtime_dir(0, &vars(&[("ESSENCE_RC_RUNTIME_DIR", "")]), None, None, Os::Linux, &|_| None).is_err());
        assert!(choose_runtime_dir(0, &vars(&[("ESSENCE_RC_RUNTIME_DIR", "rel")]), None, None, Os::Linux, &|_| None).is_err());
    }

    #[cfg(unix)]
    fn runtime() -> tempfile::TempDir { tempfile::Builder::new().prefix("rc").tempdir_in("/tmp").unwrap() }
    #[cfg(windows)]
    fn runtime() -> tempfile::TempDir { tempfile::tempdir().unwrap() }

    #[test]
    fn endpoint_in_is_deterministic_and_keyed_by_both_directories() {
        let runtime = runtime();
        let other = runtime.path().join("other");
        let data = runtime.path().join("data");
        let first = endpoint_in(runtime.path(), &data).unwrap();
        assert_eq!(first, endpoint_in(runtime.path(), &data).unwrap());
        assert_eq!(first.id.len(), 16);
        assert!(first.id.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()), "{}", first.id);
        let expected = Sha256::digest([resolved(&data).as_os_str().as_encoded_bytes(), b"\n", runtime.path().as_os_str().as_encoded_bytes()].concat());
        assert_eq!(first.id, hex::encode(&expected[..8]));
        assert_eq!(first.socket, runtime.path().join(format!("{}.sock", first.id)));
        assert_eq!(first.lock, runtime.path().join(format!("{}.lock", first.id)));
        assert_eq!(first.log, runtime.path().join(format!("{}.log", first.id)));
        assert_eq!(first.pipe, format!(r"\\.\pipe\essence-rc-{}", first.id));
        assert_eq!(first.data_dir, data);
        assert_ne!(first.id, endpoint_in(&other, &data).unwrap().id, "the runtime directory isolates endpoints");
        assert_ne!(first.id, endpoint_in(runtime.path(), &other).unwrap().id);
    }

    /// The id of a UTF-8 path is the digest of its text, as before.
    #[cfg(unix)]
    #[test]
    fn utf8_paths_keep_the_textual_id() {
        let id = endpoint_in(Path::new("/run/rc"), Path::new("/nonexistent-rc/дата")).unwrap().id;
        assert_eq!(id, hex::encode(&Sha256::digest("/nonexistent-rc/дата\n/run/rc")[..8]));
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_and_non_utf8_spellings_name_their_directory() {
        use std::ffi::OsStr;
        use std::os::unix::ffi::OsStrExt;
        let runtime = runtime();
        let real = runtime.path().join("real");
        std::fs::create_dir(&real).unwrap();
        let link = runtime.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let id = |data: &Path| endpoint_in(runtime.path(), data).unwrap().id;
        assert_eq!(id(&link), id(&real), "a link names the directory it points to");
        assert_eq!(id(&link.join("absent/data")), id(&real.join("absent/data")), "a missing tail is appended");
        assert!(!real.join("absent").exists(), "nothing is created");
        assert_eq!(endpoint_in(runtime.path(), &link).unwrap().data_dir, link, "the daemon gets the path as given");
        let lossy = |byte: u8| id(&runtime.path().join(OsStr::from_bytes(&[b'd', byte])));
        assert_ne!(lossy(0xff), lossy(0xfe), "non-UTF-8 bytes are not merged");
    }

    #[test]
    fn relative_data_dir_is_made_absolute_and_relative_runtime_is_invalid() {
        let runtime = runtime();
        let relative = endpoint_in(runtime.path(), Path::new("data")).unwrap();
        assert_eq!(relative, endpoint_in(runtime.path(), &std::env::current_dir().unwrap().join("data")).unwrap());
        assert_eq!(endpoint_in(Path::new("run"), Path::new("/data")).unwrap_err().kind(), io::ErrorKind::InvalidInput);
    }

    #[cfg(unix)]
    #[test]
    fn long_socket_path_is_rejected() {
        let runtime = PathBuf::from(format!("/tmp/{}", "r".repeat(90)));
        let error = endpoint_in(&runtime, Path::new("/data")).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        assert_eq!(error.to_string(), "Путь сокета демона слишком длинный: задайте ESSENCE_RC_RUNTIME_DIR.");
    }

    #[cfg(unix)]
    #[test]
    fn runtime_dir_must_be_private_real_directory() {
        use std::os::unix::fs::PermissionsExt;
        let base = runtime();
        let dir = base.path().join("run");
        let endpoint = endpoint_in(&dir, Path::new("/data")).unwrap();
        prepare_runtime_dir(&endpoint).unwrap();
        assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        verify_runtime_dir(&dir).unwrap();

        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o750)).unwrap();
        assert_eq!(verify_runtime_dir(&dir).unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(prepare_runtime_dir(&endpoint).unwrap_err().kind(), io::ErrorKind::PermissionDenied, "never silently chmod");
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();

        let link = base.path().join("link");
        std::os::unix::fs::symlink(&dir, &link).unwrap();
        assert_eq!(verify_runtime_dir(&link).unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(verify_runtime_dir(&base.path().join("absent")).unwrap_err().kind(), io::ErrorKind::NotFound);
    }
}
