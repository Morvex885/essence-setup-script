#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module nodes.sh
    source "$PROJECT_ROOT/remote-control/modules/ssh.sh"
    source "$PROJECT_ROOT/remote-control/modules/hardening.sh"
    source "$PROJECT_ROOT/remote-control/modules/cli.sh"
    source "$PROJECT_ROOT/remote-control/modules/cmd_nodes.sh"
    load '../helpers/cmd_helper'
    source "$TEST_HELPERS_DIR/mock_ssh.bash"
    state_open_local
    load_fixture_config
    RC_SESSION_OPEN=1 RC_SESSION_AUTHORIZED=1
    NAME=$(jq_r '.nodes[0].name')
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
    local leftovers=("$CONFIG_DIR"/.node-delete.*)
    [[ ! -e "${leftovers[0]}" ]]
    # The recovery made a fresh, key-authenticated login only AFTER adding
    # authorization through the existing authenticated connection.
    grep -q 'false|none||true' "$CALL_LOG"
}

# node delete через ядро (управляемый ключ, отзыв); журнал — в $BATS_TEST_TMPDIR/output.
delete_managed() {
    run_cmd node delete --name "$NAME" --revoke-key --yes
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/output"
    [ "$status" -eq 0 ]
}

@test "local checkpoint failure after key revocation restores local state and key-only login" {
    state_checkpoint() { return 1; }
    if delete_managed; then return 1; fi
    assert_recovered_access
}

@test "long configuration directories retain key-only recovery with a bounded control socket" {
    CONFIG_DIR="$CONFIG_DIR/$(printf '%0120d' 0)"
    mkdir -p "$CONFIG_DIR"
    state_checkpoint() { return 1; }
    if delete_managed; then return 1; fi
    assert_recovered_access
}

@test "GitHub commit failure after key revocation restores local state and key-only login" {
    FLUSHES=0
    github_sync_flush() {
        FLUSHES=$((FLUSHES+1))
        [[ "$FLUSHES" -ne 1 ]]
    }
    if delete_managed; then return 1; fi
    [[ "$FLUSHES" == 2 ]]
    assert_recovered_access
}

@test "GitHub checkpoint failure after revocation restores authorization before recovery checkpoint" {
    CHECKPOINTS=0
    github_config_checkpoint() {
        CHECKPOINTS=$((CHECKPOINTS+1))
        [[ "$CHECKPOINTS" -ne 1 ]]
    }
    if delete_managed; then return 1; fi
    [[ "$CHECKPOINTS" == 2 ]]
    assert_recovered_access
}

@test "successful managed deletion revokes once closes connection and removes sensitive artifacts" {
    delete_managed
    [[ "$(jq_r --arg id "$ID" '[.nodes[] | select(.id==$id)] | length')" == 0 ]]
    if grep -qxF "$PUBKEY" "$REMOTE_HOME/.ssh/authorized_keys"; then return 1; fi
    grep -qxF 'ssh-ed25519 OTHER unrelated' "$REMOTE_HOME/.ssh/authorized_keys"
    [[ ! -e "$SSH_IDENTITIES_DIR/$ID" && ! -e "$SSH_IDENTITIES_DIR/$ID.pub" ]]
    [[ ! -e "$MASTER_STATE" ]]
    [[ "$(wc -l < "$REVOKE_COUNT" | tr -d ' ')" == 1 ]]
    local leftovers=("$CONFIG_DIR"/.node-delete.*)
    [[ ! -e "${leftovers[0]}" ]]
}

