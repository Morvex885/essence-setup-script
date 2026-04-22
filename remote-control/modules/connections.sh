#!/bin/bash
# ─── Подключения нод (per-group) ────────────────────────────────────────────

# Кеш кол-ва обнаруженных подключений per нода. Заполняется _sync_all_connections.
declare -A NODE_DISC_COUNT

connections_menu() {
    local _conn_synced=0
    while true; do
        local node_count
        node_count=$(nodes_count)

        if [[ "$node_count" -gt 0 && "$_conn_synced" -eq 0 ]]; then
            _sync_all_connections
            _conn_synced=1
        fi

        echo ""
        box_top
        box_center "Подключения нод для групп"
        box_bot

        if [[ "$node_count" -eq 0 ]]; then
            echo ""
            echo -e "  ${DIM}Нет нод${NC}"
        else
            # Обзор: нода × группа → кол-во подключений
            _show_connections_overview
            echo ""
            local i=1
            while IFS=$'\t' read -r nname nip; do
                echo -e "  ${GREEN}${i})${NC} $nname ${DIM}$nip${NC}"
                i=$((i + 1))
            done < <(jq_r '.nodes[] | "\(.name)\t\(.ip)"')
        fi
        echo ""
        if [[ "$node_count" -gt 0 ]]; then
            echo -e "  ${YELLOW}r)${NC} Переименовать подключения"
            echo -e "  ${CYAN}s)${NC} Синхронизировать с нодами"
        fi
        echo -e "  ${NC}0)${NC} Назад"
        echo ""
        read -rp "  Выберите ноду: " CONN_CHOICE

        if [[ "$CONN_CHOICE" == "0" ]]; then
            return
        elif [[ "$CONN_CHOICE" == "r" || "$CONN_CHOICE" == "R" ]]; then
            _rename_connections
        elif [[ "$CONN_CHOICE" == "s" || "$CONN_CHOICE" == "S" ]]; then
            _sync_all_connections
        elif [[ "$CONN_CHOICE" =~ ^[0-9]+$ ]] && (( CONN_CHOICE >= 1 && CONN_CHOICE <= node_count )); then
            _configure_node_connections "$CONN_CHOICE"
        else
            warn "Неверный выбор."
        fi
    done
}

# Очищает .connections для ноды от proxy, которых нет в обнаруженном списке.
# Удаляет пустые группы и пустые ноды.
# Args: $1 — имя ноды; $2 — имя массива bash с обнаруженными подключениями.
_purge_stale_connections() {
    local nname="$1"
    local -n _disc_arr=$2
    local disc_json
    disc_json=$(printf '%s\n' "${_disc_arr[@]}" | jq -R . | jq -s .)
    jq_w --arg n "$nname" --argjson valid "$disc_json" '
        .connections |= map(
            if .node==$n then
                .groups |= map(.proxies |= [.[] | select(. as $p | $valid | index($p))])
                | .groups |= [.[] | select(.proxies | length > 0)]
            else . end)
        | .connections |= [.[] | select(.groups | length > 0)]'
}

