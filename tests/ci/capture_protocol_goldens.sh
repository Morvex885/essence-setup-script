#!/bin/bash
# Captures golden outputs of the Bash protocol builders/parsers for byte
# comparison with the Rust port. Read-only for common/ and the repository.
#
# Output: one JSON per source module in <out>/<module>.json
#   {"module": "...", "cases": [{"function", "case", "invoke", "args", "globals",
#     "stdin_b64", "stdout_b64", "stderr_b64", "rc"}]}
# Raw bytes are base64 so CRLF and non-UTF-8 survive. Output is deterministic.
#
# Usage: tests/ci/capture_protocol_goldens.sh [output_dir]
#        GOLDEN_OUT=/tmp/x tests/ci/capture_protocol_goldens.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-${GOLDEN_OUT:-$ROOT/remote-control/core/tests/golden/protocols}}"
export LANG=C.UTF-8
unset LC_ALL

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EMPTY_CWD="$WORK/cwd"
SYNC_DIR="$WORK/sync"
mkdir -p "$EMPTY_CWD" "$SYNC_DIR" "$OUT"

# listener-users.sh hardcodes /etc/mihomo/config.yaml. Use a temp copy that
# points at a temp config; the source under common/ is never modified.
sed "s|/etc/mihomo/config.yaml|$SYNC_DIR/config.yaml|" \
    "$ROOT/common/listener-users.sh" > "$SYNC_DIR/listener-users.sh"

source "$ROOT/common/common.sh"
for f in uri hy2 vless-tcp vless-grpc vless-xhttp iptables-dnat; do
    source "$ROOT/common/protocols/$f.sh"
done
source "$SYNC_DIR/listener-users.sh"

MODULES="uri hy2 vless-tcp vless-grpc vless-xhttp iptables-dnat listener-users"
for m in $MODULES; do : > "$WORK/$m.ndjson"; done
GLOBALS_JSON=''
COUNT=0

json_args() { printf '%s\0' "$@" | jq -Rs 'split("\u0000")[:-1]'; }

# c <module> <function> <case> <stdin|<none>> [args...]
#   Runs <function> in a subshell with cwd in an empty temp dir and stdin
#   from the given string (or /dev/null for <none>). Appends one NDJSON record.
c() { run_case "$1" "$2" "$2" "$3" "$4" "${@:5}"; }

# run_case <module> <function> <invoke> <case> <stdin|<none>> [args...]
run_case() {
    local module="$1" fn="$2" invoke="$3" name="$4" stdin="$5"
    shift 5
    local globals="${GLOBALS_JSON:-}" stdin_b64=null rc
    [[ -n "$globals" ]] || globals='{}'
    if [[ "$stdin" != "<none>" ]]; then
        stdin_b64=$(printf '%s' "$stdin" | base64 -w0 | jq -Rs .)
    fi
    (
        cd "$EMPTY_CWD" || exit 99
        if [[ "$stdin" == "<none>" ]]; then
            "$invoke" "$@" < /dev/null
        else
            printf '%s' "$stdin" | "$invoke" "$@"
        fi
    ) > "$WORK/stdout" 2> "$WORK/stderr"
    rc=$?
    jq -cn --arg fn "$fn" --arg invoke "$invoke" --arg case "$name" \
        --argjson args "$(json_args "$@")" --argjson globals "$globals" \
        --argjson stdin_b64 "$stdin_b64" \
        --arg stdout_b64 "$(base64 -w0 < "$WORK/stdout")" \
        --arg stderr_b64 "$(base64 -w0 < "$WORK/stderr")" \
        --argjson rc "$rc" \
        '{function: $fn, invoke: $invoke, case: $case, args: $args, globals: $globals,
          stdin_b64: $stdin_b64, stdout_b64: $stdout_b64, stderr_b64: $stderr_b64, rc: $rc}' \
        >> "$WORK/$module.ndjson"
    COUNT=$((COUNT + 1))
}

# ── wrappers ────────────────────────────────────────────────────────────────

w_server_port() {
    _parse_server_port_from_uri "$1"
    printf 'server=%s\nport=%s\n' "$URI_SERVER" "$URI_PORT"
}

# Stubs shadow iptables/sysctl/netfilter-persistent and the two sed/grep calls
# that touch /etc/sysctl.conf. Each stub appends argv to $DNAT_LOG. Functions
# are defined inside the per-case subshell, so nothing leaks and the real
# firewall and sysctl configuration are never touched.
dnat_rec() { printf '%s' "$1"; shift; local a; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; }
dnat_stubs() {
    DNAT_LOG="$WORK/dnat.log"; : > "$DNAT_LOG"
    iptables() { dnat_rec iptables "$@" >> "$DNAT_LOG"; }
    ip6tables() { dnat_rec ip6tables "$@" >> "$DNAT_LOG"; }
    sysctl() { dnat_rec sysctl "$@" >> "$DNAT_LOG"; }
    netfilter-persistent() { dnat_rec netfilter-persistent "$@" >> "$DNAT_LOG"; }
    grep() {
        if [[ "$*" == *"/etc/sysctl.conf"* ]]; then
            dnat_rec grep "$@" >> "$DNAT_LOG"
            [[ "$1" == "-q" ]]
            return
        fi
        command grep "$@"
    }
    sed() {
        if [[ "$*" == *"/etc/sysctl.conf"* ]]; then dnat_rec sed "$@" >> "$DNAT_LOG"; return 0; fi
        command sed "$@"
    }
}
w_apply_dnat() { dnat_stubs; _apply_dnat_rules "$@"; local rc=$?; cat "$DNAT_LOG"; return "$rc"; }
w_remove_dnat() { dnat_stubs; _remove_dnat_rules "$@"; local rc=$?; cat "$DNAT_LOG"; return "$rc"; }
w_persist_dnat() { dnat_stubs; _persist_dnat_rules "$@"; local rc=$?; cat "$DNAT_LOG"; return "$rc"; }

w_sync() {
    _sync_listener_users "$1" "$2"
    local rc=$?
    cat "$SYNC_DIR/config.yaml" 2>/dev/null
    return "$rc"
}

# sync_case <case> <marker> <users_yaml> <config|<none>>
sync_case() {
    local name="$1" marker="$2" users="$3" config="$4"
    if [[ "$config" == "<none>" ]]; then
        rm -f "$SYNC_DIR/config.yaml"
        GLOBALS_JSON=$(jq -cn '{config_path: "/etc/mihomo/config.yaml", config_yaml: null,
            note: "stdout is the resulting config file (or empty if absent)"}')
    else
        printf '%s' "$config" > "$SYNC_DIR/config.yaml"
        GLOBALS_JSON=$(jq -cn --arg c "$config" '{config_path: "/etc/mihomo/config.yaml",
            config_yaml: $c, note: "stdout is the resulting config file (or empty if absent)"}')
    fi
    run_case listener-users _sync_listener_users w_sync "$name" '<none>' "$marker" "$users"
    GLOBALS_JSON=''
}

ps() { run_case uri _parse_server_port_from_uri w_server_port "$1" '<none>' "$2"; }

