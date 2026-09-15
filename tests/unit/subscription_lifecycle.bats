#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    export HOME="$BATS_TEST_TMPDIR/home" FIX_ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$HOME" "$FIX_ROOT/etc/mihomo" "$FIX_ROOT/etc/nginx/sites-enabled" \
        "$FIX_ROOT/etc/nginx/sites-available" "$FIX_ROOT/etc/nginx/ssl" \
        "$FIX_ROOT/etc/nginx/snippets" "$FIX_ROOT/etc/systemd/system" \
        "$FIX_ROOT/usr/local/bin" "$FIX_ROOT/var/www" "$FIX_ROOT/var/lib/essence-sub"
    export MODULE_COPY="$BATS_TEST_TMPDIR/subscription.sh"
    sed \
        -e "s|/etc/mihomo|$FIX_ROOT/etc/mihomo|g" \
        -e "s|/etc/nginx|$FIX_ROOT/etc/nginx|g" \
        -e "s|/etc/systemd/system|$FIX_ROOT/etc/systemd/system|g" \
        -e "s|/usr/local/bin|$FIX_ROOT/usr/local/bin|g" \
        -e "s|/var/www|$FIX_ROOT/var/www|g" \
        -e "s|/var/lib/essence-sub|$FIX_ROOT/var/lib/essence-sub|g" \
        "$PROJECT_ROOT/setup-essence/modules/subscription.sh" > "$MODULE_COPY"
    source "$MODULE_COPY"
    mkdir -p "$FIX_ROOT/etc/nginx"
    printf 'events {}\nhttp {}\n' > "$FIX_ROOT/etc/nginx/nginx.conf"
    _check_base() { return 0; }
    _load_reality_conf() { return 0; }
    _detect_reality_mode() { printf '%s\n' sni; }
    _detect_site_name() { printf '%s\n' reality.example.com; }
    _nginx_h2_directives() { LISTEN_H2_FLAG='ssl;'; HTTP2_DIRECTIVE=''; }
    confirm_yn() { return 0; }
    curl() {
        case "$*" in
            *ifconfig.me*|*icanhazip.com*|*api4.ipify.org*) printf '%s\n' 192.0.2.1; return 0 ;;
            *) return 0 ;;
        esac
    }
    export REAL_SED
    REAL_SED=$(command -v sed)
    sed() {
        if [[ "${1:-}" == -i ]]; then
            shift
            if [[ "${OSTYPE:-}" == darwin* ]]; then
                "$REAL_SED" -i '' "$@"
            else
                "$REAL_SED" -i "$@"
            fi
        else
            "$REAL_SED" "$@"
        fi
    }
    getent() {
        if [[ "$1" == hosts ]]; then
            printf '%s\n' '192.0.2.1 subs.example.com'
        elif [[ "$1" == group ]]; then
            return 0
        fi
    }
    ps() { return 1; }
    chown() { return 0; }
    ufw() { return 0; }
    systemctl() {
        if [[ "$1" == reload && "$2" == nginx ]]; then
            SYSTEMCTL_RELOAD_COUNT=$((SYSTEMCTL_RELOAD_COUNT + 1))
            [[ "${SYSTEMCTL_RELOAD_FAIL:-0}" -eq 0 || "$SYSTEMCTL_RELOAD_COUNT" -ne 2 ]]
            return $?
        fi
        return 0
    }
    nginx() {
        if [[ "$1" == -t ]]; then
            NGINX_TEST_COUNT=$((NGINX_TEST_COUNT + 1))
            [[ "${NGINX_TEST_FAIL:-0}" -eq 0 || "$NGINX_TEST_COUNT" -ne 2 ]]
            return $?
        fi
        return 0
    }
    ensure_acme_installed() {
        ACME_MARKER="$BATS_TEST_TMPDIR/acme-installed"
        mkdir -p "$HOME/.acme.sh"
        : > "$ACME_MARKER"
        printf '#!/bin/bash\n' > "$HOME/.acme.sh/acme.sh"
        chmod 755 "$HOME/.acme.sh/acme.sh"
        return 0
    }
    issue_cert() { return 0; }
    install_cert() {
        mkdir -p "$FIX_ROOT/etc/nginx/ssl/$1"
        : > "$FIX_ROOT/etc/nginx/ssl/$1/fullchain.pem"
        return 0
    }
    SYSTEMCTL_RELOAD_COUNT=0 NGINX_TEST_COUNT=0 NGINX_TEST_FAIL=0 SYSTEMCTL_RELOAD_FAIL=0
}

