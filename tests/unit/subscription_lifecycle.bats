#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    export HOME="$BATS_TEST_TMPDIR/home" FIX_ROOT="$BATS_TEST_TMPDIR/root"
    export CERT_MODULE_COPY="$BATS_TEST_TMPDIR/cert.sh"
    sed -e "s|/etc/nginx|$FIX_ROOT/etc/nginx|g" \
        "$PROJECT_ROOT/common/cert.sh" > "$CERT_MODULE_COPY"
    source "$CERT_MODULE_COPY"
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
    _load_reality_conf() { HAS_SITE=true; SITE_NAME=reality.example.com; return 0; }
    mkdir -p "$FIX_ROOT/etc/nginx/ssl/reality.example.com"
    : > "$FIX_ROOT/etc/nginx/ssl/reality.example.com/fullchain.pem"
    : > "$FIX_ROOT/etc/nginx/ssl/reality.example.com/privkey.pem"
    _detect_reality_mode() { printf '%s\n' sni; }
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
    export REAL_RM
    REAL_RM=$(command -v rm)
    export OPS_LOG ACME_TEST_LOG ACME_TEST_FAIL
    OPS_LOG="$BATS_TEST_TMPDIR/operations.log"
    ACME_TEST_LOG="$BATS_TEST_TMPDIR/acme.log"
    : > "$OPS_LOG"
    : > "$ACME_TEST_LOG"
    UFW_RULES="$BATS_TEST_TMPDIR/ufw-rules"
    : > "$UFW_RULES"
    FAIL_UFW_SHOW=0
    sed() {
        if [[ "${1:-}" == -i ]]; then
            shift
            printf 'sed %s\n' "$*" >> "$OPS_LOG"
            if [[ "${FAIL_SNI_SED:-0}" -eq 1 && "${1:-}" == *subscription* ]] ||
               [[ "${FAIL_ZONE_SED:-0}" -eq 1 && "${1:-}" == '/zone=sub/d' ]]
            then
                return 1
            fi
            if ! "$REAL_SED" --version >/dev/null 2>&1; then
                "$REAL_SED" -i '' "$@"
            else
                "$REAL_SED" -i "$@"
            fi
        else
            "$REAL_SED" "$@"
        fi
    }
    rm() {
        [[ -d "${OPS_LOG%/*}" ]] && printf 'rm %s\n' "$*" >> "$OPS_LOG"
        if [[ -n "${RM_FAIL_MATCH:-}" && "$*" == *"$RM_FAIL_MATCH"* ]]; then
            return 1
        fi
        "$REAL_RM" "$@"
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
    ufw() {
        printf 'ufw %s\n' "$*" >> "$OPS_LOG"
        case "$*" in
            "show added")
                [[ "$FAIL_UFW_SHOW" -eq 0 ]] || return 1
                cat "$UFW_RULES"
                ;;
            allow\ *)
                printf 'ufw %s\n' "$*" >> "$UFW_RULES"
                ;;
            delete\ allow\ *)
                [[ "${FAIL_UFW:-0}" -eq 0 ]] || return 1
                local rule="ufw ${*:2}"
                grep -Fxq "$rule" "$UFW_RULES" || return 1
                sed "\|^${rule}$|d" "$UFW_RULES" > "$UFW_RULES.tmp"
                mv "$UFW_RULES.tmp" "$UFW_RULES"
                ;;
            *) return 1 ;;
        esac
    }
    systemctl() {
        printf 'systemctl %s\n' "$*" >> "$OPS_LOG"
        if [[ "$1" == reload && "$2" == nginx ]]; then
            SYSTEMCTL_RELOAD_COUNT=$((SYSTEMCTL_RELOAD_COUNT + 1))
            if [[ "${FAIL_SYSTEMCTL_RELOAD:-0}" -eq 1 ]] ||
               [[ "${SYSTEMCTL_RELOAD_FAIL:-0}" -eq 1 && "$SYSTEMCTL_RELOAD_COUNT" -ne 2 ]]
            then
                return 1
            fi
        elif [[ "$1" == disable && "$2" == --now ]]; then
            [[ "${FAIL_TIMER_DISABLE:-0}" -eq 0 ]] || return 1
        elif [[ "$1" == daemon-reload ]]; then
            [[ "${FAIL_DAEMON_RELOAD:-0}" -eq 0 ]] || return 1
        fi
        return 0
    }
    nginx() {
        if [[ "$1" == -t ]]; then
            NGINX_TEST_COUNT=$((NGINX_TEST_COUNT + 1))
            printf 'nginx -t\n' >> "$OPS_LOG"
            if [[ "${FAIL_NGINX_TEST:-0}" -eq 1 ]] ||
               [[ "${NGINX_TEST_FAIL:-0}" -eq 1 && "$NGINX_TEST_COUNT" -ne 2 ]]
            then
                return 1
            fi
        fi
        if [[ "$1" == -T ]]; then
            [[ "${FAIL_NGINX_DUMP:-0}" -eq 0 ]] || return 1
            cat "$FIX_ROOT/etc/nginx/nginx.conf"
            local site
            for site in "$FIX_ROOT/etc/nginx/sites-enabled/"*; do
                [[ -f "$site" ]] && cat "$site"
            done
        fi
        return 0
    }
    ensure_acme_installed() {
        ACME_MARKER="$BATS_TEST_TMPDIR/acme-installed"
        mkdir -p "$HOME/.acme.sh"
        : > "$ACME_MARKER"
        cat > "$HOME/.acme.sh/acme.sh" <<'ACMEEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ACME_TEST_LOG"
[[ "${ACME_TEST_FAIL:-0}" -eq 0 ]] || exit 1
domain=
ecc=
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) domain="$2"; shift 2 ;;
        --ecc) ecc=_ecc; shift ;;
        *) shift ;;
    esac
