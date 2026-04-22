#!/bin/bash
# ─── Группы клиентов ────────────────────────────────────────────────────────

groups_list() {
    _ensure_config
    mapfile -t GRP_LIST < <(jq_r '.groups[].name')
}

_group_client_count() {
    jq_r --arg g "$1" '[.clients[] | select(.group==$g)] | length'
}

_group_nodes_csv() {
    jq_r --arg g "$1" '
        [.connections[] | select(any(.groups[]?; .name == $g)) | .node]
        | unique | join(",")'
}

_group_nodes_display() {
    local csv
    csv=$(_group_nodes_csv "$1")
    [[ -z "$csv" ]] && { echo "-"; return; }
    echo "${csv//,/, }"
}

groups_menu() {
    while true; do
        echo ""
        box_top
        box_center "Группы"
        box_bot
        echo ""

        groups_list
        if [[ ${#GRP_LIST[@]} -gt 0 ]]; then
            local i=1
            for g in "${GRP_LIST[@]}"; do
                local count
                count=$(_group_client_count "$g")
                local tpl
                tpl=$(jq_r --arg g "$g" '.groups[] | select(.name==$g) | .template // "default.yaml"')
                local tpl_display=""
                [[ "$tpl" != "default.yaml" ]] && tpl_display=" ${YELLOW}[$tpl]${NC}"
                local node_count=0
                local _gn_csv
                _gn_csv=$(_group_nodes_csv "$g")
                [[ -n "$_gn_csv" ]] && node_count=$(echo "$_gn_csv" | tr ',' '\n' | wc -l | tr -d ' ')
                echo -e "  ${GREEN}${i})${NC} $g ${DIM}— $count клиентов, $node_count нод${NC}${tpl_display}"
                i=$((i + 1))
            done
        else
            echo -e "  ${DIM}Нет групп${NC}"
        fi
        echo ""
        echo -e "  ${GREEN}a)${NC} Добавить группу"
        echo -e "  ${RED}d)${NC} Удалить группу"
        echo -e "  ${YELLOW}t)${NC} Поменять шаблон группе"
        echo -e "  ${NC}0)${NC} Назад"
        echo ""
        read -rp "Выберите: " GRP_CHOICE

        case "$GRP_CHOICE" in
            a) add_group ;;
            d) delete_group ;;
            t) assign_template_to_group ;;
            0) return ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

add_group() {
    echo ""
    read -rp "Название группы: " GROUP_NAME
    [[ -z "$GROUP_NAME" ]] && { warn "Название не указано."; return; }

    GROUP_NAME=$(echo "$GROUP_NAME" | tr '[:lower:]' '[:upper:]')

    if jq_r '.groups[].name' | grep -qx "$GROUP_NAME"; then
        warn "Группа '$GROUP_NAME' уже существует."
        return
    fi

    jq_w --arg g "$GROUP_NAME" '.groups += [{name: $g, template: "default.yaml"}]'
    success "Группа $GROUP_NAME добавлена"
}

