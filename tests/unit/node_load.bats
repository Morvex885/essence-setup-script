#!/usr/bin/env bats
# Tests for node_load() / node_load_by_name()

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "nodes.sh"
    override_pass_key
    load_fixture_config

    # Re-encode the password in fixture with the deterministic key
    local encoded
    encoded=$(node_pass_encode "testpass123")
    jq_w --arg p "$encoded" '.nodes[1].pass = $p'
}

teardown() {
    teardown_test_env
}

@test "node_load: first node (key auth) sets globals" {
    node_load 1
    [[ "$NODE_NAME" == "de-vps" ]]
    [[ "$SERVER_IP" == "1.2.3.4" ]]
    [[ "$SERVER_PORT" == "22" ]]
    [[ "$SERVER_USER" == "root" ]]
    [[ "$SERVER_AUTH" == "key" ]]
    [[ "$SERVER_PASS" == "" ]]
}

@test "node_load: second node (password auth) decrypts password" {
    node_load 2
    [[ "$NODE_NAME" == "ru-vps" ]]
    [[ "$SERVER_IP" == "5.6.7.8" ]]
    [[ "$SERVER_PORT" == "2222" ]]
    [[ "$SERVER_USER" == "admin" ]]
    [[ "$SERVER_AUTH" == "password" ]]
    [[ "$SERVER_PASS" == "testpass123" ]]
}

@test "node_load_by_name: finds existing node" {
    node_load_by_name "de-vps"
    [[ "$NODE_NAME" == "de-vps" ]]
    [[ "$SERVER_IP" == "1.2.3.4" ]]
}

@test "node_load_by_name: finds second node" {
    node_load_by_name "ru-vps"
    [[ "$NODE_NAME" == "ru-vps" ]]
    [[ "$SERVER_IP" == "5.6.7.8" ]]
    [[ "$SERVER_PASS" == "testpass123" ]]
}

@test "node_load_by_name: returns 1 for missing node" {
    run node_load_by_name "nonexistent"
    assert_failure
}

@test "nodes_count: returns correct count" {
    run nodes_count
    assert_success
    assert_output "2"
}

@test "nodes_count: returns 0 for empty config" {
    echo '{"nodes":[],"groups":[],"clients":[],"connections":[]}' > "$CONFIG_JSON"
    run nodes_count
    assert_success
    assert_output "0"
}

@test "node_load: index 0 — returns error" {
    run node_load 0
    assert_failure
}

@test "node_load: index out of range — returns error" {
    run node_load 100
    assert_failure
}
