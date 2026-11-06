#!/bin/bash
# Keep saved server-side contacts aligned with the Let's Encrypt account.

# Outputs private backup and staged replacement through globals. Never reads the
# configuration as shell code (the Telegram state may contain secrets).
_essence_acme_stage() {
    local file="$1" key="$2" email="$3" line count=0 value="" enabled="" stage backup
    ESSENCE_ACME_STAGE=""
    ESSENCE_ACME_BACKUP=""
    [[ -e "$file" || -L "$file" ]] || return 0
    [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$key="* ]]; then
            count=$((count + 1))
            value="${line#*=}"
        fi
        if [[ "$key" == TELEGRAM_WEB_EMAIL && "$line" == TELEGRAM_WEB_ENABLED=* ]]; then
            enabled="${line#*=}"
        fi
    done < "$file" || return 1
    [[ "$count" == 1 ]] || return 1
    if [[ "$key" == TELEGRAM_WEB_EMAIL ]]; then
        [[ "$enabled" == true || "$enabled" == false ]] || return 1
        [[ "$enabled" == true || -z "$value" ]] || return 1
    fi
    [[ -z "$value" ]] || acme_email_valid "$value" || return 1
    backup=$(umask 077; mktemp "${file}.backup.XXXXXX") || return 1
    stage=""
    if ! cp -p "$file" "$backup" || ! chmod 0600 "$backup"; then
        rm -f "$backup" "$stage"
        return 1
    fi
    if [[ -n "$value" && "$value" != "$email" ]]; then
        stage=$(umask 077; mktemp "${file}.stage.XXXXXX") || { rm -f "$backup"; return 1; }
        if ! while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "$key="* ]]; then
                printf '%s=%s\n' "$key" "$email"
            else
                printf '%s\n' "$line"
            fi
        done < "$backup" > "$stage" || ! chmod 0600 "$stage"; then
            rm -f "$backup" "$stage"
            return 1
        fi
    fi
    ESSENCE_ACME_BACKUP="$backup"
    ESSENCE_ACME_STAGE="$stage"
}

ensure_essence_acme_email() {
    local email="$1" old_email="" old_registered=false ca_conf i failed=false rollback_failed=false attempted=false status
    local paths=("${ACME_REALITY_CONF:-/etc/mihomo/reality.conf}" "${TPROXY_CONF:-/etc/tproxy-server/essence.conf}")
    local keys=(EMAIL TELEGRAM_WEB_EMAIL) stages=("" "") backups=("" "") replaced=(false false)
    acme_email_valid "$email" || { warn "Некорректный ACME email."; return 1; }
    ca_conf=$(_acme_ca_conf)
    _acme_conf_value "$ca_conf" ACCOUNT_URL
    status=$?
    if (( status == 2 )); then
        warn "Не удалось прочитать аккаунт Let's Encrypt."
        return 1
    fi
    if (( status == 0 )) && [[ -n "$ACME_CONF_VALUE" ]]; then
        old_registered=true
    fi
    if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
        _acme_current_email && old_email="$ACME_CURRENT_EMAIL"
    fi
    for (( i=0; i<2; i++ )); do
        if ! _essence_acme_stage "${paths[i]}" "${keys[i]}" "$email"; then
            failed=true
            break
        fi
        stages[i]="$ESSENCE_ACME_STAGE"
        backups[i]="$ESSENCE_ACME_BACKUP"
    done
    if [[ "$failed" == true ]]; then
        warn "Не удалось подготовить конфигурации для смены ACME email. Аккаунт не изменён."
    else
        attempted=true
        if ! ensure_acme_installed "$email"; then
            failed=true
        else
            for (( i=0; i<2; i++ )); do
                [[ -n "${stages[i]}" ]] || continue
                if ! mv -f "${stages[i]}" "${paths[i]}"; then
                    failed=true
                    warn "Не удалось сохранить ACME email в конфигурации."
                    break
                fi
                stages[i]=""
                replaced[i]=true
            done
        fi
    fi
    if [[ "$failed" == true ]]; then
        for (( i=0; i<2; i++ )); do
            if [[ "${replaced[i]}" == true ]] && ! mv -f "${backups[i]}" "${paths[i]}"; then
                rollback_failed=true
                warn "Не удалось восстановить конфигурацию ${paths[i]}."
            fi
        done
        if [[ "$attempted" == true && "$old_registered" == true && -n "$old_email" && "$old_email" != "$email" ]]; then
            if ! "$ACME" --update-account --server letsencrypt -m "$old_email" ||
               ! _acme_conf_value "$ca_conf" CA_EMAIL || [[ "$ACME_CONF_VALUE" != "$old_email" ]]; then
                rollback_failed=true
                warn "Не удалось восстановить прежний контакт Let's Encrypt."
            fi
        elif [[ "$attempted" == true && "$old_registered" == false ]]; then
            warn "Аккаунт Let's Encrypt мог быть зарегистрирован; прежнего контакта для отката нет."
        elif [[ "$attempted" == true && -z "$old_email" ]]; then
            warn "Контакт Let's Encrypt мог измениться; прежний контакт неизвестен, автоматический откат невозможен."
        fi
        [[ "$rollback_failed" == false ]] || warn "Откат ACME email завершился с ошибкой; проверьте аккаунт и конфигурации вручную."
    fi
    for (( i=0; i<2; i++ )); do
        [[ -z "${stages[i]}" ]] || rm -f "${stages[i]}"
        [[ -z "${backups[i]}" ]] || rm -f "${backups[i]}"
    done
    [[ "$failed" == false ]]
}
