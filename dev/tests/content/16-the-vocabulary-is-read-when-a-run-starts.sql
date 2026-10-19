-- TWO ORDER TRAPS, CLOSED (REM-1057).
--
-- 1. The relations an extractor may use are read when a run starts. The ingest
--    and reflect workflows used to bake extractor_call's whole request, the
--    relation enum included, into the definition at install, so a relation
--    registered afterwards was never offered to the model. Now the definition
--    holds a reference, and the run's extractor_format step computes the
--    response_format from aiq.graph_vocabulary as it stands.
-- 2. Registering an entity table projects the rows already in it. The
--    projection triggers only see what is written afterwards, so a table loaded
--    first and registered second held no nodes.
--
-- WHAT WOULD MAKE IT FAIL. Bake the enum into the definition again and §1's
-- "the definition names no relation" raises; drop the rebuild from
-- register_entity_table and §2 raises.
--
-- One transaction, rolled back. Needs no model: §1 asserts the definition and
-- the step's output, which is what the worker sends.

\set ON_ERROR_STOP on
begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
    if p_ok is not true then
        raise exception 'the vocabulary is read when a run starts: %', p_what;
    end if;
end $$;

-- §1. Install the readers first, then register a relation.
select aiq.install_structure_null('gpt-4o') is not null as extractor;
select agentic.install_reflect_workflow('gpt-4o', 'structure_null', 'reflect_rem1057');
-- The suite's default embedding model has no provider, so the ingest workflow gets one that does.
insert into aiq.embedding_models (name, dim, provider, endpoint, credential_ref)
values ('rem1057-embed', 3, 'openai', 'https://api.openai.com/v1/embeddings', 'LLM_API_KEY');
select content.install_ingest_workflow(p_model => 'rem1057-embed', p_graph_index => true, p_graph_model => 'gpt-4o',
                                       p_name => 'ingest_rem1057') is not null as ingest;
select aiq.register_graph_vocabulary('[{"relation": "ships_via_rem1057"}]') ->> 'relations' as relations;

select pg_temp.check(position('ships_via_rem1057' in d.spec::text) = 0
                     and position('affiliated_with' in d.spec::text) = 0
                     and position('{{steps.extractor_format.result}}' in d.spec::text) > 0,
    format('§1: %s carries a reference to its run''s extractor_format step, and no relation list', d.name))
  from (select distinct on (name) name, spec from workflow.definitions
         where name in ('reflect_rem1057', 'ingest_rem1057') and deleted_at is null
         order by name, version desc) d;
select pg_temp.check(count(distinct name) = 2, '§1: both workflows were installed')
  from workflow.definitions where name in ('reflect_rem1057', 'ingest_rem1057');

-- What the step returns is what the model is sent: the relation registered after install is in it.
select pg_temp.check(aiq.extractor_response_format('structure_null', 'gpt-4o')
                       #> '{json_schema,schema,properties,edges,items,properties,r,enum}' ? 'ships_via_rem1057',
    '§1: the extractor_format step offers a relation registered after the workflow was installed');

-- §2. Load a table, then register it.
create schema rem1057;
create table rem1057.ports (id uuid primary key default gen_random_uuid(), name text not null unique);
insert into rem1057.ports (name) values ('Rotterdam'), ('Felixstowe');
select aiq.register_entity_table('rem1057_port', 'rem1057.ports', 'n.name', 'n.name', 'rbac.shared_org_id()');
select pg_temp.check((select count(*) from aiq.nodes where entity_type = 'rem1057_port') = 2,
    '§2: the two rows loaded before registration are nodes');
insert into rem1057.ports (name) values ('Gothenburg');
select pg_temp.check((select count(*) from aiq.nodes where entity_type = 'rem1057_port') = 3,
    '§2: and a row written after it is projected by the trigger, as before');

rollback;
