#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module state.sh
    source_module nodes.sh
    source_module ssh.sh
    source_module hardening.sh
    source "$PROJECT_ROOT/remote-control/modules/cli.sh"
    source "$PROJECT_ROOT/remote-control/modules/cmd_nodes.sh"
    load '../helpers/cmd_helper'
    RC_SESSION_OPEN=1 RC_SESSION_AUTHORIZED=1
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

@test "local key auth with managed identity passes the key in base SSH options" {
    export CONFIG_SOURCE=local SERVER_AUTH=key SERVER_PASS= NODE_IDENTITY=node-id
    : > "$SSH_IDENTITIES_DIR/node-id"
    _ssh_base_options
    [[ " ${SSH_BASE_OPTIONS[*]} " == *" -i $SSH_IDENTITIES_DIR/node-id "* ]]
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
if [[ -n "${SSH_ASKPASS:-}" ]]; then
    "$SSH_ASKPASS" > "$SSH_FAKE_ASKPASS_MARKER"
fi
sleep 2
printf '%s\n' complete > "$SSH_FAKE_MARKER"
EOF
    chmod 755 "$fake_ssh"
    export SSH_FAKE_MARKER="$marker" PATH="$BATS_TEST_TMPDIR:$PATH"
    export SSH_FAKE_ASKPASS_MARKER="$BATS_TEST_TMPDIR/askpass-used"
    # A desktop session may export SSH_ASKPASS; only ssh_run may provide one here.
    unset SSH_ASKPASS SSH_ASKPASS_REQUIRE

    export CONFIG_SOURCE=local SERVER_AUTH=key SERVER_PASS= SSH_RUN_TIMEOUT=1
    run ssh_run -t -- true
    assert_success
    [[ "$(cat "$marker")" == complete ]]
    [[ ! -e "$SSH_FAKE_ASKPASS_MARKER" ]]

    rm -f "$marker"
    export SERVER_AUTH=password SERVER_PASS='password-secret'
    # Askpass files must be gone when ssh_run returns, before the EXIT cleanup.
    _check_password_ssh_cleanup() {
        export TMPDIR="$BATS_TEST_TMPDIR/askpass-tmp"
        mkdir -p "$TMPDIR" || return 1
        local rc=0
        ssh_run -- true || rc=$?
        [[ "$rc" -eq 124 || "$rc" -eq 143 ]] || return 1
        [[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]]
    }
    run _check_password_ssh_cleanup
    assert_success
    [[ ! -e "$marker" ]]
    [[ "$output" != *password-secret* ]]
    [[ "$(cat "$SSH_FAKE_ASKPASS_MARKER")" == password-secret ]]
}

_run_failed_add_node() {
    state_open_local
    CONFIG_SOURCE=github
    ssh_run() {
        printf '%s\n' 'Permission denied' >&2
        return 1
    }
    RC_REQUEST_SECRETS='{"password":"secret"}'
    run_cmd node add --name failed-node --ip 127.0.0.1 --port 22 --user root --auth password \
        --tag DE --accept-new-host-key
    [ "$(cmd_jq '.error.code')" = remote_failed ] || return 0
    [ "$status" -eq 0 ]
}

@test "failed SSH onboarding cancels without persisting the node" {
    run _run_failed_add_node
    assert_failure
    run jq -r '.nodes | length' "$CONFIG_JSON"
    assert_output 0
}

@test "GitHub add with deferred SSH setup records issues before the validated node write" {
    state_open_local
    CONFIG_SOURCE=github
    mkdir -p "$TEMPLATES_DIR" && : > "$TEMPLATES_DIR/default.yaml"
    # Mirrors the GitHub jq_w hook: the candidate must pass portable validation.
    config_persist_candidate() {
        local original="$CONFIG_JSON" rc=0
        CONFIG_JSON="$1"
        state_validate true >/dev/null 2>&1 || rc=1
        CONFIG_JSON="$original"
        [[ $rc -eq 0 ]] && mv "$1" "$CONFIG_JSON"
    }
    _provision_portable_identity() { return 1; }
    ssh_run() { printf '%s\n' ok; }
    _ssh_pin_host_key() { return 1; }

    run_cmd node add --name deferred-node --ip 127.0.0.1 --port 22 --user root --auth key \
        --tag DE --accept-new-host-key --defer-ssh-setup
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.needs_setup')" = true ]
    local node_id
    node_id=$(jq -r '.nodes[0].id' "$CONFIG_JSON")
    [[ "$(jq -r '.nodes[0].identity' "$CONFIG_JSON")" == system ]]
    jq -e --arg id "$node_id" '
        any(.portability.issues[]; .node_id==$id and .reason=="missing_identity") and
        any(.portability.issues[]; .node_id==$id and .reason=="missing_host_key")
    ' "$STATE_MANIFEST"
    [[ "$(state_validate true)" == needs_setup ]]
    ! compgen -G "$CONFIG_DIR/.manifest.*" || return 1
    ! compgen -G "$CONFIG_DIR/.known-hosts.*"
}

