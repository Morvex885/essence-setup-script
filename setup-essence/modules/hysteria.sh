#!/bin/bash
# ─── Hysteria2 ───────────────────────────────────────────────────────────────

hy2_menu() {
    local choice
    while true; do
        echo ""
        box_top
        box_center "Hysteria2"
        box_mid
        if grep -q '# --- hy2 ---' /etc/mihomo/config.yaml 2>/dev/null; then
            box_line " Статус: установлен" " ${GREEN}Статус: установлен${NC}"
        else
            box_line " Статус: не установлен" " ${DIM}Статус: не установлен${NC}"
        fi
        box_mid
        menu_item 1 "Установить Hysteria2" GREEN
        menu_item 2 "Удалить Hysteria2" RED
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите действие: " choice; then
            return 0
        fi
        choice="${choice%$'\r'}"
        case "$choice" in
            1)
                install_hy2 || {
                    [[ "${HY2_CANCELLED:-false}" == true ]] ||
                        warn "Установка Hysteria2 завершилась ошибкой."
                }
                ;;
            2) uninstall_hy2 || warn "Удаление Hysteria2 завершилось ошибкой." ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

install_hy2() {
    echo ""
    HY2_CANCELLED=false

    if [[ ! -f /etc/mihomo/config.yaml ]]; then
        warn "Mihomo не установлен. Сначала выберите «b) Базовая установка»."
        return 1
    fi

    if grep -q '# --- hy2 ---' /etc/mihomo/config.yaml; then
        review_frame "Замена Hysteria2" \
            "Существующее входное подключение Hysteria2 будет заменено." \
            "Прежние данные подключения перестанут работать."
        confirm_yn "Перезаписать существующую конфигурацию?" N || { info "Отменено."; return 0; }
    fi

    # ── Ввод параметров ──────────────────────────────────────────────────────
    DEFAULT_PORT=$(gen_free_port 10000 65535) || {
        warn "Не удалось подобрать порт для Hysteria2."
        return 1
    }
    IFS= read -rp "  Порт для Hysteria2 [Enter = $DEFAULT_PORT]: " HY2_PORT || { HY2_CANCELLED=true; return 1; }
    HY2_PORT="${HY2_PORT%$'\r'}"
    [[ -z "$HY2_PORT" ]] && HY2_PORT="$DEFAULT_PORT"
    while true; do
        if ! [[ "$HY2_PORT" =~ ^[0-9]+$ ]] || (( HY2_PORT < 1 || HY2_PORT > 65535 )); then
            warn "Неверный порт '$HY2_PORT'. Введите число от 1 до 65535."
        elif ! is_port_free "$HY2_PORT"; then
            warn "Порт $HY2_PORT уже занят. Введите другой."
        else
            break
        fi
        IFS= read -rp "  Новый порт: " HY2_PORT || { HY2_CANCELLED=true; return 1; }
        HY2_PORT="${HY2_PORT%$'\r'}"
        [[ -z "$HY2_PORT" ]] && { warn "Порт не указан"; return 1; }
    done

    DEFAULT_USER="vpn"
    IFS= read -rp "  Имя пользователя [Enter = $DEFAULT_USER]: " HY2_USER || { HY2_CANCELLED=true; return 1; }
    HY2_USER="${HY2_USER%$'\r'}"
    [[ -z "$HY2_USER" ]] && HY2_USER="$DEFAULT_USER"

    IFS= read -rp "  Пароль [Enter = сгенерировать]: " HY2_PASS || { HY2_CANCELLED=true; return 1; }
    HY2_PASS="${HY2_PASS%$'\r'}"
    if [[ -z "$HY2_PASS" ]]; then
        HY2_PASS=$(openssl rand -hex 16) && [[ -n "$HY2_PASS" ]] || {
            warn "Не удалось сгенерировать пароль."
            return 1
        }
    fi

    while true; do
        echo ""
        box_top
        box_center "Выход трафика Hysteria2"
        box_mid
        menu_item 1 "Через группу outbound" CYAN
        box_line "    WARP, если подключён и доступен; иначе DIRECT." "    ${DIM}WARP, если подключён и доступен; иначе DIRECT.${NC}"
        menu_item 2 "Напрямую (DIRECT)" CYAN
        box_line "    Выход с IP сервера, минуя группу outbound." "    ${DIM}Выход с IP сервера, минуя группу outbound.${NC}"
        menu_item 0 "Отмена" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите выход трафика [Enter = 1]: " PROXY_CHOICE; then
            HY2_CANCELLED=true
            return 1
        fi
        PROXY_CHOICE="${PROXY_CHOICE%$'\r'}"
        PROXY_CHOICE="${PROXY_CHOICE:-1}"
        case "$PROXY_CHOICE" in
            1) HY2_PROXY="outbound"; break ;;
            2) HY2_PROXY="DIRECT"; break ;;
            0) HY2_CANCELLED=true; return 1 ;;
            *) warn "Неверный выбор." ;;
        esac
    done

    echo ""
    info "Obfs salamander — маскирует QUIC-трафик Hysteria2 под случайные байты,"
    info "скрывая сам факт использования протокола. Требует совпадения пароля на клиенте."
    if confirm_yn "Включить obfs salamander?"; then
        IFS= read -rp "  Пароль obfs [Enter = сгенерировать]: " HY2_OBFS_PASS || { HY2_CANCELLED=true; return 1; }
        HY2_OBFS_PASS="${HY2_OBFS_PASS%$'\r'}"
        if [[ -z "$HY2_OBFS_PASS" ]]; then
            HY2_OBFS_PASS=$(openssl rand -hex 12) && [[ -n "$HY2_OBFS_PASS" ]] || {
                warn "Не удалось сгенерировать пароль."
                return 1
            }
        fi
        USE_OBFS=true
    else
        USE_OBFS=false
    fi

    echo ""
    info "Порт:         $HY2_PORT"
    info "Пользователь: $HY2_USER"
    info "Прокси:       $HY2_PROXY"
    [[ "$USE_OBFS" == "true" ]] && info "Obfs:         salamander"
    echo ""
    confirm_yn "Всё верно?" || { info "Отменено."; return; }
    local _hy2_old_umask
    _hy2_old_umask=$(umask)
    umask 077

    # ── Сертификат ───────────────────────────────────────────────────────────
    echo ""
    info "Генерирую самоподписанный TLS сертификат..."
    mkdir -p /etc/mihomo/certs/hy2
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=www.google.de" \
        -keyout /etc/mihomo/certs/hy2/server.key \
        -out    /etc/mihomo/certs/hy2/server.crt 2>/dev/null || {
        warn "Не удалось создать сертификат"
        umask "$_hy2_old_umask"
        return 1
    }
    chmod 600 /etc/mihomo/certs/hy2/server.key
    success "Сертификат: /etc/mihomo/certs/hy2/server.crt"

    # ── Обновление config.yaml ────────────────────────────────────────────────
    if grep -q '# --- hy2 ---' /etc/mihomo/config.yaml; then
        sed '/^# --- hy2 ---/,/^# --- \/hy2 ---/d' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
        mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
    fi

    local _obfs_arg=""
    [[ "$USE_OBFS" == "true" ]] && _obfs_arg="$HY2_OBFS_PASS"

    local _listener_yaml
    _listener_yaml=$(_build_hy2_listener_yaml "Hysteria2" "$HY2_PORT" "$HY2_USER" "$HY2_PASS" "$HY2_PROXY" "$_obfs_arg")

    printf '%s\n' "# --- hy2 ---" "$_listener_yaml" "# --- /hy2 ---" > /tmp/_inject_tmp.yaml

    awk '/^rule-providers:/{
        while ((getline line < "/tmp/_inject_tmp.yaml") > 0) print line
        print ""
    }
    {print}' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
    rm -f /tmp/_inject_tmp.yaml

    # ── Firewall ─────────────────────────────────────────────────────────────
    info "Открываю порт $HY2_PORT (UDP + TCP) в firewall..."
    ufw allow "${HY2_PORT}/udp" > /dev/null
    ufw allow "${HY2_PORT}/tcp" > /dev/null
    success "Порт $HY2_PORT открыт"

    # ── Перезапуск Mihomo ─────────────────────────────────────────────────────
    info "Перезапускаю Mihomo..."
    local _start_rc=0
    systemctl restart mihomo &>/dev/null || _start_rc=$?
    sleep 3

    if [[ "$_start_rc" -eq 0 ]] && systemctl is-active --quiet mihomo; then
        success "Mihomo перезапущен с Hysteria2"
    else
        warn "Не удалось запустить Mihomo. Проверьте журнал и повторите действие из меню."
        journalctl -u mihomo -n 20 --no-pager || true
        umask "$_hy2_old_umask"
        return 1
    fi

    # ── Клиентский конфиг ────────────────────────────────────────────────────
    HY2_SERVER=$(grep '^Server:' /etc/mihomo/client-config.txt 2>/dev/null | awk '{print $2}' | head -1)
    [[ -z "$HY2_SERVER" ]] && HY2_SERVER=$(curl -4 -s ifconfig.me)

    local _obfs_arg=""
    [[ "$USE_OBFS" == "true" ]] && _obfs_arg="$HY2_OBFS_PASS"

    HY2_URI=$(_build_hy2_uri "$HY2_PASS" "$HY2_SERVER" "$HY2_PORT" "www.google.de" "$_obfs_arg")
    local _client_yaml
    _client_yaml=$(_build_hy2_client_yaml "Hysteria2" "$HY2_SERVER" "$HY2_PORT" "$HY2_PASS" "www.google.de" "true" "$_obfs_arg")

    cat >> /etc/mihomo/client-config.txt << HY2SAVEOF

