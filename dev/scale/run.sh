#!/usr/bin/env bash
# Scale probes for the workflow engine's three hot paths. See README.md.
set -euo pipefail

CONTAINER="${CONTAINER:-p8-dev-db}"
DSN="${DSN:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPTH=1000000
CLIENTS="1 8 32"
CLEAN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --depth)   DEPTH="$2"; shift 2 ;;
    --clients) CLIENTS="$2"; shift 2 ;;
    --clean)   CLEAN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# A file is piped on stdin rather than passed with -f, because -f resolves
# inside the container and these files are on the host. Same reason
# dev/tests/run.sh does it this way.
psql_file() {
  local f="$1"; shift
  if [ -n "$DSN" ]; then psql "$DSN" -v ON_ERROR_STOP=1 "$@" < "$f"
  else docker exec -i "$CONTAINER" psql -U p8 -d p8experiment -v ON_ERROR_STOP=1 "$@" < "$f"
  fi
}

psql_cmd() {
  if [ -n "$DSN" ]; then psql "$DSN" -v ON_ERROR_STOP=1 -c "$1"
  else docker exec -i "$CONTAINER" psql -U p8 -d p8experiment -v ON_ERROR_STOP=1 -c "$1" < /dev/null
  fi
}

if [ "$CLEAN" = 1 ]; then
  # The engine owns retention now. This used to be a batched delete loop in
  # bash, written here because nothing in the schema could purge a task --
  # which was a production gap wearing a test harness as a disguise.
  psql_cmd "set role app_owner;
    update workflow.runs r set status='cancelled', completed_at=now()-interval '1000 days'
      from workflow.definitions d
     where d.id = r.workflow_def_id and d.name in ('__scale_probe','scale_fanin');
    select * from workflow.purge_completed(interval '1 day', 200);"
  echo "cleaned"; exit 0
fi

echo "=== seeding ${DEPTH} ready tasks ==="
psql_file "$HERE/01-seed.sql" -q -v depth="$DEPTH"

echo
echo "=== probe: claim plan and cost at depth ==="
psql_file "$HERE/02-claim.sql"

echo
echo "=== probe: claim throughput under contention ==="
# pgbench needs the worker role, exactly as a real worker connects.
for c in $CLIENTS; do
  echo "--- clients=$c ---"
  if [ -n "$DSN" ]; then
    pgbench "$DSN" -n -f "$HERE/claim.pgbench" -c "$c" -j 4 -T 10 2>&1 | grep -E 'tps|latency average'
  else
    docker exec -i "$CONTAINER" bash -c "cat > /tmp/claim.pgbench" < "$HERE/claim.pgbench"
    docker exec "$CONTAINER" bash -c \
      "PGPASSWORD=workerpass pgbench -h localhost -U worker -d p8experiment \
       -n -f /tmp/claim.pgbench -c $c -j 4 -T 10 2>&1 | grep -E 'tps|latency average'"
  fi
done

echo
echo "=== probe: queue_depth, which the autoscaler calls every 30s ==="
psql_file "$HERE/03-depth.sql"

echo
echo "=== probe: fan-in cascade cost ==="
psql_file "$HERE/04-fanin.sql"

echo
echo "=== probe: work nobody can claim ==="
psql_file "$HERE/05-catchment.sql"
