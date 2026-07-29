#!/usr/bin/env bash
# Lean installer: add the run-shell source line to the tmux config and reload.
# TPM users do not need this - they use `set -g @plugin 'KakkoiDev/tmux-worktree'`.
#
# Deliberately does not touch git, create worktrees, or write any state. The
# plugin builds $WORKTREE_BASE lazily on first use, and an installer that
# creates directories is one more thing to undo.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${TMUX_CONF:-$HOME/.tmux.conf}"
LINE="run-shell '$DIR/worktrees.tmux'"

for dep in git tmux awk; do
    command -v "$dep" >/dev/null 2>&1 || { echo "missing required command: $dep" >&2; exit 1; }
done

# tmux 3.0 is the floor: display-menu does not exist before it, and the whole
# UI is menus.
if ! tmux -V | sed 's/[^0-9.]//g' | awk -F. '{exit !($1 > 3 || ($1 == 3 && $2 >= 0))}'; then
    echo "tmux-worktree requires tmux 3.0+ (found $(tmux -V))" >&2
    exit 1
fi

# Match on the .tmux path rather than the whole line, so an install from a moved
# checkout replaces the old entry instead of adding a second one.
if [ -f "$CONF" ] && grep -qF "worktrees.tmux" "$CONF"; then
    if grep -qF "$LINE" "$CONF"; then
        echo "Already installed in $CONF"
    else
        echo "A different tmux-worktree checkout is already sourced in $CONF:" >&2
        grep -nF "worktrees.tmux" "$CONF" >&2
        echo "Remove that line first, or run uninstall.sh from that checkout." >&2
        exit 1
    fi
else
    printf '\n# tmux-worktree\n%s\n' "$LINE" >> "$CONF"
    echo "Added to $CONF"
fi

if [ -n "${TMUX:-}" ]; then
    tmux source-file "$CONF" && echo "Reloaded tmux config. Try: prefix + W"
else
    echo "Start tmux (or reload with: tmux source-file $CONF) to activate."
fi
