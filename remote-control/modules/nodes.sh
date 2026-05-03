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
    NODE_NAME=$(jq_r  --argjson i "$idx" '.nodes[$i].name')
    SERVER_IP=$(jq_r  --argjson i "$idx" '.nodes[$i].ip')
    SERVER_PORT=$(jq_r --argjson i "$idx" '.nodes[$i].port')
    SERVER_USER=$(jq_r --argjson i "$idx" '.nodes[$i].user')
    SERVER_AUTH=$(jq_r --argjson i "$idx" '.nodes[$i].auth // "password"')
    NODE_TAG=$(jq_r  --argjson i "$idx" '.nodes[$i].tag // ""')
    if [[ "$SERVER_AUTH" == "key" ]]; then
        SERVER_PASS=""
    else
        SERVER_PASS=$(node_pass_decode "$(jq_r --argjson i "$idx" '.nodes[$i].pass')")
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
add_node() {
    echo ""
    echo -e "${CYAN}  ── Добавить ноду ──────────────────────────${NC}"
    read -rp "  Название [vps-1]:  " _name
    _name="${_name:-vps-1}"

    read -rp "  IP сервера:        " _ip
    [[ -z "$_ip" ]] && { warn "IP не может быть пустым."; return; }

    read -rp "  Порт SSH [22]:     " _port
    _port="${_port:-22}"

    read -rp "  Логин [root]:      " _user
    _user="${_user:-root}"

    # Выбор типа авторизации
    echo ""
    echo -e "  Авторизация:"
    echo -e "  ${GREEN}1)${NC} SSH-ключ (рекомендуется)"
    echo -e "  ${GREEN}2)${NC} Пароль"
    read -rp "  Выберите [1]: " _auth_choice
    _auth_choice="${_auth_choice:-1}"

    local _auth="key"
    local _pass=""
    if [[ "$_auth_choice" == "2" ]]; then
        _auth="password"
        while true; do
            read -rsp "  Пароль:            " _pass; echo ""
            [[ -n "$_pass" ]] && break
            warn "Пароль не может быть пустым."
        done
    fi

    # Тест подключения
    NODE_NAME="$_name"; SERVER_IP="$_ip"; SERVER_PORT="$_port"
    SERVER_USER="$_user"; SERVER_PASS="$_pass"; SERVER_AUTH="$_auth"

    while true; do
        info "Проверяем подключение..."
        local _ssh_err
        _ssh_err=$(ssh_run -- "echo ok" 2>&1)
        if echo "$_ssh_err" | grep -q "^ok$"; then
            success "Подключение успешно"
            break
        fi
        if echo "$_ssh_err" | grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED"; then
            warn "SSH-ключ сервера изменился."
            if confirm_yn "Обновить ключ сервера?" Y; then
                ssh-keygen -R "$_ip" 2>/dev/null
                [[ "$_port" != "22" ]] && ssh-keygen -R "[$_ip]:$_port" 2>/dev/null
                success "Старый ключ удалён. Повторяем подключение..."
                continue
            fi
        fi
        warn "Не удалось подключиться."
        if [[ "$_auth" == "key" ]]; then
            warn "Убедитесь, что SSH-ключ добавлен на сервер: ssh-copy-id ${_user}@${_ip}"
        fi
        confirm_yn "Повторить попытку?" Y || return
        if [[ "$_auth" == "password" ]]; then
            read -rsp "  Новый пароль:      " _pass; echo ""
            [[ -z "$_pass" ]] && { warn "Пароль не может быть пустым."; continue; }
            SERVER_PASS="$_pass"
        fi
    done

    # Предложить настроить SSH-ключ если авторизация по паролю
    if [[ "$_auth" == "password" ]]; then
        echo ""
        if confirm_yn "Настроить SSH-ключ на сервере? (рекомендуется)" Y; then
            ssh_hardening
            # После hardening переменные обновлены (auth=key, порт сменён)
            _auth="$SERVER_AUTH"
            _port="$SERVER_PORT"
            _pass="$SERVER_PASS"
        fi
    fi

    if ! confirm_yn "Сохранить ноду?" Y; then
        info "Нода не сохранена — используется только в этом сеансе."
        menu_operations
        return
    fi

    if [[ "$(jq_r --arg n "$_name" '.nodes[] | select(.name==$n) | .name')" == "$_name" ]]; then
        warn "Нода с именем '${_name}' уже существует."
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

    local _pass_b64=""
    [[ "$_auth" == "password" ]] && _pass_b64=$(node_pass_encode "$_pass")
    jq_w --arg n "$_name" --arg ip "$_ip" --argjson port "$_port" --arg u "$_user" --arg a "$_auth" --arg p "$_pass_b64" --arg t "$_tag" \
        '.nodes += [{name:$n, ip:$ip, port:$port, user:$u, auth:$a, pass:$p, tag:$t, aliases:{}}]'
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
        local _name
        _name=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].name')

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

            # Удаляем ноду и все ссылки: nodes, connections.node, clients.nodes, clients.connections.node
            jq_w --arg n "$_name" '
                .nodes |= [.[] | select(.name!=$n)] |
                .connections |= [.[] | select(.node!=$n)] |
                .clients |= map(
                    (if .nodes then .nodes |= [.[] | select(.!=$n)] else . end) |
                    (if .connections then .connections |= [.[] | select(.node!=$n)] else . end)
                )
            '
            success "Нода '${_name}' удалена"
        fi
    else
        warn "Неверный номер."
    fi
}
