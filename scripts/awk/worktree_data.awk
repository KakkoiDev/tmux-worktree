# worktree_data.awk - Generate menu items for worktree list
# Input: git worktree list --porcelain
# Variables: project, filter, items_per_page, start, end, script_path
#            recent_ages (optional): "branch|age;branch|age;..." map for age annotations
# Output: Line 1 = total_pages, Line 2 = space-separated menu items

BEGIN {
    count = 0
    line_num = 0

    # Parse recent_ages into age_map[branch] = age_label
    if (length(recent_ages) > 0) {
        n_pairs = split(recent_ages, pairs, ";")
        for (i = 1; i <= n_pairs; i++) {
            if (pairs[i] == "") continue
            sep = index(pairs[i], "|")
            if (sep == 0) continue
            age_branch = substr(pairs[i], 1, sep - 1)
            age_label = substr(pairs[i], sep + 1)
            age_map[age_branch] = age_label
        }
    }
}

function format_label(b,   label) {
    label = b
    if (b in age_map) {
        label = label " (" age_map[b] ")"
    }
    return label
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
            label = format_label(branch)
            items[line_num] = "\"" label "\" \"\" \"display-message \\\"Switching...\\\" ; run-shell \\\"'" script_path "' switch_worktree " branch " \\\\\\\"" full_path "\\\\\\\"\\\"\""
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
            label = format_label(branch)
            items[line_num] = "\"" label "\" \"\" \"display-message \\\"Switching...\\\" ; run-shell \\\"'" script_path "' switch_worktree " branch " \\\\\\\"" full_path "\\\\\\\"\\\"\""
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
