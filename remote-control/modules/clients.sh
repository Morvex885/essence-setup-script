#!/bin/bash
# ─── Управление клиентами ───────────────────────────────────────────────────

GENERATED_DIR="$CONFIG_DIR/generated"

_validate_client_name() {
    [[ "$1" =~ ^[a-zA-Z0-9._-]+$ && ! "$1" =~ ^\.+$ ]]
}

# Путь к директории/файлу конфигов клиента: $GENERATED_DIR/<group>/<client>/config.yaml
_client_config_dir() {
    local client="$1"
    local group
    group=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .group')
    echo "$GENERATED_DIR/$group/$client"
}

_client_config_file() {
    echo "$(_client_config_dir "$1")/config.yaml"
}

clients_menu() {
    while true; do
        echo ""
        box_top
        box_center "Клиенты"
        box_mid
        _list_clients_display
        box_mid
        menu_item a "Добавить клиента" GREEN
        menu_item e "Редактировать клиента" YELLOW
        menu_item d "Удалить клиента" RED
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите действие: " CL_CHOICE; then
            return 0
        fi
        CL_CHOICE="${CL_CHOICE%$'\r'}"
        case "$CL_CHOICE" in
            a|A) state_action "add_client" add_client ;;
            e|E) edit_client ;;
            d|D) state_action "delete_client" delete_client ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

_list_clients_display() {
    local count
    count=$(jq_r '.clients | length')
    if [[ "$count" -eq 0 ]]; then
        box_line " Нет клиентов" " ${DIM}Нет клиентов${NC}"
        return
    fi

    local name group inherit nodes_display
    while IFS='|' read -r name group inherit; do
        if [[ "$inherit" == "true" ]]; then
            nodes_display=$(_group_nodes_csv "$group")
            nodes_display="${nodes_display//,/, }"
            [[ -z "$nodes_display" ]] && nodes_display="нет нод"
            box_line " ${name} — группа: ${group}"
            box_line "    ноды: ${nodes_display}" "    ${DIM}ноды: ${nodes_display}${NC}"
        else
            nodes_display=$(jq_r --arg n "$name" '.clients[] | select(.name==$n) | .nodes // [] | sort | join(", ")')
            [[ -z "$nodes_display" ]] && nodes_display="нет нод"
            box_line " ${name} — группа: ${group}"
            box_line "    ноды: ${nodes_display}" "    ${YELLOW}ноды: ${nodes_display}${NC}"
        fi
    done < <(jq_r '.clients[] | "\(.name)|\(.group)|\(if .inherit_nodes_from_group == false then false else true end)"')
}

clients_list() {
    CLIENTS=()
    while IFS= read -r client_name; do
        CLIENTS+=("$client_name")
    done < <(jq_r '.clients[] | .name')
}

add_client() {
    echo ""
    IFS= read -rp "  Имя клиента: " CLIENT_NAME || return 1
    CLIENT_NAME="${CLIENT_NAME%$'\r'}"
    [[ -z "$CLIENT_NAME" ]] && { warn "Имя не указано."; return; }

    if ! _validate_client_name "$CLIENT_NAME"; then
        warn "Имя может содержать только буквы, цифры, точку, - и _"
        return
    fi

    if [[ "$(jq_r --arg n "$CLIENT_NAME" '.clients[] | select(.name==$n) | .name')" == "$CLIENT_NAME" ]]; then
        warn "Клиент '$CLIENT_NAME' уже существует."
        return
    fi

    # Выбор группы
    echo ""
    echo -e "  Группа:"
    if ! select_group; then return; fi
    local group="$SELECTED_GROUP"

    # Показываем ноды группы
    local group_nodes
    group_nodes=$(_group_nodes_csv "$group")
    group_nodes="${group_nodes//,/, }"
    if [[ -n "$group_nodes" ]]; then
        info "Ноды группы: $group_nodes"
    else
        warn "У группы $group нет нод. Назначьте прокси группе через Подключения."
    fi

    # Генерируем per-client credentials
    local client_uuid client_hy2_pass
    client_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
    client_hy2_pass=$(openssl rand -hex 16)

    jq_w --arg n "$CLIENT_NAME" --arg g "$group" \
        --arg uuid "$client_uuid" --arg hy2pass "$client_hy2_pass" \
        '.clients += [{name:$n, group:$g, inherit_nodes_from_group:true, nodes:[], connections:[], credentials:{vless_uuid:$uuid, hy2_password:$hy2pass}}]' || return 1

    success "Клиент $CLIENT_NAME добавлен ($group, ноды от группы)"
}

