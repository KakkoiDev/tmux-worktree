# worktree_sort_alpha.awk - Reorder worktree porcelain blocks alphabetically by branch
# Input: git worktree list --porcelain
# Output: Same porcelain format, blocks sorted by branch name (case-insensitive ascending).
# Detached HEAD blocks (no branch line) sort after named branches, in input order.

BEGIN {
    block_count = 0
    current_block = ""
    current_branch = ""
}

/^worktree/ {
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
    if (current_block != "") {
        block_count++
        blocks[block_count] = current_block
        branches[block_count] = current_branch
    }

    # Build index arrays: named blocks first (alpha), then detached blocks (input order)
    named_n = 0
    detached_n = 0
    for (i = 1; i <= block_count; i++) {
        if (branches[i] == "") {
            detached_n++
            detached_idx[detached_n] = i
        } else {
            named_n++
            named_idx[named_n] = i
        }
    }

    # Insertion sort named_idx by lowercase branch ascending
    for (i = 2; i <= named_n; i++) {
        k = named_idx[i]
        k_key = tolower(branches[k])
        j = i - 1
        while (j > 0) {
            prev = named_idx[j]
            if (tolower(branches[prev]) > k_key) {
                named_idx[j + 1] = prev
                j--
            } else break
        }
        named_idx[j + 1] = k
    }

    for (i = 1; i <= named_n; i++) {
        printf "%s\n", blocks[named_idx[i]]
    }
    for (i = 1; i <= detached_n; i++) {
        printf "%s\n", blocks[detached_idx[i]]
    }
}
