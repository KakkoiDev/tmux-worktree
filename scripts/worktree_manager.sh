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

    # Display fetching message
    tmux display-message "Fetching remote branches..."

    # Run git fetch with timeout (uses portable timeout wrapper)
    if run_with_timeout "$timeout_seconds" git fetch --all --prune 2>/dev/null; then
        tmux display-message "Remote branches fetched successfully"
        return 0
    else
        tmux display-message "Fetch failed - try 'git fetch origin' manually or check network"
        return 1
    fi
}

# ==============================================================================
# CORE DATA FUNCTIONS
# ==============================================================================

# Get project name from git repository root directory
# Sanitizes output to prevent command injection via malicious directory names
get_project_name() {
    local name
    name=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
    # Sanitize: allow only alphanumeric, dash, underscore, dot
    echo "$name" | tr -cd 'a-zA-Z0-9_.-'
}

# Remove worktree helper function
remove_worktree() {
    local worktree_path="$1"
    local branch_name="$2"
    local is_managed="$3"
    local session_name="$4"
    local current_page="$5"

    # Remove the worktree with timeout protection
    # Note: No retry without timeout to prevent infinite hang
    if run_with_timeout 10 git worktree remove --force "$worktree_path" > /dev/null 2>&1; then
        tmux display-message "Worktree removed: $worktree_path"
    else
        tmux display-message "Worktree removal failed - try 'git worktree remove $worktree_path' manually"
    fi

    # If it's a managed worktree, also delete the branch with timeout
    if [ "$is_managed" = "true" ]; then
        if run_with_timeout 5 git branch -D "$branch_name" > /dev/null 2>&1; then
            tmux display-message "Branch deleted: $branch_name"
        else
            tmux display-message "Branch deletion failed - try 'git branch -D $branch_name' manually"
        fi
    fi

    # Kill the tmux session if it exists (try both naming patterns)
    if tmux kill-session -t "$session_name" 2>/dev/null; then
        tmux display-message "Session killed: $session_name"
    elif tmux kill-session -t "$branch_name" 2>/dev/null; then
        tmux display-message "Session killed: $branch_name"
    fi

    # Refresh the menu
    show_remove_worktree_menu "$current_page"
}

# Get git worktree data with pagination and optional filter
get_worktree_data() {
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
    LC_ALL=C git worktree list --porcelain | LC_ALL=C awk -v home="$HOME" -v project="$project_name" -v filter="$sanitized_filter" '
        BEGIN {
            # Convert wildcard to regex
            if (filter != "") {
                gsub(/\./, "\\.", filter)  # Escape literal dots first
                gsub(/\*/, ".*", filter)   # Then convert wildcards
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
        }
        /^worktree/ {path=$2;full_path=$2;head_sha=""}
        /^HEAD/ {head_sha=substr($2,1,7)}  # Capture short SHA for detached HEAD
        /^branch/ {
            branch=$2
            display_path=path
            sub(home"/", "~/", display_path)
            sub("refs/heads/", "", branch)
            # Sanitize branch name - remove newlines and shell metacharacters
            gsub(/[\r\n]/, "", branch)
            gsub(/[^a-zA-Z0-9._\/-]/, "", branch)

            # Apply filter (case-insensitive)
            if (filter == "" || tolower(branch) ~ tolower(filter)) {
                session_name=project "-" branch
                gsub("/", "-", session_name)
                print "\"" display_path " (" branch ")\" \"\" \"run-shell \\\"tmux has-session -t " session_name " 2>/dev/null && tmux switch-client -t " session_name " || (tmux new-session -d -c \\\\\\\"" full_path "\\\\\\\" -s " session_name " && tmux switch-client -t " session_name ")\\\"\""
            }
        }
        /^detached/ {
            # Handle detached HEAD worktrees
            display_path=path
            sub(home"/", "~/", display_path)
            branch="HEAD@" head_sha

            # Apply filter (case-insensitive)
            if (filter == "" || tolower(branch) ~ tolower(filter)) {
                session_name=project "-detached-" head_sha
                print "\"" display_path " (" branch ")\" \"\" \"run-shell \\\"tmux has-session -t " session_name " 2>/dev/null && tmux switch-client -t " session_name " || (tmux new-session -d -c \\\\\\\"" full_path "\\\\\\\" -s " session_name " && tmux switch-client -t " session_name ")\\\"\""
            }
        }
    ' | sed -n "${start_line},${end_line}p" | tr '\n' ' '
}

# Get git branch data with pagination, optional filter, and optional remote branches
get_branch_data() {
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

    eval "$branch_cmd" | awk -v base="$WORKTREE_BASE" -v project="$project_name" -v filter="$sanitized_filter" '
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
                worktree_path = base "/" local_branch
                session_name = project "-" local_branch
                gsub("/", "-", session_name)

                if (is_remote) {
                    # Remote branch: create tracking branch (paths quoted for spaces)
                    print "\"[remote] " display_branch "\" \"\" \"run-shell \\\"git worktree add -b " local_branch " \\\\\\\"" worktree_path "\\\\\\\" " branch " > /dev/null && tmux new-session -d -c \\\\\\\"" worktree_path "\\\\\\\" -s " session_name " && tmux switch-client -t " session_name "\\\"\""
                } else {
                    # Local branch (paths quoted for spaces)
                    print "\"" display_branch "\" \"\" \"run-shell \\\"git worktree add \\\\\\\"" worktree_path "\\\\\\\" " branch " > /dev/null && tmux new-session -d -c \\\\\\\"" worktree_path "\\\\\\\" -s " session_name " && tmux switch-client -t " session_name "\\\"\""
                }
            }
        }
    ' | sed -n "${start_line},${end_line}p" | tr '\n' ' '
}

