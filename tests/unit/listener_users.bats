#!/usr/bin/env bats
# Server-side listener users helpers (common/listener-users.sh)

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
}

teardown() {
    teardown_test_env
}

@test "users YAML builders keep a last line without trailing newline and strip CR" {
    source "$PROJECT_ROOT/common/listener-users.sh"
    local out
    out=$(printf 'alice u1\r\nbob u2' | _build_vless_users_yaml vless-tcp)
    [[ "$out" == *'uuid: u1'$'\n'* && "$out" != *$'\r'* ]]
    grep -qxF '        uuid: u2' <<< "$out"
    out=$(printf 'alice p1\r\nbob p2' | _build_hy2_users_yaml)
    [[ "$out" == $'      alice: p1\n      bob: p2' ]]
}

@test "listener sync refuses missing end marker without changing config" {
    local config="$BATS_TEST_TMPDIR/config.yaml" patched="$BATS_TEST_TMPDIR/listener-users.sh"
    printf '# --- vless-tcp ---\n  # client-users-start\n  old: keep\n# --- /vless-tcp ---\nother: keep\n' > "$config"
    cp "$config" "$config.before"
    sed "s|/etc/mihomo/config.yaml|$config|g" "$PROJECT_ROOT/common/listener-users.sh" > "$patched"
    source "$patched"
    run _sync_listener_users vless-tcp '      new: value'
    [ "$status" -ne 0 ]
    cmp "$config.before" "$config"
}
