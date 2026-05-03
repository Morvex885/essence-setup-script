#!/usr/bin/env bats
# Tests for jq_r(), jq_w(), _ensure_config()

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
}

teardown() {
    teardown_test_env
}

@test "jq_r: read nodes length from default config" {
    run jq_r '.nodes | length'
    assert_success
    assert_output "0"
}

@test "jq_r: read group names from default config" {
    run jq_r '.groups[].name'
    assert_success
    assert_line "ROUTER"
    assert_line "PC"
    assert_line "MOBILE"
}

@test "jq_r: read non-existent field returns null" {
    run jq_r '.nonexistent'
    assert_success
    assert_output "null"
}

@test "jq_w: write then read persists" {
    jq_w '.nodes += [{"name":"test-node"}]'
    run jq_r '.nodes[0].name'
    assert_success
    assert_output "test-node"
}

@test "jq_w: write preserves other fields" {
    jq_w '.nodes += [{"name":"x"}]'
    run jq_r '.groups | length'
    assert_success
    assert_output "3"
}

@test "jq_w: invalid filter returns non-zero, original untouched" {
    local before
    before=$(cat "$CONFIG_JSON")
    run jq_w 'INVALID FILTER'
    assert_failure
    local after
    after=$(cat "$CONFIG_JSON")
    [[ "$before" == "$after" ]]
}

@test "jq_w: multiple writes accumulate" {
    jq_w '.nodes += [{"name":"a"}]'
    jq_w '.nodes += [{"name":"b"}]'
    run jq_r '.nodes | length'
    assert_success
    assert_output "2"
}

@test "_ensure_config: creates default config if missing" {
    rm -f "$CONFIG_JSON"
    _ensure_config
    [[ -f "$CONFIG_JSON" ]]
    run jq_r '.groups | length'
    assert_success
    assert_output "3"
}

@test "_ensure_config: does not overwrite existing config" {
    jq_w '.nodes += [{"name":"keep-me"}]'
    _ensure_config
    run jq_r '.nodes[0].name'
    assert_success
    assert_output "keep-me"
}

@test "jq_r: with fixture config — read node name" {
    load_fixture_config
    run jq_r '.nodes[0].name'
    assert_success
    assert_output "de-vps"
}

@test "jq_r: with fixture config — read connections" {
    load_fixture_config
    run jq_r '.connections | length'
    assert_success
    assert_output "2"
}