# ── fixtures ────────────────────────────────────────────────────────────────

SYNC_BASE=$'mihomo:\n  listeners:\n# --- vless-tcp ---\n  - name: vless-tcp\n    type: vless\n    port: 443\n    users:\n      # client-users-start\n      - username: old\n        uuid: old-uuid\n        flow: xtls-rprx-vision\n      # client-users-end\n    proxy: DIRECT\n# --- /vless-tcp ---\n# --- hy2 ---\n  - name: hy2\n    type: hysteria2\n    port: 8443\n    users:\n      # client-users-start\n      old: pw\n      # client-users-end\n    cascade-user-note: keep\n# cascade-user:alpha\n# --- /hy2 ---\n'
SYNC_NO_CLIENT=$'# --- vless-tcp ---\n  - name: x\n    port: 1\n# --- /vless-tcp ---\n'
USERS_TCP=$(printf 'alice u1\nbob u2\n' | _build_vless_users_yaml vless-tcp)
USERS_HY2=$(printf 'bob pw2\n' | _build_hy2_users_yaml)
USERS_CYR=$(printf 'Иван u-1\n' | _build_vless_users_yaml vless-grpc)

UUID='11111111-2222-3333-4444-555555555555'

# ── _uri_percent_encode ─────────────────────────────────────────────────────

c uri _uri_percent_encode pe_alnum '<none>' 'abcXYZ019-._~'
c uri _uri_percent_encode pe_space '<none>' 'a b'
c uri _uri_percent_encode pe_reserved '<none>' 'a#b?c&d=e%f'
c uri _uri_percent_encode pe_cyrillic '<none>' 'Привет'
c uri _uri_percent_encode pe_emoji '<none>' '😀'
c uri _uri_percent_encode pe_empty '<none>' ''
c uri _uri_percent_encode pe_slash_plus '<none>' 'a/b+c:d;e,f'
c uri _uri_percent_encode pe_newline '<none>' $'a\nb'
c uri _uri_percent_encode pe_tab_cr '<none>' $'a\tb\r'
c uri _uri_percent_encode pe_mixed '<none>' 'Сервер 🚀 #1'
c uri _uri_percent_encode pe_brackets '<none>' '[2001:db8::1]'
c uri _uri_percent_encode pe_quotes '<none>' "it's \"q\""
c uri _uri_percent_encode pe_backslash '<none>' 'a\b'
c uri _uri_percent_encode pe_percent_only '<none>' '%'
c uri _uri_percent_encode pe_idn '<none>' 'sni.пример.рф'

# ── _uri_percent_decode ─────────────────────────────────────────────────────

c uri _uri_percent_decode pd_plain '<none>' 'plain-text_1'
c uri _uri_percent_decode pd_space '<none>' 'a%20b'
c uri _uri_percent_decode pd_utf8 '<none>' '%D0%9F%D1%80%D0%B8'
c uri _uri_percent_decode pd_lower '<none>' '%d0%9f'
c uri _uri_percent_decode pd_emoji '<none>' '%F0%9F%98%80'
c uri _uri_percent_decode pd_short '<none>' 'a%2'
c uri _uri_percent_decode pd_bad_hex '<none>' '%ZZ'
c uri _uri_percent_decode pd_nul '<none>' 'a%00b'
c uri _uri_percent_decode pd_lone_percent '<none>' '100%'
c uri _uri_percent_decode pd_double_percent '<none>' '%%41'
c uri _uri_percent_decode pd_reserved '<none>' '%23%3F%26%3D%25'
c uri _uri_percent_decode pd_plus_kept '<none>' 'a+b'
c uri _uri_percent_decode pd_crlf '<none>' 'a%0D%0Ab'
c uri _uri_percent_decode pd_empty '<none>' ''
c uri _uri_percent_decode pd_trailing_one '<none>' 'x%4'
c uri _uri_percent_decode pd_nonhex_second '<none>' '%4G'
c uri _uri_percent_decode pd_slash_query '<none>' '%2F%3Fq%3D1'
c uri _uri_percent_decode pd_invalid_utf8 '<none>' '%FF%FE'

# ── _parse_server_port_from_uri (sets URI_SERVER/URI_PORT) ──────────────────

ps ps_vless_basic 'vless://uuid-1@example.com:443?x=1#f'
ps ps_hy2 'hy2://pw@1.2.3.4:8443'
ps ps_hysteria2 'hysteria2://pw@h.example:9443?insecure=1#n'
ps ps_ipv6_bracketed 'vless://u@[2001:db8::1]:443?x=1'
ps ps_no_port 'vless://u@host?x=1'
ps ps_no_query 'hy2://pw@host.example:1'
ps ps_fragment_colons 'vless://u@a.b:444#name:with:colons'
ps ps_at_in_fragment 'hy2://p@h:5#x@y'
ps ps_colon_in_query 'vless://u@h.example:443?sni=a:b'
ps ps_no_scheme 'example.com:443'
ps ps_empty ''
ps ps_crlf $'hy2://p@h:443\r'
ps ps_multi_at 'vless://u@x@h:1'
ps ps_zero_port 'vless://u@h:0'

# ── _parse_vless_uri_to_exit ────────────────────────────────────────────────

