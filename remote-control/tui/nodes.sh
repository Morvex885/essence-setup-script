#!/bin/bash
# ─── Экраны TUI: ноды, SSH, подключения, AmneziaWG, Telegram ─────────────────
# Данные — только результаты команд ядра через tui_call (tui_q/tui_eq).
# Каждый экран — цикл полного кадра: данные → кадр → ввод. 0/EOF → rc 0.
# Пароль SSH передаётся только через tui_secret и очищается сразу после вызова.

# ─── Помощники ───────────────────────────────────────────────────────────────

# _tui_node_try NAME ARGV… — вызов с обработкой кодов ноды; rc 0 — успех.
_tui_node_try() {
    local name="$1" rc
    shift
    while true; do
        tui_call "$@" && return 0
        rc=0
        tui_handle_node_codes "$name" || rc=$?
        (( rc == 2 )) || return 1
    done
}

# _tui_node_confirmed NAME TITLE QUESTION ARGV… — то же с подтверждением плана.
_tui_node_confirmed() {
    local name="$1" title="$2" question="$3" rc
    shift 3
    while true; do
        tui_run_confirmed "$title" "$question" "$@" && return 0
        rc=0
        tui_handle_node_codes "$name" || rc=$?
        (( rc == 2 )) || return 1
    done
}

# Меню сервера Telegram Proxy одной ноды (нужен терминал; serve откроет /dev/tty).
_tui_node_telegram_menu() {
    _tui_node_confirmed "$1" "Загрузка скриптов" "Загрузить скрипты и открыть меню?" \
        telegram menu --node "$1" || true
}

# ─── Ноды ────────────────────────────────────────────────────────────────────

tui_nodes() {
    local count i pending
    local -a names labels colors
    while true; do
        tui_call node list || return 0
        _tui_list_into '.[].name'; names=("${TUI_LIST[@]}")
        _tui_list_into '.[] | "\(.name)  \(.ip):\(.port)"'; labels=("${TUI_LIST[@]}")
        _tui_list_into '.[] | if ((.auth == "password" and .password != "ok") or ((.issues // []) | length) > 0) then "YELLOW" else "CYAN" end'
        colors=("${TUI_LIST[@]}")
        count=${#names[@]}
        pending=false
        if tui_call status; then pending=$(tui_q '.ssh_setup_pending'); fi
        _tui_head "Ноды"
        if (( count == 0 )); then
            box_line " Нет нод" " ${DIM}Нет нод${NC}"
        else
            for ((i = 0; i < count; i++)); do
                menu_item "$((i + 1))" "${labels[$i]}" "${colors[$i]}"
            done
        fi
        box_mid
        menu_item a "Добавить ноду" GREEN
        [[ "$pending" != true ]] || menu_item h "Завершить отложенную SSH-настройку" YELLOW
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            a|A) tui_node_add ;;
            h|H)
                if [[ "$pending" == true ]]; then
                    tui_node_setup_ssh
                else
                    warn "Неверный выбор."
                fi
                ;;
            0) return 0 ;;
            *)
                if menu_index_valid "$TUI_CHOICE" "$count"; then
                    tui_node_card "${names[$((TUI_CHOICE - 1))]}"
                else
                    warn "Неверный выбор."
                fi
                ;;
        esac
    done
}

