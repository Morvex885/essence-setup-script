#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
    load '../helpers/test_helper'
    setup_test_env
    load '../helpers/cmd_helper'
    load_core
    load '../helpers/mock_ssh'
    load_fixture_config
    open_local_session
    passfile=$(_script_pass_file)
    _hash_pass() { printf 'saved:%s\n' "$1"; }
    _verify_pass() { [[ "$1" == "saved:$2" ]]; }
}
teardown() { teardown_test_env; }

@test "self password-set installs, requires current password to change, rejects empty" {
    RC_REQUEST_SECRETS='{"password":"first"}'
    run_cmd self password-set
    [ "$status" -eq 0 ]
    [ "$(cat "$passfile")" = saved:first ]
    RC_REQUEST_SECRETS='{"password":"second"}'
    run_cmd self password-set
    [ "$(cmd_jq '.error.code')" = auth_required ]
    RC_REQUEST_SECRETS='{"password":"second","current-password":"wrong"}'
    run_cmd self password-set
    [ "$(cmd_jq '.error.code')" = auth_failed ]
    [ "$(cat "$passfile")" = saved:first ]
    RC_REQUEST_SECRETS='{"password":"","current-password":"first"}'
    run_cmd self password-set
    [ "$(cmd_jq '.error.code')" = invalid ]
    RC_REQUEST_SECRETS='{"password":"second","current-password":"first"}'
    run_cmd self password-set
    [ "$status" -eq 0 ]
    [ "$(cat "$passfile")" = saved:second ]
    [[ "$output$CMD_ENVELOPE" != *second* ]] || return 1
}

@test "self password-set rejects line breaks without installing or changing a password" {
    local candidate
    for candidate in $'first\nsecond' $'\nfirst' $'first\n'; do
        RC_REQUEST_SECRETS=$(printf '%s' "$candidate" | jq -Rs '{password:.}')
        run_cmd self password-set
        [ "$status" -eq 1 ]
        [ "$(cmd_jq '.error.code')" = invalid ]
        [ ! -e "$passfile" ]
    done
    RC_REQUEST_SECRETS='{"password":"first"}'
    run_cmd self password-set
    [ "$status" -eq 0 ]
    cp "$passfile" "$BATS_TEST_TMPDIR/password-before"
    RC_REQUEST_SECRETS='{"password":"second\nline","current-password":"first"}'
    run_cmd self password-set
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = invalid ]
    cmp -s "$passfile" "$BATS_TEST_TMPDIR/password-before"
    RC_REQUEST_SECRETS='{"password":"valid.","current-password":"first"}'
    run_cmd self password-set
    [ "$status" -eq 0 ]
    [ "$(cat "$passfile")" = saved:valid. ]
}

@test "self password-remove is gated and keeps the hash on denial or wrong password" {
    printf 'saved:second\n' > "$passfile"
    RC_REQUEST_SECRETS='{"current-password":"second"}'
    run_cmd self password-remove
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [ -e "$passfile" ]
    RC_REQUEST_SECRETS='{"current-password":"bad"}'
    run_cmd self password-remove --yes
    [ "$(cmd_jq '.error.code')" = auth_failed ]
    [ -e "$passfile" ]
    RC_REQUEST_SECRETS='{"current-password":"second"}'
    run_cmd self password-remove --yes
    [ "$status" -eq 0 ]
    [ ! -e "$passfile" ]
}

@test "failed updater preserves CURRENT_VERSION and reports installer_rc" {
    _self_is_root() { return 0; }
    printf '#!/bin/bash\nexit 3\n' > "$SCRIPT_DIR/install-remote-control.sh"
    CURRENT_VERSION=old-version
    run_cmd self update
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    run_cmd self update --yes
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = update_failed ]
    [ "$(cmd_jq '.error.installer_rc')" = 3 ]
    [ "$CURRENT_VERSION" = old-version ]
}

@test "self update checks installer and root before planning" {
    run_cmd self update
    [ "$(cmd_jq '.error.code')" = not_installed ]
    printf '#!/bin/bash\nexit 0\n' > "$SCRIPT_DIR/install-remote-control.sh"
    _self_is_root() { return 1; }
    run_cmd self update --yes
    [ "$(cmd_jq '.error.code')" = root_required ]
}

