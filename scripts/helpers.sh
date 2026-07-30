#!/usr/bin/env bash
# ==============================================================================
# TMUX WORKTREES - Shared Helper Functions
# ==============================================================================
# Requires: bash 3.2+, tmux 3.0+

# ==============================================================================
# VERSION
# ==============================================================================

TMUX_WORKTREE_VERSION="0.1.0"

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
# VENDORED TMUX-TOOLKIT
# ==============================================================================
#
# lib/ is a git subtree of KakkoiDev/tmux-toolkit's dist branch. It is the same
# code tmux-agent-mesh, -tracker, -resumer and tmux-session-order vendor, so a fix
# lands once instead of five times. Do not edit it in place: CI recomputes
# lib/.checksum and fails if it has drifted.
#
# TK_SOCKET is what collapses this file's fifteen hand-copied
# `if [ -n "$TMUX_SOCKET" ]` branches into one. tk_tmux prepends -L when it is
# set, so every call site becomes a plain `tk_tmux ...` with no fork.

# shellcheck source=../lib/toolkit.sh
source "$PLUGIN_DIR/lib/toolkit.sh"
tk_require_version 0.2.0
tk_init worktree "${WORKTREE_BASE:-$HOME/.tmux-worktree}"
# shellcheck disable=SC2034  # read by tk_tmux in the vendored lib/tmux.sh
TK_SOCKET="${TMUX_SOCKET:-}"

# ==============================================================================
# VERSION CHECKS
# ==============================================================================

# Check tmux version (display-menu requires 3.0+)
# Returns 0 if compatible, 1 if not
check_tmux_version() { tk_vers_ge 3.0; }

# Display error if tmux version is incompatible
ensure_tmux_version() {
    if ! check_tmux_version; then
        echo "Error: tmux-worktree requires tmux 3.0+ (display-menu support)" >&2
        echo "Current version: $(tk_vers)" >&2
        return 1
    fi
    return 0
}

# ==============================================================================
# TMUX CONFIGURATION HELPERS
# ==============================================================================

# Get tmux option with fallback default
# Usage: get_tmux_option "@option-name" "default-value"
get_tmux_option() { tk_opt "$1" "$2"; }

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
    tmux_pid=$(tk_server_pid)
    echo "/tmp/tmux-worktree-config-${tmux_pid:-notmux}"
}

# Check if config cache is valid (exists and less than 5 minutes old)
_is_cache_valid() { tk_fresh "$1" 300; }

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
    ADOPT_SESSION=$(get_tmux_option "@worktree-adopt-session" "on")
    SORT_RECENT_DEFAULT=$(get_tmux_option "@worktree-sort-recent-default" "on")

    local age_raw
    age_raw=$(get_tmux_option "@worktree-max-age-days" "30")
    MAX_AGE_DAYS=$(validate_positive_int "$age_raw" "30" "@worktree-max-age-days")
    MAX_AGE_CHOICES=$(get_tmux_option "@worktree-max-age-choices" "7,30,90")
    [ -z "$MAX_AGE_CHOICES" ] && MAX_AGE_CHOICES="7,30,90"

    # Track which options were explicitly set (non-empty raw value). A project
    # .tmux-worktree.conf may only override an option the user did NOT set in tmux,
    # so this needs the raw value, not get_tmux_option's defaulted one.
    _EXPLICIT_OPTIONS=""
    local _opt _raw_val
    for _opt in fetch-prune copy-ignored max-age-days max-age-choices; do
        _raw_val=$(tk_tmux show-option -gqv "@worktree-$_opt" 2>/dev/null) || true
        [ -n "$_raw_val" ] && _EXPLICIT_OPTIONS="${_EXPLICIT_OPTIONS}$_opt "
    done

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
ADOPT_SESSION='$ADOPT_SESSION'
MAX_AGE_DAYS='$MAX_AGE_DAYS'
MAX_AGE_CHOICES='$MAX_AGE_CHOICES'
SORT_RECENT_DEFAULT='$SORT_RECENT_DEFAULT'
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
            max-age-days)
                if [[ "$_EXPLICIT_OPTIONS" != *"max-age-days"* ]]; then
                    MAX_AGE_DAYS=$(validate_positive_int "$value" "${MAX_AGE_DAYS:-30}" "max-age-days")
                    debug_log "Project config: max-age-days=$MAX_AGE_DAYS"
                fi
                ;;
            max-age-choices)
                if [[ "$_EXPLICIT_OPTIONS" != *"max-age-choices"* ]]; then
                    [ -n "$value" ] && MAX_AGE_CHOICES="$value"
                    debug_log "Project config: max-age-choices=$MAX_AGE_CHOICES"
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
        debug_log "load_config: from cache=$cache_file"
    else
        # Slow path: load from tmux and write cache
        _load_config_from_tmux "$cache_file"
        debug_log "load_config: from tmux (cache written to $cache_file)"
    fi

    export WORKTREE_BASE ITEMS_PER_PAGE FETCH_TIMEOUT FETCH_PRUNE KEYBINDING DEBUG
    export KEY_LIST KEY_ADD KEY_REMOVE
    export KEY_NEXT KEY_PREV KEY_FILTER KEY_CLEAR_FILTER KEY_FETCH KEY_BACK KEY_QUIT KEY_NEW
    export KEY_OPTIONS COPY_IGNORED MAX_AGE_DAYS MAX_AGE_CHOICES SORT_RECENT_DEFAULT

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

        tk_tmux set-option -g "$key" "$value" 2>/dev/null || true
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