c uri _parse_vless_uri_to_exit vl_tcp_reality_full '<none>' 'proxy' "vless://${UUID}@exit.example.com:443?encryption=none&flow=xtls-rprx-direct&security=reality&sni=www.microsoft.com&fp=safari&pbk=PUBKEY&sid=abcd&type=tcp#frag"
c uri _parse_vless_uri_to_exit vl_tcp_default_flow '<none>' 'p' 'vless://u@h:443?security=reality&sni=s&pbk=k&sid=s&type=tcp'
c uri _parse_vless_uri_to_exit vl_no_query '<none>' 'p' 'vless://u@h.example:443'
c uri _parse_vless_uri_to_exit vl_tcp_cyr_sni '<none>' 'p' 'vless://u@h:443?sni=%D0%9F%D1%80%D0%B8%D0%BC%D0%B5%D1%80&type=tcp'
c uri _parse_vless_uri_to_exit vl_xhttp_reality_path '<none>' 'p' 'vless://u@h:443?type=xhttp&path=%2Fapi%2Fv1%3Fx%3D1&mode=packet-up&security=reality&sni=s&pbk=k&sid=s&fp=chrome'
c uri _parse_vless_uri_to_exit vl_xhttp_tls_default '<none>' 'p' 'vless://u@h:443?type=xhttp&security=tls&sni=s'
c uri _parse_vless_uri_to_exit vl_xhttp_mode_default '<none>' 'p' 'vless://u@h:443?type=xhttp&security=tls'
c uri _parse_vless_uri_to_exit vl_grpc_space '<none>' 'p' 'vless://u@h:443?type=grpc&serviceName=my%20svc&security=reality&pbk=k&sid=s'
c uri _parse_vless_uri_to_exit vl_grpc_default_service '<none>' 'p' 'vless://u@h:443?type=grpc&pbk=k'
c uri _parse_vless_uri_to_exit vl_unknown_transport '<none>' 'p' 'vless://u@h:443?type=quic'
c uri _parse_vless_uri_to_exit vl_bad_pct_sni '<none>' 'p' 'vless://u@h:443?sni=%ZZ'
c uri _parse_vless_uri_to_exit vl_bad_pct_path_tail '<none>' 'p' 'vless://u@h:443?type=xhttp&path=%2'
c uri _parse_vless_uri_to_exit vl_hash_in_query '<none>' 'p' 'vless://u@h:443?sni=a#b'
c uri _parse_vless_uri_to_exit vl_cr_tail '<none>' 'p' $'vless://u@h:443?type=tcp&fp=chrome\r'
c uri _parse_vless_uri_to_exit vl_ipv6_bracketed '<none>' 'p' 'vless://u@[2001:db8::1]:443?type=tcp'
c uri _parse_vless_uri_to_exit vl_port_8443_colon_frag '<none>' 'p' 'vless://u@h:8443?type=tcp#a:b'
c uri _parse_vless_uri_to_exit vl_empty_uuid '<none>' 'p' 'vless://@h:443?type=tcp'
c uri _parse_vless_uri_to_exit vl_key_without_value '<none>' 'p' 'vless://u@h:443?flag&type=tcp'
c uri _parse_vless_uri_to_exit vl_emoji_service_raw '<none>' 'p' 'vless://u@h:443?type=grpc&serviceName=🚀'
c uri _parse_vless_uri_to_exit vl_repeated_amp '<none>' 'p' 'vless://u@h:443?type=tcp&&sni=s&'
c uri _parse_vless_uri_to_exit vl_empty_sni '<none>' 'p' 'vless://u@h:443?type=tcp&sni='
c uri _parse_vless_uri_to_exit vl_uuid_pct_encoded '<none>' 'p' 'vless://11111111%2D2222%2D3333%2D4444%2D555555555555@h:443?type=tcp'
c uri _parse_vless_uri_to_exit vl_uuid_bad_pct '<none>' 'p' 'vless://u%ZZ@h:443?type=tcp'
c uri _parse_vless_uri_to_exit vl_uuid_truncated_pct '<none>' 'p' 'vless://u%2@h:443?type=tcp'
c uri _parse_vless_uri_to_exit vl_uuid_nul '<none>' 'p' 'vless://u%00@h:443?type=tcp'
c uri _parse_vless_uri_to_exit vl_grpc_service_quote '<none>' 'p' 'vless://u@h:443?type=grpc&serviceName=a%22b%5Cc'
c uri _parse_vless_uri_to_exit vl_xhttp_path_quote '<none>' 'p' 'vless://u@h:443?type=xhttp&path=%2Fa%22b%5Cc'
c uri _parse_vless_uri_to_exit vl_ipv6_any_default_sni '<none>' 'p' 'vless://u@[::]:443?type=tcp'
c uri _parse_vless_uri_to_exit vl_sni_quote '<none>' 'p' 'vless://u@h:443?type=grpc&sni=a%22b%5Cc%20%23x'

# ── _parse_hy2_uri_to_exit ──────────────────────────────────────────────────

c uri _parse_hy2_uri_to_exit hp_full '<none>' 'hy2-exit' 'hysteria2://PASS-1@exit.example.com:443?insecure=1&sni=cdn.example.org&obfs=salamander&obfs-password=OBFS%23PW'
c uri _parse_hy2_uri_to_exit hp_default_sni '<none>' 'hy2-exit' 'hy2://pw@h:443'
c uri _parse_hy2_uri_to_exit hp_insecure_0 '<none>' 'p' 'hy2://pw@h:443?insecure=0&sni=s'
c uri _parse_hy2_uri_to_exit hp_insecure_true '<none>' 'p' 'hy2://pw@h:443?insecure=true'
c uri _parse_hy2_uri_to_exit hp_obfs_empty '<none>' 'p' 'hy2://pw@h:443?obfs-password='
c uri _parse_hy2_uri_to_exit hp_obfs_pct '<none>' 'p' 'hy2://pw@h:443?obfs-password=a%23b%26c'
c uri _parse_hy2_uri_to_exit hp_cyr_sni '<none>' 'p' 'hy2://pw@h:443?sni=%D0%9F%D1%80%D0%B8%D0%BC%D0%B5%D1%80.%D1%80%D1%84&insecure=1'
c uri _parse_hy2_uri_to_exit hp_bad_pct '<none>' 'p' 'hy2://pw@h:443?sni=%G0'
c uri _parse_hy2_uri_to_exit hp_ipv6_bracketed '<none>' 'p' 'hy2://pw@[2001:db8::1]:443?insecure=1'
c uri _parse_hy2_uri_to_exit hp_port_65535 '<none>' 'p' 'hy2://pw@h:65535'
c uri _parse_hy2_uri_to_exit hp_userinfo_colon '<none>' 'p' 'hy2://user:pass@h:443'
c uri _parse_hy2_uri_to_exit hp_cr_tail '<none>' 'p' $'hy2://pw@h:443?insecure=1\r'
c uri _parse_hy2_uri_to_exit hp_empty_after_scheme '<none>' 'p' 'hy2://'
c uri _parse_hy2_uri_to_exit hp_fragment_ignored '<none>' 'p' 'hy2://pw@h:443#my-node'
c uri _parse_hy2_uri_to_exit hp_emoji_pass '<none>' 'p' 'hy2://🔑@h:443'
c uri _parse_hy2_uri_to_exit hp_no_port '<none>' 'p' 'hy2://pw@h'
c uri _parse_hy2_uri_to_exit hp_hysteria2_pct_pass '<none>' 'p' 'hysteria2://a%20b@h:443'
c uri _parse_hy2_uri_to_exit hp_pass_yaml_special '<none>' 'p' 'hy2://%2A%20a%20%23b%22%5C@h:443?obfs-password=-%20o%20%23x'

# ── _parse_proxy_uri (reads one line from stdin) ───────────────────────────

c uri _parse_proxy_uri pp_vless $'vless://u@h.example:443?type=tcp&pbk=PK&sid=ab&flow=xtls-rprx-vision#n\n' 'proxy-a'
c uri _parse_proxy_uri pp_hy2 $'hysteria2://pw@h:8443?insecure=1&sni=x#n\n' 'hy2-b'
c uri _parse_proxy_uri pp_hy2_crlf $'hy2://pw@h:443?insecure=1\r\n' 'hy2-c'
c uri _parse_proxy_uri pp_unknown_scheme $'https://example.com\n' 'p'
c uri _parse_proxy_uri pp_empty_line $'\n' 'p'
c uri _parse_proxy_uri pp_no_newline 'vless://u@h:443' 'p'
c uri _parse_proxy_uri pp_vless_xhttp $'vless://u@h:443?type=xhttp&path=%2F&mode=packet-up\n' 'x'
c uri _parse_proxy_uri pp_bad_pct $'vless://u@h:443?sni=%G1\n' 'p'
c uri _parse_proxy_uri pp_grpc $'vless://u@h:443?type=grpc&serviceName=s\n' 'p'
c uri _parse_proxy_uri pp_unknown_transport $'vless://u@h:443?type=quic\n' 'p'

