#!/bin/bash
# ─── Пароль запуска, версия, самообновление, удаление ────────────────────────

# ─── Пароль для доступа к скрипту ────────────────────────────────────────────

_script_pass_file() { echo "${SCRIPT_AUTH_FILE:-$CONFIG_DIR/.auth}"; }

_hash_pass() {
    local salt
    salt=$(openssl rand -hex 8)
    # Пароль — через stdin: в argv он виден в /proc/<pid>/cmdline.
    printf '%s\n' "$1" | openssl passwd -6 -salt "$salt" -stdin
}
_script_password_hash_salt() {
    local stored="$1"
    [[ "$stored" =~ ^\$6\$(rounds=[0-9]+\$)?([./A-Za-z0-9]+)\$[./A-Za-z0-9]+$ ]] || return 1
    printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}


_verify_pass() {
    local stored="$1" input="$2"
    local salt
    salt=$(_script_password_hash_salt "$stored") || return 1
    local input_hash
    # Пароль — через stdin: в argv он виден в /proc/<pid>/cmdline.
    input_hash=$(printf '%s\n' "$input" | openssl passwd -6 -salt "$salt" -stdin)
    [[ "$input_hash" == "$stored" ]]
}

_write_script_password() {
    local passfile="$1" password="$2" tmp
    mkdir -p "$(dirname "$passfile")" || return 1
    tmp=$(umask 077; mktemp "${passfile}.tmp.XXXXXX") || return 1
    if ! _hash_pass "$password" > "$tmp" ||
       ! chmod 600 "$tmp" ||
       ! mv "$tmp" "$passfile"; then
        rm -f "$tmp"
        return 1
    fi
}

_remove_script_password() {
    rm -f "$1"
}

# Пароль запуска установлен (непустой хеш).
_self_password_installed() {
    [[ -f "$(_script_pass_file)" && -n "$(tr -d '\r\n' < "$(_script_pass_file)")" ]]
}

# Проверка текущего пароля запуска: если он установлен, нужен секрет
# current-password (auth_required / auth_failed). Без пароля — rc 0.
core_self_password_check_current() {
    local stored current
    _self_password_installed || return 0
    stored=$(tr -d '\r\n' < "$(_script_pass_file)")
    if ! current=$(rc_secret current-password); then
        rc_fail auth_required "Требуется текущий пароль запуска."
        return 1
    fi
    if ! _verify_pass "$stored" "$current"; then
        rc_fail auth_failed "Неверный текущий пароль запуска."
        return 1
    fi
}

# _self_auth_change FILE FN ARGS… — state_action FN under the mutation lock. In
# GitHub mode the write precedes the publishing steps and the next materialize
# would revert an unpublished file, so a reported failure brings the previous
# password file back. In local mode the file is the source of truth: a late
# checkpoint failure keeps the applied change, like any other state_action.
_self_auth_change() {
    local file="$1" backup="" rc=0
    shift
    if [[ "${CONFIG_SOURCE:-local}" != github ]]; then
        state_action script_password "$@"
        return
    fi
    if [[ -f "$file" ]]; then
        backup=$(umask 077; mktemp "${file}.restore.XXXXXX") || return 1
        cp -p "$file" "$backup" || { rm -f "$backup"; return 1; }
    fi
    state_action script_password "$@" || rc=$?
    if (( rc == 0 )); then
        [[ -z "$backup" ]] || rm -f "$backup"
        return 0
    fi
    if [[ -z "$backup" ]]; then
        rm -f "$file"
    elif cp -p "$backup" "$file"; then
        rm -f "$backup"
    else
        warn "Не удалось восстановить прежний пароль запуска; копия оставлена: $backup"
    fi
    # The checkpoint may already carry the new hash.
    state_checkpoint >/dev/null 2>&1 || true
    return "$rc"
}

# core_self_password_set NEW — записать хеш пароля запуска.
core_self_password_set() {
    local new="${1:-}" file
    [[ -n "$new" ]] || { rc_fail invalid "Пароль не может быть пустым."; return 1; }
    if [[ "$new" == *$'\n'* ]]; then
        rc_fail invalid "Пароль не может содержать перевод строки."
        return 1
    fi
    file=$(_script_pass_file)
    if ! rc_locked script_password _self_auth_change "$file" _write_script_password "$file" "$new"; then
        [[ -n "${RC_ERROR_CODE:-}" ]] ||
            rc_fail failed "Операция с паролем не завершена. Проверьте его состояние перед повтором."
        return 1
    fi
    success "Пароль сохранён"
}

core_self_password_remove() {
    local file
    file=$(_script_pass_file)
    if ! rc_locked script_password _self_auth_change "$file" _remove_script_password "$file"; then
        [[ -n "${RC_ERROR_CODE:-}" ]] ||
            rc_fail failed "Операция с паролем не завершена. Проверьте его состояние перед повтором."
        return 1
    fi
    success "Пароль убран"
}

# ─── Версия ──────────────────────────────────────────────────────────────────

