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
. dev/lib/extension-schemas.sh

# Named after the database container this run grades, not a fixed name. The
# cleanup removes it by name, and on 2026-09-11 three sessions ran this gate
# within minutes of each other, each against its own database and all three
# through one container called p8-upgrade -- the collision
# dev/release-rehearsal.sh records for its own containers.
UPGC="${UPGC:-${CONTAINER:-p8}-upgrade}"
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

-- AN APPLICATION'S ROLE AS EARLIER UPGRADES LEFT IT (REM-193). The 0.1.10
-- backfill in user-rbac/schema.sql gave agents:invoke and resources:create to
-- every role on every replay, including the roles grant_application_role
-- creates -- which that function then refuses to grant again. On Hetzner the
-- listing token went 403 after the 0.2.2 update. An ordinary role beside it
-- shows the backfill still reaches the roles it is for.
insert into rbac.roles (name, description) values
    ('ci-lister', 'granted by an application'), ('ci-member', null)
on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
    ('ci-lister', 'research', 'list'), ('ci-lister', 'agents', 'invoke'), ('ci-lister', 'resources', 'create')
on conflict do nothing;

-- A PUBLIC WORK WITH TWO REVISIONS, from before exposures existed (REM-185).
-- Every revision of a public work was readable then, so the upgrade must
-- expose both, or a link or blog entry pinned to the first stops resolving.
with u as (select id from rbac.users where email = 'upgrade@ci'),
     w as (insert into research.works (public_id, owner_id, visibility, listed_at)
           select 'ci-public-work', u.id, 'public', now() from u returning id, owner_id),
     r1 as (insert into research.revisions (work_id, number, label, schema_version, document, content_hash,
                                            actor_id, actor_kind)
            select w.id, 1, 'r1', '0.1', '{}'::jsonb, 'ci-hash-1', w.owner_id, 'person' from w returning id, work_id),
     r2 as (insert into research.revisions (work_id, number, label, schema_version, document, content_hash,
                                            predecessor_id, actor_id, actor_kind)
            select r1.work_id, 2, 'r2', '0.1', '{}'::jsonb, 'ci-hash-2', r1.id, w.owner_id, 'person'
              from r1 join w on w.id = r1.work_id returning id, work_id)
insert into research.heads (work_id, revision_id) select work_id, id from r2;
SQL

for f in "percolate--$V.sql" "percolate--$PREV--$V.sql"; do
    [ -f "extension/percolate/sql/$f" ] || {
        echo "missing extension/percolate/sql/$f -- run extension/percolate/build-sql.py" >&2
        exit 1; }
    docker cp "extension/percolate/sql/$f" "$UPGC:/usr/share/postgresql/19/extension/" >/dev/null
done
docker cp extension/percolate/percolate.control "$UPGC:/usr/share/postgresql/19/extension/" >/dev/null

# THE UPGRADE'S SUPERUSER STEP, rehearsed the way an upgrader meets it: the
# update refuses, naming what is missing, and then the image's own
# 00-superuser.sql -- the file an upgrader runs -- lets it through. Two refusals,
# because the preflight names one missing grant at a time and each is its own
# door:
#
#   * From 0.2.0 a workflow step runs as the person who started its run through
#     api_viewer, which needs authenticated's grants -- a cluster-level grant an
#     extension cannot make. Without it the workflows of every upgraded
#     database fail on their first read.
#   * Until 0.2.0 any role could call set_config, so a signed-in caller could
#     write someone else's id into request.jwt.claims (user-rbac/roles.sql §6).
#     The revoke is per database, so an upgraded database has not had it.
#
# The first refusal is answered by hand, with the one statement it names, only
# to reach the second; the superuser file then does both.
refuses() {  # $1 the text the refusal must contain, $2 what is missing
    local out
    if out=$(docker exec "$UPGC" psql -U p8 -d percolate -v ON_ERROR_STOP=1 -q \
               -c "set role app_owner; alter extension percolate update;" 2>&1); then
        echo "the update ran on a database where $2; its preflight should have refused" >&2
        exit 1
    fi
    echo "$out" | grep -qF "$1" || {
        echo "the update refused, but not with the statement an upgrader must run:" >&2
        echo "$out" >&2; exit 1; }
}
if [ "$(docker exec "$UPGC" psql -U p8 -d percolate -tAc \
        "select pg_has_role('api_viewer','authenticated','member')")" != "t" ]; then
    refuses "grant authenticated to api_viewer" "api_viewer is not a member of authenticated"
    docker exec "$UPGC" psql -U p8 -d percolate -v ON_ERROR_STOP=1 -q \
        -c "grant authenticated to api_viewer;"
fi
if [ "$(docker exec "$UPGC" psql -U p8 -d percolate -tAc \
        "select has_function_privilege('authenticated','pg_catalog.set_config(text,text,boolean)','execute')")" = "t" ]; then
    refuses "pg_catalog.set_config(text, text, boolean) from public" "authenticated can still call set_config"
fi
docker cp dev/image-init/00-superuser.sql "$UPGC:/tmp/00-superuser.sql" >/dev/null
docker exec "$UPGC" psql -U p8 -d percolate -v ON_ERROR_STOP=1 -q -f /tmp/00-superuser.sql

docker exec "$UPGC" psql -U p8 -d percolate -v ON_ERROR_STOP=1 -q \
    -c "set role app_owner; alter extension percolate update;"

# The schemas the superuser-ownership assertion below walks: every one the
# upgraded database says is the extension's. It named five by hand, and a
# superuser-owned percolate.* object would have passed.
S=$(ext_schemas docker exec "$UPGC" psql -U p8 -d percolate)

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

  -- AN APPLICATION ROLE IS GRANTABLE AGAIN (REM-193), and nothing else moved.
  if exists (select 1 from rbac.role_permissions where role = 'ci-lister'
              and (resource, action) in (('agents', 'invoke'), ('resources', 'create')))
    then raise exception 'an application role still carries capabilities its grant rule refuses after the upgrade'; end if;
  if not exists (select 1 from rbac.role_permissions where role = 'ci-lister' and resource = 'research' and action = 'list')
    then raise exception 'the upgrade removed research:list, which an application may grant'; end if;
  if not exists (select 1 from rbac.role_permissions where role = 'ci-member' and resource = 'agents' and action = 'invoke')
    then raise exception 'the backfill no longer reaches an ordinary role'; end if;
  perform rbac.grant_application_role((select id from rbac.users where email = 'upgrade@ci'), 'ci-lister',
                                      'research', 'list', 'operator', 'upgrade gate', 'hub', null);

  -- A PUBLIC WORK KEEPS EVERY REVISION IT EXPOSED (REM-185).
  if (select count(*) from research.exposures e join research.works w on w.id = e.work_id
       where w.public_id = 'ci-public-work') <> 2
    then raise exception 'the upgrade did not expose both revisions of a work that was public before exposures existed'; end if;

  if exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
             join pg_roles r on r.oid=c.relowner
             where n.nspname in $S and r.rolsuper)
    then raise exception 'an object is owned by a superuser -- RLS is inert on it'; end if;
  if has_function_privilege('web_anon',
       'rbac.request_password_reset(text,text,interval)', 'execute')
    then raise exception 'web_anon still holds EXECUTE on request_password_reset after the upgrade -- an existing database keeps the takeover'; end if;
  if not has_function_privilege('web_anon', 'rbac.reset_password(text,text)', 'execute')
    then raise exception 'the upgrade took away reset_password from web_anon -- redeeming a reset is the half that IS anonymous'; end if;
end \$\$;"

echo "UPGRADED $PREV -> $V with data intact and ownership preserved."
