#!/bin/bash
# ─── Telegram Proxy: remote lifecycle ─────────────────────────────────────────

TELEGRAM_PROXY_REMOTE_DIR="${REMOTE_DIR:-/root/essence-setup}"

# Build the exact local script set that upload_scripts transfers. The manifest
# is intentionally kept in memory so no credential-adjacent state is written.
_telegram_proxy_scripts_manifest() {
    local -a sources targets module_sources common_sources protocol_sources
    local source digest old_lc="${LC_ALL-}"
    sources=("$SETUP_DIR/setup-essence.sh" "$VERSION_PATH")
    targets=("setup-essence.sh" "VERSION")
    [[ -r "${sources[0]}" && -f "${sources[0]}" &&
       -r "${sources[1]}" && -f "${sources[1]}" ]] || {
        warn "Не удалось подготовить проверку серверных скриптов." >&2
        return 1
    }
    old_lc="${LC_ALL-}"
    LC_ALL=C
    module_sources=("$SETUP_DIR/modules/"*.sh)
    common_sources=("$COMMON_DIR/"*.sh)
    protocol_sources=("$COMMON_DIR/protocols/"*.sh)
    if [[ -n "$old_lc" ]]; then LC_ALL="$old_lc"; else unset LC_ALL; fi
    ((${#module_sources[@]} > 0 && ${#common_sources[@]} > 0 &&
       ${#protocol_sources[@]} > 0)) || {
        warn "Не удалось подготовить проверку серверных скриптов." >&2
        return 1
    }
    for source in "${module_sources[@]}"; do
        [[ -r "$source" && -f "$source" ]] || {
            warn "Не удалось подготовить проверку серверных скриптов." >&2
            return 1
        }
        sources+=("$source")
        targets+=("modules/$(basename "$source")")
    done
    for source in "${common_sources[@]}"; do
        [[ -r "$source" && -f "$source" ]] || {
            warn "Не удалось подготовить проверку серверных скриптов." >&2
            return 1
        }
        sources+=("$source")
        targets+=("common/$(basename "$source")")
    done
    for source in "${protocol_sources[@]}"; do
        [[ -r "$source" && -f "$source" ]] || {
            warn "Не удалось подготовить проверку серверных скриптов." >&2
            return 1
        }
        sources+=("$source")
        targets+=("common/protocols/$(basename "$source")")
    done
    [[ -r "$SETUP_DIR/modules/telegram-proxy.sh" &&
       -r "$COMMON_DIR/common.sh" && -r "$COMMON_DIR/cert.sh" &&
       -r "$COMMON_DIR/ensure-deps.sh" ]] || {
        warn "Не удалось подготовить проверку серверных скриптов." >&2
        return 1
    }
    for ((source=0; source<${#sources[@]}; source++)); do
        digest=$(_state_hash_file "${sources[$source]}") || {
            warn "Не удалось подготовить проверку серверных скриптов." >&2
            return 1
        }
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
            warn "Не удалось подготовить проверку серверных скриптов." >&2
            return 1
        }
        printf '%s  %s\n' "$digest" "${targets[$source]}"
    done
}

_telegram_proxy_remote_scripts_match() {
    local manifest="${1:-}" root escaped_root command
    [[ -n "$manifest" ]] || return 2
    root="${TELEGRAM_PROXY_REMOTE_DIR:-${REMOTE_DIR:-/root/essence-setup}}"
    escaped_root=$(printf '%s' "$root" | sed "s/'/'\\\\''/g")
    command="if ! command -v sha256sum >/dev/null 2>&1; then exit 2; fi
if ! cd '$escaped_root'; then exit 2; fi
if [ ! -x ./setup-essence.sh ]; then exit 10; fi
if sha256sum --check --status <<'ESSENCE_SCRIPTS_SHA256'
$manifest
ESSENCE_SCRIPTS_SHA256
then
    exit 0
else
    checker_rc=\$?
    if [ \"\$checker_rc\" -eq 1 ]; then exit 10; fi
    exit 2
fi"
    ssh_run -n -- "$command" >/dev/null 2>&1
}

# Read-only gate. Upload authorization belongs exclusively to the UI runner.
ensure_remote_scripts_current() {
    local manifest="${TELEGRAM_PROXY_EXPECTED_MANIFEST:-}" match_rc
    if [[ "${TELEGRAM_PROXY_PREFLIGHT_ACTIVE:-false}" != true || -z "$manifest" ]]; then
        manifest=$(_telegram_proxy_scripts_manifest) || return 1
    fi
    _telegram_proxy_remote_scripts_match "$manifest"
    match_rc=$?
    case "$match_rc" in
        0) return 0 ;;
        10)
            warn "Скрипты на ${NODE_NAME:-нода} отличаются от локальных. Повторите действие из меню Telegram Proxy для согласования обновления."
            ;;
        *)
            warn "Не удалось проверить скрипты на ${NODE_NAME:-нода}."
            ;;
    esac
    return 1
}

# Dispatch the server's nested telegram-proxy grammar. tty is deliberately
# selected only for actions which need hidden prompts/confirmation on the node.
_telegram_proxy_remote_action() {
    local component="${1:-}" action="${2:-}" tty="${3:-false}" force="${4:-false}"
    local -a args
    args=(telegram-proxy)
    case "$component:$action" in
        web:install|web:remove|web:restart|web:update)
            args+=("web" "$action") ;;
        mtproto:install|mtproto:remove|mtproto:restart|mtproto:refresh-ip)
            args+=("mtproto" "$action") ;;
        shared:status) args+=(status --json) ;;
        shared:connection) args+=(connection) ;;
        shared:rotate-secret) args+=(rotate-secret) ;;
        shared:diagnostics) args+=(diagnostics) ;;
        shared:remove-all) args+=(remove-all); force=true ;;
        shared:tag-show) args+=(tag show) ;;
        shared:tag-set) args+=(tag set) ;;
        shared:tag-clear) args+=(tag clear) ;;
        *) return 2 ;;
    esac
    [[ "$force" == true ]] && args+=(--force)
    if [[ "$tty" == true ]]; then
        ssh_run -t -- "$TELEGRAM_PROXY_REMOTE_DIR/setup-essence.sh" "${args[@]}"
    else
        ssh_run -- "$TELEGRAM_PROXY_REMOTE_DIR/setup-essence.sh" "${args[@]}"
    fi
}
_telegram_proxy_remote_action_is_valid() {
    local component="${1:-}" action="${2:-}"
    case "$component:$action" in
        web:install|web:remove|web:restart|web:update|\
        mtproto:install|mtproto:remove|mtproto:restart|mtproto:refresh-ip|\
        shared:status|shared:connection|shared:rotate-secret|shared:diagnostics|\
        shared:remove-all|shared:tag-show|shared:tag-set|shared:tag-clear) return 0 ;;
        *) return 1 ;;
    esac
}

