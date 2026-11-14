#!/bin/bash
# ─── Фича sub: хост подписок (этап 4 плана) ─────────────────────────────────
# Хуки исполнителя для ноды-хоста подписок. vhost, limit_req_zone, сценарий
# очистки и systemd-юниты рендерит RC; здесь — каталоги данных, таймер и
# снятие роли. Права каталогов — как в `setup_subscription`
# (`setup-essence/modules/subscription.sh`). Spec: SUB_HOST.

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

sub_activate() {
    systemctl enable --now essence-sub-cleanup.timer
}

# Файлы роли возвращает транзакция; таймер к ним не привязан.
sub_rollback() {
    return 0
}

sub_remove() {
    systemctl disable --now essence-sub-cleanup.timer >/dev/null 2>&1 || true
    rm -rf -- "$SUB_DIR_PATH" "$SUB_SNIPPETS"
}
