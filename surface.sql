-- ============================================================
-- SURFACE AUDIT
--
-- Declares the surface area the specs promise, then checks the database
-- actually provides it. Run after install.sh against any deployment.
--
--     psql "$DSN" -f surface.sql
--
-- This exists because the gaps in this collection have all been found the hard
-- way: a document telling readers to register `wm.resource_chunks`, a table
-- nobody shipped; `aiq.query()` needing an extension the installer did not
-- install; `workflow.p8ql()` making the engine depend on the query layer and
-- breaking a clean install. Every one of those was a promise made in prose
-- with nothing checking it.
--
-- The rule this encodes: a capability named in a spec is a row in the
-- expectations list below. If the spec says it, this file asserts it, and a
-- missing piece fails here rather than in someone's first hour.
-- ============================================================

\set ON_ERROR_STOP on
\pset pager off

create temporary table expected (
    subsystem text,
    kind      text,     -- schema | table | function | policy | extension | registration
    name      text,
    detail    text,
    why       text      -- the spec sentence this row exists to keep honest
);

insert into expected (subsystem, kind, name, detail, why) values

-- ---------- extensions -------------------------------------------------
('install','extension','pgcrypto',null,'INSTALL.md: required'),
('install','extension','pg_trgm',null,'INSTALL.md: required, FUZZY over node_keys'),
('install','extension','vector',null,'INSTALL.md: required, embeddings + HNSW'),
('install','extension','percolate_parser',null,'the C parsers: superuser-installed, no tables'),
('install','extension','percolate',null,'the schema, installed by app_owner so RLS is real'),

-- ---------- user-rbac --------------------------------------------------
('user-rbac','schema','rbac',null,'spec.md: identity lives in Postgres'),
('user-rbac','table','rbac.users',null,'spec.md §1'),
('user-rbac','table','rbac.api_keys',null,'spec.md §4: agents authenticate without a password'),
('user-rbac','table','rbac.refresh_tokens',null,'spec.md §3: revocable credential'),
('user-rbac','table','rbac.auth_events',null,'spec.md §6: append-only audit'),
('user-rbac','function','rbac.login','text,text,text,text','spec.md §4.2: atomic login'),
('user-rbac','function','rbac.create_user_with_password','text,text','spec.md §4.1: signup'),
('user-rbac','function','rbac.current_user_id','','spec.md §2: every RLS policy calls this'),
('user-rbac','function','rbac.has_permission','uuid,text,text','spec.md §2: one authz function'),
('user-rbac','function','rbac.verify_api_key','text','spec.md §4.6: API-key path'),

-- ---------- workflow-engine --------------------------------------------
('workflow-engine','schema','workflow',null,'spec.md: Postgres owns orchestration state'),
('workflow-engine','table','workflow.definitions',null,'spec.md §2'),
('workflow-engine','table','workflow.runs',null,'spec.md §2'),
('workflow-engine','table','workflow.tasks',null,'spec.md §2'),
('workflow-engine','table','workflow.step_functions',null,'schema.sql §17: sql steps are allow-listed'),
('workflow-engine','function','workflow.start_workflow','text,jsonb,text,text','spec.md §4'),
('workflow-engine','function','workflow.claim_task','text,text','spec.md: SKIP LOCKED claiming'),
('workflow-engine','function','workflow.get_task_context','uuid,text','§16: a worker must see its run input'),
('workflow-engine','function','workflow.complete_task','uuid,jsonb','spec.md §4'),
('workflow-engine','function','workflow.fail_task','uuid,jsonb,boolean','§16: terminal vs retryable'),
('workflow-engine','function','workflow.begin_compensation','uuid,text','spec.md: saga'),
('workflow-engine','function','workflow.reap_stale_tasks','','spec.md: crash recovery'),
('workflow-engine','function','workflow.define_yaml','text','YAML.md: workflows are authored as YAML'),
('workflow-engine','function','workflow.execute_sql_step','uuid','§17: sql steps run with no process'),
('workflow-engine','function','workflow.resolve_args','jsonb,uuid','§17: sql steps consume prior output'),

