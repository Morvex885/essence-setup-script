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

# ─── Авто-установка зависимостей (jq, openssl, ssh) ──────────────────────────
if [[ -f "$SCRIPT_DIR/common/ensure-deps.sh" ]]; then
    source "$SCRIPT_DIR/common/ensure-deps.sh"
elif [[ -f "$SCRIPT_DIR/../common/ensure-deps.sh" ]]; then
    source "$SCRIPT_DIR/../common/ensure-deps.sh"
else
    echo "  [✗] Не найден common/ensure-deps.sh" >&2; exit 1
fi
ensure_dep jq openssl ssh

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

_github_report_last_error() {
    local prefix="${1:-Не удалось выполнить операцию GitHub}"
    warn "${prefix} (этап: ${GITHUB_LAST_STAGE:-неизвестный этап}): ${GITHUB_LAST_ERROR:-причина не указана}"
    if _github_should_show_auth_hint; then
        warn "GitHub CLI сообщает, что вход не выполнен. Выполните: gh auth login"
    fi
}

_materialize_script_auth_from_state() {
    local logical="$1" password_hash tmp
    password_hash=$(jq -r '.access.script_password_hash // empty' "$logical" 2>/dev/null) ||
        return 1
    if [[ -z "$password_hash" ]]; then
        rm -f "$SCRIPT_AUTH_FILE"
        return
    fi
    [[ "$password_hash" =~ ^\$6\$[./A-Za-z0-9]+\$[./A-Za-z0-9]+$ ]] || {
        warn "Хеш пароля запуска в состоянии GitHub имеет некорректный формат."
        return 1
    }
    tmp=$(umask 077; mktemp "$CONFIG_DIR/.auth.XXXXXX") || return 1
    printf '%s\n' "$password_hash" > "$tmp" && chmod 600 "$tmp" &&
        mv "$tmp" "$SCRIPT_AUTH_FILE" || {
        rm -f "$tmp"
        return 1
    }
}

