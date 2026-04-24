#!/usr/bin/env bats
# E2E tests for tmux display-menu interaction
#
# These tests exercise the full pipeline: menu generation -> tmux display-menu
# parsing -> pty key selection -> action execution.
#
# Requires: expect (v5.45+), tmux 3.0+
# Run with: make test-e2e

load '../test_helper'
load '../expect_helper'

setup_file() {
    if ! command -v expect >/dev/null 2>&1; then
        skip "expect not available"
    fi

    export SHARED_REPO_DIR
    SHARED_REPO_DIR=$(create_shared_repo)
    cd "$SHARED_REPO_DIR"

    start_e2e_server "$SHARED_REPO_DIR"

    # Set worktree base to isolated temp directory
    export E2E_WORKTREE_BASE="/tmp/e2e-worktree-test-$$"
    mkdir -p "$E2E_WORKTREE_BASE"
    e2e_tmux set-option -g "@worktree-path" "$E2E_WORKTREE_BASE"
}

teardown_file() {
    stop_e2e_server
    if [ -n "${E2E_WORKTREE_BASE:-}" ] && [[ "$E2E_WORKTREE_BASE" == /tmp/* ]]; then
        rm -rf "$E2E_WORKTREE_BASE"
    fi
    cleanup_shared_repo
}

setup() {
    reset_shared_repo
    cd "$TEST_REPO_DIR" || exit 1

    # Source scripts for SCRIPTS_DIR references
    source_script "$SCRIPTS_DIR/helpers.sh"
    source_script "$SCRIPTS_DIR/filter.sh"

    # Respawn the pane in the test repo directory (deterministic, no send-keys cd)
    e2e_tmux respawn-pane -k -t e2e-session -c "$TEST_REPO_DIR"
    sleep 0.3

    # Set worktree base
    e2e_tmux set-option -g "@worktree-path" "$E2E_WORKTREE_BASE"
}

teardown() {
    e2e_cleanup_sessions

    # Remove any test worktrees
    if [ -n "${TEST_REPO_DIR:-}" ] && [ -d "$TEST_REPO_DIR" ]; then
        cd "$TEST_REPO_DIR" 2>/dev/null || true
        git worktree list --porcelain 2>/dev/null | grep "^worktree " | cut -d' ' -f2 | while read -r wt; do
            [ "$wt" != "$TEST_REPO_DIR" ] && git worktree remove --force "$wt" 2>/dev/null || true
        done
    fi
}

# ==============================================================================
# SMOKE TEST
# ==============================================================================

@test "e2e: main menu opens and quit closes cleanly" {
    run e2e_main_menu "q"
    assert_success
}

# ==============================================================================
# TIER 1: run-shell DISPATCH (tests command pipeline)
#
# These call run-shell directly, testing the exact command strings that menu
# items embed. Some functions (set_option, add_worktree) re-display a menu
# at the end, which fails without an attached pty client. This is expected -
# we ignore the run-shell exit code and verify side effects only.
# ==============================================================================

@test "e2e: set_option dispatch sets tmux option" {
    e2e_tmux set-option -g "@worktree-debug" "off"

    # run-shell may return 1 because set_option re-opens the options menu
    # which needs a client for display-menu. The option IS set before that.
    e2e_tmux run-shell "'$SCRIPTS_DIR/worktree_manager.sh' set_option @worktree-debug on" 2>/dev/null || true
    sleep 1

    local actual
    actual=$(e2e_tmux show-option -gqv "@worktree-debug")
    assert_equal "on" "$actual"
}

@test "e2e: add_worktree dispatch creates worktree" {
    local project_name
    project_name=$(basename "$TEST_REPO_DIR")

    # May return non-zero if switch_worktree/display-menu fails without client
    e2e_tmux run-shell "'$SCRIPTS_DIR/worktree_manager.sh' add_worktree feature-one" 2>/dev/null || true

    local wt_path="$E2E_WORKTREE_BASE/$project_name/feature-one"
    e2e_wait_dir "$wt_path" 5
    [ -d "$wt_path" ]
}

@test "e2e: remove_worktree dispatch removes worktree" {
    local project_name
    project_name=$(basename "$TEST_REPO_DIR")
    local wt_path="$E2E_WORKTREE_BASE/$project_name/feature-two"

    # Setup: create worktree
    mkdir -p "$(dirname "$wt_path")"
    cd "$TEST_REPO_DIR" && git worktree add -q "$wt_path" feature-two
    [ -d "$wt_path" ]

    local session_name
    session_name=$(echo "${project_name}-feature-two" | tr '/' '_' | tr '.' '_')

    e2e_tmux run-shell "'$SCRIPTS_DIR/worktree_manager.sh' remove_worktree '$wt_path' feature-two '$session_name' 1" 2>/dev/null || true
    sleep 2

    [ ! -d "$wt_path" ]
}

@test "e2e: branch with dots survives run-shell quoting" {
    cd "$TEST_REPO_DIR"
    git branch "release/1.0.0" 2>/dev/null || true

    local project_name
    project_name=$(basename "$TEST_REPO_DIR")

    e2e_tmux run-shell "'$SCRIPTS_DIR/worktree_manager.sh' add_worktree 'release/1.0.0'" 2>/dev/null || true

    local wt_path="$E2E_WORKTREE_BASE/$project_name/release/1.0.0"
    e2e_wait_dir "$wt_path" 5
    [ -d "$wt_path" ]
}

@test "e2e: branch with nested slashes survives run-shell quoting" {
    cd "$TEST_REPO_DIR"
    git branch "feature/auth/oauth" 2>/dev/null || true

    local project_name
    project_name=$(basename "$TEST_REPO_DIR")

    e2e_tmux run-shell "'$SCRIPTS_DIR/worktree_manager.sh' add_worktree 'feature/auth/oauth'" 2>/dev/null || true

    local wt_path="$E2E_WORKTREE_BASE/$project_name/feature/auth/oauth"
    e2e_wait_dir "$wt_path" 5
    [ -d "$wt_path" ]
}

# ==============================================================================
# TIER 2: PTY MENU INTERACTION (tests real display-menu overlay)
# ==============================================================================

@test "e2e: main menu List key opens worktree list submenu" {
    # Press "l" (List) to open worktree list. The submenu opens via run-shell
    # (async). Expect detaches after a delay regardless.
    run e2e_main_menu "l"
    assert_success
}

@test "e2e: main menu Options key opens options submenu" {
    run e2e_main_menu "o"
    assert_success
}

@test "e2e: options menu cycles debug value via arrow+enter" {
    e2e_tmux set-option -g "@worktree-debug" "off"

    # Open options menu directly. Debug is the 2nd item (index 1).
    # First item is "Copy ignored", so DOWN once reaches "Debug", ENTER selects.
    run e2e_sub_menu "show_options_menu" "DOWN|ENTER"
    assert_success

    # The set_option dispatch runs via run-shell (async). Wait for it.
    e2e_wait_option "@worktree-debug" "on" 5
    local actual
    actual=$(e2e_tmux show-option -gqv "@worktree-debug")
    assert_equal "on" "$actual"
}

@test "e2e: options menu cycles items-per-page" {
    e2e_tmux set-option -g "@worktree-items-per-page" "15"

    # Items/page is the 3rd item. DOWN x2 to reach it, ENTER to select.
    run e2e_sub_menu "show_options_menu" "DOWN|DOWN|ENTER"
    assert_success

    e2e_wait_option "@worktree-items-per-page" "20" 5
    local actual
    actual=$(e2e_tmux show-option -gqv "@worktree-items-per-page")
    assert_equal "20" "$actual"
}

@test "e2e: keybinding prefix+W opens main menu" {
    # Load plugin to bind prefix+W (uses TMUX_SOCKET for the E2E server)
    e2e_load_plugin
    sleep 1

    # Send prefix+W (keybinding), then "q" to close the menu
    run e2e_send_keys "W" "q"
    assert_success
}

# ==============================================================================
# TIER 3: MENU CONTENT ASSERTIONS (capture overlay bytes, grep after strip)
# ==============================================================================

@test "e2e: main menu renders expected top-level items" {
    out=$(e2e_capture_menu "run-shell '${SCRIPTS_DIR}/worktree_manager.sh tmux_worktrees_main'" "")
    e2e_assert_menu_contains "$out" "Git Worktrees" "List" "Add" "Remove" "Options" "Quit"
}

@test "e2e: options menu renders expected settings" {
    out=$(e2e_capture_menu "run-shell '${SCRIPTS_DIR}/worktree_manager.sh show_options_menu'" "")
    e2e_assert_menu_contains "$out" "Options" "Debug" "Items/page"
}

@test "e2e: list menu shows existing worktrees" {
    cd "$TEST_REPO_DIR"
    local project_name
    project_name=$(basename "$TEST_REPO_DIR")
    local wt_path="$E2E_WORKTREE_BASE/$project_name/feature-one"
    git worktree add -q "$wt_path" feature-one

    out=$(e2e_capture_menu "run-shell '${SCRIPTS_DIR}/worktree_manager.sh show_worktree_menu 1'" "")
    e2e_assert_menu_contains "$out" "feature-one"
}

@test "e2e: fetch-prune toggle shows current state in options menu" {
    e2e_tmux set-option -g "@worktree-fetch-prune" "off"
    out=$(e2e_capture_menu "run-shell '${SCRIPTS_DIR}/worktree_manager.sh show_options_menu'" "")
    e2e_assert_menu_contains "$out" "Fetch prune" "off"

    e2e_tmux set-option -g "@worktree-fetch-prune" "on"
    out=$(e2e_capture_menu "run-shell '${SCRIPTS_DIR}/worktree_manager.sh show_options_menu'" "")
    e2e_assert_menu_contains "$out" "Fetch prune" "on"
}