tui_node_card() {
    local name="$1" auth pw_state issues scope pw
    local -a labels
    while true; do
        tui_call node show --name "$name" || return 0
        auth=$(tui_q '.auth')
        pw_state=$(tui_q '.password // empty')
        issues=$(tui_q '(.issues // []) | join(", ")')
        _tui_head "Нода: $name"
        box_line " Адрес: $(tui_q '"\(.ip):\(.port)"')"
        box_line " Пользователь: $(tui_q '.user')"
        if [[ "$auth" == password ]]; then
            box_line " Вход: по паролю"
            if [[ "$pw_state" == ok ]]; then
                box_line " Пароль SSH: сохранён"
            else
                box_line " Пароль SSH: нет" " Пароль SSH: ${YELLOW}нет${NC}"
            fi
        else
            box_line " Вход: по ключу"
        fi
        box_line " Тег: $(tui_q '.tag // ""')"
        if [[ -n "$issues" ]]; then
            box_line " Требует настройки: $issues" " ${YELLOW}Требует настройки: ${issues}${NC}"
        fi
        box_line " Группы: $(tui_q '.groups | if length == 0 then "нет" else join(", ") end')"
        box_line " Клиентов: $(tui_q '.clients')"
        box_mid
        menu_item o "Меню сервера" CYAN
        menu_item t "Telegram Proxy на ноде" CYAN
        menu_item p "Подключения ноды" CYAN
        menu_item a "Клиенты AmneziaWG" CYAN
        menu_item k "Проверить подключение" CYAN
        box_mid
        menu_item u "Загрузить скрипты принудительно" YELLOW
        menu_item h "Усилить защиту SSH" YELLOW
        menu_item r "Переименовать" YELLOW
        menu_item e "Тег" YELLOW
        [[ "$auth" != password ]] || menu_item w "Пароль SSH" YELLOW
        menu_item l "Псевдонимы подключений" YELLOW
        menu_item d "Удалить ноду" RED
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            o|O) _tui_node_try "$name" node shell --name "$name" || true ;;
            t|T) _tui_node_telegram_menu "$name" ;;
            p|P) tui_conn_node "$name" ;;
            a|A) tui_awg_node "$name" ;;
            k|K) _tui_node_try "$name" node check --name "$name" || true ;;
            u|U)
                _tui_node_confirmed "$name" "Принудительная загрузка скриптов" "Загрузить скрипты?" \
                    node upload-scripts --name "$name" --force || true
                ;;
            h|H) tui_node_harden "$name" ;;
            r|R)
                _tui_ask "Новое имя ноды" || return 0
                if [[ -n "$TUI_ANSWER" ]] && tui_call node rename --name "$name" --new-name "$TUI_ANSWER"; then
                    name=$(tui_q '.name')
                fi
                ;;
            e|E)
                _tui_ask "Тег" || return 0
                tui_call node tag --name "$name" --tag "$TUI_ANSWER" || true
                ;;
            w|W)
                if [[ "$auth" != password ]]; then
                    warn "Неверный выбор."
                    continue
                fi
                IFS= read -rsp "  Пароль SSH (Enter — отмена): " pw || { echo ""; return 0; }
                echo ""
                pw="${pw%$'\r'}"
                [[ -n "$pw" ]] || continue
                tui_secret password "$pw"
                pw=""
                tui_call node password --name "$name" || true
                tui_secrets_clear
                ;;
            l|L) tui_node_aliases "$name" ;;
            d|D)
                _tui_list_into '.delete_options[].label'; labels=("${TUI_LIST[@]}")
                (( ${#labels[@]} > 0 )) || { warn "Нет доступных вариантов удаления."; continue; }
                MENU_SELECT_EMPTY="Нет вариантов удаления"
                menu_select "Объём удаления ноды" "Выберите объём" "${labels[@]}" || continue
                scope=$(tui_q ".delete_options[$((MENU_SELECT_INDEX - 1))].scope")
                if [[ "$(tui_q ".delete_options[$((MENU_SELECT_INDEX - 1))].revoke_key")" == true ]]; then
                    _tui_node_confirmed "$name" "Удаление ноды" "Удалить ноду в выбранном объёме?" \
                        node delete --name "$name" --scope "$scope" --revoke-key && return 0
                else
                    _tui_node_confirmed "$name" "Удаление ноды" "Удалить ноду в выбранном объёме?" \
                        node delete --name "$name" --scope "$scope" && return 0
                fi
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

# ─── Добавление ──────────────────────────────────────────────────────────────

tui_node_add() {
    local name ip port user auth tag pw="" new_pw fp host rc defer=false
    local -a mode args
    _tui_ask "Название [vps-1]" || return 0
    name="${TUI_ANSWER:-vps-1}"
    _tui_ask "IP" || return 0
    ip="$TUI_ANSWER"
    if [[ -z "$ip" ]]; then
        warn "IP не указан."
        return 0
    fi
    while true; do
        _tui_ask "SSH-порт [22]" || return 0
        port="${TUI_ANSWER:-22}"
        if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
            break
        fi
        warn "Порт должен быть числом от 1 до 65535."
    done
    _tui_ask "Логин [root]" || return 0
    user="${TUI_ANSWER:-root}"
    menu_select "Способ входа" "Выберите способ входа" "SSH-ключ" "Пароль" || return 0
    if [[ "$MENU_SELECT_INDEX" == 2 ]]; then
        auth=password
        while true; do
            IFS= read -rsp "  Пароль: " pw || { echo ""; return 0; }
            echo ""
            pw="${pw%$'\r'}"
            [[ -n "$pw" ]] && break
            warn "Пароль не может быть пустым."
        done
    else
        auth=key
    fi
    while true; do
        _tui_ask "Тег" || { pw=""; return 0; }
        tag="$TUI_ANSWER"
        [[ -n "$tag" ]] && break
        warn "Тег не может быть пустым."
    done
    mode=(--accept-new-host-key)
    while true; do
        args=(node add --name "$name" --ip "$ip" --port "$port" --user "$user" --auth "$auth" --tag "$tag" "${mode[@]}")
        [[ "$defer" != true ]] || args+=(--defer-ssh-setup)
        rc=0
        if [[ "$auth" == password ]]; then tui_secret password "$pw"; fi
        if [[ "${mode[0]}" == --replace-host-key ]]; then
            # Замена ключа ноды — по плану команды (прежние и новый отпечатки).
            tui_run_confirmed "Ключ сервера изменился" "Обновить ключ ноды?" "${args[@]}" || rc=1
        else
            tui_call "${args[@]}" || rc=1
        fi
        tui_secrets_clear
        if (( rc == 0 )); then
            if [[ "$(tui_q '.needs_setup')" == true ]]; then
                warn "Нода сохранена, но требует SSH-настройки: раздел n → h."
            fi
            pw=""
            return 0
        fi
        case "$TUI_CODE" in
            host_key_changed)
                fp=$(tui_eq '.fingerprints[0] // empty')
                if [[ -z "$fp" ]]; then
                    pw=""
                    return 0
                fi
                mode=(--replace-host-key "$fp")
                ;;
            remote_failed)
                host=$(tui_eq '.hint // empty')
                [[ -z "$host" ]] || info "Подсказка: $host"
                if ! confirm_yn "Повторить попытку?" Y; then
                    pw=""
                    return 0
                fi
                if [[ "$auth" == password ]]; then
                    IFS= read -rsp "  Новый пароль (Enter — прежний): " new_pw || { echo ""; pw=""; return 0; }
                    echo ""
                    new_pw="${new_pw%$'\r'}"
                    [[ -z "$new_pw" ]] || pw="$new_pw"
                    new_pw=""
                fi
                ;;
            onboarding_failed)
                if ! menu_select "Не удалось настроить переносимый SSH-ключ" "Выберите действие" \
                    "Повторить" "Сохранить ноду и настроить позже"; then
                    pw=""
                    return 0
                fi
                [[ "$MENU_SELECT_INDEX" != 2 ]] || defer=true
                ;;
            *)
                pw=""
                return 0
                ;;
        esac
    done
}

