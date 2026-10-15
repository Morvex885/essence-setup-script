#!/bin/bash
# ─── AWG Peers: обзор, создание, удаление, очистка ─────────────────────────

# Получить список клиентов, которым нужен AWG peer на ноде
_awg_expected_peers() {
    local nname="$1"
    # Клиенты, у которых в connections (групповых или своих) есть awg-* для этой ноды
    local peers=()

    # Групповые: ноды группы содержат nname + connections содержат awg-*
    while IFS='|' read -r cname cgroup cinherit cnodes; do
        local client_nodes="$cnodes"
        if [[ "$cinherit" == "true" ]]; then
            client_nodes=$(_group_nodes_csv "$cgroup")
        fi
        # Нода в списке клиента?
        echo ",$client_nodes," | grep -qF ",$nname," || continue
        # Есть awg-* подключение для этой ноды?
        local has_awg=false
        # Проверяем клиентские подключения
        local client_awg
        client_awg=$(jq_r --arg c "$cname" --arg n "$nname" \
            '.clients[] | select(.name==$c) | .connections // [] | .[] | select(.node==$n) | .proxies[] | select(. == "AWG" or startswith("awg-"))')
        if [[ -n "$client_awg" ]]; then
            has_awg=true
        else
            # Проверяем групповые подключения
            local group_awg
            group_awg=$(jq_r --arg n "$nname" --arg g "$cgroup" \
                '.connections[] | select(.node==$n) | .groups[] | select(.name==$g) | .proxies[] | select(. == "AWG" or startswith("awg-"))')
            [[ -n "$group_awg" ]] && has_awg=true
        fi
        $has_awg && peers+=("$cname")
    done < <(jq_r '.clients[] | "\(.name)|\(.group)|\(if .inherit_nodes_from_group == false then false else true end)|\(.nodes // [] | join(","))"')

    printf '%s\n' "${peers[@]}" | sort -u
}

