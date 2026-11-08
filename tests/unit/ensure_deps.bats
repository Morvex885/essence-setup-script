#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    PM=apt
    source "$PROJECT_ROOT/common/ensure-deps.sh"
    FAKE_BIN="$BATS_TEST_TMPDIR/commands"
    mkdir -p "$FAKE_BIN"
    INSTALL_JOURNAL="$BATS_TEST_TMPDIR/install-journal"
    : > "$INSTALL_JOURNAL"
    ORIGINAL_PATH="$PATH"
    PATH="$FAKE_BIN"
    pm_install() {
        local bin
        printf '%s\n' "$1" >> "$INSTALL_JOURNAL"
        case "$1" in
            nftables) bin=nft ;;
            systemd) bin=systemctl ;;
            passwd) bin=useradd ;;
            coreutils) bin=id ;;
            util-linux) bin=runuser ;;
            *) return 1 ;;
        esac
        printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/$bin"
        /bin/chmod +x "$FAKE_BIN/$bin"
    }
}
teardown() {
    PATH="$ORIGINAL_PATH"
    teardown_test_env
}

@test "apt installs actual packages for missing Telegram commands" {
    local bin package
    for bin in nft systemctl useradd id runuser; do
        case "$bin" in
            nft) package=nftables ;;
            systemctl) package=systemd ;;
            useradd) package=passwd ;;
            id) package=coreutils ;;
            runuser) package=util-linux ;;
        esac
        ensure_dep "$bin"
        [ "$(command -v "$bin")" = "$FAKE_BIN/$bin" ]
        [ "$(/usr/bin/sed -n '$p' "$INSTALL_JOURNAL")" = "$package" ]
    done
    [ "$(/usr/bin/wc -l < "$INSTALL_JOURNAL")" -eq 5 ]
    ensure_dep nft systemctl useradd id runuser
    [ "$(/usr/bin/wc -l < "$INSTALL_JOURNAL")" -eq 5 ]
}
@test "missing binary after successful installer remains a dependency error" {
    pm_install() { printf '%s\n' "$1" >> "$INSTALL_JOURNAL"; return 0; }
    run ensure_dep nft
    assert_failure
    [ "$(/bin/cat "$INSTALL_JOURNAL")" = nftables ]
}
@test "other package managers keep their existing command names" {
    PM=dnf
    [ "$(pkg_name_for nft)" = nft ]
    [ "$(pkg_name_for systemctl)" = systemctl ]
    [ "$(pkg_name_for useradd)" = useradd ]
}

# Fixture bundle models command behaviour; the official archive is exercised by
# the separate installed-layout smoke, not downloaded during the unit suite.
_age_fixture() {
    export PATH="$FAKE_BIN:$ORIGINAL_PATH" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
    AGE_BIN=age AGE_KEYGEN_BIN=age-keygen
    mkdir -p "$BATS_TEST_TMPDIR/bundle/age"
    local f
    for f in age age-keygen age-plugin-batchpass; do
        printf '#!/bin/bash\nif [[ "$1" == --version ]]; then echo v1.3.2; else cat; fi\n' > "$BATS_TEST_TMPDIR/bundle/age/$f"
        chmod +x "$BATS_TEST_TMPDIR/bundle/age/$f"
    done
    tar -czf "$BATS_TEST_TMPDIR/bundle.tar.gz" -C "$BATS_TEST_TMPDIR/bundle" age
    printf '#!/bin/bash\necho v1.1.1\n' > "$FAKE_BIN/age"
    chmod +x "$FAKE_BIN/age"
    curl() {
        printf '%s\n' "$*" >> "$INSTALL_JOURNAL"
        cp "$BATS_TEST_TMPDIR/bundle.tar.gz" "${@: -1}"
    }
    sha256sum() { echo 'cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10  archive'; }
    uname() { [[ "$1" == -s ]] && echo Linux || echo x86_64; }
}

@test "old system age installs a private versioned bundle and reuses it" {
    _age_fixture
    ensure_age_batchpass
    [ "$AGE_BIN" = "$XDG_CACHE_HOME/remote-control-essence/tools/age-v1.3.2/age" ]
    [ -x "$AGE_KEYGEN_BIN" ]
    [ -x "$(dirname "$AGE_BIN")/age-plugin-batchpass" ]
    [ "$("$FAKE_BIN/age" --version)" = v1.1.1 ]
    [ "$(wc -l < "$INSTALL_JOURNAL")" -eq 1 ]
    AGE_BIN=age AGE_KEYGEN_BIN=age-keygen
    ensure_age_batchpass
    [ "$(wc -l < "$INSTALL_JOURNAL")" -eq 1 ]
}

@test "compatible native toolchain is retained and explicit invalid override is rejected" {
    _age_fixture
    cp "$BATS_TEST_TMPDIR/bundle/age/"* "$FAKE_BIN/"
    ensure_age_batchpass
    [ "$AGE_BIN" = "$FAKE_BIN/age" ]
    [ "$AGE_KEYGEN_BIN" = "$FAKE_BIN/age-keygen" ]
    [ "$("$AGE_BIN" --version)" = v1.3.2 ]
    [ ! -s "$INSTALL_JOURNAL" ]
    cd "$BATS_TEST_TMPDIR"
    AGE_BIN=./commands/age AGE_KEYGEN_BIN=./commands/age-keygen
    ensure_age_batchpass
    [ "$AGE_BIN" = "$FAKE_BIN/age" ]
    [ "$AGE_KEYGEN_BIN" = "$FAKE_BIN/age-keygen" ]
    [ ! -s "$INSTALL_JOURNAL" ]
    AGE_BIN="$BATS_TEST_TMPDIR/missing-age"
    ! ensure_age_batchpass || return 1
    [ "$AGE_BIN" = "$BATS_TEST_TMPDIR/missing-age" ]
    [ ! -s "$INSTALL_JOURNAL" ]
    AGE_BIN=age AGE_KEYGEN_BIN=age-keygen
    age() { echo v1.3.2; }
    ! ensure_age_batchpass || return 1
    [ ! -s "$INSTALL_JOURNAL" ]
    unset -f age
    AGE_BIN="$BATS_TEST_TMPDIR/not-executable"
    printf '#!/bin/bash\n' > "$AGE_BIN"
    ! ensure_age_batchpass || return 1
    [ ! -s "$INSTALL_JOURNAL" ]
}

@test "unsupported and Termux platforms do not install a glibc bundle" {
    _age_fixture
    uname() { [[ "$1" == -s ]] && echo Linux || echo riscv64; }
    ! ensure_age_batchpass || return 1
    [ ! -s "$INSTALL_JOURNAL" ]
    PM=termux
    pm_install() { return 1; }
    ! ensure_age_batchpass || return 1
    [ ! -s "$INSTALL_JOURNAL" ]
}

@test "unsafe cache link and incorrect archive digest are rejected" {
    _age_fixture
    mkdir -p "$XDG_CACHE_HOME" "$BATS_TEST_TMPDIR/outside"
    ln -s "$BATS_TEST_TMPDIR/outside" "$XDG_CACHE_HOME/remote-control-essence"
    ! ensure_age_batchpass || return 1
    [ ! -s "$INSTALL_JOURNAL" ]
    rm "$XDG_CACHE_HOME/remote-control-essence"
    sha256sum() { echo 'bad  archive'; }
    ! ensure_age_batchpass || return 1
    [ ! -e "$XDG_CACHE_HOME/remote-control-essence/tools/age-v1.3.2" ]
}
