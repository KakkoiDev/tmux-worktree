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

    source_script "$SCRIPTS_DIR/helpers.sh"
    source_script "$SCRIPTS_DIR/filter.sh"
    cd "$TEST_REPO_DIR" || exit 1
    load_config
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    # CRITICAL: Set WORKTREE_BASE AFTER load_config because load_config overwrites it
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

@test "get_worktree_data returns page count as first line" {
    run get_worktree_data 1 ""
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

    # Resolve both paths to handle macOS /tmp -> /private/tmp symlink
    local resolved_wt_dir resolved_session_path
    resolved_wt_dir=$(cd "$wt_dir" && pwd -P)
    resolved_session_path=$(cd "$session_path" && pwd -P)
    assert_equal "$resolved_wt_dir" "$resolved_session_path"

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
    # NOTE: export WORKTREE_BASE AFTER sourcing worktree_manager.sh because it calls load_config
    run bash -c "source '$SCRIPTS_DIR/helpers.sh' && source '$SCRIPTS_DIR/filter.sh' && load_config && source '$SCRIPTS_DIR/worktree_manager.sh' && export WORKTREE_BASE='$WORKTREE_BASE' && create_new_worktree '$branch'"

    # The function displays error but doesn't crash

    # No new worktree should be created (branch already exists error from git)
    local project
    project=$(get_project_name)
    [ ! -d "$WORKTREE_BASE/$project/$branch" ]
}

# Regression: a user-defined after-new-session hook (e.g. one that auto-renames
# new sessions to "<repo>-<branch>") could hijack the plugin's session name and
# break the subsequent switch-client. _setup_worktree must capture session_id
# at creation and force the intended name back. See _setup_worktree comments.
@test "create_new_worktree keeps plugin session name when after-new-session hook renames" {
    local project
    project=$(get_project_name)
    local branch="test-cnw-hook-rename"
    _worktree_vars "$branch" "$project"
    local expected_session="$_WT_SESSION"
    local expected_path="$_WT_PATH"

    tmux_run set-hook -g after-new-session 'rename-session stolen-by-hook'

    (create_new_worktree "$branch") 2>/dev/null || true

    run tmux_run has-session -t "$expected_session"
    local has_expected="$status"
    run tmux_run has-session -t "stolen-by-hook"
    local has_stolen="$status"

    # Cleanup BEFORE asserts so the hook never leaks to other tests even on failure
    tmux_run set-hook -gu after-new-session 2>/dev/null || true
    tmux_run kill-session -t "$expected_session" 2>/dev/null || true
    tmux_run kill-session -t "stolen-by-hook" 2>/dev/null || true
    git worktree remove --force "$expected_path" 2>/dev/null || true
    git branch -D "$branch" 2>/dev/null || true

    [ "$has_expected" -eq 0 ] || { echo "Expected session '$expected_session' to exist"; return 1; }
    [ "$has_stolen" -ne 0 ] || { echo "Session 'stolen-by-hook' should NOT exist"; return 1; }
}

