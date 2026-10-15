#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    export HOME="$BATS_TEST_TMPDIR/home"
    export ACME_REALITY_CONF="$BATS_TEST_TMPDIR/reality.conf"
    export TPROXY_CONF="$BATS_TEST_TMPDIR/telegram.conf"
    export ACME_LOG="$BATS_TEST_TMPDIR/acme.log"
    export ACME_FIXTURE="$BATS_TEST_TMPDIR/fake-acme.sh"
    mkdir -p "$HOME/.acme.sh"
    : > "$ACME_LOG"
    source_common
    source "$PROJECT_ROOT/common/cert.sh"
    source "$PROJECT_ROOT/setup-essence/modules/acme-email.sh"
    cat > "$ACME_FIXTURE" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$ACME_LOG"
case "$1" in
    --set-default-ca) exit 0 ;;
    --register-account|--update-account)
        [ "${ACME_FAIL:-}" = "$1" ] && exit 1
        mkdir -p "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory"
        printf "ACCOUNT_URL='https://example.invalid/account'\nCA_EMAIL='%s'\n" "$5" > "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf"
        exit 0 ;;
esac
exit 1
MOCK
    chmod 700 "$ACME_FIXTURE"
}

teardown() { teardown_test_env; }

openssl() {
    if [[ "$*" == 'rand -hex 4' ]]; then printf '01234567\n'; else printf 'abcdef\n'; fi
}

curl() { cp "$ACME_FIXTURE" "$3"; }
sh() {
    [[ "$2" == email=* ]] || return 1
    printf '%s\n' "$2" > "$BATS_TEST_TMPDIR/install-email"
    mkdir -p "$HOME/.acme.sh"
    cp "$ACME_FIXTURE" "$HOME/.acme.sh/acme.sh"
}

registered() {
    cp "$ACME_FIXTURE" "$HOME/.acme.sh/acme.sh"
    mkdir -p "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory"
    printf "ACCOUNT_URL='https://example.invalid/account'\nCA_EMAIL='old@example.com'\n" > "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf"
}

@test "first Enter selects a generated email and installs it before registration" {
    acme_select_email <<< ''
    [ "$ACME_SELECTED_EMAIL" = user01234567@abcdef.com ]
    ensure_acme_installed "$ACME_SELECTED_EMAIL"
    [ "$(cat "$BATS_TEST_TMPDIR/install-email")" = email=user01234567@abcdef.com ]
    [ "$(cat "$ACME_LOG")" = $'--set-default-ca --server letsencrypt\n--register-account --server letsencrypt -m user01234567@abcdef.com' ]
    [ "$ACME_CONF_VALUE" = user01234567@abcdef.com ]
}

@test "registered Enter keeps the contact without an update" {
    registered
    acme_select_email <<< ''
    [ "$ACME_SELECTED_EMAIL" = old@example.com ]
    ensure_acme_installed "$ACME_SELECTED_EMAIL"
    [ "$(cat "$ACME_LOG")" = '--set-default-ca --server letsencrypt' ]
}

@test "refusing a changed contact reprompts and only approved change updates account" {
    registered
    local confirmations=0
    confirm_yn() { confirmations=$((confirmations + 1)); [[ "$confirmations" -eq 2 ]]; }
    acme_select_email <<< $'new@example.com\nnew@example.com\n'
    [ "$confirmations" -eq 2 ]
    [ "$ACME_SELECTED_EMAIL" = new@example.com ]
    ensure_acme_installed "$ACME_SELECTED_EMAIL"
    [ "$(grep -c '^--update-account --server letsencrypt -m new@example.com$' "$ACME_LOG")" -eq 1 ]
}

@test "refusal followed by EOF leaves account and selection unchanged" {
    registered
    confirm_yn() { return 1; }
    ACME_SELECTED_EMAIL=stale@example.com
    acme_select_email <<< 'new@example.com' && return 1
    [ -z "$ACME_SELECTED_EMAIL" ]
    [ ! -s "$ACME_LOG" ]
}

@test "unknown registered contact requires confirmation before selection" {
    registered
    printf "ACCOUNT_URL='https://example.invalid/account'\n" > "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf"
    confirm_yn() { return 1; }
    acme_select_email <<< 'new@example.com' && return 1
    [ -z "$ACME_SELECTED_EMAIL" ]
    [ ! -s "$ACME_LOG" ]
}

