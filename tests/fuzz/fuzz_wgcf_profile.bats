#!/usr/bin/env bats

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-100}"
BASE64_ALPHABET='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/setup-essence/modules/warp.sh"
}

teardown() {
    teardown_test_env
}

random_wireguard_key() {
    local key="" i
    for ((i = 0; i < 43; i++)); do
        key+="${BASE64_ALPHABET:RANDOM%64:1}"
    done
    printf '%s=\n' "$key"
}

@test "fuzz wgcf profile: valid padded keys round-trip exactly" {
    local profile="$BATS_TEST_TMPDIR/wgcf-profile.conf"
    local i private_key public_key

    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        private_key=$(random_wireguard_key)
        public_key=$(random_wireguard_key)
        printf 'PrivateKey = %s\nPublicKey = %s\n' "$private_key" "$public_key" > "$profile"

        parse_wgcf_profile_keys "$profile" || {
            echo "FAIL iteration $i: valid keys were rejected"
            return 1
        }
        [[ "$WGCF_PROFILE_PRIVATE_KEY" == "$private_key" ]] || return 1
        [[ "$WGCF_PROFILE_PUBLIC_KEY" == "$public_key" ]] || return 1
    done
}

@test "fuzz wgcf profile: whitespace and CRLF do not alter keys" {
    local profile="$BATS_TEST_TMPDIR/wgcf-profile.conf"
    local i private_key public_key

    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        private_key=$(random_wireguard_key)
        public_key=$(random_wireguard_key)
        printf ' \tPrivateKey \t=  %s \t\r\nPublicKey=\t%s\r\n' \
            "$private_key" "$public_key" > "$profile"

        parse_wgcf_profile_keys "$profile" || return 1
        [[ "$WGCF_PROFILE_PRIVATE_KEY" == "$private_key" ]] || return 1
        [[ "$WGCF_PROFILE_PUBLIC_KEY" == "$public_key" ]] || return 1
    done
}

@test "fuzz wgcf profile: malformed keys are rejected without crashing" {
    local profile="$BATS_TEST_TMPDIR/wgcf-profile.conf"
    local i private_key public_key malformed variant

    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        private_key=$(random_wireguard_key)
        public_key=$(random_wireguard_key)

        case $((RANDOM % 5)) in
            0) malformed="${private_key%=}" ;;
            1) malformed="${private_key}=" ;;
            2) malformed="-${private_key:1}" ;;
            3) malformed="${private_key%=}A" ;;
            4)
                variant=$(random_utf8 "$((RANDOM % 32 + 1))")
                malformed="${variant}="
                ;;
        esac

        printf 'PrivateKey = %s\nPublicKey = %s\n' "$malformed" "$public_key" > "$profile"
        if parse_wgcf_profile_keys "$profile"; then
            echo "FAIL iteration $i: malformed private key was accepted"
            return 1
        fi
    done
}