_run_validated_password_add_node() {
    state_open_local
    CONFIG_SOURCE=local
    ssh_run() {
        printf '%s\n' ok
        return 0
    }
    RC_REQUEST_SECRETS='{"password":"secret-password"}'
    run_cmd node add --name validated-node --ip 127.0.0.1 --port 70000 --user root --auth password --tag DE
    [ "$(cmd_jq '.error.code')" = invalid ]
    [ "$(jq -r '.nodes | length' "$CONFIG_JSON")" == 0 ]
    RC_REQUEST_SECRETS='{"password":"secret-password"}'
    run_cmd node add --name validated-node --ip 127.0.0.1 --port 2222 --user root --auth invalid --tag DE
    [ "$(cmd_jq '.error.code')" = usage ]
    RC_REQUEST_SECRETS='{"password":"secret-password"}'
    run_cmd node add --name validated-node --ip 127.0.0.1 --port 2222 --user root --auth password \
        --tag DE --accept-new-host-key
    [ "$status" -eq 0 ]
    [[ "$output" != *secret-password* ]]
}

@test "add node rejects invalid port and auth before persisting password auth" {
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
    # План читает ключ сервера; без сети он не прочитан, закрепление — заглушка.
    ssh-keyscan() { return 1; }

    state_actionable_ssh_setup_pending
    run_cmd node setup-ssh --provision-keys yes --yes
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.ready')" = true ]
    [ "$(cmd_jq '.data.installed | join(",")')" = pending-node ]
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

    if _github_initial_portable_onboarding yes rollback; then
        return 1
    fi
    [ "$RC_ERROR_CODE" = onboarding_failed ]
    [ "$(jq -r '.step' <<< "$RC_ERROR_EXTRA")" = pin ]
    [[ "$REVOKED_ID" == "$node_id" ]]
    [[ ! -e "$SSH_IDENTITIES_DIR/$node_id" ]]
    [[ ! -e "$SSH_IDENTITIES_DIR/$node_id.pub" ]]
    [[ "$(jq -r '.nodes | length' "$CONFIG_JSON")" == 1 ]]
    [[ "$(jq -r '.nodes[0].identity' "$CONFIG_JSON")" == system ]]
}

_prepare_onboarding_rollback() {
    _prepare_pending_key_node
    printf '%s\n' existing-host > "$SSH_KNOWN_HOSTS"
    cp "$SSH_KNOWN_HOSTS" "$BATS_TEST_TMPDIR/known.before"
    cp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    _provision_portable_identity() {
        mkdir -p "$SSH_IDENTITIES_DIR"
        printf private > "$SSH_IDENTITIES_DIR/$1"
        printf public > "$SSH_IDENTITIES_DIR/$1.pub"
        NODE_IDENTITY="$1"
    }
}

_assert_onboarding_rolled_back() {
    cmp "$SSH_KNOWN_HOSTS" "$BATS_TEST_TMPDIR/known.before"
    cmp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    [[ "$(jq -r '.nodes[0].identity' "$CONFIG_JSON")" == system ]]
    ! compgen -G "$CONFIG_DIR/.known-hosts.*" || return 1
    ! compgen -G "$CONFIG_DIR/.manifest.*"
}

@test "onboarding state write failure after provisioning revokes key and restores backups" {
    _prepare_onboarding_rollback
    local node_id=0123456789abcdef0123456789abcdef
    REVOKED_ID=""
    _ssh_pin_host_key() { printf '%s\n' pinned-host >> "$SSH_KNOWN_HOSTS"; }
    state_portability_remove_issue() { return 77; }
    _revoke_managed_remote_key() { REVOKED_ID="$1"; }

    if _github_initial_portable_onboarding yes rollback; then
        return 1
    fi
    [[ "$REVOKED_ID" == "$node_id" ]]
    [[ ! -e "$SSH_IDENTITIES_DIR/$node_id" && ! -e "$SSH_IDENTITIES_DIR/$node_id.pub" ]]
    _assert_onboarding_rolled_back
}

