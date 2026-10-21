-- A RUN'S POLICY AND BUDGET DECIDE WHAT RUNS WITHOUT A PERSON (REM-1126; feedback 9ea269ac, points 2 and 3).
--
-- A policy row decides from a run's estimate whether it starts or waits for approval; a run draws on a budget and
-- pauses at its cap until a person raises it; and one line says spent, estimated and cap. Waiting and paused are
-- runs.hold, so the run stays 'running' and nothing fails.
--
--   1  with no policy row a run starts unheld, as before this card
--   2  with a policy, a run is held awaiting its estimate, nothing is claimed or autorun, v_unclaimable says why,
--      and it gets the policy's default budget
--   3  an incomplete estimate keeps it held
--   4  an estimate within the limits starts it: its worker step is claimable and its sql step ran
--   5  an estimate one cent over the limit waits for approval, and approve_run starts it
--   6  an unpriced estimate under a cost limit waits for approval rather than being guessed
--   7  spend reaching the cap pauses the run (a hold, not a failure): the next step is not claimable
--   8  approve_run refuses a paused run; raise_budget below the spend keeps it paused, above it resumes
--   9  the status line says spent, estimated and cap
--  10  an owner's own policy row wins over the deployment's
--  11  an unbounded fan-out's estimate is a floor, so it waits for approval even under every limit
--  12  a sub-workflow's child run is not held: its parent's run was the one decided, and the parent finishes
--
-- The estimate and the spend are REM-1125's (workflow/32): its run_estimates row decides the run through
-- trg_run_estimates_decide, and each attempt's record_task_usage checks the cap through trg_task_usage_budget.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void as $$
begin
    if p_ok is not true then
        raise exception 'run policy: %', p_what;
    end if;
end $$ language plpgsql;

create function pg_temp.hold(p_run uuid) returns text as $$
    select coalesce(hold, 'none') from workflow.runs where id = p_run
$$ language sql;

-- An estimate arriving the way REM-1125's arrives: the run row of workflow.run_estimates rewritten, as
-- sum_run_estimate does after the dry run. trg_run_estimates_decide does the rest. Incomplete is basis 'none'.
create function pg_temp.estimate(p_run uuid, p_cost numeric, p_tokens bigint, p_wall numeric) returns text as $$
    update workflow.run_estimates
       set basis = case when p_tokens is null or p_wall is null then 'none' else 'history' end,
           est_cost_usd = p_cost, est_input_tokens = p_tokens, est_output_tokens = 0, est_wall_seconds = p_wall
     where run_id = p_run and step_key is null;
    select hold from workflow.runs where id = p_run;
$$ language sql;

select workflow.define_yaml($y$
name: wf33_spends
steps:
  - id: think
    queue: wf33
    work: true
  - id: write
    needs: [think]
    queue: wf33
    work: true
  - id: note
    sql: "select 1 as n"
$y$);

select workflow.define_yaml($y$
name: wf33_child
steps:
  - id: n
    sql: "select 1 as n"
$y$);
insert into workflow.definitions (name, spec) values
    ('wf33_parent', '{"steps":[{"key":"call","kind":"sub_workflow","queue":"none","input":{"workflow":"wf33_child"}}]}'::jsonb);

do $$
declare
    r    uuid;
    t    workflow.tasks;
    line text;
    u    uuid := gen_random_uuid();
    v    uuid := gen_random_uuid();
