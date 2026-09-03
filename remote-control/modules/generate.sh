#!/bin/bash
# ─── Генерация клиентских конфигов ─────────────────────────────────────────

edit_template() {
    local templates=()
    while IFS= read -r template_name; do
        [[ -n "$template_name" ]] && templates+=("$template_name")
    done < <(_list_templates)

    echo ""
    echo -e "  Выберите шаблон для редактирования:"
    local i=1 t
    for t in "${templates[@]}"; do
        echo -e "  ${GREEN}${i})${NC} $t"
        i=$((i + 1))
    done
    echo -e "  ${GREEN}n)${NC} Создать новый шаблон"
    echo ""
    read -rp "Выберите: " TPL_CHOICE

    local template="" source=""
    mkdir -p "$TEMPLATES_DIR" || return 1
    if [[ "$TPL_CHOICE" == "n" || "$TPL_CHOICE" == "N" ]]; then
        read -rp "Имя нового шаблона (без .yaml): " TPL_NAME
        if [[ -z "$TPL_NAME" || ! "$TPL_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
            warn "Имя может содержать только буквы, цифры, точку, - и _"
            return
        fi

        template="$TEMPLATES_DIR/${TPL_NAME}.yaml"
        if [[ -f "$template" ]]; then
            warn "Шаблон '${TPL_NAME}.yaml' уже существует."
            return
        fi
        source=$(_find_template "default.yaml")
        if [[ -n "$source" ]]; then
            cp "$source" "$template" || return 1
            info "Скопирован default.yaml как основа"
        else
            : > "$template"
        fi
    elif [[ "$TPL_CHOICE" =~ ^[0-9]+$ ]] &&
         (( TPL_CHOICE >= 1 && TPL_CHOICE <= ${#templates[@]} )); then
        local selected="${templates[$((TPL_CHOICE - 1))]}"
        source=$(_find_template "$selected")
        [[ -n "$source" ]] || { warn "Шаблон не найден."; return 1; }
        template="$TEMPLATES_DIR/$selected"
        if [[ "$source" != "$template" ]]; then
            cp "$source" "$template" || return 1
        fi
    else
        warn "Неверный выбор."
        return
    fi

    if command -v nano > /dev/null 2>&1; then
        nano "$template"
    elif command -v vi > /dev/null 2>&1; then
        vi "$template"
    else
        warn "Редактор не найден. Отредактируйте вручную:"
        info "$template"
    fi
}

generate_menu() {
    while true; do
        echo ""
        box_top
        box_center "Генерация конфигов"
        box_bot

        # Показываем группы и их шаблоны
        groups_list
        if [[ ${#GRP_LIST[@]} -gt 0 ]]; then
            echo ""
            for g in "${GRP_LIST[@]}"; do
                local tpl
                tpl=$(_template_name_for_group "$g")
                local client_count
                client_count=$(jq_r --arg g "$g" '[.clients[] | select(.group==$g)] | length')
                echo -e "  ${CYAN}$g${NC} ${DIM}— $tpl, $client_count клиентов${NC}"
            done
        fi

        echo ""
        echo -e "  ${GREEN}g)${NC} По группе"
        echo -e "  ${GREEN}a)${NC} Всем клиентам"
        echo -e "  ${YELLOW}t)${NC} Редактировать шаблон"
        echo -e "  ${NC}0)${NC} Назад"
        echo ""
        read -rp "Выберите: " GEN_CHOICE

        case "$GEN_CHOICE" in
            g|G) generate_by_group ;;
            a|A) generate_all ;;
            t|T) state_action "edit_template" edit_template ;;
            0) return ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

generate_by_group() {
    _reset_node_cache
    echo ""
    echo -e "  Выберите группу для генерации:"
    if ! select_group; then return; fi
    _generate_group "$SELECTED_GROUP"

    # Синхронизация per-client users на нодах группы
    local _group_nodes=()
    local _gn_csv
    _gn_csv=$(_group_nodes_csv "$SELECTED_GROUP")
    IFS=',' read -ra _group_nodes <<< "$_gn_csv"
    # Добавляем кастомные ноды клиентов группы
    while IFS= read -r _cn; do
        [[ -z "$_cn" ]] && continue
        local _already=false
        for _ex in "${_group_nodes[@]}"; do [[ "$_ex" == "$_cn" ]] && _already=true; done
        $_already || _group_nodes+=("$_cn")
    done < <(jq_r --arg g "$SELECTED_GROUP" '.clients[] | select(.group==$g and .inherit_nodes_from_group==false) | .nodes // [] | .[]')
    [[ ${#_group_nodes[@]} -gt 0 ]] && _sync_listeners_on_nodes "${_group_nodes[@]}"

    _subscription_prompt_refresh
}

generate_all() {
    _reset_node_cache
    echo ""
    groups_list
    if [[ ${#GRP_LIST[@]} -eq 0 ]]; then
        warn "Нет групп."
        return
    fi

    # Собрать все уникальные ноды и клиентов по всем группам заранее,
    # чтобы сделать AWG peers + prefetch конфигов одним проходом
    local all_client_names=()
    local all_unique_nodes=()

    for g in "${GRP_LIST[@]}"; do
        local _gnodes_csv
        _gnodes_csv=$(_group_nodes_csv "$g")
        local -a _gnodes
        IFS=',' read -ra _gnodes <<< "$_gnodes_csv"
        for _n in "${_gnodes[@]}"; do
            [[ -z "$_n" ]] && continue
            if ! array_contains "$_n" "${all_unique_nodes[@]}"; then
                all_unique_nodes+=("$_n")
            fi
        done

        while IFS= read -r _cl; do
            local _cname="${_cl%%|*}"
            if ! array_contains "$_cname" "${all_client_names[@]}"; then
                all_client_names+=("$_cname")
            fi
            local _rest="${_cl#*|}"
            local _inherit="${_rest%%|*}"
            local _own="${_rest#*|}"
            if [[ "$_inherit" != "true" && -n "$_own" ]]; then
                local -a _cnodes
                IFS=',' read -ra _cnodes <<< "$_own"
                for _n in "${_cnodes[@]}"; do
                    [[ -z "$_n" ]] && continue
                    if ! array_contains "$_n" "${all_unique_nodes[@]}"; then
                        all_unique_nodes+=("$_n")
                    fi
                done
            fi
        done < <(jq_r --arg g "$g" \
            '.clients[] | select(.group==$g) | "\(.name)|\(if .inherit_nodes_from_group == false then false else true end)|\(.nodes // [] | join(","))"')
    done

    # Один проход: AWG peers на всех нодах для всех клиентов
    _ensure_all_awg_peers "${#all_client_names[@]}" "${all_client_names[@]}" "${all_unique_nodes[@]}"
    # Один проход: предзагрузка конфигов
    _prefetch_node_configs "${all_unique_nodes[@]}"

    # Генерация (0 SSH — всё в кеше)
    for g in "${GRP_LIST[@]}"; do
        _generate_group "$g"
    done

    # Синхронизация per-client users на нодах
    _sync_listeners_on_nodes "${all_unique_nodes[@]}"

    echo ""
    success "Все конфиги обновлены."
    info "Конфиги: $GENERATED_DIR/"
    _subscription_prompt_refresh
}
# ─── Кеш конфигов нод ──────────────────────────────────────────────────────
NODE_CONFIG_CACHE_KEYS=()
NODE_CONFIG_CACHE_VALUES=()
NODE_CONFIG_FAILED=()
SCRIPTS_UPLOADED=()
AWG_PEERS_CHECKED=()

_reset_node_cache() {
    NODE_CONFIG_CACHE_KEYS=()
    NODE_CONFIG_CACHE_VALUES=()
    NODE_CONFIG_FAILED=()
    SCRIPTS_UPLOADED=()
    AWG_PEERS_CHECKED=()
}

# Получить client-config.txt из кеша (без SSH)
_get_node_config() {
    local nname="$1"
    local i

    for i in "${!NODE_CONFIG_CACHE_KEYS[@]}"; do
        if [[ "${NODE_CONFIG_CACHE_KEYS[$i]}" == "$nname" ]]; then
            echo "${NODE_CONFIG_CACHE_VALUES[$i]}"
            return 0
        fi
    done

    array_contains "$nname" "${NODE_CONFIG_FAILED[@]}" && return 1

    # Не должно вызываться напрямую — только после _prefetch
    return 1
}

_node_config_cache_set() {
    local nname="$1" value="$2"
    local i
    for i in "${!NODE_CONFIG_CACHE_KEYS[@]}"; do
        if [[ "${NODE_CONFIG_CACHE_KEYS[$i]}" == "$nname" ]]; then
            NODE_CONFIG_CACHE_VALUES[$i]="$value"
            return 0
        fi
    done
    NODE_CONFIG_CACHE_KEYS+=("$nname")
    NODE_CONFIG_CACHE_VALUES+=("$value")
}

_node_config_cache_delete() {
    local nname="$1"
    local i
    for i in "${!NODE_CONFIG_CACHE_KEYS[@]}"; do
        if [[ "${NODE_CONFIG_CACHE_KEYS[$i]}" == "$nname" ]]; then
            unset "NODE_CONFIG_CACHE_KEYS[$i]" "NODE_CONFIG_CACHE_VALUES[$i]"
            return 0
        fi
    done
    return 1
}

# Предзагрузка конфигов со всех нод (один SSH на ноду)
_prefetch_node_configs() {
    local nodes=("$@")

    for nname in "${nodes[@]}"; do
        # Уже в кеше или уже провалилась
        if array_contains "$nname" "${NODE_CONFIG_CACHE_KEYS[@]}" ||
           array_contains "$nname" "${NODE_CONFIG_FAILED[@]}"; then
            continue
        fi

        if ! node_load_by_name "$nname"; then
            warn "Нода $nname не найдена."
            NODE_CONFIG_FAILED+=("$nname")
            continue
        fi

        info "Подключаюсь к $nname..."

        local remote_config
        remote_config=$(ssh_run -- "cat /etc/mihomo/client-config.txt 2>/dev/null; cat /etc/mihomo/amnezia/*/mihomo-proxy.yaml 2>/dev/null; true") || {
            warn "Не удалось получить конфиг с $nname"
            NODE_CONFIG_FAILED+=("$nname")
            continue
        }

        _node_config_cache_set "$nname" "$remote_config"
        success "$nname — конфиг загружен"
    done
}

# Батч создание AWG peers на всех нодах для всех клиентов группы.
# Первый аргумент — число клиентских имён, затем клиентские имена и ноды.
_ensure_all_awg_peers() {
    [[ $# -ge 1 ]] || return 1

    local client_count="$1"
    [[ "$client_count" =~ ^[0-9]+$ ]] || return 1
    client_count=$((10#$client_count))
    shift
    (( $# >= client_count )) || return 1

    local -a client_names=()
    local i
    for (( i=0; i<client_count; i++ )); do
        client_names+=("$1")
        shift
    done
    local nodes=("$@")

    for nname in "${nodes[@]}"; do
        array_contains "$nname" "${NODE_CONFIG_FAILED[@]}" && continue
        array_contains "$nname" "${AWG_PEERS_CHECKED[@]}" && continue

        if ! node_load_by_name "$nname"; then
            continue
        fi

        # Проверяем AWG + какие peers уже существуют — одним SSH
        local check_result
        check_result=$(ssh_run -- "if [ ! -f /etc/amnezia/amneziawg/awg0.conf ]; then echo NO_AWG; else echo AWG_OK; ls /etc/mihomo/amnezia/; fi") \
            || continue

        # AWG не установлен на ноде
        if [[ "$check_result" == "NO_AWG" ]]; then
            AWG_PEERS_CHECKED+=("$nname")
            continue
        fi

        # Собираем имена существующих peers
        local existing_peers
        existing_peers=$(echo "$check_result" | tail -n +2 | tr -d '\r')

        # Определяем какие peers нужно создать
        local missing=()
        local cname
        for cname in "${client_names[@]}"; do
            if ! echo "$existing_peers" | grep -qxF "$cname"; then
                missing+=("$cname")
            fi
        done

        if [[ ${#missing[@]} -eq 0 ]]; then
            AWG_PEERS_CHECKED+=("$nname")
            continue
        fi

        # Создаём все недостающие peers за один SSH
        info "Создаю AWG peers на $nname: ${missing[*]}..."
        if ! array_contains "$nname" "${SCRIPTS_UPLOADED[@]}"; then
            upload_scripts
            SCRIPTS_UPLOADED+=("$nname")
        fi

        local peers_cmd="source ${REMOTE_DIR}/modules/amneziawg.sh"
        for cname in "${missing[@]}"; do
            peers_cmd="$peers_cmd && add_awg_peer_auto $(printf '%q' "$cname")"
        done

        ssh_run -- "$peers_cmd" || {
            warn "Ошибка при создании AWG peers на $nname"
        }

        # Инвалидируем кеш — конфиг ноды изменился (новые peers)
        _node_config_cache_delete "$nname"
        AWG_PEERS_CHECKED+=("$nname")
    done
}

_render_client_config() {
    local processed_template="$1"
    local proxy_entries="$2"
    local found_anchor=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line"
        if [[ "$line" == "proxies:" ]]; then
            found_anchor=1
            if [[ -n "$proxy_entries" ]]; then
                printf '%s\n' "$proxy_entries"
            fi
        fi
    done <<< "$processed_template"

    [[ -z "$proxy_entries" || "$found_anchor" -eq 1 ]]
}

_generate_group() {
    local group="$1"
    local tpl_name
    tpl_name=$(_template_name_for_group "$group")
    local template
    template=$(_template_for_group "$group")

    if [[ -z "$template" ]]; then
        warn "Шаблон '$tpl_name' не найден для группы $group. Поместите файл в $TEMPLATES_DIR/"
        return
    fi

    # Ноды группы
    local group_nodes_csv
    group_nodes_csv=$(_group_nodes_csv "$group")

    # Клиенты группы
    local group_clients=()
    while IFS= read -r client_line; do
        group_clients+=("$client_line")
    done < <(jq_r --arg g "$group" \
        '.clients[] | select(.group==$g) | "\(.name)|\(.group)|\(if .inherit_nodes_from_group == false then false else true end)|\(.nodes // [] | join(","))"')

    if [[ ${#group_clients[@]} -eq 0 ]]; then
        warn "В группе $group нет клиентов — пропускаю."
        return
    fi

    info "Группа $group ($tpl_name)..."

    # Фаза 1: собираем уникальные ноды и имена клиентов
    local all_nodes_csv="$group_nodes_csv"
    local client_names=()
    for client_line in "${group_clients[@]}"; do
        local cname="${client_line%%|*}"
        client_names+=("$cname")
        local rest="${client_line#*|}"
        rest="${rest#*|}"
        local client_inherit="${rest%%|*}"
        local client_own_nodes="${rest#*|}"
        if [[ "$client_inherit" != "true" && -n "$client_own_nodes" ]]; then
            all_nodes_csv="${all_nodes_csv},${client_own_nodes}"
        fi
    done

    # Дедупликация нод
    local unique_nodes=()
    local -a _all
    local _n
    IFS=',' read -ra _all <<< "$all_nodes_csv"
    for _n in "${_all[@]}"; do
        [[ -z "$_n" ]] && continue
        if ! array_contains "$_n" "${unique_nodes[@]}"; then
            unique_nodes+=("$_n")
        fi
    done

    # Фаза 2: батч AWG peers (до загрузки конфигов)
    _ensure_all_awg_peers "${#client_names[@]}" "${client_names[@]}" "${unique_nodes[@]}"

    # Обрабатываем шаблон
    local processed
    processed=$(process_template "$template" "$group")

    # Фаза 4: генерация клиентов (0 SSH)
    for client_line in "${group_clients[@]}"; do
        local client_name="${client_line%%|*}"
        local rest="${client_line#*|}"
        local client_group="${rest%%|*}"
        rest="${rest#*|}"
        local client_inherit="${rest%%|*}"
        local client_own_nodes="${rest#*|}"

        local client_nodes
        if [[ "$client_inherit" == "true" ]]; then
            client_nodes="$group_nodes_csv"
        else
            client_nodes="$client_own_nodes"
        fi

        local client_dir="$GENERATED_DIR/$group/$client_name"
        if ! mkdir -p "$client_dir"; then
            warn "$client_name — config.yaml не сгенерирован"
            continue
        fi

        # Получаем прокси из кеша
        local proxy_entries=""
        if [[ -n "$client_nodes" ]]; then
            proxy_entries=$(_fetch_proxies_for_client "$client_name" "$client_group" "$client_nodes")
        fi

        # Проверяем уникальность имён прокси
        if [[ -n "$proxy_entries" ]]; then
            local dup_names
            dup_names=$(printf '%s\n' "$proxy_entries" | sed -n 's/^  - name: "\([^"]*\)"$/\1/p' | sort | uniq -d)
            if [[ -n "$dup_names" ]]; then
                warn "$client_name: повторяющиеся имена прокси:" >&2
                while IFS= read -r dn; do
                    warn "  '$dn' — задайте алиас через P → Переименовать" >&2
                done <<< "$dup_names"
                warn "$client_name — пропущен (повторяющиеся имена прокси)" >&2
                continue
            fi
        fi

        local config=""
        if ! config=$(_render_client_config "$processed" "$proxy_entries"); then
            warn "$client_name — config.yaml не сгенерирован"
            continue
        fi

        # Убираем дублирующиеся пустые строки (артефакты удалённых блоков)
        local config_tmp=""
        if ! config_tmp=$(umask 077; mktemp "$client_dir/.config.yaml.XXXXXX"); then
            warn "$client_name — config.yaml не сгенерирован"
            continue
        fi
        if ! cat -s > "$config_tmp" <<< "$config"; then
            rm -f "$config_tmp"
            warn "$client_name — config.yaml не сгенерирован"
            continue
        fi
        if ! grep -q '[^[:space:]]' "$config_tmp"; then
            rm -f "$config_tmp"
            warn "$client_name — config.yaml не сгенерирован"
            continue
        fi
        if ! mv "$config_tmp" "$client_dir/config.yaml"; then
            rm -f "$config_tmp"
            warn "$client_name — config.yaml не сгенерирован"
            continue
        fi

        success "$client_name — сгенерирован"
    done
}

_fetch_proxies_for_client() {
    local client_name="$1"
    local client_group="$2"
    local nodes_csv="$3"

    local all_proxies=""
    local -a node_names _cc allowed
    local nname _p conn_name

    # Per-client credentials для подстановки в proxy-блоки
    local _client_vless_uuid _client_hy2_pass
    _client_vless_uuid=$(jq_r --arg c "$client_name" '.clients[] | select(.name==$c) | .credentials.vless_uuid // ""')
    _client_hy2_pass=$(jq_r --arg c "$client_name" '.clients[] | select(.name==$c) | .credentials.hy2_password // ""')

    IFS=',' read -ra node_names <<< "$nodes_csv"
    for nname in "${node_names[@]}"; do
        # Подключения: клиентские > групповые
        local allowed_connections=""
        local client_conns
        client_conns=$(jq_r --arg c "$client_name" --arg n "$nname" \
            '.clients[] | select(.name==$c) | .connections // [] | .[] | select(.node==$n) | .proxies | join(",")')

        local group_conns
        group_conns=$(jq_r --arg n "$nname" --arg g "$client_group" \
            '.connections[] | select(.node==$n) | .groups[] | select(.name==$g) | .proxies | join(",")')

        if [[ -n "$client_conns" ]]; then
            allowed_connections="$client_conns"
            if [[ -n "$group_conns" ]]; then
                IFS=',' read -ra _cc <<< "$client_conns"
                for _p in "${_cc[@]}"; do
                    if ! echo ",$group_conns," | grep -qF ",$_p,"; then
                        warn "$client_name: подключение '$_p' на $nname отсутствует в группе $client_group" >&2
                    fi
                done
            fi
        else
            allowed_connections="$group_conns"
        fi

        # Конфиг из кеша
        local remote_config
        remote_config=$(_get_node_config "$nname") || continue

        # Парсим proxy блоки
        local proxy_block
        proxy_block=$(echo "$remote_config" | sed -n '/^proxies:/,/^---/p' | grep -v '^---' | grep -v '^proxies:' \
            | sed 's/^  - name: \([^"]\)\(.*\)/  - name: "\1\2"/')

        if [[ -n "$proxy_block" && -n "$allowed_connections" ]]; then
            local filtered=""
            IFS=',' read -ra allowed <<< "$allowed_connections"
            for conn_name in "${allowed[@]}"; do
                # AWG: generic connection → client-specific proxy
                local match_name="$conn_name"
                [[ "$conn_name" == "AWG" ]] && match_name="awg-${client_name}"

                local block
                block=$(echo "$proxy_block" | awk -v name="$match_name" '
                    /^  - name:/ {
                        if (found) print buf
                        buf = $0
                        n = $0
                        sub(/^  - name: *"?/, "", n)
                        sub(/"? *$/, "", n)
                        found = (n == name)
                        next
                    }
                    { if (buf != "") buf = buf "\n" $0 }
                    END { if (found) print buf }
                ')
                # Per-client credentials: подставляем uuid/password клиента
                if [[ -n "$block" ]]; then
                    local _proxy_type
                    _proxy_type=$(echo "$block" | grep '    type:' | awk '{print $2}' | head -1)
                    case "$_proxy_type" in
                        vless)
                            [[ -n "$_client_vless_uuid" ]] && \
                                block=$(echo "$block" | sed "s/    uuid: .*/    uuid: $_client_vless_uuid/")
                            if declare -F _normalize_vless_xhttp_proxy_yaml >/dev/null; then
                                block=$(printf '%s\n' "$block" | _normalize_vless_xhttp_proxy_yaml)
                            fi
                            ;;
                        hysteria2)
                            [[ -n "$_client_hy2_pass" ]] && \
                                block=$(echo "$block" | sed "s/    password: .*/    password: $_client_hy2_pass/")
                            ;;
                    esac
                fi
                # AWG: переименовать proxy → "node AmneziaWG 2.0"
                if [[ -n "$block" && "$conn_name" == "AWG" ]]; then
                    local awg_display="AmneziaWG 2.0"
                    block="  - name: \"${awg_display}\""$'\n'"$(echo "$block" | tail -n +2)"
                fi
                [[ -n "$block" ]] && filtered="${filtered}${block}"$'\n'
            done
            proxy_block="$filtered"
        fi

        # Aliases
        if [[ -n "$proxy_block" ]]; then
            local aliases_json
            aliases_json=$(jq_r --arg n "$nname" '.nodes[] | select(.name==$n) | .aliases // {}')
            if [[ -n "$aliases_json" && "$aliases_json" != "{}" && "$aliases_json" != "null" ]]; then
                local orig repl
                while IFS=$'\t' read -r orig repl; do
                    local search="  - name: \"$orig\""
                    local replace="  - name: \"$repl\""
                    proxy_block="${proxy_block//"$search"/"$replace"}"
                done < <(echo "$aliases_json" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')
            fi

            # Tag prefix
            local tag
            tag=$(jq_r --arg n "$nname" '.nodes[] | select(.name==$n) | .tag // ""')
            if [[ -n "$tag" ]]; then
                proxy_block="${proxy_block//  - name: \"/  - name: \"${tag} }"
            fi

            all_proxies="${all_proxies}${proxy_block}"$'\n'
        fi
    done

    [[ -n "$all_proxies" ]] && echo "$all_proxies" | awk '/^  - name:/ && NR>1 {print ""} 1'
}

# ─── Синхронизация users в listener'ах на нодах ──────────────────────────────

# Собирает per-client users для указанной ноды и синхронизирует listener'ы
# Args: nname — имя ноды
_sync_node_listeners() {
    local nname="$1"

    if ! node_load_by_name "$nname"; then
        return 1
    fi

    # Собираем всех клиентов, привязанных к этой ноде (через группы и кастомные ноды)
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

    [[ -z "$users_data" ]] && return 0

    # Определяем какие listener'ы есть на ноде (из кешированного конфига)
    local remote_config
    remote_config=$(_get_node_config "$nname") || return 1

    # Формируем YAML-блоки для каждого типа listener'а
    local vless_tcp_users="" vless_xhttp_users="" vless_grpc_users="" hy2_users=""
    local has_vless_tcp=false has_vless_xhttp=false has_vless_grpc=false has_hy2=false

    echo "$remote_config" | grep -q '^--- VLESS TCP ---' && has_vless_tcp=true
    echo "$remote_config" | grep -q '^--- VLESS xHTTP ---' && has_vless_xhttp=true
    echo "$remote_config" | grep -q '^--- VLESS gRPC ---' && has_vless_grpc=true
    echo "$remote_config" | grep -q '^--- Hysteria2 ---' && has_hy2=true

    while IFS=' ' read -r _cname _cuuid _cpass; do
        [[ -z "$_cname" ]] && continue
        if $has_vless_tcp && [[ -n "$_cuuid" ]]; then
            vless_tcp_users+="      - username: ${_cname}"$'\n'
            vless_tcp_users+="        uuid: ${_cuuid}"$'\n'
            vless_tcp_users+="        flow: xtls-rprx-vision"$'\n'
        fi
        if $has_vless_xhttp && [[ -n "$_cuuid" ]]; then
            vless_xhttp_users+="      - username: ${_cname}"$'\n'
            vless_xhttp_users+="        uuid: ${_cuuid}"$'\n'
        fi
        if $has_vless_grpc && [[ -n "$_cuuid" ]]; then
            vless_grpc_users+="      - username: ${_cname}"$'\n'
            vless_grpc_users+="        uuid: ${_cuuid}"$'\n'
        fi
        if $has_hy2 && [[ -n "$_cpass" ]]; then
            hy2_users+="      ${_cname}: ${_cpass}"$'\n'
        fi
    done <<< "$users_data"

    # Убираем trailing newline
    vless_tcp_users="${vless_tcp_users%$'\n'}"
    vless_xhttp_users="${vless_xhttp_users%$'\n'}"
    vless_grpc_users="${vless_grpc_users%$'\n'}"
    hy2_users="${hy2_users%$'\n'}"

    # Загружаем скрипты если ещё не загружены
    if ! array_contains "$nname" "${SCRIPTS_UPLOADED[@]}"; then
        upload_scripts
        SCRIPTS_UPLOADED+=("$nname")
    fi

    # Формируем SSH-команду: sync каждого listener'а + restart
    local sync_cmd="source ${REMOTE_DIR}/common/listener-users.sh"
    local has_changes=false

    if $has_vless_tcp && [[ -n "$vless_tcp_users" ]]; then
        sync_cmd+=" && _sync_listener_users 'vless-tcp' $(printf '%q' "$vless_tcp_users")"
        has_changes=true
    fi
    if $has_vless_xhttp && [[ -n "$vless_xhttp_users" ]]; then
        sync_cmd+=" && _sync_listener_users 'vless-xhttp' $(printf '%q' "$vless_xhttp_users")"
        has_changes=true
    fi
    if $has_vless_grpc && [[ -n "$vless_grpc_users" ]]; then
        sync_cmd+=" && _sync_listener_users 'vless-grpc' $(printf '%q' "$vless_grpc_users")"
        has_changes=true
    fi
    if $has_hy2 && [[ -n "$hy2_users" ]]; then
        sync_cmd+=" && _sync_listener_users 'hy2' $(printf '%q' "$hy2_users")"
        has_changes=true
    fi

    if ! $has_changes; then
        return 0
    fi

    # Restart mihomo после sync
    sync_cmd+=" && systemctl restart mihomo"

    if ssh_run -- "$sync_cmd" 2>/dev/null; then
        success "$nname — listeners обновлены"
    else
        warn "$nname — не удалось обновить listeners"
    fi
}

# Синхронизирует listeners на всех указанных нодах
_sync_listeners_on_nodes() {
    local nodes=("$@")

    echo ""
    info "Синхронизация users на нодах..."

    for nname in "${nodes[@]}"; do
        array_contains "$nname" "${NODE_CONFIG_FAILED[@]}" && continue
        _sync_node_listeners "$nname"
    done
}
