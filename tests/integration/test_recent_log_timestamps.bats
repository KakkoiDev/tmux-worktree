#!/usr/bin/env bats
# bats file_tags=integration,recent,timestamps
# Tests for timestamped .recent.log format, migration, and timestamp lookups.

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
    tmux_set_option "@worktree-path" "$WORKTREE_BASE"
    export TMUX_WORKTREE_RECENT_FILE="$WORKTREE_BASE/.recent-test.log"
}

teardown() {
    rm -f "$TMUX_WORKTREE_RECENT_FILE" 2>/dev/null
    safe_cleanup_worktree_base
}

# ==============================================================================
# NEW-FORMAT WRITE
# ==============================================================================

@test "record_recent_branch writes new format with timestamp prefix" {
    record_recent_branch "proj" "alpha"

    run cat "$TMUX_WORKTREE_RECENT_FILE"
    assert_matches "^[0-9]+ proj:alpha$" "$output"
}

@test "record_recent_branch uses current time as timestamp" {
    local before after
    before=$(date +%s)
    record_recent_branch "proj" "alpha"
    after=$(date +%s)

    local ts
    ts=$(awk '{print $1}' "$TMUX_WORKTREE_RECENT_FILE")
    [ "$ts" -ge "$before" ]
    [ "$ts" -le "$after" ]
}

# ==============================================================================
# MIGRATION
# ==============================================================================

@test "migration: legacy entries get stamped on next record" {
    # Pre-seed file with legacy (no timestamp) entries.
    mkdir -p "$(dirname "$TMUX_WORKTREE_RECENT_FILE")"
    printf 'proj:legacy-a\nproj:legacy-b\n' > "$TMUX_WORKTREE_RECENT_FILE"

    local before
    before=$(date +%s)
    record_recent_branch "proj" "new-c"

    local line_count
    line_count=$(wc -l < "$TMUX_WORKTREE_RECENT_FILE" | tr -d ' ')
    assert_equal "3" "$line_count"

    # Every line starts with a timestamp now.
    run awk '{ if ($0 !~ /^[0-9]+ /) print "bad:" $0 }' "$TMUX_WORKTREE_RECENT_FILE"
    assert_equal "" "$output"

    # Legacy entries were stamped with ~now.
    local legacy_ts
    legacy_ts=$(awk '/proj:legacy-a/{print $1}' "$TMUX_WORKTREE_RECENT_FILE")
    [ "$legacy_ts" -ge "$before" ]
}

@test "migration: idempotent (no rewrite once all lines have timestamps)" {
    record_recent_branch "proj" "alpha"
    local hash_before
    hash_before=$(cksum "$TMUX_WORKTREE_RECENT_FILE")

    sleep 1
    _migrate_recent_log

    local hash_after
    hash_after=$(cksum "$TMUX_WORKTREE_RECENT_FILE")
    assert_equal "$hash_before" "$hash_after"
}

@test "migration: handles empty file gracefully" {
    touch "$TMUX_WORKTREE_RECENT_FILE"
    run _migrate_recent_log
    assert_success
}

@test "migration: handles missing file gracefully" {
    rm -f "$TMUX_WORKTREE_RECENT_FILE"
    run _migrate_recent_log
    assert_success
}

# ==============================================================================
# TIMESTAMP LOOKUPS
# ==============================================================================

@test "get_recent_timestamp: returns ts for known branch" {
    record_recent_branch "proj" "alpha"

    local ts
    ts=$(get_recent_timestamp "proj" "alpha")
    [[ "$ts" =~ ^[0-9]+$ ]]
    [ "$ts" -gt 0 ]
}

@test "get_recent_timestamp: returns 0 for unknown branch" {
    record_recent_branch "proj" "alpha"

    run get_recent_timestamp "proj" "nonexistent"
    assert_equal "0" "$output"
}

@test "get_recent_timestamp: returns 0 for missing file" {
    rm -f "$TMUX_WORKTREE_RECENT_FILE"
    run get_recent_timestamp "proj" "alpha"
    assert_equal "0" "$output"
}

@test "get_recent_timestamp: returns newest ts on dupes" {
    # Seed old entry, then record new one.
    mkdir -p "$(dirname "$TMUX_WORKTREE_RECENT_FILE")"
    echo "1000000000 proj:alpha" > "$TMUX_WORKTREE_RECENT_FILE"

    record_recent_branch "proj" "alpha"

    local ts
    ts=$(get_recent_timestamp "proj" "alpha")
    [ "$ts" -gt 1000000000 ]
}

@test "get_recent_entries: emits ts branch lines sorted newest first" {
    mkdir -p "$(dirname "$TMUX_WORKTREE_RECENT_FILE")"
    cat > "$TMUX_WORKTREE_RECENT_FILE" <<EOF
1000000000 proj:alpha
1000001000 proj:beta
1000002000 proj:gamma
EOF

    run get_recent_entries "proj"
    assert_success

    local first second third
    first=$(echo "$output"  | sed -n '1p')
    second=$(echo "$output" | sed -n '2p')
    third=$(echo "$output"  | sed -n '3p')

    assert_equal "1000002000 gamma" "$first"
    assert_equal "1000001000 beta" "$second"
    assert_equal "1000000000 alpha" "$third"
}

@test "get_recent_branches: sorted by ts desc, not append order" {
    mkdir -p "$(dirname "$TMUX_WORKTREE_RECENT_FILE")"
    # Append order: alpha, beta, gamma (gamma is last)
    # But gamma has the OLDEST timestamp.
    cat > "$TMUX_WORKTREE_RECENT_FILE" <<EOF
1000000300 proj:alpha
1000000200 proj:beta
1000000100 proj:gamma
EOF

    run get_recent_branches "proj"
    assert_success

    local first second third
    first=$(echo "$output"  | sed -n '1p')
    second=$(echo "$output" | sed -n '2p')
    third=$(echo "$output"  | sed -n '3p')

    assert_equal "alpha" "$first"
    assert_equal "beta" "$second"
    assert_equal "gamma" "$third"
}

@test "get_recent_branches: legacy lines treated as ts=0 and sorted last" {
    mkdir -p "$(dirname "$TMUX_WORKTREE_RECENT_FILE")"
    cat > "$TMUX_WORKTREE_RECENT_FILE" <<EOF
proj:legacy
1000000000 proj:stamped
EOF

    run get_recent_branches "proj"
    assert_success

    local first second
    first=$(echo "$output"  | sed -n '1p')
    second=$(echo "$output" | sed -n '2p')

    # Stamped entries come first; legacy (ts=0) last.
    assert_equal "stamped" "$first"
    assert_equal "legacy" "$second"
}

# ==============================================================================
# REMOVE TOLERATES BOTH FORMATS
# ==============================================================================

@test "remove_recent_branch: removes timestamped rows" {
    record_recent_branch "proj" "alpha"
    record_recent_branch "proj" "beta"

    remove_recent_branch "proj" "alpha"

    run cat "$TMUX_WORKTREE_RECENT_FILE"
    refute_contains "$output" "proj:alpha"
    assert_contains "$output" "proj:beta"
}

@test "remove_recent_branch: removes legacy rows" {
    mkdir -p "$(dirname "$TMUX_WORKTREE_RECENT_FILE")"
    cat > "$TMUX_WORKTREE_RECENT_FILE" <<EOF
proj:legacy
1000000000 proj:stamped
EOF

    remove_recent_branch "proj" "legacy"

    run cat "$TMUX_WORKTREE_RECENT_FILE"
    refute_contains "$output" "proj:legacy"
    assert_contains "$output" "proj:stamped"
}
