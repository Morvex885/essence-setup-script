#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module state.sh
    source_module nodes.sh
    source_module ssh.sh
    source_module hardening.sh
    export NODE_NAME=node NODE_ID=node-id SERVER_IP=127.0.0.1 SERVER_PORT=22 SERVER_USER=root SSH_KNOWN_HOSTS="$CONFIG_DIR/known_hosts" SSH_IDENTITIES_DIR="$CONFIG_DIR/identities"
    mkdir -p "$SSH_IDENTITIES_DIR"
}
teardown() { teardown_test_env; }

@test "local system auth keeps accept-new and does not require managed identity" {
    export CONFIG_SOURCE=local SERVER_AUTH=key NODE_IDENTITY=system
    _ssh_base_options
    [[ " ${SSH_BASE_OPTIONS[*]} " == *"StrictHostKeyChecking=accept-new"* ]]
    [[ " ${SSH_BASE_OPTIONS[*]} " != *"IdentitiesOnly=yes"* ]]
}

@test "GitHub password auth requires managed known host and strict checking" {
    export CONFIG_SOURCE=github SERVER_AUTH=password SERVER_PASS=secret
    _ssh_known_host_present() { return 0; }
    _ssh_base_options
    [[ " ${SSH_BASE_OPTIONS[*]} " == *"StrictHostKeyChecking=yes"* ]]
    [[ " ${SSH_BASE_OPTIONS[*]} " == *"UserKnownHostsFile=$SSH_KNOWN_HOSTS"* ]]
    [[ " ${SSH_BASE_OPTIONS[*]} " != *"-i"* ]]
}

@test "GitHub key auth requires explicit managed identity" {
    export CONFIG_SOURCE=github SERVER_AUTH=key SERVER_PASS= NODE_IDENTITY=node-id
    _ssh_known_host_present() { return 0; }
    : > "$SSH_IDENTITIES_DIR/node-id"
    _ssh_base_options
    [[ " ${SSH_BASE_OPTIONS[*]} " == *"IdentitiesOnly=yes"* ]]
    [[ " ${SSH_BASE_OPTIONS[*]} " == *"$SSH_IDENTITIES_DIR/node-id"* ]]
}

@test "GitHub onboarding uses a valid accept-new option sequence" {
    export CONFIG_SOURCE=github SERVER_AUTH=password SERVER_PASS=secret
    export SSH_ALLOW_PORTABLE_ONBOARDING=1
    _ssh_base_options
    [[ "${SSH_BASE_OPTIONS[0]}" == "-o" ]]
    [[ "${SSH_BASE_OPTIONS[1]}" == "StrictHostKeyChecking=accept-new" ]]
    [[ "${SSH_BASE_OPTIONS[2]}" == "-o" ]]
    [[ " ${SSH_BASE_OPTIONS[*]} " != *" -o -o "* ]]
}

@test "portability issue blocks GitHub SSH before binary" {
    export CONFIG_SOURCE=github SERVER_AUTH=password SERVER_PASS=secret
    printf '{"portability":{"status":"needs_setup","issues":[{"node_id":"node-id","reason":"missing_host_key"}]}}\n' > "$CONFIG_DIR/manifest.json"
    export STATE_MANIFEST="$CONFIG_DIR/manifest.json"
    run _ssh_base_options
    assert_failure
    assert_output --partial 'отложена SSH-настройка для синхронизации через GitHub'
    assert_output --partial 'H) Завершить отложенную SSH-настройку нод'
    [[ "$output" != *"Y →"* ]]
}

_run_failed_add_node() {
    state_open_local
    CONFIG_SOURCE=github
    ssh_run() {
        printf '%s\n' 'Permission denied' >&2
        return 1
    }
    add_node <<< $'failed-node\n127.0.0.1\ninvalid\n22\nroot\nx\n2\nsecret\n3'
}

@test "failed SSH onboarding shows vertical Russian choices and cancels safely" {
    run _run_failed_add_node
    assert_failure
    [[ "$output" == *$'\033[0;32m1)\033[0m Повторить подключение'* ]]
    [[ "$output" == *$'\033[1;33m2)\033[0m Продолжить — настроить ноды позже'* ]]
    [[ "$output" == *$'\033[0;31m3)\033[0m Отменить и откатить изменения'* ]]
    assert_output --partial "Порт SSH должен быть числом от 1 до 65535."
    assert_output --partial "Выберите 1 или 2."
    [[ "$output" != *"requires_setup"* ]]
    run jq -r '.nodes | length' "$CONFIG_JSON"
    assert_output 0
}

