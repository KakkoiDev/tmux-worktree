#!/usr/bin/env bats
# Tests for copy_ignored_files feature

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

    # Mock tmux display-message to prevent errors in test environment
    tmux() {
        if [ "$1" = "display-message" ]; then
            return 0
        fi
        command tmux "$@"
    }
}

teardown() {
    # Clean up any test worktrees
    cd "$TEST_REPO_DIR" 2>/dev/null || true
    git worktree list --porcelain 2>/dev/null | grep "^worktree " | cut -d' ' -f2 | while read -r wt; do
        [ "$wt" != "$TEST_REPO_DIR" ] && git worktree remove --force "$wt" 2>/dev/null || true
    done
    safe_cleanup_worktree_base
    unset -f tmux 2>/dev/null || true
}

# ==============================================================================
# COPY IGNORED FILES TESTS
# ==============================================================================

@test "copy_ignored_files: copies node_modules to target" {
    echo "node_modules/" >> "$TEST_REPO_DIR/.gitignore"
    git add .gitignore && git commit -q -m "add gitignore"
    mkdir -p "$TEST_REPO_DIR/node_modules/some-pkg"
    echo "package content" > "$TEST_REPO_DIR/node_modules/some-pkg/index.js"

    local wt_dir="${BATS_TMPDIR}/wt-copy-test-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/test-branch" -b test-copy-branch

    copy_ignored_files "$wt_dir/test-branch"

    [ -f "$wt_dir/test-branch/node_modules/some-pkg/index.js" ]

    git worktree remove --force "$wt_dir/test-branch" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "copy_ignored_files: copies .env file" {
    echo ".env" >> "$TEST_REPO_DIR/.gitignore"
    git add .gitignore && git commit -q -m "add gitignore"
    echo "SECRET=value" > "$TEST_REPO_DIR/.env"

    local wt_dir="${BATS_TMPDIR}/wt-copy-test-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/test-branch" -b test-env-branch

    copy_ignored_files "$wt_dir/test-branch"

    [ -f "$wt_dir/test-branch/.env" ]
    assert_contains "$(cat "$wt_dir/test-branch/.env")" "SECRET=value"

    git worktree remove --force "$wt_dir/test-branch" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "copy_ignored_files: copies dist directory" {
    echo "dist/" >> "$TEST_REPO_DIR/.gitignore"
    git add .gitignore && git commit -q -m "add gitignore"
    mkdir -p "$TEST_REPO_DIR/dist"
    echo "built" > "$TEST_REPO_DIR/dist/bundle.js"

    local wt_dir="${BATS_TMPDIR}/wt-copy-test-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/test-branch" -b test-dist-branch

    copy_ignored_files "$wt_dir/test-branch"

    [ -f "$wt_dir/test-branch/dist/bundle.js" ]

    git worktree remove --force "$wt_dir/test-branch" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "copy_ignored_files: handles empty repo with no ignored files" {
    local wt_dir="${BATS_TMPDIR}/wt-copy-test-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/test-branch" -b test-empty-branch

    run copy_ignored_files "$wt_dir/test-branch"
    assert_success

    git worktree remove --force "$wt_dir/test-branch" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "copy_ignored_files: respects COPY_IGNORED=off setting" {
    echo "node_modules/" >> "$TEST_REPO_DIR/.gitignore"
    git add .gitignore && git commit -q -m "add gitignore"
    mkdir -p "$TEST_REPO_DIR/node_modules/pkg"
    echo "content" > "$TEST_REPO_DIR/node_modules/pkg/index.js"

    export COPY_IGNORED="off"

    local wt_dir="${BATS_TMPDIR}/wt-copy-test-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/test-branch" -b test-off-branch

    # Simulate the conditional from create_new_worktree
    if [ "$COPY_IGNORED" = "on" ]; then
        copy_ignored_files "$wt_dir/test-branch"
    fi

    # Should NOT have copied
    [ ! -d "$wt_dir/test-branch/node_modules" ]

    git worktree remove --force "$wt_dir/test-branch" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "copy_ignored_files: copies when COPY_IGNORED=on" {
    echo "node_modules/" >> "$TEST_REPO_DIR/.gitignore"
    git add .gitignore && git commit -q -m "add gitignore"
    mkdir -p "$TEST_REPO_DIR/node_modules/pkg"
    echo "content" > "$TEST_REPO_DIR/node_modules/pkg/index.js"

    export COPY_IGNORED="on"

    local wt_dir="${BATS_TMPDIR}/wt-copy-test-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/test-branch" -b test-on-branch

    # Simulate the conditional from create_new_worktree
    if [ "$COPY_IGNORED" = "on" ]; then
        copy_ignored_files "$wt_dir/test-branch"
    fi

    # Should have copied
    [ -f "$wt_dir/test-branch/node_modules/pkg/index.js" ]

    git worktree remove --force "$wt_dir/test-branch" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "copy_ignored_files: copies multiple ignored items" {
    cat > "$TEST_REPO_DIR/.gitignore" <<'EOF'
node_modules/
dist/
.env
EOF
    git add .gitignore && git commit -q -m "add gitignore"

    mkdir -p "$TEST_REPO_DIR/node_modules/pkg"
    echo "pkg" > "$TEST_REPO_DIR/node_modules/pkg/index.js"
    mkdir -p "$TEST_REPO_DIR/dist"
    echo "built" > "$TEST_REPO_DIR/dist/app.js"
    echo "DB_URL=localhost" > "$TEST_REPO_DIR/.env"

    local wt_dir="${BATS_TMPDIR}/wt-copy-test-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/test-branch" -b test-multi-branch

    copy_ignored_files "$wt_dir/test-branch"

    [ -f "$wt_dir/test-branch/node_modules/pkg/index.js" ]
    [ -f "$wt_dir/test-branch/dist/app.js" ]
    [ -f "$wt_dir/test-branch/.env" ]

    git worktree remove --force "$wt_dir/test-branch" 2>/dev/null || true
    rm -rf "$wt_dir"
}

@test "copy_ignored_files: skips nonexistent ignored items" {
    # .gitignore references files that don't actually exist
    echo "nonexistent/" >> "$TEST_REPO_DIR/.gitignore"
    echo "also-missing.txt" >> "$TEST_REPO_DIR/.gitignore"
    git add .gitignore && git commit -q -m "add gitignore"

    local wt_dir="${BATS_TMPDIR}/wt-copy-test-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/test-branch" -b test-skip-branch

    # Should succeed without errors even though ignored items don't exist
    run copy_ignored_files "$wt_dir/test-branch"
    assert_success

    git worktree remove --force "$wt_dir/test-branch" 2>/dev/null || true
    rm -rf "$wt_dir"
}