-- ---------- ai-query-layer ---------------------------------------------
('ai-query-layer','schema','aiq',null,'brief.md: one query dialect'),
('ai-query-layer','table','aiq.nodes',null,'graph-identity.md: write-time node registry'),
('ai-query-layer','table','aiq.node_keys',null,'graph-identity.md: lookup index'),
('ai-query-layer','table','aiq.edges',null,'graph-identity.md: authored soft links'),
('ai-query-layer','table','aiq.embedding_models',null,'schema.sql §10: one space per MODEL'),
('ai-query-layer','function','aiq.query','text,vector','§9: one RPC for the whole dialect'),
('ai-query-layer','function','aiq.lookup','text,boolean,integer','§7: LOOKUP / FUZZY'),
('ai-query-layer','function','aiq.graph_neighbors','uuid,text,integer','§7: GRAPH depth 1'),
('ai-query-layer','function','aiq.graph_walk','uuid,integer,text,integer','§7: GRAPH depth n>1'),
('ai-query-layer','function','aiq.semantic_in','vector,text,integer','§10: SEMANTIC, model-scoped'),
('ai-query-layer','function','aiq.lexical','text,text,integer','§11: TEXT'),
('ai-query-layer','function','aiq.hybrid','text,text,vector,text,integer,integer','§11: HYBRID / RRF'),
('ai-query-layer','function','aiq.sql_passthrough','text','§12: the escape hatch'),
('ai-query-layer','function','aiq.check_drift','text','graph-identity.md D7'),
('ai-query-layer','function','aiq.rebuild_entity_type','text','graph-identity.md: rebuild'),

-- ---------- world-model-ingestion --------------------------------------
('world-model-ingestion','schema','content',null,'brief.md §2-§3: the content plane'),
('world-model-ingestion','table','content.channels',null,'brief.md §2: a source is a row'),
('world-model-ingestion','table','content.files',null,'brief.md §3: pointers, never bytes'),
('world-model-ingestion','table','content.resources',null,'brief.md §2: unit of ingested content'),
('world-model-ingestion','table','content.resource_chunks',null,'brief.md §3: what SEMANTIC searches'),
('world-model-ingestion','function','content.register_upload',
     'text,text,text,text,bigint,text,text,text,uuid,jsonb,text,text','brief.md §3.5: upload registers AND starts ingestion'),
('world-model-ingestion','function','content.register_fetched','text,text,text,text,uuid,jsonb','brief.md §2: pulled sources'),
('world-model-ingestion','function','content.resolve_file','uuid','brief.md §3.5: proxied reads'),
('world-model-ingestion','function','content.record_chunks','uuid,jsonb','brief.md §3: chunking writes back'),
('world-model-ingestion','function','content.check_drift','','brief.md §3: reconciliation is definition-of-done'),

-- ---------- registrations the docs depend on ---------------------------
('cross','registration','lexical:chunks',null,'USAGE.md tells readers TEXT searches "chunks"'),
('cross','registration','semantic:chunks',null,'USAGE.md tells readers SEMANTIC searches "chunks"'),
('cross','registration','step:p8ql',null,'YAML.md: p8ql: steps must resolve'),
('cross','registration','step:record_chunks',null,'ingestion pipeline is declarative'),
('cross','registration','entity:document',null,'integration.sql: resources become graph nodes');

-- ============================================================
-- Check each expectation against the catalog.
-- ============================================================
create temporary view surface as
select e.*,
  case e.kind
    when 'extension' then exists (select 1 from pg_extension where extname = e.name)
    when 'schema'    then exists (select 1 from pg_namespace where nspname = e.name)
    when 'table'     then to_regclass(e.name) is not null
    when 'function'  then to_regprocedure(e.name || '(' || coalesce(e.detail,'') || ')') is not null
    when 'registration' then case split_part(e.name, ':', 1)
        when 'lexical'  then exists (select 1 from aiq.lexical_sources  where name = split_part(e.name,':',2))
        when 'semantic' then exists (select 1 from aiq.semantic_sources where name = split_part(e.name,':',2))
        when 'step'     then exists (select 1 from workflow.step_functions where name = split_part(e.name,':',2))
        when 'entity'   then exists (select 1 from aiq.entity_registry where entity_type = split_part(e.name,':',2))
        else false end
    else false
  end as present
from expected e;

\echo
\echo '=== SURFACE BY SUBSYSTEM ==='
select subsystem,
       count(*) as declared,
       count(*) filter (where present) as present,
       count(*) filter (where not present) as missing
from surface group by subsystem order by subsystem;

\echo
\echo '=== MISSING (each one is a promise the specs make and the database does not keep) ==='
select subsystem, kind, name, coalesce(detail,'') as signature, why
from surface where not present order by subsystem, kind, name;

\echo
do $$
declare v_missing int;
begin
    select count(*) into v_missing from surface where not present;
    if v_missing > 0 then
        raise exception
            'SURFACE INCOMPLETE: % of % declared capabilities are missing. '
            'Each is a spec promise with nothing behind it.',
            v_missing, (select count(*) from surface);
    end if;
    raise notice 'SURFACE COMPLETE: all % declared capabilities present',
        (select count(*) from surface);
end $$;
