#!/bin/bash
# ─── Cascade / Цепочка серверов ─────────────────────────────────────────────
# Каждый каскад — listener + exit-прокси + outbound группа.
# Маркеры: # --- cascade:<name> --- / # --- /cascade:<name> ---

cascade_menu() {
    while true; do
        echo ""
        box_top
        box_center "Каскады"
        box_mid

        local cascades=() line c block srv srv_port _sl _sl_port _sl_label _info
        while IFS= read -r line; do
            cascades+=("$line")
        done < <(grep '^# --- cascade:' /etc/mihomo/config.yaml 2>/dev/null | sed 's/# --- cascade://;s/ ---//')
        if [[ ${#cascades[@]} -gt 0 ]]; then
            for c in "${cascades[@]}"; do
                block=$(sed -n "/^# --- cascade:${c} ---/,/^# --- \/cascade:${c} ---/p" /etc/mihomo/config.yaml)
                if [[ "$block" == *"# type: iptables-dnat"* ]]; then
                    srv=$(printf '%s\n' "$block" | awk '/^# remote:/{print $3; exit}')
                    srv_port=$(printf '%s\n' "$block" | awk '/^# remote-port:/{print $3; exit}')
                    _sl_port=$(printf '%s\n' "$block" | awk '/^# local-port:/{print $3; exit}')
                    _sl="DNAT"
                    _info=" ${c}: DNAT :${_sl_port} → ${srv}:${srv_port}"
                else
                    srv=$(printf '%s\n' "$block" | awk '/    server:/{print $2; exit}')
                    srv_port=$(printf '%s\n' "$block" | awk '/    port:/{print $2; exit}')
                    _sl=$(printf '%s\n' "$block" | awk '/^# shared-listener:/{print $3; exit}')
                    _sl_port=$(awk '/# --- '"$_sl"' ---/{f=1} f && /port:/{print $2; exit}' /etc/mihomo/config.yaml)
                    case "$_sl" in
                        hy2) _sl_label="Hysteria2" ;;
                        vless-tcp) _sl_label="VLESS TCP" ;;
                        vless-xhttp) _sl_label="VLESS xHTTP" ;;
                        vless-grpc) _sl_label="VLESS gRPC" ;;
                        *) _sl_label="$_sl" ;;
                    esac
                    _info=" ${c}: ${_sl_label}:${_sl_port} → ${srv}:${srv_port}"
                fi
                if [[ -n "$srv" && -n "$srv_port" && -n "$_sl" && -n "$_sl_port" ]]; then
                    box_line "$_info"
                else
                    box_line " ${c}: неполная конфигурация" " ${YELLOW}${c}: неполная конфигурация${NC}"
                fi
            done
        else
            box_line " Нет каскадов" " ${DIM}Нет каскадов${NC}"
        fi
        box_mid
        menu_item 1 "Добавить каскад" GREEN
        menu_item 2 "Удалить каскад" RED
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        local CASCADE_CHOICE
        if ! IFS= read -rp "  Выберите действие: " CASCADE_CHOICE; then
            return 0
        fi
        CASCADE_CHOICE="${CASCADE_CHOICE%$'\r'}"
        case "$CASCADE_CHOICE" in
            1)
                install_cascade || {
                    [[ "${CASCADE_CANCELLED:-false}" == true ]] ||
                        warn "Настройка каскада завершилась ошибкой. Повторите действие из меню."
                }
                ;;
            2)
                remove_cascade_interactive || {
                    [[ "${CASCADE_CANCELLED:-false}" == true ]] ||
                        warn "Удаление каскада завершилось ошибкой. Повторите действие из меню."
                }
                ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

