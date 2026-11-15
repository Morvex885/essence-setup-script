#!/usr/bin/env bats
# Фича telegram исполнителя: telegram_prepare (пропуск сборки только при
# полной установке ревизии, пользователи), telegram_rollback, telegram_remove
# и юниты upstream из закреплённой ревизии (tests/fixtures/tproxy-server).
# Заглушки команд через PATH, корень — $ROOT.

setup() {
    load '../helpers/test_helper'
    setup_test_env
    require_executor_env
    ROOT="$BATS_TEST_TMPDIR/node"
    STUBS="$BATS_TEST_TMPDIR/stubs"
    CALLS="$BATS_TEST_TMPDIR/calls"
    AGENT="$PROJECT_ROOT/node-agent"
    NODE_DIR="$ROOT/root/essence-node"
    export CALLS
    mkdir -p "$STUBS" "$ROOT" "$NODE_DIR"
    : >"$CALLS"
    local cmd
    for cmd in apt-get git systemctl chown useradd userdel nft wget curl runuser; do stub "$cmd" 'exit 0'; done
    stub fuser 'exit 1'
    stub uname '[[ "$1" == -m ]] && echo x86_64; exit 0'
    stub id 'exit "${ID_RC:-0}"'
    # getent passwd <имя>: системная учётная запись, если не задано иное.
    stub getent '[[ -n "${GETENT_ABSENT:-}" ]] && exit 2
echo "$2:x:${USER_UID:-990}:990::/nonexistent:${USER_SHELL:-/usr/sbin/nologin}"'
    stub install 'for a; do last="$a"; done; [[ " $* " == *" -d "* ]] && mkdir -p "$last"; exit 0'
    export PATH="$STUBS:$PATH"
    REV=f7a6acc4d536a787d442fd7df3ba4ebfd728f406
}

teardown() { teardown_test_env; }

stub() {
    printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >>"$CALLS"\n%s\n' "$1" "$2" >"$STUBS/$1"
    chmod +x "$STUBS/$1"
}

# refute_call <регулярное выражение> — такого вызова нет. `! grep` посреди
# теста bats не проверяет (set -e не срабатывает на отрицании).
refute_call() {
    if grep -q -- "$1" "$CALLS"; then
        echo "неожиданный вызов: $(grep -- "$1" "$CALLS")"
        return 1
    fi
}

