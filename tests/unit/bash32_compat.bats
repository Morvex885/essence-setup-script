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

@test "node discovery count tracks two names and updates an existing name" {
    _node_disc_count_reset
    _node_disc_count_set 'de-vps' 2
    _node_disc_count_set 'ru-vps' 4
    [[ "$(_node_disc_count_get 'de-vps')" == 2 ]]
    [[ "$(_node_disc_count_get 'ru-vps')" == 4 ]]

    _node_disc_count_set 'de-vps' 7
    [[ "$(_node_disc_count_get 'de-vps')" == 7 ]]
    [[ "$(_node_disc_count_get 'ru-vps')" == 4 ]]
}

@test "subscription selectors write selected values to the shared result" {
    _select_client 'Choose client' <<< $'1\n'
    [[ "$SUBSCRIPTION_SELECT_RESULT" == 'my-router' ]]

    _select_group 'Choose group' <<< $'1\n'
    [[ "$SUBSCRIPTION_SELECT_RESULT" == 'ROUTER' ]]

    jq_w --arg n 'my-router' --arg t 'test-token' \
        '.clients |= map(if .name == $n then .subscription = {token: $t} else . end)'
    _select_client_with_sub 'Choose subscribed client' <<< $'1\n'
    [[ "$SUBSCRIPTION_SELECT_RESULT" == 'my-router' ]]
}
