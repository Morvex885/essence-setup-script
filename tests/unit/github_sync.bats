#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module 'github-config.sh'
    export REMOTE="$BATS_TEST_TMPDIR/remote.git"
    export GITHUB_REMOTE="$REMOTE" GITHUB_STORE="$BATS_TEST_TMPDIR/store.git" GITHUB_SESSIONS_DIR="$BATS_TEST_TMPDIR/sessions"
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    git init --bare -b main "$REMOTE" >/dev/null
}
teardown() { teardown_test_env; }

_file_mode() {
    case "${OSTYPE:-}" in
        darwin*) stat -f '%Lp' "$1" ;;
        *) stat -c '%a' "$1" ;;
    esac
}

_seed_live_revision() {
    local revision="${1:-1}"
    GITHUB_STORAGE_MODE=none
    github_sync_init || return 1
    printf '{"storage_version":1,"encryption":"none","revision":%s}\n' "$revision" \
        > "$GITHUB_WORKTREE/storage.json" || return 1
    github_sync_flush || return 1
}

_seed_age_revision() {
    GITHUB_STORAGE_MODE=age
    github_sync_init || return 1
    printf '{"storage_version":1,"encryption":"age"}\n' > "$GITHUB_WORKTREE/storage.json"
    printf 'age1oldrecipient\n' > "$GITHUB_WORKTREE/recipient.txt"
    printf 'old-unlock\n' > "$GITHUB_WORKTREE/unlock.age"
    printf 'old-state\n' > "$GITHUB_WORKTREE/state.json.age"
    chmod 600 "$GITHUB_WORKTREE/unlock.age" "$GITHUB_WORKTREE/state.json.age"
    github_sync_flush || return 1
}

_assert_remote_revision() {
    local remote="$1" revision="$2"
    [[ "$(git --git-dir="$remote" show main:storage.json | jq -r '.revision')" == "$revision" ]] || return 1
}
_prepare_local_switch_fixture() {
    GITHUB_STORAGE_MODE=none
    github_sync_init || return 1
    SWITCH_OLD_WORKTREE="$GITHUB_WORKTREE"
    SWITCH_OLD_SESSION="$GITHUB_SESSION_ID"
    local runtime="$BATS_TEST_TMPDIR/switch-runtime"
    mkdir -p "$runtime/templates" "$runtime/ssh/identities" \
        "$CONFIG_DIR/templates" "$CONFIG_DIR/ssh/identities" || return 1
    printf '{"schema_version":2,"marker":"github"}\n' > "$runtime/config.json"
    printf '{"marker":"github-secrets"}\n' > "$runtime/secrets.json"
    printf '{"schema_version":1,"marker":"github-manifest"}\n' > "$runtime/manifest.json"
    printf 'github-template\n' > "$runtime/templates/current.yaml"
    printf 'github-known-host\n' > "$runtime/ssh/known_hosts"
    printf 'local-config\n' > "$CONFIG_DIR/config.json"
    printf 'local-secrets\n' > "$CONFIG_DIR/secrets.json"
    printf 'local-manifest\n' > "$CONFIG_DIR/manifest.json"
    printf 'local-template\n' > "$CONFIG_DIR/templates/previous.yaml"
    printf 'local-known-host\n' > "$CONFIG_DIR/ssh/known_hosts"
    printf 'github-source-metadata\n' > "$CONFIG_DIR/source.json"
    CONFIG_SOURCE=github
    STATE_DIR="$runtime"; CONFIG_JSON="$runtime/config.json"
    SECRETS_JSON="$runtime/secrets.json"; STATE_MANIFEST="$runtime/manifest.json"
    TEMPLATES_DIR="$runtime/templates"; SSH_IDENTITIES_DIR="$runtime/ssh/identities"
    SSH_KNOWN_HOSTS="$runtime/ssh/known_hosts"; SCRIPT_AUTH_FILE="$CONFIG_DIR/.auth"
    export CONFIG_SOURCE STATE_DIR CONFIG_JSON SECRETS_JSON STATE_MANIFEST
    export TEMPLATES_DIR SSH_IDENTITIES_DIR SSH_KNOWN_HOSTS SCRIPT_AUTH_FILE
    state_validate() { return 0; }
}

_assert_local_switch_rolled_back() {
    [[ "$CONFIG_SOURCE" == github ]] || return 1
    [[ "$GITHUB_WORKTREE" == "$SWITCH_OLD_WORKTREE" ]] || return 1
    [[ "$GITHUB_SESSION_ID" == "$SWITCH_OLD_SESSION" ]] || return 1
    [[ -d "$SWITCH_OLD_WORKTREE" ]] || return 1
    git -C "$SWITCH_OLD_WORKTREE" rev-parse --is-inside-work-tree >/dev/null || return 1
    [[ "$(cat "$CONFIG_DIR/config.json")" == local-config ]] || return 1
    [[ "$(cat "$CONFIG_DIR/secrets.json")" == local-secrets ]] || return 1
    [[ "$(cat "$CONFIG_DIR/manifest.json")" == local-manifest ]] || return 1
    [[ "$(cat "$CONFIG_DIR/templates/previous.yaml")" == local-template ]] || return 1
    [[ "$(cat "$CONFIG_DIR/ssh/known_hosts")" == local-known-host ]] || return 1
    [[ "$(cat "$CONFIG_DIR/source.json")" == github-source-metadata ]] || return 1
    local leftover
    leftover=$(find "$CONFIG_DIR" -maxdepth 1 -name '.local-switch-*' -print -quit) || return 1
    [[ -z "$leftover" ]]
}

@test "transport init does not persist metadata until explicit writer" {
    export GITHUB_OWNER=test-owner GITHUB_REPO_NAME=essence-remote-control-config
    rm -f "$CONFIG_DIR/source.json"

    github_sync_init
    [[ ! -e "$CONFIG_DIR/source.json" ]] || return 1

    github_source_metadata_write
    github_source_metadata_valid "$CONFIG_DIR/source.json"
    [[ "$(_file_mode "$CONFIG_DIR/source.json")" == 600 ]] || return 1
}

