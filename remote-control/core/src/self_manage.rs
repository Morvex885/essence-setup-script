//! Native self-management: version check, self-update and uninstall.
//!
//! `version` performs one read-only GitHub API request; network problems
//! degrade to `checked:false, latest:null`, never to a command failure.
//! `prepare_update` resolves release metadata only — no download and no
//! mutation happens before the caller confirms the returned [`Plan`].
//! `apply` then downloads the target asset, verifies it against the release
//! `SHA256SUMS` and atomically replaces the running executable natively:
//! same-directory rename on Unix, rename-aside + atomic publish with rollback
//! on Windows. Uninstall removes only the current executable and the
//! schema-v2 ESSENCE data root; Bash-era directories are never touched.
//! The optional GitHub token is read once, held in memory and sent as a
//! request header; no subprocess, curl or environment is passed to children.

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

use crate::confirmation::Plan;
use crate::error::{RcError, Result};
use crate::state::State;
use crate::VERSION;

/// Release repository, matching the v1 `_REPO` constant.
const REPO: &str = "Morvex885/essence-setup-script";
const API_BASE: &str = "https://api.github.com";

const METADATA_TIMEOUT: Duration = Duration::from_secs(5);
const METADATA_CONNECT: Duration = Duration::from_secs(3);
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(600);
const DOWNLOAD_CONNECT: Duration = Duration::from_secs(10);

const MAX_CHECKSUMS_BYTES: u64 = 1 << 20;
const MAX_ASSET_BYTES: u64 = 1 << 30;
const MAX_BINARY_BYTES: u64 = 1 << 30;

// ─── Release target identity ────────────────────────────────────────────────

/// Map a build triple (os, arch, env) to the release matrix target name.
/// `None` means the platform is not part of the 8-target release matrix.
fn target_triple_for(os: &str, arch: &str, env: Option<&str>) -> Option<&'static str> {
    match (os, arch, env) {
        ("linux", "x86_64", _) => Some("x86_64-unknown-linux-gnu"),
        ("linux", "aarch64", Some("musl")) => Some("aarch64-unknown-linux-musl"),
        ("linux", "aarch64", _) => Some("aarch64-unknown-linux-gnu"),
        ("linux", "arm", _) => Some("armv7-unknown-linux-gnueabihf"),
        ("macos", "x86_64", _) => Some("x86_64-apple-darwin"),
        ("macos", "aarch64", _) => Some("aarch64-apple-darwin"),
        ("windows", "x86_64", _) => Some("x86_64-pc-windows-msvc"),
        ("windows", "aarch64", _) => Some("aarch64-pc-windows-msvc"),
        _ => None,
    }
}

/// Target identity from the build environment of this exact binary.
fn release_target() -> Option<&'static str> {
    // armv7 hard-float is target_env "gnu" (abi "eabihf"), not a separate env.
    let env = if cfg!(target_env = "musl") {
        Some("musl")
    } else if cfg!(target_env = "msvc") {
        Some("msvc")
    } else if cfg!(target_env = "gnu") {
        Some("gnu")
    } else {
        None
    };
    target_triple_for(std::env::consts::OS, std::env::consts::ARCH, env)
}

/// Planned release asset archive name for a target (step 9 layout).
fn asset_name(target: &str) -> String {
    if target.contains("windows") {
        format!("essence-rc-{target}.zip")
    } else {
        format!("essence-rc-{target}.tar.gz")
    }
}

/// Binary file name inside the asset archive for a target.
fn binary_name_for(target: &str) -> &'static str {
    if target.contains("windows") { "essence-rc.exe" } else { "essence-rc" }
}

fn unsupported_target_error() -> RcError {
    RcError::new("update_failed", "Эта платформа не входит в матрицу релизов.")
        .with_extra("stage", "target")
        .with_extra("os", std::env::consts::OS)
        .with_extra("arch", std::env::consts::ARCH)
}

// ─── GitHub metadata (reqwest + rustls, token in memory only) ───────────────

fn user_agent() -> String {
    format!("essence-rc/{VERSION}")
}

fn github_token() -> Option<Zeroizing<String>> {
    std::env::var("GITHUB_TOKEN")
        .ok()
        .filter(|token| !token.is_empty())
        .map(Zeroizing::new)
}

fn apply_auth(mut request: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
    if let Some(token) = github_token() {
        request = request.bearer_auth(token.as_str());
    }
    request
}

