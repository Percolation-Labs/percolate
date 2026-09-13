-- RETENTION, THE PLAN GATE, AND THE OPERATOR VIEWS -- schema.sql's
-- "Operating at scale" section, asserted.
--
-- Everything in that section was written from a real measurement and every one
-- of these assertions comes from a defect a review of it found afterwards. The
-- pattern is worth naming, because it is the same one four times: the code was
-- correct on the shape it was developed against, and wrong on the shape it
-- exists for.
--
--   RETENTION EXCLUDED EVERY RUN THAT EVER CALLED AN AGENT, forever, on the
--   stated reasoning that a foreign key would abort the delete. The key is
--   `on delete set null`, so that reason was wrong -- but removing the clause
--   aborts the purge anyway, on a CHECK in the other schema
--   (`scheduled_runs_name_their_task`) that refuses the null the FK writes.
--   The guard belongs to SCHEDULED agent runs only, and an interactive one
--   must no longer hold its workflow run hostage. §1.
--
--   IT LEFT THE EVENT LOG BEHIND ENTIRELY. task_events has no foreign key to
--   tasks, so purging a backlog left four to six orphaned event rows per task
--   and replaced a table that only grew with one that grows faster. §2.
--
--   `runs_skipped` COUNTED EVERY RUN THE BATCH LIMIT HAD NOT REACHED, so an
--   operator was told references were blocking retention when nothing was. §3.
--
--   THE VIEWS WERE GRANTED TO `authenticated`, which -- being owner-privileged
--   over RLS-enabled tables -- handed every logged-in user every tenant's
--   stuck work. §4.
--
-- The gate assertions (§5, §6) are about the one function in this collection
-- whose entire design premise is that a false pass is worse than no answer.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- ---------------------------------------------------------------------
-- Fixture: two finished runs old enough to purge, each with tasks and the
-- transition events those tasks generated.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_ret', '{"steps":[{"key":"a", "kind":"work", "queue":"t-ret"}]}');

do $$
declare
    v_plain  uuid;
    v_agenty uuid;
    v_task   uuid;
    v_agent  uuid;
    v_events bigint;
    v_session uuid := gen_random_uuid();
    v_r      record;
