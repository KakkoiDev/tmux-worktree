#!/usr/bin/env bash
# Test helper utilities for tmux-worktree BATS tests

# Isolated tmux socket for testing (prevents interference with user's tmux)
export TMUX_SOCKET="test-worktrees"
export TMUX_TMPDIR="${BATS_TMPDIR:-/tmp}"

# Unset $TMUX so production `tmux` calls in sourced scripts don't inherit
# the user's socket. Combined with the stub below, every tmux invocation
# from test code routes to -L "$TMUX_SOCKET" (the isolated test server).
unset TMUX TMUX_PANE

# Shadow `tmux` for all tests that load this helper.
#
# The stub only kicks in when we're NOT inside a tmux session (i.e. $TMUX is
# empty). That covers the failure mode we care about: the bats shell itself,
# which would otherwise send display-menu/display-message to the user's real
# tmux via an inherited $TMUX.
#
# Inside tmux (run-shell subshells during E2E tests), $TMUX is set and we want
# production tmux calls to reach the real tmux binary untouched.
#
# What the stub does when active:
#   1. UI overlay commands (display-menu, display-popup, display-message,
#      command-prompt) return 0 without rendering. The test server has no
#      attached client so they would error anyway.
#   2. Everything else forwards to the isolated server via -L $TMUX_SOCKET
#      so session/window ops are real and tests can assert on them.
tmux() {
    if [ -n "$TMUX" ]; then
        command tmux "$@"
        return
    fi
    case "$1" in
        display-menu|display-popup|command-prompt)
            return 0 ;;
        display-message)
            # `display-message -p ...` is a query that prints to stdout (no client
            # required), so route it to the test server. Status-line UI messages
            # (no -p) need an attached client and are suppressed.
            local _arg
            for _arg in "$@"; do
                case "$_arg" in
                    -p|-p*) command tmux -L "$TMUX_SOCKET" "$@"; return ;;
                esac
            done
            return 0 ;;
        *)
            command tmux -L "$TMUX_SOCKET" "$@" ;;
    esac
}
export -f tmux

# Plugin paths (set relative to test_helper.bash location, not test file)
_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PLUGIN_DIR="${_HELPER_DIR}/.."
export SCRIPTS_DIR="${PLUGIN_DIR}/scripts"

# Test fixture paths
export FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures"
export TEST_REPO_DIR=""

# Shared repo for faster tests (created once per file)
export SHARED_REPO_DIR=""

# Start isolated tmux server for testing.
#   - `command tmux` bypasses the shadow function (which would no-op new-session).
#   - `-f /dev/null` ignores the user's ~/.tmux.conf so plugins, session-rename
#     hooks, and custom options can't leak into tests (matches the E2E server).
#   - A second "_keepalive" session keeps the server alive when production code
#     under test kills the session tests reference (e.g. remove_worktree on
#     "test-session"). Without it, the server would exit and the next test's
#     setup would fail with "no server running".
start_tmux_server() {
    command tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
    local start_dir="${TEST_REPO_DIR:-${SHARED_REPO_DIR:-$PWD}}"
    command tmux -f /dev/null -L "$TMUX_SOCKET" new-session -d -s "test-session" -c "$start_dir"
    command tmux -L "$TMUX_SOCKET" new-session -d -s "_keepalive" -c "$start_dir"
}

# Stop isolated tmux server
stop_tmux_server() {
    command tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
}

