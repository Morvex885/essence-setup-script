#!/bin/bash
# ─── Общие функции для работы с acme.sh и TLS-сертификатами ─────────────────

ACME="$HOME/.acme.sh/acme.sh"

acme_email_valid() {
    [[ "${1:-}" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]
}

# Read one allowlisted acme.sh assignment without executing account configuration.
# 0 = present, 1 = absent, 2 = malformed, duplicate or unreadable.
_acme_conf_value() {
    local file="$1" key="$2" line found=false
    ACME_CONF_VALUE=""
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    [[ -e "$file" ]] || return 1
    [[ -f "$file" && -r "$file" ]] || return 2
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$key="* ]]; then
            if [[ "$found" != false || ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\'([^\']*)\'$ ]]; then
                ACME_CONF_VALUE=""
                return 2
            fi
            [[ "${BASH_REMATCH[1]}" == "$key" ]] || return 2
            ACME_CONF_VALUE="${BASH_REMATCH[2]}"
            found=true
        fi
    done < "$file" || { ACME_CONF_VALUE=""; return 2; }
    [[ "$found" == true ]] || { ACME_CONF_VALUE=""; return 1; }
}

_acme_ca_conf() {
    printf '%s' "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf"
}

_acme_current_email() {
    local status ca_conf
    ACME_CURRENT_EMAIL=""
    ca_conf=$(_acme_ca_conf)
    if _acme_conf_value "$ca_conf" CA_EMAIL; then status=0; else status=$?; fi
    if (( status == 1 )); then
        if _acme_conf_value "$HOME/.acme.sh/account.conf" ACCOUNT_EMAIL; then status=0; else status=$?; fi
    fi
    if (( status == 0 )) && acme_email_valid "$ACME_CONF_VALUE"; then
        ACME_CURRENT_EMAIL="$ACME_CONF_VALUE"
        return 0
    fi
    warn "Текущий email acme.sh неизвестен или недоступен."
    return 1
}

acme_select_email() {
    local current="" generated="" answer="" registered=false ca_conf
    ACME_SELECTED_EMAIL=""
    ca_conf=$(_acme_ca_conf)
    if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
        _acme_current_email && current="$ACME_CURRENT_EMAIL"
        if _acme_conf_value "$ca_conf" ACCOUNT_URL && [[ -n "$ACME_CONF_VALUE" ]]; then
            registered=true
        fi
    else
        local user_part domain_part
        user_part=$(openssl rand -hex 4) && domain_part=$(openssl rand -hex 3) &&
            [[ "$user_part" =~ ^[[:xdigit:]]{8}$ && "$domain_part" =~ ^[[:xdigit:]]{6}$ ]] || {
            warn "Не удалось сгенерировать email для acme.sh."
            return 1
        }
        generated="user${user_part}@${domain_part}.com"
    fi
    while true; do
        if [[ -n "$current" ]]; then
            IFS= read -rp "  Email для acme.sh [Enter = $current]: " answer || return 1
        elif [[ -n "$generated" ]]; then
            IFS= read -rp "  Email для acme.sh [Enter = $generated]: " answer || return 1
        else
            IFS= read -rp "  Email для acme.sh (введите вручную): " answer || return 1
        fi
        answer="${answer%$'\r'}"
        if [[ -z "$answer" ]]; then
            answer="${current:-$generated}"
            if [[ -z "$answer" ]]; then
                warn "Текущий email неизвестен. Введите email вручную."
                continue
            fi
        fi
        if ! acme_email_valid "$answer"; then
            warn "Некорректный ACME email."
            continue
        fi
        if [[ -n "$current" && "$answer" != "$current" ]]; then
            confirm_yn "Изменить контакт Let's Encrypt с $current на $answer?" N || continue
        elif [[ -z "$current" && "$registered" == true ]]; then
            confirm_yn "Текущий email неизвестен. Установить контакт Let's Encrypt: $answer?" N || continue
        fi
        ACME_SELECTED_EMAIL="$answer"
        return 0
    done
}

ensure_acme_installed() {
    local email="$1" installer ca_conf old_email="" registered=false
    acme_email_valid "$email" || { warn "Некорректный ACME email."; return 1; }
    if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
        installer=$(umask 077; mktemp "${TMPDIR:-/tmp}/essence-acme.XXXXXX") || {
            warn "Не удалось установить acme.sh."
            return 1
        }
        if ! curl -fsS https://get.acme.sh -o "$installer" ||
           ! sh "$installer" "email=$email"; then
            rm -f "$installer"
            warn "Не удалось установить acme.sh."
            return 1
        fi
        rm -f "$installer" || { warn "Не удалось удалить временный установщик."; return 1; }
    else
        info "acme.sh уже установлен"
    fi
    ACME="$HOME/.acme.sh/acme.sh"
    "$ACME" --set-default-ca --server letsencrypt || {
        warn "Не удалось настроить Let's Encrypt в acme.sh."
        return 1
    }
    ca_conf=$(_acme_ca_conf)
    if _acme_conf_value "$ca_conf" ACCOUNT_URL && [[ -n "$ACME_CONF_VALUE" ]]; then
        registered=true
    fi
    if _acme_conf_value "$ca_conf" CA_EMAIL && acme_email_valid "$ACME_CONF_VALUE"; then
        old_email="$ACME_CONF_VALUE"
    fi
    if [[ "$registered" == true ]]; then
        if [[ "$old_email" != "$email" ]]; then
            "$ACME" --update-account --server letsencrypt -m "$email" || {
                warn "Не удалось обновить контакт Let's Encrypt."
                return 1
            }
        fi
    else
        "$ACME" --register-account --server letsencrypt -m "$email" || {
            warn "Не удалось зарегистрировать аккаунт Let's Encrypt."
            return 1
        }
    fi
    if ! _acme_conf_value "$ca_conf" CA_EMAIL || [[ "$ACME_CONF_VALUE" != "$email" ]]; then
        warn "Контакт Let's Encrypt не совпадает с запрошенным email."
        return 1
    fi
}

# Identity is also used as a filename and a literal nginx server_name.
_cert_identity_valid() {
    [[ -n "${1:-}" && "$1" != *[[:space:][:cntrl:]/]* &&
       "$1" != "." && "$1" != ".." && "$1" != *[\'\"\`\$\;\{\}\(\)\\\&\|\<\>\*\?\[\]\#]* ]]
}

_cert_safe_path() {
    [[ "${1:-}" == /* && "$1" != "/" &&
       "$1" != *[[:cntrl:]\'\"\`\$\;\{\}\(\)\\\&\|\<\>\*\?\[\]\#]* &&
       "$1" != *[[:space:]]* && "/${1#/}/" != *"/../"* ]]
}

_cert_prerequisites() {
    local version xhelp vhelp trust="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
    [[ -f "$trust" && -r "$trust" && -s "$trust" ]] || return 2
    version=$(openssl version 2>/dev/null) || return 2
    case "$version" in
        "OpenSSL 1.1.1"*|"OpenSSL "[3-9].*) ;;
        *) return 2 ;;
    esac
    xhelp=$(openssl x509 -help 2>&1)
    vhelp=$(openssl verify -help 2>&1)
    [[ "$xhelp" == *"-ext "* && "$vhelp" == *"-verify_hostname"* &&
       "$vhelp" == *"-verify_ip"* && "$vhelp" == *"-attime"* &&
       "$vhelp" == *"-purpose"* ]] || return 2
    openssl x509 -in "$trust" -noout >/dev/null 2>&1 || return 2
}

# Split and validate every PEM block, including intermediates. Never trust them
# as roots. Refuse trailing junk, nested blocks and incomplete final blocks.
_cert_split_chain() {
    local file="$1" dir="$2" line inside=false count=0
    [[ -f "$file" && -r "$file" && -s "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
            [[ "$inside" == false ]] || return 1
            count=$((count + 1))
            inside=true
            printf '%s\n' "$line" > "$dir/chain-$count.pem" || return 1
        elif [[ "$line" == "-----END CERTIFICATE-----" ]]; then
            [[ "$inside" == true ]] || return 1
            printf '%s\n' "$line" >> "$dir/chain-$count.pem" || return 1
            openssl x509 -in "$dir/chain-$count.pem" -noout >/dev/null 2>&1 || return 1
            inside=false
        elif [[ "$inside" == true ]]; then
            [[ -n "$line" && "$line" != *[!A-Za-z0-9+/=]* ]] || return 1
            printf '%s\n' "$line" >> "$dir/chain-$count.pem" || return 1
        else
            [[ -z "${line//[[:space:]]/}" ]] || return 1
        fi
    done < "$file"
    [[ "$inside" == false && "$count" -gt 0 ]] || return 1
    local i
    : > "$dir/intermediates.pem" || return 1
    for ((i=2; i<=count; i++)); do
        cat "$dir/chain-$i.pem" >> "$dir/intermediates.pem" || return 1
    done
}

_cert_key_pem_valid() {
    local file="$1" line label="" state=before
    [[ -f "$file" && -r "$file" && -s "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$state" == before && "$line" == "-----BEGIN "*"-----" ]]; then
            label="${line#-----BEGIN }" label="${label%-----}"
            case "$label" in "PRIVATE KEY"|"RSA PRIVATE KEY"|"EC PRIVATE KEY"|"ENCRYPTED PRIVATE KEY") ;; *) return 1 ;; esac
            state=inside
        elif [[ "$state" == inside && "$line" == "-----END $label-----" ]]; then
            state=after
        elif [[ "$state" == inside ]]; then
            [[ -n "$line" && "$line" != *[!A-Za-z0-9+/=]* ]] || return 1
        else
            [[ -z "${line//[[:space:]]/}" ]] || return 1
        fi
    done < "$file"
    [[ "$state" == after ]]
}

# 0 usable; 1 invalid; 2 missing crypto/trust capabilities. The optional epoch
# is a single clock snapshot, also permitting deterministic boundary checks.
cert_is_usable() (
    local identity="${1:-}" chain="${2:-}" key="${3:-}" is_ip="${4:-false}"
    local now="${5:-}" tmp san pubcert pubkey vhelp
    _cert_identity_valid "$identity" || return 1
    _cert_safe_path "$chain" && _cert_safe_path "$key" || return 1
    [[ "$is_ip" == true || "$is_ip" == false ]] || return 1
    _cert_prerequisites || return 2
    [[ -n "$now" ]] || now=$(date +%s) || return 2
    [[ "$now" =~ ^[0-9]+$ && ${#now} -le 12 ]] || return 1
    umask 077
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/essence-cert-check.XXXXXX") || return 2
    trap 'rm -rf "$tmp"' EXIT
    _cert_split_chain "$chain" "$tmp" || return 1
    _cert_key_pem_valid "$key" || return 1
    san=$(openssl x509 -in "$tmp/chain-1.pem" -noout -ext subjectAltName 2>/dev/null) || return 1
    local verify_args=(-purpose sslserver -CAfile "${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" -no-CApath)
    vhelp=$(openssl verify -help 2>&1)
    [[ "$vhelp" != *"-no-CAstore"* ]] || verify_args+=(-no-CAstore)
    if [[ "$is_ip" == true ]]; then
        [[ "$san" == *"IP Address:"* ]] || return 1
        verify_args+=(-verify_ip "$identity")
    else
        [[ "$san" == *"DNS:"* ]] || return 1
        verify_args+=(-verify_hostname "$identity")
    fi
    [[ ! -s "$tmp/intermediates.pem" ]] || verify_args+=(-untrusted "$tmp/intermediates.pem")
    openssl verify "${verify_args[@]}" -attime "$now" "$tmp/chain-1.pem" >/dev/null 2>&1 || return 1
    openssl verify "${verify_args[@]}" -attime "$((10#$now + 86400))" "$tmp/chain-1.pem" >/dev/null 2>&1 || return 1
    pubcert=$(openssl x509 -in "$tmp/chain-1.pem" -pubkey -noout 2>/dev/null) || return 1
    pubkey=$(openssl pkey -in "$key" -pubout -passin pass: 2>/dev/null) || return 1
    [[ -n "$pubcert" && "$pubcert" == "$pubkey" ]]
)

# Validate the complete domain config before handing it to acme.sh, which
# sources it. Accept only literal quoted assignments and comments/blank lines.
_cert_registration_valid() {
    local file="$1" identity="$2" family="$3" line name value seen="|" length="" rc
    [[ -f "$file" && -r "$file" && ! -L "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\'([^\']*)\'$ ]] || return 1
        name="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
        [[ "$seen" != *"|$name|"* && "$value" != *[[:cntrl:]]* ]] || return 1
        seen="$seen$name|"
    done < "$file" || return 1
    _acme_conf_value "$file" Le_Domain || return 1
    [[ "$ACME_CONF_VALUE" == "$identity" ]] || return 1
    if _acme_conf_value "$file" Le_Keylength; then rc=0; else rc=$?; fi
    ((rc != 2)) || return 1
    length="$ACME_CONF_VALUE"
    if [[ "$family" == ecc ]]; then
        case "$length" in ec-256|ec-384|ec-521) ;; *) return 1 ;; esac
    else
        [[ -n "$length" ]] || length=2048
        [[ "$length" =~ ^[0-9]+$ && ${#length} -le 6 ]] || return 1
        ((10#$length >= 2048)) || return 1
    fi
    CERT_KEY_LENGTH="$length"
}

# Globals are confined to callers' subshells; family order is ECC then RSA.
_cert_registrations() {
    local identity="$1" family dir active removed file
    CERT_REG_FAMILIES=() CERT_REG_FILES=() CERT_REG_LENGTHS=()
    for family in ecc rsa; do
        dir="$HOME/.acme.sh/$identity"
        [[ "$family" != ecc ]] || dir="${dir}_ecc"
        [[ ! -L "$dir" ]] || return 1
        active="$dir/$identity.conf" removed="$dir/$identity.conf.removed"
        [[ ! -L "$active" && ! -L "$removed" ]] || return 1
        [[ ! ( -e "$active" && -e "$removed" ) ]] || return 1
        file=""
        [[ ! -e "$removed" ]] || file="$removed"
        [[ ! -e "$active" ]] || file="$active"
        [[ -n "$file" ]] || continue
        _cert_registration_valid "$file" "$identity" "$family" || return 1
        CERT_REG_FAMILIES+=("$family")
        CERT_REG_FILES+=("$file")
        CERT_REG_LENGTHS+=("$CERT_KEY_LENGTH")
    done
}

# Update only lifecycle fields; all other bytes/lines remain untouched.
_cert_write_metadata() (
    local file="$1" webroot="$2" dest="$3" line name i tmp
    local keys=(Le_Webroot Le_PreHook Le_PostHook Le_RealCertPath Le_RealKeyPath Le_RealCACertPath Le_RealFullChainPath Le_ReloadCmd Le_InstallCertSuccessTime Le_InstallCertSuccessTimeStr)
    local values=("$webroot" "ufw allow 80/tcp" "ufw deny 80/tcp && systemctl reload nginx" "$dest/cert.pem" "$dest/privkey.pem" "" "$dest/fullchain.pem" "systemctl reload nginx" "" "")
    local seen=()
    # renew() retries a pending install before its renewal-date check. The
    # published pair was independently validated, so no unchecked archive
    # retry may replace it (including when the archive itself is damaged).
    _cert_safe_path "$file" && _cert_safe_path "$webroot" && _cert_safe_path "$dest" || return 1
    [[ -f "$file" && -r "$file" && ! -L "$file" ]] || return 1
    umask 077
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    trap 'rm -f "$tmp"' EXIT
    while IFS= read -r line || [[ -n "$line" ]]; do
        name="${line%%=*}"
        for ((i=0; i<${#keys[@]}; i++)); do
            if [[ "$name" == "${keys[$i]}" ]]; then
                [[ "${seen[$i]:-}" != true ]] || return 1
                [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\'([^\']*)\'$ ]] || return 1
                seen[$i]=true
                line="$name='${values[$i]}'"
                break
            fi
        done
        printf '%s\n' "$line" >> "$tmp" || return 1
    done < "$file"
    for ((i=0; i<${#keys[@]}; i++)); do
        [[ "${seen[$i]:-}" == true ]] || printf "%s='%s'\n" "${keys[$i]}" "${values[$i]}" >> "$tmp" || return 1
    done
    chmod 600 "$tmp" && mv -f "$tmp" "$file"
)

# Tokenize nginx syntax, not arbitrary hostname substrings. Quoted literal
# paths work; variables, escapes and ambiguous certificate directives fail
# closed. Comments (including nginx -T file headers) cannot be consumers.
_cert_scan_nginx() {
    local text="$1" identity="$2" mode="${3:-consumers}"
    local line char token="" quote="" escaped=false i found=false roots=0 destination existing duplicate
    local words=()
    CERT_SCAN_ROOT=""
    CERT_CONSUMER_DESTINATIONS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$line "
        for ((i=0; i<${#line}; i++)); do
            char="${line:$i:1}"
            if [[ "$escaped" == true ]]; then token="$token$char"; escaped=false; continue; fi
            if [[ "$char" == \\ ]]; then token="$token$char"; escaped=true; continue; fi
            if [[ -n "$quote" ]]; then
                if [[ "$char" == "$quote" ]]; then quote=""; else token="$token$char"; fi
                continue
            fi
            case "$char" in
                \#) break ;;
                \"|\') quote="$char"; continue ;;
                ' '|$'\t'|$'\r'|';'|'{'|'}')
                    if [[ -n "$token" ]]; then words+=("$token"); token=""; fi
                    if [[ "$char" == ';' || "$char" == '{' || "$char" == '}' ]]; then
                        if [[ "${words[0]:-}" == ssl_certificate || "${words[0]:-}" == ssl_certificate_key ]]; then
                            [[ "$char" == ';' && ${#words[@]} -eq 2 ]] || return 2
                            _cert_safe_path "${words[1]}" || return 2
                            case "${words[1]}" in
                                */"$identity"/fullchain.pem|*/"$identity"/cert.pem|*/"$identity"/privkey.pem)
                                    found=true
                                    destination="${words[1]%/*}"
                                    duplicate=false
                                    for existing in ${CERT_CONSUMER_DESTINATIONS[@]+"${CERT_CONSUMER_DESTINATIONS[@]}"}; do
                                        [[ "$existing" != "$destination" ]] || duplicate=true
                                    done
                                    [[ "$duplicate" == true ]] || CERT_CONSUMER_DESTINATIONS+=("$destination")
                                    ;;
                            esac
                        elif [[ "$mode" == root && "${words[0]:-}" == root ]]; then
                            [[ "$char" == ';' && ${#words[@]} -eq 2 ]] || return 2
                            _cert_safe_path "${words[1]}" || return 2
                            CERT_SCAN_ROOT="${words[1]}"
                            roots=$((roots + 1))
                        fi
                        words=()
                    fi ;;
                *) token="$token$char" ;;
            esac
        done
        if [[ -z "$quote" && -n "$token" ]]; then words+=("$token"); token=""; fi
    done <<< "$text"
    [[ -z "$quote" && "$escaped" == false && ${#words[@]} -eq 0 ]] || return 2
    if [[ "$mode" == root ]]; then [[ "$roots" -eq 1 ]]; else [[ "$found" == true ]]; fi
}

_cert_has_consumers() {
    local identity="$1" cert_dir="$2" conf="$3" text
    _cert_identity_valid "$identity" && _cert_safe_path "$cert_dir" && _cert_safe_path "$conf" || return 2
    text=$(nginx -T -c "$conf" 2>/dev/null) || return 2
    [[ -n "$text" ]] || return 2
    _cert_scan_nginx "$text" "$identity"
}

# Rollback may have removed the installing feature's copy while a different
# cert root still serves this identity. Return a usable live destination using
# exactly the same conservative nginx parsing as release.
_cert_find_consumer_directory() {
    local identity="$1" cert_dir="$2" conf="$3" destination rc is_ip=false
    local candidates=()
    CERT_CONSUMER_CERT_DIR="" CERT_CONSUMER_DEST=""
    if _cert_has_consumers "$identity" "$cert_dir" "$conf"; then rc=0; else rc=$?; fi
    ((rc == 0)) || return "$rc"
    [[ "$identity" != *:* && ! "$identity" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || is_ip=true
    for destination in ${CERT_CONSUMER_DESTINATIONS[@]+"${CERT_CONSUMER_DESTINATIONS[@]}"}; do
        [[ "$destination" != "$cert_dir/$identity" ]] || candidates+=("$destination")
    done
    for destination in ${CERT_CONSUMER_DESTINATIONS[@]+"${CERT_CONSUMER_DESTINATIONS[@]}"}; do
        [[ "$destination" == "$cert_dir/$identity" ]] || candidates+=("$destination")
    done
    for destination in ${candidates[@]+"${candidates[@]}"}; do
        if cert_is_usable "$identity" "$destination/fullchain.pem" "$destination/privkey.pem" "$is_ip"; then rc=0; else rc=$?; fi
        ((rc != 2)) || return 2
        ((rc == 0)) || continue
        CERT_CONSUMER_DEST="$destination"
        CERT_CONSUMER_CERT_DIR="${destination%/*}"
        return 0
    done
    return 1
}

_cert_site_root() {
    local site="$1" text
    [[ -f "$site" && -r "$site" && ! -L "$site" ]] || return 1
    text=$(cat "$site") || return 1
    [[ "$text" == "# Essence ACME challenge"$'\n'* ]] || return 1
    _cert_scan_nginx "$text" "" root || return 1
    CERT_EFFECTIVE_WEBROOT="$CERT_SCAN_ROOT"
}

_cert_effective_root() {
    local identity="$1" webroot="$2" available="$3" cert_dir="$4" conf="$5" rc
    CERT_EFFECTIVE_WEBROOT="$webroot"
    if [[ -e "$available/essence-acme-$identity" || -L "$available/essence-acme-$identity" ]]; then
        _cert_site_root "$available/essence-acme-$identity" || return 1
        if _cert_has_consumers "$identity" "$cert_dir" "$conf"; then rc=0; else rc=$?; fi
        ((rc != 2)) || return 1
        ((rc == 0)) || CERT_EFFECTIVE_WEBROOT="$webroot"
    fi
}

_cert_enable_site() {
    local identity="$1" webroot="$2" available="$3" enabled="$4" conf="$5" site link tmp
    site="$available/essence-acme-$identity" link="$enabled/essence-acme-$identity"
    if [[ -e "$site" || -L "$site" ]]; then _cert_site_root "$site" || return 1; fi
    if [[ -e "$link" || -L "$link" ]]; then
        [[ -L "$link" && "$(readlink "$link")" == "$site" ]] || return 1
    fi
    # HTTP workers must traverse newly created roots/parents. Do not chmod an
    # existing decoy root; transaction and key directories stay private.
    (umask 022; mkdir -p "$webroot" "$available" "$enabled") || return 1
    tmp=$(umask 077; mktemp "$available/.essence-acme.XXXXXX") || return 1
    if ! printf '%s\n' "# Essence ACME challenge" "server {" "    listen 80;" \
        "    server_name $identity;" "    location /.well-known/acme-challenge/ {" \
        "        root $webroot;" "    }" \
        '    location / { return 301 https://$host$request_uri; }' "}" > "$tmp" ||
       ! chmod 644 "$tmp" || ! mv -f "$tmp" "$site"; then
        rm -f "$tmp"
        return 1
    fi
    [[ -L "$link" ]] || ln -s "$site" "$link" || return 1
    nginx -t -c "$conf" >/dev/null 2>&1 || return 1
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl start nginx
    fi
}

# Generic transaction snapshots preserve symbolic links and unrelated files.
_cert_snapshot() {
    local path="$1" slot="$2"
    if [[ -e "$path" || -L "$path" ]]; then
        cp -pR "$path" "$slot" || return 1
    else
        : > "$slot.absent" || return 1
    fi
}

_cert_restore_snapshot() {
    local path="$1" slot="$2"
    if [[ -e "$slot" || -L "$slot" ]]; then
        rm -rf "$path" && mkdir -p "${path%/*}" && cp -pR "$slot" "$path"
    elif [[ -e "$slot.absent" ]]; then
        rm -rf "$path"
    else
        return 1
    fi
}

_cert_snapshot_registrations() {
    local identity="$1" tx="$2" family dir
    for family in ecc rsa; do
        dir="$HOME/.acme.sh/$identity"
        [[ "$family" != ecc ]] || dir="${dir}_ecc"
        _cert_snapshot "$dir/$identity.conf" "$tx/$family.active" &&
        _cert_snapshot "$dir/$identity.conf.removed" "$tx/$family.removed" || return 1
    done
}

_cert_restore_registrations() {
    local identity="$1" tx="$2" family dir failed=false
    for family in ecc rsa; do
        dir="$HOME/.acme.sh/$identity"
        [[ "$family" != ecc ]] || dir="${dir}_ecc"
        if [[ -e "$tx/$family.active.absent" && -e "$tx/$family.removed.absent" ]]; then
            # An order may have created metadata. Retain it, but disable cron.
            if [[ -e "$dir/$identity.conf" ]]; then
                if [[ -e "$dir/$identity.conf.removed" ]]; then failed=true
                else mv "$dir/$identity.conf" "$dir/$identity.conf.removed" || failed=true; fi
            fi
        else
            _cert_restore_snapshot "$dir/$identity.conf" "$tx/$family.active" || failed=true
            _cert_restore_snapshot "$dir/$identity.conf.removed" "$tx/$family.removed" || failed=true
        fi
    done
    [[ "$failed" == false ]]
}

_cert_activate() {
    local file="$1"
    if [[ "$file" == *.conf.removed ]]; then
        [[ ! -e "${file%.removed}" ]] && mv "$file" "${file%.removed}" || return 1
        file="${file%.removed}"
    fi
    CERT_ACTIVE_CONFIG="$file"
}

# No issuance/install operation is permitted in either rollback helper.
_cert_pause_registration() (
    local identity="${1:-}" tx="" ok=false i file family acme="$HOME/.acme.sh/acme.sh"
    _cert_identity_valid "$identity" || return 1
    _cert_safe_path "$HOME/.acme.sh" || return 1
    _cert_registrations "$identity" || return 1
    umask 077
    tx=$(mktemp -d "${TMPDIR:-/tmp}/essence-cert-pause.XXXXXX") || return 1
    _cert_snapshot_registrations "$identity" "$tx" || { rm -rf "$tx"; return 1; }
    trap 'if [[ "$ok" != true ]]; then _cert_restore_registrations "$identity" "$tx" || warn "Не удалось восстановить регистрацию сертификата."; fi; rm -rf "$tx"' EXIT
    for ((i=0; i<${#CERT_REG_FILES[@]}; i++)); do
        file="${CERT_REG_FILES[$i]}" family="${CERT_REG_FAMILIES[$i]}"
        [[ "$file" != *.removed ]] || continue
        if [[ -x "$acme" ]]; then
            local args=(--remove -d "$identity")
            if [[ "$family" == ecc ]]; then args+=(--ecc); else args+=(--keylength "${CERT_REG_LENGTHS[$i]}"); fi
            "$acme" "${args[@]}" || return 1
            [[ ! -e "$file" && -f "$file.removed" ]] || return 1
        else
            [[ ! -e "$file.removed" ]] && mv "$file" "$file.removed" || return 1
        fi
    done
    ok=true
)

_cert_renewal_metadata() {
    local identity="$1" webroot="$2" dest="$3" index="$4" file
    file="${CERT_REG_FILES[$index]}"
    _cert_activate "$file" || return 1
    CERT_REG_FILES[$index]="$CERT_ACTIVE_CONFIG"
    _cert_registration_valid "$CERT_ACTIVE_CONFIG" "$identity" "${CERT_REG_FAMILIES[$index]}" || return 1
    _cert_write_metadata "$CERT_ACTIVE_CONFIG" "$webroot" "$dest"
}

_cert_resume_registration() (
    local identity="${1:-}" webroot="${2:-}" cert_dir="${3:-/etc/nginx/ssl}"
    local available="${4:-/etc/nginx/sites-available}" enabled="${5:-/etc/nginx/sites-enabled}"
    local conf="${6:-/etc/nginx/nginx.conf}" is_ip=false tx="" ok=false i
    _cert_identity_valid "$identity" || return 1
    local path
    for path in "$webroot" "$cert_dir" "$available" "$enabled" "$conf" "$HOME/.acme.sh"; do _cert_safe_path "$path" || return 1; done
    [[ "$identity" != *:* && ! "$identity" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || is_ip=true
    cert_is_usable "$identity" "$cert_dir/$identity/fullchain.pem" "$cert_dir/$identity/privkey.pem" "$is_ip" || return 1
    _cert_registrations "$identity" && [[ ${#CERT_REG_FILES[@]} -gt 0 ]] || return 1
    _cert_effective_root "$identity" "$webroot" "$available" "$cert_dir" "$conf" || return 1
    webroot="$CERT_EFFECTIVE_WEBROOT"
    umask 077
    tx=$(mktemp -d "${TMPDIR:-/tmp}/essence-cert-resume.XXXXXX") || return 1
    _cert_snapshot_registrations "$identity" "$tx" &&
    _cert_snapshot "$available/essence-acme-$identity" "$tx/site" &&
    _cert_snapshot "$enabled/essence-acme-$identity" "$tx/link" || { rm -rf "$tx"; return 1; }
    trap '
        if [[ "$ok" != true ]]; then
            rollback_failed=false
            _cert_restore_registrations "$identity" "$tx" || rollback_failed=true
            _cert_restore_snapshot "$available/essence-acme-$identity" "$tx/site" || rollback_failed=true
            _cert_restore_snapshot "$enabled/essence-acme-$identity" "$tx/link" || rollback_failed=true
            nginx -t -c "$conf" >/dev/null 2>&1 && systemctl reload nginx || rollback_failed=true
            [[ "$rollback_failed" == false ]] || warn "Не удалось полностью восстановить настройку продления."
        fi
        rm -rf "$tx"
    ' EXIT
    _cert_enable_site "$identity" "$webroot" "$available" "$enabled" "$conf" || return 1
    # Restoring a consumer resumes every family which was previously paused.
    for ((i=0; i<${#CERT_REG_FILES[@]}; i++)); do
        _cert_renewal_metadata "$identity" "$webroot" "$cert_dir/$identity" "$i" || return 1
    done
    nginx -t -c "$conf" >/dev/null 2>&1 && systemctl reload nginx || return 1
    ok=true
)

_cert_choose_material() {
    local identity="$1" dest="$2" is_ip="$3" now="$4" i dir rc installed_leaf="" archive_leaf=""
    local first=-1 matching=-1 installed_pub="" archive_pub=""
    CERT_MATERIAL=none CERT_SELECTED_INDEX=-1
    if cert_is_usable "$identity" "$dest/fullchain.pem" "$dest/privkey.pem" "$is_ip" "$now"; then
        CERT_INSTALLED_STATUS=0
    else
        CERT_INSTALLED_STATUS=$?
    fi
    ((CERT_INSTALLED_STATUS != 2)) || return 2
    _cert_registrations "$identity" || return 1
    if ((CERT_INSTALLED_STATUS == 0 && ${#CERT_REG_FILES[@]} > 0)); then
        CERT_MATERIAL=installed CERT_SELECTED_INDEX=0
        if ((${#CERT_REG_FILES[@]} > 1)); then
            installed_leaf=$(openssl x509 -in "$dest/fullchain.pem" -fingerprint -sha256 -noout 2>/dev/null) || return 1
            installed_pub=$(openssl pkey -in "$dest/privkey.pem" -pubout -passin pass: 2>/dev/null) || return 1
            for ((i=0; i<${#CERT_REG_FILES[@]}; i++)); do
                dir="${CERT_REG_FILES[$i]%/*}"
                archive_leaf=$(openssl x509 -in "$dir/fullchain.cer" -fingerprint -sha256 -noout 2>/dev/null) || continue
                archive_pub=$(openssl pkey -in "$dir/$identity.key" -pubout -passin pass: 2>/dev/null) || continue
                if [[ "$archive_leaf" == "$installed_leaf" && "$archive_pub" == "$installed_pub" ]]; then
                    CERT_SELECTED_INDEX=$i
                    break
                fi
            done
        fi
        return 0
    fi
    if ((CERT_INSTALLED_STATUS == 0)); then
        installed_leaf=$(openssl x509 -in "$dest/fullchain.pem" -fingerprint -sha256 -noout 2>/dev/null) || return 1
        installed_pub=$(openssl pkey -in "$dest/privkey.pem" -pubout -passin pass: 2>/dev/null) || return 1
    fi
    for ((i=0; i<${#CERT_REG_FILES[@]}; i++)); do
        dir="${CERT_REG_FILES[$i]%/*}"
        if cert_is_usable "$identity" "$dir/fullchain.cer" "$dir/$identity.key" "$is_ip" "$now"; then rc=0; else rc=$?; fi
        ((rc != 2)) || return 2
        ((rc == 0)) || continue
        ((first != -1)) || first=$i
        if [[ -n "$installed_leaf" ]]; then
            archive_leaf=$(openssl x509 -in "$dir/fullchain.cer" -fingerprint -sha256 -noout 2>/dev/null) || return 1
            archive_pub=$(openssl pkey -in "$dir/$identity.key" -pubout -passin pass: 2>/dev/null) || return 1
            [[ "$installed_leaf" != "$archive_leaf" || "$installed_pub" != "$archive_pub" ]] || matching=$i
        fi
    done
    if ((first != -1)); then
        CERT_MATERIAL=archive CERT_SELECTED_INDEX=$first
        ((matching == -1)) || CERT_SELECTED_INDEX=$matching
    fi
    return 0
}

# A successful order must prove the issued family's archive, not accidentally
# adopt an unmanaged installed pair merely because registration now exists.
_cert_select_issued_material() {
    local identity="$1" length="$2" is_ip="$3" now="$4" family=rsa i dir
    [[ "$length" != ec-* ]] || family=ecc
    _cert_registrations "$identity" || return 1
    for ((i=0; i<${#CERT_REG_FILES[@]}; i++)); do
        [[ "${CERT_REG_FAMILIES[$i]}" == "$family" ]] || continue
        dir="${CERT_REG_FILES[$i]%/*}"
        cert_is_usable "$identity" "$dir/fullchain.cer" "$dir/$identity.key" "$is_ip" "$now" || return 1
        CERT_MATERIAL=archive CERT_SELECTED_INDEX=$i
        return 0
    done
    return 1
}

_cert_issue_once() {
    local identity="$1" webroot="$2" is_ip="$3" length="$4" force="${5:-false}"
    local args=(--issue -d "$identity" --webroot "$webroot" --server letsencrypt --keylength "$length"
        --pre-hook "ufw allow 80/tcp" --post-hook "ufw deny 80/tcp && systemctl reload nginx")
    [[ "$is_ip" != true ]] || args+=(--certificate-profile shortlived --days 5)
    [[ "$force" != true ]] || args+=(--force)
    "$HOME/.acme.sh/acme.sh" "${args[@]}"
}

_cert_install_archive() {
    local identity="$1" dest="$2" stage="$3" is_ip="$4" now="$5" index="$6" family
    family="${CERT_REG_FAMILIES[$index]}"
    _cert_activate "${CERT_REG_FILES[$index]}" || return 1
    CERT_REG_FILES[$index]="$CERT_ACTIVE_CONFIG"
    local args=(--install-cert -d "$identity" --cert-file "$stage/cert.pem"
        --key-file "$stage/privkey.pem" --fullchain-file "$stage/fullchain.pem" --reloadcmd "")
    if [[ "$family" == ecc ]]; then args+=(--ecc); else args+=(--keylength "${CERT_REG_LENGTHS[$index]}"); fi
    "$HOME/.acme.sh/acme.sh" "${args[@]}" || return 1
    cert_is_usable "$identity" "$stage/fullchain.pem" "$stage/privkey.pem" "$is_ip" "$now" || return 1
    mkdir "$stage/check" && _cert_split_chain "$stage/fullchain.pem" "$stage/check" || return 1
    mkdir "$stage/leaf-check" && _cert_split_chain "$stage/cert.pem" "$stage/leaf-check" || return 1
    [[ ! -e "$stage/leaf-check/chain-2.pem" ]] || return 1
    local leaf staged_leaf
    leaf=$(openssl x509 -in "$stage/check/chain-1.pem" -fingerprint -sha256 -noout 2>/dev/null) || return 1
    staged_leaf=$(openssl x509 -in "$stage/cert.pem" -fingerprint -sha256 -noout 2>/dev/null) || return 1
    [[ "$leaf" == "$staged_leaf" ]] || return 1
    mkdir -p "$dest" || return 1
    local file tmp mode
    for file in cert.pem privkey.pem fullchain.pem; do
        tmp=$(mktemp "$dest/.essence-cert.XXXXXX") || return 1
        mode=644
        [[ "$file" != privkey.pem ]] || mode=600
        if ! cp "$stage/$file" "$tmp" || ! chmod "$mode" "$tmp" || ! mv -f "$tmp" "$dest/$file"; then
            rm -f "$tmp"
            return 1
        fi
    done
}

_cert_ensure_rollback() {
    local identity="$1" tx="$2" dest="$3" available="$4" enabled="$5" conf="$6" failed=false file
    for file in cert.pem privkey.pem fullchain.pem; do
        _cert_restore_snapshot "$dest/$file" "$tx/$file" || failed=true
    done
    if [[ -f "$tx/dest.absent" && -d "$dest" ]]; then rmdir "$dest" 2>/dev/null || :; fi
    _cert_restore_registrations "$identity" "$tx" || failed=true
    _cert_restore_snapshot "$available/essence-acme-$identity" "$tx/site" || failed=true
    _cert_restore_snapshot "$enabled/essence-acme-$identity" "$tx/link" || failed=true
    if [[ -e "$tx/route.changed" ]]; then
        nginx -t -c "$conf" >/dev/null 2>&1 && systemctl reload nginx || failed=true
    fi
    [[ "$failed" == false ]] || { warn "Не удалось полностью восстановить сертификат и настройку продления."; return 1; }
}

# Sole acquire/install/renew owner. Account/email preparation remains with the
# caller. Every error restores installed files, registrations and shared route.
ensure_cert() (
    local identity="${1:-}" webroot="${2:-}" is_ip="${3:-false}" cert_dir="${4:-/etc/nginx/ssl}"
    local available="${5:-/etc/nginx/sites-available}" enabled="${6:-/etc/nginx/sites-enabled}"
    local conf="${7:-/etc/nginx/nginx.conf}" dest tx="" now path file ok=false firewall=false
    local index length=ec-256 rc issued=false message i unmanaged_usable=false
    _cert_identity_valid "$identity" || { warn "Некорректное имя сертификата."; return 1; }
    for path in "$webroot" "$cert_dir" "$available" "$enabled" "$conf" "$HOME/.acme.sh"; do
        _cert_safe_path "$path" || { warn "Небезопасный путь сертификата."; return 1; }
    done
    [[ "$is_ip" == true || "$is_ip" == false ]] || return 1
    _cert_prerequisites || { warn "Нужны OpenSSL ≥1.1.1 и доступное хранилище доверенных CA."; return 2; }
    [[ -x "$HOME/.acme.sh/acme.sh" ]] || { warn "acme.sh не установлен."; return 1; }
    dest="$cert_dir/$identity"
    [[ ! -L "$dest" ]] || return 1
    now=$(date +%s) || return 1
    _cert_choose_material "$identity" "$dest" "$is_ip" "$now" || { warn "Не удалось проверить регистрацию сертификата."; return 1; }
    if [[ "$CERT_MATERIAL" == none && "$CERT_INSTALLED_STATUS" == 0 ]]; then unmanaged_usable=true; fi
    _cert_effective_root "$identity" "$webroot" "$available" "$cert_dir" "$conf" || {
        warn "Не удалось определить общий HTTP-01 маршрут."; return 1;
    }
    webroot="$CERT_EFFECTIVE_WEBROOT"
    umask 077
    tx=$(mktemp -d "${TMPDIR:-/tmp}/essence-cert-install.XXXXXX") || return 1
    _cert_snapshot_registrations "$identity" "$tx" &&
    _cert_snapshot "$available/essence-acme-$identity" "$tx/site" &&
    _cert_snapshot "$enabled/essence-acme-$identity" "$tx/link" || { rm -rf "$tx"; return 1; }
    for file in cert.pem privkey.pem fullchain.pem; do
        _cert_snapshot "$dest/$file" "$tx/$file" || { rm -rf "$tx"; return 1; }
    done
    [[ -d "$dest" ]] || : > "$tx/dest.absent"
    trap 'if [[ "$firewall" == true ]]; then ufw deny 80/tcp >/dev/null || warn "Не удалось закрыть порт HTTP-01."; fi; if [[ "$ok" != true ]]; then _cert_ensure_rollback "$identity" "$tx" "$dest" "$available" "$enabled" "$conf"; fi; rm -rf "$tx"' EXIT
    if [[ "$CERT_MATERIAL" == none ]]; then
        if ((${#CERT_REG_FILES[@]} > 0)); then
            length="${CERT_REG_LENGTHS[0]}"
            _cert_activate "${CERT_REG_FILES[0]}" || return 1
        fi
        : > "$tx/route.changed" || return 1
        _cert_enable_site "$identity" "$webroot" "$available" "$enabled" "$conf" || {
            warn "Не удалось включить HTTP-01 маршрут."; return 1;
        }
        ufw allow 80/tcp >/dev/null || return 1
        firewall=true
        if _cert_issue_once "$identity" "$webroot" "$is_ip" "$length"; then rc=0; else rc=$?; fi
        if ((rc != 0 && rc != 2)); then
            warn "Не удалось получить сертификат; повторная выдача не выполняется."
            return 1
        fi
        if ((rc == 0)); then
            issued=true
            _cert_select_issued_material "$identity" "$length" "$is_ip" "$now" || {
                warn "Полученный сертификат непригоден."; return 1;
            }
        else
            _cert_choose_material "$identity" "$dest" "$is_ip" "$now" || return 1
        fi
        if [[ "$CERT_MATERIAL" == none ]]; then
            if [[ "$rc" == 2 && "$CERT_INSTALLED_STATUS" == 1 && "$unmanaged_usable" == false ]]; then
                warn "Пригодного сертификата нет; выполняется однократная принудительная выдача."
                _cert_issue_once "$identity" "$webroot" "$is_ip" "$length" true || return 1
                issued=true
                _cert_select_issued_material "$identity" "$length" "$is_ip" "$now" || {
                    warn "Полученный сертификат непригоден."; return 1;
                }
            else
                warn "ACME не предоставил пригодный управляемый сертификат."
                return 1
            fi
        fi
        ufw deny 80/tcp >/dev/null || return 1
        firewall=false
    fi
    index="$CERT_SELECTED_INDEX"
    if [[ "$CERT_MATERIAL" == archive ]]; then
        mkdir "$tx/stage" || return 1
        _cert_install_archive "$identity" "$dest" "$tx/stage" "$is_ip" "$now" "$index" || {
            warn "Не удалось установить проверенный сертификат."; return 1;
        }
        message="Сертификат восстановлен из acme.sh."
    else
        message="Используется установленный сертификат."
    fi
    cert_is_usable "$identity" "$dest/fullchain.pem" "$dest/privkey.pem" "$is_ip" "$now" || return 1
    : > "$tx/route.changed" || return 1
    _cert_enable_site "$identity" "$webroot" "$available" "$enabled" "$conf" || return 1
    _cert_renewal_metadata "$identity" "$webroot" "$dest" "$index" || {
        warn "Не удалось сохранить настройку продления."; return 1;
    }
    for ((i=0; i<${#CERT_REG_FILES[@]}; i++)); do
        [[ "$i" == "$index" || "${CERT_REG_FILES[$i]}" == *.removed ]] && continue
        _cert_write_metadata "${CERT_REG_FILES[$i]}" "$webroot" "$dest" || return 1
    done
    nginx -t -c "$conf" >/dev/null 2>&1 && systemctl reload nginx || return 1
    ok=true
    [[ "$issued" != true ]] || message="Выдан новый сертификат."
    success "$message"
)

release_cert() (
    local identity="${1:-}" webroot="${2:-}" cert_dir="${3:-/etc/nginx/ssl}"
    local available="${4:-/etc/nginx/sites-available}" enabled="${5:-/etc/nginx/sites-enabled}"
    local conf="${6:-/etc/nginx/nginx.conf}" path rc tx="" ok=false site link root remove_route=true site_text
    _cert_identity_valid "$identity" || return 1
    for path in "$webroot" "$cert_dir" "$available" "$enabled" "$conf" "$HOME/.acme.sh"; do
        _cert_safe_path "$path" || return 1
    done
    _cert_registrations "$identity" || { warn "Повреждена регистрация сертификата."; return 1; }
    if _cert_has_consumers "$identity" "$cert_dir" "$conf"; then rc=0; else rc=$?; fi
    if ((rc == 0)); then
        info "Сертификат сохранён для другого TLS-потребителя."
        return 0
    elif ((rc != 1)); then
        warn "Не удалось безопасно проверить TLS-потребителей; сертификат сохранён."
        return 1
    fi
    site="$available/essence-acme-$identity" link="$enabled/essence-acme-$identity" root="$webroot"
    if [[ -e "$site" || -L "$site" ]]; then
        site_text=$(cat "$site") || return 1
        if [[ "$site_text" == "# Essence ACME challenge"$'\n'* ]]; then
            _cert_site_root "$site" || { warn "Конфликт общего HTTP-01 сайта."; return 1; }
            root="$CERT_EFFECTIVE_WEBROOT"
        else
            remove_route=false
        fi
    fi
    if [[ "$remove_route" == true && ( -e "$link" || -L "$link" ) ]]; then
        [[ -L "$link" && "$(readlink "$link")" == "$site" ]] || return 1
    fi
    [[ ! -L "$cert_dir/$identity" ]] || return 1
    umask 077
    tx=$(mktemp -d "${TMPDIR:-/tmp}/essence-cert-release.XXXXXX") || return 1
    _cert_snapshot_registrations "$identity" "$tx" &&
    _cert_snapshot "$cert_dir/$identity" "$tx/dest" &&
    _cert_snapshot "$site" "$tx/site" &&
    _cert_snapshot "$link" "$tx/link" &&
    _cert_snapshot "$root" "$tx/root" || { rm -rf "$tx"; return 1; }
    trap '
        if [[ "$ok" != true ]]; then
            rollback_failed=false
            _cert_restore_snapshot "$cert_dir/$identity" "$tx/dest" || rollback_failed=true
            _cert_restore_snapshot "$site" "$tx/site" || rollback_failed=true
            _cert_restore_snapshot "$link" "$tx/link" || rollback_failed=true
            _cert_restore_snapshot "$root" "$tx/root" || rollback_failed=true
            _cert_restore_registrations "$identity" "$tx" || rollback_failed=true
            nginx -t -c "$conf" >/dev/null 2>&1 && systemctl reload nginx || rollback_failed=true
            [[ "$rollback_failed" == false ]] || warn "Не удалось полностью восстановить сертификат после удаления."
        fi
        rm -rf "$tx"
    ' EXIT
    _cert_pause_registration "$identity" || { warn "Не удалось остановить продление сертификата."; return 1; }
    rm -rf "$cert_dir/$identity" "$root" || return 1
    if [[ "$remove_route" == true ]]; then rm -f "$link" "$site" || return 1; fi
    nginx -t -c "$conf" >/dev/null 2>&1 && systemctl reload nginx || return 1
    ok=true
    success "Локальный сертификат удалён; архив acme.sh сохранён, продление остановлено."
)
