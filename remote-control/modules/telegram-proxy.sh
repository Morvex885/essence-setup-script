#!/bin/bash
# ─── Telegram Proxy: remote lifecycle ─────────────────────────────────────────


# core_telegram_menu INDEX — серверное меню Telegram Proxy одной ноды по SSH на
# /dev/tty. Загрузка скриптов — через rc_confirm_gate (отпечаток комплекта и
# VERSION входят в токен). rc 2 удалённой стороны → not_ready.
core_telegram_menu() {
    local index="${1:-}" rc upload_allowed=false fingerprint version
    local NODE_NAME SERVER_IP SERVER_PORT SERVER_USER SERVER_PASS SERVER_AUTH NODE_TAG NODE_ID NODE_IDENTITY
    _telegram_proxy_remote_clear_plan
    if ! menu_index_valid "$index" "$(nodes_count)"; then
        rc_fail usage "Неверный номер ноды: $index."
        return 1
    fi
    if ! _telegram_proxy_remote_preflight "$index"; then
        _telegram_proxy_remote_clear_plan
        rc_fail failed "Предварительная проверка ноды Telegram Proxy не выполнена."
        return 1
    fi
    if [[ "${TELEGRAM_PROXY_PLAN_STATE[0]}" == excluded ]]; then
        rc_fail not_ready "Нода ${TELEGRAM_PROXY_PLAN_NAME[0]} недоступна для меню Telegram Proxy: ${TELEGRAM_PROXY_PLAN_REASON[0]}"
        _telegram_proxy_remote_clear_plan
        return 1
    fi
    if [[ "${TELEGRAM_PROXY_PLAN_STATE[0]}" == upload ]]; then
        _telegram_proxy_remote_plan_lines shared menu || { _telegram_proxy_remote_clear_plan; return 1; }
        CORE_PLAN_LINES=("$TELEGRAM_PROXY_PLAN_LABEL" "${TELEGRAM_PROXY_PLAN_LINES[@]}")
        CORE_PLAN_EXTRA="${TELEGRAM_PROXY_PLAN_FINGERPRINT} ${TELEGRAM_PROXY_PLAN_VERSION}"
        if ! rc_confirm_gate; then
            _telegram_proxy_remote_clear_plan
            return 1
        fi
        upload_allowed=true
    fi
    NODE_NAME="${TELEGRAM_PROXY_PLAN_NAME[0]}"
    SERVER_IP="${TELEGRAM_PROXY_PLAN_IP[0]}"
    SERVER_PORT="${TELEGRAM_PROXY_PLAN_PORT[0]}"
    SERVER_USER="${TELEGRAM_PROXY_PLAN_USER[0]}"
    SERVER_PASS="${TELEGRAM_PROXY_PLAN_PASS[0]}"
    SERVER_AUTH="${TELEGRAM_PROXY_PLAN_AUTH[0]}"
    NODE_TAG="${TELEGRAM_PROXY_PLAN_TAG[0]}"
    NODE_ID="${TELEGRAM_PROXY_PLAN_ID[0]}"
    NODE_IDENTITY="${TELEGRAM_PROXY_PLAN_IDENTITY[0]}"
    fingerprint="$TELEGRAM_PROXY_PLAN_FINGERPRINT"
    version="$TELEGRAM_PROXY_PLAN_VERSION"
    _telegram_proxy_remote_clear_plan
    _rc_tty_run _telegram_proxy_remote_execute_prepared shared menu false "$upload_allowed" "$fingerprint" "$version"
    rc=$?
    case "$rc" in
        0) return 0 ;;
        2) rc_fail not_ready "Скрипты на ноде не поддерживают меню Telegram Proxy: загрузите их принудительно (node upload-scripts --force)." ;;
        *) rc_fail remote_failed "SSH-сессия Telegram Proxy завершилась с ошибкой." ;;
    esac
    return 1
}

_telegram_proxy_remote_action_is_valid() {
    case "${1:-}:${2:-}" in
        web:remove|web:restart|web:update|mtproto:install|mtproto:remove|\
        mtproto:refresh-ip|backend:restart|shared:status|shared:remove-all) return 0 ;;
        *) return 1 ;;
    esac
}

_telegram_proxy_remote_force_allowed() {
    case "${1:-}:${2:-}" in
        mtproto:install|web:remove|mtproto:remove|shared:remove-all) return 0 ;;
        *) return 1 ;;
    esac
}

_telegram_proxy_remote_action() {
    local component="${1:-}" action="${2:-}" force="${3:-false}" entry
    local -a args
    _telegram_proxy_remote_action_is_valid "$component" "$action" || return 2
    [[ "$force" == true || "$force" == false ]] || return 2
    if [[ "$force" == true ]]; then
        _telegram_proxy_remote_force_allowed "$component" "$action" || return 2
    elif _telegram_proxy_remote_force_allowed "$component" "$action"; then
        # Destructive batch handlers must never ask a remote question.
        return 2
    fi
    args=(telegram-proxy)
    case "$component" in
        web|mtproto|backend) args+=("$component" "$action") ;;
        shared)
            args+=("$action")
            [[ "$action" == status ]] && args+=(--json)
            ;;
    esac
    [[ "$force" == true ]] && args+=(--force)
    printf -v entry '%q' "$REMOTE_DIR/setup-essence.sh"
    ssh_run -- "bash $entry ${args[*]}"
}

