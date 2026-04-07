#!/usr/bin/env bats
# Tests for Options menu and _cycle_value helper

load '../test_helper'

# Global to capture menu options
CAPTURED_MENU_OPTIONS=""

setup_file() {
    export SHARED_REPO_DIR
    SHARED_REPO_DIR=$(create_shared_repo)
    cd "$SHARED_REPO_DIR"
    start_tmux_server
}

teardown_file() {
    stop_tmux_server
    cleanup_shared_repo
}

setup() {
    reset_shared_repo
    source_script "$SCRIPTS_DIR/helpers.sh"
    source_script "$SCRIPTS_DIR/filter.sh"
    cd "$TEST_REPO_DIR" || exit 1
    load_config
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    # CRITICAL: Set WORKTREE_BASE AFTER load_config because load_config overwrites it
    init_test_worktree_base

    # Set tmux option so reload_config (called by show_options_menu) uses test path
    tmux_set_option "@worktree-path" "$WORKTREE_BASE"

    # Mock display_menu to capture options without opening real tmux menus
    display_menu() {
        CAPTURED_MENU_OPTIONS="$2"
    }
}

teardown() {
    CAPTURED_MENU_OPTIONS=""
    safe_cleanup_worktree_base
}

# ==============================================================================
# _cycle_value TESTS
# ==============================================================================

@test "_cycle_value: cycles to next value" {
    run _cycle_value "off" "off" "on"
    assert_success
    assert_equal "on" "$output"
}

@test "_cycle_value: wraps around to first value" {
    run _cycle_value "on" "off" "on"
    assert_success
    assert_equal "off" "$output"
}

@test "_cycle_value: cycles through multiple values" {
    run _cycle_value "15" "10" "15" "20" "25"
    assert_success
    assert_equal "20" "$output"
}

@test "_cycle_value: wraps around multiple values" {
    run _cycle_value "25" "10" "15" "20" "25"
    assert_success
    assert_equal "10" "$output"
}

@test "_cycle_value: returns first when current not found" {
    run _cycle_value "unknown" "off" "on"
    assert_success
    assert_equal "off" "$output"
}

@test "_cycle_value: handles single value" {
    run _cycle_value "only" "only"
    assert_success
    assert_equal "only" "$output"
}

# ==============================================================================
# OPTIONS MENU CONTENT TESTS
# ==============================================================================

@test "options menu generates Copy ignored option" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Copy ignored:'
}

@test "options menu generates Debug option" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Debug:'
}

@test "options menu generates Items/page option" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Items/page:'
}

@test "options menu generates Fetch timeout option" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Fetch timeout:'
}

@test "options menu generates Path option" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Path:'
}

@test "options menu generates Back option" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'Back'
}

# ==============================================================================
# OPTIONS MENU DISPLAY VALUES
# ==============================================================================

@test "options menu shows current COPY_IGNORED value" {
    tmux_set_option "@worktree-copy-ignored" "off"
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'Copy ignored: off'
}

@test "options menu shows current DEBUG value" {
    tmux_set_option "@worktree-debug" "on"
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'Debug: on'
}

@test "options menu shows current ITEMS_PER_PAGE value" {
    tmux_set_option "@worktree-items-per-page" "20"
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'Items/page: 20'
}

@test "options menu shows current FETCH_TIMEOUT value" {
    tmux_set_option "@worktree-fetch-timeout" "60"
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'Fetch timeout: 60s'
}

# ==============================================================================
# OPTIONS MENU COMMANDS
# ==============================================================================

@test "options menu uses set_option dispatch for copy-ignored" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'set_option @worktree-copy-ignored'
}

@test "options menu uses set_option dispatch for debug" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'set_option @worktree-debug'
}

@test "options menu uses set_option dispatch for items-per-page" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'set_option @worktree-items-per-page'
}

@test "options menu uses set_option dispatch for fetch-timeout" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'set_option @worktree-fetch-timeout'
}

@test "options menu uses set_option dispatch for path" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'set_option @worktree-path'
}

@test "options menu uses set_option dispatch (not inline set-option)" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'set_option'
    refute_contains "$CAPTURED_MENU_OPTIONS" 'set-option -g'
}

@test "options menu contains tmux_worktrees_main for Back" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'tmux_worktrees_main'
}

# ==============================================================================
# DISPATCH TESTS
# ==============================================================================

