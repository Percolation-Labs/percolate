#!/usr/bin/env bash
# Many walks at once over one scope, sampling Postgres's memory: REM-1228's load test. See README.md.
#
#     dev/scale/walks.sh                         # 250 walks, 16 at a time, against p8-dev-db
#     dev/scale/walks.sh --walks 40 --clients 8
#     CONTAINER=my-db DB=p8ci dev/scale/walks.sh
#
# Each walk is offline (its verdicts come from a replay document), so no model and no key is needed, and it runs
# its steps in its own connection with workflow.drain_sql_steps, the cascade a worker's write-back takes. --clients
# is how many backends run walk steps at once. Every 2 s it samples the container's Postgres processes: private
# memory (RssAnon, which leaves out shared buffers a backend has touched) in total and in the largest backend. It
# fails if any walk did not succeed or any backend was killed.
set -euo pipefail

CONTAINER="${CONTAINER:-p8-dev-db}"
DB="${DB:-p8experiment}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WALKS=250
CLIENTS=16
ITEMS=2000
TAGS=300
FILLER=20000
OUT="${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/walks.XXXXXX")}"

while [ $# -gt 0 ]; do
  case "$1" in
    --walks)   WALKS="$2"; shift 2 ;;
    --clients) CLIENTS="$2"; shift 2 ;;
    --items)   ITEMS="$2"; shift 2 ;;
    --filler)  FILLER="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT"
q() { docker exec -i "$CONTAINER" psql -U p8 -d "$DB" -X -At -v ON_ERROR_STOP=1 "$@"; }

echo "=== seeding the scope: $ITEMS items, $TAGS terms, $FILLER other resources ==="
q -q -v items="$ITEMS" -v tags="$TAGS" -v filler="$FILLER" < "$HERE/06-walks-seed.sql"

started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "=== $WALKS walks, $CLIENTS at a time; samples in $OUT/samples.csv ==="
echo "t,walks_done,active_backends,pg_private_mb,max_backend_private_mb" > "$OUT/samples.csv"
: > "$OUT/runs.txt"

walk() {
  # four search seeds per walk, spread over the scope, so walks do not all read the same leads
  docker exec -i "$CONTAINER" psql -U p8 -d "$DB" -X -At -v ON_ERROR_STOP=1 -v n="$1" <<'SQL' >> "$OUT/runs.txt"
\set QUIET on
select workflow.start_workflow('walk_load_run', jsonb_build_object(
           'nodes', 'walk_load', 'prefix', 'wl/', 'question', jsonb_build_object('text', 'load walk ' || :n),
           'search', to_jsonb(array(select 'wl/' || (1 + abs(hashtext(:n || '/' || k)) % (select count(*) from aiq.nodes where entity_type = 'walk_load'))
                                      from generate_series(1, 4) k)),
           'replay', (select id from content.resources where uri = 'walk-load:replay'), 'offline', true,
           'settings', jsonb_build_object('stack', false, 'describe', 'source'))) as r \gset
select workflow.drain_sql_steps(:'r', 1000) \g /dev/null
-- a statement of its own, so it sees what the drain committed
select :'r', status, (select count(*) from workflow.tasks where run_id = :'r') from workflow.runs where id = :'r';
SQL
}
export -f walk; export CONTAINER DB OUT

t0=$(date +%s)
seq 1 "$WALKS" | xargs -P "$CLIENTS" -I{} bash -c 'walk {}' &
pid=$!
while :; do
  done_n=$(wc -l < "$OUT/runs.txt" | tr -d ' ')
  a=$(q -c "select count(*) from pg_stat_activity where backend_type = 'client backend' and state = 'active'" < /dev/null)
  m=$(docker exec "$CONTAINER" sh -c 'for f in /proc/[0-9]*/status; do grep -s "^RssAnon" $f; done' \
        | awk '{s += $2; if ($2 > m) m = $2} END {printf "%d,%d", s / 1024, m / 1024}')
  echo "$(( $(date +%s) - t0 )),$done_n,$a,$m" >> "$OUT/samples.csv"
  kill -0 "$pid" 2>/dev/null || break
  sleep 2
done
wait "$pid" || true
secs=$(( $(date +%s) - t0 ))

ok=$(awk -F'|' '$2 == "succeeded"' "$OUT/runs.txt" | wc -l | tr -d ' ')
killed=$(docker logs --since "$started" "$CONTAINER" 2>&1 | grep -c "terminated by signal" || true)
peak=$(awk -F, 'NR > 1 && $4 > p {p = $4} END {print p + 0}' "$OUT/samples.csv")
peak1=$(awk -F, 'NR > 1 && $5 > p {p = $5} END {print p + 0}' "$OUT/samples.csv")
echo "walks: $ok of $WALKS succeeded in ${secs} s; backends killed: $killed"
echo "Postgres private memory: peak ${peak} MB in total, ${peak1} MB in one backend"
[ "$ok" = "$WALKS" ] && [ "$killed" = 0 ]
