-- A STEP RUNS WHEN ITS CONDITION HOLDS, AND IS SKIPPED OTHERWISE (REM-967).
--
-- `when:` is a SQL predicate over the run's input and earlier results. The engine asks it once, when the step's
-- needs are done; false or null marks the step `skipped`, which is terminal and counts as success, so the steps
-- after it are released rather than cancelled. Every workflow here is made of in-database steps, so each run
-- finishes inside start_workflow and the assertions read the end state directly.
--
--   1  the vocabulary: skipped is a terminal success, and the tasks CHECK admits it
--   2  the compiler carries `when` into the spec, and refuses an empty one
--   3  a gate: false skips the step and its successor still runs; true runs it
--   4  a root step asks against the run's input, and a run whose last step is skipped succeeds
--   5  a skipped step is never claimable and a skipped signal never waits
--   6  a predicate naming a step outside `needs` is refused at definition
--   7  a predicate that cannot be evaluated fails its step and the run, not the step before it
--   8  a progress view counts a skipped step as done
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void as $$
begin
    if p_ok is not true then
        raise exception 'when: %', p_what;
    end if;
end $$ language plpgsql;

create function pg_temp.status(p_run uuid, p_step text) returns text as $$
    select status from workflow.tasks where run_id = p_run and step_key = p_step
$$ language sql;

create function pg_temp.run_status(p_run uuid) returns text as $$
    select status from workflow.runs where id = p_run
$$ language sql;


-- 1 ------------------------------------------------------------------------------------------------------------
select pg_temp.check(workflow.is_terminal('skipped') and workflow.is_success('skipped'),
    '1 skipped is terminal and a success');
select pg_temp.check(pg_get_constraintdef((select oid from pg_constraint where conname = 'tasks_status_check'))
    like '%skipped%', '1 the tasks CHECK admits skipped');


-- 2 ------------------------------------------------------------------------------------------------------------
select pg_temp.check(
    p8_compile_workflow(E'name: c\nsteps:\n  - id: a\n    work: true\n  - id: b\n    needs: [a]\n    work: true\n    when: "{{steps.a.result.n}} > 1"')
        #>> '{workflow,spec,steps,1,when}' = '{{steps.a.result.n}} > 1',
    '2 the compiler carries when into the step, as written');
select pg_temp.check(
    (p8_compile_workflow(E'name: c\nsteps:\n  - id: a\n    work: true\n    when: "  "')->>'ok')::boolean is false,
    '2 an empty when is refused');
select pg_temp.check((workflow.compiler_capabilities()->'accepts'->>'when')::boolean,
    '2 the installed compiler says it accepts when');


-- 3 ------------------------------------------------------------------------------------------------------------
select workflow.define_yaml($y$
name: when_gate
steps:
  - id: score
    sql: "select {{run.score}} as v"
  - id: review
    needs: [score]
    when: "{{steps.score.result.0.v}} > 0.5"
    sql: "select 'reviewed' as r, 2 as n"
  - id: notify
    needs: [review]
    sql: "select 'notified' as n"
  - id: if_unreviewed
    needs: [review]
    when: "{{steps.review.result.0.r}} is null"
    sql: "select 'escalated' as e"
  - id: if_reviewed_ok
    needs: [review]
    when: "'{{steps.review.result.0.r}}' = 'reviewed'"
    sql: "select 'filed' as f"
  - id: if_counted
    needs: [review]
    when: "{{steps.review.result.0.n}} > 1"
    sql: "select 'counted' as c"
$y$);

do $$
declare
    low  uuid := workflow.start_workflow('when_gate', '{"score": 0.2}');
    high uuid := workflow.start_workflow('when_gate', '{"score": 0.9}');
begin
    perform pg_temp.check(pg_temp.status(low, 'review') = 'skipped', '3 false skips the step');
    perform pg_temp.check((select output is null and completed_at is not null from workflow.tasks
                            where run_id = low and step_key = 'review'), '3 a skipped step has no output and is done');
    perform pg_temp.check(pg_temp.status(low, 'notify') = 'succeeded', '3 the step after a skipped one still runs');
    perform pg_temp.check(pg_temp.status(low, 'if_unreviewed') = 'succeeded',
        '3 a skipped step''s result reads as null, so is null holds');
    perform pg_temp.check(pg_temp.status(low, 'if_reviewed_ok') = 'skipped',
        '3 and a comparison with it is null, which skips');
    perform pg_temp.check(pg_temp.status(low, 'if_counted') = 'skipped',
        '3 a numeric comparison with a skipped result is null too, not a type error');
    perform pg_temp.check(pg_temp.run_status(low) = 'succeeded', '3 a run of successes and a skip succeeded');

    perform pg_temp.check(pg_temp.status(high, 'review') = 'succeeded', '3 true runs the step');
    perform pg_temp.check(pg_temp.status(high, 'notify') = 'succeeded'
        and pg_temp.status(high, 'if_unreviewed') = 'skipped'
        and pg_temp.status(high, 'if_reviewed_ok') = 'succeeded'
        and pg_temp.status(high, 'if_counted') = 'succeeded'
        and pg_temp.run_status(high) = 'succeeded', '3 and the run finishes as before');
