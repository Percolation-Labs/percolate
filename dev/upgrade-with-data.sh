#!/usr/bin/env bash
# Can a database that ALREADY HAS DATA reach this version at all?
#
#     dev/upgrade-with-data.sh
#
# The other upgrade gate, `dev/upgrade-converges.sh`, asks whether an upgraded
# database ends up in the same PLACE as a fresh install. This asks the cruder
# and more urgent question first: does `ALTER EXTENSION percolate UPDATE` even
# RUN against a real published image holding real rows, and do the rows and the
# ownership survive it. Every other gate installs fresh, which proves the schema
# is valid and says nothing about what every user after the first one does.
#
# THAT IS NOT HYPOTHETICAL. A commit unifying the terminal status to `succeeded`
# left the CHECK constraints inline in `create table if not exists`, so the
# update aborted on any database holding a finished run -- `violates foreign key
# constraint runs_status_fk`. This inserts exactly such a run and would have
# said so on the first push. It never ran, because an unrelated assertion had
# failed twenty seconds earlier and a release blocker sat behind a red that
# everybody could already explain. `dev/check.sh` runs every gate regardless of
# what failed before it, which is the structural version of that fix.
#
# `set role app_owner` is the load-bearing line: an extension update creates its
# objects as whoever runs it, so a superuser here leaves every policy on the new
# tables inert while reporting success.
set -euo pipefail
cd "$(dirname "$0")/.."

UPGC="${UPGC:-p8-upgrade}"
V=$(sed -n "s/^default_version = '\(.*\)'/\1/p" extension/percolate/percolate.control)
PREV=$(git tag --list 'v*' | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
       | grep -v "^$V$" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
if [ -z "$PREV" ]; then
    echo "nothing published below $V -- there is no upgrade to test yet."
    exit 0
fi
echo "==> upgrading a real $PREV database, with data, to $V"

cleanup() { docker rm -f "$UPGC" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --name "$UPGC" -e POSTGRES_USER=p8 -e POSTGRES_PASSWORD=p8 \
    -e POSTGRES_DB=percolate "percolationlabs/percolate-postgres:19-$PREV" \
    postgres -c shared_preload_libraries=pg_cron -c cron.database_name=percolate >/dev/null
# TCP, for the reason dev/ci-database.sh spells out on its readiness loop.
for _ in $(seq 1 90); do
    docker exec -e PGPASSWORD=p8 "$UPGC" psql -h 127.0.0.1 -U p8 -d percolate -tAc \
        "select 1 from pg_extension where extname='percolate'" 2>/dev/null | grep -q 1 && break
    sleep 2
done

# Data a real user would have, so the upgrade is carrying something.
docker exec -i "$UPGC" psql -U p8 -d percolate -v ON_ERROR_STOP=1 -q <<'SQL'
select rbac.create_user_with_password('upgrade@ci','a long passphrase');
select workflow.define_yaml($$
name: ci_upgrade
steps:
  - id: now
    sql: {function: p8ql, args: ['SELECT now()']}
$$);
select workflow.start_workflow('ci_upgrade','{}'::jsonb);
SQL

for f in "percolate--$V.sql" "percolate--$PREV--$V.sql"; do
    [ -f "extension/percolate/sql/$f" ] || {
        echo "missing extension/percolate/sql/$f -- run extension/percolate/build-sql.py" >&2
        exit 1; }
    docker cp "extension/percolate/sql/$f" "$UPGC:/usr/share/postgresql/19/extension/" >/dev/null
done
docker cp extension/percolate/percolate.control "$UPGC:/usr/share/postgresql/19/extension/" >/dev/null

docker exec "$UPGC" psql -U p8 -d percolate -v ON_ERROR_STOP=1 -q \
    -c "set role app_owner; alter extension percolate update;"

# WHAT THE LAST TWO ASSERTIONS ARE FOR. Everything above them asks whether the
# upgrade PRESERVED something. They ask whether it REMOVED something, which is
# the half a replay is bad at: `create or replace function` keeps the existing
# ACL, so deleting a grant from the schema corrects a fresh install and leaves
# every database that already has it untouched. Measured on the real published
# 0.1.2 -- web_anon still held EXECUTE on request_password_reset after the
# update, which is the account takeover the removal was for.
docker exec "$UPGC" psql -U p8 -d percolate -v ON_ERROR_STOP=1 -tAc "
do \$\$ begin
  if (select extversion from pg_extension where extname='percolate') is distinct from '$V'
    then raise exception 'still on %', (select extversion from pg_extension where extname='percolate'); end if;
  if not exists (select 1 from rbac.users where email='upgrade@ci')
    then raise exception 'the user did not survive the upgrade'; end if;
  -- The word for finishing well is the vocabulary table's business, not a
  -- literal here: efebac2 renamed the terminal state and left hardcoded copies
  -- in two files, and both went red separately.
  if not exists (select 1 from workflow.runs r
                   join workflow.lifecycle_states s on s.state = r.status
                  where s.is_success)
    then raise exception 'their finished run did not survive the upgrade'; end if;
  if exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
             join pg_roles r on r.oid=c.relowner
             where n.nspname in ('rbac','workflow','aiq','content','agentic') and r.rolsuper)
    then raise exception 'an object is owned by a superuser -- RLS is inert on it'; end if;
  if has_function_privilege('web_anon',
       'rbac.request_password_reset(text,text,interval)', 'execute')
    then raise exception 'web_anon still holds EXECUTE on request_password_reset after the upgrade -- an existing database keeps the takeover'; end if;
  if not has_function_privilege('web_anon', 'rbac.reset_password(text,text)', 'execute')
    then raise exception 'the upgrade took away reset_password from web_anon -- redeeming a reset is the half that IS anonymous'; end if;
end \$\$;"

echo "UPGRADED $PREV -> $V with data intact and ownership preserved."
