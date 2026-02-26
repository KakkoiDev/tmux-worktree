# Ideas

Improvement ideas for tmux-worktree, inspired by [worktrunk](https://github.com/max-sixty/worktrunk) comparison and user feedback.

## High Priority / Low Effort

### Copy ignored files on worktree creation
Copy `.gitignore`d build artifacts (node_modules, dist, .env) from the primary worktree to new worktrees using CoW (`cp -c` on macOS). Eliminates cold-start penalty (~3s vs ~60s). Controlled via `@worktree-copy-ignored` option.

**Status:** Implemented

### Runtime options menu
`prefix+W > Options` to toggle settings without editing tmux.conf. Toggle debug, change items/page, copy-ignored, fetch timeout, worktree path.

**Status:** Implemented

## Medium Priority / Medium Effort

### Post-create hook
Run a command after worktree creation via `@worktree-post-create-cmd`. Example: `npm install && cp ../.env .`

### Project config file
Support `.tmux-worktree.conf` in repo root for team-shared settings (hooks, path template, copy-ignored patterns).

### Merge/cleanup workflow
Menu option to merge branch back to main, then remove worktree + session in one step.

### Template variables in hooks
Support `{{ branch }}`, `{{ project }}`, `{{ path }}` in hook commands.

## Low Priority / Higher Effort

### CI status in worktree list
Show GitHub/GitLab PR status inline in worktree list via `gh` CLI.

### Progressive rendering
Show skeleton menu immediately, fill data in parallel. Reduces perceived latency.

### Shell integration (cd directive)
Allow `cd`-ing into worktrees from regular shell without tmux session switching. Write directive files that shell hooks pick up.

### Branch-first abstraction
Abstract away paths entirely, think in branches. `tmux-worktree switch feature-auth` style interaction.

## Won't Do

### Decouple from tmux
Tight tmux coupling IS our strength. worktrunk's flexibility comes at the cost of setup complexity. Our zero-config visual UX is the differentiator.

### Rewrite in Rust/Go
Shell portability and zero dependencies are features, not limitations. Performance is adequate for the interactive use case.
