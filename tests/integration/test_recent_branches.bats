#!/usr/bin/env bats
# bats file_tags=integration,recent
# Tests for recent branch tracking and sort_recent toggle in the List menu

load '../test_helper'

# Globals to capture menu output
CAPTURED_MENU_TITLE=""
CAPTURED_MENU_OPTIONS=""

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
    source_script "$SCRIPTS_DIR/helpers.sh"
    source_script "$SCRIPTS_DIR/filter.sh"
    cd "$TEST_REPO_DIR" || exit 1
    load_config
    source_script "$SCRIPTS_DIR/worktree_manager.sh"

    # CRITICAL: Set WORKTREE_BASE AFTER load_config because load_config overwrites it
    init_test_worktree_base

    # Set tmux option so reload_config uses test path
    tmux_set_option "@worktree-path" "$WORKTREE_BASE"

    # Use isolated recent file for each test
    export TMUX_WORKTREE_RECENT_FILE="$WORKTREE_BASE/.recent-test.log"

    # Mock display_menu to capture title and options
    display_menu() {
        CAPTURED_MENU_TITLE="$1"
        CAPTURED_MENU_OPTIONS="$2"
    }
}

teardown() {
    CAPTURED_MENU_TITLE=""
    CAPTURED_MENU_OPTIONS=""
    rm -f "$TMUX_WORKTREE_RECENT_FILE" 2>/dev/null
    safe_cleanup_worktree_base
}

# ==============================================================================
# record_recent_branch TESTS
# ==============================================================================

@test "record_recent_branch creates file and writes entry" {
    record_recent_branch "myproject" "feature-one"

    [ -f "$TMUX_WORKTREE_RECENT_FILE" ]
    run cat "$TMUX_WORKTREE_RECENT_FILE"
    assert_contains "$output" "myproject:feature-one"
}

@test "record_recent_branch appends multiple entries" {
    record_recent_branch "myproject" "feature-one"
    record_recent_branch "myproject" "feature-two"

    local count
    count=$(wc -l < "$TMUX_WORKTREE_RECENT_FILE" | tr -d ' ')
    assert_equal "2" "$count"
}

@test "record_recent_branch ignores empty project" {
    record_recent_branch "" "feature-one"
    [ ! -f "$TMUX_WORKTREE_RECENT_FILE" ]
}

@test "record_recent_branch ignores empty branch" {
    record_recent_branch "myproject" ""
    [ ! -f "$TMUX_WORKTREE_RECENT_FILE" ]
}

@test "record_recent_branch auto-trims for file hygiene" {
    for i in $(seq 1 110); do
        record_recent_branch "proj" "branch-$i"
    done

    local count
    count=$(wc -l < "$TMUX_WORKTREE_RECENT_FILE" | tr -d ' ')
    assert_equal "100" "$count"
}

# ==============================================================================
# remove_recent_branch TESTS
# ==============================================================================

@test "remove_recent_branch removes matching entries" {
    record_recent_branch "proj" "alpha"
    record_recent_branch "proj" "beta"
    record_recent_branch "proj" "alpha"

    remove_recent_branch "proj" "alpha"

    run cat "$TMUX_WORKTREE_RECENT_FILE"
    refute_contains "$output" "alpha"
    assert_contains "$output" "beta"
}

@test "remove_recent_branch does nothing for missing file" {
    rm -f "$TMUX_WORKTREE_RECENT_FILE"
    run remove_recent_branch "proj" "alpha"
    assert_success
}

@test "remove_recent_branch only removes exact match" {
    record_recent_branch "proj" "feature"
    record_recent_branch "proj" "feature-two"

    remove_recent_branch "proj" "feature"

    local count
    count=$(wc -l < "$TMUX_WORKTREE_RECENT_FILE" | tr -d ' ')
    assert_equal "1" "$count"
    run cat "$TMUX_WORKTREE_RECENT_FILE"
    assert_equal "proj:feature-two" "$output"
}

@test "remove_recent_branch scoped to project" {
    record_recent_branch "proj-a" "branch"
    record_recent_branch "proj-b" "branch"

    remove_recent_branch "proj-a" "branch"

    run cat "$TMUX_WORKTREE_RECENT_FILE"
    refute_contains "$output" "proj-a:branch"
    assert_contains "$output" "proj-b:branch"
}

# ==============================================================================
# get_recent_branches TESTS
# ==============================================================================

