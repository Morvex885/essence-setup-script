#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env

    export AWG_TEST_ROOT="$BATS_TEST_TMPDIR/awg-root"
    export AWG_DIR="$AWG_TEST_ROOT/etc/amnezia/amneziawg"
    export AWG_CONF="$AWG_DIR/awg0.conf"
    export AWG_CLIENTS_DIR="$AWG_TEST_ROOT/etc/mihomo/amnezia"
    export AWG_MIHOMO_CONFIG="$AWG_TEST_ROOT/etc/mihomo/config.yaml"
    export AWG_CLIENT_CONFIG="$AWG_TEST_ROOT/etc/mihomo/client-config.txt"
    export AWG_SYSCTL_FILE="$AWG_TEST_ROOT/etc/sysctl.d/99-vpn-speedup.conf"
    export AWG_OS_RELEASE="$AWG_TEST_ROOT/etc/os-release"
    export AWG_MODULES_ROOT="$AWG_TEST_ROOT/lib/modules"
    export AWG_APT_KEYRING="$AWG_TEST_ROOT/etc/apt/keyrings/amnezia.gpg"
    export AWG_APT_SOURCE="$AWG_TEST_ROOT/etc/apt/sources.list.d/amnezia.sources"
    export AWG_APT_SOURCES_LIST="$AWG_TEST_ROOT/etc/apt/sources.list"
    export AWG_APT_SOURCES_DIR="$AWG_TEST_ROOT/etc/apt/sources.list.d"
    export AWG_TMP_BASE="$AWG_TEST_ROOT/tmp"
    export AWG_EFFECTIVE_EUID=0
    export MOCK_BIN="$AWG_TEST_ROOT/mock-bin"
    export MOCK_STATE="$AWG_TEST_ROOT/mock-state"
    export MOCK_CALLS="$MOCK_STATE/calls"
    export MOCK_ARCH=amd64 MOCK_KERNEL=6.1.0-test MOCK_HEADERS=1 MOCK_PACKAGE=1
    export AWG_KERNEL="$MOCK_KERNEL" AWG_HEADERS_PKG="linux-headers-$MOCK_KERNEL"
    export MOCK_CANDIDATE=1.0.0 MOCK_HEADERS_CANDIDATE=6.1.0-test-1
    export MOCK_FINGERPRINT=75C9DD72C799870E310542E24166F2C257290828
    export MOCK_APT_UPDATE_FAIL=0 MOCK_APT_INSTALL_FAIL=0 MOCK_MODINFO_FAIL=0 MOCK_MODPROBE_FAIL=0
    export MOCK_APT_INSTALL_FAIL_PACKAGE="" MOCK_GPG_POST_INSTALL_MISSING=0
    export MOCK_HEADERS_POST_INSTALL_BUILD_MISSING=0
    export MOCK_MIHOMO_FAIL=0 MOCK_SYSTEMCTL_FAIL_UNIT="" MOCK_UFW_FAIL=0

    mkdir -p "$MOCK_BIN" "$MOCK_STATE" "$AWG_TEST_ROOT/etc/mihomo" \
        "$AWG_APT_SOURCES_DIR" "$AWG_TMP_BASE" "$AWG_MODULES_ROOT/$MOCK_KERNEL/build"
    : > "$MOCK_CALLS"
    cat > "$AWG_OS_RELEASE" <<'EOF'
ID=debian
VERSION_ID="12"
EOF
    cat > "$AWG_MIHOMO_CONFIG" <<'EOF'
bind-address: '*'
mode: rule
EOF
    cat > "$AWG_CLIENT_CONFIG" <<'EOF'
Domain: vpn.example.com
Existing: keep-me
EOF
    _write_awg_mocks
    export PATH="$MOCK_BIN:$PATH"

    source_common
    source "$PROJECT_ROOT/setup-essence/modules/amneziawg.sh"
}

teardown() {
    teardown_test_env
}

_file_mode() {
    case "${OSTYPE:-}" in
        darwin*) stat -f '%Lp' "$1" ;;
        *) stat -c '%a' "$1" ;;
    esac
}


_mock_script() {
    local name="$1"
    shift
    printf '#!/bin/bash\n%s\n' "$*" > "$MOCK_BIN/$name"
    chmod +x "$MOCK_BIN/$name"
}

_write_awg_mocks() {
    cat > "$MOCK_BIN/dpkg" <<'EOF'
#!/bin/bash
[[ "$1" == "--print-architecture" ]] && { echo "${MOCK_ARCH}"; exit 0; }
exit 0
EOF
    cat > "$MOCK_BIN/dpkg-query" <<'EOF'
#!/bin/bash
case "$*" in
  *linux-headers-*) [[ "$MOCK_HEADERS" == 1 ]] || exit 1 ;;
  *amneziawg*) [[ "$MOCK_PACKAGE" == 1 ]] || exit 1 ;;
