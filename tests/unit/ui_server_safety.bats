#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    export SERVER_FIX="$BATS_TEST_TMPDIR/server"
    mkdir -p "$SERVER_FIX/etc/mihomo" "$SERVER_FIX/etc/sysctl.d" \
        "$SERVER_FIX/etc/systemd/system" "$SERVER_FIX/etc/ssh" "$SERVER_FIX/root/wgcf" \
        "$SERVER_FIX/opt" "$SERVER_FIX/tmp" "$SERVER_FIX/usr/local/bin"
    printf 'Port 2222\nPasswordAuthentication no\n' > "$SERVER_FIX/etc/ssh/sshd_config"
    printf 'proxies:\n# --- proxies ---\n# --- /proxies ---\nlisteners:\nrule-providers:\n' > "$SERVER_FIX/etc/mihomo/config.yaml"
    printf 'Server: 192.0.2.1\nShort ID: deadbeef\n' > "$SERVER_FIX/etc/mihomo/client-config.txt"
    export REAL_SED="$(command -v sed)"
    local module
    for module in base hysteria warp cascade fake-site; do
        "$REAL_SED" -e 's|/etc|__ESSENCE_SERVER_FIX__/etc|g' \
            -e 's|/root|__ESSENCE_SERVER_FIX__/root|g' \
            -e 's|/usr/local/bin|__ESSENCE_SERVER_FIX__/usr/local/bin|g' \
            -e 's|/tmp/|__ESSENCE_SERVER_FIX__/tmp/|g' \
            -e 's|/opt/|__ESSENCE_SERVER_FIX__/opt/|g' \
            -e "s|__ESSENCE_SERVER_FIX__|$SERVER_FIX|g" \
            "$PROJECT_ROOT/setup-essence/modules/$module.sh" > "$BATS_TEST_TMPDIR/$module.sh"
        source "$BATS_TEST_TMPDIR/$module.sh"
    done
    source "$PROJECT_ROOT/common/protocols/hy2.sh"
    # Production uses GNU sed -i; use a portable equivalent in the sandbox.
    sed() {
        if [[ "${1:-}" == -i ]]; then
            shift
            local file="${!#}"
            "$REAL_SED" "$@" > "$file.test-tmp" && mv "$file.test-tmp" "$file"
        else
            "$REAL_SED" "$@"
        fi
    }
    export ACTION_LOG="$BATS_TEST_TMPDIR/actions" CONFIRM_LOG="$BATS_TEST_TMPDIR/confirms"
    : > "$ACTION_LOG"
    : > "$CONFIRM_LOG"
    systemctl() {
        printf '%s\n' "$*" >> "$ACTION_LOG"
        case "$1" in start|restart) return "${START_RC:-0}" ;; esac
        return 0
    }
    journalctl() { return 0; }
    sleep() { return 0; }
    ufw() { printf 'ufw %s\n' "$*" >> "$ACTION_LOG"; }
    sysctl() { return 0; }
    apt_wait() { return 0; }
    apt-get() { return 0; }
    confirm_yn() { printf '%s\n' "$*" >> "$CONFIRM_LOG"; return 0; }
    success_box() { printf 'success-box\n' >> "$ACTION_LOG"; }
    openssl() {
        case "$1" in
            rand) printf '%s\n' SUPER_SECRET_MARKER ;;
            req) printf 'certificate\n' >> "$ACTION_LOG" ;;
            *) return 1 ;;
        esac
    }
    _get_server_addr() { printf '%s\n' 192.0.2.1; }
    _get_client_port() { printf '%s\n' 12345; }
}

teardown() { teardown_test_env; }

@test "WARP removal deletes only its proxy and outbound entry" {
    cat > "$SERVER_FIX/etc/mihomo/config.yaml" <<'EOF'
proxies:
  - name: before
    type: direct
# --- warp ---
  - name: warp-wg
    type: wireguard
    private-key: secret-key
# --- /warp ---
  - name: after
    type: direct
proxy-groups:
  - name: outbound
    proxies:
      - before
      - warp-wg
      - after
EOF
    run uninstall_warp
    assert_success
    ! grep -q 'warp\|secret-key' "$SERVER_FIX/etc/mihomo/config.yaml"
    grep -q '^  - name: before$' "$SERVER_FIX/etc/mihomo/config.yaml"
    grep -q '^  - name: after$' "$SERVER_FIX/etc/mihomo/config.yaml"
    grep -q '^      - before$' "$SERVER_FIX/etc/mihomo/config.yaml"
    grep -q '^      - after$' "$SERVER_FIX/etc/mihomo/config.yaml"
    [[ "$(wc -l < "$CONFIRM_LOG" | tr -d ' ')" == 1 ]]
}

