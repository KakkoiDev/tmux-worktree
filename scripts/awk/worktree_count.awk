# worktree_count.awk - Count worktrees for pagination
# Input: git worktree list --porcelain
# Variables: filter (regex pattern, optional)
# Output: count of matching worktrees

/^worktree/ { path = $2 }
/^HEAD/ { head_sha = substr($2, 1, 7) }
/^branch/ {
    branch = $2
    sub("refs/heads/", "", branch)
    if (filter == "" || tolower(branch) ~ tolower(filter)) count++
}
/^detached/ {
    branch = "HEAD@" head_sha
    if (filter == "" || tolower(branch) ~ tolower(filter)) count++
}
END { print count + 0 }
