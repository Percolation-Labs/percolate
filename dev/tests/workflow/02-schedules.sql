-- SCHEDULES -- a scheduled workflow is a row, and the ticker is the only clock.
--
-- `schema.sql` §19. Everything here is asserted by running it, because the
-- failure mode of a scheduler is silence: a schedule that never fires, or one
-- that fires twice, produces no error anywhere. Both are checked below.
--
-- tick() takes an explicit timestamp precisely so this file can drive the
-- clock. Nothing here sleeps, and nothing here depends on pg_cron being
-- installed -- pg_cron is one caller of tick(), not the mechanism.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- ---------------------------------------------------------------------
-- 1. The cron matcher, against a known instant.
--
-- 2026-08-31 09:05 UTC is a MONDAY, the 31st, in August. Every row below is
-- chosen so that a plausible implementation bug flips exactly one of them.
-- ---------------------------------------------------------------------
do $$
declare
    v_ts timestamptz := '2026-08-31 09:05:00+00';
    v_case record;
begin
    for v_case in
        select * from (values
            ('* * * * *',       true,  'every minute'),
            ('5 9 * * *',       true,  'exact minute and hour'),
            ('0 9 * * *',       false, 'wrong minute'),
            ('5 8 * * *',       false, 'wrong hour'),
            ('*/5 * * * *',     true,  'step divides the minute'),
            ('*/7 * * * *',     false, 'step does not divide the minute'),
            ('0-10 9 * * *',    true,  'range'),
            ('6-10 9 * * *',    false, 'range excludes'),
            ('5,17,44 9 * * *', true,  'list'),
            ('4,6 9 * * *',     false, 'list excludes'),
            ('5 9 31 8 *',      true,  'day-of-month and month'),
            ('5 9 30 8 *',      false, 'wrong day-of-month'),
            ('5 9 * 7 *',       false, 'wrong month'),
            ('5 9 * * 1',       true,  'Monday as 1'),
            ('5 9 * * 0',       false, 'not Sunday'),
            -- Vixie cron's OR rule: with BOTH day fields restricted, either
            -- matching fires. The 13th is not today, but Monday is -- so this
            -- must be TRUE. An implementation that ANDs them returns false
            -- here, and every crontab line copied in from elsewhere then
            -- means something different than it did.
            ('5 9 13 * 1',      true,  'dom OR dow when both restricted'),
            ('5 9 13 * 2',      false, 'neither dom nor dow matches'),
            -- With only ONE of them restricted the rule is a plain AND.
            ('5 9 13 * *',      false, 'dom alone must still exclude')
        ) as t(expr, expected, why)
    loop
        if workflow.cron_matches(v_case.expr, v_ts) <> v_case.expected then
            raise exception 'cron_matches(%) should be % -- %',
                v_case.expr, v_case.expected, v_case.why;
        end if;
    end loop;
end $$;

-- Sunday is both 0 and 7, as in every real crontab.
do $$
declare v_sun timestamptz := '2026-09-06 00:00:00+00';   -- a Sunday
begin
    if not workflow.cron_matches('0 0 * * 0', v_sun) then
        raise exception 'Sunday must match dow 0';
    end if;
    if not workflow.cron_matches('0 0 * * 7', v_sun) then
        raise exception 'Sunday must also match dow 7';
    end if;
end $$;

-- The timezone is the schedule's, not the server's. "09:00 in New York" is a
-- different instant from "09:00 UTC", and a scheduler that silently means the
-- latter is wrong in a way nobody notices until a report lands at 4am.
do $$
declare v_ts timestamptz := '2026-08-31 13:00:00+00';   -- 09:00 America/New_York
begin
    if not workflow.cron_matches('0 9 * * *', v_ts, 'America/New_York') then
        raise exception 'cron_matches ignored the schedule timezone';
    end if;
    if workflow.cron_matches('0 9 * * *', v_ts, 'UTC') then
        raise exception 'the same instant must NOT match 09:00 UTC';
    end if;
end $$;

