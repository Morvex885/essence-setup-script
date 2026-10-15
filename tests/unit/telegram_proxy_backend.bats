#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    source "$PROJECT_ROOT/common/cert.sh"
    export TMPDIR="$BATS_TEST_TMPDIR"
    export TPROXY_DIR="$BATS_TEST_TMPDIR/tproxy"
    export TPROXY_CONF="$TPROXY_DIR/essence.conf"
    export TPROXY_ENV_FILE="$BATS_TEST_TMPDIR/mtproxy/env"
    export TPROXY_MTPROXY_DIR="$BATS_TEST_TMPDIR/mtproxy"
    export TPROXY_MTPROXY_SOURCE_DIR="$BATS_TEST_TMPDIR/native"
    export TPROXY_RELAY_SOURCE_PATH="$BATS_TEST_TMPDIR/relay"
    export TPROXY_SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd"
    export TPROXY_FIREWALL_FILE="$TPROXY_DIR/firewall.nft"
    export TPROXY_REFRESH_BIN="$BATS_TEST_TMPDIR/refresh"
    export TPROXY_PROFILES_FILE="$TPROXY_DIR/profiles.json"
    export TPROXY_TOKEN_KEY="$TPROXY_DIR/token.key"
    export TPROXY_CONFIG_JSON="$TPROXY_DIR/config.json"
    export TPROXY_SITE_DIR="$BATS_TEST_TMPDIR/site"
    export TPROXY_BIN="$BATS_TEST_TMPDIR/bin/relay"
    export TPROXY_NGINX_SITE="$BATS_TEST_TMPDIR/nginx/site"
    export TPROXY_NGINX_ENABLED="$BATS_TEST_TMPDIR/nginx/enabled"
    export TPROXY_NGINX_ACME_SITE="$BATS_TEST_TMPDIR/nginx/acme"
    export TPROXY_NGINX_CONF="$BATS_TEST_TMPDIR/nginx/main"
    export TPROXY_CERT_DIR="$BATS_TEST_TMPDIR/cert"
    export TPROXY_WEBROOT_BASE="$BATS_TEST_TMPDIR/www"
    source "$PROJECT_ROOT/setup-essence/modules/telegram-proxy.sh"
    secret=0123456789abcdef0123456789abcdef
    tag=fedcba9876543210fedcba9876543210
    events="$BATS_TEST_TMPDIR/events"
    : > "$events"
    source_dir="$BATS_TEST_TMPDIR/source"
    make_source "$source_dir"
    mkdir -p "$TPROXY_SYSTEMD_DIR" "$TPROXY_DIR" "$(dirname "$TPROXY_ENV_FILE")"
    TELEGRAM_MTPROTO_ENABLED=false
    backend_active=false
    listener_ok=true
    chown() { return 0; }
    getent() { return 1; }
    _telegram_proxy_backend_active() { [[ "$backend_active" == true ]]; }
    _telegram_proxy_wait_mtproxy_listener() { printf 'listener\n' >> "$events"; [[ "$listener_ok" == true ]]; }
    _telegram_proxy_install_backend() {
        printf 'native\n' >> "$events"
        _telegram_proxy_render_mtproxy_unit "$1/deploy/mtproxy.service" "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY"
    }
    systemctl() {
        printf 'systemctl:%s\n' "$*" >> "$events"
        if [[ "$1" == is-active || "$1" == is-enabled ]]; then return 1; fi
        return 0
    }
}
teardown() { teardown_test_env; }

make_source() {
    mkdir -p "$1/deploy"
    cat > "$1/deploy/mtproxy.service" <<'EOF'
[Service]
Environment=MTPROXY_WORKERS=1
ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy -u mtproxy -p 8888 -H 2398 -S ${MTPROXY_SECRET} --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M ${MTPROXY_WORKERS} -C ${MTPROXY_MAX_CONNECTIONS}
EOF
}

existing_backend() {
    _telegram_proxy_render_mtproxy_env "$secret" "-P $tag"
    cp "$TPROXY_ENV_FILE" "$BATS_TEST_TMPDIR/old-env"
    _telegram_proxy_render_mtproxy_unit "$source_dir/deploy/mtproxy.service" "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY"
}

