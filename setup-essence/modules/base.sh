#!/bin/bash
# ─── Базовая установка (mihomo, sysctl, UFW, systemd) ────────────────────────

install_base() {
    if [[ -f /usr/local/bin/mihomo ]] && [[ -f /etc/mihomo/config.yaml ]]; then
        warn "Mihomo уже установлен."
        confirm_yn "Переустановить базу?" || return
    fi

    local TOTAL_STEPS=4 STEP=0

    # ─── Шаг 1: Зависимости ─────────────────────────────────────────────────
    STEP=$((STEP + 1))
    echo ""
    info "Шаг $STEP/$TOTAL_STEPS: Установка зависимостей..."
    apt_wait
    DEBIAN_FRONTEND=noninteractive apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl wget unzip ufw openssl uuid-runtime dnsutils cron || error "Не удалось установить зависимости"
    success "Зависимости установлены"

    # ─── Шаг 2: Оптимизация сети ─────────────────────────────────────────────
    STEP=$((STEP + 1))
    echo ""
    info "Шаг $STEP/$TOTAL_STEPS: Оптимизация сети (sysctl)..."

    cat > /etc/sysctl.d/99-vpn-speedup.conf << SYSCTLEOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
SYSCTLEOF

    sysctl --system > /dev/null 2>&1
    success "Оптимизация сети применена"

    # UFW
    info "Настройка firewall..."
    local _ssh_port
    _ssh_port=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    _ssh_port="${_ssh_port:-22}"
    ufw --force reset > /dev/null
    ufw default deny incoming
    ufw default allow outgoing
    if [[ "$_ssh_port" == "22" ]]; then
        ufw allow OpenSSH
    else
        ufw allow "${_ssh_port}/tcp"
    fi
    ufw --force enable > /dev/null
    success "Firewall включён: открыт SSH (${_ssh_port})"

    # ─── Шаг 3: Mihomo ──────────────────────────────────────────────────────
    STEP=$((STEP + 1))
    echo ""
    info "Шаг $STEP/$TOTAL_STEPS: Установка Mihomo..."
    _install_mihomo_binary

    # ─── Шаг 4: Конфиг + systemd ────────────────────────────────────────────
    STEP=$((STEP + 1))
    echo ""
    info "Шаг $STEP/$TOTAL_STEPS: Создание конфига и сервиса..."
    mkdir -p /etc/mihomo/rules

    # Не перезаписываем config.yaml если он уже есть
    if [[ ! -f /etc/mihomo/config.yaml ]]; then
        _write_config_skeleton
    fi

    _write_systemd_service

    systemctl daemon-reload
    systemctl enable mihomo
    systemctl start mihomo
    sleep 4

    if systemctl is-active --quiet mihomo; then
        success "Mihomo запущен"
    else
        warn "Mihomo не запустился. Лог:"
        journalctl -u mihomo -n 20 --no-pager
    fi

    echo ""
    success "Базовая установка завершена."
    info "Теперь добавьте протоколы: VLESS Reality, Hysteria2, AmneziaWG и т.д."
}

# ─── Вспомогательные функции ──────────────────────────────────────────────────

_install_mihomo_binary() {
    LATEST=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4)
    [[ -z "$LATEST" ]] && error "Не удалось получить актуальную версию Mihomo с GitHub."
    info "Версия: $LATEST"

    case "$(uname -m)" in
        aarch64|arm64)
            MIHOMO_ARCH="arm64"
            ;;
        armv7l|armv7)
            MIHOMO_ARCH="armv7"
            ;;
        *)
            CPU_FLAGS=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || echo "")
            if echo "$CPU_FLAGS" | grep -qw "avx2"; then
                MIHOMO_ARCH="amd64-v3"
            elif echo "$CPU_FLAGS" | grep -qw "sse4_2"; then
                MIHOMO_ARCH="amd64-v2"
            else
                MIHOMO_ARCH="amd64"
            fi
            ;;
    esac
    info "Архитектура CPU: $MIHOMO_ARCH"

    curl -Lo /tmp/mihomo.gz \
        "https://github.com/MetaCubeX/mihomo/releases/download/${LATEST}/mihomo-linux-${MIHOMO_ARCH}-${LATEST}.gz"
    gunzip -f /tmp/mihomo.gz
    mv /tmp/mihomo /usr/local/bin/mihomo
    chmod +x /usr/local/bin/mihomo
    success "Mihomo установлен: $(/usr/local/bin/mihomo -v 2>&1 | head -1)"
}

