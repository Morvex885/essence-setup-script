#!/bin/bash
# ─── VLESS xHTTP protocol builders ──────────────────────────────────────────

# Listener YAML with Reality (server-side)
# Args: name listen port username uuid path dest private_key short_id sni proxy
_build_vless_xhttp_listener_yaml() {
    local name="$1" listen="$2" port="$3" username="$4" uuid="$5"
    local path="$6" dest="$7" private_key="$8" short_id="$9" sni="${10}" proxy="${11}"
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
    xhttp-config:
      path: "$path"
      mode: auto
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

# Listener YAML with nginx TLS (server-side)
# Args: name listen port username uuid path cert key proxy
_build_vless_xhttp_tls_listener_yaml() {
    local name="$1" listen="$2" port="$3" username="$4" uuid="$5"
    local path="$6" cert="$7" key="$8" proxy="$9"
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
    xhttp-config:
      path: "$path"
      mode: auto
    certificate: $cert
    private-key: $key
    proxy: $proxy
EOF
}

# Client proxy YAML (unified: Reality if public_key, else TLS)
# Args: name server port uuid sni path [public_key short_id]
_build_vless_xhttp_client_yaml() {
    local name="$1" server="$2" port="$3" uuid="$4" sni="$5"
    local path="$6" public_key="${7:-}" short_id="${8:-}"

    echo "proxies:"
    echo "  - name: \"$name\""
    echo "    type: vless"
    echo "    server: $server"
    echo "    port: $port"
    echo "    uuid: $uuid"
    echo "    network: xhttp"
    echo "    udp: true"
    echo "    tls: true"
    echo "    servername: $sni"
    echo "    xhttp-opts:"
    echo "      path: \"$path\""
    echo "      mode: auto"
    if [[ -n "$public_key" ]]; then
        echo "    reality-opts:"
        echo "      public-key: \"$public_key\""
        echo "      short-id: \"$short_id\""
    fi
    echo "    client-fingerprint: chrome"
}

# Client URI (unified: Reality if public_key, else TLS)
# Args: uuid server port sni path [public_key short_id fragment]
_build_vless_xhttp_uri() {
    local uuid="$1" server="$2" port="$3" sni="$4" path="$5"
    local public_key="${6:-}" short_id="${7:-}" fragment="${8:-VLESS xHTTP}"

    local security_params
    if [[ -n "$public_key" ]]; then
        security_params="security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}"
    else
        security_params="security=tls&sni=${sni}&fp=chrome"
    fi

    echo "vless://${uuid}@${server}:${port}?encryption=none&${security_params}&type=xhttp&path=${path}&mode=auto#${fragment}"
}

# Exit proxy YAML (cascade outbound)
# Args: name server port uuid sni path [mode public_key short_id fingerprint]
_build_vless_xhttp_exit_yaml() {
    local name="$1" server="$2" port="$3" uuid="$4" sni="$5"
    local path="$6" mode="${7:-auto}"
    local public_key="${8:-}" short_id="${9:-}" fingerprint="${10:-chrome}"

    echo "  - name: $name"
    echo "    type: vless"
    echo "    server: $server"
    echo "    port: $port"
    echo "    uuid: $uuid"
    echo "    network: xhttp"
    echo "    udp: true"
    echo "    xhttp-opts:"
    echo "      path: \"$path\""
    echo "      mode: $mode"
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
_ask_exit_vless_xhttp() {
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
    read -rp "Path [Enter = /]: " C_PATH
    C_PATH="${C_PATH:-/}"

    echo "" >&2
    info "Exit: $C_SERVER:$C_PORT VLESS xHTTP Reality" >&2

    _build_vless_xhttp_exit_yaml "$proxy_name" "$C_SERVER" "$C_PORT" "$C_UUID" "$C_SNI" "$C_PATH" "auto" "$C_PUBKEY" "$C_SHORT_ID"
}
