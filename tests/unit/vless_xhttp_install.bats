#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source "$PROJECT_ROOT/common/protocols/uri.sh"
    source "$PROJECT_ROOT/common/protocols/vless-xhttp.sh"
    source "$PROJECT_ROOT/setup-essence/modules/vless.sh"

    export XHTTP_MIHOMO_CONFIG="$BATS_TEST_TMPDIR/etc/mihomo/config.yaml"
    export XHTTP_CLIENT_CONFIG="$BATS_TEST_TMPDIR/etc/mihomo/client-config.txt"
    export XHTTP_NGINX_FILE="$BATS_TEST_TMPDIR/etc/nginx/sites-available/site.example"
    export XHTTP_CERT_DIR="$BATS_TEST_TMPDIR/etc/mihomo/certs/xhttp"
    mkdir -p "$(dirname "$XHTTP_MIHOMO_CONFIG")" \
        "$(dirname "$XHTTP_NGINX_FILE")" "$XHTTP_CERT_DIR"

    UUID="11111111-1111-1111-1111-111111111111"
    PRIVATE_KEY="private-key"
    PUBLIC_KEY="public-key"
    SHORT_ID="abcd1234"
    SNI_DOMAIN="sni.example"
    REALITY_DEST="sni.example:443"
    SITE_NAME="site.example"
    CLIENT_SERVER="edge.example"

    SERVICE_LOG="$BATS_TEST_TMPDIR/services.log"
    : > "$SERVICE_LOG"
    PROBE_RESULT=0

    _xhttp_mihomo_validate() { return 0; }
    _xhttp_nginx_validate() { return 0; }
    _xhttp_service_is_active() { return 0; }
    _xhttp_service_restart() { echo "restart:$1" >> "$SERVICE_LOG"; return 0; }
    _xhttp_service_reload() { echo "reload:$1" >> "$SERVICE_LOG"; return 0; }
    _xhttp_service_stop() { echo "stop:$1" >> "$SERVICE_LOG"; return 0; }
    _xhttp_probe() { return "$PROBE_RESULT"; }

    cat > "$XHTTP_MIHOMO_CONFIG" <<'EOF'
log-level: silent
proxy-groups:
  - name: outbound
    type: select
    proxies: [DIRECT]
listeners:

rule-providers:
  keep-provider:
    type: http
sub-rules:
  keep-subrule:
    - MATCH,DIRECT
rules:
  - MATCH,DIRECT
EOF

    cat > "$XHTTP_NGINX_FILE" <<'EOF'
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name site.example;
    location / {
        try_files $uri =404;
    }
}
EOF
}

teardown() {
    teardown_test_env
}

@test "fresh Reality install is transactional and emits firefox client data" {
    run _install_vless_xhttp_transaction \
        reality 0.0.0.0 14443 14443 /fresh false
    assert_success

    grep -qF 'listen: 0.0.0.0' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'port: 14443' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'path: "/fresh"' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'reality-config:' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'keep-provider:' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'keep-subrule:' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'client-fingerprint: firefox' "$XHTTP_CLIENT_CONFIG"
    grep -qF 'fp=firefox' "$XHTTP_CLIENT_CONFIG"
}

@test "fresh nginx install uses plain loopback xHTTP and disables request buffering" {
    run _install_vless_xhttp_transaction \
        nginx 127.0.0.1 18445 443 /nginx false
    assert_success

    grep -qF 'allow-insecure: true' "$XHTTP_MIHOMO_CONFIG"
    ! grep -qE 'certificate:|private-key:' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'proxy_pass http://127.0.0.1:18445;' "$XHTTP_NGINX_FILE"
    grep -qF 'proxy_request_buffering off;' "$XHTTP_NGINX_FILE"
    grep -qF 'proxy_buffering off;' "$XHTTP_NGINX_FILE"
    ! grep -qF 'proxy_ssl_verify' "$XHTTP_NGINX_FILE"
    [[ ! -e "$XHTTP_CERT_DIR" ]]
}

