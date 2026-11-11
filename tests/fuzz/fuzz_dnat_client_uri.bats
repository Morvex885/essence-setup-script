#!/usr/bin/env bats

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-100}"

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/common/protocols/uri.sh"
    source "$PROJECT_ROOT/setup-essence/modules/cascade.sh"
}

teardown() { teardown_test_env; }

@test "cascade URI keeps scheme, userinfo, path, query and fragment byte-for-byte" {
    local i scheme user exit_host query fragment uri out
    for (( i=0; i<FUZZ_ITERATIONS; i++ )); do
        scheme=$(random_pick vless hy2 hysteria2)
        user=$(random_string 12 'abcdefABCDEF0123456789-%._~')
        exit_host=$(random_pick exit.example '[2001:db8::1]' 192.0.2.7)
        query=$(random_string 16 'abcdefxyz0123456789=&%:@/._-')
        fragment=$(random_string 10 'abcxyz0123456789@#%:/? ')
        uri="${scheme}://${user}@${exit_host}:$(random_int 1 65535)?${query}#${fragment}"
        out=$(_dnat_client_uri "$uri" 2001:db8::9 8443)
        [ "$out" = "${scheme}://${user}@[2001:db8::9]:8443?${query}#${fragment}" ]
    done
}
