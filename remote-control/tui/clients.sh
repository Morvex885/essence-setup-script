#!/bin/bash
# ─── Экраны TUI: клиенты, группы, шаблоны, генерация, подписки ───────────────
# Данные — только результаты команд ядра через tui_call (tui_q/tui_eq).
# Каждый экран — цикл полного кадра: данные → кадр → ввод. 0/EOF → rc 0.

# ─── Общие помощники ─────────────────────────────────────────────────────────

# Итог генерации по TUI_DATA: пустые строки не выводятся.
_tui_generate_summary() {
    local v
    local -a lines=()
    v=$(tui_q '.ok | join(", ")');           [[ -z "$v" ]] || lines+=("Готово: $v")
    v=$(tui_q '.skipped | join(", ")');      [[ -z "$v" ]] || lines+=("Пропущено: $v")
    v=$(tui_q '.failed | join(", ")');       [[ -z "$v" ]] || lines+=("Ошибки: $v")
    v=$(tui_q '.nodes_failed | join(", ")'); [[ -z "$v" ]] || lines+=("Ноды с ошибкой: $v")
    v=$(tui_q '.dir // empty');              [[ -z "$v" ]] || lines+=("Каталог: $v")
    review_frame "Итог генерации" "${lines[@]}"
}

# _tui_generate_run ARGV… — generate …; итог показывается и при partial.
_tui_generate_run() {
    tui_call generate "$@" || true
    [[ "$TUI_DATA" == null ]] || _tui_generate_summary
}

# Итог публикации всех подписок по TUI_DATA.
_tui_publish_summary() {
    local v
    local -a lines=()
    v=$(tui_q '.published | join(", ")'); [[ -z "$v" ]] || lines+=("Опубликовано: $v")
    v=$(tui_q '.skipped | join(", ")');   [[ -z "$v" ]] || lines+=("Пропущено: $v")
    v=$(tui_q '.failed | join(", ")');    [[ -z "$v" ]] || lines+=("Ошибки: $v")
    v=$(tui_q '.removed // 0');           [[ "$v" == 0 ]] || lines+=("Удалено устаревших: $v")
    (( ${#lines[@]} > 0 )) || lines=("Нечего публиковать.")
    review_frame "Итог публикации подписок" "${lines[@]}"
}

# ─── Клиенты ─────────────────────────────────────────────────────────────────

tui_clients() {
    local count i name
    local -a names labels
    while true; do
        tui_call client list || return 0
        _tui_list_into '.[].name'; names=("${TUI_LIST[@]}")
        _tui_list_into '.[] | "\(.name)  (\(.group))"'; labels=("${TUI_LIST[@]}")
        count=${#names[@]}
        _tui_head "Клиенты"
        if (( count == 0 )); then
            box_line " Нет клиентов" " ${DIM}Нет клиентов${NC}"
        else
            for ((i = 0; i < count; i++)); do
                menu_item "$((i + 1))" "${labels[$i]}" CYAN
            done
        fi
        box_mid
        menu_item a "Добавить клиента" GREEN
        menu_item d "Удалить клиентов" RED
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            a|A)
                _tui_ask "Имя клиента" || return 0
                name="$TUI_ANSWER"
                if [[ -z "$name" ]]; then
                    warn "Имя клиента не указано."
                    continue
                fi
                tui_pick_group "Группа клиента" || continue
                tui_call client add --name "$name" --group "$TUI_PICK" || true
                ;;
            d|D) _tui_clients_delete "${names[@]}" ;;
            0) return 0 ;;
            *)
                if menu_index_valid "$TUI_CHOICE" "$count"; then
                    tui_client_card "${names[$((TUI_CHOICE - 1))]}"
                else
                    warn "Неверный выбор."
                fi
                ;;
        esac
    done
}

