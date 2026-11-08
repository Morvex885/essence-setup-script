#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module 'nodes.sh'
    override_pass_key
    export STATE_DIR="$BATS_TEST_TMPDIR"
    export STATE_MANIFEST="$STATE_DIR/manifest.json"
    export SECRETS_JSON="$STATE_DIR/secrets.json"
    export SSH_IDENTITIES_DIR="$STATE_DIR/ssh/identities"
    export SSH_KNOWN_HOSTS="$STATE_DIR/ssh/known_hosts"
    export SCRIPT_AUTH_FILE="$STATE_DIR/.auth"
    CONFIG_SOURCE=local
    A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    OUT="$STATE_DIR/portable.json"
    ISSUES="$STATE_DIR/issues.json"
    jq -n --arg a "$A" --arg b "$B" '{schema_version:2,
        nodes:([$a,$b] | map({id:.,name:(if .==$a then "portable-a" else "portable-b" end),
        ip:(if .==$a then "192.0.2.10" else "192.0.2.11" end),port:22,user:"root",
        auth:"password",secret_id:("node:"+.+":ssh-password"),aliases:{}})),
        groups:[],clients:[],connections:[]}' > "$CONFIG_JSON"
    node_secret_set "$A" 'synthetic-good'
    node_secret_set "$B" 'synthetic-other'
    printf '%s\n' '{"schema_version":2,"portability":{"status":"ready","issues":[]}}' > "$STATE_MANIFEST"
}

teardown() { teardown_test_env; }

_set_entry() {
    jq --arg id "node:$B:ssh-password" --argjson value "$1" \
        '.node_passwords[$id]=$value' "$SECRETS_JSON" > "$STATE_DIR/next"
    mv "$STATE_DIR/next" "$SECRETS_JSON"
}

_pin_hosts() {
    ssh-keygen -q -t ed25519 -N '' -f "$STATE_DIR/host-key"
    local public
    public=$(cat "$STATE_DIR/host-key.pub")
    printf '192.0.2.10 %s\n192.0.2.11 %s\n' "$public" "$public" > "$SSH_KNOWN_HOSTS"
}

@test "getter returns exact nonempty plaintext from explicit file" {
    local password=$'  quote" slash\\ Unicode-Ж\r\nlast\n\n' actual
    node_secret_set "$A" "$password"
    cp "$SECRETS_JSON" "$STATE_DIR/copy.json"
    rm "$SECRETS_JSON"
    actual=$(node_secret_get "$A" "$STATE_DIR/copy.json"; rc=$?; printf '.'; exit "$rc")
    [[ "${actual%.}" == "$password" ]]
}

@test "getter returns two with no output for every per-node failure" {
    local value
    for value in 'null' 'false' '42' '{}' '[]' '""' '"not-ciphertext"'; do
        _set_entry "$value"
        run node_secret_get "$B"
        [[ "$status" == 2 && -z "$output" ]]
    done
    node_secret_delete "$B"
    run node_secret_get "$B"
    [[ "$status" == 2 && -z "$output" ]]
    node_secret_set "$B" 'synthetic-other'
    _pass_key() { printf '%s' 'bbbb1111cccc2222dddd3333eeee4444ffff5555aaaa6666aabb7788ccdd99ee'; }
    run node_secret_get "$B"
    [[ "$status" == 2 && -z "$output" ]]
}

@test "getter discards partial decoder output and empty decoded passwords" {
    _state_secret_decode() { printf '%s' 'synthetic-leak'; return 1; }
    run node_secret_get "$A"
    [[ "$status" == 2 && -z "$output" ]]
    _state_secret_decode() { return 0; }
    run node_secret_get "$A"
    [[ "$status" == 2 && -z "$output" ]]
}

@test "getter rejects decoded NUL without exposing a prefix" {
    _state_secret_decode() { printf 'synthetic\000secret'; }
    run node_secret_get "$A"
    [[ "$status" == 2 && -z "$output" ]]
}