done
conf="$HOME/.acme.sh/${domain}${ecc}/${domain}.conf"
[[ -f "$conf" ]] || exit 1
mv "$conf" "${conf}.removed"
ACMEEOF
        chmod 755 "$HOME/.acme.sh/acme.sh"
        return 0
    }
    ensure_essence_acme_email() { ensure_acme_installed "$1"; }
    ensure_cert() {
        mkdir -p "$FIX_ROOT/etc/nginx/ssl/$1"
        : > "$FIX_ROOT/etc/nginx/ssl/$1/fullchain.pem"
        : > "$FIX_ROOT/etc/nginx/ssl/$1/privkey.pem"
        return 0
    }
    SYSTEMCTL_RELOAD_COUNT=0 NGINX_TEST_COUNT=0 NGINX_TEST_FAIL=0 SYSTEMCTL_RELOAD_FAIL=0
    FAIL_SNI_SED=0 FAIL_ZONE_SED=0 FAIL_UFW=0 FAIL_SYSTEMCTL_RELOAD=0
    FAIL_NGINX_TEST=0 FAIL_TIMER_DISABLE=0 FAIL_DAEMON_RELOAD=0 RM_FAIL_MATCH=
}

teardown() { teardown_test_env; }

_subscription_input() {
    printf '%s\n' subs.example.com "$@" ''
}
_prepare_removal_fixture() {
    local mode="${1:-standalone}" registration="${2:-rsa}" timer="${3:-1}"
    "$REAL_RM" -rf "$FIX_ROOT" "$HOME/.acme.sh"
    mkdir -p "$FIX_ROOT/etc/mihomo" "$FIX_ROOT/etc/nginx/sites-enabled" \
        "$FIX_ROOT/etc/nginx/sites-available" "$FIX_ROOT/etc/nginx/ssl/subs.example.com" \
        "$FIX_ROOT/etc/nginx/snippets/essence-sub" "$FIX_ROOT/etc/systemd/system" \
        "$FIX_ROOT/usr/local/bin" "$FIX_ROOT/var/www/subs.example.com" \
        "$FIX_ROOT/var/lib/essence-sub" "$FIX_ROOT/etc/nginx"
    printf 'SUB_MODE=%s\nSUB_PORT=2096\nSUB_HOSTNAME=subs.example.com\nSUB_DIR=%s\n' \
        "$mode" "$FIX_ROOT/var/lib/essence-sub" > "$SUB_CONF"
    printf 'events {}\nhttp {}\n' > "$FIX_ROOT/etc/nginx/nginx.conf"
    : > "$FIX_ROOT/etc/nginx/sites-enabled/essence-sub"
    : > "$FIX_ROOT/etc/nginx/sites-available/essence-sub"
    : > "$FIX_ROOT/etc/nginx/sites-enabled/essence-sub-http"
    : > "$FIX_ROOT/etc/nginx/sites-available/essence-sub-http"
    : > "$FIX_ROOT/etc/nginx/ssl/subs.example.com/fullchain.pem"
    : > "$FIX_ROOT/etc/nginx/snippets/essence-sub/sub-token.conf"
    : > "$FIX_ROOT/var/lib/essence-sub/subscription.yaml"
    : > "$FIX_ROOT/var/www/subs.example.com/index.html"
    if [[ "$timer" -eq 1 ]]; then
        : > "$FIX_ROOT/etc/systemd/system/essence-sub-cleanup.service"
        : > "$FIX_ROOT/etc/systemd/system/essence-sub-cleanup.timer"
        : > "$FIX_ROOT/usr/local/bin/essence-sub-cleanup"
    fi
    if [[ "$registration" != none ]]; then
        ensure_acme_installed test@example.com
        if [[ "$registration" == rsa || "$registration" == both ]]; then
            mkdir -p "$HOME/.acme.sh/subs.example.com"
            printf "Le_Domain='subs.example.com'\nLe_Keylength='2048'\n" \
                > "$HOME/.acme.sh/subs.example.com/subs.example.com.conf"
        fi
        if [[ "$registration" == ecc || "$registration" == both ]]; then
            mkdir -p "$HOME/.acme.sh/subs.example.com_ecc"
            printf "Le_Domain='subs.example.com'\nLe_Keylength='ec-256'\n" \
                > "$HOME/.acme.sh/subs.example.com_ecc/subs.example.com.conf"
        fi
    fi
    : > "$OPS_LOG"
    : > "$ACME_TEST_LOG"
    SYSTEMCTL_RELOAD_COUNT=0 NGINX_TEST_COUNT=0 NGINX_TEST_FAIL=0 SYSTEMCTL_RELOAD_FAIL=0
    FAIL_SNI_SED=0 FAIL_ZONE_SED=0 FAIL_UFW=0 FAIL_SYSTEMCTL_RELOAD=0
    FAIL_NGINX_TEST=0 FAIL_TIMER_DISABLE=0 FAIL_DAEMON_RELOAD=0
    RM_FAIL_MATCH= ACME_TEST_FAIL=0
    FAIL_UFW_SHOW=0
    : > "$UFW_RULES"
    [[ "$mode" != standalone ]] || printf 'ufw allow 2096/tcp\n' > "$UFW_RULES"
    return 0
}

