#!/bin/bash
# ─── AmneziaWG ──────────────────────────────────────────────────────────────

AWG_DIR="/etc/amnezia/amneziawg"
AWG_CONF="$AWG_DIR/awg0.conf"

# ── Общая логика создания peer ──────────────────────────────────────────────
# _awg_create_peer <CLIENT_NAME>
# Создаёт peer: ключи, серверный конфиг, клиентские конфиги, QR.
# Устанавливает: PEER_IP, PEER_CONF, PEER_MIHOMO_CONF
# Возвращает 1 при ошибке.
_awg_create_peer() {
    local CLIENT_NAME="$1"

    # Определяем следующий IP
    local subnet
    subnet=$(grep 'Address' "$AWG_CONF" | head -1 | awk '{print $3}' | cut -d'.' -f1-3)
    local last_ip
    last_ip=$(grep 'AllowedIPs' "$AWG_CONF" | tail -1 | awk '{print $3}' | cut -d'/' -f1)
    [[ -z "$last_ip" ]] && last_ip="${subnet}.1"
    local next_octet=$(( ${last_ip##*.} + 1 ))

    if (( next_octet > 254 )); then
        echo "Подсеть заполнена — максимум 253 клиента" >&2
        return 1
    fi

    PEER_IP="${subnet}.${next_octet}"

    # Генерация ключей
    local client_priv client_pub psk
    client_priv=$(awg genkey)
    client_pub=$(echo "$client_priv" | awg pubkey)
    psk=$(awg genpsk)

    # Серверные параметры
    local server_pub awg_port
    server_pub=$(cat "$AWG_DIR/server_public.key")
    awg_port=$(grep 'ListenPort' "$AWG_CONF" | awk '{print $3}')

    local Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4
    Jc=$(grep '^Jc' "$AWG_CONF" | awk '{print $3}')
    Jmin=$(grep '^Jmin' "$AWG_CONF" | awk '{print $3}')
    Jmax=$(grep '^Jmax' "$AWG_CONF" | awk '{print $3}')
    S1=$(grep '^S1' "$AWG_CONF" | awk '{print $3}')
    S2=$(grep '^S2' "$AWG_CONF" | awk '{print $3}')
    S3=$(grep '^S3' "$AWG_CONF" | awk '{print $3}')
    S4=$(grep '^S4' "$AWG_CONF" | awk '{print $3}')
    H1=$(grep '^H1' "$AWG_CONF" | awk '{print $3}')
    H2=$(grep '^H2' "$AWG_CONF" | awk '{print $3}')
    H3=$(grep '^H3' "$AWG_CONF" | awk '{print $3}')
    H4=$(grep '^H4' "$AWG_CONF" | awk '{print $3}')

    # Добавляем peer в серверный конфиг
    cat >> "$AWG_CONF" << PEEREOF

# peer: $CLIENT_NAME
[Peer]
PublicKey = $client_pub
PresharedKey = $psk
AllowedIPs = ${PEER_IP}/32
PEEREOF

    # Применяем без перезапуска
    awg syncconf awg0 <(awg-quick strip "$AWG_CONF") 2>/dev/null || {
        systemctl restart awg-quick@awg0
        sleep 2
    }

    # Адрес сервера
    local SERVER_ADDR
    SERVER_ADDR=$(grep '^Domain:' /etc/mihomo/client-config.txt 2>/dev/null | awk '{print $2}')
    [[ -z "$SERVER_ADDR" ]] && SERVER_ADDR=$(curl -4 -s --max-time 5 ifconfig.me)

    local dns
    dns=$(grep '^DNS' "$AWG_DIR/clients/"*.conf 2>/dev/null | head -1 | sed 's/.*= //')
    [[ -z "$dns" ]] && dns="1.1.1.1, 1.0.0.1"

    # Клиентский конфиг
    local client_dir="/etc/mihomo/amnezia/${CLIENT_NAME}"
    mkdir -p "$client_dir"

    PEER_CONF="[Interface]
Address = ${PEER_IP}/32
DNS = $dns
PrivateKey = $client_priv
Jc = $Jc
Jmin = $Jmin
Jmax = $Jmax
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $server_pub
PresharedKey = $psk
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${SERVER_ADDR}:${awg_port}
PersistentKeepalive = 25"

    echo "$PEER_CONF" > "$client_dir/${CLIENT_NAME}.conf"
    chmod 600 "$client_dir/${CLIENT_NAME}.conf"

    PEER_MIHOMO_CONF="--- Client proxy config Mihomo/Clash.Meta ---
proxies:
  - name: awg-${CLIENT_NAME}
    type: wireguard
    private-key: $client_priv
    server: $SERVER_ADDR
    port: $awg_port
    ip: $PEER_IP
    dns: ['${dns// /}']
    public-key: $server_pub
    pre-shared-key: $psk
    allowed-ips: ['0.0.0.0/0', '::/0']
    udp: true
    persistent-keepalive: 25
    amnezia-wg-option:
      jc: $Jc
      jmin: $Jmin
      jmax: $Jmax
      s1: $S1
      s2: $S2
      s3: $S3
      s4: $S4
      h1: $H1
      h2: $H2
      h3: $H3
      h4: $H4"

    echo "$PEER_MIHOMO_CONF" > "$client_dir/mihomo-proxy.yaml"

    # QR-код
    if command -v qrencode > /dev/null 2>&1; then
        qrencode -t PNG -o "$client_dir/qr.png" -s 5 < "$client_dir/${CLIENT_NAME}.conf"
        chmod 600 "$client_dir/qr.png"
    fi
}

awg_menu() {
    echo ""
    box_top
    box_center "AmneziaWG"
    box_bot
    echo ""
    if systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        echo -e "  Статус: ${GREEN}работает${NC}"
    elif [[ -f "$AWG_CONF" ]]; then
        echo -e "  Статус: ${YELLOW}установлен, но не запущен${NC}"
    else
        echo -e "  Статус: ${RED}не установлен${NC}"
    fi
    echo ""
    echo -e "  ${GREEN}1)${NC} Установить AmneziaWG"
    echo -e "  ${CYAN}2)${NC} Добавить клиента"
    echo -e "  ${YELLOW}3)${NC} Удалить клиента"
    echo -e "  ${RED}4)${NC} Удалить AmneziaWG"
    echo -e "  ${NC}0)${NC} Назад"
    echo ""
    read -rp "Выберите действие [0-4]: " AWG_CHOICE

    case "$AWG_CHOICE" in
        1) install_awg ;;
        2) add_awg_peer ;;
        3) remove_awg_peer ;;
        4) uninstall_awg ;;
        0) return ;;
        *) warn "Неверный выбор." ;;
    esac
}

