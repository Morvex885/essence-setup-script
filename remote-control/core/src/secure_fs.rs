//! Private state files, with no subprocess ACL helpers.
//!
//! On Unix, existing parent aliases are canonicalized before a no-follow fd walk;
//! final sensitive entries still cannot be symlinks. Windows rejects reparse
//! points. Only the directory explicitly passed to `create_dir_all` is made
//! private on reuse. New directories are private from creation. Atomic writes
//! sync the new file before replacement and the containing directory on Unix.
//! Windows has no
//! supported equivalent of Unix directory fsync; MoveFileExW's WRITE_THROUGH is
//! used, but cannot promise the same power-loss durability for directory entries.

use std::fs::File;
use std::io::{self, Write};
use std::path::Path;

/// Create an owner-only directory, failing with `AlreadyExists` on reuse.
pub fn create_dir(path: &Path) -> io::Result<()> {
    let (parent, name) = split_path(path)?;
    platform::Parent::open(parent)?.create_dir(name)
}

/// Create private directories, tightening the final existing directory on reuse.
/// Existing ancestors are never chmodded or assigned a new DACL.
pub fn create_dir_all(path: &Path) -> io::Result<()> {
    platform::create_dir_all(path)
}

/// Exclusively create a private, read/write regular file. Never truncate a file.
pub fn create_new(path: &Path) -> io::Result<File> {
    let (parent, name) = split_path(path)?;
    platform::Parent::open(parent)?.create_new(name)
}

/// Replace a regular file atomically with private, fully flushed contents.
///
/// A precommit failure leaves the previous file untouched and removes the
/// temporary file. An error syncing the directory is necessarily postcommit:
/// the new contents are visible, but their crash durability is uncertain.
pub fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    atomic_write_with(path, |file| file.write_all(bytes))
}

fn split_path(path: &Path) -> io::Result<(&Path, &std::ffi::OsStr)> {
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "expected a file or directory name")
    })?;
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
    Ok((parent, name))
}

fn unsafe_path() -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, "sensitive path is not an owner-controlled regular file or directory")
}

fn atomic_write_with(path: &Path, write: impl FnOnce(&mut File) -> io::Result<()>) -> io::Result<()> {
    let (parent_path, destination) = split_path(path)?;
    let parent = platform::Parent::open(parent_path)?;
    parent.check_destination(destination)?;
    // A cryptographically random, same-parent name; exclusive creation also
    // handles collisions. The guard unlinks relative to the pinned parent.
    let (name, file) = loop {
        let name = std::ffi::OsString::from(format!(".rc-write-{:032x}", rand::random::<u128>()));
        match parent.create_new(&name) {
            Ok(file) => break (name, file),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    };
    let mut temporary = Temporary { parent: &parent, name: &name, committed: false };
    // Declare the owned handle after the cleanup guard, so both error returns
    // and unwinding close it before Windows attempts to remove its name.
    let mut file = file;
    write(&mut file)?;
    file.sync_all()?;
    // Close before replacement: Windows must be allowed to rename the source.
    drop(file);
    parent.check_destination(destination)?;
    parent.replace(&name, destination)?;
    temporary.committed = true;
    parent.sync()
}

struct Temporary<'a> {
    parent: &'a platform::Parent,
    name: &'a std::ffi::OsStr,
    committed: bool,
}

impl Drop for Temporary<'_> {
    fn drop(&mut self) {
        if !self.committed {
            self.parent.remove(self.name);
        }
    }
}

#[cfg(unix)]
mod platform {
    use super::unsafe_path;
    use std::ffi::{CStr, CString, OsStr};
    use std::fs::File;
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use std::path::{Component, Path};

    pub(super) struct Parent(File);

    fn c_name(name: &OsStr) -> io::Result<CString> {
        CString::new(name.as_bytes()).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in path"))
    }

    fn from_fd(fd: libc::c_int) -> io::Result<File> {
        if fd < 0 {
            Err(io::Error::last_os_error())
        } else {
            // SAFETY: a successful open/openat returned a new owned descriptor.
            Ok(unsafe { File::from_raw_fd(fd) })
        }
    }

    fn anchor(absolute: bool) -> io::Result<File> {
        let path: &CStr = if absolute { c"/" } else { c"." };
        // SAFETY: path is NUL terminated and flags require no mode argument.
        from_fd(unsafe { libc::open(path.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW) })
    }

