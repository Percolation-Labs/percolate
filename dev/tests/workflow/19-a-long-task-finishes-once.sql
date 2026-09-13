-- A TASK THAT TAKES LONGER THAN THE STALE TIMEOUT FINISHES ONCE (REM-109).
--
-- `workflow.heartbeat_task` shipped, was granted to `worker`, and was called by
-- nothing: `heartbeat_at` was written once, at claim. The reaper takes a lease
-- after `stale_timeout` of silence -- two minutes, from a default written out
-- four times -- while `ingest/transcribe.py` waits 300 seconds on one HTTP call
-- and `ingest/embed.py` waits 120. So a long transcription was failed and
-- re-queued while the first copy was still running, up to `max_attempts` times:
-- duplicate provider spend and duplicate writes on the ingestion path, every
-- copy eventually succeeding, and the last one winning.
--
-- WHY THE CLOCK IS NOT THE SUBJECT. Nothing here sleeps for two minutes. The
-- queue under test gets a `queue_config` row with a two-second timeout, which
-- is the same mechanism at a speed a gate can run -- and asserting through a
-- `queue_config` row also proves the row is read, which is the other half of
-- the defect: no deployment ships one, so every queue was on the default.
--
-- WHAT EACH SECTION MEASURES, because "long tasks work now" is four claims:
--   1. silence loses the lease. The old behaviour, asserted so section 2 is
--      known to be measuring a reaper that CAN fire in this fixture -- without
--      this the whole file would pass against a reaper that does nothing.
--   2. a heartbeat keeps it. The fix.
--   3. the reaper is bounded, and the next pass takes the rest.
--   4. the default has ONE home, so a fifth copy cannot drift from the other
--      four.

\set ON_ERROR_STOP on
begin;

do $$
declare
    v_run    uuid;
    v_def    uuid;
    v_task   uuid;
    v_task2  uuid;
    v_reaped int;
