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

# Проверки существования для core-функций (без вывода).
_sub_client_exists() {
    [[ "$(jq_r --arg n "$1" 'any(.clients[]?; .name==$n)')" == true ]]
}

_sub_group_exists() {
    [[ "$(jq_r --arg g "$1" 'any(.groups[]?; .name==$g)')" == true ]]
}

_sub_node_exists() {
    [[ "$(jq_r --arg n "$1" 'any(.nodes[]?; .name==$n)')" == true ]]
}

# node_load_by_name с кодами ошибок ядра. Контекст SSH сохраняет вызывающий.
_sub_node_load() {
    local name="$1" rc=0
    node_load_by_name "$name" >/dev/null || rc=$?
    case "$rc" in
        0) return 0 ;;
        2) rc_fail missing_secret "Пароль SSH ноды '$name' недоступен." ;;
        *) rc_fail not_found "Не удалось загрузить ноду '$name'." ;;
    esac
}

_sub_load_host() {
    local host_node
    host_node=$(jq_r '.subscription_host.node // empty')
    [[ -z "$host_node" ]] && { rc_fail not_ready "Хост-нода подписок не задана: sub host --node NAME."; return 1; }
    _sub_save_ssh_ctx
    _sub_node_load "$host_node" || { _sub_restore_ssh_ctx; return 1; }

    local rc=0
    ssh_run -- "test -f /etc/mihomo/subscription.conf" 2>/dev/null || rc=$?
    if [[ $rc -ne 0 ]]; then
        _sub_restore_ssh_ctx
        if [[ $rc -eq 1 ]]; then
            rc_fail not_ready "На ноде '$host_node' не установлен хостинг подписок."
        else
            rc_fail remote_failed "Хост-нода подписок недоступна."
        fi
        return 1
    fi
}

# Заголовки подписок по умолчанию: действуют, пока в config.json нет
# .subscription_default_headers (конфигурацию они не меняют).
_SUB_DEFAULT_HEADERS_JSON='[{"name":"Content-Disposition","value":"attachment; filename=\"config.yaml\""},{"name":"profile-update-interval","value":"24"}]'

_sub_done() {
    _sub_restore_ssh_ctx
}

SUB_SNIPPETS_DIR="/etc/nginx/snippets/essence-sub"
# Токены осиротевших подписок из плана sub publish-all (core_sub_publish_all_plan):
# subscription_publish_all удаляет на хосте только их.
SUB_PUBLISH_PRUNE=()

# Токен подписки — 64 hex (openssl rand -hex 32). Проверяется при каждом чтении
# из конфигурации: он попадает в пути и удалённые команды.
_sub_token_valid() {
    [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]
}

# _sub_client_token CLIENT → SUB_TOKEN (пусто — подписки нет); rc 1 и invalid,
# если сохранённый токен повреждён.
_sub_client_token() {
    SUB_TOKEN=$(jq_r --arg n "$1" '.clients[] | select(.name==$n) | .subscription.token // empty')
    if [[ -n "$SUB_TOKEN" ]] && ! _sub_token_valid "$SUB_TOKEN"; then
        SUB_TOKEN=""
        rc_fail invalid "Токен подписки клиента '$1' в конфигурации повреждён."
        return 1
    fi
}

# _sub_jq_w_token TOKEN JQ_ARGS… — jq_w, где токен доступен как $t: файлом 0600, не argv.
_sub_jq_w_token() {
    local token="$1" file rc=0
    shift
    file=$(_secret_tmpfile "$token") || return 1
    jq_w --rawfile t "$file" "$@" || rc=1
    rm -f "$file"
    return "$rc"
}

# Случайное имя временных файлов загрузки: путь на хосте не содержит токена.
_sub_upload_tag() {
    local tag
    tag=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [[ "$tag" =~ ^[0-9a-f]{16}$ ]] || return 1
    printf '%s\n' "$tag"
}

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

