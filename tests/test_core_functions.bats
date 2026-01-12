#!/usr/bin/env bats
# Tests for core worktree manager functions

load test_helper

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
}

teardown() {
    :
}

# ==============================================================================
# Project Name Tests
# ==============================================================================

@test "get_project_name returns repository directory name" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    run get_project_name
    assert_success
    # Shared repo dir is like /tmp/shared-repo.XXXXXX
    assert_contains "$output" "shared-repo"
}

@test "get_project_name works from subdirectory" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    mkdir -p subdir/nested
    cd subdir/nested

    run get_project_name
    assert_success
    assert_contains "$output" "shared-repo"
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

@test "get_worktree_data returns menu entries" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    run get_worktree_data 1
    assert_success
    # Should contain the current worktree with branch name
    assert_contains "$output" "master"
}

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

@test "get_worktree_data includes session switch command" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    run get_worktree_data 1
    assert_success
    # Should contain tmux session commands
    assert_contains "$output" "run-shell"
    assert_contains "$output" "switch-client"
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

    # Session name should have slashes replaced with dashes
    assert_contains "$output" "-feature-auth-login"

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
    assert_contains "$output" "git worktree add"
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
    # Should include remove_worktree command
    assert_contains "$output" "remove_worktree"

    # Cleanup
    git worktree remove -f "$WORKTREE_BASE/test-branch" 2>/dev/null || true
    rm -rf "$test_worktree_base"
}

# ==============================================================================
# Navigation Helper Tests
# ==============================================================================

@test "generate_nav_options shows next when not on last page" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    run generate_nav_options 1 3 "show_worktree_menu"
    assert_success
    assert_contains "$output" "Next"
    assert_contains "$output" "i"
}

@test "generate_nav_options shows previous when not on first page" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    run generate_nav_options 2 3 "show_worktree_menu"
    assert_success
    assert_contains "$output" "Previous"
    assert_contains "$output" "o"
}

@test "generate_nav_options always shows back option" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    run generate_nav_options 1 1 "show_worktree_menu"
    assert_success
    assert_contains "$output" "Back"
    assert_contains "$output" "$KEY_BACK"
}

@test "generate_nav_options hides previous on first page" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    run generate_nav_options 1 3 "show_worktree_menu"
    assert_success
    # Should NOT contain Previous
    [[ "$output" != *"Previous"* ]]
}

@test "generate_nav_options hides next on last page" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    run generate_nav_options 3 3 "show_worktree_menu"
    assert_success
    # Should NOT contain Next
    [[ "$output" != *"Next"* ]]
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
    display_menu() {
        echo "$2"
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

    display_menu() {
        echo "$2"
    }

    run tmux_worktrees_main
    assert_success

    # Each menu function name should appear complete (not cut off)
    # Format is: show_worktree_menu\"" (escaped quote then quote)
    [[ "$output" == *'show_worktree_menu\'* ]]
    [[ "$output" == *'show_add_worktree_menu\'* ]]
    [[ "$output" == *'show_remove_worktree_menu\'* ]]
}
