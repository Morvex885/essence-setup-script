#!/usr/bin/env bats
# Tests for client name validation regex: ^[a-zA-Z0-9._-]+$

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "clients.sh"
}

teardown() {
    teardown_test_env
}

# Use the real validation function from clients.sh
matches() {
    _validate_client_name "$1"
}

@test "client name: simple alpha" {
    run matches "client"
    assert_success
}

@test "client name: alphanumeric" {
    run matches "client123"
    assert_success
}

@test "client name: with dots" {
    run matches "my.client"
    assert_success
}

@test "client name: with hyphens" {
    run matches "my-client"
    assert_success
}

@test "client name: with underscores" {
    run matches "my_client"
    assert_success
}

@test "client name: mixed valid chars" {
    run matches "a1._-b"
    assert_success
}

@test "client name: single char" {
    run matches "a"
    assert_success
}

@test "client name: single dot rejected" {
    run matches "."
    assert_failure
}

@test "client name: single hyphen" {
    run matches "-"
    assert_success
}

@test "client name: long valid name" {
    local name
    name=$(printf 'a%.0s' {1..200})
    run matches "$name"
    assert_success
}

# --- Invalid names ---

@test "client name: empty string rejected" {
    run matches ""
    assert_failure
}

@test "client name: space inside rejected" {
    run matches "my client"
    assert_failure
}

@test "client name: leading space rejected" {
    run matches " client"
    assert_failure
}

@test "client name: Unicode rejected" {
    run matches "клиент"
    assert_failure
}

@test "client name: semicolon rejected" {
    run matches "cli;ent"
    assert_failure
}

@test "client name: dollar sign rejected" {
    run matches 'cli$ent'
    assert_failure
}

@test "client name: backtick rejected" {
    run matches 'cli`ent'
    assert_failure
}

@test "client name: slash rejected" {
    run matches "cli/ent"
    assert_failure
}

@test "client name: path traversal rejected" {
    run matches "../etc/passwd"
    assert_failure
}

@test "client name: pipe rejected" {
    run matches "a|b"
    assert_failure
}

@test "client name: shell injection rejected" {
    run matches 'cli;rm -rf /'
    assert_failure
}

@test "client name: newline rejected" {
    run matches $'cli\nent'
    assert_failure
}
