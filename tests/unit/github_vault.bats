#!/usr/bin/env bats
BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-30}"

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module 'github-config.sh'
    printf '{"node_passwords":{}}\n' > "$CONFIG_DIR/secrets.json"
    printf '{"vault_version":1,"portability":{"status":"ready","issues":[]},"access":{"script_password_hash":null},"templates":{}}\n' > "$CONFIG_DIR/manifest.json"
    export SECRETS_JSON="$CONFIG_DIR/secrets.json" STATE_MANIFEST="$CONFIG_DIR/manifest.json"
}
teardown() { teardown_test_env; }

_file_mode() {
    case "${OSTYPE:-}" in
        darwin*) stat -f '%Lp' "$1" ;;
        *) stat -c '%a' "$1" ;;
    esac
}

_write_valid_logical_state() {
    jq -n '{
      vault_version:1,
      minimum_remote_control_version:"0.0.0",
      portability:{status:"ready",issues:[]},
      access:{script_password_hash:null},
      config:{schema_version:2,nodes:[],groups:[],clients:[],connections:[]},
      secrets:{schema_version:1,node_passwords:{}},
      templates:{"default.yaml":{content:"mode: rule\n"}},
      ssh:{known_hosts:"host-key\n",identities:{}}
    }' > "$1"
}

_assert_prior_plain_tree() {
    [[ "$(cat "$GITHUB_WORKTREE/config.json")" == "prior-config" ]] || return 1
    [[ "$(cat "$GITHUB_WORKTREE/secrets.json")" == "prior-secrets" ]] || return 1
    [[ "$(cat "$GITHUB_WORKTREE/manifest.json")" == "prior-manifest" ]] || return 1
    [[ "$(cat "$GITHUB_WORKTREE/ssh/known_hosts")" == "prior-known-host" ]] || return 1
    [[ "$(cat "$GITHUB_WORKTREE/templates/prior.yaml")" == "prior-template" ]] || return 1
    [[ "$(cat "$GITHUB_WORKTREE/ssh/identities/00000000000000000000000000000000")" == "prior-identity" ]] || return 1
}

_prepare_plain_worktree() {
    export GITHUB_WORKTREE="$CONFIG_DIR/worktree" GITHUB_STORAGE_MODE=none
    mkdir -p "$GITHUB_WORKTREE" || return 1
    _write_valid_logical_state "$CONFIG_DIR/state.json" || return 1
    github_config_checkpoint "$CONFIG_DIR/state.json" || return 1
}

_configure_managed_recovery_roots() {
    CONFIG_DIR="$BATS_TEST_TMPDIR/managed"
    CONFIG_JSON="$CONFIG_DIR/config.json"
    GITHUB_STORE="$CONFIG_DIR/github-store.git"
    GITHUB_SESSIONS_DIR="$CONFIG_DIR/github-sessions"
    GITHUB_CREDENTIALS_DIR="$CONFIG_DIR/credentials"
    GITHUB_UNLOCK_FILE="$GITHUB_CREDENTIALS_DIR/github-config.agekey"
    GITHUB_WORKTREE="$CONFIG_DIR/github-sessions/session/worktree"
    STATE_DIR="$CONFIG_DIR/runtime"
    SECRETS_JSON="$STATE_DIR/secrets.json"
    STATE_MANIFEST="$STATE_DIR/manifest.json"
    TEMPLATES_DIR="$STATE_DIR/templates"
    SSH_IDENTITIES_DIR="$STATE_DIR/ssh/identities"
    SSH_KNOWN_HOSTS="$STATE_DIR/ssh/known_hosts"
    mkdir -p "$CONFIG_DIR" || return 1
}

_assert_diagnostic_field_redacted() {
    local field="$1" payload="$2" selected raw
    shift 2
    case "$field" in
        stage)
            _github_record_error "$payload" "safe detail"
            selected="$GITHUB_LAST_STAGE"
            ;;
        detail)
            _github_record_error "safe stage" "$payload"
            selected="$GITHUB_LAST_ERROR"
            ;;
        hint)
            _github_record_error "safe stage" "safe detail" false "$payload"
            selected="$GITHUB_LAST_HINT"
            ;;
        *) return 1 ;;
    esac
    [[ "${#selected}" -le 500 ]] || return 1
    run _github_report_last_error "failed"
    assert_success
    for raw in "$@"; do
        [[ "$selected $output" != *"$raw"* ]] || return 1
    done
    [[ "${#output}" -le 1200 ]] || return 1
    [[ "$output" == *"[скрыто]"* ]]
}


@test "storage mode prompt requires an explicit choice" {
    run "${BASH:-bash}" -c "source '$PROJECT_ROOT/common/common.sh'; source '$PROJECT_ROOT/remote-control/modules/github-config.sh'; printf 'x\n2\n' | _github_prompt_storage_mode"
    assert_success
    [[ "$output" == *$'\033[0;32m1)\033[0m Зашифровать паролем'* ]] || return 1
    [[ "$output" == *$'\033[0;36m2)\033[0m Хранить без шифрования'* ]]
}


@test "source metadata validator enforces the GitHub contract" {
    local valid="$BATS_TEST_TMPDIR/source.json"
    printf '%s\n' '{"type":"github","repo":"owner/repo","branch":"main","private_verified":true}' > "$valid"
    run github_source_metadata_valid "$valid"
    assert_success

    printf '%s\n' '{"type":"github","repo":"owner/repo","branch":"","private_verified":true}' > "$valid"
    run github_source_metadata_valid "$valid"
    assert_failure

    printf '%s\n' '{"type":"github","repo":"owner/repo","branch":"main","private_verified":false}' > "$valid"
    run github_source_metadata_valid "$valid"
    assert_failure

    printf '%s\n' '{"type":"github","repo":"owner/repo/extra","branch":"main","private_verified":true}' > "$valid"
    run github_source_metadata_valid "$valid"
    assert_failure
}