_tui_clients_delete() {
    local i
    local -a args=(client delete)
    _TG_LABELS=("$@")
    _TG_FLAGS=()
    for _ in "$@"; do _TG_FLAGS+=(0); done
    _tui_toggle "Удаление клиентов" || return 0
    if (( ${#TUI_PICKED_IDX[@]} == 0 )); then
        warn "Ничего не выбрано."
        return 0
    fi
    for i in "${TUI_PICKED_IDX[@]}"; do args+=(--name "${_TG_LABELS[$i]}"); done
    tui_run_confirmed "Удаление клиентов" "Удалить выбранных клиентов?" "${args[@]}" || true
}

tui_client_card() {
    local name="$1" row inherit nodes group sub_line expires published
    while true; do
        tui_call client list || return 0
        row=$(tui_q -c --arg n "$name" '.[] | select(.name == $n)')
        if [[ -z "$row" ]]; then
            warn "Клиент '$name' не найден."
            return 0
        fi
        group=$(printf '%s' "$row" | jq -r '.group')
        inherit=$(printf '%s' "$row" | jq -r '.inherit_nodes')
        nodes=$(printf '%s' "$row" | jq -r '.nodes | join(", ")')
        published=$(printf '%s' "$row" | jq -r '.subscription.published')
        expires=$(printf '%s' "$row" | jq -r '.subscription.expires_at // empty')
        if [[ "$published" != true ]]; then
            sub_line="нет"
        elif [[ -n "$expires" ]]; then
            sub_line="опубликована до $expires"
        else
            sub_line="опубликована, без срока"
        fi
        _tui_head "Клиент: $name"
        box_line " Группа: $group"
        if [[ "$inherit" == true ]]; then
            box_line " Ноды: от группы (${nodes:-нет})"
        else
            box_line " Ноды: свои (${nodes:-нет})"
        fi
        box_line " Подписка: $sub_line"
        box_mid
        menu_item v "Показать данные подключения" CYAN
        menu_item s "Подписка" CYAN
        box_mid
        menu_item f "Сгенерировать конфиг" YELLOW
        menu_item n "Ноды клиента" YELLOW
        menu_item p "Подключения по нодам" YELLOW
        menu_item g "Сменить группу" YELLOW
        menu_item r "Переименовать" YELLOW
        menu_item d "Удалить клиента" RED
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            v|V) _tui_client_show "$name" ;;
            s|S) tui_client_subscription "$name" ;;
            f|F) _tui_generate_run --client "$name" ;;
            n|N) _tui_client_nodes "$name" "$inherit" "$row" ;;
            p|P)
                if [[ "$inherit" == true ]]; then
                    warn "Подключения настраиваются только для клиента со своими нодами."
                else
                    _tui_client_connections "$name" "$row"
                fi
                ;;
            g|G)
                if tui_pick_group "Новая группа клиента"; then
                    tui_run_confirmed "Смена группы клиента" "Сменить группу?" \
                        client set-group --name "$name" --group "$TUI_PICK" || true
                fi
                ;;
            r|R)
                _tui_ask "Новое имя клиента" || return 0
                if [[ -z "$TUI_ANSWER" ]]; then
                    warn "Имя клиента не указано."
                elif tui_run_confirmed "Переименование клиента" "Переименовать клиента?" \
                    client rename --name "$name" --new-name "$TUI_ANSWER" || [[ "$TUI_CODE" == partial ]]; then
                    name=$(tui_q '.name')
                fi
                ;;
            d|D)
                if tui_run_confirmed "Удаление клиента" "Удалить клиента?" client delete --name "$name" ||
                    { [[ "$TUI_CODE" == partial ]] && [[ "$(tui_q --arg n "$name" '.deleted // [] | index($n) != null')" == true ]]; }; then
                    return 0
                fi
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