@test "failed authorization recovery retains local node key backups and authenticated connection" {
    state_checkpoint() { return 1; }
    RESTORE_FAIL=true
    if delete_managed; then return 1; fi
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    cmp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    [[ -f "$SSH_IDENTITIES_DIR/$ID" && -f "$MASTER_STATE" ]]
    local socket="$(cat "$MASTER_STATE")" backups=("$CONFIG_DIR"/.node-delete.*)
    local backup="${backups[0]}"
    [[ -f "$backup/config" && -f "$backup/secrets" && -f "$backup/key.pub" ]]
    [[ -S "$socket" || -f "$socket" ]]
    grep -qF "$backup" "$BATS_TEST_TMPDIR/output"
    grep -qF "$socket" "$BATS_TEST_TMPDIR/output"
    [[ "$(wc -l < "$REVOKE_COUNT" | tr -d ' ')" == 1 ]]
}

@test "backup preparation failure never revokes remote key" {
    mktemp() { return 1; }
    if delete_managed; then return 1; fi
    [[ ! -e "$CALL_LOG" && ! -e "$REVOKE_COUNT" ]]
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    grep -qxF "$PUBKEY" "$REMOTE_HOME/.ssh/authorized_keys"
}

prepare_abort_backups() {
    KNOWN_BACKUP="$BATS_TEST_TMPDIR/known.backup"
    MANIFEST_BACKUP="$BATS_TEST_TMPDIR/manifest.backup"
    SSH_KNOWN_HOSTS="$CONFIG_DIR/known_hosts"
    printf 'previous-host\n' > "$KNOWN_BACKUP"
    printf 'current-host\n' > "$SSH_KNOWN_HOSTS"
    cp "$STATE_MANIFEST" "$MANIFEST_BACKUP"
}

assert_removed_without_recovery() {
    [[ "$(jq_r --arg id "$ID" '[.nodes[] | select(.id==$id)] | length')" == 0 ]]
    if grep -qxF "$PUBKEY" "$REMOTE_HOME/.ssh/authorized_keys"; then return 1; fi
    [[ ! -e "$MASTER_STATE" ]]
    ! compgen -G "$CONFIG_DIR/.node-delete.*" || return 1
    [ "$(cmd_jq '.error.code')" = partial ]
}