@test "secure GitHub roots reject credential session-root and session-leaf symlinks" {
    local session_target="$BATS_TEST_TMPDIR/session-target"
    local leaf_target="$BATS_TEST_TMPDIR/leaf-target"
    local credentials_target="$BATS_TEST_TMPDIR/credentials-target"
    local identity="$BATS_TEST_TMPDIR/import.key" rc=0 leftover
    mkdir -p "$session_target" "$leaf_target" "$credentials_target" || return 1
    chmod 755 "$session_target" "$leaf_target" "$credentials_target" || return 1

    rm -rf "$GITHUB_SESSIONS_DIR" || return 1
    ln -s "$session_target" "$GITHUB_SESSIONS_DIR" || return 1
    github_sync_init || rc=$?
    [[ "$rc" -ne 0 ]] || return 1
    [[ "$(_file_mode "$session_target")" == 755 ]] || return 1
    leftover=$(find "$session_target" -mindepth 1 -print -quit) || return 1
    [[ -z "$leftover" ]] || return 1

    rm -f "$GITHUB_SESSIONS_DIR" || return 1
    mkdir -p "$GITHUB_SESSIONS_DIR" || return 1
    chmod 700 "$GITHUB_SESSIONS_DIR" || return 1
    GITHUB_SESSION_ID=forced-session
    ln -s "$leaf_target" "$GITHUB_SESSIONS_DIR/$GITHUB_SESSION_ID" || return 1
    rc=0
    github_sync_init || rc=$?
    [[ "$rc" -ne 0 ]] || return 1
    [[ "$(_file_mode "$leaf_target")" == 755 ]] || return 1
    leftover=$(find "$leaf_target" -mindepth 1 -print -quit) || return 1
    [[ -z "$leftover" ]] || return 1

    rm -rf "$GITHUB_CREDENTIALS_DIR" || return 1
    ln -s "$credentials_target" "$GITHUB_CREDENTIALS_DIR" || return 1
    GITHUB_UNLOCK_FILE="$GITHUB_CREDENTIALS_DIR/github-config.agekey"
    printf 'AGE-SECRET-KEY-EXTERNAL\n' > "$identity" || return 1
    rc=0
    github_config_remember "$identity" || rc=$?
    [[ "$rc" -ne 0 ]] || return 1
    [[ "$(_file_mode "$credentials_target")" == 755 ]] || return 1
    leftover=$(find "$credentials_target" -mindepth 1 -print -quit) || return 1
    [[ -z "$leftover" ]]
}


@test "transport creates independent session worktree" {
    github_sync_init
    [[ -d "$GITHUB_WORKTREE" ]] || return 1
    [[ -d "$GITHUB_STORE" ]] || return 1
    [[ "$(_file_mode "$GITHUB_WORKTREE")" == 700 ]] || return 1
}

@test "repeated transport initialization keeps the live session worktree" {
    github_sync_init
    local first_session="$GITHUB_SESSION_ID" first_worktree="$GITHUB_WORKTREE"
    run github_sync_init
    assert_success
    [[ "$GITHUB_SESSION_ID" == "$first_session" ]] || return 1
    [[ "$GITHUB_WORKTREE" == "$first_worktree" ]] || return 1
    [[ -d "$first_worktree" ]] || return 1
}

@test "flush commits with repository-local identity and reports pending offline" {
    github_sync_init
    rm -rf "$REMOTE"
    printf '{"storage_version":1,"encryption":"none"}\n' > "$GITHUB_WORKTREE/storage.json"
    git -C "$GITHUB_WORKTREE" add storage.json
    if github_sync_flush; then
        return 1
    fi
    [[ $GITHUB_SYNC_STATUS == pending ]] || return 1
    run git -C "$GITHUB_WORKTREE" log -1 --format='%an <%ae>'
    assert_output 'Essence Remote Control <remote-control@localhost>'
}

@test "commit failure keeps staged state pending and same-process retry pushes it" {
    _seed_live_revision 1
    local old_remote old_local old_head rc=0
    old_remote=$(git --git-dir="$REMOTE" rev-parse main) || return 1
    old_local=$(git --git-dir="$GITHUB_STORE" rev-parse main) || return 1
    old_head=$(git -C "$GITHUB_WORKTREE" rev-parse HEAD) || return 1
    printf '{"storage_version":1,"encryption":"none","revision":2}\n' \
        > "$GITHUB_WORKTREE/storage.json" || return 1
    export GIT_REAL COMMIT_FAIL_MARKER="$BATS_TEST_TMPDIR/commit.failed"
    GIT_REAL=$(command -v git) || return 1
    git() {
        local arg
        for arg in "$@"; do
            if [[ "$arg" == commit && ! -e "$COMMIT_FAIL_MARKER" ]]; then
                : > "$COMMIT_FAIL_MARKER"
                printf 'simulated git commit failure\n' >&2
                return 79
            fi
        done
        "$GIT_REAL" "$@"
    }
    github_sync_flush || rc=$?
    unset -f git

    [[ "$rc" -ne 0 ]] || return 1
    [[ "$GITHUB_LAST_STAGE" == "сохранение локальных изменений Git" ]] || return 1
    [[ "$GITHUB_LAST_ERROR" == "simulated git commit failure" ]] || return 1
    [[ "$GITHUB_SYNC_STATUS" == pending ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$old_remote" ]] || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" rev-parse main)" == "$old_local" ]] || return 1
    [[ "$(git -C "$GITHUB_WORKTREE" rev-parse HEAD)" == "$old_head" ]] || return 1
    [[ "$(jq -r '.revision' "$GITHUB_WORKTREE/storage.json")" == 2 ]] || return 1
    if git -C "$GITHUB_WORKTREE" diff --cached --quiet; then
        return 1
    fi

    github_sync_flush || return 1
    [[ "$GITHUB_SYNC_STATUS" == clean ]] || return 1
    _assert_remote_revision "$REMOTE" 2 || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" rev-parse main)" == \
       "$(git --git-dir="$REMOTE" rev-parse main)" ]] || return 1
    git -C "$GITHUB_WORKTREE" diff --quiet || return 1
    git -C "$GITHUB_WORKTREE" diff --cached --quiet
}

