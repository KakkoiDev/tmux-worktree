#!/usr/bin/env bash
# E2E test helpers for tmux display-menu interaction via expect
#
# These helpers manage an isolated tmux server with an attached pty client
# (via expect) to test real menu rendering and key-based selection.
#
# Key insight: tmux send-keys does NOT reach display-menu overlays.
# Only writing to the client's pty (via expect) works.

# Isolated socket for E2E tests (separate from mock-based test-worktrees)
export E2E_SOCKET="e2e-worktrees"
export E2E_PREFIX_CHAR="a"  # Ctrl-A, set explicitly on test server

# Path to the expect script
_E2E_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export E2E_EXPECT_SCRIPT="${_E2E_HELPER_DIR}/fixtures/expect_menu.exp"

# ==============================================================================
# SERVER LIFECYCLE
# ==============================================================================

# Start E2E tmux server with known prefix and terminal size
# Usage: start_e2e_server [start_dir]
start_e2e_server() {
    local start_dir="${1:-$PWD}"
    tmux -L "$E2E_SOCKET" kill-server 2>/dev/null || true

    # -f /dev/null prevents loading user's ~/.tmux.conf (avoids session renaming,
    # plugin interference, and prefix key differences)
    tmux -f /dev/null -L "$E2E_SOCKET" new-session -d -s "e2e-session" -c "$start_dir" -x 80 -y 24

    # Set a known prefix key so tests never depend on user config
    tmux -L "$E2E_SOCKET" set-option -g prefix C-a
    tmux -L "$E2E_SOCKET" bind-key C-a send-prefix

    # Override TMUX_SOCKET inside the server environment so that scripts
    # called via run-shell use the correct socket (not the inherited
    # "test-worktrees" from the bats test process)
    tmux -L "$E2E_SOCKET" set-environment -g TMUX_SOCKET "$E2E_SOCKET"

    # Disable mouse (prevents interference with menu key navigation)
    tmux -L "$E2E_SOCKET" set-option -g mouse off 2>/dev/null || true
}

# Stop E2E tmux server
stop_e2e_server() {
    tmux -L "$E2E_SOCKET" kill-server 2>/dev/null || true
}

# Run tmux command on E2E server
e2e_tmux() {
    tmux -L "$E2E_SOCKET" "$@"
}

# ==============================================================================
# MENU INTERACTION
# ==============================================================================

# Open a menu via command mode and send selection keys
# Usage: e2e_menu_interact "tmux_command" "key1|key2|..."
# Example: e2e_menu_interact "run-shell '/path/to/script tmux_worktrees_main'" "l|q"
# Returns: 0 on success, non-zero on timeout/failure
e2e_menu_interact() {
    local tmux_cmd="$1"
    local keys="${2:-}"

    E2E_SOCKET="$E2E_SOCKET" \
    E2E_PREFIX="$E2E_PREFIX_CHAR" \
    E2E_CMD="$tmux_cmd" \
    E2E_KEYS="$keys" \
    E2E_DELAY="${E2E_DELAY:-300}" \
    E2E_TIMEOUT="${E2E_TIMEOUT:-8}" \
    E2E_CAPTURE_FILE="${E2E_CAPTURE_FILE:-}" \
    expect "$E2E_EXPECT_SCRIPT"
}

# Send keys via keybinding (no command mode, just prefix + key)
# Usage: e2e_send_keys "W" "q"  (prefix+W opens menu, then q to close)
e2e_send_keys() {
    local bind_key="$1"
    local menu_keys="${2:-}"

    E2E_SOCKET="$E2E_SOCKET" \
    E2E_PREFIX="$E2E_PREFIX_CHAR" \
    E2E_CMD="" \
    E2E_BIND="$bind_key" \
    E2E_KEYS="$menu_keys" \
    E2E_DELAY="${E2E_DELAY:-300}" \
    E2E_TIMEOUT="${E2E_TIMEOUT:-8}" \
    E2E_CAPTURE_FILE="${E2E_CAPTURE_FILE:-}" \
    expect "$E2E_EXPECT_SCRIPT"
}

# Convenience: open main menu via run-shell and send keys
# Usage: e2e_main_menu "key1|key2"
e2e_main_menu() {
    local keys="$1"
    e2e_menu_interact \
        "run-shell '${SCRIPTS_DIR}/worktree_manager.sh tmux_worktrees_main'" \
        "$keys"
}

# Convenience: open a specific sub-menu directly
# Usage: e2e_sub_menu "show_options_menu" "DOWN|ENTER"
e2e_sub_menu() {
    local func="$1"
    local keys="$2"
    e2e_menu_interact \
        "run-shell '${SCRIPTS_DIR}/worktree_manager.sh $func'" \
        "$keys"
}

# ==============================================================================
# WAIT HELPERS (menu actions execute asynchronously via run-shell)
# ==============================================================================

# Wait for a tmux option to reach an expected value
# Usage: e2e_wait_option "@worktree-debug" "on" [timeout_seconds]
e2e_wait_option() {
    local option="$1"
    local expected="$2"
    local timeout="${3:-5}"
    local actual=""
    local i=0

    while [ "$i" -lt "$((timeout * 2))" ]; do
        actual=$(e2e_tmux show-option -gqv "$option" 2>/dev/null)
        if [ "$actual" = "$expected" ]; then
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done

    echo "Timeout: $option expected '$expected', got '$actual'" >&2
    return 1
}