@test "malformed subscription configuration is preserved" {
    printf 'SUB_MODE=standalone\n' > "$SUB_CONF"
    run remove_subscription
    assert_failure
    [[ -e "$SUB_CONF" ]]
}

@test "missing subscription configuration is a successful no-op" {
    run remove_subscription
    assert_success
}

@test "subscription removal fails fast at every critical stage" {
    local stage mode registration output_file
    local -a stages=(
        sites sni zone ufw nginx-test reload timer units daemon acme files config
    )
    for stage in "${stages[@]}"; do
        mode=standalone
        registration=rsa
        _prepare_removal_fixture "$mode" "$registration" 1
        case "$stage" in
            sites)
                RM_FAIL_MATCH=sites-enabled/essence-sub
                ;;
            sni)
                _prepare_removal_fixture sni rsa 1
                FAIL_SNI_SED=1
                ;;
            zone)
                FAIL_ZONE_SED=1
                ;;
            ufw)
                FAIL_UFW=1
                ;;
            nginx-test)
                FAIL_NGINX_TEST=1
                ;;
            reload)
                FAIL_SYSTEMCTL_RELOAD=1
                ;;
            timer)
                FAIL_TIMER_DISABLE=1
                ;;
            units)
                RM_FAIL_MATCH=essence-sub-cleanup.service
                ;;
            daemon)
                FAIL_DAEMON_RELOAD=1
                ;;
            acme)
                ACME_TEST_FAIL=1
                ;;
            files)
                RM_FAIL_MATCH="$FIX_ROOT/var/lib/essence-sub"
                ;;
            config)
                RM_FAIL_MATCH=subscription.conf
                ;;
        esac
        output_file="$BATS_TEST_TMPDIR/${stage}.output"
        if remove_subscription > "$output_file"; then
            printf 'stage %s unexpectedly succeeded\n' "$stage" >&2
            return 1
        fi
        [[ -e "$SUB_CONF" ]] || return 1
        case "$stage" in
            nginx-test) ! [[ "$(cat "$OPS_LOG")" == *"systemctl reload nginx"* ]] ;;
            daemon) [[ -e "$HOME/.acme.sh/subs.example.com/subs.example.com.conf" ]] &&
                    [[ -e "$FIX_ROOT/var/lib/essence-sub/subscription.yaml" ]] ;;
            acme) [[ -e "$FIX_ROOT/etc/nginx/ssl/subs.example.com/fullchain.pem" ]] ;;
            files|config) [[ -e "$HOME/.acme.sh/subs.example.com/subs.example.com.conf.removed" ]] ;;
            *) [[ -e "$FIX_ROOT/etc/systemd/system/essence-sub-cleanup.timer" ]] ;;
        esac || return 1
    done
}

