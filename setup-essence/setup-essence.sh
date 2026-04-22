#!/bin/bash

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
source "$SCRIPT_DIR/modules/uninstall.sh"

# ─── Проверка root ───────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Запустите скрипт от root: sudo bash $0"

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
    local latest
    latest=$(latest_version)

    echo ""
    local _domain
    _domain=$(grep '^DOMAIN=' /etc/mihomo/reality.conf 2>/dev/null | cut -d= -f2)
    box_top
    box_center "Essence Setup"
    local _ver="версия: ${CURRENT_VERSION}"
    box_center "$_ver" "${DIM}${_ver}${NC}"
    if [[ -n "$_domain" ]]; then
        box_center "$_domain" "${CYAN}${_domain}${NC}"
    fi
    if has_update "$CURRENT_VERSION"; then
        local _upd="↑ ${latest} — пункт 10"
        box_center "$_upd" "${YELLOW}↑ ${latest} — пункт 10${NC}"
    fi
    # Reality
    if [[ -f /etc/mihomo/reality.conf ]]; then
        local _rmode _sni
        _rmode=$(grep '^MODE=' /etc/mihomo/reality.conf 2>/dev/null | cut -d= -f2)
        _sni=$(grep '^SNI_DOMAIN=' /etc/mihomo/reality.conf 2>/dev/null | cut -d= -f2)
        if [[ -n "$_rmode" && -n "$_sni" ]]; then
            local _rline
            if [[ "$_rmode" == "self-steal" ]]; then
                _rline="Reality: self-steal"
            else
                _rline="Reality SNI: ${_sni}"
            fi
            box_center "$_rline" "${DIM}${_rline}${NC}"
        fi
    fi
    # Протоколы
    if [[ -f /etc/mihomo/config.yaml ]]; then
        local _vless=() _other=()
        grep -q '# --- vless-tcp ---' /etc/mihomo/config.yaml 2>/dev/null && _vless+=("TCP")
        grep -q '# --- vless-xhttp ---' /etc/mihomo/config.yaml 2>/dev/null && _vless+=("xHTTP")
        grep -q '# --- vless-grpc ---' /etc/mihomo/config.yaml 2>/dev/null && _vless+=("gRPC")
        grep -q '# --- hy2 ---' /etc/mihomo/config.yaml 2>/dev/null && _other+=("HY2")
        [[ -f /etc/amnezia/amneziawg/awg0.conf ]] && _other+=("AWG")
        grep -q '# --- warp ---' /etc/mihomo/config.yaml 2>/dev/null && _other+=("WARP")
        if [[ ${#_vless[@]} -gt 0 || ${#_other[@]} -gt 0 ]]; then
            local _parts=()
            if [[ ${#_vless[@]} -gt 0 ]]; then
                local _vstr
                _vstr=$(IFS=', '; echo "${_vless[*]}")
                _parts+=("VLESS: ${_vstr}")
            fi
            [[ ${#_other[@]} -gt 0 ]] && _parts+=("$(IFS=', '; echo "${_other[*]}")")
            local _pstr
            _pstr=$(IFS=' | '; echo "${_parts[*]}")
            box_mid
            box_center "$_pstr" "${GREEN}${_pstr}${NC}"
        fi
    fi
    box_bot
    echo ""
    echo -e "  ${GREEN}1)${NC} Базовая установка"
    echo -e "  ${GREEN}2)${NC} VLESS Reality"
    echo -e "  ${GREEN}3)${NC} Hysteria2"
    echo -e "  ${GREEN}4)${NC} AmneziaWG 2.0"
    echo -e "  ${YELLOW}5)${NC} IPv6"
    echo -e "  ${YELLOW}6)${NC} WARP"
    echo -e "  ${YELLOW}7)${NC} Каскады нод"
    echo -e "  ${CYAN}8)${NC} Показать клиентский конфиг"
    echo -e "  ${CYAN}9)${NC} Показать серверный конфиг"
    echo -e "  ${CYAN}10)${NC} Обновить скрипты"
    echo -e "  ${GREEN}s)${NC} Subscription hosting"
    echo -e "  ${RED}u)${NC} Удалить всё установленное"
    echo -e "  ${NC}0)${NC} Выход"
    echo ""
    read -rp "Выберите пункт [0-10, s, u]: " CHOICE
}

# ─── Точка входа ─────────────────────────────────────────────────────────────
INITIAL_CHOICE="${1:-}"
while true; do
    if [[ -n "$INITIAL_CHOICE" ]]; then
        CHOICE="$INITIAL_CHOICE"
        INITIAL_CHOICE=""
    else
        show_menu
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
        10) self_update; CURRENT_VERSION=$(tr -d '\r' < "$SCRIPT_DIR/VERSION" 2>/dev/null || tr -d '\r' < "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "none") ;;
        s|S) subscription_menu ;;
        u) uninstall ;;
        0) echo "Выход."; exit 0 ;;
        *) warn "Неверный выбор: $CHOICE" ;;
    esac
done