# ─── Усиление SSH ────────────────────────────────────────────────────────────

tui_node_harden() {
    local name="$1" port="" p token changed retry rc line
    local -a args plan
    while true; do
        args=(node harden --name "$name")
        [[ -z "$port" ]] || args+=(--port "$port")
        tui_call "${args[@]}" && return 0
        case "$TUI_CODE" in
            confirmation_required) ;;
            invalid|port_in_use)
                _tui_ask "SSH-порт (Enter — случайный свободный)" || return 0
                port="$TUI_ANSWER"
                continue
                ;;
            *)
                rc=0
                tui_handle_node_codes "$name" || rc=$?
                (( rc == 2 )) && continue
                return 0
                ;;
        esac
        if [[ -z "$port" ]]; then
            # План без --port содержит случайный порт: подтверждается только план,
            # запрошенный с явным --port (иначе токен не совпадёт).
            p=$(tui_eq '.port // empty')
            _tui_ask "SSH-порт [Enter = $p]" || return 0
            port="${TUI_ANSWER:-$p}"
            [[ -n "$port" ]] || return 0
            continue
        fi
        changed=0
        retry=0
        while true; do
            token=$(tui_eq '.plan_token // empty')
            plan=()
            while IFS= read -r line; do plan+=("$line"); done < <(tui_eq '.plan[]?')
            review_frame "Усиление защиты SSH" "${plan[@]}"
            if ! confirm_yn "Усилить защиту SSH?" N; then
                info "Отменено."
                return 0
            fi
            tui_call node harden --name "$name" --port "$port" --yes --plan-token "$token" && return 0
            case "$TUI_CODE" in
                plan_changed)
                    changed=$((changed + 1))
                    (( changed <= 2 )) || return 0
                    warn "План изменился. Проверьте его ещё раз."
                    p=$(tui_eq '.port // empty')
                    [[ -z "$p" ]] || port="$p"
                    ;;
                hardening_failed)
                    if [[ "$(tui_eq '.console_required // false')" == true ]]; then
                        warn "Проверьте доступ через консоль провайдера."
                    fi
                    return 0
                    ;;
                *)
                    rc=0
                    tui_handle_node_codes "$name" || rc=$?
                    (( rc == 2 )) || return 0
                    retry=1
                    break
                    ;;
            esac
        done
        (( retry == 1 )) || return 0
    done
}

