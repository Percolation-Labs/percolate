-- A WORKER-MODE SQL STEP RUNS UNDER ITS OWN LIMIT; A SPEC THAT SAYS NOTHING STILL RUNS INLINE (REM-1316).
--
-- An inline `sql` step runs inside the statement that made it ready, and Postgres arms statement_timeout only when
-- a top-level statement starts, so a step's timeout_ms bounds nothing: on 0.2.38 `run_sql('select pg_sleep(3)',
-- false, 1000)` ran 3 s. YAML.md ("Where a `sql` step runs") gives a step two modes. In `worker` it is a task a
-- worker claims; the worker sets statement_timeout as a statement of its own and then runs the step, so the limit
-- is armed for exactly that statement. This file drives the database half of that sequence as the `worker` role,
-- statement by statement, the way percolate-core's worker sends it:
--
--   1. a spec with no `mode` runs its sql step inline, inside start_workflow, as everything stored before this did;
--   2. `mode: worker` on the definition leaves the step ready for a worker, on queue http, with mode in its input;
--   3. the REM-1316 case: a worker-mode step with timeout_ms 1000 running pg_sleep(3) is cancelled at about 1 s
--      with a statement-timeout reason, and fail_task records it with a retry, as any worker failure does;
--   4. a worker-mode step that succeeds completes through complete_task, which makes its successor ready and does
--      not run it;
--   5. a step's `mode: inline` beats its definition's `worker`;
--   6. a matrix child takes its template's mode, and its template's queue;
--   7. the compiler writes `mode: worker` when a document says nothing, and carries what it does say;
--   8. a worker cannot run a sql step it does not hold.
--
-- On 0.2.38 §2 fails: the stored `mode` is ignored and start_workflow runs the step inline for its 3 s.

\set ON_ERROR_STOP on
\set VERBOSITY terse

begin;

insert into workflow.definitions (name, spec) values
('t_1316w_none', '{"steps":[
    {"key":"q", "kind":"sql", "queue":"none", "input":{"statement":"select 7 as n"}}
 ]}'),
('t_1316w_nap', '{"mode":"worker", "steps":[
    {"key":"nap", "kind":"sql", "queue":"none",
     "input":{"statement":"select pg_sleep(3) as s", "timeout_ms": 1000}}
 ]}'),
('t_1316w_claim', '{"mode":"worker", "steps":[
    {"key":"nap", "kind":"sql", "queue":"t1316w",
     "input":{"statement":"select pg_sleep(3) as s", "timeout_ms": 1000}}
 ]}'),
('t_1316w_chain', '{"mode":"worker", "steps":[
    {"key":"a", "kind":"sql", "queue":"t1316w", "input":{"statement":"select 41 + 1 as n"}},
    {"key":"b", "kind":"sql", "queue":"t1316w", "depends_on":["a"],
     "input":{"statement":"select {{steps.a.result.0.n}} as n"}}
 ]}'),
('t_1316w_override', '{"mode":"worker", "steps":[
    {"key":"q", "kind":"sql", "queue":"none", "mode":"inline", "input":{"statement":"select 7 as n"}}
 ]}'),
('t_1316w_fan', '{"mode":"inline", "steps":[
    {"key":"fan", "kind":"matrix", "queue":"none",
     "input":{"max_fanout": 5, "items":[{"n":1},{"n":2}],
              "template":{"kind":"sql", "queue":"none", "mode":"worker",
                          "input":{"statement":"select {{item.n}} as n"}}}},
    {"key":"fan2", "kind":"matrix", "queue":"none",
     "input":{"max_fanout": 5, "items":[{"n":1}],
              "template":{"kind":"sql", "queue":"none",
                          "input":{"statement":"select {{item.n}} as n"}}}}
 ]}');

create temp table t39 (k text primary key, run uuid, took interval);

-- ---------------------------------------------------------------------------------------------------------------
-- 1. No mode: inline, inside start_workflow, exactly as before.
do $$
declare v_run uuid := workflow.start_workflow('t_1316w_none', '{}'::jsonb);
        tk workflow.tasks;
begin
    select * into tk from workflow.tasks where run_id = v_run and step_key = 'q';
    if tk.status is distinct from 'succeeded' then
        raise exception 'a spec with no mode did not run its sql step inside start_workflow: %/%', tk.status, tk.claimed_by;
    end if;
    if tk.input ? 'mode' then
        raise exception 'a spec with no mode wrote a mode into its task: %', tk.input;
    end if;
    raise notice 'workflow/39 §1: a spec with no mode runs its sql step inline, inside start_workflow';
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. mode: worker leaves the step for a worker, on the http queue.
do $$
declare t0 timestamptz := clock_timestamp();
        v_run uuid := workflow.start_workflow('t_1316w_nap', '{}'::jsonb);
        v_took interval := clock_timestamp() - t0;
        tk workflow.tasks;
begin
    select * into tk from workflow.tasks where run_id = v_run and step_key = 'nap';
    if tk.status is distinct from 'ready' or v_took > interval '1 second' then
        raise exception 'start_workflow ran a worker-mode step itself: the step is % after %', tk.status, v_took;
    end if;
    if tk.queue is distinct from 'http' or tk.input->>'mode' is distinct from 'worker' then
        raise exception 'a worker-mode step is not on the http queue with mode worker: queue %, input %', tk.queue, tk.input;
    end if;
    -- Nothing in the database runs it: not drain, not execute_sql_step.
    perform workflow.drain_sql_steps(v_run);
    if workflow.execute_sql_step(tk.id) then
        raise exception 'execute_sql_step ran a worker-mode step';
    end if;
    if (select status from workflow.tasks where id = tk.id) is distinct from 'ready' then
        raise exception 'drain or execute_sql_step moved a worker-mode step';
    end if;
    raise notice 'workflow/39 §2: mode worker leaves the step ready on queue http after %, and nothing in the database runs it', v_took;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. The REM-1316 case, as the worker sends it.
select workflow.start_workflow('t_1316w_claim', '{}'::jsonb) as claim_run \gset
set local role worker;
select (workflow.claim_task('t1316w', 'w-1316', '{}')).id as task \gset
select workflow.worker_sql_step_timeout(:'task', 'w-1316') as limit_ms \gset
reset role;
select set_config('t39.task', :'task', true) \gset
insert into t39 (k, took) values ('t0', clock_timestamp() - now());   -- an offset from now(), read back below

savepoint step;
set local role worker;
set local statement_timeout = :limit_ms;
\set ON_ERROR_STOP off
select workflow.execute_worker_sql_step(:'task', 'w-1316');
\set ON_ERROR_STOP on
rollback to savepoint step;
reset role;

select set_config('t39.limit', :'limit_ms', true),
       set_config('t39.state', :'LAST_ERROR_SQLSTATE', true),
       set_config('t39.msg', :'LAST_ERROR_MESSAGE', true) \gset
do $$
declare v_took interval := (clock_timestamp() - now()) - (select took from t39 where k = 't0');
begin
    if current_setting('t39.limit') is distinct from '1000' then
        raise exception 'the worker was told a limit of % ms, not the step''s 1000', current_setting('t39.limit');
    end if;
    if current_setting('t39.state') is distinct from '57014'
       or current_setting('t39.msg') not like '%statement timeout%' then
        raise exception 'the step did not end on its statement timeout: % %',
            current_setting('t39.state'), current_setting('t39.msg');
    end if;
    if v_took < interval '900 ms' or v_took > interval '2 seconds' then
        raise exception 'a 3 s step under timeout_ms 1000 ended after %, not about 1 s', v_took;
    end if;
    raise notice 'workflow/39 §3: a 3 s step under timeout_ms 1000 ended after % with %: %',
        v_took, current_setting('t39.state'), current_setting('t39.msg');
end $$;

-- The worker then fails the task in a transaction of its own, retryable, and the usual rules apply.
set local role worker;
select workflow.fail_task(:'task', jsonb_build_object('error', :'LAST_ERROR_MESSAGE', 'sqlstate', :'LAST_ERROR_SQLSTATE'),
                          false, 'w-1316') is null as failed \gset
reset role;
do $$
declare tk workflow.tasks;
begin
    select * into tk from workflow.tasks where id = current_setting('t39.task')::uuid;
    if tk.attempts <> 1 or tk.status not in ('ready', 'failed') or tk.error->>'error' not like '%statement timeout%' then
        raise exception 'fail_task did not record the timeout as attempt 1: % % %', tk.status, tk.attempts, tk.error;
    end if;
    raise notice 'workflow/39 §3: fail_task recorded attempt 1 as %, %', tk.status, tk.error->>'error';
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Success: the output is returned, complete_task makes the successor ready, and does not run it.
select workflow.start_workflow('t_1316w_chain', '{}'::jsonb) as chain_run \gset
set local role worker;
select (workflow.claim_task('t1316w', 'w-1316', '{}')).id as a_task \gset
select workflow.worker_sql_step_timeout(:'a_task', 'w-1316') as a_limit \gset
set local statement_timeout = :a_limit;
select workflow.execute_worker_sql_step(:'a_task', 'w-1316') as a_out \gset
set local statement_timeout = 0;
select workflow.complete_task(:'a_task', :'a_out'::jsonb, 'w-1316') is null as completed \gset
reset role;
select set_config('t39.chain', :'chain_run', true), set_config('t39.a_limit', :'a_limit', true) \gset
do $$
declare a workflow.tasks; b workflow.tasks;
begin
    select * into a from workflow.tasks where run_id = current_setting('t39.chain')::uuid and step_key = 'a';
    select * into b from workflow.tasks where run_id = current_setting('t39.chain')::uuid and step_key = 'b';
    if current_setting('t39.a_limit') <> '30000' then
        raise exception 'a statement with no timeout_ms was given % ms, not run_sql''s default 30000', current_setting('t39.a_limit');
    end if;
    if a.status <> 'succeeded' or a.output->'result'->0->>'n' is distinct from '42' then
        raise exception 'the worker-run step did not complete with its rows: % %', a.status, a.output;
    end if;
    if b.status <> 'ready' or b.claimed_by is not null then
        raise exception 'complete_task ran the worker-mode successor itself: % %', b.status, b.claimed_by;
    end if;
    raise notice 'workflow/39 §4: the step completed with %, and its successor is ready for a worker, not run', a.output;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. A step's inline beats its definition's worker.
do $$
declare v_run uuid := workflow.start_workflow('t_1316w_override', '{}'::jsonb);
        tk workflow.tasks;
begin
    select * into tk from workflow.tasks where run_id = v_run and step_key = 'q';
    if tk.status is distinct from 'succeeded' then
        raise exception 'mode: inline on the step did not override the definition''s worker: %/%', tk.status, tk.claimed_by;
    end if;
    raise notice 'workflow/39 §5: a step''s mode inline beats its definition''s worker';
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 6. A matrix child takes its template's mode; with none, the definition's (here inline).
do $$
declare v_run uuid := workflow.start_workflow('t_1316w_fan', '{}'::jsonb);
        n_worker int; n_inline int;
begin
    select count(*) filter (where status = 'ready' and queue = 'http' and input->>'mode' = 'worker'),
           count(*) filter (where status <> 'ready') into n_worker, n_inline
      from workflow.tasks where run_id = v_run and step_key like 'fan[%';
    if n_worker <> 2 or n_inline <> 0 then
        raise exception 'a worker-mode template made % worker children of 2 (% ran inline)', n_worker, n_inline;
    end if;
    select count(*) into n_inline from workflow.tasks
     where run_id = v_run and step_key like 'fan2[%' and status = 'succeeded' and not (input ? 'mode');
    if n_inline <> 1 then
        raise exception 'a template with no mode under an inline definition did not run its child inline';
    end if;
    raise notice 'workflow/39 §6: a matrix child takes its template''s mode and queue, else the definition''s';
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 7. The compiler: worker unless the document says otherwise.
do $$
declare c jsonb;
begin
    c := p8_compile_workflow(E'name: c\nsteps:\n  - id: s\n    sql: "select 1"\n    timeout_ms: 1000');
    if c#>>'{workflow,spec,mode}' is distinct from 'worker' then
        raise exception 'a document that says nothing did not compile to mode worker: %', c;
    end if;
    if c#>>'{workflow,spec,steps,0,input,timeout_ms}' is distinct from '1000' then
        raise exception 'a step''s timeout_ms did not land in its input: %', c;
    end if;
    c := p8_compile_workflow(E'name: c\nmode: worker\nsteps:\n  - id: s\n    sql: "select 1"\n    mode: inline');
    if c#>>'{workflow,spec,mode}' is distinct from 'worker' or c#>>'{workflow,spec,steps,0,mode}' is distinct from 'inline' then
        raise exception 'the compiler lost a definition''s or a step''s mode: %', c;
    end if;
    c := p8_compile_workflow(E'name: c\nmode: inline\nsteps:\n  - id: m\n    matrix:\n      items: [1]\n      max_fanout: 1\n      template: {sql: "select 1", mode: worker}');
    if c#>>'{workflow,spec,mode}' is distinct from 'inline' or c#>>'{workflow,spec,steps,0,input,template,mode}' is distinct from 'worker' then
        raise exception 'the compiler lost a template''s mode: %', c;
    end if;
    c := p8_compile_workflow(E'name: c\nsteps:\n  - id: s\n    rest: {url: http://x}\n    mode: worker');
    if (c->>'ok')::boolean then
        raise exception 'the compiler accepted mode on a rest step: %', c;
    end if;
    c := p8_compile_workflow(E'name: c\nmode: sometimes\nsteps:\n  - id: s\n    sql: "select 1"');
    if (c->>'ok')::boolean then
        raise exception 'the compiler accepted mode: sometimes';
    end if;
    raise notice 'workflow/39 §7: the compiler writes mode worker by default and carries a step''s and a template''s';
end $$;

-- And a document that says nothing runs on a worker, start to finish through define_yaml.
do $$
declare v_run uuid; tk workflow.tasks;
begin
    perform workflow.define_yaml(E'name: t_1316w_yaml\nsteps:\n  - id: s\n    sql: "select 1 as n"');
    v_run := workflow.start_workflow('t_1316w_yaml', '{}'::jsonb);
    select * into tk from workflow.tasks where run_id = v_run;
    if tk.status <> 'ready' or tk.queue <> 'http' then
        raise exception 'a YAML workflow that says nothing did not leave its sql step for a worker: % %', tk.status, tk.queue;
    end if;
    raise notice 'workflow/39 §7: a YAML workflow that says nothing leaves its sql step for a worker on http';
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 8. A worker runs only a step it holds.
set local role worker;
select (workflow.claim_task('t1316w', 'w-1316', '{}')).id as b_task \gset
\set ON_ERROR_STOP off
savepoint other;
select workflow.execute_worker_sql_step(:'b_task', 'w-other');
rollback to savepoint other;
\set ON_ERROR_STOP on
reset role;
select set_config('t39.state8', :'LAST_ERROR_SQLSTATE', true), set_config('t39.limit8',
       coalesce(workflow.worker_sql_step_timeout(:'b_task', 'w-other')::text, 'none'), true) \gset
do $$
begin
    if current_setting('t39.state8') is distinct from '42501' or current_setting('t39.limit8') <> 'none' then
        raise exception 'another worker reached a step it does not hold: % %',
            current_setting('t39.state8'), current_setting('t39.limit8');
    end if;
    raise notice 'workflow/39 §8: a worker cannot run, or read the limit of, a sql step it does not hold';
end $$;

rollback;
