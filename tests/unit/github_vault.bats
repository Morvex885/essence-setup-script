#!/usr/bin/env bats
BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-30}"

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module 'state.sh'
    source_module 'nodes.sh'
    source_module 'github-config.sh'
    # Bare-module fault fixtures model an already available batchpass dependency.
    ensure_age_batchpass() { return 0; }
    printf '{"schema_version":1,"node_passwords":{}}\n' > "$CONFIG_DIR/secrets.json"
    printf '{"schema_version":2,"portability":{"status":"ready","issues":[]},"access":{"script_password_hash":null},"templates":{}}\n' > "$CONFIG_DIR/manifest.json"
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
      vault_version:2,
      minimum_remote_control_version:"0.0.0",
      portability:{status:"ready",issues:[]},
      access:{script_password_hash:null},
      config:{schema_version:2,nodes:[],groups:[],clients:[],connections:[]},
      secrets:{schema_version:2,node_passwords:{}},
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


@test "storage mode decision accepts only age or none" {
    GITHUB_DECISION_STORAGE=none
    _github_decide_storage_mode
    [[ "$GITHUB_STORAGE_MODE" == none ]] || return 1
    GITHUB_DECISION_STORAGE=age
    _github_decide_storage_mode
    [[ "$GITHUB_STORAGE_MODE" == age ]] || return 1
}

