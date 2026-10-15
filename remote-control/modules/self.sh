#!/bin/bash
# ─── Проверка зависимостей, самообновление, удаление ─────────────────────────

# ─── Пароль для доступа к скрипту ────────────────────────────────────────────

_script_pass_file() { echo "${SCRIPT_AUTH_FILE:-$CONFIG_DIR/.auth}"; }

_hash_pass() {
    local salt
    salt=$(openssl rand -hex 8)
    openssl passwd -6 -salt "$salt" "$1"
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
    input_hash=$(openssl passwd -6 -salt "$salt" "$input")
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

check_script_password() {
    local passfile
    passfile=$(_script_pass_file)
    [[ ! -f "$passfile" ]] && return 0

    local stored
    stored=$(tr -d '\r\n' < "$passfile")
    [[ -z "$stored" ]] && return 0

    echo ""
    while true; do
        local attempts=3 _input
        while (( attempts > 0 )); do
            if ! read -rsp "  Введите пароль: " _input; then
                echo ""
                return 1
            fi
            echo ""
            if _verify_pass "$stored" "$_input"; then
                return 0
            fi
            attempts=$((attempts - 1))
            (( attempts > 0 )) && warn "Неверный пароль. Осталось попыток: $attempts"
        done
        warn "Доступ запрещён."
        startup_recovery_menu "Восстановление доступа" true || return 1
    done
}

set_script_password() {
    local passfile stored _choice _old _new _confirm installed
    passfile=$(_script_pass_file)
    while true; do
        installed=false
        [[ -s "$passfile" ]] && installed=true
        echo ""
        box_top
        box_center "Пароль скрипта"
        box_mid
        if [[ "$installed" == true ]]; then
            box_line " Пароль: установлен" " ${GREEN}Пароль: установлен${NC}"
        else
            box_line " Пароль: не установлен" " ${DIM}Пароль: не установлен${NC}"
        fi
        box_mid
        if [[ "$installed" == true ]]; then
            menu_item 1 "Сменить пароль" YELLOW
            menu_item 2 "Убрать пароль" RED
        else
            menu_item 1 "Установить пароль" GREEN
        fi
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        IFS= read -rp "  Выберите действие: " _choice || return 0
        _choice="${_choice%$'\r'}"
        case "$_choice" in
            0) return 0 ;;
            1|2)
                [[ "$_choice" == 2 && "$installed" != true ]] && { warn "Неверный выбор."; continue; }
                if [[ "$installed" == true ]]; then
                    stored=$(tr -d '\r\n' < "$passfile") || return 1
                    if ! IFS= read -rsp "  Текущий пароль: " _old; then echo ""; return 0; fi
                    echo ""
                    _old="${_old%$'\r'}"
                    _verify_pass "$stored" "$_old" || { warn "Неверный пароль."; continue; }
                fi
                if [[ "$_choice" == 2 ]]; then
                    review_frame "Удаление пароля запуска" "Пароль запуска remote-control будет удалён." "Локальные данные и SSH-ключи сохранятся."
                    confirm_yn "Убрать пароль запуска?" N || continue
                    if state_action "script_password" _remove_script_password "$passfile"; then
                        success "Пароль убран"
                    else
                        warn "Операция с паролем не завершена. Проверьте его состояние перед повтором."
                    fi
                    continue
                fi
                if ! IFS= read -rsp "  Новый пароль: " _new; then echo ""; return 0; fi
                echo ""
                _new="${_new%$'\r'}"
                [[ -n "$_new" ]] || { warn "Пароль не может быть пустым."; continue; }
                if ! IFS= read -rsp "  Повторите пароль: " _confirm; then echo ""; return 0; fi
                echo ""
                _confirm="${_confirm%$'\r'}"
                [[ "$_new" == "$_confirm" ]] || { warn "Пароли не совпадают."; continue; }
                if state_action "script_password" _write_script_password "$passfile" "$_new"; then
                    success "Пароль сохранён"
                else
                    warn "Операция с паролем не завершена. Проверьте его состояние перед повтором."
                fi
                _old=""; _new=""; _confirm=""
                ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

# ─── Проверка зависимостей ───────────────────────────────────────────────────

check_deps() {
    local missing=()
    for cmd in ssh scp base64 openssl jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Не найдены утилиты: ${missing[*]}\nУстановите:\n  Linux:   sudo apt install ${missing[*]}\n  macOS:   brew install ${missing[*]}\n  Windows: winget install ${missing[*]}"
    fi
    check_update_start
}

# ─── Самообновление ───────────────────────────────────────────────────────────
self_update() {
    local installer="$SCRIPT_DIR/install-remote-control.sh"
    if [[ ! -f "$installer" ]]; then
        warn "install-remote-control.sh не найден. Переустановите скрипт командой из REMOTE.md."
        return 1
    fi
    if [[ $EUID -ne 0 ]]; then
        warn "Для обновления нужен root."
        warn "Запустите: sudo remote-control-essence  или  sudo bash $installer"
        return 1
    fi
    if ! bash "$installer"; then
        warn "Обновление не завершено. Повторите действие из меню."
        return 1
    fi
    success "Скрипт обновлён."
    warn "Для загрузки новых функций запустите remote-control-essence заново."
    exit 0
}

# ─── Удаление remote-control-essence ──────────────────────────────────────────
uninstall_self() {
    if [[ $EUID -ne 0 ]]; then
        warn "Для удаления нужен root."
        warn "Запустите: sudo remote-control-essence"
        return 1
    fi
    menu_select "Удаление remote-control" "Выберите, что сохранить" \
        "Сохранить локальные данные" "Удалить локальные данные" || return 0
    local remove_data=false data_path="${CONFIG_DIR:-}" data_fate="сохраняются"
    if [[ "$MENU_SELECT_INDEX" == 2 ]]; then
        remove_data=true
        data_fate="будут удалены"
        # Resolve the real directory so slash/dot aliases and symlinks cannot
        # turn the selected data removal into removal of HOME or root.
        [[ -n "$data_path" && -d "$data_path" ]] || {
            warn "Небезопасный путь локальных данных. Удаление отменено."
            return 1
        }
        data_path=$(cd "$data_path" && pwd -P) || return 1
        local home_path
        home_path=$(cd "$HOME" && pwd -P) || return 1
        if [[ "$data_path" == / || "$data_path" == "$home_path" ]]; then
            warn "Небезопасный путь локальных данных. Удаление отменено."
            return 1
        fi
    fi
    review_frame "Удаление remote-control" \
        "/usr/local/bin/remote-control-essence будет удалён." \
        "/opt/remote-control-essence будет удалён." \
        "Локальные данные: $data_path — $data_fate." \
        "Локальные данные: ноды, клиенты, группы, пароли, токены, шаблоны и SSH-ключи." \
        "Компоненты на нодах и репозиторий GitHub не удаляются."
    confirm_yn "Удалить remote-control в выбранном объёме?" N || return 0
    if ! rm -f "/usr/local/bin/remote-control-essence" ||
       ! rm -rf "/opt/remote-control-essence"; then
        warn "Удаление remote-control не завершено."
        return 1
    fi
    if [[ "$remove_data" == true ]] && ! rm -rf "$data_path"; then
        warn "Удаление remote-control не завершено."
        return 1
    fi
    success "remote-control удалён."
    exit 0
}
