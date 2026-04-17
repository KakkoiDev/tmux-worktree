# stale_count.awk - Count stale worktrees for a given age threshold
# Input: git worktree list --porcelain
# Variables:
#   current_dir         - pwd (skipped)
#   filter              - case-insensitive regex on branch
#   threshold_seconds   - age threshold in seconds
#   now                 - current unix timestamp
#   recent_ts_pairs     - "branch|ts;..." from get_recent_entries
# Output: single integer = number of stale worktrees.

BEGIN {
    count = 0

    if (length(recent_ts_pairs) > 0) {
        n_pairs = split(recent_ts_pairs, entries, ";")
        for (i = 1; i <= n_pairs; i++) {
            if (entries[i] == "") continue
            sep = index(entries[i], "|")
            if (sep == 0) continue
            b = substr(entries[i], 1, sep - 1)
            v = substr(entries[i], sep + 1)
            ts_map[b] = v + 0
        }
    }
}

function is_stale(b,   ts) {
    ts = (b in ts_map) ? ts_map[b] : 0
    return (now - ts) >= threshold_seconds
}

/^worktree/ {
    path = $2
    head_sha = ""
}
/^HEAD/ { head_sha = substr($2, 1, 7) }
/^branch/ {
    if (path != current_dir) {
        branch = $2
        sub("refs/heads/", "", branch)
        gsub(/[^a-zA-Z0-9._\/-]/, "", branch)

        if (filter == "" || tolower(branch) ~ tolower(filter)) {
            if (is_stale(branch)) count++
        }
    }
}
/^detached/ {
    if (path != current_dir) {
        branch = "HEAD@" head_sha

        if (filter == "" || tolower(branch) ~ tolower(filter)) {
            if (is_stale(branch)) count++
        }
    }
}
END {
    print count
}
