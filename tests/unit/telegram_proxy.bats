#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    export TPROXY_DIR="$BATS_TEST_TMPDIR/etc-tproxy"
    export TPROXY_CONF="$TPROXY_DIR/essence.conf"
    export TPROXY_CONFIG_JSON="$TPROXY_DIR/config.json"
    export TPROXY_PROFILES_FILE="$BATS_TEST_TMPDIR/etc-tproxy/profiles.json"
    export TPROXY_PROFILES_RUNTIME_FILE="$BATS_TEST_TMPDIR/run/credentials/tproxy-server.service/profiles.json"
    export TPROXY_ENV_FILE="$BATS_TEST_TMPDIR/etc-mtproxy/mtproxy.env"
    export TPROXY_MTPROXY_DIR="$BATS_TEST_TMPDIR/etc-mtproxy"
    export TPROXY_MTPROXY_SOURCE_DIR="$BATS_TEST_TMPDIR/opt/MTProxy"
    export TPROXY_RELAY_SOURCE_PATH="$BATS_TEST_TMPDIR/opt/tproxy-server-source"
    export TPROXY_SITE_DIR="$BATS_TEST_TMPDIR/site"
    export TPROXY_NGINX_SITE="$BATS_TEST_TMPDIR/nginx/sites-available/essence-telegram-proxy"
    export TPROXY_NGINX_ENABLED="$BATS_TEST_TMPDIR/nginx/sites-enabled/essence-telegram-proxy"
    export TPROXY_NGINX_CONF="$BATS_TEST_TMPDIR/nginx/nginx.conf"
    export TPROXY_CERT_DIR="$BATS_TEST_TMPDIR/ssl"
    export TPROXY_SYSTEMD_DIR="$BATS_TEST_TMPDIR/systemd"
    source "$PROJECT_ROOT/setup-essence/modules/telegram-proxy.sh"
}

teardown() { teardown_test_env; }
_file_mode() {
    if [[ "$(uname -s)" == Darwin ]]; then
        stat -f '%Lp' "$1"
    else
        stat -c '%a' "$1"
    fi
}

_upstream_sha=f7a6acc4d536a787d442fd7df3ba4ebfd728f406


_valid_secret=0123456789abcdef0123456789abcdef

write_mtproto_state() {
    _telegram_proxy_initialize_state
    TELEGRAM_MTPROTO_ENABLED=true
    TELEGRAM_MTPROTO_IPV4=8.8.8.8
    TELEGRAM_UFW_MTPROTO_PREVIOUS=absent
    _telegram_proxy_render_mtproxy_env "$_valid_secret"
    _telegram_proxy_state_write
}

write_web_state() {
    _telegram_proxy_initialize_state
    TELEGRAM_WEB_ENABLED=true
    TELEGRAM_WEB_HOSTNAME=web.example.com
    TELEGRAM_WEB_EMAIL=operator@example.com
    TELEGRAM_WEB_TOPOLOGY=direct
    TELEGRAM_WEB_TLS_LISTEN=0.0.0.0:443
    TELEGRAM_WEB_IPV6=false
    TELEGRAM_RELAY_SOURCE_PATH="$TPROXY_RELAY_SOURCE_PATH"
    TELEGRAM_RELAY_UPSTREAM_SHA="$_upstream_sha"
    _telegram_proxy_render_mtproxy_env "$_valid_secret"
    _telegram_proxy_render_profiles "$_valid_secret"
    _telegram_proxy_state_write
}
write_both_state() {
    write_web_state
    TELEGRAM_MTPROTO_ENABLED=true
    TELEGRAM_MTPROTO_IPV4=8.8.8.8
    TELEGRAM_UFW_MTPROTO_PREVIOUS=absent
    _telegram_proxy_state_write
}

_run_telegram_menu() {
    telegram_proxy_menu < "$1"
    echo MENU_RETURNED
}

_menu_journal() {
    printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/menu-journal"
}

