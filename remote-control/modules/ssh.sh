#!/bin/bash
# ─── SSH / SCP обёртки и удалённые операции ──────────────────────────────────

# Создаёт askpass-скрипт для передачи пароля через SSH_ASKPASS.
# Устанавливает _ASKPASS_FILE и _PASS_FILE (глобальные для cleanup).
_ASKPASS_FILE="" _PASS_FILE=""
SSH_BASE_OPTIONS=()

_setup_askpass() {
    _cleanup_askpass >/dev/null 2>&1 || true
    [[ "$SERVER_AUTH" == "key" || -z "$SERVER_PASS" ]] && return 1
    _PASS_FILE=$(umask 077; mktemp) || return 1
    if ! printf '%s' "$SERVER_PASS" > "$_PASS_FILE"; then
        _cleanup_askpass
        return 1
    fi
    chmod 0600 "$_PASS_FILE" || { _cleanup_askpass; return 1; }
    _ASKPASS_FILE=$(umask 077; mktemp) || { _cleanup_askpass; return 1; }
    if ! printf '#!/bin/bash\ncat "%s"\n' "$_PASS_FILE" > "$_ASKPASS_FILE" ||
       ! chmod 0700 "$_ASKPASS_FILE"; then
        _cleanup_askpass
        return 1
    fi
    if declare -F register_exit_cleanup >/dev/null 2>&1; then
        register_exit_cleanup _cleanup_askpass
    fi
}

_cleanup_askpass() {
    rm -f "$_ASKPASS_FILE" "$_PASS_FILE"
    _ASKPASS_FILE="" _PASS_FILE=""
}

_ssh_known_host_present() {
    local host="$SERVER_IP"
    [[ "${SERVER_PORT:-22}" != "22" ]] && host="[$SERVER_IP]:$SERVER_PORT"
    [[ -n "${SSH_KNOWN_HOSTS:-}" && -f "$SSH_KNOWN_HOSTS" ]] ||
        return 1
    ssh-keygen -F "$host" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1
}

_ssh_deferred_setup_hint() {
    warn "Для ноды '${NODE_NAME}' отложена SSH-настройка для синхронизации через GitHub: нужно подготовить SSH-ключ и сохранить ключ сервера. Завершите её командой node setup-ssh."
}

_ssh_node_portability_issue() {
    [[ "${CONFIG_SOURCE:-local}" == "github" ]] || return 1
    [[ "${SSH_ALLOW_PORTABLE_ONBOARDING:-0}" == "1" ]] && return 1
    local issue=""
    if [[ -n "${STATE_MANIFEST:-}" && -f "$STATE_MANIFEST" ]]; then
        issue=$(jq -r --arg id "${NODE_ID:-}" \
            '.portability.issues[]? | select(.node_id==$id) | .reason' \
            "$STATE_MANIFEST" 2>/dev/null | tr -d '\r' | head -1)
    fi
    if [[ -z "$issue" && -n "${CONFIG_JSON:-}" && -f "$CONFIG_JSON" ]]; then
        issue=$(jq -r --arg id "${NODE_ID:-}" \
            '.portability.issues[]? | select(.node_id==$id) | .reason' \
            "$CONFIG_JSON" 2>/dev/null | tr -d '\r' | head -1)
    fi
    if [[ -n "$issue" ]]; then
        if [[ "$issue" == missing_secret ]]; then
            warn "Пароль SSH для ноды '${NODE_NAME}' недоступен. Сохраните его заново: node password --name ${NODE_NAME}."
        else
            _ssh_deferred_setup_hint
        fi
        return 0
    fi
    if [[ "$SERVER_AUTH" == "key" ]]; then
        if [[ -z "${NODE_IDENTITY:-}" || "$NODE_IDENTITY" == "system" ||
              -z "${SSH_IDENTITIES_DIR:-}" || ! -f "$SSH_IDENTITIES_DIR/$NODE_IDENTITY" ]]; then
            _ssh_deferred_setup_hint
            return 0
        fi
    elif [[ -z "$SERVER_PASS" ]]; then
        warn "Пароль SSH для ноды '${NODE_NAME}' недоступен. Сохраните его заново: node password --name ${NODE_NAME}."
        return 0
    fi
    if ! _ssh_known_host_present; then
        _ssh_deferred_setup_hint
        return 0
    fi
    return 1
}

