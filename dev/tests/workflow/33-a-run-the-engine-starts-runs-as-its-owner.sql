-- A RUN THE ENGINE STARTS FOR SOMEBODY RUNS AS THEM FROM ITS FIRST STEP (REM-1121).
--
-- tick fired a person's schedule, and start_child_workflow a sub_workflow on
-- a worker's completion, with no claims: the run was created ownerless and
-- the sql steps start_workflow drains on the spot ran as the definer, past
-- row security, before tick stamped the owner on. A child's name also
-- resolved as an operator. Asserted here, on the scheduler's and the
-- worker's own logins:
--   1. Alice's one sql step counts rbac.users; run by tick on her schedule it
--      counts what she sees, as her own start does, and the run is hers;
--   2. a child started by the worker for Alice's parent task is Alice's, and
--      its sql step counts what she sees;
--   3. a child naming Leo's private definition is refused for Alice's parent;
--   4. a schedule whose start fails leaves no claims behind for the next.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

\set alice '''00000000-0000-4000-8000-000000112101'''
\set leo   '''00000000-0000-4000-8000-000000112102'''
\set as_alice 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000112101"}''; set local role authenticated;'

begin;
insert into rbac.users (id, email, status) values
    (:alice, 'rem1121-alice@example.test', 'active'),
    (:leo,   'rem1121-leo@example.test',   'active');
insert into workflow.definitions (name, spec, owner_id, visibility) values
    ('rem1121_count', '{"steps":[{"key":"q","kind":"sql","queue":"none","input":{"statement":"select count(*) as n from rbac.users"}}]}', :alice, 'private'),
    ('rem1121_parent', '{"steps":[{"key":"call","kind":"work","queue":"rem1121"}]}', :alice, 'private'),
    ('rem1121_leos', '{"steps":[{"key":"q","kind":"sql","queue":"none","input":{"statement":"select 1 as n"}}]}', :leo, 'private');

-- What Alice sees, from her own start.
:as_alice
select workflow.start_workflow('rem1121_count', '{}'::jsonb) as direct \gset
select workflow.schedule_workflow('rem1121', 'rem1121_count', '* * * * *') \g /dev/null
-- A broken schedule of hers, named to sort first, so tick meets it before the good one.
select workflow.schedule_workflow('rem1121_a_broken', 'rem1121_count', '* * * * *') \g /dev/null
select workflow.start_workflow('rem1121_parent', '{}'::jsonb) as parent \gset
reset role;
update workflow.schedules set workflow_name = 'rem1121_gone' where name = 'rem1121_a_broken';
select (output->'result'->0->>'n')::int as alice_sees from workflow.tasks where run_id = :'direct' \gset
select set_config('rem1121.alice_sees', :'alice_sees', true) \g /dev/null
select id as parent_task from workflow.tasks where run_id = :'parent' and step_key = 'call' \gset

-- 1 and 4. The scheduler's login.
set local request.jwt.claims = '';
set session authorization scheduler;
select workflow.tick(now()) \g /dev/null
select coalesce(current_setting('request.jwt.claims', true), '') = '' as claims_left_clean \gset
reset session authorization;
\if :claims_left_clean
\else
    \echo 'workflow/33: tick left claims behind'
    select 1/0;
\endif
do $$
declare v_run workflow.runs; v_n int;
begin
    select r.* into v_run from workflow.runs r join workflow.schedules s on s.last_run_id = r.id where s.name = 'rem1121';
    if v_run.owner_id is distinct from '00000000-0000-4000-8000-000000112101' then
        raise exception 'the run tick started on Alice''s schedule is owned by %', v_run.owner_id;
    end if;
    select (output->'result'->0->>'n')::int into v_n from workflow.tasks where run_id = v_run.id;
    if v_n is distinct from current_setting('rem1121.alice_sees')::int then
        raise exception 'tick''s run of Alice''s step counted % users, and Alice sees %', v_n, current_setting('rem1121.alice_sees');
    end if;
    if (select last_error from workflow.schedules where name = 'rem1121_a_broken') is null then
        raise exception 'fixture: the broken schedule did not fail, so it tested nothing';
    end if;
end $$;

-- 2 and 3. The worker's login.
set session authorization worker;
select workflow.start_child_workflow(:'parent_task'::uuid, 'rem1121_count', '{}'::jsonb) as child \gset
select set_config('rem1121.child', :'child', true) \g /dev/null
select set_config('rem1121.parent_task', :'parent_task', true) \g /dev/null
do $$
begin
    perform workflow.start_child_workflow(current_setting('rem1121.parent_task')::uuid, 'rem1121_leos', '{}'::jsonb);
    raise exception 'accepted: Alice''s parent started a child from Leo''s private definition';
exception when others then
    if sqlerrm not like '%rem1121_leos%not registered%' then raise; end if;
end $$;
reset session authorization;
do $$
declare v_n int;
begin
    if (select owner_id from workflow.runs where id = current_setting('rem1121.child')::uuid)
       is distinct from '00000000-0000-4000-8000-000000112101' then
        raise exception 'a child the worker started for Alice''s parent is not hers';
    end if;
    select (output->'result'->0->>'n')::int into v_n from workflow.tasks where run_id = current_setting('rem1121.child')::uuid;
    if v_n is distinct from current_setting('rem1121.alice_sees')::int then
        raise exception 'the child''s step counted % users, and Alice sees %', v_n, current_setting('rem1121.alice_sees');
    end if;
    if exists (select 1 from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id
                where d.name = 'rem1121_leos') then
        raise exception 'Alice''s parent started a child from Leo''s private definition';
    end if;
end $$;

rollback;

\echo workflow/33: a run the engine starts on a schedule or as a child runs as its owner from its first step