# Wait for a tmux session to exist
# Usage: e2e_wait_session "session-name" [timeout_seconds]
e2e_wait_session() {
    local session="$1"
    local timeout="${2:-5}"
    local i=0

    while [ "$i" -lt "$((timeout * 2))" ]; do
        if e2e_tmux has-session -t "$session" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done

    echo "Timeout: session '$session' not found" >&2
    return 1
}

# Wait for a directory to exist (worktree creation)
# Usage: e2e_wait_dir "/path/to/worktree" [timeout_seconds]
e2e_wait_dir() {
    local dir="$1"
    local timeout="${2:-5}"
    local i=0

    while [ "$i" -lt "$((timeout * 2))" ]; do
        if [ -d "$dir" ]; then
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done

    echo "Timeout: directory '$dir' not found" >&2
    return 1
}

# ==============================================================================
# SCREEN-STATE ASSERTIONS
#
# Two capture paths:
#  - e2e_capture_pane: the pane BUFFER (what's in the scrollback). Does NOT
#    include display-menu overlays (those are drawn by tmux on top of the
#    pane and don't land in the buffer).
#  - e2e_capture_menu / e2e_capture_keybind: the raw TERMINAL bytes delivered
#    to the attached pty. This DOES include display-menu overlay renders.
#    Output contains ANSI escape codes - strip before matching if needed.
# ==============================================================================

# Capture the pane buffer (no overlays). Useful for post-action terminal state.
e2e_capture_pane() {
    if [ "$#" -eq 0 ]; then
        e2e_tmux capture-pane -p -t e2e-session
    else
        e2e_tmux capture-pane -p "$@"
    fi
}

# Wait until the pane buffer contains a substring.
e2e_wait_pane_contains() {
    local needle="$1"
    local timeout="${2:-5}"
    local i=0

    while [ "$i" -lt "$((timeout * 2))" ]; do
        if e2e_capture_pane | grep -qF -- "$needle"; then
            return 0
        fi
        sleep 0.5
        i=$((i + 1))
    done

    echo "Timeout: pane did not contain '$needle'" >&2
    echo "--- pane dump ---" >&2
    e2e_capture_pane >&2
    echo "--- end ---" >&2
    return 1
}

# Open a menu via expect and capture the terminal bytes (includes overlay).
# Returns the raw byte stream on stdout.
# Usage: out=$(e2e_capture_menu "tmux_cmd" "keys")
e2e_capture_menu() {
    local tmux_cmd="$1"
    local keys="${2:-}"
    local capture_file
    capture_file=$(mktemp "${BATS_TMPDIR:-/tmp}/e2e-capture.XXXXXX")

    E2E_CAPTURE_FILE="$capture_file" \
        e2e_menu_interact "$tmux_cmd" "$keys" >/dev/null 2>&1 || true

    cat "$capture_file"
    rm -f "$capture_file"
}

# Open a menu via keybinding (prefix + bind_key) and capture overlay bytes.
# Usage: out=$(e2e_capture_keybind "W" "")
e2e_capture_keybind() {
    local bind_key="$1"
    local keys="${2:-}"
    local capture_file
    capture_file=$(mktemp "${BATS_TMPDIR:-/tmp}/e2e-capture.XXXXXX")

    E2E_CAPTURE_FILE="$capture_file" \
        e2e_send_keys "$bind_key" "$keys" >/dev/null 2>&1 || true

    cat "$capture_file"
    rm -f "$capture_file"
}

# Strip ANSI escape sequences from captured terminal output.
# Usage: printf '%s' "$capture" | e2e_strip_ansi
e2e_strip_ansi() {
    sed $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][A-Z0-9]//g; s/\x1b\\][^\x07]*\x07//g'
}

# Assert that a menu capture contains all of the given needles (fixed-string).
# Strips ANSI before matching. Returns 0 if all present, 1 otherwise.
# Usage: e2e_assert_menu_contains "$capture" "List" "Options" "Quit"
e2e_assert_menu_contains() {
    local capture="$1"; shift
    local clean
    clean=$(printf '%s' "$capture" | e2e_strip_ansi)
    local n
    for n in "$@"; do
        if ! printf '%s' "$clean" | grep -qF -- "$n"; then
            echo "Assertion failed: menu did not contain '$n'" >&2
            echo "--- menu dump (ANSI stripped) ---" >&2
            printf '%s' "$clean" | tr -cd '\n[:print:]' >&2
            echo >&2
            echo "--- end ---" >&2
            return 1
        fi
    done
    return 0
}

# ==============================================================================
# CLEANUP HELPERS
# ==============================================================================

# Kill all sessions except e2e-session
e2e_cleanup_sessions() {
    e2e_tmux list-sessions -F '#{session_name}' 2>/dev/null | \
        grep -v '^e2e-session$' | while read -r s; do
            e2e_tmux kill-session -t "$s" 2>/dev/null || true
        done
}

# Load plugin into E2E server (for keybinding tests)
e2e_load_plugin() {
    TMUX_SOCKET="$E2E_SOCKET" e2e_tmux run-shell "$PLUGIN_DIR/worktrees.tmux"
}