    fn open_directory(parent: &File, name: &CStr) -> io::Result<File> {
        // SAFETY: parent is live and name is a NUL-terminated component.
        from_fd(unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW) })
    }

    fn private_directory(file: &File) -> io::Result<()> {
        let metadata = file.metadata()?;
        // SAFETY: geteuid has no preconditions.
        if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } {
            return Err(unsafe_path());
        }
        file.set_permissions(std::fs::Permissions::from_mode(0o700))
    }

    fn mkdir(parent: &File, name: &CStr) -> io::Result<File> {
        // SAFETY: parent is live and name is a NUL-terminated component.
        if unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let initialized = (|| {
            let file = match open_directory(parent, name) {
                Ok(file) => file,
                Err(error) if error.kind() == io::ErrorKind::PermissionDenied => {
                    // An unusually restrictive umask may remove owner read.
                    // Restore only this new entry, never follow a swapped link.
                    if unsafe { libc::fchmodat(parent.as_raw_fd(), name.as_ptr(), 0o700, libc::AT_SYMLINK_NOFOLLOW) } != 0 {
                        return Err(io::Error::last_os_error());
                    }
                    open_directory(parent, name)?
                }
                Err(error) => return Err(error),
            };
            private_directory(&file)?;
            Ok(file)
        })();
        if initialized.is_err() {
            // Only the newly created, still-empty entry can be removed.
            unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) };
        }
        initialized
    }

    fn walk(path: &Path, create: bool) -> io::Result<File> {
        let mut current = anchor(path.is_absolute())?;
        if create && path == Path::new(".") {
            private_directory(&current)?;
        }
        let mut components = path.components().peekable();
        while let Some(component) = components.next() {
            let name = match component {
                Component::RootDir | Component::CurDir => continue,
                Component::Normal(name) => c_name(name)?,
                Component::ParentDir => CString::new("..").unwrap(),
                Component::Prefix(_) => return Err(unsafe_path()),
            };
            let (next, created) = match open_directory(&current, &name) {
                Ok(next) => (next, false),
                Err(error) if create && error.kind() == io::ErrorKind::NotFound => {
                    match mkdir(&current, &name) {
                        Ok(next) => (next, true),
                        Err(error) if error.kind() == io::ErrorKind::AlreadyExists =>
                            (open_directory(&current, &name)?, false),
                        Err(error) => return Err(error),
                    }
                }
                Err(error) => return Err(error),
            };
            if create && !created && components.peek().is_none() {
                private_directory(&next)?;
            }
            current = next;
        }
        Ok(current)
    }

    pub(super) fn create_dir_all(path: &Path) -> io::Result<()> {
        if path.as_os_str().is_empty() {
            return Ok(());
        }
        if path == Path::new(".") {
            return walk(path, true).map(|_| ());
        }
        let Ok((mut ancestor, name)) = super::split_path(path) else {
            return walk(path, true).map(|_| ());
        };
        // Resolve only existing parents, never the final sensitive entry.
        // Preserve missing parents so walk creates them with private modes.
        let mut missing = Vec::new();
        let mut resolved = loop {
            match std::fs::canonicalize(ancestor) {
                Ok(resolved) => break resolved,
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    let (parent, name) = super::split_path(ancestor)?;
                    missing.push(name);
                    ancestor = parent;
                }
                Err(error) => return Err(error),
            }
        };
        for name in missing.into_iter().rev() {
            resolved.push(name);
        }
        resolved.push(name);
        walk(&resolved, true).map(|_| ())
    }

    impl Parent {
        pub(super) fn open(path: &Path) -> io::Result<Self> {
            walk(&std::fs::canonicalize(path)?, false).map(Self)
        }

        pub(super) fn create_dir(&self, name: &OsStr) -> io::Result<()> {
            mkdir(&self.0, &c_name(name)?).map(|_| ())
        }

        pub(super) fn create_new(&self, name: &OsStr) -> io::Result<File> {
            let name = c_name(name)?;
            // SAFETY: exclusive creation never follows a preexisting link.
            let file = from_fd(unsafe { libc::openat(self.0.as_raw_fd(), name.as_ptr(), libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC | libc::O_NOFOLLOW, 0o600) })?;
            // Restore owner access even under a restrictive umask, without ever
            // granting group/other permissions during creation.
            if let Err(error) = file.set_permissions(std::fs::Permissions::from_mode(0o600)) {
                // SAFETY: unlink only the exclusively created directory entry.
                unsafe { libc::unlinkat(self.0.as_raw_fd(), name.as_ptr(), 0) };
                return Err(error);
            }
            Ok(file)
        }

        pub(super) fn check_destination(&self, name: &OsStr) -> io::Result<()> {
            let name = c_name(name)?;
            let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
            // SAFETY: the stat output points at correctly sized writable memory.
            if unsafe { libc::fstatat(self.0.as_raw_fd(), name.as_ptr(), metadata.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW) } != 0 {
                let error = io::Error::last_os_error();
                return if error.kind() == io::ErrorKind::NotFound { Ok(()) } else { Err(error) };
            }
            // SAFETY: fstatat initialized metadata on success.
            let metadata = unsafe { metadata.assume_init() };
            if metadata.st_mode & libc::S_IFMT != libc::S_IFREG || metadata.st_uid != unsafe { libc::geteuid() } {
                return Err(unsafe_path());
            }
            Ok(())
        }

        pub(super) fn replace(&self, source: &OsStr, destination: &OsStr) -> io::Result<()> {
            let source = c_name(source)?;
            let destination = c_name(destination)?;
            // SAFETY: both names are relative to the same live directory fd.
            if unsafe { libc::renameat(self.0.as_raw_fd(), source.as_ptr(), self.0.as_raw_fd(), destination.as_ptr()) } != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        }

        pub(super) fn remove(&self, name: &OsStr) {
            if let Ok(name) = c_name(name) {
                // SAFETY: this name belongs to our exclusively created tempfile.
                unsafe { libc::unlinkat(self.0.as_raw_fd(), name.as_ptr(), 0) };
            }
        }

        pub(super) fn sync(&self) -> io::Result<()> {
            self.0.sync_all()
        }
    }
}

