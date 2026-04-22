#!/usr/bin/env bats
# Tests for _vis_len() — UTF-8 codepoint counter

setup() {
    load '../helpers/test_helper'
    source_common
}

@test "_vis_len: empty string returns 0" {
    run _vis_len ""
    assert_success
    assert_output "0"
}

@test "_vis_len: pure ASCII" {
    run _vis_len "hello"
    assert_success
    assert_output "5"
}

@test "_vis_len: single ASCII char" {
    run _vis_len "x"
    assert_success
    assert_output "1"
}

@test "_vis_len: digits" {
    run _vis_len "12345"
    assert_success
    assert_output "5"
}

@test "_vis_len: special characters" {
    run _vis_len '!@#$%'
    assert_success
    assert_output "5"
}

@test "_vis_len: Cyrillic word (6 chars)" {
    run _vis_len "привет"
    assert_success
    assert_output "6"
}

@test "_vis_len: single Cyrillic char" {
    run _vis_len "Б"
    assert_success
    assert_output "1"
}

@test "_vis_len: mixed ASCII + Cyrillic" {
    run _vis_len "hi мир"
    assert_success
    assert_output "6"
}

@test "_vis_len: emoji (4-byte UTF-8)" {
    run _vis_len "😀"
    assert_success
    assert_output "1"
}

@test "_vis_len: space only" {
    run _vis_len " "
    assert_success
    assert_output "1"
}

@test "_vis_len: multiple spaces" {
    run _vis_len "   "
    assert_success
    assert_output "3"
}

@test "_vis_len: ASCII with spaces" {
    run _vis_len "hi there"
    assert_success
    assert_output "8"
}