# ── hy2 builders ────────────────────────────────────────────────────────────

c hy2 _build_hy2_listener_yaml hl_basic '<none>' 'hy2-main' 443 alice secret DIRECT
c hy2 _build_hy2_listener_yaml hl_obfs '<none>' 'hy2-main' 443 alice secret DIRECT 'obfs-pw'
c hy2 _build_hy2_listener_yaml hl_obfs_explicit_empty '<none>' 'hy2-main' 443 alice secret DIRECT ''
c hy2 _build_hy2_listener_yaml hl_port_custom '<none>' 'hy2-x' 8443 bob pw proxy-a
c hy2 _build_hy2_listener_yaml hl_special_pass '<none>' 'hy2' 443 u 'p a$s#?&=%Ж😀' DIRECT
c hy2 _build_hy2_listener_yaml hl_user_space '<none>' 'hy2' 443 'john doe' pw DIRECT
c hy2 _build_hy2_listener_yaml hl_missing_proxy '<none>' 'hy2' 443 u p
c hy2 _build_hy2_listener_yaml hl_missing_user '<none>' 'hy2' 443 '' p DIRECT
c hy2 _build_hy2_listener_yaml hl_cr_pass '<none>' 'hy2' 443 u $'p\r' DIRECT
c hy2 _build_hy2_listener_yaml hl_obfs_amp '<none>' 'hy2' 443 u p DIRECT 'o&b=fs'
c hy2 _build_hy2_listener_yaml hl_cyr_name '<none>' 'Выход-1' 443 u p DIRECT
c hy2 _build_hy2_listener_yaml hl_quote_backslash_pass '<none>' 'hy2' 443 u 'a"b\c' DIRECT 'o"\#'
c hy2 _build_hy2_listener_yaml hl_newline_pass '<none>' 'hy2' 443 u $'a\nb' DIRECT

c hy2 _build_hy2_client_yaml hc_defaults '<none>' 'hy2-exit' 'exit.example.com' 443 pw
c hy2 _build_hy2_client_yaml hc_full '<none>' 'hy2-exit' 'exit.example.com' 443 pw 'cdn.example.org' false 'salt'
c hy2 _build_hy2_client_yaml hc_skip_true '<none>' 'hy2-exit' 'exit.example.com' 443 pw 'a.b' true
c hy2 _build_hy2_client_yaml hc_ipv6_server '<none>' 'v6' '2001:db8::1' 443 pw
c hy2 _build_hy2_client_yaml hc_name_special '<none>' 'Выход 🚀 "q"' 'h.example' 8443 pw
c hy2 _build_hy2_client_yaml hc_empty_sni_default '<none>' 'x' 'h.example' 443 pw '' true
c hy2 _build_hy2_client_yaml hc_pass_special '<none>' 'x' 'h' 1 'p#q?r&s=t%u'
c hy2 _build_hy2_client_yaml hc_port_max '<none>' 'x' 'h' 65535 pw
c hy2 _build_hy2_client_yaml hc_empty_obfs '<none>' 'x' 'h' 443 pw www.google.de true ''
c hy2 _build_hy2_client_yaml hc_bracketed_server '<none>' 'v6' '[2001:db8::1]' 443 pw
c hy2 _build_hy2_client_yaml hc_server_trailing_colon '<none>' 'v6' '2001:db8::' 443 pw
c hy2 _build_hy2_client_yaml hc_pass_leading_indicator '<none>' 'x' h 443 '*a #b' www.google.de true '- o "q"'

c hy2 _build_hy2_uri hu_defaults '<none>' pw 'h.example' 443
c hy2 _build_hy2_uri hu_sni '<none>' pw h 443 'sni.example'
c hy2 _build_hy2_uri hu_obfs '<none>' pw h 443 www.google.de 'obfs pw'
c hy2 _build_hy2_uri hu_special_pass '<none>' 'p ass#1?&=%' h 443
c hy2 _build_hy2_uri hu_ipv6 '<none>' pw '[2001:db8::1]' 443
c hy2 _build_hy2_uri hu_cyr_pass '<none>' 'пароль' h 443
c hy2 _build_hy2_uri hu_obfs_amp '<none>' pw h 443 '' 'a&b'
c hy2 _build_hy2_uri hu_port_1 '<none>' pw h 1
c hy2 _build_hy2_uri hu_empty_sni '<none>' pw h 443 ''

c hy2 _build_hy2_exit_yaml hx_defaults '<none>' 'hy2-exit' 'exit.example.com' 443 pw
c hy2 _build_hy2_exit_yaml hx_full '<none>' 'hy2-exit' 'exit.example.com' 443 pw 'cdn.example.org' false 'salt'
c hy2 _build_hy2_exit_yaml hx_skip_false '<none>' 'hy2-exit' 'h' 443 pw 'a.b' false
c hy2 _build_hy2_exit_yaml hx_obfs '<none>' 'hy2-exit' 'h' 443 pw www.google.de true 'obfs'
c hy2 _build_hy2_exit_yaml hx_ipv6 '<none>' 'v6' '2001:db8::1' 443 pw
c hy2 _build_hy2_exit_yaml hx_empty_sni_default '<none>' 'x' 'h' 443 pw '' true
c hy2 _build_hy2_exit_yaml hx_name_cyr '<none>' 'Выход' 'h' 443 pw
c hy2 _build_hy2_exit_yaml hx_pass_special '<none>' 'x' 'h' 443 'p#q?r&s=t%u'
c hy2 _build_hy2_exit_yaml hx_port_min '<none>' 'x' 'h' 1 pw
c hy2 _build_hy2_exit_yaml hx_bracketed_server '<none>' 'v6' '[2001:db8::1]' 443 pw
c hy2 _build_hy2_exit_yaml hx_pass_quote_backslash '<none>' 'x' h 443 'a"b\c' www.google.de true $'o\r\n'

# ── vless-tcp builders ──────────────────────────────────────────────────────