struct Release {
    tag: String,
    /// (asset name, browser_download_url)
    assets: Vec<(String, String)>,
}

enum ReleaseError {
    Network,
    NotFound,
    Shape,
}

fn metadata_client() -> reqwest::Result<reqwest::Client> {
    reqwest::Client::builder()
        .timeout(METADATA_TIMEOUT)
        .connect_timeout(METADATA_CONNECT)
        .user_agent(user_agent())
        .build()
}

/// Read-only `releases/latest` lookup. Never fails the command by itself.
async fn fetch_latest_release() -> std::result::Result<Release, ReleaseError> {
    let url = format!("{API_BASE}/repos/{REPO}/releases/latest");
    let client = metadata_client().map_err(|_| ReleaseError::Network)?;
    let response = apply_auth(client.get(&url))
        .send()
        .await
        .map_err(|_| ReleaseError::Network)?;
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        return Err(ReleaseError::NotFound);
    }
    let response = response.error_for_status().map_err(|_| ReleaseError::Network)?;
    let body: Value = response.json().await.map_err(|_| ReleaseError::Shape)?;
    let tag = body
        .get("tag_name")
        .and_then(Value::as_str)
        .map(str::trim)
        .ok_or(ReleaseError::Shape)?;
    if tag.is_empty() || tag.bytes().any(|b| b < 0x20 || b == 0x7f) {
        return Err(ReleaseError::Shape);
    }
    let assets = body
        .get("assets")
        .and_then(Value::as_array)
        .ok_or(ReleaseError::Shape)?
        .iter()
        .filter_map(|asset| {
            let name = asset.get("name")?.as_str()?.trim().to_string();
            let url = asset.get("browser_download_url")?.as_str()?.trim().to_string();
            (!name.is_empty() && !url.is_empty()).then_some((name, url))
        })
        .collect();
    Ok(Release { tag: tag.to_string(), assets })
}

fn release_metadata_error(error: ReleaseError) -> RcError {
    match error {
        ReleaseError::Network => RcError::new(
            "update_failed",
            "Не удалось получить данные последнего релиза. Проверьте сеть.",
        )
        .with_extra("stage", "metadata"),
        ReleaseError::NotFound => RcError::new("update_failed", "Релизы недоступны.")
            .with_extra("stage", "metadata")
            .with_extra("status", 404),
        ReleaseError::Shape => RcError::new(
            "update_failed",
            "Неожиданный формат ответа GitHub.",
        )
        .with_extra("stage", "metadata"),
    }
}

fn download_error(asset: &str, stage: &str) -> RcError {
    RcError::new("update_failed", "Не удалось скачать файл релиза.")
        .with_extra("asset", asset)
        .with_extra("stage", stage)
}

async fn download_bytes(url: &str, asset: &str, cap: u64) -> Result<Vec<u8>> {
    let client = reqwest::Client::builder()
        .timeout(DOWNLOAD_TIMEOUT)
        .connect_timeout(DOWNLOAD_CONNECT)
        .user_agent(user_agent())
        .build()
        .map_err(|_| download_error(asset, "client"))?;
    let response = apply_auth(client.get(url))
        .send()
        .await
        .map_err(|_| download_error(asset, "network"))?;
    let response = response
        .error_for_status()
        .map_err(|_| download_error(asset, "status"))?;
    let bytes = response
        .bytes()
        .await
        .map_err(|_| download_error(asset, "read"))?;
    if bytes.len() as u64 > cap {
        return Err(download_error(asset, "size"));
    }
    Ok(bytes.to_vec())
}

// ─── Helpers ────────────────────────────────────────────────────────────────

fn strip_v(version: &str) -> &str {
    version.strip_prefix('v').unwrap_or(version)
}

fn newer_than(candidate: &str, current: &str) -> bool {
    match (
        semver::Version::parse(strip_v(candidate.trim())),
        semver::Version::parse(strip_v(current.trim())),
    ) {
        (Ok(candidate), Ok(current)) => candidate > current,
        _ => false,
    }
}

fn current_exe_path() -> Result<PathBuf> {
    std::env::current_exe()
        .map_err(|_| RcError::new("failed", "Не удалось определить путь исполняемого файла."))
}

fn update_failed_io(stage: &str) -> RcError {
    RcError::new("update_failed", "Не удалось заменить исполняемый файл.")
        .with_extra("stage", stage)
}

