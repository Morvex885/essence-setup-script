#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    export CONFIG_SOURCE=local
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
    source_common
    source_module 'state.sh'
    load_fixture_template
    state_open_local || return 1
    REAL_MV=$(command -v mv)
    MANIFEST_ATTEMPTS="$BATS_TEST_TMPDIR/manifest-attempts"
    SUCCESS_EVENTS="$BATS_TEST_TMPDIR/success-events"
}

teardown() { teardown_test_env; }

# Source the actual override only when that wrapper is under test. No copied
# wrapper bodies: the state-only cases must also work without github-config.sh.
_select_wrapper() {
    if [[ "$1" == github ]]; then
        source "$PROJECT_ROOT/remote-control/modules/github-config.sh"
    fi
}

_inject_manifest_promotion_failure() {
    mv() {
        if [[ "$#" -eq 2 && "$1" == "${STATE_MANIFEST}.tmp."* && "$2" == "$STATE_MANIFEST" ]]; then
            printf 'rejected\n' >> "$MANIFEST_ATTEMPTS"
            return 77
        fi
        "$REAL_MV" "$@"
    }
}

_change_local_state() {
    jq_w '.groups += [{name:"CHECKPOINT",template:"default.yaml"}]' || return 1
    printf '%s\n' '$6$new$hash' > "$SCRIPT_AUTH_FILE"
}

_late_manifest_failure() {
    _select_wrapper "$1"
    printf '%s\n' '$6$old$hash' > "$SCRIPT_AUTH_FILE"
    state_checkpoint || return 1
    cp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    _inject_manifest_promotion_failure

    run state_action change_group _change_local_state
    assert_failure
    jq -e 'any(.groups[]; .name == "CHECKPOINT")' "$CONFIG_JSON" >/dev/null || return 1
    [[ "$(cat "$SCRIPT_AUTH_FILE")" == '$6$new$hash' ]] || return 1
    cmp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before" || return 1
    [[ "$(cat "$MANIFEST_ATTEMPTS")" == rejected ]]
}

_leaf_failure() {
    _select_wrapper "$1"
    cp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before"
    cp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    _inject_manifest_promotion_failure
    _reject_change() { return 42; }

    run state_action reject_change _reject_change
    assert_equal "$status" 42
    [[ ! -e "$MANIFEST_ATTEMPTS" ]] || return 1
    cmp "$CONFIG_JSON" "$BATS_TEST_TMPDIR/config.before" || return 1
    cmp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
}

_successful_local_change() {
    _select_wrapper "$1"
    printf '%s\n' '$6$old$hash' > "$SCRIPT_AUTH_FILE"
    state_checkpoint || return 1

    run state_action change_group _change_local_state
    assert_success
    jq -e 'any(.groups[]; .name == "CHECKPOINT")' "$CONFIG_JSON" >/dev/null || return 1
    jq -e '.schema_version == 2 and .access.script_password_hash == "$6$new$hash"' \
        "$STATE_MANIFEST" >/dev/null || return 1
    state_validate false
}

_password_removal_late_failure() {
    _select_wrapper "$1"
    source "$PROJECT_ROOT/remote-control/modules/self.sh"
    # Sandbox authentication, following ui_remote_ops.bats; the menu, removal,
    # wrapper and checkpoint remain the real implementations.
    _verify_pass() { [[ "$1" == "saved:$2" ]]; }
    printf 'saved:secret\n' > "$SCRIPT_AUTH_FILE"
    state_checkpoint || return 1
    cp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    _inject_manifest_promotion_failure
    success() { printf '%s\n' "$*" >> "$SUCCESS_EVENTS"; }

    run set_script_password <<< $'2\nsecret\ny\nx\n0'
    assert_success
    [[ ! -e "$SCRIPT_AUTH_FILE" && ! -e "$SUCCESS_EVENTS" ]] || return 1
    cmp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before" || return 1
    [[ "$(cat "$MANIFEST_ATTEMPTS")" == rejected ]] || return 1
    # The redraw reflects the already-applied removal and accepts another menu
    # command instead of exiting or retrying the failed persistence operation.
    assert_output --partial 'Пароль: не установлен'
    assert_output --partial 'Неверный выбор.'
    refute_output --partial 'Не удалось удалить пароль.'
    refute_output --partial 'Пароль убран'
    refute_output --partial 'старый пароль'
    refute_output --partial 'пароль не изменён'
}

