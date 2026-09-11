-- requires: pg_cron
--
-- THE CLOCK IS ACTUALLY RUNNING.
--
-- 02-schedules.sql tests the scheduler by driving tick() itself, which proves
-- the logic and proves nothing about the deployment. This file asserts the
-- other half: that something is calling tick() on this database, once a
-- minute, without anyone asking it to.
--
-- It is a separate file because it can only pass against a running stack
-- (`dev/docker-compose.yml`), and because the failure it exists to catch is
-- specific and silent: pg_cron registers a job, reports it active, and then
-- fails to run it -- most often because the job's role cannot open a
-- connection. `cron.job` looks perfect in that state.
--
-- Safe to run at any point after the stack comes up: the first assertion
-- waits up to 100 seconds for a tick, because pg_cron's finest granularity is
-- a minute and a freshly created database has not reached one yet.

\set ON_ERROR_STOP on

do $$
begin
    if not exists (select 1 from pg_extension where extname = 'pg_cron') then
        raise exception
            'pg_cron is not installed. The image builds it with '
            'dev/patches/pg_cron-pg19.patch; the extension is created by '
            'dev/image-init/01-percolate.sh, and its worker needs '
            'shared_preload_libraries=pg_cron (docker-compose.yml).';
    end if;
end $$;

-- Every job the deployment installs must exist, be active, and be owned by
-- the role the spec says runs maintenance.
do $$
declare
    v_missing text;
    v_bad_user text;
begin
    select string_agg(j, ', ') into v_missing
      from unnest(array['workflow-tick','workflow-reaper','workflow-timers']) j
     where not exists (select 1 from cron.job where jobname = j and active);
    if v_missing is not null then
        raise exception 'cron jobs missing or inactive: %', v_missing;
    end if;

    select string_agg(jobname || ' runs as ' || username, ', ') into v_bad_user
      from cron.job
     where jobname like 'workflow-%' and username <> 'scheduler';
    if v_bad_user is not null then
        raise exception
            'maintenance jobs must run as `scheduler`, not as a privileged '
            'role: %', v_bad_user;
    end if;
end $$;

-- The assertion that matters. A registered job that never runs produces no
-- error anywhere -- it just quietly does nothing, which for a scheduler is
-- indistinguishable from "nothing was due".
do $$
declare
    v_runs     int;
    v_failed   text;
    v_failures bigint;
    v_latest   timestamptz;
    v_waited   int := 0;
    v_seen     timestamptz;
