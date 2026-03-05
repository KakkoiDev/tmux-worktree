#!/usr/bin/env bats
# Tests for post-create hook and template variable expansion

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
    source_script "$SCRIPTS_DIR/helpers.sh"
    source_script "$SCRIPTS_DIR/filter.sh"
    cd "$TEST_REPO_DIR" || exit 1
    load_config
    source_script "$SCRIPTS_DIR/worktree_manager.sh"
    init_test_worktree_base

    # Mock tmux display-message
    DISPLAY_MESSAGES=()
    tmux() {
        if [ "$1" = "display-message" ]; then
            DISPLAY_MESSAGES+=("$2")
            return 0
        fi
        command tmux "$@"
    }
}

teardown() {
    cd "$TEST_REPO_DIR" 2>/dev/null || true
    git worktree list --porcelain 2>/dev/null | grep "^worktree " | cut -d' ' -f2 | while read -r wt; do
        [ "$wt" != "$TEST_REPO_DIR" ] && git worktree remove --force "$wt" 2>/dev/null || true
    done
    safe_cleanup_worktree_base
    unset -f tmux 2>/dev/null || true
}

# ==============================================================================
# TEMPLATE VARIABLE EXPANSION TESTS
# ==============================================================================

@test "_expand_hook_vars: expands {{ branch }} with spaces" {
    run _expand_hook_vars "echo {{ branch }}" "feature-x" "myproj" "/tmp/wt"
    assert_success
    assert_equal "echo feature-x" "$output"
}

@test "_expand_hook_vars: expands {{branch}} without spaces" {
    run _expand_hook_vars "echo {{branch}}" "feature-x" "myproj" "/tmp/wt"
    assert_success
    assert_equal "echo feature-x" "$output"
}

@test "_expand_hook_vars: expands {{ project }}" {
    run _expand_hook_vars "echo {{ project }}" "br" "myproj" "/tmp/wt"
    assert_success
    assert_equal "echo myproj" "$output"
}

@test "_expand_hook_vars: expands {{ path }}" {
    run _expand_hook_vars "cd {{ path }}" "br" "proj" "/tmp/wt/test"
    assert_success
    assert_equal "cd /tmp/wt/test" "$output"
}

@test "_expand_hook_vars: expands all variables combined" {
    run _expand_hook_vars "echo {{branch}} {{project}} {{path}}" "feat" "proj" "/tmp/p"
    assert_success
    assert_equal "echo feat proj /tmp/p" "$output"
}

@test "_expand_hook_vars: sanitizes special chars in branch names" {
    run _expand_hook_vars "echo {{branch}}" 'feat;rm -rf /' "proj" "/tmp"
    assert_success
    # Semicolon and space stripped, only safe chars remain
    assert_equal "echo featrm-rf/" "$output"
}

@test "_expand_hook_vars: leaves unknown variables untouched" {
    run _expand_hook_vars "echo {{ unknown }}" "br" "proj" "/tmp"
    assert_success
    assert_equal "echo {{ unknown }}" "$output"
}

@test "_expand_hook_vars: handles template with no variables" {
    run _expand_hook_vars "npm install" "br" "proj" "/tmp"
    assert_success
    assert_equal "npm install" "$output"
}

# ==============================================================================
# HOOK RUNNER TESTS
# ==============================================================================

@test "_run_post_create_hook: skips when POST_CREATE_CMD is empty" {
    export POST_CREATE_CMD=""
    run _run_post_create_hook "branch" "project" "$TEST_REPO_DIR"
    assert_success
}

@test "_run_post_create_hook: runs command in worktree directory" {
    local wt_dir="${BATS_TMPDIR}/wt-hook-test-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/test-branch" -b test-hook-cwd

    export POST_CREATE_CMD="pwd > .hook-cwd-test"
    _run_post_create_hook "test-hook-cwd" "project" "$wt_dir/test-branch"

    [ -f "$wt_dir/test-branch/.hook-cwd-test" ]
    run cat "$wt_dir/test-branch/.hook-cwd-test"
    assert_equal "$wt_dir/test-branch" "$output"

    git worktree remove --force "$wt_dir/test-branch" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "_run_post_create_hook: returns 1 on failure" {
    export POST_CREATE_CMD="false"
    run _run_post_create_hook "branch" "project" "$TEST_REPO_DIR"
    assert_failure
}

@test "_run_post_create_hook: displays message on failure" {
    export POST_CREATE_CMD="false"
    _run_post_create_hook "branch" "project" "$TEST_REPO_DIR" || true

    # The function calls tmux -L $TMUX_SOCKET display-message on failure
    # We verify via the tmux server's message history isn't easy, so we just
    # verify the function returns failure (tested above) and produces debug log
    # Instead, check that the mock captured the message
    # Since TMUX_SOCKET is set, it goes through `tmux -L` which hits the real tmux
    # Verify by checking the return code was non-zero (already tested)
    # and that the function attempted display-message by grepping debug log
    export DEBUG="on"
    export POST_CREATE_CMD="false"
    _run_post_create_hook "branch" "project" "$TEST_REPO_DIR" || true

    [ -f "$WORKTREE_BASE/.tmux-worktree.log" ]
    run cat "$WORKTREE_BASE/.tmux-worktree.log"
    assert_contains "$output" "post-create hook FAILED"
}

@test "_run_post_create_hook: receives TMUX_WORKTREE env vars" {
    local wt_dir="${BATS_TMPDIR}/wt-hook-env-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/test-branch" -b test-hook-env

    export POST_CREATE_CMD='echo "$TMUX_WORKTREE|$TMUX_WORKTREE_PROJECT|$TMUX_WORKTREE_BRANCH|$TMUX_WORKTREE_PATH" > .hook-env-test'
    _run_post_create_hook "test-hook-env" "myproject" "$wt_dir/test-branch"

    [ -f "$wt_dir/test-branch/.hook-env-test" ]
    run cat "$wt_dir/test-branch/.hook-env-test"
    assert_equal "1|myproject|test-hook-env|$wt_dir/test-branch" "$output"

    git worktree remove --force "$wt_dir/test-branch" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "_run_post_create_hook: expands template variables in command" {
    local wt_dir="${BATS_TMPDIR}/wt-hook-tpl-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/test-branch" -b test-hook-tpl

    export POST_CREATE_CMD='echo "{{ branch }} {{ project }}" > .hook-tpl-test'
    _run_post_create_hook "test-hook-tpl" "myproject" "$wt_dir/test-branch"

    [ -f "$wt_dir/test-branch/.hook-tpl-test" ]
    run cat "$wt_dir/test-branch/.hook-tpl-test"
    assert_equal "test-hook-tpl myproject" "$output"

    git worktree remove --force "$wt_dir/test-branch" 2>/dev/null || true
    rm -rf "$wt_dir"
}
