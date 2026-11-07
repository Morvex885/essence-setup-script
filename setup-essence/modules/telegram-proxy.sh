#!/bin/bash
# ─── Telegram Proxy (official MTProxy backend + WEB relay) ──────────────────
#
# WEB and MTProto are independent components.  The official MTProxy process,
# secret, optional tag, firewall and refresh timer are shared by both.

TPROXY_DIR="${TPROXY_DIR:-/etc/tproxy-server}"
TPROXY_CONF="${TPROXY_CONF:-$TPROXY_DIR/essence.conf}"
TPROXY_CONFIG_JSON="${TPROXY_CONFIG_JSON:-$TPROXY_DIR/config.json}"
TPROXY_PROFILES_FILE="${TPROXY_PROFILES_FILE:-$TPROXY_DIR/profiles.json}"
TPROXY_PROFILES_RUNTIME_FILE="${TPROXY_PROFILES_RUNTIME_FILE:-/run/credentials/tproxy-server.service/profiles.json}"
TPROXY_ENV_FILE="${TPROXY_ENV_FILE:-/etc/mtproxy/mtproxy.env}"
TPROXY_MTPROXY_DIR="${TPROXY_MTPROXY_DIR:-/etc/mtproxy}"
TPROXY_RELAY_SOURCE_PATH="${TPROXY_RELAY_SOURCE_PATH:-/opt/tproxy-server-source}"
TPROXY_MTPROXY_SOURCE_DIR="${TPROXY_MTPROXY_SOURCE_DIR:-/opt/MTProxy}"
TPROXY_SITE_DIR="${TPROXY_SITE_DIR:-/srv/tproxy-site}"
TPROXY_BIN="${TPROXY_BIN:-/usr/local/bin/tproxy-server}"
TPROXY_NGINX_SITE="${TPROXY_NGINX_SITE:-/etc/nginx/sites-available/essence-telegram-proxy}"
TPROXY_NGINX_ENABLED="${TPROXY_NGINX_ENABLED:-/etc/nginx/sites-enabled/essence-telegram-proxy}"
TPROXY_NGINX_AVAILABLE_DIR="${TPROXY_NGINX_AVAILABLE_DIR:-$(dirname "$TPROXY_NGINX_SITE")}"
TPROXY_NGINX_ENABLED_DIR="${TPROXY_NGINX_ENABLED_DIR:-$(dirname "$TPROXY_NGINX_ENABLED")}"
TPROXY_NGINX_ACME_SITE="${TPROXY_NGINX_ACME_SITE:-$TPROXY_NGINX_ENABLED_DIR/essence-telegram-proxy-acme}"
TPROXY_NGINX_CONF="${TPROXY_NGINX_CONF:-${NGINX_MAIN_CONFIG:-/etc/nginx/nginx.conf}}"
TPROXY_SYSTEMD_DIR="${TPROXY_SYSTEMD_DIR:-/etc/systemd/system}"
TPROXY_FIREWALL_FILE="${TPROXY_FIREWALL_FILE:-$TPROXY_DIR/firewall.nft}"
TPROXY_TOKEN_KEY="${TPROXY_TOKEN_KEY:-$TPROXY_DIR/token.key}"
TPROXY_REFRESH_BIN="${TPROXY_REFRESH_BIN:-/usr/local/sbin/refresh-mtproxy-config}"
TPROXY_CERT_DIR="${TPROXY_CERT_DIR:-/etc/nginx/ssl}"
TPROXY_ACME_DIR="${TPROXY_ACME_DIR:-$HOME/.acme.sh}"
TPROXY_WEBROOT_BASE="${TPROXY_WEBROOT_BASE:-/var/www}"
TPROXY_IPV6_DISABLE_FILE="${TPROXY_IPV6_DISABLE_FILE:-/proc/sys/net/ipv6/conf/all/disable_ipv6}"
TPROXY_REPO_URL="${TPROXY_REPO_URL:-https://github.com/telegramdesktop/tproxy-server.git}"
TPROXY_UPSTREAM_REVISION=f7a6acc4d536a787d442fd7df3ba4ebfd728f406
TPROXY_UPSTREAM_CHECKSUM=f7a6acc4d536a787d442fd7df3ba4ebfd728f406
TPROXY_READY_ATTEMPTS="${TPROXY_READY_ATTEMPTS:-20}"
TPROXY_HEALTH_URL="${TPROXY_HEALTH_URL:-http://127.0.0.1:8081/healthz}"
TPROXY_READY_URL="${TPROXY_READY_URL:-http://127.0.0.1:8081/readyz}"
TPROXY_METRICS_URL="${TPROXY_METRICS_URL:-http://127.0.0.1:8081/metrics}"
TPROXY_MTPROXY_PORT=2398
TPROXY_MTPROXY_STATS_PORT=8888
TPROXY_UNIT_RELAY="tproxy-server.service"
TPROXY_UNIT_MTPROXY="mtproxy.service"
TPROXY_UNIT_FIREWALL="tproxy-firewall.service"
TPROXY_UNIT_REFRESH="refresh-mtproxy-config.service"
TPROXY_UNIT_TIMER="refresh-mtproxy-config.timer"
TPROXY_NFT_TABLE="tproxy_backend"

TPROXY_ROLLBACK_RUNTIME_CAPTURED=false
TPROXY_ROLLBACK_NFT_EXISTED=false
TPROXY_ROLLBACK_NFT_FILE=""
TPROXY_ROLLBACK_UFW_80=""
TPROXY_ROLLBACK_UFW_2398=""
TPROXY_ROLLBACK_UNIT_EXISTED=()
TPROXY_ROLLBACK_UNIT_NAMES=()
TPROXY_ROLLBACK_UNIT_ACTIVE=()
TPROXY_ROLLBACK_UNIT_ENABLED=()
# ─── Validators and state ───────────────────────────────────────────────────

_telegram_proxy_valid_hostname() {
    local value="${1:-}" label old_ifs
    [[ ${#value} -le 253 && "$value" == "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" ]] || return 1
    [[ "$value" == *.* && "$value" != *://* && "$value" != */* && "$value" != *:* ]] || return 1
    [[ "$value" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] || return 1
    old_ifs="$IFS"; IFS=.
    for label in $value; do [[ ${#label} -le 63 ]] || { IFS="$old_ifs"; return 1; }; done
    IFS="$old_ifs"
}

_telegram_proxy_valid_email() {
    [[ "${1:-}" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]
}

_telegram_proxy_valid_secret() { [[ "${1:-}" =~ ^[a-f0-9]{32}$ ]]; }
_telegram_proxy_valid_tag() { [[ "${1:-}" =~ ^[a-fA-F0-9]{32}$ ]]; }

_telegram_proxy_valid_bool() { [[ "${1:-}" == true || "${1:-}" == false ]]; }

_telegram_proxy_valid_public_ipv4() {
    local value="${1:-}" part old_ifs octets i n
    [[ "$value" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
    old_ifs="$IFS"; IFS=.; octets=($value); IFS="$old_ifs"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for part in "${octets[@]}"; do [[ "$part" =~ ^[0-9]+$ && "$part" -le 255 ]] || return 1; done
    n=${octets[0]}
    (( n > 0 && n < 224 )) || return 1
    (( n != 10 && n != 127 )) || return 1
    if (( n == 100 && octets[1] >= 64 && octets[1] <= 127 )); then return 1; fi
    if (( n == 169 && octets[1] == 254 )); then return 1; fi
    if (( n == 172 && octets[1] >= 16 && octets[1] <= 31 )); then return 1; fi
    if (( n == 192 && octets[1] == 168 )); then return 1; fi
    if (( n == 192 && octets[1] == 0 && octets[2] == 0 )); then return 1; fi
    if (( n == 192 && octets[1] == 0 && octets[2] == 2 )); then return 1; fi
    if (( n == 198 && octets[1] >= 18 && octets[1] <= 19 )); then return 1; fi
    if (( n == 198 && octets[1] == 51 && octets[2] == 100 )); then return 1; fi
    if (( n == 203 && octets[1] == 0 && octets[2] == 113 )); then return 1; fi
    if (( n == 192 && octets[1] == 0 && octets[2] == 0 && octets[3] == 0 )); then return 1; fi
    return 0
}

_telegram_proxy_generate_secret() {
    local value
    value=$(openssl rand -hex 16 2>/dev/null) || return 1
    _telegram_proxy_valid_secret "$value" || return 1
    printf '%s\n' "$value"
}

_telegram_proxy_reset_state_vars() {
    TELEGRAM_PROXY_STATE_VERSION=""
    TELEGRAM_WEB_ENABLED=""
    TELEGRAM_MTPROTO_ENABLED=""
    TELEGRAM_TAG_CONFIGURED=""
    TELEGRAM_WEB_HOSTNAME=""
    TELEGRAM_WEB_EMAIL=""
    TELEGRAM_WEB_TOPOLOGY=""
    TELEGRAM_WEB_TLS_LISTEN=""
    TELEGRAM_WEB_IPV6=""
    TELEGRAM_RELAY_SOURCE_PATH=""
    TELEGRAM_RELAY_UPSTREAM_SHA=""
    TELEGRAM_MTPROTO_IPV4=""
    TELEGRAM_MTPROTO_PORT=""
    TELEGRAM_UFW_MTPROTO_PREVIOUS=""
    TPROXY_CREATED_USER=""
    MTPROXY_CREATED_USER=""
}

_telegram_proxy_load_conf() {
    [[ -f "$TPROXY_CONF" ]] || return 1
    _telegram_proxy_reset_state_vars
    local key value
    local have_version=false have_web=false have_mtproto=false have_tag=false
    local have_mtp_port=false have_created=false have_mt_created=false
    local have_web_host=false have_web_email=false have_web_topology=false
    local have_web_listen=false have_web_ipv6=false have_relay_path=false
    local have_relay_sha=false have_mt_ip=false have_ufw_previous=false
    while IFS='=' read -r key value; do
        key=${key//$'\r'/}
        value=${value%$'\r'}
        case "$key" in
            TELEGRAM_PROXY_STATE_VERSION) TELEGRAM_PROXY_STATE_VERSION="$value"; have_version=true ;;
            TELEGRAM_WEB_ENABLED) TELEGRAM_WEB_ENABLED="$value"; have_web=true ;;
            TELEGRAM_MTPROTO_ENABLED) TELEGRAM_MTPROTO_ENABLED="$value"; have_mtproto=true ;;
            TELEGRAM_TAG_CONFIGURED) TELEGRAM_TAG_CONFIGURED="$value"; have_tag=true ;;
            TELEGRAM_WEB_HOSTNAME) TELEGRAM_WEB_HOSTNAME="$value"; have_web_host=true ;;
            TELEGRAM_WEB_EMAIL) TELEGRAM_WEB_EMAIL="$value"; have_web_email=true ;;
            TELEGRAM_WEB_TOPOLOGY) TELEGRAM_WEB_TOPOLOGY="$value"; have_web_topology=true ;;
            TELEGRAM_WEB_TLS_LISTEN) TELEGRAM_WEB_TLS_LISTEN="$value"; have_web_listen=true ;;
            TELEGRAM_WEB_IPV6) TELEGRAM_WEB_IPV6="$value"; have_web_ipv6=true ;;
            TELEGRAM_RELAY_SOURCE_PATH) TELEGRAM_RELAY_SOURCE_PATH="$value"; have_relay_path=true ;;
            TELEGRAM_RELAY_UPSTREAM_SHA) TELEGRAM_RELAY_UPSTREAM_SHA="$value"; have_relay_sha=true ;;
            TELEGRAM_MTPROTO_IPV4) TELEGRAM_MTPROTO_IPV4="$value"; have_mt_ip=true ;;
            TELEGRAM_MTPROTO_PORT) TELEGRAM_MTPROTO_PORT="$value"; have_mtp_port=true ;;
            TELEGRAM_UFW_MTPROTO_PREVIOUS) TELEGRAM_UFW_MTPROTO_PREVIOUS="$value"; have_ufw_previous=true ;;
            TPROXY_CREATED_USER) TPROXY_CREATED_USER="$value"; have_created=true ;;
            MTPROXY_CREATED_USER) MTPROXY_CREATED_USER="$value"; have_mt_created=true ;;
        esac
    done < "$TPROXY_CONF"
    [[ "$have_version" == true && "$have_web" == true && "$have_mtproto" == true &&
       "$have_tag" == true && "$have_mtp_port" == true && "$have_created" == true &&
       "$have_mt_created" == true ]] || return 1
    [[ "$TELEGRAM_PROXY_STATE_VERSION" == 1 ]] || return 1
    _telegram_proxy_valid_bool "$TELEGRAM_WEB_ENABLED" &&
        _telegram_proxy_valid_bool "$TELEGRAM_MTPROTO_ENABLED" &&
        _telegram_proxy_valid_bool "$TELEGRAM_TAG_CONFIGURED" || return 1
    [[ "$TELEGRAM_WEB_ENABLED" == true || "$TELEGRAM_MTPROTO_ENABLED" == true ]] || return 1
    _telegram_proxy_valid_bool "$TPROXY_CREATED_USER" &&
        _telegram_proxy_valid_bool "$MTPROXY_CREATED_USER" || return 1
    [[ "$TELEGRAM_MTPROTO_PORT" == 2398 ]] || return 1
    if [[ "$TELEGRAM_WEB_ENABLED" == true ]]; then
        [[ "$have_web_host" == true && "$have_web_email" == true &&
           "$have_web_topology" == true && "$have_web_listen" == true &&
           "$have_web_ipv6" == true && "$have_relay_path" == true &&
           "$have_relay_sha" == true ]] || return 1
        _telegram_proxy_valid_hostname "$TELEGRAM_WEB_HOSTNAME" &&
            _telegram_proxy_valid_email "$TELEGRAM_WEB_EMAIL" || return 1
        case "$TELEGRAM_WEB_TOPOLOGY" in
            direct) [[ "$TELEGRAM_WEB_TLS_LISTEN" == 0.0.0.0:443 ]] || return 1 ;;
            self-steal) [[ "$TELEGRAM_WEB_TLS_LISTEN" == 127.0.0.1:8443 ]] || return 1 ;;
            sni) [[ "$TELEGRAM_WEB_TLS_LISTEN" == 127.0.0.1:8446 ]] || return 1 ;;
            *) return 1 ;;
        esac
        [[ "$TELEGRAM_RELAY_UPSTREAM_SHA" == "$TPROXY_UPSTREAM_CHECKSUM" ]] || return 1
        _telegram_proxy_valid_bool "$TELEGRAM_WEB_IPV6" || return 1
        [[ "$TELEGRAM_RELAY_SOURCE_PATH" == "$TPROXY_RELAY_SOURCE_PATH" ]] || return 1
    else
        [[ "$have_web_host" == true && "$have_web_email" == true &&
           "$have_web_topology" == true && "$have_web_listen" == true &&
           "$have_web_ipv6" == true && "$have_relay_path" == true &&
           "$have_relay_sha" == true ]] || return 1
        [[ -z "$TELEGRAM_WEB_HOSTNAME" && -z "$TELEGRAM_WEB_EMAIL" &&
           -z "$TELEGRAM_WEB_TOPOLOGY" && -z "$TELEGRAM_WEB_TLS_LISTEN" &&
           -z "$TELEGRAM_WEB_IPV6" && -z "$TELEGRAM_RELAY_SOURCE_PATH" &&
           -z "$TELEGRAM_RELAY_UPSTREAM_SHA" ]] || return 1
    fi
    if [[ "$TELEGRAM_MTPROTO_ENABLED" == true ]]; then
        [[ "$have_mt_ip" == true && "$have_ufw_previous" == true ]] || return 1
        _telegram_proxy_valid_public_ipv4 "$TELEGRAM_MTPROTO_IPV4" || return 1
        [[ "$TELEGRAM_UFW_MTPROTO_PREVIOUS" == allow ||
           "$TELEGRAM_UFW_MTPROTO_PREVIOUS" == deny ||
           "$TELEGRAM_UFW_MTPROTO_PREVIOUS" == absent ]] || return 1
    else
        [[ "$have_mt_ip" == true && "$have_ufw_previous" == true &&
           -z "$TELEGRAM_MTPROTO_IPV4" && -z "$TELEGRAM_UFW_MTPROTO_PREVIOUS" ]] || return 1
    fi
    return 0
}

