#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/common/protocols/uri.sh"
source "$PROJECT_ROOT/common/protocols/vless-xhttp.sh"
source "$PROJECT_ROOT/setup-essence/modules/vless.sh"

MIHOMO_BIN="${MIHOMO_BIN:-mihomo}"
NGINX_BIN="${NGINX_BIN:-nginx}"
VALIDATION_DIR=$(mktemp -d)
trap 'rm -rf "$VALIDATION_DIR"' EXIT

write_mihomo_config() {
    local output="$1" listener="$2"
    {
        printf '%s\n' \
            'log-level: silent' \
            'mode: rule' \
            'proxy-groups:' \
            '  - name: outbound' \
            '    type: select' \
            '    proxies:' \
            '      - DIRECT' \
            'listeners:'
        printf '%s\n' "$listener"
        printf '%s\n' \
            'rules:' \
            '  - MATCH,DIRECT'
    } > "$output"
}

nginx_listener=$(_build_vless_xhttp_nginx_listener_yaml \
    'VLESS xHTTP nginx' 127.0.0.1 18445 user1 \
    11111111-1111-1111-1111-111111111111 /ci-nginx outbound)
reality_listener=$(_build_vless_xhttp_listener_yaml \
    'VLESS xHTTP Reality' 127.0.0.1 19445 user1 \
    22222222-2222-2222-2222-222222222222 /ci-reality \
    example.com:443 jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0 \
    0123456789abcdef example.com outbound)

write_mihomo_config "$VALIDATION_DIR/mihomo-nginx.yaml" "$nginx_listener"
write_mihomo_config "$VALIDATION_DIR/mihomo-reality.yaml" "$reality_listener"
"$MIHOMO_BIN" -t -f "$VALIDATION_DIR/mihomo-nginx.yaml"
"$MIHOMO_BIN" -t -f "$VALIDATION_DIR/mihomo-reality.yaml"

cat > "$VALIDATION_DIR/nginx-base.conf" <<'EOF'
pid /tmp/nginx-xhttp-validation.pid;
error_log stderr;
events {}
http {
    access_log off;
    server {
        listen 127.0.0.1:8443;
        location / {
            return 204;
        }
    }
}
EOF
_xhttp_render_nginx_config "$VALIDATION_DIR/nginx-base.conf" \
    "$VALIDATION_DIR/nginx.conf" /ci-nginx 18445
"$NGINX_BIN" -t -p "$VALIDATION_DIR/" -c "$VALIDATION_DIR/nginx.conf"

if [[ -n "${XHTTP_NGINX_OUTPUT:-}" ]]; then
    cp "$VALIDATION_DIR/nginx.conf" "$XHTTP_NGINX_OUTPUT"
fi

printf '%s\n' 'xHTTP config validation: OK'
