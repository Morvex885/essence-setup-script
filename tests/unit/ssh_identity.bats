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
}
@test "interactive SSH is not killed by operation timeout" {
    local fake_ssh="$BATS_TEST_TMPDIR/ssh" marker="$BATS_TEST_TMPDIR/ssh-complete"
    cat > "$fake_ssh" <<'EOF'
#!/bin/bash
sleep 2
printf '%s\n' complete > "$SSH_FAKE_MARKER"
EOF
    chmod 755 "$fake_ssh"
    export SSH_FAKE_MARKER="$marker" PATH="$BATS_TEST_TMPDIR:$PATH"

    export CONFIG_SOURCE=local SERVER_AUTH=key SERVER_PASS= SSH_RUN_TIMEOUT=1
    run ssh_run -t -- true
    assert_success
    [[ "$(cat "$marker")" == complete ]]
    [[ -z "${SERVER_PASS:-}" ]]
    [[ ! -e "${_ASKPASS_FILE:-}" && ! -e "${_PASS_FILE:-}" ]]

    rm -f "$marker"
    export SERVER_AUTH=password SERVER_PASS='password-secret'
    run ssh_run -- true
    [[ "$status" -eq 124 || "$status" -eq 143 ]]
    [[ ! -e "$marker" ]]
    [[ "$output" != *password-secret* ]]
    [[ ! -e "${_ASKPASS_FILE:-}" && ! -e "${_PASS_FILE:-}" ]]
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

@test "failed SSH onboarding cancels without persisting the node" {
    run _run_failed_add_node
    assert_failure
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

# Execute remote provisioning commands only against a sandbox HOME. Keep the
# real ssh_run, key generation, installation, persistence and revocation paths.
_prepare_identity_transport() {
    state_open_local
    export CONFIG_SOURCE=local NODE_ID=0123456789abcdef0123456789abcdef
    export NODE_IDENTITY=system SERVER_AUTH=key SERVER_PASS=
    jq_w --arg id "$NODE_ID" \
        '.nodes=[{id:$id,name:"node",ip:"127.0.0.1",port:22,user:"root",auth:"key",identity:"system",secret_id:null,aliases:{}}]'
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/remote/.ssh"
    export SSH_SANDBOX_HOME="$BATS_TEST_TMPDIR/remote"
    printf '%s\n' unrelated-existing-key > "$SSH_SANDBOX_HOME/.ssh/authorized_keys"
    cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'EOF'
#!/bin/bash
export HOME="$SSH_SANDBOX_HOME"
exec /bin/bash -c "${!#}"
EOF
    chmod 755 "$BATS_TEST_TMPDIR/bin/ssh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
}

_prepare_host_pin_transport() {
    _prepare_pending_key_node
    export NODE_ID=0123456789abcdef0123456789abcdef
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/pin-tmp"
    ssh-keygen -t ed25519 -N '' -q -f "$BATS_TEST_TMPDIR/host-key"
    local key_type key_data rest
    read -r key_type key_data rest < "$BATS_TEST_TMPDIR/host-key.pub"
    printf '%s %s %s\n' "$SERVER_IP" "$key_type" "$key_data" > "$BATS_TEST_TMPDIR/host-scan"
    export SSH_SCAN_FIXTURE="$BATS_TEST_TMPDIR/host-scan"
    cat > "$BATS_TEST_TMPDIR/bin/ssh-keyscan" <<'EOF'
#!/bin/bash
exec cat "$SSH_SCAN_FIXTURE"
EOF
    chmod 755 "$BATS_TEST_TMPDIR/bin/ssh-keyscan"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH" TMPDIR="$BATS_TEST_TMPDIR/pin-tmp"
    cp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
}

_assert_host_pin_failed_safely() {
    cmp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    jq -e --arg id "$NODE_ID" \
        'any(.portability.issues[]; .node_id==$id and .reason=="missing_host_key")' \
        "$STATE_MANIFEST"
    ! compgen -G "$TMPDIR/*"
}

@test "failed known_hosts append removes keyscan temporary file and stops checkpoint" {
    _prepare_host_pin_transport
    printf '%s\n' existing-host > "$SSH_KNOWN_HOSTS"
    cp "$SSH_KNOWN_HOSTS" "$BATS_TEST_TMPDIR/known.before"
    mktemp() {
        if [[ "$#" -eq 0 ]]; then
            command mktemp "$TMPDIR/scan.XXXXXX"
        else
            command mktemp "$@"
        fi
    }
    cat() {
        case "${1:-}" in
            "$TMPDIR"/*) printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/failed-append"; return 77 ;;
        esac
        command cat "$@"
    }
    state_checkpoint() { touch "$BATS_TEST_TMPDIR/checkpoint-called"; }

    run _ssh_pin_host_key
    assert_failure
    [[ -s "$BATS_TEST_TMPDIR/failed-append" ]]
    [[ ! -e "$(command cat "$BATS_TEST_TMPDIR/failed-append")" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/checkpoint-called" ]]
    cmp "$SSH_KNOWN_HOSTS" "$BATS_TEST_TMPDIR/known.before"
    _assert_host_pin_failed_safely
}

@test "failed known_hosts permissions stop checkpoint and preserve pending host setup" {
    _prepare_host_pin_transport
    chmod() {
        if [[ "$1" == 600 && "$2" == "$SSH_KNOWN_HOSTS" ]]; then
            touch "$BATS_TEST_TMPDIR/failed-host-chmod"
            return 77
        fi
        command chmod "$@"
    }
    state_checkpoint() { touch "$BATS_TEST_TMPDIR/checkpoint-called"; }

    run _ssh_pin_host_key
    assert_failure
    [[ -e "$BATS_TEST_TMPDIR/failed-host-chmod" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/checkpoint-called" ]]
    cmp "$SSH_KNOWN_HOSTS" "$SSH_SCAN_FIXTURE"
    _assert_host_pin_failed_safely
}

@test "failed host checkpoint leaves written key but does not clear missing_host_key" {
    _prepare_host_pin_transport
    state_checkpoint() { touch "$BATS_TEST_TMPDIR/checkpoint-called"; return 77; }

    run _ssh_pin_host_key
    assert_failure
    [[ -e "$BATS_TEST_TMPDIR/checkpoint-called" ]]
    cmp "$SSH_KNOWN_HOSTS" "$SSH_SCAN_FIXTURE"
    _assert_host_pin_failed_safely
}

_assert_identity_permission_failure() {
    _prepare_identity_transport
    local failed_mode="$1" failed_path="$SSH_IDENTITIES_DIR/$NODE_ID"
    [[ "$failed_mode" == 644 ]] && failed_path="$failed_path.pub"
    chmod() {
        if [[ "$1" == "$failed_mode" && "$2" == "$failed_path" ]]; then
            command grep -qxF "$(command cat "$SSH_IDENTITIES_DIR/$NODE_ID.pub")" \
                "$SSH_SANDBOX_HOME/.ssh/authorized_keys" || return 78
            touch "$BATS_TEST_TMPDIR/failed-key-chmod"
            return 77
        fi
        command chmod "$@"
    }
    jq_w() { touch "$BATS_TEST_TMPDIR/config-write-called"; return 77; }
    state_checkpoint() { touch "$BATS_TEST_TMPDIR/checkpoint-called"; return 77; }

    run _provision_portable_identity "$NODE_ID"
    assert_failure
    [[ -e "$BATS_TEST_TMPDIR/failed-key-chmod" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/config-write-called" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/checkpoint-called" ]]
    [[ ! -e "$SSH_IDENTITIES_DIR/$NODE_ID" && ! -e "$SSH_IDENTITIES_DIR/$NODE_ID.pub" ]]
    ! compgen -G "$CONFIG_DIR/.identity.*"
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    [[ "$(cat "$SSH_SANDBOX_HOME/.ssh/authorized_keys")" == unrelated-existing-key ]]
}

@test "private key chmod failure revokes only new key and removes installation before publication" {
    _assert_identity_permission_failure 600
}

@test "public key chmod failure revokes only new key and removes installation before publication" {
    _assert_identity_permission_failure 644
}

@test "late identity checkpoint failure keeps published identity and stops downstream hardening" {
    _prepare_identity_transport
    state_checkpoint() { touch "$BATS_TEST_TMPDIR/checkpoint-called"; return 77; }
    _harden_select_port() { HARDEN_NEW_PORT=2222; }
    confirm_yn() { return 0; }
    _harden_disable_password() { touch "$BATS_TEST_TMPDIR/password-disabled"; }
    _harden_change_port() { touch "$BATS_TEST_TMPDIR/port-changed"; }
    _harden_restore_password() { touch "$BATS_TEST_TMPDIR/password-restored"; }

    run ssh_hardening
    assert_failure
    [[ -e "$BATS_TEST_TMPDIR/checkpoint-called" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/password-disabled" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/port-changed" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/password-restored" ]]
    [[ "$(jq -r '.nodes[0].identity' "$CONFIG_JSON")" == "$NODE_ID" ]]
    ssh-keygen -y -f "$SSH_IDENTITIES_DIR/$NODE_ID" > "$BATS_TEST_TMPDIR/derived.pub"
    [[ "$(cut -d ' ' -f 1-2 "$SSH_IDENTITIES_DIR/$NODE_ID.pub")" == \
       "$(cut -d ' ' -f 1-2 "$BATS_TEST_TMPDIR/derived.pub")" ]]
    command grep -qxF "$(cat "$SSH_IDENTITIES_DIR/$NODE_ID.pub")" \
        "$SSH_SANDBOX_HOME/.ssh/authorized_keys"
    ! compgen -G "$CONFIG_DIR/.identity.*"
}

@test "deferred identity provisioning installs keys without individual config or checkpoint writes" {
    _prepare_identity_transport
    cp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    export PORTABLE_IDENTITY_DEFER_CONFIG=1
    jq_w() { touch "$BATS_TEST_TMPDIR/config-write-called"; return 77; }
    state_checkpoint() { touch "$BATS_TEST_TMPDIR/checkpoint-called"; return 77; }

    _provision_portable_identity "$NODE_ID"
    [[ "$NODE_IDENTITY" == "$NODE_ID" ]]
    [[ -f "$SSH_IDENTITIES_DIR/$NODE_ID" && -f "$SSH_IDENTITIES_DIR/$NODE_ID.pub" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/config-write-called" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/checkpoint-called" ]]
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    cmp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    command grep -qxF "$(cat "$SSH_IDENTITIES_DIR/$NODE_ID.pub")" \
        "$SSH_SANDBOX_HOME/.ssh/authorized_keys"
    ! compgen -G "$CONFIG_DIR/.identity.*"
}
