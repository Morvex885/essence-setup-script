#!/usr/bin/env bats
# Regression tests for shared framed menu contracts.

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
}

teardown() {
    teardown_test_env
}

@test "menu_index_valid rejects zero, leading zero, signs, and expressions" {
    menu_index_valid 1 2
    ! menu_index_valid 0 2
    ! menu_index_valid 01 2
    ! menu_index_valid +1 2
    ! menu_index_valid '1+1' 2
    ! menu_index_valid 3 2
}

@test "confirm_yn distinguishes Enter from EOF" {
    confirm_yn 'continue?' Y <<< $'\n'
    ! confirm_yn 'continue?' Y </dev/null
}

@test "toggle_select mutates shared flags without command substitution" {
    TOGGLE_SELECT_ITEMS=('alpha' 'beta')
    TOGGLE_SELECT_FLAGS=(0 1)
    toggle_select 'Choose' <<< $'1\n\n'
    [[ "${TOGGLE_SELECT_FLAGS[0]}" == 1 ]]
    [[ "${TOGGLE_SELECT_FLAGS[1]}" == 1 ]]
}

@test "toggle_select EOF cancels without changing flags" {
    TOGGLE_SELECT_ITEMS=('alpha')
    TOGGLE_SELECT_FLAGS=(1)
    toggle_select 'Choose' <<< ''
    [[ "$?" -eq 1 ]]
    [[ "${TOGGLE_SELECT_FLAGS[0]}" == 1 ]]
}

@test "box_line preserves UTF-8 characters while wrapping" {
    BOX_W=6
    output=$(box_line 'Пример действия')
    [[ "$output" != *'�'* ]]
}

@test "box_line wraps long content at configured width" {
    BOX_W=4
    output=$(box_line 'abcdef')
    [[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]]
}
