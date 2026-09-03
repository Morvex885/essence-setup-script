#!/usr/bin/env bats

VALID_WARP_PRIVATE_KEY='eCtXsJZ27+4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU='
VALID_WARP_PUBLIC_KEY='Cr8hWlKvtDt7nrvf+f0brNQQzabAqrjfBvas9pmowjo='

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/setup-essence/modules/warp.sh"
}

teardown() {
    teardown_test_env
}

parse_addresses() {
    parse_wgcf_address_line "$1" || return
    printf '%s|%s\n' "$WGCF_IPV4_ADDRESS" "$WGCF_IPV6_ADDRESS"
}

parse_profile_keys() {
    parse_wgcf_profile_keys "$1" || return
    printf '%s|%s\n' "$WGCF_PROFILE_PRIVATE_KEY" "$WGCF_PROFILE_PUBLIC_KEY"
}

render_profile_yaml() {
    parse_wgcf_profile_keys "$1" || return
    render_warp_yaml "$WGCF_PROFILE_PRIVATE_KEY" "172.16.0.2" "" "$WGCF_PROFILE_PUBLIC_KEY"
}

make_wgcf_mock() {
    local directory="$1"
    cat > "$directory/wgcf" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$WGCF_CALL_LOG"
case "$1" in
    --version)
        exit 0
        ;;
    register)
        [[ "${WGCF_REGISTER_EXIT:-0}" -eq 0 ]] || exit "$WGCF_REGISTER_EXIT"
        printf '%s\n' 'device_id = "test-device"' > "${WGCF_ACCOUNT_FILE:-wgcf-account.toml}"
        ;;
    update)
        exit "${WGCF_UPDATE_EXIT:-0}"
        ;;
    generate)
        [[ "${WGCF_GENERATE_EXIT:-0}" -eq 0 ]] || exit "$WGCF_GENERATE_EXIT"
        cat > "${WGCF_PROFILE_FILE:-wgcf-profile.conf}" <<'PROFILE'
[Interface]
PrivateKey = eCtXsJZ27+4PbhDkHnB923tkUn2Gj59wZw5wFA75MnU=
Address = 172.16.0.2/32, 2606:4700:110:8765::2/128
[Peer]
PublicKey = Cr8hWlKvtDt7nrvf+f0brNQQzabAqrjfBvas9pmowjo=
PROFILE
        ;;
esac
EOF
    chmod +x "$directory/wgcf"
}

prepare_account_in_dir() {
    local directory="$1" license="$2" require_license="${3:-0}"
    cd "$directory" || return
    WGCF_BIN="$directory/wgcf" _warp_prepare_account "$license" "$require_license"
}

generate_profile_in_dir() {
    local directory="$1"
    cd "$directory" || return
    WGCF_BIN="$directory/wgcf" _warp_generate_profile
}

apply_reregistered_profile() {
    local config="$1" source_profile="$2" stored_profile="$3" mihomo_bin="$4"

    MIHOMO_CONFIG_FILE="$config" \
    MIHOMO_WGCF_PROFILE_FILE="$stored_profile" \
    WGCF_PROFILE_FILE="$source_profile" \
    MIHOMO_BIN="$mihomo_bin" \
        _warp_apply_reregistered_profile \
            "$VALID_WARP_PRIVATE_KEY" "172.16.0.2" "2606:4700:110:8765::2" "$VALID_WARP_PUBLIC_KEY" \
        || return
    printf 'APPLIED=%s\n' "$WARP_REREGISTER_APPLIED"
}

@test "wgcf Address parser: dual-stack" {
    run parse_addresses "Address = 172.16.0.2/32, 2606:4700:110:8765::2/128"
    assert_success
    assert_output "172.16.0.2|2606:4700:110:8765::2"
}

@test "wgcf Address parser: reverse family order" {
    run parse_addresses "Address = 2606:4700:110:8765::2/128, 172.16.0.2/32"
    assert_success
    assert_output "172.16.0.2|2606:4700:110:8765::2"
}

@test "wgcf Address parser: extra whitespace and different CIDR masks" {
    run parse_addresses $' \tAddress  =  10.20.30.40/24 ,  2001:db8::7/64 \r'
    assert_success
    assert_output "10.20.30.40|2001:db8::7"
}

@test "wgcf Address parser: IPv4-only" {
    run parse_addresses "Address = 172.16.0.2/32"
    assert_success
    assert_output "172.16.0.2|"
}

@test "wgcf Address parser: IPv4 is required" {
    run parse_addresses "Address = 2606:4700:110:8765::2/128"
    assert_failure
}

@test "wgcf Address parser: malformed input is rejected" {
    run parse_addresses "Address = 999.1.2.3/32, 2001:::1/128, garbage"
    assert_failure
}

