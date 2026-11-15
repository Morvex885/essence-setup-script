#!/bin/bash
# ─── Фича telegram: Telegram Web Proxy (этап 5 плана) ───────────────────────
# Хуки исполнителя для роли Telegram на ноде. mtproxy.env, firewall.nft,
# config.json, profiles.json и vhost рендерит RC (ставит транзакция `config`);
# здесь — сборка и установка бэкенда MTProxy и реле tproxy-server по
# закреплённой ревизии, юниты upstream, ключ токенов, сайт реле, запуск и
# снятие. Перенос v1-модуля telegram-proxy.sh без меню и без
# файла состояния essence.conf. Прямой MTProto (2398 наружу) не открывается.
# Spec: TG_HOST, TG_REPO, TG_REVISION, TG_GO_VERSION, TG_GO_SHA256.
#
# Состояние фичи под $NODE_DIR (переживает откат транзакции):
# - features/telegram — prepare начал ставить компоненты; пока метка есть,
#   cleanup снимает роль, если её нет в FEATURES (см. stage_cleanup);
# - telegram-users — пользователи, созданные Essence (userdel только им);
# - telegram-go — каталог Go, установленный Essence.
#
# Известное ограничение upstream (принято): секрет MTProxy и спонсорский тег
# передаются mtproto-proxy аргументами и видны локальным пользователям ноды
# (ps, /proc/<pid>/cmdline) — см. _tg_render_mtproxy_unit.

TG_DIR="$R/etc/tproxy-server"
TG_TOKEN_KEY="$TG_DIR/token.key"
TG_PROFILES_FILE="/etc/tproxy-server/profiles.json"
TG_MTPROXY_DIR="$R/etc/mtproxy"
TG_ENV_FILE="/etc/mtproxy/mtproxy.env"
TG_SOURCE="$R/opt/tproxy-server-source"
TG_MTPROXY_SOURCE="$R/opt/MTProxy"
TG_SITE="$R/srv/tproxy-site"
TG_BIN="$R/usr/local/bin/tproxy-server"
TG_REFRESH_BIN="$R/usr/local/sbin/refresh-mtproxy-config"
TG_SYSTEMD="$R/etc/systemd/system"
TG_MARKER="$TG_SOURCE/.essence-revision"
TG_UNIT_RELAY="tproxy-server.service"
TG_UNIT_MTPROXY="mtproxy.service"
TG_UNIT_FIREWALL="tproxy-firewall.service"
TG_UNIT_REFRESH="refresh-mtproxy-config.service"
TG_UNIT_TIMER="refresh-mtproxy-config.timer"
TG_NFT_TABLE="tproxy_backend"
TG_READY_ATTEMPTS="${TG_READY_ATTEMPTS:-20}"
# telegram_activate начал перезапуск служб в этой операции (см. telegram_rollback).
TG_ACTIVATED=false

# ─── Проверки upstream (telegram-proxy.sh:402-444, 497-515) ─────────────────

_tg_validate_upstream_unit() {
    local unit="$1" count
    [[ -r "$unit" ]] || return 1
    count=$(grep -c '^ExecStart=' "$unit" 2>/dev/null || true); [[ "$count" == 1 ]] || return 1
    grep -Eq -- '-p[[:space:]]+8888' "$unit" || return 1
    grep -Eq -- '-H[[:space:]]+2398' "$unit" || return 1
    grep -Eq -- '-S[[:space:]]+\$\{?MTPROXY_SECRET\}?' "$unit" || return 1
    grep -Eq 'MTPROXY_(WORKERS|MAX_CONNECTIONS)' "$unit" || return 1
}

_tg_validate_upstream_firewall_unit() {
    local unit="$1"
    [[ -r "$unit" ]] || return 1
    grep -Eq '/etc/tproxy-server/firewall\.nft([[:space:]]|$)' "$unit"
}

