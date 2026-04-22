#!/usr/bin/env bats
# Tests for process_template() — template group block filtering

setup() {
    load '../helpers/test_helper'
    setup_test_env
    source_common
    source_module "templates.sh"
}

teardown() {
    teardown_test_env
}

# Helper: write content to temp template file and process it
process() {
    local content="$1" target="$2"
    local tmpfile="$BATS_TEST_TMPDIR/test_template.yaml"
    printf '%s\n' "$content" > "$tmpfile"
    process_template "$tmpfile" "$target"
}

@test "process_template: no markers — pass-through" {
    run process "line1
line2
line3" "PC"
    assert_success
    assert_output "line1
line2
line3"
}

@test "process_template: matching block — content kept, markers removed" {
    run process "before
# --- PC ---
kept line
# --- PC ---
after" "PC"
    assert_success
    assert_output "before
kept line
after"
}

@test "process_template: non-matching block — block removed" {
    run process "before
# --- MOBILE ---
hidden line
# --- MOBILE ---
after" "PC"
    assert_success
    assert_output "before
after"
}

@test "process_template: multi-group match" {
    run process "# --- ROUTER/PC ---
kept
# --- ROUTER/PC ---" "PC"
    assert_success
    assert_output "kept"
}

@test "process_template: multi-group no match" {
    run process "before
# --- ROUTER/PC ---
hidden
# --- ROUTER/PC ---
after" "MOBILE"
    assert_success
    assert_output "before
after"
}

@test "process_template: multiple blocks — mix of match/no-match" {
    run process "header
# --- PC ---
pc content
# --- PC ---
middle
# --- MOBILE ---
mobile content
# --- MOBILE ---
footer" "PC"
    assert_success
    assert_output "header
pc content
middle
footer"
}

@test "process_template: adjacent blocks" {
    run process "# --- ROUTER ---
router line
# --- ROUTER ---
# --- PC ---
pc line
# --- PC ---" "ROUTER"
    assert_success
    assert_output "router line"
}

@test "process_template: unmatched opening tag (matching) — content leaks" {
    run process "# --- PC ---
leaked content" "PC"
    assert_success
    assert_output "leaked content"
}

@test "process_template: unmatched opening tag (non-matching) — content suppressed" {
    run process "# --- MOBILE ---
hidden content" "PC"
    assert_success
    assert_output ""
}

@test "process_template: lowercase marker NOT treated as group tag" {
    run process "# --- lowercase ---
visible" "lowercase"
    assert_success
    assert_output "# --- lowercase ---
visible"
}

@test "process_template: indented marker NOT treated as group tag" {
    run process "  # --- PC ---
visible" "PC"
    assert_success
    assert_output "  # --- PC ---
visible"
}

@test "process_template: real fixture template for ROUTER" {
    load_fixture_template
    run process_template "$TEMPLATES_DIR/default.yaml" "ROUTER"
    assert_success
    assert_line "redir-port: 7892"
    assert_line "tproxy-port: 7893"
    # tun block (PC/MOBILE only) should be excluded
    refute_line "  stack: system"
}

@test "process_template: real fixture template for PC" {
    load_fixture_template
    run process_template "$TEMPLATES_DIR/default.yaml" "PC"
    assert_success
    refute_line "redir-port: 7892"
    assert_line "  enable: true"
}

@test "process_template: nested markers — inner treated as content" {
    # Inner ROUTER markers don't close the outer PC block;
    # they are treated as plain content inside the PC block.
    run process "# --- PC ---
# --- ROUTER ---
inner content
# --- ROUTER ---
# --- PC ---
after" "PC"
    assert_success
    assert_line "# --- ROUTER ---"
    assert_line "inner content"
    assert_line "after"
}

@test "process_template: nested markers — outer non-matching hides inner" {
    run process "# --- MOBILE ---
# --- PC ---
hidden
# --- PC ---
# --- MOBILE ---
after" "PC"
    assert_success
    # Everything inside MOBILE block is hidden, including the inner PC markers
    refute_line "hidden"
    assert_line "after"
}

@test "process_template: empty file" {
    local tmpfile="$BATS_TEST_TMPDIR/empty.yaml"
    touch "$tmpfile"
    run process_template "$tmpfile" "PC"
    assert_success
    assert_output ""
}
