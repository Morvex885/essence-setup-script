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

teardown() {
    local pid
    for pid in ${RACE_WORKERS:-}; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    teardown_test_env
}

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
    source "$PROJECT_ROOT/remote-control/modules/cli.sh"
    source "$PROJECT_ROOT/remote-control/modules/self.sh"
    source "$PROJECT_ROOT/remote-control/modules/cmd_core.sh"
    # Sandbox authentication, following cmd_system.bats; the removal command
    # core, wrapper and checkpoint remain the real implementations.
    _verify_pass() { [[ "$1" == "saved:$2" ]]; }
    printf 'saved:secret\n' > "$SCRIPT_AUTH_FILE"
    state_checkpoint || return 1
    cp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before"
    _inject_manifest_promotion_failure
    success() { printf '%s\n' "$*" >> "$SUCCESS_EVENTS"; }

    RC_REQUEST_SECRETS='{"current-password":"secret"}'
    RC_CONFIRM_YES=1
    run cli_cmd_self_password_remove
    assert_failure
    [[ ! -e "$SCRIPT_AUTH_FILE" && ! -e "$SUCCESS_EVENTS" ]] || return 1
    cmp "$STATE_MANIFEST" "$BATS_TEST_TMPDIR/manifest.before" || return 1
    [[ "$(cat "$MANIFEST_ATTEMPTS")" == rejected ]] || return 1
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

@test "password removal command with state wrapper stays available after applied removal and late failure" {
    _password_removal_late_failure state
}

