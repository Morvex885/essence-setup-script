#!/bin/bash
# GitHub-backed portable configuration vault. This module is deliberately
# self-contained: state.sh owns logical state, while this file owns layout and
# transport boundaries.

GITHUB_REPO_NAME="${GITHUB_REPO_NAME:-essence-remote-control-config}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITHUB_STORE="${GITHUB_STORE:-${CONFIG_DIR:-.}/github-store.git}"
GITHUB_SESSIONS_DIR="${GITHUB_SESSIONS_DIR:-${CONFIG_DIR:-.}/github-sessions}"
GITHUB_CREDENTIALS_DIR="${GITHUB_CREDENTIALS_DIR:-${CONFIG_DIR:-.}/credentials}"
GITHUB_UNLOCK_FILE="${GITHUB_CREDENTIALS_DIR}/github-config.agekey"
AGE_BIN="${AGE_BIN:-age}"
AGE_KEYGEN_BIN="${AGE_KEYGEN_BIN:-age-keygen}"
GITHUB_SYNC_STATUS="${GITHUB_SYNC_STATUS:-clean}"
GITHUB_SESSION_ID="${GITHUB_SESSION_ID:-}"
GITHUB_WORKTREE="${GITHUB_WORKTREE:-}"
GITHUB_REMOTE="${GITHUB_REMOTE:-}"
GITHUB_LAST_STAGE="${GITHUB_LAST_STAGE:-}"
GITHUB_LAST_ERROR="${GITHUB_LAST_ERROR:-}"
GITHUB_LAST_HINT="${GITHUB_LAST_HINT:-}"
GITHUB_LAST_AUTH_RELEVANT="${GITHUB_LAST_AUTH_RELEVANT:-false}"
GITHUB_SESSION_REMOTE="${GITHUB_SESSION_REMOTE:-}"
GITHUB_SESSION_BRANCH="${GITHUB_SESSION_BRANCH:-}"
GITHUB_SESSION_ORIGIN="${GITHUB_SESSION_ORIGIN:-}"

_github_clear_error() {
    GITHUB_LAST_STAGE=""
    GITHUB_LAST_ERROR=""
    GITHUB_LAST_HINT=""
    GITHUB_LAST_AUTH_RELEVANT=false
}

_github_safe_error() {
    local message="${1:-}"
    message=$(printf '%s' "$message" |
        LC_ALL=C tr -cd '\11\12\15\40-\176\200-\377' |
        tr '\r' ' ' |
        awk 'BEGIN { first=1 } {
            if (!first) printf " __GH_NL__ "
            printf "%s", $0
            first=0
        } END { print "" }' |
        sed -E \
            -e 's#([Hh][Tt][Tt][Pp][Ss]?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1[скрыто]@#g' \
            -e 's/([Gg][Ii][Tt][Hh][Uu][Bb]_[Pp][Aa][Tt]_|[Gg][Hh][PpOoUuSsRr]_)[[:space:]]*(__GH_NL__[[:space:]]*)?[A-Za-z0-9_]+/[скрыто]/g' \
            -e 's/([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn][[:space:]]*:[[:space:]]*(__GH_NL__[[:space:]]*)?([Bb][Ee][Aa][Rr][Ee][Rr]|[Tt][Oo][Kk][Ee][Nn])[[:space:]]+)[^[:space:]]+/\1[скрыто]/g' \
            -e 's/(([Bb][Ee][Aa][Rr][Ee][Rr]|[Tt][Oo][Kk][Ee][Nn])[[:space:]]+(__GH_NL__[[:space:]]+)?)[^[:space:]]+/\1[скрыто]/g' \
            -e 's/(([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn])([[:space:]]|__GH_NL__)*[=:]([[:space:]]|__GH_NL__)*)[^[:space:]]+([[:space:]]+__GH_NL__[[:space:]]+[^[:space:]]+)?/\1[скрыто]/g' \
            -e 's/(([Bb][Ee][Aa][Rr][Ee][Rr]|[Tt][Oo][Kk][Ee][Nn])[[:space:]]+(__GH_NL__[[:space:]]+)?)[^[:space:]]+/\1[скрыто]/g' \
            -e 's/[[:space:]]*__GH_NL__[[:space:]]*/ /g')
    message="${message:0:500}"
    printf '%s\n' "${message:-операция завершилась с ошибкой без дополнительного сообщения}"
}

_github_record_error() {
    GITHUB_LAST_STAGE=$(_github_safe_error "${1:-}")
    GITHUB_LAST_ERROR=$(_github_safe_error "${2:-}")
    GITHUB_LAST_AUTH_RELEVANT="${3:-false}"
    if [[ -n "${4:-}" ]]; then
        GITHUB_LAST_HINT=$(_github_safe_error "$4")
    else
        GITHUB_LAST_HINT=""
    fi
}
_github_ensure_error() {
    if [[ -z ${GITHUB_LAST_ERROR:-} ]]; then
        _github_record_error "$1" "${2:-}" "${3:-false}" "${4:-}"
    fi
    return 1
}

_github_auth_failure_confirmed() {
    local output="${1:-}"
    printf '%s\n' "$output" | grep -Eiq \
        '(^|[^0-9])401([^0-9]|$)|bad credentials|not logged|not authenticated|authentication (failed|required)|token[^[:alnum:]]*(is )?(invalid|expired|revoked)'
}
_github_should_show_auth_hint() {
    [[ ${GITHUB_LAST_AUTH_RELEVANT:-false} == true ]]
}
_github_report_last_error() {
    local prefix
    prefix=$(_github_safe_error "${1:-Не удалось выполнить операцию GitHub}")
    warn "${prefix} (этап: ${GITHUB_LAST_STAGE:-неизвестный этап}): ${GITHUB_LAST_ERROR:-причина не указана}"
    if [[ -n ${GITHUB_LAST_HINT:-} ]]; then
        warn "$GITHUB_LAST_HINT"
    elif _github_should_show_auth_hint; then
        warn "GitHub CLI сообщает, что вход не выполнен. Выполните: gh auth login --hostname github.com"
    fi
}

_github_require() { command -v "$1" >/dev/null 2>&1; }
_github_mkdir_secure() {
    umask 077
    local dir
    for dir in "$@"; do
        if [[ -e "$dir" || -L "$dir" ]]; then
            [[ -d "$dir" && ! -L "$dir" ]] || return 1
        else
            mkdir -p "$dir" || return 1
        fi
        [[ -d "$dir" && ! -L "$dir" ]] || return 1
        chmod 700 "$dir" || return 1
    done
}
_github_ensure_deps() {
    local mode="${1:-}" remote="${2:-${GITHUB_REMOTE:-}}"
    if declare -F ensure_dep >/dev/null 2>&1; then
        ensure_dep git gh || return 1
        if [[ "$mode" == age ]]; then ensure_dep age || return 1; fi
    else
        _github_require git || return 1
        if [[ "$remote" != /* && "$remote" != *.git && "$remote" != file://* ]]; then
            _github_require gh || return 1
        fi
        [[ "$mode" != age ]] || _github_require "$AGE_BIN"
    fi
}
_github_load_active_login() {
    local gh="${GH_BIN:-gh}" output
    _github_clear_error
    if ! _github_require "$gh"; then
        _github_record_error "проверка зависимостей" \
            "Не найдена команда GitHub CLI: $gh."
        return 1
    fi
    if ! output=$(NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" api user --jq .login 2>&1); then
        local auth_relevant=false
        _github_auth_failure_confirmed "$output" && auth_relevant=true
        _github_record_error "определение пользователя GitHub" "$output" "$auth_relevant"
        return 1
    fi
    output=$(printf '%s' "$output" | tr -d '\r\n')
    [[ "$output" =~ ^[A-Za-z0-9-]+$ ]] || {
        _github_record_error "определение пользователя GitHub" \
            "GitHub CLI не вернул имя активного аккаунта."
        return 1
    }
    GITHUB_ACTIVE_LOGIN="$output"
    export GITHUB_ACTIVE_LOGIN
}

_github_switch_active_account() {
    local login="${1-}" gh="${GH_BIN:-gh}" switch_stderr switch_output
    local -a switch_args
    if (( $# > 0 )); then
        [[ "$login" =~ ^[A-Za-z0-9-]+$ ]] || {
            _github_record_error "переключение аккаунта GitHub" \
                "Указано некорректное имя аккаунта GitHub."
            return 1
        }
        switch_args=(auth switch --hostname github.com --user "$login")
    else
        switch_args=(auth switch --hostname github.com)
    fi
    switch_stderr=$(umask 077; mktemp "${TMPDIR:-/tmp}/github-switch.XXXXXX") || {
        _github_record_error "переключение аккаунта GitHub" \
            "Не удалось подготовить безопасную диагностику переключения аккаунта."
        return 1
    }
    if ! NO_COLOR=1 "$gh" "${switch_args[@]}" 2>"$switch_stderr"; then
        switch_output=$(cat "$switch_stderr")
        rm -f "$switch_stderr"
        _github_record_error "переключение аккаунта GitHub" \
            "${switch_output:-Не удалось переключить аккаунт GitHub.}"
        return 1
    fi
    rm -f "$switch_stderr"
    _github_load_active_login
}

_github_select_account() {
    local initial_login="${1:-}" current_owner="${2:-}" login answer option_one
    _github_clear_error
    if ! _github_ensure_deps; then
        _github_record_error "проверка зависимостей" \
            "Не удалось подготовить GitHub CLI для выбора аккаунта."
        return 1
    fi
    if [[ -n "$initial_login" ]]; then
        login="$initial_login"
    elif ! _github_load_active_login; then
        return 1
    else
        login="$GITHUB_ACTIVE_LOGIN"
    fi
    while :; do
        info "Выбран аккаунт GitHub: $login"
        if [[ -n "$current_owner" && "$current_owner" == "$login" ]]; then
            option_one="Продолжить с $login (текущий источник)"
        else
            option_one="Использовать $login для конфигурации"
        fi
        echo -e "  ${GREEN}1)${NC} $option_one"
        if [[ -n "$current_owner" && "$current_owner" != "$login" ]]; then
            echo -e "  ${DIM}Сначала скрипт проверит репозиторий этого аккаунта.${NC}"
        fi
        echo -e "  ${CYAN}2)${NC} Выбрать другой аккаунт GitHub"
        echo -e "  ${RED}0)${NC} Отмена — ничего не менять"
        if ! read -rp "  Выберите действие: " answer; then
            _github_record_error "выбор аккаунта GitHub" \
                "Выбор аккаунта GitHub отменён."
            return 1
        fi
        case "$answer" in
            1)
                GITHUB_OWNER="$login"
                GITHUB_ACTIVE_LOGIN="$login"
                export GITHUB_OWNER GITHUB_ACTIVE_LOGIN
                return 0
                ;;
            2)
                _github_switch_active_account || return 1
                login="$GITHUB_ACTIVE_LOGIN"
                ;;
            0)
                _github_record_error "выбор аккаунта GitHub" \
                    "Выбор аккаунта GitHub отменён."
                return 1
                ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}


_github_run_with_timeout() {
    run_with_timeout "$@"
}

_github_validate_tree() {
    local root="$1" mode="${2:-auto}" list path rel name kind
    if [[ ! -d "$root" || -L "$root" ]]; then
        _github_record_error "проверка файлов репозитория GitHub" \
            "Корень рабочей копии GitHub не является обычным каталогом."
        return 1
    fi
    if [[ -e "$root/.git" || -L "$root/.git" ]]; then
        if [[ -L "$root/.git" ]] ||
           { [[ ! -f "$root/.git" ]] && [[ ! -d "$root/.git" ]]; }; then
            _github_record_error "проверка файлов репозитория GitHub" \
                "Служебный путь .git имеет недопустимый тип."
            return 1
        fi
    fi
    list=$(umask 077; mktemp "${TMPDIR:-/tmp}/github-tree.XXXXXX") || {
        _github_record_error "проверка файлов репозитория GitHub" \
            "Не удалось подготовить безопасный список файлов."
        return 1
    }
    if ! find "$root" -mindepth 1 -path "$root/.git" -prune -o -print0 > "$list"; then
        rm -f "$list"
        _github_record_error "проверка файлов репозитория GitHub" \
            "Не удалось перечислить файлы рабочей копии GitHub."
        return 1
    fi
    while IFS= read -r -d '' path; do
        rel="${path#"$root"/}"
        if [[ -L "$path" ]]; then
            kind=link
        elif [[ -f "$path" ]]; then
            kind=file
        elif [[ -d "$path" ]]; then
            kind=dir
        else
            kind=special
        fi
        case "$mode:$kind:$rel" in
            auto:file:storage.json|auto:file:recipient.txt|auto:file:unlock.age|auto:file:state.json.age|\
            auto:file:config.json|auto:file:secrets.json|auto:file:manifest.json|auto:file:ssh/known_hosts|\
            age:file:storage.json|age:file:recipient.txt|age:file:unlock.age|age:file:state.json.age|\
            none:file:storage.json|none:file:config.json|none:file:secrets.json|none:file:manifest.json|none:file:ssh/known_hosts)
                ;;
            auto:dir:templates|auto:dir:ssh|auto:dir:ssh/identities|\
            none:dir:templates|none:dir:ssh|none:dir:ssh/identities)
                ;;
            auto:file:templates/*.yaml|none:file:templates/*.yaml)
                name="${rel#templates/}"
                [[ "$name" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] || kind=invalid
                ;;
            auto:file:ssh/identities/*|none:file:ssh/identities/*)
                name="${rel#ssh/identities/}"
                [[ "$name" =~ ^[0-9a-fA-F]{32}(\.pub)?$ ]] || kind=invalid
                ;;
            *) kind=invalid ;;
        esac
        if [[ "$kind" == invalid || "$kind" == link || "$kind" == special ]]; then
            rm -f "$list"
            _github_record_error "проверка файлов репозитория GitHub" \
                "В хранилище конфигурации GitHub обнаружен недопустимый путь: $rel"
            return 1
        fi
    done < "$list"
    if ! rm -f "$list"; then
        _github_record_error "проверка файлов репозитория GitHub" \
            "Не удалось удалить временный список файлов."
        return 1
    fi
}

_github_prompt_storage_mode() {
    local answer
    while :; do
        echo -e "  ${GREEN}1)${NC} Зашифровать паролем"
        echo -e "  ${CYAN}2)${NC} Хранить без шифрования"
        read -rp "  Выберите 1 или 2: " answer
        case "$answer" in 1) GITHUB_STORAGE_MODE=age; return 0;; 2) GITHUB_STORAGE_MODE=none; return 0;; esac
    done
}
_github_prompt_existing_config_action() {
    local allow_local="${1:-true}" answer mode_label
    case "${GITHUB_STORAGE_MODE:-}" in
        age) mode_label="зашифровано паролем" ;;
        none) mode_label="без шифрования" ;;
        *) return 1 ;;
    esac
    info "В GitHub уже сохранена конфигурация (режим хранения: $mode_label)."
    while :; do
        echo "  1) Загрузить конфигурацию из GitHub"
        if [[ "$allow_local" == true ]]; then
            echo "  2) Заменить конфигурацию в GitHub текущей локальной"
        fi
        echo "  0) Отмена"
        if ! IFS= read -rp "  Выберите действие: " answer; then
            return 1
        fi
        case "$answer" in
            1) GITHUB_EXISTING_ACTION=remote; return 0 ;;
            2) [[ "$allow_local" == true ]] || { warn "Неверный выбор."; continue; }
               GITHUB_EXISTING_ACTION=local; return 0 ;;
            0) return 1 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}
_github_prompt_remember_unlock() {
    local answer
    while :; do
        printf 'Сохранить ключ расшифровки на этом устройстве? (y/n): '
        IFS= read -r answer || return 1
        case "$answer" in y|Y) return 0;; n|N) return 1;; esac
    done
}

_github_storage_init() {
    local mode=${1:-${GITHUB_STORAGE_MODE:-}} tmp
    [[ $mode == age || $mode == none ]] || {
        _github_record_error "подготовка параметров хранения GitHub" \
            "Указан неподдерживаемый режим хранения конфигурации GitHub."
        return 1
    }
    _github_validate_tree "$GITHUB_WORKTREE" auto || return 1
    if [[ -L "$GITHUB_WORKTREE/storage.json" ]] ||
       { [[ -e "$GITHUB_WORKTREE/storage.json" ]] &&
         ! _github_exact_regular_file "$GITHUB_WORKTREE/storage.json"; }; then
        _github_record_error "сохранение параметров хранения GitHub" \
            "Путь storage.json имеет недопустимый тип."
        return 1
    fi
    tmp=$(umask 077; mktemp "$GITHUB_WORKTREE/.storage.json.XXXXXX") || return 1
    if ! printf '{"storage_version":1,"encryption":"%s"}\n' "$mode" > "$tmp" ||
       ! chmod 644 "$tmp" || ! mv "$tmp" "$GITHUB_WORKTREE/storage.json"; then
        rm -f "$tmp"
        _github_record_error "сохранение параметров хранения GitHub" \
            "Не удалось атомарно сохранить параметры хранения конфигурации GitHub."
        return 1
    fi
    GITHUB_STORAGE_MODE=$mode
}
_github_storage_read() {
    _github_validate_tree "$GITHUB_WORKTREE" auto || return 1
    _github_exact_regular_file "$GITHUB_WORKTREE/storage.json" &&
        [[ -s "$GITHUB_WORKTREE/storage.json" ]] || {
        _github_record_error "чтение параметров хранения GitHub" \
            "Не удалось прочитать параметры хранения конфигурации GitHub."
        return 1
    }
    GITHUB_STORAGE_MODE=$(jq -er '
        select(type=="object" and .storage_version == 1 and
            (.encryption == "age" or .encryption == "none")) | .encryption
    ' "$GITHUB_WORKTREE/storage.json" 2>/dev/null) || {
        _github_record_error "проверка параметров хранения GitHub" \
            "Параметры хранения конфигурации GitHub имеют некорректный формат."
        return 1
    }
}
github_config_prompt_master() {
    _github_clear_error
    local first second
    if ! read -rsp "Введите пароль доступа к зашифрованной конфигурации: " first; then
        printf '\n'
        _github_record_error "ввод пароля шифрования" "Не удалось прочитать пароль доступа."
        return 1
    fi
    printf '\n'
    [[ -n "$first" ]] || {
        _github_record_error "ввод пароля шифрования" \
            "Пароль доступа не может быть пустым."
        return 1
    }
    if ! read -rsp "Повторите пароль доступа: " second; then
        printf '\n'
        _github_record_error "ввод пароля шифрования" "Не удалось прочитать пароль доступа."
        return 1
    fi
    printf '\n'
    [[ "$first" == "$second" ]] || {
        _github_record_error "ввод пароля шифрования" \
            "Введённые пароли доступа не совпадают."
        return 1
    }
    GITHUB_MASTER_PASSWORD="$first"
}
github_config_age_init() {
    _github_clear_error
    if ! _github_require "$AGE_BIN"; then
        _github_record_error "проверка зависимостей" "Не найдена команда age: $AGE_BIN."
        return 1
    fi
    github_config_prompt_master || return 1
    if ! _github_mkdir_secure "$GITHUB_CREDENTIALS_DIR" ||
       ! _github_validate_tree "$GITHUB_WORKTREE" auto; then
        unset GITHUB_MASTER_PASSWORD
        _github_ensure_error "подготовка локального ключа" \
            "Не удалось подготовить защищённые пути ключа."
        return 1
    fi
    local identity recipient recipient_tmp unlock_tmp backup path failed=false
    local had_recipient=false had_unlock=false
    local old_identity="${GITHUB_IDENTITY:-}" old_recipient="${GITHUB_RECIPIENT:-}"
    identity=$(_github_new_private_path "$CONFIG_DIR/.github-identity.XXXXXX") || {
        unset GITHUB_MASTER_PASSWORD
        return 1
    }
    recipient_tmp=$(umask 077; mktemp "$GITHUB_WORKTREE/.recipient.XXXXXX") || {
        rm -f "$identity"
        unset GITHUB_MASTER_PASSWORD
        return 1
    }
    unlock_tmp=$(_github_new_private_path "$GITHUB_WORKTREE/.unlock.XXXXXX") || {
        _github_remove_private_path "$identity"
        rm -f "$recipient_tmp"
        unset GITHUB_MASTER_PASSWORD
        return 1
    }
    if command -v "$AGE_KEYGEN_BIN" >/dev/null 2>&1; then
        (umask 077; "$AGE_KEYGEN_BIN" > "$identity" 2>/dev/null) || failed=true
    else
        (umask 077; "$AGE_BIN" -gen-key > "$identity" 2>/dev/null) ||
            (umask 077; "$AGE_BIN" -keygen > "$identity" 2>/dev/null) ||
            failed=true
    fi
    recipient=$(sed -n 's/^# public key: *//p' "$identity" 2>/dev/null |
        tr -d '\r\n') || failed=true
    [[ -n "$recipient" ]] || failed=true
    if [[ "$failed" != true ]] &&
       { ! printf '%s\n' "$recipient" > "$recipient_tmp" ||
         ! chmod 644 "$recipient_tmp" ||
         ! _github_exact_regular_file "$identity" ||
         ! chmod 600 "$identity" ||
         ! (umask 077
             printf '%s\n%s\n' "$GITHUB_MASTER_PASSWORD" "$GITHUB_MASTER_PASSWORD" |
                 "$AGE_BIN" -p -o "$unlock_tmp" "$identity" >/dev/null 2>&1
         ) ||
         ! _github_exact_regular_file "$unlock_tmp" ||
         ! chmod 600 "$unlock_tmp"; }; then
        failed=true
    fi
    unset GITHUB_MASTER_PASSWORD
    if [[ "$failed" == true ]]; then
        _github_remove_private_path "$identity"
        _github_remove_private_path "$unlock_tmp"
        rm -f "$recipient_tmp"
        GITHUB_IDENTITY="$old_identity"
        GITHUB_RECIPIENT="$old_recipient"
        _github_record_error "шифрование ключа конфигурации" \
            "Не удалось подготовить атомарный комплект ключей age."
        return 1
    fi
    backup=$(umask 077; mktemp -d "$CONFIG_DIR/.age-init-backup.XXXXXX") || {
        _github_remove_private_path "$identity"
        _github_remove_private_path "$unlock_tmp"
        rm -f "$recipient_tmp"
        GITHUB_IDENTITY="$old_identity"
        GITHUB_RECIPIENT="$old_recipient"
        return 1
    }
    for path in recipient.txt unlock.age; do
        if [[ -e "$GITHUB_WORKTREE/$path" || -L "$GITHUB_WORKTREE/$path" ]]; then
            case "$path" in
                recipient.txt) had_recipient=true ;;
                unlock.age) had_unlock=true ;;
            esac
            if ! cp -p "$GITHUB_WORKTREE/$path" "$backup/$path"; then
                failed=true
                break
            fi
        fi
    done
    if [[ "$failed" != true ]] &&
       { ! mv "$recipient_tmp" "$GITHUB_WORKTREE/recipient.txt" ||
         ! mv "$unlock_tmp" "$GITHUB_WORKTREE/unlock.age"; }; then
        failed=true
    fi
    if [[ "$failed" == true ]]; then
        _github_remove_private_path "$unlock_tmp"
        _github_remove_private_path "$identity"
        rm -f "$recipient_tmp"
        if [[ -e "$backup/recipient.txt" ]]; then
            mv "$backup/recipient.txt" "$GITHUB_WORKTREE/recipient.txt" || return 1
        elif [[ "$had_recipient" != true ]]; then
            rm -f "$GITHUB_WORKTREE/recipient.txt" || return 1
        fi
        if [[ -e "$backup/unlock.age" ]]; then
            mv "$backup/unlock.age" "$GITHUB_WORKTREE/unlock.age" || return 1
        elif [[ "$had_unlock" != true ]]; then
            rm -f "$GITHUB_WORKTREE/unlock.age" || return 1
        fi
        rm -rf "$backup" || return 1
        GITHUB_IDENTITY="$old_identity"
        GITHUB_RECIPIENT="$old_recipient"
        _github_record_error "сохранение параметров шифрования" \
            "Не удалось опубликовать комплект ключей age."
        return 1
    fi
    _github_remove_private_path "$unlock_tmp" ||
        warn "Защищённый staging-каталог ключа требует ручной очистки."
    GITHUB_IDENTITY="$identity"
    GITHUB_RECIPIENT="$recipient"
    export GITHUB_IDENTITY GITHUB_RECIPIENT
    if ! rm -rf "$backup"; then
        warn "Комплект ключей создан, но защищённая резервная копия требует ручной очистки: $backup"
    fi
}
github_config_unlock() {
    _github_clear_error
    local attempts=3 pass id="${GITHUB_UNLOCK_FILE:-}" check
    local original_identity="${GITHUB_IDENTITY:-}" imported_valid=false
    if _github_exact_regular_file "$original_identity" &&
       [[ -s "$original_identity" ]] &&
       "$AGE_KEYGEN_BIN" -y "$original_identity" >/dev/null 2>&1; then
        imported_valid=true
    fi
    if [[ "$imported_valid" == true ]]; then
        if ! check=$(_github_new_private_path "$CONFIG_DIR/.unlock-check.XXXXXX"); then
            _github_record_error "расшифровка конфигурации GitHub" \
                "Не удалось создать защищённый временный файл."
            return 1
        fi
        if (umask 077
            "$AGE_BIN" -d -i "$original_identity" -o "$check" \
                "$GITHUB_WORKTREE/unlock.age" >/dev/null 2>&1
        ) && _github_exact_regular_file "$check"; then
            _github_remove_private_path "$check"
            if _github_prompt_remember_unlock; then
                if ! github_config_remember "$original_identity"; then
                    warn "Не удалось сохранить ключ расшифровки на этом устройстве; текущий сеанс продолжится без сохранённого ключа."
                    _github_clear_error
                fi
            fi
            GITHUB_IDENTITY="$original_identity"
            export GITHUB_IDENTITY
            return 0
        fi
        _github_remove_private_path "$check"
    fi
    if [[ "$id" != "$original_identity" ]] &&
       _github_exact_regular_file "$id" && [[ -s "$id" ]]; then
        if ! check=$(_github_new_private_path "$CONFIG_DIR/.unlock-check.XXXXXX"); then
            _github_record_error "расшифровка конфигурации GitHub" \
                "Не удалось создать защищённый временный файл."
            return 1
        fi
        if (umask 077
            "$AGE_BIN" -d -i "$id" -o "$check" \
                "$GITHUB_WORKTREE/unlock.age" >/dev/null 2>&1
        ) && _github_exact_regular_file "$check"; then
            _github_remove_private_path "$check"
            GITHUB_IDENTITY="$id"
            export GITHUB_IDENTITY
            return 0
        fi
        _github_remove_private_path "$check"
        warn "Сохранённый ключ расшифровки не подходит к текущему хранилищу."
    fi
    while (( attempts > 0 )); do
        if ! read -rsp "Введите пароль доступа к конфигурации (осталось попыток: $attempts): " pass; then
            printf '\n'
            GITHUB_IDENTITY="$original_identity"
            export GITHUB_IDENTITY
            _github_record_error "расшифровка конфигурации GitHub" \
                "Не удалось прочитать пароль доступа."
            return 1
        fi
        printf '\n'
        if ! check=$(_github_new_private_path "$CONFIG_DIR/.unlock-check.XXXXXX"); then
            GITHUB_IDENTITY="$original_identity"
            export GITHUB_IDENTITY
            _github_record_error "расшифровка конфигурации GitHub" \
                "Не удалось создать защищённый временный файл."
            return 1
        fi
        if [[ -n "$pass" ]] &&
           (umask 077
               printf '%s\n' "$pass" |
                   "$AGE_BIN" -d -p -o "$check" "$GITHUB_WORKTREE/unlock.age" \
                       >/dev/null 2>&1
           ) && _github_exact_regular_file "$check"; then
            GITHUB_IDENTITY="$check"
            export GITHUB_IDENTITY
            if _github_prompt_remember_unlock; then
                if ! github_config_remember "$GITHUB_IDENTITY"; then
                    warn "Не удалось сохранить ключ расшифровки на этом устройстве; текущий сеанс продолжится без сохранённого ключа."
                    _github_clear_error
                fi
            fi
            return 0
        fi
        _github_remove_private_path "$check"
        attempts=$((attempts - 1))
    done
    GITHUB_IDENTITY="$original_identity"
    export GITHUB_IDENTITY
    _github_record_error "расшифровка конфигурации GitHub" \
        "Не удалось разблокировать конфигурацию: пароль или ключ восстановления не подошёл."
    return 1
}

