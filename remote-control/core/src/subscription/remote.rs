//! Remote effects on a subscription host. Generated configs and snippets are
//! staged locally under random names and uploaded over SFTP; one shell script
//! then validates nginx and publishes them atomically. Tokens and the random
//! upload tag travel in stdin, so command text is constant per directory and
//! never carries a token. Remote diagnostics are discarded: they may name tokens.

use std::path::Path;

use crate::dispatch::Session;
use crate::error::{RcError, Result};
use crate::model::Config;
use crate::nodes::{self, COMMAND_TIMEOUT, sh_quote};
use crate::transport::{RemoteSession, RemoteTransport};
use crate::validation::subscription_token_valid;

/// Per-token `location` snippets included by the server's nginx site.
pub(super) const SNIPPETS_DIR: &str = "/etc/nginx/snippets/essence-sub";

/// Hosting settings written by the server module; exit 3 = not installed.
pub(super) const CONF_COMMAND: &str =
    r#"f=/etc/mihomo/subscription.conf; [ -f "$f" ] || exit 3; cat "$f""#;

/// `KEY=value` settings of `/etc/mihomo/subscription.conf`.
#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct HostConf {
    pub base_url: String,
    pub sub_dir: String,
    pub nginx_group: String,
}

impl HostConf {
    pub fn parse(text: &str) -> Self {
        let value = |key: &str| text.lines()
            .find_map(|line| line.strip_prefix(key).and_then(|rest| rest.strip_prefix('=')))
            .map(|value| value.trim_end_matches('\r').to_owned()).unwrap_or_default();
        Self { base_url: value("SUB_BASE_URL"), sub_dir: value("SUB_DIR"), nginx_group: value("NGINX_GROUP") }
    }

    /// The subscription directory: absolute, without `..`, control characters.
    pub fn sub_dir(&self) -> Option<&str> {
        let dir = self.sub_dir.as_str();
        (dir.starts_with('/') && !dir.chars().any(char::is_control) && dir.split('/').all(|part| part != ".."))
            .then_some(dir)
    }

    /// The nginx group (`www-data` when unset); `None` when unusable.
    pub fn nginx_group(&self) -> Option<String> {
        let group = if self.nginx_group.is_empty() { "www-data" } else { self.nginx_group.as_str() };
        group.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.')).then(|| group.to_owned())
    }

    /// Base URL, directory and group usable in links and commands.
    pub fn complete(&self) -> bool {
        !self.base_url.is_empty() && !self.base_url.chars().any(|c| c.is_control() || c.is_whitespace())
            && self.sub_dir().is_some() && self.nginx_group().is_some()
    }
}

/// Connect to a configured node under its pins (deferred GitHub nodes refused).
pub(super) async fn connect_node<T: RemoteTransport>(session: &Session, config: &Config, name: &str,
    connect: &dyn Fn() -> T) -> Result<T>
{
    let node = nodes::find(config, name)?;
    nodes::require_portable(session, node)?;
    let mut transport = connect();
    nodes::connect(&mut transport, &session.state, node).await?;
    Ok(transport)
}

/// Hosting settings of a connected node: `not_installed` when the server module
/// is not installed, `remote_failed` with `unreachable` otherwise.
pub(super) async fn read_conf<S: RemoteSession>(remote: &S, node: &str, unreachable: &str) -> Result<HostConf> {
    match remote.exec(CONF_COMMAND, &[], COMMAND_TIMEOUT).await {
        Ok(result) if result.exit_status == 0 && !result.stdout.trim_ascii().is_empty() => {
            Ok(HostConf::parse(&String::from_utf8_lossy(&result.stdout)))
        }
        Ok(result) if result.exit_status == 0 || result.exit_status == 3 => Err(RcError::new("not_installed",
            format!("На ноде «{node}» не установлен хостинг подписок.")).with_extra("name", node)),
        _ => Err(RcError::new("remote_failed", unreachable).with_extra("name", node)),
    }
}

/// The current host node, connected, with its directory and nginx group.
pub(super) struct Host<T> {
    pub transport: T,
    pub sub_dir: String,
    pub nginx_group: String,
}

