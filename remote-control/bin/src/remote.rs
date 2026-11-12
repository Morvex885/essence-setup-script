//! Удалённый демон: `--connect URL`, `--fingerprint SHA256:…`, `--insecure`
//! (и `ESSENCE_RC_CONNECT`, `ESSENCE_RC_FINGERPRINT`, `ESSENCE_RC_INSECURE=1`).
//!
//! Закрепления сертификатов — `<каталог данных>/known-daemons.json`, объект
//! `{"host:port":"SHA256:hex"}`; `--fingerprint` имеет приоритет над файлом.
//! Неизвестный сертификат при живой консоли подтверждается вопросом (ответ
//! `y` закрепляет его), иначе — конверт `daemon_cert_unknown`.

use std::collections::BTreeMap;
use std::env::VarError;
use std::fs::{self, File, TryLockError};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use essence_rc_client::{ConnectError, DaemonClient, RemoteUrl, Trust, valid_fingerprint};
use rc_core::error::{RcError, Result};
use rc_core::secure_fs;
use rc_core::state::StatePaths;

use crate::terminal;

const KNOWN_DAEMONS: &str = "known-daemons.json";
/// Ожидание чужой блокировки файла закреплений.
const LOCK_WAIT: Duration = Duration::from_secs(10);
const LOCK_RETRY: Duration = Duration::from_millis(50);

/// Куда подключаться вместо локального демона.
pub struct Target {
    url: String,
    parsed: RemoteUrl,
    fingerprint: Option<String>,
}

fn usage(message: impl Into<String>) -> RcError {
    RcError::new("usage", message)
}

/// Значение флага: `--имя=значение` либо следующее слово; пустое — `usage`.
/// Следующее слово-флаг (`--connect --json …`) значением не считается и
/// остаётся в argv: режим `--json` определяется и для этой ошибки.
fn flag_value(argv: &mut Vec<String>, index: usize, name: &str) -> Result<String> {
    let word = argv.remove(index);
    let value = match word.split_once('=') {
        Some((_, value)) => value.to_owned(),
        None if index < argv.len() && !argv[index].starts_with("--") => argv.remove(index),
        None => String::new(),
    };
    if value.is_empty() {
        return Err(usage(format!("Укажите значение: {name}.")));
    }
    Ok(value)
}

fn environment(name: &str) -> Result<Option<String>> {
    match std::env::var(name) {
        Ok(value) if value.is_empty() => Err(usage(format!("Переменная {name} пуста."))),
        Ok(value) => Ok(Some(value)),
        Err(VarError::NotPresent) => Ok(None),
        Err(VarError::NotUnicode(_)) => Err(usage(format!("Переменная {name} не в кодировке UTF-8."))),
    }
}

/// Извлечь флаги подключения, стоящие перед командой (до первого слова,
/// которое не флаг; значения глобальных флагов пропускаются); затем
/// переменные окружения. `None` — локальный демон.
pub fn extract(argv: &mut Vec<String>) -> Result<Option<Target>> {
    let (mut connect, mut fingerprint, mut insecure) = (None, None, false);
    let mut index = 0;
    while index < argv.len() {
        let name = argv[index].split_once('=').map_or(argv[index].as_str(), |(name, _)| name).to_owned();
        match name.as_str() {
            "--connect" => connect = Some(flag_value(argv, index, "--connect URL")?),
            "--fingerprint" => fingerprint = Some(flag_value(argv, index, "--fingerprint SHA256:…")?),
            "--insecure" if argv[index] == "--insecure" => {
                argv.remove(index);
                insecure = true;
            }
            _ => match rc_core::cli::global_width(argv, index) {
                Some(width) => index += width,
                None if name.starts_with("--") => index += 1,
                None => break,
            },
        }
    }
    let flagged = connect.is_some();
    let Some(url) = connect.map_or_else(|| environment("ESSENCE_RC_CONNECT"), |url| Ok(Some(url)))? else {
        if fingerprint.is_some() || insecure {
            return Err(usage("Флаги --fingerprint и --insecure применяются только с --connect."));
        }
        return Ok(None);
    };
    let fingerprint = match fingerprint {
        Some(fingerprint) => Some(fingerprint),
        None if flagged => None,
        None => environment("ESSENCE_RC_FINGERPRINT")?,
    };
    if fingerprint.as_deref().is_some_and(|value| !valid_fingerprint(value)) {
        return Err(usage("Отпечаток указывается в виде SHA256:<64 hex>."));
    }
    let insecure = insecure || std::env::var("ESSENCE_RC_INSECURE").is_ok_and(|value| value == "1");
    let parsed = RemoteUrl::parse(&url).map_err(usage)?;
    if !parsed.tls && !parsed.is_loopback() && !insecure {
        return Err(usage("Незашифрованное подключение: укажите https:// или --insecure."));
    }
    Ok(Some(Target { url, parsed, fingerprint }))
}