begin
    v_plain  := workflow.start_workflow('t_ret', '{}'::jsonb);
    v_agenty := workflow.start_workflow('t_ret', '{}'::jsonb);

    -- Both finish, which is what makes them eligible, and both accumulate
    -- events on the way -- one row per status transition.
    for v_r in select id, run_id from workflow.tasks
                where run_id in (v_plain, v_agenty) loop
        perform workflow.complete_task(v_r.id, '{"result": "ok"}'::jsonb);
    end loop;
    update workflow.runs set status = 'succeeded', completed_at = now() - interval '90 days'
     where id in (v_plain, v_agenty);

    select count(*) into v_events from workflow.task_events
     where run_id in (v_plain, v_agenty);
    if v_events = 0 then
        raise exception 'the fixture produced no task_events, so §2 would prove nothing';
    end if;

    -- The second run gets a SCHEDULED agent run hung off one of its tasks,
    -- which is the only shape that pins it: agentic.runs carries `check
    -- (trigger_kind <> 'scheduled' or workflow_task_id is not null)`, so the
    -- FK's `on delete set null` writes a null that the CHECK refuses and the
    -- whole purge transaction aborts.
    if to_regclass('agentic.runs') is not null then
        select id into v_task from workflow.tasks where run_id = v_agenty limit 1;
        select id into v_agent from agentic.agents limit 1;
        if v_agent is not null then
            insert into agentic.runs (agent_id, owner_id, trigger_kind,
                                      workflow_task_id, status)
            values (v_agent, gen_random_uuid(), 'scheduled', v_task, 'succeeded');

            -- And the first run gets an INTERACTIVE one, which does not pin
            -- anything: its reference nulls out cleanly. This is the case the
            -- old clause wrongly held back, and it is most of them.
            select id into v_task from workflow.tasks where run_id = v_plain limit 1;
            insert into agentic.sessions (id, owner_id, title)
            values (v_session, gen_random_uuid(), 'retention fixture');
            insert into agentic.runs (agent_id, owner_id, trigger_kind, session_id,
                                      workflow_task_id, status)
            values (v_agent, gen_random_uuid(), 'interactive', v_session, v_task,
                    'succeeded');
        end if;
    end if;

    -- ------------------------------------------------------------------
    -- 1. A RUN WHOSE AGENT RUN IS INTERACTIVE IS PURGED, and the reference
    --    nulls out. A run pinned by a SCHEDULED one is kept, and counted.
    -- 2. AND THE EVENTS OF WHATEVER IS PURGED GO WITH IT.
    -- ------------------------------------------------------------------
    declare
        v_res     record;
        v_pinned  boolean := to_regclass('agentic.runs') is not null and v_agent is not null;
    begin
        select * into v_res from workflow.purge_completed(interval '30 days', 50, 10);

        if exists (select 1 from workflow.runs where id = v_plain) then
            raise exception
                'retention left a finished 90-day-old run behind because an INTERACTIVE '
                'agent run referenced one of its tasks -- that reference nulls out '
                'cleanly and must not pin anything (purged % runs)', v_res.runs_purged;
        end if;
        if exists (select 1 from workflow.task_events where run_id = v_plain) then
            raise exception
                'retention purged a run''s tasks and left % of its event rows behind',
                (select count(*) from workflow.task_events where run_id = v_plain);
        end if;
        if v_res.events_purged < 1 then
            raise exception 'purge_completed reported no events purged';
        end if;

        if v_pinned then
            if not exists (select 1 from workflow.runs where id = v_agenty) then
                raise exception
                    'retention deleted a run pinned by a scheduled agent run -- the '
                    'delete should have aborted on scheduled_runs_name_their_task';
            end if;
            if v_res.runs_skipped < 1 then
                raise exception
                    'a run pinned by a scheduled agent run was not counted as skipped '
                    '(%), so the table stops shrinking with no explanation',
                    v_res.runs_skipped;
            end if;
        end if;
    end;
end $$;

-- ---------------------------------------------------------------------
-- 3. `runs_skipped` MEANS "HELD BACK BY A REFERENCE", NOT "NOT REACHED YET".
--
-- Ten eligible runs, one batch of two, one pass: eight are simply unreached
-- and none is blocked. The old count said eight were skipped, which sends an
-- operator looking for a reference that does not exist.
-- ---------------------------------------------------------------------
do $$
declare
    v_run  uuid;
    v_res  record;
    v_base bigint;
    i      int;
begin
    -- The baseline: whatever the previous block legitimately left pinned.
    -- p_max_batches = 0 purges nothing and computes only the count, which is a
    -- useful mode in its own right -- "what is retention unable to touch".
    select runs_skipped into v_base
      from workflow.purge_completed(interval '30 days', 1, 0);

    for i in 1..10 loop
        v_run := workflow.start_workflow('t_ret', '{}'::jsonb);
        update workflow.runs set status = 'succeeded',
               completed_at = now() - interval '90 days'
         where id = v_run;
    end loop;

    select * into v_res from workflow.purge_completed(interval '30 days', 2, 1);

    if v_res.runs_purged <> 2 then
        raise exception 'one batch of two purged % runs', v_res.runs_purged;
    end if;
    if v_res.runs_skipped <> v_base then
        raise exception
            'purge_completed reported % runs "skipped" against a baseline of % -- the '
            'ten just seeded hold nothing and were merely beyond p_max_batches',
            v_res.runs_skipped, v_base;
    end if;
end $$;

-- A run a schedule points at IS held back, and IS counted.
do $$
declare
    v_run uuid;
    v_res record;
