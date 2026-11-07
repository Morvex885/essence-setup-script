#!/usr/bin/env bats
# Tests for node_load() / node_load_by_name()

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "nodes.sh"
    override_pass_key
    load_fixture_config

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

_node_context() {
    declare -p NODE_ID NODE_NAME NODE_IDENTITY NODE_TAG SERVER_IP SERVER_PORT \
        SERVER_USER SERVER_AUTH SERVER_PASS CURRENT_NODE_INDEX
}

@test "node_load: missing and unreadable passwords preserve the previous context" {
    node_load 1
    local before rc id
    before=$(_node_context)
    id=$(jq_r '.nodes[1].id')
    node_secret_delete "$id"
    rc=0
    node_load 2 || rc=$?
    [[ "$rc" == 2 ]]
    [[ "$(_node_context)" == "$before" ]]
    jq --arg key "node:$id:ssh-password" '.node_passwords[$key]="broken"' \
        "$SECRETS_JSON" > "$BATS_TEST_TMPDIR/secrets"
    cp "$BATS_TEST_TMPDIR/secrets" "$SECRETS_JSON"
    rc=0
    node_load_by_name ru-vps || rc=$?
    [[ "$rc" == 2 ]]
    [[ "$(_node_context)" == "$before" ]]
}

@test "node_load: wrong machine key preserves context and returns two" {
    node_load 1
    local before rc=0
    before=$(_node_context)
    _pass_key() { printf '%s' different-machine-key; }
    node_load 2 || rc=$?
    [[ "$rc" == 2 ]]
    [[ "$(_node_context)" == "$before" ]]
}

@test "node_load: invalid index name and container are global errors without context changes" {
    node_load 1
    local before index rc
    before=$(_node_context)
    for index in 0 100 01 -1 '1+1' ''; do
        rc=0
        node_load "$index" || rc=$?
        [[ "$rc" == 1 ]]
        [[ "$(_node_context)" == "$before" ]]
    done
    rc=0
    node_load_by_name absent || rc=$?
    [[ "$rc" == 1 ]]
    [[ "$(_node_context)" == "$before" ]]
    printf '{broken' > "$SECRETS_JSON"
    rc=0
    node_load 2 || rc=$?
    [[ "$rc" == 1 ]]
    [[ "$(_node_context)" == "$before" ]]
}

@test "node_load: preserves password trailing newlines" {
    local password=$' synthetic "password"\\\r\n\n' id
    id=$(jq_r '.nodes[1].id')
    node_secret_set "$id" "$password"
    node_load 2
    [[ "$SERVER_PASS" == "$password" ]]
}

@test "node_save_password: repairs only the selected secret issue without SSH" {
    local id before
    id=$(jq_r '.nodes[1].id')
    before=$(cat "$CONFIG_JSON")
    state_portability_add_issue "$id" missing_secret
    state_portability_add_issue "$id" missing_host_key
    ssh_run() { touch "$BATS_TEST_TMPDIR/ssh-calls.log"; return 1; }
    node_save_password "$id" "synthetic-replacement"
    node_load 2
    [[ "$SERVER_PASS" == synthetic-replacement ]]
    [[ "$(cat "$CONFIG_JSON")" == "$before" ]]
    jq -e --arg id "$id" '
        any(.portability.issues[]; .node_id==$id and .reason=="missing_host_key") and
        all(.portability.issues[]; .node_id!=$id or .reason!="missing_secret")
    ' "$STATE_MANIFEST"
    [[ ! -e "$BATS_TEST_TMPDIR/ssh-calls.log" ]]
}

@test "node_save_password: failed manifest mutation restores both files" {
    local id
    id=$(jq_r '.nodes[1].id')
    state_portability_add_issue "$id" missing_secret
    cp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    cp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    state_portability_remove_issue() { printf broken > "$STATE_MANIFEST"; return 1; }
    run node_save_password "$id" synthetic-replacement
    assert_failure
    cmp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    cmp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
}

@test "node_prompt_password: cancellation EOF and empty input do not mutate" {
    cp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    state_action() { touch "$BATS_TEST_TMPDIR/mutation"; return 0; }
    run node_prompt_password 2 <<< "n"
    assert_failure
    run node_prompt_password 2 < /dev/null
    assert_failure
    run node_prompt_password 2 <<< $'y\n'
    assert_failure
    run node_prompt_password 2 <<< "y"
    assert_failure
    cmp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    [[ ! -e "$BATS_TEST_TMPDIR/mutation" ]]
}

@test "node_prompt_password: saves via state action without connecting" {
    ssh_run() { touch "$BATS_TEST_TMPDIR/ssh-calls.log"; return 1; }
    ssh_connect() { touch "$BATS_TEST_TMPDIR/ssh-calls.log"; return 1; }
    upload_scripts() { touch "$BATS_TEST_TMPDIR/ssh-calls.log"; return 1; }
    run node_prompt_password 2 <<< $'y\nsynthetic-replacement'
    assert_success
    [[ "$output" != *synthetic-replacement* ]]
    node_load 2
    [[ "$SERVER_PASS" == synthetic-replacement ]]
    [[ ! -e "$BATS_TEST_TMPDIR/ssh-calls.log" ]]
}

@test "node_save_password: failed secret write restores original files and absent manifest" {
    local id
    id=$(jq_r '.nodes[1].id')
    rm -f "$STATE_MANIFEST"
    cp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    node_secret_set() { printf broken > "$SECRETS_JSON"; return 1; }
    run node_save_password "$id" synthetic-replacement
    assert_failure
    cmp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    [[ ! -e "$STATE_MANIFEST" ]]
}

@test "portable onboarding: unavailable password records host pin readiness without SSH" {
    source_module "hardening.sh"
    CONFIG_SOURCE=github
    local id
    id=$(jq_r '.nodes[1].id')
    node_secret_delete "$id"
    confirm_yn() { return 1; }
    _ssh_known_host_present() { [[ "$SERVER_IP" == 1.2.3.4 ]]; }
    _ssh_pin_host_key() { touch "$BATS_TEST_TMPDIR/ssh-calls.log"; return 1; }
    ssh_run() { touch "$BATS_TEST_TMPDIR/ssh-calls.log"; return 1; }
    _github_initial_portable_onboarding
    jq -e --arg id "$id" '
        any(.portability.issues[]; .node_id==$id and .reason=="missing_secret") and
        any(.portability.issues[]; .node_id==$id and .reason=="missing_host_key")
    ' "$STATE_MANIFEST"
    [[ ! -e "$BATS_TEST_TMPDIR/ssh-calls.log" ]]
    _ssh_known_host_present() { return 0; }
    _github_initial_portable_onboarding
    jq -e --arg id "$id" '
        any(.portability.issues[]; .node_id==$id and .reason=="missing_secret") and
        all(.portability.issues[]; .node_id!=$id or .reason!="missing_host_key")
    ' "$STATE_MANIFEST"
    [[ ! -e "$BATS_TEST_TMPDIR/ssh-calls.log" ]]
}