@test "complete subscription removal handles RSA and ECC registrations" {
    _prepare_removal_fixture standalone both 1
    remove_subscription
    [[ ! -e "$SUB_CONF" ]]
    [[ ! -e "$FIX_ROOT/etc/nginx/sites-enabled/essence-sub" ]]
    [[ ! -e "$FIX_ROOT/etc/nginx/sites-available/essence-sub-http" ]]
    [[ ! -e "$FIX_ROOT/etc/nginx/ssl/subs.example.com" ]]
    [[ ! -e "$FIX_ROOT/var/www/subs.example.com" ]]
    [[ ! -e "$FIX_ROOT/var/lib/essence-sub" ]]
    [[ ! -e "$FIX_ROOT/etc/nginx/snippets/essence-sub" ]]
    [[ -e "$HOME/.acme.sh/subs.example.com/subs.example.com.conf.removed" ]]
    [[ -e "$HOME/.acme.sh/subs.example.com_ecc/subs.example.com.conf.removed" ]]
}

@test "partial subscription removal without timer or ACME registration succeeds" {
    _prepare_removal_fixture standalone none 0
    remove_subscription
    [[ ! -e "$SUB_CONF" ]]
    [[ ! -e "$FIX_ROOT/var/lib/essence-sub" ]]
    [[ ! -e "$HOME/.acme.sh/acme.sh" ]]
    ! [[ "$(cat "$OPS_LOG")" == *"systemctl disable --now essence-sub-cleanup.timer"* ]]
}

