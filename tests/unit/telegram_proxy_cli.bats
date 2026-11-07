#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    export TPROXY_DIR="$BATS_TEST_TMPDIR/etc-tproxy"
    export TPROXY_CONF="$TPROXY_DIR/essence.conf"
    export TPROXY_CONFIG_JSON="$TPROXY_DIR/config.json"
    export TPROXY_PROFILES_FILE="$TPROXY_DIR/profiles.json"
    export TPROXY_PROFILES_RUNTIME_FILE="$BATS_TEST_TMPDIR/run/credentials/tproxy-server.service/profiles.json"
    export TPROXY_ENV_FILE="$BATS_TEST_TMPDIR/etc-mtproxy/mtproxy.env"
    export TPROXY_MTPROXY_DIR="$BATS_TEST_TMPDIR/etc-mtproxy"
    export TPROXY_MTPROXY_SOURCE_DIR="$BATS_TEST_TMPDIR/opt/MTProxy"
    export TPROXY_RELAY_SOURCE_PATH="$BATS_TEST_TMPDIR/opt/tproxy-server-source"
    export TPROXY_SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd"
    export TPROXY_SITE_DIR="$BATS_TEST_TMPDIR/site"
    export TPROXY_CERT_DIR="$BATS_TEST_TMPDIR/ssl"
    source "$PROJECT_ROOT/common/cert.sh"
    source "$PROJECT_ROOT/setup-essence/modules/telegram-proxy.sh"
}

teardown() { teardown_test_env; }

_upstream_sha=f7a6acc4d536a787d442fd7df3ba4ebfd728f406

write_state() {
    _telegram_proxy_initialize_state
    TELEGRAM_WEB_ENABLED=true
    TELEGRAM_WEB_HOSTNAME=web.example.com
    TELEGRAM_WEB_EMAIL=operator@example.com
    TELEGRAM_WEB_TOPOLOGY=direct
    TELEGRAM_WEB_TLS_LISTEN=0.0.0.0:443
    TELEGRAM_WEB_IPV6=false
    TELEGRAM_RELAY_SOURCE_PATH="$TPROXY_RELAY_SOURCE_PATH"
    TELEGRAM_RELAY_UPSTREAM_SHA="$_upstream_sha"
    TELEGRAM_MTPROTO_ENABLED=true
    TELEGRAM_MTPROTO_IPV4=8.8.8.8
    TELEGRAM_UFW_MTPROTO_PREVIOUS=absent
    _telegram_proxy_render_mtproxy_env 0123456789abcdef0123456789abcdef
    _telegram_proxy_render_profiles 0123456789abcdef0123456789abcdef
    _telegram_proxy_state_write
}

@test "all actions return exit 3 when no managed state exists" {
    run telegram_proxy_cli connection
    [ "$status" -eq 3 ]
    run telegram_proxy_cli status
    [ "$status" -eq 3 ]
    run telegram_proxy_cli status --json
    [ "$status" -eq 3 ]
    run telegram_proxy_cli web restart
    [ "$status" -eq 3 ]
    run telegram_proxy_cli backend restart
    [ "$status" -eq 3 ]
    run telegram_proxy_cli tag show
    [ "$status" -eq 3 ]
    run telegram_proxy_cli diagnostics
    [ "$status" -eq 3 ]
}

@test "status distinguishes absence from malformed state and unmanaged remnants" {
    run telegram_proxy_cli status --json
    [ "$status" -eq 3 ]
    [ "$(printf '%s' "$output" | jq -r '.installed')" = false ]
    run telegram_proxy_cli status
    [ "$status" -eq 3 ]

    mkdir -p "$TPROXY_DIR"
    printf 'bad=state\n' > "$TPROXY_CONF"
    run telegram_proxy_cli status --json
    [ "$status" -eq 1 ]
    [[ "$output" != *'"installed":false'* ]]
    rm "$TPROXY_CONF"
    ln -s "$BATS_TEST_TMPDIR/nonexistent" "$TPROXY_PROFILES_FILE"
    run telegram_proxy_cli status --json
    [ "$status" -eq 1 ]
    [[ "$output" != *'"installed":false'* ]]
}

