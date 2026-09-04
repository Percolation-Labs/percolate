-- WORKFLOW SURFACE -- the failures that report success.
--
-- Every assertion here corresponds to a bug that was actually shipped in this
-- repo and found by executing a scenario, not by reasoning about one. They
-- share a shape: nothing raised, nothing crashed, and the run reported a
-- status that was not true. That shape is why the workflow engine is one of
-- the three surfaces this repo treats as load-bearing
-- (`meta/skills/spec-driven-development`, the section above §1).

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- ---------------------------------------------------------------------
-- Fixture: a two-step chain where the second step reads the first's output.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_chain', '{"steps":[
    {"key":"first",  "kind":"work", "queue":"t"},
    {"key":"second", "kind":"work", "queue":"t", "depends_on":["first"]}
 ]}');

do $$
declare
    v_run   uuid;
    v_first uuid;
    v_ctx   jsonb;
begin
    v_run := workflow.start_workflow('t_chain', '{"seed":1}'::jsonb);

    -- 1. START_WORKFLOW MUST CARRY THE INPUT.
    -- It once dropped `input`, `rate_key`, `saga_group` and the signal
    -- registration entirely: the run existed, looked healthy, and every
    -- template referencing {{run.*}} silently resolved to null.
    if (select input from workflow.runs where id = v_run) is distinct from '{"seed":1}'::jsonb then
        raise exception 'start_workflow dropped run input';
    end if;

    -- 2. AN OWNER IS STAMPED FROM THE VERIFIED JWT, NOT A PARAMETER.
    -- Runs once had no owner_id at all, which made them invisible to the
    -- person who created them -- a data-loss bug that looked like an empty
    -- list, not an error.
    if not exists (select 1 from information_schema.columns
                   where table_schema='workflow' and table_name='runs' and column_name='owner_id') then
        raise exception 'runs.owner_id is gone -- ownership cannot be enforced';
    end if;

    select id into v_first from workflow.tasks where run_id = v_run and step_key = 'first';

    -- 3. COMPLETE_TASK WRITES CONTEXT BEFORE STATUS.
    -- This is the ordering bug that matters most, because `sql` and `p8ql`
    -- steps execute the instant a dependency flips to ready. If status is
    -- written first, the dependent step can start and read a context that
    -- does not yet contain the value it depends on -- an off-by-one in time,
    -- producing a wrong answer with every task marked `done`.
    perform workflow.complete_task(v_first, '{"value":42}'::jsonb);

    select context into v_ctx from workflow.runs where id = v_run;
    if v_ctx -> 'first' is distinct from '{"value":42}'::jsonb then
        raise exception 'complete_task did not merge output into runs.context: %', v_ctx;
    end if;

    -- 4. THE MERGE MUST NOT SILENTLY MATCH ZERO ROWS.
    -- The original bug: the worker holds no JWT, so the UPDATE against
    -- runs was filtered by RLS and matched nothing. A zero-row UPDATE is
    -- not an error in Postgres. The fix was to make the state mutators
    -- SECURITY DEFINER, and this assertion is what notices if one stops
    -- being one.
    if (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'workflow' and p.proname = 'complete_task') is not true then
        raise exception 'complete_task is no longer SECURITY DEFINER -- '
                        'its context merge will silently match zero rows under RLS';
    end if;

    -- 5. THE DEPENDENT STEP IS ONLY NOW READY.
    if (select status from workflow.tasks where run_id = v_run and step_key = 'second') is distinct from 'ready' then
        raise exception 'dependent step did not become ready after its dependency completed';
    end if;

    raise notice 'workflow/01: chain ordering and context merge OK';
end $$;

-- ---------------------------------------------------------------------
-- 6. CANCELLATION IS AUTHORISED.
-- A confirmed exploit, not a hypothetical: cancel_run had no authz check
-- and a non-owner cancelled another user's run. The recursion into child
-- runs is handled by a separate cancel_run_unchecked rather than a
-- "skip authz" flag, because a flag is one bad caller away from being a
-- bypass.
-- ---------------------------------------------------------------------
do $$
begin
    if to_regprocedure('workflow.assert_run_access(uuid,text)') is null then
        raise exception 'assert_run_access is gone -- cancel_run has no authorization';
    end if;
    if pg_get_functiondef(to_regprocedure('workflow.cancel_run(uuid)')::oid)
       not like '%assert_run_access%' then
        raise exception 'cancel_run no longer calls assert_run_access';
    end if;
    raise notice 'workflow/01: cancel_run is authorized';