# Migrate legacy log lines to timestamped format.
# Legacy line: "project:branch"
# New line:    "<unix_ts> project:branch"
# Any non-empty line missing a numeric prefix gets stamped with `now`.
_migrate_recent_log() {
    local recent_file
    recent_file=$(_get_recent_file)
    [ -f "$recent_file" ] || return 0

    local needs_migration=0
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        if [[ ! "$line" =~ ^[0-9]+[[:space:]] ]]; then
            needs_migration=1
            break
        fi
    done < "$recent_file"

    [ "$needs_migration" -eq 0 ] && return 0

    local now
    now=$(date +%s)
    local tmp="${recent_file}.migrate.$$"
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        if [[ "$line" =~ ^[0-9]+[[:space:]] ]]; then
            echo "$line"
        else
            echo "$now $line"
        fi
    done < "$recent_file" > "$tmp" && mv "$tmp" "$recent_file"

    debug_log "_migrate_recent_log: stamped legacy entries with $now"
}

# Record a branch switch to the recent log.
# Format: "<unix_ts> project:branch" (one per line, newest at bottom).
# Legacy lines without a timestamp are migrated on first call.
# Usage: record_recent_branch "project" "branch"
record_recent_branch() {
    local project="$1"
    local branch="$2"
    [ -z "$project" ] || [ -z "$branch" ] && return 0

    local recent_file
    recent_file=$(_get_recent_file)
    mkdir -p "$(dirname "$recent_file")" 2>/dev/null || true

    _migrate_recent_log

    local now
    now=$(date +%s)
    echo "$now $project:$branch" >> "$recent_file"

    # Auto-trim for file hygiene
    local count
    count=$(wc -l < "$recent_file" 2>/dev/null | tr -d ' ')
    if [ "$count" -gt "$_RECENT_LOG_MAX" ]; then
        tail -"$_RECENT_LOG_MAX" "$recent_file" > "$recent_file.tmp" && mv "$recent_file.tmp" "$recent_file"
    fi
}

# Remove a branch from the recent log (matches both legacy and timestamped rows).
# Usage: remove_recent_branch "project" "branch"
remove_recent_branch() {
    local project="$1"
    local branch="$2"
    [ -z "$project" ] || [ -z "$branch" ] && return 0

    local recent_file
    recent_file=$(_get_recent_file)
    [ -f "$recent_file" ] || return 0

    awk -v proj="$project" -v br="$branch" '
    {
        rest = $0
        if (match($0, /^[0-9]+[[:space:]]/)) {
            rest = substr($0, RLENGTH + 1)
        }
        if (rest == proj ":" br) next
        print $0
    }' "$recent_file" > "$recent_file.tmp" 2>/dev/null || true
    mv "$recent_file.tmp" "$recent_file"
}

