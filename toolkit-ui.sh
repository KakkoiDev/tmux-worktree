# shellcheck shell=bash
# toolkit-ui.sh - entry point for interactive and install-time work.
#
# The hot set plus the modules a harness hook must never pay for. Source this
# from a key binding, a menu handler, an installer or a CLI; source
# lib/toolkit.sh from a hook.
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/toolkit-ui.sh"
#   tk_init agent-mesh "$MESH_DIR"
#
# Currently carries menu, lock and notify. target, fmt, hook, sched, status,
# harness and identity are not written yet; this file is the list of what
# exists, and a contract test asserts that every module it names is present, so
# it cannot drift back into documenting something that is not there.

if [[ -z "${TK_UI_LOADED:-}" ]]; then
    TK_UI_LOADED=1

    _tk_ui_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -n "${TMUX_TOOLKIT_DEV:-}" && -r "${TMUX_TOOLKIT_DEV%/}/lib/core.sh" ]]; then
        _tk_ui_src="${TMUX_TOOLKIT_DEV%/}/lib"
    fi

    # shellcheck source=toolkit.sh
    source "$_tk_ui_src/toolkit.sh"

    # shellcheck source=lock.sh
    source "$_tk_ui_src/lock.sh"
    # shellcheck source=menu.sh
    source "$_tk_ui_src/menu.sh"
    # shellcheck source=notify.sh
    source "$_tk_ui_src/notify.sh"

    unset _tk_ui_src
fi