# Get removable worktree data with pagination and optional filter
get_removable_worktree_data() {
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

    LC_ALL=C git worktree list --porcelain | LC_ALL=C awk -v home="$HOME" -v current_dir="$(pwd)" -v script_path="$script_path" -v current_page="$page" -v project="$project_name" -v filter="$sanitized_filter" '
        BEGIN {
            if (filter != "") {
                gsub(/\./, "\\.", filter)  # Escape literal dots first
                gsub(/\*/, ".*", filter)   # Then convert wildcards
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
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
                display_path = path
                sub(home"/", "~/", display_path)
                sub("refs/heads/", "", branch)
                # Sanitize branch name - remove shell metacharacters
                gsub(/[^a-zA-Z0-9._\/-]/, "", branch)

                # Apply filter (case-insensitive)
                if (filter == "" || tolower(branch) ~ tolower(filter)) {
                    session_name = project "-" branch
                    gsub("/", "-", session_name)

                    # Check if worktree is in managed directory to decide whether to delete branch
                    # Supports both current and legacy managed directory names
                    if (path ~ /__tmux_worktree_managed__/ || path ~ /__tmux_managed__/) {
                        # Managed worktree - remove both worktree and branch
                        print "\"" display_path " (" branch ")\" \"\" \"display-message \\\"Removing managed worktree and branch...\\\" ; run-shell \\\". " script_path " && remove_worktree \\\\\\\"" full_path "\\\\\\\" \\\\\\\"" branch "\\\\\\\" true \\\\\\\"" session_name "\\\\\\\" " current_page "\\\"\""
                    } else {
                        # Existing branch worktree - only remove worktree, keep branch
                        print "\"" display_path " (" branch ")\" \"\" \"display-message \\\"Removing worktree (keeping branch)...\\\" ; run-shell \\\". " script_path " && remove_worktree \\\\\\\"" full_path "\\\\\\\" \\\\\\\"" branch "\\\\\\\" false \\\\\\\"" session_name "\\\\\\\" " current_page "\\\"\""
                    }
                }
            }
        }
        /^detached/ {
            # Handle detached HEAD worktrees
            if (path != current_dir) {
                display_path = path
                sub(home"/", "~/", display_path)
                branch = "HEAD@" head_sha

                # Apply filter (case-insensitive)
                if (filter == "" || tolower(branch) ~ tolower(filter)) {
                    session_name = project "-detached-" head_sha

                    # Detached HEAD worktrees - only remove worktree (no branch to delete)
                    print "\"" display_path " (" branch ")\" \"\" \"display-message \\\"Removing detached worktree...\\\" ; run-shell \\\". " script_path " && remove_worktree \\\\\\\"" full_path "\\\\\\\" \\\\\\\"\\\\\\\" false \\\\\\\"" session_name "\\\\\\\" " current_page "\\\"\""
                }
            }
        }
    ' | sed -n "${start_line},${end_line}p" | tr '\n' ' '
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
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    local nav_options=""

    # Previous page navigation (preserve filter)
    if [ "$page" -gt 1 ]; then
        if [ -n "$filter" ]; then
            nav_options="\"◀ Previous\" \"o\" \"run-shell \\\". '$script_path' && $menu_function $((page - 1)) '$filter'\\\"\" "
        else
            nav_options="\"◀ Previous\" \"o\" \"run-shell \\\". '$script_path' && $menu_function $((page - 1))\\\"\" "
        fi
    fi

    # Next page navigation (preserve filter)
    if [ "$page" -lt "$total_pages" ]; then
        if [ -n "$filter" ]; then
            nav_options="${nav_options}\"Next ▶\" \"i\" \"run-shell \\\". '$script_path' && $menu_function $((page + 1)) '$filter'\\\"\" "
        else
            nav_options="${nav_options}\"Next ▶\" \"i\" \"run-shell \\\". '$script_path' && $menu_function $((page + 1))\\\"\" "
        fi
    fi

    # Back to main menu
    nav_options="${nav_options}\"← Back\" \"BSpace\" \"run-shell \\\". '$script_path' && tmux_worktrees_main\\\"\""

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
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local script_path="$SCRIPT_DIR/worktree_manager.sh"
    local total_pages
    total_pages=$(get_worktree_page_count "$filter")
    # Ensure at least 1 page to avoid "Page 1/0"
    [ "$total_pages" -lt 1 ] && total_pages=1
    local worktree_items
    worktree_items=$(get_worktree_data "$page" "$filter")
    local nav_options
    nav_options=$(generate_nav_options "$page" "$total_pages" "show_worktree_menu" "$filter")

    # Build title with filter indicator
    local title="Worktrees (Page $page/$total_pages)"
    [ -n "$filter" ] && title="$title - Filter: '$filter'"

    # Filter option (always present)
    local filter_option="\"Filter\" \"f\" \"command-prompt -p 'Filter pattern:' 'run-shell \\\". $script_path && show_worktree_menu 1 %1\\\"'\""

    # Clear filter option (only when filter active)
    local clear_option=""
    if [ -n "$filter" ]; then
        clear_option="\"Clear filter\" \"c\" \"run-shell \\\". '$script_path' && show_worktree_menu 1\\\"\""
    fi

    if [ -n "$worktree_items" ]; then
        local all_options="$filter_option $clear_option $worktree_items $nav_options"
    else
        local all_options="$filter_option $clear_option \"(No worktrees found)\" \"\" \"\" $nav_options"
    fi

    display_menu "$title" "$all_options"
}