@test "pending offline commit survives a fresh session and retry pushes it" {
    local held_remote="$BATS_TEST_TMPDIR/held-remote.git"
    github_sync_init
    printf '{"storage_version":1,"encryption":"none","revision":1}\n' \
        > "$GITHUB_WORKTREE/storage.json"
    github_sync_flush
    [[ "$(git --git-dir="$REMOTE" show main:storage.json | jq -r '.revision')" == 1 ]] || return 1

    printf '{"storage_version":1,"encryption":"none","revision":2}\n' \
        > "$GITHUB_WORKTREE/storage.json"
    mv "$REMOTE" "$held_remote" || return 1
    if github_sync_flush; then
        return 1
    fi
    [[ "$GITHUB_SYNC_STATUS" == pending ]] || return 1
    local pending_head
    pending_head=$(git --git-dir="$GITHUB_STORE" rev-parse main)
    mv "$held_remote" "$REMOTE" || return 1

    github_config_close
    github_sync_init
    [[ "$GITHUB_SYNC_STATUS" == pending ]] || return 1
    [[ "$(git -C "$GITHUB_WORKTREE" rev-parse HEAD)" == "$pending_head" ]] || return 1
    [[ "$(jq -r '.revision' "$GITHUB_WORKTREE/storage.json")" == 2 ]] || return 1

    github_sync_flush
    [[ "$GITHUB_SYNC_STATUS" == clean ]] || return 1
    [[ "$(git --git-dir="$REMOTE" show main:storage.json | jq -r '.revision')" == 2 ]] || return 1
}

@test "divergent local and remote commits stop without overwriting local recovery" {
    local held_remote="$BATS_TEST_TMPDIR/held-remote.git"
    github_sync_init
    printf '{"storage_version":1,"encryption":"none","revision":1}\n' \
        > "$GITHUB_WORKTREE/storage.json"
    github_sync_flush

    printf '{"storage_version":1,"encryption":"none","revision":2}\n' \
        > "$GITHUB_WORKTREE/storage.json"
    mv "$REMOTE" "$held_remote" || return 1
    run github_sync_flush
    assert_failure
    local pending_head
    pending_head=$(git --git-dir="$GITHUB_STORE" rev-parse main)
    mv "$held_remote" "$REMOTE" || return 1

    local updater="$BATS_TEST_TMPDIR/updater"
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    printf '{"storage_version":1,"encryption":"none","revision":3}\n' \
        > "$updater/storage.json"
    git -C "$updater" add storage.json
    git -C "$updater" commit -m remote-change >/dev/null
    git -C "$updater" push origin main >/dev/null

    github_config_close
    if github_sync_init; then
        return 1
    fi
    [[ "$GITHUB_LAST_STAGE" == "сверка локальных и удалённых изменений" ]] || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" rev-parse main)" == "$pending_head" ]] || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" show main:storage.json | jq -r '.revision')" == 2 ]] || return 1
}

@test "onboarding archives divergent cached main and opens remote head" {
    local seed="$BATS_TEST_TMPDIR/seed"
    git init --bare -b main "$REMOTE" >/dev/null
    git init -b main "$seed" >/dev/null
    git -C "$seed" config user.name seed
    git -C "$seed" config user.email seed@example.invalid
    printf '{"storage_version":1,"encryption":"none","revision":"base"}\n' \
        > "$seed/storage.json"
    git -C "$seed" add storage.json
    git -C "$seed" commit -m base >/dev/null
    git -C "$seed" remote add origin "$REMOTE"
    git -C "$seed" push origin main >/dev/null

    github_sync_init
    local base_oid
    base_oid=$(git --git-dir="$GITHUB_STORE" rev-parse main)
    github_config_close
    local tree local_oid
    tree=$(git --git-dir="$GITHUB_STORE" rev-parse "$base_oid^{tree}")
    local_oid=$(printf 'offline local state\n' |
        git -c user.name='Essence Remote Control' \
            -c user.email='remote-control@localhost' \
            --git-dir="$GITHUB_STORE" commit-tree "$tree" -p "$base_oid")
    git --git-dir="$GITHUB_STORE" update-ref refs/heads/main "$local_oid"

    local updater="$BATS_TEST_TMPDIR/updater"
    git clone "$REMOTE" "$updater" >/dev/null
    git -C "$updater" config user.name updater
    git -C "$updater" config user.email updater@example.invalid
    printf '{"storage_version":1,"encryption":"none","revision":"remote"}\n' \
        > "$updater/storage.json"
    git -C "$updater" add storage.json
    git -C "$updater" commit -m remote >/dev/null
    git -C "$updater" push origin main >/dev/null
    local remote_oid
    remote_oid=$(git --git-dir="$REMOTE" rev-parse main)

    github_sync_init true onboarding
    [[ "$(git -C "$GITHUB_WORKTREE" rev-parse HEAD)" == "$remote_oid" ]] || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" rev-parse main)" == "$remote_oid" ]] || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" for-each-ref --format='%(objectname)' 'refs/archive/onboarding-*')" == "$local_oid" ]] || return 1
    [[ "$(git --git-dir="$REMOTE" rev-parse main)" == "$remote_oid" ]] || return 1
}

@test "onboarding confirms empty remote and rejects network errors" {
    local seed="$BATS_TEST_TMPDIR/seed"
    git init -b main "$seed" >/dev/null
    git -C "$seed" config user.name seed
    git -C "$seed" config user.email seed@example.invalid
    git -C "$seed" commit --allow-empty -m cached >/dev/null
    git -C "$seed" remote add origin "$REMOTE"
    git -C "$seed" push origin main >/dev/null

    github_sync_init
    local cached_oid
    cached_oid=$(git --git-dir="$GITHUB_STORE" rev-parse main)
    github_config_close
    git --git-dir="$REMOTE" update-ref -d refs/heads/main

    github_sync_init true onboarding
    local empty_oid
    empty_oid=$(git --git-dir="$GITHUB_STORE" rev-parse main)
    [[ "$empty_oid" != "$cached_oid" ]] || return 1
    [[ -z "$(git -C "$GITHUB_WORKTREE" ls-files)" ]] || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" for-each-ref --format='%(objectname)' 'refs/archive/onboarding-*')" == "$cached_oid" ]] || return 1
    github_config_close

    local missing="$BATS_TEST_TMPDIR/missing.git" before
    before=$(git --git-dir="$GITHUB_STORE" rev-parse main)
    GITHUB_REMOTE="$missing"
    if github_sync_init true onboarding; then
        return 1
    fi
    [[ "$GITHUB_LAST_STAGE" == "загрузка репозитория GitHub" ]] || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" rev-parse main)" == "$before" ]] || return 1
}