/// Parse `SHA256SUMS` content into a lowercase map by file name.
fn parse_checksums(bytes: &[u8]) -> BTreeMap<String, String> {
    let text = String::from_utf8_lossy(bytes);
    let mut sums = BTreeMap::new();
    for line in text.lines() {
        let line = line.trim_end_matches('\r').trim();
        let mut parts = line.split_whitespace();
        let (Some(digest), Some(name)) = (parts.next(), parts.next()) else {
            continue;
        };
        if digest.len() != 64 || !digest.bytes().all(|b| b.is_ascii_hexdigit()) {
            continue;
        }
        let name = name.trim_start_matches('*').trim_start_matches("./");
        if name.is_empty() {
            continue;
        }
        sums.insert(name.to_string(), digest.to_ascii_lowercase());
    }
    sums
}

fn read_capped<R: Read>(reader: &mut R, cap: u64) -> io::Result<Vec<u8>> {
    let mut buffer = Vec::new();
    reader.take(cap + 1).read_to_end(&mut buffer)?;
    if buffer.len() as u64 > cap {
        return Err(io::Error::new(io::ErrorKind::FileTooLarge, "файл больше допустимого размера"));
    }
    Ok(buffer)
}

/// Why a candidate data root must never be removed.
fn data_unsafe_reason(data: &Path, home: &Path, exe: &Path) -> Option<&'static str> {
    if data.parent().is_none() {
        return Some("корень файловой системы");
    }
    if data == home {
        return Some("домашний каталог");
    }
    if home.starts_with(data) {
        return Some("родительский каталог домашнего каталога");
    }
    if exe == data || exe.starts_with(data) {
        return Some("родительский каталог исполняемого файла");
    }
    if let Some(name) = data.file_name().and_then(|name| name.to_str()) {
        if name == ".remote-data" || name == "remote-control-essence" {
            return Some("каталог данных установленной Bash-версии");
        }
    }
    None
}

fn unsafe_data_path(path: &Path, reason: &str) -> RcError {
    RcError::new("unsafe_path", "Небезопасный путь локальных данных. Удаление отменено.")
        .with_extra("path", path.display().to_string())
        .with_extra("reason", reason)
}

// ─── self version ───────────────────────────────────────────────────────────

/// Current and latest release version. Network unavailability degrades to
/// `checked:false, latest:null`; the command itself never fails on it.
pub async fn version() -> Result<Value> {
    let latest = match fetch_latest_release().await {
        Ok(release) => Some(release.tag),
        Err(_) => None,
    };
    let checked = latest.is_some();
    let update_available = latest
        .as_deref()
        .map(|latest| newer_than(latest, VERSION))
        .unwrap_or(false);
    Ok(json!({
        "current": VERSION,
        "latest": latest,
        "update_available": update_available,
        "checked": checked,
    }))
}

// ─── self update ────────────────────────────────────────────────────────────

/// v1 always demanded root because it owned `/usr/local/bin` and `/opt`. The
/// native binary may also live in a user directory (Termux, `~/.local/bin`):
/// root is required only when the executable's directory is not writable.
#[cfg(unix)]
fn ensure_root(exe: &Path, action: &str, command: &str) -> Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let writable = exe.parent().is_some_and(|dir| {
        std::ffi::CString::new(dir.as_os_str().as_bytes())
            .is_ok_and(|dir| unsafe { libc::access(dir.as_ptr(), libc::W_OK) } == 0)
    });
    if !writable && unsafe { libc::geteuid() } != 0 {
        return Err(RcError::new(
            "root_required",
            format!("Для {action} нужен root: sudo essence-rc self {command}"),
        ));
    }
    Ok(())
}

#[cfg(not(unix))]
fn ensure_root(_exe: &Path, _action: &str, _command: &str) -> Result<()> {
    Ok(())
}

struct UpdateIntent {
    exe: PathBuf,
    target: &'static str,
    asset_name: String,
    asset_url: String,
    sums_url: String,
    tag: String,
}

/// Prepared update: metadata only, read-only. The caller must run
/// `plan.confirm(...)` before `apply` performs any download or mutation.
pub struct UpdatePlan {
    pub plan: Plan,
    intent: UpdateIntent,
}