@test "missing or unknown storage decision clears the previous selection" {
    local value rc
    for value in '' 1 plaintext; do
        GITHUB_STORAGE_MODE=age GITHUB_DECISION_STORAGE="$value" rc=0
        _github_decide_storage_mode || rc=$?
        [[ "$rc" -eq 1 && -z "$GITHUB_STORAGE_MODE" ]] || return 1
        [[ "$RC_ERROR_CODE" == storage_mode_required ]] || return 1
        [[ "$(jq -c .choices <<< "$RC_ERROR_EXTRA")" == '["age","none"]' ]] || return 1
    done
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
    _write_valid_logical_state "$CONFIG_DIR/state.json"
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
[[ "$1" == -y && "$(cat "${2:-}")" == AGE-SECRET-KEY-CALLER ]] || exit 1
printf 'age1callerrecipient\n'
EOF
    cat > "$age" <<'EOF'
#!/bin/bash
exit 74
EOF
    chmod +x "$keygen" "$age" || return 1
    mkdir -p "$CONFIG_DIR/worktree" || return 1
    printf 'encrypted-unlock\n' > "$CONFIG_DIR/worktree/unlock.age" || return 1
    printf 'age1repositoryrecipient\n' > "$CONFIG_DIR/worktree/recipient.txt" || return 1
    GITHUB_WORKTREE="$CONFIG_DIR/worktree"
    GITHUB_IDENTITY="$identity"
    AGE_KEYGEN_BIN="$keygen"
    AGE_BIN="$age"
    github_config_unlock </dev/null || rc=$?
    [[ "$RC_ERROR_CODE" == vault_password_required ]] || return 1
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

@test "rejected GitHub group candidate preserves config and skips completion effects" {
    source "$PROJECT_ROOT/remote-control/modules/groups.sh"
    local before manifest_before rc=0 temp_found
    local completion="$BATS_TEST_TMPDIR/group-completed"
    local pushed="$BATS_TEST_TMPDIR/github-pushed"
    printf '{"schema_version":1,"node_passwords":{}}\n' > "$SECRETS_JSON" || return 1
    printf 'mode: rule\n' > "$TEMPLATES_DIR/default.yaml" || return 1
    state_open_local || return 1
    state_validate true || return 1
    before=$(jq -S . "$CONFIG_JSON") || return 1
    manifest_before=$(cat "$STATE_MANIFEST") || return 1

    # A lost session must reject the real checkpoint, not just a mocked writer.
    CONFIG_SOURCE=github
    GITHUB_STORAGE_MODE=none
    GITHUB_WORKTREE="$BATS_TEST_TMPDIR/missing-worktree"
    GITHUB_SYNC_STATUS=clean
    success() { printf 'completed\n' > "$completion"; }
    github_sync_flush() { printf 'pushed\n' > "$pushed"; }

    state_action add_group core_group_add REJECTED \
        > "$BATS_TEST_TMPDIR/rejected-group-output" 2>&1 || rc=$?

    [[ "$rc" -ne 0 ]] || return 1
    [[ "$(jq -S . "$CONFIG_JSON")" == "$before" ]] || return 1
    [[ "$(cat "$STATE_MANIFEST")" == "$manifest_before" ]] || return 1
    [[ ! -e "$completion" && ! -e "$pushed" ]] || return 1
    [[ ! -e "$GITHUB_WORKTREE" ]] || return 1
    [[ "$GITHUB_SYNC_STATUS" == clean ]] || return 1
    temp_found=$(find "$CONFIG_DIR" \
        \( -name 'config.json.tmp.*' -o -name '.candidate-state.*' \
           -o -name '.persist-config.*' \) -print -quit) || return 1
    [[ -z "$temp_found" ]]
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

@test "missing batchpass dependencies reject age operations before mutating the vault" {
    GITHUB_WORKTREE="$CONFIG_DIR/dependency-worktree" GITHUB_STORAGE_MODE=age
    mkdir -p "$GITHUB_WORKTREE" || return 1
    printf 'age1existing\n' > "$GITHUB_WORKTREE/recipient.txt"
    printf 'existing-unlock\n' > "$GITHUB_WORKTREE/unlock.age"
    printf 'existing-state\n' > "$GITHUB_WORKTREE/state.json.age"
    printf 'existing-identity\n' > "$CONFIG_DIR/dependency-identity"
    chmod 600 "$GITHUB_WORKTREE/unlock.age" "$GITHUB_WORKTREE/state.json.age" \
        "$CONFIG_DIR/dependency-identity" || return 1
    GITHUB_IDENTITY="$CONFIG_DIR/dependency-identity" GITHUB_RECIPIENT=age1existing
    GITHUB_SECRET_VAULT_PASSWORD=old-password GITHUB_SECRET_NEW_VAULT_PASSWORD=new-password
    local state="$CONFIG_DIR/dependency-state.json" before operation rc
    _write_valid_logical_state "$state" || return 1
    before=$(find "$CONFIG_DIR" -print | LC_ALL=C sort) || return 1
    ensure_age_batchpass() { return 1; }
    for operation in github_config_age_init github_config_unlock \
        github_config_checkpoint github_config_rewrap_master; do
        rc=0 RC_ERROR_CODE=""
        if [[ "$operation" == github_config_checkpoint ]]; then
            "$operation" "$state" || rc=$?
        else
            "$operation" || rc=$?
        fi
        [[ "$rc" -ne 0 && "$RC_ERROR_CODE" == deps_missing ]] || return 1
        [[ "$GITHUB_IDENTITY" == "$CONFIG_DIR/dependency-identity" &&
           "$GITHUB_RECIPIENT" == age1existing ]] || return 1
        [[ "$(cat "$GITHUB_IDENTITY")" == existing-identity ]] || return 1
        [[ "$(cat "$GITHUB_WORKTREE/recipient.txt")" == age1existing ]] || return 1
        [[ "$(cat "$GITHUB_WORKTREE/unlock.age")" == existing-unlock ]] || return 1
        [[ "$(cat "$GITHUB_WORKTREE/state.json.age")" == existing-state ]] || return 1
        [[ "$(_file_mode "$GITHUB_IDENTITY")" == 600 &&
           "$(_file_mode "$GITHUB_WORKTREE/unlock.age")" == 600 &&
           "$(_file_mode "$GITHUB_WORKTREE/state.json.age")" == 600 ]] || return 1
        [[ "$(find "$CONFIG_DIR" -print | LC_ALL=C sort)" == "$before" ]] || return 1
    done
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

@test "age open takes the recipient from the opened repository, not a stale session" {
    export GITHUB_WORKTREE="$CONFIG_DIR/worktree" GITHUB_STORAGE_MODE=age
    mkdir -p "$GITHUB_WORKTREE" || return 1
    git -C "$GITHUB_WORKTREE" init >/dev/null || return 1
    printf '{"storage_version":1,"encryption":"age"}\n' > "$GITHUB_WORKTREE/storage.json"
    printf 'age1repositoryrecipient\r\n' > "$GITHUB_WORKTREE/recipient.txt"
    printf 'wrapped\n' > "$GITHUB_WORKTREE/unlock.age"
    printf 'ciphertext\n' > "$GITHUB_WORKTREE/state.json.age"
    git -C "$GITHUB_WORKTREE" add . >/dev/null || return 1
    export AGE_STATE_FIXTURE="$CONFIG_DIR/plain-state.json"
    _write_valid_logical_state "$AGE_STATE_FIXTURE" || return 1
    cat > "$BATS_TEST_TMPDIR/age-keygen" <<'EOF'
#!/bin/bash
[[ "$1" == -y && "$(cat "$2")" == AGE-SECRET-KEY-FIXTURE ]] || exit 1
printf 'age1repositoryrecipient\n'
EOF
    cat > "$BATS_TEST_TMPDIR/age" <<'EOF'
#!/bin/bash
[[ $# -eq 6 && "$1" == -d && "$2" == -i && "$4" == -o ]] || exit 1
[[ "$(cat "$3")" == AGE-SECRET-KEY-FIXTURE && "$6" == *state.json.age ]] || exit 1
cp "$AGE_STATE_FIXTURE" "$5"
EOF
    chmod +x "$BATS_TEST_TMPDIR/age" "$BATS_TEST_TMPDIR/age-keygen"
    export AGE_BIN="$BATS_TEST_TMPDIR/age" AGE_KEYGEN_BIN="$BATS_TEST_TMPDIR/age-keygen"
    printf 'AGE-SECRET-KEY-FIXTURE\n' > "$CONFIG_DIR/identity"
    GITHUB_IDENTITY="$CONFIG_DIR/identity" GITHUB_RECIPIENT=age1stalerecipient
    github_config_open "$GITHUB_WORKTREE" "$CONFIG_DIR/opened.json" </dev/null || return 1
    [[ "$GITHUB_RECIPIENT" == age1repositoryrecipient ]] || return 1
    jq -e '.vault_version==2' "$CONFIG_DIR/opened.json"
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
[[ $# -eq 6 && "$2" == -j && "$3" == batchpass && "$4" == -o ]] || exit 1
[[ "${AGE_PASSPHRASE_FD:-}" == 9 && /dev/fd/0 -ef /dev/null ]] || exit 1
IFS= read -r pw <&9 || [[ -n "$pw" ]] || exit 1
out="$5"
if [[ "$1" == -d ]]; then
    [[ "$pw" == old-password && "$(cat "$6")" == old-unlock-exact ]] || exit 1
    printf 'AGE-SECRET-KEY-TEST\n' > "$out"
    if [[ "${OSTYPE:-}" == darwin* ]]; then
        stat -f '%Lp' "$out"
    else
        stat -c '%a' "$out"
    fi > "$PARTIAL_MODE_MARKER"
    exit 0
fi
[[ "$1" == -e && "$pw" == new-password && "$(cat "$6")" == AGE-SECRET-KEY-TEST ]] || exit 1
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

    GITHUB_SECRET_VAULT_PASSWORD=old-password GITHUB_SECRET_NEW_VAULT_PASSWORD=new-password
    run github_config_rewrap_master
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
[[ $# -eq 6 && "$1" == -e && "$2" == -j && "$3" == batchpass && "$4" == -o ]] || exit 1
[[ "${AGE_PASSPHRASE_FD:-}" == 9 && /dev/fd/0 -ef /dev/null ]] || exit 1
IFS= read -r pw <&9 || [[ -n "$pw" ]] || exit 1
[[ "$pw" == master-password && "$(cat "$6")" == *AGE-SECRET-KEY-NEW* ]] || exit 1
out="$5"
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
    GITHUB_SECRET_NEW_VAULT_PASSWORD=master-password
    github_config_age_init || age_init_rc=$?
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

_portable_password_runtime() {
    export PORTABLE_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa PORTABLE_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    export SSH_KNOWN_HOSTS="$CONFIG_DIR/ssh/known_hosts"
    export SSH_IDENTITIES_DIR="$CONFIG_DIR/ssh/identities"
    mkdir -p "$SSH_IDENTITIES_DIR" "$TEMPLATES_DIR" || return 1
    printf 'mode: rule\n' > "$TEMPLATES_DIR/default.yaml"
    ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/portable-host" || return 1
    local kind public ignored
    read -r kind public ignored < "$BATS_TEST_TMPDIR/portable-host.pub"
    printf '192.0.2.10 %s %s\n192.0.2.11 %s %s\n' "$kind" "$public" "$kind" "$public" > "$SSH_KNOWN_HOSTS"
    jq -n --arg a "$PORTABLE_A" --arg b "$PORTABLE_B" '{
      schema_version:2,nodes:[
        {id:$a,name:"portable-a",ip:"192.0.2.10",port:22,user:"root",auth:"password",identity:null,secret_id:("node:"+$a+":ssh-password"),tag:"TEST",aliases:{}},
        {id:$b,name:"portable-b",ip:"192.0.2.11",port:22,user:"root",auth:"password",identity:null,secret_id:("node:"+$b+":ssh-password"),tag:"TEST",aliases:{}}],
      groups:[],clients:[],connections:[]}' > "$CONFIG_JSON"
    PORTABLE_PASSWORD=$' synthetic "quote" \\ slash \u03bb\r\nlast\n'
    _pass_key() { printf '%064d' 1; }
    node_secret_set "$PORTABLE_A" "$PORTABLE_PASSWORD" || return 1
    node_secret_set "$PORTABLE_B" 'synthetic-second' || return 1
    jq --arg key "node:$PORTABLE_B:ssh-password" '.node_passwords[$key]="unreadable-ciphertext"' "$SECRETS_JSON" > "$SECRETS_JSON.next" &&
        mv "$SECRETS_JSON.next" "$SECRETS_JSON" || return 1
    chmod 600 "$SECRETS_JSON"
}

_portable_password_transport_roundtrip() {
    local mode="$1" logical="$CONFIG_DIR/portable.json" opened="$CONFIG_DIR/opened.json"
    local imported="$CONFIG_DIR/imported.json" before received
    _portable_password_runtime || return 1
    before=$(cat "$SECRETS_JSON")
    github_config_serialize "$logical" "$CONFIG_JSON" || return 1
    [[ "$(cat "$SECRETS_JSON")" == "$before" ]] || return 1
    jq -e --arg a "$PORTABLE_A" --arg b "$PORTABLE_B" '
      .vault_version==2 and .secrets.schema_version==2 and
      (.config.nodes|length)==2 and
      (.secrets.node_passwords|keys)==[("node:"+$a+":ssh-password")] and
      .portability=={status:"needs_setup",issues:[{node_id:$b,reason:"missing_secret"}]}' "$logical" || return 1
    export GITHUB_WORKTREE="$CONFIG_DIR/portable-worktree" GITHUB_STORAGE_MODE="$mode"
    mkdir -p "$GITHUB_WORKTREE"
    git -C "$GITHUB_WORKTREE" init >/dev/null || return 1
    if [[ "$mode" == age ]]; then
        { command -v age >/dev/null && command -v age-keygen >/dev/null; } || skip "age не установлен"
        AGE_BIN=$(command -v age)
        AGE_KEYGEN_BIN=$(command -v age-keygen)
        source "$PROJECT_ROOT/common/ensure-deps.sh"
        _age_batchpass_valid "$AGE_BIN" "$AGE_KEYGEN_BIN" || skip "age >=1.3.2 с batchpass не установлен"
        GITHUB_UNLOCK_FILE="$BATS_TEST_TMPDIR/portable-agekey"
        "$AGE_KEYGEN_BIN" -o "$GITHUB_UNLOCK_FILE" >/dev/null 2>&1 || return 1
        GITHUB_RECIPIENT=$("$AGE_KEYGEN_BIN" -y "$GITHUB_UNLOCK_FILE") || return 1
        printf '%s\n' "$GITHUB_RECIPIENT" > "$GITHUB_WORKTREE/recipient.txt"
        printf '%s' portable-vault-password |
            _github_age_passphrase -e "$GITHUB_UNLOCK_FILE" "$GITHUB_WORKTREE/unlock.age" || return 1
        GITHUB_IDENTITY=""
    fi
    run github_config_checkpoint "$logical"
    assert_success
    [[ "$output" != *synthetic* && "$output" != *unreadable-ciphertext* ]] || return 1
    github_config_open "$GITHUB_WORKTREE" "$opened" </dev/null || return 1
    cmp -s <(jq -S . "$logical") <(jq -S . "$opened") || return 1
    jq '.secrets' "$opened" > "$CONFIG_DIR/portable-secrets.json"
    _pass_key() { printf '%064d' 2; }
    _state_secrets_import_portable "$CONFIG_DIR/portable-secrets.json" "$imported" || return 1
    jq -e '.schema_version==1' "$imported" || return 1
    received=$(node_secret_get "$PORTABLE_A" "$imported"; rc=$?; printf '.'; exit "$rc") || return 1
    [[ "${received%.}" == "$PORTABLE_PASSWORD" ]] || return 1
    run node_secret_get "$PORTABLE_B" "$imported"
    [[ "$status" -eq 2 && -z "$output" ]] || return 1
    SECRETS_JSON="$imported"
    STATE_MANIFEST="$CONFIG_DIR/imported-manifest.json"
    jq '{schema_version:2,portability,access,templates:{}}' "$opened" > "$STATE_MANIFEST"
    github_config_serialize "$CONFIG_DIR/reexport.json" "$CONFIG_JSON" || return 1
    cmp -s <(jq -S . "$logical") <(jq -S . "$CONFIG_DIR/reexport.json") || return 1
    if [[ "$mode" == age ]]; then
        [[ ! -e "$GITHUB_WORKTREE/secrets.json" && ! -e "$GITHUB_WORKTREE/config.json" ]] || return 1
        [[ "$(cd "$GITHUB_WORKTREE" && find . -maxdepth 1 -type f | sed 's|^\./||' | LC_ALL=C sort)" == $'recipient.txt\nstate.json.age\nstorage.json\nunlock.age' ]] || return 1
    fi
}

@test "portable password none transport preserves plaintext across machine keys" {
    _portable_password_transport_roundtrip none
}

@test "portable password real age transport preserves plaintext across machine keys" {
    _portable_password_transport_roundtrip age
}

@test "portable password partial validator rejects contradictory missing secrets and NUL" {
    _portable_password_runtime || return 1
    local logical="$CONFIG_DIR/portable.json" invalid="$CONFIG_DIR/invalid.json" filter
    github_config_serialize "$logical" "$CONFIG_JSON" || return 1
    for filter in \
        '.portability.issues=[] | .portability.status="ready"' \
        '.portability.issues[0].node_id="cccccccccccccccccccccccccccccccc"' \
        '.portability.issues += [{node_id:.config.nodes[0].id,reason:"missing_secret"}]' \
        '.config.nodes[1].auth="key" | .config.nodes[1].secret_id=null | .config.nodes[1].identity="system"' \
        '.secrets.node_passwords[("node:"+.config.nodes[0].id+":ssh-password")]="bad\u0000password"' \
        '.secrets.node_passwords[("node:"+.config.nodes[0].id+":ssh-password")]=""' \
        '.secrets.node_passwords[("node:"+.config.nodes[0].id+":ssh-password")]=3'; do
        jq "$filter" "$logical" > "$invalid" || return 1
        run github_config_validate "$invalid"
        assert_failure
        [[ "$output" != *synthetic* ]] || return 1
    done
}

@test "plain reader classifies old, newer and absent versions" {
    _prepare_plain_worktree || return 1
    git -C "$GITHUB_WORKTREE" init >/dev/null || return 1
    local version out="$CONFIG_DIR/open-version.json" expected
    cp "$GITHUB_WORKTREE/manifest.json" "$CONFIG_DIR/original-manifest.json"
    for version in 1 99 null; do
        jq --argjson version "$version" '.vault_version=$version' "$CONFIG_DIR/original-manifest.json" > "$GITHUB_WORKTREE/manifest.json"
        printf 'previous-output\n' > "$out"
        chmod 640 "$out"
        ! github_config_open "$GITHUB_WORKTREE" "$out" || return 1
        case "$version" in
            1) expected=outdated ;;
            99) expected=newer ;;
            null) expected=invalid ;;
        esac
        [[ "$GITHUB_LAST_FORMAT" == "$expected" ]] || return 1
        if [[ "$version" == 1 ]]; then
            [[ "$GITHUB_LAST_FORMAT_VERSION" == 1 ]] || return 1
        fi
        [[ "$(cat "$out")" == previous-output && "$(_file_mode "$out")" == 640 ]] || return 1
    done
    cp "$CONFIG_DIR/original-manifest.json" "$GITHUB_WORKTREE/manifest.json"
    github_config_open "$GITHUB_WORKTREE" "$out" || return 1
    jq -e '.vault_version==2 and .secrets.schema_version==2' "$out"
}

# _prepare_v1_plain_worktree [all|partial] — publish a vault-1 tree with device-bound secrets.
_prepare_v1_plain_worktree() {
    local readable="${1:-all}"
    _portable_password_runtime || return 1
    if [[ "$readable" == all ]]; then
        node_secret_set "$PORTABLE_B" 'synthetic-second' || return 1
    fi
    export GITHUB_WORKTREE="$CONFIG_DIR/v1-worktree" GITHUB_STORAGE_MODE=none
    mkdir -p "$GITHUB_WORKTREE" || return 1
    git -C "$GITHUB_WORKTREE" init >/dev/null || return 1
    github_config_serialize "$CONFIG_DIR/v2.json" "$CONFIG_JSON" || return 1
    github_config_checkpoint "$CONFIG_DIR/v2.json" >/dev/null || return 1
    cp "$SECRETS_JSON" "$GITHUB_WORKTREE/secrets.json" || return 1
    jq '.vault_version=1 | .minimum_remote_control_version="1.0.3" |
        .portability={status:"ready",issues:[]}' \
        "$GITHUB_WORKTREE/manifest.json" > "$CONFIG_DIR/v1-manifest.json" &&
        mv "$CONFIG_DIR/v1-manifest.json" "$GITHUB_WORKTREE/manifest.json"
}

@test "vault v1 migrates device ciphertext into portable plaintext" {
    _prepare_v1_plain_worktree all || return 1
    local out="$CONFIG_DIR/migrated.json" received
    ! github_config_open "$GITHUB_WORKTREE" "$out" || return 1
    [[ "$GITHUB_LAST_FORMAT" == outdated && ! -e "$out" ]] || return 1
    CURRENT_VERSION=1.1.0 github_config_open "$GITHUB_WORKTREE" "$out" migrate || return 1
    jq -e --arg a "$PORTABLE_A" --arg pass "$PORTABLE_PASSWORD" '
        .vault_version==2 and .secrets.schema_version==2 and
        .minimum_remote_control_version=="1.1.0" and .portability.status=="ready" and
        .secrets.node_passwords[("node:"+$a+":ssh-password")]==$pass' "$out" || return 1
    jq -e --arg b "$PORTABLE_B" '.secrets.node_passwords[("node:"+$b+":ssh-password")]=="synthetic-second"' "$out"
}

@test "vault v1 migration marks undecryptable passwords as missing_secret" {
    _prepare_v1_plain_worktree partial || return 1
    local out="$CONFIG_DIR/migrated.json"
    github_config_open "$GITHUB_WORKTREE" "$out" migrate || return 1
    jq -e --arg a "$PORTABLE_A" --arg b "$PORTABLE_B" --arg pass "$PORTABLE_PASSWORD" '
        .portability=={status:"needs_setup",issues:[{node_id:$b,reason:"missing_secret"}]} and
        .secrets.node_passwords[("node:"+$a+":ssh-password")]==$pass and
        (.secrets.node_passwords|has("node:"+$b+":ssh-password")|not)' "$out"
}

@test "vault v1 migration failure leaves output untouched and reports invalid" {
    _prepare_v1_plain_worktree all || return 1
    local out="$CONFIG_DIR/migrated.json"
    jq '.schema_version=1' "$GITHUB_WORKTREE/config.json" > "$CONFIG_DIR/c.json" &&
        mv "$CONFIG_DIR/c.json" "$GITHUB_WORKTREE/config.json" || return 1
    printf 'previous-output\n' > "$out"
    ! github_config_open "$GITHUB_WORKTREE" "$out" migrate || return 1
    [[ "$GITHUB_LAST_FORMAT" == invalid && "$(cat "$out")" == previous-output ]] || return 1
    [[ -z "$(find "$CONFIG_DIR" -maxdepth 1 -name '.github-private.*')" ]]
}

@test "snapshot requiring a newer Remote Control is classified before format" {
    _prepare_plain_worktree || return 1
    git -C "$GITHUB_WORKTREE" init >/dev/null || return 1
    local out="$CONFIG_DIR/newer.json"
    jq '.minimum_remote_control_version="9.9.9" | .vault_version=1' "$GITHUB_WORKTREE/manifest.json" > "$CONFIG_DIR/m.json" &&
        mv "$CONFIG_DIR/m.json" "$GITHUB_WORKTREE/manifest.json" || return 1
    CURRENT_VERSION=1.1.0
    ! github_config_open "$GITHUB_WORKTREE" "$out" migrate || return 1
    [[ "$GITHUB_LAST_FORMAT" == newer && "$GITHUB_LAST_FORMAT_REQUIRED" == 9.9.9 && ! -e "$out" ]]
}

@test "serializer pins minimum version to the vault format, not the script version" {
    _portable_password_runtime || return 1
    CURRENT_VERSION=1.2.3
    github_config_serialize "$CONFIG_DIR/pinned.json" "$CONFIG_JSON" || return 1
    jq -e '.minimum_remote_control_version=="1.1.0" and .vault_version==2' "$CONFIG_DIR/pinned.json"
}

@test "portable password invalid container does not replace serialized output or source ciphertext" {
    _portable_password_runtime || return 1
    local out="$CONFIG_DIR/prior-output.json" before
    printf 'previous-output\n' > "$out"
    chmod 640 "$out"
    printf '{"schema_version":1,"node_passwords":[]}\n' > "$SECRETS_JSON"
    before=$(cat "$SECRETS_JSON")
    run github_config_serialize "$out" "$CONFIG_JSON"
    assert_failure
    [[ "$(cat "$out")" == previous-output && "$(_file_mode "$out")" == 640 ]] || return 1
    [[ "$(cat "$SECRETS_JSON")" == "$before" ]]
}

@test "portable password unsupported checkpoint preserves the published tree" {
    _prepare_plain_worktree || return 1
    local version before="$CONFIG_DIR/prior-tree"
    cp -Rp "$GITHUB_WORKTREE" "$before"
    for version in 1 55; do
        jq --argjson version "$version" '.vault_version=$version' "$CONFIG_DIR/state.json" > "$CONFIG_DIR/unsupported.json"
        run github_config_checkpoint "$CONFIG_DIR/unsupported.json"
        assert_failure
        diff -r "$before" "$GITHUB_WORKTREE" || return 1
    done
}

# ─── security round 1: github (S-M10, S-M11) ────────────────────────────────

# Расшифрованные ключи age сеанса в CONFIG_DIR.
_session_keys_left() {
    find "$CONFIG_DIR" \( -name output -o -name '.recovery-key.*' -o -name '.unlock-check.*' \) -print
}

@test "import-recovery-key removes the previous session key and close leaves no decrypted key" {
    _configure_managed_recovery_roots
    local external="$BATS_TEST_TMPDIR/external" first second
    mkdir -p "$external" || return 1
    printf 'AGE-SECRET-KEY-RECOVERY\n' > "$external/recovery.key"
    printf '#!/bin/bash\n[[ "$1" == -y ]] && grep -q AGE-SECRET "$2" && echo age1x\n' > "$external/keygen"
    chmod +x "$external/keygen" || return 1
    AGE_KEYGEN_BIN="$external/keygen"
    # Ключ сеанса после разблокировки паролем: .github-private.*/output.
    first=$(_github_new_private_path "$CONFIG_DIR/.unlock-check.XXXXXX") || return 1
    printf 'AGE-SECRET-KEY-DECRYPTED\n' > "$first"
    GITHUB_IDENTITY="$first"
    github_config_import_recovery "$external/recovery.key" || return 1
    [[ ! -e "$first" && ! -e "$(dirname "$first")" ]] || return 1
    second="$GITHUB_IDENTITY"
    github_config_import_recovery "$external/recovery.key" || return 1
    [[ ! -e "$second" && -f "$GITHUB_IDENTITY" ]] || return 1
    GITHUB_WORKTREE="" GITHUB_SESSION_ID=""
    github_config_close || return 1
    [ -z "$(_session_keys_left)" ]
    # Сохранённый на устройстве ключ импорт не удаляет.
    mkdir -p "$(dirname "$GITHUB_UNLOCK_FILE")"
    printf 'AGE-SECRET-KEY-REMEMBERED\n' > "$GITHUB_UNLOCK_FILE"
    GITHUB_IDENTITY="$GITHUB_UNLOCK_FILE"
    github_config_import_recovery "$external/recovery.key" || return 1
    [ "$(cat "$GITHUB_UNLOCK_FILE")" = AGE-SECRET-KEY-REMEMBERED ]
}

@test "unlock by password removes an imported key that does not fit the vault" {
    local bin="$BATS_TEST_TMPDIR/age-bin" imported="$CONFIG_DIR/.recovery-key.test"
    mkdir -p "$bin" "$CONFIG_DIR/worktree" || return 1
    cat > "$bin/age-keygen" <<'EOF'
#!/bin/bash
[[ "$1" == -y ]] || exit 1
case "$(cat "$2")" in
    AGE-SECRET-KEY-OTHER) printf 'age1other\n' ;;
    AGE-SECRET-KEY-DECRYPTED) printf 'age1vault\n' ;;
    *) exit 1 ;;
esac
EOF
    cat > "$bin/age" <<'EOF'
#!/bin/bash
# Пароль доступа приходит только через batchpass fd 9, не stdin.
[[ $# -eq 6 && "$1" == -d && "$2" == -j && "$3" == batchpass && "$4" == -o ]] || exit 1
[[ "${AGE_PASSPHRASE_FD:-}" == 9 && /dev/fd/0 -ef /dev/null ]] || exit 1
IFS= read -r pw <&9 || [[ -n "$pw" ]] || exit 1
[[ "$pw" == vault-pass && "$(cat "$6")" == encrypted-unlock ]] || exit 1
out="$5"
printf 'AGE-SECRET-KEY-DECRYPTED\n' > "$out"
EOF
    chmod +x "$bin/age" "$bin/age-keygen" || return 1
    printf 'encrypted-unlock\n' > "$CONFIG_DIR/worktree/unlock.age"
    printf 'age1vault\n' > "$CONFIG_DIR/worktree/recipient.txt"
    printf 'AGE-SECRET-KEY-OTHER\n' > "$imported"
    AGE_BIN="$bin/age" AGE_KEYGEN_BIN="$bin/age-keygen"
    GITHUB_WORKTREE="$CONFIG_DIR/worktree" GITHUB_IDENTITY="$imported"
    GITHUB_SECRET_VAULT_PASSWORD=vault-pass
    local recipient rc
    for recipient in '' age1mismatched; do
        printf '%s\n' "$recipient" > "$GITHUB_WORKTREE/recipient.txt"
        rc=0
        github_config_unlock </dev/null || rc=$?
        [[ "$rc" -ne 0 && "$GITHUB_LAST_FORMAT" == invalid ]] || return 1
        [[ "$GITHUB_IDENTITY" == "$imported" &&
           "$(cat "$imported")" == AGE-SECRET-KEY-OTHER ]] || return 1
        [[ "$(_session_keys_left)" == "$imported" ]] || return 1
    done
    printf 'age1vault\n' > "$GITHUB_WORKTREE/recipient.txt"
    github_config_unlock </dev/null || return 1
    [[ ! -e "$imported" ]] || return 1
    [ "$(cat "$GITHUB_IDENTITY")" = AGE-SECRET-KEY-DECRYPTED ]
    GITHUB_WORKTREE="" GITHUB_SESSION_ID=""
    github_config_close || return 1
    [ -z "$(_session_keys_left)" ]
}

@test "config close removes a plaintext runtime-vault.json left by older versions" {
    printf '{"secrets":"plaintext"}\n' > "$CONFIG_DIR/runtime-vault.json"
    GITHUB_WORKTREE="" GITHUB_SESSION_ID="" GITHUB_IDENTITY=""
    github_config_close || return 1
    [[ ! -e "$CONFIG_DIR/runtime-vault.json" ]]
}

# ─── round 2: github (keys) ─────────────────────────────────────────────────

# In-process core with a local bare repository behind the GitHub URL and a fake age
# that wraps unlock.age using batchpass fd 9 and binds native payloads to their
# recipient; age-keygen derives the recipient from the key, never opens scrypt.
_r2_age_core() {
    export REMOTE="$BATS_TEST_TMPDIR/r2-remote.git" GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/r2-gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    git init -q --bare -b main "$REMOTE" || return 1
    git config --global user.name test
    git config --global user.email test@example.invalid
    git config --global url."file://$REMOTE".insteadOf \
        "https://github.com/test-owner/essence-remote-control-config.git"
    mkdir -p "$BATS_TEST_TMPDIR/r2-bin"
    cat > "$BATS_TEST_TMPDIR/r2-bin/age-keygen" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == -y ]]; then
    k=$(grep -v '^#' "$2" | head -1); [[ "$k" == AGE-SECRET-KEY-* ]] || exit 1
    printf 'age1%s\n' "$(printf '%s' "$k" | sha256sum | cut -c1-20)"
else
    k="AGE-SECRET-KEY-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '# public key: age1%s\n%s\n' "$(printf '%s' "$k" | sha256sum | cut -c1-20)" "$k"
fi
EOF
    cat > "$BATS_TEST_TMPDIR/r2-bin/age" <<'EOF'
#!/bin/bash
out="" input="" mode="" identity="" recipient="" plugin=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|-d) [[ -z "$mode" ]] || exit 1; mode="$1"; shift ;;
        -j) [[ "$2" == batchpass ]] || exit 1; plugin="$2"; shift 2 ;;
        -i) identity="$2"; shift 2 ;;
        -r) recipient="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        -*) exit 1 ;;
        *) [[ -z "$input" ]] || exit 1; input="$1"; shift ;;
    esac
