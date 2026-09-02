#!/bin/bash
# ─── Хранилище нод (config.json → .nodes[]) ────────────────────────────────

nodes_count() { jq_r '.nodes | length'; }

_pass_key() {
    local mid
    mid=$(cat /etc/machine-id 2>/dev/null || hostname)
    printf '%s' "rcm-${mid}" | openssl dgst -sha256 -r | cut -d' ' -f1
}

node_pass_decode() {
    local key
    key=$(_pass_key)
    printf '%s' "$1" | base64 -d 2>/dev/null \
        | openssl enc -aes-256-cbc -d -pbkdf2 -k "$key" 2>/dev/null
}

node_pass_encode() {
    local key
    key=$(_pass_key)
    printf '%s' "$1" \
        | openssl enc -aes-256-cbc -pbkdf2 -k "$key" 2>/dev/null \
        | base64 | tr -d '\n'
}

node_load() {
    local idx=$(($1 - 1))
    if (( idx < 0 )); then
        warn "Неверный индекс ноды: $1"
        return 1
    fi
    local count
    count=$(nodes_count)
    if (( idx >= count )); then
        warn "Нода #$1 не существует (всего: $count)"
        return 1
    fi
    NODE_ID=$(jq_r --argjson i "$idx" '.nodes[$i].id')
    NODE_NAME=$(jq_r --argjson i "$idx" '.nodes[$i].name')
    SERVER_IP=$(jq_r --argjson i "$idx" '.nodes[$i].ip')
    SERVER_PORT=$(jq_r --argjson i "$idx" '.nodes[$i].port')
    SERVER_USER=$(jq_r --argjson i "$idx" '.nodes[$i].user')
    SERVER_AUTH=$(jq_r --argjson i "$idx" '.nodes[$i].auth // "password"')
    NODE_IDENTITY=$(jq_r --argjson i "$idx" '.nodes[$i].identity // ""')
    NODE_TAG=$(jq_r --argjson i "$idx" '.nodes[$i].tag // ""')
    if [[ "$SERVER_AUTH" == "key" ]]; then
        SERVER_PASS=""
    else
        if ! SERVER_PASS=$(node_secret_get "$NODE_ID"); then
            SERVER_PASS=""
            warn "Не удалось получить пароль SSH для ноды '${NODE_NAME}'."
            return 1
        fi
    fi
}

node_load_by_name() {
    local target="$1"
    local idx
    idx=$(jq_r --arg n "$target" '.nodes | to_entries[] | select(.value.name==$n) | .key')
    [[ -z "$idx" ]] && return 1
    node_load $((idx + 1))
}

# ─── Добавление ноды ─────────────────────────────────────────────────────────
_github_add_abort() {
    local node_id="${1:-}" managed="${2:-false}" known_backup="${3:-}" manifest_backup="${4:-}"
    local existing_name previous_candidate_allow
    existing_name=$(jq_r --arg id "$node_id" '.nodes[] | select(.id==$id) | .name' 2>/dev/null || true)
    if [[ -n "$existing_name" ]]; then
        previous_candidate_allow="${CONFIG_PERSIST_ALLOW_NEEDS_SETUP:-0}"
        CONFIG_PERSIST_ALLOW_NEEDS_SETUP=1
        jq_w --arg id "$node_id" --arg n "$existing_name" '
            .nodes |= [.[] | select(.id != $id)] |
            .connections |= [.[] | select(.node != $n)] |
            .clients |= map(
                (if .nodes then .nodes |= [.[] | select(. != $n)] else . end) |
                (if .connections then .connections |= [.[] | select(.node != $n)] else . end)
            )' >/dev/null 2>&1 || true
        CONFIG_PERSIST_ALLOW_NEEDS_SETUP="$previous_candidate_allow"
    fi
    if [[ "$managed" == true && -n "$node_id" ]] && declare -F _revoke_managed_remote_key >/dev/null 2>&1; then
        _revoke_managed_remote_key "$node_id" >/dev/null 2>&1 ||
            warn "Не удалось отозвать переносимый SSH-ключ ноды «${node_id}»."
    fi
    [[ -n "$node_id" ]] && rm -f "${SSH_IDENTITIES_DIR:-}/$node_id" "${SSH_IDENTITIES_DIR:-}/$node_id.pub"
    [[ -n "$node_id" ]] && node_secret_delete "$node_id" >/dev/null 2>&1 || true
    if [[ -n "$known_backup" && -f "$known_backup" ]]; then
        cp "$known_backup" "$SSH_KNOWN_HOSTS"
    elif [[ -n "${SSH_KNOWN_HOSTS:-}" ]]; then
        rm -f "$SSH_KNOWN_HOSTS"
    fi
    [[ -n "$manifest_backup" && -f "$manifest_backup" ]] && cp "$manifest_backup" "$STATE_MANIFEST"
    rm -f "$known_backup" "$manifest_backup"
}

