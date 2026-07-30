# shellcheck shell=bash
# log.sh - leveled, self-trimming log.
#
# Replaces four copies: three byte-identical _debug_log implementations and
# tmux-worktree's debug_log/error_log pair.
#
# TK_LOG_FILE   - target; defaults to $TK_DIR/debug.log
# TK_LOG_LEVEL  - error|warn|info|debug (default warn)
# TK_LOG_MAX    - trim above this many lines (default 1500)
# TK_LOG_KEEP   - keep this many when trimming (default 1000)
#
# DEBUG_LOG=0|1 is honoured for compatibility with the existing plugins, which
# all read an @<ns>-debug-log option into that name. 1 means debug.

TK_LOG_LEVEL="${TK_LOG_LEVEL:-}"
TK_LOG_FILE="${TK_LOG_FILE:-}"
TK_LOG_MAX="${TK_LOG_MAX:-1500}"
TK_LOG_KEEP="${TK_LOG_KEEP:-1000}"

tk_log_level_n() {
    case "$1" in
        error) printf 1 ;;
        warn)  printf 2 ;;
        info)  printf 3 ;;
        debug) printf 4 ;;
        *)     printf 2 ;;
    esac
}

tk_log_enabled() {
    local want cur
    want="$(tk_log_level_n "$1")"
    if [[ -n "$TK_LOG_LEVEL" ]]; then
        cur="$(tk_log_level_n "$TK_LOG_LEVEL")"
    elif [[ "${DEBUG_LOG:-0}" == "1" ]]; then
        cur=4
    else
        cur=2
    fi
    [[ "$want" -le "$cur" ]]
}

tk_log_file() {
    if [[ -n "$TK_LOG_FILE" ]]; then
        printf '%s' "$TK_LOG_FILE"
    else
        printf '%s/debug.log' "${TK_DIR:-${TMPDIR:-/tmp}}"
    fi
}

# tk_log <level> <msg>...
#
# Trimming is sampled at roughly 1 write in 100 rather than checked on every
# write. The implementations this replaces run `wc -l` on the log for every
# single line, i.e. a fork per log call on a path that fires ~12x per turn.
# $RANDOM needs no state, so sampling costs nothing and still bounds the file.
tk_log() {
    local level="$1"; shift
    tk_log_enabled "$level" || return 0

    local file
    file="$(tk_log_file)"
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$file" 2>/dev/null || return 0

    if [[ $(( RANDOM % 100 )) -eq 0 ]]; then
        local n
        n="$(wc -l < "$file" 2>/dev/null)" || return 0
        n="${n// /}"
        if [[ "${n:-0}" -gt "$TK_LOG_MAX" ]]; then
            tail -n "$TK_LOG_KEEP" "$file" > "$file.tmp" 2>/dev/null \
                && mv -f "$file.tmp" "$file" 2>/dev/null || true
        fi
    fi
    return 0
}

tk_error() { tk_log error "$@"; }
tk_warn()  { tk_log warn  "$@"; }
tk_info()  { tk_log info  "$@"; }
tk_debug() { tk_log debug "$@"; }

# tk_log_trim - force a trim now, for tests and for `doctor`.
tk_log_trim() {
    local file n
    file="$(tk_log_file)"
    [[ -f "$file" ]] || return 0
    n="$(wc -l < "$file" 2>/dev/null)" || return 0
    n="${n// /}"
    if [[ "${n:-0}" -gt "$TK_LOG_MAX" ]]; then
        tail -n "$TK_LOG_KEEP" "$file" > "$file.tmp" 2>/dev/null \
            && mv -f "$file.tmp" "$file" 2>/dev/null || true
    fi
    return 0
}
