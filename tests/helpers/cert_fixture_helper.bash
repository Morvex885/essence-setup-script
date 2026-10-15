#!/bin/bash
# Local-only certificate authority and acme.sh fixtures; compatible with Bash 3.2.
# See function signatures below. No fixture contacts a CA or changes host services.

cert_fixture_date() {
    date -u -r "$1" '+%Y%m%d%H%M%SZ' 2>/dev/null || date -u -d "@$1" '+%Y%m%d%H%M%SZ'
}

# cert_fixture_init <root> [epoch]: exports test trust store and a local EC CA chain.
cert_fixture_init() {
    export CERT_FIXTURE_ROOT="$1" CERT_FIXTURE_EPOCH="${2:-$(date +%s)}"
    export SSL_CERT_FILE="$CERT_FIXTURE_ROOT/root.pem"
    mkdir -p "$CERT_FIXTURE_ROOT/root-db" "$CERT_FIXTURE_ROOT/intermediate-db" || return 1
    : > "$CERT_FIXTURE_ROOT/root-db/index"
    : > "$CERT_FIXTURE_ROOT/intermediate-db/index"
    printf '1000\n' > "$CERT_FIXTURE_ROOT/root-db/serial"
    printf '2000\n' > "$CERT_FIXTURE_ROOT/intermediate-db/serial"
    cat > "$CERT_FIXTURE_ROOT/ca.cnf" <<EOF
[ca]
default_ca = root
[root]
database = $CERT_FIXTURE_ROOT/root-db/index
new_certs_dir = $CERT_FIXTURE_ROOT/root-db
serial = $CERT_FIXTURE_ROOT/root-db/serial
certificate = $CERT_FIXTURE_ROOT/root.pem
private_key = $CERT_FIXTURE_ROOT/root.key
default_md = sha256
policy = permissive
unique_subject = no
[intermediate]
database = $CERT_FIXTURE_ROOT/intermediate-db/index
new_certs_dir = $CERT_FIXTURE_ROOT/intermediate-db
serial = $CERT_FIXTURE_ROOT/intermediate-db/serial
certificate = $CERT_FIXTURE_ROOT/intermediate.pem
private_key = $CERT_FIXTURE_ROOT/intermediate.key
default_md = sha256
policy = permissive
unique_subject = no
[permissive]
commonName = supplied
[ca_extensions]
basicConstraints = critical,CA:true,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
[root_extensions]
basicConstraints = critical,CA:true,pathlen:1
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$CERT_FIXTURE_ROOT/root.key" >/dev/null 2>&1 || return 1
    openssl req -new -key "$CERT_FIXTURE_ROOT/root.key" -subj /CN=Essence-test-root -out "$CERT_FIXTURE_ROOT/root.csr" >/dev/null 2>&1 || return 1
    openssl ca -batch -selfsign -config "$CERT_FIXTURE_ROOT/ca.cnf" -in "$CERT_FIXTURE_ROOT/root.csr" -out "$SSL_CERT_FILE" -notext -extensions root_extensions -startdate "$(cert_fixture_date "$((CERT_FIXTURE_EPOCH - 86400))")" -enddate "$(cert_fixture_date "$((CERT_FIXTURE_EPOCH + 31536000))")" >/dev/null 2>&1 || return 1
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$CERT_FIXTURE_ROOT/intermediate.key" >/dev/null 2>&1 || return 1
    openssl req -new -key "$CERT_FIXTURE_ROOT/intermediate.key" -subj /CN=Essence-test-intermediate -out "$CERT_FIXTURE_ROOT/intermediate.csr" >/dev/null 2>&1 || return 1
    openssl ca -batch -config "$CERT_FIXTURE_ROOT/ca.cnf" -in "$CERT_FIXTURE_ROOT/intermediate.csr" -out "$CERT_FIXTURE_ROOT/intermediate.pem" -notext -extensions ca_extensions -startdate "$(cert_fixture_date "$((CERT_FIXTURE_EPOCH - 86400))")" -enddate "$(cert_fixture_date "$((CERT_FIXTURE_EPOCH + 2592000))")" >/dev/null 2>&1 || return 1
    chmod 600 "$CERT_FIXTURE_ROOT/root.key" "$CERT_FIXTURE_ROOT/intermediate.key"
}

