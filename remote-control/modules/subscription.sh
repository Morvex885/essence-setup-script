#!/bin/bash
# ─── Управление подписками (subscription hosting) ──────────────────────────

# ─── SSH context save/restore ───────────────────────────────────────────────

_sub_save_ssh_ctx() {
    _SAVE_NODE_ID="${NODE_ID:-}" _SAVE_NODE_NAME="$NODE_NAME"
    _SAVE_NODE_IDENTITY="${NODE_IDENTITY:-}" _SAVE_NODE_TAG="${NODE_TAG:-}"
    _SAVE_SERVER_IP="$SERVER_IP" _SAVE_SERVER_PORT="$SERVER_PORT"
    _SAVE_SERVER_USER="$SERVER_USER" _SAVE_SERVER_PASS="$SERVER_PASS"
    _SAVE_SERVER_AUTH="$SERVER_AUTH"
}

_sub_restore_ssh_ctx() {
    NODE_ID="$_SAVE_NODE_ID" NODE_NAME="$_SAVE_NODE_NAME"
    NODE_IDENTITY="$_SAVE_NODE_IDENTITY" NODE_TAG="$_SAVE_NODE_TAG"
    SERVER_IP="$_SAVE_SERVER_IP" SERVER_PORT="$_SAVE_SERVER_PORT"
    SERVER_USER="$_SAVE_SERVER_USER" SERVER_PASS="$_SAVE_SERVER_PASS"
    SERVER_AUTH="$_SAVE_SERVER_AUTH"
}

_sub_load_host() {
    local host_node
    host_node=$(jq_r '.subscription_host.node // empty')
    [[ -z "$host_node" ]] && { warn "Хост-нода подписок не задана. Используйте пункт «Выбрать хост-ноду»."; return 1; }
    _sub_save_ssh_ctx
    node_load_by_name "$host_node" || { _sub_restore_ssh_ctx; warn "Нода '$host_node' не найдена."; return 1; }

    local rc=0
    ssh_run -- "test -f /etc/mihomo/subscription.conf" 2>/dev/null || rc=$?
    if [[ $rc -ne 0 ]]; then
        _sub_restore_ssh_ctx
        if [[ $rc -eq 1 ]]; then
            warn "На ноде '$host_node' не установлен хостинг подписок."
        else
            warn "Хост-нода подписок недоступна."
        fi
        return 1
    fi
}

# Записывает дефолтные subscription headers если их ещё нет в config.json.
# Вызывается перед публикацией/ротацией и из subscription_menu, но не при отзыве.
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
    local d conf
    d=$(jq_r '.subscription_host.sub_dir // empty')
    if [[ -n "$d" ]]; then echo "$d"; return 0; fi
    conf=$(ssh_run -- "grep '^SUB_DIR=' /etc/mihomo/subscription.conf 2>/dev/null") || return 1
    d=$(printf '%s\n' "$conf" | cut -d= -f2-)
    [[ -n "$d" ]] || return 1
    echo "$d"
}

_sub_get_nginx_group() {
    local g
    g=$(jq_r '.subscription_host.nginx_group // empty')
    if [[ -n "$g" ]]; then echo "$g"; return; fi
    g=$(ssh_run -- "grep '^NGINX_GROUP=' /etc/mihomo/subscription.conf 2>/dev/null | cut -d= -f2-")
    echo "${g:-www-data}"
}

_subscription_config_ready() {
    local path="${1:-}"
    [[ -f "$path" && -r "$path" ]] || return 1
    grep -q '[^[:space:]]' "$path"
}

