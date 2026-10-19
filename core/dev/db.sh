#!/usr/bin/env bash
# A Postgres cluster of this experiment's own, on :5500.
#
# Why not just use experiments/pg19-stack's: cluster-level ROLES are shared by
# every database in a cluster, and pg19-stack's `load-specs.sh --fresh` drops
# and recreates them. Anything else running against that cluster gets
# `role "authenticated" does not exist` mid-flight -- observed, not theoretical.
# A separate container is a separate cluster, so the two stop interfering; it
# reuses the same image, so it is still PG19 beta3.
#
# Loads, in dependency order and with the right role at each step, the REAL
# spec files -- never copies:
#   user-rbac/roles.sql -> workflow-engine/schema.sql -> user-rbac/schema.sql
#   -> workflow-engine/integration-rbac.sql (if present) -> agentic/schema.sql
#
# Usage: ./dev/db.sh up [--fresh] | down
set -euo pipefail

NAME=p8-agentic-pg
PORT=${P8_PG_PORT:-5500}
DB=p8agentic
HERE="$(cd "$(dirname "$0")" && pwd)"
# The specs live in Percolation-Labs/percolate, checked out beside this repo --
# this loads the ACTUAL spec files, never copies, so a schema that only works
# because the harness did something extra fails here. Overridable for a
# checkout in a different place.
SPECS="${P8_SPECS:-$HERE/../../percolate/specs}"
if [[ ! -d "$SPECS" ]]; then
  echo "specs not found at $SPECS -- set P8_SPECS to your percolate/specs" >&2
  exit 1
fi
SPECS="$(cd "$SPECS" && pwd)"

psql_super() { docker exec -i "$NAME" psql -U p8 -d "$DB" -v ON_ERROR_STOP=1 "$@"; }
load() { docker cp "$1" "$NAME:/tmp/x.sql" >/dev/null; shift; psql_super -q "$@" -f /tmp/x.sql; }

case "${1:-up}" in
up)
  if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" --network pg19-stack_default -p "$PORT":5432 \
      -e POSTGRES_USER=p8 -e POSTGRES_PASSWORD=p8 -e POSTGRES_DB="$DB" \
      pg19-stack-db >/dev/null
    echo "==> waiting for postgres"
    for _ in $(seq 1 30); do
      docker exec "$NAME" pg_isready -U p8 -d "$DB" >/dev/null 2>&1 && break
      sleep 1
    done
  fi

  echo "==> 1/6 roles.sql (superuser: roles are cluster-level)"
  load "$SPECS/user-rbac/roles.sql"
  psql_super -q -c "alter role authenticator with password 'authpass';
                    grant app_owner to p8; grant worker to p8;
                    grant create on database $DB to app_owner;
                    grant create, usage on schema public to app_owner;"
  # set_config closed to the roles a person can become, in THIS database:
  # function ACLs live in each database's pg_proc, and this path loads spec
  # files one by one, so it never runs the preflight the extension's generated
  # script carries. While PUBLIC could call it, any signed-in user could write
  # someone else's `sub` into request.jwt.claims and read as them. Repeated
  # from user-rbac/roles.sql so a specs checkout from before 2026-09-11 is
  # closed too; both statements are idempotent.
  psql_super -q -c "revoke execute on function pg_catalog.set_config(text, text, boolean) from public;
                    grant execute on function pg_catalog.set_config(text, text, boolean)
                        to authenticator, app_owner, worker, scheduler;"

  echo "==> 2/6 workflow-engine/schema.sql (as app_owner)"
  load "$SPECS/workflow-engine/schema.sql" -c "set role app_owner;"
  echo "==> 3/6 user-rbac/schema.sql (as app_owner -- refuses superuser)"
  load "$SPECS/user-rbac/schema.sql" -c "set role app_owner;"
  if [[ -f "$SPECS/workflow-engine/integration-rbac.sql" ]]; then
    echo "==> 4/6 workflow-engine/integration-rbac.sql (as app_owner)"
    load "$SPECS/workflow-engine/integration-rbac.sql" -c "set role app_owner;"
  fi
  echo "==> 5/6 agentic/schema.sql (as app_owner)"
  load "$SPECS/agentic/schema.sql" -c "set role app_owner;"
  echo "==> 6/6 fixtures"
  load "$HERE/seed.sql"
  echo "==> ready: postgres://p8:p8@localhost:$PORT/$DB"
  ;;
down)
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  echo "==> stopped"
  ;;
*) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