-- A malformed expression must fail at authoring time. The alternative is a
-- schedule that never fires and never says why.
do $$
declare
    v_bad text;
    v_expr text;
begin
    foreach v_expr in array array[
        '* * * *',            -- four fields
        '* * * * * *',        -- six fields
        '60 * * * *',         -- minute out of range
        '* 24 * * *',         -- hour out of range
        '*/0 * * * *',        -- zero step
        'every-minute',       -- not cron at all
        '5 9 * * MON'         -- names are not supported, and must say so
    ]
    loop
        begin
            perform workflow.cron_matches(v_expr, now());
            v_bad := coalesce(v_bad || ', ', '') || quote_literal(v_expr);
        exception when others then
            null;   -- expected
        end;
    end loop;
    if v_bad is not null then
        raise exception 'these malformed cron expressions were accepted: %', v_bad;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. Fixture: a workflow that needs nothing deployed.
--
-- `content_drift` is an allow-listed §17 sql step, so this whole run
-- executes inside Postgres with no worker, no queue and no network -- which
-- is what makes it a fair test of the SCHEDULER rather than of the stack
-- around it.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_sched_drift', '{"steps":[
    {"key":"drift", "kind":"sql", "queue":"none",
     "input":{"function":"content_drift","args":[]}}
 ]}');

-- ---------------------------------------------------------------------
-- 3. A schedule is a row, and the ticker starts runs from it.
-- ---------------------------------------------------------------------
do $$
declare
    v_id      uuid;
    v_started int;
    v_run     uuid;
    -- 09:05 on a Monday; the schedule below fires at :05 past every hour.
    v_match   timestamptz := '2026-08-31 09:05:00+00';
    -- BEFORE the match, not after: tick() dedupes with `last_tick_at <
    -- this_minute`, so a clock that goes backwards stalls a schedule rather
    -- than double-firing it. That is the safe direction, and it means a test
    -- has to drive time forwards like the real ticker does.
    v_miss    timestamptz := '2026-08-31 09:04:00+00';
begin
    v_id := workflow.schedule_workflow('t_hourly', 't_sched_drift', '5 * * * *');
    if v_id is null then
        raise exception 'schedule_workflow returned no id';
    end if;

    -- A minute that does not match must start nothing -- but must still be
    -- recorded as evaluated, or the ticker cannot be distinguished from a
    -- ticker that is not running.
    v_started := workflow.tick(v_miss);
    if v_started <> 0 then
        raise exception 'tick fired % run(s) on a non-matching minute', v_started;
    end if;
    if (select last_tick_at from workflow.schedules where name = 't_hourly')
       is distinct from date_trunc('minute', v_miss) then
        raise exception 'a non-matching tick must still record last_tick_at';
    end if;
    if (select last_fired_at from workflow.schedules where name = 't_hourly') is not null then
        raise exception 'a non-matching tick must not set last_fired_at';
    end if;

    -- A matching minute starts exactly one run.
    v_started := workflow.tick(v_match);
    if v_started <> 1 then
        raise exception 'tick started % run(s) on a matching minute, expected 1', v_started;
    end if;

    select last_run_id into v_run from workflow.schedules where name = 't_hourly';
    if v_run is null then
        raise exception 'schedule did not record the run it started';
    end if;

    -- The run is an ORDINARY run: same table, same tasks, same engine. If a
    -- scheduled run were special in any way, retry/reaper/compensation would
    -- all need a second implementation.
    if not exists (select 1 from workflow.tasks where run_id = v_run and step_key = 'drift') then
        raise exception 'scheduled run has no tasks -- it did not go through start_workflow';
    end if;

    -- And because the only step is a `sql` step, it has already executed --
    -- with nothing deployed anywhere.
    if (select status from workflow.tasks where run_id = v_run and step_key = 'drift') <> 'done' then
        raise exception 'the sql step in a scheduled run did not execute in-database';
    end if;

    -- 4. THE SAME MINUTE, TWICE, MUST NOT DOUBLE-FIRE.
    -- Two overlapping tickers, a retried transaction, or an operator running
    -- tick() by hand next to pg_cron all produce this. The engine's own
    -- external_id idempotency is what makes it safe, so this also asserts
    -- that tick() actually uses it.
    v_started := workflow.tick(v_match);
    if v_started <> 0 then
        raise exception 'the same minute fired twice';
    end if;
    if (select count(*) from workflow.runs r
         join workflow.definitions d on d.id = r.workflow_def_id
        where d.name = 't_sched_drift') <> 1 then
        raise exception 'a second run was created for the same scheduled minute';
    end if;

    if (select fire_count from workflow.schedules where name = 't_hourly') <> 1 then
        raise exception 'fire_count does not match the number of runs started';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. Overlap: a slow run must not accumulate a queue of its own successors.