_sub_upload_config() {
    local src="$1" token="$2" sub_dir="$3" nginx_group="${4:-www-data}" client="${5:-}"
    if ! _subscription_config_ready "$src"; then
        warn "YAML-конфигурация отсутствует или пуста — загрузка отменена."
        return 1
    fi
    local snippets_dir="$SUB_SNIPPETS_DIR"
    local yaml_tmp="${sub_dir}/.${token}.yaml.tmp"
    local yaml_dst="${sub_dir}/${token}.yaml"
    local snip_tmp="${snippets_dir}/.sub-${token}.conf.tmp"
    local snip_dst="${snippets_dir}/sub-${token}.conf"
    local label="${client:-подписки}"

    # Локально рендерим snippet (если client указан)
    local snip_local=""
    if [[ -n "$client" ]]; then
        snip_local=$(umask 077; mktemp) || return 1
        _render_subscription_snippet "$client" "$token" "$sub_dir" > "$snip_local" || { rm -f "$snip_local"; return 1; }
    fi

    if ! scp_run "$src" "${SERVER_USER}@${SERVER_IP}:${yaml_tmp}" >/dev/null 2>&1; then
        [[ -n "$snip_local" ]] && rm -f "$snip_local"
        warn "Не удалось загрузить YAML-конфигурацию для ${label}."
        return 1
    fi

    if [[ -n "$snip_local" ]]; then
        if ! scp_run "$snip_local" "${SERVER_USER}@${SERVER_IP}:${snip_tmp}" >/dev/null 2>&1; then
            rm -f "$snip_local"
            ssh_run -- "rm -f '${yaml_tmp}'" >/dev/null 2>&1
            warn "Не удалось загрузить фрагмент конфигурации для ${label}."
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

    if ! ssh_run -- "$ssh_cmd" >/dev/null 2>&1; then
        ssh_run -- "rm -f '${yaml_tmp}' '${snip_tmp}'" >/dev/null 2>&1
        warn "Не удалось применить конфигурацию для ${label} (проверка nginx, права или перезагрузка)."
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

    local i=0
    while [[ $i -lt ${#triplets[@]} ]]; do
        local src="${triplets[$i]}"
        if ! _subscription_config_ready "$src"; then
            warn "YAML-конфигурация отсутствует или пуста — загрузка отменена."
            return 1
        fi
        i=$((i + 3))
    done

    local snippets_dir="$SUB_SNIPPETS_DIR"
    local yaml_tmp_dir snip_tmp_dir
    yaml_tmp_dir=$(umask 077; mktemp -d) || return 1
    snip_tmp_dir=$(umask 077; mktemp -d) || { rm -rf "$yaml_tmp_dir"; return 1; }

    local tokens=()
    i=0
    while [[ $i -lt ${#triplets[@]} ]]; do
        local src="${triplets[$i]}" token="${triplets[$((i+1))]}" client="${triplets[$((i+2))]}"
        if ! cp "$src" "$yaml_tmp_dir/.${token}.yaml.tmp" 2>/dev/null ||
            ! _render_subscription_snippet "$client" "$token" "$sub_dir" > "$snip_tmp_dir/.sub-${token}.conf.tmp"; then
            rm -rf "$yaml_tmp_dir" "$snip_tmp_dir"
            warn "$client: не удалось подготовить конфигурацию подписки."
            return 1
        fi
        tokens+=("$token")
        i=$((i + 3))
    done

    if ! scp_run "$yaml_tmp_dir"/.*.yaml.tmp "${SERVER_USER}@${SERVER_IP}:${sub_dir}/" >/dev/null 2>&1; then
        rm -rf "$yaml_tmp_dir" "$snip_tmp_dir"
        warn "Не удалось загрузить пакет YAML-конфигураций."
        return 1
    fi
    if ! scp_run "$snip_tmp_dir"/.sub-*.conf.tmp "${SERVER_USER}@${SERVER_IP}:${snippets_dir}/" >/dev/null 2>&1; then
        rm -rf "$yaml_tmp_dir" "$snip_tmp_dir"
        ssh_run -- "rm -f ${sub_dir}/.*.yaml.tmp" >/dev/null 2>&1
        warn "Не удалось загрузить пакет фрагментов конфигурации."
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

    if ! ssh_run -- "$ssh_cmd" >/dev/null 2>&1; then
        ssh_run -- "rm -f ${sub_dir}/.*.yaml.tmp ${snippets_dir}/.sub-*.conf.tmp" >/dev/null 2>&1
        warn "Не удалось применить пакет конфигураций (проверка nginx, права или перезагрузка)."
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
        warn "Проверка HTTP: ${code:-нет ответа} (ожидалось 200). Проверьте журнал ошибок nginx на сервере."
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
    node_pick "Хостинг подписок — выбор ноды" || return 1
    _sub_save_ssh_ctx
    node_load "$NODE_PICK_INDEX" || { _sub_done; return 1; }
    local sel="$NODE_NAME" remote_conf
    if ! remote_conf=$(ssh_run -- "cat /etc/mihomo/subscription.conf 2>/dev/null"); then
        _sub_done
        warn "Хост-нода подписок недоступна."
        return 1
    fi
    _sub_done
    [[ -n "$remote_conf" ]] || { warn "На ноде '$sel' не установлен хостинг подписок."; return 1; }
    local base_url sub_dir nginx_group
    base_url=$(echo "$remote_conf" | grep '^SUB_BASE_URL=' | cut -d= -f2-)
    sub_dir=$(echo "$remote_conf" | grep '^SUB_DIR=' | cut -d= -f2-)
    nginx_group=$(echo "$remote_conf" | grep '^NGINX_GROUP=' | cut -d= -f2-)
    [[ -n "$base_url" && -n "$sub_dir" ]] || { warn "Конфигурация хостинга подписок неполна."; return 1; }
    jq_w --arg n "$sel" --arg u "$base_url" --arg d "$sub_dir" --arg g "${nginx_group:-www-data}" \
        '.subscription_host = {node: $n, base_url: $u, sub_dir: $d, nginx_group: $g}' || return 1
    success "Хост-нода подписок: $sel ($base_url)"
}

subscription_publish() {
    local client="${1:-}" ttl="${2:-}" output_mode="${3:-share}"
    case "$output_mode" in
        share|status) ;;
        *) warn "Неверный режим вывода подписки."; return 1 ;;
    esac
    [[ -z "$client" ]] && { _select_client "Опубликовать подписку" || return 1; client="$SUBSCRIPTION_SELECT_RESULT"; }

    # Проверяем что клиент существует
    local client_group
    client_group=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .group // empty')
    [[ -z "$client_group" ]] && { warn "Клиент '$client' не найден."; return; }

    # Генерируем конфиг если нет или он пуст
    local config_file
    config_file=$(_client_config_file "$client")
    if ! _subscription_config_ready "$config_file"; then
        warn "Конфиг для '$client' не найден или пуст. Сначала сгенерируйте конфиги."
        return
    fi

    # Проверяем host
    local host_node base_url
    host_node=$(jq_r '.subscription_host.node // empty')
    base_url=$(jq_r '.subscription_host.base_url // empty')
    [[ -z "$host_node" ]] && { warn "Хост-нода подписок не задана. Используйте пункт «Выбрать хост-ноду»."; return; }

    # Токен: новый или существующий
    local token
    token=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.token // empty')
    if [[ -z "$token" ]]; then
        token=$(openssl rand -hex 32) || return 1
        [[ -n "$token" ]] || return 1
    fi

    # Загружаем на сервер
    _ensure_default_headers || return 1
    _sub_load_host || return

    local sub_dir nginx_group
    sub_dir=$(_sub_get_dir) || { _sub_done; return 1; }
    nginx_group=$(_sub_get_nginx_group)

    local rc=0 metadata_failed=false
    _sub_upload_config "$config_file" "$token" "$sub_dir" "$nginx_group" "$client" || rc=1

    # TTL → expiry.list
    if [[ $rc -eq 0 && -n "$ttl" ]]; then
        local expires_at expires_ts
        expires_ts=$(date -d "+${ttl}" +%s 2>/dev/null) || { _sub_done; warn "Неверный формат TTL: $ttl"; return; }
        expires_at=$(date -d "+${ttl}" --iso-8601=seconds 2>/dev/null)
        ssh_run -- "flock ${sub_dir}/.expiry.lock bash -c 'echo \"${token} ${expires_ts}\" >> ${sub_dir}/expiry.list'" || rc=1
        if [[ $rc -eq 0 ]]; then
            jq_w --arg n "$client" --arg t "$token" --arg e "$expires_at" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
                '(.clients[] | select(.name==$n)).subscription |= ((. // {}) + {token: $t, expires_at: $e, created_at: $ts})' || { rc=1; metadata_failed=true; }
        fi
    elif [[ $rc -eq 0 ]]; then
        jq_w --arg n "$client" --arg t "$token" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            '(.clients[] | select(.name==$n)).subscription |= ((. // {}) + {token: $t, expires_at: null, created_at: $ts})' || { rc=1; metadata_failed=true; }
    fi

    _sub_done

    if [[ $rc -eq 0 ]]; then
        success "Подписка опубликована: $client"
        _sub_verify_http "$token" || return 1
        if [[ "$output_mode" == share ]]; then _show_share_bundle "$client"; fi
    elif $metadata_failed; then
        warn "Файл загружен на сервер, но данные подписки сохранить не удалось. Публикация не завершена."
    else
        warn "Ошибка загрузки файла на сервер."
    fi
    return "$rc"
}

subscription_revoke() {
    local client="$1"
    [[ -z "$client" ]] && { _select_client_with_sub "Отозвать подписку" || return; client="$SUBSCRIPTION_SELECT_RESULT"; }

    local token
    token=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.token // empty')
    [[ -z "$token" ]] && { warn "У клиента '$client' нет подписки."; return; }

    local host_node
    host_node=$(jq_r '.subscription_host.node // empty')
    review_frame "Отзыв подписки" "Клиент: $client" "Хост-нода: $host_node" \
        "Ссылка перестанет работать; конфиг клиента сохранится."
    confirm_yn "Отозвать подписку?" N || return 0

    _subscription_revoke_silent "$client"
}

# Удаление под expiry-lock: при сбое восстанавливаются файлы, expiry и nginx.
# SUB_REMOVE_TOKEN_STATE разрешает очистку замены только после подтверждённого отката.
# Не выводим диагностику SSH/команд: пути в ней содержат токены.
_sub_remove_token() {
    local token="$1" sub_dir="$2" replacement="${3:-}" script command response rc=0
    SUB_REMOVE_TOKEN_STATE=unknown
    script=$(cat <<'EOF'
token=$1 sub_dir=$2 snippets_dir=$3 replacement=$4
yaml="$sub_dir/$token.yaml"
snippet="$snippets_dir/sub-$token.conf"
expiry="$sub_dir/expiry.list"
backup=
yaml_saved=false snippet_saved=false expiry_saved=false
pending=false
rollback() {
    files=restored expiry_state=restored nginx_state=restored
    if $yaml_saved; then cp -p "$backup/yaml" "$yaml" || files=uncertain
    else rm -f "$yaml" || files=uncertain; fi
    if $snippet_saved; then cp -p "$backup/snippet" "$snippet" || files=uncertain
    else rm -f "$snippet" || files=uncertain; fi
    if $expiry_saved; then cp -p "$backup/expiry" "$expiry" || expiry_state=uncertain
    else rm -f "$expiry" || expiry_state=uncertain; fi
    if ! nginx -t; then nginx_state=uncertain
    elif ! systemctl reload nginx; then nginx_state=uncertain; fi
    if [ "$files:$expiry_state:$nginx_state" = restored:restored:restored ]; then
        result=unchanged
        if $yaml_saved && $snippet_saved && [ -s "$yaml" ] && [ -s "$snippet" ]; then result=restored; fi
        rm -rf "$backup"
    else
        result="uncertain:$files:$expiry_state:$nginx_state"
        # Keep private backups for manual recovery, and never remove a replacement.
    fi
}
abort() {
    trap - EXIT HUP INT TERM
    if $pending; then
        rollback >/dev/null 2>&1
        printf '%s\n' "$result"
    else
        [ -z "$backup" ] || rm -rf "$backup" >/dev/null 2>&1
        printf '%s\n' unchanged
    fi
    exit 1
}
trap abort EXIT
trap 'exit 1' HUP INT TERM
prepare() {
    umask 077
    exec 9>"$sub_dir/.expiry.lock" || return 1
    flock -x 9 || return 1
    backup=$(mktemp -d "$sub_dir/.subscription-remove.XXXXXX") || return 1
    if [ -e "$yaml" ]; then cp -p "$yaml" "$backup/yaml" || return 1; yaml_saved=true; fi
    if [ -e "$snippet" ]; then cp -p "$snippet" "$backup/snippet" || return 1; snippet_saved=true; fi
    if [ -e "$expiry" ]; then cp -p "$expiry" "$backup/expiry" || return 1; expiry_saved=true; fi
}
remove() {
    rm -f "$yaml" "$snippet" || return 1
    if $expiry_saved; then
        if [ -n "$replacement" ]; then
            sed -i "s/^${token} /${replacement} /" "$expiry" || return 1
        else
            sed -i "/^${token} /d" "$expiry" || return 1
        fi
    fi
    nginx -t || return 1
    systemctl reload nginx || return 1
    test ! -e "$yaml" && test ! -e "$snippet"
}
prepare >/dev/null 2>&1 || exit 1
pending=true
remove >/dev/null 2>&1 || exit 1
trap - EXIT HUP INT TERM
rm -rf "$backup" >/dev/null 2>&1
printf '%s\n' removed
EOF
)
    printf -v command 'bash -c %q -- %q %q %q %q' "$script" "$token" "$sub_dir" "$SUB_SNIPPETS_DIR" "$replacement"
    response=$(ssh_run -- "$command" 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
        SUB_REMOVE_TOKEN_STATE=removed
        return 0
    fi
    case "$response" in
        restored|unchanged) SUB_REMOVE_TOKEN_STATE="$response" ;;
        uncertain:restored:restored:uncertain)
            SUB_REMOVE_TOKEN_STATE=uncertain
            warn "Файлы подписки и срок восстановлены; применение nginx не подтверждено. Резервная копия сохранена в каталоге подписок."
            ;;
        uncertain:*)
            SUB_REMOVE_TOKEN_STATE=uncertain
            local protocol files expiry_state nginx_state
            IFS=: read -r protocol files expiry_state nginx_state <<< "$response"
            [[ "$files" == restored ]] && files="восстановлены" || files="не подтверждены"
            [[ "$expiry_state" == restored ]] && expiry_state="восстановлен" || expiry_state="не подтверждён"
            [[ "$nginx_state" == restored ]] && nginx_state="применён" || nginx_state="не подтверждён"
            warn "Восстановление подписки: файлы — $files; срок — $expiry_state; nginx — $nginx_state. Резервная копия сохранена в каталоге подписок."
            ;;
        *) warn "Удалённое состояние подписки неизвестно: результат восстановления не получен." ;;
    esac
    return 1
}

# Тихий отзыв для удаления клиента: при сбое локальные данные остаются целы.
_subscription_revoke_silent() {
    local client="$1" token sub_dir rc=0
    token=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.token // empty')
    [[ -z "$token" ]] && return 0
    if ! _sub_load_host; then
        warn "Подписка '$client' не отозвана: ссылка может оставаться действующей."
        return 1
    fi
    sub_dir=$(_sub_get_dir) || { _sub_done; warn "Подписка '$client' не отозвана: ссылка может оставаться действующей."; return 1; }
    _sub_remove_token "$token" "$sub_dir" || rc=1
    _sub_done
    if [[ $rc -ne 0 ]]; then
        warn "Подписка '$client' не отозвана: ссылка может оставаться действующей."
        return 1
    fi
    jq_w --arg n "$client" '(.clients[] | select(.name==$n)) |= del(.subscription.token, .subscription.expires_at, .subscription.created_at)' || return 1
    success "Подписка отозвана: $client"
    return 0
}

subscription_rotate() {
    local client="${1:-}"
    [[ -z "$client" ]] && { _select_client_with_sub "Сменить токен подписки" || return 1; client="$SUBSCRIPTION_SELECT_RESULT"; }
    local old_token config_file host_node
    old_token=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.token // empty')
    [[ -n "$old_token" ]] || { warn "У клиента '$client' нет подписки."; return 1; }
    config_file=$(_client_config_file "$client")
    _subscription_config_ready "$config_file" || { warn "Конфиг для '$client' не найден или пуст."; return 1; }
    host_node=$(jq_r '.subscription_host.node // empty')
    _ensure_default_headers || return 1
    _sub_load_host || return 1
    local sub_dir nginx_group new_token
    sub_dir=$(_sub_get_dir) || { _sub_done; return 1; }
    nginx_group=$(_sub_get_nginx_group)
    _sub_done
    review_frame "Смена токена подписки" "Клиент: $client" "Хост-нода: $host_node" \
        "Старая ссылка перестанет работать; новая ссылка будет показана после завершения."
    confirm_yn "Сменить токен подписки?" N || return 0
    new_token=$(openssl rand -hex 32) || return 1
    [[ -n "$new_token" ]] || return 1
    _sub_save_ssh_ctx
    node_load_by_name "$host_node" || { _sub_done; return 1; }
    if ! _sub_upload_config "$config_file" "$new_token" "$sub_dir" "$nginx_group" "$client"; then
        _sub_done
        return 1
    fi
    if ! _sub_remove_token "$old_token" "$sub_dir" "$new_token"; then
        if [[ "$SUB_REMOVE_TOKEN_STATE" == restored ]]; then
            if ! _sub_remove_token "$new_token" "$sub_dir"; then
                warn "Старая подписка восстановлена; удаление новой копии не подтверждено."
            fi
        else
            warn "Новая подписка сохранена на хосте: доступность старой ссылки не подтверждена. Локально остался старый токен; перед повтором проверьте хост-ноду."
        fi
        _sub_done
        warn "Смена токена не завершена: удаление старой ссылки не подтверждено."
        return 1
    fi
    _sub_done
    if ! jq_w --arg n "$client" --arg t "$new_token" '(.clients[] | select(.name==$n)).subscription.token = $t'; then
        warn "Старый токен удалён, но новый токен не удалось сохранить локально. Смена токена не завершена."
        return 1
    fi
    success "Токен обновлён: $client"
    _sub_verify_http "$new_token" || return 1
    _show_share_bundle "$client"
}

subscription_show() {
    local client="$1"
    [[ -z "$client" ]] && { _select_client_with_sub "Показать подписку" || return; client="$SUBSCRIPTION_SELECT_RESULT"; }

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
        echo -e "  ${YELLOW}Срок действия:${NC} $expires_at"
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
    echo -e "  ${DIM}Данные в JSON${NC}"
    jq -n --arg url "$url" '{url: $url}'

    # QR
    if command -v qrencode &>/dev/null; then
        echo ""
        qrencode -t UTF8 "$url"
    fi
}

subscription_list() {
    local host_node name expires_at found=0 now_ts
    host_node=$(jq_r '.subscription_host.node // empty')
    now_ts=$(date +%s)
    echo ""
    box_top
    box_center "Подписки"
    box_mid
    box_line " Хост-нода: ${host_node:-не задана}"
    box_mid
    while IFS='|' read -r name expires_at; do
        [[ -n "$name" ]] || continue
        found=1
        local state="действует" term="без срока" color="$GREEN" exp_ts
        if [[ -n "$expires_at" ]]; then
            term="$expires_at"
            if ! exp_ts=$(date -d "$expires_at" +%s 2>/dev/null); then
                state="срок неизвестен"; color="$YELLOW"
            elif [[ "$exp_ts" -le "$now_ts" ]]; then
                state="истекла"; color="$YELLOW"
            fi
        fi
        box_line " $name — $term; $state" " $name — $term; ${color}${state}${NC}"
    done < <(jq_r '.clients[] | select(.subscription.token) | "\(.name)|\(.subscription.expires_at // "")"')
    [[ $found -eq 0 ]] && box_line " Нет опубликованных подписок" " ${DIM}Нет опубликованных подписок${NC}"
    box_bot
    echo ""
}

subscription_publish_all() {
    local host_node
    host_node=$(jq_r '.subscription_host.node // empty')
    [[ -z "$host_node" ]] && { warn "Хост-нода подписок не задана."; return; }

    local all_clients=()
    while IFS= read -r client_name; do
        all_clients+=("$client_name")
    done < <(jq_r '.clients[].name')

    local triplets=() ok=0 new_tokens=() skipped=0 published=() rc=0
    for client in "${all_clients[@]}"; do
        local config_file
        config_file=$(_client_config_file "$client")
        if ! _subscription_config_ready "$config_file"; then
            skipped=$((skipped + 1))
            info "$client: пропущено — конфиг отсутствует или пуст"
            continue
        fi

        local token
        token=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.token // empty')
        if [[ -z "$token" ]]; then
            token=$(openssl rand -hex 32) || { warn "$client: публикация не подтверждена"; return 1; }
            [[ -n "$token" ]] || { warn "$client: публикация не подтверждена"; return 1; }
            new_tokens+=("$client" "$token")
        fi
        triplets+=("$config_file" "$token" "$client")
        published+=("$client")
        ok=$((ok + 1))
    done

    if [[ ${#triplets[@]} -eq 0 ]]; then
        info "Нет конфигов для публикации."
        [[ $skipped -gt 0 ]] && info "Пропущено (конфиг отсутствует или пуст): $skipped"
        return
    fi

    _ensure_default_headers || return 1
    _sub_load_host || return

    local sub_dir nginx_group
    sub_dir=$(_sub_get_dir) || { _sub_done; return 1; }
    nginx_group=$(_sub_get_nginx_group)

    if _sub_upload_batch "$sub_dir" "$nginx_group" "${triplets[@]}"; then
        # Сохраняем токены новых клиентов
        local i=0
        while [[ $i -lt ${#new_tokens[@]} ]]; do
            local c="${new_tokens[$i]}" t="${new_tokens[$((i+1))]}"
            jq_w --arg n "$c" --arg t "$t" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
                '(.clients[] | select(.name==$n)).subscription |= ((. // {}) + {token: $t, expires_at: null, created_at: $ts})' || { rc=1; break; }
            i=$((i + 2))
        done
        if [[ $rc -ne 0 ]]; then
            _sub_done
            for client in "${published[@]}"; do warn "$client: публикация не подтверждена"; done
            warn "Файлы загружены пакетно; сохранение токенов завершено частично. Дальнейшие записи и очистка старых файлов остановлены."
            return 1
        fi
        for client in "${published[@]}"; do success "$client: опубликовано"; done
        success "Опубликовано: $ok"
        info "Пропущено (конфиг отсутствует или пуст): $skipped"
        info "Ошибка: 0"

        # Удаление осиротевших yaml и snippets после успешного сохранения токенов.
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
            info "Удалено осиротевших подписок: $removed"
        fi
    else
        for client in "${published[@]}"; do warn "$client: публикация не подтверждена"; done
        info "Опубликовано: 0; пропущено: $skipped; ошибка: $ok"
        rc=1
    fi

    _sub_done
    return "$rc"
}

subscription_migrate() {
    local old_node old_base_url new_node new_conf old_conf
    old_node=$(jq_r '.subscription_host.node // empty')
    old_base_url=$(jq_r '.subscription_host.base_url // empty')
    [[ -n "$old_node" ]] || { warn "Хост-нода подписок не задана."; return 1; }
    MENU_SELECT_CONTEXT=("Текущая хост-нода: $old_node")
    node_pick "Перенос подписок" || return 1
    new_node=$(jq_r --argjson i "$((NODE_PICK_INDEX - 1))" '.nodes[$i].name')
    [[ "$new_node" != "$old_node" ]] || { info "Выбрана текущая хост-нода. Перенос не выполнен."; return 1; }
    local clients=() tokens=() configs=() client token config_file
    while IFS='|' read -r client token; do
        [[ -n "$token" ]] || continue
        config_file=$(_client_config_file "$client")
        if ! _subscription_config_ready "$config_file"; then
            warn "$client: конфиг отсутствует или пуст. Перенос отменён."
            return 1
        fi
        clients+=("$client"); tokens+=("$token"); configs+=("$config_file")
    done < <(jq_r '.clients[] | select(.subscription.token) | "\(.name)|\(.subscription.token)"')
    [[ ${#clients[@]} -gt 0 ]] || { info "Нет опубликованных подписок для переноса."; return 0; }
    _sub_save_ssh_ctx
    node_load_by_name "$old_node" || { _sub_done; return 1; }
    if ! old_conf=$(ssh_run -- "cat /etc/mihomo/subscription.conf 2>/dev/null"); then
        _sub_done; warn "Хост-нода подписок недоступна."; return 1
    fi
    node_load_by_name "$new_node" || { _sub_done; return 1; }
    if ! new_conf=$(ssh_run -- "cat /etc/mihomo/subscription.conf 2>/dev/null"); then
        _sub_done; warn "Новая хост-нода подписок недоступна."; return 1
    fi
    _sub_done
    local old_sub_dir new_sub_dir new_base_url new_nginx_group
    old_sub_dir=$(echo "$old_conf" | grep '^SUB_DIR=' | cut -d= -f2-)
    new_sub_dir=$(echo "$new_conf" | grep '^SUB_DIR=' | cut -d= -f2-)
    new_base_url=$(echo "$new_conf" | grep '^SUB_BASE_URL=' | cut -d= -f2-)
    new_nginx_group=$(echo "$new_conf" | grep '^NGINX_GROUP=' | cut -d= -f2-)
    [[ -n "$old_sub_dir" && -n "$new_sub_dir" && -n "$new_base_url" ]] || {
        warn "Конфигурация хостинга подписок неполна. Перенос отменён."; return 1;
    }
    review_frame "Перенос подписок" "Старая хост-нода: $old_node" "Базовый URL: $old_base_url" \
        "Новая хост-нода: $new_node" "Базовый URL: $new_base_url" "${clients[@]}" \
        "Все адреса подписок изменятся." "Старые ссылки будут удалены только после загрузки всех подписок."
    confirm_yn "Перенести подписки?" N || return 0
    _sub_save_ssh_ctx
    node_load_by_name "$new_node" || { _sub_done; return 1; }
    local i rc=0
    for ((i=0; i<${#clients[@]}; i++)); do
        _sub_upload_config "${configs[$i]}" "${tokens[$i]}" "$new_sub_dir" "${new_nginx_group:-www-data}" "${clients[$i]}" || rc=1
    done
    _sub_done
    if [[ $rc -ne 0 ]]; then
        warn "Перенос не завершён: старый хост и старые ссылки сохранены."
        warn "На новой ноде могли остаться копии подписок."
        return 1
    fi
    jq_w --arg n "$new_node" --arg u "$new_base_url" --arg d "$new_sub_dir" --arg g "${new_nginx_group:-www-data}" \
        '.subscription_host = {node: $n, base_url: $u, sub_dir: $d, nginx_group: $g}' || return 1
    _sub_save_ssh_ctx
    if node_load_by_name "$old_node"; then
        for token in "${tokens[@]}"; do _sub_remove_token "$token" "$old_sub_dir" || rc=1; done
    else
        rc=1
    fi
    _sub_done
    if [[ $rc -ne 0 ]]; then
        warn "Подписки перенесены, но старые ссылки не удалось полностью удалить. Требуется очистка старой ноды."
        return 1
    fi
    success "Перенесено ${#clients[@]} подписок на '$new_node'"
    info "Новый базовый URL: $new_base_url"
    return 0
}

# ─── Управление хедерами ───────────────────────────────────────────────────

subscription_set_header() {
    local client="$1" hname="$2" hvalue="$3"
    [[ -z "$client" ]] && { _select_client "Добавить заголовок" || return; client="$SUBSCRIPTION_SELECT_RESULT"; }
    [[ -z "$hname" ]] && { IFS= read -rp "  Имя заголовка: " hname || return 1; hname="${hname%$'\r'}"; }
    [[ -z "$hvalue" ]] && { IFS= read -rp "  Значение заголовка: " hvalue || return 1; hvalue="${hvalue%$'\r'}"; }
    [[ -z "$hname" || -z "$hvalue" ]] && { warn "Имя и значение обязательны."; return; }

    # Валидация: RFC 7230 token chars для имени
    if [[ ! "$hname" =~ ^[a-zA-Z0-9!#\$%\&\'*+.^_\`|~-]+$ ]]; then
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
    ' || return 1
    success "Заголовок установлен: $hname: $hvalue (клиент: $client)"
    info "Запустите публикацию для $client чтобы применить."
}

subscription_del_header() {
    local client="$1" hname="$2"
    [[ -z "$client" ]] && { _select_client "Удалить заголовок" || return 1; client="$SUBSCRIPTION_SELECT_RESULT"; }
    [[ -z "$hname" ]] && { IFS= read -rp "  Имя заголовка: " hname || return 1; hname="${hname%$'\r'}"; }
    [[ -z "$hname" ]] && { warn "Имя обязательно."; return; }

    jq_w --arg n "$client" --arg hn "$hname" '
        (.clients[] | select(.name==$n)).subscription.headers =
            (((.clients[] | select(.name==$n)).subscription.headers // [])
            | [.[] | select(.name != $hn)])
    ' || return 1
    success "Заголовок удалён: $hname (клиент: $client)"
    info "Запустите публикацию для $client чтобы применить."
}

subscription_group_set_header() {
    local group="$1" hname="$2" hvalue="$3"
    [[ -z "$group" ]] && { _select_group "Добавить групповой заголовок" || return; group="$SUBSCRIPTION_SELECT_RESULT"; }
    [[ -z "$hname" ]] && { IFS= read -rp "  Имя заголовка: " hname || return 1; hname="${hname%$'\r'}"; }
    [[ -z "$hvalue" ]] && { IFS= read -rp "  Значение заголовка: " hvalue || return 1; hvalue="${hvalue%$'\r'}"; }
    [[ -z "$hname" || -z "$hvalue" ]] && { warn "Имя и значение обязательны."; return; }

    if [[ ! "$hname" =~ ^[a-zA-Z0-9!#\$%\&\'*+.^_\`|~-]+$ ]]; then
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
    ' || return 1
    success "Заголовок установлен: $hname: $hvalue (группа: $group)"
    info "Запустите 'Обновить все подписки' чтобы применить."
}

subscription_group_del_header() {
    local group="$1" hname="$2"
    [[ -z "$group" ]] && { _select_group "Удалить групповой заголовок" || return; group="$SUBSCRIPTION_SELECT_RESULT"; }
    [[ -z "$hname" ]] && { IFS= read -rp "  Имя заголовка: " hname || return 1; hname="${hname%$'\r'}"; }
    [[ -z "$hname" ]] && { warn "Имя обязательно."; return; }

    jq_w --arg g "$group" --arg hn "$hname" '
        (.groups[] | select(.name==$g)).subscription_headers =
            (((.groups[] | select(.name==$g)).subscription_headers // [])
            | [.[] | select(.name != $hn)])
    ' || return 1
    success "Заголовок удалён: $hname (группа: $group)"
    info "Запустите 'Обновить все подписки' чтобы применить."
}

subscription_show_resolved() {
    local client="$1"
    [[ -z "$client" ]] && { _select_client "Показать итоговые заголовки" || return; client="$SUBSCRIPTION_SELECT_RESULT"; }

    echo ""
    echo -e "  ${CYAN}Итоговые заголовки — ${client}:${NC}"

    local found=0
    while IFS='|' read -r value name source; do
        [[ -z "$name" ]] && continue
        found=1
        local tag
        case "$source" in
            client)
                tag="${YELLOW}[задано для клиента]${NC}" ;;
            group)
                local group
                group=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .group // empty')
                tag="${DIM}[группа: $group]${NC}" ;;
            default)
                tag="${DIM}[по умолчанию]${NC}" ;;
            *)
                tag="${DIM}[?]${NC}" ;;
        esac
        printf "  %-20s %-30s %b\n" "$name:" "$value" "$tag"
    done < <(_resolve_headers_annotated "$client")

    [[ "$found" -eq 0 ]] && echo -e "  ${DIM}Нет заголовков${NC}"
}

# Результаты интерактивного выбора передаются через глобальную переменную.
SUBSCRIPTION_SELECT_RESULT=""

_select_client() {
    SUBSCRIPTION_SELECT_RESULT=""
    local clients=() client_name
    while IFS= read -r client_name; do clients+=("$client_name"); done < <(jq_r '.clients[].name')
    MENU_SELECT_EMPTY="Нет клиентов"
    menu_select "$1" "Выберите клиента" "${clients[@]}" || return 1
    SUBSCRIPTION_SELECT_RESULT="${clients[$((MENU_SELECT_INDEX - 1))]}"
}

_select_client_with_sub() {
    SUBSCRIPTION_SELECT_RESULT=""
    local clients=() client_name
    while IFS= read -r client_name; do clients+=("$client_name"); done < <(jq_r '.clients[] | select(.subscription.token) | .name')
    MENU_SELECT_EMPTY="Нет клиентов с подписками"
    menu_select "$1" "Выберите клиента" "${clients[@]}" || return 1
    SUBSCRIPTION_SELECT_RESULT="${clients[$((MENU_SELECT_INDEX - 1))]}"
}

_select_group() {
    SUBSCRIPTION_SELECT_RESULT=""
    local groups=() group_name
    while IFS= read -r group_name; do groups+=("$group_name"); done < <(jq_r '.groups[].name')
    MENU_SELECT_EMPTY="Нет групп"
    menu_select "$1" "Выберите группу" "${groups[@]}" || return 1
    SUBSCRIPTION_SELECT_RESULT="${groups[$((MENU_SELECT_INDEX - 1))]}"
}

# ─── Меню ───────────────────────────────────────────────────────────────────

subscription_client_headers_menu() {
    local choice
    while true; do
        echo ""
        box_top
        box_center "Заголовки клиента"
        box_mid
        menu_item 1 "Установить заголовок" YELLOW
        menu_item 2 "Удалить заголовок" RED
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        IFS= read -rp "  Выберите действие: " choice || return 0
        choice="${choice%$'\r'}"
        case "$choice" in
            1) state_action "subscription_set_header" subscription_set_header "" "" "" || true ;;
            2) state_action "subscription_del_header" subscription_del_header "" "" || true ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

subscription_group_headers_menu() {
    local choice
    while true; do
        echo ""
        box_top
        box_center "Заголовки группы"
        box_mid
        menu_item 1 "Установить заголовок" YELLOW
        menu_item 2 "Удалить заголовок" RED
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        IFS= read -rp "  Выберите действие: " choice || return 0
        choice="${choice%$'\r'}"
        case "$choice" in
            1) state_action "subscription_group_set_header" subscription_group_set_header "" "" "" || true ;;
            2) state_action "subscription_group_del_header" subscription_group_del_header "" "" || true ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}

subscription_menu() {
    if ! state_action "ensure_subscription_headers" _ensure_default_headers; then
        warn "Начальные настройки подписок не сохранены. Повторите нужное действие вручную."
    fi
    local choice host_node base_url
    while true; do
        host_node=$(jq_r '.subscription_host.node // empty')
        base_url=$(jq_r '.subscription_host.base_url // empty')
        echo ""
        box_top
        box_center "Подписки"
        box_mid
        if [[ -n "$host_node" ]]; then
            box_line " Хост-нода: $host_node" " Хост-нода: ${GREEN}${host_node}${NC}"
            box_line " Базовый URL: $base_url"
        else
            box_line " Хост-нода подписок не задана" " ${DIM}Хост-нода подписок не задана${NC}"
        fi
        box_mid
        menu_item 1 "Выбрать хост-ноду" YELLOW
        menu_item 2 "Опубликовать подписку" GREEN
        menu_item 3 "Обновить все подписки" YELLOW
        menu_item 4 "Показать подписку" CYAN
        menu_item 5 "Список подписок" CYAN
        menu_item 6 "Сменить токен подписки" RED
        menu_item 7 "Отозвать подписку" RED
        menu_item 8 "Перенос на другую ноду" YELLOW
        menu_item h "Заголовки клиента" CYAN
        menu_item g "Заголовки группы" CYAN
        menu_item r "Показать итоговые заголовки" CYAN
        menu_item 0 "Назад" NC
        box_bot
        echo ""
        IFS= read -rp "  Выберите действие: " choice || return 0
        choice="${choice%$'\r'}"
        case "$choice" in
            1) state_action "subscription_set_host" subscription_set_host ;;
            2) state_action "subscription_publish" subscription_publish "" ;;
            3) state_action "subscription_publish_all" subscription_publish_all ;;
            4) subscription_show "" ;;
            5) subscription_list ;;
            6) state_action "subscription_rotate" subscription_rotate "" ;;
            7) state_action "subscription_revoke" subscription_revoke "" ;;
            8) state_action "subscription_migrate" subscription_migrate ;;
            h|H) subscription_client_headers_menu ;;
            g|G) subscription_group_headers_menu ;;
            r|R) subscription_show_resolved "" ;;
            0) return 0 ;;
            *) warn "Неверный выбор." ;;
        esac
    done
}
