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
        display_menu "Not a git repo" '"Quit" "q" ""'
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

    # Run git fetch with timeout, capture stderr
    if run_with_timeout "$timeout_seconds" git fetch --all --prune 2>"$error_file"; then
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
    local sanitized_filter
    sanitized_filter=$(sanitize_filter "$filter")
    local regex_filter
    regex_filter=$(convert_glob_to_regex "$sanitized_filter")
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))

    local project_name
    project_name=$(get_project_name)

    # Auto-prune stale worktrees before listing
    if [ "$(count_stale_worktrees)" -gt 0 ]; then
        worktree_prune
        debug_log "get_worktree_data: auto-pruned stale worktrees"
    fi

    # Log worktree paths to debug file
    if [ "$DEBUG" = "on" ]; then
        debug_log "get_worktree_data: listing worktrees for page $page"
    fi

    LC_ALL=C git worktree list --porcelain | LC_ALL=C awk \
        -v project="$project_name" \
        -v filter="$regex_filter" \
        -v items_per_page="$ITEMS_PER_PAGE" \
        -v start="$start_line" \
        -v end="$end_line" \
        -f "$SCRIPT_DIR/awk/worktree_data.awk"
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
        -v base="$WORKTREE_BASE" \
        -v project="$project_name" \
        -v filter="$regex_filter" \
        -v items_per_page="$ITEMS_PER_PAGE" \
        -v start="$start_line" \
        -v end="$end_line" \
        -v existing_wt="$existing_worktrees" \
        -v pane_cwd="$(pwd)" \
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

# Show worktree list menu with pagination and optional filter
show_worktree_menu() {
    require_git_repo || return 1
    debug_log "show_worktree_menu called: page=${1:-1} filter='${2:-}'"
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    # Single combined call for count + data (performance optimization)
    local combined_output
    combined_output=$(get_worktree_data "$page" "$filter")
    local total_pages
    total_pages=$(echo "$combined_output" | head -1)
    local worktree_items
    worktree_items=$(echo "$combined_output" | tail -n +2)

    local nav_options
    nav_options=$(generate_nav_options "$page" "$total_pages" "show_worktree_menu" "$filter")

    debug_log "show_worktree_menu: total_pages=$total_pages items_count=$(echo "$worktree_items" | grep -c '\"' || echo 0)"

    # Build title with filter indicator
    local title="Worktrees (Page $page/$total_pages)"
    [ -n "$filter" ] && title="$title - Filter: '$filter'"

    # Filter option (always present)
    local filter_option="\"Filter\" \"$KEY_FILTER\" \"command-prompt -T search -p 'Filter pattern:' 'run-shell \\\"'$script_path' show_worktree_menu 1 '\\''%1'\\''\\\"'\""

    # Clear filter option (only when filter active)
    local clear_option=""
    if [ -n "$filter" ]; then
        clear_option="\"Clear filter\" \"$KEY_CLEAR_FILTER\" \"run-shell \\\"'$script_path' show_worktree_menu 1\\\"\""
    fi

    if [ -n "$worktree_items" ]; then
        local all_options="$filter_option $clear_option $worktree_items $nav_options"
    else
        debug_log "show_worktree_menu: no worktrees found"
        local all_options="$filter_option $clear_option \"(No worktrees found)\" \"\" \"\" $nav_options"
    fi

    display_menu "$title" "$all_options"
}

# Create new worktree helper function
create_new_worktree() {
    require_git_repo || return 1
    local branch="$1"
    debug_log "create_new_worktree called: branch='$branch'"
    local project_name
    project_name=$(get_project_name)
    local session_name="${project_name}-${branch//\//_}"
    session_name="${session_name//./_}"
    session_name="${session_name//:/_}"
    local worktree_path="$WORKTREE_BASE/$project_name/$branch"
    debug_log "create_new_worktree: project=$project_name session=$session_name path=$worktree_path"

    # Ensure project directory exists
    if ! mkdir -p "$WORKTREE_BASE/$project_name" 2>/dev/null; then
        debug_log "create_new_worktree: FAILED to create $WORKTREE_BASE/$project_name"
        tmux display-message "Failed to create directory: $WORKTREE_BASE/$project_name (check permissions)"
        return 1
    fi

    local error_output
    error_output=$(git worktree add "$worktree_path" -b "$branch" 2>&1)
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        debug_log "create_new_worktree: worktree created at $worktree_path"
        if tmux new-session -d -c "$worktree_path" -s "$session_name" \
               -e "TMUX_WORKTREE=1" \
               -e "TMUX_WORKTREE_PROJECT=$project_name" \
               -e "TMUX_WORKTREE_BRANCH=$branch" \
               -e "TMUX_WORKTREE_PATH=$worktree_path" && \
           tmux switch-client -t "$session_name"; then
            debug_log "create_new_worktree: SUCCESS session=$session_name"
            tmux display-message "Created worktree and session: $session_name"
        else
            debug_log "create_new_worktree: worktree OK but session FAILED"
            tmux display-message "Worktree created but session failed - try 'tmux new -s $session_name'"
        fi
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
    local fetch_option="\"Fetch remote\" \"$KEY_FETCH\" \"run-shell \\\"'$script_path' fetch_remote_branches && '$script_path' show_add_worktree_menu 1 '$filter' 1\\\"\""

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
        "show_worktree_menu") show_worktree_menu "$2" "$3" ;;
        "show_add_worktree_menu") show_add_worktree_menu "$2" "$3" "$4" ;;
        "show_remove_worktree_menu") show_remove_worktree_menu "$2" "$3" ;;
        "remove_worktree") remove_worktree "$2" "$3" "$4" "$5" "$6" ;;
        "create_new_worktree") create_new_worktree "$2" ;;
        "fetch_remote_branches") fetch_remote_branches ;;
        "version") show_version ;;
        "health_check") health_check ;;
        *) echo "Unknown command: $1" ;;
    esac
}

# Execute main function if script is run directly (not sourced)
case "$0" in
    *worktree_manager.sh) main "$@" ;;
esac
