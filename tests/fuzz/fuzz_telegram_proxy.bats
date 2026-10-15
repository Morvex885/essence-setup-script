#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    setup_test_env
    source_common
    export TPROXY_DIR="$BATS_TEST_TMPDIR/tproxy"
    export TPROXY_CONF="$TPROXY_DIR/essence.conf"
    source "$PROJECT_ROOT/setup-essence/modules/telegram-proxy.sh"
    marker="$BATS_TEST_TMPDIR/handler-called"
    local handler
    for handler in telegram_proxy_web_cli telegram_proxy_mtproto_cli telegram_proxy_backend_restart \
        telegram_proxy_status telegram_proxy_connection telegram_proxy_rotate_secret \
        telegram_proxy_tag_show telegram_proxy_tag_set telegram_proxy_tag_clear \
        telegram_proxy_remove_all telegram_proxy_diagnostics telegram_proxy_menu; do
        eval "$handler() { touch \"\$marker\"; return 99; }"
    done
}

teardown() { teardown_test_env; }

@test "fuzz malformed Telegram CLI operands never reach a handler" {
    local i token grammar
    local forms=('menu' 'web restart' 'mtproto refresh-ip' 'status --json' 'rotate-secret --force' 'tag show' 'remove-all --force')
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        case "$((i % 4))" in
            0) token="$(random_ascii "$((RANDOM % 24 + 1))")" ;;
            1) token="$(random_utf8 "$((RANDOM % 12 + 1))")" ;;
            2) token=$'\r' ;;
            3) token="--$(random_ascii "$((RANDOM % 16 + 1))")" ;;
        esac
        grammar="${forms[$((RANDOM % ${#forms[@]}))]}"
        run telegram_proxy_cli $grammar "$token"
        [ "$status" -eq 2 ]
        [ ! -e "$marker" ]
        [ ! -e "$TPROXY_CONF" ]
        run telegram_proxy_cli rotate-secret '' "$token"
        [ "$status" -eq 2 ]
        [ ! -e "$marker" ]
    done
}
