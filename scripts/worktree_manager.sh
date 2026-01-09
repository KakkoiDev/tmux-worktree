#!/usr/bin/env bash
# ==============================================================================
# TMUX WORKTREES - Core Worktree Manager
# ==============================================================================
# Migrated from standalone tmux_worktree.sh to TPM plugin architecture
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

# Source helpers and load config
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/filter.sh"
load_config

# ==============================================================================
# REMOTE BRANCH FETCHING
# ==============================================================================

# Fetch remote branches with timeout protection
fetch_remote_branches() {
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
    local worktree_path="$1"
    local branch_name="$2"
    local session_name="$3"
    local current_page="$4"

    debug_log "remove_worktree called: path='$worktree_path' branch='$branch_name' session='$session_name'"

    # Remove the worktree with timeout protection
    # Note: Branch is NOT deleted - user can do that manually if needed
    if run_with_timeout 10 git worktree remove --force "$worktree_path" > /dev/null 2>&1; then
        debug_log "remove_worktree: worktree removed OK"
        tmux display-message "Worktree removed (branch kept): $branch_name"
    else
        debug_log "remove_worktree: FAILED to remove worktree"
        tmux display-message "Worktree removal failed - try 'git worktree remove $worktree_path' manually"
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

# Get git worktree data with pagination, optional filter, AND page count in single call
# Output format: first line = total_pages, remaining lines = menu items (space-separated on one line)
get_worktree_data_with_count() {
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local sanitized_filter
    sanitized_filter=$(sanitize_filter "$filter")
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))

    local project_name
    project_name=$(get_project_name)

    # Log worktree paths to debug file
    if [ "$DEBUG" = "on" ]; then
        debug_log "get_worktree_data_with_count: listing worktrees for page $page"
    fi

    LC_ALL=C git worktree list --porcelain | LC_ALL=C awk -v project="$project_name" -v filter="$sanitized_filter" -v items_per_page="$ITEMS_PER_PAGE" -v start="$start_line" -v end="$end_line" '
        BEGIN {
            # Convert wildcard to regex
            if (filter != "") {
                gsub(/\./, "\\.", filter)  # Escape literal dots first
                gsub(/\*/, ".*", filter)   # Then convert wildcards
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
            count = 0
            line_num = 0
        }
        /^worktree/ {path=$2;full_path=$2;head_sha=""}
        /^HEAD/ {head_sha=substr($2,1,7)}  # Capture short SHA for detached HEAD
        /^branch/ {
            branch=$2
            sub("refs/heads/", "", branch)
            # Sanitize branch name - remove newlines and shell metacharacters
            gsub(/[\r\n]/, "", branch)
            gsub(/[^a-zA-Z0-9._\/-]/, "", branch)

            # Apply filter (case-insensitive)
            if (filter == "" || tolower(branch) ~ tolower(filter)) {
                count++
                line_num++
                if (line_num >= start && line_num <= end) {
                    session_name=project "-" branch
                    gsub("/", "-", session_name)
                    items[line_num] = "\"" branch "\" \"\" \"run-shell \\\"tmux has-session -t " session_name " 2>/dev/null && tmux switch-client -t " session_name " || (tmux new-session -d -c \\\\\\\"" full_path "\\\\\\\" -s " session_name " && tmux switch-client -t " session_name ")\\\"\""
                }
            }
        }
        /^detached/ {
            # Handle detached HEAD worktrees
            branch="HEAD@" head_sha

            # Apply filter (case-insensitive)
            if (filter == "" || tolower(branch) ~ tolower(filter)) {
                count++
                line_num++
                if (line_num >= start && line_num <= end) {
                    session_name=project "-detached-" head_sha
                    items[line_num] = "\"" branch "\" \"\" \"run-shell \\\"tmux has-session -t " session_name " 2>/dev/null && tmux switch-client -t " session_name " || (tmux new-session -d -c \\\\\\\"" full_path "\\\\\\\" -s " session_name " && tmux switch-client -t " session_name ")\\\"\""
                }
            }
        }
        END {
            # Calculate total pages
            total_pages = int((count + items_per_page - 1) / items_per_page)
            if (total_pages < 1) total_pages = 1
            print total_pages

            # Output menu items
            for (i = start; i <= end && i <= line_num; i++) {
                if (items[i] != "") printf "%s ", items[i]
            }
            if (line_num > 0) print ""
        }
    '
}