@test "missing env and mismatching profile secret are status errors" {
    write_state
    rm "$TPROXY_ENV_FILE"
    run telegram_proxy_cli status --json
    [ "$status" -eq 1 ]
    _telegram_proxy_render_mtproxy_env 0123456789abcdef0123456789abcdef
    _telegram_proxy_render_profiles ffffffffffffffffffffffffffffffff
    run telegram_proxy_cli status --json
    [ "$status" -eq 1 ]
    [[ "$output" != *'"installed":false'* ]]
}

@test "inactive services remain observable in valid JSON status" {
    write_state
    _telegram_proxy_service_state() { printf inactive; }
    _telegram_proxy_probe() { return 1; }
    _telegram_proxy_public_ipv4() { printf '%s' 8.8.8.8; }
    run telegram_proxy_cli status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.installed')" = true ]
    [ "$(printf '%s' "$output" | jq -r '.backend')" = inactive ]
    [ "$(printf '%s' "$output" | jq -r '.health')" = failed ]
}

@test "CLI rejects unknown grammar and forbidden force/json combinations" {
    run telegram_proxy_cli unknown
    [ "$status" -eq 2 ]
    run telegram_proxy_cli web nope
    [ "$status" -eq 2 ]
    run telegram_proxy_cli web restart --force
    [ "$status" -eq 2 ]
    run telegram_proxy_cli status --force
    [ "$status" -eq 2 ]
    run telegram_proxy_cli remove-all --force
    [ "$status" -eq 3 ]
    run telegram_proxy_cli tag set --force
    [ "$status" -eq 2 ]
    run telegram_proxy_cli connection --json
    [ "$status" -eq 2 ]
    run telegram_proxy_cli diagnostics --json
    [ "$status" -eq 2 ]
    run telegram_proxy_cli remove-all
    [ "$status" -eq 2 ]
}

@test "backend restart rejects unsupported actions options and removed direct restart grammar" {
    local grammar
    for grammar in 'backend' 'backend install' 'backend restart --force' 'backend restart --json' 'backend restart extra' 'backend --json' 'mtproto restart' 'mtproto restart --force'; do
        run telegram_proxy_cli $grammar
        [ "$status" -eq 2 ]
    done
    run telegram_proxy_backend_restart --force
    [ "$status" -eq 2 ]
    run telegram_proxy_backend_restart extra
    [ "$status" -eq 2 ]
}

@test "status JSON is one object with conditional component fields and no credentials" {
    write_state
    _telegram_proxy_service_state() { printf active; }
    _telegram_proxy_probe() { return 0; }
    _telegram_proxy_wait_endpoint() { return 0; }
    _telegram_proxy_latest_sha() { printf '%s' 0123456789012345678901234567890123456789; }
    _telegram_proxy_public_ipv4() { printf '%s' 8.8.8.8; }
    run telegram_proxy_cli status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
    [ "$(printf '%s' "$output" | jq -r '.installed')" = true ]
    [ "$(printf '%s' "$output" | jq -r '.web_enabled')" = true ]
    [ "$(printf '%s' "$output" | jq -r '.mtproto_enabled')" = true ]
    [ "$(printf '%s' "$output" | jq -r '.mtproto_port')" = 2398 ]
    [[ "$output" != *"0123456789abcdef0123456789abcdef"* ]]
    [[ "$output" != *"abcdefabcdefabcdefabcdefabcdefab"* ]]
}

@test "WEB-only and MTProto-only status omit disabled component details" {
    write_state
    TELEGRAM_MTPROTO_ENABLED=false
    TELEGRAM_MTPROTO_IPV4=""
    TELEGRAM_UFW_MTPROTO_PREVIOUS=""
    _telegram_proxy_state_write
    _telegram_proxy_probe() { return 0; }
    run telegram_proxy_cli status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.web_enabled')" = true ]
    [ "$(printf '%s' "$output" | jq -r '.mtproto_enabled')" = false ]
    [ "$(printf '%s' "$output" | jq -r 'has("mtproto_ipv4")')" = false ]
    _telegram_proxy_initialize_state
    TELEGRAM_MTPROTO_ENABLED=true
    TELEGRAM_MTPROTO_IPV4=8.8.8.8
    TELEGRAM_UFW_MTPROTO_PREVIOUS=absent
    _telegram_proxy_state_write
    rm "$TPROXY_PROFILES_FILE"
    _telegram_proxy_public_ipv4() { printf '%s' 8.8.8.8; }
    run telegram_proxy_cli status --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.web_enabled')" = false ]
    [ "$(printf '%s' "$output" | jq -r '.mtproto_enabled')" = true ]
    [ "$(printf '%s' "$output" | jq -r 'has("web_hostname")')" = false ]
    [[ "$output" != *0123456789abcdef0123456789abcdef* ]]
}

