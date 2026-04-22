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
        box_bot
        echo ""

        _list_clients_display

        echo ""
        echo -e "  ${GREEN}a)${NC} Добавить клиента"
        echo -e "  ${YELLOW}e)${NC} Редактировать клиента"
        echo -e "  ${RED}d)${NC} Удалить клиента"
        echo -e "  ${NC}0)${NC} Назад"
        echo ""
        read -rp "Выберите: " CL_CHOICE

        case "$CL_CHOICE" in
            a) add_client ;;
            e) edit_client ;;
            d) delete_client ;;
            0) return ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

_list_clients_display() {
    local count
    count=$(jq_r '.clients | length')
    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${DIM}Нет клиентов${NC}"
        return
    fi

    local i=1
    while IFS='|' read -r name group inherit; do
        local nodes_display
        if [[ "$inherit" == "true" ]]; then
            nodes_display=$(_group_nodes_csv "$group")
            nodes_display="${nodes_display//,/, }"
            [[ -z "$nodes_display" ]] && nodes_display="нет нод"
            nodes_display="${DIM}(группа: $nodes_display)${NC}"
        else
            nodes_display=$(jq_r --arg n "$name" '.clients[] | select(.name==$n) | .nodes // [] | sort | join(", ")')
            [[ -z "$nodes_display" ]] && nodes_display="нет нод"
            nodes_display="${YELLOW}[$nodes_display]${NC}"
        fi
        printf "  ${GREEN}%d)${NC} %-18s ${CYAN}%-8s${NC} %b\n" "$i" "$name" "$group" "$nodes_display"
        i=$((i + 1))
    done < <(jq_r '.clients[] | "\(.name)|\(.group)|\(if .inherit_nodes_from_group == false then false else true end)"')
}

clients_list() {
    CLIENTS=()
    mapfile -t CLIENTS < <(jq_r '.clients[] | .name')
}

add_client() {
    echo ""
    read -rp "Имя клиента: " CLIENT_NAME
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
        '.clients += [{name:$n, group:$g, inherit_nodes_from_group:true, nodes:[], connections:[], credentials:{vless_uuid:$uuid, hy2_password:$hy2pass}}]'

    success "Клиент $CLIENT_NAME добавлен ($group, ноды от группы)"
}

