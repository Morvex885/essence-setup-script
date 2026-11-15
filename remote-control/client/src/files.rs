//! Files on the client's machine: request inputs (`@name` of the catalog) are
//! read and template exports written here; the daemon never sees client paths.
use std::fs::{File, OpenOptions};
use std::io::{self, ErrorKind, Read, Write};
use std::path::Path;
use zeroize::Zeroizing;

/// Largest request input value in bytes (the daemon's `input` limit).
pub const MAX_INPUT: usize = 1 << 20;

/// Why an input file was refused.
#[derive(Debug, PartialEq, Eq)]
pub enum InputFileError {
    /// Missing, unreadable, a link, a directory or another non-regular entry.
    Unavailable,
    /// Larger than [`MAX_INPUT`].
    TooLarge,
    NotUtf8,
}

/// Opens `path` without following a final symlink and accepts only a regular
/// file; the type is checked on the opened handle, so no race with the path.
fn open_regular(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // O_NONBLOCK: a FIFO in place of the file must not hang the open.
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        /// Opens a reparse point (symlink, junction) itself instead of its target.
        const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
        options.custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let file = options.open(path)?;
    if !file.metadata()?.file_type().is_file() {
        return Err(io::Error::new(ErrorKind::InvalidInput, "не обычный файл"));
    }
    Ok(file)
}

/// The UTF-8 text of a regular file of at most [`MAX_INPUT`] bytes. Never
/// reads more than one byte past the limit; every buffer is wiped.
pub fn read_input_file(path: &Path) -> Result<Zeroizing<String>, InputFileError> {
    let mut file = open_regular(path).map_err(|_| InputFileError::Unavailable)?;
    // A fixed buffer: growing a vector would leave unwiped copies behind.
    let mut bytes = Zeroizing::new(vec![0u8; MAX_INPUT + 1]);
    let mut filled = 0;
    while filled < bytes.len() {
        match file.read(&mut bytes[filled..]) {
            Ok(0) => break,
            Ok(count) => filled += count,
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(_) => return Err(InputFileError::Unavailable),
        }
    }
    if filled > MAX_INPUT {
        return Err(InputFileError::TooLarge);
    }
    let text = std::str::from_utf8(&bytes[..filled]).map_err(|_| InputFileError::NotUtf8)?;
    let mut owned = Zeroizing::new(String::with_capacity(text.len()));
    owned.push_str(text);
    Ok(owned)
}

/// The refusal of a recovery key file inside the data directory; the same
/// code (`invalid`) and text as the core's former check.
pub const RECOVERY_KEY_REFUSED: &str = "Не удалось импортировать ключ восстановления: файл ключа восстановления не найден, имеет недопустимый тип или расположен внутри служебного каталога.";

/// `path` lies inside `data_dir`: the file resolved (or its directory plus
/// name) against the data directory resolved like the daemon endpoint.
pub fn inside_data_dir(path: &Path, data_dir: &Path) -> bool {
    let candidate = std::fs::canonicalize(path).ok().or_else(|| {
        let name = path.file_name()?;
        std::fs::canonicalize(path.parent()?).ok().map(|parent| parent.join(name))
    });
    let Ok(data_dir) = std::path::absolute(data_dir) else { return false };
    candidate.is_some_and(|candidate| candidate.starts_with(crate::endpoint::resolved(&data_dir)))
}

/// Publishes `bytes` at `path`: a fresh temporary file in the same directory,
/// `sync_all`, a rename, then (Unix) the directory entry is synced. With
/// `replace` an existing entry — a link too — is replaced, never followed;
/// without it an entry that appeared meanwhile is kept (`AlreadyExists`).
pub fn write_file_atomic(path: &Path, bytes: &[u8], replace: bool) -> io::Result<()> {
    let parent = path.parent().filter(|parent| !parent.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let mut file = tempfile::Builder::new().prefix(".rc-export-").tempfile_in(parent)?;
    file.write_all(bytes)?;
    file.as_file().sync_all()?;
    if replace { file.persist(path) } else { file.persist_noclobber(path) }.map_err(|error| error.error)?;
    #[cfg(unix)]
    File::open(parent)?.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn files_inside_the_data_directory_are_detected_through_links() {
        let base = tempfile::tempdir().unwrap();
        let data = base.path().join("data");
        fs::create_dir_all(data.join("credentials")).unwrap();
        let key = data.join("credentials/key.txt");
        fs::write(&key, "AGE-SECRET-KEY-1\n").unwrap();
        let outside = base.path().join("key.txt");
        fs::write(&outside, "AGE-SECRET-KEY-1\n").unwrap();
        assert!(inside_data_dir(&key, &data));
        assert!(inside_data_dir(&data.join("absent.txt"), &data), "a missing name in the directory");
        assert!(!inside_data_dir(&outside, &data));
        assert!(!inside_data_dir(&base.path().join("data-other.txt"), &data), "a common prefix is not containment");
        #[cfg(unix)]
        {
            let alias = base.path().join("alias");
            std::os::unix::fs::symlink(&data, &alias).unwrap();
            assert!(inside_data_dir(&alias.join("credentials/key.txt"), &data), "the file through a link to the data directory");
            assert!(inside_data_dir(&key, &alias), "the data directory spelled through a link");
        }
    }

    #[test]
    fn inputs_are_bounded_regular_utf8_files() {
        let dir = tempfile::tempdir().unwrap();
        let text = dir.path().join("t.yaml");
        fs::write(&text, "mode: rule\n").unwrap();
        assert_eq!(read_input_file(&text).unwrap().as_str(), "mode: rule\n");
        let limit = dir.path().join("limit");
        fs::write(&limit, vec![b'a'; MAX_INPUT]).unwrap();
        assert_eq!(read_input_file(&limit).unwrap().len(), MAX_INPUT);
        let large = dir.path().join("large");
        fs::write(&large, vec![b'a'; MAX_INPUT + 1]).unwrap();
        assert_eq!(read_input_file(&large).err(), Some(InputFileError::TooLarge));
        let binary = dir.path().join("bin");
        fs::write(&binary, [0xff, 0x00]).unwrap();
        assert_eq!(read_input_file(&binary).err(), Some(InputFileError::NotUtf8));
        assert_eq!(read_input_file(dir.path()).err(), Some(InputFileError::Unavailable));
        assert_eq!(read_input_file(&dir.path().join("absent")).err(), Some(InputFileError::Unavailable));
    }

    #[cfg(unix)]
    #[test]
    fn input_links_and_fifos_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("t.yaml");
        fs::write(&target, "mode: rule\n").unwrap();
        let link = dir.path().join("link.yaml");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert_eq!(read_input_file(&link).err(), Some(InputFileError::Unavailable));
        let fifo = dir.path().join("fifo");
        let name = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        // SAFETY: a valid NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        assert_eq!(read_input_file(&fifo).err(), Some(InputFileError::Unavailable));
    }

    #[test]
    fn exports_replace_only_when_allowed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("out.yaml");
        write_file_atomic(&path, b"first\n", false).unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"first\n");
        assert_eq!(write_file_atomic(&path, b"second\n", false).unwrap_err().kind(), ErrorKind::AlreadyExists);
        assert_eq!(fs::read(&path).unwrap(), b"first\n", "an unconfirmed entry is kept");
        write_file_atomic(&path, b"second\n", true).unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"second\n");
        let leftovers = fs::read_dir(dir.path()).unwrap().filter(|entry| {
            entry.as_ref().unwrap().file_name().to_string_lossy().starts_with(".rc-export-")
        });
        assert_eq!(leftovers.count(), 0, "temporary files are removed");
    }
}
