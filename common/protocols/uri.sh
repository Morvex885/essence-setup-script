#!/bin/bash
# ─── URI parsing for cascade exit-node ──────────────────────────────────────

# Extract server and port from any supported URI (vless://, hy2://, hysteria2://)
# Sets: URI_SERVER, URI_PORT
_parse_server_port_from_uri() {
    local uri="$1"
    uri="${uri#vless://}"
    uri="${uri#hysteria2://}"
    uri="${uri#hy2://}"
    uri="${uri%%#*}"
    local hostport="${uri#*@}"
    hostport="${hostport%%\?*}"
    URI_SERVER="${hostport%%:*}"
    URI_PORT="${hostport##*:}"
}

# Dispatcher: read URI from user, detect protocol, return exit YAML
# Args: proxy_name
# Outputs: exit proxy YAML on stdout, info on stderr
_parse_proxy_uri() {
    local proxy_name="$1"
    echo "" >&2
    read -rp "Вставьте URI: " URI

    if [[ "$URI" == vless://* ]]; then
        _parse_vless_uri_to_exit "$proxy_name" "$URI"
    elif [[ "$URI" == hysteria2://* || "$URI" == hy2://* ]]; then
        _parse_hy2_uri_to_exit "$proxy_name" "$URI"
    else
        warn "Неизвестный протокол. Поддерживаются: vless://, hysteria2://, hy2://"
        return
    fi
}

# Parse vless:// URI → exit proxy YAML
# Auto-detects transport: tcp (default), xhttp, grpc
_parse_vless_uri_to_exit() {
    local proxy_name="$1" uri="$2"

    # vless://UUID@SERVER:PORT?params#fragment
    uri="${uri#vless://}"
    uri="${uri%%#*}"
    local userinfo="${uri%%@*}"
    local hostport="${uri#*@}"
    local params="${hostport#*\?}"
    hostport="${hostport%%\?*}"

    local C_UUID="$userinfo"
    local C_SERVER="${hostport%%:*}"
    local C_PORT="${hostport##*:}"

    local C_SNI="" C_PUBKEY="" C_SHORT_ID="" C_FLOW="" C_FP="chrome"
    local C_TYPE="tcp" C_PATH="" C_MODE="auto" C_SERVICE=""

    local IFS='&'
    for param in $params; do
        local key="${param%%=*}" val="${param#*=}"
        case "$key" in
            sni)         C_SNI="$val" ;;
            pbk)         C_PUBKEY="$val" ;;
            sid)         C_SHORT_ID="$val" ;;
            flow)        C_FLOW="$val" ;;
            fp)          C_FP="$val" ;;
            type)        C_TYPE="$val" ;;
            path)        C_PATH="$val" ;;
            mode)        C_MODE="$val" ;;
            serviceName) C_SERVICE="$val" ;;
        esac
    done
    unset IFS

    [[ -z "$C_SNI" ]] && C_SNI="$C_SERVER"

    echo "" >&2
    info "VLESS $C_TYPE: $C_SERVER:$C_PORT (SNI: $C_SNI)" >&2

    case "$C_TYPE" in
        tcp)
            [[ -z "$C_FLOW" ]] && C_FLOW="xtls-rprx-vision"
            _build_vless_tcp_exit_yaml "$proxy_name" "$C_SERVER" "$C_PORT" \
                "$C_UUID" "$C_SNI" "$C_PUBKEY" "$C_SHORT_ID" "$C_FLOW" "$C_FP"
            ;;
        xhttp)
            [[ -z "$C_PATH" ]] && C_PATH="/"
            _build_vless_xhttp_exit_yaml "$proxy_name" "$C_SERVER" "$C_PORT" \
                "$C_UUID" "$C_SNI" "$C_PATH" "$C_MODE" "$C_PUBKEY" "$C_SHORT_ID" "$C_FP"
            ;;
        grpc)
            [[ -z "$C_SERVICE" ]] && C_SERVICE="grpc"
            _build_vless_grpc_exit_yaml "$proxy_name" "$C_SERVER" "$C_PORT" \
                "$C_UUID" "$C_SNI" "$C_SERVICE" "$C_PUBKEY" "$C_SHORT_ID" "$C_FP"
            ;;
        *)
            warn "Неизвестный транспорт VLESS: $C_TYPE. Поддерживаются: tcp, xhttp, grpc"
            return
            ;;
    esac
}

# Parse hy2:// / hysteria2:// URI → exit proxy YAML
_parse_hy2_uri_to_exit() {
    local proxy_name="$1" uri="$2"

    uri="${uri#hysteria2://}"
    uri="${uri#hy2://}"
    uri="${uri%%#*}"

    local userinfo="${uri%%@*}"
    local hostport="${uri#*@}"
    local params="${hostport#*\?}"
    hostport="${hostport%%\?*}"

    local C_PASS="$userinfo"
    local C_SERVER="${hostport%%:*}"
    local C_PORT="${hostport##*:}"

    local C_SNI="" C_INSECURE="" C_OBFS_PASS=""

    local IFS='&'
    for param in $params; do
        local key="${param%%=*}" val="${param#*=}"
        case "$key" in
            sni)           C_SNI="$val" ;;
            insecure)      C_INSECURE="$val" ;;
            obfs-password) C_OBFS_PASS="$val" ;;
        esac
    done
    unset IFS

    [[ -z "$C_SNI" ]] && C_SNI="www.google.de"

    local skip_verify="false"
    [[ "$C_INSECURE" == "1" ]] && skip_verify="true"

    echo "" >&2
    info "Hysteria2: $C_SERVER:$C_PORT" >&2
    [[ -n "$C_OBFS_PASS" ]] && info "Obfs: salamander" >&2

    _build_hy2_exit_yaml "$proxy_name" "$C_SERVER" "$C_PORT" "$C_PASS" "$C_SNI" "$skip_verify" "$C_OBFS_PASS"
}