_telegram_proxy_read_env() {
    local key value secret="" args="" raw_args=""
    [[ -r "$TPROXY_ENV_FILE" ]] || return 1
    while IFS='=' read -r key value; do
        key=${key//$'\r'/}
        value=${value%$'\r'}
        case "$key" in
            MTPROXY_SECRET) secret="$value" ;;
            MTPROXY_TAG_ARGS) raw_args="$value" ;;
        esac
    done < "$TPROXY_ENV_FILE"
    case "$raw_args" in
        "") args="" ;;
        \"*\") args="${raw_args#\"}"; args="${args%\"}" ;;
        *) return 1 ;;
    esac
    _telegram_proxy_valid_secret "$secret" || return 1
    TPROXY_RUNTIME_SECRET="$secret"
    TPROXY_RUNTIME_TAG_ARGS="$args"
    TPROXY_RUNTIME_TAG=""
    if [[ -n "$args" ]]; then
        [[ "$args" =~ ^-P[[:space:]][a-fA-F0-9]{32}$ ]] || return 1
        TPROXY_RUNTIME_TAG="${args#-P }"
        _telegram_proxy_valid_tag "$TPROXY_RUNTIME_TAG" || return 1
        TPROXY_RUNTIME_TAG=$(printf '%s' "$TPROXY_RUNTIME_TAG" | tr '[:upper:]' '[:lower:]')
        TPROXY_RUNTIME_TAG_ARGS="-P $TPROXY_RUNTIME_TAG"
    fi
    return 0
}

_telegram_proxy_state_write() {
    local tmp old_umask
    [[ "$TELEGRAM_PROXY_STATE_VERSION" == 1 ]] || return 1
    _telegram_proxy_valid_bool "$TELEGRAM_WEB_ENABLED" && _telegram_proxy_valid_bool "$TELEGRAM_MTPROTO_ENABLED" && _telegram_proxy_valid_bool "$TELEGRAM_TAG_CONFIGURED" || return 1
    [[ "$TELEGRAM_WEB_ENABLED" == true || "$TELEGRAM_MTPROTO_ENABLED" == true ]] || return 1
    _telegram_proxy_valid_bool "$TPROXY_CREATED_USER" && _telegram_proxy_valid_bool "$MTPROXY_CREATED_USER" || return 1
    if [[ "$TELEGRAM_WEB_ENABLED" == true ]]; then
        _telegram_proxy_valid_hostname "$TELEGRAM_WEB_HOSTNAME" && _telegram_proxy_valid_email "$TELEGRAM_WEB_EMAIL" || return 1
        case "$TELEGRAM_WEB_TOPOLOGY" in
            direct) [[ "$TELEGRAM_WEB_TLS_LISTEN" == 0.0.0.0:443 ]] || return 1 ;;
            self-steal) [[ "$TELEGRAM_WEB_TLS_LISTEN" == 127.0.0.1:8443 ]] || return 1 ;;
            sni) [[ "$TELEGRAM_WEB_TLS_LISTEN" == 127.0.0.1:8446 ]] || return 1 ;;
            *) return 1 ;;
        esac
        _telegram_proxy_valid_bool "$TELEGRAM_WEB_IPV6" || return 1
        [[ "$TELEGRAM_RELAY_SOURCE_PATH" == "$TPROXY_RELAY_SOURCE_PATH" && "$TELEGRAM_RELAY_UPSTREAM_SHA" == "$TPROXY_UPSTREAM_CHECKSUM" ]] || return 1
    else
        TELEGRAM_WEB_HOSTNAME=""; TELEGRAM_WEB_EMAIL=""; TELEGRAM_WEB_TOPOLOGY=""; TELEGRAM_WEB_TLS_LISTEN=""; TELEGRAM_WEB_IPV6=""; TELEGRAM_RELAY_SOURCE_PATH=""; TELEGRAM_RELAY_UPSTREAM_SHA=""
    fi
    if [[ "$TELEGRAM_MTPROTO_ENABLED" == true ]]; then
        _telegram_proxy_valid_public_ipv4 "$TELEGRAM_MTPROTO_IPV4" || return 1
        [[ "$TELEGRAM_UFW_MTPROTO_PREVIOUS" == allow || "$TELEGRAM_UFW_MTPROTO_PREVIOUS" == deny || "$TELEGRAM_UFW_MTPROTO_PREVIOUS" == absent ]] || return 1
    else
        TELEGRAM_MTPROTO_IPV4=""; TELEGRAM_UFW_MTPROTO_PREVIOUS=""
    fi
    mkdir -p "$(dirname "$TPROXY_CONF")" || return 1
    old_umask=$(umask); umask 077; tmp="$TPROXY_CONF.tmp.$$"
    cat > "$tmp" <<EOF
TELEGRAM_PROXY_STATE_VERSION=1
TELEGRAM_WEB_ENABLED=${TELEGRAM_WEB_ENABLED}
TELEGRAM_MTPROTO_ENABLED=${TELEGRAM_MTPROTO_ENABLED}
TELEGRAM_TAG_CONFIGURED=${TELEGRAM_TAG_CONFIGURED}
TELEGRAM_WEB_HOSTNAME=${TELEGRAM_WEB_HOSTNAME}
TELEGRAM_WEB_EMAIL=${TELEGRAM_WEB_EMAIL}
TELEGRAM_WEB_TOPOLOGY=${TELEGRAM_WEB_TOPOLOGY}
TELEGRAM_WEB_TLS_LISTEN=${TELEGRAM_WEB_TLS_LISTEN}
TELEGRAM_WEB_IPV6=${TELEGRAM_WEB_IPV6}
TELEGRAM_RELAY_SOURCE_PATH=${TELEGRAM_RELAY_SOURCE_PATH}
TELEGRAM_RELAY_UPSTREAM_SHA=${TELEGRAM_RELAY_UPSTREAM_SHA}
TELEGRAM_MTPROTO_IPV4=${TELEGRAM_MTPROTO_IPV4}
TELEGRAM_MTPROTO_PORT=2398
TELEGRAM_UFW_MTPROTO_PREVIOUS=${TELEGRAM_UFW_MTPROTO_PREVIOUS}
TPROXY_CREATED_USER=${TPROXY_CREATED_USER}
MTPROXY_CREATED_USER=${MTPROXY_CREATED_USER}
EOF
    chmod 0600 "$tmp" && mv -f "$tmp" "$TPROXY_CONF"; local rc=$?; umask "$old_umask"; return "$rc"
}

_telegram_proxy_runtime_consistent() {
    _telegram_proxy_read_env || return 1
    if [[ "$TELEGRAM_TAG_CONFIGURED" == true ]]; then
        [[ -n "$TPROXY_RUNTIME_TAG" ]] || return 1
    else
        [[ -z "$TPROXY_RUNTIME_TAG" && -z "$TPROXY_RUNTIME_TAG_ARGS" ]] || return 1
    fi
    if [[ "$TELEGRAM_WEB_ENABLED" == true ]]; then
        [[ -r "$TPROXY_PROFILES_FILE" ]] || return 1
        local profile_secret
        if command -v jq >/dev/null 2>&1; then profile_secret=$(jq -r '.profiles[]? | select(.name == "default") | .secret // empty' "$TPROXY_PROFILES_FILE" 2>/dev/null | tr -d '\r' | awk 'NR == 1 { print; exit }'); else profile_secret=$(sed -n 's/.*"secret"[[:space:]]*:[[:space:]]*"\([a-f0-9]\{32\}\)".*/\1/p' "$TPROXY_PROFILES_FILE" | awk 'NR == 1 { print; exit }'); fi
        [[ "$profile_secret" == "$TPROXY_RUNTIME_SECRET" ]] || return 1
    else
        [[ ! -e "$TPROXY_PROFILES_FILE" ]] || return 1
    fi
}

_telegram_proxy_is_installed() { _telegram_proxy_load_conf && _telegram_proxy_runtime_consistent; }
_telegram_proxy_component_enabled() { _telegram_proxy_load_conf && { [[ "$1" == web && "$TELEGRAM_WEB_ENABLED" == true ]] || [[ "$1" == mtproto && "$TELEGRAM_MTPROTO_ENABLED" == true ]]; }; }
_telegram_proxy_state_complete() { _telegram_proxy_is_installed; }

# ─── Backend artifacts ───────────────────────────────────────────────────────

_telegram_proxy_atomic_copy() {
    local source="$1" target="$2" mode="${3:-0644}" tmp old_umask
    mkdir -p "$(dirname "$target")" || return 1
    tmp="$(dirname "$target")/.telegram-proxy.$$.tmp"
    old_umask=$(umask)
    umask 077
    cp "$source" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$target"
    local rc=$?
    umask "$old_umask"
    rm -f "$tmp"
    return "$rc"
}

_telegram_proxy_render_relay_config() {
    local hostname="$1" tmp
    _telegram_proxy_valid_hostname "$hostname" || return 1
    mkdir -p "$TPROXY_DIR" || return 1; tmp="$TPROXY_CONFIG_JSON.tmp.$$"
    cat > "$tmp" <<EOF
{
  "public_hostname": "${hostname}",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
  "public_dir": "${TPROXY_SITE_DIR}",
  "profiles_file": "${TPROXY_PROFILES_RUNTIME_FILE}"
}
EOF
    chmod 0640 "$tmp" && mv -f "$tmp" "$TPROXY_CONFIG_JSON"; local rc=$?; rm -f "$tmp"; [[ $rc -eq 0 ]] || return 1
    if getent group tproxy >/dev/null 2>&1; then
        chown root:tproxy "$TPROXY_CONFIG_JSON" || return 1
    fi
    return 0
}

_telegram_proxy_render_profiles() {
    local secret="$1" tmp old_umask
    _telegram_proxy_valid_secret "$secret" || return 1
    mkdir -p "$(dirname "$TPROXY_PROFILES_FILE")" || return 1; old_umask=$(umask); umask 077; tmp="$TPROXY_PROFILES_FILE.tmp.$$"
    printf '{"profiles":[{"name":"default","secret":"%s","backend":"127.0.0.1:2398","carrier_mode":"https"}]}\n' "$secret" > "$tmp" || { rm -f "$tmp"; umask "$old_umask"; return 1; }

    chmod 0400 "$tmp" && mv -f "$tmp" "$TPROXY_PROFILES_FILE"; local rc=$?; rm -f "$tmp"; umask "$old_umask"; [[ $rc -eq 0 ]] || return 1
    if getent group tproxy >/dev/null 2>&1; then chown root:tproxy "$TPROXY_PROFILES_FILE" 2>/dev/null || return 1; fi
}

_telegram_proxy_ensure_token_key() {
    local key="${1:-$TPROXY_TOKEN_KEY}" tmp bytes
    if [[ -L "$key" ]] || { [[ -e "$key" ]] && [[ ! -f "$key" ]]; }; then
        return 1
    fi
    mkdir -p "$(dirname "$key")" || return 1
    if [[ ! -e "$key" ]]; then
        tmp=$(umask 077; mktemp "${key}.XXXXXX") || return 1
        if ! head -c 32 /dev/urandom > "$tmp" ||
           ! chmod 0400 "$tmp" ||
           ! chown tproxy:tproxy "$tmp" ||
           ! ln "$tmp" "$key"; then
            rm -f "$tmp"
            return 1
        fi
        rm -f "$tmp"
    fi
    bytes=$(wc -c < "$key" 2>/dev/null | tr -d '[:space:]')
    [[ "$bytes" == 32 ]] || return 1
    chown tproxy:tproxy "$key" || return 1
    chmod 0400 "$key" || return 1
}

_telegram_proxy_render_mtproxy_env() {
    local secret="$1" tag_args="${2:-}" tag="" tmp old_umask
    _telegram_proxy_valid_secret "$secret" || return 1
    [[ -z "$tag_args" || "$tag_args" =~ ^-P[[:space:]][a-fA-F0-9]{32}$ ]] || return 1
    mkdir -p "$(dirname "$TPROXY_ENV_FILE")" || return 1
    old_umask=$(umask)
    umask 077
    tmp="$TPROXY_ENV_FILE.tmp.$$"
    if [[ -n "$tag_args" ]]; then
        tag="${tag_args#-P}"
        tag=$(printf '%s' "$tag" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        tag_args="-P $tag"
    fi
    cat > "$tmp" <<EOF
MTPROXY_SECRET=${secret}
MTPROXY_TAG_ARGS="${tag_args}"
MTPROXY_WORKERS=1
MTPROXY_MAX_CONNECTIONS=4096
EOF
    chmod 0640 "$tmp" && mv -f "$tmp" "$TPROXY_ENV_FILE"
    local rc=$?
    umask "$old_umask"
    [[ $rc -eq 0 ]] || {
        rm -f "$tmp"
        return 1
    }
    if getent group mtproxy >/dev/null 2>&1; then
        chown root:mtproxy "$TPROXY_ENV_FILE" 2>/dev/null || return 1
    fi
}

_telegram_proxy_validate_upstream_unit() {
    local unit="$1" count
    [[ -r "$unit" ]] || return 1
    count=$(grep -c '^ExecStart=' "$unit" 2>/dev/null || true); [[ "$count" == 1 ]] || return 1
    grep -Eq -- '-p[[:space:]]+8888' "$unit" || return 1
    grep -Eq -- '-H[[:space:]]+2398' "$unit" || return 1
    grep -Eq -- '-S[[:space:]]+\$\{?MTPROXY_SECRET\}?' "$unit" || return 1
    grep -Eq 'MTPROXY_(WORKERS|MAX_CONNECTIONS)' "$unit" || return 1
}

_telegram_proxy_render_mtproxy_unit() {
    local source="$1" target="$2" env_file="$TPROXY_ENV_FILE"
    _telegram_proxy_validate_upstream_unit "$source" || return 1
    grep -Eq -- '--aes-pwd' "$source" || return 1
    mkdir -p "$(dirname "$target")" || return 1
    awk -v env_file="$env_file" '
        BEGIN { done = 0; service = 0 }
        /^EnvironmentFile=/ { next }
        /^\[Service\]$/ {
            print
            print "EnvironmentFile=" env_file
            service = 1
            next
        }
        /^ExecStart=/ {
            sub(/[[:space:]]+--aes-pwd/, " \$MTPROXY_TAG_ARGS --aes-pwd")
            print
            done = 1
            next
        }
        { print }
        END { if (!done || !service) exit 2 }
    ' "$source" > "$target.tmp.$$" || {
        rm -f "$target.tmp.$$"
        return 1
    }
    chmod 0644 "$target.tmp.$$" && mv -f "$target.tmp.$$" "$target" || {
        rm -f "$target.tmp.$$"
        return 1
    }
    [[ "$(grep -cF '$MTPROXY_TAG_ARGS' "$target" 2>/dev/null || true)" == 1 ]] &&
        [[ "$(grep -c '^EnvironmentFile=' "$target" 2>/dev/null || true)" == 1 ]]
    return 0
}

