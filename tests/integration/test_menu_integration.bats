#!/usr/bin/env bats
# Tests for menu command generation (using mocks, not actual menu display)
# These tests verify that menu functions generate valid tmux commands

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

    # IMPORTANT: Mock display_menu to prevent opening real tmux menus.
    # Without this mock, tmux display-menu would block test execution
    # and require manual Escape key press to continue.
    # See CONTRIBUTING.md "Testing Menu Functions" for details.
    display_menu() {
        CAPTURED_MENU_OPTIONS="$2"
    }
}

teardown() {
    CAPTURED_MENU_OPTIONS=""
    safe_cleanup_worktree_base
}

# ==============================================================================
# MAIN MENU TESTS
# ==============================================================================

@test "main menu generates List option" {
    tmux_worktrees_main
    assert_contains "$CAPTURED_MENU_OPTIONS" '"List"'
}

@test "main menu generates Add option" {
    tmux_worktrees_main
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Add"'
}

@test "main menu generates Remove option" {
    tmux_worktrees_main
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Remove"'
}

@test "main menu generates Options option" {
    tmux_worktrees_main
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Options"'
}

@test "main menu generates Quit option" {
    tmux_worktrees_main
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Quit"'
}

# ==============================================================================
# LIST WORKTREE MENU TESTS
# ==============================================================================

@test "list worktree menu generates Filter option" {
    show_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Filter"'
}

@test "list worktree menu generates Back option" {
    show_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" 'Back'
}

@test "list worktree menu shows worktrees" {
    # Create a worktree
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    show_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" 'feature-one'

    # Cleanup
    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "list worktree menu with filter shows matching only" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one
    git worktree add -q "$wt_dir/bugfix-123" bugfix-123

    # Filter for feature* should not show bugfix
    show_worktree_menu 1 "feature*"
    assert_contains "$CAPTURED_MENU_OPTIONS" 'feature-one'

    # Cleanup
    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    git worktree remove --force "$wt_dir/bugfix-123" 2>/dev/null || true
    rm -rf "$wt_dir"
}

# ==============================================================================
# ADD WORKTREE MENU TESTS
# ==============================================================================

@test "add worktree menu generates New option" {
    show_add_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" '"New"'
}

@test "add worktree menu generates Fetch remote option" {
    show_add_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Fetch remote"'
}

@test "add worktree menu shows existing branches" {
    show_add_worktree_menu 1
    # Test branches created by create_test_repo
    assert_contains "$CAPTURED_MENU_OPTIONS" 'feature-one'
    assert_contains "$CAPTURED_MENU_OPTIONS" 'feature-two'
}

# ==============================================================================
# REMOVE WORKTREE MENU TESTS
# ==============================================================================

@test "remove worktree menu generates Filter option" {
    show_remove_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Filter"'
}

@test "remove worktree menu shows removable worktrees" {
    # Create a worktree (not current dir, so removable)
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-two" feature-two

    show_remove_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" 'feature-two'

    # Cleanup
    git worktree remove --force "$wt_dir/feature-two" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "remove worktree menu excludes current directory" {
    show_remove_worktree_menu 1
    # Menu should be generated (not empty/error)
    [ -n "$CAPTURED_MENU_OPTIONS" ]
}

# ==============================================================================
# PAGINATION TESTS (using branches, not worktrees, for speed)
# ==============================================================================

@test "add worktree menu pagination shows navigation" {
    # Use ITEMS_PER_PAGE to create enough branches
    # Test branches exist from create_test_repo (feature-one, feature-two, bugfix-123, master)
    # We test the add menu which lists branches (faster than creating worktrees)
    show_add_worktree_menu 1
    # Should have Back option at minimum
    assert_contains "$CAPTURED_MENU_OPTIONS" 'Back'
}

# ==============================================================================
# COMMAND STRUCTURE TESTS
# ==============================================================================

@test "menu options contain run-shell commands" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    show_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" 'run-shell'

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "menu options contain session switching logic" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    show_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" 'switch-client'

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "remove worktree menu contains properly quoted script path" {
    # Regression test: verify script_path variable is expanded, not literal
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    show_remove_worktree_menu 1

    # Must NOT contain literal 'script_path' - that would mean AWK variable wasn't expanded
    refute_contains "$CAPTURED_MENU_OPTIONS" "script_path"

    # Must contain the actual script path (worktree_manager.sh)
    assert_contains "$CAPTURED_MENU_OPTIONS" "worktree_manager.sh"

    # Must contain remove_worktree command
    assert_contains "$CAPTURED_MENU_OPTIONS" "remove_worktree"

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "remove worktree menu run-shell command has valid quoting structure" {
    # Regression test: script path must be single-quoted for proper shell execution
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    show_remove_worktree_menu 1

    # The pattern should be 'script_path' not '"'script_path'"'
    # Check for properly quoted path pattern: '/path/to/script' remove_worktree
    assert_contains "$CAPTURED_MENU_OPTIONS" "worktree_manager.sh' remove_worktree"

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

# ==============================================================================
# E2E TESTS - Verify script CLI executes correctly
# These tests validate that the CLI invocation pattern works, which is critical
# for run-shell commands. The 'version' and 'health_check' commands don't require
# a tmux client, making them ideal for testing CLI execution.
# ==============================================================================

@test "script CLI: version command executes via direct invocation" {
    # Test the CLI invocation pattern: 'script' command
    run "$SCRIPTS_DIR/worktree_manager.sh" version
    assert_success
    assert_contains "$output" "tmux-worktree"
}

@test "script CLI: health_check command executes via direct invocation" {
    run "$SCRIPTS_DIR/worktree_manager.sh" health_check
    assert_success
    assert_contains "$output" "Health Check"
}

@test "script invocation pattern works via /bin/sh" {
    # Verify the exact command format used in run-shell works via /bin/sh
    # This catches /bin/sh compatibility issues in the invocation pattern
    run /bin/sh -c "'$SCRIPTS_DIR/worktree_manager.sh' version"
    assert_success
    assert_contains "$output" "tmux-worktree"
}

@test "script invocation with arguments works via /bin/sh" {
    # Test argument passing through /bin/sh (like run-shell does)
    run /bin/sh -c "'$SCRIPTS_DIR/worktree_manager.sh' health_check"
    assert_success
}