# Явный запрос данных клиента: секреты показываются здесь и только здесь.
_tui_client_show() {
    local name="$1" line
    tui_call client show --name "$name" || return 0
    _tui_head "Данные клиента: $name"
    box_line " Группа: $(tui_q '.group')"
    box_line " Ноды: $(tui_q '.nodes | if length == 0 then "нет" else join(", ") end')"
    box_line " VLESS UUID: $(tui_q '.credentials.vless_uuid // "—"')"
    box_line " Hysteria2 пароль: $(tui_q '.credentials.hy2_password // "—"')"
    box_line " Конфиг: $(tui_q '.config.path') ($(tui_q 'if .config.exists then "создан" else "не создан" end'))"
    if [[ "$(tui_q '.subscription != null')" == true ]]; then
        box_line " Подписка: $(tui_q '.subscription.url // "ссылка недоступна"')"
    else
        box_line " Подписка: нет"
    fi
    if [[ "$(tui_q '.connections | length')" != 0 ]]; then
        box_mid
        box_line " Подключения по нодам:" " ${CYAN}Подключения по нодам:${NC}"
        while IFS= read -r line; do
            box_line "   $line"
        done < <(tui_q '.connections[] | "\(.node) (\(if .mode == "own" then "свои" else "от группы" end)): \(.proxies | if length == 0 then "нет" else join(", ") end)"')
    fi
    box_bot
}

