# shellcheck shell=bash
# menu.sh - build a display-menu without hand-quoting anything.
#
# Promotes the args-array convention already written three times
# (tracker.sh:882, mesh.sh:1335, session-order.sh:80) and replaces
# tmux-worktree's `eval "tmux display-menu -T '$title' $options"`, where the
# menu is assembled as one string by ten awk scripts and every layer adds
# another round of backslashes.
#
# The quoting is the whole point. A menu item's third field is a *tmux command
# string*, which tmux parses, and inside it `run-shell '<sh>'` is a *shell*
# command string, which /bin/sh parses. Two nested parsers, and a branch name
# with a space or an apostrophe breaks both. tk_menu_cmd does that quoting once.

TK_MENU_ARGS=()
TK_MENU_TITLE=""

tk_menu_reset() { TK_MENU_ARGS=(); TK_MENU_TITLE=""; }

tk_menu_title() { TK_MENU_TITLE="$1"; }

# tk_menu_item <label> <key> <command>
#
# An empty key makes the row mouse/arrow-selectable only; an empty command makes
# it inert, which is how a non-selectable header or an empty-state line is done.
tk_menu_item() {
    # tmux expands `#` in a label as a format, so a branch called `fix#12` would
    # render as something else entirely, or error.
    local label="${1//#/}"
    TK_MENU_ARGS+=("$label" "${2:-}" "${3:-}")
}

# A separator row. All three fields empty.
tk_menu_sep() { TK_MENU_ARGS+=("" "" ""); }

# tk_menu_text <label> - a non-selectable line.
tk_menu_text() { tk_menu_item "$1" "" ""; }

tk_menu_quit() { tk_menu_item "quit" "${1:-q}" ""; }

# tk_menu_cmd <script> [arg]... - a `run-shell` command string, quoted correctly.
#
# Single-quotes every word and escapes embedded single quotes the POSIX way
# ('\''), so a path with a space, an apostrophe or a dollar sign survives both
# the tmux parse and the shell parse.
tk_menu_cmd() {
    local out="" w esc q="'"
    for w in "$@"; do
        esc="${w//$q/$q\\$q$q}"
        out="$out '$esc'"
    done
    printf "run-shell%s" "$out"
}

# tk_menu_count - number of rows currently staged.
tk_menu_count() { printf '%s' "$(( ${#TK_MENU_ARGS[@]} / 3 ))"; }

# tk_menu_show [extra tmux flags...]
#
# TK_MENU_DRYRUN=1 prints one argument per line instead of calling tmux. That is
# the only unit-test seam available, because display-menu is a client overlay and
# capture-pane cannot see it; asserting on the argument vector is what catches a
# quoting regression without a terminal.
tk_menu_show() {
    local args=()
    [[ -n "$TK_MENU_TITLE" ]] && args+=(-T "$TK_MENU_TITLE")
    args+=("$@")
    args+=("${TK_MENU_ARGS[@]}")

    if [[ "${TK_MENU_DRYRUN:-0}" == "1" ]]; then
        printf '%s\n' "${args[@]}"
        return 0
    fi
    tk_tmux display-menu "${args[@]}"
}

# ── pagination ───────────────────────────────────────────────────────
#
# Only the arithmetic is shared. Each plugin's nav rows differ in wording and
# key, and mesh's are dead code, so building them here would be inventing a
# common shape that does not exist.

# tk_menu_page <total_items> <per_page> <requested_page>
# Sets TK_PAGE (1-based, clamped), TK_PAGES and TK_OFFSET (0-based).
#
# shellcheck disable=SC2034  # TK_PAGES/TK_OFFSET are outputs, read by callers
tk_menu_page() {
    local total="${1:-0}" per="${2:-10}" want="${3:-1}"
    [[ "$per" -ge 1 ]] || per=1
    TK_PAGES=$(( (total + per - 1) / per ))
    [[ "$TK_PAGES" -ge 1 ]] || TK_PAGES=1
    case "$want" in ''|*[!0-9]*) want=1 ;; esac
    [[ "$want" -ge 1 ]] || want=1
    [[ "$want" -le "$TK_PAGES" ]] || want="$TK_PAGES"
    TK_PAGE="$want"
    TK_OFFSET=$(( (TK_PAGE - 1) * per ))
}