@test "switching repository updates origin and never pushes new data to old remote" {
    github_sync_init
    printf '{"storage_version":1,"encryption":"none","revision":1}\n' \
        > "$GITHUB_WORKTREE/storage.json"
    github_sync_flush
    github_config_close

    local new_remote="$BATS_TEST_TMPDIR/new-remote.git"
    git init --bare "$new_remote" >/dev/null
    GITHUB_REMOTE="$new_remote"
    github_sync_init
    [[ "$(git --git-dir="$GITHUB_STORE" remote get-url origin)" == "$new_remote" ]] || return 1
    git --git-dir="$GITHUB_STORE" for-each-ref --format='%(refname)' \
        refs/archive | grep -q '^refs/archive/remote-switch-'

    printf '{"storage_version":1,"encryption":"none","revision":2}\n' \
        > "$GITHUB_WORKTREE/storage.json"
    github_sync_flush
    [[ "$(git --git-dir="$new_remote" show main:storage.json | jq -r '.revision')" == 2 ]] || return 1
    [[ "$(git --git-dir="$REMOTE" show main:storage.json | jq -r '.revision')" == 1 ]] || return 1
    [[ "$(git --git-dir="$new_remote" rev-list --count main)" == 2 ]] || return 1
    ! git --git-dir="$new_remote" show main^:storage.json >/dev/null 2>&1
}

@test "composed EXIT cleanup removes update temp and GitHub session secrets" {
    local meta="$BATS_TEST_TMPDIR/cleanup-meta"
    local child_config="$BATS_TEST_TMPDIR/child-config"
    local child_store="$BATS_TEST_TMPDIR/child-store.git"
    local child_sessions="$BATS_TEST_TMPDIR/child-sessions"
    run env PROJECT_ROOT="$PROJECT_ROOT" REMOTE="$REMOTE" \
        CHILD_CONFIG="$child_config" CHILD_STORE="$child_store" \
        CHILD_SESSIONS="$child_sessions" CLEANUP_META="$meta" \
        /bin/bash -c '
            source "$PROJECT_ROOT/common/common.sh"
            CONFIG_DIR="$CHILD_CONFIG"
            source "$PROJECT_ROOT/remote-control/modules/github-config.sh"
            GITHUB_REMOTE="$REMOTE"
            GITHUB_STORE="$CHILD_STORE"
            GITHUB_SESSIONS_DIR="$CHILD_SESSIONS"
            github_sync_init
            identity="$CHILD_CONFIG/.unlock-check.test"
            printf identity > "$identity"
            GITHUB_IDENTITY="$identity"
            register_exit_cleanup github_config_close
            curl() { printf "%s\n" "{\"tag_name\":\"v1.2.3\"}"; }
            check_update_start
            printf "%s\n%s\n%s\n%s\n" \
                "$GITHUB_WORKTREE" "$GITHUB_SESSION_ID" "$identity" "$_UPDATE_TMP" \
                > "$CLEANUP_META"
        '
    assert_success

    local worktree session identity update_tmp
    {
        IFS= read -r worktree
        IFS= read -r session
        IFS= read -r identity
        IFS= read -r update_tmp
    } < "$meta"
    [[ ! -d "$worktree" ]] || return 1
    [[ ! -e "$identity" ]] || return 1
    [[ ! -e "$update_tmp" ]] || return 1
    ! git --git-dir="$child_store" show-ref --verify --quiet \
        "refs/heads/session/$session"
}

@test "config close removes session state and permits a fresh session" {
    github_sync_init
    local old_session="$GITHUB_SESSION_ID" old_worktree="$GITHUB_WORKTREE"
    git --git-dir="$GITHUB_STORE" show-ref --verify --quiet \
        "refs/heads/session/$old_session"

    github_config_close
    [[ -z "$GITHUB_SESSION_ID" ]] || return 1
    [[ -z "$GITHUB_WORKTREE" ]] || return 1
    [[ ! -d "$old_worktree" ]] || return 1
    ! git --git-dir="$GITHUB_STORE" show-ref --verify --quiet \
        "refs/heads/session/$old_session"

    github_sync_init
    [[ -n "$GITHUB_SESSION_ID" ]] || return 1
    [[ "$GITHUB_SESSION_ID" != "$old_session" ]] || return 1
    [[ -d "$GITHUB_WORKTREE" ]] || return 1
}

@test "status exposes clean default" {
    run github_sync_status
    assert_success
    assert_output 'clean'
}

@test "flush without a worktree records the exact boundary error" {
    unset GITHUB_WORKTREE
    if github_sync_flush; then
        return 1
    fi
    [[ "$GITHUB_LAST_STAGE" == "подготовка рабочей копии конфигурации" ]] || return 1
    [[ "$GITHUB_LAST_ERROR" == "Рабочая копия конфигурации GitHub недоступна." ]] || return 1
    [[ "$GITHUB_SYNC_STATUS" == pending ]] || return 1
}

@test "fetch without a store records the exact boundary error" {
    unset GITHUB_STORE
    if github_sync_fetch; then
        return 1
    fi
    [[ "$GITHUB_LAST_STAGE" == "подготовка локального хранилища" ]] || return 1
    [[ "$GITHUB_LAST_ERROR" == "Локальное GitHub-хранилище не настроено." ]] || return 1
}

@test "ensure error preserves an existing detailed diagnostic and returns failure" {
    _github_record_error "детальный этап" "детальная причина"
    if _github_ensure_error "граница операции" "резервная причина"; then
        return 1
    fi
    [[ "$GITHUB_LAST_STAGE" == "детальный этап" ]] || return 1
    [[ "$GITHUB_LAST_ERROR" == "детальная причина" ]] || return 1
}

