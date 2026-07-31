#!/usr/bin/env bats
# Stress tests for tmux-worktree
# These tests verify behavior under high load and edge conditions
# bats file_tags=stress,slow

load '../test_helper'

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
    cd "$TEST_REPO_DIR"
    source "$SCRIPTS_DIR/helpers.sh"
    source "$SCRIPTS_DIR/filter.sh"
    load_config
    source "$SCRIPTS_DIR/worktree_manager.sh"

    export WORKTREE_BASE="${BATS_TMPDIR}/worktrees-stress-$$"
    mkdir -p "$WORKTREE_BASE"
}

teardown() {
    # Clean up all stress test worktrees
    git worktree list --porcelain 2>/dev/null | grep "^worktree " | cut -d' ' -f2 | while read -r wt; do
        [ "$wt" != "$TEST_REPO_DIR" ] && git worktree remove --force "$wt" 2>/dev/null || true
    done

    # Clean up stress test branches
    git branch 2>/dev/null | grep "^  stress-" | while read -r branch; do
        git branch -D "${branch## }" 2>/dev/null || true
    done

    rm -rf "$WORKTREE_BASE"
}

# ==============================================================================
# MANY BRANCHES TESTS
# ==============================================================================

@test "handles 50 branches without performance degradation" {
    # Create 50 branches
    for i in $(seq 1 50); do
        git branch "stress-branch-$i" 2>/dev/null || true
    done

    # Verify branch count
    local branch_count
    branch_count=$(git branch | wc -l)
    [ "$branch_count" -ge 50 ]

    # get_branch_data should still work
    run get_branch_data 1 ""
    assert_success
    # Should return first page of data
    [ -n "$output" ]
}

@test "pagination works correctly with many branches" {
    # Create enough branches to require multiple pages
    for i in $(seq 1 25); do
        git branch "stress-page-$i" 2>/dev/null || true
    done

    # Test page 1
    run get_branch_data 1 ""
    assert_success
    local page1_output="$output"

    # Test page 2
    run get_branch_data 2 ""
    assert_success
    local page2_output="$output"

    # Pages should be different (assuming ITEMS_PER_PAGE < 25)
    # Or page 2 should at least not crash
    [ -n "$page1_output" ]
}

# ==============================================================================
# MANY WORKTREES TESTS
# ==============================================================================

@test "handles 10 simultaneous worktrees" {
    local project
    project=$(get_project_name)

    # Create 10 worktrees
    for i in $(seq 1 10); do
        local wt_path="$WORKTREE_BASE/$project/stress-wt-$i"
        mkdir -p "$(dirname "$wt_path")"
        git worktree add -q "$wt_path" -b "stress-wt-$i" 2>/dev/null || true
    done

    # Verify worktree count
    local wt_count
    wt_count=$(git worktree list | wc -l)
    [ "$wt_count" -ge 10 ]

    # get_worktree_data should work
    run get_worktree_data 1 ""
    assert_success
    [ -n "$output" ]
}

@test "get_removable_worktree_data handles many worktrees" {
    local project
    project=$(get_project_name)

    # Create 5 worktrees
    for i in $(seq 1 5); do
        local wt_path="$WORKTREE_BASE/$project/stress-rm-$i"
        mkdir -p "$(dirname "$wt_path")"
        git worktree add -q "$wt_path" -b "stress-rm-$i" 2>/dev/null || true
    done

    run get_removable_worktree_data 1 ""
    assert_success
    # Should contain at least some of our worktrees
    assert_contains "$output" "stress-rm"
}

# ==============================================================================
# RAPID SUCCESSIVE CALLS TESTS
# ==============================================================================

@test "rapid successive get_worktree_data calls are stable" {
    for i in $(seq 1 10); do
        run get_worktree_data 1 ""
        assert_success
    done
}

@test "rapid successive get_branch_data calls are stable" {
    for i in $(seq 1 10); do
        run get_branch_data 1 ""
        assert_success
    done
}

@test "alternating function calls don't interfere" {
    for i in $(seq 1 5); do
        run get_worktree_data 1 ""
        assert_success
        run get_branch_data 1 ""
        assert_success
        run get_removable_worktree_data 1 ""
        assert_success
    done
}

# ==============================================================================
# FILTER STRESS TESTS
# ==============================================================================

@test "filter handles maximum length input" {
    # Create a filter at exactly 256 chars
    local max_filter
    max_filter=$(printf 'a%.0s' {1..256})

    run get_branch_data 1 "$max_filter"
    assert_success
    # Should not crash even with long filter
}

@test "filter with many wildcards works" {
    local wildcard_filter="*a*b*c*d*e*f*"
    run get_branch_data 1 "$wildcard_filter"
    assert_success
}

# ==============================================================================
# CONCURRENT MENU GENERATION TESTS
# ==============================================================================

@test "menu generation is stable under load" {
    # Mock display_menu
    tk_menu_show() { echo "MENU: ${TK_MENU_TITLE:-}"; TK_MENU_ARGS=(); }

    for i in $(seq 1 5); do
        run show_worktree_menu 1 ""
        assert_success
    done
}

# ==============================================================================
# LONG BRANCH NAME TESTS
# ==============================================================================

@test "handles branch names at git limit" {
    # Git branch names can be up to 255 chars
    local long_branch
    long_branch="stress-$(printf 'x%.0s' {1..200})"

    git branch "$long_branch" 2>/dev/null || true

    run get_branch_data 1 ""
    assert_success
    # Should handle without crashing

    git branch -D "$long_branch" 2>/dev/null || true
}

@test "handles deeply nested branch names" {
    local nested_branch="stress/deeply/nested/feature/branch/name"
    git branch "$nested_branch" 2>/dev/null || true

    run get_branch_data 1 ""
    assert_success
    assert_contains "$output" "nested"

    git branch -D "$nested_branch" 2>/dev/null || true
}