@test "unmatched WARP marker cannot truncate the live Mihomo configuration" {
    printf '# --- warp ---\n  - name: warp-wg\n  - name: after\nrules:\n  - MATCH,DIRECT\n' > "$SERVER_FIX/etc/mihomo/config.yaml"
    printf 'profile\n' > "$SERVER_FIX/etc/mihomo/wgcf-profile.conf"
    cp "$SERVER_FIX/etc/mihomo/config.yaml" "$BATS_TEST_TMPDIR/before"
    run uninstall_warp
    assert_failure
    cmp "$BATS_TEST_TMPDIR/before" "$SERVER_FIX/etc/mihomo/config.yaml"
    [[ -f "$SERVER_FIX/etc/mihomo/wgcf-profile.conf" ]]
    [[ ! -s "$ACTION_LOG" ]]
}

@test "WARP removal leaves config and profile intact if atomic replacement fails" {
    printf '# --- warp ---\n  - name: warp-wg\n# --- /warp ---\n' > "$SERVER_FIX/etc/mihomo/config.yaml"
    printf 'profile\n' > "$SERVER_FIX/etc/mihomo/wgcf-profile.conf"
    cp "$SERVER_FIX/etc/mihomo/config.yaml" "$BATS_TEST_TMPDIR/before"
    mv() { return 1; }
    run uninstall_warp
    assert_failure
    cmp -s "$BATS_TEST_TMPDIR/before" "$SERVER_FIX/etc/mihomo/config.yaml"
    [[ -f "$SERVER_FIX/etc/mihomo/wgcf-profile.conf" ]]
    [[ ! -s "$ACTION_LOG" ]]
}

@test "base start failure wins over an active old process" {
    _install_mihomo_binary() { return 0; }
    _write_systemd_service() { return 0; }
    START_RC=1
    run install_base
    assert_failure 1
    grep -q '^start mihomo$' "$ACTION_LOG"
    [[ "$(wc -l < "$CONFIRM_LOG" | tr -d ' ')" == 1 ]]
}

@test "Hysteria restart failure does not publish credentials" {
    gen_free_port() { printf '12345\n'; }
    is_port_free() { return 0; }
    START_RC=1
    printf '\n\n\n1\n\n' > "$BATS_TEST_TMPDIR/input"
    run install_hy2 < "$BATS_TEST_TMPDIR/input"
    assert_failure 1
    [[ "$output" != *SUPER_SECRET_MARKER* ]]
    ! grep -q 'Password:\|URI:' "$SERVER_FIX/etc/mihomo/client-config.txt"
    ! grep -q 'success-box' "$ACTION_LOG"
}

@test "Hysteria review hides generated passwords on cancellation" {
    gen_free_port() { printf '12345\n'; }
    is_port_free() { return 0; }
    confirm_yn() {
        printf '%s\n' "$*" >> "$CONFIRM_LOG"
        [[ "$(wc -l < "$CONFIRM_LOG" | tr -d ' ')" == 1 ]]
    }
    printf '\n\n\n1\n\n' > "$BATS_TEST_TMPDIR/input"
    cp "$SERVER_FIX/etc/mihomo/config.yaml" "$BATS_TEST_TMPDIR/before"
    run install_hy2 < "$BATS_TEST_TMPDIR/input"
    [[ "$output" != *SUPER_SECRET_MARKER* ]]
    cmp -s "$BATS_TEST_TMPDIR/before" "$SERVER_FIX/etc/mihomo/config.yaml"
    [[ ! -s "$ACTION_LOG" ]]
}

@test "WARP restart failure is returned before final connection details" {
    printf '#!/bin/bash\nexit 0\n' > "$SERVER_FIX/root/wgcf/wgcf"
    chmod +x "$SERVER_FIX/root/wgcf/wgcf"
    _warp_prepare_account() { return 0; }
    _warp_generate_profile() { return 0; }
    parse_wgcf_profile_keys() { WGCF_PROFILE_PRIVATE_KEY=key; WGCF_PROFILE_PUBLIC_KEY=pub; }
    parse_wgcf_profile_addresses() { WGCF_IPV4_ADDRESS=172.16.0.2; WGCF_IPV6_ADDRESS=''; }
    _warp_apply_config() { return 0; }
    _warp_store_profile() { return 0; }
    START_RC=1
    printf '\n' > "$BATS_TEST_TMPDIR/input"
    run install_warp < "$BATS_TEST_TMPDIR/input"
    assert_failure 1
    [[ "$(grep -c '^restart mihomo$' "$ACTION_LOG")" == 1 ]]
    ! grep -q 'success-box' "$ACTION_LOG"
}

