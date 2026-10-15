#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    load '../helpers/cert_fixture_helper'
    setup_test_env
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    source_common
    source "$PROJECT_ROOT/common/cert.sh"
    cert_fixture_init "$BATS_TEST_TMPDIR/pki"
    cert_fixture_leaf "$BATS_TEST_TMPDIR/good" web.example.test
    cert_fixture_runtime "$BATS_TEST_TMPDIR/runtime"
    cert_fixture_fake_acme
    export FAKE_ACME_SOURCE="$BATS_TEST_TMPDIR/good"
    ID=web.example.test
    GOOD="$BATS_TEST_TMPDIR/good"
    INSTALLED="$CERT_TEST_CERT_DIR/$ID"
    ECC="$HOME/.acme.sh/${ID}_ecc"
    RSA="$HOME/.acme.sh/$ID"
}

teardown() { teardown_test_env; }

ensure_test_cert() {
    ensure_cert "${1:-$ID}" "${2:-$CERT_TEST_WEBROOT}" "${3:-false}" "$CERT_TEST_CERT_DIR" "$CERT_TEST_AVAILABLE" "$CERT_TEST_ENABLED" "$CERT_TEST_NGINX_CONF"
}

release_test_cert() {
    release_cert "$ID" "$CERT_TEST_WEBROOT" "$CERT_TEST_CERT_DIR" "$CERT_TEST_AVAILABLE" "$CERT_TEST_ENABLED" "$CERT_TEST_NGINX_CONF"
}

assert_pair_matches() {
    cmp "$1/fullchain.pem" "$2/fullchain.pem"
    cmp "$1/privkey.pem" "$2/privkey.pem"
}

assert_final_registration() {
    local file="$1" field expected
    for field in Le_RealCertPath Le_RealKeyPath Le_RealFullChainPath; do
        case "$field" in
            Le_RealCertPath) expected="$INSTALLED/cert.pem" ;;
            Le_RealKeyPath) expected="$INSTALLED/privkey.pem" ;;
            Le_RealFullChainPath) expected="$INSTALLED/fullchain.pem" ;;
        esac
        _acme_conf_value "$file" "$field"
        [ "$ACME_CONF_VALUE" = "$expected" ]
    done
    _acme_conf_value "$file" Le_RealCACertPath
    [ -z "$ACME_CONF_VALUE" ]
    _acme_conf_value "$file" Le_ReloadCmd
    [ "$ACME_CONF_VALUE" = 'systemctl reload nginx' ]
    _acme_conf_value "$file" Le_Webroot
    [ "$ACME_CONF_VALUE" = "$CERT_TEST_WEBROOT" ]
    _acme_conf_value "$file" Le_PreHook
    [ "$ACME_CONF_VALUE" = 'ufw allow 80/tcp' ]
    _acme_conf_value "$file" Le_PostHook
    [ "$ACME_CONF_VALUE" = 'ufw deny 80/tcp && systemctl reload nginx' ]
}

@test "managed installed pair is byte-identical and renews even with a corrupt archive" {
    cert_fixture_archive "$ID" "$GOOD"
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$GOOD"
    printf 'broken archive\n' > "$ECC/fullchain.cer"
    printf 'decoy content\n' > "$CERT_TEST_WEBROOT/index.html"
    run ensure_test_cert
    assert_success
    assert_pair_matches "$GOOD" "$INSTALLED"
    [ ! -s "$ACME_ORDER_LOG" ]
    assert_final_registration "$ECC/$ID.conf"
    [ "$(cat "$CERT_TEST_WEBROOT/index.html")" = 'decoy content' ]
    [ -L "$CERT_TEST_ENABLED/essence-acme-$ID" ]
    run cat "$ACME_CALL_LOG"
    refute_output --partial --install-cert
}

@test "removed ECC archive restores a trusted pair with final renewal destinations and no order" {
    cert_fixture_archive "$ID" "$GOOD" ecc removed
    ensure_test_cert
    [ -f "$ECC/$ID.conf" ]
    [ ! -e "$ECC/$ID.conf.removed" ]
    cert_is_usable "$ID" "$INSTALLED/fullchain.pem" "$INSTALLED/privkey.pem"
    assert_pair_matches "$GOOD" "$INSTALLED"
    assert_final_registration "$ECC/$ID.conf"
    [ ! -s "$ACME_ORDER_LOG" ]
    run cat "$ACME_CALL_LOG"
    assert_output --partial --ecc
    if [[ "$(uname -s)" == Darwin ]]; then
        [ "$(stat -f '%Lp' "$INSTALLED/privkey.pem")" = 600 ]
    else
        [ "$(stat -c '%a' "$INSTALLED/privkey.pem")" = 600 ]
    fi
}

@test "RSA restoration explicitly avoids ECC when both storage directories exist" {
    cert_fixture_leaf "$BATS_TEST_TMPDIR/rsa-good" "$ID" "DNS:$ID" rsa
    cert_fixture_archive "$ID" "$BATS_TEST_TMPDIR/rsa-good" rsa removed
    mkdir -p "$ECC"
    ensure_test_cert
    assert_pair_matches "$BATS_TEST_TMPDIR/rsa-good" "$INSTALLED"
    [ -f "$RSA/$ID.conf" ]
    [ ! -e "$RSA/$ID.conf.removed" ]
    [ ! -s "$ACME_ORDER_LOG" ]
    run cat "$ACME_CALL_LOG"
    refute_output --partial --ecc
    cert_is_usable "$ID" "$INSTALLED/fullchain.pem" "$INSTALLED/privkey.pem"
}