pub async fn prepare_update() -> Result<UpdatePlan> {
    let exe = current_exe_path()?;
    ensure_root(&exe, "обновления", "update")?;
    let target = release_target().ok_or_else(unsupported_target_error)?;
    let asset = asset_name(target);
    let release = fetch_latest_release()
        .await
        .map_err(release_metadata_error)?;
    let find = |name: &str| {
        release
            .assets
            .iter()
            .find(|(asset_name, _)| asset_name == name)
            .map(|(_, url)| url.clone())
    };
    let asset_url = find(&asset).ok_or_else(|| {
        RcError::new("update_failed", "В последнем релизе нет файла для этой платформы.")
            .with_extra("asset", asset.clone())
            .with_extra("target", target)
    })?;
    let sums_url = find("SHA256SUMS").ok_or_else(|| {
        RcError::new("update_failed", "В последнем релизе нет контрольных сумм SHA256SUMS.")
            .with_extra("target", target)
    })?;
    let lines = vec![
        format!("Текущая версия: {VERSION}."),
        format!("Будет установлена версия {}.", strip_v(&release.tag)),
        format!("Платформа: {target} ({asset})."),
        format!("Бинарник {} будет заменён.", exe.display()),
        "Целостность проверяется по SHA256SUMS релиза.".to_string(),
    ];
    Ok(UpdatePlan {
        plan: Plan::new(lines, ""),
        intent: UpdateIntent {
            exe,
            target,
            asset_name: asset,
            asset_url,
            sums_url,
            tag: release.tag,
        },
    })
}

impl UpdatePlan {
    /// Download the verified asset and atomically replace the running binary.
    /// Must only run after the owner confirmed `plan`.
    pub async fn apply(self) -> Result<Value> {
        let intent = self.intent;
        let sums = download_bytes(&intent.sums_url, "SHA256SUMS", MAX_CHECKSUMS_BYTES).await?;
        let expected = parse_checksums(&sums).remove(&intent.asset_name).ok_or_else(|| {
            RcError::new("update_failed", "В SHA256SUMS нет записи для файла этой платформы.")
                .with_extra("asset", intent.asset_name.clone())
        })?;
        let archive =
            download_bytes(&intent.asset_url, &intent.asset_name, MAX_ASSET_BYTES).await?;
        let actual = hex::encode(Sha256::digest(&archive));
        if !actual.eq_ignore_ascii_case(&expected) {
            return Err(RcError::new("update_failed", "Контрольная сумма файла не совпадает.")
                .with_extra("asset", intent.asset_name)
                .with_extra("expected", expected)
                .with_extra("actual", actual));
        }
        let binary = extract_binary(
            &archive,
            &intent.asset_name,
            binary_name_for(intent.target),
            MAX_BINARY_BYTES,
        )
        .map_err(|_| {
            RcError::new("update_failed", "В архиве релиза нет исполняемого файла.")
                .with_extra("asset", intent.asset_name)
                .with_extra("stage", "extract")
        })?;
        replace_binary(&intent.exe, &binary)?;
        Ok(json!({
            "from": VERSION,
            "to": strip_v(&intent.tag),
            "restart_required": true,
        }))
    }
}

fn extract_binary(
    archive: &[u8],
    asset: &str,
    binary: &str,
    cap: u64,
) -> io::Result<Vec<u8>> {
    if asset.ends_with(".zip") {
        extract_from_zip(archive, binary, cap)
    } else {
        extract_from_targz(archive, binary, cap)
    }
}

fn extract_from_targz(archive: &[u8], binary: &str, cap: u64) -> io::Result<Vec<u8>> {
    let decoder = flate2::read::GzDecoder::new(io::Cursor::new(archive));
    let mut tar = tar::Archive::new(decoder);
    let mut by_name = None;
    for entry in tar.entries()? {
        let mut entry = entry?;
        if !matches!(
            entry.header().entry_type(),
            tar::EntryType::Regular | tar::EntryType::GNUSparse
        ) {
            continue;
        }
        let path = entry.path()?;
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if path.as_ref() == Path::new(binary) {
            return read_capped(&mut entry, cap);
        }
        if name == binary && by_name.is_none() {
            by_name = Some(read_capped(&mut entry, cap)?);
        }
    }
    by_name.ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "исполняемый файл не найден"))
}

fn extract_from_zip(archive: &[u8], binary: &str, cap: u64) -> io::Result<Vec<u8>> {
    let mut zip = zip::ZipArchive::new(io::Cursor::new(archive))?;
    if let Ok(mut file) = zip.by_name(binary) {
        return read_capped(&mut file, cap);
    }
    for index in 0..zip.len() {
        let mut file = zip.by_index(index)?;
        if file.is_dir() {
            continue;
        }
        if file.name().rsplit('/').next() == Some(binary) {
            return read_capped(&mut file, cap);
        }
    }
    Err(io::Error::new(io::ErrorKind::NotFound, "исполняемый файл не найден"))
}