_telegram_proxy_render_firewall() {
    local mtproto_enabled="${1:-false}" tmp
    _telegram_proxy_valid_bool "$mtproto_enabled" || return 1
    mkdir -p "$(dirname "$TPROXY_FIREWALL_FILE")" || return 1
    tmp="$TPROXY_FIREWALL_FILE.tmp.$$"
    cat > "$tmp" <<EOF
table inet ${TPROXY_NFT_TABLE} {
    chain input {
        type filter hook input priority -10; policy accept;
        iifname != "lo" tcp dport { 8888, 8080, 8081 } drop
EOF
    if [[ "$mtproto_enabled" != true ]]; then
        printf '        iifname != "lo" tcp dport 2398 drop\n' >> "$tmp"
    fi
    cat >> "$tmp" <<EOF
    }
}
EOF
    chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$TPROXY_FIREWALL_FILE" || { rm -f "$tmp"; return 1; }
    return 0
}

_telegram_proxy_clone_upstream() {
    local stage="$1" revision="${2:-$TPROXY_UPSTREAM_REVISION}" actual
    git clone --filter=blob:none --no-checkout "$TPROXY_REPO_URL" "$stage" >/dev/null 2>&1 || return 1
    git -C "$stage" fetch --depth 1 origin "$revision" >/dev/null 2>&1 || return 1
    git -C "$stage" checkout --detach "$revision" >/dev/null 2>&1 || return 1
    actual=$(git -C "$stage" rev-parse HEAD 2>/dev/null) || return 1
    [[ "$actual" == "$revision" && "$actual" == "$TPROXY_UPSTREAM_CHECKSUM" ]]
}

_telegram_proxy_validate_upstream_firewall_unit() {
    local unit="$1"
    [[ -r "$unit" ]] || return 1
    grep -Eq '/etc/tproxy-server/firewall\.nft([[:space:]]|$)' "$unit"
}

_telegram_proxy_install_backend() {
    local backend_source="${1:-$TPROXY_RELAY_SOURCE_PATH}" unit_source firewall_source
    [[ -f "$backend_source/deploy/install-mtproxy.sh" ]] || return 1
    unit_source="$backend_source/deploy/mtproxy.service"
    [[ -f "$unit_source" ]] || unit_source="$backend_source/deploy/mtproxy.service.in"
    firewall_source="$backend_source/deploy/tproxy-firewall.service"
    [[ -f "$firewall_source" ]] || return 1
    [[ -f "$backend_source/deploy/refresh-mtproxy-config.service" &&
       -f "$backend_source/deploy/refresh-mtproxy-config.timer" &&
       -f "$backend_source/deploy/refresh-mtproxy-config.sh" ]] || return 1
    # Validate all upstream literals before invoking an installer that can
    # mutate the host.  Never guess a transformation after upstream drift.
    _telegram_proxy_validate_upstream_unit "$unit_source" || return 1
    _telegram_proxy_validate_upstream_firewall_unit "$firewall_source" || return 1
    bash "$backend_source/deploy/install-mtproxy.sh" || return 1
    mkdir -p "$TPROXY_SYSTEMD_DIR" "$TPROXY_MTPROXY_DIR" || return 1
    _telegram_proxy_render_mtproxy_unit "$unit_source" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" || return 1
    install -m 0644 "$firewall_source" "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_FIREWALL" &&
        install -m 0644 "$backend_source/deploy/refresh-mtproxy-config.service" "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_REFRESH" &&
        install -m 0644 "$backend_source/deploy/refresh-mtproxy-config.timer" "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_TIMER" &&
        install -m 0755 "$backend_source/deploy/refresh-mtproxy-config.sh" "$TPROXY_REFRESH_BIN" || return 1
    _telegram_proxy_render_firewall "${TELEGRAM_MTPROTO_ENABLED:-false}" || return 1
    chown root:root "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_FIREWALL" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_REFRESH" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_TIMER" "$TPROXY_REFRESH_BIN" || return 1
    chmod 0644 "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_FIREWALL" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_REFRESH" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_TIMER" || return 1
    chmod 0755 "$TPROXY_REFRESH_BIN" || return 1
}

_telegram_proxy_initialize_state() {
    TELEGRAM_PROXY_STATE_VERSION=1
    TELEGRAM_WEB_ENABLED=false
    TELEGRAM_MTPROTO_ENABLED=false
    TELEGRAM_TAG_CONFIGURED=false
    TELEGRAM_WEB_HOSTNAME=""
    TELEGRAM_WEB_EMAIL=""
    TELEGRAM_WEB_TOPOLOGY=""
    TELEGRAM_WEB_TLS_LISTEN=""
    TELEGRAM_WEB_IPV6=""
    TELEGRAM_RELAY_SOURCE_PATH=""
    TELEGRAM_RELAY_UPSTREAM_SHA=""
    TELEGRAM_MTPROTO_IPV4=""
    TELEGRAM_MTPROTO_PORT=2398
    TELEGRAM_UFW_MTPROTO_PREVIOUS=""
    TPROXY_CREATED_USER=false
    MTPROXY_CREATED_USER=false
}

_telegram_proxy_reject_unmanaged_state() {
    if [[ -f "$TPROXY_CONF" ]]; then
        _telegram_proxy_load_conf && return 0
        warn "Найден некорректный или устаревший state Telegram Proxy; автоматическое переиспользование запрещено."
        return 1
    fi
    if [[ -e "$TPROXY_ENV_FILE" || -e "$TPROXY_MTPROXY_SOURCE_DIR" ||
          -e "$TPROXY_RELAY_SOURCE_PATH" ||
          -e "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" ||
          -e "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_RELAY" ]]; then
        warn "Найдены неуправляемые артефакты Telegram Proxy; удалите их явно перед установкой."
        return 1
    fi
    _telegram_proxy_initialize_state
}

_telegram_proxy_snapshot_runtime() {
    local unit active enabled existed i
    TPROXY_ROLLBACK_RUNTIME_CAPTURED=true
    TPROXY_ROLLBACK_UNIT_NAMES=(
        "$TPROXY_UNIT_RELAY" "$TPROXY_UNIT_MTPROXY"
        "$TPROXY_UNIT_FIREWALL" "$TPROXY_UNIT_REFRESH" "$TPROXY_UNIT_TIMER"
    )
    TPROXY_ROLLBACK_UNIT_EXISTED=()
    TPROXY_ROLLBACK_UNIT_ACTIVE=()
    TPROXY_ROLLBACK_UNIT_ENABLED=()
    if command -v systemctl >/dev/null 2>&1; then
        for unit in "${TPROXY_ROLLBACK_UNIT_NAMES[@]}"; do
            if [[ -e "$TPROXY_SYSTEMD_DIR/$unit" ]]; then existed=true
            else existed=false; fi
            if systemctl is-active --quiet "$unit" 2>/dev/null; then active=active
            else active=inactive; fi
            if systemctl is-enabled --quiet "$unit" 2>/dev/null; then enabled=enabled
            else enabled=disabled; fi
            TPROXY_ROLLBACK_UNIT_EXISTED+=("$existed")
            TPROXY_ROLLBACK_UNIT_ACTIVE+=("$active")
            TPROXY_ROLLBACK_UNIT_ENABLED+=("$enabled")
        done
    fi
    TPROXY_ROLLBACK_UFW_80=$(_telegram_proxy_ufw_port_state 80)
    TPROXY_ROLLBACK_UFW_2398=$(_telegram_proxy_ufw_port_state 2398)
    TPROXY_ROLLBACK_NFT_FILE="$TPROXY_ROLLBACK_DIR/nft.table"
    if command -v nft >/dev/null 2>&1 &&
       nft list table inet "$TPROXY_NFT_TABLE" > "$TPROXY_ROLLBACK_NFT_FILE" 2>/dev/null; then
        TPROXY_ROLLBACK_NFT_EXISTED=true
    else
        TPROXY_ROLLBACK_NFT_EXISTED=false
        rm -f "$TPROXY_ROLLBACK_NFT_FILE"
    fi
}

_telegram_proxy_restore_runtime() {
    local i unit rc=0
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || rc=1
        for i in "${!TPROXY_ROLLBACK_UNIT_NAMES[@]}"; do
            unit="${TPROXY_ROLLBACK_UNIT_NAMES[$i]}"
            if [[ "${TPROXY_ROLLBACK_UNIT_EXISTED[$i]:-false}" != true ]]; then
                if [[ "${TPROXY_ROLLBACK_UNIT_ACTIVE[$i]:-}" == inactive ]] &&
                   systemctl is-active --quiet "$unit" 2>/dev/null &&
                   ! systemctl stop "$unit" >/dev/null 2>&1; then
                    rc=1
                fi
                if [[ "${TPROXY_ROLLBACK_UNIT_ENABLED[$i]:-}" == disabled ]] &&
                   systemctl is-enabled --quiet "$unit" 2>/dev/null &&
                   ! systemctl disable "$unit" >/dev/null 2>&1; then
                    rc=1
                fi
                continue
            fi
            if [[ "${TPROXY_ROLLBACK_UNIT_ACTIVE[$i]:-}" == active ]] &&
               ! systemctl start "$unit" >/dev/null 2>&1; then rc=1; fi
            if [[ "${TPROXY_ROLLBACK_UNIT_ACTIVE[$i]:-}" == inactive ]] &&
               ! systemctl stop "$unit" >/dev/null 2>&1; then rc=1; fi
            if [[ "${TPROXY_ROLLBACK_UNIT_ENABLED[$i]:-}" == enabled ]] &&
               ! systemctl enable "$unit" >/dev/null 2>&1; then rc=1; fi
            if [[ "${TPROXY_ROLLBACK_UNIT_ENABLED[$i]:-}" == disabled ]] &&
               ! systemctl disable "$unit" >/dev/null 2>&1; then rc=1; fi
        done
        if command -v nginx >/dev/null 2>&1; then
            if nginx -t >/dev/null 2>&1; then
                systemctl reload nginx >/dev/null 2>&1 || rc=1
            else
                rc=1
            fi
        fi
    fi
    if command -v nft >/dev/null 2>&1; then
        if [[ "$TPROXY_ROLLBACK_NFT_EXISTED" == true ]]; then
            nft -f "$TPROXY_ROLLBACK_NFT_FILE" >/dev/null 2>&1 || rc=1
        elif nft list table inet "$TPROXY_NFT_TABLE" >/dev/null 2>&1; then
            nft delete table inet "$TPROXY_NFT_TABLE" >/dev/null 2>&1 || rc=1
        fi
    fi
    if command -v ufw >/dev/null 2>&1; then
        if [[ -n "$TPROXY_ROLLBACK_UFW_80" ]] &&
           ! _telegram_proxy_ufw_apply_port 80 "$TPROXY_ROLLBACK_UFW_80" >/dev/null 2>&1; then
            rc=1
        fi
        if [[ -n "$TPROXY_ROLLBACK_UFW_2398" ]] &&
           ! _telegram_proxy_ufw_apply_port 2398 "$TPROXY_ROLLBACK_UFW_2398" >/dev/null 2>&1; then
            rc=1
        fi
    fi
    return "$rc"
}


_telegram_proxy_snapshot_paths() {
    local path index backup
    TPROXY_ROLLBACK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/telegram-proxy-rollback.XXXXXX") || return 1
    chmod 0700 "$TPROXY_ROLLBACK_DIR" || {
        rm -rf "$TPROXY_ROLLBACK_DIR"
        return 1
    }
    TPROXY_ROLLBACK_TARGETS=()
    TPROXY_ROLLBACK_BACKUPS=()
    index=0
    for path in "$@"; do
        backup="$TPROXY_ROLLBACK_DIR/$index"
        TPROXY_ROLLBACK_TARGETS+=("$path")
        TPROXY_ROLLBACK_BACKUPS+=("$backup")
        if [[ -e "$path" || -L "$path" ]]; then
            cp -a "$path" "$backup" || {
                rm -rf "$TPROXY_ROLLBACK_DIR"
                TPROXY_ROLLBACK_DIR=""
                return 1
            }
        else
            : > "$backup.absent" || {
                rm -rf "$TPROXY_ROLLBACK_DIR"
                TPROXY_ROLLBACK_DIR=""
                return 1
            }
        fi
        index=$((index + 1))
    done
    _telegram_proxy_snapshot_runtime
    return 0
}

_telegram_proxy_restore_snapshot() {
    local index path backup rc=0
    [[ -n "${TPROXY_ROLLBACK_DIR:-}" && -d "$TPROXY_ROLLBACK_DIR" ]] || return 0
    for index in "${!TPROXY_ROLLBACK_TARGETS[@]}"; do
        path="${TPROXY_ROLLBACK_TARGETS[$index]}"
        backup="${TPROXY_ROLLBACK_BACKUPS[$index]}"
        rm -rf "$path" || rc=1
        if [[ ! -e "$backup.absent" ]]; then
            mkdir -p "$(dirname "$path")" || rc=1
            cp -a "$backup" "$path" || rc=1
        fi
    done
    _telegram_proxy_restore_runtime || rc=1
    rm -rf "$TPROXY_ROLLBACK_DIR" || rc=1
    TPROXY_ROLLBACK_DIR=""
    TPROXY_ROLLBACK_TARGETS=()
    TPROXY_ROLLBACK_BACKUPS=()
    TPROXY_ROLLBACK_UNIT_EXISTED=()
    TPROXY_ROLLBACK_UNIT_NAMES=()
    TPROXY_ROLLBACK_UNIT_ACTIVE=()
    TPROXY_ROLLBACK_UNIT_ENABLED=()
    return "$rc"
}