@test "close worktree removal failure preserves retryable session state and identity" {
    github_sync_init || return 1
    local old_worktree="$GITHUB_WORKTREE" old_session="$GITHUB_SESSION_ID"
    local identity="$CONFIG_DIR/.unlock-check.close" git_real close_rc=0
    printf 'ephemeral-identity\n' > "$identity" || return 1
    chmod 600 "$identity" || return 1
    GITHUB_IDENTITY="$identity"
    export GIT_REAL CLOSE_STORE="$GITHUB_STORE"
    GIT_REAL=$(command -v git) || return 1
    git() {
        if [[ "$1" == "--git-dir=$CLOSE_STORE" && "$2" == worktree &&
              "$3" == remove ]]; then
            return 78
        fi
        "$GIT_REAL" "$@"
    }

    github_config_close || close_rc=$?
    unset -f git
    [[ "$close_rc" -ne 0 ]] || return 1
    [[ "$GITHUB_WORKTREE" == "$old_worktree" ]] || return 1
    [[ "$GITHUB_SESSION_ID" == "$old_session" ]] || return 1
    [[ "$GITHUB_IDENTITY" == "$identity" ]] || return 1
    [[ -d "$old_worktree" ]] || return 1
    [[ -f "$identity" ]] || return 1
    git --git-dir="$GITHUB_STORE" show-ref --verify --quiet \
        "refs/heads/session/$old_session" || return 1

    github_config_close || return 1
    [[ -z "$GITHUB_WORKTREE" ]] || return 1
    [[ -z "$GITHUB_SESSION_ID" ]] || return 1
    [[ -z "$GITHUB_IDENTITY" ]] || return 1
    [[ ! -d "$old_worktree" ]] || return 1
    [[ ! -e "$identity" ]] || return 1
    ! git --git-dir="$GITHUB_STORE" show-ref --verify --quiet \
        "refs/heads/session/$old_session"
}

@test "close identity removal failure preserves its path for direct retry" {
    github_sync_init || return 1
    local old_worktree="$GITHUB_WORKTREE" identity identity_dir rc=0 arg
    identity=$(_github_new_private_path "$CONFIG_DIR/.identity-close.XXXXXX") || return 1
    identity_dir=$(dirname "$identity") || return 1
    (umask 077; printf 'ephemeral-identity\n' > "$identity") || return 1
    GITHUB_IDENTITY="$identity"
    GITHUB_RECIPIENT=age1testrecipient
    export RM_REAL RM_FAIL_TARGET="$identity" RM_FAILED="$BATS_TEST_TMPDIR/rm.failed"
    RM_REAL=$(command -v rm) || return 1
    rm() {
        for arg in "$@"; do
            if [[ "$arg" == "$RM_FAIL_TARGET" && ! -e "$RM_FAILED" ]]; then
                : > "$RM_FAILED"
                return 78
            fi
        done
        "$RM_REAL" "$@"
    }
    github_config_close || rc=$?
    unset -f rm
    [[ "$rc" -ne 0 ]] || return 1
    [[ "$GITHUB_IDENTITY" == "$identity" ]] || return 1
    [[ -f "$identity" && -d "$identity_dir" ]] || return 1
    [[ -z "$GITHUB_WORKTREE" && -z "$GITHUB_SESSION_ID" ]] || return 1
    [[ ! -d "$old_worktree" ]] || return 1
    [[ "$GITHUB_LAST_STAGE" == "очистка временного ключа GitHub" ]] || return 1
    [[ "$GITHUB_LAST_ERROR" == "Не удалось удалить временный ключ расшифровки." ]] || return 1

    github_config_close || return 1
    [[ -z "$GITHUB_IDENTITY" ]] || return 1
    [[ ! -e "$identity" && ! -e "$identity_dir" ]] || return 1

    local caller_identity="$BATS_TEST_TMPDIR/caller-owned.key"
    printf 'caller-owned\n' > "$caller_identity" || return 1
    GITHUB_IDENTITY="$caller_identity"
    github_config_close || return 1
    [[ -f "$caller_identity" ]]
}

@test "switch to local keeps source tree and session when staging copy fails" {
    _prepare_local_switch_fixture || return 1
    local rc=0 arg
    export CP_REAL
    CP_REAL=$(command -v cp) || return 1
    cp() {
        for arg in "$@"; do
            [[ "$arg" == *".local-switch-stage."* ]] && return 71
        done
        "$CP_REAL" "$@"
    }
    github_config_switch_local || rc=$?
    unset -f cp
    [[ "$rc" -ne 0 ]] || return 1
    _assert_local_switch_rolled_back || return 1
    github_config_close
}

@test "switch to local keeps source tree and session when staging chmod fails" {
    _prepare_local_switch_fixture || return 1
    local rc=0 arg
    export CHMOD_REAL
    CHMOD_REAL=$(command -v chmod) || return 1
    chmod() {
        for arg in "$@"; do
            [[ "$arg" == *".local-switch-stage."* ]] && return 72
        done
        "$CHMOD_REAL" "$@"
    }
    github_config_switch_local || rc=$?
    unset -f chmod
    [[ "$rc" -ne 0 ]] || return 1
    _assert_local_switch_rolled_back || return 1
    github_config_close
}

@test "switch to local removes a partial publication before exact rollback" {
    _prepare_local_switch_fixture || return 1
    local rc=0 destination
    export MV_REAL MV_FAIL_ONCE="$BATS_TEST_TMPDIR/mv.failed"
    MV_REAL=$(command -v mv) || return 1
    mv() {
        destination="${!#}"
        if [[ "$destination" == "$CONFIG_DIR/config.json" && ! -e "$MV_FAIL_ONCE" ]]; then
            : > "$MV_FAIL_ONCE"
            return 73
        fi
        "$MV_REAL" "$@"
    }
    github_config_switch_local || rc=$?
    unset -f mv
    [[ "$rc" -ne 0 ]] || return 1
    _assert_local_switch_rolled_back || return 1
    github_config_close
}