install_cascade() {
    CASCADE_CANCELLED=false
    echo ""

    if [[ ! -f /etc/mihomo/config.yaml ]]; then
        warn "Mihomo не установлен. Сначала выберите «b) Базовая установка»."
        return 1
    fi

    IFS= read -rp "  Имя каскада: " CASCADE_NAME || { CASCADE_CANCELLED=true; return 1; }
    CASCADE_NAME="${CASCADE_NAME%$'\r'}"
    [[ -z "$CASCADE_NAME" ]] && { warn "Имя не указано"; return 1; }
    if ! [[ "$CASCADE_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        warn "Имя может содержать только буквы, цифры, точку, - и _"
        return 1
    fi

    if grep -q "^# --- cascade:${CASCADE_NAME} ---" /etc/mihomo/config.yaml; then
        warn "Каскад «$CASCADE_NAME» уже существует — после ввода параметров он будет заменён."
    fi

    _install_proxy_cascade "$CASCADE_NAME"
}

# ═══════════════════════════════════════════════════════════════════════════════
# iptables DNAT каскад
# ═══════════════════════════════════════════════════════════════════════════════

_show_current_listeners() {
    [[ ! -f /etc/mihomo/config.yaml ]] && return
    local listeners
    listeners=$(awk '/^  - name:/{name=$3; gsub(/"/, "", name)} /^    port:/{print name, $2}' /etc/mihomo/config.yaml)
    if [[ -n "$listeners" ]]; then
        echo ""
        echo -e "  ${DIM}Текущие входные подключения:${NC}"
        while read -r lname lport; do
            echo -e "    ${DIM}:${lport}  ${lname}${NC}"
        done <<< "$listeners"
    fi
}

_install_dnat_cascade() {
    local cname="$1"

    echo ""
    echo -e "  ${CYAN}iptables DNAT — прозрачный проброс пакетов${NC}"
    echo -e "  ${DIM}Клиентский трафик уже зашифрован (Reality/Hysteria2), дополнительное шифрование не нужно.${NC}"
    echo ""

    local REMOTE_SERVER="" REMOTE_PORT="" EXIT_URI=""

    local _input_mode
    while true; do
        echo ""
        box_top
        box_center "Данные выходной ноды"
        box_mid
        menu_item 1 "Вставить URI (vless://, hy2://)" CYAN
        menu_item 2 "Ввести вручную" CYAN
        menu_item 0 "Отмена" NC
        box_bot
        echo ""
        IFS= read -rp "  Выберите способ ввода [Enter = 1]: " _input_mode || return 1
        _input_mode="${_input_mode%$'\r'}"
        _input_mode="${_input_mode:-1}"
        case "$_input_mode" in
            1|2) break ;;
            0) return 1 ;;
            *) warn "Неверный выбор." ;;
        esac
    done

    case "$_input_mode" in
        1)
            IFS= read -rp "  URI выходной ноды: " EXIT_URI || return 1
            EXIT_URI="${EXIT_URI%$'\r'}"
            if [[ -z "$EXIT_URI" ]]; then
                warn "URI не указан"; return
            fi
            if [[ "$EXIT_URI" != vless://* && "$EXIT_URI" != hy2://* && "$EXIT_URI" != hysteria2://* ]]; then
                warn "Неизвестный протокол. Поддерживаются: vless://, hy2://, hysteria2://"
                return
            fi
            _parse_server_port_from_uri "$EXIT_URI"
            REMOTE_SERVER="$URI_SERVER"
            REMOTE_PORT="$URI_PORT"
            info "Сервер: $REMOTE_SERVER, порт: $REMOTE_PORT"
            ;;
        2)
            IFS= read -rp "  IP или домен выходной ноды: " REMOTE_SERVER || return 1
            REMOTE_SERVER="${REMOTE_SERVER%$'\r'}"
            [[ -z "$REMOTE_SERVER" ]] && { warn "Сервер не указан"; return; }
            IFS= read -rp "  Порт выходной ноды: " REMOTE_PORT || return 1
            REMOTE_PORT="${REMOTE_PORT%$'\r'}"
            [[ -z "$REMOTE_PORT" ]] && { warn "Порт не указан"; return; }
            echo ""
            IFS= read -rp "  URI выходной ноды [Enter = пропустить]: " EXIT_URI || return 1
            EXIT_URI="${EXIT_URI%$'\r'}"
            ;;
        *)
            warn "Неверный выбор."; return ;;
    esac

    local DEFAULT_PORT="$REMOTE_PORT"
    _show_current_listeners
    echo ""
    echo -e "  ${DIM}Клиенты будут подключаться к этому серверу на этот порт.${NC}"
    echo -e "  ${DIM}Обычно совпадает с портом exit-ноды ($REMOTE_PORT).${NC}"
    echo -e "  ${DIM}Если $REMOTE_PORT уже занят — укажите свободный.${NC}"
    IFS= read -rp "  Порт для клиентов [Enter = $DEFAULT_PORT]: " LOCAL_PORT || return 1
    LOCAL_PORT="${LOCAL_PORT%$'\r'}"
    LOCAL_PORT="${LOCAL_PORT:-$DEFAULT_PORT}"
    while ! is_port_free "$LOCAL_PORT"; do
        warn "Порт $LOCAL_PORT занят."
        IFS= read -rp "  Другой порт: " LOCAL_PORT || return 1
        LOCAL_PORT="${LOCAL_PORT%$'\r'}"
        [[ -z "$LOCAL_PORT" ]] && { warn "Порт не указан"; return; }
    done

    echo ""
    info "Каскад:    $cname (iptables DNAT)"
    info "Exit:      $REMOTE_SERVER:$REMOTE_PORT"
    info "Локально:  :$LOCAL_PORT"
    echo ""
    confirm_yn "Всё верно?" || { info "Отменено."; return; }

    # Применяем iptables правила
    _apply_dnat_rules "$cname" "$REMOTE_SERVER" "$REMOTE_PORT" "$LOCAL_PORT"
    success "iptables DNAT правила применены"

    # Сохраняем правила
    _persist_dnat_rules
    success "Правила сохранены"

    # UFW
    ufw allow "${LOCAL_PORT}/tcp" > /dev/null 2>&1
    ufw allow "${LOCAL_PORT}/udp" > /dev/null 2>&1
    success "Порт $LOCAL_PORT открыт"

    # Маркер в config.yaml (comment-only блок)
    cat > /tmp/cascade_dnat_marker.yaml << EOF