teardown() { teardown_test_env; }

_subscription_input() {
    printf '%s\n' subs.example.com "$@" ''
}

@test "custom subscription port validates canonical decimal input" {
    local input="$BATS_TEST_TMPDIR/input"
    {
        printf '%s\n' subs.example.com 2 abc 0 65536 01
        printf '%s\n' 999999999999999999999999999999999999999999999999999999999999
        printf '%s\n\n' 2096
    } > "$input"
    run setup_subscription < "$input"
    assert_success
    _load_sub_conf
    [[ "$SUB_PORT" == 2096 ]]
    [[ "$SUB_MODE" == standalone ]]
}

@test "custom subscription EOF fails before persisting state" {
    printf '%s\n' subs.example.com 2 > "$BATS_TEST_TMPDIR/input"
    run setup_subscription < "$BATS_TEST_TMPDIR/input"
    assert_failure
    [[ ! -e "$SUB_CONF" ]]
    [[ ! -e "${ACME_MARKER:-}" ]]
}

@test "persistence failure prevents provisioning side effects" {
    mktemp() { return 1; }
    printf '%s\n' subs.example.com 1 '' > "$BATS_TEST_TMPDIR/input"
    run setup_subscription < "$BATS_TEST_TMPDIR/input"
    assert_failure
    [[ ! -e "$SUB_CONF" ]]
    [[ ! -e "${ACME_MARKER:-}" ]]
}

@test "late nginx failure leaves recoverable subscription state" {
    NGINX_TEST_FAIL=1
    printf '%s\n' subs.example.com 1 '' > "$BATS_TEST_TMPDIR/input"
    run setup_subscription < "$BATS_TEST_TMPDIR/input"
    assert_failure
    _load_sub_conf
    mkdir -p "$FIX_ROOT/etc/nginx/sites-enabled" "$FIX_ROOT/etc/nginx/sites-available" \
        "$FIX_ROOT/etc/nginx/snippets/essence-sub" "$FIX_ROOT/var/www/subs.example.com" \
        "$FIX_ROOT/var/lib/essence-sub"
    : > "$FIX_ROOT/etc/nginx/sites-enabled/essence-sub"
    : > "$FIX_ROOT/etc/nginx/sites-available/essence-sub"
    : > "$FIX_ROOT/etc/nginx/sites-enabled/essence-sub-http"
    : > "$FIX_ROOT/etc/nginx/sites-available/essence-sub-http"
    : > "$FIX_ROOT/etc/nginx/snippets/essence-sub/sub-token.conf"
    : > "$FIX_ROOT/etc/nginx/ssl/subs.example.com/fullchain.pem"
    : > "$FIX_ROOT/etc/systemd/system/essence-sub-cleanup.timer"
    NGINX_TEST_FAIL=0
    remove_subscription
    [[ ! -e "$SUB_CONF" ]]
    [[ ! -e "$FIX_ROOT/etc/nginx/sites-enabled/essence-sub-http" ]]
    [[ ! -e "$FIX_ROOT/etc/nginx/sites-available/essence-sub-http" ]]
    [[ ! -e "$FIX_ROOT/etc/nginx/snippets/essence-sub/sub-token.conf" ]]
}

@test "reload failure also preserves state for removal" {
    SYSTEMCTL_RELOAD_FAIL=1
    printf '%s\n' subs.example.com 2 2096 '' > "$BATS_TEST_TMPDIR/input"
    run setup_subscription < "$BATS_TEST_TMPDIR/input"
    assert_failure
    _load_sub_conf
    [[ "$SUB_PORT" == 2096 ]]
    SYSTEMCTL_RELOAD_FAIL=0
    remove_subscription
    [[ ! -e "$SUB_CONF" ]]
}
