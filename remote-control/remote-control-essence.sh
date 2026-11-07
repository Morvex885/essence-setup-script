#!/bin/bash
# ─── Удалённое управление setup-essence ───────────────────────────────────────
# Запускается локально. Хранит список нод, подключается по SSH и выполняет
# пункты основного скрипта setup-essence.sh в интерактивном режиме.

if (( BASH_VERSINFO[0] < 3 || ( BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2) )); then
    printf '  [✗] Требуется Bash 3.2 или новее.\n' >&2
    exit 1
fi

_SELF="${BASH_SOURCE[0]}"
while [[ -L "$_SELF" ]]; do _SELF="$(readlink "$_SELF")"; done
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REMOTE_DIR="/root/essence-setup"

# Dev-режим (запуск из репо) → данные в .remote-data/ внутри remote-control/
# Installed-режим → данные в ~/.config/remote-control-essence/
if [[ -d "$SCRIPT_DIR/../.git" ]] || [[ -f "$SCRIPT_DIR/../VERSION" ]]; then
    CONFIG_DIR="$SCRIPT_DIR/.remote-data"
else
    CONFIG_DIR="$HOME/.config/remote-control-essence"
fi
CONFIG_JSON="$CONFIG_DIR/config.json"
SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
CONFIG_SOURCE="${CONFIG_SOURCE:-local}"

# ─── Подключаем общий слой до проверки зависимостей ────────────────────────────
if [[ -f "$SCRIPT_DIR/common/common.sh" ]]; then
    source "$SCRIPT_DIR/common/common.sh"
    source "$SCRIPT_DIR/common/protocols/vless-xhttp.sh"
elif [[ -f "$SCRIPT_DIR/../common/common.sh" ]]; then
    source "$SCRIPT_DIR/../common/common.sh"
    source "$SCRIPT_DIR/../common/protocols/vless-xhttp.sh"
else
    printf '  [✗] Не найден common/common.sh\n' >&2
    exit 1
fi

if [[ -f "$SCRIPT_DIR/common/ensure-deps.sh" ]]; then
    source "$SCRIPT_DIR/common/ensure-deps.sh"
elif [[ -f "$SCRIPT_DIR/../common/ensure-deps.sh" ]]; then
    source "$SCRIPT_DIR/../common/ensure-deps.sh"
else
    printf '  [✗] Не найден common/ensure-deps.sh\n' >&2
    exit 1
fi

_startup_ensure_deps() {
    while ! ensure_dep jq openssl ssh scp base64 curl; do
        warn "Не удалось подготовить обязательные зависимости."
        startup_recovery_menu "Восстановление зависимостей" true || return 1
    done
}

_startup_ensure_deps || exit 1

# ─── Подключаем модули ───────────────────────────────────────────────────────
source "$SCRIPT_DIR/modules/state.sh"
source "$SCRIPT_DIR/modules/github-config.sh"
if ! register_exit_cleanup github_config_close; then
    warn "Не удалось зарегистрировать очистку временных файлов GitHub."
fi
if github_source_metadata_valid "$CONFIG_DIR/source.json"; then
    CONFIG_SOURCE=github
fi

source "$SCRIPT_DIR/modules/nodes.sh"
source "$SCRIPT_DIR/modules/ssh.sh"
source "$SCRIPT_DIR/modules/telegram-proxy.sh"
source "$SCRIPT_DIR/modules/self.sh"
source "$SCRIPT_DIR/modules/groups.sh"
source "$SCRIPT_DIR/modules/clients.sh"
source "$SCRIPT_DIR/modules/connections.sh"
source "$SCRIPT_DIR/modules/templates.sh"
source "$SCRIPT_DIR/modules/generate.sh"
source "$SCRIPT_DIR/modules/hardening.sh"
source "$SCRIPT_DIR/modules/awg_peers.sh"
source "$SCRIPT_DIR/modules/subscription.sh"
check_update_start || warn "Не удалось запустить фоновую проверку обновлений."


# ─── Пути к setup-essence, common и VERSION (dev / installed) ─────────────────
SETUP_DIR=""
if [[ -d "$SCRIPT_DIR/setup-essence" ]]; then
    SETUP_DIR="$SCRIPT_DIR/setup-essence"
elif [[ -d "$SCRIPT_DIR/../setup-essence" ]]; then
    SETUP_DIR="$(cd "$SCRIPT_DIR/../setup-essence" && pwd)"
fi

COMMON_DIR=""
if [[ -d "$SCRIPT_DIR/common" ]]; then
    COMMON_DIR="$SCRIPT_DIR/common"
elif [[ -d "$SCRIPT_DIR/../common" ]]; then
    COMMON_DIR="$(cd "$SCRIPT_DIR/../common" && pwd)"
fi

VERSION_PATH=""
if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    VERSION_PATH="$SCRIPT_DIR/VERSION"
elif [[ -f "$SCRIPT_DIR/../VERSION" ]]; then
    VERSION_PATH="$(cd "$SCRIPT_DIR/.." && pwd)/VERSION"
fi

# ─── Текущая версия ─────────────────────────────────────────────────────────
CURRENT_VERSION="0.0.0"
[[ -n "$VERSION_PATH" && -f "$VERSION_PATH" ]] && CURRENT_VERSION=$(tr -d '\r' < "$VERSION_PATH")


_materialize_script_auth_from_state() {
    local logical="$1" password_hash tmp
    password_hash=$(jq -er '
        .access.script_password_hash as $hash |
        if $hash == null then "" elif ($hash | type) == "string" then $hash
        else error("invalid script password hash") end
    ' "$logical" 2>/dev/null) || {
        _github_record_error "восстановление пароля запуска" \
            "Не удалось прочитать пароль запуска из конфигурации GitHub."
        return 1
    }
    if [[ -z "$password_hash" ]]; then
        if ! rm -f "$SCRIPT_AUTH_FILE"; then
            _github_record_error "восстановление пароля запуска" \
                "Не удалось удалить локальный пароль запуска."
            return 1
        fi
        return 0
    fi
    if ! _script_password_hash_salt "$password_hash" >/dev/null; then
        _github_record_error "восстановление пароля запуска" \
            "Хеш пароля запуска в состоянии GitHub имеет некорректный формат."
        return 1
    fi
    tmp=$(umask 077; mktemp "$CONFIG_DIR/.auth.XXXXXX") || {
        _github_record_error "восстановление пароля запуска" \
            "Не удалось создать защищённый временный файл пароля запуска."
        return 1
    }
    if ! printf '%s\n' "$password_hash" > "$tmp" ||
       ! chmod 600 "$tmp" || ! mv "$tmp" "$SCRIPT_AUTH_FILE"; then
        rm -f "$tmp"
        _github_record_error "восстановление пароля запуска" \
            "Не удалось сохранить пароль запуска из конфигурации GitHub."
        return 1
    fi
}