# --- cascade:${cname} ---
# type: iptables-dnat
# remote: ${REMOTE_SERVER}
# remote-port: ${REMOTE_PORT}
# local-port: ${LOCAL_PORT}
# --- /cascade:${cname} ---
EOF

    awk '
        /^# --- proxies ---/{
            print
            while ((getline line < "/tmp/cascade_dnat_marker.yaml") > 0) print line
            next
        }
        {print}
    ' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
    rm /tmp/cascade_dnat_marker.yaml

    # Клиентский конфиг
    local SERVER_ADDR
    SERVER_ADDR=$(grep '^Server:' /etc/mihomo/client-config.txt 2>/dev/null | head -1 | awk '{print $2}')
    [[ -z "$SERVER_ADDR" ]] && SERVER_ADDR=$(curl -4 -s --max-time 5 ifconfig.me)

    local client_uri=""
    if [[ -n "$EXIT_URI" ]]; then
        # Заменяем server:port в URI на адрес текущего сервера
        client_uri=$(echo "$EXIT_URI" | sed -E "s/@[^:@]+:[0-9]+/@${SERVER_ADDR}:${LOCAL_PORT}/")
    fi

    cat >> /etc/mihomo/client-config.txt << EOF

--- Cascade: ${cname} ---
Type: iptables-dnat
Local port: $LOCAL_PORT
Remote: $REMOTE_SERVER:$REMOTE_PORT
$(  [[ -n "$client_uri" ]] && printf "URI: %s\n" "$client_uri" )
Используйте конфиг exit-ноды, заменив адрес сервера на ${SERVER_ADDR}:${LOCAL_PORT}
--- /Cascade: ${cname} ---
EOF

    echo ""
    success_box "Каскад $cname настроен! (DNAT)"
    echo ""
    echo -e "  :$LOCAL_PORT -> ${REMOTE_SERVER}:${REMOTE_PORT} (прямой проброс)"
    if [[ -n "$client_uri" ]]; then
        echo ""
        echo -e "  URI: ${CYAN}${client_uri}${NC}"
    fi
    echo ""
    echo -e "  ${DIM}Используйте конфиг exit-ноды, заменив адрес сервера на ${SERVER_ADDR}:${LOCAL_PORT}${NC}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# Прокси-каскад (shared user в существующем листенере)
# ═══════════════════════════════════════════════════════════════════════════════

_install_proxy_cascade() {
    local cname="$1"

    menu_select "Данные выходной ноды" "Выберите способ ввода" "Вставить URI" "Ввести вручную" || {
        CASCADE_CANCELLED=true
        return 1
    }
    local INPUT_METHOD="$MENU_SELECT_INDEX"

    local exit_proxy_yaml=""
    case "$INPUT_METHOD" in
        1)
            exit_proxy_yaml=$(_parse_proxy_uri "$cname")
            ;;
        2)
            menu_select "Протокол выходной ноды" "Выберите протокол" \
                "VLESS TCP (Reality)" "VLESS xHTTP" "VLESS gRPC" "Hysteria2" || {
                CASCADE_CANCELLED=true
                return 1
            }
            local EXIT_PROTO="$MENU_SELECT_INDEX"
            case "$EXIT_PROTO" in
                1) exit_proxy_yaml=$(_ask_exit_vless_tcp "$cname") ;;
                2) exit_proxy_yaml=$(_ask_exit_vless_xhttp "$cname") ;;
                3) exit_proxy_yaml=$(_ask_exit_vless_grpc "$cname") ;;
                4) exit_proxy_yaml=$(_ask_exit_hy2 "$cname") ;;
                *) warn "Неверный выбор."; return ;;
            esac
            ;;
        *) warn "Неверный выбор."; return ;;
    esac
    [[ -n "$exit_proxy_yaml" ]] || return 1

    # ── Входной протокол (выбор существующего листенера) ─────────────────────
    echo ""
    echo -e "  ${CYAN}Шаг 2/2: Входной протокол${NC}"
    echo ""

    local _avail_markers=() _avail_labels=() _avail_ports=()
    local _lport

    if grep -q '# --- vless-tcp ---' /etc/mihomo/config.yaml 2>/dev/null; then
        _lport=$(awk '/# --- vless-tcp ---/{f=1} f && /port:/{print $2; exit}' /etc/mihomo/config.yaml)
        _avail_markers+=("vless-tcp"); _avail_labels+=("VLESS TCP"); _avail_ports+=("$_lport")
    fi
    if grep -q '# --- vless-xhttp ---' /etc/mihomo/config.yaml 2>/dev/null; then
        _lport=$(awk '/# --- vless-xhttp ---/{f=1} f && /port:/{print $2; exit}' /etc/mihomo/config.yaml)
        _avail_markers+=("vless-xhttp"); _avail_labels+=("VLESS xHTTP"); _avail_ports+=("$_lport")
    fi
    if grep -q '# --- vless-grpc ---' /etc/mihomo/config.yaml 2>/dev/null; then
        _lport=$(awk '/# --- vless-grpc ---/{f=1} f && /port:/{print $2; exit}' /etc/mihomo/config.yaml)
        _avail_markers+=("vless-grpc"); _avail_labels+=("VLESS gRPC"); _avail_ports+=("$_lport")
    fi
    if grep -q '# --- hy2 ---' /etc/mihomo/config.yaml 2>/dev/null; then
        _lport=$(awk '/# --- hy2 ---/{f=1} f && /port:/{print $2; exit}' /etc/mihomo/config.yaml)
        _avail_markers+=("hy2"); _avail_labels+=("Hysteria2"); _avail_ports+=("$_lport")
    fi

    local _listener_labels=() i
    for i in "${!_avail_markers[@]}"; do
        _listener_labels+=("${_avail_labels[$i]} (:${_avail_ports[$i]})")
    done
    MENU_SELECT_EMPTY="Нет установленных протоколов"
    menu_select "Входной протокол каскада" "Выберите протокол" "${_listener_labels[@]}" || {
        CASCADE_CANCELLED=true
        return 1
    }
    local _listener_choice="$MENU_SELECT_INDEX"

    local _marker="${_avail_markers[$((_listener_choice - 1))]}"
    _attach_cascade_to_listener "$cname" "$_marker" "$exit_proxy_yaml"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Добавление каскадного пользователя в существующий листенер
