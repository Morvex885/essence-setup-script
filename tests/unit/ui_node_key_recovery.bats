#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module nodes.sh
    source "$TEST_HELPERS_DIR/mock_ssh.bash"
    state_open_local
    load_fixture_config
    CONFIG_SOURCE=github
    ID=$(jq_r '.nodes[0].id')
    SSH_IDENTITIES_DIR="$CONFIG_DIR/identities"
    mkdir -p "$SSH_IDENTITIES_DIR"
    jq_w '.nodes[0].identity=.nodes[0].id | .nodes[0].auth="key"'
    # No other login method: fresh connections require this authorization.
    PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest essence-managed'
    printf '%s\n' private-test-key > "$SSH_IDENTITIES_DIR/$ID"
    printf '%s\n' "$PUBKEY" > "$SSH_IDENTITIES_DIR/$ID.pub"
    REMOTE_HOME="$BATS_TEST_TMPDIR/remote"
    mkdir -p "$REMOTE_HOME/.ssh"
    printf '%s\n' "$PUBKEY" 'ssh-ed25519 OTHER unrelated' > "$REMOTE_HOME/.ssh/authorized_keys"
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    cp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    cp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    CONFIRMS=0
    confirm_yn() { CONFIRMS=$((CONFIRMS+1)); [[ "$2" == N ]]; }
    github_config_checkpoint() { return 0; }
    github_sync_flush() { return 0; }
    CALL_LOG="$BATS_TEST_TMPDIR/ssh.calls"
    MASTER_STATE="$BATS_TEST_TMPDIR/master"
    REVOKE_COUNT="$BATS_TEST_TMPDIR/revokes"
    RESTORE_FAIL=false
    # Extend the standard mock with an authenticated transport model. Commands
    # run only against a local sandbox; no ssh process is ever launched.
    ssh_run() {
        local socket='' master=false operation='' fallback_blocked=false command
        while [[ $# -gt 0 && "$1" != -- ]]; do
            case "$1" in
                -S) socket="$2"; shift ;;
                -M) master=true ;;
                -O) operation="$2"; shift ;;
                -o) [[ "$2" == ProxyCommand=false ]] && fallback_blocked=true; shift ;;
                -i) shift ;;
            esac
            shift
        done
        [[ "${1:-}" == -- ]] && shift
        command="$*"
        printf '%s|%s|%s|%s\n' "$master" "$socket" "$operation" "$command" >> "$CALL_LOG"
        if [[ "$master" == true ]]; then
            grep -qxF "$PUBKEY" "$REMOTE_HOME/.ssh/authorized_keys" || return 255
            [[ "${#socket}" -le 103 ]] || return 255
            printf '%s' "$socket" > "$MASTER_STATE"
            touch "$socket"
            return 0
        fi
        if [[ "$operation" == exit ]]; then
            rm -f "$MASTER_STATE" "$socket"
            return 0
        fi
        if [[ "$socket" != none ]]; then
            [[ "$fallback_blocked" == true && -f "$MASTER_STATE" && "$(cat "$MASTER_STATE")" == "$socket" ]] || return 255
        else
            grep -qxF "$PUBKEY" "$REMOTE_HOME/.ssh/authorized_keys" || return 255
            [[ -f "$SSH_IDENTITIES_DIR/$ID" ]] || return 255
        fi
        if [[ "$command" == *'awk -v key='* ]]; then
            printf 'revoke\n' >> "$REVOKE_COUNT"
        fi
        if [[ "$command" == *'printf '\''%s\n'\'' '* && "$RESTORE_FAIL" == true ]]; then
            return 1
        fi
        HOME="$REMOTE_HOME" bash -c "$command"
    }
}

teardown() {
    if [[ -f "$MASTER_STATE" ]]; then
        local socket="$(cat "$MASTER_STATE")"
        [[ "$socket" == /tmp/essence-ssh.*/control ]] && command rm -rf "${socket%/*}"
    fi
    teardown_test_env
}

