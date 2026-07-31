#!/usr/bin/env bash
# ==============================================================================
# TMUX WORKTREES - Core Worktree Manager
# ==============================================================================
# Requires: bash 4.0+, git, tmux, timeout (coreutils)

# Ensure PATH is set for git and other commands
if [ -z "$PATH" ] || ! command -v git >/dev/null 2>&1; then
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
fi

# Ensure HOME is set
if [ -z "$HOME" ]; then
    HOME=$(eval echo ~"$USER")
    export HOME
fi

# Determine script location and source helpers
if [ -n "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# Source helpers and load config (only if not already loaded in test context)
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/filter.sh"
# shellcheck source=../lib/menu.sh
source "${PLUGIN_DIR:-$SCRIPT_DIR/..}/lib/menu.sh"
# Skip load_config if WORKTREE_BASE is already set to a temp path (test mode)
if [[ ! "$WORKTREE_BASE" == /tmp/* ]]; then
    load_config
fi

# ==============================================================================
# PATTERN CONVERSION
# ==============================================================================

# Convert shell glob pattern to regex for awk matching
# Converts: . -> \. (escape dots), * -> .* (any chars), ? -> . (single char)
# Returns anchored regex: ^pattern$
convert_glob_to_regex() {
    local pattern="$1"
    if [[ -z "$pattern" ]]; then
        echo ""
        return
    fi
    # Escape dots, convert wildcards, anchor pattern
    pattern="${pattern//./\\.}"
    pattern="${pattern//\*/.*}"
    pattern="${pattern//\?/.}"
    echo "^${pattern}$"
}

# ==============================================================================
# GIT REPOSITORY VALIDATION
# ==============================================================================

# Validate we're in a git repository, show error if not
require_git_repo() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        display_menu "Not a git repository" '"Quit" "q" ""'
        return 1
    fi
    return 0
}

# ==============================================================================
# REMOTE BRANCH FETCHING
# ==============================================================================

# Fetch remote branches with timeout protection
fetch_remote_branches() {
    require_git_repo || return 1
    local timeout_seconds=${FETCH_TIMEOUT:-30}
    local error_file
    error_file=$(mktemp 2>/dev/null || echo "/tmp/tmux-worktree-fetch-$$")

    # Display fetching message
    tmux display-message "Fetching remote branches..."
    debug_log "Starting git fetch in $(pwd) with timeout ${timeout_seconds}s"

    # Build fetch command (--prune only when explicitly enabled)
    local fetch_args="--all"
    if [ "${FETCH_PRUNE:-off}" = "on" ]; then
        fetch_args="--all --prune"
    fi

    # Run git fetch with timeout, capture stderr
    if run_with_timeout "$timeout_seconds" git fetch $fetch_args 2>"$error_file"; then
        debug_log "Fetch completed successfully"
        tmux display-message "Remote branches fetched successfully"
        rm -f "$error_file"
        return 0
    else
        local exit_code=$?
        local error_msg
        error_msg=$(head -1 "$error_file" 2>/dev/null | cut -c1-80)
        error_log "fetch_remote_branches: cwd=$(pwd) args=$fetch_args exit=$exit_code err=$(cat "$error_file" 2>/dev/null)"

        # Show first line of error (truncated) or generic message
        if [ -n "$error_msg" ]; then
            tmux display-message "Fetch failed: $error_msg"
        else
            tmux display-message "Fetch failed (exit $exit_code) - check debug log or run 'git fetch' manually"
        fi
        rm -f "$error_file"
        return 1
    fi
}

# ==============================================================================
# CORE DATA FUNCTIONS
# ==============================================================================