# Backward-compatible wrapper: returns just menu items (no count)
get_worktree_data() {
    local output
    output=$(get_worktree_data_with_count "$@")
    echo "$output" | tail -n +2
}

# Get git branch data with pagination, optional filter, remote branches, AND page count in single call
# Output format: first line = total_pages, remaining lines = menu items (space-separated on one line)
get_branch_data_with_count() {
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local include_remotes=${3:-0}
    local sanitized_filter
    sanitized_filter=$(sanitize_filter "$filter")
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

    eval "$branch_cmd" | awk -v base="$WORKTREE_BASE" -v project="$project_name" -v filter="$sanitized_filter" -v items_per_page="$ITEMS_PER_PAGE" -v start="$start_line" -v end="$end_line" '
        BEGIN {
            if (filter != "") {
                gsub(/\./, "\\.", filter)  # Escape literal dots first
                gsub(/\*/, ".*", filter)   # Then convert wildcards
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
            count = 0
            line_num = 0
        }
        {
            branch = $0
            # Sanitize branch name - remove newlines and shell metacharacters
            gsub(/[\r\n]/, "", branch)
            gsub(/[^a-zA-Z0-9._\/-]/, "", branch)

            # Determine if this is a remote branch
            is_remote = (index(branch, "/") > 0 && index(branch, "origin/") == 1)

            # For display and matching, use the branch name
            display_branch = branch
            local_branch = branch

            # For remote branches, extract local name for worktree creation
            if (is_remote) {
                # Strip remote prefix for local branch name (origin/feat -> feat)
                local_branch = substr(branch, index(branch, "/") + 1)
            }

            # Apply filter (case-insensitive) - match against the branch name portion
            match_name = is_remote ? local_branch : branch
            if (filter == "" || tolower(match_name) ~ tolower(filter)) {
                count++
                line_num++
                if (line_num >= start && line_num <= end) {
                    worktree_path = base "/" project "/" local_branch
                    session_name = project "-" local_branch
                    gsub("/", "-", session_name)

                    if (is_remote) {
                        # Remote branch: create tracking branch (paths quoted for spaces)
                        items[line_num] = "\"[remote] " display_branch "\" \"\" \"run-shell \\\"git worktree add -b " local_branch " \\\\\\\"" worktree_path "\\\\\\\" " branch " > /dev/null && tmux new-session -d -c \\\\\\\"" worktree_path "\\\\\\\" -s " session_name " && tmux switch-client -t " session_name "\\\"\""
                    } else {
                        # Local branch (paths quoted for spaces)
                        items[line_num] = "\"" display_branch "\" \"\" \"run-shell \\\"git worktree add \\\\\\\"" worktree_path "\\\\\\\" " branch " > /dev/null && tmux new-session -d -c \\\\\\\"" worktree_path "\\\\\\\" -s " session_name " && tmux switch-client -t " session_name "\\\"\""
                    }
                }
            }
        }
        END {
            # Calculate total pages
            total_pages = int((count + items_per_page - 1) / items_per_page)
            if (total_pages < 1) total_pages = 1
            print total_pages

            # Output menu items
            for (i = start; i <= end && i <= line_num; i++) {
                if (items[i] != "") printf "%s ", items[i]
            }
            if (line_num > 0) print ""
        }
    '
}

# Backward-compatible wrapper: returns just menu items (no count)
get_branch_data() {
    local output
    output=$(get_branch_data_with_count "$@")
    echo "$output" | tail -n +2
}

# Get removable worktree data with pagination, optional filter, AND page count in single call
# Output format: first line = total_pages, remaining lines = menu items (space-separated on one line)
get_removable_worktree_data_with_count() {
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local sanitized_filter
    sanitized_filter=$(sanitize_filter "$filter")
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))

    local project_name
    project_name=$(get_project_name)
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    # Log worktree paths to debug file
    if [ "$DEBUG" = "on" ]; then
        debug_log "get_removable_worktree_data_with_count: listing worktrees for page $page"
    fi

    LC_ALL=C git worktree list --porcelain | LC_ALL=C awk -v current_dir="$(pwd)" -v script_path="$script_path" -v current_page="$page" -v project="$project_name" -v filter="$sanitized_filter" -v items_per_page="$ITEMS_PER_PAGE" -v start="$start_line" -v end="$end_line" '
        BEGIN {
            if (filter != "") {
                gsub(/\./, "\\.", filter)  # Escape literal dots first
                gsub(/\*/, ".*", filter)   # Then convert wildcards
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
            count = 0
            line_num = 0
        }
        /^worktree/ {
            path = $2
            full_path = path
            head_sha = ""
        }
        /^HEAD/ { head_sha = substr($2,1,7) }
        /^branch/ {
            if (path != current_dir) {
                branch = $2
                sub("refs/heads/", "", branch)
                # Sanitize branch name - remove shell metacharacters
                gsub(/[^a-zA-Z0-9._\/-]/, "", branch)

                # Apply filter (case-insensitive)
                if (filter == "" || tolower(branch) ~ tolower(filter)) {
                    count++
                    line_num++
                    if (line_num >= start && line_num <= end) {
                        session_name = project "-" branch
                        gsub("/", "-", session_name)

                        # Remove worktree only (branch is always kept)
                        items[line_num] = "\"" branch "\" \"\" \"display-message \\\"Removing worktree...\\\" ; run-shell \\\". " script_path " && remove_worktree \\\\\\\"" full_path "\\\\\\\" \\\\\\\"" branch "\\\\\\\" \\\\\\\"" session_name "\\\\\\\" " current_page "\\\"\""
                    }
                }
            }
        }
        /^detached/ {
            # Handle detached HEAD worktrees
            if (path != current_dir) {
                branch = "HEAD@" head_sha

                # Apply filter (case-insensitive)
                if (filter == "" || tolower(branch) ~ tolower(filter)) {
                    count++
                    line_num++
                    if (line_num >= start && line_num <= end) {
                        session_name = project "-detached-" head_sha

                        # Detached HEAD worktrees - remove worktree only
                        items[line_num] = "\"" branch "\" \"\" \"display-message \\\"Removing worktree...\\\" ; run-shell \\\". " script_path " && remove_worktree \\\\\\\"" full_path "\\\\\\\" \\\\\\\"\\\\\\\" \\\\\\\"" session_name "\\\\\\\" " current_page "\\\"\""
                    }
                }
            }
        }
        END {
            # Calculate total pages
            total_pages = int((count + items_per_page - 1) / items_per_page)
            if (total_pages < 1) total_pages = 1
            print total_pages

            # Output menu items
            for (i = start; i <= end && i <= line_num; i++) {
                if (items[i] != "") printf "%s ", items[i]
            }
            if (line_num > 0) print ""
        }
    '
}

