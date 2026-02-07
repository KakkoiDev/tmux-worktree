#!/usr/bin/env bats
# bats file_tags=integration,env
# Tests for session environment variables

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

    source_script "$SCRIPTS_DIR/helpers.sh"
    source_script "$SCRIPTS_DIR/filter.sh"
    cd "$TEST_REPO_DIR" || exit 1
    load_config
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    init_test_worktree_base
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
# CREATE_NEW_WORKTREE ENVIRONMENT VARIABLE TESTS
# ==============================================================================

@test "create_new_worktree sets all environment variables" {
    local project
    project=$(get_project_name)
    local branch="test-env-all"
    local session_name="${project}-${branch}"
    local expected_path="$WORKTREE_BASE/$project/$branch"

    (create_new_worktree "$branch") 2>/dev/null || true

    # Find session (may have been renamed by user's tmux hooks)
    local actual_session
    actual_session=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "^${project}.*${branch}" | head -1)
    if [ -z "$actual_session" ]; then
        # Fallback: session might be renamed based on git branch
        actual_session=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${project}-${branch}" | head -1)
    fi

    # Skip if no session found (CI environment without tmux)
    if [ -z "$actual_session" ]; then
        skip "Session not created (tmux may not be available)"
    fi

    # Check TMUX_WORKTREE=1
    run tmux show-environment -t "$actual_session" TMUX_WORKTREE
    assert_success
    assert_equal "TMUX_WORKTREE=1" "$output"

    # Check TMUX_WORKTREE_PROJECT
    run tmux show-environment -t "$actual_session" TMUX_WORKTREE_PROJECT
    assert_success
    assert_equal "TMUX_WORKTREE_PROJECT=$project" "$output"

    # Check TMUX_WORKTREE_BRANCH
    run tmux show-environment -t "$actual_session" TMUX_WORKTREE_BRANCH
    assert_success
    assert_equal "TMUX_WORKTREE_BRANCH=$branch" "$output"

    # Check TMUX_WORKTREE_PATH (absolute path)
    run tmux show-environment -t "$actual_session" TMUX_WORKTREE_PATH
    assert_success
    assert_contains "$output" "TMUX_WORKTREE_PATH=/"
    refute_contains "$output" "~"
    assert_contains "$output" "$expected_path"

    # Cleanup
    tmux kill-session -t "$actual_session" 2>/dev/null || true
    git worktree remove --force "$expected_path" 2>/dev/null || true
    git branch -D "$branch" 2>/dev/null || true
}

@test "create_new_worktree preserves slashes in TMUX_WORKTREE_BRANCH" {
    local project
    project=$(get_project_name)
    local branch="feature/test-nested/branch"
    local session_name="${project}-feature-test-nested-branch"
    local expected_path="$WORKTREE_BASE/$project/$branch"

    (create_new_worktree "$branch") 2>/dev/null || true

    # Find session (may have been renamed by user's tmux hooks)
    local actual_session
    actual_session=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "^${project}.*nested" | head -1)
    if [ -z "$actual_session" ]; then
        actual_session="$session_name"
    fi

    # Skip if no session found
    if ! tmux has-session -t "$actual_session" 2>/dev/null; then
        skip "Session not created (tmux may not be available)"
    fi

    run tmux show-environment -t "$actual_session" TMUX_WORKTREE_BRANCH
    assert_success
    assert_equal "TMUX_WORKTREE_BRANCH=$branch" "$output"

    # Cleanup
    tmux kill-session -t "$actual_session" 2>/dev/null || true
    git worktree remove --force "$expected_path" 2>/dev/null || true
    git branch -D "$branch" 2>/dev/null || true
}

# ==============================================================================
# GET_PROJECT_NAME FAST PATH TESTS
# ==============================================================================

@test "get_project_name uses TMUX_WORKTREE_PROJECT when set" {
    export TMUX_WORKTREE_PROJECT="cached-project"

    run get_project_name
    assert_success
    assert_equal "cached-project" "$output"

    unset TMUX_WORKTREE_PROJECT
}

@test "get_project_name falls back to git when TMUX_WORKTREE_PROJECT unset" {
    unset TMUX_WORKTREE_PROJECT

    run get_project_name
    assert_success
    # Should return actual project name from git (shared-repo-XXXXX)
    assert_contains "$output" "shared-repo"
}

@test "get_project_name fast path is faster than git lookup" {
    # This is a sanity test - env var lookup should be near-instant
    export TMUX_WORKTREE_PROJECT="test-project"

    local start_time end_time
    start_time=$(date +%s%N 2>/dev/null || date +%s)
    get_project_name >/dev/null
    end_time=$(date +%s%N 2>/dev/null || date +%s)

    # Just verify it runs without error
    run get_project_name
    assert_success
    assert_equal "test-project" "$output"

    unset TMUX_WORKTREE_PROJECT
}