/// Connect to the configured host. The host's own settings are
/// authoritative for paths; the cached copy in the config only names links.
pub(super) async fn open_host<T: RemoteTransport>(session: &Session, config: &Config, connect: &dyn Fn() -> T)
    -> Result<Host<T>>
{
    let node = super::host_node(config)?;
    let transport = connect_node(session, config, node, connect).await?;
    let conf = read_conf(&transport, node, "Хост-нода подписок недоступна.").await?;
    let (Some(sub_dir), Some(nginx_group)) = (conf.sub_dir(), conf.nginx_group()) else {
        return Err(RcError::new("remote_failed", "Не удалось определить каталог подписок на хост-ноде."));
    };
    Ok(Host { sub_dir: sub_dir.to_owned(), nginx_group, transport })
}

fn with_vars(vars: &[(&str, &str)], body: &str) -> String {
    let mut script = String::new();
    for (name, value) in vars {
        script.push_str(&format!("{name}={}\n", sh_quote(value)));
    }
    script.push_str(body);
    script
}

/// One subscription to publish: token, generated YAML, rendered snippet.
pub(super) struct Item<'a> {
    pub token: &'a str,
    pub yaml: &'a [u8],
    pub snippet: String,
}

/// The failed step of an upload (each warns differently).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum UploadFailure { Yaml, Snippet, Apply }

const APPLY: &str = r#"set -e
IFS= read -r tag
case "$tag" in ''|*[!0-9a-f]*) exit 1 ;; esac
tokens=
while IFS= read -r tok; do
    case "$tok" in ''|*[!0-9a-f]*) exit 1 ;; esac
    tokens="$tokens $tok"
done
chown "$owner" "$sub_dir/.$tag."*.yaml.tmp
chmod 640 "$sub_dir/.$tag."*.yaml.tmp
chown root:root "$snip_dir/.$tag."*.conf.tmp
chmod 644 "$snip_dir/.$tag."*.conf.tmp
backup_dir=$(mktemp -d)
trap 'rm -rf "$backup_dir"' EXIT
i=0
for tok in $tokens; do
    if [ -f "$snip_dir/sub-$tok.conf" ]; then cp "$snip_dir/sub-$tok.conf" "$backup_dir/sub-$tok.conf"; fi
    mv "$snip_dir/.$tag.$i.conf.tmp" "$snip_dir/sub-$tok.conf"
    i=$((i + 1))
done
if ! nginx -t >/dev/null 2>&1; then
    for tok in $tokens; do
        if [ -f "$backup_dir/sub-$tok.conf" ]; then
            mv "$backup_dir/sub-$tok.conf" "$snip_dir/sub-$tok.conf"
        else
            rm -f "$snip_dir/sub-$tok.conf"
        fi
    done
    rm -f "$sub_dir/.$tag."*.yaml.tmp
    exit 1
fi
i=0
for tok in $tokens; do
    mv "$sub_dir/.$tag.$i.yaml.tmp" "$sub_dir/$tok.yaml"
    i=$((i + 1))
done
systemctl reload nginx
"#;

const CLEANUP: &str = r#"IFS= read -r tag || exit 1
case "$tag" in ''|*[!0-9a-f]*) exit 1 ;; esac
rm -f -- "$sub_dir/.$tag."*.yaml.tmp "$snip_dir/.$tag."*.conf.tmp
"#;

pub(super) fn apply_command(sub_dir: &str, nginx_group: &str) -> String {
    with_vars(&[("sub_dir", sub_dir), ("snip_dir", SNIPPETS_DIR), ("owner", &format!("root:{nginx_group}"))], APPLY)
}

pub(super) fn cleanup_command(sub_dir: &str) -> String {
    with_vars(&[("sub_dir", sub_dir), ("snip_dir", SNIPPETS_DIR)], CLEANUP)
}

/// Private local files `.<tag>.<n>.<suffix>` in a fresh directory.
fn stage(tag: &str, suffix: &str, contents: &[&[u8]]) -> std::io::Result<tempfile::TempDir> {
    let dir = tempfile::Builder::new().prefix("essence-sub-").tempdir()?;
    for (index, content) in contents.iter().enumerate() {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(dir.path().join(format!(".{tag}.{index}.{suffix}")))?;
        std::io::Write::write_all(&mut file, content)?;
    }
    Ok(dir)
}

