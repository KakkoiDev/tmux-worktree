# worktree_reorder.awk - Reorder worktree porcelain blocks by recent usage
# Input: git worktree list --porcelain
# Variables: recent (pipe-delimited branch names, newest first)
# Output: Same porcelain format, blocks reordered (recent first, then rest)
# Empty recent = passthrough (no reordering)

BEGIN {
    block_count = 0
    current_block = ""
    current_branch = ""

    # Parse recent branches into ordered array
    recent_total = split(recent, recent_arr, "|")
    for (i = 1; i <= recent_total; i++) {
        is_recent[recent_arr[i]] = i
    }
}

/^worktree/ {
    # Save previous block
    if (current_block != "") {
        block_count++
        blocks[block_count] = current_block
        branches[block_count] = current_branch
    }
    current_block = $0 "\n"
    current_branch = ""
    next
}

/^$/ {
    if (current_block != "") {
        block_count++
        blocks[block_count] = current_block
        branches[block_count] = current_branch
        current_block = ""
        current_branch = ""
    }
    next
}

/^branch/ {
    current_branch = $2
    sub("refs/heads/", "", current_branch)
    current_block = current_block $0 "\n"
    next
}

{
    current_block = current_block $0 "\n"
}

END {
    # Save last block
    if (current_block != "") {
        block_count++
        blocks[block_count] = current_block
        branches[block_count] = current_branch
    }

    # Output recent blocks in recent order
    for (i = 1; i <= recent_total; i++) {
        for (j = 1; j <= block_count; j++) {
            if (branches[j] == recent_arr[i] && !outputted[j]) {
                printf "%s\n", blocks[j]
                outputted[j] = 1
                break
            }
        }
    }

    # Output remaining blocks in original order
    for (j = 1; j <= block_count; j++) {
        if (!outputted[j]) {
            printf "%s\n", blocks[j]
        }
    }
}