add_node() {
    echo ""
    echo -e "${CYAN}  ── Добавить ноду ──────────────────────────${NC}"
    read -rp "  Название [vps-1]:  " _name
    _name="${_name:-vps-1}"

    read -rp "  IP сервера:        " _ip
    [[ -z "$_ip" ]] && { warn "IP не может быть пустым."; return; }

    local _port
    while true; do
        read -rp "  Порт SSH [22]:     " _port
        _port="${_port:-22}"
        if [[ "$_port" =~ ^[0-9]+$ ]] &&
           (( _port >= 1 && _port <= 65535 )); then
            break
        fi
        warn "Порт SSH должен быть числом от 1 до 65535."
    done

    read -rp "  Логин [root]:      " _user
    _user="${_user:-root}"

    # Выбор типа авторизации
    local _auth_choice
    while true; do
        echo ""
        echo -e "  Авторизация:"
        echo -e "  ${GREEN}1)${NC} SSH-ключ (рекомендуется)"
        echo -e "  ${GREEN}2)${NC} Пароль"
        read -rp "  Выберите [1]: " _auth_choice
        _auth_choice="${_auth_choice:-1}"
        [[ "$_auth_choice" == 1 || "$_auth_choice" == 2 ]] && break
        warn "Выберите 1 или 2."
    done

    local _auth="key"
    local _pass=""
    local _node_id
    _node_id=$(openssl rand -hex 16 2>/dev/null) || {
        warn "Не удалось создать стабильный идентификатор ноды."
        return 1
    }
    [[ "$_node_id" =~ ^[0-9a-f]{32}$ ]] || {
        warn "Генератор ID ноды вернул некорректное значение."
        return 1
    }
    local _identity="system"
    if [[ "$_auth_choice" == "2" ]]; then
        _auth="password"
        _identity=""
        while true; do
            read -rsp "  Пароль:            " _pass; echo ""
            [[ -n "$_pass" ]] && break
            warn "Пароль не может быть пустым."
        done
    fi

    # Stable ID is allocated before connection testing and never changes on rename.
    NODE_ID="$_node_id"; NODE_IDENTITY="$_identity"
    NODE_NAME="$_name"; SERVER_IP="$_ip"; SERVER_PORT="$_port"
    SERVER_USER="$_user"; SERVER_PASS="$_pass"; SERVER_AUTH="$_auth"

    local _needs_setup=false _managed_identity=false _known_backup="" _manifest_backup="" _choice
    if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
        if [[ -f "${SSH_KNOWN_HOSTS:-}" ]]; then
            _known_backup=$(umask 077; mktemp "${CONFIG_DIR:-/tmp}/.known-hosts.XXXXXX") || return 1
            cp "$SSH_KNOWN_HOSTS" "$_known_backup" || { rm -f "$_known_backup"; return 1; }
        fi
        if [[ -f "${STATE_MANIFEST:-}" ]]; then
            _manifest_backup=$(umask 077; mktemp "${CONFIG_DIR:-/tmp}/.manifest.XXXXXX") || {
                rm -f "$_known_backup"; return 1;
            }
            cp "$STATE_MANIFEST" "$_manifest_backup" || {
                rm -f "$_known_backup" "$_manifest_backup"; return 1;
            }
        fi
        if [[ "$_auth" == "key" ]]; then
            while true; do
                local _previous_defer="${PORTABLE_IDENTITY_DEFER_CONFIG:-0}"
                local _previous_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
                PORTABLE_IDENTITY_DEFER_CONFIG=1
                SSH_ALLOW_PORTABLE_ONBOARDING=1
                _provision_portable_identity "$_node_id"
                local _provision_rc=$?
                PORTABLE_IDENTITY_DEFER_CONFIG="$_previous_defer"
                SSH_ALLOW_PORTABLE_ONBOARDING="$_previous_onboarding"
                if [[ $_provision_rc -eq 0 ]]; then
                    _managed_identity=true
                    _identity="$_node_id"
                    NODE_IDENTITY="$_node_id"
                    break
                fi
                _portable_onboarding_choice
                _choice=$?
                [[ $_choice -eq 0 ]] && continue
                if [[ $_choice -eq 1 ]]; then
                    _needs_setup=true
                    break
                fi
                _github_add_abort "$_node_id" false "$_known_backup" "$_manifest_backup"
                return 1
            done
        fi
    fi

    while true; do
        info "Проверяем подключение..."
        local _ssh_err _previous_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
        [[ "${CONFIG_SOURCE:-local}" == "github" ]] && SSH_ALLOW_PORTABLE_ONBOARDING=1
        _ssh_err=$(ssh_run -- "echo ok" 2>&1)
        SSH_ALLOW_PORTABLE_ONBOARDING="$_previous_onboarding"
        if echo "$_ssh_err" | grep -q "^ok$"; then
            success "Подключение успешно"
            break
        fi
        if echo "$_ssh_err" | grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED"; then
            warn "SSH-ключ сервера изменился."
            if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
                ssh-keygen -R "$_ip" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1 || true
                [[ "$_port" != "22" ]] &&
                    ssh-keygen -R "[$_ip]:$_port" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1 || true
            elif confirm_yn "Обновить ключ сервера?" Y; then
                ssh-keygen -R "$_ip" 2>/dev/null
                [[ "$_port" != "22" ]] && ssh-keygen -R "[$_ip]:$_port" 2>/dev/null
                success "Старый ключ удалён. Повторяем подключение..."
                continue
            fi
        fi
        warn "Не удалось подключиться."
        if [[ "$_auth" == "key" ]]; then
            warn "Добавьте SSH-ключ на сервер командой: ssh-copy-id ${_user}@${_ip}"
        fi
        if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
            _portable_onboarding_choice
            _choice=$?
            [[ $_choice -eq 0 ]] && continue
            if [[ $_choice -eq 1 ]]; then
                _needs_setup=true
                break
            fi
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
            return 1
        fi
        confirm_yn "Повторить попытку?" Y || return 1
        if [[ "$_auth" == "password" ]]; then
            read -rsp "  Новый пароль:      " _pass; echo ""
            [[ -z "$_pass" ]] && { warn "Пароль не может быть пустым."; continue; }
            SERVER_PASS="$_pass"
        fi
    done
    if [[ "${CONFIG_SOURCE:-local}" == "github" ]] && ! _ssh_known_host_present; then
        while true; do
            local _previous_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
            SSH_ALLOW_PORTABLE_ONBOARDING=1
            _ssh_pin_host_key
            local _pin_rc=$?
            SSH_ALLOW_PORTABLE_ONBOARDING="$_previous_onboarding"
            [[ $_pin_rc -eq 0 ]] && break
            warn "Не удалось закрепить ключ сервера ноды '${_name}'."
            _portable_onboarding_choice
            _choice=$?
            [[ $_choice -eq 0 ]] && continue
            if [[ $_choice -eq 1 ]]; then
                _needs_setup=true
                break
            fi
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
            return 1
        done
    fi

    # Explicit hardening may have provisioned a managed identity.
    _auth="$SERVER_AUTH"
    _port="$SERVER_PORT"
    _pass="$SERVER_PASS"
    [[ "$_auth" == "key" ]] && _identity="${NODE_IDENTITY:-system}" || _identity=""

    if ! confirm_yn "Сохранить ноду?" Y; then
        info "Нода не сохранена — используется только в этом сеансе."
        if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
        fi
        menu_operations
        return
    fi

    if [[ "$(jq_r --arg n "$_name" '.nodes[] | select(.name==$n) | .name')" == "$_name" ]]; then
        warn "Нода с именем '${_name}' уже существует."
        if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
        fi
        return
    fi

    echo ""
    info "Тег — короткий префикс для прокси-имён в конфиге клиента."
    info "Например, эмодзи флага страны: 🇩🇪 🇷🇺 🇳🇱 🇺🇸 или текст: DE, RU, NL"
    local _tag=""
    while [[ -z "$_tag" ]]; do
        read -rp "  Тег: " _tag
        [[ -z "$_tag" ]] && warn "Тег обязателен — он различает прокси разных нод."
    done

    local _secret_id="" _previous_candidate_allow="${CONFIG_PERSIST_ALLOW_NEEDS_SETUP:-0}"
    [[ "$_auth" == "password" ]] && _secret_id="node:${_node_id}:ssh-password"
    # Persist the secret first: GitHub's jq_w hook validates the candidate
    # against the complete state and must see the password it references.
    if [[ "$_auth" == "password" ]] && ! node_secret_set "$_node_id" "$_pass"; then
        warn "Не удалось сохранить пароль SSH для ноды."
        [[ "${CONFIG_SOURCE:-local}" == "github" ]] &&
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
        return 1
    fi
    [[ "${CONFIG_SOURCE:-local}" == "github" ]] &&
        CONFIG_PERSIST_ALLOW_NEEDS_SETUP=1
    if ! jq_w --arg id "$_node_id" --arg n "$_name" --arg ip "$_ip" \
        --argjson port "$_port" --arg u "$_user" --arg a "$_auth" \
        --arg identity "$_identity" --arg secret_id "$_secret_id" --arg t "$_tag" '
        .nodes += [{
            id:$id, name:$n, ip:$ip, port:$port, user:$u, auth:$a,
            identity:(if $a=="key" then ($identity // "system") else null end),
            secret_id:(if $a=="password" then $secret_id else null end),
            tag:$t, aliases:{}
        }]'; then
        CONFIG_PERSIST_ALLOW_NEEDS_SETUP="$_previous_candidate_allow"
        [[ "${CONFIG_SOURCE:-local}" == "github" ]] &&
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
        [[ "${CONFIG_SOURCE:-local}" != "github" && "$_auth" == "password" ]] &&
            node_secret_delete "$_node_id" >/dev/null 2>&1 || true
        return 1
    fi
    CONFIG_PERSIST_ALLOW_NEEDS_SETUP="$_previous_candidate_allow"
    state_checkpoint >/dev/null 2>&1 || {
        [[ "${CONFIG_SOURCE:-local}" == "github" ]] &&
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
        return 1
    }
    if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
        if [[ "$_auth" == "key" &&
              ( "$_identity" == "system" || ! -f "$SSH_IDENTITIES_DIR/$_node_id" ) ]]; then
            state_portability_add_issue "$_node_id" missing_identity || {
                _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
                return 1
            }
        fi
        if ! _ssh_known_host_present; then
            state_portability_add_issue "$_node_id" missing_host_key || {
                _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
                return 1
            }
        fi
        state_checkpoint >/dev/null 2>&1 || {
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
            return 1
        }
        if declare -F github_config_checkpoint >/dev/null 2>&1 &&
           ! github_config_checkpoint; then
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
            return 1
        fi
    fi
    rm -f "$_known_backup" "$_manifest_backup"
    NODE_ID="$_node_id"
    NODE_IDENTITY="${_identity:-}"
    success "Нода '${_name}' сохранена"
}

# ─── Переименование ноды ─────────────────────────────────────────────────────
rename_node() {
    local count
    count=$(nodes_count)
    [[ $count -eq 0 ]] && { warn "Нод нет."; return; }

    echo ""
    echo -e "  ${CYAN}── Переименовать ноду ──────────────────────${NC}"
    local i=1
    while IFS=$'\t' read -r name ip; do
        printf "  ${DIM}%2d)${NC}  %-16s  %s\n" "$i" "$name" "$ip"
        i=$((i + 1))
    done < <(jq_r '.nodes[] | "\(.name)\t\(.ip)"')
    echo ""
    read -rp "  Номер для переименования (Enter = отмена): " _idx
    [[ -z "$_idx" ]] && return
    if ! [[ "$_idx" =~ ^[0-9]+$ ]] || (( _idx < 1 || _idx > count )); then
        warn "Неверный номер."
        return
    fi

    local _old_name
    _old_name=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].name')
    read -rp "  Новое имя [${_old_name}]: " _new_name
    [[ -z "$_new_name" || "$_new_name" == "$_old_name" ]] && return

    # Проверка уникальности
    if [[ "$(jq_r --arg n "$_new_name" '.nodes[] | select(.name==$n) | .name')" == "$_new_name" ]]; then
        warn "Нода с именем '${_new_name}' уже существует."
        return
    fi

    # Обновляем имя во всех местах: nodes, connections[].node, clients.nodes, clients.connections[].node
    jq_w --arg old "$_old_name" --arg new "$_new_name" '
        .nodes |= map(if .name==$old then .name=$new else . end) |
        .connections |= map(if .node==$old then .node=$new else . end) |
        .clients |= map(
            (if .nodes then .nodes |= map(if .==$old then $new else . end) else . end) |
            (if .connections then .connections |= map(if .node==$old then .node=$new else . end) else . end)
        )
    '
    success "Нода '${_old_name}' переименована в '${_new_name}'"
}

# ─── Тег ноды ───────────────────────────────────────────────────────────────
set_node_tag() {
    local count
    count=$(nodes_count)
    [[ $count -eq 0 ]] && { warn "Нод нет."; return; }

    while true; do
        echo ""
        echo -e "  ${CYAN}── Тег ноды ────────────────────────────────${NC}"
        local i=1
        while IFS=$'\t' read -r name tag; do
            local tag_display=""
            [[ -n "$tag" ]] && tag_display="  ${CYAN}[${tag}]${NC}"
            printf "  ${DIM}%2d)${NC}  %-16s%b\n" "$i" "$name" "$tag_display"
            i=$((i + 1))
        done < <(jq_r '.nodes[] | "\(.name)\t\(.tag // "")"')
        echo ""
        read -rp "  Номер ноды (Enter = назад): " _idx
        [[ -z "$_idx" ]] && return
        if ! [[ "$_idx" =~ ^[0-9]+$ ]] || (( _idx < 1 || _idx > count )); then
            warn "Неверный номер."
            continue
        fi

        local _name _old_tag
        _name=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].name')
        _old_tag=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].tag // ""')

        local _prompt="  Новый тег"
        [[ -n "$_old_tag" ]] && _prompt="  Новый тег [${_old_tag}]"
        _prompt="${_prompt} (пусто = убрать): "
        read -rp "$_prompt" _new_tag

        if [[ -z "$_new_tag" && -n "$_old_tag" ]]; then
            jq_w --argjson i "$((_idx-1))" '.nodes[$i].tag = ""'
            success "Тег ноды '${_name}' удалён"
        elif [[ -n "$_new_tag" ]]; then
            jq_w --argjson i "$((_idx-1))" --arg t "$_new_tag" '.nodes[$i].tag = $t'
            success "Тег ноды '${_name}' установлен: ${_new_tag}"
        fi
    done
}