end $$;

-- ---------------------------------------------------------------------
-- 7. SAGA ROLLBACK IS JUDGED ON COMPENSATION TASKS, NOT FORWARD ONES.
-- The original check inspected forward tasks, which are all terminal by
-- the time compensation begins -- so a rollback reported itself complete
-- before a single compensating step had run. The link that made the
-- distinction expressible is tasks.compensates_task_id.
-- ---------------------------------------------------------------------
do $$
begin
    if not exists (select 1 from information_schema.columns
                   where table_schema='workflow' and table_name='tasks'
                     and column_name='compensates_task_id') then
        raise exception 'tasks.compensates_task_id is gone -- saga rollback '
                        'cannot distinguish compensating work from forward work';
    end if;
    raise notice 'workflow/01: saga compensation is distinguishable';
end $$;

-- ---------------------------------------------------------------------
-- 8. A DEPENDENCY NAMED TWICE IS STILL ONE DEPENDENCY.
--
-- workflow.task_dependencies is keyed on (task_id, depends_on_task_id) and
-- every writer inserts `on conflict do nothing`, so naming the same
-- dependency twice produces ONE row. pending_deps was counted from the
-- caller's list instead, in three separate functions, so it was 2. The
-- cascade decrements once per dependency that finishes, the count stops at 1,
-- and the step sits in `pending` for ever under a run that stays `running`
-- for ever.
--
-- It is the quietest failure in this file: no exception, no failed task, and
-- nothing for the reaper to collect -- reap_stale_tasks() looks for expired
-- leases on `running` tasks, and a task that never became ready never ran.
-- The only symptom is a run that does not end.
--
-- Both entry points are asserted because both had it, and a fix that landed
-- in one of two copies is this collection's most-repeated mistake.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_dupdep', '{"steps":[
    {"key":"a", "kind":"work", "queue":"t"},
    {"key":"b", "kind":"work", "queue":"t", "depends_on":["a","a"]}
 ]}');

do $$
declare
    v_run uuid;
    v_a   uuid;
    v_c   uuid;
begin
    -- (a) through start_workflow, which is what `needs: [a, a]` in YAML
    --     compiles to.
    v_run := workflow.start_workflow('t_dupdep', '{}'::jsonb);
    select id into v_a from workflow.tasks where run_id = v_run and step_key = 'a';

    if (select pending_deps from workflow.tasks where run_id = v_run and step_key = 'b')
       is distinct from (select count(*)::int from workflow.task_dependencies d
                          join workflow.tasks t on t.id = d.task_id
                         where t.run_id = v_run and t.step_key = 'b') then
        raise exception
            'pending_deps disagrees with the dependency rows it counts: % against % rows',
            (select pending_deps from workflow.tasks where run_id = v_run and step_key = 'b'),
            (select count(*) from workflow.task_dependencies d
              join workflow.tasks t on t.id = d.task_id
             where t.run_id = v_run and t.step_key = 'b');
    end if;

    perform workflow.complete_task(v_a, '{"result":"ok"}'::jsonb);

    if (select status from workflow.tasks where run_id = v_run and step_key = 'b')
       is distinct from 'ready' then
        raise exception
            'a step that named its one dependency twice never became ready (it is %) -- '
            'the run can no longer finish and nothing reported anything',
            (select status from workflow.tasks where run_id = v_run and step_key = 'b');
    end if;

    -- (b) through add_task, the dynamic path, with the same id twice.
    v_run := workflow.start_workflow('t_dupdep', '{}'::jsonb);
    select id into v_a from workflow.tasks where run_id = v_run and step_key = 'a';
    v_c := workflow.add_task(v_run, 'c', 't', array[v_a, v_a]);

    perform workflow.complete_task(v_a, '{"result":"ok"}'::jsonb);

    if (select status from workflow.tasks where id = v_c) is distinct from 'ready' then
        raise exception
            'add_task counted one dependency twice: the task is % with pending_deps %',
            (select status from workflow.tasks where id = v_c),
            (select pending_deps from workflow.tasks where id = v_c);
    end if;

    raise notice 'workflow/01: a dependency named twice is one dependency, through both writers';
end $$;

rollback;
