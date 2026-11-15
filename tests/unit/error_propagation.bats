#!/usr/bin/env bats
# Operations report recoverable failures to their callers.

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/common/cert.sh"

}

teardown() {
    teardown_test_env
}

@test "ensure_acme_installed propagates installer failure" {
    HOME="$BATS_TEST_TMPDIR/home"
    curl() { return 1; }
    run ensure_acme_installed 'test@example.com'
    assert_failure
    assert_output --partial "Не удалось установить acme.sh."
}
