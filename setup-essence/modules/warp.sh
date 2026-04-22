#!/bin/bash
# ─── WARP ────────────────────────────────────────────────────────────────────

warp_menu() {
    echo ""
    box_top
    box_center "WARP"
    box_bot
    echo ""
    if grep -q '# --- warp ---' /etc/mihomo/config.yaml 2>/dev/null; then
        echo -e "  Статус: ${GREEN}установлен${NC}"
    else
        echo -e "  Статус: ${RED}не установлен${NC}"
    fi
    echo ""
    echo -e "  ${GREEN}1)${NC} Установить WARP"
    echo -e "  ${YELLOW}2)${NC} Обновить ключ"
    echo -e "  ${RED}3)${NC} Удалить WARP"
    echo -e "  ${NC}0)${NC} Назад"
    echo ""
    read -rp "Выберите действие [0-3]: " WARP_CHOICE

    case "$WARP_CHOICE" in
        1) install_warp ;;
        2) update_warp ;;
        3) uninstall_warp ;;
        0) return ;;
        *) warn "Неверный выбор." ;;
    esac
}

install_warp() {
    echo ""

    if [[ ! -f /etc/mihomo/config.yaml ]]; then
        warn "Mihomo не установлен. Сначала выполните установку (пункт 1)."
        return
    fi

    if grep -q '# --- warp ---' /etc/mihomo/config.yaml; then
        warn "WARP уже настроен."
        confirm_yn "Переустановить?" || { info "Отменено."; return; }
        awk '
            /^# --- warp ---/{print; skip=1; next}
            skip && /^# --- \/warp ---/{skip=0}
            {print}
        ' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
        mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
        sed -i '/^      - warp-wg$/d' /etc/mihomo/config.yaml
    fi

    echo ""
    read -rp "WARP+ лицензионный ключ (Enter = бесплатный WARP): " WARP_LICENSE
    echo ""

    CURRENT_IPV6=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "0")
    if [[ "$CURRENT_IPV6" == "1" ]]; then
        WARP_DNS="['1.1.1.1', '1.0.0.1']"
    else
        WARP_DNS="['1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001']"
    fi

    WGCF_DIR="/root/wgcf"
    mkdir -p "$WGCF_DIR"
    cd "$WGCF_DIR"

    if [[ ! -f "$WGCF_DIR/wgcf" ]] || ! "$WGCF_DIR/wgcf" --version > /dev/null 2>&1; then
        rm -f "$WGCF_DIR/wgcf"
        info "Определяю последнюю версию wgcf..."
        WGCF_VERSION=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest \
            | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v')
        [[ -z "$WGCF_VERSION" ]] && error "Не удалось получить версию wgcf с GitHub."
        local wgcf_arch
        case "$(uname -m)" in
            aarch64|arm64) wgcf_arch="arm64" ;;
            armv7l|armv7)  wgcf_arch="armv7" ;;
            *)             wgcf_arch="amd64" ;;
        esac
        info "Скачиваю wgcf v${WGCF_VERSION} (${wgcf_arch})..."
        curl -sLo "$WGCF_DIR/wgcf" \
            "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${wgcf_arch}" \
            || { rm -f "$WGCF_DIR/wgcf"; error "Не удалось скачать wgcf"; }
        chmod +x "$WGCF_DIR/wgcf"
        success "wgcf скачан"
    fi

    info "Регистрирую аккаунт WARP..."
    printf 'y\n' | ./wgcf register || error "Ошибка регистрации WARP"

    if [[ -n "$WARP_LICENSE" ]]; then
        info "Применяю WARP+ лицензионный ключ..."
        ./wgcf update --license-key "$WARP_LICENSE" || warn "Ключ не применился — продолжаю с бесплатным WARP"
    fi

    info "Генерирую WireGuard конфиг..."
    ./wgcf generate

    WARP_PRIVATE_KEY=$(grep 'PrivateKey' wgcf-profile.conf | awk '{print $3}')
    WARP_IP=$(grep 'Address' wgcf-profile.conf | awk '{print $3}' | cut -d'/' -f1 | cut -d',' -f1)
    WARP_PUBLIC_KEY=$(grep 'PublicKey' wgcf-profile.conf | awk '{print $3}')

    [[ -z "$WARP_PRIVATE_KEY" || -z "$WARP_IP" || -z "$WARP_PUBLIC_KEY" ]] && \
        error "Не удалось распарсить данные WARP из wgcf-profile.conf"

    cp wgcf-profile.conf /etc/mihomo/wgcf-profile.conf
    cd /root
    success "WARP настроен: IP=$WARP_IP"

    # Удаляем старый warp из proxies если был
    sed '/^# --- warp ---$/,/^# --- \/warp ---$/d' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml

    # Инжектируем warp как элемент в общий proxies блок
    cat > /tmp/warp_proxy.yaml << WARPEOF