--- Hysteria2 ---
Server:   $HY2_SERVER
Port:     $HY2_PORT
User:     $HY2_USER
Password: $HY2_PASS
$(  [[ "$USE_OBFS" == "true" ]] && printf "Obfs:      salamander\nObfs pass: %s" "$HY2_OBFS_PASS" )
Proxy:    $HY2_PROXY

URI: $HY2_URI

--- Client proxy config (Mihomo/Clash.Meta) ---
$_client_yaml
--- /Hysteria2 ---
HY2SAVEOF

    echo ""
    success_box "Hysteria2 настроен!"
    echo ""
    echo -e "  Сервер:   ${CYAN}$HY2_SERVER${NC}"
    echo -e "  Порт:     ${CYAN}$HY2_PORT${NC}"
    echo -e "  Пароль:   ${CYAN}$HY2_PASS${NC}"
    [[ "$USE_OBFS" == "true" ]] && echo -e "  Obfs пароль: ${CYAN}$HY2_OBFS_PASS${NC}"
    echo -e "  Прокси:   ${CYAN}$HY2_PROXY${NC}"
    echo ""
    echo -e "  URI: ${CYAN}$HY2_URI${NC}"
    echo ""
    echo -e "  Клиентский конфиг: ${CYAN}/etc/mihomo/client-config.txt${NC}"
    echo ""
    umask "$_hy2_old_umask"
    return 0
}

