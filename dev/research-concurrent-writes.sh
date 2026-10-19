#!/usr/bin/env bash
# Do concurrent identical writes to one research work make one revision? (REM-151)
#
#     CONTAINER=p8-ci DB=p8ci dev/research-concurrent-writes.sh
#
# specs/tables/schema.md §3: "Concurrent identical submissions return one revision." A rolled-back test
# in one session cannot show that; two sessions have to overlap. So each first writer holds its
# transaction open after writing, and the second arrives while the first still owns the key or the row:
#
#   * two imports under one idempotency key: one work, one revision, the same receipt twice;
#   * two revisions from the same head: one draft-2, and the second told the head has moved.
#
# Committed rows, unlike dev/tests: an overlap needs two transactions. The owner and their work are made
# here and removed on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${CONTAINER:-p8-dev-db}"
DB="${DB:-p8research}"
SU="${SUPERUSER:-p8}"
OWNER=00000000-0000-4000-8000-0000000151d1
PID="rp-concurrent-$$"
TMP=$(mktemp -d)

sql() { docker exec -i "$CONTAINER" psql -U "$SU" -d "$DB" -v ON_ERROR_STOP=1 -qtA "$@"; }
cleanup() {
    sql -c "select research.erase_work(public_id, 'concurrent-writes fixture') from research.works where owner_id = '$OWNER'" \
        -c "delete from rbac.users where id = '$OWNER'" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT
cleanup
TMP=$(mktemp -d)
sql -c "insert into rbac.users (id, email, status) values ('$OWNER', 'concurrent-writes@example.test', 'active')" >/dev/null

# One transaction as the owner: $1, then hold it open $2 seconds.
as_owner() {
    docker exec -i "$CONTAINER" psql -U "$SU" -d "$DB" -qtA <<SQL 2>&1
begin;
set local request.jwt.claims = '{"sub": "$OWNER"}';
set local role authenticated;
$1
select pg_sleep($2);
commit;
SQL
}
DOC='{"schema_version": "0.1", "title": "A concurrently imported package", "sources": [], "claims": [], "edges": [], "visibility": "private"}'
failed=0

# 1. One key, two imports.
as_owner "select 'rev:' || (research.submit_package('$DOC', 'concurrent-key', '$PID')->>'revision_id');" 3 > "$TMP/a" &
sleep 1
as_owner "select 'rev:' || (research.submit_package('$DOC', 'concurrent-key', '$PID')->>'revision_id');" 0 > "$TMP/b"
wait
a=$(grep -o 'rev:.*' "$TMP/a" || true); b=$(grep -o 'rev:.*' "$TMP/b" || true)
n=$(sql -c "select count(*) from research.revisions r join research.works w on w.id = r.work_id where w.public_id = '$PID'")
if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$n" = 1 ]; then
    echo "  two imports under one key, overlapping: one revision, the same receipt twice -- ok"
else
    echo "FAILED: two imports under one key made $n revision(s); receipts '${a:-none}' and '${b:-none}'"
    sed 's/^/    first:  /' "$TMP/a"; sed 's/^/    second: /' "$TMP/b"; failed=1
fi

# 2. Two revisions from the same head.
as_owner "select 'rev:' || (research.revise_package('$PID', '$DOC'::jsonb || '{\"title\": \"The first revision\"}', 'draft-1')->>'revision');" 3 > "$TMP/c" &
sleep 1
as_owner "select 'rev:' || (research.revise_package('$PID', '$DOC'::jsonb || '{\"title\": \"The second revision\"}', 'draft-1')->>'revision');" 0 > "$TMP/d"
wait
labels=$(sql -c "select string_agg(r.label, ',' order by r.number) from research.revisions r join research.works w on w.id = r.work_id where w.public_id = '$PID'")
if grep -q 'rev:draft-2' "$TMP/c" && grep -q 'newer revision' "$TMP/d" && [ "$labels" = "draft-1,draft-2" ]; then
    echo "  two revisions from one head, overlapping: one draft-2, and the second told the head moved -- ok"
else
    echo "FAILED: two revisions from one head left $labels"
    sed 's/^/    first:  /' "$TMP/c"; sed 's/^/    second: /' "$TMP/d"; failed=1
fi
exit $failed
