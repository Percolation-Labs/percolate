-- A RUN IS ESTIMATED BEFORE IT SPENDS, AND ITS COST IS RECORDED BESIDE THE ESTIMATE (REM-1125).
--
--   1. a run of a definition that has never run is estimated basis 'none':
--      every step, and the run, with nulls rather than zeros;
--   2. a worker holding a task's lease records what the attempt spent, in the
--      agent runtime's units; without the lease, nothing is recorded;
--   3. when the run ends, the actuals sit beside the estimate, per step and in
--      total, fan-out included;
--   4. the next run of the definition is estimated from that history, before
--      any of its tasks runs.
--
-- One transaction, rolled back. The workflow is the test's own, on a queue
-- nothing else claims.

\set ON_ERROR_STOP on

begin;

insert into workflow.definitions (name, spec) values
('t_est_1125', '{"steps":[{"key":"read","kind":"work","queue":"t-est-1125"},
                           {"key":"judge","kind":"work","queue":"t-est-1125","depends_on":["read"]}]}');

create temp table est_ids (k text primary key, v uuid);

-- 1. No history: estimated, and honestly unknown.
do $$
declare v_run uuid := workflow.start_workflow('t_est_1125', '{}'::jsonb);
begin
    insert into est_ids values ('run1', v_run);
    if (select array_agg(step_key || ':' || basis order by step_key nulls first)
          from workflow.run_estimates where run_id = v_run) is distinct from array[null, 'judge:none', 'read:none'] then
        raise exception 'a first run should be estimated basis none per step, and as a run: %',
            (select jsonb_agg(to_jsonb(e)) from workflow.run_estimates e where run_id = v_run);
    end if;
    if (select basis from workflow.run_estimates where run_id = v_run and step_key is null) is distinct from 'none'
       or (select est_input_tokens from workflow.run_estimates where run_id = v_run and step_key is null) is not null then
        raise exception 'an unknown run must not total to a number';
    end if;
end $$;

-- 2 and 3. The run spends, the worker reports it, and the run ends.
do $$
declare
    v_run uuid := (select v from est_ids where k = 'run1');
    t workflow.tasks;
begin
    select * into t from workflow.claim_task('t-est-1125', 'w-1125');
    if t.step_key is distinct from 'read' then raise exception 'expected read first, claimed %', t.step_key; end if;
    -- Without the lease: nothing.
    perform workflow.record_task_usage(t.id, t.attempts, '{"requests": 9, "input_tokens": 9}', 'someone-else');
    if exists (select 1 from workflow.task_usage where task_id = t.id) then
        raise exception 'usage was recorded by a worker that does not hold the lease';
    end if;
    perform workflow.record_task_usage(t.id, t.attempts,
        '{"requests": 2, "input_tokens": 1200, "output_tokens": 300, "tool_calls": 1, "cost": 0.0042,
          "model": "openai:gpt-4o-mini", "cache_read_tokens": 50}', 'w-1125');
    perform workflow.complete_task(t.id, '{"result": "read"}'::jsonb, 'w-1125');

    select * into t from workflow.claim_task('t-est-1125', 'w-1125');
    perform workflow.record_task_usage(t.id, t.attempts, '{"requests": 1, "input_tokens": 800, "output_tokens": 100}', 'w-1125');
    -- A repeated report of the same attempt replaces it rather than adding.
    perform workflow.record_task_usage(t.id, t.attempts, '{"requests": 1, "input_tokens": 800, "output_tokens": 120}', 'w-1125');
    perform workflow.complete_task(t.id, '{"result": "judged"}'::jsonb, 'w-1125');

    if (select status from workflow.runs where id = v_run) is distinct from 'succeeded' then
        raise exception 'the fixture run did not finish: %', (select status from workflow.runs where id = v_run);
    end if;
    if (select (actual_tasks, actual_requests, actual_input_tokens, actual_output_tokens)
          from workflow.run_estimates where run_id = v_run and step_key is null)
       is distinct from (2, 3, 2000::bigint, 420::bigint) then
        raise exception 'the run''s actuals are not beside its estimate: %',
            (select to_jsonb(e) from workflow.run_estimates e where run_id = v_run and step_key is null);
    end if;
    if (select actual_cost_usd from workflow.run_estimates where run_id = v_run and step_key = 'read') is distinct from 0.0042
       or (select actual_cost_usd from workflow.run_estimates where run_id = v_run and step_key = 'judge') is not null then
        raise exception 'cost is recorded where the runtime priced it, and null where it did not';
    end if;
end $$;

-- 4. The next run is estimated from that history before anything of it runs.
do $$
declare v_run uuid := workflow.start_workflow('t_est_1125', '{}'::jsonb);
begin
    if (select (basis, est_tasks, est_requests, est_input_tokens, est_output_tokens)
          from workflow.run_estimates where run_id = v_run and step_key = 'read')
       is distinct from ('history'::text, 1, 2, 1200::bigint, 300::bigint) then
        raise exception 'the read step was not estimated from its history: %',
            (select to_jsonb(e) from workflow.run_estimates e where run_id = v_run and step_key = 'read');
    end if;
    if (select (basis, est_tasks, est_input_tokens) from workflow.run_estimates where run_id = v_run and step_key is null)
       is distinct from ('history'::text, 2, 2000::bigint) then
        raise exception 'the run total is not the sum of its estimated steps: %',
            (select to_jsonb(e) from workflow.run_estimates e where run_id = v_run and step_key is null);
    end if;
    if exists (select 1 from workflow.task_usage where run_id = v_run) then
        raise exception 'the estimate should exist before the run spends anything';
    end if;
end $$;

rollback;
