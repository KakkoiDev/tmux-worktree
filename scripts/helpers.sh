#!/usr/bin/env bash
# ==============================================================================
# TMUX WORKTREES - Shared Helper Functions
# ==============================================================================
# Requires: bash 3.2+, tmux 3.0+

# ==============================================================================
# VERSION
# ==============================================================================

TMUX_WORKTREE_VERSION="0.1.0"

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

# Get config cache file path (unique per tmux server)
_get_config_cache_file() {
    local tmux_pid
    # Respect TMUX_SOCKET for testing
    if [ -n "$TMUX_SOCKET" ]; then
        tmux_pid=$(tmux -L "$TMUX_SOCKET" display-message -p '#{pid}' 2>/dev/null || echo "notmux")
    else
        tmux_pid=$(tmux display-message -p '#{pid}' 2>/dev/null || echo "notmux")
    fi
    echo "/tmp/tmux-worktree-config-${tmux_pid}"
}

# Check if config cache is valid (exists and less than 5 minutes old)
_is_cache_valid() {
    local cache_file="$1"
    [ -f "$cache_file" ] || return 1

    # Check age - cache valid for 300 seconds (5 minutes)
    local cache_age
    if [[ "$OSTYPE" == "darwin"* ]]; then
        cache_age=$(( $(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || echo 0) ))
    else
        cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
    fi
    [ "$cache_age" -lt 300 ]
}

# Load config from tmux and write to cache file
_load_config_from_tmux() {
    local cache_file="$1"

    WORKTREE_BASE=$(get_tmux_option "@worktree-path" "$HOME/.tmux-worktree")
    [ -z "$WORKTREE_BASE" ] && WORKTREE_BASE="$HOME/.tmux-worktree"

    local items_raw timeout_raw
    items_raw=$(get_tmux_option "@worktree-items-per-page" "15")
    ITEMS_PER_PAGE=$(validate_positive_int "$items_raw" "15" "@worktree-items-per-page")

    timeout_raw=$(get_tmux_option "@worktree-fetch-timeout" "30")
    FETCH_TIMEOUT=$(validate_positive_int "$timeout_raw" "30" "@worktree-fetch-timeout")

    KEYBINDING=$(get_tmux_option "@worktree-keybinding" "W")
    DEBUG=$(get_tmux_option "@worktree-debug" "off")

    KEY_LIST=$(get_tmux_option "@worktree-key-list" "l")
    KEY_ADD=$(get_tmux_option "@worktree-key-add" "a")
    KEY_REMOVE=$(get_tmux_option "@worktree-key-remove" "d")
    KEY_NEXT=$(get_tmux_option "@worktree-key-next" "i")
    KEY_PREV=$(get_tmux_option "@worktree-key-prev" "o")
    KEY_FILTER=$(get_tmux_option "@worktree-key-filter" "f")
    KEY_CLEAR_FILTER=$(get_tmux_option "@worktree-key-clear-filter" "c")
    KEY_FETCH=$(get_tmux_option "@worktree-key-fetch" "r")
    KEY_BACK=$(get_tmux_option "@worktree-key-back" "b")
    KEY_QUIT=$(get_tmux_option "@worktree-key-quit" "q")
    KEY_NEW=$(get_tmux_option "@worktree-key-new" "n")
    KEY_OPTIONS=$(get_tmux_option "@worktree-key-options" "o")
    FETCH_PRUNE=$(get_tmux_option "@worktree-fetch-prune" "off")
    COPY_IGNORED=$(get_tmux_option "@worktree-copy-ignored" "off")
    # Track which options were explicitly set (non-empty raw value)
    _EXPLICIT_OPTIONS=""
    local _raw_val
    if [ -n "$TMUX_SOCKET" ]; then
        _raw_val=$(tmux -L "$TMUX_SOCKET" show-option -gqv "@worktree-fetch-prune" 2>/dev/null)
    else
        _raw_val=$(tmux show-option -gqv "@worktree-fetch-prune" 2>/dev/null)
    fi
    [ -n "$_raw_val" ] && _EXPLICIT_OPTIONS="${_EXPLICIT_OPTIONS}fetch-prune "

    if [ -n "$TMUX_SOCKET" ]; then
        _raw_val=$(tmux -L "$TMUX_SOCKET" show-option -gqv "@worktree-copy-ignored" 2>/dev/null)
    else
        _raw_val=$(tmux show-option -gqv "@worktree-copy-ignored" 2>/dev/null)
    fi
    [ -n "$_raw_val" ] && _EXPLICIT_OPTIONS="${_EXPLICIT_OPTIONS}copy-ignored "

    # Write to cache file for next invocation
    cat > "$cache_file" 2>/dev/null <<CACHE
WORKTREE_BASE='$WORKTREE_BASE'
ITEMS_PER_PAGE='$ITEMS_PER_PAGE'
FETCH_TIMEOUT='$FETCH_TIMEOUT'
KEYBINDING='$KEYBINDING'
DEBUG='$DEBUG'
KEY_LIST='$KEY_LIST'
KEY_ADD='$KEY_ADD'
KEY_REMOVE='$KEY_REMOVE'
KEY_NEXT='$KEY_NEXT'
KEY_PREV='$KEY_PREV'
KEY_FILTER='$KEY_FILTER'
KEY_CLEAR_FILTER='$KEY_CLEAR_FILTER'
KEY_FETCH='$KEY_FETCH'
KEY_BACK='$KEY_BACK'
KEY_QUIT='$KEY_QUIT'
KEY_NEW='$KEY_NEW'
KEY_OPTIONS='$KEY_OPTIONS'
FETCH_PRUNE='$FETCH_PRUNE'
COPY_IGNORED='$COPY_IGNORED'
CACHE
}

