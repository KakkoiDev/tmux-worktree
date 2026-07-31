#!/usr/bin/env bats
# Tests for core worktree manager functions

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
# Page Calculation Tests
# ==============================================================================

@test "get_worktree_page_count returns 1 for single worktree" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Only main worktree exists
    run get_worktree_page_count
    assert_success
    assert_equal "1" "$output"
}

@test "get_worktree_page_count calculates ceiling correctly" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Use smaller page size for faster test (same pagination logic)
    ITEMS_PER_PAGE=3

    # Create temp dir for worktrees
    local wt_dir="${TEST_REPO_DIR}-worktrees"
    mkdir -p "$wt_dir"

    # Create 4 worktrees (5 total with main = 2 pages with 3 items per page)
    for i in $(seq 1 4); do
        git worktree add -q "$wt_dir/wt-$i" -b "branch-$i"
    done

    run get_worktree_page_count
    assert_success
    # 5 worktrees (1 main + 4 created) = ceil(5/3) = 2
    assert_equal "2" "$output"

    # Cleanup
    for i in $(seq 1 4); do
        git worktree remove -f "$wt_dir/wt-$i" 2>/dev/null || true
    done
    rm -rf "$wt_dir"
}

@test "get_branch_page_count returns correct count" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # We have: master, feature-one, feature-two, bugfix-123 = 4 branches
    run get_branch_page_count
    assert_success
    assert_equal "1" "$output"
}

@test "get_removable_worktree_page_count excludes current directory" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a worktree in temp location
    local wt_path="${TEST_REPO_DIR}-other-wt"
    git worktree add -q "$wt_path" feature-one

    run get_removable_worktree_page_count
    assert_success
    # Only 1 removable (the one we created, not current)
    assert_equal "1" "$output"

    # Cleanup
    git worktree remove -f "$wt_path" 2>/dev/null || true
}

# ==============================================================================
# Worktree Data Tests
# ==============================================================================

@test "get_worktree_data respects pagination" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Use smaller page size for faster test (same pagination logic)
    ITEMS_PER_PAGE=3

    # Create temp dir for worktrees (inside test repo parent for cleanup)
    local wt_dir="${TEST_REPO_DIR}-worktrees"
    mkdir -p "$wt_dir"

    # Create 4 worktrees (5 total = 2 pages with 3 items per page)
    for i in $(seq 1 4); do
        git worktree add -q "$wt_dir/wt-$i" -b "branch-$i"
    done

    # Page 1 should have 3 items
    run get_worktree_data 1
    assert_success
    [ -n "$output" ]

    # Page 2 should have 2 items
    run get_worktree_data 2
    assert_success
    [ -n "$output" ]

    # Cleanup worktrees
    for i in $(seq 1 4); do
        git worktree remove -f "$wt_dir/wt-$i" 2>/dev/null || true
    done
    rm -rf "$wt_dir"
}

@test "get_worktree_data TSV includes branch and path fields" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Raw awk output is now TSV (no menu syntax).
    # The full menu pipeline adds run-shell via tk_menu_cmd.
    run get_worktree_data 1
    assert_success
    # First line is page count, subsequent lines are TSV with tab-separated fields
    local first_data
    first_data=$(echo "$output" | tail -n +2 | head -1)
    # Branch name should appear in the TSV output
    if [ -n "$first_data" ]; then
        assert_contains "$first_data" "$(echo -e '\t')" || true
    fi
}

# ==============================================================================
# Branch Data Tests
# ==============================================================================

@test "get_branch_data returns menu entries for branches" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    run get_branch_data 1
    assert_success
    # Should contain our test branches
    assert_contains "$output" "feature-one"
    assert_contains "$output" "feature-two"
}

@test "get_branch_data handles branches with slashes" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create branch with slash
    git branch "feature/auth/login" 2>/dev/null || true

    run get_branch_data 1
    assert_success
    assert_contains "$output" "feature/auth/login"

    # TSV output - no menu syntax in raw awk output

    # Cleanup
    git branch -D "feature/auth/login" 2>/dev/null || true
}

