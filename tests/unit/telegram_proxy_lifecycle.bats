#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    export TPROXY_DIR="$BATS_TEST_TMPDIR/etc-tproxy"
    export TPROXY_CONF="$TPROXY_DIR/essence.conf"
    export TPROXY_CONFIG_JSON="$TPROXY_DIR/config.json"
    export TPROXY_PROFILES_FILE="$TPROXY_DIR/profiles.json"
    export TPROXY_ENV_FILE="$BATS_TEST_TMPDIR/etc-mtproxy/mtproxy.env"
    export TPROXY_MTPROXY_DIR="$BATS_TEST_TMPDIR/opt/mtproxy"
    export TPROXY_MTPROXY_SOURCE_DIR="$BATS_TEST_TMPDIR/opt/MTProxy"
    export TPROXY_RELAY_SOURCE_PATH="$BATS_TEST_TMPDIR/opt/tproxy-server-source"
    export TPROXY_SITE_DIR="$BATS_TEST_TMPDIR/site"
    export TPROXY_NGINX_SITE="$BATS_TEST_TMPDIR/nginx/sites-available/telegram"
    export TPROXY_NGINX_ENABLED="$BATS_TEST_TMPDIR/nginx/sites-enabled/telegram"
    export TPROXY_NGINX_ACME_SITE="$BATS_TEST_TMPDIR/nginx/sites-available/telegram-acme"
    export TPROXY_NGINX_CONF="$BATS_TEST_TMPDIR/nginx/nginx.conf"
    export TPROXY_CERT_DIR="$BATS_TEST_TMPDIR/ssl"
    export TPROXY_WEBROOT_BASE="$BATS_TEST_TMPDIR/www"
    export TPROXY_SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd"
    export TPROXY_FIREWALL_FILE="$BATS_TEST_TMPDIR/etc-tproxy/firewall.nft"
    export TPROXY_REFRESH_BIN="$BATS_TEST_TMPDIR/bin/refresh"
    export TPROXY_UNIT_RELAY=telegram-relay.service
    export TPROXY_UNIT_MTPROXY=telegram-mtproxy.service
    export TPROXY_UNIT_FIREWALL=telegram-firewall.service
    export TPROXY_UNIT_REFRESH=telegram-refresh.service
    export TPROXY_UNIT_TIMER=telegram-refresh.timer
    source "$PROJECT_ROOT/setup-essence/modules/telegram-proxy.sh"
}

teardown() { teardown_test_env; }

@test "backend checkout is staged at the pinned commit and never tracks master" {
    local fakebin="$BATS_TEST_TMPDIR/bin" log="$BATS_TEST_TMPDIR/git.log"
    local pinned=f7a6acc4d536a787d442fd7df3ba4ebfd728f406
    mkdir -p "$fakebin"
    cat > "$fakebin/git" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GIT_LOG"
case "$1" in
    clone)
        dest=""
        for arg in "$@"; do dest="$arg"; done
        mkdir -p "$dest/.git"
        exit 0
        ;;
    -C)
        if [[ "$*" == *"rev-parse HEAD"* ]]; then
            printf '%s\n' "$GIT_PIN"
        fi
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
    chmod 755 "$fakebin/git"
    export GIT_LOG="$log" GIT_PIN="$pinned" PATH="$fakebin:$PATH"
    local rc
    local stage="$BATS_TEST_TMPDIR/stage"
    if _telegram_proxy_clone_upstream "$stage"; then rc=0; else rc=$?; fi
    [ "$rc" -eq 0 ]
    [[ "$(cat "$log")" == *"fetch --depth 1 origin $pinned"* ]]
    [[ "$(cat "$log")" == *"checkout --detach $pinned"* ]]
    [[ "$(cat "$log")" != *" origin master"* ]]

}
@test "WEB-only removal cleans WEB artifacts without touching shared MTProto state" {
    mkdir -p "$TPROXY_DIR" "$TPROXY_RELAY_SOURCE_PATH" "$TPROXY_CERT_DIR/web.example.com" "$TPROXY_WEBROOT_BASE/web.example.com" "$TPROXY_MTPROXY_DIR" "$(dirname "$TPROXY_NGINX_SITE")" "$(dirname "$TPROXY_NGINX_ENABLED")"
    touch "$TPROXY_CONFIG_JSON" "$TPROXY_PROFILES_FILE" "$TPROXY_NGINX_SITE" "$TPROXY_NGINX_ENABLED" "$TPROXY_RELAY_SOURCE_PATH/source"
    _telegram_proxy_initialize_state
    TELEGRAM_WEB_ENABLED=true TELEGRAM_MTPROTO_ENABLED=false TELEGRAM_WEB_HOSTNAME=web.example.com
    TPROXY_CREATED_USER=false
    _telegram_proxy_component_enabled() { [[ "$1" == web ]]; }
    _telegram_proxy_snapshot_paths() { return 0; }
    _telegram_proxy_discard_snapshot() { return 0; }
    systemctl() { true; }
    nginx() { true; }
    _telegram_proxy_cleanup_backend() { return 0; }
    telegram_proxy_web_remove --force
    [ "$?" -eq 0 ]
    [ ! -e "$TPROXY_CONFIG_JSON" ]
    [ ! -e "$TPROXY_PROFILES_FILE" ]
    [ ! -e "$TPROXY_RELAY_SOURCE_PATH" ]
    [ -z "$TELEGRAM_WEB_HOSTNAME" ]
}

