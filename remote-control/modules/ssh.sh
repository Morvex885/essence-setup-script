#!/bin/bash
# ─── SSH / SCP обёртки и удалённые операции ──────────────────────────────────

# Создаёт askpass-скрипт для передачи пароля через SSH_ASKPASS
# Устанавливает _ASKPASS_FILE и _PASS_FILE (глобальные для cleanup)
_ASKPASS_FILE="" _PASS_FILE=""

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

ssh_run() {
    local extra=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do extra+=("$1"); shift; done
    [[ "$1" == "--" ]] && shift
    local base=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -p "$SERVER_PORT")

    local is_tty=false
    for f in "${extra[@]}"; do [[ "$f" == "-t" ]] && is_tty=true; done

    local rc
    if _setup_askpass; then
        if $is_tty; then
            DISPLAY=dummy SSH_ASKPASS="$_ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force \
                ssh "${base[@]}" "${extra[@]}" "${SERVER_USER}@${SERVER_IP}" "$@"
        else
            DISPLAY=dummy SSH_ASKPASS="$_ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force \
                timeout 30 ssh "${base[@]}" "${extra[@]}" "${SERVER_USER}@${SERVER_IP}" "$@"
        fi
        rc=$?
        _cleanup_askpass
    else
        if $is_tty; then
            ssh "${base[@]}" "${extra[@]}" "${SERVER_USER}@${SERVER_IP}" "$@"
        else
            timeout 30 ssh "${base[@]}" "${extra[@]}" "${SERVER_USER}@${SERVER_IP}" "$@"
        fi
        rc=$?
    fi
    return $rc
}

scp_run() {
    local base=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -P "$SERVER_PORT")

    local rc
    if _setup_askpass; then
        DISPLAY=dummy SSH_ASKPASS="$_ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force \
            scp "${base[@]}" "$@"
        rc=$?
        _cleanup_askpass
    else
        scp "${base[@]}" "$@"
        rc=$?
    fi
    return $rc
}

# ─── Проверка соединения с ретраем ──────────────────────────────────────────
# ssh_connect — проверяет SSH соединение с текущей нодой.
# Обрабатывает изменение ключа, показывает причину ошибки, предлагает повторить.
# Возвращает 0 при успехе, 1 при отмене пользователем.
ssh_connect() {
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
                ssh-keygen -R "$SERVER_IP" 2>/dev/null
                [[ "$SERVER_PORT" != "22" ]] && ssh-keygen -R "[$SERVER_IP]:$SERVER_PORT" 2>/dev/null
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
