#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module state.sh
    source_module nodes.sh
    source "$TESTS_DIR/helpers/mock_ssh.bash"
    # Keep the real option builder, askpass handling and ssh invocation. Only
    # the transport binary is replaced; no network or accepted system key exists.
    source_module ssh.sh
    source_module hardening.sh
    state_open_local
    export CONFIG_SOURCE=local NODE_NAME=local-password NODE_ID=node-id
    export NODE_IDENTITY=system SERVER_IP=192.0.2.10 SERVER_PORT=22 SERVER_USER=root
    export SERVER_AUTH=password SERVER_PASS='hardening-password-canary'
    export SSH_IDENTITIES_DIR="$CONFIG_DIR/identities with spaces"
    export SSH_ARGV_DIR="$BATS_TEST_TMPDIR/argv" SSH_RECOVERY_FAULT=none
    export SSH_AUTH_SOCK= HOME="$BATS_TEST_TMPDIR/empty-home"
    unset SSH_ASKPASS SSH_ASKPASS_REQUIRE
    mkdir -p "$SSH_IDENTITIES_DIR" "$SSH_ARGV_DIR" "$HOME" "$BATS_TEST_TMPDIR/bin"
    cat > "$CONFIG_JSON" <<'EOF'
{"schema_version":2,"nodes":[{"id":"node-id","name":"local-password","ip":"192.0.2.10","port":22,"user":"root","auth":"password","identity":"system","secret_id":"node-id"}],"groups":[],"clients":[],"connections":[]}
EOF
    node_secret_set "$NODE_ID" "$SERVER_PASS"
    cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'EOF'
#!/bin/bash
n=0
[[ ! -f "$SSH_ARGV_DIR/count" ]] || read -r n < "$SSH_ARGV_DIR/count"
n=$((n + 1))
printf '%s\n' "$n" > "$SSH_ARGV_DIR/count"
printf '%s\0' "$@" > "$SSH_ARGV_DIR/$n.argv"
key= port= batch= identities= password_auth= command=
while (( $# )); do
    case "$1" in
        -i) key="$2"; shift 2 ;;
        -p) port="$2"; shift 2 ;;
        -o)
            case "$2" in
                BatchMode=*) batch="${2#*=}" ;;
                IdentitiesOnly=*) identities="${2#*=}" ;;
                PasswordAuthentication=*) password_auth="${2#*=}" ;;
            esac
            shift 2 ;;
        root@*) shift; command="$1"; break ;;
        *) exit 90 ;;
    esac
done
case "$command" in
    *'ss -tlnp'*) phase=select ;;
    *'mkdir -p ~/.ssh'*) phase=install ;;
    *'PasswordAuthentication no'*) phase=disable ;;
    *'PasswordAuthentication yes'*) phase=restore ;;
    *"echo 'Port 55555'"*) phase=apply ;;
    *"echo 'Port 22'"*) phase=rollback ;;
    'echo ok')
        if [[ "$key" == *'/.identity.'* ]]; then phase=verify-key
        elif [[ "$port" == 55555 ]]; then phase=verify-new
        else phase=verify-old; fi ;;
    *) exit 91 ;;
esac
printf '%s %s\n' "$phase" "$port" > "$SSH_ARGV_DIR/$n.phase"
if [[ "$phase" == select || "$phase" == install ]]; then
    [[ -n "${SSH_ASKPASS:-}" && -x "$SSH_ASKPASS" ]] || exit 92
    [[ "$("$SSH_ASKPASS")" == hardening-password-canary ]] || exit 93
else
    # Key-only transport cannot silently use an agent, system key or password.
    [[ -s "$key" && "$batch" == yes && "$identities" == yes && "$password_auth" == no ]] || exit 94
    [[ -z "${SSH_ASKPASS:-}" ]] || exit 95
fi
case "$SSH_RECOVERY_FAULT:$phase:$port" in
    apply:apply:* | verify:verify-new:* | fallback:verify-new:* | rollback:verify-new:*) exit 1 ;;
    fallback:rollback:22 | rollback:rollback:*) exit 1 ;;
esac
[[ "$phase" != select ]] || printf 'free\n'
[[ "$phase" != verify-key && "$phase" != verify-new && "$phase" != verify-old ]] || printf 'ok\n'
exit 0
EOF
    chmod 755 "$BATS_TEST_TMPDIR/bin/ssh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    sleep() {
        [[ "${1:-}" != 3 ]] || return 0
        command sleep "$@"
    }
}

teardown() { teardown_test_env; }

