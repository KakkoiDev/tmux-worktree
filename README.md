# tmux-worktree

> **Beta:** This plugin is under active development. Configuration options and behavior may change.

Manage git worktrees with tmux sessions. Switch branches without stashing, run tests on one branch while coding on another.

## Quick Start

**Install with [TPM](https://github.com/tmux-plugins/tpm):**

```bash
# Add to ~/.tmux.conf
set -g @plugin 'KakkoiDev/tmux-worktree'
```

Press `prefix + I` to install, then `prefix + W` to open the menu.

## Workflows

### Start working on a feature

```
prefix + W  →  Add  →  select "feature/login"
```

Creates a worktree at `~/.tmux-worktree/myproject/feature/login` and opens a new tmux session.

### Review a colleague's PR

```
prefix + W  →  Add  →  Fetch remote  →  select "[remote] origin/fix-bug-123"
```

Fetches latest branches, creates a local tracking branch with its own worktree.

### Switch between tasks

```
prefix + s  →  select session
```

Use tmux's built-in session switcher for quick navigation between open sessions.

For worktrees without an open session:

```
prefix + W  →  List  →  select worktree
```

Creates a session if needed, then switches to it.

### Clean up after merging

```
prefix + W  →  Remove  →  select worktree to delete
```

Removes the worktree directory. The git branch is preserved (delete manually with `git branch -D` if needed).

### Find a specific branch

```
prefix + W  →  List  →  Filter  →  type "feature*"  →  Enter
```

Shows only branches matching the pattern. Supports `*` (any characters) and `?` (single character).

## Keys

| Key | Action |
|-----|--------|
| `l` | List worktrees |
| `a` | Add worktree |
| `d` | Remove worktree |
| `i` / `o` | Next / Previous page |
| `f` | Filter |
| `c` | Clear filter |
| `n` | New branch (in Add menu) |
| `r` | Fetch remote (in Add menu) |
| `b` | Back |
| `q` | Quit |

## How It Works

Worktrees are stored by project:

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

Most users don't need to configure anything. For customization:

```bash
# Change keybinding (default: W)
set -g @worktree-keybinding "T"

# Change storage path (default: ~/.tmux-worktree)
set -g @worktree-path "~/worktrees"

# Items per page (default: 15)
set -g @worktree-items-per-page "20"
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
```

</details>

## Troubleshooting

**Menu doesn't appear:** Requires tmux 3.0+. Check with `tmux -V`.

**Fetch times out:** Run `git fetch origin` manually. On macOS, install `brew install coreutils` for timeout support.

**Keybinding conflict:** Change with `set -g @worktree-keybinding "T"`.

**Debug mode:** Enable with `set -g @worktree-debug "on"`. Logs written to `~/.tmux-worktree/.tmux-worktree.log`.

## Requirements

- tmux 3.0+
- git
- bash 3.2+

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

## License

MIT