@test "onboarding rollback keeps public key for manual cleanup when revocation fails" {
    _prepare_onboarding_rollback
    local node_id=0123456789abcdef0123456789abcdef
    _ssh_pin_host_key() { return 1; }
    _revoke_managed_remote_key() { return 1; }

    run _github_initial_portable_onboarding yes rollback
    assert_failure
    assert_output --partial "Удалите его из authorized_keys вручную: $SSH_IDENTITIES_DIR/$node_id.pub"
    [[ ! -e "$SSH_IDENTITIES_DIR/$node_id" && -f "$SSH_IDENTITIES_DIR/$node_id.pub" ]]
    _assert_onboarding_rolled_back
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
    ! compgen -G "$CONFIG_DIR/.identity.*" || return 1
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
    _harden_disable_password() { touch "$BATS_TEST_TMPDIR/password-disabled"; }
    _harden_change_port() { touch "$BATS_TEST_TMPDIR/port-changed"; }
    _harden_restore_password() { touch "$BATS_TEST_TMPDIR/password-restored"; }

    core_node_harden node 2222 > "$BATS_TEST_TMPDIR/harden.out" 2>&1 && return 1
    [ "$RC_ERROR_CODE" = hardening_failed ]
    [ "$(jq -r '.stage' <<< "$RC_ERROR_EXTRA")" = key ]
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

# ─── security round 1: nodes ───

# Локальная конфигурация из фикстуры (первая нода — ключ, ru-vps — пароль);
# SSH без подключения: вызовы пишутся в CALL_LOG и завершаются ошибкой.
_sec_node_fixture() {
    state_open_local
    load_fixture_config
    CONFIG_SOURCE=local
    NAME=$(jq_r '.nodes[0].name')
    jq_w '.nodes[0].identity=.nodes[0].id'
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    CALL_LOG="$BATS_TEST_TMPDIR/ssh.calls"
    ssh_run() { printf '%s\n' "$*" >> "$CALL_LOG"; return 255; }
}

# ssh-keyscan отдаёт настоящий ключ ed25519 и подставленный по пути ключ
# другого типа; соединение «успешно» без SSH.
_sec_hostkeys() {
    _sec_node_fixture
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/legit" -C legit
    ssh-keygen -q -t ecdsa -N '' -f "$BATS_TEST_TMPDIR/evil" -C evil
    ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/old" -C old
    LEGIT_FP=$(ssh-keygen -lf "$BATS_TEST_TMPDIR/legit.pub" | awk '{print $2}')
    OLD_FP=$(ssh-keygen -lf "$BATS_TEST_TMPDIR/old.pub" | awk '{print $2}')
    LEGIT_PUB=$(cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/legit.pub")
    EVIL_PUB=$(cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/evil.pub")
    OLD_PUB=$(cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/old.pub")
    ssh-keyscan() {
        local host="${!#}"
        printf '%s %s\n' "$host" "$LEGIT_PUB" "$host" "$EVIL_PUB"
    }
    ssh_run() { printf 'ok\n'; }
}

@test "security: node add --host-key pins only the verified key from the scan" {
    _sec_hostkeys
    run_cmd node add --name n1 --ip 198.51.100.7 --auth key --tag t --host-key "$LEGIT_FP"
    [ "$status" -eq 0 ]
    grep -qxF "198.51.100.7 $LEGIT_PUB" "$HOME/.ssh/known_hosts"
    ! grep -qF "$EVIL_PUB" "$HOME/.ssh/known_hosts"
}

@test "security: node trust-host-key pins only the agreed key from the scan" {
    _sec_hostkeys
    jq_w '.nodes[0].ip="198.51.100.7"'
    run_cmd node trust-host-key --name "$NAME" --host-key "$LEGIT_FP" --yes
    [ "$status" -eq 0 ]
    grep -qxF "198.51.100.7 $LEGIT_PUB" "$HOME/.ssh/known_hosts"
    ! grep -qF "$EVIL_PUB" "$HOME/.ssh/known_hosts"
}

@test "security: node add --host-key refuses a host already known with another key" {
    _sec_hostkeys
    printf '198.51.100.7 %s\n' "$OLD_PUB" > "$HOME/.ssh/known_hosts"
    cp "$HOME/.ssh/known_hosts" "$BATS_TEST_TMPDIR/known.before"
    run_cmd node add --name n1 --ip 198.51.100.7 --auth key --tag t --host-key "$LEGIT_FP"
    [ "$(cmd_jq '.error.code')" = host_key_changed ]
    cmd_jq --arg f "$LEGIT_FP" '.error | .host == "198.51.100.7" and .port == 22 and
        (.fingerprints | index($f) != null)' | grep -qx true
    cmp "$BATS_TEST_TMPDIR/known.before" "$HOME/.ssh/known_hosts"
    [ "$(jq_r '[.nodes[] | select(.name=="n1")] | length')" = 0 ]
}

@test "security: node add --replace-host-key needs the plan and then pins only the new key" {
    _sec_hostkeys
    printf '198.51.100.7 %s\n' "$OLD_PUB" > "$HOME/.ssh/known_hosts"
    cp "$HOME/.ssh/known_hosts" "$BATS_TEST_TMPDIR/known.before"
    run_cmd node add --name n1 --ip 198.51.100.7 --auth key --tag t --replace-host-key "$LEGIT_FP"
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    cmd_jq --arg o "$OLD_FP" --arg n "$LEGIT_FP" '.error.plan |
        any(. == "Прежние отпечатки: " + $o) and any(. == "Новый отпечаток: " + $n)' | grep -qx true
    cmp "$BATS_TEST_TMPDIR/known.before" "$HOME/.ssh/known_hosts"
    [ "$(jq_r '[.nodes[] | select(.name=="n1")] | length')" = 0 ]
    local token
    token=$(cmd_jq '.error.plan_token')
    run_cmd node add --name n1 --ip 198.51.100.7 --auth key --tag t --replace-host-key "$LEGIT_FP" \
        --yes --plan-token "$token"
    [ "$status" -eq 0 ]
    grep -qxF "198.51.100.7 $LEGIT_PUB" "$HOME/.ssh/known_hosts"
    ! grep -qF "$OLD_PUB" "$HOME/.ssh/known_hosts" || return 1
    ! grep -qF "$EVIL_PUB" "$HOME/.ssh/known_hosts"
}

@test "security: node add rejects a login or address that ssh would read as an option" {
    _sec_node_fixture
    run_cmd node add --name x --ip 198.51.100.9 --user '-oProxyCommand=touch /tmp/pwned #' \
        --auth key --tag t --accept-new-host-key
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd node add --name x --ip '-oProxyCommand=touch /tmp/pwned' --auth key --tag t --accept-new-host-key
    [ "$(cmd_jq '.error.code')" = invalid ]
    run_cmd node add --name x --ip '198.51.100.9 -p 2' --auth key --tag t --accept-new-host-key
    [ "$(cmd_jq '.error.code')" = invalid ]
    [[ ! -e "$CALL_LOG" ]]
    [ "$(jq_r '[.nodes[] | select(.name=="x")] | length')" = 0 ]
    node_ssh_host_valid '::1' && node_ssh_host_valid '2001:db8::1' && node_ssh_host_valid 'vps-1.example.com'
    node_ssh_user_valid root && node_ssh_user_valid '_svc.user-1'
    ! node_ssh_user_valid $'root\n-oX' || return 1
    ! node_ssh_user_valid 'a@b' || return 1
    ! node_ssh_user_valid "$(printf 'u%.0s' {1..33})" || return 1
    ! node_ssh_host_valid '-x' || return 1
}

@test "security: a stored unsafe login, address or key reference is refused before SSH" {
    _sec_node_fixture
    state_validate false >/dev/null
    local pair field value
    for pair in 'user=-oProxyCommand=touch /tmp/pwned #' 'ip=-oProxyCommand=x' \
        'identity=../home/.ssh/id_victim' 'identity=22222222222222222222222222222222'; do
        field="${pair%%=*}" value="${pair#*=}"
        jq --arg f "$field" --arg v "$value" '.nodes[0][$f]=$v' \
            "$BATS_TEST_TMPDIR/config.before" > "$CONFIG_JSON"
        run_cmd node check --name "$NAME"
        [ "$(cmd_jq '.error.code')" = invalid ]
        ! state_validate false >/dev/null 2>&1 || return 1
    done
    [[ ! -e "$CALL_LOG" ]]
}

@test "security: node delete refuses a key reference outside the node's own identity" {
    _sec_node_fixture
    mkdir -p "$SSH_IDENTITIES_DIR"
    printf 'victim\n' > "$SSH_IDENTITIES_DIR/../victim-key"
    printf 'victim\n' > "$SSH_IDENTITIES_DIR/../victim-key.pub"
    jq '.nodes[0].identity="../victim-key"' "$BATS_TEST_TMPDIR/config.before" > "$CONFIG_JSON"
    run_cmd node delete --name "$NAME" --yes
    [ "$(cmd_jq '.error.code')" = invalid ]
    [[ -e "$SSH_IDENTITIES_DIR/../victim-key" && -e "$SSH_IDENTITIES_DIR/../victim-key.pub" ]]
    [ "$(jq_r --arg n "$NAME" '[.nodes[] | select(.name==$n)] | length')" = 1 ]
}

@test "security: node password keeps ciphertext, key and password out of jq and openssl argv" {
    _sec_node_fixture
    local bin="$BATS_TEST_TMPDIR/argv-bin" id stored key
    mkdir -p "$bin"
    export ARGV_LOG="$BATS_TEST_TMPDIR/argv.log" REAL_JQ REAL_OPENSSL
    REAL_JQ=$(command -v jq) REAL_OPENSSL=$(command -v openssl)
    cat > "$bin/jq" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$ARGV_LOG"
exec "$REAL_JQ" "$@"
EOF
    sed 's/REAL_JQ/REAL_OPENSSL/' "$bin/jq" > "$bin/openssl"
    chmod +x "$bin/jq" "$bin/openssl"
    RC_REQUEST_SECRETS='{"password":"Sup3r-Secret!"}'
    PATH="$bin:$PATH" run_cmd node password --name ru-vps
    [ "$status" -eq 0 ]
    id=$(jq_r '.nodes[] | select(.name=="ru-vps") | .id')
    stored=$(jq -r --arg s "node:$id:ssh-password" '.node_passwords[$s]' "$SECRETS_JSON")
    [[ -n "$stored" && "$stored" != null ]]
    key=$(_pass_key)
    [[ -s "$ARGV_LOG" ]]
    ! grep -qF -- "$stored" "$ARGV_LOG" || return 1
    ! grep -qF -- "$key" "$ARGV_LOG" || return 1
    ! grep -qF -- 'Sup3r-Secret!' "$ARGV_LOG" || return 1
    [ "$(node_secret_get "$id")" = 'Sup3r-Secret!' ]
}

@test "security: rc_fail folds line breaks so the log line and the envelope match" {
    run rc_fail invalid $'first\r\nsecond\n\n  [✓] forged'
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == *'first second   [✓] forged'* ]]
    rc_fail invalid $'first\r\nsecond\n\n  [✓] forged' >/dev/null || true
    [ "$RC_ERROR_MESSAGE" = 'first second   [✓] forged' ]
}

@test "security: ssh_run and scp_run end options with -- before the destination" {
    export CONFIG_SOURCE=local SERVER_AUTH=key SERVER_PASS= NODE_IDENTITY=system
    export ARGV_LOG="$BATS_TEST_TMPDIR/argv"
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/src"
    cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$ARGV_LOG.${0##*/}"
EOF
    cp "$BATS_TEST_TMPDIR/bin/ssh" "$BATS_TEST_TMPDIR/bin/scp"
    chmod +x "$BATS_TEST_TMPDIR/bin/ssh" "$BATS_TEST_TMPDIR/bin/scp"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    ssh_run -n -- "echo ok"
    [ "$(tail -n 3 "$ARGV_LOG.ssh" | paste -sd'|' -)" = '--|root@127.0.0.1|echo ok' ]
    [ "$(grep -cx -- -- "$ARGV_LOG.ssh")" -eq 1 ]
    scp_run -r "$BATS_TEST_TMPDIR/src" "root@127.0.0.1:/opt/essence/"
    [ "$(tail -n 3 "$ARGV_LOG.scp" | paste -sd'|' -)" = "--|$BATS_TEST_TMPDIR/src|root@127.0.0.1:/opt/essence/" ]
    [ "$(grep -nx -- -r "$ARGV_LOG.scp" | cut -d: -f1)" -lt "$(grep -nx -- -- "$ARGV_LOG.scp" | cut -d: -f1)" ]
}

# ssh-keyscan: план видит только настоящий ключ; при выполнении сервер
# добавляет подставленный ключ (SCAN_EXEC=extra) или отдаёт только его (evil-only).
_sec_onboarding_scan() {
    ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/legit" -C legit
    ssh-keygen -q -t ecdsa -N '' -f "$BATS_TEST_TMPDIR/evil" -C evil
    LEGIT_FP=$(ssh-keygen -lf "$BATS_TEST_TMPDIR/legit.pub" | awk '{print $2}')
    LEGIT_PUB=$(cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/legit.pub")
    EVIL_PUB=$(cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/evil.pub")
    SCAN_COUNT="$BATS_TEST_TMPDIR/scan-count" SCAN_EXEC="${SCAN_EXEC:-extra}"
    ssh-keyscan() {
        local host="${!#}" n=0
        [[ ! -f "$SCAN_COUNT" ]] || n=$(cat "$SCAN_COUNT")
        printf '%s\n' "$((n + 1))" > "$SCAN_COUNT"
        if (( n == 0 )); then
            printf '%s %s\n' "$host" "$LEGIT_PUB"
        elif [[ "$SCAN_EXEC" == evil-only ]]; then
            printf '%s %s\n' "$host" "$EVIL_PUB"
        else
            printf '%s %s\n' "$host" "$LEGIT_PUB" "$host" "$EVIL_PUB"
        fi
    }
}

@test "security: node setup-ssh shows server fingerprints in the plan and pins only them" {
    _prepare_pending_key_node
    _sec_onboarding_scan
    run_cmd node setup-ssh --provision-keys no
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    cmd_jq --arg f "$LEGIT_FP" '.error.plan |
        any(. == "Ключ сервера pending-node (127.0.0.1:22) будет закреплён: " + $f)' | grep -qx true
    [[ ! -e "$SSH_KNOWN_HOSTS" ]]
    local token
    token=$(cmd_jq '.error.plan_token')
    rm -f "$SCAN_COUNT"
    run_cmd node setup-ssh --provision-keys no --yes --plan-token "$token"
    [ "$status" -eq 0 ]
    grep -qxF "127.0.0.1 $LEGIT_PUB" "$SSH_KNOWN_HOSTS"
    ! grep -qF "$EVIL_PUB" "$SSH_KNOWN_HOSTS"
}

@test "security: node setup-ssh fails the pin step when the server key differs from the plan" {
    _prepare_pending_key_node
    SCAN_EXEC=evil-only
    _sec_onboarding_scan
    run_cmd node setup-ssh --provision-keys no
    local token
    token=$(cmd_jq '.error.plan_token')
    rm -f "$SCAN_COUNT"
    run_cmd node setup-ssh --provision-keys no --yes --plan-token "$token"
    [ "$(cmd_jq '.error.code')" = onboarding_failed ]
    [ "$(cmd_jq '.error.step')" = pin ]
    [[ ! -e "$SSH_KNOWN_HOSTS" ]]
}

@test "security: onboarding rejects a host key written during provisioning that the plan did not show" {
    _prepare_pending_key_node
    _sec_onboarding_scan
    local node_id=0123456789abcdef0123456789abcdef
    REVOKED_ID=""
    _provision_portable_identity() {
        mkdir -p "$SSH_IDENTITIES_DIR"
        printf private > "$SSH_IDENTITIES_DIR/$1"
        printf public > "$SSH_IDENTITIES_DIR/$1.pub"
        # Вход с accept-new записал ключ, который предъявил сервер.
        printf '127.0.0.1 %s\n' "$EVIL_PUB" >> "$SSH_KNOWN_HOSTS"
        NODE_IDENTITY="$1"
    }
    _revoke_managed_remote_key() { REVOKED_ID="$1"; }
    ONBOARDING_PLANNED_FPS="# plan"$'\n'"$node_id $LEGIT_FP"$'\n'

    if _github_initial_portable_onboarding yes rollback; then
        return 1
    fi
    [ "$RC_ERROR_CODE" = onboarding_failed ]
    [ "$(jq -r '.step' <<< "$RC_ERROR_EXTRA")" = pin ]
    [[ "$REVOKED_ID" == "$node_id" ]]
    [[ ! -e "$SSH_KNOWN_HOSTS" ]]
    [[ "$(jq -r '.nodes[0].identity' "$CONFIG_JSON")" == system ]]
}

# ─── round 2: nodes ──────────────────────────────────────────────────────────

# Повторное усиление: у ноды уже есть управляемый ключ (identity = id, порт
# 2222), его открытая часть — в authorized_keys песочницы. Пароль и порт —
# заглушки; ключ ставится и отзывается настоящими командами в песочнице.
_r2_rekey_fixture() {
    _prepare_identity_transport
    mkdir -p "$SSH_IDENTITIES_DIR"
    ssh-keygen -q -t ed25519 -N '' -C "essence:$NODE_ID" -f "$SSH_IDENTITIES_DIR/$NODE_ID"
    cp "$SSH_IDENTITIES_DIR/$NODE_ID" "$BATS_TEST_TMPDIR/old.key"
    OLD_PUB=$(cat "$SSH_IDENTITIES_DIR/$NODE_ID.pub")
    printf '%s\n' "$OLD_PUB" >> "$SSH_SANDBOX_HOME/.ssh/authorized_keys"
    jq_w --arg id "$NODE_ID" '.nodes[0].identity=$id | .nodes[0].port=2222'
    _harden_disable_password() { touch "$BATS_TEST_TMPDIR/password-disabled"; }
    _harden_change_port() { SERVER_PORT="$1"; touch "$BATS_TEST_TMPDIR/port-changed"; }
    _harden_restore_password() { touch "$BATS_TEST_TMPDIR/password-restored"; }
}

_r2_assert_old_key_restored() {
    [ "$RC_ERROR_CODE" = hardening_failed ]
    jq -e '.stage == "key" and .rolled_back == true' <<< "$RC_ERROR_EXTRA"
    cmp "$SSH_IDENTITIES_DIR/$NODE_ID" "$BATS_TEST_TMPDIR/old.key"
    [ "$(cat "$SSH_IDENTITIES_DIR/$NODE_ID.pub")" = "$OLD_PUB" ]
    [ "$(cat "$SSH_SANDBOX_HOME/.ssh/authorized_keys")" = "$(printf '%s\n%s' unrelated-existing-key "$OLD_PUB")" ]
    [ "$(jq -r '.nodes[0].identity' "$CONFIG_JSON")" = "$NODE_ID" ]
    ! compgen -G "$CONFIG_DIR/.identity.*" || return 1
    [[ ! -e "$BATS_TEST_TMPDIR/password-disabled" ]]
}

@test "R2-H4: re-harden identity save failure restores the old managed key and revokes the new one" {
    _r2_rekey_fixture
    eval "$(declare -f jq_w | sed '1s/jq_w/_r2_real_jq_w/')"
    jq_w() { [[ "$*" == *'.identity=$identity'* ]] && return 77; _r2_real_jq_w "$@"; }
    core_node_harden node 55555 > "$BATS_TEST_TMPDIR/harden.out" 2>&1 && return 1
    _r2_assert_old_key_restored
}

@test "R2-H4: re-harden checkpoint failure restores the old managed key and revokes the new one" {
    _r2_rekey_fixture
    state_checkpoint() { return 77; }
    core_node_harden node 55555 > "$BATS_TEST_TMPDIR/harden.out" 2>&1 && return 1
    _r2_assert_old_key_restored
}

@test "R2-H4: successful re-harden plans and revokes the replaced managed key on the server" {
    _r2_rekey_fixture
    local line='Прежний SSH-ключ ноды будет заменён новым и отозван на сервере.'
    _harden_load_node node
    HARDEN_NEW_PORT=55555
    core_node_harden_plan
    printf '%s\n' "${CORE_PLAN_LINES[@]}" | grep -qxF "$line"
    NODE_IDENTITY=system core_node_harden_plan
    ! printf '%s\n' "${CORE_PLAN_LINES[@]}" | grep -qxF "$line" || return 1
    core_node_harden node 55555 > "$BATS_TEST_TMPDIR/harden.out" 2>&1
    local new_pub
    new_pub=$(cat "$SSH_IDENTITIES_DIR/$NODE_ID.pub")
    [ "$new_pub" != "$OLD_PUB" ]
    grep -qxF "$new_pub" "$SSH_SANDBOX_HOME/.ssh/authorized_keys"
    ! grep -qxF "$OLD_PUB" "$SSH_SANDBOX_HOME/.ssh/authorized_keys" || return 1
    [[ -e "$BATS_TEST_TMPDIR/password-disabled" && -e "$BATS_TEST_TMPDIR/port-changed" ]]
    ! compgen -G "$CONFIG_DIR/.identity.*"
}

@test "R2-M3: rollback restores password login only for a node that used it before" {
    state_open_local
    export CONFIG_SOURCE=local
    local kid=0123456789abcdef0123456789abcdef pid=fedcba9876543210fedcba9876543210
    jq_w --arg k "$kid" --arg p "$pid" '.nodes=[
        {id:$k,name:"kn",ip:"192.0.2.10",port:2222,user:"root",auth:"key",identity:"system",secret_id:null,aliases:{}},
        {id:$p,name:"pn",ip:"192.0.2.11",port:22,user:"root",auth:"password",identity:null,secret_id:("node:"+$p+":ssh-password"),aliases:{}}]'
    node_secret_set "$pid" pw
    _harden_setup_key() { :; }
    _harden_disable_password() { return 0; }
    _harden_change_port() { HARDEN_PORT_STAGE=port HARDEN_PORT_ROLLED_BACK=true; return 1; }
    _harden_restore_password() { printf '%s\n' "$NODE_NAME" >> "$BATS_TEST_TMPDIR/restored"; }
    core_node_harden kn 55555 > "$BATS_TEST_TMPDIR/harden.out" 2>&1 && return 1
    jq -e '.stage == "port" and .rolled_back == true and .console_required == false' <<< "$RC_ERROR_EXTRA"
    [[ ! -e "$BATS_TEST_TMPDIR/restored" ]]
    _harden_disable_password() { return 1; }
    core_node_harden kn 55555 > "$BATS_TEST_TMPDIR/harden.out" 2>&1 && return 1
    jq -e '.stage == "disable_password" and .rolled_back == true' <<< "$RC_ERROR_EXTRA"
    [[ ! -e "$BATS_TEST_TMPDIR/restored" ]]
    core_node_harden pn 55555 > "$BATS_TEST_TMPDIR/harden.out" 2>&1 && return 1
    [ "$(cat "$BATS_TEST_TMPDIR/restored")" = pn ]
}

@test "R2-M5: local node add undoes the node and its password when the checkpoint fails" {
    _sec_node_fixture
    ssh_run() { printf 'ok\n'; }
    local secrets_before
    secrets_before=$(jq -c '.node_passwords // {} | keys' "$SECRETS_JSON")
    eval "$(declare -f state_checkpoint | sed '1s/state_checkpoint/_r2_real_checkpoint/')"
    R2_CHECKPOINT_FAIL=1
    state_checkpoint() { [[ "$R2_CHECKPOINT_FAIL" != 1 ]] || return 1; _r2_real_checkpoint "$@"; }
    RC_REQUEST_SECRETS='{"password":"pw1"}'
    run_cmd node add --name n1 --ip 192.0.2.5 --auth password --tag DE --accept-new-host-key
    [ "$(cmd_jq '.error.code')" = failed ]
    [ "$(jq -S . "$CONFIG_JSON")" = "$(jq -S . "$BATS_TEST_TMPDIR/config.before")" ]
    [ "$(jq -c '.node_passwords // {} | keys' "$SECRETS_JSON")" = "$secrets_before" ]
    # Откат записи ноды не удался — нода остаётся, ответ partial с её данными.
    eval "$(declare -f jq_w | sed '1s/jq_w/_r2_real_jq_w/')"
    jq_w() { [[ "$*" == *'select(.id != $id)'* ]] && return 77; _r2_real_jq_w "$@"; }
    RC_REQUEST_SECRETS='{"password":"pw1"}'
    run_cmd node add --name n1 --ip 192.0.2.5 --auth password --tag DE --accept-new-host-key
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = partial ]
    cmd_jq --arg id "$(jq_r '.nodes[] | select(.name=="n1") | .id')" \
        '.data == {name:"n1", id:$id, needs_setup:false}' | grep -qx true
    jq_w() { _r2_real_jq_w "$@"; }
    jq_w '.nodes |= [.[] | select(.name != "n1")]'
    R2_CHECKPOINT_FAIL=0
    RC_REQUEST_SECRETS='{"password":"pw1"}'
    run_cmd node add --name n1 --ip 192.0.2.5 --auth password --tag DE --accept-new-host-key
    [ "$status" -eq 0 ]
}

@test "R2-L3: failed local node add restores known_hosts after --host-key and --replace-host-key" {
    _sec_hostkeys
    ssh_run() { printf 'Permission denied\n'; return 255; }
    run_cmd node add --name n1 --ip 198.51.100.7 --auth key --tag t --host-key "$LEGIT_FP"
    [ "$(cmd_jq '.error.code')" = remote_failed ]
    [[ ! -e "$HOME/.ssh/known_hosts" ]]
    printf '198.51.100.7 %s\n' "$OLD_PUB" > "$HOME/.ssh/known_hosts"
    cp "$HOME/.ssh/known_hosts" "$BATS_TEST_TMPDIR/known.before"
    run_cmd node add --name n1 --ip 198.51.100.7 --auth key --tag t --replace-host-key "$LEGIT_FP"
    local token
    token=$(cmd_jq '.error.plan_token')
    run_cmd node add --name n1 --ip 198.51.100.7 --auth key --tag t --replace-host-key "$LEGIT_FP" \
        --yes --plan-token "$token"
    [ "$(cmd_jq '.error.code')" = remote_failed ]
    cmp "$BATS_TEST_TMPDIR/known.before" "$HOME/.ssh/known_hosts"
    [ "$(jq_r '[.nodes[] | select(.name=="n1")] | length')" = 0 ]
    ! compgen -G "$CONFIG_DIR/.known-hosts.*" || return 1
    ssh_run() { printf 'ok\n'; }
    rm -f "$HOME/.ssh/known_hosts"
    run_cmd node add --name n1 --ip 198.51.100.7 --auth key --tag t --host-key "$LEGIT_FP"
    [ "$status" -eq 0 ]
    grep -qxF "198.51.100.7 $LEGIT_PUB" "$HOME/.ssh/known_hosts"
    ! compgen -G "$CONFIG_DIR/.known-hosts.*"
}

@test "R2-L1: server-scope delete reports partial with remote_removed when the local commit fails" {
    _sec_node_fixture
    ssh_run() { printf '%s\n' "${*: -1}" >> "$CALL_LOG"; printf 'ok\n'; }
    ensure_remote_scripts_current() { :; }
    state_checkpoint() { return 1; }
    run_cmd node delete --name "$NAME" --scope server --yes
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = partial ]
    cmd_jq --arg n "$NAME" '.data == {name:$n, scope:"server", deleted:false, remote_removed:true}' | grep -qx true
    grep -q 'uninstall --force' "$CALL_LOG"
    [ "$(jq_r --arg n "$NAME" '[.nodes[] | select(.name==$n)] | length')" = 1 ]
    ! compgen -G "$CONFIG_DIR/.node-delete.*"
}

@test "R2-L2: late identity cleanup partial carries data and leaves no backup with secrets" {
    _sec_node_fixture
    local id
    id=$(jq_r '.nodes[0].id')
    mkdir -p "$SSH_IDENTITIES_DIR"
    ssh-keygen -q -t ed25519 -N '' -f "$SSH_IDENTITIES_DIR/$id"
    rm() { [[ "$*" == *"$SSH_IDENTITIES_DIR/$id"* ]] && return 1; command rm "$@"; }
    run_cmd node delete --name "$NAME" --yes
    unset -f rm
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = partial ]
    cmd_jq --arg n "$NAME" '.data == {name:$n, scope:"local", deleted:true, remote_removed:false}' | grep -qx true
    [ "$(jq_r --arg n "$NAME" '[.nodes[] | select(.name==$n)] | length')" = 0 ]
    ! compgen -G "$CONFIG_DIR/.node-delete.*"
}

@test "R2 node names: add takes only safe names; tags allow Unicode but not shell metacharacters" {
    _sec_node_fixture
    ssh_run() { printf '%s\n' "$*" >> "$CALL_LOG"; printf 'ok\n'; }
    local bad
    for bad in '../x' 'bad/name' '..' 'a b'; do
        run_cmd node add --name "$bad" --ip 192.0.2.5 --auth key --tag t --accept-new-host-key
        [ "$(cmd_jq '.error.code')" = invalid ]
    done
    for bad in 'bad;tag' 'a:b' "x'y" $'a\tb' "$(printf 'T%.0s' {1..33})"; do
        run_cmd node add --name n1 --ip 192.0.2.5 --auth key --tag "$bad" --accept-new-host-key
        [ "$(cmd_jq '.error.code')" = invalid ]
    done
    [[ ! -e "$CALL_LOG" ]]
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    run_cmd node add --name n1 --ip 192.0.2.5 --auth key --tag '🇩🇪 Германия' --accept-new-host-key
    [ "$status" -eq 0 ]
    [ "$(jq_r '.nodes[] | select(.name=="n1") | .tag')" = '🇩🇪 Германия' ]
    run_cmd node tag --name n1 --tag ''
    [ "$status" -eq 0 ]
    _node_tag_valid '' && _node_tag_valid 'EU-1' && ! _node_tag_valid 'a{b}'
}

@test "R2-LM1: SSH commands on a GitHub node with pending setup answer needs_setup before the gate and SSH" {
    load_core
    state_open_local
    RC_SESSION_OPEN=1 RC_SESSION_AUTHORIZED=1 REMOTE_DIR=/root/essence-setup
    local id=0123456789abcdef0123456789abcdef cmd
    jq_w --arg id "$id" '.nodes=[{id:$id,name:"k1",ip:"192.0.2.10",port:22,user:"root",auth:"key",identity:"system",secret_id:null,tag:"DE",aliases:{}}]'
    CONFIG_SOURCE=github
    state_portability_add_issue "$id" missing_identity
    state_portability_add_issue "$id" missing_host_key
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/bash\necho ssh >> "%s"\nexit 255\n' "$BATS_TEST_TMPDIR/ssh.calls" > "$BATS_TEST_TMPDIR/bin/ssh"
    cp "$BATS_TEST_TMPDIR/bin/ssh" "$BATS_TEST_TMPDIR/bin/scp"
    chmod +x "$BATS_TEST_TMPDIR/bin/ssh" "$BATS_TEST_TMPDIR/bin/scp"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    for cmd in "node upload-scripts --name k1" "node upload-scripts --name k1 --force" \
               "node delete --name k1 --scope server" "node harden --name k1" \
               "node harden --name k1 --port 50000"; do
        run_cmd $cmd
        [ "$(cmd_jq '.error.code')" = needs_setup ]
    done
    [[ ! -e "$BATS_TEST_TMPDIR/ssh.calls" ]]
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
}

@test "R2-LM2: host key fingerprints and the setup-ssh plan token do not depend on ssh-keyscan order" {
    load_core
    state_open_local
    RC_SESSION_OPEN=1 RC_SESSION_AUTHORIZED=1
    mkdir -p "$TEMPLATES_DIR" && : > "$TEMPLATES_DIR/default.yaml"
    local id=0123456789abcdef0123456789abcdef t1 first
    jq_w --arg id "$id" '.nodes=[{id:$id,name:"p1",ip:"192.0.2.10",port:22,user:"root",auth:"password",identity:null,secret_id:("node:"+$id+":ssh-password"),tag:"DE",aliases:{}}]'
    node_secret_set "$id" pw
    CONFIG_SOURCE=github
    state_portability_add_issue "$id" missing_host_key
    ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/k1"
    ssh-keygen -q -t ecdsa -N '' -f "$BATS_TEST_TMPDIR/k2"
    R2_FLIP=0
    ssh-keyscan() {
        local a b
        a="192.0.2.10 $(cut -d' ' -f1-2 "$BATS_TEST_TMPDIR/k1.pub")"
        b="192.0.2.10 $(cut -d' ' -f1-2 "$BATS_TEST_TMPDIR/k2.pub")"
        if (( R2_FLIP ^= 1 )); then printf '%s\n%s\n' "$a" "$b"; else printf '%s\n%s\n' "$b" "$a"; fi
    }
    _node_hostkey_scan 192.0.2.10 22
    rm -f "$NODE_HOSTKEY_SCAN"
    first=$(printf '%s\n' "${NODE_HOSTKEY_FPS[@]}")
    [ "${#NODE_HOSTKEY_FPS[@]}" -eq 2 ]
    [ "$first" = "$(printf '%s\n' "${NODE_HOSTKEY_FPS[@]}" | LC_ALL=C sort)" ]
    _node_hostkey_scan 192.0.2.10 22
    rm -f "$NODE_HOSTKEY_SCAN"
    [ "$(printf '%s\n' "${NODE_HOSTKEY_FPS[@]}")" = "$first" ]
    run_cmd node setup-ssh
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    t1=$(cmd_jq '.error.plan_token')
    run_cmd node setup-ssh
    [ "$(cmd_jq '.error.plan_token')" = "$t1" ]
}
