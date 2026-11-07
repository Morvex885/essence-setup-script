#!/bin/bash
# ─── URI parsing for cascade exit-node ──────────────────────────────────────

# RFC 3986 percent-encoding for URI query values and fragments.
_uri_percent_encode() {
    local input="$1" output="" bytes hex char i

    # Iterate over the hexadecimal representation of the raw bytes rather
    # than Bash characters. This keeps multibyte UTF-8 sequences intact on
    # Bash 3.2, regardless of the user's locale.
    bytes=$(printf '%s' "$input" | LC_ALL=C od -An -v -t x1 | tr -d '[:space:]' | tr 'a-f' 'A-F')
    for ((i = 0; i < ${#bytes}; i += 2)); do
        hex="${bytes:i:2}"
        case "$hex" in
            2D|2E|30|31|32|33|34|35|36|37|38|39|4[1-9A-F]|5[0-9A]|5F|6[1-9A-F]|7[0-9A]|7E)
                printf -v char '%b' "\\x${hex}"
                output+="$char"
                ;;
            *)
                output+="%${hex}"
                ;;
        esac
    done
    printf '%s' "$output"
}

# Strict percent-decoder. Malformed escapes and NUL are rejected.
_uri_percent_decode() {
    local input="$1" output="" prefix hex char
    while [[ "$input" == *%* ]]; do
        prefix="${input%%\%*}"
        output+="$prefix"
        input="${input#*%}"
        [[ ${#input} -ge 2 ]] || return 1
        hex="${input:0:2}"
        [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]] || return 1
        input="${input:2}"
        [[ "$hex" != "00" ]] || return 1
        printf -v char '%b' "\\x${hex}"
        output+="$char"
    done
    output+="$input"
    printf '%s' "$output"
}

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
        if ! val=$(_uri_percent_decode "$val"); then
            warn "Некорректное percent-кодирование в VLESS URI"
            return 1
        fi
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
                "$C_UUID" "$C_SNI" "$C_PATH" "$C_MODE" "$C_PUBKEY" "$C_SHORT_ID" "firefox"
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
        if ! val=$(_uri_percent_decode "$val"); then
            warn "Некорректное percent-кодирование в Hysteria2 URI"
            return 1
        fi
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
