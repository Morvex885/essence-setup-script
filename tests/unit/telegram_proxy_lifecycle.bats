#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
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
    export TMPDIR="$BATS_TEST_TMPDIR"
    export TPROXY_BIN="$BATS_TEST_TMPDIR/bin/tproxy-server"
    export TPROXY_UNIT_RELAY=telegram-relay.service
    export TPROXY_UNIT_MTPROXY=telegram-mtproxy.service
    export TPROXY_UNIT_FIREWALL=telegram-firewall.service
    export TPROXY_UNIT_REFRESH=telegram-refresh.service
    export TPROXY_UNIT_TIMER=telegram-refresh.timer
    source "$PROJECT_ROOT/common/cert.sh"
    source "$PROJECT_ROOT/setup-essence/modules/telegram-proxy.sh"
}

teardown() { teardown_test_env; }

@test "component verification reports MTProxy failure before probing WEB" {
    local events="$BATS_TEST_TMPDIR/probes" rc
    TELEGRAM_WEB_ENABLED=true
    _telegram_proxy_wait_mtproxy_listener() { printf 'mtproxy\n' >> "$events"; return 1; }
    _telegram_proxy_wait_endpoint() { printf 'web\n' >> "$events"; return 0; }
    warn() { printf 'warn:%s\n' "$*" >> "$events"; }
    _telegram_proxy_verify_components && rc=0 || rc=$?
    [ "$rc" -eq 1 ]
    [[ "$(cat "$events")" == $'mtproxy\nwarn:'*'127.0.0.1:2398.' ]]
}

@test "component verification reports WEB readyz failure" {
    local events="$BATS_TEST_TMPDIR/probes" rc
    TELEGRAM_WEB_ENABLED=true
    TPROXY_READY_URL=http://127.0.0.1:8081/readyz
    _telegram_proxy_wait_mtproxy_listener() { printf 'mtproxy\n' >> "$events"; }
    _telegram_proxy_wait_endpoint() { printf 'web:%s\n' "$1" >> "$events"; return 1; }
    warn() { printf 'warn:%s\n' "$*" >> "$events"; }
    _telegram_proxy_verify_components && rc=0 || rc=$?
    [ "$rc" -eq 1 ]
    [[ "$(cat "$events")" == $'mtproxy\nweb:http://127.0.0.1:8081/readyz\nwarn:'*'127.0.0.1:8081/readyz.' ]]
}

@test "custom WEB readiness endpoint failure does not expose its URL" {
    local events="$BATS_TEST_TMPDIR/warnings" rc
    TELEGRAM_WEB_ENABLED=true
    TPROXY_READY_URL=http://user:credential@127.0.0.1:8081/private
    _telegram_proxy_wait_mtproxy_listener() { return 0; }
    _telegram_proxy_wait_endpoint() { [[ "$1" == "$TPROXY_READY_URL" ]] && return 1; }
    warn() { printf '%s\n' "$*" >> "$events"; }
    _telegram_proxy_verify_components && rc=0 || rc=$?
    [ "$rc" -eq 1 ]
    [[ "$(cat "$events")" == *'проверка готовности'* ]]
    [[ "$(cat "$events")" != *credential* ]]
    [[ "$(cat "$events")" != *'127.0.0.1:8081/readyz'* ]]
}

@test "component verification succeeds without warnings when both probes pass" {
    local events="$BATS_TEST_TMPDIR/probes" rc
    TELEGRAM_WEB_ENABLED=true
    TPROXY_READY_URL=http://127.0.0.1:8081/readyz
    _telegram_proxy_wait_mtproxy_listener() { printf 'mtproxy\n' >> "$events"; }
    _telegram_proxy_wait_endpoint() { printf 'web:%s\n' "$1" >> "$events"; }
    warn() { printf 'warn:%s\n' "$*" >> "$events"; }
    _telegram_proxy_verify_components && rc=0 || rc=$?
    [ "$rc" -eq 0 ]
    [ "$(cat "$events")" = $'mtproxy\nweb:http://127.0.0.1:8081/readyz' ]
}

