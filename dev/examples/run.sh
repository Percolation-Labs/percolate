#!/usr/bin/env bash
# Run the worked examples and print what they actually return.
#
#   ./run.sh              # fixture, then all of them
#   ./run.sh 03           # one
#   DB=p8graph ./run.sh   # another database in the same container
#   DSN="postgres://…" ./run.sh
#
# Everything the docs page quotes comes from here. A page showing output nobody
# produced is the one failure mode a cookbook has, so the page is written from
# this script's transcript rather than from what the query ought to return.
#
# Each example runs inside its own transaction and rolls back, so they are
# order-independent and the fixture survives. `set local role` needs the
# transaction anyway.
set -euo pipefail
CONTAINER="${CONTAINER:-p8-dev-db}"
# The database, because `11-graph` needs the compiled graph algorithms and a
# stack still running the published image does not have them until
# dev/build-image.sh has been run. Pointing at a database made by
# dev/reload.sh is the fast way to see them work.
DB="${DB:-p8dev}"
DSN="${DSN:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run() {   # run <file> <wrap-in-transaction>
    local sql
    if [ "$2" = yes ]; then
        sql="begin;
$(cat "$1")
rollback;"
    else
        sql="$(cat "$1")"
    fi
    if [ -n "$DSN" ]; then
        printf '%s\n' "$sql" | psql "$DSN" -v ON_ERROR_STOP=1 -q
    else
        printf '%s\n' "$sql" | docker exec -i "$CONTAINER" \
            psql -U p8 -d "$DB" -v ON_ERROR_STOP=1 -q
    fi
}

if [ $# -eq 0 ]; then
    echo "### fixture"
    run "$HERE/00-harbour.sql" no
    files=("$HERE"/[0-9][0-9]-*.sql)
else
    files=("$HERE/$1"-*.sql)
fi

for f in "${files[@]}"; do
    case "$(basename "$f")" in 00-*) continue ;; esac
    echo
    echo "=============================================================="
    echo "### $(basename "$f" .sql)"
    echo "=============================================================="
    run "$f" yes
done
