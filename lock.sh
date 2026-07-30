# shellcheck shell=bash
# lock.sh - a portable mutex.
#
# Replaces tmux-agent-resumer's _try_lock/_unlock, the only locking anywhere in
# the five plugins.
#
# mkdir is the primitive, because there is no portable lock binary: macOS has
# lockf(1) and a deprecated shlock(1) but no flock(1); Linux has flock(1) but no
# lockf(1). mkdir is atomic on every POSIX filesystem, needs nothing installed,
# and works identically on both.
#
# Rejected alternatives, so nobody re-litigates them:
#   * lockf(1) *runs a command* under the lock. It has no acquire/hold/release
#     form that composes with a shell function, so it cannot implement this API.
#   * tmux `wait-for -L/-U` fails outright when there is no client, which is
#     exactly the case for a harness hook, and its channel is never released if
#     the holder dies. Unusable as a mutex.
#
# The one real defect of a mkdir lock is that the OS does not release it when the
# holder dies. The resumer's version handled that with a flat 120s steal, so a
# crashed holder blocked everything for two minutes. This writes the holder's pid
# into the directory and steals immediately once that pid is gone.

TK_LOCK_STALE="${TK_LOCK_STALE:-120}"

tk_lock_dir() { printf '%s/.lock.%s' "${TK_DIR:?tk_init not called}" "$1"; }

# tk_lock <name> [stale_secs] - acquire, or return 1 immediately.
#
# Non-blocking on purpose. Every caller in this codebase is on a status-render or
# hook path where waiting is worse than skipping a cycle.
tk_lock() {
    local name="$1" stale="${2:-$TK_LOCK_STALE}" dir
    dir="$(tk_lock_dir "$name")"
    mkdir -p "$(dirname "$dir")" 2>/dev/null || true

    if mkdir "$dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$dir/pid" 2>/dev/null || true
        return 0
    fi

    # Held. Steal it only if the holder is provably gone, or it has aged out.
    # `read` returns non-zero at EOF without a trailing newline even though it
    # has assigned the variable, so its status must not be treated as "no pid".
    local holder=""
    if [[ -r "$dir/pid" ]]; then
        read -r holder < "$dir/pid" 2>/dev/null || true
    fi
    local dead=0
    if [[ -n "$holder" ]]; then
        # A pid that no longer exists means the holder died without unlocking,
        # which the OS will never tell us about for a mkdir lock.
        kill -0 "$holder" 2>/dev/null || dead=1
    else
        # No pid file: either a pre-pid-era lock or a partial acquire. Fall back
        # to age alone.
        [[ "$(tk_age "$dir")" -ge "$stale" ]] && dead=1
    fi
    [[ "$dead" -eq 0 && "$(tk_age "$dir")" -ge "$stale" ]] && dead=1
    [[ "$dead" -eq 1 ]] || return 1

    tk_log warn "tk_lock: stealing stale lock '$name' (holder=${holder:-unknown})"
    rm -rf "$dir" 2>/dev/null || true
    if mkdir "$dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$dir/pid" 2>/dev/null || true
        return 0
    fi
    return 1
}

tk_unlock() {
    local dir
    dir="$(tk_lock_dir "$1")"
    rm -rf "$dir" 2>/dev/null || true
    return 0
}

# tk_locked <name> - is it currently held by a live process?
tk_locked() {
    local dir holder
    dir="$(tk_lock_dir "$1")"
    [[ -d "$dir" ]] || return 1
    [[ -r "$dir/pid" ]] || return 0
    read -r holder < "$dir/pid" 2>/dev/null || true
    [[ -n "$holder" ]] || return 0
    kill -0 "$holder" 2>/dev/null
}

# tk_with_lock <name> <cmd>... - run cmd under the lock, releasing on any exit.
#
# The trap is the point: a caller that returns early, or dies on `set -e`, still
# releases. Returns 1 without running cmd when the lock is held.
tk_with_lock() {
    local name="$1"; shift
    tk_lock "$name" || return 1
    local rc=0
    # A subshell so the trap cannot outlive this call or clobber a caller's own.
    ( trap 'tk_unlock "$name"' EXIT INT TERM; "$@" ) || rc=$?
    tk_unlock "$name"
    return "$rc"
}