# Run tmux command in isolated server. Bypasses the shadow so all subcommands
# (including has-session, kill-session, etc.) reach the real tmux server.
tmux_run() {
    command tmux -L "$TMUX_SOCKET" "$@"
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

# ==============================================================================
# SHARED REPO (create once per test file for speed)
# ==============================================================================

# File to persist shared repo path across subshells
_shared_repo_file() {
    echo "${BATS_FILE_TMPDIR:-$BATS_TMPDIR}/.shared_repo_path"
}

# Create shared repo - call from setup_file()
create_shared_repo() {
    SHARED_REPO_DIR=$(mktemp -d "${BATS_TMPDIR}/shared-repo.XXXXXX")
    echo "$SHARED_REPO_DIR" > "$(_shared_repo_file)"

    cd "$SHARED_REPO_DIR" || return 1
    git init -q --initial-branch=master
    git config user.email "test@test.com"
    git config user.name "Test User"

    echo "initial" > README.md
    git add README.md
    git commit -q -m "Initial commit"

    git branch feature-one
    git branch feature-two
    git branch bugfix-123

    echo "$SHARED_REPO_DIR"
}

# Reset shared repo to clean state - call from setup()
# Base branches: master, feature-one, feature-two, bugfix-123
reset_shared_repo() {
    # Read from file if variable not set (bats subshell issue)
    if [ -z "$SHARED_REPO_DIR" ] && [ -f "$(_shared_repo_file)" ]; then
        SHARED_REPO_DIR=$(cat "$(_shared_repo_file)")
    fi
    [ -z "$SHARED_REPO_DIR" ] && return 1
    [ ! -d "$SHARED_REPO_DIR" ] && return 1

    cd "$SHARED_REPO_DIR" || return 1

    # Quick check: only clean if there are extra worktrees
    local wt_count
    wt_count=$(git worktree list 2>/dev/null | wc -l)
    if [ "$wt_count" -gt 1 ]; then
        git worktree list --porcelain 2>/dev/null | grep "^worktree " | cut -d' ' -f2 | while read -r wt; do
            [ "$wt" != "$SHARED_REPO_DIR" ] && git worktree remove --force "$wt" 2>/dev/null || true
        done
    fi

    # Delete non-base branches (ensures clean state even after test crashes)
    git checkout -q master 2>/dev/null || true
    git for-each-ref --format='%(refname:short)' refs/heads/ | while read -r branch; do
        case "$branch" in
            master|feature-one|feature-two|bugfix-123) ;;
            *) git branch -D "$branch" 2>/dev/null || true ;;
        esac
    done

    git checkout -q master 2>/dev/null || true
    TEST_REPO_DIR="$SHARED_REPO_DIR"
}

