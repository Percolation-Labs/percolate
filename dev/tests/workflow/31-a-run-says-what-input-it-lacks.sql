-- A RUN SAYS WHICH {{run.*}} KEYS ITS INPUT LACKS, WHEN IT STARTS (REM-1016).
--
-- A worker-dispatched step that reads a run key the caller left out fails at dispatch with "resolved to nothing".
-- start_workflow now lists each such key on the run row (and raises a WARNING), naming the step and whether that
-- step is conditional. It never refuses: a gated step may read a key only its own branch needs.
--
--   1  a key an unconditional step reads and the input lacks is listed; supplied, nothing is
--   2  a when-gated step's key is listed as conditional, and when the gate is false the step is skipped and the
--      run succeeds -- a skipped step's templates are never resolved
--   3  a sql: step and a when: predicate bind a missing key as NULL, so neither is listed
--   4  $-prefixed engine fields are not input and are never listed
--   5  a nested key is checked along its whole path
--   6  workflow.runs_api carries the list, for callers who start runs over REST
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void as $$
begin
    if p_ok is not true then
        raise exception 'unsupplied input: %', p_what;
    end if;
end $$ language plpgsql;

create function pg_temp.gaps(p_run uuid) returns jsonb as $$
    select unsupplied_input from workflow.runs where id = p_run
$$ language sql;

select workflow.define_yaml($y$
name: lacks_input
steps:
  - id: greet
    work: true
    input: {text: "hello {{run.speaker}}"}
  - id: dig
    needs: [greet]
    when: "{{run.deep}}"
    work: true
    input: {topic: "{{run.topic}}"}
  - id: count
    sql: "select {{run.n}} as n"
  - id: meta
    work: true
    input: {run: "{{run.$id}}", who: "{{run.who.name}}"}
$y$);


-- 1, 3, 4 -----------------------------------------------------------------------------------------------------
do $$
declare
    bare uuid := workflow.start_workflow('lacks_input', '{"deep": false}');
    whole uuid := workflow.start_workflow('lacks_input',
                     '{"speaker": "a", "deep": true, "topic": "t", "n": 1, "who": {"name": "b"}}');
    g    jsonb;
begin
    g := pg_temp.gaps(bare);
    perform pg_temp.check(g @> '[{"key": "run.speaker", "step": "greet", "conditional": false}]',
        '1 an unconditional step''s missing key is listed with its step: ' || coalesce(g::text, 'null'));
    perform pg_temp.check(pg_temp.gaps(whole) is null, '1 a run whose input supplies every key lists nothing');

    perform pg_temp.check(not g @> '[{"key": "run.n"}]', '3 a sql: step''s key binds as NULL and is not listed');
    perform pg_temp.check(not g @> '[{"key": "run.deep"}]', '3 a when: predicate''s key is not listed');
    perform pg_temp.check(g::text not like '%$id%', '4 an engine field is not listed');
end $$;


-- 2 ------------------------------------------------------------------------------------------------------------
select workflow.define_yaml($y$
name: lacks_gated
steps:
  - id: dig
    when: "{{run.deep}}"
    work: true
    input: {topic: "{{run.topic}}"}
$y$);

do $$
declare
    r uuid := workflow.start_workflow('lacks_gated', '{"deep": false}');
begin
    perform pg_temp.check(pg_temp.gaps(r) = '[{"key": "run.topic", "step": "dig", "conditional": true}]',
        '2 a gated step''s key is listed as conditional: ' || coalesce(pg_temp.gaps(r)::text, 'null'));
    perform pg_temp.check((select status from workflow.tasks where run_id = r and step_key = 'dig') = 'skipped',
        '2 the gate is false, so the step is skipped');
    perform pg_temp.check((select status from workflow.runs where id = r) = 'succeeded',
        '2 and the run succeeds: the missing key was never resolved');
end $$;


-- 5 ------------------------------------------------------------------------------------------------------------
do $$
declare
    half uuid := workflow.start_workflow('lacks_input', '{"speaker": "a", "topic": "t", "who": {}}');
begin
    perform pg_temp.check(pg_temp.gaps(half) = '[{"key": "run.who.name", "step": "meta", "conditional": false}]',
        '5 a nested key missing below a present parent is listed: ' || coalesce(pg_temp.gaps(half)::text, 'null'));
end $$;


-- 6 ------------------------------------------------------------------------------------------------------------
select pg_temp.check(
    to_regclass('workflow.runs_api') is null
    or exists (select from information_schema.columns
                where table_schema = 'workflow' and table_name = 'runs_api' and column_name = 'unsupplied_input'),
    '6 runs_api carries unsupplied_input');

rollback;