@test "get_recent_branches returns branches newest first" {
    record_recent_branch "proj" "alpha"
    record_recent_branch "proj" "beta"
    record_recent_branch "proj" "gamma"

    run get_recent_branches "proj"
    assert_success

    local first_line
    first_line=$(echo "$output" | head -1)
    assert_equal "gamma" "$first_line"

    local second_line
    second_line=$(echo "$output" | sed -n '2p')
    assert_equal "beta" "$second_line"
}

@test "get_recent_branches deduplicates keeping latest position" {
    record_recent_branch "proj" "alpha"
    record_recent_branch "proj" "beta"
    record_recent_branch "proj" "alpha"

    run get_recent_branches "proj"
    assert_success

    local first_line
    first_line=$(echo "$output" | head -1)
    assert_equal "alpha" "$first_line"

    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    assert_equal "2" "$count"
}

@test "get_recent_branches filters by project" {
    record_recent_branch "proj-a" "branch-a"
    record_recent_branch "proj-b" "branch-b"
    record_recent_branch "proj-a" "branch-c"

    run get_recent_branches "proj-a"
    assert_success
    assert_contains "$output" "branch-a"
    assert_contains "$output" "branch-c"
    refute_contains "$output" "branch-b"
}

@test "get_recent_branches returns all unique branches" {
    for i in $(seq 1 20); do
        record_recent_branch "proj" "branch-$i"
    done

    run get_recent_branches "proj"
    assert_success

    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    assert_equal "20" "$count"
}

@test "get_recent_branches returns empty for missing file" {
    rm -f "$TMUX_WORKTREE_RECENT_FILE"

    run get_recent_branches "proj"
    assert_success
    assert_equal "" "$output"
}

@test "get_recent_branches returns empty for unknown project" {
    record_recent_branch "proj-a" "branch"

    run get_recent_branches "proj-b"
    assert_success
    assert_equal "" "$output"
}

# ==============================================================================
# LIST MENU - SORT_RECENT TOGGLE
# ==============================================================================

@test "list menu shows Recent toggle when sort_recent=0" {
    show_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Recent" "r"'
}

@test "list menu shows Default toggle when sort_recent=1" {
    show_worktree_menu 1 "" 1
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Default" "r"'
}

@test "list menu title shows [Recent] when sort_recent=1" {
    show_worktree_menu 1 "" 1
    assert_contains "$CAPTURED_MENU_TITLE" "[Recent]"
}

@test "list menu title normal when sort_recent=0" {
    show_worktree_menu 1
    refute_contains "$CAPTURED_MENU_TITLE" "[Recent]"
}

@test "list menu Recent toggle dispatches with sort_recent=1" {
    show_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" "show_worktree_menu 1 '' 1"
}

@test "list menu Default toggle dispatches with sort_recent=0" {
    show_worktree_menu 1 "" 1
    assert_contains "$CAPTURED_MENU_OPTIONS" "show_worktree_menu 1 '' 0"
}

@test "list menu filter preserves sort_recent state" {
    show_worktree_menu 1 "" 1
    # Filter command should include sort_recent=1
    assert_contains "$CAPTURED_MENU_OPTIONS" "show_worktree_menu 1"
    assert_contains "$CAPTURED_MENU_OPTIONS" "1\\\"'\""
}

@test "list menu clear filter preserves sort_recent state" {
    show_worktree_menu 1 "test*" 1
    assert_contains "$CAPTURED_MENU_OPTIONS" "show_worktree_menu 1 '' 1"
}

