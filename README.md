# tmux-worktree

A tmux plugin for managing git worktrees with an interactive menu interface.

## Features

- **Switch Worktrees**: Quickly switch between existing git worktrees
- **Create Worktrees**: Create new worktrees from local or remote branches
- **Remove Worktrees**: Clean up worktrees with optional branch deletion
- **Remote Branch Support**: Fetch and create worktrees from remote branches
- **Filter/Search**: Filter worktrees and branches by pattern (supports `*` and `?` wildcards)
- **Pagination**: Navigate large lists with keyboard shortcuts
- **Session Management**: Automatically creates/switches tmux sessions per worktree

## Requirements

- tmux 3.0+ (uses `display-menu`)
- git
- bash 3.2+
- coreutils `timeout` or `gtimeout` (optional, for fetch timeout protection)

## Installation

### With [TPM](https://github.com/tmux-plugins/tpm) (recommended)

Add to your `~/.tmux.conf`:

```bash
set -g @plugin 'KakkoiDev/tmux-worktree'
```

Then press `prefix + I` to install.

### Manual Installation

```bash
git clone https://github.com/KakkoiDev/tmux-worktree ~/.tmux/plugins/tmux-worktree
```

Add to your `~/.tmux.conf`:

```bash
run-shell ~/.tmux/plugins/tmux-worktree/worktrees.tmux
```

## Usage

Press `prefix + W` (default) to open the main menu.

### Main Menu

- **List** (`l`) - Switch to an existing worktree
- **Add** (`a`) - Create a new worktree from a branch
- **Remove** (`d`) - Remove an existing worktree

### Navigation (customizable)

- `i` / `o` - Next / Previous page
- `f` - Filter by pattern
- `c` - Clear filter
- `Backspace` - Back to previous menu
- `n` - Create new branch (in Add menu)
- `r` - Fetch remote branches (in Add menu)
- `q` - Quit

### Filter Patterns

- `feature*` - Match branches starting with "feature"
- `*fix*` - Match branches containing "fix"
- `bug?123` - Match "bug" + any single character + "123"

## Configuration

Add to your `~/.tmux.conf`:

```bash
# Custom keybinding (default: W)
set -g @worktree-keybinding "T"

# Custom worktree base path (default: ~/.tmux-worktree)
set -g @worktree-path "~/my-worktrees"

# Items per page (default: 15)
set -g @worktree-items-per-page "20"

# Fetch timeout in seconds (default: 30)
set -g @worktree-fetch-timeout "60"
```

### Custom Keybindings

All navigation keys can be customized:

```bash
# Navigation keys
set -g @worktree-key-next "j"        # Next page (default: i)
set -g @worktree-key-prev "k"        # Previous page (default: o)
set -g @worktree-key-back "Escape"   # Back (default: BSpace)
set -g @worktree-key-quit "q"        # Quit (default: q)

# Action keys
set -g @worktree-key-filter "/"      # Filter (default: f)
set -g @worktree-key-clear-filter "x" # Clear filter (default: c)
set -g @worktree-key-new "n"         # New branch (default: n)
set -g @worktree-key-fetch "r"       # Fetch remote (default: r)
```

## How It Works

### Managed vs Existing Worktrees

- **Managed worktrees**: Created via "New" in the Add Worktree menu. Stored in `@worktree-path/__tmux_worktree_managed__/`. When removed, both the worktree and branch are deleted.
- **Existing worktrees**: Created from existing branches. When removed, only the worktree is deleted; the branch is preserved.

### Session Naming

Sessions are named `{project}-{branch}` with `/` replaced by `-`.

Example: Project `myapp` on branch `feature/login` creates session `myapp-feature-login`.

## Troubleshooting

### "display-menu" not found

Ensure you have tmux 3.0 or newer:
```bash
tmux -V
```

### Fetch fails or times out

Try fetching manually:
```bash
git fetch origin
```

On macOS, install coreutils for timeout support:
```bash
brew install coreutils
```

### Worktree creation fails

Check if the branch already exists:
```bash
git branch -a | grep branch-name
```

### Plugin not loading

Check if the plugin is active:
```bash
# Run health check
~/.tmux/plugins/tmux-worktree/scripts/worktree_manager.sh health_check
```

### Keybinding doesn't work

The default `prefix + W` may conflict with other plugins. Change it:
```bash
set -g @worktree-keybinding "T"
```

## Uninstall

1. Remove the plugin line from `~/.tmux.conf`
2. Reload tmux config (`prefix + r`) or restart tmux

Optionally remove managed worktrees:
```bash
rm -rf ~/.tmux-worktree
```

## Debug Mode

Enable debug logging to troubleshoot issues:

```bash
set -g @worktree-debug "on"
```

Logs are written to `~/.tmux-worktree/.tmux-worktree.log`.

## License

MIT
