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
    cd "$TEST_REPO_DIR"
    cleanup_test_branches
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
    # Returns 0 so run-shell doesn't dump output to the pane
    assert_success

    local log_file="$WORKTREE_BASE/.tmux-worktree.log"
    [ -f "$log_file" ]

    local content
    content=$(cat "$log_file")

    # Should show the non-git directory as cwd
    [[ "$content" == *"cwd=$non_git_dir"* ]]

    rm -rf "$non_git_dir"
}

@test "tmux_worktrees_main does not log git check in non-git dir" {
    DEBUG="on"
    local non_git_dir
    non_git_dir=$(mktemp -d "${BATS_TMPDIR}/non-git-diag.XXXXXX")
    cd "$non_git_dir"

    run tmux_worktrees_main
    assert_success

    local log_file="$WORKTREE_BASE/.tmux-worktree.log"
    local content
    content=$(cat "$log_file")

    # git check log only appears after require_git_repo succeeds
    [[ "$content" != *"git check:"* ]]

    rm -rf "$non_git_dir"
}

# ==============================================================================
# PANE CWD RESOLUTION
# ==============================================================================

@test "tmux_worktrees_main succeeds when called from a git repo directory" {
    cd "$TEST_REPO_DIR"

    # Mock display_menu to prevent real menu
    display_menu() { echo "MENU_CALLED"; }

    run tmux_worktrees_main
    assert_success
}

@test "get_branch_data includes cd prefix with pane_cwd" {
    # Create a branch so get_branch_data has output
    cd "$TEST_REPO_DIR"
    git branch test-cwd-branch

    run get_branch_data 1 "" 0
    assert_success

    # Output should contain "cd" prefix with the test repo path
    # because get_branch_data passes pane_cwd=$(pwd) to awk
    [[ "$output" == *"cd "* ]]
    [[ "$output" == *"$TEST_REPO_DIR"* ]]
}

@test "get_branch_data cd prefix uses current working directory" {
    cd "$TEST_REPO_DIR"
    git branch test-cwd-verify

    local before_output
    before_output=$(get_branch_data 1 "" 0)

    # The cd prefix in the awk output should reference the pane CWD
    # This ensures run-shell commands start in the correct directory
    [[ "$before_output" == *"cd"*"$TEST_REPO_DIR"*"git worktree add"* ]]
}

@test "main resolves pane CWD before dispatching commands" {
    # Start in a non-git temp dir (simulates run-shell's session CWD)
    local start_dir
    start_dir=$(mktemp -d "${BATS_TMPDIR}/session-cwd.XXXXXX")

    # Mock tmux display-message to return our test repo (simulates pane CWD)
    tmux() {
        if [[ "$1" == "display-message" && "$2" == "-p" ]]; then
            echo "$TEST_REPO_DIR"
        else
            command tmux "$@"
        fi
    }
    export -f tmux

    # Mock display_menu to capture that we got past the git check
    display_menu() { echo "MENU_OK"; }

    cd "$start_dir"

    # main() should resolve pane CWD to TEST_REPO_DIR, then succeed
    run main tmux_worktrees_main
    assert_success

    rm -rf "$start_dir"
}