@test "self update success returns data without exiting" {
    _self_is_root() { return 0; }
    printf '#!/bin/bash\nexit 0\n' > "$SCRIPT_DIR/install-remote-control.sh"
    CURRENT_VERSION=1.0.0
    run_cmd self update --yes
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '{"from":"1.0.0","restart_required":true}' ]
}

@test "self update that rewrites the running entrypoint in place returns the command's own result" {
    bats_require_minimum_version 1.5.0
    local app="$BATS_TEST_TMPDIR/app" home="$BATS_TEST_TMPDIR/home" t_entry new line start offset version
    mkdir -p "$app/modules" "$app/common" "$home"
    cp "$PROJECT_ROOT/remote-control/remote-control-essence.sh" "$PROJECT_ROOT/VERSION" "$app/"
    cp "$PROJECT_ROOT/remote-control/modules/"*.sh "$app/modules/"
    cp -R "$PROJECT_ROOT/common/." "$app/common/"
    t_entry="$app/remote-control-essence.sh"
    version=$(tr -d '\r' < "$app/VERSION")
    # Только в этой копии: обновление без root.
    printf '\n_self_is_root() { return 0; }\n' >> "$app/modules/self.sh"
    # Новая версия другой длины: с байта, где кончается строка cli_main старого
    # файла, начинается код, который не должен выполниться.
    line=$(grep -m1 '^cli_main ' "$t_entry")
    start=$(grep -m1 -bo '^cli_main .*' "$t_entry" | cut -d: -f1)
    offset=$((start + ${#line} + 1))
    new="$BATS_TEST_TMPDIR/new-entrypoint.sh"
    { head -c "$((offset - 1))" /dev/zero | tr '\0' '#'; printf '\necho SHOULD_NOT_RUN\nexit 42\n'; } > "$new"
    [ "$(wc -c < "$new")" -ne "$(wc -c < "$t_entry")" ]
    # Как установщик: cp поверх того же файла (тот же inode).
    printf '#!/bin/bash\ncat "%s" > "%s"\n' "$new" "$t_entry" > "$app/install-remote-control.sh"
    _rc_installed() {
        env -u CONFIG_DIR -u CONFIG_JSON -u TEMPLATES_DIR -u GENERATED_DIR -u SCRIPT_DIR \
            HOME="$home" RC_DEPS_READY=1 "$BASH" "$t_entry" "$@" < /dev/null
    }
    run _rc_installed source init-local
    [ "$status" -eq 0 ]
    run --separate-stderr _rc_installed self update --yes --json
    [ "$status" -eq 0 ]
    [ "$output" = "{\"ok\":true,\"data\":{\"from\":\"$version\",\"restart_required\":true}}" ]
    [[ "$output$stderr" != *SHOULD_NOT_RUN* ]] || return 1
    cmp -s "$new" "$t_entry"
}

@test "self version reports unreachable network as checked false" {
    curl() { return 7; }
    CURRENT_VERSION=1.0.0
    run_cmd self version
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '{"current":"1.0.0","latest":null,"update_available":false,"checked":false}' ]
    curl() { echo '{"tag_name": "v2.0.0"}'; }
    run_cmd self version
    [ "$(cmd_jq -c '.data | [.latest,.update_available,.checked]')" = '["v2.0.0",true,true]' ]
}

@test "self version passes GITHUB_TOKEN to curl only through stdin config" {
    CURRENT_VERSION=1.0.0
    GITHUB_TOKEN=ghp_secret_token_value
    curl() {
        printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/curl.argv"
        if [[ " $* " == *" --config - "* ]]; then cat > "$BATS_TEST_TMPDIR/curl.stdin"; fi
        echo '{"tag_name": "v2.0.0"}'
    }
    run_cmd self version
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.latest')" = v2.0.0 ]
    ! grep -q 'ghp_secret_token_value' "$BATS_TEST_TMPDIR/curl.argv" || return 1
    [ "$(cat "$BATS_TEST_TMPDIR/curl.stdin")" = 'header = "Authorization: token ghp_secret_token_value"' ]
}

@test "uninstall rejects HOME aliases before deletion" {
    _self_is_root() { return 0; }
    HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
    CONFIG_DIR="$HOME/./"
    rm() { touch "$BATS_TEST_TMPDIR/rm.called"; }
    run_cmd self uninstall --remove-data --yes
    [ "$status" -eq 1 ]
    [ "$(cmd_jq '.error.code')" = unsafe_path ]
    [ ! -e "$BATS_TEST_TMPDIR/rm.called" ]
    unset -f rm
}

@test "uninstall without --yes plans only and requires root" {
    _self_is_root() { return 1; }
    run_cmd self uninstall
    [ "$(cmd_jq '.error.code')" = root_required ]
    _self_is_root() { return 0; }
    rm() { touch "$BATS_TEST_TMPDIR/rm.called"; }
    run_cmd self uninstall
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [ ! -e "$BATS_TEST_TMPDIR/rm.called" ]
    unset -f rm
}

@test "uninstall rm failure never removes local data" {
    _self_is_root() { return 0; }
    marker="$CONFIG_DIR/preserved"; touch "$marker"
    calls=()
    rm() { calls+=("$*"); return 1; }
    run_cmd self uninstall --remove-data --yes
    [ "$status" -eq 1 ]
    [[ ${#calls[@]} == 1 && -f "$marker" ]]
    unset -f rm
}

@test "uninstall success returns removed paths and data_kept" {
    _self_is_root() { return 0; }
    rm() { return 0; }
    run_cmd self uninstall --yes
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.data_kept')" = true ]
    [ "$(cmd_jq '.data.removed | length')" = 2 ]
    unset -f rm
}

@test "status reports update, script_password and nested source" {
    printf 'saved:x\n' > "$passfile"
    run_cmd status
    [ "$status" -eq 0 ]
    [ "$(cmd_jq '.data.script_password')" = true ]
    [ "$(cmd_jq '.data.source.type')" = local ]
    [ "$(cmd_jq '.data.update | keys | join(",")')" = available,current,latest ]
}

# GitHub через локальный bare-репозиторий: аккаунт и gh заглушены.
_github_fixture() {
    load_fixture_template
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
    git config --global user.name test
    git config --global user.email test@example.invalid
    GITHUB_REMOTE="$BATS_TEST_TMPDIR/remote.git"
    git init --bare -b main "$GITHUB_REMOTE" >/dev/null
    _github_ensure_deps() { return 0; }
    _github_prepare_account() { return 0; }
}

@test "source status reports a local source without GitHub fields" {
    run_cmd source status
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '{"type":"local","repo":null,"branch":null,"storage":null,"sync":null,"key_saved":null}' ]
}

@test "GitHub-only source commands refuse a local source" {
    local verb
    for verb in github-fetch github-push github-delete-repo github-switch-local github-rotate-key; do
        run_cmd source "$verb" --yes
        [ "$(cmd_jq '.error.code')" = not_ready ] || return 1
    done
    [ "$CONFIG_SOURCE" = local ]
}

@test "source github-accounts lists saved profiles and the global login" {
    mkdir -p "$GITHUB_CREDENTIALS_DIR/gh/test-owner" "$GITHUB_CREDENTIALS_DIR/gh/empty"
    : > "$GITHUB_CREDENTIALS_DIR/gh/test-owner/hosts.yml"
    _github_load_global_login() { GITHUB_GLOBAL_LOGIN=global-user; }
    run_cmd source github-accounts
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '{"accounts":["test-owner"],"global_login":"global-user"}' ]
}

@test "source github-login runs gh web login without stdin and reports failures" {
    local fake="$BATS_TEST_TMPDIR/gh"
    cat > "$fake" <<'EOF'
#!/bin/bash
if IFS= read -r line; then printf 'stdin:%s\n' "$line" >> "$GH_STDIN_LOG"; fi
[[ "${GH_FAKE_FAIL:-0}" == 1 ]] && { printf 'browser authorization failed: token=ghp_WebSecret123\n' >&2; exit 1; }
printf 'user: test-owner\n' > "$GH_CONFIG_DIR/hosts.yml"
EOF
    chmod +x "$fake"
    export GH_BIN="$fake" GH_STDIN_LOG="$BATS_TEST_TMPDIR/gh-stdin"
    _github_ensure_deps() { return 0; }
    _github_account_login() { return 0; }
    run_cmd source github-login --login test-owner <<< 'y'
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '{"login":"test-owner"}' ]
    [ ! -e "$GH_STDIN_LOG" ]
    export GH_FAKE_FAIL=1
    run_cmd source github-login --login test-owner
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = github_auth_required ]
    [[ "$(cmd_jq '.error.hint')" == *"gh auth login --hostname github.com --web"* ]]
    [[ "$output$CMD_ENVELOPE" != *ghp_WebSecret123* ]]
}

@test "source github-connect requires --login and reports github_auth_required with a hint" {
    run_cmd source github-connect --storage none
    [ "$status" -eq 2 ]
    [ "$(cmd_jq '.error.code')" = usage ]
    _github_ensure_deps() { return 0; }
    _github_prepare_account() {
        _github_record_error "авторизация аккаунта GitHub" "нет токена" true "Выполните: gh auth login"
        return 1
    }
    run_cmd source github-connect --login test-owner --storage none
    [ "$status" -eq 2 ]
    [ "$(cmd_jq -c '.error | [.code,.login,.hint]')" = '["github_auth_required","test-owner","Выполните: gh auth login"]' ]
    [ "$CONFIG_SOURCE" = local ]
    [ ! -e "$CONFIG_DIR/source.json" ]
}

@test "source github-connect asks before creating a missing repository" {
    _github_ensure_deps() { return 0; }
    _github_prepare_account() { return 0; }
    _github_gh() {
        printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/gh.calls"
        case "$2 $3" in
            "repo view") printf 'repository not found\n'; return 1 ;;
        esac
    }
    GITHUB_REMOTE=""
    run_cmd source github-connect --login test-owner --storage none
    [ "$status" -eq 2 ]
    [ "$(cmd_jq -c '.error | [.code,.repo]')" = '["repo_create_required","test-owner/essence-remote-control-config"]' ]
    ! grep -q 'repo create' "$BATS_TEST_TMPDIR/gh.calls" || return 1
    [ ! -e "$CONFIG_DIR/source.json" ]
}

