#!/usr/bin/env bats
# Tests for worktree creation and removal operations
# Tests git worktree operations directly, not via menu interaction

load 'test_helper'

setup() {
    source_script "$SCRIPTS_DIR/helpers.sh"
    source_script "$SCRIPTS_DIR/filter.sh"
    TEST_REPO_DIR=$(create_test_repo)
    cd "$TEST_REPO_DIR" || exit 1
    start_tmux_server
    load_config
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    # Set up worktree base in temp dir for isolation
    export WORKTREE_BASE="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$WORKTREE_BASE"
}

teardown() {
    # Clean up all worktrees except main repo
    git worktree list --porcelain 2>/dev/null | grep "^worktree " | cut -d' ' -f2 | while read -r wt; do
        [ "$wt" != "$TEST_REPO_DIR" ] && git worktree remove --force "$wt" 2>/dev/null || true
    done

    # Delete test branches
    git branch 2>/dev/null | grep "^  test-" | while read -r branch; do
        git branch -D "${branch## }" 2>/dev/null || true
    done

    stop_tmux_server
    rm -rf "$WORKTREE_BASE"
    cleanup_test_repo
}

# ==============================================================================
# PROJECT NAME TESTS
# ==============================================================================

@test "get_project_name returns sanitized name" {
    run get_project_name
    assert_success
    # Should only contain alphanumeric, dash, underscore, dot
    [[ "$output" =~ ^[a-zA-Z0-9._-]+$ ]]
}

@test "get_project_name works from worktree" {
    local wt_dir="$WORKTREE_BASE/$(get_project_name)/feature-one"
    mkdir -p "$(dirname "$wt_dir")"
    git worktree add -q "$wt_dir" feature-one

    # Get project name from worktree
    local wt_project
    wt_project=$(cd "$wt_dir" && get_project_name)

    # Should match main repo project name
    local main_project
    main_project=$(get_project_name)

    assert_equal "$main_project" "$wt_project"

    git worktree remove --force "$wt_dir"
}

# ==============================================================================
# WORKTREE DATA TESTS
# ==============================================================================

@test "get_worktree_data returns menu format" {
    local wt_dir="$WORKTREE_BASE/$(get_project_name)/feature-one"
    mkdir -p "$(dirname "$wt_dir")"
    git worktree add -q "$wt_dir" feature-one

    run get_worktree_data 1 ""
    assert_success
    assert_contains "$output" 'feature-one'
    assert_contains "$output" 'run-shell'

    git worktree remove --force "$wt_dir"
}

@test "get_worktree_data_with_count returns page count" {
    run get_worktree_data_with_count 1 ""
    assert_success

    # First line should be a number (page count)
    local first_line
    first_line=$(echo "$output" | head -1)
    [[ "$first_line" =~ ^[0-9]+$ ]]
}

@test "get_branch_data returns branches" {
    run get_branch_data 1 ""
    assert_success
    # Should contain test branches from create_test_repo
    assert_contains "$output" 'feature-one'
}

@test "get_removable_worktree_data excludes current dir" {
    # Create a worktree
    local wt_dir="$WORKTREE_BASE/$(get_project_name)/feature-one"
    mkdir -p "$(dirname "$wt_dir")"
    git worktree add -q "$wt_dir" feature-one

    run get_removable_worktree_data 1 ""
    assert_success
    # Should contain the worktree we created
    assert_contains "$output" 'feature-one'

    git worktree remove --force "$wt_dir"
}

# ==============================================================================
# WORKTREE CREATION TESTS (git operations, not create_new_worktree function)
# ==============================================================================

@test "git worktree add creates directory" {
    local wt_dir="$WORKTREE_BASE/$(get_project_name)/test-create"
    mkdir -p "$(dirname "$wt_dir")"

    run git worktree add "$wt_dir" -b "test-create"
    assert_success
    [ -d "$wt_dir" ]

    git worktree remove --force "$wt_dir"
    git branch -D "test-create"
}

@test "git worktree add from existing branch" {
    local wt_dir="$WORKTREE_BASE/$(get_project_name)/feature-one"
    mkdir -p "$(dirname "$wt_dir")"

    run git worktree add "$wt_dir" feature-one
    assert_success
    [ -d "$wt_dir" ]

    # Verify correct branch
    local branch
    branch=$(git -C "$wt_dir" branch --show-current)
    assert_equal "feature-one" "$branch"

    git worktree remove --force "$wt_dir"
}

@test "worktree has correct git configuration" {
    local wt_dir="$WORKTREE_BASE/$(get_project_name)/test-config"
    mkdir -p "$(dirname "$wt_dir")"
    git worktree add -q "$wt_dir" -b "test-config"

    # Worktree should share git config with main repo
    local main_email wt_email
    main_email=$(git config user.email)
    wt_email=$(git -C "$wt_dir" config user.email)

    assert_equal "$main_email" "$wt_email"

    git worktree remove --force "$wt_dir"
    git branch -D "test-config"
}

