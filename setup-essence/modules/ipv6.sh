#!/bin/bash
# ─── Переключение IPv6 ───────────────────────────────────────────────────────

toggle_ipv6() {
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
            success "IPv6 включён"
            ;;
        2)
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
            success "IPv6 отключён"
            ;;
        0)
            info "Отменено."
            ;;
        *)
            warn "Неверный выбор."
            ;;
    esac
}