assert_recovered_access() {
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    cmp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    cmp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    grep -qxF "$PUBKEY" "$REMOTE_HOME/.ssh/authorized_keys"
    grep -qxF 'ssh-ed25519 OTHER unrelated' "$REMOTE_HOME/.ssh/authorized_keys"
    [[ -f "$SSH_IDENTITIES_DIR/$ID" ]]
    [[ ! -e "$MASTER_STATE" ]]
    [[ "$(wc -l < "$REVOKE_COUNT" | tr -d ' ')" == 1 ]]
    [[ "$CONFIRMS" == 1 ]]
    local leftovers=("$CONFIG_DIR"/.node-delete.*)
    [[ ! -e "${leftovers[0]}" ]]
    # The recovery made a fresh, key-authenticated login only AFTER adding
    # authorization through the existing authenticated connection.
    grep -q 'false|none||true' "$CALL_LOG"
}

@test "local checkpoint failure after key revocation restores local state and key-only login" {
    state_checkpoint() { return 1; }
    if delete_node <<< $'1\n2'; then return 1; fi
    assert_recovered_access
}

@test "long configuration directories retain key-only recovery with a bounded control socket" {
    CONFIG_DIR="$CONFIG_DIR/$(printf '%0120d' 0)"
    mkdir -p "$CONFIG_DIR"
    state_checkpoint() { return 1; }
    if delete_node <<< $'1\n2'; then return 1; fi
    assert_recovered_access
}

@test "GitHub commit failure after key revocation restores local state and key-only login" {
    FLUSHES=0
    github_sync_flush() {
        FLUSHES=$((FLUSHES+1))
        [[ "$FLUSHES" -ne 1 ]]
    }
    if delete_node <<< $'1\n2'; then return 1; fi
    [[ "$FLUSHES" == 2 ]]
    assert_recovered_access
}

@test "GitHub checkpoint failure after revocation restores authorization before recovery checkpoint" {
    CHECKPOINTS=0
    github_config_checkpoint() {
        CHECKPOINTS=$((CHECKPOINTS+1))
        [[ "$CHECKPOINTS" -ne 1 ]]
    }
    if delete_node <<< $'1\n2'; then return 1; fi
    [[ "$CHECKPOINTS" == 2 ]]
    assert_recovered_access
}

@test "successful managed deletion revokes once closes connection and removes sensitive artifacts" {
    delete_node <<< $'1\n2'
    [[ "$(jq_r --arg id "$ID" '[.nodes[] | select(.id==$id)] | length')" == 0 ]]
    if grep -qxF "$PUBKEY" "$REMOTE_HOME/.ssh/authorized_keys"; then return 1; fi
    grep -qxF 'ssh-ed25519 OTHER unrelated' "$REMOTE_HOME/.ssh/authorized_keys"
    [[ ! -e "$SSH_IDENTITIES_DIR/$ID" && ! -e "$SSH_IDENTITIES_DIR/$ID.pub" ]]
    [[ ! -e "$MASTER_STATE" ]]
    [[ "$CONFIRMS" == 1 ]]
    [[ "$(wc -l < "$REVOKE_COUNT" | tr -d ' ')" == 1 ]]
    local leftovers=("$CONFIG_DIR"/.node-delete.*)
    [[ ! -e "${leftovers[0]}" ]]
}

@test "failed authorization recovery retains local node key backups and authenticated connection" {
    state_checkpoint() { return 1; }
    RESTORE_FAIL=true
    if delete_node <<< $'1\n2' > "$BATS_TEST_TMPDIR/output"; then return 1; fi
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    cmp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    [[ -f "$SSH_IDENTITIES_DIR/$ID" && -f "$MASTER_STATE" ]]
    local socket="$(cat "$MASTER_STATE")" backups=("$CONFIG_DIR"/.node-delete.*)
    local backup="${backups[0]}"
    [[ -f "$backup/config" && -f "$backup/secrets" && -f "$backup/key.pub" ]]
    [[ -S "$socket" || -f "$socket" ]]
    grep -qF "$backup" "$BATS_TEST_TMPDIR/output"
    grep -qF "$socket" "$BATS_TEST_TMPDIR/output"
    [[ "$CONFIRMS" == 1 ]]
    [[ "$(wc -l < "$REVOKE_COUNT" | tr -d ' ')" == 1 ]]
}

@test "backup preparation failure never revokes remote key" {
    mktemp() { return 1; }
    if delete_node <<< $'1\n2'; then return 1; fi
    [[ ! -e "$CALL_LOG" && ! -e "$REVOKE_COUNT" ]]
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    grep -qxF "$PUBKEY" "$REMOTE_HOME/.ssh/authorized_keys"
}