edit_client() {
    clients_list
    MENU_SELECT_EMPTY="Нет клиентов"
    menu_select "Выбор клиента" "Выберите клиента" "${CLIENTS[@]}" || return 1
    local target="${CLIENTS[$((MENU_SELECT_INDEX - 1))]}"
    local current_group current_inherit nodes choice
    while true; do
        current_group=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | .group')
        [[ -n "$current_group" ]] || return 0
        current_inherit=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | .inherit_nodes_from_group != false')
        nodes=$(_collect_client_nodes "$target")
        echo ""
        box_top
        box_center "Клиент: $target"
        box_mid
        box_line " Группа: $current_group"
        if [[ "$current_inherit" == true ]]; then
            box_line " Ноды: от группы (${nodes//,/, })"
        else
            box_line " Ноды: свои (${nodes//,/, })"
        fi
        box_mid
        if [[ "$current_inherit" == true ]]; then
            menu_item 1 "Назначить свои ноды (отвязать от группы)" YELLOW
        else
            menu_item 1 "Вернуть ноды от группы" YELLOW
            menu_item 2 "Изменить свои ноды" YELLOW
            menu_item 3 "Настроить подключения для нод" CYAN
        fi
        menu_item g "Поменять группу" YELLOW
        menu_item r "Переименовать клиента" YELLOW
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        IFS= read -rp "  Выберите действие: " choice || return 0
        choice="${choice%$'\r'}"
        case "$choice" in
            1)
                if [[ "$current_inherit" == true ]]; then
                    state_action "set_custom_nodes" _set_custom_nodes "$target" "$current_group"
                else
                    state_action "inherit_client_nodes" _inherit_client_nodes "$target"
                fi ;;
            2)
                if [[ "$current_inherit" == false ]]; then
                    state_action "set_custom_nodes" _set_custom_nodes "$target" "$current_group"
                else warn "Неверный выбор."; fi ;;
            3)
                if [[ "$current_inherit" == false ]]; then
                    _configure_client_connections "$target" "$current_group"
                else warn "Неверный выбор."; fi ;;
            g|G) state_action "change_client_group" _change_client_group "$target" "$current_group" ;;
            r|R)
                CLIENT_RENAME_RESULT=""
                state_action "rename_client" _rename_client "$target"
                [[ -n "$CLIENT_RENAME_RESULT" ]] && target="$CLIENT_RENAME_RESULT"
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

_inherit_client_nodes() {
    jq_w --arg n "$1" \
        '.clients |= map(if .name==$n then .inherit_nodes_from_group=true | del(.nodes) | del(.connections) else . end)' || return 1
    success "$1: ноды от группы"
}

