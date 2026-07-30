# shellcheck shell=bash
# notify.sh - fire a user-configured notification.
#
# One implementation for three: tracker's _fire_transition_hook, mesh's
# _fire_mail_hook and resumer's _notify. All three eval a user-supplied string
# and one also posts to ntfy.sh, so the eval and the backgrounding belong in one
# place rather than three.
#
# Options read, for namespace <ns>:
#   @<ns>-on-<event>   shell snippet, receives the arguments positionally
#   @<ns>-ntfy-topic   ntfy.sh topic; posts the body when set

# tk_notify <ns> <event> <arg>...
#
# The snippet runs backgrounded in a subshell, detached from the caller. That is
# deliberate on three counts: a hook must not wait on a user's notify command, a
# slow command must not hold a turn open, and a failing one must not fail the
# hook that fired it.
tk_notify() {
    local ns="$1" event="$2"; shift 2
    local cmd
    cmd="$(tk_opt "@${ns}-on-${event}")"
    [[ -n "$cmd" ]] || return 0
    # `eval "$cmd \"\$@\""`, not `eval "$cmd" "$@"`. All three implementations
    # this replaces use the second form, which splices the arguments into the
    # string being evaluated, so a prompt summary containing a space arrives as
    # two arguments and one containing a quote breaks the parse. Passing "$@"
    # through to the eval'd code keeps them as real positional parameters.
    ( eval "$cmd \"\$@\"" & ) 2>/dev/null
    return 0
}

# tk_notify_push <ns> <message> - post to the configured ntfy.sh topic.
#
# Backgrounded and time-limited: a notification is never worth blocking on, and
# without -m curl will sit on an unreachable network until its own default
# timeout, which is minutes.
tk_notify_push() {
    local ns="$1" msg="$2" topic
    topic="$(tk_opt "@${ns}-ntfy-topic")"
    [[ -n "$topic" ]] || return 0
    tk_have curl || { tk_log warn "tk_notify_push: curl missing, '$topic' unreachable"; return 0; }
    ( curl -s -m 5 -d "$msg" "https://ntfy.sh/${topic}" >/dev/null 2>&1 & ) 2>/dev/null
    return 0
}

# tk_notify_all <ns> <event> <message> [arg]... - both channels.
tk_notify_all() {
    local ns="$1" event="$2" msg="$3"; shift 3
    tk_notify "$ns" "$event" "$msg" "$@"
    tk_notify_push "$ns" "$msg"
}
