#!/bin/bash
# Baked into percolationlabs/percolate-postgres:19 and run once at initdb,
# after 00-superuser.sql has made the roles and the per-database grants.
#
# WHY THIS IS IN THE IMAGE. Without it the image ships an extension that is
# available and not installed, so `docker run` gives you a Postgres with
# nothing in it and the first thing every user does is find and copy a
# bootstrap script. The bootstrap is a few statements and two of them are
# subtle, which is exactly what belongs in an image rather than in everybody's
# compose file.
#
# TWO FILES, AND ONLY THE FIRST IS THE SUPERUSER'S. 00-superuser.sql is the
# one copy of the superuser step, which every dev script also runs; this is
# what the image does after it: install the system as app_owner, start the
# clock, close template1, stamp the build. It used to carry its own copy of
# the roles and grants, which is how #24's misordered grant reached it.
#
# A SHELL script, not .sql, for two reasons: template1 is a second database,
# and the build stamp may legitimately be absent on a hand-assembled image,
# which psql has no clean way to skip.
#
# The whole directory is the hook: dev/Dockerfile.pg19 copies it over
# /docker-entrypoint-initdb.d, the private kind stack puts it in the ConfigMap it
# mounts there, and to try a change without building anything, mount
# dev/image-init over that directory of any published image.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'EOSQL'
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
--    scheduler that never runs and says nothing is the worst of the outcomes.
--
--    THREE CONDITIONS, as in get-percolate's bootstrap.sql step 4. The third
--    is cron.database_name: it names ONE database for the whole cluster, and
--    `create extension pg_cron` anywhere else fails with "can only create
--    extension in database <name>". Checking only the preload meant an image
--    started with POSTGRES_DB renamed and cron.database_name left at its
--    default aborted init on this line -- ON_ERROR_STOP -- and the container
--    never became ready. A Helm install that renames the database is that case.
--
--    Scheduled AS scheduler in one call, as bootstrap.sql does. It changed
--    because cron.schedule() makes the job the caller's and the UPDATE that
--    handed it to scheduler collided on jobname_username_uniq on a second run.
--    Init runs once, so that collision cannot happen here; the reason to match
--    is that this file and bootstrap.sql are one procedure, and two spellings
--    of one step are how the two drift apart.
do $$
begin
    if exists (select 1 from pg_available_extensions where name = 'pg_cron')
       and coalesce(current_setting('shared_preload_libraries', true), '') like '%pg_cron%'
       and coalesce(current_setting('cron.database_name', true), 'postgres')
           = current_database()
    then
        create extension if not exists pg_cron;
        perform cron.schedule_in_database('workflow-tick',   '* * * * *',
                    'select workflow.tick()',               current_database(), 'scheduler');
        perform cron.schedule_in_database('workflow-reaper', '* * * * *',
                    'select workflow.reap_stale_tasks()',   current_database(), 'scheduler');
        perform cron.schedule_in_database('workflow-timers', '* * * * *',
                    'select workflow.promote_due_timers()', current_database(), 'scheduler');
        -- A FOURTH JOB, BECAUSE NOTHING DELETED A FINISHED RUN (REM-109).
        -- workflow.purge_completed existed and was scheduled nowhere, so every
        -- deployment kept every run and every task_event for ever. That is not
        -- only disk: scale.md finding 2 shows queue_depth -- the autoscaler's
        -- own probe -- degrades with the live-to-total row ratio, so at ~10k
        -- tasks/day the thing that decides how many workers to run gets slower
        -- for three months and then matters. Daily rather than per-minute: it
        -- is a retention pass. One run of it stops starting batches at half of
        -- scheduler's statement_timeout and keeps what it purged, so a backlog
        -- larger than one night's budget shrinks a night at a time instead of
        -- being cancelled and rolled back (schema.sql, purge_completed).
        perform cron.schedule_in_database('workflow-purge',  '17 3 * * *',
                    'select workflow.purge_completed()',    current_database(), 'scheduler');
        raise notice 'percolate: pg_cron scheduled -- tick, reaper, timers and purge are live';
    elsif coalesce(current_setting('shared_preload_libraries', true), '') like '%pg_cron%'
    then
        raise notice 'percolate: pg_cron is preloaded but cron.database_name is %, not '
                     '%. The clock runs in one database per cluster, so scheduled '
                     'workflows, the reaper and timer steps will not fire for this one. '
                     'Start the server with -c cron.database_name=%',
                     coalesce(current_setting('cron.database_name', true), 'postgres'),
                     current_database(), current_database();
    else
        raise notice 'percolate: pg_cron is NOT preloaded, so scheduled workflows, the '
                     'stale-task reaper and timer steps will not fire. Start the server '
                     'with -c shared_preload_libraries=pg_cron -c cron.database_name=%',
                     current_database();
    end if;
end $$;
EOSQL

# template1 runs the same superuser file, so a database somebody creates later
# -- `createdb`, CREATE DATABASE -- already has set_config closed, and CREATE
# EXTENSION percolate there does not stop to ask for it. The file knows when
# it is in a template and stops after the revoke.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname template1 -q \
     -f "$HERE/00-superuser.sql"

# Provenance, applied after the extension that defines the recorder. Tolerated
# if absent so a hand-assembled image still starts -- an unstamped build
# reports no rows, which reads as "unknown", not as a broken install.
if [ -f /usr/local/share/percolate/build.sql ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
         -f /usr/local/share/percolate/build.sql >/dev/null
fi

echo "percolate: installed into ${POSTGRES_DB}."
