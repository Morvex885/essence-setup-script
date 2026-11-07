#!/usr/bin/env bats

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-100}"

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/common/cert.sh"
}

teardown() { teardown_test_env; }

@test "allowlisted ACME contact round-trips without interpreting shell text" {
    local file="$BATS_TEST_TMPDIR/ca.conf" local_part value i
    for (( i=0; i<FUZZ_ITERATIONS; i++ )); do
        local_part=$(random_string 12 'abcdefghijklmnopqrstuvwxyz0123456789._+-')
        value="${local_part}@example.com"
        printf "UNRELATED='\$(touch %s)'\nCA_EMAIL='%s'\n" "$BATS_TEST_TMPDIR/executed" "$value" > "$file"
        _acme_conf_value "$file" CA_EMAIL
        [ "$ACME_CONF_VALUE" = "$value" ]
        acme_email_valid "$ACME_CONF_VALUE"
        [ ! -e "$BATS_TEST_TMPDIR/executed" ]
    done
}

@test "malformed and duplicate ACME assignments never become selected contact" {
    local file="$BATS_TEST_TMPDIR/ca.conf" value i
    for (( i=0; i<FUZZ_ITERATIONS; i++ )); do
        value=$(random_string 10 'abcdefghijklmnopqrstuvwxyz0123456789')
        printf "CA_EMAIL='%s@example.com'\nCA_EMAIL='%s@example.com'\n" "$value" "$value" > "$file"
        _acme_conf_value "$file" CA_EMAIL && return 1
        [ -z "$ACME_CONF_VALUE" ] || return 1
        printf 'CA_EMAIL=$(touch %s)\n' "$BATS_TEST_TMPDIR/executed" > "$file"
        _acme_conf_value "$file" CA_EMAIL && return 1
        [ ! -e "$BATS_TEST_TMPDIR/executed" ]
    done
}
