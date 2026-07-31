# branch_data.awk - Generate TSV rows for add-worktree branch list menu
# Input: git branch output (local or local+remote)
# Variables: project, filter, items_per_page, start, end, existing_wt, script_path (unused)
#   existing_wt: "branch1|path1;branch2|path2" map of branches that already
#   have a worktree.
# Output: Line 1 = total_pages, subsequent lines = TSV rows
# TSV columns: type, label, branch, extra
#   type "active": extra = full_path  (already has worktree -> switch_worktree)
#   type "local":  extra = ""        (local branch -> add_worktree)
#   type "remote": extra = remote_ref (remote branch -> add_worktree with remote)

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
    # Sanitize branch name
    gsub(/[\r\n]/, "", branch)
    gsub(/[^a-zA-Z0-9._\/-]/, "", branch)

    is_remote = (index(branch, "/") > 0 && index(branch, "origin/") == 1)

    display_branch = branch
    local_branch = branch

    if (is_remote) {
        local_branch = substr(branch, index(branch, "/") + 1)
        if (local_branches[local_branch]) {
            next
        }
    } else {
        local_branches[branch] = 1
    }

    match_name = is_remote ? local_branch : branch
    if (filter != "" && tolower(match_name) !~ tolower(filter)) next

    count++
    if (has_worktree[local_branch]) {
        a_n++
        active_type[a_n] = "active"
        active_label[a_n] = "[active] " display_branch
        active_branch[a_n] = local_branch
        active_extra[a_n] = wt_path[local_branch]
    } else if (is_remote) {
        r_n++
        remote_type[r_n] = "remote"
        remote_label[r_n] = "[remote] " display_branch
        remote_branch[r_n] = local_branch
        remote_extra[r_n] = branch
    } else {
        l_n++
        local_type[l_n] = "local"
        local_label[l_n] = display_branch
        local_branch_arr[l_n] = branch
    }
}
END {
    total_pages = int((count + items_per_page - 1) / items_per_page)
    if (total_pages < 1) total_pages = 1
    print total_pages

    # Build ordered array
    idx = 0
    for (i = 1; i <= a_n; i++) {
        idx++
        all[idx] = active_type[i] "\t" active_label[i] "\t" active_branch[i] "\t" active_extra[i]
    }
    for (i = 1; i <= l_n; i++) {
        idx++
        all[idx] = local_type[i] "\t" local_label[i] "\t" local_branch_arr[i] "\t" ""
    }
    for (i = 1; i <= r_n; i++) {
        idx++
        all[idx] = remote_type[i] "\t" remote_label[i] "\t" remote_branch[i] "\t" remote_extra[i]
    }

    for (i = start; i <= end && i <= idx; i++) {
        if (all[i] != "") print all[i]
    }
}
