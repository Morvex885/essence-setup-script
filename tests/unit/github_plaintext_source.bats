#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env

    export APP="$BATS_TEST_TMPDIR/app"
    export HOME="$BATS_TEST_TMPDIR/home"
    export BIN="$BATS_TEST_TMPDIR/bin"
    export REMOTE="$BATS_TEST_TMPDIR/remote.git"
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    export GH_ACTIVE_LOGIN_FILE="$BATS_TEST_TMPDIR/gh-active-login"
    mkdir -p "$APP/modules" "$APP/templates" "$APP/common/protocols" "$BIN" "$HOME"
    printf '%s\n' test-owner > "$GH_ACTIVE_LOGIN_FILE"
    cp "$PROJECT_ROOT/remote-control/remote-control-essence.sh" "$APP/"
    cp "$PROJECT_ROOT/remote-control/modules/"*.sh "$APP/modules/"
    cp "$PROJECT_ROOT/remote-control/templates/"*.yaml "$APP/templates/"
    cp -R "$PROJECT_ROOT/common/." "$APP/common/"
    chmod +x "$APP/remote-control-essence.sh"

    cat > "$BIN/curl" <<'EOF'
#!/bin/bash
exit 1
EOF
    export TEST_REAL_OPENSSL
    TEST_REAL_OPENSSL=$(command -v openssl) || return 1
    cat > "$BIN/openssl" <<'EOF'
#!/bin/bash
if [[ "$1" == passwd && "$2" == -6 ]]; then
    shift 2
    salt=test
    password=
    while (( $# > 0 )); do
        if [[ "$1" == -salt ]]; then
            salt="$2"
            shift 2
        else
            password="$1"
            shift
        fi
    done
    if command -v sha256sum >/dev/null 2>&1; then
        digest=$(printf '%s' "$password" | sha256sum | cut -d' ' -f1)
    else
        digest=$(printf '%s' "$password" | shasum -a 256 | cut -d' ' -f1)
    fi
    printf '$6$%s$%s\n' "$salt" "$digest"
    exit 0
fi
exec "$TEST_REAL_OPENSSL" "$@"
EOF
    cat > "$BIN/gh" <<'EOF'
#!/bin/bash
if [[ -n "${GH_CALLS_FILE:-}" ]]; then
    printf '%s\n' "$*" >> "$GH_CALLS_FILE"
fi
if [[ "$1" == auth && "$2" == status ]]; then
    if [[ "${GH_MODE:-success}" == auth-fail ]]; then
        printf '%s\n' 'not logged in to github.com' >&2
        exit 1
    fi
    exit 0
fi
if [[ "$1" == auth && "$2" == switch ]]; then
    if [[ "${GH_MODE:-success}" == auth-switch-fail ]]; then
        printf '%s\n' 'switch failed: token=ghp_SwitchSecret123' >&2
        exit 1
    fi
    printf '%s\n' alternate-owner > "$GH_ACTIVE_LOGIN_FILE"
    [[ -z "${GH_SWITCH_MARKER:-}" ]] || touch "$GH_SWITCH_MARKER"
    exit 0
fi
if [[ "$1" == auth && "$2" == setup-git ]]; then
    exit 0
fi
if [[ "$1" == api && "$2" == user ]]; then
    if [[ "${GH_MODE:-success}" == api-timeout ]]; then
        printf '%s\n' 'connection timed out' >&2
        exit 28
    fi
    if [[ "${GH_MODE:-success}" == empty-login ]]; then
        exit 0
    fi
    if [[ "${GH_MODE:-success}" == wrong-account ]]; then
        count=0
        [[ -f "${GH_API_COUNT_FILE:-}" ]] && count=$(cat "$GH_API_COUNT_FILE")
        printf '%s\n' "$((count + 1))" > "$GH_API_COUNT_FILE"
        if (( count == 0 )); then
            printf '%s\n' test-owner
        else
            printf '%s\n' alternate-owner
        fi
        exit 0
    fi
    if [[ "${GH_MODE:-success}" == auth-fail ]]; then
        printf '%s\n' 'HTTP 401: Bad credentials' >&2
        exit 1
    fi
    cat "$GH_ACTIVE_LOGIN_FILE"
    exit 0
fi
if [[ "$1" == repo && "$2" == view ]]; then
    if [[ "${GH_MODE:-success}" == fail ]]; then
        printf '%s\n' 'permission denied' >&2
        exit 1
    fi
    if [[ "${GH_MODE:-success}" == secret-fail ]]; then
        printf '%s\n' 'permission denied: https://user:password@github.com token=ghp_SecretValue123456789 github_pat_SecretValue123456789' >&2
        exit 1
    fi
    if [[ "${GH_MODE:-success}" == missing ]]; then
        printf '%s\n' 'repository not found' >&2
        exit 1
    fi
    if [[ "${GH_MODE:-success}" == retry ]]; then
        count=0
        [[ -f "${GH_COUNT_FILE:-}" ]] && count=$(cat "$GH_COUNT_FILE")
        printf '%s\n' "$((count + 1))" > "$GH_COUNT_FILE"
        if (( count == 0 )); then
            printf '%s\n' 'permission denied' >&2
            exit 1
        fi
    fi
    if [[ "${GH_MODE:-success}" == reconnect &&
          ! -f "${GH_REPO_STATE_FILE:-}" ]]; then
        printf '%s\n' 'repository not found' >&2
        exit 1
    fi
    printf '%s\n' '{"visibility":"PRIVATE"}'
    exit 0
fi
if [[ "$1" == repo && "$2" == create ]]; then
    if [[ -n "${GH_CREATE_COUNT_FILE:-}" ]]; then
        count=$(cat "$GH_CREATE_COUNT_FILE")
        printf '%s\n' "$((count + 1))" > "$GH_CREATE_COUNT_FILE"
        [[ -n "${GH_REPO_STATE_FILE:-}" ]] && touch "$GH_REPO_STATE_FILE"
    fi
    printf '%s\n' '{"visibility":"PRIVATE"}'
    exit 0
fi
if [[ "$1" == repo && "$2" == delete ]]; then
    [[ -z "${GH_DELETE_MARKER:-}" ]] || touch "$GH_DELETE_MARKER"
    if [[ "${GH_DELETE_FAIL:-false}" == true ]]; then
        printf '%s\n' 'delete failed: token=ghp_DeleteSecret123' >&2
        exit 1
    fi
    exit 0
fi
if [[ "$1" == browse && "$2" == --settings && "$3" == --repo ]]; then
    [[ -z "${GH_BROWSE_MARKER:-}" ]] || touch "$GH_BROWSE_MARKER"
    if [[ "${GH_BROWSE_FAIL:-false}" == true ]]; then
        exit 1
    fi
    exit 0
fi
exit 1
EOF
    chmod +x "$BIN/curl" "$BIN/gh" "$BIN/openssl"
    export PATH="$BIN:$PATH"

    git init --bare -b main "$REMOTE" >/dev/null
    local seed="$BATS_TEST_TMPDIR/seed"
    git init -b main "$seed" >/dev/null
    git -C "$seed" config user.name seed
    git -C "$seed" config user.email seed@example.invalid
    git -C "$seed" commit --allow-empty -m seed >/dev/null
    git -C "$seed" remote add origin "$REMOTE"
    git -C "$seed" push origin main >/dev/null
    git config --global url."file://$REMOTE".insteadOf \
        "https://github.com/test-owner/essence-remote-control-config.git"
}

teardown() {
    PATH="${PATH#"$BIN:"}"
    export PATH
    hash -r
    teardown_test_env
}
_hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

_file_mode() {
    case "${OSTYPE:-}" in
        darwin*) stat -f '%Lp' "$1" ;;
        *) stat -c '%a' "$1" ;;
    esac
}

_runtime_fingerprint() {
    local root="$1" path rel mode hash
    [[ -d "$root" ]] || return 1
    printf 'd %s .\n' "$(_file_mode "$root")" || return 1
    while IFS= read -r path; do
        rel="${path#"$root"/}"
        if [[ -L "$path" ]]; then
            printf 'l %s %s\n' "$(readlink "$path")" "$rel" || return 1
        else
            mode=$(_file_mode "$path") || return 1
            if [[ -d "$path" ]]; then
                printf 'd %s %s\n' "$mode" "$rel" || return 1
            elif [[ -f "$path" ]]; then
                hash=$(_hash_file "$path") || return 1
                printf 'f %s %s %s\n' "$mode" "$hash" "$rel" || return 1
            else
                printf 'x %s %s\n' "$mode" "$rel" || return 1
            fi
        fi
    done < <(find "$root" -mindepth 1 -print | LC_ALL=C sort)
}


