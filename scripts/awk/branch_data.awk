# branch_data.awk - Generate menu items for branch list (add worktree menu)
# Input: git branch output (local or local+remote)
# Variables: base, project, filter, items_per_page, start, end, existing_wt, script_path
# Output: Line 1 = total_pages, Line 2 = space-separated menu items

BEGIN {
    count = 0
    line_num = 0
    # Parse existing worktrees into an array
    n = split(existing_wt, wt_arr, "|")
    for (i = 1; i <= n; i++) {
        has_worktree[wt_arr[i]] = 1
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
        # Skip remote branches that already have a local counterpart
        # (local branches are listed first, so they are already in the array)
        if (local_branches[local_branch]) {
            next
        }
    } else {
        # Store local branch names for later duplicate detection
        local_branches[branch] = 1
    }

    # Skip branches that already have a worktree
    if (has_worktree[local_branch]) {
        next
    }

    # Apply filter (case-insensitive) - match against the branch name portion
    match_name = is_remote ? local_branch : branch
    if (filter == "" || tolower(match_name) ~ tolower(filter)) {
        count++
        line_num++
        if (line_num >= start && line_num <= end) {
            if (is_remote) {
                # Remote branch: pass remote ref as second arg
                items[line_num] = "\"[remote] " display_branch "\" \"\" \"display-message \\\"Creating worktree...\\\" ; run-shell \\\"'" script_path "' add_worktree " local_branch " " branch "\\\"\""
            } else {
                # Local branch
                items[line_num] = "\"" display_branch "\" \"\" \"display-message \\\"Creating worktree...\\\" ; run-shell \\\"'" script_path "' add_worktree " branch "\\\"\""
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
