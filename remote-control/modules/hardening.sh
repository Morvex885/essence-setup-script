#!/bin/bash
# ─── SSH Hardening: ключ + отключение пароля + смена порта ───────────────────

_revoke_managed_remote_key_value() {
    local pubkey="${1:-}" old_onboarding rc
    [[ -n "$pubkey" ]] || return 1
    old_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
    SSH_ALLOW_PORTABLE_ONBOARDING=1
    ssh_run -- "if [ -f ~/.ssh/authorized_keys ]; then
        _essence_tmp=\$(mktemp ~/.ssh/authorized_keys.XXXXXX) &&
        awk -v key='$pubkey' '\$0 != key' ~/.ssh/authorized_keys > \"\$_essence_tmp\" &&
        cat \"\$_essence_tmp\" > ~/.ssh/authorized_keys &&
        rm -f \"\$_essence_tmp\"
    fi"
    rc=$?
    SSH_ALLOW_PORTABLE_ONBOARDING="$old_onboarding"
    return "$rc"
}

_revoke_managed_remote_key() {
    local node_id="${1:-}" pubfile pubkey
    [[ -n "$node_id" ]] || return 1
    pubfile="${SSH_IDENTITIES_DIR:-}/$node_id.pub"
    [[ -f "$pubfile" ]] || return 1
    pubkey=$(cat "$pubfile") || return 1
    _revoke_managed_remote_key_value "$pubkey"
}

_portable_onboarding_choice() {
    local choice
    while true; do
        echo ""
        box_top
        box_center "Подключение не выполнено"
        box_mid
        box_line " 1) Повторить подключение" " ${GREEN}1)${NC} Повторить подключение"
        box_line " 2) Продолжить — настроить ноды позже" " ${YELLOW}2)${NC} Продолжить — настроить ноды позже"
        box_line " 3) Отменить и откатить изменения" " ${RED}3)${NC} Отменить и откатить изменения"
        box_bot
        echo ""
        read -rp "  Выберите действие: " choice
        case "$choice" in
            1) return 0 ;;
            2) return 1 ;;
            3) return 2 ;;
            *) warn "Выберите 1, 2 или 3." ;;
        esac
    done
}

