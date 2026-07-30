# shellcheck shell=bash
# sqlite.sh - sqlite3 CLI wrappers.
#
# Replaces three sql/sql_esc copies and four hand-written WAL+busy_timeout
# preambles.
#
# ── The db is a parameter, not a global ──────────────────────────────
#
# All three existing implementations close over a bare $DB. That is why
# tmux-agent-mesh carries a six-line comment at scripts/mesh.sh:9 explaining
# that an unprefixed name points tmux-agent-tracker at mesh.db and kills its
# hooks with "no such table: sessions", and why its isolation.bats spends four
# tests policing the env namespace. Passing the db explicitly deletes the whole
# bug class.
#
# No parameter-binding layer: the sqlite3 CLI has no bind, and .param is not in
# every build. Quote-doubling via tk_sql_esc is the only portable option.

TK_SQL_TIMEOUT="${TK_SQL_TIMEOUT:-100}"

# tk_sql <db> <sql>...
tk_sql() {
    local db="$1"; shift
    printf '.timeout %s\n%s\n' "$TK_SQL_TIMEOUT" "$*" | sqlite3 "$db"
}

# tk_sql_sep <db> <sep> <sql>...
tk_sql_sep() {
    local db="$1" sep="$2"; shift 2
    printf '.timeout %s\n%s\n' "$TK_SQL_TIMEOUT" "$*" | sqlite3 -separator "$sep" "$db"
}

# tk_sql_json <db> <sql>... - always valid JSON; an empty result is [], not "".
tk_sql_json() {
    local db="$1"; shift
    local out
    out="$(printf '.timeout %s\n.mode json\n%s\n' "$TK_SQL_TIMEOUT" "$*" | sqlite3 "$db")"
    printf '%s' "${out:-[]}"
}

# tk_sql_esc <string> - double single quotes for a SQL literal.
tk_sql_esc() { local q="'"; printf '%s' "${1//$q/$q$q}"; }

# tk_sql_init <db> <ddl>
#
# WAL plus a busy_timeout is mandatory, not tuning: without it, concurrent
# harness hooks hit SQLITE_BUSY under any load. Prepended here so no caller has
# to remember it.
#
# CREATE TABLE IF NOT EXISTS only. This function will never emit a DROP: the
# tracker's `DROP TABLE IF EXISTS sessions` on every plugin load is exactly the
# bug D-9 removes, and a shared helper must not make it easy to reintroduce.
tk_sql_init() {
    local db="$1" ddl="$2"
    case "$ddl" in
        *DROP\ TABLE*|*drop\ table*)
            tk_die "tk_sql_init: refusing DDL containing DROP TABLE (see D-9)" ;;
    esac
    mkdir -p "$(dirname "$db")" 2>/dev/null || true
    sqlite3 "$db" <<SQL
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=$TK_SQL_TIMEOUT;
$ddl
SQL
}

# tk_sql_table_exists <db> <table>
tk_sql_table_exists() {
    local out
    out="$(tk_sql "$1" "SELECT name FROM sqlite_master WHERE type='table' AND name='$(tk_sql_esc "$2")';" 2>/dev/null)" || return 1
    [[ -n "$out" ]]
}

# tk_sql_has_column <db> <table> <column> - for migration ladders.
tk_sql_has_column() {
    local out
    out="$(tk_sql "$1" "SELECT 1 FROM pragma_table_info('$(tk_sql_esc "$2")') WHERE name='$(tk_sql_esc "$3")';" 2>/dev/null)" || return 1
    [[ -n "$out" ]]
}