@test "WEB install reports failed nginx reload after certificate before one rollback" {
    local events="$BATS_TEST_TMPDIR/install-events" transcript rc
    export TPROXY_BIN="$BATS_TEST_TMPDIR/bin/tproxy-server"
    export TPROXY_TOKEN_KEY="$TPROXY_DIR/token.key"
    export TPROXY_PROFILES_RUNTIME_FILE="$BATS_TEST_TMPDIR/run/profiles.json"
    export TPROXY_IPV6_DISABLE_FILE="$BATS_TEST_TMPDIR/ipv6-disable"
    export TMPDIR="$BATS_TEST_TMPDIR"
    mkdir -p "$TPROXY_DIR" "$(dirname "$TPROXY_NGINX_SITE")" "$(dirname "$TPROXY_NGINX_ENABLED")" "$(dirname "$TPROXY_BIN")"
    : > "$TPROXY_CONF"
    _telegram_proxy_load_conf() { TELEGRAM_WEB_ENABLED=false; TELEGRAM_MTPROTO_ENABLED=true; TPROXY_RUNTIME_SECRET=placeholder; }
    _telegram_proxy_runtime_consistent() { return 0; }
    acme_select_email() { ACME_SELECTED_EMAIL=admin@example.com; }
    _telegram_proxy_preflight() { return 0; }
    _telegram_proxy_public_ipv4() { printf '8.8.8.8\n'; }
    _telegram_proxy_public_ipv6() { return 0; }
    _telegram_proxy_wait_dns() { TELEGRAM_WEB_IPV6=false; }
    _telegram_proxy_detect_topology() { printf 'direct\n'; }
    _telegram_proxy_check_ports() { return 0; }
    _telegram_proxy_ufw_port_state() { printf 'absent\n'; }
    _telegram_proxy_snapshot_paths() { return 0; }
    _telegram_proxy_snapshot_certificate_registration() { return 0; }
    _telegram_proxy_clone_relay() { return 0; }
    _telegram_proxy_prepare_backend() { return 0; }
    _randomhtml() { printf 'stub\n' > "$2/index.html"; }
    _telegram_proxy_ensure_token_key() { return 0; }
    _telegram_proxy_render_relay_config() { return 0; }
    _telegram_proxy_render_profiles() { return 0; }
    _telegram_proxy_find_go() { printf '/usr/bin/true\n'; }
    _telegram_proxy_build_relay() {
        printf '#!/bin/bash\n[[ "$*" == *-check* ]]\n' > "$3"
        chmod 0755 "$3"
    }
    _telegram_proxy_install_web_service() { return 0; }
    _telegram_proxy_ensure_certificate() { printf 'cert\n' >> "$events"; }
    _telegram_proxy_render_nginx_site() { : > "$TPROXY_NGINX_SITE"; }
    _telegram_proxy_render_firewall() { printf 'firewall\n' >> "$events"; }
    _telegram_proxy_verify_components() { printf 'probes\n' >> "$events"; }
    _telegram_proxy_state_write() { printf 'state\n' >> "$events"; }
    _telegram_proxy_restore_install_failure() { printf 'rollback\n' >> "$events"; }
    warn() {
        [[ -s "$events" ]] && printf 'warn:%s\n' "$*" >> "$events"
        return 0
    }
    id() { [[ "$1" == tproxy ]]; }
    chown() { return 0; }
    install() {
        if [[ "$1" == -d ]]; then mkdir -p "${@: -1}"; else cp "$7" "$8"; fi
    }
    mktemp() {
        if [[ "$1" == /tmp/tproxy-server.XXXXXX ]]; then
            command mktemp "$BATS_TEST_TMPDIR/candidate.XXXXXX"
        else
            command mktemp "$@"
        fi
    }
    git() { printf '%s\n' "$TPROXY_UPSTREAM_CHECKSUM"; }
    nginx() { [[ "$1" == -t ]] && printf 'nginx_ok\n' >> "$events"; }
    _telegram_proxy_wait_nginx_tls() { printf 'unexpected_tls\n' >> "$events"; return 1; }
    systemctl() {
        if [[ "$1 $2" == 'reload nginx' ]]; then
            printf 'reload_failed\n' >> "$events"
            return 1
        fi
        return 0
    }
    telegram_proxy_web_install --force <<< 'web.example.com' && rc=0 || rc=$?
    [ "$rc" -eq 1 ]
    transcript=$(cat "$events")
    [[ "$transcript" == $'cert\nnginx_ok\nreload_failed\nwarn:'*nginx*$'\nrollback' ]]
    [[ "$transcript" != *$'\nrollback\n'* ]]
    [[ "$transcript" != *unexpected_tls* ]]
}

@test "WEB install reports final UFW restore failure without blaming certificate" {
    local events="$BATS_TEST_TMPDIR/install-events" transcript rc
    export TPROXY_BIN="$BATS_TEST_TMPDIR/bin/tproxy-server"
    export TPROXY_TOKEN_KEY="$TPROXY_DIR/token.key"
    export TPROXY_PROFILES_RUNTIME_FILE="$BATS_TEST_TMPDIR/run/profiles.json"
    export TPROXY_IPV6_DISABLE_FILE="$BATS_TEST_TMPDIR/ipv6-disable"
    export TMPDIR="$BATS_TEST_TMPDIR"
    mkdir -p "$TPROXY_DIR" "$(dirname "$TPROXY_NGINX_SITE")" "$(dirname "$TPROXY_NGINX_ENABLED")" "$(dirname "$TPROXY_BIN")"
    : > "$TPROXY_CONF"
    _telegram_proxy_load_conf() { TELEGRAM_WEB_ENABLED=false; TELEGRAM_MTPROTO_ENABLED=true; TPROXY_RUNTIME_SECRET=placeholder; }
    _telegram_proxy_runtime_consistent() { return 0; }
    acme_select_email() { ACME_SELECTED_EMAIL=admin@example.com; }
    _telegram_proxy_preflight() { return 0; }
    _telegram_proxy_public_ipv4() { printf '8.8.8.8\n'; }
    _telegram_proxy_public_ipv6() { return 0; }
    _telegram_proxy_wait_dns() { TELEGRAM_WEB_IPV6=false; }
    _telegram_proxy_detect_topology() { printf 'direct\n'; }
    _telegram_proxy_check_ports() { return 0; }
    _telegram_proxy_ufw_port_state() { printf 'absent\n'; }
    _telegram_proxy_ufw_apply_port() {
        [[ "$1 $2" == '80 allow' ]] && return 0
        [[ "$1 $2" == '80 absent' ]] && return 1
        return 1
    }
    _telegram_proxy_snapshot_paths() { return 0; }
    _telegram_proxy_snapshot_certificate_registration() { return 0; }
    _telegram_proxy_clone_relay() { return 0; }
    _telegram_proxy_prepare_backend() { return 0; }
    _randomhtml() { printf 'stub\n' > "$2/index.html"; }
    _telegram_proxy_ensure_token_key() { return 0; }
    _telegram_proxy_render_relay_config() { return 0; }
    _telegram_proxy_render_profiles() { return 0; }
    _telegram_proxy_find_go() { printf '/usr/bin/true\n'; }
    _telegram_proxy_build_relay() {
        printf '#!/bin/bash\n[[ "$*" == *-check* ]]\n' > "$3"
        chmod 0755 "$3"
    }
    _telegram_proxy_install_web_service() { return 0; }
    ensure_essence_acme_email() { return 0; }
    ensure_cert() { printf 'cert\n' >> "$events"; }
    _telegram_proxy_render_nginx_site() { printf 'nginx_site\n' >> "$events"; }
    _telegram_proxy_render_firewall() { printf 'firewall\n' >> "$events"; }
    _telegram_proxy_verify_components() { printf 'probes\n' >> "$events"; }
    _telegram_proxy_state_write() { printf 'state\n' >> "$events"; }
    _telegram_proxy_restore_install_failure() { printf 'rollback\n' >> "$events"; }
    warn() {
        [[ -s "$events" ]] && printf 'warn:%s\n' "$*" >> "$events"
        return 0
    }
    id() { [[ "$1" == tproxy ]]; }
    chown() { return 0; }
    install() {
        if [[ "$1" == -d ]]; then mkdir -p "${@: -1}"; else cp "$7" "$8"; fi
    }
    mktemp() {
        if [[ "$1" == /tmp/tproxy-server.XXXXXX ]]; then
            command mktemp "$BATS_TEST_TMPDIR/candidate.XXXXXX"
        else
            command mktemp "$@"
        fi
    }
    git() { printf '%s\n' "$TPROXY_UPSTREAM_CHECKSUM"; }
    nginx() { return 0; }
    _telegram_proxy_wait_nginx_tls() { printf 'unexpected_tls\n' >> "$events"; return 1; }
    systemctl() { return 0; }
    telegram_proxy_web_install --force <<< 'web.example.com' && rc=0 || rc=$?
    [ "$rc" -eq 1 ]
    transcript=$(cat "$events")
    [[ "$transcript" == $'cert\nwarn:'*'UFW TCP/80'*$'\nrollback' ]]
    [[ "$transcript" != *$'\nrollback\n'* ]]
    [[ "$transcript" != *'Не удалось выпустить/установить сертификат'* ]]
    [[ "$transcript" != *unexpected_tls* ]]
}

