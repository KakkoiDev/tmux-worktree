# tmux-worktree

> **Beta:** This plugin is under active development. Configuration options and behavior may change.

Work on multiple branches at the same time without ever leaving tmux. One keypress creates a worktree, opens a session, and drops you in - ready to code. Switch between tasks instantly. Clean up when you're done.

No CLI commands to remember. No paths to manage. Just a menu that does everything git worktree can do, faster than you can type it.

<a href="https://github.com/user-attachments/assets/d9fc4507-00c4-422f-9457-c6dfbb2ef022">
  <img src="https://github.com/user-attachments/assets/3d947242-47e6-424e-872c-ef9fcf41a7b5" alt="Demo" width="600">
</a><br>
<a href="https://github.com/user-attachments/assets/d9fc4507-00c4-422f-9457-c6dfbb2ef022">▶ Click to watch demo</a>

## Quick Start

Requires **tmux 3.0+**, **git**, and **bash 3.2+**.

**Install with [TPM](https://github.com/tmux-plugins/tpm):**

```bash
# Add to ~/.tmux.conf
set -g @plugin 'KakkoiDev/tmux-worktree'
```

Press `prefix + I` to install, then `prefix + W` to open the menu.

## Workflows

### Create a worktree

```
prefix + W  →  Add  →  select "feature/login"
```

Creates a worktree at `~/.tmux-worktree/myproject/feature/login` and opens a new tmux session.

### Switch between tasks

```
prefix + s  →  select session
```

Use tmux's built-in session switcher. For worktrees without an open session:

```
prefix + W  →  List  →  select worktree
```

Creates a session if needed, then switches to it.

### Find a branch

```
prefix + W  →  List  →  Filter  →  type "feature*"  →  Enter
```

Shows only branches matching the pattern. Supports `*` (any characters) and `?` (single character).

### Remove a worktree

```
prefix + W  →  Remove  →  select worktree to delete
```

Removes the worktree directory. The git branch is preserved (delete manually with `git branch -D` if needed). Stale entries from manually deleted directories are pruned automatically.

### Check out a remote branch

```
prefix + W  →  Add  →  Fetch remote  →  select "[remote] origin/fix-bug-123"
```

Fetches latest branches, creates a local tracking branch with its own worktree.

### Copy build files to new worktrees

New worktrees start empty - no `node_modules/`, no `.env`, no build output. Enable this to copy those files automatically from your main worktree:

```bash
# In tmux.conf, or toggle at runtime: prefix + W → Options
set -g @worktree-copy-ignored "on"
```

Uses Copy-on-Write on macOS for near-instant copies regardless of size.

## Keys

| Key | Action |
|-----|--------|
| `l` | List worktrees |
| `a` | Add worktree |
| `d` | Remove worktree |
| `o` | Options / Previous page |
| `i` | Next page |
| `f` | Filter |
| `c` | Clear filter |
| `n` | New branch (in Add menu) |
| `r` | Fetch remote (in Add menu) |
| `b` | Back |
| `q` | Quit |

## Worktree Storage

Worktrees are organized by project:

```
~/.tmux-worktree/
├── myproject/
│   ├── main/
│   └── feature/login/
└── other-repo/
    └── bugfix/header/
```

Sessions are named `{project}-{branch}` (e.g., `myproject-feature-login`).

## Configuration

Works out of the box. Settings can be changed in `tmux.conf` or at runtime via `prefix + W → Options`.

```bash
# Change keybinding (default: W)
set -g @worktree-keybinding "T"

# Change storage path (default: ~/.tmux-worktree)
set -g @worktree-path "~/worktrees"

# Items per page (default: 15)
set -g @worktree-items-per-page "20"

# Copy .gitignore'd files to new worktrees (default: off)
set -g @worktree-copy-ignored "on"
```

<details>
<summary>All keybinding options</summary>

```bash
set -g @worktree-key-list "l"
set -g @worktree-key-add "a"
set -g @worktree-key-remove "d"
set -g @worktree-key-quit "q"
set -g @worktree-key-next "i"
set -g @worktree-key-prev "o"
set -g @worktree-key-back "b"
set -g @worktree-key-filter "f"
set -g @worktree-key-clear-filter "c"
set -g @worktree-key-new "n"
set -g @worktree-key-fetch "r"
set -g @worktree-key-options "o"
```

</details>

## Environment Variables

Each worktree session exposes variables you can use in your shell prompt or tmux statusline:

| Variable | Description |
|----------|-------------|
| `TMUX_WORKTREE` | Set to `1` in managed sessions |
| `TMUX_WORKTREE_PROJECT` | Project/repository name |
| `TMUX_WORKTREE_BRANCH` | Branch name |
| `TMUX_WORKTREE_PATH` | Worktree directory path |

**Shell prompt:**
```bash
# .bashrc / .zshrc
if [ -n "$TMUX_WORKTREE" ]; then
    PS1="[$TMUX_WORKTREE_PROJECT:$TMUX_WORKTREE_BRANCH] $PS1"
fi
```

**Tmux statusline:**
```bash
set -g status-right '#{?TMUX_WORKTREE,#[fg=green]#{TMUX_WORKTREE_BRANCH},}'
```

## Troubleshooting

**Menu doesn't appear:** Requires tmux 3.0+. Check with `tmux -V`.

**Fetch times out:** Run `git fetch origin` manually. On macOS, install `brew install coreutils` for timeout support.

**Keybinding conflict:** Change with `set -g @worktree-keybinding "T"`.

**Debug mode:** Enable with `set -g @worktree-debug "on"` or via `prefix + W → Options`. Logs written to `~/.tmux-worktree/.tmux-worktree.log`.

**Something else?** [Open an issue](https://github.com/KakkoiDev/tmux-worktree/issues/new) with your tmux version (`tmux -V`), OS, and relevant lines from the debug log.

## Manual Installation

```bash
git clone https://github.com/KakkoiDev/tmux-worktree ~/.tmux/plugins/tmux-worktree
```

Add to `~/.tmux.conf`:

```bash
run-shell ~/.tmux/plugins/tmux-worktree/worktrees.tmux
```

## Uninstall

Remove the plugin line from `~/.tmux.conf` and reload. Optionally delete worktrees: `rm -rf ~/.tmux-worktree`.

## Acknowledgments

Thanks to [@Ahmed-878](https://github.com/Ahmed-878) for his help debugging this project.

## License

MIT
