#!/usr/bin/env bats
# Unit tests for format_age_short
# bats file_tags=unit,fast

load '../test_helper'

setup() {
    source "$SCRIPTS_DIR/helpers.sh"
}

@test "format_age_short: ts=0 -> never" {
    run format_age_short 0 1000000000
    assert_success
    assert_equal "never" "$output"
}

@test "format_age_short: empty ts -> never" {
    run format_age_short "" 1000000000
    assert_success
    assert_equal "never" "$output"
}

@test "format_age_short: non-numeric ts -> never" {
    run format_age_short "abc" 1000000000
    assert_success
    assert_equal "never" "$output"
}

@test "format_age_short: same ts and now -> now" {
    run format_age_short 1000000000 1000000000
    assert_success
    assert_equal "now" "$output"
}

@test "format_age_short: 30 seconds -> now" {
    run format_age_short 1000000000 1000000030
    assert_success
    assert_equal "now" "$output"
}

@test "format_age_short: 2 minutes -> 2m" {
    run format_age_short 1000000000 1000000120
    assert_success
    assert_equal "2m" "$output"
}

@test "format_age_short: 59 minutes -> 59m" {
    run format_age_short 1000000000 1000003540
    assert_success
    assert_equal "59m" "$output"
}

@test "format_age_short: 1 hour -> 1h" {
    run format_age_short 1000000000 1000003600
    assert_success
    assert_equal "1h" "$output"
}

@test "format_age_short: 5 hours -> 5h" {
    run format_age_short 1000000000 1000018000
    assert_success
    assert_equal "5h" "$output"
}

@test "format_age_short: 1 day -> 1d" {
    run format_age_short 1000000000 1000086400
    assert_success
    assert_equal "1d" "$output"
}

@test "format_age_short: 3 days -> 3d" {
    run format_age_short 1000000000 1000259200
    assert_success
    assert_equal "3d" "$output"
}

@test "format_age_short: 6 days -> 6d (under a week)" {
    run format_age_short 1000000000 1000518400
    assert_success
    assert_equal "6d" "$output"
}

@test "format_age_short: 1 week -> 1w" {
    run format_age_short 1000000000 1000604800
    assert_success
    assert_equal "1w" "$output"
}

@test "format_age_short: 5 weeks -> 5w" {
    run format_age_short 1000000000 1003024000
    assert_success
    assert_equal "5w" "$output"
}

@test "format_age_short: negative diff (ts > now) clamps to now" {
    run format_age_short 1000000100 1000000000
    assert_success
    assert_equal "now" "$output"
}
