#!/usr/bin/env bats
# TUI: boundary: — линтер границы слоя remote-control/tui;
# client: — клиент serve (tui/client.sh) против фальшивого и настоящего serve.
bats_require_minimum_version 1.5.0

setup() {
    load '../helpers/test_helper'
    setup_test_env
    export TUI_DIR="$PROJECT_ROOT/remote-control/tui"
    export FAKE="$BATS_TEST_TMPDIR/fake"
    mkdir -p "$FAKE"
    # Снимок слоя на время теста: правка common.sh/tui/*.sh в рабочем дереве
    # посреди прогона не должна менять то, что видит этот тест.
    export SNAP="$BATS_TEST_TMPDIR/snap"
    mkdir -p "$SNAP/common"
    cp "$PROJECT_ROOT/common/common.sh" "$SNAP/common/"
    cp -R "$TUI_DIR" "$SNAP/tui"
    # Фальшивый serve: hello, затем на n-й запрос — строки из reply.n
    # (@ID@ → id запроса). Нет файла ответа — процесс завершается (EOF).
    cat > "$FAKE/serve.sh" <<'EOF'
#!/bin/bash
printf '%s\n' '{"event":"hello","protocol":1,"version":"test"}'
n=0
while IFS= read -r line; do
    printf '%s\n' "$line" >> "$FAKE/requests.log"
    n=$((n + 1))
    id=$(printf '%s' "$line" | jq -r '.id')
    [[ -f "$FAKE/reply.$n" ]] || exit 0
    while IFS= read -r reply; do
        printf '%s\n' "${reply//@ID@/$id}"
    done < "$FAKE/reply.$n"
done
EOF
    chmod +x "$FAKE/serve.sh"
}

teardown() { teardown_test_env; }

# tui_sh CODE — CODE в чистом bash с client.sh и запущенным фальшивым serve.
tui_sh() {
    run bash -c '
        source "$SNAP/common/common.sh"
        source "$SNAP/tui/client.sh"
        declare -F box_top >/dev/null && declare -F review_frame >/dev/null || { echo "common.sh не загружен"; exit 99; }
        tui_on_int() { exit 130; }
        RC_ENTRYPOINT="$FAKE/serve.sh"
        tui_serve_start
        eval "$1"
    ' _ "$1"
}

reply() { local n="$1"; shift; printf '%s\n' "$@" > "$FAKE/reply.$n"; }

# ─── boundary ────────────────────────────────────────────────────────────────

@test "boundary: tui files have valid syntax and no set -e" {
    local f
    for f in "$TUI_DIR"/*.sh; do
        /bin/bash -n "$f"
        ! grep -nE '^[[:space:]]*set -[a-z]*e' "$f" || return 1
    done
}

# Запрещённые обращения к ядру и литералы кодов ошибок протокола, которые экраны
# сравнивают точно: перед проверкой `\bgithub_` эти коды вырезаются из строки.
BOUNDARY_PATTERNS=('core_' 'jq_r' 'jq_w' 'ssh_run' 'scp_run' 'state_action' 'rc_locked'
    'rc_dispatch' 'cli_cmd_' 'CONFIG_JSON' 'config\.json' 'node_load' '\bgithub_' '\b_github_'
    'modules/' 'source .*remote-control-essence')
BOUNDARY_CODES='github_auth_required|github_format_outdated|github_format_newer|github_format_invalid'

# _boundary_scan FILE… — нарушения границы строками «файл: [шаблон] номер:строка».
_boundary_scan() {
    local f pattern hit
    for f in "$@"; do
        for pattern in "${BOUNDARY_PATTERNS[@]}"; do
            while IFS= read -r hit; do
                printf '%s: [%s] %s\n' "$f" "$pattern" "$hit"
            done < <(sed -E "s/\\b(${BOUNDARY_CODES})\\b//g" "$f" | grep -nE -- "$pattern")
        done
    done
}

@test "boundary: tui does not reach into the core" {
    run _boundary_scan "$TUI_DIR"/*.sh
    [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "boundary: the linter allows exact error codes but not core calls" {
    local probe="$BATS_TEST_TMPDIR/probe.sh"
    printf '%s\n' 'case "$TUI_CODE" in github_auth_required|github_format_newer) ;; esac' > "$probe"
    run _boundary_scan "$probe"
    [ -z "$output" ]
    printf '%s\n' 'github_config_open "$dir" "$out"' > "$probe"
    run _boundary_scan "$probe"
    [[ "$output" == *'[\bgithub_]'* ]]
    printf '%s\n' 'github_format_newer_hint; _github_select_account' > "$probe"
    run _boundary_scan "$probe"
    [[ "$output" == *'[\bgithub_]'* && "$output" == *'[\b_github_]'* ]]
}

@test "boundary: main.sh sources only common.sh and tui files" {
    local line
    while IFS= read -r line; do
        [[ "$line" == *'common/common.sh'* || "$line" == *'source "$tui_file"'* ]] || {
            echo "unexpected: $line"; return 1
        }
    done < <(grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "$TUI_DIR/main.sh")
    grep -q 'source "\$SCRIPT_DIR/common/common.sh"' "$TUI_DIR/main.sh"
    grep -q '"\$SCRIPT_DIR"/tui/\*.sh' "$TUI_DIR/main.sh"
}

@test "boundary: other tui files source only common.sh or tui files" {
    local f line
    for f in "$TUI_DIR"/*.sh; do
        [[ "${f##*/}" != main.sh ]] || continue
        while IFS= read -r line; do
            [[ "$line" == *'common/common.sh'* || "$line" == *'/tui/'* ]] || {
                echo "$f: $line"; return 1
            }
        done < <(grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "$f" || true)
    done
}

