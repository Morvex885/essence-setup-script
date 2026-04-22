#!/bin/bash
# ─── Общие функции для работы с acme.sh и TLS-сертификатами ─────────────────

ACME=~/.acme.sh/acme.sh

ensure_acme_installed() {
    local email="$1"
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl -s https://get.acme.sh | sh -s email="$email"
    else
        info "acme.sh уже установлен"
    fi
    ACME=~/.acme.sh/acme.sh
    $ACME --set-default-ca --server letsencrypt
}

# issue_cert <domain> <webroot> [is_ip]
# Получает сертификат через acme.sh (HTTP-01 webroot).
# is_ip="true" → shortlived профиль для IP-сертификатов.
issue_cert() {
    local domain="$1" webroot="$2" is_ip="${3:-false}"

    ufw allow 80/tcp > /dev/null

    if [[ "$is_ip" == "true" ]]; then
        $ACME --issue \
            -d "$domain" \
            --webroot "$webroot" \
            --server letsencrypt \
            --certificate-profile shortlived \
            --days 5 \
            --pre-hook  "ufw allow 80/tcp" \
            --post-hook "ufw deny 80/tcp && systemctl reload nginx" \
            --force || {
                ufw deny 80/tcp > /dev/null
                error "Не удалось получить IP-сертификат. Проверьте доступность порта 80."
            }
    else
        $ACME --issue \
            -d "$domain" \
            --webroot "$webroot" \
            --pre-hook  "ufw allow 80/tcp" \
            --post-hook "ufw deny 80/tcp && systemctl reload nginx" \
            --force || {
                ufw deny 80/tcp > /dev/null
                error "Не удалось получить сертификат. Проверьте DNS и доступность порта 80."
            }
    fi

    ufw deny 80/tcp > /dev/null
}

# install_cert <domain> [reload_cmd]
# Устанавливает сертификат в /etc/nginx/ssl/<domain>/.
install_cert() {
    local domain="$1" reload_cmd="${2:-systemctl reload nginx}"

    mkdir -p /etc/nginx/ssl/"$domain"
    $ACME --install-cert \
        -d "$domain" \
        --cert-file      /etc/nginx/ssl/"$domain"/cert.pem \
        --key-file       /etc/nginx/ssl/"$domain"/privkey.pem \
        --fullchain-file /etc/nginx/ssl/"$domain"/fullchain.pem \
        --reloadcmd      "$reload_cmd"
}
