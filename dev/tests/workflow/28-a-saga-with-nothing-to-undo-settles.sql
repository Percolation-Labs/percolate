-- A SAGA WITH NOTHING TO UNDO SETTLES WHEN IT FAILS (REM-974).
--
-- A saga whose first step fails has completed nothing, so begin_compensation creates no compensation task, and
-- check_compensation_completion settles a run only once one exists. The run read `failed / compensating` for good:
-- an undo in progress that would never finish (REM-957's fresh reader, a booking whose first write failed). Every
-- workflow here is in-database, so each run finishes inside start_workflow and the assertions read the end state.
--
--   1  a saga failing on its first step reads failed / compensated, with no compensation task
--   2  a saga failing on its third step still waits for its compensations, then reads compensated
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void as $$
begin
    if p_ok is not true then
        raise exception 'saga: %', p_what;
    end if;
end $$ language plpgsql;

create function pg_temp.run(p_run uuid) returns text as $$
    select status || '/' || compensation_state from workflow.runs where id = p_run
$$ language sql;

create function pg_temp.compensations(p_run uuid) returns bigint as $$
    select count(*) from workflow.tasks where run_id = p_run and compensates_task_id is not null
$$ language sql;

create table public.wf28_holds (run_id uuid, what text);
grant select, insert, delete on public.wf28_holds to authenticated;


-- 1 ------------------------------------------------------------------------------------------------------------
select workflow.define_yaml($y$
name: saga_first_fails
steps:
  - id: reserve
    sql: {statement: "insert into public.wf28_holds values ('{{run.$id}}'::uuid, 1 / 0)", write: true}
    compensate_with: release
    saga_group: booking
  - id: confirm
    needs: [reserve]
    sql: {statement: "insert into public.wf28_holds values ('{{run.$id}}'::uuid, 'confirmed')", write: true}
    saga_group: booking
  - id: release
    sql: {statement: "delete from public.wf28_holds where run_id = '{{run.$id}}'::uuid", write: true}
$y$);

do $$
declare r uuid := workflow.start_workflow('saga_first_fails', '{}');
begin
    perform pg_temp.check((select status from workflow.tasks where run_id = r and step_key = 'reserve') = 'failed',
        '1 the first step failed');
    perform pg_temp.check(pg_temp.compensations(r) = 0, '1 there is nothing to undo, so no compensation task');
    perform pg_temp.check(pg_temp.run(r) is not distinct from 'failed/compensated',
        '1 the run settles as failed/compensated, not compensating for good: ' || coalesce(pg_temp.run(r), 'no run'));
end $$;


-- 2 ------------------------------------------------------------------------------------------------------------
select workflow.define_yaml($y$
name: saga_third_fails
steps:
  - id: reserve
    sql: {statement: "insert into public.wf28_holds values ('{{run.$id}}'::uuid, 'berth')", write: true}
    compensate_with: release
    saga_group: booking
  - id: pilot
    needs: [reserve]
    sql: {statement: "insert into public.wf28_holds values ('{{run.$id}}'::uuid, 'pilot')", write: true}
    compensate_with: cancel_pilot
    saga_group: booking
  - id: confirm
    needs: [pilot]
    sql: "select 1 / 0"
    saga_group: booking
  - id: release
    sql: {statement: "delete from public.wf28_holds where run_id = '{{run.$id}}'::uuid and what = 'berth'", write: true}
  - id: cancel_pilot
    sql: {statement: "delete from public.wf28_holds where run_id = '{{run.$id}}'::uuid and what = 'pilot'", write: true}
$y$);

do $$
declare r uuid := workflow.start_workflow('saga_third_fails', '{}');
begin
    perform pg_temp.check(pg_temp.compensations(r) = 2, '2 both completed steps get a compensation');
    perform pg_temp.check(pg_temp.run(r) is not distinct from 'failed/compensated',
        '2 the run reads compensated once both compensations ran: ' || coalesce(pg_temp.run(r), 'no run'));
    perform pg_temp.check((select count(*) from public.wf28_holds where run_id = r) = 0, '2 and both writes are undone');
end $$;

-- 2b: settling early must not claim a rollback that is still running. A compensation that waits on a worker
-- keeps the run compensating until it finishes.
select workflow.define_yaml($y$
name: saga_slow_undo
steps:
  - id: reserve
    sql: {statement: "insert into public.wf28_holds values ('{{run.$id}}'::uuid, 'berth')", write: true}
    compensate_with: release
    saga_group: booking
  - id: confirm
    needs: [reserve]
    sql: "select 1 / 0"
    saga_group: booking
  - id: release
    work: true
$y$);

do $$
declare r uuid := workflow.start_workflow('saga_slow_undo', '{}');
begin
    perform pg_temp.check(pg_temp.compensations(r) = 1, '2b one compensation, for a worker');
    perform pg_temp.check(pg_temp.run(r) is not distinct from 'failed/compensating',
        '2b and the run is still compensating while it waits: ' || coalesce(pg_temp.run(r), 'no run'));
end $$;


rollback;
