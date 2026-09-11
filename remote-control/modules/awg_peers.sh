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
        box_center "AWG-подключения"
        box_mid
        if [[ "$node_count" -eq 0 ]]; then
            box_line " Нет нод" " ${DIM}Нет нод${NC}"
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
                box_line " $((idx+1))) $nname $nip" " ${CYAN}$((idx+1)))${NC} $nname ${DIM}$nip${NC}"
            else
                box_line " $((idx+1))) $nname $nip — нет AWG подключений" \
                    " ${CYAN}$((idx+1)))${NC} $nname ${DIM}$nip — нет AWG подключений${NC}"
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
            state_action "awg_peers" _awg_peers_node "$_pick"
        else
            warn "Неверный выбор."
        fi
    done
}

_awg_peers_node() {
    node_load "$1"
    local nname="$NODE_NAME"

    ssh_connect || return

    # SSH: проверяем AWG + получаем список peers
    local check_result
    check_result=$(ssh_run -- "if [ ! -f /etc/amnezia/amneziawg/awg0.conf ]; then echo NO_AWG; else echo AWG_OK; ls /etc/mihomo/amnezia/; fi") \
        || { warn "Не удалось получить статус AWG на $nname."; return; }

    if [[ "$check_result" == "NO_AWG" ]]; then
        warn "AmneziaWG не установлен на $nname."
        return
    fi

    local existing_peers
    existing_peers=$(echo "$check_result" | tail -n +2 | tr -d '\r' | grep -v '^$')

    # Ожидаемые peers
    local expected_peers
    expected_peers=$(_awg_expected_peers "$nname")

    while true; do
        local all_peers=() peer_status=() missing_peers=() orphan_count=0
        local idx p s
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            all_peers+=("$p")
            if printf '%s\n' "$expected_peers" | grep -qxF "$p"; then
                peer_status+=("used")
            else
                peer_status+=("orphan")
            fi
        done <<< "$existing_peers"

        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            if ! printf '%s\n' "$existing_peers" | grep -qxF "$p"; then
                missing_peers+=("$p")
                all_peers+=("$p")
                peer_status+=("missing")
            fi
        done <<< "$expected_peers"
        for s in "${peer_status[@]}"; do
            [[ "$s" == orphan ]] && orphan_count=$((orphan_count + 1))
        done

        echo ""
        box_top
        box_center "Peers: $nname"
        box_mid
        if [[ ${#all_peers[@]} -eq 0 ]]; then
            box_line " Нет peers" " ${DIM}Нет peers${NC}"
        else
            for (( idx=0; idx<${#all_peers[@]}; idx++ )); do
                p="${all_peers[$idx]}"
                s="${peer_status[$idx]}"
                case "$s" in
                    used) box_line " $((idx+1))) [✓] $p" " ${GREEN}$((idx+1)))${NC} [${GREEN}✓${NC}] $p" ;;
                    orphan) box_line " $((idx+1))) [!] $p — не привязан" " ${GREEN}$((idx+1)))${NC} [${YELLOW}!${NC}] $p ${YELLOW}— не привязан${NC}" ;;
                    missing) box_line " $((idx+1))) [-] $p — не создан" " ${GREEN}$((idx+1)))${NC} [${RED}-${NC}] $p ${RED}— не создан${NC}" ;;
                esac
            done
        fi
        box_mid
        [[ ${#missing_peers[@]} -gt 0 ]] && menu_item c "Создать недостающие peers (${#missing_peers[@]})" GREEN
        menu_item d "Удалить peer" RED
        [[ $orphan_count -gt 0 ]] && menu_item x "Удалить неиспользуемые ($orphan_count)" YELLOW
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        if ! IFS= read -rp "  Выберите действие: " _choice; then
            return 0
        fi
        _choice="${_choice%$'\r'}"
        case "$_choice" in
            c|C)
                if [[ ${#missing_peers[@]} -eq 0 ]]; then
                    info "Все peers созданы."
                    continue
                fi
                info "Создаю peers: ${missing_peers[*]}..."
                if ! upload_scripts; then
                    warn "Не удалось загрузить скрипты для ноды '${NODE_NAME}'."
                    continue
                fi
                local peers_cmd="source ${REMOTE_DIR}/modules/amneziawg.sh"
                for p in "${missing_peers[@]}"; do
                    peers_cmd="$peers_cmd && add_awg_peer_auto $(printf '%q' "$p")"
                done
                if ssh_run -- "$peers_cmd"; then
                    success "Peers созданы"
                else
                    warn "Ошибка при создании peers"
                fi
                # Обновить список
                existing_peers=$(ssh_run -- "ls /etc/mihomo/amnezia/ 2>/dev/null" | tr -d '\r' | grep -v '^$')
                ;;
            d|D)
                if [[ ${#all_peers[@]} -eq 0 ]]; then
                    warn "Нет peers для удаления."
                    continue
                fi
                read -rp "  Номер peer для удаления: " _didx
                if [[ "$_didx" =~ ^[0-9]+$ ]] && (( _didx >= 1 && _didx <= ${#all_peers[@]} )); then
                    local target="${all_peers[$((_didx - 1))]}"
                    local target_status="${peer_status[$((_didx - 1))]}"
                    if [[ "$target_status" == "missing" ]]; then
                        warn "Peer $target ещё не создан на сервере."
                        continue
                    fi
                    if confirm_yn "Удалить peer $target?"; then
                        if ! upload_scripts; then
                            warn "Не удалось загрузить скрипты для ноды '${NODE_NAME}'."
                            continue
                        fi
                        if ssh_run -- "source ${REMOTE_DIR}/modules/amneziawg.sh && remove_awg_peer_by_name $(printf '%q' "$target")"; then
                            success "Peer $target удалён"
                        else
                            warn "Не удалось удалить peer $target"
                        fi
                        existing_peers=$(ssh_run -- "ls /etc/mihomo/amnezia/ 2>/dev/null" | tr -d '\r' | grep -v '^$')
                    fi
                else
                    warn "Неверный номер."
                fi
                ;;
            x|X)
                if [[ $orphan_count -eq 0 ]]; then
                    info "Нет неиспользуемых peers."
                    continue
                fi
                local orphans=()
                for (( idx=0; idx<${#all_peers[@]}; idx++ )); do
                    [[ "${peer_status[$idx]}" == "orphan" ]] && orphans+=("${all_peers[$idx]}")
                done
                echo -e "  Будут удалены: ${YELLOW}${orphans[*]}${NC}"
                if confirm_yn "Продолжить?"; then
                    if ! upload_scripts; then
                        warn "Не удалось загрузить скрипты для ноды '${NODE_NAME}'."
                        continue
                    fi
                    local del_cmd="source ${REMOTE_DIR}/modules/amneziawg.sh"
                    for p in "${orphans[@]}"; do
                        del_cmd="$del_cmd && remove_awg_peer_by_name $(printf '%q' "$p")"
                    done
                    if ssh_run -- "$del_cmd"; then
                        success "Неиспользуемые peers удалены"
                    else
                        warn "Ошибка при удалении"
                    fi
                    existing_peers=$(ssh_run -- "ls /etc/mihomo/amnezia/ 2>/dev/null" | tr -d '\r' | grep -v '^$')
                fi
                ;;
            0) return ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}