# Cleanup shared repo - call from teardown_file()
cleanup_shared_repo() {
    # Read from file if variable not set
    if [ -z "$SHARED_REPO_DIR" ] && [ -f "$(_shared_repo_file)" ]; then
        SHARED_REPO_DIR=$(cat "$(_shared_repo_file)")
    fi

    if [ -n "$SHARED_REPO_DIR" ] && [ -d "$SHARED_REPO_DIR" ]; then
        cd "$SHARED_REPO_DIR" 2>/dev/null && \
        git worktree list --porcelain 2>/dev/null | grep "^worktree " | cut -d' ' -f2 | while read -r wt; do
            [ "$wt" != "$SHARED_REPO_DIR" ] && git worktree remove --force "$wt" 2>/dev/null || true
        done
        rm -rf "$SHARED_REPO_DIR"
    fi
    rm -f "$(_shared_repo_file)" 2>/dev/null || true
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

# Assert string does NOT contain substring
refute_contains() {
    local haystack="$1"
    local needle="$2"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "Expected '$haystack' to NOT contain '$needle'" >&2
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

# Assert string matches an ERE.
#
# Subject first, like assert_contains and its 225 callers. This replaces
# assert_matches, which took the pattern first: two assertions in the same file
# with opposite argument orders is a silent-pass waiting to happen, and it only
# had two callers against assert_contains's 225, so the minority moved.
assert_match_re() {
    local actual="$1"
    local pattern="$2"
    if [[ ! "$actual" =~ $pattern ]]; then
        echo "Expected '$actual' to match pattern '$pattern'" >&2
        return 1
    fi
}

# Assert string does NOT match an ERE.
refute_match_re() {
    local actual="$1"
    local pattern="$2"
    if [[ "$actual" =~ $pattern ]]; then
        echo "Expected '$actual' to NOT match pattern '$pattern'" >&2
        return 1
    fi
}

# Assert a glob pattern matches. $2 is deliberately unquoted at the comparison,
# which is what makes it a pattern rather than a literal.
assert_match() {
    local actual="$1"
    local pattern="$2"
    # shellcheck disable=SC2053
    if [[ ! "$actual" == $pattern ]]; then
        echo "Expected '$actual' to match glob '$pattern'" >&2
        return 1
    fi
}

refute_match() {
    local actual="$1"
    local pattern="$2"
    # shellcheck disable=SC2053
    if [[ "$actual" == $pattern ]]; then
        echo "Expected '$actual' to NOT match glob '$pattern'" >&2
        return 1
    fi
}

# assert_one_of <actual> <allowed>... - for a value that legitimately has more
# than one correct answer. Replaces `[[ "$x" -eq 0 || "$x" -eq 1 ]]`, which as a
# bare compound was inert on bash 3.2 as well as hard to read.
assert_one_of() {
    local actual="$1"; shift
    local c
    for c in "$@"; do
        [[ "$actual" == "$c" ]] && return 0
    done
    echo "Expected one of [$*], got '$actual'" >&2
    return 1
}

# Numeric comparisons. `-ge`/`-le` fail loudly on a non-numeric operand, which is
# what you want from a count assertion: an empty $(... | wc -l) should be a test
# failure, not a silent zero.
assert_num_ge() {
    if [[ ! "$1" -ge "$2" ]]; then
        echo "Expected >= $2, got '$1'" >&2
        return 1
    fi
}

assert_num_le() {
    if [[ ! "$1" -le "$2" ]]; then
        echo "Expected <= $2, got '$1'" >&2
        return 1
    fi
}

# Assert a directory does NOT exist.
refute_dir() {
    if [[ -d "$1" ]]; then
        echo "Directory should not exist: $1" >&2
        return 1
    fi
}

# assert_no_crash - the assertion four tests were reaching for and not making.
#
# They each wrote `[[ "$status" -eq 0 ]] || [[ "$status" -ne 0 ]]` with a comment
# saying "always true - verifies no crash". It is indeed always true, so it
# verified nothing, and as a bare compound it could not have failed regardless.
#
# "Did not crash" is testable: a shell reports a signal death as 128+N, so 139 is
# SIGSEGV and 134 is SIGABRT. Anything below 126 is the command choosing its own
# exit status, which is the definition of handling the case rather than crashing.
# 126 and 127 are "not executable" and "not found", which are also real failures
# worth catching rather than waving through.
assert_no_crash() {
    if [[ -z "${status:-}" ]]; then
        echo "assert_no_crash: no \$status; call it after \`run\`" >&2
        return 1
    fi
    if [[ "$status" -ge 126 ]]; then
        echo "Crashed or could not execute: status $status" >&2
        echo "Output: $output" >&2
        return 1
    fi
}

# Assert string does not contain substring
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "Expected '$haystack' to NOT contain '$needle'" >&2
        return 1
    fi
}

# Assert output line count
assert_line_count() {
    local expected="$1"
    local actual
    actual=$(echo "$output" | wc -l)
    if [ "$expected" -ne "$actual" ]; then
        echo "Expected $expected lines, got $actual" >&2
        return 1
    fi
}

# ==============================================================================
# WORKTREE LIFECYCLE HELPERS
# ==============================================================================

# Kill all test tmux sessions created during tests (on test server)
cleanup_test_sessions() {
    tmux_run list-sessions -F '#{session_name}' 2>/dev/null | \
        grep -E '^test-repo' | \
        while read -r session; do
            tmux_run kill-session -t "$session" 2>/dev/null || true
        done
}

# Kill sessions created by create_new_worktree on the MAIN tmux server
# These are named like "shared-repo-XXXXX-branch-name"
cleanup_main_server_test_sessions() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null | \
        grep -E '^shared-repo' | \
        while read -r session; do
            tmux kill-session -t "$session" 2>/dev/null || true
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

# ==============================================================================
# SAFE TEST ISOLATION
# ==============================================================================

# Initialize WORKTREE_BASE safely for test isolation
# MUST be called AFTER load_config because load_config overwrites WORKTREE_BASE
# Uses /tmp explicitly to avoid any ambiguity with BATS_TMPDIR
init_test_worktree_base() {
    export WORKTREE_BASE="/tmp/tmux-worktree-test-$$"
    mkdir -p "$WORKTREE_BASE"
    echo "$WORKTREE_BASE"
}

# Safely clean up WORKTREE_BASE - only deletes if under /tmp
# Prevents accidental deletion of ~/.tmux-worktree
safe_cleanup_worktree_base() {
    if [[ -z "$WORKTREE_BASE" ]]; then
        return 0
    fi

    # Only delete if path is under /tmp (strict safety check)
    if [[ "$WORKTREE_BASE" == /tmp/* ]]; then
        rm -rf "$WORKTREE_BASE"
    else
        echo "WARNING: Refusing to delete WORKTREE_BASE='$WORKTREE_BASE' - not under /tmp" >&2
    fi
}