/// Закрепления: `--fingerprint` для любого адреса подключения, иначе файл.
struct Pins {
    flag: Option<String>,
    file: BTreeMap<String, String>,
}

impl Trust for Pins {
    fn pinned(&self, host_port: &str) -> Option<String> {
        self.flag.clone().or_else(|| self.file.get(host_port).cloned())
    }
}

fn known_daemons() -> Result<PathBuf> {
    Ok(StatePaths::discover()?.root().join(KNOWN_DAEMONS))
}

fn load_pins(path: &PathBuf) -> Result<BTreeMap<String, String>> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map_err(|_| RcError::new("invalid", format!("Файл {} повреждён.", path.display()))),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(BTreeMap::new()),
        Err(error) => Err(RcError::new("failed", format!("Не удалось прочитать {}: {error}", path.display()))),
    }
}

/// Исключительная блокировка чтения-изменения-записи закреплений: блокировка
/// ОС (`flock` / `LockFileEx`) файла `known-daemons.json.lock`. ОС снимает её
/// при закрытии файла, в том числе при падении процесса, поэтому файл не
/// удаляется и брошенных блокировок не бывает.
struct PinLock {
    _file: File,
}

impl PinLock {
    fn acquire(path: &Path) -> Result<Self> {
        let lock = path.with_extension("json.lock");
        let failed = |error: io::Error| RcError::new("failed", format!("Не удалось заблокировать {}: {error}", lock.display()));
        let file = match secure_fs::create_new(&lock) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => open_lock(&lock).map_err(failed)?,
            Err(error) => return Err(failed(error)),
        };
        let deadline = Instant::now() + LOCK_WAIT;
        loop {
            match file.try_lock() {
                Ok(()) => return Ok(Self { _file: file }),
                Err(TryLockError::WouldBlock) if Instant::now() < deadline => std::thread::sleep(LOCK_RETRY),
                Err(TryLockError::WouldBlock) => {
                    return Err(RcError::new("locked", format!("Файл {} занят другим процессом.", path.display())));
                }
                Err(TryLockError::Error(error)) => return Err(failed(error)),
            }
        }
    }
}

/// Существующий файл блокировки: только обычный файл, ссылка не разыменовывается.
fn open_lock(lock: &Path) -> io::Result<File> {
    let mut options = fs::OpenOptions::new();
    options.read(true).write(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::custom_flags(&mut options, libc::O_NOFOLLOW);
    let file = options.open(lock)?;
    if !file.metadata()?.is_file() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "не обычный файл"));
    }
    Ok(file)
}

fn save_pin(path: &PathBuf, host_port: String, fingerprint: String) -> Result<()> {
    let failed = |error: io::Error| RcError::new("failed", format!("Не удалось записать {}: {error}", path.display()));
    if let Some(parent) = path.parent() {
        secure_fs::create_dir_all(parent).map_err(failed)?;
    }
    let _lock = PinLock::acquire(path)?;
    let mut pins = load_pins(path)?;
    pins.insert(host_port, fingerprint);
    let text = serde_json::to_string_pretty(&pins).map_err(|_| RcError::new("failed", "Не удалось записать закрепление."))?;
    secure_fs::atomic_write(path, format!("{text}\n").as_bytes()).map_err(failed)
}

/// Вопрос о неизвестном сертификате; только при живой консоли.
fn confirm_certificate(host_port: &str, fingerprint: &str) -> bool {
    if !terminal::console_available() {
        return false;
    }
    let mut stderr = io::stderr().lock();
    let _ = writeln!(stderr, "  Сертификат демона {host_port} не подтверждён. Отпечаток: {fingerprint}");
    let _ = write!(stderr, "  Доверять этому сертификату? (y/N): ");
    let _ = stderr.flush();
    drop(stderr);
    let mut answer = String::new();
    io::stdin().read_line(&mut answer).is_ok_and(|_| answer.trim().eq_ignore_ascii_case("y"))
}

fn certificate_error(code: &'static str, message: &str, host: String, port: u16, fingerprint: String) -> RcError {
    RcError::new(code, message).with_extra("host", host).with_extra("port", port).with_extra("fingerprint", fingerprint)
}