begin
    delete from workflow.run_policies;
    -- Runs here are one person's, who approves and raises them: those check who is asking, as signal_task does.
    insert into rbac.users (id, email) values (u, 'wf33@test.com'), (v, 'wf33-own@test.com');
    execute format('set local request.jwt.claims = %L', json_build_object('sub', u)::text);

    -- 1
    r := workflow.start_workflow('wf33_spends', '{}'::jsonb);
    perform pg_temp.check(pg_temp.hold(r) = 'none', '1 no policy, no hold: ' || pg_temp.hold(r));
    perform pg_temp.check((select status from workflow.tasks where run_id = r and step_key = 'note') = 'succeeded',
                          '1 and its sql step ran');
    update workflow.tasks set status = 'cancelled' where run_id = r and status in ('ready', 'pending');

    insert into workflow.run_policies (owner_id, auto_cost_usd, auto_tokens, auto_wall_seconds, default_budget)
    values (null, 1.00, 50000, 600, '{"cost_limit": 2.00}');

    -- 2
    r := workflow.start_workflow('wf33_spends', '{}'::jsonb);
    perform pg_temp.check(pg_temp.hold(r) = 'awaiting_estimate', '2 held awaiting its estimate: ' || pg_temp.hold(r));
    perform pg_temp.check((select basis from workflow.run_estimates where run_id = r and step_key is null) = 'none',
                          '2 no history, so REM-1125''s estimate at start is incomplete');
    perform pg_temp.check((select status from workflow.runs where id = r) = 'running', '2 and still running');
    perform pg_temp.check((select budget from workflow.runs where id = r) = '{"cost_limit": 2.00}'::jsonb,
                          '2 with the policy''s default budget');
    perform pg_temp.check(workflow.claim_task('wf33', 'w1') is null, '2 nothing is claimed');
    perform pg_temp.check((select status from workflow.tasks where run_id = r and step_key = 'note') = 'ready',
                          '2 the sql step did not autorun');
    perform pg_temp.check(exists (select 1 from workflow.v_unclaimable where run_id = r and reason like '%held%'),
                          '2 v_unclaimable says the run is held');

    -- 3
    perform pg_temp.estimate(r, null, null, null);
    perform pg_temp.check(pg_temp.hold(r) = 'awaiting_estimate', '3 an incomplete estimate keeps it held');

    -- 4
    perform pg_temp.estimate(r, 1.00, 50000, 600);
    perform pg_temp.check(pg_temp.hold(r) = 'none', '4 at the limits exactly, it starts: ' || pg_temp.hold(r));
    perform pg_temp.check((select status from workflow.tasks where run_id = r and step_key = 'note') = 'succeeded',
                          '4 its sql step ran on release');
    t := workflow.claim_task('wf33', 'w1');
    perform pg_temp.check(t.run_id = r and t.step_key = 'think', '4 and its worker step is claimable');

    -- 7: the worker reports think's usage, which reaches the $2.00 cap
    perform workflow.record_task_usage(t.id, t.attempts,
        '{"requests": 3, "input_tokens": 9000, "output_tokens": 1000, "cost": 2.00}'::jsonb, 'w1');
    perform pg_temp.check(pg_temp.hold(r) = 'budget_paused', '7 the usage paused it at its cap: ' || pg_temp.hold(r));
    perform workflow.complete_task(t.id, '{"result": "thought"}'::jsonb);
    perform pg_temp.check((select status from workflow.runs where id = r) = 'running'
                          and (select status from workflow.tasks where run_id = r and step_key = 'think') = 'succeeded',
                          '7 the step in flight finished and nothing failed');
    perform pg_temp.check(workflow.claim_task('wf33', 'w1') is null, '7 the next step is not claimed');

    -- 9
    line := (select c.line from workflow.run_cost(r) c);
    perform pg_temp.check(line = 'running (budget paused) · spent $2.00, estimated $1.00, cap $2.00',
                          '9 the status line: ' || line);

    -- 8
    begin
        perform workflow.approve_run(r);
        raise exception 'approve_run accepted a paused run';
    exception when others then
        perform pg_temp.check(sqlerrm like '%paused at its budget%', '8 approve_run refuses a paused run: ' || sqlerrm);
    end;
    line := workflow.raise_budget(r, '{"cost_limit": 1.50}');
    perform pg_temp.check(pg_temp.hold(r) = 'budget_paused', '8 a cap below the spend keeps it paused');
    line := workflow.raise_budget(r, '{"cost_limit": 5.00}');
    perform pg_temp.check(pg_temp.hold(r) = 'none', '8 a cap above the spend resumes it: ' || line);
    t := workflow.claim_task('wf33', 'w1');
    perform pg_temp.check(t.run_id = r and t.step_key = 'write', '8 and its next step is claimable');
    perform workflow.complete_task(t.id, '{"result": "written"}'::jsonb);
    perform pg_temp.check((select status from workflow.runs where id = r) = 'succeeded', '8 and the run finishes');

    -- 5
    r := workflow.start_workflow('wf33_spends', '{}'::jsonb);
    perform pg_temp.estimate(r, 1.01, 50000, 600);
    perform pg_temp.check(pg_temp.hold(r) = 'awaiting_approval', '5 a cent over waits for approval: ' || pg_temp.hold(r));
    perform pg_temp.check(workflow.claim_task('wf33', 'w1') is null, '5 and nothing is claimed');
    perform workflow.approve_run(r);
    perform pg_temp.check(pg_temp.hold(r) = 'none', '5 approve_run starts it');
    perform pg_temp.check((workflow.claim_task('wf33', 'w1')).run_id = r, '5 and its step is claimable');

    -- 6
    r := workflow.start_workflow('wf33_spends', '{}'::jsonb);
    perform pg_temp.estimate(r, null, 100, 10);
    perform pg_temp.check(pg_temp.hold(r) = 'awaiting_approval', '6 an unpriced estimate under a cost limit waits');

    -- 10
    insert into workflow.run_policies (owner_id, auto_cost_usd) values (v, 10.00);
    execute format('set local request.jwt.claims = %L', json_build_object('sub', v)::text);
    r := workflow.start_workflow('wf33_spends', '{}'::jsonb);
    perform pg_temp.check((select owner_id from workflow.runs where id = r) = v, '10 the run is v''s');
    perform pg_temp.estimate(r, 5.00, 100, 10);
    perform pg_temp.check(pg_temp.hold(r) = 'none', '10 the owner''s own policy wins: ' || pg_temp.hold(r));

    -- 11
    r := workflow.start_workflow('wf33_spends', '{}'::jsonb);
    update workflow.run_estimates
       set basis = 'dry_run_unbounded', est_cost_usd = 0.01, est_input_tokens = 10, est_output_tokens = 0,
           est_wall_seconds = 1
     where run_id = r and step_key is null;
    perform pg_temp.check(pg_temp.hold(r) = 'awaiting_approval', '11 an unbounded floor waits: ' || pg_temp.hold(r));

    -- 12
    r := workflow.start_workflow('wf33_parent', '{}'::jsonb);
    perform pg_temp.estimate(r, 0.10, 100, 10);
    perform pg_temp.check(pg_temp.hold(r) = 'none', '12 the parent starts within the limits');
    perform pg_temp.check((select pg_temp.hold(c.id) from workflow.runs c
                            where c.parent_task_id = (select id from workflow.tasks where run_id = r and step_key = 'call'))
                          = 'none', '12 its child run is not held');
    perform pg_temp.check((select status from workflow.runs where id = r) = 'succeeded',
                          '12 and the parent finishes: ' || (select status from workflow.runs where id = r));
end $$;

rollback;