c vless-tcp _build_vless_tcp_listener_yaml tl_basic '<none>' 'vless-tcp' '0.0.0.0' 443 alice "$UUID" 'www.microsoft.com:443' 'PRIVKEY_abc' 'a1b2c3d4' 'www.microsoft.com' DIRECT
c vless-tcp _build_vless_tcp_listener_yaml tl_ipv6_listen '<none>' 'x' '::' 8443 bob "$UUID" 'www.microsoft.com:443' pk sid sni.example DIRECT
c vless-tcp _build_vless_tcp_listener_yaml tl_empty_sid '<none>' 'x' '0.0.0.0' 443 alice "$UUID" 'd:443' pk '' sni.example DIRECT
c vless-tcp _build_vless_tcp_listener_yaml tl_special_user '<none>' 'x' '0.0.0.0' 443 'Иван 😀' "$UUID" 'd:443' pk sid sni.example DIRECT
c vless-tcp _build_vless_tcp_listener_yaml tl_missing_proxy '<none>' 'x' '0.0.0.0' 443 alice "$UUID" 'd:443' pk sid sni.example
c vless-tcp _build_vless_tcp_listener_yaml tl_dest_ipv6 '<none>' 'x' '0.0.0.0' 443 alice "$UUID" '[2001:db8::2]:443' pk sid sni.example DIRECT
c vless-tcp _build_vless_tcp_listener_yaml tl_cyr_sni '<none>' 'x' '0.0.0.0' 443 alice "$UUID" 'd:443' pk sid 'пример.рф' DIRECT
c vless-tcp _build_vless_tcp_listener_yaml tl_cr_pk '<none>' 'x' '0.0.0.0' 443 alice "$UUID" 'd:443' $'pk\r' sid sni.example DIRECT
c vless-tcp _build_vless_tcp_listener_yaml tl_port_2053 '<none>' 'x' '0.0.0.0' 2053 alice "$UUID" 'd:443' pk sid sni.example DIRECT
c vless-tcp _build_vless_tcp_listener_yaml tl_listen_bracketed '<none>' 'x' '[::]' 443 alice "$UUID" 'd:443' pk sid sni.example DIRECT
c vless-tcp _build_vless_tcp_listener_yaml tl_dest_quote '<none>' 'x' '0.0.0.0' 443 alice "$UUID" 'a"b\c:443' pk sid sni.example DIRECT
c vless-tcp _build_vless_tcp_listener_yaml tl_sni_special '<none>' 'x' '0.0.0.0' 443 alice "$UUID" 'd:443' pk sid '::' DIRECT

c vless-tcp _build_vless_tcp_client_yaml tc_basic '<none>' 'vless-exit' 'exit.example.com' 443 "$UUID" 'www.microsoft.com' PUBKEY abcd
c vless-tcp _build_vless_tcp_client_yaml tc_ipv6 '<none>' 'v6' '[2001:db8::1]' 443 "$UUID" sni.example PUBKEY abcd
c vless-tcp _build_vless_tcp_client_yaml tc_empty_sid '<none>' 'x' 'h' 443 "$UUID" sni.example PUBKEY ''
c vless-tcp _build_vless_tcp_client_yaml tc_port_8443 '<none>' 'x' 'h' 8443 "$UUID" sni.example PUBKEY abcd
c vless-tcp _build_vless_tcp_client_yaml tc_name_special '<none>' 'Выход "1" 🚀' 'h' 443 "$UUID" sni.example PUBKEY abcd
c vless-tcp _build_vless_tcp_client_yaml tc_empty_pbk '<none>' 'x' 'h' 443 "$UUID" sni.example '' ''
c vless-tcp _build_vless_tcp_client_yaml tc_sni_cyr '<none>' 'x' 'h' 443 "$UUID" 'пример.рф' PUBKEY abcd
c vless-tcp _build_vless_tcp_client_yaml tc_missing_sid '<none>' 'x' 'h' 443 "$UUID" sni.example PUBKEY
c vless-tcp _build_vless_tcp_client_yaml tc_special_pbk '<none>' 'x' 'h' 443 "$UUID" sni.example 'pk+/=' 'a b'

c vless-tcp _build_vless_tcp_uri tu_default '<none>' "$UUID" 'exit.example.com' 443 sni.example PUBKEY abcd
c vless-tcp _build_vless_tcp_uri tu_fragment_plain '<none>' "$UUID" h 443 sni.example PUBKEY abcd 'Node 1'
c vless-tcp _build_vless_tcp_uri tu_fragment_special '<none>' "$UUID" h 443 sni.example PUBKEY abcd 'a b#c?d&e=f%g'
c vless-tcp _build_vless_tcp_uri tu_fragment_cyr_emoji '<none>' "$UUID" h 443 sni.example PUBKEY abcd 'Выход 🚀'
c vless-tcp _build_vless_tcp_uri tu_empty_fragment '<none>' "$UUID" h 443 sni.example PUBKEY abcd ''
c vless-tcp _build_vless_tcp_uri tu_ipv6 '<none>' "$UUID" '[2001:db8::1]' 443 sni.example PUBKEY abcd
c vless-tcp _build_vless_tcp_uri tu_port_8443 '<none>' "$UUID" h 8443 sni.example PUBKEY abcd
c vless-tcp _build_vless_tcp_uri tu_empty_sid '<none>' "$UUID" h 443 sni.example PUBKEY ''
c vless-tcp _build_vless_tcp_uri tu_sni_special '<none>' "$UUID" h 443 'a&b' PUBKEY abcd

c vless-tcp _build_vless_tcp_exit_yaml te_defaults '<none>' 'x' h 443 "$UUID" sni.example
c vless-tcp _build_vless_tcp_exit_yaml te_reality '<none>' 'x' h 443 "$UUID" sni.example PUBKEY abcd
c vless-tcp _build_vless_tcp_exit_yaml te_flow_empty '<none>' 'x' h 443 "$UUID" sni.example PUBKEY abcd '' chrome
c vless-tcp _build_vless_tcp_exit_yaml te_fp_firefox '<none>' 'x' h 443 "$UUID" sni.example PUBKEY abcd xtls-rprx-vision firefox
c vless-tcp _build_vless_tcp_exit_yaml te_ipv6 '<none>' 'x' '2001:db8::1' 443 "$UUID" sni.example PUBKEY abcd
c vless-tcp _build_vless_tcp_exit_yaml te_special_pbk '<none>' 'x' h 443 "$UUID" sni.example 'pk+/=' 'a b'
c vless-tcp _build_vless_tcp_exit_yaml te_port_8443_flow_other '<none>' 'x' h 8443 "$UUID" sni.example '' '' xtls-rprx-direct
c vless-tcp _build_vless_tcp_exit_yaml te_empty_fp_default '<none>' 'x' h 443 "$UUID" sni.example PUBKEY abcd xtls-rprx-vision ''
c vless-tcp _build_vless_tcp_exit_yaml te_bracketed_server '<none>' 'x' '[2001:db8::1]' 443 "$UUID" sni.example PUBKEY abcd

# ── vless-grpc builders ─────────────────────────────────────────────────────

c vless-grpc _build_vless_grpc_listener_yaml gl_basic '<none>' 'vless-grpc' '0.0.0.0' 443 alice "$UUID" 'grpc' 'www.microsoft.com:443' PRIVKEY abcd sni.example DIRECT
c vless-grpc _build_vless_grpc_listener_yaml gl_ipv6 '<none>' 'x' '::' 443 alice "$UUID" 'grpc' 'd:443' pk sid sni.example DIRECT
c vless-grpc _build_vless_grpc_listener_yaml gl_service_special '<none>' 'x' '0.0.0.0' 443 alice "$UUID" 'my svc/1' 'd:443' pk sid sni.example DIRECT
c vless-grpc _build_vless_grpc_listener_yaml gl_empty_sid '<none>' 'x' '0.0.0.0' 443 alice "$UUID" 'grpc' 'd:443' pk '' sni.example DIRECT
c vless-grpc _build_vless_grpc_listener_yaml gl_missing_proxy '<none>' 'x' '0.0.0.0' 443 alice "$UUID" 'grpc' 'd:443' pk sid sni.example
c vless-grpc _build_vless_grpc_listener_yaml gl_cyr_user '<none>' 'x' '0.0.0.0' 443 'Иван' "$UUID" 'grpc' 'd:443' pk sid sni.example DIRECT
c vless-grpc _build_vless_grpc_listener_yaml gl_pk_cr '<none>' 'x' '0.0.0.0' 443 alice "$UUID" 'grpc' 'd:443' $'pk\r' sid sni.example DIRECT
c vless-grpc _build_vless_grpc_listener_yaml gl_port_2083 '<none>' 'x' '0.0.0.0' 2083 alice "$UUID" 'grpc' 'd:443' pk sid sni.example DIRECT
c vless-grpc _build_vless_grpc_listener_yaml gl_service_quote '<none>' 'x' '[::]' 443 alice "$UUID" 'a"b\c' 'd:443' pk sid sni.example DIRECT

