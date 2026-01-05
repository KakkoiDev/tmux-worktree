#!/usr/bin/env bash
# ==============================================================================
# TMUX WORKTREES - Core Worktree Manager
# ==============================================================================
# Migrated from standalone tmux_worktree.sh to TPM plugin architecture

# Ensure PATH is set for git and other commands (POSIX-compliant)
if [ -z "$PATH" ] || ! command -v git >/dev/null 2>&1; then
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
fi

# Ensure HOME is set
if [ -z "$HOME" ]; then
    export HOME=$(eval echo ~$USER)
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
# CORE DATA FUNCTIONS
# ==============================================================================

# Get project name from git repository root directory
get_project_name() {
    basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
}

# Remove worktree helper function
remove_worktree() {
    local worktree_path="$1"
    local branch_name="$2"
    local is_managed="$3"
    local session_name="$4"
    local current_page="$5"

    # Remove the worktree with timeout protection
    if timeout 10 git worktree remove --force "$worktree_path" > /dev/null 2>&1; then
        tmux display-message "Worktree removed: $worktree_path"
    else
        tmux display-message "Warning: Worktree removal timed out or failed"
        git worktree remove --force "$worktree_path" > /dev/null 2>&1 || true
    fi

    # If it's a managed worktree, also delete the branch with timeout
    if [ "$is_managed" = "true" ]; then
        if timeout 5 git branch -D "$branch_name" > /dev/null 2>&1; then
            tmux display-message "Branch deleted: $branch_name"
        else
            tmux display-message "Warning: Branch deletion failed: $branch_name"
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
    local page=${1:-1}
    local filter=${2:-}
    local sanitized_filter=$(sanitize_filter "$filter")
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))

    local project_name=$(get_project_name)
    git worktree list --porcelain | awk -v home="$HOME" -v project="$project_name" -v filter="$sanitized_filter" '
        BEGIN {
            # Convert wildcard to regex
            if (filter != "") {
                gsub(/\*/, ".*", filter)
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
        }
        /^worktree/ {path=$2;full_path=$2}
        /^branch/ {
            branch=$2
            display_path=path
            sub(home"/", "~/", display_path)
            sub("refs/heads/", "", branch)

            # Apply filter (case-insensitive)
            if (filter == "" || tolower(branch) ~ tolower(filter)) {
                session_name=project "-" branch
                gsub("/", "-", session_name)
                print "\"" display_path " (" branch ")\" \"\" \"run-shell \\\"tmux has-session -t " session_name " 2>/dev/null && tmux switch-client -t " session_name " || (tmux new-session -d -c \\\\\\\"" full_path "\\\\\\\" -s " session_name " && tmux switch-client -t " session_name ")\\\"\""
            }
        }
    ' | sed -n "${start_line},${end_line}p" | tr '\n' ' '
}

# Get git branch data with pagination and optional filter
get_branch_data() {
    local page=${1:-1}
    local filter=${2:-}
    local sanitized_filter=$(sanitize_filter "$filter")
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))

    local project_name=$(get_project_name)
    git branch --format="%(refname:short)" | awk -v base="$WORKTREE_BASE" -v project="$project_name" -v filter="$sanitized_filter" '
        BEGIN {
            if (filter != "") {
                gsub(/\*/, ".*", filter)
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
        }
        {
            branch = $0
            # Apply filter (case-insensitive)
            if (filter == "" || tolower(branch) ~ tolower(filter)) {
                worktree_path = base "/" branch
                session_name = project "-" branch
                gsub("/", "-", session_name)
                print "\"" branch "\" \"\" \"run-shell \\\"git worktree add " worktree_path " " branch " > /dev/null && tmux new-session -d -c \\\\\\\"" worktree_path "\\\\\\\" -s " session_name " && tmux switch-client -t " session_name "\\\"\""
            }
        }
    ' | sed -n "${start_line},${end_line}p" | tr '\n' ' '
}