esac
echo 'install ok installed'
EOF
    cat > "$MOCK_BIN/uname" <<'EOF'
#!/bin/bash
echo "$MOCK_KERNEL"
EOF
    cat > "$MOCK_BIN/curl" <<'EOF'
#!/bin/bash
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then out="$2"; shift 2; else shift; fi
done
if [[ -n "$out" ]]; then printf 'mock public key\n' > "$out"; else printf '203.0.113.10'; fi
EOF
    cat > "$MOCK_BIN/gpg" <<'EOF'
#!/bin/bash
if [[ "$*" == *"--show-keys"* ]]; then
  printf 'fpr:::::::::%s:\n' "$MOCK_FINGERPRINT"
else
  cat
fi
EOF
    cat > "$MOCK_BIN/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >> "$MOCK_CALLS"
if [[ "$1" == "update" ]]; then
  if grep -RFq 'https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu' "$AWG_TEST_ROOT/etc/apt" 2>/dev/null; then
    echo 'apt-update-amnezia-source=present' >> "$MOCK_CALLS"
  else
    echo 'apt-update-amnezia-source=absent' >> "$MOCK_CALLS"
  fi
  [[ "$MOCK_APT_UPDATE_FAIL" == 1 ]] && exit 1
fi
if [[ "$1" == "install" ]]; then
  [[ "$MOCK_APT_INSTALL_FAIL" == 1 ]] && exit 1
  [[ -n "$MOCK_APT_INSTALL_FAIL_PACKAGE" && "$*" == *"$MOCK_APT_INSTALL_FAIL_PACKAGE"* ]] && exit 1
  if [[ "$*" == *gnupg* && "$MOCK_GPG_POST_INSTALL_MISSING" != 1 ]]; then
    touch "$MOCK_STATE/gpg.available"
  fi
  if [[ "$*" == *"linux-headers-$MOCK_KERNEL"* && "$MOCK_HEADERS_POST_INSTALL_BUILD_MISSING" != 1 ]]; then
    mkdir -p "$AWG_MODULES_ROOT/$MOCK_KERNEL/build"
  fi
fi
exit 0
EOF
    cat > "$MOCK_BIN/apt-cache" <<'EOF'
#!/bin/bash
echo "apt-cache $*" >> "$MOCK_CALLS"
package="${@: -1}"
echo "$package:"
if [[ "$package" == "linux-headers-$MOCK_KERNEL" ]]; then
  candidate="$MOCK_HEADERS_CANDIDATE"
else
  candidate="$MOCK_CANDIDATE"
fi
if [[ -n "$candidate" ]]; then echo "  Candidate: $candidate"; else echo '  Candidate: (none)'; fi
EOF
    cat > "$MOCK_BIN/modinfo" <<'EOF'
#!/bin/bash
echo "modinfo $*" >> "$MOCK_CALLS"
[[ "$MOCK_MODINFO_FAIL" == 1 ]] && exit 1
echo 'filename: mock/amneziawg.ko'
EOF
    cat > "$MOCK_BIN/modprobe" <<'EOF'
#!/bin/bash
echo "modprobe $*" >> "$MOCK_CALLS"
[[ "$1" == "amneziawg" && "$MOCK_MODPROBE_FAIL" == 1 ]] && exit 1
exit 0
EOF
    cat > "$MOCK_BIN/mihomo" <<'EOF'
#!/bin/bash
echo "mihomo $*" >> "$MOCK_CALLS"
[[ "$MOCK_MIHOMO_FAIL" == 1 ]] && exit 1
exit 0
EOF
    cat > "$MOCK_BIN/awg" <<'EOF'
#!/bin/bash
case "$1" in
  genkey) echo 'server-private' ;;
  pubkey) read -r key; echo "public-$key" ;;
  genpsk) echo 'server-psk' ;;
  *) exit 0 ;;
esac
EOF
    cat > "$MOCK_BIN/awg-quick" <<'EOF'
#!/bin/bash
echo "awg-quick $*" >> "$MOCK_CALLS"
exit 0
EOF
    cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/bin/bash
action="$1"
unit="${@: -1}"
safe_unit=${unit//@/_}; safe_unit=${safe_unit//\//_}
echo "systemctl $*" >> "$MOCK_CALLS"
case "$action" in
  is-active) [[ -f "$MOCK_STATE/active.$safe_unit" ]] ;;
  is-enabled) [[ -f "$MOCK_STATE/enabled.$safe_unit" ]] ;;
  restart|start)
    if [[ "$unit" == "$MOCK_SYSTEMCTL_FAIL_UNIT" && ! -f "$MOCK_STATE/failed-once.$safe_unit" ]]; then
      touch "$MOCK_STATE/failed-once.$safe_unit"
      exit 1
    fi
    touch "$MOCK_STATE/active.$safe_unit"
    ;;
  stop) rm -f "$MOCK_STATE/active.$safe_unit" ;;
  enable) touch "$MOCK_STATE/enabled.$safe_unit" ;;
  disable) rm -f "$MOCK_STATE/enabled.$safe_unit" ;;