@test "public repository needs an explicit make-private decision" {
    _github_ensure_deps() { return 0; }
    _github_prepare_account() { return 0; }
    _github_gh() {
        printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/gh.calls"
        case "$2 $3" in
            "repo view") printf '{"visibility":"PUBLIC"}\n' ;;
        esac
    }
    GITHUB_OWNER=test-owner GITHUB_REMOTE=""
    github_sync_init true onboarding true && return 1
    [ "$RC_ERROR_CODE" = repo_private_required ]
    [ "$(jq -r .repo <<< "$RC_ERROR_EXTRA")" = test-owner/essence-remote-control-config ]
    ! grep -q 'repo edit' "$BATS_TEST_TMPDIR/gh.calls"
}

@test "source github-connect decisions: storage, vault password, key provisioning" {
    _github_fixture
    run_cmd source github-connect --login test-owner
    [ "$status" -eq 2 ]
    [ "$(cmd_jq -c '.error | [.code,.choices]')" = '["storage_mode_required",["age","none"]]' ]
    [ "$CONFIG_SOURCE" = local ]
    [ ! -e "$CONFIG_DIR/source.json" ]
    AGE_BIN=true
    run_cmd source github-connect --login test-owner --storage age
    [ "$(cmd_jq '.error.code')" = new_vault_password_required ]
    run_cmd source github-connect --login test-owner --storage none
    [ "$status" -eq 2 ]
    [ "$(cmd_jq -c '.error | [.code,.nodes]')" = '["key_provisioning_required",["de-vps"]]' ]
    [ ! -e "$CONFIG_DIR/source.json" ]
    # Закрепление ключей серверов (SSH) проверяется в onboarding_recovery.bats:
    # дальше — конфигурация без нод.
    jq_w '.nodes = [] | .connections = [] | .clients |= map(select(.name != "my-pc"))'
    run_cmd source github-connect --login test-owner --storage none --provision-keys no --yes
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data | [.repo,.storage]')" = '["test-owner/essence-remote-control-config","none"]' ]
    [ "$(jq -r .type "$CONFIG_DIR/source.json")" = github ]
    [ "$CONFIG_SOURCE" = github ]
    run_cmd source github-connect --login test-owner --storage none
    [ "$(cmd_jq '.error.code')" = conflict ]
}