# ─── Текущая нода (глобальные переменные) ────────────────────────────────────
NODE_NAME=""
_config_source_materialize_state() {
    local logical="${1:?logical state}" runtime="${2:-$CONFIG_DIR/github-runtime}"
    local stage publish retired="" auth_backup="" names name id
    local old_source="${CONFIG_SOURCE:-}" old_state="${STATE_DIR:-}"
    local old_config="${CONFIG_JSON:-}" old_secrets="${SECRETS_JSON:-}"
    local old_manifest="${STATE_MANIFEST:-}" old_templates="${TEMPLATES_DIR:-}"
    local old_identities="${SSH_IDENTITIES_DIR:-}" old_hosts="${SSH_KNOWN_HOSTS:-}"
    local old_auth_file="${SCRIPT_AUTH_FILE:-}" had_runtime=false had_auth=false
    local rollback_ok=true rollback_backup_preserved=false
    stage=$(umask 077; mktemp -d "$CONFIG_DIR/.github-runtime.stage.XXXXXX") || {
        _github_record_error "подготовка рабочего состояния" \
            "Не удалось создать защищённый каталог staging."
        return 1
    }
    if ! mkdir -p "$stage/templates" "$stage/ssh/identities" ||
       ! jq -e '.config' "$logical" > "$stage/config.json" ||
       ! jq -e '.secrets' "$logical" > "$stage/secrets.json" ||
       ! jq -e '{schema_version:2,minimum_remote_control_version,portability,templates,access}' \
            "$logical" > "$stage/manifest.json" ||
       ! jq -j '.ssh.known_hosts // ""' "$logical" > "$stage/ssh/known_hosts"; then
        rm -rf "$stage"
        _github_record_error "подготовка рабочего состояния" \
            "Не удалось извлечь файлы рабочего состояния из логического снимка."
        return 1
    fi
    names="$stage/.templates.list"
    if ! jq -r '.templates // {} | keys[]' "$logical" > "$names"; then
        rm -rf "$stage"
        _github_record_error "подготовка шаблонов" \
            "Не удалось прочитать список шаблонов."
        return 1
    fi
    while IFS= read -r name; do
        if [[ ! "$name" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] ||
           ! jq -j --arg n "$name" '.templates[$n].content // ""' "$logical" \
                > "$stage/templates/$name"; then
            rm -rf "$stage"
            _github_record_error "подготовка шаблонов" \
                "Не удалось безопасно восстановить шаблон: $name"
            return 1
        fi
    done < "$names"
    if ! rm -f "$names"; then
        rm -rf "$stage"
        return 1
    fi
    names="$stage/.identities.list"
    if ! jq -r '.ssh.identities // {} | keys[]' "$logical" > "$names"; then
        rm -rf "$stage"
        _github_record_error "подготовка SSH-ключей" \
            "Не удалось прочитать список SSH-ключей."
        return 1
    fi
    while IFS= read -r id; do
        if [[ ! "$id" =~ ^[0-9a-fA-F]{32}$ ]] ||
           ! jq -j --arg n "$id" '.ssh.identities[$n].private // ""' "$logical" \
                > "$stage/ssh/identities/$id" ||
           ! jq -j --arg n "$id" '.ssh.identities[$n].public // ""' "$logical" \
                > "$stage/ssh/identities/$id.pub"; then
            rm -rf "$stage"
            _github_record_error "подготовка SSH-ключей" \
                "Не удалось безопасно восстановить SSH-ключ: $id"
            return 1
        fi
    done < "$names"
    if ! rm -f "$names" ||
       ! chmod 700 "$stage" "$stage/templates" "$stage/ssh" \
            "$stage/ssh/identities" ||
       ! chmod 600 "$stage/config.json" "$stage/secrets.json" \
            "$stage/manifest.json" "$stage/ssh/known_hosts"; then
        rm -rf "$stage"
        _github_record_error "защита рабочего состояния" \
            "Не удалось установить безопасные права доступа."
        return 1
    fi
    for name in "$stage"/templates/*.yaml; do
        [[ -e "$name" ]] || continue
        if ! chmod 644 "$name"; then
            rm -rf "$stage"
            return 1
        fi
    done
    for name in "$stage"/ssh/identities/*; do
        [[ -e "$name" ]] || continue
        case "$name" in
            *.pub) chmod 644 "$name" || { rm -rf "$stage"; return 1; } ;;
            *) chmod 600 "$name" || { rm -rf "$stage"; return 1; } ;;
        esac
    done
    CONFIG_SOURCE=github
    STATE_DIR="$stage"
    CONFIG_JSON="$stage/config.json"
    SECRETS_JSON="$stage/secrets.json"
    STATE_MANIFEST="$stage/manifest.json"
    TEMPLATES_DIR="$stage/templates"
    SSH_IDENTITIES_DIR="$stage/ssh/identities"
    SSH_KNOWN_HOSTS="$stage/ssh/known_hosts"
    SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
    if ! state_validate true >/dev/null 2>&1; then
        CONFIG_SOURCE="$old_source"; STATE_DIR="$old_state"; CONFIG_JSON="$old_config"
        SECRETS_JSON="$old_secrets"; STATE_MANIFEST="$old_manifest"
        TEMPLATES_DIR="$old_templates"; SSH_IDENTITIES_DIR="$old_identities"
        SSH_KNOWN_HOSTS="$old_hosts"; SCRIPT_AUTH_FILE="$old_auth_file"
        rm -rf "$stage"
        _github_ensure_error "проверка рабочего состояния" \
            "Восстановленное состояние GitHub не прошло проверку."
        return 1
    fi
    CONFIG_SOURCE="$old_source"; STATE_DIR="$old_state"; CONFIG_JSON="$old_config"
    SECRETS_JSON="$old_secrets"; STATE_MANIFEST="$old_manifest"
    TEMPLATES_DIR="$old_templates"; SSH_IDENTITIES_DIR="$old_identities"
    SSH_KNOWN_HOSTS="$old_hosts"; SCRIPT_AUTH_FILE="$old_auth_file"
    publish=$(umask 077; mktemp -d "$CONFIG_DIR/.github-runtime.publish.XXXXXX") || {
        rm -rf "$stage"
        return 1
    }
    if ! cp -Rp "$stage/." "$publish/" || ! rm -rf "$stage"; then
        rm -rf "$stage" "$publish"
        _github_record_error "публикация рабочего состояния" \
            "Не удалось подготовить полную копию состояния к публикации."
        return 1
    fi
    if [[ -e "$runtime" || -L "$runtime" ]]; then
        if [[ ! -d "$runtime" || -L "$runtime" ]]; then
            rm -rf "$publish"
            _github_record_error "публикация рабочего состояния" \
                "Путь рабочего состояния имеет недопустимый тип."
            return 1
        fi
        had_runtime=true
        retired=$(umask 077; mktemp -d "$CONFIG_DIR/.github-runtime.retired.XXXXXX") || {
            rm -rf "$publish"
            return 1
        }
        rmdir "$retired" || { rm -rf "$publish" "$retired"; return 1; }
    fi
    if [[ -e "$CONFIG_DIR/.auth" || -L "$CONFIG_DIR/.auth" ]]; then
        if [[ ! -f "$CONFIG_DIR/.auth" || -L "$CONFIG_DIR/.auth" ]]; then
            rm -rf "$publish"
            _github_record_error "публикация пароля запуска" \
                "Локальный файл пароля имеет недопустимый тип."
            return 1
        fi
        had_auth=true
        auth_backup=$(umask 077; mktemp "$CONFIG_DIR/.auth.backup.XXXXXX") || {
            rm -rf "$publish"
            return 1
        }
        if ! cp "$CONFIG_DIR/.auth" "$auth_backup" || ! chmod 600 "$auth_backup"; then
            rm -rf "$publish"
            rm -f "$auth_backup"
            return 1
        fi
    fi
    if [[ "$had_runtime" == true ]] && ! mv "$runtime" "$retired"; then
        rm -rf "$publish" "$retired"
        rm -f "$auth_backup"
        _github_record_error "публикация рабочего состояния" \
            "Не удалось убрать прежнее рабочее состояние."
        return 1
    fi
    if ! mv "$publish" "$runtime"; then
        rollback_ok=true
        if [[ "$had_runtime" == true ]] && ! mv "$retired" "$runtime"; then
            rollback_ok=false
            rollback_backup_preserved=true
        fi
        if ! rm -rf "$publish"; then
            rollback_ok=false
        fi
        if [[ "$rollback_backup_preserved" != true && -n "$retired" ]] &&
           ! rm -rf "$retired"; then
            rollback_ok=false
        fi
        if [[ -n "$auth_backup" ]] && ! rm -f "$auth_backup"; then
            rollback_ok=false
            rollback_backup_preserved=true
        fi
        if [[ "$rollback_ok" == true ]]; then
            _github_record_error "публикация рабочего состояния" \
                "Не удалось атомарно опубликовать новое рабочее состояние."
        elif [[ "$rollback_backup_preserved" == true ]]; then
            _github_record_error "откат публикации рабочего состояния" \
                "Не удалось восстановить прежнее рабочее состояние после ошибки публикации. Резервные копии сохранены в $CONFIG_DIR."
        else
            _github_record_error "откат публикации рабочего состояния" \
                "Не удалось восстановить прежнее рабочее состояние после ошибки публикации."
        fi
        return 1
    fi
    SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
    if ! _materialize_script_auth_from_state "$logical"; then
        local auth_stage="${GITHUB_LAST_STAGE:-}" auth_detail="${GITHUB_LAST_ERROR:-}"
        rollback_ok=true
        rollback_backup_preserved=false
        if ! rm -rf "$runtime"; then
            rollback_ok=false
            rollback_backup_preserved=true
        else
            if [[ "$had_runtime" == true ]] && ! mv "$retired" "$runtime"; then
                rollback_ok=false
                rollback_backup_preserved=true
            fi
        fi
        if [[ "$had_auth" == true ]]; then
            if ! mv "$auth_backup" "$SCRIPT_AUTH_FILE"; then
                rollback_ok=false
                rollback_backup_preserved=true
            fi
        elif ! rm -f "$SCRIPT_AUTH_FILE"; then
            rollback_ok=false
        fi
        if [[ "$rollback_backup_preserved" != true ]]; then
            [[ -z "$retired" ]] || { rm -rf "$retired" || rollback_ok=false; }
            [[ -z "$auth_backup" ]] || { rm -f "$auth_backup" || rollback_ok=false; }
        fi
        if [[ "$rollback_ok" == true ]]; then
            GITHUB_LAST_STAGE="$auth_stage"
            GITHUB_LAST_ERROR="$auth_detail"
        elif [[ "$rollback_backup_preserved" == true ]]; then
            _github_record_error "откат рабочего состояния и пароля" \
                "Не удалось полностью восстановить рабочее состояние после ошибки пароля запуска. Резервные копии сохранены в $CONFIG_DIR."
        else
            _github_record_error "откат рабочего состояния и пароля" \
                "Не удалось полностью восстановить рабочее состояние после ошибки пароля запуска."
        fi
        return 1
    fi
    if ! rm -rf "$retired" || ! rm -f "$auth_backup"; then
        warn "Рабочее состояние опубликовано, но резервные файлы требуют ручной очистки."
    fi
    CONFIG_SOURCE=github
    STATE_DIR="$runtime"; CONFIG_JSON="$runtime/config.json"
    SECRETS_JSON="$runtime/secrets.json"; STATE_MANIFEST="$runtime/manifest.json"
    TEMPLATES_DIR="$runtime/templates"; SSH_IDENTITIES_DIR="$runtime/ssh/identities"
    SSH_KNOWN_HOSTS="$runtime/ssh/known_hosts"; SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
    export CONFIG_SOURCE STATE_DIR CONFIG_JSON SECRETS_JSON STATE_MANIFEST
    export TEMPLATES_DIR SSH_IDENTITIES_DIR SSH_KNOWN_HOSTS SCRIPT_AUTH_FILE
}
_config_source_materialize_github() {
    local logical="${1:-$CONFIG_DIR/runtime-vault.json}"
    [[ -n "${GITHUB_WORKTREE:-}" && -d "$GITHUB_WORKTREE" ]] || {
        _github_record_error "подготовка рабочей копии конфигурации" \
            "Рабочая копия конфигурации GitHub недоступна."
        return 1
    }
    if ! github_config_open "$GITHUB_WORKTREE" "$logical"; then
        [[ -n "${GITHUB_LAST_STAGE:-}" ]] || _github_record_error "чтение конфигурации GitHub" \
            "Не удалось проверить или расшифровать состояние репозитория."
        return 1
    fi
    if ! _config_source_materialize_state "$logical" "${2:-$CONFIG_DIR/github-runtime}"; then
        [[ -n "${GITHUB_LAST_STAGE:-}" ]] || _github_record_error "подготовка рабочего состояния" \
            "Не удалось подготовить локальное рабочее состояние из конфигурации GitHub."
        return 1
    fi
}
_config_source_create_empty_snapshot() {
    local out="${1:?snapshot}" stage
    local old_source="$CONFIG_SOURCE" old_state="$STATE_DIR" old_config="$CONFIG_JSON"
    local old_secrets="$SECRETS_JSON" old_manifest="$STATE_MANIFEST"
    local old_templates="$TEMPLATES_DIR" old_ids="$SSH_IDENTITIES_DIR"
    local old_hosts="$SSH_KNOWN_HOSTS" old_auth="$SCRIPT_AUTH_FILE"
    stage=$(umask 077; mktemp -d "$CONFIG_DIR/.account-empty.XXXXXX") || return 1
    if ! mkdir -p "$stage/templates" "$stage/ssh/identities"; then rm -rf "$stage"; return 1; fi
    CONFIG_SOURCE=github; STATE_DIR="$stage"; CONFIG_JSON="$stage/config.json"
    SECRETS_JSON="$stage/secrets.json"; STATE_MANIFEST="$stage/manifest.json"
    TEMPLATES_DIR="$stage/templates"; SSH_IDENTITIES_DIR="$stage/ssh/identities"
    SSH_KNOWN_HOSTS="$stage/ssh/known_hosts"; SCRIPT_AUTH_FILE="$stage/.auth"
    if ! _ensure_config || ! _state_ensure_secrets || ! state_checkpoint ||
       ! state_validate false >/dev/null 2>&1 ||
       ! github_config_serialize "$out" "$CONFIG_JSON"; then
        CONFIG_SOURCE="$old_source"; STATE_DIR="$old_state"; CONFIG_JSON="$old_config"
        SECRETS_JSON="$old_secrets"; STATE_MANIFEST="$old_manifest"
        TEMPLATES_DIR="$old_templates"; SSH_IDENTITIES_DIR="$old_ids"
        SSH_KNOWN_HOSTS="$old_hosts"; SCRIPT_AUTH_FILE="$old_auth"; rm -rf "$stage"
        return 1
    fi
    CONFIG_SOURCE="$old_source"; STATE_DIR="$old_state"; CONFIG_JSON="$old_config"
    SECRETS_JSON="$old_secrets"; STATE_MANIFEST="$old_manifest"
    TEMPLATES_DIR="$old_templates"; SSH_IDENTITIES_DIR="$old_ids"
    SSH_KNOWN_HOSTS="$old_hosts"; SCRIPT_AUTH_FILE="$old_auth"; rm -rf "$stage"
}

github_config_snapshot_cached() {
    local out="${1:?snapshot}" expected_repo="${2:?repo}" branch="${3:?branch}"
    local origin old_store="$GITHUB_STORE" old_sessions="$GITHUB_SESSIONS_DIR"
    local old_worktree="$GITHUB_WORKTREE" old_session="$GITHUB_SESSION_ID"
    local old_remote="$GITHUB_REMOTE" old_branch="$GITHUB_BRANCH"
    local old_session_remote="$GITHUB_SESSION_REMOTE"
    local old_session_branch="$GITHUB_SESSION_BRANCH"
    local old_session_origin="$GITHUB_SESSION_ORIGIN"
    local old_identity="$GITHUB_IDENTITY" old_recipient="$GITHUB_RECIPIENT"
    local old_storage="$GITHUB_STORAGE_MODE" rc=1
    [[ -d "$old_store" && ! -L "$old_store" ]] || return 1
    origin=$(git --git-dir="$old_store" remote get-url origin 2>/dev/null) || return 1
    [[ "$origin" == "$expected_repo" ||
       "$origin" == "https://github.com/$expected_repo.git" ]] || return 1
    git --git-dir="$old_store" show-ref --verify --quiet "refs/heads/$branch" || return 1
    _github_mkdir_secure "$GITHUB_ACCOUNT_SWITCH_DIR" || return 1
    GITHUB_SESSION_ID=""
    if _github_session_open_cached "$old_store" "$GITHUB_ACCOUNT_SWITCH_DIR/cached-sessions" "$branch" &&
       github_config_open "$GITHUB_WORKTREE" "$out"; then
        rc=0
    fi
    github_config_close >/dev/null 2>&1 || true
    _github_account_switch_remove_path "$GITHUB_ACCOUNT_SWITCH_DIR/cached-sessions" || true
    GITHUB_STORE="$old_store"; GITHUB_SESSIONS_DIR="$old_sessions"
    GITHUB_WORKTREE="$old_worktree"; GITHUB_SESSION_ID="$old_session"
    GITHUB_REMOTE="$old_remote"; GITHUB_BRANCH="$old_branch"
    GITHUB_SESSION_REMOTE="$old_session_remote"; GITHUB_SESSION_BRANCH="$old_session_branch"
    GITHUB_SESSION_ORIGIN="$old_session_origin"; GITHUB_IDENTITY="$old_identity"
    GITHUB_RECIPIENT="$old_recipient"; GITHUB_STORAGE_MODE="$old_storage"
    export GITHUB_STORE GITHUB_SESSIONS_DIR GITHUB_WORKTREE GITHUB_SESSION_ID
    export GITHUB_REMOTE GITHUB_BRANCH GITHUB_SESSION_REMOTE GITHUB_SESSION_BRANCH
    export GITHUB_SESSION_ORIGIN GITHUB_IDENTITY GITHUB_RECIPIENT GITHUB_STORAGE_MODE
    return "$rc"
}


github_source_change_account() {
    local mode="${1:-menu}" initial_login="${2:-}"
    local old_repo old_name branch old_store old_sessions new_repo old_storage
    local old_worktree old_remote old_branch old_owner old_session
    local old_identity old_recipient old_session_remote old_session_branch old_session_origin
    local target_owner logical="$CONFIG_DIR/account-switch/old-state.json"
    local target_state="$CONFIG_DIR/account-switch/target-state.json"
    local tracked target_valid=false target_needs_replace=false
    local old_state_available=false desired_state="" push_required=false
    local expected_head="" action
    [[ "$CONFIG_SOURCE" == github ]] || return 1
    old_repo=$(jq -er '.repo' "$CONFIG_DIR/source.json") || return 1
    branch=$(jq -er '.branch' "$CONFIG_DIR/source.json") || return 1
    old_name="${old_repo#*/}"
    old_store="$GITHUB_STORE"; old_sessions="$GITHUB_SESSIONS_DIR"
    old_worktree="$GITHUB_WORKTREE"; old_session="$GITHUB_SESSION_ID"
    old_remote="$GITHUB_REMOTE"; old_branch="$GITHUB_BRANCH"; old_owner="$GITHUB_OWNER"
    old_identity="$GITHUB_IDENTITY"; old_recipient="$GITHUB_RECIPIENT"
    old_session_remote="$GITHUB_SESSION_REMOTE"; old_session_branch="$GITHUB_SESSION_BRANCH"
    old_session_origin="$GITHUB_SESSION_ORIGIN"; old_storage="$GITHUB_STORAGE_MODE"

    if [[ -n "$initial_login" ]]; then
        [[ "$initial_login" =~ ^[A-Za-z0-9-]+$ ]] || {
            _github_record_error "выбор аккаунта GitHub" \
                "Указано некорректное имя активного аккаунта GitHub."
            return 1
        }
    elif ! _github_load_active_login; then
        return 1
    else
        initial_login="$GITHUB_ACTIVE_LOGIN"
    fi
    if ! _github_select_account "$initial_login" "${old_repo%%/*}"; then
        local picker_error="${GITHUB_LAST_ERROR:-Выбор аккаунта GitHub отменён.}"
        if ! _github_switch_active_account "$initial_login"; then
            _github_record_error "отмена выбора аккаунта GitHub" \
                "$picker_error Активный аккаунт не удалось восстановить."
        else
            _github_record_error "выбор аккаунта GitHub" \
                "Смена аккаунта GitHub отменена."
        fi
        return 1
    fi
    target_owner="$GITHUB_OWNER"
    new_repo="$target_owner/$old_name"
    [[ "$new_repo" != "$old_repo" ]] || {
        info "Уже используется аккаунт $target_owner."
        return 0
    }

    _github_mkdir_secure "$GITHUB_ACCOUNT_SWITCH_DIR" || return 1
    if [[ -f "$CONFIG_JSON" && -f "$SECRETS_JSON" && -f "$STATE_MANIFEST" ]] &&
       github_config_serialize "$logical" "$CONFIG_JSON"; then
        old_state_available=true
    elif github_config_snapshot_cached "$logical" "$old_repo" "$branch"; then
        old_state_available=true
    fi
    if [[ "$old_state_available" != true ]]; then
        warn "Последний локальный кэш прежнего аккаунта недоступен."
        if ! confirm_yn "Продолжить смену аккаунта без локального кэша?" N; then
            _github_account_switch_remove_file "$logical" || true
            _github_account_switch_remove_path "$GITHUB_ACCOUNT_SWITCH_DIR" || true
            _github_record_error "выбор данных смены аккаунта" \
                "Смена аккаунта GitHub отменена."
            return 1
        fi
    fi
    if ! github_account_switch_begin "$old_repo" "$new_repo" "$branch" "$initial_login"; then
        return 1
    fi
    if ! cp "$CONFIG_DIR/source.json" "$GITHUB_ACCOUNT_SWITCH_DIR/old-source.json" ||
       ! chmod 600 "$GITHUB_ACCOUNT_SWITCH_DIR/old-source.json" ||
       ! _github_account_switch_write_marker prepared "" "$old_state_available" false false; then
        github_account_switch_rollback >/dev/null 2>&1 || true
        return 1
    fi

    GITHUB_OWNER="$target_owner"; GITHUB_REPO_NAME="$old_name"; GITHUB_BRANCH="$branch"
    GITHUB_REMOTE="$new_repo"; GITHUB_STORE="$GITHUB_ACCOUNT_SWITCH_DIR/target-store.git"
    GITHUB_SESSIONS_DIR="$GITHUB_ACCOUNT_SWITCH_DIR/target-sessions"
    GITHUB_SESSION_ID=""; GITHUB_WORKTREE=""
    if ! github_sync_init true onboarding true; then
        github_account_switch_rollback >/dev/null 2>&1 || true
        return 1
    fi
    tracked=$(git -C "$GITHUB_WORKTREE" ls-files 2>/dev/null) || {
        github_account_switch_rollback >/dev/null 2>&1 || true
        return 1
    }
    if [[ -n "$tracked" ]]; then
        if github_config_open "$GITHUB_WORKTREE" "$target_state"; then
            target_valid=true
        else
            target_needs_replace=true
        fi
    fi
    if [[ "$target_valid" == true ]]; then
        if ! _github_prompt_existing_config_action "$old_state_available"; then
            github_config_close >/dev/null 2>&1 || true
            github_account_switch_rollback >/dev/null 2>&1 || true
            return 1
        fi
        action="$GITHUB_EXISTING_ACTION"
        if [[ "$action" == remote ]]; then
            desired_state="$target_state"
            push_required=false
        else
            desired_state="$logical"
            push_required=true
        fi
    else
        if [[ "$target_needs_replace" == true ]]; then
            if ! confirm_yn "Удалить все tracked-файлы $new_repo и заменить репозиторий корректной конфигурацией Essence?" N; then
                github_config_close >/dev/null 2>&1 || true
                github_account_switch_rollback >/dev/null 2>&1 || true
                return 1
            fi
            git -C "$GITHUB_WORKTREE" rm -r -f -- . >/dev/null 2>&1 || {
                github_account_switch_rollback >/dev/null 2>&1 || true
                return 1
            }
        fi
        if [[ "$old_state_available" == true ]]; then
            desired_state="$logical"
        else
            desired_state="$logical"
            if ! _config_source_create_empty_snapshot "$desired_state"; then
                github_account_switch_rollback >/dev/null 2>&1 || true
                return 1
            fi
        fi
        if ! _github_prompt_storage_mode; then
            github_account_switch_rollback >/dev/null 2>&1 || true
            return 1
        fi
        if [[ "$GITHUB_STORAGE_MODE" == age ]] && ! github_config_age_init; then
            github_account_switch_rollback >/dev/null 2>&1 || true
            return 1
        fi
        push_required=true
    fi
    if [[ "$desired_state" != "$target_state" ]] &&
       { ! cp "$desired_state" "$target_state" || ! chmod 600 "$target_state" ||
         ! github_config_validate "$target_state"; }; then
        local target_state_error="${GITHUB_LAST_ERROR:-Снимок целевой конфигурации не прошёл проверку.}"
        github_account_switch_rollback >/dev/null 2>&1 || true
        _github_record_error "подготовка целевой конфигурации" "$target_state_error"
        return 1
    fi
    if [[ "$push_required" == true ]]; then
        if ! github_config_checkpoint "$desired_state" || ! _github_sync_commit; then
            local failure_stage="${GITHUB_LAST_STAGE:-сохранение новой конфигурации}"
            local failure_detail="${GITHUB_LAST_ERROR:-Не удалось подготовить новую конфигурацию.}"
            github_account_switch_rollback >/dev/null 2>&1 || true
            _github_record_error "$failure_stage" "$failure_detail"
            return 1
        fi
        expected_head="${GITHUB_LAST_COMMIT_HEAD:-}"
        [[ "$expected_head" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || {
            _github_record_error "подготовка отправки новой конфигурации" \
                "Не удалось определить commit новой конфигурации."
            github_account_switch_rollback >/dev/null 2>&1 || true
            return 1
        }
        if ! _github_account_switch_write_marker push_unknown "$expected_head" \
            "$old_state_available" "${GITHUB_ACCOUNT_SWITCH_REPO_CREATED:-false}" \
            "${GITHUB_ACCOUNT_SWITCH_REPO_PRIVATIZED:-false}"; then
            _github_record_error "подготовка отправки новой конфигурации" \
                "Не удалось записать защищённый маркер перед отправкой."
            github_account_switch_rollback >/dev/null 2>&1 || true
            return 1
        fi
        if ! _github_sync_push "$expected_head"; then
            return 1
        fi
        _github_account_switch_write_marker target_committed "$expected_head" \
            "$old_state_available" "${GITHUB_ACCOUNT_SWITCH_REPO_CREATED:-false}" \
            "${GITHUB_ACCOUNT_SWITCH_REPO_PRIVATIZED:-false}" || {
            _github_record_error "фиксация отправленной конфигурации" \
                "Не удалось записать состояние завершённой отправки."
            return 1
        }
    else
        expected_head=$(git -C "$GITHUB_WORKTREE" rev-parse HEAD 2>/dev/null) || {
            _github_record_error "чтение удалённой конфигурации" \
                "Не удалось определить commit выбранной конфигурации GitHub."
            return 1
        }
    fi
    if ! github_config_close; then
        _github_ensure_error "закрытие рабочей копии новой конфигурации" \
            "Не удалось закрыть рабочую копию нового репозитория."
        return 1
    fi
    GITHUB_STORE="$old_store"; GITHUB_SESSIONS_DIR="$old_sessions"
    GITHUB_WORKTREE="$old_worktree"; GITHUB_SESSION_ID="$old_session"
    GITHUB_REMOTE="$old_remote"; GITHUB_BRANCH="$old_branch"
    GITHUB_IDENTITY="$old_identity"; GITHUB_RECIPIENT="$old_recipient"
    GITHUB_SESSION_REMOTE="$old_session_remote"; GITHUB_SESSION_BRANCH="$old_session_branch"
    GITHUB_SESSION_ORIGIN="$old_session_origin"; GITHUB_STORAGE_MODE="$old_storage"
    if [[ -n "$old_worktree" || -n "$old_session" ]]; then
        github_config_close || {
            _github_ensure_error "закрытие прежней рабочей копии" \
                "Не удалось закрыть рабочую копию прежнего репозитория."
            return 1
        }
    fi
    GITHUB_STORE="$old_store"; GITHUB_SESSIONS_DIR="$old_sessions"
    GITHUB_WORKTREE=""; GITHUB_SESSION_ID=""
    github_account_switch_finalize "$target_state" false "$expected_head" || {
        _github_ensure_error "локальная финализация смены аккаунта" \
            "Не удалось установить новое локальное хранилище GitHub."
        return 1
    }
    GITHUB_STORE="$old_store"; GITHUB_SESSIONS_DIR="$old_sessions"
    GITHUB_REMOTE="https://github.com/$new_repo.git"; GITHUB_BRANCH="$branch"
    GITHUB_OWNER="$target_owner"; GITHUB_REPO_NAME="$old_name"
    GITHUB_SESSION_ID=""; GITHUB_WORKTREE=""
    _github_session_open_cached "$old_store" "$old_sessions" "$branch" || {
        _github_record_error "открытие новой рабочей копии" \
            "Не удалось открыть новое локальное хранилище GitHub без повторной сети."
        return 1
    }
    _config_source_materialize_state "$target_state" || return 1
    github_source_metadata_write || return 1
    github_account_switch_commit_local || {
        _github_record_error "запись завершения смены аккаунта GitHub" \
            "Не удалось зафиксировать обновлённое локальное состояние."
        return 1
    }
    github_account_switch_recover || return 1
    if confirm_yn "Открыть настройки прежнего репозитория $old_repo для ручного удаления?" N; then
        github_repository_open_settings "$old_repo" ||
            warn "Не удалось открыть настройки прежнего репозитория."
    fi
    success "Аккаунт GitHub изменён: $target_owner."
    return 0
}

config_source_startup() {
    if [[ -e "${GITHUB_ACCOUNT_SWITCH_MARKER:-$CONFIG_DIR/account-switch/transaction.json}" ]] &&
       ! github_account_switch_recover; then
        return 1
    fi
    _github_clear_error
    if github_source_metadata_valid "$CONFIG_DIR/source.json"; then
        local source_repo source_branch source_owner
        source_repo=$(jq -er '.repo' "$CONFIG_DIR/source.json") || {
            _github_record_error "проверка настроек источника GitHub" "source.json не содержит репозиторий GitHub."
            return 1
        }
        source_branch=$(jq -er '.branch' "$CONFIG_DIR/source.json") || {
            _github_record_error "проверка настроек источника GitHub" "source.json не содержит ветку GitHub."
            return 1
        }
        source_owner="${source_repo%%/*}"
        local active_login
        if ! _github_load_active_login; then
            return 1
        fi
        active_login="$GITHUB_ACTIVE_LOGIN"
        if [[ "$active_login" != "$source_owner" ]]; then
            warn "Конфигурация подключена к GitHub-аккаунту $source_owner, а сейчас выбран $active_login."
            info "Ничего не изменено. Выберите аккаунт, с которым продолжить."
            if ! github_source_change_account startup "$active_login"; then
                return 1
            fi
            source_repo=$(jq -er '.repo' "$CONFIG_DIR/source.json") || {
                _github_record_error "проверка настроек источника GitHub" "source.json не содержит репозиторий GitHub."
                return 1
            }
            source_branch=$(jq -er '.branch' "$CONFIG_DIR/source.json") || {
                _github_record_error "проверка настроек источника GitHub" "source.json не содержит ветку GitHub."
                return 1
            }
            source_owner="${source_repo%%/*}"
        fi
        CONFIG_SOURCE=github
        GITHUB_OWNER="$source_owner"
        GITHUB_BRANCH="$source_branch"
        if [[ -n "${GITHUB_WORKTREE:-}" && -n "${GITHUB_SESSION_REMOTE:-}" ]]; then
            GITHUB_REMOTE="$GITHUB_SESSION_REMOTE"
        else
            GITHUB_REMOTE="$source_repo"
        fi
        if ! github_sync_init; then
            if declare -F _github_ensure_error >/dev/null 2>&1; then
                _github_ensure_error "подготовка источника GitHub" \
                    "Не удалось подготовить локальную рабочую копию репозитория."
            else
                _github_record_error "подготовка источника GitHub" \
                    "Не удалось подготовить локальную рабочую копию репозитория."
            fi
            return 1
        fi
        _config_source_materialize_github || return 1
    elif legacy_local_source_metadata_valid "$CONFIG_DIR/source.json"; then
        state_open_local || return 1
        if ! rm -f "$CONFIG_DIR/source.json"; then
            warn "Не удалось удалить устаревший локальный source.json."
            return 1
        fi
        CONFIG_SOURCE=local
    elif [[ -f "$CONFIG_DIR/source.json" ]] &&
          jq -e 'type=="object" and .type=="github"' "$CONFIG_DIR/source.json" >/dev/null 2>&1; then
        CONFIG_SOURCE=github
        _github_record_error "проверка настроек источника GitHub" \
            "source.json содержит неполные или некорректные параметры GitHub."
        return 1
    elif [[ -f "$CONFIG_DIR/source.json" ]]; then
        warn "source.json содержит неподдерживаемый или неполный источник GitHub."
        return 1
    else
        state_open_local || return 1
        CONFIG_SOURCE=local
    fi
    export CONFIG_SOURCE CONFIG_JSON SECRETS_JSON STATE_MANIFEST TEMPLATES_DIR
    export SSH_IDENTITIES_DIR SSH_KNOWN_HOSTS SCRIPT_AUTH_FILE STATE_DIR
}

_github_enable_rollback() {
    local source_backup="$1" source_had_file="$2" serialized_state="${3:-}"
    local restore_ok=true
    local failure_stage="${GITHUB_LAST_STAGE:-}" failure_detail="${GITHUB_LAST_ERROR:-}"
    local failure_hint="${GITHUB_LAST_HINT:-}" failure_auth="${GITHUB_LAST_AUTH_RELEVANT:-false}"
    [[ -z "$serialized_state" ]] || rm -f "$serialized_state"
    github_config_close >/dev/null 2>&1 || restore_ok=false
    if [[ "$source_had_file" == true ]]; then
        _github_atomic_private_copy "$source_backup" "$CONFIG_DIR/source.json" ||
            restore_ok=false
    else
        rm -f "$CONFIG_DIR/source.json" || restore_ok=false
    fi
    rm -f "$source_backup" || restore_ok=false
    if ! state_open_local; then
        restore_ok=false
    fi
    GITHUB_LAST_STAGE="$failure_stage"
    GITHUB_LAST_ERROR="$failure_detail"
    GITHUB_LAST_HINT="$failure_hint"
    GITHUB_LAST_AUTH_RELEVANT="$failure_auth"
    if [[ "$restore_ok" != true ]]; then
        warn "Не удалось полностью восстановить локальный источник конфигурации."
    fi
    return 1
}


github_enable_local() {
    [[ $CONFIG_SOURCE == local ]] || return 0
    _github_clear_error
    if ! state_open_local; then
        _github_ensure_error "подготовка локальной конфигурации" \
            "Не удалось открыть или создать локальную конфигурацию перед подключением GitHub."
        return 1
    fi
    if ! _github_select_account; then
        return 1
    fi
    local source_backup source_had_file=false tmp_state="" tracked
    if [[ -z ${CONFIG_DIR:-} ]] || ! mkdir -p "$CONFIG_DIR"; then
        _github_record_error "подготовка локальной конфигурации" \
            "Не удалось подготовить каталог конфигурации."
        return 1
    fi
    source_backup=$(umask 077; mktemp "$CONFIG_DIR/.source-backup.XXXXXX") || {
        _github_record_error "резервное копирование локальной конфигурации" \
            "Не удалось создать временный файл."
        return 1
    }
    if [[ -f "$CONFIG_DIR/source.json" ]]; then
        source_had_file=true
        cp "$CONFIG_DIR/source.json" "$source_backup" || {
            rm -f "$source_backup"
            _github_record_error "резервное копирование локальной конфигурации" \
                "Не удалось скопировать настройки текущего источника."
            return 1
        }
    fi
    github_sync_init true onboarding || {
        _github_enable_rollback "$source_backup" "$source_had_file"
        return 1
    }
    tracked=$(git -C "$GITHUB_WORKTREE" ls-files) || {
        _github_record_error "проверка существующего репозитория GitHub" \
            "Не удалось проверить содержимое репозитория GitHub. Репозиторий не изменён."
        _github_enable_rollback "$source_backup" "$source_had_file"
        return 1
    }

    if [[ -z "$tracked" ]]; then
        if ! _github_prompt_storage_mode; then
            _github_record_error "выбор способа хранения" "Выбор источника GitHub отменён."
            _github_enable_rollback "$source_backup" "$source_had_file"
            return 1
        fi
        if [[ $GITHUB_STORAGE_MODE == age ]] && {
            ! _github_ensure_deps age || ! github_config_age_init
        }; then
            _github_ensure_error "настройка шифрования конфигурации" \
                "Не удалось подготовить ключи шифрования."
            _github_enable_rollback "$source_backup" "$source_had_file"
            return 1
        fi
        CONFIG_SOURCE=github
        if ! _github_initial_portable_onboarding; then
            _github_ensure_error "подготовка переносимой конфигурации" \
                "Не удалось подготовить локальные файлы для хранения в GitHub."
            _github_enable_rollback "$source_backup" "$source_had_file"
            return 1
        fi
        tmp_state=$(umask 077; mktemp "$CONFIG_DIR/.vault.XXXXXX") || {
            _github_record_error "подготовка конфигурации к отправке" \
                "Не удалось создать защищённый временный файл."
            _github_enable_rollback "$source_backup" "$source_had_file"
            return 1
        }
        if ! github_config_serialize "$tmp_state" "$CONFIG_JSON" ||
           ! github_config_checkpoint "$tmp_state"; then
            _github_ensure_error "подготовка конфигурации к отправке" \
                "Не удалось собрать конфигурацию для репозитория GitHub."
            _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
            return 1
        fi
        if ! github_sync_flush; then
            GITHUB_SYNC_STATUS=pending
            _github_report_last_error "Не удалось отправить начальную конфигурацию в GitHub"
            warn "Изменения сохранены локально и не отправлены."
        fi
    else
        case $'\n'"$tracked"$'\n' in
            *$'\nstorage.json\n'*) ;;
            *)
                _github_record_error "проверка существующего репозитория GitHub" \
                    "В репозитории есть данные, но отсутствует корректная конфигурация Essence. Репозиторий не изменён."
                _github_enable_rollback "$source_backup" "$source_had_file"
                return 1
                ;;
        esac
        if ! _github_storage_read ||
           { [[ $GITHUB_STORAGE_MODE == age ]] && ! _github_ensure_deps age; }; then
            _github_ensure_error "чтение существующей конфигурации GitHub" \
                "Не удалось проверить или расшифровать существующую конфигурацию. Репозиторий не изменён."
            _github_enable_rollback "$source_backup" "$source_had_file"
            return 1
        fi
        tmp_state=$(umask 077; mktemp "$CONFIG_DIR/.vault.XXXXXX") || {
            _github_record_error "чтение существующей конфигурации GitHub" \
                "Не удалось проверить или расшифровать существующую конфигурацию. Репозиторий не изменён."
            _github_enable_rollback "$source_backup" "$source_had_file"
            return 1
        }
        if ! github_config_open "$GITHUB_WORKTREE" "$tmp_state"; then
            _github_ensure_error "чтение существующей конфигурации GitHub" \
                "Не удалось проверить или расшифровать существующую конфигурацию. Репозиторий не изменён."
            _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
            return 1
        fi
        if ! _github_prompt_existing_config_action; then
            _github_record_error "выбор версии конфигурации" "Подключение GitHub отменено."
            _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
            return 1
        fi
        CONFIG_SOURCE=github
        if [[ "$GITHUB_EXISTING_ACTION" != remote ]]; then
            if ! _github_initial_portable_onboarding; then
                _github_ensure_error "подготовка переносимой конфигурации" \
                    "Не удалось подготовить локальные файлы для хранения в GitHub."
                _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
                return 1
            fi
            if ! github_config_serialize "$tmp_state" "$CONFIG_JSON" ||
               ! github_config_checkpoint "$tmp_state"; then
                _github_ensure_error "подготовка конфигурации к отправке" \
                    "Не удалось собрать конфигурацию для репозитория GitHub."
                _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
                return 1
            fi
            if ! github_sync_flush; then
                GITHUB_SYNC_STATUS=pending
                _github_report_last_error "Не удалось отправить начальную конфигурацию в GitHub"
                warn "Изменения сохранены локально и не отправлены."
            fi
        fi
    fi
    if ! github_source_metadata_write ||
       ! github_source_metadata_valid "$CONFIG_DIR/source.json"; then
        _github_ensure_error "сохранение настроек источника" \
            "Не удалось сохранить или проверить настройки источника GitHub."
        _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
        return 1
    fi
    if ! _config_source_materialize_state "$tmp_state"; then
        _github_ensure_error "проверка подключённого источника" \
            "Не удалось открыть конфигурацию из репозитория GitHub после подключения."
        _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
        return 1
    fi
    export CONFIG_SOURCE CONFIG_JSON SECRETS_JSON STATE_MANIFEST TEMPLATES_DIR
    export SSH_IDENTITIES_DIR SSH_KNOWN_HOSTS SCRIPT_AUTH_FILE STATE_DIR
    rm -f "$tmp_state" "$source_backup" ||
        warn "Не удалось удалить временные файлы завершённого подключения GitHub."
}
_github_sync_status_label() {
    case "$(github_sync_status)" in
        clean|synced) printf '%s\n' "синхронизировано" ;;
        pending) printf '%s\n' "есть неотправленные изменения" ;;
        offline) printf '%s\n' "нет связи с GitHub" ;;
        *) printf '%s\n' "состояние неизвестно" ;;
    esac
}

