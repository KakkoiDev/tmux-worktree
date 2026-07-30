# shellcheck shell=bash
# opt.sh - tmux option access.
#
# Replaces five dialects of the same function: three byte-identical
# get_tmux_option copies (tracker, resumer, mesh), tmux-worktree's variant with
# a hand-copied `if [ -n "$TMUX_SOCKET" ]` fork, and tmux-session-order's
# printf/${v:-$2} version.
#
# ── Why there is no tk_opt_fmt ───────────────────────────────────────
#
# The plan proposed `#{?@o,#{@o},default}` as a one-round-trip option-with-
# default. Probed on tmux 3.5a, it is wrong twice over:
#
#   set -g @o ""  -> #{?@o,#{@o},DEFAULT} yields DEFAULT   (cannot tell unset
#                                                           from set-empty)
#   set -g @o "0" -> #{?@o,#{@o},DEFAULT} yields DEFAULT   (!!)
#
# `#{?X,a,b}` is false when X is empty *or the string "0"*. So that form
# silently substitutes the default for any option a user legitimately sets to
# zero: @agent-mesh-debug-log 0, @agent-tracker-completed-delay 0, and so on.
# It is a footgun with five callers, so it is not offered. Use tk_opt_many when
# the goal is one round trip for several options; it uses no conditionals and so
# has no truthiness bug.

TK_OPTS_BLOB=""
TK_OPTS_PREFIX=""

# tk_opt <option> [default] - the faithful drop-in. Empty or unset yields the
# default, matching every implementation this replaces.
tk_opt() {
    local value
    value="$(tk_tmux show-option -gqv "$1" 2>/dev/null)" || true
    printf '%s' "${value:-${2:-}}"
}

# tk_opt_set <option> <value>
tk_opt_set() { tk_tmux set-option -g "$1" "$2" 2>/dev/null || true; }

# tk_opt_set_quiet <option> <value> - -gq, for values written on a hot path
# where a failure must never surface in a harness hook.
tk_opt_set_quiet() { tk_tmux_silent set-option -gq "$1" "$2"; }

tk_opt_unset() { tk_tmux set-option -gu "$1" 2>/dev/null || true; }

# tk_opt_many <sep> <option>... - one display-message round trip for N options,
# printing their raw values joined by <sep>. No conditionals, so an option set
# to "0" or "" comes back exactly as stored; the caller applies its own defaults.
#
# Pick a <sep> that cannot occur in the values. A tab is usually right.
tk_opt_many() {
    local sep="$1"; shift
    [[ "$#" -gt 0 ]] || return 0
    local fmt="" o
    for o in "$@"; do
        if [[ -n "$fmt" ]]; then fmt="$fmt$sep#{$o}"; else fmt="#{$o}"; fi
    done
    tk_tmux display-message -p "$fmt" 2>/dev/null || true
}

# ── bulk namespace read ──────────────────────────────────────────────
#
# One `show-options -g` fork for an entire namespace, instead of one fork per
# option. tmux-agent-resumer's cold config load is 25 forks today.
#
# Idea from jaclu/tmux-menus (scripts/utils/tmux.sh:106 and :121), including its
# trailing-space match, which is load-bearing: a plain prefix test makes
# @ns-empty also match @ns-empty-extra.
#
# Unlike a format read, this DOES distinguish unset from set-empty: an unset
# user option does not appear in the output at all, while a set-empty one
# appears as `@name ''`.

# tk_opt_bulk <prefix> - populate the in-process blob from the live server.
# <prefix> is matched literally at the start of the line, e.g. "@agent-mesh-".
tk_opt_bulk() {
    local prefix="$1" raw
    raw="$(tk_tmux show-options -g 2>/dev/null | grep "^$prefix" 2>/dev/null)" || raw=""
    # A leading newline means the "\n<name> " match below works for line 1 too.
    TK_OPTS_BLOB=$'\n'"$raw"
    TK_OPTS_PREFIX="$prefix"
}

# tk_opt_bulk_save <prefix> <file> - same read, persisted so separate processes
# (each harness hook is a fresh one) share the single fork.
tk_opt_bulk_save() {
    local prefix="$1" file="$2"
    tk_opt_bulk "$prefix"
    {
        printf '%s\n' "${TK_OPTS_BLOB#$'\n'}" > "$file.tmp" && mv -f "$file.tmp" "$file"
    } 2>/dev/null || true
    return 0
}

