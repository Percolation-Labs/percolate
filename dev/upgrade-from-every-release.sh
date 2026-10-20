#!/usr/bin/env bash
# Can a database at EVERY released version reach this one?
#
#     dev/upgrade-from-every-release.sh
#
# The other two upgrade gates start from the newest tag only (`tail -1` of the
# tag list), and this build ships an upgrade script from every tag -- so five of
# the six 0.2.0 scripts had never run. They failed: 0.1.1 and 0.1.2 on the
# status rename (`runs_status_check ... is violated by some row`), 0.1.3 to
# 0.1.5 on `column "recall_count" does not exist`, because build-sql.py
# prepended only the migration named <old>--<this>, and the older hops in
# specs/migrations/ were read by nothing.
#
# So: one database per tag, installed from that tag's own SQL, carrying a
# finished workflow run -- the row the status rename exists for -- then
# upgraded with this tree's script, in a database that has had the superuser
# file an upgrader runs (dev/image-init/00-superuser.sql; dev/upgrade-with-data.sh
# rehearses that the update refuses without it).
# Lean by design: it asks "does every path RUN and keep its rows", and leaves
# "does it converge" and "does the data survive administration" to the other
# two, which ask them of the newest tag in depth.
set -euo pipefail
cd "$(dirname "$0")/.."

# After the container this run grades, for dev/upgrade-with-data.sh's reason.
C="${UPGC_ALL:-${CONTAINER:-p8}-upgrade-all}"
V=$(sed -n "s/^default_version = '\(.*\)'/\1/p" extension/percolate/percolate.control)
TAGS=$(git tag --list 'v*' | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
       | grep -v "^$V$" | sort -t. -k1,1n -k2,2n -k3,3n)
[ -n "$TAGS" ] || { echo "nothing published below $V -- no upgrade to test yet."; exit 0; }
PREV=$(echo "$TAGS" | tail -1)
EXT=/usr/share/postgresql/19/extension

cleanup() { docker rm -f -v "$C" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
# The newest published image: its parser is what an upgrader has, and every
# older version's SQL has to install on it for this question to be asked.
# Pulled first: a published tag can be rebuilt (19-0.2.20 was, on 1 October), and
# `docker run` would start whatever copy this machine cached.
docker pull -q "percolationlabs/percolate-postgres:19-$PREV" >/dev/null
docker run -d --name "$C" -e POSTGRES_USER=p8 -e POSTGRES_PASSWORD=p8 \
    -e POSTGRES_DB=percolate "percolationlabs/percolate-postgres:19-$PREV" >/dev/null
# TCP, for the reason dev/ci-database.sh spells out on its readiness loop.
for _ in $(seq 1 90); do
    docker exec -e PGPASSWORD=p8 "$C" psql -h 127.0.0.1 -U p8 -d percolate -tAc \
        "select 1 from pg_extension where extname='percolate'" 2>/dev/null | grep -q 1 && break
    sleep 2
done

q() { docker exec -i "$C" psql -U p8 -d "$1" -v ON_ERROR_STOP=1 -q "${@:2}"; }
docker cp "extension/percolate/sql/percolate--$V.sql" "$C:$EXT/" >/dev/null
docker cp extension/percolate/percolate.control "$C:$EXT/" >/dev/null
docker cp dev/image-init/00-superuser.sql "$C:/tmp/00-superuser.sql" >/dev/null

failed=0
for old in $TAGS; do
    db="upg_${old//./_}"
    up="extension/percolate/sql/percolate--$old--$V.sql"
    [ -f "$up" ] || { echo "  $old: $up is missing -- run extension/percolate/build-sql.py"; failed=1; continue; }
    tmp=$(mktemp)
    git show "v$old:extension/percolate/sql/percolate--$old.sql" > "$tmp"
    # mktemp makes it 0600 and `docker cp` keeps the mode, so the server could
    # not read it: "Permission denied" on every tag, which reads like a broken
    # release and is a broken copy.
    chmod 644 "$tmp"
    docker cp "$tmp" "$C:$EXT/percolate--$old.sql" >/dev/null; rm -f "$tmp"
    docker cp "$up" "$C:$EXT/" >/dev/null

    q percolate -c "create database $db" >/dev/null
    # The image's superuser step, once, before the old install: every statement
    # in it was already true of a database 0.1.x installed into, or is one the
    # old release never reached for (it installs as app_owner, which keeps
    # set_config), so running it first is the order a new database gets.
    q "$db" -f /tmp/00-superuser.sql >/dev/null
    if ! out=$(q "$db" -c "set client_min_messages = warning" -c "set role app_owner" \
                   -c "create extension percolate version '$old'" 2>&1); then
        echo "  $old: its own release no longer installs on the $PREV image:"
        echo "$out" | grep -m1 ERROR; failed=1; continue
    fi
    # A FINISHED run, which is what the status rename has to carry across.
    q "$db" -c "select workflow.define_yaml(\$y\$
name: upg
steps:
  - id: now
    sql: {function: p8ql, args: ['SELECT now()']}
\$y\$)" -c "select workflow.start_workflow('upg','{}'::jsonb)" >/dev/null
    if out=$(q "$db" -c "set client_min_messages = warning" -c "set role app_owner" \
                 -c "alter extension percolate update to '$V'" 2>&1); then
        got=$(q "$db" -tAc "select extversion from pg_extension where extname='percolate'")
        runs=$(q "$db" -tAc "select count(*) from workflow.runs r
                              join workflow.lifecycle_states s on s.state = r.status and s.is_success")
        if [ "$got" = "$V" ] && [ "$runs" = "1" ]; then
            echo "  $old -> $V  ok"
        else
            echo "  $old -> $V  FAILED: at $got, with $runs finished run(s) where 1 was written"; failed=1
        fi
    else
        echo "  $old -> $V  FAILED: $(echo "$out" | grep -m1 ERROR)"; failed=1
    fi
done
exit $failed
