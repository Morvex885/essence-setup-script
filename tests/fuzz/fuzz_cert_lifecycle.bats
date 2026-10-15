#!/usr/bin/env bats

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-100}"

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
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
    cert_fixture_archive web.example.test "$BATS_TEST_TMPDIR/good" ecc removed
    export FAKE_ACME_SOURCE="$BATS_TEST_TMPDIR/good"
    ID=web.example.test
    CONF="$HOME/.acme.sh/${ID}_ecc/$ID.conf.removed"
    cp "$CONF" "$BATS_TEST_TMPDIR/original.conf"
    cp "$HOME/.acme.sh/${ID}_ecc/fullchain.cer" "$BATS_TEST_TMPDIR/original-chain"
    cp "$HOME/.acme.sh/${ID}_ecc/$ID.key" "$BATS_TEST_TMPDIR/original-key"
}

teardown() { teardown_test_env; }

fuzz_ensure() {
    ensure_cert "$1" "$2" false "${3:-$CERT_TEST_CERT_DIR}" "$CERT_TEST_AVAILABLE" "$CERT_TEST_ENABLED" "$CERT_TEST_NGINX_CONF"
}

assert_archive_unchanged() {
    cmp "$BATS_TEST_TMPDIR/original-chain" "$HOME/.acme.sh/${ID}_ecc/fullchain.cer"
    cmp "$BATS_TEST_TMPDIR/original-key" "$HOME/.acme.sh/${ID}_ecc/$ID.key"
    [ ! -e "$HOME/.acme.sh/${ID}_ecc/$ID.conf" ]
    [ ! -s "$ACME_ORDER_LOG" ]
    [ ! -s "$ACME_CALL_LOG" ]
    [ ! -e "$BATS_TEST_TMPDIR/executed" ]
}

@test "mixed-case assignment reader returns literal values without evaluating shell payloads" {
    local file="$BATS_TEST_TMPDIR/parser.conf" token key value i
    for (( i=0; i<FUZZ_ITERATIONS; i++ )); do
        token=$(random_string 12 'abcdefghijklmnopqrstuvwxyz0123456789')
        key="Le_${token}"
        value="literal\$(touch $BATS_TEST_TMPDIR/executed)-$token"
        printf "OTHER='untouched'\n%s='%s'\n" "$key" "$value" > "$file"
        _acme_conf_value "$file" "$key"
        [ "$ACME_CONF_VALUE" = "$value" ]
        [ ! -e "$BATS_TEST_TMPDIR/executed" ]
        run _acme_conf_value "$file" "${key}x"
        assert_failure 1
    done
}

@test "safe lifecycle metadata round-trips atomically and unrelated bytes are preserved" {
    local token root dest file="$BATS_TEST_TMPDIR/metadata.conf" field expected i
    for (( i=0; i<FUZZ_ITERATIONS; i++ )); do
        token=$(random_string 16 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-')
        root="$BATS_TEST_TMPDIR/web/$token"
        dest="$BATS_TEST_TMPDIR/ssl/$token"
        printf "# preserved comment\nLe_Domain='%s'\nLe_Keylength='ec-256'\nUNRELATED='retained %s'\n" "$ID" "$token" > "$file"
        _cert_write_metadata "$file" "$root" "$dest"
        for field in Le_Webroot Le_RealCertPath Le_RealKeyPath Le_RealFullChainPath Le_RealCACertPath Le_PreHook Le_PostHook Le_ReloadCmd; do
            case "$field" in
                Le_Webroot) expected="$root" ;;
                Le_RealCertPath) expected="$dest/cert.pem" ;;
                Le_RealKeyPath) expected="$dest/privkey.pem" ;;
                Le_RealFullChainPath) expected="$dest/fullchain.pem" ;;
                Le_RealCACertPath) expected='' ;;
                Le_PreHook) expected='ufw allow 80/tcp' ;;
                Le_PostHook) expected='ufw deny 80/tcp && systemctl reload nginx' ;;
                Le_ReloadCmd) expected='systemctl reload nginx' ;;
            esac
            _acme_conf_value "$file" "$field"
            [ "$ACME_CONF_VALUE" = "$expected" ]
        done
        _acme_conf_value "$file" UNRELATED
        [ "$ACME_CONF_VALUE" = "retained $token" ]
        _acme_conf_value "$file" Le_Domain
        [ "$ACME_CONF_VALUE" = "$ID" ]
        cp "$file" "$file.before"
        _cert_write_metadata "$file" "$root" "$dest"
        cmp "$file.before" "$file"
        [ ! -e "$BATS_TEST_TMPDIR/executed" ]
    done
}