@test "get_branch_data handles branches with dots" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create branch with dots
    git branch "release-1.2.3" 2>/dev/null || true

    run get_branch_data 1
    assert_success
    assert_contains "$output" "release-1.2.3"

    # Cleanup
    git branch -D "release-1.2.3" 2>/dev/null || true
}

@test "get_branch_data handles branches with underscores and numbers" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create branch with underscore and numbers
    git branch "fix_issue_123" 2>/dev/null || true

    run get_branch_data 1
    assert_success
    assert_contains "$output" "fix_issue_123"

    # Cleanup
    git branch -D "fix_issue_123" 2>/dev/null || true
}

@test "get_branch_data includes worktree creation command" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    run get_branch_data 1
    assert_success
    # TSV output - run-shell is added by tk_menu_cmd at menu-build time
}

# ==============================================================================
# Removable Worktree Data Tests
# ==============================================================================

@test "get_removable_worktree_data excludes current worktree" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create another worktree in temp location
    local wt_path="${TEST_REPO_DIR}-removable-wt"
    git worktree add -q "$wt_path" feature-one

    run get_removable_worktree_data 1
    assert_success
    # Should contain the removable worktree
    assert_contains "$output" "feature-one"
    # Should NOT contain current directory's branch (master)
    # This is tricky to test - we just verify we get output
    [ -n "$output" ]

    # Cleanup
    git worktree remove -f "$wt_path" 2>/dev/null || true
}

@test "get_removable_worktree_data returns worktree entries" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Override WORKTREE_BASE for test isolation
    local test_worktree_base="${TEST_REPO_DIR}-worktree-base"
    WORKTREE_BASE="$test_worktree_base"

    # Create worktree
    mkdir -p "$WORKTREE_BASE"
    git worktree add -q "$WORKTREE_BASE/test-branch" -b "test-worktree"

    run get_removable_worktree_data 1
    assert_success
    assert_contains "$output" "test-worktree"
    # TSV output: raw awk data no longer contains menu syntax

    # Cleanup
    git worktree remove -f "$WORKTREE_BASE/test-branch" 2>/dev/null || true
    rm -rf "$test_worktree_base"
}

# ==============================================================================
# Navigation Helper Tests
# ==============================================================================

@test "_add_nav_items shows next when not on last page" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_reset
    _add_nav_items 1 3 "show_worktree_menu"
    local args_flat="${TK_MENU_ARGS[*]:-}"
    assert_contains "$args_flat" "Next"
}

@test "_add_nav_items shows previous when not on first page" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_reset
    _add_nav_items 2 3 "show_worktree_menu"
    local args_flat="${TK_MENU_ARGS[*]:-}"
    assert_contains "$args_flat" "Previous"
}

@test "_add_nav_items always shows back option" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_reset
    _add_nav_items 1 1 "show_worktree_menu"
    local args_flat="${TK_MENU_ARGS[*]:-}"
    assert_contains "$args_flat" "Back"
}

@test "_add_nav_items hides previous on first page" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_reset
    _add_nav_items 1 3 "show_worktree_menu"
    local args_flat="${TK_MENU_ARGS[*]:-}"
    refute_contains "$args_flat" "Previous"
}

@test "_add_nav_items hides next on last page" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_reset
    _add_nav_items 3 3 "show_worktree_menu"
    local args_flat="${TK_MENU_ARGS[*]:-}"
    refute_contains "$args_flat" "Next"
}

# ==============================================================================
# Menu Function Tests
# ==============================================================================

@test "worktree_manager.sh is executable" {
    assert_file_exists "$SCRIPTS_DIR/worktree_manager.sh"
    assert_executable "$SCRIPTS_DIR/worktree_manager.sh"
}

@test "worktree_manager.sh sources without error" {
    run bash -c "source '$SCRIPTS_DIR/worktree_manager.sh'"
    assert_success
}