@test "validators accept managed values and reject unsafe inputs" {
    run _telegram_proxy_valid_hostname web.example.com
    [ "$status" -eq 0 ]
    run _telegram_proxy_valid_hostname Example.com
    [ "$status" -ne 0 ]
    run _telegram_proxy_valid_hostname 'https://web.example.com:443/path'
    [ "$status" -ne 0 ]
    run _telegram_proxy_valid_email operator@example.com
    [ "$status" -eq 0 ]
    run _telegram_proxy_valid_email operator@example
    [ "$status" -ne 0 ]
    run _telegram_proxy_valid_secret "$_valid_secret"
    [ "$status" -eq 0 ]
    run _telegram_proxy_valid_secret dd0123456789abcdef0123456789abcdef
    [ "$status" -ne 0 ]
    run _telegram_proxy_valid_public_ipv4 8.8.8.8
    [ "$status" -eq 0 ]
    run _telegram_proxy_valid_public_ipv4 192.168.1.5
    [ "$status" -ne 0 ]
}

@test "state accepts WEB-only, MTProto-only and both combinations" {
    write_mtproto_state
    run _telegram_proxy_is_installed
    [ "$status" -eq 0 ]

    write_web_state
    run _telegram_proxy_is_installed
    [ "$status" -eq 0 ]

    TELEGRAM_MTPROTO_ENABLED=true
    TELEGRAM_MTPROTO_IPV4=8.8.8.8
    TELEGRAM_UFW_MTPROTO_PREVIOUS=deny
    _telegram_proxy_state_write
    run _telegram_proxy_is_installed
    [ "$status" -eq 0 ]
}

@test "state rejects zero components and invalid conditional fields" {
    _telegram_proxy_initialize_state
    run _telegram_proxy_state_write
    [ "$status" -ne 0 ]

    write_mtproto_state
    awk '{ sub(/TELEGRAM_MTPROTO_PORT=2398/, "TELEGRAM_MTPROTO_PORT=443"); print }' "$TPROXY_CONF" > "$TPROXY_CONF.tmp"
    mv "$TPROXY_CONF.tmp" "$TPROXY_CONF"
    run _telegram_proxy_is_installed
    [ "$status" -ne 0 ]

    write_web_state
    awk '{ sub(/TELEGRAM_WEB_IPV6=false/, "TELEGRAM_WEB_IPV6=maybe"); print }' "$TPROXY_CONF" > "$TPROXY_CONF.tmp"
    mv "$TPROXY_CONF.tmp" "$TPROXY_CONF"
    run _telegram_proxy_is_installed
    [ "$status" -ne 0 ]
}

@test "state and credentials use restrictive modes and no runtime credential directory" {
    write_web_state
    [ "$(_file_mode "$TPROXY_CONF")" = 600 ]
    [ "$(_file_mode "$TPROXY_PROFILES_FILE")" = 400 ]
    [ ! -e "$TPROXY_PROFILES_RUNTIME_FILE" ]
    run _telegram_proxy_is_installed
    [ "$status" -eq 0 ]
    [[ "$output" != *"$_valid_secret"* ]]
}
@test "token key is atomic, exact length and rejects symlinks" {
    TPROXY_TOKEN_KEY="$BATS_TEST_TMPDIR/token.key"
    chown() { return 0; }
    _telegram_proxy_ensure_token_key
    [ "$(_file_mode "$TPROXY_TOKEN_KEY")" = 400 ]
    [ "$(wc -c < "$TPROXY_TOKEN_KEY" | tr -d '[:space:]')" -eq 32 ]
    rm -f "$TPROXY_TOKEN_KEY"
    ln -s "$BATS_TEST_TMPDIR/elsewhere" "$TPROXY_TOKEN_KEY"
    run _telegram_proxy_ensure_token_key
    [ "$status" -ne 0 ]
}

@test "component-aware firewall blocks public client port in WEB-only mode" {
    TPROXY_FIREWALL_FILE="$BATS_TEST_TMPDIR/firewall.nft"
    _telegram_proxy_render_firewall false
    grep -q '2398 drop' "$TPROXY_FIREWALL_FILE"
    grep -q '8888' "$TPROXY_FIREWALL_FILE"
    _telegram_proxy_render_firewall true
    ! grep -q '2398 drop' "$TPROXY_FIREWALL_FILE"
    grep -q '8888' "$TPROXY_FIREWALL_FILE"
    grep -q 'iifname != "lo"' "$TPROXY_FIREWALL_FILE"
}

