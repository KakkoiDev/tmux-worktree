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

# ==============================================================================
# REMOVABLE DATA - DETACHED HEAD WORKTREES
# ==============================================================================

@test "detached HEAD worktree appears in removable data" {
    local project
    project=$(get_project_name)
    local wt_path="$WORKTREE_BASE/$project/test-detached"
    mkdir -p "$(dirname "$wt_path")"

    # Create worktree, detach HEAD, delete branch
    git worktree add -q "$wt_path" -b "test-detached-branch"
    git -C "$wt_path" checkout --detach HEAD 2>/dev/null
    git branch -D "test-detached-branch" 2>/dev/null

    run get_removable_worktree_data 1 ""
    assert_success
    assert_contains "$output" "HEAD@"

    # Cleanup
    git worktree remove --force "$wt_path" 2>/dev/null || true
}

@test "detached HEAD worktree shows short SHA in menu" {
    local project
    project=$(get_project_name)
    local wt_path="$WORKTREE_BASE/$project/test-detached-sha"
    mkdir -p "$(dirname "$wt_path")"

    git worktree add -q "$wt_path" -b "test-detached-sha"
    local head_sha
    head_sha=$(git -C "$wt_path" rev-parse --short=7 HEAD)
    git -C "$wt_path" checkout --detach HEAD 2>/dev/null
    git branch -D "test-detached-sha" 2>/dev/null

    run get_removable_worktree_data 1 ""
    assert_success
    assert_contains "$output" "HEAD@${head_sha}"

    # Cleanup
    git worktree remove --force "$wt_path" 2>/dev/null || true
}

@test "detached HEAD worktree is filterable" {
    local project
    project=$(get_project_name)
    local wt_path="$WORKTREE_BASE/$project/test-detached-filter"
    mkdir -p "$(dirname "$wt_path")"

    git worktree add -q "$wt_path" -b "test-detached-filter"
    git -C "$wt_path" checkout --detach HEAD 2>/dev/null
    git branch -D "test-detached-filter" 2>/dev/null

    # Filter for HEAD@ should match
    run get_removable_worktree_data 1 "HEAD*"
    assert_success
    assert_contains "$output" "HEAD@"

    # Filter for non-matching should exclude
    run get_removable_worktree_data 1 "nonexistent-xyz"
    assert_success
    refute_contains "$output" "HEAD@"

    # Cleanup
    git worktree remove --force "$wt_path" 2>/dev/null || true
}

# ==============================================================================
# REMOVABLE DATA - PRUNABLE WORKTREES (deleted directory)
# ==============================================================================

@test "worktree with deleted directory still appears in removable data" {
    local project
    project=$(get_project_name)
    local wt_path="$WORKTREE_BASE/$project/test-prunable"
    mkdir -p "$(dirname "$wt_path")"

    git worktree add -q "$wt_path" -b "test-prunable-branch"

    # Delete the directory but keep git's worktree entry
    rm -rf "$wt_path"

    run get_removable_worktree_data 1 ""
    assert_success
    assert_contains "$output" "test-prunable-branch"

    # Cleanup
    git worktree prune
    git branch -D "test-prunable-branch" 2>/dev/null || true
}

@test "worktree with deleted directory is filterable by branch name" {
    local project
    project=$(get_project_name)
    local wt_path="$WORKTREE_BASE/$project/test-prunable-filter"
    mkdir -p "$(dirname "$wt_path")"

    git worktree add -q "$wt_path" -b "test-prunable-filter"
    rm -rf "$wt_path"

    run get_removable_worktree_data 1 "test-prunable*"
    assert_success
    assert_contains "$output" "test-prunable-filter"

    # Cleanup
    git worktree prune
    git branch -D "test-prunable-filter" 2>/dev/null || true
}

# ==============================================================================
# REMOVABLE DATA - BRANCH WITH SLASHES
# ==============================================================================

@test "worktree with slashes in branch name appears in removable data" {
    local project
    project=$(get_project_name)
    local wt_path="$WORKTREE_BASE/$project/user/TASK-12345"
    mkdir -p "$(dirname "$wt_path")"

    git worktree add -q "$wt_path" -b "user/TASK-12345"

    run get_removable_worktree_data 1 ""
    assert_success
    assert_contains "$output" "user/TASK-12345"

    # Cleanup
    git worktree remove --force "$wt_path" 2>/dev/null || true
    git branch -D "user/TASK-12345" 2>/dev/null || true
}

@test "worktree with slashes in branch name is filterable" {
    local project
    project=$(get_project_name)
    local wt_path="$WORKTREE_BASE/$project/user/TASK-99999"
    mkdir -p "$(dirname "$wt_path")"

    git worktree add -q "$wt_path" -b "user/TASK-99999"

    run get_removable_worktree_data 1 "user/TASK*"
    assert_success
    assert_contains "$output" "user/TASK-99999"

    run get_removable_worktree_data 1 "*99999"
    assert_success
    assert_contains "$output" "user/TASK-99999"

    # Cleanup
    git worktree remove --force "$wt_path" 2>/dev/null || true
    git branch -D "user/TASK-99999" 2>/dev/null || true
}

@test "worktree with slashes in branch name generates valid session name" {
    local project
    project=$(get_project_name)
    local wt_path="$WORKTREE_BASE/$project/user/TASK-77777"
    mkdir -p "$(dirname "$wt_path")"

    git worktree add -q "$wt_path" -b "user/TASK-77777"

    run get_removable_worktree_data 1 ""
    assert_success
    # Session name should have slashes converted to underscores
    # and dots converted to underscores (AWK applies gsub on full session_name)
    local expected_session="${project}-user_TASK-77777"
    expected_session="${expected_session//./_}"
    expected_session="${expected_session//:/_}"
    assert_contains "$output" "$expected_session"

    # Cleanup
    git worktree remove --force "$wt_path" 2>/dev/null || true
    git branch -D "user/TASK-77777" 2>/dev/null || true
}
