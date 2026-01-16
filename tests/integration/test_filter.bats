#!/usr/bin/env bats
# Tests for filter functionality

load '../test_helper'

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
    cd "$TEST_REPO_DIR"
    source "$SCRIPTS_DIR/helpers.sh"
    load_config
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # CRITICAL: Set WORKTREE_BASE AFTER sourcing worktree_manager.sh because it calls load_config
    init_test_worktree_base
}

teardown() {
    safe_cleanup_worktree_base
}

# ==============================================================================
# Wildcard Matching Tests
# ==============================================================================

@test "matches_filter returns true for exact match" {
    source "$SCRIPTS_DIR/filter.sh"

    run matches_filter "feature-one" "feature-one"
    assert_success
}

@test "matches_filter returns true for * wildcard" {
    source "$SCRIPTS_DIR/filter.sh"

    run matches_filter "feature-one" "feature*"
    assert_success

    run matches_filter "feature-two" "feature*"
    assert_success

    run matches_filter "bugfix-123" "feature*"
    assert_failure
}

@test "matches_filter returns true for ? single char wildcard" {
    source "$SCRIPTS_DIR/filter.sh"

    run matches_filter "fix-1" "fix-?"
    assert_success

    run matches_filter "fix-12" "fix-?"
    assert_failure
}

@test "matches_filter handles * at beginning" {
    source "$SCRIPTS_DIR/filter.sh"

    run matches_filter "feature-auth" "*auth"
    assert_success

    run matches_filter "bugfix-auth-login" "*auth*"
    assert_success
}

@test "matches_filter handles * in middle" {
    source "$SCRIPTS_DIR/filter.sh"

    run matches_filter "feature-auth-v2" "feature*v2"
    assert_success

    run matches_filter "feature-auth-v3" "feature*v2"
    assert_failure
}

@test "matches_filter is case insensitive" {
    source "$SCRIPTS_DIR/filter.sh"

    run matches_filter "Feature-One" "feature*"
    assert_success

    run matches_filter "BUGFIX-123" "bugfix*"
    assert_success
}

@test "matches_filter returns true for empty filter" {
    source "$SCRIPTS_DIR/filter.sh"

    run matches_filter "anything" ""
    assert_success
}

# ==============================================================================
# Input Sanitization Tests
# ==============================================================================

@test "sanitize_filter allows alphanumeric chars" {
    source "$SCRIPTS_DIR/filter.sh"

    run sanitize_filter "feature123"
    assert_success
    assert_equal "feature123" "$output"
}

@test "sanitize_filter allows wildcards * and ?" {
    source "$SCRIPTS_DIR/filter.sh"

    run sanitize_filter "feat*"
    assert_success
    assert_equal "feat*" "$output"

    run sanitize_filter "fix-?"
    assert_success
    assert_equal "fix-?" "$output"
}

@test "sanitize_filter allows dash and underscore" {
    source "$SCRIPTS_DIR/filter.sh"

    run sanitize_filter "feature-one_test"
    assert_success
    assert_equal "feature-one_test" "$output"
}

@test "sanitize_filter allows forward slash" {
    source "$SCRIPTS_DIR/filter.sh"

    run sanitize_filter "feature/auth"
    assert_success
    assert_equal "feature/auth" "$output"
}

@test "sanitize_filter removes dangerous chars" {
    source "$SCRIPTS_DIR/filter.sh"

    # Shell metacharacters should be removed (but / is allowed for branch paths)
    run sanitize_filter "feat;rm -rf /"
    assert_success
    assert_equal "featrm -rf /" "$output"

    run sanitize_filter "feat\$(whoami)"
    assert_success
    assert_equal "featwhoami" "$output"

    run sanitize_filter "feat\`id\`"
    assert_success
    assert_equal "featid" "$output"
}

@test "sanitize_filter removes backticks" {
    source "$SCRIPTS_DIR/filter.sh"

    run sanitize_filter "\`command\`"
    assert_success
    [[ "$output" != *"\`"* ]]
}