@test "runtime fingerprint records symlinks without dereferencing them" {
    local root="$BATS_TEST_TMPDIR/fingerprint-root"
    mkdir -p "$root" || return 1
    printf 'fingerprint-target\n' > "$root/target" || return 1
    ln -s target "$root/link" || return 1

    run _runtime_fingerprint "$root"
    assert_success
    assert_output --partial $'l target link'
    ! printf '%s\n' "$output" | grep -Eq '^f [0-9]+ [0-9a-f]+ link$'
}
_materialization_temp_inventory() {
    local config_dir="$1"
    find "$config_dir" -mindepth 1 -maxdepth 1 \
        \( -name '.github-runtime.*' -o -name 'github-runtime.tmp.*' \
           -o -name '.auth.*' -o -name '.runtime-vault.*' \
           -o -name 'runtime-vault.json.tmp.*' -o -name '.materialize.*' \) \
        -print | LC_ALL=C sort
}

_assert_runtime_secure_modes() {
    local runtime="$1" id="$2" path mode
    while IFS= read -r path; do
        mode=$(_file_mode "$path") || return 1
        if [[ "$mode" != 700 ]]; then
            printf '# insecure directory mode: %s %s\n' "$mode" "$path" >&3
            return 1
        fi
    done < <(find "$runtime" -type d -print)
    mode=$(_file_mode "$runtime/secrets.json") || return 1
    if [[ "$mode" != 600 ]]; then
        printf '# insecure secrets mode: %s\n' "$mode" >&3
        return 1
    fi
    mode=$(_file_mode "$runtime/ssh/identities/$id") || return 1
    if [[ "$mode" != 600 ]]; then
        printf '# insecure private identity mode: %s\n' "$mode" >&3
        return 1
    fi
}