@test "existing cascade refusal leaves config and client records byte identical" {
    printf '# --- cascade:demo ---\n    server: old.example\n    port: 443\n# --- /cascade:demo ---\n' >> "$SERVER_FIX/etc/mihomo/config.yaml"
    cp "$SERVER_FIX/etc/mihomo/config.yaml" "$BATS_TEST_TMPDIR/config-before"
    cp "$SERVER_FIX/etc/mihomo/client-config.txt" "$BATS_TEST_TMPDIR/client-before"
    confirm_yn() { printf '%s\n' "$*" >> "$CONFIRM_LOG"; return 1; }
    _remove_cascade() { printf 'remove\n' >> "$ACTION_LOG"; }
    run _attach_cascade_to_listener demo hy2 $'  - name: demo\n    server: new.example\n    port: 8443\n    password: EXIT_SECRET_MARKER'
    assert_failure 1
    cmp -s "$BATS_TEST_TMPDIR/config-before" "$SERVER_FIX/etc/mihomo/config.yaml"
    cmp -s "$BATS_TEST_TMPDIR/client-before" "$SERVER_FIX/etc/mihomo/client-config.txt"
    [[ "$output" != *SUPER_SECRET_MARKER* && "$output" != *EXIT_SECRET_MARKER* ]]
    [[ "$(wc -l < "$CONFIRM_LOG" | tr -d ' ')" == 1 ]]
    [[ ! -s "$ACTION_LOG" ]]
}

@test "cascade restart failure does not publish a completed installation" {
    START_RC=1
    run _attach_cascade_to_listener demo hy2 $'  - name: demo\n    server: new.example\n    port: 8443'
    assert_failure 1
    [[ "$output" != *SUPER_SECRET_MARKER* ]]
    ! grep -q 'success-box' "$ACTION_LOG"
}

@test "fake site invalid input and cancellation do not retry the download" {
    wget() { printf 'wget\n' >> "$ACTION_LOG"; return 1; }
    printf '\ninvalid\n0\n' > "$BATS_TEST_TMPDIR/input"
    run _randomhtml simple "$SERVER_FIX/site" < "$BATS_TEST_TMPDIR/input"
    assert_failure 1
    [[ "$(wc -l < "$ACTION_LOG" | tr -d ' ')" == 1 ]]
    [[ ! -e "$SERVER_FIX/opt/main.zip" ]]
}

@test "fake site explicit retry performs only one additional attempt" {
    wget() { printf 'wget\n' >> "$ACTION_LOG"; return 1; }
    printf '1\n0\n' > "$BATS_TEST_TMPDIR/input"
    run _randomhtml simple "$SERVER_FIX/site" < "$BATS_TEST_TMPDIR/input"
    assert_failure 1
    [[ "$(wc -l < "$ACTION_LOG" | tr -d ' ')" == 2 ]]
}

@test "VLESS cascade cancellation hides its generated UUID and preserves the old cascade" {
    source "$PROJECT_ROOT/common/protocols/vless-tcp.sh"
    printf '# --- cascade:demo ---\n    server: old.example\n    port: 443\n# --- /cascade:demo ---\n' >> "$SERVER_FIX/etc/mihomo/config.yaml"
    cp "$SERVER_FIX/etc/mihomo/config.yaml" "$BATS_TEST_TMPDIR/config-before"
    cp "$SERVER_FIX/etc/mihomo/client-config.txt" "$BATS_TEST_TMPDIR/client-before"
    _load_cascade_reality() { SNI_DOMAIN=cover.example; PUBLIC_KEY=pub; SHORT_ID=deadbeef; }
    cat() {
        if [[ "$*" == /proc/sys/kernel/random/uuid ]]; then
            printf 'SECRET_UUID_MARKER\n'
        else
            command cat "$@"
        fi
    }
    confirm_yn() { printf '%s\n' "$*" >> "$CONFIRM_LOG"; return 1; }
    run _attach_cascade_to_listener demo vless-tcp $'  - name: demo\n    server: new.example\n    port: 8443'
    assert_failure 1
    [[ "$output" != *SECRET_UUID_MARKER* ]]
    cmp -s "$BATS_TEST_TMPDIR/config-before" "$SERVER_FIX/etc/mihomo/config.yaml"
    cmp -s "$BATS_TEST_TMPDIR/client-before" "$SERVER_FIX/etc/mihomo/client-config.txt"
    [[ "$(wc -l < "$CONFIRM_LOG" | tr -d ' ')" == 1 ]]
    [[ ! -s "$ACTION_LOG" ]]
}

@test "Hysteria selector cancellation stays in the menu without reporting a failed install" {
    gen_free_port() { printf '12345\n'; }
    is_port_free() { return 0; }
    warn() { printf 'warn\n' >> "$ACTION_LOG"; }
    cp "$SERVER_FIX/etc/mihomo/config.yaml" "$BATS_TEST_TMPDIR/config-before"
    printf '1\n\n\n\n0\n0\n' > "$BATS_TEST_TMPDIR/input"
    run hy2_menu < "$BATS_TEST_TMPDIR/input"
    assert_success
    cmp -s "$BATS_TEST_TMPDIR/config-before" "$SERVER_FIX/etc/mihomo/config.yaml"
    [[ ! -s "$CONFIRM_LOG" ]]
    [[ ! -s "$ACTION_LOG" ]]
}
