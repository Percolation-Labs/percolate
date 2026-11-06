-- A STATEMENT TIMEOUT FAILS THE STEP IT LANDS IN, AND THE CALLER'S STATEMENT GOES ON (REM-1316).
--
-- A `sql` step runs inside the statement that made it ready, and a statement_timeout set inside a running statement
-- is never armed for it, so a step's own timeout_ms bounds nothing. The limit a step meets is its caller's
-- statement_timeout. execute_sql_step caught failures with `when others`, which does not catch query_canceled, so
-- when that limit fired inside a step it aborted the caller's whole statement: on 5801 a walk start inside the
-- worker's complete_task cascade took the write-back with it, and q retried from the top.
--
--   1. a caller under a 1 s statement_timeout starts a run whose sql step sleeps 3 s: start_workflow returns near
--      1 s, and the step is failed with sqlstate 57014 and a reason that names the caller's timeout;
--   2. a person's cancel (here the backend cancels itself from inside a step) still stops the caller.
--
-- On 0.2.38 case 1 fails: start_workflow itself is cancelled.

\set ON_ERROR_STOP on

begin;

insert into workflow.definitions (name, spec) values
('t_1316_sleep', '{"steps":[
    {"key":"nap", "kind":"sql", "queue":"none",
     "input":{"statement":"select pg_sleep(3) as s", "timeout_ms": 1000}}
 ]}'),
('t_1316_cancel', '{"steps":[
    {"key":"stop", "kind":"sql", "queue":"none", "input":{"function":"t_1316_cancel"}}
 ]}');

-- The step cancels its own backend. Security definer as the test's role, because a step runs as the engine owner,
-- which may not signal a superuser's backend ("permission denied to cancel query").
create function pg_temp.t_1316_cancel() returns int language plpgsql security definer as $f$
begin
    perform pg_cancel_backend(pg_backend_pid());
    perform pg_sleep(1);
    return 1;
end $f$;
select workflow.register_step_function('t_1316_cancel', 'pg_temp.t_1316_cancel', '{}', 1000, 'REM-1316 fixture');

create temp table t_1316 (run uuid, took interval);

-- 1. The caller's limit fires inside the step.
set local statement_timeout = '1s';
do $$
declare t0 timestamptz := clock_timestamp();
begin
    insert into t_1316 values (workflow.start_workflow('t_1316_sleep', '{}'::jsonb), clock_timestamp() - t0);
end $$;
set local statement_timeout = 0;

do $$
declare
    r  t_1316;
    tk workflow.tasks;
begin
    select * into r from t_1316;
    select * into tk from workflow.tasks where run_id = r.run and step_key = 'nap';
    if tk.status is distinct from 'failed' then
        raise exception 'the step the timeout landed in is %, not failed', tk.status;
    end if;
    if tk.error->>'sqlstate' is distinct from '57014' or tk.error->>'reason' not like '%statement_timeout (1s)%' then
        raise exception 'the failed step does not say the caller''s timeout ended it: %', tk.error;
    end if;
    if r.took > interval '2.5 s' then
        raise exception 'start_workflow took %, so the 3 s step was not cut off near 1 s', r.took;
    end if;
    raise notice 'workflow/37: a 3 s step under a 1 s caller timeout is failed after %, and start_workflow returns', r.took;
end $$;

-- 2. A person's cancel is not a timeout, and still stops the caller.
do $$
begin
    perform workflow.start_workflow('t_1316_cancel', '{}'::jsonb);
    raise exception 'a cancel from inside a step was swallowed, so a person could not stop the caller';
exception when query_canceled then
    if sqlerrm <> 'canceling statement due to user request' then
        raise;
    end if;
    raise notice 'workflow/37: a person''s cancel inside a step still stops the caller';
end $$;

rollback;