# Известное ограничение upstream: юнит передаёт секрет MTProxy (-S) и
# спонсорский тег (-P из MTPROXY_TAG_ARGS) аргументами mtproto-proxy, поэтому
# локальные пользователи ноды видят их в `ps`//proc/<pid>/cmdline. Иначе
# upstream их не принимает; поведение upstream не меняется.
_tg_render_mtproxy_unit() {
    local source="$1" target="$2"
    _tg_validate_upstream_unit "$source" || return 1
    grep -Eq -- '--aes-pwd' "$source" || return 1
    mkdir -p "$(dirname "$target")" || return 1
    awk -v env_file="$TG_ENV_FILE" '
        BEGIN { done = 0; service = 0 }
        /^EnvironmentFile=/ { next }
        /^\[Service\]$/ {
            print
            print "EnvironmentFile=" env_file
            service = 1
            next
        }
        /^ExecStart=/ {
            sub(/[[:space:]]+--aes-pwd/, " $MTPROXY_TAG_ARGS --aes-pwd")
            print
            done = 1
            next
        }
        { print }
        END { if (!done || !service) exit 2 }
    ' "$source" > "$target.tmp.$$" || {
        rm -f "$target.tmp.$$"
        return 1
    }
    chmod 0644 "$target.tmp.$$" && mv -f "$target.tmp.$$" "$target" || {
        rm -f "$target.tmp.$$"
        return 1
    }
    [[ "$(grep -cF '$MTPROXY_TAG_ARGS' "$target" 2>/dev/null || true)" == 1 ]] &&
        [[ "$(grep -c '^EnvironmentFile=' "$target" 2>/dev/null || true)" == 1 ]]
}

# Клон закреплённой ревизии (telegram-proxy.sh:469-476).
_tg_clone_upstream() {
    local stage="$1" revision="$2" actual
    git clone --filter=blob:none --no-checkout "$TG_REPO" "$stage" >/dev/null 2>&1 || return 1
    git -C "$stage" fetch --depth 1 origin "$revision" >/dev/null 2>&1 || return 1
    git -C "$stage" checkout --detach "$revision" >/dev/null 2>&1 || return 1
    actual=$(git -C "$stage" rev-parse HEAD 2>/dev/null) || return 1
    [[ "$actual" == "$revision" ]]
}

# Бэкенд MTProxy и юниты upstream. firewall.nft и mtproxy.env рендерит RC.
_tg_install_backend() {
    local backend_source="$1" unit_source firewall_source
    [[ -f "$backend_source/deploy/install-mtproxy.sh" ]] || return 1
    unit_source="$backend_source/deploy/mtproxy.service"
    [[ -f "$unit_source" ]] || unit_source="$backend_source/deploy/mtproxy.service.in"
    firewall_source="$backend_source/deploy/tproxy-firewall.service"
    [[ -f "$firewall_source" ]] || return 1
    [[ -f "$backend_source/deploy/refresh-mtproxy-config.service" &&
       -f "$backend_source/deploy/refresh-mtproxy-config.timer" &&
       -f "$backend_source/deploy/refresh-mtproxy-config.sh" ]] || return 1
    # Все литералы upstream проверяются до установщика, меняющего хост.
    _tg_validate_upstream_unit "$unit_source" || return 1
    _tg_validate_upstream_firewall_unit "$firewall_source" || return 1
    # Исполнитель работает под umask 077, а сборку upstream делает и запускает
    # пользователь mtproxy: под 077 objs/ получился бы 0700 root (203/EXEC).
    (umask 022; bash "$backend_source/deploy/install-mtproxy.sh" </dev/null) || return 1
    mkdir -p "$TG_SYSTEMD" "$TG_MTPROXY_DIR" "$(dirname "$TG_REFRESH_BIN")" || return 1
    _tg_render_mtproxy_unit "$unit_source" "$TG_SYSTEMD/$TG_UNIT_MTPROXY" || return 1
    install -m 0644 "$firewall_source" "$TG_SYSTEMD/$TG_UNIT_FIREWALL" &&
        install -m 0644 "$backend_source/deploy/refresh-mtproxy-config.service" "$TG_SYSTEMD/$TG_UNIT_REFRESH" &&
        install -m 0644 "$backend_source/deploy/refresh-mtproxy-config.timer" "$TG_SYSTEMD/$TG_UNIT_TIMER" &&
        install -m 0755 "$backend_source/deploy/refresh-mtproxy-config.sh" "$TG_REFRESH_BIN" || return 1
    chown root:root "$TG_SYSTEMD/$TG_UNIT_MTPROXY" "$TG_SYSTEMD/$TG_UNIT_FIREWALL" \
        "$TG_SYSTEMD/$TG_UNIT_REFRESH" "$TG_SYSTEMD/$TG_UNIT_TIMER" "$TG_REFRESH_BIN" || return 1
}