done
[[ -n "$out" && -s "$input" ]] || exit 1
if [[ -n "$plugin" ]]; then
    [[ -z "$identity$recipient" && "${AGE_PASSPHRASE_FD:-}" == 9 ]] || exit 1
    [[ /dev/fd/0 -ef /dev/null ]] || exit 1
    IFS= read -r pw <&9 || [[ -n "$pw" ]] || exit 1
fi
if [[ "$mode" != -d ]]; then
    if [[ "$plugin" == batchpass && "$mode" == -e ]]; then
        { printf 'FAKEPW:%s\n' "$pw"
          printf 'IDSHA:%s\n' "$(grep -v '^#' "$input" | head -1 | sha256sum | cut -c1-20)"
          cat "$input"; } > "$out"
    else
        [[ -n "$recipient" && -z "$plugin$identity" ]] || exit 1
        { printf 'FAKERECIPIENT:%s\n' "$recipient"; cat "$input"; } > "$out"
    fi
    exit 0
fi
first=$(head -1 "$input")
if [[ "$first" == FAKEPW:* ]]; then
    [[ "$plugin" == batchpass && -z "$identity" && "FAKEPW:$pw" == "$first" ]] || exit 1
    tail -n +3 "$input" > "$out"
else
    [[ -z "$plugin$recipient" && -s "$identity" ]] || exit 1
    public=$("$AGE_KEYGEN_BIN" -y "$identity") || exit 1
    [[ "$first" == "FAKERECIPIENT:$public" ]] || exit 1
    tail -n +2 "$input" > "$out"