# Keep installer control flow and state serialization real; isolate host mutations.
web_tls_install_harness() {
    export TPROXY_TOKEN_KEY="$TPROXY_DIR/token.key"
    export TPROXY_PROFILES_RUNTIME_FILE="$BATS_TEST_TMPDIR/run/profiles.json"
    export TPROXY_IPV6_DISABLE_FILE="$BATS_TEST_TMPDIR/ipv6-disable"
    mkdir -p "$TPROXY_DIR" "$(dirname "$TPROXY_ENV_FILE")" "$(dirname "$TPROXY_NGINX_SITE")" \
        "$(dirname "$TPROXY_NGINX_ENABLED")" "$(dirname "$TPROXY_BIN")"
    _telegram_proxy_initialize_state
    TELEGRAM_MTPROTO_ENABLED=true
    TELEGRAM_MTPROTO_IPV4=8.8.8.8
    TELEGRAM_UFW_MTPROTO_PREVIOUS=absent
    _telegram_proxy_state_write
    printf 'MTPROXY_SECRET=0123456789abcdef0123456789abcdef\nMTPROXY_TAG_ARGS=""\n' > "$TPROXY_ENV_FILE"

    # Record calls without replacing the real writer with an echo-only mock.
    local writer
    writer=$(declare -f _telegram_proxy_state_write)
    eval "${writer/_telegram_proxy_state_write/web_tls_real_state_write}"
    _telegram_proxy_state_write() {
        printf 'state\n' >> "$events"
        web_tls_real_state_write
    }
    acme_select_email() { ACME_SELECTED_EMAIL=admin@example.com; }
    _telegram_proxy_preflight() { return 0; }
    _telegram_proxy_public_ipv4() { printf '8.8.8.8\n'; }
    _telegram_proxy_public_ipv6() { printf '2001:4860:4860::8888\n'; }
    _telegram_proxy_wait_dns() { TELEGRAM_WEB_IPV6=true; }
    _telegram_proxy_detect_topology() { printf 'self-steal\n'; }
    _telegram_proxy_check_ports() { return 0; }
    _telegram_proxy_ufw_port_state() { printf 'absent\n'; }
    _telegram_proxy_snapshot_paths() { printf 'snapshot\n' >> "$events"; }
    _telegram_proxy_snapshot_certificate_registration() { return 0; }
    _telegram_proxy_clone_relay() { return 0; }
    _telegram_proxy_prepare_backend() { return 0; }
    _randomhtml() { printf 'stub\n' > "$2/index.html"; }
    _telegram_proxy_ensure_token_key() { return 0; }
    _telegram_proxy_render_relay_config() { return 0; }
    _telegram_proxy_render_profiles() { return 0; }
    _telegram_proxy_find_go() { printf '/usr/bin/true\n'; }
    _telegram_proxy_build_relay() {
        printf '#!/bin/bash\n[[ "$*" == *-check* ]]\n' > "$3"
        chmod 0755 "$3"
    }
    _telegram_proxy_install_web_service() { return 0; }
    _telegram_proxy_ensure_certificate() { printf 'cert\n' >> "$events"; }
    _telegram_proxy_render_nginx_site() { : > "$TPROXY_NGINX_SITE"; }
    _telegram_proxy_render_firewall() { printf 'firewall\n' >> "$events"; }
    _telegram_proxy_verify_components() { printf 'probes\n' >> "$events"; }
    _telegram_proxy_restore_install_failure() {
        printf 'rollback\n' >> "$events"
        [[ "$#" -eq 4 && "$1" == absent && -z "$2" && "$3" == true && "$4" == true ]] || {
            printf 'unexpected_rollback_args\n' >> "$events"
            return 1
        }
    }
    _telegram_proxy_discard_snapshot() { printf 'discard\n' >> "$events"; }
    info() { return 0; }
    warn() { printf '%s\n' "$*" >> "$warnings"; }
    success() { printf 'success\n' >> "$events"; }
    id() { [[ "$1" == tproxy || "$1" == mtproxy ]]; }
    chown() { return 0; }
    install() {
        if [[ "$1" == -d ]]; then mkdir -p "${@: -1}"; else cp "$7" "$8"; fi
    }
    mktemp() {
        if [[ "$1" == /tmp/tproxy-server.XXXXXX ]]; then
            command mktemp "$BATS_TEST_TMPDIR/candidate.XXXXXX"
        else
            command mktemp "$@"
        fi
    }
    git() { printf '%s\n' "$TPROXY_UPSTREAM_CHECKSUM"; }
    nginx() { [[ "$1" == -t ]] && printf 'nginx_ok\n' >> "$events"; }
    systemctl() {
        case "$1 $2" in
            'reload nginx') printf 'reload\n' >> "$events" ;;
            "reload $TPROXY_UNIT_FIREWALL"|"restart $TPROXY_UNIT_FIREWALL")
                printf 'firewall_apply\n' >> "$events" ;;
        esac
        return 0
    }
}