# Синхронный запрос последнего релиза (те же API и таймауты, что check_update_start).
# Результат: SELF_LATEST_VERSION (пусто, если сеть недоступна).
core_self_version_fetch() {
    SELF_LATEST_VERSION=$(_github_release_curl \
        "https://api.github.com/repos/${_REPO}/releases/latest" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"' | tr -d '\r' || true)
    [[ -n "$SELF_LATEST_VERSION" ]]
}

# ─── Самообновление ──────────────────────────────────────────────────────────

_self_is_root() { [[ $EUID -eq 0 ]]; }

# core_self_update_plan — проверки и план. Результат: SELF_INSTALLER.
core_self_update_plan() {
    SELF_INSTALLER="$SCRIPT_DIR/install-remote-control.sh"
    CORE_PLAN_LINES=()
    if [[ ! -f "$SELF_INSTALLER" ]]; then
        rc_fail not_installed "install-remote-control.sh не найден. Инструкция по переустановке: docs/remote-control.md, раздел «Установленная версия»."
        return 1
    fi
    if ! _self_is_root; then
        rc_fail root_required "Для обновления нужен root: sudo remote-control-essence или sudo bash $SELF_INSTALLER"
        return 1
    fi
    CORE_PLAN_LINES=("Текущая версия: ${CURRENT_VERSION:-неизвестна}" "Будет установлена последняя версия из GitHub.")
}

core_self_update() {
    local rc=0
    bash "$SELF_INSTALLER" || rc=$?
    if (( rc != 0 )); then
        rc_fail update_failed "Обновление не завершено." "$(jq -cn --argjson rc "$rc" '{installer_rc:$rc}')"
        return 1
    fi
    success "Скрипт обновлён."
    warn "Для загрузки новых функций запустите remote-control-essence заново."
}

# ─── Удаление remote-control-essence ─────────────────────────────────────────

SELF_BIN_PATH="/usr/local/bin/remote-control-essence"
SELF_APP_PATH="/opt/remote-control-essence"

# core_self_uninstall_plan REMOVE_DATA(0|1) — проверки и план.
# Результат: SELF_DATA_PATH (реальный путь данных).
core_self_uninstall_plan() {
    local remove_data="${1:-0}" home_path data_fate="сохраняются"
    CORE_PLAN_LINES=()
    SELF_DATA_PATH="${CONFIG_DIR:-}"
    if ! _self_is_root; then
        rc_fail root_required "Для удаления нужен root: sudo remote-control-essence"
        return 1
    fi
    if [[ "$remove_data" == 1 ]]; then
        data_fate="будут удалены"
        # Реальный каталог: алиасы со слэшами/точками и симлинки не должны
        # превращать удаление данных в удаление HOME или корня.
        if [[ -z "$SELF_DATA_PATH" || ! -d "$SELF_DATA_PATH" ]]; then
            rc_fail unsafe_path "Небезопасный путь локальных данных. Удаление отменено." \
                "$(jq -cn --arg p "$SELF_DATA_PATH" '{path:$p}')"
            return 1
        fi
        SELF_DATA_PATH=$(cd "$SELF_DATA_PATH" && pwd -P) || return 1
        home_path=$(cd "$HOME" && pwd -P) || return 1
        if [[ "$SELF_DATA_PATH" == / || "$SELF_DATA_PATH" == "$home_path" ]]; then
            rc_fail unsafe_path "Небезопасный путь локальных данных. Удаление отменено." \
                "$(jq -cn --arg p "$SELF_DATA_PATH" '{path:$p}')"
            return 1
        fi
    fi
    CORE_PLAN_LINES=(
        "$SELF_BIN_PATH будет удалён."
        "$SELF_APP_PATH будет удалён."
        "Локальные данные: $SELF_DATA_PATH — $data_fate."
        "Локальные данные: ноды, клиенты, группы, пароли, токены, шаблоны и SSH-ключи."
        "Компоненты на нодах и репозиторий GitHub не удаляются."
    )
    if [[ "$remove_data" == 1 && "${CONFIG_SOURCE:-local}" == github &&
          "${GITHUB_SYNC_STATUS:-}" == pending ]]; then
        CORE_PLAN_LINES+=("Изменения, не отправленные в GitHub, будут потеряны: сначала выполните source github-push.")
    fi
}

# core_self_uninstall REMOVE_DATA — результат: SELF_REMOVED (строки путей).
core_self_uninstall() {
    local remove_data="${1:-0}"
    SELF_REMOVED=()
    if ! rm -f "$SELF_BIN_PATH" || ! rm -rf "$SELF_APP_PATH"; then
        rc_fail failed "Удаление remote-control не завершено."
        return 1
    fi
    SELF_REMOVED=("$SELF_BIN_PATH" "$SELF_APP_PATH")
    if [[ "$remove_data" == 1 ]]; then
        if ! rm -rf "$SELF_DATA_PATH"; then
            rc_fail failed "Удаление remote-control не завершено."
            return 1
        fi
        SELF_REMOVED+=("$SELF_DATA_PATH")
    fi
    success "remote-control удалён."
}
