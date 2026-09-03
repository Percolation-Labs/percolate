#!/usr/bin/env bash
# Reload the schema into the running stack, without building anything.
#
#     dev/reload.sh              # into a scratch database, p8reload
#     dev/reload.sh p8experiment # into the one the stack actually serves
#
# THE INNER LOOP, and the reason it exists is that the other two paths are for
# other people. Building the image takes minutes and publishing it takes eight;
# neither is what you want after editing a line of SQL, and reaching for one of
# them because it is the documented path is how the dev experience rots.
#
# What this does instead: regenerate the extension SQL from specs/, drop and
# recreate ONE database inside the container that is already running, and
# install into it. About twenty seconds, no build, no pull, no restart, and the
# rest of the stack -- PostgREST, the worker, the MCP server -- keeps running
# against whatever it was already pointed at.
#
# It is deliberately NOT an `ALTER EXTENSION UPDATE`. Pre-1.0 there is no
# in-place upgrade path (PACKAGING.md), and pretending otherwise here would
# mean maintaining migration scripts for a schema that is still moving. A fresh
# database from the current specs is the honest reload, and it is fast because
# the samples in init/ are small on purpose.
#
# The image only has to be rebuilt when something COMPILED changes -- the
# Dockerfile, pgvector, pg_cron, the parser .so. Editing SQL is not that.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

DB=${1:-p8reload}
CONTAINER=${CONTAINER:-p8-experiment-pg19}
SUPERUSER=${SUPERUSER:-p8}
ADMIN_DB=${ADMIN_DB:-p8experiment}

docker inspect "$CONTAINER" >/dev/null 2>&1 || {
  echo "no container named $CONTAINER -- start the stack first: (cd dev && docker compose up -d)" >&2
  exit 1; }

echo "==> regenerating the extension SQL from specs/"
python3 "$ROOT/extension/percolate/build-sql.py" | tail -1

# Into the image's own extension directory, so `create extension percolate`
# finds the version being tested rather than the one the image shipped with.
# Overwriting it inside a running container is fine and is undone by any
# recreate -- which is exactly the property that makes this loop cheap.
VERSION=$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$ROOT/extension/percolate/percolate.control")
echo "==> installing percolate--$VERSION.sql into $CONTAINER"
docker cp "$ROOT/extension/percolate/sql/percolate--$VERSION.sql" \
          "$CONTAINER:/tmp/percolate--$VERSION.sql" >/dev/null
docker exec "$CONTAINER" sh -c \
  "cp /tmp/percolate--$VERSION.sql \$(pg_config --sharedir)/extension/"

echo "==> recreating database $DB"
docker exec -i "$CONTAINER" psql -U "$SUPERUSER" -d "$ADMIN_DB" -q \
  -c "drop database if exists $DB (force);" -c "create database $DB;"

# Same order as init/, minus pg_cron: its background worker is bound to one
# database by cron.database_name, so a scratch database cannot have it, and
# nothing below needs it to install.
docker exec -i "$CONTAINER" psql -U "$SUPERUSER" -d "$DB" -v ON_ERROR_STOP=1 -q <<SQL
create extension if not exists pgcrypto;
create extension if not exists pg_trgm;
create extension if not exists vector;
create extension if not exists percolate_parser;
do \$\$ begin execute format('grant create on database %I to app_owner', current_database()); end \$\$;
grant create, usage on schema public to app_owner;
set role app_owner;
create extension percolate cascade;
reset role;
SQL

for f in init/0[2-9]-*.sql; do
  [ -e "$f" ] || continue
  docker cp "$f" "$CONTAINER:/tmp/$(basename "$f")" >/dev/null
  docker exec -i "$CONTAINER" psql -U "$SUPERUSER" -d "$DB" -q \
    -f "/tmp/$(basename "$f")" 2>&1 | grep -iE '^(ERROR|WARNING)' || true
done

echo "==> auditing"
docker cp "$ROOT/surface.sql" "$CONTAINER:/tmp/surface.sql" >/dev/null
docker exec -i "$CONTAINER" psql -U "$SUPERUSER" -d "$DB" -f /tmp/surface.sql 2>&1 \
  | grep -iE 'SURFACE (COMPLETE|INCOMPLETE)|ROUND TRIP (COMPLETE|INCOMPLETE)|^ERROR' || true

echo
echo "==> $DB is current. Connect with:"
echo "    docker exec -it $CONTAINER psql -U $SUPERUSER -d $DB"
