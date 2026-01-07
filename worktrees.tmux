#!/usr/bin/env bash
# ==============================================================================
# TMUX WORKTREES - TPM Plugin Loader
# ==============================================================================
# TPM entry point for tmux-worktree plugin
# Installs keybinding and sets up environment
# Requires: tmux 3.0+, bash 3.2+

# Determine plugin directory
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TMUX_WORKTREES_PLUGIN_DIR="$CURRENT_DIR"

# Source helpers
SCRIPTS_DIR="$CURRENT_DIR/scripts"
source "$SCRIPTS_DIR/helpers.sh"

# Check tmux version compatibility
if ! ensure_tmux_version; then
    exit 1
fi

# Load configuration
load_config

# Check for keybinding conflicts
check_keybinding_conflict() {
    local key="$1"
    local existing
    existing=$(tmux list-keys -T prefix 2>/dev/null | grep "bind-key -T prefix *$key " || true)
    if [ -n "$existing" ]; then
        tmux display-message "tmux-worktree: Note: prefix+$key was rebound (use @worktree-keybinding to change)"
    fi
}

# Bind main menu key (default: prefix + W)
# Only bind if we're in a tmux environment
if [ -n "$TMUX" ] || [ -n "$TMUX_SOCKET" ]; then
    check_keybinding_conflict "$KEYBINDING"
    if [ -n "$TMUX_SOCKET" ]; then
        tmux -L "$TMUX_SOCKET" bind-key "$KEYBINDING" run-shell "$SCRIPTS_DIR/worktree_manager.sh tmux_worktrees_main"
    else
        tmux bind-key "$KEYBINDING" run-shell "$SCRIPTS_DIR/worktree_manager.sh tmux_worktrees_main"
    fi
fi
