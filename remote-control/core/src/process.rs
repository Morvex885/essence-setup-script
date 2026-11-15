//! Native process birth identities. An inaccessible process is never presumed dead.
//!
//! Linux/Android use `/proc` start ticks and boot ID when readable. If Android
//! restricts boot_id, unavailable boot identity conservatively prevents reclaim
//! when start ticks match; it does not block acquisition. Actual Android device
//! behavior must be exercised by integration, not inferred from host tests. macOS uses
//! `proc_pidinfo` start time; Windows uses the process creation FILETIME. No shell
//! or child process participates in lock-owner discovery.

use serde::{Deserialize, Serialize};
use std::io;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProcessIdentity {
    pub pid: u32,
    pub birth: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProcessState {
    Alive,
    Dead,
    /// Permissions, unsupported platform, or an indeterminate native query.
    Unknown,
}

impl ProcessIdentity {
    pub fn current() -> io::Result<Self> {
        let pid = std::process::id();
        match native::inspect(pid)? {
            Some(birth) => Ok(Self { pid, birth }),
            None => Err(io::Error::other("Cannot determine current process birth identity")),
        }
    }

    pub fn is_valid(&self) -> bool {
        if self.pid == 0 {
            return false;
        }
        let number = |value: &str| !value.is_empty()
            && (value.len() == 1 || !value.starts_with('0'))
            && value.bytes().all(|byte| byte.is_ascii_digit())
            && value.parse::<u64>().is_ok();
        let mut fields = self.birth.split(':');
        let valid = match (fields.next(), fields.next(), fields.next()) {
            (Some("linux"), Some(boot), Some(ticks)) => {
                (boot == "unavailable" || valid_boot_id(boot))
                    && number(ticks)
            }
            (Some("macos"), Some(seconds), Some(micros)) => number(seconds) && number(micros),
            (Some("windows"), Some(ticks), None) => number(ticks),
            _ => false,
        };
        valid && fields.next().is_none()
    }

    /// A different birth identity proves that the original owner has died, even
    /// when its PID now names a live, unrelated process.
    pub fn state(&self) -> ProcessState {
        if !self.is_valid() {
            return ProcessState::Unknown;
        }
        self.state_from_inspection(native::inspect(self.pid))
    }

    fn state_from_inspection(&self, inspected: io::Result<Option<String>>) -> ProcessState {
        match inspected {
            Ok(Some(birth)) if same_birth(&birth, &self.birth) => ProcessState::Alive,
            Ok(_) => ProcessState::Dead,
            Err(_) => ProcessState::Unknown,
        }
    }
}

fn valid_boot_id(boot: &str) -> bool {
    boot.len() == 36 && boot.bytes().enumerate().all(|(index, byte)| {
        if matches!(index, 8 | 13 | 18 | 23) { byte == b'-' }
        else { byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte) }
    })
}

