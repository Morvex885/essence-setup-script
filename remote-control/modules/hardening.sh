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
        menu_item 1 "Повторить подключение" CYAN
        menu_item 2 "Продолжить — настроить ноды позже" YELLOW
        menu_item 3 "Отменить и откатить изменения" RED
        box_bot
        echo ""
        IFS= read -rp "  Выберите действие: " choice || return 2
        choice="${choice%$'\r'}"
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
    local provision_keys=false restore_ok
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
                    restore_ok=true
                    if [[ "$known_existed" == true ]]; then
                        [[ -f "$known_backup" ]] && cp "$known_backup" "$SSH_KNOWN_HOSTS" || restore_ok=false
                    else
                        rm -f "$SSH_KNOWN_HOSTS" || restore_ok=false
                    fi
                    if [[ -n "$manifest_backup" ]]; then
                        [[ -f "$manifest_backup" ]] && cp "$manifest_backup" "$STATE_MANIFEST" || restore_ok=false
                    fi
                    if [[ "$restore_ok" == true ]]; then
                        rm -f "$known_backup" "$manifest_backup"
                    else
                        warn "Не удалось восстановить SSH-настройку. Резервные копии оставлены: $known_backup $manifest_backup"
                    fi
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
            warn "Не удалось закрепить SSH-ключ ноды '${NODE_NAME}'."
            _portable_onboarding_choice
            choice=$?
            if [[ $choice -eq 0 ]]; then continue
            elif [[ $choice -eq 1 ]]; then
                state_portability_add_issue "$id" missing_host_key || return 1
                break
            else
                restore_ok=true
                if [[ "$known_existed" == true ]]; then
                    [[ -f "$known_backup" ]] && cp "$known_backup" "$SSH_KNOWN_HOSTS" || restore_ok=false
                else
                    rm -f "$SSH_KNOWN_HOSTS" || restore_ok=false
                fi
                if [[ -n "$manifest_backup" ]]; then
                    [[ -f "$manifest_backup" ]] && cp "$manifest_backup" "$STATE_MANIFEST" || restore_ok=false
                fi
                if [[ "$restore_ok" == true ]]; then
                    rm -f "$known_backup" "$manifest_backup"
                else
                    warn "Не удалось восстановить SSH-настройку. Резервные копии оставлены: $known_backup $manifest_backup"
                fi
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
            restore_ok=true
            if [[ "$known_existed" == true ]]; then
                [[ -f "$known_backup" ]] && cp "$known_backup" "$SSH_KNOWN_HOSTS" || restore_ok=false
            else
                rm -f "$SSH_KNOWN_HOSTS" || restore_ok=false
            fi
            if [[ -n "$manifest_backup" ]]; then
                [[ -f "$manifest_backup" ]] && cp "$manifest_backup" "$STATE_MANIFEST" || restore_ok=false
            fi
            if [[ "$restore_ok" == true ]]; then
                rm -f "$known_backup" "$manifest_backup"
            else
                warn "Не удалось восстановить SSH-настройку. Резервные копии оставлены: $known_backup $manifest_backup"
            fi
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
        -o BatchMode=yes -o IdentitiesOnly=yes -i "$private" -p "$SERVER_PORT")
    if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
        # During onboarding accept-new is scoped to this managed known_hosts;
        # normal GitHub sessions remain strict in ssh.sh.
        verify_options=(-o StrictHostKeyChecking=accept-new
            -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}"
            -o ConnectTimeout=10 -o PasswordAuthentication=no
            -o BatchMode=yes -o IdentitiesOnly=yes -i "$private" -p "$SERVER_PORT")
    else
        verify_options=(-o StrictHostKeyChecking=accept-new
            -o ConnectTimeout=10 -o PasswordAuthentication=no
            -o BatchMode=yes -o IdentitiesOnly=yes -i "$private" -p "$SERVER_PORT")
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
       ! mv "$public" "$SSH_IDENTITIES_DIR/$node_id.pub" ||
       ! chmod 600 "$SSH_IDENTITIES_DIR/$node_id" ||
       ! chmod 644 "$SSH_IDENTITIES_DIR/$node_id.pub"; then
        [[ "$remote_installed" == true ]] && _revoke_managed_remote_key_value "$pubkey" >/dev/null 2>&1 || true
        rm -f "$SSH_IDENTITIES_DIR/$node_id" "$SSH_IDENTITIES_DIR/$node_id.pub"
        rm -rf "$tmp_dir"
        warn "Не удалось установить переносимый SSH-ключ в локальное хранилище."
        return 1
    fi
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
        if ! state_checkpoint; then
            warn "SSH-ключ сохранён, но точку восстановления сохранить не удалось; дальнейшая настройка остановлена."
            return 1
        fi
    fi
    success "Переносимый SSH-ключ установлен"
}

