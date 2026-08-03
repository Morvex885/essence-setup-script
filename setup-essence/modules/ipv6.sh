#!/bin/bash

render_mihomo_ipv6_candidate() {
    local state="$1" source_config="$2" top_level_count

    [[ "$state" == "true" || "$state" == "false" ]] || return 1
    [[ -f "$source_config" ]] || return 1
    top_level_count=$(grep -c '^ipv6:[[:space:]]*' "$source_config" || true)
    [[ "$top_level_count" -eq 1 ]] || return 1

    awk -v state="$state" '
        /^ipv6:[[:space:]]*/ && !updated {
            print "ipv6: " state
            updated=1
            next
        }
        { print }
        END { if (!updated) exit 1 }
    ' "$source_config"
}

_apply_mihomo_ipv6_setting() {
    local state="$1"
    local config_file="${MIHOMO_CONFIG_FILE:-/etc/mihomo/config.yaml}"
    local config_dir candidate old_umask mihomo_bin

    if [[ ! -f "$config_file" ]]; then
        warn "Mihomo не установлен: $config_file не найден."
        return 1
    fi

    config_dir=$(dirname "$config_file")
    old_umask=$(umask)
    umask 077
    candidate=$(mktemp "$config_dir/.config.yaml.XXXXXX") || {
        umask "$old_umask"
        return 1
    }
    umask "$old_umask"

    if ! render_mihomo_ipv6_candidate "$state" "$config_file" > "$candidate"; then
        rm -f -- "$candidate"
        warn "Не удалось обновить верхнеуровневый параметр ipv6 в config.yaml."
        return 1
    fi

    mihomo_bin="${MIHOMO_BIN:-/usr/local/bin/mihomo}"
    if [[ ! -x "$mihomo_bin" ]]; then
        mihomo_bin=$(command -v mihomo 2>/dev/null || true)
    fi
    if [[ -z "$mihomo_bin" ]] || ! "$mihomo_bin" -t -f "$candidate"; then
        rm -f -- "$candidate"
        warn "Проверка нового config.yaml через mihomo завершилась ошибкой; IPv6 не переключён."
        return 1
    fi

    mv -f -- "$candidate" "$config_file"
}
# ─── Переключение IPv6 ───────────────────────────────────────────────────────

toggle_ipv6() {
    local mihomo_ipv6_changed=0
    local mihomo_ipv6_state=""
    echo ""
    SYSCTL_FILE="/etc/sysctl.d/99-vpn-speedup.conf"

    CURRENT_STATE=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "0")
    if [[ "$CURRENT_STATE" == "1" ]]; then
        info "Текущее состояние IPv6: ${RED}ОТКЛЮЧЁН${NC}"
    else
        info "Текущее состояние IPv6: ${GREEN}ВКЛЮЧЁН${NC}"
    fi

    echo ""
    echo -e "  ${GREEN}1)${NC} Включить IPv6"
    echo -e "  ${RED}2)${NC} Выключить IPv6"
    echo -e "  ${NC}0)${NC} Отмена"
    echo ""
    read -rp "Выберите действие [0-2]: " IPV6_CHOICE

    case "$IPV6_CHOICE" in
        1)
            if ! _apply_mihomo_ipv6_setting true; then
                warn "Системные настройки IPv6 оставлены без изменений."
                return 1
            fi
            if [[ -f "$SYSCTL_FILE" ]]; then
                sed -i '/# IPv6 отключён/d' "$SYSCTL_FILE"
                sed -i '/net.ipv6.conf.*disable_ipv6/d' "$SYSCTL_FILE"
                grep -q 'net.ipv6.conf.all.forwarding' "$SYSCTL_FILE" || \
                    echo "net.ipv6.conf.all.forwarding = 1" >> "$SYSCTL_FILE"
            fi
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 > /dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 > /dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.lo.disable_ipv6=0 > /dev/null 2>&1 || true
            sysctl --system > /dev/null 2>&1
            mihomo_ipv6_changed=1
            mihomo_ipv6_state="true"
            success "IPv6 включён"
            ;;
        2)
            if ! _apply_mihomo_ipv6_setting false; then
                warn "Системные настройки IPv6 оставлены без изменений."
                return 1
            fi
            if [[ -f "$SYSCTL_FILE" ]]; then
                sed -i '/net.ipv6.conf.all.forwarding/d' "$SYSCTL_FILE"
                sed -i '/# IPv6 отключён/d' "$SYSCTL_FILE"
                sed -i '/net.ipv6.conf.*disable_ipv6/d' "$SYSCTL_FILE"
                cat >> "$SYSCTL_FILE" << EOF

# IPv6 отключён по запросу пользователя
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
            else
                warn "Файл $SYSCTL_FILE не найден. Создаю минимальный..."
                cat > "$SYSCTL_FILE" << EOF
# IPv6 отключён по запросу пользователя
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
            fi
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.lo.disable_ipv6=1 > /dev/null 2>&1 || true
            sysctl --system > /dev/null 2>&1
            mihomo_ipv6_changed=1
            mihomo_ipv6_state="false"
            success "IPv6 отключён"
            ;;
        0)
            info "Отменено."
            ;;
        *)
            warn "Неверный выбор."
            ;;
    esac

    if (( mihomo_ipv6_changed )); then
        info "Перезапускаю Mihomo..."
        systemctl restart mihomo &>/dev/null
        if systemctl is-active --quiet mihomo; then
            success "Mihomo перезапущен с ipv6: $mihomo_ipv6_state"
        else
            warn "Mihomo не запустился. Лог:"
            journalctl -u mihomo -n 20 --no-pager
        fi
    fi
}
