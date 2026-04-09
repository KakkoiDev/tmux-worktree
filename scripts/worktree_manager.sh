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
        debug_log "Fetch failed (exit $exit_code): $(cat "$error_file" 2>/dev/null)"

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
    echo "$name" | tr -cd 'a-zA-Z0-9_.-'
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
            debug_log "remove_worktree: FAILED to remove worktree: $error_output"
            local error_msg
            error_msg=$(echo "$error_output" | head -1 | cut -c1-60)
            if [ -n "$error_msg" ]; then
                tmux display-message "Remove failed: $error_msg"
            else
                tmux display-message "Remove failed (exit $exit_code)"
            fi
        fi
    fi

    # Kill the tmux session if it exists (try both naming patterns)
    if tmux kill-session -t "$session_name" 2>/dev/null; then
        debug_log "remove_worktree: session killed: $session_name"
    elif tmux kill-session -t "$branch_name" 2>/dev/null; then
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
            -f "$SCRIPT_DIR/awk/worktree_data.awk"
    else
        LC_ALL=C git worktree list --porcelain | LC_ALL=C awk \
            -v project="$project_name" \
            -v filter="$regex_filter" \
            -v items_per_page="$ITEMS_PER_PAGE" \
            -v start="$start_line" \
            -v end="$end_line" \
            -v script_path="$script_path" \
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

    # Get branches that already have worktrees (to filter them out)
    local existing_worktrees
    existing_worktrees=$(git worktree list --porcelain 2>/dev/null | grep '^branch refs/heads/' | sed 's|^branch refs/heads/||' | tr '\n' '|' | sed 's/|$//')

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

# Generate navigation options for paginated menus
generate_nav_options() {
    local page=$1
    local total_pages=$2
    local menu_function=$3
    local filter=${4:-}
    local extra_args=${5:-}
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    local nav_options=""

    # Build args string (filter + extra_args)
    local args_suffix=""
    if [ -n "$filter" ] || [ -n "$extra_args" ]; then
        args_suffix="'$filter' $extra_args"
    fi

    # Previous page navigation (preserve filter and extra args)
    if [ "$page" -gt 1 ]; then
        if [ -n "$args_suffix" ]; then
            nav_options="\"◀ Previous\" \"$KEY_PREV\" \"display-message \\\"Loading...\\\" ; run-shell \\\"'$script_path' $menu_function $((page - 1)) $args_suffix\\\"\" "
        else
            nav_options="\"◀ Previous\" \"$KEY_PREV\" \"display-message \\\"Loading...\\\" ; run-shell \\\"'$script_path' $menu_function $((page - 1))\\\"\" "
        fi
    fi

    # Next page navigation (preserve filter and extra args)
    if [ "$page" -lt "$total_pages" ]; then
        if [ -n "$args_suffix" ]; then
            nav_options="${nav_options}\"Next ▶\" \"$KEY_NEXT\" \"display-message \\\"Loading...\\\" ; run-shell \\\"'$script_path' $menu_function $((page + 1)) $args_suffix\\\"\" "
        else
            nav_options="${nav_options}\"Next ▶\" \"$KEY_NEXT\" \"display-message \\\"Loading...\\\" ; run-shell \\\"'$script_path' $menu_function $((page + 1))\\\"\" "
        fi
    fi

    # Back to main menu
    nav_options="${nav_options}\"← Back\" \"$KEY_BACK\" \"display-message \\\"Loading...\\\" ; run-shell \\\"'$script_path' tmux_worktrees_main\\\"\""

    echo "$nav_options"
}

# ==============================================================================
# MENU DISPLAY FUNCTIONS
# ==============================================================================

# Generic tmux menu display function
display_menu() {
    local title="$1"
    local options="$2"
    eval "tmux display-menu -T '$title' $options"
}