_telegram_proxy_discard_snapshot() {
    local rc=0
    [[ -n "${TPROXY_ROLLBACK_DIR:-}" ]] && rm -rf "$TPROXY_ROLLBACK_DIR" || rc=1
    TPROXY_ROLLBACK_DIR=""
    TPROXY_ROLLBACK_TARGETS=()
    TPROXY_ROLLBACK_BACKUPS=()
    TPROXY_ROLLBACK_UNIT_EXISTED=()
    TPROXY_ROLLBACK_UNIT_NAMES=()
    TPROXY_ROLLBACK_UNIT_ACTIVE=()
    TPROXY_ROLLBACK_UNIT_ENABLED=()
    return "$rc"
}

_telegram_proxy_restore_install_failure() {
    local before_80="${1:-}" before_2398="${2:-}"
    local mt_user_before="${3:-true}" tproxy_user_before="${4:-true}"
    local temp_path="${5:-}" rc=0 backup
    if [[ -n "${TPROXY_ROLLBACK_DIR:-}" && -d "$TPROXY_ROLLBACK_DIR" ]]; then
        _telegram_proxy_restore_snapshot || rc=1
        if [[ "$mt_user_before" == false ]] && id mtproxy >/dev/null 2>&1; then
            userdel mtproxy >/dev/null 2>&1 || rc=1
        fi
        if [[ "$tproxy_user_before" == false ]] && id tproxy >/dev/null 2>&1; then
            userdel tproxy >/dev/null 2>&1 || rc=1
        fi
    else
        if command -v ufw >/dev/null 2>&1; then
            if [[ -n "$before_80" ]] &&
               ! _telegram_proxy_ufw_apply_port 80 "$before_80" >/dev/null 2>&1; then
                rc=1
            fi
            if [[ -n "$before_2398" ]] &&
               ! _telegram_proxy_ufw_apply_port 2398 "$before_2398" >/dev/null 2>&1; then
                rc=1
            fi
        fi
        if [[ "$mt_user_before" == false ]] && id mtproxy >/dev/null 2>&1; then
            userdel mtproxy >/dev/null 2>&1 || rc=1
        fi
        if [[ "$tproxy_user_before" == false ]] && id tproxy >/dev/null 2>&1; then
            userdel tproxy >/dev/null 2>&1 || rc=1
        fi
        if command -v systemctl >/dev/null 2>&1 &&
           ! systemctl daemon-reload >/dev/null 2>&1; then
            rc=1
        fi
    fi
    for backup in "${TPROXY_MTPROXY_SOURCE_DIR}".before-tproxy.*; do
        [[ -e "$backup" ]] && rm -rf "$backup" || true
    done
    [[ -n "$temp_path" ]] && rm -rf "$temp_path"
    if (( rc != 0 )); then
        warn "Откат Telegram Proxy завершился с ошибками; проверьте services, firewall и nginx."
    fi
    return "$rc"
}


_telegram_proxy_backend_active() { systemctl is-active --quiet "$TPROXY_UNIT_MTPROXY" 2>/dev/null; }
_telegram_proxy_service_state() { systemctl is-active --quiet "$1" 2>/dev/null && printf active || printf inactive; }

# ─── Public probes and UFW ───────────────────────────────────────────────────

_telegram_proxy_public_ipv4() {
    curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null ||
        curl -4 -fsS --max-time 5 https://icanhazip.com 2>/dev/null ||
        curl -4 -fsS --max-time 5 https://api4.ipify.org 2>/dev/null
}
_telegram_proxy_public_ipv6() { curl -6 -fsS --max-time 5 https://ifconfig.co 2>/dev/null || curl -6 -fsS --max-time 5 https://api6.ipify.org 2>/dev/null; }
_telegram_proxy_dns_ipv4() { getent ahostsv4 "$1" 2>/dev/null | awk 'NR == 1 { print $1; exit }'; }
_telegram_proxy_dns_ipv6() { getent ahostsv6 "$1" 2>/dev/null | awk 'NR == 1 { print $1; exit }'; }
_telegram_proxy_ipv6_enabled() { [[ ! -f "$TPROXY_IPV6_DISABLE_FILE" || "$(cat "$TPROXY_IPV6_DISABLE_FILE" 2>/dev/null)" != 1 ]]; }

_telegram_proxy_ufw_port_state() {
    local port="$1" status line
    command -v ufw >/dev/null 2>&1 || { printf absent; return 0; }
    status=$(ufw status 2>/dev/null || true)
    line=$(printf '%s\n' "$status" | awk -v p="$port/tcp" '$1 == p { print; exit }')
    if [[ "$line" =~ ALLOW ]]; then printf allow; elif [[ "$line" =~ DENY|REJECT ]]; then printf deny; else printf absent; fi
}

_telegram_proxy_ufw_apply_port() {
    local port="$1" state="$2"
    case "$state" in
        allow) ufw allow "$port/tcp" >/dev/null 2>&1 || return 1 ;;
        deny) ufw deny "$port/tcp" >/dev/null 2>&1 || return 1 ;;
        absent) ufw delete allow "$port/tcp" >/dev/null 2>&1 || true; ufw delete deny "$port/tcp" >/dev/null 2>&1 || true ;;
        *) return 1 ;;
    esac
}

_telegram_proxy_check_ports() {
    local p
    for p in "$@"; do is_port_free "$p" || { warn "Порт ${p} уже занят."; return 1; }; done
}

_telegram_proxy_render_nginx_site() {
    local hostname="$1" topology="$2" ipv6="${3:-false}" listen h2="ssl http2;"
    if type _nginx_h2_directives >/dev/null 2>&1; then _nginx_h2_directives >/dev/null 2>&1 || true; h2="${LISTEN_H2_FLAG:-ssl http2;}"; fi
    case "$topology" in direct) listen="    listen 443 $h2" ;; self-steal) listen="    listen 127.0.0.1:8443 $h2" ;; sni) listen="    listen 127.0.0.1:8446 $h2" ;; *) return 1 ;; esac
    mkdir -p "$(dirname "$TPROXY_NGINX_SITE")" || return 1
    cat > "$TPROXY_NGINX_SITE.tmp.$$" <<EOF
server {
${listen}
EOF
    if [[ "$topology" == direct || ( "$topology" == self-steal && "$ipv6" == true ) ]]; then printf '    listen [::]:443 ipv6only=on %s\n' "$h2" >> "$TPROXY_NGINX_SITE.tmp.$$"; fi
    cat >> "$TPROXY_NGINX_SITE.tmp.$$" <<EOF
    server_name ${hostname};
    ssl_certificate ${TPROXY_CERT_DIR}/${hostname}/fullchain.pem;
    ssl_certificate_key ${TPROXY_CERT_DIR}/${hostname}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    access_log off;
    add_header Strict-Transport-Security "max-age=31536000" always;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_connect_timeout 30s;
        proxy_send_timeout 120s;
        proxy_read_timeout 120s;
    }
}
EOF
    chmod 0644 "$TPROXY_NGINX_SITE.tmp.$$" && mv -f "$TPROXY_NGINX_SITE.tmp.$$" "$TPROXY_NGINX_SITE"; local rc=$?; rm -f "$TPROXY_NGINX_SITE.tmp.$$"; return "$rc"
}

_telegram_proxy_patch_sni_nginx() {
    local hostname="$1" source="$TPROXY_NGINX_CONF" tmp
    [[ -f "$source" ]] || return 1; tmp="$source.telegram-proxy.$$"
    awk -v host="$hostname" '
      BEGIN { map=0; upstream=0; skip=0 }
      /# --- telegram-proxy-map ---/ { skip=1; next }
      /# --- \/telegram-proxy-map ---/ { skip=0; next }
      /# --- telegram-proxy-upstream ---/ { skip=2; next }
      /# --- \/telegram-proxy-upstream ---/ { skip=0; next }
      skip { next }
      !map && $0 ~ /^[[:space:]]*default[[:space:]].*mihomo;/ { print "        # --- telegram-proxy-map ---"; print "        " host " telegram_proxy;"; print "        # --- /telegram-proxy-map ---"; map=1 }
      !upstream && $0 ~ /^[[:space:]]*upstream[[:space:]]+mihomo[[:space:]]*{/ { print "    # --- telegram-proxy-upstream ---"; print "    upstream telegram_proxy {"; print "        server 127.0.0.1:8446;"; print "    }"; print "    # --- /telegram-proxy-upstream ---"; upstream=1 }
      { print }
      END { if (!map || !upstream) exit 2 }
    ' "$source" > "$tmp" || { rm -f "$tmp"; return 1; }
    cmp -s "$tmp" "$source" || mv -f "$tmp" "$source"; rm -f "$tmp"
}

_telegram_proxy_remove_sni_markers() {
    local source="$TPROXY_NGINX_CONF" tmp
    [[ -f "$source" ]] || return 0; tmp="$source.telegram-proxy-remove.$$"
    awk '/# --- telegram-proxy-map ---/ { skip=1; next } /# --- \/telegram-proxy-map ---/ { skip=0; next } /# --- telegram-proxy-upstream ---/ { skip=1; next } /# --- \/telegram-proxy-upstream ---/ { skip=0; next } !skip { print }' "$source" > "$tmp" && mv -f "$tmp" "$source"; local rc=$?; rm -f "$tmp"; return "$rc"
}

# ─── Install preflight and WEB plumbing ──────────────────────────────────────

_telegram_proxy_ensure_dependencies() {
    declare -F ensure_dep >/dev/null 2>&1 || return 0
    # All dependencies are prepared before the first host mutation.
    ensure_dep git curl openssl wget unzip nginx nft ufw systemctl useradd id runuser make gcc tar
}

_telegram_proxy_preflight() {
    [[ "$(id -u 2>/dev/null)" == 0 ]] || { warn "Установка требует root."; return 1; }
    case "$(uname -m)" in x86_64|amd64) ;; *) warn "Официальный MTProxy build поддерживает только x86_64."; return 1 ;; esac
    local id_value=""
    [[ -r /etc/os-release ]] && id_value=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | awk 'NR == 1 { print; exit }')
    case "$id_value" in debian|ubuntu) ;; *) warn "Поддерживаются только Debian и Ubuntu."; return 1 ;; esac
    command -v apt-get >/dev/null 2>&1 || { warn "Не найден apt-get."; return 1; }
    _telegram_proxy_ensure_dependencies || return 1
}

_telegram_proxy_detect_topology() {
    local mode
    if type _detect_reality_mode >/dev/null 2>&1; then mode=$(_detect_reality_mode 2>/dev/null || true); else mode=direct; fi
    case "$mode" in direct|self-steal|sni) printf '%s\n' "$mode" ;; *) printf direct; return 0 ;; esac
}

_telegram_proxy_wait_dns() {
    local hostname="$1" public4="$2" public6="${3:-}" answer dns4 dns6
    while true; do
        dns4=$(_telegram_proxy_dns_ipv4 "$hostname")
        [[ "$dns4" == "$public4" ]] && break
        warn "A-запись ${hostname}: ${dns4:-не найдена}; IPv4 ноды: ${public4}."
        read -rp "Enter = перепроверить, 0 = отмена: " answer; [[ "$answer" == 0 ]] && return 1
    done
    dns6=$(_telegram_proxy_dns_ipv6 "$hostname")
    if [[ -n "$dns6" ]]; then
        [[ -n "$public6" && "$dns6" == "$public6" ]] && _telegram_proxy_ipv6_enabled || { warn "AAAA-запись не совпадает с IPv6 ноды."; return 1; }
        TELEGRAM_WEB_IPV6=true
    else TELEGRAM_WEB_IPV6=false; fi
}

_telegram_proxy_issue_certificate() {
    local hostname="$1" tmp_site="$2" webroot="$TPROXY_WEBROOT_BASE/$1" before="absent"
    mkdir -p "$webroot" "$(dirname "$tmp_site")" || return 1
    printf 'telegram-proxy-acme\n' > "$webroot/index.html" || return 1
    before=$(_telegram_proxy_ufw_port_state 80)
    cat > "$tmp_site" <<EOF
server {
    listen 80;
    server_name ${hostname};
    location /.well-known/acme-challenge/ { root ${webroot}; }
}
EOF
    ln -sf "$tmp_site" "$TPROXY_NGINX_ACME_SITE" || {
        rm -f "$tmp_site"
        return 1
    }
    if ! _telegram_proxy_ufw_apply_port 80 allow; then
        rm -f "$TPROXY_NGINX_ACME_SITE" "$tmp_site"
        _telegram_proxy_ufw_apply_port 80 "$before" >/dev/null 2>&1 || true
        return 1
    fi
    (
        nginx -t &&
        systemctl reload nginx &&
        ensure_acme_installed "$TELEGRAM_WEB_EMAIL" &&
        issue_cert "$hostname" "$webroot" false &&
        install_cert "$hostname" "systemctl reload nginx"
    ) || {
        rm -f "$TPROXY_NGINX_ACME_SITE" "$tmp_site"
        _telegram_proxy_ufw_apply_port 80 "$before" >/dev/null 2>&1 || true
        return 1
    }
    rm -f "$TPROXY_NGINX_ACME_SITE" "$tmp_site"
    _telegram_proxy_ufw_apply_port 80 "$before" || return 1
}
_telegram_proxy_install_pinned_go() {
    local version="${TPROXY_GO_VERSION:-1.26.5}"
    local checksum="${TPROXY_GO_CHECKSUM:-5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053}"
    local archive directory
    archive=$(umask 077; mktemp "${TMPDIR:-/tmp}/go-linux-amd64.XXXXXX.tar.gz") || return 1
    directory=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/go-linux-amd64.XXXXXX") || {
        rm -f "$archive"
        return 1
    }
    if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --output "$archive" "https://go.dev/dl/go${version}.linux-amd64.tar.gz" ||
       [[ "$(sha256sum "$archive" | awk '{print $1}')" != "$checksum" ]] ||
       ! tar -C "$directory" -xzf "$archive"; then
        rm -f "$archive"
        rm -rf "$directory"
        return 1
    fi
    if [[ -e "/opt/go${version}" ]]; then
        rm -rf "$directory/go"
    else
        mv "$directory/go" "/opt/go${version}" || {
            rm -f "$archive"; rm -rf "$directory"; return 1;
        }
    fi
    rm -f "$archive"
    rm -rf "$directory"
    [[ -x "/opt/go${version}/bin/go" ]] || return 1
    printf '%s\n' "/opt/go${version}/bin/go"
}

_telegram_proxy_wait_endpoint() {
    local url="$1" attempts="${2:-$TPROXY_READY_ATTEMPTS}" n=0
    while (( n < attempts )); do curl --fail --silent --output /dev/null --max-time 2 "$url" 2>/dev/null && return 0; n=$((n + 1)); sleep 1; done
    return 1
}

_telegram_proxy_clone_relay() {
    local stage="$1"
    _telegram_proxy_clone_upstream "$stage" "$TPROXY_UPSTREAM_REVISION"
}