/// Подключиться к удалённому демону; ошибки — конверты каталога.
pub fn connect(target: &Target) -> Result<DaemonClient> {
    if !target.parsed.tls {
        let _ = writeln!(io::stderr().lock(), "  [!] Соединение не шифруется.");
    }
    let path = known_daemons()?;
    loop {
        // Явный отпечаток задаёт доверие сам: файл закреплений не читается.
        let file = if target.fingerprint.is_some() { BTreeMap::new() } else { load_pins(&path)? };
        let pins = Pins { flag: target.fingerprint.clone(), file };
        match DaemonClient::connect_remote(&target.url, &pins) {
            Ok(client) => return Ok(client),
            Err(ConnectError::CertUnknown { host, port, fingerprint }) => {
                let host_port = target.parsed.host_port();
                if confirm_certificate(&host_port, &fingerprint) {
                    save_pin(&path, host_port, fingerprint)?;
                    continue;
                }
                return Err(certificate_error("daemon_cert_unknown", "Сертификат демона не подтверждён.", host, port, fingerprint));
            }
            Err(ConnectError::CertChanged { host, port, fingerprint }) => {
                return Err(certificate_error("daemon_cert_changed", "Сертификат демона изменился.", host, port, fingerprint));
            }
            Err(error @ ConnectError::Unreachable(_)) => return Err(RcError::new("daemon_unreachable", error.to_string())),
            Err(error @ ConnectError::Protocol(_)) => return Err(RcError::new("daemon_protocol", error.to_string())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(list: &[&str]) -> Vec<String> {
        list.iter().map(|word| (*word).to_owned()).collect()
    }

    fn extracted(list: &[&str]) -> (Result<Option<Target>>, Vec<String>) {
        let mut argv = words(list);
        let target = extract(&mut argv);
        (target, argv)
    }

    #[test]
    fn leading_flags_are_extracted_and_validated() {
        let fp = format!("SHA256:{}", "a".repeat(64));
        let (target, rest) = extracted(&["--json", "--connect", "https://panel.example", &format!("--fingerprint={fp}"), "node", "list", "--connect", "x"]);
        let target = target.unwrap().unwrap();
        assert_eq!((target.url.as_str(), target.fingerprint.as_deref()), ("https://panel.example", Some(fp.as_str())));
        assert_eq!(rest, words(&["--json", "node", "list", "--connect", "x"]));

        let (target, rest) = extracted(&["--connect=http://127.0.0.1:9000", "status"]);
        assert!(!target.unwrap().unwrap().parsed.tls);
        assert_eq!(rest, words(&["status"]));
        let (target, rest) = extracted(&["--insecure", "--connect", "http://10.0.0.5", "status"]);
        assert!(target.unwrap().is_some());
        assert_eq!(rest, words(&["status"]));
        // Значение глобального флага не останавливает поиск --connect.
        let (target, rest) = extracted(&["--yes", "--plan-token", "tok", "--connect", "https://panel.example", "node", "delete"]);
        assert!(target.unwrap().is_some());
        assert_eq!(rest, words(&["--yes", "--plan-token", "tok", "node", "delete"]));

        let code = |list: &[&str]| extracted(list).0.err().map(|error| (error.code, error.message));
        let insecure = code(&["--connect", "http://10.0.0.5", "status"]).unwrap();
        assert_eq!(insecure, ("usage", "Незашифрованное подключение: укажите https:// или --insecure.".to_owned()));
        assert_eq!(code(&["--connect", "https://x", "--fingerprint", "SHA256:abc", "status"]).unwrap().0, "usage");
        assert_eq!(code(&["--connect", "ftp://x", "status"]).unwrap().0, "usage");
        assert_eq!(code(&["--connect"]).unwrap().0, "usage");
        assert_eq!(code(&["--connect=", "status"]).unwrap().0, "usage");
        // Флаг не становится значением и остаётся в argv (JSON-конверт ошибки).
        let (target, rest) = extracted(&["--connect", "--json", "status"]);
        assert_eq!(target.err().map(|error| error.code), Some("usage"));
        assert_eq!(rest, words(&["--json", "status"]));
    }

    #[cfg(unix)]
    #[test]
    fn concurrent_pins_are_all_kept() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::Builder::new().prefix("rc").tempdir_in("/tmp").unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let path = dir.path().join(KNOWN_DAEMONS);
        let writers: Vec<_> = (0..8)
            .map(|index| {
                let path = path.clone();
                std::thread::spawn(move || save_pin(&path, format!("h{index}:1"), format!("SHA256:{index}")).unwrap())
            })
            .collect();
        for writer in writers {
            writer.join().unwrap();
        }
        assert_eq!(load_pins(&path).unwrap().len(), 8);
        // Файл блокировки остаётся, но после закрытия всех дескрипторов свободен.
        drop(PinLock::acquire(&path).unwrap());
        assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    }

    #[test]
    fn pins_prefer_the_flag() {
        let pins = Pins { flag: None, file: BTreeMap::from([("h:1".to_owned(), "SHA256:f".to_owned())]) };
        assert_eq!(pins.pinned("h:1").as_deref(), Some("SHA256:f"));
        assert_eq!(pins.pinned("h:2"), None);
        let pins = Pins { flag: Some("SHA256:x".into()), ..pins };
        assert_eq!(pins.pinned("h:1").as_deref(), Some("SHA256:x"));
    }
}
