//! Cross-process mkdir locks, matching the state.sh session/mutation rules.
//!
//! Mutation guards release at depth zero. Acquiring Session promotes the lock
//! permanently: even dropping every guard retains it until `release_all` or
//! the last manager/guard is dropped. Reentrancy belongs to the execution
//! thread, not the PID. Guards are deliberately neither Send nor Sync.
//!
//! Owner metadata is versioned JSON in `.rc-lock/owner`. Invalid metadata is
//! never reclaimed. Only an absent owner older than 60 seconds, or a proven
//! dead process birth identity, permits recovery. Election directories remain
//! inside the old inode until its atomic rename. A killed reclaimer leaves a
//! fail-closed `.reclaim` requiring manual recovery. Metadata uses secure_fs's
//! flush/replace primitive (including parent-directory fsync on Unix). Windows
//! has no supported directory-fsync equivalent here: replacement is atomic but
//! directory-entry durability across power loss is not guaranteed.

use crate::{error::{RcError, Result}, process::{ProcessIdentity, ProcessState}, secure_fs};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File},
    io::{self, Read},
    marker::PhantomData,
    path::{Path, PathBuf},
    rc::Rc,
    sync::{Arc, Mutex, MutexGuard},
    thread::{self, ThreadId},
    time::{Duration, Instant, SystemTime},
};

const POLL: Duration = Duration::from_millis(200);
const INCOMPLETE_AGE: Duration = Duration::from_secs(60);
const MAX_OWNER: u64 = 64 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LockKind { Session, Mutation }

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Owner {
    version: u32,
    process: ProcessIdentity,
    kind: LockKind,
    label: String,
    token: String,
}

impl Owner {
    fn valid(&self) -> bool {
        self.version == 1 && self.process.is_valid()
            && self.token.len() == 32
            && self.token.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    }
}

enum OwnerStatus { Missing, Valid(Owner), Invalid }

struct Held {
    thread: ThreadId,
    depth: usize,
    owner: Owner,
    directory: DirectoryIdentity,
}

struct Inner {
    path: PathBuf,
    held: Mutex<Option<Held>>,
}

#[derive(Clone)]
pub struct LockManager { inner: Arc<Inner> }

pub struct LockGuard {
    inner: Arc<Inner>,
    token: String,
    active: bool,
    _execution_thread: PhantomData<Rc<()>>,
}

impl LockManager {
    pub fn new(data_dir: impl AsRef<Path>) -> Self {
        Self { inner: Arc::new(Inner { path: data_dir.as_ref().join(".rc-lock"), held: Mutex::new(None) }) }
    }

    pub fn acquire(&self, kind: LockKind, label: &str) -> Result<LockGuard> {
        self.acquire_with_timeout(kind, label, wait_from_env(std::env::var("RC_LOCK_WAIT").ok().as_deref()))
    }