begin
    v_run := workflow.start_workflow('t_ret', '{}'::jsonb);
    update workflow.runs set status = 'succeeded',
           completed_at = now() - interval '90 days'
     where id = v_run;
    insert into workflow.schedules (name, workflow_name, cron_expr, last_run_id)
    values ('t_ret_sched', 't_ret', '0 0 * * *', v_run);

    select * into v_res from workflow.purge_completed(interval '30 days', 50, 10);

    if not exists (select 1 from workflow.runs where id = v_run) then
        raise exception 'retention deleted the run a schedule points at';
    end if;
    if v_res.runs_skipped < 1 then
        raise exception
            'a run held back by a schedule was not counted as skipped (%)',
            v_res.runs_skipped;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 3b. A PURGE THAT WOULD OUTLIVE ITS CALLER'S statement_timeout STOPS AND
--     KEEPS WHAT IT DID, rather than being cancelled and rolling all of it
--     back.
--
-- pg_cron runs the nightly purge as `scheduler`, under statement_timeout 60s.
-- Measured on 100k finished runs, that call was cancelled at 64.8s and purged
-- nothing, and would have been every night. Deletes are slowed here by a
-- trigger so that twenty one-run batches need 6s against a 4s bound: without a
-- deadline the call is cancelled at 4s; with one it stops starting batches at
-- 2s and returns what it purged.
-- ---------------------------------------------------------------------
create function workflow.t_slow_delete() returns trigger language plpgsql as
$$ begin perform pg_sleep(0.3); return old; end $$;
create trigger t_slow_delete before delete on workflow.runs
    for each row execute function workflow.t_slow_delete();

do $$
declare v_run uuid; i int;
begin
    for i in 1..20 loop
        v_run := workflow.start_workflow('t_ret', '{}'::jsonb);
        update workflow.runs set status = 'succeeded',
               completed_at = now() - interval '90 days'
         where id = v_run;
    end loop;
end $$;

set local statement_timeout = '4s';
do $$
declare v_res record;
begin
    select * into v_res from workflow.purge_completed(interval '30 days', 1, 1000);
    if v_res.runs_purged < 1 then
        raise exception 'a purge that stopped at its deadline purged nothing (%)', v_res;
    end if;
end $$;
set local statement_timeout = 0;

drop trigger t_slow_delete on workflow.runs;
drop function workflow.t_slow_delete();
-- The runs this block left unpurged still hold `ready` tasks on t-ret, which
-- would make t-ret the deepest queue §6's plan gate judges. Cleared, so §6
-- judges what it seeds.
select from workflow.purge_completed(interval '30 days', 50, 1000);

-- ---------------------------------------------------------------------
-- 4. THE OPERATOR VIEWS ARE NOT GRANTED TO CALLERS.
--
-- workflow.runs and tasks carry RLS, and these views are owner-privileged --
-- so a grant to `authenticated` makes them a read of every tenant's rows with
-- the policies evaluated as the owner that bypasses them. Every operator view
-- that came before them is ungranted; these three now match.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(table_name || ' -> ' || grantee, ', ')
      into v_bad
      from information_schema.role_table_grants
     where table_schema = 'workflow'
       and table_name in ('v_unclaimable', 'v_backlog', 'v_capacity',
                          'v_queue_depth', 'v_stuck_tasks', 'v_lease_violations')
       and grantee in ('authenticated', 'web_anon', 'PUBLIC');
    if v_bad is not null then
        raise exception
            'an operator view over RLS-enabled tables is readable by a caller: %. '
            'These are read as the owner, by an operator -- a REST surface needs a '
            'security_invoker view or a definer function that filters.', v_bad;
    end if;

    if has_function_privilege('authenticated', 'workflow.check_hot_paths(int)', 'execute') then
        raise exception
            'check_hot_paths is SECURITY DEFINER and returns queue names and backlog '
            'depth; `authenticated` should not be able to call it';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. HEADROOM DOES NOT COUNT SLOTS A CALLER CANNOT HAVE.