fi
EOF
    chmod +x "$BATS_TEST_TMPDIR/r2-bin/age" "$BATS_TEST_TMPDIR/r2-bin/age-keygen"
    load '../helpers/cmd_helper'
    load_core
    ensure_age_batchpass() { return 0; }
    load '../helpers/mock_ssh'
    export AGE_BIN="$BATS_TEST_TMPDIR/r2-bin/age" AGE_KEYGEN_BIN="$BATS_TEST_TMPDIR/r2-bin/age-keygen"
    BUILTIN_TEMPLATES_DIR="$PROJECT_ROOT/remote-control/templates"
    _github_ensure_deps() { return 0; }
    _github_prepare_account() { return 0; }
    _github_gh() {
        shift
        case "$1 $2" in
            "api user") printf 'test-owner\n' ;;
            "repo view") printf '{"visibility":"PRIVATE"}\n' ;;
            *) return 1 ;;
        esac
    }
    load_fixture_template
    open_local_session
}

# _r2_age_connect [--remember-key] — new encrypted vault, access password vpw.
_r2_age_connect() {
    RC_REQUEST_SECRETS='{"new-vault-password":"vpw"}'
    run_cmd source github-connect --login test-owner --storage age --yes "$@"
    RC_REQUEST_SECRETS='{}'
    [ "$status" -eq 0 ] || { printf 'connect: %s\n' "$CMD_ENVELOPE"; return 1; }
}