github_source_menu() {
    if [[ $CONFIG_SOURCE != github ]]; then
        if state_action "github_enable" github_enable_local; then
            success "Источник GitHub подключён."
            return 0
        fi
        _github_report_last_error "Не удалось подключить GitHub"
        warn "Продолжаем использовать локальную конфигурацию."
        return 1
    fi

    local _sync_status _encrypted_storage
    while true; do
        _sync_status=$(_github_sync_status_label)
        _encrypted_storage=false
        [[ ${GITHUB_STORAGE_MODE:-none} == age ]] && _encrypted_storage=true
    echo ""
    box_top
    box_center "Источник конфигурации GitHub"
    box_mid
    box_line " Состояние синхронизации: ${_sync_status}"
    box_mid
    box_line " F) Загрузить конфигурацию из GitHub" " ${CYAN}F)${NC} Загрузить конфигурацию из GitHub"
    box_line " P) Отправить локальную конфигурацию в GitHub" " ${GREEN}P)${NC} Отправить локальную конфигурацию в GitHub"
    box_line " C) Сменить аккаунт GitHub" " ${YELLOW}C)${NC} Сменить аккаунт GitHub"
    if [[ "$_encrypted_storage" == true ]]; then
        box_line " R) Сменить пароль доступа (ключ останется прежним)" " ${YELLOW}R)${NC} Сменить пароль доступа ${DIM}(ключ останется прежним)${NC}"
        box_line " V) Создать новый ключ шифрования" " ${YELLOW}V)${NC} Создать новый ключ шифрования"
        box_line "    Текущая конфигурация будет зашифрована заново" " ${DIM}   Текущая конфигурация будет зашифрована заново${NC}"
        box_line "    Старые версии в GitHub потребуют прежний ключ" " ${DIM}   Старые версии в GitHub потребуют прежний ключ${NC}"
        box_line "    Пароли нод при этом не меняются" " ${DIM}   Пароли нод при этом не меняются${NC}"
        box_line " I) Импортировать ключ восстановления" " ${YELLOW}I)${NC} Импортировать ключ восстановления"
    fi
    box_line " E) Использовать локальную конфигурацию без синхронизации с GitHub" " ${RED}E)${NC} Использовать локальную конфигурацию без синхронизации с GitHub"
    box_line " D) Удалить репозиторий GitHub" " ${RED}D)${NC} Удалить репозиторий GitHub"
    box_line " 0) Назад"
    box_bot
    echo ""
    if ! IFS= read -rp "  Выберите действие: " _sync_choice; then
        return 0
    fi
    _sync_choice="${_sync_choice%$'\r'}"
    case "$_sync_choice" in
        C|c)
            if github_source_change_account menu; then
                :
            else
                _github_report_last_error "Не удалось сменить аккаунт GitHub"
                return 1
            fi
            ;;
        F|f)
            if github_sync_fetch; then
                success "Конфигурация загружена из GitHub."
            else
                _github_report_last_error "Не удалось загрузить конфигурацию из GitHub"
            fi
            ;;
        P|p)
            if github_sync_flush; then
                success "Локальная конфигурация отправлена в GitHub."
            else
                _github_report_last_error "Не удалось отправить конфигурацию в GitHub"
                warn "Изменения сохранены локально и ожидают отправки."
            fi
            ;;
        R|r)
            if [[ "$_encrypted_storage" != true ]]; then
                warn "Неверный выбор."
            elif github_config_rewrap_master; then
                success "Пароль доступа изменён; ключ шифрования остался прежним."
            else
                if [[ -n "${GITHUB_LAST_ERROR:-}" ]]; then
                    _github_report_last_error "Не удалось изменить пароль доступа"
                else
                    warn "Не удалось изменить пароль доступа."
                fi
                return 1
            fi
            ;;
        V|v)
            if [[ "$_encrypted_storage" != true ]]; then
                warn "Неверный выбор."
            elif github_config_rotate_vault_key; then
                success "Новый ключ создан; текущая конфигурация зашифрована заново."
            else
                if [[ -n "${GITHUB_LAST_ERROR:-}" ]]; then
                    _github_report_last_error "Не удалось создать новый ключ шифрования"
                else
                    warn "Не удалось создать новый ключ шифрования."
                fi
                return 1
            fi
            ;;
        I|i)
            if [[ "$_encrypted_storage" != true ]]; then
                warn "Неверный выбор."
            else
                read -rp "  Путь к файлу с ключом восстановления: " _recovery
                if github_config_import_recovery "$_recovery"; then
                    success "Ключ восстановления импортирован для текущего сеанса."
                else
                    if [[ -n "${GITHUB_LAST_ERROR:-}" ]]; then
                        _github_report_last_error "Не удалось импортировать ключ восстановления"
                    else
                        warn "Не удалось импортировать ключ восстановления."
                    fi
                    return 1
                fi
            fi
            ;;
        E|e)
            if github_config_switch_local; then
                success "Используется локальная конфигурация; синхронизация с GitHub отключена."
                return 0
            else
                if [[ -n "${GITHUB_LAST_ERROR:-}" ]]; then
                    _github_report_last_error "Не удалось перейти на локальную конфигурацию"
                else
                    warn "Не удалось перейти на локальную конфигурацию."
                fi
                return 1
            fi
            ;;
        D|d)
            local _repo_to_delete
            _repo_to_delete=$(_github_repo)
            warn "Будет удалён репозиторий GitHub: $_repo_to_delete."
            warn "Конфигурация останется локально, синхронизация будет отключена."
            if confirm_yn "Удалить репозиторий $_repo_to_delete?" N; then
                if github_repository_delete "$_repo_to_delete"; then
                    success "Репозиторий $_repo_to_delete удалён. Конфигурация сохранена локально, синхронизация отключена."
                else
                    _github_report_last_error "Не удалось удалить репозиторий GitHub"
                    if [[ "$GITHUB_LAST_STAGE" == "удаление репозитория GitHub" ]]; then
                        if github_repository_open_settings "$_repo_to_delete"; then
                            info "Открыта страница настроек $_repo_to_delete. Завершите удаление в Danger Zone."
                        else
                            warn "Откройте страницу настроек и завершите удаление в Danger Zone: $(hyperlink "https://github.com/$_repo_to_delete/settings")"
                        fi
                    fi
                fi
            fi
            ;;
        0) return 0 ;;
        *) warn "Неверный выбор." ;;
    esac
    done
}
menu_nodes() {
    while true; do
        local count
        count=$(nodes_count)
        local _show_deferred_ssh_setup=false
        if [[ $CONFIG_SOURCE == github ]] &&
           state_actionable_ssh_setup_pending; then
            _show_deferred_ssh_setup=true
        fi


        local latest
        latest=$(latest_version)

        echo ""
        box_top
        box_center "Essence Remote Management"
        local _ver="версия: ${CURRENT_VERSION}"
        box_center "$_ver" "${DIM}${_ver}${NC}"
        if has_update "$CURRENT_VERSION"; then
            local _upd="↑ ${latest} — нажмите U"
            box_center "$_upd" "${YELLOW}↑ ${latest} — нажмите U${NC}"
        fi
        box_mid
        if [[ $count -eq 0 ]]; then
            box_line " (нод нет — добавьте первую)" " ${DIM}(нод нет — добавьте первую)${NC}"
        else
            local _num=1
            while IFS=$'\t' read -r _name _addr _tag; do
                local _tag_plain="" _tag_color=""
                [[ -n "$_tag" ]] && { _tag_plain=" [${_tag}]"; _tag_color=" ${DIM}[${_tag}]${NC}"; }
                box_line " ${_num}) ${_name}  ${_addr}${_tag_plain}" " ${GREEN}${_num})${NC} ${_name}  ${_addr}${_tag_color}"
                _num=$((_num + 1))
            done < <(jq_r '.nodes[] | "\(.name)\t\(.ip):\(.port)\t\(.tag // "")"')
        fi
        box_mid
        box_line " a) Добавить ноду" " ${GREEN}a)${NC} Добавить ноду"
        if [[ $count -gt 0 ]]; then
            box_line " n) Переименовать ноду" " ${YELLOW}n)${NC} Переименовать ноду"
            box_line " t) Тег ноды" " ${YELLOW}t)${NC} Тег ноды"
            box_line " d) Удалить ноду" " ${RED}d)${NC} Удалить ноду"
        fi
        box_mid
        box_line " C) Клиенты" " ${CYAN}C)${NC} Клиенты"
        box_line " G) Группы" " ${YELLOW}G)${NC} Группы"
        box_mid
        box_line " P) Подключения нод для групп" " ${YELLOW}P)${NC} Подключения нод для групп"
        if [[ $CONFIG_SOURCE == github ]] &&
           [[ "$_show_deferred_ssh_setup" == true ]]; then
            box_line " H) Завершить отложенную SSH-настройку нод" " ${YELLOW}H)${NC} Завершить отложенную SSH-настройку нод"
        fi
        box_line " W) AWG подключения" " ${CYAN}W)${NC} AWG подключения"
        box_line " b) Telegram Proxy" " ${CYAN}b)${NC} Telegram Proxy"
        box_mid
        box_line " F) Сгенерировать конфиги" " ${GREEN}F)${NC} Сгенерировать конфиги"
        box_line " S) Подписки" " ${GREEN}S)${NC} Подписки"
        box_mid
        if [[ $CONFIG_SOURCE == github ]]; then
            local _github_status _github_url _github_link
            _github_status=$(_github_sync_status_label)
            _github_url="https://github.com/$(_github_repo)"
            _github_link=$(hyperlink "$_github_url" "GitHub")
            box_line " Y) Источник конфигурации: GitHub • ${_github_status}" " ${CYAN}Y)${NC} Источник конфигурации: ${_github_link} • ${_github_status}"
        else
            box_line " Y) Источник конфигурации: локальный" " ${CYAN}Y)${NC} Источник конфигурации: локальный"
        fi
        box_line " U) Обновить скрипт" " ${CYAN}U)${NC} Обновить скрипт"
        box_line " L) Пароль скрипта" " ${YELLOW}L)${NC} Пароль скрипта"
        box_line " R) Удалить remote-control" " ${RED}R)${NC} Удалить remote-control"
        box_line " 0) Выход"
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите ноду или действие: " _pick; then
            echo ""; echo "  Выход."; exit 0
        fi
        _pick="${_pick%$'\r'}"
        case "$_pick" in
            0)
                echo ""; echo "  Выход."; exit 0
                ;;
            *)
                if menu_index_valid "$_pick" "$count"; then
                    node_load "$_pick"
                    menu_operations
                else
                    case "$_pick" in
                        a|A) state_action "add_node" add_node ;;
                        d|D)
                            [[ $count -gt 0 ]] && state_action "delete_node" delete_node ||
                                warn "Неверный выбор."
                            ;;
                        n|N)
                            [[ $count -gt 0 ]] && state_action "rename_node" rename_node ||
                                warn "Неверный выбор."
                            ;;
                        t|T)
                            [[ $count -gt 0 ]] && state_action "set_node_tag" set_node_tag ||
                                warn "Неверный выбор."
                            ;;
                        C|c) clients_menu ;;
                        P|p) connections_menu ;;
                        G|g) groups_menu ;;
                        F|f) generate_menu ;;
                        W|w) awg_peers_menu ;;
                        b|B) telegram_proxy_remote_menu ;;
                        S|s) subscription_menu ;;
                        Y|y) github_source_menu ;;
                        H|h)
                            [[ "$_show_deferred_ssh_setup" == true ]] &&
                                state_action "complete_portable_node_setup" complete_portable_node_setup ||
                                warn "Неверный выбор."
                            ;;
                        U|u) self_update ;;
                        L|l) state_action "set_script_password" set_script_password ;;
                        R|r) uninstall_self ;;
                        *) warn "Неверный выбор." ;;
                    esac
                fi
                ;;
        esac
    done
}