# tg_call <код>: common.sh и шаги исполнителя с $R=$ROOT и spec роли.
tg_call() {
    run bash -c 'R="$1"; OP="$2"; NODE_DIR="$6"; TG_HOST=tg.example.com; TG_REPO=https://example.com/tproxy-server.git
        TG_REVISION="$3"; TG_GO_VERSION=1.26.5; TG_GO_SHA256=x; TX_PATHS=()
        source "$4/../common/common.sh"; for f in "$4"/steps/*.sh; do source "$f"; done; eval "$5"' \
        _ "$ROOT" "$BATS_TEST_TMPDIR" "$REV" "$AGENT" "$1" "$NODE_DIR"
}

# Всё, что ставит сборка ревизии $1.
installed_revision() {
    local unit
    mkdir -p "$ROOT/opt/tproxy-server-source" "$ROOT/opt/MTProxy/objs/bin" "$ROOT/usr/local/bin" "$ROOT/usr/local/sbin" \
        "$ROOT/etc/systemd/system" "$ROOT/etc/mtproxy" "$ROOT/srv/tproxy-site"
    printf '%s\n' "$1" >"$ROOT/opt/tproxy-server-source/.essence-revision"
    for bin in usr/local/bin/tproxy-server opt/MTProxy/objs/bin/mtproto-proxy usr/local/sbin/refresh-mtproxy-config; do
        printf '#!/bin/bash\n' >"$ROOT/$bin"; chmod +x "$ROOT/$bin"
    done
    for unit in mtproxy.service tproxy-server.service tproxy-firewall.service refresh-mtproxy-config.service refresh-mtproxy-config.timer; do
        : >"$ROOT/etc/systemd/system/$unit"
    done
    echo secret >"$ROOT/etc/mtproxy/proxy-secret"
    echo conf >"$ROOT/etc/mtproxy/proxy-multi.conf"
    echo site >"$ROOT/srv/tproxy-site/index.html"
}

@test "telegram_prepare: та же ревизия установлена полностью — сборка пропущена, метка фичи стоит" {
    installed_revision "$REV"
    tg_call telegram_prepare
    assert_success
    refute_call "^git "
    grep -q "^apt-get install" "$CALLS"
    [[ "$(wc -c <"$ROOT/etc/tproxy-server/token.key")" -eq 32 ]]
    [[ -d "$ROOT/var/www/tg.example.com" && -f "$NODE_DIR/features/telegram" ]]
}

@test "telegram_prepare: повреждённая установка той же ревизии пересобирается" {
    for broken in etc/mtproxy/proxy-secret opt/MTProxy/objs/bin/mtproto-proxy etc/systemd/system/refresh-mtproxy-config.timer \
        usr/local/sbin/refresh-mtproxy-config; do
        installed_revision "$REV"
        rm -f "$ROOT/$broken"
        : >"$CALLS"
        tg_call telegram_prepare
        grep -q "^git clone --filter=blob:none --no-checkout https://example.com/tproxy-server.git" "$CALLS" || { echo "$broken"; return 1; }
    done
    # Нет пользователя mtproxy — тоже пересборка.
    installed_revision "$REV"
    : >"$CALLS"
    ID_RC=1 tg_call telegram_prepare
    grep -q "^git clone" "$CALLS"
}

@test "telegram_prepare: другая ревизия — клон из TG_REPO" {
    installed_revision "0000000000000000000000000000000000000000"
    tg_call telegram_prepare
    assert_failure
    grep -q "^git clone --filter=blob:none --no-checkout https://example.com/tproxy-server.git" "$CALLS"
}

@test "пользователи: отсутствующий создаётся и записывается, чужой несистемный отклоняется" {
    installed_revision "$REV"
    GETENT_ABSENT=1 tg_call telegram_prepare
    assert_success
    grep -qx "useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy" "$CALLS"
    [[ "$(cat "$NODE_DIR/telegram-users")" == tproxy ]]
    : >"$CALLS"
    rm -f "$NODE_DIR/telegram-users"
    USER_UID=1001 USER_SHELL=/bin/bash tg_call telegram_prepare
    assert_failure
    refute_call "^useradd"
    [[ ! -e "$NODE_DIR/telegram-users" ]]
    # Существующая системная учётная запись принимается и не записывается.
    tg_call telegram_prepare
    assert_success
    [[ ! -e "$NODE_DIR/telegram-users" ]]
}

@test "telegram_remove: только удаление — файлы, остатки сборки и свои пользователи, без остановки служб" {
    installed_revision "$REV"
    mkdir -p "$ROOT/etc/tproxy-server" "$ROOT/opt/go1.26.5/bin" "$ROOT/opt/MTProxy.before-tproxy.20260101000000" "$NODE_DIR/features"
    : >"$ROOT/etc/mtproxy/mtproxy.env"
    : >"$NODE_DIR/features/telegram"
    echo /opt/go1.26.5 >"$NODE_DIR/telegram-go"
    echo mtproxy >"$NODE_DIR/telegram-users"
    tg_call telegram_remove
    assert_success
    for path in opt/MTProxy opt/MTProxy.before-tproxy.20260101000000 opt/go1.26.5 opt/tproxy-server-source usr/local/bin/tproxy-server \
        etc/mtproxy etc/tproxy-server srv/tproxy-site etc/systemd/system/mtproxy.service etc/systemd/system/tproxy-server.service \
        usr/local/sbin/refresh-mtproxy-config root/essence-node/features/telegram root/essence-node/telegram-users root/essence-node/telegram-go; do
        [[ ! -e "$ROOT/$path" ]] || { echo "осталось: $path"; return 1; }
    done
    grep -qx "userdel mtproxy" "$CALLS"
    refute_call "^userdel tproxy$"
    refute_call "^systemctl disable\|^nft "
}

@test "telegram_deactivate: службы выключаются и таблица nft снимается, пока юниты на месте" {
    installed_revision "$REV"
    tg_call telegram_deactivate
    assert_success
    grep -qx "systemctl disable --now refresh-mtproxy-config.timer tproxy-server.service mtproxy.service tproxy-firewall.service" "$CALLS"
    grep -qx "nft delete table inet tproxy_backend" "$CALLS"
    # Без юнитов (компоненты не ставились) — ничего.
    rm -f "$ROOT/etc/systemd/system/"*.service
    : >"$CALLS"
    tg_call telegram_deactivate
    assert_success
    [[ ! -s "$CALLS" ]]
    # Неполная установка (бэкенд поставлен, реле — нет): выключаются только существующие юниты.
    installed_revision "$REV"
    rm -f "$ROOT/etc/systemd/system/tproxy-server.service"
    : >"$CALLS"
    tg_call telegram_deactivate
    assert_success
    grep -qx "systemctl disable --now refresh-mtproxy-config.timer mtproxy.service tproxy-firewall.service" "$CALLS"
    grep -qx "nft delete table inet tproxy_backend" "$CALLS"
}

@test "telegram_remove: без записей Essence пользователи и чужой Go не трогаются" {
    installed_revision "$REV"
    mkdir -p "$ROOT/opt/go1.26.5"
    tg_call telegram_remove
    assert_success
    refute_call "^userdel"
    [[ -d "$ROOT/opt/go1.26.5" ]]
}

# rollback_with <пути транзакции> <first|changed|same> [deactivated]: откат с
# TX_PATHS. Копия config.json (и mtproxy.env, кроме first) — old; файл операции —
# new (changed) или такой же (same). first — mtproxy.env до транзакции не было.
# ROLLBACK_PRE — код перед откатом (например, начатая активация).
rollback_with() {
    local backup="$BATS_TEST_TMPDIR/backup" files="$BATS_TEST_TMPDIR/files" path
    rm -rf "$backup" "$files"
    for path in /etc/mtproxy/mtproxy.env /etc/tproxy-server/config.json; do
        mkdir -p "$backup$(dirname "$path")" "$files$(dirname "$path")"
        echo old >"$backup$path"
        if [[ "$2" == same ]]; then echo old >"$files$path"; else echo new >"$files$path"; fi
    done
    if [[ "$2" == first ]]; then rm "$backup/etc/mtproxy/mtproxy.env"; : >"$backup/etc/mtproxy/mtproxy.env.absent"; fi
    : >"$CALLS"
    tg_call "TX_PATHS=($1); TX_DEACTIVATED='${3:-}'; ${ROLLBACK_PRE:-} telegram_rollback"
}

@test "telegram_rollback: первая установка выключает службы, изменённые файлы — перезапуск, чужой откат не трогает" {
    installed_revision "$REV"
    rollback_with "/etc/mihomo/config.yaml /etc/mtproxy/mtproxy.env" first
    assert_success
    grep -qx "systemctl disable --now refresh-mtproxy-config.timer tproxy-server.service mtproxy.service tproxy-firewall.service" "$CALLS"
    refute_call "restart"
    rollback_with "/etc/tproxy-server/config.json" changed
    grep -qx "systemctl restart mtproxy.service tproxy-server.service" "$CALLS"
    refute_call "disable\|enable"
    rollback_with "/etc/mihomo/config.yaml /etc/amnezia/amneziawg/awg0.conf" changed
    assert_success
    [[ ! -s "$CALLS" ]]
}

@test "telegram_rollback: файлы роли в транзакции, но не изменены — службы не трогаются" {
    rollback_with "/etc/mihomo/config.yaml /etc/mtproxy/mtproxy.env /etc/tproxy-server/config.json" same
    assert_success
    [[ ! -s "$CALLS" ]]
}

@test "telegram_rollback: начатая активация с теми же файлами роли — службы поднимаются заново и проверяется готовность" {
    # Правка только mihomo: файлы роли те же, но telegram_activate уже перезапускал службы.
    ROLLBACK_PRE='TG_ACTIVATED=true; _tg_wait_backend() { echo backend-ready >>"$CALLS"; };'
    rollback_with "/etc/mihomo/config.yaml /etc/mtproxy/mtproxy.env /etc/tproxy-server/config.json" same
    assert_success
    grep -qx "systemctl enable --now tproxy-firewall.service mtproxy.service refresh-mtproxy-config.timer tproxy-server.service" "$CALLS"
    grep -qx "systemctl restart mtproxy.service tproxy-server.service" "$CALLS"
    grep -qx "backend-ready" "$CALLS"
    grep -q "^curl .*127.0.0.1:8081/readyz" "$CALLS"
    # Готовность не достигнута — откат не завершён (rollback_failed), а не rolled_back.
    stub curl 'exit 7'
    ROLLBACK_PRE='TG_ACTIVATED=true; TG_READY_ATTEMPTS=1; _tg_wait_backend() { :; }; sleep() { :; };'
    rollback_with "/etc/mihomo/config.yaml" same
    assert_failure
    # Сбой до активации с теми же файлами — службы не трогаются.
    ROLLBACK_PRE='TG_ACTIVATED=false;'
    rollback_with "/etc/mihomo/config.yaml /etc/mtproxy/mtproxy.env" same
    assert_success
    [[ ! -s "$CALLS" ]]
}

@test "telegram_rollback: код — код его команд, а не упавшей до отката команды" {
    mkdir -p "$ROOT/etc/mtproxy" && echo old >"$ROOT/etc/mtproxy/mtproxy.env"
    # В trap finish откату предшествует упавшая команда (mihomo -t): её код не возвращается.
    tg_call 'false; TX_PATHS=(); TX_DEACTIVATED=telegram; telegram_rollback; echo "rc=$?"'
    assert_line "rc=0"
    stub systemctl '[[ "$1" == restart ]] && exit 5; exit 0'
    tg_call 'TX_PATHS=(); TX_DEACTIVATED=telegram; telegram_rollback; echo "rc=$?"'
    assert_line "rc=5"
}

@test "telegram_rollback: снятие роли в этой операции откатывается — службы снова включаются" {
    mkdir -p "$ROOT/etc/mtproxy" && echo old >"$ROOT/etc/mtproxy/mtproxy.env"
    rollback_with "/etc/mtproxy/mtproxy.env" same telegram
    assert_success
    grep -qx "systemctl enable --now tproxy-firewall.service mtproxy.service refresh-mtproxy-config.timer tproxy-server.service" "$CALLS"
    grep -qx "systemctl restart mtproxy.service tproxy-server.service" "$CALLS"
}

@test "telegram_rollback: откат снятия незафиксированных остатков — службы остаются выключенными" {
    # adopt_feature_leftovers: роль не была зафиксирована, файлов роли нет и после возврата.
    installed_revision "$REV"
    rm -f "$ROOT/etc/mtproxy/mtproxy.env"
    rollback_with "/etc/mihomo/config.yaml" same telegram
    assert_success
    grep -qx "systemctl disable --now refresh-mtproxy-config.timer tproxy-server.service mtproxy.service tproxy-firewall.service" "$CALLS"
    refute_call "enable --now\|restart"
    # Остатки неполной установки (реле не собрано): только существующие юниты.
    rm -f "$ROOT/etc/systemd/system/tproxy-server.service"
    rollback_with "/etc/mihomo/config.yaml" same telegram
    assert_success
    grep -qx "systemctl disable --now refresh-mtproxy-config.timer mtproxy.service tproxy-firewall.service" "$CALLS"
}

@test "юниты upstream закреплённой ревизии проходят проверки и рендер" {
    local fixtures="$PROJECT_ROOT/tests/fixtures/tproxy-server"
    mkdir -p "$ROOT/opt/tproxy-server-source/deploy"
    cp "$fixtures/tproxy-server.service" "$ROOT/opt/tproxy-server-source/deploy/"
    tg_call "_tg_validate_upstream_firewall_unit '$fixtures/tproxy-firewall.service' &&
        _tg_render_mtproxy_unit '$fixtures/mtproxy.service' '$BATS_TEST_TMPDIR/mtproxy.service' &&
        _tg_install_relay_service"
    assert_success
    [[ "$(grep -c '^EnvironmentFile=' "$BATS_TEST_TMPDIR/mtproxy.service")" == 1 ]]
    grep -qx 'EnvironmentFile=/etc/mtproxy/mtproxy.env' "$BATS_TEST_TMPDIR/mtproxy.service"
    grep -qF -- '-S ${MTPROXY_SECRET} $MTPROXY_TAG_ARGS --aes-pwd' "$BATS_TEST_TMPDIR/mtproxy.service"
    grep -qx 'LoadCredential=profiles.json:/etc/tproxy-server/profiles.json' "$ROOT/etc/systemd/system/tproxy-server.service"
}
