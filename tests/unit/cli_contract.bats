#!/usr/bin/env bats
# Контракт ядра на реальном entrypoint в installed-layout: разовый CLI и serve.
bats_require_minimum_version 1.5.0

setup() {
    load '../helpers/test_helper'
    setup_test_env

    export APP="$BATS_TEST_TMPDIR/app"
    export HOME="$BATS_TEST_TMPDIR/home"
    export BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$APP/modules" "$APP/templates" "$APP/common" "$BIN" "$HOME"
    cp "$PROJECT_ROOT/remote-control/remote-control-essence.sh" "$APP/"
    cp "$PROJECT_ROOT/VERSION" "$APP/"
    cp "$PROJECT_ROOT/remote-control/modules/"*.sh "$APP/modules/"
    cp "$PROJECT_ROOT/remote-control/templates/"*.yaml "$APP/templates/"
    cp -R "$PROJECT_ROOT/common/." "$APP/common/"
    chmod +x "$APP/remote-control-essence.sh"
    # Сеть и SSH в тестах запрещены: заглушки идут первыми в PATH.
    local tool
    for tool in curl ssh scp ssh-keyscan gh; do
        printf '#!/bin/bash\nexit 1\n' > "$BIN/$tool"
        chmod +x "$BIN/$tool"
    done
    export PATH="$BIN:$PATH"
    export RC_DIR="$HOME/.config/remote-control-essence"
    unset RC_SCRIPT_PASSWORD RC_VAULT_PASSWORD
    # setup_test_env экспортирует пути модульных тестов; entrypoint вычисляет свои.
    unset CONFIG_DIR CONFIG_JSON TEMPLATES_DIR GENERATED_DIR SCRIPT_DIR
}

teardown() {
    [[ -z "${LOCK_HOLDER:-}" ]] || kill "$LOCK_HOLDER" 2>/dev/null || true
    [[ -z "${SERVE_PID:-}" ]] || kill "$SERVE_PID" 2>/dev/null || true
    teardown_test_env
}

rc() { "$APP/remote-control-essence.sh" "$@"; }

# stdout в JSON-режиме — ровно одна строка с валидным JSON.
assert_single_json() {
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
    jq -e . <<< "$output" >/dev/null
}

# Нода с входом по паролю прямо в config.json (без SSH).
add_password_node() {
    jq --arg n "$1" '.nodes += [{id:"44444444444444444444444444444444", name:$n, ip:"127.0.0.1",
        port:22, user:"root", auth:"password", identity:null,
        secret_id:"node:44444444444444444444444444444444:ssh-password", tag:"t", aliases:{}}]' \
        "$RC_DIR/config.json" > "$RC_DIR/config.json.tmp" && mv "$RC_DIR/config.json.tmp" "$RC_DIR/config.json"
}

# Запросы serve (по строке на аргумент) → $output (stdout), $stderr (журнал процесса).
serve() {
    run --separate-stderr bash -c 'printf "%s\n" "${@:2}" | "$1" serve' _ "$APP/remote-control-essence.sh" "$@"
}

# Строка stdout serve по jq-предикату → её номер (с 0); пусто, если нет.
serve_line_index() {
    printf '%s\n' "$output" | jq -s --argjson n 0 "map($1) | index(true)"
}

# ─── Разовый CLI ─────────────────────────────────────────────────────────────

@test 'help returns the command catalog as data and renders it as a table' {
    run --separate-stderr rc help
    assert_success
    assert_output --partial 'node add'
    assert_output --partial 'source init-local'
    run --separate-stderr rc help --json
    assert_success
    assert_single_json
    jq -e '.data.commands | any(.usage | startswith("group delete"))' <<< "$output" >/dev/null
    # Описание не делится по «|»: альтернативы остаются в usage, описание — целиком.
    jq -e '.data.commands | any(.usage == "… --json" and (.description | startswith("Ответ одним JSON-объектом")))' \
        <<< "$output" >/dev/null
    jq -e '.data.commands | any(.usage | startswith("node add") and contains("--auth key|password"))' \
        <<< "$output" >/dev/null
    jq -e '.data.commands | all(.description | test("^[А-ЯЁ0-9]"))' <<< "$output" >/dev/null
    run --separate-stderr rc group --help --json
    assert_success
    jq -e '.data.commands | length > 0 and all(.usage | startswith("group "))' <<< "$output" >/dev/null
}

