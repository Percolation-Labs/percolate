#!/bin/bash
# Baked into percolationlabs/percolate-postgres:19 and run once at initdb.
#
# WHY THIS IS IN THE IMAGE. Without it the image ships an extension that is
# available and not installed, so `docker run` gives you a Postgres with
# nothing in it and the first thing every user does is find and copy a
# bootstrap script. The bootstrap is four statements and two of them are
# subtle, which is exactly what belongs in an image rather than in everybody's
# compose file.
#
# A SHELL script, not .sql, because the role passwords have to come from the
# environment: initdb runs .sql files through psql with no variables set, so a
# .sql version can only hard-code them.
#
# dev/ shadows this. dev/docker-compose.yml bind-mounts ./init over
# /docker-entrypoint-initdb.d, which REPLACES the directory, so the harness
# keeps its own seeded variant and this never runs twice.
set -e

AUTH_PW="${P8_AUTHENTICATOR_PASSWORD:-authpass}"
WORKER_PW="${P8_WORKER_PASSWORD:-workerpass}"

if [ -z "${P8_AUTHENTICATOR_PASSWORD:-}" ] || [ -z "${P8_WORKER_PASSWORD:-}" ]; then
    echo "percolate: WARNING -- using the default 'authpass'/'workerpass' role passwords." >&2
    echo "percolate: set P8_AUTHENTICATOR_PASSWORD and P8_WORKER_PASSWORD for anything" >&2
    echo "percolate: reachable by anyone else. They are printed in this image's source." >&2
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v auth_pw="$AUTH_PW" -v worker_pw="$WORKER_PW" <<'EOSQL'
-- 1. Roles. Cluster-level, so a non-superuser cannot create them -- which is
--    the whole reason this cannot be left to CREATE EXTENSION.
--
--    Neither app_owner nor api_viewer may ever be a superuser: a superuser
--    bypasses RLS unconditionally, and app_owner is about to own every table.
--    percolate.control sets superuser = false and user-rbac's own guard
--    refuses the superuser case rather than installing silently broken.
create role app_owner nologin;
create role api_viewer nologin;
grant api_viewer to app_owner;          -- so app_owner can hand it the views
create role web_anon nologin;
create role authenticated nologin;
create role authenticator noinherit login password :'auth_pw';
grant web_anon to authenticator;
grant authenticated to authenticator;

-- The worker and the Content Server connect as themselves and hold NO table
-- grants -- every interaction is a SECURITY DEFINER function call. That is
-- what makes "bring your own worker" safe to offer: a compromised worker can
-- claim and complete tasks, and nothing else.
create role worker login password :'worker_pw';

-- LOGIN, unlike the spec's default: pg_cron runs each job over a libpq
-- connection as the job's username, so a NOLOGIN scheduler means "cron job N
-- connection failed" once a minute with the job still showing active. No
-- password -- the connection is loopback inside the container, which pg_hba
-- trusts -- and no table grants, since all three jobs are SECURITY DEFINER.
create role scheduler login;

-- 2. The extensions a non-superuser cannot install.
create extension if not exists vector;
create extension if not exists percolate_parser;

-- 3. Room for app_owner to create things.
do $$ begin
    execute format('grant create on database %I to app_owner', current_database());
end $$;
grant create, usage on schema public to app_owner;

-- 4. The whole system, installed BY app_owner so it owns what it creates.
set role app_owner;
create extension percolate cascade;
reset role;

-- 5. The clock. ONE cron job for the whole system, because every scheduled
--    workflow is a ROW in workflow.schedules -- adding one is an ordinary
--    authenticated REST call, not a change to this file.
--
--    Skipped LOUDLY when pg_cron is not preloaded. pg_cron is a background
--    worker: no CREATE EXTENSION can add it after startup, so this needs the
--    server started with -c shared_preload_libraries=pg_cron and
--    -c cron.database_name=<db>. A notice rather than an exception keeps the
--    image usable without it -- everything but scheduling, the reaper and
--    timer steps still works -- while still saying what is missing, because a
--    scheduler that silently never runs is the worst of the three outcomes.
do $$
begin
    if exists (select 1 from pg_available_extensions where name = 'pg_cron')
       and coalesce(current_setting('shared_preload_libraries', true), '') like '%pg_cron%'
    then
        create extension if not exists pg_cron;
        perform cron.schedule('workflow-tick',   '* * * * *', 'select workflow.tick()');
        perform cron.schedule('workflow-reaper', '* * * * *', 'select workflow.reap_stale_tasks()');
        perform cron.schedule('workflow-timers', '* * * * *', 'select workflow.promote_due_timers()');
        update cron.job set username = 'scheduler'
         where jobname in ('workflow-tick','workflow-reaper','workflow-timers');
        raise notice 'percolate: pg_cron scheduled -- tick, reaper and timers are live';
    else
        raise notice 'percolate: pg_cron is NOT preloaded, so scheduled workflows, the '
                     'stale-task reaper and timer steps will not fire. Start the server '
                     'with -c shared_preload_libraries=pg_cron -c cron.database_name=%',
                     current_database();
    end if;
end $$;
EOSQL

# Provenance, applied after the extension that defines the recorder. Tolerated
# if absent so a hand-assembled image still starts -- an unstamped build
# reports no rows, which reads as "unknown", not as a broken install.
if [ -f /usr/local/share/percolate/build.sql ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
         -f /usr/local/share/percolate/build.sql >/dev/null
fi

echo "percolate: installed into ${POSTGRES_DB}."
