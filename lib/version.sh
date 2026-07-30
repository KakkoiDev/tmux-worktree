# shellcheck shell=bash
# version.sh - tmux version detection and comparison.
#
# Replaces four hand-rolled copies (three identical major/minor comparators plus
# tmux-worktree's major-only `cut -d. -f1` one).
#
# Encoding is major*1000 + minor, NOT the concatenated-digits trick used by
# jaclu/tmux-menus. Its tpt_digits_from_string turns "3.10" into 310 and "3.9"
# into 39 and therefore reports 3.9 > 3.10. Suffix handling and memoization are
# worth stealing from that project; the integer encoding is not.
#
# Deliberate deviation from the plan: the good/bad memo lists live in process
# memory only, with no $TK_DIR/vers.cache file. jaclu caches to disk because
# their comparator sources a large helpers file; ours is pure bash arithmetic,
# so a file read would cost more than it saves. The only real cost is the
# `tmux -V` fork, and that is taken lazily so hook paths that never ask for a
# version never pay it. A disk cache would also go stale across a tmux upgrade,
# which is a step in this very plan.

TK_VERS=""        # e.g. 3.5a
TK_VERS_N=""      # e.g. 3005
TK_VERS_SUFFIX="" # e.g. a
TK_VERS_OK=""     # space-delimited memo of satisfied requirements
TK_VERS_NO=""     # space-delimited memo of unsatisfied requirements

# tk_vers_parse <string> - sets TK_P_N and TK_P_SUFFIX.
# bash 3.2 has no namerefs, so the outputs are fixed global names.
tk_vers_parse() {
    local v="$1"
    v="${v#tmux }"          # `tmux -V` output
    v="${v#next-}"          # a next-3.8 build is treated as 3.8
    v="${v%%-*}"            # drop -rc / -devel suffixes
    v="${v## }"; v="${v%% }"

    local head="${v%%.*}" rest minor suffix
    if [[ "$v" == *.* ]]; then
        rest="${v#*.}"
    else
        rest="0"
    fi

    # minor is the leading digits of rest; whatever follows is the suffix.
    minor="${rest%%[!0-9]*}"
    suffix="${rest#"$minor"}"
    suffix="${suffix%%.*}"

    # A non-numeric head means we could not parse it at all.
    case "$head" in
        ''|*[!0-9]*) TK_P_N=0; TK_P_SUFFIX=""; return 1 ;;
    esac
    [[ -n "$minor" ]] || minor=0

    TK_P_N=$(( head * 1000 + minor ))
    TK_P_SUFFIX="$suffix"
    return 0
}

# tk_vers - the running tmux version string, memoized. One fork, taken lazily.
tk_vers() {
    if [[ -z "$TK_VERS" ]]; then
        local raw
        raw="$(tk_tmux -V 2>/dev/null || true)"
        if [[ -z "$raw" ]]; then
            TK_VERS="0.0"; TK_VERS_N=0; TK_VERS_SUFFIX=""
        else
            TK_VERS="${raw#tmux }"
            if tk_vers_parse "$raw"; then
                TK_VERS_N="$TK_P_N"; TK_VERS_SUFFIX="$TK_P_SUFFIX"
            else
                TK_VERS_N=0; TK_VERS_SUFFIX=""
            fi
        fi
    fi
    printf '%s' "$TK_VERS"
}

# tk_vers_ge <x.y[suffix]> - is the running tmux at least this version?
tk_vers_ge() {
    local want="$1"
    [[ -n "$want" ]] || return 0

    case " $TK_VERS_OK " in *" $want "*) return 0 ;; esac
    case " $TK_VERS_NO " in *" $want "*) return 1 ;; esac

    tk_vers >/dev/null

    local rc=1 wn wsuf
    if tk_vers_parse "$want"; then
        wn="$TK_P_N"; wsuf="$TK_P_SUFFIX"
        if [[ "$TK_VERS_N" -gt "$wn" ]]; then
            rc=0
        elif [[ "$TK_VERS_N" -lt "$wn" ]]; then
            rc=1
        elif [[ -z "$wsuf" ]]; then
            # 3.5a satisfies "3.5"; an empty requirement suffix is the floor.
            rc=0
        elif [[ -z "$TK_VERS_SUFFIX" ]]; then
            # 3.5 does not satisfy "3.5a".
            rc=1
        elif [[ "$TK_VERS_SUFFIX" > "$wsuf" || "$TK_VERS_SUFFIX" == "$wsuf" ]]; then
            rc=0
        else
            rc=1
        fi
    fi

    if [[ "$rc" -eq 0 ]]; then
        TK_VERS_OK="$TK_VERS_OK $want"
    else
        TK_VERS_NO="$TK_VERS_NO $want"
    fi
    return "$rc"
}

# tk_vers_require <x.y> <plugin-name> - the loader gate. Message names the
# plugin so a user with five of these installed knows which one complained.
tk_vers_require() {
    local want="${1:-3.0}" who="${2:-tmux-toolkit}"
    tk_vers_ge "$want" && return 0
    printf '%s requires tmux %s+ (found %s)\n' "$who" "$want" "$(tk_vers)" >&2
    return 1
}
