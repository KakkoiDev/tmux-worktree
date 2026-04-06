#!/usr/bin/env bats
# bats file_tags=integration,recent
# Tests for recent branch tracking in the List menu

load '../test_helper'

# Global to capture menu options
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

    # Enable recent branches (default)
    RECENT_COUNT=10
    tmux_set_option "@worktree-recent-count" "10"

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

@test "record_recent_branch auto-trims at 15 entries" {
    for i in $(seq 1 20); do
        record_recent_branch "proj" "branch-$i"
    done

    local count
    count=$(wc -l < "$TMUX_WORKTREE_RECENT_FILE" | tr -d ' ')
    assert_equal "15" "$count"

    # Oldest entries should be gone (1-5), newest kept (6-20)
    run cat "$TMUX_WORKTREE_RECENT_FILE"
    # Use exact line matching to avoid substring false positives (branch-1 vs branch-10)
    local first_line
    first_line=$(head -1 "$TMUX_WORKTREE_RECENT_FILE")
    assert_equal "proj:branch-6" "$first_line"
    local last_line
    last_line=$(tail -1 "$TMUX_WORKTREE_RECENT_FILE")
    assert_equal "proj:branch-20" "$last_line"
}

@test "record_recent_branch auto-trims preserves exactly 15 newest" {
    for i in $(seq 1 16); do
        record_recent_branch "proj" "branch-$i"
    done

    local count
    count=$(wc -l < "$TMUX_WORKTREE_RECENT_FILE" | tr -d ' ')
    assert_equal "15" "$count"

    # branch-1 should be trimmed, branch-2 through branch-16 kept
    local first_line
    first_line=$(head -1 "$TMUX_WORKTREE_RECENT_FILE")
    assert_equal "proj:branch-2" "$first_line"
    local last_line
    last_line=$(tail -1 "$TMUX_WORKTREE_RECENT_FILE")
    assert_equal "proj:branch-16" "$last_line"
}

# ==============================================================================
# get_recent_branches TESTS
# ==============================================================================

@test "get_recent_branches returns branches newest first" {
    record_recent_branch "proj" "alpha"
    record_recent_branch "proj" "beta"
    record_recent_branch "proj" "gamma"

    run get_recent_branches "proj" 10
    assert_success

    # First line should be newest
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

    run get_recent_branches "proj" 10
    assert_success

    # alpha should appear first (most recent), beta second
    local first_line
    first_line=$(echo "$output" | head -1)
    assert_equal "alpha" "$first_line"

    local second_line
    second_line=$(echo "$output" | sed -n '2p')
    assert_equal "beta" "$second_line"

    # Only 2 unique branches
    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    assert_equal "2" "$count"
}

@test "get_recent_branches filters by project" {
    record_recent_branch "proj-a" "branch-a"
    record_recent_branch "proj-b" "branch-b"
    record_recent_branch "proj-a" "branch-c"

    run get_recent_branches "proj-a" 10
    assert_success
    assert_contains "$output" "branch-a"
    assert_contains "$output" "branch-c"
    refute_contains "$output" "branch-b"
}

@test "get_recent_branches respects count limit" {
    record_recent_branch "proj" "a"
    record_recent_branch "proj" "b"
    record_recent_branch "proj" "c"
    record_recent_branch "proj" "d"

    run get_recent_branches "proj" 2
    assert_success

    local count
    count=$(echo "$output" | wc -l | tr -d ' ')
    assert_equal "2" "$count"

    # Should be newest first
    local first_line
    first_line=$(echo "$output" | head -1)
    assert_equal "d" "$first_line"
}

@test "get_recent_branches returns empty for missing file" {
    rm -f "$TMUX_WORKTREE_RECENT_FILE"

    run get_recent_branches "proj" 10
    assert_success
    assert_equal "" "$output"
}

@test "get_recent_branches returns empty when count is 0" {
    record_recent_branch "proj" "alpha"

    run get_recent_branches "proj" 0
    assert_success
    assert_equal "" "$output"
}

@test "get_recent_branches returns empty for unknown project" {
    record_recent_branch "proj-a" "branch"

    run get_recent_branches "proj-b" 10
    assert_success
    assert_equal "" "$output"
}

# ==============================================================================
# RECENT_COUNT CONFIG TESTS
# ==============================================================================

@test "RECENT_COUNT loads from tmux option" {
    tmux_set_option "@worktree-recent-count" "5"
    reload_config

    assert_equal "5" "$RECENT_COUNT"
}

@test "RECENT_COUNT defaults to 10" {
    # Clear the option
    tmux_run set-option -gu "@worktree-recent-count" 2>/dev/null || true
    reload_config

    assert_equal "10" "$RECENT_COUNT"
}

@test "RECENT_COUNT accepts 0 (disabled)" {
    tmux_set_option "@worktree-recent-count" "0"
    reload_config

    assert_equal "0" "$RECENT_COUNT"
}

# ==============================================================================
# OPTIONS MENU TESTS
# ==============================================================================

@test "options menu shows Recent count option" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Recent count:'
}

@test "options menu shows current RECENT_COUNT value" {
    tmux_set_option "@worktree-recent-count" "5"
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'Recent count: 5'
}

@test "options menu uses set_option dispatch for recent-count" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" 'set_option @worktree-recent-count'
}

# ==============================================================================
# LIST MENU RECENT TOGGLE TESTS
# ==============================================================================

@test "list menu shows Recent action item when RECENT_COUNT > 0" {
    show_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Recent" "r"'
}