@test "rejected add rollback retains referenced identity secrets and recovery copies" {
    prepare_abort_backups
    jq_w() { return 77; }
    _revoke_managed_remote_key() { touch "$BATS_TEST_TMPDIR/revoked"; }
    node_secret_delete() { touch "$BATS_TEST_TMPDIR/secret-deleted"; }
    if _github_add_abort "$ID" true "$KNOWN_BACKUP" "$MANIFEST_BACKUP"; then return 1; fi
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    cmp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    [[ -f "$SSH_IDENTITIES_DIR/$ID" && -f "$SSH_IDENTITIES_DIR/$ID.pub" ]]
    [[ -f "$KNOWN_BACKUP" && -f "$MANIFEST_BACKUP" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/revoked" && ! -e "$BATS_TEST_TMPDIR/secret-deleted" ]]
}

@test "add rollback failed known hosts restore preserves both recovery copies" {
    prepare_abort_backups
    cp() {
        [[ "$1" == "$KNOWN_BACKUP" ]] && return 77
        command cp "$@"
    }
    if _github_add_abort "$ID" false "$KNOWN_BACKUP" "$MANIFEST_BACKUP"; then return 1; fi
    [[ -f "$KNOWN_BACKUP" && -f "$MANIFEST_BACKUP" ]]
    [[ "$(cat "$SSH_KNOWN_HOSTS")" == current-host ]]
}

@test "add rollback missing known hosts backup does not delete current target" {
    prepare_abort_backups
    rm "$KNOWN_BACKUP"
    if _github_add_abort "$ID" false "$KNOWN_BACKUP" "$MANIFEST_BACKUP"; then return 1; fi
    [[ "$(cat "$SSH_KNOWN_HOSTS")" == current-host ]]
    [[ -f "$MANIFEST_BACKUP" ]]
}

@test "add rollback failed manifest restore retains already restored known hosts backup" {
    prepare_abort_backups
    cp() {
        [[ "$1" == "$MANIFEST_BACKUP" ]] && return 77
        command cp "$@"
    }
    if _github_add_abort "$ID" false "$KNOWN_BACKUP" "$MANIFEST_BACKUP"; then return 1; fi
    cmp "$KNOWN_BACKUP" "$SSH_KNOWN_HOSTS"
    [[ -f "$KNOWN_BACKUP" && -f "$MANIFEST_BACKUP" ]]
}

@test "late identity removal failure leaves node deleted and recovery backup available" {
    rm() {
        [[ "$1" == -f && "${2:-}" == "$SSH_IDENTITIES_DIR/$ID" ]] && return 77
        command rm "$@"
    }
    if delete_managed; then return 1; fi
    assert_removed_without_recovery
    [[ -f "$SSH_IDENTITIES_DIR/$ID" ]]
}

@test "late known hosts removal failure does not restore deleted node or revoked key" {
    SSH_KNOWN_HOSTS="$CONFIG_DIR/known_hosts"
    printf 'fixture\n' > "$SSH_KNOWN_HOSTS"
    ssh-keygen() { return 77; }
    if delete_managed; then return 1; fi
    assert_removed_without_recovery
    [[ ! -f "$SSH_IDENTITIES_DIR/$ID" ]]
}

@test "late GitHub checkpoint failure keeps deletion pending and skips late flush" {
    SSH_KNOWN_HOSTS="$CONFIG_DIR/known_hosts"
    printf 'fixture\n' > "$SSH_KNOWN_HOSTS"
    ssh-keygen() { return 0; }
    CHECKPOINTS=0 FLUSHES=0
    github_config_checkpoint() {
        CHECKPOINTS=$((CHECKPOINTS+1))
        [[ "$CHECKPOINTS" -eq 1 ]]
    }
    github_sync_flush() { FLUSHES=$((FLUSHES+1)); }
    _github_report_last_error() { touch "$BATS_TEST_TMPDIR/reported"; }
    if delete_managed; then return 1; fi
    assert_removed_without_recovery
    [[ "$CHECKPOINTS" == 2 && "$FLUSHES" == 1 && "$GITHUB_SYNC_STATUS" == pending ]]
    [[ -f "$BATS_TEST_TMPDIR/reported" ]]
}

@test "late push failure leaves successful local deletion pending" {
    SSH_KNOWN_HOSTS="$CONFIG_DIR/known_hosts"
    printf 'fixture\n' > "$SSH_KNOWN_HOSTS"
    ssh-keygen() { return 0; }
    FLUSHES=0
    github_sync_flush() {
        FLUSHES=$((FLUSHES+1))
        [[ "$FLUSHES" -eq 1 ]]
    }
    delete_managed
    [[ "$FLUSHES" == 2 && "$GITHUB_SYNC_STATUS" == pending ]]
    [[ "$(jq_r --arg id "$ID" '[.nodes[] | select(.id==$id)] | length')" == 0 ]]
    [[ ! -f "$SSH_IDENTITIES_DIR/$ID" ]]
    local backups=("$CONFIG_DIR"/.node-delete.*)
    [[ ! -e "${backups[0]}" ]]
}

@test "add rollback identity removal failure retains secrets and recovery copies" {
    prepare_abort_backups
    rm() {
        [[ "$1" == -f && "${2:-}" == "$SSH_IDENTITIES_DIR/$ID" ]] && return 77
        command rm "$@"
    }
    node_secret_delete() { touch "$BATS_TEST_TMPDIR/secret-deleted"; }
    if _github_add_abort "$ID" false "$KNOWN_BACKUP" "$MANIFEST_BACKUP"; then return 1; fi
    [[ -f "$SSH_IDENTITIES_DIR/$ID" && -f "$KNOWN_BACKUP" && -f "$MANIFEST_BACKUP" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/secret-deleted" ]]
}

@test "add rollback secret removal failure retains recovery copies" {
    prepare_abort_backups
    node_secret_delete() { return 77; }
    if _github_add_abort "$ID" false "$KNOWN_BACKUP" "$MANIFEST_BACKUP"; then return 1; fi
    cmp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    [[ -f "$KNOWN_BACKUP" && -f "$MANIFEST_BACKUP" ]]
    [[ "$(cat "$SSH_KNOWN_HOSTS")" == current-host ]]
}

@test "add rollback missing manifest backup retains current manifest and surviving backup" {
    prepare_abort_backups
    rm "$MANIFEST_BACKUP"
    if _github_add_abort "$ID" false "$KNOWN_BACKUP" "$MANIFEST_BACKUP"; then return 1; fi
    # The rollback writer may update the manifest; it must never delete it.
    [[ -f "$STATE_MANIFEST" && -f "$KNOWN_BACKUP" ]]
}

@test "late nonstandard port known hosts failure preserves committed deletion" {
    jq_w '.nodes[0].port=2222'
    SSH_KNOWN_HOSTS="$CONFIG_DIR/known_hosts"
    printf 'fixture\n' > "$SSH_KNOWN_HOSTS"
    ssh-keygen() {
        [[ "$2" != *']:2222' ]]
    }
    if delete_managed; then return 1; fi
    assert_removed_without_recovery
}

@test "standard port cleanup does not attempt bracketed host removal" {
    jq_w '.nodes[0].port=22'
    SSH_KNOWN_HOSTS="$CONFIG_DIR/known_hosts"
    printf 'fixture\n' > "$SSH_KNOWN_HOSTS"
    ssh-keygen() {
        [[ "$2" != \[* ]] || return 77
        printf '%s\n' "$2" >> "$BATS_TEST_TMPDIR/removed-hosts"
    }
    delete_managed
    [[ "$(wc -l < "$BATS_TEST_TMPDIR/removed-hosts" | tr -d ' ')" == 1 ]]
}

# ─── Команды нод без вопросов ────────────────────────────────────────────────

# Локальный режим с заглушками ssh-keyscan/ssh-keygen: отпечаток SHA256:fp-new.
use_local_hostkey_stubs() {
    CONFIG_SOURCE=local
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.ssh" "$BATS_TEST_TMPDIR/bin"
    printf '9.9.9.9 ssh-ed25519 OLD\n' > "$HOME/.ssh/known_hosts"
    cat > "$BATS_TEST_TMPDIR/bin/ssh-keyscan" <<'EOF'
#!/bin/bash
echo "9.9.9.9 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINewKeyForTests"
EOF
    cat > "$BATS_TEST_TMPDIR/bin/ssh-keygen" <<'EOF'
#!/bin/bash
case "$1" in
    -F) exit 1 ;;
    -l*|-E) echo "256 SHA256:fp-new 9.9.9.9 (ED25519)" ;;
    -R) grep -v "^$2 " "$4" > "$4.tmp"; mv "$4.tmp" "$4" ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/ssh-keyscan" "$BATS_TEST_TMPDIR/bin/ssh-keygen"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "node delete without --yes returns the plan and touches nothing" {
    run_cmd node delete --name "$NAME" --revoke-key
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    cmd_jq '.error.plan | any(startswith("Объём:"))' | grep -qx true
    [[ ! -e "$CALL_LOG" ]]
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
}

@test "node show lists delete options with labels for a managed key" {
    run_cmd node show --name "$NAME"
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '[.data.delete_options[] | "\(.scope):\(.revoke_key)"] | join(",")')" = \
        "local:false,local:true,server:false,server:true" ]
    cmd_jq '.data.delete_options | all(.label | length > 0)' | grep -qx true
    CONFIG_SOURCE=local
    run_cmd node show --name ru-vps
    [ "$(cmd_jq '[.data.delete_options[] | .scope] | join(",")')" = "local,server" ]
}

@test "node shell and node setup-ssh answer with decision codes without SSH" {
    _rc_tty_available() { return 1; }
    run_cmd node shell --name "$NAME"
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = tty_required ]
    [[ ! -e "$CALL_LOG" ]]

    # План setup-ssh читает ключи серверов: без сети ключ не прочитан.
    ssh-keyscan() { return 1; }
    CONFIG_SOURCE=local
    run_cmd node setup-ssh --yes
    [ "$(cmd_jq '.error.code')" = invalid ]
    CONFIG_SOURCE=github
    state_actionable_ssh_setup_pending() { return 1; }
    run_cmd node setup-ssh --yes
    [ "$(cmd_jq '.error.code')" = nothing_pending ]
    state_actionable_ssh_setup_pending() { return 0; }
    jq_w '.nodes[0].identity="system"'
    run_cmd node setup-ssh
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = key_provisioning_required ]
    [ "$(cmd_jq '.error.nodes | join(",")')" = de-vps ]
    run_cmd node setup-ssh --provision-keys maybe
    [ "$(cmd_jq '.error.code')" = usage ]
    run_cmd node setup-ssh --provision-keys no --on-failure defer
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [[ ! -e "$CALL_LOG" ]]
}

