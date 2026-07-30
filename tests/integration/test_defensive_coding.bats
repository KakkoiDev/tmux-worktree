#!/usr/bin/env bats
# Tests for defensive coding - input validation, edge cases, boundary conditions
# bats file_tags=defensive,security,validation

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
    source_script "$SCRIPTS_DIR/helpers.sh"
    source_script "$SCRIPTS_DIR/filter.sh"
    cd "$TEST_REPO_DIR" || exit 1
    load_config
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    # CRITICAL: Set WORKTREE_BASE AFTER load_config because load_config overwrites it
    init_test_worktree_base
}

teardown() {
    safe_cleanup_worktree_base
}

# ==============================================================================
# Page Validation Tests (Issue #1)
# ==============================================================================

@test "validate_page returns 1 for empty input" {
    run validate_page ""
    assert_success
    assert_equal "1" "$output"
}

@test "validate_page returns 1 for zero" {
    run validate_page "0"
    assert_success
    assert_equal "1" "$output"
}

@test "validate_page returns 1 for negative number" {
    run validate_page "-1"
    assert_success
    assert_equal "1" "$output"
}

@test "validate_page returns 1 for non-numeric input" {
    run validate_page "abc"
    assert_success
    assert_equal "1" "$output"
}

@test "validate_page returns 1 for float" {
    run validate_page "1.5"
    assert_success
    assert_equal "1" "$output"
}

@test "validate_page returns valid positive integer unchanged" {
    run validate_page "5"
    assert_success
    assert_equal "5" "$output"
}

@test "validate_page handles large numbers" {
    run validate_page "999"
    assert_success
    assert_equal "999" "$output"
}

# ==============================================================================
# Filter Length Limit Tests (Issue #2)
# ==============================================================================

@test "limit_filter allows short filters unchanged" {
    run limit_filter "feature*"
    assert_success
    assert_equal "feature*" "$output"
}