    /// Explicit timeout avoids process-global environment mutation in callers/tests.
    pub fn acquire_with_timeout(&self, kind: LockKind, label: &str, timeout: Duration) -> Result<LockGuard> {
        let mut process = None;
        let started = Instant::now();
        if let Some(parent) = self.inner.path.parent() {
            secure_fs::create_dir_all(parent).map_err(lock_io)?;
        }
        loop {
            {
                let mut held = self.inner.state()?;
                if let Some(held) = held.as_mut() {
                    if held.thread == thread::current().id() {
                        if held.depth == usize::MAX {
                            return Err(RcError::new("locked", "Превышена глубина блокировки конфигурации."));
                        }
                        let directory = PinnedDirectory::open(&self.inner.path).map_err(lock_io)?;
                        if directory.identity != held.directory || !matches!(&directory.owner(), OwnerStatus::Valid(owner) if owner == &held.owner) {
                            return Err(RcError::new("locked", "Владелец блокировки конфигурации изменился."));
                        }
                        if kind == LockKind::Session {
                            let mut promoted = held.owner.clone();
                            promoted.kind = kind;
                            promoted.label = label.into();
                            write_owner(&self.inner.path, &promoted).map_err(lock_io)?;
                            held.owner = promoted;
                        }
                        held.depth += 1;
                        return Ok(self.guard(&held.owner.token));
                    }
                }
                // Keep the shared state mutex until metadata publication, so a
                // clone never mistakes an in-progress acquisition for reentrancy.
                if held.is_none() {
                    if process.is_none() {
                        process = Some(ProcessIdentity::current().map_err(lock_io)?);
                    }
                    match secure_fs::create_dir(&self.inner.path) {
                        Ok(()) => {
                            let directory = PinnedDirectory::open(&self.inner.path).map_err(lock_io)?;
                            let owner = Owner { version: 1, process: process.as_ref().unwrap().clone(), kind, label: label.into(), token: hex::encode(rand::random::<[u8; 16]>()) };
                            if let Err(error) = write_owner(&self.inner.path, &owner) {
                                // A durability error can occur after atomic
                                // publication. Retire a complete owner by token;
                                // otherwise remove only our still-empty inode.
                                let identity = directory.identity;
                                let missing = matches!(directory.owner(), OwnerStatus::Missing);
                                let same_path = directory.matches_path();
                                drop(directory);
                                if same_path {
                                    if missing {
                                        let _ = fs::remove_dir(&self.inner.path);
                                    } else {
                                        let held = Held { thread: thread::current().id(), depth: 1, owner, directory: identity };
                                        let _ = remove_owned(&self.inner.path, &held);
                                    }
                                }
                                return Err(lock_io(error));
                            }
                            let guard = self.guard(&owner.token);
                            *held = Some(Held { thread: thread::current().id(), depth: 1, owner, directory: directory.identity });
                            return Ok(guard);
                        }
                        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                        Err(error) => return Err(lock_io(error)),
                    }
                }
            }
            let mut owner = None;
            if let Ok(directory) = PinnedDirectory::open(&self.inner.path) {
                let status = directory.owner();
                let stale = directory.reclaimable(&status);
                if let OwnerStatus::Valid(value) = status { owner = Some(value); }
                if stale && reclaim(directory) {
                    continue;
                }
            } else if !self.inner.path.exists() {
                // A concurrent release can race with opening the directory.
                if started.elapsed() < timeout { continue; }
            }
            let immediate = owner.as_ref().is_some_and(|owner| owner.kind == LockKind::Session);
            if immediate || started.elapsed() >= timeout {
                return Err(self.inner.busy(owner.as_ref()));
            }
            thread::sleep(POLL.min(timeout.saturating_sub(started.elapsed())));
        }
    }

    fn guard(&self, token: &str) -> LockGuard {
        LockGuard { inner: self.inner.clone(), token: token.into(), active: true, _execution_thread: PhantomData }
    }

    /// End a sticky session and invalidate outstanding guards. Only the owning
    /// execution thread may do this; old guards cannot release a later lock.
    pub fn release_all(&self) -> Result<()> {
        let mut state = self.inner.state()?;
        if let Some(held) = state.as_ref() {
            if held.thread != thread::current().id() {
                return Err(RcError::new("locked", "Блокировка принадлежит другому потоку выполнения."));
            }
            remove_owned(&self.inner.path, held).map_err(lock_io)?;
            *state = None;
        }
        Ok(())
    }
}

impl LockGuard {
    pub fn release(mut self) -> Result<()> {
        self.active = false;
        self.inner.release(&self.token)
    }
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        if self.active { let _ = self.inner.release(&self.token); }
    }
}

impl Inner {
    fn state(&self) -> Result<MutexGuard<'_, Option<Held>>> {
        self.held.lock().map_err(|_| RcError::new("locked", "Состояние блокировки повреждено после паники."))
    }

    fn release(&self, token: &str) -> Result<()> {
        let mut state = self.state()?;
        if let Some(held) = state.as_mut() {
            if held.owner.token != token || held.thread != thread::current().id() { return Ok(()); }
            held.depth = held.depth.saturating_sub(1);
            if held.depth == 0 && held.owner.kind == LockKind::Mutation {
                remove_owned(&self.path, held).map_err(lock_io)?;
                *state = None;
            }
        }
        Ok(())
    }

    fn busy(&self, owner: Option<&Owner>) -> RcError {
        let election = self.path.join(".reclaim");
        if election.exists() {
            return RcError::new("locked", format!("Не завершена очистка блокировки: {}. Убедитесь, что другие операции не выполняются, и только затем удалите этот служебный каталог вручную.", election.display()))
                .with_extra("path", election.to_string_lossy().into_owned());
        }
        let pid = owner.map(|owner| owner.process.pid.to_string()).unwrap_or_else(|| "?".into());
        let label = owner.map(|owner| owner.label.as_str()).unwrap_or("?");
        let error = RcError::new("locked", format!("Конфигурация занята другим процессом (PID {pid}: {label}). Повторите после его завершения."));
        match owner { Some(owner) => error.with_extra("pid", owner.process.pid), None => error }
    }
}