@test 'unknown command and unknown secret are usage errors with exit 2' {
    run --separate-stderr rc foo --json
    [ "$status" -eq 2 ]
    assert_single_json
    [ "$(jq -r '.error.code' <<< "$output")" = usage ]

    rc source init-local --json >/dev/null 2>&1
    run --separate-stderr bash -c 'printf "%s" "{\"vault-password\":\"x\"}" | "$1" group list --secrets-stdin --json' _ "$APP/remote-control-essence.sh"
    [ "$status" -eq 2 ]
    [ "$(jq -r '.error.code' <<< "$output")" = usage ]
}

@test 'password-stdin is a transport flag allowed only for @password commands' {
    rc source init-local --json >/dev/null 2>&1
    run --separate-stderr bash -c 'printf "pw\n" | "$1" group list --password-stdin --json' _ "$APP/remote-control-essence.sh"
    [ "$status" -eq 2 ]
    [ "$(jq -r '.error.code' <<< "$output")" = usage ]
    run --separate-stderr bash -c 'printf "pw\n" | "$1" node password --name n --password-stdin --secrets-stdin --json' _ "$APP/remote-control-essence.sh"
    [ "$status" -eq 2 ]
    [ "$(jq -r '.error.code' <<< "$output")" = usage ]
    run --separate-stderr bash -c 'printf "{]" | "$1" node password --name n --secrets-stdin --json' _ "$APP/remote-control-essence.sh"
    [ "$status" -eq 2 ]
    [ "$(jq -r '.error.code' <<< "$output")" = usage ]
}

@test 'password from stdin and from --secrets-stdin is saved and never echoed' {
    rc source init-local --json >/dev/null 2>&1
    add_password_node pw-node
    run --separate-stderr bash -c 'printf "first-secret\n" | "$1" node password --name pw-node --password-stdin --json' _ "$APP/remote-control-essence.sh"
    assert_success
    [[ "$output$stderr" != *first-secret* ]]
    run --separate-stderr bash -c 'printf "%s" "{\"password\":\"second-secret\"}" | "$1" node password --name pw-node --secrets-stdin --json' _ "$APP/remote-control-essence.sh"
    assert_success
    [[ "$output$stderr" != *second-secret* ]]
    ! grep -rq second-secret "$RC_DIR" || return 1
    run --separate-stderr rc node list --json
    [ "$(jq -r '.data[0].password' <<< "$output")" = ok ]
}

@test 'commands before init report not_configured and create nothing' {
    run --separate-stderr rc node list --json
    [ "$status" -eq 1 ]
    assert_single_json
    [ "$(jq -r '.error.code' <<< "$output")" = not_configured ]
    [ ! -e "$RC_DIR/config.json" ]
}

@test 'session status works without a session and reports the source' {
    run --separate-stderr rc session status --json
    assert_success
    jq -e '.data == {configured:false, source:null, open:false, authorized:false}' <<< "$output" >/dev/null
    rc source init-local --json >/dev/null 2>&1
    run --separate-stderr rc session status --json
    jq -e '.data.configured and .data.source == "local"' <<< "$output" >/dev/null
}

@test 'source init-local creates config once, then conflicts' {
    run --separate-stderr rc source init-local --json
    assert_success
    assert_single_json
    [ "$(jq -r '.data.source' <<< "$output")" = local ]
    [ -f "$RC_DIR/config.json" ]
    run --separate-stderr rc source init-local --json
    [ "$status" -eq 1 ]
    [ "$(jq -r '.error.code' <<< "$output")" = conflict ]
    run --separate-stderr rc init local --json
    [ "$status" -eq 2 ]
    [ "$(jq -r '.error.code' <<< "$output")" = usage ]
}

@test 'group add uppercases the name and rejects duplicates' {
    rc source init-local --json >/dev/null 2>&1
    run --separate-stderr rc group add --name lab --json
    assert_success
    assert_single_json
    [ "$(jq -r '.data.name' <<< "$output")" = LAB ]
    run --separate-stderr rc group add --name lab --json
    [ "$status" -eq 1 ]
    [ "$(jq -r '.error.code' <<< "$output")" = conflict ]
}

@test 'human output renders a list as a table and a plan as a frame' {
    rc source init-local --json >/dev/null 2>&1
    rc group add --name lab --json >/dev/null 2>&1
    run rc group list
    assert_success
    assert_line --regexp '^  name +template +clients +nodes$'
    assert_line --regexp '^  LAB +default\.yaml +0 +—$'
    run rc group delete --name LAB
    [ "$status" -eq 2 ]
    assert_output --partial 'Требуется подтверждение'
    assert_output --partial 'Группа: LAB'
    assert_output --partial 'Повторите команду с --yes.'
    jq -e 'any(.groups[]; .name=="LAB")' "$RC_DIR/config.json" >/dev/null
}