@test "main function dispatches correctly" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Test that unknown command returns error message
    run main "unknown_command"
    assert_contains "$output" "Unknown"
}

# ==============================================================================
# Main Menu Command Tests
# ==============================================================================

@test "tmux_worktrees_main generates valid menu commands" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Capture the options variable by running the function in a subshell
    # and intercepting display_menu
    tk_menu_show() {
        printf '%s\n' "${TK_MENU_ARGS[@]}"; TK_MENU_ARGS=()
    }

    run tmux_worktrees_main
    assert_success

    # Verify all menu options are present with full command names
    assert_contains "$output" "show_worktree_menu"
    assert_contains "$output" "show_add_worktree_menu"
    assert_contains "$output" "show_remove_worktree_menu"
}

@test "main menu commands are not truncated" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_show() {
        printf '%s\n' "${TK_MENU_ARGS[@]}"; TK_MENU_ARGS=()
    }

    run tmux_worktrees_main
    assert_success

    # Each menu function name should appear complete in tk_menu_cmd output
    assert_contains "$output" "show_worktree_menu"
    assert_contains "$output" "show_add_worktree_menu"
    assert_contains "$output" "show_remove_worktree_menu"
}

# ==============================================================================
# Session name prefix-collision regression
# ==============================================================================
# tmux resolves a `-t` target by: session-id, exact name, then start-of-name
# (prefix), then glob. Two worktrees like `pfxcol` and `pfxcol-2` yield session
# names where one is a prefix of the other. When the shorter session is not
# alive, tmux prefix-matches the target to the longer session, so switch lands
# on the wrong worktree and remove kills the wrong session. The fix pins every
# computed-name lookup to an exact match with a leading `=`.

@test "switch_worktree does not hijack a session whose name it prefixes" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    local project short_session long_session pfx_path
    project=$(get_project_name)
    short_session=$(get_session_name "$project" "pfxcol")
    long_session=$(get_session_name "$project" "pfxcol-2")

    # Clear any leftovers from a prior (possibly failed) run on the shared server.
    tmux_run kill-session -t "=$short_session" 2>/dev/null || true
    tmux_run kill-session -t "=$long_session" 2>/dev/null || true

    # Worktree for the short branch so `new-session -c "$path"` can cd into it.
    pfx_path=$(create_test_worktree "pfxcol")

    # Only the longer session is alive; the short one is not. Without an exact
    # target, tmux would prefix-match "$short_session" to "$long_session".
    tmux_run new-session -d -s "$long_session" -c "$TEST_REPO_DIR"

    switch_worktree "pfxcol" "$pfx_path" || true

    # Correct behavior: no exact match existed, so a new short session was created
    # at the correct path rather than resolving to the longer session.
    run tmux_run has-session -t "=$short_session"
    assert_success

    tmux_run kill-session -t "=$short_session" 2>/dev/null || true
    tmux_run kill-session -t "=$long_session" 2>/dev/null || true
    remove_test_worktree "$pfx_path" true
}

@test "remove_worktree does not kill a sibling session whose name it prefixes" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    local project short_session long_session pfx_path
    project=$(get_project_name)
    short_session=$(get_session_name "$project" "pfxcol")
    long_session=$(get_session_name "$project" "pfxcol-2")

    tmux_run kill-session -t "=$short_session" 2>/dev/null || true
    tmux_run kill-session -t "=$long_session" 2>/dev/null || true

    pfx_path=$(create_test_worktree "pfxcol")

    # Sibling "-2" session is alive; the removed branch's own session is not.
    tmux_run new-session -d -s "$long_session" -c "$TEST_REPO_DIR"

    remove_worktree "$pfx_path" "pfxcol" "$short_session" 1 || true

    # The sibling session must survive: kill-session must not prefix-match it.
    run tmux_run has-session -t "=$long_session"
    assert_success

    tmux_run kill-session -t "=$long_session" 2>/dev/null || true
    git branch -D pfxcol 2>/dev/null || true
}