@test "legacy local source marker validator accepts only the exact marker" {
    local marker="$BATS_TEST_TMPDIR/source.json"
    printf '%s\n' '{"type":"local"}' > "$marker"
    run legacy_local_source_metadata_valid "$marker"
    assert_success

    printf '%s\n' '{"type":"local","repo":"owner/repo"}' > "$marker"
    run legacy_local_source_metadata_valid "$marker"
    assert_failure
}
@test "plaintext serializer writes exact core tree and validates round trip" {
    export GITHUB_WORKTREE="$CONFIG_DIR/worktree" GITHUB_STORAGE_MODE=none
    mkdir -p "$GITHUB_WORKTREE"
    git -C "$GITHUB_WORKTREE" init >/dev/null
    printf '{"vault_version":1,"minimum_remote_control_version":"0.0.0","portability":{"status":"ready","issues":[]},"access":{"script_password_hash":null},"config":{"nodes":[],"groups":[],"clients":[],"connections":[]},"secrets":{"node_passwords":{}},"templates":{},"ssh":{"identities":{},"known_hosts":""}}\n' > "$CONFIG_DIR/state.json"
    run github_config_checkpoint "$CONFIG_DIR/state.json"
    assert_success
    [[ -f "$GITHUB_WORKTREE/storage.json" ]] || return 1
    [[ -f "$GITHUB_WORKTREE/config.json" ]] || return 1
    run github_config_open "$GITHUB_WORKTREE" "$CONFIG_DIR/open.json"
    assert_success
    run jq -r '.config.nodes|length' "$CONFIG_DIR/open.json"
    assert_output '0'
}

@test "plaintext validation rejects malformed state" {
    export GITHUB_WORKTREE="$CONFIG_DIR/worktree" GITHUB_STORAGE_MODE=none
    mkdir -p "$GITHUB_WORKTREE"
    printf '{"storage_version":1,"encryption":"none"}\n' > "$GITHUB_WORKTREE/storage.json"
    printf '{"nodes":[]}' > "$GITHUB_WORKTREE/config.json"
    printf '{"node_passwords":{}}' > "$GITHUB_WORKTREE/secrets.json"
    printf '{}' > "$GITHUB_WORKTREE/manifest.json"
    run github_config_open "$GITHUB_WORKTREE" "$CONFIG_DIR/open.json"
    assert_failure
}

@test "plaintext write preserves the complete prior tree for invalid keys" {
    export GITHUB_WORKTREE="$CONFIG_DIR/worktree" GITHUB_STORAGE_MODE=none
    mkdir -p "$GITHUB_WORKTREE/templates" "$GITHUB_WORKTREE/ssh/identities"
    printf prior-config > "$GITHUB_WORKTREE/config.json"
    printf prior-secrets > "$GITHUB_WORKTREE/secrets.json"
    printf prior-manifest > "$GITHUB_WORKTREE/manifest.json"
    printf prior-known-host > "$GITHUB_WORKTREE/ssh/known_hosts"
    printf prior-template > "$GITHUB_WORKTREE/templates/prior.yaml"
    printf prior-identity > "$GITHUB_WORKTREE/ssh/identities/00000000000000000000000000000000"
    local state="$CONFIG_DIR/invalid-state.json"
    _write_valid_logical_state "$state"

    jq '.templates={"../invalid.yaml":{content:"bad"}}' "$state" > "$state.tmp" &&
        mv "$state.tmp" "$state"
    run _github_plain_write "$state"
    assert_failure
    _assert_prior_plain_tree || return 1

    _write_valid_logical_state "$state"
    jq '.ssh.identities={"../invalid":{private:"private",public:"public"}}' \
        "$state" > "$state.tmp" && mv "$state.tmp" "$state"
    run _github_plain_write "$state"
    assert_failure
    _assert_prior_plain_tree
}

@test "config close removes ephemeral age identity but keeps remembered identity" {
    local ephemeral="$CONFIG_DIR/.unlock-check.test"
    printf identity > "$ephemeral"
    GITHUB_IDENTITY="$ephemeral"
    github_config_close
    [[ ! -e "$ephemeral" ]] || return 1

    mkdir -p "$(dirname "$GITHUB_UNLOCK_FILE")"
    printf remembered > "$GITHUB_UNLOCK_FILE"
    GITHUB_IDENTITY="$GITHUB_UNLOCK_FILE"
    github_config_close
    [[ -f "$GITHUB_UNLOCK_FILE" ]]
}

@test "failed unlock preserves the caller identity and does not delete its file" {
    local identity="$BATS_TEST_TMPDIR/caller-identity"
    local age="$BATS_TEST_TMPDIR/age-fail" keygen="$BATS_TEST_TMPDIR/age-keygen-ok"
    local rc=0
    printf 'AGE-SECRET-KEY-CALLER\n' > "$identity" || return 1
    chmod 600 "$identity" || return 1
    cat > "$keygen" <<'EOF'
#!/bin/bash
[[ "$1" == -y && -f "${2:-}" ]]
EOF
    cat > "$age" <<'EOF'
#!/bin/bash
exit 74
EOF
    chmod +x "$keygen" "$age" || return 1
    mkdir -p "$CONFIG_DIR/worktree" || return 1
    printf 'encrypted-unlock\n' > "$CONFIG_DIR/worktree/unlock.age" || return 1
    GITHUB_WORKTREE="$CONFIG_DIR/worktree"
    GITHUB_IDENTITY="$identity"
    AGE_KEYGEN_BIN="$keygen"
    AGE_BIN="$age"
    github_config_unlock </dev/null || rc=$?
    [[ "$rc" -ne 0 ]] || return 1
    [[ "$GITHUB_IDENTITY" == "$identity" ]] || return 1
    [[ "$(cat "$identity")" == AGE-SECRET-KEY-CALLER ]]
}

