# worktree_data.awk - Generate TSV rows for worktree list menu
# Input: git worktree list --porcelain
# Variables: project, filter, items_per_page, start, end, script_path (unused in TSV)
#            recent_ages (optional): "branch|age;branch|age;..." map for age annotations
# Output: Line 1 = total_pages, subsequent lines = TSV rows
# TSV columns: label, branch, full_path

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

function format_label(b) {
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
    gsub(/[\r\n]/, "", branch)
    gsub(/[^a-zA-Z0-9._\/-]/, "", branch)

    if (filter == "" || tolower(branch) ~ tolower(filter)) {
        count++
        line_num++
        if (line_num >= start && line_num <= end) {
            label = format_label(branch)
            items[line_num] = label "\t" branch "\t" full_path
        }
    }
}
/^detached/ {
    branch = "HEAD@" head_sha

    if (filter == "" || tolower(branch) ~ tolower(filter)) {
        count++
        line_num++
        if (line_num >= start && line_num <= end) {
            label = format_label(branch)
            items[line_num] = label "\t" branch "\t" full_path
        }
    }
}
END {
    total_pages = int((count + items_per_page - 1) / items_per_page)
    if (total_pages < 1) total_pages = 1
    print total_pages

    for (i = start; i <= end && i <= line_num; i++) {
        if (items[i] != "") print items[i]
    }
}