# Backward-compatible wrapper: returns just menu items (no count)
get_removable_worktree_data() {
    local output
    output=$(get_removable_worktree_data_with_count "$@")
    echo "$output" | tail -n +2
}

# ==============================================================================
# PAGE CALCULATION FUNCTIONS
# ==============================================================================

get_worktree_page_count() {
    local filter=${1:-}
    local sanitized_filter
    sanitized_filter=$(sanitize_filter "$filter")
    local total
    total=$(LC_ALL=C git worktree list --porcelain | LC_ALL=C awk -v filter="$sanitized_filter" '
        BEGIN {
            if (filter != "") {
                gsub(/\./, "\\.", filter)  # Escape literal dots first
                gsub(/\*/, ".*", filter)   # Then convert wildcards
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
        }
        /^worktree/ { path = $2 }
        /^HEAD/ { head_sha = substr($2,1,7) }
        /^branch/ {
            branch = $2
            sub("refs/heads/", "", branch)
            if (filter == "" || tolower(branch) ~ tolower(filter)) count++
        }
        /^detached/ {
            branch = "HEAD@" head_sha
            if (filter == "" || tolower(branch) ~ tolower(filter)) count++
        }
        END { print count+0 }
    ')
    echo $(( (total + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))
}

get_branch_page_count() {
    local filter=${1:-}
    local include_remotes=${2:-0}
    local sanitized_filter
    sanitized_filter=$(sanitize_filter "$filter")

    # Build branch command based on include_remotes
    local branch_cmd="git branch --format='%(refname:short)'"
    if [ "$include_remotes" = "1" ]; then
        branch_cmd="{ git branch --format='%(refname:short)'; git branch -r --format='%(refname:short)' | grep -v 'HEAD'; }"
    fi

    local total
    total=$(eval "$branch_cmd" | awk -v filter="$sanitized_filter" '
        BEGIN {
            if (filter != "") {
                gsub(/\./, "\\.", filter)  # Escape literal dots first
                gsub(/\*/, ".*", filter)   # Then convert wildcards
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
        }
        {
            branch = $0
            # For remote branches, match against local part
            if (index(branch, "origin/") == 1) {
                match_name = substr(branch, index(branch, "/") + 1)
            } else {
                match_name = branch
            }
            if (filter == "" || tolower(match_name) ~ tolower(filter)) count++
        }
        END { print count+0 }
    ')
    echo $(( (total + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))
}

get_removable_worktree_page_count() {
    local filter=${1:-}
    local sanitized_filter
    sanitized_filter=$(sanitize_filter "$filter")
    local total
    total=$(LC_ALL=C git worktree list --porcelain | LC_ALL=C awk -v current_dir="$(pwd)" -v filter="$sanitized_filter" '
        BEGIN {
            if (filter != "") {
                gsub(/\./, "\\.", filter)  # Escape literal dots first
                gsub(/\*/, ".*", filter)   # Then convert wildcards
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
        }
        /^worktree/ { path = $2 }
        /^HEAD/ { head_sha = substr($2,1,7) }
        /^branch/ {
            if (path != current_dir) {
                branch = $2
                sub("refs/heads/", "", branch)
                if (filter == "" || tolower(branch) ~ tolower(filter)) count++
            }
        }
        /^detached/ {
            if (path != current_dir) {
                branch = "HEAD@" head_sha
                if (filter == "" || tolower(branch) ~ tolower(filter)) count++
            }
        }
        END { print count+0 }
    ')
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
            nav_options="\"◀ Previous\" \"$KEY_PREV\" \"run-shell \\\". '$script_path' && $menu_function $((page - 1)) $args_suffix\\\"\" "
        else
            nav_options="\"◀ Previous\" \"$KEY_PREV\" \"run-shell \\\". '$script_path' && $menu_function $((page - 1))\\\"\" "
        fi
    fi

    # Next page navigation (preserve filter and extra args)
    if [ "$page" -lt "$total_pages" ]; then
        if [ -n "$args_suffix" ]; then
            nav_options="${nav_options}\"Next ▶\" \"$KEY_NEXT\" \"run-shell \\\". '$script_path' && $menu_function $((page + 1)) $args_suffix\\\"\" "
        else
            nav_options="${nav_options}\"Next ▶\" \"$KEY_NEXT\" \"run-shell \\\". '$script_path' && $menu_function $((page + 1))\\\"\" "
        fi
    fi

    # Back to main menu
    nav_options="${nav_options}\"← Back\" \"$KEY_BACK\" \"run-shell \\\". '$script_path' && tmux_worktrees_main\\\"\""

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
    debug_log "show_worktree_menu called: page=${1:-1} filter='${2:-}'"
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    # Single combined call for count + data (performance optimization)
    local combined_output
    combined_output=$(get_worktree_data_with_count "$page" "$filter")
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
    local filter_option="\"Filter\" \"$KEY_FILTER\" \"command-prompt -p 'Filter pattern:' 'run-shell \\\". $script_path && show_worktree_menu 1 %1\\\"'\""

    # Clear filter option (only when filter active)
    local clear_option=""
    if [ -n "$filter" ]; then
        clear_option="\"Clear filter\" \"$KEY_CLEAR_FILTER\" \"run-shell \\\". '$script_path' && show_worktree_menu 1\\\"\""
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
    local branch="$1"
    debug_log "create_new_worktree called: branch='$branch'"
    local project_name
    project_name=$(get_project_name)
    local session_name="${project_name}-${branch//\//-}"
    local worktree_path="$WORKTREE_BASE/$project_name/$branch"
    debug_log "create_new_worktree: project=$project_name session=$session_name path=$worktree_path"

    # Ensure project directory exists
    if ! mkdir -p "$WORKTREE_BASE/$project_name" 2>/dev/null; then
        debug_log "create_new_worktree: FAILED to create $WORKTREE_BASE/$project_name"
        tmux display-message "Failed to create directory: $WORKTREE_BASE/$project_name (check permissions)"
        return 1
    fi

    if git worktree add "$worktree_path" -b "$branch" > /dev/null 2>&1; then
        debug_log "create_new_worktree: worktree created at $worktree_path"
        if tmux new-session -d -c "$worktree_path" -s "$session_name" && \
           tmux switch-client -t "$session_name"; then
            debug_log "create_new_worktree: SUCCESS session=$session_name"
            tmux display-message "Created worktree and session: $session_name"
        else
            debug_log "create_new_worktree: worktree OK but session FAILED"
            tmux display-message "Worktree created but session failed - try 'tmux new -s $session_name'"
        fi
    else
        debug_log "create_new_worktree: FAILED git worktree add (branch may exist)"
        tmux display-message "Failed to create worktree - branch '$branch' may already exist"
    fi
}

# Show add worktree menu with pagination, optional filter, and optional remote branches
show_add_worktree_menu() {
    debug_log "show_add_worktree_menu called: page=${1:-1} filter='${2:-}' include_remotes=${3:-0}"
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local include_remotes=${3:-0}
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    # Single combined call for count + data (performance optimization)
    local combined_output
    combined_output=$(get_branch_data_with_count "$page" "$filter" "$include_remotes")
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
    local new_option="\"New\" \"$KEY_NEW\" \"command-prompt -p 'New branch name:' 'run-shell \\\". $script_path && create_new_worktree %1\\\"'\""

    # Fetch remote option - fetches and refreshes menu with remotes included
    local fetch_option="\"Fetch remote\" \"$KEY_FETCH\" \"run-shell \\\". '$script_path' && fetch_remote_branches && show_add_worktree_menu 1 '$filter' 1\\\"\""

    # Filter option (always present)
    local filter_option="\"Filter\" \"$KEY_FILTER\" \"command-prompt -p 'Filter pattern:' 'run-shell \\\". $script_path && show_add_worktree_menu 1 %1 $include_remotes\\\"'\""

    # Clear filter option (only when filter active)
    local clear_option=""
    if [ -n "$filter" ]; then
        clear_option="\"Clear filter\" \"$KEY_CLEAR_FILTER\" \"run-shell \\\". '$script_path' && show_add_worktree_menu 1 '' $include_remotes\\\"\""
    fi

    local all_options="$new_option $fetch_option $filter_option $clear_option $branch_items $nav_options"
    display_menu "$title" "$all_options"
}

# Show remove worktree menu with pagination and optional filter
show_remove_worktree_menu() {
    debug_log "show_remove_worktree_menu called: page=${1:-1} filter='${2:-}'"
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    # Single combined call for count + data (performance optimization)
    local combined_output
    combined_output=$(get_removable_worktree_data_with_count "$page" "$filter")
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
    local filter_option="\"Filter\" \"$KEY_FILTER\" \"command-prompt -p 'Filter pattern:' 'run-shell \\\". $script_path && show_remove_worktree_menu 1 %1\\\"'\""

    # Clear filter option (only when filter active)
    local clear_option=""
    if [ -n "$filter" ]; then
        clear_option="\"Clear filter\" \"$KEY_CLEAR_FILTER\" \"run-shell \\\". '$script_path' && show_remove_worktree_menu 1\\\"\""
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
    debug_log "tmux_worktrees_main called"
    local script_path="$SCRIPT_DIR/worktree_manager.sh"
    local options='"List" "'"$KEY_LIST"'" "run-shell \". '"'"$script_path"'"' && show_worktree_menu\"" \
    "Add" "'"$KEY_ADD"'" "run-shell \". '"'"$script_path"'"' && show_add_worktree_menu\"" \
    "Remove" "'"$KEY_REMOVE"'" "run-shell \". '"'"$script_path"'"' && show_remove_worktree_menu\"" \
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