@test "remember and forget unlock use private local credentials" {
    local identity="$CONFIG_DIR/id"
    printf 'AGE-SECRET-KEY-TEST\n' > "$identity"
    github_config_remember "$identity"
    [[ -f "$GITHUB_UNLOCK_FILE" ]] || return 1
    [[ "$(_file_mode "$GITHUB_UNLOCK_FILE")" == 600 ]] || return 1
    github_config_forget
    [[ ! -e "$GITHUB_UNLOCK_FILE" ]]
}

@test "local diagnostic does not probe GitHub auth or show an auth hint" {
    local gh_calls="$BATS_TEST_TMPDIR/gh-auth-calls"
    local fake_gh="$BATS_TEST_TMPDIR/gh"
    cat > "$fake_gh" <<EOF
#!/bin/bash
touch "$gh_calls"
printf '%s\n' 'not logged in to github.com' >&2
exit 1
EOF
    chmod +x "$fake_gh"
    export GH_BIN="$fake_gh"

    _github_clear_error
    _github_record_error "подготовка конфигурации к отправке" "serialize failed"
    run _github_should_show_auth_hint
    assert_failure
    [[ "$GITHUB_LAST_AUTH_RELEVANT" == false ]] || return 1
    [[ ! -e "$gh_calls" ]]
}

@test "recovery export and import accept a valid key outside managed roots" {
    _configure_managed_recovery_roots
    local external="$BATS_TEST_TMPDIR/external"
    local identity="$external/identity" exported="$external/recovery.key"
    local age_keygen="$external/age-keygen" marker="$external/keygen.calls"
    mkdir -p "$external" || return 1
    printf 'AGE-SECRET-KEY-TEST\n' > "$identity" || return 1
    cat > "$age_keygen" <<'EOF'
#!/bin/bash
[[ "$1" == -y && "$(cat "${2:-}")" == AGE-SECRET-KEY-TEST ]] || exit 1
printf 'called\n' >> "$RECOVERY_KEYGEN_MARKER"
printf 'age1testrecipient\n'
EOF
    chmod +x "$age_keygen" || return 1
    export AGE_KEYGEN_BIN="$age_keygen" RECOVERY_KEYGEN_MARKER="$marker"
    GITHUB_IDENTITY="$identity"

    github_config_export_recovery "$exported" || return 1
    [[ "$(cat "$exported")" == "AGE-SECRET-KEY-TEST" ]] || return 1
    [[ "$(_file_mode "$exported")" == 600 ]] || return 1
    rm -f "$marker" || return 1

    github_config_import_recovery "$exported" || return 1
    [[ "$GITHUB_IDENTITY" != "$identity" ]] || return 1
    [[ "$(cat "$GITHUB_IDENTITY")" == "AGE-SECRET-KEY-TEST" ]] || return 1
    [[ "$(_file_mode "$GITHUB_IDENTITY")" == 600 ]] || return 1
    [[ "$(cat "$marker")" == called ]] || return 1
}

@test "recovery boundaries reject managed aliases before keygen and preserve destinations" {
    _configure_managed_recovery_roots
    local external="$BATS_TEST_TMPDIR/external"
    local valid_identity="$external/identity" key="$CONFIG_DIR/recovery.key"
    local alias_dir="$BATS_TEST_TMPDIR/config-alias"
    local marker="$external/keygen.calls" fake="$external/age-keygen"
    local export_target="$external/export-target" export_alias="$external/export-link"
    local config_before target_before config_mode target_mode imported failures=0
    mkdir -p "$external" || return 1
    printf 'AGE-SECRET-KEY-TEST\n' > "$valid_identity" || return 1
    printf 'AGE-SECRET-KEY-TEST\n' > "$key" || return 1
    cat > "$fake" <<'EOF'
#!/bin/bash
[[ "$1" == -y && "$(cat "${2:-}")" == AGE-SECRET-KEY-TEST ]] || exit 1
printf 'called\n' >> "$RECOVERY_KEYGEN_MARKER"
printf 'age1testrecipient\n'
EOF
    chmod +x "$fake" || return 1
    export AGE_KEYGEN_BIN="$fake" RECOVERY_KEYGEN_MARKER="$marker"
    GITHUB_IDENTITY="$valid_identity"

    rm -f "$marker" || return 1
    if github_config_import_recovery "$key"; then failures=$((failures + 1)); fi
    [[ ! -e "$marker" ]] || failures=$((failures + 1))
    imported="${GITHUB_IDENTITY:-}"
    [[ "$imported" == "$valid_identity" ]] || failures=$((failures + 1))
    [[ "$imported" == "$valid_identity" ]] || rm -f "$imported"
    GITHUB_IDENTITY="$valid_identity"

    ln -s "$CONFIG_DIR" "$alias_dir" || return 1
    rm -f "$marker" || return 1
    if github_config_import_recovery "$alias_dir/recovery.key"; then
        failures=$((failures + 1))
    fi
    [[ ! -e "$marker" ]] || failures=$((failures + 1))
    imported="${GITHUB_IDENTITY:-}"
    [[ "$imported" == "$valid_identity" ]] || failures=$((failures + 1))
    [[ "$imported" == "$valid_identity" ]] || rm -f "$imported"
    GITHUB_IDENTITY="$valid_identity"

    printf 'external-target-original\n' > "$export_target" || return 1
    chmod 640 "$export_target" || return 1
    ln -s "$export_target" "$export_alias" || return 1
    target_before=$(cat "$export_target") || return 1
    target_mode=$(_file_mode "$export_target") || return 1
    if github_config_export_recovery "$export_alias"; then failures=$((failures + 1)); fi
    [[ -L "$export_alias" ]] || failures=$((failures + 1))
    [[ "$(cat "$export_target")" == "$target_before" ]] || failures=$((failures + 1))
    [[ "$(_file_mode "$export_target")" == "$target_mode" ]] || failures=$((failures + 1))

    printf '{"schema_version":2,"marker":"config-original"}\n' > "$CONFIG_JSON" || return 1
    chmod 640 "$CONFIG_JSON" || return 1
    config_before=$(cat "$CONFIG_JSON") || return 1
    config_mode=$(_file_mode "$CONFIG_JSON") || return 1
    if github_config_export_recovery "$CONFIG_JSON"; then failures=$((failures + 1)); fi
    [[ "$(cat "$CONFIG_JSON")" == "$config_before" ]] || failures=$((failures + 1))
    [[ "$(_file_mode "$CONFIG_JSON")" == "$config_mode" ]] || failures=$((failures + 1))

    [[ "$failures" -eq 0 ]]
}