c vless-grpc _build_vless_grpc_client_yaml gc_basic '<none>' 'grpc-exit' 'exit.example.com' 443 "$UUID" sni.example grpc PUBKEY abcd
c vless-grpc _build_vless_grpc_client_yaml gc_ipv6 '<none>' 'v6' '[2001:db8::1]' 443 "$UUID" sni.example grpc PUBKEY abcd
c vless-grpc _build_vless_grpc_client_yaml gc_empty_service '<none>' 'x' h 443 "$UUID" sni.example '' PUBKEY abcd
c vless-grpc _build_vless_grpc_client_yaml gc_service_quote '<none>' 'x' h 443 "$UUID" sni.example 'a"b' PUBKEY abcd
c vless-grpc _build_vless_grpc_client_yaml gc_no_reality '<none>' 'x' h 443 "$UUID" sni.example grpc '' ''
c vless-grpc _build_vless_grpc_client_yaml gc_cyr_name '<none>' 'Выход 1' h 443 "$UUID" sni.example grpc PUBKEY abcd
c vless-grpc _build_vless_grpc_client_yaml gc_port_8443 '<none>' 'x' h 8443 "$UUID" sni.example grpc PUBKEY abcd
c vless-grpc _build_vless_grpc_client_yaml gc_missing_sid '<none>' 'x' h 443 "$UUID" sni.example grpc PUBKEY
c vless-grpc _build_vless_grpc_client_yaml gc_service_backslash '<none>' 'x' h 443 "$UUID" sni.example 'a\b"c' PUBKEY abcd

c vless-grpc _build_vless_grpc_uri gu_default '<none>' "$UUID" h 443 sni.example grpc PUBKEY abcd
c vless-grpc _build_vless_grpc_uri gu_fragment '<none>' "$UUID" h 443 sni.example grpc PUBKEY abcd 'Node 1'
c vless-grpc _build_vless_grpc_uri gu_service_space '<none>' "$UUID" h 443 sni.example 'my svc' PUBKEY abcd
c vless-grpc _build_vless_grpc_uri gu_ipv6 '<none>' "$UUID" '[2001:db8::1]' 443 sni.example grpc PUBKEY abcd
c vless-grpc _build_vless_grpc_uri gu_empty_fragment '<none>' "$UUID" h 443 sni.example grpc PUBKEY abcd ''
c vless-grpc _build_vless_grpc_uri gu_special_sni '<none>' "$UUID" h 443 'a&b' grpc PUBKEY abcd
c vless-grpc _build_vless_grpc_uri gu_emoji_fragment '<none>' "$UUID" h 443 sni.example grpc PUBKEY abcd '🚀 нода'
c vless-grpc _build_vless_grpc_uri gu_port_8443 '<none>' "$UUID" h 8443 sni.example grpc PUBKEY abcd

c vless-grpc _build_vless_grpc_exit_yaml ge_defaults '<none>' 'x' h 443 "$UUID" sni.example grpc
c vless-grpc _build_vless_grpc_exit_yaml ge_reality '<none>' 'x' h 443 "$UUID" sni.example grpc PUBKEY abcd
c vless-grpc _build_vless_grpc_exit_yaml ge_fp_firefox '<none>' 'x' h 443 "$UUID" sni.example grpc PUBKEY abcd firefox
c vless-grpc _build_vless_grpc_exit_yaml ge_pbk_empty_sid_set '<none>' 'x' h 443 "$UUID" sni.example grpc '' abcd
c vless-grpc _build_vless_grpc_exit_yaml ge_ipv6 '<none>' 'x' '2001:db8::1' 443 "$UUID" sni.example grpc
c vless-grpc _build_vless_grpc_exit_yaml ge_special_service '<none>' 'x' h 443 "$UUID" sni.example 'a "b" c' PUBKEY abcd
c vless-grpc _build_vless_grpc_exit_yaml ge_empty_service '<none>' 'x' h 443 "$UUID" sni.example ''
c vless-grpc _build_vless_grpc_exit_yaml ge_port_1 '<none>' 'x' h 1 "$UUID" sni.example grpc
c vless-grpc _build_vless_grpc_exit_yaml ge_bracketed_server_quote '<none>' 'x' '[2001:db8::1]' 443 "$UUID" sni.example 'a"b\c'

# ── vless-xhttp builders ────────────────────────────────────────────────────

c vless-xhttp _build_vless_xhttp_listener_yaml xl_basic '<none>' 'vless-xhttp' '0.0.0.0' 443 alice "$UUID" / 'www.microsoft.com:443' PRIVKEY abcd sni.example DIRECT
c vless-xhttp _build_vless_xhttp_listener_yaml xl_custom_path '<none>' 'x' '0.0.0.0' 443 alice "$UUID" '/api/v1?x=1' 'd:443' pk sid sni.example DIRECT
c vless-xhttp _build_vless_xhttp_listener_yaml xl_ipv6_listen '<none>' 'x' '::' 443 alice "$UUID" / 'd:443' pk sid sni.example DIRECT
c vless-xhttp _build_vless_xhttp_listener_yaml xl_cyr_user '<none>' 'x' '0.0.0.0' 443 'Иван' "$UUID" / 'd:443' pk sid sni.example DIRECT
c vless-xhttp _build_vless_xhttp_listener_yaml xl_missing_proxy '<none>' 'x' '0.0.0.0' 443 alice "$UUID" / 'd:443' pk sid sni.example
c vless-xhttp _build_vless_xhttp_listener_yaml xl_empty_path '<none>' 'x' '0.0.0.0' 443 alice "$UUID" '' 'd:443' pk sid sni.example DIRECT
c vless-xhttp _build_vless_xhttp_listener_yaml xl_port_8443 '<none>' 'x' '0.0.0.0' 8443 alice "$UUID" / 'd:443' pk sid sni.example DIRECT
c vless-xhttp _build_vless_xhttp_listener_yaml xl_pk_cr '<none>' 'x' '0.0.0.0' 443 alice "$UUID" / 'd:443' $'pk\r' sid sni.example DIRECT
c vless-xhttp _build_vless_xhttp_listener_yaml xl_path_quote '<none>' 'x' '[::]' 443 alice "$UUID" '/a"b\c' '[2001:db8::2]:443' pk sid sni.example DIRECT