@test "getter returns one for missing malformed or unsupported container" {
    local value
    for value in '{' '{}' '[]' '{"schema_version":2,"node_passwords":{}}' \
        '{"schema_version":1,"node_passwords":[]}' \
        '{"schema_version":1,"node_passwords":{}} {}'; do
        printf '%s' "$value" > "$SECRETS_JSON"
        run node_secret_get "$A"
        [[ "$status" == 1 && -z "$output" ]]
    done
    rm "$SECRETS_JSON"
    run node_secret_get "$A"
    [[ "$status" == 1 && -z "$output" ]]
}

@test "getter reports missing required crypto tool as global failure" {
    command() {
        if [[ "$1" == -v && "$2" == openssl ]]; then return 1; fi
        builtin command "$@"
    }
    run node_secret_get "$A"
    [[ "$status" == 1 && -z "$output" ]]
}

@test "partial export preserves source ciphertext and drops orphan and key-auth secrets" {
    _set_entry '"broken-cipher"'
    node_secret_set cccccccccccccccccccccccccccccccc 'orphan-secret'
    cp "$SECRETS_JSON" "$STATE_DIR/original"
    _state_secrets_export_portable "$CONFIG_JSON" "$SECRETS_JSON" "$OUT" "$ISSUES"
    cmp "$STATE_DIR/original" "$SECRETS_JSON"
    jq -e --arg a "node:$A:ssh-password" '.schema_version==2 and
        (.node_passwords|length)==1 and .node_passwords[$a]=="synthetic-good"' "$OUT"
    jq -e --arg b "$B" '.==[{node_id:$b,reason:"missing_secret"}]' "$ISSUES"
    jq '.nodes[0].auth="key" | .nodes[0].secret_id=null' "$CONFIG_JSON" > "$STATE_DIR/next"
    mv "$STATE_DIR/next" "$CONFIG_JSON"
    _state_secrets_export_portable "$CONFIG_JSON" "$SECRETS_JSON" "$OUT" "$ISSUES"
    jq -e '.node_passwords=={}' "$OUT"
    [[ "$(stat -c '%a' "$OUT" 2>/dev/null || stat -f '%Lp' "$OUT")" == 600 &&
       "$(stat -c '%a' "$ISSUES" 2>/dev/null || stat -f '%Lp' "$ISSUES")" == 600 ]]
}

@test "cross-device export import preserves special characters and terminal newlines" {
    local password=$' spaces\t"\\Ж\r\nend\n\n' actual
    node_secret_set "$A" "$password"
    node_secret_delete "$B"
    _state_secrets_export_portable "$CONFIG_JSON" "$SECRETS_JSON" "$OUT" "$ISSUES"
    cp "$OUT" "$STATE_DIR/logical-before"
    _pass_key() { printf '%s' 'bbbb1111cccc2222dddd3333eeee4444ffff5555aaaa6666aabb7788ccdd99ee'; }
    _state_secrets_import_portable "$OUT" "$STATE_DIR/imported"
    actual=$(node_secret_get "$A" "$STATE_DIR/imported"; rc=$?; printf '.'; exit "$rc")
    [[ "${actual%.}" == "$password" ]]
    run node_secret_get "$B" "$STATE_DIR/imported"
    [[ "$status" == 2 && -z "$output" ]]
    jq -e '.schema_version==1' "$STATE_DIR/imported"
    _state_secrets_export_portable "$CONFIG_JSON" "$STATE_DIR/imported" "$OUT" "$ISSUES"
    cmp "$STATE_DIR/logical-before" "$OUT"
    [[ "$(stat -c '%a' "$STATE_DIR/imported" 2>/dev/null || stat -f '%Lp' "$STATE_DIR/imported")" == 600 ]]
}