# ==============================================================================
# PROJECT CONFIG FILE
# ==============================================================================

# Load project-level config from .tmux-worktree.conf in repo root
# Only overrides options NOT explicitly set via tmux
_load_project_config() {
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0

    local config_file="$repo_root/.tmux-worktree.conf"
    [ -f "$config_file" ] || return 0

    debug_log "Loading project config from $config_file"

    local key value
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue

        # Parse key = value (requires = sign)
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"

        # Trim whitespace
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [ -z "$key" ] && continue

        case "$key" in
            fetch-prune)
                if [[ "$_EXPLICIT_OPTIONS" != *"fetch-prune"* ]]; then
                    FETCH_PRUNE="$value"
                    debug_log "Project config: fetch-prune=$value"
                fi
                ;;
            copy-ignored)
                if [[ "$_EXPLICIT_OPTIONS" != *"copy-ignored"* ]]; then
                    COPY_IGNORED="$value"
                    debug_log "Project config: copy-ignored=$value"
                fi
                ;;
        esac
    done < "$config_file"
}

# Load all configuration variables (file-cached for performance)
# First call: 15 tmux calls + write cache (~100ms)
# Subsequent calls: 1 file read (~5ms)
load_config() {
    local cache_file
    cache_file=$(_get_config_cache_file)

    if _is_cache_valid "$cache_file"; then
        # Fast path: read from cache file
        source "$cache_file"
    else
        # Slow path: load from tmux and write cache
        _load_config_from_tmux "$cache_file"
    fi

    export WORKTREE_BASE ITEMS_PER_PAGE FETCH_TIMEOUT FETCH_PRUNE KEYBINDING DEBUG
    export KEY_LIST KEY_ADD KEY_REMOVE
    export KEY_NEXT KEY_PREV KEY_FILTER KEY_CLEAR_FILTER KEY_FETCH KEY_BACK KEY_QUIT KEY_NEW
    export KEY_OPTIONS COPY_IGNORED

    # Load project config (overrides non-explicit options)
    _load_project_config

    # Ensure worktree base directory exists (needed for debug logs)
    if [ -n "$WORKTREE_BASE" ]; then
        mkdir -p "$WORKTREE_BASE" 2>/dev/null || true
    fi

    # Log config if debug enabled
    if [ "$DEBUG" = "on" ]; then
        debug_log "=== Config loaded ==="
        debug_log "WORKTREE_BASE=$WORKTREE_BASE"
        debug_log "ITEMS_PER_PAGE=$ITEMS_PER_PAGE FETCH_TIMEOUT=$FETCH_TIMEOUT"
        debug_log "Keys: next=$KEY_NEXT prev=$KEY_PREV filter=$KEY_FILTER back=$KEY_BACK"
    fi
}

# Force reload configuration (invalidates cache)
reload_config() {
    local cache_file
    cache_file=$(_get_config_cache_file)
    rm -f "$cache_file" 2>/dev/null
    load_config
}

# ==============================================================================
# OPTIONS PERSISTENCE
# ==============================================================================

# Get state file path for persisting options across tmux restarts
# Override with TMUX_WORKTREE_STATE_FILE for testing
_get_state_file() {
    echo "${TMUX_WORKTREE_STATE_FILE:-$HOME/.tmux-worktree/options.conf}"
}

# Save a tmux option to the state file
# Usage: save_option "@worktree-copy-ignored" "on"
save_option() {
    local key="$1"
    local value="$2"
    local state_file
    state_file=$(_get_state_file)

    mkdir -p "$(dirname "$state_file")" 2>/dev/null || true

    # Remove existing entry for this key, then append
    if [ -f "$state_file" ]; then
        local tmp="${state_file}.tmp"
        grep -v "^${key}=" "$state_file" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$state_file"
    fi
    echo "${key}=${value}" >> "$state_file"
}