@test "validated upstream unit receives exactly one optional tag argument" {
    local source="$BATS_TEST_TMPDIR/mtproxy.service"
    local target="$BATS_TEST_TMPDIR/mtproxy-rendered.service"
    cat > "$source" <<'EOF'
[Service]
Environment=MTPROXY_WORKERS=1
ExecStart=/opt/MTProxy/mtproto-proxy -p 8888 -H 2398 -S ${MTPROXY_SECRET} --aes-pwd default
EOF
    _telegram_proxy_render_mtproxy_unit "$source" "$target"
    [ "$(grep -cF '$MTPROXY_TAG_ARGS' "$target")" -eq 1 ]
    grep -q '2398.*\$MTPROXY_TAG_ARGS.*--aes-pwd' "$target"
}

@test "SNI markers remain idempotent and preserve Subscription entries" {
    mkdir -p "$(dirname "$TPROXY_NGINX_CONF")"
    cat > "$TPROXY_NGINX_CONF" <<'EOF'
stream {
    map $ssl_preread_server_name $name {
        subscription.example.com subscription;
        default mihomo;
    }
    upstream mihomo {
        server 127.0.0.1:8443;
    }
}
EOF
    _telegram_proxy_patch_sni_nginx web.example.com
    cp "$TPROXY_NGINX_CONF" "$BATS_TEST_TMPDIR/nginx.before"
    _telegram_proxy_patch_sni_nginx web.example.com
    cmp -s "$BATS_TEST_TMPDIR/nginx.before" "$TPROXY_NGINX_CONF"
    [ "$(grep -c '# --- telegram-proxy-map ---' "$TPROXY_NGINX_CONF")" -eq 1 ]
    [ "$(grep -c '# --- telegram-proxy-upstream ---' "$TPROXY_NGINX_CONF")" -eq 1 ]
    grep -q 'subscription.example.com subscription;' "$TPROXY_NGINX_CONF"
}