# ─── Отложенная SSH-настройка ────────────────────────────────────────────────

tui_node_setup_ssh() {
    local provision="" on_failure="" names line
    local -a args
    while true; do
        args=(node setup-ssh)
        [[ -z "$provision" ]] || args+=(--provision-keys "$provision")
        [[ -z "$on_failure" ]] || args+=(--on-failure "$on_failure")
        if tui_run_confirmed "Завершение SSH-настройки" "Выполнить?" "${args[@]}"; then
            break
        fi
        case "$TUI_CODE" in
            key_provisioning_required)
                names=$(tui_eq '(.nodes // []) | join(", ")')
                review_frame "Переносимый SSH-ключ" "Ноды: $names"
                if confirm_yn "Создать переносимый SSH-ключ для этих нод?" N; then
                    provision=yes
                else
                    provision=no
                fi
                ;;
            onboarding_failed)
                menu_select "Не удалось настроить переносимый SSH-ключ" "Выберите действие" \
                    "Повторить" "Отложить проблемные ноды" || return 0
                [[ "$MENU_SELECT_INDEX" != 2 ]] || on_failure=defer
                ;;
            *) return 0 ;;
        esac
    done
    if [[ "$(tui_q '.ready')" == true ]]; then
        success "SSH-настройка завершена."
    else
        while IFS= read -r line; do
            printf '  %b[!]%b %s\n' "$YELLOW" "$NC" "$line"
        done < <(tui_q '(.deferred // [])[] | "Отложено: \(.name) — \(.issue)"')
    fi
}

# ─── Псевдонимы ──────────────────────────────────────────────────────────────