_change_client_group() {
    local target="$1"
    local current_group="$2"

    groups_list
    if [[ ${#GRP_LIST[@]} -le 1 ]]; then
        warn "Нет других групп — создайте вторую группу в меню Группы."
        return
    fi

    local other_groups=()
    for g in "${GRP_LIST[@]}"; do
        [[ "$g" != "$current_group" ]] && other_groups+=("$g")
    done

    MENU_SELECT_CONTEXT=("Текущая группа: $current_group")
    menu_select "Смена группы клиента: $target" "Выберите группу" "${other_groups[@]}" || return 1
    local new_group="${other_groups[$((MENU_SELECT_INDEX - 1))]}"

    # Сводка изменений
    local cur_tpl new_tpl
    cur_tpl=$(jq_r --arg g "$current_group" '.groups[] | select(.name==$g) | .template // "default.yaml"')
    new_tpl=$(jq_r --arg g "$new_group" '.groups[] | select(.name==$g) | .template // "default.yaml"')

    local inherit
    inherit=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | if .inherit_nodes_from_group == false then false else true end')

    echo ""
    info "Изменения для '$target':"
    echo -e "    Группа:  ${YELLOW}$current_group${NC} → ${GREEN}$new_group${NC}"
    if [[ "$cur_tpl" != "$new_tpl" ]]; then
        echo -e "    Шаблон:  ${YELLOW}$cur_tpl${NC} → ${GREEN}$new_tpl${NC}"
    fi
    if [[ "$inherit" == "true" ]]; then
        local old_nodes new_nodes
        old_nodes=$(_group_nodes_csv "$current_group"); old_nodes="${old_nodes//,/, }"
        new_nodes=$(_group_nodes_csv "$new_group"); new_nodes="${new_nodes//,/, }"
        echo -e "    Ноды:    ${YELLOW}${old_nodes:-нет}${NC} → ${GREEN}${new_nodes:-нет}${NC}"
    fi

    local client_conns_count
    client_conns_count=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | .connections // [] | length')
    if [[ "$client_conns_count" -gt 0 ]]; then
        warn "У клиента есть $client_conns_count собственных подключений — они сохранятся, но проверьте актуальность через пункт '3)'."
    fi

    local gh_count
    gh_count=$(jq_r --arg g "$current_group" '.groups[] | select(.name==$g) | .subscription_headers // [] | length')
    if [[ "$gh_count" -gt 0 ]]; then
        warn "Заголовки подписок старой группы (${gh_count}) больше не будут применяться."
    fi


    # Собираем affected_nodes ДО изменения JSON
    local affected_nodes=()
    local _csv _n
    local -a _arr

    _csv=$(_group_nodes_csv "$current_group")
    IFS=',' read -ra _arr <<< "$_csv"
    for _n in "${_arr[@]}"; do
        [[ -z "$_n" ]] && continue
        array_contains "$_n" "${affected_nodes[@]}" && continue
        affected_nodes+=("$_n")
    done

    _csv=$(_group_nodes_csv "$new_group")
    IFS=',' read -ra _arr <<< "$_csv"
    for _n in "${_arr[@]}"; do
        [[ -z "$_n" ]] && continue
        array_contains "$_n" "${affected_nodes[@]}" && continue
        affected_nodes+=("$_n")
    done

    if [[ "$inherit" != "true" ]]; then
        _csv=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | .nodes // [] | join(",")')
        IFS=',' read -ra _arr <<< "$_csv"
        for _n in "${_arr[@]}"; do
            [[ -z "$_n" ]] && continue
            array_contains "$_n" "${affected_nodes[@]}" && continue
            affected_nodes+=("$_n")
        done
    fi


    # Путь старой папки клиента (не группы!) — снимается до jq_w, т.к. после
    # изменения group этот же клиент будет смотреть в новую подпапку.
    local old_dir
    old_dir=$(_client_config_dir "$target")

    # Атомарное обновление group
    jq_w --arg n "$target" --arg g "$new_group" \
        '.clients |= map(if .name==$n then .group=$g else . end)' || return 1
    success "$target: группа — $new_group"

    # Регенерация. Prefetch явно на ВСЕХ affected_nodes (в т.ч. нодах старой
    # группы — иначе _sync_node_listeners на них тихо провалится: кеша нет).
    _reset_node_cache
    [[ ${#affected_nodes[@]} -gt 0 ]] && _prefetch_node_configs "${affected_nodes[@]}"
    _generate_group "$new_group"
    [[ ${#affected_nodes[@]} -gt 0 ]] && _sync_listeners_on_nodes "${affected_nodes[@]}"

    # Удаляем папку клиента в старой группе только ЕСЛИ новая успешно создана.
    # При пропуске генерации (дубликаты proxy-имён в новой группе и т.п.)
    # сохраняем старый config.yaml как fallback до ручного фикса.
    local new_dir
    new_dir=$(_client_config_dir "$target")
    if [[ -f "$new_dir/config.yaml" ]]; then
        [[ -d "$old_dir" && "$old_dir" != "$new_dir" ]] && rm -rf "${old_dir:?}"
    else
        warn "$target: новый config.yaml не сгенерирован — старая папка сохранена: $old_dir"
    fi

    # Republish подписки, если у клиента есть токен
    local token
    token=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | .subscription.token // empty')
    if [[ -n "$token" ]]; then
        echo ""
        info "Обновляю подписку для $target..."
        subscription_publish "$target" "" status
    else
        info "У клиента нет подписки — пропуск publish."
    fi
}

_rename_client() {
    local old_name="$1"
    echo ""
    CLIENT_RENAME_RESULT=""
    local new_name
    IFS= read -rp "  Новое имя [Enter = ${old_name}]: " new_name || return 1
    new_name="${new_name%$'\r'}"
    [[ -z "$new_name" || "$new_name" == "$old_name" ]] && return

    if ! _validate_client_name "$new_name"; then
        warn "Имя может содержать только буквы, цифры, точку, - и _"
        return
    fi

    if [[ "$(jq_r --arg n "$new_name" '.clients[] | select(.name==$n) | .name')" == "$new_name" ]]; then
        warn "Клиент '$new_name' уже существует."
        return
    fi

    # Путь до jq_w: группа ещё привязана к old_name
    local old_dir
    old_dir=$(_client_config_dir "$old_name")

    jq_w --arg old "$old_name" --arg new "$new_name" \
        '.clients |= map(if .name==$old then .name=$new else . end)' || return 1

    local new_dir
    new_dir=$(_client_config_dir "$new_name")

    if [[ -d "$old_dir" ]]; then
        mkdir -p "$(dirname "$new_dir")" || return 1
        mv "$old_dir" "$new_dir" || return 1
    fi

    CLIENT_RENAME_RESULT="$new_name"
    success "Клиент '$old_name' переименован в '$new_name'"
}

_set_custom_nodes() {
    local client_name="$1"
    local client_group="$2"

    local node_count
    node_count=$(nodes_count)
    if [[ "$node_count" -eq 0 ]]; then
        warn "Нет нод."
        return
    fi
    # Текущие ноды клиента нужны для сохранения выбранных флагов.
    local current_nodes
    current_nodes=$(jq_r --arg n "$client_name" \
        '.clients[] | select(.name==$n) | .nodes // [] | join(",")')


    local node_names=() node_labels=() node_flags=()
    while IFS=$'\t' read -r nname nip; do
        node_names+=("$nname")
        node_labels+=("$nname  $nip")
        if echo ",$current_nodes," | grep -qF ",$nname,"; then
            node_flags+=(1)
        else
            node_flags+=(0)
        fi
    done < <(jq_r '.nodes[] | "\(.name)\t\(.ip):\(.port)"')

    TOGGLE_SELECT_ITEMS=("${node_labels[@]}")
    TOGGLE_SELECT_FLAGS=("${node_flags[@]}")
    toggle_select "Ноды для $client_name"
    local toggle_rc=$?
    node_flags=("${TOGGLE_SELECT_FLAGS[@]}")
    TOGGLE_SELECT_ITEMS=()
    TOGGLE_SELECT_FLAGS=()
    (( toggle_rc == 0 )) || return 1

    local selected_nodes=()
    local i=0
    for nname in "${node_names[@]}"; do
        [[ "${node_flags[$i]}" == "1" ]] && selected_nodes+=("$nname")
        i=$((i + 1))
    done

    local nodes_json='[]'
    if [[ ${#selected_nodes[@]} -gt 0 ]]; then
        nodes_json=$(printf '%s\n' "${selected_nodes[@]}" | jq -R . | jq -s .) || return 1
    fi

    jq_w --arg n "$client_name" --argjson nodes "$nodes_json" \
        '.clients |= map(if .name==$n then .inherit_nodes_from_group=false | .nodes=$nodes else . end)' || return 1

    local nodes_display
    nodes_display=$(IFS=', '; echo "${selected_nodes[*]}")
    success "$client_name: свои ноды — ${nodes_display:-нет}"
}

# Возвращает CSV нод, назначенных клиенту (inherit от группы или custom)
_collect_client_nodes() {
    local cname="$1"
    local cgroup cinherit
    cgroup=$(jq_r --arg n "$cname" '.clients[] | select(.name==$n) | .group')
    cinherit=$(jq_r --arg n "$cname" '.clients[] | select(.name==$n) | if .inherit_nodes_from_group == false then false else true end')
    if [[ "$cinherit" == "true" ]]; then
        _group_nodes_csv "$cgroup"
    else
        jq_r --arg n "$cname" '.clients[] | select(.name==$n) | .nodes // [] | join(",")'
    fi
}

# 0 если собственные или групповые подключения клиента включают AmneziaWG.
_client_has_awg_on_node() {
    local cname="$1" nname="$2" cnt
    cnt=$(jq_r --arg c "$cname" --arg n "$nname" '
        (.clients[] | select(.name==$c)) as $client |
        [($client.connections[]? | select(.node==$n) | .proxies[]?),
         (.connections[] | select(.node==$n) | .groups[] | select(.name==$client.group) | .proxies[]?)]
        | map(select(. == "AWG" or startswith("awg-"))) | length') || return 1
    [[ "$cnt" -gt 0 ]]
}

delete_client() {
    echo ""
    clients_list

    if [[ ${#CLIENTS[@]} -eq 0 ]]; then
        warn "Нет клиентов для удаления."
        return
    fi

    # Мульти-выбор
    local -a _flags=()
    local _i
    for (( _i=0; _i<${#CLIENTS[@]}; _i++ )); do _flags+=("0"); done

    TOGGLE_SELECT_ITEMS=("${CLIENTS[@]}")
    TOGGLE_SELECT_FLAGS=("${_flags[@]}")
    toggle_select "Выберите клиентов для удаления"
    local toggle_rc=$?
    _flags=("${TOGGLE_SELECT_FLAGS[@]}")
    TOGGLE_SELECT_ITEMS=()
    TOGGLE_SELECT_FLAGS=()
    (( toggle_rc == 0 )) || return 1

    local -a TARGETS=()
    for (( _i=0; _i<${#CLIENTS[@]}; _i++ )); do
        [[ "${_flags[$_i]}" == "1" ]] && TARGETS+=("${CLIENTS[$_i]}")
    done

    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        info "Ничего не выбрано."
        return
    fi
    # Собираем списки peers по нодам и затронутых нод.
    local -a _peer_nodes=() _peer_lists=() _affected_nodes=()
    local _cname _nodes_csv _nn
    local -a _cnodes

    for _cname in "${TARGETS[@]}"; do
        _nodes_csv=$(_collect_client_nodes "$_cname")
        [[ -z "$_nodes_csv" ]] && continue
        IFS=',' read -ra _cnodes <<< "$_nodes_csv"
        for _nn in "${_cnodes[@]}"; do
            [[ -z "$_nn" ]] && continue
            if ! array_contains "$_nn" "${_affected_nodes[@]}"; then
                _affected_nodes+=("$_nn")
            fi
            if _client_has_awg_on_node "$_cname" "$_nn"; then
                local _peer_idx=-1 _peer_i
                for (( _peer_i=0; _peer_i<${#_peer_nodes[@]}; _peer_i++ )); do
                    if [[ "${_peer_nodes[$_peer_i]}" == "$_nn" ]]; then
                        _peer_idx=$_peer_i
                        break
                    fi
                done
                if [[ $_peer_idx -ge 0 ]]; then
                    _peer_lists[$_peer_idx]+=" $_cname"
                else
                    _peer_nodes+=("$_nn")
                    _peer_lists+=(" $_cname")
                fi
            fi
        done
    done
    local _target_dirs=() _subscriptions=() _review=("Клиенты: ${TARGETS[*]}")
    local _token _host _addr _dir
    _host=$(jq_r '.subscription_host.node // "нет"')
    _review+=("Каталоги конфигов:")
    for _cname in "${TARGETS[@]}"; do
        _dir=$(_client_config_dir "$_cname")
        _target_dirs+=("$_dir")
        _review+=(" $_cname: $_dir")
        _token=$(jq_r --arg n "$_cname" '.clients[] | select(.name==$n) | .subscription.token // empty')
        [[ -n "$_token" ]] && _subscriptions+=("$_cname")
    done
    _review+=("Затронутые ноды:")
    [[ ${#_affected_nodes[@]} -gt 0 ]] || _review+=(" нет")
    for _nn in "${_affected_nodes[@]}"; do
        _addr=$(jq_r --arg n "$_nn" '.nodes[] | select(.name==$n) | "\(.ip):\(.port)"')
        _review+=(" $_nn  ${_addr:-не найдена}")
    done
    _review+=("Клиенты AmneziaWG:")
    [[ ${#_peer_nodes[@]} -gt 0 ]] || _review+=(" нет")
    for (( _i=0; _i<${#_peer_nodes[@]}; _i++ )); do
        _review+=(" ${_peer_nodes[$_i]}:${_peer_lists[$_i]}")
    done
    _review+=("Подписки: ${_subscriptions[*]:-нет}" "Хост подписок: $_host"
        "Локальные записи и сгенерированные конфиги будут удалены."
        "Подписки будут отозваны."
        "Клиенты AmneziaWG будут удалены; доступ в mihomo будет убран."
        "Служба mihomo на затронутых нодах будет перезапущена.")
    review_frame "Удаление клиентов" "${_review[@]}"
    confirm_yn "Удалить выбранных клиентов и их доступ?" N || { info "Отменено."; return 1; }

    # Доступ отзывается до локального удаления. Любой сбой сохраняет клиентов.
    for _cname in "${_subscriptions[@]}"; do
        if ! _subscription_revoke_silent "$_cname"; then
            warn "Удаление клиентов не завершено: подписки не удалось отозвать. Локальные клиенты сохранены."
            return 1
        fi
    done
    local _failed=0 _peers_list _peer _cmd _module
    for (( _i=0; _i<${#_peer_nodes[@]}; _i++ )); do
        _nn="${_peer_nodes[$_i]}"
        if ! node_load_by_name "$_nn" || ! ensure_remote_scripts_current; then
            warn "$_nn: не удалось подготовить удаление клиентов AmneziaWG."
            _failed=1
            continue
        fi
        array_contains "$_nn" "${SCRIPTS_READY[@]}" || SCRIPTS_READY+=("$_nn")
        printf -v _module %q "$REMOTE_DIR/modules/amneziawg.sh"
        _cmd="source $_module || exit 1; _remove_rc=0"
        _peers_list="${_peer_lists[$_i]# }"
        for _peer in $_peers_list; do
            _cmd+="; remove_awg_peer_by_name $(printf '%q' "$_peer") || _remove_rc=1"
        done
        _cmd+='; exit "$_remove_rc"'
        if ! ssh_run -- "$_cmd"; then
            warn "$_nn: не удалось удалить всех клиентов AmneziaWG."
            _failed=1
        fi
    done
    if (( _failed != 0 )); then
        warn "Удаление клиентов не завершено: клиентов AmneziaWG не удалось удалить. Локальные клиенты сохранены."
        return 1
    fi

    local names_json
    names_json=$(printf '%s\n' "${TARGETS[@]}" | jq -R . | jq -s .) || return 1
    jq_w --argjson names "$names_json" \
        '.clients |= [.[] | select(.name as $n | $names | index($n) | not)]' || return 1
    for _dir in "${_target_dirs[@]}"; do
        rm -rf "${_dir:?}" || _failed=1
    done
    local _remaining_users
    for _nn in "${_affected_nodes[@]}"; do
        if ! node_load_by_name "$_nn"; then _failed=1; continue; fi
        if ! _remaining_users=$(_build_node_users_cmd "$_nn"); then _failed=1; continue; fi
        [[ -n "$_remaining_users" ]] || continue
        if ! array_contains "$_nn" "${SCRIPTS_READY[@]}"; then
            if ! ensure_remote_scripts_current; then _failed=1; continue; fi
            SCRIPTS_READY+=("$_nn")
        fi
        if ssh_run -- "$_remaining_users"; then
            success "$_nn: входные подключения обновлены"
        else
            warn "$_nn: не удалось обновить входные подключения"
            _failed=1
        fi
    done
    if (( _failed != 0 )); then
        warn "Локальные клиенты удалены, но очистка завершена не полностью."
        return 1
    fi
    success "Удалено клиентов: ${#TARGETS[@]} (${TARGETS[*]})"
    return 0
}

# Формирует SSH-команду для sync всех типов listener'ов на ноде
# Args: nname
_build_node_users_cmd() {
    local nname="$1"

    # Собираем всех клиентов привязанных к этой ноде
    local users_data
    users_data=$(jq_r --arg n "$nname" '
        . as $root |
        [.clients[] |
            select(
                (.inherit_nodes_from_group != false and
                    (.group as $g | any(
                        $root.connections[];
                        .node == $n and any(.groups[]?; .name == $g)
                    ))) or
                (.inherit_nodes_from_group == false and
                    (.nodes // [] | index($n)))
            ) |
            {name: .name, vless_uuid: .credentials.vless_uuid, hy2_password: .credentials.hy2_password}
        ] | .[] | "\(.name) \(.vless_uuid) \(.hy2_password)"
    ' 2>/dev/null) || return 1

    # Формируем YAML-блоки
    local vless_tcp_users="" vless_xhttp_users="" vless_grpc_users="" hy2_users=""

    while IFS=' ' read -r _cname _cuuid _cpass; do
        [[ -z "$_cname" ]] && continue
        if [[ -n "$_cuuid" ]]; then
            vless_tcp_users+="      - username: ${_cname}"$'\n'
            vless_tcp_users+="        uuid: ${_cuuid}"$'\n'
            vless_tcp_users+="        flow: xtls-rprx-vision"$'\n'

            vless_xhttp_users+="      - username: ${_cname}"$'\n'
            vless_xhttp_users+="        uuid: ${_cuuid}"$'\n'

            vless_grpc_users+="      - username: ${_cname}"$'\n'
            vless_grpc_users+="        uuid: ${_cuuid}"$'\n'
        fi
        if [[ -n "$_cpass" ]]; then
            hy2_users+="      ${_cname}: ${_cpass}"$'\n'
        fi
    done <<< "$users_data"

    # Убираем trailing newline
    vless_tcp_users="${vless_tcp_users%$'\n'}"
    vless_xhttp_users="${vless_xhttp_users%$'\n'}"
    vless_grpc_users="${vless_grpc_users%$'\n'}"
    hy2_users="${hy2_users%$'\n'}"

    local module
    printf -v module %q "$REMOTE_DIR/common/listener-users.sh"
    local cmd="source $module || exit 1; _sync_rc=0"

    # Пробуем все типы — _sync_listener_users пропустит несуществующие
    for marker_type in vless-tcp vless-xhttp vless-grpc hy2; do
        local _users=""
        case "$marker_type" in
            vless-tcp)   _users="$vless_tcp_users" ;;
            vless-xhttp) _users="$vless_xhttp_users" ;;

            vless-grpc)  _users="$vless_grpc_users" ;;
            hy2)         _users="$hy2_users" ;;
        esac
        # Sync даже с пустыми users (все клиенты удалены)
        cmd+="; if grep -q '^# --- ${marker_type} ---\$' /etc/mihomo/config.yaml 2>/dev/null; then _sync_listener_users $(printf '%q' "$marker_type") $(printf '%q' "$_users") || _sync_rc=1; fi"
    done
    cmd+='; if [ -f /etc/mihomo/config.yaml ]; then systemctl restart mihomo || _sync_rc=1; fi; exit "$_sync_rc"'

    echo "$cmd"
}

_configure_client_connections() {
    local client_name="$1" client_group="$2"
    local client_nodes=() labels=() nname addr mode selected_node choice
    while true; do
        [[ -n "$(jq_r --arg c "$client_name" '.clients[] | select(.name==$c) | .name')" ]] || return 0
        client_nodes=()
        labels=()
        while IFS= read -r nname; do
            [[ -n "$nname" ]] || continue
            client_nodes+=("$nname")
            addr=$(jq_r --arg n "$nname" '.nodes[] | select(.name==$n) | "\(.ip):\(.port)"')
            mode=$(jq_r --arg c "$client_name" --arg n "$nname" \
                '.clients[] | select(.name==$c) | if any(.connections[]?; .node==$n) then "собственные" else "от группы" end')
            labels+=("$nname  ${addr:-не найдена} — $mode")
        done < <(jq_r --arg c "$client_name" '.clients[] | select(.name==$c) | .nodes[]?')
        MENU_SELECT_EMPTY="У клиента нет нод"
        menu_select "Подключения клиента: $client_name" "Выберите ноду" "${labels[@]}" || return 1
        selected_node="${client_nodes[$((MENU_SELECT_INDEX - 1))]}"
        while true; do
            mode=$(jq_r --arg c "$client_name" --arg n "$selected_node" \
                '.clients[] | select(.name==$c) | if any(.connections[]?; .node==$n) then "собственные" else "от группы" end')
            echo ""
            box_top
            box_center "Подключения клиента"
            box_mid
            box_line " Клиент: $client_name"
            box_line " Нода: $selected_node"
            box_line " Подключения: $mode"
            box_mid
            menu_item 1 "Настроить подключения" YELLOW
            [[ "$mode" == собственные ]] && menu_item 2 "Сбросить на групповые" RED
            menu_item 0 "Назад" NC
            box_bot
            echo ""
            IFS= read -rp "  Выберите действие: " choice || return 0
            choice="${choice%$'\r'}"
            case "$choice" in
                1) state_action "set_client_connections" _set_client_connections "$client_name" "$client_group" "$selected_node" ;;
                2)
                    if [[ "$mode" == собственные ]]; then
                        state_action "reset_client_connections" _reset_client_connections "$client_name" "$selected_node"
                    else warn "Неверный выбор."; fi ;;
                0) break ;;
                *) warn "Неверный выбор." ;;
            esac
        done
    done
}

_reset_client_connections() {
    review_frame "Сброс подключений клиента" "Клиент: $1" "Нода: $2" \
        "Собственные подключения будут удалены; будут применены подключения группы."
    confirm_yn "Сбросить подключения на групповые?" N || return 1
    _save_client_connections "$1" "$2" '[]'
}

_save_client_connections() {
    jq_w --arg c "$1" --arg n "$2" --argjson p "$3" \
        '.clients |= map(if .name==$c then .connections = ((.connections // []) | [.[] | select(.node!=$n)]) + (if ($p|length)>0 then [{node:$n, proxies:$p}] else [] end) else . end)' || return 1
    success "$1 → $2: подключения сохранены"
}

_set_client_connections() {
    local client_name="$1" client_group="$2" selected_node="$3"
    node_load_by_name "$selected_node" || return 1
    local discovered current d i toggle_rc proxies_json
    discovered=$(_discover_connections) || return 1
    [[ -n "$discovered" ]] || { warn "Не удалось обнаружить подключения на $selected_node."; return 1; }
    local disc_arr=() flags=() selected=()
    while IFS= read -r d; do [[ -n "$d" ]] && disc_arr+=("$d"); done <<< "$discovered"
    current=$(jq_r --arg c "$client_name" --arg n "$selected_node" \
        '.clients[] | select(.name==$c) | .connections[]? | select(.node==$n) | .proxies | join(",")')
    if [[ -z "$current" ]]; then
        current=$(jq_r --arg n "$selected_node" --arg g "$client_group" \
            '.connections[] | select(.node==$n) | .groups[] | select(.name==$g) | .proxies | join(",")')
    fi
    for d in "${disc_arr[@]}"; do
        case ",$current," in *",$d,"*) flags+=(1) ;; *) flags+=(0) ;; esac
    done
    TOGGLE_SELECT_ITEMS=("${disc_arr[@]}")
    TOGGLE_SELECT_FLAGS=("${flags[@]}")
    toggle_select "$client_name → $selected_node"
    toggle_rc=$?
    flags=("${TOGGLE_SELECT_FLAGS[@]}")
    TOGGLE_SELECT_ITEMS=()
    TOGGLE_SELECT_FLAGS=()
    (( toggle_rc == 0 )) || return 1
    for (( i=0; i<${#disc_arr[@]}; i++ )); do
        [[ "${flags[$i]}" == 1 ]] && selected+=("${disc_arr[$i]}")
    done
    proxies_json='[]'
    if [[ ${#selected[@]} -gt 0 ]]; then
        proxies_json=$(printf '%s\n' "${selected[@]}" | jq -R . | jq -s .) || return 1
    fi
    _save_client_connections "$client_name" "$selected_node" "$proxies_json"
}
