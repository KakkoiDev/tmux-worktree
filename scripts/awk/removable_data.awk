# removable_data.awk - Generate menu items for removable worktree list
# Input: git worktree list --porcelain
# Variables: current_dir, script_path, current_page, project, filter, items_per_page, start, end
# Output: Line 1 = total_pages, Line 2 = space-separated menu items

BEGIN {
    count = 0
    line_num = 0
}
/^worktree/ {
    path = $2
    full_path = path
    head_sha = ""
}
/^HEAD/ { head_sha = substr($2, 1, 7) }
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
                gsub("[.:]", "-", session_name)

                # Remove worktree only (branch is always kept)
                # script_path is passed directly via -v, no shell quoting needed
                items[line_num] = "\"" branch "\" \"\" \"display-message \\\"Removing worktree...\\\" ; run-shell \\\"'" script_path "' remove_worktree \\\\\\\"" full_path "\\\\\\\" \\\\\\\"" branch "\\\\\\\" \\\\\\\"" session_name "\\\\\\\" " current_page "\\\"\""
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
                gsub("[.:]", "-", session_name)

                # Detached HEAD worktrees - remove worktree only
                items[line_num] = "\"" branch "\" \"\" \"display-message \\\"Removing worktree...\\\" ; run-shell \\\"'" script_path "' remove_worktree \\\\\\\"" full_path "\\\\\\\" \\\\\\\"\\\\\\\" \\\\\\\"" session_name "\\\\\\\" " current_page "\\\"\""
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
