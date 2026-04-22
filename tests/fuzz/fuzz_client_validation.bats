#!/usr/bin/env bats
# Fuzz tests for client name validation: ^[a-zA-Z0-9._-]+$ (excluding dot-only)

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-100}"

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    setup_test_env
    source_common
    source_module "clients.sh"
}

teardown() {
    teardown_test_env
}

matches() {
    _validate_client_name "$1"
}

@test "fuzz client validation: random valid names always match" {
    local charset="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local len=$(random_int 1 50)
        local name
        name=$(random_string "$len" "$charset")
        # Ensure it's not dot-only (regenerate if so)
        while [[ "$name" =~ ^\.+$ ]]; do
            name=$(random_string "$len" "$charset")
        done
        run matches "$name"
        assert_success
    done
}

@test "fuzz client validation: strings with invalid chars always rejected" {
    local invalid_chars=(' ' ';' '|' '&' '$' "'" '"' '/' '\' '(' ')' '{' '}' '[' ']' '!' '@' '#' '%' '^' '*' '+' '=' '<' '>' '?' ',')
    local valid_charset="abcdefghijklmnopqrstuvwxyz0123456789"
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local len=$(random_int 2 20)
        local name
        name=$(random_string "$len" "$valid_charset")
        local invalid_char
        invalid_char=$(random_pick invalid_chars)
        local pos=$((RANDOM % ${#name}))
        name="${name:0:$pos}${invalid_char}${name:$pos}"
        run matches "$name"
        assert_failure
    done
}

@test "fuzz client validation: deterministic — same input same result" {
    local charset="abcdefghijklmnopqrstuvwxyz0123456789._- ;/|"
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local len=$(random_int 1 30)
        local name
        name=$(random_string "$len" "$charset")
        local result1 result2
        matches "$name" && result1=0 || result1=1
        matches "$name" && result2=0 || result2=1
        [[ "$result1" == "$result2" ]] || {
            echo "FAIL: non-deterministic for '$name': $result1 vs $result2"
            return 1
        }
    done
}

@test "fuzz client validation: dot-only names always rejected" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local len=$(random_int 1 20)
        local name=""
        for ((j = 0; j < len; j++)); do
            name+="."
        done
        run matches "$name"
        assert_failure
    done
}

@test "fuzz client validation: unicode/non-ASCII always rejected" {
    local cyrillic="абвгдежзиклмнопрстуфхцчшщэюя"
    local cjk="漢字中国人大学生日本語"
    local accented="àáâãäåèéêëìíîïòóôõöùúûüýÿñ"
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local name=""
        local pool=$((RANDOM % 3))
        local len=$(random_int 1 15)
        local charset
        case $pool in
            0) charset="$cyrillic" ;;
            1) charset="$cjk" ;;
            2) charset="$accented" ;;
        esac
        name=$(random_string "$len" "$charset")
        run matches "$name"
        assert_failure
    done
}

@test "fuzz client validation: dots mixed with other chars still valid" {
    local alphanum="abcdefghijklmnopqrstuvwxyz0123456789"
    local dotchars="._-"
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local len=$(random_int 2 20)
        local name=""
        # Guarantee at least one alphanum character
        name+="${alphanum:$((RANDOM % ${#alphanum})):1}"
        for ((j = 1; j < len; j++)); do
            if (( RANDOM % 3 == 0 )); then
                name+="${dotchars:$((RANDOM % ${#dotchars})):1}"
            else
                name+="${alphanum:$((RANDOM % ${#alphanum})):1}"
            fi
        done
        run matches "$name"
        assert_success
    done
}

@test "fuzz client validation: shell injection never passes" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local name
        local strategy=$((RANDOM % 3))
        case $strategy in
            0) # Pure injection payload
                name=$(random_pick DICT_SHELL_INJECTION)
                ;;
            1) # Valid name + injected shell token
                name=$(random_ascii $((RANDOM % 10 + 1)))
                name=$(mutate_inject "$name" DICT_SHELL_INJECTION)
                ;;
            2) # Multiple injections
                name=$(random_ascii $((RANDOM % 5 + 1)))
                name=$(mutate_inject "$name" DICT_SHELL_INJECTION)
                name=$(mutate_inject "$name" DICT_SHELL_INJECTION)
                ;;
        esac
        # Empty string is inherently rejected by the regex; non-empty with bad chars too
        [[ -z "$name" ]] && continue
        run matches "$name"
        assert_failure
    done
}

@test "fuzz client validation: path traversal — pure payloads rejected" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local name
        name=$(random_pick DICT_PATH_TRAVERSAL)
        [[ -z "$name" ]] && continue
        run matches "$name"
        assert_failure
    done
}

@test "fuzz client validation: path traversal — mutated names safe" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local name
        local strategy=$((RANDOM % 3))
        case $strategy in
            0) # Valid name + traversal token injected
                name=$(random_ascii $((RANDOM % 10 + 1)))
                name=$(mutate_inject "$name" DICT_PATH_TRAVERSAL)
                ;;
            1) # Multiple traversal injections
                name=$(random_ascii $((RANDOM % 5 + 1)))
                name=$(mutate_inject "$name" DICT_PATH_TRAVERSAL)
                name=$(mutate_inject "$name" DICT_PATH_TRAVERSAL)
                ;;
            2) # Traversal token + random suffix
                name="$(random_pick DICT_PATH_TRAVERSAL)$(random_ascii $((RANDOM % 10 + 1)))"
                ;;
        esac
        [[ -z "$name" ]] && continue
        # Oracle: if validation passes, the name must not be a dangerous path
        run matches "$name"
        if [[ "$status" -eq 0 ]]; then
            [[ "$name" != "." && "$name" != ".." && ! "$name" =~ ^\.+$ ]] || {
                echo "FAIL iteration $i: dangerous path '$name' passed validation"
                return 1
            }
        fi
    done
}
