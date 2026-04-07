#!/usr/bin/env bats
# Tests for .tmux-worktree.conf project config file

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
    init_test_worktree_base

    # Reset explicit options tracking
    _EXPLICIT_OPTIONS=""
}

teardown() {
    rm -f "$TEST_REPO_DIR/.tmux-worktree.conf" 2>/dev/null || true
    safe_cleanup_worktree_base
}

# ==============================================================================
# PROJECT CONFIG PARSING TESTS
# ==============================================================================

@test "_load_project_config: reads copy-ignored" {
    echo 'copy-ignored = on' > "$TEST_REPO_DIR/.tmux-worktree.conf"
    COPY_IGNORED="off"
    _load_project_config

    assert_equal "on" "$COPY_IGNORED"
}

@test "_load_project_config: skips comments" {
    cat > "$TEST_REPO_DIR/.tmux-worktree.conf" <<'EOF'
# This is a comment
copy-ignored = on
EOF
    COPY_IGNORED="off"
    _load_project_config

    assert_equal "on" "$COPY_IGNORED"
}

@test "_load_project_config: skips blank lines" {
    cat > "$TEST_REPO_DIR/.tmux-worktree.conf" <<'EOF'

copy-ignored = on

EOF
    COPY_IGNORED="off"
    _load_project_config

    assert_equal "on" "$COPY_IGNORED"
}

@test "_load_project_config: does NOT override explicit tmux options" {
    echo 'copy-ignored = on' > "$TEST_REPO_DIR/.tmux-worktree.conf"
    COPY_IGNORED="off"
    _EXPLICIT_OPTIONS="copy-ignored "
    _load_project_config

    assert_equal "off" "$COPY_IGNORED"
}

@test "_load_project_config: handles missing config file" {
    rm -f "$TEST_REPO_DIR/.tmux-worktree.conf" 2>/dev/null || true
    COPY_IGNORED="existing"
    run _load_project_config
    assert_success

    # Value should be unchanged
    assert_equal "existing" "$COPY_IGNORED"
}

@test "_load_project_config: handles malformed lines" {
    cat > "$TEST_REPO_DIR/.tmux-worktree.conf" <<'EOF'
this has no equals sign
copy-ignored = on
just-key-no-value
EOF
    COPY_IGNORED="off"
    _load_project_config

    assert_equal "on" "$COPY_IGNORED"
}

@test "_load_project_config: trims whitespace from values" {
    echo '  copy-ignored  =  on  ' > "$TEST_REPO_DIR/.tmux-worktree.conf"
    COPY_IGNORED="off"
    _load_project_config

    assert_equal "on" "$COPY_IGNORED"
}