@test "diagnostic sanitizer redacts secrets, tags and request credentials" {
    output=$(printf '%s\n' \
        'GET /?bridge=secret&secret=0123456789abcdef0123456789abcdef' \
        'Authorization: Bearer token' \
        'Sec-WebSocket-Protocol: credential' \
        'tag=abcdefabcdefabcdefabcdefabcdefab' \
        '0123456789abcdef0123456789abcdef' | _telegram_proxy_sanitize)
    [[ "$output" != *"Bearer token"* ]]
    [[ "$output" != *"0123456789abcdef0123456789abcdef"* ]]
    [[ "$output" != *"abcdefabcdefabcdefabcdefabcdefab"* ]]
    [[ "$output" == *"REDACTED"* ]]
}
@test "Telegram menu: root rejects invalid and Enter, then handles status, 0 and EOF" {
    write_web_state
    telegram_proxy_status() {
        _menu_journal status
        return 0
    }

    local input="$BATS_TEST_TMPDIR/menu-input"
    printf 'x\n\n1\n0\n' > "$input"
    run _run_telegram_menu "$input"
    [ "$status" -eq 0 ]
    [[ "$output" == *MENU_RETURNED* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/menu-journal")" = status ]

    : > "$input"
    run _run_telegram_menu "$input"
    [ "$status" -eq 0 ]
    [[ "$output" == *MENU_RETURNED* ]]
}

@test "Telegram menu: WEB management keeps submenu after failure and accepts uppercase keys" {
    write_web_state
    telegram_proxy_web_cli() {
        _menu_journal "web:$1"
        [[ "$1" == restart ]] && return 1
        return 0
    }
    telegram_proxy_status() {
        _menu_journal status
        return 0
    }

    local input="$BATS_TEST_TMPDIR/menu-input"
    printf '3\nrestart\nR\nU\n0\n1\n0\n' > "$input"
    run _run_telegram_menu "$input"
    [ "$status" -eq 0 ]
    [[ "$output" == *MENU_RETURNED* ]]
    printf 'web:restart\nweb:update\nstatus\n' > "$BATS_TEST_TMPDIR/menu-expected"
    cmp -s "$BATS_TEST_TMPDIR/menu-expected" "$BATS_TEST_TMPDIR/menu-journal"
}

@test "Telegram menu: MTProto management routes uppercase actions and remains open after failure" {
    write_mtproto_state
    telegram_proxy_mtproto_cli() {
        _menu_journal "mtproto:$1"
        [[ "$1" == refresh-ip ]] && return 1
        return 0
    }
    telegram_proxy_status() {
        _menu_journal status
        return 0
    }

    local input="$BATS_TEST_TMPDIR/menu-input"
    printf '4\nI\nR\n0\n1\n0\n' > "$input"
    run _run_telegram_menu "$input"
    [ "$status" -eq 0 ]
    [[ "$output" == *MENU_RETURNED* ]]
    printf 'mtproto:refresh-ip\nmtproto:restart\nstatus\n' > "$BATS_TEST_TMPDIR/menu-expected"
    cmp -s "$BATS_TEST_TMPDIR/menu-expected" "$BATS_TEST_TMPDIR/menu-journal"
}

@test "Telegram menu: installation state changes open component management on next root redraw" {
    write_web_state
    telegram_proxy_mtproto_cli() {
        _menu_journal "mtproto:$1"
        if [[ "$1" == install ]]; then
            write_both_state
        fi
        return 0
    }

    local input="$BATS_TEST_TMPDIR/menu-input"
    printf '4\n4\nR\n0\n0\n' > "$input"
    run _run_telegram_menu "$input"
    [ "$status" -eq 0 ]
    [[ "$output" == *MENU_RETURNED* ]]
    printf 'mtproto:install\nmtproto:restart\n' > "$BATS_TEST_TMPDIR/menu-expected"
    cmp -s "$BATS_TEST_TMPDIR/menu-expected" "$BATS_TEST_TMPDIR/menu-journal"
}

@test "Telegram menu: disappearing WEB context returns to parent menu" {
    write_both_state
    telegram_proxy_web_cli() {
        _menu_journal "web:$1"
        if [[ "$1" == remove ]]; then
            write_mtproto_state
        fi
        return 0
    }
    telegram_proxy_status() {
        _menu_journal status
        return 0
    }

    local input="$BATS_TEST_TMPDIR/menu-input"
    printf '3\nD\n1\n0\n' > "$input"
    run _run_telegram_menu "$input"
    [ "$status" -eq 0 ]
    [[ "$output" == *MENU_RETURNED* ]]
    printf 'web:remove\nstatus\n' > "$BATS_TEST_TMPDIR/menu-expected"
    cmp -s "$BATS_TEST_TMPDIR/menu-expected" "$BATS_TEST_TMPDIR/menu-journal"
}

@test "Telegram menu: tag submenu persists across actions and handler failure" {
    write_web_state
    telegram_proxy_tag_clear() {
        _menu_journal tag:clear
        return 1
    }
    telegram_proxy_tag_show() {
        _menu_journal tag:show
        return 0
    }
    telegram_proxy_tag_set() {
        _menu_journal tag:set
        return 0
    }

    local input="$BATS_TEST_TMPDIR/menu-input"
    printf '6\nD\nS\nE\n0\n0\n' > "$input"
    run _run_telegram_menu "$input"
    [ "$status" -eq 0 ]
    [[ "$output" == *MENU_RETURNED* ]]
    printf 'tag:clear\ntag:show\ntag:set\n' > "$BATS_TEST_TMPDIR/menu-expected"
    cmp -s "$BATS_TEST_TMPDIR/menu-expected" "$BATS_TEST_TMPDIR/menu-journal"
}

@test "Telegram menu: remove-all confirmation routes only after explicit approval" {
    write_both_state
    confirm_yn() {
        _menu_journal confirm
        return "${MENU_CONFIRM_RC:-0}"
    }
    telegram_proxy_remove_all() {
        _menu_journal remove-all
        return 0
    }
    local input="$BATS_TEST_TMPDIR/menu-input"

    MENU_CONFIRM_RC=1
    printf '8\n0\n' > "$input"
    run _run_telegram_menu "$input"
    [ "$status" -eq 0 ]
    [[ "$output" == *MENU_RETURNED* ]]
    printf 'confirm\n' > "$BATS_TEST_TMPDIR/menu-expected"
    cmp -s "$BATS_TEST_TMPDIR/menu-expected" "$BATS_TEST_TMPDIR/menu-journal"

    rm -f "$BATS_TEST_TMPDIR/menu-journal"
    MENU_CONFIRM_RC=0
    printf '8\n0\n' > "$input"
    run _run_telegram_menu "$input"
    [ "$status" -eq 0 ]
    printf 'confirm\nremove-all\n' > "$BATS_TEST_TMPDIR/menu-expected"
    cmp -s "$BATS_TEST_TMPDIR/menu-expected" "$BATS_TEST_TMPDIR/menu-journal"
}