# ─── Ключ токенов (telegram-proxy.sh:348-369) ───────────────────────────────

_tg_ensure_token_key() {
    local key="$TG_TOKEN_KEY" tmp bytes
    if [[ -L "$key" ]] || { [[ -e "$key" ]] && [[ ! -f "$key" ]]; }; then
        return 1
    fi
    mkdir -p "$(dirname "$key")" || return 1
    if [[ ! -e "$key" ]]; then
        tmp=$(umask 077; mktemp "${key}.XXXXXX") || return 1
        if ! head -c 32 /dev/urandom > "$tmp" ||
           ! chmod 0400 "$tmp" ||
           ! chown tproxy:tproxy "$tmp" ||
           ! ln "$tmp" "$key"; then
            rm -f "$tmp"
            return 1
        fi
        rm -f "$tmp"
    fi
    bytes=$(wc -c < "$key" 2>/dev/null | tr -d '[:space:]')
    [[ "$bytes" == 32 ]] || return 1
    chown tproxy:tproxy "$key" || return 1
    chmod 0400 "$key" || return 1
}

# ─── Go и реле (telegram-proxy.sh:1030-1133) ────────────────────────────────

_tg_install_pinned_go() {
    local version="$TG_GO_VERSION" checksum="$TG_GO_SHA256"
    local archive directory
    archive=$(umask 077; mktemp "${TMPDIR:-/tmp}/go-linux-amd64.XXXXXX.tar.gz") || return 1
    directory=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/go-linux-amd64.XXXXXX") || {
        rm -f "$archive"
        return 1
    }
    if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --output "$archive" "https://go.dev/dl/go${version}.linux-amd64.tar.gz" ||
       [[ "$(sha256sum "$archive" | awk '{print $1}')" != "$checksum" ]] ||
       ! tar -C "$directory" -xzf "$archive"; then
        rm -f "$archive"
        rm -rf "$directory"
        return 1
    fi
    if [[ -e "$R/opt/go${version}" ]]; then
        rm -rf "$directory/go"
    else
        mv "$directory/go" "$R/opt/go${version}" || {
            rm -f "$archive"; rm -rf "$directory"; return 1;
        }
        # Каталог Go поставлен Essence — его снимет telegram_remove.
        printf '%s\n' "/opt/go${version}" > "$NODE_DIR/telegram-go"
    fi
    rm -f "$archive"
    rm -rf "$directory"
    [[ -x "$R/opt/go${version}/bin/go" ]] || return 1
    printf '%s\n' "$R/opt/go${version}/bin/go"
}

