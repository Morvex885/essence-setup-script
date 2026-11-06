#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    export AWG_DIR="$BATS_TEST_TMPDIR/amneziawg"
    export AWG_CONF="$AWG_DIR/awg0.conf"
    export AWG_CLIENTS_DIR="$BATS_TEST_TMPDIR/clients"
    export XHTTP_MIHOMO_CONFIG="$BATS_TEST_TMPDIR/config.yaml"
    export XHTTP_CLIENT_CONFIG="$BATS_TEST_TMPDIR/client-config.txt"
    export UI_CONFIRM_CALLS="$BATS_TEST_TMPDIR/confirm-calls"
    mkdir -p "$AWG_DIR" "$AWG_CLIENTS_DIR"
    printf 'mode: rule\n' > "$XHTTP_MIHOMO_CONFIG"
    : > "$XHTTP_CLIENT_CONFIG"
    source "$PROJECT_ROOT/setup-essence/modules/amneziawg.sh"
    source "$PROJECT_ROOT/setup-essence/modules/vless.sh"
    source "$PROJECT_ROOT/common/protocols/vless-tcp.sh"
    source "$PROJECT_ROOT/common/protocols/vless-xhttp.sh"
    source "$PROJECT_ROOT/common/protocols/vless-grpc.sh"
    source "$PROJECT_ROOT/common/protocols/hy2.sh"
    source "$PROJECT_ROOT/common/protocols/uri.sh"
}

teardown() { teardown_test_env; }

_seed_awg_clients() {
    mkdir -p "$AWG_CLIENTS_DIR/alpha" "$AWG_CLIENTS_DIR/beta"
    printf 'alpha-secret\n' > "$AWG_CLIENTS_DIR/alpha/alpha.conf"
    printf 'beta-secret\n' > "$AWG_CLIENTS_DIR/beta/beta.conf"
    cat > "$AWG_CONF" <<'CONF'
[Interface]
ListenPort = 33000

# peer: alpha
[Peer]
PublicKey = alpha-key
AllowedIPs = 10.10.8.2/32

# peer: beta
[Peer]
PublicKey = beta-key
AllowedIPs = 10.10.8.3/32

CONF
    cp "$AWG_CONF" "$BATS_TEST_TMPDIR/awg-before"
}

_reject_confirmation() {
    confirm_yn() { printf '%s\n' "$1" >> "$UI_CONFIRM_CALLS"; return 1; }
}

_redirect_vless_config() {
    grep() {
        local args=() arg
        for arg in "$@"; do
            case "$arg" in
                /etc/mihomo/config.yaml) arg="$XHTTP_MIHOMO_CONFIG" ;;
            esac
            args+=("$arg")
        done
        command grep "${args[@]}"
    }
    _check_base() { return 0; }
    _check_reality() { return 0; }
    _load_reality_conf() { HAS_SITE=true; MIHOMO_LISTEN=0.0.0.0; MIHOMO_PORT=443; }
}

@test "AmneziaWG deletion rejects expressions and leading zeros before cancellation" {
    _seed_awg_clients
    _reject_confirmation
    run remove_awg_peer <<< $'01\n1+1\n0'
    assert_failure 1
    [[ ! -e "$UI_CONFIRM_CALLS" ]]
    cmp "$AWG_CONF" "$BATS_TEST_TMPDIR/awg-before"
    [[ -s "$AWG_CLIENTS_DIR/alpha/alpha.conf" && -s "$AWG_CLIENTS_DIR/beta/beta.conf" ]]
}

@test "AmneziaWG deletion EOF does not confirm or mutate the existing clients" {
    _seed_awg_clients
    _reject_confirmation
    run remove_awg_peer < /dev/null
    assert_failure 1
    [[ ! -e "$UI_CONFIRM_CALLS" ]]
    cmp "$AWG_CONF" "$BATS_TEST_TMPDIR/awg-before"
    [[ -s "$AWG_CLIENTS_DIR/alpha/alpha.conf" && -s "$AWG_CLIENTS_DIR/beta/beta.conf" ]]
}

@test "AmneziaWG deletion uses the canonical selected client without deleting its neighbour" {
    _seed_awg_clients
    # Both GNU and BSD sed accept a nonempty backup suffix.
    sed() {
        if [[ "$1" == -i ]]; then
            shift
            command sed -i.bak "$@"
        else
            command sed "$@"
        fi
    }
    awg() { return 0; }
    awg-quick() { cat "$AWG_CONF"; }
    run remove_awg_peer <<< $'01\n1+1\n2\ny'
    assert_success
    [[ -s "$AWG_CLIENTS_DIR/alpha/alpha.conf" ]]
    [[ ! -e "$AWG_CLIENTS_DIR/beta" ]]
    command grep -q '^# peer: alpha$' "$AWG_CONF"
    ! command grep -q '^# peer: beta$' "$AWG_CONF"
}

@test "noninteractive AmneziaWG removal can be repeated after partial client deletion" {
    _seed_awg_clients
    sed() {
        if [[ "$1" == -i ]]; then shift; command sed -i.bak "$@"; else command sed "$@"; fi
    }
    awg() { return 0; }
    awg-quick() { cat "$AWG_CONF"; }
    remove_awg_peer_by_name alpha
    remove_awg_peer_by_name alpha
    [[ ! -d "$AWG_CLIENTS_DIR/alpha" && -d "$AWG_CLIENTS_DIR/beta" ]]
    ! command grep -qx '# peer: alpha' "$AWG_CONF"
    command grep -qx '# peer: beta' "$AWG_CONF"
}