_tui_client_nodes() {
    local name="$1" inherit="$2" row="$3" cur i
    local -a args=(client nodes --name "$name")
    if [[ "$inherit" == true ]]; then
        MENU_SELECT_CONTEXT=("Сейчас ноды берутся от группы.")
        menu_select "Ноды клиента: $name" "Выберите действие" "Назначить свои ноды" || return 0
    else
        MENU_SELECT_CONTEXT=("Сейчас у клиента свои ноды.")
        menu_select "Ноды клиента: $name" "Выберите действие" \
            "Изменить свои ноды" "Вернуть ноды от группы" || return 0
        if [[ "$MENU_SELECT_INDEX" == 2 ]]; then
            tui_run_confirmed "Ноды клиента" "Вернуть ноды от группы?" \
                client nodes --name "$name" --inherit || true
            return 0
        fi
    fi
    cur=$(printf '%s' "$row" | jq -c '.nodes')
    tui_call node list || return 0
    _tui_list_into '.[].name'; _TG_NAMES=("${TUI_LIST[@]}")
    _tui_list_into '.[] | "\(.name)  \(.ip):\(.port)"'; _TG_LABELS=("${TUI_LIST[@]}")
    _tui_list_into --argjson cur "$cur" '.[] | if ([.name] | inside($cur)) then 1 else 0 end'; _TG_FLAGS=("${TUI_LIST[@]}")
    _tui_toggle "Свои ноды клиента: $name" || return 0
    if (( ${#TUI_PICKED_IDX[@]} == 0 )); then
        warn "Ничего не выбрано."
        return 0
    fi
    for i in "${TUI_PICKED_IDX[@]}"; do args+=(--node "${_TG_NAMES[$i]}"); done
    tui_call "${args[@]}" || true
}

_tui_client_connections() {
    local name="$1" row="$2" node cur i found label
    local -a args
    local -a cnodes=() names=() labels=()
    while IFS= read -r i; do cnodes+=("$i"); done < <(printf '%s' "$row" | jq -r '.nodes[]')
    if (( ${#cnodes[@]} == 0 )); then
        warn "У клиента нет своих нод."
        return 0
    fi
    tui_call node list || return 0
    for i in "${cnodes[@]}"; do
        label=$(tui_q --arg n "$i" '.[] | select(.name == $n) | "\(.name)  \(.ip):\(.port)"')
        [[ -n "$label" ]] || continue
        names+=("$i")
        labels+=("$label")
    done
    if (( ${#names[@]} == 0 )); then
        warn "Назначенные ноды больше недоступны."
        return 0
    fi
    MENU_SELECT_EMPTY="Нет нод"
    menu_select "Подключения клиента: $name" "Выберите ноду" "${labels[@]}" || return 0
    node="${names[$((MENU_SELECT_INDEX - 1))]}"
    menu_select "Подключения: $name на $node" "Выберите действие" \
        "Настроить подключения" "Сбросить на групповые" || return 0
    if [[ "$MENU_SELECT_INDEX" == 2 ]]; then
        tui_run_confirmed "Сброс подключений" "Сбросить подключения ноды?" \
            client connections --name "$name" --node "$node" --reset || true
        return 0
    fi
    tui_call client connections --name "$name" || return 0
    cur=$(tui_q -c --arg n "$node" '[.[] | select(.node == $n) | .proxies[]?]')
    while true; do
        if tui_call conn list --node "$node" --discover; then
            break
        fi
        tui_handle_node_codes "$node"
        (( $? == 2 )) || return 0
    done
    _tui_list_into '.[0].discovered[]?'; _TG_LABELS=("${TUI_LIST[@]}")
    _TG_FLAGS=()
    for found in "${_TG_LABELS[@]}"; do
        if [[ "$(printf '%s' "$cur" | jq -r --arg p "$found" 'index($p) != null')" == true ]]; then
            _TG_FLAGS+=(1)
        else
            _TG_FLAGS+=(0)
        fi
    done
    _tui_toggle "Подключения клиента на $node" || return 0
    if (( ${#TUI_PICKED_IDX[@]} == 0 )); then
        warn "Ничего не выбрано."
        return 0
    fi
    args=(client connections --name "$name" --node "$node")
    for i in "${TUI_PICKED_IDX[@]}"; do args+=(--proxy "${_TG_LABELS[$i]}"); done
    tui_call "${args[@]}" || true
}

# ─── Подписка клиента и заголовки ────────────────────────────────────────────

tui_client_subscription() {
    local name="$1" row host sub_line published expires
    while true; do
        tui_call client list || return 0
        row=$(tui_q -c --arg n "$name" '.[] | select(.name == $n)')
        if [[ -z "$row" ]]; then
            warn "Клиент '$name' не найден."
            return 0
        fi
        published=$(printf '%s' "$row" | jq -r '.subscription.published')
        expires=$(printf '%s' "$row" | jq -r '.subscription.expires_at // empty')
        if [[ "$published" != true ]]; then
            sub_line="нет"
        elif [[ -n "$expires" ]]; then
            sub_line="опубликована до $expires"
        else
            sub_line="опубликована, без срока"
        fi
        tui_call sub host || true
        host=$(tui_q '.node // empty')
        _tui_head "Подписка клиента: $name"
        if [[ -n "$host" ]]; then
            box_line " Хост подписок: $host"
        else
            box_line " Хост подписок не задан — раздел s" " ${DIM}Хост подписок не задан — раздел s${NC}"
        fi
        box_line " Подписка: $sub_line"
        box_mid
        menu_item p "Опубликовать" GREEN
        menu_item v "Показать ссылку" CYAN
        menu_item i "Итоговые заголовки" CYAN
        menu_item h "Заголовки клиента" YELLOW
        menu_item r "Сменить токен" RED
        menu_item x "Отозвать подписку" RED
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            p|P)
                _tui_ask "Срок действия (12h, 30d, 2w; Enter — без срока)" || return 0
                # partial — подписка сохранена (не прошла проверка HTTP): ссылка всё равно нужна.
                if [[ -n "$TUI_ANSWER" ]]; then
                    tui_call sub publish --client "$name" --ttl "$TUI_ANSWER" || [[ "$TUI_CODE" == partial ]] || continue
                else
                    tui_call sub publish --client "$name" || [[ "$TUI_CODE" == partial ]] || continue
                fi
                _tui_share_bundle "$name"
                ;;
            v|V) _tui_share_bundle "$name" ;;
            i|I) _tui_resolved_headers "$name" ;;
            h|H) tui_headers client "$name" ;;
            r|R)
                if tui_run_confirmed "Смена токена подписки" "Сменить токен?" sub rotate --client "$name" ||
                    [[ "$TUI_CODE" == partial ]]; then
                    _tui_share_bundle "$name"
                fi
                ;;
            x|X) tui_run_confirmed "Отзыв подписки" "Отозвать подписку?" sub revoke --client "$name" || true ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

_tui_share_bundle() {
    tui_call sub show --client "$1" || return 0
    tui_render_share_bundle
}

_tui_resolved_headers() {
    local line
    tui_call sub headers --client "$1" || return 0
    _tui_head "Итоговые заголовки: $1"
    if [[ "$(tui_q 'length')" == 0 ]]; then
        box_line " Нет заголовков" " ${DIM}Нет заголовков${NC}"
    else
        while IFS= read -r line; do
            box_line " $line"
        done < <(tui_q '.[] | "\(.name): \(.value)  [\(if .source == "default" then "по умолчанию" elif .source == "group" then "группа" elif .source == "client" then "клиент" else .source end)]"')
    fi
    box_bot
}

# tui_headers client|group NAME
tui_headers() {
    local kind="$1" name="$2" count line hname hvalue i
    local -a own
    while true; do
        tui_call sub headers "--$kind" "$name" || return 0
        count=$(tui_q 'length')
        _tui_head "Заголовки подписки: $name"
        if [[ "$count" == 0 ]]; then
            box_line " Нет заголовков" " ${DIM}Нет заголовков${NC}"
        elif [[ "$kind" == client ]]; then
            while IFS= read -r line; do box_line " $line"; done \
                < <(tui_q '.[] | "\(.name): \(.value)  [\(if .source == "default" then "по умолчанию" elif .source == "group" then "группа" elif .source == "client" then "клиент" else .source end)]"')
        else
            while IFS= read -r line; do box_line " $line"; done \
                < <(tui_q '.[] | "\(.name): \(.value)"')
        fi
        box_mid
        menu_item a "Установить" YELLOW
        menu_item d "Удалить" RED
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            a|A)
                _tui_ask "Имя заголовка" || return 0
                hname="$TUI_ANSWER"
                _tui_ask "Значение" || return 0
                hvalue="$TUI_ANSWER"
                if [[ -z "$hname" || -z "$hvalue" ]]; then
                    warn "Имя и значение заголовка обязательны."
                    continue
                fi
                tui_call sub headers "--$kind" "$name" --set "$hname=$hvalue" || true
                ;;
            d|D)
                if [[ "$kind" == client ]]; then
                    _tui_list_into '.[] | select(.source == "client") | .name'
                else
                    _tui_list_into '.[].name'
                fi
                own=("${TUI_LIST[@]}")
                MENU_SELECT_EMPTY="Нет собственных заголовков"
                menu_select "Удаление заголовка" "Выберите заголовок" "${own[@]}" || continue
                i=$((MENU_SELECT_INDEX - 1))
                tui_call sub headers "--$kind" "$name" --unset "${own[$i]}" || true
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

# ─── Группы ──────────────────────────────────────────────────────────────────

tui_groups() {
    local count i
    local -a names labels
    while true; do
        tui_call group list || return 0
        _tui_list_into '.[].name'; names=("${TUI_LIST[@]}")
        _tui_list_into '.[] | "\(.name)  (\(.template))"'; labels=("${TUI_LIST[@]}")
        count=${#names[@]}
        _tui_head "Группы"
        if (( count == 0 )); then
            box_line " Нет групп" " ${DIM}Нет групп${NC}"
        else
            for ((i = 0; i < count; i++)); do
                menu_item "$((i + 1))" "${labels[$i]}" CYAN
            done
        fi
        box_mid
        menu_item a "Добавить группу" GREEN
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            a|A)
                _tui_ask "Название группы" || return 0
                if [[ -z "$TUI_ANSWER" ]]; then
                    warn "Название не указано."
                else
                    tui_call group add --name "$TUI_ANSWER" || true
                fi
                ;;
            0) return 0 ;;
            *)
                if menu_index_valid "$TUI_CHOICE" "$count"; then
                    tui_group_card "${names[$((TUI_CHOICE - 1))]}"
                else
                    warn "Неверный выбор."
                fi
                ;;
        esac
    done
}

tui_group_card() {
    local name="$1" row
    while true; do
        tui_call group list || return 0
        row=$(tui_q -c --arg n "$name" '.[] | select(.name == $n)')
        if [[ -z "$row" ]]; then
            warn "Группа '$name' не найдена."
            return 0
        fi
        _tui_head "Группа: $name"
        box_line " Шаблон: $(printf '%s' "$row" | jq -r '.template')"
        box_line " Клиентов: $(printf '%s' "$row" | jq -r '.clients')"
        box_line " Ноды: $(printf '%s' "$row" | jq -r '.nodes | if length == 0 then "нет" else join(", ") end')"
        box_mid
        menu_item t "Шаблон" YELLOW
        menu_item h "Заголовки подписки группы" YELLOW
        menu_item f "Сгенерировать конфиги группы" YELLOW
        menu_item d "Удалить группу" RED
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            t|T) _tui_group_template "$name" "$(printf '%s' "$row" | jq -r '.template')" ;;
            h|H) tui_headers group "$name" ;;
            f|F) _tui_generate_run --group "$name" ;;
            d|D)
                if tui_run_confirmed "Удаление группы" "Удалить группу?" group delete --name "$name"; then
                    return 0
                fi
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

_tui_group_template() {
    local name="$1" current="$2" count created
    local -a names
    tui_call template list || return 0
    _tui_list_into '.[].name'; names=("${TUI_LIST[@]}")
    count=${#names[@]}
    MENU_SELECT_CONTEXT=("Текущий: $current")
    menu_select "Шаблон группы: $name" "Выберите шаблон" "${names[@]}" "Создать новый шаблон" || return 0
    if (( MENU_SELECT_INDEX > count )); then
        _tui_ask "Имя нового шаблона" || return 0
        if [[ -z "$TUI_ANSWER" ]]; then
            warn "Имя шаблона не указано."
            return 0
        fi
        tui_call template create --name "$TUI_ANSWER" --group "$name" || return 0
        created=$(tui_q '.name')
        tui_template_edit "$created" || true
    else
        tui_call group set-template --name "$name" --template "${names[$((MENU_SELECT_INDEX - 1))]}" || true
    fi
}

# ─── Шаблоны ─────────────────────────────────────────────────────────────────

tui_templates() {
    local count i created
    local -a names labels
    while true; do
        tui_call template list || return 0
        _tui_list_into '.[].name'; names=("${TUI_LIST[@]}")
        _tui_list_into '.[] | "\(.name)  (\(if .source == "builtin" then "встроенный" else "пользовательский" end))"'
        labels=("${TUI_LIST[@]}")
        count=${#names[@]}
        _tui_head "Шаблоны"
        if (( count == 0 )); then
            box_line " Нет шаблонов" " ${DIM}Нет шаблонов${NC}"
        else
            for ((i = 0; i < count; i++)); do
                menu_item "$((i + 1))" "${labels[$i]}" CYAN
            done
        fi
        box_mid
        menu_item a "Создать шаблон" GREEN
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            a|A)
                _tui_ask "Имя шаблона" || return 0
                if [[ -z "$TUI_ANSWER" ]]; then
                    warn "Имя шаблона не указано."
                    continue
                fi
                tui_call template create --name "$TUI_ANSWER" || continue
                created=$(tui_q '.name')
                tui_template_edit "$created" || true
                ;;
            0) return 0 ;;
            *)
                if menu_index_valid "$TUI_CHOICE" "$count"; then
                    tui_template_card "${names[$((TUI_CHOICE - 1))]}"
                else
                    warn "Неверный выбор."
                fi
                ;;
        esac
    done
}

