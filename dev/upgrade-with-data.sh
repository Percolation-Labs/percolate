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

-- AND AN ADMINISTRATOR, because the two defects this gate exists to catch live
-- only in a database somebody has actually administered. `bootstrap_admin`
-- marks a role `grants_all` and grants it every pair declared AT THAT MOMENT;
-- everything the next release declares is what goes missing.
select rbac.bootstrap_admin('upgrade@ci', 'ci_admin');
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

# THE UPGRADE'S ONE SUPERUSER STEP, rehearsed the way an upgrader meets it. From
# 0.2.0 a workflow step runs as the person who started its run through api_viewer,
# which needs authenticated's grants -- a cluster-level grant an extension
# cannot make. A cluster bootstrapped earlier lacks it, and the update must
# REFUSE and name the line rather than install a build whose workflows fail on
# their first read. So: the refusal first, then the line, then the update.
if [ "$(docker exec "$UPGC" psql -U p8 -d percolate -tAc \
        "select pg_has_role('api_viewer','authenticated','member')")" != "t" ]; then
    if out=$(docker exec "$UPGC" psql -U p8 -d percolate -v ON_ERROR_STOP=1 -q \
               -c "set role app_owner; alter extension percolate update;" 2>&1); then
        echo "the update ran on a cluster without 'grant authenticated to api_viewer';" \
             "its preflight should have refused" >&2
        exit 1
    fi
    echo "$out" | grep -q "grant authenticated to api_viewer" || {
        echo "the update refused, but not with the line an upgrader must run:" >&2
        echo "$out" >&2; exit 1; }
    docker exec "$UPGC" psql -U p8 -d percolate -v ON_ERROR_STOP=1 -q \
        -c "grant authenticated to api_viewer;"
fi

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
  -- AN ADMINISTERED DATABASE STILL MEANS WHAT ADMIN MEANS.
  --
  -- bootstrap_admin grants every pair that exists when it runs, and it runs
  -- once. Measured on a real 0.1.3 -> 0.1.4 upgrade: the administrator held 20
  -- of 27 declared pairs, and the seven it had lost were every pair the newer
  -- release declared -- so on any deployment older than the release, the person
  -- who installed it could not administer an org and could not see the orgs
  -- table at all, with no way to tell that from a deployment which simply has no orgs.
  --
  -- The fix was rbac.roles.grants_all plus a trigger. THIS is the assertion
  -- that the fix keeps working, and it could not have existed before this file
  -- seeded an administrator: every other gate installs fresh, and a fresh
  -- install has nobody to lose anything.
  -- THE SUBJECT MUST EXIST BEFORE THE ASSERTION MEANS ANYTHING. Without this,
  -- a seed whose bootstrap_admin silently failed leaves zero grants_all roles,
  -- the cross join below is empty, and the check passes having examined
  -- nothing -- which is exactly the class meta/postmortems/README.md calls
  -- verified in a world where the defect could not appear. Caught by trying to
  -- make the assertion fail and watching it pass.
  if not exists (select 1 from rbac.roles where grants_all)
    then raise exception
      'no role is marked grants_all -- the seed did not administer this database, so the next assertion would prove nothing';
  end if;

  if exists (
      select 1 from rbac.roles r cross join rbac.permission_kinds k
       where r.grants_all
         and not exists (select 1 from rbac.role_permissions rp
                          where rp.role = r.name and rp.resource = k.resource
                            and rp.action = k.action))
    then raise exception
      'an administrator lost declared permissions across the upgrade: % of % pairs',
      (select count(*) from rbac.role_permissions rp join rbac.roles r on r.name = rp.role where r.grants_all),
      (select count(*) from rbac.permission_kinds) * (select count(*) from rbac.roles where grants_all);
  end if;

  -- EVERY checked_by STILL NAMES SOMETHING THAT EXISTS.
  --
  -- permission_kinds.checked_by records where a pair is consulted so it can
  -- be verified. 0.1.4 renamed two policies and the seed ended on conflict do
  -- nothing, so a fresh install named the new ones and every upgraded database
  -- went on naming policies that by then existed nowhere. Invisible to
  -- upgrade-converges.sh, which compares objects and this is a ROW.
  --
  -- Only the policy NAME form is checkable; the rest name functions and one
  -- names a group of them in words. Checking the checkable form is worth more
  -- than checking none of it, and the where says so rather than pretending.
  if exists (
      select 1 from rbac.permission_kinds k
       where k.checked_by like 'policy %'
         and not exists (select 1 from pg_policy p
                          where p.polname = split_part(k.checked_by, ' ', 2)))
    then raise exception
      'these declarations name a policy that does not exist after the upgrade: %',
      (select string_agg(k.resource || '/' || k.action || ' -> ' || k.checked_by, ', ')
         from rbac.permission_kinds k
        where k.checked_by like 'policy %'
          and not exists (select 1 from pg_policy p
                           where p.polname = split_part(k.checked_by, ' ', 2)));
  end if;

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
