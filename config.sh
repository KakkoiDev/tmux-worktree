# shellcheck shell=bash
# config.sh - one config loader with an mtime-TTL cache.
#
# Replaces the same load_config architecture written four times with four
# different variable lists (~70 hand-written cache-emit lines between them), and
# the mtime-staleness idiom written seven times with seven different TTLs.
#
# Two behaviours are inherited deliberately, both from the copy that got them
# right rather than the original:
#
#  1. Staleness is honoured on the fast path. tmux-agent-tracker's
#     _load_config_fast (scripts/tracker.sh:618) sources the cache
#     unconditionally, so `tmux set -g @agent-tracker-color-idle red` never took
#     effect until the file happened to age out. tmux-agent-resumer's version
#     (scripts/resumer.sh:76) delegates to the real loader and is correct. This
#     is the resumer's.
#
#  2. The cache is validated with `bash -n` before being sourced, and rebuilt
#     rather than reported on failure. mesh's comment explains the stakes: a
#     cache that will not parse, sourced under `set -euo pipefail`, aborts the
#     caller, which takes down every hook, menu, watch and refresh at once,
#     including the one meant to diagnose it.
#
# A spec is VARNAME:@option:default. Everything after the second colon is the
# default, so defaults may contain colons.

TK_CONFIG_TTL="${TK_CONFIG_TTL:-60}"

# First line of every cache. A cache written by a different library version, or
# for a different namespace, is rebuilt rather than sourced. This is the guard
# that matters in practice: the writer here is atomic (tmp + mv -f), so a
# half-written cache is not a real failure mode, but a format change between
# vendored lib/ versions absolutely is.
#
# It also covers a gap in `bash -n`, which is weaker than it looks. Verified on
# bash 5.3 and 3.2: an unterminated quote is caught (rc 2), but an unterminated
# array assignment is NOT --
#
#   printf 'V=(a b\n' > f; bash -n f; echo $?   -> 0
#
# and sourcing that same file aborts the caller. A syntax error cannot be
# trapped in the current shell, so the only defence is to not source anything
# whose provenance is unconfirmed.
TK_CONFIG_MARKER="# tk-config v1"

tk_config_file() { printf '%s/config_cache' "${TK_DIR:?tk_init not called}"; }

# tk_config_prefix <ns> - "agent-mesh" -> "@agent-mesh-"
tk_config_prefix() { printf '@%s-' "$1"; }

tk_config_invalidate() { rm -f "$(tk_config_file)" 2>/dev/null || true; return 0; }

# tk_config_fresh [ttl] - is the cache younger than ttl?
tk_config_fresh() { tk_fresh "$(tk_config_file)" "${1:-$TK_CONFIG_TTL}"; }

# tk_config_cache_valid <file> <ns> - is this cache ours, and does it parse?
tk_config_cache_valid() {
    [[ -r "$1" ]] || return 1
    local first
    read -r first < "$1" 2>/dev/null || return 1
    [[ "$first" == "$TK_CONFIG_MARKER $2" ]] || return 1
    bash -n "$1" 2>/dev/null
}

# tk_config_load <ns> <ttl> <spec>...
tk_config_load() {
    local ns="$1" ttl="$2"; shift 2
    local cache
    cache="$(tk_config_file)"

    if tk_fresh "$cache" "$ttl" && tk_config_cache_valid "$cache" "$ns"; then
        # shellcheck disable=SC1090
        source "$cache"
        return 0
    fi
    rm -f "$cache" 2>/dev/null || true

    # One fork for the whole namespace instead of one per option.
    tk_opt_bulk "$(tk_config_prefix "$ns")"

    local spec var opt default rest
    for spec in "$@"; do
        var="${spec%%:*}"
        rest="${spec#*:}"
        opt="${rest%%:*}"
        if [[ "$rest" == *:* ]]; then default="${rest#*:}"; else default=""; fi
        tk_opt_into "$var" "$opt" "$default"
    done

    # No data dir means the plugin is not installed on this machine. Read the
    # options, but create nothing: a harness hook on an uninstalled box must be
    # inert, not a directory-creating side effect.
    [[ -d "${TK_DIR:-}" ]] || return 0

    # Atomic write, safe for concurrent hook invocations. The cache is cosmetic,
    # so an unwritable dir must never fail a hook.
    {
        {
            printf '%s %s\n' "$TK_CONFIG_MARKER" "$ns"
            for spec in "$@"; do
                var="${spec%%:*}"
                eval "printf '%s=%s\\n' \"\$var\" \"\$(tk_cq \"\${$var:-}\")\""
            done
        } > "$cache.tmp" && mv -f "$cache.tmp" "$cache"
    } 2>/dev/null || true
    return 0
}

# tk_config_fast <ns> <ttl> <spec>... - alias kept so the two call styles the
# plugins already have both land on the correct, staleness-honouring path.
tk_config_fast() { tk_config_load "$@"; }
