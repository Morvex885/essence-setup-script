#!/bin/bash
# ─── SSH Hardening: ключ + отключение пароля + смена порта ───────────────────

_harden_setup_key() {
    local key_path="$HOME/.ssh/id_ed25519"

    # Генерация ключа если нет
    if [[ ! -f "$key_path" ]]; then
        info "Генерируем SSH-ключ (ed25519)..."
        mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
        ssh-keygen -t ed25519 -f "$key_path" -N "" -q || { warn "Не удалось сгенерировать ключ."; return 1; }
        success "SSH-ключ создан: $key_path"
    else
        info "SSH-ключ уже существует: $key_path"
    fi

    # Копируем публичный ключ на сервер
    local pubkey
    pubkey=$(cat "${key_path}.pub") || { warn "Не удалось прочитать публичный ключ."; return 1; }

    info "Копируем публичный ключ на сервер..."
    ssh_run -- "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${pubkey}' >> ~/.ssh/authorized_keys && sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
        || { warn "Не удалось скопировать ключ на сервер."; return 1; }

    # Проверяем что ключ работает
    info "Проверяем авторизацию по ключу..."
    if timeout 10 ssh -i "$key_path" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        -o PasswordAuthentication=no \
        -p "$SERVER_PORT" \
        "${SERVER_USER}@${SERVER_IP}" "echo ok" &>/dev/null; then
        success "Авторизация по ключу работает"
        return 0
    else
        warn "Авторизация по ключу не работает. Hardening прерван."
        return 1
    fi
}

_harden_disable_password() {
    info "Отключаем вход по паролю на сервере..."
    ssh_run -- "
        sed -i '/^#\\?PubkeyAuthentication/d' /etc/ssh/sshd_config
        sed -i '/^#\\?PasswordAuthentication/d' /etc/ssh/sshd_config
        sed -i '/^#\\?ChallengeResponseAuthentication/d' /etc/ssh/sshd_config
        echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
        echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
        echo 'ChallengeResponseAuthentication no' >> /etc/ssh/sshd_config
    " || { warn "Не удалось изменить sshd_config."; return 1; }
    success "Вход по паролю отключён (ожидает перезапуска sshd)"
}

_harden_restore_password() {
    ssh_run -- "
        sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config
        sed -i '/^ChallengeResponseAuthentication/d' /etc/ssh/sshd_config
        echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
    " 2>/dev/null
}