c vless-xhttp _build_vless_xhttp_nginx_listener_yaml xn_basic '<none>' 'x' '127.0.0.1' 8080 alice "$UUID" / DIRECT
c vless-xhttp _build_vless_xhttp_nginx_listener_yaml xn_ipv6 '<none>' 'x' '::1' 8080 alice "$UUID" / DIRECT
c vless-xhttp _build_vless_xhttp_nginx_listener_yaml xn_path_special '<none>' 'x' '127.0.0.1' 8080 alice "$UUID" '/a b?c=d&e' DIRECT
c vless-xhttp _build_vless_xhttp_nginx_listener_yaml xn_missing_proxy '<none>' 'x' '127.0.0.1' 8080 alice "$UUID" /
c vless-xhttp _build_vless_xhttp_nginx_listener_yaml xn_port_2053 '<none>' 'x' '127.0.0.1' 2053 alice "$UUID" / DIRECT
c vless-xhttp _build_vless_xhttp_nginx_listener_yaml xn_cyr_user '<none>' 'x' '127.0.0.1' 8080 'Иван' "$UUID" / DIRECT
c vless-xhttp _build_vless_xhttp_nginx_listener_yaml xn_empty_user '<none>' 'x' '127.0.0.1' 8080 '' "$UUID" / DIRECT
c vless-xhttp _build_vless_xhttp_nginx_listener_yaml xn_listen_bracketed_quote '<none>' 'x' '[::1]' 8080 alice "$UUID" '/a"b\c' DIRECT

c vless-xhttp _build_vless_xhttp_tls_listener_yaml xt_legacy_9args '<none>' 'x' '0.0.0.0' 443 alice "$UUID" / /etc/cert.pem /etc/key.pem DIRECT
c vless-xhttp _build_vless_xhttp_tls_listener_yaml xt_legacy_8args '<none>' 'x' '0.0.0.0' 443 alice "$UUID" / /etc/cert.pem /etc/key.pem
c vless-xhttp _build_vless_xhttp_tls_listener_yaml xt_7args '<none>' 'x' '0.0.0.0' 443 alice "$UUID" / DIRECT
c vless-xhttp _build_vless_xhttp_tls_listener_yaml xt_ipv6 '<none>' 'x' '::' 443 alice "$UUID" / c k DIRECT
c vless-xhttp _build_vless_xhttp_tls_listener_yaml xt_path_special '<none>' 'x' '0.0.0.0' 443 alice "$UUID" '/p q' c k DIRECT
c vless-xhttp _build_vless_xhttp_tls_listener_yaml xt_port_8443 '<none>' 'x' '0.0.0.0' 8443 alice "$UUID" / c k DIRECT

c vless-xhttp _build_vless_xhttp_client_yaml xc_reality '<none>' 'xh-exit' 'exit.example.com' 443 "$UUID" sni.example / PUBKEY abcd
c vless-xhttp _build_vless_xhttp_client_yaml xc_tls '<none>' 'xh-exit' 'exit.example.com' 443 "$UUID" sni.example /
c vless-xhttp _build_vless_xhttp_client_yaml xc_path_special '<none>' 'x' h 443 "$UUID" sni.example '/a b?c=d&e' PUBKEY abcd
c vless-xhttp _build_vless_xhttp_client_yaml xc_ipv6 '<none>' 'x' '[2001:db8::1]' 443 "$UUID" sni.example / PUBKEY abcd
c vless-xhttp _build_vless_xhttp_client_yaml xc_empty_sid_reality '<none>' 'x' h 443 "$UUID" sni.example / PUBKEY ''
c vless-xhttp _build_vless_xhttp_client_yaml xc_port_8443 '<none>' 'x' h 8443 "$UUID" sni.example / PUBKEY abcd
c vless-xhttp _build_vless_xhttp_client_yaml xc_cyr_sni '<none>' 'x' h 443 "$UUID" 'пример.рф' / PUBKEY abcd
c vless-xhttp _build_vless_xhttp_client_yaml xc_empty_path '<none>' 'x' h 443 "$UUID" sni.example ''
c vless-xhttp _build_vless_xhttp_client_yaml xc_path_quote '<none>' 'x' h 443 "$UUID" sni.example '/a"b\c' PUBKEY abcd

c vless-xhttp _build_vless_xhttp_uri xu_tls_default '<none>' "$UUID" h 443 sni.example /
c vless-xhttp _build_vless_xhttp_uri xu_reality_default_frag '<none>' "$UUID" h 443 sni.example / PUBKEY abcd
c vless-xhttp _build_vless_xhttp_uri xu_reality_frag '<none>' "$UUID" h 443 sni.example / PUBKEY abcd 'Нода 🚀'
c vless-xhttp _build_vless_xhttp_uri xu_path_special '<none>' "$UUID" h 443 sni.example '/p?a=1&b=2%3D' PUBKEY abcd
c vless-xhttp _build_vless_xhttp_uri xu_tls_frag_space '<none>' "$UUID" h 443 sni.example / '' '' 'x y'
c vless-xhttp _build_vless_xhttp_uri xu_ipv6 '<none>' "$UUID" '[2001:db8::1]' 443 sni.example / PUBKEY abcd
c vless-xhttp _build_vless_xhttp_uri xu_empty_path '<none>' "$UUID" h 443 sni.example ''
c vless-xhttp _build_vless_xhttp_uri xu_cyr_sni '<none>' "$UUID" h 443 'пример.рф' / PUBKEY abcd
c vless-xhttp _build_vless_xhttp_uri xu_pbk_no_sid '<none>' "$UUID" h 443 sni.example / PUBKEY ''
c vless-xhttp _build_vless_xhttp_uri xu_port_8443 '<none>' "$UUID" h 8443 sni.example / PUBKEY abcd
c vless-xhttp _build_vless_xhttp_uri xu_empty_sni '<none>' "$UUID" h 443 '' /

c vless-xhttp _build_vless_xhttp_exit_yaml xe_defaults '<none>' 'x' h 443 "$UUID" sni.example /
c vless-xhttp _build_vless_xhttp_exit_yaml xe_packet_up '<none>' 'x' h 443 "$UUID" sni.example / packet-up
c vless-xhttp _build_vless_xhttp_exit_yaml xe_reality '<none>' 'x' h 443 "$UUID" sni.example / auto PUBKEY abcd
c vless-xhttp _build_vless_xhttp_exit_yaml xe_fp_chrome_ignored '<none>' 'x' h 443 "$UUID" sni.example / auto PUBKEY abcd chrome
c vless-xhttp _build_vless_xhttp_exit_yaml xe_ipv6 '<none>' 'x' '2001:db8::1' 443 "$UUID" sni.example /
c vless-xhttp _build_vless_xhttp_exit_yaml xe_path_special '<none>' 'x' h 443 "$UUID" sni.example '/a b?c=d' auto
c vless-xhttp _build_vless_xhttp_exit_yaml xe_empty_mode '<none>' 'x' h 443 "$UUID" sni.example / ''
c vless-xhttp _build_vless_xhttp_exit_yaml xe_port_8443 '<none>' 'x' h 8443 "$UUID" sni.example /
c vless-xhttp _build_vless_xhttp_exit_yaml xe_bracketed_server_quote '<none>' 'x' '[2001:db8::1]' 443 "$UUID" sni.example '/a"b\c'

