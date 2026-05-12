# branch_data.awk - Generate menu items for branch list (add worktree menu)
# Input: git branch output (local or local+remote)
# Variables: base, project, filter, items_per_page, start, end, existing_wt, script_path
#   existing_wt: "branch1|path1;branch2|path2" map of branches that already
#   have a worktree (paths must not contain ';' or '|').
# Output: Line 1 = total_pages, Line 2 = space-separated menu items
# Ordering: [active] branches first, then plain locals, then [remote] entries.

BEGIN {
    count = 0
    a_n = 0
    l_n = 0
    r_n = 0
    # Parse existing worktrees into has_worktree[branch]=1 and wt_path[branch]=path
    n_pairs = split(existing_wt, pairs, ";")
    for (i = 1; i <= n_pairs; i++) {
        if (pairs[i] == "") continue
        sep = index(pairs[i], "|")
        if (sep == 0) continue
        b = substr(pairs[i], 1, sep - 1)
        p = substr(pairs[i], sep + 1)
        has_worktree[b] = 1
        wt_path[b] = p
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

    # Apply filter (case-insensitive) - match against the branch name portion
    match_name = is_remote ? local_branch : branch
    if (filter != "" && tolower(match_name) !~ tolower(filter)) next

    count++
    if (has_worktree[local_branch]) {
        # Already-checked-out branch: show as [active] and route to switch_worktree
        active_items[++a_n] = "\"[active] " display_branch "\" \"\" \"display-message \\\"Switching...\\\" ; run-shell \\\"'" script_path "' switch_worktree " local_branch " \\\\\\\"" wt_path[local_branch] "\\\\\\\"\\\"\""
    } else if (is_remote) {
        # Remote branch: pass remote ref as second arg
        remote_items[++r_n] = "\"[remote] " display_branch "\" \"\" \"display-message \\\"Creating worktree...\\\" ; run-shell \\\"'" script_path "' add_worktree " local_branch " " branch "\\\"\""
    } else {
        # Local branch
        local_items[++l_n] = "\"" display_branch "\" \"\" \"display-message \\\"Creating worktree...\\\" ; run-shell \\\"'" script_path "' add_worktree " branch "\\\"\""
    }
}
END {
    # Calculate total pages
    total_pages = int((count + items_per_page - 1) / items_per_page)
    if (total_pages < 1) total_pages = 1
    print total_pages

    # Concatenate buckets in display order: active, local, remote
    idx = 0
    for (i = 1; i <= a_n; i++) { idx++; all[idx] = active_items[i] }
    for (i = 1; i <= l_n; i++) { idx++; all[idx] = local_items[i] }
    for (i = 1; i <= r_n; i++) { idx++; all[idx] = remote_items[i] }

    # Output paginated slice
    for (i = start; i <= end && i <= idx; i++) {
        if (all[i] != "") printf "%s ", all[i]
    }
    if (idx > 0) print ""
}
