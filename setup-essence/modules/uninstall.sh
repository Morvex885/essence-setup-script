#!/bin/bash
# ─── Удаление всего установленного ──────────────────────────────────────────

uninstall() {
    echo ""
    warn "Будет удалено: mihomo, wgcf, nginx конфиг, сертификаты, сайт-заглушка, acme.sh, подписки, firewall правила."
    confirm_yn "Вы уверены?" || { info "Отменено."; return; }

    # VLESS транспорты — закрываем кастомные порты
    if [[ -f /etc/mihomo/config.yaml ]]; then
        local _xhttp_port _grpc_port
        _xhttp_port=$(awk '/# --- vless-xhttp ---/{f=1} f && /port:/{print $2; exit}' /etc/mihomo/config.yaml 2>/dev/null)
        _grpc_port=$(awk '/# --- vless-grpc ---/{f=1} f && /port:/{print $2; exit}' /etc/mihomo/config.yaml 2>/dev/null)
        [[ -n "$_xhttp_port" ]] && { ufw delete allow "${_xhttp_port}/tcp" > /dev/null 2>&1 || true; }
        [[ -n "$_grpc_port" ]] && { ufw delete allow "${_grpc_port}/tcp" > /dev/null 2>&1 || true; }
    fi

    # Mihomo
    info "Останавливаю и удаляю Mihomo..."
    systemctl stop mihomo 2>/dev/null || true
    systemctl disable mihomo 2>/dev/null || true
    rm -f /etc/systemd/system/mihomo.service
    rm -f /usr/local/bin/mihomo
    rm -rf /etc/mihomo
    systemctl daemon-reload
    success "Mihomo удалён"

    # AmneziaWG
    if [[ -f /etc/amnezia/amneziawg/awg0.conf ]] || systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        info "Удаляю AmneziaWG..."
        local awg_port_u
        awg_port_u=$(grep 'ListenPort' /etc/amnezia/amneziawg/awg0.conf 2>/dev/null | awk '{print $3}')
        awg-quick down awg0 2>/dev/null || true
        systemctl stop awg-quick@awg0 2>/dev/null || true
        systemctl disable awg-quick@awg0 2>/dev/null || true
        sed -i '/^tproxy-port:/d' /etc/mihomo/config.yaml 2>/dev/null || true
        rm -rf /etc/amnezia
        rm -rf /etc/mihomo/amnezia
        if [[ -n "$awg_port_u" ]]; then
            ufw delete allow "${awg_port_u}/udp" > /dev/null 2>&1
            ufw delete allow "${awg_port_u}/tcp" > /dev/null 2>&1
        fi
        success "AmneziaWG удалён"
    fi

    # wgcf
    info "Удаляю wgcf..."
    rm -rf /root/wgcf
    success "wgcf удалён"

    # Subscription hosting
    if [[ -f /etc/mihomo/subscription.conf ]]; then
        info "Удаляю subscription hosting..."
        source /etc/mihomo/subscription.conf
        rm -f /etc/nginx/sites-enabled/essence-sub
        rm -f /etc/nginx/sites-available/essence-sub
        if [[ "$SUB_MODE" == "sni" ]]; then
            sed -i "/${SUB_HOSTNAME}.*subscription;/d" /etc/nginx/nginx.conf 2>/dev/null
            sed -i '/upstream subscription {/,/}/d' /etc/nginx/nginx.conf 2>/dev/null
        fi
        sed -i '/zone=sub/d' /etc/nginx/nginx.conf 2>/dev/null
        [[ "$SUB_MODE" == "standalone" ]] && ufw delete allow "${SUB_PORT}/tcp" > /dev/null 2>&1
        systemctl disable --now essence-sub-cleanup.timer 2>/dev/null
        rm -f /etc/systemd/system/essence-sub-cleanup.service
        rm -f /etc/systemd/system/essence-sub-cleanup.timer
        rm -f /usr/local/bin/essence-sub-cleanup
        rm -rf "$SUB_DIR"
        rm -rf /etc/nginx/ssl/"$SUB_HOSTNAME"
        rm -rf /var/www/"$SUB_HOSTNAME"
        rm -f /etc/mihomo/subscription.conf
        systemctl daemon-reload
        success "Subscription hosting удалён"
    fi

    # Nginx конфиг и сайт
    info "Удаляю Nginx конфиг и сайт-заглушку..."
    INSTALLED_DOMAIN=$(grep -r 'server_name' /etc/nginx/sites-available/ 2>/dev/null \
        | grep -v '#' | awk '{print $2}' | tr -d ';' | head -1)
    if [[ -n "$INSTALLED_DOMAIN" ]]; then
        rm -f /etc/nginx/sites-enabled/"$INSTALLED_DOMAIN"
        rm -f /etc/nginx/sites-available/"$INSTALLED_DOMAIN"
        rm -rf /var/www/"$INSTALLED_DOMAIN"
        info "Удалено: $INSTALLED_DOMAIN"
    else
        warn "Домен не найден в nginx конфигах — пропускаю"
    fi
    # Удаляем stream блок из nginx.conf
    if grep -q '^stream {' /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/^stream {/,/^}/d' /etc/nginx/nginx.conf
        info "Stream блок удалён из nginx.conf"
    fi
    systemctl restart nginx 2>/dev/null || true
    success "Nginx конфиг и сайт удалены"

    # Сертификаты
    info "Удаляю сертификаты..."
    rm -rf /etc/nginx/ssl
    success "Сертификаты удалены"

    # acme.sh
    info "Удаляю acme.sh..."
    if [[ -f ~/.acme.sh/acme.sh ]]; then
        ~/.acme.sh/acme.sh --uninstall 2>/dev/null || true
        rm -rf ~/.acme.sh
    fi
    success "acme.sh удалён"

    # sysctl
    info "Удаляю настройки sysctl..."
    if [[ -f /etc/sysctl.d/99-vpn-speedup.conf ]]; then
        rm -f /etc/sysctl.d/99-vpn-speedup.conf
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 > /dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 > /dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 > /dev/null 2>&1 || true
        sysctl --system > /dev/null 2>&1 || true
        success "Настройки sysctl удалены, IPv6 восстановлен"
    else
        info "Файл sysctl не найден — пропускаю"
    fi

    # SSH hardening
    local _ssh_port
    _ssh_port=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    _ssh_port="${_ssh_port:-22}"
    if [[ "$_ssh_port" != "22" ]]; then
        echo ""
        warn "SSH настроен на порт ${_ssh_port} (не стандартный)."
        if confirm_yn "Сбросить SSH hardening (вернуть порт 22 и вход по паролю)?"; then
            sed -i 's/^Port .*/Port 22/' /etc/ssh/sshd_config
            sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
            sed -i 's/^ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config
            systemctl daemon-reload 2>/dev/null; systemctl restart ssh.socket 2>/dev/null || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
            _ssh_port="22"
            success "SSH вернён на порт 22, вход по паролю включён"
        fi
    fi

    # Firewall
    info "Сбрасываю правила firewall..."
    ufw --force reset > /dev/null
    if [[ "$_ssh_port" != "22" ]]; then
        ufw default deny incoming > /dev/null
        ufw default allow outgoing > /dev/null
        ufw allow "${_ssh_port}/tcp" > /dev/null 2>&1
        ufw --force enable > /dev/null
        success "Firewall сброшен, SSH-порт ${_ssh_port} открыт."
    else
        ufw --force disable > /dev/null
        success "Firewall отключён — все порты открыты."
    fi

    echo ""
    success "Всё удалено."
    echo ""
}