--
-- world-model-ingestion/brief.md §5's overlapping-poll problem, which is the
-- reason overlap_policy exists at all: a channel polled every minute whose
-- fetch takes ninety seconds.
-- ---------------------------------------------------------------------
do $$
declare
    v_started int;
    v_run     uuid;
begin
    perform workflow.schedule_workflow('t_every_minute', 't_sched_drift', '* * * * *');

    v_started := workflow.tick('2026-08-31 10:00:00+00');
    if v_started <> 1 then
        raise exception 'expected the every-minute schedule to fire';
    end if;
    select last_run_id into v_run from workflow.schedules where name = 't_every_minute';

    -- Force the previous run to look still-running, which is the situation
    -- overlap_policy is about. (The sql step completed it immediately, which
    -- is exactly why this has to be staged rather than waited for.)
    update workflow.runs set status = 'running' where id = v_run;

    v_started := workflow.tick('2026-08-31 10:01:00+00');
    if v_started <> 0 then
        raise exception 'overlap_policy=skip started a run while the previous one was running';
    end if;
    if (select skip_count from workflow.schedules where name = 't_every_minute') <> 1 then
        raise exception 'a skip must be counted, not silent';
    end if;

    -- Once it finishes, the next tick proceeds. A skip is a skip, not a stop.
    update workflow.runs set status = 'completed' where id = v_run;
    v_started := workflow.tick('2026-08-31 10:02:00+00');
    if v_started <> 1 then
        raise exception 'the schedule did not resume after its run finished';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. One broken schedule must not stop the others.
--
-- The whole point of a ticker is that it keeps running. A schedule whose
-- workflow has been deleted is the ordinary way this happens, and it must
-- record WHY on the row rather than aborting the tick for every other
-- schedule in the database.
-- ---------------------------------------------------------------------
do $$
declare
    v_started int;
    v_err     text;
begin
    perform workflow.schedule_workflow('t_broken', 't_sched_drift', '* * * * *');
    perform workflow.schedule_workflow('t_healthy', 't_sched_drift', '* * * * *');

    -- Break one of them behind schedule_workflow()'s validation, the way
    -- deleting a definition later would.
    update workflow.schedules set workflow_name = 't_does_not_exist' where name = 't_broken';

    v_started := workflow.tick('2026-08-31 11:00:00+00');

    select last_error into v_err from workflow.schedules where name = 't_broken';
    if v_err is null then
        raise exception 'a failing schedule recorded no error';
    end if;
    if (select last_fired_at from workflow.schedules where name = 't_broken') is not null then
        raise exception 'a failing schedule must not claim to have fired';
    end if;

    -- The healthy one fired in the same tick.
    if (select last_run_id from workflow.schedules where name = 't_healthy') is null then
        raise exception 'a broken schedule stopped a healthy one from firing';
    end if;
    if v_started < 1 then
        raise exception 'tick reported no runs started despite a healthy schedule firing';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 7. Authoring-time validation: the errors worth catching are the ones that