/// Write `bytes` to a private temporary file next to `exe`, synced and with
/// automatic deletion cancelled: the caller owns the returned path.
fn stage_temporary(dir: &Path, bytes: &[u8]) -> io::Result<PathBuf> {
    let mut staged = tempfile::NamedTempFile::new_in(dir)?;
    staged.write_all(bytes)?;
    staged.as_file().sync_all()?;
    staged.into_temp_path().keep().map_err(|error| error.error)
}

#[cfg(windows)]
fn random_suffix() -> String {
    format!("{:08x}", rand::random::<u32>())
}

#[cfg(windows)]
fn sibling(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(suffix);
    path.with_file_name(name)
}

#[cfg(unix)]
fn sync_directory(dir: &Path) {
    if let Ok(handle) = fs::File::open(dir) {
        let _ = handle.sync_all();
    }
}

/// Same-directory atomic replacement of the executable.
#[cfg(unix)]
fn replace_binary(exe: &Path, bytes: &[u8]) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let dir = exe.parent().ok_or_else(|| update_failed_io("path"))?;
    let staged_path = stage_temporary(dir, bytes).map_err(|_| update_failed_io("stage"))?;
    let mode = fs::metadata(exe).map(|meta| meta.permissions().mode()).unwrap_or(0o755);
    if fs::set_permissions(&staged_path, fs::Permissions::from_mode(mode)).is_err() {
        let _ = fs::remove_file(&staged_path);
        return Err(update_failed_io("permissions"));
    }
    if fs::rename(&staged_path, exe).is_err() {
        let _ = fs::remove_file(&staged_path);
        return Err(update_failed_io("publish"));
    }
    sync_directory(dir);
    Ok(())
}

#[cfg(windows)]
fn move_file_ex(source: &Path, destination: Option<&Path>, flags: u32) -> io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::MoveFileExW;
    let source_wide: Vec<u16> =
        source.as_os_str().encode_wide().chain(Some(0)).collect();
    let destination_wide: Option<Vec<u16>> = destination
        .map(|path| path.as_os_str().encode_wide().chain(Some(0)).collect());
    let result = unsafe {
        MoveFileExW(
            source_wide.as_ptr(),
            destination_wide
                .as_ref()
                .map_or(std::ptr::null(), |wide| wide.as_ptr()),
            flags,
        )
    };
    if result == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// Replace the running executable: rename it aside, atomically publish the
/// new file, roll the old file back if publishing fails, then delete the
/// old copy (scheduled for reboot when the running image still maps it).
#[cfg(windows)]
fn replace_binary(exe: &Path, bytes: &[u8]) -> Result<()> {
    use windows_sys::Win32::Storage::FileSystem::{
        MOVEFILE_DELAY_UNTIL_REBOOT, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };
    let dir = exe.parent().ok_or_else(|| update_failed_io("path"))?;
    let staged_path = stage_temporary(dir, bytes).map_err(|_| update_failed_io("stage"))?;
    let backup = sibling(exe, &format!(".old-{}", random_suffix()));
    if fs::rename(exe, &backup).is_err() {
        let _ = fs::remove_file(&staged_path);
        return Err(update_failed_io("backup"));
    }
    if move_file_ex(&staged_path, Some(exe), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)
        .is_err()
    {
        let rollback = fs::rename(&backup, exe);
        let mut error = update_failed_io("publish");
        if rollback.is_err() {
            error = error.with_extra("rollback_failed", true);
        }
        return Err(error);
    }
    // Best-effort cleanup of the replaced copy; never a reported removal.
    if fs::remove_file(&backup).is_err() {
        let _ = move_file_ex(&backup, None, MOVEFILE_DELAY_UNTIL_REBOOT);
    }
    Ok(())
}

// ─── self uninstall ─────────────────────────────────────────────────────────

struct UninstallIntent {
    exe: PathBuf,
    /// Canonicalized data root, present only when it will be removed.
    data: Option<PathBuf>,
    /// Data root as configured, reported in the response.
    data_report: PathBuf,
}

/// Prepared uninstall: read-only checks and the plan. The caller must run
/// `plan.confirm(...)` before `apply` mutates anything.
pub struct UninstallPlan {
    pub plan: Plan,
    intent: UninstallIntent,
}