esac
EOF
    cat > "$MOCK_BIN/ufw" <<'EOF'
#!/bin/bash
echo "ufw $*" >> "$MOCK_CALLS"
rules="$MOCK_STATE/ufw.rules"
touch "$rules"
case "$1" in
  status) while IFS= read -r rule; do [[ -n "$rule" ]] && echo "$rule ALLOW Anywhere"; done < "$rules" ;;
  allow)
    [[ "$MOCK_UFW_FAIL" == 1 ]] && exit 1
    grep -qxF "$2" "$rules" 2>/dev/null || echo "$2" >> "$rules"
    ;;
  delete)
    tmp="$rules.tmp"
    grep -vxF "$3" "$rules" > "$tmp" || true
    mv "$tmp" "$rules"
    ;;
esac
EOF
    cat > "$MOCK_BIN/ip" <<'EOF'
#!/bin/bash
echo "ip $*" >> "$MOCK_CALLS"
[[ "$1 $2 $3" == "link show awg0" && "$MOCK_IP_LINK_FAIL" == 1 ]] && exit 1
exit 0
EOF
    cat > "$MOCK_BIN/sysctl" <<'EOF'
#!/bin/bash
echo "sysctl $*" >> "$MOCK_CALLS"
exit 0
EOF
    for cmd in iptables journalctl dkms dmesg qrencode; do
        cat > "$MOCK_BIN/$cmd" <<EOF
#!/bin/bash
echo "$cmd \$*" >> "\$MOCK_CALLS"
exit 0
EOF
    done
    cat > "$MOCK_BIN/fuser" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$MOCK_BIN"/*
}

_simulate_missing_gpg() {
    command() {
        if [[ "$1" == "-v" && "${2:-}" == "gpg" && ! -f "$MOCK_STATE/gpg.available" ]]; then
            return 1
        fi
        builtin command "$@"
    }
}

_seed_old_repo_state() {
    mkdir -p "$(dirname "$AWG_APT_KEYRING")" "$AWG_APT_SOURCES_DIR"
    cat > "$AWG_APT_SOURCE" <<EOF
Types: deb
URIs: $AWG_PPA_URI
Suites: broken
Components: main
Signed-By: $AWG_APT_KEYRING
EOF
    cat > "$AWG_APT_SOURCES_DIR/legacy.list" <<EOF
deb $AWG_PPA_URI stale main
deb https://deb.debian.org/debian bookworm main
EOF
    printf 'old-keyring\n' > "$AWG_APT_KEYRING"
}

_assert_old_repo_state_restored() {
    grep -qxF 'Suites: broken' "$AWG_APT_SOURCE"
    grep -qxF "deb $AWG_PPA_URI stale main" "$AWG_APT_SOURCES_DIR/legacy.list"
    grep -qxF 'deb https://deb.debian.org/debian bookworm main' "$AWG_APT_SOURCES_DIR/legacy.list"
    [[ "$(<"$AWG_APT_KEYRING")" == "old-keyring" ]]
}

_mock_install_environment() {
    _awg_preflight() {
        AWG_ARCH=amd64
        AWG_KERNEL="$MOCK_KERNEL"
        AWG_APT_SUITE=focal
        AWG_MIHOMO_BIN="$MOCK_BIN/mihomo"
    }
    _awg_gen_free_port() {
        [[ "$1" == 30000 ]] && echo 41000 || echo 12000
    }
    _awg_gen_params() {
        AWG_Jc=4 AWG_Jmin=10 AWG_Jmax=50
        AWG_S1=20 AWG_S2=30 AWG_S3=5 AWG_S4=6
        AWG_H1=10-20 AWG_H2=30-40 AWG_H3=50-60 AWG_H4=70-80
    }
    is_port_free() { return 0; }
    confirm_yn() {
        [[ "$1" == *"Создать peer"* ]] && return 1
        return 0
    }
}

_mock_install_prerequisites() {
    _mock_install_environment
    _awg_ensure_packages() { return 0; }
}

_run_bootstrap_failure() {
    local mode="$1"
    rm -f "$MOCK_STATE/gpg.available"
    : > "$MOCK_CALLS"
    export MOCK_APT_UPDATE_FAIL=0 MOCK_APT_INSTALL_FAIL=0 MOCK_GPG_POST_INSTALL_MISSING=0
    _seed_old_repo_state
    _simulate_missing_gpg
    case "$mode" in
        lock) _awg_apt_wait() { return 1; } ;;
        update) export MOCK_APT_UPDATE_FAIL=1 ;;
        install) export MOCK_APT_INSTALL_FAIL=1 ;;
        missing) export MOCK_GPG_POST_INSTALL_MISSING=1 ;;
    esac
    AWG_APT_SUITE=focal AWG_ARCH=amd64 AWG_KERNEL="$MOCK_KERNEL"
    _awg_install_repository
}