_telegram_proxy_find_go() {
    local candidate version minor
    for candidate in "$(command -v go 2>/dev/null || true)" /opt/go*/bin/go; do
        [[ -x "$candidate" ]] || continue; version=$($candidate env GOVERSION 2>/dev/null); minor=$(printf '%s\n' "$version" | sed -n 's/^go1\.\([0-9][0-9]*\).*/\1/p'); [[ -n "$minor" && "$minor" -ge 20 ]] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

_telegram_proxy_install_web_service() {
    local source="$TPROXY_RELAY_SOURCE_PATH/deploy/tproxy-server.service"
    local target="$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_RELAY" tmp
    [[ -f "$source" ]] || return 1
    mkdir -p "$TPROXY_SYSTEMD_DIR" || return 1
    tmp="$target.tmp.$$"
    awk -v profile="$TPROXY_PROFILES_FILE" '
        /^LoadCredential=/ { next }
        /^\[Service\]$/ {
            print
            print "LoadCredential=profiles.json:" profile
            inserted = 1
            next
        }
        { print }
        END { if (!inserted) exit 2 }
    ' "$source" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" && mv -f "$tmp" "$target" || {
        rm -f "$tmp"
        return 1
    }
    chown root:root "$target" || return 1
    chmod 0644 "$target" || return 1
    grep -q '^LoadCredential=profiles.json:' "$target"
}

# ─── Component installation ─────────────────────────────────────────────────

telegram_proxy_mtproto_install() {
    local force=false arg public4 secret before_ufw backend_was=false source_tmp mt_user_before=false
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            *) return 2 ;;
        esac
    done
    if [[ -f "$TPROXY_CONF" ]]; then
        _telegram_proxy_load_conf || return 1
        _telegram_proxy_runtime_consistent || return 1
        [[ "$TELEGRAM_MTPROTO_ENABLED" == true ]] && {
            if _telegram_proxy_backend_active &&
               systemctl is-enabled --quiet "$TPROXY_UNIT_MTPROXY" 2>/dev/null &&
               (exec 3<>/dev/tcp/127.0.0.1/2398) 2>/dev/null; then
                exec 3>&- 3<&-
                info "MTProto уже установлен и работает."
                return 0
            fi
            warn "MTProto отмечен установленным, но runtime не здоров; выполняется reconcile."
        }
        backend_was=true
        secret="$TPROXY_RUNTIME_SECRET"
    else
        _telegram_proxy_reject_unmanaged_state || return 1
        secret=""
    fi
    _telegram_proxy_preflight || return 1
    public4=$(_telegram_proxy_public_ipv4 | tr -d '[:space:]')
    _telegram_proxy_valid_public_ipv4 "$public4" || { warn "Не удалось определить публичный IPv4."; return 1; }
    if [[ "$backend_was" != true ]]; then
        _telegram_proxy_check_ports 2398 8888 || return 1
        secret=$(_telegram_proxy_generate_secret) || return 1
        id mtproxy >/dev/null 2>&1 && mt_user_before=true
    elif ! _telegram_proxy_backend_active; then
        _telegram_proxy_check_ports 2398 8888 || return 1
    fi
    before_ufw=$(_telegram_proxy_ufw_port_state 2398)
    echo ""
    info "MTProto: ${public4}:2398"
    warn "Provider firewall: разрешите TCP/2398 и запретите TCP/8888."
    [[ "$force" == true ]] || confirm_yn "Provider firewall настроен, продолжить?" || return 0
    [[ "$force" == true ]] || confirm_yn "Установить MTProto?" || return 0
    _telegram_proxy_snapshot_paths \
        "$TPROXY_CONF" "$TPROXY_ENV_FILE" "$TPROXY_MTPROXY_DIR" \
        "$TPROXY_MTPROXY_SOURCE_DIR" "$TPROXY_FIREWALL_FILE" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_FIREWALL" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_REFRESH" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_TIMER" "$TPROXY_REFRESH_BIN" || return 1
    if [[ "$backend_was" != true ]]; then
        source_tmp=$(mktemp -d "${TMPDIR:-/tmp}/tproxy-source.XXXXXX") || {
            _telegram_proxy_restore_snapshot
            return 1
        }
        chmod 0700 "$source_tmp" || {
            rm -rf "$source_tmp"
            _telegram_proxy_restore_snapshot
            return 1
        }
        if ! _telegram_proxy_clone_relay "$source_tmp"; then
            rm -rf "$source_tmp"
            _telegram_proxy_restore_snapshot
            return 1
        fi
        _telegram_proxy_render_mtproxy_env "$secret" || {
            rm -rf "$source_tmp"
            _telegram_proxy_restore_snapshot
            return 1
        }
        _telegram_proxy_install_backend "$source_tmp" || {
            rm -rf "$source_tmp"
            _telegram_proxy_restore_install_failure "" "$before_ufw" "$mt_user_before" true
            return 1
        }
        rm -rf "$source_tmp"
        if ! systemctl daemon-reload; then
            _telegram_proxy_restore_install_failure "" "$before_ufw" "$mt_user_before" true
            return 1
        fi
        if ! systemctl enable --now "$TPROXY_UNIT_FIREWALL" "$TPROXY_UNIT_MTPROXY"; then
            _telegram_proxy_restore_install_failure "" "$before_ufw" "$mt_user_before" true
            return 1
        fi
        if ! systemctl enable --now "$TPROXY_UNIT_TIMER" >/dev/null 2>&1; then
            _telegram_proxy_restore_install_failure "" "$before_ufw" "$mt_user_before" true
            return 1
        fi
        if [[ "$mt_user_before" == false ]] && id mtproxy >/dev/null 2>&1; then
            MTPROXY_CREATED_USER=true
        fi
    else
        _telegram_proxy_render_firewall true || {
            _telegram_proxy_restore_install_failure "" "$before_ufw" "$mt_user_before" true
            return 1
        }
        if ! systemctl reload "$TPROXY_UNIT_FIREWALL" >/dev/null 2>&1 &&
           ! systemctl restart "$TPROXY_UNIT_FIREWALL" >/dev/null 2>&1; then
            _telegram_proxy_restore_install_failure "" "$before_ufw" "$mt_user_before" true
            return 1
        fi
        if ! _telegram_proxy_backend_active &&
           ! systemctl enable --now "$TPROXY_UNIT_MTPROXY"; then
            _telegram_proxy_restore_install_failure "" "$before_ufw" "$mt_user_before" true
            return 1
        fi
        if ! systemctl enable --now "$TPROXY_UNIT_TIMER" >/dev/null 2>&1; then
            _telegram_proxy_restore_install_failure "" "$before_ufw" "$mt_user_before" true
            return 1
        fi
    fi
    if ! _telegram_proxy_ufw_apply_port 2398 allow; then
        _telegram_proxy_restore_install_failure "" "$before_ufw" "$mt_user_before" true
        return 1
    fi
    TELEGRAM_MTPROTO_ENABLED=true
    TELEGRAM_MTPROTO_IPV4="$public4"
    TELEGRAM_MTPROTO_PORT=2398
    TELEGRAM_UFW_MTPROTO_PREVIOUS="$before_ufw"
    if ! _telegram_proxy_state_write; then
        _telegram_proxy_restore_install_failure "" "$before_ufw" "$mt_user_before" true
        return 1
    fi
    _telegram_proxy_discard_snapshot
    success "MTProto установлен. Откройте Connection в меню Telegram Proxy для ссылки."
    return 0
}

telegram_proxy_web_install() {
    local force=false arg hostname email public4 public6 topology secret backend_was=false
    local relay_tmp source_tmp go_binary candidate mt_user_before=false tproxy_user_before=false before_80
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            *) return 2 ;;
        esac
    done
    if [[ -f "$TPROXY_CONF" ]]; then
        _telegram_proxy_load_conf || return 1
        _telegram_proxy_runtime_consistent || return 1
        [[ "$TELEGRAM_WEB_ENABLED" == true ]] && {
            if _telegram_proxy_web_runtime_healthy; then
                info "WEB уже установлен и работает."
                return 0
            fi
            warn "WEB отмечен установленным, но runtime не здоров; выполняется reconcile."
        }
        backend_was=true
        secret="$TPROXY_RUNTIME_SECRET"
    else
        _telegram_proxy_reject_unmanaged_state || return 1
        secret=""
    fi

    read -rp "Введите hostname для Telegram WEB: " hostname
    hostname=$(printf '%s' "$hostname" | tr -d '\r')
    _telegram_proxy_valid_hostname "$hostname" || { warn "Некорректный hostname."; return 1; }
    read -rp "Введите обязательный ACME email: " email
    email=$(printf '%s' "$email" | tr -d '\r')
    _telegram_proxy_valid_email "$email" || { warn "Некорректный ACME email."; return 1; }
    TELEGRAM_WEB_EMAIL="$email"
    _telegram_proxy_preflight || return 1
    public4=$(_telegram_proxy_public_ipv4 | tr -d '[:space:]')
    _telegram_proxy_valid_public_ipv4 "$public4" || { warn "Не удалось определить публичный IPv4."; return 1; }
    public6=$(_telegram_proxy_public_ipv6 | tr -d '[:space:]' || true)
    _telegram_proxy_wait_dns "$hostname" "$public4" "$public6" || return 1
    topology=$(_telegram_proxy_detect_topology)
    if [[ "$backend_was" != true ]]; then
        _telegram_proxy_check_ports 2398 8888 8080 8081 || return 1
        secret=$(_telegram_proxy_generate_secret) || return 1
        id mtproxy >/dev/null 2>&1 && mt_user_before=true
    else
        _telegram_proxy_check_ports 8080 8081 || return 1
    fi
    echo ""
    info "WEB: ${hostname}; topology=${topology}; IPv6=${TELEGRAM_WEB_IPV6}"
    warn "Provider firewall: разрешите TCP/80 и TCP/443; запретите TCP/8080 и TCP/8081."
    [[ "$backend_was" == true ]] || warn "WEB-only режим блокирует TCP/2398 до добавления MTProto."
    [[ "$force" == true ]] || confirm_yn "Provider firewall настроен, продолжить?" || return 0
    [[ "$force" == true ]] || confirm_yn "Установить Telegram WEB?" || return 0
    before_80=$(_telegram_proxy_ufw_port_state 80)
    id tproxy >/dev/null 2>&1 && tproxy_user_before=true
    _telegram_proxy_snapshot_paths \
        "$TPROXY_CONF" "$TPROXY_TOKEN_KEY" "$TPROXY_ENV_FILE" "$TPROXY_PROFILES_FILE" \
        "$TPROXY_CONFIG_JSON" "$TPROXY_MTPROXY_DIR" "$TPROXY_MTPROXY_SOURCE_DIR" \
        "$TPROXY_RELAY_SOURCE_PATH" "$TPROXY_SITE_DIR" "$TPROXY_BIN" \
        "$TPROXY_NGINX_SITE" "$TPROXY_NGINX_ENABLED" "$TPROXY_NGINX_ACME_SITE" \
        "$TPROXY_NGINX_CONF" "$TPROXY_CERT_DIR/$hostname" "$TPROXY_WEBROOT_BASE/$hostname" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_RELAY" "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_FIREWALL" "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_REFRESH" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_TIMER" "$TPROXY_FIREWALL_FILE" \
        "$TPROXY_REFRESH_BIN" || return 1

    if [[ "$backend_was" != true ]]; then
        source_tmp=$(mktemp -d "${TMPDIR:-/tmp}/tproxy-source.XXXXXX") || {
            _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
        }
        chmod 0700 "$source_tmp" || {
            rm -rf "$source_tmp"; _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
        }
        if ! _telegram_proxy_clone_relay "$source_tmp"; then
            rm -rf "$source_tmp"; _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1
        fi
        _telegram_proxy_render_mtproxy_env "$secret" || {
            rm -rf "$source_tmp"; _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
        }
        _telegram_proxy_install_backend "$source_tmp" || {
            rm -rf "$source_tmp"; _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
        }
        rm -rf "$source_tmp"
        systemctl daemon-reload || {
            _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
        }
        systemctl enable --now "$TPROXY_UNIT_FIREWALL" "$TPROXY_UNIT_MTPROXY" || {
            _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
        }
        if [[ "$mt_user_before" == false ]] && id mtproxy >/dev/null 2>&1; then MTPROXY_CREATED_USER=true; fi
    fi

    relay_tmp=$(mktemp -d "${TMPDIR:-/tmp}/tproxy-relay.XXXXXX") || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    chmod 0700 "$relay_tmp" || { rm -rf "$relay_tmp"; _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1; }
    if ! _telegram_proxy_clone_relay "$relay_tmp"; then
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before" "$relay_tmp"; return 1
    fi
    rm -rf "$TPROXY_RELAY_SOURCE_PATH"
    mkdir -p "$(dirname "$TPROXY_RELAY_SOURCE_PATH")" || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before" "$relay_tmp"; return 1;
    }
    mv "$relay_tmp" "$TPROXY_RELAY_SOURCE_PATH" || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    chmod 0700 "$TPROXY_RELAY_SOURCE_PATH" || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    if ! id tproxy >/dev/null 2>&1; then
        useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy || {
            _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
        }
        TPROXY_CREATED_USER=true
    else
        tproxy_user_before=true
        TPROXY_CREATED_USER=false
    fi
    install -d -o root -g tproxy -m 0750 "$TPROXY_DIR" || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    mkdir -p "$TPROXY_SITE_DIR" || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    if ! ( _randomhtml "" "$TPROXY_SITE_DIR" ); then
        warn "Не удалось подготовить сайт-заглушку Telegram WEB."
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1
    fi
    [[ -f "$TPROXY_SITE_DIR/index.html" && -r "$TPROXY_SITE_DIR/index.html" ]] || {
        warn "Выбор шаблона отменён или index.html недоступен."
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    chmod -R u=rwX,go=rX "$TPROXY_SITE_DIR" || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    chown -R root:root "$TPROXY_SITE_DIR" || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    _telegram_proxy_ensure_token_key || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    _telegram_proxy_render_relay_config "$hostname" || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    _telegram_proxy_render_profiles "$secret" || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    go_binary=$(_telegram_proxy_find_go 2>/dev/null || true)
    [[ -n "$go_binary" ]] || go_binary=$(_telegram_proxy_install_pinned_go 2>/dev/null || true)
    [[ -n "$go_binary" ]] || {
        warn "Не удалось подготовить Go 1.20+."
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    candidate="$(mktemp "${TMPDIR:-/tmp}/tproxy-server.XXXXXX")"
    rm -f "$candidate"
    if ! (cd "$TPROXY_RELAY_SOURCE_PATH" &&
          runuser -u tproxy -- "$go_binary" build -trimpath -ldflags='-s -w' -o "$candidate" ./cmd/tproxy-server); then
        rm -f "$candidate"
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1
    fi
    chmod 0755 "$candidate" || { rm -f "$candidate"; _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1; }
    if ! "$candidate" -config "$TPROXY_CONFIG_JSON" -profiles-file "$TPROXY_PROFILES_FILE" -check; then
        rm -f "$candidate"
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1
    fi
    install -o root -g root -m 0755 "$candidate" "$TPROXY_BIN" || {
        rm -f "$candidate"; _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    rm -f "$candidate"
    _telegram_proxy_install_web_service || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    systemctl daemon-reload || { _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1; }
    systemctl enable --now "$TPROXY_UNIT_RELAY" || { _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1; }

    TELEGRAM_PROXY_STATE_VERSION=1
    TELEGRAM_WEB_ENABLED=true
    TELEGRAM_WEB_HOSTNAME="$hostname"
    TELEGRAM_WEB_EMAIL="$email"
    TELEGRAM_WEB_TOPOLOGY="$topology"
    case "$topology" in
        direct) TELEGRAM_WEB_TLS_LISTEN=0.0.0.0:443 ;;
        self-steal) TELEGRAM_WEB_TLS_LISTEN=127.0.0.1:8443 ;;
        sni) TELEGRAM_WEB_TLS_LISTEN=127.0.0.1:8446 ;;
    esac
    TELEGRAM_MTPROTO_PORT=2398
    TELEGRAM_RELAY_SOURCE_PATH="$TPROXY_RELAY_SOURCE_PATH"
    TELEGRAM_RELAY_UPSTREAM_SHA=$(git -C "$TPROXY_RELAY_SOURCE_PATH" rev-parse HEAD 2>/dev/null) || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    [[ "$TELEGRAM_RELAY_UPSTREAM_SHA" == "$TPROXY_UPSTREAM_CHECKSUM" ]] || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    _telegram_proxy_issue_certificate "$hostname" "$TPROXY_NGINX_SITE.acme" || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    _telegram_proxy_render_nginx_site "$hostname" "$topology" "$TELEGRAM_WEB_IPV6" || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    if [[ "$topology" == sni ]] && ! _telegram_proxy_patch_sni_nginx "$hostname"; then
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1
    fi
    ln -sf "$TPROXY_NGINX_SITE" "$TPROXY_NGINX_ENABLED" || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    nginx -t || { _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1; }
    systemctl reload nginx || { _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1; }
    _telegram_proxy_render_firewall "$TELEGRAM_MTPROTO_ENABLED" || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    if ! systemctl reload "$TPROXY_UNIT_FIREWALL" >/dev/null 2>&1 &&
       ! systemctl restart "$TPROXY_UNIT_FIREWALL" >/dev/null 2>&1; then
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1
    fi
    _telegram_proxy_verify_components || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    _telegram_proxy_state_write || {
        _telegram_proxy_restore_install_failure "$before_80" "" "$mt_user_before" "$tproxy_user_before"; return 1;
    }
    _telegram_proxy_discard_snapshot
    success "Telegram WEB установлен. Откройте Connection в меню Telegram Proxy для ссылки."
    return 0
}