/// v1 `_sub_upload_batch` (also used for one subscription): upload YAML and
/// snippets under a random tag, then publish all of them with one nginx
/// check and reload, restoring previous snippets when nginx rejects them.
/// Leftover temporary files are removed on any failure.
pub(super) async fn upload<S: RemoteSession>(remote: &S, sub_dir: &str, nginx_group: &str, items: &[Item<'_>])
    -> std::result::Result<(), UploadFailure>
{
    if items.is_empty() {
        return Ok(());
    }
    if items.iter().any(|item| !subscription_token_valid(item.token) || item.yaml.trim_ascii().is_empty()) {
        return Err(UploadFailure::Yaml);
    }
    let tag = crate::github::random_hex(8);
    let yaml: Vec<&[u8]> = items.iter().map(|item| item.yaml).collect();
    let snippets: Vec<&[u8]> = items.iter().map(|item| item.snippet.as_bytes()).collect();
    let (Ok(yaml_dir), Ok(snippet_dir)) = (stage(&tag, "yaml.tmp", &yaml), stage(&tag, "conf.tmp", &snippets)) else {
        return Err(UploadFailure::Yaml);
    };
    let mut stdin = format!("{tag}\n").into_bytes();
    for item in items {
        stdin.extend_from_slice(item.token.as_bytes());
        stdin.push(b'\n');
    }
    let result = async {
        transfer(remote, yaml_dir.path(), sub_dir).await.map_err(|_| UploadFailure::Yaml)?;
        transfer(remote, snippet_dir.path(), SNIPPETS_DIR).await.map_err(|_| UploadFailure::Snippet)?;
        match remote.exec(&apply_command(sub_dir, nginx_group), &stdin, COMMAND_TIMEOUT).await {
            Ok(result) if result.exit_status == 0 => Ok(()),
            _ => Err(UploadFailure::Apply),
        }
    }.await;
    if result.is_err() {
        let _ = remote.exec(&cleanup_command(sub_dir), format!("{tag}\n").as_bytes(), COMMAND_TIMEOUT).await;
    }
    result
}

async fn transfer<S: RemoteSession>(remote: &S, local: &Path, remote_dir: &str) -> Result<()> {
    remote.upload(local, remote_dir, COMMAND_TIMEOUT).await
}

/// Outcome of a link removal (v1 `SUB_REMOVE_TOKEN_STATE`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Removal {
    Removed,
    /// Rolled back with the old YAML and snippet present again.
    Restored,
    /// Rolled back; the old link was not (fully) present before.
    Unchanged,
    /// Rollback not confirmed: private backups kept on the host.
    Uncertain,
    /// No result received (transport lost).
    Unknown,
}

const REMOVE: &str = r#"IFS= read -r token || exit 1
IFS= read -r replacement || replacement=
case "$token" in (''|*[!0-9a-f]*) exit 1 ;; esac
case "$replacement" in (*[!0-9a-f]*) exit 1 ;; esac
yaml="$sub_dir/$token.yaml"
snippet="$snippets_dir/sub-$token.conf"
expiry="$sub_dir/expiry.list"
backup=
yaml_saved=false snippet_saved=false expiry_saved=false
pending=false
rollback() {
    files=restored expiry_state=restored nginx_state=restored
    if $yaml_saved; then cp -p "$backup/yaml" "$yaml" || files=uncertain
    else rm -f "$yaml" || files=uncertain; fi
    if $snippet_saved; then cp -p "$backup/snippet" "$snippet" || files=uncertain
    else rm -f "$snippet" || files=uncertain; fi
    if $expiry_saved; then cp -p "$backup/expiry" "$expiry" || expiry_state=uncertain
    else rm -f "$expiry" || expiry_state=uncertain; fi
    if ! nginx -t; then nginx_state=uncertain
    elif ! systemctl reload nginx; then nginx_state=uncertain; fi
    if [ "$files:$expiry_state:$nginx_state" = restored:restored:restored ]; then
        result=unchanged
        if $yaml_saved && $snippet_saved && [ -s "$yaml" ] && [ -s "$snippet" ]; then result=restored; fi
        rm -rf "$backup"
    else
        result="uncertain:$files:$expiry_state:$nginx_state"
    fi
}
abort() {
    trap - EXIT HUP INT TERM
    if $pending; then
        rollback >/dev/null 2>&1
        printf '%s\n' "$result"
    else
        [ -z "$backup" ] || rm -rf "$backup" >/dev/null 2>&1
        printf '%s\n' unchanged
    fi
    exit 1
}
trap abort EXIT
trap 'exit 1' HUP INT TERM
prepare() {
    umask 077
    exec 9>"$sub_dir/.expiry.lock" || return 1
    flock -x 9 || return 1
    backup=$(mktemp -d "$sub_dir/.subscription-remove.XXXXXX") || return 1
    if [ -e "$yaml" ]; then cp -p "$yaml" "$backup/yaml" || return 1; yaml_saved=true; fi
    if [ -e "$snippet" ]; then cp -p "$snippet" "$backup/snippet" || return 1; snippet_saved=true; fi
    if [ -e "$expiry" ]; then cp -p "$expiry" "$backup/expiry" || return 1; expiry_saved=true; fi
}
remove() {
    rm -f "$yaml" "$snippet" || return 1
    if $expiry_saved; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ("$token "*)
                    if [ -n "$replacement" ]; then printf '%s\n' "$replacement ${line#"$token "}"; fi
                    ;;
                (*) printf '%s\n' "$line" ;;
            esac
        done < "$expiry" > "$backup/expiry.new" || return 1
        cp -- "$backup/expiry.new" "$expiry" || return 1
    fi
    nginx -t || return 1
    systemctl reload nginx || return 1
    test ! -e "$yaml" && test ! -e "$snippet"
}
prepare >/dev/null 2>&1 || exit 1
pending=true
remove >/dev/null 2>&1 || exit 1
trap - EXIT HUP INT TERM
rm -rf "$backup" >/dev/null 2>&1
printf '%s\n' removed
"#;

pub(super) fn remove_command(sub_dir: &str) -> String {
    with_vars(&[("sub_dir", sub_dir), ("snippets_dir", SNIPPETS_DIR)], REMOVE)
}

/// v1 `_sub_remove_token`: delete the link under the expiry lock; on failure
/// the files, expiry list and nginx are restored. With `replacement` the
/// expiry entry moves to the new token. Returns the outcome and a warning.
pub(super) async fn remove_token<S: RemoteSession>(remote: &S, sub_dir: &str, token: &str, replacement: Option<&str>)
    -> (Removal, Option<String>)
{
    if !subscription_token_valid(token) || replacement.is_some_and(|t| !subscription_token_valid(t)) {
        return (Removal::Unchanged, Some("Токен подписки повреждён — удаление не выполнено.".into()));
    }
    let stdin = format!("{token}\n{}\n", replacement.unwrap_or(""));
    let (status, stdout) = match remote.exec(&remove_command(sub_dir), stdin.as_bytes(), COMMAND_TIMEOUT).await {
        Ok(result) => (Some(result.exit_status), String::from_utf8_lossy(&result.stdout).into_owned()),
        Err(_) => (None, String::new()),
    };
    if status == Some(0) {
        return (Removal::Removed, None);
    }
    let response = stdout.lines().last().unwrap_or("").trim_end_matches('\r');
    match response {
        "restored" => (Removal::Restored, None),
        "unchanged" => (Removal::Unchanged, None),
        "uncertain:restored:restored:uncertain" => (Removal::Uncertain, Some(
            "Файлы подписки и срок восстановлены; применение nginx не подтверждено. Резервная копия сохранена в каталоге подписок.".into())),
        _ if response.starts_with("uncertain:") => {
            let parts: Vec<&str> = response.split(':').collect();
            let restored = |index: usize| parts.get(index) == Some(&"restored");
            let files = if restored(1) { "восстановлены" } else { "не подтверждены" };
            let expiry = if restored(2) { "восстановлен" } else { "не подтверждён" };
            let nginx = if restored(3) { "применён" } else { "не подтверждён" };
            (Removal::Uncertain, Some(format!(
                "Восстановление подписки: файлы — {files}; срок — {expiry}; nginx — {nginx}. Резервная копия сохранена в каталоге подписок.")))
        }
        _ => (Removal::Unknown, Some("Удалённое состояние подписки неизвестно: результат восстановления не получен.".into())),
    }
}

const EXPIRY: &str = r#"list="$sub_dir/expiry.list"; tmp="$list.migrate.$$"
drop=" " entries=""
while IFS=' ' read -r tok ts; do
    case "$tok" in ('') continue ;; (*[!0-9a-f]*) exit 1 ;; esac
    case "$ts" in (*[!0-9]*) exit 1 ;; esac
    drop="$drop$tok "
    if [ -n "$ts" ]; then entries="$entries$tok $ts
"; fi
done
exec 9>"$sub_dir/.expiry.lock" || exit 1
flock -x 9 || exit 1
(
    if [ -e "$list" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$drop" in
                (*" ${line%% *} "*) ;;
                (*) printf '%s\n' "$line" || exit 1 ;;
            esac
        done < "$list" || exit 1
    fi
    printf '%s' "$entries" || exit 1
) > "$tmp" || { rm -f "$tmp"; exit 1; }
mv -f "$tmp" "$list" || { rm -f "$tmp"; exit 1; }
"#;

pub(super) fn expiry_command(sub_dir: &str) -> String {
    with_vars(&[("sub_dir", sub_dir)], EXPIRY)
}

/// v1 `_sub_migrate_expiry`: replace the expiry entries of the given tokens
/// atomically under the expiry lock; `None` only drops the old entry.
pub(super) async fn write_expiry<S: RemoteSession>(remote: &S, sub_dir: &str, pairs: &[(String, Option<i64>)]) -> bool {
    let mut stdin = String::new();
    for (token, expiry) in pairs {
        if !subscription_token_valid(token) || expiry.is_some_and(|e| e < 0) {
            return false;
        }
        stdin.push_str(&format!("{token} {}\n", expiry.map(|e| e.to_string()).unwrap_or_default()));
    }
    matches!(remote.exec(&expiry_command(sub_dir), stdin.as_bytes(), COMMAND_TIMEOUT).await,
        Ok(result) if result.exit_status == 0)
}

pub(super) fn list_command(sub_dir: &str) -> String {
    format!("cd -- {} || exit 1\nfor f in *.yaml; do [ -e \"$f\" ] && printf '%s\\n' \"${{f%.yaml}}\"; done\nexit 0",
        sh_quote(sub_dir))
}

/// Tokens published on the host (valid YAML names in the directory).
pub(super) async fn list_tokens<S: RemoteSession>(remote: &S, sub_dir: &str) -> Result<Vec<String>> {
    match remote.exec(&list_command(sub_dir), &[], COMMAND_TIMEOUT).await {
        Ok(result) if result.exit_status == 0 => Ok(String::from_utf8_lossy(&result.stdout).lines()
            .map(|line| line.trim_end_matches('\r')).filter(|name| subscription_token_valid(name))
            .map(str::to_owned).collect()),
        _ => Err(RcError::new("remote_failed", "Не удалось прочитать каталог подписок на хост-ноде.")),
    }
}

const PRUNE: &str = r#"removed=0 failed=0 reload=0
while IFS= read -r tok; do
    case "$tok" in ''|*[!0-9a-f]*) continue ;; esac
    [ -e "$sub_dir/$tok.yaml" ] || continue
    if rm -f "$sub_dir/$tok.yaml" "$snip_dir/sub-$tok.conf"; then removed=$((removed + 1)); else failed=$((failed + 1)); fi
done
if [ $removed -gt 0 ]; then systemctl reload nginx || reload=1; fi
echo "$removed $failed"
[ $failed -eq 0 ] && [ $reload -eq 0 ]
"#;

pub(super) fn prune_command(sub_dir: &str) -> String {
    with_vars(&[("sub_dir", sub_dir), ("snip_dir", SNIPPETS_DIR)], PRUNE)
}

/// v1 `_sub_prune_planned`: delete the YAML and snippet of each token; the
/// number removed and whether everything (including the reload) succeeded.
pub(super) async fn prune<S: RemoteSession>(remote: &S, sub_dir: &str, tokens: &[String]) -> (u64, bool) {
    if tokens.is_empty() {
        return (0, true);
    }
    let stdin: String = tokens.iter().map(|token| format!("{token}\n")).collect();
    let (status, stdout) = match remote.exec(&prune_command(sub_dir), stdin.as_bytes(), COMMAND_TIMEOUT).await {
        Ok(result) => (Some(result.exit_status), String::from_utf8_lossy(&result.stdout).into_owned()),
        Err(_) => (None, String::new()),
    };
    let mut counts = stdout.lines().last().unwrap_or("").split_whitespace().map(|n| n.parse::<u64>().ok());
    let (removed, failed) = (counts.next().flatten(), counts.next().flatten());
    (removed.unwrap_or(0), status == Some(0) && removed.is_some() && failed == Some(0))
}

/// HTTP status of the published link (v1 `curl -sk --max-time 5`); `None`
/// without a response. Certificates are not verified, redirects not followed.
pub(super) async fn http_status(url: &str) -> Option<u16> {
    let client = reqwest::Client::builder()
        .danger_accept_invalid_certs(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(5))
        .build().ok()?;
    client.get(url).send().await.ok().map(|response| response.status().as_u16())
}