pub fn prepare_uninstall(state: &State, remove_data: bool) -> Result<UninstallPlan> {
    let exe = current_exe_path()?;
    ensure_root(&exe, "удаления", "uninstall")?;
    let root = state.paths().root().to_path_buf();
    let mut data = None;
    if remove_data {
        let canonical = canonical_data_root(&root)?;
        let home = dirs::home_dir()
            .ok_or_else(|| RcError::new("failed", "Не удалось определить домашний каталог."))?;
        let home = fs::canonicalize(&home).unwrap_or(home);
        if let Some(reason) = data_unsafe_reason(&canonical, &home, &exe) {
            return Err(unsafe_data_path(&canonical, reason));
        }
        data = Some(canonical);
    }
    let data_line = data.as_ref().unwrap_or(&root);
    let data_fate = if remove_data { "будут удалены" } else { "сохраняются" };
    let lines = vec![
        format!("{} будет удалён.", exe.display()),
        format!("Локальные данные: {} — {}.", data_line.display(), data_fate),
        "Локальные данные: ноды, клиенты, группы, пароли, токены, шаблоны и SSH-ключи.".to_string(),
        "Компоненты на нодах и репозиторий GitHub не удаляются.".to_string(),
        "Установленная Bash-версия (remote-control, .remote-data) не затрагивается.".to_string(),
    ];
    Ok(UninstallPlan {
        plan: Plan::new(lines, ""),
        intent: UninstallIntent { exe, data, data_report: root },
    })
}

fn canonical_data_root(root: &Path) -> Result<PathBuf> {
    let metadata = fs::metadata(root).map_err(|_| unsafe_data_path(root, "каталог не существует"))?;
    if !metadata.is_dir() {
        return Err(unsafe_data_path(root, "это не каталог"));
    }
    fs::canonicalize(root).map_err(|_| unsafe_data_path(root, "не удаётся определить реальный путь"))
}

impl UninstallPlan {
    /// Remove the current executable and, when requested, the ESSENCE data
    /// root. Must only run after the owner confirmed `plan`.
    pub fn apply(self) -> Result<Value> {
        let intent = self.intent;
        let mut removed = vec![intent.exe.display().to_string()];
        if let Some(data) = &intent.data {
            let canonical = canonical_data_root(data)?;
            let home = dirs::home_dir()
                .ok_or_else(|| RcError::new("failed", "Не удалось определить домашний каталог."))?;
            let home = fs::canonicalize(&home).unwrap_or(home);
            if let Some(reason) = data_unsafe_reason(&canonical, &home, &intent.exe) {
                return Err(unsafe_data_path(&canonical, reason));
            }
            if let Err(_error) = fs::remove_dir_all(&canonical) {
                if fs::metadata(&canonical).is_ok() {
                    return Err(RcError::new("failed", "Удаление essence-rc не завершено.")
                        .with_extra("stage", "data"));
                }
            }
            removed.push(canonical.display().to_string());
        }
        let reboot_required = remove_executable(&intent.exe)?;
        Ok(json!({
            "removed": removed,
            "data_kept": intent.data.is_none(),
            "data_path": intent.data_report.display().to_string(),
            "reboot_required": reboot_required,
        }))
    }
}

#[cfg(unix)]
fn remove_executable(exe: &Path) -> Result<bool> {
    if let Err(error) = fs::remove_file(exe) {
        if error.kind() != io::ErrorKind::NotFound {
            return Err(RcError::new("failed", "Удаление essence-rc не завершено.")
                .with_extra("stage", "executable"));
        }
    }
    if let Some(dir) = exe.parent() {
        sync_directory(dir);
    }
    Ok(false)
}

/// Delete the running executable natively: a running image cannot be deleted
/// directly, but it can be renamed aside; the renamed copy is then deleted,
/// or scheduled for deletion on reboot and reported via `reboot_required`.
/// There is no fake success: failure to clear the file fails the command.
#[cfg(windows)]
fn remove_executable(exe: &Path) -> Result<bool> {
    use windows_sys::Win32::Storage::FileSystem::MOVEFILE_DELAY_UNTIL_REBOOT;
    match fs::remove_file(exe) {
        Ok(()) => return Ok(false),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(_locked) => {}
    }
    let tombstone = sibling(exe, &format!(".removed-{}", random_suffix()));
    if fs::rename(exe, &tombstone).is_err() {
        return Err(RcError::new("failed", "Удаление essence-rc не завершено.")
            .with_extra("stage", "executable"));
    }
    if fs::remove_file(&tombstone).is_ok() {
        return Ok(false);
    }
    if move_file_ex(&tombstone, None, MOVEFILE_DELAY_UNTIL_REBOOT).is_ok() {
        return Ok(true);
    }
    Err(RcError::new("failed", "Удаление essence-rc не завершено.")
        .with_extra("stage", "executable"))
}

