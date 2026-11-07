#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    source_common
    export TPROXY_CONF="$BATS_TEST_TMPDIR/essence.conf"
    export TPROXY_ENV_FILE="$BATS_TEST_TMPDIR/mtproxy.env"
    export TPROXY_RELAY_SOURCE_PATH="$BATS_TEST_TMPDIR/relay"
    export TPROXY_MTPROXY_SOURCE_DIR="$BATS_TEST_TMPDIR/MTProxy"
    source "$PROJECT_ROOT/setup-essence/modules/telegram-proxy.sh"
    source "$PROJECT_ROOT/setup-essence/modules/uninstall.sh"
}

teardown() { teardown_test_env; }

@test "uninstall cancellation leaves Telegram Proxy untouched" {
    : > "$TPROXY_CONF"
    confirm_yn() { return 1; }
    telegram_proxy_remove_all() { echo called > "$BATS_TEST_TMPDIR/called"; return 0; }
    run uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/called" ]
}

@test "uninstall stops before other components when Telegram removal fails" {
    : > "$TPROXY_CONF"
    confirm_yn() { return 0; }
    telegram_proxy_remove_all() { return 1; }
    systemctl() { echo systemctl-called > "$BATS_TEST_TMPDIR/systemctl"; return 0; }
    run uninstall
    [ "$status" -eq 1 ]
    [ ! -e "$BATS_TEST_TMPDIR/systemctl" ]
    [[ "$output" == *"Не удалось удалить Telegram Proxy"* ]]
}

_load_fixture_uninstall() {
    local root="$BATS_TEST_TMPDIR/uninstall-root" copy="$BATS_TEST_TMPDIR/uninstall.sh"
    mkdir -p "$root/etc/mihomo" "$root/etc/nginx/sites-available" \
        "$root/etc/nginx/sites-enabled" "$root/etc/systemd/system" \
        "$root/etc/sysctl.d" "$root/etc/ssh" "$root/usr/local/bin" \
        "$root/root" "$root/var/www"
    sed -e "s|/etc|$root/etc|g" -e "s|/root|$root/root|g" \
        -e "s|/usr/local/bin|$root/usr/local/bin|g" \
        -e "s|/var/www|$root/var/www|g" \
        "$PROJECT_ROOT/setup-essence/modules/uninstall.sh" > "$copy"
    source "$copy"
    export FIXTURE_UNINSTALL_ROOT="$root"
    export TPROXY_CONF="$root/etc/tproxy-server/essence.conf"
    export TPROXY_ENV_FILE="$root/etc/mtproxy/mtproxy.env"
    export TPROXY_RELAY_SOURCE_PATH="$root/opt/tproxy-server-source"
    export TPROXY_MTPROXY_SOURCE_DIR="$root/opt/MTProxy"
    mkdir -p "$root/opt" "$root/etc/tproxy-server"
    systemctl() { return 0; }
    ufw() { return 0; }
    sysctl() { return 0; }
    awg-quick() { return 0; }
    confirm_yn() { return 0; }
}

@test "Telegram rc3 allows complete fixture cleanup" {
    _load_fixture_uninstall
    : > "$TPROXY_RELAY_SOURCE_PATH"
    : > "$FIXTURE_UNINSTALL_ROOT/etc/mihomo/config.yaml"
    telegram_proxy_remove_all() { return 3; }
    uninstall
    [[ ! -e "$FIXTURE_UNINSTALL_ROOT/etc/mihomo/config.yaml" ]]
}

@test "Telegram rc1 stops before deleting fixture components" {
    _load_fixture_uninstall
    : > "$TPROXY_RELAY_SOURCE_PATH"
    : > "$FIXTURE_UNINSTALL_ROOT/etc/mihomo/config.yaml"
    telegram_proxy_remove_all() { return 1; }
    if uninstall; then
        return 1
    fi
    [[ -e "$FIXTURE_UNINSTALL_ROOT/etc/mihomo/config.yaml" ]]
}

@test "subscription cleanup runs before Mihomo directory removal" {
    _load_fixture_uninstall
    local sub_conf="$FIXTURE_UNINSTALL_ROOT/etc/mihomo/subscription.conf"
    printf 'SUB_MODE=standalone\\nSUB_PORT=2096\\nSUB_HOSTNAME=subs.example.com\\nSUB_DIR=%s\\n' \
        "$FIXTURE_UNINSTALL_ROOT/var/www/subs" > "$sub_conf"
    SUB_CONF="$sub_conf"
    [[ -f "$SUB_CONF" ]]
    remove_subscription() {
        [[ -f "$SUB_CONF" ]] || return 1
        printf '%s\n' called > "$FIXTURE_UNINSTALL_ROOT/subscription-called"
        rm -f "$SUB_CONF"
    }
    uninstall
    [[ "$(cat "$FIXTURE_UNINSTALL_ROOT/subscription-called")" == called ]]
}
