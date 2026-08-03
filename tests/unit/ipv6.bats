#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/setup-essence/modules/ipv6.sh"
}

teardown() {
    teardown_test_env
}

write_ipv6_config() {
    cat > "$1" <<'EOF'
log-level: silent
ipv6: false
dns:
  enable: true
  ipv6: nested-value
profile:
  ipv6: another-nested-value
EOF
}

@test "mihomo IPv6 renderer enables only the top-level setting" {
    local config="$BATS_TEST_TMPDIR/config.yaml"
    write_ipv6_config "$config"

    run render_mihomo_ipv6_candidate true "$config"
    assert_success
    assert_line "ipv6: true"
    assert_line "  ipv6: nested-value"
    assert_line "  ipv6: another-nested-value"
    refute_line "ipv6: false"
}

@test "mihomo IPv6 renderer disables only the top-level setting" {
    local config="$BATS_TEST_TMPDIR/config.yaml"
    write_ipv6_config "$config"
    render_mihomo_ipv6_candidate true "$config" > "$BATS_TEST_TMPDIR/enabled.yaml"

    run render_mihomo_ipv6_candidate false "$BATS_TEST_TMPDIR/enabled.yaml"
    assert_success
    assert_line "ipv6: false"
    assert_line "  ipv6: nested-value"
    assert_line "  ipv6: another-nested-value"
    refute_line "ipv6: true"
}

@test "mihomo IPv6 renderer rejects missing or duplicate top-level setting" {
    local missing="$BATS_TEST_TMPDIR/missing.yaml"
    local duplicate="$BATS_TEST_TMPDIR/duplicate.yaml"
    printf 'dns:\n  ipv6: true\n' > "$missing"
    printf 'ipv6: true\nipv6: false\n' > "$duplicate"

    run render_mihomo_ipv6_candidate true "$missing"
    assert_failure
    run render_mihomo_ipv6_candidate false "$duplicate"
    assert_failure
}

@test "mihomo IPv6 atomic apply keeps config when validation fails" {
    local config="$BATS_TEST_TMPDIR/config.yaml"
    local original="$BATS_TEST_TMPDIR/original.yaml"
    local mihomo_mock="$BATS_TEST_TMPDIR/mihomo"
    write_ipv6_config "$config"
    cp "$config" "$original"
    printf '#!/bin/bash\nexit 1\n' > "$mihomo_mock"
    chmod +x "$mihomo_mock"
    export MIHOMO_CONFIG_FILE="$config"
    export MIHOMO_BIN="$mihomo_mock"

    run _apply_mihomo_ipv6_setting true
    assert_failure
    cmp -s "$config" "$original"
}
