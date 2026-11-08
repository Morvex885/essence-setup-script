#!/usr/bin/env bats
# Observable contracts for the Bash 3.2-compatible helper APIs.

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "subscription.sh"
    source_module "connections.sh"
    load_fixture_config
}

teardown() {
    teardown_test_env
}

@test "array_contains compares exact values including spaces and glob characters" {
    run array_contains 'node * [primary]' 'other' 'node * [primary]'
    assert_success

    run array_contains 'node * [primary]' 'node *'
    assert_failure
}

@test "toggle_select updates indexed flags from shared arrays" {
    TOGGLE_SELECT_ITEMS=('alpha node' 'beta*')
    TOGGLE_SELECT_FLAGS=(0 1)

    toggle_select 'Choose nodes' <<< $'1\n'

    [[ "${TOGGLE_SELECT_FLAGS[0]}" == 1 ]]
    [[ "${TOGGLE_SELECT_FLAGS[1]}" == 1 ]]
}