# cert_fixture_intermediate_dates <start_epoch> <end_epoch>: re-signs the same issuer.
# Existing leaf signatures stay valid; only the issuer validity window changes.
cert_fixture_intermediate_dates() {
    openssl ca -batch -config "$CERT_FIXTURE_ROOT/ca.cnf" -in "$CERT_FIXTURE_ROOT/intermediate.csr" -out "$CERT_FIXTURE_ROOT/intermediate.pem" -notext -extensions ca_extensions -startdate "$(cert_fixture_date "$1")" -enddate "$(cert_fixture_date "$2")" >/dev/null 2>&1
}

# cert_fixture_leaf <dest> <CN> [SAN|none] [ecc|rsa] [start_epoch] [end_epoch]
# Produces cert.pem, privkey.pem, chain.pem, fullchain.pem using explicit CA dates.
cert_fixture_leaf() {
    local dest="$1" identity="$2" san="${3:-DNS:$2}" family="${4:-ecc}"
    local start="${5:-$((CERT_FIXTURE_EPOCH - 3600))}" end="${6:-$((CERT_FIXTURE_EPOCH + 604800))}"
    mkdir -p "$dest" || return 1
    if [[ "$family" == rsa ]]; then
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$dest/privkey.pem" >/dev/null 2>&1 || return 1
    else
        openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$dest/privkey.pem" >/dev/null 2>&1 || return 1
    fi
    openssl req -new -key "$dest/privkey.pem" -subj "/CN=$identity" -out "$dest/leaf.csr" >/dev/null 2>&1 || return 1
    cat > "$dest/leaf.cnf" <<EOF
[leaf]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
    [[ "$san" == none ]] || printf 'subjectAltName = %s\n' "$san" >> "$dest/leaf.cnf"
    openssl ca -batch -config "$CERT_FIXTURE_ROOT/ca.cnf" -name intermediate -in "$dest/leaf.csr" -out "$dest/cert.pem" -notext -extfile "$dest/leaf.cnf" -extensions leaf -startdate "$(cert_fixture_date "$start")" -enddate "$(cert_fixture_date "$end")" >/dev/null 2>&1 || return 1
    cp "$CERT_FIXTURE_ROOT/intermediate.pem" "$dest/chain.pem" || return 1
    cat "$dest/cert.pem" "$dest/chain.pem" > "$dest/fullchain.pem" || return 1
    chmod 600 "$dest/privkey.pem"
}

# cert_fixture_archive <identity> <fixture> [ecc|rsa] [active|removed]
cert_fixture_archive() {
    local identity="$1" fixture="$2" family="${3:-ecc}" state="${4:-active}" suffix="" keylength=2048 file dir
    [[ "$family" != ecc ]] || { suffix=_ecc; keylength=ec-256; }
    dir="$HOME/.acme.sh/$identity$suffix"
    mkdir -p "$dir" || return 1
    cp "$fixture/cert.pem" "$dir/$identity.cer" && cp "$fixture/fullchain.pem" "$dir/fullchain.cer" && cp "$fixture/privkey.pem" "$dir/$identity.key" || return 1
    file="$dir/$identity.conf"
    [[ "$state" != removed ]] || file="$file.removed"
    printf "Le_Domain='%s'\nLe_Keylength='%s'\nLe_Webroot='%s'\nUNRELATED='retained metadata'\n" "$identity" "$keylength" "${CERT_TEST_WEBROOT:-/tmp/essence-fixture-webroot}" > "$file"
}

# cert_fixture_installed <cert_root> <identity> <fixture>
cert_fixture_installed() {
    mkdir -p "$1/$2" && cp "$3/cert.pem" "$3/privkey.pem" "$3/fullchain.pem" "$1/$2/"
}