# Get removable worktree data with pagination and optional filter
get_removable_worktree_data() {
    local page=${1:-1}
    local filter=${2:-}
    local sanitized_filter=$(sanitize_filter "$filter")
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))

    local project_name=$(get_project_name)
    local script_path="$SCRIPT_DIR/worktree_manager.sh"

    git worktree list --porcelain | awk -v home="$HOME" -v current_dir="$(pwd)" -v script_path="$script_path" -v current_page="$page" -v project="$project_name" -v filter="$sanitized_filter" '
        BEGIN {
            if (filter != "") {
                gsub(/\*/, ".*", filter)
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
        }
        /^worktree/ {
            path = $2
            full_path = path
        }
        /^branch/ {
            if (path != current_dir) {
                branch = $2
                display_path = path
                sub(home"/", "~/", display_path)
                sub("refs/heads/", "", branch)

                # Apply filter (case-insensitive)
                if (filter == "" || tolower(branch) ~ tolower(filter)) {
                    session_name = project "-" branch
                    gsub("/", "-", session_name)

                    # Check if worktree is in managed directory to decide whether to delete branch
                    if (path ~ /__tmux_managed__/) {
                        # Managed worktree - remove both worktree and branch
                        print "\"" display_path " (" branch ")\" \"\" \"display-message \\\"Removing managed worktree and branch...\\\" ; run-shell \\\". " script_path " && remove_worktree \\\\\\\"" full_path "\\\\\\\" \\\\\\\"" branch "\\\\\\\" true \\\\\\\"" session_name "\\\\\\\" " current_page "\\\"\""
                    } else {
                        # Existing branch worktree - only remove worktree, keep branch
                        print "\"" display_path " (" branch ")\" \"\" \"display-message \\\"Removing worktree (keeping branch)...\\\" ; run-shell \\\". " script_path " && remove_worktree \\\\\\\"" full_path "\\\\\\\" \\\\\\\"" branch "\\\\\\\" false \\\\\\\"" session_name "\\\\\\\" " current_page "\\\"\""
                    }
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
    local sanitized_filter=$(sanitize_filter "$filter")
    local total=$(git worktree list --porcelain | awk -v filter="$sanitized_filter" '
        BEGIN {
            if (filter != "") {
                gsub(/\*/, ".*", filter)
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
        }
        /^worktree/ { path = $2 }
        /^branch/ {
            branch = $2
            sub("refs/heads/", "", branch)
            if (filter == "" || tolower(branch) ~ tolower(filter)) count++
        }
        END { print count+0 }
    ')
    echo $(( (total + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))
}

get_branch_page_count() {
    local filter=${1:-}
    local sanitized_filter=$(sanitize_filter "$filter")
    local total=$(git branch --format="%(refname:short)" | awk -v filter="$sanitized_filter" '
        BEGIN {
            if (filter != "") {
                gsub(/\*/, ".*", filter)
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
        }
        {
            if (filter == "" || tolower($0) ~ tolower(filter)) count++
        }
        END { print count+0 }
    ')
    echo $(( (total + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))
}

get_removable_worktree_page_count() {
    local filter=${1:-}
    local sanitized_filter=$(sanitize_filter "$filter")
    local total=$(git worktree list --porcelain | awk -v current_dir="$(pwd)" -v filter="$sanitized_filter" '
        BEGIN {
            if (filter != "") {
                gsub(/\*/, ".*", filter)
                gsub(/\?/, ".", filter)
                filter = "^" filter "$"
            }
        }
        /^worktree/ { path = $2 }
        /^branch/ {
            if (path != current_dir) {
                branch = $2
                sub("refs/heads/", "", branch)
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
    local page=${1:-1}
    local filter=${2:-}
    local script_path="$SCRIPT_DIR/worktree_manager.sh"
    local total_pages=$(get_worktree_page_count "$filter")
    local worktree_items=$(get_worktree_data "$page" "$filter")
    local nav_options=$(generate_nav_options "$page" "$total_pages" "show_worktree_menu" "$filter")

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
    local project_name=$(get_project_name)
    local session_name="${project_name}-${branch//\//-}"

    # Ensure managed directory exists
    mkdir -p "$MANAGED_DIR"

    git worktree add "$MANAGED_DIR/$branch" -b "$branch" > /dev/null 2>&1 && \
    tmux new-session -d -c "$MANAGED_DIR/$branch" -s "$session_name" && \
    tmux switch-client -t "$session_name"
}

# Show add worktree menu with pagination and optional filter
show_add_worktree_menu() {
    local page=${1:-1}
    local filter=${2:-}
    local script_path="$SCRIPT_DIR/worktree_manager.sh"
    local total_pages=$(get_branch_page_count "$filter")
    local branch_items=$(get_branch_data "$page" "$filter")
    local nav_options=$(generate_nav_options "$page" "$total_pages" "show_add_worktree_menu" "$filter")

    # Build title with filter indicator
    local title="Add Worktree (Page $page/$total_pages)"
    [ -n "$filter" ] && title="$title - Filter: '$filter'"

    # New branch option
    local new_option="\"New\" \"n\" \"command-prompt -p 'New branch name:' 'run-shell \\\". $script_path && create_new_worktree %1'\"\""

    # Filter option (always present)
    local filter_option="\"Filter\" \"f\" \"command-prompt -p 'Filter pattern:' 'run-shell \\\". $script_path && show_add_worktree_menu 1 %1\\\"'\""

    # Clear filter option (only when filter active)
    local clear_option=""
    if [ -n "$filter" ]; then
        clear_option="\"Clear filter\" \"c\" \"run-shell \\\". '$script_path' && show_add_worktree_menu 1\\\"\""
    fi

    local all_options="$new_option $filter_option $clear_option $branch_items $nav_options"
    display_menu "$title" "$all_options"
}

# Show remove worktree menu with pagination and optional filter
show_remove_worktree_menu() {
    local page=${1:-1}
    local filter=${2:-}
    local script_path="$SCRIPT_DIR/worktree_manager.sh"
    local total_pages=$(get_removable_worktree_page_count "$filter")
    local worktree_items=$(get_removable_worktree_data "$page" "$filter")
    local nav_options=$(generate_nav_options "$page" "$total_pages" "show_remove_worktree_menu" "$filter")

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
# SCRIPT EXECUTION
# ==============================================================================

# Main entry point
main() {
    case "${1:-tmux_worktrees_main}" in
        "tmux_worktrees_main"|"") tmux_worktrees_main ;;
        "show_worktree_menu") show_worktree_menu "$2" "$3" ;;
        "show_add_worktree_menu") show_add_worktree_menu "$2" "$3" ;;
        "show_remove_worktree_menu") show_remove_worktree_menu "$2" "$3" ;;
        "remove_worktree") remove_worktree "$2" "$3" "$4" "$5" "$6" ;;
        "create_new_worktree") create_new_worktree "$2" ;;
        *) echo "Unknown command: $1" ;;
    esac
}

# Execute main function if script is run directly (not sourced)
case "$0" in
    *worktree_manager.sh) main "$@" ;;
esac