@test "wgcf key parser: preserves Base64 padding and trims whitespace with CRLF" {
    local profile="$BATS_TEST_TMPDIR/wgcf-profile.conf"
    printf '[Interface]\r\n  PrivateKey =  %s  \r\n[Peer]\r\nPublicKey = %s\r\n' \
        "$VALID_WARP_PRIVATE_KEY" "$VALID_WARP_PUBLIC_KEY" > "$profile"

    run parse_profile_keys "$profile"
    assert_success
    assert_output "$VALID_WARP_PRIVATE_KEY|$VALID_WARP_PUBLIC_KEY"
}

@test "wgcf value parser: preserves everything after the first equals sign" {
    local profile="$BATS_TEST_TMPDIR/wgcf-profile.conf"
    printf 'PrivateKey = %s=\n' "$VALID_WARP_PRIVATE_KEY" > "$profile"

    run _warp_profile_value PrivateKey "$profile"
    assert_success
    assert_output "${VALID_WARP_PRIVATE_KEY}="

    run _warp_valid_wireguard_key "${VALID_WARP_PRIVATE_KEY}="
    assert_failure
}

@test "wgcf key parser: rejects invalid length alphabet and padding" {
    local profile="$BATS_TEST_TMPDIR/wgcf-profile.conf" invalid
    local -a invalid_keys=(
        "${VALID_WARP_PRIVATE_KEY%=}"
        "${VALID_WARP_PRIVATE_KEY}="
        "-${VALID_WARP_PRIVATE_KEY:1}"
        "${VALID_WARP_PRIVATE_KEY%=}A"
        ""
    )

    for invalid in "${invalid_keys[@]}"; do
        printf 'PrivateKey = %s\nPublicKey = %s\n' \
            "$invalid" "$VALID_WARP_PUBLIC_KEY" > "$profile"
        run parse_profile_keys "$profile"
        assert_failure
    done
}

@test "wgcf key parser: ignores comments and similar parameter names" {
    local profile="$BATS_TEST_TMPDIR/wgcf-profile.conf"
    printf '# PrivateKey = %s\nNotPrivateKey = %s\nPublicKey = %s\n' \
        "$VALID_WARP_PRIVATE_KEY" "$VALID_WARP_PRIVATE_KEY" "$VALID_WARP_PUBLIC_KEY" > "$profile"

    run parse_profile_keys "$profile"
    assert_failure
}

@test "wgcf key parser: renders exact validated keys into WARP YAML" {
    local profile="$BATS_TEST_TMPDIR/wgcf-profile.conf"
    printf 'PrivateKey = %s\nPublicKey = %s\n' \
        "$VALID_WARP_PRIVATE_KEY" "$VALID_WARP_PUBLIC_KEY" > "$profile"

    run render_profile_yaml "$profile"
    assert_success
    assert_line "    private-key: \"$VALID_WARP_PRIVATE_KEY\""
    assert_line "    public-key: \"$VALID_WARP_PUBLIC_KEY\""
}

@test "WARP account: existing account is reused without registration" {
    local directory="$BATS_TEST_TMPDIR/wgcf"
    mkdir -p "$directory"
    make_wgcf_mock "$directory"
    printf '%s\n' 'device_id = "existing"' > "$directory/wgcf-account.toml"
    export WGCF_CALL_LOG="$directory/calls.log"

    run prepare_account_in_dir "$directory" ""
    assert_success
    refute_output --partial "Регистрирую"
    [[ ! -e "$WGCF_CALL_LOG" ]]
}

@test "WARP account: missing account is registered exactly once" {
    local directory="$BATS_TEST_TMPDIR/wgcf"
    mkdir -p "$directory"
    make_wgcf_mock "$directory"
    export WGCF_CALL_LOG="$directory/calls.log"

    run prepare_account_in_dir "$directory" ""
    assert_success
    [[ -s "$directory/wgcf-account.toml" ]]
    [[ "$(grep -c '^register$' "$WGCF_CALL_LOG")" -eq 1 ]]
    ! grep -q '^update ' "$WGCF_CALL_LOG"
}

@test "WARP account: license is applied to existing and new accounts" {
    local existing="$BATS_TEST_TMPDIR/existing" new="$BATS_TEST_TMPDIR/new"
    mkdir -p "$existing" "$new"
    make_wgcf_mock "$existing"
    make_wgcf_mock "$new"
    printf '%s\n' 'device_id = "existing"' > "$existing/wgcf-account.toml"

    export WGCF_CALL_LOG="$existing/calls.log"
    run prepare_account_in_dir "$existing" "plus-key"
    assert_success
    grep -q '^update --license-key plus-key$' "$WGCF_CALL_LOG"
    refute_output --partial "Регистрирую"

    export WGCF_CALL_LOG="$new/calls.log"
    run prepare_account_in_dir "$new" "plus-key"
    assert_success
    grep -q '^register$' "$WGCF_CALL_LOG"
    grep -q '^update --license-key plus-key$' "$WGCF_CALL_LOG"
}

