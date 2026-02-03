# worktree_data.awk - Generate menu items for worktree list
# Input: git worktree list --porcelain
# Variables: project, filter, items_per_page, start, end
# Output: Line 1 = total_pages, Line 2 = space-separated menu items

BEGIN {
    count = 0
    line_num = 0
}
/^worktree/ { path = $2; full_path = $2; head_sha = "" }
/^HEAD/ { head_sha = substr($2, 1, 7) }
/^branch/ {
    branch = $2
    sub("refs/heads/", "", branch)
    # Sanitize branch name - remove newlines and shell metacharacters
    gsub(/[\r\n]/, "", branch)
    gsub(/[^a-zA-Z0-9._\/-]/, "", branch)

    # Apply filter (case-insensitive)
    if (filter == "" || tolower(branch) ~ tolower(filter)) {
        count++
        line_num++
        if (line_num >= start && line_num <= end) {
            session_name = project "-" branch
            gsub("/", "-", session_name)
            items[line_num] = "\"" branch "\" \"\" \"display-message \\\"Switching...\\\" ; run-shell \\\"tmux has-session -t " session_name " 2>/dev/null && tmux switch-client -t " session_name " || (tmux new-session -d -c \\\\\\\"" full_path "\\\\\\\" -s " session_name " -e TMUX_WORKTREE=1 -e TMUX_WORKTREE_PROJECT=" project " -e TMUX_WORKTREE_BRANCH=" branch " -e TMUX_WORKTREE_PATH=\\\\\\\"" full_path "\\\\\\\" && tmux switch-client -t " session_name ")\\\"\""
        }
    }
}
/^detached/ {
    # Handle detached HEAD worktrees
    branch = "HEAD@" head_sha

    # Apply filter (case-insensitive)
    if (filter == "" || tolower(branch) ~ tolower(filter)) {
        count++
        line_num++
        if (line_num >= start && line_num <= end) {
            session_name = project "-detached-" head_sha
            items[line_num] = "\"" branch "\" \"\" \"display-message \\\"Switching...\\\" ; run-shell \\\"tmux has-session -t " session_name " 2>/dev/null && tmux switch-client -t " session_name " || (tmux new-session -d -c \\\\\\\"" full_path "\\\\\\\" -s " session_name " -e TMUX_WORKTREE=1 -e TMUX_WORKTREE_PROJECT=" project " -e TMUX_WORKTREE_BRANCH=" branch " -e TMUX_WORKTREE_PATH=\\\\\\\"" full_path "\\\\\\\" && tmux switch-client -t " session_name ")\\\"\""
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