@test "password removal command with GitHub override stays available after applied removal and late failure" {
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

_wait_lock_race_event() {
    local i
    for ((i=0; i<500; i++)); do
        [[ -e "$1" || ( -n "${2:-}" && -e "$2" ) ]] && return 0
        sleep 0.02
    done
    return 1
}

_concurrent_stale_reclaimers() {
    export RACE_DIR="$BATS_TEST_TMPDIR/race" PROJECT_ROOT RACE_PAUSE="$1"
    mkdir "$RACE_DIR" "$CONFIG_DIR/.rc-lock"
    sleep 0 &
    local dead=$! delayed owner before
    wait "$dead"
    export DEAD_PID="$dead"
    printf 'pid=%s\nkind=mutation\nlabel=dead\n' "$dead" > "$CONFIG_DIR/.rc-lock/owner"
    cat > "$RACE_DIR/worker.sh" <<'EOF'
source "$PROJECT_ROOT/common/common.sh"
source "$PROJECT_ROOT/remote-control/modules/state.sh"
role="$1"
wait_event() {
    local i
    for ((i=0; i<500; i++)); do
        [[ -e "$1" ]] && return 0
        sleep 0.02
    done
    return 1
}
if [[ "$role" == delayed ]]; then
    kill() {
        if [[ "$RACE_PAUSE" == probe && "$1" == -0 && "$2" == "$DEAD_PID" && ! -e "$RACE_DIR/probed" ]]; then
            : > "$RACE_DIR/probed"
            wait_event "$RACE_DIR/resume" || return 1
            return 1
        fi
        builtin kill "$@"
    }
    mkdir() {
        if [[ "$RACE_PAUSE" == election && "$1" == .reclaim && ! -e "$RACE_DIR/probed" ]]; then
            : > "$RACE_DIR/probed"
            wait_event "$RACE_DIR/resume" || return 1
        fi
        command mkdir "$@"
    }
    mv() {
        command mv "$@" || return
        # Expose the unlocked interval even if an implementation attempts to
        # detect and restore a live owner only after renaming its directory.
        if [[ "$1" == "$CONFIG_DIR/.rc-lock" && -f "$2/owner" ]] &&
            [[ "$(_rc_lock_owner_field "$2/owner" pid)" == "$(cat "$RACE_DIR/owner.pid")" ]]; then
            : > "$RACE_DIR/moved-live"
            wait_event "$RACE_DIR/third.finished"
        fi
    }
fi
critical() {
    mkdir "$RACE_DIR/active" 2>/dev/null || : > "$RACE_DIR/overlap"
    jq_w --arg name "$role" '.groups += [{name:$name,template:"default.yaml"}]' || return 1
    : > "$RACE_DIR/$role.entered"
    if [[ "$role" == owner ]]; then
        wait_event "$RACE_DIR/release-owner" || return 1
    fi
    rmdir "$RACE_DIR/active" 2>/dev/null || true
}
RC_LOCK_WAIT=0
state_action "$role" critical
printf '%s\n' "$?" > "$RACE_DIR/$role.result"
EOF
    bash "$RACE_DIR/worker.sh" delayed > "$RACE_DIR/delayed.log" 2>&1 &
    delayed=$!
    RACE_WORKERS="$delayed"
    _wait_lock_race_event "$RACE_DIR/probed" || return 1
    bash "$RACE_DIR/worker.sh" owner > "$RACE_DIR/owner.log" 2>&1 &
    owner=$!
    RACE_WORKERS="$RACE_WORKERS $owner"
    printf '%s\n' "$owner" > "$RACE_DIR/owner.pid"
    _wait_lock_race_event "$RACE_DIR/owner.entered" || return 1
    before=$(cat "$CONFIG_DIR/.rc-lock/owner")
    if [[ "$RACE_PAUSE" == election ]]; then
        mkdir "$CONFIG_DIR/.rc-lock/.reclaim" || return 1
    fi
    : > "$RACE_DIR/resume"
    _wait_lock_race_event "$RACE_DIR/delayed.result" "$RACE_DIR/moved-live" || return 1
    bash "$RACE_DIR/worker.sh" third > "$RACE_DIR/third.log" 2>&1
    : > "$RACE_DIR/third.finished"
    wait "$delayed" || return 1
    [[ "$(cat "$RACE_DIR/delayed.result")" == 1 ]] || return 1
    [[ "$(cat "$RACE_DIR/third.result")" == 1 ]] || return 1
    [[ ! -e "$RACE_DIR/overlap" && ! -e "$RACE_DIR/moved-live" ]] || return 1
    [[ "$(cat "$CONFIG_DIR/.rc-lock/owner")" == "$before" ]] || return 1
    if [[ "$RACE_PAUSE" == election ]]; then
        [[ -d "$CONFIG_DIR/.rc-lock/.reclaim" ]] || return 1
        rmdir "$CONFIG_DIR/.rc-lock/.reclaim" || return 1
    fi
    : > "$RACE_DIR/release-owner"
    wait "$owner" || return 1
    RACE_WORKERS=
    [[ "$(cat "$RACE_DIR/owner.result")" == 0 && ! -e "$CONFIG_DIR/.rc-lock" ]] || return 1
    jq -e '[.groups[].name | select(. == "owner" or . == "delayed" or . == "third")] == ["owner"]' \
        "$CONFIG_JSON" >/dev/null || return 1
    state_validate false
}

@test "cached stale PID never displaces a live owner or overlaps three state actions" {
    _concurrent_stale_reclaimers probe
}

@test "reclaimer paused in an old directory never touches a replacement lock election" {
    _concurrent_stale_reclaimers election
}

@test "nested acquisition retains a promoted session lock until release all" {
    rc_lock_acquire mutation outer || return 1
    rc_lock_acquire session inner || return 1
    [[ "$_RC_LOCK_DEPTH" == 2 && "$_RC_LOCK_SESSION" == 1 ]] || return 1
    rc_lock_release
    rc_lock_release
    [[ "$_RC_LOCK_DEPTH" == 0 && -d "$CONFIG_DIR/.rc-lock" ]] || return 1
    run bash -c 'source "$1/remote-control/modules/state.sh"
        warn() { :; }
        sleep() { exit 91; }
        RC_LOCK_WAIT=600
        rc_lock_acquire mutation contender || { printf "%s\n" "$RC_ERROR_CODE"; exit 1; }' _ "$PROJECT_ROOT"
    assert_failure
    assert_output locked
    rc_lock_release_all
    [[ "$_RC_LOCK_DEPTH" == 0 && "$_RC_LOCK_SESSION" == 0 && ! -e "$CONFIG_DIR/.rc-lock" ]]
}

@test "TERM during election removes only the claimed guard and preserves reclaimable state" {
    sleep 0 &
    local dead=$!
    wait "$dead"
    mkdir "$CONFIG_DIR/.rc-lock"
    printf 'pid=%s\nkind=mutation\nlabel=dead\n' "$dead" > "$CONFIG_DIR/.rc-lock/owner"
    cp "$CONFIG_DIR/.rc-lock/owner" "$BATS_TEST_TMPDIR/owner.before"
    run bash -c 'source "$1/remote-control/modules/state.sh"
        mkdir() {
            command mkdir "$@" || return
            if [[ "$1" == .reclaim ]]; then
                sh -c '\''kill -TERM "$PPID"'\''
            fi
        }
        _rc_lock_reclaim "$CONFIG_DIR/.rc-lock"' _ "$PROJECT_ROOT"
    assert_failure
    [[ ! -e "$CONFIG_DIR/.rc-lock/.reclaim" ]] || return 1
    cmp "$CONFIG_DIR/.rc-lock/owner" "$BATS_TEST_TMPDIR/owner.before" || return 1
    RC_LOCK_WAIT=0 state_action recovered _change_local_state || return 1
    [[ ! -e "$CONFIG_DIR/.rc-lock" ]] || return 1
    jq -e 'any(.groups[]; .name == "CHECKPOINT")' "$CONFIG_JSON" >/dev/null
}

@test "reclaim preserves ignored INT during election and rename and still applies the mutation" {
    local phase dead
    for phase in election rename; do
        sleep 0 &
        dead=$!
        wait "$dead"
        mkdir "$CONFIG_DIR/.rc-lock"
        printf 'pid=%s\nkind=mutation\nlabel=dead\n' "$dead" > "$CONFIG_DIR/.rc-lock/owner"
        run bash -c 'source "$1/remote-control/modules/state.sh"
            phase="$2"; event="$3"
            warn() { :; }
            trap "" INT
            ignored_int=$(trap -p INT)
            mkdir() {
                command mkdir "$@" || return
                if [[ "$phase" == election && "$1" == .reclaim ]]; then
                    sh -c '\''kill -INT "$PPID"'\''
                fi
            }
            mv() {
                if [[ "$phase" == rename && "$1" == "$CONFIG_DIR/.rc-lock" ]]; then
                    sh -c '\''kill -INT "$PPID"'\''
                fi
                command mv "$@"
            }
            apply() { printf "applied\n" > "$event"; }
            RC_LOCK_WAIT=0
            rc_locked reclaimed apply || exit 1
            [[ "$(trap -p INT)" == "$ignored_int" ]]' \
            _ "$PROJECT_ROOT" "$phase" "$BATS_TEST_TMPDIR/$phase.applied"
        assert_success
        [[ "$(cat "$BATS_TEST_TMPDIR/$phase.applied")" == applied ]] || return 1
        [[ ! -e "$CONFIG_DIR/.rc-lock" ]] || return 1
    done
}
