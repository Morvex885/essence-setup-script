#!/bin/bash
# ─── Subscription Hosting: HTTPS-эндпоинт для раздачи клиентских конфигов ────

# cert.sh подключается из setup-essence.sh

SUB_CONF="/etc/mihomo/subscription.conf"

_load_sub_conf() {
    [[ -f "$SUB_CONF" ]] || return 1
    source "$SUB_CONF"
    [[ -n "$SUB_HOSTNAME" && -n "$SUB_PORT" && -n "$SUB_DIR" ]] || return 1
}

_check_sub() {
    if ! _load_sub_conf; then
        warn "Subscription hosting не настроен."
        return 1
    fi
}

_detect_reality_mode() {
    local conf="/etc/mihomo/reality.conf"
    [[ -f "$conf" ]] || return 1
    source "$conf"
    if [[ "$REALITY_DEST" == "127.0.0.1:8443" ]]; then
        echo "self-steal"
    elif grep -q '^stream {' /etc/nginx/nginx.conf 2>/dev/null; then
        echo "sni"
    else
        echo "bare"
    fi
}

_detect_site_name() {
    local dir
    for dir in /etc/nginx/ssl/*/; do
        [[ -f "${dir}fullchain.pem" ]] && basename "$dir" && return 0
    done
    return 1
}

_nginx_h2_directives() {
    local _nginx_ver
    _nginx_ver=$(nginx -v 2>&1 | grep -oP '[\d.]+')
    if dpkg --compare-versions "$_nginx_ver" ge "1.25.1" 2>/dev/null; then
        LISTEN_H2_FLAG="ssl;"
        HTTP2_DIRECTIVE=$'\n    http2 on;'
    else
        LISTEN_H2_FLAG="ssl http2;"
        HTTP2_DIRECTIVE=""
    fi
}

# ─── Установка ──────────────────────────────────────────────────────────────

setup_subscription() {
    _check_base || return

    if _load_sub_conf; then
        warn "Subscription hosting уже настроен (${SUB_HOSTNAME}:${SUB_PORT})."
        confirm_yn "Перенастроить?" || return
        remove_subscription
    fi

    if ! _load_reality_conf; then
        error "Reality не настроен. Сначала настройте VLESS Reality с сайтом-заглушкой."
    fi

    local reality_mode
    reality_mode=$(_detect_reality_mode)
    if [[ "$reality_mode" == "bare" ]]; then
        error "Reality настроен без сайта (SNI bare). Перенастройте Reality с доменом или IP-сертификатом."
    fi

    local vless_site
    vless_site=$(_detect_site_name) || error "Не найден TLS-сертификат. Перенастройте Reality."

    local SERVER_IP
    SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me \
        || curl -4 -s --max-time 5 icanhazip.com \
        || curl -4 -s --max-time 5 api4.ipify.org)
    [[ -z "$SERVER_IP" ]] && error "Не удалось определить внешний IP."

    # ─── Домен подписки (всегда отдельный) ───────────────────────────────────
    echo ""
    info "Домен VLESS-сайта: $vless_site"
    echo ""
    read -rp "Введите домен для подписок (например subs.example.com): " SUB_HOSTNAME
    [[ -z "$SUB_HOSTNAME" ]] && { warn "Домен не может быть пустым"; return; }

    if [[ "$SUB_HOSTNAME" == "$vless_site" ]]; then
        warn "Домен подписки должен отличаться от домена VLESS ($vless_site)."
        return
    fi

    echo ""
    info "Проверяю DNS для $SUB_HOSTNAME..."
    local SUB_DOMAIN_IP
    SUB_DOMAIN_IP=$(getent hosts "$SUB_HOSTNAME" 2>/dev/null | awk '{print $1}' | head -1)
    info "IP сервера: $SERVER_IP"
    info "IP домена:  $SUB_DOMAIN_IP"
    if [[ "$SERVER_IP" != "$SUB_DOMAIN_IP" ]]; then
        warn "IP сервера ($SERVER_IP) и домена ($SUB_DOMAIN_IP) не совпадают. Настройте A-запись."
        return
    fi

    # ─── Порт ────────────────────────────────────────────────────────────────
    echo ""
    echo -e "  Порт для подписок:"
    echo -e "  ${GREEN}1)${NC} 443 (через существующий nginx)"
    echo -e "  ${GREEN}2)${NC} Свой порт ${DIM}[default: 2096]${NC}"
    echo ""
    read -rp "Выберите [1]: " PORT_CHOICE
    PORT_CHOICE="${PORT_CHOICE:-1}"

    local SUB_PORT SUB_LISTEN SUB_MODE

    if [[ "$PORT_CHOICE" == "1" ]]; then
        SUB_PORT=443
        if [[ "$reality_mode" == "self-steal" ]]; then
            SUB_LISTEN="127.0.0.1:8443"
            SUB_MODE="self-steal"
        else
            SUB_LISTEN="127.0.0.1:8445"
            SUB_MODE="sni"
        fi
    elif [[ "$PORT_CHOICE" == "2" ]]; then
        read -rp "Введите порт [2096]: " SUB_PORT
        SUB_PORT="${SUB_PORT:-2096}"
        SUB_LISTEN="0.0.0.0:${SUB_PORT}"
        SUB_MODE="standalone"
    else
        warn "Неверный выбор."; return
    fi

    local SUB_BASE_URL="https://${SUB_HOSTNAME}:${SUB_PORT}"
    [[ "$SUB_PORT" == "443" ]] && SUB_BASE_URL="https://${SUB_HOSTNAME}"
    local SUB_DIR="/var/lib/essence-sub"

    # ─── Сводка ──────────────────────────────────────────────────────────────
    echo ""
    info "Домен:  $SUB_HOSTNAME"
    info "Порт:   $SUB_PORT"
    info "Режим:  $SUB_MODE"
    info "URL:    ${SUB_BASE_URL}/sub/<token>"
    echo ""
    confirm_yn "Всё верно?" || { info "Отменено."; return; }

    local TOTAL_STEPS=4 STEP=0

    # ─── Шаг: Сертификат ─────────────────────────────────────────────────────
    STEP=$((STEP + 1))
    echo ""
    info "Шаг $STEP/$TOTAL_STEPS: Получение SSL сертификата для $SUB_HOSTNAME..."

    DEFAULT_EMAIL="user$(openssl rand -hex 4)@$(openssl rand -hex 3).com"
    read -rp "Email для acme.sh [Enter = $DEFAULT_EMAIL]: " SUB_EMAIL
    [[ -z "$SUB_EMAIL" ]] && SUB_EMAIL="$DEFAULT_EMAIL"

    ensure_acme_installed "$SUB_EMAIL"
    mkdir -p /var/www/"$SUB_HOSTNAME"

    # Временный HTTP-конфиг для acme.sh challenge
    cat > /etc/nginx/sites-available/essence-sub-http << SUBHTTPEOF
server {
    listen 80;
    server_name ${SUB_HOSTNAME};

    location /.well-known/acme-challenge/ {
        root /var/www/${SUB_HOSTNAME};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
SUBHTTPEOF
    ln -sf /etc/nginx/sites-available/essence-sub-http /etc/nginx/sites-enabled/essence-sub-http
    nginx -t || error "Nginx конфиг невалиден"
    systemctl reload nginx

    issue_cert "$SUB_HOSTNAME" "/var/www/$SUB_HOSTNAME" "false"
    install_cert "$SUB_HOSTNAME"

    # Убираем временный HTTP-конфиг
    rm -f /etc/nginx/sites-enabled/essence-sub-http /etc/nginx/sites-available/essence-sub-http

    success "Сертификат получен"

    # ─── Шаг: Директория и nginx ─────────────────────────────────────────────
    STEP=$((STEP + 1))
    echo ""
    info "Шаг $STEP/$TOTAL_STEPS: Настройка nginx..."

    mkdir -p "$SUB_DIR"

    # Определяем группу nginx-воркера (www-data на Debian/Ubuntu, nginx на RHEL/Alpine, http на Arch)
    local NGINX_GROUP
    NGINX_GROUP=$(ps -o group= -C nginx 2>/dev/null | sort -u | grep -v '^root$' | head -1)
    [[ -z "$NGINX_GROUP" ]] && NGINX_GROUP=$(awk '/^[[:space:]]*user[[:space:]]+/{print $2; exit}' /etc/nginx/nginx.conf 2>/dev/null | tr -d ';')
    NGINX_GROUP="${NGINX_GROUP:-www-data}"
    getent group "$NGINX_GROUP" >/dev/null 2>&1 || error "Группа nginx '$NGINX_GROUP' не найдена в системе"
    info "Nginx-группа: $NGINX_GROUP"

    chown "root:${NGINX_GROUP}" "$SUB_DIR"
    chmod 2750 "$SUB_DIR"

    # Defence-in-depth: default ACL — новые файлы унаследуют read даже если забыли chmod
    if command -v setfacl &>/dev/null; then
        setfacl -m    "g:${NGINX_GROUP}:rx" "$SUB_DIR" 2>/dev/null || true
        setfacl -d -m "g:${NGINX_GROUP}:r"  "$SUB_DIR" 2>/dev/null || true
    fi

    # Per-token nginx snippets dir (читается nginx master = root, поэтому 644 root:root)
    mkdir -p /etc/nginx/snippets/essence-sub
    chown root:root /etc/nginx/snippets/essence-sub
    chmod 755 /etc/nginx/snippets/essence-sub

    _nginx_h2_directives

    # limit_req_zone (добавляем если ещё нет)
    if ! grep -q 'zone=sub' /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/^http {/a\    limit_req_zone $binary_remote_addr zone=sub:1m rate=10r/m;' /etc/nginx/nginx.conf
    fi

    cat > /etc/nginx/sites-available/essence-sub << NGINXEOF
server {
    listen ${SUB_LISTEN} ${LISTEN_H2_FLAG}
    server_name ${SUB_HOSTNAME};${HTTP2_DIRECTIVE}

    ssl_certificate     /etc/nginx/ssl/${SUB_HOSTNAME}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${SUB_HOSTNAME}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;

    access_log off;
    add_header Cache-Control "no-store" always;
    add_header X-Content-Type-Options nosniff always;

    include /etc/nginx/snippets/essence-sub/sub-*.conf;

    location ~ "^/sub/([a-f0-9]{64})\$" {
        alias ${SUB_DIR}/\$1.yaml;
        default_type application/yaml;
        limit_req zone=sub burst=5 nodelay;
    }

    location / {
        return 444;
    }
}
NGINXEOF

    ln -sf /etc/nginx/sites-available/essence-sub /etc/nginx/sites-enabled/essence-sub

    # ─── Интеграция с 443 ────────────────────────────────────────────────────
    if [[ "$SUB_MODE" == "sni" ]]; then
        # Добавляем upstream и map-entry в stream-блок
        sed -i "/default.*mihomo;/i\\        ${SUB_HOSTNAME}   subscription;" /etc/nginx/nginx.conf
        sed -i "/upstream mihomo {/i\\    upstream subscription {\n        server 127.0.0.1:8445;\n    }" /etc/nginx/nginx.conf
    fi
    # self-steal: второй server на том же 127.0.0.1:8443 — nginx разруливает по SNI, доп. настройка не нужна

    if [[ "$SUB_MODE" == "standalone" ]]; then
        ufw allow "${SUB_PORT}/tcp" > /dev/null
        success "Порт $SUB_PORT открыт"
    fi

    nginx -t || error "Nginx конфиг невалиден"
    systemctl reload nginx || error "Nginx не перезагрузился"
    success "Nginx настроен"

    # ─── Шаг: Cleanup timer ──────────────────────────────────────────────────
    STEP=$((STEP + 1))
    echo ""
    info "Шаг $STEP/$TOTAL_STEPS: Настройка автоочистки expired подписок..."

    cat > /usr/local/bin/essence-sub-cleanup << 'CLEANUPEOF'
#!/bin/bash
source /etc/mihomo/subscription.conf 2>/dev/null || exit 0
LIST="${SUB_DIR}/expiry.list"
[[ -f "$LIST" ]] || exit 0
NOW=$(date +%s)
( flock 9
  while read -r token expires; do
    [[ -z "$token" ]] && continue
    if [[ "$expires" -le "$NOW" ]]; then
      rm -f "${SUB_DIR}/${token}.yaml"
    else
      printf '%s %s\n' "$token" "$expires"
    fi
  done < "$LIST" > "${LIST}.tmp"
  mv "${LIST}.tmp" "$LIST"
) 9>"${SUB_DIR}/.expiry.lock"
CLEANUPEOF
    chmod +x /usr/local/bin/essence-sub-cleanup

    cat > /etc/systemd/system/essence-sub-cleanup.service << EOF
[Unit]
Description=Cleanup expired subscription configs

[Service]
Type=oneshot
ExecStart=/usr/local/bin/essence-sub-cleanup
EOF

    cat > /etc/systemd/system/essence-sub-cleanup.timer << EOF
[Unit]
Description=Run subscription cleanup every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now essence-sub-cleanup.timer
    success "Автоочистка настроена (каждые 5 мин)"

    # ─── Шаг: Сохранение конфига ─────────────────────────────────────────────
    STEP=$((STEP + 1))
    echo ""
    info "Шаг $STEP/$TOTAL_STEPS: Сохранение конфигурации..."

    cat > "$SUB_CONF" << EOF
SUB_PORT=${SUB_PORT}
SUB_HOSTNAME=${SUB_HOSTNAME}
SUB_BASE_URL=${SUB_BASE_URL}
SUB_DIR=${SUB_DIR}
SUB_LISTEN=${SUB_LISTEN}
SUB_MODE=${SUB_MODE}
NGINX_GROUP=${NGINX_GROUP}
EOF

    success "Subscription hosting настроен!"
    echo ""
    info "Base URL: ${SUB_BASE_URL}/sub/<token>"
    info "Конфиги клиентов публикуются через remote-control → Subscriptions"
}

# ─── Удаление ───────────────────────────────────────────────────────────────

remove_subscription() {
    if ! _load_sub_conf; then
        warn "Subscription hosting не установлен."
        return
    fi

    info "Удаляю subscription hosting..."

    # nginx
    rm -f /etc/nginx/sites-enabled/essence-sub
    rm -f /etc/nginx/sites-available/essence-sub

    # stream-блок (SNI-режим)
    if [[ "$SUB_MODE" == "sni" ]]; then
        sed -i "/${SUB_HOSTNAME}.*subscription;/d" /etc/nginx/nginx.conf
        sed -i '/upstream subscription {/,/}/d' /etc/nginx/nginx.conf
    fi

    # limit_req_zone
    sed -i '/zone=sub/d' /etc/nginx/nginx.conf

    # ufw
    if [[ "$SUB_MODE" == "standalone" ]]; then
        ufw delete allow "${SUB_PORT}/tcp" > /dev/null 2>&1
    fi

    nginx -t && systemctl reload nginx 2>/dev/null

    # cleanup timer
    systemctl disable --now essence-sub-cleanup.timer 2>/dev/null
    rm -f /etc/systemd/system/essence-sub-cleanup.service
    rm -f /etc/systemd/system/essence-sub-cleanup.timer
    rm -f /usr/local/bin/essence-sub-cleanup
    systemctl daemon-reload

    # cert
    local ACME=~/.acme.sh/acme.sh
    if [[ -f "$ACME" ]]; then
        $ACME --remove -d "$SUB_HOSTNAME" 2>/dev/null
    fi
    rm -rf /etc/nginx/ssl/"$SUB_HOSTNAME"
    rm -rf /var/www/"$SUB_HOSTNAME"

    # данные и конфиг
    rm -rf "$SUB_DIR"
    rm -rf /etc/nginx/snippets/essence-sub
    rm -f "$SUB_CONF"

    success "Subscription hosting удалён"
}

# ─── Статус ─────────────────────────────────────────────────────────────────

subscription_status() {
    if ! _load_sub_conf; then
        warn "Subscription hosting не установлен."
        return
    fi

    echo ""
    info "Subscription hosting:"
    info "  URL:    ${SUB_BASE_URL}/sub/<token>"
    info "  Режим:  $SUB_MODE"
    info "  Порт:   $SUB_PORT"
    info "  Домен:  $SUB_HOSTNAME"

    # Кол-во файлов
    local count=0 snip_count=0
    if [[ -d "$SUB_DIR" ]]; then
        count=$(find "$SUB_DIR" -name '*.yaml' -type f 2>/dev/null | wc -l)
    fi
    if [[ -d /etc/nginx/snippets/essence-sub ]]; then
        snip_count=$(find /etc/nginx/snippets/essence-sub -name 'sub-*.conf' -type f 2>/dev/null | wc -l)
    fi
    info "  Подписок: $count (snippets: $snip_count)"

    # Cert validity
    local cert_file="/etc/nginx/ssl/${SUB_HOSTNAME}/fullchain.pem"
    if [[ -f "$cert_file" ]]; then
        local expiry
        expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
        if openssl x509 -checkend 0 -noout -in "$cert_file" 2>/dev/null; then
            success "  Сертификат: валиден до $expiry"
        else
            warn "  Сертификат: ИСТЁК ($expiry)"
        fi
    else
        warn "  Сертификат: не найден"
    fi

    # nginx
    if systemctl is-active --quiet nginx; then
        success "  Nginx: active"
    else
        warn "  Nginx: inactive"
    fi

    # timer
    if systemctl is-active --quiet essence-sub-cleanup.timer; then
        success "  Cleanup timer: active"
    else
        warn "  Cleanup timer: inactive"
    fi
}

# ─── Меню ───────────────────────────────────────────────────────────────────

subscription_menu() {
    while true; do
        echo ""
        echo -e "  ${CYAN}── Subscription Hosting ─────────────────────${NC}"
        echo ""
        if _load_sub_conf 2>/dev/null; then
            echo -e "  ${DIM}${SUB_BASE_URL}/sub/<token>${NC}"
            echo ""
            echo -e "  ${GREEN}1)${NC} Статус"
            echo -e "  ${RED}2)${NC} Удалить"
        else
            echo -e "  ${DIM}Не установлено${NC}"
            echo ""
            echo -e "  ${GREEN}1)${NC} Установить"
        fi
        echo -e "  ${NC}0)${NC} Назад"
        echo ""
        read -rp "  Выберите: " CHOICE

        case "$CHOICE" in
            1)
                if _load_sub_conf 2>/dev/null; then
                    subscription_status
                else
                    setup_subscription
                fi
                ;;
            2)
                if _load_sub_conf 2>/dev/null; then
                    confirm_yn "Удалить subscription hosting?" || continue
                    remove_subscription
                else
                    warn "Нечего удалять."
                fi
                ;;
            0) return ;;
            *) warn "Неверный выбор: $CHOICE" ;;
        esac
    done
}