_run_install_with_sentinel() {
    install_awg <<< $'\n\n'
    local rc=$?
    echo "INSTALL_RC=$rc"
    echo "SENTINEL_AFTER_INSTALL"
    return 0
}

@test "platform mapping: Debian 12/13 use focal and Ubuntu uses jammy/noble" {
    local id version expected
    detect_platform() {
        _awg_detect_platform || return
        printf '%s\n' "$AWG_APT_SUITE"
    }
    while IFS='|' read -r id version expected; do
        printf 'ID=%s\nVERSION_ID="%s"\n' "$id" "$version" > "$AWG_OS_RELEASE"
        run detect_platform
        assert_success
        assert_output "$expected"
    done <<'EOF'
debian|12|focal
debian|13|focal
ubuntu|22.04|jammy
ubuntu|24.04|noble
EOF
}

@test "unsupported OS returns without global exit" {
    printf 'ID=ubuntu\nVERSION_ID="26.04"\n' > "$AWG_OS_RELEASE"
    check_sentinel() { _awg_detect_platform; echo sentinel; }
    run check_sentinel
    assert_output --partial "Поддерживаются Debian 12/13"
    assert_output --partial "sentinel"
}

@test "preflight records exact headers package without requiring dpkg state or build-path" {
    export MOCK_HEADERS=0
    rmdir "$AWG_MODULES_ROOT/$MOCK_KERNEL/build"
    preflight_values() {
        _awg_preflight || return
        printf '%s|%s\n' "$AWG_KERNEL" "$AWG_HEADERS_PKG"
    }

    run preflight_values
    assert_success
    assert_output "$MOCK_KERNEL|linux-headers-$MOCK_KERNEL"
}

@test "preflight passes when gpg is missing" {
    _simulate_missing_gpg

    run _awg_preflight
    assert_success
}

@test "missing gpg installs gnupg before configuring the PPA" {
    _seed_old_repo_state
    _simulate_missing_gpg
    AWG_APT_SUITE=focal AWG_ARCH=amd64 AWG_KERNEL="$MOCK_KERNEL"

    run _awg_ensure_packages
    assert_success
    grep -q '^apt-get update$' "$MOCK_CALLS"
    grep -q '^apt-get install -y gnupg$' "$MOCK_CALLS"
    ! grep -q "linux-headers-$MOCK_KERNEL" "$MOCK_CALLS"
    grep -q '^apt-get install -y amneziawg$' "$MOCK_CALLS"
    source_states=()
    while IFS= read -r value; do source_states+=("$value"); done < <(grep '^apt-update-amnezia-source=' "$MOCK_CALLS")
    assert_equal "${source_states[0]}" 'apt-update-amnezia-source=absent'
    assert_equal "${source_states[1]}" 'apt-update-amnezia-source=present'
    [[ -f "$AWG_APT_KEYRING" ]]
    grep -qxF "Suites: focal" "$AWG_APT_SOURCE"
    ! grep -Fq "$AWG_PPA_URI" "$AWG_APT_SOURCES_DIR/legacy.list"
    grep -qxF 'deb https://deb.debian.org/debian bookworm main' "$AWG_APT_SOURCES_DIR/legacy.list"
}

@test "gnupg bootstrap failures restore managed and legacy sources and keyring" {
    local mode
    for mode in lock update install missing; do
        run _run_bootstrap_failure "$mode"
        assert_failure
        _assert_old_repo_state_restored
        [[ -z "$(find "$AWG_TMP_BASE" -maxdepth 1 -type d -name 'awg-repo.*' -print -quit)" ]]
        case "$mode" in
            lock) ! grep -q '^apt-get update$' "$MOCK_CALLS" ;;
            update) assert_output --partial 'apt-get update для bootstrap зависимостей' ;;
            install) assert_output --partial 'Не удалось установить пакет gnupg' ;;
            missing) assert_output --partial 'После bootstrap команда gpg не найдена' ;;
        esac
    done
}

@test "existing build-path is accepted without a dpkg headers package" {
    export MOCK_HEADERS=0 AWG_APT_SUITE=focal AWG_ARCH=amd64

    run _awg_ensure_packages
    assert_success
    assert_equal "$(grep -c '^apt-get update$' "$MOCK_CALLS")" 1
    ! grep -q "apt-get install.*linux-headers-$MOCK_KERNEL" "$MOCK_CALLS"
    grep -qxF 'apt-update-amnezia-source=present' "$MOCK_CALLS"
}