_telegram_proxy_remote_force_allowed() {
    local component="${1:-}" action="${2:-}"
    case "$component:$action" in
        web:install|web:remove|web:update|\
        mtproto:install|mtproto:remove|mtproto:refresh-ip|\
        shared:rotate-secret|shared:remove-all|shared:tag-clear) return 0 ;;
        *) return 1 ;;
    esac
}
telegram_proxy_remote_single() {
    local component="${1:-}" action="${2:-}" force="${3:-false}" tty=false
    _telegram_proxy_remote_action_is_valid "$component" "$action" || {
        warn "Неверное действие Telegram Proxy: $component $action"
        return 2
    }
    if [[ "$force" == true ]] && ! _telegram_proxy_remote_force_allowed "$component" "$action"; then
        warn "--force недоступен для действия $component $action."
        return 2
    fi
    case "$component:$action" in
        web:install|web:update|web:remove|\
        mtproto:install|mtproto:remove|mtproto:refresh-ip|\
        shared:rotate-secret|shared:tag-set|shared:tag-clear|\
        shared:diagnostics)
            tty=true ;;
        web:restart|mtproto:restart|shared:status|shared:tag-show|shared:connection) ;;
    esac
    # Batch actions pass --force after the single confirmation made by the
    # caller; no remote TTY must be allocated for those noninteractive jobs.
    [[ "$force" == true ]] && tty=false
    local sync_log sync_rc
    sync_log=$(umask 077; mktemp) || return 1
    if ensure_remote_scripts_current >"$sync_log" 2>&1; then
        sync_rc=0
    else
        sync_rc=$?
    fi
    if (( sync_rc != 0 )); then
        cat "$sync_log"
        rm -f "$sync_log"
        return "$sync_rc"
    fi
    rm -f "$sync_log"
    local timeout=30
    case "$component:$action" in
        shared:status) timeout=60 ;;
        web:restart|mtproto:restart) timeout=120 ;;
        web:remove|mtproto:remove) timeout=300 ;;
        web:update|mtproto:install) timeout=1200 ;;
    esac
    SSH_RUN_TIMEOUT="$timeout" _telegram_proxy_remote_action "$component" "$action" "$tty" "$force"
}