@test "jq_w reports detailed persistence errors and generic fallback" {
    CONFIG_JSON="$BATS_TEST_TMPDIR/config.json"
    printf '{"value":1}\n' > "$CONFIG_JSON"
    CONFIG_SOURCE=github
    config_persist_candidate() {
        if [[ "${PERSIST_ERROR_MODE:-detailed}" == detailed ]]; then
            CONFIG_PERSIST_LAST_ERROR="Не удалось зафиксировать кандидат."
        fi
        return 1
    }

    run jq_w '.value=2'
    assert_failure
    assert_output --partial "Не удалось зафиксировать кандидат."

    PERSIST_ERROR_MODE=generic
    run jq_w '.value=3'
    assert_failure
    assert_output --partial "Не удалось сохранить представление конфига"
}

@test "open rejects a tracked symlink before reading its target" {
    _prepare_plain_worktree
    local outside="$BATS_TEST_TMPDIR/outside-template" out="$CONFIG_DIR/open.json"
    printf 'EXTERNAL-TEMPLATE-MUST-NOT-BE-READ\n' > "$outside" || return 1
    printf 'prior-open-output\n' > "$out" || return 1
    chmod 600 "$out" || return 1
    rm "$GITHUB_WORKTREE/templates/default.yaml" || return 1
    ln -s "$outside" "$GITHUB_WORKTREE/templates/default.yaml" || return 1
    git -C "$GITHUB_WORKTREE" init -q || return 1
    git -C "$GITHUB_WORKTREE" add templates/default.yaml || return 1

    run github_config_open "$GITHUB_WORKTREE" "$out"
    assert_failure
    [ "$status" -eq 1 ]
    [[ "$(cat "$outside")" == "EXTERNAL-TEMPLATE-MUST-NOT-BE-READ" ]] || return 1
    [[ "$(cat "$out")" == "prior-open-output" ]] || return 1
    ! grep -Fq 'EXTERNAL-TEMPLATE-MUST-NOT-BE-READ' "$out" || return 1
}

@test "checkpoint rejects an untracked symlink without replacing it or its target" {
    _prepare_plain_worktree
    local outside="$BATS_TEST_TMPDIR/outside-template"
    printf 'EXTERNAL-TARGET-UNCHANGED\n' > "$outside" || return 1
    ln -s "$outside" "$GITHUB_WORKTREE/templates/untracked.yaml" || return 1

    run github_config_checkpoint "$CONFIG_DIR/state.json"
    assert_failure
    [ "$status" -eq 1 ]
    [[ -L "$GITHUB_WORKTREE/templates/untracked.yaml" ]] || return 1
    [[ "$(cat "$outside")" == "EXTERNAL-TARGET-UNCHANGED" ]] || return 1
}

@test "open rejects an untracked symlink and checkpoint rejects it once tracked" {
    _prepare_plain_worktree
    local outside="$BATS_TEST_TMPDIR/outside-cross-check" out="$CONFIG_DIR/open-cross.json"
    local failures=0
    printf 'CROSS-CHECK-TARGET-UNCHANGED\n' > "$outside" || return 1
    printf 'prior-cross-output\n' > "$out" || return 1
    rm "$GITHUB_WORKTREE/templates/default.yaml" || return 1
    ln -s "$outside" "$GITHUB_WORKTREE/templates/default.yaml" || return 1

    run github_config_open "$GITHUB_WORKTREE" "$out"
    [[ "$status" -eq 1 ]] || failures=$((failures + 1))
    [[ "$(cat "$out")" == "prior-cross-output" ]] || failures=$((failures + 1))
    [[ "$(cat "$outside")" == "CROSS-CHECK-TARGET-UNCHANGED" ]] || failures=$((failures + 1))

    git -C "$GITHUB_WORKTREE" init -q || return 1
    git -C "$GITHUB_WORKTREE" add templates/default.yaml || return 1
    run github_config_checkpoint "$CONFIG_DIR/state.json"
    [[ "$status" -eq 1 ]] || failures=$((failures + 1))
    [[ -L "$GITHUB_WORKTREE/templates/default.yaml" ]] || failures=$((failures + 1))
    [[ "$(cat "$outside")" == "CROSS-CHECK-TARGET-UNCHANGED" ]] || failures=$((failures + 1))

    [[ "$failures" -eq 0 ]]
}