_establish_materialization_source() {
    local password_hash
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    _publish_key_node_state ready || return 1
    password_hash=$(openssl passwd -6 -salt fixture secret-pass) || return 1
    _publish_remote_access_hash "$password_hash" || return 1
    run bash -c 'printf "secret-pass\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success

    MATERIALIZE_CONFIG_DIR="$HOME/.config/remote-control-essence"
    MATERIALIZE_RUNTIME="$MATERIALIZE_CONFIG_DIR/github-runtime"
    MATERIALIZE_ID=0123456789abcdef0123456789abcdef
    export MATERIALIZE_CONFIG_DIR MATERIALIZE_RUNTIME MATERIALIZE_ID
    [[ -f "$MATERIALIZE_RUNTIME/ssh/identities/$MATERIALIZE_ID" ]] || return 1
    [[ -f "$MATERIALIZE_CONFIG_DIR/.auth" ]] || return 1
    _assert_runtime_secure_modes "$MATERIALIZE_RUNTIME" "$MATERIALIZE_ID" || return 1
    [[ "$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth")" == 600 ]] || return 1
}

_publish_remote_access_null() {
    local marker="$1"
    local updater="$BATS_TEST_TMPDIR/access-null-$marker"
    git clone "$REMOTE" "$updater" >/dev/null || return 1
    git -C "$updater" config user.name updater || return 1
    git -C "$updater" config user.email updater@example.invalid || return 1
    jq --arg marker "$marker" '.marker=$marker' "$updater/config.json" \
        > "$updater/config.json.tmp" || return 1
    mv "$updater/config.json.tmp" "$updater/config.json" || return 1
    jq '.access.script_password_hash=null' "$updater/manifest.json" \
        > "$updater/manifest.json.tmp" || return 1
    mv "$updater/manifest.json.tmp" "$updater/manifest.json" || return 1
    git -C "$updater" add config.json manifest.json || return 1
    git -C "$updater" commit -m "access-null-$marker" >/dev/null || return 1
    git -C "$updater" push origin main >/dev/null || return 1
}

_publish_remote_access_hash() {
    local password_hash="$1" updater="$BATS_TEST_TMPDIR/access-hash"
    git clone "$REMOTE" "$updater" >/dev/null || return 1
    git -C "$updater" config user.name updater || return 1
    git -C "$updater" config user.email updater@example.invalid || return 1
    jq --arg password_hash "$password_hash" \
        '.access.script_password_hash=$password_hash' "$updater/manifest.json" \
        > "$updater/manifest.json.tmp" || return 1
    mv "$updater/manifest.json.tmp" "$updater/manifest.json" || return 1
    git -C "$updater" add manifest.json || return 1
    git -C "$updater" commit -m access-hash >/dev/null || return 1
    git -C "$updater" push origin main >/dev/null || return 1
}

_install_materialization_fault_wrappers() {
    export REAL_JQ REAL_CP REAL_CHMOD REAL_MV REAL_RM
    REAL_JQ=$(command -v jq) || return 1
    REAL_CP=$(command -v cp) || return 1
    REAL_CHMOD=$(command -v chmod) || return 1
    REAL_MV=$(command -v mv) || return 1
    REAL_RM=$(command -v rm) || return 1
    cat > "$BIN/jq" <<'EOF'
#!/bin/bash
is_config_filter=false
is_runtime_input=false
for arg in "$@"; do
    [[ "$arg" == .config ]] && is_config_filter=true
    [[ "$arg" == "$MATERIALIZE_CONFIG_DIR"/*vault* ]] && is_runtime_input=true
done
if [[ "${MATERIALIZE_FAULT:-}" == jq &&
      "$is_config_filter" == true && "$is_runtime_input" == true ]]; then
    printf 'jq\n' >> "$MATERIALIZE_FAULT_MARKER"
    exit 81
fi
exec "$REAL_JQ" "$@"
EOF
    cat > "$BIN/cp" <<'EOF'
#!/bin/bash
if [[ "${MATERIALIZE_FAULT:-}" == cp ]]; then
    for arg in "$@"; do
        if [[ "$arg" == *github-runtime* ]]; then
            printf 'cp\n' >> "$MATERIALIZE_FAULT_MARKER"
            exit 82
        fi
    done
fi
exec "$REAL_CP" "$@"
EOF
    cat > "$BIN/chmod" <<'EOF'
#!/bin/bash
if [[ "${MATERIALIZE_FAULT:-}" == chmod ]]; then
    for arg in "$@"; do
        if [[ "$arg" == *github-runtime* ]]; then
            printf 'chmod\n' >> "$MATERIALIZE_FAULT_MARKER"
            exit 83
        fi
    done
fi
exec "$REAL_CHMOD" "$@"
EOF
    cat > "$BIN/mv" <<'EOF'
#!/bin/bash
if [[ "${MATERIALIZE_FAULT:-}" == auth-rollback &&
      "${1:-}" == "$MATERIALIZE_CONFIG_DIR"/.auth.backup.* &&
      "${2:-}" == "$MATERIALIZE_CONFIG_DIR/.auth" ]]; then
    printf 'auth-restore-fail\n' >> "$MATERIALIZE_FAULT_MARKER"
    exit 89
fi
if [[ "${MATERIALIZE_FAULT:-}" == runtime-rollback &&
      "${1:-}" == "$MATERIALIZE_CONFIG_DIR"/.github-runtime.publish.* &&
      "${2:-}" == "$MATERIALIZE_RUNTIME" ]]; then
    printf 'publish-fail\n' >> "$MATERIALIZE_FAULT_MARKER"
    exit 86
fi
if [[ "${MATERIALIZE_FAULT:-}" == runtime-rollback &&
      "${1:-}" == "$MATERIALIZE_CONFIG_DIR"/.github-runtime.retired.* &&
      "${2:-}" == "$MATERIALIZE_RUNTIME" ]]; then
    printf 'runtime-restore-fail\n' >> "$MATERIALIZE_FAULT_MARKER"
    exit 87
fi
if [[ "${MATERIALIZE_FAULT:-}" == mv ]]; then
    for arg in "$@"; do
        if [[ "$arg" == *github-runtime* ]]; then
            printf 'mv\n' >> "$MATERIALIZE_FAULT_MARKER"
            exit 84
        fi
    done
fi
exec "$REAL_MV" "$@"
EOF
    cat > "$BIN/rm" <<'EOF'
#!/bin/bash
if [[ "${MATERIALIZE_FAULT:-}" == auth-rollback ]]; then
    for arg in "$@"; do
        if [[ "$arg" == "$MATERIALIZE_CONFIG_DIR/.auth" ]]; then
            printf 'auth-rm\n' >> "$MATERIALIZE_FAULT_MARKER"
            exit 88
        fi
    done
fi
if [[ "${MATERIALIZE_FAULT:-}" == auth-rm ]]; then
    for arg in "$@"; do
        if [[ "$arg" == "$MATERIALIZE_CONFIG_DIR/.auth" ]]; then
            printf 'auth-rm\n' >> "$MATERIALIZE_FAULT_MARKER"
            exit 85
        fi
    done
fi
exec "$REAL_RM" "$@"
EOF
    chmod +x "$BIN/jq" "$BIN/cp" "$BIN/chmod" "$BIN/mv" "$BIN/rm" || return 1
}

_publish_key_node_state() {
    local mode="$1"
    local updater="$BATS_TEST_TMPDIR/updater-$mode"
    local node_id=0123456789abcdef0123456789abcdef
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    mkdir -p "$updater/ssh/identities"
    jq --arg id "$node_id" --arg mode "$mode" '
        .nodes=[{
          id:$id,name:"ssh-node",ip:"127.0.0.1",port:22,user:"root",
          auth:"key",identity:(if $mode=="ready" then $id else "system" end),
          secret_id:null,tag:"TEST",aliases:{}
        }]
    ' "$updater/config.json" > "$updater/config.json.tmp" &&
        mv "$updater/config.json.tmp" "$updater/config.json"
    if [[ "$mode" == ready ]]; then
        ssh-keygen -t ed25519 -N '' -q -f "$updater/ssh/identities/$node_id"
        local key_type key_data _
        read -r key_type key_data _ < "$updater/ssh/identities/$node_id.pub"
        printf '127.0.0.1 %s %s\n' "$key_type" "$key_data" \
            > "$updater/ssh/known_hosts"
        jq '.portability={status:"ready",issues:[]}' \
            "$updater/manifest.json" > "$updater/manifest.json.tmp" &&
            mv "$updater/manifest.json.tmp" "$updater/manifest.json"
    else
        rm -f "$updater/ssh/identities/"*
        : > "$updater/ssh/known_hosts"
        jq --arg id "$node_id" \
            '.portability={status:"needs_setup",issues:[
              {node_id:$id,reason:"missing_identity"},
              {node_id:$id,reason:"missing_host_key"}
            ]}' "$updater/manifest.json" > "$updater/manifest.json.tmp" &&
            mv "$updater/manifest.json.tmp" "$updater/manifest.json"
    fi
    git -C "$updater" add config.json manifest.json ssh
    git -C "$updater" commit -m "$mode-node" >/dev/null
    git -C "$updater" push origin main >/dev/null
}

_install_fake_age() {
    cat > "$BIN/age-keygen" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-y" ]]; then
    printf '%s\n' age1testrecipient
else
    printf '%s\n' '# public key: age1testrecipient'
    printf '%s\n' 'AGE-SECRET-KEY-TEST'
fi
EOF
    cat > "$BIN/age" <<'EOF'
#!/bin/bash
out="" input="" decrypting=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) decrypting=true; shift ;;
        -p)
            if [[ "$decrypting" == true && -n "${AGE_PASSWORD_DECRYPT_MARKER:-}" ]]; then
                printf '%s\n' unlock >> "$AGE_PASSWORD_DECRYPT_MARKER"
            fi
            shift ;;
        -r|-i) shift 2 ;;
        -o) out="$2"; shift 2 ;;
        *) input="$1"; shift ;;
    esac
done
[[ -n "$out" && -n "$input" ]] || exit 1
cp "$input" "$out"
EOF
    chmod +x "$BIN/age" "$BIN/age-keygen"
}
_set_local_marker() {
    local config_dir="$1" marker="$2" tmp="$BATS_TEST_TMPDIR/config-marker.tmp"
    jq --arg marker "$marker" '.marker=$marker' "$config_dir/config.json" > "$tmp" &&
        mv "$tmp" "$config_dir/config.json"
}

_publish_plain_marker() {
    local marker="$1"
    local updater="$BATS_TEST_TMPDIR/plain-marker-$marker"
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    jq --arg marker "$marker" '.marker=$marker' "$updater/config.json" \
        > "$updater/config.json.tmp" && mv "$updater/config.json.tmp" "$updater/config.json"
    git -C "$updater" add config.json
    git -C "$updater" commit -m "marker-$marker" >/dev/null
    git -C "$updater" push origin main >/dev/null
}


_prepare_existing_plaintext_vault() {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    _set_local_marker "$config_dir" local
    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\nE\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
}



@test "first local source selection does not probe GitHub" {
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"

    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"

    assert_success
    assert_output --partial "Источник конфигурации"
    assert_output --partial "Essence Remote Management"
    [[ ! -s "$GH_CALLS_FILE" ]] || return 1
    [[ "$output" != *"Не удалось открыть источник GitHub"* ]] || return 1
}

@test "plaintext GitHub source persists and restarts from installed layout" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    [[ "$output" == *$'\033[0;32m1)\033[0m Хранить конфигурацию только на этом компьютере'* ]] || return 1
    [[ "$output" == *$'\033[0;36m2)\033[0m Синхронизировать конфигурацию через GitHub'* ]] || return 1

    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    local github_link=$'\033]8;;https://github.com/test-owner/essence-remote-control-config\033\\GitHub\033]8;;\033\\'
    assert_output --partial "Источник GitHub подключён."
    assert_output --partial "GitHub-аккаунт для репозитория конфигурации: test-owner"
    [[ "$output" == *"Источник конфигурации: ${github_link}"* ]] || return 1
    jq -e 'type == "object" and .type == "github" and .private_verified == true' \
        "$config_dir/source.json"
    [[ "$(git --git-dir="$config_dir/github-store.git" show main:storage.json | jq -r '.encryption')" == none ]] || return 1
    [[ "$(git --git-dir="$REMOTE" show main:storage.json | jq -r '.encryption')" == none ]] || return 1
    local rel
    for rel in storage.json config.json secrets.json manifest.json templates/default.yaml; do
        cmp <(git --git-dir="$config_dir/github-store.git" show "main:$rel") \
            <(git --git-dir="$REMOTE" show "main:$rel")
    done
    local session_worktree_found=false session_worktree
    for session_worktree in "$config_dir"/github-sessions/*/worktree; do
        [[ -d "$session_worktree" ]] && session_worktree_found=true
    done
    [[ "$session_worktree_found" == false ]] || return 1
    [[ -f "$config_dir/github-runtime/config.json" ]] || return 1

    run bash -c 'printf "Y\n0\n0\n" | "$0"' "$APP/remote-control-essence.sh"

    assert_success
    assert_output --partial "Источник конфигурации: ${github_link} • синхронизировано"
    [[ "$output" != *"GitHub-аккаунт для репозитория конфигурации: test-owner"* ]] || return 1
    [[ "$output" != *"Завершить отложенную SSH-настройку"* ]] || return 1
    assert_output --partial "Источник конфигурации GitHub"
    assert_output --partial "Состояние синхронизации: синхронизировано"
    [[ "$output" == *$'\033[0;36mF)\033[0m Загрузить конфигурацию из GitHub'* ]] || return 1
    [[ "$output" == *$'\033[0;32mP)\033[0m Отправить локальную конфигурацию в GitHub'* ]] || return 1
    [[ "$output" != *"Сменить пароль доступа"* ]] || return 1
    [[ "$output" != *"Создать новый ключ шифрования"* ]] || return 1
    [[ "$output" != *"Импортировать ключ восстановления"* ]] || return 1
    [[ "$output" != *"Текущая конфигурация будет зашифрована заново"* ]] || return 1
    [[ "$output" != *"Старые версии в GitHub потребуют прежний ключ"* ]] || return 1
    [[ "$output" != *"Пароли нод при этом не меняются"* ]] || return 1
    [[ "$output" == *$'\033[0;31mE)\033[0m Использовать локальную конфигурацию без синхронизации с GitHub'* ]] || return 1
    assert_output --partial " 0) Назад"
    [[ -f "$config_dir/github-runtime/config.json" ]] || return 1
    run bash -c 'printf "0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local plain_output="$output"
    plain_output=$(printf '%s\n' "$plain_output" | sed $'s/\033\\[[0-9;]*m//g')
    local marker remaining="$plain_output"
    for marker in \
        "S) Подписки" \
        "Y) Источник конфигурации: ${github_link} • синхронизировано" \
        "U) Обновить скрипт" \
        "L) Пароль скрипта" \
        "R) Удалить remote-control" \
        "0) Выход"; do
        [[ "$remaining" == *"$marker"* ]] || return 1
        remaining=${remaining#*"$marker"}
    done

    run bash -c 'printf "Y\nR\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Неверный выбор."
    [[ "$output" != *"Текущий пароль доступа"* ]] || return 1
}

@test "encrypted GitHub menu shows password key and recovery actions" {
    _install_fake_age
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success

    local updater="$BATS_TEST_TMPDIR/age-updater"
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    jq -n --slurpfile config "$updater/config.json" \
        --slurpfile secrets "$updater/secrets.json" \
        --slurpfile manifest "$updater/manifest.json" \
        --rawfile template "$updater/templates/default.yaml" '
        {
          vault_version:1,
          minimum_remote_control_version:"0.0.0",
          portability:$manifest[0].portability,
          access:$manifest[0].access,
          config:$config[0],
          secrets:$secrets[0],
          templates:{"default.yaml":(($manifest[0].templates["default.yaml"] // {}) + {content:$template})},
          ssh:{identities:{},known_hosts:""}
        }
    ' > "$updater/state.json.age"
    printf '%s\n' '{"storage_version":1,"encryption":"age"}' > "$updater/storage.json"
    printf '%s\n' age1testrecipient > "$updater/recipient.txt"
    printf '%s\n' AGE-SECRET-KEY-TEST > "$updater/unlock.age"
    rm -f "$updater/config.json" "$updater/secrets.json" "$updater/manifest.json"
    rm -rf "$updater/templates" "$updater/ssh"
    git -C "$updater" add -A
    git -C "$updater" commit -m encrypted-state >/dev/null
    git -C "$updater" push origin main >/dev/null

    run bash -c 'printf "access-pass\nn\nY\n0\n0\n" | "$0"' \
        "$APP/remote-control-essence.sh"
    assert_success
    [[ "$output" == *$'\033[1;33mR)\033[0m Сменить пароль доступа'* ]] || return 1
    assert_output --partial "ключ останется прежним"
    [[ "$output" == *$'\033[1;33mV)\033[0m Создать новый ключ шифрования'* ]] || return 1
    assert_output --partial "Текущая конфигурация будет зашифрована заново"
    assert_output --partial "Старые версии в GitHub потребуют прежний ключ"
    assert_output --partial "Пароли нод при этом не меняются"
    [[ "$output" == *$'\033[1;33mI)\033[0m Импортировать ключ восстановления'* ]] || return 1
}

@test "encrypted GitHub menu reports empty diagnostics for every failed action" {
    _install_fake_age
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success

    local updater="$BATS_TEST_TMPDIR/empty-diagnostic-age-updater"
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    jq -n --slurpfile config "$updater/config.json" \
        --slurpfile secrets "$updater/secrets.json" \
        --slurpfile manifest "$updater/manifest.json" \
        --rawfile template "$updater/templates/default.yaml" '
        {
          vault_version:1,
          minimum_remote_control_version:"0.0.0",
          portability:$manifest[0].portability,
          access:$manifest[0].access,
          config:$config[0],
          secrets:$secrets[0],
          templates:{"default.yaml":(($manifest[0].templates["default.yaml"] // {}) + {content:$template})},
          ssh:{identities:{},known_hosts:""}
        }
    ' > "$updater/state.json.age"
    printf '%s\n' '{"storage_version":1,"encryption":"age"}' > "$updater/storage.json"
    printf '%s\n' age1testrecipient > "$updater/recipient.txt"
    printf '%s\n' AGE-SECRET-KEY-TEST > "$updater/unlock.age"
    rm -f "$updater/config.json" "$updater/secrets.json" "$updater/manifest.json"
    rm -rf "$updater/templates" "$updater/ssh"
    git -C "$updater" add -A
    git -C "$updater" commit -m empty-diagnostic-encrypted-state >/dev/null
    git -C "$updater" push origin main >/dev/null

    cat >> "$APP/modules/github-config.sh" <<'EOF'
github_config_rewrap_master() { _github_clear_error; return 1; }
github_config_rotate_vault_key() { _github_clear_error; return 1; }
github_config_import_recovery() { _github_clear_error; return 1; }
github_config_switch_local() { _github_clear_error; return 1; }
EOF

    run bash -c 'printf "access-pass\nn\nY\nR\nY\nV\nY\nI\n/tmp/missing-recovery-key\nY\nE\n0\n" | "$0"' \
        "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Не удалось изменить пароль доступа."
    assert_output --partial "Не удалось создать новый ключ шифрования."
    assert_output --partial "Не удалось импортировать ключ восстановления."
    assert_output --partial "Не удалось перейти на локальную конфигурацию."
    assert_output --partial "Выход."
}
@test "ready GitHub state with nodes does not show deferred SSH action" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    _publish_key_node_state ready

    run bash -c 'printf "0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "ssh-node"
    [[ "$output" != *"Завершить отложенную SSH-настройку"* ]] || return 1
}

@test "deferred SSH action is visible only until mocked setup resolves issues" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    _publish_key_node_state needs-setup

    local scan_key="$BATS_TEST_TMPDIR/scan-key" key_type key_data _
    ssh-keygen -t ed25519 -N '' -q -f "$scan_key"
    read -r key_type key_data _ < "$scan_key.pub"
    export SSH_SCAN_FILE="$BATS_TEST_TMPDIR/ssh-scan"
    printf '127.0.0.1 %s %s\n' "$key_type" "$key_data" > "$SSH_SCAN_FILE"
    cat > "$BIN/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' ok
EOF
    cat > "$BIN/ssh-keyscan" <<'EOF'
#!/bin/bash
cat "$SSH_SCAN_FILE"
EOF
    chmod +x "$BIN/ssh" "$BIN/ssh-keyscan"

    run bash -c 'printf "H\ny\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    [[ "$output" == *$'\033[1;33mH)\033[0m Завершить отложенную SSH-настройку нод'* ]] || return 1
    assert_output --partial "Отложенная SSH-настройка нод завершена"
    local action_count
    action_count=$(printf '%s' "$output" |
        grep -o 'Завершить отложенную SSH-настройку нод' | wc -l | tr -d ' ')
    [[ "$action_count" == 1 ]] || return 1

    run bash -c 'printf "0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    [[ "$output" != *"Завершить отложенную SSH-настройку"* ]] || return 1
    [[ "$(git --git-dir="$REMOTE" show main:manifest.json |
        jq -r '.portability.status')" == ready ]] || return 1
}

@test "direct GitHub selection initializes local recovery and empty plaintext repository" {
    git --git-dir="$REMOTE" update-ref -d refs/heads/main

    run bash -c 'printf "2\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"

    assert_success
    assert_output --partial "Источник GitHub подключён."
    [[ "$output" != *"jq: error"* ]] || return 1
    [[ "$output" != *"Не удалось выбрать источник конфигурации."* ]] || return 1
    local config_dir="$HOME/.config/remote-control-essence"
    jq -e 'type == "object" and .schema_version == 2' "$config_dir/config.json"
    jq -e 'type == "object" and .schema_version == 2' \
        "$config_dir/github-runtime/config.json"
    jq -e 'type == "object" and .encryption == "none"' \
        <(git --git-dir="$REMOTE" show main:storage.json)
    jq -e 'type == "object" and .schema_version == 2' \
        <(git --git-dir="$REMOTE" show main:config.json)
}

@test "direct GitHub replacement on a new device commits default local recovery" {
    _prepare_existing_plaintext_vault
    local old_remote
    old_remote=$(git --git-dir="$REMOTE" rev-parse main)
    rm -rf "$HOME/.config/remote-control-essence"

    run bash -c 'printf "2\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"

    assert_success
    assert_output --partial "Источник GitHub подключён."
    [[ "$output" != *"jq: error"* ]] || return 1
    [[ "$output" != *"Не удалось выбрать источник конфигурации."* ]] || return 1
    local config_dir="$HOME/.config/remote-control-essence" new_remote
    new_remote=$(git --git-dir="$REMOTE" rev-parse main)
    [[ "$new_remote" != "$old_remote" ]] || return 1
    git --git-dir="$REMOTE" merge-base --is-ancestor "$old_remote" "$new_remote"
    jq -e 'type == "object" and .schema_version == 2' \
        <(git --git-dir="$REMOTE" show main:config.json)
    jq -e 'type == "object" and .schema_version == 2' \
        "$config_dir/github-runtime/config.json"
    jq -e '.type == "github" and .repo == "test-owner/essence-remote-control-config" and .private_verified == true' \
        "$config_dir/source.json"
}

@test "plaintext GitHub source initializes empty private repository" {
    git --git-dir="$REMOTE" update-ref -d refs/heads/main

    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Источник GitHub подключён."
    git --git-dir="$REMOTE" show-ref --verify --quiet refs/heads/main
}
@test "encrypted GitHub source initializes empty private repository and restarts" {
    git --git-dir="$REMOTE" update-ref -d refs/heads/main
    _install_fake_age

    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\n1\naccess-pass\naccess-pass\n0\n" | "$0"' \
        "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    assert_output --partial "Источник GitHub подключён."
    jq -e '.type == "github" and .private_verified == true' \
        "$config_dir/source.json"
    [[ "$(git --git-dir="$config_dir/github-store.git" show main:storage.json |
        jq -r '.encryption')" == age ]] || return 1
    local rel
    for rel in recipient.txt unlock.age state.json.age; do
        git --git-dir="$config_dir/github-store.git" cat-file -e "main:$rel"
    done
    for rel in config.json secrets.json manifest.json; do
        ! git --git-dir="$config_dir/github-store.git" cat-file -e "main:$rel"
    done
    [[ -f "$config_dir/github-runtime/config.json" ]] || return 1

    run bash -c 'printf "access-pass\nn\n0\n" | "$0"' \
        "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "синхронизировано"

    run bash -c 'printf "access-pass\nn\nY\n0\n0\n" | "$0"' \
        "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Сменить пароль доступа"
}

@test "script password hash persists through GitHub and protects the next process" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success

    run bash -c 'printf "L\nsecret-pass\nsecret-pass\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    [[ "$(git --git-dir="$REMOTE" show main:manifest.json |
        jq -r '.access.script_password_hash | startswith("$6$")')" == true ]] || return 1

    run bash -c 'printf "secret-pass\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Essence Remote Management"
    [[ "$output" != *"Доступ запрещён."* ]] || return 1

    local rounds_hash config_dir="$HOME/.config/remote-control-essence"
    rounds_hash=$(openssl passwd -6 -salt 'rounds=100000$fixture' secret-pass) || return 1
    _publish_remote_access_hash "$rounds_hash" || return 1

    run bash -c 'printf "secret-pass\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Essence Remote Management"
    [[ "$output" != *"Доступ запрещён."* ]] || return 1
    [[ "$(cat "$config_dir/.auth")" == "$rounds_hash" ]] || return 1
}
@test "existing plaintext vault can load remote without changing local files" {
    _prepare_existing_plaintext_vault
    _publish_plain_marker remote
    local config_dir="$HOME/.config/remote-control-essence"
    local remote_head
    remote_head=$(git --git-dir="$REMOTE" rev-parse main)

    run bash -c 'printf "Y\n1\n1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "В GitHub уже сохранена конфигурация (режим хранения: без шифрования)."
    assert_output --partial "1) Загрузить конфигурацию из GitHub"
    [[ "$output" != *"Зашифровать паролем"* ]] || return 1
    [[ "$output" != *"Хранить без шифрования"* ]] || return 1
    [[ "$(jq -r '.marker' "$config_dir/github-runtime/config.json")" == remote ]] || return 1
    [[ "$(jq -r '.marker' "$config_dir/config.json")" == local ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$remote_head" ]] || return 1
    jq -e '.type == "github" and .repo == "test-owner/essence-remote-control-config"' \
        "$config_dir/source.json"
}

@test "existing plaintext vault can replace remote with local history" {
    _prepare_existing_plaintext_vault
    _publish_plain_marker remote
    local config_dir="$HOME/.config/remote-control-essence"
    _set_local_marker "$config_dir" local-new
    local old_remote new_remote
    old_remote=$(git --git-dir="$REMOTE" rev-parse main)

    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    new_remote=$(git --git-dir="$REMOTE" rev-parse main)
    [[ "$new_remote" != "$old_remote" ]] || return 1
    git --git-dir="$REMOTE" merge-base --is-ancestor "$old_remote" "$new_remote"
    [[ "$(git --git-dir="$REMOTE" show "$old_remote:config.json" | jq -r '.marker')" == remote ]] || return 1
    [[ "$(git --git-dir="$REMOTE" show "$new_remote:config.json" | jq -r '.marker')" == local-new ]] || return 1
    [[ "$(jq -r '.marker' "$config_dir/github-runtime/config.json")" == local-new ]] || return 1
}

@test "canceling existing plaintext vault keeps both versions untouched" {
    _prepare_existing_plaintext_vault
    _publish_plain_marker remote
    local config_dir="$HOME/.config/remote-control-essence"
    local checksum remote_head
    checksum=$(_hash_file "$config_dir/config.json")
    remote_head=$(git --git-dir="$REMOTE" rev-parse main)

    run bash -c 'printf "Y\n1\n0\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "выбор версии конфигурации"
    [[ ! -e "$config_dir/source.json" ]] || return 1
    [[ "$(_hash_file "$config_dir/config.json")" == "$checksum" ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$remote_head" ]] || return 1
}

@test "existing age vault inherits storage mode and unlocks only once" {
    _install_fake_age
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    _set_local_marker "$config_dir" local

    local updater="$BATS_TEST_TMPDIR/age-existing"
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    mkdir -p "$updater/templates" "$updater/ssh"
    jq -n --slurpfile config "$config_dir/config.json" \
        --slurpfile secrets "$config_dir/secrets.json" \
        --rawfile template "$APP/templates/default.yaml" '
        {
          vault_version:1,
          minimum_remote_control_version:"0.0.0",
          portability:{status:"ready",issues:[]},
          access:{script_password_hash:null},
          config:($config[0] + {marker:"remote"}),
          secrets:$secrets[0],
          templates:{"default.yaml":{content:$template}},
          ssh:{identities:{},known_hosts:""}
        }
    ' > "$updater/state.json.age"
    printf '%s\n' '{"storage_version":1,"encryption":"age"}' > "$updater/storage.json"
    printf '%s\n' age1testrecipient > "$updater/recipient.txt"
    printf '%s\n' AGE-SECRET-KEY-TEST > "$updater/unlock.age"
    git -C "$updater" add -A
    git -C "$updater" commit -m encrypted-state >/dev/null
    git -C "$updater" push origin main >/dev/null
    mv "$BIN/age" "$BIN/age.package"
    mv "$BIN/age-keygen" "$BIN/age-keygen.package"
    cat > "$BIN/brew" <<'EOF'
#!/bin/bash
[[ "$1" == install && "$2" == age ]] || exit 1
cp "$BIN/age.package" "$BIN/age"
cp "$BIN/age-keygen.package" "$BIN/age-keygen"
chmod +x "$BIN/age" "$BIN/age-keygen"
: > "$AGE_INSTALL_MARKER"
EOF
    chmod +x "$BIN/brew"
    export PM=brew AGE_INSTALL_MARKER="$BATS_TEST_TMPDIR/age-install-marker"
    export AGE_PASSWORD_DECRYPT_MARKER="$BATS_TEST_TMPDIR/age-password-decrypts"
    : > "$AGE_PASSWORD_DECRYPT_MARKER"
    local original_path="$PATH"
    local isolated_bin="$BATS_TEST_TMPDIR/no-age-bin" path_dir candidate name
    mkdir -p "$isolated_bin"
    while IFS= read -r path_dir; do
        [[ -d "$path_dir" ]] || continue
        for candidate in "$path_dir"/*; do
            [[ -f "$candidate" && -x "$candidate" ]] || continue
            name=${candidate##*/}
            case "$name" in age|age-keygen) continue ;; esac
            [[ -e "$isolated_bin/$name" ]] ||
                ln -s "$candidate" "$isolated_bin/$name"
        done
    done < <(tr ':' '\n' <<< "$PATH")
    export PATH="$BIN:$isolated_bin"
    ! command -v age >/dev/null 2>&1



    run bash -c 'printf "Y\n1\naccess-pass\nn\n1\n0\n" | "$0"' \
        "$APP/remote-control-essence.sh"
    export PATH="$original_path"
    assert_success
    assert_output --partial "Отсутствует age — устанавливаем age через brew"
    [[ -f "$AGE_INSTALL_MARKER" ]] || return 1
    assert_output --partial "режим хранения: зашифровано паролем"
    [[ "$output" != *"Зашифровать паролем"* ]] || return 1
    [[ "$output" != *"Хранить без шифрования"* ]] || return 1
    local password_decrypts
    password_decrypts=$(wc -l < "$AGE_PASSWORD_DECRYPT_MARKER" | tr -d ' ')
    [[ "$password_decrypts" == 1 ]] || return 1
    [[ "$(jq -r '.marker' "$config_dir/github-runtime/config.json")" == remote ]] || return 1
    [[ "$(jq -r '.marker' "$config_dir/config.json")" == local ]] || return 1
}
@test "tracked GitHub data without storage metadata is rejected before writing" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    local checksum remote_head orphan="$BATS_TEST_TMPDIR/orphan"
    checksum=$(_hash_file "$config_dir/config.json")
    git init -b main "$orphan" >/dev/null
    git -C "$orphan" config user.name orphan
    git -C "$orphan" config user.email orphan@example.invalid
    printf 'not an Essence vault\n' > "$orphan/README.txt"
    git -C "$orphan" add README.txt
    git -C "$orphan" commit -m orphan >/dev/null
    git -C "$orphan" remote add origin "$REMOTE"
    git -C "$orphan" push --force origin main >/dev/null
    remote_head=$(git --git-dir="$REMOTE" rev-parse main)

    run bash -c 'printf "Y\n1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "проверка существующего репозитория GitHub"
    assert_output --partial "В репозитории есть данные, но отсутствует корректная конфигурация Essence."
    [[ ! -e "$config_dir/source.json" ]] || return 1
    [[ "$(_hash_file "$config_dir/config.json")" == "$checksum" ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$remote_head" ]] || return 1
}



@test "failed GitHub enable preserves local source and config" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    local checksum
    checksum=$(_hash_file "$config_dir/config.json")

    run env GH_MODE=fail bash -c 'printf "Y\n1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Не удалось подключить GitHub (этап: проверка приватного репозитория): permission denied"
    assert_output --partial "GitHub-аккаунт для репозитория конфигурации: test-owner"
    [[ "$output" != *"gh auth login"* ]] || return 1
    [[ "$output" == *"Источник конфигурации: локальный"* ]] || return 1
    [[ "$output" != *"Источник GitHub подключён."* ]] || return 1
    [[ "$(_hash_file "$config_dir/config.json")" == "$checksum" ]] || return 1
    [[ ! -e "$config_dir/source.json" ]] || return 1
}

@test "failed first attempt can retry GitHub enable in one process" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    export GH_MODE=retry GH_COUNT_FILE="$BATS_TEST_TMPDIR/gh-count"
    printf '0\n' > "$GH_COUNT_FILE"

    run bash -c 'printf "Y\n1\nY\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Не удалось подключить GitHub (этап: проверка приватного репозитория): permission denied"
    [[ "$output" != *"gh auth login"* ]] || return 1
    assert_output --partial "Источник GitHub подключён."
    [[ "$(git --git-dir="$REMOTE" show main:storage.json | jq -r '.encryption')" == none ]] || return 1
    [[ "$(cat "$GH_COUNT_FILE")" == 2 ]] || return 1
}

@test "confirmed GitHub auth failure shows relevant login hint" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    : > "$GH_CALLS_FILE"

    run env GH_MODE=auth-fail bash -c 'printf "Y\n1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Не удалось подключить GitHub (этап: определение пользователя GitHub): HTTP 401: Bad credentials"
    assert_output --partial "Выполните: gh auth login"
    assert_output --partial "Продолжаем использовать локальную конфигурацию."
    [[ "$output" == *"Источник конфигурации: локальный"* ]] || return 1
    [[ "$(grep -c '^repo view ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$(grep -c '^repo create ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
}

@test "failed GitHub account switch stops before repository operations" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    : > "$GH_CALLS_FILE"

    run env GH_MODE=auth-switch-fail bash -c 'printf "Y\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Не удалось подключить GitHub (этап: переключение аккаунта GitHub): switch failed: token=[скрыто]"
    [[ "$output" != *"gh auth login"* ]] || return 1
    [[ "$(grep -c '^auth status ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$(grep -c '^auth login ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$(grep -c '^repo view ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$(grep -c '^repo create ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
}
@test "GitHub connection error redacts credentials and tokens" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success


    run env GH_MODE=secret-fail bash -c 'printf "Y\n1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Не удалось подключить GitHub (этап: проверка приватного репозитория):"
    [[ "$output" != *"password@github.com"* ]] || return 1
    [[ "$output" != *"ghp_SecretValue123456789"* ]] || return 1
    [[ "$output" != *"github_pat_SecretValue123456789"* ]] || return 1
    [[ "$output" != *"gh auth login"* ]] || return 1
}
@test "non-auth API timeout has no login hint and no auth status probe" {
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    : > "$GH_CALLS_FILE"
    run env GH_MODE=api-timeout bash -c 'printf "Y\n1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    [[ "$output" != *"gh auth login"* ]] || return 1
    [[ "$(grep -c '^auth status ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$(grep -c '^auth login ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$(grep -c '^repo view ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$(grep -c '^repo create ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
}

@test "empty successful login is a non-auth error and stops before repository access" {
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    : > "$GH_CALLS_FILE"

    run env GH_MODE=empty-login bash -c 'printf "Y\n1\n0\n" | "$0"' \
        "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "GitHub CLI не вернул имя активного аккаунта."
    [[ "$output" != *"gh auth login"* ]] || return 1
    [[ "$(grep -c '^api user ' "$GH_CALLS_FILE" || true)" == 1 ]] || return 1
    [[ "$(grep -c '^auth status ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$(grep -c '^auth login ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$(grep -c '^repo view ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$(grep -c '^repo create ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
}

@test "wrong account failure shows the exact switch-only hint" {
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_API_COUNT_FILE="$BATS_TEST_TMPDIR/gh-api-count"
    printf '0\n' > "$GH_API_COUNT_FILE" || return 1
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    : > "$GH_CALLS_FILE"
    printf '0\n' > "$GH_API_COUNT_FILE" || return 1

    run env GH_MODE=wrong-account bash -c 'printf "Y\n1\n0\n" | "$0"' \
        "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "GitHub CLI подключён как alternate-owner, ожидался пользователь test-owner."
    assert_output --partial "gh auth switch --hostname github.com --user test-owner"
    [[ "$output" != *"gh auth login"* ]] || return 1
    [[ "$(grep -c '^api user ' "$GH_CALLS_FILE" || true)" == 2 ]] || return 1
    [[ "$(grep -c '^auth status ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$(grep -c '^auth login ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$(grep -c '^repo view ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
    [[ "$(grep -c '^repo create ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
}

@test "switching to local source can reconnect GitHub in the same process" {
    export GH_MODE=reconnect
    export GH_CREATE_COUNT_FILE="$BATS_TEST_TMPDIR/gh-create-count"
    export GH_REPO_STATE_FILE="$BATS_TEST_TMPDIR/gh-repo-created"
    printf '0\n' > "$GH_CREATE_COUNT_FILE"
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\ny\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success

    run bash -c 'printf "Y\nE\nY\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Источник GitHub подключён."
    [[ "$output" != *"Не удалось подключить GitHub"* ]] || return 1
    jq -e 'type == "object" and .type == "github" and .private_verified == true' \
        "$HOME/.config/remote-control-essence/source.json"
    [[ "$(cat "$GH_CREATE_COUNT_FILE")" == 1 ]] || return 1
}

@test "legacy exact local source marker migrates on the next process" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    local checksum
    checksum=$(_hash_file "$config_dir/config.json")
    printf '%s\n' '{"type":"local"}' > "$config_dir/source.json"
    chmod 600 "$config_dir/source.json"

    run bash -c 'printf "0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Источник конфигурации: локальный"
    [[ "$output" != *"source.json содержит неподдерживаемый"* ]] || return 1
    [[ "$(_hash_file "$config_dir/config.json")" == "$checksum" ]] || return 1
    [[ ! -e "$config_dir/source.json" ]] || return 1
}

@test "switching from GitHub to local persists without source metadata" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"

    run bash -c 'printf "Y\nE\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local checksum
    checksum=$(_hash_file "$config_dir/config.json")
    [[ ! -e "$config_dir/source.json" ]] || return 1

    run bash -c 'printf "0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Источник конфигурации: локальный"
    [[ "$output" != *"source.json содержит неподдерживаемый"* ]] || return 1
    [[ "$(_hash_file "$config_dir/config.json")" == "$checksum" ]] || return 1
    [[ ! -e "$config_dir/source.json" ]] || return 1
}
@test "selecting another GitHub account happens before repository operations" {
    local alternate_remote="$BATS_TEST_TMPDIR/alternate.git"
    local alternate_seed="$BATS_TEST_TMPDIR/alternate-seed"
    git init --bare -b main "$alternate_remote" >/dev/null
    git init -b main "$alternate_seed" >/dev/null
    git -C "$alternate_seed" config user.name seed
    git -C "$alternate_seed" config user.email seed@example.invalid
    git -C "$alternate_seed" commit --allow-empty -m seed >/dev/null
    git -C "$alternate_seed" remote add origin "$alternate_remote"
    git -C "$alternate_seed" push origin main >/dev/null
    git config --global url."file://$alternate_remote".insteadOf \
        "https://github.com/alternate-owner/essence-remote-control-config.git"
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_SWITCH_MARKER="$BATS_TEST_TMPDIR/gh-switch"

    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n2\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success

    local config_dir="$HOME/.config/remote-control-essence"
    jq -e '.repo == "alternate-owner/essence-remote-control-config"' \
        "$config_dir/source.json"
    [[ -f "$GH_SWITCH_MARKER" ]] || return 1
    local calls
    calls=$(cat "$GH_CALLS_FILE")
    [[ "$calls" == *$'api user --jq .login\nauth switch --hostname github.com\napi user --jq .login'* ]] || return 1
    [[ "$calls" != *"repo view test-owner/essence-remote-control-config"* ]] || return 1
    [[ "$calls" == *"repo view alternate-owner/essence-remote-control-config"* ]] || return 1
    [[ "$(git --git-dir="$config_dir/github-store.git" config --get remote.origin.url)" == "https://github.com/alternate-owner/essence-remote-control-config.git" ]] || return 1
}

@test "missing repository defaults to refusal without creating or changing local state" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    local checksum
    checksum=$(_hash_file "$config_dir/config.json")
    export GH_MODE=missing GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_CREATE_COUNT_FILE="$BATS_TEST_TMPDIR/gh-create-count"
    printf '0\n' > "$GH_CREATE_COUNT_FILE"

    run bash -c 'printf "Y\n1\n\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_output --partial "Репозиторий test-owner/essence-remote-control-config не найден."
    assert_output --partial "Продолжаем использовать локальную конфигурацию."
    [[ "$(_hash_file "$config_dir/config.json")" == "$checksum" ]] || return 1
    [[ ! -e "$config_dir/source.json" ]] || return 1
    [[ "$(cat "$GH_CREATE_COUNT_FILE")" == 0 ]] || return 1
    [[ "$(grep -c '^repo create ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
}

@test "confirmed missing repository creates exactly one private repository" {
    export GH_MODE=missing GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_CREATE_COUNT_FILE="$BATS_TEST_TMPDIR/gh-create-count"
    printf '0\n' > "$GH_CREATE_COUNT_FILE"

    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\ny\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success

    [[ "$(cat "$GH_CREATE_COUNT_FILE")" == 1 ]] || return 1
    [[ "$(grep -c '^repo create test-owner/essence-remote-control-config --private --description Essence Remote Control configuration$' "$GH_CALLS_FILE" || true)" == 1 ]] || return 1
    jq -e '.type == "github" and .private_verified == true' \
        "$HOME/.config/remote-control-essence/source.json"
}

@test "startup does not recreate a repository missing from saved GitHub source" {
    export GH_MODE=missing GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_CREATE_COUNT_FILE="$BATS_TEST_TMPDIR/gh-create-count"
    printf '0\n' > "$GH_CREATE_COUNT_FILE"

    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\ny\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    printf '0\n' > "$GH_CREATE_COUNT_FILE"

    run bash -c 'printf "0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_failure
    assert_output --partial "Не удалось открыть источник GitHub (этап: проверка приватного репозитория): Репозиторий test-owner/essence-remote-control-config не найден."
    [[ "$(cat "$GH_CREATE_COUNT_FILE")" == 0 ]] || return 1
    [[ "$(grep -c '^repo create ' "$GH_CALLS_FILE" || true)" == 1 ]] || return 1
}

@test "GitHub delete defaults to refusal and keeps source metadata" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_DELETE_MARKER="$BATS_TEST_TMPDIR/gh-delete"

    run bash -c 'printf "Y\nD\n\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    [[ -f "$config_dir/source.json" ]] || return 1
    [[ ! -e "$GH_DELETE_MARKER" ]] || return 1
    [[ "$(grep -c '^repo delete ' "$GH_CALLS_FILE" || true)" == 0 ]] || return 1
}

@test "successful GitHub delete preserves local files and disables source" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_DELETE_MARKER="$BATS_TEST_TMPDIR/gh-delete"

    run bash -c 'printf "Y\nD\ny\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Репозиторий test-owner/essence-remote-control-config удалён."
    assert_output --partial "Источник конфигурации: локальный"
    [[ -f "$GH_DELETE_MARKER" ]] || return 1
    [[ "$(grep -c '^repo delete test-owner/essence-remote-control-config --yes$' "$GH_CALLS_FILE" || true)" == 1 ]] || return 1
    [[ ! -e "$config_dir/source.json" ]] || return 1
    jq -e 'type == "object" and .schema_version == 2' "$config_dir/config.json"
    jq -e 'type == "object" and .schema_version == 1' "$config_dir/secrets.json"
    jq -e 'type == "object" and .schema_version == 2' "$config_dir/manifest.json"
}

@test "failed GitHub delete opens settings and keeps local source" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_DELETE_MARKER="$BATS_TEST_TMPDIR/gh-delete"
    export GH_BROWSE_MARKER="$BATS_TEST_TMPDIR/gh-browse"
    export GH_DELETE_FAIL=true

    run bash -c 'printf "Y\nD\ny\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "Открыта страница настроек test-owner/essence-remote-control-config"
    [[ -f "$config_dir/config.json" ]] || return 1
    [[ ! -e "$config_dir/source.json" ]] || return 1
    [[ -f "$GH_DELETE_MARKER" && -f "$GH_BROWSE_MARKER" ]] || return 1
    [[ "$(grep -c '^repo delete test-owner/essence-remote-control-config --yes$' "$GH_CALLS_FILE" || true)" == 1 ]] || return 1
    [[ "$(grep -c '^browse --settings --repo test-owner/essence-remote-control-config$' "$GH_CALLS_FILE" || true)" == 1 ]] || return 1
    [[ "$output" != *"ghp_DeleteSecret123"* ]] || return 1
}

@test "failed settings fallback prints a clickable repository settings link" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    run bash -c 'printf "Y\n1\n2\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    export GH_CALLS_FILE="$BATS_TEST_TMPDIR/gh-calls"
    export GH_DELETE_FAIL=true GH_BROWSE_FAIL=true

    run bash -c 'printf "Y\nD\ny\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    assert_output --partial "https://github.com/test-owner/essence-remote-control-config/settings"
    [[ ! -e "$config_dir/source.json" ]] || return 1
    [[ "$output" != *"ghp_DeleteSecret123"* ]] || return 1
}

@test "GitHub runtime materialization command failures preserve runtime and auth and retry cleanly" {
    _establish_materialization_source
    _install_materialization_fault_wrappers
    local fault marker expected old_runtime new_runtime old_auth_hash old_auth_mode
    local old_temps new_temps failures=0

    for fault in jq cp chmod mv; do
        expected="materialize-$fault"
        _publish_plain_marker "$expected" || return 1
        old_runtime=$(_runtime_fingerprint "$MATERIALIZE_RUNTIME") || return 1
        old_auth_hash=$(_hash_file "$MATERIALIZE_CONFIG_DIR/.auth") || return 1
        old_auth_mode=$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth") || return 1
        old_temps=$(_materialization_temp_inventory "$MATERIALIZE_CONFIG_DIR") || return 1
        marker="$BATS_TEST_TMPDIR/materialize-$fault.calls"
        rm -f "$marker" || return 1

        run env MATERIALIZE_FAULT="$fault" MATERIALIZE_FAULT_MARKER="$marker" \
            bash -c 'printf "secret-pass\n0\n" | "$0"' \
            "$APP/remote-control-essence.sh"
        [[ "$status" -ne 0 ]] || failures=$((failures + 1))
        [[ -s "$marker" ]] || failures=$((failures + 1))
        new_runtime=$(_runtime_fingerprint "$MATERIALIZE_RUNTIME") ||
            new_runtime="runtime-unavailable"
        [[ "$new_runtime" == "$old_runtime" ]] || failures=$((failures + 1))
        [[ "$(_hash_file "$MATERIALIZE_CONFIG_DIR/.auth" 2>/dev/null || true)" == "$old_auth_hash" ]] ||
            failures=$((failures + 1))
        [[ "$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth" 2>/dev/null || true)" == "$old_auth_mode" ]] ||
            failures=$((failures + 1))
        new_temps=$(_materialization_temp_inventory "$MATERIALIZE_CONFIG_DIR") || return 1
        [[ "$new_temps" == "$old_temps" ]] || failures=$((failures + 1))

        run env MATERIALIZE_FAULT=none MATERIALIZE_FAULT_MARKER="$marker" \
            bash -c 'printf "secret-pass\n0\n" | "$0"' \
            "$APP/remote-control-essence.sh"
        [[ "$status" -eq 0 ]] || failures=$((failures + 1))
        [[ "$(jq -r '.marker' "$MATERIALIZE_RUNTIME/config.json" 2>/dev/null || true)" == "$expected" ]] ||
            failures=$((failures + 1))
        _assert_runtime_secure_modes "$MATERIALIZE_RUNTIME" "$MATERIALIZE_ID" ||
            failures=$((failures + 1))
        [[ "$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth" 2>/dev/null || true)" == 600 ]] ||
            failures=$((failures + 1))
    done

    [[ "$failures" -eq 0 ]] || return 1
}

@test "missing remote auth hash rm failure rolls back runtime and auth then retries" {
    _establish_materialization_source
    _install_materialization_fault_wrappers
    _publish_remote_access_null auth-null || return 1

    local old_runtime old_auth_hash old_auth_mode old_temps new_runtime new_temps
    local marker="$BATS_TEST_TMPDIR/materialize-auth-rm.calls" failures=0
    old_runtime=$(_runtime_fingerprint "$MATERIALIZE_RUNTIME") || return 1
    old_auth_hash=$(_hash_file "$MATERIALIZE_CONFIG_DIR/.auth") || return 1
    old_auth_mode=$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth") || return 1
    old_temps=$(_materialization_temp_inventory "$MATERIALIZE_CONFIG_DIR") || return 1

    run env MATERIALIZE_FAULT=auth-rm MATERIALIZE_FAULT_MARKER="$marker" \
        bash -c 'printf "secret-pass\n0\n" | "$0"' \
        "$APP/remote-control-essence.sh"
    [[ "$status" -ne 0 ]] || failures=$((failures + 1))
    [[ "$(cat "$marker" 2>/dev/null || true)" == auth-rm ]] || failures=$((failures + 1))
    new_runtime=$(_runtime_fingerprint "$MATERIALIZE_RUNTIME") ||
        new_runtime="runtime-unavailable"
    [[ "$new_runtime" == "$old_runtime" ]] || failures=$((failures + 1))
    [[ "$(_hash_file "$MATERIALIZE_CONFIG_DIR/.auth" 2>/dev/null || true)" == "$old_auth_hash" ]] ||
        failures=$((failures + 1))
    [[ "$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth" 2>/dev/null || true)" == "$old_auth_mode" ]] ||
        failures=$((failures + 1))
    new_temps=$(_materialization_temp_inventory "$MATERIALIZE_CONFIG_DIR") || return 1
    [[ "$new_temps" == "$old_temps" ]] || failures=$((failures + 1))

    run env MATERIALIZE_FAULT=none MATERIALIZE_FAULT_MARKER="$marker" \
        bash -c 'printf "0\n" | "$0"' "$APP/remote-control-essence.sh"
    [[ "$status" -eq 0 ]] || failures=$((failures + 1))
    [[ ! -e "$MATERIALIZE_CONFIG_DIR/.auth" ]] || failures=$((failures + 1))
    [[ "$(jq -r '.marker' "$MATERIALIZE_RUNTIME/config.json" 2>/dev/null || true)" == auth-null ]] ||
        failures=$((failures + 1))
    _assert_runtime_secure_modes "$MATERIALIZE_RUNTIME" "$MATERIALIZE_ID" ||
        failures=$((failures + 1))

    [[ "$failures" -eq 0 ]] || return 1
}
@test "failed runtime restore preserves the retired runtime backup" {
    _establish_materialization_source
    _install_materialization_fault_wrappers
    _publish_plain_marker runtime-rollback || return 1
    local old_runtime retired marker="$BATS_TEST_TMPDIR/materialize-runtime-rollback.calls"
    old_runtime=$(_runtime_fingerprint "$MATERIALIZE_RUNTIME") || return 1
    rm -f "$marker" || return 1

    run env MATERIALIZE_FAULT=runtime-rollback MATERIALIZE_FAULT_MARKER="$marker" \
        bash -c 'printf "secret-pass\n0\n" | "$0"' \
        "$APP/remote-control-essence.sh"
    assert_failure
    [[ "$(cat "$marker")" == $'publish-fail\nruntime-restore-fail' ]] || return 1
    retired=$(find "$MATERIALIZE_CONFIG_DIR" -mindepth 1 -maxdepth 1 \
        -name '.github-runtime.retired.*' -print)
    [[ "$(printf '%s\n' "$retired" | sed '/^$/d' | wc -l | tr -d ' ')" == 1 ]] || return 1
    [[ "$(_runtime_fingerprint "$retired")" == "$old_runtime" ]] || return 1
    [[ ! -e "$MATERIALIZE_RUNTIME" ]] || return 1
    assert_output --partial "Резервные копии сохранены в $MATERIALIZE_CONFIG_DIR."
}

@test "failed auth restore preserves the auth backup after runtime rollback" {
    _establish_materialization_source
    _install_materialization_fault_wrappers
    _publish_remote_access_null auth-rollback || return 1
    local old_runtime old_auth_hash old_auth_mode backup marker="$BATS_TEST_TMPDIR/materialize-auth-rollback.calls"
    old_runtime=$(_runtime_fingerprint "$MATERIALIZE_RUNTIME") || return 1
    old_auth_hash=$(_hash_file "$MATERIALIZE_CONFIG_DIR/.auth") || return 1
    old_auth_mode=$(_file_mode "$MATERIALIZE_CONFIG_DIR/.auth") || return 1
    rm -f "$marker" || return 1

    run env MATERIALIZE_FAULT=auth-rollback MATERIALIZE_FAULT_MARKER="$marker" \
        bash -c 'printf "secret-pass\n0\n" | "$0"' \
        "$APP/remote-control-essence.sh"
    assert_failure
    [[ "$(cat "$marker")" == $'auth-rm\nauth-restore-fail' ]] || return 1
    [[ "$(_runtime_fingerprint "$MATERIALIZE_RUNTIME")" == "$old_runtime" ]] || return 1
    backup=$(find "$MATERIALIZE_CONFIG_DIR" -mindepth 1 -maxdepth 1 \
        -name '.auth.backup.*' -print)
    [[ "$(printf '%s\n' "$backup" | sed '/^$/d' | wc -l | tr -d ' ')" == 1 ]] || return 1
    [[ "$(_hash_file "$backup")" == "$old_auth_hash" ]] || return 1
    [[ "$(_file_mode "$backup")" == "$old_auth_mode" ]] || return 1
    [[ "$old_auth_mode" == 600 ]] || return 1
    assert_output --partial "Резервные копии сохранены в $MATERIALIZE_CONFIG_DIR."
}

@test "startup ensures the complete local dependency set and starts one update check" {
    local deps_log="$BATS_TEST_TMPDIR/ensure-deps.calls"
    local update_log="$BATS_TEST_TMPDIR/update.calls" dep count failures=0
    cat > "$APP/common/ensure-deps.sh" <<'EOF'
#!/bin/bash
ensure_dep() {
    printf '%s\n' "$@" >> "$ENSURE_DEPS_LOG"
}
EOF
    cat > "$BIN/curl" <<'EOF'
#!/bin/bash
printf 'update\n' >> "$UPDATE_CHECK_LOG"
printf '%s\n' '{"tag_name":"v0.0.0"}'
EOF
    chmod +x "$APP/common/ensure-deps.sh" "$BIN/curl" || return 1
    export ENSURE_DEPS_LOG="$deps_log" UPDATE_CHECK_LOG="$update_log"

    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    [[ "$status" -eq 0 ]] || failures=$((failures + 1))
    for dep in jq openssl ssh scp base64; do
        count=$(grep -c "^${dep}$" "$deps_log" 2>/dev/null || true)
        [[ "$count" -eq 1 ]] || failures=$((failures + 1))
    done
    for ((count=0; count<50; count++)); do
        if [[ -f "$update_log" ]] && grep -q '^update$' "$update_log"; then
            break
        fi
        sleep 0.1
    done
    count=$(grep -c '^update$' "$update_log" 2>/dev/null || true)
    [[ "$count" -eq 1 ]] || failures=$((failures + 1))

    [[ "$failures" -eq 0 ]] || return 1
}

@test "readable incomplete GitHub metadata reports the GitHub diagnostic" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    printf '%s\n' '{"type":"github","repo":"test-owner/essence-remote-control-config"}' \
        > "$config_dir/source.json"

    run bash -c 'printf "0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_failure
    assert_output --partial "source.json содержит неполные или некорректные параметры GitHub."
    assert_output --partial "этап: проверка настроек источника GitHub"
}

@test "malformed source metadata keeps the generic startup fallback" {
    run bash -c 'printf "1\n0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_success
    local config_dir="$HOME/.config/remote-control-essence"
    printf '%s\n' '{not-json' > "$config_dir/source.json"

    run bash -c 'printf "0\n" | "$0"' "$APP/remote-control-essence.sh"
    assert_failure
    assert_output --partial "Не удалось открыть источник конфигурации."
    [[ "$output" != *"этап: проверка настроек источника GitHub"* ]] || return 1
}