# Restore saved options from state file into tmux
restore_saved_options() {
    local state_file
    state_file=$(_get_state_file)

    [ -f "$state_file" ] || return 0

    local key value
    while IFS='=' read -r key value; do
        # Skip empty lines and comments
        [ -z "$key" ] && continue
        [[ "$key" == \#* ]] && continue

        if [ -n "$TMUX_SOCKET" ]; then
            tmux -L "$TMUX_SOCKET" set-option -g "$key" "$value" 2>/dev/null || true
        else
            tmux set-option -g "$key" "$value" 2>/dev/null || true
        fi
    done < "$state_file"
}

# ==============================================================================
# RECENT BRANCH TRACKING
# ==============================================================================

# Max raw entries in recent log (internal file hygiene, not user-facing)
_RECENT_LOG_MAX=100

# Get recent log file path
# Override with TMUX_WORKTREE_RECENT_FILE for testing
_get_recent_file() {
    echo "${TMUX_WORKTREE_RECENT_FILE:-$WORKTREE_BASE/.recent.log}"
}

# Record a branch switch to the recent log
# Format: project:branch (one per line, newest at bottom)
# Usage: record_recent_branch "project" "branch"
record_recent_branch() {
    local project="$1"
    local branch="$2"
    [ -z "$project" ] || [ -z "$branch" ] && return 0

    local recent_file
    recent_file=$(_get_recent_file)
    mkdir -p "$(dirname "$recent_file")" 2>/dev/null || true

    # Append entry
    echo "$project:$branch" >> "$recent_file"

    # Auto-trim for file hygiene
    local count
    count=$(wc -l < "$recent_file" 2>/dev/null | tr -d ' ')
    if [ "$count" -gt "$_RECENT_LOG_MAX" ]; then
        tail -"$_RECENT_LOG_MAX" "$recent_file" > "$recent_file.tmp" && mv "$recent_file.tmp" "$recent_file"
    fi
}

# Remove a branch from the recent log
# Usage: remove_recent_branch "project" "branch"
remove_recent_branch() {
    local project="$1"
    local branch="$2"
    [ -z "$project" ] || [ -z "$branch" ] && return 0

    local recent_file
    recent_file=$(_get_recent_file)
    [ -f "$recent_file" ] || return 0

    # Remove all entries matching project:branch
    grep -v "^${project}:${branch}$" "$recent_file" > "$recent_file.tmp" 2>/dev/null || true
    mv "$recent_file.tmp" "$recent_file"
}

# Get all recent unique branches for a project (newest first)
# Returns one branch name per line
# Usage: get_recent_branches "project"
get_recent_branches() {
    local project="$1"

    local recent_file
    recent_file=$(_get_recent_file)
    [ -f "$recent_file" ] || return 0

    # Reverse, filter by project, deduplicate
    awk -F: -v proj="$project" '
    {
        lines[NR] = $0
    }
    END {
        for (i = NR; i >= 1; i--) {
            split(lines[i], parts, ":")
            if (parts[1] != proj) continue
            branch = parts[2]
            if (branch == "") continue
            if (seen[branch]) continue
            seen[branch] = 1
            print branch
        }
    }' "$recent_file"
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
# Replaces characters invalid in tmux session names: / . :
get_session_name() {
    local project="$1"
    local branch="$2"
    local session_name="${project}-${branch}"
    session_name="${session_name//\//_}"
    session_name="${session_name//./_}"
    session_name="${session_name//:/_}"
    echo "$session_name"
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

# ==============================================================================
# WORKTREE HEALTH CHECK HELPERS
# ==============================================================================

# Check if git version supports worktree repair (Git 2.30+)
# Returns 0 if supported, 1 if not
has_worktree_repair() {
    local version_string
    local major minor

    version_string=$(git --version 2>/dev/null | sed 's/git version //' | cut -d' ' -f1)
    major=$(echo "$version_string" | cut -d. -f1)
    minor=$(echo "$version_string" | cut -d. -f2)

    # git worktree repair was added in Git 2.30
    if [ -n "$major" ] && [ -n "$minor" ]; then
        if [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 30 ]; }; then
            return 0
        fi
    fi
    return 1
}

# Count stale worktrees (path doesn't exist on filesystem)
# Returns count as stdout
count_stale_worktrees() {
    local count=0
    local path

    while IFS= read -r line; do
        if [[ "$line" == worktree\ * ]]; then
            path="${line#worktree }"
            if [ ! -d "$path" ]; then
                count=$((count + 1))
            fi
        fi
    done < <(git worktree list --porcelain 2>/dev/null)

    echo "$count"
}

# Prune stale worktree entries (removes entries for deleted paths)
# Returns 0 on success
worktree_prune() {
    git worktree prune 2>/dev/null
}

# Repair worktree references (Git 2.30+ only)
# Returns 0 on success, 1 if not supported or failed
worktree_repair() {
    if ! has_worktree_repair; then
        return 1
    fi
    git worktree repair 2>/dev/null
}
