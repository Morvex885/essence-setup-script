#!/bin/bash
# ─── Hysteria2 ───────────────────────────────────────────────────────────────

hy2_menu() {
    echo ""
    box_top
    box_center "Hysteria2"
    box_bot
    echo ""
    if grep -q '# --- hy2 ---' /etc/mihomo/config.yaml 2>/dev/null; then
        echo -e "  Статус: ${GREEN}установлен${NC}"
    else
        echo -e "  Статус: ${RED}не установлен${NC}"
    fi
    echo ""
    echo -e "  ${GREEN}1)${NC} Установить Hysteria2"
    echo -e "  ${RED}2)${NC} Удалить Hysteria2"
    echo -e "  ${NC}0)${NC} Назад"
    echo ""
    read -rp "Выберите действие [0-2]: " HY2_MENU_CHOICE

    case "$HY2_MENU_CHOICE" in
        1) install_hy2 ;;
        2) uninstall_hy2 ;;
        0) return ;;
        *) warn "Неверный выбор." ;;
    esac
}

install_hy2() {
    echo ""

    if [[ ! -f /etc/mihomo/config.yaml ]]; then
        warn "Mihomo не установлен. Сначала выполните установку (пункт 1)."
        return
    fi

    if grep -q '# --- hy2 ---' /etc/mihomo/config.yaml; then
        warn "Hysteria2 уже настроен в config.yaml."
        confirm_yn "Перезаписать существующую конфигурацию?" || { info "Отменено."; return; }
    fi

    # ── Ввод параметров ──────────────────────────────────────────────────────
    DEFAULT_PORT=$(gen_free_port 10000 65535)
    read -rp "Порт для Hysteria2 [Enter = $DEFAULT_PORT]: " HY2_PORT
    [[ -z "$HY2_PORT" ]] && HY2_PORT="$DEFAULT_PORT"
    while true; do
        if ! [[ "$HY2_PORT" =~ ^[0-9]+$ ]] || (( HY2_PORT < 1 || HY2_PORT > 65535 )); then
            warn "Неверный порт '$HY2_PORT'. Введите число от 1 до 65535."
        elif ! is_port_free "$HY2_PORT"; then
            warn "Порт $HY2_PORT уже занят. Введите другой."
        else
            break
        fi
        read -rp "Новый порт: " HY2_PORT
        [[ -z "$HY2_PORT" ]] && { warn "Порт не указан"; return; }
    done

    DEFAULT_USER="vpn"
    read -rp "Имя пользователя [Enter = $DEFAULT_USER]: " HY2_USER
    [[ -z "$HY2_USER" ]] && HY2_USER="$DEFAULT_USER"

    DEFAULT_PASS=$(openssl rand -hex 16)
    read -rp "Пароль [Enter = $DEFAULT_PASS]: " HY2_PASS
    [[ -z "$HY2_PASS" ]] && HY2_PASS="$DEFAULT_PASS"

    echo ""
    echo -e "  Через какой прокси пускать трафик?"
    echo -e "  ${GREEN}1)${NC} outbound (по умолчанию)"
    echo -e "  ${NC}2)${NC} DIRECT"
    read -rp "Выберите [Enter = 1]: " PROXY_CHOICE
    PROXY_CHOICE="${PROXY_CHOICE:-1}"
    case "$PROXY_CHOICE" in
        1) HY2_PROXY="outbound" ;;
        2) HY2_PROXY="DIRECT" ;;
        *) warn "Неверный выбор."; return ;;
    esac

    echo ""
    info "Obfs salamander — маскирует QUIC-трафик Hysteria2 под случайные байты,"
    info "скрывая сам факт использования протокола. Требует совпадения пароля на клиенте."
    if confirm_yn "Включить obfs salamander?"; then
        DEFAULT_OBFS_PASS=$(openssl rand -hex 12)
        read -rp "Пароль obfs [Enter = $DEFAULT_OBFS_PASS]: " HY2_OBFS_PASS
        [[ -z "$HY2_OBFS_PASS" ]] && HY2_OBFS_PASS="$DEFAULT_OBFS_PASS"
        USE_OBFS=true
    else
        USE_OBFS=false
    fi

    echo ""
    info "Порт:         $HY2_PORT"
    info "Пользователь: $HY2_USER"
    info "Пароль:       $HY2_PASS"
    info "Прокси:       $HY2_PROXY"
    [[ "$USE_OBFS" == "true" ]] && info "Obfs:         salamander / пароль: $HY2_OBFS_PASS"
    echo ""
    confirm_yn "Всё верно?" || { info "Отменено."; return; }

    # ── Сертификат ───────────────────────────────────────────────────────────
    echo ""
    info "Генерирую самоподписанный TLS сертификат..."
    mkdir -p /etc/mihomo/certs/hy2
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=www.google.de" \
        -keyout /etc/mihomo/certs/hy2/server.key \
        -out    /etc/mihomo/certs/hy2/server.crt 2>/dev/null || error "Не удалось создать сертификат"
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
    systemctl restart mihomo &>/dev/null
    sleep 3

    if systemctl is-active --quiet mihomo; then
        success "Mihomo перезапущен с Hysteria2"
    else
        warn "Mihomo не запустился. Лог:"
        journalctl -u mihomo -n 20 --no-pager
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
}

uninstall_hy2() {
    echo ""

    if ! grep -q '# --- hy2 ---' /etc/mihomo/config.yaml 2>/dev/null; then
        warn "Hysteria2 не настроен в config.yaml."
        return
    fi

    local _cascade_names
    if _cascade_names=$(_check_cascade_users "hy2" 2>/dev/null) && [[ -n "$_cascade_names" ]]; then
        echo ""
        warn "Этот листенер используется каскадами:"
        echo "$_cascade_names" | while read -r _cn; do
            echo -e "    ${YELLOW}*${NC} $_cn"
        done
        warn "Удаление сломает эти каскады. Сначала удалите их."
        confirm_yn "Всё равно удалить?" || { info "Отменено."; return; }
    fi

    warn "Будет удалён listener Hysteria2, закрыт порт и удалены сертификаты."
    confirm_yn "Вы уверены?" || { info "Отменено."; return; }

    HY2_PORT=$(awk '/# --- hy2 ---/{f=1} f && /port:/{print $2; exit}' /etc/mihomo/config.yaml)

    sed '/^# --- hy2 ---/,/^# --- \/hy2 ---/d' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
    success "Listener Hysteria2 удалён из config.yaml"

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
