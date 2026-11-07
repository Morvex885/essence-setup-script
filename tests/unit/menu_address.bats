#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/setup-essence/modules/warp.sh"
    source "$PROJECT_ROOT/setup-essence/modules/telegram-proxy.sh"
    source "$PROJECT_ROOT/setup-essence/modules/menu-address.sh"
    export DETECTOR_CALLS="$BATS_TEST_TMPDIR/detector-calls"
    export DETECTOR_GATE="$BATS_TEST_TMPDIR/detector-gate"
    : > "$DETECTOR_CALLS"
    _telegram_proxy_public_ipv4() {
        printf 'ipv4\n' >> "$DETECTOR_CALLS"
        while [[ ! -e "$DETECTOR_GATE" ]]; do sleep 0.02; done
        printf '8.8.8.8\n'
    }
    _telegram_proxy_public_ipv6() {
        printf 'ipv6\n' >> "$DETECTOR_CALLS"
        while [[ ! -e "$DETECTOR_GATE" ]]; do sleep 0.02; done
        printf '2606:4700:4700::1111\n'
    }
}

teardown() {
    : > "$DETECTOR_GATE"
    _menu_address_cleanup
    teardown_test_env
}

@test "menu address reads pending without waiting and starts detectors once" {
    menu_address_start
    menu_address_read
    [[ "$_MENU_IPV4_STATE" == pending && "$_MENU_IPV6_STATE" == pending ]]
    [[ -z "$_MENU_NODE_IPV4" && -z "$_MENU_NODE_IPV6" ]]
    menu_address_start
    : > "$DETECTOR_GATE"
    wait "${_MENU_ADDRESS_PIDS[@]}"
    menu_address_read
    [[ "$_MENU_IPV4_STATE" == ready && "$_MENU_NODE_IPV4" == 8.8.8.8 ]]
    [[ "$_MENU_IPV6_STATE" == ready && "$_MENU_NODE_IPV6" == 2606:4700:4700::1111 ]]
    menu_address_start
    menu_address_read
    [[ "$(wc -l < "$DETECTOR_CALLS" | tr -d ' ')" == 2 ]]
}

@test "invalid addresses produce completed failed states rather than pending" {
    _telegram_proxy_public_ipv4() { printf 'not-an-ip\n'; return 1; }
    _telegram_proxy_public_ipv6() { return 1; }
    menu_address_start
    wait "${_MENU_ADDRESS_PIDS[@]}"
    menu_address_read
    [[ "$_MENU_IPV4_STATE" == failed && "$_MENU_IPV6_STATE" == failed ]]
    [[ -z "$_MENU_NODE_IPV4" && -z "$_MENU_NODE_IPV6" ]]
}

@test "address directory failure does not launch detectors or leave pending state" {
    mktemp() { return 1; }
    run menu_address_start
    assert_failure 1
    [[ ! -s "$DETECTOR_CALLS" ]]
    if menu_address_start; then return 1; fi
    [[ "$_MENU_IPV4_STATE" == failed && "$_MENU_IPV6_STATE" == failed ]]
    [[ -z "$_MENU_ADDRESS_DIR" ]]
}

@test "address cleanup removes worker files and the private directory" {
    : > "$DETECTOR_GATE"
    menu_address_start
    wait "${_MENU_ADDRESS_PIDS[@]}"
    local directory="$_MENU_ADDRESS_DIR"
    [[ -d "$directory" ]]
    _menu_address_cleanup
    [[ ! -e "$directory" && -z "$_MENU_ADDRESS_DIR" ]]
    [[ "${#_MENU_ADDRESS_PIDS[@]}" == 0 ]]
}