@test "missing headers package is installed for the exact running kernel" {
    rm -rf "$AWG_MODULES_ROOT/$MOCK_KERNEL/build"
    export MOCK_HEADERS=0 AWG_APT_SUITE=focal AWG_ARCH=amd64

    run _awg_ensure_packages
    assert_success
    grep -q "^apt-cache policy linux-headers-$MOCK_KERNEL$" "$MOCK_CALLS"
    grep -q "^apt-get install -y linux-headers-$MOCK_KERNEL$" "$MOCK_CALLS"
    ! grep -q '^apt-get install --reinstall' "$MOCK_CALLS"
    [[ -d "$AWG_MODULES_ROOT/$MOCK_KERNEL/build" ]]
    source_states=()
    while IFS= read -r value; do source_states+=("$value"); done < <(grep '^apt-update-amnezia-source=' "$MOCK_CALLS")
    assert_equal "${source_states[0]}" 'apt-update-amnezia-source=absent'
    assert_equal "${source_states[1]}" 'apt-update-amnezia-source=present'
}

@test "installed headers package without build-path is reinstalled" {
    rm -rf "$AWG_MODULES_ROOT/$MOCK_KERNEL/build"
    export MOCK_HEADERS=1 AWG_APT_SUITE=focal AWG_ARCH=amd64

    run _awg_ensure_packages
    assert_success
    grep -q "^apt-get install --reinstall -y linux-headers-$MOCK_KERNEL$" "$MOCK_CALLS"
    [[ -d "$AWG_MODULES_ROOT/$MOCK_KERNEL/build" ]]
}

@test "missing gpg and headers share one bootstrap update" {
    rm -rf "$AWG_MODULES_ROOT/$MOCK_KERNEL/build"
    rm -f "$MOCK_STATE/gpg.available"
    export MOCK_HEADERS=0 AWG_APT_SUITE=focal AWG_ARCH=amd64
    _simulate_missing_gpg

    run _awg_ensure_packages
    assert_success
    assert_equal "$(grep -c '^apt-get update$' "$MOCK_CALLS")" 2
    grep -q '^apt-get install -y gnupg$' "$MOCK_CALLS"
    grep -q "^apt-get install -y linux-headers-$MOCK_KERNEL$" "$MOCK_CALLS"
}

@test "bootstrap waits for apt lock before update and every dependency install" {
    rm -rf "$AWG_MODULES_ROOT/$MOCK_KERNEL/build"
    rm -f "$MOCK_STATE/gpg.available"
    export MOCK_HEADERS=0 AWG_APT_SUITE=focal AWG_ARCH=amd64
    _simulate_missing_gpg
    _awg_apt_wait() { echo 'apt-wait' >> "$MOCK_CALLS"; }

    run _awg_install_repository
    assert_success
    events=()
    while IFS= read -r value; do events+=("$value"); done < <(grep -E '^(apt-wait|apt-get)' "$MOCK_CALLS")
    assert_equal "${events[0]}" 'apt-wait'
    assert_equal "${events[1]}" 'apt-get update'
    assert_equal "${events[2]}" 'apt-wait'
    assert_equal "${events[3]}" 'apt-get install -y gnupg'
    assert_equal "${events[4]}" 'apt-wait'
    assert_equal "${events[5]}" "apt-get install -y linux-headers-$MOCK_KERNEL"
    assert_equal "${#events[@]}" 6
}

@test "apt-lock failure at each bootstrap APT step rolls back sources and keyring" {
    local fail_at
    _simulate_missing_gpg
    for fail_at in 1 2 3; do
        rm -rf "$AWG_MODULES_ROOT/$MOCK_KERNEL/build"
        rm -f "$MOCK_STATE/gpg.available"
        export MOCK_HEADERS=0 AWG_APT_SUITE=focal AWG_ARCH=amd64
        _seed_old_repo_state
        AWG_WAIT_CALL=0
        _awg_apt_wait() {
            AWG_WAIT_CALL=$((AWG_WAIT_CALL + 1))
            [[ "$AWG_WAIT_CALL" -ne "$fail_at" ]]
        }

        run _awg_install_repository
        assert_failure
        _assert_old_repo_state_restored
    done
}

@test "AWG repository update and package install each wait for apt lock" {
    export AWG_APT_SUITE=focal AWG_ARCH=amd64
    _awg_apt_wait() { echo 'apt-wait' >> "$MOCK_CALLS"; }

    run _awg_ensure_packages
    assert_success
    events=()
    while IFS= read -r value; do events+=("$value"); done < <(grep -E '^(apt-wait|apt-get)' "$MOCK_CALLS")
    assert_equal "${events[0]}" 'apt-wait'
    assert_equal "${events[1]}" 'apt-get update'
    assert_equal "${events[2]}" 'apt-wait'
    assert_equal "${events[3]}" 'apt-get install -y amneziawg'
    assert_equal "${#events[@]}" 4
}

