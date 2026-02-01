#!/usr/bin/env bats
# Tests for worktree health check functionality
# Tests stale worktree detection, auto-prune, and repair capabilities

load '../test_helper'

# Create shared repo once per file
setup_file() {
    export SHARED_REPO_DIR
    SHARED_REPO_DIR=$(create_shared_repo)
    cd "$SHARED_REPO_DIR"
    start_tmux_server
}

teardown_file() {
    stop_tmux_server
    cleanup_main_server_test_sessions
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
}

teardown() {
    # Clean up worktrees created during test
    git worktree list --porcelain 2>/dev/null | grep "^worktree " | cut -d' ' -f2 | while read -r wt; do
        [ "$wt" != "$TEST_REPO_DIR" ] && git worktree remove --force "$wt" 2>/dev/null || true
    done

    # Prune any stale entries
    git worktree prune 2>/dev/null || true

    # Delete test branches
    git branch 2>/dev/null | grep "^  test-" | while read -r branch; do
        git branch -D "${branch## }" 2>/dev/null || true
    done

    safe_cleanup_worktree_base
}

# ==============================================================================
# HELPER FUNCTION TESTS
# ==============================================================================

@test "has_worktree_repair returns based on git version" {
    # Just verify the function runs without error
    run has_worktree_repair
    # Status should be 0 (has repair) or 1 (no repair) - both are valid
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

@test "count_stale_worktrees returns 0 when no stale entries" {
    run count_stale_worktrees
    assert_success
    assert_equal "0" "$output"
}

@test "count_stale_worktrees detects manually deleted worktree" {
    local project
    project=$(get_project_name)
    local wt_dir="$WORKTREE_BASE/$project/test-stale"
    mkdir -p "$(dirname "$wt_dir")"

    # Create a worktree
    git worktree add -q "$wt_dir" -b "test-stale"

    # Verify it's counted (not stale yet)
    run count_stale_worktrees
    assert_success
    assert_equal "0" "$output"

    # Manually delete the directory (simulates orphaned worktree)
    rm -rf "$wt_dir"

    # Now it should be stale
    run count_stale_worktrees
    assert_success
    assert_equal "1" "$output"

    # Cleanup
    git worktree prune
    git branch -D "test-stale" 2>/dev/null || true
}

@test "worktree_prune removes stale entries" {
    local project
    project=$(get_project_name)
    local wt_dir="$WORKTREE_BASE/$project/test-prune"
    mkdir -p "$(dirname "$wt_dir")"

    # Create and then manually delete worktree
    git worktree add -q "$wt_dir" -b "test-prune"
    rm -rf "$wt_dir"

    # Verify stale
    local stale_before
    stale_before=$(count_stale_worktrees)
    assert_equal "1" "$stale_before"

    # Prune
    run worktree_prune
    assert_success

    # Verify cleaned
    run count_stale_worktrees
    assert_success
    assert_equal "0" "$output"

    # Cleanup branch
    git branch -D "test-prune" 2>/dev/null || true
}

@test "worktree_repair runs without error on Git 2.30+" {
    if ! has_worktree_repair; then
        skip "Git version does not support worktree repair"
    fi

    run worktree_repair
    assert_success
}

# ==============================================================================
# AUTO-PRUNE TESTS
# ==============================================================================

@test "get_worktree_data auto-prunes stale entries" {
    local project
    project=$(get_project_name)
    local wt_dir="$WORKTREE_BASE/$project/test-auto-prune"
    mkdir -p "$(dirname "$wt_dir")"

    # Create and manually delete worktree
    git worktree add -q "$wt_dir" -b "test-auto-prune"
    rm -rf "$wt_dir"

    # Verify stale entry exists
    local stale_before
    stale_before=$(count_stale_worktrees)
    assert_equal "1" "$stale_before"

    # Call get_worktree_data (triggers auto-prune)
    run get_worktree_data 1 ""
    assert_success

    # Verify auto-prune occurred
    run count_stale_worktrees
    assert_success
    assert_equal "0" "$output"

    # Cleanup branch
    git branch -D "test-auto-prune" 2>/dev/null || true
}

# ==============================================================================
# REMOVE_WORKTREE STALE HANDLING TESTS
# ==============================================================================

@test "remove_worktree handles already-deleted path gracefully" {
    local project
    project=$(get_project_name)
    local branch="test-already-deleted"
    local wt_path="$WORKTREE_BASE/$project/$branch"
    local session_name="${project}-${branch}"
    mkdir -p "$(dirname "$wt_path")"

    # Create worktree
    git worktree add -q "$wt_path" -b "$branch"

    # Manually delete the directory
    rm -rf "$wt_path"

    # Verify stale entry exists
    local stale_before
    stale_before=$(count_stale_worktrees)
    assert_equal "1" "$stale_before"

    # Mock show_remove_worktree_menu to avoid menu display
    show_remove_worktree_menu() { :; }

    # remove_worktree should handle this gracefully
    run remove_worktree "$wt_path" "$branch" "$session_name" 1
    # Should not crash

    # Stale entry should be cleaned
    run count_stale_worktrees
    assert_equal "0" "$output"

    # Cleanup branch
    git branch -D "$branch" 2>/dev/null || true
}

@test "remove_worktree removes existing path normally" {
    local project
    project=$(get_project_name)
    local branch="test-normal-remove"
    local wt_path="$WORKTREE_BASE/$project/$branch"
    local session_name="${project}-${branch}"
    mkdir -p "$(dirname "$wt_path")"

    # Create worktree
    git worktree add -q "$wt_path" -b "$branch"

    # Verify path exists
    [ -d "$wt_path" ]

    # Mock show_remove_worktree_menu
    show_remove_worktree_menu() { :; }

    # Remove worktree
    run remove_worktree "$wt_path" "$branch" "$session_name" 1

    # Path should be gone
    [ ! -d "$wt_path" ]

    # No stale entries
    run count_stale_worktrees
    assert_equal "0" "$output"

    # Cleanup branch
    git branch -D "$branch" 2>/dev/null || true
}

# ==============================================================================
# MULTIPLE STALE WORKTREES TESTS
# ==============================================================================

@test "count_stale_worktrees handles multiple stale entries" {
    local project
    project=$(get_project_name)
    mkdir -p "$WORKTREE_BASE/$project"

    # Create multiple worktrees
    git worktree add -q "$WORKTREE_BASE/$project/stale-1" -b "test-stale-1"
    git worktree add -q "$WORKTREE_BASE/$project/stale-2" -b "test-stale-2"
    git worktree add -q "$WORKTREE_BASE/$project/stale-3" -b "test-stale-3"

    # Delete them all
    rm -rf "$WORKTREE_BASE/$project/stale-1"
    rm -rf "$WORKTREE_BASE/$project/stale-2"
    rm -rf "$WORKTREE_BASE/$project/stale-3"

    # Should count all 3
    run count_stale_worktrees
    assert_success
    assert_equal "3" "$output"

    # Prune should clean all
    worktree_prune

    run count_stale_worktrees
    assert_success
    assert_equal "0" "$output"

    # Cleanup branches
    git branch -D "test-stale-1" "test-stale-2" "test-stale-3" 2>/dev/null || true
}

@test "auto-prune handles multiple stale entries" {
    local project
    project=$(get_project_name)
    mkdir -p "$WORKTREE_BASE/$project"

    # Create and delete multiple worktrees
    git worktree add -q "$WORKTREE_BASE/$project/multi-1" -b "test-multi-1"
    git worktree add -q "$WORKTREE_BASE/$project/multi-2" -b "test-multi-2"
    rm -rf "$WORKTREE_BASE/$project/multi-1"
    rm -rf "$WORKTREE_BASE/$project/multi-2"

    # Verify stale count
    local stale_before
    stale_before=$(count_stale_worktrees)
    assert_equal "2" "$stale_before"

    # get_worktree_data triggers auto-prune
    get_worktree_data 1 "" > /dev/null

    # All should be pruned
    run count_stale_worktrees
    assert_equal "0" "$output"

    # Cleanup branches
    git branch -D "test-multi-1" "test-multi-2" 2>/dev/null || true
}

# ==============================================================================
# EDGE CASES
# ==============================================================================

@test "count_stale_worktrees handles mixed valid and stale" {
    local project
    project=$(get_project_name)
    mkdir -p "$WORKTREE_BASE/$project"

    # Create valid worktree
    git worktree add -q "$WORKTREE_BASE/$project/valid-wt" -b "test-valid-wt"

    # Create and delete (stale) worktree
    git worktree add -q "$WORKTREE_BASE/$project/stale-wt" -b "test-stale-wt"
    rm -rf "$WORKTREE_BASE/$project/stale-wt"

    # Should count only 1 stale
    run count_stale_worktrees
    assert_success
    assert_equal "1" "$output"

    # Cleanup
    git worktree remove --force "$WORKTREE_BASE/$project/valid-wt" 2>/dev/null || true
    git worktree prune
    git branch -D "test-valid-wt" "test-stale-wt" 2>/dev/null || true
}

@test "health check functions work from worktree directory" {
    local project
    project=$(get_project_name)
    local wt_dir="$WORKTREE_BASE/$project/test-from-wt"
    mkdir -p "$(dirname "$wt_dir")"

    git worktree add -q "$wt_dir" -b "test-from-wt"

    # Run health functions from within the worktree
    cd "$wt_dir"

    run count_stale_worktrees
    assert_success
    assert_equal "0" "$output"

    run worktree_prune
    assert_success

    # Cleanup
    cd "$TEST_REPO_DIR"
    git worktree remove --force "$wt_dir"
    git branch -D "test-from-wt" 2>/dev/null || true
}