# Get project name from git repository (works from worktrees too)
# Sanitizes output to prevent command injection via malicious directory names
get_project_name() {
    # Fast path: use env var if in managed session
    if [ -n "$TMUX_WORKTREE_PROJECT" ]; then
        debug_log "get_project_name: from env=$TMUX_WORKTREE_PROJECT"
        echo "$TMUX_WORKTREE_PROJECT"
        return
    fi

    local name
    # Use git-common-dir to get the main repo path (works from worktrees too)
    local git_common_dir
    git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
    # In worktrees, git-common-dir returns absolute path to main repo's .git
    # In regular repos, it returns relative ".git"
    if [ -n "$git_common_dir" ] && [[ "$git_common_dir" == /* ]]; then
        # Absolute path means we're in a worktree - get parent directory name
        name=$(basename "$(dirname "$git_common_dir")")
    else
        # Regular repo - use show-toplevel
        name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
    fi
    # Sanitize: allow only alphanumeric, dash, underscore, dot
    local result
    result=$(echo "$name" | tr -cd 'a-zA-Z0-9_.-')
    debug_log "get_project_name: resolved=$result (git-common-dir=$git_common_dir)"
    echo "$result"
}

# Remove worktree helper function
remove_worktree() {
    require_git_repo || return 1
    local worktree_path="$1"
    local branch_name="$2"
    local session_name="$3"
    local current_page="$4"

    debug_log "remove_worktree called: path='$worktree_path' branch='$branch_name' session='$session_name'"

    # Check if the worktree path exists
    if [ ! -d "$worktree_path" ]; then
        # Path already deleted - just prune the stale entry
        debug_log "remove_worktree: path already gone, running prune"
        worktree_prune
        tmux display-message "Cleaned stale worktree: $branch_name"
    else
        # Remove the worktree with timeout protection
        # Note: Branch is NOT deleted - user can do that manually if needed
        local error_output
        error_output=$(run_with_timeout 10 git worktree remove --force "$worktree_path" 2>&1)
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            debug_log "remove_worktree: worktree removed OK"
            tmux display-message "Worktree removed (branch kept): $branch_name"
        else
            error_log "remove_worktree: path=$worktree_path branch=$branch_name exit=$exit_code err=$error_output"
            local error_msg
            error_msg=$(_git_error_summary "$error_output")
            if [ -n "$error_msg" ]; then
                tmux display-message "Remove failed: $error_msg"
            else
                tmux display-message "Remove failed (exit $exit_code)"
            fi
        fi
    fi

    # Kill the tmux session if it exists (try both naming patterns)
    if tmux kill-session -t "=$session_name" 2>/dev/null; then
        debug_log "remove_worktree: session killed: $session_name"
    elif tmux kill-session -t "=$branch_name" 2>/dev/null; then
        debug_log "remove_worktree: session killed: $branch_name"
    fi

    # Remove from recent log
    local project_name
    project_name=$(get_project_name)
    remove_recent_branch "$project_name" "$branch_name"

    # Refresh the menu
    show_remove_worktree_menu "$current_page"
}

# Get git worktree data with pagination and optional filter
# Output format: first line = total_pages, remaining lines = menu items (space-separated on one line)
get_worktree_data() {
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local sort_recent=${3:-0}
    local sanitized_filter
    sanitized_filter=$(sanitize_filter "$filter")
    local regex_filter
    regex_filter=$(convert_glob_to_regex "$sanitized_filter")
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))

    local project_name
    project_name=$(get_project_name)

    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    # Auto-prune stale worktrees before listing
    if [ "$(count_stale_worktrees)" -gt 0 ]; then
        worktree_prune
        debug_log "get_worktree_data: auto-pruned stale worktrees"
    fi

    # Log worktree paths to debug file
    if [ "$DEBUG" = "on" ]; then
        debug_log "get_worktree_data: listing worktrees for page $page sort_recent=$sort_recent"
    fi

    # Build "branch|age;..." annotations from the recent log
    local now recent_ages=""
    now=$(date +%s)
    local _entry _ts _branch
    while IFS= read -r _entry; do
        [ -z "$_entry" ] && continue
        _ts="${_entry%% *}"
        _branch="${_entry#* }"
        [ -z "$_branch" ] && continue
        local _age
        _age=$(format_age_short "$_ts" "$now")
        if [ -n "$recent_ages" ]; then
            recent_ages="${recent_ages};${_branch}|${_age}"
        else
            recent_ages="${_branch}|${_age}"
        fi
    done < <(get_recent_entries "$project_name")

    if [ "$sort_recent" = "1" ]; then
        # Reorder porcelain: recent branches first, then rest
        local recent_pipe
        recent_pipe=$(get_recent_branches "$project_name" | tr '\n' '|' | sed 's/|$//')

        LC_ALL=C git worktree list --porcelain | LC_ALL=C awk \
            -v recent="$recent_pipe" \
            -f "$SCRIPT_DIR/awk/worktree_reorder.awk" | LC_ALL=C awk \
            -v project="$project_name" \
            -v filter="$regex_filter" \
            -v items_per_page="$ITEMS_PER_PAGE" \
            -v start="$start_line" \
            -v end="$end_line" \
            -v script_path="$script_path" \
            -v recent_ages="$recent_ages" \
            -f "$SCRIPT_DIR/awk/worktree_data.awk"
    else
        LC_ALL=C git worktree list --porcelain | LC_ALL=C awk \
            -f "$SCRIPT_DIR/awk/worktree_sort_alpha.awk" | LC_ALL=C awk \
            -v project="$project_name" \
            -v filter="$regex_filter" \
            -v items_per_page="$ITEMS_PER_PAGE" \
            -v start="$start_line" \
            -v end="$end_line" \
            -v script_path="$script_path" \
            -v recent_ages="$recent_ages" \
            -f "$SCRIPT_DIR/awk/worktree_data.awk"
    fi
}

# Get git branch data with pagination, optional filter, and remote branches
# Output format: first line = total_pages, remaining lines = menu items (space-separated on one line)
get_branch_data() {
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local include_remotes=${3:-0}
    local sanitized_filter
    sanitized_filter=$(sanitize_filter "$filter")
    local regex_filter
    regex_filter=$(convert_glob_to_regex "$sanitized_filter")
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))

    local project_name
    project_name=$(get_project_name)

    # Get local branches
    local branch_cmd="git branch --format='%(refname:short)'"

    # Add remote branches if requested
    if [ "$include_remotes" = "1" ]; then
        branch_cmd="{ git branch --format='%(refname:short)'; git branch -r --format='%(refname:short)' | grep -v 'HEAD'; }"
    fi

    # Get branches that already have worktrees, with their paths.
    # Encoded as "branch1|path1;branch2|path2" for branch_data.awk.
    local existing_worktrees
    existing_worktrees=$(git worktree list --porcelain 2>/dev/null \
        | awk '/^worktree / {p=$2} /^branch refs\/heads\// {b=$2; sub("refs/heads/","",b); printf "%s|%s;", b, p}' \
        | sed 's/;$//')

    eval "$branch_cmd" | awk \
        -v project="$project_name" \
        -v filter="$regex_filter" \
        -v items_per_page="$ITEMS_PER_PAGE" \
        -v start="$start_line" \
        -v end="$end_line" \
        -v existing_wt="$existing_worktrees" \
        -v script_path="$SCRIPT_DIR/worktree_manager.sh" \
        -f "$SCRIPT_DIR/awk/branch_data.awk"
}

# Get removable worktree data with pagination and optional filter
# Output format: first line = total_pages, remaining lines = menu items (space-separated on one line)
get_removable_worktree_data() {
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local sanitized_filter
    sanitized_filter=$(sanitize_filter "$filter")
    local regex_filter
    regex_filter=$(convert_glob_to_regex "$sanitized_filter")
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))

    local project_name
    project_name=$(get_project_name)
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    # Log worktree paths to debug file
    if [ "$DEBUG" = "on" ]; then
        debug_log "get_removable_worktree_data: listing worktrees for page $page"
    fi

    LC_ALL=C git worktree list --porcelain | LC_ALL=C awk \
        -v current_dir="$(pwd)" \
        -v script_path="$script_path" \
        -v current_page="$page" \
        -v project="$project_name" \
        -v filter="$regex_filter" \
        -v items_per_page="$ITEMS_PER_PAGE" \
        -v start="$start_line" \
        -v end="$end_line" \
        -f "$SCRIPT_DIR/awk/removable_data.awk"
}

# ==============================================================================
# PAGE CALCULATION FUNCTIONS
# ==============================================================================

get_worktree_page_count() {
    local filter=${1:-}
    local sanitized_filter
    sanitized_filter=$(sanitize_filter "$filter")
    local regex_filter
    regex_filter=$(convert_glob_to_regex "$sanitized_filter")
    local total
    total=$(LC_ALL=C git worktree list --porcelain | LC_ALL=C awk \
        -v filter="$regex_filter" \
        -f "$SCRIPT_DIR/awk/worktree_count.awk")
    echo $(( (total + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))
}

get_branch_page_count() {
    local filter=${1:-}
    local include_remotes=${2:-0}
    local sanitized_filter
    sanitized_filter=$(sanitize_filter "$filter")
    local regex_filter
    regex_filter=$(convert_glob_to_regex "$sanitized_filter")

    # Build branch command based on include_remotes
    local branch_cmd="git branch --format='%(refname:short)'"
    if [ "$include_remotes" = "1" ]; then
        branch_cmd="{ git branch --format='%(refname:short)'; git branch -r --format='%(refname:short)' | grep -v 'HEAD'; }"
    fi

    local total
    total=$(eval "$branch_cmd" | awk \
        -v filter="$regex_filter" \
        -f "$SCRIPT_DIR/awk/branch_count.awk")
    echo $(( (total + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))
}

# Build the (recent_ts_pairs, recent_age_pairs) strings from the recent log.
# Exports _STALE_TS_PAIRS and _STALE_AGE_PAIRS for the caller.
_build_stale_context() {
    local project_name="$1"
    local now="$2"

    _STALE_TS_PAIRS=""
    _STALE_AGE_PAIRS=""

    local _entry _ts _branch _age
    while IFS= read -r _entry; do
        [ -z "$_entry" ] && continue
        _ts="${_entry%% *}"
        _branch="${_entry#* }"
        [ -z "$_branch" ] && continue

        _age=$(format_age_short "$_ts" "$now")
        if [ -n "$_STALE_TS_PAIRS" ]; then
            _STALE_TS_PAIRS="${_STALE_TS_PAIRS};${_branch}|${_ts}"
            _STALE_AGE_PAIRS="${_STALE_AGE_PAIRS};${_branch}|${_age}"
        else
            _STALE_TS_PAIRS="${_branch}|${_ts}"
            _STALE_AGE_PAIRS="${_branch}|${_age}"
        fi
    done < <(get_recent_entries "$project_name")
}

# Count stale worktrees for a given age threshold (ignores pagination / filter).
get_stale_worktree_count() {
    local threshold_days="${1:-${MAX_AGE_DAYS:-30}}"
    local filter=${2:-}
    local sanitized_filter regex_filter
    sanitized_filter=$(sanitize_filter "$filter")
    regex_filter=$(convert_glob_to_regex "$sanitized_filter")

    local now threshold_seconds
    now=$(date +%s)
    threshold_seconds=$(( threshold_days * 86400 ))

    local project_name
    project_name=$(get_project_name)
    _build_stale_context "$project_name" "$now"

    local _current_dir
    _current_dir=$(pwd -P 2>/dev/null || pwd)

    LC_ALL=C git worktree list --porcelain | LC_ALL=C awk \
        -v current_dir="$_current_dir" \
        -v filter="$regex_filter" \
        -v threshold_seconds="$threshold_seconds" \
        -v now="$now" \
        -v recent_ts_pairs="$_STALE_TS_PAIRS" \
        -f "$SCRIPT_DIR/awk/stale_count.awk" 2>/dev/null
}

# Get stale worktree menu data (paginated).
# Output: Line 1 = total_pages, Line 2 = space-separated menu items
get_stale_worktree_data() {
    local threshold_days="${1:-${MAX_AGE_DAYS:-30}}"
    local page
    page=$(validate_page "${2:-1}")
    local filter
    filter=$(limit_filter "${3:-}")
    local sanitized_filter regex_filter
    sanitized_filter=$(sanitize_filter "$filter")
    regex_filter=$(convert_glob_to_regex "$sanitized_filter")
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))

    local now threshold_seconds
    now=$(date +%s)
    threshold_seconds=$(( threshold_days * 86400 ))

    local project_name
    project_name=$(get_project_name)
    local script_path="$SCRIPT_DIR/worktree_manager.sh"
    _build_stale_context "$project_name" "$now"

    if [ "$DEBUG" = "on" ]; then
        debug_log "get_stale_worktree_data: threshold=${threshold_days}d page=$page filter='$filter'"
    fi

    local _current_dir
    _current_dir=$(pwd -P 2>/dev/null || pwd)

    LC_ALL=C git worktree list --porcelain | LC_ALL=C awk \
        -v current_dir="$_current_dir" \
        -v script_path="$script_path" \
        -v current_page="$page" \
        -v project="$project_name" \
        -v filter="$regex_filter" \
        -v items_per_page="$ITEMS_PER_PAGE" \
        -v start="$start_line" \
        -v end="$end_line" \
        -v threshold_days="$threshold_days" \
        -v threshold_seconds="$threshold_seconds" \
        -v now="$now" \
        -v recent_ts_pairs="$_STALE_TS_PAIRS" \
        -v recent_age_pairs="$_STALE_AGE_PAIRS" \
        -f "$SCRIPT_DIR/awk/stale_data.awk"
}

get_removable_worktree_page_count() {
    local filter=${1:-}
    local sanitized_filter
    sanitized_filter=$(sanitize_filter "$filter")
    local regex_filter
    regex_filter=$(convert_glob_to_regex "$sanitized_filter")
    local total
    total=$(LC_ALL=C git worktree list --porcelain | LC_ALL=C awk \
        -v current_dir="$(pwd)" \
        -v filter="$regex_filter" \
        -f "$SCRIPT_DIR/awk/removable_count.awk")
    echo $(( (total + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))
}

# ==============================================================================
# NAVIGATION HELPER FUNCTIONS
# ==============================================================================

# Add navigation items to current menu (side-effect: calls tk_menu_item)
_add_nav_items() {
    local page=$1
    local total_pages=$2
    local menu_function=$3
    local filter=${4:-}
    local extra1=${5:-}
    local extra2=${6:-}
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    local filter_args=""
    if [ -n "$filter" ]; then
        filter_args="'$filter'"
    fi

    # Build the sub-args list for tk_menu_cmd.
    # We must pass each positional arg separately so quoting works.
    local _nav_args=()

    # Previous page
    if [ "$page" -gt 1 ]; then
        _nav_args=("$script_path" "$menu_function" "$((page - 1))")
        [ -n "$filter" ] && _nav_args+=("$filter")
        [ -n "$extra1" ] && _nav_args+=("$extra1")
        [ -n "$extra2" ] && _nav_args+=("$extra2")
        local prev_cmd="display-message 'Loading...' ; $(tk_menu_cmd "${_nav_args[@]}")"
        tk_menu_item "◀ Previous" "$KEY_PREV" "$prev_cmd"
    fi

    # Next page
    if [ "$page" -lt "$total_pages" ]; then
        _nav_args=("$script_path" "$menu_function" "$((page + 1))")
        [ -n "$filter" ] && _nav_args+=("$filter")
        [ -n "$extra1" ] && _nav_args+=("$extra1")
        [ -n "$extra2" ] && _nav_args+=("$extra2")
        local next_cmd="display-message 'Loading...' ; $(tk_menu_cmd "${_nav_args[@]}")"
        tk_menu_item "Next ▶" "$KEY_NEXT" "$next_cmd"
    fi

    # Back to main menu
    tk_menu_item "← Back" "$KEY_BACK" "display-message 'Loading...' ; $(tk_menu_cmd "$script_path" tmux_worktrees_main)"
}

# Legacy wrapper for callers that still need string output (none, replaced inline)
# Kept for backward compat only during transition.
generate_nav_options() {
    # This function is no longer used for menu building.
    # Callers now use _add_nav_items which calls tk_menu_item directly.
    echo ""
}

# ==============================================================================
# MENU DISPLAY FUNCTIONS
# ==============================================================================

# Generic tmux menu display function.
# Delegates to tk_menu_show from vendored menu.sh.
# TK_MENU_DRYRUN=1 prints the argument vector for test assertions.
display_menu() {
    tk_menu_show
}

# Show worktree list menu with pagination, optional filter, and optional recent sort
show_worktree_menu() {
    require_git_repo || return 1
    debug_log "show_worktree_menu called: page=${1:-1} filter='${2:-}' sort_recent=${3:-0}"
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local sort_recent="${3:-}"
    if [ -z "$sort_recent" ]; then
        if [ "${SORT_RECENT_DEFAULT:-on}" = "on" ]; then
            sort_recent=1
        else
            sort_recent=0
        fi
    fi
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    # Single combined call for count + data (performance optimization)
    local combined_output
    combined_output=$(get_worktree_data "$page" "$filter" "$sort_recent")
    local total_pages
    total_pages=$(echo "$combined_output" | head -1)
    local worktree_items
    worktree_items=$(echo "$combined_output" | tail -n +2)

    debug_log "show_worktree_menu: total_pages=$total_pages sort_recent=$sort_recent"

    # Build title with state indicators
    local title="Worktrees (Page $page/$total_pages)"
    if [ "$sort_recent" = "1" ]; then
        title="$title [Latest first]"
    else
        title="$title [Alphabetical]"
    fi
    [ -n "$filter" ] && title="$title - Filter: '$filter'"

    tk_menu_reset
    tk_menu_title "$title"

    # Sort toggle: label shows the mode you'll switch TO
    if [ "$sort_recent" = "1" ]; then
        tk_menu_item "Alphabetical" "r" "$(tk_menu_cmd "$script_path" show_worktree_menu 1 "$filter" 0)"
    else
        tk_menu_item "Latest first" "r" "$(tk_menu_cmd "$script_path" show_worktree_menu 1 "$filter" 1)"
    fi

    # Filter option (preserves sort_recent state)
    tk_menu_item "Filter" "$KEY_FILTER" "command-prompt -T search -p 'Filter pattern:' 'run-shell '\''$script_path'\'' show_worktree_menu 1 '\''%1'\'' $sort_recent'"

    # Clear filter option (only when filter active, preserves sort_recent)
    if [ -n "$filter" ]; then
        tk_menu_item "Clear filter" "$KEY_CLEAR_FILTER" "$(tk_menu_cmd "$script_path" show_worktree_menu 1 '' $sort_recent)"
    fi

    # Parse TSV worktree items
    if [ -n "$worktree_items" ]; then
        while IFS=$'\t' read -r label branch full_path; do
            [ -z "$label" ] && continue
            tk_menu_item "$label" "" "display-message 'Switching...' ; $(tk_menu_cmd "$script_path" switch_worktree "$branch" "$full_path")"
        done <<< "$worktree_items"
    else
        debug_log "show_worktree_menu: no worktrees found"
        tk_menu_text "(No worktrees found)"
    fi

    # Navigation items
    _add_nav_items "$page" "$total_pages" "show_worktree_menu" "$filter" "$sort_recent"

    tk_menu_show
}

# Copy gitignored files from primary worktree to a new worktree
# Uses CoW (cp -c) on macOS for near-instant copies, regular cp on Linux
copy_ignored_files() {
    local target_path="$1"
    local primary
    primary=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')

    debug_log "copy_ignored_files: primary=$primary target=$target_path"

    # Get list of ignored files/directories from primary worktree
    local ignored_items
    ignored_items=$(cd "$primary" && git ls-files --others --ignored --exclude-standard --directory 2>/dev/null)

    if [ -z "$ignored_items" ]; then
        debug_log "copy_ignored_files: no ignored files found"
        return 0
    fi

    local copied=0
    local failed=0

    while IFS= read -r item; do
        [ -z "$item" ] && continue
        # Strip trailing slash for consistent handling
        item="${item%/}"
        local src="$primary/$item"
        local dst="$target_path/$item"

        # Skip if source doesn't exist
        [ ! -e "$src" ] && continue

        # Ensure parent directory exists
        mkdir -p "$(dirname "$dst")" 2>/dev/null

        # Copy using CoW on macOS (with fallback), regular on Linux
        local copy_ok=false
        if [[ "$OSTYPE" == "darwin"* ]]; then
            if cp -Rc "$src" "$dst" 2>/dev/null; then
                copy_ok=true
            elif cp -R "$src" "$dst" 2>/dev/null; then
                copy_ok=true
            fi
        else
            if cp -Ra "$src" "$dst" 2>/dev/null; then
                copy_ok=true
            fi
        fi

        if $copy_ok; then
            copied=$((copied + 1))
        else
            failed=$((failed + 1))
        fi
    done <<< "$ignored_items"

    debug_log "copy_ignored_files: copied=$copied failed=$failed"
    if [ "$failed" -gt 0 ]; then
        error_log "copy_ignored_files: $failed items failed to copy from $primary to $target_path"
    fi

    if [ "$copied" -gt 0 ]; then
        tmux display-message "Copied $copied ignored item(s) to new worktree"
    fi
}

# Shared worktree creation logic
# Usage: _setup_worktree "branch" "worktree_path" "session_name" "project_name"
_setup_worktree() {
    local branch="$1"
    local worktree_path="$2"
    local session_name="$3"
    local project_name="$4"
    debug_log "_setup_worktree: branch=$branch path=$worktree_path session=$session_name project=$project_name"

    # Record to recent log
    record_recent_branch "$project_name" "$branch"

    # Copy ignored files if enabled
    if [ "$COPY_IGNORED" = "on" ]; then
        copy_ignored_files "$worktree_path"
    fi

    # Capture session_id (immutable, e.g. $0/$1/...) instead of relying on the name.
    # A user-defined after-new-session hook can rename the session before we use it;
    # the id survives renames, so we use it for switch-client and the rename-back below.
    local session_id
    session_id=$(tmux new-session -d -P -F '#{session_id}' \
           -c "$worktree_path" -s "$session_name" \
           -e "TMUX_WORKTREE=1" \
           -e "TMUX_WORKTREE_PROJECT=$project_name" \
           -e "TMUX_WORKTREE_BRANCH=$branch" \
           -e "TMUX_WORKTREE_PATH=$worktree_path" 2>&1)
    local new_exit=$?

    if [ $new_exit -ne 0 ] || [ -z "$session_id" ] || [[ "$session_id" != \$* ]]; then
        error_log "_setup_worktree: new-session FAILED exit=$new_exit out=$session_id session=$session_name path=$worktree_path"
        tmux display-message "Worktree created but session failed - try 'tmux new -s $session_name'"
        return 1
    fi

    # Best-effort restore of the plugin-assigned name if an external hook renamed it.
    # Skipped when names already match so we don't trigger after-rename-session loops.
    local current_name
    current_name=$(tmux display-message -p -t "$session_id" '#{session_name}' 2>/dev/null)
    if [ -n "$current_name" ] && [ "$current_name" != "$session_name" ]; then
        if ! tmux rename-session -t "$session_id" "$session_name" 2>/dev/null; then
            debug_log "_setup_worktree: rename-back blocked sid=$session_id current=$current_name target=$session_name"
        fi
    fi

    local session_err
    session_err=$(tmux switch-client -t "$session_id" 2>&1)
    local switch_exit=$?

    if [ $switch_exit -ne 0 ]; then
        error_log "_setup_worktree: switch-client FAILED exit=$switch_exit err=$session_err session=$session_name sid=$session_id"
        tmux display-message "Created session $session_name (switch failed - use 'tmux switch -t $session_name')"
        return 0
    fi

    debug_log "_setup_worktree: SUCCESS session=$session_name sid=$session_id"
    tmux display-message "Created worktree and session: $session_name"
}

# Compute worktree path and session name from branch
_worktree_vars() {
    local branch="$1"
    local project_name="$2"
    _WT_SESSION="${project_name}-${branch//\//_}"
    _WT_SESSION="${_WT_SESSION//./_}"
    _WT_SESSION="${_WT_SESSION//:/_}"
    _WT_PATH="$WORKTREE_BASE/$project_name/$branch"
}

# Pick the most useful line from git stderr for a status-bar message.
# git worktree add prints "Preparing worktree ..." before the real "fatal:"
# line, so head -1 alone surfaces the progress line instead of the cause.
_git_error_summary() {
    local out="$1" line
    line=$(printf '%s\n' "$out" | grep -m1 -iE '^(fatal|error):')
    [ -z "$line" ] && line=$(printf '%s\n' "$out" | grep -viE '^Preparing worktree' | head -1)
    [ -z "$line" ] && line=$(printf '%s\n' "$out" | head -1)
    printf '%s' "$line" | cut -c1-60
}

# tmux after-new-session hook entry point. Called once per new session with
# the session name and its default-path. Cds into the path so git resolves
# correctly, then delegates to adopt_current_session.
adopt_session_hook() {
    local session_name="$1"
    local session_path="$2"

    [ -z "$session_name" ] && return 0
    # Without the session's own directory we cannot resolve its project; refuse
    # rather than adopt using the hook child's inherited CWD (another session's).
    [ -z "$session_path" ] && return 0
    cd "$session_path" 2>/dev/null || return 0

    debug_log "adopt_session_hook: session='$session_name' path='$session_path'"
    adopt_current_session "$session_name"
}

# Rename the calling session to "<project>-<branch>" when inside a git work tree,
# or to "<dir-basename>" when outside one (so sessions opened in non-git dirs no
# longer keep tmux's default "window"/"0" name).
# Optional arg overrides the queried session name (used by tests).
# Skipped when:
#   - @worktree-adopt-session option is "off"
#   - tmux query returns empty (no tmux / no current session)
#   - HEAD is detached inside a git repo (no canonical branch name)
#   - current name already equals the canonical name
#   - current name already starts with "<canonical>-" (treated as already managed)
adopt_current_session() {
    [ "${ADOPT_SESSION:-on}" = "off" ] && return 0

    local current_name="${1:-}"
    if [ -z "$current_name" ]; then
        current_name=$(tmux display-message -p '#{session_name}' 2>/dev/null)
    fi
    [ -z "$current_name" ] && return 0

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)

    local in_git=0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=1

    if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
        if [ "$in_git" = "1" ]; then
            debug_log "adopt_current_session: detached HEAD, skipping (current='$current_name')"
            return 0
        fi
        # Not inside a git work tree: fall back to bare project name (dir basename).
        branch=""
    fi

    local project
    # Adoption must derive the project from this session's own directory, never
    # from a TMUX_WORKTREE_PROJECT inherited by the hook/sweep child process
    # (it leaks across unrelated sessions and mis-stamps every adopted name).
    project=$(TMUX_WORKTREE_PROJECT= get_project_name)
    [ -z "$project" ] && return 0

    # Sanitized "<project>-" prefix (matches whatever get_session_name will emit,
    # e.g. tmux replaces "." with "_"). Used for both the skip rule and as the
    # bare-project fallback name (with the trailing "-" stripped).
    local sanitized_prefix
    sanitized_prefix=$(get_session_name "$project" "")

    local expected
    if [ -n "$branch" ]; then
        expected=$(get_session_name "$project" "$branch")
    else
        expected="${sanitized_prefix%-}"
    fi

    # Already plugin-managed: exact match, or "<project>-..." (any branch under
    # the same project, plugin-created or otherwise). Leave alone.
    [ "$current_name" = "$expected" ] && return 0
    case "$current_name" in
        "$sanitized_prefix"*) debug_log "adopt_current_session: '$current_name' already has project prefix, skipping"; return 0 ;;
    esac

    if tmux rename-session -t "$current_name" "$expected" 2>/dev/null; then
        debug_log "adopt_current_session: renamed '$current_name' -> '$expected'"
        # Propagate plugin env vars to the session so future panes/processes
        # see the same context as plugin-created sessions.
        local worktree_path=""
        [ "$in_git" = "1" ] && worktree_path=$(git rev-parse --show-toplevel 2>/dev/null)
        tmux setenv -t "$expected" TMUX_WORKTREE 1 2>/dev/null || true
        tmux setenv -t "$expected" TMUX_WORKTREE_PROJECT "$project" 2>/dev/null || true
        [ -n "$branch" ] && tmux setenv -t "$expected" TMUX_WORKTREE_BRANCH "$branch" 2>/dev/null || true
        [ -n "$worktree_path" ] && tmux setenv -t "$expected" TMUX_WORKTREE_PATH "$worktree_path" 2>/dev/null || true
    else
        debug_log "adopt_current_session: rename failed '$current_name' -> '$expected'"
        if tmux has-session -t "=$expected" 2>/dev/null; then
            tmux display-message "tmux-worktree: '$current_name' not renamed - '$expected' already exists"
        fi
    fi
}

# Switch to an existing worktree session (or create one) and record to recent log
# Usage: switch_worktree "branch" "full_path"
switch_worktree() {
    local branch="$1"
    local full_path="$2"
    debug_log "switch_worktree called: branch='$branch' path='$full_path'"
    local project_name
    project_name=$(get_project_name)
    _worktree_vars "$branch" "$project_name"
    local session_name="$_WT_SESSION"

    # Record to recent log
    record_recent_branch "$project_name" "$branch"

    # Switch to existing session or create a new one
    if tmux has-session -t "=$session_name" 2>/dev/null; then
        debug_log "switch_worktree: switching to existing session=$session_name"
        tmux switch-client -t "=$session_name"
    else
        debug_log "switch_worktree: creating new session=$session_name"
        # Capture session_id (immutable). See _setup_worktree for why: external
        # after-new-session hooks may rename the session out from under us.
        local session_id
        session_id=$(tmux new-session -d -P -F '#{session_id}' \
            -c "$full_path" -s "$session_name" \
            -e "TMUX_WORKTREE=1" \
            -e "TMUX_WORKTREE_PROJECT=$project_name" \
            -e "TMUX_WORKTREE_BRANCH=$branch" \
            -e "TMUX_WORKTREE_PATH=$full_path" 2>&1)
        local new_exit=$?

        if [ $new_exit -ne 0 ] || [ -z "$session_id" ] || [[ "$session_id" != \$* ]]; then
            error_log "switch_worktree: new-session FAILED exit=$new_exit out=$session_id branch=$branch path=$full_path session=$session_name"
            return 1
        fi

        # Best-effort rename-back, same pattern as _setup_worktree.
        local current_name
        current_name=$(tmux display-message -p -t "$session_id" '#{session_name}' 2>/dev/null)
        if [ -n "$current_name" ] && [ "$current_name" != "$session_name" ]; then
            if ! tmux rename-session -t "$session_id" "$session_name" 2>/dev/null; then
                debug_log "switch_worktree: rename-back blocked sid=$session_id current=$current_name target=$session_name"
            fi
        fi

        if tmux switch-client -t "$session_id"; then
            debug_log "switch_worktree: SUCCESS session=$session_name sid=$session_id"
        else
            error_log "switch_worktree: switch-client FAILED branch=$branch path=$full_path session=$session_name sid=$session_id"
        fi
    fi
}

# Create worktree from existing branch
# Usage: add_worktree "branch" ["remote_ref"]
add_worktree() {
    require_git_repo || return 1
    local branch="$1"
    local remote_ref="${2:-}"
    debug_log "add_worktree called: branch='$branch' remote_ref='$remote_ref'"
    local project_name
    project_name=$(get_project_name)
    _worktree_vars "$branch" "$project_name"
    local session_name="$_WT_SESSION"
    local worktree_path="$_WT_PATH"
    debug_log "add_worktree: project=$project_name session=$session_name path=$worktree_path"

    # Ensure parent directory exists (branches with slashes need intermediate dirs)
    local worktree_parent
    worktree_parent="$(dirname "$worktree_path")"
    if ! mkdir -p "$worktree_parent" 2>/dev/null; then
        error_log "add_worktree: FAILED mkdir $worktree_parent"
        tmux display-message "Failed to create directory: $worktree_parent (check permissions)"
        return 1
    fi

    local error_output
    if [ -n "$remote_ref" ] && ! git show-ref --verify --quiet "refs/heads/$branch"; then
        debug_log "add_worktree: creating new local branch from $remote_ref"
        # Remote branch without existing local branch: create tracking local branch
        error_output=$(git worktree add -b "$branch" "$worktree_path" "$remote_ref" 2>&1)
    else
        debug_log "add_worktree: checking out existing local branch"
        # Local branch (or remote with existing local): check out existing
        error_output=$(git worktree add "$worktree_path" "$branch" 2>&1)
    fi
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        debug_log "add_worktree: worktree created at $worktree_path"
        _setup_worktree "$branch" "$worktree_path" "$session_name" "$project_name"
    else
        error_log "add_worktree: cwd=$(pwd) branch=$branch remote_ref=$remote_ref path=$worktree_path exit=$exit_code err=$error_output"
        local error_msg
        error_msg=$(_git_error_summary "$error_output")
        if [ -n "$error_msg" ]; then
            tmux display-message "Failed: $error_msg"
        else
            tmux display-message "Failed to create worktree (exit $exit_code)"
        fi
    fi
}

# Create new worktree with a new branch (from "New" option in Add menu)
create_new_worktree() {
    require_git_repo || return 1
    local branch="$1"
    debug_log "create_new_worktree called: branch='$branch'"

    # Normalize unambiguous noise: surrounding whitespace and trailing slashes
    # (git never allows a branch name to end in '/'). Everything else is left
    # for git check-ref-format to reject with a clear message rather than guess.
    branch="${branch#"${branch%%[![:space:]]*}"}"
    branch="${branch%"${branch##*[![:space:]]}"}"
    while [ "${branch%/}" != "$branch" ]; do
        branch="${branch%/}"
    done
    if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
        error_log "create_new_worktree: invalid branch name '$branch'"
        tmux display-message "Invalid branch name: $branch"
        return 1
    fi

    local project_name
    project_name=$(get_project_name)
    _worktree_vars "$branch" "$project_name"
    local session_name="$_WT_SESSION"
    local worktree_path="$_WT_PATH"
    debug_log "create_new_worktree: project=$project_name session=$session_name path=$worktree_path"

    # Ensure parent directory exists (branches with slashes need intermediate dirs)
    local worktree_parent
    worktree_parent="$(dirname "$worktree_path")"
    if ! mkdir -p "$worktree_parent" 2>/dev/null; then
        error_log "create_new_worktree: FAILED mkdir $worktree_parent"
        tmux display-message "Failed to create directory: $worktree_parent (check permissions)"
        return 1
    fi

    local error_output
    error_output=$(git worktree add "$worktree_path" -b "$branch" 2>&1)
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        debug_log "create_new_worktree: worktree created at $worktree_path"
        _setup_worktree "$branch" "$worktree_path" "$session_name" "$project_name"
    else
        error_log "create_new_worktree: cwd=$(pwd) branch=$branch path=$worktree_path exit=$exit_code err=$error_output"
        local error_msg
        error_msg=$(_git_error_summary "$error_output")
        if [ -n "$error_msg" ]; then
            tmux display-message "Failed: $error_msg"
        else
            tmux display-message "Failed to create worktree (exit $exit_code)"
        fi
    fi
}

# Show add worktree menu with pagination, optional filter, and optional remote branches
show_add_worktree_menu() {
    require_git_repo || return 1
    debug_log "show_add_worktree_menu called: page=${1:-1} filter='${2:-}' include_remotes=${3:-0}"
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local include_remotes=${3:-0}
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    # Single combined call for count + data (performance optimization)
    local combined_output
    combined_output=$(get_branch_data "$page" "$filter" "$include_remotes")
    local total_pages
    total_pages=$(echo "$combined_output" | head -1)
    local branch_items
    branch_items=$(echo "$combined_output" | tail -n +2)

    debug_log "show_add_worktree_menu: total_pages=$total_pages include_remotes=$include_remotes"

    # Build title with filter and remote indicator
    local title="Add Worktree (Page $page/$total_pages)"
    [ "$include_remotes" = "1" ] && title="$title [+remote]"
    [ -n "$filter" ] && title="$title - Filter: '$filter'"

    tk_menu_reset
    tk_menu_title "$title"

    # New branch option
    tk_menu_item "New" "$KEY_NEW" "command-prompt -p 'New branch name:' 'run-shell '\''$script_path'\'' create_new_worktree %1'"

    # Fetch remote option
    tk_menu_item "Fetch remote" "$KEY_FETCH" "$(tk_menu_cmd "$script_path" fetch_remote_branches) ; $(tk_menu_cmd "$script_path" show_add_worktree_menu 1 "$filter" 1)"

    # Filter option (always present)
    tk_menu_item "Filter" "$KEY_FILTER" "command-prompt -T search -p 'Filter pattern:' 'run-shell '\''$script_path'\'' show_add_worktree_menu 1 '\''%1'\'' $include_remotes'"

    # Clear filter option (only when filter active)
    if [ -n "$filter" ]; then
        tk_menu_item "Clear filter" "$KEY_CLEAR_FILTER" "$(tk_menu_cmd "$script_path" show_add_worktree_menu 1 '' $include_remotes)"
    fi

    # Parse TSV branch items
    if [ -n "$branch_items" ]; then
        while IFS=$'\t' read -r row_type label branch extra; do
            [ -z "$row_type" ] && continue
            case "$row_type" in
                active)
                    tk_menu_item "$label" "" "display-message 'Switching...' ; $(tk_menu_cmd "$script_path" switch_worktree "$branch" "$extra")"
                    ;;
                local)
                    tk_menu_item "$label" "" "display-message 'Creating worktree...' ; $(tk_menu_cmd "$script_path" add_worktree "$branch")"
                    ;;
                remote)
                    tk_menu_item "$label" "" "display-message 'Creating worktree...' ; $(tk_menu_cmd "$script_path" add_worktree "$branch" "$extra")"
                    ;;
            esac
        done <<< "$branch_items"
    else
        debug_log "show_add_worktree_menu: no branches found"
        tk_menu_text "(No branches available)"
    fi

    # Navigation items
    _add_nav_items "$page" "$total_pages" "show_add_worktree_menu" "$filter" "$include_remotes"

    tk_menu_show
}

# Show remove worktree menu with pagination and optional filter
show_remove_worktree_menu() {
    require_git_repo || return 1
    debug_log "show_remove_worktree_menu called: page=${1:-1} filter='${2:-}'"
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    # Single combined call for count + data (performance optimization)
    local combined_output
    combined_output=$(get_removable_worktree_data "$page" "$filter")
    local total_pages
    total_pages=$(echo "$combined_output" | head -1)
    local worktree_items
    worktree_items=$(echo "$combined_output" | tail -n +2)

    debug_log "show_remove_worktree_menu: total_pages=$total_pages"

    # Build title with filter indicator
    local title="Remove Worktree (Page $page/$total_pages)"
    [ -n "$filter" ] && title="$title - Filter: '$filter'"

    tk_menu_reset
    tk_menu_title "$title"

    # Bulk-remove entry point (hidden when count=0)
    local stale_count
    stale_count=$(get_stale_worktree_count "$MAX_AGE_DAYS")
    if [ "$stale_count" -gt 0 ]; then
        tk_menu_item "Remove older than ${MAX_AGE_DAYS}d ($stale_count)" "X" "display-message 'Loading...' ; $(tk_menu_cmd "$script_path" show_bulk_remove_preview_menu "$MAX_AGE_DAYS")"
    fi

    # Filter option (always present)
    tk_menu_item "Filter" "$KEY_FILTER" "command-prompt -T search -p 'Filter pattern:' 'run-shell '\''$script_path'\'' show_remove_worktree_menu 1 '\''%1'\'''"

    # Clear filter option (only when filter active)
    if [ -n "$filter" ]; then
        tk_menu_item "Clear filter" "$KEY_CLEAR_FILTER" "$(tk_menu_cmd "$script_path" show_remove_worktree_menu 1)"
    fi

    # Parse TSV removable items
    if [ -n "$worktree_items" ]; then
        while IFS=$'\t' read -r label full_path branch session_name current_page; do
            [ -z "$label" ] && continue
            tk_menu_item "$label" "" "display-message 'Removing worktree...' ; $(tk_menu_cmd "$script_path" remove_worktree "$full_path" "$branch" "$session_name" "$current_page")"
        done <<< "$worktree_items"
    else
        debug_log "show_remove_worktree_menu: no removable worktrees found"
        tk_menu_text "(No removable worktrees found)"
    fi

    # Navigation items
    _add_nav_items "$page" "$total_pages" "show_remove_worktree_menu" "$filter"

    tk_menu_show
}

# Show preview menu for bulk-remove of worktrees older than threshold_days.
# Layout: [Remove all N] [per-worktree rows] [nav].
show_bulk_remove_preview_menu() {
    require_git_repo || return 1
    local threshold_days="${1:-${MAX_AGE_DAYS:-30}}"
    local page
    page=$(validate_page "${2:-1}")
    local filter
    filter=$(limit_filter "${3:-}")
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    debug_log "show_bulk_remove_preview_menu: threshold=${threshold_days}d page=$page filter='$filter'"

    local combined_output total_pages items count
    combined_output=$(get_stale_worktree_data "$threshold_days" "$page" "$filter")
    total_pages=$(echo "$combined_output" | head -1)
    items=$(echo "$combined_output" | tail -n +2)
    count=$(get_stale_worktree_count "$threshold_days" "$filter")

    local title="Stale Worktrees >${threshold_days}d (Page $page/$total_pages)"
    [ -n "$filter" ] && title="$title - Filter: '$filter'"

    tk_menu_reset
    tk_menu_title "$title"

    # Remove all option
    if [ "$count" -gt 0 ]; then
        tk_menu_item "Remove all $count" "X" "command-prompt -p 'Remove $count worktrees older than ${threshold_days}d? Type yes:' 'run-shell '\''$script_path'\'' bulk_remove_worktrees $threshold_days '\''%1'\'''"
    fi

    # Filter option
    tk_menu_item "Filter" "$KEY_FILTER" "command-prompt -T search -p 'Filter pattern:' 'run-shell '\''$script_path'\'' show_bulk_remove_preview_menu $threshold_days 1 '\''%1'\'''"

    # Clear filter option
    if [ -n "$filter" ]; then
        tk_menu_item "Clear filter" "$KEY_CLEAR_FILTER" "$(tk_menu_cmd "$script_path" show_bulk_remove_preview_menu "$threshold_days" 1)"
    fi

    # Parse TSV stale items
    if [ -n "$items" ] && [ "$count" -gt 0 ]; then
        while IFS=$'\t' read -r label full_path branch session_name current_page; do
            [ -z "$label" ] && continue
            tk_menu_item "$label" "" "display-message 'Removing worktree...' ; $(tk_menu_cmd "$script_path" remove_worktree "$full_path" "$branch" "$session_name" "$current_page")"
        done <<< "$items"
    else
        tk_menu_text "(No stale worktrees found)"
    fi

    # Navigation items
    _add_nav_items "$page" "$total_pages" "show_bulk_remove_preview_menu" "$filter" "$threshold_days"

    tk_menu_show
}

# Bulk-remove all worktrees older than threshold_days. Called from the confirm prompt.
# Second arg is the user's typed confirmation string (must equal "yes" exactly).
bulk_remove_worktrees() {
    require_git_repo || return 1
    local threshold_days="$1"
    local confirm="${2:-}"

    if [ "$confirm" != "yes" ]; then
        tmux display-message "Bulk remove cancelled"
        return 0
    fi

    local now threshold_seconds
    now=$(date +%s)
    threshold_seconds=$(( threshold_days * 86400 ))

    local project_name
    project_name=$(get_project_name)
    _build_stale_context "$project_name" "$now"

    # Collect (worktree_path, branch) rows via the count awk adapted to emit paths.
    # We reuse stale_data.awk schema indirectly by re-parsing porcelain here.
    local removed=0 failed=0
    local wt_path=""
    local branch_name=""
    local head_sha=""
    local current_dir
    current_dir=$(pwd -P 2>/dev/null || pwd)

    # Snapshot the list first so removals don't perturb the iterator.
    local -a _stale_paths=()
    local -a _stale_branches=()
    while IFS= read -r line; do
        case "$line" in
            worktree\ *)
                wt_path="${line#worktree }"
                branch_name=""
                head_sha=""
                ;;
            HEAD\ *)
                head_sha="${line#HEAD }"
                head_sha="${head_sha:0:7}"
                ;;
            branch\ *)
                branch_name="${line#branch refs/heads/}"
                ;;
            detached*)
                branch_name=""
                ;;
            "")
                if [ -n "$wt_path" ] && [ "$wt_path" != "$current_dir" ]; then
                    local bn="${branch_name:-HEAD@${head_sha}}"
                    local ts
                    ts=$(get_recent_timestamp "$project_name" "$bn")
                    local diff=$((now - ts))
                    if [ "$diff" -ge "$threshold_seconds" ]; then
                        _stale_paths+=("$wt_path")
                        _stale_branches+=("$bn")
                    fi
                fi
                wt_path=""
                branch_name=""
                head_sha=""
                ;;
        esac
    done < <(LC_ALL=C git worktree list --porcelain; echo "")

    local total=${#_stale_paths[@]}
    local i
    for ((i = 0; i < total; i++)); do
        local p="${_stale_paths[$i]}"
        local b="${_stale_branches[$i]}"
        local progress=$((i + 1))
        debug_log "bulk_remove_worktrees: removing [$progress/$total] path=$p branch=$b"

        # Progress ping for the user. -d 0 forces immediate redraw so long
        # removals do not leave the status bar stuck on the previous message.
        tmux display-message -d 0 "Deleting worktree $progress/$total: $b..." 2>/dev/null || true

        if [ ! -d "$p" ]; then
            worktree_prune
        else
            if run_with_timeout 10 git worktree remove --force "$p" >/dev/null 2>&1; then
                removed=$((removed + 1))
            else
                failed=$((failed + 1))
                error_log "bulk_remove_worktrees: failed to remove $p"
                continue
            fi
        fi

        local sn
        sn=$(get_session_name "$project_name" "$b")
        tmux kill-session -t "=$sn" 2>/dev/null || tmux kill-session -t "=$b" 2>/dev/null || true

        remove_recent_branch "$project_name" "$b"
    done

    if [ "$failed" -gt 0 ]; then
        tmux display-message "Bulk remove: $removed removed, $failed failed"
    else
        tmux display-message "Bulk remove: $removed worktree(s) removed"
    fi
}

# ==============================================================================
# OPTIONS MENU
# ==============================================================================

# Cycle through a list of values, wrapping around
# Usage: _cycle_value "current" "val1" "val2" "val3"
_cycle_value() {
    local current="$1"
    shift
    local values=("$@")
    local count=${#values[@]}
    local i
    for ((i = 0; i < count; i++)); do
        if [ "${values[$i]}" = "$current" ]; then
            echo "${values[$(( (i + 1) % count ))]}"
            return
        fi
    done
    # Current value not found, return first
    echo "${values[0]}"
}

# Set a tmux option, persist it to state file, and re-show options menu
# Usage: set_option "@worktree-copy-ignored" "on"
set_option() {
    local key="$1"
    local value="$2"
    debug_log "set_option: key=$key value=$value"

    tk_tmux set-option -g "$key" "$value"
    save_option "$key" "$value"
    show_options_menu
}

# Show options menu for runtime configuration
# Each item sets a tmux option and re-displays the menu with updated values
show_options_menu() {
    reload_config
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    # Compute next values for toggles and cycles
    local next_copy_ignored next_debug next_items next_timeout next_fetch_prune next_age next_sort_recent
    next_copy_ignored=$(_cycle_value "$COPY_IGNORED" "off" "on")
    next_debug=$(_cycle_value "$DEBUG" "off" "on")
    next_items=$(_cycle_value "$ITEMS_PER_PAGE" "10" "15" "20" "25")
    next_timeout=$(_cycle_value "$FETCH_TIMEOUT" "15" "30" "60" "120")
    next_fetch_prune=$(_cycle_value "$FETCH_PRUNE" "off" "on")
    next_sort_recent=$(_cycle_value "${SORT_RECENT_DEFAULT:-on}" "off" "on")

    # Parse MAX_AGE_CHOICES into an array for cycling.
    local _age_choices_str="${MAX_AGE_CHOICES:-7,30,90}"
    IFS=',' read -r -a _age_arr <<< "$_age_choices_str"
    # Trim whitespace from each entry.
    local _i
    for _i in "${!_age_arr[@]}"; do
        _age_arr[$_i]="${_age_arr[$_i]// /}"
    done
    if [ "${#_age_arr[@]}" -eq 0 ]; then
        _age_arr=("7" "30" "90")
    fi
    next_age=$(_cycle_value "$MAX_AGE_DAYS" "${_age_arr[@]}")

    local dp
    dp=$(display_path "$WORKTREE_BASE")

    tk_menu_reset
    tk_menu_title "Options"

    tk_menu_item "Copy ignored: $COPY_IGNORED" "" "$(tk_menu_cmd "$script_path" set_option @worktree-copy-ignored "$next_copy_ignored")"
    tk_menu_item "Debug: $DEBUG" "" "$(tk_menu_cmd "$script_path" set_option @worktree-debug "$next_debug")"
    tk_menu_item "Items/page: $ITEMS_PER_PAGE" "" "$(tk_menu_cmd "$script_path" set_option @worktree-items-per-page "$next_items")"
    tk_menu_item "Sort recent: ${SORT_RECENT_DEFAULT:-on}" "" "$(tk_menu_cmd "$script_path" set_option @worktree-sort-recent-default "$next_sort_recent")"
    tk_menu_item "Fetch prune: $FETCH_PRUNE" "" "$(tk_menu_cmd "$script_path" set_option @worktree-fetch-prune "$next_fetch_prune")"
    tk_menu_item "Fetch timeout: ${FETCH_TIMEOUT}s" "" "$(tk_menu_cmd "$script_path" set_option @worktree-fetch-timeout "$next_timeout")"
    tk_menu_item "Stale after: ${MAX_AGE_DAYS}d" "" "$(tk_menu_cmd "$script_path" set_option @worktree-max-age-days "$next_age")"
    tk_menu_item "Path: $dp" "" "command-prompt -I '$WORKTREE_BASE' -p 'Worktree path:' 'run-shell '\''$script_path'\'' set_option @worktree-path %1'"
    tk_menu_item "← Back" "$KEY_BACK" "$(tk_menu_cmd "$script_path" tmux_worktrees_main)"

    tk_menu_show
}

# ==============================================================================
# MAIN MENU
# ==============================================================================

# Main tmux worktrees menu
tmux_worktrees_main() {
    debug_log "tmux_worktrees_main called from cwd=$(pwd)"

    # Check if we're in a git repository (silent return so run-shell shows nothing)
    if ! require_git_repo; then
        return 0
    fi

    debug_log "git check: $(git rev-parse --git-dir 2>&1 || true)"

    # Adopt the calling session into the plugin's naming convention. Sessions
    # opened manually by the user (`tmux` from a folder) get a default name
    # like "windows" or "0"; rename them to <project>-<branch> so they look
    # like sessions the plugin itself created.
    adopt_current_session

    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    tk_menu_reset
    tk_menu_title "Git Worktrees"
    tk_menu_item "List" "$KEY_LIST" "display-message 'Loading worktrees...' ; $(tk_menu_cmd "$script_path" show_worktree_menu)"
    tk_menu_item "Add" "$KEY_ADD" "display-message 'Loading branches...' ; $(tk_menu_cmd "$script_path" show_add_worktree_menu)"
    tk_menu_item "Remove" "$KEY_REMOVE" "display-message 'Loading...' ; $(tk_menu_cmd "$script_path" show_remove_worktree_menu)"
    tk_menu_item "Options" "$KEY_OPTIONS" "$(tk_menu_cmd "$script_path" show_options_menu)"
    tk_menu_item "Quit" "$KEY_QUIT" ""

    tk_menu_show
}

# ==============================================================================
# DIAGNOSTIC COMMANDS
# ==============================================================================

# Display version information
show_version() {
    echo "tmux-worktree version $TMUX_WORKTREE_VERSION"
}

# Health check for troubleshooting
health_check() {
    echo "tmux-worktree Health Check"
    echo "=========================="
    echo "Plugin version: $TMUX_WORKTREE_VERSION"
    echo "tmux version: $(tmux -V 2>/dev/null || echo 'not found')"
    echo "Worktree base: $WORKTREE_BASE"
    echo "Worktree base exists: $([ -d "$WORKTREE_BASE" ] && echo 'yes' || echo 'no')"
    echo "Git available: $(command -v git >/dev/null && echo 'yes' || echo 'no')"
    echo "Timeout available: $(command -v timeout >/dev/null || command -v gtimeout >/dev/null && echo 'yes' || echo 'no (fetch may hang)')"
    echo "Debug mode: $DEBUG"
    echo "In git repo: $(git rev-parse --show-toplevel 2>/dev/null && echo 'yes' || echo 'no')"
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
        echo "Worktrees found: $(git worktree list 2>/dev/null | wc -l | tr -d ' ')"
    fi
}

# ==============================================================================
# SCRIPT EXECUTION
# ==============================================================================

# Main entry point
main() {
    # Resolve pane's actual working directory (run-shell uses session CWD, not pane CWD)
    PANE_CWD=$(tmux display-message -p '#{pane_current_path}' 2>/dev/null)
    debug_log "main: command=${1:-tmux_worktrees_main} PANE_CWD=$PANE_CWD cwd=$(pwd)"
    if [ -n "$PANE_CWD" ] && [ -d "$PANE_CWD" ]; then
        cd "$PANE_CWD" || true
    fi

    case "${1:-tmux_worktrees_main}" in
        "tmux_worktrees_main"|"") tmux_worktrees_main ;;
        "show_worktree_menu") show_worktree_menu "$2" "$3" "$4" ;;
        "show_add_worktree_menu") show_add_worktree_menu "$2" "$3" "$4" ;;
        "show_remove_worktree_menu") show_remove_worktree_menu "$2" "$3" ;;
        "remove_worktree") remove_worktree "$2" "$3" "$4" "$5" "$6" ;;
        "add_worktree") add_worktree "$2" "$3" ;;
        "switch_worktree") switch_worktree "$2" "$3" ;;
        "create_new_worktree") create_new_worktree "$2" ;;
        "adopt_session_hook") adopt_session_hook "$2" "$3" ;;
        "fetch_remote_branches") fetch_remote_branches ;;
        "show_options_menu") show_options_menu ;;
        "show_bulk_remove_preview_menu") show_bulk_remove_preview_menu "$2" "$3" "$4" ;;
        "bulk_remove_worktrees") bulk_remove_worktrees "$2" "$3" ;;
        "set_option") set_option "$2" "$3" ;;
        "version") show_version ;;
        "health_check") health_check ;;
        *) echo "Unknown command: $1" ;;
    esac
}

# Execute main function if script is run directly (not sourced)
case "$0" in
    *worktree_manager.sh) main "$@" ;;
esac