_harden_change_port() {
    local old_port="$SERVER_PORT"
    local new_port=""

    # Генерируем случайный порт
    local attempts=0
    while (( attempts < 5 )); do
        new_port=$(( RANDOM % 16384 + 49152 ))
        # Проверяем что порт свободен
        if ! ssh_run -- "ss -tlnp | grep -q ':${new_port}\b'" 2>/dev/null; then
            break
        fi
        attempts=$((attempts + 1))
        new_port=""
    done
    [[ -z "$new_port" ]] && { warn "Не удалось найти свободный порт."; return 1; }

    echo ""
    echo -e "  Предлагаемый порт: ${GREEN}${new_port}${NC}"
    read -rp "  Принять (Enter) или ввести свой [${new_port}]: " _custom_port
    if [[ -n "$_custom_port" ]]; then
        if ! [[ "$_custom_port" =~ ^[0-9]+$ ]] || (( _custom_port < 1 || _custom_port > 65535 )); then
            warn "Порт должен быть числом от 1 до 65535."
            return 1
        fi
        new_port="$_custom_port"
        # Проверяем что кастомный порт свободен
        if ssh_run -- "ss -tlnp | grep -q ':${new_port}\b'" 2>/dev/null; then
            warn "Порт ${new_port} уже занят на сервере."
            return 1
        fi
    fi

    info "Меняем SSH-порт на ${new_port}..."
    ssh_run -- "
        sed -i '/^#\\?Port /d' /etc/ssh/sshd_config
        echo 'Port ${new_port}' >> /etc/ssh/sshd_config
    " || { warn "Не удалось изменить порт в sshd_config."; return 1; }

    # Открываем новый порт и удаляем старый из firewall
    ssh_run -- "
        if command -v ufw &>/dev/null; then
            ufw allow ${new_port}/tcp > /dev/null 2>&1
            ufw delete allow OpenSSH > /dev/null 2>&1
            ufw delete allow 22/tcp > /dev/null 2>&1
            ufw delete allow ${old_port}/tcp > /dev/null 2>&1
        fi
        if command -v firewall-cmd &>/dev/null; then
            firewall-cmd --permanent --add-port=${new_port}/tcp > /dev/null 2>&1
            firewall-cmd --permanent --remove-service=ssh > /dev/null 2>&1
            firewall-cmd --permanent --remove-port=${old_port}/tcp > /dev/null 2>&1
            firewall-cmd --reload > /dev/null 2>&1
        fi
    " 2>/dev/null

    # Проверяем конфиг перед рестартом
    local _sshd_check
    if ! _sshd_check=$(ssh_run -- "sshd -t 2>&1"); then
        warn "Ошибка в sshd_config:"
        echo "$_sshd_check" | head -5
        warn "Откатываем порт..."
        ssh_run -- "
            sed -i '/^Port /d' /etc/ssh/sshd_config
            echo 'Port ${old_port}' >> /etc/ssh/sshd_config
            if command -v ufw &>/dev/null; then
                ufw allow ${old_port}/tcp > /dev/null 2>&1
                ufw delete allow ${new_port}/tcp > /dev/null 2>&1
            fi
        "
        return 1
    fi

    # Перезапускаем sshd (daemon-reload запускает generator, обновляет ssh.socket из sshd_config)
    info "Перезапускаем sshd..."
    ssh_run -- "
        systemctl daemon-reload 2>/dev/null
        systemctl restart ssh.socket 2>/dev/null || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null
    " || { warn "Не удалось перезапустить sshd."; return 1; }

    # Ждём пока sshd перезапустится
    sleep 3

    # Проверяем подключение по новому порту с ключом (без -v для надёжного grep)
    info "Проверяем подключение на порту ${new_port}..."
    local _verify_ok
    _verify_ok=$(timeout 10 ssh -i "$HOME/.ssh/id_ed25519" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        -o PasswordAuthentication=no \
        -p "$new_port" \
        "${SERVER_USER}@${SERVER_IP}" "echo ok" 2>/dev/null)
    if [[ "$_verify_ok" == *"ok"* ]]; then
        success "Подключение по порту ${new_port} работает"
    else
        # Диагностика — повторяем с -v
        local _diag
        _diag=$(timeout 10 ssh -v -i "$HOME/.ssh/id_ed25519" \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            -o PasswordAuthentication=no \
            -p "$new_port" \
            "${SERVER_USER}@${SERVER_IP}" "echo ok" 2>&1)
        echo "$_diag" | grep -iE "error|closed|refused|denied" | tail -5
        warn "Не удалось подключиться по новому порту."
        warn "Откатываем..."
        local _rollback_cmd="sed -i '/^Port /d' /etc/ssh/sshd_config && echo 'Port ${old_port}' >> /etc/ssh/sshd_config && (command -v ufw &>/dev/null && ufw allow ${old_port}/tcp > /dev/null 2>&1 && ufw delete allow ${new_port}/tcp > /dev/null 2>&1; true) && (systemctl daemon-reload 2>/dev/null; systemctl restart ssh.socket 2>/dev/null || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null)"
        if ! ssh_run -- "$_rollback_cmd" 2>/dev/null; then
            local _saved_port="$SERVER_PORT"
            SERVER_PORT="$new_port"
            ssh_run -- "$_rollback_cmd" 2>/dev/null
            SERVER_PORT="$_saved_port"
        fi
        warn "Порт возвращён на ${old_port}. Hardening прерван."
        return 1
    fi

    # Обновляем config.json
    jq_w --arg n "$NODE_NAME" --argjson p "$new_port" \
        '.nodes |= [.[] | if .name==$n then .port=$p | .auth="key" | del(.pass) else . end]'

    # Обновляем глобальные переменные
    SERVER_PORT="$new_port"
    SERVER_AUTH="key"
    SERVER_PASS=""
}

ssh_hardening() {
    echo ""
    echo -e "${CYAN}  ── SSH Hardening ──────────────────────────${NC}"
    echo -e "  Нода:  ${GREEN}${NODE_NAME}${NC} (${SERVER_IP}:${SERVER_PORT})"
    echo -e "  Auth:  ${SERVER_AUTH}"
    echo ""

    # Проверка — уже захардено?
    if [[ "$SERVER_AUTH" == "key" && "$SERVER_PORT" != "22" ]]; then
        warn "SSH hardening уже выполнен (ключ + порт ${SERVER_PORT})."
        confirm_yn "Выполнить повторно?" || return
    fi

    echo -e "  Что будет сделано:"
    echo -e "  ${GREEN}1.${NC} Сгенерируется SSH-ключ (если ещё нет) и скопируется на сервер"
    echo -e "  ${GREEN}2.${NC} Вход по паролю будет запрещён (только по ключу)"
    echo -e "  ${GREEN}3.${NC} SSH-порт сменится с ${SERVER_PORT} на случайный (49152-65535)"
    echo ""
    confirm_yn "Продолжить?" Y || return

    echo ""

    # Шаг 1: SSH-ключ
    _harden_setup_key || return

    # Шаг 2: Отключение пароля
    _harden_disable_password || return

    # Шаг 3: Смена порта (включает restart sshd и обновление config.json)
    if ! _harden_change_port; then
        # Шаг 3 провалился — откатываем шаг 2 (восстанавливаем вход по паролю)
        warn "Восстанавливаем вход по паролю..."
        _harden_restore_password
        return 1
    fi

    echo ""
    success "SSH Hardening завершён!"
    echo -e "  Ключ:  ${GREEN}~/.ssh/id_ed25519${NC}"
    echo -e "  Порт:  ${GREEN}${SERVER_PORT}${NC}"
    echo -e "  Пароль: ${RED}отключён${NC}"
    echo ""
}
