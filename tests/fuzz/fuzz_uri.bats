#!/usr/bin/env bats

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-100}"

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/common/protocols/uri.sh"
}

teardown() {
    teardown_test_env
}

@test "fuzz URI percent encoder/parser round-trip reserved ASCII" {
    local charset='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~ !#$&()*+,/:;=?@[]{}|`%'
    local iteration input encoded decoded
    for ((iteration = 0; iteration < FUZZ_ITERATIONS; iteration++)); do
        input=$(random_string "$((RANDOM % 80 + 1))" "$charset")
        encoded=$(_uri_percent_encode "$input")
        decoded=$(_uri_percent_decode "$encoded")
        [[ "$decoded" == "$input" ]] || {
            echo "round-trip failed at iteration $iteration: '$input' -> '$encoded' -> '$decoded'"
            return 1
        }
        [[ "$encoded" =~ ^([a-zA-Z0-9.~_-]|%[0-9A-F]{2})*$ ]] || {
            echo "encoder emitted invalid bytes at iteration $iteration: '$encoded'"
            return 1
        }
    done
}

@test "fuzz URI percent encoder/parser round-trip visible UTF-8" {
    local iteration input encoded decoded
    for ((iteration = 0; iteration < FUZZ_ITERATIONS; iteration++)); do
        random_utf8 "$((RANDOM % 30 + 1))"
        input="$FUZZ_UTF8_STR"
        encoded=$(_uri_percent_encode "$input")
        decoded=$(_uri_percent_decode "$encoded")
        [[ "$decoded" == "$input" ]] || {
            echo "UTF-8 round-trip failed at iteration $iteration"
            return 1
        }
    done
}

@test "fuzz URI percent parser rejects malformed escapes without crashing" {
    local malformed=('%' '%0' '%GG' '%0G' '%G0' '%00' 'abc%' 'abc%2' 'abc%xy')
    local iteration value
    for ((iteration = 0; iteration < FUZZ_ITERATIONS; iteration++)); do
        value="${malformed[RANDOM % ${#malformed[@]}]}"
        run _uri_percent_decode "$value"
        assert_failure
    done
}