@test "missing headers candidate explains kernel and repository causes and rolls back APT files" {
    rm -rf "$AWG_MODULES_ROOT/$MOCK_KERNEL/build"
    export MOCK_HEADERS=0 MOCK_HEADERS_CANDIDATE="" AWG_APT_SUITE=focal AWG_ARCH=amd64
    _seed_old_repo_state

    run _awg_install_repository
    assert_failure
    assert_output --partial 'Активные репозитории не предоставляют headers для текущего ядра'
    assert_output --partial 'старое/custom/provider kernel, неполные репозитории или APT pinning'
    assert_output --partial 'Ядро не обновлялось, сервер не перезагружался'
    _assert_old_repo_state_restored
}

@test "headers install and reinstall failures restore managed and legacy APT files" {
    local installed
    for installed in 0 1; do
        rm -rf "$AWG_MODULES_ROOT/$MOCK_KERNEL/build"
        : > "$MOCK_CALLS"
        export MOCK_HEADERS="$installed" MOCK_APT_INSTALL_FAIL_PACKAGE="linux-headers-$MOCK_KERNEL"
        export AWG_APT_SUITE=focal AWG_ARCH=amd64
        _seed_old_repo_state

        run _awg_install_repository
        assert_failure
        _assert_old_repo_state_restored
        if [[ "$installed" == 1 ]]; then
            grep -q "^apt-get install --reinstall -y linux-headers-$MOCK_KERNEL$" "$MOCK_CALLS"
        else
            grep -q "^apt-get install -y linux-headers-$MOCK_KERNEL$" "$MOCK_CALLS"
        fi
    done
}

@test "successful headers APT without build-path fails factual postcondition and rolls back" {
    rm -rf "$AWG_MODULES_ROOT/$MOCK_KERNEL/build"
    export MOCK_HEADERS=0 MOCK_HEADERS_POST_INSTALL_BUILD_MISSING=1
    export AWG_APT_SUITE=focal AWG_ARCH=amd64
    _seed_old_repo_state

    run _awg_install_repository
    assert_failure
    assert_output --partial 'не появился build-path'
    _assert_old_repo_state_restored
}

@test "incomplete repository rollback emits a separate warning and keeps backups" {
    AWG_REPO_TX_DIR="$AWG_TMP_BASE/rollback-warning"
    mkdir -p "$AWG_REPO_TX_DIR"
    : > "$AWG_REPO_TX_DIR/manifest"
    _awg_repo_rollback() { return 1; }

    run _awg_repo_abort
    assert_failure
    assert_output --partial 'Откат sources/keyring выполнен не полностью'
    [[ -d "$AWG_REPO_TX_DIR" ]]
}

@test "dependencies installed by bootstrap survive later fingerprint and DKMS failures" {
    local mode
    _simulate_missing_gpg
    for mode in fingerprint dkms; do
        rm -rf "$AWG_MODULES_ROOT/$MOCK_KERNEL/build"
        rm -f "$MOCK_STATE/gpg.available"
        : > "$MOCK_CALLS"
        export MOCK_HEADERS=0 MOCK_FINGERPRINT=75C9DD72C799870E310542E24166F2C257290828
        export MOCK_MODINFO_FAIL=0 AWG_APT_SUITE=focal AWG_ARCH=amd64
        _seed_old_repo_state
        if [[ "$mode" == fingerprint ]]; then
            export MOCK_FINGERPRINT=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            run _awg_install_repository
        else
            export MOCK_MODINFO_FAIL=1
            run _awg_ensure_packages
        fi

        assert_failure
        [[ -f "$MOCK_STATE/gpg.available" ]]
        [[ -d "$AWG_MODULES_ROOT/$MOCK_KERNEL/build" ]]
        ! grep -Eq '^apt-get (remove|purge)' "$MOCK_CALLS"
        _assert_old_repo_state_restored
    done
}