@test "WEB install rejects failed TLS after successful nginx reload before firewall and state commit" {
    local events="$BATS_TEST_TMPDIR/install-events" warnings="$BATS_TEST_TMPDIR/warnings" rc
    web_tls_install_harness
    cp "$TPROXY_CONF" "$BATS_TEST_TMPDIR/state-before"
    cp "$TPROXY_ENV_FILE" "$BATS_TEST_TMPDIR/env-before"
    _telegram_proxy_wait_nginx_tls() {
        printf 'tls_failed\n' >> "$events"
        [[ "$#" -eq 2 && "$1" == web.example.com && "$2" == self-steal ]] || {
            printf 'unexpected_tls_args\n' >> "$events"
        }
        return 1
    }
    telegram_proxy_web_install --force <<< 'web.example.com' && rc=0 || rc=$?
    [ "$rc" -eq 1 ]
    [ "$(cat "$events")" = $'snapshot\ncert\nnginx_ok\nreload\ntls_failed\nrollback' ]
    cmp "$BATS_TEST_TMPDIR/state-before" "$TPROXY_CONF"
    cmp "$BATS_TEST_TMPDIR/env-before" "$TPROXY_ENV_FILE"
    _telegram_proxy_load_conf
    [ "$TELEGRAM_WEB_ENABLED" = false ]
}

@test "WEB install commits real installed state once only after nginx TLS succeeds" {
    local events="$BATS_TEST_TMPDIR/install-events" warnings="$BATS_TEST_TMPDIR/warnings" rc
    web_tls_install_harness
    cp "$TPROXY_ENV_FILE" "$BATS_TEST_TMPDIR/env-before"
    _telegram_proxy_wait_nginx_tls() {
        printf 'tls_ok\n' >> "$events"
        [[ "$#" -eq 2 && "$1" == web.example.com && "$2" == self-steal ]]
    }
    telegram_proxy_web_install --force <<< 'web.example.com' && rc=0 || rc=$?
    [ "$rc" -eq 0 ]
    [ "$(cat "$events")" = $'snapshot\ncert\nnginx_ok\nreload\ntls_ok\nfirewall\nfirewall_apply\nprobes\nstate\ndiscard\nsuccess' ]
    _telegram_proxy_load_conf
    [ "$TELEGRAM_WEB_ENABLED" = true ]
    [ "$TELEGRAM_WEB_HOSTNAME" = web.example.com ]
    [ "$TELEGRAM_WEB_TOPOLOGY" = self-steal ]
    [ "$TELEGRAM_WEB_TLS_LISTEN" = 127.0.0.1:8443 ]
    [ "$TELEGRAM_WEB_IPV6" = true ]
    [ "$TELEGRAM_MTPROTO_ENABLED" = true ]
    cmp "$BATS_TEST_TMPDIR/env-before" "$TPROXY_ENV_FILE"
}