@test "open and checkpoint reject FIFO and unexpected directories without hanging" {
    _prepare_plain_worktree
    local out="$CONFIG_DIR/open.json" failures=0
    printf 'prior-open-output\n' > "$out" || return 1
    mkfifo "$GITHUB_WORKTREE/templates/unexpected.pipe" || return 1

    run github_config_open "$GITHUB_WORKTREE" "$out"
    [[ "$status" -eq 1 ]] || failures=$((failures + 1))
    [[ "$(cat "$out")" == "prior-open-output" ]] || failures=$((failures + 1))

    run github_config_checkpoint "$CONFIG_DIR/state.json"
    [[ "$status" -eq 1 ]] || failures=$((failures + 1))
    [[ -p "$GITHUB_WORKTREE/templates/unexpected.pipe" ]] || failures=$((failures + 1))

    rm -f "$GITHUB_WORKTREE/templates/unexpected.pipe" || return 1
    mkdir -p "$GITHUB_WORKTREE/templates/nested" || return 1
    printf 'unexpected\n' > "$GITHUB_WORKTREE/templates/nested/file.yaml" || return 1
    run github_config_checkpoint "$CONFIG_DIR/state.json"
    [[ "$status" -eq 1 ]] || failures=$((failures + 1))
    [[ -f "$GITHUB_WORKTREE/templates/nested/file.yaml" ]] || failures=$((failures + 1))

    [[ "$failures" -eq 0 ]]
}

@test "diagnostic stage redacts uppercase URL credentials and GitHub tokens" {
    local filler payload
    printf -v filler '%0600d' 0
    payload=$'STAGE HTTPS://URLStageUser:URLStagePassword@github.com GITHUB_PAT_StageGithubPat GHP_StageGhp GHO_StageGho\n'"$filler"
    _assert_diagnostic_field_redacted stage "$payload" \
        URLStageUser URLStagePassword StageGithubPat StageGhp StageGho
}

@test "diagnostic detail redacts authorization and token prefixes across newlines" {
    local payload=$'DETAIL GHU_DetailGhu GHS_DetailGhs GHP_\nWrappedGhp GITHUB_PAT_\nWrappedPat AUTHORIZATION:\nBEARER AuthorizationValue BEARER\nBearerValue TOKEN:\nTokenValue'
    _assert_diagnostic_field_redacted detail "$payload" \
        DetailGhu DetailGhs WrappedGhp WrappedPat AuthorizationValue BearerValue TokenValue
}

@test "diagnostic hint redacts password passwd secret and wrapped values" {
    local payload=$'HINT GHR_HintGhr PASSWORD=\nPasswordValue PASSWD\n=\nPasswdValue SECRET:\nSecretValue PASSWORD=WrappedFirst\nWrappedSecond'
    _assert_diagnostic_field_redacted hint "$payload" \
        HintGhr PasswordValue PasswdValue SecretValue WrappedFirst WrappedSecond
}

@test "identity serialization jq failure preserves output and leaves no secret temp" {
    local id=11111111111111111111111111111111
    local out="$CONFIG_DIR/identity.json" marker="$BATS_TEST_TMPDIR/jq.calls"
    local identity_dir="$CONFIG_DIR/ssh/identities"
    local identity="$identity_dir/$id"
    local host_identity="$CONFIG_DIR/host-key" private_marker out_mode temp_found path
    mkdir -p "$TEMPLATES_DIR" "$identity_dir" || return 1
    printf 'mode: rule\n' > "$TEMPLATES_DIR/default.yaml" || return 1
    ssh-keygen -q -t ed25519 -N '' -f "$identity" || return 1
    ssh-keygen -q -t ed25519 -N '' -f "$host_identity" || return 1
    awk '{print "127.0.0.1 "$1" "$2}' "$host_identity.pub" > "$CONFIG_DIR/ssh/known_hosts" || return 1
    cat > "$CONFIG_JSON" <<EOF
{"schema_version":2,"nodes":[{"id":"$id","name":"node","ip":"127.0.0.1","port":22,"user":"root","auth":"key","identity":"$id","secret_id":null,"aliases":{}}],"groups":[{"name":"ROUTER","template":"default.yaml"}],"clients":[],"connections":[]}
EOF
    printf '{"schema_version":1,"node_passwords":{}}\n' > "$SECRETS_JSON" || return 1
    cat > "$STATE_MANIFEST" <<'EOF'
{"schema_version":2,"minimum_remote_control_version":"0.0.0","portability":{"status":"ready","issues":[]},"access":{"script_password_hash":null},"templates":{"default.yaml":{"source":"custom"}}}
EOF
    export SSH_IDENTITIES_DIR="$identity_dir" SSH_KNOWN_HOSTS="$CONFIG_DIR/ssh/known_hosts"
    private_marker=$(sed -n '3p' "$identity") || return 1
    [[ -n "$private_marker" ]] || return 1
    printf 'prior-output-exact\n' > "$out" || return 1
    chmod 640 "$out" || return 1
    out_mode=$(_file_mode "$out") || return 1

    export JQ_REAL SERIALIZER_IDENTITY="$identity" SERIALIZER_JQ_MARKER="$marker"
    JQ_REAL=$(command -v jq) || return 1
    jq() {
        local previous="" arg
        for arg in "$@"; do
            if [[ "$previous" == p && "$arg" == "$SERIALIZER_IDENTITY" ]]; then
                printf 'identity-rawfile\n' >> "$SERIALIZER_JQ_MARKER"
                return 71
            fi
            previous="$arg"
        done
        "$JQ_REAL" "$@"
    }
    run github_config_serialize "$out" "$CONFIG_JSON"
    unset -f jq
    assert_failure
    [[ "$(cat "$marker")" == "identity-rawfile" ]] || return 1
    [[ "$(cat "$out")" == "prior-output-exact" ]] || return 1
    [[ "$(_file_mode "$out")" == "$out_mode" ]] || return 1
    temp_found=$(find "$CONFIG_DIR" -type f \
        \( -name "$(basename "$out").tmp.*" -o -name '.serialize.*' \) -print -quit) || return 1
    [[ -z "$temp_found" ]] || return 1
    while IFS= read -r path; do
        [[ "$path" == "$identity" ]] && continue
        grep -Fq "$private_marker" "$path" && return 1
    done < <(find "$CONFIG_DIR" -type f -print)
    return 0
}

