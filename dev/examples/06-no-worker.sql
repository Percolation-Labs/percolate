-- 6. A workflow with nothing running.
--
-- Both steps are in-database kinds, so the run finishes before
-- start_workflow returns. There is no queue to poll and no process to deploy.
set local role app_owner;
set local request.jwt.claims = '{"orgs":["d0000000-0000-0000-0000-00000000000a"]}';

select workflow.define_yaml($$
name: fleet_brief
steps:
  - id: operator
    p8ql: 'LOOKUP "MERI"'

  - id: fleet
    needs: [operator]
    p8ql: 'GRAPH "MERI" DEPTH 1'

  - id: reports
    needs: [operator]
    p8ql: 'TEXT "PSC-441" FROM chunks LIMIT 3'
$$) as definition;

select workflow.start_workflow('fleet_brief', '{}'::jsonb) as run_id \gset

\echo '-- already finished, and no task was ever claimed:'
select status, completed_at is not null as finished
from workflow.runs where id = :'run_id'::uuid;

select step_key, kind, status, coalesce(claimed_by,'in-database') as worker,
       jsonb_array_length(output->'result'->'rows') as rows_out
from workflow.tasks where run_id = :'run_id'::uuid order by step_key;

\echo '-- the fleet step returned the graph, in the row:'
select r->>'entity_type' as type, r->>'summary' as summary
from workflow.tasks t,
     jsonb_array_elements(t.output->'result'->'rows') r
where t.run_id = :'run_id'::uuid and t.step_key = 'fleet';

-- The one thing to know about p8ql steps.
\echo '-- a p8ql step holding PLAIN SQL does not execute it. The task still'
\echo '-- goes done, carrying a note instead of rows:'
select workflow.define_yaml($$
name: plain_sql_step
steps:
  - id: count
    p8ql: 'select count(*) from harbour.vessels'
$$);
select workflow.start_workflow('plain_sql_step','{}'::jsonb) as sql_run \gset
select status, output->'result'->>'mode' as mode, output->'result'->>'note' as note
from workflow.tasks where run_id = :'sql_run'::uuid;
