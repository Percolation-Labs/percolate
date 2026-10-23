-- Completing N children that all feed one successor: the shape `matrix`
-- produces, and the one place an O(N^2) would hide.
--
-- cascade_task_status fires per completed row and decrements pending_deps on
-- every dependent, so the question is whether that stays linear as the fan
-- widens. It does -- about 75us per child -- and idx_task_deps_reverse is why.
\set ON_ERROR_STOP on
set role app_owner;

insert into workflow.definitions (name, spec)
select 'scale_fanin', '{"steps":[{"key":"c","kind":"work","queue":"fan"}]}'
where not exists (select 1 from workflow.definitions where name = 'scale_fanin');

do $$
declare v_run uuid; v_succ uuid; v_child uuid; n int; t0 timestamptz; ms numeric;
begin
    foreach n in array array[100, 500, 2000] loop
        insert into workflow.runs (workflow_def_id, status)
        select id, 'running' from workflow.definitions where name = 'scale_fanin'
        returning id into v_run;

        insert into workflow.tasks (run_id, step_key, kind, queue, status, pending_deps)
        values (v_run, 'fanin', 'work', 'fan', 'pending', n) returning id into v_succ;

        for i in 1..n loop
            insert into workflow.tasks (run_id, step_key, kind, queue, status, pending_deps)
            values (v_run, 'c' || i, 'work', 'fan', 'running', 0) returning id into v_child;
            insert into workflow.task_dependencies (task_id, depends_on_task_id)
            values (v_succ, v_child);
        end loop;

        t0 := clock_timestamp();
        update workflow.tasks set status = 'succeeded', completed_at = now()
        where run_id = v_run and status = 'running';
        ms := extract(epoch from (clock_timestamp() - t0)) * 1000;

        raise notice 'fan-in % children: % ms (% us/child), successor now %',
            n, round(ms, 1), round(ms * 1000 / n),
            (select status from workflow.tasks where id = v_succ);
    end loop;
end $$;