@test "node add with --replace-host-key pins only a matching fingerprint" {
    use_local_hostkey_stubs
    ssh_run() { printf 'ok\n'; }
    run_cmd node add --name fresh --ip 9.9.9.9 --auth key --tag T --replace-host-key SHA256:other
    [ "$(cmd_jq '.error.code')" = host_key_mismatch ]
    [ "$(jq_r '[.nodes[] | select(.name=="fresh")] | length')" = 0 ]
    grep -q OLD "$HOME/.ssh/known_hosts"

    run_cmd node add --name fresh --ip 9.9.9.9 --auth key --tag T --accept-new-host-key \
        --replace-host-key SHA256:fp-new
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    cmd_jq '.error.plan | any(. == "Новый отпечаток: SHA256:fp-new")' | grep -qx true
    [ "$(jq_r '[.nodes[] | select(.name=="fresh")] | length')" = 0 ]
    grep -q OLD "$HOME/.ssh/known_hosts"
    local token
    token=$(cmd_jq '.error.plan_token')
    run_cmd node add --name fresh --ip 9.9.9.9 --auth key --tag T --accept-new-host-key \
        --replace-host-key SHA256:fp-new --yes --plan-token "$token"
    [ "$status" -eq 0 ]
    [ "$(jq_r '[.nodes[] | select(.name=="fresh")] | length')" = 1 ]
    ! grep -q OLD "$HOME/.ssh/known_hosts" || return 1
    grep -q NewKeyForTests "$HOME/.ssh/known_hosts"

    run_cmd node add --name other --ip 9.9.9.9 --auth key --tag T --host-key SHA256:fp-new \
        --replace-host-key SHA256:fp-new
    [ "$(cmd_jq '.error.code')" = usage ]
}

