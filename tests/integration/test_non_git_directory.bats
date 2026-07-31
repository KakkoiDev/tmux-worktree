#!/usr/bin/env bats
# Tests for behavior outside git repositories

load '../test_helper'

setup_file() {
    export SHARED_REPO_DIR
    SHARED_REPO_DIR=$(create_shared_repo)
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
    load_config
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a non-git temp directory for testing
    export NON_GIT_DIR
    NON_GIT_DIR=$(mktemp -d "${BATS_TMPDIR}/non-git.XXXXXX")
}

teardown() {
    rm -rf "$NON_GIT_DIR" 2>/dev/null || true
}

# ==============================================================================
# require_git_repo HELPER TESTS
# ==============================================================================

@test "require_git_repo succeeds in git repository" {
    cd "$SHARED_REPO_DIR"
    run require_git_repo
    assert_success
}

@test "require_git_repo fails outside git repository" {
    cd "$NON_GIT_DIR"
    run require_git_repo
    assert_failure
}

# ==============================================================================
# MENU FUNCTIONS IN NON-GIT DIRECTORY
# ==============================================================================

@test "show_worktree_menu fails gracefully outside git repo" {
    cd "$NON_GIT_DIR"

    # Mock display_menu to prevent real menu opens
    # See CONTRIBUTING.md "Testing Menu Functions" for details.
    tk_menu_show() { echo "MENU_CALLED"; TK_MENU_ARGS=(); }

    run show_worktree_menu 1 ""
    assert_failure
}

@test "show_add_worktree_menu fails gracefully outside git repo" {
    cd "$NON_GIT_DIR"

    # Mock display_menu to prevent real menu opens
    tk_menu_show() { echo "MENU_CALLED"; TK_MENU_ARGS=(); }

    run show_add_worktree_menu 1 ""
    assert_failure
}

@test "show_remove_worktree_menu fails gracefully outside git repo" {
    cd "$NON_GIT_DIR"

    # Mock display_menu to prevent real menu opens
    tk_menu_show() { echo "MENU_CALLED"; TK_MENU_ARGS=(); }

    run show_remove_worktree_menu 1 ""
    assert_failure
}

@test "create_new_worktree fails gracefully outside git repo" {
    cd "$NON_GIT_DIR"

    run create_new_worktree "test-branch"
    assert_failure
}

@test "fetch_remote_branches fails gracefully outside git repo" {
    cd "$NON_GIT_DIR"

    run fetch_remote_branches
    assert_failure
}

@test "remove_worktree fails gracefully outside git repo" {
    cd "$NON_GIT_DIR"

    run remove_worktree "/fake/path" "fake-branch" "fake-session" 1
    assert_failure
}

# ==============================================================================
# tmux_worktrees_main EXISTING CHECK
# ==============================================================================

@test "tmux_worktrees_main returns success outside git repo" {
    cd "$NON_GIT_DIR"

    run tmux_worktrees_main
    # Returns 0 so run-shell doesn't dump output to the pane
    assert_success
}

@test "tmux_worktrees_main succeeds in git repo" {
    cd "$SHARED_REPO_DIR"

    # Mock display_menu to prevent real menu opens
    tk_menu_show() { echo "MENU_CALLED"; TK_MENU_ARGS=(); }

    run tmux_worktrees_main
    assert_success
}
