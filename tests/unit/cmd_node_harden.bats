#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    load '../helpers/cmd_helper'
    # Keep the real option builder, askpass handling and ssh invocation. Only
    # the transport binary is replaced; no network or accepted system key exists.
    load_core
    state_open_local
    RC_SESSION_OPEN=1 RC_SESSION_AUTHORIZED=1
    export CONFIG_SOURCE=local NODE_NAME=local-password NODE_ID=0123456789abcdef0123456789abcdef
    export NODE_IDENTITY=system SERVER_IP=192.0.2.10 SERVER_PORT=22 SERVER_USER=root
    export SERVER_AUTH=password SERVER_PASS='hardening-password-canary'
    export SSH_IDENTITIES_DIR="$CONFIG_DIR/identities with spaces"
    export SSH_ARGV_DIR="$BATS_TEST_TMPDIR/argv" SSH_RECOVERY_FAULT=none
    export SSH_AUTH_SOCK= HOME="$BATS_TEST_TMPDIR/empty-home"
    unset SSH_ASKPASS SSH_ASKPASS_REQUIRE
    mkdir -p "$SSH_IDENTITIES_DIR" "$SSH_ARGV_DIR" "$HOME" "$BATS_TEST_TMPDIR/bin"
    cat > "$CONFIG_JSON" <<'EOF'
{"schema_version":2,"nodes":[{"id":"0123456789abcdef0123456789abcdef","name":"local-password","ip":"192.0.2.10","port":22,"user":"root","auth":"password","identity":"system","secret_id":"node:0123456789abcdef0123456789abcdef:ssh-password"}],"groups":[],"clients":[],"connections":[]}
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
        --) shift ;;
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
    fallback:rollback:22 | rollback:rollback:* | select:select:*) exit 1 ;;
esac
[[ "$phase" != select ]] || printf '%s\n' "${SSH_PORT_STATE:-free}"
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

# node harden через ядро; журнал — в $BATS_TEST_TMPDIR/output.
harden() {
    run_cmd node harden --name local-password --port 55555 --yes
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/output"
    [ "$status" -eq 0 ]
}

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
            [[ "$identity" == "$CONFIG_DIR"/.identity.*/"$NODE_ID" ]]
        else
            [[ "$identity" == "$SSH_IDENTITIES_DIR/$NODE_ID" ]]
        fi
    done
    [[ "$(cat "$BATS_TEST_TMPDIR/output")" != *hardening-password-canary* ]]
    local private
    private=$(cat "$SSH_IDENTITIES_DIR/$NODE_ID")
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

# Reject only the final publication of one sandbox state file. Key installation,
# JSON updates and all other filesystem operations still use the real binary.
reject_hardening_state_promotion() {
    HARDENING_REAL_MV=$(command -v mv)
    HARDENING_REJECT_TARGET="$1"
    mv() {
        if [[ "$#" == 2 && "$1" == "$HARDENING_REJECT_TARGET".tmp.* &&
              "$2" == "$HARDENING_REJECT_TARGET" ]]; then
            printf '%s\n' "$2" >> "$BATS_TEST_TMPDIR/rejected-promotions"
            return 77
        fi
        "$HARDENING_REAL_MV" "$@"
    }
}

assert_no_hardening_phase() {
    local unwanted="$1" file actual
    for file in "$SSH_ARGV_DIR/"*.phase; do
        actual=$(cat "$file")
        [[ "$actual" != "$unwanted "* ]] || return 1
    done
}

assert_retained_portable_identity() {
    [[ "$(jq_r '.nodes[0].identity')" == "$NODE_ID" ]]
    [[ "$NODE_IDENTITY" == "$NODE_ID" ]]
    [[ -s "$SSH_IDENTITIES_DIR/$NODE_ID" && -s "$SSH_IDENTITIES_DIR/$NODE_ID.pub" ]]
    local key_type key_value comment derived derived_type derived_value
    read -r key_type key_value comment < "$SSH_IDENTITIES_DIR/$NODE_ID.pub"
    derived=$(ssh-keygen -y -f "$SSH_IDENTITIES_DIR/$NODE_ID") || return 1
    read -r derived_type derived_value comment <<< "$derived"
    [[ "$derived_type" == "$key_type" && "$derived_value" == "$key_value" ]]
}

@test "local password hardening applies and verifies the generated key without system keys" {
    harden
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
    if harden; then return 1; fi
    [ "$(cmd_jq '.error.code')" = hardening_failed ]
    cmd_jq '.error | .stage == "port" and .rolled_back == true and .console_required == false' | grep -qx true
    assert_key_recovery_argv
    assert_phase 'apply 22'
    assert_phase 'rollback 22'
    assert_phase 'verify-old 22'
    assert_phase 'restore 22'
    assert_original_connection_preserved
}

