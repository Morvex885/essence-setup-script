#!/usr/bin/env bats
# Tests for _extract_names_by_keyword() — proxy name extraction

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/tests/helpers/mock_ssh.bash"
    source_module "nodes.sh"
    source_module "connections.sh"
}

teardown() {
    teardown_test_env
}

@test "extract_names: quoted name with matching keyword" {
    local config='  - name: "vless-reality"
    type: vless
    server: 1.2.3.4'
    run _extract_names_by_keyword "$config" "vless"
    assert_success
    assert_output "vless-reality"
}

@test "extract_names: multiple matches" {
    local config='  - name: "hy2-main"
    type: hysteria2
  - name: "hy2-backup"
    type: hysteria2'
    run _extract_names_by_keyword "$config" "hy2"
    assert_success
    assert_line "hy2-main"
    assert_line "hy2-backup"
}

@test "extract_names: no matches returns empty" {
    local config='  - name: "vless-reality"
    type: vless'
    run _extract_names_by_keyword "$config" "nonexistent"
    assert_success
    assert_output ""
}

@test "extract_names: empty config returns empty" {
    run _extract_names_by_keyword "" "vless"
    assert_success
    assert_output ""
}

@test "extract_names: unquoted name (fallback path)" {
    local config='  - name: vless-test
    type: vless'
    run _extract_names_by_keyword "$config" "vless"
    assert_success
    assert_output --partial "vless-test"
}

@test "extract_names: case insensitive matching" {
    local config='  - name: "VLESS-TEST"
    type: vless'
    run _extract_names_by_keyword "$config" "vless"
    assert_success
    assert_output --partial "VLESS-TEST"
}

@test "extract_names: name with special chars preserved in full" {
    local config='  - name: "hy2-main (test)"
    type: hysteria2'
    run _extract_names_by_keyword "$config" "hy2"
    assert_success
    assert_output "hy2-main (test)"
}

@test "extract_names: mixed — quoted found, unquoted skipped" {
    local config='  - name: "vless-reality"
    type: vless
  - name: vless-backup
    type: vless'
    run _extract_names_by_keyword "$config" "vless"
    assert_success
    assert_output "vless-reality"
    refute_output --partial "vless-backup"
}

@test "extract_names: all unquoted — fallback finds them" {
    local config='  - name: vless-reality
    type: vless
  - name: vless-backup
    type: vless'
    run _extract_names_by_keyword "$config" "vless"
    assert_success
    assert_output --partial "vless-reality"
    assert_output --partial "vless-backup"
}