@test "switch to local restores exact local state when session close fails" {
    _prepare_local_switch_fixture || return 1
    local rc=0
    export GIT_REAL CLOSE_STORE="$GITHUB_STORE"
    GIT_REAL=$(command -v git) || return 1
    git() {
        if [[ "$1" == "--git-dir=$CLOSE_STORE" && "$2" == worktree &&
              "$3" == remove ]]; then
            return 74
        fi
        "$GIT_REAL" "$@"
    }
    github_config_switch_local || rc=$?
    unset -f git
    [[ "$rc" -ne 0 ]] || return 1
    _assert_local_switch_rolled_back || return 1
    github_config_close
}

@test "rewrap push failure keeps one committed bundle pending without mixed worktree state" {
    _seed_age_revision || return 1
    local age="$BATS_TEST_TMPDIR/age-rewrap-success" held="$BATS_TEST_TMPDIR/held.git"
    local old_head new_head rc=0
    old_head=$(git -C "$GITHUB_WORKTREE" rev-parse HEAD) || return 1
    cat > "$age" <<'EOF'
#!/bin/bash
out=""
decrypt=false
while (($#)); do
    case "$1" in
        -d) decrypt=true; shift ;;
        -o) out="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ "$decrypt" == true ]]; then
    printf 'AGE-SECRET-KEY-REWRAP\n' > "$out"
else
    printf 'new-unlock\n' > "$out"
fi
EOF
    chmod +x "$age" || return 1
    AGE_BIN="$age"
    mv "$REMOTE" "$held" || return 1
    github_config_rewrap_master <<< $'old-password\nnew-password\nnew-password\n' || rc=$?
    mv "$held" "$REMOTE" || return 1
    [[ "$rc" -eq 0 ]] || return 1
    [[ "$GITHUB_SYNC_STATUS" == pending ]] || return 1
    [[ "$(cat "$GITHUB_WORKTREE/unlock.age")" == new-unlock ]] || return 1
    new_head=$(git -C "$GITHUB_WORKTREE" rev-parse HEAD) || return 1
    [[ "$new_head" != "$old_head" ]] || return 1
    git -C "$GITHUB_WORKTREE" diff --quiet || return 1
    git -C "$GITHUB_WORKTREE" diff --cached --quiet || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" rev-parse main)" == "$new_head" ]] || return 1
    github_config_close
}

@test "rotation push failure keeps the complete new age bundle pending" {
    _seed_age_revision || return 1
    local age="$BATS_TEST_TMPDIR/age-rotate" keygen="$BATS_TEST_TMPDIR/age-keygen"
    local held="$BATS_TEST_TMPDIR/held.git" old_identity="$BATS_TEST_TMPDIR/caller.key"
    local old_head new_head rc=0
    printf 'caller-key\n' > "$old_identity" || return 1
    chmod 600 "$old_identity" || return 1
    GITHUB_IDENTITY="$old_identity"
    old_head=$(git -C "$GITHUB_WORKTREE" rev-parse HEAD) || return 1
    cat > "$keygen" <<'EOF'
#!/bin/bash
printf '# public key: age1newrecipient\nAGE-SECRET-KEY-ROTATED\n'
EOF
    cat > "$age" <<'EOF'
#!/bin/bash
out=""
while (($#)); do
    if [[ "$1" == -o ]]; then out="${2:-}"; shift 2; else shift; fi
done
printf 'new-unlock\n' > "$out"
EOF
    chmod +x "$age" "$keygen" || return 1
    AGE_BIN="$age"
    AGE_KEYGEN_BIN="$keygen"
    confirm_yn() { return 0; }
    github_config_checkpoint() {
        printf 'new-state\n' > "$GITHUB_WORKTREE/state.json.age"
    }
    mv "$REMOTE" "$held" || return 1
    github_config_rotate_vault_key <<< $'master-password\nmaster-password\n' || rc=$?
    mv "$held" "$REMOTE" || return 1
    [[ "$rc" -eq 0 ]] || return 1
    [[ "$GITHUB_SYNC_STATUS" == pending ]] || return 1
    [[ "$(cat "$GITHUB_WORKTREE/recipient.txt")" == age1newrecipient ]] || return 1
    [[ "$(cat "$GITHUB_WORKTREE/unlock.age")" == new-unlock ]] || return 1
    [[ "$(cat "$GITHUB_WORKTREE/state.json.age")" == new-state ]] || return 1
    [[ "$(cat "$old_identity")" == caller-key ]] || return 1
    [[ "$GITHUB_IDENTITY" != "$old_identity" && -f "$GITHUB_IDENTITY" ]] || return 1
    [[ "$(_file_mode "$GITHUB_IDENTITY")" == 600 ]] || return 1
    [[ "$(_file_mode "$(dirname "$GITHUB_IDENTITY")")" == 700 ]] || return 1
    new_head=$(git -C "$GITHUB_WORKTREE" rev-parse HEAD) || return 1
    [[ "$new_head" != "$old_head" ]] || return 1
    git -C "$GITHUB_WORKTREE" diff --quiet || return 1
    git -C "$GITHUB_WORKTREE" diff --cached --quiet || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" rev-parse main)" == "$new_head" ]] || return 1
    github_config_close
    [[ -f "$old_identity" ]]
}

@test "fetch reopen failure keeps the old usable session and a same-process retry succeeds" {
    _seed_live_revision 1
    local old_worktree="$GITHUB_WORKTREE" old_session="$GITHUB_SESSION_ID"
    local calls="$BATS_TEST_TMPDIR/startup.calls" fetch_rc=0
    config_source_startup() {
        local count=0
        [[ -f "$calls" ]] && count=$(cat "$calls")
        count=$((count + 1))
        printf '%s\n' "$count" > "$calls"
        if [[ "$count" -eq 1 ]]; then
            _github_record_error "повторное открытие источника GitHub" \
                "Имитирован временный сбой повторного открытия."
            return 79
        fi
        return 0
    }

    github_sync_fetch || fetch_rc=$?
    [[ "$fetch_rc" -ne 0 ]] || return 1
    [[ "$GITHUB_WORKTREE" == "$old_worktree" ]] || return 1
    [[ "$GITHUB_SESSION_ID" == "$old_session" ]] || return 1
    [[ -d "$old_worktree" ]] || return 1
    git -C "$old_worktree" rev-parse --is-inside-work-tree >/dev/null || return 1
    git --git-dir="$GITHUB_STORE" show-ref --verify --quiet \
        "refs/heads/session/$old_session" || return 1

    github_sync_fetch || return 1
    [[ "$(cat "$calls")" == 2 ]]
}

