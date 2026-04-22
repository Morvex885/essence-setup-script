#!/usr/bin/env bats
# Tests for _group_matches() — group tag matching

setup() {
    load '../helpers/test_helper'
    source_common
    source_module "templates.sh"
}

@test "_group_matches: exact single match" {
    run _group_matches "PC" "PC"
    assert_success
    assert_output "1"
}

@test "_group_matches: single no match" {
    run _group_matches "PC" "MOBILE"
    assert_success
    assert_output "0"
}

@test "_group_matches: multi-group match first" {
    run _group_matches "ROUTER/PC" "ROUTER"
    assert_success
    assert_output "1"
}

@test "_group_matches: multi-group match second" {
    run _group_matches "ROUTER/PC" "PC"
    assert_success
    assert_output "1"
}

@test "_group_matches: multi-group no match" {
    run _group_matches "ROUTER/PC" "MOBILE"
    assert_success
    assert_output "0"
}

@test "_group_matches: three groups, match middle" {
    run _group_matches "A/B/C" "B"
    assert_success
    assert_output "1"
}

@test "_group_matches: three groups, match last" {
    run _group_matches "A/B/C" "C"
    assert_success
    assert_output "1"
}

@test "_group_matches: empty tag vs non-empty target" {
    run _group_matches "" "PC"
    assert_success
    assert_output "0"
}

@test "_group_matches: partial name does not match" {
    run _group_matches "ROUTER" "ROUTE"
    assert_success
    assert_output "0"
}

@test "_group_matches: case sensitive — lowercase vs uppercase" {
    run _group_matches "router" "ROUTER"
    assert_success
    assert_output "0"
}

@test "_group_matches: single char groups" {
    run _group_matches "A/B" "A"
    assert_success
    assert_output "1"
}

@test "_group_matches: target with slash does not match element" {
    run _group_matches "A/B" "A/B"
    assert_success
    assert_output "0"
}
