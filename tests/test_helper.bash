#!/usr/bin/env bash
# Test helper utilities for tmux-worktree BATS tests

# Isolated tmux socket for testing (prevents interference with user's tmux)
export TMUX_SOCKET="test-worktrees"
export TMUX_TMPDIR="${BATS_TMPDIR:-/tmp}"

# Plugin paths (set relative to test file location)
export PLUGIN_DIR="${BATS_TEST_DIRNAME}/.."
export SCRIPTS_DIR="${PLUGIN_DIR}/scripts"

# Test fixture paths
export FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures"
export TEST_REPO_DIR=""

# Start isolated tmux server for testing
start_tmux_server() {
    tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
    tmux -L "$TMUX_SOCKET" new-session -d -s "test-session" -c "$TEST_REPO_DIR"
}

# Stop isolated tmux server
stop_tmux_server() {
    tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
}

# Run tmux command in isolated server
tmux_run() {
    tmux -L "$TMUX_SOCKET" "$@"
}

# Set tmux option in isolated server
tmux_set_option() {
    local option="$1"
    local value="$2"
    tmux_run set-option -g "$option" "$value"
}

# Get tmux option from isolated server
tmux_get_option() {
    local option="$1"
    tmux_run show-option -gqv "$option"
}

# Create a temporary git repository for testing
create_test_repo() {
    TEST_REPO_DIR=$(mktemp -d "${BATS_TMPDIR}/test-repo.XXXXXX")
    cd "$TEST_REPO_DIR" || return 1
    # Use consistent branch name regardless of system default
    git init -q --initial-branch=master
    git config user.email "test@test.com"
    git config user.name "Test User"

    # Create initial commit
    echo "initial" > README.md
    git add README.md
    git commit -q -m "Initial commit"

    # Create some test branches
    git branch feature-one
    git branch feature-two
    git branch bugfix-123

    echo "$TEST_REPO_DIR"
}

# Cleanup test repository
cleanup_test_repo() {
    if [ -n "$TEST_REPO_DIR" ] && [ -d "$TEST_REPO_DIR" ]; then
        rm -rf "$TEST_REPO_DIR"
    fi
}

# Source a script and capture if it loads without error
source_script() {
    local script="$1"
    if [ -f "$script" ]; then
        # shellcheck source=/dev/null
        source "$script"
        return $?
    else
        return 1
    fi
}

# Assert file exists
assert_file_exists() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "Expected file to exist: $file" >&2
        return 1
    fi
}

# Assert file is executable
assert_executable() {
    local file="$1"
    if [ ! -x "$file" ]; then
        echo "Expected file to be executable: $file" >&2
        return 1
    fi
}

# Assert string contains substring
assert_contains() {
    local haystack="$1"
    local needle="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "Expected '$haystack' to contain '$needle'" >&2
        return 1
    fi
}

# Assert strings are equal
assert_equal() {
    local expected="$1"
    local actual="$2"
    if [ "$expected" != "$actual" ]; then
        echo "Expected: '$expected'" >&2
        echo "Actual:   '$actual'" >&2
        return 1
    fi
}

# Assert command succeeds
assert_success() {
    if [ "$status" -ne 0 ]; then
        echo "Expected success (status 0), got status $status" >&2
        echo "Output: $output" >&2
        return 1
    fi
}

# Assert command fails
assert_failure() {
    if [ "$status" -eq 0 ]; then
        echo "Expected failure (non-zero status), got status 0" >&2
        echo "Output: $output" >&2
        return 1
    fi
}


# ==============================================================================
# WORKTREE LIFECYCLE HELPERS
# ==============================================================================

# Kill all test tmux sessions created during tests
cleanup_test_sessions() {
    tmux_run list-sessions -F '#{session_name}' 2>/dev/null | \
        grep -E '^test-repo' | \
        while read -r session; do
            tmux_run kill-session -t "$session" 2>/dev/null || true
        done
}

# Delete test branches (prefix: test-)
cleanup_test_branches() {
    git branch 2>/dev/null | grep "^  test-" | while read -r branch; do
        git branch -D "${branch## }" 2>/dev/null || true
    done
}

# Create worktree for testing (with guaranteed cleanup)
create_test_worktree() {
    local branch="$1"
    local project_name
    project_name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
    local wt_path="${WORKTREE_BASE:-$BATS_TMPDIR}/$project_name/$branch"
    mkdir -p "$(dirname "$wt_path")"
    git worktree add "$wt_path" -b "$branch" 2>/dev/null
    echo "$wt_path"
}

# Remove test worktree and optionally its branch
remove_test_worktree() {
    local wt_path="$1"
    local delete_branch="${2:-false}"
    local branch

    if [ "$delete_branch" = "true" ]; then
        branch=$(git worktree list 2>/dev/null | grep "$wt_path" | awk '{print $NF}' | tr -d '[]')
    fi

    git worktree remove --force "$wt_path" 2>/dev/null || true

    if [ "$delete_branch" = "true" ] && [ -n "$branch" ]; then
        git branch -D "$branch" 2>/dev/null || true
    fi
}

# Clean up all worktrees except the main repo
cleanup_all_worktrees() {
    local main_repo="$1"
    git worktree list --porcelain 2>/dev/null | grep "^worktree " | cut -d' ' -f2 | while read -r wt; do
        if [ "$wt" != "$main_repo" ]; then
            git worktree remove --force "$wt" 2>/dev/null || true
        fi
    done
}