@test "portable imports reject invalid values including JSON NUL without replacing output" {
    local value
    printf '%s' 'previous-output' > "$STATE_DIR/imported"
    for value in '""' 'null' '23' '"nul\u0000inside"'; do
        jq -n --arg key "node:$A:ssh-password" --argjson value "$value" \
            '{schema_version:2,node_passwords:{($key):$value}}' > "$OUT"
        run _state_secrets_import_portable "$OUT" "$STATE_DIR/imported"
        [[ "$status" == 1 ]]
        [[ "$(cat "$STATE_DIR/imported")" == previous-output ]]
        [[ "$output" != *nul* && "$output" != *inside* ]]
    done
}

@test "conversion global errors leave both export outputs unchanged" {
    printf '%s' 'previous-portable' > "$OUT"
    printf '%s' 'previous-issues' > "$ISSUES"
    printf '%s' '{' > "$SECRETS_JSON"
    run _state_secrets_export_portable "$CONFIG_JSON" "$SECRETS_JSON" "$OUT" "$ISSUES"
    [[ "$status" == 1 ]]
    [[ "$(cat "$OUT")" == previous-portable && "$(cat "$ISSUES")" == previous-issues ]]
}

@test "failed second export write restores the first staging output" {
    printf '%s' 'previous-portable' > "$OUT"
    printf '%s' 'previous-issues' > "$ISSUES"
    _state_write_atomic() {
        [[ "$2" != "$ISSUES" ]] || return 1
        cp "$1" "$2"
    }
    run _state_secrets_export_portable "$CONFIG_JSON" "$SECRETS_JSON" "$OUT" "$ISSUES"
    [[ "$status" == 1 ]]
    [[ "$(cat "$OUT")" == previous-portable && "$(cat "$ISSUES")" == previous-issues ]]
}

@test "openssl encode failure cannot publish imported runtime or change local secret" {
    _state_secrets_export_portable "$CONFIG_JSON" "$SECRETS_JSON" "$OUT" "$ISSUES"
    printf '%s' 'previous-runtime' > "$STATE_DIR/imported"
    cp "$SECRETS_JSON" "$STATE_DIR/original"
    openssl() { return 1; }
    run _state_secrets_import_portable "$OUT" "$STATE_DIR/imported"
    [[ "$status" == 1 && -z "$output" ]]
    [[ "$(cat "$STATE_DIR/imported")" == previous-runtime ]]
    run node_secret_set "$A" 'replacement-synthetic'
    [[ "$status" == 1 ]]
    cmp "$STATE_DIR/original" "$SECRETS_JSON"
}

@test "state fallback crypto preserves CR LF and handles encode pipeline failure" {
    unset -f node_pass_encode node_pass_decode
    local password=$'fallback \r\nЖ\n' actual
    node_secret_set "$A" "$password"
    actual=$(node_secret_get "$A"; rc=$?; printf '.'; exit "$rc")
    [[ "${actual%.}" == "$password" ]]
    cp "$SECRETS_JSON" "$STATE_DIR/original"
    openssl() { return 1; }
    run node_secret_set "$A" 'replacement'
    [[ "$status" == 1 ]]
    cmp "$STATE_DIR/original" "$SECRETS_JSON"
}

@test "password issues are sorted unique and skip key-auth nodes" {
    node_secret_delete "$A"
    node_secret_delete "$B"
    jq '.nodes=[.nodes[1],.nodes[0],.nodes[1]]' "$CONFIG_JSON" > "$STATE_DIR/next"
    mv "$STATE_DIR/next" "$CONFIG_JSON"
    local issues
    issues=$(_state_password_issues "$CONFIG_JSON" "$SECRETS_JSON")
    jq -e --arg a "$A" --arg b "$B" '.==[{node_id:$a,reason:"missing_secret"},
        {node_id:$b,reason:"missing_secret"}]' <<< "$issues"
    jq '.nodes=[]' "$CONFIG_JSON" > "$STATE_DIR/next"
    mv "$STATE_DIR/next" "$CONFIG_JSON"
    [[ "$(_state_password_issues "$CONFIG_JSON" "$SECRETS_JSON")" == '[]' ]]
}