@test "filesystem failure after ACME removal is retryable" {
    _prepare_removal_fixture standalone rsa 1
    RM_FAIL_MATCH="$FIX_ROOT/var/lib/essence-sub"
    if remove_subscription; then
        return 1
    fi
    [[ -e "$SUB_CONF" ]] || return 1
    [[ -e "$HOME/.acme.sh/subs.example.com/subs.example.com.conf.removed" ]] || return 1
    [[ ! -e "$HOME/.acme.sh/subs.example.com/subs.example.com.conf" ]] || return 1
    [[ ! -e "$FIX_ROOT/etc/nginx/ssl/subs.example.com" ]] || return 1
    [[ ! -e "$FIX_ROOT/var/www/subs.example.com" ]] || return 1
    [[ -e "$FIX_ROOT/var/lib/essence-sub/subscription.yaml" ]] || return 1
    RM_FAIL_MATCH=
    remove_subscription
    [[ ! -e "$SUB_CONF" ]]
}

@test "subscription cleanup retries after firewall deletion and nginx validation failure" {
    _prepare_removal_fixture standalone rsa 1
    FAIL_NGINX_TEST=1
    run remove_subscription
    assert_failure 1
    [[ ! -s "$UFW_RULES" ]]
    [[ -e "$SUB_CONF" ]]
    [[ -e "$FIX_ROOT/var/lib/essence-sub/subscription.yaml" ]]

    FAIL_NGINX_TEST=0
    : > "$OPS_LOG"
    run remove_subscription
    assert_success
    [[ ! -e "$SUB_CONF" ]]
    [[ ! -e "$FIX_ROOT/var/lib/essence-sub" ]]
    [[ "$(cat "$OPS_LOG")" == *"nginx -t"* ]]
    [[ "$(cat "$OPS_LOG")" == *"systemctl reload nginx"* ]]
    [[ "$(cat "$OPS_LOG")" != *"ufw delete"* ]]
}

@test "subscription cleanup skips absent rule and preserves unrelated firewall rules" {
    _prepare_removal_fixture standalone none 0
    printf 'ufw allow 12096/tcp\nufw allow 2096/udp\nufw deny 2096/tcp\n' > "$UFW_RULES"
    cp "$UFW_RULES" "$BATS_TEST_TMPDIR/before-rules"
    run remove_subscription
    assert_success
    [[ ! -e "$SUB_CONF" ]]
    cmp -s "$UFW_RULES" "$BATS_TEST_TMPDIR/before-rules"
    [[ "$(cat "$OPS_LOG")" == *"nginx -t"* ]]
    [[ "$(cat "$OPS_LOG")" != *"ufw delete"* ]]
}

@test "subscription cleanup preserves state when firewall rule query fails" {
    _prepare_removal_fixture standalone none 0
    FAIL_UFW_SHOW=1
    run remove_subscription
    assert_failure 1
    [[ -s "$UFW_RULES" ]]
    [[ -e "$SUB_CONF" ]]
    [[ "$(cat "$OPS_LOG")" != *"ufw delete"* ]]
    [[ "$(cat "$OPS_LOG")" != *"nginx -t"* ]]
}

_load_fixture_uninstall_for_lifecycle() {
    local copy="$BATS_TEST_TMPDIR/lifecycle-uninstall.sh"
    sed -e "s|/etc|$FIX_ROOT/etc|g" -e "s|/root|$FIX_ROOT/root|g" \
        -e "s|/usr/local/bin|$FIX_ROOT/usr/local/bin|g" \
        -e "s|/var/www|$FIX_ROOT/var/www|g" \
        "$PROJECT_ROOT/setup-essence/modules/uninstall.sh" > "$copy"
    source "$copy"
    export TPROXY_CONF="$FIX_ROOT/etc/tproxy-server/essence.conf"
    export TPROXY_ENV_FILE="$FIX_ROOT/etc/mtproxy/mtproxy.env"
    export TPROXY_RELAY_SOURCE_PATH="$FIX_ROOT/opt/tproxy-server-source"
    export TPROXY_MTPROXY_SOURCE_DIR="$FIX_ROOT/opt/MTProxy"
    mkdir -p "$FIX_ROOT/root" "$FIX_ROOT/opt" "$FIX_ROOT/etc/tproxy-server"
    menu_select() { MENU_SELECT_INDEX=1; return 0; }
}

