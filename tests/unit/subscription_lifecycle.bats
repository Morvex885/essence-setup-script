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
            if [[ "${OSTYPE:-}" == darwin* ]]; then
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
    issue_cert() { return 0; }
    install_cert() {
        mkdir -p "$FIX_ROOT/etc/nginx/ssl/$1"
        : > "$FIX_ROOT/etc/nginx/ssl/$1/fullchain.pem"
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
            : > "$HOME/.acme.sh/subs.example.com/subs.example.com.conf"
        fi
        if [[ "$registration" == ecc || "$registration" == both ]]; then
            mkdir -p "$HOME/.acme.sh/subs.example.com_ecc"
            : > "$HOME/.acme.sh/subs.example.com_ecc/subs.example.com.conf"
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
    [[ "$output" == *"Не удалось прочитать конфигурацию подписок."* ]]
    [[ -e "$SUB_CONF" ]]
}

@test "missing subscription configuration is a successful no-op" {
    run remove_subscription
    assert_success
    [[ "$output" == *"Subscription hosting не установлен."* ]]
    [[ "$output" != *"Subscription hosting удалён"* ]]
}

@test "subscription removal fails fast at every critical stage" {
    local stage mode registration expected output_file
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
                expected="Не удалось удалить nginx-конфигурацию подписок."
                ;;
            sni)
                _prepare_removal_fixture sni rsa 1
                FAIL_SNI_SED=1
                expected="Не удалось очистить nginx-конфигурацию подписок."
                ;;
            zone)
                FAIL_ZONE_SED=1
                expected="Не удалось очистить nginx-конфигурацию подписок."
                ;;
            ufw)
                FAIL_UFW=1
                expected="Не удалось удалить правило firewall подписок."
                ;;
            nginx-test)
                FAIL_NGINX_TEST=1
                expected="Nginx конфигурация не прошла проверку после удаления подписок."
                ;;
            reload)
                FAIL_SYSTEMCTL_RELOAD=1
                expected="Не удалось перезагрузить Nginx после удаления подписок."
                ;;
            timer)
                FAIL_TIMER_DISABLE=1
                expected="Не удалось остановить таймер очистки подписок."
                ;;
            units)
                RM_FAIL_MATCH=essence-sub-cleanup.service
                expected="Не удалось удалить автоочистку подписок."
                ;;
            daemon)
                FAIL_DAEMON_RELOAD=1
                expected="Не удалось обновить конфигурацию systemd."
                ;;
            acme)
                ACME_TEST_FAIL=1
                expected="Не удалось удалить регистрацию сертификата подписок."
                ;;
            files)
                RM_FAIL_MATCH=nginx/ssl/subs.example.com
                expected="Не удалось удалить файлы подписок."
                ;;
            config)
                RM_FAIL_MATCH=subscription.conf
                expected="Не удалось удалить конфигурацию подписок."
                ;;
        esac
        output_file="$BATS_TEST_TMPDIR/${stage}.output"
        if remove_subscription > "$output_file"; then
            printf 'stage %s unexpectedly succeeded\n' "$stage" >&2
            return 1
        fi
        [[ "$(cat "$output_file")" == *"$expected"* ]]
        [[ "$(cat "$output_file")" != *"Subscription hosting удалён"* ]]
        [[ -e "$SUB_CONF" ]]
        case "$stage" in
            nginx-test) ! [[ "$(cat "$OPS_LOG")" == *"systemctl reload nginx"* ]] ;;
            daemon) [[ -e "$HOME/.acme.sh/subs.example.com/subs.example.com.conf" ]] &&
                    [[ -e "$FIX_ROOT/var/lib/essence-sub/subscription.yaml" ]] ;;
            acme) [[ -e "$FIX_ROOT/etc/nginx/ssl/subs.example.com/fullchain.pem" ]] ;;
            files|config) [[ -e "$HOME/.acme.sh/subs.example.com/subs.example.com.conf.removed" ]] ;;
            *) [[ -e "$FIX_ROOT/etc/systemd/system/essence-sub-cleanup.timer" ]] ;;
        esac
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
    [[ "$(cat "$ACME_TEST_LOG")" == *"--remove -d subs.example.com"* ]]
    [[ "$(cat "$ACME_TEST_LOG")" == *"--remove -d subs.example.com --ecc"* ]]
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
    RM_FAIL_MATCH=nginx/ssl/subs.example.com
    if remove_subscription; then
        return 1
    fi
    [[ -e "$SUB_CONF" ]]
    [[ -e "$HOME/.acme.sh/subs.example.com/subs.example.com.conf.removed" ]]
    [[ -e "$FIX_ROOT/var/www/subs.example.com" ]]
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