tui_template_card() {
    local name="$1" row source
    while true; do
        tui_call template list || return 0
        row=$(tui_q -c --arg n "$name" '.[] | select(.name == $n)')
        if [[ -z "$row" ]]; then
            warn "Шаблон '$name' не найден."
            return 0
        fi
        source=$(printf '%s' "$row" | jq -r 'if .source == "builtin" then "встроенный" else "пользовательский" end')
        _tui_head "Шаблон: $name"
        box_line " Источник: $source"
        box_line " Группы: $(printf '%s' "$row" | jq -r '.groups | if length == 0 then "нет" else join(", ") end')"
        box_mid
        menu_item v "Показать" CYAN
        menu_item x "Экспорт в файл" CYAN
        menu_item e "Редактировать" YELLOW
        menu_item i "Импорт из файла" YELLOW
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            v|V)
                if tui_call template show --name "$name"; then
                    _tui_head "Содержимое: $name"
                    box_line " Путь: $(tui_q '.path')"
                    box_bot
                    printf '%s' "$TUI_DATA" | jq -r '.content'
                fi
                ;;
            e|E) tui_template_edit "$name" || true ;;
            x|X)
                _tui_ask "Путь к файлу" || return 0
                [[ -n "$TUI_ANSWER" ]] || { warn "Путь не указан."; continue; }
                case "$TUI_ANSWER" in '~') TUI_ANSWER="$HOME" ;; '~/'*) TUI_ANSWER="$HOME/${TUI_ANSWER#\~/}" ;; esac
                tui_run_confirmed "Экспорт шаблона" "Перезаписать файл?" \
                    template export --name "$name" --output "$TUI_ANSWER" || true
                ;;
            i|I)
                _tui_ask "Путь к файлу" || return 0
                [[ -n "$TUI_ANSWER" ]] || { warn "Путь не указан."; continue; }
                case "$TUI_ANSWER" in '~') TUI_ANSWER="$HOME" ;; '~/'*) TUI_ANSWER="$HOME/${TUI_ANSWER#\~/}" ;; esac
                tui_run_confirmed "Импорт шаблона" "Перезаписать шаблон?" \
                    template import --name "$name" --file "$TUI_ANSWER" || true
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