# ─── Lifecycle ──────────────────────────────────────────────────────────────

_telegram_proxy_json_escape() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
_telegram_proxy_probe() { curl --fail --silent --output /dev/null --max-time 4 "$1" 2>/dev/null; }
_telegram_proxy_cert_expiry() { [[ -r "$TPROXY_CERT_DIR/${TELEGRAM_WEB_HOSTNAME}/fullchain.pem" ]] && openssl x509 -enddate -noout -in "$TPROXY_CERT_DIR/${TELEGRAM_WEB_HOSTNAME}/fullchain.pem" 2>/dev/null | sed 's/^notAfter=//'; }
_telegram_proxy_latest_sha() { printf '%s\n' "$TPROXY_UPSTREAM_REVISION"; }

telegram_proxy_status() {
    local json=false arg backend firewall timer health readiness cert latest commit_state
    local ip_state=unknown listener=false ipv6=false observed_ip
    local seen_json=false
    for arg in "$@"; do
        case "$arg" in
            --json) [[ "$seen_json" == true ]] && return 2; seen_json=true; json=true ;;
            *) return 2 ;;
        esac
    done
    _telegram_proxy_is_installed || {
        [[ "$json" == true ]] && printf '%s\n' '{"installed":false,"web_enabled":false,"mtproto_enabled":false,"tag_configured":false}'
        return 3
    }
    backend=$(_telegram_proxy_service_state "$TPROXY_UNIT_MTPROXY")
    firewall=$(_telegram_proxy_service_state "$TPROXY_UNIT_FIREWALL")
    timer=$(_telegram_proxy_service_state "$TPROXY_UNIT_TIMER")
    latest=""
    commit_state=unknown
    health=unknown
    readiness=unknown
    cert=""
    if [[ "$TELEGRAM_WEB_ENABLED" == true ]]; then
        latest=$(_telegram_proxy_latest_sha 2>/dev/null || true)
        if [[ -n "$latest" ]]; then
            [[ "$latest" == "$TELEGRAM_RELAY_UPSTREAM_SHA" ]] &&
                commit_state=current || commit_state="update available"
        fi
        _telegram_proxy_probe "$TPROXY_HEALTH_URL" && health=ok || health=failed
        _telegram_proxy_probe "$TPROXY_READY_URL" && readiness=ok || readiness=failed
        cert=$(_telegram_proxy_cert_expiry || true)
        [[ "$TELEGRAM_WEB_IPV6" == true ]] && ipv6=true
    fi
    if [[ "$TELEGRAM_MTPROTO_ENABLED" == true ]]; then
        (exec 3<>/dev/tcp/127.0.0.1/2398) 2>/dev/null && {
            exec 3>&-
            exec 3<&-
            listener=true
        }
        observed_ip=$(_telegram_proxy_public_ipv4 2>/dev/null | tr -d '[:space:]' || true)
        if _telegram_proxy_valid_public_ipv4 "$observed_ip"; then
            [[ "$observed_ip" == "$TELEGRAM_MTPROTO_IPV4" ]] &&
                ip_state=current || ip_state=changed
        fi
    fi
    if [[ "$json" == true ]]; then
        printf '{"installed":true,"web_enabled":%s,"mtproto_enabled":%s,"tag_configured":%s,"backend":"%s","firewall":"%s","timer":"%s"' \
            "$TELEGRAM_WEB_ENABLED" "$TELEGRAM_MTPROTO_ENABLED" "$TELEGRAM_TAG_CONFIGURED" \
            "$backend" "$firewall" "$timer"
        if [[ "$TELEGRAM_WEB_ENABLED" == true ]]; then
            printf ',"web_hostname":"%s","hostname":"%s","web_topology":"%s","web_tls_listen":"%s","web_ipv6":%s,"relay":"%s","health":"%s","readiness":"%s","certificate_not_after":"%s","relay_sha":"%s","relay_latest_sha":"%s","relay_commit_state":"%s"' \
                "$(_telegram_proxy_json_escape "$TELEGRAM_WEB_HOSTNAME")" \
                "$(_telegram_proxy_json_escape "$TELEGRAM_WEB_HOSTNAME")" "$TELEGRAM_WEB_TOPOLOGY" \
                "$TELEGRAM_WEB_TLS_LISTEN" "$ipv6" "$(_telegram_proxy_service_state "$TPROXY_UNIT_RELAY")" \
                "$health" "$readiness" "$(_telegram_proxy_json_escape "$cert")" "$TELEGRAM_RELAY_UPSTREAM_SHA" \
                "$latest" "$commit_state"
        fi
        if [[ "$TELEGRAM_MTPROTO_ENABLED" == true ]]; then
            printf ',"mtproto_ipv4":"%s","mtproto_port":2398,"mtproto_listener":%s,"mtproto_ip_state":"%s"' \
                "$TELEGRAM_MTPROTO_IPV4" "$listener" "$ip_state"
        fi
        printf '}\n'
        return 0
    fi
    info "Telegram Proxy"
    if [[ "$TELEGRAM_WEB_ENABLED" == true ]]; then
        info "WEB: active (${TELEGRAM_WEB_HOSTNAME}); topology=${TELEGRAM_WEB_TOPOLOGY}; health=${health}; readiness=${readiness}"
    else
        info "WEB: inactive"
    fi
    if [[ "$TELEGRAM_MTPROTO_ENABLED" == true ]]; then
        info "MTProto: active (${TELEGRAM_MTPROTO_IPV4}:2398); listener=${listener}; ip=${ip_state}"
    else
        info "MTProto: inactive"
    fi
    info "Shared: backend=${backend}; firewall=${firewall}; timer=${timer}; tag_configured=${TELEGRAM_TAG_CONFIGURED}"
    info "Ссылки и secret доступны только в Connection."
}