web_tls_noop_harness() {
    mkdir -p "$TPROXY_DIR" "$(dirname "$TPROXY_ENV_FILE")"
    _telegram_proxy_initialize_state
    TELEGRAM_WEB_ENABLED=true
    TELEGRAM_WEB_HOSTNAME=web.example.com
    TELEGRAM_WEB_EMAIL=admin@example.com
    TELEGRAM_WEB_TOPOLOGY=self-steal
    TELEGRAM_WEB_TLS_LISTEN=127.0.0.1:8443
    TELEGRAM_WEB_IPV6=true
    TELEGRAM_RELAY_SOURCE_PATH="$TPROXY_RELAY_SOURCE_PATH"
    TELEGRAM_RELAY_UPSTREAM_SHA="$TPROXY_UPSTREAM_CHECKSUM"
    _telegram_proxy_state_write
    printf 'MTPROXY_SECRET=0123456789abcdef0123456789abcdef\nMTPROXY_TAG_ARGS=""\n' > "$TPROXY_ENV_FILE"
    printf '{"profiles":[{"name":"default","secret":"0123456789abcdef0123456789abcdef"}]}\n' > "$TPROXY_PROFILES_FILE"
    cp "$TPROXY_CONF" "$BATS_TEST_TMPDIR/state-before"
    cp "$TPROXY_ENV_FILE" "$BATS_TEST_TMPDIR/env-before"
    cp "$TPROXY_PROFILES_FILE" "$BATS_TEST_TMPDIR/profiles-before"

    web_tls_unexpected() { printf 'unexpected:%s\n' "$1" >> "$events"; return 1; }
    read() {
        if [[ "$1" == -rp ]]; then web_tls_unexpected prompt; else builtin read "$@"; fi
    }
    confirm_yn() { web_tls_unexpected confirm; }
    acme_select_email() { web_tls_unexpected email; }
    _telegram_proxy_preflight() { web_tls_unexpected preflight; }
    _telegram_proxy_check_ports() { web_tls_unexpected ports; }
    _telegram_proxy_generate_secret() { web_tls_unexpected secret; }
    _telegram_proxy_snapshot_paths() { web_tls_unexpected snapshot; }
    _telegram_proxy_clone_relay() { web_tls_unexpected clone; }
    _telegram_proxy_prepare_backend() { web_tls_unexpected backend_prepare; }
    _telegram_proxy_build_relay() { web_tls_unexpected build; }
    _telegram_proxy_ensure_certificate() { web_tls_unexpected acme; }
    _telegram_proxy_render_nginx_site() { web_tls_unexpected nginx_site; }
    _telegram_proxy_render_firewall() { web_tls_unexpected firewall; }
    _telegram_proxy_state_write() { web_tls_unexpected state; }
    _telegram_proxy_discard_snapshot() { web_tls_unexpected discard; }
    _telegram_proxy_restore_install_failure() { web_tls_unexpected rollback; }
    nginx() { web_tls_unexpected nginx; }
    success() { web_tls_unexpected success; }
    systemctl() {
        case "$*" in
            "is-enabled --quiet $TPROXY_UNIT_TIMER") printf 'timer_enabled\n' >> "$events" ;;
            "is-active --quiet $TPROXY_UNIT_TIMER") printf 'timer_active\n' >> "$events" ;;
            *) web_tls_unexpected "systemctl:$*"; return 1 ;;
        esac
    }
    _telegram_proxy_web_runtime_healthy() { printf 'relay\n' >> "$events"; }
    _telegram_proxy_backend_active() { printf 'backend\n' >> "$events"; }
    _telegram_proxy_wait_mtproxy_listener() { printf 'listener\n' >> "$events"; }
    _telegram_proxy_wait_nginx_tls() {
        printf 'tls\n' >> "$events"
        [[ "$#" -eq 3 && "$1" == web.example.com && "$2" == self-steal && "$3" == 1 ]] || {
            web_tls_unexpected tls_args
            return 1
        }
        return "$tls_result"
    }
    info() { printf '%s\n' "$*" >> "$messages"; }
    warn() { printf '%s\n' "$*" >> "$messages"; }
}

web_tls_assert_noop_unchanged() {
    [ "$(cat "$events")" = $'relay\nbackend\ntimer_enabled\ntimer_active\nlistener\ntls' ]
    cmp "$BATS_TEST_TMPDIR/state-before" "$TPROXY_CONF"
    cmp "$BATS_TEST_TMPDIR/env-before" "$TPROXY_ENV_FILE"
    cmp "$BATS_TEST_TMPDIR/profiles-before" "$TPROXY_PROFILES_FILE"
    [ "$TPROXY_RUNTIME_SECRET" = 0123456789abcdef0123456789abcdef ]
    [[ "$(cat "$messages")" != *0123456789abcdef0123456789abcdef* ]]
}

@test "installed healthy WEB preserves state and automatically displays connection credentials" {
    local events="$BATS_TEST_TMPDIR/noop-events" messages="$BATS_TEST_TMPDIR/messages" tls_result=0 rc
    web_tls_noop_harness
    telegram_proxy_web_install </dev/null > "$BATS_TEST_TMPDIR/connection-output" && rc=0 || rc=$?
    [ "$rc" -eq 0 ]
    web_tls_assert_noop_unchanged
    [[ "$(cat "$BATS_TEST_TMPDIR/connection-output")" == *'secret=0123456789abcdef0123456789abcdef'* ]]
}

@test "installed healthy WEB with failed TLS refuses reconcile and preserves state and secret" {
    local events="$BATS_TEST_TMPDIR/noop-events" messages="$BATS_TEST_TMPDIR/messages" tls_result=1 rc
    web_tls_noop_harness
    telegram_proxy_web_install </dev/null && rc=0 || rc=$?
    [ "$rc" -eq 1 ]
    web_tls_assert_noop_unchanged
}

