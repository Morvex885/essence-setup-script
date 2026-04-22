#!/bin/bash
# ─── Проверка зависимостей, самообновление, удаление ─────────────────────────

# ─── Пароль для доступа к скрипту ────────────────────────────────────────────

_script_pass_file() { echo "$CONFIG_DIR/.auth"; }

_hash_pass() {
    local salt
    salt=$(openssl rand -hex 8)
    openssl passwd -6 -salt "$salt" "$1"
}

_verify_pass() {
    local stored="$1" input="$2"
    local salt
    salt=$(echo "$stored" | cut -d'$' -f3)
    local input_hash
    input_hash=$(openssl passwd -6 -salt "$salt" "$input")
    [[ "$input_hash" == "$stored" ]]
}

check_script_password() {
    local passfile
    passfile=$(_script_pass_file)
    [[ ! -f "$passfile" ]] && return 0

    local stored
    stored=$(tr -d '\r\n' < "$passfile")
    [[ -z "$stored" ]] && return 0

    echo ""
    local attempts=3
    while (( attempts > 0 )); do
        read -rsp "  Введите пароль: " _input; echo ""
        if _verify_pass "$stored" "$_input"; then
            return 0
        fi
        attempts=$((attempts - 1))
        (( attempts > 0 )) && warn "Неверный пароль. Осталось попыток: $attempts"
    done
    error "Доступ запрещён."
}

set_script_password() {
    local passfile
    passfile=$(_script_pass_file)

    if [[ -f "$passfile" && -s "$passfile" ]]; then
        local stored
        stored=$(tr -d '\r\n' < "$passfile")
        echo ""
        echo -e "  ${GREEN}1)${NC} Сменить пароль"
        echo -e "  ${RED}2)${NC} Убрать пароль"
        echo -e "  ${NC}0)${NC} Назад"
        echo ""
        read -rp "  Выберите: " _choice
        case "$_choice" in
            1)
                read -rsp "  Текущий пароль: " _old; echo ""
                if ! _verify_pass "$stored" "$_old"; then
                    warn "Неверный пароль."; return
                fi
                read -rsp "  Новый пароль: " _new; echo ""
                [[ -z "$_new" ]] && { warn "Пароль не может быть пустым."; return; }
                read -rsp "  Повторите: " _confirm; echo ""
                [[ "$_new" != "$_confirm" ]] && { warn "Пароли не совпадают."; return; }
                _hash_pass "$_new" > "$passfile"
                chmod 600 "$passfile"
                success "Пароль изменён"
                ;;
            2)
                read -rsp "  Текущий пароль: " _old; echo ""
                if ! _verify_pass "$stored" "$_old"; then
                    warn "Неверный пароль."; return
                fi
                rm -f "$passfile"
                success "Пароль убран"
                ;;
            *) return ;;
        esac
    else
        echo ""
        read -rsp "  Новый пароль: " _new; echo ""
        [[ -z "$_new" ]] && { warn "Пароль не может быть пустым."; return; }
        read -rsp "  Повторите: " _confirm; echo ""
        [[ "$_new" != "$_confirm" ]] && { warn "Пароли не совпадают."; return; }
        _hash_pass "$_new" > "$passfile"
        chmod 600 "$passfile"
        success "Пароль установлен"
    fi
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

    _ensure_config
    chmod 600 "$CONFIG_JSON"
    check_update_start
}

# ─── Самообновление ───────────────────────────────────────────────────────────
self_update() {
    local installer="$SCRIPT_DIR/install-remote-control.sh"
    if [[ ! -f "$installer" ]]; then
        warn "install-remote-control.sh не найден. Переустановите скрипт командой из REMOTE.md."
        return
    fi
    if [[ $EUID -ne 0 ]]; then
        warn "Для обновления нужен root."
        warn "Запустите: sudo remote-control-essence  или  sudo bash $installer"
        return
    fi
    bash "$installer"
    CURRENT_VERSION=$(tr -d '\r' < "$VERSION_PATH" 2>/dev/null || echo "none")
}

# ─── Удаление remote-control-essence ──────────────────────────────────────────
uninstall_self() {
    echo ""
    echo -e "  ${RED}── Удаление remote-control-essence ──────────${NC}"
    confirm_yn "Вы уверены?" || return

    if [[ $EUID -ne 0 ]]; then
        warn "Для удаления нужен root."
        warn "Запустите: sudo remote-control-essence"
        return
    fi

    rm -f "/usr/local/bin/remote-control-essence"
    rm -rf "/opt/remote-control-essence"

    if confirm_yn "Удалить сохранённые ноды?"; then
        rm -rf "$HOME/.config/remote-control-essence"
        success "Ноды удалены"
    fi

    success "remote-control-essence удалён"
    exit 0
}