telegram_proxy_connection() {
    [[ $# -eq 0 ]] || return 2
    _telegram_proxy_is_installed || {
        warn "Telegram Proxy не установлен."
        return 3
    }
    local secret="$TPROXY_RUNTIME_SECRET"
    echo "Telegram Proxy connection (credentials показываются только по явному запросу):"
    echo "Secret: ${secret}"
    if [[ "$TELEGRAM_WEB_ENABLED" == true ]]; then
        echo "WEB: https://t.me/webproxy?server=${TELEGRAM_WEB_HOSTNAME}&port=443&secret=${secret}"
        echo "WEB: tg://webproxy?server=${TELEGRAM_WEB_HOSTNAME}&port=443&secret=${secret}"
    fi
    if [[ "$TELEGRAM_MTPROTO_ENABLED" == true ]]; then
        echo "MTProto: https://t.me/proxy?server=${TELEGRAM_MTPROTO_IPV4}&port=2398&secret=${secret}"
        echo "MTProto: tg://proxy?server=${TELEGRAM_MTPROTO_IPV4}&port=2398&secret=${secret}"
    fi
}

telegram_proxy_tag_show() {
    [[ $# -eq 0 ]] || return 2
    _telegram_proxy_is_installed || return 3
    _telegram_proxy_read_env || return 1
    if [[ -n "$TPROXY_RUNTIME_TAG" ]]; then
        printf '%s\n' "$TPROXY_RUNTIME_TAG"
    else
        info "Tag не настроен."
    fi
}
_telegram_proxy_web_secret_accepted() {
    local secret="$1" runtime="$TPROXY_PROFILES_RUNTIME_FILE"
    [[ "$TELEGRAM_WEB_ENABLED" == true && -r "$runtime" ]] || return 1
    if command -v jq >/dev/null 2>&1; then
        [[ "$(jq -r --arg s "$secret" '.profiles[]? | select(.name == "default" and .secret == $s) | .secret' "$runtime" 2>/dev/null | awk 'NR == 1 { print; exit }')" == "$secret" ]] || return 1
    else
        grep -Eq '"secret"[[:space:]]*:[[:space:]]*"'"$secret"'"' "$runtime" || return 1
    fi
    _telegram_proxy_wait_endpoint "$TPROXY_READY_URL" 1 || return 1
}

_telegram_proxy_wait_mtproxy_listener() {
    local n=0
    while (( n < TPROXY_READY_ATTEMPTS )); do
        (exec 3<>/dev/tcp/127.0.0.1/2398) 2>/dev/null && {
            exec 3>&-
            exec 3<&-
            return 0
        }
        n=$((n + 1))
        sleep 1
    done
    return 1
}

_telegram_proxy_verify_components() {
    _telegram_proxy_wait_mtproxy_listener || return 1
    if [[ "$TELEGRAM_WEB_ENABLED" == true ]]; then
        _telegram_proxy_wait_endpoint "$TPROXY_READY_URL" || return 1
    fi
}

_telegram_proxy_web_runtime_healthy() {
    [[ "$TELEGRAM_WEB_ENABLED" == true ]] || return 1
    systemctl is-active --quiet "$TPROXY_UNIT_RELAY" 2>/dev/null || return 1
    systemctl is-enabled --quiet "$TPROXY_UNIT_RELAY" 2>/dev/null || return 1
    [[ -r "$TPROXY_CONFIG_JSON" && -r "$TPROXY_PROFILES_FILE" &&
       -x "$TPROXY_BIN" && -r "$TPROXY_SITE_DIR/index.html" ]] || return 1
    _telegram_proxy_wait_endpoint "$TPROXY_READY_URL" 1
}

telegram_proxy_tag_set() {
    local tag old_env old_tag
    [[ $# -eq 0 ]] || return 2
    _telegram_proxy_is_installed || return 3
    confirm_yn "Изменить общий tag (кратко затронет WEB и MTProto)?" || return 0
    read -rsp "Введите tag (ровно 32 hex): " tag
    echo ""
    _telegram_proxy_valid_tag "$tag" || {
        warn "Tag должен содержать ровно 32 hex."
        return 2
    }
    tag=$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')
    old_tag="${TPROXY_RUNTIME_TAG:-}"
    old_env="$TPROXY_ENV_FILE.telegram-proxy-old.$$"
    cp "$TPROXY_ENV_FILE" "$old_env" || return 1
    _telegram_proxy_render_mtproxy_env "$TPROXY_RUNTIME_SECRET" "-P $tag" || {
        rm -f "$old_env"
        return 1
    }
    if ! systemctl restart "$TPROXY_UNIT_MTPROXY" ||
       ! _telegram_proxy_verify_components; then
        cp "$old_env" "$TPROXY_ENV_FILE"
        systemctl restart "$TPROXY_UNIT_MTPROXY" >/dev/null 2>&1 || true
        rm -f "$old_env"
        return 1
    fi
    old_tag="${TELEGRAM_TAG_CONFIGURED:-false}"
    TELEGRAM_TAG_CONFIGURED=true
    if ! _telegram_proxy_state_write; then
        TELEGRAM_TAG_CONFIGURED="$old_tag"
        cp "$old_env" "$TPROXY_ENV_FILE"
        systemctl restart "$TPROXY_UNIT_MTPROXY" >/dev/null 2>&1 || true
        rm -f "$old_env"
        return 1
    fi
    rm -f "$old_env"
    success "Tag установлен. Откройте Tag show или Connection отдельно."
}

telegram_proxy_tag_clear() {
    local force=false arg old_env old_tag
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            *) return 2 ;;
        esac
    done
    _telegram_proxy_is_installed || return 3
    [[ "$force" == true ]] ||
        confirm_yn "Очистить общий tag (кратко затронет WEB и MTProto)?" || return 0
    old_env="$TPROXY_ENV_FILE.telegram-proxy-old.$$"
    cp "$TPROXY_ENV_FILE" "$old_env" || return 1
    _telegram_proxy_render_mtproxy_env "$TPROXY_RUNTIME_SECRET" "" || {
        rm -f "$old_env"
        return 1
    }
    if ! systemctl restart "$TPROXY_UNIT_MTPROXY" ||
       ! _telegram_proxy_verify_components; then
        cp "$old_env" "$TPROXY_ENV_FILE"
        systemctl restart "$TPROXY_UNIT_MTPROXY" >/dev/null 2>&1 || true
        rm -f "$old_env"
        return 1
    fi
    old_tag="${TELEGRAM_TAG_CONFIGURED:-false}"
    TELEGRAM_TAG_CONFIGURED=false
    if ! _telegram_proxy_state_write; then
        TELEGRAM_TAG_CONFIGURED="$old_tag"
        cp "$old_env" "$TPROXY_ENV_FILE"
        systemctl restart "$TPROXY_UNIT_MTPROXY" >/dev/null 2>&1 || true
        rm -f "$old_env"
        return 1
    fi
    rm -f "$old_env"
    success "Tag очищен."
}

telegram_proxy_rotate_secret() {
    local force=false arg new old_env old_profile old_tag old_secret rollback_rc=0
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            *) return 2 ;;
        esac
    done
    _telegram_proxy_is_installed || return 3
    [[ "$force" == true ]] ||
        confirm_yn "Ротировать общий secret (старые ссылки будут отозваны)?" || return 0
    old_secret="$TPROXY_RUNTIME_SECRET"
    new=$(_telegram_proxy_generate_secret) || return 1
    old_env="$TPROXY_ENV_FILE.telegram-proxy-old.$$"
    cp "$TPROXY_ENV_FILE" "$old_env" || return 1
    old_tag="${TPROXY_RUNTIME_TAG_ARGS:-}"
    old_profile=""
    if [[ "$TELEGRAM_WEB_ENABLED" == true ]]; then
        old_profile="$TPROXY_PROFILES_FILE.telegram-proxy-old.$$"
        cp "$TPROXY_PROFILES_FILE" "$old_profile" || { rm -f "$old_env"; return 1; }
    fi
    if ! _telegram_proxy_render_mtproxy_env "$new" "$old_tag" ||
       { [[ "$TELEGRAM_WEB_ENABLED" == true ]] && ! _telegram_proxy_render_profiles "$new"; }; then
        cp "$old_env" "$TPROXY_ENV_FILE"
        [[ -n "$old_profile" ]] && cp "$old_profile" "$TPROXY_PROFILES_FILE"
        rm -f "$old_env" "$old_profile"
        return 1
    fi
    if [[ "$TELEGRAM_MTPROTO_ENABLED" == true ]] &&
       ! systemctl restart "$TPROXY_UNIT_MTPROXY"; then
        rollback_rc=1
    fi
    if [[ "$rollback_rc" -eq 0 && "$TELEGRAM_WEB_ENABLED" == true ]]; then
        if ! systemctl restart "$TPROXY_UNIT_RELAY" ||
           ! _telegram_proxy_web_secret_accepted "$new"; then
            rollback_rc=1
        fi
    fi
    if [[ "$rollback_rc" -ne 0 ]]; then
        cp "$old_env" "$TPROXY_ENV_FILE" || rollback_rc=1
        [[ -n "$old_profile" ]] && cp "$old_profile" "$TPROXY_PROFILES_FILE" || true
        [[ "$TELEGRAM_MTPROTO_ENABLED" == true ]] &&
            systemctl restart "$TPROXY_UNIT_MTPROXY" >/dev/null 2>&1 || true
        [[ "$TELEGRAM_WEB_ENABLED" == true ]] &&
            systemctl restart "$TPROXY_UNIT_RELAY" >/dev/null 2>&1 || true
        if [[ "$TELEGRAM_WEB_ENABLED" == true ]] &&
           ! _telegram_proxy_web_secret_accepted "$old_secret"; then
            warn "Не удалось подтвердить восстановление старого WEB secret."
            rollback_rc=1
        fi
        rm -f "$old_env" "$old_profile"
        return 1
    fi
    rm -f "$old_env" "$old_profile"
    success "Secret ротирован для всех enabled components. Откройте Connection отдельно."
    return 0
}

telegram_proxy_web_restart() {
    local arg
    for arg in "$@"; do
        [[ "$arg" == --force ]] && return 2
        return 2
    done
    _telegram_proxy_component_enabled web || return 3
    systemctl restart "$TPROXY_UNIT_RELAY" || return 1
    _telegram_proxy_wait_endpoint "$TPROXY_READY_URL" || return 1
    success "WEB relay перезапущен."
}

telegram_proxy_mtproto_restart() {
    local arg was_ready=false
    for arg in "$@"; do
        [[ "$arg" == --force ]] && return 2
        return 2
    done
    _telegram_proxy_component_enabled mtproto || return 3
    if [[ "$TELEGRAM_WEB_ENABLED" == true ]] &&
       _telegram_proxy_probe "$TPROXY_READY_URL"; then
        was_ready=true
    fi
    systemctl restart "$TPROXY_UNIT_MTPROXY" || return 1
    _telegram_proxy_wait_mtproxy_listener || return 1
    if [[ "$was_ready" == true ]]; then
        _telegram_proxy_wait_endpoint "$TPROXY_READY_URL" || return 1
    fi
    warn "Общий MTProxy backend кратко затронул WEB relay." >&2
    success "MTProto перезапущен."
}

telegram_proxy_web_update() {
    local force=false arg latest old_sha go_binary candidate stage new_sha
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            *) return 2 ;;
        esac
    done
    _telegram_proxy_component_enabled web || return 3
    latest=$(_telegram_proxy_latest_sha 2>/dev/null || true)
    [[ -n "$latest" && "$latest" != "$TELEGRAM_RELAY_UPSTREAM_SHA" ]] || return 0
    [[ "$force" == true ]] || confirm_yn "Обновить WEB relay до проверенной ревизии ${latest}?" || return 0
    old_sha="$TELEGRAM_RELAY_UPSTREAM_SHA"
    stage=$(mktemp -d "${TMPDIR:-/tmp}/tproxy-update.XXXXXX") || return 1
    chmod 0700 "$stage" || { rm -rf "$stage"; return 1; }
    if ! _telegram_proxy_clone_relay "$stage"; then
        rm -rf "$stage"
        return 1
    fi
    go_binary=$(_telegram_proxy_find_go 2>/dev/null || true)
    [[ -n "$go_binary" ]] || go_binary=$(_telegram_proxy_install_pinned_go 2>/dev/null || true)
    [[ -n "$go_binary" ]] || { rm -rf "$stage"; return 1; }
    candidate=$(mktemp "${TMPDIR:-/tmp}/tproxy-server-update.XXXXXX") || { rm -rf "$stage"; return 1; }
    rm -f "$candidate"
    if ! (cd "$stage" && runuser -u tproxy -- "$go_binary" build -trimpath -ldflags='-s -w' -o "$candidate" ./cmd/tproxy-server); then
        rm -f "$candidate"; rm -rf "$stage"; return 1
    fi
    chmod 0755 "$candidate" || { rm -f "$candidate"; rm -rf "$stage"; return 1; }
    new_sha=$(git -C "$stage" rev-parse HEAD 2>/dev/null) || { rm -f "$candidate"; rm -rf "$stage"; return 1; }
    [[ "$new_sha" == "$TPROXY_UPSTREAM_CHECKSUM" ]] || { rm -f "$candidate"; rm -rf "$stage"; return 1; }
    _telegram_proxy_snapshot_paths "$TPROXY_RELAY_SOURCE_PATH" "$TPROXY_BIN" "$TPROXY_CONF" || {
        rm -f "$candidate"; rm -rf "$stage"; return 1;
    }
    rm -rf "$TPROXY_RELAY_SOURCE_PATH"
    mv "$stage" "$TPROXY_RELAY_SOURCE_PATH" || {
        rm -f "$candidate"; _telegram_proxy_restore_snapshot; return 1;
    }
    if ! install -o root -g root -m 0755 "$candidate" "$TPROXY_BIN" ||
       ! systemctl restart "$TPROXY_UNIT_RELAY" ||
       ! _telegram_proxy_wait_endpoint "$TPROXY_READY_URL"; then
        rm -f "$candidate"
        _telegram_proxy_restore_snapshot
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart "$TPROXY_UNIT_RELAY" >/dev/null 2>&1 || true
        return 1
    fi
    rm -f "$candidate"
    TELEGRAM_RELAY_UPSTREAM_SHA="$new_sha"
    if ! _telegram_proxy_state_write; then
        TELEGRAM_RELAY_UPSTREAM_SHA="$old_sha"
        _telegram_proxy_restore_snapshot
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart "$TPROXY_UNIT_RELAY" >/dev/null 2>&1 || true
        return 1
    fi
    _telegram_proxy_discard_snapshot
    success "WEB relay обновлён до проверенной ревизии. Откройте Status для проверки."
    return 0
}

telegram_proxy_refresh_ip() {
    local force=false arg new old
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            *) return 2 ;;
        esac
    done
    _telegram_proxy_component_enabled mtproto || return 3
    old="$TELEGRAM_MTPROTO_IPV4"
    new=$(_telegram_proxy_public_ipv4 | tr -d '[:space:]')
    _telegram_proxy_valid_public_ipv4 "$new" || return 2
    [[ "$new" == "$old" ]] && {
        info "Публичный IPv4 не изменился."
        return 0
    }
    info "IPv4 изменился: ${old} -> ${new}"
    [[ "$force" == true ]] || confirm_yn "Сохранить новый IPv4?" || return 0
    TELEGRAM_MTPROTO_IPV4="$new"
    _telegram_proxy_state_write || {
        TELEGRAM_MTPROTO_IPV4="$old"
        return 1
    }
    success "IPv4 сохранён."
}

# ─── Diagnostics, removal, menu and command grammar ───────────────────────────

_telegram_proxy_sanitize() {
    sed -E \
        -e 's/((^|[?&])(bridge|secret|tag|token|password|key)=)[^&[:space:]]+/\1[REDACTED]/g' \
        -e 's/((^|[[:space:]])(Authorization|Proxy-Authorization|X-Api-Key):[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
        -e 's/((^|[[:space:]])Sec-WebSocket-Protocol:[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
        -e 's/(^|[^[:alnum:]_])([a-fA-F0-9]{32}|dd[a-fA-F0-9]{32})([^[:alnum:]_]|$)/\1[REDACTED]\3/g'
}

telegram_proxy_diagnostics() {
    [[ $# -eq 0 ]] || return 2
    _telegram_proxy_is_installed || return 3
    echo "Telegram Proxy diagnostics"
    echo "-- shared journal --"
    journalctl -u "$TPROXY_UNIT_MTPROXY" -u "$TPROXY_UNIT_FIREWALL" \
        -u "$TPROXY_UNIT_TIMER" --since "30 minutes ago" --no-pager 2>/dev/null |
        _telegram_proxy_sanitize || true
    if [[ "$TELEGRAM_WEB_ENABLED" == true ]]; then
        echo "-- WEB relay metrics --"
        curl --fail --silent --max-time 5 "$TPROXY_METRICS_URL" 2>/dev/null |
            _telegram_proxy_sanitize || true
        echo "-- WEB relay journal --"
        journalctl -u "$TPROXY_UNIT_RELAY" --since "30 minutes ago" --no-pager 2>/dev/null |
            _telegram_proxy_sanitize || true
    fi
}

_telegram_proxy_cleanup_backend() {
    local rc=0
    systemctl disable --now "$TPROXY_UNIT_TIMER" "$TPROXY_UNIT_RELAY" \
        "$TPROXY_UNIT_MTPROXY" "$TPROXY_UNIT_FIREWALL" >/dev/null 2>&1 || rc=1
    if nft list table inet "$TPROXY_NFT_TABLE" >/dev/null 2>&1; then
        nft delete table inet "$TPROXY_NFT_TABLE" >/dev/null 2>&1 || rc=1
    fi
    rm -f "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_RELAY" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_FIREWALL" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_REFRESH" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_TIMER" "$TPROXY_REFRESH_BIN" \
        "$TPROXY_FIREWALL_FILE" "$TPROXY_ENV_FILE" || rc=1
    rm -rf "$TPROXY_MTPROXY_DIR" "$TPROXY_MTPROXY_SOURCE_DIR" "$TPROXY_RELAY_SOURCE_PATH" || rc=1
    systemctl daemon-reload >/dev/null 2>&1 || rc=1
    return "$rc"
}

telegram_proxy_web_remove() {
    local force=false arg host created relay_active relay_enabled failed=false
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            *) return 2 ;;
        esac
    done
    _telegram_proxy_component_enabled web || return 3
    host="$TELEGRAM_WEB_HOSTNAME"
    created="$TPROXY_CREATED_USER"
    relay_active=false
    relay_enabled=false
    systemctl is-active --quiet "$TPROXY_UNIT_RELAY" 2>/dev/null && relay_active=true
    systemctl is-enabled --quiet "$TPROXY_UNIT_RELAY" 2>/dev/null && relay_enabled=true
    [[ "$force" == true ]] || confirm_yn "Удалить Telegram WEB для ${host}?" || return 0
    _telegram_proxy_snapshot_paths \
        "$TPROXY_CONF" "$TPROXY_CONFIG_JSON" "$TPROXY_PROFILES_FILE" \
        "$TPROXY_RELAY_SOURCE_PATH" "$TPROXY_SITE_DIR" "$TPROXY_BIN" \
        "$TPROXY_NGINX_SITE" "$TPROXY_NGINX_ENABLED" "$TPROXY_NGINX_ACME_SITE" \
        "$TPROXY_NGINX_CONF" "$TPROXY_CERT_DIR/$host" "$TPROXY_WEBROOT_BASE/$host" \
        "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_RELAY" "$TPROXY_FIREWALL_FILE" || return 1
    if ! systemctl disable --now "$TPROXY_UNIT_RELAY" >/dev/null 2>&1; then
        _telegram_proxy_discard_snapshot
        return 1
    fi
    rm -f "$TPROXY_NGINX_ENABLED" "$TPROXY_NGINX_SITE" "$TPROXY_NGINX_ACME_SITE" \
        "$TPROXY_CONFIG_JSON" "$TPROXY_BIN" || failed=true
    if [[ "$TELEGRAM_WEB_TOPOLOGY" == sni ]] &&
       ! _telegram_proxy_remove_sni_markers; then
        failed=true
    fi
    rm -rf "$TPROXY_SITE_DIR" "$TPROXY_PROFILES_FILE" \
        "$TPROXY_CERT_DIR/$host" "$TPROXY_WEBROOT_BASE/$host" "$TPROXY_RELAY_SOURCE_PATH" || failed=true
    if [[ "$failed" == false ]] && ! nginx -t; then failed=true; fi
    if [[ "$failed" == false ]] && ! systemctl reload nginx; then failed=true; fi
    if [[ "$failed" == false ]] &&
       nginx -T 2>/dev/null | grep -F "$host" >/dev/null 2>&1; then
        warn "Удалённый hostname остался в активной nginx-конфигурации."
        failed=true
    fi
    if [[ "$failed" == false ]]; then
        TELEGRAM_WEB_ENABLED=false
        TELEGRAM_WEB_HOSTNAME=""
        TELEGRAM_WEB_EMAIL=""
        TELEGRAM_WEB_TOPOLOGY=""
        TELEGRAM_WEB_TLS_LISTEN=""
        TELEGRAM_WEB_IPV6=""
        TELEGRAM_RELAY_SOURCE_PATH=""
        TELEGRAM_RELAY_UPSTREAM_SHA=""
        TPROXY_CREATED_USER=false
        if [[ "$TELEGRAM_MTPROTO_ENABLED" == true ]]; then
            _telegram_proxy_render_firewall true || failed=true
            if [[ "$failed" == false ]] &&
               ! systemctl reload "$TPROXY_UNIT_FIREWALL" >/dev/null 2>&1 &&
               ! systemctl restart "$TPROXY_UNIT_FIREWALL" >/dev/null 2>&1; then
                failed=true
            fi
            [[ "$failed" == false ]] && _telegram_proxy_state_write || failed=true
        else
            _telegram_proxy_cleanup_backend || failed=true
            if [[ "$failed" == false && "$TPROXY_CREATED_USER" == true ]] &&
               ! userdel tproxy >/dev/null 2>&1; then
                failed=true
            fi
            if [[ "$failed" == false && "$MTPROXY_CREATED_USER" == true ]] &&
               ! userdel mtproxy >/dev/null 2>&1; then
                failed=true
            fi
            [[ "$failed" == false ]] && rm -f "$TPROXY_CONF" || failed=true
        fi
    fi
    if [[ "$failed" == true ]]; then
        local rollback_rc=0
        _telegram_proxy_restore_snapshot || rollback_rc=1
        if ! nginx -t >/dev/null 2>&1 || ! systemctl reload nginx >/dev/null 2>&1; then
            rollback_rc=1
        fi
        if (( rollback_rc != 0 )); then
            warn "Откат удаления Telegram Proxy завершился с ошибками; проверьте services, firewall и nginx."
        fi
        return 1
    fi
    _telegram_proxy_discard_snapshot
    if [[ "$TELEGRAM_MTPROTO_ENABLED" == true ]]; then
        success "Telegram WEB удалён; MTProto и общий tag сохранены."
    else
        success "Telegram Proxy удалён."
    fi
    return 0
}

telegram_proxy_mtproto_remove() {
    local force=false arg previous old_enabled old_ip old_previous failed=false
    for arg in "$@"; do
        case "$arg" in
            --force) force=true ;;
            *) return 2 ;;
        esac
    done
    _telegram_proxy_component_enabled mtproto || return 3
    previous="$TELEGRAM_UFW_MTPROTO_PREVIOUS"
    [[ "$force" == true ]] || confirm_yn "Удалить MTProto?" || return 0
    if [[ "$TELEGRAM_WEB_ENABLED" == true ]]; then
        _telegram_proxy_snapshot_paths "$TPROXY_CONF" "$TPROXY_FIREWALL_FILE" || return 1
        _telegram_proxy_ufw_apply_port 2398 "$previous" || {
            _telegram_proxy_discard_snapshot
            return 1
        }
        old_enabled="$TELEGRAM_MTPROTO_ENABLED"
        old_ip="$TELEGRAM_MTPROTO_IPV4"
        old_previous="$TELEGRAM_UFW_MTPROTO_PREVIOUS"
        TELEGRAM_MTPROTO_ENABLED=false
        TELEGRAM_MTPROTO_IPV4=""
        TELEGRAM_UFW_MTPROTO_PREVIOUS=""
        if ! _telegram_proxy_render_firewall false; then
            failed=true
        fi
        if [[ "$failed" == false ]] &&
           ! systemctl reload "$TPROXY_UNIT_FIREWALL" >/dev/null 2>&1; then
            systemctl restart "$TPROXY_UNIT_FIREWALL" >/dev/null 2>&1 || failed=true
        fi
        if [[ "$failed" == false ]] && ! _telegram_proxy_state_write; then
            failed=true
        fi
        if [[ "$failed" == true ]]; then
            TELEGRAM_MTPROTO_ENABLED="$old_enabled"
            TELEGRAM_MTPROTO_IPV4="$old_ip"
            TELEGRAM_UFW_MTPROTO_PREVIOUS="$old_previous"
            _telegram_proxy_restore_snapshot || failed=true
            return 1
        fi
        _telegram_proxy_discard_snapshot
        success "MTProto удалён; WEB и общий tag сохранены."
    else
        local mt_user_before=false tproxy_user_before=false
        id mtproxy >/dev/null 2>&1 && mt_user_before=true
        id tproxy >/dev/null 2>&1 && tproxy_user_before=true
        _telegram_proxy_snapshot_paths \
            "$TPROXY_CONF" "$TPROXY_ENV_FILE" "$TPROXY_MTPROXY_DIR" \
            "$TPROXY_MTPROXY_SOURCE_DIR" "$TPROXY_FIREWALL_FILE" \
            "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_MTPROXY" \
            "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_FIREWALL" \
            "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_REFRESH" \
            "$TPROXY_SYSTEMD_DIR/$TPROXY_UNIT_TIMER" "$TPROXY_REFRESH_BIN" || return 1
        if ! _telegram_proxy_ufw_apply_port 2398 "$previous" ||
           ! _telegram_proxy_cleanup_backend; then
            _telegram_proxy_restore_install_failure "" "$previous" "$mt_user_before" "$tproxy_user_before"
            return 1
        fi
        if [[ "$MTPROXY_CREATED_USER" == true ]] && ! userdel mtproxy >/dev/null 2>&1; then
            _telegram_proxy_restore_install_failure "" "$previous" "$mt_user_before" "$tproxy_user_before"
            return 1
        fi
        if [[ "$TPROXY_CREATED_USER" == true ]] && ! userdel tproxy >/dev/null 2>&1; then
            _telegram_proxy_restore_install_failure "" "$previous" "$mt_user_before" "$tproxy_user_before"
            return 1
        fi
        rm -f "$TPROXY_CONF" || {
            _telegram_proxy_restore_install_failure "" "$previous" "$mt_user_before" "$tproxy_user_before"
            return 1
        }
        _telegram_proxy_discard_snapshot
        success "Telegram Proxy удалён."
    fi
}

telegram_proxy_remove_all() {
    local arg force=false rc=0
    [[ "${TPROXY_INTERNAL_CALL:-false}" == true ]] || return 2
    for arg in "$@"; do
        [[ "$arg" == --force ]] || return 2
        force=true
    done
    [[ "$force" == true ]] || return 2
    if [[ -f "$TPROXY_CONF" ]]; then
        _telegram_proxy_load_conf || return 1
        _telegram_proxy_runtime_consistent || return 1
    else
        return 3
    fi
    if [[ "$TELEGRAM_WEB_ENABLED" == true ]]; then
        telegram_proxy_web_remove --force || rc=$?
    fi
    if [[ "$rc" -eq 0 && "$TELEGRAM_MTPROTO_ENABLED" == true ]]; then
        telegram_proxy_mtproto_remove --force || rc=$?
    fi
    return "$rc"
}

_telegram_proxy_menu_warn_failure() {
    warn "Операция Telegram Proxy завершилась с ошибкой. Повторите действие из меню."
}

_telegram_proxy_web_menu() {
    local choice
    while true; do
        if ! _telegram_proxy_component_enabled web; then
            return 0
        fi
        echo ""
        box_top
        box_center "Управление WEB"
        box_mid
        menu_item r "Перезапустить WEB" YELLOW
        menu_item u "Обновить WEB" YELLOW
        menu_item d "Удалить WEB" RED
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите действие: " choice; then
            return 0
        fi
        choice="${choice%$'\r'}"
        case "$choice" in
            r|R)
                if ! telegram_proxy_web_cli restart; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            u|U)
                if ! telegram_proxy_web_cli update; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            d|D)
                if ! telegram_proxy_web_cli remove; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