# Create new worktree helper function
create_new_worktree() {
    local branch="$1"
    local project_name
    project_name=$(get_project_name)
    local session_name="${project_name}-${branch//\//-}"

    # Ensure managed directory exists
    if ! mkdir -p "$MANAGED_DIR" 2>/dev/null; then
        tmux display-message "Failed to create directory: $MANAGED_DIR (check permissions)"
        return 1
    fi

    if git worktree add "$MANAGED_DIR/$branch" -b "$branch" > /dev/null 2>&1; then
        if tmux new-session -d -c "$MANAGED_DIR/$branch" -s "$session_name" && \
           tmux switch-client -t "$session_name"; then
            tmux display-message "Created worktree and session: $session_name"
        else
            tmux display-message "Worktree created but session failed - try 'tmux new -s $session_name'"
        fi
    else
        tmux display-message "Failed to create worktree - branch '$branch' may already exist"
    fi
}

# Show add worktree menu with pagination, optional filter, and optional remote branches
show_add_worktree_menu() {
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local include_remotes=${3:-0}
    local script_path="$SCRIPT_DIR/worktree_manager.sh"
    local total_pages
    total_pages=$(get_branch_page_count "$filter" "$include_remotes")
    # Ensure at least 1 page to avoid "Page 1/0"
    [ "$total_pages" -lt 1 ] && total_pages=1
    local branch_items
    branch_items=$(get_branch_data "$page" "$filter" "$include_remotes")
    local nav_options
    nav_options=$(generate_nav_options "$page" "$total_pages" "show_add_worktree_menu" "$filter")

    # Build title with filter and remote indicator
    local title="Add Worktree (Page $page/$total_pages)"
    [ "$include_remotes" = "1" ] && title="$title [+remote]"
    [ -n "$filter" ] && title="$title - Filter: '$filter'"

    # New branch option
    local new_option="\"New\" \"n\" \"command-prompt -p 'New branch name:' 'run-shell \\\". $script_path && create_new_worktree %1'\"\""

    # Fetch remote option - fetches and refreshes menu with remotes included
    local fetch_option="\"Fetch remote\" \"r\" \"run-shell \\\". '$script_path' && fetch_remote_branches && show_add_worktree_menu 1 '$filter' 1\\\"\""

    # Filter option (always present)
    local filter_option="\"Filter\" \"f\" \"command-prompt -p 'Filter pattern:' 'run-shell \\\". $script_path && show_add_worktree_menu 1 %1 $include_remotes\\\"'\""

    # Clear filter option (only when filter active)
    local clear_option=""
    if [ -n "$filter" ]; then
        clear_option="\"Clear filter\" \"c\" \"run-shell \\\". '$script_path' && show_add_worktree_menu 1 '' $include_remotes\\\"\""
    fi

    local all_options="$new_option $fetch_option $filter_option $clear_option $branch_items $nav_options"
    display_menu "$title" "$all_options"
}

