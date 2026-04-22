#!/usr/bin/env bats
# Tests for has_update() — semver version comparison

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
}

teardown() {
    teardown_test_env
}

# has_update uses latest_version() internally, which reads from _UPDATE_TMP file.
# We mock by writing directly to that file.

mock_latest() {
    _UPDATE_TMP="$BATS_TEST_TMPDIR/mock_latest"
    echo -n "$1" > "$_UPDATE_TMP"
}

@test "has_update: newer major version available" {
    mock_latest "v2.0.0"
    run has_update "1.0.0"
    assert_success
}

@test "has_update: newer minor version available" {
    mock_latest "v1.2.0"
    run has_update "1.1.0"
    assert_success
}

@test "has_update: newer patch version available" {
    mock_latest "v1.0.2"
    run has_update "1.0.1"
    assert_success
}

@test "has_update: same version — no update" {
    mock_latest "v1.0.0"
    run has_update "1.0.0"
    assert_failure
}

@test "has_update: current is newer — no update" {
    mock_latest "v1.0.0"
    run has_update "2.0.0"
    assert_failure
}

@test "has_update: current minor is newer — no update" {
    mock_latest "v1.1.0"
    run has_update "1.2.0"
    assert_failure
}

@test "has_update: current patch is newer — no update" {
    mock_latest "v1.0.1"
    run has_update "1.0.2"
    assert_failure
}

@test "has_update: current is 'none' — no update" {
    mock_latest "v2.0.0"
    run has_update "none"
    assert_failure
}

@test "has_update: empty latest — no update" {
    mock_latest ""
    run has_update "1.0.0"
    assert_failure
}

@test "has_update: v-prefix stripped for comparison" {
    mock_latest "v3.0.0"
    run has_update "3.0.0"
    assert_failure
}

@test "has_update: simple versions without patch" {
    mock_latest "v2.0"
    run has_update "1.0"
    assert_success
}

@test "has_update: single number versions" {
    mock_latest "v7"
    run has_update "5"
    assert_success
}

@test "_ver_gt: 1.10.0 > 1.2.0" {
    run _ver_gt "1.10.0" "1.2.0"
    assert_success
}

@test "_ver_gt: 1.2.0 is NOT > 1.10.0" {
    run _ver_gt "1.2.0" "1.10.0"
    assert_failure
}

@test "_ver_gt: equal versions" {
    run _ver_gt "1.0.0" "1.0.0"
    assert_failure
}
