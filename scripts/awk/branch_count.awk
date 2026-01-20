# branch_count.awk - Count branches for pagination
# Input: git branch output (local or local+remote)
# Variables: filter (regex pattern, optional)
# Output: count of matching branches

{
    branch = $0
    # For remote branches, match against local part
    if (index(branch, "origin/") == 1) {
        match_name = substr(branch, index(branch, "/") + 1)
    } else {
        match_name = branch
    }
    if (filter == "" || tolower(match_name) ~ tolower(filter)) count++
}
END { print count + 0 }
