#!/usr/bin/env bats
# Tests for subscription TTL and cleanup script

setup() {
    load '../helpers/test_helper'
    setup_test_env

    # Create a mock subscription directory
    export SUB_DIR="$BATS_TEST_TMPDIR/essence-sub"
    mkdir -p "$SUB_DIR"
}

teardown() {
    teardown_test_env
}

_run_cleanup() {
    local LIST="$SUB_DIR/expiry.list"
    local NOW
    NOW=$(date +%s)
    [[ -f "$LIST" ]] || return 0
    (
        while read -r token expires; do
            [[ -z "$token" ]] && continue
            if [[ "$expires" -le "$NOW" ]]; then
                rm -f "${SUB_DIR}/${token}.yaml"
            else
                printf '%s %s\n' "$token" "$expires"
            fi
        done < "$LIST" > "${LIST}.tmp"
        mv "${LIST}.tmp" "$LIST"
    )
}

@test "cleanup removes expired files" {
    local token="aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aabb7788ccdd99ee"
    echo "test content" > "$SUB_DIR/${token}.yaml"
    local past_ts=$(($(date +%s) - 3600))
    echo "$token $past_ts" > "$SUB_DIR/expiry.list"

    _run_cleanup

    [ ! -f "$SUB_DIR/${token}.yaml" ]
}

@test "cleanup keeps non-expired files" {
    local token="bbbb1111cccc2222dddd3333eeee4444ffff5555aaaa6666bbcc7788ddee99ff"
    echo "test content" > "$SUB_DIR/${token}.yaml"
    local future_ts=$(($(date +%s) + 3600))
    echo "$token $future_ts" > "$SUB_DIR/expiry.list"

    _run_cleanup

    [ -f "$SUB_DIR/${token}.yaml" ]
}

@test "cleanup updates expiry.list" {
    local expired="aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aabb7788ccdd99ee"
    local valid="bbbb1111cccc2222dddd3333eeee4444ffff5555aaaa6666bbcc7788ddee99ff"
    echo "expired" > "$SUB_DIR/${expired}.yaml"
    echo "valid" > "$SUB_DIR/${valid}.yaml"

    local past_ts=$(($(date +%s) - 3600))
    local future_ts=$(($(date +%s) + 3600))
    printf '%s %s\n%s %s\n' "$expired" "$past_ts" "$valid" "$future_ts" > "$SUB_DIR/expiry.list"

    _run_cleanup

    # Only valid token remains in expiry.list
    run wc -l < "$SUB_DIR/expiry.list"
    assert_output "1"
    run grep -c "$valid" "$SUB_DIR/expiry.list"
    assert_output "1"
}

@test "cleanup handles empty expiry.list" {
    touch "$SUB_DIR/expiry.list"
    _run_cleanup
    # Should not error
    [ -f "$SUB_DIR/expiry.list" ]
}

@test "cleanup handles missing expiry.list" {
    run _run_cleanup
    assert_success
}

@test "files without expiry.list entries are not touched" {
    local token="cccc1111dddd2222eeee3333ffff4444aaaa5555bbbb6666ccdd7788eeff99aa"
    echo "permanent" > "$SUB_DIR/${token}.yaml"
    # No expiry.list at all

    _run_cleanup

    [ -f "$SUB_DIR/${token}.yaml" ]
}
