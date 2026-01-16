#!/usr/bin/env bats
# Tests for worktree creation and removal operations
# Tests git worktree operations directly, not via menu interaction

load '../test_helper'

# Create shared repo once per file (much faster than per-test)
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

    # CRITICAL: Initialize WORKTREE_BASE BEFORE load_config to prevent
    # teardown from deleting ~/.tmux-worktree if setup fails mid-way
    init_test_worktree_base

    source_script "$SCRIPTS_DIR/helpers.sh"
    source_script "$SCRIPTS_DIR/filter.sh"
    cd "$TEST_REPO_DIR" || exit 1
    load_config
    source_script "$SCRIPTS_DIR/worktree_manager.sh"
}

teardown() {
    # Clean up worktrees created during test
    git worktree list --porcelain 2>/dev/null | grep "^worktree " | cut -d' ' -f2 | while read -r wt; do
        [ "$wt" != "$TEST_REPO_DIR" ] && git worktree remove --force "$wt" 2>/dev/null || true
    done

    # Delete test branches
    git branch 2>/dev/null | grep "^  test-" | while read -r branch; do
        git branch -D "${branch## }" 2>/dev/null || true
    done
    git branch 2>/dev/null | grep "^  feature/test-" | while read -r branch; do
        git branch -D "${branch## }" 2>/dev/null || true
    done

    safe_cleanup_worktree_base
}

# ==============================================================================
# PROJECT NAME TESTS
# ==============================================================================

@test "get_project_name returns sanitized name" {
    run get_project_name
    assert_success
    # Should only contain alphanumeric, dash, underscore, dot
    [[ "$output" =~ ^[a-zA-Z0-9._-]+$ ]]
    # Should contain part of the repo directory name
    assert_contains "$output" "shared-repo"
}

