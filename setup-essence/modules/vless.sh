#!/bin/bash
# ─── VLESS Reality ──────────────────────────────────────────────────────────────

# cert.sh подключается из setup-essence.sh

# ─── Загрузка / проверка reality.conf ────────────────────────────────────────

_load_reality_conf() {
    local conf="/etc/mihomo/reality.conf"
    [[ -f "$conf" ]] || return 1
    source "$conf"
    [[ -n "$UUID" && -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" && -n "$SHORT_ID" \
        && -n "$SNI_DOMAIN" && -n "$REALITY_DEST" ]] || return 1
}

_check_reality() {
    if ! _load_reality_conf; then
        warn "Reality не настроен. Сначала выберите пункт 'r' для настройки Reality."
        return 1
    fi
}

# ─── Настройка Reality ───────────────────────────────────────────────────────

setup_reality() {
    _check_base || return

    if [[ -f /etc/mihomo/reality.conf ]]; then
        warn "Reality уже настроен."
        confirm_yn "Перенастроить Reality?" || return
    fi

    # ─── Выбор режима Reality ─────────────────────────────────────────────────
    echo ""
    echo -e "  Режим Reality:"
    echo -e "  ${GREEN}1)${NC} Self-Steal ${DIM}(рекомендуется)${NC}"
    echo -e "  ${GREEN}2)${NC} SNI (указать домен-маскировку)"
    echo ""
    read -rp "Выберите [1]: " REALITY_MODE
    REALITY_MODE="${REALITY_MODE:-1}"
    if ! [[ "$REALITY_MODE" =~ ^[12]$ ]]; then
        warn "Неверный выбор."; return
    fi

    local DOMAIN="" EMAIL="" SNI_DOMAIN="" REALITY_DEST=""
    local HAS_SITE="true" SITE_NAME="" IS_IP_CERT="false"
    local MIHOMO_LISTEN="" MIHOMO_PORT="" CLIENT_SERVER=""
    local SERVER_IP=""
    local TOTAL_STEPS STEP=0

    if [[ "$REALITY_MODE" == "2" ]]; then
        # ─── SNI режим ───────────────────────────────────────────────────────
        REALITY_MODE="sni"
        echo ""
        read -rp "SNI домен (например www.google.com): " SNI_DOMAIN
        [[ -z "$SNI_DOMAIN" ]] && { warn "SNI домен не может быть пустым"; return; }

        SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me \
            || curl -4 -s --max-time 5 icanhazip.com \
            || curl -4 -s --max-time 5 api4.ipify.org)
        [[ -z "$SERVER_IP" ]] && { warn "Не удалось определить внешний IP сервера."; return; }

        echo ""
        if confirm_yn "Добавить свой домен с сайтом-заглушкой?"; then
            # Сценарий: SNI + свой домен
            echo ""
            read -rp "Введите домен (например example.com): " DOMAIN
            [[ -z "$DOMAIN" ]] && { warn "Домен не может быть пустым"; return; }

            DEFAULT_EMAIL="user$(openssl rand -hex 4)@$(openssl rand -hex 3).com"
            read -rp "Email для acme.sh [Enter = $DEFAULT_EMAIL]: " EMAIL
            [[ -z "$EMAIL" ]] && EMAIL="$DEFAULT_EMAIL"

            SITE_NAME="$DOMAIN"
            CLIENT_SERVER="$DOMAIN"

            echo ""
            info "Проверяю DNS для $DOMAIN..."
            DOMAIN_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
            info "IP сервера: $SERVER_IP"
            info "IP домена:  $DOMAIN_IP"
            if [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
                warn "IP сервера ($SERVER_IP) и домена ($DOMAIN_IP) не совпадают. Настройте A-запись домена."; return
            fi
        elif confirm_yn "Получить IP-сертификат для сайта-заглушки?"; then
            # Сценарий: SNI + IP-серт
            IS_IP_CERT="true"
            SITE_NAME="$SERVER_IP"
            CLIENT_SERVER="$SERVER_IP"

            DEFAULT_EMAIL="user$(openssl rand -hex 4)@$(openssl rand -hex 3).com"
            read -rp "Email для acme.sh [Enter = $DEFAULT_EMAIL]: " EMAIL
            [[ -z "$EMAIL" ]] && EMAIL="$DEFAULT_EMAIL"
        else
            # Сценарий: SNI bare
            HAS_SITE="false"
            CLIENT_SERVER="$SERVER_IP"
        fi

        REALITY_DEST="${SNI_DOMAIN}:443"
        if [[ "$HAS_SITE" == "true" ]]; then
            MIHOMO_LISTEN="127.0.0.1"
            MIHOMO_PORT="8444"
        else
            MIHOMO_LISTEN="0.0.0.0"
            MIHOMO_PORT="443"
        fi
    else
        # ─── Self-Steal режим ────────────────────────────────────────────────
        REALITY_MODE="self-steal"
        echo ""
        read -rp "Введите домен (например example.com): " DOMAIN
        [[ -z "$DOMAIN" ]] && { warn "Домен не может быть пустым"; return; }

        DEFAULT_EMAIL="user$(openssl rand -hex 4)@$(openssl rand -hex 3).com"
        read -rp "Email для acme.sh [Enter = $DEFAULT_EMAIL]: " EMAIL
        [[ -z "$EMAIL" ]] && EMAIL="$DEFAULT_EMAIL"

        SNI_DOMAIN="$DOMAIN"
        REALITY_DEST="127.0.0.1:8443"
        SITE_NAME="$DOMAIN"
        CLIENT_SERVER="$DOMAIN"
        MIHOMO_LISTEN="0.0.0.0"
        MIHOMO_PORT="443"

        echo ""
        info "Проверяю DNS для $DOMAIN..."
        SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me \
            || curl -4 -s --max-time 5 icanhazip.com \
            || curl -4 -s --max-time 5 api4.ipify.org)
        [[ -z "$SERVER_IP" ]] && { warn "Не удалось определить внешний IP сервера."; return; }
        DOMAIN_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
        info "IP сервера: $SERVER_IP"
        info "IP домена:  $DOMAIN_IP"
        if [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
            warn "IP сервера ($SERVER_IP) и домена ($DOMAIN_IP) не совпадают. Настройте A-запись домена."; return
        fi
    fi

    # ─── Сводка ──────────────────────────────────────────────────────────────
    echo ""
    if [[ "$REALITY_MODE" == "self-steal" ]]; then
        info "Режим:      Self-Steal"
        info "Домен:      $DOMAIN"
        info "Email:      $EMAIL"
    else
        info "Режим:      SNI"
        info "SNI домен:  $SNI_DOMAIN"
        if [[ "$HAS_SITE" == "true" ]]; then
            info "Сайт:       $SITE_NAME"
            info "Email:      $EMAIL"
            [[ "$IS_IP_CERT" == "true" ]] && info "Серт:       IP (shortlived, 6 дней)"
        else
            info "Сайт:       нет"
        fi
        info "IP сервера: $SERVER_IP"
    fi
    echo ""
    confirm_yn "Всё верно?" || { info "Отменено."; return; }

    # ─── Шаги: Nginx + сертификат (только если HAS_SITE) ─────────────────────
    if [[ "$HAS_SITE" == "true" ]]; then
        TOTAL_STEPS=7
    else
        TOTAL_STEPS=1
    fi

    if [[ "$HAS_SITE" == "true" ]]; then

        # ─── Шаг: Зависимости (nginx) ───────────────────────────────────────
        STEP=$((STEP + 1))
        echo ""
        info "Шаг $STEP/$TOTAL_STEPS: Установка nginx..."
        apt_wait
        DEBIAN_FRONTEND=noninteractive apt-get update -q
        if [[ "$REALITY_MODE" == "sni" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q nginx libnginx-mod-stream || error "Не удалось установить nginx"
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q nginx || error "Не удалось установить nginx"
        fi
        systemctl enable nginx
        success "Nginx установлен"

        # ─── Шаг: Сайт-заглушка ─────────────────────────────────────────────
        STEP=$((STEP + 1))
        echo ""
        info "Шаг $STEP/$TOTAL_STEPS: Создание сайта-заглушки..."
        mkdir -p /var/www/"$SITE_NAME"
        mkdir -p /etc/nginx/ssl/"$SITE_NAME"
        setup_fake_site "/var/www/$SITE_NAME"

        # ─── Шаг: Nginx HTTP (для acme.sh) ──────────────────────────────────
        STEP=$((STEP + 1))
        echo ""
        info "Шаг $STEP/$TOTAL_STEPS: Настройка Nginx (HTTP для acme.sh)..."
        rm -f /etc/nginx/sites-enabled/*

        cat > /etc/nginx/sites-available/"$SITE_NAME" << NGINXEOF
server {
    listen 80;
    server_name $SITE_NAME;

    location /.well-known/acme-challenge/ {
        root /var/www/$SITE_NAME;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINXEOF

        ln -sf /etc/nginx/sites-available/"$SITE_NAME" /etc/nginx/sites-enabled/"$SITE_NAME"
        nginx -t || error "Nginx конфиг невалиден"
        systemctl restart nginx || error "Nginx не запустился"
        sleep 1
        systemctl is-active --quiet nginx || error "Nginx не активен после запуска"
        success "Nginx запущен на порту 80"

        # ─── Шаг: acme.sh ───────────────────────────────────────────────────
        STEP=$((STEP + 1))
        echo ""
        info "Шаг $STEP/$TOTAL_STEPS: Установка acme.sh..."
        ensure_acme_installed "$EMAIL"
        success "acme.sh готов (CA: Let's Encrypt)"

        # ─── Шаг: Сертификат ────────────────────────────────────────────────
        STEP=$((STEP + 1))
        echo ""
        info "Шаг $STEP/$TOTAL_STEPS: Получение SSL сертификата для $SITE_NAME..."
        issue_cert "$SITE_NAME" "/var/www/$SITE_NAME" "$IS_IP_CERT"
        info "Закрываю порт 80..."
        ufw deny 80/tcp > /dev/null
        success "Порт 80 закрыт"

        install_cert "$SITE_NAME"
        success "Сертификат получен и установлен"

        # ─── Шаг: Nginx SSL ─────────────────────────────────────────────────
        STEP=$((STEP + 1))
        echo ""

        # HTTP/2: синтаксис зависит от версии nginx
        local _nginx_ver _listen_h2 _http2_directive
        _nginx_ver=$(nginx -v 2>&1 | grep -oP '[\d.]+')
        if dpkg --compare-versions "$_nginx_ver" ge "1.25.1" 2>/dev/null; then
            _listen_h2="listen 127.0.0.1:8443 ssl;"
            _http2_directive=$'\n    http2 on;'
        else
            _listen_h2="listen 127.0.0.1:8443 ssl http2;"
            _http2_directive=""
        fi

        if [[ "$REALITY_MODE" == "self-steal" ]]; then
            # Self-Steal: nginx SSL на 127.0.0.1:8443
            info "Шаг $STEP/$TOTAL_STEPS: Настройка Nginx SSL (self-steal на 127.0.0.1:8443)..."

            cat > /etc/nginx/sites-available/"$SITE_NAME" << NGINXEOF
server {
    listen 80;
    server_name $SITE_NAME;

    location /.well-known/acme-challenge/ {
        root /var/www/$SITE_NAME;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    $_listen_h2
    server_name $SITE_NAME;$_http2_directive

    ssl_certificate     /etc/nginx/ssl/$SITE_NAME/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$SITE_NAME/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;

    root /var/www/$SITE_NAME;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXEOF

        else
            # SNI + сайт: nginx stream (443 → 8443/8444) + HTTPS на 8443
            info "Шаг $STEP/$TOTAL_STEPS: Настройка Nginx (stream SNI-роутинг + HTTPS)..."

            cat > /etc/nginx/sites-available/"$SITE_NAME" << NGINXEOF
server {
    listen 80;
    server_name $SITE_NAME;

    location /.well-known/acme-challenge/ {
        root /var/www/$SITE_NAME;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    $_listen_h2
    server_name $SITE_NAME;$_http2_directive

    ssl_certificate     /etc/nginx/ssl/$SITE_NAME/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$SITE_NAME/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;

    root /var/www/$SITE_NAME;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXEOF

            # Удаляем старый stream блок и добавляем новый
            sed -i '/^stream {/,/^}/d' /etc/nginx/nginx.conf
            cat >> /etc/nginx/nginx.conf << STREAMEOF

stream {
    map \$ssl_preread_server_name \$backend {
        $SITE_NAME       site;
        default          mihomo;
    }
    upstream site {
        server 127.0.0.1:8443;
    }
    upstream mihomo {
        server 127.0.0.1:8444;
    }
    server {
        listen 443;
        listen [::]:443;
        proxy_pass \$backend;
        ssl_preread on;
    }
}
STREAMEOF
        fi

        nginx -t || error "Nginx конфиг невалиден"
        systemctl restart nginx || error "Nginx не запустился после настройки SSL"
        sleep 1

        local http_code
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" https://127.0.0.1:8443 -H "Host: $SITE_NAME")
        if [[ "$http_code" == "200" ]]; then
            success "Сайт-заглушка (127.0.0.1:8443) работает (HTTP $http_code)"
        else
            if [[ "$REALITY_MODE" == "self-steal" ]]; then
                error "Nginx на 8443 вернул HTTP $http_code — Reality не будет работать."
            else
                warn "Nginx на 8443 вернул HTTP $http_code"
            fi
        fi

    fi # HAS_SITE

    # ─── Шаг: Генерация ключей Reality ───────────────────────────────────────
    STEP=$((STEP + 1))
    echo ""
    info "Шаг $STEP/$TOTAL_STEPS: Генерация ключей Reality..."

    ufw allow 443/tcp > /dev/null 2>&1

    local TMPKEY
    TMPKEY=$(openssl genpkey -algorithm X25519 2>/dev/null)
    PRIVATE_KEY=$(printf '%s' "$TMPKEY" | openssl pkey -outform DER 2>/dev/null \
        | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
    PUBLIC_KEY=$(printf '%s' "$TMPKEY" | openssl pkey -pubout -outform DER 2>/dev/null \
        | tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
    UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    SHORT_ID=$(openssl rand -hex 8)

    if [[ -z "$PUBLIC_KEY" || -z "$PRIVATE_KEY" ]]; then
        error "Не удалось сгенерировать X25519 ключи через openssl"
    fi

    # Удаляем старый VLESS listener без маркеров (миграция со старого формата)
    if grep -q 'name: vless-reality' /etc/mihomo/config.yaml 2>/dev/null; then
        awk '
            /^  - name: vless-reality/{skip=1; next}
            skip && (/^  - name:/ || /^# ---/ || /^rule-providers:/ || /^$/){skip=0}
            !skip
        ' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
        mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
        info "Старый VLESS listener (без маркеров) удалён из config.yaml"
    fi

    # Удаляем старую секцию клиентского конфига
    if [[ -f /etc/mihomo/client-config.txt ]]; then
        sed -i '/^--- VLESS ---/,/^--- \/VLESS ---/d' /etc/mihomo/client-config.txt
    fi

    # Сохраняем reality.conf
    cat > /etc/mihomo/reality.conf << CONFEOF
MODE=$REALITY_MODE
DOMAIN=$DOMAIN
EMAIL=$EMAIL
SNI_DOMAIN=$SNI_DOMAIN
SERVER_IP=$SERVER_IP
UUID=$UUID
PUBLIC_KEY=$PUBLIC_KEY
PRIVATE_KEY=$PRIVATE_KEY
SHORT_ID=$SHORT_ID
CLIENT_SERVER=$CLIENT_SERVER
MIHOMO_LISTEN=$MIHOMO_LISTEN
MIHOMO_PORT=$MIHOMO_PORT
HAS_SITE=$HAS_SITE
SITE_NAME=$SITE_NAME
IS_IP_CERT=$IS_IP_CERT
REALITY_DEST=$REALITY_DEST
CONFEOF
    chmod 600 /etc/mihomo/reality.conf

    echo ""
    success "Reality настроен!"
    info "UUID:       $UUID"
    info "Public key: $PUBLIC_KEY"
    info "Short ID:   $SHORT_ID"
    echo ""
    info "Теперь добавьте транспорт: TCP, xHTTP или gRPC."
}

# ─── Вспомогательные функции ────────────────────────────────────────────────

_vless_port_input() {
    local default_port="$1"
    local port

    read -rp "Порт [Enter = $default_port]: " port
    [[ -z "$port" ]] && port="$default_port"

    while true; do
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            warn "Неверный порт '$port'. Введите число от 1 до 65535."
        elif ! is_port_free "$port"; then
            warn "Порт $port уже занят."
        else
            break
        fi
        read -rp "Новый порт: " port
        [[ -z "$port" ]] && { warn "Порт не указан"; return; }
    done

    VLESS_PORT="$port"
}

# ─── Добавить VLESS TCP ─────────────────────────────────────────────────────

_add_vless_tcp() {
    _check_base || return
    _check_reality || return

    if grep -q '# --- vless-tcp ---' /etc/mihomo/config.yaml 2>/dev/null; then
        warn "VLESS TCP уже установлен."
        confirm_yn "Переустановить?" || return
    fi

    _load_reality_conf

    local client_port=443

    info "Добавляю VLESS TCP..."

    # Удаляем старый блок если есть
    sed -i '/^# --- vless-tcp ---/,/^# --- \/vless-tcp ---/d' /etc/mihomo/config.yaml

    # Генерируем и вставляем listener перед rule-providers:
    local _listener_yaml
    _listener_yaml=$(_build_vless_tcp_listener_yaml \
        "VLESS TCP" "$MIHOMO_LISTEN" "$MIHOMO_PORT" \
        "user1" "$UUID" "$REALITY_DEST" "$PRIVATE_KEY" "$SHORT_ID" "$SNI_DOMAIN" "outbound")

    printf '%s\n' "# --- vless-tcp ---" "$_listener_yaml" "# --- /vless-tcp ---" > /tmp/_inject_tmp.yaml

    awk '/^rule-providers:/{
        while ((getline line < "/tmp/_inject_tmp.yaml") > 0) print line
        print ""
    }
    {print}' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
    rm -f /tmp/_inject_tmp.yaml

    # UFW
    ufw allow 443/tcp > /dev/null 2>&1

    # Перезапуск
    systemctl restart mihomo &>/dev/null
    sleep 3

    if systemctl is-active --quiet mihomo; then
        success "VLESS TCP добавлен"
    else
        warn "Mihomo не запустился. Лог:"
        journalctl -u mihomo -n 20 --no-pager
    fi

    # Клиентский конфиг
    if [[ -f /etc/mihomo/client-config.txt ]]; then
        sed -i '/^--- VLESS TCP ---/,/^--- \/VLESS TCP ---/d' /etc/mihomo/client-config.txt
    fi

    local _client_uri _client_yaml
    _client_uri=$(_build_vless_tcp_uri "$UUID" "$CLIENT_SERVER" "$client_port" "$SNI_DOMAIN" "$PUBLIC_KEY" "$SHORT_ID" "VLESS TCP")
    _client_yaml=$(_build_vless_tcp_client_yaml "VLESS TCP" "$CLIENT_SERVER" "$client_port" "$UUID" "$SNI_DOMAIN" "$PUBLIC_KEY" "$SHORT_ID")

    cat >> /etc/mihomo/client-config.txt << VLESSTCPEOF

--- VLESS TCP ---
Transport:    tcp
Server:       $CLIENT_SERVER
Port:         $client_port
SNI:          $SNI_DOMAIN
UUID:         $UUID
Public key:   $PUBLIC_KEY
Short ID:     $SHORT_ID

URI: $_client_uri

$_client_yaml
--- /VLESS TCP ---
VLESSTCPEOF

    echo ""
    echo -e "  Сервер: ${CYAN}$CLIENT_SERVER:$client_port${NC}"
    echo -e "  SNI:    ${CYAN}$SNI_DOMAIN${NC}"
    echo -e "  URI:    ${CYAN}${_client_uri}${NC}"
    echo ""
}

# ─── Добавить VLESS xHTTP ───────────────────────────────────────────────────

_add_xhttp_nginx_location() {
    local path="$1" port="$2"
    local nginx_file="/etc/nginx/sites-available/$SITE_NAME"

    [[ -f "$nginx_file" ]] || { warn "Nginx конфиг $nginx_file не найден"; return 1; }

    # Удаляем старый блок если есть
    sed -i '/# --- xhttp-nginx ---/,/# --- \/xhttp-nginx ---/d' "$nginx_file"

    # Вставляем location перед "location / {" в SSL server блоке (после listen.*8443)
    awk -v path="$path" -v port="$port" '
        /listen.*8443/{in_ssl=1}
        in_ssl && /location \/ \{/ && !done {
            print "    # --- xhttp-nginx ---"
            print "    location " path " {"
            print "        proxy_pass https://127.0.0.1:" port ";"
            print "        proxy_http_version 1.1;"
            print "        proxy_ssl_verify off;"
            print "        proxy_set_header Host \044host;"
            print "        proxy_set_header X-Forwarded-For \044proxy_add_x_forwarded_for;"
            print "        proxy_read_timeout 315s;"
            print "        proxy_send_timeout 300s;"
            print "        proxy_buffering off;"
            print "        client_max_body_size 0;"
            print "        client_body_timeout 300s;"
            print "    }"
            print "    # --- /xhttp-nginx ---"
            print ""
            done=1
        }
        {print}
    ' "$nginx_file" > /tmp/nginx_xhttp_tmp.conf
    mv /tmp/nginx_xhttp_tmp.conf "$nginx_file"

    nginx -t || { warn "Nginx конфиг невалиден после добавления xHTTP location"; return 1; }
    systemctl reload nginx
    success "Nginx location для xHTTP добавлен"
}

_remove_xhttp_nginx_location() {
    if ! _load_reality_conf 2>/dev/null; then return; fi
    local nginx_file="/etc/nginx/sites-available/$SITE_NAME"
    if [[ -f "$nginx_file" ]] && grep -q '# --- xhttp-nginx ---' "$nginx_file" 2>/dev/null; then
        sed -i '/# --- xhttp-nginx ---/,/# --- \/xhttp-nginx ---/d' "$nginx_file"
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
        info "Nginx location для xHTTP удалён"
    fi
}

_add_vless_xhttp() {
    _check_base || return
    _check_reality || return

    if grep -q '# --- vless-xhttp ---' /etc/mihomo/config.yaml 2>/dev/null; then
        warn "VLESS xHTTP уже установлен."
        confirm_yn "Переустановить?" || return
    fi

    _load_reality_conf

    local XHTTP_LISTEN XHTTP_PORT client_port xhttp_via_nginx=false
    local XHTTP_PATH="/$(openssl rand -hex 8)"

    echo ""
    echo -e "  Порт для xHTTP:"
    echo -e "  ${GREEN}1)${NC} 443 (Reality) — занимает порт, нельзя совместить с TCP"
    if [[ "$HAS_SITE" == "true" ]]; then
        echo -e "  ${GREEN}2)${NC} 443 (TLS, nginx) — совместно с TCP (нужен сайт-заглушка)"
    fi
    echo -e "  ${GREEN}3)${NC} Свой порт (Reality)"
    echo -e "  ${NC}0)${NC} Назад"
    echo ""
    read -rp "Выберите [1]: " PORT_CHOICE
    PORT_CHOICE="${PORT_CHOICE:-1}"

    case "$PORT_CHOICE" in
        1)
            if grep -q '# --- vless-tcp ---' /etc/mihomo/config.yaml 2>/dev/null; then
                warn "Порт 443 уже занят VLESS TCP. Используйте вариант 2 (через nginx) или 3 (другой порт)."; return
            fi
            if grep -q '# --- vless-grpc ---' /etc/mihomo/config.yaml 2>/dev/null; then
                local _gp
                _gp=$(awk '/# --- vless-grpc ---/{f=1} f && /port:/{print $2; exit}' /etc/mihomo/config.yaml)
                if [[ "$_gp" == "$MIHOMO_PORT" ]]; then
                    warn "Порт 443 уже занят VLESS gRPC."; return
                fi
            fi
            XHTTP_LISTEN="$MIHOMO_LISTEN"
            XHTTP_PORT="$MIHOMO_PORT"
            client_port=443
            ;;
        2)
            if [[ "$HAS_SITE" != "true" ]]; then
                warn "Вариант 'через nginx' доступен только в режиме с сайтом-заглушкой (self-steal или SNI+сайт)."; return
            fi
            xhttp_via_nginx=true
            XHTTP_LISTEN="127.0.0.1"
            XHTTP_PORT=8445
            if ! is_port_free 8445; then
                XHTTP_PORT=$(gen_free_port 20000 30000)
            fi
            client_port=443
            ;;
        3)
            local DEFAULT_PORT=$(gen_free_port 10000 65535)
            _vless_port_input "$DEFAULT_PORT"
            XHTTP_LISTEN="0.0.0.0"
            XHTTP_PORT="$VLESS_PORT"
            client_port="$XHTTP_PORT"
            ;;
        0) return ;;
        *)
            warn "Неверный выбор."; return
            ;;
    esac

    echo ""
    info "Порт:  $client_port"
    info "Path:  $XHTTP_PATH"
    if [[ "$xhttp_via_nginx" == "true" ]]; then
        info "Режим: через nginx reverse proxy (без Reality, обычный TLS)"
        info "Внутренний порт: 127.0.0.1:$XHTTP_PORT"
    fi
    echo ""
    confirm_yn "Всё верно?" || { info "Отменено."; return; }

    info "Добавляю VLESS xHTTP..."

    # Удаляем старый блок если есть
    sed -i '/^# --- vless-xhttp ---/,/^# --- \/vless-xhttp ---/d' /etc/mihomo/config.yaml

    local _listener_yaml
    if [[ "$xhttp_via_nginx" == "true" ]]; then
        # Симлинк на серты nginx (SAFE_PATHS в systemd unit разрешает /etc/nginx/ssl)
        mkdir -p /etc/mihomo/certs
        rm -rf /etc/mihomo/certs/xhttp
        ln -sf "/etc/nginx/ssl/$SITE_NAME" /etc/mihomo/certs/xhttp

        local _cert_dir="/etc/mihomo/certs/xhttp"
        _listener_yaml=$(_build_vless_xhttp_tls_listener_yaml \
            "VLESS xHTTP" "$XHTTP_LISTEN" "$XHTTP_PORT" \
            "user1" "$UUID" "$XHTTP_PATH" \
            "$_cert_dir/fullchain.pem" "$_cert_dir/privkey.pem" "outbound")

        # Добавляем nginx location
        _add_xhttp_nginx_location "$XHTTP_PATH" "$XHTTP_PORT"
    else
        _listener_yaml=$(_build_vless_xhttp_listener_yaml \
            "VLESS xHTTP" "$XHTTP_LISTEN" "$XHTTP_PORT" \
            "user1" "$UUID" "$XHTTP_PATH" \
            "$REALITY_DEST" "$PRIVATE_KEY" "$SHORT_ID" "$SNI_DOMAIN" "outbound")
    fi

    printf '%s\n' "# --- vless-xhttp ---" "$_listener_yaml" "# --- /vless-xhttp ---" > /tmp/_inject_tmp.yaml

    awk '/^rule-providers:/{
        while ((getline line < "/tmp/_inject_tmp.yaml") > 0) print line
        print ""
    }
    {print}' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
    rm -f /tmp/_inject_tmp.yaml

    # UFW (только для кастомных портов)
    if [[ "$client_port" != "443" ]]; then
        ufw allow "${client_port}/tcp" > /dev/null 2>&1
        success "Порт $client_port открыт"
    fi

    # Перезапуск
    systemctl restart mihomo &>/dev/null
    sleep 3

    if systemctl is-active --quiet mihomo; then
        success "VLESS xHTTP добавлен"
    else
        warn "Mihomo не запустился. Лог:"
        journalctl -u mihomo -n 20 --no-pager
    fi

    # Клиентский конфиг
    if [[ -f /etc/mihomo/client-config.txt ]]; then
        sed -i '/^--- VLESS xHTTP ---/,/^--- \/VLESS xHTTP ---/d' /etc/mihomo/client-config.txt
    fi

    local _client_uri _client_yaml _client_sni _transport_label
    if [[ "$xhttp_via_nginx" == "true" ]]; then
        _client_sni="$SITE_NAME"
        _transport_label="xhttp (через nginx, без Reality)"
        _client_uri=$(_build_vless_xhttp_uri "$UUID" "$CLIENT_SERVER" "$client_port" "$SITE_NAME" "$XHTTP_PATH" "" "" "VLESS xHTTP")
        _client_yaml=$(_build_vless_xhttp_client_yaml "VLESS xHTTP" "$CLIENT_SERVER" "$client_port" "$UUID" "$SITE_NAME" "$XHTTP_PATH")
    else
        _client_sni="$SNI_DOMAIN"
        _transport_label="xhttp"
        _client_uri=$(_build_vless_xhttp_uri "$UUID" "$CLIENT_SERVER" "$client_port" "$SNI_DOMAIN" "$XHTTP_PATH" "$PUBLIC_KEY" "$SHORT_ID" "VLESS xHTTP")
        _client_yaml=$(_build_vless_xhttp_client_yaml "VLESS xHTTP" "$CLIENT_SERVER" "$client_port" "$UUID" "$SNI_DOMAIN" "$XHTTP_PATH" "$PUBLIC_KEY" "$SHORT_ID")
    fi

    cat >> /etc/mihomo/client-config.txt << VLESSXHTTPEOF

--- VLESS xHTTP ---
Transport:    $_transport_label
Server:       $CLIENT_SERVER
Port:         $client_port
SNI:          $_client_sni
UUID:         $UUID
$(  [[ -n "$PUBLIC_KEY" && "$xhttp_via_nginx" != "true" ]] && printf "Public key:   %s\nShort ID:     %s\n" "$PUBLIC_KEY" "$SHORT_ID" )Path:         $XHTTP_PATH

URI: $_client_uri

$_client_yaml
--- /VLESS xHTTP ---
VLESSXHTTPEOF

    echo ""
    echo -e "  Сервер: ${CYAN}$CLIENT_SERVER:$client_port${NC}"
    if [[ "$xhttp_via_nginx" == "true" ]]; then
        echo -e "  SNI:    ${CYAN}$SITE_NAME${NC} (обычный TLS)"
    else
        echo -e "  SNI:    ${CYAN}$SNI_DOMAIN${NC} (Reality)"
    fi
    echo -e "  Path:   ${CYAN}$XHTTP_PATH${NC}"
    echo ""
}

# ─── Добавить VLESS gRPC ────────────────────────────────────────────────────

_add_vless_grpc() {
    _check_base || return
    _check_reality || return

    if grep -q '# --- vless-grpc ---' /etc/mihomo/config.yaml 2>/dev/null; then
        warn "VLESS gRPC уже установлен."
        confirm_yn "Переустановить?" || return
    fi

    _load_reality_conf

    local GRPC_LISTEN GRPC_PORT client_port
    local GRPC_SERVICE="grpc-$(openssl rand -hex 4)"

    echo ""
    echo -e "  Порт для gRPC:"
    echo -e "  ${GREEN}1)${NC} 443 (Reality) — занимает порт, нельзя совместить с TCP/xHTTP"
    echo -e "  ${GREEN}2)${NC} Свой порт (Reality)"
    echo -e "  ${NC}0)${NC} Назад"
    echo ""
    read -rp "Выберите [1]: " PORT_CHOICE
    PORT_CHOICE="${PORT_CHOICE:-1}"

    case "$PORT_CHOICE" in
        1)
            if grep -q '# --- vless-tcp ---' /etc/mihomo/config.yaml 2>/dev/null; then
                warn "Порт 443 уже занят VLESS TCP. Выберите другой порт или удалите TCP."; return
            fi
            if grep -q '# --- vless-xhttp ---' /etc/mihomo/config.yaml 2>/dev/null; then
                local _xp
                _xp=$(awk '/# --- vless-xhttp ---/{f=1} f && /port:/{print $2; exit}' /etc/mihomo/config.yaml)
                if [[ "$_xp" == "$MIHOMO_PORT" ]]; then
                    warn "Порт 443 уже занят VLESS xHTTP. Выберите другой порт или удалите xHTTP."; return
                fi
            fi
            GRPC_LISTEN="$MIHOMO_LISTEN"
            GRPC_PORT="$MIHOMO_PORT"
            client_port=443
            ;;
        2)
            local DEFAULT_PORT=$(gen_free_port 10000 65535)
            _vless_port_input "$DEFAULT_PORT"
            GRPC_LISTEN="0.0.0.0"
            GRPC_PORT="$VLESS_PORT"
            client_port="$GRPC_PORT"
            ;;
        0) return ;;
        *)
            warn "Неверный выбор."; return
            ;;
    esac

    echo ""
    info "Порт:         $client_port"
    info "Service name: $GRPC_SERVICE"
    echo ""
    confirm_yn "Всё верно?" || { info "Отменено."; return; }

    info "Добавляю VLESS gRPC..."

    # Удаляем старый блок если есть
    sed -i '/^# --- vless-grpc ---/,/^# --- \/vless-grpc ---/d' /etc/mihomo/config.yaml

    # Генерируем и вставляем listener
    local _listener_yaml
    _listener_yaml=$(_build_vless_grpc_listener_yaml \
        "VLESS gRPC" "$GRPC_LISTEN" "$GRPC_PORT" \
        "user1" "$UUID" "$GRPC_SERVICE" \
        "$REALITY_DEST" "$PRIVATE_KEY" "$SHORT_ID" "$SNI_DOMAIN" "outbound")

    printf '%s\n' "# --- vless-grpc ---" "$_listener_yaml" "# --- /vless-grpc ---" > /tmp/_inject_tmp.yaml

    awk '/^rule-providers:/{
        while ((getline line < "/tmp/_inject_tmp.yaml") > 0) print line
        print ""
    }
    {print}' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
    rm -f /tmp/_inject_tmp.yaml

    # UFW
    ufw allow "${client_port}/tcp" > /dev/null 2>&1
    success "Порт $client_port открыт"

    # Перезапуск
    systemctl restart mihomo &>/dev/null
    sleep 3

    if systemctl is-active --quiet mihomo; then
        success "VLESS gRPC добавлен"
    else
        warn "Mihomo не запустился. Лог:"
        journalctl -u mihomo -n 20 --no-pager
    fi

    # Клиентский конфиг
    if [[ -f /etc/mihomo/client-config.txt ]]; then
        sed -i '/^--- VLESS gRPC ---/,/^--- \/VLESS gRPC ---/d' /etc/mihomo/client-config.txt
    fi

    local _client_uri _client_yaml
    _client_uri=$(_build_vless_grpc_uri "$UUID" "$CLIENT_SERVER" "$client_port" "$SNI_DOMAIN" "$GRPC_SERVICE" "$PUBLIC_KEY" "$SHORT_ID" "VLESS gRPC")
    _client_yaml=$(_build_vless_grpc_client_yaml "VLESS gRPC" "$CLIENT_SERVER" "$client_port" "$UUID" "$SNI_DOMAIN" "$GRPC_SERVICE" "$PUBLIC_KEY" "$SHORT_ID")

    cat >> /etc/mihomo/client-config.txt << VLESSGRPCEOF

--- VLESS gRPC ---
Transport:        grpc
Server:           $CLIENT_SERVER
Port:             $client_port
SNI:              $SNI_DOMAIN
UUID:             $UUID
Public key:       $PUBLIC_KEY
Short ID:         $SHORT_ID
Service name:     $GRPC_SERVICE

URI: $_client_uri

$_client_yaml
--- /VLESS gRPC ---
VLESSGRPCEOF

    echo ""
    echo -e "  Сервер:       ${CYAN}$CLIENT_SERVER:$client_port${NC}"
    echo -e "  SNI:          ${CYAN}$SNI_DOMAIN${NC}"
    echo -e "  Service name: ${CYAN}$GRPC_SERVICE${NC}"
    echo ""
}

# ─── Удалить транспорт ───────────────────────────────────────────────────────

_remove_vless_transport() {
    echo ""

    # Собираем список установленных транспортов
    local items=() labels=()
    if grep -q '# --- vless-tcp ---' /etc/mihomo/config.yaml 2>/dev/null; then
        items+=("tcp")
        labels+=("VLESS TCP (порт 443)")
    fi
    if grep -q '# --- vless-xhttp ---' /etc/mihomo/config.yaml 2>/dev/null; then
        local xhttp_port
        xhttp_port=$(awk '/^--- VLESS xHTTP ---/{f=1} f && /^Port:/{print $2; exit}' /etc/mihomo/client-config.txt 2>/dev/null)
        items+=("xhttp")
        labels+=("VLESS xHTTP (порт ${xhttp_port:-?})")
    fi
    if grep -q '# --- vless-grpc ---' /etc/mihomo/config.yaml 2>/dev/null; then
        local grpc_port
        grpc_port=$(awk '/^--- VLESS gRPC ---/{f=1} f && /^Port:/{print $2; exit}' /etc/mihomo/client-config.txt 2>/dev/null)
        items+=("grpc")
        labels+=("VLESS gRPC (порт ${grpc_port:-?})")
    fi

    if [[ ${#items[@]} -eq 0 ]]; then
        warn "Нет установленных VLESS транспортов."
        return
    fi

    local i
    for i in "${!items[@]}"; do
        echo -e "  ${GREEN}$((i+1)))${NC} ${labels[$i]}"
    done

    echo ""
    read -rp "Выберите транспорт для удаления [0 = назад]: " DEL_CHOICE

    if [[ "$DEL_CHOICE" == "0" || -z "$DEL_CHOICE" ]]; then return; fi
    if ! [[ "$DEL_CHOICE" =~ ^[0-9]+$ ]] || (( DEL_CHOICE < 1 || DEL_CHOICE > ${#items[@]} )); then
        warn "Неверный выбор."; return
    fi

    local selected="${items[$((DEL_CHOICE-1))]}"

    # Проверяем cascade-user перед удалением
    local _marker_name
    case "$selected" in
        tcp) _marker_name="vless-tcp" ;;
        xhttp) _marker_name="vless-xhttp" ;;
        grpc) _marker_name="vless-grpc" ;;
    esac
    local _cascade_names
    if _cascade_names=$(_check_cascade_users "$_marker_name" 2>/dev/null) && [[ -n "$_cascade_names" ]]; then
        echo ""
        warn "Этот листенер используется каскадами:"
        echo "$_cascade_names" | while read -r _cn; do
            echo -e "    ${YELLOW}*${NC} $_cn"
        done
        warn "Удаление сломает эти каскады. Сначала удалите их."
        confirm_yn "Всё равно удалить?" || return
    fi

    case "$selected" in
        tcp)
            confirm_yn "Удалить VLESS TCP?" || return
            sed -i '/^# --- vless-tcp ---/,/^# --- \/vless-tcp ---/d' /etc/mihomo/config.yaml
            sed -i '/^--- VLESS TCP ---/,/^--- \/VLESS TCP ---/d' /etc/mihomo/client-config.txt 2>/dev/null
            success "VLESS TCP удалён"
            ;;
        xhttp)
            confirm_yn "Удалить VLESS xHTTP?" || return
            local xp
            xp=$(awk '/^--- VLESS xHTTP ---/{f=1} f && /^Port:/{print $2; exit}' /etc/mihomo/client-config.txt 2>/dev/null)
            sed -i '/^# --- vless-xhttp ---/,/^# --- \/vless-xhttp ---/d' /etc/mihomo/config.yaml
            sed -i '/^--- VLESS xHTTP ---/,/^--- \/VLESS xHTTP ---/d' /etc/mihomo/client-config.txt 2>/dev/null
            _remove_xhttp_nginx_location
            rm -rf /etc/mihomo/certs/xhttp
            if [[ -n "$xp" && "$xp" != "443" ]]; then
                ufw delete allow "${xp}/tcp" > /dev/null 2>&1 || true
                success "VLESS xHTTP удалён (порт $xp закрыт)"
            else
                success "VLESS xHTTP удалён"
            fi
            ;;
        grpc)
            confirm_yn "Удалить VLESS gRPC?" || return
            local gp
            gp=$(awk '/^--- VLESS gRPC ---/{f=1} f && /^Port:/{print $2; exit}' /etc/mihomo/client-config.txt 2>/dev/null)
            sed -i '/^# --- vless-grpc ---/,/^# --- \/vless-grpc ---/d' /etc/mihomo/config.yaml
            sed -i '/^--- VLESS gRPC ---/,/^--- \/VLESS gRPC ---/d' /etc/mihomo/client-config.txt 2>/dev/null
            if [[ -n "$gp" && "$gp" != "443" ]]; then
                ufw delete allow "${gp}/tcp" > /dev/null 2>&1 || true
                success "VLESS gRPC удалён (порт $gp закрыт)"
            else
                success "VLESS gRPC удалён"
            fi
            ;;
    esac

    # Перезапуск Mihomo
    info "Перезапускаю Mihomo..."
    systemctl restart mihomo &>/dev/null
    sleep 2
    if systemctl is-active --quiet mihomo; then
        success "Mihomo перезапущен"
    else
        warn "Mihomo не запустился. Лог:"
        journalctl -u mihomo -n 20 --no-pager
    fi
}

# ─── Статус VLESS ────────────────────────────────────────────────────────────

_vless_status() {
    echo ""
    if [[ -f /etc/mihomo/reality.conf ]]; then
        _load_reality_conf
        echo -e "  Reality: ${GREEN}настроен${NC} (${CYAN}$MODE${NC})"
        echo -e "  SNI:     ${CYAN}$SNI_DOMAIN${NC}"
        echo -e "  Сервер:  ${CYAN}$CLIENT_SERVER${NC}"
    else
        echo -e "  Reality: ${RED}не настроен${NC}"
    fi

    echo ""
    local found=false
    if grep -q '# --- vless-tcp ---' /etc/mihomo/config.yaml 2>/dev/null; then
        echo -e "  TCP:     ${GREEN}установлен${NC} (порт 443)"
        found=true
    fi
    if grep -q '# --- vless-xhttp ---' /etc/mihomo/config.yaml 2>/dev/null; then
        local xp
        xp=$(awk '/^--- VLESS xHTTP ---/{f=1} f && /^Port:/{print $2; exit}' /etc/mihomo/client-config.txt 2>/dev/null)
        echo -e "  xHTTP:   ${GREEN}установлен${NC} (порт ${xp:-?})"
        found=true
    fi
    if grep -q '# --- vless-grpc ---' /etc/mihomo/config.yaml 2>/dev/null; then
        local gp
        gp=$(awk '/^--- VLESS gRPC ---/{f=1} f && /^Port:/{print $2; exit}' /etc/mihomo/client-config.txt 2>/dev/null)
        echo -e "  gRPC:    ${GREEN}установлен${NC} (порт ${gp:-?})"
        found=true
    fi
    if [[ "$found" == "false" ]]; then
        echo -e "  Транспорты: ${RED}не установлены${NC}"
    fi
    echo ""
}

# ─── Меню VLESS ──────────────────────────────────────────────────────────────

vless_menu() {
    _check_base || return

    while true; do
        echo ""
        box_top
        box_center "VLESS Reality"
        box_bot
        _vless_status
        echo -e "  ${GREEN}1)${NC} Настроить Reality"
        echo -e "  ${GREEN}2)${NC} Добавить TCP"
        echo -e "  ${GREEN}3)${NC} Добавить xHTTP"
        echo -e "  ${GREEN}4)${NC} Добавить gRPC"
        echo -e "  ${RED}d)${NC} Удалить транспорт"
        echo -e "  ${CYAN}s)${NC} Статус"
        echo -e "  ${NC}0)${NC} Назад"
        echo ""
        read -rp "Выберите [0]: " VLESS_CHOICE

        case "$VLESS_CHOICE" in
            1) setup_reality ;;
            2) _add_vless_tcp ;;
            3) _add_vless_xhttp ;;
            4) _add_vless_grpc ;;
            d|D) _remove_vless_transport ;;
            s|S) _vless_status ;;
            0|"") return ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}