@test "duplicate or malformed target fields cannot be silently rewritten" {
    local field token file="$BATS_TEST_TMPDIR/metadata.conf" i
    local fields=(Le_Webroot Le_PreHook Le_PostHook Le_RealCertPath Le_RealKeyPath Le_RealCACertPath Le_RealFullChainPath Le_ReloadCmd Le_InstallCertSuccessTime Le_InstallCertSuccessTimeStr)
    for (( i=0; i<FUZZ_ITERATIONS; i++ )); do
        field="${fields[$((i % ${#fields[@]}))]}"
        token=$(random_ascii 12)
        printf "Le_Domain='%s'\n%s='%s'\n%s='%s'\n" "$ID" "$field" "$token" "$field" "$token" > "$file"
        cp "$file" "$file.before"
        _cert_write_metadata "$file" "$CERT_TEST_WEBROOT" "$CERT_TEST_CERT_DIR/$ID" && return 1
        cmp "$file.before" "$file"
        _acme_conf_value "$file" "$field" && return 1
        [ -z "$ACME_CONF_VALUE" ]
        printf 'Le_Domain=\x27%s\x27\n%s=$(touch %s)\n' "$ID" "$field" "$BATS_TEST_TMPDIR/executed" > "$file"
        cp "$file" "$file.before"
        _cert_write_metadata "$file" "$CERT_TEST_WEBROOT" "$CERT_TEST_CERT_DIR/$ID" && return 1
        cmp "$file.before" "$file"
        [ ! -e "$BATS_TEST_TMPDIR/executed" ]
    done
}

@test "injection traversal and control paths fail before metadata archive or ACME writes" {
    local path token i
    local unsafe=(relative / "$BATS_TEST_TMPDIR/../escape" "$BATS_TEST_TMPDIR/a/../../escape" "$BATS_TEST_TMPDIR/a'quote" "$BATS_TEST_TMPDIR/\$(touch executed)" "$BATS_TEST_TMPDIR/\`id\`" "$BATS_TEST_TMPDIR/\${HOME}" "$BATS_TEST_TMPDIR/"$'line\nbreak' "$BATS_TEST_TMPDIR/"$'carriage\rreturn')
    for (( i=0; i<FUZZ_ITERATIONS; i++ )); do
        token=$(random_ascii 10)
        path="${unsafe[$((i % ${#unsafe[@]}))]}"
        # Preserve the absolute-root and relative-path boundary cases verbatim.
        case "$path" in /|relative) ;; *) path="$path/$token" ;; esac
        run fuzz_ensure "$ID" "$path"
        assert_failure
        cmp "$BATS_TEST_TMPDIR/original.conf" "$CONF"
        assert_archive_unchanged
        run fuzz_ensure "$ID" "$CERT_TEST_WEBROOT" "$path"
        assert_failure
        cmp "$BATS_TEST_TMPDIR/original.conf" "$CONF"
        assert_archive_unchanged
        run _cert_write_metadata "$CONF" "$path" "$CERT_TEST_CERT_DIR/$ID"
        assert_failure
        cmp "$BATS_TEST_TMPDIR/original.conf" "$CONF"
        run _cert_write_metadata "$CONF" "$CERT_TEST_WEBROOT" "$path"
        assert_failure
        cmp "$BATS_TEST_TMPDIR/original.conf" "$CONF"
    done
}

@test "unsafe identity boundaries never select a file outside the requested archive" {
    local identity token i
    local invalid=('' '../other' 'one/two' 'with space' $'with\ttab' $'with\nnewline' $'with\rcarriage' $'control\x01byte' $'control\x7fbyte')
    for (( i=0; i<FUZZ_ITERATIONS; i++ )); do
        token=$(random_ascii 12)
        identity="${invalid[$((i % ${#invalid[@]}))]}"
        [[ -z "$identity" ]] || identity="$token$identity"
        run fuzz_ensure "$identity" "$CERT_TEST_WEBROOT"
        assert_failure
        cmp "$BATS_TEST_TMPDIR/original.conf" "$CONF"
        assert_archive_unchanged
        run cert_is_usable "$identity" "$BATS_TEST_TMPDIR/good/fullchain.pem" "$BATS_TEST_TMPDIR/good/privkey.pem"
        assert_failure 1
        assert_archive_unchanged
    done
}

@test "malformed duplicate and hostile domain registrations never execute or trigger orders" {
    local token i mode
    for (( i=0; i<FUZZ_ITERATIONS; i++ )); do
        token=$(random_ascii 12)
        mode=$((i % 6))
        case "$mode" in
            0) printf "Le_Domain='%s'\nLe_Domain='%s'\nLe_Keylength='ec-256'\n" "$ID" "$ID" > "$CONF" ;;
            1) printf 'Le_Domain=$(touch %s)\nLe_Keylength=\x27ec-256\x27\n' "$BATS_TEST_TMPDIR/executed" > "$CONF" ;;
            2) printf "Le_Domain='%s'\nLe_Keylength='ec-256'\nLe_Keylength='ec-256'\n" "$ID" > "$CONF" ;;
            3) printf "Le_Domain='%s'\nLe_Keylength='2048'\n" "$ID" > "$CONF" ;;
            4) printf "Le_Domain='%s'\nLe_Keylength='%s'\n" "$ID" "$token" > "$CONF" ;;
            5) printf "Le_Domain='%s.example.test'\nLe_Keylength='ec-256'\n" "$token" > "$CONF" ;;
        esac
        cp "$CONF" "$BATS_TEST_TMPDIR/malformed.before"
        run fuzz_ensure "$ID" "$CERT_TEST_WEBROOT"
        assert_failure
        cmp "$BATS_TEST_TMPDIR/malformed.before" "$CONF"
        assert_archive_unchanged
    done
}