@test "WEB install asks only for provider firewall approval before snapshot" {
    local events="$BATS_TEST_TMPDIR/install-events" decision rc
    _telegram_proxy_reject_unmanaged_state() { return 0; }
    acme_select_email() { ACME_SELECTED_EMAIL=admin@example.com; }
    _telegram_proxy_preflight() { return 0; }
    _telegram_proxy_public_ipv4() { printf '8.8.8.8\n'; }
    _telegram_proxy_public_ipv6() { return 0; }
    _telegram_proxy_wait_dns() { TELEGRAM_WEB_IPV6=false; }
    _telegram_proxy_detect_topology() { printf 'direct\n'; }
    _telegram_proxy_check_ports() { return 0; }
    _telegram_proxy_generate_secret() { printf 'test-secret\n'; }
    _telegram_proxy_ufw_port_state() { printf 'absent\n'; }
    confirm_yn() { printf 'confirm\n' >> "$events"; [[ "$decision" == yes ]]; }
    _telegram_proxy_snapshot_paths() { printf 'snapshot\n' >> "$events"; return 1; }

    for decision in yes no force; do
        : > "$events"
        if [[ "$decision" == force ]]; then
            telegram_proxy_web_install --force <<< 'web.example.com' && rc=0 || rc=$?
        else
            telegram_proxy_web_install <<< 'web.example.com' && rc=0 || rc=$?
        fi
        case "$decision" in
            yes)
                [ "$rc" -eq 1 ]
                [ "$(cat "$events")" = $'confirm\nsnapshot' ]
                ;;
            no)
                [ "$rc" -eq 0 ]
                [ "$(cat "$events")" = confirm ]
                ;;
            force)
                [ "$rc" -eq 1 ]
                [ "$(cat "$events")" = snapshot ]
                ;;
        esac
    done
}

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
@test "WEB-only removal under nounset cleans artifacts without touching shared MTProto state" {
    mkdir -p "$TPROXY_DIR" "$TPROXY_RELAY_SOURCE_PATH" "$TPROXY_CERT_DIR/web.example.com" "$TPROXY_WEBROOT_BASE/web.example.com" "$TPROXY_MTPROXY_DIR" "$(dirname "$TPROXY_NGINX_SITE")" "$(dirname "$TPROXY_NGINX_ENABLED")"
    touch "$TPROXY_CONFIG_JSON" "$TPROXY_PROFILES_FILE" "$TPROXY_NGINX_SITE" "$TPROXY_NGINX_ENABLED" "$TPROXY_RELAY_SOURCE_PATH/source"
    _telegram_proxy_initialize_state
    TELEGRAM_WEB_ENABLED=true TELEGRAM_MTPROTO_ENABLED=false TELEGRAM_WEB_HOSTNAME=web.example.com
    TPROXY_CREATED_USER=false
    _telegram_proxy_component_enabled() { [[ "$1" == web ]]; }
    _telegram_proxy_snapshot_paths() { return 0; }
    _telegram_proxy_snapshot_certificate_registration() { return 0; }
    _telegram_proxy_discard_snapshot() { return 0; }
    systemctl() { true; }
    nginx() { [[ " $* " != *' -T '* ]] || printf 'http { server { listen 80; server_name _; } }\n'; }
    _telegram_proxy_cleanup_backend() { return 0; }
    set -u
    telegram_proxy_web_remove --force
    [ "$?" -eq 0 ]
    set +u
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
    SETUP_DIR="$PROJECT_ROOT/setup-essence"
    COMMON_DIR="$PROJECT_ROOT/common"
    VERSION_PATH="$PROJECT_ROOT/VERSION"
    source "$PROJECT_ROOT/remote-control/modules/ssh.sh"
    source "$PROJECT_ROOT/remote-control/modules/telegram-proxy.sh"
    node_load() { NODE_NAME="node-$1"; SERVER_IP=127.0.0.1; SERVER_PORT=22; SERVER_USER=root; SERVER_AUTH=key; SERVER_PASS=; return 0; }
    nodes_count() { printf '2\n'; }
    _remote_scripts_probe() {
        REMOTE_SCRIPTS_STATE=ready
        REMOTE_SCRIPTS_VERSION=$(_remote_scripts_normalize_version "$(cat "$VERSION_PATH")")
    }
    ssh_run() { printf '%s\n' "$NODE_NAME" >> "$BATS_TEST_TMPDIR/failed-workers"; return 1; }
    run _telegram_proxy_remote_run web restart false 1 2
    [ "$status" -eq 1 ]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/failed-workers" | tr -d ' ')" -eq 2 ]
}

@test "certificate failure preserves its status and restores the original UFW rule" {
    local rc rules="$BATS_TEST_TMPDIR/ufw-restored"
    TELEGRAM_WEB_EMAIL=admin@example.com
    _telegram_proxy_ufw_port_state() { printf 'deny\n'; }
    _telegram_proxy_ufw_apply_port() { printf '%s %s\n' "$1" "$2" >> "$rules"; }
    ensure_essence_acme_email() { return 0; }
    ensure_cert() { return 7; }
    _telegram_proxy_ensure_certificate web.example.com && rc=0 || rc=$?
    [ "$rc" -eq 7 ]
    [ "$(cat "$rules")" = "80 deny" ]
    [ "$TPROXY_CERT_UFW_RESTORE_FAILED" = false ]
}

@test "certificate and UFW restoration failures retain a distinct firewall warning" {
    local rc warnings="$BATS_TEST_TMPDIR/warnings"
    TELEGRAM_WEB_EMAIL=admin@example.com
    _telegram_proxy_ufw_port_state() { printf 'absent\n'; }
    _telegram_proxy_ufw_apply_port() { return 1; }
    ensure_essence_acme_email() { return 0; }
    ensure_cert() { return 7; }
    warn() { printf '%s\n' "$*" >> "$warnings"; }
    _telegram_proxy_ensure_certificate web.example.com && rc=0 || rc=$?
    [ "$rc" -ne 0 ]
    [ "$TPROXY_CERT_UFW_RESTORE_FAILED" = true ]
    [[ "$(cat "$warnings")" == *'UFW TCP/80'* ]]
}