# ─── Удаление ноды ───────────────────────────────────────────────────────────
_node_delete_restore() {
    local config_backup="$1" secrets_backup="$2" manifest_backup="$3"
    cp -p "$config_backup" "$CONFIG_JSON" || return 1
    cp -p "$secrets_backup" "$SECRETS_JSON" || return 1
    if [[ -n "$manifest_backup" && -f "$manifest_backup" ]]; then
        cp -p "$manifest_backup" "$STATE_MANIFEST" || return 1
    fi
    if [[ "${CONFIG_SOURCE:-local}" == github ]]; then
        github_config_checkpoint || return 1
        github_sync_flush || true
    fi
}

delete_node() {
    local count
    count=$(nodes_count)
    [[ $count -eq 0 ]] && { warn "Нод нет."; return; }

    echo ""
    echo -e "  ${RED}── Удалить ноду ────────────────────────────${NC}"
    local i=1
    while IFS=$'\t' read -r name ip port user auth; do
        local auth_label="ключ"
        [[ "$auth" == "password" ]] && auth_label="пароль"
        printf "  ${DIM}%2d)${NC}  %-16s  %s:%s  %s  ${DIM}(%s)${NC}\n" "$i" "$name" "$ip" "$port" "$user" "$auth_label"
        i=$((i + 1))
    done < <(jq_r '.nodes[] | "\(.name)\t\(.ip)\t\(.port)\t\(.user)\t\(.auth // "password")"')
    echo ""
    read -rp "  Номер для удаления: " _idx
    [[ -z "$_idx" ]] && { warn "Введите номер ноды."; return; }
    if [[ "$_idx" =~ ^[0-9]+$ ]] && (( _idx >= 1 && _idx <= count )); then
        local _name _id _ip _port _identity
        _id=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].id')
        _name=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].name')
        _ip=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].ip')
        _port=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].port')
        _identity=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].identity // ""')

        if confirm_yn "Удалить ноду '${_name}'?"; then
            # Удаление всех компонентов на сервере
            if confirm_yn "Удалить все компоненты essence на сервере?"; then
                node_load "$_idx"
                info "Подключаемся к серверу для удаления..."
                if ssh_run -- "echo ok" &>/dev/null; then
                    upload_scripts
                    run_remote 10
                else
                    warn "Не удалось подключиться — удаление на сервере не выполнено"
                fi
            fi

            local _manifest_backup="" _config_backup _secrets_backup
            local _revoke_requested=false
            _config_backup=$(umask 077; mktemp "${CONFIG_DIR:-/tmp}/.config.XXXXXX") || return 1
            _secrets_backup=$(umask 077; mktemp "${CONFIG_DIR:-/tmp}/.secrets.XXXXXX") || {
                rm -f "$_config_backup"
                return 1
            }
            cp -p "$CONFIG_JSON" "$_config_backup" &&
                cp -p "$SECRETS_JSON" "$_secrets_backup" || {
                rm -f "$_config_backup" "$_secrets_backup"
                return 1
            }
            if [[ -f "${STATE_MANIFEST:-}" ]]; then
                _manifest_backup=$(umask 077; mktemp "${CONFIG_DIR:-/tmp}/.manifest.XXXXXX") || {
                    rm -f "$_config_backup" "$_secrets_backup"
                    return 1
                }
                cp -p "$STATE_MANIFEST" "$_manifest_backup" || {
                    rm -f "$_config_backup" "$_secrets_backup" "$_manifest_backup"
                    return 1
                }
            fi
            if [[ "${CONFIG_SOURCE:-local}" == github && "$_identity" == "$_id" ]] &&
               confirm_yn "Отозвать переносимый SSH-ключ на сервере?" Y; then
                node_load "$_idx" || {
                    rm -f "$_config_backup" "$_secrets_backup" "$_manifest_backup"
                    return 1
                }
                _revoke_requested=true
            fi
            if [[ "${CONFIG_SOURCE:-local}" == github ]]; then
                state_portability_remove_node "$_id" || {
                    rm -f "$_config_backup" "$_secrets_backup" "$_manifest_backup"
                    return 1
                }
            fi

            if ! jq_w --arg id "$_id" --arg n "$_name" '
                .nodes |= [.[] | select(.id != $id)] |
                .connections |= [.[] | select(.node!=$n)] |
                .clients |= map(
                    (if .nodes then .nodes |= [.[] | select(.!=$n)] else . end) |
                    (if .connections then .connections |= [.[] | select(.node!=$n)] else . end)
                )
            ' ||
               ! node_secret_delete "$_id" ||
               ! state_checkpoint; then
                _node_delete_restore "$_config_backup" "$_secrets_backup" "$_manifest_backup" || true
                rm -f "$_config_backup" "$_secrets_backup" "$_manifest_backup"
                warn "Удаление ноды отменено: локальное состояние не удалось сохранить."
                return 1
            fi
            if [[ "${CONFIG_SOURCE:-local}" == github ]] &&
               { ! github_config_checkpoint || ! github_sync_flush; }; then
                _node_delete_restore "$_config_backup" "$_secrets_backup" "$_manifest_backup" || true
                rm -f "$_config_backup" "$_secrets_backup" "$_manifest_backup"
                warn "Удаление ноды отменено: состояние GitHub не удалось сохранить."
                return 1
            fi

            if [[ "$_revoke_requested" == true ]]; then
                while true; do
                    local _previous_onboarding="${SSH_ALLOW_PORTABLE_ONBOARDING:-0}"
                    SSH_ALLOW_PORTABLE_ONBOARDING=1
                    _revoke_managed_remote_key "$_id"
                    local _revoke_rc=$?
                    SSH_ALLOW_PORTABLE_ONBOARDING="$_previous_onboarding"
                    [[ $_revoke_rc -eq 0 ]] && break
                    warn "Не удалось отозвать переносимый SSH-ключ."
                    echo ""
                    box_top
                    box_center "Удаление ноды"
                    box_mid
                    box_line " 1) Повторить отзыв ключа" " ${GREEN}1)${NC} Повторить отзыв ключа"
                    box_line " 2) Оставить ключ на сервере" " ${YELLOW}2)${NC} Оставить ключ на сервере"
                    box_line " 3) Восстановить ноду и отменить удаление" " ${RED}3)${NC} Восстановить ноду и отменить удаление"
                    box_bot
                    echo ""
                    read -rp "  Выберите действие: " _revoke_choice
                    case "$_revoke_choice" in
                        1) continue ;;
                        2)
                            warn "Ключ останется на сервере и потребует ручного отзыва."
                            break
                            ;;
                        3)
                            _node_delete_restore "$_config_backup" "$_secrets_backup" "$_manifest_backup" || true
                            rm -f "$_config_backup" "$_secrets_backup" "$_manifest_backup"
                            return 1
                            ;;
                        *) warn "Неверный выбор." ;;
                    esac
                done
            fi
            if [[ -n "$_identity" && "$_identity" != "system" ]]; then
                rm -f "$SSH_IDENTITIES_DIR/$_identity" "$SSH_IDENTITIES_DIR/$_identity.pub" ||
                    warn "Не удалось удалить локальную копию SSH-ключа."
            fi
            if [[ "${CONFIG_SOURCE:-local}" == github && -f "${SSH_KNOWN_HOSTS:-}" ]]; then
                ssh-keygen -R "$_ip" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1 || true
                [[ "$_port" != "22" ]] &&
                    ssh-keygen -R "[$_ip]:$_port" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1 || true
                github_config_checkpoint || GITHUB_SYNC_STATUS=pending
                github_sync_flush || true
            fi
            rm -f "$_config_backup" "$_secrets_backup" "$_manifest_backup"
            success "Нода '${_name}' удалена"
        fi
    else
        warn "Неверный номер."
    fi
}
