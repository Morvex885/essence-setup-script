#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "command substitution cleans its own resource without closing the parent" {
    run /bin/bash -s -- "$PROJECT_ROOT" "$BATS_TEST_TMPDIR" <<'SH'
source "$1/common/common.sh"
parent="$2/parent"
child="$2/child"
touch "$parent" "$child" || exit 80
cleanup_parent() { rm "$parent"; }
cleanup_child() { rm "$child"; }
register_exit_cleanup cleanup_parent || exit 81
response=$(
    register_exit_cleanup cleanup_child || exit 82
    [[ -f "$parent" && -f "$child" ]] || exit 83
    printf 'ready'
) || exit 84
[[ "$response" == ready && -f "$parent" && ! -e "$child" ]] || exit 85
SH
    assert_success
    [[ ! -e "$BATS_TEST_TMPDIR/parent" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/child" ]]
}

@test "nested command substitutions clean each level only after its owner exits" {
    run /bin/bash -s -- "$PROJECT_ROOT" "$BATS_TEST_TMPDIR" <<'SH'
source "$1/common/common.sh"
parent="$2/parent"
child="$2/child"
nested="$2/nested"
touch "$parent" "$child" "$nested" || exit 80
cleanup_parent() { rm "$parent"; }
cleanup_child() { rm "$child"; }
cleanup_nested() { rm "$nested"; }
register_exit_cleanup cleanup_parent || exit 81
response=$(
    register_exit_cleanup cleanup_child || exit 82
    nested_response=$(
        register_exit_cleanup cleanup_nested || exit 83
        [[ -f "$parent" && -f "$child" && -f "$nested" ]] || exit 84
        printf 'nested-ready'
    ) || exit 85
    [[ "$nested_response" == nested-ready ]] || exit 86
    [[ -f "$parent" && -f "$child" && ! -e "$nested" ]] || exit 87
    printf 'ready'
) || exit 88
[[ "$response" == ready && -f "$parent" ]] || exit 89
[[ ! -e "$child" && ! -e "$nested" ]] || exit 90
SH
    assert_success
    [[ ! -e "$BATS_TEST_TMPDIR/parent" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/child" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/nested" ]]
}

@test "parenthesized child cleanup leaves its parent's resource alive" {
    run /bin/bash -s -- "$PROJECT_ROOT" "$BATS_TEST_TMPDIR" <<'SH'
source "$1/common/common.sh"
parent="$2/parent"
child="$2/child"
touch "$parent" "$child" || exit 80
cleanup_parent() { rm "$parent"; }
cleanup_child() { rm "$child"; }
register_exit_cleanup cleanup_parent || exit 81
(
    register_exit_cleanup cleanup_child || exit 82
    [[ -f "$parent" && -f "$child" ]] || exit 83
) || exit 84
[[ -f "$parent" && ! -e "$child" ]] || exit 85
SH
    assert_success
    [[ ! -e "$BATS_TEST_TMPDIR/parent" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/child" ]]
}

@test "background child cleanup finishes at wait without closing the parent" {
    run /bin/bash -s -- "$PROJECT_ROOT" "$BATS_TEST_TMPDIR" <<'SH'
source "$1/common/common.sh"
parent="$2/parent"
child="$2/child"
touch "$parent" "$child" || exit 80
cleanup_parent() { rm "$parent"; }
cleanup_child() { rm "$child"; }
register_exit_cleanup cleanup_parent || exit 81
(
    register_exit_cleanup cleanup_child || exit 82
    [[ -f "$parent" && -f "$child" ]] || exit 83
) &
child_pid=$!
wait "$child_pid" || exit 84
[[ -f "$parent" && ! -e "$child" ]] || exit 85
SH
    assert_success
    [[ ! -e "$BATS_TEST_TMPDIR/parent" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/child" ]]
}

@test "pipeline child cleanup does not release the parent's resource" {
    run /bin/bash -s -- "$PROJECT_ROOT" "$BATS_TEST_TMPDIR" <<'SH'
source "$1/common/common.sh"
set -o pipefail
parent="$2/parent"
child="$2/child"
touch "$parent" "$child" || exit 80
cleanup_parent() { rm "$parent"; }
cleanup_child() { rm "$child"; }
register_exit_cleanup cleanup_parent || exit 81
(
    register_exit_cleanup cleanup_child || exit 82
    [[ -f "$parent" && -f "$child" ]] || exit 83
) | cat || exit 84
[[ -f "$parent" && ! -e "$child" ]] || exit 85
SH
    assert_success
    [[ ! -e "$BATS_TEST_TMPDIR/parent" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/child" ]]
}

@test "inherited cleanup name can be registered for a different child resource" {
    run /bin/bash -s -- "$PROJECT_ROOT" "$BATS_TEST_TMPDIR" <<'SH'
source "$1/common/common.sh"
parent="$2/parent"
child="$2/child"
touch "$parent" "$child" || exit 80
resource="$parent"
cleanup_resource() { rm "$resource"; }
register_exit_cleanup cleanup_resource || exit 81
response=$(
    resource="$child"
    register_exit_cleanup cleanup_resource || exit 82
    [[ -f "$parent" && -f "$child" ]] || exit 83
    printf 'ready'
) || exit 84
[[ "$response" == ready && -f "$parent" && ! -e "$child" ]] || exit 85
[[ "$resource" == "$parent" ]] || exit 86
SH
    assert_success
    [[ ! -e "$BATS_TEST_TMPDIR/parent" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/child" ]]
}

@test "cleanup runs once per registration name in reverse order" {
    run /bin/bash -s -- "$PROJECT_ROOT" "$BATS_TEST_TMPDIR" <<'SH'
source "$1/common/common.sh"
resource_dir="$2/resource-dir"
resource_file="$resource_dir/resource"
failed_removal="$2/failed-removal"
mkdir "$resource_dir" && touch "$resource_file" || exit 80
cleanup_directory() {
    rmdir "$resource_dir" || { touch "$failed_removal"; return 1; }
}
cleanup_file() {
    rm "$resource_file" || { touch "$failed_removal"; return 1; }
}
register_exit_cleanup cleanup_directory || exit 81
register_exit_cleanup cleanup_file || exit 82
register_exit_cleanup cleanup_directory || exit 83
register_exit_cleanup cleanup_file || exit 84
[[ -d "$resource_dir" && -f "$resource_file" ]] || exit 85
SH
    assert_success
    [[ ! -e "$BATS_TEST_TMPDIR/resource-dir/resource" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/resource-dir" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/failed-removal" ]]
}

@test "exit status 37 survives a failed cleanup and independent resources are released" {
    run /bin/bash -s -- "$PROJECT_ROOT" "$BATS_TEST_TMPDIR" <<'SH'
source "$1/common/common.sh"
independent="$2/independent"
blocked="$2/nonempty-directory"
attempted="$2/failed-cleanup-attempted"
mkdir "$blocked" && touch "$blocked/retained" "$independent" || exit 80
cleanup_independent() { rm "$independent"; }
cleanup_blocked() {
    touch "$attempted"
    rmdir "$blocked"
}
register_exit_cleanup cleanup_independent || exit 81
register_exit_cleanup cleanup_blocked || exit 82
exit 37
SH
    assert_failure 37
    [[ -f "$BATS_TEST_TMPDIR/failed-cleanup-attempted" ]]
    [[ -f "$BATS_TEST_TMPDIR/nonempty-directory/retained" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/independent" ]]
}

@test "invalid function registration fails without losing existing cleanups" {
    run /bin/bash -s -- "$PROJECT_ROOT" "$BATS_TEST_TMPDIR" <<'SH'
source "$1/common/common.sh"
resource="$2/resource"
touch "$resource" || exit 80
cleanup_resource() { rm "$resource"; }
register_exit_cleanup cleanup_resource || exit 81
if register_exit_cleanup nonexistent_cleanup_function; then
    exit 82
fi
[[ -f "$resource" ]] || exit 83
SH
    assert_success
    [[ ! -e "$BATS_TEST_TMPDIR/resource" ]]
}