impl Drop for Inner {
    fn drop(&mut self) {
        let state = self.held.get_mut().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(held) = state.take() { let _ = remove_owned(&self.path, &held); }
    }
}

fn wait_from_env(value: Option<&str>) -> Duration {
    let seconds = value.filter(|value| (1..=6).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_digit()))
        .and_then(|value| value.parse::<u64>().ok()).unwrap_or(30);
    Duration::from_secs(seconds)
}

fn lock_io(error: io::Error) -> RcError {
    RcError::new("locked", format!("Не удалось выполнить операцию с блокировкой конфигурации: {error}"))
}

fn write_owner(path: &Path, owner: &Owner) -> io::Result<()> {
    let bytes = serde_json::to_vec(owner).map_err(io::Error::other)?;
    if bytes.len() as u64 > MAX_OWNER { return Err(io::Error::new(io::ErrorKind::InvalidInput, "Lock owner metadata exceeds size limit")); }
    secure_fs::atomic_write(&path.join("owner"), &bytes)
}

fn reclaim(directory: PinnedDirectory) -> bool {
    let Ok(mut election) = Election::claim(directory) else { return false; };
    if !election.directory.matches_path() { return false; }
    let owner = election.directory.owner();
    if !election.directory.reclaimable(&owner) { return false; }
    election.retire().is_ok()
}