_write_config_skeleton() {
    cat > /etc/mihomo/config.yaml << 'MIHOMOEOF'
log-level: silent
mode: rule
ipv6: false
tcp-concurrent: true
unified-delay: true
allow-lan: false
bind-address: "*"
keep-alive-interval: 15
external-controller: 127.0.0.1:9090

dns:
  enable: false

sniffer:
  enable: false

proxies:
# --- proxies ---
# --- /proxies ---

proxy-groups:
  - name: outbound
    type: fallback
    proxies:
      - DIRECT
    url: https://www.gstatic.com/generate_204
    interval: 10
    timeout: 3000
    lazy: false

listeners:

rule-providers:
  refilter_ipsum:
    type: http
    behavior: ipcidr
    format: mrs
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/re-filter/ip-rule.mrs
    path: ./rules/re-filter.mrs
    interval: 86400
  discord-voice-ips:
    type: http
    behavior: ipcidr
    format: mrs
    url: https://github.com/legiz-ru/mihomo-rule-sets/raw/main/other/discord-voice-ip-list.mrs
    path: ./rules/discord-voice-ips.mrs
    interval: 86400
  telegram-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/telegram.mrs
    path: ./rules/telegram-ip.mrs
    interval: 86400
  cloudflare-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/cloudflare.mrs
    path: ./rules/cloudflare-ip.mrs
    interval: 86400
  geoip-ru:
    type: http
    behavior: ipcidr
    format: text
    url: https://raw.githubusercontent.com/Davoyan/ipinfo/main/geo/geoip/ru.lst
    path: ./rules/geoip-ru.lst
    interval: 86400
  facebook-asn:
    type: http
    behavior: classical
    format: yaml
    url: https://raw.githubusercontent.com/Kwisma/ASN-List/refs/heads/main/data/Facebook/Facebook_ASN.yaml
    path: ./rules/Facebook_ASN.yaml
    interval: 86400
  fastly-asn:
    type: http
    behavior: classical
    format: yaml
    url: https://raw.githubusercontent.com/Kwisma/ASN-List/refs/heads/main/data/Fastly/Fastly_ASN.yaml
    path: ./rules/Fastly_ASN.yaml
    interval: 86400
  netflix-asn:
    type: http
    behavior: classical
    format: yaml
    url: https://raw.githubusercontent.com/Kwisma/ASN-List/refs/heads/main/data/Netflix/Netflix_ASN.yaml
    path: ./rules/Netflix_ASN.yaml
    interval: 86400
  telegram-asn:
    type: http
    behavior: classical
    format: yaml
    url: https://raw.githubusercontent.com/Kwisma/ASN-List/refs/heads/main/data/Telegram/Telegram_ASN.yaml
    path: ./rules/Telegram_ASN.yaml
    interval: 86400
  twitter-asn:
    type: http
    behavior: classical
    format: yaml
    url: https://raw.githubusercontent.com/Kwisma/ASN-List/refs/heads/main/data/Twitter/Twitter_ASN.yaml
    path: ./rules/Twitter_ASN.yaml
    interval: 86400
  google-asn:
    type: http
    behavior: classical
    format: yaml
    url: https://raw.githubusercontent.com/Kwisma/ASN-List/refs/heads/main/data/Google/Google_ASN.yaml
    path: ./rules/Google_ASN.yaml
    interval: 86400
  amazon-asn:
    type: http
    behavior: classical
    format: yaml
    url: https://raw.githubusercontent.com/Kwisma/ASN-List/refs/heads/main/data/Amazon/Amazon_ASN.yaml
    path: ./rules/Amazon_ASN.yaml
    interval: 86400
  cloudflare-asn:
    type: http
    behavior: classical
    format: yaml
    url: https://raw.githubusercontent.com/Kwisma/ASN-List/refs/heads/main/data/Cloudflare/Cloudflare_ASN.yaml
    path: ./rules/Cloudflare_ASN.yaml
    interval: 86400
  microsoft-asn:
    type: http
    behavior: classical
    format: yaml
    url: https://raw.githubusercontent.com/Kwisma/ASN-List/refs/heads/main/data/Microsoft/Microsoft_ASN.yaml
    path: ./rules/Microsoft_ASN.yaml
    interval: 86400
  leaseweb-asn:
    type: http
    behavior: classical
    format: yaml
    url: https://raw.githubusercontent.com/Kwisma/ASN-List/refs/heads/main/data/Leaseweb/Leaseweb_ASN.yaml
    path: ./rules/Leaseweb_ASN.yaml
    interval: 86400

rules:
  - RULE-SET,refilter_ipsum,outbound
  - RULE-SET,discord-voice-ips,outbound
  - RULE-SET,telegram-ip,outbound
  - RULE-SET,facebook-asn,outbound
  - RULE-SET,fastly-asn,outbound
  - RULE-SET,netflix-asn,outbound
  - RULE-SET,telegram-asn,outbound
  - RULE-SET,twitter-asn,outbound
  - RULE-SET,google-asn,outbound
  - RULE-SET,amazon-asn,outbound
  - RULE-SET,cloudflare-asn,outbound
  - RULE-SET,microsoft-asn,outbound
  - RULE-SET,leaseweb-asn,outbound
  - RULE-SET,geoip-ru,outbound
  - MATCH,DIRECT
MIHOMOEOF
}

_write_systemd_service() {
    cat > /etc/systemd/system/mihomo.service << 'SVCEOF'
[Unit]
Description=Mihomo Daemon (Intermediate Node)
After=network.target NetworkManager.service systemd-networkd.service

[Service]
Type=simple
LimitNPROC=500
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
Restart=always
Environment="SAFE_PATHS=/etc/mihomo:/etc/nginx/ssl"
ExecStartPre=/usr/bin/sleep 3s
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
SVCEOF
}

# Проверка что база установлена
_check_base() {
    if [[ ! -f /etc/mihomo/config.yaml ]]; then
        warn "Mihomo не установлен. Сначала выполните базовую установку (пункт 1)."
        return 1
    fi
}
