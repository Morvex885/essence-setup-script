#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module nodes.sh
    source_module hardening.sh
    source_module self.sh
    source_module awg_peers.sh
    source "$TEST_HELPERS_DIR/mock_ssh.bash"
    state_open_local
    load_fixture_config
    export SSH_IDENTITIES_DIR="$CONFIG_DIR/identities" REMOTE_DIR='/opt/essence scripts'
    mkdir -p "$SSH_IDENTITIES_DIR"
    node_load 1
    state_action() { shift; "$@"; }
}
teardown() { teardown_test_env; }

@test "node deletion denial leaves config secrets and remote untouched" {
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    cp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    CONFIRMS=0
    confirm_yn() { CONFIRMS=$((CONFIRMS+1)); [[ "$2" == N ]]; return 1; }
    delete_node <<< $'1\n2'
    [[ "$CONFIRMS" == 1 ]]
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    cmp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    [[ ${#SSH_RUN_CALLS[@]} == 0 && ${#UPLOAD_CALLS[@]} == 0 ]]
}

@test "failed noninteractive server removal preserves local node and secrets" {
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    cp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    SSH_RUN_MOCK_EXIT=1
    if delete_node <<< $'2\n2\ny'; then return 1; fi
    [[ ${#UPLOAD_CALLS[@]} == 1 && ${#SSH_RUN_CALLS[@]} == 1 ]]
    [[ "${SSH_RUN_CALLS[0]}" == *'uninstall --force' ]]
    [[ "${SSH_RUN_CALLS[0]}" != *'telegram-proxy'* ]]
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    cmp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
}

@test "key revocation failure preserves managed node before local mutation" {
    CONFIG_SOURCE=github
    jq_w '.nodes[0].identity=.nodes[0].id'
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    _revoke_managed_remote_key() { return 1; }
    if delete_node <<< $'1\n2\ny'; then return 1; fi
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    [[ ${#UPLOAD_CALLS[@]} == 0 ]]
}

@test "server removal uses the selected node and a 900 second timeout" {
    capture="$BATS_TEST_TMPDIR/remote.call"
    ssh_run() {
        printf '%s|%s|%s\n' "$NODE_NAME" "$SSH_RUN_TIMEOUT" "$*" > "$capture"
        return 1
    }
    if delete_node <<< $'2\n2\ny'; then return 1; fi
    [[ "$(cat "$capture")" == 'ru-vps|900|'*'uninstall --force' ]]
    [[ "$(jq_r '.nodes | length')" == 2 ]]
}

@test "failed local checkpoint rolls node deletion back" {
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    cp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    state_checkpoint() { return 1; }
    if delete_node <<< $'2\n1\ny'; then return 1; fi
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    cmp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
}

@test "already hardened node has one deny-default confirmation after port selection" {
    SERVER_AUTH=key SERVER_PORT=2222
    SSH_RUN_MOCK_OUTPUT=free
    CONFIRMS=0
    confirm_yn() { CONFIRMS=$((CONFIRMS+1)); [[ "$2" == N ]]; return 1; }
    _harden_setup_key() { touch "$BATS_TEST_TMPDIR/mutation"; }
    _harden_disable_password() { touch "$BATS_TEST_TMPDIR/mutation"; }
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    ssh_hardening <<< $'\n'
    [[ "$CONFIRMS" == 1 && -n "$HARDEN_NEW_PORT" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/mutation" ]]
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    CONFIRMS=0
    if ssh_hardening </dev/null; then return 1; fi
    [[ "$CONFIRMS" == 0 && ! -e "$BATS_TEST_TMPDIR/mutation" ]]
}

@test "SSH transport failure cannot select a free port" {
    SSH_RUN_MOCK_EXIT=255
    if _harden_select_port <<< ''; then return 1; fi
    [[ -z "$HARDEN_NEW_PORT" ]]
}

@test "occupied custom SSH port is rejected" {
    counter="$BATS_TEST_TMPDIR/port.checks"
    printf '0\n' > "$counter"
    ssh_run() {
        local n
        n=$(cat "$counter"); printf '%s\n' "$((n+1))" > "$counter"
        if [[ "$n" == 0 ]]; then printf 'free\n'; else printf 'occupied\n'; fi
    }
    if _harden_select_port <<< '2222'; then return 1; fi
    [[ -z "$HARDEN_NEW_PORT" && "$(cat "$counter")" == 2 ]]
}

@test "unconfirmed rollback does not persist new SSH port" {
    SSH_RUN_MOCK_EXIT=1
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    if _harden_change_port 55555; then return 1; fi
    [[ "$SERVER_PORT" == 22 ]]
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
}

@test "rollback needs both successful remote commands and old port connection" {
    SSH_RUN_MOCK_OUTPUT=wrong
    if _harden_rollback_port 22 55555; then return 1; fi
    [[ "$SERVER_PORT" == 22 ]]
    SSH_RUN_MOCK_OUTPUT=ok
    _harden_rollback_port 22 55555
    [[ "$SERVER_PORT" == 22 ]]
}

@test "AWG stale snapshot blocks all mutations until a successful refresh" {
    ssh_connect() { return 0; }
    _awg_expected_peers() { printf 'alpha\nbeta\n'; }
    calls="$BATS_TEST_TMPDIR/awg.calls"
    ssh_run() {
        printf '%s\n' "$*" >> "$calls"
        if [[ "$*" == *AWG_OK* ]]; then printf 'AWG_OK\nalpha\n'; return 0; fi
        return 1
    }
    _awg_peers_mutate() { touch "$BATS_TEST_TMPDIR/mutated"; }
    _awg_peers_node 1 <<< $'r\nc\nd\nx\n0'
    [[ ! -e "$BATS_TEST_TMPDIR/mutated" ]]
    [[ "$(wc -l < "$calls" | tr -d ' ')" == 2 ]]
}

@test "AWG successful refresh re-enables client creation" {
    ssh_connect() { return 0; }
    _awg_expected_peers() { printf 'alpha\nbeta\n'; }
    counter="$BATS_TEST_TMPDIR/refresh.counter"; printf '0\n' > "$counter"
    ssh_run() {
        if [[ "$*" == *AWG_OK* ]]; then printf 'AWG_OK\nalpha\n'; return 0; fi
        local n
        n=$(cat "$counter"); printf '%s\n' "$((n+1))" > "$counter"
        [[ "$n" == 0 ]] && return 1
        printf 'alpha\n'
    }
    _awg_peers_mutate() { printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/mutated"; }
    _awg_peers_node 1 <<< $'r\nc\nr\nc\n0'
    [[ "$(cat "$BATS_TEST_TMPDIR/mutated")" == *'add_awg_peer_auto beta'* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/mutated")" != *'add_awg_peer_auto alpha'* ]]
}

@test "password menu persists across rejected changes and denied removal" {
    passfile=$(_script_pass_file)
    _hash_pass() { printf 'saved:%s\n' "$1"; }
    _verify_pass() { [[ "$1" == "saved:$2" ]]; }
    set_script_password <<< $'1\nfirst\nfirst\n1\nwrong\n2\nfirst\nn\n1\nfirst\nsecond\nsecond\n0'
    [[ "$(cat "$passfile")" == saved:second ]]
    set_script_password <<< $'2\nsecond\ny\n0'
    [[ ! -e "$passfile" ]]
}

@test "EOF during password entry preserves current authentication" {
    passfile=$(_script_pass_file)
    printf 'saved:first\n' > "$passfile"
    _verify_pass() { [[ "$1" == "saved:$2" ]]; }
    set_script_password <<< $'1\nfirst'
    [[ "$(cat "$passfile")" == saved:first ]]
}

@test "failed updater preserves CURRENT_VERSION" {
    [[ "$EUID" == 0 ]] || skip 'requires root to exercise installer failure'
    printf '#!/bin/bash\nexit 1\n' > "$SCRIPT_DIR/install-remote-control.sh"
    CURRENT_VERSION=old-version
    if self_update; then return 1; fi
    [[ "$CURRENT_VERSION" == old-version ]]
}

@test "uninstall rejects HOME aliases before deletion" {
    [[ "$EUID" == 0 ]] || skip 'requires root to exercise uninstall'
    HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
    CONFIG_DIR="$HOME/./"
    rm() { touch "$BATS_TEST_TMPDIR/rm.called"; }
    if uninstall_self <<< $'2\ny'; then return 1; fi
    [[ ! -e "$BATS_TEST_TMPDIR/rm.called" ]]
    unset -f rm
}

@test "uninstall rm failure never removes local data" {
    [[ "$EUID" == 0 ]] || skip 'requires root to exercise uninstall'
    marker="$CONFIG_DIR/preserved"; touch "$marker"
    calls=()
    rm() { calls+=("$*"); return 1; }
    if uninstall_self <<< $'2\ny'; then return 1; fi
    [[ ${#calls[@]} == 1 && -f "$marker" ]]
    unset -f rm
}
