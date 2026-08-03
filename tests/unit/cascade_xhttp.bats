#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/common/protocols/uri.sh"
    source "$PROJECT_ROOT/common/protocols/vless-xhttp.sh"
    source "$PROJECT_ROOT/setup-essence/modules/vless.sh"
    source "$PROJECT_ROOT/setup-essence/modules/cascade.sh"
    SITE_NAME="site.example"
    SNI_DOMAIN="reality.example"
    PUBLIC_KEY="public-key"
    SHORT_ID="short-id"
}

teardown() {
    teardown_test_env
}

write_listener() {
    local tls_field="$1"
    cat > "$BATS_TEST_TMPDIR/config.yaml" <<EOF
listeners:
# --- vless-xhttp ---
  - name: VLESS xHTTP
    type: vless
    listen: 127.0.0.1
    port: 18445
    users:
      - username: alice
        uuid: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
    xhttp-config:
      path: "/cascade-path"
      mode: auto
$tls_field
    proxy: outbound
# --- /vless-xhttp ---
rule-providers:
EOF
}

@test "cascade recognizes old nginx certificate listener" {
    write_listener $'    certificate: old.crt\n    private-key: old.key'
    _load_xhttp_cascade_client_settings "$BATS_TEST_TMPDIR/config.yaml" edge.example
    [[ "$XHTTP_CASCADE_TOPOLOGY" == "nginx" ]]
    [[ "$XHTTP_CASCADE_PATH" == "/cascade-path" ]]
    [[ "$XHTTP_CASCADE_SNI" == "site.example" ]]
    [[ -z "$XHTTP_CASCADE_PUBLIC_KEY" ]]
}

@test "cascade recognizes new nginx allow-insecure listener" {
    write_listener '    allow-insecure: true'
    _load_xhttp_cascade_client_settings "$BATS_TEST_TMPDIR/config.yaml" edge.example
    [[ "$XHTTP_CASCADE_TOPOLOGY" == "nginx" ]]
    [[ "$XHTTP_CASCADE_SNI" == "site.example" ]]
}

@test "cascade preserves Reality parameters and generates firefox credentials" {
    write_listener $'    reality-config:\n      dest: reality.example:443'
    _load_xhttp_cascade_client_settings "$BATS_TEST_TMPDIR/config.yaml" edge.example
    [[ "$XHTTP_CASCADE_TOPOLOGY" == "reality" ]]
    [[ "$XHTTP_CASCADE_SNI" == "reality.example" ]]
    [[ "$XHTTP_CASCADE_PUBLIC_KEY" == "public-key" ]]
    [[ "$XHTTP_CASCADE_SHORT_ID" == "short-id" ]]

    local yaml
    yaml=$(_build_vless_xhttp_client_yaml "cascade" edge.example 443 \
        bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb "$XHTTP_CASCADE_SNI" \
        "$XHTTP_CASCADE_PATH" "$XHTTP_CASCADE_PUBLIC_KEY" "$XHTTP_CASCADE_SHORT_ID")
    grep -qF 'uuid: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' <<< "$yaml"
    grep -qF 'client-fingerprint: firefox' <<< "$yaml"
}