telegram_certificate_fixture() {
    source "$PROJECT_ROOT/tests/helpers/cert_fixture_helper.bash"
    cert_fixture_init "$BATS_TEST_TMPDIR/pki" || return 1
    cert_fixture_leaf "$BATS_TEST_TMPDIR/pair" web.example.test || return 1
    cert_fixture_fake_acme || return 1
    cert_fixture_runtime "$BATS_TEST_TMPDIR/cert-runtime" || return 1
    TPROXY_CERT_DIR="$CERT_TEST_CERT_DIR"
    TPROXY_NGINX_AVAILABLE_DIR="$CERT_TEST_AVAILABLE"
    TPROXY_NGINX_ENABLED_DIR="$CERT_TEST_ENABLED"
    TPROXY_NGINX_CONF="$CERT_TEST_NGINX_CONF"
    TPROXY_NGINX_SITE="$CERT_TEST_AVAILABLE/telegram"
    TPROXY_NGINX_ENABLED="$CERT_TEST_ENABLED/telegram"
    TPROXY_NGINX_ACME_SITE="$CERT_TEST_ENABLED/essence-telegram-proxy-acme"
    TPROXY_WEBROOT_BASE="$CERT_TEST_WEBROOT"
    TELEGRAM_WEB_EMAIL=test@example.test
    cert_fixture_archive web.example.test "$BATS_TEST_TMPDIR/pair" ecc removed || return 1
    ensure_essence_acme_email() { return 0; }
    _telegram_proxy_ufw_port_state() { printf 'absent\n'; }
    _telegram_proxy_ufw_apply_port() { return 0; }
}

telegram_certificate_remove_fixture() {
    telegram_certificate_fixture || return 1
    TPROXY_WEBROOT_BASE="${1:-$TPROXY_WEBROOT_BASE}"
    _telegram_proxy_ensure_certificate web.example.test || return 1
    mkdir -p "$TPROXY_DIR" "$TPROXY_SYSTEMD_DIR"
    printf 'saved state\n' > "$TPROXY_CONF"
    printf 'ssl_certificate "%s/web.example.test/fullchain.pem";\nssl_certificate_key "%s/web.example.test/privkey.pem";\n' \
        "$TPROXY_CERT_DIR" "$TPROXY_CERT_DIR" > "$TPROXY_NGINX_SITE"
    ln -s "$TPROXY_NGINX_SITE" "$TPROXY_NGINX_ENABLED"
    _telegram_proxy_initialize_state
    TELEGRAM_WEB_ENABLED=true TELEGRAM_MTPROTO_ENABLED=true
    TELEGRAM_WEB_HOSTNAME=web.example.test TELEGRAM_WEB_TOPOLOGY=direct
    _telegram_proxy_component_enabled() { [[ "$1" == web ]]; }
    _telegram_proxy_render_firewall() { return 0; }
    nginx() {
        case " $* " in
            *' -T '*)
                [[ ! -f "$TPROXY_NGINX_SITE" ]] || cat "$TPROXY_NGINX_SITE"
                cat "$CERT_TEST_NGINX_DUMP" ;;
            *) return 0 ;;
        esac
    }
}

