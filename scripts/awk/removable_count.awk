# removable_count.awk - Count removable worktrees for pagination
# Input: git worktree list --porcelain
# Variables: current_dir (current working directory), filter (regex pattern, optional)
# Output: count of removable worktrees (excludes current directory)

/^worktree/ { path = $2 }
/^HEAD/ { head_sha = substr($2, 1, 7) }
/^branch/ {
    if (path != current_dir) {
        branch = $2
        sub("refs/heads/", "", branch)
        if (filter == "" || tolower(branch) ~ tolower(filter)) count++
    }
}
/^detached/ {
    if (path != current_dir) {
        branch = "HEAD@" head_sha
        if (filter == "" || tolower(branch) ~ tolower(filter)) count++
    }
}
END { print count + 0 }