@test "absent AmneziaWG directory does not conceal an active peer block" {
    _seed_awg_clients
    command rm -rf "$AWG_CLIENTS_DIR/alpha"
    sed() {
        if [[ "$1" == -i ]]; then shift; command sed -i.bak "$@"; else command sed "$@"; fi
    }
    awg() { return 0; }
    awg-quick() { cat "$AWG_CONF"; }
    remove_awg_peer_by_name alpha
    ! command grep -qx '# peer: alpha' "$AWG_CONF"
    command grep -qx '# peer: beta' "$AWG_CONF"
}

@test "failed AmneziaWG synchronization retains the client for a later removal attempt" {
    _seed_awg_clients
    sed() {
        if [[ "$1" == -i ]]; then shift; command sed -i.bak "$@"; else command sed "$@"; fi
    }
    awg-quick() { cat "$AWG_CONF"; }
    awg() { return 1; }
    systemctl() { return 1; }
    ! remove_awg_peer_by_name alpha
    [[ -d "$AWG_CLIENTS_DIR/alpha" ]]
    awg() { return 0; }
    remove_awg_peer_by_name alpha
    [[ ! -d "$AWG_CLIENTS_DIR/alpha" && -d "$AWG_CLIENTS_DIR/beta" ]]
}

@test "empty AmneziaWG selector returns without consuming operator input" {
    printf '[Interface]\n' > "$AWG_CONF"
    _select_then_read() {
        local rc next
        remove_awg_peer
        rc=$?
        IFS= read -r next
        [[ "$rc" -eq 1 && "$next" == untouched ]]
    }
    run _select_then_read <<< untouched
    assert_success
}

@test "VLESS removal rejects noncanonical indices and preserves the transport on cancellation" {
    _redirect_vless_config
    _reject_confirmation
    printf '# --- vless-tcp ---\n  - name: VLESS TCP\n# --- /vless-tcp ---\n' > "$XHTTP_MIHOMO_CONFIG"
    cp "$XHTTP_MIHOMO_CONFIG" "$BATS_TEST_TMPDIR/vless-before"
    run _remove_vless_transport <<< $'01\n1+1\n0'
    assert_failure 1
    [[ ! -e "$UI_CONFIRM_CALLS" ]]
    cmp "$XHTTP_MIHOMO_CONFIG" "$BATS_TEST_TMPDIR/vless-before"
}

@test "empty VLESS selector returns without consuming operator input" {
    _redirect_vless_config
    _select_then_read() {
        local rc next
        _remove_vless_transport
        rc=$?
        IFS= read -r next
        [[ "$rc" -eq 1 && "$next" == untouched ]]
    }
    run _select_then_read <<< untouched
    assert_success
}

@test "Reality xHTTP and gRPC default selectors cancel and reach EOF before mutation" {
    _redirect_vless_config
    _reject_confirmation
    cp "$XHTTP_MIHOMO_CONFIG" "$BATS_TEST_TMPDIR/vless-before"
    for action in setup_reality _add_vless_xhttp _add_vless_grpc; do
        run "$action" <<< $'01\n1+1\n0'
        assert_failure 1
        run "$action" < /dev/null
        assert_failure 1
    done
    [[ ! -e "$UI_CONFIRM_CALLS" ]]
    cmp "$XHTTP_MIHOMO_CONFIG" "$BATS_TEST_TMPDIR/vless-before"
}

@test "manual exit input EOF never produces YAML using stale optional defaults" {
    C_SNI=stale.example C_PATH=/stale C_SERVICE=stale-service C_OBFS=stale-obfs
    for action in _ask_exit_vless_tcp _ask_exit_vless_xhttp _ask_exit_vless_grpc; do
        run "$action" exit-node <<< $'vpn.example\n443\nauth-uuid\npublic-key\nshort-id'
        assert_failure 1
        [[ "$output" != *'name:'* && "$output" != *auth-uuid* ]]
    done
    run _ask_exit_hy2 exit-node <<< $'vpn.example\n443\nauth-password'
    assert_failure 1
    [[ "$output" != *'name:'* && "$output" != *auth-password* ]]
    URI='vless://stale-uuid@stale.example:443?security=reality'
    run _parse_proxy_uri exit-node < /dev/null
    assert_failure 1
    [[ "$output" != *'name:'* && "$output" != *stale-uuid* ]]
}

@test "manual exit input strips CR and preserves Enter defaults in actual generated YAML" {
    run _ask_exit_vless_xhttp exit-node <<< $'vpn.example\r\n\r\nauth-uuid\r\npublic-key\r\nshort-id\r\n\r\n\r'
    assert_success
    [[ "$output" != *$'\r'* ]]
    assert_output --partial 'server: vpn.example'
    assert_output --partial 'port: 443'
    assert_output --partial 'uuid: auth-uuid'
    assert_output --partial 'servername: vpn.example'
    assert_output --partial 'path: "/"'
}
