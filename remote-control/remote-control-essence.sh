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

# ─── Авто-установка зависимостей (jq, openssl, ssh, scp, base64) ──────────────
if [[ -f "$SCRIPT_DIR/common/ensure-deps.sh" ]]; then
    source "$SCRIPT_DIR/common/ensure-deps.sh"
elif [[ -f "$SCRIPT_DIR/../common/ensure-deps.sh" ]]; then
    source "$SCRIPT_DIR/../common/ensure-deps.sh"
else
    echo "  [✗] Не найден common/ensure-deps.sh" >&2; exit 1
fi
ensure_dep jq openssl ssh scp base64

# ─── Подключаем модули ───────────────────────────────────────────────────────
if [[ -f "$SCRIPT_DIR/common/common.sh" ]]; then
    source "$SCRIPT_DIR/common/common.sh"
    source "$SCRIPT_DIR/common/protocols/vless-xhttp.sh"
elif [[ -f "$SCRIPT_DIR/../common/common.sh" ]]; then
    source "$SCRIPT_DIR/../common/common.sh"
    source "$SCRIPT_DIR/../common/protocols/vless-xhttp.sh"
fi
source "$SCRIPT_DIR/modules/state.sh"
source "$SCRIPT_DIR/modules/github-config.sh"
register_exit_cleanup github_config_close ||
    error "Не удалось зарегистрировать очистку временных файлов GitHub."
if github_source_metadata_valid "$CONFIG_DIR/source.json"; then
    CONFIG_SOURCE=github
fi

source "$SCRIPT_DIR/modules/nodes.sh"
source "$SCRIPT_DIR/modules/ssh.sh"
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
    if [[ ! "$password_hash" =~ ^\$6\$[./A-Za-z0-9]+\$[./A-Za-z0-9]+$ ]]; then
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
    local rollback_ok=true
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
        fi
        rm -rf "$publish" "$retired" || rollback_ok=false
        rm -f "$auth_backup" || rollback_ok=false
        if [[ "$rollback_ok" == true ]]; then
            _github_record_error "публикация рабочего состояния" \
                "Не удалось атомарно опубликовать новое рабочее состояние."
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
        rm -rf "$runtime" || rollback_ok=false
        if [[ "$had_runtime" == true ]] && ! mv "$retired" "$runtime"; then
            rollback_ok=false
        fi
        if [[ "$had_auth" == true ]]; then
            mv "$auth_backup" "$SCRIPT_AUTH_FILE" || rollback_ok=false
        else
            rm -f "$SCRIPT_AUTH_FILE" || rollback_ok=false
        fi
        rm -rf "$publish" "$retired" || rollback_ok=false
        rm -f "$auth_backup" || rollback_ok=false
        if [[ "$rollback_ok" == true ]]; then
            GITHUB_LAST_STAGE="$auth_stage"
            GITHUB_LAST_ERROR="$auth_detail"
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


config_source_startup() {
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
    _github_clear_error
    success "Источник GitHub подключён."
}

_github_sync_status_label() {
    case "$(github_sync_status)" in
        clean)   printf '%s\n' "синхронизировано" ;;
        pending) printf '%s\n' "есть неотправленные изменения" ;;
        offline) printf '%s\n' "нет связи с GitHub" ;;
        *)       printf '%s\n' "состояние неизвестно" ;;
    esac
}