@test "list menu sort_recent shows all worktrees reordered" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one
    git worktree add -q "$wt_dir/bugfix-123" bugfix-123

    # Record only feature-one as recent
    local project_name
    project_name=$(get_project_name)
    record_recent_branch "$project_name" "feature-one"

    show_worktree_menu 1 "" 1

    # Both worktrees should appear (all worktrees, reordered)
    assert_contains "$CAPTURED_MENU_OPTIONS" "feature-one"
    assert_contains "$CAPTURED_MENU_OPTIONS" "bugfix-123"

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    git worktree remove --force "$wt_dir/bugfix-123" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "list menu sort_recent puts recent branches first" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one
    git worktree add -q "$wt_dir/bugfix-123" bugfix-123

    # Record bugfix-123 as most recent
    local project_name
    project_name=$(get_project_name)
    record_recent_branch "$project_name" "bugfix-123"

    show_worktree_menu 1 "" 1

    # bugfix-123 should appear before feature-one in the menu options
    local bugfix_pos feature_pos
    bugfix_pos=$(echo "$CAPTURED_MENU_OPTIONS" | grep -bo "bugfix-123" | head -1 | cut -d: -f1)
    feature_pos=$(echo "$CAPTURED_MENU_OPTIONS" | grep -bo "feature-one" | head -1 | cut -d: -f1)
    [ "$bugfix_pos" -lt "$feature_pos" ]

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    git worktree remove --force "$wt_dir/bugfix-123" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "list menu normal order not affected by recent log" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one
    git worktree add -q "$wt_dir/bugfix-123" bugfix-123

    local project_name
    project_name=$(get_project_name)
    record_recent_branch "$project_name" "bugfix-123"

    # sort_recent=0 should use normal git order
    show_worktree_menu 1 "" 0

    # Both should appear
    assert_contains "$CAPTURED_MENU_OPTIONS" "feature-one"
    assert_contains "$CAPTURED_MENU_OPTIONS" "bugfix-123"

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    git worktree remove --force "$wt_dir/bugfix-123" 2>/dev/null || true
    rm -rf "$wt_dir"
}

# ==============================================================================
# OPTIONS MENU - NO RECENT COUNT
# ==============================================================================

@test "options menu does not show Recent count option" {
    show_options_menu
    refute_contains "$CAPTURED_MENU_OPTIONS" 'Recent count'
}

# ==============================================================================
# switch_worktree + RECORDING TESTS
# ==============================================================================

@test "switch_worktree records branch to recent log" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    tmux() {
        case "$1" in
            has-session) return 1 ;;
            new-session) return 0 ;;
            switch-client) return 0 ;;
            *) command tmux -L "$TMUX_SOCKET" "$@" ;;
        esac
    }
    export -f tmux

    switch_worktree "feature-one" "$wt_dir/feature-one"

    [ -f "$TMUX_WORKTREE_RECENT_FILE" ]
    run cat "$TMUX_WORKTREE_RECENT_FILE"
    assert_contains "$output" "feature-one"

    unset -f tmux
    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "add_worktree records branch to recent log" {
    tmux() {
        case "$1" in
            new-session) return 0 ;;
            switch-client) return 0 ;;
            display-message) return 0 ;;
            *) command tmux -L "$TMUX_SOCKET" "$@" ;;
        esac
    }
    export -f tmux

    add_worktree "feature-one"

    [ -f "$TMUX_WORKTREE_RECENT_FILE" ]
    run cat "$TMUX_WORKTREE_RECENT_FILE"
    assert_contains "$output" "feature-one"

    unset -f tmux
    local project_name
    project_name=$(get_project_name)
    git worktree remove --force "$WORKTREE_BASE/$project_name/feature-one" 2>/dev/null || true
}

@test "create_new_worktree records branch to recent log" {
    tmux() {
        case "$1" in
            new-session) return 0 ;;
            switch-client) return 0 ;;
            display-message) return 0 ;;
            *) command tmux -L "$TMUX_SOCKET" "$@" ;;
        esac
    }
    export -f tmux

    create_new_worktree "test-new-branch"

    [ -f "$TMUX_WORKTREE_RECENT_FILE" ]
    run cat "$TMUX_WORKTREE_RECENT_FILE"
    assert_contains "$output" "test-new-branch"

    unset -f tmux
    local project_name
    project_name=$(get_project_name)
    git worktree remove --force "$WORKTREE_BASE/$project_name/test-new-branch" 2>/dev/null || true
    git branch -D "test-new-branch" 2>/dev/null || true
}

# ==============================================================================
# REMOVE WORKTREE CLEANS RECENT LOG
# ==============================================================================

@test "remove_worktree cleans entry from recent log" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    local project_name
    project_name=$(get_project_name)
    record_recent_branch "$project_name" "feature-one"
    record_recent_branch "$project_name" "feature-two"

    run cat "$TMUX_WORKTREE_RECENT_FILE"
    assert_contains "$output" "feature-one"

    show_remove_worktree_menu() { :; }
    remove_worktree "$wt_dir/feature-one" "feature-one" "test-session" "1"

    run cat "$TMUX_WORKTREE_RECENT_FILE"
    refute_contains "$output" "feature-one"
    assert_contains "$output" "feature-two"

    rm -rf "$wt_dir"
}

# ==============================================================================
# LIST MENU WORKTREE DATA TESTS
# ==============================================================================

@test "list menu worktree items use switch_worktree dispatch" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    show_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" 'switch_worktree'

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}