# Файлы грузятся под случайными именами; токен уходит в stdin удалённой
# команды, которая сама собирает итоговые пути (в argv ssh токена нет).
_sub_upload_config() {
    local src="$1" token="$2" sub_dir="$3" nginx_group="${4:-www-data}" client="${5:-}"
    if ! _subscription_config_ready "$src"; then
        warn "YAML-конфигурация отсутствует или пуста — загрузка отменена."
        return 1
    fi
    if ! _sub_token_valid "$token"; then
        warn "Токен подписки повреждён — загрузка отменена."
        return 1
    fi
    local tag label="${client:-подписки}"
    tag=$(_sub_upload_tag) || return 1
    local yaml_tmp="${sub_dir}/.upload-${tag}.yaml.tmp"
    local snip_tmp="${SUB_SNIPPETS_DIR}/.upload-${tag}.conf.tmp"
    local q_yaml_tmp q_snip_tmp q_sub_dir q_snip_dir q_owner
    printf -v q_yaml_tmp %q "$yaml_tmp"
    printf -v q_snip_tmp %q "$snip_tmp"
    printf -v q_sub_dir %q "$sub_dir"
    printf -v q_snip_dir %q "$SUB_SNIPPETS_DIR"
    printf -v q_owner %q "root:${nginx_group}"

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
            ssh_run -- "rm -f -- $q_yaml_tmp" >/dev/null 2>&1
            warn "Не удалось загрузить фрагмент конфигурации для ${label}."
            return 1
        fi
        rm -f "$snip_local"
    fi

    local ssh_cmd
    ssh_cmd="set -e
IFS= read -r token
case \"\$token\" in ''|*[!0-9a-f]*) exit 1 ;; esac
yaml_tmp=$q_yaml_tmp
yaml_dst=$q_sub_dir/\$token.yaml
chown $q_owner \"\$yaml_tmp\" && chmod 640 \"\$yaml_tmp\""

    if [[ -n "$client" ]]; then
        ssh_cmd+="
snip_tmp=$q_snip_tmp
snip_dst=$q_snip_dir/sub-\$token.conf
chown root:root \"\$snip_tmp\" && chmod 644 \"\$snip_tmp\"
backup=
if [ -f \"\$snip_dst\" ]; then backup=\$(mktemp); cp \"\$snip_dst\" \"\$backup\"; fi
mv \"\$snip_tmp\" \"\$snip_dst\"
if ! nginx -t >/dev/null 2>&1; then
    if [ -n \"\$backup\" ]; then mv \"\$backup\" \"\$snip_dst\"; else rm -f \"\$snip_dst\"; fi
    rm -f \"\$yaml_tmp\"
    nginx -t >&2 || true
    exit 1
fi
[ -n \"\$backup\" ] && rm -f \"\$backup\"
mv \"\$yaml_tmp\" \"\$yaml_dst\"
systemctl reload nginx"
    else
        ssh_cmd+="
mv \"\$yaml_tmp\" \"\$yaml_dst\""
    fi

    if ! ssh_run -- "$ssh_cmd" >/dev/null 2>&1 <<< "$token"; then
        ssh_run -- "rm -f -- $q_yaml_tmp $q_snip_tmp" >/dev/null 2>&1
        warn "Не удалось применить конфигурацию для ${label} (проверка nginx, права или перезагрузка)."
        return 1
    fi
    return 0
}

# ─── Batch-загрузка: 1 SCP yaml + 1 SCP snippet + 1 atomic SSH ──────────────
# Аргументы: sub_dir nginx_group [config_file token client_name ...]
# Временные файлы называются .<tag>.<номер>; токены по номерам — в stdin SSH.

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
        if ! _sub_token_valid "${triplets[$((i+1))]}"; then
            warn "Токен подписки повреждён — загрузка отменена."
            return 1
        fi
        i=$((i + 3))
    done

    local tag yaml_tmp_dir snip_tmp_dir
    tag=$(_sub_upload_tag) || return 1
    yaml_tmp_dir=$(umask 077; mktemp -d) || return 1
    snip_tmp_dir=$(umask 077; mktemp -d) || { rm -rf "$yaml_tmp_dir"; return 1; }

    local tokens="" n=0
    i=0
    while [[ $i -lt ${#triplets[@]} ]]; do
        local src="${triplets[$i]}" token="${triplets[$((i+1))]}" client="${triplets[$((i+2))]}"
        if ! cp "$src" "$yaml_tmp_dir/.${tag}.${n}.yaml.tmp" 2>/dev/null ||
            ! _render_subscription_snippet "$client" "$token" "$sub_dir" > "$snip_tmp_dir/.${tag}.${n}.conf.tmp"; then
            rm -rf "$yaml_tmp_dir" "$snip_tmp_dir"
            warn "$client: не удалось подготовить конфигурацию подписки."
            return 1
        fi
        tokens+="$token"$'\n'
        n=$((n + 1))
        i=$((i + 3))
    done

    local q_sub_dir q_snip_dir q_owner
    printf -v q_sub_dir %q "$sub_dir"
    printf -v q_snip_dir %q "$SUB_SNIPPETS_DIR"
    printf -v q_owner %q "root:${nginx_group}"

    if ! scp_run "$yaml_tmp_dir"/.*.yaml.tmp "${SERVER_USER}@${SERVER_IP}:${sub_dir}/" >/dev/null 2>&1; then
        rm -rf "$yaml_tmp_dir" "$snip_tmp_dir"
        warn "Не удалось загрузить пакет YAML-конфигураций."
        return 1
    fi
    if ! scp_run "$snip_tmp_dir"/.*.conf.tmp "${SERVER_USER}@${SERVER_IP}:${SUB_SNIPPETS_DIR}/" >/dev/null 2>&1; then
        rm -rf "$yaml_tmp_dir" "$snip_tmp_dir"
        ssh_run -- "rm -f -- $q_sub_dir/.$tag.*.yaml.tmp" >/dev/null 2>&1
        warn "Не удалось загрузить пакет фрагментов конфигурации."
        return 1
    fi
    rm -rf "$yaml_tmp_dir" "$snip_tmp_dir"

    local ssh_cmd
    ssh_cmd="set -e
SUB_DIR=$q_sub_dir
SNIP_DIR=$q_snip_dir
TAG=$tag
TOKENS=
while IFS= read -r tok; do
    case \"\$tok\" in ''|*[!0-9a-f]*) exit 1 ;; esac
    TOKENS=\"\$TOKENS \$tok\"
done
chown $q_owner \"\$SUB_DIR\"/.\$TAG.*.yaml.tmp && chmod 640 \"\$SUB_DIR\"/.\$TAG.*.yaml.tmp
chown root:root \"\$SNIP_DIR\"/.\$TAG.*.conf.tmp && chmod 644 \"\$SNIP_DIR\"/.\$TAG.*.conf.tmp
BACKUP_DIR=\$(mktemp -d)
trap 'rm -rf \"\$BACKUP_DIR\"' EXIT
i=0
for tok in \$TOKENS; do
    if [ -f \"\$SNIP_DIR/sub-\$tok.conf\" ]; then
        cp \"\$SNIP_DIR/sub-\$tok.conf\" \"\$BACKUP_DIR/sub-\$tok.conf\"
    fi
    mv \"\$SNIP_DIR/.\$TAG.\$i.conf.tmp\" \"\$SNIP_DIR/sub-\$tok.conf\"
    i=\$((i + 1))
done
if ! nginx -t >/dev/null 2>&1; then
    for tok in \$TOKENS; do
        if [ -f \"\$BACKUP_DIR/sub-\$tok.conf\" ]; then
            mv \"\$BACKUP_DIR/sub-\$tok.conf\" \"\$SNIP_DIR/sub-\$tok.conf\"
        else
            rm -f \"\$SNIP_DIR/sub-\$tok.conf\"
        fi
    done
    rm -f \"\$SUB_DIR\"/.\$TAG.*.yaml.tmp
    nginx -t >&2 || true
    exit 1
fi
i=0
for tok in \$TOKENS; do
    mv \"\$SUB_DIR/.\$TAG.\$i.yaml.tmp\" \"\$SUB_DIR/\$tok.yaml\"
    i=\$((i + 1))
done
systemctl reload nginx"

    if ! ssh_run -- "$ssh_cmd" >/dev/null 2>&1 <<< "${tokens%$'\n'}"; then
        ssh_run -- "rm -f -- $q_sub_dir/.$tag.*.yaml.tmp $q_snip_dir/.$tag.*.conf.tmp" >/dev/null 2>&1
        warn "Не удалось применить пакет конфигураций (проверка nginx, права или перезагрузка)."
        return 1
    fi
    return 0
}

# HTTP-верификация после сохранения подписки: токен должен отдавать 200.
# Сбой — partial: данные уже записаны, ссылку вызывающий выставил заранее.
# URL с токеном передаётся curl конфигурацией из stdin, не argv.
_sub_verify_http() {
    local token="$1"
    local base_url url
    base_url=$(jq_r '.subscription_host.base_url // empty')
    [[ -z "$base_url" ]] && return 0
    url="${base_url}/sub/${token}"
    url=${url//\\/\\\\}
    url=${url//\"/\\\"}

    local code
    code=$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' --config - 2>/dev/null <<< "url = \"$url\"")
    if [[ "$code" != "200" ]]; then
        rc_fail partial "Подписка сохранена, но проверка HTTP: ${code:-нет ответа} (ожидалось 200). Проверьте журнал ошибок nginx на сервере."
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
    jq_r --arg n "$client" --arg g "$group" --argjson dflt "$_SUB_DEFAULT_HEADERS_JSON" '
        (.subscription_default_headers // $dflt) as $dh |
        ((.groups[] | select(.name==$g) | .subscription_headers) // []) as $gh |
        ((.clients[] | select(.name==$n) | .subscription.headers) // []) as $ch |
        ($dh + $gh + $ch) | group_by(.name) | map(last) | sort_by(.name)
    '
}

_resolve_headers_annotated() {
    local client="$1"
    local group
    group=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .group // empty')

    jq_r --arg n "$client" --arg g "$group" --argjson dflt "$_SUB_DEFAULT_HEADERS_JSON" '
        (.subscription_default_headers // $dflt) as $dh |
        ((.groups[] | select(.name==$g) | .subscription_headers) // []) as $gh |
        ((.clients[] | select(.name==$n) | .subscription.headers) // []) as $ch |
        ($dh | map({key: .name, value: {value: .value, source: "default"}})) as $dm |
        ($gh | map({key: .name, value: {value: .value, source: "group"}})) as $gm |
        ($ch | map({key: .name, value: {value: .value, source: "client"}})) as $cm |
        ($dm + $gm + $cm) | group_by(.key) | map(last) | sort_by(.key) |
        map("\(.value.value)|\(.key)|\(.value.source)")[]
    '
}

# _sub_headers_valid HEADERS_JSON — заголовки допустимы для nginx: имя
# ^[A-Za-z0-9-]+$, значение без CR/LF и без завершающего \ (как _sub_header_validate).
_sub_headers_valid() {
    printf '%s' "${1:-[]}" | jq -e 'type == "array" and all(.[];
        (.name | type == "string" and test("^[A-Za-z0-9-]+$")) and
        (.value | tostring | (test("[\r\n]") | not) and (endswith("\\") | not)))' >/dev/null 2>&1
}

# _sub_headers_check CLIENT — итоговые заголовки клиента допустимы; иначе invalid.
# Конфигурация может прийти из GitHub, поэтому проверка повторяется до публикации.
_sub_headers_check() {
    local headers
    headers=$(_resolve_headers "$1")
    _sub_headers_valid "${headers:-[]}" && return 0
    rc_fail invalid "Недопустимый заголовок подписки в конфигурации клиента '$1' — исправьте его через sub headers."
    return 1
}

# Генерит per-token nginx snippet (location = /sub/<token>) на stdout.
# Чистая функция: ни SSH, ни jq_w, только чтение конфига через _resolve_headers.
# Токен и заголовки проверяются заново; недопустимые — invalid без вывода snippet
# (сообщение — в stderr: stdout вызывающие пишут в файл snippet).
# Args: client token sub_dir
_render_subscription_snippet() {
    local client="$1" token="$2" sub_dir="$3"
    local headers_json count
    if ! _sub_token_valid "$token"; then
        rc_fail invalid "Токен подписки клиента '$client' повреждён." >&2
        return 1
    fi
    headers_json=$(_resolve_headers "$client")
    if ! _sub_headers_valid "${headers_json:-[]}"; then
        rc_fail invalid "Недопустимый заголовок подписки в конфигурации клиента '$client' — исправьте его через sub headers." >&2
        return 1
    fi

    printf 'location = /sub/%s {\n' "$token"
    printf '    alias %s/%s.yaml;\n' "$sub_dir" "$token"
    printf '    default_type application/yaml;\n'
    printf '    add_header Cache-Control "no-store" always;\n'
    printf '    add_header X-Content-Type-Options nosniff always;\n'

    count=$(printf '%s' "$headers_json" | jq 'length' 2>/dev/null | tr -d '\r')
    count="${count:-0}"

    if [[ "$count" -gt 0 ]]; then
        local i name value quoted esc
        for ((i=0; i<count; i++)); do
            name=$(printf '%s' "$headers_json" | jq -r ".[$i].name" | tr -d '\r')
            value=$(printf '%s' "$headers_json" | jq -r ".[$i].value" | tr -d '\r')
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

# ─── Сроки подписок ──────────────────────────────────────────────────────────

# TTL вида 12h / 30d / 2w → unix-время истечения (от текущего момента).
_sub_ttl_to_epoch() {
    local ttl="${1:-}" re='^[1-9][0-9]*[hdw]$' count mult now
    [[ "$ttl" =~ $re ]] || return 1
    count="${ttl%?}"
    [[ ${#count} -le 6 ]] || return 1
    case "${ttl: -1}" in
        h) mult=3600 ;;
        d) mult=86400 ;;
        w) mult=604800 ;;
    esac
    now=$(date +%s) || return 1
    printf '%s\n' "$((now + 10#$count * mult))"
}

# unix-время → ISO-8601 UTC с суффиксом Z (GNU date, затем BSD/macOS).
_sub_epoch_to_iso() {
    local epoch="${1:-}" iso
    [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
    iso=$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) ||
        iso=$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 1
    printf '%s\n' "$iso"
}

# ─── Основные команды ──────────────────────────────────────────────────────

# Core: назначить хост-ноду подписок по имени ноды (без вопросов).
core_sub_set_host() {
    local node="${1:-}" remote_conf current
    [[ -n "$node" ]] || { rc_fail usage "Не указана нода."; return 1; }
    _sub_node_exists "$node" || { rc_fail not_found "Нода '$node' не найдена."; return 1; }
    current=$(jq_r '.subscription_host.node // empty')
    if [[ -n "$current" && "$current" != "$node" ]] &&
        [[ "$(jq_r 'any(.clients[]?; (.subscription.token // "") != "")')" == true ]]; then
        rc_fail conflict "Есть опубликованные подписки. Для смены хост-ноды используйте sub migrate --node $node."
        return 1
    fi
    _sub_save_ssh_ctx
    _sub_node_load "$node" || { _sub_done; return 1; }
    if ! remote_conf=$(ssh_run -- "cat /etc/mihomo/subscription.conf 2>/dev/null"); then
        _sub_done
        rc_fail remote_failed "Хост-нода подписок недоступна."
        return 1
    fi
    _sub_done
    [[ -n "$remote_conf" ]] || { rc_fail not_ready "На ноде '$node' не установлен хостинг подписок."; return 1; }
    local base_url sub_dir nginx_group
    base_url=$(echo "$remote_conf" | grep '^SUB_BASE_URL=' | cut -d= -f2-)
    sub_dir=$(echo "$remote_conf" | grep '^SUB_DIR=' | cut -d= -f2-)
    nginx_group=$(echo "$remote_conf" | grep '^NGINX_GROUP=' | cut -d= -f2-)
    [[ -n "$base_url" && -n "$sub_dir" ]] || { rc_fail invalid "Конфигурация хостинга подписок неполна."; return 1; }
    jq_w --arg n "$node" --arg u "$base_url" --arg d "$sub_dir" --arg g "${nginx_group:-www-data}" \
        '.subscription_host = {node: $n, base_url: $u, sub_dir: $d, nginx_group: $g}' || return 1
    success "Хост-нода подписок: $node ($base_url)"
}

# Core: публикация подписки клиента. TTL (12h/30d/2w) проверяется до загрузки;
# без TTL повторная публикация сохраняет срок существующей подписки.
# Успех: SUB_PUBLISH_URL, SUB_PUBLISH_EXPIRES_AT (пусто — без срока); они же
# при partial (сбой проверки HTTP после сохранения).
subscription_publish() {
    local client="${1:-}" ttl="${2:-}"
    SUB_PUBLISH_URL="" SUB_PUBLISH_EXPIRES_AT=""
    [[ -n "$client" ]] || { rc_fail usage "Не указан клиент."; return 1; }

    # Проверяем что клиент существует
    local client_group
    client_group=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .group // empty')
    [[ -z "$client_group" ]] && { rc_fail not_found "Клиент '$client' не найден."; return 1; }

    # TTL → срок; до любых записей и загрузок
    local expires_ts="" expires_at=""
    if [[ -n "$ttl" ]]; then
        if ! expires_ts=$(_sub_ttl_to_epoch "$ttl") || ! expires_at=$(_sub_epoch_to_iso "$expires_ts"); then
            rc_fail invalid "Неверный формат TTL: $ttl (пример: 12h, 30d, 2w)."
            return 1
        fi
    fi

    local config_file
    config_file=$(_client_config_file "$client") || { _client_dir_invalid "$client"; return 1; }
    if ! _subscription_config_ready "$config_file"; then
        rc_fail not_ready "Конфиг для '$client' не найден или пуст. Сначала сгенерируйте конфиги."
        return 1
    fi

    # Проверяем host
    local host_node base_url
    host_node=$(jq_r '.subscription_host.node // empty')
    base_url=$(jq_r '.subscription_host.base_url // empty')
    [[ -z "$host_node" ]] && { rc_fail not_ready "Хост-нода подписок не задана: sub host --node NAME."; return 1; }

    # Токен: новый или существующий; заголовки — до любых загрузок
    local token is_new=false
    _sub_client_token "$client" || return 1
    token="$SUB_TOKEN"
    if [[ -z "$token" ]]; then
        token=$(openssl rand -hex 32) || return 1
        _sub_token_valid "$token" || { rc_fail failed "Не удалось создать токен подписки."; return 1; }
        is_new=true
    fi
    _sub_headers_check "$client" || return 1

    # Загружаем на сервер
    _sub_load_host || return 1

    local sub_dir nginx_group
    sub_dir=$(_sub_get_dir) || { _sub_done; rc_fail remote_failed "Не удалось определить каталог подписок на хост-ноде."; return 1; }
    nginx_group=$(_sub_get_nginx_group)

    if ! _sub_upload_config "$config_file" "$token" "$sub_dir" "$nginx_group" "$client"; then
        _sub_done
        rc_fail remote_failed "Ошибка загрузки файла на сервер."
        return 1
    fi

    # TTL → expiry.list (тот же epoch, что и expires_at): запись токена заменяется
    # под expiry-lock, без дубликатов. Без TTL срок существующей подписки не меняется.
    if [[ -n "$expires_ts" ]] && ! _sub_migrate_expiry "$sub_dir" "$token" "$expires_ts"; then
        if $is_new; then
            local cleanup="загруженная подписка удалена"
            _sub_remove_token "$token" "$sub_dir" ||
                cleanup="удалить загруженную подписку не удалось — проверьте каталог подписок на хост-ноде"
            _sub_done
            rc_fail remote_failed "Срок подписки не записан на хост-ноде; $cleanup. Локальные данные не изменены."
        else
            _sub_done
            rc_fail remote_failed "Конфиг подписки обновлён на хост-ноде, но новый срок записать не удалось; действует прежний срок."
        fi
        return 1
    fi

    local metadata='{token: $t, created_at: $ts}'
    if [[ -n "$expires_ts" ]]; then
        metadata='{token: $t, expires_at: $e, created_at: $ts}'
    elif $is_new; then
        metadata='{token: $t, expires_at: null, created_at: $ts}'
    fi
    if ! _sub_jq_w_token "$token" --arg n "$client" --arg e "$expires_at" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        "(.clients[] | select(.name==\$n)).subscription |= ((. // {}) + $metadata)"; then
        _sub_done
        rc_fail failed "Файл загружен на сервер, но данные подписки сохранить не удалось. Публикация не завершена."
        return 1
    fi
    _sub_done

    success "Подписка опубликована: $client"
    [[ -n "$base_url" ]] && SUB_PUBLISH_URL="${base_url}/sub/${token}"
    SUB_PUBLISH_EXPIRES_AT=$(jq_r --arg n "$client" '.clients[] | select(.name==$n) | .subscription.expires_at // empty')
    _sub_verify_http "$token"
}

# План отзыва подписки: CORE_PLAN_LINES.
core_sub_revoke_plan() {
    local client="${1:-}" token host_node
    CORE_PLAN_LINES=()
    [[ -n "$client" ]] || { rc_fail usage "Не указан клиент."; return 1; }
    _sub_client_exists "$client" || { rc_fail not_found "Клиент '$client' не найден."; return 1; }
    _sub_client_token "$client" || return 1
    token="$SUB_TOKEN"
    [[ -n "$token" ]] || { rc_fail invalid "У клиента '$client' нет подписки."; return 1; }
    host_node=$(jq_r '.subscription_host.node // empty')
    CORE_PLAN_LINES=("Клиент: $client" "Хост-нода: $host_node" \
        "Ссылка перестанет работать; конфиг клиента сохранится.")
}

core_sub_revoke() {
    local client="${1:-}"
    core_sub_revoke_plan "$client" || return 1
    _subscription_revoke_silent "$client"
}

# Удаление под expiry-lock: при сбое восстанавливаются файлы, expiry и nginx.
# SUB_REMOVE_TOKEN_STATE разрешает очистку замены только после подтверждённого отката.
# Не выводим диагностику SSH/команд: пути в ней содержат токены.
# Токен и замена передаются в stdin (не argv); expiry.list правится точным
# сравнением первого поля, без sed.
_sub_remove_token() {
    local token="$1" sub_dir="$2" replacement="${3:-}" script command response rc=0
    SUB_REMOVE_TOKEN_STATE=unknown
    if ! _sub_token_valid "$token" || { [[ -n "$replacement" ]] && ! _sub_token_valid "$replacement"; }; then
        warn "Токен подписки повреждён — удаление не выполнено."
        return 1
    fi
    script=$(cat <<'EOF'
sub_dir=$1 snippets_dir=$2
IFS= read -r token || exit 1
IFS= read -r replacement || replacement=
case "$token" in (''|*[!0-9a-f]*) exit 1 ;; esac
case "$replacement" in (*[!0-9a-f]*) exit 1 ;; esac
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
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ("$token "*)
                    if [ -n "$replacement" ]; then printf '%s\n' "$replacement ${line#"$token "}"; fi
                    ;;
                (*) printf '%s\n' "$line" ;;
            esac
        done < "$expiry" > "$backup/expiry.new" || return 1
        cp -- "$backup/expiry.new" "$expiry" || return 1
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
    printf -v command 'bash -c %q -- %q %q' "$script" "$sub_dir" "$SUB_SNIPPETS_DIR"
    response=$(ssh_run -- "$command" 2>/dev/null <<< "$token"$'\n'"$replacement") || rc=$?
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
    _sub_client_token "$client" || return 1
    token="$SUB_TOKEN"
    [[ -z "$token" ]] && return 0
    if ! _sub_load_host; then
        warn "Подписка '$client' не отозвана: ссылка может оставаться действующей."
        return 1
    fi
    sub_dir=$(_sub_get_dir) || { _sub_done; rc_fail remote_failed "Подписка '$client' не отозвана: ссылка может оставаться действующей."; return 1; }
    _sub_remove_token "$token" "$sub_dir" || rc=1
    _sub_done
    if [[ $rc -ne 0 ]]; then
        rc_fail remote_failed "Подписка '$client' не отозвана: ссылка может оставаться действующей."
        return 1
    fi
    jq_w --arg n "$client" '(.clients[] | select(.name==$n)) |= del(.subscription.token, .subscription.expires_at, .subscription.created_at)' || return 1
    success "Подписка отозвана: $client"
    return 0
}

# План смены токена: только локальные проверки, CORE_PLAN_LINES.
core_sub_rotate_plan() {
    local client="${1:-}" token config_file host_node
    CORE_PLAN_LINES=()
    [[ -n "$client" ]] || { rc_fail usage "Не указан клиент."; return 1; }
    _sub_client_exists "$client" || { rc_fail not_found "Клиент '$client' не найден."; return 1; }
    _sub_client_token "$client" || return 1
    token="$SUB_TOKEN"
    [[ -n "$token" ]] || { rc_fail invalid "У клиента '$client' нет подписки."; return 1; }
    config_file=$(_client_config_file "$client") || { _client_dir_invalid "$client"; return 1; }
    _subscription_config_ready "$config_file" || { rc_fail not_ready "Конфиг для '$client' не найден или пуст."; return 1; }
    host_node=$(jq_r '.subscription_host.node // empty')
    [[ -n "$host_node" ]] || { rc_fail not_ready "Хост-нода подписок не задана: sub host --node NAME."; return 1; }
    _sub_headers_check "$client" || return 1
    CORE_PLAN_LINES=("Клиент: $client" "Хост-нода: $host_node" \
        "Старая ссылка перестанет работать; новая ссылка будет показана после завершения.")
}

# Core: новый токен → загрузка → удаление старой ссылки → сохранение. Успех: SUB_ROTATE_URL
# (и при partial — сбой проверки HTTP после сохранения нового токена).
core_sub_rotate() {
    local client="${1:-}" old_token config_file host_node base_url sub_dir nginx_group new_token
    SUB_ROTATE_URL=""
    core_sub_rotate_plan "$client" || return 1
    old_token="$SUB_TOKEN"
    config_file=$(_client_config_file "$client") || { _client_dir_invalid "$client"; return 1; }
    host_node=$(jq_r '.subscription_host.node // empty')
    _sub_load_host || return 1
    sub_dir=$(_sub_get_dir) || { _sub_done; rc_fail remote_failed "Не удалось определить каталог подписок на хост-ноде."; return 1; }
    nginx_group=$(_sub_get_nginx_group)
    _sub_done
    new_token=$(openssl rand -hex 32) || return 1
    _sub_token_valid "$new_token" || { rc_fail failed "Не удалось создать токен подписки."; return 1; }
    _sub_save_ssh_ctx
    _sub_node_load "$host_node" || { _sub_done; return 1; }
    if ! _sub_upload_config "$config_file" "$new_token" "$sub_dir" "$nginx_group" "$client"; then
        _sub_done
        rc_fail remote_failed "Смена токена не выполнена: новая подписка не загружена."
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
        rc_fail remote_failed "Смена токена не завершена: удаление старой ссылки не подтверждено."
        return 1
    fi
    _sub_done
    if ! _sub_jq_w_token "$new_token" --arg n "$client" '(.clients[] | select(.name==$n)).subscription.token = $t'; then
        rc_fail failed "Старый токен удалён, но новый токен не удалось сохранить локально. Смена токена не завершена."
        return 1
    fi
    success "Токен обновлён: $client"
    base_url=$(jq_r '.subscription_host.base_url // empty')
    [[ -n "$base_url" ]] && SUB_ROTATE_URL="${base_url}/sub/${new_token}"
    _sub_verify_http "$new_token" || return 1
}

# План sub publish-all: клиенты с готовым конфигом и осиротевшие подписки хоста
# (read-only SSH-листинг каталога подписок; токены в плане — только префиксы).
# Заполняет CORE_PLAN_LINES, SUB_PUBLISH_PLAN_COUNT (0 — публиковать нечего,
# подтверждение не нужно) и SUB_PUBLISH_PRUNE (токены к удалению на хосте).
# Нет ни одного локального токена, а на хосте есть подписки — failed без изменений.
core_sub_publish_all_plan() {
    CORE_PLAN_LINES=() SUB_PUBLISH_PRUNE=() SUB_PUBLISH_PLAN_COUNT=0
    local host_node client config_file sub_dir q_dir listing name
    local -a targets=() known=() remote=()
    host_node=$(jq_r '.subscription_host.node // empty')
    [[ -n "$host_node" ]] || { rc_fail not_ready "Хост-нода подписок не задана."; return 1; }
    while IFS= read -r client; do
        [[ -n "$client" ]] || continue
        _sub_client_token "$client" || return 1
        [[ -n "$SUB_TOKEN" ]] && known+=("$SUB_TOKEN")
        config_file=$(_client_config_file "$client") || { _client_dir_invalid "$client"; return 1; }
        _subscription_config_ready "$config_file" || continue
        _sub_headers_check "$client" || return 1
        targets+=("$client")
    done < <(jq_r '.clients[].name')
    SUB_PUBLISH_PLAN_COUNT=${#targets[@]}
    (( SUB_PUBLISH_PLAN_COUNT > 0 )) || return 0

    _sub_load_host || return 1
    if ! sub_dir=$(_sub_get_dir); then
        _sub_done
        rc_fail remote_failed "Не удалось определить каталог подписок на хост-ноде."
        return 1
    fi
    printf -v q_dir %q "$sub_dir"
    if ! listing=$(ssh_run -- "cd -- $q_dir || exit 1
for f in *.yaml; do [ -e \"\$f\" ] && printf '%s\n' \"\${f%.yaml}\"; done
exit 0" 2>/dev/null); then
        _sub_done
        rc_fail remote_failed "Не удалось прочитать каталог подписок на хост-ноде."
        return 1
    fi
    _sub_done
    while IFS= read -r name; do
        _sub_token_valid "$name" || continue
        remote+=("$name")
        array_contains "$name" "${known[@]}" || SUB_PUBLISH_PRUNE+=("$name")
    done <<< "$listing"
    if (( ${#known[@]} == 0 && ${#remote[@]} > 0 )); then
        SUB_PUBLISH_PRUNE=()
        rc_fail failed "В конфигурации нет ни одного токена подписки, а на хост-ноде есть опубликованные подписки. Публикация отменена, на хосте ничего не удалено — проверьте конфигурацию."
        return 1
    fi

    CORE_PLAN_LINES=("Хост-нода: $host_node" "Будут опубликованы (${#targets[@]}):")
    for client in "${targets[@]}"; do CORE_PLAN_LINES+=(" $client"); done
    if (( ${#SUB_PUBLISH_PRUNE[@]} > 0 )); then
        CORE_PLAN_LINES+=("Подписки без клиента в конфигурации будут удалены с хоста (${#SUB_PUBLISH_PRUNE[@]}):")
        for name in "${SUB_PUBLISH_PRUNE[@]}"; do CORE_PLAN_LINES+=(" ${name:0:8}…"); done
    else
        CORE_PLAN_LINES+=("Подписок без клиента на хосте нет.")
    fi
    CORE_PLAN_LINES+=("nginx на хост-ноде будет перезагружен.")
}

# Core: публикация всех клиентов с готовым конфигом пакетом на хост-ноду; затем
# удаление на хосте только подписок из SUB_PUBLISH_PRUNE (план, согласованный
# через core_sub_publish_all_plan; без плана ничего не удаляется).
# Итог: SUB_PUBLISH_OK=(), SUB_PUBLISH_SKIPPED=(), SUB_PUBLISH_FAILED=(), SUB_PUBLISH_REMOVED=<n>.
subscription_publish_all() {
    SUB_PUBLISH_OK=() SUB_PUBLISH_SKIPPED=() SUB_PUBLISH_FAILED=() SUB_PUBLISH_REMOVED=0
    local -a planned_prune=()
    [[ ${#SUB_PUBLISH_PRUNE[@]} -gt 0 ]] && planned_prune=("${SUB_PUBLISH_PRUNE[@]}")
    SUB_PUBLISH_PRUNE=()
    local host_node
    host_node=$(jq_r '.subscription_host.node // empty')
    [[ -z "$host_node" ]] && { rc_fail not_ready "Хост-нода подписок не задана."; return 1; }

    local all_clients=()
    while IFS= read -r client_name; do
        all_clients+=("$client_name")
    done < <(jq_r '.clients[].name')

    local triplets=() ok=0 new_tokens=() skipped=0 published=() rc=0
    for client in "${all_clients[@]}"; do
        local config_file
        config_file=$(_client_config_file "$client") || { _client_dir_invalid "$client"; return 1; }
        if ! _subscription_config_ready "$config_file"; then
            skipped=$((skipped + 1))
            SUB_PUBLISH_SKIPPED+=("$client")
            info "$client: пропущено — конфиг отсутствует или пуст"
            continue
        fi

        local token
        _sub_client_token "$client" || return 1
        _sub_headers_check "$client" || return 1
        token="$SUB_TOKEN"
        if [[ -z "$token" ]]; then
            token=$(openssl rand -hex 32) || { rc_fail failed "$client: публикация не подтверждена"; return 1; }
            _sub_token_valid "$token" || { rc_fail failed "$client: публикация не подтверждена"; return 1; }
            new_tokens+=("$client" "$token")
        fi
        triplets+=("$config_file" "$token" "$client")
        published+=("$client")
        ok=$((ok + 1))
    done

    if [[ ${#triplets[@]} -eq 0 ]]; then
        info "Нет конфигов для публикации."
        [[ $skipped -gt 0 ]] && info "Пропущено (конфиг отсутствует или пуст): $skipped"
        return 0
    fi

    _sub_load_host || return 1

    local sub_dir nginx_group
    sub_dir=$(_sub_get_dir) || { _sub_done; rc_fail remote_failed "Не удалось определить каталог подписок на хост-ноде."; return 1; }
    nginx_group=$(_sub_get_nginx_group)

    if _sub_upload_batch "$sub_dir" "$nginx_group" "${triplets[@]}"; then
        # Сохраняем токены новых клиентов
        local i=0 saved=0
        while [[ $i -lt ${#new_tokens[@]} ]]; do
            local c="${new_tokens[$i]}" t="${new_tokens[$((i+1))]}"
            _sub_jq_w_token "$t" --arg n "$c" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
                '(.clients[] | select(.name==$n)).subscription |= ((. // {}) + {token: $t, expires_at: null, created_at: $ts})' || { rc=1; break; }
            saved=$((saved + 1))
            i=$((i + 2))
        done
        if [[ $rc -ne 0 ]]; then
            _sub_done
            # Опубликованы клиенты с сохранённым токеном (прежним или новым); у остальных
            # новых файлы на хосте есть, а токена в конфигурации нет.
            local -a unsaved=()
            for (( ; i<${#new_tokens[@]}; i+=2 )); do unsaved+=("${new_tokens[$i]}"); done
            for client in "${published[@]}"; do
                if array_contains "$client" "${unsaved[@]}"; then
                    SUB_PUBLISH_FAILED+=("$client")
                    warn "$client: публикация не подтверждена"
                else
                    SUB_PUBLISH_OK+=("$client")
                fi
            done
            if (( saved > 0 )); then
                rc_fail partial "Файлы загружены пакетно; сохранено новых токенов: $saved из $(( ${#new_tokens[@]} / 2 )). Дальнейшие записи и очистка старых файлов остановлены."
            else
                rc_fail failed "Файлы загружены пакетно, но новые токены сохранить не удалось. Дальнейшие записи и очистка старых файлов остановлены."
            fi
            return 1
        fi
        SUB_PUBLISH_OK=("${published[@]}")
        for client in "${published[@]}"; do success "$client: опубликовано"; done
        success "Опубликовано: $ok"
        info "Пропущено (конфиг отсутствует или пуст): $skipped"
        info "Ошибка: 0"

        # Удаление согласованных в плане осиротевших подписок (токены — в stdin).
        if ! _sub_prune_planned "$sub_dir" "${planned_prune[@]}"; then
            rc_fail partial "Подписки опубликованы, но не все подписки без клиента удалены с хост-ноды."
            rc=1
        fi
    else
        SUB_PUBLISH_FAILED=("${published[@]}")
        for client in "${published[@]}"; do warn "$client: публикация не подтверждена"; done
        info "Опубликовано: 0; пропущено: $skipped; ошибка: $ok"
        rc_fail remote_failed "Подписки не опубликованы: ошибка загрузки на хост-ноду."
        rc=1
    fi

    _sub_done
    return "$rc"
}

# _sub_prune_planned SUB_DIR TOKEN… — удаляет на хосте YAML и snippet указанных
# подписок, кроме ставших известными локально; токены — в stdin. Итог: SUB_PUBLISH_REMOVED.
# rc 1 — сбой SSH, удаления или перезагрузки nginx (уже отсутствующие файлы не ошибка).
_sub_prune_planned() {
    local sub_dir="$1" known t q_sub q_snip sweep_cmd out removed failed rc=0
    local -a prune=()
    shift
    [[ $# -gt 0 ]] || return 0
    known=$'\n'$(jq_r '.clients[] | .subscription.token // empty')$'\n'
    for t in "$@"; do
        _sub_token_valid "$t" || continue
        [[ "$known" == *$'\n'"$t"$'\n'* ]] && continue
        prune+=("$t")
    done
    [[ ${#prune[@]} -gt 0 ]] || return 0
    printf -v q_sub %q "$sub_dir"
    printf -v q_snip %q "$SUB_SNIPPETS_DIR"
    sweep_cmd="SUB_DIR=$q_sub
SNIP_DIR=$q_snip
removed=0 failed=0 reload=0
while IFS= read -r tok; do
    case \"\$tok\" in ''|*[!0-9a-f]*) continue ;; esac
    [ -e \"\$SUB_DIR/\$tok.yaml\" ] || continue
    if rm -f \"\$SUB_DIR/\$tok.yaml\" \"\$SNIP_DIR/sub-\$tok.conf\"; then removed=\$((removed + 1)); else failed=\$((failed + 1)); fi
done
if [ \$removed -gt 0 ]; then systemctl reload nginx || reload=1; fi
echo \"\$removed \$failed\"
[ \$failed -eq 0 ] && [ \$reload -eq 0 ]"
    out=$(ssh_run -- "$sweep_cmd" 2>/dev/null <<< "$(printf '%s\n' "${prune[@]}")") || rc=1
    read -r removed failed <<< "${out##*$'\n'}"
    if [[ "$removed" =~ ^[0-9]+$ && "$removed" -gt 0 ]]; then
        SUB_PUBLISH_REMOVED="$removed"
        info "Удалено осиротевших подписок: $removed"
    fi
    [[ $rc -eq 0 && "$removed" =~ ^[0-9]+$ && "${failed:-0}" == 0 ]]
}

# ISO-8601 срок подписки (формат `date --iso-8601=seconds` или с суффиксом Z) → unix-время.
# Разбор через jq, без GNU `date -d`: работает и в macOS.
_sub_iso_to_epoch() {
    local epoch
    epoch=$(jq -enr --arg d "${1:-}" '
        $d | capture("^(?<t>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2}))$")
        | ((.t + "Z") | fromdateiso8601)
          - (if .z == "Z" then 0
             else (if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60) end)
    ' 2>/dev/null) && epoch="${epoch//$'\r'/}" && [[ "$epoch" =~ ^-?[0-9]+$ ]] || return 1
    printf '%s\n' "$epoch"
}

# Сроки подписок в expiry.list новой хост-ноды под тем же expiry-lock, что и очистка.
# Аргументы: sub_dir, затем пары «токен срок_unix»; пустой срок только удаляет прежнюю
# запись токена. Список заменяется атомарно: при ошибке прежний expiry.list не меняется.
# Пары передаются в stdin (не argv); записи сравниваются точно по первому полю.
_sub_migrate_expiry() {
    local sub_dir="$1" script command pairs=""
    shift
    while [[ $# -ge 2 ]]; do
        _sub_token_valid "$1" || return 1
        [[ -z "$2" || "$2" =~ ^[0-9]+$ ]] || return 1
        pairs+="$1 $2"$'\n'
        shift 2
    done
    script=$(cat <<'EOF'
sub_dir=$1
list="$sub_dir/expiry.list"; tmp="$list.migrate.$$"
drop=" " entries=""
while IFS=' ' read -r tok ts; do
    case "$tok" in ('') continue ;; (*[!0-9a-f]*) exit 1 ;; esac
    case "$ts" in (*[!0-9]*) exit 1 ;; esac
    drop="$drop$tok "
    if [ -n "$ts" ]; then entries="$entries$tok $ts
"; fi
done
exec 9>"$sub_dir/.expiry.lock" || exit 1
flock -x 9 || exit 1
(
    if [ -e "$list" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$drop" in
                (*" ${line%% *} "*) ;;
                (*) printf '%s\n' "$line" || exit 1 ;;
            esac
        done < "$list" || exit 1
    fi
    printf '%s' "$entries" || exit 1
) > "$tmp" || { rm -f "$tmp"; exit 1; }
mv -f "$tmp" "$list" || { rm -f "$tmp"; exit 1; }
EOF
)
    printf -v command 'bash -c %q -- %q' "$script" "$sub_dir"
    ssh_run -- "$command" >/dev/null 2>&1 <<< "${pairs%$'\n'}"
}

# Проверки переноса (локальные, затем read-only SSH к обеим нодам). Заполняет _SUB_MIG_*.
# Без опубликованных подписок SSH не выполняется и _SUB_MIG_CLIENTS пуст.
_sub_migrate_prepare() {
    local new_node="${1:-}" old_node new_conf old_conf
    _SUB_MIG_OLD_NODE="" _SUB_MIG_OLD_BASE_URL="" _SUB_MIG_OLD_SUB_DIR=""
    _SUB_MIG_NEW_SUB_DIR="" _SUB_MIG_NEW_BASE_URL="" _SUB_MIG_NEW_NGINX_GROUP=""
    _SUB_MIG_CLIENTS=() _SUB_MIG_TOKENS=() _SUB_MIG_CONFIGS=() _SUB_MIG_EXPIRY_ARGS=()
    old_node=$(jq_r '.subscription_host.node // empty')
    [[ -n "$old_node" ]] || { rc_fail not_ready "Хост-нода подписок не задана."; return 1; }
    [[ -n "$new_node" ]] || { rc_fail usage "Не указана новая хост-нода."; return 1; }
    _sub_node_exists "$new_node" || { rc_fail not_found "Нода '$new_node' не найдена."; return 1; }
    [[ "$new_node" != "$old_node" ]] || { rc_fail invalid "Выбрана текущая хост-нода. Перенос не выполнен."; return 1; }
    _SUB_MIG_OLD_NODE="$old_node"
    _SUB_MIG_OLD_BASE_URL=$(jq_r '.subscription_host.base_url // empty')
    local client token expires_at expires_ts config_file
    while IFS='|' read -r client token expires_at; do
        [[ -n "$token" ]] || continue
        if ! _sub_token_valid "$token"; then
            rc_fail invalid "Токен подписки клиента '$client' в конфигурации повреждён. Перенос отменён."
            return 1
        fi
        config_file=$(_client_config_file "$client") || { _client_dir_invalid "$client"; return 1; }
        if ! _subscription_config_ready "$config_file"; then
            rc_fail not_ready "$client: конфиг отсутствует или пуст. Перенос отменён."
            return 1
        fi
        _sub_headers_check "$client" || return 1
        if [[ -n "$expires_at" ]]; then
            if ! expires_ts=$(_sub_iso_to_epoch "$expires_at"); then
                rc_fail invalid "$client: срок подписки не распознан. Перенос отменён."
                return 1
            fi
        else
            expires_ts=""
        fi
        _SUB_MIG_EXPIRY_ARGS+=("$token" "$expires_ts")
        _SUB_MIG_CLIENTS+=("$client"); _SUB_MIG_TOKENS+=("$token"); _SUB_MIG_CONFIGS+=("$config_file")
    done < <(jq_r '.clients[] | select(.subscription.token) | "\(.name)|\(.subscription.token)|\(.subscription.expires_at // "")"')
    [[ ${#_SUB_MIG_CLIENTS[@]} -gt 0 ]] || return 0
    _sub_save_ssh_ctx
    _sub_node_load "$old_node" || { _sub_done; return 1; }
    if ! old_conf=$(ssh_run -- "cat /etc/mihomo/subscription.conf 2>/dev/null"); then
        _sub_done; rc_fail remote_failed "Хост-нода подписок недоступна."; return 1
    fi
    _sub_node_load "$new_node" || { _sub_done; return 1; }
    if ! new_conf=$(ssh_run -- "cat /etc/mihomo/subscription.conf 2>/dev/null"); then
        _sub_done; rc_fail remote_failed "Новая хост-нода подписок недоступна."; return 1
    fi
    _sub_done
    _SUB_MIG_OLD_SUB_DIR=$(echo "$old_conf" | grep '^SUB_DIR=' | cut -d= -f2-)
    _SUB_MIG_NEW_SUB_DIR=$(echo "$new_conf" | grep '^SUB_DIR=' | cut -d= -f2-)
    _SUB_MIG_NEW_BASE_URL=$(echo "$new_conf" | grep '^SUB_BASE_URL=' | cut -d= -f2-)
    _SUB_MIG_NEW_NGINX_GROUP=$(echo "$new_conf" | grep '^NGINX_GROUP=' | cut -d= -f2-)
    [[ -n "$_SUB_MIG_OLD_SUB_DIR" && -n "$_SUB_MIG_NEW_SUB_DIR" && -n "$_SUB_MIG_NEW_BASE_URL" ]] || {
        rc_fail invalid "Конфигурация хостинга подписок неполна. Перенос отменён."; return 1;
    }
}

# План переноса: CORE_PLAN_LINES; SUB_MIGRATE_COUNT — число подписок к переносу (0 — нечего переносить).
core_sub_migrate_plan() {
    CORE_PLAN_LINES=()
    SUB_MIGRATE_COUNT=0
    _sub_migrate_prepare "${1:-}" || return 1
    SUB_MIGRATE_COUNT=${#_SUB_MIG_CLIENTS[@]}
    if [[ $SUB_MIGRATE_COUNT -eq 0 ]]; then
        CORE_PLAN_LINES=("Нет опубликованных подписок для переноса.")
        return 0
    fi
    CORE_PLAN_LINES=("Старая хост-нода: $_SUB_MIG_OLD_NODE" "Базовый URL: $_SUB_MIG_OLD_BASE_URL" \
        "Новая хост-нода: $1" "Базовый URL: $_SUB_MIG_NEW_BASE_URL" "${_SUB_MIG_CLIENTS[@]}" \
        "Все адреса подписок изменятся." "Старые ссылки будут удалены только после загрузки всех подписок.")
}

# Core: перенос всех подписок на NODE. Успех: SUB_MIGRATE_BASE_URL, SUB_MIGRATE_COUNT
# (выставляются и при partial — хост уже переключён).
core_sub_migrate() {
    local new_node="${1:-}" old_node new_sub_dir new_base_url new_nginx_group old_sub_dir token i rc=0
    SUB_MIGRATE_BASE_URL="" SUB_MIGRATE_COUNT=0
    _sub_migrate_prepare "$new_node" || return 1
    if [[ ${#_SUB_MIG_CLIENTS[@]} -eq 0 ]]; then
        info "Нет опубликованных подписок для переноса."
        return 0
    fi
    old_node="$_SUB_MIG_OLD_NODE" old_sub_dir="$_SUB_MIG_OLD_SUB_DIR"
    new_sub_dir="$_SUB_MIG_NEW_SUB_DIR" new_base_url="$_SUB_MIG_NEW_BASE_URL"
    new_nginx_group="${_SUB_MIG_NEW_NGINX_GROUP:-www-data}"
    _sub_save_ssh_ctx
    _sub_node_load "$new_node" || { _sub_done; return 1; }
    # Сначала сроки: устаревшая запись токена на новой ноде не должна удалить загруженный YAML.
    _sub_migrate_expiry "$new_sub_dir" "${_SUB_MIG_EXPIRY_ARGS[@]}" || rc=1
    if [[ $rc -eq 0 ]]; then
        for ((i=0; i<${#_SUB_MIG_CLIENTS[@]}; i++)); do
            _sub_upload_config "${_SUB_MIG_CONFIGS[$i]}" "${_SUB_MIG_TOKENS[$i]}" "$new_sub_dir" "$new_nginx_group" "${_SUB_MIG_CLIENTS[$i]}" || rc=1
        done
    fi
    _sub_done
    if [[ $rc -ne 0 ]]; then
        warn "Перенос не завершён: старый хост и старые ссылки сохранены."
        rc_fail remote_failed "На новой ноде могли остаться копии подписок."
        return 1
    fi
    jq_w --arg n "$new_node" --arg u "$new_base_url" --arg d "$new_sub_dir" --arg g "$new_nginx_group" \
        '.subscription_host = {node: $n, base_url: $u, sub_dir: $d, nginx_group: $g}' || return 1
    SUB_MIGRATE_BASE_URL="$new_base_url"
    SUB_MIGRATE_COUNT=${#_SUB_MIG_CLIENTS[@]}
    _sub_save_ssh_ctx
    if node_load_by_name "$old_node"; then
        for token in "${_SUB_MIG_TOKENS[@]}"; do _sub_remove_token "$token" "$old_sub_dir" || rc=1; done
    else
        rc=1
    fi
    _sub_done
    if [[ $rc -ne 0 ]]; then
        rc_fail partial "Подписки перенесены, но старые ссылки не удалось полностью удалить. Требуется очистка старой ноды."
        return 1
    fi
    success "Перенесено $SUB_MIGRATE_COUNT подписок на '$new_node'"
    info "Новый базовый URL: $new_base_url"
    return 0
}

# ─── Управление хедерами ───────────────────────────────────────────────────

# Имя — латиница, цифры и дефис (имя вставляется в nginx без кавычек); значение
# без переводов строк и без завершающего \. Те же правила повторяет
# _sub_headers_valid при каждой публикации.
_sub_header_validate() {
    local hname="$1" hvalue="$2"
    if [[ ! "$hname" =~ ^[A-Za-z0-9-]+$ ]]; then
        rc_fail invalid "Некорректное имя заголовка: допустимы латинские буквы, цифры и дефис."
        return 1
    fi
    # CRLF injection
    if [[ "$hvalue" =~ $'\r' || "$hvalue" =~ $'\n' ]]; then
        rc_fail invalid "Значение не может содержать переводы строк."
        return 1
    fi
    # Trailing backslash ломает escape в double-quoted nginx-литералах
    if [[ "$hvalue" =~ \\$ ]]; then
        rc_fail invalid "Значение не может оканчиваться на \\."
        return 1
    fi
}

subscription_set_header() {
    local client="${1:-}" hname="${2:-}" hvalue="${3:-}"
    [[ -n "$client" && -n "$hname" && -n "$hvalue" ]] || { rc_fail usage "Клиент, имя и значение заголовка обязательны."; return 1; }
    _sub_client_exists "$client" || { rc_fail not_found "Клиент '$client' не найден."; return 1; }
    _sub_header_validate "$hname" "$hvalue" || return 1

    jq_w --arg n "$client" --arg hn "$hname" --arg hv "$hvalue" '
        (.clients[] | select(.name==$n)).subscription.headers =
            (((.clients[] | select(.name==$n)).subscription.headers // [])
            | [.[] | select(.name != $hn)] + [{name: $hn, value: $hv}])
    ' || return 1
    success "Заголовок установлен: $hname: $hvalue (клиент: $client)"
    info "Запустите публикацию для $client чтобы применить."
}

subscription_del_header() {
    local client="${1:-}" hname="${2:-}"
    [[ -n "$client" && -n "$hname" ]] || { rc_fail usage "Клиент и имя заголовка обязательны."; return 1; }
    _sub_client_exists "$client" || { rc_fail not_found "Клиент '$client' не найден."; return 1; }

    jq_w --arg n "$client" --arg hn "$hname" '
        (.clients[] | select(.name==$n)).subscription.headers =
            (((.clients[] | select(.name==$n)).subscription.headers // [])
            | [.[] | select(.name != $hn)])
    ' || return 1
    success "Заголовок удалён: $hname (клиент: $client)"
    info "Запустите публикацию для $client чтобы применить."
}

subscription_group_set_header() {
    local group="${1:-}" hname="${2:-}" hvalue="${3:-}"
    [[ -n "$group" && -n "$hname" && -n "$hvalue" ]] || { rc_fail usage "Группа, имя и значение заголовка обязательны."; return 1; }
    _sub_group_exists "$group" || { rc_fail not_found "Группа '$group' не найдена."; return 1; }
    _sub_header_validate "$hname" "$hvalue" || return 1

    jq_w --arg g "$group" --arg hn "$hname" --arg hv "$hvalue" '
        (.groups[] | select(.name==$g)).subscription_headers =
            (((.groups[] | select(.name==$g)).subscription_headers // [])
            | [.[] | select(.name != $hn)] + [{name: $hn, value: $hv}])
    ' || return 1
    success "Заголовок установлен: $hname: $hvalue (группа: $group)"
    info "Запустите 'Обновить все подписки' чтобы применить."
}

subscription_group_del_header() {
    local group="${1:-}" hname="${2:-}"
    [[ -n "$group" && -n "$hname" ]] || { rc_fail usage "Группа и имя заголовка обязательны."; return 1; }
    _sub_group_exists "$group" || { rc_fail not_found "Группа '$group' не найдена."; return 1; }

    jq_w --arg g "$group" --arg hn "$hname" '
        (.groups[] | select(.name==$g)).subscription_headers =
            (((.groups[] | select(.name==$g)).subscription_headers // [])
            | [.[] | select(.name != $hn)])
    ' || return 1
    success "Заголовок удалён: $hname (группа: $group)"
    info "Запустите 'Обновить все подписки' чтобы применить."
}

# subscription_headers_apply KIND TARGET N [NAME VALUE]×N [NAME]… — N установок и
# удаления заголовков клиента (KIND=client) или группы (group): сначала проверки
# всех пар, затем одна запись jq_w (установки, затем удаления — как --set/--unset).
subscription_headers_apply() {
    local kind="${1:-}" target="${2:-}" count="${3:-}" ops='[]' name value
    [[ $# -ge 3 ]] && shift 3 || shift $#
    case "$kind" in
        client) _sub_client_exists "$target" || { rc_fail not_found "Клиент '$target' не найден."; return 1; } ;;
        group) _sub_group_exists "$target" || { rc_fail not_found "Группа '$target' не найдена."; return 1; } ;;
        *) rc_fail usage "Заголовки изменяются только у клиента или группы."; return 1 ;;
    esac
    if [[ ! "$count" =~ ^[0-9]+$ ]] || (( $# < count * 2 )); then
        rc_fail usage "Неполный список заголовков."
        return 1
    fi
    while (( count > 0 )); do
        name="$1" value="$2"
        shift 2
        count=$((count - 1))
        [[ -n "$name" && -n "$value" ]] || { rc_fail usage "Имя и значение заголовка обязательны."; return 1; }
        _sub_header_validate "$name" "$value" || return 1
        ops=$(jq -c --arg n "$name" --arg v "$value" '. + [{name: $n, value: $v}]' <<< "$ops") || return 1
    done
    for name in "$@"; do
        [[ -n "$name" ]] || { rc_fail usage "Флаг --unset ожидает имя заголовка."; return 1; }
        ops=$(jq -c --arg n "$name" '. + [{name: $n}]' <<< "$ops") || return 1
    done
    jq_w --arg k "$kind" --arg t "$target" --argjson ops "$ops" '
        def apply: reduce $ops[] as $o (. // [];
            [.[] | select(.name != $o.name)] + (if $o | has("value") then [{name: $o.name, value: $o.value}] else [] end));
        if $k == "client" then (.clients[] | select(.name==$t)).subscription.headers |= apply
        else (.groups[] | select(.name==$t)).subscription_headers |= apply end' || return 1
    if [[ "$kind" == client ]]; then
        success "Заголовки подписки обновлены (клиент: $target)"
        info "Запустите публикацию для $target чтобы применить."
    else
        success "Заголовки подписки обновлены (группа: $target)"
        info "Запустите 'Обновить все подписки' чтобы применить."
    fi
}
