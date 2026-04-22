#!/usr/bin/env bats
# Fuzz tests for process_template() — random templates with group markers

FUZZ_ITERATIONS="${FUZZ_ITERATIONS:-50}"

setup() {
    load '../helpers/test_helper'
    load '../helpers/fuzz_helper'
    setup_test_env
    source_common
    source_module "templates.sh"
}

teardown() {
    teardown_test_env
}

# Generate a random template with some group markers and some plain lines
random_template() {
    local lines=$((RANDOM % 20 + 5))
    local groups=("ROUTER" "PC" "MOBILE" "TEST")
    local content=""
    local in_block=""

    for ((i = 0; i < lines; i++)); do
        local dice=$((RANDOM % 10))
        if [[ $dice -lt 2 ]]; then
            local g="${groups[$((RANDOM % ${#groups[@]}))]}"
            if [[ -n "$in_block" && "$in_block" == "$g" ]]; then
                content+="# --- $g ---"$'\n'
                in_block=""
            elif [[ -z "$in_block" ]]; then
                content+="# --- $g ---"$'\n'
                in_block="$g"
            else
                content+="plain line $i"$'\n'
            fi
        else
            content+="plain line $i"$'\n'
        fi
    done
    echo "$content"
}

@test "fuzz process_template: never crashes on random templates" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local tmpfile="$BATS_TEST_TMPDIR/fuzz_${i}.yaml"
        random_template > "$tmpfile"
        local target_groups=("ROUTER" "PC" "MOBILE" "TEST" "NONEXISTENT")
        local target="${target_groups[$((RANDOM % ${#target_groups[@]}))]}"
        run process_template "$tmpfile" "$target"
        assert_success
    done
}

@test "fuzz process_template: matching block content included, non-matching excluded" {
    local all_groups=("ROUTER" "PC" "MOBILE" "TEST" "ALPHA" "BETA")
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local tmpfile="$BATS_TEST_TMPDIR/match_${i}.yaml"
        # Pick two distinct random groups
        local g1="${all_groups[$((RANDOM % ${#all_groups[@]}))]}"
        local g2="${all_groups[$((RANDOM % ${#all_groups[@]}))]}"
        while [[ "$g2" == "$g1" ]]; do
            g2="${all_groups[$((RANDOM % ${#all_groups[@]}))]}"
        done
        # Generate unique markers for each group block
        local marker1="CONTENT_${RANDOM}_${RANDOM}_G1"
        local marker2="CONTENT_${RANDOM}_${RANDOM}_G2"
        local plain_marker="PLAIN_${RANDOM}_${RANDOM}"
        cat > "$tmpfile" <<EOF
$plain_marker
# --- $g1 ---
$marker1
# --- $g1 ---
# --- $g2 ---
$marker2
# --- $g2 ---
EOF
        # Test for g1: marker1 included, marker2 excluded, plain included
        local output
        output=$(process_template "$tmpfile" "$g1")
        if ! echo "$output" | grep -qF "$marker1"; then
            echo "FAIL iteration $i: marker1 '$marker1' missing for group '$g1'"
            return 1
        fi
        if echo "$output" | grep -qF "$marker2"; then
            echo "FAIL iteration $i: marker2 '$marker2' should not appear for group '$g1'"
            return 1
        fi
        if ! echo "$output" | grep -qF "$plain_marker"; then
            echo "FAIL iteration $i: plain marker '$plain_marker' missing"
            return 1
        fi
        # Group markers themselves must be stripped
        if echo "$output" | grep -qF "# --- $g1 ---"; then
            echo "FAIL iteration $i: group markers should be stripped"
            return 1
        fi
    done
}

@test "fuzz process_template: plain lines outside blocks preserved verbatim" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local tmpfile="$BATS_TEST_TMPDIR/plain_${i}.yaml"
        local line_count=$(random_int 1 10)
        local lines=()
        for ((j = 0; j < line_count; j++)); do
            lines+=("plain_${RANDOM}_content_${RANDOM}_line_${j}")
        done
        printf '%s\n' "${lines[@]}" > "$tmpfile"
        local output
        output=$(process_template "$tmpfile" "PC")
        for line in "${lines[@]}"; do
            echo "$output" | grep -qF "$line" || {
                echo "FAIL iteration $i: line '$line' missing from output"
                return 1
            }
        done
    done
}

@test "fuzz process_template: unclosed blocks — no crash" {
    local all_groups=("ROUTER" "PC" "MOBILE" "TEST" "ALPHA")
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local tmpfile="$BATS_TEST_TMPDIR/unclosed_${i}.yaml"
        local group="${all_groups[$((RANDOM % ${#all_groups[@]}))]}"
        local line_count=$(random_int 0 10)
        {
            echo "before_${RANDOM}"
            echo "# --- $group ---"
            for ((j = 0; j < line_count; j++)); do
                echo "inside_${RANDOM}_line_${j}"
            done
            # No closing marker
        } > "$tmpfile"
        local target="${all_groups[$((RANDOM % ${#all_groups[@]}))]}"
        run process_template "$tmpfile" "$target"
        assert_success
    done
}

@test "fuzz process_template: injection in plain lines passes through unchanged" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local tmpfile="$BATS_TEST_TMPDIR/inject_${i}.yaml"
        local prefix
        prefix=$(random_ascii $((RANDOM % 10 + 3)))
        local injection
        injection=$(random_pick DICT_SHELL_INJECTION)
        local suffix
        suffix=$(random_ascii $((RANDOM % 10 + 3)))
        local line="${prefix}${injection}${suffix}"
        # Skip lines that accidentally match the group marker regex
        if [[ "$line" =~ ^#\ ---\ [A-Z0-9/_]+\ ---$ ]]; then
            continue
        fi
        echo "$line" > "$tmpfile"
        local output
        output=$(process_template "$tmpfile" "PC")
        [[ "$output" == "$line" ]] || {
            echo "FAIL iteration $i: line was modified"
            echo "  input='$(printf '%s' "$line" | xxd -p | head -c 80)'"
            echo "  output='$(printf '%s' "$output" | xxd -p | head -c 80)'"
            return 1
        }
    done
}

@test "fuzz process_template: output never exceeds input lines" {
    for ((i = 0; i < FUZZ_ITERATIONS; i++)); do
        local tmpfile="$BATS_TEST_TMPDIR/fuzz_count_${i}.yaml"
        random_template > "$tmpfile"
        local input_lines output_lines
        input_lines=$(grep -c '' "$tmpfile" || echo 0)
        local output
        output=$(process_template "$tmpfile" "PC")
        if [[ -z "$output" ]]; then
            output_lines=0
        else
            output_lines=$(printf '%s\n' "$output" | grep -c '')
        fi
        [[ "$output_lines" -le "$input_lines" ]] || {
            echo "FAIL iteration $i: input=$input_lines output=$output_lines"
            return 1
        }
    done
}