--    would otherwise be silence once a minute forever.
-- ---------------------------------------------------------------------
do $$
begin
    begin
        perform workflow.schedule_workflow('t_nope', 'no_such_workflow', '* * * * *');
        raise exception 'scheduling an unknown workflow was accepted';
    exception when others then
        if sqlerrm like 'scheduling an unknown workflow%' then raise; end if;
    end;

    begin
        perform workflow.schedule_workflow('t_nope', 't_sched_drift', 'not a cron expression');
        raise exception 'a malformed cron expression was accepted';
    exception when others then
        if sqlerrm like 'a malformed cron%' then raise; end if;
    end;

    begin
        perform workflow.schedule_workflow('t_nope', 't_sched_drift', '* * * * *',
                                           '{}'::jsonb, 'Mars/Olympus_Mons');
        raise exception 'an unknown timezone was accepted';
    exception when others then
        if sqlerrm like 'an unknown timezone%' then raise; end if;
    end;
end $$;

-- Re-registering by name edits rather than duplicates, so a deployment can
-- re-run its own seed without accumulating schedules.
do $$
declare v_first uuid; v_second uuid;
begin
    v_first  := workflow.schedule_workflow('t_idem', 't_sched_drift', '0 1 * * *');
    v_second := workflow.schedule_workflow('t_idem', 't_sched_drift', '0 2 * * *');
    if v_first <> v_second then
        raise exception 'schedule_workflow created a second schedule for the same name';
    end if;
    if (select cron_expr from workflow.schedules where name = 't_idem') <> '0 2 * * *' then
        raise exception 'schedule_workflow did not update the existing schedule';
    end if;
end $$;

-- Disable is reversible and keeps the row; unschedule is the destructive one
-- and is not an error when there is nothing to delete.
do $$
begin
    perform workflow.set_schedule_enabled('t_idem', false);
    if workflow.tick('2026-08-31 02:00:00+00') <> 0 then
        raise exception 'a disabled schedule fired';
    end if;
    if not exists (select 1 from workflow.schedules where name = 't_idem') then
        raise exception 'disabling a schedule deleted it';
    end if;

    if workflow.unschedule_workflow('t_idem') is not true then
        raise exception 'unschedule_workflow did not report deleting the schedule';
    end if;
    if workflow.unschedule_workflow('t_idem') is not false then
        raise exception 'unschedule_workflow raised on an already-deleted schedule';
    end if;
end $$;

rollback;

-- ---------------------------------------------------------------------
-- 8. Authorization -- separately, because it must be tested as a USER, over
--    the same connection shape PostgREST actually uses.
--
-- schedule_workflow/set_schedule_enabled/unschedule_workflow are SECURITY
-- DEFINER and granted to `authenticated`, which is the exact shape that was
-- CONFIRMED EXPLOITABLE for cancel_run (integration-rbac.sql (e)): a definer
-- function acting on a caller-supplied identifier bypasses RLS, so it must do
-- its own check. Without one, any authenticated user could repoint or delete
-- any other tenant's schedule.
--
-- SET SESSION AUTHORIZATION, not just SET ROLE, and that distinction is the
-- test. assert_schedule_access() lets the DEPLOYMENT through by asking
-- whether session_user is a member of the role owning the table -- it has to
-- ask about session_user, because inside a SECURITY DEFINER function
-- current_user is always the function's owner. In a superuser psql session
-- session_user is `p8`, which is a member of everything, so a test that only
-- did SET ROLE would pass while checking nothing. Becoming `authenticator`
-- and then SET ROLE `authenticated` is precisely what PostgREST does per
-- request, and `authenticator` is deliberately not a member of app_owner.
-- ---------------------------------------------------------------------
begin;

set local role app_owner;

insert into workflow.definitions (name, spec) values
('t_authz_wf', '{"steps":[{"key":"drift","kind":"sql","queue":"none",
                           "input":{"function":"content_drift","args":[]}}]}');

do $$
begin
    -- Stashed in GUCs rather than a temp table: these have to survive the
    -- session-authorization change below, and a table's grants would not.
    perform set_config('test.alice',
        rbac.create_user_with_password('sched-alice@test.com', 'pw-alice-12345')::text, true);
    perform set_config('test.mallory',
        rbac.create_user_with_password('sched-mallory@test.com', 'pw-mallory-123')::text, true);