@test "unknown installed contact cannot be accepted with Enter and EOF cancels" {
    cp "$ACME_FIXTURE" "$HOME/.acme.sh/acme.sh"
    run acme_select_email <<< $'\n'
    assert_failure
    [ ! -s "$ACME_LOG" ]
    acme_select_email <<< $'\nnew@example.com\n'
    [ "$ACME_SELECTED_EMAIL" = new@example.com ]
}

@test "invalid email cannot reach acme client" {
    registered
    run ensure_acme_installed 'bad address'
    assert_failure
    [ ! -s "$ACME_LOG" ]
}

@test "sync changes only active contacts and preserves unrelated secret fields" {
    registered
    printf 'MODE=self-steal\nEMAIL=old@example.com\nPRIVATE_KEY=hidden\n' > "$ACME_REALITY_CONF"
    printf 'TELEGRAM_WEB_ENABLED=true\nTELEGRAM_WEB_EMAIL=old@example.com\nSECRET=hidden\n' > "$TPROXY_CONF"
    ensure_essence_acme_email new@example.com
    [ "$(cat "$ACME_REALITY_CONF")" = $'MODE=self-steal\nEMAIL=new@example.com\nPRIVATE_KEY=hidden' ]
    [ "$(cat "$TPROXY_CONF")" = $'TELEGRAM_WEB_ENABLED=true\nTELEGRAM_WEB_EMAIL=new@example.com\nSECRET=hidden' ]
    [ "$(grep -c '^--update-account ' "$ACME_LOG")" -eq 1 ]
}

@test "bare SNI and disabled WEB email stay empty" {
    registered
    printf 'MODE=sni\nEMAIL=\n' > "$ACME_REALITY_CONF"
    printf 'TELEGRAM_WEB_ENABLED=false\nTELEGRAM_WEB_EMAIL=\n' > "$TPROXY_CONF"
    ensure_essence_acme_email old@example.com
    [ "$(cat "$ACME_REALITY_CONF")" = $'MODE=sni\nEMAIL=' ]
    [ "$(cat "$TPROXY_CONF")" = $'TELEGRAM_WEB_ENABLED=false\nTELEGRAM_WEB_EMAIL=' ]
}

@test "malformed state aborts before account update or partial file writes" {
    registered
    printf 'EMAIL=old@example.com\n' > "$ACME_REALITY_CONF"
    printf 'TELEGRAM_WEB_ENABLED=true\nTELEGRAM_WEB_EMAIL=old@example.com\nTELEGRAM_WEB_EMAIL=old@example.com\n' > "$TPROXY_CONF"
    run ensure_essence_acme_email new@example.com
    assert_failure
    [ ! -s "$ACME_LOG" ]
    [ "$(cat "$ACME_REALITY_CONF")" = EMAIL=old@example.com ]
}

@test "failed ACME update leaves both saved contacts unchanged" {
    registered
    printf 'EMAIL=old@example.com\n' > "$ACME_REALITY_CONF"
    printf 'TELEGRAM_WEB_ENABLED=true\nTELEGRAM_WEB_EMAIL=old@example.com\n' > "$TPROXY_CONF"
    export ACME_FAIL=--update-account
    run ensure_essence_acme_email new@example.com
    assert_failure
    [ "$(cat "$ACME_REALITY_CONF")" = EMAIL=old@example.com ]
    [ "$(cat "$TPROXY_CONF")" = $'TELEGRAM_WEB_ENABLED=true\nTELEGRAM_WEB_EMAIL=old@example.com' ]
}

@test "failed second replacement restores first file and previous account contact" {
    registered
    printf 'EMAIL=old@example.com\n' > "$ACME_REALITY_CONF"
    printf 'TELEGRAM_WEB_ENABLED=true\nTELEGRAM_WEB_EMAIL=old@example.com\n' > "$TPROXY_CONF"
    mv() {
        if [[ "$2" == "$TPROXY_CONF".stage.* ]]; then return 1; fi
        command mv "$@"
    }
    run ensure_essence_acme_email new@example.com
    assert_failure
    [ "$(cat "$ACME_REALITY_CONF")" = EMAIL=old@example.com ]
    [ "$(cat "$TPROXY_CONF")" = $'TELEGRAM_WEB_ENABLED=true\nTELEGRAM_WEB_EMAIL=old@example.com' ]
    _acme_conf_value "$HOME/.acme.sh/ca/acme-v02.api.letsencrypt.org/directory/ca.conf" CA_EMAIL
    [ "$ACME_CONF_VALUE" = old@example.com ]
}
