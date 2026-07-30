# shellcheck shell=bash
# core.sh - namespace init, paths, platform primitives.
#
# Sourced, never executed. Every exported symbol is tk_-prefixed so this file
# can be sourced alongside a plugin's own helpers.sh without either shadowing
# the other. Callers run under `set -euo pipefail`, so no reference here may be
# unguarded and no failing command may escape.

# ── plugin/library paths ─────────────────────────────────────────────

# Set at source time so callers get the paths without an explicit init.
TK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TK_PLUGIN_DIR="$(cd "$TK_LIB_DIR/.." && pwd)"

tk_lib_dir()    { printf '%s' "$TK_LIB_DIR"; }
tk_plugin_dir() { printf '%s' "$TK_PLUGIN_DIR"; }

# ── namespace init ───────────────────────────────────────────────────

# tk_init <ns> [data_dir]
#
# <ns> is the plugin's option namespace without the @ or trailing dash, e.g.
# `agent-mesh` for @agent-mesh-*. An explicit data_dir wins, because plugins
# have already resolved their own env override by the time they call this.
tk_init() {
    TK_NS="${1:?tk_init: namespace required}"
    TK_DIR="${2:-${TK_DIR:-$HOME/.tmux-$TK_NS}}"
    TK_STATE="${TK_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/tmux-toolkit}"
}

# ── failure ──────────────────────────────────────────────────────────

tk_die() { printf '%s\n' "$*" >&2; exit 1; }

# tk_require <cmd>... - die naming every missing command, not just the first.
tk_require() {
    local missing="" c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    [[ -z "$missing" ]] || tk_die "missing required command(s):$missing"
}

tk_have() { command -v "$1" >/dev/null 2>&1; }

# ── platform primitives ──────────────────────────────────────────────

# Memoize `uname`: this is on the hook path, which fires ~12x per turn.
TK_UNAME=""
tk_uname() {
    [[ -n "$TK_UNAME" ]] || TK_UNAME="$(uname 2>/dev/null || printf 'unknown')"
    printf '%s' "$TK_UNAME"
}

tk_now() { date +%s; }

# stat(1) is not portable: -f %m is BSD, -c %Y is GNU.
tk_mtime() {
    [[ -e "$1" ]] || return 1
    case "$(tk_uname)" in
        Darwin) stat -f %m "$1" 2>/dev/null ;;
        *)      stat -c %Y "$1" 2>/dev/null ;;
    esac
}

# `date -r <epoch>` is BSD-only; on Linux it means "read the file", so the GNU
# branch has to use -d @epoch or timestamps print blank.
tk_fmt_time() {
    local fmt="${2:-%H:%M:%S}"
    case "$(tk_uname)" in
        Darwin) date -r "$1" "+$fmt" 2>/dev/null ;;
        *)      date -d "@$1" "+$fmt" 2>/dev/null ;;
    esac
}

# tk_age <file> - seconds since mtime. A missing file is infinitely old, which
# is what every caller wants for a cache-staleness test, so report a number
# rather than an error they would each have to handle.
tk_age() {
    local m
    if ! m="$(tk_mtime "$1" 2>/dev/null)" || [[ -z "$m" ]]; then
        printf '%s' 999999999
        return 0
    fi
    printf '%s' "$(( $(tk_now) - m ))"
}

# tk_fresh <file> <ttl> - true when the file exists and is younger than ttl.
tk_fresh() {
    local age
    age="$(tk_age "$1")"
    [[ "$age" -lt "$2" ]]
}

# ── shell quoting ────────────────────────────────────────────────────

# Single-quote a value for a file that will be sourced. @<ns>-on-mail and
# friends are user-supplied shell snippets, so they contain quotes; unescaped
# they produce a cache that fails to parse, and a bare `source` under
# `set -euo pipefail` then kills every hook, menu and refresh at once.
tk_cq() {
    local q="'" esc
    esc="${1//$q/$q\\$q$q}"
    printf "'%s'" "$esc"
}

# ── library version ──────────────────────────────────────────────────

TK_VERSION=""
tk_lib_version() {
    if [[ -z "$TK_VERSION" ]]; then
        if [[ -r "$TK_LIB_DIR/VERSION" ]]; then
            read -r TK_VERSION < "$TK_LIB_DIR/VERSION" || TK_VERSION="0.0.0"
        else
            TK_VERSION="0.0.0"
        fi
    fi
    printf '%s' "$TK_VERSION"
}

# tk_require_version <min> - guard against a plugin vendoring a lib/ older than
# the API it calls. Compares major.minor.patch numerically.
tk_require_version() {
    local want="$1" have
    have="$(tk_lib_version)"
    local hw hm hp ww wm wp
    hw="${have%%.*}"; hm="${have#*.}"; hp="${hm#*.}"; hm="${hm%%.*}"; hp="${hp%%.*}"
    ww="${want%%.*}"; wm="${want#*.}"; wp="${wm#*.}"; wm="${wm%%.*}"; wp="${wp%%.*}"
    local hn wn
    hn=$(( ${hw:-0} * 1000000 + ${hm:-0} * 1000 + ${hp:-0} ))
    wn=$(( ${ww:-0} * 1000000 + ${wm:-0} * 1000 + ${wp:-0} ))
    [[ "$hn" -ge "$wn" ]] && return 0
    tk_die "tmux-toolkit $want+ required, vendored lib/ is $have (run: make sync)"
}