#[cfg(windows)]
mod platform {
    use super::unsafe_path;
    use std::ffi::{OsStr, c_void};
    use std::fs::File;
    use std::io;
    use std::mem::{size_of, zeroed};
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use std::path::{Component, Path, PathBuf};
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::Foundation::{ERROR_INVALID_FUNCTION, ERROR_INVALID_PARAMETER, ERROR_NOT_SUPPORTED, GENERIC_READ, GENERIC_WRITE, INVALID_HANDLE_VALUE, LocalFree};
    use windows_sys::Win32::Security::Authorization::{ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo, SE_FILE_OBJECT, SetSecurityInfo};
    use windows_sys::Win32::Security::{DACL_SECURITY_INFORMATION, EqualSid, GetSecurityDescriptorDacl, GetTokenInformation, OWNER_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION, SECURITY_ATTRIBUTES, TOKEN_INFORMATION_CLASS, TOKEN_OWNER, TOKEN_QUERY, TOKEN_USER, TokenOwner, TokenUser};
    use windows_sys::Win32::Storage::FileSystem::*;
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
    use windows_sys::Win32::System::SystemServices::FILE_PERSISTENT_ACLS;

    // Pin ancestors against rename by denying FILE_SHARE_DELETE. Cooperating
    // callers may still open them for DACL changes while these pins are held.
    pub(super) struct Parent {
        path: PathBuf,
        _ancestors: Vec<File>,
    }

    pub(super) struct LocalAllocation(pub(super) *mut c_void);

    impl Drop for LocalAllocation {
        fn drop(&mut self) {
            // SAFETY: this allocation came from a LocalAlloc-family API.
            unsafe { LocalFree(self.0) };
        }
    }