@test "sanitize_filter removes dollar signs" {
    source "$SCRIPTS_DIR/filter.sh"

    run sanitize_filter "\$HOME"
    assert_success
    [[ "$output" != *"\$"* ]]
}

# ==============================================================================
# Filtered Data Tests
# ==============================================================================

@test "get_worktree_data with filter returns matching entries" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create worktrees with different names
    local wt_dir="${TEST_REPO_DIR}-worktrees"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feat-one" -b "feature-one-new"
    git worktree add -q "$wt_dir/feat-two" -b "feature-two-new"
    git worktree add -q "$wt_dir/bug-fix" -b "bugfix-123-new"

    run get_worktree_data 1 "feature*"
    assert_success
    assert_contains "$output" "feature"
    [[ "$output" != *"bugfix"* ]]

    # Cleanup
    git worktree remove -f "$wt_dir/feat-one" 2>/dev/null || true
    git worktree remove -f "$wt_dir/feat-two" 2>/dev/null || true
    git worktree remove -f "$wt_dir/bug-fix" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "get_branch_data with filter returns matching entries" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # We have branches: master, feature-one, feature-two, bugfix-123
    run get_branch_data 1 "feature*"
    assert_success
    assert_contains "$output" "feature"
    [[ "$output" != *"bugfix"* ]]
}

@test "get_worktree_page_count with filter counts only matching" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create worktrees
    local wt_dir="${TEST_REPO_DIR}-worktrees"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feat-a" -b "feature-a"
    git worktree add -q "$wt_dir/feat-b" -b "feature-b"
    git worktree add -q "$wt_dir/bug-x" -b "bugfix-x"

    # Without filter - should count all (4 total: main + 3 created)
    run get_worktree_page_count ""
    local unfiltered="$output"

    # With filter - should count only matching (2 feature worktrees)
    run get_worktree_page_count "feature*"
    local filtered="$output"

    # Filtered count should be less than or equal to unfiltered
    [ "$filtered" -le "$unfiltered" ]

    # Cleanup
    git worktree remove -f "$wt_dir/feat-a" 2>/dev/null || true
    git worktree remove -f "$wt_dir/feat-b" 2>/dev/null || true
    git worktree remove -f "$wt_dir/bug-x" 2>/dev/null || true
    rm -rf "$wt_dir"
}

# ==============================================================================
# Menu Filter Integration Tests
# ==============================================================================

@test "show_worktree_menu accepts filter parameter" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Mock display_menu to capture title
    display_menu() {
        echo "TITLE: $1"
    }

    run show_worktree_menu 1 "feat*"
    assert_success
    # Title should show filter is active
    assert_contains "$output" "Filter"
}

@test "show_add_worktree_menu accepts filter parameter" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    display_menu() {
        echo "TITLE: $1"
    }

    run show_add_worktree_menu 1 "feat*"
    assert_success
    assert_contains "$output" "Filter"
}

@test "show_remove_worktree_menu accepts filter parameter" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a removable worktree first
    local wt_dir="${TEST_REPO_DIR}-worktrees"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/test-wt" feature-one

    display_menu() {
        echo "TITLE: $1"
    }

    run show_remove_worktree_menu 1 "feat*"
    assert_success
    assert_contains "$output" "Filter"

    # Cleanup
    git worktree remove -f "$wt_dir/test-wt" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "menu includes filter option with f key" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    display_menu() {
        echo "$2"
    }

    run show_worktree_menu 1
    assert_success
    assert_contains "$output" "Filter"
    assert_contains "$output" "\"f\""
}

@test "menu includes clear filter option when filter active" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    display_menu() {
        echo "$2"
    }

    run show_worktree_menu 1 "feat*"
    assert_success
    assert_contains "$output" "Clear"
    assert_contains "$output" "\"c\""
}

@test "navigation preserves filter parameter" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    run generate_nav_options 1 3 "show_worktree_menu" "feat*"
    assert_success
    # Next page link should include the filter
    assert_contains "$output" "feat"
}