@test "boundary: jq never receives secrets through --arg or --argjson" {
    run grep -nE -- '--arg(json)?[[:space:]]+[^[:space:]]+[[:space:]]+"?\$\{?(TUI_SECRETS|RC_REQUEST_SECRETS|pw|pass[A-Za-z_]*|[A-Za-z_]*_?[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][A-Za-z_]*)' \
        "$TUI_DIR"/*.sh "$PROJECT_ROOT"/remote-control/modules/*.sh
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

# ─── client ──────────────────────────────────────────────────────────────────

@test "client: log events are rendered with prefixes before the reply" {
    reply 1 \
        '{"id":@ID@,"event":"log","level":"info","text":"шаг один"}' \
        '{"id":@ID@,"event":"log","level":"success","text":"готово"}' \
        '{"id":@ID@,"event":"log","level":"warn","text":"внимание"}' \
        '{"id":@ID@,"event":"log","level":"error","text":"сбой"}' \
        '{"id":@ID@,"event":"log","level":"output","text":"сырая строка"}' \
        '{"id":@ID@,"ok":true,"data":null}'
    tui_sh 'tui_call group list; echo "rc=$?"'
    [ "$status" -eq 0 ]
    [[ "$output" == *'[*]'*'шаг один'* ]]
    [[ "$output" == *'[✓]'*'готово'* ]]
    [[ "$output" == *'[!]'*'внимание'* ]]
    [[ "$output" == *'[✗]'*'сбой'* ]]
    [[ "$output" == *$'\nсырая строка'* ]]
    [[ "$output" == *'rc=0'* ]]
}

@test "client: replies of other ids and hello are ignored" {
    reply 1 \
        '{"id":999,"event":"log","level":"info","text":"чужое"}' \
        '{"id":999,"ok":false,"error":{"code":"failed","message":"x"}}' \
        '{"id":@ID@,"ok":true,"data":{"a":1}}'
    tui_sh 'tui_call group list; echo "ok=$TUI_OK data=$TUI_DATA"'
    [[ "$output" != *чужое* ]]
    [[ "$output" == *'ok=true data={"a":1}'* ]]
}

@test "client: success and error replies fill TUI_OK TUI_CODE TUI_DATA TUI_ERROR" {
    reply 1 '{"id":@ID@,"ok":true,"data":[{"name":"a b"}]}'
    reply 2 '{"id":@ID@,"ok":false,"error":{"code":"not_found","message":"нет","plan":["x","y"],"plan_token":"T"}}'
    tui_sh '
        tui_call node list; echo "rc1=$? ok=$TUI_OK code=[$TUI_CODE] name=$(tui_q ".[0].name")"
        tui_call node show --name z; echo "rc2=$? ok=$TUI_OK code=$TUI_CODE data=$TUI_DATA"
        echo "token=$(tui_eq .plan_token) plan=$(tui_eq ".plan | join(\",\")")"
        echo "resp=$TUI_RESPONSE"
    '
    [[ "$output" == *'rc1=0 ok=true code=[] name=a b'* ]]
    [[ "$output" == *'rc2=1 ok=false code=not_found data=null'* ]]
    [[ "$output" == *'token=T plan=x,y'* ]]
    [[ "$output" == *'resp={"id":2,"ok":false'* ]]
}

@test "client: argv is sent as an array with the request id" {
    reply 1 '{"id":@ID@,"ok":true}'
    tui_sh 'tui_call client add --name "my pc" --group ""'
    jq -e '.id == 1 and .argv == ["client","add","--name","my pc","--group",""] and (has("secrets") | not)' \
        "$FAKE/requests.log" >/dev/null
}

@test "client: secrets travel only in the secrets field" {
    export SECRET='p"a$s s\ёж'
    reply 1 '{"id":@ID@,"ok":true}'
    tui_sh 'tui_secret password "$SECRET"; tui_call node password --name n1; tui_secrets_clear; echo "left=[${TUI_SECRETS:-}]"'
    [[ "$output" == *'left=[]'* ]]
    jq -e --arg s "$SECRET" \
        '.secrets.password == $s and (.argv | tojson | contains($s) | not) and .argv == ["node","password","--name","n1"]' \
        "$FAKE/requests.log" >/dev/null
    [[ "$output" != *"$SECRET"* ]]
}

@test "client: two tui_secret calls keep both values and jq argv never contains them" {
    export SECRET1='first-secret-ONE' SECRET2='second-secret-TWO'
    mkdir -p "$BATS_TEST_TMPDIR/stub"
    export REAL_JQ ARGV_LOG="$BATS_TEST_TMPDIR/jq-argv.log"
    REAL_JQ=$(command -v jq)
    cat > "$BATS_TEST_TMPDIR/stub/jq" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ARGV_LOG"
exec "$REAL_JQ" "$@"
EOF
    chmod +x "$BATS_TEST_TMPDIR/stub/jq"
    reply 1 '{"id":@ID@,"ok":true}'
    PATH="$BATS_TEST_TMPDIR/stub:$PATH" tui_sh '
        tui_secret current-password "$SECRET1"
        tui_secret password "$SECRET2"
        tui_call self password-set
    '
    [ "$status" -eq 0 ]
    [ -s "$ARGV_LOG" ]
    ! grep -qF -e "$SECRET1" -e "$SECRET2" "$ARGV_LOG" || return 1
    jq -e --arg a "$SECRET1" --arg b "$SECRET2" \
        '.secrets == {"current-password":$a, "password":$b}' "$FAKE/requests.log" >/dev/null
}

@test "client: serve EOF ends the process with exit 1 and a message" {
    tui_sh 'tui_call group list; echo "unreachable"'
    [ "$status" -eq 1 ]
    [[ "$output" == *'неожиданно завершилось'* ]]
    [[ "$output" != *unreachable* ]]
}

@test "client: refused confirmation makes no second call" {
    reply 1 '{"id":@ID@,"ok":false,"error":{"code":"confirmation_required","message":"m","plan":["Группа: A"],"plan_token":"T1"}}'
    tui_sh 'tui_run_confirmed "Удаление" "Удалить?" group delete --name A; echo "rc=$?"' <<< 'n'
    [[ "$output" == *'Группа: A'* ]]
    [[ "$output" == *'Отменено.'* ]]
    [[ "$output" == *'rc=1'* ]]
    [ "$(wc -l < "$FAKE/requests.log" | tr -d ' ')" -eq 1 ]
}

@test "client: EOF at the question counts as refusal" {
    reply 1 '{"id":@ID@,"ok":false,"error":{"code":"confirmation_required","message":"m","plan":["x"],"plan_token":"T1"}}'
    tui_sh 'tui_run_confirmed "Удаление" "Удалить?" group delete --name A </dev/null; echo "rc=$?"'
    [[ "$output" == *'rc=1'* ]]
    [ "$(wc -l < "$FAKE/requests.log" | tr -d ' ')" -eq 1 ]
}

@test "client: consent repeats the call with --yes and the plan token" {
    reply 1 '{"id":@ID@,"ok":false,"error":{"code":"confirmation_required","message":"m","plan":["Группа: A"],"plan_token":"T1"}}'
    reply 2 '{"id":@ID@,"ok":true,"data":{"name":"A"}}'
    tui_sh 'tui_run_confirmed "Удаление" "Удалить?" group delete --name A; echo "rc=$? data=$TUI_DATA"' <<< 'y'
    [[ "$output" == *'rc=0 data={"name":"A"}'* ]]
    [ "$(wc -l < "$FAKE/requests.log" | tr -d ' ')" -eq 2 ]
    jq -c '.argv' "$FAKE/requests.log" | tail -n 1 |
        grep -qx '\["group","delete","--name","A","--yes","--plan-token","T1"\]'
}

@test "client: plan_changed shows the new plan and asks again" {
    reply 1 '{"id":@ID@,"ok":false,"error":{"code":"confirmation_required","message":"m","plan":["старый план"],"plan_token":"T1"}}'
    reply 2 '{"id":@ID@,"ok":false,"error":{"code":"plan_changed","message":"m","plan":["новый план"],"plan_token":"T2"}}'
    reply 3 '{"id":@ID@,"ok":true,"data":null}'
    tui_sh 'tui_run_confirmed "Удаление" "Удалить?" group delete --name A; echo "rc=$?"' <<< $'y\ny'
    [[ "$output" == *'старый план'* ]]
    [[ "$output" == *'План изменился'* ]]
    [[ "$output" == *'новый план'* ]]
    [[ "$output" == *'rc=0'* ]]
    jq -c '.argv' "$FAKE/requests.log" | tail -n 1 |
        grep -qx '\["group","delete","--name","A","--yes","--plan-token","T2"\]'
}

@test "client: more than two consecutive plan_changed gives up with rc 1" {
    reply 1 '{"id":@ID@,"ok":false,"error":{"code":"confirmation_required","message":"m","plan":["p"],"plan_token":"T1"}}'
    local n
    for n in 2 3 4; do
        reply "$n" '{"id":@ID@,"ok":false,"error":{"code":"plan_changed","message":"m","plan":["p"],"plan_token":"T'"$n"'"}}'
    done
    tui_sh 'tui_run_confirmed "Удаление" "Удалить?" group delete --name A; echo "rc=$?"' <<< $'y\ny\ny\ny'
    [[ "$output" == *'rc=1'* ]]
    [ "$(wc -l < "$FAKE/requests.log" | tr -d ' ')" -eq 4 ]
}

@test "client: other errors from tui_run_confirmed return 1 without prompting" {
    reply 1 '{"id":@ID@,"ok":false,"error":{"code":"not_found","message":"m"}}'
    tui_sh 'tui_run_confirmed "Удаление" "Удалить?" group delete --name A; echo "rc=$?"'
    [[ "$output" == *'rc=1'* ]]
    [[ "$output" != *'Удалить?'* ]]
}

@test "client: share bundle renders url expiry headers curl and json" {
    reply 1 '{"id":@ID@,"ok":true,"data":{"client":"phone","url":"https://h.example/sub/tok","expires_at":"2030-01-01T00:00:00Z","headers":[{"name":"profile-update-interval","value":"24","source":"default"}]}}'
    tui_sh 'tui_call sub show --client phone; tui_render_share_bundle'
    [ "$status" -eq 0 ]
    [[ "$output" == *'Подписка: phone'* ]]
    [[ "$output" == *'https://h.example/sub/tok'* ]]
    [[ "$output" == *'2030-01-01T00:00:00Z'* ]]
    [[ "$output" == *'profile-update-interval: 24'* ]]
    [[ "$output" == *"curl 'https://h.example/sub/tok'"* ]]
    [[ "$output" == *'{"url":"https://h.example/sub/tok"}'* ]]
}

@test "client: tui_pick_node returns the chosen name and cancel returns 1" {
    reply 1 '{"id":@ID@,"ok":true,"data":[{"name":"de","ip":"1.2.3.4","port":22},{"name":"ru","ip":"5.6.7.8","port":2222}]}'
    reply 2 '{"id":@ID@,"ok":true,"data":[{"name":"de","ip":"1.2.3.4","port":22}]}'
    tui_sh 'tui_pick_node "Нода"; echo "rc=$? pick=$TUI_PICK"; tui_pick_node "Нода"; echo "rc=$? pick=[$TUI_PICK]"' <<< $'2\n0'
    [[ "$output" == *'de  1.2.3.4:22'* ]]
    [[ "$output" == *'rc=0 pick=ru'* ]]
    [[ "$output" == *'rc=1 pick=[]'* ]]
}

@test "client: tui_toggle_nodes returns flagged names and clears toggle globals" {
    reply 1 '{"id":@ID@,"ok":true,"data":[{"name":"de","ip":"1.2.3.4","port":22},{"name":"ru","ip":"5.6.7.8","port":2222}]}'
    reply 2 '{"id":@ID@,"ok":true,"data":[{"name":"de","ip":"1.2.3.4","port":22}]}'
    reply 3 '{"id":@ID@,"ok":true,"data":[{"name":"de","ip":"1.2.3.4","port":22}]}'
    tui_sh '
        tui_toggle_nodes "Ноды"; echo "rc=$? picked=${TUI_PICKED[*]} items=${#TOGGLE_SELECT_ITEMS[@]} flags=${#TOGGLE_SELECT_FLAGS[@]}"
        tui_toggle_nodes "Ноды"; echo "rc=$? picked=${#TUI_PICKED[@]} items=${#TOGGLE_SELECT_ITEMS[@]}"
        tui_toggle_nodes "Ноды"; echo "rc=$? picked=${#TUI_PICKED[@]}"
    ' <<< $'2\n\n\n0'
    [[ "$output" == *'rc=0 picked=ru items=0 flags=0'* ]]
    # Enter без отметок ничего не выбирает.
    [[ "$output" == *'rc=0 picked=0 items=0'* ]]
    [[ "$output" == *'rc=1 picked=0'* ]]
    [[ "$output" == *'[ ] de'* && "$output" != *'[x] de'* ]]
}

@test "client: host_key_changed trusts the first fingerprint after consent" {
    reply 1 '{"id":@ID@,"ok":false,"error":{"code":"host_key_changed","message":"m","fingerprints":["SHA256:abc","SHA256:def"]}}'
    reply 2 '{"id":@ID@,"ok":false,"error":{"code":"confirmation_required","message":"m","plan":["Новый отпечаток: SHA256:abc"],"plan_token":"T9"}}'
    reply 3 '{"id":@ID@,"ok":true,"data":{"name":"n1","fingerprint":"SHA256:abc"}}'
    tui_sh 'tui_call node check --name n1; tui_handle_node_codes n1; echo "rc=$?"' <<< 'y'
    [[ "$output" == *'rc=2'* ]]
    jq -c '.argv' "$FAKE/requests.log" | tail -n 1 |
        grep -qx '\["node","trust-host-key","--name","n1","--host-key","SHA256:abc","--yes","--plan-token","T9"\]'
}

@test "client: needs_setup and unknown codes are not retried" {
    reply 1 '{"id":@ID@,"ok":false,"error":{"code":"needs_setup","message":"m"}}'
    reply 2 '{"id":@ID@,"ok":false,"error":{"code":"failed","message":"m"}}'
    tui_sh 'tui_call node check --name n1; tui_handle_node_codes n1; echo "rc1=$?"; tui_call node check --name n1; tui_handle_node_codes n1; echo "rc2=$?"'
    [[ "$output" == *'rc1=1'* && "$output" == *'rc2=1'* ]]
    [[ "$output" == *'SSH-настройки'* ]]
}

@test "client: real serve answers session status and shutdown leaves no process" {
    export APP="$BATS_TEST_TMPDIR/app" HOME="$BATS_TEST_TMPDIR/home" BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$APP/modules" "$APP/templates" "$APP/common" "$BIN" "$HOME"
    cp "$PROJECT_ROOT/remote-control/remote-control-essence.sh" "$APP/"
    cp "$PROJECT_ROOT/VERSION" "$APP/"
    cp "$PROJECT_ROOT/remote-control/modules/"*.sh "$APP/modules/"
    cp "$PROJECT_ROOT/remote-control/templates/"*.yaml "$APP/templates/"
    cp -R "$PROJECT_ROOT/common/." "$APP/common/"
    chmod +x "$APP/remote-control-essence.sh"
    local tool
    for tool in curl ssh scp ssh-keyscan gh; do
        printf '#!/bin/bash\nexit 1\n' > "$BIN/$tool"
        chmod +x "$BIN/$tool"
    done
    export PATH="$BIN:$PATH"
    unset CONFIG_DIR CONFIG_JSON TEMPLATES_DIR GENERATED_DIR SCRIPT_DIR RC_SCRIPT_PASSWORD RC_VAULT_PASSWORD
    run bash -c '
        source "$PROJECT_ROOT/common/common.sh"
        source "$TUI_DIR/client.sh"
        tui_on_int() { exit 130; }
        RC_ENTRYPOINT="$APP/remote-control-essence.sh"
        tui_serve_start
        pid=$TUI_SERVE_PID tmp=$TUI_TMP
        tui_call session status; echo "rc=$? configured=$(tui_q .configured)"
        tui_shutdown
        kill -0 "$pid" 2>/dev/null && echo "ALIVE"
        [[ -e "$tmp" ]] && echo "TMP_LEFT"
        echo done
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'rc=0 configured=false'* ]]
    [[ "$output" != *ALIVE* && "$output" != *TMP_LEFT* ]]
    [[ "$output" == *done* ]]
}

# ─── screens / editor: экраны clients.sh с заглушкой tui_call ────────────────

# Заглушка tui_call: пишет argv в $FX/calls.log и отдаёт фикстуру
# $FX/<w1>_<w2>.<N> (N — номер вызова этой пары слов) или $FX/<w1>_<w2>.
_write_stub() {
    cat > "$FX/stub.sh" <<'EOF'
tui_call() {
    local key="$1_$2" n f resp i
    printf '%s\n' "$*" >> "$FX/calls.log"
    [[ -z "${TUI_SECRETS:-}" ]] || printf '%s\n' "$(printf '%s' "$TUI_SECRETS" | jq -r '.password // empty')" >> "$FX/pw.log"
    [[ -z "${TUI_SECRETS:-}" ]] || printf '%s %s\n' "$*" "$TUI_SECRETS" >> "$FX/secrets.log"
    n=$(grep -c -e "^$1 $2\( \|\$\)" "$FX/calls.log")
    f="$FX/$key.$n"
    [[ -f "$f" ]] || f="$FX/$key"
    [[ -f "$f" ]] || f="$FX/$1"
    if [[ -f "$f" ]]; then resp=$(cat "$f"); else resp='{"ok":true,"data":null}'; fi
    if [[ "$1 $2" == "template import" ]]; then
        for ((i = 1; i <= $#; i++)); do
            [[ "${!i}" == --file ]] && { j=$((i + 1)); cp "${!j}" "$FX/imported"; echo "${!j}" > "$FX/import_path"; }
        done
    fi
    TUI_RESPONSE="$resp"
    TUI_OK=$(printf '%s' "$resp" | jq -r '.ok')
    TUI_CODE=$(printf '%s' "$resp" | jq -r '.error.code // ""')
    TUI_DATA=$(printf '%s' "$resp" | jq -c '.data // null')
    TUI_ERROR=$(printf '%s' "$resp" | jq -c '.error // null')
    [[ "$TUI_OK" == true ]]
}
_tui_run_editor() { "$1" "$2"; }
EOF
}

# scr CODE — экран с заглушкой; ввод — stdin теста.
scr() {
    export FX="$BATS_TEST_TMPDIR/fx" TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$FX" "$TMPDIR"
    rm -f "$FX/calls.log" "$FX/pw.log" "$FX/secrets.log"
    _write_stub
    run bash -c '
        source "$SNAP/common/common.sh"
        source "$SNAP/tui/client.sh"
        source "$SNAP/tui/clients.sh"
        source "$SNAP/tui/nodes.sh"
        source "$SNAP/tui/system.sh"
        source "$FX/stub.sh"
        eval "$1"
    ' _ "$1"
    # Цвета не мешают подстрочным проверкам.
    output=$(printf '%s' "$output" | sed -E 's/\x1b\[[0-9;]*m//g')
}

# fx NAME JSON — фикстура ответа.
fx() { mkdir -p "$BATS_TEST_TMPDIR/fx"; printf '%s\n' "$2" > "$BATS_TEST_TMPDIR/fx/$1"; }

CONFIRM='{"ok":false,"error":{"code":"confirmation_required","message":"m","plan":["План: X"],"plan_token":"T1"}}'
OK_NULL='{"ok":true,"data":null}'

_fixtures() {
    fx client_list '{"ok":true,"data":[{"name":"alice","group":"PC","inherit_nodes":true,"nodes":["de"],"subscription":{"published":true,"expires_at":null}},{"name":"bob","group":"MOBILE","inherit_nodes":false,"nodes":["de","ru"],"subscription":{"published":false,"expires_at":null}}]}'
    fx group_list '{"ok":true,"data":[{"name":"PC","template":"default.yaml","clients":1,"nodes":["de"]},{"name":"MOBILE","template":"m.yaml","clients":1,"nodes":[]}]}'
    fx template_list '{"ok":true,"data":[{"name":"default.yaml","source":"builtin","groups":["PC"]},{"name":"m.yaml","source":"user","groups":["MOBILE"]}]}'
    fx node_list '{"ok":true,"data":[{"name":"de","ip":"1.2.3.4","port":22},{"name":"ru","ip":"5.6.7.8","port":2222}]}'
    fx sub_host '{"ok":true,"data":{"node":"de","base_url":"https://h.example"}}'
    fx sub_show '{"ok":true,"data":{"client":"alice","url":"https://h.example/sub/tok","expires_at":null,"headers":[]}}'
}

calls() { cat "$BATS_TEST_TMPDIR/fx/calls.log" 2>/dev/null || true; }
assert_call() { calls | grep -qxF -- "$1" || { echo "нет вызова: $1"; calls; return 1; }; }
refute_yes() { ! calls | grep -q -- '--yes' || { echo "неожиданный --yes"; calls; return 1; }; }

# Общие проверки навигации экрана: 0, EOF, x, Enter, верхний регистр.
nav_checks() {
    local screen="$1"
    scr "$screen; echo rc=\$?" <<< '0'
    [[ "$output" == *'rc=0'* ]] || { echo "$screen: 0"; echo "$output"; return 1; }
    scr "$screen; echo rc=\$?" < /dev/null
    [[ "$output" == *'rc=0'* ]] || { echo "$screen: EOF"; return 1; }
    scr "$screen; echo rc=\$?" <<< $'z\n\n0'
    [ "$(grep -c 'Неверный выбор.' <<< "$output")" -eq 2 ] || { echo "$screen: x/Enter"; echo "$output"; return 1; }
    [[ "$output" == *'rc=0'* ]]
}

@test "screens: every clients.sh screen handles 0, EOF, an unknown key and Enter" {
    _fixtures
    local s
    for s in tui_clients 'tui_client_card alice' 'tui_client_subscription alice' 'tui_headers client alice' \
        'tui_headers group PC' tui_groups 'tui_group_card PC' tui_templates 'tui_template_card default.yaml' \
        tui_generate tui_subscriptions; do
        fx sub_headers '{"ok":true,"data":[]}'
        nav_checks "$s" || { echo "screen: $s"; return 1; }
    done
}

@test "screens: tui_clients lists clients, opens a card by number and adds in uppercase" {
    _fixtures
    scr 'tui_clients' <<< $'1\n0\n0'
    [[ "$output" == *'alice  (PC)'* && "$output" == *'bob  (MOBILE)'* && "$output" == *'Клиент: alice'* ]]
    scr 'tui_clients' <<< $'A\nnew-client\n2\n0'
    assert_call 'client add --name new-client --group MOBILE'
    scr 'tui_clients' <<< $'a\n\n0'
    [[ "$output" == *'Имя клиента не указано.'* ]]
    ! calls | grep -q 'client add' || return 1
}

@test "screens: tui_clients shows an empty list" {
    _fixtures
    fx client_list '{"ok":true,"data":[]}'
    scr 'tui_clients' <<< '0'
    [[ "$output" == *'Нет клиентов'* ]]
}

@test "screens: client deletion refusal sends no --yes, consent sends --yes --plan-token" {
    _fixtures
    fx client_delete.1 "$CONFIRM"
    scr 'tui_clients' <<< $'d\n1\n\nn\n0'
    assert_call 'client delete --name alice'
    refute_yes
    rm -f "$BATS_TEST_TMPDIR/fx/calls.log"
    fx client_delete.2 "$OK_NULL"
    scr 'tui_clients' <<< $'D\n1\n2\n\ny\n0'
    assert_call 'client delete --name alice --name bob'
    assert_call 'client delete --name alice --name bob --yes --plan-token T1'
}

@test "screens: client deletion with an empty selection warns and calls nothing" {
    _fixtures
    scr 'tui_clients' <<< $'d\n\n0'
    [[ "$output" == *'Ничего не выбрано.'* ]]
    ! calls | grep -q 'client delete' || return 1
}

@test "screens: client card shows context and hides secrets until v" {
    _fixtures
    fx client_show '{"ok":true,"data":{"name":"alice","group":"PC","inherit_nodes":true,"nodes":["de"],"credentials":{"vless_uuid":"UUID-SECRET-1","hy2_password":"HY2-SECRET-1"},"connections":[{"node":"de","mode":"group","proxies":["vless"]}],"config":{"path":"/g/PC/alice/config.yaml","exists":true},"subscription":null}}'
    scr 'tui_client_card alice' <<< '0'
    [[ "$output" == *'Группа: PC'* && "$output" == *'Ноды: от группы (de)'* && "$output" == *'Подписка: опубликована, без срока'* ]]
    [[ "$output" != *SECRET* ]]
    scr 'tui_client_card alice' <<< $'V\n0'
    [[ "$output" == *UUID-SECRET-1* && "$output" == *HY2-SECRET-1* ]]
    scr 'tui_client_card bob' <<< '0'
    [[ "$output" == *'Ноды: свои (de, ru)'* ]]
}

@test "screens: client card delete refusal and consent, success returns to the list" {
    _fixtures
    fx client_delete.1 "$CONFIRM"
    scr 'tui_client_card alice; echo rc=$?' <<< $'d\nn\n0'
    assert_call 'client delete --name alice'
    refute_yes
    [[ "$output" == *'Клиент: alice'* ]]
    fx client_delete.2 "$OK_NULL"
    scr 'tui_client_card alice; echo rc=$?' <<< $'D\ny'
    assert_call 'client delete --name alice --yes --plan-token T1'
    [[ "$output" == *'rc=0'* ]]
}

@test "screens: client set-group and rename use the real commands" {
    _fixtures
    fx client_set-group.1 "$CONFIRM"
    scr 'tui_client_card alice' <<< $'g\n2\nn\n0'
    assert_call 'client set-group --name alice --group MOBILE'
    refute_yes
    fx client_set-group.2 "$OK_NULL"
    scr 'tui_client_card alice' <<< $'G\n2\ny\n0'
    assert_call 'client set-group --name alice --group MOBILE --yes --plan-token T1'
    scr 'tui_client_card alice' <<< $'r\nalice2\n0'
    assert_call 'client rename --name alice --new-name alice2'
}

@test "screens: client card continues with the name returned by client rename" {
    _fixtures
    fx client_rename '{"ok":true,"data":{"name":"alice.2"}}'
    fx client_list.2 '{"ok":true,"data":[{"name":"alice.2","group":"PC","inherit_nodes":true,"nodes":["de"],"subscription":{"published":true,"expires_at":null}}]}'
    fx client_list.3 '{"ok":true,"data":[{"name":"alice.2","group":"PC","inherit_nodes":true,"nodes":["de"],"subscription":{"published":true,"expires_at":null}}]}'
    scr 'tui_client_card alice; echo rc=$?' <<< $'r\nalice2\ng\n2\n0'
    assert_call 'client rename --name alice --new-name alice2'
    assert_call 'client set-group --name alice.2 --group MOBILE'
    ! calls | grep -q -- '--name alice2' || return 1
    [[ "$output" == *'Клиент: alice.2'* && "$output" != *'не найден'* && "$output" == *'rc=0'* ]]
}

@test "screens: client with inherited nodes cannot configure connections; own nodes can reset with consent" {
    _fixtures
    scr 'tui_client_card alice' <<< $'p\n0'
    [[ "$output" == *'Подключения настраиваются только для клиента со своими нодами.'* ]]
    fx client_connections.1 "$CONFIRM"
    scr 'tui_client_card bob' <<< $'P\n1\n2\nn\n0'
    assert_call 'client connections --name bob --node de --reset'
    refute_yes
    fx client_connections.2 "$OK_NULL"
    scr 'tui_client_card bob' <<< $'p\n1\n2\ny\n0'
    assert_call 'client connections --name bob --node de --reset --yes --plan-token T1'
}

@test "screens: client connections are configured from discovered proxies" {
    _fixtures
    fx client_connections '{"ok":true,"data":[{"node":"de","mode":"own","proxies":["p1"]}]}'
    fx conn_list '{"ok":true,"data":[{"node":"de","groups":[],"discovered":["p1","p2"]}]}'
    scr 'tui_client_card bob' <<< $'p\n1\n1\n2\n\n0'
    assert_call 'conn list --node de --discover'
    assert_call 'client connections --name bob --node de --proxy p1 --proxy p2'
}

@test "screens: discovery failure with needs_setup is not retried" {
    _fixtures
    fx client_connections '{"ok":true,"data":[]}'
    fx conn_list '{"ok":false,"error":{"code":"needs_setup","message":"m"}}'
    scr 'tui_client_card bob' <<< $'p\n1\n1\n0'
    [ "$(calls | grep -c '^conn list')" -eq 1 ]
    [[ "$output" == *'SSH-настройки'* ]]
}

@test "screens: client nodes menu assigns own nodes with current marks and returns to the group" {
    _fixtures
    scr 'tui_client_card alice' <<< $'n\n1\n2\n\n0'
    assert_call 'client nodes --name alice --node de --node ru'
    scr 'tui_client_card bob' <<< $'N\n2\n0'
    assert_call 'client nodes --name bob --inherit'
    scr 'tui_client_card bob' <<< $'n\n1\n1\n2\n\n0'
    [[ "$output" == *'[x] de'* ]]
    [[ "$output" == *'Ничего не выбрано.'* ]]
}

@test "screens: client subscription publishes with ttl, shows bundle, rotates and revokes with confirmation" {
    _fixtures
    scr 'tui_client_subscription alice' <<< $'p\n30d\n0'
    assert_call 'sub publish --client alice --ttl 30d'
    assert_call 'sub show --client alice'
    [[ "$output" == *'Подписка: alice'* && "$output" == *'https://h.example/sub/tok'* ]]
    scr 'tui_client_subscription alice' <<< $'P\n\n0'
    assert_call 'sub publish --client alice'
    scr 'tui_client_subscription alice' <<< $'v\n0'
    [[ "$output" == *'Хост подписок: de'* && "$output" == *'curl '* ]]
    fx sub_rotate.1 "$CONFIRM"
    scr 'tui_client_subscription alice' <<< $'r\nn\n0'
    refute_yes
    fx sub_rotate.2 "$OK_NULL"
    scr 'tui_client_subscription alice' <<< $'R\ny\n0'
    assert_call 'sub rotate --client alice --yes --plan-token T1'
    fx sub_revoke.1 "$CONFIRM"
    rm -f "$BATS_TEST_TMPDIR/fx/calls.log"
    scr 'tui_client_subscription alice' <<< $'x\nn\n0'
    refute_yes
    fx sub_revoke.2 "$OK_NULL"
    scr 'tui_client_subscription alice' <<< $'X\ny\n0'
    assert_call 'sub revoke --client alice --yes --plan-token T1'
}

@test "screens: subscription card shows a missing host hint and resolved headers" {
    _fixtures
    fx sub_host "$OK_NULL"
    scr 'tui_client_subscription alice' <<< '0'
    [[ "$output" == *'Хост подписок не задан — раздел s'* ]]
    fx sub_headers '{"ok":true,"data":[{"name":"X-A","value":"1","source":"client"},{"name":"X-B","value":"2","source":"default"}]}'
    scr 'tui_client_subscription alice' <<< $'i\n0'
    [[ "$output" == *'X-A: 1  [клиент]'* && "$output" == *'X-B: 2  [по умолчанию]'* ]]
}

@test "screens: headers set and delete only own client headers" {
    _fixtures
    fx sub_headers '{"ok":true,"data":[{"name":"X-A","value":"1","source":"client"},{"name":"X-B","value":"2","source":"default"}]}'
    scr 'tui_headers client alice' <<< $'a\nX-New\nval\n0'
    assert_call 'sub headers --client alice --set X-New=val'
    scr 'tui_headers client alice' <<< $'a\n\nval\n0'
    [[ "$output" == *'Имя и значение заголовка обязательны.'* ]]
    scr 'tui_headers client alice' <<< $'D\n1\n0'
    assert_call 'sub headers --client alice --unset X-A'
    scr 'tui_headers client alice' <<< $'d\n2\n0'
    [ "$(calls | grep -c -- '--unset X-B')" -eq 0 ]
    fx sub_headers '{"ok":true,"data":[]}'
    scr 'tui_headers group PC' <<< '0'
    [[ "$output" == *'Нет заголовков'* ]]
}

@test "screens: groups list, add, card" {
    _fixtures
    scr 'tui_groups' <<< $'1\n0\n0'
    [[ "$output" == *'PC  (default.yaml)'* && "$output" == *'Группа: PC'* && "$output" == *'Клиентов: 1'* ]]
    scr 'tui_groups' <<< $'A\nLAB\n0'
    assert_call 'group add --name LAB'
    scr 'tui_groups' <<< $'a\n\n0'
    [[ "$output" == *'Название не указано.'* ]]
}

@test "screens: group delete refusal and consent, success leaves the card" {
    _fixtures
    fx group_delete.1 "$CONFIRM"
    scr 'tui_group_card PC' <<< $'d\nn\n0'
    assert_call 'group delete --name PC'
    refute_yes
    fx group_delete.2 "$OK_NULL"
    scr 'tui_group_card PC; echo rc=$?' <<< $'D\ny'
    assert_call 'group delete --name PC --yes --plan-token T1'
    [[ "$output" == *'rc=0'* ]]
}

@test "screens: group card template menu picks an existing template or creates a new one" {
    _fixtures
    scr 'tui_group_card PC' <<< $'t\n2\n0'
    assert_call 'group set-template --name PC --template m.yaml'
    fx template_create '{"ok":true,"data":{"name":"fresh.yaml","based_on":"default.yaml","group":"PC"}}'
    fx template_show '{"ok":true,"data":{"name":"fresh.yaml","source":"user","path":"/t/fresh.yaml","content":"a: 1\n"}}'
    scr 'tui_group_card PC' <<< $'T\n3\nfresh\n0'
    assert_call 'template create --name fresh --group PC'
    assert_call 'template show --name fresh.yaml'
    scr 'tui_group_card PC' <<< $'f\n0'
    assert_call 'generate --group PC'
}

@test "screens: group card opens group headers" {
    _fixtures
    fx sub_headers '{"ok":true,"data":[{"name":"X-G","value":"1"}]}'
    scr 'tui_group_card PC' <<< $'h\n0\n0'
    assert_call 'sub headers --group PC'
    [[ "$output" == *'X-G: 1'* ]]
}

@test "screens: templates list marks the source and creates then edits a template" {
    _fixtures
    scr 'tui_templates' <<< '0'
    [[ "$output" == *'default.yaml  (встроенный)'* && "$output" == *'m.yaml  (пользовательский)'* ]]
    fx template_create '{"ok":true,"data":{"name":"n.yaml","based_on":null,"group":null}}'
    fx template_show '{"ok":true,"data":{"name":"n.yaml","source":"user","path":"/t/n.yaml","content":""}}'
    scr 'tui_templates' <<< $'a\nn\n0'
    assert_call 'template create --name n'
    assert_call 'template show --name n.yaml'
    scr 'tui_templates' <<< $'A\n\n0'
    [[ "$output" == *'Имя шаблона не указано.'* ]]
}

@test "screens: template card shows content and exports and imports with confirmation" {
    _fixtures
    fx template_show '{"ok":true,"data":{"name":"m.yaml","source":"user","path":"/t/m.yaml","content":"mode: rule\n"}}'
    scr 'tui_template_card m.yaml' <<< $'v\n0'
    [[ "$output" == *'Источник: пользовательский'* && "$output" == *'Группы: MOBILE'* && "$output" == *'mode: rule'* ]]
    fx template_export.1 "$CONFIRM"
    scr 'tui_template_card m.yaml' <<< $'x\n/tmp/o.yaml\nn\n0'
    assert_call 'template export --name m.yaml --output /tmp/o.yaml'
    refute_yes
    fx template_export.2 "$OK_NULL"
    scr 'tui_template_card m.yaml' <<< $'X\n/tmp/o.yaml\ny\n0'
    assert_call 'template export --name m.yaml --output /tmp/o.yaml --yes --plan-token T1'
    fx template_import.1 "$CONFIRM"
    rm -f "$BATS_TEST_TMPDIR/fx/calls.log"
    scr 'tui_template_card m.yaml' <<< $'i\n/tmp/i.yaml\nn\n0'
    refute_yes
    fx template_import.2 "$OK_NULL"
    scr 'tui_template_card m.yaml' <<< $'I\n/tmp/i.yaml\ny\n0'
    assert_call 'template import --name m.yaml --file /tmp/i.yaml --yes --plan-token T1'
}

@test "screens: generate runs all, group and client and prints the summary without empty lines" {
    _fixtures
    fx generate '{"ok":true,"data":{"ok":["alice"],"skipped":[],"failed":[],"nodes_ok":["de"],"nodes_failed":[],"dir":"/g"}}'
    scr 'tui_generate' <<< $'a\n0'
    assert_call 'generate --all'
    [[ "$output" == *'Готово: alice'* && "$output" == *'Каталог: /g'* && "$output" == *'PC → default.yaml'* ]]
    [[ "$output" != *'Пропущено:'* && "$output" != *'Ошибки:'* ]]
    scr 'tui_generate' <<< $'G\n1\n0'
    assert_call 'generate --group PC'
    scr 'tui_generate' <<< $'c\n2\n0'
    assert_call 'generate --client bob'
}

@test "screens: generate shows the summary also on partial" {
    _fixtures
    fx generate '{"ok":false,"error":{"code":"partial","message":"m"},"data":{"ok":[],"skipped":["s"],"failed":["bad"],"nodes_ok":[],"nodes_failed":["de"],"dir":"/g"}}'
    scr 'tui_generate' <<< $'a\n0'
    [[ "$output" == *'Ошибки: bad'* && "$output" == *'Ноды с ошибкой: de'* && "$output" == *'Пропущено: s'* ]]
}

@test "screens: subscriptions host, list, publish-all, migrate and delegations" {
    _fixtures
    scr 'tui_subscriptions' <<< '0'
    [[ "$output" == *'Хост-нода: '*de* && "$output" == *'Базовый URL: https://h.example'* ]]
    fx sub_host "$OK_NULL"
    scr 'tui_subscriptions' <<< '0'
    [[ "$output" == *'Хост-нода подписок не задана'* ]]
    _fixtures
    scr 'tui_subscriptions' <<< $'H\n2\n0'
    assert_call 'sub host --node ru'
    fx sub_list '{"ok":true,"data":[{"client":"alice","expires_at":"2030-01-01T00:00:00Z","state":"active"},{"client":"bob","expires_at":null,"state":"unlimited"}]}'
    scr 'tui_subscriptions' <<< $'l\n0'
    [[ "$output" == *'alice  2030-01-01T00:00:00Z'* && "$output" == *'bob'* ]]
    fx sub_publish-all '{"ok":true,"data":{"published":["alice"],"skipped":[],"failed":["bob"],"removed":0}}'
    scr 'tui_subscriptions' <<< $'u\n0'
    [[ "$output" == *'Опубликовано: alice'* && "$output" == *'Ошибки: bob'* ]]
    scr 'tui_subscriptions' <<< $'c\n1\n0\n0'
    [[ "$output" == *'Подписка клиента: alice'* ]]
    fx sub_headers '{"ok":true,"data":[]}'
    scr 'tui_subscriptions' <<< $'g\n1\n0\n0'
    [[ "$output" == *'Заголовки подписки: PC'* ]]
}

@test "screens: subscription migration refusal sends no --yes and consent sends the token" {
    _fixtures
    fx sub_migrate.1 "$CONFIRM"
    scr 'tui_subscriptions' <<< $'m\n2\nn\n0'
    assert_call 'sub migrate --node ru'
    refute_yes
    fx sub_migrate.2 "$OK_NULL"
    scr 'tui_subscriptions' <<< $'M\n2\ny\n0'
    assert_call 'sub migrate --node ru --yes --plan-token T1'
}

@test "screens: a vanished object returns to the list" {
    _fixtures
    fx client_list '{"ok":false,"error":{"code":"not_found","message":"m"}}'
    scr 'tui_client_card ghost; echo rc=$?' <<< $'0'
    [[ "$output" == *'rc=0'* ]]
    fx client_list '{"ok":true,"data":[]}'
    scr 'tui_client_card ghost; echo rc=$?' <<< $'0'
    [[ "$output" == *'не найден'* && "$output" == *'rc=0'* ]]
    scr 'tui_client_subscription ghost; echo rc=$?' <<< $'0'
    [[ "$output" == *'rc=0'* ]]
    fx group_list '{"ok":true,"data":[]}'
    scr 'tui_group_card PC; echo rc=$?' <<< $'0'
    [[ "$output" == *'rc=0'* ]]
    fx template_list '{"ok":true,"data":[]}'
    scr 'tui_template_card x.yaml; echo rc=$?' <<< $'0'
    [[ "$output" == *'rc=0'* ]]
}

# ─── editor ──────────────────────────────────────────────────────────────────

_editor_fixture() {
    fx template_show '{"ok":true,"data":{"name":"m.yaml","source":"user","path":"/t/m.yaml","content":"mode: rule\n"}}'
}

@test "editor: a changed file is imported with --yes and the temporary files are removed" {
    _editor_fixture
    cat > "$BATS_TEST_TMPDIR/edit.sh" <<'EOF'
#!/bin/bash
printf 'extra: 1\n' >> "$1"
EOF
    chmod +x "$BATS_TEST_TMPDIR/edit.sh"
    export EDITOR="$BATS_TEST_TMPDIR/edit.sh"
    unset VISUAL
    scr 'tui_template_edit m.yaml; echo rc=$?'
    [[ "$output" == *'rc=0'* ]]
    calls | grep -qE '^template import --name m.yaml --file .+/edit.yaml --yes$'
    [ "$(cat "$FX/imported")" = $'mode: rule\nextra: 1' ]
    [ ! -e "$(cat "$FX/import_path")" ]
    [ -z "$(ls -A "$BATS_TEST_TMPDIR/tmp")" ]
}

@test "editor: an unchanged file reports no changes and imports nothing" {
    _editor_fixture
    export EDITOR=true
    unset VISUAL
    scr 'tui_template_edit m.yaml; echo rc=$?'
    [[ "$output" == *'Изменений нет.'* && "$output" == *'rc=0'* ]]
    ! calls | grep -q 'template import' || return 1
    [ -z "$(ls -A "$BATS_TEST_TMPDIR/tmp")" ]
}

@test "editor: VISUAL wins over EDITOR" {
    _editor_fixture
    printf '#!/bin/bash\necho visual > "$FX/who"\n' > "$BATS_TEST_TMPDIR/vis.sh"
    printf '#!/bin/bash\necho editor > "$FX/who"\n' > "$BATS_TEST_TMPDIR/ed.sh"
    chmod +x "$BATS_TEST_TMPDIR/vis.sh" "$BATS_TEST_TMPDIR/ed.sh"
    export VISUAL="$BATS_TEST_TMPDIR/vis.sh" EDITOR="$BATS_TEST_TMPDIR/ed.sh"
    scr 'tui_template_edit m.yaml'
    [ "$(cat "$FX/who")" = visual ]
}

@test "editor: a failing editor keeps the template and cleans up" {
    _editor_fixture
    export EDITOR=false
    unset VISUAL
    scr 'tui_template_edit m.yaml; echo rc=$?'
    [[ "$output" == *'Редактор завершился с ошибкой.'* && "$output" == *'rc=1'* ]]
    ! calls | grep -q 'template import' || return 1
    [ -z "$(ls -A "$BATS_TEST_TMPDIR/tmp")" ]
}

@test "editor: no editor available warns and returns 1" {
    _editor_fixture
    unset VISUAL EDITOR
    scr 'command() { [[ "$1 $2" == "-v nano" || "$1 $2" == "-v vi" ]] && return 1; builtin command "$@"; }
        tui_template_edit m.yaml; echo rc=$?'
    [[ "$output" == *'Редактор не найден: установите nano или задайте EDITOR.'* && "$output" == *'rc=1'* ]]
    ! calls | grep -q 'template import' || return 1
}

@test "editor: a vanished template returns 1 without creating files" {
    fx template_show '{"ok":false,"error":{"code":"not_found","message":"m"}}'
    export EDITOR=true
    scr 'tui_template_edit gone.yaml; echo rc=$?'
    [[ "$output" == *'rc=1'* ]]
    [ -z "$(ls -A "$BATS_TEST_TMPDIR/tmp")" ]
}

# ─── screens: nodes.sh ───────────────────────────────────────────────────────

_node_fixtures() {
    fx node_list '{"ok":true,"data":[{"name":"de","ip":"1.2.3.4","port":22,"user":"root","auth":"key","password":null,"issues":[]},{"name":"ru","ip":"5.6.7.8","port":2222,"user":"admin","auth":"password","password":"missing","issues":["missing_secret"]}]}'
    fx status '{"ok":true,"data":{"ssh_setup_pending":false}}'
    fx node_show '{"ok":true,"data":{"name":"ru","ip":"5.6.7.8","port":2222,"user":"admin","auth":"password","tag":"RU","password":"ok","issues":[],"groups":["PC"],"clients":2,"delete_options":[{"scope":"local","revoke_key":false,"label":"Удалить локально"},{"scope":"local","revoke_key":true,"label":"Локально и отозвать ключ"},{"scope":"server","revoke_key":false,"label":"Удалить с сервера"}]}}'
    fx conn_sync '{"ok":true,"data":{"nodes":[{"name":"de","status":"synced","discovered":["p1","p2"],"removed":[],"groups":[{"name":"PC","proxies":["p1"]}]},{"name":"ru","status":"unreachable","discovered":null,"removed":[],"groups":[]}],"ok":1,"failed":1,"total":2,"stopped_at":null}}'
    fx conn_list '{"ok":true,"data":[{"node":"de","groups":[{"name":"PC","proxies":["p1"]}]},{"node":"ru","groups":[]}]}'
    fx awg_status '{"ok":true,"data":{"installed":true,"peers":[{"name":"a","status":"used"},{"name":"b","status":"orphan"},{"name":"c","status":"missing"}]}}'
    fx group_list '{"ok":true,"data":[{"name":"PC","template":"default.yaml","clients":1,"nodes":["de"]},{"name":"MOBILE","template":"m.yaml","clients":1,"nodes":[]}]}'
    fx node_aliases '{"ok":true,"data":[{"proxy":"p1","alias":"A"},{"proxy":"p2","alias":null}]}'
}

# Ошибка с кодом и EXTRA.
err() { printf '{"ok":false,"error":{"code":"%s","message":"m"%s}}' "$1" "${2:+,$2}"; }

@test "screens: every nodes.sh screen handles 0, EOF, an unknown key and Enter" {
    _fixtures
    _node_fixtures
    local s
    for s in tui_nodes 'tui_node_card ru' tui_connections 'tui_conn_node de' tui_awg 'tui_awg_node de' tui_telegram; do
        nav_checks "$s" || { echo "screen: $s"; return 1; }
    done
}

@test "screens: tui_nodes lists nodes, opens a card, hides h without pending setup" {
    _fixtures; _node_fixtures
    scr 'tui_nodes' <<< $'2\n0\n0'
    [[ "$output" == *'de  1.2.3.4:22'* && "$output" == *'ru  5.6.7.8:2222'* && "$output" == *'Нода: ru'* ]]
    [[ "$output" != *'Завершить отложенную'* ]]
    scr 'tui_nodes' <<< $'h\n0'
    [[ "$output" == *'Неверный выбор.'* ]]
    ! calls | grep -q 'setup-ssh' || return 1
    fx status '{"ok":true,"data":{"ssh_setup_pending":true}}'
    scr 'tui_nodes' <<< $'H\n0'
    [[ "$output" == *'Завершить отложенную SSH-настройку'* ]]
    assert_call 'node setup-ssh'
    fx node_list '{"ok":true,"data":[]}'
    scr 'tui_nodes' <<< '0'
    [[ "$output" == *'Нет нод'* ]]
}

@test "screens: node card shows context; password key only for password nodes" {
    _fixtures; _node_fixtures
    scr 'tui_node_card ru' <<< '0'
    [[ "$output" == *'Адрес: 5.6.7.8:2222'* && "$output" == *'Вход: по паролю'* && "$output" == *'Пароль SSH: сохранён'* \
        && "$output" == *'Группы: PC'* && "$output" == *'Клиентов: 2'* && "$output" == *'w) Пароль SSH'* ]]
    fx node_show '{"ok":true,"data":{"name":"de","ip":"1.2.3.4","port":22,"user":"root","auth":"key","tag":"DE","password":null,"issues":["missing_identity"],"groups":[],"clients":0,"delete_options":[]}}'
    scr 'tui_node_card de' <<< $'w\n0'
    [[ "$output" == *'Вход: по ключу'* && "$output" == *'Требует настройки: missing_identity'* && "$output" == *'Неверный выбор.'* ]]
    [[ "$output" != *'w) Пароль SSH'* ]]
}

@test "screens: node delete offers every option; refusal sends no --yes, consent sends the token" {
    _fixtures; _node_fixtures
    local idx scope extra
    for idx in 1 2 3; do
        case "$idx" in
            1) scope="--scope local" ;;
            2) scope="--scope local --revoke-key" ;;
            3) scope="--scope server" ;;
        esac
        fx node_delete.1 "$CONFIRM"
        scr 'tui_node_card ru' <<< "d"$'\n'"$idx"$'\nn\n0'
        assert_call "node delete --name ru $scope"
        refute_yes
        fx node_delete.2 "$OK_NULL"
        scr 'tui_node_card ru; echo rc=$?' <<< "D"$'\n'"$idx"$'\ny'
        assert_call "node delete --name ru $scope --yes --plan-token T1"
        [[ "$output" == *'rc=0'* ]]
    done
    scr 'tui_node_card ru' <<< $'d\n1\nn\n0'
    [[ "$output" == *'Удалить локально'* && "$output" == *'Локально и отозвать ключ'* && "$output" == *'Удалить с сервера'* ]]
}

@test "screens: forced script upload and telegram menu need consent" {
    _fixtures; _node_fixtures
    fx node_upload-scripts.1 "$CONFIRM"
    scr 'tui_node_card ru' <<< $'u\nn\n0'
    assert_call 'node upload-scripts --name ru --force'
    refute_yes
    fx node_upload-scripts.2 "$OK_NULL"
    scr 'tui_node_card ru' <<< $'U\ny\n0'
    assert_call 'node upload-scripts --name ru --force --yes --plan-token T1'
    fx telegram_menu.1 "$CONFIRM"
    scr 'tui_node_card ru' <<< $'t\nn\n0'
    assert_call 'telegram menu --node ru'
    refute_yes
    fx telegram_menu.2 "$OK_NULL"
    scr 'tui_node_card ru' <<< $'T\ny\n0'
    assert_call 'telegram menu --node ru --yes --plan-token T1'
}

@test "screens: node shell, check, rename, tag and delegations" {
    _fixtures; _node_fixtures
    scr 'tui_node_card ru' <<< $'o\n0'
    assert_call 'node shell --name ru'
    fx node_shell "$(err tty_required)"
    scr 'tui_node_card ru' <<< $'O\n0'
    [ "$(calls | grep -c '^node shell')" -eq 1 ]
    scr 'tui_node_card ru' <<< $'k\n0'
    assert_call 'node check --name ru'
    scr 'tui_node_card ru' <<< $'r\nru2\n0'
    assert_call 'node rename --name ru --new-name ru2'
    scr 'tui_node_card ru' <<< $'e\nT2\n0'
    assert_call 'node tag --name ru --tag T2'
    scr 'tui_node_card ru' <<< $'p\n0\n0'
    assert_call 'conn sync --node ru'
    scr 'tui_node_card ru' <<< $'a\n0\n0'
    assert_call 'awg status --node ru'
    scr 'tui_node_card ru' <<< $'l\n\n\n0'
    assert_call 'node aliases --name ru'
}

@test "screens: node card continues with the name returned by node rename" {
    _fixtures; _node_fixtures
    fx node_rename '{"ok":true,"data":{"name":"RU-2"}}'
    scr 'tui_node_card ru' <<< $'r\nru2\nk\n0'
    assert_call 'node rename --name ru --new-name ru2'
    [ "$(calls | sed -n 3p)" = 'node show --name RU-2' ]
    assert_call 'node check --name RU-2'
    ! calls | grep -q -- '--name ru2' || return 1
}

@test "screens: host_key_changed on a node command trusts the key only after consent" {
    _fixtures; _node_fixtures
    fx node_check.1 "$(err host_key_changed '"host":"5.6.7.8","port":2222,"fingerprints":["SHA256:abc","SHA256:def"]')"
    fx node_trust-host-key.1 "$CONFIRM"
    scr 'tui_node_card ru' <<< $'k\nn\n0'
    assert_call 'node trust-host-key --name ru --host-key SHA256:abc'
    refute_yes
    [ "$(calls | grep -c '^node check')" -eq 1 ]
    fx node_check.2 "$OK_NULL"
    fx node_trust-host-key.2 "$OK_NULL"
    scr 'tui_node_card ru' <<< $'k\ny\n0'
    assert_call 'node trust-host-key --name ru --host-key SHA256:abc --yes --plan-token T1'
    [ "$(calls | grep -c '^node check')" -eq 2 ]
}

@test "screens: node password is read silently, sent only as a secret and cleared" {
    _fixtures; _node_fixtures
    scr 'tui_node_card ru; echo "left=[${TUI_SECRETS:-}]"' <<< $'w\nS3cr3t-PW\n0'
    assert_call 'node password --name ru'
    [ "$(cat "$FX/pw.log")" = S3cr3t-PW ]
    ! calls | grep -q S3cr3t || return 1
    [[ "$output" != *S3cr3t* && "$output" == *'left=[]'* ]]
    scr 'tui_node_card ru' <<< $'w\n\n0'
    ! calls | grep -q 'node password' || return 1
}

@test "screens: node card returns to the list when the node vanished" {
    _fixtures; _node_fixtures
    fx node_show '{"ok":false,"error":{"code":"not_found","message":"m"}}'
    scr 'tui_node_card ghost; echo rc=$?' <<< '0'
    [[ "$output" == *'rc=0'* ]]
}

# ─── node add ────────────────────────────────────────────────────────────────

ADD_BASE='vps
1.2.3.4
22
root
1
TAG
'
ADD_CALL='node add --name vps --ip 1.2.3.4 --port 22 --user root --auth key --tag TAG --accept-new-host-key'

@test "screens: node add asks in order, uses defaults and calls node add" {
    _fixtures
    fx node_add '{"ok":true,"data":{"name":"vps","id":"x","needs_setup":false}}'
    scr 'tui_node_add' <<< "$ADD_BASE"
    assert_call "$ADD_CALL"
    scr 'tui_node_add' <<< $'\n1.2.3.4\n\n\n1\nT\n'
    assert_call 'node add --name vps-1 --ip 1.2.3.4 --port 22 --user root --auth key --tag T --accept-new-host-key'
    fx node_add '{"ok":true,"data":{"name":"vps","id":"x","needs_setup":true}}'
    scr 'tui_node_add' <<< "$ADD_BASE"
    [[ "$output" == *'Нода сохранена, но требует SSH-настройки: раздел n → h.'* ]]
}

@test "screens: node add validates ip, port and tag and can be cancelled" {
    _fixtures
    scr 'tui_node_add' <<< $'vps\n\n'
    [[ "$output" == *'IP не указан.'* ]]
    ! calls | grep -q 'node add' || return 1
    scr 'tui_node_add' <<< $'vps\n1.2.3.4\nabc\n70000\n0\n2222\nroot\n1\n\nTAG\n'
    [ "$(grep -c 'Порт должен быть' <<< "$output")" -eq 3 ]
    [[ "$output" == *'Тег не может быть пустым.'* ]]
    assert_call 'node add --name vps --ip 1.2.3.4 --port 2222 --user root --auth key --tag TAG --accept-new-host-key'
    scr 'tui_node_add' <<< $'vps\n1.2.3.4\n22\nroot\n0\n'
    ! calls | grep -q 'node add' || return 1
}

@test "screens: node add sends the password only as a secret" {
    _fixtures
    fx node_add '{"ok":true,"data":{"name":"vps","id":"x","needs_setup":false}}'
    scr 'tui_node_add; echo "left=[${TUI_SECRETS:-}]"' <<< $'vps\n1.2.3.4\n22\nroot\n2\n\nPW-ONE-secret\nTAG\n'
    assert_call 'node add --name vps --ip 1.2.3.4 --port 22 --user root --auth password --tag TAG --accept-new-host-key'
    [ "$(cat "$FX/pw.log")" = PW-ONE-secret ]
    ! calls | grep -q PW-ONE || return 1
    [[ "$output" != *PW-ONE* && "$output" == *'left=[]'* ]]
}

@test "screens: node add host_key_changed replaces the key only through the command plan" {
    _fixtures
    local replace='node add --name vps --ip 1.2.3.4 --port 22 --user root --auth key --tag TAG --replace-host-key SHA256:aaa'
    fx node_add.1 "$(err host_key_changed '"host":"1.2.3.4","port":22,"fingerprints":["SHA256:aaa","SHA256:bbb"]')"
    fx node_add.2 '{"ok":false,"error":{"code":"confirmation_required","message":"m","plan":["Нода: vps 1.2.3.4:22","Прежние отпечатки: SHA256:bbb","Новый отпечаток: SHA256:aaa"],"plan_token":"T7"}}'
    fx node_add.3 '{"ok":true,"data":{"name":"vps","id":"x","needs_setup":false}}'
    scr 'tui_node_add' <<< "${ADD_BASE}y"
    assert_call "$replace"
    assert_call "$replace --yes --plan-token T7"
    [[ "$output" == *'1.2.3.4:22'* && "$output" == *'SHA256:bbb'* ]]
    scr 'tui_node_add' <<< "${ADD_BASE}n"
    [ "$(calls | grep -c '^node add')" -eq 2 ]
    refute_yes
}

@test "screens: node add remote_failed retries on consent and can replace the password" {
    _fixtures
    fx node_add.1 "$(err remote_failed '"reason":"auth","hint":"ssh-copy-id root@1.2.3.4"')"
    fx node_add.2 '{"ok":true,"data":{"name":"vps","id":"x","needs_setup":false}}'
    scr 'tui_node_add' <<< "${ADD_BASE}y"
    [ "$(calls | grep -c '^node add')" -eq 2 ]
    [[ "$output" == *'ssh-copy-id root@1.2.3.4'* ]]
    scr 'tui_node_add' <<< "${ADD_BASE}n"
    [ "$(calls | grep -c '^node add')" -eq 1 ]
    scr 'tui_node_add' <<< $'vps\n1.2.3.4\n22\nroot\n2\nOLD-pw\nTAG\ny\nNEW-pw\n'
    [ "$(cat "$FX/pw.log" | paste -sd, -)" = OLD-pw,NEW-pw ]
    ! calls | grep -qE 'OLD-pw|NEW-pw' || return 1
    scr 'tui_node_add' <<< $'vps\n1.2.3.4\n22\nroot\n2\nOLD-pw\nTAG\ny\n\n'
    [ "$(cat "$FX/pw.log" | paste -sd, -)" = OLD-pw,OLD-pw ]
}

@test "screens: node add onboarding_failed can defer the ssh setup" {
    _fixtures
    fx node_add.1 "$(err onboarding_failed '"node":"vps","step":"provision","rolled_back":true')"
    fx node_add.2 '{"ok":true,"data":{"name":"vps","id":"x","needs_setup":true}}'
    scr 'tui_node_add' <<< "${ADD_BASE}2"
    assert_call "$ADD_CALL --defer-ssh-setup"
    scr 'tui_node_add' <<< "${ADD_BASE}1"
    [ "$(calls | grep -c -- '--defer-ssh-setup')" -eq 0 ]
    [ "$(calls | grep -c '^node add')" -eq 2 ]
    fx node_add "$(err conflict)"
    scr 'tui_node_add' <<< "$ADD_BASE"
    [ "$(calls | grep -c '^node add')" -eq 1 ]
}

# ─── harden ──────────────────────────────────────────────────────────────────

HCONF() { printf '{"ok":false,"error":{"code":"confirmation_required","message":"m","plan":["План %s"],"plan_token":"%s","port":%s}}' "$2" "$1" "$2"; }

@test "screens: harden asks for the port, refusal sends no --yes, consent sends token and port" {
    _fixtures
    fx node_harden.1 "$(HCONF T1 40000)"
    fx node_harden.2 "$(HCONF T2 40000)"
    scr 'tui_node_harden ru' <<< $'\nn'
    assert_call 'node harden --name ru'
    refute_yes
    [[ "$output" == *'План 40000'* ]]
    fx node_harden.3 "$OK_NULL"
    scr 'tui_node_harden ru' <<< $'\ny'
    assert_call 'node harden --name ru --port 40000 --yes --plan-token T2'
}

@test "screens: harden re-plans on another port" {
    _fixtures
    fx node_harden.1 "$(HCONF T1 40000)"
    fx node_harden.2 "$(HCONF T2 55555)"
    fx node_harden.3 "$OK_NULL"
    scr 'tui_node_harden ru' <<< $'55555\ny'
    assert_call 'node harden --name ru --port 55555'
    assert_call 'node harden --name ru --port 55555 --yes --plan-token T2'
}

@test "screens: harden asks for the port again after port_in_use" {
    _fixtures
    fx node_harden.1 "$(HCONF T1 40000)"
    fx node_harden.2 "$(err port_in_use '"port":22')"
    fx node_harden.3 "$(HCONF T3 33333)"
    fx node_harden.4 "$OK_NULL"
    scr 'tui_node_harden ru' <<< $'22\n33333\ny'
    assert_call 'node harden --name ru --port 22'
    assert_call 'node harden --name ru --port 33333'
    assert_call 'node harden --name ru --port 33333 --yes --plan-token T3'
    [[ "$output" == *'Enter — случайный свободный'* || -n "$output" ]]
}

@test "screens: harden shows a changed plan again and warns about the provider console" {
    _fixtures
    fx node_harden.1 "$(HCONF T1 40000)"
    fx node_harden.2 "$(HCONF T2 40000)"
    fx node_harden.3 "$(err plan_changed '"plan":["Новый план"],"plan_token":"T3","port":40000')"
    fx node_harden.4 "$OK_NULL"
    scr 'tui_node_harden ru' <<< $'\ny\ny'
    [[ "$output" == *'План изменился'* && "$output" == *'Новый план'* ]]
    assert_call 'node harden --name ru --port 40000 --yes --plan-token T3'
    fx node_harden.3 "$(err hardening_failed '"stage":"verify","rolled_back":false,"console_required":true')"
    scr 'tui_node_harden ru' <<< $'\ny'
    [[ "$output" == *'Проверьте доступ через консоль провайдера.'* ]]
}

# ─── setup-ssh и псевдонимы ──────────────────────────────────────────────────

@test "screens: setup-ssh asks about key provisioning, then confirms the plan" {
    _fixtures
    fx node_setup-ssh.1 "$(err key_provisioning_required '"nodes":["de","ru"]')"
    fx node_setup-ssh.2 "$CONFIRM"
    fx node_setup-ssh.3 '{"ok":true,"data":{"ready":true,"installed":["de"],"deferred":[],"pending":false}}'
    scr 'tui_node_setup_ssh' <<< $'y\nn'
    assert_call 'node setup-ssh --provision-keys yes'
    refute_yes
    [[ "$output" == *'de, ru'* ]]
    scr 'tui_node_setup_ssh' <<< $'y\ny'
    assert_call 'node setup-ssh --provision-keys yes --yes --plan-token T1'
    [[ "$output" == *'SSH-настройка завершена.'* ]]
    scr 'tui_node_setup_ssh' <<< $'n\ny'
    assert_call 'node setup-ssh --provision-keys no'
}

@test "screens: setup-ssh onboarding_failed can defer and prints deferred nodes" {
    _fixtures
    fx node_setup-ssh.1 "$CONFIRM"
    fx node_setup-ssh.2 "$(err onboarding_failed '"node":"ru","step":"pin","rolled_back":true')"
    fx node_setup-ssh.3 "$CONFIRM"
    fx node_setup-ssh.4 '{"ok":true,"data":{"ready":false,"installed":[],"deferred":[{"name":"ru","issue":"missing_identity"}],"pending":true}}'
    scr 'tui_node_setup_ssh' <<< $'y\n2\ny'
    assert_call 'node setup-ssh --on-failure defer'
    assert_call 'node setup-ssh --on-failure defer --yes --plan-token T1'
    [[ "$output" == *'Отложено: ru — missing_identity'* ]]
}

@test "screens: aliases send one call with sets and unsets, or report no changes" {
    _fixtures; _node_fixtures
    scr 'tui_node_aliases de' <<< $'new1\n-\n'
    assert_call 'node aliases --name de --set p1=new1'
    scr 'tui_node_aliases de' <<< $'-\n\n'
    assert_call 'node aliases --name de --unset p1'
    scr 'tui_node_aliases de' <<< $'\n\n'
    [[ "$output" == *'Изменений нет.'* ]]
    [ "$(calls | grep -c '^node aliases')" -eq 1 ]
    fx node_aliases '{"ok":true,"data":[]}'
    scr 'tui_node_aliases de' <<< ''
    [[ "$output" == *'Подключения на ноде не найдены.'* ]]
}

# ─── connections / awg / telegram ────────────────────────────────────────────

@test "screens: connections overview, sync and node entry" {
    _fixtures; _node_fixtures
    scr 'tui_connections' <<< $'s\n1\n0\n0'
    [[ "$output" == *'PC: 1/2'* && "$output" == *'ru  недоступна'* ]]
    [ "$(calls | grep -c '^conn sync$')" -eq 2 ]
    assert_call 'conn sync --node de'
    fx conn_sync '{"ok":false,"error":{"code":"partial","message":"m"},"data":{"nodes":[{"name":"de","status":"synced","discovered":null,"removed":[],"groups":[{"name":"PC","proxies":["p1"]}]}],"ok":1,"failed":0,"total":1,"stopped_at":null}}'
    scr 'tui_connections' <<< '0'
    [[ "$output" == *'PC: 1/?'* ]]
}

@test "screens: connections overview syncs only on entry and s, redraws read conn list" {
    _fixtures; _node_fixtures
    # Неверный ввод, вход в ноду и возврат — перерисовки без conn sync.
    scr 'tui_connections' <<< $'z\n1\n0\n0'
    [ "$(calls | grep -c '^conn sync$')" -eq 1 ]
    [ "$(calls | grep -c '^conn sync --node de$')" -eq 1 ]
    [ "$(calls | grep -c '^conn list$')" -eq 3 ]
    [ "$(calls | head -1)" = 'conn sync' ]
    # Обнаруженные подключения и недоступность — из кэша последней синхронизации.
    [ "$(grep -c 'PC: 1/2' <<< "$output")" -eq 3 ]
    [ "$(grep -c 'ru  недоступна' <<< "$output")" -eq 3 ]
    scr 'tui_connections' <<< $'s\nS\n0'
    [ "$(calls | grep -c '^conn sync$')" -eq 3 ]
}

@test "screens: node connections sync only on entry and s, assignment refreshes by conn list" {
    _fixtures; _node_fixtures
    scr 'tui_conn_node de' <<< $'z\n0'
    [ "$(calls | tr '\n' '|')" = 'conn sync --node de|conn list --node de|conn list --node de|' ]
    scr 'tui_conn_node de' <<< $'s\nS\n0'
    [ "$(calls | grep -c '^conn sync --node de$')" -eq 3 ]
    fx conn_list.2 '{"ok":true,"data":[{"node":"de","groups":[{"name":"PC","proxies":["p1","p2"]}]}]}'
    scr 'tui_conn_node de' <<< $'b\n2\n\n1\n\n0'
    assert_call 'conn set --node de --group PC --proxy p1 --proxy p2'
    [ "$(calls | grep -c '^conn sync')" -eq 1 ]
    [ "$(calls | tail -1)" = 'conn list --node de' ]
    [[ "$output" == *'p2  [PC]'* ]]
}

@test "screens: connection assignment selects proxies then groups, empty selection warns" {
    _fixtures; _node_fixtures
    scr 'tui_conn_node de' <<< $'b\n2\n\n1\n\n0'
    assert_call 'conn set --node de --group PC --proxy p1 --proxy p2'
    [[ "$output" == *'p1  [PC]'* && "$output" == *'p2  []'* ]]
    scr 'tui_conn_node de' <<< $'B\n1\n\n0'
    [[ "$output" == *'Ничего не выбрано.'* ]]
    scr 'tui_conn_node de' <<< $'b\n\n\n0'
    ! calls | grep -q 'conn set' || return 1
    scr 'tui_conn_node de' <<< $'l\n\n\n0'
    assert_call 'node aliases --name de'
}

@test "screens: connection node screen handles node codes and a vanished node" {
    _fixtures; _node_fixtures
    fx conn_sync "$(err not_found)"
    scr 'tui_conn_node ghost; echo rc=$?' <<< '0'
    [[ "$output" == *'rc=0'* ]]
    fx conn_sync '{"ok":true,"data":{"nodes":[],"ok":0,"failed":0,"total":0,"stopped_at":null}}'
    fx conn_list "$(err not_found)"
    scr 'tui_conn_node ghost; echo rc=$?' <<< ''
    [[ "$output" == *'rc=0'* && "$output" != *'Подключения ноды: ghost'* ]]
}

@test "screens: awg node lists peers, creates missing, removes with consent" {
    _fixtures; _node_fixtures
    scr 'tui_awg_node de' <<< '0'
    [[ "$output" == *'не используется'* && "$output" == *'не создан'* ]]
    scr 'tui_awg_node de' <<< $'c\n0'
    assert_call 'awg sync --node de'
    fx awg_remove.1 "$CONFIRM"
    scr 'tui_awg_node de' <<< $'d\n2\nn\n0'
    assert_call 'awg remove --node de --peer b'
    refute_yes
    [[ "$output" != *'3) c'* ]]
    fx awg_remove.2 "$OK_NULL"
    scr 'tui_awg_node de' <<< $'D\n2\ny\n0'
    assert_call 'awg remove --node de --peer b --yes --plan-token T1'
    fx awg_remove.1 "$CONFIRM"
    scr 'tui_awg_node de' <<< $'x\nn\n0'
    assert_call 'awg remove --node de --orphans'
    refute_yes
    fx awg_remove.2 "$OK_NULL"
    scr 'tui_awg_node de' <<< $'X\ny\n0'
    assert_call 'awg remove --node de --orphans --yes --plan-token T1'
    scr 'tui_awg_node de' <<< $'r\n0'
    [ "$(calls | grep -c '^awg status')" -eq 2 ]
}

@test "screens: awg not installed shows a hint and no management keys" {
    _fixtures; _node_fixtures
    fx awg_status '{"ok":true,"data":{"installed":false,"peers":[]}}'
    scr 'tui_awg_node de' <<< $'c\nd\nx\n0'
    [[ "$output" == *'AmneziaWG на ноде не установлен'* ]]
    [ "$(grep -c 'Неверный выбор.' <<< "$output")" -eq 3 ]
    ! calls | grep -qE 'awg (sync|remove)' || return 1
    fx awg_status "$(err not_found)"
    scr 'tui_awg_node de; echo rc=$?' <<< ''
    [[ "$output" == *'rc=0'* ]]
}

@test "screens: awg lists nodes and opens one" {
    _fixtures; _node_fixtures
    scr 'tui_awg' <<< $'2\n0\n0'
    [[ "$output" == *'AmneziaWG: ru'* ]]
    assert_call 'awg status --node ru'
}

@test "screens: awg status needs-setup is not retried" {
    _fixtures; _node_fixtures
    fx awg_status "$(err needs_setup)"
    scr 'tui_awg_node de; echo rc=$?' <<< ''
    [ "$(calls | grep -c '^awg status')" -eq 1 ]
    [[ "$output" == *'rc=0'* ]]
}

TG_RES='{"results":[{"node":"de","code":0,"status":"ok","reason":null},{"node":"ru","code":1,"status":"error","reason":"timeout"}]}'

@test "screens: telegram status prints the results table" {
    _fixtures; _node_fixtures
    fx telegram_status "{\"ok\":true,\"data\":$TG_RES}"
    scr 'tui_telegram' <<< $'S\n0'
    assert_call 'telegram status --all'
    [[ "$output" == *'de  готово'* && "$output" == *'ru  '*'ошибка'*'  timeout'* ]]
}

@test "screens: every telegram batch action needs consent and prints results even on partial" {
    _fixtures; _node_fixtures
    local key cmd
    for pair in 'i|telegram install' 'p|telegram refresh-ip' 'w|telegram web-update' 'r|telegram web-restart' \
        'b|telegram backend-restart' 'x|telegram remove-all'; do
        key="${pair%%|*}"
        cmd="${pair#*|}"
        fx "$(tr ' ' _ <<< "$cmd").1" "$CONFIRM"
        scr 'tui_telegram' <<< "$key"$'\n1\n2\n\nn\n0'
        assert_call "$cmd --node de --node ru"
        refute_yes
        fx "$(tr ' ' _ <<< "$cmd").2" "{\"ok\":false,\"error\":{\"code\":\"partial\",\"message\":\"m\"},\"data\":$TG_RES}"
        scr 'tui_telegram' <<< "$(printf '%s' "$key" | tr a-z A-Z)"$'\n1\n2\n\ny\n0'
        assert_call "$cmd --node de --node ru --yes --plan-token T1"
        [[ "$output" == *'ru  '*'ошибка'* ]] || { echo "$cmd: no table"; echo "$output"; return 1; }
        rm -f "$FX"/telegram_*.1 "$FX"/telegram_*.2
    done
}

@test "screens: telegram remove asks for the component; empty node selection warns" {
    _fixtures; _node_fixtures
    fx telegram_remove.1 "$CONFIRM"
    scr 'tui_telegram' <<< $'d\n1\n1\n2\n\nn\n0'
    assert_call 'telegram remove --component web --node de --node ru'
    refute_yes
    scr 'tui_telegram' <<< $'D\n2\n1\n2\n\nn\n0'
    assert_call 'telegram remove --component mtproto --node de --node ru'
    scr 'tui_telegram' <<< $'i\n\n0'
    [[ "$output" == *'Ничего не выбрано.'* ]]
    ! calls | grep -q 'telegram install' || return 1
}

@test "screens: telegram single node management goes through the consent for scripts" {
    _fixtures; _node_fixtures
    fx telegram_menu.1 "$CONFIRM"
    scr 'tui_telegram' <<< $'o\n1\nn\n0'
    assert_call 'telegram menu --node de'
    refute_yes
    fx telegram_menu.2 "$OK_NULL"
    scr 'tui_telegram' <<< $'O\n1\ny\n0'
    assert_call 'telegram menu --node de --yes --plan-token T1'
}

# ─── screens: system.sh ──────────────────────────────────────────────────────

_system_fixtures() {
    fx status '{"ok":true,"data":{"version":"1.1.0","update":{"current":"1.1.0","latest":"v1.2.0","available":true},"script_password":false,"source":{"type":"github","repo":"o/r","sync":"pending"},"counts":{"nodes":2,"groups":3,"clients":1},"password_missing":["ru"],"ssh_setup_pending":true,"subscription_host":null}}'
    fx source_status '{"ok":true,"data":{"type":"github","repo":"o/r","branch":"main","storage":"age","sync":"clean","key_saved":false}}'
    fx self_version '{"ok":true,"data":{"current":"1.1.0","latest":"v1.2.0","update_available":true,"checked":true}}'
    fx source_github-accounts '{"ok":true,"data":{"accounts":["test-owner"],"global_login":"glob"}}'
}

secrets() { cat "$BATS_TEST_TMPDIR/fx/secrets.log" 2>/dev/null || true; }

@test "screens: every system.sh screen handles 0, EOF, an unknown key and Enter" {
    _system_fixtures
    local s
    for s in tui_dashboard tui_source tui_settings; do
        nav_checks "$s" || { echo "screen: $s"; return 1; }
    done
    fx source_status '{"ok":true,"data":{"type":"local","repo":null,"branch":null,"storage":null,"sync":null,"key_saved":null}}'
    nav_checks tui_source
}

@test "screens: dashboard shows the status summary and dispatches every section" {
    _system_fixtures
    scr 'for f in tui_nodes tui_clients tui_groups tui_templates tui_connections tui_generate \
            tui_subscriptions tui_awg tui_telegram tui_source tui_settings; do
            eval "$f() { echo SCREEN:$f; }"
        done
        tui_dashboard; echo rc=$?' <<< $'n\nC\ng\nM\np\nf\ns\na\nt\nI\no\n0'
    [[ "$output" == *'Remote Control v1.1.0'* && "$output" == *'Доступно обновление v1.2.0 — раздел o'* ]]
    [[ "$output" == *'Источник: GitHub o/r • ожидает отправки'* ]]
    [[ "$output" == *'Ноды: 2  Клиенты: 1  Группы: 3'* && "$output" == *'Хост подписок не задан'* ]]
    [[ "$output" == *'Нет пароля SSH: ru'* && "$output" == *'Отложена SSH-настройка нод — раздел n → h'* ]]
    [ "$(grep -o 'SCREEN:[a-z_]*' <<< "$output" | tr '\n' ' ')" = 'SCREEN:tui_nodes SCREEN:tui_clients SCREEN:tui_groups SCREEN:tui_templates SCREEN:tui_connections SCREEN:tui_generate SCREEN:tui_subscriptions SCREEN:tui_awg SCREEN:tui_telegram SCREEN:tui_source SCREEN:tui_settings ' ]
    [[ "$output" == *'rc=0'* ]]
    fx status '{"ok":true,"data":{"version":"1.1.0","update":{"current":"1.1.0","latest":null,"available":false},"script_password":false,"source":{"type":"local","repo":null,"sync":null},"counts":{"nodes":0,"groups":3,"clients":0},"password_missing":[],"ssh_setup_pending":false,"subscription_host":"de"}}'
    scr 'tui_dashboard' <<< '0'
    [[ "$output" == *'Источник: локальная'* && "$output" == *'Хост подписок: de'* ]]
    [[ "$output" != *'Доступно обновление'* && "$output" != *'Нет пароля SSH'* && "$output" != *'Отложена'* ]]
}

@test "screens: source sync, local switch and recovery key use the real commands" {
    _system_fixtures
    scr 'tui_source' <<< $'f\nP\ne\nk\n/tmp/key.txt\n0'
    assert_call 'source github-fetch'
    assert_call 'source github-push'
    assert_call 'source github-switch-local'
    assert_call 'source github-import-recovery-key --file /tmp/key.txt'
    fx source_status '{"ok":true,"data":{"type":"github","repo":"o/r","branch":"main","storage":"none","sync":"clean","key_saved":null}}'
    scr 'tui_source' <<< $'r\nv\nk\n0'
    [ "$(grep -c 'Неверный выбор.' <<< "$output")" -eq 3 ]
    [[ "$output" != *'Сменить пароль доступа'* ]]
    ! calls | grep -qE 'rewrap|rotate|import' || return 1
}

@test "screens: rewrap sends both passwords only as secrets and clears them; mismatch calls nothing" {
    _system_fixtures
    scr 'tui_source' <<< $'r\nold-pass\nnew-pass\nnew-pass\n0'
    assert_call 'source github-rewrap-password'
    [ "$(secrets | wc -l)" -eq 1 ]
    [[ "$(secrets)" == 'source github-rewrap-password {"vault-password":"old-pass","new-vault-password":"new-pass"}' ]]
    ! calls | grep -qE 'old-pass|new-pass' || return 1
    [ "$(calls | tail -n 1)" = 'source status' ]
    scr 'tui_source' <<< $'r\nold-pass\nnew-pass\nother\n0'
    [[ "$output" == *'Пароли не совпадают.'* ]]
    ! calls | grep -q rewrap || return 1
    [ -z "$(secrets)" ]
}

@test "screens: rotate, replace and delete need consent; delete failure prints the settings link" {
    _system_fixtures
    fx source_github-rotate-key.1 "$CONFIRM"
    scr 'tui_source' <<< $'v\nn1\nn1\nn\n0'
    assert_call 'source github-rotate-key'
    refute_yes
    fx source_github-rotate-key.2 "$OK_NULL"
    scr 'tui_source' <<< $'V\nn1\nn1\ny\n0'
    assert_call 'source github-rotate-key --yes --plan-token T1'
    [[ "$(secrets)" == *'"new-vault-password":"n1"'* ]]
    fx source_github-replace-with-local.1 "$(err key_provisioning_required '"nodes":["de"]')"
    fx source_github-replace-with-local.2 "$CONFIRM"
    fx source_github-replace-with-local.3 "$OK_NULL"
    scr 'tui_source' <<< $'l\ny\ny\n0'
    assert_call 'source github-replace-with-local'
    assert_call 'source github-replace-with-local --provision-keys yes'
    assert_call 'source github-replace-with-local --provision-keys yes --yes --plan-token T1'
    fx source_github-delete-repo.1 "$CONFIRM"
    scr 'tui_source' <<< $'d\nn\n0'
    assert_call 'source github-delete-repo'
    refute_yes
    fx source_github-delete-repo.2 "$(err remote_failed '"settings_url":"https://github.com/o/r/settings"')"
    scr 'tui_source' <<< $'D\ny\n0'
    assert_call 'source github-delete-repo --yes --plan-token T1'
    [[ "$output" == *'Удалите репозиторий вручную: '*'https://github.com/o/r/settings'* ]]
}

@test "screens: local source offers only GitHub connection through the wizard" {
    _system_fixtures
    fx source_status '{"ok":true,"data":{"type":"local","repo":null,"branch":null,"storage":null,"sync":null,"key_saved":null}}'
    scr 'tui_github_wizard() { echo "WIZARD:$1"; }; tui_source' <<< $'G\nf\n0'
    [[ "$output" == *'Источник: локальная'* && "$output" == *'WIZARD:connect'* ]]
    [ "$(grep -c 'Неверный выбор.' <<< "$output")" -eq 1 ]
    ! calls | grep -q 'github-fetch' || return 1
}

@test "screens: connect wizard answers login, repository, storage, password and key decisions" {
    _system_fixtures
    fx source_github-connect.1 "$(err github_auth_required '"login":"test-owner","hint":"h"')"
    fx source_github-connect.2 "$(err repo_create_required '"repo":"test-owner/cfg"')"
    fx source_github-connect.3 "$(err storage_mode_required '"choices":["age","none"]')"
    fx source_github-connect.4 "$(err new_vault_password_required)"
    fx source_github-connect.5 "$(err key_provisioning_required '"nodes":["de"]')"
    fx source_github-connect.6 '{"ok":true,"data":{"repo":"test-owner/cfg","storage":"age","sync":"clean"}}'
    scr 'tui_github_wizard connect; echo rc=$?' <<< $'1\n\ny\n1\nvp\nvp\nn'
    [[ "$output" == *'1) test-owner'* && "$output" == *'2) glob'* && "$output" == *'3) Указать другой логин'* ]]
    assert_call 'source github-login --login test-owner'
    assert_call 'source github-connect --login test-owner --create-repo --storage age'
    assert_call 'source github-connect --login test-owner --create-repo --storage age --provision-keys no'
    [[ "$(secrets)" == *'{"new-vault-password":"vp"}'* ]]
    [[ "$output" == *'rc=0'* ]]
}

@test "screens: connect wizard handles vault password, existing configuration and another login" {
    _system_fixtures
    fx source_github-connect.1 "$(err vault_password_required)"
    fx source_github-connect.2 "$(err existing_config_action_required '"choices":["remote","local"],"remote_counts":{"nodes":2,"clients":1,"groups":3},"local_counts":null')"
    fx source_github-connect.3 "$CONFIRM"
    fx source_github-connect.4 "$OK_NULL"
    # Замену конфигурации подтверждает только план команды, без отдельного вопроса.
    scr 'tui_github_wizard connect; echo rc=$?' <<< $'3\nother-owner\nvp\ny\n2\ny'
    [[ "$output" == *'Использовать конфигурацию из GitHub (ноды 2, клиенты 1)'* ]]
    [[ "$output" != *'Заменить конфигурацию в GitHub?'* && "$output" == *'План: X'* ]]
    assert_call 'source github-connect --login other-owner --remember-key --existing local'
    assert_call 'source github-connect --login other-owner --remember-key --existing local --yes --plan-token T1'
    # Секрет остаётся в повторе с токеном плана.
    [[ "$(secrets)" == *'--yes --plan-token T1 {"vault-password":"vp"'* ]]
    [[ "$output" == *'rc=0'* ]]
}

@test "screens: wizard refusal or EOF at any step cancels without further calls" {
    _system_fixtures
    fx source_github-connect.1 "$(err repo_create_required '"repo":"test-owner/cfg"')"
    scr 'tui_github_wizard connect; echo rc=$?' <<< $'1\nn'
    [[ "$output" == *'Отменено.'* && "$output" == *'rc=1'* ]]
    [ "$(calls | grep -c 'github-connect')" -eq 1 ]
    scr 'tui_github_wizard connect; echo rc=$?' < /dev/null
    [[ "$output" == *'Отменено.'* && "$output" == *'rc=1'* ]]
    ! calls | grep -q 'github-connect' || return 1
}

@test "screens: change wizard answers cache, target and privacy decisions and shows the old repository" {
    _system_fixtures
    fx source_github-change-account.1 "$(err cache_skip_required)"
    fx source_github-change-account.2 "$(err target_replace_required '"repo":"glob/cfg","tracked_files":3')"
    fx source_github-change-account.3 "$(err repo_private_required '"repo":"glob/cfg"')"
    fx source_github-change-account.4 "$CONFIRM"
    fx source_github-change-account.5 '{"ok":true,"data":{"repo":"glob/cfg","sync":"clean","old_repo_settings_url":"https://github.com/test-owner/cfg/settings"}}'
    # Удаление файлов и приватность подтверждает один план команды.
    scr 'tui_github_wizard change; echo rc=$?' <<< $'2\ny\ny'
    [[ "$output" == *'План: X'* ]]
    assert_call 'source github-change-account --login glob --without-cache --replace-target --make-private'
    assert_call 'source github-change-account --login glob --without-cache --replace-target --make-private --yes --plan-token T1'
    [[ "$output" == *'Прежний репозиторий можно удалить вручную: '*'https://github.com/test-owner/cfg/settings'* ]]
    [[ "$output" == *'rc=0'* ]]
    scr 'tui_github_wizard change; echo rc=$?' <<< $'2\nn'
    [[ "$output" == *'Отменено.'* && "$output" == *'rc=1'* ]]
    [ "$(calls | grep -c 'github-change-account')" -eq 1 ]
    scr 'tui_github_wizard change; echo rc=$?' <<< $'2\ny\nn'
    [[ "$output" == *'Отменено.'* && "$output" == *'rc=1'* ]]
    [ "$(calls | grep -c 'github-change-account')" -eq 4 ]
    refute_yes
}

@test "screens: settings update and uninstall need consent and exit the TUI with 0" {
    _system_fixtures
    fx self_update.1 "$CONFIRM"
    scr 'tui_settings; echo rc=$?' <<< $'u\nn\n0'
    assert_call 'self update'
    refute_yes
    fx self_update.2 "$OK_NULL"
    scr 'tui_settings; echo AFTER' <<< $'U\ny'
    [ "$status" -eq 0 ]
    assert_call 'self update --yes --plan-token T1'
    [[ "$output" == *'Запустите remote-control-essence заново.'* && "$output" != *AFTER* ]]
    fx self_uninstall.1 "$CONFIRM"
    fx self_uninstall.2 "$OK_NULL"
    scr 'tui_settings; echo AFTER' <<< $'x\n2\ny'
    [ "$status" -eq 0 ]
    assert_call 'self uninstall --remove-data'
    assert_call 'self uninstall --remove-data --yes --plan-token T1'
    [[ "$output" != *AFTER* ]]
}

@test "screens: settings password set and remove send passwords only as secrets" {
    _system_fixtures
    scr 'tui_settings' <<< $'l\nnew-pw\nnew-pw\n0'
    assert_call 'self password-set'
    [[ "$(secrets)" == 'self password-set {"password":"new-pw"}' ]]
    [[ "$output" != *'Убрать пароль запуска'* ]]
    fx status '{"ok":true,"data":{"script_password":true}}'
    scr 'tui_settings' <<< $'l\ncur\nnew-pw\nnew-pw\n0'
    [[ "$(secrets)" == 'self password-set {"current-password":"cur","password":"new-pw"}' ]]
    fx self_password-remove.1 "$CONFIRM"
    fx self_password-remove.2 "$OK_NULL"
    scr 'tui_settings' <<< $'r\ncur\ny\n0'
    assert_call 'self password-remove --yes --plan-token T1'
    [ "$(calls | tail -n 1)" = 'status' ]
    ! calls | grep -q 'cur' || return 1
    fx self_version '{"ok":true,"data":{"current":"1.1.0","latest":null,"update_available":false,"checked":false}}'
    scr 'tui_settings' <<< $'u\n0'
    [[ "$output" == *'Не удалось проверить обновления'* && "$output" == *'Неверный выбор.'* ]]
}

@test "screens: first run creates a local configuration, starts the wizard or exits" {
    fx session_status '{"ok":true,"data":{"configured":false}}'
    scr 'tui_startup; echo rc=$?' <<< '1'
    assert_call 'source init-local'
    assert_call 'session open'
    [[ "$output" == *'rc=0'* ]]
    scr 'tui_github_wizard() { echo "WIZARD:$1"; }; tui_startup; echo rc=$?' <<< '2'
    [[ "$output" == *'WIZARD:connect'* && "$output" == *'rc=0'* ]]
    scr 'tui_startup; echo rc=$?' <<< $'x\n0'
    [[ "$output" == *'Неверный выбор.'* && "$output" == *'rc=2'* ]]
    ! calls | grep -q 'session open' || return 1
    scr 'tui_startup; echo rc=$?' < /dev/null
    [[ "$output" == *'rc=1'* ]]
}

@test "screens: startup asks the vault password with remember-key and clears secrets" {
    fx session_status '{"ok":true,"data":{"configured":true}}'
    fx session_open.1 "$(err vault_password_required)"
    fx session_open.2 "$(err vault_password_invalid)"
    scr 'tui_startup; echo rc=$?; echo "secrets=${TUI_SECRETS:-none}"' <<< $'p1\nn\np2\ny'
    assert_call 'session open --remember-key'
    [[ "$(secrets)" == *'{"vault-password":"p1"}'* && "$(secrets)" == *'{"vault-password":"p2"}'* ]]
    [[ "$output" == *'rc=0'* && "$output" == *'secrets=none'* ]]
}

@test "screens: three wrong script passwords open the recovery menu; retry or exit" {
    fx session_status '{"ok":true,"data":{"configured":true}}'
    fx session_open.1 "$(err auth_required)"
    fx session_open.2 "$(err auth_failed)"
    fx session_open.3 "$(err auth_failed)"
    fx session_open.4 "$(err auth_failed)"
    scr 'tui_startup; echo rc=$?' <<< $'a\nb\nc\n0'
    [[ "$output" == *'Восстановление доступа'* && "$output" == *'rc=1'* ]]
    [ "$(calls | grep -c 'session open')" -eq 4 ]
    fx session_open.5 "$(err auth_required)"
    fx session_open.6 "$OK_NULL"
    scr 'tui_startup; echo rc=$?' <<< $'a\nb\nc\n1\nd'
    [[ "$output" == *'rc=0'* ]]
    [[ "$(secrets | tail -n 1)" == *'{"script-password":"d"}'* ]]
}

@test "screens: an outdated GitHub format is migrated with its own password check, then opened" {
    fx session_status '{"ok":true,"data":{"configured":true}}'
    fx session_open.1 "$(err github_format_outdated '"version":"1","required":null')"
    fx source_github-migrate-format.1 "$(err auth_required)"
    fx source_github-migrate-format.2 "$CONFIRM"
    fx source_github-migrate-format.3 "$OK_NULL"
    scr 'tui_startup; echo rc=$?' <<< $'1\npw\ny'
    [[ "$output" == *'Конфигурация GitHub требует восстановления'* && "$output" == *'Формат конфигурации: v1'* ]]
    assert_call 'source github-migrate-format --yes --plan-token T1'
    [[ "$(secrets)" == *'"script-password":"pw"'* ]]
    [ "$(calls | tail -n 1)" = 'session open' ]
    [[ "$output" == *'rc=0'* ]]
}

@test "screens: a newer GitHub format only exits; replace and locked use their own flows" {
    fx session_status '{"ok":true,"data":{"configured":true}}'
    fx session_open.1 "$(err github_format_newer '"version":"9","required":"9.9.9"')"
    scr 'tui_startup; echo rc=$?' <<< $'1\n2\n0'
    [ "$(grep -c 'Неверный выбор.' <<< "$output")" -eq 2 ]
    [[ "$output" == *'Требуется remote-control: v9.9.9'* && "$output" == *'rc=1'* ]]
    ! calls | grep -qE 'migrate|replace' || return 1
    fx session_open.1 "$(err github_format_invalid)"
    fx source_github-replace-with-local.1 "$CONFIRM"
    scr 'tui_startup; echo rc=$?' <<< $'2\nn\n0'
    assert_call 'source github-replace-with-local'
    refute_yes
    [[ "$output" == *'rc=1'* ]]
    fx session_open.1 "$(err locked)"
    scr 'tui_startup; echo rc=$?' <<< '1'
    [[ "$output" == *'Конфигурация занята'* && "$output" == *'rc=0'* ]]
}

# ─── client: hardening ───────────────────────────────────────────────────────

@test "client: an argv element with a newline and --yes stays one element" {
    reply 1 '{"id":@ID@,"ok":true}'
    tui_sh 'tui_call client add --name $'"'"'x\n--yes'"'"' --group PC'
    jq -e '.argv == ["client","add","--name","x\n--yes","--group","PC"]' "$FAKE/requests.log" >/dev/null
}

@test "client: tui_call with no arguments sends an empty argv" {
    reply 1 '{"id":@ID@,"ok":true}'
    tui_sh 'tui_call'
    jq -e '.argv == []' "$FAKE/requests.log" >/dev/null
}

@test "client: log text loses C0 and C1 control characters but keeps text" {
    reply 1 \
        '{"id":@ID@,"event":"log","level":"warn","text":"a\u001b[2Jb\u009bc\u0007d\u0000e"}' \
        '{"id":@ID@,"ok":true,"data":null}'
    tui_sh 'tui_call group list'
    [ "$status" -eq 0 ]
    [[ "$output" == *'a[2Jbcd'* ]]
    [[ "$output" != *$'\a'* ]]
    [[ "$output" != *$'\xc2\x9b'* ]]
}

@test "client: share bundle passes the subscription url to qrencode and jq only through stdin" {
    mkdir -p "$FAKE/bin"
    printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s/qr.argv"\ncat > "%s/qr.stdin"\n' "$FAKE" "$FAKE" > "$FAKE/bin/qrencode"
    chmod +x "$FAKE/bin/qrencode"
    printf '#!/bin/bash\nprintf "%%s\\n" "$@" >> "%s/jq.argv"\nexec "%s" "$@"\n' "$FAKE" "$(command -v jq)" > "$FAKE/bin/jq"
    chmod +x "$FAKE/bin/jq"
    reply 1 '{"id":@ID@,"ok":true,"data":{"client":"phone","url":"https://h.example/sub/SECRET_TOKEN","expires_at":null,"headers":[]}}'
    PATH="$FAKE/bin:$PATH" tui_sh 'tui_call sub show --client phone; : > "$FAKE/jq.argv"; tui_render_share_bundle'
    [ "$status" -eq 0 ]
    [[ "$output" == *'{"url":"https://h.example/sub/SECRET_TOKEN"}'* ]]
    ! grep -q 'SECRET_TOKEN' "$FAKE/qr.argv" || return 1
    [ "$(cat "$FAKE/qr.stdin")" = 'https://h.example/sub/SECRET_TOKEN' ]
    ! grep -q 'SECRET_TOKEN' "$FAKE/jq.argv"
}

# ─── security round 1: nodes ───

@test "screens: node add key replacement sends the password only as a secret on both plan calls" {
    _fixtures
    local replace='node add --name vps --ip 1.2.3.4 --port 22 --user root --auth password --tag TAG --replace-host-key SHA256:aaa'
    fx node_add.1 "$(err host_key_changed '"host":"1.2.3.4","port":22,"fingerprints":["SHA256:aaa"]')"
    fx node_add.2 "$CONFIRM"
    fx node_add.3 '{"ok":true,"data":{"name":"vps","id":"x","needs_setup":false}}'
    scr 'tui_node_add; echo "left=[${TUI_SECRETS:-}]"' <<< $'vps\n1.2.3.4\n22\nroot\n2\nPW-REPLACE-secret\nTAG\ny\n'
    assert_call "$replace"
    assert_call "$replace --yes --plan-token T1"
    [ "$(paste -sd, - < "$FX/pw.log")" = PW-REPLACE-secret,PW-REPLACE-secret,PW-REPLACE-secret ]
    ! calls | grep -q PW-REPLACE || return 1
    [[ "$output" != *PW-REPLACE* && "$output" == *'left=[]'* ]]
}

# ─── security round 1: github wizard (S-M9) ─────────────────────────────────

@test "screens: connect wizard re-reviews plan_changed and retries the same argv with the new token" {
    _system_fixtures
    fx source_github-connect.1 "$(err storage_mode_required '"choices":["age","none"]')"
    fx source_github-connect.2 "$CONFIRM"
    fx source_github-connect.3 "$(err plan_changed '"plan":["Новый план"],"plan_token":"T2"')"
    fx source_github-connect.4 "$OK_NULL"
    scr 'tui_github_wizard connect; echo rc=$?' <<< $'1\n2\ny\ny'
    [[ "$output" == *'План: X'* && "$output" == *'Новый план'* ]]
    assert_call 'source github-connect --login test-owner --storage none'
    assert_call 'source github-connect --login test-owner --storage none --yes --plan-token T1'
    assert_call 'source github-connect --login test-owner --storage none --yes --plan-token T2'
    [[ "$output" == *'rc=0'* ]]
    scr 'tui_github_wizard connect; echo rc=$?' <<< $'1\n2\nn'
    [[ "$output" == *'Отменено.'* && "$output" == *'rc=1'* ]]
    refute_yes
}

# ─── security round 1: clients ───────────────────────────────────────────────

@test "screens: returning client nodes to the group shows the plan and needs consent (S-L8)" {
    _fixtures
    fx client_nodes.1 "$CONFIRM"
    scr 'tui_client_card bob' <<< $'n\n2\nn\n0'
    assert_call 'client nodes --name bob --inherit'
    [[ "$output" == *'План: X'* ]]
    refute_yes
    fx client_nodes.2 "$OK_NULL"
    scr 'tui_client_card bob' <<< $'n\n2\ny\n0'
    assert_call 'client nodes --name bob --inherit --yes --plan-token T1'
}

@test "screens: publishing all subscriptions shows the plan and needs consent (S-M7)" {
    _fixtures
    fx sub_publish-all.1 "$CONFIRM"
    scr 'tui_subscriptions' <<< $'u\nn\n0'
    assert_call 'sub publish-all'
    [[ "$output" == *'План: X'* && "$output" != *'Опубликовано: alice'* ]]
    refute_yes
    fx sub_publish-all.2 '{"ok":true,"data":{"published":["alice"],"skipped":[],"failed":[],"removed":1}}'
    scr 'tui_subscriptions' <<< $'U\ny\n0'
    assert_call 'sub publish-all --yes --plan-token T1'
    [[ "$output" == *'Опубликовано: alice'* ]]
}

# ─── round 2: dispatch ───────────────────────────────────────────────────────

@test "client: giving up after repeated plan_changed tells the user nothing was done" {
    reply 1 '{"id":@ID@,"ok":false,"error":{"code":"confirmation_required","message":"m","plan":["p"],"plan_token":"T1"}}'
    local n
    for n in 2 3 4; do
        reply "$n" '{"id":@ID@,"ok":false,"error":{"code":"plan_changed","message":"m","plan":["p"],"plan_token":"T'"$n"'"}}'
    done
    tui_sh 'tui_run_confirmed "Удаление" "Удалить?" group delete --name A; echo "rc=$?"' <<< $'y\ny\ny\ny'
    [[ "$output" == *'План продолжает меняться. Действие не выполнено'*'rc=1'* ]]
}

# ─── round 2: nodes ──────────────────────────────────────────────────────────

@test "screens: harden confirms the plan requested with the accepted port, not the random one (R2-M4)" {
    _fixtures
    fx node_harden.1 "$(HCONF T1 40000)"
    fx node_harden.2 "$(HCONF T2 40000)"
    fx node_harden.3 "$OK_NULL"
    scr 'tui_node_harden ru' <<< $'\ny'
    [ "$(calls | grep -c '^node harden')" -eq 3 ]
    [ "$(calls | sed -n 2p)" = 'node harden --name ru --port 40000' ]
    [ "$(calls | sed -n 3p)" = 'node harden --name ru --port 40000 --yes --plan-token T2' ]
    ! calls | grep -qF -- '--plan-token T1' || return 1
    [ "$(printf '%s' "$output" | grep -c 'План 40000')" -eq 1 ]
}

# ─── round 2: clients ────────────────────────────────────────────────────────

@test "screens: partial rename, publish and rotate keep their results (R2-H3, R2-M8)" {
    _fixtures
    local partial='{"ok":false,"error":{"code":"partial","message":"m"},"data":{"name":"alice.2"}}'
    fx client_rename "$partial"
    fx client_list.2 '{"ok":true,"data":[{"name":"alice.2","group":"PC","inherit_nodes":true,"nodes":["de"],"subscription":{"published":true,"expires_at":null}}]}'
    fx client_list.3 '{"ok":true,"data":[{"name":"alice.2","group":"PC","inherit_nodes":true,"nodes":["de"],"subscription":{"published":true,"expires_at":null}}]}'
    scr 'tui_client_card alice; echo rc=$?' <<< $'r\nalice2\ng\n2\n0'
    assert_call 'client set-group --name alice.2 --group MOBILE'
    [[ "$output" == *'Клиент: alice.2'* && "$output" == *'rc=0'* ]]
    fx sub_publish '{"ok":false,"error":{"code":"partial","message":"m"},"data":{"client":"alice","url":"u","expires_at":null}}'
    scr 'tui_client_subscription alice' <<< $'p\n\n0'
    assert_call 'sub show --client alice'
    fx sub_publish '{"ok":false,"error":{"code":"remote_failed","message":"m"}}'
    scr 'tui_client_subscription alice' <<< $'p\n\n0'
    ! calls | grep -q '^sub show' || return 1
    fx sub_rotate.1 "$CONFIRM"
    fx sub_rotate.2 '{"ok":false,"error":{"code":"partial","message":"m"},"data":{"client":"alice","url":"u"}}'
    scr 'tui_client_subscription alice' <<< $'r\ny\n0'
    assert_call 'sub rotate --client alice --yes --plan-token T1'
    assert_call 'sub show --client alice'
}

@test "screens: client rename goes through the plan when AmneziaWG peers are removed (R2-M8)" {
    _fixtures
    fx client_rename.1 "$CONFIRM"
    scr 'tui_client_card alice' <<< $'r\nalice2\nn\n0'
    assert_call 'client rename --name alice --new-name alice2'
    refute_yes
    [[ "$output" == *'План: X'* && "$output" == *'Клиент: alice'* ]]
    fx client_rename.2 '{"ok":true,"data":{"name":"alice.2"}}'
    fx client_list.2 '{"ok":true,"data":[{"name":"alice.2","group":"PC","inherit_nodes":true,"nodes":["de"],"subscription":{"published":true,"expires_at":null}}]}'
    fx client_list.3 '{"ok":true,"data":[{"name":"alice.2","group":"PC","inherit_nodes":true,"nodes":["de"],"subscription":{"published":true,"expires_at":null}}]}'
    scr 'tui_client_card alice; echo rc=$?' <<< $'R\nalice2\ny\ng\n2\n0'
    assert_call 'client rename --name alice --new-name alice2 --yes --plan-token T1'
    assert_call 'client set-group --name alice.2 --group MOBILE'
    [[ "$output" == *'Клиент: alice.2'* && "$output" == *'rc=0'* ]]
}

@test "screens: partial delete leaves only surviving client cards open" {
    _fixtures
    fx client_delete '{"ok":false,"error":{"code":"partial","message":"cleanup"},"data":{"deleted":["bob"]}}'
    scr 'tui_client_card bob' <<< $'d\n0'
    [ "$(calls | grep -c '^client list')" -eq 1 ]
    [[ "$output" != *'не найден'* ]]
    fx client_delete '{"ok":false,"error":{"code":"partial","message":"cleanup"},"data":{"deleted":[]}}'
    scr 'tui_client_card bob' <<< $'d\n0'
    [ "$(calls | grep -c '^client list')" -eq 2 ]
}

@test "screens: empty client data has no empty connections section" {
    fx client_show '{"ok":true,"data":{"group":"PC","nodes":[],"credentials":{},"config":{"path":"x","exists":false},"subscription":null,"connections":[]}}'
    scr '_tui_client_show bob'
    [[ "$output" == *'Ноды: нет'* && "$output" != *'Подключения по нодам:'* ]]
    fx client_show '{"ok":true,"data":{"group":"PC","nodes":["de"],"credentials":{},"config":{"path":"x","exists":false},"subscription":null,"connections":[{"node":"de","mode":"own","proxies":[]}]}}'
    scr '_tui_client_show bob'
    [[ "$output" == *'de (свои): нет'* ]]
}

@test "screens: client node picker uses addresses and skips vanished nodes" {
    _fixtures
    fx node_list '{"ok":true,"data":[{"name":"ru","ip":"5.6.7.8","port":2222}]}'
    fx client_connections.1 "$CONFIRM"
    scr 'tui_client_card bob' <<< $'p\n1\n2\nn\n0'
    [[ "$output" == *'ru  5.6.7.8:2222'* && "$output" != *'de  1.2.3.4'* ]]
    assert_call 'client connections --name bob --node ru --reset'
}

@test "screens: resolved header labels translate without changing sources" {
    fx sub_headers '{"ok":true,"data":[{"name":"a","value":"1","source":"default"},{"name":"b","value":"2","source":"group"},{"name":"c","value":"3","source":"client"}]}'
    scr '_tui_resolved_headers bob'
    [[ "$output" == *'[по умолчанию]'* && "$output" == *'[группа]'* && "$output" == *'[клиент]'* ]]
}

@test "screens: subscription host retries only after resolver permits it" {
    _fixtures
    fx sub_host.2 '{"ok":false,"error":{"code":"missing_secret","message":"m"}}'
    fx sub_host.3 '{"ok":true,"data":{"node":"ru"}}'
    scr 'tui_handle_node_codes() { echo resolver:$1; return 2; }; tui_subscriptions' <<< $'h\n2\n0'
    [[ "$output" == *'resolver:ru'* ]]
    [ "$(calls | grep -c '^sub host --node ru$')" -eq 2 ]
    scr 'tui_handle_node_codes() { return 1; }; tui_subscriptions' <<< $'h\n2\n0'
    [ "$(calls | grep -c '^sub host --node ru$')" -eq 1 ]
}

@test "screens: template file prompts expand only home tilde" {
    _fixtures
    scr 'tui_template_card m.yaml' <<< $'x\n~/out.yaml\ni\n~other/file\n0'
    assert_call "template export --name m.yaml --output $HOME/out.yaml"
    assert_call 'template import --name m.yaml --file ~other/file'
    scr 'tui_template_card m.yaml' <<< $'i\n~/in.yaml\nx\n~\n0'
    assert_call "template import --name m.yaml --file $HOME/in.yaml"
    assert_call "template export --name m.yaml --output $HOME"
}

@test "screens: host node resolver requires consent and preserves unsafe-change failures" {
    _fixtures
    fx sub_host.2 '{"ok":false,"error":{"code":"missing_secret","message":"m"}}'
    fx sub_host.3 '{"ok":false,"error":{"code":"conflict","message":"m"}}'
    scr 'tui_subscriptions' <<< $'h\n2\ny\nsecret\n0'
    assert_call 'node password --name ru'
    [ "$(calls | grep -c '^sub host --node ru$')" -eq 2 ]
    scr 'tui_subscriptions' <<< $'h\n2\nn\n0'
    [ "$(calls | grep -c '^sub host --node ru$')" -eq 1 ]
    ! calls | grep -q '^node password' || return 1
    fx sub_host.2 '{"ok":false,"error":{"code":"needs_setup","message":"m"}}'
    scr 'tui_subscriptions' <<< $'h\n2\n0'
    [ "$(calls | grep -c '^sub host --node ru$')" -eq 1 ]
    [[ "$output" == *'SSH-настройки'* ]]
}

@test "client: zero migration info event reaches the user without confirmation" {
    reply 1 '{"id":@ID@,"event":"log","level":"info","text":"Нет опубликованных подписок для переноса; хост не изменён."}' \
        '{"id":@ID@,"ok":true,"data":{"node":"ru","base_url":null,"migrated":0}}'
    tui_sh 'tui_run_confirmed "Перенос" "Перенести?" sub migrate --node ru; echo "migrated=$(tui_q .migrated)"'
    [[ "$output" == *'хост не изменён'* && "$output" == *'migrated=0'* ]]
    [ "$(wc -l < "$FAKE/requests.log")" -eq 1 ]
}

@test "screens: host key change retries host selection only after trust" {
    _fixtures
    fx sub_host.2 '{"ok":false,"error":{"code":"host_key_changed","message":"m","fingerprints":["SHA256:test"]}}'
    fx sub_host.3 '{"ok":true,"data":{"node":"ru"}}'
    fx node_trust-host-key.1 "$CONFIRM"
    fx node_trust-host-key.2 "$OK_NULL"
    scr 'tui_subscriptions' <<< $'h\n2\ny\n0'
    assert_call 'node trust-host-key --name ru --host-key SHA256:test --yes --plan-token T1'
    [ "$(calls | grep -c '^sub host --node ru$')" -eq 2 ]
    scr 'tui_subscriptions' <<< $'h\n2\nn\n0'
    [ "$(calls | grep -c '^sub host --node ru$')" -eq 1 ]
    refute_yes
}