_harden_setup_key() {
    _provision_portable_identity "${NODE_ID:-}" || return 1
}

# Hardening uses the just-verified identity even for local nodes, whose normal
# SSH sessions deliberately keep the existing system/agent-key policy.
_harden_ssh_run() {
    local SERVER_AUTH=key SERVER_PASS=""
    ssh_run -i "$SSH_IDENTITIES_DIR/$NODE_IDENTITY" \
        -o IdentitiesOnly=yes -o BatchMode=yes -o PasswordAuthentication=no -- "$@"
}

_harden_disable_password() {
    info "Отключаем вход по паролю на сервере..."
    _harden_ssh_run "
        sed -i '/^#\\?PubkeyAuthentication/d' /etc/ssh/sshd_config &&
        sed -i '/^#\\?PasswordAuthentication/d' /etc/ssh/sshd_config &&
        sed -i '/^#\\?ChallengeResponseAuthentication/d' /etc/ssh/sshd_config &&
        echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config &&
        echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config &&
        echo 'ChallengeResponseAuthentication no' >> /etc/ssh/sshd_config
    " || { warn "Не удалось изменить sshd_config."; return 1; }
    success "Вход по паролю отключён (ожидает перезапуска SSH-сервиса)"
}

_harden_restore_password() {
    _harden_ssh_run "
        sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config &&
        sed -i '/^ChallengeResponseAuthentication/d' /etc/ssh/sshd_config &&
        echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config &&
        sshd -t &&
        (systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null)
    " 2>/dev/null
}

_harden_select_port() {
    HARDEN_NEW_PORT=""
    local new_port="" attempts=0 occupied custom_port
    while (( attempts < 5 )); do
        new_port=$(( RANDOM % 16384 + 49152 ))
        occupied=$(ssh_run -- "ss -tlnp > /dev/null || exit 1; if ss -tlnp | grep -q ':${new_port}\b'; then echo occupied; else echo free; fi" 2>/dev/null) || {
            warn "Не удалось проверить занятость SSH-порта на ноде."
            return 1
        }
        occupied="${occupied%$'\r'}"
        [[ "$occupied" == free ]] && break
        [[ "$occupied" == occupied ]] || return 1
        new_port=""
        attempts=$((attempts + 1))
    done
    [[ -n "$new_port" ]] || { warn "Не удалось найти свободный порт."; return 1; }
    IFS= read -rp "  SSH-порт [Enter = $new_port]: " custom_port || return 1
    custom_port="${custom_port%$'\r'}"
    if [[ -n "$custom_port" ]]; then
        [[ "$custom_port" =~ ^[1-9][0-9]{0,4}$ ]] && (( custom_port <= 65535 )) || {
            warn "Порт должен быть числом от 1 до 65535."
            return 1
        }
        new_port="$custom_port"
        occupied=$(ssh_run -- "ss -tlnp > /dev/null || exit 1; if ss -tlnp | grep -q ':${new_port}\b'; then echo occupied; else echo free; fi" 2>/dev/null) || {
            warn "Не удалось проверить занятость SSH-порта на ноде."
            return 1
        }
        [[ "${occupied%$'\r'}" == free ]] || { warn "Порт ${new_port} занят или его состояние неизвестно."; return 1; }
    fi
    HARDEN_NEW_PORT="$new_port"
}

_harden_rollback_port() {
    local old_port="$1" new_port="$2" rollback_ok=false
    local rollback_cmd="
        sed -i '/^Port /d' /etc/ssh/sshd_config &&
        echo 'Port ${old_port}' >> /etc/ssh/sshd_config || exit 1
        if command -v ufw >/dev/null 2>&1; then
            ufw allow ${old_port}/tcp >/dev/null 2>&1 &&
            ufw delete allow ${new_port}/tcp >/dev/null 2>&1 || exit 1
        fi
        if command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port=${old_port}/tcp >/dev/null 2>&1 &&
            firewall-cmd --permanent --remove-port=${new_port}/tcp >/dev/null 2>&1 &&
            firewall-cmd --reload >/dev/null 2>&1 || exit 1
        fi
        sshd -t &&
        systemctl daemon-reload &&
        (systemctl restart ssh.socket 2>/dev/null || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null)
    "
    SERVER_PORT="$old_port"
    if _harden_ssh_run "$rollback_cmd" 2>/dev/null; then
        rollback_ok=true
    else
        SERVER_PORT="$new_port"
        _harden_ssh_run "$rollback_cmd" 2>/dev/null && rollback_ok=true
    fi
    SERVER_PORT="$old_port"
    local verify
    if [[ "$rollback_ok" == true ]] &&
       verify=$(_harden_ssh_run "echo ok" 2>/dev/null) &&
       [[ "${verify%$'\r'}" == ok ]]; then
        warn "SSH-порт возвращён на $old_port. Усиление защиты SSH прервано."
        return 0
    fi
    warn "Не удалось подтвердить возврат SSH-порта. Проверьте порты $old_port и $new_port через консоль провайдера."
    return 1
}

