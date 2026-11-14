#!/bin/bash
# ─── Базовые этапы исполнителя ──────────────────────────────────────────────
# Подключается из apply.sh; использует $R, $OP, $NODE_DIR, $AGENT_DIR и spec.
# Каждый этап возвращает ненулевой код при сбое; `error` не вызывается.

MIHOMO_BIN_REL=/usr/local/bin/mihomo

# agent_apt_wait — ждать освобождения блокировок apt/dpkg без вопросов.
# Лимит — AGENT_APT_WAIT_SECONDS (по умолчанию 300 с); по истечении — код 1.
agent_apt_wait() {
    local limit="${AGENT_APT_WAIT_SECONDS:-300}" waited=0 lock busy
    local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
    while true; do
        busy=""
        for lock in "${locks[@]}"; do
            if fuser "$R$lock" >/dev/null 2>&1; then
                busy="$lock"
                break
            fi
        done
        [[ -z "$busy" ]] && return 0
        if ((waited >= limit)); then
            warn "Блокировка apt ($busy) не освободилась за ${limit} с."
            return 1
        fi
        if ((waited % 30 == 0)); then
            info "Ожидаю завершения другого процесса apt ($busy)..."
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

# Транзакция затронула /etc/nginx/ (установка или удаление).
tx_touches_nginx() {
    local path
    for path in "${TX_PATHS[@]}"; do
        [[ "$path" == /etc/nginx/* ]] && return 0
    done
    return 1
}

# ─── packages ───────────────────────────────────────────────────────────────
stage_packages() {
    local pkgs=(curl wget unzip ufw openssl dnsutils cron)
    [[ "$NGINX" == true ]] && pkgs+=(nginx)
    [[ "$NGINX_STREAM" == true ]] && pkgs+=(libnginx-mod-stream)
    agent_apt_wait || return 1
    DEBIAN_FRONTEND=noninteractive apt-get update -q || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${pkgs[@]}" || return 1
    if [[ "$NGINX" == true ]]; then
        systemctl enable nginx || return 1
    fi
}

# ─── system ─────────────────────────────────────────────────────────────────
stage_system() {
    local ports=() port
    if ufw status 2>/dev/null | grep -q '^Status: active'; then
        return 0
    fi
    # Порт, к которому подключается RC, и порт sshd на сервере (NAT/проброс).
    read -r -a ports <<<"$SSH_PORTS"
    ((${#ports[@]})) || ports=(22)
    for port in "${ports[@]}"; do
        [[ "$port" =~ ^[0-9]{1,5}$ ]] || { warn "Некорректный SSH-порт: $port"; return 1; }
        ufw allow "$port/tcp" || return 1
    done
    ufw default deny incoming || return 1
    ufw default allow outgoing || return 1
    ufw --force enable || return 1
}

# ─── mihomo ─────────────────────────────────────────────────────────────────
stage_mihomo() {
    local bin="$R$MIHOMO_BIN_REL" latest="$MIHOMO_VERSION"
    if [[ -z "$latest" ]]; then
        warn "Не задана версия mihomo."
        return 1
    fi
    if [[ -x "$bin" ]] && "$bin" -v 2>/dev/null | grep -qF -- "$latest"; then
        return 0
    fi
    info "Версия: $latest"

    local arch
    case "$(uname -m)" in
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7) arch="armv7" ;;
        *)
            local cpu_flags
            cpu_flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || echo "")
            if echo "$cpu_flags" | grep -qw "avx2"; then
                arch="amd64-v3"
            elif echo "$cpu_flags" | grep -qw "sse4_2"; then
                arch="amd64-v2"
            else
                arch="amd64"
            fi
            ;;
    esac
    # Бинарник только скачивается в каталог операции; заменяет его этап config
    # внутри транзакции, чтобы откат вернул прежнюю версию.
    local download_dir staged="$OP/mihomo.new"
    download_dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/essence-mihomo.XXXXXX") || {
        warn "Не удалось подготовить временный каталог для Mihomo."
        return 1
    }
    if ! curl -fLo "$download_dir/mihomo.gz" \
        "https://github.com/MetaCubeX/mihomo/releases/download/${latest}/mihomo-linux-${arch}-${latest}.gz" ||
       ! gunzip -f "$download_dir/mihomo.gz" ||
       ! mv -f "$download_dir/mihomo" "$staged" ||
       ! chmod 0755 "$staged"; then
        rm -rf -- "$download_dir"
        rm -f -- "$staged"
        warn "Не удалось скачать бинарник Mihomo."
        return 1
    fi
    rm -rf -- "$download_dir"
}

# install_mihomo — заменить бинарник скачанным этапом mihomo (если есть).
install_mihomo() {
    local staged="$OP/mihomo.new" bin="$R$MIHOMO_BIN_REL"
    [[ -f "$staged" ]] || return 0
    (umask 022; mkdir -p "$(dirname "$bin")") || return 1
    if ! mv -f -- "$staged" "$bin.new" || ! chmod 0755 "$bin.new" || ! mv -f -- "$bin.new" "$bin"; then
        rm -f -- "$bin.new"
        warn "Не удалось установить бинарник Mihomo."
        return 1
    fi
}

# ─── dns ────────────────────────────────────────────────────────────────────
external_ipv4() {
    local url ip
    for url in https://ifconfig.me https://icanhazip.com https://api4.ipify.org; do
        ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}

stage_dns() {
    [[ -n "$DNS_DOMAINS" ]] || return 0
    local ip domain resolved
    ip=$(external_ipv4) || { warn "Не удалось определить внешний IPv4."; return 1; }
    for domain in $DNS_DOMAINS; do
        resolved=$(getent ahostsv4 "$domain" | awk '{print $1; exit}')
        if [[ "$resolved" != "$ip" ]]; then
            warn "A-запись $domain (${resolved:-нет}) не указывает на $ip."
            return 1
        fi
    done
}

# ─── site ───────────────────────────────────────────────────────────────────
# site_fetch <simple|sni|nothing|random> <каталог> — сайт-заглушка без вопросов.
# Порт _randomhtml: при сбое загрузки по одной попытке на остальные источники.
site_fetch() (
    local template_source="$1" target_dir="$2"
    umask 022
    local template_urls=(
        "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip"
        "https://github.com/distillium/sni-templates/archive/refs/heads/main.zip"
        "https://github.com/prettyleaf/nothing-sni/archive/refs/heads/main.zip"
    )
    local first
    case "$template_source" in
        simple) first=0 ;;
        sni) first=1 ;;
        nothing) first=2 ;;
        random|"") first=$((RANDOM % 3)) ;;
        *) warn "Неизвестный источник сайта: $template_source"; return 1 ;;
    esac

    local work
    work=$(mktemp -d "${TMPDIR:-/tmp}/essence-site.XXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    cd "$work" || return 1

    local i selected_url="" order=("$first")
    for i in 0 1 2; do
        [[ "$i" == "$first" ]] || order+=("$i")
    done
    info "Скачиваю шаблон..."
    for i in "${order[@]}"; do
        if wget --timeout=15 --tries=2 -q "${template_urls[$i]}" -O main.zip; then
            selected_url="${template_urls[$i]}"
            break
        fi
        warn "Не удалось скачать шаблон: ${template_urls[$i]}"
        rm -f main.zip
    done
    [[ -n "$selected_url" ]] || return 1

    if ! unzip -o main.zip &>/dev/null; then
        warn "Не удалось распаковать архив шаблона"
        return 1
    fi
    rm -f main.zip

    local template_dir
    if [[ "$selected_url" == *"eGamesAPI"* ]]; then
        template_dir="simple-web-templates-main"
        cd "$template_dir" || return 1
        rm -rf assets ".gitattributes" "README.md" "_config.yml" 2>/dev/null
    elif [[ "$selected_url" == *"nothing-sni"* ]]; then
        template_dir="nothing-sni-main"
        cd "$template_dir" || return 1
        rm -rf .github README.md 2>/dev/null
    else
        template_dir="sni-templates-main"
        cd "$template_dir" || return 1
        rm -rf assets "README.md" "index.html" 2>/dev/null
    fi

    local RandomHTML
    if [[ "$selected_url" == *"nothing-sni"* ]]; then
        local selected_number=$((RANDOM % 8 + 1))
        RandomHTML="${selected_number}.html"
    else
        local templates=() template
        while IFS= read -r template; do
            templates+=("$template")
        done < <(find . -maxdepth 1 -type d -not -path . | sed 's|./||')
        ((${#templates[@]} > 0)) || { warn "Архив шаблона пуст"; return 1; }
        RandomHTML="${templates[$RANDOM % ${#templates[@]}]}"
    fi

    if [[ "$selected_url" == *"distillium"* && "$RandomHTML" == "503 error pages" ]]; then
        local versions=("v1" "v2")
        local RandomVersion="${versions[$RANDOM % ${#versions[@]}]}"
        RandomHTML="$RandomHTML/$RandomVersion"
    fi

    # ── Антифингерпринтинг ────────────────────────────────────────────────────
    local random_meta_id random_comment random_class_suffix random_title_suffix
    local random_id_suffix random_meta_name random_username random_class_prefix
    random_meta_id=$(openssl rand -hex 16)
    random_comment=$(openssl rand -hex 8)
    random_class_suffix=$(openssl rand -hex 4)
    random_title_suffix=$(openssl rand -hex 4)
    random_id_suffix=$(openssl rand -hex 4)

    local meta_names=("viewport-id" "session-id" "track-id" "render-id" "page-id" "config-id")
    local meta_usernames=("Payee6296" "UserX1234" "AlphaBeta" "GammaRay" "DeltaForce" "EchoZulu" "Foxtrot99" "HotelCalifornia" "IndiaInk" "JulietBravo")
    local class_prefixes=("style" "data" "ui" "layout" "theme" "view")

    random_meta_name=${meta_names[$RANDOM % ${#meta_names[@]}]}
    random_username=${meta_usernames[$RANDOM % ${#meta_usernames[@]}]}
    random_class_prefix=${class_prefixes[$RANDOM % ${#class_prefixes[@]}]}

    local random_class="${random_class_prefix}-${random_class_suffix}"
    local random_title="Page_${random_title_suffix}"
    local random_footer_text="Designed by RandomSite_${random_title_suffix}"

    find "./$RandomHTML" -type f -name "*.html" -exec sed -i \
        -e "s|<!-- Website template by freewebsitetemplates.com -->||" \
        -e "s|<!-- Theme by: WebThemez.com -->||" \
        -e "s|<a href=\"http://freewebsitetemplates.com\">Free Website Templates</a>|<span>${random_footer_text}</span>|" \
        -e "s|<a href=\"http://webthemez.com\" alt=\"webthemez\">WebThemez.com</a>|<span>${random_footer_text}</span>|" \
        -e "s|id=\"Content\"|id=\"rnd_${random_id_suffix}\"|" \
        -e "s|id=\"subscribe\"|id=\"sub_${random_id_suffix}\"|" \
        -e "s|<title>.*</title>|<title>${random_title}</title>|" \
        -e "s/<\/head>/<meta name=\"${random_meta_name}\" content=\"${random_meta_id}\">\n<!-- ${random_comment} -->\n<\/head>/" \
        -e "s/<body/<body class=\"${random_class}\"/" \
        -e "s/CHANGEMEPLS/${random_username}/g" \
        {} \;

    find "./$RandomHTML" -type f -name "*.css" -exec sed -i \
        -e "1i\/* ${random_comment} */" \
        -e "1i.${random_class} { display: block; }" \
        {} \;

    info "Выбран шаблон: $RandomHTML"

    mkdir -p "$target_dir" || return 1
    if [[ -d "${RandomHTML}" ]]; then
        rm -rf "${target_dir:?}"/*
        cp -a "${RandomHTML}"/. "$target_dir/" || return 1
    elif [[ -f "${RandomHTML}" ]]; then
        cp "${RandomHTML}" "$target_dir/index.html" || return 1
    else
        warn "Шаблон '$RandomHTML' не найден в распакованном архиве"
        return 1
    fi
    success "Шаблон скопирован в $target_dir"
)

stage_site() {
    [[ -n "$SITE_NAME" ]] || return 0
    local www="$R/var/www/$SITE_NAME"
    (umask 022; mkdir -p "$www") || return 1
    mkdir -p "$R/etc/nginx/ssl/$SITE_NAME" || return 1
    [[ -e "$www/.essence-site" ]] && return 0
    # Каталог без отметки с содержимым — чужой сайт: site_fetch стёр бы его без копии.
    if [[ -n "$(ls -A -- "$www")" ]]; then
        warn "В /var/www/$SITE_NAME уже есть сайт без отметки Essence — не заменяю."
        return 1
    fi
    site_fetch "$SITE_SOURCE" "$www" || return 1
    (umask 022; : >"$www/.essence-site") || return 1
}

# ─── certificate ────────────────────────────────────────────────────────────
# parse_cert_entries <список> — записи «имя:/var/www/имя» в CERT_ENTRIES.
# Разбор без glob; любая некорректная запись — сбой этапа.
parse_cert_entries() {
    local entry name list=()
    CERT_ENTRIES=()
    read -r -d '' -a list <<<"$1" || true
    for entry in "${list[@]}"; do
        name="${entry%%:*}"
        if [[ "$entry" != *:* || ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ || "$name" == *..* ||
              "${entry#*:}" != "/var/www/$name" ]]; then
            warn "Некорректная запись сертификата: $entry"
            return 1
        fi
        CERT_ENTRIES+=("$entry")
    done
}

stage_certificate() {
    [[ -n "$CERTS" ]] || return 0
    local entry name webroot
    parse_cert_entries "$CERTS" || return 1
    ensure_acme_installed "$ACME_EMAIL" || return 1
    for entry in "${CERT_ENTRIES[@]}"; do
        name="${entry%%:*}"
        webroot="${entry#*:}"
        (umask 022; mkdir -p "$R$webroot") || return 1
        ensure_cert "$name" "$R$webroot" false "$R/etc/nginx/ssl" \
            "$R/etc/nginx/sites-available" "$R/etc/nginx/sites-enabled" "$R/etc/nginx/nginx.conf" || return 1
    done
}

# ─── prepare ────────────────────────────────────────────────────────────────
stage_prepare() {
    local hy2="$R/etc/mihomo/certs/hy2" feature
    if [[ "$HY2_CERT" == true && ! -f "$hy2/server.crt" ]]; then
        [[ -n "$HY2_CN" ]] || { warn "Не задан CN сертификата Hysteria2."; return 1; }
        mkdir -p "$hy2" && chmod 0700 "$hy2" || return 1
        openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
            -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=$HY2_CN" \
            -keyout "$hy2/server.key" \
            -out    "$hy2/server.crt" 2>/dev/null || {
            warn "Не удалось создать сертификат"
            rm -f "$hy2/server.key" "$hy2/server.crt"
            return 1
        }
        chmod 0600 "$hy2/server.key" || return 1
    fi
    for feature in $FEATURES; do
        feature_hook "$feature" prepare || return 1
    done
}

# ─── config: транзакция ─────────────────────────────────────────────────────
# managed_path <путь> — путь из files.list/remove.list входит в набор, которым
# управляет RC; без сегментов «..»/«.», «//», пробелов и управляющих символов.
managed_path() {
    local path="$1"
    [[ "$path" == /* && "$path" != */ && "$path" != *//* ]] || return 1
    [[ "$path/" != */../* && "$path/" != */./* ]] || return 1
    [[ ! "$path" =~ [[:space:][:cntrl:]] ]] || return 1
    case "$path" in
        /etc/mihomo|/etc/mihomo/*|/etc/systemd/system/mihomo.service|/etc/sysctl.d/99-vpn-speedup.conf)
            return 0 ;;
    esac
    [[ "$path" == /etc/nginx/modules-enabled/90-essence-stream.conf ||
       "$path" =~ ^/etc/nginx/(sites-available|sites-enabled)/[^/]+$ ]]
}

check_path() {
    managed_path "$1" && return 0
    warn "Путь вне управляемого набора: $1"
    return 1
}

# removable <путь> — удалять ли путь из remove.list (отсутствующий — нечего).
# Сайты nginx удаляются, только если они наши: файл sites-available/<имя> с
# первой строкой «# Essence site <имя>», ссылка sites-enabled/<имя> на
# /etc/nginx/sites-available/<имя>. Чужие пропускаются с предупреждением.
removable() {
    local path="$1" dest="$R$1" name="${1##*/}" first=""
    [[ -e "$dest" || -L "$dest" ]] || return 1
    case "$path" in
        /etc/nginx/sites-available/*)
            if [[ -f "$dest" && ! -L "$dest" ]]; then
                IFS= read -r first <"$dest" || true
            fi
            [[ "$first" == "# Essence site $name" ]] && return 0
            warn "Пропускаю $path: нет отметки Essence."
            return 1 ;;
        /etc/nginx/sites-enabled/*)
            [[ -L "$dest" && "$(readlink -- "$dest")" == "/etc/nginx/sites-available/$name" ]] && return 0
            warn "Пропускаю $path: это не ссылка на сайт Essence."
            return 1 ;;
    esac
}

# tx_backup <абсолютный путь> — копия в <op>/backup/<путь> либо отметка .absent.
tx_backup() {
    local path="$1" dest="$R$1" bak="$OP/backup$1" known
    [[ "$path" == "$MIHOMO_BIN_REL" ]] || check_path "$path" || return 1
    for known in "${TX_PATHS[@]}"; do
        [[ "$known" == "$path" ]] && return 0
    done
    mkdir -p "$(dirname "$bak")" || return 1
    if [[ -e "$dest" || -L "$dest" ]]; then
        cp -a -- "$dest" "$bak" || return 1
    else
        : >"$bak.absent" || return 1
    fi
    TX_PATHS+=("$path")
}

# tx_restore_files — вернуть все пути транзакции; код 1, если хоть один не вернулся.
tx_restore_files() {
    local path dest bak rc=0
    for path in "${TX_PATHS[@]}"; do
        dest="$R$path"
        bak="$OP/backup$path"
        if [[ -e "$bak.absent" ]]; then
            rm -rf -- "$dest" || rc=1
        elif [[ -e "$bak" || -L "$bak" ]]; then
            if ! rm -rf -- "$dest" || ! mkdir -p "$(dirname "$dest")" || ! cp -a -- "$bak" "$dest"; then
                warn "Не удалось восстановить $path."
                rc=1
            fi
        fi
    done
    return "$rc"
}

# port_handover <restart|reload|none> — mihomo остановлен, пока nginx занимает
# или освобождает общие порты (443), затем запускается заново. Все шаги
# выполняются и при сбое одного из них (откат зовёт то же самое).
port_handover() {
    local rc=0
    systemctl stop mihomo || rc=1
    case "$1" in
        restart) systemctl restart nginx || rc=1 ;;
        reload) { nginx -t && systemctl reload nginx; } || rc=1 ;;
    esac
    systemctl start mihomo || rc=1
    if ! wait_active mihomo "${AGENT_ACTIVE_WAIT_SECONDS:-15}"; then
        warn "mihomo не запустился."
        rc=1
    fi
    return "$rc"
}

# listen_ready — каждый порт LISTEN_TCP в состоянии LISTEN (ss -Htln);
# ждёт до AGENT_LISTEN_WAIT_SECONDS (по умолчанию 10 с).
listen_ready() {
    local limit="${AGENT_LISTEN_WAIT_SECONDS:-10}" ports=() port missing listening i
    read -r -a ports <<<"$LISTEN_TCP"
    ((${#ports[@]})) || return 0
    for port in "${ports[@]}"; do
        [[ "$port" =~ ^[0-9]{1,5}$ ]] || { warn "Некорректный порт LISTEN_TCP: $port"; return 1; }
    done
    for ((i = 1; ; i++)); do
        missing=""
        listening=$(ss -Htln 2>/dev/null | awk '{ n = split($4, a, ":"); print a[n] }')
        for port in "${ports[@]}"; do
            grep -qxF -- "$port" <<<"$listening" || { missing="$port"; break; }
        done
        [[ -z "$missing" ]] && return 0
        ((i >= limit)) && break
        sleep 1
    done
    warn "Порт $missing не слушается."
    return 1
}

# tx_open — открыть транзакцию и запомнить службы, работавшие до неё
# (TX_ACTIVE): откат обязан вернуть их в работу.
tx_open() {
    local unit
    TX_ACTIVE=""
    for unit in mihomo nginx; do
        systemctl is-active --quiet "$unit" 2>/dev/null && TX_ACTIVE+="$unit "
    done
    TX_OPEN=true
}

# Откат: вызывается из finish() при открытой транзакции. Код 1 — откат не
# завершён: не вернулись файлы или правила UFW, не работает служба, которая
# работала до транзакции, или отказал откат фичи (тогда finish сохраняет
# backup/). Службы, не работавшие до транзакции (новая нода), не требуются.
tx_rollback() {
    local feature unit nginx_action=none rc=0
    warn "Откат изменений."
    tx_restore_files || rc=1
    tx_restore_firewall || rc=1
    systemctl daemon-reload
    if [[ "$OP_MODE" == teardown ]]; then
        systemctl enable mihomo
    fi
    if [[ "$NGINX" == true || "$OP_MODE" == teardown ]] && command -v nginx >/dev/null 2>&1; then
        nginx_action=restart
    elif tx_touches_nginx && command -v nginx >/dev/null 2>&1; then
        nginx_action=reload
    fi
    port_handover "$nginx_action"
    sysctl --system >/dev/null
    for feature in $FEATURES; do
        if ! feature_hook "$feature" rollback; then
            warn "Откат фичи $feature не удался."
            rc=1
        fi
    done
    for unit in $TX_ACTIVE; do
        if ! systemctl is-active --quiet "$unit"; then
            warn "Служба $unit работала до операции, а после отката не запущена."
            rc=1
        fi
    done
    TX_OPEN=false
    return "$rc"
}

# read_list <файл> — пути без пустых строк.
read_list() {
    [[ -f "$1" ]] || return 0
    grep -v '^[[:space:]]*$' "$1"
}

install_file() {
    local mode="$1" owner="$2" group="$3" path="$4"
    local src="$OP/files$path" dest="$R$path" dir tmp
    [[ -e "$src" ]] || { warn "Нет файла операции: $path"; return 1; }
    dir="$(dirname "$dest")"
    (umask 022; mkdir -p "$dir") || return 1
    if [[ "$mode" == link ]]; then
        rm -rf -- "$dest" 2>/dev/null
        ln -sfn -- "$(cat "$src")" "$dest" || return 1
        return 0
    fi
    [[ "$mode" =~ ^[0-7]{4}$ ]] || { warn "Некорректный режим $mode для $path"; return 1; }
    tmp=$(mktemp "$dir/.essence.XXXXXX") || return 1
    if ! cat -- "$src" >"$tmp" ||
       ! chown "$owner:$group" "$tmp" ||
       ! chmod "$mode" "$tmp" ||
       ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        return 1
    fi
}

wait_active() {
    local unit="$1" seconds="$2" i
    for ((i = 0; i < seconds; i++)); do
        systemctl is-active --quiet "$unit" && return 0
        sleep 1
    done
    systemctl is-active --quiet "$unit"
}

stage_config() {
    local mode owner group path feature code nginx_action=none
    local entries=() removes=()
    while read -r mode owner group path; do
        [[ -n "${mode:-}" ]] || continue
        check_path "$path" || return 1
        entries+=("$mode $owner $group $path")
    done < <(read_list "$OP/files.list")
    while IFS= read -r path; do
        check_path "$path" || return 1
        removable "$path" || continue
        removes+=("$path")
    done < <(read_list "$OP/remove.list")

    tx_open
    for path in "${entries[@]}"; do
        read -r mode owner group path <<<"$path"
        tx_backup "$path" || return 1
    done
    for path in "${removes[@]}"; do
        tx_backup "$path" || return 1
    done
    if [[ -f "$OP/mihomo.new" ]]; then
        tx_backup "$MIHOMO_BIN_REL" || return 1
    fi

    for path in "${entries[@]}"; do
        read -r mode owner group path <<<"$path"
        install_file "$mode" "$owner" "$group" "$path" || return 1
    done
    for path in "${removes[@]}"; do
        rm -rf -- "$R$path" || return 1
    done
    install_mihomo || return 1

    sysctl --system >/dev/null || return 1
    "$R$MIHOMO_BIN_REL" -t -d "$R/etc/mihomo" -f "$R/etc/mihomo/config.yaml" || return 1
    if [[ "$NGINX" == true ]]; then
        nginx -t || return 1
    fi
    systemctl daemon-reload || return 1
    systemctl enable mihomo || return 1
    if [[ "$NGINX" == true ]]; then
        nginx_action=restart
    elif tx_touches_nginx && command -v nginx >/dev/null 2>&1; then
        nginx_action=reload
    fi
    port_handover "$nginx_action" || return 1
    listen_ready || return 1
    if [[ "$SITE_REQUIRE_200" == true ]]; then
        code=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443 -H "Host: $SITE_NAME")
        [[ "$code" == 200 ]] || { warn "Сайт-заглушка ответил $code."; return 1; }
    fi
    for feature in $FEATURES; do
        feature_hook "$feature" activate || return 1
    done
}

stage_teardown_config() {
    local path removes=() sysctl_removed=false
    while IFS= read -r path; do
        check_path "$path" || return 1
        removable "$path" || continue
        removes+=("$path")
    done < <(read_list "$OP/remove.list")

    tx_open
    for path in "${removes[@]}" "$MIHOMO_BIN_REL"; do
        tx_backup "$path" || return 1
    done
    # Сначала disable: без файла юнита systemctl disable отказывает.
    systemctl disable --now mihomo || return 1
    for path in "${removes[@]}"; do
        [[ "$path" == /etc/sysctl.d/99-vpn-speedup.conf ]] && sysctl_removed=true
        rm -rf -- "$R$path" || return 1
    done
    rm -f -- "$R$MIHOMO_BIN_REL" || return 1
    systemctl daemon-reload || return 1
    if command -v nginx >/dev/null 2>&1; then
        { nginx -t && systemctl reload nginx; } || return 1
    fi
    if [[ "$sysctl_removed" == true ]]; then
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 \
            net.ipv6.conf.lo.disable_ipv6=0 >/dev/null || return 1
        sysctl --system >/dev/null || return 1
    fi
}

# ─── firewall ───────────────────────────────────────────────────────────────
# stage_firewall "<правила>" — учёт своих правил в $NODE_DIR/ufw-rules.
# Правило, которое уже было в `ufw show added` до нас, принадлежит
# администратору: в учёт не попадает и нами не удаляется. Учтённое правило,
# которого в UFW больше нет, добавляется заново. Учёт сохраняется после
# каждого изменения UFW, чтобы сбой посреди этапа не терял свои правила.
# Списки have/want — строки «правило\n» (без ассоциативных массивов).
# FW_ADDED/FW_DELETED (из apply.sh) — свои правила, добавленные и удалённые
# этой операцией: по ним откат возвращает UFW и учёт.
stage_firewall() {
    local ledger="$NODE_DIR/ufw-rules" rule added="" wanted=() have="" want="" snapshot
    if [[ -f "$ledger" ]]; then
        while IFS= read -r rule; do
            [[ -n "$rule" ]] && ! in_list "$have" "$rule" && have+="$rule"$'\n'
        done <"$ledger"
    fi
    read -r -a wanted <<<"$1"
    if ((${#wanted[@]})); then
        added=$(ufw show added 2>/dev/null) || { warn "Не удалось прочитать правила UFW."; return 1; }
    fi
    for rule in "${wanted[@]}"; do
        want+="$rule"$'\n'
        if grep -qxF -- "ufw allow $rule" <<<"$added"; then
            in_list "$have" "$rule" ||
                info "Правило UFW $rule уже было добавлено вручную — не учитываю."
            continue
        fi
        ufw allow "$rule" || return 1
        in_list "$have" "$rule" && continue
        have+="$rule"$'\n'
        FW_ADDED+="$rule"$'\n'
        ledger_save || return 1
    done
    snapshot="$have"
    while IFS= read -r rule <&3; do
        [[ -n "$rule" ]] || continue
        in_list "$want" "$rule" && continue
        ufw delete allow "$rule" || return 1
        have_remove "$rule"
        FW_DELETED+="$rule"$'\n'
        ledger_save || return 1
    done 3<<<"$snapshot"
    ledger_save
}

# tx_restore_firewall — вернуть удалённые этой операцией правила и снять
# добавленные; учёт меняется только для правил, которые удалось вернуть.
tx_restore_firewall() {
    local ledger="$NODE_DIR/ufw-rules" have="" rule rc=0
    [[ -n "$FW_ADDED$FW_DELETED" ]] || return 0
    if [[ -f "$ledger" ]]; then
        have=$(grep -v '^$' "$ledger")
        [[ -z "$have" ]] || have+=$'\n'
    fi
    while IFS= read -r rule <&3; do
        [[ -n "$rule" ]] || continue
        if ufw allow "$rule"; then
            in_list "$have" "$rule" || have+="$rule"$'\n'
        else
            warn "Не удалось вернуть правило UFW $rule."
            rc=1
        fi
    done 3<<<"$FW_DELETED"
    while IFS= read -r rule <&3; do
        [[ -n "$rule" ]] || continue
        if ufw delete allow "$rule"; then
            have_remove "$rule"
        else
            warn "Не удалось снять правило UFW $rule."
            rc=1
        fi
    done 3<<<"$FW_ADDED"
    ledger_save || rc=1
    FW_ADDED="" FW_DELETED=""
    return "$rc"
}

# have_remove <правило> — убрать правило из списка have вызывающей функции.
have_remove() {
    have=$(printf '%s' "$have" | grep -vxF -- "$1")
    [[ -z "$have" ]] || have+=$'\n'
}

# in_list <список «строка\n»> <строка> — строка есть в списке.
in_list() {
    [[ $'\n'"$1" == *$'\n'"$2"$'\n'* ]]
}

# ledger_save — атомарно записать список have (из stage_firewall) в $ledger.
ledger_save() {
    printf '%s' "$have" | sort >"$ledger.tmp" || return 1
    mv -f -- "$ledger.tmp" "$ledger"
}

# ─── cleanup ────────────────────────────────────────────────────────────────
# stage_cleanup — часть внутри транзакции: только проверка RELEASE_CERTS.
# Необратимое (снятие фич и сертификатов, удаление каталогов) — в
# cleanup_committed после записи committed: откат после него вернул бы сайт
# nginx без сертификата и webroot.
stage_cleanup() {
    parse_cert_entries "$RELEASE_CERTS"
}

# cleanup_committed — после committed, по возможности: сбой — предупреждение,
# итог операции не меняется.
# apply: пять последних операций и только текущий исполнитель.
# teardown: все остальные операции и исполнители; свой каталог исполнителя
# apply.sh удаляет сам, от своей операции остаются status и log.
# Операция с result=rollback_failed не удаляется: её backup/ — последняя копия.
cleanup_committed() {
    local feature entry name webroot dir self
    for feature in $REMOVE_FEATURES; do
        feature_hook "$feature" remove || warn "Не удалось снять фичу $feature."
    done
    for entry in "${CERT_ENTRIES[@]}"; do
        name="${entry%%:*}"
        webroot="${entry#*:}"
        if [[ ! -e "$R$webroot/.essence-site" ]]; then
            warn "Пропускаю сертификат $name: в $webroot нет отметки Essence."
            continue
        fi
        if ! release_cert "$name" "$R$webroot" "$R/etc/nginx/ssl" \
            "$R/etc/nginx/sites-available" "$R/etc/nginx/sites-enabled" "$R/etc/nginx/nginx.conf"; then
            warn "Не удалось снять сертификат $name."
            continue
        fi
        rm -rf -- "$R$webroot"
    done
    if [[ "$HY2_CERT" != true ]]; then
        rm -rf -- "$R/etc/mihomo/certs/hy2"
    fi
    if [[ "$WARP" == false ]]; then
        rm -rf -- "$R/root/wgcf"
    fi
    if [[ -d "$NODE_DIR/ops" ]]; then
        while IFS= read -r dir; do
            [[ "$(cd "$dir" && pwd -P)" == "$OP" ]] && continue
            if grep -qx 'result=rollback_failed' "$dir/status" 2>/dev/null; then
                warn "Оставляю операцию $(basename "$dir"): её откат не завершён."
                continue
            fi
            rm -rf -- "${dir%/}"
        done < <(if [[ "$OP_MODE" == teardown ]]; then
                     ls -1d "$NODE_DIR/ops"/*/ 2>/dev/null
                 else
                     ls -1dt "$NODE_DIR/ops"/*/ 2>/dev/null | tail -n +6
                 fi)
    fi
    if [[ -d "$NODE_DIR/agent" ]]; then
        for dir in "$NODE_DIR/agent"/*/; do
            [[ -d "$dir" ]] || continue
            self="$(cd "$dir" && pwd -P)"
            [[ "$self" == "$AGENT_DIR" ]] && continue
            rm -rf -- "${dir%/}"
        done
    fi
}