// ─── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn target_matrix_maps_all_eight_targets() {
        let cases = [
            (("linux", "x86_64", None as Option<&str>), Some("x86_64-unknown-linux-gnu")),
            (("linux", "aarch64", Some("musl")), Some("aarch64-unknown-linux-musl")),
            (("linux", "aarch64", None), Some("aarch64-unknown-linux-gnu")),
            (("linux", "aarch64", Some("gnu")), Some("aarch64-unknown-linux-gnu")),
            (("linux", "arm", Some("gnueabihf")), Some("armv7-unknown-linux-gnueabihf")),
            (("macos", "x86_64", None), Some("x86_64-apple-darwin")),
            (("macos", "aarch64", None), Some("aarch64-apple-darwin")),
            (("windows", "x86_64", Some("msvc")), Some("x86_64-pc-windows-msvc")),
            (("windows", "aarch64", Some("msvc")), Some("aarch64-pc-windows-msvc")),
        ];
        for ((os, arch, env), expected) in cases {
            assert_eq!(target_triple_for(os, arch, env), expected, "{os}/{arch}/{env:?}");
        }
    }

    #[test]
    fn unsupported_targets_are_rejected_not_faked() {
        assert_eq!(target_triple_for("freebsd", "x86_64", None), None);
        assert_eq!(target_triple_for("linux", "riscv64", None), None);
        assert_eq!(target_triple_for("windows", "x86", None), None);
        assert_eq!(target_triple_for("android", "aarch64", None), None);
    }

    #[test]
    fn asset_and_binary_names_follow_release_layout() {
        assert_eq!(
            asset_name("x86_64-unknown-linux-gnu"),
            "essence-rc-x86_64-unknown-linux-gnu.tar.gz"
        );
        assert_eq!(asset_name("aarch64-pc-windows-msvc"), "essence-rc-aarch64-pc-windows-msvc.zip");
        assert_eq!(binary_name_for("x86_64-pc-windows-msvc"), "essence-rc.exe");
        assert_eq!(binary_name_for("aarch64-unknown-linux-musl"), "essence-rc");
    }

    #[test]
    fn checksums_parse_github_format_with_markers_and_crlf() {
        let body = concat!(
            "6a1b1f6d7bb31f2f53c19ba4a4a0e1d1c93b1e5f7e0b8d2c4a6f0e2d4b6c8a0f  ",
            "essence-rc-x86_64-unknown-linux-gnu.tar.gz\r\n",
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef ",
            "*essence-rc-aarch64-pc-windows-msvc.zip\r\n",
            "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210  ",
            "./essence-rc-aarch64-apple-darwin.tar.gz\n",
        );
        let sums = parse_checksums(body.as_bytes());
        assert_eq!(sums.len(), 3);
        assert_eq!(
            sums.get("essence-rc-x86_64-unknown-linux-gnu.tar.gz").map(String::as_str),
            Some("6a1b1f6d7bb31f2f53c19ba4a4a0e1d1c93b1e5f7e0b8d2c4a6f0e2d4b6c8a0f")
        );
        assert!(sums.contains_key("essence-rc-aarch64-pc-windows-msvc.zip"));
        assert!(sums.contains_key("essence-rc-aarch64-apple-darwin.tar.gz"));
    }

    #[test]
    fn checksums_ignore_malformed_lines() {
        let body = concat!(
            "short  essence-rc-a.tar.gz\n",
            "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz  essence-rc-b.tar.gz\n",
            "6a1b1f6d7bb31f2f53c19ba4a4a0e1d1c93b1e5f7e0b8d2c4a6f0e2d4b6c8a0f\n",
            "\n",
            "6a1b1f6d7bb31f2f53c19ba4a4a0e1d1c93b1e5f7e0b8d2c4a6f0e2d4b6c8a0f  \n",
            "6a1b1f6d7bb31f2f53c19ba4a4a0e1d1c93b1e5f7e0b8d2c4a6f0e2d4b6c8a0f2  essence-rc-long.tar.gz\n",
            "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789  essence-rc-c.tar.gz\n",
        );
        let sums = parse_checksums(body.as_bytes());
        assert_eq!(sums.len(), 1);
        assert_eq!(
            sums.get("essence-rc-c.tar.gz").map(String::as_str),
            Some("abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
        );
    }

    /// Release archives (tar.gz and zip) yield exactly the platform binary,
    /// size caps apply, and replacement keeps the old mode without leftovers.
    #[cfg(unix)]
    #[test]
    fn verified_archive_replaces_executable_in_place() {
        use std::os::unix::fs::PermissionsExt;
        let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast()));
        for (path, data) in [("essence-rc-x/README", &b"docs"[..]), ("essence-rc-x/essence-rc", b"new-binary")] {
            let mut header = tar::Header::new_gnu();
            header.set_size(data.len() as u64);
            header.set_mode(0o755);
            header.set_cksum();
            builder.append_data(&mut header, path, data).unwrap();
        }
        let targz = builder.into_inner().unwrap().finish().unwrap();
        assert_eq!(extract_binary(&targz, "a.tar.gz", "essence-rc", 1024).unwrap(), b"new-binary");
        assert!(extract_binary(&targz, "a.tar.gz", "essence-rc", 4).is_err());
        assert!(extract_binary(&targz, "a.tar.gz", "essence-rc.exe", 1024).is_err());

        let mut zip = zip::ZipWriter::new(io::Cursor::new(Vec::new()));
        let options = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        zip.start_file("dist/essence-rc.exe", options).unwrap();
        zip.write_all(b"windows-binary").unwrap();
        let zipped = zip.finish().unwrap().into_inner();
        assert_eq!(extract_binary(&zipped, "a.zip", "essence-rc.exe", 1024).unwrap(), b"windows-binary");

        let dir = tempfile::tempdir().unwrap();
        let exe = dir.path().join("essence-rc");
        fs::write(&exe, b"old").unwrap();
        fs::set_permissions(&exe, fs::Permissions::from_mode(0o751)).unwrap();
        replace_binary(&exe, b"new-binary").unwrap();
        assert_eq!(fs::read(&exe).unwrap(), b"new-binary");
        assert_eq!(fs::metadata(&exe).unwrap().permissions().mode() & 0o777, 0o751);
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1, "no staged leftovers");
    }

    #[test]
    fn version_comparison_strips_v_prefix() {
        assert!(newer_than("v2.0.0", "1.1.0"));
        assert!(newer_than("2.0.0", "1.1.0"));
        assert!(!newer_than("v1.1.0", "1.1.0"));
        assert!(!newer_than("v1.0.9", "1.1.0"));
        assert!(newer_than("1.10.0", "1.9.0"));
        assert!(!newer_than("garbage", "1.1.0"));
        assert!(!newer_than("2.0.0", "garbage"));
    }

    #[test]
    fn strip_v_removes_only_leading_marker() {
        assert_eq!(strip_v("v2.0.0"), "2.0.0");
        assert_eq!(strip_v("2.0.0"), "2.0.0");
        assert_eq!(strip_v("vv"), "v");
    }

    #[cfg(unix)]
    #[test]
    fn data_path_safety_rejects_root_home_ancestors_and_legacy_aliases() {
        let home = Path::new("/home/user");
        let exe = Path::new("/usr/local/bin/essence-rc");
        assert_eq!(data_unsafe_reason(Path::new("/"), home, exe), Some("корень файловой системы"));
        assert_eq!(data_unsafe_reason(home, home, exe), Some("домашний каталог"));
        assert_eq!(
            data_unsafe_reason(Path::new("/home"), home, exe),
            Some("родительский каталог домашнего каталога")
        );
        assert_eq!(
            data_unsafe_reason(Path::new("/usr"), home, exe),
            Some("родительский каталог исполняемого файла")
        );
        assert_eq!(
            data_unsafe_reason(Path::new("/usr/local/bin"), home, exe),
            Some("родительский каталог исполняемого файла")
        );
        assert_eq!(
            data_unsafe_reason(Path::new("/home/user/.config/remote-control-essence"), home, exe),
            Some("каталог данных установленной Bash-версии")
        );
        assert_eq!(
            data_unsafe_reason(Path::new("/opt/remote-control/.remote-data"), home, exe),
            Some("каталог данных установленной Bash-версии")
        );
        assert_eq!(data_unsafe_reason(Path::new("/home/user/.local/share/essence-remote-control"), home, exe), None);
        assert_eq!(data_unsafe_reason(Path::new("/tmp/data"), home, exe), None);
    }
}
