#!/usr/bin/env bats
# Regression tests for shared framed menu contracts.

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module groups.sh
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
    if toggle_select 'Choose' </dev/null; then
        rc=0
    else
        rc=$?
    fi
    [[ "$rc" -eq 1 ]]
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

@test "select_group redraws stable indexes and chooses second group" {
    local input="$BATS_TEST_TMPDIR/group-input" screen="$BATS_TEST_TMPDIR/group-screen"
    BOX_W=70
    printf '2\n' > "$input"
    select_group < "$input" > "$screen"
    [[ "$SELECTED_GROUP" == PC ]]
}

@test "select_group rejects zero and EOF" {
    if select_group <<< '0'; then
        return 1
    fi
    if select_group </dev/null; then
        return 1
    fi
}

@test "menu_select validates input before publishing and clears context" {
    MENU_SELECT_CONTEXT=('context')
    MENU_SELECT_EMPTY='empty'
    menu_select 'Choose' 'Pick' alpha beta <<< $'01\n1+1\n\n2\r\n'
    [[ "$MENU_SELECT_INDEX" == 2 ]]
    [[ "${#MENU_SELECT_CONTEXT[@]}" == 0 && -z "$MENU_SELECT_EMPTY" ]]
}

@test "menu_select cancellation and EOF clear previous result" {
    MENU_SELECT_INDEX=2
    ! menu_select 'Choose' 'Pick' alpha <<< 0
    [[ -z "$MENU_SELECT_INDEX" ]]
    MENU_SELECT_INDEX=2
    ! menu_select 'Choose' 'Pick' alpha </dev/null
    [[ -z "$MENU_SELECT_INDEX" ]]
}

@test "empty menu_select leaves input unread and clears optional inputs" {
    MENU_SELECT_CONTEXT=('context')
    MENU_SELECT_EMPTY='empty'
    {
        ! menu_select 'Choose' 'Pick'
        IFS= read -r remaining
    } <<< sentinel
    [[ "$remaining" == sentinel && -z "$MENU_SELECT_INDEX" ]]
    [[ "${#MENU_SELECT_CONTEXT[@]}" == 0 && -z "$MENU_SELECT_EMPTY" ]]
}

@test "node_pick preserves config order without loading or contacting node" {
    source_module nodes.sh
    load '../helpers/mock_ssh'
    reset_ssh_mocks
    jq_w '.nodes=[{name:"alpha",ip:"192.0.2.1",port:22},{name:"beta",ip:"192.0.2.2",port:2222}]'
    node_load() { return 99; }
    node_pick 'Choose' <<< 2
    [[ "$NODE_PICK_INDEX" == 2 && -z "$SSH_RUN_CALLS" ]]
}