# A native identity matches recipient.txt; it cannot decrypt scrypt unlock.age.
_r2_key_matches_recipient() {
    local public
    public=$("$AGE_KEYGEN_BIN" -y "$1") || return 1
    [[ "$public" == "$(tr -d '\r\n' < "$GITHUB_WORKTREE/recipient.txt")" ]]
}

@test "age mock enforces batchpass passwords and native recipient binding" {
    _r2_age_core
    _r2_age_connect
    local out="$BATS_TEST_TMPDIR/mock-decrypted" other="$BATS_TEST_TMPDIR/other.key"
    run "$AGE_BIN" -d -i "$GITHUB_IDENTITY" -o "$out" "$GITHUB_WORKTREE/unlock.age"
    assert_failure
    [[ ! -e "$out" ]] || return 1
    run "$AGE_BIN" -p -o "$out" "$GITHUB_IDENTITY"
    assert_failure
    [[ ! -e "$out" ]] || return 1
    run "$AGE_BIN" -d -j batchpass -o "$out" "$GITHUB_WORKTREE/unlock.age"
    assert_failure
    [[ ! -e "$out" ]] || return 1
    if printf '%s' wrong-password |
        _github_age_passphrase -d "$GITHUB_WORKTREE/unlock.age" "$out"; then
        return 1
    fi
    [[ ! -e "$out" ]] || return 1
    printf '%s' vpw | _github_age_passphrase -d "$GITHUB_WORKTREE/unlock.age" "$out" || return 1
    cmp -s "$GITHUB_IDENTITY" "$out" || return 1
    rm -f "$out"
    "$AGE_KEYGEN_BIN" > "$other" || return 1
    run "$AGE_BIN" -d -i "$other" -o "$out" "$GITHUB_WORKTREE/state.json.age"
    assert_failure
    [[ ! -e "$out" ]]
}

