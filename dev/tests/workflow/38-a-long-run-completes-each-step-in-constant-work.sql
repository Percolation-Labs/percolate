-- A LONG RUN CHECKS ITS COMPLETION IN CONSTANT WORK PER STEP (REM-1323).
--
-- check_run_completion runs once for every task that finishes, and asked workflow.is_success of every task in the
-- run, so a run of n steps made about n^2/2 calls. Measured on 0.2.38: five 100-step inline chains made 52,490 calls,
-- and the last ten steps of a chain took 4.5 ms each against 0.8 ms for the first ten.
--
-- Time is the symptom and a timing test is flaky, so this counts the mechanism: one 100-step inline chain may call
-- is_success at most a few times per step. 0.2.38 makes 10,498 calls here and fails; the check against the states makes
-- none from check_run_completion.

\set ON_ERROR_STOP on

begin;

-- every function call is counted for this transaction (pg_stat_get_xact_function_calls), SQL functions included
set local track_functions = 'all';

do $$
begin
    insert into workflow.definitions (name, spec)
    select 't_1323_chain', jsonb_build_object('steps', jsonb_agg(
               jsonb_build_object('key', format('s%s', lpad(i::text, 3, '0')), 'kind', 'sql', 'queue', 'none',
                                  'input', jsonb_build_object('statement', 'select 1 as n'))
               || case when i > 0 then jsonb_build_object('depends_on', jsonb_build_array(format('s%s', lpad((i - 1)::text, 3, '0'))))
                       else '{}'::jsonb end
               order by i))
      from generate_series(0, 99) i;
end $$;

create temp table t_1323 (run uuid);
insert into t_1323 select workflow.start_workflow('t_1323_chain', '{}'::jsonb);

do $$
declare
    calls bigint := coalesce(pg_stat_get_xact_function_calls('workflow.is_success(text)'::regprocedure), 0);
    st    text   := (select r.status from workflow.runs r join t_1323 on t_1323.run = r.id);
begin
    if st is distinct from 'succeeded' then
        raise exception 'the 100-step chain ended %, so the count below measures nothing', st;
    end if;
    -- linear: about 5 per step remain, from the cascade (498 here). 0.2.38 made 10,498.
    if calls > 1000 then
        raise exception 'a 100-step chain called is_success % times: completion is still checked against every task', calls;
    end if;
    raise notice 'workflow/38: a 100-step chain called is_success % times (0.2.38: ~10,500)', calls;
end $$;

rollback;
