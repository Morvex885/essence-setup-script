#!/usr/bin/env bats

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
    [[ "$(cat "$GITHUB_WORKTREE/config.json")" == "prior-config" ]]
    [[ "$(cat "$GITHUB_WORKTREE/secrets.json")" == "prior-secrets" ]]
    [[ "$(cat "$GITHUB_WORKTREE/manifest.json")" == "prior-manifest" ]]
    [[ "$(cat "$GITHUB_WORKTREE/ssh/known_hosts")" == "prior-known-host" ]]
    [[ "$(cat "$GITHUB_WORKTREE/templates/prior.yaml")" == "prior-template" ]]
    [[ "$(cat "$GITHUB_WORKTREE/ssh/identities/00000000000000000000000000000000")" == "prior-identity" ]]
}


@test "storage mode prompt requires an explicit choice" {
    run "${BASH:-bash}" -c "source '$PROJECT_ROOT/common/common.sh'; source '$PROJECT_ROOT/remote-control/modules/github-config.sh'; printf 'x\n2\n' | _github_prompt_storage_mode"
    assert_success
    [[ "$output" == *$'\033[0;32m1)\033[0m Зашифровать паролем'* ]]
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
    [[ -f "$GITHUB_WORKTREE/storage.json" ]]
    [[ -f "$GITHUB_WORKTREE/config.json" ]]
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
    _assert_prior_plain_tree

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
    [[ ! -e "$ephemeral" ]]

    mkdir -p "$(dirname "$GITHUB_UNLOCK_FILE")"
    printf remembered > "$GITHUB_UNLOCK_FILE"
    GITHUB_IDENTITY="$GITHUB_UNLOCK_FILE"
    github_config_close
    [[ -f "$GITHUB_UNLOCK_FILE" ]]
}

@test "remember and forget unlock use private local credentials" {
    local identity="$CONFIG_DIR/id"
    printf 'AGE-SECRET-KEY-TEST\n' > "$identity"
    github_config_remember "$identity"
    [[ -f "$GITHUB_UNLOCK_FILE" ]]
    [[ "$(_file_mode "$GITHUB_UNLOCK_FILE")" == 600 ]]
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
    [[ "$GITHUB_LAST_AUTH_RELEVANT" == false ]]
    [[ ! -e "$gh_calls" ]]
}