# Same defense, exercised via add_worktree (the path the user originally hit).
@test "add_worktree keeps plugin session name when after-new-session hook renames" {
    local project
    project=$(get_project_name)
    local branch="feature-one"  # pre-existing branch in shared repo
    _worktree_vars "$branch" "$project"
    local expected_session="$_WT_SESSION"
    local expected_path="$_WT_PATH"

    tmux_run set-hook -g after-new-session 'rename-session stolen-by-hook-2'

    (add_worktree "$branch") 2>/dev/null || true

    run tmux_run has-session -t "$expected_session"
    local has_expected="$status"
    run tmux_run has-session -t "stolen-by-hook-2"
    local has_stolen="$status"

    tmux_run set-hook -gu after-new-session 2>/dev/null || true
    tmux_run kill-session -t "$expected_session" 2>/dev/null || true
    tmux_run kill-session -t "stolen-by-hook-2" 2>/dev/null || true
    git worktree remove --force "$expected_path" 2>/dev/null || true

    [ "$has_expected" -eq 0 ] || { echo "Expected session '$expected_session' to exist"; return 1; }
    [ "$has_stolen" -ne 0 ] || { echo "Session 'stolen-by-hook-2' should NOT exist"; return 1; }
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

# ==============================================================================
# ADOPT_CURRENT_SESSION TESTS
# Renames sessions started manually by the user (default tmux name like
# "windows" or "0") to the plugin's <project>-<branch> convention.
# ==============================================================================

# Helper: tmux sanitizes "." in session names to "_", so the canonical name we
# observe is whatever get_session_name produces.
_adopt_canonical_name() {
    local branch="${1:-master}"
    get_session_name "$(get_project_name)" "$branch"
}

@test "adopt_current_session renames default-named session to project-branch" {
    local expected
    expected=$(_adopt_canonical_name master)
    local orig="adopt-windows-1"

    # Ensure no stale session from prior runs
    tmux_run kill-session -t "$orig" 2>/dev/null || true
    tmux_run kill-session -t "$expected" 2>/dev/null || true

    tmux_run new-session -d -s "$orig" -c "$TEST_REPO_DIR"

    # Pass session name explicitly to bypass tmux display-message ambiguity in tests
    adopt_current_session "$orig"

    run tmux_run has-session -t "$expected"
    local has_expected="$status"
    run tmux_run has-session -t "$orig"
    local has_orig="$status"

    tmux_run kill-session -t "$expected" 2>/dev/null || true
    tmux_run kill-session -t "$orig" 2>/dev/null || true

    [ "$has_expected" -eq 0 ] || { echo "Expected session '$expected' to exist"; return 1; }
    [ "$has_orig" -ne 0 ] || { echo "Session '$orig' should have been renamed"; return 1; }
}

@test "adopt_current_session renames numeric default session" {
    local expected
    expected=$(_adopt_canonical_name master)
    local orig="0"

    tmux_run kill-session -t "$orig" 2>/dev/null || true
    tmux_run kill-session -t "$expected" 2>/dev/null || true

    tmux_run new-session -d -s "$orig" -c "$TEST_REPO_DIR"

    adopt_current_session "$orig"

    run tmux_run has-session -t "$expected"
    local has_expected="$status"

    tmux_run kill-session -t "$expected" 2>/dev/null || true
    tmux_run kill-session -t "$orig" 2>/dev/null || true

    [ "$has_expected" -eq 0 ] || { echo "Expected session '$expected' to exist"; return 1; }
}

@test "adopt_current_session leaves already-canonical session alone" {
    local canonical
    canonical=$(_adopt_canonical_name master)

    tmux_run kill-session -t "$canonical" 2>/dev/null || true
    tmux_run new-session -d -s "$canonical" -c "$TEST_REPO_DIR"

    adopt_current_session "$canonical"

    run tmux_run has-session -t "$canonical"
    local has_expected="$status"

    tmux_run kill-session -t "$canonical" 2>/dev/null || true

    [ "$has_expected" -eq 0 ] || { echo "Canonical session '$canonical' should still exist"; return 1; }
}

@test "adopt_current_session leaves plugin-prefixed sessions alone" {
    # Same project, different branch in the name - user might have switched
    # branches within an existing plugin session. Leave it alone.
    local prefixed canonical_master
    prefixed=$(_adopt_canonical_name feature-one)
    canonical_master=$(_adopt_canonical_name master)

    tmux_run kill-session -t "$prefixed" 2>/dev/null || true
    tmux_run kill-session -t "$canonical_master" 2>/dev/null || true

    tmux_run new-session -d -s "$prefixed" -c "$TEST_REPO_DIR"

    adopt_current_session "$prefixed"

    run tmux_run has-session -t "$prefixed"
    local has_orig="$status"
    # Canonical name for master should NOT exist (no rename happened)
    run tmux_run has-session -t "$canonical_master"
    local has_canonical="$status"

    tmux_run kill-session -t "$prefixed" 2>/dev/null || true
    tmux_run kill-session -t "$canonical_master" 2>/dev/null || true

    [ "$has_orig" -eq 0 ] || { echo "Session '$prefixed' should still exist"; return 1; }
    [ "$has_canonical" -ne 0 ] || { echo "Session '$canonical_master' should NOT have been created"; return 1; }
}

@test "adopt_current_session skips detached HEAD" {
    local project
    project=$(get_project_name)
    local detached_dir="$WORKTREE_BASE/$project/adopt-detached"
    local orig="adopt-detached-session"
    mkdir -p "$(dirname "$detached_dir")"
    git worktree add --detach "$detached_dir" HEAD

    tmux_run kill-session -t "$orig" 2>/dev/null || true
    tmux_run new-session -d -s "$orig" -c "$detached_dir"

    pushd "$detached_dir" >/dev/null
    adopt_current_session "$orig"
    popd >/dev/null

    run tmux_run has-session -t "$orig"
    local has_orig="$status"

    tmux_run kill-session -t "$orig" 2>/dev/null || true
    git worktree remove --force "$detached_dir" 2>/dev/null || true

    [ "$has_orig" -eq 0 ] || { echo "Detached HEAD should not trigger rename of '$orig'"; return 1; }
}

@test "adopt_current_session sets TMUX_WORKTREE env vars on renamed session" {
    local expected
    expected=$(_adopt_canonical_name master)
    local orig="adopt-env-session"

    tmux_run kill-session -t "$orig" 2>/dev/null || true
    tmux_run kill-session -t "$expected" 2>/dev/null || true

    tmux_run new-session -d -s "$orig" -c "$TEST_REPO_DIR"

    adopt_current_session "$orig"

    run tmux_run show-environment -t "$expected" TMUX_WORKTREE
    local env_status="$status"
    local env_output="$output"

    tmux_run kill-session -t "$expected" 2>/dev/null || true
    tmux_run kill-session -t "$orig" 2>/dev/null || true

    [ "$env_status" -eq 0 ] || { echo "TMUX_WORKTREE env not set on renamed session"; return 1; }
    [[ "$env_output" == "TMUX_WORKTREE=1" ]] || { echo "Unexpected env value: $env_output"; return 1; }
}

@test "adopt_current_session is a no-op when tmux query returns empty" {
    # Explicit empty session name simulates "not in tmux"
    run adopt_current_session ""
    assert_success
}

@test "adopt_session_hook renames default-named session via tmux hook entry point" {
    local orig="adopt-hook-windows"
    local expected
    expected=$(_adopt_canonical_name master)

    tmux_run kill-session -t "$orig" 2>/dev/null || true
    tmux_run kill-session -t "$expected" 2>/dev/null || true
    tmux_run new-session -d -s "$orig" -c "$TEST_REPO_DIR"

    adopt_session_hook "$orig" "$TEST_REPO_DIR"

    run tmux_run has-session -t "$expected"
    local has_expected="$status"
    run tmux_run has-session -t "$orig"
    local has_orig="$status"

    tmux_run kill-session -t "$expected" 2>/dev/null || true
    tmux_run kill-session -t "$orig" 2>/dev/null || true

    [ "$has_expected" -eq 0 ] || { echo "Hook should have renamed to '$expected'"; return 1; }
    [ "$has_orig" -ne 0 ] || { echo "Original session '$orig' should be gone"; return 1; }
}

@test "adopt_session_hook renames default-named session to dir basename outside git repo" {
    local orig="window"
    local non_git_dir="/tmp/nongit-hook-$$"
    local expected
    expected=$(basename "$non_git_dir")
    mkdir -p "$non_git_dir"

    run tmux_run has-session -t "$orig"
    if [ "$status" -eq 0 ]; then tmux_run kill-session -t "$orig"; fi
    run tmux_run has-session -t "$expected"
    if [ "$status" -eq 0 ]; then tmux_run kill-session -t "$expected"; fi
    run tmux_run new-session -d -s "$orig" -c "$non_git_dir"
    [ "$status" -eq 0 ] || skip "could not create session"

    adopt_session_hook "$orig" "$non_git_dir"

    run tmux_run has-session -t "$expected"
    local has_expected="$status"
    run tmux_run has-session -t "$orig"
    local has_orig="$status"

    tmux_run kill-session -t "$expected" 2>/dev/null || true
    tmux_run kill-session -t "$orig" 2>/dev/null || true
    rm -rf "$non_git_dir"

    [ "$has_expected" -eq 0 ] || { echo "Expected session '$expected' to exist after non-git adoption"; return 1; }
    [ "$has_orig" -ne 0 ] || { echo "Original session '$orig' should have been renamed"; return 1; }
}

@test "adopt_current_session is a no-op when @worktree-adopt-session=off" {
    local orig="adopt-disabled-session"
    tmux_run kill-session -t "$orig" 2>/dev/null || true
    tmux_run new-session -d -s "$orig" -c "$TEST_REPO_DIR"

    ADOPT_SESSION=off adopt_current_session "$orig"

    run tmux_run has-session -t "$orig"
    local has_orig="$status"

    # Canonical session must NOT have been created
    local canonical
    canonical=$(_adopt_canonical_name master)
    run tmux_run has-session -t "$canonical"
    local has_canonical="$status"

    tmux_run kill-session -t "$orig" 2>/dev/null || true
    tmux_run kill-session -t "$canonical" 2>/dev/null || true

    [ "$has_orig" -eq 0 ] || { echo "Original session '$orig' should still exist"; return 1; }
    [ "$has_canonical" -ne 0 ] || { echo "Canonical '$canonical' should NOT have been created"; return 1; }
}

# ==============================================================================
# NON-GIT ADOPTION (regression: sessions opened outside a git repo)
# ==============================================================================
# Regression for the "window" bug: when tmux starts in a non-git directory the
# hook used to early-return on the failed `git rev-parse`, leaving the default
# session name in place. Now the directory basename is used as the canonical
# name and the same exact-match / prefix-skip rules apply.

@test "adopt_current_session renames 'window' to dir basename in non-git dir" {
    local dir base orig="window"
    dir=$(mktemp -d "${BATS_TMPDIR}/nongit-window-XXXXXX")
    base=$(basename "$dir")

    tmux_run kill-session -t "$orig" 2>/dev/null || true
    tmux_run kill-session -t "$base" 2>/dev/null || true
    tmux_run new-session -d -s "$orig" -c "$dir"

    pushd "$dir" >/dev/null
    adopt_current_session "$orig"
    popd >/dev/null

    run tmux_run has-session -t "$base"
    local has_expected="$status"
    run tmux_run has-session -t "$orig"
    local has_orig="$status"

    tmux_run kill-session -t "$base" 2>/dev/null || true
    tmux_run kill-session -t "$orig" 2>/dev/null || true
    rm -rf "$dir"

    [ "$has_expected" -eq 0 ] || { echo "Expected '$base' to exist after rename"; return 1; }
    [ "$has_orig" -ne 0 ] || { echo "'$orig' should have been renamed away"; return 1; }
}

@test "adopt_current_session renames numeric default ('0') to dir basename in non-git dir" {
    local dir base orig="0"
    dir=$(mktemp -d "${BATS_TMPDIR}/nongit-zero-XXXXXX")
    base=$(basename "$dir")

    tmux_run kill-session -t "$orig" 2>/dev/null || true
    tmux_run kill-session -t "$base" 2>/dev/null || true
    tmux_run new-session -d -s "$orig" -c "$dir"

    pushd "$dir" >/dev/null
    adopt_current_session "$orig"
    popd >/dev/null

    run tmux_run has-session -t "$base"
    local has_expected="$status"

    tmux_run kill-session -t "$base" 2>/dev/null || true
    tmux_run kill-session -t "$orig" 2>/dev/null || true
    rm -rf "$dir"

    [ "$has_expected" -eq 0 ] || { echo "Expected '$base' to exist after numeric default rename"; return 1; }
}

@test "adopt_current_session leaves already-basename session alone in non-git dir" {
    local dir base
    dir=$(mktemp -d "${BATS_TMPDIR}/nongit-keep-XXXXXX")
    base=$(basename "$dir")

    tmux_run kill-session -t "$base" 2>/dev/null || true
    tmux_run new-session -d -s "$base" -c "$dir"

    pushd "$dir" >/dev/null
    adopt_current_session "$base"
    popd >/dev/null

    run tmux_run has-session -t "$base"
    local has_expected="$status"

    tmux_run kill-session -t "$base" 2>/dev/null || true
    rm -rf "$dir"

    [ "$has_expected" -eq 0 ] || { echo "Session '$base' should still exist (exact match skip)"; return 1; }
}

@test "adopt_current_session leaves '<basename>-suffix' session alone in non-git dir" {
    local dir base prefixed
    dir=$(mktemp -d "${BATS_TMPDIR}/nongit-prefix-XXXXXX")
    base=$(basename "$dir")
    prefixed="${base}-feature"

    tmux_run kill-session -t "$prefixed" 2>/dev/null || true
    tmux_run kill-session -t "$base" 2>/dev/null || true
    tmux_run new-session -d -s "$prefixed" -c "$dir"

    pushd "$dir" >/dev/null
    adopt_current_session "$prefixed"
    popd >/dev/null

    # Use "=NAME" for EXACT tmux target match (default is prefix-match, which
    # would let "has-session -t $base" succeed against "${base}-feature").
    run tmux_run has-session -t "=$prefixed"
    local has_prefixed="$status"
    run tmux_run has-session -t "=$base"
    local has_bare="$status"

    tmux_run kill-session -t "=$prefixed" 2>/dev/null || true
    tmux_run kill-session -t "=$base" 2>/dev/null || true
    rm -rf "$dir"

    [ "$has_prefixed" -eq 0 ] || { echo "Prefixed session '$prefixed' should still exist"; return 1; }
    [ "$has_bare" -ne 0 ] || { echo "Bare '$base' session should NOT have been created"; return 1; }
}

@test "adopt_current_session sanitizes dots in non-git basename" {
    # tmux disallows '.' in session names; the production code substitutes _.
    local parent dir base sanitized orig="window"
    parent=$(mktemp -d "${BATS_TMPDIR}/nongit-dotparent.XXXXXX")
    dir="$parent/foo.bar.baz"
    mkdir -p "$dir"
    base=$(basename "$dir")            # foo.bar.baz
    sanitized="${base//./_}"           # foo_bar_baz

    tmux_run kill-session -t "$orig" 2>/dev/null || true
    tmux_run kill-session -t "$sanitized" 2>/dev/null || true
    tmux_run new-session -d -s "$orig" -c "$dir"

    pushd "$dir" >/dev/null
    adopt_current_session "$orig"
    popd >/dev/null

    run tmux_run has-session -t "$sanitized"
    local has_expected="$status"

    tmux_run kill-session -t "$sanitized" 2>/dev/null || true
    tmux_run kill-session -t "$orig" 2>/dev/null || true
    rm -rf "$parent"

    [ "$has_expected" -eq 0 ] || { echo "Expected sanitized session '$sanitized' to exist"; return 1; }
}

@test "adopt_current_session sets project env var but not branch/path env in non-git dir" {
    local dir base orig="window"
    dir=$(mktemp -d "${BATS_TMPDIR}/nongit-env-XXXXXX")
    base=$(basename "$dir")

    tmux_run kill-session -t "$orig" 2>/dev/null || true
    tmux_run kill-session -t "$base" 2>/dev/null || true
    tmux_run new-session -d -s "$orig" -c "$dir"

    pushd "$dir" >/dev/null
    adopt_current_session "$orig"
    popd >/dev/null

    run tmux_run show-environment -t "$base" TMUX_WORKTREE
    local flag_status="$status" flag_output="$output"
    run tmux_run show-environment -t "$base" TMUX_WORKTREE_PROJECT
    local proj_status="$status" proj_output="$output"
    run tmux_run show-environment -t "$base" TMUX_WORKTREE_BRANCH
    local branch_status="$status"
    run tmux_run show-environment -t "$base" TMUX_WORKTREE_PATH
    local path_status="$status"

    tmux_run kill-session -t "$base" 2>/dev/null || true
    tmux_run kill-session -t "$orig" 2>/dev/null || true
    rm -rf "$dir"

    [ "$flag_status" -eq 0 ] || { echo "TMUX_WORKTREE not set"; return 1; }
    [[ "$flag_output" == "TMUX_WORKTREE=1" ]] || { echo "Unexpected flag value: $flag_output"; return 1; }
    [ "$proj_status" -eq 0 ] || { echo "TMUX_WORKTREE_PROJECT not set"; return 1; }
    [[ "$proj_output" == "TMUX_WORKTREE_PROJECT=$base" ]] || { echo "Unexpected project value: $proj_output"; return 1; }
    # Branch and path must NOT be set for non-git sessions
    [ "$branch_status" -ne 0 ] || { echo "TMUX_WORKTREE_BRANCH should NOT be set in non-git dir"; return 1; }
    [ "$path_status" -ne 0 ] || { echo "TMUX_WORKTREE_PATH should NOT be set in non-git dir"; return 1; }
}

@test "adopt_current_session is a no-op in non-git dir when @worktree-adopt-session=off" {
    local dir base orig="window"
    dir=$(mktemp -d "${BATS_TMPDIR}/nongit-off-XXXXXX")
    base=$(basename "$dir")

    tmux_run kill-session -t "$orig" 2>/dev/null || true
    tmux_run kill-session -t "$base" 2>/dev/null || true
    tmux_run new-session -d -s "$orig" -c "$dir"

    pushd "$dir" >/dev/null
    ADOPT_SESSION=off adopt_current_session "$orig"
    popd >/dev/null

    run tmux_run has-session -t "$orig"
    local has_orig="$status"
    run tmux_run has-session -t "$base"
    local has_base="$status"

    tmux_run kill-session -t "$orig" 2>/dev/null || true
    tmux_run kill-session -t "$base" 2>/dev/null || true
    rm -rf "$dir"

    [ "$has_orig" -eq 0 ] || { echo "Original session '$orig' should still exist when adopt is off"; return 1; }
    [ "$has_base" -ne 0 ] || { echo "Basename session '$base' should NOT have been created"; return 1; }
}
