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
    source "$PROJECT_ROOT/common/cert.sh"
    source "$PROJECT_ROOT/setup-essence/modules/telegram-proxy.sh"
    source "$PROJECT_ROOT/setup-essence/modules/uninstall.sh"
}

teardown() { teardown_test_env; }

@test "uninstall cancellation leaves Telegram Proxy untouched" {
    : > "$TPROXY_CONF"
    confirm_yn() { return 1; }
    menu_select() { MENU_SELECT_INDEX=1; return 0; }
    telegram_proxy_remove_all() { echo called > "$BATS_TEST_TMPDIR/called"; return 0; }
    run uninstall
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/called" ]
}

@test "uninstall stops before other components when Telegram removal fails" {
    : > "$TPROXY_CONF"
    confirm_yn() { return 0; }
    menu_select() { MENU_SELECT_INDEX=1; return 0; }
    telegram_proxy_remove_all() { return 1; }
    systemctl() { echo systemctl-called > "$BATS_TEST_TMPDIR/systemctl"; return 0; }
    run uninstall
    [ "$status" -eq 1 ]
    [ ! -e "$BATS_TEST_TMPDIR/systemctl" ]
}

_load_fixture_uninstall() {
    local root="$BATS_TEST_TMPDIR/uninstall-root" copy="$BATS_TEST_TMPDIR/uninstall.sh"
    mkdir -p "$root/etc/mihomo" "$root/etc/nginx/sites-available" \
        "$root/etc/nginx/sites-enabled" "$root/etc/systemd/system" \
        "$root/etc/sysctl.d" "$root/etc/ssh" "$root/usr/local/bin" \
        "$root/root" "$root/var/www"
    sed -e 's|/etc|@FIX_ROOT@/etc|g' -e 's|/root|@FIX_ROOT@/root|g' \
        -e 's|/usr/local/bin|@FIX_ROOT@/usr/local/bin|g' \
        -e 's|/var/www|@FIX_ROOT@/var/www|g' \
        -e "s|@FIX_ROOT@|$root|g" \
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
    menu_select() { MENU_SELECT_INDEX=1; return 0; }
    _uninstall_sshd_effective() { return 1; }
}

