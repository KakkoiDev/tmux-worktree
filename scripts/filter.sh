#!/usr/bin/env bash
# ==============================================================================
# TMUX WORKTREES - Filter Functions
# ==============================================================================
# Wildcard matching and input sanitization
# Requires: bash 3.2+ (uses [[ ]] and case pattern matching)

# Sanitize filter input to prevent shell injection
# Allows: a-z A-Z 0-9 * ? - _ / space
# Removes: ; $ ` ( ) { } [ ] | & < > \ " '
sanitize_filter() {
    local input="$1"
    # Remove dangerous characters, keep only safe ones
    echo "$input" | tr -cd 'a-zA-Z0-9*?_/. -'
}

# Check if a string matches a wildcard pattern
# Uses bash pattern matching with case-insensitive comparison
# Supports: * (any chars), ? (single char)
matches_filter() {
    local string="$1"
    local pattern="$2"

    # Empty pattern matches everything
    if [ -z "$pattern" ]; then
        return 0
    fi

    # Convert to lowercase for case-insensitive matching (POSIX portable)
    local lower_string
    local lower_pattern
    lower_string=$(echo "$string" | tr '[:upper:]' '[:lower:]')
    lower_pattern=$(echo "$pattern" | tr '[:upper:]' '[:lower:]')

    # Use bash extended pattern matching
    # * becomes * (works in case)
    # ? becomes ? (works in case)
    # shellcheck disable=SC2254 # The user-supplied glob is intentional here.
    case "$lower_string" in
        $lower_pattern) return 0 ;;
        *) return 1 ;;
    esac
}

# Note: Filtering is done directly in AWK within worktree_manager.sh
# for better performance with large lists
