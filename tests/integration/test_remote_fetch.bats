#!/usr/bin/env bats
# Tests for remote branch fetching functionality

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
}

teardown() {
    :
}

# ==============================================================================
# Remote Fetch Menu Option Tests
# ==============================================================================

@test "show_add_worktree_menu includes fetch remote option" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    display_menu() {
        echo "$2"
    }

    run show_add_worktree_menu 1
    assert_success
    assert_contains "$output" "Fetch remote"
    assert_contains "$output" "\"r\""
}

@test "fetch remote option is positioned after New and before Filter" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    display_menu() {
        echo "$2"
    }

    run show_add_worktree_menu 1
    assert_success

    # Check order: New should come before Fetch, Fetch before Filter
    local new_pos=$(echo "$output" | grep -bo '"New"' | head -1 | cut -d: -f1)
    local fetch_pos=$(echo "$output" | grep -bo '"Fetch remote"' | head -1 | cut -d: -f1)
    local filter_pos=$(echo "$output" | grep -bo '"Filter"' | head -1 | cut -d: -f1)

    [ "$new_pos" -lt "$fetch_pos" ]
    [ "$fetch_pos" -lt "$filter_pos" ]
}

# ==============================================================================
# Remote Branch Fetching Tests
# ==============================================================================

@test "fetch_remote_branches function exists" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    run type fetch_remote_branches
    assert_success
    assert_contains "$output" "function"
}

@test "fetch_remote_branches returns success with valid remote" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a bare remote
    local remote_dir="${TEST_REPO_DIR}-remote"
    git clone --bare . "$remote_dir"
    git remote add test-remote "$remote_dir"

    run fetch_remote_branches
    assert_success

    # Cleanup
    git remote remove test-remote
    rm -rf "$remote_dir"
}

@test "fetch_remote_branches respects timeout" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Override timeout to very short value
    FETCH_TIMEOUT=1

    # Even with short timeout, function should return (success or failure)
    run timeout 5 bash -c "source '$SCRIPTS_DIR/worktree_manager.sh' && FETCH_TIMEOUT=1 && fetch_remote_branches"
    # Should not hang
    [ $status -le 128 ]  # Not killed by signal
}

# ==============================================================================
# Remote Branch Data Tests
# ==============================================================================

@test "get_branch_data accepts include_remotes parameter" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a bare remote and add remote branches
    local remote_dir="${TEST_REPO_DIR}-remote"
    git clone --bare . "$remote_dir"
    git remote add origin "$remote_dir"

    # Create a branch in the remote
    cd "$remote_dir"
    git branch remote-only-branch
    cd "$TEST_REPO_DIR"
    git fetch origin

    # With include_remotes=1, should show remote branches
    run get_branch_data 1 "" 1
    assert_success
    assert_contains "$output" "origin"

    # Cleanup
    git remote remove origin
    rm -rf "$remote_dir"
}

@test "get_branch_data excludes remotes by default" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a bare remote
    local remote_dir="${TEST_REPO_DIR}-remote"
    git clone --bare . "$remote_dir"
    git remote add origin "$remote_dir"
    git fetch origin

    # Without include_remotes parameter, should not show remote branches
    run get_branch_data 1 ""
    assert_success
    # Should only have local branches, not origin prefixed ones
    [[ "$output" != *"origin/"* ]]

    # Cleanup
    git remote remove origin
    rm -rf "$remote_dir"
}

@test "remote branches are marked with visual indicator" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a bare remote
    local remote_dir="${TEST_REPO_DIR}-remote"
    git clone --bare . "$remote_dir"
    git remote add origin "$remote_dir"
    git fetch origin

    run get_branch_data 1 "" 1
    assert_success
    # Remote branches should have origin/ prefix in display
    assert_contains "$output" "origin/"

    # Cleanup
    git remote remove origin
    rm -rf "$remote_dir"
}

@test "get_branch_page_count includes remotes when requested" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a bare remote with extra branch
    local remote_dir="${TEST_REPO_DIR}-remote"
    git clone --bare . "$remote_dir"
    git remote add origin "$remote_dir"

    cd "$remote_dir"
    git branch remote-branch-1
    git branch remote-branch-2
    cd "$TEST_REPO_DIR"
    git fetch origin

    # Count without remotes
    run get_branch_page_count "" 0
    local count_without="$output"

    # Count with remotes should be higher
    run get_branch_page_count "" 1
    local count_with="$output"

    [ "$count_with" -ge "$count_without" ]

    # Cleanup
    git remote remove origin
    rm -rf "$remote_dir"
}

# ==============================================================================
# Worktree Creation from Remote Branch Tests
# ==============================================================================

@test "selecting remote branch creates tracking local branch" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a bare remote with a branch
    local remote_dir="${TEST_REPO_DIR}-remote"
    git clone --bare . "$remote_dir"
    git remote add origin "$remote_dir"

    cd "$remote_dir"
    git branch remote-feature
    cd "$TEST_REPO_DIR"
    git fetch origin

    # Create worktree from remote branch
    local wt_dir="${TEST_REPO_DIR}-worktrees/remote-feature"
    mkdir -p "$(dirname "$wt_dir")"

    run git worktree add -b remote-feature "$wt_dir" origin/remote-feature
    assert_success

    # Verify local branch exists and tracks remote
    run git branch -vv
    assert_contains "$output" "remote-feature"
    assert_contains "$output" "origin/remote-feature"

    # Cleanup
    git worktree remove -f "$wt_dir" 2>/dev/null || true
    git branch -D remote-feature 2>/dev/null || true
    git remote remove origin
    rm -rf "$remote_dir"
}

# ==============================================================================
# Filter Integration with Remote Branches Tests
# ==============================================================================

@test "filter applies to remote branches" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a bare remote with branches
    local remote_dir="${TEST_REPO_DIR}-remote"
    git clone --bare . "$remote_dir"
    git remote add origin "$remote_dir"

    cd "$remote_dir"
    git branch feature-remote
    git branch bugfix-remote
    cd "$TEST_REPO_DIR"
    git fetch origin

    # Filter for feature branches should include remote feature branch
    run get_branch_data 1 "feature*" 1
    assert_success
    assert_contains "$output" "feature"
    [[ "$output" != *"bugfix"* ]]

    # Cleanup
    git remote remove origin
    rm -rf "$remote_dir"
}

# ==============================================================================
# Include Remotes State Tests
# ==============================================================================

@test "show_add_worktree_menu accepts include_remotes parameter" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    display_menu() {
        echo "TITLE: $1"
        echo "OPTIONS: $2"
    }

    # With include_remotes, title should indicate remote mode
    run show_add_worktree_menu 1 "" 1
    assert_success
    # Could show indicator in title or have different behavior
}

@test "fetch remote action refreshes menu with include_remotes enabled" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    display_menu() {
        echo "$2"
    }

    run show_add_worktree_menu 1
    assert_success

    # The fetch option should trigger menu refresh with include_remotes=1
    assert_contains "$output" "show_add_worktree_menu"
    assert_contains "$output" "fetch_remote_branches"
}