@test "node add reports a changed host key and an SSH failure with details" {
    use_local_hostkey_stubs
    ssh_run() { printf '@@@ REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\n'; return 255; }
    run_cmd node add --name fresh --ip 9.9.9.9 --auth key --tag T --accept-new-host-key
    [ "$(cmd_jq '.error.code')" = host_key_changed ]
    cmd_jq '.error | .host == "9.9.9.9" and .port == 22 and .fingerprints == ["SHA256:fp-new"]' | grep -qx true
    ssh_run() { printf 'Permission denied (publickey).\n'; return 255; }
    run_cmd node add --name fresh --ip 9.9.9.9 --auth key --tag T --accept-new-host-key
    [ "$(cmd_jq '.error.code')" = remote_failed ]
    cmd_jq '.error | (.reason | test("denied")) and .hint == "ssh-copy-id root@9.9.9.9"' | grep -qx true
    [ "$(jq_r '[.nodes[] | select(.name=="fresh")] | length')" = 0 ]
}

@test "node trust-host-key checks the fingerprint, needs --yes and replaces old entries" {
    use_local_hostkey_stubs
    jq_w '.nodes[0].ip="9.9.9.9"'
    run_cmd node trust-host-key --name "$NAME" --host-key SHA256:other
    [ "$(cmd_jq '.error.code')" = host_key_mismatch ]
    run_cmd node trust-host-key --name "$NAME" --host-key SHA256:fp-new
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    cmd_jq '.error.plan | any(. == "Новый отпечаток: SHA256:fp-new")' | grep -qx true
    grep -q OLD "$HOME/.ssh/known_hosts"
    run_cmd node trust-host-key --name "$NAME" --host-key SHA256:fp-new --yes
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.fingerprint')" = SHA256:fp-new ]
    ! grep -q OLD "$HOME/.ssh/known_hosts" || return 1
    grep -q NewKeyForTests "$HOME/.ssh/known_hosts"
}