_telegram_proxy_external_ipv6_usable() {
    [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 && "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == 1 ]] && return 1
    if command -v ip >/dev/null 2>&1; then
        ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 ' && return 0
    fi
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | grep -q 'inet6.*scopeid' && return 0
    fi
    return 1
}

# Probe HTTPS and certificate validity with bounded curl/openssl calls. The
# IPv6 result is deliberately separate: an absent local IPv6 route is not a
# failed WEB endpoint and is reported as UNVERIFIED.
_telegram_proxy_external_probe() {
    local hostname="${1:-}" tls_pid tls_elapsed=0
    TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=NOT_PRESENT
    [[ -n "$hostname" ]] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    curl -4 -fsS --connect-timeout 10 --max-time 20 -o /dev/null "https://${hostname}/" || return 1
    if command -v openssl >/dev/null 2>&1; then
        (printf '' | openssl s_client -4 -connect "${hostname}:443" -servername "$hostname" -verify_return_error) >/dev/null 2>&1 &
        tls_pid=$!
        while kill -0 "$tls_pid" 2>/dev/null; do
            if (( tls_elapsed >= 20 )); then
                kill "$tls_pid" 2>/dev/null || true
                wait "$tls_pid" 2>/dev/null || true
                return 1
            fi
            sleep 1
            tls_elapsed=$((tls_elapsed + 1))
        done
        wait "$tls_pid" 2>/dev/null || return 1
    fi
    if command -v getent >/dev/null 2>&1 && getent ahostsv6 "$hostname" 2>/dev/null | grep -q .; then
        if ! _telegram_proxy_external_ipv6_usable; then
            TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=UNVERIFIED
        else
            curl -6 -fsS --connect-timeout 10 --max-time 20 -o /dev/null "https://${hostname}/" >/dev/null 2>&1 \
                && TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=OK || TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=FAILED
        fi
    fi
}

# A status response is a protocol response, not a stream of log lines. Require
# exactly one JSON object before reading any field, so malformed or noisy
# output is FAILED instead of accidentally being treated as a healthy node.
_telegram_proxy_status_object() {
    command -v jq >/dev/null 2>&1 || return 1
    printf '%s\n' "$1" | jq -e -s -c \
        'if length == 1 and (.[0] | type) == "object" then .[0] else error("expected one JSON object") end' \
        2>/dev/null
}

_telegram_proxy_redact() {
    # Do not write credentials to result files or the batch summary. The final
    # expression also catches raw standalone secrets in otherwise unstructured
    # SSH error output.
    sed -E \
        -e 's/([Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Aa][Gg])([[:space:]]*[:=][[:space:]]*)[[:xdigit:]]{32,34}/\1\2[REDACTED]/g' \
        -e 's/([?&][Ss][Ee][Cc][Rr][Ee][Tt]=)[^&[:space:]]+/\1[REDACTED]/g' \
        -e 's/([?&][Tt][Aa][Gg]=)[^&[:space:]]+/\1[REDACTED]/g' \
        -e 's/([?&](bridge|query|header|credential|token|password|uuid)=)[^&[:space:]]+/\1[REDACTED]/g' \
        -e 's/([Bb][Rr][Ii][Dd][Gg][Ee]|[Qq][Uu][Ee][Rr][Yy]|[Hh][Ee][Aa][Dd][Ee][Rr]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])([[:space:]]*[:=][[:space:]]*)[^,}[:space:]]+/\1\2[REDACTED]/g' \
        -e 's/(^|[^[:xdigit:]])[[:xdigit:]]{32,34}([^[:xdigit:]]|$)/\1[REDACTED]\2/g'
}

_telegram_proxy_status_result() {
    local json="$1" web_enabled mtproto_enabled hostname mtproto_ip degraded=0 reason=""
    web_enabled=$(printf '%s' "$json" | jq -r '.web_enabled // false' 2>/dev/null) || return 1
    mtproto_enabled=$(printf '%s' "$json" | jq -r '.mtproto_enabled // false' 2>/dev/null) || return 1
    [[ "$web_enabled" == true || "$mtproto_enabled" == true ]] || {
        TELEGRAM_PROXY_STATUS_RESULT="1|no enabled component"
        return 0
    }
    if [[ "$web_enabled" == true ]]; then
        hostname=$(printf '%s' "$json" | jq -r '.web_hostname // .hostname // empty' 2>/dev/null)
        if [[ -z "$hostname" ]]; then
            degraded=1
            reason="WEB hostname unavailable"
        elif ! _telegram_proxy_external_probe "$hostname"; then
            degraded=1
            reason="WEB endpoint unavailable"
        elif [[ "${TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS:-NOT_PRESENT}" == UNVERIFIED ]]; then
            reason="UNVERIFIED IPv6"
        fi
    fi
    if [[ "$mtproto_enabled" == true ]]; then
        mtproto_ip=$(printf '%s' "$json" | jq -r '.mtproto_ipv4 // .mtproto_ip // empty' 2>/dev/null)
        if [[ -z "$mtproto_ip" ]] || ! _telegram_proxy_mtproto_probe "$mtproto_ip"; then
            degraded=1
            [[ -n "$reason" ]] || reason="MTProto endpoint unavailable"
        fi
    fi
    if (( degraded )); then
        TELEGRAM_PROXY_STATUS_RESULT="4|${reason:-endpoint unavailable}"
    elif [[ -n "$reason" ]]; then
        TELEGRAM_PROXY_STATUS_RESULT="0|$reason"
    else
        TELEGRAM_PROXY_STATUS_RESULT="0"
    fi
}

_telegram_proxy_remote_worker_body() {
    local slot="${1:-}" source_index="${2:-}" component="${3:-}" action="${4:-}"
    local force="${5:-false}" result_file="${6:-}" output_file="${7:-}"
    local raw_file="${output_file}.raw" rc_file="${output_file}.rc" action_pid=""
    umask 077
    _telegram_proxy_remote_worker_abort() {
        [[ -n "$action_pid" ]] && kill "$action_pid" 2>/dev/null || true
        [[ -n "$action_pid" ]] && wait "$action_pid" 2>/dev/null || true
        _cleanup_askpass >/dev/null 2>&1 || true
        rm -f "$raw_file" "$rc_file"
        printf '%s\n' 130 > "$result_file"
        : > "$result_file.done"
        exit 130
    }
    trap '_telegram_proxy_remote_worker_abort' INT TERM
    local rc=1 out safe_out status_json status_result pipeline_rc
    (
        telegram_proxy_remote_single "$component" "$action" "$force" 2>&1 |
            _telegram_proxy_redact >"$raw_file"
        pipeline_rc="${PIPESTATUS[0]}"
        printf '%s\n' "$pipeline_rc" > "$rc_file"
    ) &
    action_pid=$!
    wait "$action_pid" 2>/dev/null || true
    action_pid=""
    if [[ -r "$rc_file" ]]; then
        IFS= read -r rc < "$rc_file"
    fi
    out=$(cat "$raw_file" 2>/dev/null)
    rm -f "$raw_file" "$rc_file"
    safe_out=$(printf '%s\n' "$out" | _telegram_proxy_redact)
    if [[ "$component:$action" == shared:status && "$rc" == 0 ]]; then
        if ! status_json=$(_telegram_proxy_status_object "$out"); then
            rc=1
        else
            if _telegram_proxy_status_result "$status_json"; then
                status_result="${TELEGRAM_PROXY_STATUS_RESULT:-1|invalid status}"
                printf '%s\n' "$status_result" > "$result_file"
                : > "$result_file.done"
                return 0
            fi
            rc=1
        fi
    fi
    printf '%s\n' "$safe_out" > "$output_file"
    printf '%s\n' "$rc" > "$result_file"
    : > "$result_file.done"
}

# Keep the direct worker entry point isolated under a private umask/trap while
# allowing the persistent FIFO reader to run the body as its active child.
_telegram_proxy_remote_worker() {
    (
        _telegram_proxy_remote_worker_body "$@"
    )
}

_telegram_proxy_b64_encode() {
    printf '%s' "$1" | base64 | tr -d '\r\n'
    printf '\n'
}
_telegram_proxy_b64_decode() {
    local help
    help=$(base64 --help 2>&1)
    if [[ "$help" == *--decode* ]]; then
        base64 --decode
    else
        base64 -D
    fi
}

_telegram_proxy_decode_field() {
    local encoded="$1" variable="$2" tmp value=""
    tmp=$(umask 077; mktemp) || return 1
    if ! printf '%s' "$encoded" | _telegram_proxy_b64_decode > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    IFS= read -r -d '' value < "$tmp" || true
    rm -f "$tmp"
    printf -v "$variable" '%s' "$value"
}

_telegram_proxy_fifo_dispatch_job() {
    local slot="$1" source_index="$2" component="$3" action="$4" force="$5"
    local result_file="$6" output_file="$7" cred_file="$8"
    local encoded variable
    local NODE_NAME SERVER_IP SERVER_PORT SERVER_USER SERVER_PASS SERVER_AUTH NODE_TAG
    local -a values
    while IFS= read -r encoded; do
        values+=("$encoded")
    done < "$cred_file"
    [[ "${#values[@]}" -eq 7 ]] || {
        printf '%s\n' 1 > "$result_file"
        return 1
    }
    _telegram_proxy_decode_field "${values[0]}" NODE_NAME &&
    _telegram_proxy_decode_field "${values[1]}" SERVER_IP &&
    _telegram_proxy_decode_field "${values[2]}" SERVER_PORT &&
    _telegram_proxy_decode_field "${values[3]}" SERVER_USER &&
    _telegram_proxy_decode_field "${values[4]}" SERVER_PASS &&
    _telegram_proxy_decode_field "${values[5]}" SERVER_AUTH &&
    _telegram_proxy_decode_field "${values[6]}" NODE_TAG || {
        printf '%s\n' 1 > "$result_file"
        return 1
    }
    NODE_NAME="$NODE_NAME" SERVER_IP="$SERVER_IP" SERVER_PORT="$SERVER_PORT" \
    SERVER_USER="$SERVER_USER" SERVER_PASS="$SERVER_PASS" SERVER_AUTH="$SERVER_AUTH" \
    NODE_TAG="$NODE_TAG" CURRENT_VERSION="${CURRENT_VERSION:-}" \
    _telegram_proxy_remote_worker_body "$slot" "$source_index" "$component" "$action" \
        "$force" "$result_file" "$output_file"
}

# Bash read buffers make several concurrent readers on one FIFO steal bytes
# from one another (records become corrupted on Bash 3.2). Keep one FIFO
# dispatcher for framing and use four independent active worker slots instead.
_telegram_proxy_fifo_dispatcher() {
    local fifo="$1" dir="$2"
    local source_index component action force result_file output_file cred_file
    local slot read_rc wait_pid wait_rc
    local -a slot_pid slot_source
    exec 7< "$fifo" || return 1
    exec 9>&-
    _telegram_proxy_fifo_dispatcher_abort() {
        local pid
        for pid in "${slot_pid[@]}"; do
            [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
        done
        for pid in "${slot_pid[@]}"; do
            [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
        done
        exec 7<&- 2>/dev/null || true
        _cleanup_askpass >/dev/null 2>&1 || true
        exit 130
    }
    _telegram_proxy_fifo_reap_finished() {
        local i pid rc
        for ((i=0; i<4; i++)); do
            pid="${slot_pid[$i]:-}"
            [[ -n "$pid" ]] || continue
            rc=0
            if ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null || rc=$?
                [[ -s "$dir/r${slot_source[$i]}" ]] ||
                    printf '%s\n' "$rc" > "$dir/r${slot_source[$i]}"
                unset "slot_pid[$i]" "slot_source[$i]"
                return 0
            fi
        done
        return 1
    }
    trap '_telegram_proxy_fifo_dispatcher_abort' INT TERM
    while true; do
        _telegram_proxy_fifo_reap_finished && continue
        slot=0
        while [[ -n "${slot_pid[$slot]:-}" && "$slot" -lt 4 ]]; do slot=$((slot + 1)); done
        if (( slot >= 4 )); then
            sleep 0.05
            continue
        fi
        IFS=$'\t' read -r source_index component action force result_file output_file cred_file <&7
        read_rc=$?
        if (( read_rc != 0 )); then break; fi
        [[ -n "$source_index" ]] || continue
        (
            umask 077
            _telegram_proxy_fifo_dispatch_job "$slot" "$source_index" "$component" "$action" \
                "$force" "$result_file" "$output_file" "$cred_file"
        ) &
        slot_pid[$slot]=$!
        slot_source[$slot]=$source_index
    done
    for ((slot=0; slot<4; slot++)); do
        [[ -n "${slot_pid[$slot]:-}" ]] || continue
        wait_pid="${slot_pid[$slot]}"
        if wait "$wait_pid" 2>/dev/null; then
            wait_rc=0
        else
            wait_rc=$?
        fi
        [[ -s "$dir/r${slot_source[$slot]}" ]] ||
            printf '%s\n' "${wait_rc:-1}" > "$dir/r${slot_source[$slot]}"
    done
    exec 7<&-
    trap - INT TERM
    return 0
}

# Bounded Bash /dev/tcp probe. Do not use an unbounded connect in the worker:
# an unreachable provider must release its slot after five seconds.
_telegram_proxy_mtproto_probe() {
    local address="$1" pid elapsed=0
    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    (exec 3<>"/dev/tcp/$address/2398"; exec 3>&-) 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if (( elapsed >= 5 )); then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$pid" 2>/dev/null
}

TELEGRAM_PROXY_BATCH_DIR=""
TELEGRAM_PROXY_BATCH_PIDS=""
_telegram_proxy_remote_batch_abort() {
    local pid
    exec 9>&- 2>/dev/null || true
    for pid in $TELEGRAM_PROXY_BATCH_PIDS; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in $TELEGRAM_PROXY_BATCH_PIDS; do
        wait "$pid" 2>/dev/null || true
    done
    [[ -n "$TELEGRAM_PROXY_BATCH_DIR" ]] && rm -rf -- "$TELEGRAM_PROXY_BATCH_DIR"
    TELEGRAM_PROXY_BATCH_DIR=""
    TELEGRAM_PROXY_BATCH_PIDS=""
    trap - INT TERM HUP
    exit 130
}

# FIFO source queue with four independent worker slots. Source indexes are
# never used as slots: a failed node_load consumes no slot, and a freed slot
# can be reused by the next source item without disturbing result ordering.
telegram_proxy_remote_batch() {
    local component="${1:-}" action="${2:-}" force="${3:-false}"
    if (( $# >= 3 )); then shift 3; else shift $#; fi
    local -a indexes
    indexes=("$@")
    local count=${#indexes[@]}
    (( count == 0 )) && return 0
    _telegram_proxy_remote_action_is_valid "$component" "$action" || return 2
    if [[ "$force" == true ]] && ! _telegram_proxy_remote_force_allowed "$component" "$action"; then
        return 2
    fi

    local dir fifo
    dir=$(umask 077; mktemp -d) || return 1
    chmod 700 "$dir" 2>/dev/null || true
    fifo="$dir/jobs"
    mkfifo "$fifo" 2>/dev/null || {
        rm -rf -- "$dir"
        return 1
    }
    chmod 600 "$fifo" 2>/dev/null || true
    TELEGRAM_PROXY_BATCH_DIR="$dir"
    TELEGRAM_PROXY_BATCH_PIDS=""
    trap '_telegram_proxy_remote_batch_abort' INT TERM HUP

    local -a source_name source_ip source_port source_user source_pass source_auth source_tag
    local -a source_queued results outputs worker_pids
    local src idx load_rc load_output cred_file slot worker_count line rc code reason j aggregate=0
    local preflight_pos preflight_code
    for ((src=0; src<count; src++)); do
        idx="${indexes[$src]}"
        preflight_pos=-1
        if [[ "${TELEGRAM_PROXY_PREFLIGHT_ACTIVE:-false}" == true ]]; then
            for ((preflight_pos=0; preflight_pos<${#TELEGRAM_PROXY_PREFLIGHT_SOURCE_INDEXES[@]}; preflight_pos++)); do
                [[ "${TELEGRAM_PROXY_PREFLIGHT_SOURCE_INDEXES[$preflight_pos]}" == "$idx" ]] && break
            done
            [[ "$preflight_pos" -lt "${#TELEGRAM_PROXY_PREFLIGHT_SOURCE_INDEXES[@]}" ]] || preflight_pos=-1
        fi
        if (( preflight_pos >= 0 )); then
            preflight_code="${TELEGRAM_PROXY_PREFLIGHT_CODES[$preflight_pos]:-1}"
            if [[ "$preflight_code" != 0 ]]; then
                source_name[$src]="${TELEGRAM_PROXY_PREFLIGHT_NAMES[$preflight_pos]:-#$idx}"
                results[$src]=1
                source_queued[$src]=0
                printf '%s\n' "${TELEGRAM_PROXY_PREFLIGHT_MESSAGES[$preflight_pos]:-Не удалось проверить скрипты; нода не будет обработана.}" > "$dir/o$src"
                continue
            fi
        fi
        idx="${indexes[$src]}"
        NODE_NAME=""; SERVER_IP=""; SERVER_PORT=""; SERVER_USER=""
        SERVER_PASS=""; SERVER_AUTH=""; NODE_TAG=""
        node_load "$idx" > "$dir/l$src" 2>&1
        load_rc=$?
        chmod 600 "$dir/l$src" 2>/dev/null || true
        if (( load_rc != 0 )); then
            source_name[$src]="#$idx"
            load_output=$(cat "$dir/l$src" 2>/dev/null)
            outputs[$src]=$(printf '%s\n' "$load_output" | _telegram_proxy_redact)
            results[$src]=1
            source_queued[$src]=0
            continue
        fi
        source_name[$src]="${NODE_NAME:-#$idx}"
        source_ip[$src]="${SERVER_IP:-}"
        source_port[$src]="${SERVER_PORT:-}"
        source_user[$src]="${SERVER_USER:-}"
        source_pass[$src]="${SERVER_PASS:-}"
        source_auth[$src]="${SERVER_AUTH:-}"
        source_tag[$src]="${NODE_TAG:-}"
        cred_file="$dir/c$src"
        {
            _telegram_proxy_b64_encode "${source_name[$src]}"
            _telegram_proxy_b64_encode "${source_ip[$src]}"
            _telegram_proxy_b64_encode "${source_port[$src]}"
            _telegram_proxy_b64_encode "${source_user[$src]}"
            _telegram_proxy_b64_encode "${source_pass[$src]}"
            _telegram_proxy_b64_encode "${source_auth[$src]}"
            _telegram_proxy_b64_encode "${source_tag[$src]}"
        } > "$cred_file" || {
            rm -rf "$dir"
            return 1
        }
        chmod 600 "$cred_file" 2>/dev/null || true
        source_queued[$src]=1
    done

    worker_count=0
    for ((src=0; src<count; src++)); do
        [[ "${source_queued[$src]:-0}" == 1 ]] && worker_count=$((worker_count + 1))
    done
    if (( worker_count > 0 )); then
        # O_RDWR keeps the producer open while the dispatcher starts, avoiding
        # the classic FIFO open/open deadlock on Bash 3.2.
        exec 9<>"$fifo" || _telegram_proxy_remote_batch_abort
        (
            umask 077
            _telegram_proxy_fifo_dispatcher "$fifo" "$dir"
        ) &
        worker_pids[0]=$!
        TELEGRAM_PROXY_BATCH_PIDS="${TELEGRAM_PROXY_BATCH_PIDS} ${worker_pids[0]}"
        for ((src=0; src<count; src++)); do
            [[ "${source_queued[$src]:-0}" == 1 ]] || continue
            printf '%s\t%s\t%s\t%s\t%s/r%s\t%s/o%s\t%s/c%s\n' \
                "$src" "$component" "$action" "$force" "$dir" "$src" "$dir" "$src" "$dir" "$src" >&9
        done
        exec 9>&-
        if wait "${worker_pids[0]}" 2>/dev/null; then :; else :; fi
        local barrier_wait=0 barrier_limit="${SSH_RUN_TIMEOUT:-120}"
        barrier_limit=$((barrier_limit + 10))
        while (( barrier_wait < barrier_limit )); do
            local complete=0
            for ((src=0; src<count; src++)); do
                [[ "${source_queued[$src]:-0}" != 1 || -e "$dir/r$src.done" ]] &&
                    complete=$((complete + 1))
            done
            (( complete == worker_count )) && break
            sleep 0.1
            barrier_wait=$((barrier_wait + 1))
        done
        for ((src=0; src<count; src++)); do
            if [[ "${source_queued[$src]:-0}" == 1 && ! -e "$dir/r$src.done" ]]; then
                results[$src]=1
                outputs[$src]="worker did not publish a result"
            fi
        done
    fi

    trap - INT TERM HUP
    echo ""
    echo "  Результаты Telegram Proxy:"
    for ((j=0; j<count; j++)); do
        if [[ -z "${results[$j]:-}" && -s "$dir/r$j" ]]; then
            IFS= read -r line < "$dir/r$j"
            results[$j]="$line"
        fi
        if [[ -f "$dir/o$j" ]]; then
            outputs[$j]=$(cat "$dir/o$j" 2>/dev/null)
        else
            outputs[$j]=""
        fi
        rc="${results[$j]:-1}"
        code="${rc%%|*}"
        reason=""
        [[ "$rc" == *"|"* ]] && reason="${rc#*|}"
        case "$code" in
            0)
                if [[ -n "$reason" ]]; then
                    printf '  %-24s OK (%s)\n' "${source_name[$j]:-#${indexes[$j]}}" "$reason"
                else
                    printf '  %-24s OK\n' "${source_name[$j]:-#${indexes[$j]}}"
                fi
                ;;
            3)
                (( aggregate == 0 )) && aggregate=3
                printf '  %-24s SKIPPED: не установлен\n' "${source_name[$j]:-#${indexes[$j]}}"
                ;;
            4)
                (( aggregate == 0 )) && aggregate=4
                printf '  %-24s DEGRADED: %s\n' "${source_name[$j]:-#${indexes[$j]}}" "${reason:-endpoint unavailable}"
                ;;
            *)
                aggregate=1
                printf '  %-24s FAILED: %s\n' "${source_name[$j]:-#${indexes[$j]}}" "$(printf '%s' "${outputs[$j]:-}" | tr '\n' ' ' | cut -c1-120)"
                [[ -n "${outputs[$j]:-}" ]] && printf '%s\n' "${outputs[$j]}"
                ;;
        esac
    done
    rm -rf -- "$dir"
    TELEGRAM_PROXY_BATCH_DIR=""
    TELEGRAM_PROXY_BATCH_PIDS=""
    trap - INT TERM HUP
    return "$aggregate"

}
_telegram_proxy_remote_pick_single() {
    local count choice name address i
    if [[ "${TELEGRAM_PROXY_NODE_SCOPED:-false}" == true ]]; then
        [[ -n "${CURRENT_NODE_INDEX:-}" ]] || return 1
        node_load "$CURRENT_NODE_INDEX"
        return $?
    fi
    count=$(nodes_count)
    if ! [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
        echo ""
        box_top
        box_center "Выбор ноды"
        box_mid
        box_line " Нет нод для выбора" " ${DIM}Нет нод для выбора${NC}"
        menu_item 0 "Отмена" NC
        box_bot
        echo ""
        return 1
    fi
    local -a names addresses
    names=()
    addresses=()
    while IFS=$'\t' read -r name address; do
        names+=("$name")
        addresses+=("$address")
    done < <(jq_r '.nodes[] | "\(.name)\t\(.ip):\(.port)"')
    if ((${#names[@]} == 0)); then
        echo ""
        box_top
        box_center "Выбор ноды"
        box_mid
        box_line " Нет нод для выбора" " ${DIM}Нет нод для выбора${NC}"
        menu_item 0 "Отмена" NC
        box_bot
        echo ""
        return 1
    fi
    while true; do
        echo ""
        box_top
        box_center "Выбор ноды"
        box_mid
        for ((i=0; i<${#names[@]}; i++)); do
            menu_item "$((i + 1))" "${names[$i]}  ${addresses[$i]}" CYAN
        done
        menu_item 0 "Отмена" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите ноду: " choice; then
            return 1
        fi
        choice="${choice%$'\r'}"
        case "$choice" in
            0) return 1 ;;
            *) ;;
        esac
        if menu_index_valid "$choice" "$count"; then
            CURRENT_NODE_INDEX="$choice"
            node_load "$choice"
            return $?
        fi
        warn "Неверный выбор."
    done
}

TELEGRAM_PROXY_COMPONENT=""
_telegram_proxy_remote_component_select() {
    local choice
    TELEGRAM_PROXY_COMPONENT=""
    while true; do
        echo ""
        box_top
        box_center "Компонент Telegram Proxy"
        box_mid
        menu_item w "WEB" CYAN
        menu_item m "MTProto" CYAN
        menu_item 0 "Отмена" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите компонент: " choice; then
            return 1
        fi
        choice="${choice%$'\r'}"
        case "$choice" in
            w|W) TELEGRAM_PROXY_COMPONENT=web; return 0 ;;
            m|M) TELEGRAM_PROXY_COMPONENT=mtproto; return 0 ;;
            0) return 1 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

TELEGRAM_PROXY_SYNC_INDEXES=()
_telegram_proxy_remote_confirm_action() {
    local component="${1:-}" action="${2:-}"
    shift 2 2>/dev/null || true
    local label explanation count index idx name ip port pos code
    local requires_confirm=false
    local -a indexes target_names target_addresses
    indexes=("$@")
    _telegram_proxy_remote_action_is_valid "$component" "$action" || {
        warn "Не удалось подготовить подтверждение Telegram Proxy."
        return 2
    }
    case "$component:$action" in
        web:remove)
            label="Удалить WEB"
            explanation="WEB станет недоступен на выбранных нодах."
            requires_confirm=true ;;
        mtproto:remove)
            label="Удалить MTProto"
            explanation="MTProto станет недоступен на выбранных нодах."
            requires_confirm=true ;;
        shared:rotate-secret)
            label="Сменить секрет подключения"
            explanation="Старые ссылки подключения будут отозваны."
            requires_confirm=true ;;
        shared:tag-clear)
            label="Удалить тег Telegram Proxy"
            explanation="Общий тег WEB и MTProto будет удалён."
            requires_confirm=true ;;
        shared:remove-all)
            label="Удалить всё Telegram Proxy"
            explanation="WEB и MTProto станут недоступны на выбранных нодах."
            requires_confirm=true ;;
        web:install) label="Установить WEB"; explanation="Установить WEB на выбранных нодах." ;;
        web:restart) label="Перезапустить WEB"; explanation="Перезапустить WEB на выбранных нодах." ;;
        web:update) label="Обновить WEB"; explanation="Обновить WEB на выбранных нодах." ;;
        mtproto:install) label="Установить MTProto"; explanation="Установить MTProto на выбранных нодах." ;;
        mtproto:restart) label="Перезапустить MTProto"; explanation="Перезапустить MTProto на выбранных нодах." ;;
        mtproto:refresh-ip) label="Обновить IP-адрес MTProto"; explanation="Обновить IP-адрес MTProto на выбранных нодах." ;;
        shared:status) label="Общий статус"; explanation="Показать общий статус выбранных нод." ;;
        shared:connection) label="Подключение"; explanation="Показать данные подключения выбранных нод." ;;
        shared:tag-show) label="Показать тег"; explanation="Показать тег выбранной ноды." ;;
        shared:tag-set) label="Изменить тег"; explanation="Изменить тег выбранной ноды." ;;
        shared:diagnostics) label="Диагностика"; explanation="Запустить диагностику выбранных нод." ;;
        *) return 2 ;;
    esac
    ((${#indexes[@]} > 0)) || {
        warn "Не удалось подготовить подтверждение Telegram Proxy."
        return 2
    }
    count=$(nodes_count)
    target_names=()
    target_addresses=()
    for index in "${indexes[@]}"; do
        if ! menu_index_valid "$index" "$count"; then
            warn "Не удалось подготовить подтверждение Telegram Proxy."
            return 2
        fi
        idx=$((index - 1))
        if ! name=$(jq_r --argjson i "$idx" '.nodes[$i].name') ||
           ! ip=$(jq_r --argjson i "$idx" '.nodes[$i].ip') ||
           ! port=$(jq_r --argjson i "$idx" '.nodes[$i].port') ||
           [[ -z "$name" || -z "$ip" || -z "$port" ]]; then
            warn "Не удалось подготовить подтверждение Telegram Proxy."
            return 2
        fi
        target_names+=("$name")
        target_addresses+=("$ip:$port")
    done
    ((${#TELEGRAM_PROXY_SYNC_INDEXES[@]} > 0)) && requires_confirm=true
    [[ "$requires_confirm" == true ]] || return 0

    echo ""
    box_top
    box_center "Подтверждение действия"
    box_mid
    box_line "$label" " ${RED}${label}${NC}"
    box_line "$explanation"
    box_mid
    for ((idx=0; idx<${#target_names[@]}; idx++)); do
        box_line " ${target_names[$idx]}  ${target_addresses[$idx]}"
    done
    if [[ "${TELEGRAM_PROXY_PREFLIGHT_ACTIVE:-false}" == true ]]; then
        local failed_count=0
        for ((pos=0; pos<${#TELEGRAM_PROXY_PREFLIGHT_CODES[@]}; pos++)); do
            code="${TELEGRAM_PROXY_PREFLIGHT_CODES[$pos]:-1}"
            [[ "$code" == 0 || "$code" == 10 ]] || failed_count=$((failed_count + 1))
        done
        if (( failed_count > 0 )); then
            box_mid
            box_line " Не будут обработаны:" " ${YELLOW}Не будут обработаны:${NC}"
            for ((pos=0; pos<${#TELEGRAM_PROXY_PREFLIGHT_CODES[@]}; pos++)); do
                code="${TELEGRAM_PROXY_PREFLIGHT_CODES[$pos]:-1}"
                [[ "$code" == 0 || "$code" == 10 ]] && continue
                box_line " ${TELEGRAM_PROXY_PREFLIGHT_NAMES[$pos]:-нода} — ${TELEGRAM_PROXY_PREFLIGHT_MESSAGES[$pos]}"
            done
        fi
    fi
    if ((${#TELEGRAM_PROXY_SYNC_INDEXES[@]} > 0)); then
        box_mid
        box_line " Будут загружены локальные скрипты:" " ${YELLOW}Будут загружены локальные скрипты:${NC}"
        for index in "${TELEGRAM_PROXY_SYNC_INDEXES[@]}"; do
            idx=$((index - 1))
            name=$(jq_r --argjson i "$idx" '.nodes[$i].name') || return 2
            ip=$(jq_r --argjson i "$idx" '.nodes[$i].ip') || return 2
            port=$(jq_r --argjson i "$idx" '.nodes[$i].port') || return 2
            box_line " ${name}  ${ip}:${port}"
        done
        box_line " Ручные изменения и более новая версия серверных скриптов могут быть перезаписаны."
    fi
    box_bot
    echo ""
    confirm_yn "Выполнить действие и указанные изменения?" N
    [[ "$?" -eq 0 ]] && return 0
    return 1
}
_telegram_proxy_remote_run() {
    local mode="${1:-}" component="${2:-}" action="${3:-}" force="${4:-false}"
    shift 4 2>/dev/null || true
    local -a indexes sync_indexes eligible_indexes
    local -a TELEGRAM_PROXY_PREFLIGHT_CODES TELEGRAM_PROXY_PREFLIGHT_NAMES
    local -a TELEGRAM_PROXY_PREFLIGHT_MESSAGES TELEGRAM_PROXY_PREFLIGHT_SOURCE_INDEXES
    local index pos count manifest current_manifest probe_rc load_log
    local name address confirm_rc action_rc
    indexes=("$@")
    case "$mode" in single|batch) ;; *) return 2 ;; esac
    _telegram_proxy_remote_action_is_valid "$component" "$action" || return 2
    if [[ "$force" != true && "$force" != false ]]; then return 2; fi
    if [[ "$force" == true ]] &&
       ! _telegram_proxy_remote_force_allowed "$component" "$action"; then
        return 2
    fi
    count=$(nodes_count)
    if [[ "$mode" == single && ${#indexes[@]} -ne 1 ]] ||
       [[ "$mode" == batch && ${#indexes[@]} -eq 0 ]]; then
        return 2
    fi
    for index in "${indexes[@]}"; do
        menu_index_valid "$index" "$count" || return 2
    done
    manifest=$(_telegram_proxy_scripts_manifest) || return 1
    TELEGRAM_PROXY_EXPECTED_MANIFEST="$manifest"
    TELEGRAM_PROXY_PREFLIGHT_ACTIVE=true
    TELEGRAM_PROXY_PREFLIGHT_SOURCE_INDEXES=("${indexes[@]}")
    TELEGRAM_PROXY_PREFLIGHT_CODES=()
    TELEGRAM_PROXY_PREFLIGHT_NAMES=()
    TELEGRAM_PROXY_PREFLIGHT_MESSAGES=()
    TELEGRAM_PROXY_SYNC_INDEXES=()
    eligible_indexes=()
    for ((pos=0; pos<${#indexes[@]}; pos++)); do
        index="${indexes[$pos]}"
        name=$(jq_r --argjson i "$((index - 1))" '.nodes[$i].name' 2>/dev/null) || name="#$index"
        address=$(jq_r --argjson i "$((index - 1))" '"\(.ip):\(.port)"' 2>/dev/null) || address=""
        TELEGRAM_PROXY_PREFLIGHT_NAMES[$pos]="$name"
        TELEGRAM_PROXY_PREFLIGHT_MESSAGES[$pos]="Не удалось проверить скрипты; нода не будет обработана."
        NODE_NAME=""; SERVER_IP=""; SERVER_PORT=""; SERVER_USER=""
        SERVER_PASS=""; SERVER_AUTH=""; NODE_TAG=""
        load_log=$(umask 077; mktemp) || return 1
        if ! node_load "$index" >"$load_log" 2>&1; then
            rm -f "$load_log"
            TELEGRAM_PROXY_PREFLIGHT_CODES[$pos]=1
            warn "Не удалось проверить скрипты для ${name}${address:+ ($address)}; нода не будет обработана."
            continue
        fi
        rm -f "$load_log"
        name="${NODE_NAME:-$name}"
        address="${SERVER_IP:-${address%:*}}${SERVER_PORT:+:${SERVER_PORT}}"
        TELEGRAM_PROXY_PREFLIGHT_NAMES[$pos]="$name"
        if _telegram_proxy_remote_scripts_match "$manifest" >/dev/null 2>&1; then
            probe_rc=0
        else
            probe_rc=$?
        fi
        case "$probe_rc" in
            0)
                TELEGRAM_PROXY_PREFLIGHT_CODES[$pos]=0
                eligible_indexes+=("$index") ;;
            10)
                TELEGRAM_PROXY_PREFLIGHT_CODES[$pos]=10
                sync_indexes+=("$index")
                TELEGRAM_PROXY_SYNC_INDEXES+=("$index")
                eligible_indexes+=("$index") ;;
            *)
                TELEGRAM_PROXY_PREFLIGHT_CODES[$pos]=1
                warn "Не удалось проверить скрипты для ${name}${address:+ ($address)}; нода не будет обработана."
                ;;
        esac
    done
    if ((${#eligible_indexes[@]} == 0)); then
        if [[ "$mode" == batch ]]; then
            telegram_proxy_remote_batch "$component" "$action" "$force" "${indexes[@]}"
            return $?
        fi
        return 1
    fi
    _telegram_proxy_remote_confirm_action "$component" "$action" "${eligible_indexes[@]}"
    confirm_rc=$?
    case "$confirm_rc" in
        0) ;;
        1) info "Операция отменена."; return 0 ;;
        *) return 1 ;;
    esac
    if ((${#sync_indexes[@]} > 0)); then
        current_manifest=$(_telegram_proxy_scripts_manifest) || return 1
        if [[ "$current_manifest" != "$manifest" ]]; then
            warn "Локальные скрипты изменились после проверки. Повторите действие из меню."
            return 1
        fi
        for index in "${sync_indexes[@]}"; do
            node_load "$index" >/dev/null 2>&1 || {
                warn "Не удалось согласовать скрипты на ${NODE_NAME:-нода}."
                for ((pos=0; pos<${#indexes[@]}; pos++)); do
                    [[ "${indexes[$pos]}" == "$index" ]] || continue
                    TELEGRAM_PROXY_PREFLIGHT_CODES[$pos]=1
                    TELEGRAM_PROXY_PREFLIGHT_MESSAGES[$pos]="Не удалось загрузить или проверить скрипты; нода не будет обработана."
                done
                continue
            }
            if ! upload_scripts >/dev/null 2>&1 ||
               ! _telegram_proxy_remote_scripts_match "$manifest" >/dev/null 2>&1; then
                warn "Не удалось согласовать скрипты на ${NODE_NAME:-нода}."
                for ((pos=0; pos<${#indexes[@]}; pos++)); do
                    [[ "${indexes[$pos]}" == "$index" ]] || continue
                    TELEGRAM_PROXY_PREFLIGHT_CODES[$pos]=1
                    TELEGRAM_PROXY_PREFLIGHT_MESSAGES[$pos]="Не удалось загрузить или проверить скрипты; нода не будет обработана."
                done
            else
                for ((pos=0; pos<${#indexes[@]}; pos++)); do
                    [[ "${indexes[$pos]}" == "$index" ]] || continue
                    TELEGRAM_PROXY_PREFLIGHT_CODES[$pos]=0
                done
            fi
        done
    fi
    if [[ "$mode" == single ]]; then
        index="${indexes[0]}"
        [[ "${TELEGRAM_PROXY_PREFLIGHT_CODES[0]}" == 0 ]] || return 1
        node_load "$index" >/dev/null 2>&1 || return 1
        telegram_proxy_remote_single "$component" "$action" "$force"
        return $?
    fi
    telegram_proxy_remote_batch "$component" "$action" "$force" "${indexes[@]}"
    action_rc=$?
    return "$action_rc"
}

_telegram_proxy_remote_tag_menu() {
    local node_index="${CURRENT_NODE_INDEX:-}" action node_name node_address action_rc
    while true; do
        node_name="${NODE_NAME:-нода}"
        node_address="${SERVER_IP:-}:${SERVER_PORT:-}"
        echo ""
        box_top
        box_center "Тег Telegram Proxy"
        box_line " ${node_name}  ${node_address}"
        box_mid
        menu_item s "Показать тег" CYAN
        menu_item e "Изменить тег" YELLOW
        menu_item d "Удалить тег" RED
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите действие: " action; then
            return 0
        fi
        action="${action%$'\r'}"
        case "$action" in
            0) return 0 ;;
            s|S) action=show ;;
            e|E) action=set ;;
            d|D) action=clear ;;
            *) warn "Неверный выбор."; continue ;;
        esac
        case "$action" in
            show)
                _telegram_proxy_remote_run single shared tag-show false "$node_index"
                action_rc=$?
                ;;
            set)
                _telegram_proxy_remote_run single shared tag-set false "$node_index"
                action_rc=$?
                ;;
            clear)
                _telegram_proxy_remote_run single shared tag-clear true "$node_index"
                action_rc=$?
                ;;
        esac
        (( action_rc == 0 )) ||
            warn "Операция Telegram Proxy завершилась с ошибкой. Повторите действие из меню."
    done
}

_telegram_proxy_remote_pick_multi() {
    TELEGRAM_PROXY_SELECTED=()
    TOGGLE_SELECT_ITEMS=()
    TOGGLE_SELECT_FLAGS=()
    if [[ "${TELEGRAM_PROXY_NODE_SCOPED:-false}" == true ]]; then
        [[ -n "${CURRENT_NODE_INDEX:-}" ]] || return 1
        TELEGRAM_PROXY_SELECTED=("$CURRENT_NODE_INDEX")
        return 0
    fi
    local count
    count=$(nodes_count)
    if ! [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
        echo ""
        box_top
        box_center "Выбор нод Telegram Proxy"
        box_mid
        box_line " Нет нод для выбора" " ${DIM}Нет нод для выбора${NC}"
        menu_item 0 "Отмена" NC
        box_bot
        echo ""
        return 1
    fi
    local -a labels flags
    labels=()
    flags=()
    local name address
    while IFS=$'\t' read -r name address; do
        labels+=("$name  $address")
        flags+=(0)
    done < <(jq_r '.nodes[] | "\(.name)\t\(.ip):\(.port)"')
    if ((${#labels[@]} == 0)); then
        TOGGLE_SELECT_ITEMS=()
        TOGGLE_SELECT_FLAGS=()
        echo ""
        box_top
        box_center "Выбор нод Telegram Proxy"
        box_mid
        box_line " Нет нод для выбора" " ${DIM}Нет нод для выбора${NC}"
        menu_item 0 "Отмена" NC
        box_bot
        echo ""
        return 1
    fi
    TOGGLE_SELECT_ITEMS=("${labels[@]}")
    TOGGLE_SELECT_FLAGS=("${flags[@]}")
    toggle_select "Выберите ноды Telegram Proxy"
    local toggle_rc=$?
    if (( toggle_rc != 0 )); then
        TOGGLE_SELECT_ITEMS=()
        TOGGLE_SELECT_FLAGS=()
        return 1
    fi
    flags=("${TOGGLE_SELECT_FLAGS[@]}")
    TOGGLE_SELECT_ITEMS=()
    TOGGLE_SELECT_FLAGS=()
    local i
    for ((i=0; i<${#flags[@]}; i++)); do
        [[ "${flags[$i]}" == 1 ]] && TELEGRAM_PROXY_SELECTED+=("$((i + 1))")
    done
    ((${#TELEGRAM_PROXY_SELECTED[@]} > 0)) || {
        warn "Не выбрана ни одна нода."
        return 1
    }
}

telegram_proxy_remote_menu() {
    local pick component
    while true; do
        echo ""
        box_top
        box_center "Telegram Proxy"
        box_mid
        menu_item 1 "Установить компонент" GREEN
        menu_item 2 "Перезапустить компонент" YELLOW
        menu_item 3 "Обновить WEB" YELLOW
        menu_item 4 "Удалить компонент" RED
        menu_item 5 "Общий статус" CYAN
        menu_item 6 "Подключение" CYAN
        menu_item 7 "Сменить секрет подключения" RED
        menu_item 8 "Тег Telegram Proxy" CYAN
        menu_item 9 "Диагностика" CYAN
        menu_item 10 "Удалить всё" RED
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите действие: " pick; then
            return 0
        fi
        pick="${pick%$'\r'}"
        case "$pick" in
            0) return 0 ;;
            1)
                _telegram_proxy_remote_component_select || continue
                component="$TELEGRAM_PROXY_COMPONENT"
                if [[ "$component" == web ]]; then
                    _telegram_proxy_remote_pick_single || continue
                    _telegram_proxy_remote_run single web install false "$CURRENT_NODE_INDEX" ||
                        warn "Операция Telegram Proxy завершилась с ошибкой. Повторите действие из меню."
                else
                    _telegram_proxy_remote_batch_component mtproto install
                fi
                ;;
            2)
                _telegram_proxy_remote_component_select || continue
                component="$TELEGRAM_PROXY_COMPONENT"
                _telegram_proxy_remote_pick_multi || continue
                _telegram_proxy_remote_run batch "$component" restart false "${TELEGRAM_PROXY_SELECTED[@]}" ||
                    warn "Операция Telegram Proxy завершилась с ошибкой. Повторите действие из меню."
                ;;
            3) _telegram_proxy_remote_batch_component web update ;;
            4)
                _telegram_proxy_remote_component_select || continue
                component="$TELEGRAM_PROXY_COMPONENT"
                _telegram_proxy_remote_batch_component "$component" remove
                ;;
            5)
                _telegram_proxy_remote_pick_multi || continue
                _telegram_proxy_remote_run batch shared status false "${TELEGRAM_PROXY_SELECTED[@]}" ||
                    warn "Операция Telegram Proxy завершилась с ошибкой. Повторите действие из меню."
                ;;
            6)
                _telegram_proxy_remote_pick_single || continue
                _telegram_proxy_remote_run single shared connection false "$CURRENT_NODE_INDEX" ||
                    warn "Операция Telegram Proxy завершилась с ошибкой. Повторите действие из меню."
                ;;
            7)
                _telegram_proxy_remote_pick_single || continue
                _telegram_proxy_remote_run single shared rotate-secret true "$CURRENT_NODE_INDEX" ||
                    warn "Операция Telegram Proxy завершилась с ошибкой. Повторите действие из меню."
                ;;
            8)
                _telegram_proxy_remote_pick_single || continue
                _telegram_proxy_remote_tag_menu
                ;;
            9)
                _telegram_proxy_remote_pick_single || continue
                _telegram_proxy_remote_run single shared diagnostics false "$CURRENT_NODE_INDEX" ||
                    warn "Операция Telegram Proxy завершилась с ошибкой. Повторите действие из меню."
                ;;
            10)
                _telegram_proxy_remote_pick_multi || continue
                _telegram_proxy_remote_run batch shared remove-all true "${TELEGRAM_PROXY_SELECTED[@]}" ||
                    warn "Операция Telegram Proxy завершилась с ошибкой. Повторите действие из меню."
                ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

_telegram_proxy_remote_batch_component() {
    local component="$1" action="$2" force=false
    _telegram_proxy_remote_pick_multi || return
    case "$component:$action" in
        mtproto:install|web:update|web:remove|mtproto:remove|shared:remove-all) force=true ;;
    esac
    _telegram_proxy_remote_run batch "$component" "$action" "$force" \
        "${TELEGRAM_PROXY_SELECTED[@]}"
}