# tk_opt_bulk_load <prefix> <file> - load a saved blob without touching tmux.
# $(<file) is a bash builtin read, not a fork.
tk_opt_bulk_load() {
    [[ -r "$2" ]] || return 1
    local content
    content="$(<"$2")" || return 1
    TK_OPTS_BLOB=$'\n'"$content"
    TK_OPTS_PREFIX="$1"
    return 0
}

# tk_opt_raw <option> - the option's rendered form from the blob, or the
# sentinel TK_UNSET when the option does not appear. Internal.
tk_opt_raw() {
    local opt="$1" t
    t="${TK_OPTS_BLOB#*$'\n'"$opt" }"
    if [[ "$t" == "$TK_OPTS_BLOB" ]]; then
        printf 'TK_UNSET'
        return 1
    fi
    printf '%s' "${t%%$'\n'*}"
}

# tk_opt_cached <option> [default] - read from the blob, falling back to a real
# fork when the rendered value carries escapes.
#
# `show-options -g` renders values with an escaping scheme that cannot be undone
# by sequential global substitution. Verified on 3.5a:
#
#   value  a\b      renders  a\\b          (backslash doubled)
#   value  a\tb     renders  a\\tb         (two chars: backslash, t)
#   value  a<TAB>b  renders  a\tb          (one char: tab)
#
# So `\\`->`\` then `\t`->TAB turns the literal `a\tb` into `a<TAB>b`. Undoing
# it correctly needs a single left-to-right pass, which in bash 3.2 is a
# character scan. Rather than carry that, we detect the case and ask tmux for
# the authoritative value. Escapes appear only in exotic values (shell snippets
# in @<ns>-on-mail, paths with spaces), so the one-fork fast path still covers
# keybindings, colours, icons, numbers and on/off, which is nearly everything.
tk_opt_cached() {
    local opt="$1" default="${2:-}" raw

    # A blob loaded for one namespace cannot answer for another: every option
    # outside the loaded prefix is absent from it and would silently read as
    # unset. That is a live mistake for the D-2 shims, where one process may
    # touch two plugins' namespaces, so it is a warning rather than a shrug.
    if [[ -n "$TK_OPTS_PREFIX" && "$opt" != "$TK_OPTS_PREFIX"* ]]; then
        tk_log warn "tk_opt_cached: '$opt' is outside the loaded namespace '$TK_OPTS_PREFIX'; reading it directly"
        printf '%s' "$(tk_opt "$opt" "$default")"
        return 0
    fi

    if ! raw="$(tk_opt_raw "$opt")"; then
        printf '%s' "$default"
        return 0
    fi

    case "$raw" in
        "''")
            # Explicitly set to empty. Same result as unset, matching tk_opt.
            printf '%s' "$default"
            ;;
        *\\*|\"*)
            # Escaped or double-quoted: get the real value from tmux.
            printf '%s' "$(tk_opt "$opt" "$default")"
            ;;
        *)
            printf '%s' "${raw:-$default}"
            ;;
    esac
}

# tk_opt_names [prefix] - every option name present in the blob, one per line.
# Feeds the T4 contract test "no option is loaded and then never read".
tk_opt_names() {
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        printf '%s\n' "${line%% *}"
    done <<EOF
${TK_OPTS_BLOB#$'\n'}
EOF
}

# ── assign-into ──────────────────────────────────────────────────────

# tk_opt_into <varname> <option> [default]
#
# bash 3.2 has no namerefs, so this is an eval. The varname is validated first:
# an option value must never be able to name the variable it lands in.
# shellcheck disable=SC2034  # $val is read by the eval at the end
tk_opt_into() {
    local var="$1" opt="$2" default="${3:-}"
    case "$var" in
        ''|*[!A-Za-z0-9_]*|[0-9]*)
            tk_die "tk_opt_into: invalid variable name '$var'" ;;
    esac
    local val
    if [[ -n "$TK_OPTS_BLOB" ]]; then
        val="$(tk_opt_cached "$opt" "$default")"
    else
        val="$(tk_opt "$opt" "$default")"
    fi
    eval "$var=\$val"
}
