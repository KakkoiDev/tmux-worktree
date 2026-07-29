#!/usr/bin/env bash
# Remove the run-shell source line (and its comment) added by install.sh.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${TMUX_CONF:-$HOME/.tmux.conf}"
LINE="run-shell '$DIR/worktrees.tmux'"

if [ ! -f "$CONF" ]; then
    echo "No $CONF; nothing to do."
    exit 0
fi

if ! grep -qF "$LINE" "$CONF"; then
    echo "Not installed in $CONF; nothing to do."
    exit 0
fi

tmp=$(mktemp)
grep -vF "$LINE" "$CONF" | grep -vxF "# tmux-worktree" > "$tmp" || true

# `cat "$tmp" > "$CONF"`, never `mv "$tmp" "$CONF"`. A dotfiles-managed
# ~/.tmux.conf is usually a symlink, and mv replaces the link itself with a
# regular file: the real file keeps its old contents and every future edit goes
# to a detached copy. Verified on this platform --
#   ln -s real.conf link.conf; mv new link.conf   -> link.conf is now a file
#   ln -s real.conf link.conf; cat new > link.conf -> link preserved, real updated
cat "$tmp" > "$CONF"
rm -f "$tmp"

echo "Removed from $CONF."

# Nothing else is touched. The worktrees themselves, $WORKTREE_BASE, the recent
# log and the persisted options are user data: an uninstaller that deletes
# checked-out branches would be a data-loss bug, not a courtesy.
cat <<EOF

Left in place (user data, remove by hand if you want them gone):
  \${TMUX_WORKTREE_STATE_FILE:-\$HOME/.tmux-worktree/options.conf}
  worktrees under \$(tmux show-option -gqv @worktree-path), default ~/.tmux-worktree

Restart tmux (or reload) to drop the key binding and the after-new-session hook.
EOF