@test "source github-connect to an existing configuration needs --existing with counts" {
    _github_fixture
    jq_w '.nodes = [] | .connections = [] | .clients |= map(select(.name != "my-pc"))'
    run_cmd source github-connect --login test-owner --storage none --provision-keys no --yes
    [ "$status" -eq 0 ]
    run_cmd source github-switch-local
    [ "$status" -eq 0 ]
    [ "$(cmd_jq -c '.data')" = '{"source":"local"}' ]
    GITHUB_REMOTE="$BATS_TEST_TMPDIR/remote.git"
    run_cmd source github-connect --login test-owner
    [ "$status" -eq 2 ]
    [ "$(cmd_jq -c '.error | [.code,.choices,.remote_counts.clients,.local_counts.clients]')" = \
        '["existing_config_action_required",["remote","local"],1,1]' ]
    [ ! -e "$CONFIG_DIR/source.json" ]
    run_cmd source github-connect --login test-owner --existing remote
    [ "$status" -eq 0 ]
    [ "$(jq -r .type "$CONFIG_DIR/source.json")" = github ]
}

@test "recovery commands check the script password themselves" {
    printf 'saved:secret\n' > "$passfile"
    RC_SESSION_OPEN=0 RC_SESSION_AUTHORIZED=0
    run_cmd source github-replace-with-local --yes
    [ "$(cmd_jq '.error.code')" = auth_required ]
    RC_REQUEST_SECRETS='{"script-password":"wrong"}'
    run_cmd source github-migrate-format --yes
    [ "$(cmd_jq '.error.code')" = auth_failed ]
    RC_REQUEST_SECRETS='{"script-password":"secret"}'
    run_cmd source github-migrate-format --yes
    [ "$(cmd_jq '.error.code')" = not_ready ]
    [ "$RC_SESSION_AUTHORIZED" = 1 ]
}