    fn wide(path: &Path) -> io::Result<Vec<u16>> {
        let mut value: Vec<u16> = path.as_os_str().encode_wide().collect();
        if value.contains(&0) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "NUL in path"));
        }
        value.push(0);
        Ok(value)
    }

    fn check_component(name: &OsStr) -> io::Result<()> {
        let units = name.encode_wide();
        if name.is_empty() || matches!(units.clone().last(), Some(32 | 46))
            || units.clone().any(|unit| matches!(unit, 0 | 47 | 58 | 92)) {
            return Err(unsafe_path());
        }
        // DOS device names can ignore CREATE_NEW and open a device instead of a
        // regular file, including when an extension is appended.
        const DEVICES: &[&str] = &[
            "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
            "COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³",
        ];
        for device in DEVICES {
            let stem = units.clone().take_while(|unit| *unit != 46).map(|unit| {
                if (97..=122).contains(&unit) { unit - 32 } else { unit }
            });
            if stem.eq(device.encode_utf16()) { return Err(unsafe_path()); }
        }
        Ok(())
    }

    fn bool_result(value: i32) -> io::Result<()> {
        if value == 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
    }

    // Keep the token buffer alive: the SID inside TOKEN_USER/TOKEN_OWNER points into this buffer.
    fn token_information(class: TOKEN_INFORMATION_CLASS) -> io::Result<Vec<usize>> {
        unsafe {
            let mut token = null_mut();
            bool_result(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token))?;
            let token = OwnedHandle::from_raw_handle(token);
            let mut length = 0;
            GetTokenInformation(token.as_raw_handle(), class, null_mut(), 0, &mut length);
            if length == 0 {
                return Err(io::Error::last_os_error());
            }
            // usize gives the token structure and embedded SID alignment.
            let mut buffer = vec![0usize; (length as usize).div_ceil(size_of::<usize>())];
            bool_result(GetTokenInformation(token.as_raw_handle(), class, buffer.as_mut_ptr().cast(), length, &mut length))?;
            Ok(buffer)
        }
    }

    fn token_user() -> io::Result<Vec<usize>> { token_information(TokenUser) }

    pub(super) struct Security(LocalAllocation);

    impl Security {
        pub(super) fn new(directory: bool) -> io::Result<Self> {
            unsafe {
                let user = token_user()?;
                let sid = (*(user.as_ptr().cast::<TOKEN_USER>())).User.Sid;
                let mut sid_text = null_mut();
                bool_result(ConvertSidToStringSidW(sid, &mut sid_text))?;
                let allocation = LocalAllocation(sid_text.cast());
                let mut length = 0;
                while *sid_text.add(length) != 0 { length += 1; }
                let sid_text = String::from_utf16(std::slice::from_raw_parts(sid_text, length))
                    .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid Windows SID"))?;
                drop(allocation);
                let inheritance = if directory { "OICI" } else { "" };
                let sddl = format!("O:{sid_text}D:P(A;{inheritance};FA;;;{sid_text})");
                let sddl: Vec<u16> = sddl.encode_utf16().chain(Some(0)).collect();
                let mut descriptor = null_mut();
                bool_result(ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), 1, &mut descriptor, null_mut()))?;
                Ok(Self(LocalAllocation(descriptor)))
            }
        }

        fn attributes(&self) -> SECURITY_ATTRIBUTES {
            SECURITY_ATTRIBUTES { nLength: size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: self.0.0, bInheritHandle: 0 }
        }

        fn restrict(&self, file: &File) -> io::Result<()> {
            check_owner(file)?;
            unsafe {
                let mut present = 0;
                let mut defaulted = 0;
                let mut dacl = null_mut();
                bool_result(GetSecurityDescriptorDacl(self.0.0, &mut present, &mut dacl, &mut defaulted))?;
                if present == 0 || dacl.is_null() { return Err(unsafe_path()); }
                let result = SetSecurityInfo(file.as_raw_handle(), SE_FILE_OBJECT,
                    DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                    null_mut(), null_mut(), dacl, null());
                if result != 0 { return Err(io::Error::from_raw_os_error(result as i32)); }
                Ok(())
            }
        }
    }

    /// The owner is the current user or the token's default owner: an
    /// elevated administrator's objects are owned by BUILTIN\Administrators
    /// (the default owner of an elevated token), which is still a principal
    /// of this process, not a foreign one.
    fn check_owner(file: &File) -> io::Result<()> {
        unsafe {
            let user = token_user()?;
            let sid = (*(user.as_ptr().cast::<TOKEN_USER>())).User.Sid;
            let default_owner = token_information(TokenOwner)?;
            let default_sid = (*(default_owner.as_ptr().cast::<TOKEN_OWNER>())).Owner;
            let mut owner = null_mut();
            let mut descriptor = null_mut();
            let result = GetSecurityInfo(file.as_raw_handle(), SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION,
                &mut owner, null_mut(), null_mut(), null_mut(), &mut descriptor);
            if result != 0 { return Err(io::Error::from_raw_os_error(result as i32)); }
            let _allocation = LocalAllocation(descriptor);
            if owner.is_null() || (EqualSid(owner, sid) == 0 && EqualSid(owner, default_sid) == 0) { return Err(unsafe_path()); }
            Ok(())
        }
    }

    fn open(path: &Path, directory: bool, access: u32, share: u32) -> io::Result<File> {
        let path = wide(path)?;
        unsafe {
            let handle = CreateFileW(path.as_ptr(), access, share, null(), OPEN_EXISTING,
                FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, null_mut());
            if handle == INVALID_HANDLE_VALUE { return Err(io::Error::last_os_error()); }
            let file = File::from_raw_handle(handle);
            let mut information: BY_HANDLE_FILE_INFORMATION = zeroed();
            bool_result(GetFileInformationByHandle(handle, &mut information))?;
            if information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
                || (information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) != directory {
                return Err(unsafe_path());
            }
            Ok(file)
        }
    }

    fn mkdir(path: &Path, security: &Security) -> io::Result<()> {
        let path = wide(path)?;
        let attributes = security.attributes();
        // SAFETY: descriptor, attributes and UTF-16 path live for the entire call.
        bool_result(unsafe { CreateDirectoryW(path.as_ptr(), &attributes) })
    }

    /// Rename with POSIX semantics (Windows 10 1607+, NTFS): the destination
    /// is replaced even while readers hold it open, which the classic rename
    /// refuses with ERROR_ACCESS_DENIED. Filesystems without it report
    /// ERROR_INVALID_PARAMETER/ERROR_NOT_SUPPORTED; the caller falls back.
    /// `destination` is the NUL-terminated UTF-16 full path.
    fn posix_rename(source: &Path, destination: &[u16]) -> io::Result<()> {
        const FILE_RENAME_FLAG_REPLACE_IF_EXISTS: u32 = 0x1;
        const FILE_RENAME_FLAG_POSIX_SEMANTICS: u32 = 0x2;
        let file = open(source, false, DELETE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)?;
        let name = &destination[..destination.len() - 1];
        let name_offset = std::mem::offset_of!(FILE_RENAME_INFO, FileName);
        let size = name_offset + size_of_val(name);
        // u64 storage satisfies FILE_RENAME_INFO's pointer alignment.
        let mut buffer = vec![0u64; size.div_ceil(size_of::<u64>())];
        unsafe {
            let info = buffer.as_mut_ptr().cast::<FILE_RENAME_INFO>();
            (*info).Anonymous.Flags = FILE_RENAME_FLAG_REPLACE_IF_EXISTS | FILE_RENAME_FLAG_POSIX_SEMANTICS;
            (*info).RootDirectory = null_mut();
            (*info).FileNameLength = size_of_val(name) as u32;
            std::ptr::copy_nonoverlapping(name.as_ptr(), buffer.as_mut_ptr().cast::<u8>().add(name_offset).cast::<u16>(), name.len());
            bool_result(SetFileInformationByHandle(file.as_raw_handle(), FileRenameInfoEx, buffer.as_ptr().cast(), size as u32))
        }
    }

    fn walk(path: &Path, create: bool) -> io::Result<Parent> {
        // absolute handles drive-relative paths without changing global cwd.
        let absolute = std::path::absolute(path)?;
        let mut current = PathBuf::new();
        let mut ancestors = Vec::new();
        let security = if create { Some(Security::new(true)?) } else { None };
        let mut components = absolute.components().peekable();
        while let Some(component) = components.next() {
            match component {
                Component::Prefix(prefix) => {
                    match prefix.kind() {
                        std::path::Prefix::Disk(_) | std::path::Prefix::VerbatimDisk(_)
                            | std::path::Prefix::UNC(_, _) | std::path::Prefix::VerbatimUNC(_, _) => (),
                        _ => return Err(unsafe_path()),
                    }
                    current.push(prefix.as_os_str());
                    continue;
                }
                Component::RootDir => current.push(component.as_os_str()),
                Component::Normal(name) => {
                    check_component(name)?;
                    current.push(name);
                }
                Component::CurDir => continue,
                Component::ParentDir => return Err(unsafe_path()),
            }
            let final_directory = components.peek().is_none();
            if create && final_directory && matches!(component, Component::RootDir) {
                return Err(unsafe_path()); // Never change a volume root's DACL.
            }
            let access = FILE_READ_ATTRIBUTES | if create && final_directory { READ_CONTROL | WRITE_DAC } else { 0 };
            let file = match open(&current, true, access, FILE_SHARE_READ | FILE_SHARE_WRITE) {
                Ok(file) => file,
                Err(error) if create && error.kind() == io::ErrorKind::NotFound => {
                    match mkdir(&current, security.as_ref().unwrap()) {
                        Ok(()) => (),
                        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => (),
                        Err(error) => return Err(error),
                    }
                    open(&current, true, access, FILE_SHARE_READ | FILE_SHARE_WRITE)?
                }
                Err(error) => return Err(error),
            };
            if ancestors.is_empty() {
                let mut flags = 0;
                // A filesystem may accept but ignore creation descriptors (FAT).
                // Refuse it before creating any sensitive entries.
                bool_result(unsafe { GetVolumeInformationByHandleW(file.as_raw_handle(), null_mut(), 0,
                    null_mut(), null_mut(), &mut flags, null_mut(), 0) })?;
                if flags & FILE_PERSISTENT_ACLS == 0 { return Err(unsafe_path()); }
            }
            let file = if create && final_directory {
                security.as_ref().unwrap().restrict(&file)?;
                // Acquire the read-only pin before dropping WRITE_DAC access:
                // there must never be a window in which rename is permitted.
                let pin = open(&current, true, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE)?;
                drop(file);
                pin
            } else {
                file
            };
            ancestors.push(file);
        }
        if ancestors.is_empty() { return Err(unsafe_path()); }
        Ok(Parent { path: current, _ancestors: ancestors })
    }

    pub(super) fn create_dir_all(path: &Path) -> io::Result<()> {
        if path.as_os_str().is_empty() { return Ok(()); }
        walk(path, true).map(|_| ())
    }

    impl Parent {
        pub(super) fn open(path: &Path) -> io::Result<Self> {
            walk(path, false)
        }

        fn child(&self, name: &OsStr) -> io::Result<PathBuf> {
            check_component(name)?;
            Ok(self.path.join(name))
        }

        pub(super) fn create_dir(&self, name: &OsStr) -> io::Result<()> {
            mkdir(&self.child(name)?, &Security::new(true)?)
        }

        pub(super) fn create_new(&self, name: &OsStr) -> io::Result<File> {
            let path = wide(&self.child(name)?)?;
            let security = Security::new(false)?;
            let attributes = security.attributes();
            unsafe {
                let handle = CreateFileW(path.as_ptr(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ,
                    &attributes, CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, null_mut());
                if handle == INVALID_HANDLE_VALUE { return Err(io::Error::last_os_error()); }
                Ok(File::from_raw_handle(handle))
            }
        }

        pub(super) fn check_destination(&self, name: &OsStr) -> io::Result<()> {
            match open(&self.child(name)?, false, FILE_READ_ATTRIBUTES | READ_CONTROL, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE) {
                Ok(file) => check_owner(&file),
                Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(error),
            }
        }

        pub(super) fn replace(&self, source: &OsStr, destination: &OsStr) -> io::Result<()> {
            let source_path = self.child(source)?;
            let destination = wide(&self.child(destination)?)?;
            match posix_rename(&source_path, &destination) {
                Err(error) if matches!(error.raw_os_error().map(|code| code as u32),
                    Some(ERROR_INVALID_PARAMETER | ERROR_NOT_SUPPORTED | ERROR_INVALID_FUNCTION)) => (),
                result => return result,
            }
            let source = wide(&source_path)?;
            // Same-parent MoveFileEx, without COPY_ALLOWED, is an atomic rename.
            // Unlike ReplaceFileW it keeps the new file's private DACL rather
            // than inheriting the replaced file's possibly permissive DACL.
            bool_result(unsafe { MoveFileExW(source.as_ptr(), destination.as_ptr(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) })
        }

        pub(super) fn remove(&self, name: &OsStr) {
            if let Ok(path) = self.child(name) { let _ = std::fs::remove_file(path); }
        }

        pub(super) fn sync(&self) -> io::Result<()> {
            // See module documentation: no portable directory flush on Windows.
            Ok(())
        }
    }

    #[cfg(test)]
    pub(super) fn assert_private_acl(path: &Path, directory: bool) {
        use windows_sys::Win32::Security::{ACCESS_ALLOWED_ACE, GetAce, GetSecurityDescriptorControl, SE_DACL_PROTECTED};
        use windows_sys::Win32::System::SystemServices::ACCESS_ALLOWED_ACE_TYPE;
        let file = open(path, directory, READ_CONTROL | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE).unwrap();
        check_owner(&file).unwrap();
        unsafe {
            let mut owner = null_mut();
            let mut dacl = null_mut();
            let mut descriptor = null_mut();
            assert_eq!(GetSecurityInfo(file.as_raw_handle(), SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                &mut owner, null_mut(), &mut dacl, null_mut(), &mut descriptor), 0);
            let _allocation = LocalAllocation(descriptor);
            assert!(!dacl.is_null(), "NULL DACL grants access to everyone");
            let mut control = 0;
            let mut revision = 0;
            assert_ne!(GetSecurityDescriptorControl(descriptor, &mut control, &mut revision), 0);
            assert_ne!(control & SE_DACL_PROTECTED, 0, "DACL must not inherit broad ancestor grants");
            assert_eq!((*dacl).AceCount, 1, "only the owner may receive an allow ACE");
            let mut ace = null_mut();
            assert_ne!(GetAce(dacl, 0, &mut ace), 0);
            let ace = &*ace.cast::<ACCESS_ALLOWED_ACE>();
            assert_eq!(ace.Header.AceType as u32, ACCESS_ALLOWED_ACE_TYPE);
            assert_eq!(ace.Mask & FILE_ALL_ACCESS, FILE_ALL_ACCESS);
            let ace_sid = std::ptr::addr_of!(ace.SidStart).cast_mut().cast();
            assert_ne!(EqualSid(owner, ace_sid), 0, "allow ACE must name the actual owner SID");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn entries(path: &Path) -> Vec<std::ffi::OsString> {
        let mut names: Vec<_> = fs::read_dir(path).unwrap().map(|entry| entry.unwrap().file_name()).collect();
        names.sort();
        names
    }

    #[test]
    fn replaces_existing_contents_and_creates_missing_file() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("state");
        atomic_write(&path, b"old").unwrap();
        let mut previous = File::open(&path).unwrap();
        atomic_write(&path, b"replacement").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"replacement");
        use std::io::Read;
        let mut previous_contents = Vec::new();
        previous.read_to_end(&mut previous_contents).unwrap();
        assert_eq!(previous_contents, b"old", "replacement must not truncate the old open file");
        assert_eq!(entries(root.path()), [std::ffi::OsString::from("state")]);
    }

    #[test]
    fn failed_partial_write_preserves_old_file_and_cleans_temporary() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("state");
        atomic_write(&path, b"previous valid contents").unwrap();
        let error = atomic_write_with(&path, |file| {
            file.write_all(b"incomplete replacement")?;
            Err(io::Error::other("injected precommit write failure"))
        }).unwrap_err();
        assert_eq!(error.to_string(), "injected precommit write failure");
        assert_eq!(fs::read(&path).unwrap(), b"previous valid contents");
        assert_eq!(entries(root.path()), [std::ffi::OsString::from("state")]);
    }

    #[test]
    fn failed_first_write_leaves_no_file_or_temporary() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("state");
        assert!(atomic_write_with(&path, |file| {
            file.write_all(b"partial")?;
            Err(io::Error::other("injected failure"))
        }).is_err());
        assert!(entries(root.path()).is_empty());
    }

    #[test]
    fn failed_commit_cleans_temporary_without_removing_destination() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("state");
        let result = atomic_write_with(&path, |file| {
            file.write_all(b"new")?;
            // Destination becomes an incompatible directory after initial check.
            fs::create_dir(&path)
        });
        assert!(result.is_err());
        assert!(path.is_dir());
        assert_eq!(entries(root.path()), [std::ffi::OsString::from("state")]);
    }

    #[test]
    fn exclusive_creation_never_truncates_existing_file_or_reuses_directory() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("file");
        create_new(&path).unwrap().write_all(b"original").unwrap();
        assert_eq!(create_new(&path).unwrap_err().kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read(&path).unwrap(), b"original");
        let directory = root.path().join("directory");
        create_dir(&directory).unwrap();
        assert_eq!(create_dir(&directory).unwrap_err().kind(), io::ErrorKind::AlreadyExists);
    }

    #[test]
    fn relative_filename_uses_current_directory_as_parent() {
        // A unique bare name avoids changing process-wide cwd in parallel tests.
        let name = format!(".rc-relative-test-{}", hex::encode(rand::random::<[u8; 16]>()));
        let path = Path::new(&name);
        atomic_write(path, b"relative").unwrap();
        let contents = fs::read(path).unwrap();
        fs::remove_file(path).unwrap();
        assert_eq!(contents, b"relative");
    }

    #[cfg(unix)]
    #[test]
    fn private_unix_modes_and_reused_directory_tightening() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("one/two");
        create_dir_all(&directory).unwrap();
        for path in [root.path().join("one"), directory.clone()] {
            assert_eq!(fs::metadata(path).unwrap().permissions().mode() & 0o7777, 0o700);
        }
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o777)).unwrap();
        create_dir_all(&directory).unwrap();
        assert_eq!(fs::metadata(&directory).unwrap().permissions().mode() & 0o7777, 0o700);
        let file = directory.join("file");
        create_new(&file).unwrap();
        assert_eq!(fs::metadata(&file).unwrap().permissions().mode() & 0o7777, 0o600);
        fs::set_permissions(&file, fs::Permissions::from_mode(0o644)).unwrap();
        atomic_write(&file, b"secret").unwrap();
        assert_eq!(fs::metadata(file).unwrap().permissions().mode() & 0o7777, 0o600);
    }

    #[cfg(unix)]
    #[test]
    fn accepts_trusted_unix_parent_aliases_but_rejects_final_symlinks() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("target");
        fs::write(&target, b"untouched").unwrap();
        let link = root.path().join("link");
        symlink(&target, &link).unwrap();
        assert!(atomic_write(&link, b"bad").is_err());
        assert!(create_new(&link).is_err());
        assert_eq!(fs::read(&target).unwrap(), b"untouched");
        assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        let dangling = root.path().join("dangling");
        symlink(root.path().join("missing"), &dangling).unwrap();
        assert!(atomic_write(&dangling, b"bad").is_err());
        assert!(!root.path().join("missing").exists());
        let directory = root.path().join("real");
        create_dir(&directory).unwrap();
        let ancestor = root.path().join("ancestor");
        symlink(&directory, &ancestor).unwrap();
        create_dir_all(&ancestor.join("nested/deeper")).unwrap();
        assert!(directory.join("nested/deeper").is_dir());
        assert!(create_dir_all(&ancestor).is_err());
        create_new(&ancestor.join("file")).unwrap().write_all(b"old").unwrap();
        atomic_write(&ancestor.join("file"), b"private replacement").unwrap();
        assert_eq!(fs::read(directory.join("file")).unwrap(), b"private replacement");
        let exclusive = ancestor.join("exclusive");
        create_dir(&exclusive).unwrap();
        assert!(directory.join("exclusive").is_dir());
        // The system temp path may itself use aliases (/var on macOS).
        let system_path_file = root.path().join("system-path-file");
        atomic_write(&system_path_file, b"system temporary directory").unwrap();
        assert_eq!(fs::read(system_path_file).unwrap(), b"system temporary directory");
    }

    #[cfg(unix)]
    #[test]
    fn symlink_introduced_before_commit_is_rejected_and_cleaned() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("target");
        fs::write(&target, b"untouched").unwrap();
        let destination = root.path().join("state");
        assert!(atomic_write_with(&destination, |file| {
            file.write_all(b"new")?;
            symlink(&target, &destination)
        }).is_err());
        assert_eq!(fs::read(target).unwrap(), b"untouched");
        assert_eq!(entries(root.path()), [std::ffi::OsString::from("state"), std::ffi::OsString::from("target")]);
    }

    #[cfg(windows)]
    #[test]
    fn windows_files_and_directories_have_protected_owner_only_dacl() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("one/two");
        create_dir_all(&directory).unwrap();
        platform::assert_private_acl(&root.path().join("one"), true);
        platform::assert_private_acl(&directory, true);
        // Reused paths must also receive a protected owner-only DACL.
        create_dir_all(&directory).unwrap();
        platform::assert_private_acl(&directory, true);
        let reused = root.path().join("reused");
        fs::create_dir(&reused).unwrap();
        create_dir_all(&reused).unwrap();
        platform::assert_private_acl(&reused, true);
        let file = directory.join("file");
        let opened = create_new(&file).unwrap();
        platform::assert_private_acl(&file, false); // Inspect before creator closes.
        drop(opened);
        atomic_write(&file, b"private replacement").unwrap();
        platform::assert_private_acl(&file, false);
        let exclusive = directory.join("exclusive");
        create_dir(&exclusive).unwrap();
        platform::assert_private_acl(&exclusive, true);
    }

    #[cfg(windows)]
    #[test]
    fn windows_directory_tightening_cooperates_with_pinned_atomic_writers() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("private");
        create_dir_all(&directory).unwrap();
        // Keep a reader pin alive throughout both workers. Tightening must not
        // conflict with this handle, nor may it require a retry to succeed.
        let pin = platform::Parent::open(&directory).unwrap();
        let barrier = std::sync::Barrier::new(2);
        std::thread::scope(|scope| {
            let tightening = scope.spawn(|| {
                barrier.wait();
                for _ in 0..64 {
                    create_dir_all(&directory).unwrap();
                }
            });
            let writing = scope.spawn(|| {
                barrier.wait();
                for iteration in 0..64 {
                    let reader = platform::Parent::open(&directory).unwrap();
                    atomic_write(&directory.join("state"), &[iteration]).unwrap();
                    drop(reader);
                }
            });
            tightening.join().unwrap();
            writing.join().unwrap();
        });
        drop(pin);
        assert_eq!(fs::read(directory.join("state")).unwrap(), [63]);
        platform::assert_private_acl(&directory, true);
        platform::assert_private_acl(&directory.join("state"), false);
    }

    #[cfg(windows)]
    #[test]
    fn windows_reparse_points_fail_closed() {
        use std::os::windows::fs::{symlink_dir, symlink_file};
        use windows_sys::Win32::Foundation::ERROR_PRIVILEGE_NOT_HELD;
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("target");
        fs::write(&target, b"untouched").unwrap();
        let link = root.path().join("link");
        match symlink_file(&target, &link) {
            Ok(()) => (),
            // Windows CI without Developer Mode cannot create test symlinks.
            // ACL assertions above are unconditional and never silently skipped.
            Err(error) if error.raw_os_error() == Some(ERROR_PRIVILEGE_NOT_HELD as i32) => return,
            Err(error) => panic!("cannot create test symlink: {error}"),
        }
        assert!(atomic_write(&link, b"bad").is_err());
        assert!(create_new(&link).is_err());
        assert_eq!(fs::read(&target).unwrap(), b"untouched");
        let real = root.path().join("real");
        fs::create_dir(&real).unwrap();
        let ancestor = root.path().join("ancestor");
        symlink_dir(&real, &ancestor).unwrap();
        assert!(create_dir_all(&ancestor).is_err());
        assert!(create_dir_all(&ancestor.join("nested")).is_err());
        assert!(create_new(&ancestor.join("file")).is_err());
        assert!(atomic_write(&ancestor.join("file"), b"bad").is_err());
        assert!(entries(&real).is_empty());
    }
}