fn remove_owned(path: &Path, held: &Held) -> io::Result<()> {
    let directory = match PinnedDirectory::open(path) {
        Ok(directory) => directory,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if directory.identity != held.directory { return Ok(()); }
    let mut election = Election::claim(directory)?;
    if !election.directory.matches_path() { return Ok(()); }
    if !matches!(election.directory.owner(), OwnerStatus::Valid(owner) if owner == held.owner) { return Ok(()); }
    election.retire()
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DirectoryIdentity { volume: u64, file: u64 }

struct PinnedDirectory {
    path: PathBuf,
    file: Option<File>,
    identity: DirectoryIdentity,
    incomplete_old: bool,
}

impl PinnedDirectory {
    fn open(path: &Path) -> io::Result<Self> {
        let file = platform::open_directory(path)?;
        let metadata = file.metadata()?;
        let identity = platform::identity(&file)?;
        let incomplete_old = metadata.modified().ok().and_then(|modified| SystemTime::now().duration_since(modified).ok())
            .is_some_and(|age| age > INCOMPLETE_AGE);
        Ok(Self { path: path.into(), file: Some(file), identity, incomplete_old })
    }

    fn matches_path(&self) -> bool {
        platform::open_directory(&self.path).and_then(|file| platform::identity(&file)).is_ok_and(|identity| identity == self.identity)
    }

    fn owner(&self) -> OwnerStatus {
        let file = match platform::open_owner(self) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return OwnerStatus::Missing,
            Err(_) => return OwnerStatus::Invalid,
        };
        if !file.metadata().is_ok_and(|metadata| metadata.is_file() && metadata.len() <= MAX_OWNER) { return OwnerStatus::Invalid; }
        let mut bytes = Vec::new();
        if file.take(MAX_OWNER + 1).read_to_end(&mut bytes).is_err() || bytes.len() as u64 > MAX_OWNER { return OwnerStatus::Invalid; }
        match serde_json::from_slice::<Owner>(&bytes) {
            Ok(owner) if owner.valid() => OwnerStatus::Valid(owner),
            _ => OwnerStatus::Invalid,
        }
    }

    fn reclaimable(&self, owner: &OwnerStatus) -> bool {
        match owner {
            OwnerStatus::Missing => self.incomplete_old,
            OwnerStatus::Valid(owner) => owner.process.state() == ProcessState::Dead,
            OwnerStatus::Invalid => false,
        }
    }
}

struct Election { directory: PinnedDirectory, active: bool }

impl Election {
    fn claim(directory: PinnedDirectory) -> io::Result<Self> {
        platform::claim(&directory)?;
        Ok(Self { directory, active: true })
    }

    fn retire(&mut self) -> io::Result<()> {
        // The election excludes every cooperating release/reclaimer. Windows
        // pins deny directory deletion until this point; close before rename.
        // Unix keeps the descriptor pinned through the rename.
        let stale = self.directory.path.with_file_name(format!(".rc-lock.stale.{}.{}", std::process::id(), hex::encode(rand::random::<[u8; 16]>())));
        #[cfg(windows)]
        self.directory.file.take();
        fs::rename(&self.directory.path, &stale)?;
        self.active = false;
        // Failure to delete the detached stale directory does not invalidate
        // the successful ownership transfer. It can no longer block the lock.
        let _ = fs::remove_dir_all(stale);
        Ok(())
    }
}

impl Drop for Election {
    fn drop(&mut self) {
        if self.active { platform::unclaim(&self.directory); }
    }
}

#[cfg(unix)]
mod platform {
    use super::*;
    use std::os::{fd::{AsRawFd, FromRawFd}, unix::fs::{MetadataExt, OpenOptionsExt}};

    pub(super) fn open_directory(path: &Path) -> io::Result<File> {
        fs::OpenOptions::new().read(true).custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC).open(path)
    }
    pub(super) fn identity(file: &File) -> io::Result<DirectoryIdentity> {
        let metadata = file.metadata()?;
        Ok(DirectoryIdentity { volume: metadata.dev(), file: metadata.ino() })
    }
    pub(super) fn open_owner(directory: &PinnedDirectory) -> io::Result<File> {
        let fd = directory.file.as_ref().unwrap().as_raw_fd();
        // O_NONBLOCK also prevents a malformed FIFO owner from hanging us.
        let owner = unsafe { libc::openat(fd, c"owner".as_ptr(), libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK) };
        if owner < 0 { return Err(io::Error::last_os_error()); }
        Ok(unsafe { File::from_raw_fd(owner) })
    }
    pub(super) fn claim(directory: &PinnedDirectory) -> io::Result<()> {
        let fd = directory.file.as_ref().unwrap().as_raw_fd();
        // mkdirat anchors the private election to this inode, never a path that
        // a faster reclaimer has already replaced. 0700 applies at creation.
        if unsafe { libc::mkdirat(fd, c".reclaim".as_ptr(), 0o700) } != 0 { return Err(io::Error::last_os_error()); }
        Ok(())
    }
    pub(super) fn unclaim(directory: &PinnedDirectory) {
        if let Some(file) = &directory.file {
            let _ = unsafe { libc::unlinkat(file.as_raw_fd(), c".reclaim".as_ptr(), libc::AT_REMOVEDIR) };
        }
    }
}

#[cfg(windows)]
mod platform {
    use super::*;
    use std::{mem, os::windows::{ffi::OsStrExt, io::{AsRawHandle, FromRawHandle}}};
    use windows_sys::Win32::{Foundation::INVALID_HANDLE_VALUE, Storage::FileSystem::{
        BY_HANDLE_FILE_INFORMATION, CreateFileW, FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT,
        FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
        FILE_SHARE_WRITE, GetFileInformationByHandle, OPEN_EXISTING,
    }};