@test "R2-L11: connect --remember-key keeps the key of the new vault on this device" {
    _r2_age_core
    _r2_age_connect --remember-key
    [ -f "$GITHUB_UNLOCK_FILE" ]
    [ "$(_file_mode "$GITHUB_UNLOCK_FILE")" = 600 ]
    _r2_key_matches_recipient "$GITHUB_UNLOCK_FILE"
    run_cmd source status
    [ "$(cmd_jq -r .data.key_saved)" = true ]
}

@test "R2-L11: connect without --remember-key saves no key" {
    _r2_age_core
    _r2_age_connect
    [ ! -e "$GITHUB_UNLOCK_FILE" ]
}

@test "R2-M16: rotate-key replaces a saved key with the new one" {
    _r2_age_core
    _r2_age_connect --remember-key
    local old; old=$(cat "$GITHUB_UNLOCK_FILE")
    RC_REQUEST_SECRETS='{"new-vault-password":"vpw2"}'
    run_cmd source github-rotate-key --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$GITHUB_UNLOCK_FILE")" != "$old" ]
    cmp -s "$GITHUB_UNLOCK_FILE" "$GITHUB_IDENTITY"
    _r2_key_matches_recipient "$GITHUB_UNLOCK_FILE"
    run_cmd source status
    [ "$(cmd_jq -r .data.key_saved)" = true ]
}