_tg_find_go() {
    local candidate version minor
    for candidate in "$(command -v go 2>/dev/null || true)" "$R"/opt/go*/bin/go; do
        [[ -x "$candidate" ]] || continue; version=$($candidate env GOVERSION 2>/dev/null); minor=$(printf '%s\n' "$version" | sed -n 's/^go1\.\([0-9][0-9]*\).*/\1/p'); [[ -n "$minor" && "$minor" -ge 20 ]] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

# candidate — существующий файл root; сборщик пишет только в свой build_tmp.
_tg_build_relay() {
    local source="$1" go_binary="$2" candidate="$3" build_tmp rc=0
    build_tmp=$(mktemp -d /tmp/tproxy-build.XXXXXX) || return 1
    if ! chown tproxy:tproxy "$build_tmp" || ! chmod 0700 "$build_tmp"; then
        rm -rf "$build_tmp"
        return 1
    fi
    if ! chown -R root:tproxy "$source" ||
       ! chmod -R g+rX,g-w,o-rwx "$source"; then
        rc=1
    elif ! (cd "$source" &&
            runuser -u tproxy -- env HOME="$build_tmp" GOCACHE="$build_tmp/cache" \
                GOPATH="$build_tmp/gopath" TMPDIR="$build_tmp" \
                "$go_binary" build -buildvcs=false -trimpath -ldflags='-s -w' -o "$build_tmp/tproxy-server" ./cmd/tproxy-server); then
        rc=1
    # Чтение от tproxy: подложенная в build_tmp ссылка не раскроет файлы root.
    elif ! runuser -u tproxy -- cat -- "$build_tmp/tproxy-server" > "$candidate"; then
        rc=1
    fi
    chown -R root:root "$source" || rc=1
    chmod -R go-rwx "$source" || rc=1
    chmod 0700 "$source" || rc=1
    rm -rf "$build_tmp" || rc=1
    return "$rc"
}

_tg_install_relay_service() {
    local source="$TG_SOURCE/deploy/tproxy-server.service"
    local target="$TG_SYSTEMD/$TG_UNIT_RELAY" tmp
    [[ -f "$source" ]] || return 1
    mkdir -p "$TG_SYSTEMD" || return 1
    tmp="$target.tmp.$$"
    awk -v profile="$TG_PROFILES_FILE" '
        /^LoadCredential=/ { next }
        /^\[Service\]$/ {
            print
            print "LoadCredential=profiles.json:" profile
            inserted = 1
            next
        }
        { print }
        END { if (!inserted) exit 2 }
    ' "$source" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp" && mv -f "$tmp" "$target" || {
        rm -f "$tmp"
        return 1
    }
    chown root:root "$target" || return 1
    grep -q '^LoadCredential=profiles.json:' "$target"
}

# Установлена ли уже эта ревизия: маркер и всё, что ставит сборка, на месте
# (иначе — пересборка: ручное повреждение чинится применением).
_tg_revision_installed() {
    local unit file
    [[ -f "$TG_MARKER" && "$(cat "$TG_MARKER" 2>/dev/null)" == "$TG_REVISION" ]] || return 1
    [[ -x "$TG_BIN" && -x "$TG_MTPROXY_SOURCE/objs/bin/mtproto-proxy" && -x "$TG_REFRESH_BIN" ]] || return 1
    for unit in "$TG_UNIT_MTPROXY" "$TG_UNIT_RELAY" "$TG_UNIT_FIREWALL" "$TG_UNIT_REFRESH" "$TG_UNIT_TIMER"; do
        [[ -f "$TG_SYSTEMD/$unit" ]] || return 1
    done
    for file in proxy-secret proxy-multi.conf; do
        [[ -s "$TG_MTPROXY_DIR/$file" ]] || return 1
    done
    id mtproxy >/dev/null 2>&1 && id tproxy >/dev/null 2>&1
}

# _tg_ensure_user <имя>: отсутствующего создаёт и записывает в telegram-users;
# существующий принимается, только если это системная учётная запись без входа.
_tg_ensure_user() {
    local name="$1" entry uid shell max
    if entry=$(getent passwd "$name"); then
        uid=$(cut -d: -f3 <<<"$entry")
        shell=$(cut -d: -f7 <<<"$entry")
        max=$(awk '$1 == "SYS_UID_MAX" { print $2; exit }' "$R/etc/login.defs" 2>/dev/null)
        [[ "$max" =~ ^[0-9]+$ ]] || max=999
        if [[ "$uid" =~ ^[0-9]+$ ]] && ((uid <= max)) && [[ "$shell" == */nologin || "$shell" == */false ]]; then
            return 0
        fi
        warn "Учётная запись $name уже существует и не системная (UID $uid, оболочка $shell): Telegram Proxy её не использует."
        return 1
    fi
    useradd --system --home /nonexistent --shell /usr/sbin/nologin "$name" || return 1
    grep -qx -- "$name" "$NODE_DIR/telegram-users" 2>/dev/null || printf '%s\n' "$name" >> "$NODE_DIR/telegram-users"
}

