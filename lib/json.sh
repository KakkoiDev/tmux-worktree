# shellcheck shell=bash
# json.sh - reading harness hook payloads from stdin JSON.
#
# Replaces three _json_val copies. Two of them (tracker, resumer) are
# string-slice only, which silently returns nothing for a harness that
# pretty-prints or puts a space after the colon. mesh's jq-first version is the
# one worth keeping, and its comment explains why the fallback still exists:
# SessionEnd must still deregister on a machine without jq.

TK_JQ=""
tk_jq() {
    if [[ -z "$TK_JQ" ]]; then
        if command -v jq >/dev/null 2>&1; then TK_JQ=yes; else TK_JQ=no; fi
    fi
    [[ "$TK_JQ" == "yes" ]]
}

tk_need_jq() { tk_jq || tk_die "jq is required for this command"; }

# tk_json <json> <key> - top-level string value.
#
# The no-jq fallback matches only "key":"value" with no whitespace and no
# escapes. It logs at warn so a silent empty is attributable rather than
# mysterious.
tk_json() {
    if tk_jq; then
        printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null || true
        return 0
    fi
    tk_log warn "tk_json: jq missing, using degraded string match for '$2'"
    local t="${1#*\"$2\":\"}"
    [[ "$t" == "$1" ]] && return 0
    printf '%s' "${t%%\"*}"
}

# tk_json_bool <json> <key> - true when the key is JSON true. Needs its own
# probe because tk_json only matches quoted values.
tk_json_bool() {
    printf '%s' "$1" | grep -qE "\"$2\"[[:space:]]*:[[:space:]]*true"
}

# tk_json_path <json> <a.b.c> - nested access. jq only; returns empty without it.
#
# This is what removes tmux-agent-resumer's three inline python3 heredocs
# (scripts/resumer.sh:499, :635, :664), each ~40ms of interpreter startup on the
# status-render path.
tk_json_path() {
    tk_jq || { tk_log warn "tk_json_path: jq missing, '$2' unavailable"; return 0; }
    printf '%s' "$1" | jq -r --arg p "$2" '
        reduce ($p | split(".")[]) as $k (.; if . == null then null else .[$k]? end)
        | if . == null then empty else . end' 2>/dev/null || true
}

# tk_json_str_or_obj <json> <key> [subkey]
#
# Harnesses disagree on shape: `"model": "opus"` in some payloads,
# `"model": {"id": "opus"}` in others. The type has to be tested before it is
# indexed, because .model.id on a string is an error in jq, not null.
tk_json_str_or_obj() {
    local key="$2" sub="${3:-id}"
    tk_jq || return 0
    printf '%s' "$1" | jq -r --arg k "$key" --arg s "$sub" '
        .[$k] as $v
        | (if ($v | type) == "object" then $v[$s] else $v end)
        | strings' 2>/dev/null || true
}

# tk_json_esc <string> - escape for embedding in a JSON string literal.
#
# `jq -Rs .` emits the complete literal including its surrounding quotes, which
# are then stripped with parameter expansion. Note that `jq -Rs '.[1:-1]'` looks
# like it would do the same and does not: it slices the string's *characters*,
# so `say "hi"` comes back as `ay \"hi`.
tk_json_esc() {
    if tk_jq; then
        local q
        q="$(printf '%s' "$1" | jq -Rs . 2>/dev/null)" || q=""
        if [[ -n "$q" ]]; then
            q="${q#\"}"; q="${q%\"}"
            printf '%s' "$q"
            return 0
        fi
    fi
    # Fallback covers every escape a harness payload realistically carries.
    # Control characters below 0x20 other than tab/newline/return are not
    # escaped here; with jq present they are.
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# tk_json_read - the whole payload from stdin.
#
# `cat`, not `read -r`: a harness that pretty-prints its payload sends many
# lines, and reading only the first one drops every field.
tk_json_read() { cat; }