@test "matching installed family wins over ECC preference and unrelated files survive publication" {
    cert_fixture_leaf "$BATS_TEST_TMPDIR/rsa-good" "$ID" "DNS:$ID" rsa
    cert_fixture_archive "$ID" "$BATS_TEST_TMPDIR/rsa-good" rsa removed
    cert_fixture_archive "$ID" "$GOOD" ecc removed
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$BATS_TEST_TMPDIR/rsa-good"
    printf 'preserve me\n' > "$INSTALLED/unrelated.txt"
    ensure_test_cert
    assert_pair_matches "$BATS_TEST_TMPDIR/rsa-good" "$INSTALLED"
    [ -f "$RSA/$ID.conf" ]
    [ "$(cat "$INSTALLED/unrelated.txt")" = 'preserve me' ]
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "validator supports real EC and RSA keys and rejects mismatched or encrypted private keys" {
    cert_is_usable "$ID" "$GOOD/fullchain.pem" "$GOOD/privkey.pem" false "$CERT_FIXTURE_EPOCH"
    cert_fixture_leaf "$BATS_TEST_TMPDIR/rsa-good" "$ID" "DNS:$ID" rsa
    cert_is_usable "$ID" "$BATS_TEST_TMPDIR/rsa-good/fullchain.pem" "$BATS_TEST_TMPDIR/rsa-good/privkey.pem" false "$CERT_FIXTURE_EPOCH"
    run cert_is_usable "$ID" "$GOOD/fullchain.pem" "$BATS_TEST_TMPDIR/rsa-good/privkey.pem" false "$CERT_FIXTURE_EPOCH"
    assert_failure 1
    openssl pkey -in "$GOOD/privkey.pem" -aes256 -passout pass:secret -out "$BATS_TEST_TMPDIR/encrypted.key"
    run cert_is_usable "$ID" "$GOOD/fullchain.pem" "$BATS_TEST_TMPDIR/encrypted.key" false "$CERT_FIXTURE_EPOCH"
    assert_failure 1
}

@test "SAN is mandatory even when CN matches and a different DNS SAN never matches" {
    local san fixture
    for san in none DNS:other.example.test; do
        fixture="$BATS_TEST_TMPDIR/${san//:/_}"
        cert_fixture_leaf "$fixture" "$ID" "$san"
        run cert_is_usable "$ID" "$fixture/fullchain.pem" "$fixture/privkey.pem" false "$CERT_FIXTURE_EPOCH"
        assert_failure 1
    done
}

@test "DNS wildcard depth and IPv4 identity are delegated to OpenSSL" {
    cert_fixture_leaf "$BATS_TEST_TMPDIR/wildcard" ignored.example.test 'DNS:*.example.test'
    cert_is_usable WEB.EXAMPLE.TEST "$BATS_TEST_TMPDIR/wildcard/fullchain.pem" "$BATS_TEST_TMPDIR/wildcard/privkey.pem" false "$CERT_FIXTURE_EPOCH"
    run cert_is_usable deep.web.example.test "$BATS_TEST_TMPDIR/wildcard/fullchain.pem" "$BATS_TEST_TMPDIR/wildcard/privkey.pem" false "$CERT_FIXTURE_EPOCH"
    assert_failure 1
    cert_fixture_leaf "$BATS_TEST_TMPDIR/ip" 192.0.2.10 IP:192.0.2.10
    cert_is_usable 192.0.2.10 "$BATS_TEST_TMPDIR/ip/fullchain.pem" "$BATS_TEST_TMPDIR/ip/privkey.pem" true "$CERT_FIXTURE_EPOCH"
    run cert_is_usable 192.0.2.11 "$BATS_TEST_TMPDIR/ip/fullchain.pem" "$BATS_TEST_TMPDIR/ip/privkey.pem" true "$CERT_FIXTURE_EPOCH"
    assert_failure 1
    run cert_is_usable 192.0.2.10 "$BATS_TEST_TMPDIR/ip/fullchain.pem" "$BATS_TEST_TMPDIR/ip/privkey.pem" false "$CERT_FIXTURE_EPOCH"
    assert_failure 1
}

@test "validity boundary is strictly more than one day and rejects expired or future leaves" {
    local end start fixture
    start=$((CERT_FIXTURE_EPOCH - 3600))
    for end in "$((CERT_FIXTURE_EPOCH - 1))" "$((CERT_FIXTURE_EPOCH + 86400))" "$((CERT_FIXTURE_EPOCH + 86401))"; do
        fixture="$BATS_TEST_TMPDIR/expiry-$end"
        cert_fixture_leaf "$fixture" "$ID" "DNS:$ID" ecc "$start" "$end"
        run cert_is_usable "$ID" "$fixture/fullchain.pem" "$fixture/privkey.pem" false "$CERT_FIXTURE_EPOCH"
        if (( end == CERT_FIXTURE_EPOCH + 86401 )); then assert_success; else assert_failure 1; fi
    done
    cert_fixture_leaf "$BATS_TEST_TMPDIR/future" "$ID" "DNS:$ID" ecc "$((CERT_FIXTURE_EPOCH + 1))" "$((CERT_FIXTURE_EPOCH + 604800))"
    run cert_is_usable "$ID" "$BATS_TEST_TMPDIR/future/fullchain.pem" "$BATS_TEST_TMPDIR/future/privkey.pem" false "$CERT_FIXTURE_EPOCH"
    assert_failure 1
}

@test "full chain cannot omit intermediates or turn a supplied issuer into a trust anchor" {
    run cert_is_usable "$ID" "$GOOD/cert.pem" "$GOOD/privkey.pem" false "$CERT_FIXTURE_EPOCH"
    assert_failure 1
    cat "$GOOD/fullchain.pem" "$SSL_CERT_FILE" > "$BATS_TEST_TMPDIR/with-root.pem"
    local original_trust="$SSL_CERT_FILE"
    cert_fixture_init "$BATS_TEST_TMPDIR/foreign-pki" "$CERT_FIXTURE_EPOCH"
    run cert_is_usable "$ID" "$BATS_TEST_TMPDIR/with-root.pem" "$GOOD/privkey.pem" false "$CERT_FIXTURE_EPOCH"
    assert_failure 1
    export SSL_CERT_FILE="$original_trust"
    cert_is_usable "$ID" "$BATS_TEST_TMPDIR/with-root.pem" "$GOOD/privkey.pem" false "$CERT_FIXTURE_EPOCH"
}

@test "intermediate validity is checked now and one day ahead as well as leaf validity" {
    local start end file="$BATS_TEST_TMPDIR/changed-chain.pem"
    for end in "$((CERT_FIXTURE_EPOCH - 1))" "$((CERT_FIXTURE_EPOCH + 86400))"; do
        cert_fixture_intermediate_dates "$((CERT_FIXTURE_EPOCH - 3600))" "$end"
        cat "$GOOD/cert.pem" "$CERT_FIXTURE_ROOT/intermediate.pem" > "$file"
        run cert_is_usable "$ID" "$file" "$GOOD/privkey.pem" false "$CERT_FIXTURE_EPOCH"
        assert_failure 1
    done
    cert_fixture_intermediate_dates "$((CERT_FIXTURE_EPOCH + 1))" "$((CERT_FIXTURE_EPOCH + 604800))"
    cat "$GOOD/cert.pem" "$CERT_FIXTURE_ROOT/intermediate.pem" > "$file"
    run cert_is_usable "$ID" "$file" "$GOOD/privkey.pem" false "$CERT_FIXTURE_EPOCH"
    assert_failure 1
    cert_fixture_intermediate_dates "$((CERT_FIXTURE_EPOCH - 3600))" "$((CERT_FIXTURE_EPOCH + 86401))"
    cat "$GOOD/cert.pem" "$CERT_FIXTURE_ROOT/intermediate.pem" > "$file"
    cert_is_usable "$ID" "$file" "$GOOD/privkey.pem" false "$CERT_FIXTURE_EPOCH"
}

@test "malformed PEM blocks anywhere in fullchain are rejected" {
    local file="$BATS_TEST_TMPDIR/malformed.pem"
    printf 'not a certificate\n' > "$file"
    run cert_is_usable "$ID" "$file" "$GOOD/privkey.pem" false "$CERT_FIXTURE_EPOCH"
    assert_failure 1
    cat "$GOOD/fullchain.pem" > "$file"
    printf '\n-----BEGIN CERTIFICATE-----\ntruncated\n' >> "$file"
    run cert_is_usable "$ID" "$file" "$GOOD/privkey.pem" false "$CERT_FIXTURE_EPOCH"
    assert_failure 1
    cat "$GOOD/cert.pem" > "$file"
    printf '\n-----BEGIN CERTIFICATE-----\ninvalid-base64\n-----END CERTIFICATE-----\n' >> "$file"
    run cert_is_usable "$ID" "$file" "$GOOD/privkey.pem" false "$CERT_FIXTURE_EPOCH"
    assert_failure 1
}

@test "missing trust store and unavailable OpenSSL capabilities fail without ACME orders" {
    cert_fixture_archive "$ID" "$GOOD"
    export SSL_CERT_FILE="$BATS_TEST_TMPDIR/missing-trust"
    run cert_is_usable "$ID" "$GOOD/fullchain.pem" "$GOOD/privkey.pem"
    assert_failure 2
    run ensure_test_cert
    assert_failure
    [ ! -s "$ACME_ORDER_LOG" ]
    export SSL_CERT_FILE="$CERT_FIXTURE_ROOT/root.pem"
    openssl() { return 1; }
    run cert_is_usable "$ID" "$GOOD/fullchain.pem" "$GOOD/privkey.pem"
    assert_failure 2
    run ensure_test_cert
    assert_failure
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "invalid installed pair restores a usable managed archive without ordering" {
    cert_fixture_archive "$ID" "$GOOD"
    cert_fixture_leaf "$BATS_TEST_TMPDIR/wrong" "$ID" DNS:wrong.example.test
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$BATS_TEST_TMPDIR/wrong"
    printf retained > "$INSTALLED/unrelated"
    ensure_test_cert
    assert_pair_matches "$GOOD" "$INSTALLED"
    [ "$(cat "$INSTALLED/unrelated")" = retained ]
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "valid unmanaged installed pair makes one normal order for automatic renewal" {
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$GOOD"
    ensure_test_cert
    [ "$(cat "$ACME_ORDER_LOG")" = "normal ecc $ID ec-256" ]
    assert_final_registration "$ECC/$ID.conf"
    cert_is_usable "$ID" "$INSTALLED/fullchain.pem" "$INSTALLED/privkey.pem"
}

@test "valid unmanaged installed pair and skip code never permit force" {
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$GOOD"
    export FAKE_ACME_ISSUE_STATUS=2
    run ensure_test_cert
    assert_failure
    [ "$(cat "$ACME_ORDER_LOG")" = "normal ecc $ID ec-256" ]
    assert_pair_matches "$GOOD" "$INSTALLED"
}

@test "skip with cryptographically unusable copies permits exactly one forced order" {
    cert_fixture_archive "$ID" "$GOOD" ecc removed
    printf invalid > "$ECC/fullchain.cer"
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$GOOD"
    printf invalid > "$INSTALLED/fullchain.pem"
    export FAKE_ACME_ISSUE_STATUS=2
    ensure_test_cert
    [ "$(cat "$ACME_ORDER_LOG")" = "$(printf 'normal ecc %s ec-256\nforce ecc %s ec-256' "$ID" "$ID")" ]
    cert_is_usable "$ID" "$INSTALLED/fullchain.pem" "$INSTALLED/privkey.pem"
    [ ! -e "$ECC/$ID.conf.removed" ]
}

@test "skip publishing a usable managed archive is restored without force" {
    export FAKE_ACME_ISSUE_STATUS=2 FAKE_ACME_SKIP_PUBLISH=true
    ensure_test_cert
    [ "$(cat "$ACME_ORDER_LOG")" = "normal ecc $ID ec-256" ]
    assert_pair_matches "$GOOD" "$INSTALLED"
}

@test "CA challenge and general failures never force and preserve files and removed registration" {
    cert_fixture_archive "$ID" "$GOOD" ecc removed
    printf unusable > "$ECC/fullchain.cer"
    cp "$ECC/$ID.conf.removed" "$BATS_TEST_TMPDIR/original.conf"
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$GOOD"
    printf unusable > "$INSTALLED/fullchain.pem"
    cp -R "$INSTALLED" "$BATS_TEST_TMPDIR/original-pair"
    local code
    for code in 1 3 429; do
        : > "$ACME_ORDER_LOG"
        export FAKE_ACME_ISSUE_STATUS="$code"
        run ensure_test_cert
        assert_failure
        [ "$(cat "$ACME_ORDER_LOG")" = "normal ecc $ID ec-256" ]
        assert_pair_matches "$BATS_TEST_TMPDIR/original-pair" "$INSTALLED"
        cmp "$BATS_TEST_TMPDIR/original.conf" "$ECC/$ID.conf.removed"
        [ ! -e "$ECC/$ID.conf" ]
    done
}

@test "successful status with corrupt material and failed forced issuance cannot report success" {
    export FAKE_ACME_CORRUPT_ISSUE=true
    run ensure_test_cert
    assert_failure
    [ "$(cat "$ACME_ORDER_LOG")" = "normal ecc $ID ec-256" ]
    [ ! -f "$INSTALLED/fullchain.pem" ]
    [ -f "$ECC/$ID.conf.removed" ]
    unset FAKE_ACME_CORRUPT_ISSUE
    : > "$ACME_ORDER_LOG"
    export FAKE_ACME_ISSUE_STATUS=2 FAKE_ACME_FORCE_STATUS=1
    run ensure_test_cert
    assert_failure
    [ "$(cat "$ACME_ORDER_LOG")" = "$(printf 'normal ecc %s ec-256\nforce ecc %s ec-256' "$ID" "$ID")" ]
    [ ! -f "$INSTALLED/fullchain.pem" ]
}

@test "IP orders use shortlived profile while retaining normal-first behavior" {
    cert_fixture_leaf "$BATS_TEST_TMPDIR/ip" 192.0.2.10 IP:192.0.2.10
    export FAKE_ACME_SOURCE="$BATS_TEST_TMPDIR/ip"
    ensure_test_cert 192.0.2.10 "$CERT_TEST_WEBROOT" true
    [ "$(cat "$ACME_ORDER_LOG")" = 'normal ecc 192.0.2.10 ec-256' ]
    run cat "$ACME_CALL_LOG"
    assert_output --partial '--certificate-profile shortlived'
    assert_output --partial '--days 5'
    cert_is_usable 192.0.2.10 "$CERT_TEST_CERT_DIR/192.0.2.10/fullchain.pem" "$CERT_TEST_CERT_DIR/192.0.2.10/privkey.pem" true
}

@test "legacy RSA registration keeps numeric key length during issuance" {
    cert_fixture_leaf "$BATS_TEST_TMPDIR/rsa-good" "$ID" "DNS:$ID" rsa
    cert_fixture_archive "$ID" "$BATS_TEST_TMPDIR/rsa-good" rsa removed
    printf "Le_Domain='%s'\n" "$ID" > "$RSA/$ID.conf.removed"
    printf invalid > "$RSA/fullchain.cer"
    export FAKE_ACME_SOURCE="$BATS_TEST_TMPDIR/rsa-good"
    ensure_test_cert
    [ "$(cat "$ACME_ORDER_LOG")" = "normal rsa $ID 2048" ]
    cert_is_usable "$ID" "$INSTALLED/fullchain.pem" "$INSTALLED/privkey.pem"
}

@test "conflicting registrations and incompatible key length fail before any order" {
    cert_fixture_archive "$ID" "$GOOD" ecc removed
    cp "$ECC/$ID.conf.removed" "$ECC/$ID.conf"
    run ensure_test_cert
    assert_failure
    [ ! -s "$ACME_ORDER_LOG" ]
    rm "$ECC/$ID.conf"
    printf "Le_Domain='%s'\nLe_Keylength='2048'\n" "$ID" > "$ECC/$ID.conf.removed"
    run ensure_test_cert
    assert_failure
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "install failure and staged wrong leaf preserve original installed files and metadata" {
    cert_fixture_leaf "$BATS_TEST_TMPDIR/wrong" "$ID" DNS:wrong.example.test
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$BATS_TEST_TMPDIR/wrong"
    cert_fixture_archive "$ID" "$GOOD" ecc removed
    cp "$ECC/$ID.conf.removed" "$BATS_TEST_TMPDIR/original.conf"
    export FAKE_ACME_INSTALL_FAIL=true
    run ensure_test_cert
    assert_failure
    assert_pair_matches "$BATS_TEST_TMPDIR/wrong" "$INSTALLED"
    cmp "$BATS_TEST_TMPDIR/original.conf" "$ECC/$ID.conf.removed"
    unset FAKE_ACME_INSTALL_FAIL
    export FAKE_ACME_BAD_LEAF=true
    run ensure_test_cert
    assert_failure
    assert_pair_matches "$BATS_TEST_TMPDIR/wrong" "$INSTALLED"
    cmp "$BATS_TEST_TMPDIR/original.conf" "$ECC/$ID.conf.removed"
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "publication rename failure rolls back the old pair without losing unrelated files" {
    cert_fixture_leaf "$BATS_TEST_TMPDIR/wrong" "$ID" DNS:wrong.example.test
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$BATS_TEST_TMPDIR/wrong"
    cert_fixture_archive "$ID" "$GOOD"
    cp "$ECC/$ID.conf" "$BATS_TEST_TMPDIR/original.conf"
    printf keep > "$INSTALLED/unrelated"
    mv() {
        local last="${!#}"
        if [[ "$last" == "$INSTALLED/fullchain.pem" && ! -e "$BATS_TEST_TMPDIR/mv-failed" ]]; then
            touch "$BATS_TEST_TMPDIR/mv-failed"
            return 1
        fi
        command mv "$@"
    }
    run ensure_test_cert
    assert_failure
    [ -f "$BATS_TEST_TMPDIR/mv-failed" ]
    assert_pair_matches "$BATS_TEST_TMPDIR/wrong" "$INSTALLED"
    [ "$(cat "$INSTALLED/unrelated")" = keep ]
    cmp "$BATS_TEST_TMPDIR/original.conf" "$ECC/$ID.conf"
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "renewal metadata write failure never triggers an order or changes installed pair" {
    cert_fixture_archive "$ID" "$GOOD"
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$GOOD"
    cp "$ECC/$ID.conf" "$BATS_TEST_TMPDIR/original.conf"
    mv() {
        local last="${!#}"
        if [[ "$last" == "$ECC/$ID.conf" && ! -e "$BATS_TEST_TMPDIR/metadata-failed" ]]; then
            touch "$BATS_TEST_TMPDIR/metadata-failed"
            return 1
        fi
        command mv "$@"
    }
    run ensure_test_cert
    assert_failure
    [ -f "$BATS_TEST_TMPDIR/metadata-failed" ]
    assert_pair_matches "$GOOD" "$INSTALLED"
    cmp "$BATS_TEST_TMPDIR/original.conf" "$ECC/$ID.conf"
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "reload failure restores installed pair registration and preexisting shared site" {
    cert_fixture_archive "$ID" "$GOOD"
    ensure_test_cert
    cp "$ECC/$ID.conf" "$BATS_TEST_TMPDIR/original.conf"
    cp "$CERT_TEST_AVAILABLE/essence-acme-$ID" "$BATS_TEST_TMPDIR/original.site"
    cert_fixture_leaf "$BATS_TEST_TMPDIR/wrong" "$ID" DNS:wrong.example.test
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$BATS_TEST_TMPDIR/wrong"
    export CERT_TEST_RELOAD_FAIL_ONCE="$BATS_TEST_TMPDIR/reload-failed"
    run ensure_test_cert
    assert_failure
    assert_pair_matches "$BATS_TEST_TMPDIR/wrong" "$INSTALLED"
    cmp "$BATS_TEST_TMPDIR/original.conf" "$ECC/$ID.conf"
    cmp "$BATS_TEST_TMPDIR/original.site" "$CERT_TEST_AVAILABLE/essence-acme-$ID"
    [ -L "$CERT_TEST_ENABLED/essence-acme-$ID" ]
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "successful order followed by failed installation retains issued archive with paused registration" {
    export FAKE_ACME_INSTALL_FAIL=true
    run ensure_test_cert
    assert_failure
    [ "$(cat "$ACME_ORDER_LOG")" = "normal ecc $ID ec-256" ]
    cmp "$GOOD/fullchain.pem" "$ECC/fullchain.cer"
    cmp "$GOOD/privkey.pem" "$ECC/$ID.key"
    [ -f "$ECC/$ID.conf.removed" ]
    [ ! -e "$ECC/$ID.conf" ]
    [ ! -e "$INSTALLED/fullchain.pem" ]
    [ ! -e "$CERT_TEST_AVAILABLE/essence-acme-$ID" ]
    unset FAKE_ACME_INSTALL_FAIL
    : > "$ACME_ORDER_LOG"
    ensure_test_cert
    [ ! -s "$ACME_ORDER_LOG" ]
    cert_is_usable "$ID" "$INSTALLED/fullchain.pem" "$INSTALLED/privkey.pem"
}

@test "unmarked challenge collision and nginx validation failure stop before ACME" {
    printf '# user owned\n' > "$CERT_TEST_AVAILABLE/essence-acme-$ID"
    run ensure_test_cert
    assert_failure
    [ ! -s "$ACME_ORDER_LOG" ]
    [ "$(cat "$CERT_TEST_AVAILABLE/essence-acme-$ID")" = '# user owned' ]
    rm "$CERT_TEST_AVAILABLE/essence-acme-$ID"
    export CERT_TEST_NGINX_TEST_FAIL=true
    run ensure_test_cert
    assert_failure
    [ ! -s "$ACME_ORDER_LOG" ]
    [ ! -e "$CERT_TEST_AVAILABLE/essence-acme-$ID" ]
}

@test "last release pauses both families preserves archive and account and reinstalls without orders" {
    cert_fixture_archive "$ID" "$GOOD"
    cert_fixture_leaf "$BATS_TEST_TMPDIR/rsa-good" "$ID" "DNS:$ID" rsa
    cert_fixture_archive "$ID" "$BATS_TEST_TMPDIR/rsa-good" rsa
    ensure_test_cert
    cp "$ECC/fullchain.cer" "$BATS_TEST_TMPDIR/ecc-chain-before"
    cp "$ECC/$ID.key" "$BATS_TEST_TMPDIR/ecc-key-before"
    cp "$RSA/fullchain.cer" "$BATS_TEST_TMPDIR/rsa-chain-before"
    cp "$RSA/$ID.key" "$BATS_TEST_TMPDIR/rsa-key-before"
    cp "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf" "$BATS_TEST_TMPDIR/account-before"
    mkdir -p "$CERT_TEST_CERT_DIR/other.example.test"
    printf other > "$CERT_TEST_CERT_DIR/other.example.test/untouched"
    printf '# unrelated\n' > "$CERT_TEST_AVAILABLE/other-site"
    release_test_cert
    [ ! -e "$INSTALLED" ]
    [ ! -e "$CERT_TEST_WEBROOT" ]
    [ ! -e "$CERT_TEST_AVAILABLE/essence-acme-$ID" ]
    [ ! -L "$CERT_TEST_ENABLED/essence-acme-$ID" ]
    [ -f "$ECC/$ID.conf.removed" ]
    [ -f "$RSA/$ID.conf.removed" ]
    cmp "$BATS_TEST_TMPDIR/ecc-chain-before" "$ECC/fullchain.cer"
    cmp "$BATS_TEST_TMPDIR/ecc-key-before" "$ECC/$ID.key"
    cmp "$BATS_TEST_TMPDIR/rsa-chain-before" "$RSA/fullchain.cer"
    cmp "$BATS_TEST_TMPDIR/rsa-key-before" "$RSA/$ID.key"
    cmp "$BATS_TEST_TMPDIR/account-before" "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf"
    [ "$(cat "$CERT_TEST_CERT_DIR/other.example.test/untouched")" = other ]
    [ "$(cat "$CERT_TEST_AVAILABLE/other-site")" = '# unrelated' ]
    release_test_cert
    ensure_test_cert
    [ ! -s "$ACME_ORDER_LOG" ]
    [ -f "$ECC/$ID.conf" ]
    [ -L "$CERT_TEST_ENABLED/essence-acme-$ID" ]
    cert_is_usable "$ID" "$INSTALLED/fullchain.pem" "$INSTALLED/privkey.pem"
}

@test "remaining quoted TLS consumer in a different root keeps registration and original challenge root" {
    cert_fixture_archive "$ID" "$GOOD"
    ensure_test_cert
    local original_root="$CERT_TEST_WEBROOT" alternative="$BATS_TEST_TMPDIR/alternative-webroot"
    printf 'ssl_certificate "%s/elsewhere/%s/fullchain.pem";\nssl_certificate_key "%s/elsewhere/%s/privkey.pem";\n' "$BATS_TEST_TMPDIR" "$ID" "$BATS_TEST_TMPDIR" "$ID" > "$CERT_TEST_NGINX_DUMP"
    release_test_cert
    [ -f "$ECC/$ID.conf" ]
    [ -d "$INSTALLED" ]
    [ -d "$original_root" ]
    ensure_test_cert "$ID" "$alternative"
    _acme_conf_value "$ECC/$ID.conf" Le_Webroot
    [ "$ACME_CONF_VALUE" = "$original_root" ]
    [ ! -s "$ACME_ORDER_LOG" ]
    cert_is_usable "$ID" "$INSTALLED/fullchain.pem" "$INSTALLED/privkey.pem"
}

@test "comments and hostname substrings are not consumers but unknown certificate directives retain state" {
    cert_fixture_archive "$ID" "$GOOD"
    ensure_test_cert
    local directive
    for directive in 'ssl_certificate $dynamic_path;' 'ssl_certificate;' 'ssl_certificate /unterminated'; do
        printf '%s\n' "$directive" > "$CERT_TEST_NGINX_DUMP"
        run release_test_cert
        assert_failure
        [ -f "$ECC/$ID.conf" ]
        [ -d "$INSTALLED" ]
        [ -L "$CERT_TEST_ENABLED/essence-acme-$ID" ]
    done
    export CERT_TEST_NGINX_DUMP_FAIL=true
    run release_test_cert
    assert_failure
    [ -f "$ECC/$ID.conf" ]
    [ -d "$INSTALLED" ]
    unset CERT_TEST_NGINX_DUMP_FAIL
    printf '# ssl_certificate %s/fullchain.pem;\nserver_name %s;\nssl_certificate %s/not-%s/fullchain.pem;\n' "$INSTALLED" "$ID" "$CERT_TEST_CERT_DIR" "$ID" > "$CERT_TEST_NGINX_DUMP"
    release_test_cert
    [ ! -e "$INSTALLED" ]
    [ -f "$ECC/$ID.conf.removed" ]
}

@test "missing executable pauses registration by rename without touching archived material" {
    cert_fixture_archive "$ID" "$GOOD"
    ensure_test_cert
    cp "$ECC/fullchain.cer" "$BATS_TEST_TMPDIR/archive-before"
    rm "$HOME/.acme.sh/acme.sh"
    release_test_cert
    [ -f "$ECC/$ID.conf.removed" ]
    [ ! -e "$ECC/$ID.conf" ]
    cmp "$BATS_TEST_TMPDIR/archive-before" "$ECC/fullchain.cer"
    [ ! -e "$INSTALLED" ]
}

@test "failed pause never deletes installed files route or webroot" {
    cert_fixture_archive "$ID" "$GOOD"
    ensure_test_cert
    export FAKE_ACME_REMOVE_FAIL=true
    run release_test_cert
    assert_failure
    [ -f "$ECC/$ID.conf" ]
    assert_pair_matches "$GOOD" "$INSTALLED"
    [ -d "$CERT_TEST_WEBROOT" ]
    [ -L "$CERT_TEST_ENABLED/essence-acme-$ID" ]
}

@test "archive fallback prefers ECC over RSA when no installed pair selects a family" {
    cert_fixture_archive "$ID" "$GOOD" ecc removed
    cert_fixture_leaf "$BATS_TEST_TMPDIR/rsa-good" "$ID" "DNS:$ID" rsa
    cert_fixture_archive "$ID" "$BATS_TEST_TMPDIR/rsa-good" rsa removed
    ensure_test_cert
    assert_pair_matches "$GOOD" "$INSTALLED"
    [ -f "$ECC/$ID.conf" ]
    [ -f "$RSA/$ID.conf.removed" ]
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "staging copy failure restores original files and does not leave active staging metadata" {
    cert_fixture_archive "$ID" "$GOOD" ecc removed
    cert_fixture_leaf "$BATS_TEST_TMPDIR/wrong" "$ID" DNS:wrong.example.test
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$BATS_TEST_TMPDIR/wrong"
    cp "$ECC/$ID.conf.removed" "$BATS_TEST_TMPDIR/original.conf"
    cp() {
        local last="${!#}"
        if [[ "$last" == "$INSTALLED/privkey.pem" && ! -e "$BATS_TEST_TMPDIR/cp-failed" ]]; then
            touch "$BATS_TEST_TMPDIR/cp-failed"
            return 1
        fi
        command cp "$@"
    }
    # A private stage-to-final move is valid too; fail whichever primitive publishes key.
    mv() {
        local last="${!#}"
        if [[ "$last" == "$INSTALLED/privkey.pem" && ! -e "$BATS_TEST_TMPDIR/cp-failed" ]]; then
            touch "$BATS_TEST_TMPDIR/cp-failed"
            return 1
        fi
        command mv "$@"
    }
    run ensure_test_cert
    assert_failure
    [ -f "$BATS_TEST_TMPDIR/cp-failed" ]
    assert_pair_matches "$BATS_TEST_TMPDIR/wrong" "$INSTALLED"
    cmp "$BATS_TEST_TMPDIR/original.conf" "$ECC/$ID.conf.removed"
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "last release never deletes an unmarked shared-site filename" {
    cert_fixture_archive "$ID" "$GOOD"
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$GOOD"
    printf '# user owned\n' > "$CERT_TEST_AVAILABLE/essence-acme-$ID"
    ln -s "$CERT_TEST_AVAILABLE/essence-acme-$ID" "$CERT_TEST_ENABLED/essence-acme-$ID"
    release_test_cert
    [ "$(cat "$CERT_TEST_AVAILABLE/essence-acme-$ID")" = '# user owned' ]
    [ -L "$CERT_TEST_ENABLED/essence-acme-$ID" ]
    [ -f "$ECC/$ID.conf.removed" ]
}

@test "unrelated nginx regex and multiline log format do not retain an unused certificate" {
    cert_fixture_archive "$ID" "$GOOD"
    ensure_test_cert
    cat > "$CERT_TEST_NGINX_DUMP" <<'NGINX'
http {
    log_format main '$remote_addr - $remote_user '
                    '"$request" $status';
    server {
        location ~ \.php$ { return 404; }
    }
}
NGINX
    release_test_cert
    [ ! -e "$INSTALLED" ]
    [ -f "$ECC/$ID.conf.removed" ]
}

@test "ordinary order replaces unmanaged pair and must validate newly issued material" {
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$GOOD"
    cert_fixture_leaf "$BATS_TEST_TMPDIR/replacement" "$ID"
    export FAKE_ACME_SOURCE="$BATS_TEST_TMPDIR/replacement"
    ensure_test_cert
    assert_pair_matches "$BATS_TEST_TMPDIR/replacement" "$INSTALLED"
    [ "$(cat "$ACME_ORDER_LOG")" = "normal ecc $ID ec-256" ]
}

@test "corrupt successful order cannot borrow validity from an unmanaged installed pair" {
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$GOOD"
    export FAKE_ACME_CORRUPT_ISSUE=true
    run ensure_test_cert
    assert_failure
    assert_pair_matches "$GOOD" "$INSTALLED"
    [ "$(cat "$ACME_ORDER_LOG")" = "normal ecc $ID ec-256" ]
    [ -f "$ECC/$ID.conf.removed" ]
}

# Seed the actual acme.sh retry condition: the last installation predates issuance.
# Its renewal path attempts installation before returning the normal not-due code.
seed_pending_install_retry() {
    cert_fixture_archive "$ID" "$GOOD"
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$GOOD"
    printf 'corrupt retained archive\n' > "$ECC/fullchain.cer"
    cat >> "$ECC/$ID.conf" <<EOF
Le_CertCreateTime='$CERT_FIXTURE_EPOCH'
Le_InstallCertSuccessTime='$((CERT_FIXTURE_EPOCH - 100))'
Le_InstallCertSuccessTimeStr='previous install'
Le_RealCertPath='$INSTALLED/cert.pem'
Le_RealKeyPath='$INSTALLED/privkey.pem'
Le_RealFullChainPath='$INSTALLED/fullchain.pem'
EOF
}

@test "installed reuse prevents the next skipped renewal from overwriting trusted files with corrupt archive" {
    seed_pending_install_retry
    cp "$ECC/$ID.conf" "$BATS_TEST_TMPDIR/pending.conf"
    # Demonstrate the consumer-visible hazard without lifecycle reconciliation.
    run "$ACME" --renew -d "$ID" --ecc
    assert_failure 2
    run cert_is_usable "$ID" "$INSTALLED/fullchain.pem" "$INSTALLED/privkey.pem"
    assert_failure 1
    cert_fixture_installed "$CERT_TEST_CERT_DIR" "$ID" "$GOOD"
    cp "$BATS_TEST_TMPDIR/pending.conf" "$ECC/$ID.conf"
    ensure_test_cert
    run "$ACME" --renew -d "$ID" --ecc
    assert_failure 2
    assert_pair_matches "$GOOD" "$INSTALLED"
    cert_is_usable "$ID" "$INSTALLED/fullchain.pem" "$INSTALLED/privkey.pem"
    [ ! -s "$ACME_ORDER_LOG" ]
}

@test "rollback resume prevents pending archive installation before scheduled renewal skip" {
    seed_pending_install_retry
    mv "$ECC/$ID.conf" "$ECC/$ID.conf.removed"
    _cert_resume_registration "$ID" "$CERT_TEST_WEBROOT" "$CERT_TEST_CERT_DIR" "$CERT_TEST_AVAILABLE" "$CERT_TEST_ENABLED" "$CERT_TEST_NGINX_CONF"
    [ -f "$ECC/$ID.conf" ]
    [ ! -e "$ECC/$ID.conf.removed" ]
    run "$ACME" --renew -d "$ID" --ecc
    assert_failure 2
    assert_pair_matches "$GOOD" "$INSTALLED"
    cert_is_usable "$ID" "$INSTALLED/fullchain.pem" "$INSTALLED/privkey.pem"
    [ -L "$CERT_TEST_ENABLED/essence-acme-$ID" ]
    [ ! -s "$ACME_ORDER_LOG" ]
}
