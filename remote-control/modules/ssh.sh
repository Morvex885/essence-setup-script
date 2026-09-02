#!/bin/bash
# ─── SSH / SCP обёртки и удалённые операции ──────────────────────────────────

# Создаёт askpass-скрипт для передачи пароля через SSH_ASKPASS.
# Устанавливает _ASKPASS_FILE и _PASS_FILE (глобальные для cleanup).
_ASKPASS_FILE="" _PASS_FILE=""
SSH_BASE_OPTIONS=()

_setup_askpass() {
    _ASKPASS_FILE="" _PASS_FILE=""
    [[ "$SERVER_AUTH" == "key" || -z "$SERVER_PASS" ]] && return 1
    _PASS_FILE=$(umask 077; mktemp)
    printf '%s' "$SERVER_PASS" > "$_PASS_FILE"
    _ASKPASS_FILE=$(umask 077; mktemp)
    printf '#!/bin/bash\ncat "%s"\n' "$_PASS_FILE" > "$_ASKPASS_FILE"
    chmod 700 "$_ASKPASS_FILE"
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
    local extra=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do extra+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    _ssh_base_options || return 1

    local is_tty=false f
    for f in "${extra[@]}"; do [[ "$f" == "-t" ]] && is_tty=true; done
    local rc
    if _setup_askpass; then
        if $is_tty; then
            DISPLAY=dummy SSH_ASKPASS="$_ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force \
                ssh "${SSH_BASE_OPTIONS[@]}" "${extra[@]}" "${SERVER_USER}@${SERVER_IP}" "$@"
        else
            DISPLAY=dummy SSH_ASKPASS="$_ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force \
                run_with_timeout 30 ssh "${SSH_BASE_OPTIONS[@]}" "${extra[@]}" "${SERVER_USER}@${SERVER_IP}" "$@"
        fi
        rc=$?
        _cleanup_askpass
    else
        if $is_tty; then
            ssh "${SSH_BASE_OPTIONS[@]}" "${extra[@]}" "${SERVER_USER}@${SERVER_IP}" "$@"
        else
            run_with_timeout 30 ssh "${SSH_BASE_OPTIONS[@]}" "${extra[@]}" "${SERVER_USER}@${SERVER_IP}" "$@"
        fi
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
upload_scripts() {
    info "Загружаем скрипты на ${SERVER_USER}@${SERVER_IP} (${REMOTE_DIR})..."
    ssh_run -- "mkdir -p ${REMOTE_DIR}/modules" \
        || { warn "Не удалось создать директорию на сервере."; return; }
    scp_run "$SETUP_DIR/setup-essence.sh" \
        "${SERVER_USER}@${SERVER_IP}:${REMOTE_DIR}/setup-essence.sh" \
        || { warn "Ошибка загрузки setup-essence.sh"; return; }
    scp_run "$SETUP_DIR/modules/"*.sh \
        "${SERVER_USER}@${SERVER_IP}:${REMOTE_DIR}/modules/" \
        || { warn "Ошибка загрузки модулей"; return; }
    scp_run -r "$COMMON_DIR" \
        "${SERVER_USER}@${SERVER_IP}:${REMOTE_DIR}/" \
        || { warn "Ошибка загрузки common/"; return; }
    scp_run "$VERSION_PATH" \
        "${SERVER_USER}@${SERVER_IP}:${REMOTE_DIR}/VERSION" \
        || { warn "Ошибка загрузки VERSION"; return; }
    ssh_run -- "chmod +x ${REMOTE_DIR}/setup-essence.sh ${REMOTE_DIR}/modules/*.sh"
    success "Скрипты загружены"
}

# ─── Запуск меню на сервере ───────────────────────────────────────────────────
run_remote() {
    echo ""
    info "Открываю интерактивную SSH-сессию на ${NODE_NAME} (${SERVER_IP})..."
    echo -e "  ${YELLOW}(введите 0 в меню сервера для выхода)${NC}"
    echo ""
    ssh_run -t -- "bash ${REMOTE_DIR}/setup-essence.sh"
}