begin
    -- WAIT FOR THE FIRST TICK RATHER THAN REQUIRING THE CALLER TO.
    --
    -- The header says to run this ~70 seconds after the stack comes up, and
    -- `dev/tests/run.sh` runs every file the moment the database answers -- so
    -- on a freshly created database this failed with "has never run" against a
    -- perfectly healthy pg_cron that simply had not reached the top of a
    -- minute yet. A precondition a test states and its runner cannot honour is
    -- a test that fails for the wrong reason, which is worse than no test:
    -- someone learns to expect this file to be red.
    --
    -- pg_cron's finest granularity is one minute, so the bound is 100 seconds
    -- and it costs nothing on a stack that has been up. The failures below are
    -- unchanged -- they just mean it now.
    --
    -- AND WAIT FOR THE CONDITION THE ASSERTIONS ACTUALLY NEED, which is not
    -- the same as "a row exists". A tick row appears in `cron.job_run_details`
    -- the moment pg_cron starts opening its connection, with status
    -- `connecting`, and `workflow.schedules.last_tick_at` is not stamped until
    -- that tick has connected and run. Measured on a database CI had just
    -- built:
    --
    --     FIRST TICK ROW SEEN after 26s: rows=1 statuses=connecting
    --                                    last_tick_at=NULL
    --
    -- On `v_runs > 0` alone the loop exited in exactly that state and the
    -- schedules assertion below then read NULL and reported *"tick() is
    -- running but is not reaching workflow.schedules"* -- which sends a reader
    -- to `cron.database_name` on a deployment where it is correct. That is
    -- this collection's characteristic failure wearing a race's clothes: not a
    -- check that says fail, a check that says fail for a reason other than the
    -- one it names.
    --
    -- IT NEVER WAITED AT ALL, which is the part worth keeping. The red run
    -- (33894105831) failed 13 seconds into a `dev/check.sh` that started 4
    -- seconds after the database was created -- the loop exited on its first
    -- pass. So this is not "CI is slow": it passes on every machine where
    -- anything slow happened first, and that is the whole of why it survived
    -- from the day it was written.
    --
    -- The three lines below are the same three conditions the three assertions
    -- make, so a timeout still reaches whichever assertion is the true one and
    -- fails with its message. This waits; it does not excuse.
    loop
        select count(*), max(start_time) into v_runs, v_latest
          from cron.job_run_details d
          join cron.job j on j.jobid = d.jobid
         where j.jobname = 'workflow-tick';
        select last_tick_at into v_seen
          from workflow.schedules where name = 'content-reconcile';
        exit when (v_runs > 0 and v_seen is not null) or v_waited >= 100;
        perform pg_sleep(5);
        v_waited := v_waited + 5;
    end loop;

    if v_runs = 0 then
        raise exception
            'workflow-tick is registered but has never run. If the server log '
            'says "cron job N connection failed", the `scheduler` role is '
            'NOLOGIN -- pg_cron opens a real libpq connection per job rather '
            'than running it in-process.';
    end if;

    -- RECENT FAILURES, NOT EVERY FAILURE THERE HAS EVER BEEN.
    --
    -- This read `where status <> 'succeeded'` over the whole of
    -- job_run_details, and the whole of it is forever: pg_cron marks every
    -- in-flight row `failed` with "server restarted" when the postmaster comes
    -- back, so one `docker compose restart` made this file permanently red on
    -- that database. Observed with nine "job startup timeout" rows inside a
    -- seven-minute window and 495 successful ticks after them, up to a minute
    -- before this ran -- a clock the very next assertion proves is healthy.
    -- This file's own header says what that costs: "someone learns to expect
    -- this file to be red."
    --
    -- Two changes, and the second is not cosmetic. The window makes it a
    -- question about now. And it counts ROWS rather than aggregating messages:
    -- `string_agg(distinct return_message)` over rows whose message is null
    -- returns null, so a genuinely failed run that recorded no message passed
    -- this check silently -- and `<> 'succeeded'` also swept up `running` and
    -- `connecting`, which are what a tick looks like while it is working.
    select count(*),
           coalesce(string_agg(distinct coalesce(d.return_message, '(no message)'), '; '),
                    '(no messages recorded)')
      into v_failures, v_failed
      from cron.job_run_details d
      join cron.job j on j.jobid = d.jobid
     where j.jobname = 'workflow-tick'
       and d.status = 'failed'
       and d.start_time > now() - interval '15 minutes';
    if v_failures > 0 then
        raise exception
            'workflow-tick failed % times in the last 15 minutes: %',
            v_failures, v_failed;
    end if;

    if v_latest < now() - interval '3 minutes' then
        raise exception
            'workflow-tick last ran at % -- the clock has stopped', v_latest;
    end if;
end $$;

-- And the tick reached the schedules: the seeded example has been evaluated.
-- This is the end-to-end link -- pg_cron -> tick() -> a row -- and it is the
-- step that a correct cron setup pointed at the WRONG DATABASE still fails
-- (cron.database_name), because the job succeeds against an empty schema.
do $$
declare v_seen timestamptz;
begin
    select last_tick_at into v_seen
      from workflow.schedules where name = 'content-reconcile';

    if not found then
        raise exception
            'the seeded example schedule is missing -- init/02-seed.sql did not run';
    end if;
    if v_seen is null then
        raise exception
            'the seeded schedule has never been evaluated: tick() is running '
            'but is not reaching workflow.schedules';
    end if;
    if v_seen < now() - interval '3 minutes' then
        raise exception 'the seeded schedule was last evaluated at %', v_seen;
    end if;
end $$;

\echo
\echo '=== the clock, as the database sees it ==='
select name, cron_expr, enabled, last_tick_at, last_fired_at, fire_count, skip_count,
       coalesce(last_error, '') as last_error
from workflow.schedules order by name;

\echo
\echo '=== cron jobs ==='
select j.jobname, j.schedule, j.username,
       count(d.*) filter (where d.status = 'succeeded') as ok,
       count(d.*) filter (where d.status <> 'succeeded') as not_ok,
       max(d.start_time) as last_run
from cron.job j
left join cron.job_run_details d on d.jobid = j.jobid
group by j.jobname, j.schedule, j.username
order by j.jobname;

do $$
declare v_at timestamptz;
begin
    select max(d.start_time) into v_at
      from cron.job_run_details d join cron.job j on j.jobid = d.jobid
     where j.jobname = 'workflow-tick';
    raise notice 'workflow/03: pg_cron is driving workflow.tick() as `scheduler` (last: %)', v_at;
    raise notice 'workflow/03: the tick reaches workflow.schedules -- cron.database_name is right';
end $$;
