#!/usr/bin/env bash
# ==============================================================================
# TMUX WORKTREES - Shared Helper Functions
# ==============================================================================

# Determine plugin directory (works when sourced or executed)
if [ -n "$TMUX_WORKTREES_PLUGIN_DIR" ]; then
    PLUGIN_DIR="$TMUX_WORKTREES_PLUGIN_DIR"
elif [ -n "${BASH_SOURCE[0]}" ]; then
    PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
else
    PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fi

SCRIPTS_DIR="$PLUGIN_DIR/scripts"

# ==============================================================================
# TMUX CONFIGURATION HELPERS
# ==============================================================================

# Get tmux option with fallback default
# Usage: get_tmux_option "@option-name" "default-value"
get_tmux_option() {
    local option="$1"
    local default="$2"
    local value

    # Use the test socket if set, otherwise default tmux
    if [ -n "$TMUX_SOCKET" ]; then
        value=$(tmux -L "$TMUX_SOCKET" show-option -gqv "$option" 2>/dev/null)
    else
        value=$(tmux show-option -gqv "$option" 2>/dev/null)
    fi

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Load all configuration variables
load_config() {
    WORKTREE_BASE=$(get_tmux_option "@worktree-path" "$HOME/.tmux-worktrees/worktrees")
    MANAGED_DIR="$WORKTREE_BASE/__tmux_managed__"
    ITEMS_PER_PAGE=$(get_tmux_option "@worktree-items-per-page" "15")
    FETCH_TIMEOUT=$(get_tmux_option "@worktree-fetch-timeout" "30")
    KEYBINDING=$(get_tmux_option "@worktree-keybinding" "W")

    export WORKTREE_BASE MANAGED_DIR ITEMS_PER_PAGE FETCH_TIMEOUT KEYBINDING
}

# ==============================================================================
# SESSION NAME HELPERS
# ==============================================================================

# Get project name from git repository root directory
get_project_name() {
    basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
}

# Generate session name from project and branch
# Replaces / with - for valid tmux session names
get_session_name() {
    local project="$1"
    local branch="$2"
    local session_name="${project}-${branch}"
    echo "${session_name//\//-}"
}

# ==============================================================================
# PATH HELPERS
# ==============================================================================

# Sanitize path for display (replace $HOME with ~)
display_path() {
    local path="$1"
    echo "${path/#$HOME/~}"
}

# Ensure directory exists
ensure_dir() {
    local dir="$1"
    [ -d "$dir" ] || mkdir -p "$dir"
}