@test "uninstall stops before Mihomo removal when subscription cleanup fails" {
    _prepare_removal_fixture standalone rsa 1
    : > "$FIX_ROOT/etc/mihomo/config.yaml"
    _load_fixture_uninstall_for_lifecycle
    FAIL_NGINX_TEST=1
    if uninstall; then
        return 1
    fi
    [[ -e "$FIX_ROOT/etc/mihomo/config.yaml" ]]
    [[ -e "$SUB_CONF" ]]
    ! [[ "$(cat "$OPS_LOG")" == *"systemctl stop mihomo"* ]]
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

@test "certificate failure leaves recoverable state without TLS subscription provisioning" {
    ensure_cert() { return 1; }
    printf '%s\n' subs.example.com 1 chosen@example.com > "$BATS_TEST_TMPDIR/input"
    run setup_subscription < "$BATS_TEST_TMPDIR/input"
    assert_failure
    _load_sub_conf
    [[ "$SUB_HOSTNAME" == subs.example.com ]]
    [[ ! -e "$FIX_ROOT/etc/nginx/sites-enabled/essence-sub" ]]
    [[ ! -e "$FIX_ROOT/etc/nginx/sites-enabled/essence-sub-http" ]]
}

@test "subscription rejected contact change returns without persisting state" {
    ensure_acme_installed old@example.com
    mkdir -p "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory"
    printf "ACCOUNT_URL='https://example.invalid/account'\nCA_EMAIL='old@example.com'\n" > "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf"
    confirm_yn() {
        [[ "$1" == Изменить* ]] && return 1
        return 0
    }
    printf '%s\n' subs.example.com 1 new@example.com > "$BATS_TEST_TMPDIR/input"
    run setup_subscription < "$BATS_TEST_TMPDIR/input"
    assert_failure
    [ ! -e "$SUB_CONF" ]
    [ ! -s "$ACME_TEST_LOG" ]
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
        "$FIX_ROOT/var/lib/essence-sub" "$FIX_ROOT/etc/nginx/ssl/subs.example.com"
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

@test "VLESS discovery uses Reality identity instead of a foreign certificate directory" {
    mkdir -p "$FIX_ROOT/etc/nginx/ssl/aaa-foreign.example.com"
    : > "$FIX_ROOT/etc/nginx/ssl/aaa-foreign.example.com/fullchain.pem"
    : > "$FIX_ROOT/etc/nginx/ssl/aaa-foreign.example.com/privkey.pem"
    HAS_SITE=false SITE_NAME=caller.example.com
    run _detect_site_name
    assert_success
    assert_output reality.example.com
    [[ "$HAS_SITE" == false && "$SITE_NAME" == caller.example.com ]]
}

@test "VLESS discovery rejects bare Reality and incomplete installed pairs" {
    _load_reality_conf() { HAS_SITE=false; SITE_NAME=reality.example.com; }
    run _detect_site_name
    assert_failure
    _load_reality_conf() { HAS_SITE=true; SITE_NAME=reality.example.com; }
    "$REAL_RM" "$FIX_ROOT/etc/nginx/ssl/reality.example.com/privkey.pem"
    run _detect_site_name
    assert_failure
}

@test "subscription preserves certificates and active renewal when nginx consumers cannot be inspected" {
    local reason
    for reason in dump variable; do
        _prepare_removal_fixture standalone rsa 0
        if [[ "$reason" == dump ]]; then
            FAIL_NGINX_DUMP=1
        else
            FAIL_NGINX_DUMP=0
            printf 'events {}\nhttp { server { ssl_certificate $dynamic_cert; } }\n' \
                > "$FIX_ROOT/etc/nginx/nginx.conf"
        fi
        run remove_subscription
        assert_failure
        [[ -e "$SUB_CONF" ]]
        [[ -e "$FIX_ROOT/etc/nginx/ssl/subs.example.com/fullchain.pem" ]]
        [[ -e "$FIX_ROOT/var/www/subs.example.com/index.html" ]]
        [[ -e "$HOME/.acme.sh/subs.example.com/subs.example.com.conf" ]]
        [[ ! -s "$ACME_TEST_LOG" ]]
    done
}

_prepare_subscription_crypto() {
    _prepare_removal_fixture standalone none 0
    source "$PROJECT_ROOT/tests/helpers/cert_fixture_helper.bash"
    cert_fixture_init "$BATS_TEST_TMPDIR/pki" || return 1
    cert_fixture_leaf "$BATS_TEST_TMPDIR/good" subs.example.com || return 1
    cert_fixture_archive subs.example.com "$BATS_TEST_TMPDIR/good" ecc active || return 1
    cert_fixture_installed "$FIX_ROOT/etc/nginx/ssl" subs.example.com "$BATS_TEST_TMPDIR/good" || return 1
    cert_fixture_fake_acme || return 1
    export FAKE_ACME_SOURCE="$BATS_TEST_TMPDIR/good"
    sed -e "s|/etc/nginx|$FIX_ROOT/etc/nginx|g" \
        "$PROJECT_ROOT/common/cert.sh" > "$CERT_MODULE_COPY"
    source "$CERT_MODULE_COPY"
    ensure_cert subs.example.com "$FIX_ROOT/var/www/subs.example.com" false || return 1
    cat > "$FIX_ROOT/etc/nginx/sites-available/essence-sub" <<EOF
server {
    listen 2096 ssl;
    server_name subs.example.com;
    ssl_certificate "$FIX_ROOT/etc/nginx/ssl/subs.example.com/fullchain.pem";
    ssl_certificate_key "$FIX_ROOT/etc/nginx/ssl/subs.example.com/privkey.pem";
}
EOF
    ln -sf "$FIX_ROOT/etc/nginx/sites-available/essence-sub" \
        "$FIX_ROOT/etc/nginx/sites-enabled/essence-sub"
    cp "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf" \
        "$BATS_TEST_TMPDIR/account-before"
}

@test "subscription removal keeps a trusted shared certificate and renewal for another TLS consumer" {
    _prepare_subscription_crypto
    cat > "$FIX_ROOT/etc/nginx/sites-available/another-consumer" <<EOF
server {
    listen 2443 ssl;
    server_name subs.example.com;
    ssl_certificate '$FIX_ROOT/etc/nginx/ssl/subs.example.com/fullchain.pem';
    ssl_certificate_key '$FIX_ROOT/etc/nginx/ssl/subs.example.com/privkey.pem';
}
EOF
    ln -s "$FIX_ROOT/etc/nginx/sites-available/another-consumer" \
        "$FIX_ROOT/etc/nginx/sites-enabled/another-consumer"
    remove_subscription
    [[ ! -e "$SUB_CONF" ]]
    [[ -e "$FIX_ROOT/etc/nginx/sites-enabled/another-consumer" ]]
    [[ -e "$FIX_ROOT/etc/nginx/sites-enabled/essence-acme-subs.example.com" ]]
    [[ -d "$FIX_ROOT/var/www/subs.example.com" ]]
    local conf="$HOME/.acme.sh/subs.example.com_ecc/subs.example.com.conf"
    [[ -e "$conf" && ! -e "$conf.removed" ]]
    _acme_conf_value "$conf" Le_Webroot
    [[ "$ACME_CONF_VALUE" == "$FIX_ROOT/var/www/subs.example.com" ]]
    cmp -s "$FIX_ROOT/etc/nginx/ssl/subs.example.com/fullchain.pem" "$BATS_TEST_TMPDIR/good/fullchain.pem"
    cmp -s "$FIX_ROOT/etc/nginx/ssl/subs.example.com/privkey.pem" "$BATS_TEST_TMPDIR/good/privkey.pem"
    cert_is_usable subs.example.com "$FIX_ROOT/etc/nginx/ssl/subs.example.com/fullchain.pem" \
        "$FIX_ROOT/etc/nginx/ssl/subs.example.com/privkey.pem"
    [[ ! -s "$ACME_ORDER_LOG" ]]
}

@test "last subscription removal retains archive and reinstall restores trusted TLS without an order" {
    _prepare_subscription_crypto
    printf '# ssl_certificate %s;\n# subs.example.com remains only in a comment\n' \
        "$FIX_ROOT/etc/nginx/ssl/subs.example.com/fullchain.pem" >> "$FIX_ROOT/etc/nginx/nginx.conf"
    remove_subscription
    [[ ! -e "$SUB_CONF" ]]
    [[ ! -e "$FIX_ROOT/etc/nginx/ssl/subs.example.com" ]]
    [[ ! -e "$FIX_ROOT/var/www/subs.example.com" ]]
    [[ ! -e "$FIX_ROOT/etc/nginx/sites-available/essence-acme-subs.example.com" ]]
    [[ ! -L "$FIX_ROOT/etc/nginx/sites-enabled/essence-acme-subs.example.com" ]]
    local archive="$HOME/.acme.sh/subs.example.com_ecc"
    [[ ! -e "$archive/subs.example.com.conf" && -e "$archive/subs.example.com.conf.removed" ]]
    cmp -s "$archive/fullchain.cer" "$BATS_TEST_TMPDIR/good/fullchain.pem"
    cmp -s "$archive/subs.example.com.key" "$BATS_TEST_TMPDIR/good/privkey.pem"
    cmp -s "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf" "$BATS_TEST_TMPDIR/account-before"

    cert_fixture_installed "$FIX_ROOT/etc/nginx/ssl" reality.example.com "$BATS_TEST_TMPDIR/good"
    printf '%s\n' subs.example.com 1 '' > "$BATS_TEST_TMPDIR/input"
    setup_subscription < "$BATS_TEST_TMPDIR/input"
    _load_sub_conf
    [[ "$SUB_HOSTNAME" == subs.example.com ]]
    [[ -e "$archive/subs.example.com.conf" && ! -e "$archive/subs.example.com.conf.removed" ]]
    [[ -e "$FIX_ROOT/etc/nginx/sites-enabled/essence-acme-subs.example.com" ]]
    [[ -e "$FIX_ROOT/etc/nginx/sites-enabled/essence-sub" ]]
    cert_is_usable subs.example.com "$FIX_ROOT/etc/nginx/ssl/subs.example.com/fullchain.pem" \
        "$FIX_ROOT/etc/nginx/ssl/subs.example.com/privkey.pem"
    cmp -s "$archive/fullchain.cer" "$BATS_TEST_TMPDIR/good/fullchain.pem"
    cmp -s "$archive/subs.example.com.key" "$BATS_TEST_TMPDIR/good/privkey.pem"
    [[ ! -s "$ACME_ORDER_LOG" ]]
}

@test "installed subscription hosting refuses setup without touching its artifacts" {
    _prepare_removal_fixture standalone rsa 1
    cp "$SUB_CONF" "$BATS_TEST_TMPDIR/sub-before"
    cp "$FIX_ROOT/var/lib/essence-sub/subscription.yaml" "$BATS_TEST_TMPDIR/yaml-before"
    local before_ops
    before_ops=$(cat "$OPS_LOG")
    run setup_subscription < /dev/null
    assert_failure 1
    cmp -s "$BATS_TEST_TMPDIR/sub-before" "$SUB_CONF"
    cmp -s "$BATS_TEST_TMPDIR/yaml-before" "$FIX_ROOT/var/lib/essence-sub/subscription.yaml"
    [[ "$(cat "$OPS_LOG")" == "$before_ops" ]]
}