tui_node_aliases() {
    local name="$1" i count proxy alias reply
    local -a proxies aliases sets unsets
    _tui_node_try "$name" node aliases --name "$name" || return 0
    _tui_list_into '.[].proxy'; proxies=("${TUI_LIST[@]}")
    _tui_list_into '.[] | .alias // ""'; aliases=("${TUI_LIST[@]}")
    count=${#proxies[@]}
    if (( count == 0 )); then
        info "Подключения на ноде не найдены."
        return 0
    fi
    sets=()
    unsets=()
    for ((i = 0; i < count; i++)); do
        proxy="${proxies[$i]}"
        alias="${aliases[$i]}"
        IFS= read -rp "  $proxy [$alias]: " reply || return 0
        reply="${reply%$'\r'}"
        if [[ -z "$reply" ]]; then
            continue
        elif [[ "$reply" == - ]]; then
            [[ -z "$alias" ]] || unsets+=(--unset "$proxy")
        elif [[ "$reply" != "$alias" ]]; then
            sets+=(--set "$proxy=$reply")
        fi
    done
    if (( ${#sets[@]} + ${#unsets[@]} == 0 )); then
        info "Изменений нет."
        return 0
    fi
    tui_call node aliases --name "$name" "${sets[@]}" "${unsets[@]}" || true
}

# ─── Подключения ─────────────────────────────────────────────────────────────

# conn sync меняет конфигурацию (убирает устаревшие назначения) и ходит по SSH:
# только при входе на экран и по s. Перерисовка — conn list (только чтение)
# с обнаруженными подключениями и доступностью из последней синхронизации.
tui_connections() {
    local count i sync=1 line name status synced=""
    local -a names
    while true; do
        if (( sync == 1 )); then
            tui_call conn sync || true
            [[ "$TUI_DATA" != null ]] || return 0
            synced="$TUI_DATA"
            sync=0
        fi
        tui_call conn list || return 0
        TUI_DATA=$(tui_q -c --argjson s "$synced" '{nodes: map(.node as $n
            | (first($s.nodes[]? | select(.name == $n)) // {}) as $c
            | {name: $n, status: $c.status, discovered: $c.discovered, groups})}')
        _tui_list_into '.nodes[].name'; names=("${TUI_LIST[@]}")
        count=${#names[@]}
        _tui_head "Подключения нод"
        if (( count == 0 )); then
            box_line " Нет нод" " ${DIM}Нет нод${NC}"
        else
            for ((i = 0; i < count; i++)); do
                name="${names[$i]}"
                status=$(tui_q --arg n "$name" '.nodes[] | select(.name == $n) | .status')
                if [[ "$status" == unreachable ]]; then
                    box_line " $name  недоступна" " $name  ${YELLOW}недоступна${NC}"
                    continue
                fi
                box_line " $name"
                while IFS=$'\t' read -r line status; do
                    case "$status" in
                        green)  box_line "   $line" "   ${GREEN}${line}${NC}" ;;
                        yellow) box_line "   $line" "   ${YELLOW}${line}${NC}" ;;
                        *)      box_line "   $line" "   ${DIM}${line}${NC}" ;;
                    esac
                done < <(tui_q --arg n "$name" '
                    .nodes[] | select(.name == $n) | (.discovered | if . == null then null else length end) as $t
                    | .groups[]? | (.proxies | length) as $a
                    | ["\(.name): \($a)/\(if $t == null then "?" else $t end)",
                       (if $t == null or $t == 0 then "dim" elif $a >= $t then "green" else "yellow" end)] | @tsv')
            done
        fi
        box_mid
        for ((i = 0; i < count; i++)); do
            menu_item "$((i + 1))" "${names[$i]}" CYAN
        done
        (( count == 0 )) || box_mid
        menu_item s "Синхронизировать с нодами" YELLOW
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            s|S) sync=1 ;;
            0) return 0 ;;
            *)
                if menu_index_valid "$TUI_CHOICE" "$count"; then
                    tui_conn_node "${names[$((TUI_CHOICE - 1))]}"
                else
                    warn "Неверный выбор."
                fi
                ;;
        esac
    done
}