@test "fetch restores runtime and auth when the old session cannot close" {
    _seed_live_revision 1
    local old_worktree="$GITHUB_WORKTREE" old_session="$GITHUB_SESSION_ID"
    local runtime="$BATS_TEST_TMPDIR/live-runtime" auth="$CONFIG_DIR/.auth"
    local rc=0
    mkdir -p "$runtime" || return 1
    printf 'old-runtime\n' > "$runtime/value" || return 1
    printf 'old-auth\n' > "$auth" || return 1
    STATE_DIR="$runtime"
    CONFIG_JSON="$runtime/value"
    export FETCH_RUNTIME_VALUE="$runtime/value" FETCH_AUTH_FILE="$auth"
    github_config_serialize() {
        jq -n --arg runtime "$(cat "$FETCH_RUNTIME_VALUE")" \
            --arg auth "$(cat "$FETCH_AUTH_FILE")" \
            '{runtime:$runtime,auth:$auth}' > "$1"
    }
    _config_source_materialize_state() {
        local snapshot="$1"
        jq -r '.runtime' "$snapshot" > "$FETCH_RUNTIME_VALUE" || return 1
        jq -r '.auth' "$snapshot" > "$FETCH_AUTH_FILE" || return 1
    }
    config_source_startup() {
        printf 'candidate-runtime\n' > "$FETCH_RUNTIME_VALUE" || return 1
        printf 'candidate-auth\n' > "$FETCH_AUTH_FILE" || return 1
        github_sync_init
    }
    export GIT_REAL CLOSE_STORE="$GITHUB_STORE" CLOSE_OLD_WORKTREE="$old_worktree"
    GIT_REAL=$(command -v git) || return 1
    git() {
        if [[ "$1" == "--git-dir=$CLOSE_STORE" && "$2" == worktree &&
              "$3" == remove && "${4:-}" == --force &&
              "${5:-}" == "$CLOSE_OLD_WORKTREE" ]]; then
            return 76
        fi
        "$GIT_REAL" "$@"
    }
    github_sync_fetch || rc=$?
    unset -f git
    [[ "$rc" -ne 0 ]] || return 1
    [[ "$(cat "$runtime/value")" == old-runtime ]] || return 1
    [[ "$(cat "$auth")" == old-auth ]] || return 1
    [[ "$GITHUB_WORKTREE" == "$old_worktree" ]] || return 1
    [[ "$GITHUB_SESSION_ID" == "$old_session" ]] || return 1
    [[ -d "$old_worktree" ]] || return 1
    github_config_close
}

@test "fetch retry without a worktree reaches startup instead of mandatory preflush" {
    github_sync_init || return 1
    github_config_close || return 1
    local marker="$BATS_TEST_TMPDIR/startup.called"
    config_source_startup() {
        printf 'called\n' > "$marker"
        return 0
    }

    github_sync_fetch || return 1
    [[ "$(cat "$marker")" == called ]]
}

@test "requested remote and branch mismatch cannot reuse or flush a live session" {
    _seed_live_revision 1
    local old_remote="$GITHUB_REMOTE" old_branch="$GITHUB_BRANCH"
    local old_worktree="$GITHUB_WORKTREE" old_session="$GITHUB_SESSION_ID"
    local old_main old_remote_head other="$BATS_TEST_TMPDIR/requested-other.git"
    local init_rc=0 flush_rc=0
    old_main=$(git --git-dir="$GITHUB_STORE" rev-parse "refs/heads/$old_branch") || return 1
    old_remote_head=$(git --git-dir="$old_remote" rev-parse "refs/heads/$old_branch") || return 1
    git init --bare -b other "$other" >/dev/null || return 1
    GITHUB_SESSION_REMOTE="$old_remote"
    GITHUB_SESSION_BRANCH="$old_branch"
    GITHUB_REMOTE="$other"
    GITHUB_BRANCH=other
    printf '{"storage_version":1,"encryption":"none","revision":99}\n' \
        > "$old_worktree/storage.json" || return 1

    github_sync_init || init_rc=$?
    github_sync_flush || flush_rc=$?
    [[ "$init_rc" -ne 0 ]] || return 1
    [[ "$flush_rc" -ne 0 ]] || return 1
    [[ "$GITHUB_WORKTREE" == "$old_worktree" ]] || return 1
    [[ "$GITHUB_SESSION_ID" == "$old_session" ]] || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" remote get-url origin)" == "$old_remote" ]] || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" rev-parse "refs/heads/$old_branch")" == "$old_main" ]] || return 1
    [[ "$(git --git-dir="$old_remote" rev-parse "refs/heads/$old_branch")" == "$old_remote_head" ]] || return 1
    _assert_remote_revision "$old_remote" 1 || return 1
    ! git --git-dir="$old_remote" show-ref --verify --quiet refs/heads/other || return 1
    ! git --git-dir="$other" show-ref --verify --quiet refs/heads/other
}

@test "saved session target mismatch fails before changing refs or remote content" {
    _seed_live_revision 1
    local old_remote="$GITHUB_REMOTE" old_branch="$GITHUB_BRANCH"
    local old_main old_remote_head other="$BATS_TEST_TMPDIR/saved-other.git"
    local init_rc=0 flush_rc=0
    old_main=$(git --git-dir="$GITHUB_STORE" rev-parse "refs/heads/$old_branch") || return 1
    old_remote_head=$(git --git-dir="$old_remote" rev-parse "refs/heads/$old_branch") || return 1
    git init --bare -b saved-other "$other" >/dev/null || return 1
    GITHUB_SESSION_REMOTE="$other"
    GITHUB_SESSION_BRANCH=saved-other
    printf '{"storage_version":1,"encryption":"none","revision":98}\n' \
        > "$GITHUB_WORKTREE/storage.json" || return 1

    github_sync_init || init_rc=$?
    github_sync_flush || flush_rc=$?
    [[ "$init_rc" -ne 0 ]] || return 1
    [[ "$flush_rc" -ne 0 ]] || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" remote get-url origin)" == "$old_remote" ]] || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" rev-parse "refs/heads/$old_branch")" == "$old_main" ]] || return 1
    [[ "$(git --git-dir="$old_remote" rev-parse "refs/heads/$old_branch")" == "$old_remote_head" ]] || return 1
    _assert_remote_revision "$old_remote" 1 || return 1
    ! git --git-dir="$other" show-ref --verify --quiet refs/heads/saved-other
}

