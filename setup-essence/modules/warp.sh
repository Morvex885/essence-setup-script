#!/bin/bash

_warp_valid_ipv4() {
    local address="$1" octet
    local -a octets

    IFS='.' read -r -a octets <<< "$address"
    [[ ${#octets[@]} -eq 4 ]] || return 1

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

_warp_valid_ipv6() {
    local address="$1" normalized group rest i
    local compressed=0 group_count=0
    local -a groups

    [[ "$address" == *:* ]] || return 1
    [[ "$address" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    [[ "$address" != *:::* ]] || return 1

    rest="$address"
    if [[ "$rest" == *::* ]]; then
        compressed=1
        rest="${rest#*::}"
        [[ "$rest" != *::* ]] || return 1
    fi

    [[ "$address" != :* || "$address" == ::* ]] || return 1
    [[ "$address" != *: || "$address" == *:: ]] || return 1

    normalized="${address//::/:}"
    IFS=':' read -r -a groups <<< "$normalized"
    for ((i = 0; i < ${#groups[@]}; i++)); do
        group="${groups[$i]}"
        [[ -z "$group" ]] && continue
        if [[ "$group" == *.* ]]; then
            (( i == ${#groups[@]} - 1 )) || return 1
            _warp_valid_ipv4 "$group" || return 1
            ((group_count += 2))
        else
            [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
            ((group_count++))
        fi
    done

    if (( compressed )); then
        (( group_count < 8 )) || return 1
    else
        (( group_count == 8 )) || return 1
    fi
}

parse_wgcf_address_line() {
    local line="$1" value entry address prefix
    local -a entries

    WGCF_IPV4_ADDRESS=""
    WGCF_IPV6_ADDRESS=""

    [[ "$line" =~ ^[[:space:]]*Address[[:space:]]*=[[:space:]]*(.*)$ ]] || return 1
    value="${BASH_REMATCH[1]}"
    IFS=',' read -r -a entries <<< "$value"

    for entry in "${entries[@]}"; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -n "$entry" ]] || continue

        address="$entry"
        prefix=""
        if [[ "$entry" == */* ]]; then
            address="${entry%/*}"
            prefix="${entry##*/}"
            [[ "$prefix" =~ ^[0-9]{1,3}$ ]] || continue
        fi

        if _warp_valid_ipv4 "$address"; then
            [[ -z "$prefix" || 10#$prefix -le 32 ]] || continue
            [[ -n "$WGCF_IPV4_ADDRESS" ]] || WGCF_IPV4_ADDRESS="$address"
        elif _warp_valid_ipv6 "$address"; then
            [[ -z "$prefix" || 10#$prefix -le 128 ]] || continue
            [[ -n "$WGCF_IPV6_ADDRESS" ]] || WGCF_IPV6_ADDRESS="$address"
        fi
    done

    [[ -n "$WGCF_IPV4_ADDRESS" ]]
}

parse_wgcf_profile_addresses() {
    local profile="$1" line

    WGCF_IPV4_ADDRESS=""
    WGCF_IPV6_ADDRESS=""
    [[ -f "$profile" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*Address[[:space:]]*= ]]; then
            parse_wgcf_address_line "$line"
            return $?
        fi
    done < "$profile"

    return 1
}

_warp_profile_value() {
    local key="$1" profile="$2"
    awk -v key="$key" '
        {
            separator=index($0, "=")
            if (!separator) next

            name=substr($0, 1, separator - 1)
            sub(/^[[:space:]]*/, "", name)
            sub(/[[:space:]]*$/, "", name)
            if (name != key) next

            value=substr($0, separator + 1)
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]\r]*$/, "", value)
            print value
            exit
        }
    ' "$profile"
}

_warp_valid_wireguard_key() {
    [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

parse_wgcf_profile_keys() {
    local profile="$1" private_key public_key

    WGCF_PROFILE_PRIVATE_KEY=""
    WGCF_PROFILE_PUBLIC_KEY=""
    [[ -f "$profile" ]] || return 1

    private_key=$(_warp_profile_value PrivateKey "$profile")
    public_key=$(_warp_profile_value PublicKey "$profile")
    _warp_valid_wireguard_key "$private_key" || return 1
    _warp_valid_wireguard_key "$public_key" || return 1

    WGCF_PROFILE_PRIVATE_KEY="$private_key"
    WGCF_PROFILE_PUBLIC_KEY="$public_key"
}

_warp_prepare_account() {
    local license="$1" require_license="${2:-0}"
    local wgcf_bin="${WGCF_BIN:-./wgcf}"
    local account_file="${WGCF_ACCOUNT_FILE:-wgcf-account.toml}"

    if [[ -f "$account_file" ]]; then
        info "Существующий аккаунт WARP найден — переиспользую"
    else
        info "Регистрирую новый аккаунт WARP..."
        printf 'y\n' | "$wgcf_bin" register || return 1
    fi

    if [[ -n "$license" ]]; then
        info "Применяю WARP+ лицензионный ключ..."
        if ! "$wgcf_bin" update --license-key "$license"; then
            [[ "$require_license" -eq 1 ]] && return 1
            warn "Ключ не применился — продолжаю с текущим аккаунтом"
        fi
    fi
}

_warp_generate_profile() {
    local wgcf_bin="${WGCF_BIN:-./wgcf}"
    local profile_file="${WGCF_PROFILE_FILE:-wgcf-profile.conf}"

    rm -f -- "$profile_file"
    "$wgcf_bin" generate || return 1
    [[ -s "$profile_file" ]]
}

_warp_store_profile() {
    local source_file="$1" target_file="$2"
    local target_dir temp_file old_umask

    target_dir=$(dirname "$target_file")
    old_umask=$(umask)
    umask 077
    temp_file=$(mktemp "$target_dir/.wgcf-profile.XXXXXX") || {
        umask "$old_umask"
        return 1
    }
    umask "$old_umask"

    if ! cp -- "$source_file" "$temp_file" || ! mv -f -- "$temp_file" "$target_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

_warp_restore_account_files() {
    local account_backup="$1" profile_backup="$2" had_profile="$3"

    rm -f -- wgcf-account.toml wgcf-profile.conf
    mv -f -- "$account_backup" wgcf-account.toml
    if [[ "$had_profile" -eq 1 ]]; then
        mv -f -- "$profile_backup" wgcf-profile.conf
    else
        rm -f -- "$profile_backup"
    fi
}

render_warp_yaml() {
    local private_key="$1" ipv4_address="$2" ipv6_address="$3" public_key="$4"

    printf '%s\n' '# --- warp ---' '  - name: warp-wg' '    type: wireguard'
    printf '    private-key: "%s"\n' "$private_key"
    printf '%s\n' '    server: engage.cloudflareclient.com' '    port: 2408'
    printf '    ip: %s\n' "$ipv4_address"
    if [[ -n "$ipv6_address" ]]; then
        printf '    ipv6: %s\n' "$ipv6_address"
        printf '    public-key: "%s"\n' "$public_key"
        printf "%s\n" "    allowed-ips: ['0.0.0.0/0', '::/0']"
    else
        printf '    public-key: "%s"\n' "$public_key"
        printf "%s\n" "    allowed-ips: ['0.0.0.0/0']"
    fi
    printf '%s\n' '    udp: true' '    mtu: 1280' '# --- /warp ---'
}

build_warp_config_candidate() {
    local mode="$1" source_config="$2" warp_block="$3"
    local start_count end_count proxy_marker_count add_to_outbound=0

    [[ -f "$source_config" && -f "$warp_block" ]] || return 1

    start_count=$(grep -c '^# --- warp ---$' "$source_config" || true)
    end_count=$(grep -c '^# --- /warp ---$' "$source_config" || true)

    case "$mode" in
        install)
            [[ "$start_count" -eq 0 && "$end_count" -eq 0 ]] || return 1
            proxy_marker_count=$(grep -c '^# --- proxies ---$' "$source_config" || true)
            [[ "$proxy_marker_count" -eq 1 ]] || return 1
            if ! grep -q '^      - warp-wg$' "$source_config"; then
                grep -q '^      - DIRECT$' "$source_config" || return 1
                add_to_outbound=1
            fi
            awk -v block_file="$warp_block" -v add_to_outbound="$add_to_outbound" '
                /^# --- proxies ---$/ {
                    print
                    while ((getline line < block_file) > 0) print line
                    close(block_file)
                    next
                }
                add_to_outbound && /^      - DIRECT$/ {
                    print "      - warp-wg"
                    add_to_outbound=0
                }
                { print }
            ' "$source_config"
            ;;
        update)
            [[ "$start_count" -eq 1 && "$end_count" -eq 1 ]] || return 1
            awk -v block_file="$warp_block" '
                /^# --- warp ---$/ {
                    while ((getline line < block_file) > 0) print line
                    close(block_file)
                    replacing=1
                    replaced=1
                    next
                }
                replacing && /^# --- \/warp ---$/ { replacing=0; next }
                !replacing { print }
                END { if (!replaced || replacing) exit 1 }
            ' "$source_config"
            ;;
        *)
            return 1
            ;;
    esac
}

_warp_apply_config() {
    local mode="$1" private_key="$2" ipv4_address="$3" ipv6_address="$4" public_key="$5"
    local config_file="${MIHOMO_CONFIG_FILE:-/etc/mihomo/config.yaml}"
    local config_dir candidate warp_block old_umask mihomo_bin

    config_dir=$(dirname "$config_file")
    old_umask=$(umask)
    umask 077
    warp_block=$(mktemp "$config_dir/.warp-block.XXXXXX") || { umask "$old_umask"; return 1; }
    candidate=$(mktemp "$config_dir/.config.yaml.XXXXXX") || {
        rm -f -- "$warp_block"
        umask "$old_umask"
        return 1
    }
    umask "$old_umask"

    if ! render_warp_yaml "$private_key" "$ipv4_address" "$ipv6_address" "$public_key" > "$warp_block" \
        || ! build_warp_config_candidate "$mode" "$config_file" "$warp_block" > "$candidate"; then
        rm -f -- "$warp_block" "$candidate"
        warn "Не удалось сформировать безопасный кандидат config.yaml."
        return 1
    fi
    rm -f -- "$warp_block"

    mihomo_bin="${MIHOMO_BIN:-/usr/local/bin/mihomo}"
    if [[ ! -x "$mihomo_bin" ]]; then
        mihomo_bin=$(command -v mihomo 2>/dev/null || true)
    fi
    if [[ -z "$mihomo_bin" ]] || ! "$mihomo_bin" -t -f "$candidate"; then
        rm -f -- "$candidate"
        warn "Проверка нового config.yaml через mihomo завершилась ошибкой; рабочий конфиг не изменён."
        return 1
    fi

    mv -f -- "$candidate" "$config_file"
}

_warp_apply_reregistered_profile() {
    local private_key="$1" ipv4_address="$2" ipv6_address="$3" public_key="$4"
    local config_file="${MIHOMO_CONFIG_FILE:-/etc/mihomo/config.yaml}"
    local stored_profile="${MIHOMO_WGCF_PROFILE_FILE:-/etc/mihomo/wgcf-profile.conf}"
    local source_profile="${WGCF_PROFILE_FILE:-wgcf-profile.conf}"
    local config_dir config_backup old_umask

    WARP_REREGISTER_APPLIED=0
    grep -q '^# --- warp ---$' "$config_file" 2>/dev/null || return 0

    config_dir=$(dirname "$config_file")
    old_umask=$(umask)
    umask 077
    config_backup=$(mktemp "$config_dir/.config.yaml.warp-backup.XXXXXX") || {
        umask "$old_umask"
        return 1
    }
    umask "$old_umask"

    if ! cp -- "$config_file" "$config_backup"; then
        rm -f -- "$config_backup"
        return 1
    fi
    if ! _warp_apply_config update "$private_key" "$ipv4_address" "$ipv6_address" "$public_key" \
        || ! _warp_store_profile "$source_profile" "$stored_profile"; then
        mv -f -- "$config_backup" "$config_file"
        return 1
    fi

    rm -f -- "$config_backup"
    WARP_REREGISTER_APPLIED=1
}
# ─── WARP ────────────────────────────────────────────────────────────────────

warp_menu() {
    echo ""
    box_top
    box_center "WARP"
    box_bot
    echo ""
    if grep -q '# --- warp ---' /etc/mihomo/config.yaml 2>/dev/null; then
        echo -e "  Статус: ${GREEN}установлен${NC}"
    else
        echo -e "  Статус: ${RED}не установлен${NC}"
    fi
    echo ""
    echo -e "  ${GREEN}1)${NC} Установить WARP"
    echo -e "  ${YELLOW}2)${NC} Обновить ключ"
    echo -e "  ${YELLOW}3)${NC} Перерегистрировать аккаунт WARP"
    echo -e "  ${RED}4)${NC} Удалить WARP"
    echo -e "  ${NC}0)${NC} Назад"
    echo ""
    read -rp "Выберите действие [0-4]: " WARP_CHOICE

    case "$WARP_CHOICE" in
        1) install_warp ;;
        2) update_warp ;;
        3) reregister_warp ;;
        4) uninstall_warp ;;
        0) return ;;
        *) warn "Неверный выбор." ;;
    esac
}

install_warp() {
    local warp_config_mode="install"
    echo ""

    if [[ ! -f /etc/mihomo/config.yaml ]]; then
        warn "Mihomo не установлен. Сначала выполните установку (пункт 1)."
        return
    fi

    if grep -q '# --- warp ---' /etc/mihomo/config.yaml; then
        warn "WARP уже настроен."
        confirm_yn "Переустановить?" || { info "Отменено."; return; }
        warp_config_mode="update"
    fi

    echo ""
    read -rp "WARP+ лицензионный ключ (Enter = бесплатный WARP): " WARP_LICENSE
    echo ""

    WGCF_DIR="/root/wgcf"
    mkdir -p "$WGCF_DIR"
    cd "$WGCF_DIR"

    if [[ ! -f "$WGCF_DIR/wgcf" ]] || ! "$WGCF_DIR/wgcf" --version > /dev/null 2>&1; then
        rm -f "$WGCF_DIR/wgcf"
        info "Определяю последнюю версию wgcf..."
        WGCF_VERSION=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest \
            | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v')
        [[ -z "$WGCF_VERSION" ]] && error "Не удалось получить версию wgcf с GitHub."
        local wgcf_arch
        case "$(uname -m)" in
            aarch64|arm64) wgcf_arch="arm64" ;;
            armv7l|armv7)  wgcf_arch="armv7" ;;
            *)             wgcf_arch="amd64" ;;
        esac
        info "Скачиваю wgcf v${WGCF_VERSION} (${wgcf_arch})..."
        curl -sLo "$WGCF_DIR/wgcf" \
            "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${wgcf_arch}" \
            || { rm -f "$WGCF_DIR/wgcf"; error "Не удалось скачать wgcf"; }
        chmod +x "$WGCF_DIR/wgcf"
        success "wgcf скачан"
    fi

    _warp_prepare_account "$WARP_LICENSE" || error "Ошибка регистрации WARP"

    info "Генерирую WireGuard конфиг..."
    _warp_generate_profile || error "Ошибка генерации WireGuard-конфига WARP"

    if ! parse_wgcf_profile_keys wgcf-profile.conf; then
        error "Не удалось распарсить корректные ключи WARP из wgcf-profile.conf"
        return 1
    fi
    WARP_PRIVATE_KEY="$WGCF_PROFILE_PRIVATE_KEY"
    WARP_PUBLIC_KEY="$WGCF_PROFILE_PUBLIC_KEY"
    if ! parse_wgcf_profile_addresses wgcf-profile.conf; then
        error "Не удалось найти корректный IPv4-адрес WARP в wgcf-profile.conf"
        return 1
    fi
    WARP_IP="$WGCF_IPV4_ADDRESS"
    WARP_IPV6="$WGCF_IPV6_ADDRESS"

    if [[ -z "$WARP_IPV6" ]]; then
        warn "IPv6-адрес WARP отсутствует; будет создан корректный IPv4-only proxy."
    fi

    if ! _warp_apply_config "$warp_config_mode" "$WARP_PRIVATE_KEY" "$WARP_IP" "$WARP_IPV6" "$WARP_PUBLIC_KEY"; then
        cd /root
        error "Конфигурация WARP не применена."
        return 1
    fi

    _warp_store_profile wgcf-profile.conf /etc/mihomo/wgcf-profile.conf \
        || error "Не удалось сохранить профиль WARP в /etc/mihomo"
    cd /root
    success "WARP настроен: IPv4=$WARP_IP${WARP_IPV6:+, IPv6=$WARP_IPV6}"
    success "WARP добавлен в группу outbound"

    sed -i '/^WARP IP:/d; /^WARP Public key:/d' /etc/mihomo/client-config.txt
    sed -i "/^Short ID:/a WARP IP:          $WARP_IP\nWARP Public key:  $WARP_PUBLIC_KEY" \
        /etc/mihomo/client-config.txt

    info "Перезапускаю Mihomo..."
    systemctl restart mihomo &>/dev/null
    sleep 4

    if systemctl is-active --quiet mihomo; then
        success "Mihomo перезапущен с WARP"
    else
        warn "Mihomo не запустился. Лог:"
        journalctl -u mihomo -n 20 --no-pager
    fi

    echo ""
    success_box "WARP настроен!"
    echo ""
    echo -e "  WARP IP:         ${CYAN}$WARP_IP${NC}"
    [[ -n "$WARP_IPV6" ]] && echo -e "  WARP IPv6:       ${CYAN}$WARP_IPV6${NC}"
    echo -e "  WARP Public key: ${CYAN}$WARP_PUBLIC_KEY${NC}"
    echo -e "  Профиль:         ${CYAN}/etc/mihomo/wgcf-profile.conf${NC}"
    echo ""
}

reregister_warp() {
    local wgcf_dir="/root/wgcf"
    local original_dir="$PWD" account_backup profile_backup
    local old_umask had_profile=0 warp_installed=0
    local private_key public_key warp_ip warp_ipv6 new_warp_license

    echo ""
    if [[ ! -f "$wgcf_dir/wgcf-account.toml" ]]; then
        warn "Существующий аккаунт WARP не найден. Используйте обычную установку WARP."
        return
    fi
    if [[ ! -x "$wgcf_dir/wgcf" ]] || ! "$wgcf_dir/wgcf" --version > /dev/null 2>&1; then
        warn "wgcf не найден или повреждён. Сначала запустите обычную установку WARP."
        return
    fi

    warn "Будет создана новая регистрация устройства WARP."
    warn "Старая регистрация останется в Cloudflare и может занимать слот WARP+."
    warn "При необходимости удалите старое устройство вручную в приложении 1.1.1.1."
    confirm_yn "Перерегистрировать аккаунт WARP?" N || { info "Отменено."; return; }

    echo ""
    read -rp "WARP+ лицензионный ключ для нового аккаунта (Enter = бесплатный WARP): " new_warp_license
    echo ""

    cd "$wgcf_dir" || { warn "Не удалось открыть $wgcf_dir"; return; }
    old_umask=$(umask)
    umask 077
    account_backup=$(mktemp "$wgcf_dir/.wgcf-account.backup.XXXXXX") || {
        umask "$old_umask"
        cd "$original_dir"
        warn "Не удалось создать резервную копию аккаунта WARP."
        return
    }
    profile_backup=$(mktemp "$wgcf_dir/.wgcf-profile.backup.XXXXXX") || {
        umask "$old_umask"
        rm -f -- "$account_backup"
        cd "$original_dir"
        warn "Не удалось создать резервную копию профиля WARP."
        return
    }
    umask "$old_umask"

    if ! cp -- wgcf-account.toml "$account_backup"; then
        rm -f -- "$account_backup" "$profile_backup"
        cd "$original_dir"
        warn "Не удалось сохранить резервную копию аккаунта WARP."
        return
    fi
    if [[ -f wgcf-profile.conf ]]; then
        had_profile=1
        if ! cp -- wgcf-profile.conf "$profile_backup"; then
            rm -f -- "$account_backup" "$profile_backup"
            cd "$original_dir"
            warn "Не удалось сохранить резервную копию профиля WARP."
            return
        fi
    fi

    rm -f -- wgcf-account.toml wgcf-profile.conf
    if ! _warp_prepare_account "$new_warp_license" 1; then
        _warp_restore_account_files "$account_backup" "$profile_backup" "$had_profile"
        cd "$original_dir"
        warn "Новый аккаунт не подготовлен; предыдущий аккаунт восстановлен."
        warn "Неудачная удалённая регистрация могла остаться в Cloudflare."
        return
    fi

    info "Генерирую WireGuard конфиг для нового аккаунта..."
    if ! _warp_generate_profile \
        || ! parse_wgcf_profile_keys wgcf-profile.conf \
        || ! parse_wgcf_profile_addresses wgcf-profile.conf; then
        _warp_restore_account_files "$account_backup" "$profile_backup" "$had_profile"
        cd "$original_dir"
        warn "Новый профиль не создан; предыдущий аккаунт восстановлен."
        warn "Новая удалённая регистрация могла остаться в Cloudflare."
        return
    fi

    private_key="$WGCF_PROFILE_PRIVATE_KEY"
    public_key="$WGCF_PROFILE_PUBLIC_KEY"
    warp_ip="$WGCF_IPV4_ADDRESS"
    warp_ipv6="$WGCF_IPV6_ADDRESS"
    if ! _warp_apply_reregistered_profile "$private_key" "$warp_ip" "$warp_ipv6" "$public_key"; then
        _warp_restore_account_files "$account_backup" "$profile_backup" "$had_profile"
        cd "$original_dir"
        warn "Новый аккаунт не применён; предыдущая конфигурация восстановлена."
        return
    fi
    warp_installed="$WARP_REREGISTER_APPLIED"

    rm -f -- "$account_backup" "$profile_backup"
    cd "$original_dir"

    if [[ "$warp_installed" -eq 1 ]]; then
        sed -i '/^WARP IP:/d; /^WARP Public key:/d' /etc/mihomo/client-config.txt
        sed -i "/^Short ID:/a WARP IP:          $warp_ip\nWARP Public key:  $public_key" \
            /etc/mihomo/client-config.txt
        info "Перезапускаю Mihomo..."
        systemctl restart mihomo &>/dev/null
        sleep 3
        if systemctl is-active --quiet mihomo; then
            success "Mihomo перезапущен с новым аккаунтом WARP"
        else
            warn "Mihomo не запустился. Лог:"
            journalctl -u mihomo -n 20 --no-pager
        fi
    else
        success "Новый аккаунт и WireGuard-профиль WARP подготовлены."
        info "Запустите обычную установку WARP, чтобы добавить его в Mihomo."
    fi
    echo ""
}

uninstall_warp() {
    echo ""

    if ! grep -q '# --- warp ---' /etc/mihomo/config.yaml 2>/dev/null; then
        warn "WARP не настроен."
        return
    fi

    warn "Будет удалён WARP из конфига Mihomo и файлы wgcf."
    confirm_yn "Вы уверены?" || { info "Отменено."; return; }

    awk '
        /^# --- warp ---/{print; skip=1; next}
        skip && /^# --- \/warp ---/{skip=0}
        {print}
    ' /etc/mihomo/config.yaml > /tmp/mihomo_tmp.yaml
    mv /tmp/mihomo_tmp.yaml /etc/mihomo/config.yaml
    success "WARP proxy удалён из config.yaml"

    sed -i '/^      - warp-wg$/d' /etc/mihomo/config.yaml
    success "warp-wg удалён из группы outbound"

    sed -i '/^WARP IP:/d; /^WARP Public key:/d' /etc/mihomo/client-config.txt

    rm -rf /root/wgcf
    rm -f /etc/mihomo/wgcf-profile.conf
    success "Файлы wgcf удалены"

    info "Перезапускаю Mihomo..."
    systemctl restart mihomo &>/dev/null
    sleep 3

    if systemctl is-active --quiet mihomo; then
        success "Mihomo перезапущен без WARP"
    else
        warn "Mihomo не запустился. Лог:"
        journalctl -u mihomo -n 20 --no-pager
    fi
    echo ""
}

update_warp() {
    echo ""

    if [[ ! -f /etc/mihomo/config.yaml ]]; then
        warn "Mihomo не установлен. Сначала выполните установку (пункт 1)."
        return
    fi

    if ! grep -q '# --- warp ---' /etc/mihomo/config.yaml; then
        warn "WARP не настроен. Сначала выполните установку WARP (пункт 4 → 1)."
        return
    fi

    WGCF_DIR="/root/wgcf"
    if [[ ! -f "$WGCF_DIR/wgcf" ]] || ! "$WGCF_DIR/wgcf" --version > /dev/null 2>&1; then
        rm -f "$WGCF_DIR/wgcf"
        info "Определяю последнюю версию wgcf..."
        local WGCF_VERSION wgcf_arch
        WGCF_VERSION=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest \
            | grep '"tag_name"' | cut -d'"' -f4 | tr -d 'v')
        [[ -z "$WGCF_VERSION" ]] && error "Не удалось получить версию wgcf с GitHub."
        case "$(uname -m)" in
            aarch64|arm64) wgcf_arch="arm64" ;;
            armv7l|armv7)  wgcf_arch="armv7" ;;
            *)             wgcf_arch="amd64" ;;
        esac
        info "wgcf не найден, скачиваю v${WGCF_VERSION} (${wgcf_arch})..."
        mkdir -p "$WGCF_DIR"
        curl -sLo "$WGCF_DIR/wgcf" \
            "https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${wgcf_arch}" \
            || { rm -f "$WGCF_DIR/wgcf"; error "Не удалось скачать wgcf"; }
        chmod +x "$WGCF_DIR/wgcf"
        success "wgcf скачан"
    fi

    echo ""
    read -rp "WARP+ лицензионный ключ (Enter = бесплатный WARP): " NEW_WARP_LICENSE
    echo ""

    cd "$WGCF_DIR"

    _warp_prepare_account "$NEW_WARP_LICENSE" || error "Ошибка регистрации WARP"

    info "Генерирую новый WireGuard конфиг..."
    _warp_generate_profile || error "Ошибка генерации WireGuard-конфига WARP"

    if ! parse_wgcf_profile_keys wgcf-profile.conf; then
        error "Не удалось распарсить корректные ключи WARP из wgcf-profile.conf"
        return 1
    fi
    NEW_PRIVATE_KEY="$WGCF_PROFILE_PRIVATE_KEY"
    NEW_PUBLIC_KEY="$WGCF_PROFILE_PUBLIC_KEY"
    if ! parse_wgcf_profile_addresses wgcf-profile.conf; then
        error "Не удалось найти корректный IPv4-адрес WARP в wgcf-profile.conf"
        return 1
    fi
    NEW_WARP_IP="$WGCF_IPV4_ADDRESS"
    NEW_WARP_IPV6="$WGCF_IPV6_ADDRESS"

    if [[ -z "$NEW_WARP_IPV6" ]]; then
        warn "IPv6-адрес WARP отсутствует; будет создан корректный IPv4-only proxy."
    fi

    info "Новый WARP IP:         $NEW_WARP_IP"
    [[ -n "$NEW_WARP_IPV6" ]] && info "Новый WARP IPv6:       $NEW_WARP_IPV6"
    info "Новый WARP Public key: $NEW_PUBLIC_KEY"

    if ! _warp_apply_config update "$NEW_PRIVATE_KEY" "$NEW_WARP_IP" "$NEW_WARP_IPV6" "$NEW_PUBLIC_KEY"; then
        cd /root
        error "Новый WARP-конфиг не применён."
        return 1
    fi

    _warp_store_profile wgcf-profile.conf /etc/mihomo/wgcf-profile.conf \
        || error "Не удалось сохранить профиль WARP в /etc/mihomo"
    cd /root

    info "Перезапускаю Mihomo..."
    systemctl restart mihomo &>/dev/null
    sleep 3

    if systemctl is-active --quiet mihomo; then
        success "Mihomo перезапущен с новым WARP конфигом"
    else
        warn "Mihomo не запустился. Лог:"
        journalctl -u mihomo -n 20 --no-pager
    fi

    echo ""
    echo -e "  WARP IP:         ${CYAN}$NEW_WARP_IP${NC}"
    [[ -n "$NEW_WARP_IPV6" ]] && echo -e "  WARP IPv6:       ${CYAN}$NEW_WARP_IPV6${NC}"
    echo -e "  WARP Public key: ${CYAN}$NEW_PUBLIC_KEY${NC}"
    echo -e "  Профиль:         ${CYAN}/etc/mihomo/wgcf-profile.conf${NC}"
    echo ""
}