_harden_change_port() {
    local old_port="$SERVER_PORT" new_port="$1"
    info "Меняем SSH-порт на ${new_port}..."
    if ! _harden_ssh_run "
        sed -i '/^#\\?Port /d' /etc/ssh/sshd_config &&
        echo 'Port ${new_port}' >> /etc/ssh/sshd_config || exit 1
        if command -v ufw >/dev/null 2>&1; then
            ufw allow ${new_port}/tcp >/dev/null 2>&1 &&
            ufw delete allow OpenSSH >/dev/null 2>&1 &&
            ufw delete allow 22/tcp >/dev/null 2>&1 &&
            ufw delete allow ${old_port}/tcp >/dev/null 2>&1 || exit 1
        fi
        if command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port=${new_port}/tcp >/dev/null 2>&1 &&
            firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1 &&
            firewall-cmd --permanent --remove-port=${old_port}/tcp >/dev/null 2>&1 &&
            firewall-cmd --reload >/dev/null 2>&1 || exit 1
        fi
        sshd -t &&
        systemctl daemon-reload &&
        (systemctl restart ssh.socket 2>/dev/null || systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null)
    "; then
        warn "Не удалось применить новый SSH-порт."
        _harden_rollback_port "$old_port" "$new_port" || true
        return 1
    fi
    sleep 3
    local verify
    SERVER_PORT="$new_port"
    if ! verify=$(_harden_ssh_run "echo ok" 2>/dev/null) || [[ "${verify%$'\r'}" != ok ]]; then
        SERVER_PORT="$old_port"
        warn "Не удалось подключиться по новому порту."
        _harden_rollback_port "$old_port" "$new_port" || true
        return 1
    fi
    if ! jq_w --arg id "$NODE_ID" --argjson p "$new_port" --arg identity "$NODE_ID" \
        '.nodes |= map(if .id==$id then .port=$p | .auth="key" | .identity=$identity | .secret_id=null else . end)'; then
        SERVER_PORT="$old_port"
        warn "Не удалось сохранить параметры усиления защиты SSH."
        _harden_rollback_port "$old_port" "$new_port" || true
        return 1
    fi
    SERVER_AUTH=key; SERVER_PASS=""
    success "Подключение по порту ${new_port} работает"
    return 0
}
ssh_hardening() {
    _harden_select_port || return 1
    local lines=("Нода: $NODE_NAME  $SERVER_IP:$SERVER_PORT" "Пользователь: $SERVER_USER"
        "Ключ: $SSH_IDENTITIES_DIR/$NODE_ID" "Порт: $SERVER_PORT → $HARDEN_NEW_PORT"
        "Вход по паролю будет отключён."
        "Будет установлен SSH-ключ и изменены правила firewall для SSH."
        "При сбое может потребоваться консоль провайдера.")
    if [[ "$SERVER_AUTH" == key && "$SERVER_PORT" != 22 ]]; then
        lines+=("Усиление защиты SSH уже выполнено; настройки будут изменены повторно.")
    fi
    review_frame "Усиление защиты SSH" "${lines[@]}"
    confirm_yn "Усилить защиту SSH?" N || return 0
    _harden_setup_key || return 1
    if ! _harden_disable_password || ! _harden_change_port "$HARDEN_NEW_PORT"; then
        warn "Восстанавливаем вход по паролю..."
        _harden_restore_password || warn "Не удалось восстановить вход по паролю. Используйте консоль провайдера."
        return 1
    fi
    if ! node_secret_delete "$NODE_ID"; then
        warn "Порт и SSH-ключ сохранены, но старый пароль не удалось удалить из локального состояния."
        return 1
    fi
    success "Усиление защиты SSH завершено!"
    info "Ключ: $SSH_IDENTITIES_DIR/$NODE_ID"
    info "Порт: $SERVER_PORT; вход по паролю отключён."
    return 0
}