# Internal: emit "<ts> <branch>" one per unique branch, sorted by newest ts desc.
# Ties broken by latest append order (line number).
_recent_entries_for() {
    local project="$1"
    local recent_file
    recent_file=$(_get_recent_file)
    [ -f "$recent_file" ] || return 0

    awk -v proj="$project" '
    {
        rest = $0
        ts = 0
        if (match($0, /^[0-9]+[[:space:]]/)) {
            ts = substr($0, 1, RLENGTH - 1) + 0
            rest = substr($0, RLENGTH + 1)
        }
        colon = index(rest, ":")
        if (colon == 0) next
        p = substr(rest, 1, colon - 1)
        b = substr(rest, colon + 1)
        if (p != proj) next
        if (b == "") next
        if (!(b in max_ts) || ts > max_ts[b] || (ts == max_ts[b] && NR > max_line[b])) {
            max_ts[b] = ts
            max_line[b] = NR
        }
    }
    END {
        n = 0
        for (b in max_ts) {
            n++
            branches[n] = b
        }
        # Insertion sort: primary key max_ts desc, secondary key max_line desc
        for (i = 2; i <= n; i++) {
            k = branches[i]
            kts = max_ts[k]
            kline = max_line[k]
            j = i - 1
            while (j > 0) {
                prev = branches[j]
                if (max_ts[prev] < kts || (max_ts[prev] == kts && max_line[prev] < kline)) {
                    branches[j + 1] = prev
                    j--
                } else break
            }
            branches[j + 1] = k
        }
        for (i = 1; i <= n; i++) {
            print max_ts[branches[i]] " " branches[i]
        }
    }' "$recent_file"
}

# Get all recent unique branches for a project (newest first).
# Usage: get_recent_branches "project"
get_recent_branches() {
    local project="$1"
    _recent_entries_for "$project" | awk '{
        sub(/^[0-9]+ /, "", $0)
        print $0
    }'
}

# Get newest unix timestamp recorded for a specific project/branch.
# Prints "0" when the branch is not in the log.
# Usage: get_recent_timestamp "project" "branch"
get_recent_timestamp() {
    local project="$1"
    local branch="$2"
    [ -z "$project" ] || [ -z "$branch" ] && { echo 0; return 0; }

    local ts
    ts=$(_recent_entries_for "$project" | awk -v br="$branch" '{
        if ($2 == br) { print $1; exit }
    }')
    if [ -z "$ts" ]; then
        echo 0
    else
        echo "$ts"
    fi
}

# Emit "<ts> <branch>" one per unique branch, sorted newest first.
# Public alias of _recent_entries_for, used by menu rendering.
# Usage: get_recent_entries "project"
get_recent_entries() {
    _recent_entries_for "$1"
}

# Format a unix timestamp as a short relative-age label.
# Usage: format_age_short "<ts>" ["<now>"]
#   ts=0 or empty   -> never
#   diff < 60s      -> now
#   diff < 1h       -> Nm
#   diff < 1d       -> Nh
#   diff < 1w       -> Nd
#   otherwise       -> Nw
format_age_short() {
    local ts="${1:-0}"
    local now="${2:-$(date +%s)}"

    [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
    if [ "$ts" -le 0 ]; then
        echo "never"
        return 0
    fi

    local diff=$((now - ts))
    if [ "$diff" -lt 0 ]; then
        diff=0
    fi

    if [ "$diff" -lt 60 ]; then
        echo "now"
    elif [ "$diff" -lt 3600 ]; then
        echo "$((diff / 60))m"
    elif [ "$diff" -lt 86400 ]; then
        echo "$((diff / 3600))h"
    elif [ "$diff" -lt 604800 ]; then
        echo "$((diff / 86400))d"
    else
        echo "$((diff / 604800))w"
    fi
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

# Always log errors regardless of DEBUG setting
# Usage: error_log "message"
error_log() {
    local log_file="$WORKTREE_BASE/.tmux-worktree.log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >> "$log_file" 2>/dev/null || true
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

    local timeout_cmd=""
    if command -v timeout >/dev/null 2>&1; then
        timeout_cmd="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
        timeout_cmd="gtimeout"
    fi

    if [ -z "$timeout_cmd" ]; then
        # No timeout available - run without timeout protection
        "$@"
        return
    fi

    # Test --foreground support once, then run the command exactly once
    if "$timeout_cmd" --foreground 0.1 true >/dev/null 2>&1; then
        "$timeout_cmd" --foreground "$seconds" "$@"
    else
        "$timeout_cmd" "$seconds" "$@"
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