uninstall_hy2() {
    echo ""

    if ! grep -q '# --- hy2 ---' /etc/mihomo/config.yaml 2>/dev/null; then
        warn "Hysteria2 не настроен в config.yaml."
        return
    fi

    local _cascade_names _cn
    local review_lines=("Входное подключение Hysteria2 будет удалено." "Порт будет закрыт; сертификаты и клиентская запись будут удалены." "Mihomo будет перезапущен.")
    if _cascade_names=$(_check_cascade_users "hy2" 2>/dev/null) && [[ -n "$_cascade_names" ]]; then
        review_lines+=("Доступ следующих каскадов перестанет работать:")
        while IFS= read -r _cn; do
            review_lines+=("Каскад: $_cn")
        done <<< "$_cascade_names"
    fi
    review_frame "Удаление Hysteria2" "${review_lines[@]}"
    confirm_yn "Удалить Hysteria2?" N || { info "Отменено."; return 0; }

    HY2_PORT=$(awk '/# --- hy2 ---/{f=1} f && /port:/{print $2; exit}' /etc/mihomo/config.yaml)

    sed '/^# --- hy2 ---/,/^# --- \/hy2 ---/d' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
    success "Входное подключение Hysteria2 удалено из config.yaml"

    if [[ -f /etc/mihomo/client-config.txt ]]; then
        sed '/^--- Hysteria2 ---/,/^--- \/Hysteria2 ---/d' /etc/mihomo/client-config.txt > /tmp/client_tmp.txt
        mv /tmp/client_tmp.txt /etc/mihomo/client-config.txt
        success "Секция Hysteria2 удалена из client-config.txt"
    fi

    if [[ -n "$HY2_PORT" ]]; then
        ufw delete allow "${HY2_PORT}/udp" > /dev/null 2>&1 || true
        ufw delete allow "${HY2_PORT}/tcp" > /dev/null 2>&1 || true
        success "Порт $HY2_PORT закрыт"
    fi

    rm -rf /etc/mihomo/certs/hy2
    success "Сертификаты удалены"

    info "Перезапускаю Mihomo..."
    systemctl restart mihomo &>/dev/null
    sleep 2
    if systemctl is-active --quiet mihomo; then
        success "Mihomo перезапущен"
    else
        warn "Mihomo не запустился. Лог:"
        journalctl -u mihomo -n 20 --no-pager
    fi
    echo ""
}
