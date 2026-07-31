#!/usr/bin/env bats
# bats file_tags=integration,bulk-remove
# Integration tests for bulk-remove of worktrees not used recently.

load '../test_helper'

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
    init_test_worktree_base

    tmux_set_option "@worktree-path" "$WORKTREE_BASE"
    # Reset possible leftover from prior tests on the shared server.
    tmux_set_option "@worktree-max-age-days" ""
    tmux_set_option "@worktree-max-age-choices" ""
    rm -f "$TEST_REPO_DIR/.tmux-worktree.conf" 2>/dev/null
    reload_config
    export TMUX_WORKTREE_RECENT_FILE="$WORKTREE_BASE/.recent-test.log"

    tk_menu_show() {
        CAPTURED_MENU_TITLE="${TK_MENU_TITLE:-}"
        CAPTURED_MENU_OPTIONS="${TK_MENU_ARGS[*]:-}"
        TK_MENU_ARGS=()
    }

    tmux() {
        case "$1" in
            display-message|kill-session|switch-client|new-session|has-session)
                return 0
                ;;
            *) command tmux -L "$TMUX_SOCKET" "$@" ;;
        esac
    }
    export -f tmux
}

teardown() {
    unset -f tmux
    CAPTURED_MENU_TITLE=""
    CAPTURED_MENU_OPTIONS=""
    # Reset tmux options that tests may have set (shared server state).
    tmux_set_option "@worktree-max-age-days" ""
    tmux_set_option "@worktree-max-age-choices" ""
    rm -f "$TEST_REPO_DIR/.tmux-worktree.conf" 2>/dev/null
    rm -f "$TMUX_WORKTREE_RECENT_FILE" 2>/dev/null
    safe_cleanup_worktree_base
}

# Helper: create worktree, optionally seed recent log with a specific timestamp
_seed_worktree() {
    local branch="$1"
    local ts="${2:-}"
    local project_name
    project_name=$(get_project_name)
    local wt_dir="${BATS_TMPDIR}/wt-$$"
    mkdir -p "$wt_dir"
    git worktree add -q "$wt_dir/$branch" "$branch" 2>/dev/null
    if [ -n "$ts" ]; then
        mkdir -p "$(dirname "$TMUX_WORKTREE_RECENT_FILE")"
        echo "$ts $project_name:$branch" >> "$TMUX_WORKTREE_RECENT_FILE"
    fi
}