@test "fresh shared backend starts and checks listener without publishing direct access" {
    _telegram_proxy_prepare_backend "$source_dir" "$secret" false
    [ "$(cat "$events")" = "native
systemctl:daemon-reload
systemctl:enable --now $TPROXY_UNIT_FIREWALL $TPROXY_UNIT_MTPROXY
systemctl:enable --now $TPROXY_UNIT_TIMER
listener" ]
    _telegram_proxy_read_env
    [ "$TPROXY_RUNTIME_SECRET" = "$secret" ]
    [ "$TELEGRAM_MTPROTO_ENABLED" = false ]
    [ ! -e "$TPROXY_CONF" ]
}

@test "healthy canonical backend avoids rebuild and restart and preserves shared credentials" {
    existing_backend
    backend_active=true
    _telegram_proxy_prepare_backend "$source_dir" "$secret" true
    cmp -s "$BATS_TEST_TMPDIR/old-env" "$TPROXY_ENV_FILE"
    [[ "$(cat "$events")" != *native* ]]
    [[ "$(cat "$events")" != *restart* ]]
    [[ "$(cat "$events")" == *"enable --now $TPROXY_UNIT_TIMER"* ]]
    [ "$TPROXY_ROLLBACK_MTPROXY_CHANGED" = false ]
}

@test "inactive or listenerless existing backend gets one repair preserving secret and tag" {
    local scenario
    for scenario in inactive listenerless; do
        existing_backend
        : > "$events"
        if [[ "$scenario" == inactive ]]; then backend_active=false; else backend_active=true; fi
        _telegram_proxy_wait_mtproxy_listener() {
            printf 'listener\n' >> "$events"
            if [[ "$scenario" == listenerless ]] && ! grep -q '^native$' "$events"; then return 1; fi
        }
        _telegram_proxy_prepare_backend "$source_dir" "$secret" true
        [ "$(grep -c '^native$' "$events")" -eq 1 ]
        cmp -s "$BATS_TEST_TMPDIR/old-env" "$TPROXY_ENV_FILE"
        if [[ "$scenario" == listenerless ]]; then
            [ "$(grep -c "^systemctl:restart $TPROXY_UNIT_MTPROXY$" "$events")" -eq 1 ]
        else
            ! grep -q '^systemctl:restart' "$events"
        fi
    done
}

@test "changed unit restarts active backend once without native rebuild" {
    existing_backend
    backend_active=true
    printf '\n# stale managed unit\n' >> "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY"
    _telegram_proxy_prepare_backend "$source_dir" "$secret" true
    _telegram_proxy_render_mtproxy_unit "$source_dir/deploy/mtproxy.service" "$BATS_TEST_TMPDIR/canonical"
    cmp -s "$BATS_TEST_TMPDIR/canonical" "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY"
    cmp -s "$BATS_TEST_TMPDIR/old-env" "$TPROXY_ENV_FILE"
    ! grep -q '^native$' "$events"
    [ "$(grep -c "^systemctl:restart $TPROXY_UNIT_MTPROXY$" "$events")" -eq 1 ]
    [ "$TPROXY_ROLLBACK_MTPROXY_CHANGED" = true ]
}

@test "repair rollback restarts only changed previously active backend after restoring unit" {
    existing_backend
    cp "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" "$BATS_TEST_TMPDIR/old-unit"
    systemctl() {
        if [[ "$1" == is-active || "$1" == is-enabled ]]; then [[ "${@: -1}" == "$TPROXY_UNIT_MTPROXY" ]]; return; fi
        if [[ "$1" == restart ]]; then cmp -s "$BATS_TEST_TMPDIR/old-unit" "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" || return 1; fi
        printf 'systemctl:%s\n' "$*" >> "$events"
    }
    _telegram_proxy_ufw_port_state() { return 0; }
    nginx() { [[ "$1" == -t ]]; }
    nft() { return 1; }
    _telegram_proxy_snapshot_paths "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY"
    printf 'changed\n' > "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY"
    TPROXY_ROLLBACK_MTPROXY_CHANGED=true
    _telegram_proxy_restore_snapshot
    [ "$(grep -c "^systemctl:restart $TPROXY_UNIT_MTPROXY$" "$events")" -eq 1 ]
    [ "$TPROXY_ROLLBACK_MTPROXY_CHANGED" = false ]
}

web_install_harness() {
    _telegram_proxy_preflight() { return 0; }
    _telegram_proxy_public_ipv4() { printf '8.8.8.8\n'; }
    _telegram_proxy_public_ipv6() { return 0; }
    _telegram_proxy_wait_dns() { TELEGRAM_WEB_IPV6=false; }
    _telegram_proxy_detect_topology() { printf 'direct\n'; }
    _telegram_proxy_check_ports() { return 0; }
    _telegram_proxy_generate_secret() { printf '%s\n' '0123456789abcdef0123456789abcdef'; }
    acme_select_email() { ACME_SELECTED_EMAIL=admin@example.com; }
    _telegram_proxy_ufw_port_state() { printf 'absent\n'; }
    _telegram_proxy_snapshot_paths() { TPROXY_ROLLBACK_MTPROXY_CHANGED=false; }
    _telegram_proxy_snapshot_certificate_registration() { return 0; }
    _telegram_proxy_clone_relay() { make_source "$1"; }
    _telegram_proxy_restore_install_failure() { printf 'rollback\n' >> "$events"; [[ -z "${5:-}" ]] || rm -rf "$5"; }
    id() { return 1; }
    useradd() { return 0; }
    install() { if [[ "$1" == -d ]]; then mkdir -p "${@: -1}"; else command install "$@"; fi; }
    _randomhtml() { printf 'decoy\n' >> "$events"; return 1; }
    _telegram_proxy_ensure_certificate() { printf 'cert\n' >> "$events"; return 1; }
    _telegram_proxy_build_relay() { printf 'build\n' >> "$events"; return 1; }
    _telegram_proxy_state_write() { printf 'state\n' >> "$events"; }
}

@test "WEB fresh and existing inactive prepare backend before any relay or certificate work" {
    local scenario rc
    web_install_harness
    for scenario in fresh existing; do
        : > "$events"
        rm -f "$TPROXY_CONF"
        if [[ "$scenario" == existing ]]; then
            existing_backend
            : > "$TPROXY_CONF"
            _telegram_proxy_load_conf() { TELEGRAM_WEB_ENABLED=false; TELEGRAM_MTPROTO_ENABLED=true; TPROXY_RUNTIME_SECRET="$secret"; }
            _telegram_proxy_runtime_consistent() { return 0; }
        fi
        telegram_proxy_web_install --force <<< 'web.example.com' && rc=0 || rc=$?
        [ "$rc" -eq 1 ]
        [[ "$(cat "$events")" == *$'listener\ndecoy\nrollback' ]]
        ! grep -Eq '^(build|cert|state)$' "$events"
    done
}

@test "WEB backend listener failure rolls back once before relay build certificate or state" {
    web_install_harness
    listener_ok=false
    warn() { printf 'warn\n' >> "$events"; }
    telegram_proxy_web_install --force <<< 'web.example.com' && rc=0 || rc=$?
    [ "$rc" -eq 1 ]
    [[ "$(cat "$events")" == *$'listener\nwarn\nrollback' ]]
    [ "$(grep -c '^rollback$' "$events")" -eq 1 ]
    ! grep -Eq '^(decoy|build|cert|state)$' "$events"
    [ ! -e "$TPROXY_CONF" ]
}

@test "WEB-only rotation restarts backend and checks listener before new WEB secret proof" {
    existing_backend
    TELEGRAM_WEB_ENABLED=true
    TELEGRAM_MTPROTO_ENABLED=false
    _telegram_proxy_render_profiles "$secret"
    _telegram_proxy_is_installed() { _telegram_proxy_read_env; }
    _telegram_proxy_generate_secret() { printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; }
    _telegram_proxy_web_secret_accepted() { printf 'proof\n' >> "$events"; [[ "$1" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]; }
    telegram_proxy_rotate_secret --force
    [ "$(cat "$events")" = "systemctl:restart $TPROXY_UNIT_MTPROXY
listener
systemctl:restart $TPROXY_UNIT_RELAY
proof" ]
    _telegram_proxy_read_env
    [ "$TPROXY_RUNTIME_SECRET" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]
    [ "$TPROXY_RUNTIME_TAG_ARGS" = "-P $tag" ]
}

@test "WEB-only rotation restores env and restarts backend when new listener fails" {
    existing_backend
    TELEGRAM_WEB_ENABLED=true
    TELEGRAM_MTPROTO_ENABLED=false
    _telegram_proxy_render_profiles "$secret"
    cp "$TPROXY_PROFILES_FILE" "$BATS_TEST_TMPDIR/old-profile"
    _telegram_proxy_is_installed() { _telegram_proxy_read_env; }
    _telegram_proxy_generate_secret() { printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; }
    listener_ok=false
    _telegram_proxy_web_secret_accepted() { [[ "$1" == "$secret" ]]; }
    telegram_proxy_rotate_secret --force && rc=0 || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(grep -c "^systemctl:restart $TPROXY_UNIT_MTPROXY$" "$events")" -eq 2 ]
    cmp -s "$BATS_TEST_TMPDIR/old-env" "$TPROXY_ENV_FILE"
    cmp -s "$BATS_TEST_TMPDIR/old-profile" "$TPROXY_PROFILES_FILE"
}

restart_state() {
    local mode="$1"
    _telegram_proxy_initialize_state
    rm -f "$TPROXY_PROFILES_FILE"
    _telegram_proxy_render_mtproxy_env "$secret"
    if [[ "$mode" != direct ]]; then
        TELEGRAM_WEB_ENABLED=true
        TELEGRAM_WEB_HOSTNAME=web.example.com
        TELEGRAM_WEB_EMAIL=operator@example.com
        TELEGRAM_WEB_TOPOLOGY=direct
        TELEGRAM_WEB_TLS_LISTEN=0.0.0.0:443
        TELEGRAM_WEB_IPV6=false
        TELEGRAM_RELAY_SOURCE_PATH="$TPROXY_RELAY_SOURCE_PATH"
        TELEGRAM_RELAY_UPSTREAM_SHA="$TPROXY_UPSTREAM_REVISION"
        _telegram_proxy_render_profiles "$secret"
    fi
    if [[ "$mode" != web ]]; then
        TELEGRAM_MTPROTO_ENABLED=true
        TELEGRAM_MTPROTO_IPV4=8.8.8.8
        TELEGRAM_UFW_MTPROTO_PREVIOUS=absent
    fi
    _telegram_proxy_state_write
}

@test "common restart supports all installed access modes without confirmation" {
    local mode expected
    warn() { printf 'warn\n' >> "$events"; }
    _telegram_proxy_probe() { return 1; }
    _telegram_proxy_wait_endpoint() { printf 'web-ready\n' >> "$events"; return 0; }
    confirm_yn() { printf 'unexpected-confirm\n' >> "$events"; return 1; }
    for mode in web direct both; do
        restart_state "$mode"
        : > "$events"
        run telegram_proxy_cli backend restart
        [ "$status" -eq 0 ]
        expected="systemctl:restart $TPROXY_UNIT_MTPROXY
listener"
        [[ "$mode" == direct ]] || expected+=$'\nweb-ready'
        [ "$(cat "$events")" = "$expected" ]
    done
}

@test "common restart propagates backend listener and mandatory WEB readiness failures" {
    local failure expected
    restart_state web
    warn() { printf 'warn\n' >> "$events"; }
    _telegram_proxy_probe() { return 1; }
    _telegram_proxy_wait_endpoint() { printf 'web-ready\n' >> "$events"; return 1; }
    systemctl() {
        printf 'systemctl:%s\n' "$*" >> "$events"
        [[ "$failure" != start ]]
    }
    for failure in start listener web; do
        : > "$events"
        listener_ok=true
        [[ "$failure" != listener ]] || listener_ok=false
        run telegram_proxy_backend_restart
        [ "$status" -eq 1 ]
        expected="systemctl:restart $TPROXY_UNIT_MTPROXY"
        [[ "$failure" == start ]] || expected+=$'\nlistener'
        [[ "$failure" != web ]] || expected+=$'\nweb-ready'
        [ "$(cat "$events")" = "$expected" ]
    done
}

@test "backend preparation native start and timer failures never publish managed state" {
    local failure expected
    warn() { printf 'warn\n' >> "$events"; }
    _telegram_proxy_install_backend() { printf 'native\n' >> "$events"; [[ "$failure" != native ]]; }
    systemctl() {
        printf 'systemctl:%s\n' "$*" >> "$events"
        if [[ "$failure" == start && "$*" == "enable --now $TPROXY_UNIT_FIREWALL $TPROXY_UNIT_MTPROXY" ]]; then return 1; fi
        if [[ "$failure" == timer && "$*" == "enable --now $TPROXY_UNIT_TIMER" ]]; then return 1; fi
        return 0
    }
    for failure in native start timer; do
        : > "$events"
        run _telegram_proxy_prepare_backend "$source_dir" "$secret" false
        [ "$status" -eq 1 ]
        expected=native
        if [[ "$failure" != native ]]; then
            expected+=$'\nsystemctl:daemon-reload'
            expected+=$'\nsystemctl:enable --now '"$TPROXY_UNIT_FIREWALL $TPROXY_UNIT_MTPROXY"
        fi
        [[ "$failure" != timer ]] || expected+=$'\nsystemctl:enable --now '"$TPROXY_UNIT_TIMER"
        expected+=$'\nwarn'
        [ "$(cat "$events")" = "$expected" ]
        [ ! -e "$TPROXY_CONF" ]
    done
}

@test "removing either access mode preserves shared backend until the final mode is disabled" {
    local first second
    nft() { return 1; }
    nginx() { [[ " $* " != *' -T '* ]] || printf 'http { server { listen 80; server_name _; } }\n'; }
    id() { return 1; }
    _telegram_proxy_ufw_port_state() { return 0; }
    _telegram_proxy_ufw_apply_port() { return 0; }
    for first in web mtproto; do
        restart_state both
        mkdir -p "$TPROXY_MTPROXY_SOURCE_DIR" "$TPROXY_RELAY_SOURCE_PATH" \
            "$(dirname "$TPROXY_NGINX_SITE")"
        _telegram_proxy_render_mtproxy_unit "$source_dir/deploy/mtproxy.service" \
            "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY"
        : > "$events"
        if [[ "$first" == web ]]; then
            telegram_proxy_web_remove --force
            second=mtproto
        else
            telegram_proxy_mtproto_remove --force
            second=web
        fi
        _telegram_proxy_is_installed
        _telegram_proxy_component_enabled "$second"
        [ -f "$TPROXY_ENV_FILE" ]
        [ -f "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" ]
        ! grep -Eq '^systemctl:(stop|disable).*mtproxy' "$events"
        if [[ "$second" == web ]]; then
            telegram_proxy_web_remove --force
        else
            telegram_proxy_mtproto_remove --force
        fi
        [ ! -e "$TPROXY_CONF" ]
        [ ! -e "$TPROXY_ENV_FILE" ]
        [ ! -e "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" ]
        [ ! -e "$TPROXY_MTPROXY_SOURCE_DIR" ]
        [ ! -e "$TPROXY_FIREWALL_FILE" ]
    done
}

@test "IPv6 self-steal WEB installation leaves all public TLS sockets to mihomo" {
    web_install_harness
    _telegram_proxy_wait_dns() { TELEGRAM_WEB_IPV6=true; }
    _telegram_proxy_detect_topology() { printf 'self-steal\n'; }
    _randomhtml() { printf 'site\n' > "$2/index.html"; }
    _telegram_proxy_ensure_token_key() { return 0; }
    _telegram_proxy_render_relay_config() { return 0; }
    _telegram_proxy_find_go() { printf '/usr/bin/true\n'; }
    _telegram_proxy_build_relay() { printf '#!/bin/bash\nexit 0\n' > "$3"; }
    _telegram_proxy_install_web_service() { return 0; }
    _telegram_proxy_ensure_certificate() { return 0; }
    _telegram_proxy_wait_endpoint() { return 0; }
    _telegram_proxy_wait_nginx_tls() { return 0; }
    git() { printf '%s\n' "$TPROXY_UPSTREAM_CHECKSUM"; }
    _telegram_proxy_discard_snapshot() { return 0; }
    nginx() { return 0; }
    install() {
        if [[ "$1" == -d ]]; then mkdir -p "${@: -1}"
        else cp "${@: -2:1}" "${@: -1}"; fi
    }
    mktemp() {
        if [[ "$1" == /tmp/tproxy-server.XXXXXX ]]; then
            command mktemp "$BATS_TEST_TMPDIR/candidate.XXXXXX"
        else command mktemp "$@"; fi
    }
    mkdir -p "$(dirname "$TPROXY_BIN")"
    telegram_proxy_web_install --force <<< 'web.example.com'
    # Inspect the nginx socket contract emitted by the real installer + renderer,
    # not installer source or a mocked renderer. IPv6 stays enabled at the front.
    [ "$TELEGRAM_WEB_IPV6" = true ]
    [ "$(awk '$1 == "listen" { gsub(/;/, "", $2); print $2 }' "$TPROXY_NGINX_SITE")" = 127.0.0.1:8443 ]
}

@test "local rotation displays committed secret and forced rotation never displays it" {
    local mode new=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    _telegram_proxy_generate_secret() { printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; }
    _telegram_proxy_web_secret_accepted() { return 0; }
    for mode in local force; do
        restart_state both
        if [[ "$mode" == force ]]; then
            run telegram_proxy_cli rotate-secret --force </dev/null
        else
            run telegram_proxy_cli rotate-secret <<< y
        fi
        [ "$status" -eq 0 ]
        _telegram_proxy_read_env
        [ "$TPROXY_RUNTIME_SECRET" = "$new" ]
        jq -e --arg s "$new" '.profiles[0].secret == $s' "$TPROXY_PROFILES_FILE" >/dev/null
        if [[ "$mode" == force ]]; then
            [[ "$output" != *"$new"* && "$output" != *"$secret"* ]]
        else
            [[ "$output" == *"secret=$new"* ]]
            [[ "$output" != *"$secret"* ]]
        fi
    done
}

@test "cancelled rotation leaves state and secrets unchanged without displaying credentials" {
    restart_state direct
    cp "$TPROXY_ENV_FILE" "$BATS_TEST_TMPDIR/before-env"
    cp "$TPROXY_CONF" "$BATS_TEST_TMPDIR/before-conf"
    _telegram_proxy_generate_secret() { printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; }
    local answer
    for answer in '' n; do
        run telegram_proxy_cli rotate-secret <<< "$answer"
        [ "$status" -eq 0 ]
        cmp "$BATS_TEST_TMPDIR/before-env" "$TPROXY_ENV_FILE"
        cmp "$BATS_TEST_TMPDIR/before-conf" "$TPROXY_CONF"
        [[ "$output" != *"$secret"* && "$output" != *aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa* ]]
    done
    run telegram_proxy_cli rotate-secret </dev/null
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/before-env" "$TPROXY_ENV_FILE"
    cmp "$BATS_TEST_TMPDIR/before-conf" "$TPROXY_CONF"
    [[ "$output" != *"$secret"* && "$output" != *aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa* ]]
}

@test "failed rotation rolls back committed credentials without leaking generated secret" {
    restart_state both
    cp "$TPROXY_ENV_FILE" "$BATS_TEST_TMPDIR/before-env"
    cp "$TPROXY_PROFILES_FILE" "$BATS_TEST_TMPDIR/before-profile"
    _telegram_proxy_generate_secret() { printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; }
    _telegram_proxy_web_secret_accepted() { [[ "$1" == "$secret" ]]; }
    listener_ok=false
    local mode
    for mode in local force; do
        if [[ "$mode" == local ]]; then
            run telegram_proxy_cli rotate-secret <<< y
        else
            run telegram_proxy_cli rotate-secret --force </dev/null
        fi
        [ "$status" -eq 1 ]
        cmp "$BATS_TEST_TMPDIR/before-env" "$TPROXY_ENV_FILE"
        cmp "$BATS_TEST_TMPDIR/before-profile" "$TPROXY_PROFILES_FILE"
        [[ "$output" != *"$secret"* && "$output" != *aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa* ]]
    done
}

@test "connection rendering failure after rotation reports failure without rolling back committed state" {
    restart_state direct
    _telegram_proxy_generate_secret() { printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'; }
    telegram_proxy_connection() { return 1; }
    run telegram_proxy_cli rotate-secret <<< y
    [ "$status" -eq 1 ]
    _telegram_proxy_read_env
    [ "$TPROXY_RUNTIME_SECRET" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]
    [[ "$output" != *aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa* ]]
}

@test "refresh IPv4 commits without confirmation and displays updated connection" {
    restart_state direct
    confirm_yn() { touch "$BATS_TEST_TMPDIR/unexpected-confirm"; return 1; }
    _telegram_proxy_public_ipv4() { printf '1.1.1.1\n'; }
    run telegram_proxy_cli mtproto refresh-ip </dev/null
    [ "$status" -eq 0 ]
    _telegram_proxy_load_conf
    [ "$TELEGRAM_MTPROTO_IPV4" = 1.1.1.1 ]
    [[ "$output" == *"server=1.1.1.1&port=2398&secret=$secret"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/unexpected-confirm" ]
    cp "$TPROXY_CONF" "$BATS_TEST_TMPDIR/before"
    _telegram_proxy_public_ipv4() { printf 'invalid\n'; }
    run telegram_proxy_cli mtproto refresh-ip </dev/null
    [ "$status" -eq 1 ]
    cmp "$BATS_TEST_TMPDIR/before" "$TPROXY_CONF"
}

@test "Web update distinguishes unavailable revision from current revision without mutation" {
    restart_state web
    cp "$TPROXY_CONF" "$BATS_TEST_TMPDIR/before"
    confirm_yn() { touch "$BATS_TEST_TMPDIR/unexpected-confirm"; return 1; }
    _telegram_proxy_latest_sha() { return 0; }
    run telegram_proxy_cli web update </dev/null
    [ "$status" -eq 1 ]
    _telegram_proxy_latest_sha() { printf '%s\n' "$TPROXY_UPSTREAM_REVISION"; }
    run telegram_proxy_cli web update </dev/null
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/before" "$TPROXY_CONF"
    [ ! -e "$BATS_TEST_TMPDIR/unexpected-confirm" ]
}

mtproto_install_fixture() {
    _telegram_proxy_preflight() { return 0; }
    _telegram_proxy_public_ipv4() { printf '8.8.8.8\n'; }
    _telegram_proxy_check_ports() { return 0; }
    _telegram_proxy_generate_secret() { printf '0123456789abcdef0123456789abcdef\n'; }
    _telegram_proxy_ufw_port_state() { printf 'absent\n'; }
    _telegram_proxy_ufw_apply_port() { return 0; }
    _telegram_proxy_clone_relay() { make_source "$1"; }
    _telegram_proxy_prepare_backend() { _telegram_proxy_render_mtproxy_env "$2"; }
    id() { return 1; }
}

@test "MTProto installation confirms once before commit while forced install hides credentials and review" {
    local mode
    mtproto_install_fixture
    for mode in local force; do
        rm -f "$TPROXY_CONF" "$TPROXY_ENV_FILE" "$TPROXY_FIREWALL_FILE"
        : > "$events"
        confirm_yn() { printf 'confirm\n' >> "$events"; [[ "$2" == N ]]; }
        review_frame() { printf 'review\n' >> "$events"; }
        if [[ "$mode" == local ]]; then
            run telegram_proxy_cli mtproto install
        else
            run telegram_proxy_cli mtproto install --force </dev/null
        fi
        [ "$status" -eq 0 ]
        _telegram_proxy_load_conf
        _telegram_proxy_read_env
        [ "$TELEGRAM_MTPROTO_ENABLED" = true ]
        [ "$TELEGRAM_MTPROTO_IPV4" = 8.8.8.8 ]
        [ "$TPROXY_RUNTIME_SECRET" = "$secret" ]
        if [[ "$mode" == local ]]; then
            [[ "$output" == *"secret=$secret"* ]]
            [ "$(grep -c '^confirm$' "$events")" -eq 1 ]
            [ "$(grep -c '^review$' "$events")" -eq 1 ]
        else
            [[ "$output" != *"$secret"* ]]
            ! grep -Eq '^(confirm|review)$' "$events"
        fi
    done
}

@test "MTProto installation denial leaves sandbox untouched and never prints generated secret" {
    mtproto_install_fixture
    cp "$events" "$BATS_TEST_TMPDIR/events-before"
    run telegram_proxy_cli mtproto install </dev/null
    [ "$status" -eq 0 ]
    [ ! -e "$TPROXY_CONF" ]
    [ ! -e "$TPROXY_ENV_FILE" ]
    [ ! -e "$TPROXY_FIREWALL_FILE" ]
    cmp "$BATS_TEST_TMPDIR/events-before" "$events"
    [[ "$output" != *"$secret"* ]]
}