# ─── security round 1: github (S-M9, S-M11) ─────────────────────────────────

# Файлы конфигурации CONFIG_DIR (без рабочих копий git, блокировки и журнала
# run_cmd) с хешами.
_gh_config_files() {
    (cd "$CONFIG_DIR" && find . -path ./github-store.git -prune -o -path ./github-sessions -prune \
        -o -path ./.rc-lock -prune -o -path ./cmd.log -prune -o -type f -print | LC_ALL=C sort |
        while IFS= read -r f; do
            printf '%s %s\n' "$(cksum < "$f")" "$f"
        done)
}

# SSH-шаг подключения заглушен, вызовы — в onboarding.calls; запуск только
# отмечает ноды отложенной SSH-настройкой (как --provision-keys no без SSH).
_gh_stub_onboarding() {
    onboarding_plan_lines() {
        printf 'plan:%s\n' "$1" >> "$BATS_TEST_TMPDIR/onboarding.calls"
        CORE_PLAN_LINES+=("Будет создан переносимый SSH-ключ: de-vps")
    }
    _github_initial_portable_onboarding() {
        local id
        printf 'run:%s\n' "$1" >> "$BATS_TEST_TMPDIR/onboarding.calls"
        for id in $(jq_r '.nodes[] | select(.auth == "key") | .id'); do
            state_portability_add_issue "$id" missing_identity || return 1
        done
        for id in $(jq_r '.nodes[].id'); do
            state_portability_add_issue "$id" missing_host_key || return 1
        done
    }
}

@test "source github-connect --storage none is plan-gated and writes nothing before consent" {
    _github_fixture
    jq_w '.nodes = [] | .connections = [] | .clients |= map(select(.name != "my-pc"))'
    local before token
    before=$(_gh_config_files)
    run_cmd source github-connect --login test-owner --storage none
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [[ "$(cmd_jq -c '.error.plan')" == *'Репозиторий: test-owner/essence-remote-control-config'* ]]
    [[ "$(cmd_jq -c '.error.plan')" == *'Пароли SSH и ключи будут храниться в GitHub без шифрования'* ]]
    [ -z "$(git --git-dir="$GITHUB_REMOTE" for-each-ref)" ]
    [ "$CONFIG_SOURCE" = local ]
    [ "$(_gh_config_files)" = "$before" ]
    token=$(cmd_jq '.error.plan_token')
    run_cmd source github-connect --login test-owner --storage none --yes --plan-token "$token"
    [ "$status" -eq 0 ]
    [ "$(git --git-dir="$GITHUB_REMOTE" show main:storage.json | jq -r .encryption)" = none ]
    [ "$CONFIG_SOURCE" = github ]
    [ ! -e "$CONFIG_DIR/runtime-vault.json" ]
}

