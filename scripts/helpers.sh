#!/usr/bin/env bash
# ==============================================================================
# TMUX WORKTREES - Shared Helper Functions
# ==============================================================================
# Requires: bash 3.2+, tmux 3.0+

# ==============================================================================
# VERSION
# ==============================================================================

TMUX_WORKTREE_VERSION="1.0.0"

# ==============================================================================
# VERSION CHECKS
# ==============================================================================

# Check tmux version (display-menu requires 3.0+)
# Returns 0 if compatible, 1 if not
check_tmux_version() {
    local version_string
    local major_version

    version_string=$(tmux -V 2>/dev/null | sed 's/[^0-9.]//g')
    major_version=$(echo "$version_string" | cut -d. -f1)

    if [ -z "$major_version" ] || [ "$major_version" -lt 3 ]; then
        return 1
    fi
    return 0
}

# Display error if tmux version is incompatible
ensure_tmux_version() {
    if ! check_tmux_version; then
        echo "Error: tmux-worktree requires tmux 3.0+ (display-menu support)" >&2
        echo "Current version: $(tmux -V 2>/dev/null || echo 'unknown')" >&2
        return 1
    fi
    return 0
}

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

# Validate positive integer, return default if invalid
# Usage: validate_positive_int "value" "default" "option_name"
validate_positive_int() {
    local value="$1"
    local default="$2"
    local option_name="$3"

    # Check if value is a positive integer
    if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "$value"
    else
        # Show warning only if tmux is available
        if command -v tmux >/dev/null 2>&1 && [ -n "$TMUX" ]; then
            tmux display-message "Warning: Invalid $option_name '$value', using default $default" 2>/dev/null || true
        fi
        echo "$default"
    fi
}

# Validate page number - must be positive integer, defaults to 1
# Usage: validate_page "value"
validate_page() {
    local value="$1"
    # Check if value is a positive integer
    if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "$value"
    else
        echo "1"
    fi
}

# Limit filter length to prevent DoS (max 256 chars)
# Usage: limit_filter "filter_string"
limit_filter() {
    local filter="$1"
    local max_length=256
    if [ ${#filter} -gt $max_length ]; then
        echo "${filter:0:$max_length}"
    else
        echo "$filter"
    fi
}

# Load all configuration variables
load_config() {
    WORKTREE_BASE=$(get_tmux_option "@worktree-path" "$HOME/.tmux-worktree")
    # Validate WORKTREE_BASE is not empty
    if [ -z "$WORKTREE_BASE" ]; then
        WORKTREE_BASE="$HOME/.tmux-worktree"
    fi
    MANAGED_DIR="$WORKTREE_BASE/__tmux_worktree_managed__"
    # Legacy managed dir for backward compatibility with standalone script
    LEGACY_MANAGED_DIR="$WORKTREE_BASE/__tmux_managed__"

    # Load and validate numeric options
    local items_raw
    items_raw=$(get_tmux_option "@worktree-items-per-page" "15")
    ITEMS_PER_PAGE=$(validate_positive_int "$items_raw" "15" "@worktree-items-per-page")

    local timeout_raw
    timeout_raw=$(get_tmux_option "@worktree-fetch-timeout" "30")
    FETCH_TIMEOUT=$(validate_positive_int "$timeout_raw" "30" "@worktree-fetch-timeout")

    KEYBINDING=$(get_tmux_option "@worktree-keybinding" "W")
    DEBUG=$(get_tmux_option "@worktree-debug" "off")

    # Menu key configuration
    KEY_NEXT=$(get_tmux_option "@worktree-key-next" "i")
    KEY_PREV=$(get_tmux_option "@worktree-key-prev" "o")
    KEY_FILTER=$(get_tmux_option "@worktree-key-filter" "f")
    KEY_CLEAR_FILTER=$(get_tmux_option "@worktree-key-clear-filter" "c")
    KEY_FETCH=$(get_tmux_option "@worktree-key-fetch" "r")
    KEY_HELP=$(get_tmux_option "@worktree-key-help" "h")
    KEY_BACK=$(get_tmux_option "@worktree-key-back" "BSpace")
    KEY_QUIT=$(get_tmux_option "@worktree-key-quit" "q")
    KEY_NEW=$(get_tmux_option "@worktree-key-new" "n")

    # Help menu toggle
    SHOW_HELP_MENU=$(get_tmux_option "@worktree-help-menu" "on")

    export WORKTREE_BASE MANAGED_DIR LEGACY_MANAGED_DIR ITEMS_PER_PAGE FETCH_TIMEOUT KEYBINDING DEBUG
    export KEY_NEXT KEY_PREV KEY_FILTER KEY_CLEAR_FILTER KEY_FETCH KEY_HELP KEY_BACK KEY_QUIT KEY_NEW
    export SHOW_HELP_MENU
}

# ==============================================================================
# DEBUG LOGGING
# ==============================================================================

# Log debug message if debug mode is enabled
# Usage: debug_log "message"
debug_log() {
    if [ "$DEBUG" = "on" ]; then
        local log_file="$WORKTREE_BASE/.tmux-worktree.log"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$log_file" 2>/dev/null || true
    fi
}

# ==============================================================================
# SESSION NAME HELPERS
# ==============================================================================

# Note: get_project_name() is defined in worktree_manager.sh with sanitization
# to prevent command injection. Do not duplicate here.

# Generate session name from project and branch
# Replaces / with - for valid tmux session names
get_session_name() {
    local project="$1"
    local branch="$2"
    local session_name="${project}-${branch}"
    echo "${session_name//\//-}"
}

# ==============================================================================
# TIMEOUT HELPER (macOS compatibility)
# ==============================================================================

# Portable timeout command wrapper
# On Linux: uses coreutils timeout
# On macOS: uses gtimeout (from coreutils) or falls back to no timeout
# Uses --foreground to properly terminate child processes on timeout
run_with_timeout() {
    local seconds="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        # --foreground ensures child processes are killed on timeout
        timeout --foreground "$seconds" "$@" 2>/dev/null || timeout "$seconds" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout --foreground "$seconds" "$@" 2>/dev/null || gtimeout "$seconds" "$@"
    else
        # No timeout available - run without timeout protection
        "$@"
    fi
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