github_source_menu() {
    if [[ $CONFIG_SOURCE != github ]]; then
        if ! state_action "github_enable" github_enable_local; then
            _github_report_last_error "Не удалось подключить GitHub"
            warn "Продолжаем использовать локальную конфигурацию."
            return 1
        fi
        return 0
    fi

    local _sync_status _encrypted_storage=false
    _sync_status=$(_github_sync_status_label)
    [[ ${GITHUB_STORAGE_MODE:-none} == age ]] && _encrypted_storage=true
    echo ""
    box_top
    box_center "Источник конфигурации GitHub"
    box_mid
    box_line " Состояние синхронизации: ${_sync_status}"
    box_mid
    box_line " F) Загрузить конфигурацию из GitHub" " ${CYAN}F)${NC} Загрузить конфигурацию из GitHub"
    box_line " P) Отправить локальную конфигурацию в GitHub" " ${GREEN}P)${NC} Отправить локальную конфигурацию в GitHub"
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
    read -rp "  Выберите действие: " _sync_choice
    case "$_sync_choice" in
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
                [[ -n "${GITHUB_LAST_ERROR:-}" ]] &&
                    _github_report_last_error "Не удалось изменить пароль доступа"
            fi
            ;;
        V|v)
            if [[ "$_encrypted_storage" != true ]]; then
                warn "Неверный выбор."
            elif github_config_rotate_vault_key; then
                success "Новый ключ создан; текущая конфигурация зашифрована заново."
            else
                [[ -n "${GITHUB_LAST_ERROR:-}" ]] &&
                    _github_report_last_error "Не удалось создать новый ключ шифрования"
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
                    [[ -n "${GITHUB_LAST_ERROR:-}" ]] &&
                        _github_report_last_error "Не удалось импортировать ключ восстановления"
                fi
            fi
            ;;
        E|e)
            if github_config_switch_local; then
                success "Используется локальная конфигурация; синхронизация с GitHub отключена."
            else
                [[ -n "${GITHUB_LAST_ERROR:-}" ]] &&
                    _github_report_last_error "Не удалось перейти на локальную конфигурацию"
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
        0|"") return 0 ;;
        *) warn "Неверный выбор." ;;
    esac
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
        read -rp "  Выберите ноду или действие: " _pick

        if [[ "$_pick" == "0" ]]; then
            echo ""; echo "  Выход."; exit 0
        elif [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= count )); then
            node_load "$_pick"
            menu_operations
        elif [[ "$_pick" == "a" || "$_pick" == "A" ]]; then
            state_action "add_node" add_node
        elif [[ $count -gt 0 ]] && [[ "$_pick" == "d" || "$_pick" == "D" ]]; then
            state_action "delete_node" delete_node
        elif [[ $count -gt 0 ]] && [[ "$_pick" == "n" || "$_pick" == "N" ]]; then
            state_action "rename_node" rename_node
        elif [[ $count -gt 0 ]] && [[ "$_pick" == "t" || "$_pick" == "T" ]]; then
            state_action "set_node_tag" set_node_tag
        elif [[ "$_pick" == "C" || "$_pick" == "c" ]]; then
            clients_menu
        elif [[ "$_pick" == "P" || "$_pick" == "p" ]]; then
            connections_menu
        elif [[ "$_pick" == "G" || "$_pick" == "g" ]]; then
            groups_menu
        elif [[ "$_pick" == "F" || "$_pick" == "f" ]]; then
            generate_menu
        elif [[ "$_pick" == "W" || "$_pick" == "w" ]]; then
            awg_peers_menu
        elif [[ "$_pick" == "S" || "$_pick" == "s" ]]; then
            subscription_menu
        elif [[ "$_pick" == "Y" || "$_pick" == "y" ]]; then
            github_source_menu
        elif [[ "$_show_deferred_ssh_setup" == true ]] &&
             [[ "$_pick" == "H" || "$_pick" == "h" ]]; then
            state_action "complete_portable_node_setup" complete_portable_node_setup
        elif [[ "$_pick" == "U" || "$_pick" == "u" ]]; then
            self_update
        elif [[ "$_pick" == "L" || "$_pick" == "l" ]]; then
            state_action "set_script_password" set_script_password
        elif [[ "$_pick" == "R" || "$_pick" == "r" ]]; then
            uninstall_self
        else
            warn "Неверный выбор."
        fi
    done
}

# ─── Меню операций (для выбранной ноды) ──────────────────────────────────────
menu_operations() {
    # Проверяем соединение и загружаем скрипты при первом входе
    echo ""
    ssh_connect || return
    upload_scripts

    while true; do
        echo ""
        box_top
        local _node="${NODE_NAME}  (${SERVER_IP})"
        box_center "$_node" "${GREEN}${_node}${NC}"
        box_mid
        box_line " 1) Открыть меню сервера" " ${GREEN}1)${NC} Открыть меню сервера"
        box_mid
        box_line " h) Настройка SSH ключа на ноде" " ${YELLOW}h)${NC} Настройка SSH ключа на ноде"
        box_line " u) Обновить скрипты на сервере" " ${CYAN}u)${NC} Обновить скрипты на сервере"
        box_line " 0) Назад"
        box_bot
        echo ""
        read -rp "  Выберите пункт: " CHOICE

        case "$CHOICE" in
            1)
                run_remote
                echo ""
                echo -e "  ${DIM}── SSH-сессия завершена ──────────────────${NC}"
                confirm_yn "Продолжить работу с ${NODE_NAME}?" Y || return
                ;;
            h|H)        state_action "ssh_hardening" ssh_hardening ;;
            u|U)        upload_scripts ;;

            0)          return ;;
            *)          warn "Неверный выбор: $CHOICE" ;;
        esac
    done
}

first_run_source_menu() {
    [[ -f "$CONFIG_DIR/source.json" || -f "$CONFIG_DIR/config.json" ]] && return 0
    echo ""
    box_top
    box_center "Источник конфигурации"
    box_mid
    box_line " 1) Хранить конфигурацию только на этом компьютере" " ${GREEN}1)${NC} Хранить конфигурацию только на этом компьютере"
    box_line " 2) Синхронизировать конфигурацию через GitHub" " ${CYAN}2)${NC} Синхронизировать конфигурацию через GitHub"
    box_line " 0) Выход"
    box_bot
    echo ""
    local choice
    read -rp "  Выберите источник: " choice
    case "$choice" in
        1) state_open_local ;;
        2) github_enable_local ;;
        0) exit 0 ;;
        *) warn "Неверный выбор."; return 1 ;;
    esac
}

# ─── Точка входа ──────────────────────────────────────────────────────────────
if ! first_run_source_menu; then
    if [[ -n "${GITHUB_LAST_ERROR:-}" ]]; then
        _github_report_last_error "Не удалось подключить GitHub"
        exit 1
    fi
    error "Не удалось выбрать источник конфигурации."
fi
config_source_startup || {
    if [[ "$CONFIG_SOURCE" == github || -n "${GITHUB_LAST_STAGE:-}" ]]; then
        _github_report_last_error "Не удалось открыть источник GitHub"
    else
        error "Не удалось открыть источник конфигурации."
    fi
    exit 1
}
check_script_password
menu_nodes
