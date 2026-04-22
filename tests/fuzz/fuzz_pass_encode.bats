#!/usr/bin/env bats
# Fuzz tests for node_pass_encode/node_pass_decode — encryption round-trip

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-50}"

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    setup_test_env
    source_common
    source_module "nodes.sh"
    override_pass_key
}

teardown() {
    teardown_test_env
}

@test "fuzz pass round-trip: random ASCII passwords" {
    local charset='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;:,.<>?'
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local len=$(random_int 1 100)
        local pass
        pass=$(random_string "$len" "$charset")
        local encoded
        encoded=$(node_pass_encode "$pass")
        [[ -n "$encoded" ]] || { echo "FAIL: encode returned empty for pass len=$len"; return 1; }
        local decoded
        decoded=$(node_pass_decode "$encoded")
        [[ "$decoded" == "$pass" ]] || {
            echo "FAIL iteration $i: len=$len"
            echo "  pass='${pass:0:20}...'"
            echo "  decoded='${decoded:0:20}...'"
            return 1
        }
    done
}

@test "fuzz pass round-trip: random lengths including 0" {
    local charset="abcdefghijklmnopqrstuvwxyz0123456789"
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local len=$(random_int 0 500)
        local pass
        pass=$(random_string "$len" "$charset")
        local encoded
        encoded=$(node_pass_encode "$pass")
        [[ -n "$encoded" ]] || { echo "FAIL: encode returned empty for len=$len"; return 1; }
        local decoded
        decoded=$(node_pass_decode "$encoded")
        [[ "$decoded" == "$pass" ]] || {
            echo "FAIL: len=$len pass='${pass:0:30}...' decoded='${decoded:0:30}...'"
            return 1
        }
    done
}

@test "fuzz pass round-trip: random passwords with whitespace" {
    local charset=$'abcdefghijklmnopqrstuvwxyz0123456789 \t\n'
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local len=$(random_int 0 80)
        local pass
        pass=$(random_string "$len" "$charset")
        local encoded
        encoded=$(node_pass_encode "$pass")
        [[ -n "$encoded" ]] || { echo "FAIL: encode returned empty, iteration $i len=$len"; return 1; }
        local decoded
        decoded=$(node_pass_decode "$encoded")
        [[ "$decoded" == "$pass" ]] || {
            echo "FAIL iteration $i: round-trip mismatch len=$len"
            return 1
        }
    done
}

@test "fuzz pass round-trip: injection chars preserved in round-trip" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local base
        base=$(random_ascii $((RANDOM % 20 + 1)))
        local pass
        local strategy=$((RANDOM % 3))
        case $strategy in
            0) pass=$(mutate_inject "$base" DICT_SHELL_INJECTION) ;;
            1) pass=$(mutate_inject "$base" DICT_FORMAT_STRINGS) ;;
            2) pass=$(mutate_inject "$base" DICT_PATH_TRAVERSAL) ;;
        esac
        # Skip null-byte passwords — bash can't handle them in variables
        [[ "$pass" == *$'\x00'* ]] && continue
        local encoded
        encoded=$(node_pass_encode "$pass")
        [[ -n "$encoded" ]] || { echo "FAIL: encode returned empty, iteration $i"; return 1; }
        local decoded
        decoded=$(node_pass_decode "$encoded")
        [[ "$decoded" == "$pass" ]] || {
            echo "FAIL iteration $i: injection round-trip mismatch"
            echo "  pass_hex='$(printf '%s' "$pass" | xxd -p | head -c 60)'"
            echo "  decoded_hex='$(printf '%s' "$decoded" | xxd -p | head -c 60)'"
            return 1
        }
    done
}

@test "fuzz pass decode: random garbage never crashes" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local garbage
        garbage=$(head -c $((RANDOM % 100 + 1)) /dev/urandom | base64 | head -c $((RANDOM % 50 + 1)))
        node_pass_decode "$garbage" >/dev/null 2>&1 || true
    done
}