@test "failed new-port verification recovers through the old port with the verified key" {
    export SSH_RECOVERY_FAULT=verify
    if harden; then return 1; fi
    cmd_jq '.error | .stage == "verify" and .rolled_back == true' | grep -qx true
    assert_key_recovery_argv
    assert_phase 'verify-new 55555'
    assert_phase 'rollback 22'
    assert_phase 'verify-old 22'
    assert_phase 'restore 22'
    assert_original_connection_preserved
}

@test "rollback fallback on the new port also supplies the generated identity" {
    export SSH_RECOVERY_FAULT=fallback
    if harden; then return 1; fi
    assert_key_recovery_argv
    assert_phase 'rollback 22'
    assert_phase 'rollback 55555'
    assert_phase 'verify-old 22'
    assert_phase 'restore 22'
    assert_original_connection_preserved
}

@test "unconfirmed rollback never persists the new port or discards password credentials" {
    export SSH_RECOVERY_FAULT=rollback
    if harden; then return 1; fi
    cmd_jq '.error | .rolled_back == false and .console_required == true' | grep -qx true
    assert_key_recovery_argv
    assert_phase 'rollback 22'
    assert_phase 'rollback 55555'
    assert_phase 'restore 22'
    assert_original_connection_preserved
}

@test "late secret deletion failure retains committed key access and never restores password or port" {
    cp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    reject_hardening_state_promotion "$SECRETS_JSON"

    if harden; then return 1; fi
    cmd_jq '.error.stage == "secret_delete"' | grep -qx true

    [[ "$(cat "$BATS_TEST_TMPDIR/rejected-promotions")" == "$SECRETS_JSON" ]]
    assert_phase 'verify-key 22'
    assert_phase 'disable 22'
    assert_phase 'apply 22'
    assert_phase 'verify-new 55555'
    assert_no_hardening_phase restore
    assert_no_hardening_phase rollback
    assert_key_recovery_argv
    assert_retained_portable_identity
    [[ "$(jq_r '.nodes[0].port')" == 55555 ]]
    [[ "$(jq_r '.nodes[0].auth')" == key ]]
    [[ "$(jq_r '.nodes[0].secret_id')" == null ]]
    [[ "$SERVER_PORT" == 55555 && "$SERVER_AUTH" == key && -z "$SERVER_PASS" ]]
    cmp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    [[ "$(node_secret_get "$NODE_ID")" == hardening-password-canary ]]
    [ "$(cmd_jq '.ok')" = false ]
}

@test "late identity checkpoint failure retains the published key and stops before disabling password or changing port" {
    cp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    cp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    reject_hardening_state_promotion "$STATE_MANIFEST"

    if harden; then return 1; fi
    cmd_jq '.error.stage == "key"' | grep -qx true

    [[ "$(cat "$BATS_TEST_TMPDIR/rejected-promotions")" == "$STATE_MANIFEST" ]]
    assert_phase 'install 22'
    assert_phase 'verify-key 22'
    assert_no_hardening_phase disable
    assert_no_hardening_phase apply
    assert_no_hardening_phase verify-new
    assert_no_hardening_phase restore
    assert_no_hardening_phase rollback
    assert_key_recovery_argv
    assert_retained_portable_identity
    assert_original_connection_preserved
    [[ "$(jq_r '.nodes[0].secret_id')" == "node:$NODE_ID:ssh-password" ]]
    cmp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    cmp "$SECRETS_JSON" "$BATS_TEST_TMPDIR/secrets.before"
    [ "$(cmd_jq '.ok')" = false ]
}

_write_github_known_hosts() {
    export CONFIG_SOURCE=github SSH_KNOWN_HOSTS="$BATS_TEST_TMPDIR/known_hosts"
    ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/hostkey"
    printf '192.0.2.10 %s\n' "$(cut -d ' ' -f 1-2 "$BATS_TEST_TMPDIR/hostkey.pub")" \
        > "$SSH_KNOWN_HOSTS"
    cp "$SSH_KNOWN_HOSTS" "$BATS_TEST_TMPDIR/known.before"
}

@test "GitHub hardening trusts the new port only with the already pinned host key" {
    _write_github_known_hosts
    _harden_trust_new_port 22 55555
    ssh-keygen -F '[192.0.2.10]:55555' -f "$SSH_KNOWN_HOSTS" |
        command grep -qF "$(cut -d ' ' -f 2 "$BATS_TEST_TMPDIR/hostkey.pub")"

    cp "$BATS_TEST_TMPDIR/known.before" "$SSH_KNOWN_HOSTS"
    export SERVER_IP=198.51.100.7
    if _harden_trust_new_port 22 55555; then return 1; fi
    cmp "$SSH_KNOWN_HOSTS" "$BATS_TEST_TMPDIR/known.before"
}

