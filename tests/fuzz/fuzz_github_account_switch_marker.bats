#!/usr/bin/env bats

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-50}"

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module 'github-config.sh'
    export GITHUB_ACCOUNT_SWITCH_DIR="$BATS_TEST_TMPDIR/account-switch"
    export GITHUB_ACCOUNT_SWITCH_MARKER="$GITHUB_ACCOUNT_SWITCH_DIR/transaction.json"
    export GITHUB_ACCOUNT_SWITCH_OLD_REPO='test-owner/essence-remote-control-config'
    export GITHUB_ACCOUNT_SWITCH_NEW_REPO='other-owner/essence-remote-control-config'
    export GITHUB_ACCOUNT_SWITCH_BRANCH='main'
    export GITHUB_ACCOUNT_SWITCH_INITIAL_LOGIN='test-owner'
    mkdir -p "$GITHUB_ACCOUNT_SWITCH_DIR"
}

teardown() {
    teardown_test_env
}

@test "account switch marker accepts exact schema" {
    _github_account_switch_write_marker prepared '' true false false
    github_account_switch_marker_valid "$GITHUB_ACCOUNT_SWITCH_MARKER"
    local i
    for ((i = 1; i <= FUZZ_ITERATIONS; i++)); do
        if ((i % 2 == 0)); then
            jq '.phase = "invalid"' "$GITHUB_ACCOUNT_SWITCH_MARKER" > "$GITHUB_ACCOUNT_SWITCH_MARKER.tmp"
            mv "$GITHUB_ACCOUNT_SWITCH_MARKER.tmp" "$GITHUB_ACCOUNT_SWITCH_MARKER"
            ! github_account_switch_marker_valid "$GITHUB_ACCOUNT_SWITCH_MARKER"
            _github_account_switch_write_marker prepared '' true false false
        fi
    done
}

@test "marker validator rejects injection-shaped values" {
    jq -n '{version:1,phase:"prepared",old_repo:"../../etc/passwd",new_repo:"target/repo",branch:"main",initial_login:"test-owner",expected_head:null,old_state_available:true,repo_created:false,repo_privatized:false}' > "$GITHUB_ACCOUNT_SWITCH_MARKER"
    ! github_account_switch_marker_valid "$GITHUB_ACCOUNT_SWITCH_MARKER"
    jq -n '{version:1,phase:"prepared",old_repo:"test-owner/repo",new_repo:"target/repo",branch:"main",initial_login:"$(touch /tmp/pwned)",expected_head:null,old_state_available:true,repo_created:false,repo_privatized:false}' > "$GITHUB_ACCOUNT_SWITCH_MARKER"
    ! github_account_switch_marker_valid "$GITHUB_ACCOUNT_SWITCH_MARKER"
}
