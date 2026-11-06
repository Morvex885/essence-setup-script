#!/usr/bin/env bats

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-50}"

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    setup_test_env
    source_common
    source_module 'nodes.sh'
    override_pass_key
    export STATE_DIR="$BATS_TEST_TMPDIR"
    export SECRETS_JSON="$STATE_DIR/secrets.json"
    export STATE_MANIFEST="$STATE_DIR/manifest.json"
    export SSH_IDENTITIES_DIR="$STATE_DIR/ssh/identities"
    export SSH_KNOWN_HOSTS="$STATE_DIR/ssh/known_hosts"
    A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    jq -n --arg a "$A" --arg b "$B" '{schema_version:2,
        nodes:([$a,$b] | map({id:.,name:.,ip:"192.0.2.10",port:22,user:"root",
        auth:"password",secret_id:("node:"+.+":ssh-password")})),
        groups:[],clients:[],connections:[]}' > "$CONFIG_JSON"
    OUT="$STATE_DIR/portable.json"
    ISSUES="$STATE_DIR/issues.json"
    IMPORTED="$STATE_DIR/imported.json"
    RANDOM=1701
}

teardown() { teardown_test_env; }

@test "fuzz portable cross-device roundtrip preserves exact nonempty passwords" {
    local i password actual len charset=$'abcXYZ0123 \t\r\n"\\Ж!?$[]'
    for ((i=0; i<FUZZ_ITERATIONS; i++)); do
        len=$((RANDOM % 100 + 1))
        password=$(random_string "$len" "$charset"; printf '.')
        password="${password%.}"$'\n'
        override_pass_key
        node_secret_set "$A" "$password"
        node_secret_delete "$B"
        _state_secrets_export_portable "$CONFIG_JSON" "$SECRETS_JSON" "$OUT" "$ISSUES"
        _pass_key() { printf '%s' 'bbbb1111cccc2222dddd3333eeee4444ffff5555aaaa6666aabb7788ccdd99ee'; }
        _state_secrets_import_portable "$OUT" "$IMPORTED"
        actual=$(node_secret_get "$A" "$IMPORTED"; rc=$?; printf '.'; exit "$rc")
        [[ "${actual%.}" == "$password" ]] || { echo "Roundtrip mismatch at iteration $i"; return 1; }
        run node_secret_get "$B" "$IMPORTED"
        [[ "$status" == 2 && -z "$output" ]]
    done
}

@test "fuzz one damaged entry cannot change the good entry or original ciphertext" {
    local i password len damage
    for ((i=0; i<FUZZ_ITERATIONS; i++)); do
        len=$((RANDOM % 80 + 1))
        password=$(random_string "$len" 'abcDEF0123456789_-!')
        node_secret_set "$A" "$password"
        case $((RANDOM % 5)) in
            0) damage=null ;;
            1) damage=false ;;
            2) damage='""' ;;
            3) damage='"invalid-ciphertext"' ;;
            4) damage='{}' ;;
        esac
        jq --arg key "node:$B:ssh-password" --argjson damage "$damage" \
            '.node_passwords[$key]=$damage' "$SECRETS_JSON" > "$STATE_DIR/next"
        mv "$STATE_DIR/next" "$SECRETS_JSON"
        cp "$SECRETS_JSON" "$STATE_DIR/before"
        _state_secrets_export_portable "$CONFIG_JSON" "$SECRETS_JSON" "$OUT" "$ISSUES"
        cmp "$STATE_DIR/before" "$SECRETS_JSON"
        printf '%s' "$password" > "$STATE_DIR/expected"
        jq -e --arg a "node:$A:ssh-password" --rawfile expected "$STATE_DIR/expected" \
            '.node_passwords=={($a):$expected}' "$OUT" >/dev/null
        jq -e --arg b "$B" '.==[{node_id:$b,reason:"missing_secret"}]' "$ISSUES" >/dev/null
    done
}

@test "fuzz malformed containers never replace staging outputs" {
    local i value
    for ((i=0; i<FUZZ_ITERATIONS; i++)); do
        case $((RANDOM % 6)) in
            0) value='{"schema_version":7,"node_passwords":{}}' ;;
            1) value='{"schema_version":1,"node_passwords":[]}' ;;
            2) value='{"schema_version":1}' ;;
            3) value='{"node_passwords":{}}' ;;
            4) value='{"schema_version":1,"node_passwords":{}} {}' ;;
            5) value='{' ;;
        esac
        printf '%s' "$value" > "$SECRETS_JSON"
        printf 'portable-%s' "$i" > "$OUT"
        printf 'issues-%s' "$i" > "$ISSUES"
        run _state_secrets_export_portable "$CONFIG_JSON" "$SECRETS_JSON" "$OUT" "$ISSUES"
        [[ "$status" == 1 ]]
        [[ "$(cat "$OUT")" == "portable-$i" && "$(cat "$ISSUES")" == "issues-$i" ]]
        printf 'runtime-%s' "$i" > "$IMPORTED"
        run _state_secrets_import_portable "$SECRETS_JSON" "$IMPORTED"
        [[ "$status" == 1 && "$(cat "$IMPORTED")" == "runtime-$i" ]]
    done
}