# cert_fixture_fake_acme: fake client driven by FAKE_ACME_SOURCE and status/failure env.
# ACME_ORDER_LOG records only successful-to-start issuance attempts, not installs/removes.
cert_fixture_fake_acme() {
    export ACME_ORDER_LOG="$HOME/acme-orders.log" ACME_CALL_LOG="$HOME/acme-calls.log"
    mkdir -p "$HOME/.acme.sh" || return 1
    : > "$ACME_ORDER_LOG"
    : > "$ACME_CALL_LOG"
    cat > "$HOME/.acme.sh/acme.sh" <<'FAKE'
#!/bin/bash
printf '%s ' "$@" >> "$ACME_CALL_LOG"
printf '\n' >> "$ACME_CALL_LOG"
operation="$1"; shift
identity= family=rsa length=2048 forced=false cert= key= fullchain= reload= webroot=
while (( $# )); do
    case "$1" in
        -d) identity="$2"; shift ;;
        --ecc) family=ecc; length=ec-256 ;;
        --keylength) length="$2"; case "$length" in ec-*) family=ecc ;; *) family=rsa ;; esac; shift ;;
        --force) forced=true ;;
        --cert-file) cert="$2"; shift ;;
        --key-file) key="$2"; shift ;;
        --fullchain-file) fullchain="$2"; shift ;;
        --reloadcmd) reload="$2"; shift ;;
        --webroot) webroot="$2"; shift ;;
    esac
    shift
done
suffix=; [[ "$family" != ecc ]] || suffix=_ecc
dir="$HOME/.acme.sh/$identity$suffix"; conf="$dir/$identity.conf"
set_field() {
    local name="$1" value="$2" line
    : > "$conf.tmp"
    if [[ -f "$conf" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == "$name="* ]] || printf '%s\n' "$line" >> "$conf.tmp"
        done < "$conf"
    fi
    printf "%s='%s'\n" "$name" "$value" >> "$conf.tmp"
    mv "$conf.tmp" "$conf"
}
read_field() {
    local requested="$1" line assignment_pattern="^([A-Za-z_][A-Za-z0-9_]*)='([^']*)'$"
    FAKE_CONF_VALUE=
    [[ -f "$conf" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $assignment_pattern && "${BASH_REMATCH[1]}" == "$requested" ]]; then
            FAKE_CONF_VALUE="${BASH_REMATCH[2]}"
            return 0
        fi
    done < "$conf"
    return 1
}
case "$operation" in
    --issue)
        kind=normal; [[ "$forced" != true ]] || kind=force
        printf '%s %s %s %s\n' "$kind" "$family" "$identity" "$length" >> "$ACME_ORDER_LOG"
        status="${FAKE_ACME_ISSUE_STATUS:-0}"
        [[ "$forced" != true ]] || status="${FAKE_ACME_FORCE_STATUS:-0}"
        if [[ "$status" == 0 || ( "$status" == 2 && "${FAKE_ACME_SKIP_PUBLISH:-false}" == true ) ]]; then
            mkdir -p "$dir" || exit 1
            set_field Le_Domain "$identity" || exit 1
            set_field Le_Keylength "$length" || exit 1
            set_field Le_Webroot "$webroot" || exit 1
            cp "$FAKE_ACME_SOURCE/cert.pem" "$dir/$identity.cer" && cp "$FAKE_ACME_SOURCE/privkey.pem" "$dir/$identity.key" && cp "$FAKE_ACME_SOURCE/fullchain.pem" "$dir/fullchain.cer" || exit 1
            [[ "${FAKE_ACME_CORRUPT_ISSUE:-false}" != true ]] || printf 'invalid PEM\n' > "$dir/fullchain.cer"
        fi
        exit "$status" ;;
    --install-cert)
        [[ "${FAKE_ACME_INSTALL_FAIL:-false}" != true ]] || exit 1
        [[ -f "$conf" ]] || exit 1
        cp "$dir/$identity.cer" "$cert" && cp "$dir/$identity.key" "$key" && cp "$dir/fullchain.cer" "$fullchain" || exit 1
        set_field Le_RealCertPath "$cert" && set_field Le_RealKeyPath "$key" && set_field Le_RealFullChainPath "$fullchain" && set_field Le_ReloadCmd "$reload" || exit 1
        [[ "${FAKE_ACME_BAD_LEAF:-false}" != true ]] || cp "$SSL_CERT_FILE" "$cert"
        exit 0 ;;
    --renew)
        [[ -f "$conf" ]] || exit 1
        read_field Le_InstallCertSuccessTime; installed_at="$FAKE_CONF_VALUE"
        read_field Le_CertCreateTime; created_at="$FAKE_CONF_VALUE"
        # acme.sh retries a pending installation before deciding renewal is not due.
        # This deliberately copies unchecked archive bytes so tests catch unsafe metadata.
        if [[ "$installed_at" =~ ^[0-9]+$ && "$created_at" =~ ^[0-9]+$ ]] && ((installed_at < created_at)); then
            read_field Le_RealCertPath; cert="$FAKE_CONF_VALUE"
            read_field Le_RealKeyPath; key="$FAKE_CONF_VALUE"
            read_field Le_RealFullChainPath; fullchain="$FAKE_CONF_VALUE"
            [[ -z "$cert" ]] || cp "$dir/$identity.cer" "$cert" || exit 1
            [[ -z "$key" ]] || cp "$dir/$identity.key" "$key" || exit 1
            [[ -z "$fullchain" ]] || cp "$dir/fullchain.cer" "$fullchain" || exit 1
            set_field Le_InstallCertSuccessTime "$created_at" || exit 1
        fi
        exit 2 ;;
    --remove)
        [[ "${FAKE_ACME_REMOVE_FAIL:-false}" != true ]] || exit 1
        [[ ! -e "$conf.removed" ]] || exit 1
        mv "$conf" "$conf.removed" ;;
    --set-default-ca|--register-account|--update-account) exit 0 ;;
    *) exit 1 ;;
