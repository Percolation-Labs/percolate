-- 8. Wait for a person, or for a clock.
--
-- Two control steps. Neither acts; both hold the run open, and neither needs
-- a process to do the waiting. A detention decision is a person's, and the
-- run should sit there until they make it -- not time out and not poll.
set local role app_owner;
-- as a person, so the run has an owner and the harbourmaster can signal it
set local request.jwt.claims = '{"sub":"80000000-0000-0000-0000-000000000001","orgs":["d0000000-0000-0000-0000-00000000000a"]}';

select workflow.define_yaml($$
name: detention
steps:
  - id: notice
    p8ql: 'LOOKUP "Bulk Harmony"'

  - id: cooling_off
    needs: [notice]
    timer: 3600

  - id: approve
    needs: [cooling_off]
    signal: true

  - id: release
    needs: [approve]
    p8ql: 'GRAPH "Bulk Harmony" DEPTH 1'
$$) as definition;

select workflow.start_workflow('detention', '{}'::jsonb) as run_id \gset

\echo '-- the run is open, and it is the timer that is holding it:'
select step_key, kind, status, run_after > now() as still_waiting
from workflow.tasks where run_id = :'run_id'::uuid order by step_key;

\echo '-- a clock releases the timer. No worker claimed it.'
update workflow.tasks set run_after = now() - interval '1 minute'
where run_id = :'run_id'::uuid and kind = 'timer';
select workflow.promote_due_timers() as timers_promoted;
select workflow.drain_sql_steps(:'run_id'::uuid) as sql_steps_run;

select step_key, kind, status from workflow.tasks
where run_id = :'run_id'::uuid order by step_key;

\echo '-- now it waits on the person, and only signal_task moves it:'
select workflow.signal_task(:'run_id'::uuid, 'approve',
    '{"decision":"released","by":"harbourmaster"}'::jsonb) as signalled;
select workflow.drain_sql_steps(:'run_id'::uuid) as sql_steps_run;

select step_key, kind, status from workflow.tasks
where run_id = :'run_id'::uuid order by step_key;
select status from workflow.runs where id = :'run_id'::uuid;