# Show remove worktree menu with pagination and optional filter
show_remove_worktree_menu() {
    local page
    page=$(validate_page "${1:-1}")
    local filter
    filter=$(limit_filter "${2:-}")
    local script_path="$SCRIPT_DIR/worktree_manager.sh"
    local total_pages
    total_pages=$(get_removable_worktree_page_count "$filter")
    # Ensure at least 1 page to avoid "Page 1/0"
    [ "$total_pages" -lt 1 ] && total_pages=1
    local worktree_items
    worktree_items=$(get_removable_worktree_data "$page" "$filter")
    local nav_options
    nav_options=$(generate_nav_options "$page" "$total_pages" "show_remove_worktree_menu" "$filter")

    # Build title with filter indicator
    local title="Remove Worktree (Page $page/$total_pages)"
    [ -n "$filter" ] && title="$title - Filter: '$filter'"

    # Filter option (always present)
    local filter_option="\"Filter\" \"f\" \"command-prompt -p 'Filter pattern:' 'run-shell \\\". $script_path && show_remove_worktree_menu 1 %1\\\"'\""

    # Clear filter option (only when filter active)
    local clear_option=""
    if [ -n "$filter" ]; then
        clear_option="\"Clear filter\" \"c\" \"run-shell \\\". '$script_path' && show_remove_worktree_menu 1\\\"\""
    fi

    if [ -n "$worktree_items" ]; then
        local all_options="$filter_option $clear_option $worktree_items $nav_options"
    else
        local all_options="$filter_option $clear_option \"(No removable worktrees found)\" \"\" \"\" $nav_options"
    fi

    display_menu "$title" "$all_options"
}

# ==============================================================================
# MAIN MENU
# ==============================================================================

# Main tmux worktrees menu
tmux_worktrees_main() {
    local script_path="$SCRIPT_DIR/worktree_manager.sh"
    local options='"List" "l" "run-shell \". '"'"$script_path"'"' && show_worktree_menu\"" \
    "Add" "a" "run-shell \". '"'"$script_path"'"' && show_add_worktree_menu\"" \
    "Remove" "r" "run-shell \". '"'"$script_path"'"' && show_remove_worktree_menu\"" \
    "Quit" "q" ""'

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
    echo "Managed dir: $MANAGED_DIR"
    echo "Managed dir exists: $([ -d "$MANAGED_DIR" ] && echo 'yes' || echo 'no')"
    echo "Legacy managed dir: $LEGACY_MANAGED_DIR"
    echo "Legacy dir exists: $([ -d "$LEGACY_MANAGED_DIR" ] && echo 'yes' || echo 'no')"
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