_run_validated_password_add_node() {
    state_open_local
    CONFIG_SOURCE=local
    ssh_run() {
        printf '%s\n' ok
        return 0
    }
    add_node <<< $'validated-node\n127.0.0.1\n70000\n2222\nroot\ninvalid\n2\nsecret-password\ny\nDE'
}

@test "add node reprompts invalid port and auth before persisting password auth" {
    _run_validated_password_add_node
    [[ "$(jq -r '.nodes[0].port' "$CONFIG_JSON")" == 2222 ]]
    [[ "$(jq -r '.nodes[0].auth' "$CONFIG_JSON")" == password ]]
    local node_id
    node_id=$(jq -r '.nodes[0].id' "$CONFIG_JSON")
    [[ "$(node_secret_get "$node_id")" == "secret-password" ]]
}

_prepare_pending_key_node() {
    local node_id=0123456789abcdef0123456789abcdef
    cat > "$CONFIG_JSON" <<EOF
{"schema_version":2,"nodes":[{"id":"$node_id","name":"pending-node","ip":"127.0.0.1","port":22,"user":"root","auth":"key","identity":"system","secret_id":null,"aliases":{}}],"groups":[],"clients":[],"connections":[]}
EOF
    printf '{"schema_version":1,"node_passwords":{}}\n' > "$SECRETS_JSON"
    jq -n --arg id "$node_id" \
        '{schema_version:2,minimum_remote_control_version:"0.0.0",portability:{status:"needs_setup",issues:[{node_id:$id,reason:"missing_identity"},{node_id:$id,reason:"missing_host_key"}]},access:{script_password_hash:null},templates:{}}' \
        > "$STATE_MANIFEST"
    CONFIG_SOURCE=github
}

@test "deferred key onboarding can complete all issues and reach ready" {
    _prepare_pending_key_node
    _provision_portable_identity() {
        mkdir -p "$SSH_IDENTITIES_DIR"
        ssh-keygen -t ed25519 -N '' -q -f "$SSH_IDENTITIES_DIR/$1"
        NODE_IDENTITY="$1"
    }
    _ssh_pin_host_key() {
        local key_type key_data _
        read -r key_type key_data _ < "$SSH_IDENTITIES_DIR/$NODE_ID.pub"
        printf '%s %s %s\n' "$SERVER_IP" "$key_type" "$key_data" > "$SSH_KNOWN_HOSTS"
    }

    state_actionable_ssh_setup_pending
    complete_portable_node_setup <<< $'y'
    [[ "$(jq -r '.nodes[0].identity' "$CONFIG_JSON")" == \
       "0123456789abcdef0123456789abcdef" ]]
    [[ "$(state_validate true)" == ready ]]
    ! state_actionable_ssh_setup_pending
}

@test "cancel after provisioning revokes and removes the deferred identity" {
    _prepare_pending_key_node
    local node_id=0123456789abcdef0123456789abcdef
    REVOKED_ID=""
    _provision_portable_identity() {
        mkdir -p "$SSH_IDENTITIES_DIR"
        printf private > "$SSH_IDENTITIES_DIR/$1"
        printf public > "$SSH_IDENTITIES_DIR/$1.pub"
        NODE_IDENTITY="$1"
    }
    _ssh_pin_host_key() { return 1; }
    _revoke_managed_remote_key() {
        REVOKED_ID="$1"
        return 0
    }

    if _github_initial_portable_onboarding <<< $'y\n3'; then
        return 1
    fi
    [[ "$REVOKED_ID" == "$node_id" ]]
    [[ ! -e "$SSH_IDENTITIES_DIR/$node_id" ]]
    [[ ! -e "$SSH_IDENTITIES_DIR/$node_id.pub" ]]
    [[ "$(jq -r '.nodes | length' "$CONFIG_JSON")" == 1 ]]
    [[ "$(jq -r '.nodes[0].identity' "$CONFIG_JSON")" == system ]]
}
