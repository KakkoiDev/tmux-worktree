# shellcheck shell=bash
# toolkit.sh - hot-path entry point.
#
# Source this from anything a harness hook can reach. A Claude hook fires around
# 12 times per turn, so this set is deliberately small: the interactive and
# install-time modules live in toolkit-ui.sh and are not paid for here.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/toolkit.sh"
#   tk_init agent-mesh "$MESH_DIR"
#
# Resolution is a relative path on purpose. A harness invokes the plugin CLI from
# settings.json with no tmux context and no plugin env at all, so anything that
# has to search for its library is a failure mode; see section B of the plan.
#
# TMUX_TOOLKIT_DEV - point at a checkout to develop the library against all
# consumers at once. Never set in CI.

if [[ -z "${TK_LOADED:-}" ]]; then
    TK_LOADED=1

    _tk_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -n "${TMUX_TOOLKIT_DEV:-}" && -r "${TMUX_TOOLKIT_DEV%/}/lib/core.sh" ]]; then
        _tk_src="${TMUX_TOOLKIT_DEV%/}/lib"
    fi

    # Order is dependency order: version and opt call tk_tmux; config calls both
    # tk_fresh and tk_opt_*.
    # shellcheck source=core.sh
    source "$_tk_src/core.sh"
    # shellcheck source=tmux.sh
    source "$_tk_src/tmux.sh"
    # shellcheck source=version.sh
    source "$_tk_src/version.sh"
    # shellcheck source=opt.sh
    source "$_tk_src/opt.sh"
    # shellcheck source=log.sh
    source "$_tk_src/log.sh"
    # shellcheck source=json.sh
    source "$_tk_src/json.sh"
    # shellcheck source=sqlite.sh
    source "$_tk_src/sqlite.sh"
    # shellcheck source=config.sh
    source "$_tk_src/config.sh"

    unset _tk_src
fi
