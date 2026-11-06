#!/bin/bash
# ─── Удаление всего установленного ──────────────────────────────────────────

_uninstall_prepare_targets() {
    UNINSTALL_SSH_PORT=$(awk '/^Port /{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
    UNINSTALL_SSH_PORT="${UNINSTALL_SSH_PORT:-22}"
    UNINSTALL_PASSWORD_DISABLED=false
    if grep -Eq '^[[:space:]]*PasswordAuthentication[[:space:]]+no([[:space:]]|$)' /etc/ssh/sshd_config 2>/dev/null; then
        UNINSTALL_PASSWORD_DISABLED=true
    fi
    UNINSTALL_REALITY_SITE=""
    UNINSTALL_TELEGRAM_CERT=""
    UNINSTALL_TELEGRAM_WEBROOT=""
    UNINSTALL_TELEGRAM_AVAILABLE=""
    UNINSTALL_TELEGRAM_ENABLED=""
    local reality_site=""
    if declare -F _load_reality_conf >/dev/null; then
        reality_site=$( _load_reality_conf && [[ "${HAS_SITE:-false}" == true ]] && printf '%s' "$SITE_NAME" ) || reality_site=""
        [[ -z "$reality_site" ]] || _cert_identity_valid "$reality_site" || return 1
    fi
    if [[ -z "$reality_site" ]]; then
        reality_site=$(grep -r --exclude='essence-acme-*' 'server_name' /etc/nginx/sites-available/ 2>/dev/null \
            | grep -v '#' | awk '{print $2}' | tr -d ';' | head -1)
        [[ -z "$reality_site" ]] || _cert_identity_valid "$reality_site" || return 1
    fi
    UNINSTALL_REALITY_SITE="$reality_site"

    # Сохраняем только проверенные пути WEB до удаления его состояния.
    local telegram_cert="" telegram_webroot="" telegram_available="" telegram_enabled=""
    if [[ -f "${TPROXY_CONF:-/etc/tproxy-server/essence.conf}" ]] &&
       _telegram_proxy_load_conf && [[ "$TELEGRAM_WEB_ENABLED" == true ]]; then
        telegram_cert="${TPROXY_CERT_DIR:-/etc/nginx/ssl}/$TELEGRAM_WEB_HOSTNAME"
        telegram_webroot="${TPROXY_WEBROOT_BASE:-/var/www}/$TELEGRAM_WEB_HOSTNAME"
        telegram_available="${TPROXY_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
        telegram_enabled="${TPROXY_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
        local saved_path
        for saved_path in "$telegram_cert" "$telegram_webroot" "$telegram_available" "$telegram_enabled"; do
            _cert_safe_path "$saved_path" || {
                warn "Небезопасный путь Web Proxy; удаление отменено."
                return 1
            }
        done
    fi
    UNINSTALL_TELEGRAM_CERT="$telegram_cert"
    UNINSTALL_TELEGRAM_WEBROOT="$telegram_webroot"
    UNINSTALL_TELEGRAM_AVAILABLE="$telegram_available"
    UNINSTALL_TELEGRAM_ENABLED="$telegram_enabled"
    return 0
}

uninstall() {
    _uninstall_prepare_targets || return 1
    local restore=false final_port="$UNINSTALL_SSH_PORT" firewall_line ssh_line
    if [[ "$UNINSTALL_SSH_PORT" != 22 || "$UNINSTALL_PASSWORD_DISABLED" == true ]]; then
        MENU_SELECT_CONTEXT=("Текущий SSH-порт: $UNINSTALL_SSH_PORT")
        menu_select "SSH после удаления" "Выберите действие" \
            "Сохранить текущие настройки SSH" \
            "Вернуть порт 22 и включить вход по паролю" || return 0
        if [[ "$MENU_SELECT_INDEX" == 2 ]]; then
            restore=true
            final_port=22
        fi
    fi
    if [[ "$final_port" != 22 ]]; then
        firewall_line="UFW останется включён: открыт только SSH TCP/$final_port."
    else
        firewall_line="UFW будет отключён."
    fi
    ssh_line="SSH: порт $final_port; текущие настройки входа сохраняются."
    [[ "$restore" == false ]] || ssh_line="SSH: порт 22; вход по паролю будет включён."
    review_frame "Удаление установленных компонентов" \
        "Mihomo: бинарь, служба, конфиг и клиентские записи." \
        "AmneziaWG: служба, конфиг сервера, ключи и все клиенты с ключами." \
        "WARP: /root/wgcf и профиль /etc/mihomo/wgcf-profile.conf." \
        "Сайты, конфиги nginx Essence и webroot; домен: ${UNINSTALL_REALITY_SITE:-не найден}." \
        "Сертификаты: /etc/nginx/ssl целиком." \
        "Хостинг подписок и Telegram Proxy; все ссылки перестанут работать." \
        "acme.sh и /etc/sysctl.d/99-vpn-speedup.conf; IPv6 будет восстановлен." \
        "Пакеты nginx и AmneziaWG не удаляются." \
        "Правила UFW будут сброшены." \
        "$ssh_line" \
        "$firewall_line"
    confirm_yn "Удалить перечисленные компоненты?" N || return 0
    local _uninstall_prepared=true
    _uninstall_components "$restore"
}

_uninstall_components() {
    local restore="${1:-}"
    [[ "$restore" == true || "$restore" == false ]] || return 2
    [[ "${_uninstall_prepared:-false}" == true ]] || _uninstall_prepare_targets || return 1
    local reality_site="$UNINSTALL_REALITY_SITE"
    local telegram_cert="$UNINSTALL_TELEGRAM_CERT" telegram_webroot="$UNINSTALL_TELEGRAM_WEBROOT"
    local telegram_available="$UNINSTALL_TELEGRAM_AVAILABLE" telegram_enabled="$UNINSTALL_TELEGRAM_ENABLED"
    local _ssh_port="$UNINSTALL_SSH_PORT"

    # Shared Telegram backend is removed before Nginx/certificate cleanup.
    if [[ -f "${TPROXY_CONF:-/etc/tproxy-server/essence.conf}" ||
          -e "${TPROXY_ENV_FILE:-/etc/mtproxy/mtproxy.env}" ||
          -e "${TPROXY_RELAY_SOURCE_PATH:-/opt/tproxy-server-source}" ||
          -e "${TPROXY_MTPROXY_SOURCE_DIR:-/opt/MTProxy}" ]]; then
        local telegram_rc
        if TPROXY_INTERNAL_CALL=true telegram_proxy_remove_all --force; then
            telegram_rc=0
        else
            telegram_rc=$?
        fi
        case "$telegram_rc" in
            0|3) ;;
            *)
                warn "Не удалось удалить Telegram Proxy. Остальные компоненты не удалялись."
                return 1
                ;;
        esac
    fi

    if [[ -f "${SUB_CONF:-/etc/mihomo/subscription.conf}" ]]; then
        remove_subscription || return 1
    fi

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
    if [[ -f /etc/systemd/system/mihomo.service ]] || systemctl is-active --quiet mihomo 2>/dev/null; then
        systemctl stop mihomo 2>/dev/null || return 1
        systemctl disable mihomo 2>/dev/null || return 1
    fi
    rm -f /etc/systemd/system/mihomo.service /usr/local/bin/mihomo || return 1
    rm -rf /etc/mihomo || return 1
    systemctl daemon-reload || return 1
    success "Mihomo удалён"

    # AmneziaWG
    if [[ -f /etc/amnezia/amneziawg/awg0.conf ]] || systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        info "Удаляю AmneziaWG..."
        local awg_port_u
        awg_port_u=$(grep 'ListenPort' /etc/amnezia/amneziawg/awg0.conf 2>/dev/null | awk '{print $3}')
        awg-quick down awg0 2>/dev/null || true
        systemctl stop awg-quick@awg0 2>/dev/null || return 1
        systemctl disable awg-quick@awg0 2>/dev/null || return 1
        rm -rf /etc/amnezia /etc/mihomo/amnezia || return 1
        if [[ -n "$awg_port_u" ]]; then
            ufw delete allow "${awg_port_u}/udp" > /dev/null 2>&1 || true
            ufw delete allow "${awg_port_u}/tcp" > /dev/null 2>&1 || true
        fi
        success "AmneziaWG удалён"
    fi

    # wgcf
    info "Удаляю wgcf..."
    rm -rf /root/wgcf || return 1
    success "wgcf удалён"


    # Nginx конфиг и сайт
    info "Удаляю Nginx конфиг и сайт-заглушку..."
    INSTALLED_DOMAIN="$reality_site"
    if [[ -n "$INSTALLED_DOMAIN" ]]; then
        rm -f /etc/nginx/sites-enabled/"$INSTALLED_DOMAIN" /etc/nginx/sites-available/"$INSTALLED_DOMAIN" || return 1
        rm -rf /var/www/"$INSTALLED_DOMAIN" || return 1
        info "Удалено: $INSTALLED_DOMAIN"
    else
        warn "Домен не найден в nginx конфигах — пропускаю"
    fi
    # Удаляем только помеченные общие HTTP-01 routes.
    local challenge_dir challenge_site challenge_name
    for challenge_dir in /etc/nginx/sites-available "$telegram_available"; do
        [[ -n "$challenge_dir" ]] || continue
        for challenge_site in "$challenge_dir"/essence-acme-*; do
            [[ -f "$challenge_site" ]] || continue
            grep -qx '# Essence ACME challenge' "$challenge_site" || continue
            challenge_name="${challenge_site##*/}"
            rm -f "$challenge_site" "/etc/nginx/sites-enabled/$challenge_name" || return 1
            if [[ -n "$telegram_enabled" ]]; then
                rm -f "$telegram_enabled/$challenge_name" || return 1
            fi
        done
    done
    # Удаляем stream блок из nginx.conf
    if grep -q '^stream {' /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/^stream {/,/^}/d' /etc/nginx/nginx.conf || return 1
        info "Stream блок удалён из nginx.conf"
    fi
    if [[ -f /etc/nginx/nginx.conf ]]; then
        systemctl restart nginx 2>/dev/null || return 1
    fi
    success "Nginx конфиг и сайт удалены"

    # Сертификаты
    info "Удаляю сертификаты..."
    rm -rf /etc/nginx/ssl || return 1
    [[ -z "$telegram_cert" ]] || rm -rf "$telegram_cert" || return 1
    [[ -z "$telegram_webroot" ]] || rm -rf "$telegram_webroot" || return 1
    success "Сертификаты удалены"

    # acme.sh
    info "Удаляю acme.sh..."
    if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
        "$HOME/.acme.sh/acme.sh" --uninstall 2>/dev/null || return 1
    fi
    rm -rf "$HOME/.acme.sh" || return 1
    success "acme.sh удалён"

    # sysctl
    info "Удаляю настройки sysctl..."
    if [[ -f /etc/sysctl.d/99-vpn-speedup.conf ]]; then
        rm -f /etc/sysctl.d/99-vpn-speedup.conf || return 1
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 > /dev/null 2>&1 || return 1
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 > /dev/null 2>&1 || return 1
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 > /dev/null 2>&1 || return 1
        sysctl --system > /dev/null 2>&1 || return 1
        success "Настройки sysctl удалены, IPv6 восстановлен"
    else
        info "Файл sysctl не найден — пропускаю"
    fi

    # SSH hardening
    if [[ "$restore" == true ]]; then
        if ! sed -i \
            -e '/^[[:space:]#]*Port[[:space:]]/d' \
            -e '/^[[:space:]#]*PasswordAuthentication[[:space:]]/d' \
            -e '/^[[:space:]#]*ChallengeResponseAuthentication[[:space:]]/d' /etc/ssh/sshd_config ||
           ! printf '\nPort 22\nPasswordAuthentication yes\nChallengeResponseAuthentication yes\n' >> /etc/ssh/sshd_config ||
           ! systemctl daemon-reload 2>/dev/null ||
           ! { systemctl restart ssh.socket 2>/dev/null || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; }; then
            warn "Не удалось применить настройки SSH. Firewall не изменён."
            return 1
        fi
        _ssh_port=22
        success "SSH вернён на порт 22, вход по паролю включён"
    fi

    # Firewall
    info "Сбрасываю правила firewall..."
    ufw --force reset > /dev/null || return 1
    if [[ "$_ssh_port" != "22" ]]; then
        ufw default deny incoming > /dev/null || return 1
        ufw default allow outgoing > /dev/null || return 1
        ufw allow "${_ssh_port}/tcp" > /dev/null 2>&1 || return 1
        ufw --force enable > /dev/null || return 1
        success "Firewall сброшен, SSH-порт ${_ssh_port} открыт."
    else
        ufw --force disable > /dev/null || return 1
        success "Firewall отключён — все порты открыты."
    fi

    echo ""
    success "Всё удалено."
    echo ""
    return 0
}
