#!/bin/bash
# ─── Управление подписками (subscription hosting) ──────────────────────────

# ─── SSH context save/restore ───────────────────────────────────────────────

_sub_save_ssh_ctx() {
    _SAVE_NODE_NAME="$NODE_NAME" _SAVE_SERVER_IP="$SERVER_IP"
    _SAVE_SERVER_PORT="$SERVER_PORT" _SAVE_SERVER_USER="$SERVER_USER"
    _SAVE_SERVER_PASS="$SERVER_PASS" _SAVE_SERVER_AUTH="$SERVER_AUTH"
}

_sub_restore_ssh_ctx() {
    NODE_NAME="$_SAVE_NODE_NAME" SERVER_IP="$_SAVE_SERVER_IP"
    SERVER_PORT="$_SAVE_SERVER_PORT" SERVER_USER="$_SAVE_SERVER_USER"
    SERVER_PASS="$_SAVE_SERVER_PASS" SERVER_AUTH="$_SAVE_SERVER_AUTH"
}

_sub_load_host() {
    _ensure_default_headers
    local host_node
    host_node=$(jq_r '.subscription_host.node // empty')
    [[ -z "$host_node" ]] && { warn "Subscription host не задан. Используйте 'Выбрать host-ноду'."; return 1; }
    _sub_save_ssh_ctx
    node_load_by_name "$host_node" || { _sub_restore_ssh_ctx; warn "Нода '$host_node' не найдена."; return 1; }

    if ! ssh_run -- "test -f /etc/mihomo/subscription.conf" 2>/dev/null; then
        _sub_restore_ssh_ctx
        warn "На ноде '$host_node' не установлен subscription module — сброшен из subscription_host."
        jq_w 'del(.subscription_host)'
        info "Подключитесь к ноде и запустите: essence-setup → s) Subscription hosting"
        info "Или выберите другую host-ноду: Subscriptions → 1) Выбрать host-ноду"
        return 1
    fi
}

# Записывает дефолтные subscription headers если их ещё нет в config.json.
# Вызывается лениво из _sub_load_host и subscription_menu.
_ensure_default_headers() {
    local has
    has=$(jq_r 'has("subscription_default_headers")')
    [[ "$has" == "true" ]] && return 0
    jq_w '.subscription_default_headers = [
        {name: "Content-Disposition", value: "attachment; filename=\"config.yaml\""},
        {name: "profile-update-interval", value: "24"}
    ]'
}

_sub_done() {
    _sub_restore_ssh_ctx
}

SUB_SNIPPETS_DIR="/etc/nginx/snippets/essence-sub"

# ─── Атомарная публикация конфига ───────────────────────────────────────────
# Требует: _sub_load_host уже вызван (SSH_CTX указывает на host-ноду).
# Грузит yaml + per-token nginx snippet атомарно: scp .tmp → nginx -t → mv → reload.
# Возвращает 0 при успехе, 1 при любой ошибке (шумит через warn).

_sub_get_dir() {
    local d
    d=$(jq_r '.subscription_host.sub_dir // empty')
    if [[ -n "$d" ]]; then echo "$d"; return; fi
    d=$(ssh_run -- "grep '^SUB_DIR=' /etc/mihomo/subscription.conf 2>/dev/null" | cut -d= -f2-)
    echo "${d:-/var/lib/essence-sub}"
}

_sub_get_nginx_group() {
    local g
    g=$(jq_r '.subscription_host.nginx_group // empty')
    if [[ -n "$g" ]]; then echo "$g"; return; fi
    g=$(ssh_run -- "grep '^NGINX_GROUP=' /etc/mihomo/subscription.conf 2>/dev/null | cut -d= -f2-")
    echo "${g:-www-data}"
}