fn same_birth(left: &str, right: &str) -> bool {
    if let (Some(left), Some(right)) = (left.strip_prefix("linux:"), right.strip_prefix("linux:")) {
        if let (Some((left_boot, left_ticks)), Some((right_boot, right_ticks))) = (left.rsplit_once(':'), right.rsplit_once(':')) {
            // Android may deny boot_id even when per-process stat is readable.
            // Missing boot identity can only make us more conservative: equal
            // start ticks remain live, never permission-based reclaim.
            return left_ticks == right_ticks
                && (left_boot == right_boot || left_boot == "unavailable" || right_boot == "unavailable");
        }
    }
    left == right
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod native {
    use std::{fs, io};

    pub(super) fn inspect(pid: u32) -> io::Result<Option<String>> {
        let stat = match fs::read_to_string(format!("/proc/{pid}/stat")) {
            Ok(stat) => stat,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                // A missing /proc mount is not evidence that a process died.
                fs::metadata("/proc/self/stat")?;
                return Ok(None);
            }
            Err(error) => return Err(error),
        };
        let Some((state, start)) = parse_stat(&stat) else {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "Malformed /proc process stat"));
        };
        if matches!(state, "Z" | "X" | "x") {
            return Ok(None);
        }
        Ok(Some(birth_with_boot(start, fs::read_to_string("/proc/sys/kernel/random/boot_id"))))
    }

    fn birth_with_boot(start: u64, boot: io::Result<String>) -> String {
        let boot = boot.as_deref().unwrap_or("").trim();
        let boot = if super::valid_boot_id(boot) { boot } else { "unavailable" };
        format!("linux:{boot}:{start}")
    }

    pub(super) fn parse_stat(stat: &str) -> Option<(&str, u64)> {
        // comm can contain spaces and ')' characters; only the final ')' ends it.
        let (_, fields) = stat.rsplit_once(") ")?;
        let mut fields = fields.split_ascii_whitespace();
        let state = fields.next()?;
        let start = fields.nth(18)?.parse().ok()?;
        Some((state, start))
    }

    #[cfg(test)]
    mod tests {
        #[test]
        fn boot_id_denial_keeps_own_stat_usable() {
            let birth = super::birth_with_boot(42, Err(std::io::Error::new(std::io::ErrorKind::PermissionDenied, "restricted boot_id")));
            assert_eq!(birth, "linux:unavailable:42");
            assert!(super::super::ProcessIdentity { pid: 1, birth }.is_valid());
            assert_eq!(super::birth_with_boot(42, Ok(String::new())), "linux:unavailable:42");
            assert_eq!(super::birth_with_boot(42, Ok("not-a-uuid".into())), "linux:unavailable:42");
        }

        #[test]
        fn parses_names_with_spaces_and_parentheses() {
            let fields = "S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 12345";
            assert_eq!(super::parse_stat(&format!("42 (a ) tricky name) {fields}")), Some(("S", 12345)));
            assert_eq!(super::parse_stat("malformed"), None);
        }

        proptest::proptest! {
            #[test]
            fn generated_comm_and_starttime_roundtrip(
                name in proptest::collection::vec(proptest::char::any(), 0..80),
                start in proptest::prelude::any::<u64>(),
            ) {
                let name: String = name.into_iter().collect();
                let stat = format!("42 ({name}) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 {start}");
                proptest::prop_assert_eq!(super::parse_stat(&stat), Some(("S", start)));
            }

            #[test]
            fn truncated_stat_cannot_supply_birth_identity(field_count in 0usize..19) {
                let fields = std::iter::repeat_n("1", field_count).collect::<Vec<_>>().join(" ");
                let stat = format!("42 (name) S {fields}");
                proptest::prop_assert_eq!(super::parse_stat(&stat), None);
            }
        }
    }
}

#[cfg(target_os = "macos")]
mod native {
    use std::{io, mem};

    pub(super) fn inspect(pid: u32) -> io::Result<Option<String>> {
        let pid = i32::try_from(pid).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "Invalid PID"))?;
        let mut info = mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
        // SAFETY: info points to a correctly sized writable native structure.
        let size = unsafe {
            libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, info.as_mut_ptr().cast(), mem::size_of::<libc::proc_bsdinfo>() as i32)
        };
        if size != mem::size_of::<libc::proc_bsdinfo>() as i32 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                return Ok(None);
            }
            return Err(error);
        }
        // SAFETY: proc_pidinfo initialized the entire structure on success.
        let info = unsafe { info.assume_init() };
        if info.pbi_status == libc::SZOMB as u32 {
            return Ok(None);
        }
        Ok(Some(format!("macos:{}:{}", info.pbi_start_tvsec, info.pbi_start_tvusec)))
    }
}

#[cfg(windows)]
mod native {
    use std::{io, mem};
    use windows_sys::Win32::{
        Foundation::{CloseHandle, ERROR_INVALID_PARAMETER, FILETIME, WAIT_OBJECT_0, WAIT_TIMEOUT},
        System::Threading::{GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, WaitForSingleObject},
    };