# Запуск редактора с терминала (в тестах переопределяется).
_tui_run_editor() {
    local editor="$1" file="$2"
    # shellcheck disable=SC2086
    $editor "$file" < /dev/tty > /dev/tty 7>&- 8>&-
}

# Правка и импорт во временном каталоге; каталог удаляет вызывающий.
_tui_template_edit_in() {
    local dir="$1" name="$2" editor="$3"
    (umask 077
        printf '%s' "$TUI_DATA" | jq -j '.content' > "$dir/orig.yaml" &&
            cp "$dir/orig.yaml" "$dir/edit.yaml"
    ) || return 1
    if ! tui_with_tty _tui_run_editor "$editor" "$dir/edit.yaml"; then
        warn "Редактор завершился с ошибкой. Изменения не сохранены."
        return 1
    fi
    if cmp -s "$dir/orig.yaml" "$dir/edit.yaml"; then
        info "Изменений нет."
        return 0
    fi
    tui_call template import --name "$name" --file "$dir/edit.yaml" --yes
}

tui_template_edit() {
    local name="$1" editor dir rc=0
    tui_call template show --name "$name" || return 1
    editor="${VISUAL:-${EDITOR:-}}"
    if [[ -z "$editor" ]]; then
        if command -v nano > /dev/null 2>&1; then
            editor="nano"
        elif command -v vi > /dev/null 2>&1; then
            editor="vi"
        fi
    fi
    if [[ -z "$editor" ]]; then
        warn "Редактор не найден: установите nano или задайте EDITOR."
        return 1
    fi
    tui_tmp_init || return 1
    dir=$(umask 077; mktemp -d "$TUI_TMP/rc-template.XXXXXX") || {
        warn "Не удалось создать временный каталог."
        return 1
    }
    _tui_template_edit_in "$dir" "$name" "$editor" || rc=$?
    rm -rf "$dir"
    return "$rc"
}

