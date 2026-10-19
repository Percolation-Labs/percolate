-- STEPS REPEAT UNTIL A CHECK PASSES, UP TO A STATED BOUND (REM-968).
--
-- `repeat: {max, until, steps}` is unrolled by the compiler into attempts (`<step>_<n>`), each after the first
-- skipped by `when:` once the check held after the attempt before (REM-967). The repeat's own id is a final step
-- reporting how many attempts ran, whether the check held, and the last attempt's results. Every workflow here is
-- in-database, so each run finishes inside start_workflow and the assertions read the end state.
--
--   1  the compiler writes the attempts out, refuses an unbounded repeat, and says it accepts repeat
--   2  the check holds after the second attempt: two ran, the rest are skipped rows, and the outcome says so
--   3  the check never holds: every attempt runs, and the outcome says it ran out
--   4  a two-step attempt reads the attempt before through {{previous}}, which is NULL on the first
--   5  an inner step's own when: still applies, alongside the repeat's
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void as $$
begin
    if p_ok is not true then
        raise exception 'repeat: %', p_what;
    end if;
end $$ language plpgsql;

create function pg_temp.status(p_run uuid, p_step text) returns text as $$
    select status from workflow.tasks where run_id = p_run and step_key = p_step
$$ language sql;

create function pg_temp.outcome(p_run uuid, p_step text) returns jsonb as $$
    select output->'result'->0 from workflow.tasks where run_id = p_run and step_key = p_step
$$ language sql;


-- 1 ------------------------------------------------------------------------------------------------------------
do $$
declare
    v jsonb := p8_compile_workflow(E'name: c\nsteps:\n  - id: loop\n    repeat:\n      max: 3\n'
                                   || E'      until: "{{steps.s.result}} is not null"\n'
                                   || E'      steps: [{id: s, work: true}]');
begin
    perform pg_temp.check((v->>'ok')::boolean, '1 a repeat compiles: ' || coalesce(v->>'error', ''));
    perform pg_temp.check((select array_agg(s->>'key' order by o) from jsonb_array_elements(v#>'{workflow,spec,steps}')
                               with ordinality e(s, o)) = array['s_1', 's_2', 's_3', 'loop'],
        '1 the attempts are written out, and the repeat''s id comes last');
    perform pg_temp.check(v#>>'{workflow,spec,steps,1,when}' = 'not ({{steps.s_1.result}} is not null)',
        '1 an attempt after the first is skipped once the check held');
end $$;

select pg_temp.check(
    (p8_compile_workflow(E'name: c\nsteps:\n  - id: loop\n    repeat:\n      until: "{{steps.s.result}} is not null"\n      steps: [{id: s, work: true}]')->>'ok')::boolean is false,
    '1 a repeat without max is refused');
select pg_temp.check(
    (p8_compile_workflow(E'name: c\nsteps:\n  - id: loop\n    repeat:\n      max: 21\n      until: "{{steps.s.result}} is not null"\n      steps: [{id: s, work: true}]')->>'ok')::boolean is false,
    '1 a repeat over the bound is refused');
select pg_temp.check(
    (p8_compile_workflow(E'name: c\nsteps:\n  - id: loop\n    repeat:\n      max: 2\n      until: "true"\n      steps: [{id: s, work: true}]')->>'ok')::boolean is false,
    '1 a check that names no attempt is refused');
select pg_temp.check((workflow.compiler_capabilities()->'accepts'->>'repeat')::boolean,
    '1 the installed compiler says it accepts repeat');


-- 2 ------------------------------------------------------------------------------------------------------------
select workflow.define_yaml($y$
name: repeat_count
steps:
  - id: loop
    repeat:
      max: 4
      until: "{{steps.count.result.0.n}} >= {{run.target}}"
      steps:
        - id: count
          sql: "select coalesce({{previous.count.result.0.n}}, 0) + 1 as n"
  - id: after
    needs: [loop]
    sql: "select {{steps.loop.result.0.attempts}} as attempts"
$y$);

do $$
declare
    r uuid := workflow.start_workflow('repeat_count', '{"target": 2}');
begin
    perform pg_temp.check(pg_temp.status(r, 'count_1') = 'succeeded' and pg_temp.status(r, 'count_2') = 'succeeded',
        '2 attempts run until the check holds');
    perform pg_temp.check(pg_temp.status(r, 'count_3') = 'skipped' and pg_temp.status(r, 'count_4') = 'skipped',
        '2 and every attempt after is a skipped row');
    perform pg_temp.check(pg_temp.outcome(r, 'loop') = '{"attempts": 2, "max_attempts": 4, "satisfied": true,
                                                       "last": {"count": [{"n": 2}]}}',
        '2 the outcome: two attempts, the check held, the last result ' || coalesce(pg_temp.outcome(r, 'loop')::text, 'none'));
    perform pg_temp.check((select output#>>'{result,0,attempts}' from workflow.tasks
                            where run_id = r and step_key = 'after') = '2',
        '2 a step after the repeat reads its outcome');
    perform pg_temp.check((select status from workflow.runs where id = r) = 'succeeded', '2 and the run succeeds');