@test "local and portable validation compute missing password readiness without mutating state" {
    _pin_hosts
    _set_entry '"broken-cipher"'
    cp "$SECRETS_JSON" "$STATE_DIR/original"
    cp "$STATE_MANIFEST" "$STATE_DIR/manifest-before"
    run state_validate false
    assert_success
    assert_output needs_setup
    run state_validate true
    assert_success
    assert_output needs_setup
    cmp "$STATE_DIR/original" "$SECRETS_JSON"
    cmp "$STATE_DIR/manifest-before" "$STATE_MANIFEST"
    state_checkpoint
    jq -e --arg b "$B" '.portability=={status:"needs_setup",issues:[{node_id:$b,reason:"missing_secret"}]}' "$STATE_MANIFEST"
    cmp "$STATE_DIR/original" "$SECRETS_JSON"
    node_secret_set "$B" 'repaired-synthetic'
    run state_validate true
    assert_success
    assert_output ready
    state_checkpoint
    jq -e '.portability=={status:"ready",issues:[]}' "$STATE_MANIFEST"
}

@test "checkpoint keeps unrelated issues and local state_action accepts partial readiness" {
    state_portability_add_issue "$A" missing_host_key
    state_action remove_password node_secret_delete "$B"
    jq -e --arg a "$A" --arg b "$B" '.portability.status=="needs_setup" and
        (.portability.issues|length)==2 and
        any(.portability.issues[];.node_id==$a and .reason=="missing_host_key") and
        any(.portability.issues[];.node_id==$b and .reason=="missing_secret")' "$STATE_MANIFEST"
    node_secret_set "$B" 'repaired'
    state_checkpoint
    jq -e --arg a "$A" '.portability.issues==[{node_id:$a,reason:"missing_host_key"}]' "$STATE_MANIFEST"
}

@test "portability issue updates refuse a corrupt manifest without replacing it" {
    printf '%s' '{"schema_version":2,"access":{"script_password_hash":"h"},' > "$STATE_MANIFEST"
    cp "$STATE_MANIFEST" "$STATE_DIR/manifest-before"
    run state_portability_add_issue "$A" missing_host_key
    assert_failure
    run state_portability_remove_issue "$A" missing_host_key
    assert_failure
    run state_portability_remove_node "$A"
    assert_failure
    cmp "$STATE_DIR/manifest-before" "$STATE_MANIFEST"
    run state_portability_set_issues '[]'
    assert_failure
    cmp "$STATE_DIR/manifest-before" "$STATE_MANIFEST"
}

@test "password relaxation does not bypass invalid links containers or resource declarations" {
    node_secret_delete "$B"
    run state_validate true
    assert_failure
    jq '.nodes[1].secret_id="wrong"' "$CONFIG_JSON" > "$STATE_DIR/next"
    mv "$STATE_DIR/next" "$CONFIG_JSON"
    run state_validate false
    assert_failure
    cp "$STATE_MANIFEST" "$STATE_DIR/manifest-before"
    run state_checkpoint
    assert_failure
    cmp "$STATE_DIR/manifest-before" "$STATE_MANIFEST"
    printf '%s' '{' > "$SECRETS_JSON"
    run state_validate false
    assert_failure
}

@test "partial warnings include only affected node names and no secret" {
    node_secret_delete "$B"
    local issues
    issues=$(_state_password_issues "$CONFIG_JSON" "$SECRETS_JSON")
    warn() { printf '%s' "$*"; }
    run _state_warn_missing_passwords "$CONFIG_JSON" "$issues"
    assert_success
    [[ "$output" == *portable-b* && "$output" != *portable-a* && "$output" != *synthetic* ]]
    run _state_warn_missing_passwords "$CONFIG_JSON" '[]'
    [[ "$status" == 0 && -z "$output" ]]
}

