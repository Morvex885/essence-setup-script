#!/usr/bin/env bats
# Fuzz разбора argv CLI: любой argv с --json даёт exit 0/1/2, ровно один
# JSON-объект с булевым .ok в stdout и не портит config.json; отказ до
# изменений (confirmation_required, plan_changed, usage, *_required, not_found)
# не меняет config.json. Зерно печатается (FUZZ_SEED воспроизводит прогон).
bats_require_minimum_version 1.5.0

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    setup_test_env
    unset CONFIG_DIR CONFIG_JSON TEMPLATES_DIR GENERATED_DIR SCRIPT_DIR
    unset RC_SCRIPT_PASSWORD RC_VAULT_PASSWORD

    export APP="$BATS_TEST_TMPDIR/app"
    export HOME="$BATS_TEST_TMPDIR/home"
    local bin="$BATS_TEST_TMPDIR/bin" tool
    mkdir -p "$APP/modules" "$APP/templates" "$APP/common" "$bin" "$HOME" "$BATS_TEST_TMPDIR/work"
    cp "$PROJECT_ROOT/remote-control/remote-control-essence.sh" "$PROJECT_ROOT/VERSION" "$APP/"
    cp "$PROJECT_ROOT/remote-control/modules/"*.sh "$APP/modules/"
    cp "$PROJECT_ROOT/remote-control/templates/"*.yaml "$APP/templates/"
    cp -R "$PROJECT_ROOT/common/." "$APP/common/"
    chmod +x "$APP/remote-control-essence.sh"
    # Сеть и SSH недоступны: команды, которым они нужны, обязаны корректно упасть.
    for tool in curl ssh scp ssh-keyscan gh git; do
        printf '#!/bin/bash\nexit 2\n' > "$bin/$tool"
        chmod +x "$bin/$tool"
    done
    export PATH="$bin:$PATH"
    export RC_DIR="$HOME/.config/remote-control-essence"
    "$APP/remote-control-essence.sh" source init-local --json >/dev/null 2>&1
}

teardown() { teardown_test_env; }

NOUNS=(source session status node group template client conn generate sub awg telegram help bogus "")
VERBS=(list show add delete rename tag aliases check password upload-scripts set-template
    export import connections nodes set-group set host publish publish-all rotate revoke
    migrate headers status sync remove install remove-all init-local open local "" bogus)
FLAGS=(--name --new-name --group --node --tag --ip --port --user --auth --template --file
    --client --ttl --proxy --peer --component --scope --set --unset --host-key
    --yes --plan-token --all --force --inherit --reset --default --orphans --discover --revoke-key
    --accept-new-host-key --defer-ssh-setup --remember-key --password-stdin --secrets-stdin
    --help --bogus -x --)

_fuzz_value() {
    case $((RANDOM % 5)) in
        0) random_ascii "$(random_int 1 12)" ;;
        1) random_pick "${DICT_SHELL_INJECTION[@]}" ;;
        2) random_pick "${DICT_FORMAT_STRINGS[@]}" ;;
        3) random_pick "${DICT_PATH_TRAVERSAL[@]}" ;;
        4) random_pick "${DICT_UTF8_EDGE[@]}" ;;
    esac
}

@test 'random argv with --json keeps the output and exit-code contract' {
    local i n args flag lines seed before after code
    seed="${FUZZ_SEED:-$((RANDOM * 32768 + RANDOM))}"
    RANDOM=$seed
    echo "fuzz seed=$seed (FUZZ_SEED=$seed воспроизводит прогон)"
    cd "$BATS_TEST_TMPDIR/work"
    for ((i = 0; i < ${FUZZ_ITERATIONS:-100}; i++)); do
        args=("$(random_pick "${NOUNS[@]}")" "$(random_pick "${VERBS[@]}")")
        n=$(random_int 0 4)
        while ((n-- > 0)); do
            flag=$(random_pick "${FLAGS[@]}")
            case $((RANDOM % 3)) in
                0) args+=("$flag") ;;
                1) args+=("$flag" "$(_fuzz_value)") ;;
                2) args+=("$flag=$(_fuzz_value)") ;;
            esac
        done
        args+=(--json)
        before=$(cksum < "$RC_DIR/config.json")
        run --separate-stderr "$APP/remote-control-essence.sh" "${args[@]}" < /dev/null
        if [[ "$status" -ne 0 && "$status" -ne 1 && "$status" -ne 2 ]]; then
            echo "exit=$status argv: ${args[*]}"
            echo "$stderr"
            return 1
        fi
        lines=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
        if [[ "$lines" -ne 1 ]] || ! jq -e '.ok | type == "boolean"' <<< "$output" >/dev/null 2>&1; then
            echo "bad stdout for argv: ${args[*]}"
            echo "$output"
            return 1
        fi
        jq -e . "$RC_DIR/config.json" >/dev/null || { echo "config broken by: ${args[*]}"; return 1; }
        code=$(jq -r '.error.code // ""' <<< "$output")
        case "$code" in
            confirmation_required|plan_changed|usage|not_found|*_required)
                after=$(cksum < "$RC_DIR/config.json")
                if [[ "$after" != "$before" ]]; then
                    echo "config changed by a refused command ($code): ${args[*]}"
                    return 1
                fi
                ;;
        esac
    done
}

@test 'gated commands without --yes never change config.json' {
    local before after cmd
    local -a gated=("group delete --name PC" "client delete --name nobody" "node delete --name nobody"
        "sub revoke --client nobody")
    before=$(cksum < "$RC_DIR/config.json")
    for cmd in "${gated[@]}"; do
        # shellcheck disable=SC2086
        run --separate-stderr "$APP/remote-control-essence.sh" $cmd --json < /dev/null
        [ "$status" -ne 0 ]
        after=$(cksum < "$RC_DIR/config.json")
        [ "$after" = "$before" ]
    done
    run --separate-stderr "$APP/remote-control-essence.sh" group delete --name PC --json < /dev/null
    [ "$status" -eq 2 ]
    [ "$(jq -r '.error.code' <<< "$output")" = confirmation_required ]
    jq -e 'any(.groups[]; .name == "PC")' "$RC_DIR/config.json" >/dev/null
}