end $$;


-- 4 ------------------------------------------------------------------------------------------------------------
select workflow.define_yaml($y$
name: when_root
steps:
  - id: only_if_asked
    when: "{{run.wanted}}"
    sql: "select 1 as one"
  - id: after_skip
    needs: [only_if_asked]
    sql: "select 4 as four"
  - id: always
    sql: "select 2 as two"
  - id: tail
    needs: [always]
    when: "'{{run.mode}}' = 'full'"
    sql: "select 3 as three"
$y$);

do $$
declare
    r uuid := workflow.start_workflow('when_root', '{"wanted": false, "mode": "brief"}');
    s uuid := workflow.start_workflow('when_root', '{"wanted": true, "mode": "full"}');
begin
    perform pg_temp.check(pg_temp.status(r, 'only_if_asked') = 'skipped', '4 a root asks against the run input');
    -- start_workflow meets the skipped root before it has written the edge to its dependent, so the dependent's
    -- count of outstanding dependencies is where a skip must read as done.
    perform pg_temp.check(pg_temp.status(r, 'after_skip') = 'succeeded',
        '4 a step after a skipped root is released when the edge is written after the skip');
    perform pg_temp.check(pg_temp.status(r, 'tail') = 'skipped', '4 a text comparison binds as text');
    perform pg_temp.check(pg_temp.run_status(r) = 'succeeded', '4 a run whose last step is skipped succeeds');
    perform pg_temp.check(pg_temp.status(s, 'only_if_asked') = 'succeeded'
        and pg_temp.status(s, 'tail') = 'succeeded', '4 and runs both when they hold');
end $$;


-- Nothing finishes through complete_task when every step is skipped, so the skip itself asks whether the run is done.
select workflow.define_yaml($y$
name: when_nothing
steps:
  - id: never
    when: "false"
    sql: "select 1 as n"
$y$);

select pg_temp.check(pg_temp.run_status(workflow.start_workflow('when_nothing', '{}')) = 'succeeded',
    '4 a run whose every step is skipped succeeds');


-- 5 ------------------------------------------------------------------------------------------------------------
select workflow.define_yaml($y$
name: when_waits
steps:
  - id: decide
    sql: "select false as escalate"
  - id: call_out
    needs: [decide]
    when: "{{steps.decide.result.0.escalate}}"
    queue: when_test_q
    rest: {url: "http://example.invalid/escalate"}
  - id: approve
    needs: [decide]
    when: "{{steps.decide.result.0.escalate}}"
    signal: true
$y$);

do $$
declare
    r uuid := workflow.start_workflow('when_waits', '{}');
begin
    perform pg_temp.check(pg_temp.status(r, 'call_out') = 'skipped', '5 a skipped http step is skipped');
    perform pg_temp.check((select id from workflow.claim_task('when_test_q', 'when-test')) is null,
        '5 and nothing on its queue is claimable');
    perform pg_temp.check(pg_temp.status(r, 'approve') = 'skipped', '5 a skipped signal never waits');
    perform pg_temp.check(pg_temp.run_status(r) = 'succeeded', '5 so the run finishes');
end $$;


-- 6 ------------------------------------------------------------------------------------------------------------
do $$
begin
    begin
        perform workflow.define_yaml($y$
name: when_outside_needs
steps:
  - id: a
    sql: "select 1 as n"
  - id: b
    sql: "select 2 as n"
  - id: c
    needs: [b]
    when: "{{steps.a.result.0.n}} = 1"
    sql: "select 3 as n"
$y$);
        raise exception 'when: 6 a predicate naming a step outside needs was accepted';
    exception when others then
        perform pg_temp.check(sqlerrm not like 'when: 6%', '6 ' || sqlerrm);
    end;
end $$;


-- 7 ------------------------------------------------------------------------------------------------------------
select workflow.define_yaml($y$
name: when_broken
steps:
  - id: first
    sql: "select 1 as n"
  - id: second
    needs: [first]
    when: "{{steps.first.result.0.n}} >>> 0"
    sql: "select 2 as n"
$y$);

do $$
declare
    r uuid := workflow.start_workflow('when_broken', '{}');
begin
    perform pg_temp.check(pg_temp.status(r, 'first') = 'succeeded', '7 the step before keeps its success');
    perform pg_temp.check(pg_temp.status(r, 'second') = 'failed', '7 a predicate that cannot run fails its step');
    perform pg_temp.check((select error->>'error' from workflow.tasks where run_id = r and step_key = 'second')
        like 'when: %', '7 and says it was the when');
    perform pg_temp.check(pg_temp.run_status(r) = 'failed', '7 and fails the run');
end $$;


-- 8 ------------------------------------------------------------------------------------------------------------
do $$
declare
    r uuid := workflow.start_workflow('when_gate', '{"score": 0.1}');
begin
    perform pg_temp.check((select done = total from workflow.v_run_progress where run_id = r),
        '8 v_run_progress counts a skipped step as done');
end $$;

rollback;