delete_group() {
    echo ""
    groups_list

    if [[ ${#GRP_LIST[@]} -eq 0 ]]; then
        warn "Нет групп для удаления."
        return
    fi

    local i=1
    for g in "${GRP_LIST[@]}"; do
        echo -e "  ${GREEN}${i})${NC} $g"
        i=$((i + 1))
    done
    echo ""
    read -rp "Номер группы для удаления: " DEL_IDX

    if ! [[ "$DEL_IDX" =~ ^[0-9]+$ ]] || (( DEL_IDX < 1 || DEL_IDX > ${#GRP_LIST[@]} )); then
        warn "Неверный выбор."
        return
    fi

    local target="${GRP_LIST[$((DEL_IDX - 1))]}"

    # Проверяем есть ли клиенты в этой группе
    local count
    count=$(_group_client_count "$target")
    if [[ "$count" -gt 0 ]]; then
        warn "В группе '$target' есть клиенты. Сначала удалите их."
        return
    fi

    confirm_yn "Удалить группу '$target'?" || { info "Отменено."; return; }

    jq_w --arg g "$target" '
        .groups |= map(select(.name != $g)) |
        .connections |= map(.groups |= [.[] | select(.name!=$g)]) |
        .connections |= [.[] | select(.groups | length > 0)]'
    success "Группа $target удалена"
}

# Выбор группы из списка, возвращает имя в SELECTED_GROUP
select_group() {
    groups_list
    if [[ ${#GRP_LIST[@]} -eq 0 ]]; then
        warn "Нет групп. Добавьте группу через меню Группы."
        return 1
    fi

    local i=1
    for g in "${GRP_LIST[@]}"; do
        local count
        count=$(_group_client_count "$g")
        echo -e "  ${GREEN}${i})${NC} $g ${DIM}— $count клиентов${NC}"
        i=$((i + 1))
    done
    echo ""
    read -rp "Выберите группу: " GRP_IDX

    if ! [[ "$GRP_IDX" =~ ^[0-9]+$ ]] || (( GRP_IDX < 1 || GRP_IDX > ${#GRP_LIST[@]} )); then
        warn "Неверный выбор."
        return 1
    fi

    SELECTED_GROUP="${GRP_LIST[$((GRP_IDX - 1))]}"
}

assign_template_to_group() {
    echo ""
    echo -e "  Выберите группу:"
    if ! select_group; then return; fi
    local group="$SELECTED_GROUP"

    # Текущий шаблон
    local current_tpl
    current_tpl=$(_template_name_for_group "$group")
    info "Текущий шаблон: $current_tpl"

    # Список шаблонов
    echo ""
    echo -e "  Доступные шаблоны:"
    local templates=()
    while IFS= read -r f; do
        templates+=("$(basename "$f")")
    done < <(find "$TEMPLATES_DIR" -maxdepth 1 -name '*.yaml' -type f 2>/dev/null | sort)

    if [[ ${#templates[@]} -eq 0 ]]; then
        warn "Нет шаблонов в $TEMPLATES_DIR/"
        return
    fi

    local i=1
    for t in "${templates[@]}"; do
        local marker=""
        [[ "$t" == "$current_tpl" ]] && marker=" ${GREEN}<- текущий${NC}"
        echo -e "  ${GREEN}${i})${NC} $t${marker}"
        i=$((i + 1))
    done
    echo -e "  ${GREEN}n)${NC} Создать новый шаблон"
    echo ""
    read -rp "Выберите шаблон: " TPL_CHOICE

    if [[ "$TPL_CHOICE" == "n" || "$TPL_CHOICE" == "N" ]]; then
        _create_new_template "$group"
        return
    fi

    if ! [[ "$TPL_CHOICE" =~ ^[0-9]+$ ]] || (( TPL_CHOICE < 1 || TPL_CHOICE > ${#templates[@]} )); then
        warn "Неверный выбор."
        return
    fi

    local selected="${templates[$((TPL_CHOICE - 1))]}"
    jq_w --arg g "$group" --arg t "$selected" \
        '.groups |= map(if .name==$g then .template=$t else . end)'
    success "Группа $group: шаблон — $selected"
}

_create_new_template() {
    local group="$1"

    read -rp "Имя нового шаблона (без .yaml): " TPL_NAME
    [[ -z "$TPL_NAME" ]] && { warn "Имя не указано."; return; }

    local new_file="$TEMPLATES_DIR/${TPL_NAME}.yaml"
    if [[ -f "$new_file" ]]; then
        warn "Шаблон '${TPL_NAME}.yaml' уже существует."
        return
    fi

    # Копируем default.yaml как основу
    local default_tpl="$TEMPLATES_DIR/default.yaml"
    if [[ -f "$default_tpl" ]]; then
        cp "$default_tpl" "$new_file"
        info "Скопирован default.yaml как основа"
    else
        touch "$new_file"
        warn "default.yaml не найден — создан пустой шаблон"
    fi

    # Открываем редактор
    if command -v nano > /dev/null 2>&1; then
        nano "$new_file"
    elif command -v vi > /dev/null 2>&1; then
        vi "$new_file"
    else
        info "Отредактируйте вручную: $new_file"
    fi

    # Назначаем группе
    jq_w --arg g "$group" --arg t "${TPL_NAME}.yaml" \
        '.groups |= map(if .name==$g then .template=$t else . end)'
    success "Группа $group: шаблон — ${TPL_NAME}.yaml"
}