_telegram_proxy_remote_clear_plan() {
    TELEGRAM_PROXY_PLAN_INDEX=() TELEGRAM_PROXY_PLAN_NAME=()
    TELEGRAM_PROXY_PLAN_IP=() TELEGRAM_PROXY_PLAN_PORT=()
    TELEGRAM_PROXY_PLAN_USER=() TELEGRAM_PROXY_PLAN_PASS=()
    TELEGRAM_PROXY_PLAN_AUTH=() TELEGRAM_PROXY_PLAN_TAG=()
    TELEGRAM_PROXY_PLAN_ID=() TELEGRAM_PROXY_PLAN_IDENTITY=()
    TELEGRAM_PROXY_PLAN_STATE=() TELEGRAM_PROXY_PLAN_REASON=()
    TELEGRAM_PROXY_PLAN_VERSION="" TELEGRAM_PROXY_PLAN_FINGERPRINT=""
}
_telegram_proxy_remote_clear_plan

_telegram_proxy_remote_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

_telegram_proxy_remote_bundle_fingerprint() (
    set -o pipefail
    local file digest common_files
    local -a files
    [[ -f "${VERSION_PATH:-}" && -f "$SETUP_DIR/setup-essence.sh" ]] || return 1
    common_files=$(find "$COMMON_DIR" -type f -name '*.sh') || return 1
    files=("$VERSION_PATH" "$SETUP_DIR/setup-essence.sh" "$SETUP_DIR"/modules/*.sh)
    while IFS= read -r file; do
        [[ -n "$file" ]] && files+=("$file")
    done <<< "$common_files"
    {
        for file in "${files[@]}"; do
            [[ -f "$file" && -r "$file" ]] || exit 1
            digest=$(_telegram_proxy_remote_hash "$file") || exit 1
            digest="${digest%% *}"
            [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || exit 1
            case "$file" in
                "$VERSION_PATH") printf 'VERSION %s\n' "$digest" ;;
                "$SETUP_DIR"/*) printf 'setup-essence/%s %s\n' "${file#"$SETUP_DIR"/}" "$digest" ;;
                "$COMMON_DIR"/*) printf 'common/%s %s\n' "${file#"$COMMON_DIR"/}" "$digest" ;;
            esac
        done
    } | LC_ALL=C sort | _telegram_proxy_remote_hash | {
        IFS= read -r digest || exit 1
        digest="${digest%% *}"
        [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || exit 1
        printf '%s\n' "$digest"
    }
)

_telegram_proxy_remote_preflight() {
    _telegram_proxy_remote_clear_plan
    local version fingerprint index src=0 state reason
    local NODE_NAME SERVER_IP SERVER_PORT SERVER_USER SERVER_PASS SERVER_AUTH NODE_TAG NODE_ID NODE_IDENTITY
    if ! version=$(_remote_scripts_normalize_version "$(cat "${VERSION_PATH:-}" 2>/dev/null)") ||
       ! fingerprint=$(_telegram_proxy_remote_bundle_fingerprint); then
        warn "Не удалось проверить локальный комплект скриптов Telegram Proxy."
        return 1
    fi
    TELEGRAM_PROXY_PLAN_VERSION="$version"
    TELEGRAM_PROXY_PLAN_FINGERPRINT="$fingerprint"
    for index in "$@"; do
        NODE_NAME=""; SERVER_IP=""; SERVER_PORT=""; SERVER_USER=""
        SERVER_PASS=""; SERVER_AUTH=""; NODE_TAG=""; NODE_ID=""; NODE_IDENTITY=""
        state=excluded reason="нода недоступна"
        # node_load and the probe are read-only; discard untrusted diagnostics.
        if node_load "$index" >/dev/null 2>&1; then
            info "Проверка ноды ($((src + 1))/$#): ${NODE_NAME}…"
            if _remote_scripts_probe >/dev/null 2>&1; then
                case "$REMOTE_SCRIPTS_STATE" in
                    missing) state=upload; reason="" ;;
                    ready)
                        state=ready; reason=""
                        _ver_gt "$version" "$REMOTE_SCRIPTS_VERSION" && state=upload
                        ;;
                    *) reason="версия скриптов неизвестна или установка повреждена — загрузите их принудительно: node upload-scripts --force" ;;
                esac
            fi
        else
            info "Проверка ноды ($((src + 1))/$#): #${index}…"
        fi
        TELEGRAM_PROXY_PLAN_INDEX[$src]="$index"
        TELEGRAM_PROXY_PLAN_NAME[$src]="${NODE_NAME:-#$index}"
        TELEGRAM_PROXY_PLAN_IP[$src]="$SERVER_IP"
        TELEGRAM_PROXY_PLAN_PORT[$src]="$SERVER_PORT"
        TELEGRAM_PROXY_PLAN_USER[$src]="$SERVER_USER"
        TELEGRAM_PROXY_PLAN_PASS[$src]="$SERVER_PASS"
        TELEGRAM_PROXY_PLAN_AUTH[$src]="$SERVER_AUTH"
        TELEGRAM_PROXY_PLAN_TAG[$src]="$NODE_TAG"
        TELEGRAM_PROXY_PLAN_ID[$src]="$NODE_ID"
        TELEGRAM_PROXY_PLAN_IDENTITY[$src]="$NODE_IDENTITY"
        TELEGRAM_PROXY_PLAN_STATE[$src]="$state"
        TELEGRAM_PROXY_PLAN_REASON[$src]="$reason"
        [[ "$state" != excluded ]] || warn "Нода «${TELEGRAM_PROXY_PLAN_NAME[$src]}» исключена: ${reason}."
        src=$((src + 1))
    done
    return 0
}

# Builds the review for a prepared preflight plan without prompting:
# TELEGRAM_PROXY_PLAN_LABEL, TELEGRAM_PROXY_PLAN_LINES (explanation, then one
# line per node), TELEGRAM_PROXY_PLAN_NEEDS_CONFIRM (destructive pair or any
# upload) and TELEGRAM_PROXY_PLAN_ELIGIBLE (nodes not excluded). rc 2 on an
# unknown component/action pair.
_telegram_proxy_remote_plan_lines() {
    local component="$1" action="$2" explanation src suffix
    TELEGRAM_PROXY_PLAN_LABEL=""
    TELEGRAM_PROXY_PLAN_LINES=()
    TELEGRAM_PROXY_PLAN_NEEDS_CONFIRM=false
    TELEGRAM_PROXY_PLAN_ELIGIBLE=0
    case "$component:$action" in
        mtproto:install)
            TELEGRAM_PROXY_PLAN_LABEL="Включение MTProto Proxy"
            explanation="В межсетевом экране провайдера разрешите TCP/2398 и запретите TCP/8888. Служба MTProxy устанавливается автоматически."
            TELEGRAM_PROXY_PLAN_NEEDS_CONFIRM=true ;;
        web:remove|mtproto:remove)
            [[ "$component" == web ]] && TELEGRAM_PROXY_PLAN_LABEL="Отключение Web Proxy" ||
                TELEGRAM_PROXY_PLAN_LABEL="Отключение MTProto Proxy"
            explanation="Ссылки этого способа перестанут работать. Служба MTProxy будет удалена, если это последний способ доступа."
            TELEGRAM_PROXY_PLAN_NEEDS_CONFIRM=true ;;
        shared:remove-all)
            TELEGRAM_PROXY_PLAN_LABEL="Отключение Telegram Proxy"
            explanation="Web Proxy, MTProto Proxy и служба MTProxy будут удалены. Все ссылки перестанут работать."
            TELEGRAM_PROXY_PLAN_NEEDS_CONFIRM=true ;;
        shared:status) TELEGRAM_PROXY_PLAN_LABEL="Общий статус нод"; explanation="Проверка состояния Telegram Proxy." ;;
        shared:menu) TELEGRAM_PROXY_PLAN_LABEL="Меню Telegram Proxy"; explanation="Открытие серверного меню Telegram Proxy по SSH." ;;
        backend:restart) TELEGRAM_PROXY_PLAN_LABEL="Перезапуск службы MTProxy"; explanation="Подключения Web Proxy и MTProto Proxy будут прерваны." ;;
        web:restart) TELEGRAM_PROXY_PLAN_LABEL="Перезапуск Web Proxy"; explanation="Подключения Web Proxy будут прерваны." ;;
        web:update) TELEGRAM_PROXY_PLAN_LABEL="Обновление Web Proxy"; explanation="Обновление Web Proxy на выбранных нодах." ;;
        mtproto:refresh-ip) TELEGRAM_PROXY_PLAN_LABEL="Обновление IP-адреса MTProto Proxy"; explanation="Обновление адреса MTProto Proxy на выбранных нодах." ;;
        *) return 2 ;;
    esac
    TELEGRAM_PROXY_PLAN_LINES=("$explanation")
    for ((src=0; src<${#TELEGRAM_PROXY_PLAN_INDEX[@]}; src++)); do
        suffix=""
        case "${TELEGRAM_PROXY_PLAN_STATE[$src]}" in
            upload)
                suffix=" — будут загружены скрипты v$TELEGRAM_PROXY_PLAN_VERSION"
                TELEGRAM_PROXY_PLAN_NEEDS_CONFIRM=true
                TELEGRAM_PROXY_PLAN_ELIGIBLE=$((TELEGRAM_PROXY_PLAN_ELIGIBLE + 1)) ;;
            ready) TELEGRAM_PROXY_PLAN_ELIGIBLE=$((TELEGRAM_PROXY_PLAN_ELIGIBLE + 1)) ;;
            excluded) suffix=" — исключена: ${TELEGRAM_PROXY_PLAN_REASON[$src]}" ;;
        esac
        TELEGRAM_PROXY_PLAN_LINES+=("${TELEGRAM_PROXY_PLAN_NAME[$src]}  ${TELEGRAM_PROXY_PLAN_IP[$src]}:${TELEGRAM_PROXY_PLAN_PORT[$src]}$suffix")
    done
    return 0
}

_telegram_proxy_remote_execute_prepared() {
    local component="$1" action="$2" force="$3" upload_allowed="$4" fingerprint="$5" version="$6"
    local current upload_output entry timeout=30
    if ! current=$(_telegram_proxy_remote_bundle_fingerprint) || [[ "$current" != "$fingerprint" ]]; then
        warn "Локальный комплект скриптов изменился после подтверждения; действие на ноде отменено."
        return 1
    fi
    if [[ "$upload_allowed" == true ]]; then
        if ! upload_output=$(upload_scripts 2>&1); then
            printf '%s\n' "$upload_output" | _telegram_proxy_redact >&2
            return 1
        fi
        _remote_scripts_probe && [[ "$REMOTE_SCRIPTS_STATE" == ready && "$REMOTE_SCRIPTS_VERSION" == "$version" ]] || return 1
    fi
    if [[ "$component:$action" == shared:menu ]]; then
        printf -v entry '%q' "$REMOTE_DIR/setup-essence.sh"
        ssh_run -t -- "bash $entry telegram-proxy menu"
        return $?
    fi
    case "$component:$action" in
        shared:status) timeout=60 ;;
        web:restart|backend:restart) timeout=120 ;;
        web:remove|mtproto:remove|shared:remove-all) timeout=300 ;;
        web:update|mtproto:install) timeout=1200 ;;
    esac
    SSH_RUN_TIMEOUT="$timeout" _telegram_proxy_remote_action "$component" "$action" "$force"
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
    local hostname="${1:-}" tls_pid tls_elapsed=0 incomplete=false failed=false
    TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=UNVERIFIED
    [[ -n "$hostname" ]] || return 2
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsS --connect-timeout 10 --max-time 20 -o /dev/null "https://${hostname}/" >/dev/null 2>&1 ||
            failed=true
    else
        incomplete=true
    fi
    if command -v openssl >/dev/null 2>&1; then
        (printf '' | openssl s_client -4 -connect "${hostname}:443" -servername "$hostname" -verify_return_error) >/dev/null 2>&1 &
        tls_pid=$!
        while kill -0 "$tls_pid" 2>/dev/null; do
            if (( tls_elapsed >= 20 )); then
                kill "$tls_pid" 2>/dev/null || true
                wait "$tls_pid" 2>/dev/null || true
                failed=true
                break
            fi
            sleep 1
            tls_elapsed=$((tls_elapsed + 1))
        done
        if (( tls_elapsed < 20 )); then
            wait "$tls_pid" 2>/dev/null || failed=true
        fi
    else
        incomplete=true
    fi
    if command -v getent >/dev/null 2>&1; then
        if getent ahostsv6 "$hostname" 2>/dev/null | grep -q .; then
            if ! _telegram_proxy_external_ipv6_usable || ! command -v curl >/dev/null 2>&1; then
                TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=UNVERIFIED
            elif curl -6 -fsS --connect-timeout 10 --max-time 20 -o /dev/null "https://${hostname}/" >/dev/null 2>&1; then
                TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=OK
            else
                TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=FAILED
                failed=true
            fi
        else
            TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS=NOT_PRESENT
        fi
    fi
    [[ "$failed" == false ]] || return 1
    [[ "$incomplete" == false ]] || return 2
    return 0
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

_telegram_proxy_status_observation() {
    local value
    value=$(printf '%s' "$1" | jq -r --arg key "$2" \
        '.[$key] | if type == "string" then . elif type == "boolean" then tostring else "" end' 2>/dev/null) || return 1
    if [[ ",$3," == *",$value,"* && -n "$value" ]]; then
        printf '%s' "$value"
    else
        printf '%s' "не проверено"
    fi
}

_telegram_proxy_status_human() {
    case "$1" in
        active) printf 'работает' ;;
        inactive) printf 'остановлена' ;;
        failed|FAILED) printf 'ошибка' ;;
        ok|OK) printf 'успешно' ;;
        true) printf 'доступен' ;;
        false) printf 'недоступен' ;;
        current) printf 'актуален' ;;
        changed) printf 'изменился — обновите IP' ;;
        NOT_PRESENT) printf 'отсутствует' ;;
        *) printf 'не проверено' ;;
    esac
}

_telegram_proxy_status_result() {
    local json="$1" server_rc="${2:-0}" flags installed web_enabled mtproto_enabled state
    local backend firewall timer relay health readiness listener ip_state
    local hostname mtproto_ip external_rc=0 degraded=false reason="" unverified=false
    local node_summary external_summary web_external mtproto_external ipv6_status
    TELEGRAM_PROXY_STATUS_RESULT="1|Ошибка протокола статуса"
    TELEGRAM_PROXY_STATUS_SUMMARY=""
    flags=$(printf '%s' "$json" | jq -er '
        if (.installed | type) == "boolean" and
           (.web_enabled | type) == "boolean" and
           (.mtproto_enabled | type) == "boolean" then
            [.installed, .web_enabled, .mtproto_enabled] | map(tostring) | join(" ")
        else error("invalid installation flags") end' 2>/dev/null) || return 1
    read -r installed web_enabled mtproto_enabled <<< "$flags"
    backend=$(_telegram_proxy_status_observation "$json" backend active,inactive,failed)
    firewall=$(_telegram_proxy_status_observation "$json" firewall active,inactive,failed)
    timer=$(_telegram_proxy_status_observation "$json" timer active,inactive,failed)
    if [[ "$server_rc" == 3 ]]; then
        [[ "$installed" == false && "$web_enabled" == false && "$mtproto_enabled" == false ]] || return 1
        TELEGRAM_PROXY_STATUS_RESULT="3|не установлен"
        TELEGRAM_PROXY_STATUS_SUMMARY="Состояние на ноде:
  Служба MTProxy: $(_telegram_proxy_status_human "$backend")
  Межсетевой экран: $(_telegram_proxy_status_human "$firewall")
  Автоматическое обновление: $(_telegram_proxy_status_human "$timer")
  Web Proxy: выключен
  MTProto Proxy: выключен
Внешняя доступность:
  Web Proxy: не проверено (выключен)
  MTProto Proxy: не проверено (выключен)"
        return 0
    fi
    [[ "$server_rc" == 0 && "$installed" == true &&
       ( "$web_enabled" == true || "$mtproto_enabled" == true ) ]] || return 1
    node_summary="Состояние на ноде:
  Служба MTProxy: $(_telegram_proxy_status_human "$backend")
  Межсетевой экран: $(_telegram_proxy_status_human "$firewall")
  Автоматическое обновление: $(_telegram_proxy_status_human "$timer")"
    for state in "$backend" "$firewall" "$timer"; do
        [[ "$state" == inactive || "$state" == failed ]] && degraded=true
        [[ "$state" == 'не проверено' ]] && unverified=true
    done
    if [[ "$web_enabled" == true ]]; then
        relay=$(_telegram_proxy_status_observation "$json" relay active,inactive,failed)
        health=$(_telegram_proxy_status_observation "$json" health ok,failed)
        readiness=$(_telegram_proxy_status_observation "$json" readiness ok,failed)
        node_summary+=$'\n'"  Web Proxy: включён; служба: $(_telegram_proxy_status_human "$relay"); проверка работы: $(_telegram_proxy_status_human "$health"); готовность: $(_telegram_proxy_status_human "$readiness")"
        for state in "$relay" "$health" "$readiness"; do
            [[ "$state" == inactive || "$state" == failed ]] && degraded=true
            [[ "$state" == 'не проверено' ]] && unverified=true
        done
        hostname=$(printf '%s' "$json" | jq -r '.web_hostname // .hostname // empty | if type == "string" then . else "" end')
        if [[ "$hostname" =~ ^[a-zA-Z0-9.-]{1,253}$ ]]; then
            if _telegram_proxy_external_probe "$hostname"; then
                external_rc=0
            else
                external_rc=$?
            fi
            ipv6_status="${TELEGRAM_PROXY_EXTERNAL_IPV6_STATUS:-UNVERIFIED}"
            case "$external_rc" in
                0) web_external="HTTPS/TLS успешно" ;;
                1) web_external="HTTPS/TLS недоступен"; degraded=true ;;
                *) web_external="HTTPS/TLS не проверено"; unverified=true ;;
            esac
            [[ "$ipv6_status" == FAILED ]] && degraded=true
            [[ "$ipv6_status" == UNVERIFIED ]] && unverified=true
        else
            web_external="HTTPS/TLS не проверено"
            ipv6_status=UNVERIFIED
            unverified=true
        fi
        external_summary="  Web Proxy: $web_external; IPv6: $(_telegram_proxy_status_human "$ipv6_status")"
    else
        node_summary+=$'\n'"  Web Proxy: выключен"
        external_summary="  Web Proxy: не проверено (выключен)"
    fi
    if [[ "$mtproto_enabled" == true ]]; then
        listener=$(_telegram_proxy_status_observation "$json" mtproto_listener true,false)
        ip_state=$(_telegram_proxy_status_observation "$json" mtproto_ip_state current,changed,unknown)
        [[ "$ip_state" == unknown ]] && ip_state="не проверено"
        node_summary+=$'\n'"  MTProto Proxy: включён; приём подключений: $(_telegram_proxy_status_human "$listener"); IPv4: $(_telegram_proxy_status_human "$ip_state")"
        [[ "$listener" == false || "$ip_state" == changed ]] && degraded=true
        [[ "$listener" == 'не проверено' || "$ip_state" == 'не проверено' ]] && unverified=true
        mtproto_ip=$(printf '%s' "$json" | jq -r '.mtproto_ipv4 // .mtproto_ip // empty | if type == "string" then . else "" end')
        if [[ "$mtproto_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            if _telegram_proxy_mtproto_probe "$mtproto_ip"; then
                mtproto_external="TCP/2398 успешно"
            else
                mtproto_external="TCP/2398 недоступен"
                degraded=true
            fi
        else
            mtproto_external="TCP/2398 не проверено"
            unverified=true
        fi
        external_summary+=$'\n'"  MTProto Proxy: $mtproto_external"
    else
        node_summary+=$'\n'"  MTProto Proxy: выключен"
        external_summary+=$'\n'"  MTProto Proxy: не проверено (выключен)"
    fi
    TELEGRAM_PROXY_STATUS_SUMMARY="$node_summary"$'\n'"Внешняя доступность:"$'\n'"$external_summary"
    if [[ "$degraded" == true ]]; then
        reason="неисправность на ноде или внешняя недоступность"
        TELEGRAM_PROXY_STATUS_RESULT="4|$reason"
    elif [[ "$unverified" == true ]]; then
        TELEGRAM_PROXY_STATUS_RESULT="0|не проверено: часть проверок не выполнена"
    else
        TELEGRAM_PROXY_STATUS_RESULT="0"
    fi
    if [[ "$unverified" == true && "$degraded" == true ]]; then
        TELEGRAM_PROXY_STATUS_RESULT+="; не проверено: часть проверок не выполнена"
    fi
}

# Статус одной ноды строками журнала; данные — в TELEGRAM_PROXY_RESULT_*.
_telegram_proxy_render_status_panel() {
    local name="$1" address="$2" code="$3" reason="$4" summary="$5" line
    case "$code" in
        0)
            if [[ -n "$reason" ]]; then
                warn "Telegram Proxy ${name}${address:+ ($address)}: успешно ($reason)"
            else
                success "Telegram Proxy ${name}${address:+ ($address)}: успешно"
            fi
            ;;
        3) info "Telegram Proxy ${name}${address:+ ($address)}: пропущено — не установлен" ;;
        4) warn "Telegram Proxy ${name}${address:+ ($address)}: частично — ${reason:-внешняя доступность не подтверждена}" ;;
        *) warn "Telegram Proxy ${name}${address:+ ($address)}: ошибка — ${reason:-не удалось получить статус}" ;;
    esac
    [[ -n "$summary" ]] || return 0
    while IFS= read -r line; do
        printf '    %s\n' "$line"
    done <<< "$summary"
}

# serve игнорирует Ctrl+C на всём дереве пакета. Не заменяем SIG_IGN
# обработчиком отмены; обычный интерактивный вызов остаётся прерываемым.
_telegram_proxy_install_abort_traps() {
    local handler="$1"
    [[ "$(trap -p INT)" == "trap -- '' SIGINT" ]] || trap "$handler" INT
    trap "$handler" TERM
}

_telegram_proxy_remote_worker_body() {
    local slot="${1:-}" source_index="${2:-}" component="${3:-}" action="${4:-}"
    local force="${5:-false}" result_file="${6:-}" output_file="${7:-}"
    local upload_allowed="${8:-false}" fingerprint="${9:-}" version="${10:-}"
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
    _telegram_proxy_install_abort_traps _telegram_proxy_remote_worker_abort
    local rc=1 out safe_out status_json status_result pipeline_rc
    (
        _telegram_proxy_remote_execute_prepared "$component" "$action" "$force" \
            "$upload_allowed" "$fingerprint" "$version" 2>&1 |
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
    if [[ "$component:$action" == shared:status && ( "$rc" == 0 || "$rc" == 3 ) ]]; then
        if status_json=$(_telegram_proxy_status_object "$out") &&
           _telegram_proxy_status_result "$status_json" "$rc"; then
            status_result="${TELEGRAM_PROXY_STATUS_RESULT}"
            printf '%s\n' "$TELEGRAM_PROXY_STATUS_SUMMARY" | _telegram_proxy_redact > "$output_file"
            printf '%s\n' "$status_result" > "$result_file"
            : > "$result_file.done"
            return 0
        fi
        rc=1
        safe_out="Некорректный ответ сервера при запросе статуса Telegram Proxy."
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
    [[ "$encoded" == "$(_telegram_proxy_b64_encode "$value")" ]] || return 1
    printf -v "$variable" '%s' "$value"
}

_telegram_proxy_fifo_dispatch_job() {
    local slot="$1" source_index="$2" component="$3" action="$4" force="$5"
    local result_file="$6" output_file="$7" cred_file="$8"
    local upload_allowed="${9:-false}" fingerprint="${10:-}" version="${11:-}"
    local encoded
    local NODE_NAME SERVER_IP SERVER_PORT SERVER_USER SERVER_PASS SERVER_AUTH NODE_TAG NODE_ID NODE_IDENTITY
    local -a values
    while IFS= read -r encoded; do
        values+=("$encoded")
    done < "$cred_file"
    if [[ "${#values[@]}" -ne 9 ]] ||
       ! _telegram_proxy_decode_field "${values[0]}" NODE_NAME ||
       ! _telegram_proxy_decode_field "${values[1]}" SERVER_IP ||
       ! _telegram_proxy_decode_field "${values[2]}" SERVER_PORT ||
       ! _telegram_proxy_decode_field "${values[3]}" SERVER_USER ||
       ! _telegram_proxy_decode_field "${values[4]}" SERVER_PASS ||
       ! _telegram_proxy_decode_field "${values[5]}" SERVER_AUTH ||
       ! _telegram_proxy_decode_field "${values[6]}" NODE_TAG ||
       ! _telegram_proxy_decode_field "${values[7]}" NODE_ID ||
       ! _telegram_proxy_decode_field "${values[8]}" NODE_IDENTITY; then
        printf '%s\n' "Не удалось прочитать данные ноды для SSH." > "$output_file"
        printf '%s\n' 1 > "$result_file"
        : > "$result_file.done"
        return 1
    fi
    CURRENT_VERSION="${CURRENT_VERSION:-}"
    _telegram_proxy_remote_worker_body "$slot" "$source_index" "$component" "$action" \
        "$force" "$result_file" "$output_file" "$upload_allowed" "$fingerprint" "$version"
}

# Bash read buffers make several concurrent readers on one FIFO steal bytes
# from one another (records become corrupted on Bash 3.2). Keep one FIFO
# dispatcher for framing and use four independent active worker slots instead.
_telegram_proxy_fifo_dispatcher() {
    local fifo="$1" dir="$2"
    local source_index component action force result_file output_file cred_file
    local upload_allowed fingerprint version
    local slot read_rc wait_pid wait_rc
    local -a slot_pid slot_source
    exec 7< "$fifo" || return 1
    exec 9>&-
    _telegram_proxy_remote_clear_plan
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
    _telegram_proxy_install_abort_traps _telegram_proxy_fifo_dispatcher_abort
    while true; do
        _telegram_proxy_fifo_reap_finished && continue
        slot=0
        while [[ -n "${slot_pid[$slot]:-}" && "$slot" -lt 4 ]]; do slot=$((slot + 1)); done
        if (( slot >= 4 )); then
            sleep 0.05
            continue
        fi
        IFS=$'\t' read -r source_index component action force result_file output_file cred_file upload_allowed fingerprint version <&7
        read_rc=$?
        if (( read_rc != 0 )); then break; fi
        [[ -n "$source_index" ]] || continue
        (
            umask 077
            _telegram_proxy_fifo_dispatch_job "$slot" "$source_index" "$component" "$action" \
                "$force" "$result_file" "$output_file" "$cred_file" "$upload_allowed" "$fingerprint" "$version"
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
    (exec 3<>"/dev/tcp/$address/2398" && exec 3>&- && exec 3<&-) 2>/dev/null &
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
TELEGRAM_PROXY_BATCH_TRAPS=""
TELEGRAM_PROXY_BATCH_ABORTED=0
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
    _telegram_proxy_remote_clear_plan
    TELEGRAM_PROXY_BATCH_ABORTED=1
    _telegram_proxy_batch_restore_traps
}

# Восстанавливает INT/TERM/HUP, сохранённые до пакета (например, `trap '' INT`
# у serve); без сохранённых — сбрасывает на значения по умолчанию.
_telegram_proxy_batch_restore_traps() {
    trap - INT TERM HUP
    [[ -z "$TELEGRAM_PROXY_BATCH_TRAPS" ]] || eval "$TELEGRAM_PROXY_BATCH_TRAPS"
    TELEGRAM_PROXY_BATCH_TRAPS=""
}

_telegram_proxy_batch_aborted() {
    [[ "${TELEGRAM_PROXY_BATCH_ABORTED:-0}" == 1 ]]
}

# FIFO source queue with four independent worker slots. Source indexes are
# never used as slots: a failed node_load consumes no slot, and a freed slot
# can be reused by the next source item without disturbing result ordering.
telegram_proxy_remote_batch() {
    local component="${1:-}" action="${2:-}" force="${3:-false}"
    # Machine-readable per-node outcome (same order as the plan); reasons are
    # redacted like the printed summary.
    local result_reason
    TELEGRAM_PROXY_RESULT_NAMES=() TELEGRAM_PROXY_RESULT_CODES=() TELEGRAM_PROXY_RESULT_REASONS=()
    if [[ $# -ne 3 ]] || ! _telegram_proxy_remote_action_is_valid "$component" "$action" ||
       [[ "$force" != true && "$force" != false ]]; then
        _telegram_proxy_remote_clear_plan; return 2
    fi
    if _telegram_proxy_remote_force_allowed "$component" "$action"; then
        [[ "$force" == true ]] || { _telegram_proxy_remote_clear_plan; return 2; }
    else
        [[ "$force" == false ]] || { _telegram_proxy_remote_clear_plan; return 2; }
    fi
    local -a indexes
    indexes=("${TELEGRAM_PROXY_PLAN_INDEX[@]}")
    local count=${#indexes[@]}
    (( count > 0 )) || { _telegram_proxy_remote_clear_plan; return 2; }

    local dir fifo
    dir=$(umask 077; mktemp -d) || { _telegram_proxy_remote_clear_plan; return 1; }
    chmod 700 "$dir" 2>/dev/null || true
    fifo="$dir/jobs"
    mkfifo "$fifo" 2>/dev/null || {
        rm -rf -- "$dir"
        _telegram_proxy_remote_clear_plan
        return 1
    }
    chmod 600 "$fifo" 2>/dev/null || true
    TELEGRAM_PROXY_BATCH_DIR="$dir"
    TELEGRAM_PROXY_BATCH_PIDS=""
    TELEGRAM_PROXY_BATCH_ABORTED=0
    trap -p INT TERM HUP > "$dir/traps" 2>/dev/null || true
    TELEGRAM_PROXY_BATCH_TRAPS=$(cat "$dir/traps" 2>/dev/null)
    _telegram_proxy_install_abort_traps _telegram_proxy_remote_batch_abort
    trap '_telegram_proxy_remote_batch_abort' HUP

    local -a source_name source_ip source_port source_queued results outputs worker_pids
    local src cred_file worker_count line rc code reason j upload_allowed aggregate=0
    for ((src=0; src<count; src++)); do
        _telegram_proxy_batch_aborted && return 130
        source_name[$src]="${TELEGRAM_PROXY_PLAN_NAME[$src]}"
        source_ip[$src]="${TELEGRAM_PROXY_PLAN_IP[$src]}"
        source_port[$src]="${TELEGRAM_PROXY_PLAN_PORT[$src]}"
        if [[ "${TELEGRAM_PROXY_PLAN_STATE[$src]}" == excluded ]]; then
            outputs[$src]="${TELEGRAM_PROXY_PLAN_REASON[$src]}"
            results[$src]=1
            source_queued[$src]=0
            continue
        fi
        cred_file="$dir/c$src"
        {
            _telegram_proxy_b64_encode "${source_name[$src]}"
            _telegram_proxy_b64_encode "${source_ip[$src]}"
            _telegram_proxy_b64_encode "${source_port[$src]}"
            _telegram_proxy_b64_encode "${TELEGRAM_PROXY_PLAN_USER[$src]}"
            _telegram_proxy_b64_encode "${TELEGRAM_PROXY_PLAN_PASS[$src]}"
            _telegram_proxy_b64_encode "${TELEGRAM_PROXY_PLAN_AUTH[$src]}"
            _telegram_proxy_b64_encode "${TELEGRAM_PROXY_PLAN_TAG[$src]}"
            _telegram_proxy_b64_encode "${TELEGRAM_PROXY_PLAN_ID[$src]}"
            _telegram_proxy_b64_encode "${TELEGRAM_PROXY_PLAN_IDENTITY[$src]}"
        } > "$cred_file" || {
            rm -rf "$dir"
            TELEGRAM_PROXY_BATCH_DIR=""; TELEGRAM_PROXY_BATCH_PIDS=""
            _telegram_proxy_remote_clear_plan
            _telegram_proxy_batch_restore_traps
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
        exec 9<>"$fifo" || { _telegram_proxy_remote_batch_abort; return 130; }
        (
            umask 077
            _telegram_proxy_fifo_dispatcher "$fifo" "$dir"
        ) &
        worker_pids[0]=$!
        TELEGRAM_PROXY_BATCH_PIDS="${TELEGRAM_PROXY_BATCH_PIDS} ${worker_pids[0]}"
        for ((src=0; src<count; src++)); do
            [[ "${source_queued[$src]:-0}" == 1 ]] || continue
            upload_allowed=false
            [[ "${TELEGRAM_PROXY_PLAN_STATE[$src]}" == upload ]] && upload_allowed=true
            printf '%s\t%s\t%s\t%s\t%s/r%s\t%s/o%s\t%s/c%s\t%s\t%s\t%s\n' \
                "$src" "$component" "$action" "$force" "$dir" "$src" "$dir" "$src" "$dir" "$src" \
                "$upload_allowed" "$TELEGRAM_PROXY_PLAN_FINGERPRINT" "$TELEGRAM_PROXY_PLAN_VERSION" >&9
        done
        exec 9>&-
        _telegram_proxy_remote_clear_plan
        if wait "${worker_pids[0]}" 2>/dev/null; then :; else :; fi
        _telegram_proxy_batch_aborted && return 130
        local barrier_wait=0 barrier_limit="${SSH_RUN_TIMEOUT:-120}"
        barrier_limit=$((barrier_limit + 10))
        while (( barrier_wait < barrier_limit )) && ! _telegram_proxy_batch_aborted; do
            local complete=0
            for ((src=0; src<count; src++)); do
                [[ "${source_queued[$src]:-0}" != 1 || -e "$dir/r$src.done" ]] &&
                    complete=$((complete + 1))
            done
            (( complete == count )) && break
            sleep 0.1
            barrier_wait=$((barrier_wait + 1))
        done
        for ((src=0; src<count; src++)); do
            if [[ "${source_queued[$src]:-0}" == 1 && ! -e "$dir/r$src.done" ]]; then
                results[$src]=1
                outputs[$src]="Не получен результат обработки ноды."
            fi
        done
    fi

    _telegram_proxy_batch_aborted && return 130
    _telegram_proxy_batch_restore_traps
    info "Результаты Telegram Proxy:"
    for ((j=0; j<count; j++)); do
        if [[ -z "${results[$j]:-}" && -s "$dir/r$j" ]]; then
            IFS= read -r line < "$dir/r$j"
            results[$j]="$line"
        fi
        if [[ -f "$dir/o$j" ]]; then
            outputs[$j]=$(cat "$dir/o$j" 2>/dev/null)
        elif [[ -z "${outputs[$j]:-}" ]]; then
            outputs[$j]="Не получен результат обработки ноды."
        fi
        rc="${results[$j]:-1}"
        code="${rc%%|*}"
        reason=""
        [[ "$rc" == *"|"* ]] && reason="${rc#*|}"
        case "$code" in
            3) (( aggregate == 0 )) && aggregate=3 ;;
            4) (( aggregate == 0 || aggregate == 3 )) && aggregate=4 ;;
            0) ;;
            *) aggregate=1 ;;
        esac
        result_reason="$reason"
        [[ -n "$result_reason" ]] || result_reason="${outputs[$j]%%$'\n'*}"
        TELEGRAM_PROXY_RESULT_NAMES[$j]="${source_name[$j]:-#${indexes[$j]}}"
        TELEGRAM_PROXY_RESULT_CODES[$j]="$code"
        TELEGRAM_PROXY_RESULT_REASONS[$j]=$(printf '%s\n' "$result_reason" | _telegram_proxy_redact)
        if [[ "$component:$action" == shared:status ]]; then
            _telegram_proxy_render_status_panel \
                "${source_name[$j]:-#${indexes[$j]}}" "${source_ip[$j]:-}" \
                "$code" "$reason" "${outputs[$j]:-}"
            continue
        fi
        case "$code" in
            0)
                success "${source_name[$j]} — успешно${reason:+: $reason}"
                if [[ "$component:$action" == mtproto:install ]]; then
                    info "Ссылки подключения: «Управление одной нодой» → «Показать ссылки подключения»."
                fi
                ;;
            3) info "${source_name[$j]} — пропущено: не установлен" ;;
            4) warn "${source_name[$j]} — частично: ${reason:-внешняя доступность не подтверждена}" ;;
            *)
                line="${outputs[$j]%%$'\n'*}"
                warn "${source_name[$j]} — ошибка: ${line:0:120}"
                [[ -n "${outputs[$j]:-}" ]] && printf '%s\n' "${outputs[$j]}"
                ;;
        esac
    done
    rm -rf -- "$dir"
    TELEGRAM_PROXY_BATCH_DIR=""
    TELEGRAM_PROXY_BATCH_PIDS=""
    _telegram_proxy_remote_clear_plan
    return "$aggregate"

}

# Non-interactive batch for the command core: validation and read-only
# preflight of every node. A destructive action or
# an upload goes through rc_confirm_gate (plan: label + lines; the bundle
# fingerprint and VERSION are part of the token), so nothing is written
# without --yes. Otherwise returns the batch aggregate (0/3/4/1) and leaves
# TELEGRAM_PROXY_RESULT_* filled.
core_telegram_run() {
    local component="${1:-}" action="${2:-}"
    local force=false index count
    _telegram_proxy_remote_clear_plan
    TELEGRAM_PROXY_RESULT_NAMES=() TELEGRAM_PROXY_RESULT_CODES=() TELEGRAM_PROXY_RESULT_REASONS=()
    if (( $# < 3 )); then
        rc_fail usage "Не выбраны ноды для операции Telegram Proxy."
        return 1
    fi
    shift 2
    if ! _telegram_proxy_remote_action_is_valid "$component" "$action"; then
        rc_fail usage "Неизвестная операция Telegram Proxy: $component $action."
        return 1
    fi
    _telegram_proxy_remote_force_allowed "$component" "$action" && force=true
    count=$(nodes_count)
    for index in "$@"; do
        if ! menu_index_valid "$index" "$count"; then
            rc_fail usage "Неверный номер ноды: $index."
            return 1
        fi
    done
    if ! _telegram_proxy_remote_preflight "$@"; then
        _telegram_proxy_remote_clear_plan
        rc_fail failed "Предварительная проверка нод Telegram Proxy не выполнена."
        return 1
    fi
    if ! _telegram_proxy_remote_plan_lines "$component" "$action"; then
        _telegram_proxy_remote_clear_plan
        rc_fail usage "Неизвестная операция Telegram Proxy: $component $action."
        return 1
    fi
    if [[ "$TELEGRAM_PROXY_PLAN_NEEDS_CONFIRM" == true ]] && (( TELEGRAM_PROXY_PLAN_ELIGIBLE > 0 )); then
        CORE_PLAN_LINES=("$TELEGRAM_PROXY_PLAN_LABEL" "${TELEGRAM_PROXY_PLAN_LINES[@]}")
        CORE_PLAN_EXTRA="${TELEGRAM_PROXY_PLAN_FINGERPRINT} ${TELEGRAM_PROXY_PLAN_VERSION}"
        if ! rc_confirm_gate; then
            _telegram_proxy_remote_clear_plan
            return 1
        fi
    fi
    telegram_proxy_remote_batch "$component" "$action" "$force"
}
