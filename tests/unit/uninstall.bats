#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    export TPROXY_CONF="$BATS_TEST_TMPDIR/essence.conf"
    export TPROXY_ENV_FILE="$BATS_TEST_TMPDIR/mtproxy.env"
    export TPROXY_RELAY_SOURCE_PATH="$BATS_TEST_TMPDIR/relay"
    export TPROXY_MTPROXY_SOURCE_DIR="$BATS_TEST_TMPDIR/MTProxy"
    source "$PROJECT_ROOT/setup-essence/modules/telegram-proxy.sh"
    source "$PROJECT_ROOT/setup-essence/modules/uninstall.sh"
    : > "$TPROXY_CONF"
}

teardown() { teardown_test_env; }

@test "uninstall cancellation leaves Telegram Proxy untouched" {
    confirm_yn() { return 1; }
    telegram_proxy_remove_all() { echo called > "$BATS_TEST_TMPDIR/called"; return 0; }
    run uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/called" ]
}

@test "uninstall stops before other components when Telegram removal fails" {
    confirm_yn() { return 0; }
    telegram_proxy_remove_all() { return 1; }
    systemctl() { echo systemctl-called > "$BATS_TEST_TMPDIR/systemctl"; return 0; }
    run uninstall
    [ "$status" -eq 1 ]
    [ ! -e "$BATS_TEST_TMPDIR/systemctl" ]
    [[ "$output" == *"Не удалось удалить Telegram Proxy"* ]]
}
