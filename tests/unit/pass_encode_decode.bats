#!/usr/bin/env bats
# Tests for node_pass_encode() / node_pass_decode() — AES-256-CBC encryption

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "nodes.sh"
    override_pass_key
}

teardown() {
    teardown_test_env
}

@test "pass round-trip: simple password" {
    local encoded
    encoded=$(node_pass_encode "password123")
    run node_pass_decode "$encoded"
    assert_success
    assert_output "password123"
}

@test "pass round-trip: special chars" {
    local encoded
    encoded=$(node_pass_encode 'p@ss!#%^&*()_+')
    run node_pass_decode "$encoded"
    assert_success
    assert_output 'p@ss!#%^&*()_+'
}

@test "pass round-trip: Unicode Cyrillic" {
    local encoded
    encoded=$(node_pass_encode "пароль")
    run node_pass_decode "$encoded"
    assert_success
    assert_output "пароль"
}

@test "pass round-trip: long password (500 chars)" {
    local long_pass
    long_pass=$(printf 'x%.0s' {1..500})
    local encoded
    encoded=$(node_pass_encode "$long_pass")
    run node_pass_decode "$encoded"
    assert_success
    assert_output "$long_pass"
}

@test "pass encode: produces non-empty base64" {
    run node_pass_encode "test"
    assert_success
    [[ -n "$output" ]]
    # Check it's valid base64 (no newlines, only base64 chars)
    [[ "$output" =~ ^[A-Za-z0-9+/=]+$ ]]
}

@test "pass decode: corrupted base64 returns empty, no crash" {
    run node_pass_decode "!!!not-base64!!!"
    # May return non-zero (openssl error), but should not crash and output should be empty
    assert_output ""
}

@test "pass decode: truncated encoded value returns empty" {
    local encoded
    encoded=$(node_pass_encode "hello")
    local truncated="${encoded:0:5}"
    run node_pass_decode "$truncated"
    assert_output ""
}

@test "pass decode: empty input returns empty" {
    run node_pass_decode ""
    assert_output ""
}

@test "pass round-trip: password with spaces" {
    local encoded
    encoded=$(node_pass_encode "my pass word")
    run node_pass_decode "$encoded"
    assert_success
    assert_output "my pass word"
}

@test "pass round-trip: password with equals signs" {
    local encoded
    encoded=$(node_pass_encode "key=value=123")
    run node_pass_decode "$encoded"
    assert_success
    assert_output "key=value=123"
}

@test "pass: encode then decode with fixture-like password" {
    local encoded
    encoded=$(node_pass_encode "testpass123")
    run node_pass_decode "$encoded"
    assert_success
    assert_output "testpass123"
}

@test "pass encode: same plaintext produces different ciphertext (random IV)" {
    local encoded1 encoded2
    encoded1=$(node_pass_encode "same-password")
    encoded2=$(node_pass_encode "same-password")
    # CBC uses random salt/IV, so two encryptions should differ
    [[ "$encoded1" != "$encoded2" ]]
}

@test "pass encode: different ciphertexts still decrypt to same plaintext" {
    local encoded1 encoded2
    encoded1=$(node_pass_encode "same-password")
    encoded2=$(node_pass_encode "same-password")
    local decoded1 decoded2
    decoded1=$(node_pass_decode "$encoded1")
    decoded2=$(node_pass_decode "$encoded2")
    [[ "$decoded1" == "$decoded2" ]]
    [[ "$decoded1" == "same-password" ]]
}
