-- A STEP'S STATEMENT TIMEOUT ENDS WITH ITS STEP, NOT THE CALLER'S TRANSACTION (REM-1262).
--
-- workflow.run_sql and workflow.call_step_function set statement_timeout with set_config(..., true), which is
-- transaction-local: it lasted until the CALLER's transaction ended. On 29 Oct the walk bundle's start.sql ran 18
-- replay starts as one implicit transaction; once one start ran a walk inline, every later statement in it ran under
-- the step's 30 s limit, the next walk longer than that was cancelled, and every start rolled back.
--
-- Each case below runs a step with a 1 s timeout and then, in the same transaction, a top-level statement that takes
-- 1.5 s. On the old functions that statement is cancelled and the test stops; with the timeout restored on return it
-- runs to the end. The four ways in: run_sql's read path, its write path, a registered step function, and the engine
-- running a `sql` step inline from start_workflow (execute_sql_step -> run_sql).

\set ON_ERROR_STOP on

begin;

set local statement_timeout = 0;

create function pg_temp.t_1262_one() returns int language sql as 'select 1';
select workflow.register_step_function('t_1262_one', 'pg_temp.t_1262_one', '{}', 1000, 'REM-1262 fixture');

insert into workflow.definitions (name, spec) values
('t_1262_inline', '{"steps":[
    {"key":"rows", "kind":"sql", "queue":"none",
     "input":{"statement":"select 1 as n", "timeout_ms": 1000}}
 ]}');

create function pg_temp.t_1262_left(p_case text) returns void language plpgsql as $$
begin
    if current_setting('statement_timeout') <> '0' then
        raise exception 'after %, the caller''s transaction runs under statement_timeout %, which the step set',
            p_case, current_setting('statement_timeout');
    end if;
end $$;

-- 1. run_sql, a read
select workflow.run_sql('select 1 as n', false, 1000);
select pg_temp.t_1262_left('run_sql (read)');
select pg_sleep(1.5);

-- 2. run_sql, a write
-- run_sql is security definer, so the write is to a table its owner holds
select workflow.run_sql($q$update workflow.step_functions set description = description where name = 't_1262_one'$q$, true, 1000);
select pg_temp.t_1262_left('run_sql (write)');
select pg_sleep(1.5);

-- 3. a registered step function
select workflow.call_step_function('t_1262_one', '[]'::jsonb, null);
select pg_temp.t_1262_left('call_step_function');
select pg_sleep(1.5);

-- 4. the engine runs a sql step inline when the run starts
select workflow.start_workflow('t_1262_inline', '{}'::jsonb);
do $$
begin
    if (select status from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id
         where d.name = 't_1262_inline') is distinct from 'succeeded' then
        raise exception 'the inline sql step did not run, so case 4 proves nothing';
    end if;
end $$;
select pg_temp.t_1262_left('a sql step run by start_workflow');
select pg_sleep(1.5);

do $$ begin raise notice 'workflow/36: a step''s statement timeout ends with its step, not the caller''s transaction'; end $$;

rollback;