edit_client() {
    echo ""
    clients_list

    if [[ ${#CLIENTS[@]} -eq 0 ]]; then
        warn "Нет клиентов."
        return
    fi

    local i=1
    for name in "${CLIENTS[@]}"; do
        echo -e "  ${GREEN}${i})${NC} $name"
        i=$((i + 1))
    done
    echo ""
    read -rp "Номер клиента: " EDIT_IDX

    if ! [[ "$EDIT_IDX" =~ ^[0-9]+$ ]] || (( EDIT_IDX < 1 || EDIT_IDX > ${#CLIENTS[@]} )); then
        warn "Неверный выбор."
        return
    fi

    local target="${CLIENTS[$((EDIT_IDX - 1))]}"
    local current_group
    current_group=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | .group')
    local current_inherit
    current_inherit=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | if .inherit_nodes_from_group == false then false else true end')

    echo ""
    info "Клиент: $target"
    info "Группа: $current_group"

    if [[ "$current_inherit" == "true" ]]; then
        local group_nodes
        group_nodes=$(_group_nodes_csv "$current_group")
        group_nodes="${group_nodes//,/, }"
        info "Ноды: от группы (${group_nodes:-нет})"
        echo ""
        echo -e "  ${GREEN}1)${NC} Назначить свои ноды (отвязать от группы)"
        echo -e "  ${CYAN}g)${NC} Поменять группу"
        echo -e "  ${YELLOW}r)${NC} Переименовать клиента"
        echo -e "  ${NC}0)${NC} Назад"
        echo ""
        read -rp "Выберите: " EDIT_CHOICE

        case "$EDIT_CHOICE" in
            1) _set_custom_nodes "$target" "$current_group" ;;
            g|G) _change_client_group "$target" "$current_group" ;;
            r|R) _rename_client "$target" ;;
            0) return ;;
            *) warn "Неверный выбор." ;;
        esac
    else
        local custom_nodes
        custom_nodes=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | .nodes // [] | join(", ")')
        local custom_conns_count
        custom_conns_count=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | .connections // [] | length')
        info "Ноды: свои (${custom_nodes:-нет})"
        [[ "$custom_conns_count" -gt 0 ]] && info "Кастомные подключения: $custom_conns_count нод"
        echo ""
        echo -e "  ${GREEN}1)${NC} Вернуть ноды от группы"
        echo -e "  ${GREEN}2)${NC} Изменить свои ноды"
        echo -e "  ${GREEN}3)${NC} Настроить подключения для нод"
        echo -e "  ${CYAN}g)${NC} Поменять группу"
        echo -e "  ${YELLOW}r)${NC} Переименовать клиента"
        echo -e "  ${NC}0)${NC} Назад"
        echo ""
        read -rp "Выберите: " EDIT_CHOICE

        case "$EDIT_CHOICE" in
            1)
                jq_w --arg n "$target" \
                    '.clients |= map(if .name==$n then .inherit_nodes_from_group=true | del(.nodes) | del(.connections) else . end)'
                success "$target: ноды от группы"
                ;;
            2) _set_custom_nodes "$target" "$current_group" ;;
            3) _configure_client_connections "$target" "$current_group" ;;
            g|G) _change_client_group "$target" "$current_group" ;;
            r|R) _rename_client "$target" ;;
            0) return ;;
            *) warn "Неверный выбор." ;;
        esac
    fi
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

    echo ""
    echo -e "  Текущая группа: ${CYAN}$current_group${NC}"
    echo -e "  Выберите новую группу:"
    local i=1
    for g in "${other_groups[@]}"; do
        local count
        count=$(_group_client_count "$g")
        local tpl
        tpl=$(jq_r --arg g "$g" '.groups[] | select(.name==$g) | .template // "default.yaml"')
        echo -e "  ${GREEN}${i})${NC} $g ${DIM}— $count клиентов, $tpl${NC}"
        i=$((i + 1))
    done
    echo -e "  ${NC}0)${NC} Отмена"
    echo ""
    read -rp "Выберите: " GRP_IDX

    [[ "$GRP_IDX" == "0" ]] && return
    if ! [[ "$GRP_IDX" =~ ^[0-9]+$ ]] || (( GRP_IDX < 1 || GRP_IDX > ${#other_groups[@]} )); then
        warn "Неверный выбор."
        return
    fi

    local new_group="${other_groups[$((GRP_IDX - 1))]}"

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
        warn "У клиента есть $client_conns_count кастомных подключений — они сохранятся, но проверьте актуальность через пункт '3)'."
    fi

    local gh_count
    gh_count=$(jq_r --arg g "$current_group" '.groups[] | select(.name==$g) | .subscription_headers // [] | length')
    if [[ "$gh_count" -gt 0 ]]; then
        warn "Групповые subscription headers (${gh_count}) старой группы больше не будут применяться."
    fi

    echo ""
    confirm_yn "Перенести '$target' в группу '$new_group'?" || { info "Отменено."; return; }

    # Собираем affected_nodes ДО изменения JSON
    local affected_nodes=()
    declare -A _aff_seen=()
    local _csv _n
    local -a _arr

    _csv=$(_group_nodes_csv "$current_group")
    IFS=',' read -ra _arr <<< "$_csv"
    for _n in "${_arr[@]}"; do
        [[ -z "$_n" || -n "${_aff_seen[$_n]+x}" ]] && continue
        _aff_seen[$_n]=1
        affected_nodes+=("$_n")
    done

    _csv=$(_group_nodes_csv "$new_group")
    IFS=',' read -ra _arr <<< "$_csv"
    for _n in "${_arr[@]}"; do
        [[ -z "$_n" || -n "${_aff_seen[$_n]+x}" ]] && continue
        _aff_seen[$_n]=1
        affected_nodes+=("$_n")
    done

    if [[ "$inherit" != "true" ]]; then
        _csv=$(jq_r --arg n "$target" '.clients[] | select(.name==$n) | .nodes // [] | join(",")')
        IFS=',' read -ra _arr <<< "$_csv"
        for _n in "${_arr[@]}"; do
            [[ -z "$_n" || -n "${_aff_seen[$_n]+x}" ]] && continue
            _aff_seen[$_n]=1
            affected_nodes+=("$_n")
        done
    fi

    # Путь старой папки клиента (не группы!) — снимается до jq_w, т.к. после
    # изменения group этот же клиент будет смотреть в новую подпапку.
    local old_dir
    old_dir=$(_client_config_dir "$target")

    # Атомарное обновление group
    jq_w --arg n "$target" --arg g "$new_group" \
        '.clients |= map(if .name==$n then .group=$g else . end)'
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
        subscription_publish "$target"
    else
        info "У клиента нет подписки — пропуск publish."
    fi
}

_rename_client() {
    local old_name="$1"
    echo ""
    read -rp "  Новое имя [${old_name}]: " new_name
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
        '.clients |= map(if .name==$old then .name=$new else . end)'

    local new_dir
    new_dir=$(_client_config_dir "$new_name")

    if [[ -d "$old_dir" ]]; then
        mkdir -p "$(dirname "$new_dir")"
        mv "$old_dir" "$new_dir"
    fi

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

    # Текущие ноды клиента (если есть)
    local current_nodes
    current_nodes=$(jq_r --arg n "$client_name" '.clients[] | select(.name==$n) | .nodes // [] | join(",")')

    local node_names=() node_labels=() node_flags=()
    while IFS=$'\t' read -r nname nip; do
        node_names+=("$nname")
        node_labels+=("$nname ${DIM}$nip${NC}")
        if echo ",$current_nodes," | grep -qF ",$nname,"; then
            node_flags+=(1)
        else
            node_flags+=(0)
        fi
    done < <(jq_r '.nodes[] | "\(.name)\t\(.ip)"')

    toggle_select "Ноды для ${CYAN}$client_name${NC}" node_labels node_flags

    local selected_nodes=()
    local i=0
    for nname in "${node_names[@]}"; do
        [[ "${node_flags[$i]}" == "1" ]] && selected_nodes+=("$nname")
        i=$((i + 1))
    done

    local nodes_json
    nodes_json=$(printf '%s\n' "${selected_nodes[@]}" | jq -R . | jq -s .)

    jq_w --arg n "$client_name" --argjson nodes "$nodes_json" \
        '.clients |= map(if .name==$n then .inherit_nodes_from_group=false | .nodes=$nodes else . end)'

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

# 0 если у клиента есть AWG подключение на ноде (через его группу), иначе 1
_client_has_awg_on_node() {
    local cname="$1" nname="$2"
    local cgroup cnt
    cgroup=$(jq_r --arg n "$cname" '.clients[] | select(.name==$n) | .group')
    cnt=$(jq_r --arg n "$nname" --arg g "$cgroup" \
        '[(.connections[] | select(.node==$n) | .groups[] | select(.name==$g) | .proxies[] | select(. == "AWG" or startswith("awg-")))] | length')
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

    toggle_select "Выберите клиентов для удаления" CLIENTS _flags

    local -a TARGETS=()
    for (( _i=0; _i<${#CLIENTS[@]}; _i++ )); do
        [[ "${_flags[$_i]}" == "1" ]] && TARGETS+=("${CLIENTS[$_i]}")
    done

    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        info "Ничего не выбрано."
        return
    fi

    echo ""
    echo -e "  Будут удалены: ${YELLOW}${TARGETS[*]}${NC}"
    confirm_yn "Подтвердить удаление (${#TARGETS[@]})?" || { info "Отменено."; return; }

    # План: NODE_PEERS[node]=" c1 c2 ..." (только AWG-peers) + AFFECTED_NODES
    local -A NODE_PEERS=()
    local -A _AFFECTED=()
    local _cname _nodes_csv _nn
    local -a _cnodes

    for _cname in "${TARGETS[@]}"; do
        _nodes_csv=$(_collect_client_nodes "$_cname")
        [[ -z "$_nodes_csv" ]] && continue
        IFS=',' read -ra _cnodes <<< "$_nodes_csv"
        for _nn in "${_cnodes[@]}"; do
            [[ -z "$_nn" ]] && continue
            _AFFECTED["$_nn"]=1
            if _client_has_awg_on_node "$_cname" "$_nn"; then
                NODE_PEERS["$_nn"]+=" $_cname"
            fi
        done
    done

    # Batch AWG peer removal — один SSH на ноду, разделитель `;` чтобы
    # отсутствие одного peer не рвало цепочку (remove_awg_peer_by_name
    # возвращает 1 для уже удалённых)
    if [[ ${#NODE_PEERS[@]} -gt 0 ]] && confirm_yn "Удалить AWG peers на нодах (${#NODE_PEERS[@]})?"; then
        local _peers_list _peer _cmd
        for _nn in "${!NODE_PEERS[@]}"; do
            if ! node_load_by_name "$_nn"; then
                warn "$_nn: не удалось подключиться — AWG peers не удалены."
                continue
            fi
            if [[ -z "${SCRIPTS_UPLOADED[$_nn]+x}" ]]; then
                upload_scripts
                SCRIPTS_UPLOADED[$_nn]=1
            fi
            _peers_list="${NODE_PEERS[$_nn]# }"
            info "Удаляю AWG peers на $_nn: $_peers_list"
            _cmd="source ${REMOTE_DIR}/modules/amneziawg.sh"
            for _peer in $_peers_list; do
                _cmd+=" ; remove_awg_peer_by_name $(printf '%q' "$_peer")"
            done
            if ssh_run -- "$_cmd" 2>/dev/null; then
                success "$_nn: AWG peers удалены"
            else
                warn "$_nn: ошибка при удалении AWG peers"
            fi
        done
    fi

    # Отзываем подписки до удаления из JSON (silent — без лишних confirm).
    # _sub_load_host меняет SSH-контекст; делаем это до listener-sync.
    local _has_sub
    for _cname in "${TARGETS[@]}"; do
        _has_sub=$(jq_r --arg n "$_cname" '.clients[] | select(.name==$n) | .subscription.token // empty')
        [[ -n "$_has_sub" ]] && _subscription_revoke_silent "$_cname"
    done

    # Сохраняем пути до jq_w: после него .group недоступна
    local -a _target_dirs=()
    for _cname in "${TARGETS[@]}"; do
        _target_dirs+=("$(_client_config_dir "$_cname")")
    done

    # Один jq_w для всех клиентов
    local names_json
    names_json=$(printf '%s\n' "${TARGETS[@]}" | jq -R . | jq -s .)
    jq_w --argjson names "$names_json" \
        '.clients |= [.[] | select(.name as $n | $names | index($n) | not)]'

    for _dir in "${_target_dirs[@]}"; do
        rm -rf "${_dir:?}" 2>/dev/null
    done

    # Listener-sync — один SSH на затронутую ноду (после batch-удаления из JSON,
    # чтобы _build_node_users_cmd собрал уже финальный состав пользователей)
    for _nn in "${!_AFFECTED[@]}"; do
        if ! node_load_by_name "$_nn"; then continue; fi

        local _remaining_users
        _remaining_users=$(_build_node_users_cmd "$_nn")
        [[ -z "$_remaining_users" ]] && continue

        if [[ -z "${SCRIPTS_UPLOADED[$_nn]+x}" ]]; then
            upload_scripts
            SCRIPTS_UPLOADED[$_nn]=1
        fi

        if ssh_run -- "$_remaining_users" 2>/dev/null; then
            success "$_nn: listeners обновлены"
        else
            warn "$_nn: не удалось обновить listeners"
        fi
    done

    success "Удалено клиентов: ${#TARGETS[@]} (${TARGETS[*]})"
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
    ' 2>/dev/null) || true

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

    local cmd="source ${REMOTE_DIR}/common/listener-users.sh"
    local has_any=false

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
        cmd+="; _sync_listener_users $(printf '%q' "$marker_type") $(printf '%q' "$_users") 2>/dev/null"
        has_any=true
    done

    $has_any && cmd+="; systemctl restart mihomo"

    echo "$cmd"
}

_configure_client_connections() {
    local client_name="$1"
    local client_group="$2"

    # Получаем ноды клиента
    local client_nodes=()
    mapfile -t client_nodes < <(jq_r --arg n "$client_name" '.clients[] | select(.name==$n) | .nodes // [] | .[]')

    if [[ ${#client_nodes[@]} -eq 0 ]]; then
        warn "У клиента нет нод. Сначала назначьте ноды."
        return
    fi

    echo ""
    echo -e "  Ноды клиента ${CYAN}$client_name${NC}:"
    local i=1
    for nname in "${client_nodes[@]}"; do
        local has_custom
        has_custom=$(jq_r --arg c "$client_name" --arg n "$nname" \
            '.clients[] | select(.name==$c) | .connections // [] | .[] | select(.node==$n) | "yes"')
        local marker=""
        [[ "$has_custom" == "yes" ]] && marker=" ${YELLOW}(кастомные)${NC}" || marker=" ${DIM}(от группы)${NC}"
        echo -e "  ${GREEN}${i})${NC} $nname${marker}"
        i=$((i + 1))
    done
    echo -e "  ${NC}0)${NC} Назад"
    echo ""
    read -rp "Выберите ноду: " NODE_IDX

    [[ "$NODE_IDX" == "0" ]] && return
    if ! [[ "$NODE_IDX" =~ ^[0-9]+$ ]] || (( NODE_IDX < 1 || NODE_IDX > ${#client_nodes[@]} )); then
        warn "Неверный выбор."
        return
    fi

    local selected_node="${client_nodes[$((NODE_IDX - 1))]}"

    # Загружаем ноду и обнаруживаем подключения
    if ! node_load_by_name "$selected_node"; then
        warn "Нода $selected_node не найдена."
        return
    fi

    info "Подключаюсь к $selected_node..."
    local discovered
    discovered=$(_discover_connections)
    if [[ -z "$discovered" ]]; then
        warn "Не удалось обнаружить подключения на $selected_node."
        warn "Перейдите в ноду и настройте VLESS, Hysteria2 или AmneziaWG."
        return
    fi

    local disc_arr=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && disc_arr+=("$line")
    done <<< "$discovered"

    # Текущие подключения: клиентские или групповые
    local current_conns
    current_conns=$(jq_r --arg c "$client_name" --arg n "$selected_node" \
        '.clients[] | select(.name==$c) | .connections // [] | .[] | select(.node==$n) | .proxies | join(",")')

    local using_custom=false
    if [[ -n "$current_conns" ]]; then
        using_custom=true
    else
        current_conns=$(jq_r --arg n "$selected_node" --arg g "$client_group" \
            '.connections[] | select(.node==$n) | .groups[] | select(.name==$g) | .proxies | join(",")')
    fi

    echo ""
    if [[ "$using_custom" == "true" ]]; then
        info "Текущие подключения: ${YELLOW}кастомные${NC}"
    else
        info "Текущие подключения: от группы"
    fi

    # Флаги
    local flags=()
    for d in "${disc_arr[@]}"; do
        if echo ",$current_conns," | grep -qF ",$d,"; then
            flags+=(1)
        else
            flags+=(0)
        fi
    done

    echo ""
    echo -e "  ${GREEN}1)${NC} Настроить подключения"
    [[ "$using_custom" == "true" ]] && echo -e "  ${GREEN}2)${NC} Сбросить на групповые"
    echo -e "  ${NC}0)${NC} Назад"
    echo ""
    read -rp "Выберите: " CONN_CHOICE

    case "$CONN_CHOICE" in
        1)
            toggle_select "${CYAN}$client_name -> $selected_node${NC}" disc_arr flags

            local selected=()
            local i=0
            for d in "${disc_arr[@]}"; do
                [[ "${flags[$i]}" == "1" ]] && selected+=("$d")
                i=$((i + 1))
            done

            local proxies_json
            proxies_json=$(printf '%s\n' "${selected[@]}" | jq -R . | jq -s .)

            # Сохраняем в client.connections — удаляем старую запись и добавляем новую
            if [[ ${#selected[@]} -gt 0 ]]; then
                jq_w --arg c "$client_name" --arg n "$selected_node" --argjson p "$proxies_json" \
                    '.clients |= map(if .name==$c then .connections = ((.connections // []) | [.[] | select(.node!=$n)]) + [{node:$n, proxies:$p}] else . end)'
            else
                # Пустой выбор — удаляем запись
                jq_w --arg c "$client_name" --arg n "$selected_node" \
                    '.clients |= map(if .name==$c then .connections = ((.connections // []) | [.[] | select(.node!=$n)]) else . end)'
            fi
            success "$client_name -> $selected_node: подключения сохранены"
            ;;
        2)
            if [[ "$using_custom" == "true" ]]; then
                jq_w --arg c "$client_name" --arg n "$selected_node" \
                    '.clients |= map(if .name==$c then .connections = ((.connections // []) | [.[] | select(.node!=$n)]) else . end)'
                success "$client_name -> $selected_node: подключения от группы"
            fi
            ;;
        0) return ;;
        *) warn "Неверный выбор." ;;
    esac
}