@test "node check reports a changed host key through ssh_probe" {
    use_local_hostkey_stubs
    jq_w '.nodes[0].ip="9.9.9.9"'
    ssh_run() { printf 'REMOTE HOST IDENTIFICATION HAS CHANGED\n'; return 255; }
    run_cmd node check --name "$NAME"
    [ "$(cmd_jq '.error.code')" = host_key_changed ]
    [ "$(cmd_jq '.error.fingerprints[0]')" = SHA256:fp-new ]
    ssh_run() { printf 'ok\n'; }
    run_cmd node check --name "$NAME"
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.reachable')" = true ]
}

@test "host key commands sort unique SHA256 fingerprints without Bash mapfile" {
    use_local_hostkey_stubs
    jq_w '.nodes[0].ip="9.9.9.9"'
    mapfile() { printf '%s\n' called > "$BATS_TEST_TMPDIR/mapfile-called"; return 127; }
    ssh-keygen() {
        case "$1" in
            -lf) printf '256 MD5:legacy 9.9.9.9 (ED25519)\n' ;;
            -E) printf '%s\n' \
                '256 SHA256:fp-z 9.9.9.9 (ED25519)' \
                '256 SHA256:fp-a 9.9.9.9 (ECDSA)' \
                '256 SHA256:fp-z 9.9.9.9 (ED25519)' ;;
            *) return 1 ;;
        esac
    }
    run_cmd node trust-host-key --name "$NAME" --host-key SHA256:other
    [ "$(cmd_jq '.error.code')" = host_key_mismatch ]
    [ "$(cmd_jq '.error.fingerprints | join(",")')" = SHA256:fp-a,SHA256:fp-z ]
    run_cmd node trust-host-key --name "$NAME" --host-key SHA256:fp-a
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [[ ! -e "$BATS_TEST_TMPDIR/mapfile-called" ]]
    grep -q OLD "$HOME/.ssh/known_hosts"
}

@test "host key commands reject an empty fingerprint scan without Bash mapfile or stale results" {
    use_local_hostkey_stubs
    jq_w '.nodes[0].ip="9.9.9.9"'
    export TMPDIR="$BATS_TEST_TMPDIR/hostkey-tmp"
    mkdir -p "$TMPDIR"
    mapfile() { printf '%s\n' called > "$BATS_TEST_TMPDIR/mapfile-called"; return 127; }
    ssh-keygen() { printf '256 MD5:legacy 9.9.9.9 (ED25519)\n'; }
    NODE_HOSTKEY_FPS=(SHA256:stale)
    NODE_HOSTKEY_SCAN=stale
    run_cmd node trust-host-key --name "$NAME" --host-key SHA256:other
    [ "$(cmd_jq '.error.code')" = remote_failed ]
    [ "${#NODE_HOSTKEY_FPS[@]}" -eq 0 ]
    [[ -z "$NODE_HOSTKEY_SCAN" && ! -e "$BATS_TEST_TMPDIR/mapfile-called" ]]
    local leftovers=("$TMPDIR"/essence-hostkey.*)
    [[ ! -e "${leftovers[0]}" ]]
    grep -q OLD "$HOME/.ssh/known_hosts"
}