# ─── Меню операций (для выбранной ноды) ──────────────────────────────────────
menu_operations() {

    while true; do
        echo ""
        box_top
        local _node="${NODE_NAME}  (${SERVER_IP})"
        box_center "$_node" "${GREEN}${_node}${NC}"
        box_mid
        box_line " 1) Открыть меню сервера" " ${GREEN}1)${NC} Открыть меню сервера"
        box_line " b) Telegram Proxy" " ${CYAN}b)${NC} Telegram Proxy"
        box_mid
        box_line " h) Настройка SSH ключа на ноде" " ${YELLOW}h)${NC} Настройка SSH ключа на ноде"
        box_line " u) Обновить скрипты на сервере" " ${CYAN}u)${NC} Обновить скрипты на сервере"
        box_line " 0) Назад"
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите пункт: " CHOICE; then
            return 0
        fi
        CHOICE="${CHOICE%$'\r'}"

        case "$CHOICE" in
            1)
                if ssh_connect && upload_scripts; then
                    run_remote
                    echo ""
                    echo -e "  ${DIM}── SSH-сессия завершена ──────────────────${NC}"
                    confirm_yn "Продолжить работу с ${NODE_NAME}?" Y || return 0
                else
                    warn "Не удалось открыть SSH-сессию или загрузить скрипты."
                fi
                ;;
            b|B)
                TELEGRAM_PROXY_NODE_SCOPED=true telegram_proxy_remote_menu
                ;;
            h|H)        state_action "ssh_hardening" ssh_hardening ;;
            u|U)
                if ! upload_scripts; then
                    warn "Не удалось загрузить скрипты для ноды '${NODE_NAME}'."
                fi
                ;;

            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

