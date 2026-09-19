-- A PERSON'S SQL STEP READS ONLY THE TASK HISTORY OF RUNS THEY MAY SEE (REM-551).
--
-- A step's statement runs as api_viewer with the starter's claims
-- (user-rbac/roles.sql §2). api_viewer holds SELECT on workflow.task_events,
-- workflow.task_dependencies and workflow.rate_limits because it owns the
-- views over them, and none of the three had a policy -- so a step naming the
-- table rather than the view read every tenant's task history, the task input
-- copied into input_snapshot included, and every sign-in address in the rate
-- limiter. Each table now carries the scope its view applies.
--
--   1. A reads the events of A's run, input_snapshot included, and none of B's;
--   2. B reads B's and none of A's;
--   3. A reads the edges of A's run and none of B's;
--   4. api_viewer reads no personal rate-limit key, and still reads the others.
--
-- rbac/02 §10 is the class gate: it refuses any table a web role can reach with
-- RLS off. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000551a1', 'rem551-a@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000551b2', 'rem551-b@example.test', 'active');

select workflow.define_yaml($y$
name: rem551_probe
steps:
  - id: now
    sql: {function: p8ql, args: ['SELECT now()']}
$y$);

-- Two runs, each with two tasks, one depending on the other. Moving a task to
-- running is what writes the event with the input snapshot, through the same
-- trigger a worker's claim fires.
do $$
declare
    v_def uuid := (select id from workflow.definitions where name = 'rem551_probe' order by version desc limit 1);
    v_run uuid;
    v_t1  uuid;
    v_t2  uuid;
    who   text;
begin
    foreach who in array array['a1', 'b2'] loop
        insert into workflow.runs (workflow_def_id, owner_id)
        values (v_def, ('00000000-0000-4000-8000-0000000551' || who)::uuid) returning id into v_run;
        insert into workflow.tasks (run_id, step_key, kind, queue, input)
        values (v_run, 'first', 'sql', 'default', jsonb_build_object('secret', 'input of ' || who))
        returning id into v_t1;
        insert into workflow.tasks (run_id, step_key, kind, queue, input)
        values (v_run, 'second', 'sql', 'default', '{}'::jsonb) returning id into v_t2;
        insert into workflow.task_dependencies (task_id, depends_on_task_id) values (v_t2, v_t1);
        update workflow.tasks set status = 'running' where id = v_t1;
        perform set_config('rem551.run_' || who, v_run::text, true);
        perform set_config('rem551.edge_' || who, v_t2::text, true);
    end loop;
    if (select count(*) from workflow.task_events
         where run_id in (current_setting('rem551.run_a1')::uuid, current_setting('rem551.run_b2')::uuid)
           and input_snapshot is not null) <> 2 then
        raise exception 'the fixture wrote no input snapshots, so §1 and §2 would prove nothing';
    end if;
end $$;

insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
values ('login:rem551-a@example.test', 5, 5, 1), ('reset:rem551-a@example.test', 3, 3, 1),
       ('rem551:not-personal', 5, 5, 1)
on conflict do nothing;


-- 1. A, as a step runs: A's history, and none of B's.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000551a1"}';
set local role api_viewer;
do $$
declare
    own   uuid := current_setting('rem551.run_a1')::uuid;
    other uuid := current_setting('rem551.run_b2')::uuid;
begin
    if not exists (select 1 from workflow.task_events where run_id = own and input_snapshot->>'secret' = 'input of a1') then
        raise exception 'A cannot read the history of A''s own run -- the policy refuses the caller it is for';
    end if;
    if exists (select 1 from workflow.task_events where run_id = other) then
        raise exception 'A read % event(s) of B''s run from workflow.task_events, input included (REM-551)',
            (select count(*) from workflow.task_events where run_id = other);
    end if;
    if exists (select 1 from workflow.task_events where input_snapshot->>'secret' = 'input of b2') then
        raise exception 'A read B''s task input through task_events.input_snapshot (REM-551)';
    end if;
    raise notice 'rbac/19: A reads A''s task history and none of B''s';
end $$;
reset role;

-- 2. B, symmetrically.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000551b2"}';
set local role api_viewer;
do $$
begin
    if not exists (select 1 from workflow.task_events where run_id = current_setting('rem551.run_b2')::uuid) then
        raise exception 'B cannot read the history of B''s own run';
    end if;
    if exists (select 1 from workflow.task_events where run_id = current_setting('rem551.run_a1')::uuid) then
        raise exception 'B read the history of A''s run (REM-551)';
    end if;
    raise notice 'rbac/19: B reads B''s task history and none of A''s';
end $$;
reset role;

-- 3. The edges, through the task.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000551a1"}';
set local role api_viewer;
do $$
begin
    if not exists (select 1 from workflow.task_dependencies where task_id = current_setting('rem551.edge_a1')::uuid) then
        raise exception 'A cannot read the edge of A''s own run';
    end if;
    if exists (select 1 from workflow.task_dependencies where task_id = current_setting('rem551.edge_b2')::uuid) then
        raise exception 'A read the edge of B''s run from workflow.task_dependencies (REM-551)';
    end if;
    raise notice 'rbac/19: A reads the edges of A''s run and none of B''s';
end $$;
reset role;

-- 4. The rate limiter hides what its view hides.
set local role api_viewer;
do $$
begin
    if exists (select 1 from workflow.rate_limits where key like 'login:%' or key like 'reset:%') then
        raise exception 'api_viewer reads personal rate-limit keys from workflow.rate_limits: % (REM-551)',
            (select string_agg(key, ', ') from workflow.rate_limits where key like 'login:%' or key like 'reset:%');
    end if;
    if not exists (select 1 from workflow.rate_limits where key = 'rem551:not-personal') then
        raise exception 'the policy hides a rate-limit key that is not personal, so queues_api-style reads lose it';
    end if;
    raise notice 'rbac/19: api_viewer reads rate limits and no sign-in address';
end $$;
reset role;

rollback;