--
-- The incident this view was written for is the case where the last free slots
-- were the superuser-reserved ones: headroom read 3 and an operator had zero
-- usable connections and no way in.
-- ---------------------------------------------------------------------
do $$
declare v record;
begin
    select * into v from workflow.v_capacity;
    if v.headroom > v.max_connections - v.reserved then
        raise exception
            'v_capacity reports headroom % against max_connections % with % reserved '
            '-- reserved slots are not headroom', v.headroom, v.max_connections, v.reserved;
    end if;
    -- AND IT STILL COUNTS SOMETHING AS THE ROLE THAT READS IT. Narrowing
    -- in_use to `backend_type = 'client backend'` reports zero for any role
    -- that owns no backends -- which is app_owner, and every operator -- so
    -- the headroom view would never warn. This assertion is the one that
    -- caught it.
    if v.in_use < 1 then
        raise exception
            'v_capacity reports % backends in use while this session is one of them '
            '-- pg_stat_activity restricts its columns for a role that owns no '
            'backends, so a filter on backend_type reads as zero usage', v.in_use;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. THE PLAN GATE COUNTS WHAT ITS PLAN FILTERS ON.
--
-- The depth check counted `status = 'ready'` while the query it explains also
-- requires `run_after <= now()`. A queue of backing-off tasks therefore
-- satisfied the depth gate and the gate then explained a query that matched
-- none of them -- a pass issued on a plan for zero rows, which is the
-- shallow-queue false pass in a different disguise.
-- ---------------------------------------------------------------------
do $$
declare
    v_run uuid;
    v_res record;
begin
    perform workflow.seed_load('t-gate', 50);
    update workflow.tasks set run_after = now() + interval '1 hour'
     where queue = 't-gate';

    select * into v_res from workflow.check_hot_paths(10);
    if v_res.verdict <> 'inconclusive' then
        raise exception
            'the gate returned % on a queue of 50 tasks that are all backing off -- '
            'nothing is claimable, so there is nothing to judge (%)',
            v_res.verdict, v_res.detail;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 7. THE SUPERSEDED substitute_item IS GONE, NOT SHADOWED.
--
-- `create or replace` with a new parameter list creates an overload, so the
-- three-argument body stayed resident in every database that had already
-- applied the file -- and it cannot resolve {{items}}, silently, for any
-- caller still on that arity.
-- ---------------------------------------------------------------------
do $$
begin
    if to_regprocedure('workflow.substitute_item(jsonb,jsonb,text)') is not null then
        raise exception
            'the three-argument substitute_item is still installed beside the '
            'four-argument one -- a caller on that arity gets a body that drops {{items}}';
    end if;
    -- §20a-ter added the brace sentinel as a fifth, defaulted argument. The
    -- four-argument form is dropped by the same file, and a stale copy beside
    -- the new one would be exactly the resident-old-arity hazard above: a
    -- caller on four arguments would get a body that does not escape row text.
    if to_regprocedure('workflow.substitute_item(jsonb,jsonb,jsonb,text)') is not null then
        raise exception
            'the four-argument substitute_item is still installed beside the '
            'five-argument one -- a caller on that arity would not escape row text';
    end if;
    if to_regprocedure('workflow.substitute_item(jsonb,jsonb,jsonb,text,text)') is null then
        raise exception 'the five-argument substitute_item is missing';
    end if;
end $$;

do $$
begin
    raise notice 'workflow/12: retention purges a run whose task triggered an agent run, and nulls the reference';
    raise notice 'workflow/12: retention takes task_events with it, and reports how many';
    raise notice 'workflow/12: runs_skipped means held back by a reference, never "not reached yet"';
    raise notice 'workflow/12: the operator views and the plan gate are not readable by a caller';
    raise notice 'workflow/12: reserved connections are not headroom, and in_use counts something as the role that reads it';
    raise notice 'workflow/12: the plan gate is inconclusive on a queue where nothing is claimable';
    raise notice 'workflow/12: the superseded three-argument substitute_item is dropped, not shadowed';
end $$;

rollback;