# ─── Текущая нода (глобальные переменные) ────────────────────────────────────
NODE_NAME=""
_config_source_materialize_state() {
    local logical="${1:?logical state}" runtime="${2:-$CONFIG_DIR/github-runtime}"
    local name
    rm -rf "$runtime"
    mkdir -p "$runtime/templates" "$runtime/ssh/identities" || return 1
    jq -e '.config' "$logical" > "$runtime/config.json" || return 1
    jq -e '.secrets' "$logical" > "$runtime/secrets.json" || return 1
    jq -e '{schema_version:2,minimum_remote_control_version,portability,templates}' \
        "$logical" > "$runtime/manifest.json" || return 1
    jq -j '.ssh.known_hosts // ""' "$logical" > "$runtime/ssh/known_hosts" || return 1
    while IFS= read -r name; do
        [[ "$name" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] || return 1
        jq -j --arg n "$name" '.templates[$n].content // ""' "$logical" \
            > "$runtime/templates/$name" || return 1
    done < <(jq -r '.templates // {} | keys[]' "$logical")
    while IFS= read -r name; do
        [[ "$name" =~ ^[0-9a-fA-F]{32}$ ]] || return 1
        jq -j --arg n "$name" '.ssh.identities[$n].private // ""' "$logical" \
            > "$runtime/ssh/identities/$name" || return 1
        jq -j --arg n "$name" '.ssh.identities[$n].public // ""' "$logical" \
            > "$runtime/ssh/identities/$name.pub" || return 1
        chmod 600 "$runtime/ssh/identities/$name"
        chmod 644 "$runtime/ssh/identities/$name.pub"
    done < <(jq -r '.ssh.identities // {} | keys[]' "$logical")
    chmod 700 "$runtime" "$runtime/templates" "$runtime/ssh" "$runtime/ssh/identities"
    chmod 600 "$runtime/secrets.json" "$runtime/manifest.json" "$runtime/ssh/known_hosts"
    CONFIG_SOURCE=github
    STATE_DIR="$runtime"; CONFIG_JSON="$runtime/config.json"; SECRETS_JSON="$runtime/secrets.json"
    STATE_MANIFEST="$runtime/manifest.json"; TEMPLATES_DIR="$runtime/templates"
    SSH_IDENTITIES_DIR="$runtime/ssh/identities"; SSH_KNOWN_HOSTS="$runtime/ssh/known_hosts"
    SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
    state_validate true >/dev/null
}

_config_source_materialize_github() {
    local logical="${1:-$CONFIG_DIR/runtime-vault.json}"
    [[ -n "${GITHUB_WORKTREE:-}" && -d "$GITHUB_WORKTREE" ]] || return 1
    if ! github_config_open "$GITHUB_WORKTREE" "$logical"; then
        _github_record_error "чтение конфигурации GitHub" \
            "Не удалось проверить или расшифровать состояние репозитория."
        return 1
    fi
    _materialize_script_auth_from_state "$logical" || return 1
    _config_source_materialize_state "$logical" "${2:-$CONFIG_DIR/github-runtime}"
}


config_source_startup() {
    if github_source_metadata_valid "$CONFIG_DIR/source.json"; then
        local source_repo source_branch source_owner
        source_repo=$(jq -er '.repo' "$CONFIG_DIR/source.json") || {
            warn "source.json не содержит репозиторий GitHub."
            return 1
        }
        source_branch=$(jq -er '.branch' "$CONFIG_DIR/source.json") || {
            warn "source.json не содержит ветку GitHub."
            return 1
        }
        source_owner="${source_repo%%/*}"
        CONFIG_SOURCE=github
        GITHUB_OWNER="$source_owner"
        GITHUB_BRANCH="$source_branch"
        GITHUB_REMOTE="$source_repo"
        if ! github_sync_init; then
            _github_report_last_error "Не удалось открыть источник GitHub"
            return 1
        fi
        if ! _config_source_materialize_github; then
            _github_report_last_error "Не удалось открыть источник GitHub"
            return 1
        fi
    elif legacy_local_source_metadata_valid "$CONFIG_DIR/source.json"; then
        state_open_local || return 1
        if ! rm -f "$CONFIG_DIR/source.json"; then
            warn "Не удалось удалить устаревший локальный source.json."
            return 1
        fi
        CONFIG_SOURCE=local
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
    [[ -z "$serialized_state" ]] || rm -f "$serialized_state"
    github_config_close >/dev/null 2>&1 || true
    if [[ "$source_had_file" == true ]]; then
        cp "$source_backup" "$CONFIG_DIR/source.json" &&
            chmod 600 "$CONFIG_DIR/source.json" || restore_ok=false
    else
        rm -f "$CONFIG_DIR/source.json" || restore_ok=false
    fi
    rm -f "$source_backup"
    if ! state_open_local; then
        restore_ok=false
    fi
    if [[ "$restore_ok" != true ]]; then
        warn "Не удалось восстановить локальный источник конфигурации."
    fi
    return 1
}


github_enable_local() {
    [[ $CONFIG_SOURCE == local ]] || return 0
    _github_clear_error
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
            _github_ensure_deps age || ! github_config_age_init
        }; then
            _github_record_error "настройка шифрования конфигурации" \
                "Не удалось подготовить ключи шифрования."
            _github_enable_rollback "$source_backup" "$source_had_file"
            return 1
        fi
        CONFIG_SOURCE=github
        if ! _github_initial_portable_onboarding; then
            _github_record_error "подготовка переносимой конфигурации" \
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
            _github_record_error "подготовка конфигурации к отправке" \
                "Не удалось собрать конфигурацию для репозитория GitHub."
            _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
            return 1
        fi
        github_sync_flush || {
            GITHUB_SYNC_STATUS=pending
            warn "Изменения сохранены локально и не отправлены."
        }
        if ! _materialize_script_auth_from_state "$tmp_state" ||
           ! _config_source_materialize_state "$tmp_state"; then
            _github_record_error "проверка подключённого источника" \
                "Не удалось открыть конфигурацию из репозитория GitHub после подключения."
            _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
            return 1
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
        if [[ $GITHUB_STORAGE_MODE == age ]] && ! _github_ensure_deps age; then
            _github_record_error "чтение существующей конфигурации GitHub" \
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
            _github_record_error "чтение существующей конфигурации GitHub" \
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
        if [[ "$GITHUB_EXISTING_ACTION" == remote ]]; then
            if ! _materialize_script_auth_from_state "$tmp_state" ||
               ! _config_source_materialize_state "$tmp_state"; then
                _github_record_error "проверка подключённого источника" \
                    "Не удалось открыть конфигурацию из репозитория GitHub после подключения."
                _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
                return 1
            fi
        else
            if ! _github_initial_portable_onboarding; then
                _github_record_error "подготовка переносимой конфигурации" \
                    "Не удалось подготовить локальные файлы для хранения в GitHub."
                _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
                return 1
            fi
            if ! github_config_serialize "$tmp_state" "$CONFIG_JSON" ||
               ! github_config_checkpoint "$tmp_state"; then
                _github_record_error "подготовка конфигурации к отправке" \
                    "Не удалось собрать конфигурацию для репозитория GitHub."
                _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
                return 1
            fi
            github_sync_flush || {
                GITHUB_SYNC_STATUS=pending
                warn "Изменения сохранены локально и не отправлены."
            }
            if ! _materialize_script_auth_from_state "$tmp_state" ||
               ! _config_source_materialize_state "$tmp_state"; then
                _github_record_error "проверка подключённого источника" \
                    "Не удалось открыть конфигурацию из репозитория GitHub после подключения."
                _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
                return 1
            fi
        fi
    fi
    export CONFIG_SOURCE CONFIG_JSON SECRETS_JSON STATE_MANIFEST TEMPLATES_DIR
    export SSH_IDENTITIES_DIR SSH_KNOWN_HOSTS SCRIPT_AUTH_FILE STATE_DIR
    if ! github_source_metadata_write; then
        _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
        return 1
    fi
    if [[ "$CONFIG_SOURCE" != github ]] ||
       [[ "$CONFIG_JSON" != "$CONFIG_DIR/github-runtime/config.json" ]] ||
       ! github_source_metadata_valid "$CONFIG_DIR/source.json"; then
        _github_record_error "проверка подключённого источника" \
            "Не удалось сохранить или проверить настройки источника GitHub."
        _github_enable_rollback "$source_backup" "$source_had_file" "$tmp_state"
        return 1
    fi
    rm -f "$tmp_state" "$source_backup"
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
            github_sync_fetch ||
                _github_report_last_error "Не удалось загрузить конфигурацию из GitHub"
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
            if [[ "$_encrypted_storage" == true ]]; then
                github_config_rewrap_master &&
                    success "Пароль доступа изменён; ключ шифрования остался прежним."
            else
                warn "Неверный выбор."
            fi
            ;;
        V|v)
            if [[ "$_encrypted_storage" == true ]]; then
                github_config_rotate_vault_key &&
                    success "Новый ключ создан; текущая конфигурация зашифрована заново."
            else
                warn "Неверный выбор."
            fi
            ;;
        I|i)
            if [[ "$_encrypted_storage" == true ]]; then
                read -rp "  Путь к файлу с ключом восстановления: " _recovery
                github_config_import_recovery "$_recovery" &&
                    success "Ключ восстановления импортирован для текущего сеанса."
            else
                warn "Неверный выбор."
            fi
            ;;
        E|e)
            github_config_switch_local &&
                success "Используется локальная конфигурация; синхронизация с GitHub отключена."
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
check_deps
first_run_source_menu || error "Не удалось выбрать источник конфигурации."
config_source_startup || error "Не удалось открыть источник конфигурации."
check_script_password
menu_nodes