esac
FAKE
    chmod 700 "$HOME/.acme.sh/acme.sh"
    export ACME="$HOME/.acme.sh/acme.sh"
    mkdir -p "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory"
    printf "ACCOUNT_URL='https://example.invalid/local-account'\nCA_EMAIL='test@example.test'\n" > "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf"
}

# cert_fixture_runtime <root>: isolated nginx/systemctl/UFW commands and API paths.
# NG... dump starts with no consumers. Tests append literal nginx -T directives.
cert_fixture_runtime() {
    export CERT_TEST_CERT_DIR="$1/ssl" CERT_TEST_AVAILABLE="$1/sites-available" CERT_TEST_ENABLED="$1/sites-enabled"
    export CERT_TEST_NGINX_CONF="$1/nginx.conf" CERT_TEST_WEBROOT="$1/webroot"
    export CERT_TEST_NGINX_DUMP="$1/nginx.dump" CERT_TEST_SERVICE_LOG="$1/services.log"
    mkdir -p "$1/bin" "$CERT_TEST_CERT_DIR" "$CERT_TEST_AVAILABLE" "$CERT_TEST_ENABLED" "$CERT_TEST_WEBROOT" || return 1
    : > "$CERT_TEST_SERVICE_LOG"
    printf 'events {}\nhttp { server { listen 80 default_server; server_name _; return 404; } }\n' > "$CERT_TEST_NGINX_CONF"
    cp "$CERT_TEST_NGINX_CONF" "$CERT_TEST_NGINX_DUMP" || return 1
    cat > "$1/bin/nginx" <<'FAKE'
#!/bin/bash
printf 'nginx %s\n' "$*" >> "$CERT_TEST_SERVICE_LOG"
case " $* " in
    *' -T '*) [[ "${CERT_TEST_NGINX_DUMP_FAIL:-false}" != true ]] || exit 1; cat "$CERT_TEST_NGINX_DUMP" ;;
    *' -t '*) [[ "${CERT_TEST_NGINX_TEST_FAIL:-false}" != true ]] ;;
    *' -v '*) printf 'nginx version: nginx/1.24.0\n' >&2 ;;
    *) exit 0 ;;
esac
FAKE
    cat > "$1/bin/systemctl" <<'FAKE'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "$CERT_TEST_SERVICE_LOG"
case " $* " in
    *' reload '*)
        if [[ "${CERT_TEST_RELOAD_FAIL:-false}" == true ]]; then exit 1; fi
        if [[ -n "${CERT_TEST_RELOAD_FAIL_ONCE:-}" && ! -f "$CERT_TEST_RELOAD_FAIL_ONCE" ]]; then touch "$CERT_TEST_RELOAD_FAIL_ONCE"; exit 1; fi ;;
esac
exit 0
FAKE
    cat > "$1/bin/ufw" <<'FAKE'
#!/bin/bash
printf 'ufw %s\n' "$*" >> "$CERT_TEST_SERVICE_LOG"
exit 0
FAKE
    chmod 700 "$1/bin/nginx" "$1/bin/systemctl" "$1/bin/ufw"
    export PATH="$1/bin:$PATH"
}