@test "list menu hides Recent action item when RECENT_COUNT = 0" {
    RECENT_COUNT=0
    tmux_set_option "@worktree-recent-count" "0"

    show_worktree_menu 1
    refute_contains "$CAPTURED_MENU_OPTIONS" '"Recent" "r"'

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "list menu shows Hide recent when recent is toggled on" {
    show_worktree_menu 1 "" 1
    assert_contains "$CAPTURED_MENU_OPTIONS" '"Hide recent" "r"'
}

@test "list menu shows recent section only when toggled on" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    local project_name
    project_name=$(get_project_name)
    record_recent_branch "$project_name" "feature-one"

    # Default: no [Recent] in title
    show_worktree_menu 1
    refute_contains "$CAPTURED_MENU_TITLE" "[Recent]"

    # Toggled on: [Recent] appears in title
    show_worktree_menu 1 "" 1
    assert_contains "$CAPTURED_MENU_TITLE" "[Recent]"

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "list menu recent section shows branch when toggled on" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    local project_name
    project_name=$(get_project_name)
    record_recent_branch "$project_name" "feature-one"

    show_worktree_menu 1 "" 1
    assert_contains "$CAPTURED_MENU_OPTIONS" 'switch_worktree feature-one'

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "list menu does not show recent section when disabled even if toggled" {
    RECENT_COUNT=0
    tmux_set_option "@worktree-recent-count" "0"

    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    local project_name
    project_name=$(get_project_name)
    record_recent_branch "$project_name" "feature-one"

    show_worktree_menu 1 "" 1
    refute_contains "$CAPTURED_MENU_TITLE" "[Recent]"

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "list menu recent only shows active worktrees" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    local project_name
    project_name=$(get_project_name)
    record_recent_branch "$project_name" "feature-two"
    record_recent_branch "$project_name" "feature-one"

    show_worktree_menu 1 "" 1
    assert_contains "$CAPTURED_MENU_TITLE" "[Recent]"

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "list menu recent section does not duplicate in main list" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one
    git worktree add -q "$wt_dir/feature-two" feature-two

    local project_name
    project_name=$(get_project_name)
    record_recent_branch "$project_name" "feature-one"

    show_worktree_menu 1 "" 1

    local switch_count
    switch_count=$(echo "$CAPTURED_MENU_OPTIONS" | grep -o "switch_worktree feature-one" | wc -l | tr -d ' ')
    assert_equal "1" "$switch_count"

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    git worktree remove --force "$wt_dir/feature-two" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "list menu recent section only on page 1" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    local project_name
    project_name=$(get_project_name)
    record_recent_branch "$project_name" "feature-one"

    show_worktree_menu 2 "" 1
    refute_contains "$CAPTURED_MENU_TITLE" "[Recent]"

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "list menu filter preserves show_recent state" {
    show_worktree_menu 1 "" 1
    # The filter option should pass show_recent=1 through
    assert_contains "$CAPTURED_MENU_OPTIONS" "show_worktree_menu 1"
    assert_contains "$CAPTURED_MENU_OPTIONS" "1\\\"'\""
}

@test "list menu recent toggle dispatches correct command" {
    show_worktree_menu 1
    # The Recent action should dispatch show_worktree_menu with show_recent=1
    assert_contains "$CAPTURED_MENU_OPTIONS" "show_worktree_menu 1 '' 1"
}

# ==============================================================================
# switch_worktree DISPATCH TESTS
# ==============================================================================

@test "switch_worktree is a recognized dispatch command" {
    run bash -c "
        source '$SCRIPTS_DIR/helpers.sh'
        source '$SCRIPTS_DIR/filter.sh'
        load_config
        source '$SCRIPTS_DIR/worktree_manager.sh'
        type switch_worktree
    "
    assert_success
    assert_contains "$output" "function"
}

@test "list menu worktree items use switch_worktree dispatch" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    show_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" 'switch_worktree'

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "switch_worktree records branch to recent log" {
    local wt_dir="${BATS_TMPDIR}/worktrees-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/feature-one" feature-one

    # Mock tmux to avoid actual session operations
    local orig_tmux
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

    # Restore tmux
    unset -f tmux

    git worktree remove --force "$wt_dir/feature-one" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "add_worktree records branch to recent log" {
    # Mock tmux to avoid actual session operations
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

    # Cleanup worktree
    local project_name
    project_name=$(get_project_name)
    local wt_path="$WORKTREE_BASE/$project_name/feature-one"
    git worktree remove --force "$wt_path" 2>/dev/null || true
}

@test "create_new_worktree records branch to recent log" {
    # Mock tmux to avoid actual session operations
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

    # Cleanup worktree and branch
    local project_name
    project_name=$(get_project_name)
    local wt_path="$WORKTREE_BASE/$project_name/test-new-branch"
    git worktree remove --force "$wt_path" 2>/dev/null || true
    git branch -D "test-new-branch" 2>/dev/null || true
}

# ==============================================================================
# _RECENT_LOG_MAX BOUNDARY TESTS
# ==============================================================================

@test "recent log never exceeds 15 entries even with rapid writes" {
    for i in $(seq 1 30); do
        record_recent_branch "proj" "branch-$i"
    done

    local count
    count=$(wc -l < "$TMUX_WORKTREE_RECENT_FILE" | tr -d ' ')
    [ "$count" -le 15 ]
}

@test "recent log trim preserves newest entries" {
    for i in $(seq 1 18); do
        record_recent_branch "proj" "b-$i"
    done

    # Newest should be last, oldest trimmed
    local first_line
    first_line=$(head -1 "$TMUX_WORKTREE_RECENT_FILE")
    assert_equal "proj:b-4" "$first_line"
    local last_line
    last_line=$(tail -1 "$TMUX_WORKTREE_RECENT_FILE")
    assert_equal "proj:b-18" "$last_line"
}