# ═══════════════════════════════════════════════════════════════════════════════

# Проверяет есть ли cascade-user в листенере. Выводит имена каскадов.
# Возвращает 0 если есть, 1 если нет.
_check_cascade_users() {
    local marker="$1"
    local names
    names=$(sed -n "/^# --- ${marker} ---/,/^# --- \/${marker} ---/p" /etc/mihomo/config.yaml 2>/dev/null \
        | grep '# cascade-user:' | grep -v '/cascade-user:' | sed 's/.*# cascade-user://')
    if [[ -n "$names" ]]; then
        echo "$names"
        return 0
    fi
    return 1
}

_load_cascade_reality() {
    if [[ ! -f /etc/mihomo/reality.conf ]]; then
        warn "Сначала установите VLESS Reality — нужен домен и сертификат."
        return 1
    fi
    source /etc/mihomo/reality.conf
}

_get_server_addr() {
    local addr
    addr=$(grep '^Server:' /etc/mihomo/client-config.txt 2>/dev/null | head -1 | awk '{print $2}')
    [[ -z "$addr" ]] && addr=$(curl -4 -s --max-time 5 ifconfig.me)
    echo "$addr"
}

# Определить client-facing порт: 127.0.0.1 → за nginx → 443, иначе = listener port
_get_client_port() {
    local marker="$1"
    local listen_addr port
    listen_addr=$(sed -n "/^# --- ${marker} ---/,/^# --- \/${marker} ---/p" /etc/mihomo/config.yaml \
        | awk '/listen:/{print $2; exit}')
    port=$(sed -n "/^# --- ${marker} ---/,/^# --- \/${marker} ---/p" /etc/mihomo/config.yaml \
        | awk '/port:/{print $2; exit}')
    if [[ "$listen_addr" == "127.0.0.1" ]]; then
        echo "443"
    else
        echo "$port"
    fi
}

_load_xhttp_cascade_client_settings() {
    local config="${1:-/etc/mihomo/config.yaml}" server_addr="$2"
    XHTTP_CASCADE_PATH=$(_xhttp_listener_field path "$config")
    XHTTP_CASCADE_TOPOLOGY=$(_xhttp_listener_topology "$config") || return 1
    if [[ "$XHTTP_CASCADE_TOPOLOGY" == "nginx" ]]; then
        XHTTP_CASCADE_SNI="${SITE_NAME:-$server_addr}"
        XHTTP_CASCADE_PUBLIC_KEY=""
        XHTTP_CASCADE_SHORT_ID=""
    else
        XHTTP_CASCADE_SNI="$SNI_DOMAIN"
        XHTTP_CASCADE_PUBLIC_KEY="$PUBLIC_KEY"
        XHTTP_CASCADE_SHORT_ID="$SHORT_ID"
    fi
    [[ -n "$XHTTP_CASCADE_PATH" && -n "$XHTTP_CASCADE_SNI" ]]
}