@test "GitHub hardening keeps @revoked and @cert-authority markers for the new port" {
    _write_github_known_hosts
    local key ca
    key=$(cut -d ' ' -f 1-2 "$BATS_TEST_TMPDIR/hostkey.pub")
    ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/ca"
    ca=$(cut -d ' ' -f 1-2 "$BATS_TEST_TMPDIR/ca.pub")
    printf '@revoked 192.0.2.10 %s\n@cert-authority 192.0.2.10 %s\n' "$key" "$ca" >> "$SSH_KNOWN_HOSTS"
    _harden_trust_new_port 22 55555
    command grep -qxF "[192.0.2.10]:55555 $key" "$SSH_KNOWN_HOSTS" || return 1
    command grep -qxF "@revoked [192.0.2.10]:55555 $key" "$SSH_KNOWN_HOSTS" || return 1
    command grep -qxF "@cert-authority [192.0.2.10]:55555 $ca" "$SSH_KNOWN_HOSTS" || return 1

    printf '@cert-authority 192.0.2.10 %s\n' "$ca" > "$SSH_KNOWN_HOSTS"
    _harden_trust_new_port 22 55555
    command grep -qxF "@cert-authority [192.0.2.10]:55555 $ca" "$SSH_KNOWN_HOSTS"
}

@test "GitHub hardening save failure rolls back the port and restores known_hosts" {
    _write_github_known_hosts
    _harden_ssh_run() {
        ssh-keygen -F '[192.0.2.10]:55555' -f "$SSH_KNOWN_HOSTS" >/dev/null || return 1
        [[ "$1" != "echo ok" ]] || printf 'ok\n'
    }
    _harden_rollback_port() { touch "$BATS_TEST_TMPDIR/rolled-back"; }
    jq_w() { touch "$BATS_TEST_TMPDIR/jq-w-called"; return 1; }

    if _harden_change_port 55555 > "$BATS_TEST_TMPDIR/output" 2>&1; then return 1; fi
    [[ -e "$BATS_TEST_TMPDIR/jq-w-called" ]] || return 1
    [[ -e "$BATS_TEST_TMPDIR/rolled-back" && "$SERVER_PORT" == 22 ]]
    cmp "$SSH_KNOWN_HOSTS" "$BATS_TEST_TMPDIR/known.before"
}

@test "node harden without --yes returns the plan with the port and changes nothing remote" {
    local before
    before=$(jq -S . "$CONFIG_JSON")
    run_cmd node harden --name local-password --port 55555
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [ "$(cmd_jq '.error.port')" = 55555 ]
    cmd_jq '.error.plan | any(. == "Порт: 22 → 55555")' | grep -qx true
    [[ "$(cmd_jq '.error.plan_token')" =~ ^[0-9a-f]{16}$ ]]
    assert_phase 'select 22'
    assert_no_hardening_phase install
    assert_no_hardening_phase disable
    [ "$(jq -S . "$CONFIG_JSON")" = "$before" ]
}

@test "node harden without --port picks a free random port into the plan" {
    run_cmd node harden --name local-password
    [ "$status" -eq 2 ]
    local port
    port=$(cmd_jq '.error.port')
    (( port >= 49152 && port <= 65535 ))
}

@test "node harden reports port_in_use, invalid ports and SSH failure before any change" {
    SSH_PORT_STATE=occupied run_cmd node harden --name local-password --port 2222
    [ "$(cmd_jq '.error.code')" = port_in_use ]
    [ "$(cmd_jq '.error.port')" = 2222 ]
    run_cmd node harden --name local-password --port 70000
    [ "$(cmd_jq '.error.code')" = invalid ]
    SSH_RECOVERY_FAULT=select run_cmd node harden --name local-password --port 2222
    [ "$(cmd_jq '.error.code')" = remote_failed ]
    run_cmd node harden --name missing
    [ "$(cmd_jq '.error.code')" = not_found ]
    assert_no_hardening_phase install
    [[ "$(jq_r '.nodes[0].port')" == 22 ]]
}

@test "node harden with a stale plan token answers plan_changed and changes nothing" {
    run_cmd node harden --name local-password --port 55555 --yes --plan-token 0000000000000000
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = plan_changed ]
    assert_no_hardening_phase install
    [[ "$(jq_r '.nodes[0].auth')" == password ]]
}

# ─── security round 1: nodes ───

@test "security: every hardening ssh call ends options with -- before the destination" {
    harden
    local file arg previous count=0
    for file in "$SSH_ARGV_DIR/"*.argv; do
        previous=
        while IFS= read -r -d '' arg; do
            if [[ "$arg" == root@192.0.2.10 ]]; then
                [[ "$previous" == -- ]] || { echo "без --: $file"; return 1; }
                count=$((count + 1))
            fi
            previous="$arg"
        done < "$file"
    done
    (( count > 0 ))
    # Прямой ssh проверки ключа из hardening.sh тоже среди вызовов.
    assert_phase "verify-key 22"
}
