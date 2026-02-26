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
    export COPY_IGNORED="off"
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

@test "options menu contains set-option for copy-ignored" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'set-option -g @worktree-copy-ignored'
}

@test "options menu contains set-option for debug" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'set-option -g @worktree-debug'
}

@test "options menu contains set-option for items-per-page" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'set-option -g @worktree-items-per-page'
}

@test "options menu contains set-option for fetch-timeout" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'set-option -g @worktree-fetch-timeout'
}

@test "options menu contains show_options_menu callback" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'show_options_menu'
}

@test "options menu contains tmux_worktrees_main for Back" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'tmux_worktrees_main'
}

# ==============================================================================
# DISPATCH TESTS
# ==============================================================================

@test "script CLI: show_options_menu is a recognized command" {
    # Verify the dispatch case handles show_options_menu
    # We can't fully test it without a tmux client, but we can verify
    # the function exists and is callable
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
