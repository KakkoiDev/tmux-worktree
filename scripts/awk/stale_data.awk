# stale_data.awk - Generate TSV rows for bulk-remove preview menu
# Input: git worktree list --porcelain
# Variables: current_dir, script_path (unused in TSV), current_page, project,
#            filter, items_per_page, start, end, threshold_days, threshold_seconds,
#            now, recent_ts_pairs, recent_age_pairs
# Output: Line 1 = total_pages, subsequent lines = TSV rows
# TSV columns: label, full_path, branch, session_name, current_page
#
# Inclusion rule: a worktree is "stale" when (now - ts_of_its_branch) >= threshold_seconds.
# Branches absent from the recent log resolve to ts=0 and are always stale (age "never").

BEGIN {
    count = 0
    line_num = 0

    # Parse recent_ts_pairs into ts_map[branch] = ts
    if (length(recent_ts_pairs) > 0) {
        n_ts_pairs = split(recent_ts_pairs, ts_entries, ";")
        for (i = 1; i <= n_ts_pairs; i++) {
            if (ts_entries[i] == "") continue
            sep = index(ts_entries[i], "|")
            if (sep == 0) continue
            b = substr(ts_entries[i], 1, sep - 1)
            v = substr(ts_entries[i], sep + 1)
            ts_map[b] = v + 0
        }
    }

    # Parse recent_age_pairs into age_map[branch] = "2h" / "3d" / etc.
    if (length(recent_age_pairs) > 0) {
        n_age_pairs = split(recent_age_pairs, age_entries, ";")
        for (i = 1; i <= n_age_pairs; i++) {
            if (age_entries[i] == "") continue
            sep = index(age_entries[i], "|")
            if (sep == 0) continue
            b = substr(age_entries[i], 1, sep - 1)
            v = substr(age_entries[i], sep + 1)
            age_map[b] = v
        }
    }
}

function age_label(b) {
    if (b in age_map) return age_map[b]
    return "never"
}

function is_stale(b,   ts) {
    ts = (b in ts_map) ? ts_map[b] : 0
    return (now - ts) >= threshold_seconds
}

/^worktree/ {
    path = $2
    full_path = $2
    head_sha = ""
}
/^HEAD/ { head_sha = substr($2, 1, 7) }
/^branch/ {
    if (path != current_dir) {
        branch = $2
        sub("refs/heads/", "", branch)
        gsub(/[^a-zA-Z0-9._\/-]/, "", branch)

        if (filter == "" || tolower(branch) ~ tolower(filter)) {
            if (is_stale(branch)) {
                count++
                line_num++
                if (line_num >= start && line_num <= end) {
                    session_name = project "-" branch
                    gsub("/", "_", session_name)
                    gsub("[.:]", "_", session_name)

                    label = branch " (" age_label(branch) ")"
                    items[line_num] = label "\t" full_path "\t" branch "\t" session_name "\t" current_page
                }
            }
        }
    }
}
/^detached/ {
    if (path != current_dir) {
        branch = "HEAD@" head_sha

        if (filter == "" || tolower(branch) ~ tolower(filter)) {
            if (is_stale(branch)) {
                count++
                line_num++
                if (line_num >= start && line_num <= end) {
                    session_name = project "-detached-" head_sha
                    gsub("[.:]", "_", session_name)

                    label = branch " (" age_label(branch) ")"
                    items[line_num] = label "\t" full_path "\t" "" "\t" session_name "\t" current_page
                }
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