tui_conn_node() {
    local name="$1" i p g sync=1 synced=""
    local -a proxies labels groups gflags args
    while true; do
        if (( sync == 1 )); then
            _tui_node_try "$name" conn sync --node "$name" || return 0
            synced="$TUI_DATA"
            sync=0
        fi
        tui_call conn list --node "$name" || return 0
        TUI_DATA=$(tui_q -c --argjson s "$synced" --arg n "$name" '{nodes: [.[] | select(.node == $n)
            | {name: .node, groups,
               discovered: ((first($s.nodes[]? | select(.name == $n)) // {}).discovered)}]}')
        _tui_list_into '.nodes[0].discovered[]?'; proxies=("${TUI_LIST[@]}")
        _tui_list_into '.nodes[0] as $n | ($n.discovered // [])[] | . as $p
            | "\(.)  [\([$n.groups[]? | select(.proxies | index($p) != null) | .name] | join(", "))]"'
        labels=("${TUI_LIST[@]}")
        _tui_head "Подключения ноды: $name"
        if (( ${#proxies[@]} == 0 )); then
            box_line " Подключения не найдены" " ${DIM}Подключения не найдены${NC}"
        else
            for p in "${labels[@]}"; do box_line " $p"; done
        fi
        box_mid
        menu_item b "Назначить подключения группам" YELLOW
        menu_item l "Псевдонимы подключений" YELLOW
        menu_item s "Синхронизировать с нодой" YELLOW
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            b|B)
                _TG_LABELS=("${proxies[@]}")
                _tui_list_into '.nodes[0] as $n | ($n.discovered // [])[] | . as $p
                    | if ([$n.groups[]? | select(.proxies | index($p) != null)] | length) > 0 then 1 else 0 end'
                _TG_FLAGS=("${TUI_LIST[@]}")
                _tui_toggle "Подключения для групп" || continue
                if (( ${#TUI_PICKED_IDX[@]} == 0 )); then
                    warn "Ничего не выбрано."
                    continue
                fi
                args=()
                for i in "${TUI_PICKED_IDX[@]}"; do args+=(--proxy "${proxies[$i]}"); done
                tui_call group list || continue
                _tui_list_into '.[].name'; groups=("${TUI_LIST[@]}")
                _TG_LABELS=("${groups[@]}")
                _TG_FLAGS=()
                for _ in "${groups[@]}"; do _TG_FLAGS+=(0); done
                _tui_toggle "Группы для подключений" || continue
                if (( ${#TUI_PICKED_IDX[@]} == 0 )); then
                    warn "Ничего не выбрано."
                    continue
                fi
                gflags=()
                for i in "${TUI_PICKED_IDX[@]}"; do gflags+=(--group "${groups[$i]}"); done
                tui_call conn set --node "$name" "${gflags[@]}" "${args[@]}" || true
                ;;
            l|L) tui_node_aliases "$name" ;;
            s|S) sync=1 ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

# ─── AmneziaWG ───────────────────────────────────────────────────────────────

tui_awg() {
    local count i
    local -a names labels
    while true; do
        tui_call node list || return 0
        _tui_list_into '.[].name'; names=("${TUI_LIST[@]}")
        _tui_list_into '.[] | "\(.name)  \(.ip):\(.port)"'; labels=("${TUI_LIST[@]}")
        count=${#names[@]}
        _tui_head "AmneziaWG"
        if (( count == 0 )); then
            box_line " Нет нод" " ${DIM}Нет нод${NC}"
        else
            for ((i = 0; i < count; i++)); do
                menu_item "$((i + 1))" "${labels[$i]}" CYAN
            done
        fi
        box_mid
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt "Выберите ноду или действие" || return 0
        case "$TUI_CHOICE" in
            0) return 0 ;;
            *)
                if menu_index_valid "$TUI_CHOICE" "$count"; then
                    tui_awg_node "${names[$((TUI_CHOICE - 1))]}"
                else
                    warn "Неверный выбор."
                fi
                ;;
        esac
    done
}

tui_awg_node() {
    local name="$1" installed i state
    local -a peers
    while true; do
        _tui_node_try "$name" awg status --node "$name" || return 0
        installed=$(tui_q '.installed')
        _tui_head "AmneziaWG: $name"
        if [[ "$installed" != true ]]; then
            box_line " AmneziaWG на ноде не установлен" " ${DIM}AmneziaWG на ноде не установлен${NC}"
        else
            _tui_list_into '.peers[] | "\(.name)\t\(.status)"'
            peers=("${TUI_LIST[@]}")
            if (( ${#peers[@]} == 0 )); then
                box_line " Нет клиентов" " ${DIM}Нет клиентов${NC}"
            fi
            for i in "${peers[@]}"; do
                state="${i#*$'\t'}"
                case "$state" in
                    used)    box_line " ${i%%$'\t'*}" " ${GREEN}${i%%$'\t'*}${NC}" ;;
                    orphan)  box_line " ${i%%$'\t'*}  не используется" " ${YELLOW}${i%%$'\t'*}  не используется${NC}" ;;
                    *)       box_line " ${i%%$'\t'*}  не создан" " ${DIM}${i%%$'\t'*}  не создан${NC}" ;;
                esac
            done
        fi
        box_mid
        menu_item r "Обновить" CYAN
        if [[ "$installed" == true ]]; then
            menu_item c "Создать недостающих" GREEN
            menu_item d "Удалить клиента" RED
            menu_item x "Удалить неиспользуемых" RED
        fi
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            r|R) ;;
            c|C)
                if [[ "$installed" == true ]]; then
                    _tui_node_try "$name" awg sync --node "$name" || true
                else
                    warn "Неверный выбор."
                fi
                ;;
            d|D)
                if [[ "$installed" != true ]]; then
                    warn "Неверный выбор."
                    continue
                fi
                _tui_list_into '.peers[] | select(.status != "missing") | .name'
                peers=("${TUI_LIST[@]}")
                MENU_SELECT_EMPTY="Нет клиентов AmneziaWG на ноде"
                menu_select "Удаление клиента AmneziaWG" "Выберите клиента" "${peers[@]}" || continue
                _tui_node_confirmed "$name" "Удаление клиента AmneziaWG" "Удалить?" \
                    awg remove --node "$name" --peer "${peers[$((MENU_SELECT_INDEX - 1))]}" || true
                ;;
            x|X)
                if [[ "$installed" == true ]]; then
                    _tui_node_confirmed "$name" "Удаление неиспользуемых клиентов AmneziaWG" "Удалить?" \
                        awg remove --node "$name" --orphans || true
                else
                    warn "Неверный выбор."
                fi
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

# ─── Telegram ────────────────────────────────────────────────────────────────

# Таблица «нода  статус  причина» по results из TUI_DATA (в том числе при ошибках).
_tui_telegram_table() {
    local node status reason color
    [[ "$(tui_q '(.results // []) | length')" -gt 0 ]] 2> /dev/null || return 0
    _tui_head "Результат Telegram Proxy"
    box_line " нода  статус  причина"
    box_mid
    while IFS=$'\t' read -r node status reason; do
        case "$status" in
            ok)            color="$GREEN";  status="готово" ;;
            not_installed) color="$YELLOW"; status="не установлено" ;;
            partial)       color="$YELLOW"; status="частично" ;;
            *)             color="$RED";    status="ошибка" ;;
        esac
        box_line " $node  $status  $reason" " $node  ${color}${status}${NC}  $reason"
    done < <(tui_q '.results[] | [.node, .status, (.reason // "")] | @tsv')
    box_bot
}

# _tui_telegram_batch HEADER TITLE ARGV… — выбор нод, подтверждение, таблица.
_tui_telegram_batch() {
    local header="$1" title="$2" n
    local -a args
    shift 2
    tui_toggle_nodes "$header" || return 0
    if (( ${#TUI_PICKED[@]} == 0 )); then
        warn "Ничего не выбрано."
        return 0
    fi
    args=("$@")
    for n in "${TUI_PICKED[@]}"; do args+=(--node "$n"); done
    tui_run_confirmed "$title" "Выполнить?" "${args[@]}" || true
    _tui_telegram_table
}

tui_telegram() {
    local component
    while true; do
        _tui_head "Telegram Proxy"
        menu_item o "Управление одной нодой" CYAN
        menu_item s "Общий статус нод" CYAN
        box_mid
        menu_item i "Включить MTProto Proxy" GREEN
        menu_item p "Обновить IP-адрес MTProto" YELLOW
        menu_item w "Обновить Web Proxy" YELLOW
        menu_item r "Перезапустить Web Proxy" YELLOW
        menu_item b "Перезапустить службу MTProxy" YELLOW
        menu_item d "Отключить способ доступа" RED
        menu_item x "Отключить Telegram Proxy полностью" RED
        menu_item 0 "Назад" NC
        box_bot
        _tui_prompt || return 0
        case "$TUI_CHOICE" in
            o|O) tui_pick_node "Управление Telegram Proxy" && _tui_node_telegram_menu "$TUI_PICK" ;;
            s|S)
                tui_call telegram status --all || true
                _tui_telegram_table
                ;;
            i|I) _tui_telegram_batch "Включение MTProto Proxy" "Включение MTProto Proxy" telegram install ;;
            p|P) _tui_telegram_batch "Обновление IP-адреса MTProto" "Обновление IP-адреса MTProto" telegram refresh-ip ;;
            w|W) _tui_telegram_batch "Обновление Web Proxy" "Обновление Web Proxy" telegram web-update ;;
            r|R) _tui_telegram_batch "Перезапуск Web Proxy" "Перезапуск Web Proxy" telegram web-restart ;;
            b|B) _tui_telegram_batch "Перезапуск службы MTProxy" "Перезапуск службы MTProxy" telegram backend-restart ;;
            d|D)
                MENU_SELECT_EMPTY="Нет способов доступа"
                menu_select "Отключение способа доступа" "Выберите способ" "Web Proxy" "MTProto Proxy" || continue
                if [[ "$MENU_SELECT_INDEX" == 1 ]]; then component=web; else component=mtproto; fi
                _tui_telegram_batch "Отключение способа доступа" "Отключение способа доступа" \
                    telegram remove --component "$component"
                ;;
            x|X) _tui_telegram_batch "Отключение Telegram Proxy" "Полное отключение Telegram Proxy" telegram remove-all ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}
