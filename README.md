# tmux-worktree

> **Beta:** This plugin is under active development. Configuration options and behavior may change.

Native tmux for parallel workflows. AI agents, code reviews, tests. Each task gets its own worktree and session.

<a href="https://github.com/user-attachments/assets/d9fc4507-00c4-422f-9457-c6dfbb2ef022">
  <img src="https://github.com/user-attachments/assets/3d947242-47e6-424e-872c-ef9fcf41a7b5" alt="Demo" width="600">
</a><br>
<a href="https://github.com/user-attachments/assets/d9fc4507-00c4-422f-9457-c6dfbb2ef022">▶ Click to watch demo</a>





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

### Automatic cleanup

The plugin automatically prunes stale worktree entries (directories that no longer exist) before listing. If you manually delete a worktree directory, it will be cleaned up the next time you open the menu. Git 2.30+ enables additional repair capabilities.

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

## Environment Variables

Sessions created by tmux-worktree include environment variables for integration with other tools:

| Variable | Description |
|----------|-------------|
| `TMUX_WORKTREE` | Set to `1` in managed sessions |
| `TMUX_WORKTREE_PROJECT` | Project/repository name |
| `TMUX_WORKTREE_BRANCH` | Branch name |
| `TMUX_WORKTREE_PATH` | Worktree directory path |

**Example: Shell prompt**
```bash
# .bashrc / .zshrc
if [ -n "$TMUX_WORKTREE" ]; then
    PS1="[$TMUX_WORKTREE_PROJECT:$TMUX_WORKTREE_BRANCH] $PS1"
fi
```

**Example: Tmux statusline**
```bash
set -g status-right '#{?TMUX_WORKTREE,#[fg=green]#{TMUX_WORKTREE_BRANCH},}'
```

## Troubleshooting

**Menu doesn't appear:** Requires tmux 3.0+. Check with `tmux -V`.

**Fetch times out:** Run `git fetch origin` manually. On macOS, install `brew install coreutils` for timeout support.

**Keybinding conflict:** Change with `set -g @worktree-keybinding "T"`.

**Debug mode:** Enable with `set -g @worktree-debug "on"`. Logs written to `~/.tmux-worktree/.tmux-worktree.log`.

## Report a Bug

[Open an issue](https://github.com/KakkoiDev/tmux-worktree/issues/new) with:

1. Enable debug mode: `set -g @worktree-debug "on"`
2. Reload tmux and reproduce the issue
3. Include relevant lines from `~/.tmux-worktree/.tmux-worktree.log`
4. Add your tmux version (`tmux -V`) and OS

## Requirements

- tmux 3.0+
- git
- bash 3.2+

## Manual Installation

```bash
git clone https://github.com/KakkoiDev/tmux-worktree ~/.tmux/plugins/tmux-worktree
~/.tmux/plugins/tmux-worktree/install.sh
```

`install.sh` checks the dependencies and the tmux version, appends the source
line to `~/.tmux.conf`, and reloads. It is idempotent, and it refuses rather than
adding a second entry if a different checkout is already sourced.

Or do it by hand, adding to `~/.tmux.conf`:

```bash
run-shell ~/.tmux/plugins/tmux-worktree/worktrees.tmux
```

Set `TMUX_CONF` to install into a config other than `~/.tmux.conf`.

## Uninstall

```bash
~/.tmux/plugins/tmux-worktree/uninstall.sh
```

Removes only the config line. Worktrees, `~/.tmux-worktree` and the persisted
options are user data and are left alone; delete them by hand if you want them
gone.

Both scripts write the config with `cat tmp > conf` rather than `mv tmp conf`,
because a dotfiles-managed `~/.tmux.conf` is usually a symlink and `mv` would
replace the link with a regular file, silently detaching every later edit.

## Acknowledgments

Thanks to [@Ahmed-878](https://github.com/Ahmed-878) for his help debugging this project.

## License

MIT