@test "only Connection exposes enabled component links and raw shared secret" {
    write_state
    _telegram_proxy_service_state() { printf active; }
    _telegram_proxy_probe() { return 0; }
    _telegram_proxy_public_ipv4() { printf '%s' 8.8.8.8; }
    run telegram_proxy_cli status --json
    [[ "$output" != *"0123456789abcdef0123456789abcdef"* ]]
    run telegram_proxy_cli connection
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://t.me/proxy?server=8.8.8.8&port=2398&secret=0123456789abcdef0123456789abcdef"* ]]
}

@test "tag show is the only non-connection output that exposes the tag" {
    write_state
    _telegram_proxy_render_mtproxy_env 0123456789abcdef0123456789abcdef "-P ABCDEFABCDEFABCDEFABCDEFABCDEFAB"
    TELEGRAM_TAG_CONFIGURED=true
    _telegram_proxy_state_write
    run telegram_proxy_cli status --json
    [[ "$output" != *"ABCDEFABCDEFABCDEFABCDEFABCDEFAB"* ]]
    run telegram_proxy_cli tag show
    [ "$status" -eq 0 ]
    [ "$output" = abcdefabcdefabcdefabcdefabcdefab ]
}

@test "remove-all is explicit force-only CLI action" {
    run telegram_proxy_cli remove-all
    [ "$status" -eq 2 ]
    run telegram_proxy_cli remove-all --json --force
    [ "$status" -eq 2 ]
    run telegram_proxy_cli remove-all --force
    [ "$status" -eq 3 ]
}

@test "strict grouped CLI rejects malformed forms before any handler side effect" {
    write_state
    cp "$TPROXY_CONF" "$BATS_TEST_TMPDIR/before-state"
    cp "$TPROXY_ENV_FILE" "$BATS_TEST_TMPDIR/before-env"
    local marker="$BATS_TEST_TMPDIR/handler-called" grammar handler
    for handler in telegram_proxy_web_cli telegram_proxy_mtproto_cli telegram_proxy_backend_restart \
        telegram_proxy_status telegram_proxy_connection telegram_proxy_rotate_secret \
        telegram_proxy_tag_show telegram_proxy_tag_set telegram_proxy_tag_clear \
        telegram_proxy_remove_all telegram_proxy_diagnostics telegram_proxy_menu; do
        eval "$handler() { touch \"\$marker\"; return 99; }"
    done
    for grammar in 'web' 'web nope --force' 'backend --json' 'status --force' 'status extra' \
        'rotate-secret --json' 'tag' 'remove-all' 'web update --force' \
        'mtproto refresh-ip --force' 'menu extra' 'tag clear --force --force'; do
        run telegram_proxy_cli $grammar
        [ "$status" -eq 2 ]
        [[ "$output" == *Использование* ]]
        [ ! -e "$marker" ]
    done
    run telegram_proxy_cli
    [ "$status" -eq 2 ]
    run telegram_proxy_cli ''
    [ "$status" -eq 2 ]
    run telegram_proxy_cli rotate-secret '' --force
    [ "$status" -eq 2 ]
    [ ! -e "$marker" ]
    cmp "$BATS_TEST_TMPDIR/before-state" "$TPROXY_CONF"
    cmp "$BATS_TEST_TMPDIR/before-env" "$TPROXY_ENV_FILE"
}

@test "menu CLI accepts EOF without installing or exposing credentials" {
    run telegram_proxy_cli menu </dev/null
    [ "$status" -eq 0 ]
    [ ! -e "$TPROXY_CONF" ]
    [[ "$output" != *'secret='* ]]
}