_sub_upload_config() {
    local src="$1" token="$2" sub_dir="$3" nginx_group="${4:-www-data}" client="${5:-}"
    local snippets_dir="$SUB_SNIPPETS_DIR"
    local yaml_tmp="${sub_dir}/.${token}.yaml.tmp"
    local yaml_dst="${sub_dir}/${token}.yaml"
    local snip_tmp="${snippets_dir}/.sub-${token}.conf.tmp"
    local snip_dst="${snippets_dir}/sub-${token}.conf"
    local short="${token:0:8}…"

    # Локально рендерим snippet (если client указан)
    local snip_local=""
    if [[ -n "$client" ]]; then
        snip_local=$(mktemp)
        _render_subscription_snippet "$client" "$token" "$sub_dir" > "$snip_local"
    fi

    if ! scp_run "$src" "${SERVER_USER}@${SERVER_IP}:${yaml_tmp}"; then
        [[ -n "$snip_local" ]] && rm -f "$snip_local"
        warn "scp yaml не отработал для ${short}"
        return 1
    fi

    if [[ -n "$snip_local" ]]; then
        if ! scp_run "$snip_local" "${SERVER_USER}@${SERVER_IP}:${snip_tmp}"; then
            rm -f "$snip_local"
            ssh_run -- "rm -f '${yaml_tmp}'" 2>/dev/null
            warn "scp snippet не отработал для ${short}"
            return 1
        fi
        rm -f "$snip_local"
    fi

    local ssh_cmd
    ssh_cmd="set -e
chown root:${nginx_group} '${yaml_tmp}' && chmod 640 '${yaml_tmp}'"

    if [[ -n "$client" ]]; then
        ssh_cmd+="
chown root:root '${snip_tmp}' && chmod 644 '${snip_tmp}'
backup=
if [ -f '${snip_dst}' ]; then backup=\$(mktemp); cp '${snip_dst}' \"\$backup\"; fi
mv '${snip_tmp}' '${snip_dst}'
if ! nginx -t >/dev/null 2>&1; then
    if [ -n \"\$backup\" ]; then mv \"\$backup\" '${snip_dst}'; else rm -f '${snip_dst}'; fi
    rm -f '${yaml_tmp}'
    nginx -t >&2 || true
    exit 1
fi
[ -n \"\$backup\" ] && rm -f \"\$backup\"
mv '${yaml_tmp}' '${yaml_dst}'
systemctl reload nginx"
    else
        ssh_cmd+="
mv '${yaml_tmp}' '${yaml_dst}'"
    fi

    if ! ssh_run -- "$ssh_cmd"; then
        ssh_run -- "rm -f '${yaml_tmp}' '${snip_tmp}'" 2>/dev/null
        warn "Не удалось применить ${short} (nginx -t / права / reload)"
        return 1
    fi
    return 0
}

# ─── Batch-загрузка: 1 SCP yaml + 1 SCP snippet + 1 atomic SSH ──────────────
# Аргументы: sub_dir nginx_group [config_file token client_name ...]

_sub_upload_batch() {
    local sub_dir="$1" nginx_group="$2"
    shift 2
    local triplets=("$@")
    local count=$(( ${#triplets[@]} / 3 ))
    [[ $count -eq 0 ]] && return 0

    local snippets_dir="$SUB_SNIPPETS_DIR"
    local yaml_tmp_dir snip_tmp_dir
    yaml_tmp_dir=$(mktemp -d)
    snip_tmp_dir=$(mktemp -d)

    local i=0 tokens=()
    while [[ $i -lt ${#triplets[@]} ]]; do
        local src="${triplets[$i]}" token="${triplets[$((i+1))]}" client="${triplets[$((i+2))]}"
        cp "$src" "$yaml_tmp_dir/.${token}.yaml.tmp"
        _render_subscription_snippet "$client" "$token" "$sub_dir" > "$snip_tmp_dir/.sub-${token}.conf.tmp"
        tokens+=("$token")
        i=$((i + 3))
    done

    if ! scp_run "$yaml_tmp_dir"/.*.yaml.tmp "${SERVER_USER}@${SERVER_IP}:${sub_dir}/"; then
        rm -rf "$yaml_tmp_dir" "$snip_tmp_dir"
        warn "scp yaml batch не отработал"
        return 1
    fi
    if ! scp_run "$snip_tmp_dir"/.sub-*.conf.tmp "${SERVER_USER}@${SERVER_IP}:${snippets_dir}/"; then
        rm -rf "$yaml_tmp_dir" "$snip_tmp_dir"
        ssh_run -- "rm -f ${sub_dir}/.*.yaml.tmp" 2>/dev/null
        warn "scp snippet batch не отработал"
        return 1
    fi
    rm -rf "$yaml_tmp_dir" "$snip_tmp_dir"

    local tokens_csv
    tokens_csv=$(IFS=' '; echo "${tokens[*]}")

    local ssh_cmd
    ssh_cmd="set -e
SUB_DIR='${sub_dir}'
SNIP_DIR='${snippets_dir}'
TOKENS='${tokens_csv}'
chown root:${nginx_group} \"\$SUB_DIR\"/.*.yaml.tmp && chmod 640 \"\$SUB_DIR\"/.*.yaml.tmp
chown root:root \"\$SNIP_DIR\"/.sub-*.conf.tmp && chmod 644 \"\$SNIP_DIR\"/.sub-*.conf.tmp
BACKUP_DIR=\$(mktemp -d)
trap 'rm -rf \"\$BACKUP_DIR\"' EXIT
for tok in \$TOKENS; do
    if [ -f \"\$SNIP_DIR/sub-\$tok.conf\" ]; then
        cp \"\$SNIP_DIR/sub-\$tok.conf\" \"\$BACKUP_DIR/sub-\$tok.conf\"
    fi
    mv \"\$SNIP_DIR/.sub-\$tok.conf.tmp\" \"\$SNIP_DIR/sub-\$tok.conf\"
done
if ! nginx -t >/dev/null 2>&1; then
    for tok in \$TOKENS; do
        if [ -f \"\$BACKUP_DIR/sub-\$tok.conf\" ]; then
            mv \"\$BACKUP_DIR/sub-\$tok.conf\" \"\$SNIP_DIR/sub-\$tok.conf\"
        else
            rm -f \"\$SNIP_DIR/sub-\$tok.conf\"
        fi
    done
    rm -f \"\$SUB_DIR\"/.*.yaml.tmp
    nginx -t >&2 || true
    exit 1
fi
for f in \"\$SUB_DIR\"/.*.yaml.tmp; do
    [ -e \"\$f\" ] || continue
    base=\$(basename \"\$f\")
    base=\${base#.}
    base=\${base%.tmp}
    mv \"\$f\" \"\$SUB_DIR/\$base\"
done
systemctl reload nginx"

    if ! ssh_run -- "$ssh_cmd"; then
        ssh_run -- "rm -f ${sub_dir}/.*.yaml.tmp ${snippets_dir}/.sub-*.conf.tmp" 2>/dev/null
        warn "Не удалось применить batch (nginx -t / права / reload)"
        return 1
    fi
    return 0
}

# HTTP-верификация: токен должен отдавать 200. Возвращает 0/1.
_sub_verify_http() {
    local token="$1"
    local base_url
    base_url=$(jq_r '.subscription_host.base_url // empty')
    [[ -z "$base_url" ]] && return 0

    local code
    code=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "${base_url}/sub/${token}" 2>/dev/null)
    if [[ "$code" != "200" ]]; then
        warn "HTTP проверка: ${code:-timeout} (ожидалось 200). Смотри nginx error.log на сервере."
        return 1
    fi
    return 0
}

# ─── Хедеры: наследование группа → клиент ──────────────────────────────────

_resolve_headers() {
    local client="$1"
    local group
    group=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .group // empty')

    # defaults + group headers + client headers → merge (later wins by .name)
    jq_r --arg n "$client" --arg g "$group" '
        ((.subscription_default_headers // [])) as $dh |
        ((.groups[] | select(.name==$g) | .subscription_headers) // []) as $gh |
        ((.clients[] | select(.name==$n) | .subscription.headers) // []) as $ch |
        ($dh + $gh + $ch) | group_by(.name) | map(last) | sort_by(.name)
    '
}

_resolve_headers_annotated() {
    local client="$1"
    local group
    group=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .group // empty')

    jq_r --arg n "$client" --arg g "$group" '
        ((.subscription_default_headers // [])) as $dh |
        ((.groups[] | select(.name==$g) | .subscription_headers) // []) as $gh |
        ((.clients[] | select(.name==$n) | .subscription.headers) // []) as $ch |
        ($dh | map({key: .name, value: {value: .value, source: "default"}})) as $dm |
        ($gh | map({key: .name, value: {value: .value, source: "group"}})) as $gm |
        ($ch | map({key: .name, value: {value: .value, source: "client"}})) as $cm |
        ($dm + $gm + $cm) | group_by(.key) | map(last) | sort_by(.key) |
        map("\(.value.value)|\(.key)|\(.value.source)")[]
    '
}

# Генерит per-token nginx snippet (location = /sub/<token>) на stdout.
# Чистая функция: ни SSH, ни jq_w, только чтение конфига через _resolve_headers.
# Args: client token sub_dir
_render_subscription_snippet() {
    local client="$1" token="$2" sub_dir="$3"

    printf 'location = /sub/%s {\n' "$token"
    printf '    alias %s/%s.yaml;\n' "$sub_dir" "$token"
    printf '    default_type application/yaml;\n'
    printf '    add_header Cache-Control "no-store" always;\n'
    printf '    add_header X-Content-Type-Options nosniff always;\n'

    local headers_json count
    headers_json=$(_resolve_headers "$client")
    count=$(echo "$headers_json" | jq 'length' 2>/dev/null)
    count="${count:-0}"

    if [[ "$count" -gt 0 ]]; then
        local i name value quoted esc
        for ((i=0; i<count; i++)); do
            name=$(echo "$headers_json" | jq -r ".[$i].name")
            value=$(echo "$headers_json" | jq -r ".[$i].value")
            if [[ "$value" != *"'"* ]]; then
                quoted="'${value}'"
            else
                esc="${value//\\/\\\\}"
                esc="${esc//\"/\\\"}"
                quoted="\"${esc}\""
            fi
            printf '    add_header %s %s always;\n' "$name" "$quoted"
        done
    fi

    printf '    limit_req zone=sub burst=5 nodelay;\n'
    printf '}\n'
}

# ─── Основные команды ──────────────────────────────────────────────────────

subscription_set_host() {
    echo ""
    echo -e "  ${CYAN}── Выбрать host-ноду для подписок ──────────${NC}"
    echo ""

    local nodes=()
    mapfile -t nodes < <(jq_r '.nodes[].name')
    if [[ ${#nodes[@]} -eq 0 ]]; then
        warn "Нет нод. Добавьте ноду сначала."
        return
    fi

    local i=1
    for n in "${nodes[@]}"; do
        echo -e "  ${GREEN}${i})${NC} $n"
        i=$((i + 1))
    done
    echo ""
    read -rp "  Выберите ноду: " idx
    [[ -z "$idx" || ! "$idx" =~ ^[0-9]+$ ]] && { warn "Неверный выбор."; return; }
    local sel="${nodes[$((idx - 1))]}"
    [[ -z "$sel" ]] && { warn "Неверный выбор."; return; }

    # Проверяем что на ноде стоит subscription module
    _sub_save_ssh_ctx
    node_load_by_name "$sel" || { _sub_restore_ssh_ctx; warn "Не удалось загрузить ноду."; return; }

    local remote_conf
    remote_conf=$(ssh_run -- "cat /etc/mihomo/subscription.conf 2>/dev/null")
    _sub_restore_ssh_ctx

    if [[ -z "$remote_conf" ]]; then
        warn "На ноде '$sel' не установлен subscription module."
        info "Подключитесь к ноде и запустите: essence-setup → s) Subscription hosting"
        return
    fi

    local base_url sub_dir nginx_group
    base_url=$(echo "$remote_conf" | grep '^SUB_BASE_URL=' | cut -d= -f2-)
    sub_dir=$(echo "$remote_conf" | grep '^SUB_DIR=' | cut -d= -f2-)
    nginx_group=$(echo "$remote_conf" | grep '^NGINX_GROUP=' | cut -d= -f2-)

    jq_w --arg n "$sel" --arg u "$base_url" \
         --arg d "${sub_dir:-/var/lib/essence-sub}" \
         --arg g "${nginx_group:-www-data}" \
         '.subscription_host = {node: $n, base_url: $u, sub_dir: $d, nginx_group: $g}'
    success "Host-нода: $sel ($base_url)"
}

subscription_publish() {
    local client="$1" ttl="${2:-}"
    [[ -z "$client" ]] && { _select_client "Опубликовать подписку" client || return; }

    # Проверяем что клиент существует
    local client_group
    client_group=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .group // empty')
    [[ -z "$client_group" ]] && { warn "Клиент '$client' не найден."; return; }

    # Проверяем host
    local host_node base_url
    host_node=$(jq_r '.subscription_host.node // empty')
    base_url=$(jq_r '.subscription_host.base_url // empty')
    [[ -z "$host_node" ]] && { warn "Host-нода не задана. Используйте 'Выбрать host-ноду'."; return; }

    # Генерируем конфиг если нет
    local config_file
    config_file=$(_client_config_file "$client")
    if [[ ! -f "$config_file" ]]; then
        warn "Конфиг для '$client' не найден. Сначала сгенерируйте конфиги."
        return
    fi

    # Токен: новый или существующий
    local token
    token=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.token // empty')
    if [[ -z "$token" ]]; then
        token=$(openssl rand -hex 32)
    fi

    # Загружаем на сервер
    _sub_load_host || return

    local sub_dir nginx_group
    sub_dir=$(_sub_get_dir)
    nginx_group=$(_sub_get_nginx_group)

    local rc=0
    _sub_upload_config "$config_file" "$token" "$sub_dir" "$nginx_group" "$client" || rc=1

    # TTL → expiry.list
    if [[ $rc -eq 0 && -n "$ttl" ]]; then
        local expires_at expires_ts
        expires_ts=$(date -d "+${ttl}" +%s 2>/dev/null) || { _sub_done; warn "Неверный формат TTL: $ttl"; return; }
        expires_at=$(date -d "+${ttl}" --iso-8601=seconds 2>/dev/null)
        ssh_run -- "flock ${sub_dir}/.expiry.lock bash -c 'echo \"${token} ${expires_ts}\" >> ${sub_dir}/expiry.list'"
        jq_w --arg n "$client" --arg t "$token" --arg e "$expires_at" --arg ts "$(date --iso-8601=seconds)" \
            '(.clients[] | select(.name==$n)).subscription |= ((. // {}) + {token: $t, expires_at: $e, created_at: $ts})'
    elif [[ $rc -eq 0 ]]; then
        jq_w --arg n "$client" --arg t "$token" --arg ts "$(date --iso-8601=seconds)" \
            '(.clients[] | select(.name==$n)).subscription |= ((. // {}) + {token: $t, expires_at: null, created_at: $ts})'
    fi

    _sub_done

    if [[ $rc -eq 0 ]]; then
        success "Подписка опубликована: $client"
        _sub_verify_http "$token"
        _show_share_bundle "$client"
    else
        warn "Ошибка загрузки файла на сервер."
    fi
}

subscription_revoke() {
    local client="$1"
    [[ -z "$client" ]] && { _select_client_with_sub "Отозвать подписку" client || return; }

    local token
    token=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.token // empty')
    [[ -z "$token" ]] && { warn "У клиента '$client' нет подписки."; return; }

    confirm_yn "Отозвать подписку '$client'?" || return

    _subscription_revoke_silent "$client"
}

# Тихая версия revoke без confirm. Используется из delete_client и интерактивного revoke.
# Удаляет yaml + nginx snippet + expiry-entry + subscription metadata из config.json.
# Если host-нода offline — warn + продолжаем (orphan'ы потом сметёт publish_all sweep).
_subscription_revoke_silent() {
    local client="$1"
    local token
    token=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.token // empty')
    [[ -z "$token" ]] && return 0

    if _sub_load_host; then
        local sub_dir
        sub_dir=$(_sub_get_dir)
        ssh_run -- "rm -f '${sub_dir}/${token}.yaml' '${SUB_SNIPPETS_DIR}/sub-${token}.conf'; sed -i '/^${token} /d' '${sub_dir}/expiry.list' 2>/dev/null; nginx -t >/dev/null 2>&1 && systemctl reload nginx" 2>/dev/null \
            || warn "Host-нода: ошибка удаления файлов (orphans будут собраны позже)."
        _sub_done
    else
        warn "Host-нода недоступна — файлы подписки '$client' остались как orphan'ы."
    fi

    # Сохраняем headers, удаляем subscription metadata
    jq_w --arg n "$client" '(.clients[] | select(.name==$n)) |= del(.subscription.token, .subscription.expires_at, .subscription.created_at)'

    success "Подписка отозвана: $client"
}

subscription_rotate() {
    local client="$1"
    [[ -z "$client" ]] && { _select_client_with_sub "Сменить токен подписки" client || return; }

    local old_token
    old_token=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.token // empty')
    [[ -z "$old_token" ]] && { warn "У клиента '$client' нет подписки."; return; }

    local config_file
    config_file=$(_client_config_file "$client")
    [[ ! -f "$config_file" ]] && { warn "Конфиг для '$client' не найден."; return; }

    local new_token
    new_token=$(openssl rand -hex 32)

    _sub_load_host || return

    local sub_dir nginx_group
    sub_dir=$(_sub_get_dir)
    nginx_group=$(_sub_get_nginx_group)

    if ! _sub_upload_config "$config_file" "$new_token" "$sub_dir" "$nginx_group" "$client"; then
        _sub_done
        return
    fi
    ssh_run -- "rm -f '${sub_dir}/${old_token}.yaml' '${SUB_SNIPPETS_DIR}/sub-${old_token}.conf'; sed -i 's/^${old_token} /${new_token} /' '${sub_dir}/expiry.list' 2>/dev/null; systemctl reload nginx"
    _sub_done

    jq_w --arg n "$client" --arg t "$new_token" '(.clients[] | select(.name==$n)).subscription.token = $t'

    success "Токен обновлён: $client"
    _sub_verify_http "$new_token"
    _show_share_bundle "$client"
}

subscription_show() {
    local client="$1"
    [[ -z "$client" ]] && { _select_client_with_sub "Показать подписку" client || return; }

    local token
    token=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.token // empty')
    [[ -z "$token" ]] && { warn "У клиента '$client' нет подписки."; return; }

    _show_share_bundle "$client"
}

_show_share_bundle() {
    local client="$1"
    local token base_url
    token=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.token // empty')
    base_url=$(jq_r '.subscription_host.base_url // empty')
    [[ -z "$token" || -z "$base_url" ]] && return

    local url="${base_url}/sub/${token}"

    echo ""
    echo -e "  ${CYAN}── Подписка: ${client} ──${NC}"
    echo ""
    echo -e "  ${GREEN}URL:${NC} $(hyperlink "$url")"

    # TTL
    local expires_at
    expires_at=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.expires_at // empty')
    if [[ -n "$expires_at" ]]; then
        echo -e "  ${YELLOW}Expires:${NC} $expires_at"
    fi

    # Resolved headers — информационно (сервер сам отдаёт их в response)
    local headers_json header_count
    headers_json=$(_resolve_headers "$client")
    header_count=$(echo "$headers_json" | jq 'length' 2>/dev/null)
    header_count="${header_count:-0}"

    if [[ "$header_count" -gt 0 ]]; then
        echo ""
        echo -e "  ${DIM}Сервер отдаст эти заголовки:${NC}"
        echo "$headers_json" | jq -r '.[] | "    \(.name): \(.value)"'
    fi

    # curl
    echo ""
    echo -e "  ${DIM}curl${NC}"
    echo -e "  ${DIM}curl '$url'${NC}"

    # JSON bundle (только URL — заголовки приходят в response, а не в request)
    echo ""
    echo -e "  ${DIM}JSON bundle${NC}"
    jq -n --arg url "$url" '{url: $url}'

    # QR
    if command -v qrencode &>/dev/null; then
        echo ""
        qrencode -t UTF8 "$url"
    fi
}

subscription_list() {
    echo ""
    echo -e "  ${CYAN}── Подписки ──────────────────────────────────${NC}"
    echo ""

    local host_node base_url
    host_node=$(jq_r '.subscription_host.node // empty')
    base_url=$(jq_r '.subscription_host.base_url // empty')

    if [[ -z "$host_node" ]]; then
        echo -e "  ${DIM}Host-нода не задана${NC}"
        return
    fi
    echo -e "  Host: ${GREEN}${host_node}${NC} (${base_url})"
    echo ""

    local found=0
    while IFS='|' read -r name token expires_at; do
        [[ -z "$token" ]] && continue
        found=1
        local status="${GREEN}active${NC}"
        if [[ -n "$expires_at" && "$expires_at" != "null" ]]; then
            local exp_ts now_ts
            exp_ts=$(date -d "$expires_at" +%s 2>/dev/null || echo 0)
            now_ts=$(date +%s)
            if [[ "$exp_ts" -le "$now_ts" ]]; then
                status="${RED}expired${NC}"
            else
                local diff=$(( (exp_ts - now_ts) / 3600 ))
                status="${GREEN}active${NC} ${DIM}(${diff}h left)${NC}"
            fi
        fi
        printf "  %-18s %b  %b\n" "$name" "$status" "$(hyperlink "${base_url}/sub/${token}")"
    done < <(jq_r '.clients[] | select(.subscription.token) | "\(.name)|\(.subscription.token)|\(.subscription.expires_at // "")"')

    [[ "$found" -eq 0 ]] && echo -e "  ${DIM}Нет опубликованных подписок${NC}"
}

subscription_publish_all() {
    local host_node
    host_node=$(jq_r '.subscription_host.node // empty')
    [[ -z "$host_node" ]] && { warn "Host-нода не задана."; return; }

    local all_clients=()
    mapfile -t all_clients < <(jq_r '.clients[].name')

    _sub_load_host || return

    local sub_dir nginx_group
    sub_dir=$(_sub_get_dir)
    nginx_group=$(_sub_get_nginx_group)

    local triplets=() ok=0 new_tokens=() skipped=0 published=()
    for client in "${all_clients[@]}"; do
        local config_file
        config_file=$(_client_config_file "$client")
        if [[ ! -f "$config_file" ]]; then
            skipped=$((skipped + 1))
            continue
        fi

        local token
        token=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.token // empty')
        if [[ -z "$token" ]]; then
            token=$(openssl rand -hex 32)
            new_tokens+=("$client" "$token")
        fi
        triplets+=("$config_file" "$token" "$client")
        published+=("$client|$token")
        ok=$((ok + 1))
    done

    if [[ ${#triplets[@]} -eq 0 ]]; then
        info "Нет конфигов для публикации."
        _sub_done; return
    fi

    if _sub_upload_batch "$sub_dir" "$nginx_group" "${triplets[@]}"; then
        # Сохраняем токены новых клиентов
        local i=0
        while [[ $i -lt ${#new_tokens[@]} ]]; do
            local c="${new_tokens[$i]}" t="${new_tokens[$((i+1))]}"
            jq_w --arg n "$c" --arg t "$t" --arg ts "$(date --iso-8601=seconds)" \
                '(.clients[] | select(.name==$n)).subscription |= ((. // {}) + {token: $t, expires_at: null, created_at: $ts})'
            i=$((i + 2))
        done
        success "Опубликовано: $ok"
        [[ $skipped -gt 0 ]] && info "Пропущено (нет конфига): $skipped"
        [[ ${#new_tokens[@]} -gt 0 ]] && info "Новых подписок: $(( ${#new_tokens[@]} / 2 ))"

        local base_url
        base_url=$(jq_r '.subscription_host.base_url // empty')
        if [[ -n "$base_url" && ${#published[@]} -gt 0 ]]; then
            echo ""
            for entry in "${published[@]}"; do
                local pc="${entry%%|*}" pt="${entry#*|}"
                local purl="${base_url}/sub/${pt}"
                printf "  %-20s %b\n" "$pc" "$(hyperlink "$purl")"
            done
        fi

        # Orphan sweep: удалить yaml + snippet файлы для токенов которых
        # больше нет в config.json (после delete_client при offline хосте и т.п.)
        local known_tokens
        known_tokens=$(jq_r '.clients[] | .subscription.token // empty' | tr '\n' '|' | sed 's/|$//')
        local sweep_cmd
        sweep_cmd="set -e
SUB_DIR='${sub_dir}'
SNIP_DIR='${SUB_SNIPPETS_DIR}'
KNOWN='${known_tokens}'
removed=0
for f in \"\$SUB_DIR\"/*.yaml; do
    [ -e \"\$f\" ] || continue
    base=\$(basename \"\$f\" .yaml)
    case \"|\$KNOWN|\" in
        *\"|\$base|\"*) ;;
        *) rm -f \"\$f\" \"\$SNIP_DIR/sub-\$base.conf\"; removed=\$((removed+1)) ;;
    esac
done
[ \$removed -gt 0 ] && systemctl reload nginx
echo \$removed"
        local removed
        removed=$(ssh_run -- "$sweep_cmd" 2>/dev/null | tail -1)
        if [[ -n "$removed" && "$removed" -gt 0 ]]; then
            info "Cleanup: удалено $removed осиротевших подписок"
        fi
    else
        warn "Ошибка batch upload"
    fi

    _sub_done
}

subscription_migrate() {
    local old_node
    old_node=$(jq_r '.subscription_host.node // empty')
    [[ -z "$old_node" ]] && { warn "Host-нода не задана."; return; }

    echo ""
    info "Текущая host-нода: $old_node"
    echo ""

    # Выбираем новую ноду
    local nodes=()
    mapfile -t nodes < <(jq_r '.nodes[].name')
    local i=1
    for n in "${nodes[@]}"; do
        [[ "$n" == "$old_node" ]] && echo -e "  ${DIM}${i}) ${n} (текущий)${NC}" || echo -e "  ${GREEN}${i})${NC} $n"
        i=$((i + 1))
    done
    echo ""
    read -rp "  Новая host-нода: " idx
    local new_node="${nodes[$((idx - 1))]}"
    [[ -z "$new_node" || "$new_node" == "$old_node" ]] && { info "Отменено."; return; }

    # Проверяем subscription module на новой ноде
    _sub_save_ssh_ctx
    node_load_by_name "$new_node" || { _sub_restore_ssh_ctx; warn "Не удалось загрузить ноду."; return; }
    local new_conf
    new_conf=$(ssh_run -- "cat /etc/mihomo/subscription.conf 2>/dev/null")
    _sub_restore_ssh_ctx

    if [[ -z "$new_conf" ]]; then
        warn "На ноде '$new_node' не установлен subscription module."
        return
    fi

    local new_base_url new_sub_dir new_nginx_group
    new_base_url=$(echo "$new_conf" | grep '^SUB_BASE_URL=' | cut -d= -f2-)
    new_sub_dir=$(echo "$new_conf" | grep '^SUB_DIR=' | cut -d= -f2-)
    new_sub_dir="${new_sub_dir:-/var/lib/essence-sub}"
    new_nginx_group=$(echo "$new_conf" | grep '^NGINX_GROUP=' | cut -d= -f2-)
    new_nginx_group="${new_nginx_group:-www-data}"

    confirm_yn "Мигрировать все подписки с '$old_node' на '$new_node'?" || return

    # Заливаем файлы на новую ноду
    _sub_save_ssh_ctx
    node_load_by_name "$new_node" || { _sub_restore_ssh_ctx; return; }

    local ok=0
    while IFS='|' read -r client token; do
        local config_file
        config_file=$(_client_config_file "$client")
        if [[ -f "$config_file" ]]; then
            _sub_upload_config "$config_file" "$token" "$new_sub_dir" "$new_nginx_group" "$client" && ok=$((ok + 1))
        fi
    done < <(jq_r '.clients[] | select(.subscription.token) | "\(.name)|\(.subscription.token)"')

    _sub_restore_ssh_ctx

    # Удаляем со старой ноды (yaml + snippet)
    _sub_save_ssh_ctx
    node_load_by_name "$old_node" || { _sub_restore_ssh_ctx; return; }

    while IFS='|' read -r _ token; do
        ssh_run -- "rm -f '/var/lib/essence-sub/${token}.yaml' '${SUB_SNIPPETS_DIR}/sub-${token}.conf'"
    done < <(jq_r '.clients[] | select(.subscription.token) | "\(.name)|\(.subscription.token)"')
    ssh_run -- "nginx -t >/dev/null 2>&1 && systemctl reload nginx" 2>/dev/null

    _sub_restore_ssh_ctx

    # Обновляем config.json
    jq_w --arg n "$new_node" --arg u "$new_base_url" \
         --arg d "$new_sub_dir" --arg g "$new_nginx_group" \
         '.subscription_host = {node: $n, base_url: $u, sub_dir: $d, nginx_group: $g}'

    success "Мигрировано $ok подписок на '$new_node'"
    info "Новый base URL: $new_base_url"
    warn "URL всех подписок изменились! Уведомите клиентов."
}

# ─── Управление хедерами ───────────────────────────────────────────────────

subscription_set_header() {
    local client="$1" hname="$2" hvalue="$3"
    [[ -z "$client" ]] && { _select_client "Добавить header" client || return; }
    [[ -z "$hname" ]] && { read -rp "Header name: " hname; }
    [[ -z "$hvalue" ]] && { read -rp "Header value: " hvalue; }
    [[ -z "$hname" || -z "$hvalue" ]] && { warn "Имя и значение обязательны."; return; }

    # Валидация: RFC 7230 token chars для имени
    if [[ ! "$hname" =~ ^[a-zA-Z0-9!#\$%\&\'*+\-.^_\`|~]+$ ]]; then
        warn "Некорректное имя заголовка."
        return 1
    fi
    # CRLF injection
    if [[ "$hvalue" =~ $'\r' || "$hvalue" =~ $'\n' ]]; then
        warn "Значение не может содержать переводы строк."
        return 1
    fi
    # Trailing backslash ломает escape в double-quoted nginx-литералах
    if [[ "$hvalue" =~ \\$ ]]; then
        warn "Значение не может оканчиваться на \\."
        return 1
    fi

    jq_w --arg n "$client" --arg hn "$hname" --arg hv "$hvalue" '
        (.clients[] | select(.name==$n)).subscription.headers =
            (((.clients[] | select(.name==$n)).subscription.headers // [])
            | [.[] | select(.name != $hn)] + [{name: $hn, value: $hv}])
    '
    success "Header установлен: $hname: $hvalue (клиент: $client)"
    info "Запустите публикацию для $client чтобы применить."
}

subscription_del_header() {
    local client="$1" hname="$2"
    [[ -z "$client" ]] && { _select_client_with_sub "Удалить header" client || return; }
    [[ -z "$hname" ]] && { read -rp "Header name: " hname; }
    [[ -z "$hname" ]] && { warn "Имя обязательно."; return; }

    jq_w --arg n "$client" --arg hn "$hname" '
        (.clients[] | select(.name==$n)).subscription.headers =
            (((.clients[] | select(.name==$n)).subscription.headers // [])
            | [.[] | select(.name != $hn)])
    '
    success "Header удалён: $hname (клиент: $client)"
    info "Запустите публикацию для $client чтобы применить."
}

subscription_group_set_header() {
    local group="$1" hname="$2" hvalue="$3"
    [[ -z "$group" ]] && { _select_group "Добавить групповой header" group || return; }
    [[ -z "$hname" ]] && { read -rp "Header name: " hname; }
    [[ -z "$hvalue" ]] && { read -rp "Header value: " hvalue; }
    [[ -z "$hname" || -z "$hvalue" ]] && { warn "Имя и значение обязательны."; return; }

    if [[ ! "$hname" =~ ^[a-zA-Z0-9!#\$%\&\'*+\-.^_\`|~]+$ ]]; then
        warn "Некорректное имя заголовка."
        return 1
    fi
    if [[ "$hvalue" =~ $'\r' || "$hvalue" =~ $'\n' ]]; then
        warn "Значение не может содержать переводы строк."
        return 1
    fi
    if [[ "$hvalue" =~ \\$ ]]; then
        warn "Значение не может оканчиваться на \\."
        return 1
    fi

    jq_w --arg g "$group" --arg hn "$hname" --arg hv "$hvalue" '
        (.groups[] | select(.name==$g)).subscription_headers =
            (((.groups[] | select(.name==$g)).subscription_headers // [])
            | [.[] | select(.name != $hn)] + [{name: $hn, value: $hv}])
    '
    success "Header установлен: $hname: $hvalue (группа: $group)"
    info "Запустите 'Обновить все подписки' чтобы применить."
}

subscription_group_del_header() {
    local group="$1" hname="$2"
    [[ -z "$group" ]] && { _select_group "Удалить групповой header" group || return; }
    [[ -z "$hname" ]] && { read -rp "Header name: " hname; }
    [[ -z "$hname" ]] && { warn "Имя обязательно."; return; }

    jq_w --arg g "$group" --arg hn "$hname" '
        (.groups[] | select(.name==$g)).subscription_headers =
            (((.groups[] | select(.name==$g)).subscription_headers // [])
            | [.[] | select(.name != $hn)])
    '
    success "Header удалён: $hname (группа: $group)"
    info "Запустите 'Обновить все подписки' чтобы применить."
}

subscription_show_resolved() {
    local client="$1"
    [[ -z "$client" ]] && { _select_client "Показать resolved headers" client || return; }

    echo ""
    echo -e "  ${CYAN}Headers (resolved) — ${client}:${NC}"

    local found=0
    while IFS='|' read -r value name source; do
        [[ -z "$name" ]] && continue
        found=1
        local tag
        case "$source" in
            client)
                tag="${YELLOW}[client override]${NC}" ;;
            group)
                local group
                group=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .group // empty')
                tag="${DIM}[group: $group]${NC}" ;;
            default)
                tag="${DIM}[default]${NC}" ;;
            *)
                tag="${DIM}[?]${NC}" ;;
        esac
        printf "  %-20s %-30s %b\n" "$name:" "$value" "$tag"
    done < <(_resolve_headers_annotated "$client")

    [[ "$found" -eq 0 ]] && echo -e "  ${DIM}Нет хедеров${NC}"
}

# ─── Хелперы: выбор клиента/группы ─────────────────────────────────────────

_select_client() {
    local label="$1"
    local -n _result=$2
    echo ""
    echo -e "  ${CYAN}── ${label} ──${NC}"

    local clients=()
    mapfile -t clients < <(jq_r '.clients[].name')
    [[ ${#clients[@]} -eq 0 ]] && { warn "Нет клиентов."; return 1; }

    local i=1
    for c in "${clients[@]}"; do
        echo -e "  ${GREEN}${i})${NC} $c"
        i=$((i + 1))
    done
    echo ""
    read -rp "  Выберите: " idx
    _result="${clients[$((idx - 1))]}"
    [[ -z "$_result" ]] && { warn "Неверный выбор."; return 1; }
    return 0
}

_select_client_with_sub() {
    local label="$1"
    local -n _result=$2
    echo ""
    echo -e "  ${CYAN}── ${label} ──${NC}"

    local clients=()
    mapfile -t clients < <(jq_r '.clients[] | select(.subscription.token) | .name')
    [[ ${#clients[@]} -eq 0 ]] && { warn "Нет клиентов с подписками."; return 1; }

    local i=1
    for c in "${clients[@]}"; do
        echo -e "  ${GREEN}${i})${NC} $c"
        i=$((i + 1))
    done
    echo ""
    read -rp "  Выберите: " idx
    _result="${clients[$((idx - 1))]}"
    [[ -z "$_result" ]] && { warn "Неверный выбор."; return 1; }
    return 0
}

_select_group() {
    local label="$1"
    local -n _result=$2
    echo ""
    echo -e "  ${CYAN}── ${label} ──${NC}"

    local groups=()
    mapfile -t groups < <(jq_r '.groups[].name')
    [[ ${#groups[@]} -eq 0 ]] && { warn "Нет групп."; return 1; }

    local i=1
    for g in "${groups[@]}"; do
        echo -e "  ${GREEN}${i})${NC} $g"
        i=$((i + 1))
    done
    echo ""
    read -rp "  Выберите: " idx
    _result="${groups[$((idx - 1))]}"
    [[ -z "$_result" ]] && { warn "Неверный выбор."; return 1; }
    return 0
}

# ─── Авторефреш после генерации (вызывается из generate.sh) ────────────────

_subscription_prompt_refresh() {
    local host_node
    host_node=$(jq_r '.subscription_host.node // empty')
    [[ -z "$host_node" ]] && return

    local gen_count
    gen_count=$(find "$GENERATED_DIR" -type f -name config.yaml 2>/dev/null | wc -l)
    [[ $gen_count -eq 0 ]] && return

    echo ""
    if confirm_yn "Опубликовать подписки для $gen_count клиентов?"; then
        subscription_publish_all
    fi
}

# ─── Меню ───────────────────────────────────────────────────────────────────

subscription_menu() {
    _ensure_default_headers
    while true; do
        echo ""
        box_top
        box_center "Subscriptions"
        box_bot
        echo ""

        local host_node
        host_node=$(jq_r '.subscription_host.node // empty')
        if [[ -n "$host_node" ]]; then
            local base_url
            base_url=$(jq_r '.subscription_host.base_url // empty')
            echo -e "  Host: ${GREEN}${host_node}${NC} (${base_url})"
        else
            echo -e "  ${DIM}Host-нода не задана${NC}"
        fi
        echo ""

        echo -e "  ${GREEN}1)${NC} Выбрать host-ноду"
        echo -e "  ${GREEN}2)${NC} Опубликовать подписку"
        echo -e "  ${GREEN}3)${NC} Обновить все подписки"
        echo -e "  ${GREEN}4)${NC} Показать подписку"
        echo -e "  ${GREEN}5)${NC} Список подписок"
        echo -e "  ${YELLOW}6)${NC} Сменить токен подписки"
        echo -e "  ${RED}7)${NC} Отозвать подписку"
        echo -e "  ${CYAN}8)${NC} Миграция на другую ноду"
        echo ""
        echo -e "  ${DIM}── Headers ──${NC}"
        echo -e "  ${GREEN}h)${NC} Header клиента (set/del)"
        echo -e "  ${GREEN}g)${NC} Header группы (set/del)"
        echo -e "  ${GREEN}r)${NC} Показать resolved headers"
        echo ""
        echo -e "  ${NC}0)${NC} Назад"
        echo ""
        read -rp "  Выберите: " CHOICE

        case "$CHOICE" in
            1) subscription_set_host ;;
            2) subscription_publish "" ;;
            3) subscription_publish_all ;;
            4) subscription_show "" ;;
            5) subscription_list ;;
            6) subscription_rotate "" ;;
            7) subscription_revoke "" ;;
            8) subscription_migrate ;;
            h|H)
                echo -e "  ${GREEN}1)${NC} Установить header"
                echo -e "  ${RED}2)${NC} Удалить header"
                read -rp "  Выберите: " hc
                case "$hc" in
                    1) subscription_set_header "" "" "" ;;
                    2) subscription_del_header "" "" ;;
                    *) warn "Неверный выбор." ;;
                esac
                ;;
            g|G)
                echo -e "  ${GREEN}1)${NC} Установить header"
                echo -e "  ${RED}2)${NC} Удалить header"
                read -rp "  Выберите: " hc
                case "$hc" in
                    1) subscription_group_set_header "" "" "" ;;
                    2) subscription_group_del_header "" "" ;;
                    *) warn "Неверный выбор." ;;
                esac
                ;;
            r|R) subscription_show_resolved "" ;;
            0) return ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}
