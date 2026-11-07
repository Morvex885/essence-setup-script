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

@test "custom node editor preserves the client's current selections" {
    cat > "$CONFIG_JSON" <<'EOF'
{"schema_version":2,"nodes":[
  {"id":"00000000000000000000000000000001","name":"node-a","ip":"127.0.0.1","port":22,"user":"root","auth":"key","identity":"system","secret_id":null,"aliases":{}},
  {"id":"00000000000000000000000000000002","name":"node-b","ip":"127.0.0.2","port":22,"user":"root","auth":"key","identity":"system","secret_id":null,"aliases":{}}
],"groups":[{"name":"PC","template":"default.yaml"}],"clients":[{"name":"client","group":"PC","inherit_nodes_from_group":false,"nodes":["node-a"],"connections":[]}],"connections":[]}
EOF
    nodes_count() { jq_r '.nodes | length'; }
    toggle_select() {
        CAPTURED_FLAGS="${TOGGLE_SELECT_FLAGS[*]}"
    }

    _set_custom_nodes "client" "PC"
    [[ "$CAPTURED_FLAGS" == "1 0" ]]
    run jq -c '.clients[0].nodes' "$CONFIG_JSON"
    assert_output '["node-a"]'
}
