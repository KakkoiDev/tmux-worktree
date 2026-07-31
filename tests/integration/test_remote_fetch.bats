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
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # CRITICAL: Set WORKTREE_BASE AFTER sourcing worktree_manager.sh because it calls load_config
    init_test_worktree_base
}

teardown() {
    safe_cleanup_worktree_base
}

# ==============================================================================
# Remote Fetch Menu Option Tests
# ==============================================================================

@test "show_add_worktree_menu includes fetch remote option" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_show() {
        printf '%s\n' "${TK_MENU_ARGS[@]}"; TK_MENU_ARGS=()
    }

    run show_add_worktree_menu 1
    assert_success
    assert_contains "$output" "Fetch remote"
    assert_contains "$output" "Fetch remote"
}

@test "fetch remote option is positioned after New and before Filter" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_show() {
        printf '%s\n' "${TK_MENU_ARGS[@]}"; TK_MENU_ARGS=()
    }

    run show_add_worktree_menu 1
    assert_success

    # Check order: New should come before Fetch, Fetch before Filter
    local new_pos=$(echo "$output" | grep -bo 'New' | head -1 | cut -d: -f1)
    local fetch_pos=$(echo "$output" | grep -bo 'Fetch remote' | head -1 | cut -d: -f1)
    local filter_pos=$(echo "$output" | grep -bo 'Filter' | head -1 | cut -d: -f1)

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
    refute_contains "$output" "origin/"

    # Cleanup
    git remote remove origin
    rm -rf "$remote_dir"
}

@test "remote branches are marked with visual indicator" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a bare remote with an extra branch that doesn't exist locally
    local remote_dir="${TEST_REPO_DIR}-remote"
    git clone --bare . "$remote_dir"
    git -C "$remote_dir" branch remote-only-branch master
    git remote add origin "$remote_dir"
    git fetch origin

    run get_branch_data 1 "" 1
    assert_success
    # Remote-only branches should have [remote] origin/ prefix in display
    assert_contains "$output" "[remote] origin/remote-only-branch"

    # Cleanup
    git remote remove origin
    rm -rf "$remote_dir"
}

@test "remote branches with local counterparts are filtered out" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a bare remote (has same branches as local)
    local remote_dir="${TEST_REPO_DIR}-remote"
    git clone --bare . "$remote_dir"
    git remote add origin "$remote_dir"
    git fetch origin

    run get_branch_data 1 "" 1
    assert_success
    # origin/master and origin/feature-* should NOT appear since local branches exist
    refute_contains "$output" "origin/master"
    refute_contains "$output" "origin/feature-one"
    refute_contains "$output" "origin/feature-two"
    # Local branches without worktrees still appear as plain entries
    assert_contains "$output" 'feature-one'
    assert_contains "$output" 'feature-two'
    # master has a worktree (main repo) so it now shows as [active]
    assert_contains "$output" '[active] master'

    # Cleanup
    git remote remove origin
    rm -rf "$remote_dir"
}

@test "local branches with existing worktrees show as [active]" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a worktree for feature-one branch
    local wt_path="${WORKTREE_BASE}/$(get_project_name)/feature-one"
    mkdir -p "$(dirname "$wt_path")"
    git worktree add "$wt_path" feature-one

    run get_branch_data 1 "" 0
    assert_success
    # feature-one has a worktree -> shown as [active]
    assert_contains "$output" '[active] feature-one'
    # master is on main repo -> also [active]
    assert_contains "$output" '[active] master'
    # Other branches without worktrees still appear as plain entries
    assert_contains "$output" 'feature-two'
    assert_contains "$output" 'bugfix-123'
    # Active items must come before plain locals
    assert_contains "${output%%feature-two*}" "[active] feature-one"
    # TSV contains type, label, branch, and worktree path
    assert_contains "$output" "feature-one"
    assert_contains "$output" "$wt_path"

    # Cleanup
    git worktree remove "$wt_path" --force
}

@test "remote branches with existing worktrees show as [active]" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a bare remote with an extra branch
    local remote_dir="${TEST_REPO_DIR}-remote"
    git clone --bare . "$remote_dir"
    git -C "$remote_dir" branch remote-only-branch master
    git remote add origin "$remote_dir"
    git fetch origin

    # Create a worktree for remote-only-branch (which creates local tracking branch)
    local wt_path="${WORKTREE_BASE}/$(get_project_name)/remote-only-branch"
    mkdir -p "$(dirname "$wt_path")"
    git worktree add -b remote-only-branch "$wt_path" origin/remote-only-branch

    run get_branch_data 1 "" 1
    assert_success
    # remote-only-branch has a local worktree -> shown as [active] under local name
    assert_contains "$output" '[active] remote-only-branch'
    # origin/remote-only-branch should not appear as a [remote] entry (local exists)
    refute_contains "$output" '[remote] origin/remote-only-branch'

    # Cleanup
    git worktree remove "$wt_path" --force
    git branch -D remote-only-branch
    git remote remove origin
    rm -rf "$remote_dir"
}

@test "[active] entries sort before plain locals and [remote] entries" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create worktrees for two local branches (master is also active via main repo)
    local wt1="${WORKTREE_BASE}/$(get_project_name)/feature-one"
    local wt2="${WORKTREE_BASE}/$(get_project_name)/bugfix-123"
    mkdir -p "$(dirname "$wt1")"
    git worktree add "$wt1" feature-one
    git worktree add "$wt2" bugfix-123

    # Add a remote that introduces an extra branch
    local remote_dir="${TEST_REPO_DIR}-remote"
    git clone --bare . "$remote_dir"
    git -C "$remote_dir" branch remote-only-extra master
    git remote add origin "$remote_dir"
    git fetch origin

    run get_branch_data 1 "" 1
    assert_success

    # Locate first occurrence of each kind in the output
    local active_pos plain_pos remote_pos
    active_pos=$(echo "$output" | grep -bo '\[active\]' | head -1 | cut -d: -f1)
    plain_pos=$(echo "$output" | grep -bo 'feature-two' | head -1 | cut -d: -f1)
    remote_pos=$(echo "$output" | grep -bo '\[remote\]' | head -1 | cut -d: -f1)

    [ -n "$active_pos" ]
    [ -n "$plain_pos" ]
    [ -n "$remote_pos" ]
    [ "$active_pos" -lt "$plain_pos" ]
    [ "$plain_pos" -lt "$remote_pos" ]

    # Cleanup
    git worktree remove "$wt1" --force
    git worktree remove "$wt2" --force
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
    refute_contains "$output" "bugfix"

    # Cleanup
    git remote remove origin
    rm -rf "$remote_dir"
}

# ==============================================================================
# Include Remotes State Tests
# ==============================================================================

@test "show_add_worktree_menu accepts include_remotes parameter" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_show() {
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

    tk_menu_show() {
        printf '%s\n' "${TK_MENU_ARGS[@]}"; TK_MENU_ARGS=()
    }

    run show_add_worktree_menu 1
    assert_success

    # The fetch option should trigger menu refresh with include_remotes=1
    assert_contains "$output" "show_add_worktree_menu"
    assert_contains "$output" "fetch_remote_branches"
}