@test "MTProto removal from a combined install preserves WEB and rewrites shared state" {
    mkdir -p "$TPROXY_DIR" "$TPROXY_RELAY_SOURCE_PATH" "$(dirname "$TPROXY_FIREWALL_FILE")"
    touch "$TPROXY_CONF" "$TPROXY_FIREWALL_FILE"
    _telegram_proxy_initialize_state
    TELEGRAM_WEB_ENABLED=true TELEGRAM_MTPROTO_ENABLED=true
    TELEGRAM_MTPROTO_IPV4=8.8.8.8 TELEGRAM_UFW_MTPROTO_PREVIOUS=absent
    _telegram_proxy_component_enabled() { [[ "$1" == mtproto ]]; }
    _telegram_proxy_snapshot_paths() { return 0; }
    _telegram_proxy_discard_snapshot() { return 0; }
    _telegram_proxy_ufw_apply_port() { return 0; }
    _telegram_proxy_render_firewall() { return 0; }
    _telegram_proxy_state_write() { printf '%s\n' state-written > "$BATS_TEST_TMPDIR/state-write"; return 0; }
    systemctl() { true; }
    telegram_proxy_mtproto_remove --force
    [ "$?" -eq 0 ]
    [ "$TELEGRAM_WEB_ENABLED" = true ]
    [ "$TELEGRAM_MTPROTO_ENABLED" = false ]
    [ -z "$TELEGRAM_MTPROTO_IPV4" ]
    [ -s "$BATS_TEST_TMPDIR/state-write" ]
}

@test "combined backend cleanup removes units, runtime directories, and firewall artifacts" {
    mkdir -p "$TPROXY_DIR" "$(dirname "$TPROXY_ENV_FILE")" "$TPROXY_MTPROXY_DIR" "$TPROXY_MTPROXY_SOURCE_DIR" "$TPROXY_RELAY_SOURCE_PATH" "$TPROXY_SYSTEMD_DIR" "$(dirname "$TPROXY_REFRESH_BIN")"
    touch "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_RELAY" "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_FIREWALL" "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_REFRESH" "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_TIMER" "$TPROXY_REFRESH_BIN" "$TPROXY_FIREWALL_FILE" "$TPROXY_ENV_FILE"
    systemctl() { true; }
    nft() { return 1; }
    run _telegram_proxy_cleanup_backend
    [ "$status" -eq 0 ]
    [ ! -e "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" ]
    [ ! -e "$TPROXY_RELAY_SOURCE_PATH" ]
    [ ! -e "$TPROXY_MTPROXY_DIR" ]
    [ ! -e "$TPROXY_FIREWALL_FILE" ]
}

@test "remote batch failure aggregate remains failure when one worker fails" {
    load '../helpers/mock_ssh'
    reset_ssh_mocks
    CURRENT_VERSION=1.2.3
    REMOTE_DIR=/root/essence-setup
    TELEGRAM_PROXY_REMOTE_DIR="$REMOTE_DIR"
    source "$PROJECT_ROOT/remote-control/modules/telegram-proxy.sh"
    node_load() { NODE_NAME="node-$1"; SERVER_IP=127.0.0.1; SERVER_PORT=22; SERVER_USER=root; SERVER_AUTH=key; SERVER_PASS=; return 0; }
    ssh_run() {
        case "$*" in
            *VERSION*) printf '%s\n' 1.2.3; return 0 ;;
            *) return 1 ;;
        esac
    }
    run telegram_proxy_remote_batch web restart false 1 2
    [ "$status" -eq 1 ]
    [[ "$output" == *FAILED* ]]
}
