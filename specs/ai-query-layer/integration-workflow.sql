-- ============================================================
-- ai-query-layer <-> workflow-engine integration.
--
-- Applied AFTER both schemas, as app_owner. Split out for the same reason
-- workflow-engine/integration-rbac.sql is: each core must stay deployable on
-- its own, and anything crossing a boundary belongs in one file applied last.
--
-- Caught by verifying a clean install rather than by reading: putting
-- workflow.p8ql() in workflow-engine/schema.sql made that file reference
-- aiq.query(), and the install failed at step 2 with `schema "aiq" does not
-- exist` -- because workflow loads before ai-query-layer. A workflow engine
-- that cannot be installed without a query layer is not the workflow engine
-- this collection specs.
-- ============================================================

-- Two arities. SEMANTIC and HYBRID need a vector, which the database cannot
-- produce -- embedding is an external model call. So those modes are composed
-- as: a `rest` step that embeds, then a p8ql step taking
-- {{steps.embed.result}} as its second argument. LOOKUP, GRAPH and TEXT need
-- no vector and use the one-argument form.
create or replace function workflow.p8ql(p_query text)
returns jsonb as $$
    select aiq.query(p_query);
$$ language sql;

create or replace function workflow.p8ql(p_query text, p_embedding jsonb)
returns jsonb as $$
    select aiq.query(p_query,
        case when p_embedding is null or p_embedding = 'null'::jsonb then null
             else (select array_agg((v #>> '{}')::real order by ord)
                   from jsonb_array_elements(p_embedding) with ordinality t(v, ord))::vector
        end);
$$ language sql;

grant execute on function workflow.p8ql(text) to authenticated, worker;
grant execute on function workflow.p8ql(text, jsonb) to authenticated, worker;

-- Register P8QL as a workflow step function, so `p8ql:` in a YAML workflow
-- resolves. Registration is owner-only (§17), so this is the deployment
-- deciding that queries may run as steps -- not something a workflow author
-- can grant themselves.
select workflow.register_step_function(
    'p8ql', 'workflow.p8ql', array['text'], 30000,
    'Run a P8QL query as a workflow step');
select workflow.register_step_function(
    'p8ql_vec', 'workflow.p8ql', array['text','jsonb'], 30000,
    'P8QL with an embedding produced by a prior step');