@test "R2-M16: rotate-key saves no key when none was saved" {
    _r2_age_core
    _r2_age_connect
    RC_REQUEST_SECRETS='{"new-vault-password":"vpw2"}'
    run_cmd source github-rotate-key --yes
    [ "$status" -eq 0 ]
    [ ! -e "$GITHUB_UNLOCK_FILE" ]
}

@test "R2-M15: import-recovery-key rejects a key of another vault and keeps the working key" {
    _r2_age_core
    _r2_age_connect
    # Recovery keys must live outside CONFIG_DIR (which is BATS_TEST_TMPDIR here).
    local working="$GITHUB_IDENTITY" external="${BATS_RUN_TMPDIR:?}/r2-recovery-$BATS_TEST_NUMBER"
    mkdir -p "$external"
    "$AGE_KEYGEN_BIN" > "$external/other.key"
    run_cmd source github-import-recovery-key --file "$external/other.key"
    [ "$status" -eq 1 ]
    [ "$(cmd_jq -r .error.code)" = invalid ]
    [[ "$(cmd_jq -r .error.message)" == *"не подходит к текущему хранилищу"* ]]
    [ "$GITHUB_IDENTITY" = "$working" ] && [ -f "$working" ]
    [ -z "$(find "$CONFIG_DIR" -maxdepth 1 -name '.recovery-key.*')" ]
    cp "$working" "$external/own.key"
    run_cmd source github-import-recovery-key --file "$external/own.key"
    [ "$status" -eq 0 ]
    [ "$GITHUB_IDENTITY" != "$working" ]
    _r2_key_matches_recipient "$GITHUB_IDENTITY"
}

@test "batchpass password contract rejects trailing CR or LF without normalizing the secret" {
    local secret rc
    for secret in $'line-password\r' $'line-password\n'; do
        GITHUB_SECRET_NEW_VAULT_PASSWORD="$secret"
        rc_error_reset
        rc=0
        github_config_new_master || rc=$?
        [ "$rc" -eq 1 ]
        [ "$RC_ERROR_CODE" = invalid ]
        [ -z "${GITHUB_MASTER_PASSWORD:-}" ]
    done
}