@test "WEB removal preserves trusted shared certificate and renewal for another TLS consumer" {
    telegram_certificate_remove_fixture
    local host=web.example.test archive="$HOME/.acme.sh/web.example.test_ecc"
    cp "$TPROXY_CERT_DIR/$host/fullchain.pem" "$BATS_TEST_TMPDIR/before-chain"
    printf 'ssl_certificate "%s/%s/fullchain.pem";\nssl_certificate_key "%s/%s/privkey.pem";\n' \
        "$TPROXY_CERT_DIR" "$host" "$TPROXY_CERT_DIR" "$host" > "$CERT_TEST_NGINX_DUMP"
    _telegram_proxy_state_write() { return 0; }
    telegram_proxy_web_remove --force
    [ ! -e "$TPROXY_NGINX_SITE" ]
    cmp "$BATS_TEST_TMPDIR/before-chain" "$TPROXY_CERT_DIR/$host/fullchain.pem"
    cert_is_usable "$host" "$TPROXY_CERT_DIR/$host/fullchain.pem" "$TPROXY_CERT_DIR/$host/privkey.pem"
    [ -f "$archive/$host.conf" ]
    [ -L "$CERT_TEST_ENABLED/essence-acme-$host" ]
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "late WEB removal failure restores trusted TLS consumer and paused renewal without orders" {
    telegram_certificate_remove_fixture "$BATS_TEST_TMPDIR/previous-feature-www"
    local host=web.example.test archive="$HOME/.acme.sh/web.example.test_ecc" rc
    local previous_root="$TPROXY_WEBROOT_BASE/$host"
    printf 'existing decoy content\n' > "$previous_root/index.html"
    TPROXY_WEBROOT_BASE="$CERT_TEST_WEBROOT"
    cp "$archive/fullchain.cer" "$BATS_TEST_TMPDIR/archive-chain"
    _telegram_proxy_state_write() { return 1; }
    telegram_proxy_web_remove --force && rc=0 || rc=$?
    [ "$rc" -ne 0 ]
    [ -f "$TPROXY_NGINX_SITE" ]
    [ -L "$TPROXY_NGINX_ENABLED" ]
    cert_is_usable "$host" "$TPROXY_CERT_DIR/$host/fullchain.pem" "$TPROXY_CERT_DIR/$host/privkey.pem"
    cmp "$archive/fullchain.cer" "$BATS_TEST_TMPDIR/archive-chain"
    [ -f "$archive/$host.conf" ]
    [ ! -e "$archive/$host.conf.removed" ]
    [ -L "$CERT_TEST_ENABLED/essence-acme-$host" ]
    _acme_conf_value "$archive/$host.conf" Le_RealFullChainPath
    [ "$ACME_CONF_VALUE" = "$TPROXY_CERT_DIR/$host/fullchain.pem" ]
    [ "$(cat "$previous_root/index.html")" = "existing decoy content" ]
    _acme_conf_value "$archive/$host.conf" Le_Webroot
    [ "$ACME_CONF_VALUE" = "$previous_root" ]
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "late WEB installation rollback keeps archive paused when restored snapshots have no consumer" {
    telegram_certificate_fixture
    local host=web.example.test archive="$HOME/.acme.sh/web.example.test_ecc"
    cp "$archive/fullchain.cer" "$BATS_TEST_TMPDIR/archive-chain"
    _telegram_proxy_snapshot_paths "$TPROXY_CERT_DIR/$host" "$TPROXY_WEBROOT_BASE/$host" \
        "$CERT_TEST_AVAILABLE/essence-acme-$host" "$CERT_TEST_ENABLED/essence-acme-$host"
    _telegram_proxy_snapshot_certificate_registration "$host"
    _telegram_proxy_ensure_certificate "$host"
    _telegram_proxy_restore_install_failure "" "" true true
    [ ! -e "$TPROXY_CERT_DIR/$host" ]
    [ ! -e "$CERT_TEST_ENABLED/essence-acme-$host" ]
    [ -f "$archive/$host.conf.removed" ]
    [ ! -e "$archive/$host.conf" ]
    cmp "$archive/fullchain.cer" "$BATS_TEST_TMPDIR/archive-chain"
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "late WEB installation rollback preserves another live consumer and its renewal without orders" {
    telegram_certificate_fixture
    local host=web.example.test archive="$HOME/.acme.sh/web.example.test_ecc"
    _telegram_proxy_ensure_certificate "$host"
    printf 'ssl_certificate "%s/%s/fullchain.pem";\nssl_certificate_key "%s/%s/privkey.pem";\n' \
        "$TPROXY_CERT_DIR" "$host" "$TPROXY_CERT_DIR" "$host" > "$CERT_TEST_NGINX_DUMP"
    cp "$TPROXY_CERT_DIR/$host/fullchain.pem" "$BATS_TEST_TMPDIR/installed-chain"
    _telegram_proxy_snapshot_paths "$TPROXY_CERT_DIR/$host" "$TPROXY_WEBROOT_BASE/$host" \
        "$CERT_TEST_AVAILABLE/essence-acme-$host" "$CERT_TEST_ENABLED/essence-acme-$host"
    _telegram_proxy_snapshot_certificate_registration "$host"
    printf 'broken\n' > "$TPROXY_CERT_DIR/$host/fullchain.pem"
    _telegram_proxy_restore_install_failure "" "" true true
    cmp "$TPROXY_CERT_DIR/$host/fullchain.pem" "$BATS_TEST_TMPDIR/installed-chain"
    cert_is_usable "$host" "$TPROXY_CERT_DIR/$host/fullchain.pem" "$TPROXY_CERT_DIR/$host/privkey.pem"
    [ -f "$archive/$host.conf" ]
    [ -L "$CERT_TEST_ENABLED/essence-acme-$host" ]
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "late WEB installation rollback restores renewal to a surviving consumer in another certificate root" {
    telegram_certificate_fixture
    local host=web.example.test other_root="$BATS_TEST_TMPDIR/other-ssl"
    local archive="$HOME/.acme.sh/web.example.test_ecc"
    ensure_cert "$host" "$TPROXY_WEBROOT_BASE/$host" false "$other_root" \
        "$TPROXY_NGINX_AVAILABLE_DIR" "$TPROXY_NGINX_ENABLED_DIR" "$TPROXY_NGINX_CONF"
    printf 'ssl_certificate "%s/%s/fullchain.pem";\nssl_certificate_key "%s/%s/privkey.pem";\n' \
        "$other_root" "$host" "$other_root" "$host" > "$CERT_TEST_NGINX_DUMP"
    cp "$archive/$host.conf" "$BATS_TEST_TMPDIR/original-registration"
    cp "$other_root/$host/fullchain.pem" "$BATS_TEST_TMPDIR/original-consumer-chain"
    cp "$other_root/$host/privkey.pem" "$BATS_TEST_TMPDIR/original-consumer-key"
    cp "$archive/fullchain.cer" "$BATS_TEST_TMPDIR/original-archive-chain"
    _telegram_proxy_snapshot_paths "$TPROXY_CERT_DIR/$host" "$TPROXY_WEBROOT_BASE/$host" \
        "$CERT_TEST_AVAILABLE/essence-acme-$host" "$CERT_TEST_ENABLED/essence-acme-$host"
    _telegram_proxy_snapshot_certificate_registration "$host"
    _telegram_proxy_ensure_certificate "$host"
    _acme_conf_value "$archive/$host.conf" Le_RealFullChainPath
    [ "$ACME_CONF_VALUE" = "$TPROXY_CERT_DIR/$host/fullchain.pem" ]
    _telegram_proxy_restore_install_failure "" "" true true
    [ ! -e "$TPROXY_CERT_DIR/$host" ]
    cert_is_usable "$host" "$other_root/$host/fullchain.pem" "$other_root/$host/privkey.pem"
    cmp "$other_root/$host/fullchain.pem" "$BATS_TEST_TMPDIR/original-consumer-chain"
    cmp "$other_root/$host/privkey.pem" "$BATS_TEST_TMPDIR/original-consumer-key"
    cmp "$archive/fullchain.cer" "$BATS_TEST_TMPDIR/original-archive-chain"
    cmp "$archive/$host.conf" "$BATS_TEST_TMPDIR/original-registration"
    [ ! -e "$archive/$host.conf.removed" ]
    [ -L "$CERT_TEST_ENABLED/essence-acme-$host" ]
    [ ! -s "$ACME_ORDER_LOG" ]
}
