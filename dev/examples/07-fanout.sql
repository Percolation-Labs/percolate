-- 7. Fan out over a query result.
--
-- One authored step becomes N tasks, in the transaction that completes it.
-- Nothing outside the database decides the width -- there is no controller
-- reading a list and templating a pod per element.
set local role app_owner;
set local request.jwt.claims = '{"sub":"80000000-0000-0000-0000-000000000001","orgs":["d0000000-0000-0000-0000-00000000000a"]}';

select workflow.define_yaml($$
name: reinspect
steps:
  - id: fan
    matrix:
      max_fanout: 50
      rows: {function: deficient_vessels}
      template:
        p8ql: 'LOOKUP "{{item.vessel}}"'

  - id: report
    needs: [fan]
    sql: {function: matrix_outputs, args: ['{{steps.fan.result.task_id}}']}
$$) as definition;

select workflow.start_workflow('reinspect', '{}'::jsonb) as run_id \gset

\echo '-- the matrix step expanded into one child per deficient vessel:'
select step_key, kind, status, coalesce(claimed_by,'in-database') as worker
from workflow.tasks where run_id = :'run_id'::uuid order by step_key;

\echo '-- each child carries its own row, and resolved its own vessel:'
select t.input->'item'->>'vessel' as vessel,
       t.input->'item'->>'code'   as code,
       (t.output->'result'->'rows'->0->>'match_kind') as resolved
from workflow.tasks t
where t.run_id = :'run_id'::uuid and t.step_key like 'fan[%'
order by 1;

\echo '-- and the run completed on its own once the children did:'
select status from workflow.runs where id = :'run_id'::uuid;
