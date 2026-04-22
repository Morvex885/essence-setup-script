#!/bin/bash
# ─── Hysteria2 protocol builders ────────────────────────────────────────────

# Listener YAML for config.yaml (server-side)
# Args: name port user pass proxy [obfs_pass]
_build_hy2_listener_yaml() {
    local name="$1" port="$2" user="$3" pass="$4" proxy="$5"
    local obfs_pass="${6:-}"

    echo "  - name: $name"
    echo "    type: hysteria2"
    echo "    listen: 0.0.0.0"
    echo "    port: $port"
    echo "    users:"
    echo "      # client-users-start"
    echo "      $user: $pass"
    echo "      # client-users-end"
    if [[ -n "$obfs_pass" ]]; then
        echo "    obfs: salamander"
        echo "    obfs-password: $obfs_pass"
    fi
    echo "    certificate: /etc/mihomo/certs/hy2/server.crt"
    echo "    private-key: /etc/mihomo/certs/hy2/server.key"
    echo "    proxy: $proxy"
}

# Client proxy YAML
# Args: name server port pass [sni skip_verify obfs_pass]
_build_hy2_client_yaml() {
    local name="$1" server="$2" port="$3" pass="$4"
    local sni="${5:-www.google.de}" skip_verify="${6:-true}" obfs_pass="${7:-}"

    echo "proxies:"
    echo "  - name: \"$name\""
    echo "    type: hysteria2"
    echo "    server: $server"
    echo "    port: $port"
    echo "    password: $pass"
    echo "    sni: $sni"
    echo "    skip-cert-verify: $skip_verify"
    if [[ -n "$obfs_pass" ]]; then
        echo "    obfs: salamander"
        echo "    obfs-password: $obfs_pass"
    fi
}

# Client URI
# Args: pass server port [sni obfs_pass]
_build_hy2_uri() {
    local pass="$1" server="$2" port="$3"
    local sni="${4:-www.google.de}" obfs_pass="${5:-}"

    local obfs_params=""
    [[ -n "$obfs_pass" ]] && obfs_params="&obfs=salamander&obfs-password=${obfs_pass}"
    echo "hysteria2://${pass}@${server}:${port}?insecure=1&sni=${sni}${obfs_params}"
}

# Exit proxy YAML (cascade outbound / proxies section)
# Args: name server port pass [sni skip_verify obfs_pass]
_build_hy2_exit_yaml() {
    local name="$1" server="$2" port="$3" pass="$4"
    local sni="${5:-www.google.de}" skip_verify="${6:-true}" obfs_pass="${7:-}"

    echo "  - name: $name"
    echo "    type: hysteria2"
    echo "    server: $server"
    echo "    port: $port"
    echo "    password: $pass"
    echo "    sni: $sni"
    echo "    skip-cert-verify: $skip_verify"
    if [[ -n "$obfs_pass" ]]; then
        echo "    obfs: salamander"
        echo "    obfs-password: $obfs_pass"
    fi
}

# Interactive: manual input for exit-node
_ask_exit_hy2() {
    local proxy_name="$1"
    echo "" >&2
    read -rp "Домен или IP exit-ноды: " C_SERVER
    [[ -z "$C_SERVER" ]] && { warn "Сервер не указан"; return; }
    read -rp "Порт: " C_PORT
    [[ -z "$C_PORT" ]] && { warn "Порт не указан"; return; }
    read -rp "Пароль: " C_PASS
    [[ -z "$C_PASS" ]] && { warn "Пароль не указан"; return; }
    read -rp "SNI [Enter = www.google.de]: " C_SNI
    C_SNI="${C_SNI:-www.google.de}"
    read -rp "Obfs salamander пароль [Enter = нет]: " C_OBFS

    echo "" >&2
    info "Exit: $C_SERVER:$C_PORT Hysteria2" >&2

    _build_hy2_exit_yaml "$proxy_name" "$C_SERVER" "$C_PORT" "$C_PASS" "$C_SNI" "true" "$C_OBFS"
}