@test "Telegram rc3 allows complete fixture cleanup and reports leftovers" {
    _load_fixture_uninstall
    : > "$TPROXY_RELAY_SOURCE_PATH"
    : > "$FIXTURE_UNINSTALL_ROOT/etc/mihomo/config.yaml"
    telegram_proxy_remove_all() { return 3; }
    run uninstall
    assert_success
    assert_output --partial "Конфигурация Telegram Proxy не найдена"
    assert_output --partial "$TPROXY_RELAY_SOURCE_PATH"
    refute_output --partial "Всё удалено."
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

@test "full uninstall removes paused archive without acme executable and only marked challenge sites" {
    _load_fixture_uninstall
    local available="$FIXTURE_UNINSTALL_ROOT/etc/nginx/sites-available"
    local enabled="$FIXTURE_UNINSTALL_ROOT/etc/nginx/sites-enabled"
    mkdir -p "$HOME/.acme.sh/web.example.test_ecc" "$FIXTURE_UNINSTALL_ROOT/etc/nginx/ssl/web.example.test"
    printf 'retained-key\n' > "$HOME/.acme.sh/web.example.test_ecc/web.example.test.key"
    printf "Le_Domain='web.example.test'\n" > "$HOME/.acme.sh/web.example.test_ecc/web.example.test.conf.removed"
    printf '# Essence ACME challenge\n' > "$available/essence-acme-web.example.test"
    ln -s "$available/essence-acme-web.example.test" "$enabled/essence-acme-web.example.test"
    printf '# Unmanaged site\n' > "$available/essence-acme-unmanaged"
    uninstall
    [[ ! -e "$HOME/.acme.sh" ]]
    [[ ! -e "$FIXTURE_UNINSTALL_ROOT/etc/nginx/ssl" ]]
    [[ ! -e "$available/essence-acme-web.example.test" ]]
    [[ ! -L "$enabled/essence-acme-web.example.test" ]]
    [[ -f "$available/essence-acme-unmanaged" ]]
}

@test "full uninstall cleans cached custom Telegram paths without deleting unrelated custom root" {
    _load_fixture_uninstall
    local custom="$BATS_TEST_TMPDIR/custom"
    export TPROXY_CERT_DIR="$custom/certs" TPROXY_WEBROOT_BASE="$custom/www"
    export TPROXY_NGINX_AVAILABLE_DIR="$custom/available" TPROXY_NGINX_ENABLED_DIR="$custom/enabled"
    mkdir -p "$TPROXY_CERT_DIR/web.example.test" "$TPROXY_CERT_DIR/other.example.test" \
        "$TPROXY_WEBROOT_BASE/web.example.test" "$TPROXY_NGINX_AVAILABLE_DIR" "$TPROXY_NGINX_ENABLED_DIR"
    printf 'key\n' > "$TPROXY_CERT_DIR/web.example.test/privkey.pem"
    printf 'unrelated\n' > "$TPROXY_CERT_DIR/other.example.test/privkey.pem"
    printf '# Essence ACME challenge\n' > "$TPROXY_NGINX_AVAILABLE_DIR/essence-acme-web.example.test"
    ln -s "$TPROXY_NGINX_AVAILABLE_DIR/essence-acme-web.example.test" "$TPROXY_NGINX_ENABLED_DIR/essence-acme-web.example.test"
    : > "$TPROXY_CONF"
    _telegram_proxy_load_conf() { TELEGRAM_WEB_ENABLED=true; TELEGRAM_WEB_HOSTNAME=web.example.test; }
    telegram_proxy_remove_all() { rm -f "$TPROXY_CONF"; return 0; }
    uninstall
    [[ ! -e "$TPROXY_CERT_DIR/web.example.test" ]]
    [[ ! -e "$TPROXY_WEBROOT_BASE/web.example.test" ]]
    [[ ! -e "$TPROXY_NGINX_AVAILABLE_DIR/essence-acme-web.example.test" ]]
    [[ ! -L "$TPROXY_NGINX_ENABLED_DIR/essence-acme-web.example.test" ]]
    [[ -f "$TPROXY_CERT_DIR/other.example.test/privkey.pem" ]]
}

@test "full uninstall removes recorded VLESS site rather than a shared challenge hostname" {
    _load_fixture_uninstall
    local available="$FIXTURE_UNINSTALL_ROOT/etc/nginx/sites-available"
    local enabled="$FIXTURE_UNINSTALL_ROOT/etc/nginx/sites-enabled"
    printf '# Essence ACME challenge\nserver_name another.example.test;\n' > "$available/essence-acme-another.example.test"
    printf 'server_name another.example.test;\n' > "$available/another.example.test"
    printf 'server_name another.example.test web.example.test;\n' > "$available/web.example.test"
    ln -s "$available/web.example.test" "$enabled/web.example.test"
    _load_reality_conf() { HAS_SITE=true; SITE_NAME=web.example.test; }
    uninstall
    [[ ! -e "$available/web.example.test" ]]
    [[ ! -L "$enabled/web.example.test" ]]
    [[ -e "$available/another.example.test" ]]
    [[ ! -e "$available/essence-acme-another.example.test" ]]
}

@test "noninteractive component removal preserves hardened SSH without asking questions" {
    _load_fixture_uninstall
    printf 'Port 2222\nPasswordAuthentication no\n' > "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config"
    cp "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/ssh-before"
    : > "$FIXTURE_UNINSTALL_ROOT/etc/mihomo/config.yaml"
    confirm_yn() { printf 'confirm\n' >> "$BATS_TEST_TMPDIR/questions"; return 1; }
    menu_select() { printf 'selector\n' >> "$BATS_TEST_TMPDIR/questions"; return 1; }
    ufw() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/firewall"; }
    _uninstall_components false
    [[ ! -e "$BATS_TEST_TMPDIR/questions" ]]
    [[ ! -e "$FIXTURE_UNINSTALL_ROOT/etc/mihomo/config.yaml" ]]
    cmp -s "$BATS_TEST_TMPDIR/ssh-before" "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config"
    grep -q '^allow 2222/tcp$' "$BATS_TEST_TMPDIR/firewall"
    grep -q '^--force enable$' "$BATS_TEST_TMPDIR/firewall"
    ! grep -q '^--force disable$' "$BATS_TEST_TMPDIR/firewall"
}

@test "SSH selector cancellation happens before any component removal" {
    _load_fixture_uninstall
    printf 'Port 2222\n' > "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config"
    : > "$FIXTURE_UNINSTALL_ROOT/etc/mihomo/config.yaml"
    menu_select() { return 1; }
    confirm_yn() { printf 'confirm\n' >> "$BATS_TEST_TMPDIR/questions"; return 0; }
    run uninstall
    assert_success
    [[ -f "$FIXTURE_UNINSTALL_ROOT/etc/mihomo/config.yaml" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/questions" ]]
}

@test "SSH restart failure restores sshd_config, retries once and keeps firewall" {
    _load_fixture_uninstall
    printf 'Port 2222\nPasswordAuthentication no\n' > "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config"
    cp "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/sshd-before"
    sed() {
        if [[ "${1:-}" == -i ]]; then
            shift
            local file="${!#}"
            command sed "$@" > "$file.test-tmp" && mv "$file.test-tmp" "$file"
        else
            command sed "$@"
        fi
    }
    systemctl() {
        printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/systemctl-calls"
        case "$*" in *'restart ssh'*) return 1 ;; esac
        return 0
    }
    ufw() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/firewall"; }
    _uninstall_sshd_effective() { printf 'port 22\npasswordauthentication yes\n'; }
    run _uninstall_components true
    assert_failure 1
    assert_output --partial "SSH не перезапустился"
    [[ "$(grep -c '^restart ssh.socket$' "$BATS_TEST_TMPDIR/systemctl-calls")" -eq 2 ]]
    grep -q '^restart sshd$' "$BATS_TEST_TMPDIR/systemctl-calls"
    grep -q '^restart ssh$' "$BATS_TEST_TMPDIR/systemctl-calls"
    awk '/^restart ssh$/ { failed = 1 } failed && /^daemon-reload$/ { found = 1 } END { exit !found }' "$BATS_TEST_TMPDIR/systemctl-calls"
    cmp -s "$BATS_TEST_TMPDIR/sshd-before" "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config"
    [[ ! -e "$BATS_TEST_TMPDIR/firewall" ]]
}

@test "SSH restart failure recovers sshd with the restored config before returning" {
    _load_fixture_uninstall
    printf 'Port 2222\nPasswordAuthentication no\n' > "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config"
    cp "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config" "$BATS_TEST_TMPDIR/sshd-before"
    systemctl() {
        printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/systemctl-calls"
        case "$*" in
            'restart ssh.socket')
                # The first restart chain fails; the recovery restart succeeds.
                [[ "$(grep -c '^restart ssh.socket$' "$BATS_TEST_TMPDIR/systemctl-calls")" -gt 1 ]] ;;
            'restart sshd'|'restart ssh') return 1 ;;
            *) return 0 ;;
        esac
    }
    ufw() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/firewall"; }
    _uninstall_sshd_effective() { printf 'port 22\npasswordauthentication yes\n'; }
    run _uninstall_components true
    assert_failure 1
    assert_output --partial "SSH перезапущен с ней"
    cmp -s "$BATS_TEST_TMPDIR/sshd-before" "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config"
    awk '/^restart ssh$/ { failed = 1 } failed && /^daemon-reload$/ { found = 1 } END { exit !found }' "$BATS_TEST_TMPDIR/systemctl-calls"
    [[ ! -e "$BATS_TEST_TMPDIR/firewall" ]]
}