    pub(super) fn inspect(pid: u32) -> io::Result<Option<String>> {
        // Query-limited + synchronize are the minimum rights needed for birth
        // identity and a zero-time wait. Access denied always stays fail-closed.
        let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE, 0, pid) };
        if handle.is_null() {
            let error = io::Error::last_os_error();
            return if error.raw_os_error() == Some(ERROR_INVALID_PARAMETER as i32) {
                Ok(None)
            } else {
                Err(error)
            };
        }
        let result = (|| {
            match unsafe { WaitForSingleObject(handle, 0) } {
                WAIT_OBJECT_0 => return Ok(None),
                WAIT_TIMEOUT => {}
                _ => return Err(io::Error::last_os_error()),
            }
            let mut creation: FILETIME = unsafe { mem::zeroed() };
            let mut exit: FILETIME = unsafe { mem::zeroed() };
            let mut kernel: FILETIME = unsafe { mem::zeroed() };
            let mut user: FILETIME = unsafe { mem::zeroed() };
            if unsafe { GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user) } == 0 {
                return Err(io::Error::last_os_error());
            }
            let ticks = ((creation.dwHighDateTime as u64) << 32) | creation.dwLowDateTime as u64;
            Ok(Some(format!("windows:{ticks}")))
        })();
        unsafe { CloseHandle(handle) };
        result
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_os = "macos", windows)))]
mod native {
    use std::io;
    pub(super) fn inspect(_: u32) -> io::Result<Option<String>> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "Native process birth identity is unavailable on this platform"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_process_is_alive_and_pid_reuse_is_detected() {
        let identity = ProcessIdentity::current().unwrap();
        assert_eq!(identity.state(), ProcessState::Alive);
        let (prefix, ticks) = identity.birth.rsplit_once(':').unwrap();
        let reused = ProcessIdentity { birth: format!("{prefix}:{}", ticks.parse::<u64>().unwrap() + 1), ..identity };
        assert_eq!(reused.state(), ProcessState::Dead);
    }

    #[test]
    fn invalid_identity_is_not_reclaimable() {
        assert_eq!(ProcessIdentity { pid: 0, birth: String::new() }.state(), ProcessState::Unknown);
    }

    #[test]
    fn linux_boot_visibility_changes_never_imply_owner_death() {
        let boot = "01234567-89ab-cdef-0123-456789abcdef";
        let other_boot = "11234567-89ab-cdef-0123-456789abcdef";
        let known = ProcessIdentity { pid: 1, birth: format!("linux:{boot}:42") };
        let unknown = ProcessIdentity { pid: 1, birth: "linux:unavailable:42".into() };
        assert!(known.is_valid());
        assert!(unknown.is_valid());
        assert_eq!(known.state_from_inspection(Ok(Some(unknown.birth.clone()))), ProcessState::Alive);
        assert_eq!(unknown.state_from_inspection(Ok(Some(known.birth.clone()))), ProcessState::Alive);
        assert_eq!(known.state_from_inspection(Ok(Some(format!("linux:{other_boot}:42")))), ProcessState::Dead);
        assert_eq!(unknown.state_from_inspection(Ok(Some(format!("linux:{boot}:43")))), ProcessState::Dead);
        assert_eq!(known.state_from_inspection(Ok(Some("linux:unavailable:43".into()))), ProcessState::Dead);
    }

    #[test]
    fn denied_and_indeterminate_native_queries_are_not_reclaimable() {
        let identity = ProcessIdentity { pid: 4, birth: "windows:1".into() };
        assert!(identity.is_valid());
        for kind in [io::ErrorKind::PermissionDenied, io::ErrorKind::Interrupted, io::ErrorKind::Other] {
            assert_eq!(identity.state_from_inspection(Err(io::Error::new(kind, "native query failed"))), ProcessState::Unknown);
        }
    }

    proptest::proptest! {
        #[test]
        fn generated_birth_identities_validate(pid in 1u32..u32::MAX, ticks in proptest::prelude::any::<u64>()) {
            let identity = ProcessIdentity { pid, birth: format!("windows:{ticks}") };
            proptest::prop_assert!(identity.is_valid());
            let malformed = ProcessIdentity { birth: format!("{}:extra", identity.birth), ..identity };
            proptest::prop_assert!(!malformed.is_valid());
        }

        #[test]
        fn unrecognized_birth_formats_are_not_reclaimable(value in "[a-zA-Z0-9]{0,100}") {
            let identity = ProcessIdentity { pid: 1, birth: value };
            proptest::prop_assert!(!identity.is_valid());
            proptest::prop_assert_eq!(identity.state(), ProcessState::Unknown);
        }
    }
}
