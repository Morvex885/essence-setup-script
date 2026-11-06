#!/bin/bash

if (( BASH_VERSINFO[0] < 3 || ( BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2) )); then
    printf '  [✗] Требуется Bash 3.2 или новее.\n' >&2
    exit 1
fi

# ─── Определяем директорию скрипта ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ─── Подключаем модули ───────────────────────────────────────────────────────
if [[ -f "$SCRIPT_DIR/common/common.sh" ]]; then
    source "$SCRIPT_DIR/common/common.sh"
    source "$SCRIPT_DIR/common/cert.sh"
    _proto_dir="$SCRIPT_DIR/common/protocols"
elif [[ -f "$SCRIPT_DIR/../common/common.sh" ]]; then
    source "$SCRIPT_DIR/../common/common.sh"
    source "$SCRIPT_DIR/../common/cert.sh"
    _proto_dir="$SCRIPT_DIR/../common/protocols"
fi
if [[ -f "$_proto_dir/../ensure-deps.sh" ]]; then
    source "$_proto_dir/../ensure-deps.sh"
elif [[ -f "$SCRIPT_DIR/common/ensure-deps.sh" ]]; then
    source "$SCRIPT_DIR/common/ensure-deps.sh"
elif [[ -f "$SCRIPT_DIR/../common/ensure-deps.sh" ]]; then
    source "$SCRIPT_DIR/../common/ensure-deps.sh"