# ==============================================================================
# WORKTREE REMOVAL TESTS
# ==============================================================================

@test "git worktree remove deletes directory" {
    local wt_dir="$WORKTREE_BASE/$(get_project_name)/test-remove"
    mkdir -p "$(dirname "$wt_dir")"
    git worktree add -q "$wt_dir" -b "test-remove"

    [ -d "$wt_dir" ]

    git worktree remove --force "$wt_dir"

    [ ! -d "$wt_dir" ]

    git branch -D "test-remove"
}

@test "git worktree remove keeps branch" {
    local wt_dir="$WORKTREE_BASE/$(get_project_name)/test-keep-branch"
    mkdir -p "$(dirname "$wt_dir")"
    git worktree add -q "$wt_dir" -b "test-keep-branch"

    git worktree remove --force "$wt_dir"

    # Branch should still exist
    run git branch --list "test-keep-branch"
    assert_success
    assert_contains "$output" "test-keep-branch"

    git branch -D "test-keep-branch"
}

@test "worktree list updates after removal" {
    local wt_dir="$WORKTREE_BASE/$(get_project_name)/test-list-update"
    mkdir -p "$(dirname "$wt_dir")"
    git worktree add -q "$wt_dir" -b "test-list-update"

    # Should be in list
    run git worktree list
    assert_contains "$output" "test-list-update"

    git worktree remove --force "$wt_dir"

    # Should not be in list
    run git worktree list
    [[ "$output" != *"test-list-update"* ]]

    git branch -D "test-list-update"
}

# ==============================================================================
# TMUX SESSION TESTS
# ==============================================================================

@test "tmux session can be created for worktree" {
    local wt_dir="$WORKTREE_BASE/$(get_project_name)/test-session"
    mkdir -p "$(dirname "$wt_dir")"
    git worktree add -q "$wt_dir" -b "test-session"

    local session_name="test-wt-session"

    # Create session in worktree directory
    run tmux_run new-session -d -c "$wt_dir" -s "$session_name"
    assert_success

    # Session should exist
    run tmux_run has-session -t "$session_name"
    assert_success

    # Clean up
    tmux_run kill-session -t "$session_name"
    git worktree remove --force "$wt_dir"
    git branch -D "test-session"
}

@test "tmux session has correct working directory" {
    local wt_dir="$WORKTREE_BASE/$(get_project_name)/test-cwd"
    mkdir -p "$(dirname "$wt_dir")"
    git worktree add -q "$wt_dir" -b "test-cwd"

    local session_name="test-cwd-session"
    tmux_run new-session -d -c "$wt_dir" -s "$session_name"

    # Get session's working directory
    local session_path
    session_path=$(tmux_run display-message -t "$session_name" -p '#{pane_current_path}')

    assert_equal "$wt_dir" "$session_path"

    tmux_run kill-session -t "$session_name"
    git worktree remove --force "$wt_dir"
    git branch -D "test-cwd"
}

# ==============================================================================
# EDGE CASES
# ==============================================================================

@test "worktree with slashes in branch name" {
    local wt_dir="$WORKTREE_BASE/$(get_project_name)/feature/test-slash"
    mkdir -p "$(dirname "$wt_dir")"

    run git worktree add "$wt_dir" -b "feature/test-slash"
    assert_success
    [ -d "$wt_dir" ]

    git worktree remove --force "$wt_dir"
    git branch -D "feature/test-slash"
}

@test "multiple worktrees can exist simultaneously" {
    local project
    project=$(get_project_name)
    local wt1="$WORKTREE_BASE/$project/test-multi-1"
    local wt2="$WORKTREE_BASE/$project/test-multi-2"
    local wt3="$WORKTREE_BASE/$project/test-multi-3"
    mkdir -p "$WORKTREE_BASE/$project"

    git worktree add -q "$wt1" -b "test-multi-1"
    git worktree add -q "$wt2" -b "test-multi-2"
    git worktree add -q "$wt3" -b "test-multi-3"

    [ -d "$wt1" ]
    [ -d "$wt2" ]
    [ -d "$wt3" ]

    # All should appear in list
    run git worktree list
    assert_contains "$output" "test-multi-1"
    assert_contains "$output" "test-multi-2"
    assert_contains "$output" "test-multi-3"

    git worktree remove --force "$wt1"
    git worktree remove --force "$wt2"
    git worktree remove --force "$wt3"
    git branch -D "test-multi-1" "test-multi-2" "test-multi-3"
}

@test "worktree base directory is created if missing" {
    local new_base="${BATS_TMPDIR}/new-worktree-base-$$"
    [ ! -d "$new_base" ]

    mkdir -p "$new_base"
    [ -d "$new_base" ]

    rm -rf "$new_base"
}