_attach_cascade_to_listener() {
    local cname="$1" marker="$2" exit_proxy_yaml="$3"
    # marker: vless-tcp | vless-xhttp | vless-grpc | hy2

    local is_vless=true
    [[ "$marker" == "hy2" ]] && is_vless=false

    # ── Генерация credentials ───────────────────────────────────────────────
    local CASCADE_UUID="" CASCADE_PASS=""
    if $is_vless; then
        _load_cascade_reality || return 1
        CASCADE_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]') || return 1
        [[ -n "$CASCADE_UUID" ]] || return 1
    else
        CASCADE_PASS=$(openssl rand -hex 16) && [[ -n "$CASCADE_PASS" ]] || return 1
    fi

    local SERVER_ADDR
    SERVER_ADDR=$(_get_server_addr)
    local client_port
    client_port=$(_get_client_port "$marker")

    # ── Собираем данные для клиентского конфига ──────────────────────────────
    local client_uri="" client_yaml="" proto_label=""

    case "$marker" in
        vless-tcp)
            proto_label="VLESS TCP"
            client_uri=$(_build_vless_tcp_uri "$CASCADE_UUID" "$SERVER_ADDR" "$client_port" \
                "$SNI_DOMAIN" "$PUBLIC_KEY" "$SHORT_ID" "VLESS TCP ${cname}")
            client_yaml=$(_build_vless_tcp_client_yaml \
                "VLESS TCP ${cname}" "$SERVER_ADDR" "$client_port" \
                "$CASCADE_UUID" "$SNI_DOMAIN" "$PUBLIC_KEY" "$SHORT_ID")
            ;;
        vless-xhttp)
            proto_label="VLESS xHTTP"
            local xhttp_path xhttp_sni xhttp_pubkey xhttp_sid
            _load_xhttp_cascade_client_settings /etc/mihomo/config.yaml "$SERVER_ADDR" || {
                warn "Не удалось прочитать параметры входного подключения xHTTP."
                return 1
            }
            xhttp_path="$XHTTP_CASCADE_PATH"
            xhttp_sni="$XHTTP_CASCADE_SNI"
            xhttp_pubkey="$XHTTP_CASCADE_PUBLIC_KEY"
            xhttp_sid="$XHTTP_CASCADE_SHORT_ID"
            client_uri=$(_build_vless_xhttp_uri "$CASCADE_UUID" "$SERVER_ADDR" "$client_port" \
                "$xhttp_sni" "$xhttp_path" "$xhttp_pubkey" "$xhttp_sid" "VLESS xHTTP ${cname}")
            client_yaml=$(_build_vless_xhttp_client_yaml \
                "VLESS xHTTP ${cname}" "$SERVER_ADDR" "$client_port" \
                "$CASCADE_UUID" "$xhttp_sni" "$xhttp_path" "$xhttp_pubkey" "$xhttp_sid")
            ;;
        vless-grpc)
            proto_label="VLESS gRPC"
            local grpc_service
            grpc_service=$(sed -n "/^# --- vless-grpc ---/,/^# --- \/vless-grpc ---/p" /etc/mihomo/config.yaml \
                | awk '/grpc-service-name:/{gsub(/"/, "", $2); print $2; exit}')
            client_uri=$(_build_vless_grpc_uri "$CASCADE_UUID" "$SERVER_ADDR" "$client_port" \
                "$SNI_DOMAIN" "$grpc_service" "$PUBLIC_KEY" "$SHORT_ID" "VLESS gRPC ${cname}")
            client_yaml=$(_build_vless_grpc_client_yaml \
                "VLESS gRPC ${cname}" "$SERVER_ADDR" "$client_port" \
                "$CASCADE_UUID" "$SNI_DOMAIN" "$grpc_service" "$PUBLIC_KEY" "$SHORT_ID")
            ;;
        hy2)
            proto_label="Hysteria2"
            client_uri=$(_build_hy2_uri "$CASCADE_PASS" "$SERVER_ADDR" "$client_port")
            client_yaml=$(_build_hy2_client_yaml \
                "Hysteria2 ${cname}" "$SERVER_ADDR" "$client_port" "$CASCADE_PASS")
            ;;
    esac
    local exit_host exit_port replacing=false
    exit_host=$(printf '%s\n' "$exit_proxy_yaml" | awk '/^[[:space:]]*server:/{print $2; exit}')
    exit_port=$(printf '%s\n' "$exit_proxy_yaml" | awk '/^[[:space:]]*port:/{print $2; exit}')
    local review_lines=("Каскад: $cname" "Вход: $proto_label, порт $client_port" "Выход: $exit_host:$exit_port")
    if grep -Fqx "# --- cascade:${cname} ---" /etc/mihomo/config.yaml; then
        replacing=true
        review_lines+=("Существующий каскад «$cname» будет заменён." "Прежние данные подключения перестанут работать.")
    fi
    review_frame "Настройка каскада" "${review_lines[@]}"
    local question="Всё верно?"
    [[ "$replacing" == false ]] || question="Заменить каскад?"
    confirm_yn "$question" N || {
        CASCADE_CANCELLED=true
        info "Отменено."
        return 1
    }
    local _cascade_old_umask
    _cascade_old_umask=$(umask)
    umask 077
    if [[ "$replacing" == true ]]; then
        _remove_cascade "$cname" || {
            umask "$_cascade_old_umask"
            warn "Не удалось удалить прежний каскад."
            return 1
        }
    fi

    # ── 1. Добавить user в листенер ──────────────────────────────────────────
    local user_block
    if $is_vless; then
        user_block="      # cascade-user:${cname}\n"
        user_block+="      - username: ${cname}\n"
        user_block+="        uuid: ${CASCADE_UUID}"
        [[ "$marker" == "vless-tcp" ]] && user_block+="\n        flow: xtls-rprx-vision"
        user_block+="\n      # /cascade-user:${cname}"
    else
        user_block="      # cascade-user:${cname}\n"
        user_block+="      ${cname}: ${CASCADE_PASS}\n"
        user_block+="      # /cascade-user:${cname}"
    fi

    # Вставляем после последней записи users (перед transport/TLS/routing полями listener'а)
    local _tmpfile
    _tmpfile=$(mktemp)
    awk -v ublock="$user_block" '
        BEGIN { in_block=0; in_users=0; last_user_line=0 }
        /^# --- '"$marker"' ---$/ { in_block=1 }
        /^# --- \/'"$marker"' ---$/ { in_block=0 }
        in_block && /^    users:/ { in_users=1 }
        in_block && in_users && /^    [a-z]/ && !/^    users:/ { in_users=0 }
        in_block && in_users { last_user_line=NR }
        { lines[NR]=$0 }
        END {
            for (i=1; i<=NR; i++) {
                print lines[i]
                if (i == last_user_line) {
                    printf "%s\n", ublock
                }
            }
        }
    ' /etc/mihomo/config.yaml > "$_tmpfile"
    mv "$_tmpfile" /etc/mihomo/config.yaml
    success "Пользователь $cname добавлен в $proto_label"

    # ── 2. proxy → rule + sub-rules ────────────────────────────────────────────
    local subrule_name="${marker}-shared"

    # Проверяем, уже ли есть rule: в этом листенере (от предыдущего каскада)
    local has_rule
    has_rule=$(sed -n "/^# --- ${marker} ---/,/^# --- \/${marker} ---/p" /etc/mihomo/config.yaml \
        | grep -c '    rule:')

    if [[ "$has_rule" -eq 0 ]]; then
        # Первый каскад для этого листенера — заменяем proxy: → rule:
        sed -i "/^# --- ${marker} ---/,/^# --- \/${marker} ---/{s/    proxy: .*/    rule: ${subrule_name}/}" \
            /etc/mihomo/config.yaml
    fi

    # Проверяем, есть ли уже sub-rules секция и конкретный sub-rule
    if grep -q "^  ${subrule_name}:" /etc/mihomo/config.yaml 2>/dev/null; then
        # Sub-rule уже есть — добавляем IN-USER перед MATCH
        sed -i "/^  ${subrule_name}:/,/MATCH/{
            /MATCH/i\\    - IN-USER,${cname},${cname}-outbound
        }" /etc/mihomo/config.yaml
    elif grep -q '^sub-rules:' /etc/mihomo/config.yaml 2>/dev/null; then
        # sub-rules секция есть, но этого sub-rule нет — добавляем
        sed -i "/^sub-rules:/a\\  ${subrule_name}:\n    - IN-USER,${cname},${cname}-outbound\n    - MATCH,outbound" \
            /etc/mihomo/config.yaml
    else
        # sub-rules секции нет — создаём перед rule-providers:
        local _sub_tmp
        _sub_tmp=$(mktemp)
        cat > "$_sub_tmp" << SUBREOF
