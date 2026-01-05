#!/usr/bin/env bats
# Tests for TPM plugin loader (worktrees.tmux)

load test_helper

setup() {
    TEST_REPO_DIR=$(create_test_repo)
    start_tmux_server
}

teardown() {
    stop_tmux_server
    cleanup_test_repo
}

# ==============================================================================
# Plugin Structure Tests
# ==============================================================================

@test "worktrees.tmux exists and is executable" {
    assert_file_exists "$PLUGIN_DIR/worktrees.tmux"
    assert_executable "$PLUGIN_DIR/worktrees.tmux"
}

@test "scripts/helpers.sh exists and is executable" {
    assert_file_exists "$SCRIPTS_DIR/helpers.sh"
    assert_executable "$SCRIPTS_DIR/helpers.sh"
}

@test "plugin loader sources without error" {
    run bash "$PLUGIN_DIR/worktrees.tmux"
    assert_success
}

# ==============================================================================
# Configuration Reading Tests
# ==============================================================================

@test "get_tmux_option returns default when option not set" {
    source_script "$SCRIPTS_DIR/helpers.sh"

    # Ensure option is not set
    tmux_run set-option -gu "@worktree-test-option" 2>/dev/null || true

    run get_tmux_option "@worktree-test-option" "default-value"
    assert_success
    assert_equal "default-value" "$output"
}

@test "get_tmux_option returns set value when option exists" {
    source_script "$SCRIPTS_DIR/helpers.sh"

    tmux_set_option "@worktree-test-option" "custom-value"

    run get_tmux_option "@worktree-test-option" "default-value"
    assert_success
    assert_equal "custom-value" "$output"
}

@test "default WORKTREE_BASE is ~/.tmux-worktrees/worktrees" {
    source_script "$SCRIPTS_DIR/helpers.sh"

    # Ensure option is not set
    tmux_run set-option -gu "@worktree-path" 2>/dev/null || true

    load_config
    assert_equal "$HOME/.tmux-worktrees/worktrees" "$WORKTREE_BASE"
}

@test "WORKTREE_BASE can be overridden via @worktree-path" {
    source_script "$SCRIPTS_DIR/helpers.sh"

    tmux_set_option "@worktree-path" "/custom/worktree/path"

    load_config
    assert_equal "/custom/worktree/path" "$WORKTREE_BASE"
}

@test "default ITEMS_PER_PAGE is 15" {
    source_script "$SCRIPTS_DIR/helpers.sh"

    # Ensure option is not set
    tmux_run set-option -gu "@worktree-items-per-page" 2>/dev/null || true

    load_config
    assert_equal "15" "$ITEMS_PER_PAGE"
}

@test "ITEMS_PER_PAGE can be overridden via @worktree-items-per-page" {
    source_script "$SCRIPTS_DIR/helpers.sh"

    tmux_set_option "@worktree-items-per-page" "25"

    load_config
    assert_equal "25" "$ITEMS_PER_PAGE"
}

@test "default FETCH_TIMEOUT is 30" {
    source_script "$SCRIPTS_DIR/helpers.sh"

    # Ensure option is not set
    tmux_run set-option -gu "@worktree-fetch-timeout" 2>/dev/null || true

    load_config
    assert_equal "30" "$FETCH_TIMEOUT"
}

@test "FETCH_TIMEOUT can be overridden via @worktree-fetch-timeout" {
    source_script "$SCRIPTS_DIR/helpers.sh"

    tmux_set_option "@worktree-fetch-timeout" "60"

    load_config
    assert_equal "60" "$FETCH_TIMEOUT"
}

# ==============================================================================
# Plugin Environment Tests
# ==============================================================================

@test "PLUGIN_DIR environment variable is set after loading" {
    run bash -c "source '$PLUGIN_DIR/worktrees.tmux' && echo \$TMUX_WORKTREES_PLUGIN_DIR"
    assert_success
    assert_contains "$output" "tmux-worktree"
}

@test "SCRIPTS_DIR points to valid scripts directory" {
    source_script "$SCRIPTS_DIR/helpers.sh"
    [ -d "$SCRIPTS_DIR" ]
}