# Show worktree list menu with pagination, optional filter, and optional recent sort
show_worktree_menu() {
    require_git_repo || return 1
    debug_log "show_worktree_menu called: page=${1:-1} filter='${2:-}' sort_recent=${3:-0}"
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local sort_recent=${3:-0}
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    # Single combined call for count + data (performance optimization)
    local combined_output
    combined_output=$(get_worktree_data "$page" "$filter" "$sort_recent")
    local total_pages
    total_pages=$(echo "$combined_output" | head -1)
    local worktree_items
    worktree_items=$(echo "$combined_output" | tail -n +2)

    local nav_options
    nav_options=$(generate_nav_options "$page" "$total_pages" "show_worktree_menu" "$filter" "$sort_recent")

    debug_log "show_worktree_menu: total_pages=$total_pages sort_recent=$sort_recent items_count=$(echo "$worktree_items" | grep -c '\"' || echo 0)"

    # Build title with state indicators
    local title="Worktrees (Page $page/$total_pages)"
    [ "$sort_recent" = "1" ] && title="$title [Recent]"
    [ -n "$filter" ] && title="$title - Filter: '$filter'"

    # Recent sort toggle
    local recent_option=""
    if [ "$sort_recent" = "1" ]; then
        recent_option="\"Default\" \"r\" \"run-shell \\\"'$script_path' show_worktree_menu 1 '$filter' 0\\\"\" "
    else
        recent_option="\"Recent\" \"r\" \"run-shell \\\"'$script_path' show_worktree_menu 1 '$filter' 1\\\"\" "
    fi

    # Filter option (preserves sort_recent state)
    local filter_option="\"Filter\" \"$KEY_FILTER\" \"command-prompt -T search -p 'Filter pattern:' 'run-shell \\\"'$script_path' show_worktree_menu 1 '\\''%1'\\'' $sort_recent\\\"'\""

    # Clear filter option (only when filter active, preserves sort_recent)
    local clear_option=""
    if [ -n "$filter" ]; then
        clear_option="\"Clear filter\" \"$KEY_CLEAR_FILTER\" \"run-shell \\\"'$script_path' show_worktree_menu 1 '' $sort_recent\\\"\""
    fi

    if [ -n "$worktree_items" ]; then
        local all_options="$recent_option$filter_option $clear_option $worktree_items $nav_options"
    else
        debug_log "show_worktree_menu: no worktrees found"
        local all_options="$recent_option$filter_option $clear_option \"(No worktrees found)\" \"\" \"\" $nav_options"
    fi

    display_menu "$title" "$all_options"
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

    # Record to recent log
    record_recent_branch "$project_name" "$branch"

    # Copy ignored files if enabled
    if [ "$COPY_IGNORED" = "on" ]; then
        copy_ignored_files "$worktree_path"
    fi

    if tmux new-session -d -c "$worktree_path" -s "$session_name" \
           -e "TMUX_WORKTREE=1" \
           -e "TMUX_WORKTREE_PROJECT=$project_name" \
           -e "TMUX_WORKTREE_BRANCH=$branch" \
           -e "TMUX_WORKTREE_PATH=$worktree_path" && \
       tmux switch-client -t "$session_name"; then
        debug_log "_setup_worktree: SUCCESS session=$session_name"
        tmux display-message "Created worktree and session: $session_name"
    else
        debug_log "_setup_worktree: worktree OK but session FAILED"
        tmux display-message "Worktree created but session failed - try 'tmux new -s $session_name'"
    fi
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

# Switch to an existing worktree session (or create one) and record to recent log
# Usage: switch_worktree "branch" "full_path"
switch_worktree() {
    local branch="$1"
    local full_path="$2"
    local project_name
    project_name=$(get_project_name)
    _worktree_vars "$branch" "$project_name"
    local session_name="$_WT_SESSION"

    # Record to recent log
    record_recent_branch "$project_name" "$branch"

    # Switch to existing session or create a new one
    if tmux has-session -t "$session_name" 2>/dev/null; then
        tmux switch-client -t "$session_name"
    else
        tmux new-session -d -c "$full_path" -s "$session_name" \
            -e "TMUX_WORKTREE=1" \
            -e "TMUX_WORKTREE_PROJECT=$project_name" \
            -e "TMUX_WORKTREE_BRANCH=$branch" \
            -e "TMUX_WORKTREE_PATH=$full_path" && \
        tmux switch-client -t "$session_name"
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
        debug_log "add_worktree: FAILED to create $worktree_parent"
        tmux display-message "Failed to create directory: $worktree_parent (check permissions)"
        return 1
    fi

    local error_output
    if [ -n "$remote_ref" ]; then
        # Remote branch: create tracking local branch
        error_output=$(git worktree add -b "$branch" "$worktree_path" "$remote_ref" 2>&1)
    else
        # Local branch: check out existing
        error_output=$(git worktree add "$worktree_path" "$branch" 2>&1)
    fi
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        debug_log "add_worktree: worktree created at $worktree_path"
        _setup_worktree "$branch" "$worktree_path" "$session_name" "$project_name"
    else
        debug_log "add_worktree: FAILED git worktree add: $error_output"
        local error_msg
        error_msg=$(echo "$error_output" | head -1 | cut -c1-60)
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
        debug_log "create_new_worktree: FAILED to create $worktree_parent"
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
        debug_log "create_new_worktree: FAILED git worktree add: $error_output"
        local error_msg
        error_msg=$(echo "$error_output" | head -1 | cut -c1-60)
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

    local nav_options
    nav_options=$(generate_nav_options "$page" "$total_pages" "show_add_worktree_menu" "$filter" "$include_remotes")

    debug_log "show_add_worktree_menu: total_pages=$total_pages include_remotes=$include_remotes"

    # Build title with filter and remote indicator
    local title="Add Worktree (Page $page/$total_pages)"
    [ "$include_remotes" = "1" ] && title="$title [+remote]"
    [ -n "$filter" ] && title="$title - Filter: '$filter'"

    # New branch option
    local new_option="\"New\" \"$KEY_NEW\" \"command-prompt -p 'New branch name:' 'run-shell \\\"'$script_path' create_new_worktree %1\\\"'\""

    # Fetch remote option - fetches and refreshes menu with remotes included
    local fetch_option="\"Fetch remote\" \"$KEY_FETCH\" \"run-shell \\\"'$script_path' fetch_remote_branches; '$script_path' show_add_worktree_menu 1 '$filter' 1\\\"\""

    # Filter option (always present)
    local filter_option="\"Filter\" \"$KEY_FILTER\" \"command-prompt -T search -p 'Filter pattern:' 'run-shell \\\"'$script_path' show_add_worktree_menu 1 '\\''%1'\\'' $include_remotes\\\"'\""

    # Clear filter option (only when filter active)
    local clear_option=""
    if [ -n "$filter" ]; then
        clear_option="\"Clear filter\" \"$KEY_CLEAR_FILTER\" \"run-shell \\\"'$script_path' show_add_worktree_menu 1 '' $include_remotes\\\"\""
    fi

    if [ -n "$branch_items" ]; then
        local all_options="$new_option $fetch_option $filter_option $clear_option $branch_items $nav_options"
    else
        debug_log "show_add_worktree_menu: no branches found"
        local all_options="$new_option $fetch_option $filter_option $clear_option \"(No branches available)\" \"\" \"\" $nav_options"
    fi

    display_menu "$title" "$all_options"
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

    local nav_options
    nav_options=$(generate_nav_options "$page" "$total_pages" "show_remove_worktree_menu" "$filter")

    debug_log "show_remove_worktree_menu: total_pages=$total_pages"

    # Build title with filter indicator
    local title="Remove Worktree (Page $page/$total_pages)"
    [ -n "$filter" ] && title="$title - Filter: '$filter'"

    # Filter option (always present)
    local filter_option="\"Filter\" \"$KEY_FILTER\" \"command-prompt -T search -p 'Filter pattern:' 'run-shell \\\"'$script_path' show_remove_worktree_menu 1 '\\''%1'\\''\\\"'\""

    # Clear filter option (only when filter active)
    local clear_option=""
    if [ -n "$filter" ]; then
        clear_option="\"Clear filter\" \"$KEY_CLEAR_FILTER\" \"run-shell \\\"'$script_path' show_remove_worktree_menu 1\\\"\""
    fi

    if [ -n "$worktree_items" ]; then
        local all_options="$filter_option $clear_option $worktree_items $nav_options"
    else
        debug_log "show_remove_worktree_menu: no removable worktrees found"
        local all_options="$filter_option $clear_option \"(No removable worktrees found)\" \"\" \"\" $nav_options"
    fi

    display_menu "$title" "$all_options"
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

    if [ -n "$TMUX_SOCKET" ]; then
        tmux -L "$TMUX_SOCKET" set-option -g "$key" "$value"
    else
        tmux set-option -g "$key" "$value"
    fi
    save_option "$key" "$value"
    show_options_menu
}

# Show options menu for runtime configuration
# Each item sets a tmux option and re-displays the menu with updated values
show_options_menu() {
    reload_config
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    # Compute next values for toggles and cycles
    local next_copy_ignored next_debug next_items next_timeout next_fetch_prune
    next_copy_ignored=$(_cycle_value "$COPY_IGNORED" "off" "on")
    next_debug=$(_cycle_value "$DEBUG" "off" "on")
    next_items=$(_cycle_value "$ITEMS_PER_PAGE" "10" "15" "20" "25")
    next_timeout=$(_cycle_value "$FETCH_TIMEOUT" "15" "30" "60" "120")
    next_fetch_prune=$(_cycle_value "$FETCH_PRUNE" "off" "on")

    local dp
    dp=$(display_path "$WORKTREE_BASE")

    local options=""
    options="\"Copy ignored: $COPY_IGNORED\" \"\" \"run-shell \\\"'$script_path' set_option @worktree-copy-ignored $next_copy_ignored\\\"\" "
    options="$options\"Debug: $DEBUG\" \"\" \"run-shell \\\"'$script_path' set_option @worktree-debug $next_debug\\\"\" "
    options="$options\"Items/page: $ITEMS_PER_PAGE\" \"\" \"run-shell \\\"'$script_path' set_option @worktree-items-per-page $next_items\\\"\" "
    options="$options\"Fetch prune: $FETCH_PRUNE\" \"\" \"run-shell \\\"'$script_path' set_option @worktree-fetch-prune $next_fetch_prune\\\"\" "
    options="$options\"Fetch timeout: ${FETCH_TIMEOUT}s\" \"\" \"run-shell \\\"'$script_path' set_option @worktree-fetch-timeout $next_timeout\\\"\" "
    options="$options\"Path: $dp\" \"\" \"command-prompt -I '$WORKTREE_BASE' -p 'Worktree path:' 'run-shell \\\"'\\'''$script_path' set_option @worktree-path %1'\\''\\\"'\" "
    options="$options\"← Back\" \"$KEY_BACK\" \"run-shell \\\"'$script_path' tmux_worktrees_main\\\"\""

    display_menu "Options" "$options"
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

    local script_path="$SCRIPT_DIR/worktree_manager.sh"
    local options='"List" "'"$KEY_LIST"'" "display-message \"Loading worktrees...\" ; run-shell \"'"'"$script_path"'"' show_worktree_menu\"" \
    "Add" "'"$KEY_ADD"'" "display-message \"Loading branches...\" ; run-shell \"'"'"$script_path"'"' show_add_worktree_menu\"" \
    "Remove" "'"$KEY_REMOVE"'" "display-message \"Loading...\" ; run-shell \"'"'"$script_path"'"' show_remove_worktree_menu\"" \
    "Options" "'"$KEY_OPTIONS"'" "run-shell \"'"'"$script_path"'"' show_options_menu\"" \
    "Quit" "'"$KEY_QUIT"'" ""'

    display_menu "Git Worktrees" "$options"
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
        "fetch_remote_branches") fetch_remote_branches ;;
        "show_options_menu") show_options_menu ;;
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
