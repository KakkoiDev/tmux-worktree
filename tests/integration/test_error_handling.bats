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
    refute_contains "$output" ";"
    # The second assertion here used to be `[[ $out != *rm* ]] || [[ $out == *rm* ]]`,
    # a tautology with a comment explaining that rm is harmless text. It was not an
    # assertion. The function documents a specific character set it removes, so
    # assert that set instead: every one of them, individually, from an input that
    # contains it.
    local c
    for c in ';' '$' '`' '(' ')' '{' '}' '[' ']' '|' '&' '<' '>' '\' '"' "'"; do
        run sanitize_filter "safe${c}name"
        assert_success
        refute_contains "$output" "$c"
        assert_contains "$output" "safename"
    done
}

@test "sanitize_filter strips backticks" {
    run sanitize_filter 'test`whoami`'
    assert_success
    refute_contains "$output" '`'
}

@test "sanitize_filter strips dollar signs" {
    run sanitize_filter 'test$HOME'
    assert_success
    refute_contains "$output" '$'
}

# ==============================================================================
# MISSING RESOURCE TESTS
# ==============================================================================

@test "remove_worktree handles missing worktree gracefully" {
    # Mock the menu refresh
    show_remove_worktree_menu() { :; }

    # Try to remove non-existent worktree
    run remove_worktree "/nonexistent/path" "fake-branch" "fake-session" 1 2>&1

    # Either it handled the missing worktree (status 0) or it surfaced git's own
    # complaint. Both are acceptable; dying on a signal is not, and the old bare
    # compound could not distinguish those because it never failed.
    assert_no_crash
    if [[ "$status" -ne 0 ]]; then
        assert_match_re "$output" 'fatal|not a'
    fi
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

    # Empty branch should fail or be rejected.
    run create_new_worktree ""
    # The old line ended in `|| true`, so it asserted nothing whatsoever, and the
    # stated intent ("doesn't create invalid state") was never checked at all.
    # Check it: no crash, and no branch or worktree brought into existence for an
    # empty name.
    assert_no_crash
    refute_contains "$(git worktree list)" "$(pwd)/"
    refute_match_re "$(git branch --format='%(refname:short)')" '^[[:space:]]*$'
}

@test "create_new_worktree strips a trailing slash from the branch name" {
    local branch="feature/test-trailing"
    local project
    project=$(get_project_name)
    local expected_path="$WORKTREE_BASE/$project/$branch"

    # User typed a trailing slash; git would reject it raw, but it must be
    # normalized away and the worktree created under the slash-free name.
    (create_new_worktree "feature/test-trailing/") 2>/dev/null || true

    run git branch --list "$branch"
    assert_contains "$output" "$branch"
    [ -d "$expected_path" ]

    git worktree remove --force "$expected_path" 2>/dev/null || true
    git branch -D "$branch" 2>/dev/null || true
}

@test "create_new_worktree rejects an invalid branch name with a clear message" {
    # Capture status-bar messages on stdout (global stub suppresses them).
    tmux() {
        if [ "$1" = "display-message" ]; then
            shift
            echo "$*"
        fi
        return 0
    }
    export -f tmux

    run create_new_worktree "bad~name"
    assert_failure
    assert_contains "$output" "Invalid branch name"
    assert_not_contains "$output" "Preparing"
}

@test "_git_error_summary surfaces the fatal line, not the progress line" {
    run _git_error_summary $'Preparing worktree (new branch x)\nfatal: invalid reference: x'
    assert_contains "$output" "fatal: invalid reference"
    assert_not_contains "$output" "Preparing"
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

@test "_add_nav_items handles page 1 of 1" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_reset
    _add_nav_items 1 1 "show_worktree_menu"
    local args_flat="${TK_MENU_ARGS[*]:-}"
    # Should have Back option but no Next/Previous
    assert_contains "$args_flat" "Back"
    refute_contains "$args_flat" "Next"
    refute_contains "$args_flat" "Previous"
}

@test "_add_nav_items handles middle page" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_reset
    _add_nav_items 2 3 "show_worktree_menu"
    local args_flat="${TK_MENU_ARGS[*]:-}"
    # Should have both Next and Previous
    assert_contains "$args_flat" "Next"
    assert_contains "$args_flat" "Previous"
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
    # The docstring says "without creating worktree", so assert that, not the old
    # `[[ $status -eq 0 ]] || [[ $status -ne 0 ]]`, which is true for every
    # possible status including a segfault.
    assert_no_crash
    refute_dir "$non_git_dir/test-branch"
    run git -C "$non_git_dir" rev-parse --git-dir
    assert_failure

    cd "$TEST_REPO_DIR"
    rm -rf "$non_git_dir"
}

@test "get_project_name handles non-git directory gracefully" {
    local non_git_dir="${BATS_TMPDIR}/non-git-project-$$"
    mkdir -p "$non_git_dir"
    cd "$non_git_dir"

    run get_project_name
    # The comment listed three acceptable outcomes - fail, empty, or the directory
    # name as a fallback - and then asserted none of them. Assert exactly those:
    # anything else, including a stray git error leaking into stdout, is a bug.
    assert_no_crash
    if [[ "$status" -eq 0 ]]; then
        assert_one_of "$output" "" "$(basename "$non_git_dir")"
    fi

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
        refute_contains "$output" ";"
        refute_contains "$output" '`'
        refute_contains "$output" '$('
        refute_contains "$output" '$'
        refute_contains "$output" "|"
        refute_contains "$output" "&"
    done
}