@test 'dangerous delete needs --yes, never reads stdin and honours the plan token' {
    local token
    rc source init-local --json >/dev/null 2>&1
    rc group add --name lab --json >/dev/null 2>&1
    run --separate-stderr rc client add --name phone --group LAB --json
    assert_success

    run --separate-stderr rc client delete --name phone --json
    [ "$status" -eq 2 ]
    assert_single_json
    [ "$(jq -r '.error.code' <<< "$output")" = confirmation_required ]
    jq -e '.error.plan | length > 0' <<< "$output" >/dev/null
    token=$(jq -r '.error.plan_token' <<< "$output")
    [[ "$token" =~ ^[0-9a-f]{16}$ ]]
    [ -z "$stderr" ]
    jq -e 'any(.clients[]; .name=="phone")' "$RC_DIR/config.json" >/dev/null

    run --separate-stderr bash -c 'printf "y\n" | "$APP/remote-control-essence.sh" client delete --name phone --json'
    [ "$status" -eq 2 ]
    jq -e 'any(.clients[]; .name=="phone")' "$RC_DIR/config.json" >/dev/null

    run --separate-stderr rc client delete --name phone --yes --plan-token 0000000000000000 --json
    [ "$status" -eq 2 ]
    [ "$(jq -r '.error.code' <<< "$output")" = plan_changed ]
    [ "$(jq -r '.error.plan_token' <<< "$output")" = "$token" ]
    jq -e 'any(.clients[]; .name=="phone")' "$RC_DIR/config.json" >/dev/null

    run --separate-stderr rc client delete --name phone --plan-token "$token" --json
    [ "$status" -eq 2 ]
    [ "$(jq -r '.error.code' <<< "$output")" = usage ]

    run --separate-stderr rc client delete --name phone --yes --plan-token "$token" --json
    assert_success
    [ "$(jq -r '.data.deleted[0]' <<< "$output")" = phone ]
    run jq -e 'any(.clients[]; .name=="phone")' "$RC_DIR/config.json"
    assert_failure
}

@test 'script password comes only from RC_SCRIPT_PASSWORD without a TTY' {
    rc source init-local --json >/dev/null 2>&1
    openssl passwd -6 -salt fixture secret > "$RC_DIR/.auth"

    run --separate-stderr rc status --json < /dev/null
    [ "$status" -eq 2 ]
    [ "$(jq -r '.error.code' <<< "$output")" = auth_required ]

    RC_SCRIPT_PASSWORD=wrong run --separate-stderr rc status --json < /dev/null
    [ "$status" -eq 1 ]
    [ "$(jq -r '.error.code' <<< "$output")" = auth_failed ]

    RC_SCRIPT_PASSWORD=secret run --separate-stderr rc status --json < /dev/null
    assert_success
    [ "$(jq -r '.ok' <<< "$output")" = true ]

    RC_SCRIPT_PASSWORD=secret run --separate-stderr rc session open --json < /dev/null
    assert_success
    jq -e '.data == {source:"local", repo:null, sync:null}' <<< "$output" >/dev/null
}

@test 'password environment variables are not inherited by child processes' {
    rc source init-local --json >/dev/null 2>&1
    openssl passwd -6 -salt fixture secret > "$RC_DIR/.auth"
    local real_jq
    real_jq=$(command -v jq)
    printf '#!/bin/bash\nenv >> "%s"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR/child-env" "$real_jq" > "$BIN/jq"
    chmod +x "$BIN/jq"
    RC_SCRIPT_PASSWORD=secret RC_VAULT_PASSWORD=vault-secret-value \
        run --separate-stderr rc status --json < /dev/null
    assert_success
    [ "$(jq -r '.ok' <<< "$output")" = true ]
    [ -s "$BATS_TEST_TMPDIR/child-env" ]
    run grep -cE 'RC_SCRIPT_PASSWORD|RC_VAULT_PASSWORD|vault-secret-value' "$BATS_TEST_TMPDIR/child-env"
    [ "$output" = 0 ]
}

@test 'core exit through error() still prints exactly one JSON document' {
    rc source init-local --json >/dev/null 2>&1
    cat >> "$APP/modules/cmd_core.sh" <<'EOF'
cli_cmd_status() { error "сбой ядра"; }
EOF
    run --separate-stderr rc status --json
    [ "$status" -eq 1 ]
    assert_single_json
    jq -e '.ok == false and .error.code == "failed"' <<< "$output" >/dev/null
}

