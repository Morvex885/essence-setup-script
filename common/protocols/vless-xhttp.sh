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

# Plain listener behind nginx TLS termination (server-side)
# Args: name listen port username uuid path proxy
_build_vless_xhttp_nginx_listener_yaml() {
    local name="$1" listen="$2" port="$3" username="$4" uuid="$5"
    local path="$6" proxy="$7"
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
    allow-insecure: true
    proxy: $proxy
EOF
}

# Backward-compatible name for callers from an older installed module.
# Certificate/key arguments are intentionally ignored: nginx owns public TLS.
_build_vless_xhttp_tls_listener_yaml() {
    local name="$1" listen="$2" port="$3" username="$4" uuid="$5"
    local path="$6" proxy="$9"
    _build_vless_xhttp_nginx_listener_yaml \
        "$name" "$listen" "$port" "$username" "$uuid" "$path" "$proxy"
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
    echo "    client-fingerprint: firefox"
}

# Client URI (unified: Reality if public_key, else TLS)
# Args: uuid server port sni path [public_key short_id fragment]
_build_vless_xhttp_uri() {
    local uuid="$1" server="$2" port="$3" sni="$4" path="$5"
    local public_key="${6:-}" short_id="${7:-}" fragment="${8:-VLESS xHTTP}"

    local security_params encoded_sni encoded_path encoded_public_key encoded_short_id encoded_fragment
    encoded_sni=$(_uri_percent_encode "$sni") || return 1
    encoded_path=$(_uri_percent_encode "$path") || return 1
    encoded_public_key=$(_uri_percent_encode "$public_key") || return 1
    encoded_short_id=$(_uri_percent_encode "$short_id") || return 1
    encoded_fragment=$(_uri_percent_encode "$fragment") || return 1
    if [[ -n "$public_key" ]]; then
        security_params="security=reality&sni=${encoded_sni}&fp=firefox&pbk=${encoded_public_key}&sid=${encoded_short_id}"
    else
        security_params="security=tls&sni=${encoded_sni}&fp=firefox"
    fi

    echo "vless://${uuid}@${server}:${port}?encryption=none&${security_params}&type=xhttp&path=${encoded_path}&mode=auto#${encoded_fragment}"
}

# Exit proxy YAML (cascade outbound)
# Args: name server port uuid sni path [mode public_key short_id fingerprint]
_build_vless_xhttp_exit_yaml() {
    local name="$1" server="$2" port="$3" uuid="$4" sni="$5"
    local path="$6" mode="${7:-auto}"
    local public_key="${8:-}" short_id="${9:-}"

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
    echo "    client-fingerprint: firefox"
}

# Normalize an extracted proxy block used by remote-control. Non-xHTTP blocks
# are returned byte-for-byte; xHTTP always receives the known-good fingerprint.
_normalize_vless_xhttp_proxy_yaml() {
    local block
    block=$(cat)
    if ! grep -q '^    network: xhttp$' <<< "$block"; then
        printf '%s\n' "$block"
        return
    fi
    if grep -q '^    client-fingerprint:' <<< "$block"; then
        sed 's/^    client-fingerprint:.*/    client-fingerprint: firefox/' <<< "$block"
    else
        printf '%s\n    client-fingerprint: firefox\n' "$block"
    fi
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
