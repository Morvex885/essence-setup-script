#!/bin/bash
# Публичные адреса определяются один раз, вне перерисовки меню.
_MENU_ADDRESS_STARTED=false
_MENU_ADDRESS_DIR=""
_MENU_NODE_IPV4=""
_MENU_NODE_IPV6=""
_MENU_IPV4_STATE=pending
_MENU_IPV6_STATE=pending
_MENU_ADDRESS_PIDS=()

_menu_address_cleanup() {
    local pid
    for pid in "${_MENU_ADDRESS_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    _MENU_ADDRESS_PIDS=()
    [[ -z "$_MENU_ADDRESS_DIR" ]] || rm -rf -- "$_MENU_ADDRESS_DIR"
    _MENU_ADDRESS_DIR=""
}

menu_address_start() {
    [[ "$_MENU_ADDRESS_STARTED" == false ]] || return 0
    _MENU_ADDRESS_STARTED=true
    _MENU_ADDRESS_DIR=$(umask 077; mktemp -d) || {
        _MENU_IPV4_STATE=failed
        _MENU_IPV6_STATE=failed
        warn "Не удалось запустить определение публичного IP."
        return 1
    }
    register_exit_cleanup _menu_address_cleanup || {
        _menu_address_cleanup
        _MENU_IPV4_STATE=failed
        _MENU_IPV6_STATE=failed
        warn "Не удалось запустить определение публичного IP."
        return 1
    }
    (
        umask 077
        address=$(_telegram_proxy_public_ipv4 2>/dev/null | tr -d '[:space:]')
        if _telegram_proxy_valid_public_ipv4 "$address"; then
            printf '%s\n' "$address" > "$_MENU_ADDRESS_DIR/ipv4.part"
        else
            : > "$_MENU_ADDRESS_DIR/ipv4.part"
        fi
        mv -- "$_MENU_ADDRESS_DIR/ipv4.part" "$_MENU_ADDRESS_DIR/ipv4"
    ) &
    _MENU_ADDRESS_PIDS+=("$!")
    (
        umask 077
        address=$(_telegram_proxy_public_ipv6 2>/dev/null | tr -d '[:space:]')
        if _warp_valid_ipv6 "$address"; then
            printf '%s\n' "$address" > "$_MENU_ADDRESS_DIR/ipv6.part"
        else
            : > "$_MENU_ADDRESS_DIR/ipv6.part"
        fi
        mv -- "$_MENU_ADDRESS_DIR/ipv6.part" "$_MENU_ADDRESS_DIR/ipv6"
    ) &
    _MENU_ADDRESS_PIDS+=("$!")
    return 0
}

menu_address_read() {
    if [[ "$_MENU_IPV4_STATE" == pending && -f "$_MENU_ADDRESS_DIR/ipv4" ]]; then
        IFS= read -r _MENU_NODE_IPV4 < "$_MENU_ADDRESS_DIR/ipv4" || _MENU_NODE_IPV4=""
        if [[ -n "$_MENU_NODE_IPV4" ]]; then _MENU_IPV4_STATE=ready; else _MENU_IPV4_STATE=failed; fi
    fi
    if [[ "$_MENU_IPV6_STATE" == pending && -f "$_MENU_ADDRESS_DIR/ipv6" ]]; then
        IFS= read -r _MENU_NODE_IPV6 < "$_MENU_ADDRESS_DIR/ipv6" || _MENU_NODE_IPV6=""
        if [[ -n "$_MENU_NODE_IPV6" ]]; then _MENU_IPV6_STATE=ready; else _MENU_IPV6_STATE=failed; fi
    fi
    return 0
}