@test 'live mutation lock makes a mutation fail with locked and the owner pid' {
    rc source init-local --json >/dev/null 2>&1
    sleep 60 &
    LOCK_HOLDER=$!
    mkdir "$RC_DIR/.rc-lock"
    printf 'pid=%s\nkind=mutation\nlabel=test\nstarted=x\n' "$LOCK_HOLDER" > "$RC_DIR/.rc-lock/owner"

    RC_LOCK_WAIT=1 run --separate-stderr rc group add --name lab --json
    [ "$status" -eq 1 ]
    [ "$(jq -r '.error.code' <<< "$output")" = locked ]
    [[ "$(jq -r '.error.message' <<< "$output")" == *"$LOCK_HOLDER"* ]]
    run jq -e 'any(.groups[]; .name=="LAB")' "$RC_DIR/config.json"
    assert_failure
}

@test 'stale lock of a dead process is taken over and released' {
    rc source init-local --json >/dev/null 2>&1
    sleep 0 &
    local dead=$!
    wait "$dead"
    mkdir "$RC_DIR/.rc-lock"
    printf 'pid=%s\nkind=mutation\nlabel=test\nstarted=x\n' "$dead" > "$RC_DIR/.rc-lock/owner"

    run --separate-stderr rc group add --name lab --json
    assert_success
    [ ! -e "$RC_DIR/.rc-lock" ]
}

@test 'no arguments start the TUI over serve and leave no serve process' {
    cp -R "$PROJECT_ROOT/remote-control/tui" "$APP/"
    rc source init-local --json >/dev/null 2>&1
    run bash -c 'printf "0\n" | "$APP/remote-control-essence.sh"'
    assert_success
    assert_output --partial 'Remote Control v'
    ! pgrep -f "$APP/remote-control-essence.sh serve" >/dev/null || return 1
    [ ! -e "$RC_DIR/.rc-lock" ]
}

# ─── serve ───────────────────────────────────────────────────────────────────

@test 'serve: hello, session gate, events before the response, plan token' {
    local token
    serve '{"id":1,"argv":["group","list"]}' \
        '{"id":2,"argv":["source","init-local"]}' \
        '{"id":3,"argv":["group","add","--name","lab"]}' \
        '{"id":4,"argv":["group","delete","--name","LAB"]}'
    assert_success
    printf '%s\n' "$output" | jq -e . >/dev/null
    printf '%s\n' "$output" | head -n 1 | jq -e '.event == "hello" and .protocol == 1 and (.version | length > 0)' >/dev/null
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 1 and .ok == false and .error.code == "session_closed")' >/dev/null
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 2 and .ok == true)' >/dev/null
    local event response
    event=$(serve_line_index '.id == 3 and .event == "log" and .level == "success"')
    response=$(serve_line_index '.id == 3 and has("ok")')
    [[ "$event" =~ ^[0-9]+$ && "$response" =~ ^[0-9]+$ ]]
    (( event < response ))
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 3 and .ok == true and .data.name == "LAB")' >/dev/null
    token=$(printf '%s\n' "$output" | jq -sr '.[] | select(.id == 4 and has("ok")) | .error.plan_token')
    [[ "$token" =~ ^[0-9a-f]{16}$ ]]
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 4 and .error.code == "confirmation_required")' >/dev/null
    # Решения не печатаются журналом serve: интерфейс показывает их сам.
    ! printf '%s\n' "$output" | jq -se 'any(.[]; .id == 4 and .event == "log")' >/dev/null || return 1

    serve '{"id":"a","argv":["session","open"]}' \
        '{"id":"b","argv":["group","delete","--name","LAB","--yes","--plan-token","0000000000000000"]}'
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == "b" and .error.code == "plan_changed")' >/dev/null
    jq -e 'any(.groups[]; .name=="LAB")' "$RC_DIR/config.json" >/dev/null

    serve '{"id":"a","argv":["session","open"]}' \
        "{\"id\":\"c\",\"argv\":[\"group\",\"delete\",\"--name\",\"LAB\",\"--yes\",\"--plan-token\",\"$token\"]}"
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == "c" and .ok == true)' >/dev/null
    run jq -e 'any(.groups[]; .name=="LAB")' "$RC_DIR/config.json"
    assert_failure
}