_github_initial_portable_onboarding() {
    [[ "${CONFIG_SOURCE:-local}" == "github" ]] || return 0
    local known_backup="" known_existed=false manifest_backup="" id name choice
    local provision_keys=false
    local -a key_ids=() installed_ids=()
    local -a node_rows=()
    if [[ -f "${SSH_KNOWN_HOSTS:-}" ]]; then
        known_existed=true
        known_backup=$(umask 077; mktemp "${CONFIG_DIR:-/tmp}/.known-hosts.XXXXXX") || return 1
        cp "$SSH_KNOWN_HOSTS" "$known_backup" || { rm -f "$known_backup"; return 1; }
    fi
    if [[ -f "${STATE_MANIFEST:-}" ]]; then
        manifest_backup=$(umask 077; mktemp "${CONFIG_DIR:-/tmp}/.manifest.XXXXXX") || {
            rm -f "$known_backup"
            return 1
        }
        cp "$STATE_MANIFEST" "$manifest_backup" || {
            rm -f "$known_backup" "$manifest_backup"
            return 1
        }
    fi
    while IFS=$'\t' read -r id name; do
        [[ -n "$id" ]] && node_rows+=("$id"$'\t'"$name")
        if [[ -n "$id" ]] && [[ "$(jq_r --arg id "$id" '.nodes[] | select(.id==$id) | (.auth=="key" and ((.identity // "system")=="system"))')" == true ]]; then
            key_ids+=("$id")
        fi
    done < <(jq_r '.nodes[] | [.id,.name] | @tsv')
    if [[ ${#key_ids[@]} -gt 0 ]]; then
        echo "Ноды с авторизацией по ключу без переносимого SSH-ключа:"
        for id in "${key_ids[@]}"; do
            name=$(jq_r --arg id "$id" '.nodes[] | select(.id==$id) | .name')
            echo "  - $name"
        done
        if confirm_yn "Создать переносимый SSH-ключ для этих нод?" N; then
            provision_keys=true
        fi
    fi
    if [[ "$provision_keys" != true ]]; then
        for id in "${key_ids[@]}"; do
            state_portability_add_issue "$id" missing_identity || return 1
        done
    else
        for id in "${key_ids[@]}"; do
            while true; do
                name=$(jq_r --arg id "$id" '.nodes[] | select(.id==$id) | .name')
                node_load_by_name "$name" || return 1
                local previous_defer="${PORTABLE_IDENTITY_DEFER_CONFIG:-0}"
                local previous_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
                PORTABLE_IDENTITY_DEFER_CONFIG=1
                SSH_ALLOW_PORTABLE_ONBOARDING=1
                _provision_portable_identity "$id"
                local provision_rc=$?
                PORTABLE_IDENTITY_DEFER_CONFIG="$previous_defer"
                SSH_ALLOW_PORTABLE_ONBOARDING="$previous_onboarding"
                if [[ $provision_rc -eq 0 ]]; then
                    installed_ids+=("$id")
                    break
                fi
                _portable_onboarding_choice
                choice=$?
                if [[ $choice -eq 0 ]]; then
                    continue
                elif [[ $choice -eq 1 ]]; then
                    state_portability_add_issue "$id" missing_identity || return 1
                    break
                else
                    for name in "${installed_ids[@]}"; do
                        node_load_by_name "$(jq_r --arg id "$name" '.nodes[] | select(.id==$id) | .name')" || continue
                        _revoke_managed_remote_key "$name" ||
                            warn "Не удалось отозвать переносимый SSH-ключ ноды «${NODE_NAME:-$name}»."
                        rm -f "$SSH_IDENTITIES_DIR/$name" "$SSH_IDENTITIES_DIR/$name.pub"
                    done
                    if [[ "$known_existed" == true ]]; then cp "$known_backup" "$SSH_KNOWN_HOSTS"; else rm -f "$SSH_KNOWN_HOSTS"; fi
                    [[ -f "$manifest_backup" ]] && cp "$manifest_backup" "$STATE_MANIFEST"
                    rm -f "$known_backup" "$manifest_backup"
                    return 1
                fi
            done
        done
    fi
    for name in "${node_rows[@]}"; do
        id="${name%%$'\t'*}"
        name="${name#*$'\t'}"
        node_load_by_name "$name" || return 1
        if [[ "$id" == "" ]]; then continue; fi
        NODE_ID="$id"
        if [[ ${#installed_ids[@]} -gt 0 ]] && [[ " ${installed_ids[*]} " == *" $id "* ]]; then NODE_IDENTITY="$id"; fi
        if _ssh_known_host_present; then
            state_portability_remove_issue "$id" missing_host_key || return 1
            continue
        fi
        while true; do
            local previous_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
            SSH_ALLOW_PORTABLE_ONBOARDING=1
            _ssh_pin_host_key
            local pin_rc=$?
            SSH_ALLOW_PORTABLE_ONBOARDING="$previous_onboarding"
            if [[ $pin_rc -eq 0 ]]; then
                state_portability_remove_issue "$id" missing_host_key || return 1
                break
            fi
            warn "Не удалось закрепить ключ сервера ноды '${NODE_NAME}'."
            _portable_onboarding_choice
            choice=$?
            if [[ $choice -eq 0 ]]; then continue
            elif [[ $choice -eq 1 ]]; then
                state_portability_add_issue "$id" missing_host_key || return 1
                break
            else
                if [[ "$known_existed" == true ]]; then cp "$known_backup" "$SSH_KNOWN_HOSTS"; else rm -f "$SSH_KNOWN_HOSTS"; fi
                [[ -f "$manifest_backup" ]] && cp "$manifest_backup" "$STATE_MANIFEST"
                rm -f "$known_backup" "$manifest_backup"
                for name in "${installed_ids[@]}"; do
                    node_load_by_name "$(jq_r --arg id "$name" '.nodes[] | select(.id==$id) | .name')" || continue
                    _revoke_managed_remote_key "$name" ||
                        warn "Не удалось отозвать переносимый SSH-ключ ноды «${NODE_NAME:-$name}»."
                    rm -f "$SSH_IDENTITIES_DIR/$name" "$SSH_IDENTITIES_DIR/$name.pub"
                done
                return 1
            fi
        done
    done
    if [[ ${#installed_ids[@]} -gt 0 ]]; then
        local ids_json previous_candidate_allow="${CONFIG_PERSIST_ALLOW_NEEDS_SETUP:-0}"
        ids_json=$(printf '%s\n' "${installed_ids[@]}" | jq -R . | jq -s .) || return 1
        CONFIG_PERSIST_ALLOW_NEEDS_SETUP=1
        jq_w --argjson ids "$ids_json" \
            '.nodes |= map(.id as $id | if ($ids | index($id)) then .identity=$id else . end)'
        local identity_write_rc=$?
        CONFIG_PERSIST_ALLOW_NEEDS_SETUP="$previous_candidate_allow"
        if [[ $identity_write_rc -ne 0 ]]; then
            if [[ "$known_existed" == true ]]; then cp "$known_backup" "$SSH_KNOWN_HOSTS"; else rm -f "$SSH_KNOWN_HOSTS"; fi
            [[ -f "$manifest_backup" ]] && cp "$manifest_backup" "$STATE_MANIFEST"
            rm -f "$known_backup" "$manifest_backup"
            for name in "${installed_ids[@]}"; do
                node_load_by_name "$(jq_r --arg id "$name" '.nodes[] | select(.id==$id) | .name')" || continue
                _revoke_managed_remote_key "$name" ||
                    warn "Не удалось отозвать переносимый SSH-ключ ноды «${NODE_NAME:-$name}»."
                rm -f "$SSH_IDENTITIES_DIR/$name" "$SSH_IDENTITIES_DIR/$name.pub"
            done
            return 1
        fi
        for id in "${installed_ids[@]}"; do
            state_portability_remove_issue "$id" missing_identity || return 1
        done
    fi
    rm -f "$known_backup" "$manifest_backup"
    return 0
}

complete_portable_node_setup() {
    if [[ "${CONFIG_SOURCE:-local}" != github ]]; then
        warn "Отложенная SSH-настройка доступна только для источника GitHub."
        return 1
    fi
    if ! state_actionable_ssh_setup_pending; then
        warn "Отложенной SSH-настройки ключей для нод нет."
        return 1
    fi
    _github_initial_portable_onboarding || return 1
    local status
    status=$(state_validate true 2>/dev/null) || {
        warn "Не удалось проверить SSH-настройку нод для синхронизации через GitHub."
        return 1
    }
    if [[ "$status" == ready ]]; then
        success "Отложенная SSH-настройка нод завершена: SSH-ключи и ключи серверов готовы для синхронизации через GitHub."
    elif state_actionable_ssh_setup_pending; then
        warn "Для части нод SSH-настройка всё ещё отложена. Повторите действие H позже."
    else
        warn "SSH-ключи настроены, но другим нодам требуются защищённые данные для входа."
    fi
}

_provision_portable_identity() {
    local node_id="${1:-}"
    [[ -n "$node_id" ]] || { warn "Не найден стабильный идентификатор ноды."; return 1; }
    local runtime_root="${CONFIG_DIR:-${TMPDIR:-/tmp}}"
    local tmp_dir remote_installed=false
    tmp_dir=$(umask 077; mktemp -d "$runtime_root/.identity.XXXXXX") || {
        warn "Не удалось создать временную директорию для SSH-ключа."
        return 1
    }
    local private="$tmp_dir/$node_id" public="$tmp_dir/$node_id.pub"
    if ! ssh-keygen -t ed25519 -f "$private" -N "" -C "essence:${node_id}" -q; then
        rm -rf "$tmp_dir"
        warn "Не удалось сгенерировать переносимый SSH-ключ."
        return 1
    fi

    local pubkey
    pubkey=$(cat "$public") || { rm -rf "$tmp_dir"; return 1; }
    info "Копируем открытый переносимый SSH-ключ на сервер..."
    local _previous_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
    if ! ssh_run -- "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && { grep -qxF '$pubkey' ~/.ssh/authorized_keys || printf '%s\\n' '$pubkey' >> ~/.ssh/authorized_keys; }"; then
        SSH_ALLOW_PORTABLE_ONBOARDING="$_previous_onboarding"
        rm -rf "$tmp_dir"
        warn "Не удалось скопировать переносимый SSH-ключ на сервер."
        return 1
    fi
    remote_installed=true
    SSH_ALLOW_PORTABLE_ONBOARDING="$_previous_onboarding"

    local verify_options=(-o ConnectTimeout=10 -o PasswordAuthentication=no
        -o IdentitiesOnly=yes -i "$private" -p "$SERVER_PORT")
    if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
        # During onboarding accept-new is scoped to this managed known_hosts;
        # normal GitHub sessions remain strict in ssh.sh.
        verify_options=(-o StrictHostKeyChecking=accept-new
            -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}"
            -o ConnectTimeout=10 -o PasswordAuthentication=no
            -o IdentitiesOnly=yes -i "$private" -p "$SERVER_PORT")
    else
        verify_options=(-o StrictHostKeyChecking=accept-new
            -o ConnectTimeout=10 -o PasswordAuthentication=no
            -o IdentitiesOnly=yes -i "$private" -p "$SERVER_PORT")
    fi
    info "Проверяем авторизацию по переносимому SSH-ключу..."
    if ! run_with_timeout 10 ssh "${verify_options[@]}" \
        "${SERVER_USER}@${SERVER_IP}" "echo ok" &>/dev/null; then
        [[ "$remote_installed" == true ]] && _revoke_managed_remote_key_value "$pubkey" >/dev/null 2>&1 || true
        rm -rf "$tmp_dir"
        warn "Авторизация по переносимому SSH-ключу не работает."
        return 1
    fi
    mkdir -p "$SSH_IDENTITIES_DIR" && chmod 700 "$SSH_IDENTITIES_DIR" || {
        [[ "$remote_installed" == true ]] && _revoke_managed_remote_key_value "$pubkey" >/dev/null 2>&1 || true
        rm -rf "$tmp_dir"
        return 1;
    }
    if ! mv "$private" "$SSH_IDENTITIES_DIR/$node_id" ||
       ! mv "$public" "$SSH_IDENTITIES_DIR/$node_id.pub"; then
        [[ "$remote_installed" == true ]] && _revoke_managed_remote_key_value "$pubkey" >/dev/null 2>&1 || true
        rm -f "$SSH_IDENTITIES_DIR/$node_id" "$SSH_IDENTITIES_DIR/$node_id.pub"
        rm -rf "$tmp_dir"
        warn "Не удалось установить переносимый SSH-ключ в локальное хранилище."
        return 1
    fi
    chmod 600 "$SSH_IDENTITIES_DIR/$node_id"
    chmod 644 "$SSH_IDENTITIES_DIR/$node_id.pub"
    rm -rf "$tmp_dir"

    if [[ "${PORTABLE_IDENTITY_DEFER_CONFIG:-0}" != "1" ]] &&
       ! jq_w --arg id "$node_id" --arg identity "$node_id" \
        '.nodes |= map(if .id==$id then .identity=$identity else . end)'; then
        [[ "$remote_installed" == true ]] && _revoke_managed_remote_key_value "$pubkey" >/dev/null 2>&1 || true
        rm -f "$SSH_IDENTITIES_DIR/$node_id" "$SSH_IDENTITIES_DIR/$node_id.pub"
        warn "Не удалось сохранить ссылку на переносимый SSH-ключ."
        return 1
    fi
    NODE_IDENTITY="$node_id"
    if [[ "${PORTABLE_IDENTITY_DEFER_CONFIG:-0}" != "1" ]]; then
        state_checkpoint >/dev/null 2>&1 || true
    fi
    success "Переносимый SSH-ключ установлен"
}

_harden_setup_key() {
    _provision_portable_identity "${NODE_ID:-}" || return 1
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
    success "Вход по паролю отключён (ожидает перезапуска SSH-сервиса)"
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
    info "Перезапускаем SSH-сервис..."
    ssh_run -- "
        systemctl daemon-reload 2>/dev/null
        systemctl restart ssh.socket 2>/dev/null || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null
    " || { warn "Не удалось перезапустить SSH-сервис."; return 1; }

    # Ждём пока sshd перезапустится
    sleep 3

    # Проверяем подключение по новому порту явным managed ключом.
    info "Проверяем подключение на порту ${new_port}..."
    local _verify_opts=(-o StrictHostKeyChecking=accept-new
        -o ConnectTimeout=10 -o PasswordAuthentication=no
        -o IdentitiesOnly=yes -i "$SSH_IDENTITIES_DIR/$NODE_ID" -p "$new_port")
    [[ "${CONFIG_SOURCE:-local}" == "github" ]] && _verify_opts=(-o StrictHostKeyChecking=yes
        -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}" -o ConnectTimeout=10
        -o PasswordAuthentication=no -o IdentitiesOnly=yes
        -i "$SSH_IDENTITIES_DIR/$NODE_ID" -p "$new_port")
    local _verify_ok
    _verify_ok=$(run_with_timeout 10 ssh "${_verify_opts[@]}" \
        "${SERVER_USER}@${SERVER_IP}" "echo ok" 2>/dev/null)
    if [[ "$_verify_ok" == *"ok"* ]]; then
        success "Подключение по порту ${new_port} работает"
    else
        # Диагностика — повторяем с -v.
        local _diag
        _diag=$(run_with_timeout 10 ssh -v "${_verify_opts[@]}" \
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
        warn "Порт возвращён на ${old_port}. Усиление защиты SSH прервано."
        return 1
    fi

    # Обновляем config.json только после успешного подключения по новому порту.
    if ! jq_w --arg id "$NODE_ID" --argjson p "$new_port" --arg identity "$NODE_ID" \
        '.nodes |= map(if .id==$id then .port=$p | .auth="key" | .identity=$identity | .secret_id=null else . end)'; then
        warn "Не удалось сохранить параметры усиления защиты SSH."
        return 1
    fi
    node_secret_delete "$NODE_ID" >/dev/null 2>&1 || true

    # Обновляем глобальные переменные.
    SERVER_PORT="$new_port"
    SERVER_AUTH="key"
    SERVER_PASS=""
    NODE_IDENTITY="$NODE_ID"

}
ssh_hardening() {
    echo ""
    echo -e "${CYAN}  ── Усиление защиты SSH ────────────────────${NC}"
    echo -e "  Нода:         ${GREEN}${NODE_NAME}${NC} (${SERVER_IP}:${SERVER_PORT})"
    echo -e "  Авторизация:  ${SERVER_AUTH}"
    echo ""

    # Проверка — уже захардено?
    if [[ "$SERVER_AUTH" == "key" && "$SERVER_PORT" != "22" ]]; then
        warn "Усиление защиты SSH уже выполнено (ключ + порт ${SERVER_PORT})."
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
    success "Усиление защиты SSH завершено!"
    echo -e "  Ключ:  ${GREEN}$SSH_IDENTITIES_DIR/$NODE_ID${NC}"
    echo -e "  Порт:  ${GREEN}${SERVER_PORT}${NC}"
    echo -e "  Пароль: ${RED}отключён${NC}"
    echo ""
}
