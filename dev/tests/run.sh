#!/usr/bin/env bash
# Run every test in the three surfaces, in order, against a live database.
#
#   ./run.sh                          # against the compose stack
#   DSN="postgres://…" ./run.sh       # against anything else
#   ./run.sh query                    # one surface
#
# Exits nonzero on the first failure, so it works as a CI gate alongside
# ../../surface.sql. The two are complementary and neither replaces the other:
# surface.sql asks "does every promised capability EXIST"; this asks "does it
# still BEHAVE the way the spec promised".
set -euo pipefail

CONTAINER="${CONTAINER:-p8-experiment-pg19}"
DSN="${DSN:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The order is deliberate: RBAC first, because if row-level security is not
# actually on, every later assertion about who-sees-what is meaningless.
# `content` follows the two it depends on -- it writes the corpus `query`
# reads and starts the runs `workflow` executes -- and `agentic` runs last: it
# binds the others rather than adding a concern of its own, so a failure there
# is worth reading only once they are green.
SURFACES=("${@:-rbac query workflow content agentic}")

run_sql() {
    if [ -n "$DSN" ]; then
        psql "$DSN" -v ON_ERROR_STOP=1 -q -f "$1"
    else
        docker exec -i "$CONTAINER" psql -U p8 -d p8experiment -v ON_ERROR_STOP=1 -q < "$1"
    fi
}

failed=0
for surface in ${SURFACES[@]}; do
    [ -d "$HERE/$surface" ] || { echo "no such surface: $surface" >&2; exit 2; }
    echo
    echo "=== ${surface} ==============================================="
    for f in "$HERE/$surface"/*.sql; do
        [ -e "$f" ] || continue
        printf '  %-34s ' "$(basename "$f")"
        if out=$(run_sql "$f" 2>&1); then
            echo "ok"
            echo "$out" | grep '^NOTICE:' | sed 's/^NOTICE:  /      /' || true
        else
            echo "FAILED"
            echo "$out" | sed 's/^/      /'
            failed=1
        fi
    done
done

echo
if [ "$failed" -ne 0 ]; then
    echo "FAILED -- a guarantee the specs make is no longer held."
    exit 1
fi
echo "All surfaces passed."