# --- warp ---
  - name: warp-wg
    type: wireguard
    private-key: "$WARP_PRIVATE_KEY"
    server: engage.cloudflareclient.com
    port: 2408
    ip: $WARP_IP
    dns: $WARP_DNS
    public-key: "$WARP_PUBLIC_KEY"
    allowed-ips: ['0.0.0.0/0', '::/0']
    udp: true
    mtu: 1280
# --- /warp ---
WARPEOF

    awk '
        /^# --- proxies ---/{
            print
            while ((getline line < "/tmp/warp_proxy.yaml") > 0) print line
            next
        }
        {print}
    ' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
    rm /tmp/warp_proxy.yaml

    sed -i '/^      - DIRECT$/i\      - warp-wg' /etc/mihomo/config.yaml
    success "WARP добавлен в группу outbound"

    sed -i '/^WARP IP:/d; /^WARP Public key:/d' /etc/mihomo/client-config.txt
    sed -i "/^Short ID:/a WARP IP:          $WARP_IP\nWARP Public key:  $WARP_PUBLIC_KEY" \
        /etc/mihomo/client-config.txt

    info "Перезапускаю Mihomo..."
    systemctl restart mihomo &>/dev/null
    sleep 4

    if systemctl is-active --quiet mihomo; then
        success "Mihomo перезапущен с WARP"
    else
        warn "Mihomo не запустился. Лог:"
        journalctl -u mihomo -n 20 --no-pager
    fi

    echo ""
    success_box "WARP настроен!"
    echo ""
    echo -e "  WARP IP:         ${CYAN}$WARP_IP${NC}"
    echo -e "  WARP Public key: ${CYAN}$WARP_PUBLIC_KEY${NC}"
    echo -e "  Профиль:         ${CYAN}/etc/mihomo/wgcf-profile.conf${NC}"
    echo ""
}

uninstall_warp() {
    echo ""

    if ! grep -q '# --- warp ---' /etc/mihomo/config.yaml 2>/dev/null; then
        warn "WARP не настроен."
        return
    fi

    warn "Будет удалён WARP из конфига Mihomo и файлы wgcf."
    confirm_yn "Вы уверены?" || { info "Отменено."; return; }

    awk '
        /^# --- warp ---/{print; skip=1; next}
        skip && /^# --- \/warp ---/{skip=0}
        {print}
    ' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
    success "WARP proxy удалён из config.yaml"

    sed -i '/^      - warp-wg$/d' /etc/mihomo/config.yaml
    success "warp-wg удалён из группы outbound"

    sed -i '/^WARP IP:/d; /^WARP Public key:/d' /etc/mihomo/client-config.txt

    rm -rf /root/wgcf
    rm -f /etc/mihomo/wgcf-profile.conf
    success "Файлы wgcf удалены"

    info "Перезапускаю Mihomo..."
    systemctl restart mihomo &>/dev/null
    sleep 3

    if systemctl is-active --quiet mihomo; then
        success "Mihomo перезапущен без WARP"
    else
        warn "Mihomo не запустился. Лог:"
        journalctl -u mihomo -n 20 --no-pager
    fi
    echo ""
}

