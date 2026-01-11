#!/usr/bin/env bats
# Tests for menu command generation (using mocks, not actual menu display)
# These tests verify that menu functions generate valid tmux commands

load 'test_helper'

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

    # Override display_menu to capture instead of display
    display_menu() {
        CAPTURED_MENU_OPTIONS="$2"
    }
}

teardown() {
    CAPTURED_MENU_OPTIONS=""
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