@test "uninstall reads SSH port and password state from the effective sshd config" {
    _load_fixture_uninstall
    : > "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config"
    _uninstall_sshd_effective() { printf 'port 2222\npasswordauthentication no\n'; }
    _uninstall_prepare_targets
    [[ "$UNINSTALL_SSH_PORTS" == 2222 && "$UNINSTALL_PASSWORD_DISABLED" == true ]]
}

@test "without reality.conf only the Essence-created indented site is taken as Reality" {
    _load_fixture_uninstall
    local available="$FIXTURE_UNINSTALL_ROOT/etc/nginx/sites-available"
    _load_reality_conf() { return 1; }
    _uninstall_sshd_effective() { printf 'port 22\n'; }
    printf 'server {\n    server_name aaa.example.test;\n    ssl_certificate /srv/ssl/aaa.pem;\n}\n' > "$available/aaa.example.test"
    printf 'server {\n    server_name web.example.test;\n    ssl_certificate     %s/etc/nginx/ssl/web.example.test/fullchain.pem;\n}\n' \
        "$FIXTURE_UNINSTALL_ROOT" > "$available/web.example.test"
    _uninstall_prepare_targets
    [[ "$UNINSTALL_REALITY_SITE" == web.example.test ]] || return 1
    rm "$available/web.example.test"
    _uninstall_prepare_targets
    [[ -z "$UNINSTALL_REALITY_SITE" ]]
}