    pub(super) fn open_directory(path: &Path) -> io::Result<File> {
        let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        if wide[..wide.len() - 1].contains(&0) { return Err(io::Error::new(io::ErrorKind::InvalidInput, "NUL in lock path")); }
        // No FILE_SHARE_DELETE: until the election is installed and verified,
        // neither this directory nor its path may be renamed or deleted.
        let handle = unsafe { CreateFileW(wide.as_ptr(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, std::ptr::null(), OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, std::ptr::null_mut()) };
        if handle == INVALID_HANDLE_VALUE { return Err(io::Error::last_os_error()); }
        let file = unsafe { File::from_raw_handle(handle) };
        let info = information(&file)?;
        if info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0 || info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "Lock path is not a plain directory"));
        }
        Ok(file)
    }
    fn information(file: &File) -> io::Result<BY_HANDLE_FILE_INFORMATION> {
        let mut info = mem::MaybeUninit::zeroed();
        if unsafe { GetFileInformationByHandle(file.as_raw_handle(), info.as_mut_ptr()) } == 0 { return Err(io::Error::last_os_error()); }
        Ok(unsafe { info.assume_init() })
    }
    pub(super) fn identity(file: &File) -> io::Result<DirectoryIdentity> {
        let info = information(file)?;
        Ok(DirectoryIdentity { volume: info.dwVolumeSerialNumber as u64, file: ((info.nFileIndexHigh as u64) << 32) | info.nFileIndexLow as u64 })
    }
    pub(super) fn open_owner(directory: &PinnedDirectory) -> io::Result<File> {
        let path = directory.path.join("owner");
        let metadata = fs::symlink_metadata(&path)?;
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 { return Err(io::Error::new(io::ErrorKind::InvalidData, "Reparse-point lock owner")); }
        File::open(path)
    }
    pub(super) fn claim(directory: &PinnedDirectory) -> io::Result<()> { secure_fs::create_dir(&directory.path.join(".reclaim")) }
    pub(super) fn unclaim(directory: &PinnedDirectory) {
        // If rename failed after releasing the pin, reacquire it and verify the
        // inode before touching the election. Never remove a replacement's.
        if directory.matches_path() { let _ = fs::remove_dir(directory.path.join(".reclaim")); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Barrier, atomic::{AtomicUsize, Ordering}};

    fn zero(manager: &LockManager, kind: LockKind) -> Result<LockGuard> {
        manager.acquire_with_timeout(kind, "test", Duration::ZERO)
    }

    fn fixture(path: &Path, kind: LockKind) -> Owner {
        let owner = Owner { version: 1, process: ProcessIdentity::current().unwrap(), kind, label: "fixture".into(), token: hex::encode(rand::random::<[u8; 16]>()) };
        secure_fs::create_dir(path).unwrap();
        write_owner(path, &owner).unwrap();
        owner
    }

    proptest::proptest! {
        #[test]
        fn invalid_versions_never_authorize_reclaim(version in 2u32..u32::MAX) {
            let owner = Owner {
                version, process: ProcessIdentity { pid: 1, birth: "windows:1".into() },
                kind: LockKind::Mutation, label: "generated".into(), token: "0".repeat(32),
            };
            proptest::prop_assert!(!owner.valid());
        }

        #[test]
        fn malformed_tokens_are_rejected(token in "[g-z]{0,64}") {
            let owner = Owner {
                version: 1, process: ProcessIdentity { pid: 1, birth: "windows:1".into() },
                kind: LockKind::Mutation, label: String::new(), token,
            };
            proptest::prop_assert!(!owner.valid());
        }

        #[test]
        fn arbitrary_owner_bytes_do_not_panic(bytes in proptest::collection::vec(proptest::prelude::any::<u8>(), 0..2048)) {
            if let Ok(owner) = serde_json::from_slice::<Owner>(&bytes) {
                let _ = owner.valid();
            }
        }
    }

    #[test]
    fn environment_wait_is_decimal_bounded_and_non_evaluating() {
        for value in [None, Some(""), Some("5s"), Some("1+"), Some("$(false)"), Some("-1"), Some("1000000")] {
            assert_eq!(wait_from_env(value), Duration::from_secs(30));
        }
        assert_eq!(wait_from_env(Some("000001")), Duration::from_secs(1));
        assert_eq!(wait_from_env(Some("0")), Duration::ZERO);
    }

    #[test]
    fn clones_reenter_but_separate_managers_do_not() {
        let temp = tempfile::tempdir().unwrap();
        let manager = LockManager::new(temp.path());
        let first = zero(&manager, LockKind::Mutation).unwrap();
        let second = zero(&manager.clone(), LockKind::Mutation).unwrap();
        let error = zero(&LockManager::new(temp.path()), LockKind::Mutation).err().unwrap();
        assert_eq!(error.code, "locked");
        assert!(error.message.contains(&std::process::id().to_string()));
        drop(first);
        assert!(manager.inner.path.exists());
        second.release().unwrap();
        assert!(!manager.inner.path.exists());
    }

    #[test]
    fn session_promotion_is_sticky_and_old_guards_cannot_release_new_lock() {
        let temp = tempfile::tempdir().unwrap();
        let manager = LockManager::new(temp.path());
        let outer = zero(&manager, LockKind::Mutation).unwrap();
        let inner = zero(&manager, LockKind::Session).unwrap();
        drop(inner);
        drop(outer);
        assert!(manager.inner.path.exists());
        let start = Instant::now();
        assert!(LockManager::new(temp.path()).acquire_with_timeout(LockKind::Mutation, "foreign", Duration::from_secs(20)).is_err());
        assert!(start.elapsed() < Duration::from_secs(2));
        let old = zero(&manager, LockKind::Mutation).unwrap();
        manager.release_all().unwrap();
        let new = zero(&manager, LockKind::Mutation).unwrap();
        drop(old);
        assert!(manager.inner.path.exists());
        drop(new);
        assert!(!manager.inner.path.exists());
    }

    #[test]
    fn last_manager_drop_releases_sticky_session() {
        let temp = tempfile::tempdir().unwrap();
        let manager = LockManager::new(temp.path());
        drop(zero(&manager, LockKind::Session).unwrap());
        assert!(temp.path().join(".rc-lock").exists());
        drop(manager);
        assert!(!temp.path().join(".rc-lock").exists());
    }

    #[test]
    fn concurrent_clone_threads_serialize_mutations() {
        let temp = tempfile::tempdir().unwrap();
        let manager = LockManager::new(temp.path());
        let barrier = Arc::new(Barrier::new(5));
        let active = Arc::new(AtomicUsize::new(0));
        let completed = Arc::new(AtomicUsize::new(0));
        thread::scope(|scope| {
            for _ in 0..4 {
                let manager = manager.clone();
                let (barrier, active, completed) = (barrier.clone(), active.clone(), completed.clone());
                scope.spawn(move || {
                    barrier.wait();
                    for _ in 0..3 {
                        let _guard = manager.acquire_with_timeout(LockKind::Mutation, "worker", Duration::from_secs(10)).unwrap();
                        assert_eq!(active.fetch_add(1, Ordering::SeqCst), 0);
                        thread::sleep(Duration::from_millis(5));
                        assert_eq!(active.fetch_sub(1, Ordering::SeqCst), 1);
                        completed.fetch_add(1, Ordering::SeqCst);
                    }
                });
            }
            barrier.wait();
        });
        assert_eq!(completed.load(Ordering::SeqCst), 12);
        assert!(!manager.inner.path.exists());
    }

    #[test]
    fn other_thread_cannot_reenter_or_end_session() {
        let temp = tempfile::tempdir().unwrap();
        let manager = LockManager::new(temp.path());
        let guard = zero(&manager, LockKind::Mutation).unwrap();
        thread::scope(|scope| {
            scope.spawn(|| {
                assert!(zero(&manager, LockKind::Mutation).is_err());
                assert!(manager.release_all().is_err());
            }).join().unwrap();
        });
        drop(guard);
    }

    #[test]
    fn reused_pid_is_reclaimed_but_live_owner_times_out() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join(".rc-lock");
        let mut owner = fixture(&path, LockKind::Mutation);
        let manager = LockManager::new(temp.path());
        let start = Instant::now();
        let error = manager.acquire_with_timeout(LockKind::Mutation, "live", Duration::from_millis(30)).err().unwrap();
        assert_eq!(error.code, "locked");
        assert!(start.elapsed() >= Duration::from_millis(30));
        let (prefix, ticks) = owner.process.birth.rsplit_once(':').unwrap();
        owner.process.birth = format!("{prefix}:{}", ticks.parse::<u64>().unwrap() + 1);
        write_owner(&path, &owner).unwrap();
        drop(zero(&manager, LockKind::Mutation).unwrap());
        assert!(!path.exists());
    }

    #[test]
    fn abandoned_election_and_malformed_owner_fail_closed() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join(".rc-lock");
        let owner = fixture(&path, LockKind::Mutation);
        secure_fs::create_dir(&path.join(".reclaim")).unwrap();
        let before = fs::read(path.join("owner")).unwrap();
        let manager = LockManager::new(temp.path());
        let error = zero(&manager, LockKind::Mutation).err().unwrap();
        assert!(error.message.contains(&path.join(".reclaim").display().to_string()));
        assert!(error.message.contains("вручную"));
        assert_eq!(fs::read(path.join("owner")).unwrap(), before);
        fs::remove_dir(path.join(".reclaim")).unwrap();
        for bytes in [b"{".as_slice(), b"{}", b"null", b"pid=123\nkind=mutation\n"] {
            secure_fs::atomic_write(&path.join("owner"), bytes).unwrap();
            assert!(zero(&manager, LockKind::Mutation).is_err());
            assert_eq!(fs::read(path.join("owner")).unwrap(), bytes);
        }
        let mut invalid = owner;
        invalid.process.birth = "garbage".into();
        write_owner(&path, &invalid).unwrap();
        assert!(zero(&manager, LockKind::Mutation).is_err());
    }

    #[test]
    fn missing_fresh_owner_is_not_reclaimed() {
        let temp = tempfile::tempdir().unwrap();
        let manager = LockManager::new(temp.path());
        secure_fs::create_dir(&manager.inner.path).unwrap();
        assert!(zero(&manager, LockKind::Mutation).is_err());
        assert!(manager.inner.path.is_dir());
    }

    #[cfg(unix)]
    #[test]
    fn aged_incomplete_owner_is_reclaimed_but_aged_malformed_owner_is_not() {
        let temp = tempfile::tempdir().unwrap();
        let manager = LockManager::new(temp.path());
        secure_fs::create_dir(&manager.inner.path).unwrap();
        let age = SystemTime::now() - Duration::from_secs(120);
        let directory = platform::open_directory(&manager.inner.path).unwrap();
        directory.set_times(fs::FileTimes::new().set_modified(age)).unwrap();
        drop(directory);
        drop(zero(&manager, LockKind::Mutation).unwrap());
        assert!(!manager.inner.path.exists());

        secure_fs::create_dir(&manager.inner.path).unwrap();
        secure_fs::atomic_write(&manager.inner.path.join("owner"), b"{}").unwrap();
        let directory = platform::open_directory(&manager.inner.path).unwrap();
        directory.set_times(fs::FileTimes::new().set_modified(age)).unwrap();
        drop(directory);
        assert!(zero(&manager, LockKind::Mutation).is_err());
        assert_eq!(fs::read(manager.inner.path.join("owner")).unwrap(), b"{}");
    }

    #[test]
    fn incomplete_owner_with_abandoned_election_is_preserved() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join(".rc-lock");
        secure_fs::create_dir(&path).unwrap();
        secure_fs::create_dir(&path.join(".reclaim")).unwrap();
        let mut directory = PinnedDirectory::open(&path).unwrap();
        directory.incomplete_old = true;
        assert!(!reclaim(directory));
        assert!(path.join(".reclaim").exists());
        assert!(!path.join("owner").exists());
    }


    struct ChildProcess(std::process::Child);

    impl Drop for ChildProcess {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    fn child_worker(path: &Path, mode: &str) -> ChildProcess {
        ChildProcess(std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "locking::tests::process_lock_worker", "--nocapture"])
            .env("ESSENCE_RC_LOCK_TEST_MODE", mode)
            .env("ESSENCE_RC_LOCK_TEST_DIR", path)
            .spawn().unwrap())
    }

    #[test]
    fn process_lock_worker() {
        let Ok(mode) = std::env::var("ESSENCE_RC_LOCK_TEST_MODE") else { return; };
        let path = PathBuf::from(std::env::var_os("ESSENCE_RC_LOCK_TEST_DIR").unwrap());
        let manager = LockManager::new(&path);
        match mode.as_str() {
            "hold" => {
                let _guard = zero(&manager, LockKind::Mutation).unwrap();
                fs::write(path.join("holder-ready"), b"ready").unwrap();
                loop { thread::park(); }
            }
            "contend" => {
                let error = zero(&manager, LockKind::Mutation).err().unwrap();
                assert_eq!(error.code, "locked");
                fs::write(path.join("contender-blocked"), b"blocked").unwrap();
            }
            _ => panic!("unknown child worker mode"),
        }
    }

    #[test]
    fn separate_process_contention_and_dead_owner_reclaim() {
        let temp = tempfile::tempdir().unwrap();
        let mut holder = child_worker(temp.path(), "hold");
        let start = Instant::now();
        while !temp.path().join("holder-ready").exists() {
            assert!(holder.0.try_wait().unwrap().is_none(), "holder exited before acquisition");
            assert!(start.elapsed() < Duration::from_secs(10), "holder did not acquire");
            thread::sleep(Duration::from_millis(20));
        }
        let manager = LockManager::new(temp.path());
        let before = fs::read(manager.inner.path.join("owner")).unwrap();
        let error = zero(&manager, LockKind::Mutation).err().unwrap();
        assert!(error.message.contains(&holder.0.id().to_string()));
        let mut contender = child_worker(temp.path(), "contend");
        assert!(contender.0.wait().unwrap().success());
        assert!(temp.path().join("contender-blocked").exists());
        assert_eq!(fs::read(manager.inner.path.join("owner")).unwrap(), before);

        holder.0.kill().unwrap();
        holder.0.wait().unwrap();
        secure_fs::create_dir(&manager.inner.path.join(".reclaim")).unwrap();
        let error = zero(&manager, LockKind::Mutation).err().unwrap();
        assert!(error.message.contains("вручную"));
        assert_eq!(fs::read(manager.inner.path.join("owner")).unwrap(), before);
        assert!(manager.inner.path.join(".reclaim").exists());
        fs::remove_dir(manager.inner.path.join(".reclaim")).unwrap();
        let guard = zero(&manager, LockKind::Mutation).unwrap();
        assert_ne!(fs::read(manager.inner.path.join("owner")).unwrap(), before);
        guard.release().unwrap();
        assert!(!manager.inner.path.exists());
    }
    #[test]
    fn release_preserves_replacement_metadata() {
        let temp = tempfile::tempdir().unwrap();
        let manager = LockManager::new(temp.path());
        let guard = zero(&manager, LockKind::Mutation).unwrap();
        let mut owner = match PinnedDirectory::open(&manager.inner.path).unwrap().owner() { OwnerStatus::Valid(owner) => owner, _ => panic!("missing owner") };
        owner.token = hex::encode(rand::random::<[u8; 16]>());
        write_owner(&manager.inner.path, &owner).unwrap();
        drop(guard);
        assert!(manager.inner.path.exists());
        assert!(!manager.inner.path.join(".reclaim").exists());
        assert!(matches!(PinnedDirectory::open(&manager.inner.path).unwrap().owner(), OwnerStatus::Valid(value) if value == owner));
    }

    #[test]
    fn delayed_reclaimer_does_not_touch_replacement_inode_or_election() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join(".rc-lock");
        fixture(&path, LockKind::Mutation);
        let directory = PinnedDirectory::open(&path).unwrap();
        // Windows pins intentionally forbid replacement until election; test
        // the Unix cached-inode race directly, plus Windows pin behavior.
        #[cfg(unix)]
        {
            let retired = temp.path().join("old");
            fs::rename(&path, &retired).unwrap();
            let owner = fixture(&path, LockKind::Mutation);
            secure_fs::create_dir(&path.join(".reclaim")).unwrap();
            assert!(!reclaim(directory));
            assert!(path.join(".reclaim").exists());
            assert!(!retired.join(".reclaim").exists());
            assert!(matches!(PinnedDirectory::open(&path).unwrap().owner(), OwnerStatus::Valid(value) if value == owner));
        }
        #[cfg(windows)]
        {
            // The open pin must refuse the rename.
            assert!(fs::rename(&path, temp.path().join("old")).is_err());
            drop(directory);
        }
    }
}