_telegram_proxy_mtproto_menu() {
    local choice
    while true; do
        if ! _telegram_proxy_component_enabled mtproto; then
            return 0
        fi
        echo ""
        box_top
        box_center "Управление MTProto"
        box_mid
        menu_item r "Перезапустить MTProto" YELLOW
        menu_item i "Обновить IP-адрес" YELLOW
        menu_item d "Удалить MTProto" RED
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите действие: " choice; then
            return 0
        fi
        choice="${choice%$'\r'}"
        case "$choice" in
            r|R)
                if ! telegram_proxy_mtproto_cli restart; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            i|I)
                if ! telegram_proxy_mtproto_cli refresh-ip; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            d|D)
                if ! telegram_proxy_mtproto_cli remove; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

_telegram_proxy_tag_menu() {
    local choice
    while true; do
        echo ""
        box_top
        box_center "Тег Telegram Proxy"
        box_mid
        menu_item s "Показать тег" CYAN
        menu_item e "Изменить тег" YELLOW
        menu_item d "Удалить тег" RED
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите действие: " choice; then
            return 0
        fi
        choice="${choice%$'\r'}"
        case "$choice" in
            s|S)
                if ! telegram_proxy_tag_show; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            e|E)
                if ! telegram_proxy_tag_set; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            d|D)
                if ! telegram_proxy_tag_clear; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}


telegram_proxy_menu() {
    local choice web_enabled mtproto_enabled
    while true; do
        web_enabled=false
        mtproto_enabled=false
        _telegram_proxy_component_enabled web && web_enabled=true
        _telegram_proxy_component_enabled mtproto && mtproto_enabled=true

        echo ""
        box_top
        box_center "Telegram Proxy"
        if [[ "$web_enabled" == true ]]; then
            box_line " WEB: включён" " ${GREEN}WEB: включён${NC}"
        else
            box_line " WEB: выключен" " ${DIM}WEB: выключен${NC}"
        fi
        if [[ "$mtproto_enabled" == true ]]; then
            box_line " MTProto: включён" " ${GREEN}MTProto: включён${NC}"
        else
            box_line " MTProto: выключен" " ${DIM}MTProto: выключен${NC}"
        fi
        box_mid
        menu_item 1 "Общий статус" CYAN
        menu_item 2 "Подключение" CYAN
        if [[ "$web_enabled" == true ]]; then
            menu_item 3 "Управление WEB" CYAN
        else
            menu_item 3 "Установить WEB" GREEN
        fi
        if [[ "$mtproto_enabled" == true ]]; then
            menu_item 4 "Управление MTProto" CYAN
        else
            menu_item 4 "Установить MTProto" GREEN
        fi
        menu_item 5 "Сменить секрет подключения" RED
        menu_item 6 "Тег Telegram Proxy" CYAN
        menu_item 7 "Диагностика" CYAN
        menu_item 8 "Удалить всё" RED
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите действие: " choice; then
            return 0
        fi
        choice="${choice%$'\r'}"
        case "$choice" in
            0) return 0 ;;
            1)
                if ! telegram_proxy_status; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            2)
                if ! telegram_proxy_connection; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            3)
                if [[ "$web_enabled" == true ]]; then
                    _telegram_proxy_web_menu
                elif ! telegram_proxy_web_cli install; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            4)
                if [[ "$mtproto_enabled" == true ]]; then
                    _telegram_proxy_mtproto_menu
                elif ! telegram_proxy_mtproto_cli install; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            5)
                if ! telegram_proxy_rotate_secret; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            6) _telegram_proxy_tag_menu ;;
            7)
                if ! telegram_proxy_diagnostics; then
                    _telegram_proxy_menu_warn_failure
                fi
                ;;
            8)
                if confirm_yn "Удалить все компоненты Telegram Proxy?" N; then
                    if ! TPROXY_INTERNAL_CALL=true telegram_proxy_remove_all --force; then
                        warn "Не удалось удалить все компоненты Telegram Proxy."
                    fi
                fi
                ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

telegram_proxy_web_cli() {
    local action="${1:-}"
    shift || true
    case "$action" in
        install) telegram_proxy_web_install "$@" ;;
        remove) telegram_proxy_web_remove "$@" ;;
        restart) telegram_proxy_web_restart "$@" ;;
        update) telegram_proxy_web_update "$@" ;;
        *) warn "Использование: telegram-proxy web <install|remove|restart|update>"; return 2 ;;
    esac
}

telegram_proxy_mtproto_cli() {
    local action="${1:-}"
    shift || true
    case "$action" in
        install) telegram_proxy_mtproto_install "$@" ;;
        remove) telegram_proxy_mtproto_remove "$@" ;;
        restart) telegram_proxy_mtproto_restart "$@" ;;
        refresh-ip) telegram_proxy_refresh_ip "$@" ;;
        *) warn "Использование: telegram-proxy mtproto <install|remove|restart|refresh-ip>"; return 2 ;;
    esac
}

telegram_proxy_cli() {
    local group="${1:-}" action arg json=false force=false
    local args=() seen_json=false seen_force=false
    [[ $# -gt 0 ]] && shift
    action="${1:-}"
    [[ $# -gt 0 ]] && shift
    if [[ "$group" == remove-all && "$action" == --force ]]; then
        force=true
        seen_force=true
        action=""
    fi
    if [[ "$action" == --json ]]; then
        json=true
        seen_json=true
        action=""
    fi
    for arg in "$@"; do
        case "$arg" in
            --json)
                [[ "$seen_json" == false ]] || return 2
                json=true
                seen_json=true
                ;;
            --force)
                [[ "$seen_force" == false ]] || return 2
                force=true
                seen_force=true
                ;;
            *) return 2 ;;
        esac
    done
    case "$group" in
        web)
            [[ -n "$action" && "$json" == false ]] || return 2
            if [[ "$force" == true ]]; then
                case "$action" in
                    install|remove|update) args+=(--force) ;;
                    *) return 2 ;;
                esac
            fi
            telegram_proxy_web_cli "$action" "${args[@]}"
            ;;
        mtproto)
            [[ -n "$action" && "$json" == false ]] || return 2
            if [[ "$force" == true ]]; then
                case "$action" in
                    install|remove|refresh-ip) args+=(--force) ;;
                    *) return 2 ;;
                esac
            fi
            telegram_proxy_mtproto_cli "$action" "${args[@]}"
            ;;
        status)
            [[ -z "$action" && "$force" == false ]] || return 2
            if [[ "$json" == true ]]; then
                telegram_proxy_status --json
            else
                telegram_proxy_status
            fi
            ;;
        connection)
            [[ -z "$action" && "$json" == false && "$force" == false ]] || return 2
            telegram_proxy_connection
            ;;
        rotate-secret)
            [[ -z "$action" && "$json" == false ]] || return 2
            if [[ "$force" == true ]]; then
                telegram_proxy_rotate_secret --force
            else
                telegram_proxy_rotate_secret
            fi
            ;;
        tag)
            [[ -n "$action" && "$json" == false ]] || return 2
            case "$action" in
                show)
                    [[ "$force" == false ]] || return 2
                    telegram_proxy_tag_show
                    ;;
                set)
                    [[ "$force" == false ]] || return 2
                    telegram_proxy_tag_set
                    ;;
                clear)
                    if [[ "$force" == true ]]; then
                        telegram_proxy_tag_clear --force
                    else
                        telegram_proxy_tag_clear
                    fi
                    ;;
                *) return 2 ;;
            esac
            ;;
        diagnostics)
            [[ -z "$action" && "$json" == false && "$force" == false ]] || return 2
            telegram_proxy_diagnostics
            ;;
        remove-all)
            [[ -z "$action" && "$json" == false && "$force" == true ]] || return 2
            TPROXY_INTERNAL_CALL=true telegram_proxy_remove_all --force
            ;;
        *)
            warn "Использование: telegram-proxy <web|mtproto|status|connection|rotate-secret|tag|diagnostics|remove-all>"
            return 2
            ;;
    esac
}
