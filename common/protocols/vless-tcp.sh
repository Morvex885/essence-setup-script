#!/bin/bash
# ─── VLESS TCP protocol builders ────────────────────────────────────────────

# Listener YAML for config.yaml (server-side)
# Args: name listen port username uuid dest private_key short_id sni proxy
_build_vless_tcp_listener_yaml() {
    local name="$1" listen="$2" port="$3" username="$4" uuid="$5"
    local dest="$6" private_key="$7" short_id="$8" sni="$9" proxy="${10}"
    cat <<EOF
  - name: $name
    type: vless
    listen: $listen
    port: $port
    users:
      # client-users-start
      - username: $username
        uuid: $uuid
        flow: xtls-rprx-vision
      # client-users-end
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

# Client proxy YAML for client-config.txt
# Args: name server port uuid sni public_key short_id
_build_vless_tcp_client_yaml() {
    local name="$1" server="$2" port="$3" uuid="$4"
    local sni="$5" public_key="$6" short_id="$7"
    cat <<EOF
proxies:
  - name: "$name"
    type: vless
    server: $server
    port: $port
    uuid: $uuid
    network: tcp
    udp: true
    flow: xtls-rprx-vision
    tls: true
    servername: $sni
    reality-opts:
      public-key: "$public_key"
      short-id: "$short_id"
    client-fingerprint: chrome
EOF
}

# Client URI string
# Args: uuid server port sni public_key short_id [fragment]
_build_vless_tcp_uri() {
    local uuid="$1" server="$2" port="$3" sni="$4"
    local public_key="$5" short_id="$6" fragment="${7:-VLESS TCP}"
    echo "vless://${uuid}@${server}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#${fragment}"
}

# Exit proxy YAML (cascade outbound / proxies section)
# Args: name server port uuid sni [public_key short_id flow fingerprint]
_build_vless_tcp_exit_yaml() {
    local name="$1" server="$2" port="$3" uuid="$4" sni="$5"
    local public_key="${6:-}" short_id="${7:-}"
    local flow="${8:-xtls-rprx-vision}" fingerprint="${9:-chrome}"

    echo "  - name: $name"
    echo "    type: vless"
    echo "    server: $server"
    echo "    port: $port"
    echo "    uuid: $uuid"
    echo "    network: tcp"
    echo "    udp: true"
    [[ -n "$flow" ]] && echo "    flow: $flow"
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
# Args: proxy_name
# Outputs: exit proxy YAML on stdout, messages on stderr
_ask_exit_vless_tcp() {
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

    echo "" >&2
    info "Exit: $C_SERVER:$C_PORT VLESS TCP Reality" >&2

    _build_vless_tcp_exit_yaml "$proxy_name" "$C_SERVER" "$C_PORT" "$C_UUID" "$C_SNI" "$C_PUBKEY" "$C_SHORT_ID"
}