@test "kept SSH settings open every effective SSH port in UFW" {
    _load_fixture_uninstall
    : > "$FIXTURE_UNINSTALL_ROOT/etc/mihomo/config.yaml"
    _uninstall_sshd_effective() { printf 'port 2222\nport 22\nport 2222\npasswordauthentication no\n'; }
    _uninstall_prepare_targets
    [[ "$UNINSTALL_SSH_PORTS" == '2222 22' ]]
    ufw() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/firewall"; }
    _uninstall_components false
    grep -q '^allow 2222/tcp$' "$BATS_TEST_TMPDIR/firewall"
    grep -q '^allow 22/tcp$' "$BATS_TEST_TMPDIR/firewall"
    grep -q '^--force enable$' "$BATS_TEST_TMPDIR/firewall"
}

# Mirrors sshd -T: Include drop-ins precede the main file, Port accumulates,
# PasswordAuthentication keeps the first value.
_sshd_effective_from_files() {
    local dir="$FIXTURE_UNINSTALL_ROOT/etc/ssh" file
    for file in "$dir"/sshd_config.d/*.conf "$dir/sshd_config"; do
        [[ -f "$file" ]] && cat "$file"
    done | awk '
        $1 == "Port" { print "port " $2 }
        $1 == "PasswordAuthentication" && !seen { print "passwordauthentication " $2; seen = 1 }'
}

@test "SSH restore overrides sshd_config.d with a first drop-in and tolerates repeated port 22" {
    _load_fixture_uninstall
    local dropin="$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config.d/00-essence-uninstall.conf"
    mkdir -p "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config.d"
    printf 'Port 2222\nPasswordAuthentication no\n' > "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config"
    printf 'Port 22\nPasswordAuthentication no\n' > "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config.d/50-cloud-init.conf"
    _uninstall_sshd_effective() { _sshd_effective_from_files; }
    ufw() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/firewall"; }
    run _uninstall_components true
    assert_success
    assert_output --partial "SSH вернён на порт 22, вход по паролю включён"
    grep -qx 'PasswordAuthentication yes' "$dropin"
    ! grep -q '^Port' "$dropin" || return 1
    [[ "$(_sshd_effective_from_files | grep -c '^port 22$')" -eq 2 ]]
    grep -q '^--force disable$' "$BATS_TEST_TMPDIR/firewall"
}

@test "unverified SSH restore rolls back sshd_config and created drop-in before restart and firewall reset" {
    _load_fixture_uninstall
    local config="$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config"
    local dropin="$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config.d/00-essence-uninstall.conf"
    mkdir -p "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config.d"
    printf 'Port 2222\nPasswordAuthentication no\n' > "$config"
    printf 'Port 2222\n' > "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config.d/50-cloud-init.conf"
    cp "$config" "$BATS_TEST_TMPDIR/sshd-before"
    _uninstall_sshd_effective() { _sshd_effective_from_files; }
    systemctl() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/systemctl-calls"; return 0; }
    ufw() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/firewall"; }
    run _uninstall_components true
    assert_failure 1
    assert_output --partial "sshd -T не подтверждает порт 22 и вход по паролю"
    assert_output --partial "Исходная конфигурация SSH восстановлена"
    refute_output --partial "SSH вернён на порт 22"
    cmp -s "$BATS_TEST_TMPDIR/sshd-before" "$config"
    [[ ! -e "$dropin" ]]
    [[ -f "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config.d/50-cloud-init.conf" ]]
    ! grep -q '^restart ssh' "$BATS_TEST_TMPDIR/systemctl-calls" || return 1
    [[ ! -e "$BATS_TEST_TMPDIR/firewall" ]]
}

@test "failing sshd -T keeps an existing drop-in and restores sshd_config" {
    _load_fixture_uninstall
    local config="$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config"
    local dropin="$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config.d/00-essence-uninstall.conf"
    mkdir -p "$FIXTURE_UNINSTALL_ROOT/etc/ssh/sshd_config.d"
    printf 'Port 2222\nPasswordAuthentication no\n' > "$config"
    printf 'PasswordAuthentication yes\n' > "$dropin"
    cp "$config" "$BATS_TEST_TMPDIR/sshd-before"
    _uninstall_sshd_effective() { return 255; }
    ufw() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/firewall"; }
    run _uninstall_components true
    assert_failure 1
    cmp -s "$BATS_TEST_TMPDIR/sshd-before" "$config"
    [[ "$(cat "$dropin")" == 'PasswordAuthentication yes' ]]
    [[ ! -e "$BATS_TEST_TMPDIR/firewall" ]]
}

@test "nginx restart failure warns and still removes certificates and resets firewall" {
    _load_fixture_uninstall
    mkdir -p "$FIXTURE_UNINSTALL_ROOT/etc/nginx/ssl/web.example.test"
    : > "$FIXTURE_UNINSTALL_ROOT/etc/nginx/nginx.conf"
    systemctl() { [[ "$*" != 'restart nginx' ]]; }
    ufw() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/firewall"; }
    run _uninstall_components false
    assert_success
    assert_output --partial "Nginx не перезапустился"
    assert_output --partial "Удаление завершено с предупреждениями"
    refute_output --partial "Всё удалено."
    [[ ! -e "$FIXTURE_UNINSTALL_ROOT/etc/nginx/ssl" ]]
    grep -q '^--force reset$' "$BATS_TEST_TMPDIR/firewall"
}

@test "uninstall filesystem failure is returned before later removals" {
    _load_fixture_uninstall
    : > "$FIXTURE_UNINSTALL_ROOT/etc/mihomo/config.yaml"
    : > "$FIXTURE_UNINSTALL_ROOT/root/retained"
    rm() {
        case "$*" in *'/mihomo'*) return 1 ;; esac
        command rm "$@"
    }
    run _uninstall_components false
    assert_failure 1
    [[ -e "$FIXTURE_UNINSTALL_ROOT/etc/mihomo/config.yaml" ]]
    [[ -e "$FIXTURE_UNINSTALL_ROOT/root/retained" ]]
}