@test "old nginx migration preserves topology users cascades and routing" {
    cat > "$XHTTP_MIHOMO_CONFIG" <<'EOF'
log-level: silent
proxy-groups:
  - name: outbound
    type: select
    proxies: [DIRECT]
listeners:
# --- vless-xhttp ---
  - name: VLESS xHTTP
    type: vless
    listen: 127.0.0.1
    port: 28445
    users:
      # client-users-start
      - username: alice
        uuid: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
      # client-users-end
      # cascade-user:hop
      - username: hop
        uuid: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
      # /cascade-user:hop
    xhttp-config:
      path: "/keep-me"
      mode: auto
    certificate: /etc/mihomo/certs/xhttp/fullchain.pem
    private-key: /etc/mihomo/certs/xhttp/privkey.pem
    proxy: outbound
    rule: vless-xhttp-shared
# --- /vless-xhttp ---

rule-providers:
  keep-provider:
    type: http
sub-rules:
  vless-xhttp-shared:
    - DOMAIN-SUFFIX,example.org,hop
rules:
  - MATCH,DIRECT
EOF
    cat > "$XHTTP_CLIENT_CONFIG" <<'EOF'
--- VLESS xHTTP ---
Transport:    xhttp (через nginx, без Reality)
Server:       edge.example
Port:         443
SNI:          site.example
UUID:         aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
Path:         /keep-me
URI: vless://aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa@edge.example:443?security=tls&sni=site.example&fp=chrome&type=xhttp&path=/keep-me&mode=auto#VLESS
proxies:
  - name: "VLESS xHTTP"
    type: vless
    network: xhttp
    client-fingerprint: chrome
--- /VLESS xHTTP ---

--- Cascade: hop ---
Listener: VLESS xHTTP (:443)
URI: vless://bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb@edge.example:443?security=tls&sni=site.example&fp=chrome&type=xhttp&path=/keep-me&mode=auto#hop
proxies:
  - name: "VLESS xHTTP hop"
    type: vless
    network: xhttp
    client-fingerprint: chrome
--- /Cascade: hop ---
EOF
    cat > "$XHTTP_NGINX_FILE" <<'EOF'
server {
    listen 127.0.0.1:8443 ssl;
    # --- xhttp-nginx ---
    location /keep-me {
        proxy_pass https://127.0.0.1:28445;
        proxy_ssl_verify off;
        proxy_buffering off;
    }
    # --- /xhttp-nginx ---
    location / { try_files $uri =404; }
}
EOF

    run _install_vless_xhttp_transaction \
        nginx 127.0.0.1 28445 443 /keep-me true
    assert_success

    grep -qF 'port: 28445' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'path: "/keep-me"' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'username: alice' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'username: hop' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'rule: vless-xhttp-shared' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'DOMAIN-SUFFIX,example.org,hop' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'keep-provider:' "$XHTTP_MIHOMO_CONFIG"
    grep -qF 'allow-insecure: true' "$XHTTP_MIHOMO_CONFIG"
    ! grep -qE 'certificate:|private-key:' "$XHTTP_MIHOMO_CONFIG"
    [[ "$(grep -c 'client-fingerprint: firefox' "$XHTTP_CLIENT_CONFIG")" -eq 2 ]]
    [[ "$(grep -o 'fp=firefox' "$XHTTP_CLIENT_CONFIG" | wc -l)" -eq 2 ]]
}

@test "reinstall is idempotent" {
    _install_vless_xhttp_transaction nginx 127.0.0.1 18445 443 /same false
    cp "$XHTTP_MIHOMO_CONFIG" "$BATS_TEST_TMPDIR/first-mihomo"
    cp "$XHTTP_CLIENT_CONFIG" "$BATS_TEST_TMPDIR/first-client"
    cp "$XHTTP_NGINX_FILE" "$BATS_TEST_TMPDIR/first-nginx"

    run _install_vless_xhttp_transaction nginx 127.0.0.1 18445 443 /same true
    assert_success
    cmp -s "$BATS_TEST_TMPDIR/first-mihomo" "$XHTTP_MIHOMO_CONFIG"
    cmp -s "$BATS_TEST_TMPDIR/first-client" "$XHTTP_CLIENT_CONFIG"
    cmp -s "$BATS_TEST_TMPDIR/first-nginx" "$XHTTP_NGINX_FILE"
}

@test "probe failure rolls back every file and keeps internal certificates" {
    cat > "$XHTTP_CLIENT_CONFIG" <<'EOF'
before-client
EOF
    cp "$XHTTP_MIHOMO_CONFIG" "$BATS_TEST_TMPDIR/before-mihomo"
    cp "$XHTTP_CLIENT_CONFIG" "$BATS_TEST_TMPDIR/before-client"
    cp "$XHTTP_NGINX_FILE" "$BATS_TEST_TMPDIR/before-nginx"
    touch "$XHTTP_CERT_DIR/fullchain.pem"
    PROBE_RESULT=1

    run _install_vless_xhttp_transaction nginx 127.0.0.1 18445 443 /rollback false
    assert_failure

    cmp -s "$BATS_TEST_TMPDIR/before-mihomo" "$XHTTP_MIHOMO_CONFIG"
    cmp -s "$BATS_TEST_TMPDIR/before-client" "$XHTTP_CLIENT_CONFIG"
    cmp -s "$BATS_TEST_TMPDIR/before-nginx" "$XHTTP_NGINX_FILE"
    [[ -f "$XHTTP_CERT_DIR/fullchain.pem" ]]
    [[ "$(grep -c '^restart:mihomo$' "$SERVICE_LOG")" -eq 2 ]]
    [[ "$(grep -c '^reload:nginx$' "$SERVICE_LOG")" -eq 1 ]]
    [[ "$(grep -c '^restart:nginx$' "$SERVICE_LOG")" -eq 1 ]]
}