end $$;


-- 3 ------------------------------------------------------------------------------------------------------------
do $$
declare
    r uuid := workflow.start_workflow('repeat_count', '{"target": 99}');
begin
    perform pg_temp.check((select count(*) from workflow.tasks where run_id = r and step_key like 'count\_%'
                            and status = 'succeeded') = 4, '3 a check that never holds runs every attempt');
    perform pg_temp.check(pg_temp.outcome(r, 'loop') @> '{"attempts": 4, "satisfied": false}',
        '3 and the outcome says it ran out');
    perform pg_temp.check((select status from workflow.runs where id = r) = 'succeeded',
        '3 running out is not a failure of the run');
end $$;


-- 4 ------------------------------------------------------------------------------------------------------------
select workflow.define_yaml($y$
name: repeat_pair
steps:
  - id: seed
    sql: "select 'draft' as text"
  - id: polish
    needs: [seed]
    repeat:
      max: 3
      until: "'{{steps.judge.result.0.verdict}}' = 'accept'"
      steps:
        - id: rewrite
          sql: "select coalesce('{{previous.rewrite.result.0.text}}', '{{steps.seed.result.0.text}}') || '+' as text"
        - id: judge
          needs: [rewrite]
          sql: "select case when length('{{steps.rewrite.result.0.text}}') >= 7 then 'accept' else 'again' end as verdict"
$y$);

do $$
declare
    r uuid := workflow.start_workflow('repeat_pair', '{}');
begin
    perform pg_temp.check(pg_temp.outcome(r, 'rewrite_1') = '{"text": "draft+"}',
        '4 the first attempt''s {{previous}} is NULL, so it starts from the seed');
    perform pg_temp.check(pg_temp.outcome(r, 'rewrite_2') = '{"text": "draft++"}',
        '4 the second reads the first through {{previous}}');
    perform pg_temp.check(pg_temp.status(r, 'rewrite_3') = 'skipped' and pg_temp.status(r, 'judge_3') = 'skipped',
        '4 a whole attempt is skipped once the judge accepted');
    perform pg_temp.check(pg_temp.outcome(r, 'polish') @> '{"attempts": 2, "satisfied": true,
                                                          "last": {"judge": [{"verdict": "accept"}],
                                                                   "rewrite": [{"text": "draft++"}]}}',
        '4 the outcome carries every step of the last attempt');
end $$;


-- 5 ------------------------------------------------------------------------------------------------------------
select workflow.define_yaml($y$
name: repeat_own_when
steps:
  - id: loop
    repeat:
      max: 3
      until: "{{steps.count.result.0.n}} >= 3"
      steps:
        - id: count
          sql: "select coalesce({{previous.count.result.0.n}}, 0) + 1 as n"
        - id: shout
          needs: [count]
          when: "{{steps.count.result.0.n}} = 2"
          sql: "select 'two' as said"
$y$);

do $$
declare
    r uuid := workflow.start_workflow('repeat_own_when', '{}');
begin
    perform pg_temp.check(pg_temp.status(r, 'shout_1') = 'skipped' and pg_temp.status(r, 'shout_2') = 'succeeded'
        and pg_temp.status(r, 'shout_3') = 'skipped', '5 an inner step''s own when still decides within an attempt');
    perform pg_temp.check(pg_temp.status(r, 'count_3') = 'succeeded', '5 and does not stop the repeat');
    perform pg_temp.check((select status from workflow.runs where id = r) = 'succeeded', '5 the run succeeds');
end $$;

rollback;