@test "WARP account: registration failure is propagated" {
    local directory="$BATS_TEST_TMPDIR/wgcf"
    mkdir -p "$directory"
    make_wgcf_mock "$directory"
    export WGCF_CALL_LOG="$directory/calls.log"
    export WGCF_REGISTER_EXIT=1

    run prepare_account_in_dir "$directory" ""
    assert_failure
    [[ ! -e "$directory/wgcf-account.toml" ]]
}

@test "WARP account: strict license failure is propagated for re-registration" {
    local directory="$BATS_TEST_TMPDIR/wgcf"
    mkdir -p "$directory"
    make_wgcf_mock "$directory"
    printf '%s\n' 'device_id = "existing"' > "$directory/wgcf-account.toml"
    export WGCF_CALL_LOG="$directory/calls.log"
    export WGCF_UPDATE_EXIT=1

    run prepare_account_in_dir "$directory" "plus-key" 1
    assert_failure
    grep -q '^update --license-key plus-key$' "$WGCF_CALL_LOG"
}

@test "WARP profile generation: failed generation cannot reuse stale profile" {
    local directory="$BATS_TEST_TMPDIR/wgcf"
    mkdir -p "$directory"
    make_wgcf_mock "$directory"
    printf '%s\n' 'stale profile' > "$directory/wgcf-profile.conf"
    export WGCF_CALL_LOG="$directory/calls.log"
    export WGCF_GENERATE_EXIT=1

    run generate_profile_in_dir "$directory"
    assert_failure
    [[ ! -e "$directory/wgcf-profile.conf" ]]
}

@test "WARP account rollback: previous account and profile are restored" {
    local directory="$BATS_TEST_TMPDIR/wgcf"
    mkdir -p "$directory"
    printf '%s\n' 'old account' > "$directory/account.backup"
    printf '%s\n' 'old profile' > "$directory/profile.backup"
    printf '%s\n' 'new account' > "$directory/wgcf-account.toml"
    printf '%s\n' 'new profile' > "$directory/wgcf-profile.conf"

    run "${BASH:-bash}" -c "cd '$directory' && source '$PROJECT_ROOT/setup-essence/modules/warp.sh' && _warp_restore_account_files '$directory/account.backup' '$directory/profile.backup' 1"
    assert_success
    run cat "$directory/wgcf-account.toml"
    assert_output "old account"
    run cat "$directory/wgcf-profile.conf"
    assert_output "old profile"
}

@test "WARP re-registration: profile is prepared without changing an uninstalled config" {
    local config="$BATS_TEST_TMPDIR/config.yaml"
    local source_profile="$BATS_TEST_TMPDIR/wgcf-profile.conf"
    local stored_profile="$BATS_TEST_TMPDIR/stored-profile.conf"
    local mihomo_mock="$BATS_TEST_TMPDIR/mihomo"
    printf '%s\n' 'proxies:' '# --- proxies ---' '# --- /proxies ---' > "$config"
    printf '%s\n' 'new profile' > "$source_profile"
    printf '#!/bin/bash\nexit 0\n' > "$mihomo_mock"
    chmod +x "$mihomo_mock"

    run apply_reregistered_profile "$config" "$source_profile" "$stored_profile" "$mihomo_mock"
    assert_success
    assert_output "APPLIED=0"
    [[ ! -e "$stored_profile" ]]
    ! grep -q 'private-key' "$config"
}

@test "WARP re-registration: installed config and stored profile are updated" {
    local config="$BATS_TEST_TMPDIR/config.yaml"
    local source_profile="$BATS_TEST_TMPDIR/wgcf-profile.conf"
    local stored_profile="$BATS_TEST_TMPDIR/stored-profile.conf"
    local mihomo_mock="$BATS_TEST_TMPDIR/mihomo"
    cat > "$config" <<'EOF'
proxies:
# --- proxies ---
# --- warp ---
  - name: warp-wg
    type: wireguard
    private-key: "old-private"
    ip: 172.16.0.1
    public-key: "old-public"
# --- /warp ---
# --- /proxies ---
proxy-groups:
  - name: outbound
    proxies:
      - warp-wg
      - DIRECT
EOF
    printf '%s\n' 'new profile' > "$source_profile"
    printf '#!/bin/bash\nexit 0\n' > "$mihomo_mock"
    chmod +x "$mihomo_mock"

    run apply_reregistered_profile "$config" "$source_profile" "$stored_profile" "$mihomo_mock"
    assert_success
    assert_output "APPLIED=1"
    grep -q "private-key: \"$VALID_WARP_PRIVATE_KEY\"" "$config"
    cmp -s "$source_profile" "$stored_profile"
}