first_run_source_menu() {
    [[ -f "$CONFIG_DIR/source.json" || -f "$CONFIG_DIR/config.json" ]] && return 0
    while true; do
        echo ""
        box_top
        box_center "Источник конфигурации"
        box_mid
        menu_item "1" "Хранить конфигурацию только на этом компьютере" GREEN
        menu_item "2" "Синхронизировать конфигурацию через GitHub" CYAN
        menu_item "0" "Выход"
        box_bot
        echo ""
        local choice
        if ! IFS= read -rp "  Выберите источник: " choice; then
            return 1
        fi
        choice="${choice%$'\r'}"
        case "$choice" in
            1)
                if state_open_local; then
                    return 0
                fi
                warn "Не удалось подготовить локальную конфигурацию."
                ;;
            2)
                if github_enable_local; then
                    success "Источник GitHub подключён."
                    return 0
                fi
                _github_report_last_error "Не удалось подключить GitHub"
                ;;
            0) return 1 ;;
            *) warn "Неверный выбор." ;;
        esac
        startup_recovery_menu "Восстановление источника конфигурации" true || return 1
    done
}

# ─── Точка входа ──────────────────────────────────────────────────────────────
if ! first_run_source_menu; then
    [[ -n "${GITHUB_LAST_ERROR:-}" ]] &&
        _github_report_last_error "Не удалось подключить GitHub"
    exit 1
fi
while ! config_source_startup; do
    if [[ "$CONFIG_SOURCE" == github || -n "${GITHUB_LAST_STAGE:-}" ]]; then
        _github_report_last_error "Не удалось открыть источник GitHub"
    else
        warn "Не удалось открыть источник конфигурации."
    fi
    startup_recovery_menu "Восстановление источника конфигурации" true || exit 1
done
if ! check_script_password; then
    exit 1
fi
menu_nodes