@test "PPA key fingerprint is verified and keyring/source are installed atomically without duplicates" {
    AWG_APT_SUITE=focal
    cat > "$AWG_APT_SOURCES_LIST" <<EOF
deb $AWG_PPA_URI focal main
deb https://deb.debian.org/debian bookworm main
EOF
    cat > "$AWG_APT_SOURCES_DIR/legacy.list" <<EOF
deb-src $AWG_PPA_URI focal main
EOF
    cat > "$AWG_APT_SOURCES_DIR/mixed.sources" <<EOF
Types: deb
URIs: $AWG_PPA_URI https://example.invalid/repo
Suites: focal
Components: main
EOF

    run _awg_install_repository
    assert_success
    grep -qxF 'mock public key' "$AWG_APT_KEYRING"
    grep -qxF 'Types: deb deb-src' "$AWG_APT_SOURCE"
    grep -qxF "Suites: focal" "$AWG_APT_SOURCE"
    grep -qxF "Signed-By: $AWG_APT_KEYRING" "$AWG_APT_SOURCE"
    grep -q 'deb.debian.org' "$AWG_APT_SOURCES_LIST"
    ! grep -Fq "$AWG_PPA_URI" "$AWG_APT_SOURCES_LIST"
    ! grep -Fq "$AWG_PPA_URI" "$AWG_APT_SOURCES_DIR/legacy.list"
    grep -q '^URIs: https://example.invalid/repo$' "$AWG_APT_SOURCES_DIR/mixed.sources"
    [[ "$(grep -RhoF "$AWG_PPA_URI" "$AWG_TEST_ROOT/etc/apt" | wc -l)" -eq 1 ]]
    [[ -z "$(find "$AWG_TEST_ROOT/etc/apt" -name '.amnezia.gpg.*' -o -name '.amnezia.sources.*')" ]]
}

@test "wrong PPA fingerprint leaves an existing keyring untouched" {
    mkdir -p "$(dirname "$AWG_APT_KEYRING")"
    echo old-keyring > "$AWG_APT_KEYRING"
    export MOCK_FINGERPRINT=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA

    run _awg_install_repository
    assert_failure
    assert_output --partial "Fingerprint"
    assert_equal "$(<"$AWG_APT_KEYRING")" "old-keyring"
}

@test "missing APT candidate rolls back source and keyring created by this run" {
    echo 'deb https://deb.debian.org/debian bookworm main' > "$AWG_APT_SOURCES_LIST"
    export AWG_APT_SUITE=focal AWG_ARCH=amd64 AWG_KERNEL="$MOCK_KERNEL" MOCK_CANDIDATE=""

    run _awg_ensure_packages
    assert_failure
    assert_output --partial "APT candidate"
    [[ ! -e "$AWG_APT_KEYRING" ]]
    [[ ! -e "$AWG_APT_SOURCE" ]]
    grep -q 'deb.debian.org' "$AWG_APT_SOURCES_LIST"
}

@test "apt update/install, DKMS and modprobe failures return nonzero and rollback repository" {
    local mode
    for mode in update install modinfo modprobe; do
        export MOCK_APT_UPDATE_FAIL=0 MOCK_APT_INSTALL_FAIL=0 MOCK_MODINFO_FAIL=0 MOCK_MODPROBE_FAIL=0
        rm -f "$AWG_APT_KEYRING" "$AWG_APT_SOURCE"
        case "$mode" in
            update) export MOCK_APT_UPDATE_FAIL=1 ;;
            install) export MOCK_APT_INSTALL_FAIL=1 ;;
            modinfo) export MOCK_MODINFO_FAIL=1 ;;
            modprobe) export MOCK_MODPROBE_FAIL=1 ;;
        esac
        AWG_APT_SUITE=focal AWG_ARCH=amd64 AWG_KERNEL="$MOCK_KERNEL"
        run _awg_ensure_packages
        assert_failure
        [[ ! -e "$AWG_APT_KEYRING" ]]
        [[ ! -e "$AWG_APT_SOURCE" ]]
    done
}

@test "apt-lock abort inside install_awg returns to caller instead of exiting the shell" {
    _mock_install_prerequisites
    _awg_ensure_packages() { _awg_apt_lock_menu <<< '3'; }
    run _run_install_with_sentinel
    assert_output --partial "INSTALL_RC=1"
    assert_output --partial "SENTINEL_AFTER_INSTALL"
}

@test "gnupg bootstrap failure inside install_awg restores repository and reaches sentinel" {
    _mock_install_environment
    _seed_old_repo_state
    _simulate_missing_gpg
    export MOCK_APT_UPDATE_FAIL=1

    run _run_install_with_sentinel
    assert_output --partial "INSTALL_RC=1"
    assert_output --partial "SENTINEL_AFTER_INSTALL"
    _assert_old_repo_state_restored
}

@test "Mihomo validation failure happens before old AWG is stopped and before late writes" {
    _mock_install_prerequisites
    export MOCK_MIHOMO_FAIL=1
    cp "$AWG_CLIENT_CONFIG" "$BATS_TEST_TMPDIR/client.before"

    run _run_install_with_sentinel
    assert_output --partial "INSTALL_RC=1"
    ! grep -q 'systemctl stop awg-quick@awg0' "$MOCK_CALLS"
    ! grep -q '^ufw allow' "$MOCK_CALLS"
    cmp -s "$AWG_CLIENT_CONFIG" "$BATS_TEST_TMPDIR/client.before"
    [[ -f "$AWG_CONF" ]]
    [[ "$(_file_mode "$AWG_CONF")" == 600 ]]
}