# Прогоняет sync для всех нод: SSH discover + purge stale.
# Offline-ноды — warn и пропуск (stale-данные сохраняются).
_sync_all_connections() {
    local nodes=()
    mapfile -t nodes < <(jq_r '.nodes[].name')
    [[ ${#nodes[@]} -eq 0 ]] && return

    info "Синхронизирую подключения с нодами..."
    local ok=0 fail=0
    local _save_node="$NODE_NAME" _save_ip="$SERVER_IP" _save_port="$SERVER_PORT"
    local _save_user="$SERVER_USER" _save_pass="$SERVER_PASS" _save_auth="$SERVER_AUTH"

    NODE_DISC_COUNT=()

    for nname in "${nodes[@]}"; do
        if ! node_load_by_name "$nname"; then
            warn "$nname: не найдена, пропуск"
            fail=$((fail + 1))
            continue
        fi

        local discovered
        discovered=$(_discover_connections)
        if [[ -z "$discovered" ]]; then
            warn "$nname: offline или пусто, пропуск"
            fail=$((fail + 1))
            continue
        fi

        local disc_arr=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && disc_arr+=("$line")
        done <<< "$discovered"

        NODE_DISC_COUNT[$nname]=${#disc_arr[@]}
        _purge_stale_connections "$nname" disc_arr
        ok=$((ok + 1))
    done

    NODE_NAME="$_save_node" SERVER_IP="$_save_ip" SERVER_PORT="$_save_port"
    SERVER_USER="$_save_user" SERVER_PASS="$_save_pass" SERVER_AUTH="$_save_auth"

    success "Синхронизировано: $ok/${#nodes[@]} нод"
    [[ $fail -gt 0 ]] && warn "Не доступно: $fail"
}

_show_connections_overview() {
    groups_list
    [[ ${#GRP_LIST[@]} -eq 0 ]] && return

    echo ""
    while IFS=$'\t' read -r nname _nip; do
        local line="  ${nname}"
        # Паддинг до 12 символов
        local pad=$((12 - ${#nname}))
        (( pad > 0 )) && line+=$(printf '%*s' "$pad" "")

        local total="${NODE_DISC_COUNT[$nname]:-?}"
        for g in "${GRP_LIST[@]}"; do
            local cnt
            cnt=$(jq_r --arg n "$nname" --arg g "$g" \
                '.connections[] | select(.node==$n) | .groups[] | select(.name==$g) | .proxies | length')
            cnt="${cnt:-0}"
            local color
            if [[ "$total" == "?" ]]; then
                color="$DIM"
            elif [[ "$cnt" -eq 0 ]]; then
                color="$DIM"
            elif [[ "$cnt" -ge "$total" ]]; then
                color="$GREEN"
            else
                color="$YELLOW"
            fi
            line+=" ${g}: ${color}${cnt}/${total}${NC} "
        done
        echo -e "$line"
    done < <(jq_r '.nodes[] | "\(.name)\t\(.ip)"')
}

_configure_node_connections() {
    node_load "$1"
    local nname="$NODE_NAME"

    # Один SSH — discover
    info "Подключаюсь к $nname..."
    local discovered
    discovered=$(_discover_connections)
    if [[ -z "$discovered" ]]; then
        warn "Не удалось обнаружить подключения на $nname."
        warn "Перейдите в ноду и настройте VLESS, Hysteria2 или AmneziaWG."
        return
    fi

    local disc_arr=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && disc_arr+=("$line")
    done <<< "$discovered"

    success "Обнаружено ${#disc_arr[@]} подключений"

    NODE_DISC_COUNT[$nname]=${#disc_arr[@]}
    _purge_stale_connections "$nname" disc_arr

    groups_list
    while true; do
        echo ""
        echo -e "  ${CYAN}$nname${NC} — подключения:"
        echo ""
        for d in "${disc_arr[@]}"; do
            local grp_tags=""
            for g in "${GRP_LIST[@]}"; do
                local proxies_csv
                proxies_csv=$(jq_r --arg n "$nname" --arg g "$g" \
                    '.connections[] | select(.node==$n) | .groups[] | select(.name==$g) | .proxies | join(",")')
                if [[ -n "$proxies_csv" ]] && echo ",$proxies_csv," | grep -qF ",$d,"; then
                    grp_tags+=" ${GREEN}${g}${NC}"
                fi
            done
            if [[ -n "$grp_tags" ]]; then
                echo -e "  $d —${grp_tags}"
            else
                echo -e "  $d  ${DIM}(не назначено)${NC}"
            fi
        done
        echo ""
        echo -e "  ${CYAN}b)${NC} Назначить подключения группам"
        echo -e "  ${NC}0)${NC} Назад"
        echo ""
        read -rp "  Выберите действие: " _pick

        if [[ "$_pick" == "0" ]]; then
            return
        elif [[ "$_pick" == "b" || "$_pick" == "B" ]]; then
            _batch_assign_connections "$nname" disc_arr
        else
            warn "Неверный выбор."
        fi
    done
}



_batch_assign_connections() {
    local nname="$1"
    local -n _batch_disc=$2

    # Шаг 1: выбрать подключения
    local flags=()
    for d in "${_batch_disc[@]}"; do
        flags+=(0)
    done

    toggle_select "${CYAN}$nname${NC} — подключения" _batch_disc flags

    local selected_csv=""
    local i=0
    for d in "${_batch_disc[@]}"; do
        if [[ "${flags[$i]}" == "1" ]]; then
            [[ -n "$selected_csv" ]] && selected_csv+=","
            selected_csv+="$d"
        fi
        i=$((i + 1))
    done

    if [[ -z "$selected_csv" ]]; then
        warn "Ничего не выбрано."
        return
    fi

    # Шаг 2: выбрать группы
    local grp_flags=()
    for g in "${GRP_LIST[@]}"; do
        grp_flags+=(0)
    done

    toggle_select "${CYAN}$nname${NC} — группы" GRP_LIST grp_flags

    local applied=0
    i=0
    for g in "${GRP_LIST[@]}"; do
        if [[ "${grp_flags[$i]}" == "1" ]]; then
            _save_connection "$nname" "$g" "$selected_csv"
            success "$nname -> $g сохранено"
            applied=$((applied + 1))
        fi
        i=$((i + 1))
    done
    [[ $applied -eq 0 ]] && warn "Ни одна группа не выбрана."
}

_save_connection() {
    local nname="$1" group="$2" csv="$3"

    if [[ -z "$csv" ]]; then
        jq_w --arg n "$nname" --arg g "$group" '
            .connections |= map(if .node==$n then .groups |= [.[] | select(.name!=$g)] else . end)
            | .connections |= [.[] | select(.groups | length > 0)]'
        return
    fi

    local proxies_json
    proxies_json=$(echo "$csv" | tr ',' '\n' | jq -R . | jq -s .)

    jq_w --arg n "$nname" --arg g "$group" --argjson p "$proxies_json" '
        if any(.connections[]; .node==$n) then
            .connections |= map(if .node==$n then .groups = ([.groups[] | select(.name!=$g)] + [{name:$g, proxies:$p}]) else . end)
        else
            .connections += [{node:$n, groups:[{name:$g, proxies:$p}]}]
        end'
}

_rename_connections() {
    local node_count
    node_count=$(nodes_count)
    if [[ "$node_count" -eq 0 ]]; then
        warn "Нет нод."
        return
    fi

    echo ""
    echo -e "  Выберите ноду:"
    local i=1
    while IFS=$'\t' read -r nname nip; do
        echo -e "  ${GREEN}${i})${NC} $nname ${DIM}$nip${NC}"
        i=$((i + 1))
    done < <(jq_r '.nodes[] | "\(.name)\t\(.ip)"')
    echo -e "  ${NC}0)${NC} Назад"
    echo ""
    read -rp "Выберите: " NODE_IDX

    [[ "$NODE_IDX" == "0" ]] && return
    if ! [[ "$NODE_IDX" =~ ^[0-9]+$ ]] || (( NODE_IDX < 1 || NODE_IDX > node_count )); then
        warn "Неверный выбор."
        return
    fi

    node_load "$NODE_IDX"
    local nname="$NODE_NAME"

    info "Подключаюсь к $nname..."
    local discovered
    discovered=$(_discover_connections)
    if [[ -z "$discovered" ]]; then
        warn "Не удалось обнаружить подключения на $nname."
        warn "Перейдите в ноду и настройте VLESS, Hysteria2 или AmneziaWG."
        return
    fi

    local disc_arr=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && disc_arr+=("$line")
    done <<< "$discovered"

    # Текущие aliases ноды
    local aliases_json
    aliases_json=$(jq_r --arg n "$nname" '.nodes[] | select(.name==$n) | .aliases // {}')

    while true; do
        echo ""
        echo -e "  Подключения ${CYAN}$nname${NC}:"
        local i=1
        for d in "${disc_arr[@]}"; do
            local alias_val
            alias_val=$(echo "$aliases_json" | jq -r --arg k "$d" '.[$k] // empty')
            if [[ -n "$alias_val" ]]; then
                echo -e "  ${GREEN}${i})${NC} $d  ${YELLOW}→  $alias_val${NC}"
            else
                echo -e "  ${GREEN}${i})${NC} $d"
            fi
            i=$((i + 1))
        done
        echo ""
        read -rp "Номер для переименования (Enter = сохранить): " PICK
        [[ -z "$PICK" ]] && break

        if [[ "$PICK" =~ ^[0-9]+$ ]] && (( PICK >= 1 && PICK <= ${#disc_arr[@]} )); then
            local orig="${disc_arr[$((PICK - 1))]}"
            local cur_alias
            cur_alias=$(echo "$aliases_json" | jq -r --arg k "$orig" '.[$k] // empty')
            [[ -n "$cur_alias" ]] && echo -e "  Текущее: ${YELLOW}$cur_alias${NC}"
            read -rp "  Новое имя (Enter = убрать alias): " NEW_NAME

            if [[ -n "$NEW_NAME" ]]; then
                aliases_json=$(echo "$aliases_json" | jq --arg k "$orig" --arg v "$NEW_NAME" '. + {($k): $v}')
            else
                aliases_json=$(echo "$aliases_json" | jq --arg k "$orig" 'del(.[$k])')
            fi
        else
            warn "Неверный номер."
        fi
    done

    # Сохраняем aliases в ноду
    jq_w --arg n "$nname" --argjson a "$aliases_json" \
        '(.nodes[] | select(.name==$n)).aliases = $a'
    success "Aliases для $nname сохранены"
}

# ─── Вспомогательные функции ─────────────────────────────────────────────────

_extract_names_by_keyword() {
    local config="$1" keyword="$2"
    local names
    # Try PCRE first (extracts only quoted names)
    names=$(echo "$config" | grep -oP '(?<=name: ")[^"]+' 2>/dev/null | grep -i "$keyword")
    if [[ -z "$names" ]]; then
        # Fallback: try quoted names without PCRE
        names=$(echo "$config" | grep -i "name:.*\".*${keyword}" | sed 's/.*name: *"//;s/".*//' | sed 's/^ *//')
    fi
    if [[ -z "$names" ]]; then
        # Last resort: unquoted names
        names=$(echo "$config" | grep -i "name:.*${keyword}" | sed 's/.*name: *//;s/"//g' | sed 's/^ *//')
    fi
    echo "$names"
}

_append_lines() {
    local -n _result=$1
    local lines="$2" prefix="${3:-}"
    while IFS= read -r n; do
        [[ -n "$n" ]] && _result="${_result}${prefix}${n}"$'\n'
    done <<< "$lines"
}

_discover_connections() {
    local result=""

    local remote_config
    remote_config=$(ssh_run -- "cat /etc/mihomo/client-config.txt 2>/dev/null") || return

    _append_lines result "$(_extract_names_by_keyword "$remote_config" "vless")"
    _append_lines result "$(_extract_names_by_keyword "$remote_config" "hy2\|hysteria")"

    local cascade_names
    cascade_names=$(echo "$remote_config" | grep -i 'name:.*cascade' | sed 's/.*name: *//;s/"//g' | sed 's/^ *//')
    _append_lines result "$cascade_names"

    # AWG: обнаруживаем по секции в client-config.txt (без лишнего SSH)
    if echo "$remote_config" | grep -q '^--- AmneziaWG ---'; then
        result+="AWG"$'\n'
    fi

    echo "$result" | grep -v '^$' | sort -u
}