@test "AWG guard never discovers connects or mutates using previously loaded node" {
    source_module 'ssh.sh'
    source_module 'awg_peers.sh'
    node_load 1
    node_secret_delete "$B"
    cp "$CONFIG_JSON" "$STATE_DIR/config-before"
    cp "$SECRETS_JSON" "$STATE_DIR/secrets-before"
    cp "$STATE_MANIFEST" "$STATE_DIR/manifest-before"
    local log="$STATE_DIR/operations" rc=0
    : > "$log"
    ssh_run() {
        if [[ "${*: -1}" == "echo ok" ]]; then printf 'connect:%s\n' "$NODE_NAME" >> "$log"; printf 'ok\n'; return 0; fi
        printf 'ssh:%s\n' "$NODE_NAME" >> "$log"; printf '%s' NO_AWG
    }
    upload_scripts() { printf 'upload\n' >> "$log"; }
    _awg_expected_peers() { printf 'peers\n' >> "$log"; }
    core_awg_status "$(jq -r '.nodes[1].name' "$CONFIG_JSON")" || rc=$?
    [[ "$rc" == 1 && "$RC_ERROR_CODE" == missing_secret && ! -s "$log" && "$NODE_ID" == "$A" ]]
    cmp "$STATE_DIR/config-before" "$CONFIG_JSON"
    cmp "$STATE_DIR/secrets-before" "$SECRETS_JSON"
    cmp "$STATE_DIR/manifest-before" "$STATE_MANIFEST"
    core_awg_status "$(jq -r '.nodes[0].name' "$CONFIG_JSON")"
    [[ "$(cat "$log")" == $'connect:portable-a\nssh:portable-a' ]]
}

# ─── security round 1: nodes ───

@test "security: passwords encrypted the old way still decrypt and the key stays out of argv" {
    local key legacy machine_key fresh bin="$BATS_TEST_TMPDIR/argv-bin"
    key=$(_pass_key)
    # Прежний формат: openssl enc -aes-256-cbc -pbkdf2 -k KEY, base64.
    legacy=$(printf '%s' 'legacy-Secret!' | openssl enc -aes-256-cbc -pbkdf2 -k "$key" 2>/dev/null | base64 | tr -d '\n')
    [ "$(node_pass_decode "$legacy")" = 'legacy-Secret!' ]
    # Ранний bootstrap без nodes.sh: ключ из machine-id, тот же формат.
    machine_key=$(printf '%s' "rcm-$(cat /etc/machine-id 2>/dev/null || hostname)" |
        openssl dgst -sha256 -r | cut -d' ' -f1)
    legacy=$(printf '%s' 'bootstrap-Secret!' | openssl enc -aes-256-cbc -pbkdf2 -k "$machine_key" 2>/dev/null | base64 | tr -d '\n')
    [ "$(unset -f node_pass_decode node_pass_encode; _state_secret_decode "$legacy")" = 'bootstrap-Secret!' ]
    fresh=$(unset -f node_pass_decode node_pass_encode; _state_secret_encode 'bootstrap-new')
    [ "$(printf '%s' "$fresh" | base64 -d | openssl enc -aes-256-cbc -d -pbkdf2 -k "$machine_key" 2>/dev/null)" = bootstrap-new ]

    mkdir -p "$bin"
    export ARGV_LOG="$BATS_TEST_TMPDIR/openssl.argv" REAL_OPENSSL
    REAL_OPENSSL=$(command -v openssl)
    cat > "$bin/openssl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$ARGV_LOG"
exec "$REAL_OPENSSL" "$@"
EOF
    chmod +x "$bin/openssl"
    fresh=$(PATH="$bin:$PATH" node_pass_encode 'fresh-Secret!')
    [ "$(PATH="$bin:$PATH" node_pass_decode "$fresh")" = 'fresh-Secret!' ]
    [ "$(printf '%s' "$fresh" | base64 -d | "$REAL_OPENSSL" enc -aes-256-cbc -d -pbkdf2 -k "$key" 2>/dev/null)" = 'fresh-Secret!' ]
    [[ -s "$ARGV_LOG" ]]
    ! grep -qF -- "$key" "$ARGV_LOG" || return 1
}