sub-rules:
  ${subrule_name}:
    - IN-USER,${cname},${cname}-outbound
    - MATCH,outbound

SUBREOF
        awk '
            /^rule-providers:/{
                while ((getline line < "'"$_sub_tmp"'") > 0) print line
            }
            {print}
        ' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
        mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
        rm "$_sub_tmp"
    fi

    # ── 3. Exit-proxy — внутрь proxies блока ─────────────────────────────────
    cat > /tmp/cascade_proxy.yaml << EOF
# --- cascade:${cname} ---
# shared-listener: ${marker}
$exit_proxy_yaml
# --- /cascade:${cname} ---
EOF

    awk '
        /^# --- proxies ---/{
            print
            while ((getline line < "/tmp/cascade_proxy.yaml") > 0) print line
            next
        }
        {print}
    ' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
    rm /tmp/cascade_proxy.yaml

    # ── 4. Outbound группа — перед listeners: ────────────────────────────────
    awk -v cname="$cname" '
        /^listeners:/{
            print "# --- cascade-group:" cname " ---"
            print "  - name: " cname "-outbound"
            print "    type: fallback"
            print "    proxies:"
            print "      - " cname
            print "      - DIRECT"
            print "    url: https://www.gstatic.com/generate_204"
            print "    interval: 10"
            print "    timeout: 3000"
            print "    lazy: false"
            print "# --- /cascade-group:" cname " ---"
            print ""
        }
        {print}
    ' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
    success "${cname}-outbound группа создана"

    # ── 5. Client config ─────────────────────────────────────────────────────
    cat >> /etc/mihomo/client-config.txt << EOF

