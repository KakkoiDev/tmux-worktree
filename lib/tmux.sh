# shellcheck shell=bash
# tmux.sh - the single tmux choke point.
#
# Every tmux call in every consumer goes through tk_tmux. That is what makes
# two otherwise unrelated needs one module:
#
#   * tmux-agent-tracker's sandbox mode, which must no-op every tmux call
#     (scripts/tracker.sh:90 `_tmux`), and
#   * tmux-worktree's private-socket support, hand-copied as an
#     `if [ -n "$TMUX_SOCKET" ]` fork at 10 separate call sites.
#
# Both are "rewrite the argv before it reaches tmux", so both belong here.
#
# TK_SOCKET      - when set, every call gets -L "$TK_SOCKET"
# TK_TMUX_DISABLED=1 - return 0 without calling tmux (sandbox / dry-run)
# TK_TMUX_BIN    - override the binary (tests, or a side-by-side tmux-next)

TK_SOCKET="${TK_SOCKET:-}"
TK_TMUX_DISABLED="${TK_TMUX_DISABLED:-0}"
TK_TMUX_BIN="${TK_TMUX_BIN:-tmux}"

# tk_tmux <args...> - faithful passthrough. Returns tmux's exit status, so call
# sites that must not fail keep their own `|| true`; the library does not decide
# for them.
tk_tmux() {
    [[ "$TK_TMUX_DISABLED" == "1" ]] && return 0
    if [[ -n "$TK_SOCKET" ]]; then
        "$TK_TMUX_BIN" -L "$TK_SOCKET" "$@"
    else
        "$TK_TMUX_BIN" "$@"
    fi
}

# tk_tmux_silent <args...> - for cosmetic writes (status options, refreshes)
# where a failure must never propagate into a harness hook's exit status.
tk_tmux_silent() {
    tk_tmux "$@" >/dev/null 2>&1 || true
    return 0
}

# tk_tmux_ok - is a tmux server reachable?
#
# list-sessions, not `tmux info`: info exits non-zero with "no current client"
# when a server is running but unattached, which made every install and doctor
# check report "no tmux" on a perfectly healthy server.
tk_tmux_ok() {
    [[ "$TK_TMUX_DISABLED" == "1" ]] && return 1
    tk_tmux list-sessions >/dev/null 2>&1
}

# tk_in_tmux - are we running inside a pane? Distinct from tk_tmux_ok: a harness
# hook invoked from settings.json has no $TMUX but the server is up.
tk_in_tmux() { [[ -n "${TMUX:-}" || -n "${TMUX_PANE:-}" ]]; }

# tk_display <msg> - user-visible status-line toast. Never fails.
tk_display() { tk_tmux_silent display-message "$*"; }

# tk_server_pid - identifies the running server. Used as a cache key, and as the
# invalidation signal for anything holding %N pane ids: a restarted server
# renumbers panes from %0, so every stored pane id becomes a lie.
tk_server_pid() { tk_tmux display-message -p '#{pid}' 2>/dev/null || true; }