c vless-xhttp _normalize_vless_xhttp_proxy_yaml nx_chrome_replaced '  - name: n
    type: vless
    network: xhttp
    client-fingerprint: chrome
' 
c vless-xhttp _normalize_vless_xhttp_proxy_yaml nx_no_fp_appended $'  - name: n\n    network: xhttp\n    tls: true\n'
c vless-xhttp _normalize_vless_xhttp_proxy_yaml nx_no_trailing_newline $'  - name: n\n    network: xhttp'
c vless-xhttp _normalize_vless_xhttp_proxy_yaml nx_tcp_passthrough $'  - name: t\n    network: tcp\n    client-fingerprint: chrome\n'
c vless-xhttp _normalize_vless_xhttp_proxy_yaml nx_grpc_passthrough $'  - name: g\n    network: grpc\n    client-fingerprint: chrome\n'
c vless-xhttp _normalize_vless_xhttp_proxy_yaml nx_crlf_passthrough $'  - name: n\r\n    network: xhttp\r\n    client-fingerprint: chrome\r\n'
c vless-xhttp _normalize_vless_xhttp_proxy_yaml nx_empty '<none>'
c vless-xhttp _normalize_vless_xhttp_proxy_yaml nx_fp_spaces $'  - name: n\n    network: xhttp\n    client-fingerprint:   chrome  \n'
c vless-xhttp _normalize_vless_xhttp_proxy_yaml nx_wrong_indent $'  - name: n\n  network: xhttp\n'

# ── iptables-dnat ───────────────────────────────────────────────────────────

dn() { run_case iptables-dnat "$1" "$2" "$3" '<none>' "${@:4}"; }
dn _apply_dnat_rules w_apply_dnat dn_apply_basic 'vless-cascade' 203.0.113.5 443 8443
dn _apply_dnat_rules w_apply_dnat dn_apply_ipv6_remote 'v6' 2001:db8::5 443 8443
dn _apply_dnat_rules w_apply_dnat dn_apply_name_space 'my node' 203.0.113.5 443 8443
dn _apply_dnat_rules w_apply_dnat dn_apply_ports_edge 'edge' 203.0.113.5 65535 1
dn _apply_dnat_rules w_apply_dnat dn_apply_empty_local 'x' 203.0.113.5 443 ''
dn _remove_dnat_rules w_remove_dnat dn_remove_basic 'vless-cascade' 203.0.113.5 443 8443
dn _remove_dnat_rules w_remove_dnat dn_remove_ipv6_remote 'v6' 2001:db8::5 443 8443
dn _remove_dnat_rules w_remove_dnat dn_remove_name_space 'my node' 203.0.113.5 443 8443
dn _remove_dnat_rules w_remove_dnat dn_remove_empty_local 'x' 203.0.113.5 443 ''
dn _persist_dnat_rules w_persist_dnat dn_persist_netfilter_present

# ── listener-users ──────────────────────────────────────────────────────────

c listener-users _build_vless_users_yaml vu_tcp_two $'alice 11111111\nbob 22222222\n' 'vless-tcp'
c listener-users _build_vless_users_yaml vu_grpc $'alice 11111111\nbob 22222222\n' 'vless-grpc'
c listener-users _build_vless_users_yaml vu_xhttp $'alice 11111111\n' 'vless-xhttp'
c listener-users _build_vless_users_yaml vu_skip_invalid $'\nalice u1\n\n  \nbad\n' 'vless-tcp'
c listener-users _build_vless_users_yaml vu_no_input '' 'vless-tcp'
c listener-users _build_vless_users_yaml vu_cr $'alice u1\r\nbob u2\r\n' 'vless-tcp'
c listener-users _build_vless_users_yaml vu_multi_space $'alice  u1\n' 'vless-tcp'
c listener-users _build_vless_users_yaml vu_cyr_name $'Иван u-1\n' 'vless-tcp'
c listener-users _build_vless_users_yaml vu_no_uuid $'lonely\n' 'vless-tcp'
c listener-users _build_vless_users_yaml vu_no_trailing_newline $'alice u1\nbob u2' 'vless-tcp'
c listener-users _build_hy2_users_yaml hu_users_two $'alice p1\nbob p2\n'
c listener-users _build_hy2_users_yaml hu_users_skip $'\nalice p1\n\n  \nbad\n'
c listener-users _build_hy2_users_yaml hu_users_special_pass $'bob p#ss&%\n'
c listener-users _build_hy2_users_yaml hu_users_cr $'alice p1\r\n'
c listener-users _build_hy2_users_yaml hu_users_empty ''
c listener-users _build_hy2_users_yaml hu_users_no_pass $'alice\n'
c listener-users _build_hy2_users_yaml hu_users_tab $'a\tb\n'
c listener-users _build_hy2_users_yaml hu_users_no_trailing_newline $'alice p1\nbob p2'
c listener-users _build_hy2_users_yaml hu_users_quote_backslash $'eve a #"b\\c\nmax -x: y\n'

sync_case sy_vless_tcp_replace vless-tcp "$USERS_TCP" "$SYNC_BASE"
sync_case sy_delete_all vless-tcp '' "$SYNC_BASE"
sync_case sy_hy2_replace hy2 "$USERS_HY2" "$SYNC_BASE"
sync_case sy_marker_missing vless-xhttp "$USERS_TCP" "$SYNC_BASE"
sync_case sy_no_client_block vless-tcp "$USERS_TCP" "$SYNC_NO_CLIENT"
sync_case sy_config_missing vless-tcp "$USERS_TCP" '<none>'
sync_case sy_cyr_user vless-grpc "$USERS_CYR" "$SYNC_BASE"
sync_case sy_repeated_unclosed_users vless-tcp "$USERS_TCP" $'# --- vless-tcp ---\n  - name: x\n    users:\n      # client-users-start\n      # client-users-end\n      # client-users-start\n    proxy: DIRECT\n# --- /vless-tcp ---\ntail: keep\n'
sync_case sy_two_users_blocks vless-tcp "$USERS_TCP" $'# --- vless-tcp ---\n      # client-users-start\n      # client-users-end\n      # client-users-start\n      # client-users-end\n# --- /vless-tcp ---\n'
sync_case sy_stray_end_before_users vless-tcp "$USERS_TCP" $'# --- vless-tcp ---\n      # client-users-end\n      # client-users-start\n      # client-users-end\n# --- /vless-tcp ---\n'

# ── emit one JSON per module ────────────────────────────────────────────────

for m in $MODULES; do
    jq -S --arg module "$m" -s \
        '{module: $module, cases: (sort_by([.function, .case]))}' \
        "$WORK/$m.ndjson" > "$OUT/$m.json" || exit 1
done

echo "wrote $COUNT cases to $OUT ($(echo $MODULES | wc -w | tr -d ' ') module files)"