@test "WARP re-registration: profile persistence failure restores config" {
    local config="$BATS_TEST_TMPDIR/config.yaml"
    local original="$BATS_TEST_TMPDIR/original.yaml"
    local source_profile="$BATS_TEST_TMPDIR/wgcf-profile.conf"
    local stored_profile="$BATS_TEST_TMPDIR/missing/stored-profile.conf"
    local mihomo_mock="$BATS_TEST_TMPDIR/mihomo"
    cat > "$config" <<'EOF'
proxies:
# --- proxies ---
# --- warp ---
old block
# --- /warp ---
# --- /proxies ---
EOF
    cp "$config" "$original"
    printf '%s\n' 'new profile' > "$source_profile"
    printf '#!/bin/bash\nexit 0\n' > "$mihomo_mock"
    chmod +x "$mihomo_mock"

    run apply_reregistered_profile "$config" "$source_profile" "$stored_profile" "$mihomo_mock"
    assert_failure
    cmp -s "$config" "$original"
}

@test "WARP renderer: dual-stack includes IPv6 route and no proxy DNS" {
    run render_warp_yaml "private" "172.16.0.2" "2606:4700:110:8765::2" "public"
    assert_success
    assert_line "    ip: 172.16.0.2"
    assert_line "    ipv6: 2606:4700:110:8765::2"
    assert_line "    allowed-ips: ['0.0.0.0/0', '::/0']"
    refute_output --partial "dns:"
}

@test "WARP renderer: IPv4-only omits IPv6 and its default route" {
    run render_warp_yaml "private" "172.16.0.2" "" "public"
    assert_success
    assert_line "    ip: 172.16.0.2"
    assert_line "    allowed-ips: ['0.0.0.0/0']"
    refute_output --partial "    ipv6:"
    refute_output --partial "::/0"
    refute_output --partial "dns:"
}

@test "WARP update replaces only the marker block" {
    local config="$BATS_TEST_TMPDIR/config.yaml"
    local block="$BATS_TEST_TMPDIR/warp.yaml"
    cat > "$config" <<'EOF'
ipv6: false
proxies:
# --- proxies ---
  - name: neighbor-wg
    type: wireguard
    private-key: "neighbor-private"
    ip: 10.0.0.9
    public-key: "neighbor-public"
# --- warp ---
  - name: warp-wg
    type: wireguard
    private-key: "old-private"
    ip: 172.16.0.1
    public-key: "old-public"
# --- /warp ---
# --- /proxies ---
proxy-groups:
  - name: outbound
    proxies:
      - warp-wg
      - DIRECT
EOF
    render_warp_yaml "new-private" "172.16.0.2" "2001:db8::2" "new-public" > "$block"

    run build_warp_config_candidate update "$config" "$block"
    assert_success
    assert_line '    private-key: "neighbor-private"'
    assert_line '    ip: 10.0.0.9'
    assert_line '    public-key: "neighbor-public"'
    assert_line '    private-key: "new-private"'
    refute_output --partial "old-private"
}

@test "WARP install inserts after proxies marker and adds outbound member once" {
    local config="$BATS_TEST_TMPDIR/config.yaml"
    local block="$BATS_TEST_TMPDIR/warp.yaml"
    cat > "$config" <<'EOF'
proxies:
# --- proxies ---
# --- /proxies ---
proxy-groups:
  - name: outbound
    proxies:
      - DIRECT
EOF
    render_warp_yaml "private" "172.16.0.2" "" "public" > "$block"

    run build_warp_config_candidate install "$config" "$block"
    assert_success
    assert_line --index 2 "# --- warp ---"
    [[ "$(grep -c '^      - warp-wg$' <<< "$output")" -eq 1 ]]
}

@test "WARP atomic apply keeps working config when mihomo rejects candidate" {
    local config="$BATS_TEST_TMPDIR/config.yaml"
    local original="$BATS_TEST_TMPDIR/original.yaml"
    local mihomo_mock="$BATS_TEST_TMPDIR/mihomo"
    cat > "$config" <<'EOF'
proxies:
# --- proxies ---
# --- warp ---
old block
# --- /warp ---
# --- /proxies ---
EOF
    cp "$config" "$original"
    printf '#!/bin/bash\nexit 1\n' > "$mihomo_mock"
    chmod +x "$mihomo_mock"
    export MIHOMO_CONFIG_FILE="$config"
    export MIHOMO_BIN="$mihomo_mock"

    run _warp_apply_config update "$VALID_WARP_PRIVATE_KEY" "172.16.0.2" "" "$VALID_WARP_PUBLIC_KEY"
    assert_failure
    cmp -s "$config" "$original"
}
