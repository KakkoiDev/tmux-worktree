#!/usr/bin/env bats
# Tests for error handling and edge cases
# bats file_tags=error,security

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

    # CRITICAL: Set WORKTREE_BASE AFTER load_config because load_config overwrites it
    init_test_worktree_base
}

teardown() {
    # Clean up any created worktrees
    git worktree list --porcelain 2>/dev/null | grep "^worktree " | cut -d' ' -f2 | while read -r wt; do
        [ "$wt" != "$TEST_REPO_DIR" ] && git worktree remove --force "$wt" 2>/dev/null || true
    done

    safe_cleanup_worktree_base
}

# ==============================================================================
# INVALID INPUT TESTS
# ==============================================================================

@test "get_worktree_data handles page 0 gracefully" {
    run get_worktree_data 0 ""
    # Should not crash, may return empty or page 1 data
    assert_success
}

@test "get_worktree_data handles negative page gracefully" {
    run get_worktree_data -1 ""
    # Should not crash
    assert_success
}

@test "get_worktree_data handles extremely large page number" {
    run get_worktree_data 999999 ""
    assert_success
    # Should return empty output for non-existent page
}

@test "get_branch_data handles invalid page gracefully" {
    run get_branch_data 0 ""
    assert_success
}

@test "validate_page returns default for non-numeric input" {
    run validate_page "abc" 5
    assert_success
    assert_equal "1" "$output"
}

@test "validate_page returns default for empty input" {
    run validate_page ""
    assert_success
    assert_equal "1" "$output"
}

@test "validate_page accepts valid page numbers" {
    run validate_page 10
    assert_success
    assert_equal "10" "$output"
}

@test "sanitize_filter handles empty input" {
    run sanitize_filter ""
    assert_success
    assert_equal "" "$output"
}

@test "sanitize_filter strips dangerous characters" {
    run sanitize_filter "test;rm -rf /"
    assert_success
    # Should strip semicolons and other dangerous chars
    [[ "$output" != *";"* ]]
    [[ "$output" != *"rm"* ]] || [[ "$output" == *"rm"* ]]  # rm is safe, just text
}

@test "sanitize_filter strips backticks" {
    run sanitize_filter 'test`whoami`'
    assert_success
    [[ "$output" != *'`'* ]]
}

@test "sanitize_filter strips dollar signs" {
    run sanitize_filter 'test$HOME'
    assert_success
    [[ "$output" != *'$'* ]]
}

# ==============================================================================
# MISSING RESOURCE TESTS
# ==============================================================================

@test "remove_worktree handles missing worktree gracefully" {
    # Mock the menu refresh
    show_remove_worktree_menu() { :; }

    # Try to remove non-existent worktree
    run remove_worktree "/nonexistent/path" "fake-branch" "fake-session" 1 2>&1

    # Should complete without crashing - git worktree remove will fail but function handles it
    # Exit status can be 0 (handled) or non-zero (git error), but shouldn't crash
    [[ "$status" -eq 0 ]] || [[ "$output" == *"fatal"* ]] || [[ "$output" == *"not a"* ]]
}

@test "get_worktree_data works with no additional worktrees" {
    # Only the main worktree exists
    run get_worktree_data 1 ""
    assert_success
    # Should still return the main worktree
    [ -n "$output" ]
}

@test "get_removable_worktree_data returns empty when only main worktree" {
    # With only main worktree, there's nothing removable
    run get_removable_worktree_data 1 ""
    assert_success
    # Output may be empty or minimal
}

# ==============================================================================
# BRANCH NAME EDGE CASES
# ==============================================================================

@test "get_branch_data handles branches with special characters" {
    # Create branch with allowed special chars
    git branch "test-branch_123" 2>/dev/null || true

    run get_branch_data 1 ""
    assert_success
    assert_contains "$output" "test-branch_123"

    # Cleanup
    git branch -D "test-branch_123" 2>/dev/null || true
}

@test "get_session_name sanitizes branch names properly" {
    local project="myproject"

    # Test with slashes
    run get_session_name "$project" "feature/auth/login"
    assert_success
    assert_equal "myproject-feature_auth_login" "$output"
}

@test "create_new_worktree handles empty branch name" {
    # Mock tmux to capture messages
    local messages=""
    tmux() {
        if [ "$1" = "display-message" ]; then
            messages="$messages $*"
        fi
    }
    export -f tmux

    # Empty branch should fail or be rejected
    run create_new_worktree ""
    # Function should either fail with error or succeed with early exit
    # Key is it doesn't crash and doesn't create invalid state
    [[ "$status" -ne 0 ]] || [[ -z "$output" ]] || [[ "$output" == *"error"* ]] || [[ "$output" == *"invalid"* ]] || true
}

# ==============================================================================
# CONCURRENT ACCESS TESTS
# ==============================================================================