_github_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1
    fi
}
# Build logical state from the active runtime.
github_config_serialize() {
    local out=${1:?output path} cfg=${2:-${CONFIG_JSON:?CONFIG_JSON is unset}}
    local secrets=${SECRETS_JSON:-${CONFIG_DIR:-.}/secrets.json}
    local manifest=${STATE_MANIFEST:-${CONFIG_DIR:-.}/manifest.json}
    local known=${SSH_KNOWN_HOSTS:-${CONFIG_DIR:-.}/ssh/known_hosts}
    local tmp next template_list identity_list template name source pub
    local snapshot_hash builtin_hash
    _github_exact_regular_file "$cfg" || return 1
    _github_exact_regular_file "$secrets" || return 1
    _github_exact_regular_file "$manifest" || return 1
    if [[ -e "$known" || -L "$known" ]]; then
        _github_exact_regular_file "$known" || return 1
    fi
    tmp=$(umask 077; mktemp "${out}.tmp.XXXXXX") || return 1
    next=$(umask 077; mktemp "${out}.tmp.XXXXXX") || {
        rm -f "$tmp"
        return 1
    }
    template_list=$(umask 077; mktemp "${out}.templates.XXXXXX") || {
        rm -f "$tmp" "$next"
        return 1
    }
    identity_list=$(umask 077; mktemp "${out}.identities.XXXXXX") || {
        rm -f "$tmp" "$next" "$template_list"
        return 1
    }
    local -a known_args
    if _github_exact_regular_file "$known"; then
        known_args=(--rawfile known "$known")
    else
        known_args=(--arg known "")
    fi
    if ! jq -n --slurpfile config "$cfg" --slurpfile sec "$secrets" \
        --slurpfile man "$manifest" "${known_args[@]}" \
        --arg minimum "${CURRENT_VERSION:-0.0.0}" \
        '{vault_version:1,minimum_remote_control_version:$minimum,
          portability:($man[0].portability // {status:"ready",issues:[]}),
          access:($man[0].access // {script_password_hash:null}),
          config:$config[0],secrets:($sec[0] // {node_passwords:{}}),
          templates:($man[0].templates // {}),
          ssh:{identities:{},known_hosts:$known}}' > "$tmp" ||
       ! printf '%s\n' default.yaml > "$template_list" ||
       ! jq -r '(.groups // [])[]? | (.template // "default.yaml")' \
            "$cfg" >> "$template_list" ||
       ! jq -r '(.nodes // [])[]? |
            select(.auth == "key" and (.identity // "system") != "system") |
            .identity' "$cfg" > "$identity_list"; then
        rm -f "$tmp" "$next" "$template_list" "$identity_list"
        return 1
    fi
    LC_ALL=C sort -u "$template_list" > "$next" || {
        rm -f "$tmp" "$next" "$template_list" "$identity_list"
        return 1
    }
    if ! mv "$next" "$template_list"; then
        rm -f "$tmp" "$next" "$template_list" "$identity_list"
        return 1
    fi
    next=$(umask 077; mktemp "${out}.tmp.XXXXXX") || {
        rm -f "$tmp" "$template_list" "$identity_list"
        return 1
    }
    while IFS= read -r template; do
        [[ "$template" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] || {
            rm -f "$tmp" "$next" "$template_list" "$identity_list"
            return 1
        }
        name="$TEMPLATES_DIR/$template"
        source=custom
        if ! _github_exact_regular_file "$name" &&
           _github_exact_regular_file "${BUILTIN_TEMPLATES_DIR:-}/$template"; then
            name="${BUILTIN_TEMPLATES_DIR:-}/$template"
            source=builtin
        fi
        if ! _github_exact_regular_file "$name"; then
            if [[ ${CONFIG_SOURCE:-local} == github ]]; then
                rm -f "$tmp" "$next" "$template_list" "$identity_list"
                return 1
            fi
            continue
        fi
        if [[ "$source" == custom ]] &&
           _github_exact_regular_file "${BUILTIN_TEMPLATES_DIR:-}/$template" &&
           cmp -s "$name" "${BUILTIN_TEMPLATES_DIR:-}/$template"; then
            source=builtin
        fi
        snapshot_hash=$(_github_sha256 "$name") || {
            rm -f "$tmp" "$next" "$template_list" "$identity_list"
            return 1
        }
        builtin_hash=null
        if [[ "$source" == custom ]] &&
           _github_exact_regular_file "${BUILTIN_TEMPLATES_DIR:-}/$template"; then
            builtin_hash=$(_github_sha256 "${BUILTIN_TEMPLATES_DIR:-}/$template") || {
                rm -f "$tmp" "$next" "$template_list" "$identity_list"
                return 1
            }
        fi
        if ! jq --arg n "$template" --rawfile c "$name" --arg source "$source" \
            --arg hash "$snapshot_hash" --arg builtin "$builtin_hash" \
            '.templates += {($n): {content:$c,source:$source,
             snapshot_sha256:$hash,
             ignored_builtin_sha256:(if $builtin=="null" then null else $builtin end)}}' \
            "$tmp" > "$next" || ! mv "$next" "$tmp"; then
            rm -f "$tmp" "$next" "$template_list" "$identity_list"
            return 1
        fi
        next=$(umask 077; mktemp "${out}.tmp.XXXXXX") || {
            rm -f "$tmp" "$template_list" "$identity_list"
            return 1
        }
    done < "$template_list"
    LC_ALL=C sort -u "$identity_list" > "$next" || {
        rm -f "$tmp" "$next" "$template_list" "$identity_list"
        return 1
    }
    if ! mv "$next" "$identity_list"; then
        rm -f "$tmp" "$next" "$template_list" "$identity_list"
        return 1
    fi
    next=$(umask 077; mktemp "${out}.tmp.XXXXXX") || {
        rm -f "$tmp" "$template_list" "$identity_list"
        return 1
    }
    while IFS= read -r name; do
        [[ "$name" =~ ^[0-9a-fA-F]{32}$ ]] || {
            rm -f "$tmp" "$next" "$template_list" "$identity_list"
            return 1
        }
        pub="$SSH_IDENTITIES_DIR/$name.pub"
        if ! _github_exact_regular_file "$SSH_IDENTITIES_DIR/$name" ||
           ! _github_exact_regular_file "$pub" ||
           ! jq --arg n "$name" --rawfile p "$SSH_IDENTITIES_DIR/$name" \
                --rawfile q "$pub" \
                '.ssh.identities += {($n): {private:$p,public:$q}}' \
                "$tmp" > "$next" ||
           ! mv "$next" "$tmp"; then
            rm -f "$tmp" "$next" "$template_list" "$identity_list"
            return 1
        fi
        next=$(umask 077; mktemp "${out}.tmp.XXXXXX") || {
            rm -f "$tmp" "$template_list" "$identity_list"
            return 1
        }
    done < "$identity_list"
    if ! github_config_validate "$tmp" || ! chmod 600 "$tmp" ||
       ! mv "$tmp" "$out"; then
        rm -f "$tmp" "$next" "$template_list" "$identity_list"
        return 1
    fi
    rm -f "$next" "$template_list" "$identity_list" ||
        warn "Снимок создан, но временные файлы сериализации требуют ручной очистки."
}
github_config_validate() {
    local state=${1:?state json}
    _github_exact_regular_file "$state" || return 1
    jq -e 'type=="object" and .vault_version==1 and
        (.config|type=="object") and (.secrets|type=="object") and
        (.templates|type=="object") and (.ssh|type=="object") and
        ((.portability.status=="ready") or (.portability.status=="needs_setup")) and
        (.portability.issues|type=="array")' "$state" >/dev/null 2>&1 || return 1
    jq -e '
        ((.config.nodes // []) | map(.id) | length == (map(.) | unique | length)) and
        ((.config.nodes // []) | map(.name) | length == (map(.) | unique | length)) and
        all((.config.nodes // [])[];
            (.id|type=="string") and (.name|type=="string") and
            (if .auth == "key" and (.identity // "system") != "system"
             then (.identity|type=="string") and
                  (. as $node | $identities[$node.identity] != null)
             else true end))
    ' --argjson identities "$(jq -c '.ssh.identities // {}' "$state")" \
        "$state" >/dev/null 2>&1 || return 1
    jq -e '
        all((.templates // {}) | to_entries[];
            (.key | test("^[A-Za-z0-9._-]+[.]yaml$")) and
            (.value | type=="object") and (.value.content | type=="string")) and
        ((.ssh.known_hosts // "") | type=="string") and
        all((.ssh.identities // {}) | to_entries[];
            (.key | test("^[0-9a-fA-F]{32}$")) and
            (.value | type=="object") and
            (.value.private | type=="string" and length>0) and
            (.value.public | type=="string" and length>0))
    ' "$state" >/dev/null 2>&1
}

_github_plain_write() {
    local state=$1 w=$GITHUB_WORKTREE name stage backup path restore list
    local failed=false
    local -a paths=(config.json secrets.json manifest.json ssh templates)
    github_config_validate "$state" || return 1
    _github_validate_tree "$w" auto || return 1
    stage=$(umask 077; mktemp -d "$w/.plain-write.XXXXXX") || return 1
    backup=$(umask 077; mktemp -d "$w/.plain-backup.XXXXXX") || {
        rm -rf "$stage"
        return 1
    }
    list=$(umask 077; mktemp "$stage/.entries.XXXXXX") || {
        rm -rf "$stage" "$backup"
        return 1
    }
    if ! mkdir -p "$stage/templates" "$stage/ssh/identities" ||
       ! jq -e '.config' "$state" > "$stage/config.json" ||
       ! jq -e '.secrets' "$state" > "$stage/secrets.json" ||
       ! jq -e '{vault_version,minimum_remote_control_version,portability,access,templates}' \
            "$state" > "$stage/manifest.json" ||
       ! jq -j '.ssh.known_hosts // ""' "$state" > "$stage/ssh/known_hosts" ||
       ! jq -r '.templates // {} | keys[]' "$state" > "$list"; then
        rm -rf "$stage" "$backup"
        return 1
    fi
    while IFS= read -r name; do
        [[ "$name" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] || {
            rm -rf "$stage" "$backup"
            return 1
        }
        if ! jq -j --arg n "$name" '.templates[$n].content' "$state" \
                > "$stage/templates/$name" ||
           ! chmod 644 "$stage/templates/$name"; then
            rm -rf "$stage" "$backup"
            return 1
        fi
    done < "$list"
    if ! jq -r '.ssh.identities // {} | keys[]' "$state" > "$list"; then
        rm -rf "$stage" "$backup"
        return 1
    fi
    while IFS= read -r name; do
        [[ "$name" =~ ^[0-9a-fA-F]{32}$ ]] || {
            rm -rf "$stage" "$backup"
            return 1
        }
        if ! jq -j --arg n "$name" '.ssh.identities[$n].private' "$state" \
                > "$stage/ssh/identities/$name" ||
           ! jq -j --arg n "$name" '.ssh.identities[$n].public' "$state" \
                > "$stage/ssh/identities/$name.pub" ||
           ! chmod 600 "$stage/ssh/identities/$name" ||
           ! chmod 644 "$stage/ssh/identities/$name.pub"; then
            rm -rf "$stage" "$backup"
            return 1
        fi
    done < "$list"
    if ! rm -f "$list" ||
       ! chmod 700 "$stage" "$stage/templates" "$stage/ssh" "$stage/ssh/identities" ||
       ! chmod 600 "$stage/secrets.json" "$stage/ssh/known_hosts" ||
       ! chmod 644 "$stage/config.json" "$stage/manifest.json"; then
        rm -rf "$stage" "$backup"
        return 1
    fi
    for path in "${paths[@]}"; do
        if [[ -e "$w/$path" || -L "$w/$path" ]]; then
            if ! mv "$w/$path" "$backup/$path"; then
                failed=true
                break
            fi
        fi
    done
    if [[ "$failed" == true ]]; then
        for restore in "${paths[@]}"; do
            if [[ -e "$backup/$restore" || -L "$backup/$restore" ]]; then
                mv "$backup/$restore" "$w/$restore" || return 1
            fi
        done
        rm -rf "$stage" "$backup" || return 1
        return 1
    fi
    for path in "${paths[@]}"; do
        if ! mv "$stage/$path" "$w/$path"; then
            failed=true
            break
        fi
    done
    if [[ "$failed" == true ]] || ! chmod 700 "$w"; then
        for restore in "${paths[@]}"; do
            if [[ -e "$w/$restore" || -L "$w/$restore" ]]; then
                rm -rf "$w/$restore" || return 1
            fi
        done
        for restore in "${paths[@]}"; do
            if [[ -e "$backup/$restore" || -L "$backup/$restore" ]]; then
                mv "$backup/$restore" "$w/$restore" || return 1
            fi
        done
        rm -rf "$stage" "$backup" || return 1
        return 1
    fi
    if ! rmdir "$stage" || ! rm -rf "$backup"; then
        warn "Снимок опубликован, но временные каталоги требуют ручной очистки."
    fi
}
_github_plain_read() {
    local w=$GITHUB_WORKTREE out=$1 name id tmp next
    _github_validate_tree "$w" none || return 1
    _github_validate_tracked_tree none || return 1
    _github_exact_regular_file "$w/config.json" || return 1
    _github_exact_regular_file "$w/secrets.json" || return 1
    _github_exact_regular_file "$w/manifest.json" || return 1
    tmp=$(umask 077; mktemp "${out}.tmp.XXXXXX") || return 1
    next=$(umask 077; mktemp "${out}.tmp.XXXXXX") || {
        rm -f "$tmp"
        return 1
    }
    local -a known_args
    if _github_exact_regular_file "$w/ssh/known_hosts"; then
        known_args=(--rawfile known "$w/ssh/known_hosts")
    else
        known_args=(--arg known "")
    fi
    if ! jq -n --slurpfile config "$w/config.json" \
        --slurpfile secrets "$w/secrets.json" --slurpfile man "$w/manifest.json" \
        "${known_args[@]}" \
        '{vault_version:1,
          minimum_remote_control_version:($man[0].minimum_remote_control_version // "0.0.0"),
          portability:($man[0].portability // {status:"ready",issues:[]}),
          access:($man[0].access // {script_password_hash:null}),
          config:$config[0],secrets:$secrets[0],
          templates:($man[0].templates // {}),
          ssh:{identities:{},known_hosts:$known}}' > "$tmp"; then
        rm -f "$tmp" "$next"
        return 1
    fi
    for name in "$w/templates/"*.yaml; do
        [[ -e "$name" ]] || continue
        _github_exact_regular_file "$name" || {
            rm -f "$tmp" "$next"
            return 1
        }
        if ! jq --arg n "$(basename "$name")" -j --rawfile c "$name" \
            '.templates[$n].content=$c' "$tmp" > "$next" ||
           ! mv "$next" "$tmp"; then
            rm -f "$tmp" "$next"
            return 1
        fi
        next=$(umask 077; mktemp "${out}.tmp.XXXXXX") || {
            rm -f "$tmp"
            return 1
        }
    done
    for name in "$w/ssh/identities/"*.pub; do
        [[ -e "$name" ]] || continue
        _github_exact_regular_file "$name" || {
            rm -f "$tmp" "$next"
            return 1
        }
        _github_exact_regular_file "${name%.pub}" || {
            rm -f "$tmp" "$next"
            return 1
        }
    done
    for name in "$w/ssh/identities/"*; do
        [[ -e "$name" && "$name" != *.pub ]] || continue
        _github_exact_regular_file "$name" || {
            rm -f "$tmp" "$next"
            return 1
        }
        id="${name##*/}"
        [[ "$id" =~ ^[0-9a-fA-F]{32}$ ]] || {
            rm -f "$tmp" "$next"
            return 1
        }
        if ! jq --arg n "$id" -j --rawfile p "$name" --rawfile q "$name.pub" \
            '.ssh.identities[$n]={private:$p,public:$q}' "$tmp" > "$next" ||
           ! mv "$next" "$tmp"; then
            rm -f "$tmp" "$next"
            return 1
        fi
        next=$(umask 077; mktemp "${out}.tmp.XXXXXX") || {
            rm -f "$tmp"
            return 1
        }
    done
    if ! github_config_validate "$tmp" || ! chmod 600 "$tmp" ||
       ! mv "$tmp" "$out"; then
        rm -f "$tmp" "$next"
        return 1
    fi
    rm -f "$next" ||
        warn "Снимок прочитан, но временный файл требует ручной очистки."
}
_github_checkpoint_rollback_storage() {
    [[ "${1:-false}" == true ]] || return 0
    if ! rm -f "$GITHUB_WORKTREE/storage.json"; then
        _github_record_error "откат параметров хранения GitHub" \
            "Не удалось удалить storage.json после ошибки сохранения снимка."
        return 1
    fi
}

github_config_checkpoint() {
    _github_clear_error
    local state=${1:-${CONFIG_DIR:-.}/runtime-state.json}
    local generated_state=false created_storage=false age_output age_tmp
    if [[ ! -f "$state" ]]; then
        if ! state=$(umask 077; mktemp "$CONFIG_DIR/.runtime-state.XXXXXX"); then
            _github_record_error "подготовка снимка конфигурации GitHub" \
                "Не удалось создать защищённый временный снимок конфигурации."
            return 1
        fi
        generated_state=true
        if ! github_config_serialize "$state" "${CONFIG_JSON:-}"; then
            rm -f "$state"
            _github_ensure_error "подготовка снимка конфигурации GitHub" \
                "Не удалось собрать переносимый снимок конфигурации."
            return 1
        fi
    else
        _github_exact_regular_file "$state" || {
            _github_record_error "проверка снимка конфигурации GitHub" \
                "Снимок конфигурации имеет недопустимый тип."
            return 1
        }
    fi
    if [[ "$generated_state" != true ]] && ! github_config_validate "$state"; then
        _github_record_error "проверка снимка конфигурации GitHub" \
            "Снимок конфигурации имеет некорректную структуру."
        return 1
    fi
    _github_validate_tree "$GITHUB_WORKTREE" auto || {
        [[ "$generated_state" == true ]] && rm -f "$state"
        return 1
    }
    if [[ ! -e "$GITHUB_WORKTREE/storage.json" ]]; then
        if ! _github_storage_init "${GITHUB_STORAGE_MODE:-none}"; then
            [[ "$generated_state" == true ]] && rm -f "$state"
            _github_ensure_error "сохранение снимка конфигурации GitHub" \
                "Не удалось сохранить параметры хранения конфигурации GitHub."
            return 1
        fi
        created_storage=true
    else
        _github_exact_regular_file "$GITHUB_WORKTREE/storage.json" || {
            [[ "$generated_state" == true ]] && rm -f "$state"
            return 1
        }
    fi
    if [[ ${GITHUB_STORAGE_MODE:-none} == none ]]; then
        if ! _github_plain_write "$state"; then
            [[ "$generated_state" == true ]] && rm -f "$state"
            _github_ensure_error "сохранение снимка конфигурации GitHub" \
                "Не удалось сохранить снимок в рабочей копии GitHub."
            _github_checkpoint_rollback_storage "$created_storage" || return 1
            return 1
        fi
    else
        if [[ -z ${GITHUB_RECIPIENT:-} ]]; then
            [[ "$generated_state" == true ]] && rm -f "$state"
            _github_record_error "сохранение снимка конфигурации GitHub" \
                "Не удалось определить recipient для шифрования конфигурации."
            _github_checkpoint_rollback_storage "$created_storage" || return 1
            return 1
        fi
        age_tmp=$(_github_new_private_path "$GITHUB_WORKTREE/.state.json.age.XXXXXX") || {
            [[ "$generated_state" == true ]] && rm -f "$state"
            _github_record_error "подготовка шифрования снимка GitHub" \
                "Не удалось создать защищённый staging-каталог."
            _github_checkpoint_rollback_storage "$created_storage"
            return 1
        }
        if ! age_output=$(umask 077; "$AGE_BIN" -r "$GITHUB_RECIPIENT" \
                -o "$age_tmp" "$state" 2>&1) ||
           ! _github_exact_regular_file "$age_tmp" ||
           ! chmod 600 "$age_tmp" ||
           ! mv "$age_tmp" "$GITHUB_WORKTREE/state.json.age"; then
            _github_remove_private_path "$age_tmp"
            [[ "$generated_state" == true ]] && rm -f "$state"
            _github_record_error "сохранение снимка конфигурации GitHub" \
                "Не удалось атомарно зашифровать снимок конфигурации GitHub."
            _github_checkpoint_rollback_storage "$created_storage" || return 1
            return 1
        fi
        _github_remove_private_path "$age_tmp" ||
            warn "Защищённый staging-каталог снимка требует ручной очистки."
    fi
    if [[ "$generated_state" == true ]] && ! rm -f "$state"; then
        warn "Снимок опубликован, но временное логическое состояние требует ручной очистки: $state"
    fi
    return 0
}
config_persist_candidate() {
    _github_clear_error
    CONFIG_PERSIST_LAST_ERROR=""
    local candidate="${1:-}" original="${CONFIG_JSON:-}"
    local serialized backup="" had_original=false old_status="${GITHUB_SYNC_STATUS:-}"
    if ! _github_exact_regular_file "$candidate" || [[ -z "$original" ]]; then
        _github_record_error "проверка изменённой конфигурации" \
            "Временный файл изменённой конфигурации или текущий CONFIG_JSON недоступен."
        CONFIG_PERSIST_LAST_ERROR="Не удалось сохранить изменение (этап: $GITHUB_LAST_STAGE): $GITHUB_LAST_ERROR"
        return 1
    fi
    if [[ ${CONFIG_SOURCE:-local} != github ]]; then
        if ! mv "$candidate" "$original"; then
            _github_record_error "публикация изменённой конфигурации" \
                "Не удалось атомарно заменить локальный config.json."
            CONFIG_PERSIST_LAST_ERROR="Не удалось сохранить изменение (этап: $GITHUB_LAST_STAGE): $GITHUB_LAST_ERROR"
            return 1
        fi
        return 0
    fi
    serialized=$(umask 077; mktemp "$CONFIG_DIR/.candidate-state.XXXXXX") || {
        _github_record_error "подготовка снимка конфигурации GitHub" \
            "Не удалось создать защищённый временный снимок конфигурации."
        CONFIG_PERSIST_LAST_ERROR="Не удалось сохранить изменение в GitHub (этап: $GITHUB_LAST_STAGE): $GITHUB_LAST_ERROR"
        return 1
    }
    CONFIG_JSON="$candidate"
    if ! state_validate true >/dev/null 2>&1; then
        if [[ "${CONFIG_PERSIST_ALLOW_NEEDS_SETUP:-0}" != 1 ]] ||
           ! state_validate false >/dev/null 2>&1; then
            CONFIG_JSON="$original"
            rm -f "$serialized"
            _github_ensure_error "проверка изменённой конфигурации" \
                "Изменённая конфигурация не прошла проверку переносимого состояния."
            CONFIG_PERSIST_LAST_ERROR="Не удалось сохранить изменение в GitHub (этап: $GITHUB_LAST_STAGE): $GITHUB_LAST_ERROR"
            return 1
        fi
    fi
    if ! github_config_serialize "$serialized" "$candidate"; then
        CONFIG_JSON="$original"
        rm -f "$serialized"
        _github_ensure_error "подготовка снимка конфигурации GitHub" \
            "Не удалось собрать переносимый снимок конфигурации."
        CONFIG_PERSIST_LAST_ERROR="Не удалось сохранить изменение в GitHub (этап: $GITHUB_LAST_STAGE): $GITHUB_LAST_ERROR"
        return 1
    fi
    CONFIG_JSON="$original"
    if [[ -e "$original" || -L "$original" ]]; then
        if ! _github_exact_regular_file "$original"; then
            rm -f "$serialized"
            _github_record_error "публикация изменённой конфигурации" \
                "Текущий config.json имеет недопустимый тип."
            CONFIG_PERSIST_LAST_ERROR="Не удалось сохранить изменение в GitHub (этап: $GITHUB_LAST_STAGE): $GITHUB_LAST_ERROR"
            return 1
        fi
        had_original=true
        backup=$(umask 077; mktemp "$CONFIG_DIR/.persist-config.XXXXXX") || {
            rm -f "$serialized"
            return 1
        }
        if ! cp "$original" "$backup" || ! chmod 600 "$backup"; then
            rm -f "$serialized" "$backup"
            return 1
        fi
    fi
    if ! mv "$candidate" "$original"; then
        rm -f "$serialized" "$backup"
        _github_record_error "публикация изменённой конфигурации" \
            "Не удалось атомарно заменить рабочий config.json."
        CONFIG_PERSIST_LAST_ERROR="Не удалось сохранить изменение в GitHub (этап: $GITHUB_LAST_STAGE): $GITHUB_LAST_ERROR"
        return 1
    fi
    if ! github_config_checkpoint "$serialized"; then
        if [[ "$had_original" == true ]]; then
            mv "$backup" "$original" || return 1
        else
            rm -f "$original" || return 1
        fi
        GITHUB_SYNC_STATUS="$old_status"
        rm -f "$serialized" "$backup"
        _github_ensure_error "сохранение снимка конфигурации GitHub" \
            "Не удалось сохранить снимок в рабочей копии GitHub."
        CONFIG_PERSIST_LAST_ERROR="Не удалось сохранить изменение в GitHub (этап: $GITHUB_LAST_STAGE): $GITHUB_LAST_ERROR"
        return 1
    fi
    GITHUB_SYNC_STATUS=pending
    export GITHUB_SYNC_STATUS
    if ! rm -f "$serialized" "$backup"; then
        warn "Конфигурация сохранена, но защищённые временные файлы требуют ручной очистки."
    fi
    CONFIG_PERSIST_LAST_ERROR=""
    _github_clear_error
    return 0
}
_github_exact_regular_file() {
    [[ -f "${1:-}" && ! -L "${1:-}" ]]
}
_github_new_private_path() {
    local pattern="${1:?temporary path pattern}" parent staging
    parent="${pattern%/*}"
    [[ "$parent" != "$pattern" && -d "$parent" && ! -L "$parent" ]] || return 1
    staging=$(umask 077; mktemp -d "$parent/.github-private.XXXXXX") || return 1
    if ! chmod 700 "$staging"; then
        rm -rf "$staging"
        return 1
    fi
    printf '%s\n' "$staging/output"
}
_github_remove_private_path() {
    local path="${1:-}" parent
    [[ -n "$path" ]] || return 0
    parent="${path%/*}"
    if [[ "${path##*/}" == output && "${parent##*/}" == .github-private.* &&
          -d "$parent" && ! -L "$parent" ]]; then
        rm -f "$path" && rmdir "$parent"
    else
        rm -f "$path"
    fi
}
_github_remove_ephemeral_identity() {
    local identity="${1:-}"
    case "$identity" in
        "$CONFIG_DIR"/.github-private.*/output)
            _github_remove_private_path "$identity"
            ;;
        "$CONFIG_DIR"/.unlock-check.*|"$CONFIG_DIR"/.recovery-key.*|\
        "$CONFIG_DIR"/github-identity.tmp*|"$CONFIG_DIR"/.github-identity.*)
            rm -f "$identity"
            ;;
    esac
}


_github_canonical_path() {
    local path="${1:-}" parent base physical
    [[ -n "$path" ]] || return 1
    case "$path" in
        /*) ;;
        *) path="$PWD/$path" ;;
    esac
    if [[ -d "$path" ]]; then
        (cd -P "$path" 2>/dev/null && pwd -P)
        return
    fi
    parent=$(dirname "$path") || return 1
    base=$(basename "$path") || return 1
    [[ -d "$parent" ]] || return 1
    physical=$(cd -P "$parent" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "${physical%/}" "$base"
}

_github_recovery_path_is_managed() {
    local candidate managed root
    candidate=$(_github_canonical_path "${1:-}") || return 0
    for root in "${CONFIG_DIR:-}" "${GITHUB_STORE:-}" "${GITHUB_SESSIONS_DIR:-}" \
        "${GITHUB_CREDENTIALS_DIR:-}" "${GITHUB_WORKTREE:-}" "${STATE_DIR:-}" \
        "${TEMPLATES_DIR:-}" "${SSH_IDENTITIES_DIR:-}"; do
        [[ -n "$root" ]] || continue
        managed=$(_github_canonical_path "$root") || continue
        case "$candidate" in
            "$managed"|"$managed"/*) return 0 ;;
        esac
    done
    return 1
}

_github_atomic_private_copy() {
    local source="$1" target="$2" parent base tmp
    _github_exact_regular_file "$source" || return 1
    [[ ! -L "$target" ]] || return 1
    if [[ -e "$target" ]] && ! _github_exact_regular_file "$target"; then
        return 1
    fi
    parent=$(dirname "$target") || return 1
    base=$(basename "$target") || return 1
    [[ -d "$parent" ]] || return 1
    tmp=$(umask 077; mktemp "$parent/.${base}.tmp.XXXXXX") || return 1
    if ! cp "$source" "$tmp" || ! chmod 600 "$tmp" || ! mv "$tmp" "$target"; then
        rm -f "$tmp"
        return 1
    fi
}

github_config_remember() {
    _github_clear_error
    local id="${1:-}"
    _github_exact_regular_file "$id" && [[ -s "$id" ]] || {
        _github_record_error "сохранение ключа расшифровки" \
            "Ключ расшифровки недоступен."
        return 1
    }
    if ! _github_mkdir_secure "$GITHUB_CREDENTIALS_DIR"; then
        _github_record_error "сохранение ключа расшифровки" \
            "Не удалось создать защищённый каталог credentials."
        return 1
    fi
    if ! _github_atomic_private_copy "$id" "$GITHUB_UNLOCK_FILE"; then
        _github_record_error "сохранение ключа расшифровки" \
            "Не удалось атомарно сохранить ключ расшифровки на этом устройстве."
        return 1
    fi
}
github_config_forget() {
    _github_clear_error
    if ! rm -f "$GITHUB_UNLOCK_FILE"; then
        _github_record_error "удаление ключа расшифровки" \
            "Не удалось удалить сохранённый ключ расшифровки."
        return 1
    fi
}
github_config_export_recovery() {
    _github_clear_error
    local target="${1:-}" canonical_identity canonical_target
    if [[ -z "$target" || -L "$target" ]] ||
       _github_recovery_path_is_managed "$target"; then
        _github_record_error "экспорт ключа восстановления" \
            "Файл ключа восстановления недоступен или расположен внутри служебного каталога."
        return 1
    fi
    if ! _github_exact_regular_file "${GITHUB_IDENTITY:-}" ||
       [[ ! -s "${GITHUB_IDENTITY:-}" ]]; then
        _github_record_error "экспорт ключа восстановления" \
            "Ключ расшифровки недоступен для экспорта."
        return 1
    fi
    canonical_identity=$(_github_canonical_path "$GITHUB_IDENTITY") || return 1
    canonical_target=$(_github_canonical_path "$target") || {
        _github_record_error "экспорт ключа восстановления" \
            "Каталог назначения ключа восстановления недоступен."
        return 1
    }
    if [[ "$canonical_target" == "$canonical_identity" ]] ||
       ! _github_atomic_private_copy "$GITHUB_IDENTITY" "$target"; then
        _github_record_error "экспорт ключа восстановления" \
            "Не удалось атомарно сохранить копию ключа восстановления."
        return 1
    fi
}
github_config_import_recovery() {
    _github_clear_error
    local source="${1:-}" check old_identity="${GITHUB_IDENTITY:-}"
    if [[ -z "$source" || -L "$source" ]] ||
       ! _github_exact_regular_file "$source" || [[ ! -s "$source" ]] ||
       _github_recovery_path_is_managed "$source"; then
        _github_record_error "импорт ключа восстановления" \
            "Файл ключа восстановления не найден, имеет недопустимый тип или расположен внутри служебного каталога."
        return 1
    fi
    if ! check=$(umask 077; mktemp "$CONFIG_DIR/.recovery-key.XXXXXX"); then
        _github_record_error "импорт ключа восстановления" \
            "Не удалось создать защищённую временную копию ключа."
        return 1
    fi
    if ! cp "$source" "$check" || ! chmod 600 "$check"; then
        rm -f "$check"
        GITHUB_IDENTITY="$old_identity"
        _github_record_error "импорт ключа восстановления" \
            "Не удалось скопировать ключ восстановления во временный файл."
        return 1
    fi
    if ! "$AGE_KEYGEN_BIN" -y "$check" >/dev/null 2>&1; then
        rm -f "$check"
        GITHUB_IDENTITY="$old_identity"
        _github_record_error "импорт ключа восстановления" \
            "Файл не содержит корректный секретный ключ age."
        return 1
    fi
    GITHUB_IDENTITY="$check"
    export GITHUB_IDENTITY
    return 0
}
github_config_rewrap_master() {
    _github_clear_error
    if [[ ${GITHUB_STORAGE_MODE:-none} != age ]] ||
       ! _github_exact_regular_file "$GITHUB_WORKTREE/unlock.age" ||
       [[ ! -s "$GITHUB_WORKTREE/unlock.age" ]]; then
        _github_record_error "проверка зашифрованной конфигурации" \
            "Файл unlock.age недоступен."
        return 1
    fi
    local old new _new identity_tmp unlock_tmp backup old_head=""
    local failure_stage failure_detail
    old_head=$(git -C "$GITHUB_WORKTREE" rev-parse HEAD 2>/dev/null) || old_head=""
    if ! read -rsp "Текущий пароль доступа: " old; then
        printf '\n'
        _github_record_error "ввод нового пароля" "Не удалось прочитать пароль доступа."
        return 1
    fi
    printf '\n'
    if ! read -rsp "Новый пароль доступа: " new; then
        printf '\n'
        _github_record_error "ввод нового пароля" "Не удалось прочитать пароль доступа."
        return 1
    fi
    printf '\n'
    if [[ -z "$new" ]]; then
        _github_record_error "ввод нового пароля" \
            "Новый пароль доступа не может быть пустым."
        return 1
    fi
    if ! read -rsp "Повторите новый пароль доступа: " _new; then
        printf '\n'
        _github_record_error "ввод нового пароля" "Не удалось прочитать пароль доступа."
        return 1
    fi
    printf '\n'
    if [[ "$new" != "$_new" ]]; then
        _github_record_error "ввод нового пароля" \
            "Введённые новые пароли не совпадают."
        return 1
    fi
    identity_tmp=$(_github_new_private_path "$CONFIG_DIR/.rewrap-identity.XXXXXX") || {
        _github_record_error "подготовка смены пароля" \
            "Не удалось создать защищённый временный файл."
        return 1
    }
    unlock_tmp=$(_github_new_private_path "$GITHUB_WORKTREE/.rewrap-unlock.XXXXXX") || {
        _github_remove_private_path "$identity_tmp"
        return 1
    }
    backup=$(umask 077; mktemp "$CONFIG_DIR/.rewrap-backup.XXXXXX") || {
        _github_remove_private_path "$identity_tmp"
        _github_remove_private_path "$unlock_tmp"
        return 1
    }
    if ! cp "$GITHUB_WORKTREE/unlock.age" "$backup" ||
       ! chmod 600 "$backup" ||
       ! (umask 077
           printf '%s\n' "$old" |
               "$AGE_BIN" -d -p -o "$identity_tmp" \
                   "$GITHUB_WORKTREE/unlock.age" >/dev/null 2>&1
       ) ||
       ! _github_exact_regular_file "$identity_tmp" ||
       ! chmod 600 "$identity_tmp"; then
        _github_remove_private_path "$identity_tmp"
        _github_remove_private_path "$unlock_tmp"
        rm -f "$backup"
        _github_record_error "расшифровка ключа конфигурации" \
            "Текущий пароль доступа неверен или файл unlock.age повреждён."
        return 1
    fi
    if ! (umask 077
            printf '%s\n%s\n' "$new" "$new" |
                "$AGE_BIN" -p -o "$unlock_tmp" "$identity_tmp" >/dev/null 2>&1
         ) ||
       ! _github_exact_regular_file "$unlock_tmp" ||
       ! chmod 600 "$unlock_tmp" ||
       ! mv "$unlock_tmp" "$GITHUB_WORKTREE/unlock.age"; then
        _github_remove_private_path "$identity_tmp"
        _github_remove_private_path "$unlock_tmp"
        rm -f "$backup"
        _github_record_error "шифрование ключа конфигурации" \
            "Не удалось атомарно зашифровать ключ новым паролем."
        return 1
    fi
    _github_remove_private_path "$unlock_tmp" ||
        warn "Защищённый staging-каталог нового ключа требует ручной очистки."
    if ! github_sync_flush; then
        if [[ "${GITHUB_LAST_STAGE:-}" == "отправка конфигурации в GitHub" ]]; then
            GITHUB_SYNC_STATUS=pending
            _github_report_last_error "Новый пароль сохранён локально, но не отправлен в GitHub"
            _github_remove_private_path "$identity_tmp" ||
                warn "Временный ключ смены пароля требует ручной очистки."
            rm -f "$backup" ||
                warn "Резервная копия смены пароля требует ручной очистки."
            _github_clear_error
            return 0
        fi
        failure_stage="${GITHUB_LAST_STAGE:-}"
        failure_detail="${GITHUB_LAST_ERROR:-}"
        if [[ -n "$old_head" ]] &&
           ! git -C "$GITHUB_WORKTREE" reset --hard "$old_head" >/dev/null 2>&1; then
            _github_record_error "откат смены пароля" \
                "Не удалось восстановить Git-состояние после ошибки публикации."
            return 1
        fi
        if ! mv "$backup" "$GITHUB_WORKTREE/unlock.age"; then
            _github_record_error "откат смены пароля" \
                "Не удалось восстановить прежний unlock.age."
            return 1
        fi
        _github_remove_private_path "$identity_tmp" ||
            warn "Временный ключ неудачной смены пароля требует ручной очистки."
        GITHUB_LAST_STAGE="$failure_stage"
        GITHUB_LAST_ERROR="$failure_detail"
        _github_ensure_error "публикация нового пароля" \
            "Не удалось опубликовать ключ с новым паролем."
        return 1
    fi
    _github_remove_private_path "$identity_tmp" ||
        warn "Новый пароль сохранён, но временный ключ требует ручной очистки."
    if ! rm -f "$backup"; then
        warn "Новый пароль сохранён, но резервная копия требует ручной очистки."
    fi
}
github_config_rotate_vault_key() {
    _github_clear_error
    if [[ ${GITHUB_STORAGE_MODE:-none} != age ]]; then
        _github_record_error "создание нового ключа шифрования" \
            "Текущая конфигурация не использует шифрование age."
        return 1
    fi
    warn "Будет создан новый ключ, и текущая конфигурация будет зашифрована заново. Пароли нод не изменятся."
    warn "Старые версии в истории GitHub останутся доступны по прежнему ключу."
    confirm_yn "Создать новый ключ шифрования?" N || return 1
    local backup path failure_stage failure_detail failure_hint failure_auth
    local old_identity="${GITHUB_IDENTITY:-}" old_recipient="${GITHUB_RECIPIENT:-}"
    local old_status="${GITHUB_SYNC_STATUS:-clean}" new_identity old_head=""
    old_head=$(git -C "$GITHUB_WORKTREE" rev-parse HEAD 2>/dev/null) || old_head=""
    backup=$(umask 077; mktemp -d "$CONFIG_DIR/.vault-rotation.XXXXXX") || return 1
    for path in recipient.txt unlock.age state.json.age; do
        if ! _github_exact_regular_file "$GITHUB_WORKTREE/$path" ||
           ! cp -p "$GITHUB_WORKTREE/$path" "$backup/$path"; then
            rm -rf "$backup"
            _github_record_error "подготовка ротации ключа" \
                "Не удалось сохранить атомарную резервную копию комплекта age."
            return 1
        fi
    done
    if github_config_age_init && github_config_checkpoint; then
        if github_sync_flush; then
            rm -rf "$backup" ||
                warn "Новый ключ опубликован, но резервная копия требует ручной очистки: $backup"
            if [[ "$old_identity" != "${GITHUB_IDENTITY:-}" ]] &&
               ! _github_remove_ephemeral_identity "$old_identity"; then
                warn "Прежний временный ключ требует ручной очистки."
            fi
            return 0
        fi
        if [[ "${GITHUB_LAST_STAGE:-}" == "отправка конфигурации в GitHub" ]]; then
            GITHUB_SYNC_STATUS=pending
            _github_report_last_error "Новый ключ сохранён локально, но не отправлен в GitHub"
            rm -rf "$backup" ||
                warn "Резервная копия ротации требует ручной очистки: $backup"
            if [[ "$old_identity" != "${GITHUB_IDENTITY:-}" ]] &&
               ! _github_remove_ephemeral_identity "$old_identity"; then
                warn "Прежний временный ключ требует ручной очистки."
            fi
            _github_clear_error
            return 0
        fi
    fi
    failure_stage="${GITHUB_LAST_STAGE:-}"
    failure_detail="${GITHUB_LAST_ERROR:-}"
    failure_hint="${GITHUB_LAST_HINT:-}"
    failure_auth="${GITHUB_LAST_AUTH_RELEVANT:-false}"
    new_identity="${GITHUB_IDENTITY:-}"
    if [[ -n "$old_head" ]] &&
       ! git -C "$GITHUB_WORKTREE" reset --hard "$old_head" >/dev/null 2>&1; then
        _github_record_error "откат ротации ключа" \
            "Не удалось восстановить Git-состояние прежнего комплекта age."
        return 1
    fi
    for path in recipient.txt unlock.age state.json.age; do
        if ! mv "$backup/$path" "$GITHUB_WORKTREE/$path"; then
            _github_record_error "откат ротации ключа" \
                "Не удалось восстановить прежний файл комплекта age: $path"
            return 1
        fi
    done
    rm -rf "$backup" ||
        warn "Резервная копия неудачной ротации требует ручной очистки: $backup"
    if [[ -n "$new_identity" && "$new_identity" != "$old_identity" ]]; then
        _github_remove_ephemeral_identity "$new_identity" ||
            warn "Новый временный ключ не удалось удалить после отката."
    fi
    GITHUB_IDENTITY="$old_identity"
    GITHUB_RECIPIENT="$old_recipient"
    GITHUB_SYNC_STATUS="$old_status"
    GITHUB_LAST_STAGE="$failure_stage"
    GITHUB_LAST_ERROR="$failure_detail"
    GITHUB_LAST_HINT="$failure_hint"
    GITHUB_LAST_AUTH_RELEVANT="$failure_auth"
    _github_ensure_error "ротация ключа конфигурации" \
        "Не удалось завершить ротацию ключа age."
    return 1
}
github_config_switch_local() {
    _github_clear_error
    if [[ ${CONFIG_SOURCE:-local} != github || -z "${GITHUB_WORKTREE:-}" ||
          ! -d "$GITHUB_WORKTREE" || ! -f ${CONFIG_JSON:-} ]]; then
        _github_record_error "проверка конфигурации перед отключением GitHub" \
            "Источник GitHub или его рабочая конфигурация недоступны."
        return 1
    fi
    if ! _github_validate_tree "$STATE_DIR" none ||
       ! state_validate true >/dev/null 2>&1; then
        _github_ensure_error "проверка конфигурации перед отключением GitHub" \
            "Конфигурация GitHub не прошла проверку переносимого состояния."
        return 1
    fi
    local staging backup archive stamp path failure_stage failure_detail
    local old_source="$CONFIG_SOURCE" old_state="$STATE_DIR" old_config="$CONFIG_JSON"
    local old_secrets="$SECRETS_JSON" old_manifest="$STATE_MANIFEST"
    local old_templates="$TEMPLATES_DIR" old_identities="$SSH_IDENTITIES_DIR"
    local old_hosts="$SSH_KNOWN_HOSTS" old_auth="$SCRIPT_AUTH_FILE"
    local -a paths=(config.json secrets.json manifest.json templates ssh)
    local -a backup_paths=(config.json secrets.json manifest.json templates ssh source.json)
    local -a moved=() published=()
    local backup_failed=false
    if { [[ -e "$CONFIG_DIR/import-backups" || -L "$CONFIG_DIR/import-backups" ]] &&
         [[ ! -d "$CONFIG_DIR/import-backups" || -L "$CONFIG_DIR/import-backups" ]]; } ||
       ! mkdir -p "$CONFIG_DIR/import-backups" ||
       ! chmod 700 "$CONFIG_DIR/import-backups"; then
        _github_record_error "подготовка локальной копии" \
            "Не удалось подготовить защищённый каталог резервных копий."
        return 1
    fi
    staging=$(umask 077; mktemp -d "$CONFIG_DIR/.local-switch-stage.XXXXXX") || {
        _github_record_error "подготовка локальной копии" \
            "Не удалось создать защищённый staging-каталог."
        return 1
    }
    backup=$(umask 077; mktemp -d "$CONFIG_DIR/.local-switch-backup.XXXXXX") || {
        rm -rf "$staging"
        return 1
    }
    if ! mkdir -p "$staging/templates" "$staging/ssh/identities" ||
       ! cp "$CONFIG_JSON" "$staging/config.json" ||
       ! cp "$SECRETS_JSON" "$staging/secrets.json" ||
       ! cp "$STATE_MANIFEST" "$staging/manifest.json" ||
       ! cp -Rp "$TEMPLATES_DIR/." "$staging/templates/" ||
       ! cp -Rp "$SSH_IDENTITIES_DIR/." "$staging/ssh/identities/"; then
        rm -rf "$staging" "$backup"
        _github_record_error "подготовка локальной копии" \
            "Не удалось полностью скопировать рабочее состояние GitHub."
        return 1
    fi
    if _github_exact_regular_file "$SSH_KNOWN_HOSTS"; then
        if ! cp "$SSH_KNOWN_HOSTS" "$staging/ssh/known_hosts"; then
            rm -rf "$staging" "$backup"
            return 1
        fi
    elif ! : > "$staging/ssh/known_hosts"; then
        rm -rf "$staging" "$backup"
        return 1
    fi
    if ! chmod 700 "$staging" "$staging/templates" "$staging/ssh" \
            "$staging/ssh/identities" ||
       ! chmod 600 "$staging/config.json" "$staging/secrets.json" \
            "$staging/manifest.json" "$staging/ssh/known_hosts"; then
        rm -rf "$staging" "$backup"
        _github_record_error "защита локальной копии" \
            "Не удалось установить безопасные права локальной копии."
        return 1
    fi
    for path in "$staging"/templates/*.yaml; do
        [[ -e "$path" ]] || continue
        chmod 644 "$path" || { rm -rf "$staging" "$backup"; return 1; }
    done
    for path in "$staging"/ssh/identities/*; do
        [[ -e "$path" ]] || continue
        case "$path" in
            *.pub) chmod 644 "$path" || { rm -rf "$staging" "$backup"; return 1; } ;;
            *) chmod 600 "$path" || { rm -rf "$staging" "$backup"; return 1; } ;;
        esac
    done
    if ! _github_validate_tree "$staging" none; then
        rm -rf "$staging" "$backup"
        return 1
    fi
    CONFIG_SOURCE=local
    STATE_DIR="$staging"; CONFIG_JSON="$staging/config.json"
    SECRETS_JSON="$staging/secrets.json"; STATE_MANIFEST="$staging/manifest.json"
    TEMPLATES_DIR="$staging/templates"; SSH_IDENTITIES_DIR="$staging/ssh/identities"
    SSH_KNOWN_HOSTS="$staging/ssh/known_hosts"
    if ! state_validate true >/dev/null 2>&1; then
        CONFIG_SOURCE="$old_source"; STATE_DIR="$old_state"; CONFIG_JSON="$old_config"
        SECRETS_JSON="$old_secrets"; STATE_MANIFEST="$old_manifest"
        TEMPLATES_DIR="$old_templates"; SSH_IDENTITIES_DIR="$old_identities"
        SSH_KNOWN_HOSTS="$old_hosts"; SCRIPT_AUTH_FILE="$old_auth"
        rm -rf "$staging" "$backup"
        _github_ensure_error "проверка локальной копии" \
            "Подготовленная локальная копия не прошла проверку."
        return 1
    fi
    CONFIG_SOURCE="$old_source"; STATE_DIR="$old_state"; CONFIG_JSON="$old_config"
    SECRETS_JSON="$old_secrets"; STATE_MANIFEST="$old_manifest"
    TEMPLATES_DIR="$old_templates"; SSH_IDENTITIES_DIR="$old_identities"
    SSH_KNOWN_HOSTS="$old_hosts"; SCRIPT_AUTH_FILE="$old_auth"
    for path in "${backup_paths[@]}"; do
        if [[ -e "$CONFIG_DIR/$path" || -L "$CONFIG_DIR/$path" ]]; then
            case "$path" in
                config.json|secrets.json|manifest.json|source.json)
                    if ! _github_exact_regular_file "$CONFIG_DIR/$path"; then
                        backup_failed=true
                        break
                    fi
                    ;;
                templates|ssh)
                    if [[ ! -d "$CONFIG_DIR/$path" || -L "$CONFIG_DIR/$path" ]]; then
                        backup_failed=true
                        break
                    fi
                    ;;
            esac
            if ! mv "$CONFIG_DIR/$path" "$backup/$path"; then
                backup_failed=true
                break
            fi
            moved+=("$path")
        fi
    done
    if [[ "$backup_failed" == true ]]; then
        for path in "${moved[@]}"; do
            mv "$backup/$path" "$CONFIG_DIR/$path" || {
                _github_record_error "откат резервного копирования" \
                    "Не удалось восстановить прежний локальный путь: $path"
                return 1
            }
        done
        rm -rf "$staging" "$backup"
        _github_record_error "резервное копирование локального состояния" \
            "Не удалось атомарно убрать прежние локальные пути."
        return 1
    fi
    for path in "${paths[@]}"; do
        if ! mv "$staging/$path" "$CONFIG_DIR/$path"; then
            break
        fi
        published+=("$path")
    done
    if ((${#published[@]} != ${#paths[@]})); then
        for path in "${published[@]}"; do
            rm -rf "$CONFIG_DIR/$path" || return 1
        done
        for path in "${moved[@]}"; do
            mv "$backup/$path" "$CONFIG_DIR/$path" || return 1
        done
        rm -rf "$staging" "$backup"
        _github_record_error "публикация локального состояния" \
            "Не удалось опубликовать полный комплект локальных файлов."
        return 1
    fi
    if ! github_config_close; then
        failure_stage="${GITHUB_LAST_STAGE:-}"
        failure_detail="${GITHUB_LAST_ERROR:-}"
        for path in "${published[@]}"; do
            rm -rf "$CONFIG_DIR/$path" || return 1
        done
        for path in "${moved[@]}"; do
            mv "$backup/$path" "$CONFIG_DIR/$path" || return 1
        done
        rm -rf "$staging" "$backup"
        GITHUB_LAST_STAGE="$failure_stage"
        GITHUB_LAST_ERROR="$failure_detail"
        return 1
    fi
    CONFIG_SOURCE=local
    STATE_DIR="$CONFIG_DIR"; CONFIG_JSON="$CONFIG_DIR/config.json"
    SECRETS_JSON="$CONFIG_DIR/secrets.json"; STATE_MANIFEST="$CONFIG_DIR/manifest.json"
    TEMPLATES_DIR="$CONFIG_DIR/templates"; SSH_IDENTITIES_DIR="$CONFIG_DIR/ssh/identities"
    SSH_KNOWN_HOSTS="$CONFIG_DIR/ssh/known_hosts"; SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
    GITHUB_REMOTE=""; GITHUB_OWNER=""
    if stamp=$(date -u +%Y%m%dT%H%M%SZ); then
        archive="$CONFIG_DIR/import-backups/$stamp-${backup##*.}"
    fi
    if [[ -n "${archive:-}" ]] && mv "$backup" "$archive"; then
        :
    else
        warn "Прежняя локальная копия сохранена во временном каталоге: $backup"
    fi
    rmdir "$staging" 2>/dev/null ||
        warn "Staging-каталог локального переключения требует ручной очистки."
    _github_clear_error
    export CONFIG_SOURCE STATE_DIR CONFIG_JSON SECRETS_JSON STATE_MANIFEST
    export TEMPLATES_DIR SSH_IDENTITIES_DIR SSH_KNOWN_HOSTS SCRIPT_AUTH_FILE
    export GITHUB_WORKTREE GITHUB_IDENTITY GITHUB_RECIPIENT GITHUB_REMOTE GITHUB_OWNER
}
github_config_open() {
    _github_clear_error
    local root="${1:?worktree}" out="${2:-${CONFIG_DIR:-.}/runtime-state.json}"
    local id decrypt_tmp
    if [[ ! -d "$root" || -L "$root" ]]; then
        _github_record_error "подготовка рабочей копии конфигурации" \
            "Рабочая копия конфигурации GitHub недоступна."
        return 1
    fi
    GITHUB_WORKTREE="$root"
    _github_validate_tree "$root" auto || return 1
    _github_validate_tracked_tree auto || return 1
    _github_storage_read || return 1
    _github_validate_tree "$root" "$GITHUB_STORAGE_MODE" || return 1
    _github_validate_tracked_tree "$GITHUB_STORAGE_MODE" || return 1
    if [[ $GITHUB_STORAGE_MODE == none ]]; then
        if ! _github_plain_read "$out"; then
            _github_ensure_error "чтение конфигурации GitHub" \
                "Не удалось прочитать незашифрованную конфигурацию GitHub."
            return 1
        fi
    else
        if ! _github_exact_regular_file "$root/recipient.txt" ||
           ! _github_exact_regular_file "$root/unlock.age" ||
           ! _github_exact_regular_file "$root/state.json.age" ||
           [[ ! -s "$root/recipient.txt" || ! -s "$root/unlock.age" ||
              ! -s "$root/state.json.age" ]]; then
            _github_record_error "чтение конфигурации GitHub" \
                "Зашифрованная конфигурация GitHub неполна."
            return 1
        fi
        GITHUB_RECIPIENT=$(tr -d '\r\n' < "$root/recipient.txt")
        if [[ -z "$GITHUB_RECIPIENT" ]]; then
            _github_record_error "чтение конфигурации GitHub" \
                "Зашифрованная конфигурация GitHub не содержит recipient."
            return 1
        fi
        github_config_unlock || return 1
        id="${GITHUB_IDENTITY:-}"
        if ! _github_exact_regular_file "$id" || [[ ! -s "$id" ]]; then
            _github_record_error "расшифровка конфигурации GitHub" \
                "Не удалось разблокировать конфигурацию: пароль или ключ восстановления не подошёл."
            return 1
        fi
        decrypt_tmp=$(_github_new_private_path "${out}.tmp.XXXXXX") || {
            _github_record_error "расшифровка конфигурации GitHub" \
                "Не удалось создать защищённый временный файл состояния."
            return 1
        }
        if ! (umask 077
                "$AGE_BIN" -d -i "$id" -o "$decrypt_tmp" \
                    "$root/state.json.age" >/dev/null 2>&1
             ) ||
           ! _github_exact_regular_file "$decrypt_tmp" ||
           ! github_config_validate "$decrypt_tmp" ||
           ! chmod 600 "$decrypt_tmp" ||
           ! mv "$decrypt_tmp" "$out"; then
            _github_remove_private_path "$decrypt_tmp"
            _github_ensure_error "расшифровка конфигурации GitHub" \
                "Не удалось атомарно расшифровать конфигурацию GitHub."
            return 1
        fi
        _github_remove_private_path "$decrypt_tmp" ||
            warn "Защищённый staging-каталог расшифровки требует ручной очистки."
    fi
}

_github_repo() { printf '%s/%s' "${GITHUB_OWNER:?}" "$GITHUB_REPO_NAME"; }
github_repository_delete() {
    _github_clear_error
    local repo="${1:-}" gh="${GH_BIN:-gh}" output
    if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        _github_record_error "удаление репозитория GitHub" \
            "Указан некорректный репозиторий GitHub."
        return 1
    fi
    if ! github_config_switch_local; then
        _github_ensure_error "сохранение локальной конфигурации перед удалением" \
            "Не удалось сохранить конфигурацию локально."
        return 1
    fi
    if ! _github_ensure_deps "" "https://github.com/$repo.git"; then
        _github_record_error "проверка зависимостей" \
            "Не удалось подготовить GitHub CLI."
        return 1
    fi
    if ! _github_require "$gh"; then
        _github_record_error "проверка зависимостей" \
            "Не найдена команда GitHub CLI: $gh."
        return 1
    fi
    if ! output=$(NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" repo delete "$repo" --yes 2>&1); then
        _github_record_error "удаление репозитория GitHub" "$output"
        return 1
    fi
}
github_repository_open_settings() {
    _github_clear_error
    local repo="${1:-}" gh="${GH_BIN:-gh}"
    if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        _github_record_error "открытие настроек репозитория GitHub" \
            "Указан некорректный репозиторий GitHub."
        return 1
    fi
    if ! _github_require "$gh"; then
        _github_record_error "проверка зависимостей" \
            "Не найдена команда GitHub CLI: $gh."
        return 1
    fi
    if ! NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" browse --settings --repo "$repo" \
        >/dev/null 2>&1; then
        _github_record_error "открытие настроек репозитория GitHub" \
            "Не удалось открыть настройки репозитория GitHub."
        return 1
    fi
}
github_source_metadata_valid() {
    local file="${1:-}"
    [[ -f "$file" ]] || return 1
    jq -e '
        type == "object" and
        (keys | sort) == ["branch", "private_verified", "repo", "type"] and
        .type == "github" and
        (.repo | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
        (.branch | type == "string" and length > 0 and test("^[A-Za-z0-9._/-]+$")) and
        .private_verified == true
    ' "$file" >/dev/null 2>&1
}
github_source_metadata_write() {
    _github_clear_error
    local tmp repo
    if [[ -z "${GITHUB_OWNER:-}" || -z "${GITHUB_REPO_NAME:-}" ||
          -z "${GITHUB_BRANCH:-}" ]] || ! mkdir -p "$CONFIG_DIR"; then
        _github_record_error "сохранение настроек источника" \
            "Не удалось сохранить параметры репозитория GitHub."
        return 1
    fi
    repo="$GITHUB_OWNER/$GITHUB_REPO_NAME"
    if ! tmp=$(umask 077; mktemp "$CONFIG_DIR/.source.XXXXXX"); then
        _github_record_error "сохранение настроек источника" \
            "Не удалось сохранить параметры репозитория GitHub."
        return 1
    fi
    if ! jq -n --arg repo "$repo" --arg branch "$GITHUB_BRANCH" \
        '{type:"github",repo:$repo,branch:$branch,private_verified:true}' > "$tmp" ||
       ! github_source_metadata_valid "$tmp" ||
       ! chmod 600 "$tmp" ||
       ! mv "$tmp" "$CONFIG_DIR/source.json"; then
        rm -f "$tmp"
        _github_record_error "сохранение настроек источника" \
            "Не удалось сохранить параметры репозитория GitHub."
        return 1
    fi
}
GITHUB_ACCOUNT_SWITCH_DIR="${GITHUB_ACCOUNT_SWITCH_DIR:-${CONFIG_DIR:-.}/account-switch}"
GITHUB_ACCOUNT_SWITCH_MARKER="${GITHUB_ACCOUNT_SWITCH_MARKER:-$GITHUB_ACCOUNT_SWITCH_DIR/transaction.json}"

_github_account_switch_root_valid() {
    local root="${GITHUB_ACCOUNT_SWITCH_DIR:-}"
    [[ -n "$root" && -d "$root" && ! -L "$root" ]]
}

_github_account_switch_path_is_managed() {
    local path="${1:-}" root="${GITHUB_ACCOUNT_SWITCH_DIR:-}"
    [[ -n "$root" && "$path" == "$root/"* || "$path" == "$root" ]] || return 1
    case "$path" in
        "$root"|"$root/old-store.git"|"$root/target-store.git"|"$root/target-sessions"|\
        "$root/target-sessions/"*|"$root/cached-sessions"|"$root/cached-sessions/"*|\
        "$root/old-source.json"|"$root/old-state.json"|"$root/target-state.json"|\
        "$root/transaction.json"|"$root"/.transaction.*)
            return 0 ;;
        *) return 1 ;;
    esac
}

github_account_switch_marker_valid() {
    local file="${1:-}"
    _github_exact_regular_file "$file" || return 1
    find "$file" -prune -type f -perm 600 >/dev/null 2>&1 || return 1
    jq -e '
        type == "object" and .version == 1 and
        (keys | sort) == ["branch","expected_head","initial_login","new_repo","old_repo",
            "old_state_available","phase","repo_created","repo_privatized","version"] and
        (.phase | type == "string" and
            test("^(prepared|push_unknown|target_committed|local_committed)$")) and
        (.old_repo | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
        (.new_repo | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
        (.branch | type == "string" and length > 0 and test("^[A-Za-z0-9._/-]+$")) and
        (.initial_login | type == "string" and test("^[A-Za-z0-9-]+$")) and
        (.expected_head == null or
            (.expected_head | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$"))) and
        (.old_state_available | type == "boolean") and
        (.repo_created | type == "boolean") and
        (.repo_privatized | type == "boolean")
    ' "$file" >/dev/null 2>&1
}

_github_account_switch_write_marker() {
    local phase="${1:?phase}" expected_head="${2:-}" old_state_available="${3:-false}"
    local repo_created="${4:-false}" repo_privatized="${5:-false}" tmp
    _github_mkdir_secure "$GITHUB_ACCOUNT_SWITCH_DIR" || return 1
    [[ "$old_state_available" == true || "$old_state_available" == false ]] || return 1
    [[ "$repo_created" == true || "$repo_created" == false ]] || return 1
    [[ "$repo_privatized" == true || "$repo_privatized" == false ]] || return 1
    tmp=$(umask 077; mktemp "$GITHUB_ACCOUNT_SWITCH_DIR/.transaction.XXXXXX") || return 1
    if ! jq -n \
        --arg phase "$phase" --arg old_repo "${GITHUB_ACCOUNT_SWITCH_OLD_REPO:-}" \
        --arg new_repo "${GITHUB_ACCOUNT_SWITCH_NEW_REPO:-}" \
        --arg branch "${GITHUB_ACCOUNT_SWITCH_BRANCH:-}" \
        --arg initial_login "${GITHUB_ACCOUNT_SWITCH_INITIAL_LOGIN:-}" \
        --arg expected_head "$expected_head" \
        --argjson old_state_available "$old_state_available" \
        --argjson repo_created "$repo_created" \
        --argjson repo_privatized "$repo_privatized" \
        '{
            version: 1, phase: $phase, old_repo: $old_repo, new_repo: $new_repo,
            branch: $branch, initial_login: $initial_login,
            expected_head: (if $expected_head == "" then null else $expected_head end),
            old_state_available: $old_state_available, repo_created: $repo_created,
            repo_privatized: $repo_privatized
        }' > "$tmp" ||
       ! chmod 600 "$tmp" ||
       ! github_account_switch_marker_valid "$tmp" ||
       ! mv "$tmp" "$GITHUB_ACCOUNT_SWITCH_MARKER"; then
        rm -f "$tmp"
        return 1
    fi
}

_github_account_switch_remove_path() {
    local path="${1:-}"
    _github_account_switch_path_is_managed "$path" || return 1
    [[ -e "$path" || -L "$path" ]] || return 0
    rm -rf "$path"
}

_github_account_switch_remove_file() {
    local path="${1:-}"
    _github_account_switch_path_is_managed "$path" || return 1
    [[ -e "$path" || -L "$path" ]] || return 0
    _github_exact_regular_file "$path" || return 1
    rm -f "$path"
}


github_account_switch_begin() {
    local old_repo="${1:-}" new_repo="${2:-}" branch="${3:-}" initial_login="${4:-}"
    local entry worktree=""
    [[ "$old_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ &&
       "$new_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ &&
       "$branch" =~ ^[A-Za-z0-9._/-]+$ &&
       "$initial_login" =~ ^[A-Za-z0-9-]+$ ]] || {
        _github_record_error "подготовка смены аккаунта GitHub" \
            "Параметры транзакции смены аккаунта имеют некорректный формат."
        return 1
    }
    if [[ -e "$GITHUB_ACCOUNT_SWITCH_MARKER" || -L "$GITHUB_ACCOUNT_SWITCH_MARKER" ]]; then
        _github_record_error "подготовка смены аккаунта GitHub" \
            "Обнаружена незавершённая или повреждённая смена аккаунта GitHub."
        return 1
    fi
    _github_mkdir_secure "$GITHUB_ACCOUNT_SWITCH_DIR" || {
        _github_record_error "подготовка смены аккаунта GitHub" \
            "Не удалось подготовить защищённый каталог транзакции."
        return 1
    }
    if [[ -n "${GITHUB_STORE:-}" && -d "$GITHUB_STORE" && ! -L "$GITHUB_STORE" ]]; then
        git --git-dir="$GITHUB_STORE" worktree prune >/dev/null 2>&1 || {
            _github_record_error "проверка активных сессий GitHub" \
                "Не удалось очистить устаревшие регистрации рабочих копий."
            return 1
        }
        while IFS= read -r entry; do
            case "$entry" in
                worktree\ *) worktree="${entry#worktree }" ;;
                bare) worktree="" ;;
                "")
                    if [[ -n "$worktree" && "$worktree" != "${GITHUB_WORKTREE:-}" ]]; then
                        _github_record_error "проверка активных сессий GitHub" \
                            "Другой экземпляр уже использует рабочую копию GitHub. Закройте его и повторите смену аккаунта."
                        return 1
                    fi
                    worktree=""
                    ;;
            esac
        done < <(git --git-dir="$GITHUB_STORE" worktree list --porcelain 2>/dev/null)
        if [[ -n "$worktree" && "$worktree" != "${GITHUB_WORKTREE:-}" ]]; then
            _github_record_error "проверка активных сессий GitHub" \
                "Другой экземпляр уже использует рабочую копию GitHub. Закройте его и повторите смену аккаунта."
            return 1
        fi
    fi
    GITHUB_ACCOUNT_SWITCH_OLD_REPO="$old_repo"
    GITHUB_ACCOUNT_SWITCH_NEW_REPO="$new_repo"
    GITHUB_ACCOUNT_SWITCH_BRANCH="$branch"
    GITHUB_ACCOUNT_SWITCH_INITIAL_LOGIN="$initial_login"
    GITHUB_ACCOUNT_SWITCH_REPO_CREATED=false
    GITHUB_ACCOUNT_SWITCH_REPO_PRIVATIZED=false
    export GITHUB_ACCOUNT_SWITCH_OLD_REPO GITHUB_ACCOUNT_SWITCH_NEW_REPO
    export GITHUB_ACCOUNT_SWITCH_BRANCH GITHUB_ACCOUNT_SWITCH_INITIAL_LOGIN
    export GITHUB_ACCOUNT_SWITCH_REPO_CREATED GITHUB_ACCOUNT_SWITCH_REPO_PRIVATIZED
    _github_account_switch_write_marker prepared "" false false false || {
        _github_record_error "подготовка смены аккаунта GitHub" \
            "Не удалось записать защищённую транзакцию смены аккаунта."
        return 1
    }
}

github_account_switch_finalize() {
    local desired_state="${1:-}" external_committed="${2:-false}"
    local expected_head="${3:-}" marker phase old_state_available repo_created repo_privatized
    local target_origin
    marker="$GITHUB_ACCOUNT_SWITCH_MARKER"
    github_account_switch_marker_valid "$marker" || {
        _github_record_error "локальная финализация смены аккаунта GitHub" "Маркер транзакции недоступен."
        return 1
    }
    phase=$(jq -er '.phase' "$marker") || {
        _github_record_error "локальная финализация смены аккаунта GitHub" "Не удалось прочитать фазу транзакции."
        return 1
    }
    _github_exact_regular_file "$desired_state" || {
        _github_record_error "локальная финализация смены аккаунта GitHub" "Снимок целевой конфигурации недоступен."
        return 1
    }
    github_config_validate "$desired_state" || {
        _github_record_error "локальная финализация смены аккаунта GitHub" "Снимок целевой конфигурации имеет некорректную структуру."
        return 1
    }
    case "$phase" in
        prepared|push_unknown|target_committed) ;;
        local_committed) return 0 ;;
        *) _github_record_error "локальная финализация смены аккаунта GitHub" "Неизвестная фаза транзакции."; return 1 ;;
    esac
    if [[ "$external_committed" == true && "$phase" == prepared ]]; then
        _github_record_error "локальная финализация смены аккаунта GitHub" "Публикация не подтверждена."
        return 1
    fi
    old_state_available=$(jq -r '.old_state_available' "$marker") || return 1
    repo_created=$(jq -r '.repo_created' "$marker") || return 1
    repo_privatized=$(jq -r '.repo_privatized' "$marker") || return 1
    if [[ -d "$GITHUB_ACCOUNT_SWITCH_DIR/target-store.git" &&
          ! -L "$GITHUB_ACCOUNT_SWITCH_DIR/target-store.git" ]]; then
        _github_account_switch_remove_path "$GITHUB_ACCOUNT_SWITCH_DIR/old-store.git" || {
            _github_record_error "локальная финализация смены аккаунта GitHub" "Не удалось подготовить резерв прежнего хранилища."
            return 1
        }
        if [[ -d "$GITHUB_STORE" && ! -L "$GITHUB_STORE" ]] &&
           ! mv "$GITHUB_STORE" "$GITHUB_ACCOUNT_SWITCH_DIR/old-store.git"; then
            _github_record_error "локальная финализация смены аккаунта GitHub" "Не удалось переместить прежнее хранилище GitHub."
            return 1
        fi
        if ! mv "$GITHUB_ACCOUNT_SWITCH_DIR/target-store.git" "$GITHUB_STORE"; then
            _github_record_error "локальная финализация смены аккаунта GitHub" "Не удалось установить новое хранилище GitHub."
            return 1
        fi
    else
        target_origin=$(git --git-dir="$GITHUB_STORE" remote get-url origin 2>/dev/null) || {
            _github_record_error "локальная финализация смены аккаунта GitHub" "Не удалось проверить установленное хранилище GitHub."
            return 1
        }
        [[ "$target_origin" == "https://github.com/${GITHUB_ACCOUNT_SWITCH_NEW_REPO}.git" &&
           -d "$GITHUB_ACCOUNT_SWITCH_DIR/old-store.git" ]] || {
            _github_record_error "локальная финализация смены аккаунта GitHub" "Хранилище транзакции не соответствует выбранному репозиторию."
            return 1
        }
    fi
    if [[ "$external_committed" == true ]]; then
        _github_account_switch_write_marker target_committed "$expected_head" \
            "$old_state_available" "$repo_created" "$repo_privatized" || {
            _github_record_error "локальная финализация смены аккаунта GitHub" "Не удалось зафиксировать подтверждённую отправку."
            return 1
        }
    fi
    return 0
}

github_account_switch_commit_local() {
    local marker="$GITHUB_ACCOUNT_SWITCH_MARKER"
    local phase old_state_available repo_created repo_privatized
    github_account_switch_marker_valid "$marker" || return 1
    phase=$(jq -er '.phase' "$marker") || return 1
    [[ "$phase" == prepared || "$phase" == target_committed ]] || return 1
    old_state_available=$(jq -r '.old_state_available' "$marker") || return 1
    repo_created=$(jq -r '.repo_created' "$marker") || return 1
    repo_privatized=$(jq -r '.repo_privatized' "$marker") || return 1
    _github_account_switch_write_marker local_committed "" \
        "$old_state_available" "$repo_created" "$repo_privatized"
}

github_account_switch_rollback() {
    local phase marker old_repo initial_login cleanup_ok=true switch_error=""
    marker="$GITHUB_ACCOUNT_SWITCH_MARKER"
    github_account_switch_marker_valid "$marker" || return 1
    phase=$(jq -er '.phase' "$marker") || return 1
    [[ "$phase" != target_committed && "$phase" != local_committed ]] || return 1
    old_repo=$(jq -er '.old_repo' "$marker") || return 1
    initial_login=$(jq -er '.initial_login' "$marker") || return 1
    _github_account_switch_remove_path "$GITHUB_ACCOUNT_SWITCH_DIR/target-store.git" || cleanup_ok=false
    _github_account_switch_remove_path "$GITHUB_ACCOUNT_SWITCH_DIR/target-sessions" || cleanup_ok=false
    _github_account_switch_remove_path "$GITHUB_ACCOUNT_SWITCH_DIR/cached-sessions" || cleanup_ok=false
    _github_account_switch_remove_file "$GITHUB_ACCOUNT_SWITCH_DIR/old-source.json" || cleanup_ok=false
    _github_account_switch_remove_file "$GITHUB_ACCOUNT_SWITCH_DIR/old-state.json" || cleanup_ok=false
    _github_account_switch_remove_file "$GITHUB_ACCOUNT_SWITCH_DIR/target-state.json" || cleanup_ok=false
    if ! _github_switch_active_account "$initial_login"; then
        switch_error="${GITHUB_LAST_ERROR:-Не удалось восстановить активный аккаунт GitHub.}"
        cleanup_ok=false
    fi
    GITHUB_OWNER="${old_repo%%/*}"
    GITHUB_ACTIVE_LOGIN="$initial_login"
    export GITHUB_OWNER GITHUB_ACTIVE_LOGIN
    if ! _github_account_switch_remove_file "$marker"; then
        cleanup_ok=false
    fi
    rmdir "$GITHUB_ACCOUNT_SWITCH_DIR" 2>/dev/null || true
    if [[ "$cleanup_ok" != true ]]; then
        [[ -z "$switch_error" ]] || _github_record_error "восстановление аккаунта GitHub" "$switch_error"
        return 1
    fi
}


_github_account_switch_finish_target() {
    local old_store="${GITHUB_STORE:-${CONFIG_DIR:-.}/github-store.git}"
    local sessions="${GITHUB_SESSIONS_DIR:-${CONFIG_DIR:-.}/github-sessions}"
    local branch new_repo target_state="$GITHUB_ACCOUNT_SWITCH_DIR/target-state.json"
    branch=$(jq -er '.branch' "$GITHUB_ACCOUNT_SWITCH_MARKER") || return 1
    new_repo=$(jq -er '.new_repo' "$GITHUB_ACCOUNT_SWITCH_MARKER") || return 1
    GITHUB_STORE="$old_store"; GITHUB_SESSIONS_DIR="$sessions"
    GITHUB_REMOTE="https://github.com/$new_repo.git"; GITHUB_BRANCH="$branch"
    GITHUB_OWNER="${new_repo%%/*}"; GITHUB_REPO_NAME="${new_repo#*/}"
    GITHUB_SESSION_ID=""; GITHUB_WORKTREE=""
    if [[ -d "$GITHUB_ACCOUNT_SWITCH_DIR/target-store.git" ]]; then
        github_account_switch_finalize "$target_state" false || return 1
    fi
    _github_session_open_cached "$old_store" "$sessions" "$branch" || return 1
    declare -F _config_source_materialize_state >/dev/null 2>&1 || return 1
    _config_source_materialize_state "$target_state" || return 1
    declare -F github_source_metadata_write >/dev/null 2>&1 || return 1
    github_source_metadata_write || return 1
    github_account_switch_commit_local || return 1
}

github_account_switch_recover() {
    local marker="$GITHUB_ACCOUNT_SWITCH_MARKER" expected head old_state_available
    local repo_created repo_privatized target_store phase
    if [[ ! -e "$marker" ]]; then
        return 0
    fi
    github_account_switch_marker_valid "$marker" || {
        _github_record_error "восстановление смены аккаунта GitHub" \
            "Транзакция смены аккаунта GitHub повреждена и требует ручного вмешательства."
        return 1
    }
    GITHUB_ACCOUNT_SWITCH_OLD_REPO=$(jq -er '.old_repo' "$marker") || return 1
    GITHUB_ACCOUNT_SWITCH_NEW_REPO=$(jq -er '.new_repo' "$marker") || return 1
    GITHUB_ACCOUNT_SWITCH_BRANCH=$(jq -er '.branch' "$marker") || return 1
    GITHUB_ACCOUNT_SWITCH_INITIAL_LOGIN=$(jq -er '.initial_login' "$marker") || return 1
    old_state_available=$(jq -r '.old_state_available' "$marker") || return 1
    repo_created=$(jq -r '.repo_created' "$marker") || return 1
    repo_privatized=$(jq -r '.repo_privatized' "$marker") || return 1
    export GITHUB_ACCOUNT_SWITCH_OLD_REPO GITHUB_ACCOUNT_SWITCH_NEW_REPO
    export GITHUB_ACCOUNT_SWITCH_BRANCH GITHUB_ACCOUNT_SWITCH_INITIAL_LOGIN
    phase=$(jq -er '.phase' "$marker") || return 1
    case "$phase" in
        prepared)
            github_account_switch_rollback
            ;;
        push_unknown)
            expected=$(jq -er '.expected_head // empty' "$marker") || return 1
            target_store="$GITHUB_ACCOUNT_SWITCH_DIR/target-store.git"
            [[ -n "$expected" && -d "$target_store" && ! -L "$target_store" ]] || return 1
            git --git-dir="$target_store" fetch --no-tags origin \
                "$GITHUB_ACCOUNT_SWITCH_BRANCH:refs/remotes/origin/$GITHUB_ACCOUNT_SWITCH_BRANCH" \
                >/dev/null 2>&1 || return 1
            head=$(git --git-dir="$target_store" rev-parse \
                "refs/remotes/origin/$GITHUB_ACCOUNT_SWITCH_BRANCH") || return 1
            if [[ "$head" == "$expected" ]] ||
               git --git-dir="$target_store" merge-base --is-ancestor "$expected" "$head"; then
                _github_account_switch_write_marker target_committed "$head" \
                    "$old_state_available" "$repo_created" "$repo_privatized" || return 1
                if declare -F _config_source_materialize_state >/dev/null 2>&1; then
                    _github_account_switch_finish_target || return 1
                    github_account_switch_recover
                fi
            else
                github_account_switch_rollback
            fi
            ;;
        target_committed)
            if declare -F _config_source_materialize_state >/dev/null 2>&1; then
                _github_account_switch_finish_target || return 1
                github_account_switch_recover
            fi
            ;;
        local_committed)
            _github_account_switch_remove_path "$GITHUB_ACCOUNT_SWITCH_DIR/old-store.git" || return 1
            _github_account_switch_remove_path "$GITHUB_ACCOUNT_SWITCH_DIR/target-sessions" || return 1
            _github_account_switch_remove_file "$marker" || return 1
            _github_account_switch_remove_file "$GITHUB_ACCOUNT_SWITCH_DIR/old-source.json" || return 1
            _github_account_switch_remove_file "$GITHUB_ACCOUNT_SWITCH_DIR/old-state.json" || return 1
            _github_account_switch_remove_file "$GITHUB_ACCOUNT_SWITCH_DIR/target-state.json" || return 1
            rmdir "$GITHUB_ACCOUNT_SWITCH_DIR" 2>/dev/null || true
            ;;
        *) return 1 ;;
    esac
}


legacy_local_source_metadata_valid() {
    local file="${1:-}"
    [[ -f "$file" ]] || return 1
    jq -e 'type=="object" and keys==["type"] and .type=="local"' \
        "$file" >/dev/null 2>&1
}


_github_archive_oid() {
    local oid="${1:-}" label="${2:-archive}" archive_ref
    [[ -n "$oid" ]] || return 0
    archive_ref="refs/archive/${label}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    git --git-dir="$GITHUB_STORE" update-ref "$archive_ref" "$oid"
}
_github_session_target_guard() {
    local actual expected
    if [[ -z "${GITHUB_WORKTREE:-}" && -z "${GITHUB_SESSION_ID:-}" ]]; then
        return 0
    fi
    if [[ -z "${GITHUB_SESSION_REMOTE:-}" ||
          -z "${GITHUB_SESSION_BRANCH:-}" ||
          "${GITHUB_REMOTE:-}" != "$GITHUB_SESSION_REMOTE" ||
          "${GITHUB_BRANCH:-}" != "$GITHUB_SESSION_BRANCH" ]]; then
        _github_record_error "проверка цели рабочей сессии GitHub" \
            "Запрошенный репозиторий или ветка не совпадает с неизменяемой целью текущей сессии."
        return 1
    fi
    actual=$(git --git-dir="$GITHUB_STORE" remote get-url origin 2>/dev/null) || {
        _github_record_error "проверка цели рабочей сессии GitHub" \
            "Не удалось проверить origin текущей сессии."
        return 1
    }
    expected="${GITHUB_SESSION_ORIGIN:-$GITHUB_SESSION_REMOTE}"
    if [[ "$actual" != "$expected" ]]; then
        _github_record_error "проверка цели рабочей сессии GitHub" \
            "Origin локального хранилища не совпадает с неизменяемой целью текущей сессии."
        return 1
    fi
}
_github_session_open_cached() {
    local store="${1:-}" sessions="${2:-}" branch="${3:-}" dir session git_output
    [[ -d "$store" && -d "$store/objects" &&
       "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
    git --git-dir="$store" show-ref --verify --quiet "refs/heads/$branch" || return 1
    _github_mkdir_secure "$sessions" || return 1
    session="${GITHUB_SESSION_ID:-cached-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM}"
    dir="$sessions/$session"
    _github_mkdir_secure "$dir" || return 1
    if ! git_output=$(git --git-dir="$store" worktree add \
        -b "session/$session" "$dir/worktree" "$branch" 2>&1); then
        rmdir "$dir" 2>/dev/null || true
        return 1
    fi
    chmod 700 "$dir" "$dir/worktree" || return 1
    GITHUB_STORE="$store"
    GITHUB_SESSIONS_DIR="$sessions"
    GITHUB_SESSION_ID="$session"
    GITHUB_WORKTREE="$dir/worktree"
    GITHUB_BRANCH="$branch"
    GITHUB_REMOTE=$(git --git-dir="$store" remote get-url origin 2>/dev/null || true)
    GITHUB_SESSION_REMOTE="$GITHUB_REMOTE"
    GITHUB_SESSION_BRANCH="$branch"
    GITHUB_SESSION_ORIGIN="$GITHUB_REMOTE"
    export GITHUB_STORE GITHUB_SESSIONS_DIR GITHUB_SESSION_ID GITHUB_WORKTREE
    export GITHUB_SESSION_REMOTE GITHUB_SESSION_BRANCH GITHUB_SESSION_ORIGIN
}


github_sync_init() {
    local allow_create="${1:-false}"
    local init_mode="${2:-resume}"
    local allow_make_private="${3:-false}"
    _github_clear_error
    case "$init_mode" in
        resume|onboarding) ;;
        *) _github_record_error "подготовка локального репозитория" "Неизвестный режим инициализации GitHub."; return 1 ;;
    esac
    if [[ -n "${GITHUB_WORKTREE:-}" && -d "$GITHUB_WORKTREE" ]] &&
       git -C "$GITHUB_WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        _github_session_target_guard || return 1
        return 0
    fi
    if ! _github_ensure_deps "" "$GITHUB_REMOTE"; then
        _github_record_error "проверка зависимостей" "Не удалось подготовить git и GitHub CLI."
        return 1
    fi
    if ! _github_require git; then
        _github_record_error "проверка зависимостей" "Не найдена команда git."
        return 1
    fi

    local repo remote_view remote_view_lc login setup_output create_output
    local git_output fetch_output fetch_ok=true local_oid="" remote_oid=""
    local current_origin="" remote_changed=false auth_failure=false
    local gh="${GH_BIN:-gh}"
    if [[ "$GITHUB_REMOTE" != /* && "$GITHUB_REMOTE" != *.git && "$GITHUB_REMOTE" != file://* ]]; then
        if ! _github_ensure_deps; then
            _github_record_error "проверка зависимостей" "Не удалось подготовить GitHub CLI."
            return 1
        fi
        if ! _github_require "$gh"; then
            _github_record_error "проверка зависимостей" "Не найдена команда GitHub CLI: $gh."
            return 1
        fi
        if ! setup_output=$(NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" auth setup-git 2>&1); then
            _github_auth_failure_confirmed "$setup_output" && auth_failure=true
            _github_record_error "настройка Git для GitHub CLI" "$setup_output" "$auth_failure"
            return 1
        fi
        auth_failure=false
        if ! login=$(NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" api user --jq .login 2>&1); then
            _github_auth_failure_confirmed "$login" && auth_failure=true
            _github_record_error "определение пользователя GitHub" "$login" "$auth_failure"
            return 1
        fi
        login=$(printf '%s' "$login" | tr -d '\r\n')
        if [[ -z "$login" ]]; then
            _github_record_error "определение пользователя GitHub" \
                "GitHub API вернул пустое имя пользователя."
            return 1
        fi
        [[ -n "$GITHUB_OWNER" ]] || GITHUB_OWNER="$login"
        if [[ "$login" != "$GITHUB_OWNER" ]]; then
            _github_record_error "проверка пользователя GitHub" \
                "GitHub CLI подключён как $login, ожидался пользователь $GITHUB_OWNER." true \
                "Переключите активный аккаунт GitHub: gh auth switch --hostname github.com --user $GITHUB_OWNER"
            return 1
        fi
        repo="$GITHUB_OWNER/$GITHUB_REPO_NAME"
        if ! remote_view=$(NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" repo view "$repo" --json visibility 2>&1); then
            remote_view_lc=$(printf '%s' "$remote_view" | tr '[:upper:]' '[:lower:]')
            if [[ "$remote_view_lc" != *"not found"* &&
                  "$remote_view_lc" != *"could not resolve to a repository"* ]]; then
                auth_failure=false
                _github_auth_failure_confirmed "$remote_view" && auth_failure=true
                _github_record_error "проверка приватного репозитория" \
                    "$remote_view" "$auth_failure"
                return 1
            fi
            if [[ "$allow_create" != true ]]; then
                _github_record_error "проверка приватного репозитория" \
                    "Репозиторий $repo не найден."
                return 1
            fi
            info "Репозиторий $repo не найден."
            if ! confirm_yn "Создать приватный репозиторий $repo?" N; then
                _github_record_error "создание приватного репозитория" \
                    "Создание репозитория $repo отменено."
                return 1
            fi
            if ! create_output=$(NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" repo create "$repo" \
                --private --description "Essence Remote Control configuration" 2>&1); then
                auth_failure=false
                _github_auth_failure_confirmed "$create_output" && auth_failure=true
                _github_record_error "создание приватного репозитория" \
                    "$create_output" "$auth_failure"
                return 1
            fi
            remote_view='{"visibility":"PRIVATE"}'
            GITHUB_ACCOUNT_SWITCH_REPO_CREATED=true
        fi
        if ! printf '%s' "$remote_view" |
            jq -e '.visibility == "PRIVATE"' >/dev/null 2>&1; then
            if [[ "$allow_make_private" != true ]] ||
               ! confirm_yn "Репозиторий $repo публичный. Сделать его приватным?" N; then
                _github_record_error "проверка приватного репозитория" \
                    "Репозиторий $repo должен быть приватным."
                return 1
            fi
            if ! git_output=$(NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" repo edit "$repo" \
                --visibility private --accept-visibility-change-consequences 2>&1); then
                _github_record_error "изменение видимости репозитория" "$git_output"
                return 1
            fi
            GITHUB_ACCOUNT_SWITCH_REPO_PRIVATIZED=true
            if ! remote_view=$(NO_COLOR=1 GH_PROMPT_DISABLED=1 "$gh" repo view "$repo" \
                --json visibility 2>&1) ||
               ! printf '%s' "$remote_view" | jq -e '.visibility == "PRIVATE"' >/dev/null 2>&1; then
                _github_record_error "проверка приватного репозитория" \
                    "Не удалось подтвердить приватность репозитория $repo."
                return 1
            fi
        fi
        GITHUB_REMOTE="https://github.com/$repo.git"
    fi

    if ! _github_mkdir_secure "$GITHUB_STORE" "$GITHUB_SESSIONS_DIR"; then
        _github_record_error "подготовка локального хранилища" \
            "Не удалось создать служебные каталоги GitHub."
        return 1
    fi
    GITHUB_SESSION_ID=${GITHUB_SESSION_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM}
    local dir="$GITHUB_SESSIONS_DIR/$GITHUB_SESSION_ID" remote_ref remote_refs
    if ! _github_mkdir_secure "$dir"; then
        _github_record_error "подготовка локального хранилища" \
            "Не удалось создать каталог рабочей сессии."
        return 1
    fi
    if [[ ! -d "$GITHUB_STORE/objects" ]]; then
        if ! git_output=$(git init --bare "$GITHUB_STORE" 2>&1); then
            _github_record_error "подготовка локального репозитория" "$git_output"
            return 1
        fi
    fi
    if current_origin=$(git --git-dir="$GITHUB_STORE" remote get-url origin 2>/dev/null); then
        if [[ "$current_origin" != "$GITHUB_REMOTE" ]]; then
            if ! git_output=$(git --git-dir="$GITHUB_STORE" remote set-url \
                origin "$GITHUB_REMOTE" 2>&1); then
                _github_record_error "настройка адреса репозитория" "$git_output"
                return 1
            fi
            remote_changed=true
        fi
    elif ! git_output=$(git --git-dir="$GITHUB_STORE" remote add origin "$GITHUB_REMOTE" 2>&1); then
        _github_record_error "настройка адреса репозитория" "$git_output"
        return 1
    fi
    local local_ref="refs/heads/$GITHUB_BRANCH"
    remote_ref="refs/remotes/origin/$GITHUB_BRANCH"
    fetch_output=$(GIT_TERMINAL_PROMPT=0 _github_run_with_timeout 30 \
        git --git-dir="$GITHUB_STORE" fetch --no-tags origin "$GITHUB_BRANCH" 2>&1) || fetch_ok=false

    if [[ "$init_mode" == onboarding ]]; then
        if [[ "$fetch_ok" == true ]] &&
           git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$remote_ref"; then
            if ! remote_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$remote_ref" 2>&1); then
                _github_record_error "чтение локальной версии конфигурации" "$remote_oid"
                return 1
            fi
            if git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$local_ref"; then
                if ! local_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$local_ref" 2>&1); then
                    _github_record_error "чтение локальной версии конфигурации" "$local_oid"
                    return 1
                fi
                if [[ "$local_oid" != "$remote_oid" ]] &&
                   ! git --git-dir="$GITHUB_STORE" merge-base --is-ancestor \
                        "$local_ref" "$remote_ref"; then
                    if ! _github_archive_oid "$local_oid" onboarding; then
                        _github_record_error "сохранение локальной истории перед подключением" \
                            "Не удалось сохранить локальную ветку перед выбором версии конфигурации."
                        return 1
                    fi
                fi
            fi
            if ! git --git-dir="$GITHUB_STORE" update-ref "$local_ref" "$remote_ref"; then
                _github_record_error "обновление локальной копии репозитория" \
                    "Не удалось подготовить локальную ветку конфигурации."
                return 1
            fi
            GITHUB_SYNC_STATUS=clean
        else
            if ! remote_refs=$(_github_run_with_timeout 15 git ls-remote \
                "$GITHUB_REMOTE" "refs/heads/$GITHUB_BRANCH" 2>/dev/null); then
                if [[ "$GITHUB_REMOTE" == https://github.com/* ]]; then
                    _github_record_error "загрузка репозитория GitHub" "$fetch_output"
                else
                    _github_record_error "загрузка репозитория GitHub" "$fetch_output"
                fi
                return 1
            fi
            if [[ -n "$remote_refs" ]]; then
                if [[ "$GITHUB_REMOTE" == https://github.com/* ]]; then
                    _github_record_error "загрузка репозитория GitHub" "$fetch_output"
                else
                    _github_record_error "загрузка репозитория GitHub" "$fetch_output"
                fi
                return 1
            fi
            local previous_oid=""
            if git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$local_ref"; then
                if ! previous_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$local_ref" 2>&1); then
                    _github_record_error "чтение локальной версии конфигурации" "$previous_oid"
                    return 1
                fi
                if ! _github_archive_oid "$previous_oid" onboarding; then
                    _github_record_error "сохранение локальной истории перед подключением" \
                        "Не удалось сохранить локальную ветку перед выбором версии конфигурации."
                    return 1
                fi
            fi
            if ! git_output=$(git --git-dir="$GITHUB_STORE" update-ref -d "$local_ref" 2>&1); then
                _github_record_error "обновление локальной копии репозитория" "$git_output"
                return 1
            fi
            if ! git_output=$(git --git-dir="$GITHUB_STORE" update-ref -d "$remote_ref" 2>&1); then
                _github_record_error "обновление локальной копии репозитория" "$git_output"
                return 1
            fi
            GITHUB_SYNC_STATUS=clean
        fi
    elif [[ "$fetch_ok" == true ]] &&
       git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$remote_ref"; then
        if ! remote_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$remote_ref" 2>&1); then
            _github_record_error "чтение локальной версии конфигурации" "$remote_oid"
            return 1
        fi
        if ! git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$local_ref"; then
            if ! git_output=$(git --git-dir="$GITHUB_STORE" update-ref \
                "$local_ref" "$remote_ref" 2>&1); then
                _github_record_error "обновление локальной копии репозитория" "$git_output"
                return 1
            fi
            GITHUB_SYNC_STATUS=clean
            local_oid="$remote_oid"
        else
            if ! local_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$local_ref" 2>&1); then
                _github_record_error "чтение локальной версии конфигурации" "$local_oid"
                return 1
            fi
        fi
        if [[ -n "$local_oid" && "$local_oid" == "$remote_oid" ]]; then
            GITHUB_SYNC_STATUS=clean
        elif git --git-dir="$GITHUB_STORE" merge-base --is-ancestor "$remote_ref" "$local_ref"; then
            # A previous process committed locally while push was unavailable.
            # Keep that commit as the restart-safe source until it is pushed.
            GITHUB_SYNC_STATUS=pending
        elif git --git-dir="$GITHUB_STORE" merge-base --is-ancestor "$local_ref" "$remote_ref"; then
            if ! git_output=$(git --git-dir="$GITHUB_STORE" update-ref \
                "$local_ref" "$remote_ref" 2>&1); then
                _github_record_error "обновление локальной копии репозитория" "$git_output"
                return 1
            fi
            GITHUB_SYNC_STATUS=clean
        else
            _github_record_error "сверка локальных и удалённых изменений" \
                "Локальная конфигурация и GitHub изменились независимо. Автоматическое объединение остановлено, чтобы не потерять данные."
            return 1
        fi
    elif [[ "$fetch_ok" != true ]]; then
        if [[ "$remote_changed" == true ]]; then
            if remote_refs=$(_github_run_with_timeout 15 git ls-remote \
                "$GITHUB_REMOTE" "refs/heads/$GITHUB_BRANCH" 2>/dev/null) &&
               [[ -z "$remote_refs" ]]; then
                local previous_oid=""
                if git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$local_ref"; then
                    if ! previous_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$local_ref" 2>&1); then
                        _github_record_error "чтение локальной версии конфигурации" "$previous_oid"
                        return 1
                    fi
                elif git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$remote_ref"; then
                    if ! previous_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$remote_ref" 2>&1); then
                        _github_record_error "чтение локальной версии конфигурации" "$previous_oid"
                        return 1
                    fi
                fi
                if [[ -n "$previous_oid" ]] &&
                   ! _github_archive_oid "$previous_oid" remote-switch; then
                    _github_record_error "сохранение истории прежнего репозитория" \
                        "Не удалось сохранить прежнюю локальную ветку перед сменой репозитория."
                    return 1
                fi
                if ! git_output=$(git --git-dir="$GITHUB_STORE" update-ref -d "$local_ref" 2>&1); then
                    _github_record_error "обновление локальной копии репозитория" "$git_output"
                    return 1
                fi
                if ! git_output=$(git --git-dir="$GITHUB_STORE" update-ref -d "$remote_ref" 2>&1); then
                    _github_record_error "обновление локальной копии репозитория" "$git_output"
                    return 1
                fi
                info "Репозиторий GitHub изменён: прежняя история сохранена локально, новый пустой репозиторий будет инициализирован отдельно."
            else
                if [[ "$GITHUB_REMOTE" == https://github.com/* ]]; then
                    _github_record_error "загрузка нового репозитория GitHub" "$fetch_output"
                else
                    _github_record_error "загрузка нового репозитория GitHub" "$fetch_output"
                fi
                return 1
            fi
        fi
        GITHUB_SYNC_STATUS=offline
        if git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$local_ref"; then
            if git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$remote_ref"; then
                if ! local_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$local_ref" 2>&1); then
                    _github_record_error "чтение локальной версии конфигурации" "$local_oid"
                    return 1
                fi
                if ! remote_oid=$(git --git-dir="$GITHUB_STORE" rev-parse "$remote_ref" 2>&1); then
                    _github_record_error "чтение локальной версии конфигурации" "$remote_oid"
                    return 1
                fi
                if git --git-dir="$GITHUB_STORE" merge-base --is-ancestor "$remote_ref" "$local_ref" &&
                   [[ "$local_oid" != "$remote_oid" ]]; then
                    GITHUB_SYNC_STATUS=pending
                fi
            fi
        elif [[ "$GITHUB_REMOTE" == /* || "$GITHUB_REMOTE" == file://* ]] &&
             { [[ -d "$GITHUB_REMOTE" ]] ||
               [[ -z "$(_github_run_with_timeout 15 git ls-remote "$GITHUB_REMOTE" "refs/heads/$GITHUB_BRANCH" 2>/dev/null)" ]]; }; then
            :
        elif remote_refs=$(_github_run_with_timeout 15 git ls-remote "$GITHUB_REMOTE" 2>/dev/null) &&
             [[ -z "$remote_refs" ]]; then
            :
        else
            if [[ "$GITHUB_REMOTE" == https://github.com/* ]]; then
                _github_record_error "загрузка репозитория GitHub" "$fetch_output"
            else
                _github_record_error "загрузка репозитория GitHub" "$fetch_output"
            fi
            return 1
        fi
    fi
    if ! git --git-dir="$GITHUB_STORE" show-ref --verify --quiet "$local_ref"; then
        local tree commit
        if ! tree=$(printf '' | git --git-dir="$GITHUB_STORE" mktree 2>&1) ||
           ! commit=$(printf 'Initial empty state\n' |
                git -c user.name='Essence Remote Control' \
                    -c user.email='remote-control@localhost' \
                    --git-dir="$GITHUB_STORE" commit-tree "$tree" 2>&1) ||
           ! git_output=$(git --git-dir="$GITHUB_STORE" update-ref \
                "$local_ref" "$commit" 2>&1); then
            _github_record_error "создание локальной ветки конфигурации" \
                "${git_output:-${commit:-${tree:-}}}"
            return 1
        fi
    fi
    GITHUB_WORKTREE=$dir/worktree
    if ! git_output=$(git --git-dir="$GITHUB_STORE" worktree add \
        -b "session/$GITHUB_SESSION_ID" "$GITHUB_WORKTREE" "$GITHUB_BRANCH" 2>&1); then
        _github_record_error "подготовка рабочей копии конфигурации" "$git_output"
        return 1
    fi
    if ! chmod 700 "$dir" "$GITHUB_WORKTREE"; then
        _github_record_error "защита рабочей копии конфигурации" \
            "Не удалось ограничить доступ к служебным файлам."
        return 1
    fi
    GITHUB_SESSION_REMOTE="$GITHUB_REMOTE"
    GITHUB_SESSION_BRANCH="$GITHUB_BRANCH"
    GITHUB_SESSION_ORIGIN=$(git --git-dir="$GITHUB_STORE" remote get-url origin 2>/dev/null) || {
        _github_record_error "фиксация цели рабочей сессии GitHub" \
            "Не удалось сохранить origin созданной сессии."
        return 1
    }
    export GITHUB_WORKTREE GITHUB_SESSION_ID GITHUB_SESSION_REMOTE GITHUB_SESSION_BRANCH
    export GITHUB_SESSION_ORIGIN
}
github_sync_status() {
    printf '%s\n' "${GITHUB_SYNC_STATUS:-clean}"
}

_github_validate_tracked_tree() {
    local mode="${1:-${GITHUB_STORAGE_MODE:-auto}}" list entry meta rel
    local index_mode stage name valid
    list=$(umask 077; mktemp "${TMPDIR:-/tmp}/github-index.XXXXXX") || {
        _github_record_error "проверка файлов репозитория GitHub" \
            "Не удалось подготовить безопасный список индекса Git."
        return 1
    }
    if ! git -C "$GITHUB_WORKTREE" ls-files --stage -z > "$list"; then
        rm -f "$list"
        _github_record_error "проверка файлов репозитория GitHub" \
            "Не удалось проверить список файлов репозитория GitHub."
        return 1
    fi
    while IFS= read -r -d '' entry; do
        meta="${entry%%	*}"
        rel="${entry#*	}"
        index_mode="${meta%% *}"
        stage="${meta##* }"
        valid=false
        if [[ "$stage" == 0 ]] &&
           { [[ "$index_mode" == 100644 ]] || [[ "$index_mode" == 100755 ]]; }; then
            case "$mode:$rel" in
                auto:storage.json|auto:recipient.txt|auto:unlock.age|auto:state.json.age|\
                auto:config.json|auto:secrets.json|auto:manifest.json|auto:ssh/known_hosts|\
                age:storage.json|age:recipient.txt|age:unlock.age|age:state.json.age|\
                none:storage.json|none:config.json|none:secrets.json|none:manifest.json|none:ssh/known_hosts)
                    valid=true ;;
                auto:templates/*.yaml|none:templates/*.yaml)
                    name="${rel#templates/}"
                    [[ "$name" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] && valid=true ;;
                auto:ssh/identities/*|none:ssh/identities/*)
                    name="${rel#ssh/identities/}"
                    [[ "$name" =~ ^[0-9a-fA-F]{32}(\.pub)?$ ]] && valid=true ;;
            esac
        fi
        if [[ "$valid" != true ]]; then
            rm -f "$list"
            _github_record_error "проверка файлов репозитория GitHub" \
                "В индексе GitHub обнаружен недопустимый путь или тип: $rel"
            return 1
        fi
    done < "$list"
    if ! rm -f "$list"; then
        _github_record_error "проверка файлов репозитория GitHub" \
            "Не удалось удалить временный список индекса Git."
        return 1
    fi
}
_github_stage_allowlist() {
    local -a paths=(storage.json) existing=()
    local path
    _github_validate_tracked_tree "${GITHUB_STORAGE_MODE:-none}" || return 1
    _github_validate_tree "$GITHUB_WORKTREE" "${GITHUB_STORAGE_MODE:-none}" || return 1
    if [[ ${GITHUB_STORAGE_MODE:-none} == age ]]; then
        paths+=(recipient.txt unlock.age state.json.age)
    else
        paths+=(config.json secrets.json manifest.json ssh templates)
    fi
    for path in "${paths[@]}"; do
        if [[ -e "$GITHUB_WORKTREE/$path" || -L "$GITHUB_WORKTREE/$path" ]] ||
           [[ -n "$(git -C "$GITHUB_WORKTREE" ls-files -- "$path" 2>/dev/null)" ]]; then
            existing+=("$path")
        fi
    done
    ((${#existing[@]} == 0)) ||
        git -C "$GITHUB_WORKTREE" add -A -- "${existing[@]}"
}

_github_sync_commit() {
    local had_files=false commit_output head_output update_store_ref=true
    [[ -n "$(git -C "$GITHUB_WORKTREE" ls-files 2>/dev/null)" ]] && had_files=true
    _github_stage_allowlist || return 1
    if git -C "$GITHUB_WORKTREE" diff --cached --quiet; then
        [[ "$GITHUB_SYNC_STATUS" == pending ]] || update_store_ref=false
    else
        commit_output=$(git -C "$GITHUB_WORKTREE" \
            -c user.name='Essence Remote Control' \
            -c user.email='remote-control@localhost' commit -m \
            "remote-control: $([[ "$had_files" == false ]] && printf '%s' 'initialize state' || printf '%s' 'sync state')" 2>&1) || {
            _github_record_error "сохранение локальных изменений Git" "$commit_output"
            return 1
        }
    fi
    head_output=$(git -C "$GITHUB_WORKTREE" rev-parse HEAD 2>&1) || {
        _github_record_error "чтение локальной версии конфигурации" "$head_output"
        return 1
    }
    GITHUB_LAST_COMMIT_HEAD="$head_output"
    [[ "$update_store_ref" == true ]] || return 0
    git --git-dir="$GITHUB_STORE" update-ref "refs/heads/$GITHUB_BRANCH" "$head_output" || {
        _github_record_error "сохранение локальной точки восстановления" \
            "Не удалось закрепить локальный commit конфигурации."
        return 1
    }
}

_github_sync_push() {
    local expected_head="${1:-${GITHUB_LAST_COMMIT_HEAD:-}}" push_output
    [[ "$expected_head" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
    push_output=$(GIT_TERMINAL_PROMPT=0 _github_run_with_timeout 30 \
        git --git-dir="$GITHUB_STORE" push origin \
        "refs/heads/session/$GITHUB_SESSION_ID:refs/heads/$GITHUB_BRANCH" 2>&1) || {
        _github_record_error "отправка конфигурации в GitHub" "$push_output"
        return 1
    }
    GITHUB_SYNC_STATUS=clean
}

github_sync_flush() {
    _github_clear_error
    if [[ -z "${GITHUB_WORKTREE:-}" || ! -d "$GITHUB_WORKTREE" ]]; then
        _github_record_error "подготовка рабочей копии конфигурации" \
            "Рабочая копия конфигурации GitHub недоступна."
        GITHUB_SYNC_STATUS=pending
        return 1
    fi
    if ! _github_session_target_guard; then
        GITHUB_SYNC_STATUS=pending
        return 1
    fi
    local had_files=false commit_output push_output head head_output
    [[ -n "$(git -C "$GITHUB_WORKTREE" ls-files 2>/dev/null)" ]] && had_files=true
    if ! _github_stage_allowlist; then
        _github_ensure_error "подготовка файлов к отправке" \
            "Не удалось подготовить разрешённые файлы конфигурации для commit."
        GITHUB_SYNC_STATUS=pending
        return 1
    fi
    if ! git -C "$GITHUB_WORKTREE" diff --cached --quiet; then
        if ! commit_output=$(git -C "$GITHUB_WORKTREE" \
            -c user.name='Essence Remote Control' \
            -c user.email='remote-control@localhost' commit -m \
            "remote-control: $([[ "$had_files" == false ]] && printf '%s' 'initialize state' || printf '%s' 'sync state')" \
            2>&1); then
            _github_record_error "сохранение локальных изменений Git" "$commit_output"
            GITHUB_SYNC_STATUS=pending
            return 1
        fi
    elif [[ "$GITHUB_SYNC_STATUS" != pending ]]; then
        GITHUB_SYNC_STATUS=clean
        return 0
    fi
    if ! head_output=$(git -C "$GITHUB_WORKTREE" rev-parse HEAD 2>&1); then
        _github_record_error "чтение локальной версии конфигурации" "$head_output"
        GITHUB_SYNC_STATUS=pending
        return 1
    fi
    head="$head_output"
    # Preserve every committed mutation on the local main ref before network
    # I/O, so a new process can recover it even when push is unavailable.
    if ! git --git-dir="$GITHUB_STORE" update-ref "refs/heads/$GITHUB_BRANCH" "$head"; then
        _github_record_error "сохранение локальной точки восстановления" \
            "Не удалось закрепить локальный commit конфигурации."
        GITHUB_SYNC_STATUS=pending
        return 1
    fi
    if ! push_output=$(GIT_TERMINAL_PROMPT=0 _github_run_with_timeout 30 \
        git --git-dir="$GITHUB_STORE" push origin \
        "refs/heads/session/$GITHUB_SESSION_ID:refs/heads/$GITHUB_BRANCH" 2>&1); then
        if [[ "$GITHUB_REMOTE" == https://github.com/* ]]; then
            _github_record_error "отправка конфигурации в GitHub" "$push_output"
        else
            _github_record_error "отправка конфигурации в GitHub" "$push_output"
        fi
        GITHUB_SYNC_STATUS=pending
        return 1
    fi
    if ! git --git-dir="$GITHUB_STORE" update-ref \
            "refs/remotes/origin/$GITHUB_BRANCH" "$head" >/dev/null 2>&1; then
        warn "Push завершён, но локальный tracking-ref требует обновления при следующей синхронизации."
    fi
    GITHUB_SYNC_STATUS=clean
    return 0
}

github_sync_fetch() {
    _github_clear_error
    if [[ -z "${GITHUB_STORE:-}" || ! -d "$GITHUB_STORE" ]]; then
        _github_record_error "подготовка локального хранилища" \
            "Локальное GitHub-хранилище не настроено."
        return 1
    fi
    if [[ -n "${GITHUB_WORKTREE:-}" && -d "$GITHUB_WORKTREE" ]] &&
       ! github_sync_flush; then
        _github_ensure_error "подготовка файлов к отправке" \
            "Не удалось отправить локальные изменения перед загрузкой."
        return 1
    fi
    if ! declare -F config_source_startup >/dev/null 2>&1; then
        _github_record_error "повторное открытие источника GitHub" \
            "Функция открытия источника конфигурации недоступна."
        return 1
    fi
    local old_worktree="${GITHUB_WORKTREE:-}" old_session="${GITHUB_SESSION_ID:-}"
    local old_identity="${GITHUB_IDENTITY:-}" old_recipient="${GITHUB_RECIPIENT:-}"
    local old_session_remote="${GITHUB_SESSION_REMOTE:-}"
    local old_session_branch="${GITHUB_SESSION_BRANCH:-}"
    local old_session_origin="${GITHUB_SESSION_ORIGIN:-}"
    local old_status="${GITHUB_SYNC_STATUS:-clean}"
    local old_state_dir="${STATE_DIR:-}" runtime_snapshot="" has_runtime_snapshot=false
    local new_worktree new_session new_identity new_recipient
    local new_session_remote new_session_branch new_session_origin new_status
    local failure_stage failure_detail failure_hint failure_auth
    if declare -F _config_source_materialize_state >/dev/null 2>&1; then
        runtime_snapshot=$(umask 077; mktemp "$CONFIG_DIR/.fetch-runtime.XXXXXX") || {
            _github_record_error "резервное копирование рабочего состояния" \
                "Не удалось создать защищённый снимок перед загрузкой."
            return 1
        }
        if ! github_config_serialize "$runtime_snapshot" "${CONFIG_JSON:-}"; then
            rm -f "$runtime_snapshot"
            _github_ensure_error "резервное копирование рабочего состояния" \
                "Не удалось сохранить рабочее состояние перед загрузкой."
            return 1
        fi
        has_runtime_snapshot=true
    fi
    GITHUB_WORKTREE=""
    GITHUB_SESSION_ID=""
    GITHUB_IDENTITY=""
    GITHUB_RECIPIENT=""
    GITHUB_SESSION_REMOTE=""
    GITHUB_SESSION_BRANCH=""
    GITHUB_SESSION_ORIGIN=""
    if ! config_source_startup; then
        failure_stage="${GITHUB_LAST_STAGE:-}"
        failure_detail="${GITHUB_LAST_ERROR:-}"
        failure_hint="${GITHUB_LAST_HINT:-}"
        failure_auth="${GITHUB_LAST_AUTH_RELEVANT:-false}"
        if [[ -n "${GITHUB_WORKTREE:-}" || -n "${GITHUB_SESSION_ID:-}" ]] &&
           ! github_config_close; then
            _github_report_last_error "Не удалось очистить неудачную новую GitHub-сессию"
        fi
        if [[ "$has_runtime_snapshot" == true ]] &&
           ! _config_source_materialize_state "$runtime_snapshot" "$old_state_dir"; then
            failure_stage="откат рабочего состояния после загрузки"
            failure_detail="Не удалось восстановить runtime и пароль после ошибки повторного открытия."
        fi
        rm -f "$runtime_snapshot" ||
            warn "Снимок неудачной загрузки требует ручной очистки."
        GITHUB_WORKTREE="$old_worktree"; GITHUB_SESSION_ID="$old_session"
        GITHUB_IDENTITY="$old_identity"; GITHUB_RECIPIENT="$old_recipient"
        GITHUB_SESSION_REMOTE="$old_session_remote"
        GITHUB_SESSION_BRANCH="$old_session_branch"
        GITHUB_SESSION_ORIGIN="$old_session_origin"
        GITHUB_SYNC_STATUS="$old_status"
        GITHUB_LAST_STAGE="$failure_stage"; GITHUB_LAST_ERROR="$failure_detail"
        GITHUB_LAST_HINT="$failure_hint"; GITHUB_LAST_AUTH_RELEVANT="$failure_auth"
        _github_ensure_error "повторное открытие источника GitHub" \
            "Не удалось заново открыть конфигурацию после загрузки из GitHub."
        return 1
    fi
    if [[ -z "${GITHUB_WORKTREE:-}" || -z "${GITHUB_SESSION_ID:-}" ]]; then
        if [[ "$has_runtime_snapshot" == true ]] &&
           ! _config_source_materialize_state "$runtime_snapshot" "$old_state_dir"; then
            rm -f "$runtime_snapshot" ||
                warn "Снимок неудачной загрузки требует ручной очистки."
            GITHUB_WORKTREE="$old_worktree"; GITHUB_SESSION_ID="$old_session"
            GITHUB_IDENTITY="$old_identity"; GITHUB_RECIPIENT="$old_recipient"
            GITHUB_SESSION_REMOTE="$old_session_remote"
            GITHUB_SESSION_BRANCH="$old_session_branch"
            GITHUB_SESSION_ORIGIN="$old_session_origin"
            GITHUB_SYNC_STATUS="$old_status"
            _github_record_error "откат рабочего состояния после загрузки" \
                "Повторное открытие не создало сессию, а прежнее runtime-состояние восстановить не удалось."
            return 1
        fi
        GITHUB_WORKTREE="$old_worktree"; GITHUB_SESSION_ID="$old_session"
        GITHUB_IDENTITY="$old_identity"; GITHUB_RECIPIENT="$old_recipient"
        GITHUB_SESSION_REMOTE="$old_session_remote"
        GITHUB_SESSION_BRANCH="$old_session_branch"
        GITHUB_SESSION_ORIGIN="$old_session_origin"
        GITHUB_SYNC_STATUS="$old_status"
        rm -f "$runtime_snapshot" ||
            warn "Снимок загрузки требует ручной очистки."
        _github_clear_error
        return 0
    fi
    new_worktree="$GITHUB_WORKTREE"; new_session="$GITHUB_SESSION_ID"
    new_identity="${GITHUB_IDENTITY:-}"; new_recipient="${GITHUB_RECIPIENT:-}"
    new_session_remote="${GITHUB_SESSION_REMOTE:-}"
    new_session_branch="${GITHUB_SESSION_BRANCH:-}"
    new_session_origin="${GITHUB_SESSION_ORIGIN:-}"
    new_status="${GITHUB_SYNC_STATUS:-clean}"
    GITHUB_WORKTREE="$old_worktree"; GITHUB_SESSION_ID="$old_session"
    GITHUB_IDENTITY="$old_identity"; GITHUB_RECIPIENT="$old_recipient"
    GITHUB_SESSION_REMOTE="$old_session_remote"
    GITHUB_SESSION_BRANCH="$old_session_branch"
    GITHUB_SESSION_ORIGIN="$old_session_origin"
    GITHUB_SYNC_STATUS="$old_status"
    if [[ -n "$old_worktree" || -n "$old_session" ]] && ! github_config_close; then
        failure_stage="${GITHUB_LAST_STAGE:-}"
        failure_detail="${GITHUB_LAST_ERROR:-}"
        failure_hint="${GITHUB_LAST_HINT:-}"
        failure_auth="${GITHUB_LAST_AUTH_RELEVANT:-false}"
        GITHUB_WORKTREE="$new_worktree"; GITHUB_SESSION_ID="$new_session"
        GITHUB_IDENTITY="$new_identity"; GITHUB_RECIPIENT="$new_recipient"
        GITHUB_SESSION_REMOTE="$new_session_remote"
        GITHUB_SESSION_BRANCH="$new_session_branch"
        GITHUB_SESSION_ORIGIN="$new_session_origin"
        GITHUB_SYNC_STATUS="$new_status"
        if ! github_config_close; then
            _github_report_last_error "Не удалось очистить новую GitHub-сессию после ошибки замены"
        fi
        if [[ "$has_runtime_snapshot" == true ]] &&
           ! _config_source_materialize_state "$runtime_snapshot" "$old_state_dir"; then
            failure_stage="откат рабочего состояния после загрузки"
            failure_detail="Не удалось восстановить runtime и пароль после ошибки закрытия прежней сессии."
        fi
        rm -f "$runtime_snapshot" ||
            warn "Снимок неудачной загрузки требует ручной очистки."
        GITHUB_WORKTREE="$old_worktree"; GITHUB_SESSION_ID="$old_session"
        GITHUB_IDENTITY="$old_identity"; GITHUB_RECIPIENT="$old_recipient"
        GITHUB_SESSION_REMOTE="$old_session_remote"
        GITHUB_SESSION_BRANCH="$old_session_branch"
        GITHUB_SESSION_ORIGIN="$old_session_origin"
        GITHUB_SYNC_STATUS="$old_status"
        GITHUB_LAST_STAGE="$failure_stage"; GITHUB_LAST_ERROR="$failure_detail"
        GITHUB_LAST_HINT="$failure_hint"; GITHUB_LAST_AUTH_RELEVANT="$failure_auth"
        return 1
    fi
    GITHUB_WORKTREE="$new_worktree"; GITHUB_SESSION_ID="$new_session"
    GITHUB_IDENTITY="$new_identity"; GITHUB_RECIPIENT="$new_recipient"
    GITHUB_SESSION_REMOTE="$new_session_remote"
    GITHUB_SESSION_BRANCH="$new_session_branch"
    GITHUB_SESSION_ORIGIN="$new_session_origin"
    GITHUB_SYNC_STATUS="$new_status"
    export GITHUB_WORKTREE GITHUB_SESSION_ID GITHUB_IDENTITY GITHUB_RECIPIENT
    export GITHUB_SESSION_REMOTE GITHUB_SESSION_BRANCH GITHUB_SESSION_ORIGIN
    export GITHUB_SYNC_STATUS
    rm -f "$runtime_snapshot" ||
        warn "Снимок завершённой загрузки требует ручной очистки."
}

state_action() {
    local label=$1 fn=$2
    shift 2
    if [[ ${CONFIG_SOURCE:-local} == github ]]; then
        _github_clear_error
    fi
    if ! declare -F "$fn" >/dev/null 2>&1; then
        if [[ ${CONFIG_SOURCE:-local} == github ]]; then
            _github_record_error "изменение локальной конфигурации" \
                "Функция изменения конфигурации недоступна."
        fi
        return 1
    fi
    "$fn" "$@"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        if [[ ${CONFIG_SOURCE:-local} == github && -z ${GITHUB_LAST_ERROR:-} ]]; then
            _github_record_error "изменение локальной конфигурации" \
                "Не удалось выполнить изменение конфигурации."
        fi
        return "$rc"
    fi
    if [[ ${CONFIG_SOURCE:-local} == github ]]; then
        if ! state_validate true >/dev/null 2>&1; then
            _github_ensure_error "проверка изменённой конфигурации" \
                "Изменённая конфигурация не прошла проверку переносимого состояния."
            _github_report_last_error "Не удалось сохранить изменение в GitHub"
            return 1
        fi
        if ! state_checkpoint; then
            _github_ensure_error "сохранение локальной точки восстановления" \
                "Не удалось сохранить локальную точку восстановления конфигурации."
            _github_report_last_error "Не удалось сохранить изменение в GitHub"
            return 1
        fi
        if ! github_config_checkpoint; then
            GITHUB_SYNC_STATUS=pending
            _github_ensure_error "сохранение снимка конфигурации GitHub" \
                "Не удалось обновить снимок в рабочей копии GitHub."
            _github_report_last_error "Не удалось сохранить изменение в GitHub"
            return 1
        fi
        if ! github_sync_flush; then
            _github_report_last_error "Не удалось отправить изменение в GitHub"
            warn "Изменения сохранены локально и ожидают отправки."
            GITHUB_SYNC_STATUS=pending
            return 0
        fi
    else
        state_checkpoint || true
    fi
    return 0
}

github_config_close() {
    _github_clear_error
    local session_dir="" identity="${GITHUB_IDENTITY:-}" close_output restore_output
    local worktree="${GITHUB_WORKTREE:-}" session="${GITHUB_SESSION_ID:-}"
    [[ -n "$worktree" ]] && session_dir="${worktree%/worktree}"
    if [[ -n "$worktree" && -d "$worktree" ]]; then
        if ! close_output=$(git --git-dir="$GITHUB_STORE" worktree remove --force \
                "$worktree" 2>&1); then
            _github_record_error "закрытие рабочей сессии GitHub" "$close_output"
            return 1
        fi
    fi
    if [[ -n "$session" && -d ${GITHUB_STORE:-} ]]; then
        if ! close_output=$(git --git-dir="$GITHUB_STORE" update-ref -d \
                "refs/heads/session/$session" 2>&1); then
            if [[ -n "$worktree" && ! -e "$worktree" ]] &&
               { ! restore_output=$(git --git-dir="$GITHUB_STORE" worktree add \
                    "$worktree" "session/$session" 2>&1) ||
                 ! chmod 700 "$session_dir" "$worktree"; }; then
                _github_record_error "откат закрытия рабочей сессии GitHub" \
                    "${restore_output:-Не удалось восстановить рабочую копию после ошибки удаления ссылки.}"
            else
                _github_record_error "удаление ссылки рабочей сессии GitHub" "$close_output"
            fi
            return 1
        fi
    fi
    if [[ -n "$session_dir" && -d "$session_dir" ]] &&
       ! rmdir "$session_dir" 2>/dev/null; then
        _github_record_error "очистка каталога рабочей сессии GitHub" \
            "Не удалось удалить пустой каталог завершённой сессии."
        return 1
    fi
    if ! _github_remove_ephemeral_identity "$identity"; then
        GITHUB_WORKTREE=""
        GITHUB_SESSION_ID=""
        GITHUB_SESSION_REMOTE=""
        GITHUB_SESSION_BRANCH=""
        GITHUB_SESSION_ORIGIN=""
        export GITHUB_WORKTREE GITHUB_SESSION_ID
        export GITHUB_SESSION_REMOTE GITHUB_SESSION_BRANCH GITHUB_SESSION_ORIGIN
        _github_record_error "очистка временного ключа GitHub" \
            "Не удалось удалить временный ключ расшифровки."
        return 1
    fi
    GITHUB_WORKTREE=""
    GITHUB_SESSION_ID=""
    GITHUB_IDENTITY=""
    GITHUB_RECIPIENT=""
    GITHUB_SESSION_REMOTE=""
    GITHUB_SESSION_BRANCH=""
    GITHUB_SESSION_ORIGIN=""
    unset GITHUB_MASTER_PASSWORD
    export GITHUB_WORKTREE GITHUB_SESSION_ID GITHUB_IDENTITY GITHUB_RECIPIENT
    export GITHUB_SESSION_REMOTE GITHUB_SESSION_BRANCH GITHUB_SESSION_ORIGIN
}