# Sets SSH_BASE_OPTIONS; callers append operation-specific options afterwards.
_ssh_base_options() {
    SSH_BASE_OPTIONS=(-o ConnectTimeout=10 -o ServerAliveInterval=5
        -o ServerAliveCountMax=3 -p "${SERVER_PORT:-22}")
    if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
        _ssh_node_portability_issue && return 1
        SSH_BASE_OPTIONS=(-o StrictHostKeyChecking=yes
            -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}"
            -o ConnectTimeout=10 -o ServerAliveInterval=5
            -o ServerAliveCountMax=3 -p "${SERVER_PORT:-22}")
        # accept-new только для ещё неизвестного узла: закреплённый (в том
        # числе по согласованному плану) ключ не дополняется ключом другого типа.
        if [[ "${SSH_ALLOW_PORTABLE_ONBOARDING:-0}" == "1" ]] && ! _ssh_known_host_present; then
            SSH_BASE_OPTIONS[1]="StrictHostKeyChecking=accept-new"
        fi
        if [[ "$SERVER_AUTH" == "key" &&
              "${NODE_IDENTITY:-}" != "" && "${NODE_IDENTITY:-}" != "system" ]]; then
            SSH_BASE_OPTIONS+=(-i "$SSH_IDENTITIES_DIR/$NODE_IDENTITY" -o IdentitiesOnly=yes)
        fi
    else
        SSH_BASE_OPTIONS=(-o StrictHostKeyChecking=accept-new
            -o ConnectTimeout=10 -o ServerAliveInterval=5
            -o ServerAliveCountMax=3 -p "${SERVER_PORT:-22}")
        # After local hardening the managed key may be the only accepted one;
        # keep agent/system keys as a fallback (no IdentitiesOnly).
        if [[ "$SERVER_AUTH" == "key" &&
              "${NODE_IDENTITY:-}" != "" && "${NODE_IDENTITY:-}" != "system" &&
              -f "${SSH_IDENTITIES_DIR:-}/$NODE_IDENTITY" ]]; then
            SSH_BASE_OPTIONS+=(-i "$SSH_IDENTITIES_DIR/$NODE_IDENTITY")
        fi
    fi
}

