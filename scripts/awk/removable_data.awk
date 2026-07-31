# removable_data.awk - Generate TSV rows for removable worktree list
# Input: git worktree list --porcelain
# Variables: current_dir, script_path (unused in TSV), current_page, project,
#            filter, items_per_page, start, end
# Output: Line 1 = total_pages, subsequent lines = TSV rows
# TSV columns: label, full_path, branch, session_name, current_page

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
        gsub(/[^a-zA-Z0-9._\/-]/, "", branch)

        if (filter == "" || tolower(branch) ~ tolower(filter)) {
            count++
            line_num++
            if (line_num >= start && line_num <= end) {
                session_name = project "-" branch
                gsub("/", "_", session_name)
                gsub("[.:]", "_", session_name)

                items[line_num] = branch "\t" full_path "\t" branch "\t" session_name "\t" current_page
            }
        }
    }
}
/^detached/ {
    if (path != current_dir) {
        branch = "HEAD@" head_sha

        if (filter == "" || tolower(branch) ~ tolower(filter)) {
            count++
            line_num++
            if (line_num >= start && line_num <= end) {
                session_name = project "-detached-" head_sha
                gsub("[.:]", "_", session_name)

                items[line_num] = branch "\t" full_path "\t" "" "\t" session_name "\t" current_page
            }
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
