#!/usr/bin/env bats
# Fuzz tests for _vis_len() — random UTF-8 inputs, edge cases, invalid bytes

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-50}"

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    source_common
}

@test "fuzz _vis_len: random bytes — always returns non-negative integer" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local len=$((RANDOM % 100))
        local input
        input=$(head -c "$len" /dev/urandom | base64 | head -c "$len")
        local result
        result=$(_vis_len "$input")
        [[ "$result" =~ ^[0-9]+$ ]] || {
            echo "FAIL iteration $i: result='$result'"
            return 1
        }
    done
}

@test "fuzz _vis_len: pure ASCII — result equals string length" {
    local charset="abcdefghijklmnopqrstuvwxyz0123456789"
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local len=$(random_int 0 50)
        local input
        input=$(random_string "$len" "$charset")
        local result
        result=$(_vis_len "$input")
        [[ "$result" -eq "$len" ]] || {
            echo "FAIL iteration $i: input='$input' len=$len result=$result"
            return 1
        }
    done
}

@test "fuzz _vis_len: random UTF-8 — result equals character count" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local count=$(random_int 0 30)
        random_utf8 "$count"
        local result
        result=$(_vis_len "$FUZZ_UTF8_STR")
        [[ "$result" -eq "$FUZZ_UTF8_LEN" ]] || {
            echo "FAIL iteration $i: expected=$FUZZ_UTF8_LEN got=$result str_bytes=${#FUZZ_UTF8_STR}"
            return 1
        }
    done
}

@test "fuzz _vis_len: invalid UTF-8 edge cases — never crash, always non-negative" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local input
        local strategy=$((RANDOM % 3))
        case $strategy in
            0) input=$(random_pick DICT_UTF8_EDGE) ;;
            1) input="$(random_ascii $((RANDOM % 10)))$(random_pick DICT_UTF8_EDGE)$(random_ascii $((RANDOM % 10)))" ;;
            2) input=$(head -c $((RANDOM % 50 + 1)) /dev/urandom | tr -d '\0') ;;
        esac
        local result
        result=$(_vis_len "$input")
        [[ "$result" =~ ^[0-9]+$ ]] || {
            echo "FAIL iteration $i: result='$result' (not a non-negative integer)"
            return 1
        }
    done
}
