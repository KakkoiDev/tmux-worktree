#!/usr/bin/env bats
# Tests for early debug directory creation and diagnostic logging

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
    cd "$TEST_REPO_DIR"
    source "$SCRIPTS_DIR/helpers.sh"
    source "$SCRIPTS_DIR/filter.sh"
    load_config
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Use isolated WORKTREE_BASE after load_config
    init_test_worktree_base
}

teardown() {
    safe_cleanup_worktree_base
}

# ==============================================================================
# WORKTREE_BASE DIRECTORY CREATION
# ==============================================================================

@test "load_config creates WORKTREE_BASE directory" {
    local test_base="/tmp/tmux-worktree-loadconfig-test-$$"
    rm -rf "$test_base"

    WORKTREE_BASE="$test_base"
    # Re-source helpers to get the mkdir -p in load_config
    source "$SCRIPTS_DIR/helpers.sh"

    # Simulate what load_config does after setting WORKTREE_BASE
    mkdir -p "$WORKTREE_BASE" 2>/dev/null || true

    [ -d "$test_base" ]
    rm -rf "$test_base"
}

@test "load_config creates WORKTREE_BASE when it does not exist" {
    local test_base="/tmp/tmux-worktree-newdir-test-$$"
    rm -rf "$test_base"

    # Override WORKTREE_BASE via tmux option and force reload
    tmux_run set-option -g "@worktree-path" "$test_base"
    source "$SCRIPTS_DIR/helpers.sh"
    reload_config

    [ -d "$test_base" ]

    # Cleanup
    tmux_run set-option -gu "@worktree-path"
    rm -rf "$test_base"
    # Restore test WORKTREE_BASE for teardown
    export WORKTREE_BASE="/tmp/tmux-worktree-test-$$"
    mkdir -p "$WORKTREE_BASE"
}

# ==============================================================================
# DEBUG LOG FILE CREATION
# ==============================================================================

@test "debug_log creates log file when debug is on" {
    DEBUG="on"
    debug_log "test message"

    local log_file="$WORKTREE_BASE/.tmux-worktree.log"
    [ -f "$log_file" ]
}

@test "debug_log writes timestamped messages" {
    DEBUG="on"
    debug_log "hello from test"

    local log_file="$WORKTREE_BASE/.tmux-worktree.log"
    local content
    content=$(cat "$log_file")

    # Should contain timestamp pattern and our message
    [[ "$content" == *"hello from test"* ]]
    [[ "$content" =~ \[[0-9]{4}-[0-9]{2}-[0-9]{2} ]]
}

@test "debug_log does nothing when debug is off" {
    DEBUG="off"
    debug_log "should not appear"

    local log_file="$WORKTREE_BASE/.tmux-worktree.log"
    [ ! -f "$log_file" ]
}

@test "debug_log appends multiple messages" {
    DEBUG="on"
    debug_log "first message"
    debug_log "second message"

    local log_file="$WORKTREE_BASE/.tmux-worktree.log"
    local line_count
    line_count=$(wc -l < "$log_file")

    [ "$line_count" -eq 2 ]
}

# ==============================================================================
# EARLY DIAGNOSTIC LOGGING IN tmux_worktrees_main
# ==============================================================================

@test "tmux_worktrees_main logs cwd before git check in git repo" {
    DEBUG="on"

    # Mock display_menu to prevent real menu
    display_menu() { echo "MENU_CALLED"; }

    run tmux_worktrees_main
    assert_success

    local log_file="$WORKTREE_BASE/.tmux-worktree.log"
    [ -f "$log_file" ]

    local content
    content=$(cat "$log_file")
    [[ "$content" == *"cwd="* ]]
}

@test "tmux_worktrees_main logs cwd before git check in non-git dir" {
    DEBUG="on"
    local non_git_dir
    non_git_dir=$(mktemp -d "${BATS_TMPDIR}/non-git-debug.XXXXXX")
    cd "$non_git_dir"

    run tmux_worktrees_main
    assert_failure

    local log_file="$WORKTREE_BASE/.tmux-worktree.log"
    [ -f "$log_file" ]

    local content
    content=$(cat "$log_file")

    # Should show the non-git directory as cwd
    [[ "$content" == *"cwd=$non_git_dir"* ]]

    rm -rf "$non_git_dir"
}

@test "tmux_worktrees_main logs git check result on failure" {
    DEBUG="on"
    local non_git_dir
    non_git_dir=$(mktemp -d "${BATS_TMPDIR}/non-git-diag.XXXXXX")
    cd "$non_git_dir"

    run tmux_worktrees_main
    assert_failure

    local log_file="$WORKTREE_BASE/.tmux-worktree.log"
    local content
    content=$(cat "$log_file")

    # Should log the git rev-parse output (fatal error message)
    [[ "$content" == *"git check:"* ]]

    rm -rf "$non_git_dir"
}