@test "actual origin mismatch fails before pushing a live session to that origin" {
    _seed_live_revision 1
    local old_remote="$GITHUB_REMOTE" old_branch="$GITHUB_BRANCH"
    local old_main old_remote_head other="$BATS_TEST_TMPDIR/actual-other.git"
    local init_rc=0 flush_rc=0
    old_main=$(git --git-dir="$GITHUB_STORE" rev-parse "refs/heads/$old_branch") || return 1
    old_remote_head=$(git --git-dir="$old_remote" rev-parse "refs/heads/$old_branch") || return 1
    git init --bare -b "$old_branch" "$other" >/dev/null || return 1
    GITHUB_SESSION_REMOTE="$old_remote"
    GITHUB_SESSION_BRANCH="$old_branch"
    git --git-dir="$GITHUB_STORE" remote set-url origin "$other" || return 1
    printf '{"storage_version":1,"encryption":"none","revision":97}\n' \
        > "$GITHUB_WORKTREE/storage.json" || return 1

    github_sync_init || init_rc=$?
    github_sync_flush || flush_rc=$?
    [[ "$init_rc" -ne 0 ]] || return 1
    [[ "$flush_rc" -ne 0 ]] || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" remote get-url origin)" == "$other" ]] || return 1
    [[ "$(git --git-dir="$GITHUB_STORE" rev-parse "refs/heads/$old_branch")" == "$old_main" ]] || return 1
    [[ "$(git --git-dir="$old_remote" rev-parse "refs/heads/$old_branch")" == "$old_remote_head" ]] || return 1
    _assert_remote_revision "$old_remote" 1 || return 1
    ! git --git-dir="$other" show-ref --verify --quiet "refs/heads/$old_branch"
}

@test "account switch transaction rejects malformed marker reuse" {
    export GITHUB_ACCOUNT_SWITCH_DIR="$BATS_TEST_TMPDIR/account-switch"
    export GITHUB_ACCOUNT_SWITCH_MARKER="$GITHUB_ACCOUNT_SWITCH_DIR/transaction.json"
    export GITHUB_ACCOUNT_SWITCH_OLD_REPO=test-owner/config
    export GITHUB_ACCOUNT_SWITCH_NEW_REPO=other-owner/config
    export GITHUB_ACCOUNT_SWITCH_BRANCH=main
    export GITHUB_ACCOUNT_SWITCH_INITIAL_LOGIN=test-owner
    github_account_switch_begin \
        "$GITHUB_ACCOUNT_SWITCH_OLD_REPO" \
        "$GITHUB_ACCOUNT_SWITCH_NEW_REPO" main test-owner || return 1
    github_account_switch_marker_valid "$GITHUB_ACCOUNT_SWITCH_MARKER" || return 1
    printf '%s\n' '{}' > "$GITHUB_ACCOUNT_SWITCH_MARKER"
    ! github_account_switch_begin \
        "$GITHUB_ACCOUNT_SWITCH_OLD_REPO" \
        "$GITHUB_ACCOUNT_SWITCH_NEW_REPO" main test-owner
}

@test "account switch begin blocks another live worktree" {
    _seed_live_revision 1
    local other="$BATS_TEST_TMPDIR/other-worktree"
    git --git-dir="$GITHUB_STORE" worktree add "$other" main >/dev/null || return 1
    export GITHUB_ACCOUNT_SWITCH_DIR="$BATS_TEST_TMPDIR/account-switch"
    export GITHUB_ACCOUNT_SWITCH_MARKER="$GITHUB_ACCOUNT_SWITCH_DIR/transaction.json"
    if github_account_switch_begin test-owner/config other-owner/config main test-owner; then
        return 1
    fi
    [[ "${GITHUB_LAST_ERROR:-}" == *"Другой экземпляр уже использует рабочую копию"* ]] || return 1
}

@test "push unknown recovery accepts a remote descendant" {
    local seed="$BATS_TEST_TMPDIR/seed"
    git init -b main "$seed" >/dev/null
    git -C "$seed" config user.name seed
    git -C "$seed" config user.email seed@example.invalid
    git -C "$seed" commit --allow-empty -m base >/dev/null
    git -C "$seed" remote add origin "$REMOTE"
    git -C "$seed" push origin main >/dev/null
    local target="$BATS_TEST_TMPDIR/account-switch/target-store.git"
    mkdir -p "$BATS_TEST_TMPDIR/account-switch"
    git clone --bare "$REMOTE" "$target" >/dev/null
    local expected
    expected=$(git --git-dir="$target" rev-parse refs/heads/main)
    git -C "$seed" commit --allow-empty -m descendant >/dev/null
    git -C "$seed" push origin main >/dev/null
    export GITHUB_ACCOUNT_SWITCH_DIR="$BATS_TEST_TMPDIR/account-switch"
    export GITHUB_ACCOUNT_SWITCH_MARKER="$GITHUB_ACCOUNT_SWITCH_DIR/transaction.json"
    export GITHUB_ACCOUNT_SWITCH_OLD_REPO=test-owner/config
    export GITHUB_ACCOUNT_SWITCH_NEW_REPO=other-owner/config
    export GITHUB_ACCOUNT_SWITCH_BRANCH=main
    export GITHUB_ACCOUNT_SWITCH_INITIAL_LOGIN=test-owner
    _github_account_switch_write_marker push_unknown "$expected" true false false || return 1
    github_account_switch_recover || return 1
    [[ "$(jq -r '.phase' "$GITHUB_ACCOUNT_SWITCH_MARKER")" == target_committed ]] || return 1
}