@test "systemd failure does not perform late UFW or client-config changes" {
    _mock_install_prerequisites
    export MOCK_SYSTEMCTL_FAIL_UNIT=awg-quick@awg0
    cp "$AWG_CLIENT_CONFIG" "$BATS_TEST_TMPDIR/client.before"

    run _run_install_with_sentinel
    assert_output --partial "INSTALL_RC=1"
    ! grep -q '^ufw allow' "$MOCK_CALLS"
    cmp -s "$AWG_CLIENT_CONFIG" "$BATS_TEST_TMPDIR/client.before"
    [[ -f "$AWG_CONF" ]]
}

@test "first-install UFW failure restores Mihomo/client/unit/firewall and keeps diagnostic AWG config" {
    _mock_install_prerequisites
    export MOCK_UFW_FAIL=1
    cp "$AWG_MIHOMO_CONFIG" "$BATS_TEST_TMPDIR/mihomo.before"
    cp "$AWG_CLIENT_CONFIG" "$BATS_TEST_TMPDIR/client.before"

    run _run_install_with_sentinel
    assert_output --partial "INSTALL_RC=1"
    cmp -s "$AWG_MIHOMO_CONFIG" "$BATS_TEST_TMPDIR/mihomo.before"
    cmp -s "$AWG_CLIENT_CONFIG" "$BATS_TEST_TMPDIR/client.before"
    [[ ! -s "$MOCK_STATE/ufw.rules" ]]
    [[ ! -e "$MOCK_STATE/active.awg-quick_awg0" ]]
    [[ -f "$AWG_CONF" ]]
    [[ "$(_file_mode "$AWG_CONF")" == 600 ]]
}

@test "reinstall failure restores old config, keys, peers, clients, firewall and service state" {
    _mock_install_prerequisites
    mkdir -p "$AWG_DIR" "$AWG_CLIENTS_DIR/old-peer"
    cat > "$AWG_CONF" <<'EOF'
[Interface]
PrivateKey = old-private
ListenPort = 39999

# peer: old-peer
[Peer]
PublicKey = old-peer-key
AllowedIPs = 10.10.8.2/32
EOF
    echo old-private > "$AWG_DIR/server_private.key"
    echo old-public > "$AWG_DIR/server_public.key"
    echo old-psk > "$AWG_DIR/psk.key"
    echo old-client > "$AWG_CLIENTS_DIR/old-peer/old-peer.conf"
    echo 39999/udp > "$MOCK_STATE/ufw.rules"
    touch "$MOCK_STATE/active.awg-quick_awg0" "$MOCK_STATE/enabled.awg-quick_awg0"
    cp -a "$AWG_DIR" "$BATS_TEST_TMPDIR/awg.before"
    cp -a "$AWG_CLIENTS_DIR" "$BATS_TEST_TMPDIR/clients.before"
    cp "$AWG_MIHOMO_CONFIG" "$BATS_TEST_TMPDIR/mihomo.before"
    cp "$AWG_CLIENT_CONFIG" "$BATS_TEST_TMPDIR/client.before"
    export MOCK_SYSTEMCTL_FAIL_UNIT=awg-quick@awg0

    run _run_install_with_sentinel
    assert_output --partial "INSTALL_RC=1"
    diff -ru "$BATS_TEST_TMPDIR/awg.before" "$AWG_DIR"
    diff -ru "$BATS_TEST_TMPDIR/clients.before" "$AWG_CLIENTS_DIR"
    cmp -s "$AWG_MIHOMO_CONFIG" "$BATS_TEST_TMPDIR/mihomo.before"
    cmp -s "$AWG_CLIENT_CONFIG" "$BATS_TEST_TMPDIR/client.before"
    grep -qxF '39999/udp' "$MOCK_STATE/ufw.rules"
    [[ -e "$MOCK_STATE/active.awg-quick_awg0" ]]
    [[ -e "$MOCK_STATE/enabled.awg-quick_awg0" ]]
}

@test "successful install starts awg0 before writing client info and UFW" {
    _mock_install_prerequisites

    run _run_install_with_sentinel
    assert_output --partial "INSTALL_RC=0"
    [[ -f "$AWG_CONF" ]]
    grep -q '^tproxy-port: 12000$' "$AWG_MIHOMO_CONFIG"
    grep -q '^--- AmneziaWG ---$' "$AWG_CLIENT_CONFIG"
    grep -qxF '41000/udp' "$MOCK_STATE/ufw.rules"
    [[ -e "$MOCK_STATE/active.awg-quick_awg0" ]]
    local restart_line allow_line
    restart_line=$(grep -n 'systemctl restart awg-quick@awg0' "$MOCK_CALLS" | head -1 | cut -d: -f1)
    allow_line=$(grep -n '^ufw allow 41000/udp' "$MOCK_CALLS" | head -1 | cut -d: -f1)
    (( restart_line < allow_line ))
}