_cleanup_worktrees() {
    local wt_dir="${BATS_TMPDIR}/wt-$$"
    if [ -d "$wt_dir" ]; then
        git worktree list --porcelain 2>/dev/null | grep "^worktree " | cut -d' ' -f2 | while read -r wt; do
            [[ "$wt" == "$wt_dir"/* ]] && git worktree remove --force "$wt" 2>/dev/null || true
        done
        rm -rf "$wt_dir"
    fi
}

# ==============================================================================
# get_stale_worktree_count
# ==============================================================================

@test "get_stale_worktree_count: zero when all fresh" {
    local now
    now=$(date +%s)
    _seed_worktree "feature-one" "$now"
    _seed_worktree "feature-two" "$now"

    run get_stale_worktree_count 30
    assert_success
    assert_equal "0" "$output"

    _cleanup_worktrees
}

@test "get_stale_worktree_count: counts stale worktrees (ts absent = ancient)" {
    _seed_worktree "feature-one"    # no ts entry = ancient
    _seed_worktree "feature-two"

    run get_stale_worktree_count 30
    assert_success
    assert_equal "2" "$output"

    _cleanup_worktrees
}

@test "get_stale_worktree_count: mixed (some fresh, some stale)" {
    local now old
    now=$(date +%s)
    old=$((now - 86400 * 60))   # 60 days ago
    _seed_worktree "feature-one" "$now"   # fresh
    _seed_worktree "feature-two" "$old"   # stale
    _seed_worktree "bugfix-123"           # ancient (no ts)

    run get_stale_worktree_count 30
    assert_success
    assert_equal "2" "$output"

    _cleanup_worktrees
}

@test "get_stale_worktree_count: threshold boundary includes items exactly at age" {
    local now on_boundary
    now=$(date +%s)
    on_boundary=$((now - 86400 * 30))
    _seed_worktree "feature-one" "$on_boundary"

    run get_stale_worktree_count 30
    assert_success
    assert_equal "1" "$output"

    _cleanup_worktrees
}

@test "get_stale_worktree_count: threshold respects larger window" {
    local now medium
    now=$(date +%s)
    medium=$((now - 86400 * 45))
    _seed_worktree "feature-one" "$medium"

    run get_stale_worktree_count 90
    assert_success
    assert_equal "0" "$output"

    _cleanup_worktrees
}

# ==============================================================================
# show_bulk_remove_preview_menu
# ==============================================================================

@test "preview menu: no stale worktrees shows empty state" {
    local now
    now=$(date +%s)
    _seed_worktree "feature-one" "$now"

    show_bulk_remove_preview_menu 30
    assert_contains "$CAPTURED_MENU_OPTIONS" "No stale worktrees"

    _cleanup_worktrees
}

@test "preview menu: lists stale worktrees with age labels" {
    local now old older
    now=$(date +%s)
    old=$((now - 86400 * 45))
    older=$((now - 86400 * 120))
    _seed_worktree "feature-one" "$old"
    _seed_worktree "feature-two" "$older"

    show_bulk_remove_preview_menu 30

    assert_contains "$CAPTURED_MENU_OPTIONS" "feature-one"
    assert_contains "$CAPTURED_MENU_OPTIONS" "feature-two"
    # Ages present
    assert_contains "$CAPTURED_MENU_OPTIONS" "(6w)"

    _cleanup_worktrees
}

@test "preview menu: Remove all row shows correct count" {
    _seed_worktree "feature-one"
    _seed_worktree "feature-two"

    show_bulk_remove_preview_menu 30

    assert_contains "$CAPTURED_MENU_OPTIONS" "Remove all 2"

    _cleanup_worktrees
}

@test "preview menu: confirmation prompt invokes bulk_remove_worktrees" {
    _seed_worktree "feature-one"

    show_bulk_remove_preview_menu 30

    # tk_menu_cmd produces: 'bulk_remove_worktrees' '30'
    assert_contains "$CAPTURED_MENU_OPTIONS" "bulk_remove_worktrees"
    assert_contains "$CAPTURED_MENU_OPTIONS" "30"
    assert_contains "$CAPTURED_MENU_OPTIONS" "Type yes"

    _cleanup_worktrees
}

@test "preview menu: title reflects threshold" {
    _seed_worktree "feature-one"

    show_bulk_remove_preview_menu 7
    assert_contains "$CAPTURED_MENU_TITLE" ">7d"

    _cleanup_worktrees
}

# ==============================================================================
# Remove menu integration (bulk row appears when stale > 0)
# ==============================================================================

@test "Remove menu: shows bulk row when stale > 0" {
    tmux_set_option "@worktree-max-age-days" "30"
    reload_config

    _seed_worktree "feature-one"

    show_remove_worktree_menu 1
    assert_contains "$CAPTURED_MENU_OPTIONS" "Remove older than 30d (1)"

    _cleanup_worktrees
}

@test "Remove menu: hides bulk row when stale = 0" {
    local now
    now=$(date +%s)
    _seed_worktree "feature-one" "$now"

    show_remove_worktree_menu 1
    refute_contains "$CAPTURED_MENU_OPTIONS" "Remove older than"

    _cleanup_worktrees
}

# ==============================================================================
# Options menu (Max age row + cycle)
# ==============================================================================

@test "Options menu: shows Stale after row" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" "Stale after:"
}

@test "Options menu: Stale after cycle dispatches set_option" {
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" "set_option"
    assert_contains "$CAPTURED_MENU_OPTIONS" "@worktree-max-age-days"
}

@test "Options menu: Stale after shows current value" {
    tmux_set_option "@worktree-max-age-days" "90"
    show_options_menu
    assert_contains "$CAPTURED_MENU_OPTIONS" "Stale after: 90d"
}

@test "Options menu: cycle follows MAX_AGE_CHOICES" {
    tmux_set_option "@worktree-max-age-days" "7"
    tmux_set_option "@worktree-max-age-choices" "7,14,21"
    show_options_menu
    # tk_menu_cmd single-quotes args: 'set_option' '@worktree-max-age-days' '14'
    assert_contains "$CAPTURED_MENU_OPTIONS" "set_option"
    assert_contains "$CAPTURED_MENU_OPTIONS" "@worktree-max-age-days"
    assert_contains "$CAPTURED_MENU_OPTIONS" "'14'"
}

# ==============================================================================
# bulk_remove_worktrees
# ==============================================================================

@test "bulk_remove_worktrees: cancels when confirm != yes" {
    _seed_worktree "feature-one"

    local wt_dir="${BATS_TMPDIR}/wt-$$"
    [ -d "$wt_dir/feature-one" ]

    run bulk_remove_worktrees 30 "no"
    assert_success

    # worktree still exists
    [ -d "$wt_dir/feature-one" ]

    _cleanup_worktrees
}

@test "bulk_remove_worktrees: removes all stale worktrees on confirm" {
    local now old
    now=$(date +%s)
    old=$((now - 86400 * 60))

    local project_name
    project_name=$(get_project_name)

    _seed_worktree "feature-one" "$old"
    _seed_worktree "feature-two" "$now"

    local wt_dir="${BATS_TMPDIR}/wt-$$"
    [ -d "$wt_dir/feature-one" ]
    [ -d "$wt_dir/feature-two" ]

    run bulk_remove_worktrees 30 "yes"
    assert_success

    [ ! -d "$wt_dir/feature-one" ]
    [ -d "$wt_dir/feature-two" ]

    # Recent log was cleaned of removed branch
    run cat "$TMUX_WORKTREE_RECENT_FILE"
    refute_contains "$output" "$project_name:feature-one"
    assert_contains "$output" "$project_name:feature-two"

    _cleanup_worktrees
}

@test "bulk_remove_worktrees: emits progress message per worktree" {
    local now old
    now=$(date +%s)
    old=$((now - 86400 * 60))
    _seed_worktree "feature-one" "$old"
    _seed_worktree "feature-two" "$old"

    local captured=""
    tmux() {
        if [ "$1" = "display-message" ]; then
            # Append all positional args so we can assert the message content.
            captured="${captured}|$*"
            return 0
        fi
        case "$1" in
            kill-session|switch-client|new-session|has-session) return 0 ;;
            *) command tmux -L "$TMUX_SOCKET" "$@" ;;
        esac
    }
    export -f tmux

    bulk_remove_worktrees 30 "yes"

    assert_contains "$captured" "Deleting worktree 1/2"
    assert_contains "$captured" "Deleting worktree 2/2"

    _cleanup_worktrees
}

@test "bulk_remove_worktrees: no-op when none stale" {
    local now
    now=$(date +%s)
    _seed_worktree "feature-one" "$now"

    local wt_dir="${BATS_TMPDIR}/wt-$$"

    run bulk_remove_worktrees 30 "yes"
    assert_success

    [ -d "$wt_dir/feature-one" ]

    _cleanup_worktrees
}

# ==============================================================================
# Project config: max-age-days / max-age-choices
# ==============================================================================

@test "project config: max-age-days overrides default when tmux option unset" {
    cat > "$TEST_REPO_DIR/.tmux-worktree.conf" <<'EOF'
max-age-days = 14
EOF

    reload_config

    # With the config, defaults to 14
    assert_equal "14" "$MAX_AGE_DAYS"

    rm -f "$TEST_REPO_DIR/.tmux-worktree.conf"
}

@test "project config: max-age-choices overrides default cycle" {
    cat > "$TEST_REPO_DIR/.tmux-worktree.conf" <<'EOF'
max-age-choices = 1,14,60
EOF

    reload_config

    assert_equal "1,14,60" "$MAX_AGE_CHOICES"

    rm -f "$TEST_REPO_DIR/.tmux-worktree.conf"
}

@test "project config: explicit tmux option wins over project config for max-age-days" {
    tmux_set_option "@worktree-max-age-days" "7"
    cat > "$TEST_REPO_DIR/.tmux-worktree.conf" <<'EOF'
max-age-days = 45
EOF

    reload_config

    assert_equal "7" "$MAX_AGE_DAYS"

    tmux_set_option "@worktree-max-age-days" ""
    rm -f "$TEST_REPO_DIR/.tmux-worktree.conf"
}
