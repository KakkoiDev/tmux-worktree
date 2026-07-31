#!/usr/bin/env bats
# Tests for fetch prune configuration option

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

    init_test_worktree_base
}

teardown() {
    safe_cleanup_worktree_base
}

# ==============================================================================
# FETCH_PRUNE Config Tests
# ==============================================================================

@test "FETCH_PRUNE defaults to off" {
    source "$SCRIPTS_DIR/helpers.sh"
    load_config
    assert_equal "off" "$FETCH_PRUNE"
}

@test "FETCH_PRUNE can be set to on via tmux option" {
    tmux_set_option "@worktree-fetch-prune" "on"
    source "$SCRIPTS_DIR/helpers.sh"
    reload_config
    assert_equal "on" "$FETCH_PRUNE"

    # Cleanup
    tmux_run set-option -gu "@worktree-fetch-prune"
}

@test "FETCH_PRUNE is included in config cache" {
    source "$SCRIPTS_DIR/helpers.sh"
    reload_config

    local cache_file
    cache_file=$(_get_config_cache_file)
    run cat "$cache_file"
    assert_success
    assert_contains "$output" "FETCH_PRUNE="
}

# ==============================================================================
# Fetch Behavior Tests
# ==============================================================================

@test "fetch without prune keeps deleted remote branches" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a bare remote with an extra branch
    local remote_dir="${TEST_REPO_DIR}-remote"
    git clone --bare . "$remote_dir"
    git remote add origin "$remote_dir"

    # Create branch on remote and fetch it
    git -C "$remote_dir" branch temp-branch master
    git fetch origin

    # Verify remote branch is tracked
    run git branch -r
    assert_contains "$output" "origin/temp-branch"

    # Delete branch on remote
    git -C "$remote_dir" branch -D temp-branch

    # Fetch with prune OFF (default) - branch should remain
    FETCH_PRUNE="off"
    fetch_remote_branches

    run git branch -r
    assert_contains "$output" "origin/temp-branch"

    # Cleanup
    git remote remove origin
    rm -rf "$remote_dir"
}

@test "fetch with prune on removes deleted remote branches" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    # Create a bare remote with an extra branch
    local remote_dir="${TEST_REPO_DIR}-remote"
    git clone --bare . "$remote_dir"
    git remote add origin "$remote_dir"

    # Create branch on remote and fetch it
    git -C "$remote_dir" branch temp-branch master
    git fetch origin

    # Verify remote branch is tracked
    run git branch -r
    assert_contains "$output" "origin/temp-branch"

    # Delete branch on remote
    git -C "$remote_dir" branch -D temp-branch

    # Fetch with prune ON - branch should be removed
    FETCH_PRUNE="on"
    fetch_remote_branches

    run git branch -r
    refute_contains "$output" "origin/temp-branch"

    # Cleanup
    git remote remove origin
    rm -rf "$remote_dir"
}

# ==============================================================================
# Options Menu Tests
# ==============================================================================

@test "options menu shows fetch prune toggle" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_show() {
        printf '%s\n' "${TK_MENU_ARGS[@]}"
        TK_MENU_ARGS=()
    }

    FETCH_PRUNE="off"
    run show_options_menu
    assert_success
    assert_contains "$output" "Fetch prune: off"
}

@test "options menu cycles fetch prune from off to on" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_show() {
        printf '%s\n' "${TK_MENU_ARGS[@]}"
        TK_MENU_ARGS=()
    }

    # Default is off, so next value should be on
    run show_options_menu
    assert_success
    assert_contains "$output" "Fetch prune: off"
    # tk_menu_cmd produces single-quoted args
    assert_contains "$output" "@worktree-fetch-prune"
    assert_contains "$output" "'on'"
}

@test "options menu cycles fetch prune from on to off" {
    source "$SCRIPTS_DIR/worktree_manager.sh"

    tk_menu_show() {
        printf '%s\n' "${TK_MENU_ARGS[@]}"
        TK_MENU_ARGS=()
    }

    # Set to on via tmux, next value should be off
    tmux_set_option "@worktree-fetch-prune" "on"
    run show_options_menu
    assert_success
    assert_contains "$output" "Fetch prune: on"
    # tk_menu_cmd produces single-quoted args
    assert_contains "$output" "@worktree-fetch-prune"
    assert_contains "$output" "'off'"

    # Cleanup
    tmux_run set-option -gu "@worktree-fetch-prune"
}

# ==============================================================================
# Project Config Tests
# ==============================================================================

@test "fetch-prune can be set via project config" {
    source "$SCRIPTS_DIR/helpers.sh"

    # Create project config
    echo "fetch-prune = on" > "$TEST_REPO_DIR/.tmux-worktree.conf"

    # Ensure no explicit tmux option
    tmux_run set-option -gu "@worktree-fetch-prune" 2>/dev/null || true

    reload_config
    assert_equal "on" "$FETCH_PRUNE"

    # Cleanup
    rm -f "$TEST_REPO_DIR/.tmux-worktree.conf"
}

@test "explicit tmux option overrides project config for fetch-prune" {
    source "$SCRIPTS_DIR/helpers.sh"

    # Set project config to on
    echo "fetch-prune = on" > "$TEST_REPO_DIR/.tmux-worktree.conf"

    # Set explicit tmux option to off
    tmux_set_option "@worktree-fetch-prune" "off"

    reload_config
    assert_equal "off" "$FETCH_PRUNE"

    # Cleanup
    tmux_run set-option -gu "@worktree-fetch-prune"
    rm -f "$TEST_REPO_DIR/.tmux-worktree.conf"
}