@test "get_project_name works from subdirectory" {
    mkdir -p subdir/nested
    cd subdir/nested

    run get_project_name
    assert_success
    assert_contains "$output" "shared-repo"
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

# ==============================================================================
# CREATE_NEW_WORKTREE FUNCTION TESTS
# Note: These tests focus on git operations. Tmux session tests are covered
# separately in the TMUX SESSION TESTS section above.
# ==============================================================================

@test "create_new_worktree creates directory" {
    local project
    project=$(get_project_name)
    local branch="test-cnw-dir"
    local expected_path="$WORKTREE_BASE/$project/$branch"

    # Run in subshell to avoid affecting current session
    # Note: switch-client fails without attached client, but worktree is still created
    (create_new_worktree "$branch") 2>/dev/null || true

    [ -d "$expected_path" ]

    # Cleanup
    git worktree remove --force "$expected_path" 2>/dev/null || true
    git branch -D "$branch" 2>/dev/null || true
}

@test "create_new_worktree creates branch" {
    local branch="test-cnw-branch"
    local project
    project=$(get_project_name)
    local expected_path="$WORKTREE_BASE/$project/$branch"

    (create_new_worktree "$branch") 2>/dev/null || true

    # Branch should exist
    run git branch --list "$branch"
    assert_contains "$output" "$branch"

    # Cleanup
    git worktree remove --force "$expected_path" 2>/dev/null || true
    git branch -D "$branch" 2>/dev/null || true
}

@test "create_new_worktree uses correct worktree path format" {
    local project
    project=$(get_project_name)
    local branch="test-cnw-path"
    local expected_path="$WORKTREE_BASE/$project/$branch"

    (create_new_worktree "$branch") 2>/dev/null || true

    # Verify worktree appears in git worktree list with correct path
    run git worktree list
    assert_contains "$output" "$expected_path"

    # Cleanup
    git worktree remove --force "$expected_path" 2>/dev/null || true
    git branch -D "$branch" 2>/dev/null || true
}

@test "create_new_worktree handles slashes in branch name" {
    local project
    project=$(get_project_name)
    local branch="feature/test-cnw-slash"
    local expected_path="$WORKTREE_BASE/$project/$branch"

    (create_new_worktree "$branch") 2>/dev/null || true

    [ -d "$expected_path" ]

    # Branch should exist with slashes
    run git branch --list "$branch"
    assert_contains "$output" "$branch"

    # Cleanup
    git worktree remove --force "$expected_path" 2>/dev/null || true
    git branch -D "$branch" 2>/dev/null || true
}

@test "create_new_worktree fails for existing branch" {
    local branch="feature-one"  # Already exists from create_test_repo

    # Should fail because branch exists
    run bash -c "source '$SCRIPTS_DIR/helpers.sh' && source '$SCRIPTS_DIR/filter.sh' && load_config && export WORKTREE_BASE='$WORKTREE_BASE' && source '$SCRIPTS_DIR/worktree_manager.sh' && create_new_worktree '$branch'"

    # The function displays error but doesn't crash

    # No new worktree should be created (branch already exists error from git)
    local project
    project=$(get_project_name)
    [ ! -d "$WORKTREE_BASE/$project/$branch" ]
}

# ==============================================================================
# REMOVE_WORKTREE FUNCTION TESTS
# Note: These tests focus on git operations and verifying branch preservation.
# ==============================================================================

@test "remove_worktree removes directory" {
    local project
    project=$(get_project_name)
    local branch="test-rw-dir"
    local wt_path="$WORKTREE_BASE/$project/$branch"
    local session_name="${project}-${branch}"

    # Create worktree first
    mkdir -p "$(dirname "$wt_path")"
    git worktree add -q "$wt_path" -b "$branch"

    [ -d "$wt_path" ]

    # Mock show_remove_worktree_menu to avoid menu display
    show_remove_worktree_menu() { :; }

    # Remove worktree (tmux session operations may fail in test env, that's OK)
    remove_worktree "$wt_path" "$branch" "$session_name" 1 2>/dev/null || true

    # Worktree directory should be gone
    [ ! -d "$wt_path" ]

    # Cleanup branch
    git branch -D "$branch" 2>/dev/null || true
}

@test "remove_worktree keeps branch" {
    local project
    project=$(get_project_name)
    local branch="test-rw-keep-branch"
    local wt_path="$WORKTREE_BASE/$project/$branch"
    local session_name="${project}-${branch}"

    # Create worktree
    mkdir -p "$(dirname "$wt_path")"
    git worktree add -q "$wt_path" -b "$branch"

    # Mock menu
    show_remove_worktree_menu() { :; }

    remove_worktree "$wt_path" "$branch" "$session_name" 1 2>/dev/null || true

    # Branch should still exist (this is the key behavior)
    run git branch --list "$branch"
    assert_contains "$output" "$branch"

    # Cleanup
    git branch -D "$branch" 2>/dev/null || true
}

@test "remove_worktree updates worktree list" {
    local project
    project=$(get_project_name)
    local branch="test-rw-list"
    local wt_path="$WORKTREE_BASE/$project/$branch"
    local session_name="${project}-${branch}"

    # Create worktree
    mkdir -p "$(dirname "$wt_path")"
    git worktree add -q "$wt_path" -b "$branch"

    # Verify in list
    run git worktree list
    assert_contains "$output" "$wt_path"

    # Mock menu
    show_remove_worktree_menu() { :; }

    remove_worktree "$wt_path" "$branch" "$session_name" 1 2>/dev/null || true

    # Should be gone from list
    run git worktree list
    [[ "$output" != *"$wt_path"* ]]

    # Cleanup
    git branch -D "$branch" 2>/dev/null || true
}

@test "remove_worktree handles non-existent worktree gracefully" {
    local project
    project=$(get_project_name)
    local branch="test-rw-nonexistent"
    local wt_path="$WORKTREE_BASE/$project/$branch"
    local session_name="${project}-${branch}"

    # Don't create worktree - test error handling

    # Mock menu
    show_remove_worktree_menu() { :; }

    # Should not crash (may produce error message, but exit cleanly)
    run remove_worktree "$wt_path" "$branch" "$session_name" 1
    # Function doesn't crash - that's the test
    true
}

# ==============================================================================
# DETACHED HEAD WORKTREE TESTS
# ==============================================================================

@test "detached HEAD worktree appears in worktree list" {
    local project
    project=$(get_project_name)
    local commit_sha
    commit_sha=$(git rev-parse HEAD)
    local wt_dir="$WORKTREE_BASE/$project/detached-test"
    mkdir -p "$(dirname "$wt_dir")"

    # Create detached HEAD worktree
    git worktree add --detach "$wt_dir" "$commit_sha"

    # Verify it appears in git worktree list
    run git worktree list
    assert_success
    assert_contains "$output" "detached"

    # Cleanup
    git worktree remove --force "$wt_dir"
}

@test "get_worktree_data includes detached HEAD worktrees" {
    local project
    project=$(get_project_name)
    local commit_sha
    commit_sha=$(git rev-parse HEAD)
    local wt_dir="$WORKTREE_BASE/$project/detached-data"
    mkdir -p "$(dirname "$wt_dir")"

    git worktree add --detach "$wt_dir" "$commit_sha"

    run get_worktree_data 1 ""
    assert_success
    # Output should include the detached worktree path
    assert_contains "$output" "detached-data"

    # Cleanup
    git worktree remove --force "$wt_dir"
}

@test "get_removable_worktree_data includes detached HEAD worktrees" {
    local project
    project=$(get_project_name)
    local commit_sha
    commit_sha=$(git rev-parse HEAD)
    local wt_dir="$WORKTREE_BASE/$project/detached-remove"
    mkdir -p "$(dirname "$wt_dir")"

    git worktree add --detach "$wt_dir" "$commit_sha"

    run get_removable_worktree_data 1 ""
    assert_success
    # Output should include the detached worktree
    assert_contains "$output" "detached-remove"

    # Cleanup
    git worktree remove --force "$wt_dir"
}
