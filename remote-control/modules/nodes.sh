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
    CURRENT_NODE_INDEX="$1"
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

node_pick() {
    local labels=() label
    NODE_PICK_INDEX=""
    while IFS= read -r label; do
        [[ -n "$label" ]] && labels+=("$label")
    done < <(jq_r '.nodes[] | "\(.name)  \(.ip):\(.port)"')
    MENU_SELECT_EMPTY="Нет нод для выбора"
    menu_select "$1" "Выберите ноду" "${labels[@]}" || return 1
    NODE_PICK_INDEX="$MENU_SELECT_INDEX"
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
    local existing_name previous_candidate_allow rollback_status=0
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
            )' || rollback_status=$?
        CONFIG_PERSIST_ALLOW_NEEDS_SETUP="$previous_candidate_allow"
        if [[ "$rollback_status" -ne 0 ]]; then
            warn "Откат ноды не сохранён; SSH-ключи, секреты и резервные копии оставлены."
            return 1
        fi
    fi
    if [[ "$managed" == true && -n "$node_id" ]] && declare -F _revoke_managed_remote_key >/dev/null 2>&1; then
        _revoke_managed_remote_key "$node_id" >/dev/null 2>&1 ||
            warn "Не удалось отозвать переносимый SSH-ключ ноды «${node_id}»."
    fi
    if { [[ -n "$node_id" ]] &&
         { ! rm -f "${SSH_IDENTITIES_DIR:-}/$node_id" "${SSH_IDENTITIES_DIR:-}/$node_id.pub" ||
           ! node_secret_delete "$node_id"; }; } ||
       { [[ -n "$known_backup" ]] &&
         { [[ ! -f "$known_backup" ]] || ! cp "$known_backup" "$SSH_KNOWN_HOSTS"; }; } ||
       { [[ -z "$known_backup" && -n "${SSH_KNOWN_HOSTS:-}" ]] &&
         ! rm -f "$SSH_KNOWN_HOSTS"; } ||
       { [[ -n "$manifest_backup" ]] &&
         { [[ ! -f "$manifest_backup" ]] || ! cp "$manifest_backup" "$STATE_MANIFEST"; }; }; then
        warn "Восстановление ресурсов ноды не завершено. Резервные копии оставлены: $known_backup $manifest_backup"
        return 1
    fi
    rm -f "$known_backup" "$manifest_backup"
}

add_node() {
    echo ""
    echo -e "${CYAN}  ── Добавить ноду ──────────────────────────${NC}"
    IFS= read -rp "  Название [Enter = vps-1]: " _name || return 1
    _name="${_name%$'\r'}"; _name="${_name:-vps-1}"

    IFS= read -rp "  IP ноды: " _ip || return 1
    _ip="${_ip%$'\r'}"
    [[ -z "$_ip" ]] && { warn "IP не может быть пустым."; return; }

    local _port
    while true; do
        IFS= read -rp "  SSH-порт [Enter = 22]: " _port || return 1
        _port="${_port%$'\r'}"; _port="${_port:-22}"
        if [[ "$_port" =~ ^[0-9]+$ ]] &&
           (( _port >= 1 && _port <= 65535 )); then
            break
        fi
        warn "Порт SSH должен быть числом от 1 до 65535."
    done

    IFS= read -rp "  Логин [Enter = root]: " _user || return 1
    _user="${_user%$'\r'}"; _user="${_user:-root}"

    # Выбор типа авторизации
    local _auth_choice
    while true; do
        echo ""
        box_top
        box_center "Авторизация SSH"
        box_mid
        menu_item 1 "SSH-ключ" CYAN
        menu_item 2 "Пароль" CYAN
        menu_item 0 "Отмена" NC
        box_bot
        echo ""
        IFS= read -rp "  Выберите способ авторизации [Enter = 1]: " _auth_choice || return 1
        _auth_choice="${_auth_choice%$'\r'}"
        _auth_choice="${_auth_choice:-1}"
        [[ "$_auth_choice" == 0 ]] && return 1
        [[ "$_auth_choice" == 1 || "$_auth_choice" == 2 ]] && break
        warn "Неверный выбор."
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
            if ! IFS= read -rsp "  Пароль: " _pass; then echo ""; return 1; fi
            echo ""
            _pass="${_pass%$'\r'}"
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
            warn "SSH-ключ ноды изменился."
            if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
                ssh-keygen -R "$_ip" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1 || true
                [[ "$_port" != "22" ]] &&
                    ssh-keygen -R "[$_ip]:$_port" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1 || true
            elif confirm_yn "Обновить ключ ноды?" Y; then
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
            if ! IFS= read -rsp "  Новый пароль: " _pass; then echo ""; return 1; fi
            echo ""
            _pass="${_pass%$'\r'}"
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
            warn "Не удалось закрепить SSH-ключ ноды '${_name}'."
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
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup" || return 1
        fi
        menu_operations
        return
    fi

    if [[ "$(jq_r --arg n "$_name" '.nodes[] | select(.name==$n) | .name')" == "$_name" ]]; then
        warn "Нода с именем '${_name}' уже существует."
        if [[ "${CONFIG_SOURCE:-local}" == "github" ]]; then
            _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup" || return 1
        fi
        return
    fi

    echo ""
    info "Тег — короткий префикс для прокси-имён в конфиге клиента."
    info "Например, эмодзи флага страны: 🇩🇪 🇷🇺 🇳🇱 🇺🇸 или текст: DE, RU, NL"
    local _tag=""
    while [[ -z "$_tag" ]]; do
        if ! IFS= read -rp "  Тег ноды: " _tag; then
            [[ "${CONFIG_SOURCE:-local}" == github ]] &&
                _github_add_abort "$_node_id" "$_managed_identity" "$_known_backup" "$_manifest_backup"
            return 1
        fi
        _tag="${_tag%$'\r'}"
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
    node_pick "Переименование ноды" || return 1
    local _idx="$NODE_PICK_INDEX" _old_name _new_name
    _old_name=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].name')
    IFS= read -rp "  Новое имя [Enter = $_old_name]: " _new_name || return 1
    _new_name="${_new_name%$'\r'}"
    [[ -z "$_new_name" || "$_new_name" == "$_old_name" ]] && return 0

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
    ' || return 1
    success "Нода '${_old_name}' переименована в '${_new_name}'"
}

