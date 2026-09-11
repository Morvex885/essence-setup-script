#!/bin/bash
# ─── Telegram Proxy: remote lifecycle ─────────────────────────────────────────

TELEGRAM_PROXY_REMOTE_DIR="${REMOTE_DIR:-/root/essence-setup}"

# Synchronize the release marker before every remote operation. A missing or
# stale VERSION is a request to upload the complete script set. An SSH error
# remains an error: uploading to an unreachable node would only hide it.
ensure_remote_scripts_current() {
    local remote_version remote_rc
    remote_version=$(ssh_run -- "if [ -f '$TELEGRAM_PROXY_REMOTE_DIR/VERSION' ]; then cat '$TELEGRAM_PROXY_REMOTE_DIR/VERSION'; else printf '%s' '__MISSING_VERSION__'; fi" 2>&1)
    remote_rc=$?
    if (( remote_rc != 0 )); then
        warn "Не удалось проверить версию скриптов на ${NODE_NAME:-нода}."
        return 1
    fi
    remote_version=$(printf '%s' "$remote_version" | tr -d '\r\n')
    if [[ "$remote_version" == "__MISSING_VERSION__" || -z "${CURRENT_VERSION:-}" || "$remote_version" != "$CURRENT_VERSION" ]]; then
        upload_scripts || {
            warn "Не удалось обновить скрипты на ${NODE_NAME:-нода}."
            return 1
        }
    fi
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
        shared:remove-all) args+=(remove-all --force) ;;
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
    for ((src=0; src<count; src++)); do
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
                (( aggregate < 3 )) && aggregate=3
                printf '  %-24s SKIPPED: не установлен\n' "${source_name[$j]:-#${indexes[$j]}}"
                ;;
            4)
                (( aggregate < 4 )) && aggregate=4
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
    local count
    if [[ "${TELEGRAM_PROXY_NODE_SCOPED:-false}" == true ]]; then
        [[ -n "${CURRENT_NODE_INDEX:-}" ]] || return 1
        node_load "$CURRENT_NODE_INDEX"
        return $?
    fi
    count=$(nodes_count)
    (( count > 0 )) || { warn "Нод нет."; return 1; }
    local pick
    read -rp "  Номер ноды: " pick
    [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= count)) || {
        warn "Неверный выбор."
        return 1
    }
    node_load "$pick"
}

_telegram_proxy_remote_pick_multi() {
    if [[ "${TELEGRAM_PROXY_NODE_SCOPED:-false}" == true ]]; then
        [[ -n "${CURRENT_NODE_INDEX:-}" ]] || return 1
        TELEGRAM_PROXY_SELECTED=("$CURRENT_NODE_INDEX")
        return 0
    fi
    local count
    count=$(nodes_count)
    (( count > 0 )) || { warn "Нод нет."; return 1; }
    local -a labels flags
    labels=()
    flags=()
    while IFS= read -r _telegram_proxy_label; do
        [[ -n "$_telegram_proxy_label" ]] || continue
        labels+=("$_telegram_proxy_label")
        flags+=(0)
    done < <(jq_r '.nodes[].name')
    ((${#labels[@]} > 0)) || { warn "Нод нет."; return 1; }
    toggle_select "Выберите ноды Telegram Proxy" labels flags
    TELEGRAM_PROXY_SELECTED=()
    local i
    for ((i=0; i<${#flags[@]}; i++)); do
        [[ "${flags[$i]}" == 1 ]] && TELEGRAM_PROXY_SELECTED+=("$((i + 1))")
    done
    ((${#TELEGRAM_PROXY_SELECTED[@]} > 0)) || {
        warn "Не выбрана ни одна нода."
        return 1
    }
}


_telegram_proxy_remote_confirm_batch() {
    local component="$1" action="$2" idx name list=""
    for idx in "${TELEGRAM_PROXY_SELECTED[@]}"; do
        name=$(jq_r --argjson i "$((idx - 1))" '.nodes[$i].name')
        [[ -n "$list" ]] && list+=", "
        list+="${name:-#$idx}"
    done
    case "$component:$action" in
        mtproto:install)
            confirm_yn "Установить MTProto на нодах: $list? Провайдер должен разрешать TCP/2398." N ;;
        shared:remove-all)
            confirm_yn "Удалить все Telegram Proxy на нодах: $list?" N ;;
        web:update|web:remove|mtproto:remove)
            confirm_yn "Выполнить $component $action на нодах: $list?" N ;;
        *) return 0 ;;
    esac
}

_telegram_proxy_remote_batch_component() {
    local component="$1" action="$2" force=false
    _telegram_proxy_remote_pick_multi || return
    case "$component:$action" in
        mtproto:install|web:update|web:remove|mtproto:remove|shared:remove-all) force=true ;;
    esac
    telegram_proxy_remote_batch "$component" "$action" "$force" "${TELEGRAM_PROXY_SELECTED[@]}"
}

telegram_proxy_remote_menu() {
    local pick component action
    while true; do
        echo ""
        box_top
        box_center "Telegram Proxy"
        box_mid
        box_line " 1) Установить компонент"
        box_line " 2) Перезапустить компонент"
        box_line " 3) Обновить WEB"
        box_line " 4) Удалить компонент"
        box_line " 5) Общий статус"
        box_line " 6) Подключение"
        box_line " 7) Rotate secret"
        box_line " 8) Tag"
        box_line " 9) Диагностика"
        box_line "10) Удалить всё"
        box_bot
        read -rp "  Действие: " pick
        case "$pick" in
            1)
                read -rp "  Компонент (web/mtproto): " component
                case "$component" in
                    web)
                        if ! _telegram_proxy_remote_pick_single ||
                           ! telegram_proxy_remote_single web install false; then
                            warn "Операция WEB завершилась с ошибкой."
                        fi ;;
                    mtproto) _telegram_proxy_remote_batch_component mtproto install ;;
                    *) warn "Неверный компонент." ;;
                esac ;;
            2)
                read -rp "  Компонент (web/mtproto): " component
                case "$component" in
                    web|mtproto)
                        _telegram_proxy_remote_pick_multi || continue
                        telegram_proxy_remote_batch "$component" restart false "${TELEGRAM_PROXY_SELECTED[@]}" ;;
                    *) warn "Неверный компонент." ;;
                esac ;;
            3) _telegram_proxy_remote_batch_component web update ;;
            4)
                read -rp "  Компонент (web/mtproto): " component
                _telegram_proxy_remote_batch_component "$component" remove ;;
            5)
                _telegram_proxy_remote_pick_multi && telegram_proxy_remote_batch shared status false "${TELEGRAM_PROXY_SELECTED[@]}" ;;
            6|7|9)
                _telegram_proxy_remote_pick_single || continue
                case "$pick" in
                    6) telegram_proxy_remote_single shared connection false ;;
                    7) telegram_proxy_remote_single shared rotate-secret true ;;
                    9) telegram_proxy_remote_single shared diagnostics false ;;
                esac ;;
            8)
                _telegram_proxy_remote_pick_single || continue
                read -rp "  Tag (show/set/clear): " action
                case "$action" in
                    show) telegram_proxy_remote_single shared tag-show false ;;
                    set) telegram_proxy_remote_single shared tag-set false ;;
                    clear) telegram_proxy_remote_single shared tag-clear true ;;
                    *) warn "Неверное действие tag." ;;
                esac ;;
            10)
                _telegram_proxy_remote_pick_multi || continue
                _telegram_proxy_remote_confirm_batch shared remove-all || continue
                telegram_proxy_remote_batch shared remove-all true "${TELEGRAM_PROXY_SELECTED[@]}" ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}
