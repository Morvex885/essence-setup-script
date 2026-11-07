#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module state.sh
    override_pass_key
    export CURRENT_VERSION=1.0.0
}
teardown() { teardown_test_env; }

@test "v1 password migration writes schema v2 and encrypted secret" {
    cat > "$CONFIG_JSON" <<'EOF'
{"nodes":[{"name":"pw","ip":"127.0.0.1","port":22,"user":"root","auth":"password","pass":"ciphertext"}],"groups":[],"clients":[],"connections":[]}
EOF
    _state_secret_decode() { [[ $1 == ciphertext ]] && printf 'secret'; }
    run state_open_local
    assert_success
    run jq -r '.schema_version' "$CONFIG_JSON"; assert_output 2
    run jq -r '.nodes[0].pass // "absent"' "$CONFIG_JSON"; assert_output absent
    [[ -s "$SECRETS_JSON" && -s "$STATE_MANIFEST" ]]
}

@test "migration failure leaves v1 config untouched" {
    local before
    printf '{"nodes":[{"name":"pw","ip":"127.0.0.1","port":22,"user":"root","auth":"password","pass":"bad"}],"groups":[],"clients":[],"connections":[]}\n' > "$CONFIG_JSON"
    before=$(cat "$CONFIG_JSON")
    _state_secret_decode() { return 1; }
    run state_migrate_v1_to_v2
    assert_failure
    [[ $(cat "$CONFIG_JSON") == "$before" ]]
}

@test "migration is repeatable after first successful conversion" {
    printf '{"nodes":[],"groups":[],"clients":[],"connections":[]}\n' > "$CONFIG_JSON"
    _state_secret_decode() { printf secret; }
    state_open_local
    local first second
    first=$(cat "$CONFIG_JSON"); second=$(cat "$SECRETS_JSON")
    state_migrate_v1_to_v2
    [[ $(cat "$CONFIG_JSON") == "$first" && $(cat "$SECRETS_JSON") == "$second" ]]
}

@test "portable validation distinguishes ready and needs_setup" {
    printf 'mode: rule\n' > "$TEMPLATES_DIR/default.yaml"
    local id=0123456789abcdef0123456789abcdef
    jq --arg id "$id" '.nodes=[{id:$id,name:"n",ip:"127.0.0.1",port:22,user:"root",auth:"password",identity:null,secret_id:("node:"+$id+":ssh-password"),aliases:{}}]' "$CONFIG_JSON" > "$CONFIG_JSON.tmp" && mv "$CONFIG_JSON.tmp" "$CONFIG_JSON"
    printf '{"schema_version":1,"node_passwords":{}}\n' > "$SECRETS_JSON"
    jq -n --arg id "$id" '{schema_version:2,portability:{status:"needs_setup",issues:[{node_id:$id,reason:"missing_secret"},{node_id:$id,reason:"missing_host_key"}]}}' > "$STATE_MANIFEST"
    run state_validate true; assert_output --partial needs_setup
}

@test "newer minimum version blocks validation" {
    state_open_local
    jq '.minimum_remote_control_version="99.0.0"' "$STATE_MANIFEST" > "$STATE_MANIFEST.tmp" && mv "$STATE_MANIFEST.tmp" "$STATE_MANIFEST"
    run state_validate false
    assert_failure
    assert_output --partial 'требуется Remote Control'
}

@test "missing password data does not expose the deferred SSH action" {
    state_open_local
    printf 'mode: rule\n' > "$TEMPLATES_DIR/default.yaml"
    local id=0123456789abcdef0123456789abcdef
    jq --arg id "$id" '.nodes=[{
      id:$id,name:"password-node",ip:"127.0.0.1",port:22,user:"root",
      auth:"password",identity:null,secret_id:("node:"+$id+":ssh-password"),
      aliases:{}
    }]' "$CONFIG_JSON" > "$CONFIG_JSON.tmp" && mv "$CONFIG_JSON.tmp" "$CONFIG_JSON"
    printf '{"schema_version":1,"node_passwords":{}}\n' > "$SECRETS_JSON"
    local host_key="$BATS_TEST_TMPDIR/host-key" key_type key_data _
    ssh-keygen -t ed25519 -N '' -q -f "$host_key"
    read -r key_type key_data _ < "$host_key.pub"
    printf '127.0.0.1 %s %s\n' "$key_type" "$key_data" > "$SSH_KNOWN_HOSTS"
    jq -n --arg id "$id" \
        '{schema_version:2,minimum_remote_control_version:"0.0.0",portability:{status:"needs_setup",issues:[{node_id:$id,reason:"missing_secret"}]},access:{script_password_hash:null},templates:{}}' \
        > "$STATE_MANIFEST"

    [[ "$(state_validate true)" == needs_setup ]]
    run state_actionable_ssh_setup_pending
    assert_failure
}

@test "state checkpoint persists and removes the script password hash" {
    state_open_local
    printf '%s\n' '$6$salt$hash' > "$SCRIPT_AUTH_FILE"
    chmod 600 "$SCRIPT_AUTH_FILE"
    state_checkpoint
    run jq -r '.access.script_password_hash' "$STATE_MANIFEST"
    assert_output '$6$salt$hash'

    rm -f "$SCRIPT_AUTH_FILE"
    state_checkpoint
    run jq -r '.access.script_password_hash' "$STATE_MANIFEST"
    assert_output 'null'
}
