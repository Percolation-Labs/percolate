-- A SIGNAL SAYS HOW MANY WAITING STEPS IT RESOLVED (REM-977).
--
-- signal_task returned void, so a signal sent before its step was waiting_external changed nothing and looked like
-- one that worked. A fresh reader of the LangGraph article signalled `approve` while the timer still held the run,
-- saw no error, and the step then waited for a signal that had already come. It now returns the number of steps it
-- resolved, so 0 is visible from psql and over REST. It does not raise: answering twice must stay harmless.
--
--   1  the return type is integer, which is what PostgREST hands a REST caller
--   2  a signal sent while the step is still pending resolves nothing, says 0, and leaves the step pending
--   3  a signal to a waiting step says 1 and finishes the run
--   4  answering twice says 0 the second time and keeps the first answer
--   5  a name nobody waits on says 0 and leaves the real step waiting
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void as $$
begin
    if p_ok is not true then
        raise exception 'signal: %', p_what;
    end if;
end $$ language plpgsql;

create function pg_temp.status(p_run uuid, p_step text) returns text as $$
    select status from workflow.tasks where run_id = p_run and step_key = p_step
$$ language sql;

-- Runs here are owned by one real person, who signals them: signal_task checks who is signing.
create function pg_temp.owned(p_name text) returns uuid as $$
declare r uuid := workflow.start_workflow(p_name, '{}'::jsonb);
begin
    update workflow.runs set owner_id = (select id from rbac.users where email = 'wf29@test.com') where id = r;
    return r;
end $$ language plpgsql;

insert into rbac.users (id, email) values (gen_random_uuid(), 'wf29@test.com');


-- 1 ------------------------------------------------------------------------------------------------------------
select pg_temp.check(
    (select prorettype = 'integer'::regtype from pg_proc where oid = 'workflow.signal_task(uuid,text,jsonb)'::regprocedure),
    '1 signal_task returns an integer');

select workflow.define_yaml($y$
name: wf29_held
steps:
  - id: cooling_off
    timer: 3600
  - id: approve
    needs: [cooling_off]
    signal: true
$y$);

select workflow.define_yaml($y$
name: wf29_waits
steps:
  - id: approve
    signal: true
  - id: after
    needs: [approve]
    sql: "select '{{steps.approve.result.decision}}' as d"
$y$);

do $$
declare
    held  uuid := pg_temp.owned('wf29_held');
    waits uuid := pg_temp.owned('wf29_waits');
    wrong uuid := pg_temp.owned('wf29_waits');
    n     integer;
begin
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', (select id from rbac.users where email = 'wf29@test.com'))::text);

    -- 2
    perform pg_temp.check(pg_temp.status(held, 'approve') = 'pending', '2 behind the timer, approve is pending');
    n := workflow.signal_task(held, 'approve', '{"decision": "released"}');
    perform pg_temp.check(n = 0, '2 an early signal says it resolved nothing: ' || coalesce(n::text, 'null'));
    perform pg_temp.check(pg_temp.status(held, 'approve') = 'pending', '2 and approve is still pending');

    -- 3
    perform pg_temp.check(pg_temp.status(waits, 'approve') = 'waiting_external', '3 approve waits for a person');
    n := workflow.signal_task(waits, 'approve', '{"decision": "released"}');
    perform pg_temp.check(n = 1, '3 a signal to a waiting step says 1: ' || coalesce(n::text, 'null'));
    perform pg_temp.check((select status from workflow.runs where id = waits) = 'succeeded'
        and (select output #>> '{result,0,d}' from workflow.tasks where run_id = waits and step_key = 'after')
            is not distinct from 'released',
        '3 and the run finishes with the decision passed on');

    -- 4
    n := workflow.signal_task(waits, 'approve', '{"decision": "held"}');
    perform pg_temp.check(n = 0, '4 a second answer says 0: ' || coalesce(n::text, 'null'));
    perform pg_temp.check((select output #>> '{result,decision}' from workflow.tasks
                            where run_id = waits and step_key = 'approve') is not distinct from 'released',
        '4 and the first answer is the one kept');

    -- 5
    n := workflow.signal_task(wrong, 'aprove', '{}');
    perform pg_temp.check(n = 0, '5 a misspelled name says 0: ' || coalesce(n::text, 'null'));
    perform pg_temp.check(pg_temp.status(wrong, 'approve') = 'waiting_external', '5 and the real step still waits');
end $$;

rollback;