end $$;

-- From here on we are an ordinary REST caller, with no privilege of our own.
set local session authorization authenticator;
set local role authenticated;

do $$
declare
    v_alice   uuid := current_setting('test.alice')::uuid;
    v_mallory uuid := current_setting('test.mallory')::uuid;
begin
    -- Alice creates a schedule as herself. The owner comes from the JWT via
    -- the trigger, never from an argument -- there is no owner parameter to
    -- pass, which is the point.
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_alice::text)::text, true);
    perform workflow.schedule_workflow('t_alices', 't_authz_wf', '0 3 * * *');

    -- Read through the api view, never the base table: `authenticated` holds
    -- no table grant at all, which is itself part of the contract.
    if (select owner_id from workflow.schedules_api where name = 't_alices') is distinct from v_alice then
        raise exception 'the schedule was not stamped with its creator';
    end if;

    -- Mallory, authenticated but unprivileged, must not be able to touch it.
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_mallory::text)::text, true);

    begin
        perform workflow.unschedule_workflow('t_alices');
        raise exception 'PRIVILEGE ESCALATION: another user deleted a schedule they do not own';
    exception when others then
        if sqlerrm like 'PRIVILEGE ESCALATION%' then raise; end if;
    end;

    begin
        perform workflow.set_schedule_enabled('t_alices', false);
        raise exception 'PRIVILEGE ESCALATION: another user disabled a schedule they do not own';
    exception when others then
        if sqlerrm like 'PRIVILEGE ESCALATION%' then raise; end if;
    end;

    -- Repointing someone else's schedule is the worst of the three: it would
    -- run the attacker's workflow, on the owner's schedule, as the owner.
    begin
        perform workflow.schedule_workflow('t_alices', 't_authz_wf', '* * * * *');
        raise exception 'PRIVILEGE ESCALATION: another user repointed a schedule they do not own';
    exception when others then
        if sqlerrm like 'PRIVILEGE ESCALATION%' then raise; end if;
    end;

    -- Mallory can create his OWN schedule: the check restricts existing
    -- rows, it does not gate the feature.
    perform workflow.schedule_workflow('t_mallorys', 't_authz_wf', '0 4 * * *');
    if (select owner_id from workflow.schedules_api where name = 't_mallorys') is distinct from v_mallory then
        raise exception 'a user could not create their own schedule';
    end if;

    -- Back as Alice: her schedule is exactly as she left it. Checked from HER
    -- side because RLS means Mallory cannot see it to check -- which is the
    -- other half of the guarantee.
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_alice::text)::text, true);
    if (select cron_expr from workflow.schedules_api where name = 't_alices') <> '0 3 * * *' then
        raise exception 'the schedule was modified despite the check';
    end if;
    if (select enabled from workflow.schedules_api where name = 't_alices') is not true then
        raise exception 'the schedule was disabled despite the check';
    end if;

    -- Leave the session as Mallory for the RLS assertions below.
    perform set_config('request.jwt.claims',
        json_build_object('sub', v_mallory::text)::text, true);
end $$;

\echo
\echo '=== schedules mallory can see through the api view (expect: t_mallorys only) ==='
select name, cron_expr from workflow.schedules_api order by name;

do $$
begin
    if exists (select 1 from workflow.schedules_api where name = 't_alices') then
        raise exception 'RLS LEAK: another tenant''s schedule is visible through schedules_api';
    end if;
    if not exists (select 1 from workflow.schedules_api where name = 't_mallorys') then
        raise exception 'a user cannot see their own schedule through schedules_api';
    end if;
end $$;

rollback;

do $$ begin
    raise notice 'workflow/02: cron matching, incl. Vixie dom-OR-dow and timezones';
    raise notice 'workflow/02: one run per matching minute, none on a repeat tick';
    raise notice 'workflow/02: overlap skipped, counted, and resumed';
    raise notice 'workflow/02: a broken schedule records why and does not stop the others';
    raise notice 'workflow/02: a schedule cannot be repointed, disabled or deleted by a non-owner';
end $$;
