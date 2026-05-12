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

# Restore persisted options before loading config
restore_saved_options

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
        tmux -L "$TMUX_SOCKET" bind-key "$KEYBINDING" run-shell "tmux display-message 'Opening...' ; $SCRIPTS_DIR/worktree_manager.sh tmux_worktrees_main"
    else
        tmux bind-key "$KEYBINDING" run-shell "tmux display-message 'Opening...' ; $SCRIPTS_DIR/worktree_manager.sh tmux_worktrees_main"
    fi

    # Register after-new-session hook to adopt host sessions into the plugin's
    # naming convention. Plugin-created sessions already match the convention
    # so the hook is a no-op for them. Append (-a) so we don't clobber other
    # user hooks; opt-out via @worktree-adopt-session=off.
    if [ "${ADOPT_SESSION:-on}" != "off" ]; then
        hook_cmd="run-shell \"$SCRIPTS_DIR/worktree_manager.sh adopt_session_hook '#{session_name}' '#{session_path}'\""
        if [ -n "$TMUX_SOCKET" ]; then
            tmux -L "$TMUX_SOCKET" set-hook -ag after-new-session "$hook_cmd"
        else
            tmux set-hook -ag after-new-session "$hook_cmd"
        fi

        # Sweep existing sessions once at plugin load: the after-new-session
        # hook only fires for future sessions, so any session created before
        # the plugin was installed/reloaded keeps its default name otherwise.
        tmux_bin="tmux"
        [ -n "$TMUX_SOCKET" ] && tmux_bin="tmux -L $TMUX_SOCKET"
        $tmux_bin list-sessions -F '#{session_name}|#{session_path}' 2>/dev/null \
            | while IFS='|' read -r _name _path; do
                [ -z "$_name" ] && continue
                "$SCRIPTS_DIR/worktree_manager.sh" adopt_session_hook "$_name" "$_path" >/dev/null 2>&1 || true
            done
    fi
fi