--- Cascade: ${cname} ---
Listener: $proto_label (:$client_port)
URI:  $client_uri

--- Client proxy config Mihomo/Clash.Meta ---
$client_yaml
--- /Cascade: ${cname} ---
EOF

    # ── 6. Перезапуск ────────────────────────────────────────────────────────
    info "Перезапускаю Mihomo..."
    local _start_rc=0
    systemctl restart mihomo &>/dev/null || _start_rc=$?
    sleep 3

    if [[ "$_start_rc" -eq 0 ]] && systemctl is-active --quiet mihomo; then
        success "Mihomo перезапущен"
    else
        warn "Не удалось запустить Mihomo. Проверьте журнал и повторите действие из меню."
        journalctl -u mihomo -n 20 --no-pager || true
        umask "$_cascade_old_umask"
        return 1
    fi

    echo ""
    success_box "Каскад $cname настроен!"
    echo ""
    echo -e "  Через: ${CYAN}$proto_label (:$client_port)${NC} -> ${cname}-outbound -> exit-нода"
    echo ""
    echo -e "  URI: ${CYAN}${client_uri}${NC}"
    echo ""
    echo -e "  ${CYAN}Конфиг клиента Mihomo/Clash.Meta:${NC}"
    echo -e "${DIM}"
    echo "$client_yaml"
    echo -e "${NC}"
    umask "$_cascade_old_umask"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# Удаление каскада
# ═══════════════════════════════════════════════════════════════════════════════

_remove_cascade() {
    local cname="$1"

    # Определяем тип каскада
    local block
    block=$(sed -n "/^# --- cascade:${cname} ---/,/^# --- \/cascade:${cname} ---/p" /etc/mihomo/config.yaml)
    local ctype
    ctype=$(echo "$block" | grep '^# type:' | awk '{print $3}')

    if [[ "$ctype" == "iptables-dnat" ]]; then
        _remove_dnat_cascade "$cname"
    else
        _remove_proxy_cascade "$cname"
    fi
}

_remove_dnat_cascade() {
    local cname="$1"

    local block
    block=$(sed -n "/^# --- cascade:${cname} ---/,/^# --- \/cascade:${cname} ---/p" /etc/mihomo/config.yaml)
    local remote remote_port local_port
    remote=$(echo "$block" | grep '^# remote:' | awk '{print $3}')
    remote_port=$(echo "$block" | grep '^# remote-port:' | awk '{print $3}')
    local_port=$(echo "$block" | grep '^# local-port:' | awk '{print $3}')

    # Удаляем iptables правила
    _remove_dnat_rules "$cname" "$remote" "$remote_port" "$local_port" || return 1
    _persist_dnat_rules || return 1

    # Удаляем маркер из config.yaml
    sed "/^# --- cascade:${cname} ---/,/^# --- \/cascade:${cname} ---/d" /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml || return 1
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml || return 1

    # Закрываем порт
    if [[ -n "$local_port" ]]; then
        ufw delete allow "${local_port}/tcp" > /dev/null 2>&1 || true
        ufw delete allow "${local_port}/udp" > /dev/null 2>&1 || true
    fi

    # Удаляем из client-config.txt
    if [[ -f /etc/mihomo/client-config.txt ]]; then
        sed "/^--- Cascade: ${cname} ---/,/^--- \/Cascade: ${cname} ---/d" /etc/mihomo/client-config.txt > /tmp/client_tmp.txt || return 1
        mv /tmp/client_tmp.txt /etc/mihomo/client-config.txt || return 1
    fi
    return 0
}

