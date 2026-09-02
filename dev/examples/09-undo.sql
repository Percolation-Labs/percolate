-- 9. Undo the steps that already worked.
--
-- A berth is booked, then a pilot, then the tide window is missed. Two things
-- have to be given back, in the reverse of the order they were taken, and the
-- run has to end knowing it rolled back rather than ending green.
set local role app_owner;
set local request.jwt.claims = '{"sub":"80000000-0000-0000-0000-000000000001","orgs":["d0000000-0000-0000-0000-00000000000a"]}';

select workflow.define_yaml($$
name: berth_booking
steps:
  - id: reserve_berth
    p8ql: 'LOOKUP "Rotterdam"'
    compensate_with: release_berth
    saga_group: booking

  - id: book_pilot
    needs: [reserve_berth]
    p8ql: 'LOOKUP "MERI"'
    compensate_with: cancel_pilot
    saga_group: booking

  - id: confirm_tide
    needs: [book_pilot]
    queue: http
    rest: {url: 'https://tides.example/window', method: GET}

  - id: release_berth
    p8ql: 'LOOKUP "Rotterdam"'

  - id: cancel_pilot
    p8ql: 'LOOKUP "MERI"'
$$) as definition;

select workflow.start_workflow('berth_booking', '{}'::jsonb) as run_id \gset

\echo '-- the two saga steps ran; the tide check is queued for a worker:'
select step_key, kind, status from workflow.tasks
where run_id = :'run_id'::uuid order by step_key;

\echo '-- the tide window is missed, terminally:'
select workflow.fail_task(
    (select id from workflow.tasks where run_id = :'run_id'::uuid and step_key='confirm_tide'),
    '{"error":"no tide window before 06:00"}'::jsonb,
    p_terminal => true) as failed;

\echo '-- roll the saga group back:'
select workflow.begin_compensation(:'run_id'::uuid, 'booking') as compensations_created;

select step_key, kind, status from workflow.tasks
where run_id = :'run_id'::uuid order by step_key;

\echo '-- the run ends compensated, not completed. A saga that rolled back and'
\echo '-- reported success is the failure this distinction exists for.'
select status, compensation_state from workflow.runs where id = :'run_id'::uuid;
