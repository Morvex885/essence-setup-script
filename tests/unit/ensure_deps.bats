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