_remove_proxy_cascade() {
    local cname="$1"

    # Определяем тип: shared-listener (новый) или cascade-listener (старый)
    local shared_marker
    shared_marker=$(sed -n "/^# --- cascade:${cname} ---/,/^# --- \/cascade:${cname} ---/p" \
        /etc/mihomo/config.yaml | grep '^# shared-listener:' | awk '{print $3}')

    if [[ -n "$shared_marker" ]]; then
        # ── Новый формат: shared listener ────────────────────────────────────
        # a) Удалить cascade-user из листенера
        sed -i "/^      # cascade-user:${cname}$/,/^      # \/cascade-user:${cname}$/d" /etc/mihomo/config.yaml || return 1

        # b) Удалить IN-USER правило из sub-rules
        local subrule_name="${shared_marker}-shared"
        sed -i "/- IN-USER,${cname},/d" /etc/mihomo/config.yaml || return 1

        # c) Если больше нет cascade-user в этом листенере — вернуть proxy: outbound
        if ! sed -n "/^# --- ${shared_marker} ---/,/^# --- \/${shared_marker} ---/p" \
             /etc/mihomo/config.yaml | grep -q '# cascade-user:'; then
            # Заменить rule: → proxy: outbound
            sed -i "/^# --- ${shared_marker} ---/,/^# --- \/${shared_marker} ---/{s/    rule: .*/    proxy: outbound/}" \
                /etc/mihomo/config.yaml || return 1

            # Удалить sub-rule entry (имя + все правила)
            awk -v name="  ${subrule_name}:" '
                $0 == name { skip=1; next }
                skip && /^    - / { next }
                skip { skip=0 }
                { print }
            ' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml || return 1
            mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml || return 1

            # Если sub-rules: пуста — удалить заголовок и пустые строки
            if ! grep -qE '^  [a-z]' /etc/mihomo/config.yaml 2>/dev/null \
               || ! awk '/^sub-rules:/{f=1;next} f && /^  [a-z]/{found=1} f && /^[a-z]/{exit} END{exit !found}' \
                    /etc/mihomo/config.yaml 2>/dev/null; then
                sed -i '/^sub-rules:$/d' /etc/mihomo/config.yaml || return 1
            fi
        fi
    else
        # ── Старый формат: отдельный cascade-listener ────────────────────────
        local cascade_port
        cascade_port=$(sed -n "/^# --- cascade-listener:${cname} ---/,/^# --- \/cascade-listener:${cname} ---/p" \
            /etc/mihomo/config.yaml | grep 'port:' | head -1 | awk '{print $2}')

        sed "/^# --- cascade-listener:${cname} ---/,/^# --- \/cascade-listener:${cname} ---/d" \
            /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml || return 1
        mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml || return 1

        if [[ -n "$cascade_port" ]]; then
            ufw delete allow "${cascade_port}/tcp" > /dev/null 2>&1 || true
            ufw delete allow "${cascade_port}/udp" > /dev/null 2>&1 || true
        fi
    fi

    # Общее: exit-proxy, outbound группа, client-config
    sed "/^# --- cascade:${cname} ---/,/^# --- \/cascade:${cname} ---/d" \
        /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml || return 1
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml || return 1

    sed "/^# --- cascade-group:${cname} ---/,/^# --- \/cascade-group:${cname} ---/d" \
        /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml || return 1
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml || return 1

    if [[ -f /etc/mihomo/client-config.txt ]]; then
        sed "/^--- Cascade: ${cname} ---/,/^--- \/Cascade: ${cname} ---/d" \
            /etc/mihomo/client-config.txt > /tmp/client_tmp.txt || return 1
        mv /tmp/client_tmp.txt /etc/mihomo/client-config.txt || return 1
    fi
    return 0
}

remove_cascade_interactive() {
    CASCADE_CANCELLED=false
    echo ""

    local cascades=()
    while IFS= read -r line; do
        cascades+=("$line")
    done < <(grep '^# --- cascade:' /etc/mihomo/config.yaml 2>/dev/null | sed 's/# --- cascade://;s/ ---//')

    MENU_SELECT_EMPTY="Нет каскадов для удаления"
    menu_select "Удаление каскада" "Выберите каскад" "${cascades[@]}" || {
        CASCADE_CANCELLED=true
        return 1
    }
    local target="${cascades[$((MENU_SELECT_INDEX - 1))]}"
    review_frame "Удаление каскада" \
        "Каскад: $target" \
        "Доступ каскада и его клиентская конфигурация будут удалены." \
        "Mihomo будет перезапущен."
    confirm_yn "Удалить каскад?" N || { info "Отменено."; return 0; }

    _remove_cascade "$target" || return 1
    success "Каскад $target удалён"

    info "Перезапускаю Mihomo..."
    local _start_rc=0
    systemctl restart mihomo &>/dev/null || _start_rc=$?
    sleep 3

    if [[ "$_start_rc" -eq 0 ]] && systemctl is-active --quiet mihomo; then
        success "Mihomo перезапущен"
    else
        warn "Не удалось запустить Mihomo. Проверьте журнал и повторите действие из меню."
        journalctl -u mihomo -n 20 --no-pager || true
        return 1
    fi
    echo ""
    return 0
}