# ─── Тег ноды ───────────────────────────────────────────────────────────────
set_node_tag() {
    node_pick "Тег ноды" || return 1
    local _idx="$NODE_PICK_INDEX" _name _old_tag _new_tag
    _name=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].name')
    _old_tag=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].tag // ""')
    info "Нода: $_name; текущий тег: ${_old_tag:-не задан}"
    IFS= read -rp "  Новый тег [Enter = убрать]: " _new_tag || return 1
    _new_tag="${_new_tag%$'\r'}"
    jq_w --argjson i "$((_idx-1))" --arg t "$_new_tag" '.nodes[$i].tag = $t' || return 1
    success "Тег ноды '$_name' сохранён"
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
        github_sync_flush || return 1
    fi
}

# Never fall back to a fresh login after revoking its only accepted key.
# The private ControlMaster socket keeps the authenticated transport alive
# until both the local checkpoint and GitHub commit have completed.
_node_delete_key_run() {
    local socket="$1"
    shift
    ssh_run -S "$socket" -o ControlMaster=no -o ProxyCommand=false -- "$@"
}

_node_delete_key_restore() {
    local socket="$1" pubkey="$2" quoted
    printf -v quoted %q "$pubkey"
    _node_delete_key_run "$socket" "key=$quoted
mkdir -p ~/.ssh && chmod 700 ~/.ssh &&
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys &&
{ grep -qxF -- \"\$key\" ~/.ssh/authorized_keys ||
  printf '%s\n' \"\$key\" >> ~/.ssh/authorized_keys; } &&
grep -qxF -- \"\$key\" ~/.ssh/authorized_keys" || return 1
    # Verify a new login, not just the still-authenticated master session.
    ssh_run -S none -o ControlMaster=no -o BatchMode=yes \
        -i "$SSH_IDENTITIES_DIR/$NODE_IDENTITY" -o IdentitiesOnly=yes -- "true"
}

_node_delete_rollback() {
    local backup="$1" socket="$2" revoked="$3" pubkey="$4" restored=true
    if [[ "$revoked" == true ]] && ! _node_delete_key_restore "$socket" "$pubkey"; then
        warn "Не удалось подтвердить восстановление SSH-доступа. Резервные копии: $backup; сокет SSH-соединения: $socket"
        restored=false
    fi
    _node_delete_restore "$backup/config" "$backup/secrets" \
        "$([[ -f "$backup/manifest" ]] && printf '%s' "$backup/manifest")" || {
        warn "Не удалось полностью восстановить локальное состояние и GitHub. Резервные копии сохранены: $backup"
        restored=false
    }
    [[ "$restored" == true ]] || return 1
    if [[ -n "$socket" ]]; then
        ssh_run -S "$socket" -O exit -- >/dev/null 2>&1 || true
        rm -rf "${socket%/*}"
    fi
    rm -rf "$backup"
}

delete_node() {
    node_pick "Удаление ноды" || return 1
    local _idx="$NODE_PICK_INDEX" _name _id _ip _port _identity _user
    _id=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].id')
    _name=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].name')
    _ip=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].ip')
    _port=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].port')
    _identity=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].identity // ""')
    _user=$(jq_r --argjson i "$((_idx-1))" '.nodes[$i].user')
    local options=("Удалить только из remote-control; сервер и SSH-ключ оставить")
    local server_flags=(false) key_flags=(false)
    local managed=false
    [[ "${CONFIG_SOURCE:-local}" == github && -n "$_id" && "$_identity" == "$_id" ]] && managed=true
    if [[ "$managed" == true ]]; then
        options+=("Удалить из remote-control и отозвать управляемый SSH-ключ")
        server_flags+=(false); key_flags+=(true)
    fi
    options+=("Удалить из remote-control и все компоненты Essence на сервере")
    server_flags+=(true); key_flags+=(false)
    if [[ "$managed" == true ]]; then
        options+=("Удалить из remote-control, все компоненты Essence и отозвать SSH-ключ")
        server_flags+=(true); key_flags+=(true)
    fi
    menu_select "Объём удаления ноды" "Выберите объём удаления" "${options[@]}" || return 1
    local selected=$((MENU_SELECT_INDEX - 1))
    local remove_server="${server_flags[$selected]}" _revoke_requested="${key_flags[$selected]}"
    local affected=() client
    while IFS= read -r client; do
        [[ -n "$client" ]] && affected+=("$client")
    done < <(jq_r --arg n "$_name" '
        . as $config | .clients[] | . as $client |
        select((.nodes // [] | index($n)) != null or
               ([.connections[]?.node] | index($n)) != null or
               (.inherit_nodes_from_group != false and
                ([ $config.connections[] | select(.node==$n) | .groups[]?.name ] | index($client.group)) != null)) |
        .name')
    local lines=("Нода: $_name  $_ip:$_port" "Пользователь: $_user" "Объём: ${options[$selected]}"
        "Затронутые клиенты: ${affected[*]:-нет}")
    if [[ "$remove_server" == true ]]; then
        lines+=("Mihomo: бинарь, служба, конфигурация и клиентские записи."
            "AmneziaWG: служба, конфигурация, ключи и все клиенты."
            "WARP: /root/wgcf и профиль."
            "Сайты nginx Essence, webroot и /etc/nginx/ssl целиком."
            "Хостинг подписок, Telegram Proxy и acme.sh."
            "/etc/sysctl.d/99-vpn-speedup.conf; IPv6 будет восстановлен."
            "Пакеты nginx и AmneziaWG не удаляются."
            "Правила UFW будут сброшены. Настройки SSH сохранятся.")
        if [[ "$_port" == 22 ]]; then
            lines+=("UFW будет отключён.")
        else
            lines+=("UFW останется включён: открыт только SSH TCP/$_port.")
        fi
    fi
    if [[ "$_revoke_requested" == true ]]; then
        lines+=("Управляемый SSH-ключ будет отозван на ноде.")
    else
        lines+=("SSH-ключ на ноде сохранится.")
    fi
    review_frame "Удаление ноды" "${lines[@]}"
    confirm_yn "Удалить ноду в выбранном объёме?" N || return 0
    if [[ "$remove_server" == true ]]; then
        local entry
        if ! node_load "$_idx" || ! ensure_remote_scripts_current; then
            warn "Удаление компонентов на сервере не завершено. Нода сохранена в remote-control."
            return 1
        fi
        printf -v entry %q "$REMOTE_DIR/setup-essence.sh"
        if ! SSH_RUN_TIMEOUT=900 ssh_run -- "bash $entry uninstall --force"; then
            warn "Удаление компонентов на сервере не завершено. Нода сохранена в remote-control."
            return 1
        fi
    fi
    # Prepare every rollback artifact before revoking remote authorization.
    local backup socket="" pubkey="" key_present="" revoked=false quoted
    backup=$(umask 077; mktemp -d "${CONFIG_DIR:-/tmp}/.node-delete.XXXXXX") || return 1
    if ! cp -p "$CONFIG_JSON" "$backup/config" ||
       ! cp -p "$SECRETS_JSON" "$backup/secrets" ||
       { [[ -f "${STATE_MANIFEST:-}" ]] && ! cp -p "$STATE_MANIFEST" "$backup/manifest"; }; then
        rm -rf "$backup"
        return 1
    fi
    if [[ "$_revoke_requested" == true ]]; then
        if ! node_load "$_idx" ||
           ! cp -p "$SSH_IDENTITIES_DIR/$_id.pub" "$backup/key.pub" ||
           ! pubkey=$(cat "$backup/key.pub") || [[ -z "$pubkey" ]]; then
            rm -rf "$backup"
            warn "Не удалось подготовить отзыв SSH-ключа. Нода сохранена в remote-control."
            return 1
        fi
        # Unix-domain paths are limited to ~104 bytes; CONFIG_DIR may be longer.
        socket=$(umask 077; mktemp -d /tmp/essence-ssh.XXXXXX) || {
            rm -rf "$backup"
            warn "Не удалось подготовить временный сокет SSH. Ключ не отозван."
            return 1
        }
        socket="$socket/control"
        if ! ssh_run -M -N -f -S "$socket" -o ControlPersist=no --; then
            ssh_run -S "$socket" -O exit -- >/dev/null 2>&1 || true
            rm -rf "$backup" "${socket%/*}"
            warn "Не удалось сохранить SSH-соединение для восстановления доступа. Ключ не отозван."
            return 1
        fi
        printf -v quoted %q "$pubkey"
        key_present=$(_node_delete_key_run "$socket" "key=$quoted
if [ ! -f ~/.ssh/authorized_keys ]; then printf absent
elif grep -qxF -- \"\$key\" ~/.ssh/authorized_keys; then printf present
elif [ \"\$?\" -eq 1 ]; then printf absent
else exit 1; fi") || key_present=""
        case "$key_present" in
            present)
                # Mark before sending: a lost reply may follow successful revocation.
                revoked=true
                if ! _node_delete_key_run "$socket" "key=$quoted
umask 077
tmp=\$(mktemp ~/.ssh/authorized_keys.XXXXXX) || exit 1
if awk -v key=\"\$key\" '\$0 != key' ~/.ssh/authorized_keys > \"\$tmp\" &&
   mv \"\$tmp\" ~/.ssh/authorized_keys; then
    grep -qxF -- \"\$key\" ~/.ssh/authorized_keys
    [ \"\$?\" -eq 1 ]
else rm -f \"\$tmp\"; exit 1; fi"; then
                    _node_delete_rollback "$backup" "$socket" "$revoked" "$pubkey" || true
                    warn "SSH-ключ не отозван. Нода сохранена в remote-control."
                    return 1
                fi
                ;;
            absent) ;;
            *)
                _node_delete_rollback "$backup" "$socket" false "$pubkey" || true
                warn "Не удалось проверить SSH-ключ. Нода сохранена в remote-control."
                return 1
                ;;
        esac
    fi
    if [[ "${CONFIG_SOURCE:-local}" == github ]] &&
       ! state_portability_remove_node "$_id"; then
        _node_delete_rollback "$backup" "$socket" "$revoked" "$pubkey" || true
        return 1
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
        _node_delete_rollback "$backup" "$socket" "$revoked" "$pubkey" || true
        warn "Удаление ноды отменено: локальное состояние не удалось сохранить."
        return 1
    fi
    if [[ "${CONFIG_SOURCE:-local}" == github ]] &&
       { ! github_config_checkpoint || ! github_sync_flush; }; then
        _node_delete_rollback "$backup" "$socket" "$revoked" "$pubkey" || true
        warn "Удаление ноды отменено: состояние GitHub не удалось сохранить."
        return 1
    fi
    if [[ -n "$socket" ]]; then
        ssh_run -S "$socket" -O exit -- >/dev/null 2>&1 || true
        rm -rf "${socket%/*}"
    fi
    if [[ -n "$_identity" && "$_identity" != "system" ]]; then
        if ! rm -f "$SSH_IDENTITIES_DIR/$_identity" "$SSH_IDENTITIES_DIR/$_identity.pub"; then
            warn "Очистка локального SSH-ключа не завершена. Резервная копия: $backup"
            return 1
        fi
    fi
    if [[ "${CONFIG_SOURCE:-local}" == github && -f "${SSH_KNOWN_HOSTS:-}" ]]; then
        if ! ssh-keygen -R "$_ip" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1; then
            warn "Очистка известных SSH-ключей не завершена. Резервная копия: $backup"
            return 1
        fi
        if [[ "$_port" != "22" ]]; then
            if ! ssh-keygen -R "[$_ip]:$_port" -f "$SSH_KNOWN_HOSTS" >/dev/null 2>&1; then
                warn "Очистка известных SSH-ключей не завершена. Резервная копия: $backup"
                return 1
            fi
        fi
        if ! github_config_checkpoint; then
            GITHUB_SYNC_STATUS=pending
            _github_report_last_error "Очистка SSH-данных не сохранена в GitHub"
            warn "Резервная копия: $backup"
            return 1
        fi
        github_sync_flush || GITHUB_SYNC_STATUS=pending
    fi
    rm -rf "$backup"
            success "Нода '${_name}' удалена"
    return 0
}