@test "age partial state output preserves old ciphertext and mode" {
    export GITHUB_WORKTREE="$CONFIG_DIR/worktree" GITHUB_STORAGE_MODE=age
    mkdir -p "$GITHUB_WORKTREE" || return 1
    local old="$GITHUB_WORKTREE/state.json.age" age="$BATS_TEST_TMPDIR/age"
    local old_mode temp_found mode_marker="$BATS_TEST_TMPDIR/state-output.mode"
    printf '{"storage_version":1,"encryption":"age"}\n' > "$GITHUB_WORKTREE/storage.json" || return 1
    printf 'old-ciphertext-exact\n' > "$old" || return 1
    chmod 600 "$old" || return 1
    old_mode=$(_file_mode "$old") || return 1
    cat > "$age" <<'EOF'
#!/bin/bash
out=""
while (($#)); do
    if [[ "$1" == -o ]]; then out="${2:-}"; shift 2; else shift; fi
done
if [[ -n "$out" ]]; then
    printf 'partial-ciphertext\n' > "$out"
    if [[ "${OSTYPE:-}" == darwin* ]]; then
        stat -f '%Lp' "$out"
    else
        stat -c '%a' "$out"
    fi > "$PARTIAL_MODE_MARKER"
else
    printf 'partial-ciphertext\n'
fi
exit 73
EOF
    chmod +x "$age" || return 1
    export AGE_BIN="$age" GITHUB_RECIPIENT=age1testrecipient
    export PARTIAL_MODE_MARKER="$mode_marker"
    _write_valid_logical_state "$CONFIG_DIR/state.json" || return 1

    run github_config_checkpoint "$CONFIG_DIR/state.json"
    assert_failure
    [[ "$(cat "$old")" == "old-ciphertext-exact" ]] || return 1
    [[ "$(_file_mode "$old")" == "$old_mode" ]] || return 1
    [[ "$(cat "$mode_marker")" == 600 ]] || return 1
    temp_found=$(find "$GITHUB_WORKTREE" \
        \( -name 'state.json.age.tmp.*' -o -name '.state.json.age.*' -o \
           -name '.github-private.*' \) -print -quit) || return 1
    [[ -z "$temp_found" ]]
}

@test "age partial rewrap preserves old unlock ciphertext and mode" {
    export GITHUB_WORKTREE="$CONFIG_DIR/worktree" GITHUB_STORAGE_MODE=age
    mkdir -p "$GITHUB_WORKTREE" || return 1
    local unlock="$GITHUB_WORKTREE/unlock.age" age="$BATS_TEST_TMPDIR/age-rewrap"
    local unlock_mode temp_found mode_marker="$BATS_TEST_TMPDIR/rewrap-output.mode"
    printf 'old-unlock-exact\n' > "$unlock" || return 1
    chmod 600 "$unlock" || return 1
    unlock_mode=$(_file_mode "$unlock") || return 1
    cat > "$age" <<'EOF'
#!/bin/bash
out=""
decrypt=false
while (($#)); do
    case "$1" in
        -d) decrypt=true; shift ;;
        -o) out="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ "$decrypt" == true ]]; then
    printf 'AGE-SECRET-KEY-TEST\n' > "$out"
    if [[ "${OSTYPE:-}" == darwin* ]]; then
        stat -f '%Lp' "$out"
    else
        stat -c '%a' "$out"
    fi > "$PARTIAL_MODE_MARKER"
    exit 0
fi
printf 'partial-unlock\n' > "$out"
if [[ "${OSTYPE:-}" == darwin* ]]; then
    stat -f '%Lp' "$out"
else
    stat -c '%a' "$out"
fi > "$PARTIAL_MODE_MARKER"
exit 74
EOF
    chmod +x "$age" || return 1
    export AGE_BIN="$age" PARTIAL_MODE_MARKER="$mode_marker"

    run github_config_rewrap_master <<< $'old-password\nnew-password\nnew-password\n'
    assert_failure
    [[ "$(cat "$unlock")" == "old-unlock-exact" ]] || return 1
    [[ "$(_file_mode "$unlock")" == "$unlock_mode" ]] || return 1
    [[ "$(sort -u "$mode_marker")" == 600 ]] || return 1
    temp_found=$(find "$CONFIG_DIR" \
        \( -name '.rewrap.*' -o -name '.github-private.*' \) -print -quit) || return 1
    [[ -z "$temp_found" ]]
}

@test "age init partial output preserves the previous recipient unlock and identity" {
    export GITHUB_WORKTREE="$CONFIG_DIR/worktree"
    mkdir -p "$GITHUB_WORKTREE" || return 1
    local recipient="$GITHUB_WORKTREE/recipient.txt" unlock="$GITHUB_WORKTREE/unlock.age"
    local identity="$BATS_TEST_TMPDIR/old-identity" age="$BATS_TEST_TMPDIR/age-init"
    local keygen="$BATS_TEST_TMPDIR/age-keygen" recipient_mode unlock_mode temp_found
    local mode_marker="$BATS_TEST_TMPDIR/init-output.mode"
    printf 'old-recipient\n' > "$recipient" || return 1
    printf 'old-unlock\n' > "$unlock" || return 1
    printf 'old-identity\n' > "$identity" || return 1
    chmod 644 "$recipient" || return 1
    chmod 600 "$unlock" "$identity" || return 1
    recipient_mode=$(_file_mode "$recipient") || return 1
    unlock_mode=$(_file_mode "$unlock") || return 1
    cat > "$keygen" <<'EOF'
#!/bin/bash
cat <<'KEY'
# public key: age1newrecipient
AGE-SECRET-KEY-NEW
KEY
EOF
    cat > "$age" <<'EOF'
#!/bin/bash
out=""
while (($#)); do
    if [[ "$1" == -o ]]; then out="${2:-}"; shift 2; else shift; fi
done
printf 'partial-unlock\n' > "$out"
if [[ "${OSTYPE:-}" == darwin* ]]; then
    stat -f '%Lp' "$out"
else
    stat -c '%a' "$out"
fi > "$PARTIAL_MODE_MARKER"
exit 75
EOF
    chmod +x "$keygen" "$age" || return 1
    export AGE_KEYGEN_BIN="$keygen" AGE_BIN="$age" PARTIAL_MODE_MARKER="$mode_marker"
    GITHUB_IDENTITY="$identity"
    GITHUB_RECIPIENT=old-recipient

    local age_init_rc=0
    github_config_age_init <<< $'master-password\nmaster-password\n' || age_init_rc=$?
    [[ "$age_init_rc" -ne 0 ]] || return 1
    [[ -f "$recipient" ]] || return 1
    [[ -f "$unlock" ]] || return 1
    [[ "$(cat "$recipient")" == "old-recipient" ]] || return 1
    [[ "$(cat "$unlock")" == "old-unlock" ]] || return 1
    [[ "$(_file_mode "$recipient")" == "$recipient_mode" ]] || return 1
    [[ "$(_file_mode "$unlock")" == "$unlock_mode" ]] || return 1
    [[ "$GITHUB_IDENTITY" == "$identity" ]] || return 1
    [[ "$GITHUB_RECIPIENT" == old-recipient ]] || return 1
    [[ "$(cat "$mode_marker")" == 600 ]] || return 1
    temp_found=$(find "$CONFIG_DIR" \
        \( -name 'github-identity.tmp*' -o -name '.recipient.*' -o \
           -name '.unlock.*' -o -name '.github-private.*' \) -print -quit) || return 1
    [[ -z "$temp_found" ]]
}

@test "private identity chmod failure rolls back the complete plaintext tree" {
    export GITHUB_WORKTREE="$CONFIG_DIR/worktree" GITHUB_STORAGE_MODE=none
    local id=00000000000000000000000000000000 state="$CONFIG_DIR/state.json"
    local chmod_real rc=0 temp_found
    mkdir -p "$GITHUB_WORKTREE/templates" "$GITHUB_WORKTREE/ssh/identities" || return 1
    printf prior-config > "$GITHUB_WORKTREE/config.json" || return 1
    printf prior-secrets > "$GITHUB_WORKTREE/secrets.json" || return 1
    printf prior-manifest > "$GITHUB_WORKTREE/manifest.json" || return 1
    printf prior-known-host > "$GITHUB_WORKTREE/ssh/known_hosts" || return 1
    printf prior-template > "$GITHUB_WORKTREE/templates/prior.yaml" || return 1
    printf prior-identity > "$GITHUB_WORKTREE/ssh/identities/$id" || return 1
    chmod 640 "$GITHUB_WORKTREE/config.json" || return 1
    chmod 600 "$GITHUB_WORKTREE/secrets.json" "$GITHUB_WORKTREE/ssh/known_hosts" \
        "$GITHUB_WORKTREE/ssh/identities/$id" || return 1
    chmod 644 "$GITHUB_WORKTREE/manifest.json" "$GITHUB_WORKTREE/templates/prior.yaml" || return 1
    _write_valid_logical_state "$state" || return 1
    jq --arg id "$id" \
        '.ssh.identities={($id):{private:"new-private",public:"new-public"}}' \
        "$state" > "$state.next" || return 1
    mv "$state.next" "$state" || return 1

    export CHMOD_REAL PRIVATE_IDENTITY_NAME="$id"
    CHMOD_REAL=$(command -v chmod) || return 1
    chmod() {
        local arg
        for arg in "$@"; do
            if [[ "$arg" == */.plain-write.*/ssh/identities/"$PRIVATE_IDENTITY_NAME" ]]; then
                return 76
            fi
        done
        "$CHMOD_REAL" "$@"
    }
    _github_plain_write "$state" || rc=$?
    unset -f chmod
    [[ "$rc" -ne 0 ]] || return 1
    _assert_prior_plain_tree || return 1
    [[ "$(_file_mode "$GITHUB_WORKTREE/config.json")" == 640 ]] || return 1
    [[ "$(_file_mode "$GITHUB_WORKTREE/secrets.json")" == 600 ]] || return 1
    [[ "$(_file_mode "$GITHUB_WORKTREE/manifest.json")" == 644 ]] || return 1
    [[ ! -e "$GITHUB_WORKTREE/templates/default.yaml" ]] || return 1
    temp_found=$(find "$GITHUB_WORKTREE" \
        \( -name '.plain-write.*' -o -name '.plain-backup.*' \) -print -quit) || return 1
    [[ -z "$temp_found" ]]
}

@test "checkpoint removes newly-created storage after later plain and age failures" {
    local state="$CONFIG_DIR/checkpoint-state.json" age="$BATS_TEST_TMPDIR/age-fail"
    local rc=0 leftover
    _write_valid_logical_state "$state" || return 1
    GITHUB_WORKTREE="$CONFIG_DIR/checkpoint-worktree"
    mkdir -p "$GITHUB_WORKTREE" || return 1
    GITHUB_STORAGE_MODE=none
    _github_plain_write() {
        _github_record_error "имитация записи plaintext" "Имитирован поздний сбой."
        return 76
    }
    github_config_checkpoint "$state" || rc=$?
    [[ "$rc" -ne 0 ]] || return 1
    leftover=$(find "$GITHUB_WORKTREE" -mindepth 1 -print -quit) || return 1
    [[ -z "$leftover" ]] || return 1
    unset -f _github_plain_write

    rm -rf "$GITHUB_WORKTREE" || return 1
    mkdir -p "$GITHUB_WORKTREE" || return 1
    cat > "$age" <<'EOF'
#!/bin/bash
out=""
while (($#)); do
    if [[ "$1" == -o ]]; then out="${2:-}"; shift 2; else shift; fi
done
printf 'partial-ciphertext\n' > "$out"
exit 77
EOF
    chmod +x "$age" || return 1
    AGE_BIN="$age"
    GITHUB_STORAGE_MODE=age
    GITHUB_RECIPIENT=age1testrecipient
    rc=0
    github_config_checkpoint "$state" || rc=$?
    [[ "$rc" -ne 0 ]] || return 1
    leftover=$(find "$GITHUB_WORKTREE" -mindepth 1 -print -quit) || return 1
    [[ -z "$leftover" ]]
}

@test "GitHub config promotion failure rolls back and direct success becomes pending" {
    local runtime="$CONFIG_DIR/github-runtime" state="$CONFIG_DIR/old-state.json"
    local snapshot="$BATS_TEST_TMPDIR/worktree-snapshot" before diagnostic
    local mv_real rc=0 temp_found
    mkdir -p "$runtime/templates" "$runtime/ssh/identities" || return 1
    cat > "$runtime/config.json" <<'EOF'
{"schema_version":2,"marker":"old","nodes":[],"groups":[],"clients":[],"connections":[]}
EOF
    printf '{"schema_version":1,"node_passwords":{}}\n' > "$runtime/secrets.json" || return 1
    cat > "$runtime/manifest.json" <<'EOF'
{"schema_version":2,"minimum_remote_control_version":"0.0.0","portability":{"status":"ready","issues":[]},"access":{"script_password_hash":null},"templates":{}}
EOF
    printf 'mode: rule\n' > "$runtime/templates/default.yaml" || return 1
    : > "$runtime/ssh/known_hosts" || return 1
    chmod 700 "$runtime" "$runtime/templates" "$runtime/ssh" "$runtime/ssh/identities" || return 1
    chmod 600 "$runtime/config.json" "$runtime/secrets.json" "$runtime/manifest.json" \
        "$runtime/ssh/known_hosts" || return 1
    export CONFIG_SOURCE=github STATE_DIR="$runtime" CONFIG_JSON="$runtime/config.json"
    export SECRETS_JSON="$runtime/secrets.json" STATE_MANIFEST="$runtime/manifest.json"
    export TEMPLATES_DIR="$runtime/templates" SSH_IDENTITIES_DIR="$runtime/ssh/identities"
    export SSH_KNOWN_HOSTS="$runtime/ssh/known_hosts"
    export GITHUB_WORKTREE="$CONFIG_DIR/worktree" GITHUB_STORAGE_MODE=none
    mkdir -p "$GITHUB_WORKTREE" || return 1
    github_config_serialize "$state" "$CONFIG_JSON" || return 1
    github_config_checkpoint "$state" || return 1
    cp -Rp "$GITHUB_WORKTREE" "$snapshot" || return 1
    before=$(cat "$CONFIG_JSON") || return 1
    GITHUB_SYNC_STATUS=pending
    diagnostic="$BATS_TEST_TMPDIR/persist-diagnostic"

    export MV_REAL PERSIST_CONFIG="$CONFIG_JSON" PERSIST_MV_MARKER="$BATS_TEST_TMPDIR/final-mv"
    MV_REAL=$(command -v mv) || return 1
    mv() {
        if [[ "$#" -eq 2 && "$1" == "$PERSIST_CONFIG.tmp."* && "$2" == "$PERSIST_CONFIG" ]]; then
            printf 'blocked\n' > "$PERSIST_MV_MARKER"
            return 77
        fi
        "$MV_REAL" "$@"
    }
    jq_w '.marker="new"' > "$diagnostic" 2>&1 || rc=$?
    unset -f mv

    [[ "$rc" -ne 0 ]] || return 1
    [[ -e "$PERSIST_MV_MARKER" ]] || return 1
    [[ "$(cat "$CONFIG_JSON")" == "$before" ]] || return 1
    diff -r "$snapshot" "$GITHUB_WORKTREE" >/dev/null || return 1
    [[ "$GITHUB_SYNC_STATUS" == pending ]] || return 1
    [[ -n "${CONFIG_PERSIST_LAST_ERROR:-}" ]] || return 1
    grep -Fq "$CONFIG_PERSIST_LAST_ERROR" "$diagnostic" || return 1
    temp_found=$(find "$CONFIG_DIR" \
        \( -name 'config.json.tmp.*' -o -name '.candidate-state.*' \
           -o -name '.runtime-state.*' -o -name '.plain-write.*' \
           -o -name '.plain-backup.*' \) -print -quit) || return 1
    [[ -z "$temp_found" ]] || return 1
    local success_candidate="$CONFIG_DIR/config.success"
    jq '.marker="committed"' "$CONFIG_JSON" > "$success_candidate" || return 1
    GITHUB_SYNC_STATUS=clean
    config_persist_candidate "$success_candidate" || return 1
    [[ "$GITHUB_SYNC_STATUS" == pending ]]
}
