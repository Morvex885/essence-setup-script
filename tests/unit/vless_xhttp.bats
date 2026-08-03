#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/common/protocols/uri.sh"
    source "$PROJECT_ROOT/common/protocols/vless-xhttp.sh"
}

teardown() {
    teardown_test_env
}

@test "xHTTP client builders always use firefox and keep mode auto" {
    local yaml uri
    yaml=$(_build_vless_xhttp_client_yaml \
        "VLESS xHTTP" "edge.example" 443 \
        "11111111-1111-1111-1111-111111111111" "sni.example" "/probe" \
        "public-key" "short-id")
    uri=$(_build_vless_xhttp_uri \
        "11111111-1111-1111-1111-111111111111" "edge.example" 443 \
        "sni.example" "/probe" "public-key" "short-id" "VLESS xHTTP")

    grep -qF 'client-fingerprint: firefox' <<< "$yaml"
    grep -qF 'mode: auto' <<< "$yaml"
    [[ "$uri" == *"fp=firefox"* ]]
    [[ "$uri" == *"mode=auto"* ]]
}

@test "xHTTP exit builder overrides imported chrome fingerprint" {
    local yaml
    yaml=$(_build_vless_xhttp_exit_yaml \
        "cascade" "edge.example" 443 \
        "22222222-2222-2222-2222-222222222222" "sni.example" "/probe" \
        "auto" "public-key" "short-id" "chrome")

    grep -qF 'client-fingerprint: firefox' <<< "$yaml"
    ! grep -qF 'client-fingerprint: chrome' <<< "$yaml"
}

@test "xHTTP URI parser normalizes chrome to firefox and preserves Reality fields" {
    local uri yaml
    uri='vless://33333333-3333-3333-3333-333333333333@edge.example:443?encryption=none&security=reality&sni=sni.example&fp=chrome&pbk=public-key&sid=short-id&type=xhttp&path=%2Fprobe&mode=auto#xHTTP'
    yaml=$(_parse_vless_uri_to_exit "cascade" "$uri")

    grep -qF 'uuid: 33333333-3333-3333-3333-333333333333' <<< "$yaml"
    grep -qF 'path: "/probe"' <<< "$yaml"
    grep -qF 'public-key: public-key' <<< "$yaml"
    grep -qF 'short-id: short-id' <<< "$yaml"
    grep -qF 'client-fingerprint: firefox' <<< "$yaml"
}

@test "xHTTP URI builder and parser round-trip reserved path bytes" {
    local uri yaml
    uri=$(_build_vless_xhttp_uri \
        "44444444-4444-4444-4444-444444444444" "edge.example" 443 \
        "sni.example" "/a b?c&d" "public+/key=" "short/id" "узел xHTTP")

    [[ "$uri" == *'path=%2Fa%20b%3Fc%26d'* ]]
    [[ "$uri" == *'pbk=public%2B%2Fkey%3D'* ]]
    [[ "$uri" == *'#%D1%83%D0%B7%D0%B5%D0%BB%20xHTTP' ]]
    yaml=$(_parse_vless_uri_to_exit "roundtrip" "$uri")
    grep -qF 'path: "/a b?c&d"' <<< "$yaml"
    grep -qF 'public-key: public+/key=' <<< "$yaml"
    grep -qF 'short-id: short/id' <<< "$yaml"
    grep -qF 'client-fingerprint: firefox' <<< "$yaml"
}

@test "malformed percent escape is rejected" {
    run _parse_vless_uri_to_exit "bad" \
        'vless://55555555-5555-5555-5555-555555555555@edge.example:443?type=xhttp&path=%GG'
    assert_failure
    assert_output --partial 'Некорректное percent-кодирование'
}
