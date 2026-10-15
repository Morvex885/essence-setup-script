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
    warn "Для ноды '${NODE_NAME}' отложена SSH-настройка для синхронизации через GitHub: нужно подготовить SSH-ключ и сохранить ключ сервера. В главном меню выберите H) Завершить отложенную SSH-настройку нод."
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
            warn "Для ноды '${NODE_NAME}' отсутствует пароль SSH в состоянии GitHub. Сохраните ноду с паролем заново."
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
        warn "Для ноды '${NODE_NAME}' отсутствует пароль SSH в состоянии GitHub. Сохраните ноду с паролем заново."
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
        if [[ "${SSH_ALLOW_PORTABLE_ONBOARDING:-0}" == "1" ]]; then
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
        runner=(run_with_timeout "$timeout_seconds")
    fi
    if _setup_askpass; then
        DISPLAY=dummy SSH_ASKPASS="$_ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force \
            "${runner[@]}" ssh "${SSH_BASE_OPTIONS[@]}" "${extra[@]}" \
            "${SERVER_USER}@${SERVER_IP}" "$@"
        rc=$?
        _cleanup_askpass
    else
        "${runner[@]}" ssh "${SSH_BASE_OPTIONS[@]}" "${extra[@]}" \
            "${SERVER_USER}@${SERVER_IP}" "$@"
        rc=$?
    fi
    return "$rc"
}

scp_run() {
    _ssh_base_options || return 1
    local scp_options=() option
    for option in "${SSH_BASE_OPTIONS[@]}"; do
        [[ "$option" == "-p" ]] && option="-P"
        scp_options+=("$option")
    done
    local rc
    if _setup_askpass; then
        DISPLAY=dummy SSH_ASKPASS="$_ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force \
            scp "${scp_options[@]}" "$@"
        rc=$?
        _cleanup_askpass
    else
        scp "${scp_options[@]}" "$@"
        rc=$?
    fi
    return $rc
}

# Store a newly confirmed host key only in the managed known_hosts file.
_ssh_pin_host_key() {
    [[ -n "${SSH_KNOWN_HOSTS:-}" ]] || return 1
    mkdir -p "$(dirname "$SSH_KNOWN_HOSTS")" || return 1
    local tmp
    tmp=$(umask 077; mktemp) || return 1
    if ! ssh-keyscan -p "${SERVER_PORT:-22}" "$SERVER_IP" > "$tmp" 2>/dev/null ||
       [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        return 1
    fi
    cat "$tmp" >> "$SSH_KNOWN_HOSTS"
    rm -f "$tmp"
    chmod 600 "$SSH_KNOWN_HOSTS"
    state_checkpoint >/dev/null 2>&1 || true
}

# ─── Проверка соединения с ретраем ──────────────────────────────────────────
ssh_connect() {
    _ssh_node_portability_issue && return 1
    while true; do
        info "Подключаемся к ${NODE_NAME} (${SERVER_USER}@${SERVER_IP}:${SERVER_PORT})..."
        local _ssh_err
        _ssh_err=$(ssh_run -- "echo ok" 2>&1)
        if echo "$_ssh_err" | grep -q "^ok$"; then
            success "Соединение установлено"
            return 0
        fi
        if echo "$_ssh_err" | grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED"; then
            warn "SSH-ключ сервера изменился."
            if confirm_yn "Обновить ключ сервера?" Y; then
                if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
                    ssh-keygen -R "$SERVER_IP" -f "$SSH_KNOWN_HOSTS" 2>/dev/null || true
                    [[ "$SERVER_PORT" != "22" ]] &&
                        ssh-keygen -R "[$SERVER_IP]:$SERVER_PORT" -f "$SSH_KNOWN_HOSTS" 2>/dev/null || true
                    if ! _ssh_pin_host_key; then
                        warn "Не удалось записать новый ключ сервера."
                        return 1
                    fi
                else
                    ssh-keygen -R "$SERVER_IP" 2>/dev/null
                    [[ "$SERVER_PORT" != "22" ]] &&
                        ssh-keygen -R "[$SERVER_IP]:$SERVER_PORT" 2>/dev/null
                fi
                success "Старый ключ удалён. Повторяем подключение..."
                continue
            fi
        fi
        warn "Не удалось подключиться к '${NODE_NAME}'."
        local _reason
        _reason=$(echo "$_ssh_err" | grep -iE "refused|denied|closed|timed out|No route|resolve|reset" | head -1)
        [[ -n "$_reason" ]] && warn "Причина: $_reason"
        confirm_yn "Повторить попытку?" Y || return 1
    done
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

ensure_remote_scripts_current() {
    local force=false local_version
    case "${1:-}" in
        "") [[ $# -eq 0 ]] || return 2 ;;
        --force) [[ $# -eq 1 ]] || return 2; force=true ;;
        *) return 2 ;;
    esac
    if [[ -z "${VERSION_PATH:-}" || ! -f "$VERSION_PATH" ]] ||
       ! local_version=$(_remote_scripts_normalize_version "$(cat "$VERSION_PATH")"); then
        warn "Некорректный локальный VERSION: подготовка скриптов остановлена."
        return 1
    fi
    if ! _remote_scripts_probe; then
        warn "Не удалось определить состояние скриптов на ноде '${NODE_NAME}'."
        return 1
    fi
    if [[ "$force" == true ]]; then
        local remote_label
        case "$REMOTE_SCRIPTS_STATE" in
            missing) remote_label="скрипты отсутствуют" ;;
            broken) remote_label="установка повреждена${REMOTE_SCRIPTS_VERSION:+ (версия $REMOTE_SCRIPTS_VERSION)}" ;;
            unknown) remote_label="неизвестна" ;;
            ready) remote_label="$REMOTE_SCRIPTS_VERSION" ;;
        esac
        echo ""
        box_top
        box_center "Принудительная загрузка скриптов"
        box_mid
        box_line " Нода: ${NODE_NAME} (${SERVER_IP})"
        box_line " Локальная версия: $local_version"
        box_line " Серверная версия: $remote_label"
        box_mid
        box_line " Локальные скрипты заменят серверные, включая ручные изменения;"
        box_line " версия может быть понижена."
        box_bot
        echo ""
        if ! confirm_yn "Загрузить локальные скрипты принудительно?" N; then
            info "Загрузка скриптов отменена."
            return 0
        fi
    else
        case "$REMOTE_SCRIPTS_STATE" in
            ready)
                _ver_gt "$local_version" "$REMOTE_SCRIPTS_VERSION" || return 0 ;;
            missing) ;;
            unknown|broken)
                warn "На ноде '${NODE_NAME}' версия скриптов неизвестна или установка повреждена. Используйте пункт ручной принудительной загрузки."
                return 1 ;;
        esac
    fi
    upload_scripts || return 1
    if ! _remote_scripts_probe ||
       [[ "$REMOTE_SCRIPTS_STATE" != ready || "$REMOTE_SCRIPTS_VERSION" != "$local_version" ]]; then
        warn "Версия скриптов на ноде '${NODE_NAME}' после загрузки не подтверждена."
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