update_warp() {
    echo ""

    if [[ ! -f /etc/mihomo/config.yaml ]]; then
        warn "Mihomo не установлен. Сначала выполните установку (пункт 1)."
        return
    fi

    if ! grep -q '# --- warp ---' /etc/mihomo/config.yaml; then
        warn "WARP не настроен. Сначала выполните установку WARP (пункт 4 → 1)."
        return
    fi

    WGCF_DIR="/root/wgcf"
    if [[ ! -f "$WGCF_DIR/wgcf" ]] || ! "$WGCF_DIR/wgcf" --version > /dev/null 2>&1; then
        rm -f "$WGCF_DIR/wgcf"
        info "Определяю последнюю версию wgcf..."
        local WGCF_VERSION wgcf_arch
        WGCF_VERSION=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest \
            | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v')
        [[ -z "$WGCF_VERSION" ]] && error "Не удалось получить версию wgcf с GitHub."
        case "$(uname -m)" in
            aarch64|arm64) wgcf_arch="arm64" ;;
            armv7l|armv7)  wgcf_arch="armv7" ;;
            *)             wgcf_arch="amd64" ;;
        esac
        info "wgcf не найден, скачиваю v${WGCF_VERSION} (${wgcf_arch})..."
        mkdir -p "$WGCF_DIR"
        curl -sLo "$WGCF_DIR/wgcf" \
            "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${wgcf_arch}" \
            || { rm -f "$WGCF_DIR/wgcf"; error "Не удалось скачать wgcf"; }
        chmod +x "$WGCF_DIR/wgcf"
        success "wgcf скачан"
    fi

    echo ""
    read -rp "WARP+ лицензионный ключ (Enter = бесплатный WARP): " NEW_WARP_LICENSE
    echo ""

    cd "$WGCF_DIR"

    if [[ -f "$WGCF_DIR/wgcf-account.toml" ]]; then
        info "Существующий аккаунт WARP найден"
        if [[ -n "$NEW_WARP_LICENSE" ]]; then
            info "Применяю WARP+ лицензионный ключ..."
            ./wgcf update --license-key "$NEW_WARP_LICENSE" || warn "Ключ не применился — продолжаю с текущим аккаунтом"
        fi
    else
        info "Регистрирую новый аккаунт WARP..."
        printf 'y\n' | ./wgcf register || error "Ошибка регистрации WARP"
        if [[ -n "$NEW_WARP_LICENSE" ]]; then
            info "Применяю WARP+ лицензионный ключ..."
            ./wgcf update --license-key "$NEW_WARP_LICENSE" || warn "Ключ не применился — продолжаю с бесплатным WARP"
        fi
    fi

    info "Генерирую новый WireGuard конфиг..."
    ./wgcf generate

    NEW_PRIVATE_KEY=$(grep 'PrivateKey' wgcf-profile.conf | awk '{print $3}')
    NEW_WARP_IP=$(grep 'Address' wgcf-profile.conf | awk '{print $3}' | cut -d'/' -f1 | cut -d',' -f1)
    NEW_PUBLIC_KEY=$(grep 'PublicKey' wgcf-profile.conf | awk '{print $3}')

    if [[ -z "$NEW_PRIVATE_KEY" || -z "$NEW_WARP_IP" || -z "$NEW_PUBLIC_KEY" ]]; then
        error "Не удалось распарсить данные WARP из wgcf-profile.conf"
    fi

    info "Новый WARP IP:         $NEW_WARP_IP"
    info "Новый WARP Public key: $NEW_PUBLIC_KEY"

    sed -i "s|^    private-key: .*|    private-key: \"$NEW_PRIVATE_KEY\"|" /etc/mihomo/config.yaml
    sed -i "s|^    ip: .*|    ip: $NEW_WARP_IP|"                           /etc/mihomo/config.yaml
    sed -i "s|^    public-key: .*|    public-key: \"$NEW_PUBLIC_KEY\"|"    /etc/mihomo/config.yaml

    cp wgcf-profile.conf /etc/mihomo/wgcf-profile.conf
    cd /root

    info "Перезапускаю Mihomo..."
    systemctl restart mihomo &>/dev/null
    sleep 3

    if systemctl is-active --quiet mihomo; then
        success "Mihomo перезапущен с новым WARP конфигом"
    else
        warn "Mihomo не запустился. Лог:"
        journalctl -u mihomo -n 20 --no-pager
    fi

    echo ""
    echo -e "  WARP IP:         ${CYAN}$NEW_WARP_IP${NC}"
    echo -e "  WARP Public key: ${CYAN}$NEW_PUBLIC_KEY${NC}"
    echo -e "  Профиль:         ${CYAN}/etc/mihomo/wgcf-profile.conf${NC}"
    echo ""
}