@test 'serve: secrets travel only in the secrets field and never leak' {
    rc source init-local --json >/dev/null 2>&1
    add_password_node pw-node
    serve '{"id":1,"argv":["session","open"]}' \
        '{"argv":["node","password","--name","pw-node"],"secrets":{"password":"secret-zz"}}' \
        '{"id":3,"argv":["node","password","--name","pw-node","--password-stdin"]}' \
        '{"id":4,"argv":["group","list"],"secrets":{"password":"secret-zz"}}'
    assert_success
    [[ "$output$stderr" != *secret-zz* ]]
    ! grep -rq secret-zz "$RC_DIR" || return 1
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == null and .ok == true and .data.name == "pw-node")' >/dev/null
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 3 and .error.code == "usage")' >/dev/null
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 4 and .error.code == "usage")' >/dev/null
}

@test 'serve: malformed requests get usage with a null id' {
    serve 'not json' '{"id":{},"argv":["help"]}' '{"id":5,"argv":"help"}' '{"id":6,"argv":["help"],"secrets":{"a":1}}'
    assert_success
    printf '%s\n' "$output" | jq -se '[.[] | select(has("ok"))] | length == 4' >/dev/null
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == null and .error.code == "usage" and .error.message == "Неверный запрос.")' >/dev/null
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 5 and .error.code == "usage")' >/dev/null
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 6 and .error.code == "usage")' >/dev/null
}

@test 'serve: log events carry no terminal control characters' {
    rc source init-local --json >/dev/null 2>&1
    # \e и \a текстом превращает в байты echo -e журнала; \u001b — сырой ESC в argv.
    serve '{"id":1,"argv":["session","open"]}' \
        '{"id":2,"argv":["node","show","--name","\\e]52;c;cHduZWQ=\\a"]}' \
        '{"id":3,"argv":["node","show","--name","x\u001b[2Jy\u009bz"]}'
    assert_success
    printf '%s\n' "$output" | jq -se '[.[] | select(.event == "log" and (.id == 2 or .id == 3))] | length == 2' >/dev/null
    printf '%s\n' "$output" | jq -se '[.[] | select(.event == "log") | .text
        | test("[\u0001-\u0008\u000b-\u001f\u007f-\u009f]")] | any | not' >/dev/null
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 3 and .event == "log" and (.text | contains("x[2Jyz")))' >/dev/null
}

@test 'serve: EOF exits 0 and releases the session lock' {
    serve '{"id":1,"argv":["source","init-local"]}' '{"id":2,"argv":["status"]}'
    assert_success
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 2 and .ok == true)' >/dev/null
    [ ! -e "$RC_DIR/.rc-lock" ]
}

@test 'serve: SIGINT during a command does not interrupt it' {
    rc source init-local --json >/dev/null 2>&1
    jq '.nodes += [{id:"55555555555555555555555555555555", name:"slow", ip:"127.0.0.1", port:22,
        user:"root", auth:"key", identity:"system", secret_id:null, tag:"t", aliases:{}}]' \
        "$RC_DIR/config.json" > "$RC_DIR/config.json.tmp" && mv "$RC_DIR/config.json.tmp" "$RC_DIR/config.json"
    local started="$BATS_TEST_TMPDIR/ssh.started" completed="$BATS_TEST_TMPDIR/ssh.completed" waited=0
    printf '#!/bin/bash\n: > "%s"\nsleep 1\n: > "%s"\nprintf "ok\\n"\n' "$started" "$completed" > "$BIN/ssh"
    local fifo="$BATS_TEST_TMPDIR/serve.in" out="$BATS_TEST_TMPDIR/serve.out"
    mkfifo "$fifo"
    "$APP/remote-control-essence.sh" serve < "$fifo" > "$out" 2>/dev/null &
    SERVE_PID=$!
    exec 4> "$fifo"
    printf '%s\n' '{"id":1,"argv":["session","open"]}' '{"id":2,"argv":["node","check","--name","slow"]}' >&4
    # INT только когда команда уже запущена (ssh-заглушка оставила маркер).
    while [[ ! -e "$started" && $waited -lt 100 ]]; do sleep 0.1; waited=$((waited + 1)); done
    [ -e "$started" ]
    kill -INT "$SERVE_PID"
    exec 4>&-
    wait "$SERVE_PID"
    local rc=$?
    SERVE_PID=""
    [ "$rc" -eq 0 ]
    [ -e "$completed" ]
    jq -se 'any(.[]; .id == 2 and .ok == true and .data.reachable == true)' "$out" >/dev/null
}

# ─── round 2: dispatch ───────────────────────────────────────────────────────

