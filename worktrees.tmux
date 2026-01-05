#!/usr/bin/env bash
# ==============================================================================
# TMUX WORKTREES - TPM Plugin Loader
# ==============================================================================
# TPM entry point for tmux-worktree plugin
# Installs keybinding and sets up environment

# Determine plugin directory
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TMUX_WORKTREES_PLUGIN_DIR="$CURRENT_DIR"

# Source helpers
SCRIPTS_DIR="$CURRENT_DIR/scripts"
source "$SCRIPTS_DIR/helpers.sh"

# Load configuration
load_config

# Bind main menu key (default: prefix + W)
# Only bind if we're in a tmux environment
if [ -n "$TMUX" ] || [ -n "$TMUX_SOCKET" ]; then
    if [ -n "$TMUX_SOCKET" ]; then
        tmux -L "$TMUX_SOCKET" bind-key "$KEYBINDING" run-shell "$SCRIPTS_DIR/worktree_manager.sh tmux_worktrees_main"
    else
        tmux bind-key "$KEYBINDING" run-shell "$SCRIPTS_DIR/worktree_manager.sh tmux_worktrees_main"
    fi
fi
