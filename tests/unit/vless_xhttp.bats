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

@test "bracketed IPv6 URI parses to unbracketed server and correct port" {
    source "$PROJECT_ROOT/common/protocols/vless-tcp.sh"
    source "$PROJECT_ROOT/common/protocols/hy2.sh"
    _parse_server_port_from_uri 'vless://u@[2001:db8::1]:8443?type=tcp#n'
    [[ "$URI_SERVER" == "2001:db8::1" && "$URI_PORT" == "8443" ]]
    local yaml
    yaml=$(_parse_vless_uri_to_exit p 'vless://u@[2001:db8::1]:443?type=tcp' 2>/dev/null)
    grep -qxF '    server: 2001:db8::1' <<< "$yaml"
    grep -qxF '    port: 443' <<< "$yaml"
    yaml=$(_parse_hy2_uri_to_exit p 'hy2://pw@[2001:db8::1]:443' 2>/dev/null)
    grep -qxF '    server: 2001:db8::1' <<< "$yaml"
    [[ $(_build_hy2_uri pw 2001:db8::1 443) == 'hysteria2://pw@[2001:db8::1]:443?'* ]]
    [[ $(_build_vless_tcp_uri u 2001:db8::1 443 s k i) == 'vless://u@[2001:db8::1]:443?'* ]]
}

@test "trailing CR from CRLF input does not leak into the last URI field" {
    source "$PROJECT_ROOT/common/protocols/hy2.sh"
    _parse_server_port_from_uri $'hy2://p@h:443\r'
    [[ "$URI_PORT" == "443" ]]
    local yaml
    yaml=$(_parse_vless_uri_to_exit p $'vless://u@h:443?type=xhttp&mode=packet-up\r' 2>/dev/null)
    grep -qxF '    xhttp-opts:' <<< "$yaml"
    grep -qF 'mode: packet-up' <<< "$yaml"
    [[ "$yaml" != *$'\r'* ]]
    yaml=$(_parse_hy2_uri_to_exit p $'hy2://pw@h:443?insecure=1\r' 2>/dev/null)
    grep -qxF '    skip-cert-verify: true' <<< "$yaml"
}

@test "xHTTP normalizer handles CRLF blocks" {
    local out
    out=$(printf '  - name: n\r\n    network: xhttp\r\n    client-fingerprint: chrome\r\n' | _normalize_vless_xhttp_proxy_yaml)
    [[ "$out" == *$'    client-fingerprint: firefox\r'* ]]
    [[ "$out" != *chrome* ]]
    out=$(printf '  - name: n\r\n    network: xhttp\r\n' | _normalize_vless_xhttp_proxy_yaml)
    [[ "$out" == *$'    client-fingerprint: firefox\r' ]]
}

@test "URI builders encode reserved fields and hysteria password round trips" {
    source "$PROJECT_ROOT/common/protocols/vless-tcp.sh"
    source "$PROJECT_ROOT/common/protocols/vless-grpc.sh"
    source "$PROJECT_ROOT/common/protocols/hy2.sh"
    local uri yaml
    uri=$(_build_hy2_uri 'p@# &%' host 443 's&n' 'ob#fs')
    [[ "$uri" == *'p%40%23%20%26%25@host'* && "$uri" == *'ob%23fs'* ]]
    yaml=$(_parse_hy2_uri_to_exit p "$uri" 2>/dev/null)
    [[ "$yaml" == *'password: p@# &%'* ]]
    uri=$(_build_vless_grpc_uri uuid host 443 's&n' 'svc?x' 'p+k' id 'my node')
    [[ "$uri" == *'sni=s%26n'* && "$uri" == *'serviceName=svc%3Fx'* && "$uri" == *'#my%20node' ]]
    uri=$(_build_vless_tcp_uri uuid host 443 s k id 'my node')
    [[ "$uri" == *'#my%20node' ]]
}

@test "explicitly empty TCP flow is omitted" {
    source "$PROJECT_ROOT/common/protocols/vless-tcp.sh"
    local yaml
    yaml=$(_build_vless_tcp_exit_yaml p host 443 uuid s '' '' '')
    [[ "$yaml" != *'    flow:'* ]]
}

@test "client YAML quotes escape double quotes and backslashes" {
    source "$PROJECT_ROOT/common/protocols/vless-tcp.sh"
    source "$PROJECT_ROOT/common/protocols/vless-grpc.sh"
    source "$PROJECT_ROOT/common/protocols/hy2.sh"
    local yaml
    yaml=$(_build_hy2_client_yaml 'a"b\c' host 443 pass)
    [[ "$yaml" == *'name: "a\"b\\c"'* ]]
    yaml=$(_build_vless_tcp_client_yaml 'a"b\c' host 443 u s k id)
    [[ "$yaml" == *'name: "a\"b\\c"'* ]]
    yaml=$(_build_vless_grpc_client_yaml 'a"b\c' host 443 u s svc k id)
    [[ "$yaml" == *'name: "a\"b\\c"'* ]]
}
