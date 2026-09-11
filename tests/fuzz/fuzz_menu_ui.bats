#!/usr/bin/env bats
# Fuzz tests for menu input boundaries and cancellation.

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-50}"

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    source_common
}

@test "fuzz menu_index_valid never evaluates arbitrary numeric input" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        value="$(random_pick "${DICT_BOUNDARY[@]}")$(random_pick "${DICT_FORMAT_STRINGS[@]}")"
        menu_index_valid "$value" 3 || true
    done
}

@test "fuzz toggle_select invalid streams always cancel or complete" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        TOGGLE_SELECT_ITEMS=('alpha' 'beta')
        TOGGLE_SELECT_FLAGS=(0 0)
        stream="$(random_int 0 9)\n$(random_pick "${DICT_FORMAT_STRINGS[@]}")\n"
        toggle_select 'Choose' <<< "$stream" >/dev/null 2>&1 || true
        [[ "${TOGGLE_SELECT_FLAGS[0]}" =~ ^[01]$ ]]
        [[ "${TOGGLE_SELECT_FLAGS[1]}" =~ ^[01]$ ]]
    done
}