@test "state wrapper reports late manifest failure without rolling back applied JSON" {
    _late_manifest_failure state
}

@test "GitHub override in local mode reports late manifest failure without rolling back JSON" {
    _late_manifest_failure github
}

@test "state wrapper preserves leaf failure and does not checkpoint" {
    _leaf_failure state
}

@test "GitHub override in local mode preserves leaf failure and does not checkpoint" {
    _leaf_failure github
}

@test "state wrapper saves the requested JSON and updated manifest" {
    _successful_local_change state
}

@test "GitHub override in local mode saves the requested JSON and updated manifest" {
    _successful_local_change github
}

@test "password menu with state wrapper stays available after applied removal and late failure" {
    _password_removal_late_failure state
}

@test "password menu with GitHub override stays available after applied removal and late failure" {
    _password_removal_late_failure github
}

@test "GitHub push-only failure leaves requested JSON and committed worktree pending" {
    _select_wrapper github
    export GITHUB_REMOTE="$BATS_TEST_TMPDIR/remote.git"
    export GITHUB_STORE="$BATS_TEST_TMPDIR/store.git"
    export GITHUB_SESSIONS_DIR="$BATS_TEST_TMPDIR/sessions"
    GITHUB_BRANCH=main
    GITHUB_STORAGE_MODE=none
    GITHUB_WORKTREE= GITHUB_SESSION_ID= GITHUB_IDENTITY=
    git init --bare "$GITHUB_REMOTE" >/dev/null 2>&1 || return 1
    git init --bare "$GITHUB_STORE" >/dev/null 2>&1 || return 1
    git --git-dir="$GITHUB_STORE" remote add origin "$GITHUB_REMOTE" || return 1
    local tree seed before_remote
    tree=$(git --git-dir="$GITHUB_STORE" mktree </dev/null) || return 1
    seed=$(printf 'seed\n' | git --git-dir="$GITHUB_STORE" \
        -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree "$tree") || return 1
    git --git-dir="$GITHUB_STORE" update-ref refs/heads/main "$seed" || return 1
    _github_session_open_cached "$GITHUB_STORE" "$GITHUB_SESSIONS_DIR" main || return 1
    CONFIG_SOURCE=github
    _add_baseline_group() { jq_w '.groups += [{name:"BASELINE",template:"default.yaml"}]'; }
    state_action baseline _add_baseline_group || return 1
    before_remote=$(git --git-dir="$GITHUB_REMOTE" rev-parse refs/heads/main) || return 1
    # Reject only the server-side receive: checkpoint, serialization and local
    # commits remain real, and no network or SSH transport is involved.
    printf '#!/bin/sh\nexit 1\n' > "$GITHUB_REMOTE/hooks/pre-receive"
    chmod +x "$GITHUB_REMOTE/hooks/pre-receive"
    _add_pending_group() { jq_w '.groups += [{name:"PENDING",template:"default.yaml"}]'; }

    local rc=0
    state_action add_pending _add_pending_group > "$BATS_TEST_TMPDIR/push-output" 2>&1 || rc=$?
    [[ "$rc" -eq 0 && "$GITHUB_SYNC_STATUS" == pending ]] || return 1
    jq -e 'any(.groups[]; .name == "PENDING")' "$CONFIG_JSON" >/dev/null || return 1
    [[ -d "$GITHUB_WORKTREE" ]] || return 1
    git -C "$GITHUB_WORKTREE" show HEAD:config.json | \
        jq -e 'any(.groups[]; .name == "PENDING")' >/dev/null || return 1
    [[ -z "$(git -C "$GITHUB_WORKTREE" status --porcelain)" ]] || return 1
    [[ "$(git --git-dir="$GITHUB_REMOTE" rev-parse refs/heads/main)" == "$before_remote" ]] || return 1
    git --git-dir="$GITHUB_REMOTE" show main:config.json | \
        jq -e 'all(.groups[]; .name != "PENDING")' >/dev/null || return 1
    github_config_close
}
