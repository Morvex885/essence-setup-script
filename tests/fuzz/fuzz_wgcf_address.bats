#!/usr/bin/env bats

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-100}"

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

@test "fuzz wgcf Address: valid families are recognized in either order" {
    local i a b c d ipv4 ipv6 line
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        a=$((RANDOM % 223 + 1))
        b=$((RANDOM % 256))
        c=$((RANDOM % 256))
        d=$((RANDOM % 254 + 1))
        ipv4="$a.$b.$c.$d"
        printf -v ipv6 '2001:db8:%x:%x::%x' "$((RANDOM % 65536))" "$((RANDOM % 65536))" "$((RANDOM % 65535 + 1))"

        if (( RANDOM % 2 )); then
            line="Address = $ipv4/32, $ipv6/128"
        else
            line="  Address  =  $ipv6/64 ,   $ipv4/24  "
        fi

        parse_wgcf_address_line "$line" || {
            echo "FAIL iteration $i: valid Address was rejected: $line"
            return 1
        }
        [[ "$WGCF_IPV4_ADDRESS" == "$ipv4" ]] || return 1
        [[ "$WGCF_IPV6_ADDRESS" == "$ipv6" ]] || return 1
    done
}

@test "fuzz wgcf Address: garbage never becomes an address or crashes" {
    local i garbage line
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        garbage=$(random_ascii "$((RANDOM % 24 + 1))")
        line="Address = 999.$((RANDOM % 999)).1.1/999, 2001:::${RANDOM}/129, ${garbage}/x"

        if parse_wgcf_address_line "$line"; then
            echo "FAIL iteration $i: garbage produced IPv4 '$WGCF_IPV4_ADDRESS'"
            return 1
        fi
        [[ -z "$WGCF_IPV4_ADDRESS" ]] || return 1
        if [[ -n "$WGCF_IPV6_ADDRESS" ]]; then
            _warp_valid_ipv6 "$WGCF_IPV6_ADDRESS" || return 1
        fi
    done
}

@test "fuzz wgcf Address: arbitrary lines do not crash parser" {
    local i line
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        line="$(random_utf8 "$((RANDOM % 40))")"
        parse_wgcf_address_line "$line" || true
        if [[ -n "$WGCF_IPV4_ADDRESS" ]]; then
            _warp_valid_ipv4 "$WGCF_IPV4_ADDRESS" || return 1
        fi
        if [[ -n "$WGCF_IPV6_ADDRESS" ]]; then
            _warp_valid_ipv6 "$WGCF_IPV6_ADDRESS" || return 1
        fi
    done
}