ssh_run() {
    local extra=() tty=false option
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        option="$1"
        extra+=("$option")
        [[ "$option" == "-t" || "$option" == "-tt" ]] && tty=true
        shift
    done
    [[ "${1:-}" == "--" ]] && shift
    _ssh_base_options || return 1
    local rc timeout_seconds="${SSH_RUN_TIMEOUT:-30}" runner=()
    [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds=30
    if [[ "$tty" != true ]]; then
        runner=(run_with_timeout "$timeout_seconds" ${RC_SERVE_TIMEOUT_FLAG:+"$RC_SERVE_TIMEOUT_FLAG"})
    fi
    # «--» перед адресом: логин и адрес из config.json не разбираются как опции.
    if _setup_askpass; then
        DISPLAY=dummy SSH_ASKPASS="$_ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force \
            "${runner[@]}" ssh "${SSH_BASE_OPTIONS[@]}" "${extra[@]}" \
            -- "${SERVER_USER}@${SERVER_IP}" "$@"
        rc=$?
        _cleanup_askpass
    else
        "${runner[@]}" ssh "${SSH_BASE_OPTIONS[@]}" "${extra[@]}" \
            -- "${SERVER_USER}@${SERVER_IP}" "$@"
        rc=$?
    fi
    return "$rc"
}

# scp_run [-r] SOURCE… USER@HOST:PATH — ведущие опции вызывающего, затем «--»
# перед операндами.
scp_run() {
    _ssh_base_options || return 1
    local scp_options=() option
    for option in "${SSH_BASE_OPTIONS[@]}"; do
        [[ "$option" == "-p" ]] && option="-P"
        scp_options+=("$option")
    done
    while [[ $# -gt 0 && "$1" == -?* && "$1" != -- ]]; do
        scp_options+=("$1")
        shift
    done
    [[ "${1:-}" == -- ]] && shift
    local rc
    if _setup_askpass; then
        DISPLAY=dummy SSH_ASKPASS="$_ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force \
            scp "${scp_options[@]}" -- "$@"
        rc=$?
        _cleanup_askpass
    else
        scp "${scp_options[@]}" -- "$@"
        rc=$?
    fi
    return $rc
}

# Store a newly confirmed host key only in the managed known_hosts file.
# При непустом ONBOARDING_PLANNED_FPS (строки «NODE_ID SHA256:…» из плана
# onboarding_plan_lines) закрепляются только ключи с согласованными для
# NODE_ID отпечатками; нет согласованных или совпадений — сбой без записи.
_ssh_pin_host_key() {
    [[ -n "${SSH_KNOWN_HOSTS:-}" ]] || return 1
    local tmp planned=() id fp
    if [[ -n "${ONBOARDING_PLANNED_FPS:-}" ]]; then
        while read -r id fp; do
            [[ -n "$id" && "$id" == "${NODE_ID:-}" && "$fp" == SHA256:?* ]] && planned+=("$fp")
        done <<< "$ONBOARDING_PLANNED_FPS"
        if [[ ${#planned[@]} -eq 0 ]]; then
            warn "Ключ сервера ноды '${NODE_NAME:-}' не был согласован в плане."
            return 1
        fi
    fi
    mkdir -p "$(dirname "$SSH_KNOWN_HOSTS")" || return 1
    tmp=$(umask 077; mktemp) || return 1
    if ! ssh-keyscan -p "${SERVER_PORT:-22}" "$SERVER_IP" > "$tmp" 2>/dev/null ||
       [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        return 1
    fi
    if [[ ${#planned[@]} -gt 0 ]]; then
        local agreed
        agreed=$(umask 077; mktemp) || { rm -f "$tmp"; return 1; }
        if ! _node_hostkey_filter "$tmp" "$agreed" "${planned[@]}"; then
            rm -f "$tmp" "$agreed"
            warn "Ключ сервера ноды '${NODE_NAME:-}' не совпадает с согласованным в плане."
            return 1
        fi
        rm -f "$tmp"
        tmp="$agreed"
    fi
    if ! cat "$tmp" >> "$SSH_KNOWN_HOSTS"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    chmod 600 "$SSH_KNOWN_HOSTS" || return 1
    if ! state_checkpoint; then
        warn "Ключ сервера записан, но точку восстановления сохранить не удалось."
        return 1
    fi
}

# ─── Проверка соединения ─────────────────────────────────────────────────────
# ssh_require_portable — без подключения: needs_setup, если у загруженной
# ноды GitHub отложена SSH-настройка (SSH к ней заведомо не выполнится).
# Вызывается до первого удалённого шага и до подтверждения планом.
ssh_require_portable() {
    if _ssh_node_portability_issue >/dev/null; then
        rc_fail needs_setup "Для ноды '${NODE_NAME}' отложена SSH-настройка: выполните node setup-ssh."
        return 1
    fi
}

# ssh_probe — одна проверка SSH загруженной ноды, без вопросов и повторов.
# Коды: missing_secret / needs_setup (переносимость GitHub), host_key_changed
# с {"host","port","fingerprints"}, remote_failed с {"reason"}.
ssh_probe() {
    local out reason extra
    if [[ "$SERVER_AUTH" == password && -z "$SERVER_PASS" ]]; then
        rc_fail missing_secret "Пароль SSH ноды '${NODE_NAME}' не сохранён."
        return 1
    fi
    ssh_require_portable || return 1
    info "Подключаемся к ${NODE_NAME} (${SERVER_USER}@${SERVER_IP}:${SERVER_PORT})..."
    out=$(ssh_run -- "echo ok" 2>&1)
    if printf '%s\n' "$out" | grep -q "^ok$"; then
        success "Соединение установлено"
        return 0
    fi
    if printf '%s\n' "$out" | grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED"; then
        local fps='[]'
        if _node_hostkey_scan "$SERVER_IP" "$SERVER_PORT"; then
            rm -f "$NODE_HOSTKEY_SCAN"
            fps=$(printf '%s\n' "${NODE_HOSTKEY_FPS[@]}" | jq -R . | jq -sc .)
        fi
        extra=$(jq -cn --arg h "$SERVER_IP" --argjson p "${SERVER_PORT:-22}" --argjson f "$fps" \
            '{host:$h, port:$p, fingerprints:$f}')
        rc_fail host_key_changed "Ключ сервера ноды '${NODE_NAME}' изменился." "$extra"
        return 1
    fi
    reason=$(printf '%s\n' "$out" | grep -iE "refused|denied|closed|timed out|No route|resolve|reset" | head -1 | tr -d '\r')
    extra=$(jq -cn --arg r "$reason" '{reason:(if $r == "" then null else $r end)}')
    rc_fail remote_failed "Не удалось подключиться к '${NODE_NAME}'.${reason:+ Причина: $reason}" "$extra"
}

# ─── Проверка и загрузка скриптов ────────────────────────────────────────────
_remote_scripts_normalize_version() {
    local raw="${1:-}" major minor patch
    raw="${raw%$'\r'}"
    raw="${raw#v}"
    [[ "$raw" =~ ^([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})$ ]] || return 1
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    printf '%d.%d.%d\n' "$((10#$major))" "$((10#$minor))" "$((10#$patch))"
}

_remote_scripts_probe() {
    REMOTE_SCRIPTS_STATE=unknown
    REMOTE_SCRIPTS_VERSION=""
    local dir response version="" command
    printf -v dir '%q' "$REMOTE_DIR"
    command="dir=$dir
if [[ ! -e \"\$dir\" && ! -L \"\$dir\" ]]; then printf 'MISSING'; exit 0; fi
if [[ ! -d \"\$dir\" ]]; then printf 'BROKEN'; exit 0; fi
[[ -r \"\$dir\" && -x \"\$dir\" ]] || exit 1
entries=\$(ls -A \"\$dir\" && printf '.') || exit 1
if [[ \"\$entries\" == '.' ]]; then printf 'MISSING'; exit 0; fi
if [[ -x \"\$dir/setup-essence.sh\" && -f \"\$dir/setup-essence.sh\" ]]; then
    printf 'PRESENT'
else
    printf 'BROKEN'
fi
if [[ -e \"\$dir/VERSION\" || -L \"\$dir/VERSION\" ]]; then
    [[ -f \"\$dir/VERSION\" && -r \"\$dir/VERSION\" ]] || exit 1
    printf '\n'
    cat \"\$dir/VERSION\" || exit 1
fi"
    response=$(ssh_run -n -- "$command") || return 1
    case "$response" in
        MISSING) REMOTE_SCRIPTS_STATE=missing; return 0 ;;
        PRESENT|PRESENT$'\n'*) REMOTE_SCRIPTS_STATE=ready ;;
        BROKEN|BROKEN$'\n'*) REMOTE_SCRIPTS_STATE=broken ;;
        *) return 1 ;;
    esac
    if [[ "$response" == *$'\n'* ]]; then
        version="${response#*$'\n'}"
        REMOTE_SCRIPTS_VERSION=$(_remote_scripts_normalize_version "$version") || REMOTE_SCRIPTS_VERSION=""
    fi
    if [[ "$REMOTE_SCRIPTS_STATE" == ready && -z "$REMOTE_SCRIPTS_VERSION" ]]; then
        REMOTE_SCRIPTS_STATE=unknown
    fi
}

upload_scripts() {
    local dir entry modules version_tmp destination
    printf -v dir '%q' "$REMOTE_DIR"
    printf -v entry '%q' "$REMOTE_DIR/setup-essence.sh"
    printf -v modules '%q' "$REMOTE_DIR/modules"
    version_tmp="$REMOTE_DIR/.VERSION.$$.$RANDOM"
    printf -v destination '%q' "$version_tmp"
    info "Загружаем скрипты на ${SERVER_USER}@${SERVER_IP} (${REMOTE_DIR})..."
    ssh_run -- "mkdir -p $modules" \
        || { warn "Не удалось создать директорию на сервере."; return 1; }
    if ! scp_run "$SETUP_DIR/setup-essence.sh" \
            "${SERVER_USER}@${SERVER_IP}:$entry" ||
       ! scp_run "$SETUP_DIR/modules/"*.sh \
            "${SERVER_USER}@${SERVER_IP}:$modules/" ||
       ! scp_run -r "$COMMON_DIR" \
            "${SERVER_USER}@${SERVER_IP}:$dir/" ||
       ! ssh_run -- "chmod +x $entry $modules/"'*.sh' ||
       ! scp_run "$VERSION_PATH" \
            "${SERVER_USER}@${SERVER_IP}:$destination" ||
       ! ssh_run -- "mv -f $destination $dir/VERSION"; then
        ssh_run -- "rm -f $destination" >/dev/null 2>&1 || true
        warn "Не удалось загрузить и опубликовать скрипты."
        return 1
    fi
    success "Скрипты загружены"
}

_remote_scripts_local_version() {
    [[ -n "${VERSION_PATH:-}" && -f "$VERSION_PATH" ]] || return 1
    _remote_scripts_normalize_version "$(cat "$VERSION_PATH")"
}

# Строки обзора принудительной загрузки в CORE_PLAN_LINES.
# Вызывать после _remote_scripts_probe для загруженной ноды.
_remote_scripts_force_plan() {
    local local_version remote_label
    CORE_PLAN_LINES=()
    if ! local_version=$(_remote_scripts_local_version); then
        rc_fail invalid "Некорректный локальный VERSION: подготовка скриптов остановлена."
        return 1
    fi
    case "${REMOTE_SCRIPTS_STATE:-unknown}" in
        missing) remote_label="скрипты отсутствуют" ;;
        broken) remote_label="установка повреждена${REMOTE_SCRIPTS_VERSION:+ (версия $REMOTE_SCRIPTS_VERSION)}" ;;
        ready) remote_label="$REMOTE_SCRIPTS_VERSION" ;;
        *) remote_label="неизвестна" ;;
    esac
    CORE_PLAN_LINES=(
        "Нода: ${NODE_NAME} (${SERVER_IP})"
        "Локальная версия: $local_version"
        "Серверная версия: $remote_label"
        "Локальные скрипты заменят серверные, включая ручные изменения;"
        "версия может быть понижена."
    )
}

# ensure_remote_scripts_current [--force] — без --force загружает скрипты, только
# если локальные новее или их нет; --force заменяет серверные без вопросов
# (подтверждение — план команды node upload-scripts).
ensure_remote_scripts_current() {
    local force=false local_version
    case "$#:${1:-}" in
        0:) ;;
        1:--force) force=true ;;
        *) return 2 ;;
    esac
    if ! local_version=$(_remote_scripts_local_version); then
        rc_fail invalid "Некорректный локальный VERSION: подготовка скриптов остановлена."
        return 1
    fi
    if ! _remote_scripts_probe; then
        rc_fail remote_failed "Не удалось определить состояние скриптов на ноде '${NODE_NAME}'."
        return 1
    fi
    if [[ "$force" != true ]]; then
        case "$REMOTE_SCRIPTS_STATE" in
            ready)
                _ver_gt "$local_version" "$REMOTE_SCRIPTS_VERSION" || return 0 ;;
            missing) ;;
            unknown|broken)
                rc_fail invalid "На ноде '${NODE_NAME}' версия скриптов неизвестна или установка повреждена. Загрузите скрипты принудительно: node upload-scripts --force."
                return 1 ;;
        esac
    fi
    if ! upload_scripts; then
        rc_fail remote_failed "Не удалось загрузить скрипты на ноду '${NODE_NAME}'."
        return 1
    fi
    if ! _remote_scripts_probe ||
       [[ "$REMOTE_SCRIPTS_STATE" != ready || "$REMOTE_SCRIPTS_VERSION" != "$local_version" ]]; then
        rc_fail remote_failed "Версия скриптов на ноде '${NODE_NAME}' после загрузки не подтверждена."
        return 1
    fi
}

# ─── Запуск меню на сервере ───────────────────────────────────────────────────
run_remote() {
    echo ""
    info "Открываю интерактивную SSH-сессию на ${NODE_NAME} (${SERVER_IP})..."
    echo -e "  ${YELLOW}(введите 0 в меню сервера для выхода)${NC}"
    echo ""
    local entry
    printf -v entry '%q' "$REMOTE_DIR/setup-essence.sh"
    ssh_run -t -- "bash $entry"
}
