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

@test "gen_free_port returns failure without a bogus port" {
    is_port_free() { return 1; }
    run gen_free_port 1000 1001
    assert_failure
    assert_output --partial "Не удалось найти свободный порт"
}

@test "apt_wait returns failure when the lock recovery menu is cancelled" {
    fuser() { return 0; }
    sleep() { return 0; }
    _apt_lock_menu() { return 1; }
    run apt_wait
    assert_failure
}

@test "ensure_acme_installed propagates installer failure" {
    curl() { return 1; }
    run ensure_acme_installed 'test@example.com'
    assert_failure
}
