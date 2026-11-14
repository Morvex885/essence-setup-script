#!/bin/bash
# ─── Фича sub: хост подписок (этап 4 плана) ─────────────────────────────────
# Хуки исполнителя для ноды-хоста подписок. vhost, limit_req_zone, сценарий
# очистки и systemd-юниты рендерит RC; здесь — каталоги данных, таймер и
# снятие роли. Права каталогов — как в v1 `setup_subscription`. Spec: SUB_HOST.

SUB_DIR_PATH="$R/var/lib/essence-sub"
SUB_SNIPPETS="$R/etc/nginx/snippets/essence-sub"
SUB_NGINX_GROUP="www-data"

sub_prepare() {
    [[ -n "${SUB_HOST:-}" ]] || { warn "Не задан SUB_HOST."; return 1; }
    (umask 022; mkdir -p "$R/var/www/$SUB_HOST") || return 1
    mkdir -p "$SUB_DIR_PATH" || return 1
    chown "root:${SUB_NGINX_GROUP}" "$SUB_DIR_PATH" || return 1
    chmod 2750 "$SUB_DIR_PATH" || return 1
    if command -v setfacl &>/dev/null; then
        setfacl -m    "g:${SUB_NGINX_GROUP}:rx" "$SUB_DIR_PATH" 2>/dev/null || true
        setfacl -d -m "g:${SUB_NGINX_GROUP}:r"  "$SUB_DIR_PATH" 2>/dev/null || true
    fi
    # Per-token nginx snippets (читает nginx master = root, поэтому 755 root:root).
    mkdir -p "$SUB_SNIPPETS" || return 1
    chown root:root "$SUB_SNIPPETS" || return 1
    chmod 755 "$SUB_SNIPPETS"
}

SUB_TIMER_UNIT="$R/etc/systemd/system/essence-sub-cleanup.timer"

sub_activate() {
    systemctl enable --now essence-sub-cleanup.timer
}

# Откат: юнит таймера восстановлен (роль была) — таймер включается снова,
# в том числе после sub_deactivate; первой установки — файла уже нет: запущенный
# таймер останавливается (stop незапущенного без файла юнита отказывает) и
# ссылка в timers.target.wants убирается вручную (systemctl disable без файла
# юнита отказывает). Код — первая ошибка stop или rm.
sub_rollback() {
    if [[ -f "$SUB_TIMER_UNIT" ]]; then
        systemctl enable --now essence-sub-cleanup.timer
    else
        local rc=0
        if systemctl is-active --quiet essence-sub-cleanup.timer; then
            systemctl stop essence-sub-cleanup.timer || rc=$?
        fi
        if ! rm -f -- "$R/etc/systemd/system/timers.target.wants/essence-sub-cleanup.timer"; then
            ((rc)) || rc=1
        fi
        return "$rc"
    fi
}

# Снятие роли, до удаления юнитов этапом config.
sub_deactivate() {
    [[ -f "$SUB_TIMER_UNIT" ]] || return 0
    systemctl disable --now essence-sub-cleanup.timer
}

sub_remove() {
    rm -rf -- "$SUB_DIR_PATH" "$SUB_SNIPPETS"
}