# Клон, бэкенд, Go, сборка реле, юнит реле, маркер ревизии.
_tg_build() {
    local stage go_binary candidate
    stage=$(mktemp -d "${TMPDIR:-/tmp}/tproxy-relay.XXXXXX") || return 1
    progress_in 20
    progress_detail "Telegram Proxy: загрузка исходников tproxy-server"
    if ! chmod 0700 "$stage" || ! _tg_clone_upstream "$stage" "$TG_REVISION"; then
        warn "Не удалось получить исходники tproxy-server ревизии $TG_REVISION."
        rm -rf "$stage"
        return 1
    fi
    # До install-mtproxy.sh: тот создаёт mtproxy сам, и Essence не узнал бы, что пользователь его.
    progress_in 30
    progress_detail "Telegram Proxy: сборка MTProxy"
    if ! _tg_ensure_user mtproxy || ! _tg_install_backend "$stage"; then
        warn "Не удалось подготовить службу MTProxy."
        rm -rf "$stage"
        return 1
    fi
    rm -rf "$TG_SOURCE"
    mkdir -p "$(dirname "$TG_SOURCE")" || { rm -rf "$stage"; return 1; }
    mv "$stage" "$TG_SOURCE" || { rm -rf "$stage"; return 1; }
    chmod 0700 "$TG_SOURCE" || return 1
    progress_in 60
    progress_detail "Telegram Proxy: подготовка Go"
    go_binary=$(_tg_find_go 2>/dev/null || true)
    [[ -n "$go_binary" ]] || go_binary=$(_tg_install_pinned_go 2>/dev/null || true)
    [[ -n "$go_binary" ]] || { warn "Не удалось подготовить Go 1.20+."; return 1; }
    candidate=$(mktemp /tmp/tproxy-server.XXXXXX) || return 1
    progress_in 70
    progress_detail "Telegram Proxy: сборка tproxy-server (Go)"
    if ! _tg_build_relay "$TG_SOURCE" "$go_binary" "$candidate"; then
        rm -f "$candidate"
        warn "Не удалось собрать tproxy-server."
        return 1
    fi
    mkdir -p "$(dirname "$TG_BIN")" || { rm -f "$candidate"; return 1; }
    install -o root -g root -m 0755 "$candidate" "$TG_BIN" || { rm -f "$candidate"; return 1; }
    rm -f "$candidate"
    _tg_install_relay_service || return 1
    printf '%s\n' "$TG_REVISION" > "$TG_MARKER"
}

# ─── Хуки исполнителя ───────────────────────────────────────────────────────

telegram_prepare() {
    local key
    for key in TG_HOST TG_REPO TG_REVISION TG_GO_VERSION TG_GO_SHA256; do
        [[ -n "${!key:-}" ]] || { warn "Не задан $key."; return 1; }
    done
    case "$(uname -m)" in x86_64|amd64) ;; *) warn "Официальная сборка MTProxy поддерживает только x86_64."; return 1 ;; esac
    # С этого момента на ноде могут появиться компоненты роли: метка не даёт
    # им остаться, если роль так и не будет зафиксирована (см. stage_cleanup).
    mkdir -p "$NODE_DIR/features" && : > "$NODE_DIR/features/telegram" || return 1
    agent_apt_wait || return 1
    progress_detail "Telegram Proxy: установка зависимостей"
    agent_apt 0 20 install -y -q git curl openssl wget unzip nginx nftables make gcc tar || return 1
    _tg_ensure_user tproxy || return 1
    if _tg_revision_installed; then
        info "tproxy-server ревизии $TG_REVISION уже установлен — сборка пропущена."
    else
        _tg_build || return 1
    fi
    # mtproto-proxy запускается от mtproxy (User= юнита); сборка, сделанная
    # прежним исполнителем под umask 077, остаётся недоступной — чинится здесь же.
    chmod -R go+rX "$TG_MTPROXY_SOURCE/objs" || return 1
    install -d -o root -g tproxy -m 0750 "$TG_DIR" || return 1
    _tg_ensure_token_key || { warn "Не удалось подготовить ключ токенов tproxy-server."; return 1; }
    if [[ ! -f "$TG_SITE/index.html" ]]; then
        progress_in 95
        progress_detail "Telegram Proxy: сайт-заглушка Web Proxy"
        site_fetch random "$TG_SITE" || { warn "Не удалось подготовить сайт-заглушку Web Proxy."; return 1; }
        [[ -f "$TG_SITE/index.html" ]] || { warn "index.html сайта Web Proxy недоступен."; return 1; }
        chmod -R u=rwX,go=rX "$TG_SITE" || return 1
        chown -R root:root "$TG_SITE" || return 1
    fi
    (umask 022; mkdir -p "$R/var/www/$TG_HOST")
}