# ─── Генерация ───────────────────────────────────────────────────────────────

tui_generate() {
    local line
    while true; do
        tui_call group list || return 0
        _tui_head "Генерация конфигов"
        if [[ "$(tui_q 'length')" == 0 ]]; then
            box_line " Нет групп" " ${DIM}Нет групп${NC}"
        else
            while IFS= read -r line; do
                box_line " $line"
            done < <(tui_q '.[] | "\(.name) → \(.template)"')
        fi
        box_mid
        menu_item a "Всем клиентам" YELLOW
        menu_item g "По группе" YELLOW
        menu_item c "Одному клиенту" YELLOW
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            a|A) _tui_generate_run --all ;;
            g|G) tui_pick_group "Генерация по группе" && _tui_generate_run --group "$TUI_PICK" ;;
            c|C) tui_pick_client "Генерация для клиента" && _tui_generate_run --client "$TUI_PICK" ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

# ─── Подписки ────────────────────────────────────────────────────────────────

tui_subscriptions() {
    local host node
    while true; do
        tui_call sub host || return 0
        host=$(tui_q '.node // empty')
        _tui_head "Подписки"
        if [[ -n "$host" ]]; then
            box_line " Хост-нода: $host" " Хост-нода: ${GREEN}${host}${NC}"
            box_line " Базовый URL: $(tui_q '.base_url // "—"')"
        else
            box_line " Хост-нода подписок не задана" " ${DIM}Хост-нода подписок не задана${NC}"
        fi
        box_mid
        menu_item h "Хост-нода подписок" YELLOW
        menu_item l "Список подписок" CYAN
        menu_item u "Обновить все подписки" YELLOW
        menu_item m "Перенос на другую ноду" YELLOW
        menu_item c "Подписка клиента" CYAN
        menu_item g "Заголовки группы" YELLOW
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            h|H)
                if tui_pick_node "Хост-нода подписок"; then
                    node="$TUI_PICK"
                    while ! tui_call sub host --node "$node"; do
                        tui_handle_node_codes "$node"
                        (( $? == 2 )) || break
                    done
                fi
                ;;
            l|L) _tui_sub_list ;;
            u|U)
                tui_run_confirmed "Обновление подписок" "Опубликовать подписки?" sub publish-all || true
                [[ "$TUI_DATA" == null ]] || _tui_publish_summary
                ;;
            m|M)
                if tui_pick_node "Перенос подписок на ноду"; then
                    tui_run_confirmed "Перенос подписок" "Перенести подписки?" \
                        sub migrate --node "$TUI_PICK" || true
                fi
                ;;
            c|C) tui_pick_client "Подписка клиента" && tui_client_subscription "$TUI_PICK" ;;
            g|G) tui_pick_group "Заголовки группы" && tui_headers group "$TUI_PICK" ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

_tui_sub_list() {
    local client expires state color
    tui_call sub list || return 0
    _tui_head "Список подписок"
    if [[ "$(tui_q 'length')" == 0 ]]; then
        box_line " Нет опубликованных подписок" " ${DIM}Нет опубликованных подписок${NC}"
    else
        while IFS=$'\t' read -r client expires state; do
            case "$state" in
                active)  color="$GREEN"; state="действует" ;;
                expired) color="$YELLOW"; state="истекла" ;;
                unlimited) color="$DIM"; state="без срока" ;;
                *) color="$DIM"; state="срок неизвестен" ;;
            esac
            box_line " $client  $expires  $state" " $client  $expires  ${color}${state}${NC}"
        done < <(tui_q '.[] | [.client, (.expires_at // "—"), .state] | @tsv')
    fi
    box_bot
}