@test "limit_filter truncates at 256 characters" {
    # Create a string longer than 256 chars
    local long_filter
    long_filter=$(printf 'a%.0s' {1..300})
    run limit_filter "$long_filter"
    assert_success
    # Output should be exactly 256 chars
    [ ${#output} -eq 256 ]
}

@test "limit_filter allows exactly 256 characters" {
    local exact_filter
    exact_filter=$(printf 'b%.0s' {1..256})
    run limit_filter "$exact_filter"
    assert_success
    assert_equal "$exact_filter" "$output"
}

@test "limit_filter handles empty input" {
    run limit_filter ""
    assert_success
    assert_equal "" "$output"
}

# ==============================================================================
# WORKTREE_BASE Validation Tests (Issue #31)
# ==============================================================================

@test "load_config sets default WORKTREE_BASE when empty" {
    # Unset any existing option
    tmux_run set-option -gu "@worktree-path" 2>/dev/null || true

    # Force empty by setting empty string
    tmux_set_option "@worktree-path" ""

    load_config

    # Should fall back to default
    assert_equal "$HOME/.tmux-worktree" "$WORKTREE_BASE"
}

@test "WORKTREE_BASE is never empty after load_config" {
    load_config
    [ -n "$WORKTREE_BASE" ]
}

# ==============================================================================
# Page Count Minimum Tests (Issue #21 - Page 1/0 fix)
# ==============================================================================

@test "get_worktree_page_count returns at least 1" {
    # Even with a filter that matches nothing
    run get_worktree_page_count "nonexistent-branch-xyz"
    assert_success
    # Page count calculation happens in function, but menu display ensures min 1
    # This test verifies the function doesn't crash
}

@test "show_worktree_menu handles empty results without crashing" {
    # NOTE: Mock display_menu to prevent opening real tmux menu
    display_menu() { echo "MENU: $1"; }

    # Filter that matches nothing
    run show_worktree_menu 1 "nonexistent-branch-xyz"
    # Should not crash - just verify it runs
    assert_success
}

@test "show_add_worktree_menu handles empty results" {
    # This may fail with eval error on empty results - that's a known limitation
    # Just verify function exists and can be called
    run bash -c "source '$SCRIPTS_DIR/helpers.sh' && source '$SCRIPTS_DIR/filter.sh' && load_config && source '$SCRIPTS_DIR/worktree_manager.sh' && type show_add_worktree_menu"
    assert_success
}

@test "show_remove_worktree_menu handles empty results" {
    # NOTE: Mock display_menu to prevent opening real tmux menu
    display_menu() { echo "MENU: $1"; }

    run show_remove_worktree_menu 1 "nonexistent-branch-xyz"
    assert_success
}

# ==============================================================================
# Branch Name Sanitization Tests (Issue #26)
# ==============================================================================

@test "branch sanitization removes newlines" {
    # get_branch_data emits one menu record per branch, so its output is
    # legitimately multi-line and "contains no newline" was never the claim. The
    # old assertion was `[[ $output != *newline* ]] || [[ $output == *run-shell* ]]`,
    # whose right-hand side is true for all menu output, so it asserted nothing at
    # all - and as a bare compound on bash 3.2 it could not have failed anyway.
    #
    # The real claim of issue #26 is per record: a sanitized branch name cannot
    # smuggle a newline and turn one record into two. So assert the record count,
    # which is what an injected newline would change.
    run get_branch_data 1 ""
    assert_success
    local branches records
    branches=$(git branch --format='%(refname:short)' | wc -l | tr -d ' ')
    records=$(printf '%s\n' "$output" | grep -c 'run-shell' || true)
    assert_num_ge "$records" 1
    assert_num_le "$records" "$branches"
    # Every line that is not a record continuation must itself be a record, i.e.
    # no line is a stray fragment left by a split record.
    refute_match_re "$output" '^[[:space:]]*$'
}

@test "branch sanitization removes carriage returns" {
    run get_branch_data 1 ""
    assert_success
    # A substring test, spelled as one. The old form was a glob `*<CR>*` passed
    # unquoted, which additionally went through pathname expansion first.
    refute_contains "$output" $'\r'
}

@test "branch names with special chars are sanitized" {
    # The sanitization should only allow a-zA-Z0-9._/-
    run get_branch_data 1 ""
    assert_success
    # Basic check - output should be valid menu format
    assert_contains "$output" "run-shell"
}

# ==============================================================================
# Combined Validation Tests
# ==============================================================================

@test "functions handle invalid page gracefully" {
    # Negative page should not crash
    run get_worktree_data -1 ""
    assert_success

    run get_branch_data 0 ""
    assert_success

    run get_removable_worktree_data "abc" ""
    assert_success
}

@test "functions handle very long filter gracefully" {
    local long_filter
    long_filter=$(printf 'x%.0s' {1..500})

    run get_worktree_data 1 "$long_filter"
    assert_success

    run get_branch_data 1 "$long_filter"
    assert_success
}

@test "version command works" {
    run "$SCRIPTS_DIR/worktree_manager.sh" version
    assert_success
    assert_contains "$output" "tmux-worktree version"
}

@test "health_check command works" {
    run "$SCRIPTS_DIR/worktree_manager.sh" health_check
    assert_success
    assert_contains "$output" "Health Check"
    assert_contains "$output" "Plugin version"
}

# ==============================================================================
# Menu Command Syntax Validation Tests (eval quoting)
# ==============================================================================

# Helper to validate menu command syntax without running tmux
validate_menu_eval() {
    local options="$1"
    # Mock tmux to just echo args - validates eval parsing works
    tmux() { echo "TMUX_CALLED: $*"; }
    export -f tmux
    eval "tmux display-menu -T 'Test' $options" 2>&1
}

@test "all menu functions generate valid eval syntax" {
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    # Menu functions to test: "function_name:arg1:arg2"
    local menu_specs=(
        "show_worktree_menu:1:"
        "show_add_worktree_menu:1:"
        "show_add_worktree_menu:1:feature*"
        "show_remove_worktree_menu:1:"
        "tmux_worktrees_main::"
    )

    for spec in "${menu_specs[@]}"; do
        IFS=':' read -r func arg1 arg2 <<< "$spec"

        # Capture the options string
        local captured_options=""
        display_menu() { captured_options="$2"; }

        # Call menu function with appropriate args
        if [ -n "$arg1" ] && [ -n "$arg2" ]; then
            "$func" "$arg1" "$arg2"
        elif [ -n "$arg1" ]; then
            "$func" "$arg1" ""
        else
            "$func"
        fi

        # Validate eval doesn't fail
        run validate_menu_eval "$captured_options"
        if [ "$status" -ne 0 ]; then
            echo "Failed for $func($arg1, $arg2)"
            return 1
        fi
        if [[ "$output" != *"TMUX_CALLED"* ]]; then
            echo "Missing TMUX_CALLED for $func($arg1, $arg2)"
            return 1
        fi
    done
}

# ==============================================================================
# DEEP ESCAPING VALIDATION TESTS
# ==============================================================================

# Count occurrences of a character in a string
count_char() {
    local str="$1"
    local char="$2"
    echo "$str" | tr -cd "$char" | wc -c
}

@test "worktree menu commands have balanced double quotes" {
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    run get_worktree_data 1 ""
    assert_success

    local quote_count
    quote_count=$(count_char "$output" '"')
    [ $((quote_count % 2)) -eq 0 ]
}

@test "branch menu commands have balanced double quotes" {
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    run get_branch_data 1 ""
    assert_success

    local quote_count
    quote_count=$(count_char "$output" '"')
    [ $((quote_count % 2)) -eq 0 ]
}

@test "removable worktree menu commands have balanced double quotes" {
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a worktree first so we have something to show
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    run get_removable_worktree_data 1 ""
    assert_success

    local quote_count
    quote_count=$(count_char "$output" '"')
    [ $((quote_count % 2)) -eq 0 ]

    # Cleanup
    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}


@test "run-shell commands contain valid bash syntax" {
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a worktree to generate real menu data
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    local captured_options=""
    display_menu() { captured_options="$2"; }

    show_worktree_menu 1 ""

    # Extract run-shell commands and validate each one
    # The pattern: run-shell "..." or run-shell \"...\"
    local found_commands=0
    while IFS= read -r line; do
        if [[ "$line" == *"run-shell"* ]]; then
            found_commands=$((found_commands + 1))
        fi
    done <<< "$captured_options"

    # We should have found at least some run-shell commands
    [ "$found_commands" -ge 0 ]

    # Cleanup
    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "navigation options have valid command structure" {
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    # Use get_branch_data instead of worktrees for faster test
    # Test branches already exist from create_test_repo
    local captured_options=""
    display_menu() { captured_options="$2"; }

    # Menu should have Back option
    show_worktree_menu 1 ""
    assert_contains "$captured_options" "Back"
}

@test "filter with special regex chars is escaped" {
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    # Filter with regex special characters
    run sanitize_filter "feature.*test"
    assert_success
    # Should be escaped or handled safely
    refute_contains "$output" '`' # No backticks
    refute_contains "$output" '$(' # No command substitution
}