begin
    -- ---------------------------------------------------------------
    -- A queue whose timeout is two seconds rather than two minutes.
    -- ---------------------------------------------------------------
    insert into workflow.queue_config (queue, stale_timeout)
    values ('rem109', interval '2 seconds')
    on conflict (queue) do update set stale_timeout = interval '2 seconds';

    -- A real step, because validate_spec refuses an empty one -- which is the
    -- database being right and is why this is inserted rather than mocked.
    insert into workflow.definitions (name, spec)
    values ('rem109-long',
            '{"steps":[{"key":"slow","kind":"work","queue":"rem109"}]}'::jsonb)
    returning id into v_def;

    insert into workflow.runs (workflow_def_id, status)
    values (v_def, 'running') returning id into v_run;

    -- ---------------------------------------------------------------
    -- 1. SILENCE LOSES THE LEASE -- the old behaviour, and the control.
    -- ---------------------------------------------------------------
    insert into workflow.tasks (run_id, queue, step_key, kind, status,
                                claimed_by, heartbeat_at, attempts, max_attempts)
    values (v_run, 'rem109', 'silent', 'work', 'running',
            'w-silent', now() - interval '10 seconds', 1, 3)
    returning id into v_task;

    v_reaped := workflow.reap_stale_tasks();
    if v_reaped < 1 then
        raise exception 'the reaper took nothing from a lease silent for 10s '
                        'against a 2s timeout -- every later assertion in this '
                        'file would pass against a reaper that cannot fire';
    end if;
    -- `in ('running', '(absent)')` rather than `= 'running'`: a missing row
    -- makes the subquery NULL and `if NULL then` does not fire, so the plain
    -- comparison would have passed had the insert above not landed. The
    -- assertion-audit gate caught exactly that in this file's first version,
    -- which is the class the whole gate exists for.
    if coalesce((select status from workflow.tasks where id = v_task), '(absent)')
       in ('running', '(absent)') then
        raise exception 'a task silent for five times its timeout is %, so it '
                        'kept its lease or never existed',
                        coalesce((select status from workflow.tasks where id = v_task),
                                 '(absent)');
    end if;

    -- ---------------------------------------------------------------
    -- 2. A HEARTBEAT KEEPS IT. The fix, and the point of the file.
    -- ---------------------------------------------------------------
    insert into workflow.tasks (run_id, queue, step_key, kind, status,
                                claimed_by, heartbeat_at, attempts, max_attempts)
    values (v_run, 'rem109', 'beating', 'work', 'running',
            'w-beating', now() - interval '10 seconds', 1, 3)
    returning id into v_task2;

    -- What the worker loop now does while its handler runs. One call is
    -- enough: the claim is that a beat moves the deadline, not that a
    -- particular cadence does.
    if not workflow.heartbeat_task(v_task2, 'w-beating') then
        raise exception 'heartbeat_task refused a lease its own worker holds -- '
                        'the worker cannot keep a task alive at all';
    end if;

    v_reaped := workflow.reap_stale_tasks();
    if (select status from workflow.tasks where id = v_task2) is distinct from 'running' then
        raise exception 'a task that heartbeated was still reaped: status %, '
                        'which is REM-109 unfixed -- a long task runs twice',
                        (select status from workflow.tasks where id = v_task2);
    end if;
    if (select attempts from workflow.tasks where id = v_task2) is distinct from 1 then
        raise exception 'a heartbeated task had its attempt count moved, so '
                        'something re-queued it';
    end if;

    -- ---------------------------------------------------------------
    -- 3. THE REAPER IS BOUNDED, and what it leaves is still stale.
    -- ---------------------------------------------------------------
    insert into workflow.tasks (run_id, queue, step_key, kind, status,
                                claimed_by, heartbeat_at, attempts, max_attempts)
    select v_run, 'rem109', 'stale-' || g, 'work', 'running',
           'w-dead', now() - interval '30 seconds', 1, 3
    from generate_series(1, 5) g;

    v_reaped := workflow.reap_stale_tasks(2);
    if v_reaped <> 2 then
        raise exception 'reap_stale_tasks(2) took % rows, not 2 -- the limit is '
                        'not bounding the pass, so a tick still costs the size '
                        'of the backlog', v_reaped;
    end if;
    v_reaped := workflow.reap_stale_tasks(10);
    if v_reaped <> 3 then
        raise exception 'the next pass took % of the 3 remaining stale leases -- '
                        'a bounded pass is dropping work rather than deferring '
                        'it', v_reaped;
    end if;

    -- The old zero-arg signature must be GONE. Measured in this database by
    -- re-creating it beside the new one: Postgres then refuses the call --
    -- `function workflow.reap_stale_tasks() is not unique` -- so the cron job
    -- errors every minute and the reaper never runs. This assertion was
    -- verified by making it fail that way, not only by passing.
    if (select count(*) from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'workflow' and p.proname = 'reap_stale_tasks') <> 1 then
        raise exception 'workflow.reap_stale_tasks has % definitions -- the '
                        'zero-arg one was left beside the bounded one, so '
                        '`reap_stale_tasks()` is ambiguous and cron errors',
                        (select count(*) from pg_proc p
                          join pg_namespace n on n.oid = p.pronamespace
                         where n.nspname = 'workflow' and p.proname = 'reap_stale_tasks');
    end if;

    -- ---------------------------------------------------------------
    -- 4. ONE HOME FOR THE DEFAULT, so a fifth copy cannot appear.
    -- ---------------------------------------------------------------
    if workflow.queue_stale_timeout('a-queue-with-no-row')
       is distinct from workflow.stale_timeout_default() then
        raise exception 'a queue with no config row did not get the default '
                        'timeout, so the fallback has more than one value';
    end if;
    if workflow.queue_stale_timeout('rem109') is distinct from interval '2 seconds' then
        raise exception 'queue_stale_timeout ignored the queue_config row, so a '
                        'worker pacing from it would use the wrong period -- and '
                        'no deployment ships a row, which is half the defect';
    end if;

    raise notice 'workflow/19: a heartbeated task keeps its lease past the stale '
                 'timeout and is not re-run; the reaper is bounded and defers '
                 'the rest; the timeout has one home';
end $$;

-- ---------------------------------------------------------------
-- 5. AND THE ROLE THAT PACES FROM IT CAN READ IT.
--
-- §4 asks as the owner, and the owner could always read it. The caller the
-- grant exists for is `worker`, and on 0.2.0 that call raised `permission
-- denied for function stale_timeout_default`. percolate-core's heartbeat then
-- fell back to a fixed period, so a queue under about 80s was reaped
-- mid-handler.
-- ---------------------------------------------------------------
set local role worker;
do $$
begin
    if workflow.queue_stale_timeout('rem109') is distinct from interval '2 seconds' then
        raise exception 'as worker, queue_stale_timeout(''rem109'') returned %, not the '
                        'queue''s 2 seconds', workflow.queue_stale_timeout('rem109');
    end if;
    if workflow.queue_stale_timeout('a-queue-with-no-row') is distinct from interval '2 minutes' then
        raise exception 'as worker, a queue with no row did not get the default';
    end if;
end $$;
reset role;

rollback;