fi
# Подключаем protocol builders
for _f in "$_proto_dir"/*.sh; do
    [[ -f "$_f" ]] && source "$_f"
done
source "$SCRIPT_DIR/modules/acme-email.sh"
source "$SCRIPT_DIR/modules/fake-site.sh"
source "$SCRIPT_DIR/modules/base.sh"
source "$SCRIPT_DIR/modules/vless.sh"
source "$SCRIPT_DIR/modules/hysteria.sh"
source "$SCRIPT_DIR/modules/ipv6.sh"
source "$SCRIPT_DIR/modules/warp.sh"
source "$SCRIPT_DIR/modules/amneziawg.sh"
source "$SCRIPT_DIR/modules/cascade.sh"
source "$SCRIPT_DIR/modules/subscription.sh"
source "$SCRIPT_DIR/modules/telegram-proxy.sh"
source "$SCRIPT_DIR/modules/menu-address.sh"
source "$SCRIPT_DIR/modules/uninstall.sh"

if [[ $EUID -ne 0 ]]; then
    warn "Запустите скрипт от root: sudo bash $0"
    if [[ -t 0 && -t 1 ]]; then
        startup_recovery_menu "Требуются права root" false || true
    fi
    exit 1
fi

# ─── Текущая версия + фоновая проверка обновления ────────────────────────────
CURRENT_VERSION="none"
if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    CURRENT_VERSION=$(tr -d '\r' < "$SCRIPT_DIR/VERSION")
elif [[ -f "$SCRIPT_DIR/../VERSION" ]]; then
    CURRENT_VERSION=$(tr -d '\r' < "$SCRIPT_DIR/../VERSION")
fi
check_update_start
menu_address_start || true

# ─── Самообновление ───────────────────────────────────────────────────────────
self_update() {
    local installer="$SCRIPT_DIR/install-essence.sh"
    if [[ ! -f "$installer" ]]; then
        warn "install-essence.sh не найден в $SCRIPT_DIR"
        warn "Переустановите скрипт командой из README."
        return
    fi
    bash "$installer"
}

# ─── Показать клиентский конфиг ───────────────────────────────────────────────
show_client_config() {
    local cfg="/etc/mihomo/client-config.txt"
    if [[ ! -f "$cfg" ]]; then
        warn "Клиентский конфиг не найден ($cfg)."
        warn "Сначала установите VLESS или Hysteria2."
        return
    fi
    echo ""
    echo -e "${CYAN}─── Клиентский конфиг ──────────────────────────${NC}"
    cat "$cfg"
    echo -e "${CYAN}────────────────────────────────────────────────${NC}"
    echo ""
}

show_server_config() {
    local cfg="/etc/mihomo/config.yaml"
    if [[ ! -f "$cfg" ]]; then
        warn "Серверный конфиг не найден ($cfg)."
        warn "Сначала выполните установку."
        return
    fi
    echo ""
    echo -e "${CYAN}─── Серверный конфиг ($cfg) ────────────────────${NC}"
    cat "$cfg"
    echo -e "${CYAN}────────────────────────────────────────────────${NC}"
    echo ""
}

# ─── Меню ────────────────────────────────────────────────────────────────────
show_menu() {
    local latest _domain _ver _upd _rmode _sni _rline _address _vless=() _telegram=()
    local _state _color _component _label _joined
    latest=$(latest_version)

    echo ""
    _domain=$(grep '^DOMAIN=' /etc/mihomo/reality.conf 2>/dev/null | cut -d= -f2)
    box_top
    box_center "Essence Setup"
    _ver="версия: ${CURRENT_VERSION}"
    box_center "$_ver" "${DIM}${_ver}${NC}"
    box_mid
    [[ -n "$_domain" ]] && box_line " Домен: ${_domain}"
    menu_address_read
    case "$_MENU_IPV4_STATE" in
        pending) _address="определяется…" ;;
        ready) _address="$_MENU_NODE_IPV4" ;;
        *) _address="не определён" ;;
    esac
    box_line " IPv4: $_address"
    if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] &&
        [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == 0 ]]; then
        case "$_MENU_IPV6_STATE" in
            pending) _address="определяется…" ;;
            ready) _address="$_MENU_NODE_IPV6" ;;
            *) _address="не определён" ;;
        esac
        box_line " IPv6: $_address"
    fi
    if [[ -n "$latest" ]] && has_update "$CURRENT_VERSION"; then
        _upd="↑ ${latest} — нажмите u"
        box_line " $_upd" " ${YELLOW}${_upd}${NC}"
    fi
    if [[ -f /etc/mihomo/reality.conf ]]; then
        _rmode=$(grep '^MODE=' /etc/mihomo/reality.conf 2>/dev/null | cut -d= -f2)
        _sni=$(grep '^SNI_DOMAIN=' /etc/mihomo/reality.conf 2>/dev/null | cut -d= -f2)
        if [[ -n "$_rmode" && -n "$_sni" ]]; then
            if [[ "$_rmode" == "self-steal" ]]; then
                _rline="Reality: self-steal"
            else
                _rline="Reality SNI: ${_sni}"
            fi
            box_line " $_rline" " ${DIM}${_rline}${NC}"
        fi
    fi
    if [[ -f /etc/mihomo/config.yaml ]]; then
        if grep -q '# --- vless-tcp ---' /etc/mihomo/config.yaml 2>/dev/null; then
            _vless+=("TCP")
        fi
        if grep -q '# --- vless-xhttp ---' /etc/mihomo/config.yaml 2>/dev/null; then
            _vless+=("xHTTP")
        fi
        if grep -q '# --- vless-grpc ---' /etc/mihomo/config.yaml 2>/dev/null; then
            _vless+=("gRPC")
        fi
    fi
    if [[ -x /usr/local/bin/mihomo ]]; then
        if systemctl is-active --quiet mihomo; then
            _state="работает"; _color="$GREEN"
        else
            _state="остановлен"; _color="$YELLOW"
        fi
    else
        _state="не установлен"; _color="$DIM"
    fi
    box_line " • Mihomo: $_state" " • Mihomo: ${_color}${_state}${NC}"
    if [[ ${#_vless[@]} -gt 0 ]]; then
        printf -v _joined '%s, ' "${_vless[@]}"
        _joined="${_joined%, }"
        box_line " • VLESS Reality: $_joined" " • VLESS Reality: ${GREEN}${_joined}${NC}"
    else
        box_line " • VLESS Reality: не установлен" " • VLESS Reality: ${DIM}не установлен${NC}"
    fi
    for _component in hy2 awg warp subscription; do
        _state="не установлен"; _color="$DIM"
        case "$_component" in
            hy2)
                _label="Hysteria2"
                if grep -q '# --- hy2 ---' /etc/mihomo/config.yaml 2>/dev/null; then _state="установлен"; _color="$GREEN"; fi ;;
            awg)
                _label="AmneziaWG 3.1"
                if [[ -f /etc/amnezia/amneziawg/awg0.conf ]]; then _state="установлен"; _color="$GREEN"; fi ;;
            warp)
                _label="WARP"
                if grep -q '# --- warp ---' /etc/mihomo/config.yaml 2>/dev/null; then _state="установлен"; _color="$GREEN"; fi ;;
            subscription)
                _label="Хостинг подписок"
                if ( _load_sub_conf ); then _state="установлен"; _color="$GREEN"; fi ;;
        esac
        box_line " • $_label: $_state" " • $_label: ${_color}${_state}${NC}"
    done
    _telegram_proxy_component_enabled web && _telegram+=("Web Proxy")
    _telegram_proxy_component_enabled mtproto && _telegram+=("MTProto Proxy")
    if [[ ${#_telegram[@]} -gt 0 ]]; then
        printf -v _joined '%s, ' "${_telegram[@]}"
        _joined="${_joined%, }"
        box_line " • Telegram Proxy: $_joined" " • Telegram Proxy: ${GREEN}${_joined}${NC}"
    else
        box_line " • Telegram Proxy: не установлен" " • Telegram Proxy: ${DIM}не установлен${NC}"
    fi
    box_mid
    menu_item b "Базовая установка" GREEN
    box_mid
    menu_item v "VLESS Reality" CYAN
    menu_item h "Hysteria2" CYAN
    menu_item a "AmneziaWG 3.1" CYAN
    menu_item t "Telegram Proxy" CYAN
    box_mid
    menu_item i "IPv6" CYAN
    menu_item w "WARP" CYAN
    menu_item c "Каскады" CYAN
    box_mid
    menu_item s "Хостинг подписок" CYAN
    menu_item k "Показать клиентский конфиг" CYAN
    menu_item m "Показать серверный конфиг mihomo" CYAN
    box_mid
    menu_item u "Обновить скрипты" YELLOW
    menu_item x "Удалить всё установленное" RED
    menu_item 0 "Выход" NC
    box_bot
    echo ""
    if ! IFS= read -rp "  Выберите действие: " CHOICE; then
        return 1
    fi
    CHOICE="${CHOICE%$'\r'}"
    return 0
}

# ─── Точка входа ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "telegram-proxy" ]]; then
    shift
    telegram_proxy_cli "$@"
    exit $?
fi

if [[ "${1:-}" == uninstall ]]; then
    [[ $# -eq 2 && "$2" == --force ]] || {
        warn "Использование: setup-essence.sh uninstall --force"
        exit 2
    }
    _uninstall_components false
    exit $?
fi

# ─── Точка входа ─────────────────────────────────────────────────────────────
INITIAL_CHOICE="${1:-}"
while true; do
    if [[ -n "$INITIAL_CHOICE" ]]; then
        CHOICE="$INITIAL_CHOICE"
        INITIAL_CHOICE=""
    else
        show_menu || exit 0
    fi
    case "$CHOICE" in
        b|B) install_base || warn "Базовая установка завершилась ошибкой. Повторите действие из меню." ;;
        v|V) vless_menu ;;
        h|H) hy2_menu ;;
        a|A) awg_menu ;;
        i|I) toggle_ipv6 ;;
        w|W) warp_menu ;;
        c|C) cascade_menu ;;
        k|K) show_client_config ;;
        m|M) show_server_config ;;
        u|U)
            self_update
            CURRENT_VERSION=$(tr -d '\r' 2>/dev/null < "$SCRIPT_DIR/VERSION" ||
                tr -d '\r' 2>/dev/null < "$SCRIPT_DIR/../VERSION" || echo "none")
            ;;
        s|S) subscription_menu ;;
        t|T) telegram_proxy_menu ;;
        x|X) uninstall || warn "Удаление завершилось с ошибкой; меню остаётся доступно." ;;
        0) exit 0 ;;
        *) warn "Неверный выбор." ;;
    esac
done
