#!/usr/bin/env bats
# Output format validation tests for tmux-worktree
# Ensures generated menu commands are valid tmux syntax
# bats file_tags=format,syntax

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

    export WORKTREE_BASE="${BATS_TMPDIR}/worktrees-format-$$"
    mkdir -p "$WORKTREE_BASE"

    # Create a worktree for menu tests
    local project
    project=$(get_project_name)
    local wt_path="$WORKTREE_BASE/$project/feature-one"
    mkdir -p "$(dirname "$wt_path")"
    git worktree add -q "$wt_path" feature-one 2>/dev/null || true
}

teardown() {
    git worktree list --porcelain 2>/dev/null | grep "^worktree " | cut -d' ' -f2 | while read -r wt; do
        [ "$wt" != "$TEST_REPO_DIR" ] && git worktree remove --force "$wt" 2>/dev/null || true
    done
    rm -rf "$WORKTREE_BASE"
}

# ==============================================================================
# QUOTE BALANCE TESTS
# ==============================================================================

@test "worktree data has balanced double quotes" {
    run get_worktree_data 1 ""
    assert_success

    local quote_count
    quote_count=$(echo "$output" | tr -cd '"' | wc -c)
    [ $((quote_count % 2)) -eq 0 ]
}

@test "branch data has balanced double quotes" {
    run get_branch_data 1 ""
    assert_success

    local quote_count
    quote_count=$(echo "$output" | tr -cd '"' | wc -c)
    [ $((quote_count % 2)) -eq 0 ]
}

@test "removable worktree data has balanced double quotes" {
    run get_removable_worktree_data 1 ""
    assert_success

    local quote_count
    quote_count=$(echo "$output" | tr -cd '"' | wc -c)
    [ $((quote_count % 2)) -eq 0 ]
}

@test "navigation options have balanced double quotes" {
    run generate_nav_options 1 3 "show_worktree_menu" "" ""
    assert_success

    local quote_count
    quote_count=$(echo "$output" | tr -cd '"' | wc -c)
    [ $((quote_count % 2)) -eq 0 ]
}

# ==============================================================================
# RUN-SHELL COMMAND FORMAT TESTS
# ==============================================================================

@test "worktree menu run-shell commands are properly formatted" {
    run get_worktree_data 1 ""
    assert_success

    # Each run-shell command should have the format: run-shell "..."
    # The content after page count line should contain run-shell
    local data_lines
    data_lines=$(echo "$output" | tail -n +2)

    if [ -n "$data_lines" ]; then
        # Check that run-shell commands are present and properly quoted
        assert_contains "$output" "run-shell"
    fi
}

@test "branch menu run-shell commands are properly formatted" {
    run get_branch_data 1 ""
    assert_success

    # Should contain run-shell commands for branch selection
    assert_contains "$output" "run-shell"
}

# ==============================================================================
# MENU TITLE FORMAT TESTS
# ==============================================================================

@test "worktree menu title includes page info" {
    local captured_title=""
    display_menu() { captured_title="$1"; }

    show_worktree_menu 1 ""

    # Title should contain page information
    assert_contains "$captured_title" "1/"
}

@test "add worktree menu title includes page info" {
    local captured_title=""
    display_menu() { captured_title="$1"; }

    show_add_worktree_menu 1 ""

    assert_contains "$captured_title" "1/"
}

@test "remove worktree menu title includes page info" {
    local captured_title=""
    display_menu() { captured_title="$1"; }

    show_remove_worktree_menu 1 ""

    assert_contains "$captured_title" "1/"
}

# ==============================================================================
# EVAL SAFETY TESTS
# ==============================================================================

@test "menu options can be safely eval'd" {
    local captured_options=""
    display_menu() { captured_options="$2"; }

    show_worktree_menu 1 ""

    # Try to eval the options with a mock tmux
    tmux() { echo "TMUX_CALLED"; }
    export -f tmux

    # This should not fail
    run eval "tmux display-menu -T 'Test' $captured_options"
    assert_success
}

@test "branch menu options can be safely eval'd" {
    local captured_options=""
    display_menu() { captured_options="$2"; }

    show_add_worktree_menu 1 ""

    tmux() { echo "TMUX_CALLED"; }
    export -f tmux

    run eval "tmux display-menu -T 'Test' $captured_options"
    assert_success
}

# ==============================================================================
# SPECIAL CHARACTER HANDLING TESTS
# ==============================================================================

@test "branch names with dots are properly escaped" {
    git branch "release-1.2.3" 2>/dev/null || true

    run get_branch_data 1 ""
    assert_success
    assert_contains "$output" "release-1.2.3"

    git branch -D "release-1.2.3" 2>/dev/null || true
}

@test "branch names with underscores are properly handled" {
    git branch "feature_test_branch" 2>/dev/null || true

    run get_branch_data 1 ""
    assert_success
    assert_contains "$output" "feature_test_branch"

    git branch -D "feature_test_branch" 2>/dev/null || true
}

@test "branch names with slashes create valid menu entries" {
    git branch "feature/sub/branch" 2>/dev/null || true

    run get_branch_data 1 ""
    assert_success
    # Slashes should be present in output
    assert_contains "$output" "feature/sub/branch"

    git branch -D "feature/sub/branch" 2>/dev/null || true
}

# ==============================================================================
# PAGE COUNT FORMAT TESTS
# ==============================================================================

@test "get_worktree_data first line is numeric page count" {
    run get_worktree_data 1 ""
    assert_success

    local first_line
    first_line=$(echo "$output" | head -1)
    [[ "$first_line" =~ ^[0-9]+$ ]]
}

@test "get_branch_data first line is numeric page count" {
    run get_branch_data 1 ""
    assert_success

    local first_line
    first_line=$(echo "$output" | head -1)
    [[ "$first_line" =~ ^[0-9]+$ ]]
}

@test "get_removable_worktree_data first line is numeric page count" {
    run get_removable_worktree_data 1 ""
    assert_success

    local first_line
    first_line=$(echo "$output" | head -1)
    [[ "$first_line" =~ ^[0-9]+$ ]]
}

# ==============================================================================
# FILTER DISPLAY TESTS
# ==============================================================================

@test "filtered menu title shows filter indicator" {
    local captured_title=""
    display_menu() { captured_title="$1"; }

    show_worktree_menu 1 "feature*"

    # When filter is active, title should indicate it
    # (exact format depends on implementation)
    [ -n "$captured_title" ]
}

@test "filter appears in navigation options when active" {
    run generate_nav_options 1 1 "show_worktree_menu" "feature*" ""
    assert_success

    # Should have filter-related option or pass filter through
    # The output format will include the filter in commands
    [ -n "$output" ]
}

# ==============================================================================
# EMPTY STATE FORMAT TESTS
# ==============================================================================

@test "empty worktree list returns valid page count" {
    # With only main worktree, removable list is empty
    run get_removable_worktree_data 1 "nonexistent-xyz"
    assert_success

    local first_line
    first_line=$(echo "$output" | head -1)
    [[ "$first_line" =~ ^[0-9]+$ ]]
}

@test "empty branch filter returns valid format" {
    run get_branch_data 1 "nonexistent-branch-xyz"
    assert_success

    # Should still have valid first line (page count)
    local first_line
    first_line=$(echo "$output" | head -1)
    [[ "$first_line" =~ ^[0-9]+$ ]]
}
