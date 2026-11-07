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
    local latest _domain _ver _upd _rmode _sni _rline _vless=() _other=() _vstr _pstr
    latest=$(latest_version)

    echo ""
    _domain=$(grep '^DOMAIN=' /etc/mihomo/reality.conf 2>/dev/null | cut -d= -f2)
    box_top
    box_center "Essence Setup"
    _ver="версия: ${CURRENT_VERSION}"
    box_center "$_ver" "${DIM}${_ver}${NC}"
    [[ -n "$_domain" ]] && box_line " Домен: ${_domain}"
    if has_update "$CURRENT_VERSION"; then
        _upd="↑ ${latest} — пункт 10"
        box_line "$_upd" "${YELLOW}${_upd}${NC}"
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
            box_line "$_rline" "${DIM}${_rline}${NC}"
        fi
    fi
    if _telegram_proxy_component_enabled web; then
        box_line " WEB: включён" " ${GREEN}WEB: включён${NC}"
    else
        box_line " WEB: выключен" " ${DIM}WEB: выключен${NC}"
    fi
    if _telegram_proxy_component_enabled mtproto; then
        box_line " MTProto: включён" " ${GREEN}MTProto: включён${NC}"
    else
        box_line " MTProto: выключен" " ${DIM}MTProto: выключен${NC}"
    fi
    if [[ -f /etc/mihomo/config.yaml ]]; then
        grep -q '# --- vless-tcp ---' /etc/mihomo/config.yaml 2>/dev/null && _vless+=("TCP")
        grep -q '# --- vless-xhttp ---' /etc/mihomo/config.yaml 2>/dev/null && _vless+=("xHTTP")
        grep -q '# --- vless-grpc ---' /etc/mihomo/config.yaml 2>/dev/null && _vless+=("gRPC")
        grep -q '# --- hy2 ---' /etc/mihomo/config.yaml 2>/dev/null && _other+=("HY2")
        [[ -f /etc/amnezia/amneziawg/awg0.conf ]] && _other+=("AWG")
        grep -q '# --- warp ---' /etc/mihomo/config.yaml 2>/dev/null && _other+=("WARP")
        if [[ ${#_vless[@]} -gt 0 || ${#_other[@]} -gt 0 ]]; then
            local _parts=()
            [[ ${#_vless[@]} -gt 0 ]] && _parts+=("VLESS: $(IFS=', '; echo "${_vless[*]}")")
            [[ ${#_other[@]} -gt 0 ]] && _parts+=("$(IFS=', '; echo "${_other[*]}")")
            _pstr=$(IFS=' | '; echo "${_parts[*]}")
            box_mid
            box_line " $_pstr" " ${GREEN}${_pstr}${NC}"
        fi
    fi
    box_mid
    menu_item 1 "Базовая установка" GREEN
    menu_item 2 "VLESS Reality" GREEN
    menu_item 3 "Hysteria2" GREEN
    menu_item 4 "AmneziaWG 3.1" GREEN
    menu_item 5 "IPv6" YELLOW
    menu_item 6 "WARP" YELLOW
    menu_item 7 "Каскады нод" YELLOW
    menu_item 8 "Показать клиентский конфиг" CYAN
    menu_item 9 "Показать серверный конфиг" CYAN
    menu_item 10 "Обновить скрипты" YELLOW
    menu_item s "Хостинг подписок" CYAN
    menu_item t "Telegram Proxy" CYAN
    menu_item u "Удалить всё установленное" RED
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
        1) install_base ;;
        2) vless_menu ;;
        3) hy2_menu ;;
        4) awg_menu ;;
        5) toggle_ipv6 ;;
        6) warp_menu ;;
        7) cascade_menu ;;
        8) show_client_config ;;
        9) show_server_config ;;
        10)
            self_update
            CURRENT_VERSION=$(tr -d '\r' < "$SCRIPT_DIR/VERSION" 2>/dev/null ||
                tr -d '\r' < "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "none")
            ;;
        s|S) subscription_menu ;;
        t|T) telegram_proxy_menu ;;
        u|U) uninstall || warn "Удаление завершилось с ошибкой; меню остаётся доступно." ;;
        0) exit 0 ;;
        *) warn "Неверный выбор." ;;
    esac
done