# ── Генерация обфускации (по аналогии с Amnezia-клиентом) ────────────────────

_awg_gen_params() {
    # Jc, Jmin, Jmax
    AWG_Jc=$(( RANDOM % 3 + 4 ))       # 4-6
    AWG_Jmin=10
    AWG_Jmax=50

    # S1-S4 с проверками уникальности
    while true; do
        AWG_S1=$(( RANDOM % 135 + 15 ))  # 15-149
        AWG_S2=$(( RANDOM % 135 + 15 ))
        # S1+148 != S2+92 (чтобы init и response пакеты имели разный размер)
        [[ "$AWG_S1" -ne "$AWG_S2" && $(( AWG_S1 + 148 )) -ne $(( AWG_S2 + 92 )) ]] && break
    done
    while true; do
        AWG_S3=$(( RANDOM % 63 + 1 ))    # 1-63
        [[ "$AWG_S3" -ne "$AWG_S1" && "$AWG_S3" -ne "$AWG_S2" ]] && break
    done
    while true; do
        AWG_S4=$(( RANDOM % 19 + 1 ))    # 1-19
        [[ "$AWG_S4" -ne "$AWG_S1" && "$AWG_S4" -ne "$AWG_S2" && "$AWG_S4" -ne "$AWG_S3" ]] && break
    done

    # H1-H4: восходящие непересекающиеся диапазоны [5, 2147483647]
    local nums=()
    while [[ ${#nums[@]} -lt 8 ]]; do
        local n=$(( RANDOM * RANDOM + RANDOM + 5 ))
        (( n < 5 )) && n=5
        nums+=("$n")
    done
    IFS=$'\n' nums=($(printf '%s\n' "${nums[@]}" | sort -n)); unset IFS

    AWG_H1="${nums[0]}-${nums[1]}"
    AWG_H2="${nums[2]}-${nums[3]}"
    AWG_H3="${nums[4]}-${nums[5]}"
    AWG_H4="${nums[6]}-${nums[7]}"
}

# ── Установка ────────────────────────────────────────────────────────────────

install_awg() {
    echo ""
    info "AmneziaWG — это WireGuard с обфускацией трафика против DPI."
    info "Сейчас будет установлен AWG-сервер."
    info "Peers (клиенты) создаются отдельно — через меню или remote-control."
    echo ""

    # Проверка поддержки TPROXY
    modprobe xt_TPROXY 2>/dev/null || true
    if ! lsmod | grep -q xt_TPROXY; then
        warn "Ядро не поддерживает TPROXY (xt_TPROXY). AWG через Mihomo невозможен."
        return 1
    fi

    if [[ -f "$AWG_CONF" ]]; then
        warn "AmneziaWG уже установлен."
        confirm_yn "Переустановить? (текущие клиенты будут потеряны)" || { info "Отменено."; return; }
        systemctl stop awg-quick@awg0 2>/dev/null || true
        ip link del awg0 2>/dev/null || true
        systemctl disable awg-quick@awg0 2>/dev/null || true
        rm -rf /etc/mihomo/amnezia/*
    fi

    # ── Параметры ────────────────────────────────────────────────────────────
    DEFAULT_PORT=$(gen_free_port 30000 50000)
    read -rp "UDP порт для AmneziaWG [Enter = $DEFAULT_PORT]: " AWG_PORT
    [[ -z "$AWG_PORT" ]] && AWG_PORT="$DEFAULT_PORT"
    while true; do
        if ! [[ "$AWG_PORT" =~ ^[0-9]+$ ]] || (( AWG_PORT < 1 || AWG_PORT > 65535 )); then
            warn "Неверный порт '$AWG_PORT'. Введите число от 1 до 65535."
        elif ! is_port_free "$AWG_PORT"; then
            warn "Порт $AWG_PORT уже занят."
        else
            break
        fi
        read -rp "Новый порт: " AWG_PORT
        [[ -z "$AWG_PORT" ]] && { warn "Порт не указан"; return; }
    done

    AWG_SUBNET="10.10.8"
    AWG_SERVER_IP="${AWG_SUBNET}.1"

    DEFAULT_DNS="1.1.1.1, 1.0.0.1"
    read -rp "DNS для клиентов [Enter = $DEFAULT_DNS]: " AWG_DNS
    [[ -z "$AWG_DNS" ]] && AWG_DNS="$DEFAULT_DNS"

    _awg_gen_params

    echo ""
    info "Порт:          $AWG_PORT/udp"
    info "Подсеть:       ${AWG_SUBNET}.0/24"
    info "DNS:           $AWG_DNS"
    info "Обфускация:    Jc=$AWG_Jc S1=$AWG_S1 S2=$AWG_S2 H1=$AWG_H1 ..."
    echo ""
    confirm_yn "Всё верно?" || { info "Отменено."; return; }

    # ── Установка пакетов ────────────────────────────────────────────────────
    echo ""
    info "Шаг 1/4: Установка AmneziaWG..."

    if ! command -v awg > /dev/null 2>&1; then
        if command -v add-apt-repository > /dev/null 2>&1; then
            apt_wait
            add-apt-repository -y ppa:amnezia/ppa > /dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get update -q
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q amneziawg amneziawg-tools || {
                warn "Не удалось установить из PPA, пробую amneziawg-tools отдельно..."
                DEBIAN_FRONTEND=noninteractive apt-get install -y -q amneziawg-tools
            }
        else
            error "PPA недоступен. Установите amneziawg и amneziawg-tools вручную."
        fi
    else
        info "awg уже установлен"
    fi

    command -v awg > /dev/null 2>&1 || error "awg не найден после установки"

    if ! command -v qrencode > /dev/null 2>&1; then
        apt_wait
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q qrencode 2>/dev/null || true
    fi

    success "AmneziaWG установлен"

    # ── Генерация ключей ─────────────────────────────────────────────────────
    echo ""
    info "Шаг 2/4: Генерация ключей..."
    mkdir -p "$AWG_DIR"

    SERVER_PRIVATE_KEY=$(awg genkey)
    SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | awg pubkey)
    PSK=$(awg genpsk)

    echo "$SERVER_PRIVATE_KEY" > "$AWG_DIR/server_private.key"
    echo "$SERVER_PUBLIC_KEY"  > "$AWG_DIR/server_public.key"
    echo "$PSK"                > "$AWG_DIR/psk.key"
    chmod 600 "$AWG_DIR"/*.key

    success "Ключи сгенерированы"

    # ── Серверный конфиг ─────────────────────────────────────────────────────
    echo ""
    info "Шаг 3/4: Создание конфигурации..."

    local TPROXY_PORT
    TPROXY_PORT=$(gen_free_port 10000 60000)

    cat > "$AWG_CONF" << AWGEOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = ${AWG_SERVER_IP}/24
ListenPort = $AWG_PORT
Jc = $AWG_Jc
Jmin = $AWG_Jmin
Jmax = $AWG_Jmax
S1 = $AWG_S1
S2 = $AWG_S2
S3 = $AWG_S3
S4 = $AWG_S4
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -I INPUT -m mark --mark 1 -j ACCEPT; ip rule add fwmark 1 table 100 || true; ip route add local 0.0.0.0/0 dev lo table 100 || true; iptables -t mangle -N MIHOMO_AWG || true; iptables -t mangle -F MIHOMO_AWG; iptables -t mangle -A MIHOMO_AWG -d ${AWG_SUBNET}.0/24 -j RETURN; iptables -t mangle -A MIHOMO_AWG -d 127.0.0.0/8 -j RETURN; iptables -t mangle -A MIHOMO_AWG -d 224.0.0.0/4 -j RETURN; iptables -t mangle -A MIHOMO_AWG -p tcp -j TPROXY --on-ip 127.0.0.1 --on-port $TPROXY_PORT --tproxy-mark 1; iptables -t mangle -A MIHOMO_AWG -p udp -j TPROXY --on-ip 127.0.0.1 --on-port $TPROXY_PORT --tproxy-mark 1; iptables -t mangle -A PREROUTING -i %i -j MIHOMO_AWG; iptables -t nat -A PREROUTING -i %i -p udp --dport 53 -j REDIRECT --to-ports 1053
PostDown = iptables -D FORWARD -i %i -j ACCEPT || true; iptables -D INPUT -m mark --mark 1 -j ACCEPT || true; iptables -t mangle -D PREROUTING -i %i -j MIHOMO_AWG || true; iptables -t mangle -F MIHOMO_AWG || true; iptables -t mangle -X MIHOMO_AWG || true; iptables -t nat -D PREROUTING -i %i -p udp --dport 53 -j REDIRECT --to-ports 1053 || true; ip rule del fwmark 1 table 100 || true; ip route del local 0.0.0.0/0 dev lo table 100 || true
AWGEOF

    chmod 600 "$AWG_CONF"
    success "Серверный конфиг: $AWG_CONF"

    # ── IP forwarding + запуск ───────────────────────────────────────────────
    echo ""
    info "Шаг 4/4: Запуск сервиса..."

    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    grep -q 'net.ipv4.ip_forward' /etc/sysctl.d/99-vpn-speedup.conf 2>/dev/null || \
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-vpn-speedup.conf

    # Добавить/обновить tproxy-port в Mihomo для приёма AWG трафика
    if grep -q '^tproxy-port:' /etc/mihomo/config.yaml; then
        sed -i "s/^tproxy-port:.*/tproxy-port: ${TPROXY_PORT}/" /etc/mihomo/config.yaml
    else
        sed -i "/^bind-address:/a tproxy-port: ${TPROXY_PORT}" /etc/mihomo/config.yaml
    fi
    systemctl restart mihomo &>/dev/null
    sleep 2

    systemctl enable awg-quick@awg0 2>/dev/null
    systemctl restart awg-quick@awg0
    sleep 2

    if ip link show awg0 > /dev/null 2>&1; then
        success "AmneziaWG запущен — интерфейс awg0"
    else
        warn "Интерфейс awg0 не найден. Лог:"
        journalctl -u awg-quick@awg0 -n 20 --no-pager
    fi

    ufw allow "${AWG_PORT}/udp" > /dev/null
    success "Порт $AWG_PORT/udp открыт"

    # Директория для клиентских конфигов
    mkdir -p /etc/mihomo/amnezia

    # ── AWG info в client-config.txt ────────────────────────────────────────
    SERVER_ADDR=$(grep '^Domain:' /etc/mihomo/client-config.txt 2>/dev/null | awk '{print $2}')
    [[ -z "$SERVER_ADDR" ]] && SERVER_ADDR=$(curl -4 -s --max-time 5 ifconfig.me)

    if [[ -f /etc/mihomo/client-config.txt ]]; then
        sed '/^--- AmneziaWG ---/,/^--- \/AmneziaWG ---/d' /etc/mihomo/client-config.txt > /tmp/client_tmp.txt
        mv /tmp/client_tmp.txt /etc/mihomo/client-config.txt
    fi

    cat >> /etc/mihomo/client-config.txt << AWGSAVEOF

--- AmneziaWG ---
Server:    $SERVER_ADDR
Port:      $AWG_PORT/udp
Subnet:    ${AWG_SUBNET}.0/24
Clients:   /etc/mihomo/amnezia/
--- /AmneziaWG ---
AWGSAVEOF

    echo ""
    success_box "AmneziaWG сервер установлен!"
    echo ""
    echo -e "  Сервер:      ${CYAN}${SERVER_ADDR}:${AWG_PORT}${NC}"
    echo -e "  Подсеть:     ${CYAN}${AWG_SUBNET}.0/24${NC}"
    echo ""

    if confirm_yn "Создать peer сейчас?" Y; then
        add_awg_peer
    else
        info "Peers можно создать позже через меню или remote-control."
    fi
}

# ── Добавить клиента ─────────────────────────────────────────────────────────

add_awg_peer() {
    echo ""

    if [[ ! -f "$AWG_CONF" ]]; then
        warn "AmneziaWG не установлен. Сначала выполните установку."
        return
    fi

    local client_num
    client_num=$(ls "$AWG_DIR/clients/" 2>/dev/null | wc -l)
    client_num=$(( client_num + 1 ))

    read -rp "Имя клиента [Enter = client${client_num}]: " CLIENT_NAME
    [[ -z "$CLIENT_NAME" ]] && CLIENT_NAME="client${client_num}"

    if ! [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        warn "Имя клиента может содержать только буквы, цифры, - и _"
        return
    fi

    if [[ -d "/etc/mihomo/amnezia/${CLIENT_NAME}" ]]; then
        warn "Клиент '$CLIENT_NAME' уже существует."
        confirm_yn "Перезаписать?" || { info "Отменено."; return; }
        sed -i "/# peer: $CLIENT_NAME/,/^$/d" "$AWG_CONF"
        rm -rf "/etc/mihomo/amnezia/${CLIENT_NAME}"
    fi

    _awg_create_peer "$CLIENT_NAME" || { warn "Не удалось создать peer."; return; }

    local client_dir="/etc/mihomo/amnezia/${CLIENT_NAME}"
    echo ""
    success_box "Клиент AmneziaWG добавлен!"
    echo ""
    echo -e "  Имя:     ${CYAN}$CLIENT_NAME${NC}"
    echo -e "  IP:      ${CYAN}$PEER_IP${NC}"
    echo -e "  Конфиг AWG:    ${CYAN}$client_dir/${CLIENT_NAME}.conf${NC}"
    echo -e "  Конфиг Mihomo: ${CYAN}$client_dir/mihomo-proxy.yaml${NC}"
    echo -e "  QR-код:        ${CYAN}$client_dir/qr.png${NC}"
    echo ""

    if command -v qrencode > /dev/null 2>&1; then
        echo -e "  ${CYAN}QR-код:${NC}"
        echo ""
        qrencode -t ANSIUTF8 < "$client_dir/${CLIENT_NAME}.conf"
        echo ""
    fi

    echo -e "  ${CYAN}Конфиг клиента AWG:${NC}"
    echo -e "${DIM}"
    echo "$PEER_CONF"
    echo -e "${NC}"
    echo -e "  ${CYAN}Конфиг клиента Mihomo/Clash.Meta:${NC}"
    echo -e "${DIM}"
    echo "$PEER_MIHOMO_CONF"
    echo -e "${NC}"
}

# ── Автоматическое добавление клиента (неинтерактивное) ────────────────────────
# Использование: add_awg_peer_auto <имя_клиента>
# Возвращает 0 при успехе, 1 при ошибке. Вывод в stderr.

add_awg_peer_auto() {
    local CLIENT_NAME="$1"

    if [[ -z "$CLIENT_NAME" ]]; then
        echo "Имя клиента не указано" >&2
        return 1
    fi

    if [[ ! -f "$AWG_CONF" ]]; then
        echo "AmneziaWG не установлен" >&2
        return 1
    fi

    # Если peer уже существует — пропускаем
    if [[ -d "/etc/mihomo/amnezia/${CLIENT_NAME}" ]]; then
        return 0
    fi

    _awg_create_peer "$CLIENT_NAME" || return 1

    echo "AWG peer $CLIENT_NAME создан (IP: $PEER_IP)" >&2
    return 0
}

# ── Удалить клиента ──────────────────────────────────────────────────────────

remove_awg_peer() {
    echo ""

    if [[ ! -f "$AWG_CONF" ]]; then
        warn "AmneziaWG не установлен."
        return
    fi

    # Список клиентов
    local clients_dir="/etc/mihomo/amnezia"
    local clients=()
    if [[ -d "$clients_dir" ]]; then
        for d in "$clients_dir"/*/; do
            [[ -d "$d" ]] && clients+=("$(basename "$d")")
        done
    fi

    if [[ ${#clients[@]} -eq 0 ]]; then
        warn "Нет клиентов для удаления."
        return
    fi

    echo -e "  ${CYAN}Клиенты:${NC}"
    local i=1
    for c in "${clients[@]}"; do
        local c_ip
        c_ip=$(grep -A3 "# peer: $c" "$AWG_CONF" 2>/dev/null | grep 'AllowedIPs' | awk '{print $3}' | cut -d'/' -f1)
        echo -e "  ${GREEN}${i})${NC} $c ${DIM}${c_ip}${NC}"
        i=$((i + 1))
    done
    echo ""

    read -rp "Номер клиента для удаления [1-${#clients[@]}]: " CLIENT_NUM
    if ! [[ "$CLIENT_NUM" =~ ^[0-9]+$ ]] || (( CLIENT_NUM < 1 || CLIENT_NUM > ${#clients[@]} )); then
        warn "Неверный выбор."
        return
    fi

    local client_name="${clients[$((CLIENT_NUM - 1))]}"

    warn "Будет удалён клиент: $client_name"
    confirm_yn "Вы уверены?" || { info "Отменено."; return; }

    # Удаляем peer из серверного конфига
    if grep -q "# peer: $client_name" "$AWG_CONF"; then
        sed -i "/# peer: $client_name/,/^$/d" "$AWG_CONF"
        success "Peer удалён из серверного конфига"
    fi

    # Применяем без перезапуска
    awg syncconf awg0 <(awg-quick strip "$AWG_CONF") 2>/dev/null || {
        warn "syncconf не сработал, перезапускаю сервис..."
        systemctl restart awg-quick@awg0
        sleep 2
    }

    # Удаляем папку клиента
    rm -rf "${clients_dir}/${client_name}"
    success "Конфиг клиента удалён"

    echo ""
    success "Клиент $client_name удалён."
    echo ""
}

# Неинтерактивное удаление peer по имени (для вызова из remote-control)
remove_awg_peer_by_name() {
    local client_name="$1"
    [[ -z "$client_name" ]] && { echo "Имя не указано" >&2; return 1; }
    [[ ! -f "$AWG_CONF" ]] && { echo "AWG не установлен" >&2; return 1; }

    local clients_dir="/etc/mihomo/amnezia"
    if [[ ! -d "${clients_dir}/${client_name}" ]]; then
        echo "Peer $client_name не найден" >&2
        return 1
    fi

    # Удаляем peer из серверного конфига
    if grep -q "# peer: $client_name" "$AWG_CONF"; then
        sed -i "/# peer: $client_name/,/^$/d" "$AWG_CONF"
    fi

    # Применяем без перезапуска
    awg syncconf awg0 <(awg-quick strip "$AWG_CONF") 2>/dev/null || {
        systemctl restart awg-quick@awg0 2>/dev/null
        sleep 2
    }

    # Удаляем папку клиента
    rm -rf "${clients_dir}/${client_name}"
    echo "Peer $client_name удалён" >&2
}

# ── Удаление ─────────────────────────────────────────────────────────────────

uninstall_awg() {
    echo ""

    if [[ ! -f "$AWG_CONF" ]] && ! command -v awg > /dev/null 2>&1; then
        warn "AmneziaWG не установлен."
        return
    fi

    warn "Будет удалён AmneziaWG: сервис, конфиги, ключи, клиенты."
    confirm_yn "Вы уверены?" || { info "Отменено."; return; }

    # Порт для закрытия в firewall
    local awg_port
    awg_port=$(grep 'ListenPort' "$AWG_CONF" 2>/dev/null | awk '{print $3}')

    awg-quick down awg0 2>/dev/null || true
    systemctl stop awg-quick@awg0 2>/dev/null || true
    systemctl disable awg-quick@awg0 2>/dev/null || true
    success "Сервис остановлен"

    # Убрать tproxy-port (добавлялся при установке AWG)
    if grep -q '^tproxy-port:' /etc/mihomo/config.yaml 2>/dev/null; then
        sed -i '/^tproxy-port:/d' /etc/mihomo/config.yaml
        systemctl restart mihomo &>/dev/null
        sleep 2
        success "tproxy-port убран из config.yaml"
    fi

    rm -rf "$AWG_DIR"
    rm -rf /etc/amnezia
    rm -rf /etc/mihomo/amnezia
    success "Конфиги, ключи и клиенты удалены"

    if [[ -n "$awg_port" ]]; then
        ufw delete allow "${awg_port}/udp" > /dev/null 2>&1 || true
        success "Порт $awg_port/udp закрыт"
    fi

    if [[ -f /etc/mihomo/client-config.txt ]]; then
        sed '/^--- AmneziaWG ---/,/^--- \/AmneziaWG ---/d' /etc/mihomo/client-config.txt > /tmp/client_tmp.txt
        mv /tmp/client_tmp.txt /etc/mihomo/client-config.txt
        success "Секция AmneziaWG удалена из client-config.txt"
    fi

    info "Перезагрузка systemd..."
    systemctl daemon-reload

    echo ""
    success "AmneziaWG полностью удалён."
    echo ""
}