_tg_wait_backend() {
    local n=0
    while (( n < TG_READY_ATTEMPTS )); do
        (exec 3<>/dev/tcp/127.0.0.1/2398) 2>/dev/null && return 0
        n=$((n + 1)); sleep 1
    done
    warn "Служба MTProxy недоступна на 127.0.0.1:2398."
    return 1
}

_tg_wait_ready() {
    local n=0
    while (( n < TG_READY_ATTEMPTS )); do
        curl --fail --silent --output /dev/null --max-time 2 http://127.0.0.1:8081/readyz 2>/dev/null && return 0
        n=$((n + 1)); sleep 1
    done
    warn "tproxy-server не готов (/readyz)."
    return 1
}

telegram_activate() {
    TG_ACTIVATED=true
    systemctl daemon-reload || return 1
    systemctl enable --now "$TG_UNIT_FIREWALL" "$TG_UNIT_MTPROXY" "$TG_UNIT_TIMER" "$TG_UNIT_RELAY" || return 1
    systemctl restart "$TG_UNIT_MTPROXY" "$TG_UNIT_RELAY" || return 1
    systemctl reload-or-restart "$TG_UNIT_FIREWALL" || return 1
    _tg_wait_backend || return 1
    _tg_wait_ready
}

# Юниты роли, файлы которых на месте, выключаются и останавливаются:
# `systemctl disable --now` отказывает целиком, если хоть одного юнита нет
# (неполная установка — бэкенд поставлен, реле ещё нет).
_tg_disable_units() {
    local unit units=""
    for unit in "$TG_UNIT_TIMER" "$TG_UNIT_RELAY" "$TG_UNIT_MTPROXY" "$TG_UNIT_FIREWALL"; do
        [[ -f "$TG_SYSTEMD/$unit" ]] && units="$units $unit"
    done
    [[ -n "$units" ]] || return 0
    # shellcheck disable=SC2086 # имена юнитов без пробелов
    systemctl disable --now $units
}

# Файлы роли, которые ставит транзакция `config`.
TG_ROLE_FILES=(/etc/mtproxy/mtproxy.env /etc/tproxy-server/firewall.nft /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json)