awg_peers_menu() {
    while true; do
        local node_count
        node_count=$(nodes_count)
        echo ""
        box_top
        box_center "Клиенты AmneziaWG"
        box_mid
        if [[ "$node_count" -eq 0 ]]; then
            box_line " Нет нод" " ${DIM}Нет нод${NC}"
            box_mid
            menu_item 0 "Назад" NC
            box_bot
            return 0
        fi

        local i=1 idx nname nip has_awg_conn
        local -a _node_names=() _node_ips=()
        while IFS=$'\t' read -r nname nip; do
            _node_names+=("$nname")
            _node_ips+=("$nip")
        done < <(jq_r '.nodes[] | "\(.name)\t\(.ip)"')
        for (( idx=0; idx<${#_node_names[@]}; idx++ )); do
            nname="${_node_names[$idx]}"
            nip="${_node_ips[$idx]}"
            has_awg_conn=$(jq_r --arg n "$nname" '[.connections[] | select(.node==$n) | .groups[].proxies[] | select(. == "AWG" or startswith("awg-"))] | length')
            if [[ "$has_awg_conn" -gt 0 ]]; then
                menu_item "$((idx+1))" "$nname  $nip" CYAN
            else
                menu_item "$((idx+1))" "$nname  $nip — нет подключений AmneziaWG" CYAN
            fi
            i=$((i + 1))
        done
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите ноду: " _pick; then
            return 0
        fi
        _pick="${_pick%$'\r'}"
        [[ "$_pick" == 0 ]] && return 0
        if menu_index_valid "$_pick" "${#_node_names[@]}"; then
            _awg_peers_node "$_pick"
        else
            warn "Неверный выбор."
        fi
    done
}

_awg_peers_refresh() {
    AWG_PEERS_REFRESH_RESULT=""
    local result peer
    result=$(ssh_run -- "ls /etc/mihomo/amnezia/ 2>/dev/null") || return 1
    while IFS= read -r peer; do
        peer="${peer%$'\r'}"
        [[ -n "$peer" ]] || continue
        AWG_PEERS_REFRESH_RESULT="${AWG_PEERS_REFRESH_RESULT}${peer}"$'\n'
    done <<< "$result"
    AWG_PEERS_REFRESH_RESULT="${AWG_PEERS_REFRESH_RESULT%$'\n'}"
    return 0
}

_awg_peers_mutate() {
    ensure_remote_scripts_current || {
        warn "Не удалось подготовить скрипты для ноды '$NODE_NAME'."
        return 1
    }
    ssh_run -- "$1"
}

_awg_peers_node() {
    node_load "$1" || return 1
    local nname="$NODE_NAME" check_result existing_peers="" expected_peers stale=false
    ssh_connect || return 1
    check_result=$(ssh_run -- "if [ ! -f /etc/amnezia/amneziawg/awg0.conf ]; then echo NO_AWG; else echo AWG_OK; ls /etc/mihomo/amnezia/; fi") || {
        warn "Не удалось получить статус AmneziaWG на $nname."
        return 1
    }
    check_result="${check_result//$'\r'/}"
    [[ "$check_result" == NO_AWG ]] && { warn "AmneziaWG не установлен на $nname."; return 0; }
    [[ "$check_result" == AWG_OK || "$check_result" == AWG_OK$'\n'* ]] || return 1
    [[ "$check_result" == *$'\n'* ]] && existing_peers="${check_result#*$'\n'}"
    expected_peers=$(_awg_expected_peers "$nname")
    while true; do
        local all_peers=() peer_status=() missing_peers=() orphans=()
        local idx p s choice cmd target target_status labels=()
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            all_peers+=("$p")
            if printf '%s\n' "$expected_peers" | grep -qxF "$p"; then
                peer_status+=("used")
            else
                peer_status+=("orphan")
                orphans+=("$p")
            fi
        done <<< "$existing_peers"
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            if ! printf '%s\n' "$existing_peers" | grep -qxF "$p"; then
                missing_peers+=("$p"); all_peers+=("$p"); peer_status+=("missing")
            fi
        done <<< "$expected_peers"
        echo ""
        box_top
        box_center "Клиенты AmneziaWG: $nname"
        box_mid
        if [[ "$stale" == true ]]; then
            box_line " Список не обновлён; изменения временно недоступны." \
                " ${YELLOW}Список не обновлён; изменения временно недоступны.${NC}"
        fi
        if [[ ${#all_peers[@]} -eq 0 ]]; then
            box_line " Нет клиентов AmneziaWG" " ${DIM}Нет клиентов AmneziaWG${NC}"
        else
            for ((idx=0; idx<${#all_peers[@]}; idx++)); do
                p="${all_peers[$idx]}"; s="${peer_status[$idx]}"
                case "$s" in
                    used) box_line " [✓] $p" " [${GREEN}✓${NC}] $p" ;;
                    orphan) box_line " [!] $p — не привязан" " [${YELLOW}!${NC}] $p ${YELLOW}— не привязан${NC}" ;;
                    missing) box_line " [-] $p — не создан" " [${DIM}-${NC}] $p ${DIM}— не создан${NC}" ;;
                esac
            done
        fi
        box_mid
        menu_item r "Обновить список" CYAN
        [[ ${#missing_peers[@]} -gt 0 ]] && menu_item c "Создать недостающих клиентов (${#missing_peers[@]})" GREEN
        menu_item d "Удалить клиента" RED
        [[ ${#orphans[@]} -gt 0 ]] && menu_item x "Удалить неиспользуемых (${#orphans[@]})" RED
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        IFS= read -rp "  Выберите действие: " choice || return 0
        choice="${choice%$'\r'}"
        if [[ "$stale" == true ]]; then
            case "$choice" in
                c|C|d|D|x|X) warn "Сначала обновите список клиентов AmneziaWG."; continue ;;
            esac
        fi
        case "$choice" in
            c|C)
                [[ ${#missing_peers[@]} -gt 0 ]] || { warn "Неверный выбор."; continue; }
                cmd="source $(printf '%q' "$REMOTE_DIR/modules/amneziawg.sh")"
                for p in "${missing_peers[@]}"; do
                    cmd="$cmd && add_awg_peer_auto $(printf '%q' "$p")"
                done
                state_action "awg_peers" _awg_peers_mutate "$cmd" || warn "Не удалось создать клиентов AmneziaWG."
                ;;
            d|D)
                labels=("${all_peers[@]}")
                menu_select "Удаление клиента AmneziaWG: $nname" "Выберите клиента" "${labels[@]}" || continue
                target="${all_peers[$((MENU_SELECT_INDEX-1))]}"
                target_status="${peer_status[$((MENU_SELECT_INDEX-1))]}"
                [[ "$target_status" != missing ]] || { warn "Клиент $target ещё не создан на ноде."; continue; }
                review_frame "Удаление клиента AmneziaWG" "Нода: $nname  $SERVER_IP:$SERVER_PORT" "Клиент: $target" "Конфигурация и ключи клиента будут удалены; доступ перестанет работать."
                confirm_yn "Удалить клиента AmneziaWG?" N || continue
                cmd="source $(printf '%q' "$REMOTE_DIR/modules/amneziawg.sh") && remove_awg_peer_by_name $(printf '%q' "$target")"
                state_action "awg_peers" _awg_peers_mutate "$cmd" || warn "Не удалось удалить клиента AmneziaWG."
                ;;
            x|X)
                [[ ${#orphans[@]} -gt 0 ]] || { warn "Неверный выбор."; continue; }
                review_frame "Удаление неиспользуемых клиентов AmneziaWG" "Нода: $nname  $SERVER_IP:$SERVER_PORT" \
                    "Клиенты: ${orphans[*]}" "Конфигурации и ключи клиентов будут удалены; доступ перестанет работать."
                confirm_yn "Удалить перечисленных клиентов AmneziaWG?" N || continue
                cmd="source $(printf '%q' "$REMOTE_DIR/modules/amneziawg.sh")"
                for p in "${orphans[@]}"; do
                    cmd="$cmd && remove_awg_peer_by_name $(printf '%q' "$p")"
                done
                state_action "awg_peers" _awg_peers_mutate "$cmd" || warn "Не удалось удалить всех клиентов AmneziaWG."
                ;;
            r|R) ;;
            0) return 0 ;;
            *) warn "Неверный выбор."; continue ;;
        esac
        if _awg_peers_refresh; then
            existing_peers="$AWG_PEERS_REFRESH_RESULT"
            stale=false
        else
            stale=true
            warn "Не удалось обновить список клиентов AmneziaWG. Показаны последние полученные данные."
        fi
    done
}