@test "script CLI: show_options_menu is a recognized command" {
    run bash -c "
        source '$SCRIPTS_DIR/helpers.sh'
        source '$SCRIPTS_DIR/filter.sh'
        load_config
        source '$SCRIPTS_DIR/worktree_manager.sh'
        type show_options_menu
    "
    assert_success
    assert_contains "$output" "function"
}

@test "script CLI: set_option is a recognized command" {
    run bash -c "
        source '$SCRIPTS_DIR/helpers.sh'
        source '$SCRIPTS_DIR/filter.sh'
        load_config
        source '$SCRIPTS_DIR/worktree_manager.sh'
        type set_option
    "
    assert_success
    assert_contains "$output" "function"
}

# ==============================================================================
# OPTIONS PERSISTENCE TESTS
# ==============================================================================

@test "save_option writes key=value to state file" {
    export TMUX_WORKTREE_STATE_FILE="/tmp/tmux-worktree-test-persist-${BATS_TEST_NUMBER}-$$"

    save_option "@worktree-debug" "on"

    [ -f "$TMUX_WORKTREE_STATE_FILE" ]
    run cat "$TMUX_WORKTREE_STATE_FILE"
    assert_contains "$output" "@worktree-debug=on"

    rm -f "$TMUX_WORKTREE_STATE_FILE"
}

@test "save_option overwrites existing key" {
    export TMUX_WORKTREE_STATE_FILE="/tmp/tmux-worktree-test-persist-${BATS_TEST_NUMBER}-$$"

    save_option "@worktree-debug" "on"
    save_option "@worktree-debug" "off"

    # Should have exactly one entry for the key
    local count
    count=$(grep -c "@worktree-debug" "$TMUX_WORKTREE_STATE_FILE")
    assert_equal "1" "$count"

    run cat "$TMUX_WORKTREE_STATE_FILE"
    assert_contains "$output" "@worktree-debug=off"

    rm -f "$TMUX_WORKTREE_STATE_FILE"
}

@test "save_option preserves other keys" {
    export TMUX_WORKTREE_STATE_FILE="/tmp/tmux-worktree-test-persist-${BATS_TEST_NUMBER}-$$"

    save_option "@worktree-debug" "on"
    save_option "@worktree-copy-ignored" "on"
    save_option "@worktree-debug" "off"

    run cat "$TMUX_WORKTREE_STATE_FILE"
    assert_contains "$output" "@worktree-copy-ignored=on"
    assert_contains "$output" "@worktree-debug=off"

    rm -f "$TMUX_WORKTREE_STATE_FILE"
}

@test "restore_saved_options sets tmux options from state file" {
    export TMUX_WORKTREE_STATE_FILE="/tmp/tmux-worktree-test-persist-${BATS_TEST_NUMBER}-$$"

    echo "@worktree-debug=on" > "$TMUX_WORKTREE_STATE_FILE"
    echo "@worktree-copy-ignored=on" >> "$TMUX_WORKTREE_STATE_FILE"

    restore_saved_options

    run tmux_get_option "@worktree-debug"
    assert_equal "on" "$output"

    run tmux_get_option "@worktree-copy-ignored"
    assert_equal "on" "$output"

    rm -f "$TMUX_WORKTREE_STATE_FILE"
}

@test "restore_saved_options handles missing state file" {
    export TMUX_WORKTREE_STATE_FILE="/tmp/nonexistent-state-file-$$"

    run restore_saved_options
    assert_success
}

@test "set_option sets tmux option and persists to file" {
    export TMUX_WORKTREE_STATE_FILE="/tmp/tmux-worktree-test-persist-${BATS_TEST_NUMBER}-$$"

    set_option "@worktree-debug" "on"

    # Verify tmux option was set
    run tmux_get_option "@worktree-debug"
    assert_equal "on" "$output"

    # Verify state file was written
    run cat "$TMUX_WORKTREE_STATE_FILE"
    assert_contains "$output" "@worktree-debug=on"

    rm -f "$TMUX_WORKTREE_STATE_FILE"
}

@test "options survive config reload via state file" {
    export TMUX_WORKTREE_STATE_FILE="/tmp/tmux-worktree-test-persist-${BATS_TEST_NUMBER}-$$"

    # Save an option
    save_option "@worktree-copy-ignored" "on"

    # Clear the tmux option
    tmux_set_option "@worktree-copy-ignored" "off"

    # Restore from file (simulates plugin reload)
    restore_saved_options

    run tmux_get_option "@worktree-copy-ignored"
    assert_equal "on" "$output"

    rm -f "$TMUX_WORKTREE_STATE_FILE"
}