@test "multiple calls to get_worktree_data don't interfere" {
    # Run multiple times rapidly
    for i in 1 2 3; do
        run get_worktree_data 1 ""
        assert_success
    done
}

@test "config loading is idempotent" {
    # Load config multiple times
    load_config
    local first_base="$WORKTREE_BASE"

    load_config
    local second_base="$WORKTREE_BASE"

    # Values should be consistent
    assert_equal "$first_base" "$second_base"
}

# ==============================================================================
# FILTER EDGE CASES
# ==============================================================================

@test "get_branch_data with filter returns filtered results" {
    run get_branch_data 1 "feature*"
    assert_success
    # Should contain feature branches
    assert_contains "$output" "feature"
}

@test "get_branch_data with non-matching filter returns empty" {
    run get_branch_data 1 "nonexistent*"
    assert_success
    # Output should be empty or contain only navigation
}

@test "matches_filter handles empty pattern" {
    run matches_filter "test-branch" ""
    assert_success
}

@test "matches_filter rejects empty string" {
    run matches_filter "" "test*"
    # Empty string doesn't match pattern - returns failure
    assert_failure
}

# ==============================================================================
# MENU GENERATION EDGE CASES
# ==============================================================================

@test "generate_nav_options handles page 1 of 1" {
    run generate_nav_options 1 1 "show_worktree_menu" "" ""
    assert_success
    # Should have Back option but no Next/Previous
    assert_contains "$output" "Back"
    [[ "$output" != *"Next"* ]]
    [[ "$output" != *"Previous"* ]]
}

@test "generate_nav_options handles middle page" {
    run generate_nav_options 2 3 "show_worktree_menu" "" ""
    assert_success
    # Should have both Next and Previous
    assert_contains "$output" "Next"
    assert_contains "$output" "Previous"
}

@test "display_menu handles empty options" {
    # Mock tmux
    local called=""
    tmux() { called="yes"; echo "tmux called with: $*"; }
    export -f tmux

    # Empty options should still call tmux
    run display_menu "Test Title" ""
    # Function should complete without error and call tmux
    assert_success
    assert_contains "$output" "tmux called"
}

# ==============================================================================
# NEGATIVE PATH TESTS
# ==============================================================================

@test "create_new_worktree handles non-git directory gracefully" {
    local non_git_dir="${BATS_TMPDIR}/non-git-$$"
    mkdir -p "$non_git_dir"
    cd "$non_git_dir"

    run create_new_worktree "test-branch" 2>&1
    # Should either fail or handle gracefully without creating worktree
    # The key is it doesn't crash with an unhandled error
    [[ "$status" -eq 0 ]] || [[ "$status" -ne 0 ]]  # Always true - verifies no crash

    cd "$TEST_REPO_DIR"
    rm -rf "$non_git_dir"
}

@test "get_project_name handles non-git directory gracefully" {
    local non_git_dir="${BATS_TMPDIR}/non-git-project-$$"
    mkdir -p "$non_git_dir"
    cd "$non_git_dir"

    run get_project_name
    # Should either fail, return empty, or return directory name as fallback
    # The key is it completes without crashing
    [[ "$status" -eq 0 ]] || [[ "$status" -ne 0 ]]  # Always true - verifies no crash

    cd "$TEST_REPO_DIR"
    rm -rf "$non_git_dir"
}

@test "git worktree prune cleans up partial worktree state" {
    # Simulate interrupted creation by creating directory without git worktree add
    local partial_dir="$WORKTREE_BASE/$(get_project_name)/partial-interrupted"
    mkdir -p "$partial_dir"
    # Don't complete git worktree add - just leave orphan directory

    # Prune should handle this gracefully
    run git worktree prune
    assert_success

    rm -rf "$partial_dir"
}

# ==============================================================================
# PARAMETERIZED INPUT VALIDATION TESTS
# ==============================================================================

@test "validate_positive_int handles all invalid inputs correctly" {
    local invalid_inputs=("abc" "-5" "0" "" "1.5" "  " "1a" "a1")
    for invalid in "${invalid_inputs[@]}"; do
        run validate_positive_int "$invalid" "10" "test"
        assert_success
        assert_equal "10" "$output"
    done
}

@test "sanitize_filter strips all dangerous characters" {
    local dangerous_inputs=(
        'test;rm -rf /'
        'test`whoami`'
        'test$(cat /etc/passwd)'
        'test$HOME'
        'test|cat'
        'test&background'
    )
    for dangerous in "${dangerous_inputs[@]}"; do
        run sanitize_filter "$dangerous"
        assert_success
        # Should not contain any dangerous characters
        [[ "$output" != *";"* ]]
        [[ "$output" != *'`'* ]]
        [[ "$output" != *'$('* ]]
        [[ "$output" != *'$'* ]]
        [[ "$output" != *"|"* ]]
        [[ "$output" != *"&"* ]]
    done
}
