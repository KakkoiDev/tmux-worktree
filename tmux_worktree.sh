#!/bin/bash

# ==============================================================================
# TMUX WORKTREES MANAGER
# A tmux-menus style git worktree management system with pagination
# ==============================================================================

# Ensure PATH is set for git and other commands (POSIX-compliant for dash/sh)
if [ -z "$PATH" ] || ! command -v git >/dev/null 2>&1; then
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
fi

# Ensure HOME is set (fallback to user's home if not)
if [ -z "$HOME" ]; then
    export HOME=$(eval echo ~$USER)
fi

# Script configuration
SCRIPT_PATH="$HOME/dotfiles/scripts/tmux_worktree.sh"
WORKTREE_BASE="$HOME/.tmux-worktrees/worktrees"
MANAGED_DIR="$WORKTREE_BASE/__tmux_managed__"
ITEMS_PER_PAGE=15

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
        # Attempt cleanup anyway
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
    
    # Refresh the menu (direct function call to avoid recursive sourcing)
    show_remove_worktree_menu "$current_page"
}

# Get git worktree data with pagination
get_worktree_data() {
    local page=${1:-1}
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))
    
    local project_name=$(get_project_name)
    git worktree list --porcelain | awk -v home="$HOME" -v project="$project_name" '
        /^worktree/ {path=$2;full_path=$2}
        /^branch/ {
            branch=$2
            display_path=path
            sub(home"/", "~/", display_path)
            sub("refs/heads/", "", branch)
            session_name=project "-" branch
            gsub("/", "-", session_name)
            print "\"" display_path " (" branch ")\" \"\" \"run-shell \\\"tmux has-session -t " session_name " 2>/dev/null && tmux switch-client -t " session_name " || (tmux new-session -d -c \\\\\\\"" full_path "\\\\\\\" -s " session_name " && tmux switch-client -t " session_name ")\\\"\""
        }
    ' | sed -n "${start_line},${end_line}p" | tr '\n' ' '
}

# Get git branch data with pagination
get_branch_data() {
    local page=${1:-1}
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))
    
    local project_name=$(get_project_name)
    git branch --format="%(refname:short)" | sed -n "${start_line},${end_line}p" | awk -v base="$WORKTREE_BASE" -v project="$project_name" '
        {
            branch = $0
            worktree_path = base "/" branch
            session_name = project "-" branch
            gsub("/", "-", session_name)
            print "\"" branch "\" \"\" \"run-shell \\\"git worktree add " worktree_path " " branch " > /dev/null && tmux new-session -d -c \\\\\\\"" worktree_path "\\\\\\\" -s " session_name " && tmux switch-client -t " session_name "\\\"\""
        }
    ' | tr '\n' ' '
}

# Get removable worktree data with pagination
get_removable_worktree_data() {
    local page=${1:-1}
    local start_line=$(( (page - 1) * ITEMS_PER_PAGE + 1 ))
    local end_line=$(( page * ITEMS_PER_PAGE ))
    
    local project_name=$(get_project_name)
    git worktree list --porcelain | awk -v home="$HOME" -v current_dir="$(pwd)" -v script_path="$SCRIPT_PATH" -v current_page="$page" -v project="$project_name" '
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
    ' | sed -n "${start_line},${end_line}p" | tr '\n' ' '
}

# ==============================================================================
# PAGE CALCULATION FUNCTIONS
# ==============================================================================

