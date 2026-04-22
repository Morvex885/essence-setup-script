#!/bin/bash
# ─── VLESS gRPC protocol builders ───────────────────────────────────────────

# Listener YAML with Reality (server-side)
# Args: name listen port username uuid service dest private_key short_id sni proxy
_build_vless_grpc_listener_yaml() {
    local name="$1" listen="$2" port="$3" username="$4" uuid="$5"
    local service="$6" dest="$7" private_key="$8" short_id="$9" sni="${10}" proxy="${11}"
    cat <<EOF
  - name: $name
    type: vless
    listen: $listen
    port: $port
    users:
      # client-users-start
      - username: $username
        uuid: $uuid
      # client-users-end
    grpc-service-name: "$service"
    reality-config:
      dest: $dest
      private-key: "$private_key"
      short-id:
        - "$short_id"
      server-names:
        - $sni
    proxy: $proxy
EOF
}

# Client proxy YAML
# Args: name server port uuid sni service public_key short_id
_build_vless_grpc_client_yaml() {
    local name="$1" server="$2" port="$3" uuid="$4"
    local sni="$5" service="$6" public_key="$7" short_id="$8"
    cat <<EOF
proxies:
  - name: "$name"
    type: vless
    server: $server
    port: $port
    uuid: $uuid
    network: grpc
    udp: true
    tls: true
    servername: $sni
    grpc-opts:
      grpc-service-name: "$service"
    reality-opts:
      public-key: "$public_key"
      short-id: "$short_id"
    client-fingerprint: chrome
EOF
}

# Client URI
# Args: uuid server port sni service public_key short_id [fragment]
_build_vless_grpc_uri() {
    local uuid="$1" server="$2" port="$3" sni="$4"
    local service="$5" public_key="$6" short_id="$7" fragment="${8:-VLESS gRPC}"
    echo "vless://${uuid}@${server}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=grpc&serviceName=${service}#${fragment}"
}

# Exit proxy YAML (cascade outbound)
# Args: name server port uuid sni service [public_key short_id fingerprint]
_build_vless_grpc_exit_yaml() {
    local name="$1" server="$2" port="$3" uuid="$4" sni="$5"
    local service="$6" public_key="${7:-}" short_id="${8:-}" fingerprint="${9:-chrome}"

    echo "  - name: $name"
    echo "    type: vless"
    echo "    server: $server"
    echo "    port: $port"
    echo "    uuid: $uuid"
    echo "    network: grpc"
    echo "    udp: true"
    echo "    grpc-opts:"
    echo "      grpc-service-name: \"$service\""
    echo "    tls: true"
    echo "    servername: $sni"
    if [[ -n "$public_key" ]]; then
        echo "    reality-opts:"
        echo "      public-key: $public_key"
        echo "      short-id: $short_id"
    fi
    echo "    client-fingerprint: $fingerprint"
}

# Interactive: manual input for exit-node
_ask_exit_vless_grpc() {
    local proxy_name="$1"
    echo "" >&2
    read -rp "Домен или IP exit-ноды: " C_SERVER
    [[ -z "$C_SERVER" ]] && { warn "Сервер не указан"; return; }
    read -rp "Порт [Enter = 443]: " C_PORT
    C_PORT="${C_PORT:-443}"
    read -rp "UUID: " C_UUID
    [[ -z "$C_UUID" ]] && { warn "UUID не указан"; return; }
    read -rp "Public key: " C_PUBKEY
    [[ -z "$C_PUBKEY" ]] && { warn "Public key не указан"; return; }
    read -rp "Short ID: " C_SHORT_ID
    [[ -z "$C_SHORT_ID" ]] && { warn "Short ID не указан"; return; }
    read -rp "SNI [Enter = $C_SERVER]: " C_SNI
    C_SNI="${C_SNI:-$C_SERVER}"
    read -rp "Service name: " C_SERVICE
    [[ -z "$C_SERVICE" ]] && { warn "Service name не указан"; return; }

    echo "" >&2
    info "Exit: $C_SERVER:$C_PORT VLESS gRPC Reality" >&2

    _build_vless_grpc_exit_yaml "$proxy_name" "$C_SERVER" "$C_PORT" "$C_UUID" "$C_SNI" "$C_SERVICE" "$C_PUBKEY" "$C_SHORT_ID"
}