# Откат трогает службы, только если транзакция трогала роль (RC кладёт в
# files.list все отрисованные файлы при каждом применении, поэтому важно
# изменение, а не присутствие в TX_PATHS):
# - telegram_deactivate в этой операции — службы снова включаются, только если
#   после возврата файлов роль была (mtproxy.env на месте); снимались остатки
#   незафиксированной роли (adopt_feature_leftovers) — остаются выключенными;
# - первая установка (mtproxy.env до транзакции не было, .absent) — службы
#   останавливаются и выключаются;
# - telegram_activate начинал перезапуск (даже с теми же файлами роли: его
#   могла вызвать правка mihomo) — службы поднимаются заново с прежними
#   файлами и проверяется их готовность;
# - файл роли в транзакции и изменён ею (cmp с копией) — перезапуск с прежними;
# - иначе (откат по чужой причине до активации, файлы роли те же) — ничего.
telegram_rollback() {
    local path touched=false changed=false
    # Явный код: в обработчике trap (finish) голый `return` вернул бы код
    # команды до trap, сбой хука даёт rollback_failed.
    if [[ " $TX_DEACTIVATED " == *" telegram "* ]]; then
        if [[ ! -f "$R/etc/mtproxy/mtproxy.env" ]]; then
            _tg_disable_units; return $?
        fi
        systemctl daemon-reload &&
            systemctl enable --now "$TG_UNIT_FIREWALL" "$TG_UNIT_MTPROXY" "$TG_UNIT_TIMER" "$TG_UNIT_RELAY" &&
            systemctl restart "$TG_UNIT_MTPROXY" "$TG_UNIT_RELAY"
        return $?
    fi
    for path in "${TG_ROLE_FILES[@]}"; do
        [[ " ${TX_PATHS[*]} " == *" $path "* ]] || continue
        touched=true
        if [[ -e "$OP/backup$path.absent" ]] || ! cmp -s -- "$OP/backup$path" "$OP/files$path"; then
            changed=true
        fi
    done
    [[ "$touched" == true || "$TG_ACTIVATED" == true ]] || return 0
    if [[ -e "$OP/backup/etc/mtproxy/mtproxy.env.absent" ]]; then
        _tg_disable_units; return $?
    fi
    if [[ "$TG_ACTIVATED" == true ]]; then
        telegram_activate; return $?
    fi
    [[ "$changed" == true ]] || return 0
    systemctl daemon-reload &&
        systemctl restart "$TG_UNIT_MTPROXY" "$TG_UNIT_RELAY" &&
        systemctl reload-or-restart "$TG_UNIT_FIREWALL"
}

# Снятие роли до того, как транзакция `config` удалит её файлы: службы
# останавливаются и выключаются (юниты ещё на месте; только существующие),
# таблица nft снимается.
telegram_deactivate() {
    [[ -f "$TG_SYSTEMD/$TG_UNIT_MTPROXY" || -f "$TG_SYSTEMD/$TG_UNIT_RELAY" ]] || return 0
    _tg_disable_units || return 1
    if nft list table inet "$TG_NFT_TABLE" >/dev/null 2>&1; then
        nft delete table inet "$TG_NFT_TABLE" || return 1
    fi
}

# Удаление после фиксации: только файлы, каталоги и созданные Essence учётные записи.
telegram_remove() {
    local rc=0 user go
    rm -f -- "$TG_SYSTEMD/$TG_UNIT_RELAY" "$TG_SYSTEMD/$TG_UNIT_MTPROXY" "$TG_SYSTEMD/$TG_UNIT_FIREWALL" \
        "$TG_SYSTEMD/$TG_UNIT_REFRESH" "$TG_SYSTEMD/$TG_UNIT_TIMER" "$TG_REFRESH_BIN" "$TG_BIN" || rc=1
    rm -rf -- "$TG_MTPROXY_SOURCE" "$TG_MTPROXY_SOURCE".before-tproxy.* "$TG_SOURCE" "$TG_MTPROXY_DIR" "$TG_DIR" "$TG_SITE" || rc=1
    if [[ -f "$NODE_DIR/telegram-go" ]]; then
        go=$(cat "$NODE_DIR/telegram-go")
        if [[ "$go" =~ ^/opt/go[0-9][0-9.]*$ ]]; then rm -rf -- "$R$go" || rc=1; fi
    fi
    systemctl daemon-reload >/dev/null 2>&1 || rc=1
    # Только пользователи, созданные Essence; чужие учётные записи не трогаются.
    if [[ -f "$NODE_DIR/telegram-users" ]]; then
        while IFS= read -r user; do
            [[ "$user" == tproxy || "$user" == mtproxy ]] || continue
            if id "$user" >/dev/null 2>&1; then userdel "$user" >/dev/null 2>&1 || rc=1; fi
        done <"$NODE_DIR/telegram-users"
    fi
    ((rc == 0)) || return "$rc"
    rm -f -- "$NODE_DIR/telegram-users" "$NODE_DIR/telegram-go" "$NODE_DIR/features/telegram"
}