get_worktree_page_count() {
    local total=$(git worktree list --porcelain | grep -c "^worktree")
    echo $(( (total + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))
}

get_branch_page_count() {
    local total=$(git branch --format="%(refname:short)" | wc -l)
    echo $(( (total + ITEMS_PER_PAGE - 1) / ITEMS_PER_PAGE ))
}

get_removable_worktree_page_count() {
    local total=$(git worktree list --porcelain | awk -v current_dir="$(pwd)" '
        /^worktree/ { path = $2 }
        /^branch/ { if (path != current_dir) count++ }
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
    
    local nav_options=""
    
    # Previous page navigation
    if [ "$page" -gt 1 ]; then
        nav_options="\"◀ Previous\" \"o\" \"run-shell \\\". '$SCRIPT_PATH' && $menu_function $((page - 1))\\\"\" "
    fi

    # Next page navigation
    if [ "$page" -lt "$total_pages" ]; then
        nav_options="${nav_options}\"Next ▶\" \"i\" \"run-shell \\\". '$SCRIPT_PATH' && $menu_function $((page + 1))\\\"\" "
    fi

    # Back to main menu
    nav_options="${nav_options}\"← Back\" \"BSpace\" \"run-shell \\\". '$SCRIPT_PATH' && tmux_worktrees_main\\\"\""
    
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

# Show worktree list menu with pagination
show_worktree_menu() {
    local page=${1:-1}
    local total_pages=$(get_worktree_page_count)
    local worktree_items=$(get_worktree_data $page)
    local nav_options=$(generate_nav_options $page $total_pages "show_worktree_menu")
    
    if [ -n "$worktree_items" ]; then
        local all_options="$worktree_items $nav_options"
    else
        local all_options="\"(No worktrees found)\" \"\" \"\" $nav_options"
    fi

    display_menu "Worktrees (Page $page/$total_pages)" "$all_options"
}

# Create new worktree helper function
create_new_worktree() {
    local branch="$1"
    local project_name=$(get_project_name)
    local session_name="${project_name}-${branch//\//-}"
    
    git worktree add "$MANAGED_DIR/$branch" -b "$branch" > /dev/null 2>&1 && \
    tmux new-session -d -c "$MANAGED_DIR/$branch" -s "$session_name" && \
    tmux switch-client -t "$session_name"
}

# Show add worktree menu with pagination
show_add_worktree_menu() {
    local page=${1:-1}
    local total_pages=$(get_branch_page_count)
    local project_name=$(get_project_name)
    local managed_dir_expanded="$MANAGED_DIR"
    local new_option="\"New\" \"n\" \"command-prompt -p 'New branch name:' 'run-shell \\\". $SCRIPT_PATH && create_new_worktree %1'\""
    local branch_items=$(get_branch_data $page)
    local nav_options=$(generate_nav_options $page $total_pages "show_add_worktree_menu")
    
    local all_options="$new_option $branch_items $nav_options"
    display_menu "Add Worktree (Page $page/$total_pages)" "$all_options"
}

# Show remove worktree menu with pagination
show_remove_worktree_menu() {
    local page=${1:-1}
    local total_pages=$(get_removable_worktree_page_count)
    local worktree_items=$(get_removable_worktree_data $page)
    local nav_options=$(generate_nav_options $page $total_pages "show_remove_worktree_menu")
    
    if [ -n "$worktree_items" ]; then
        local all_options="$worktree_items $nav_options"
    else
        local all_options="\"(No removable worktrees found)\" \"\" \"\" $nav_options"
    fi

    display_menu "Remove Worktree (Page $page/$total_pages)" "$all_options"
}

# ==============================================================================
# MAIN MENU
# ==============================================================================

# Main tmux worktrees menu
tmux_worktrees_main() {
    local options='"List" "l" "run-shell \". '"'"$SCRIPT_PATH"'"' && show_worktree_menu\"" \
    "Add" "a" "run-shell \". '"'"$SCRIPT_PATH"'"' && show_add_worktree_menu\"" \
    "Remove" "r" "run-shell \". '"'"$SCRIPT_PATH"'"' && show_remove_worktree_menu\"" \
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
        "show_worktree_menu") show_worktree_menu "$2" ;;
        "show_add_worktree_menu") show_add_worktree_menu "$2" ;;
        "show_remove_worktree_menu") show_remove_worktree_menu "$2" ;;
        "remove_worktree") remove_worktree "$2" "$3" "$4" "$5" "$6" ;;
        "create_new_worktree") create_new_worktree "$2" ;;
        *) echo "Unknown command: $1" ;;
    esac
}

# Execute main function if script is run directly (not sourced)
# POSIX-compliant check: if $0 ends with the script name, it's being executed directly
case "$0" in
    *tmux_worktree.sh) main "$@" ;;
esac