assert_key_recovery_argv() {
    local file phase port arg previous identity batch identities password_auth
    for file in "$SSH_ARGV_DIR/"*.argv; do
        read -r phase port < "${file%.argv}.phase"
        identity= batch= identities= password_auth= previous=
        while IFS= read -r -d '' arg; do
            [[ "$arg" != *hardening-password-canary* ]]
            if [[ "$previous" == -i ]]; then identity="$arg"; fi
            if [[ "$previous" == -o ]]; then
                case "$arg" in
                    BatchMode=yes) batch=yes ;;
                    IdentitiesOnly=yes) identities=yes ;;
                    PasswordAuthentication=no) password_auth=no ;;
                esac
            fi
            previous="$arg"
        done < "$file"
        [[ "$phase" != select && "$phase" != install ]] || continue
        [[ "$batch" == yes && "$identities" == yes && "$password_auth" == no ]]
        if [[ "$phase" == verify-key ]]; then
            [[ "$identity" == "$CONFIG_DIR"/.identity.*/node-id ]]
        else
            [[ "$identity" == "$SSH_IDENTITIES_DIR/node-id" ]]
        fi
    done
    [[ "$(cat "$BATS_TEST_TMPDIR/output")" != *hardening-password-canary* ]]
    local private
    private=$(cat "$SSH_IDENTITIES_DIR/node-id")
    [[ "$(cat "$BATS_TEST_TMPDIR/output")" != *"$private"* ]]
}

assert_phase() {
    local wanted="$1" file actual found=false
    for file in "$SSH_ARGV_DIR/"*.phase; do
        actual=$(cat "$file")
        [[ "$actual" != "$wanted" ]] || found=true
    done
    [[ "$found" == true ]]
}

assert_original_connection_preserved() {
    [[ "$(jq_r '.nodes[0].port')" == 22 ]]
    [[ "$(jq_r '.nodes[0].auth')" == password ]]
    [[ "$(node_secret_get "$NODE_ID")" == hardening-password-canary ]]
    [[ "$SERVER_PORT" == 22 && "$SERVER_AUTH" == password ]]
    [[ "$SERVER_PASS" == hardening-password-canary ]]
}

@test "local password hardening applies and verifies the generated key without system keys" {
    ssh_hardening <<< $'55555\ny' > "$BATS_TEST_TMPDIR/output" 2>&1
    assert_key_recovery_argv
    assert_phase 'verify-key 22'
    assert_phase 'disable 22'
    assert_phase 'apply 22'
    assert_phase 'verify-new 55555'
    [[ "$(jq_r '.nodes[0].port')" == 55555 ]]
    [[ "$(jq_r '.nodes[0].auth')" == key ]]
    [[ "$SERVER_AUTH" == key && -z "$SERVER_PASS" ]]
    [[ -z "$(node_secret_get "$NODE_ID")" ]]
}

@test "failed port apply uses the verified identity to roll back and restore password" {
    export SSH_RECOVERY_FAULT=apply
    if ssh_hardening <<< $'55555\ny' > "$BATS_TEST_TMPDIR/output" 2>&1; then return 1; fi
    assert_key_recovery_argv
    assert_phase 'apply 22'
    assert_phase 'rollback 22'
    assert_phase 'verify-old 22'
    assert_phase 'restore 22'
    assert_original_connection_preserved
}

@test "failed new-port verification recovers through the old port with the verified key" {
    export SSH_RECOVERY_FAULT=verify
    if ssh_hardening <<< $'55555\ny' > "$BATS_TEST_TMPDIR/output" 2>&1; then return 1; fi
    assert_key_recovery_argv
    assert_phase 'verify-new 55555'
    assert_phase 'rollback 22'
    assert_phase 'verify-old 22'
    assert_phase 'restore 22'
    assert_original_connection_preserved
}

@test "rollback fallback on the new port also supplies the generated identity" {
    export SSH_RECOVERY_FAULT=fallback
    if ssh_hardening <<< $'55555\ny' > "$BATS_TEST_TMPDIR/output" 2>&1; then return 1; fi
    assert_key_recovery_argv
    assert_phase 'rollback 22'
    assert_phase 'rollback 55555'
    assert_phase 'verify-old 22'
    assert_phase 'restore 22'
    assert_original_connection_preserved
}

@test "unconfirmed rollback never persists the new port or discards password credentials" {
    export SSH_RECOVERY_FAULT=rollback
    if ssh_hardening <<< $'55555\ny' > "$BATS_TEST_TMPDIR/output" 2>&1; then return 1; fi
    assert_key_recovery_argv
    assert_phase 'rollback 22'
    assert_phase 'rollback 55555'
    assert_phase 'restore 22'
    assert_original_connection_preserved
}