@test "source github-connect --existing local is plan-gated with both configurations" {
    _github_fixture
    jq_w '.nodes = [] | .connections = [] | .clients |= map(select(.name != "my-pc"))'
    run_cmd source github-connect --login test-owner --storage none --provision-keys no --yes
    [ "$status" -eq 0 ]
    run_cmd source github-switch-local
    [ "$status" -eq 0 ]
    GITHUB_REMOTE="$BATS_TEST_TMPDIR/remote.git"
    jq_w '.clients = []'
    local head before token
    head=$(git --git-dir="$GITHUB_REMOTE" rev-parse main)
    before=$(_gh_config_files)
    run_cmd source github-connect --login test-owner --existing local
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [[ "$(cmd_jq -c '.error.plan')" == *'Конфигурация GitHub (нод 0, клиентов 1, групп 3) будет заменена конфигурацией этого компьютера (нод 0, клиентов 0, групп 3).'* ]]
    [[ "$(cmd_jq -c '.error.plan')" == *'без шифрования'* ]]
    [ "$(git --git-dir="$GITHUB_REMOTE" rev-parse main)" = "$head" ]
    [ ! -e "$CONFIG_DIR/source.json" ]
    [ "$(_gh_config_files)" = "$before" ]
    token=$(cmd_jq '.error.plan_token')
    run_cmd source github-connect --login test-owner --existing local --yes --plan-token "$token"
    [ "$status" -eq 0 ]
    [ "$(git --git-dir="$GITHUB_REMOTE" rev-parse main)" != "$head" ]
    [ "$(jq -r .type "$CONFIG_DIR/source.json")" = github ]
}

@test "source github-connect --provision-keys yes plans node SSH actions before running them" {
    _github_fixture
    _gh_stub_onboarding
    local token
    # Хранение age само не требует согласия: план подключения требуют SSH-действия.
    RC_REQUEST_SECRETS='{"new-vault-password":"vault-pass"}'
    run_cmd source github-connect --login test-owner --storage age --provision-keys yes
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [[ "$(cmd_jq -c '.error.plan')" == *'Будет создан переносимый SSH-ключ: de-vps'* ]]
    [[ "$(cmd_jq -c '.error.plan')" == *'Хранение: зашифровано паролем доступа (age).'* ]]
    [[ "$output$CMD_ENVELOPE" != *vault-pass* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/onboarding.calls")" = 'plan:yes' ]
    [ -z "$(git --git-dir="$GITHUB_REMOTE" for-each-ref)" ]
    [ ! -e "$CONFIG_DIR/source.json" ]
    RC_REQUEST_SECRETS=''
    rm -f "$BATS_TEST_TMPDIR/onboarding.calls"
    run_cmd source github-connect --login test-owner --storage none --provision-keys yes
    token=$(cmd_jq '.error.plan_token')
    run_cmd source github-connect --login test-owner --storage none --provision-keys yes --yes --plan-token "$token"
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/onboarding.calls")" = $'plan:yes\nplan:yes\nrun:yes' ]
}

@test "source github-replace-with-local plans node SSH actions and keeps no plaintext snapshot" {
    _github_fixture
    _gh_stub_onboarding
    local with_nodes="$BATS_TEST_TMPDIR/with-nodes.json" head token
    cp "$CONFIG_JSON" "$with_nodes"
    jq_w '.nodes = [] | .connections = [] | .clients |= map(select(.name != "my-pc"))'
    run_cmd source github-connect --login test-owner --storage none --provision-keys no --yes
    [ "$status" -eq 0 ]
    cp "$with_nodes" "$CONFIG_DIR/config.json"
    head=$(git --git-dir="$GITHUB_REMOTE" rev-parse main)
    rm -f "$BATS_TEST_TMPDIR/onboarding.calls"
    run_cmd source github-replace-with-local --provision-keys yes
    [ "$(cmd_jq '.error.code')" = confirmation_required ]
    [[ "$(cmd_jq -c '.error.plan')" == *'Будет создан переносимый SSH-ключ: de-vps'* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/onboarding.calls")" = 'plan:yes' ]
    [ "$(git --git-dir="$GITHUB_REMOTE" rev-parse main)" = "$head" ]
    token=$(cmd_jq '.error.plan_token')
    run_cmd source github-replace-with-local --provision-keys yes --yes --plan-token "$token"
    [ "$status" -eq 0 ]
    [ "$(tail -n 1 "$BATS_TEST_TMPDIR/onboarding.calls")" = 'run:yes' ]
    [ "$(git --git-dir="$GITHUB_REMOTE" rev-parse main)" != "$head" ]
    [ ! -e "$CONFIG_DIR/runtime-vault.json" ]
}