# Ждать в файле ответа serve с данным id (до 10 с).
_wait_reply() {
    local out="$1" id="$2" waited=0
    while ! jq -se --argjson id "$id" 'any(.[]; .id == $id and has("ok"))' "$out" >/dev/null 2>&1; do
        (( waited < 100 )) || return 1
        sleep 0.1
        waited=$((waited + 1))
    done
}

@test 'serve: a log channel removed while idle is recreated, never replaying the previous reply' {
    rc source init-local --json >/dev/null 2>&1
    local tmp="$BATS_TEST_TMPDIR/serve-tmp" fifo="$BATS_TEST_TMPDIR/serve.in" out="$BATS_TEST_TMPDIR/serve.out"
    mkdir -p "$tmp"
    mkfifo "$fifo"
    TMPDIR="$tmp" "$APP/remote-control-essence.sh" serve < "$fifo" > "$out" 2>/dev/null &
    SERVE_PID=$!
    exec 4> "$fifo"
    printf '%s\n' '{"id":1,"argv":["session","open"]}' '{"id":2,"argv":["group","add","--name","FIRST"]}' >&4
    _wait_reply "$out" 2
    # Очистка /tmp во время простоя интерфейса.
    rm -rf "${tmp:?}"/*
    printf '%s\n' '{"id":3,"argv":["group","add","--name","SECOND"]}' '{"id":4,"argv":["group","list"]}' >&4
    exec 4>&-
    wait "$SERVE_PID"
    SERVE_PID=""
    jq -se 'any(.[]; .id == 3 and .ok == true and .data.name == "SECOND")' "$out" >/dev/null
    jq -se 'any(.[]; .id == 4 and .ok == true and (.data | type) == "array")' "$out" >/dev/null
    jq -e 'any(.groups[]; .name == "SECOND")' "$RC_DIR/config.json" >/dev/null
}

@test 'malformed RC_LOCK_WAIT falls back to the default wait instead of crashing' {
    rc source init-local --json >/dev/null 2>&1
    RC_LOCK_WAIT=5s run --separate-stderr rc group add --name lab --json
    assert_success
    [ "$(jq -r '.data.name' <<< "$output")" = LAB ]
    RC_LOCK_WAIT='1+' serve '{"id":1,"argv":["session","open"]}' '{"id":2,"argv":["group","list"]}'
    assert_success
    printf '%s\n' "$output" | jq -se 'any(.[]; .id == 1 and .ok == true) and any(.[]; .id == 2 and .ok == true)' >/dev/null
}

@test 'a flag value of -h or --help is a value, not a help request' {
    rc source init-local --json >/dev/null 2>&1
    run --separate-stderr rc node show --name -h --json
    [ "$status" -eq 1 ]
    [ "$(jq -r '.error.code' <<< "$output")" = not_found ]
    run --separate-stderr rc node show --name --help --json
    [ "$status" -eq 1 ]
    [ "$(jq -r '.error.code' <<< "$output")" = not_found ]
    run --separate-stderr rc group add --help --json
    assert_success
    jq -e '.data.commands | length > 0' <<< "$output" >/dev/null
    run --separate-stderr rc node show --name x -h --json
    assert_success
    jq -e '.data.commands | length > 0' <<< "$output" >/dev/null
}

@test 'serve log pump drops NUL and other control characters but keeps tabs' {
    run bash -c 'source "$1/modules/serve.sh"; printf "a\0b\033[2Jc\td\302\233e\n" | _serve_pump 7 3>&1' _ "$APP"
    assert_success
    [ "$(jq -r '.text' <<< "$output")" = $'ab[2Jc\tde' ]
    [ "$(jq -r '.id' <<< "$output")" = 7 ]
}

@test 'serve timeout wrapper preserves external exit status and deadline status' {
    run bash -c 'source "$1/common/common.sh"; run_with_timeout 5 --ignore-int bash -c "exit 37"' _ "$APP"
    [ "$status" -eq 37 ]
    command -v timeout >/dev/null 2>&1 || skip "GNU timeout не установлен"
    [[ "$(timeout --help)" == *--foreground* ]] || skip "Нужен GNU timeout"
    run bash -c 'source "$1/common/common.sh"; run_with_timeout 1 --ignore-int bash -c '"'"'sleep 5; touch "$1"'"'"' _ "$2"' \
        _ "$APP" "$BATS_TEST_TMPDIR/late-completion"
    [ "$status" -eq 124 ]
    [ ! -e "$BATS_TEST_TMPDIR/late-completion" ]
}
