#!/bin/bash
# ─── Управление client-users в listener'ах mihomo ─────────────────────────

# Заменяет блок между # client-users-start и # client-users-end
# внутри указанного listener-блока в /etc/mihomo/config.yaml
#
# Args:
#   $1 — marker (vless-tcp, vless-xhttp, vless-grpc, hy2)
#   $2 — новый YAML-блок users (без маркеров, уже с нужным indent)
#        пустая строка = удалить всех client-users
#
# Cascade-user блоки (# cascade-user:...) НЕ затрагиваются.
_sync_listener_users() {
    local marker="$1"
    local users_yaml="$2"
    local config="/etc/mihomo/config.yaml"

    [[ ! -f "$config" ]] && return 1

    # Проверяем что listener-блок существует
    if ! grep -q "^# --- ${marker} ---$" "$config"; then
        return 1
    fi

    # Exactly one users start marker followed by exactly one end marker inside
    # the listener block: a second, unclosed start would swallow the closing
    # listener marker and the rest of the config.
    if ! awk -v marker="$marker" '
        $0 == "# --- " marker " ---" { inside=1; next }
        $0 == "# --- /" marker " ---" { closed=1; exit }
        inside && /# client-users-start/ { starts++; next }
        inside && /# client-users-end/ { if (!starts) bad=1; ends++ }
        END { if (!(inside && closed && !bad && starts == 1 && ends == 1)) exit 1 }
    ' "$config"; then
        return 1
    fi

    local _tmpfile
    _tmpfile=$(mktemp)

    awk -v new_users="$users_yaml" '
        /^# --- '"$marker"' ---$/ { in_block=1 }
        /^# --- \/'"$marker"' ---$/ { in_block=0 }
        in_block && /# client-users-start/ {
            print "      # client-users-start"
            if (new_users != "") {
                n = split(new_users, lines, "\n")
                for (i = 1; i <= n; i++) print lines[i]
            }
            print "      # client-users-end"
            skipping = 1
            next
        }
        in_block && skipping && /# client-users-end/ { skipping = 0; next }
        skipping { next }
        { print }
    ' "$config" > "$_tmpfile"

    mv "$_tmpfile" "$config"
}

# Формирует YAML-блок users для VLESS listener'ов
# Stdin: строки формата "username uuid" (разделитель — пробел)
# Arg $1: маркер (vless-tcp → добавить flow: xtls-rprx-vision)
# Stdout: готовый YAML-блок с правильным indent
_build_vless_users_yaml() {
    local marker="$1"
    local add_flow=false
    [[ "$marker" == "vless-tcp" ]] && add_flow=true

    while IFS=' ' read -r username uuid || [[ -n "$username" ]]; do
        uuid="${uuid%$'\r'}"
        [[ -z "$username" || -z "$uuid" ]] && continue
        echo "      - username: $username"
        echo "        uuid: $uuid"
        $add_flow && echo "        flow: xtls-rprx-vision"
    done
    return 0
}

# Формирует YAML-блок users для Hysteria2 listener'а
# Stdin: строки формата "username password" (разделитель — пробел)
# Stdout: готовый YAML-блок с правильным indent
_build_hy2_users_yaml() {
    while IFS=' ' read -r username password || [[ -n "$username" ]]; do
        password="${password%$'\r'}"
        [[ -z "$username" || -z "$password" ]] && continue
        echo "      $username: $password"
    done
    return 0
}
