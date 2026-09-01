-- ============================================================
-- world-model-ingestion <-> ai-query-layer + user-rbac + workflow integration.
--
-- Applied last, after every other schema. Same boundary discipline as the
-- other integration files: content/schema.sql alone is a content store with no
-- query layer and no identity system, and everything crossing a boundary lives
-- here.
--
-- This is the file that makes ai-query-layer/USAGE.md true. That document
-- tells a reader to register a lexical source called "chunks"; until this ran,
-- there was nothing to register.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Register the corpus with the query layer.
--
-- register_lexical_source adds a generated tsvector column and a GIN index to
-- resource_chunks, so TEXT mode works over real content rather than a fixture.
-- ------------------------------------------------------------
select aiq.register_lexical_source('chunks', 'content.resource_chunks');

insert into aiq.semantic_sources (name, source_table)
values ('chunks', 'content.resource_chunks')
on conflict (name) do update set source_table = excluded.source_table;

-- ------------------------------------------------------------
-- 2. Resources become graph nodes; chunks deliberately do NOT.
--
-- graph-identity.md's inclusion policy: a row becomes a node if it is
-- LOOKUP-searchable or an edge endpoint. A document is both -- you name it,
-- and events reference it. A chunk is neither: it is machine-generated
-- data-plane volume that joins in after identity is known, and admitting
-- chunks would put the node registry on the wrong side of the scale argument.
--
-- Only 'ready' resources are included: a pending or failed one is not yet a
-- thing you can meaningfully look up, and the inclusion predicate is shared
-- with rebuild so the two cannot drift.
-- ------------------------------------------------------------
select aiq.register_entity_table(
    'document',
    'content.resources',
    'coalesce(n.title, n.uri, n.id::text)',   -- canonical key
    'coalesce(n.title, n.uri)',               -- summary
    'n.org_id',
    $$n.status = 'ready'$$
);

insert into aiq.relation_types (src_type, relation, dst_type, inverse_label, description) values
  ('document','derived_from','document','source_of','a document produced from another'),
  ('document','supersedes','document','superseded_by','a newer revision of the same thing')
on conflict do nothing;

-- ------------------------------------------------------------
-- 3. Tenancy.
--
-- resources and chunks are org-scoped; FILES ARE NOT, and that asymmetry is
-- deliberate rather than an omission. Content-hash dedup means one files row
-- can be referenced by resources belonging to different tenants -- there is no
-- single owner, so an owner-scoped policy on it would be meaningless. Files
-- are therefore never exposed directly: a caller asks for a resource, and
-- content.resolve_file() joins through it (SECURITY INVOKER, so the caller's
-- RLS on resources decides).
--
-- Chunks inherit their resource's visibility rather than carrying a second
-- copy of org_id. Duplicating a tenancy fact is what let node_keys.org_id and
-- nodes.org_id drift and made LOOKUP silently return nothing; one source of
-- truth makes that impossible rather than merely detectable.
-- ------------------------------------------------------------
alter table content.channels        enable row level security;
alter table content.resources       enable row level security;
alter table content.resource_chunks enable row level security;

create policy channels_org_scoped on content.channels for select
  using (org_id is null or org_id in (select aiq.current_org_ids()));

create policy resources_org_scoped on content.resources for select
  using (org_id is null or org_id in (select aiq.current_org_ids()));

create policy chunks_via_resource on content.resource_chunks for select
  using (exists (select 1 from content.resources r
                 where r.id = content.resource_chunks.resource_id));

-- ------------------------------------------------------------
-- 4. Grants.
--
-- Read paths are SECURITY INVOKER, so callers need real SELECT and RLS does
-- the filtering -- views for column secrecy, RLS for row visibility, and here
-- there are no secret columns. files is the exception, granted to nobody.
-- ------------------------------------------------------------
grant usage on schema content to authenticated, worker, api_viewer;
grant select on content.channels, content.resources, content.resource_chunks
    to authenticated, api_viewer;

-- REVOKE BEFORE GRANT, on every one of them, and it is not ceremony.
--
-- Postgres grants EXECUTE on a new function to PUBLIC unless it is taken away,
-- so every line below that reads "worker may call this" has always meant
-- "worker AND everyone else may call this" -- the grant is an addition to
-- access every role already had, not a restriction. The engine's own
-- enumeration found eleven functions like that (workflow-engine/
-- integration-rbac.sql §6); this is the same sweep over `content`.
--
-- Measured before writing it, because the interesting half is which layer was
-- actually holding: an ANONYMOUS caller (web_anon, no claims) trying to rewrite
-- another org's chunks is refused with "permission denied for SCHEMA content"
-- -- schema usage, granted to authenticated/worker/api_viewer and never to
-- web_anon, was doing the work that the function grants appeared to. That is
-- one revoke away from being the only thing between an unauthenticated request
-- and content.record_chunks, and it is not a defence anyone chose.
--
-- What it does change today: `authenticated` HAS usage on this schema, so
-- until these lines existed a logged-in user could call ingest_target,
-- record_ingest and register_dataset -- three functions this file documents as
-- worker-only. Their own org check meant no cross-tenant leak, but
-- ingest_target hands back a bucket and an object key for the caller's own
-- resources, and the read path a user is offered is the Content Server's
-- proxy precisely so that a storage location never becomes one.
revoke execute on function content.register_upload(text,text,text,text,bigint,text,text,text,uuid,jsonb,text,text) from public;
revoke execute on function content.register_fetched(text,text,text,text,uuid,jsonb) from public;
revoke execute on function content.record_chunks(uuid,jsonb) from public;
revoke execute on function content.resolve_file(uuid) from public;
revoke execute on function content.check_drift() from public;
revoke execute on function content.may_access_org(uuid) from public;
revoke execute on function content.assert_org_write(uuid,text) from public;
revoke execute on function content.ingest_target(uuid) from public;
revoke execute on function content.record_ingest(uuid,jsonb) from public;
revoke execute on function content.register_dataset(uuid,text,text,text,jsonb,bigint,text,text[]) from public;
revoke execute on function content.chunks_to_embed(uuid) from public;
revoke execute on function content.windows_to_index(uuid) from public;
revoke execute on function content.merge_policy(jsonb,jsonb) from public;
revoke execute on function content.dataset_uri(text) from public;
-- (install_ingest_workflow's own revoke is in ingestion.sql, where it is
--  DEFINED -- this file loads first, and a revoke can only name a signature
--  that already exists. The same lesson register_artifact taught below.)

-- The Content Server registers uploads and the ingestion workflow records
-- chunks; both go through SECURITY DEFINER functions, so neither needs a write
-- grant on any table.
grant execute on function content.register_upload(text,text,text,text,bigint,text,text,text,uuid,jsonb,text,text) to authenticated;
grant execute on function content.register_fetched(text,text,text,text,uuid,jsonb) to authenticated;
grant execute on function content.record_chunks(uuid,jsonb) to worker, authenticated;
grant execute on function content.resolve_file(uuid) to authenticated;
grant execute on function content.check_drift() to authenticated, worker;

-- ------------------------------------------------------------
-- 5. Ingestion as workflow step functions.
--
-- Registered so a YAML workflow can name them, which is what makes the
-- ingestion pipeline declarative rather than code. Registration is owner-only,
-- so this is the deployment deciding these may run as steps.
-- ------------------------------------------------------------
select workflow.register_step_function(
    'record_chunks', 'content.record_chunks', array['uuid','jsonb'], 60000,
    'Store chunks for a resource and mark it ready');
select workflow.register_step_function(
    'content_drift', 'content.check_drift', array[]::text[], 60000,
    'Report orphaned files and unchunked resources');

-- ------------------------------------------------------------
-- 5b. Workflow artifacts -- the fourth output class, given a home.
--
-- workflow-engine/outputs.md: a step produces rows, a validated assistant
-- message, an inline payload, or BYTES. Bytes are the one the engine cannot
-- hold. Its answer is a ref beside the payload --
-- {"result": ..., "$artifact": "<resource id>"} -- and this section is what
-- makes that id mean something.
--
-- A RESOURCE ID, NOT AN s3:// URI, and the difference is the whole point. A
-- bucket path in a JSONB column is a string with no owner: not RLS-scoped, not
-- checksummed, not deduped, not servable, not garbage-collected, and it drags
-- a bucket name into a row that is supposed to stay inspectable and
-- replayable -- the same argument that makes credential_ref a NAME. A resource
-- id is all of those things already, because content/schema.sql built them for
-- uploads and an artifact is an upload the system performed on its own behalf.
--
-- Nothing new is stored to make the link. The task's output holds the resource
-- id (forward) and the resource's metadata holds the task id (back), each on
-- the row that owns it. A join table would be a third copy of a fact two rows
-- already carry.
-- ------------------------------------------------------------
-- WHERE NOT EXISTS rather than ON CONFLICT, and not as a style choice:
-- channels is UNIQUE (org_id, name) with a NULLABLE org_id, so two global
-- channels of the same name do not collide -- NULLs are distinct in a unique
-- index unless it is declared NULLS NOT DISTINCT, and this one is not. An
-- ON CONFLICT here raises "no unique or exclusion constraint matching"
-- (it does; that is how this comment got written), and the version that
-- compiles would silently insert a second row on the next install, leaving
-- register_upload's lookup to pick one of them arbitrarily.
insert into content.channels (name, kind, config)
select 'workflow_artifacts', 'file_upload',
       -- No ingest_workflow: registering an artifact must not start an
       -- ingestion run. That key is what makes an upload chunk itself, and a
       -- rendered PDF that a step just produced is output, not intake. A
       -- channel with none configured registers content and starts nothing,
       -- which content.register_upload documents as a legitimate choice.
       '{"description": "bytes produced by a workflow step, refd from tasks.output"}'::jsonb
where not exists (
    select 1 from content.channels where name = 'workflow_artifacts' and org_id is null);

create or replace function workflow.register_artifact(
    p_task_id      uuid,
    p_checksum     text,
    p_bucket       text,
    p_object_key   text,
    p_size_bytes   bigint,
    p_content_type text default null,
    p_title        text default null,
    p_org_id       uuid default null
) returns uuid as $$
declare
    t      workflow.tasks;
    v_res  uuid;
    v_file uuid;
begin
    select * into t from workflow.tasks where id = p_task_id;
    if not found then
        raise exception
            'no task % -- an artifact belongs to the task that produced it, and the '
            'task id is what makes the ref traceable back to a step', p_task_id;
    end if;

    -- external_id is the TASK id, so a retry converges on one resource instead
    -- of leaving a trail of orphans -- the same idempotency the engine already
    -- gets from tasks.idempotency_key. Bytes are deduped independently by
    -- checksum, so two tasks writing identical output share one files row and
    -- still get a resource each.
    v_res := content.register_upload(
        p_channel      => 'workflow_artifacts',
        p_checksum     => p_checksum,
        p_bucket       => p_bucket,
        p_object_key   => p_object_key,
        p_size_bytes   => p_size_bytes,
        p_content_type => p_content_type,
        p_title        => coalesce(p_title, t.step_key),
        p_org_id       => p_org_id,
        p_metadata     => jsonb_build_object('workflow', jsonb_build_object(
                              'run_id', t.run_id, 'task_id', t.id,
                              'step_key', t.step_key, 'attempt', t.attempts)),
        p_external_id  => p_task_id::text,
        p_trace_id     => (select trace_id from workflow.runs where id = t.run_id));

    -- register_upload's ON CONFLICT touches updated_at and nothing else, which
    -- is right for a puller re-seeing the same item and WRONG here: attempt 2
    -- of a task can legitimately produce different bytes, and leaving the
    -- resource pointed at attempt 1's file would be a failure that reports
    -- success. Repoint it, and mark it stored -- an artifact is retrievable
    -- the moment it lands and has no chunking stage to wait for.
    select id into v_file from content.files where checksum = p_checksum;
    update content.resources
       set file_id = v_file, status = 'stored', updated_at = now()
     where id = v_res
       and (file_id is distinct from v_file or status <> 'stored');

    return v_res;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- The read side. Wraps content.resolve_file so a caller never needs a grant on
-- content.files -- which is granted to nobody, because content-hash dedup
-- leaves it with no single owner. Scoping therefore happens on the RESOURCE,
-- inside resolve_file, exactly as it does for an ordinary upload: an artifact
-- from another tenant's run is not visible here.
--
-- Returns jsonb, not a table, for the same reason workflow.p8ql does:
-- call_step_function wraps a step function's result as to_jsonb(fn(...)), and
-- a set-returning function under that produces "one row if there was one and
-- nothing at all otherwise" -- which a step would store as {"result": null}
-- and call success. RAISING instead makes an unreadable artifact a terminal
-- step failure (sqlstate P0001 is on execute_sql_step's do-not-retry list),
-- which is right: a ref that does not resolve resolves no better next time.
create or replace function workflow.artifact(p_resource_id uuid) returns jsonb as $$
declare v_out jsonb;
begin
    select to_jsonb(f) into v_out from content.resolve_file(p_resource_id) f;
    if v_out is null then
        raise exception
            'artifact % is not resolvable -- either no such resource, or it belongs '
            'to an org this caller cannot see. An artifact is scoped by its resource, '
            'not by the bucket it happens to sit in.', p_resource_id;
    end if;
    return v_out;
end;
$$ language plpgsql stable;

-- Both directions of the link, as one join, so "what did this run produce" and
-- "which step produced this file" are the same query read from either end.
create or replace view workflow.v_artifacts as
select t.run_id,
       t.id             as task_id,
       t.step_key,
       r.id             as resource_id,
       r.title,
       r.status,
       f.checksum,
       f.bucket,
       f.object_key,
       f.content_type,
       f.size_bytes,
       r.ingested_at
from workflow.tasks t
join content.resources r
  on r.id = workflow.artifact_ref(t.output)
left join content.files f on f.id = r.file_id;

grant execute on function workflow.register_artifact(uuid,text,text,text,bigint,text,text,uuid)
    to worker, authenticated;
grant execute on function workflow.artifact(uuid) to worker, authenticated;
grant select on workflow.v_artifacts to authenticated;

-- Registered so a downstream step can be handed an artifact by id and resolve
-- it in-database, which is what keeps class 4 from needing a worker just to
-- look something up: {{steps.render.$artifact}} is an ordinary argument.
select workflow.register_step_function(
    'artifact', 'workflow.artifact', array['uuid'], 30000,
    'Resolve a workflow artifact ref to its bucket, key, type and size');

-- ------------------------------------------------------------
-- 6. Self-check.
-- ------------------------------------------------------------
-- ------------------------------------------------------------
-- 6. Ingestion — the default pipeline, and the channel that runs it.
--
-- schema.sql §7 built the pieces; this is where they become a thing that runs
-- when someone uploads a file, which is the only form of "built" that counts
-- for the claim brief.md §3.5 makes.
-- ------------------------------------------------------------
grant execute on function content.ingest_target(uuid) to worker;
grant execute on function content.record_ingest(uuid, jsonb) to worker;
grant execute on function content.register_dataset(uuid, text, text, text, jsonb, bigint, text, text[]) to worker;
grant execute on function content.merge_policy(jsonb, jsonb) to worker, authenticated;
grant execute on function content.chunks_to_embed(uuid) to worker, authenticated;
grant execute on function content.windows_to_index(uuid) to worker, authenticated;
grant execute on function content.dataset_uri(text) to authenticated, api_viewer;

-- The batching embed path (ai-query-layer/schema.sql §10b). `worker` only:
-- embed_batch_call hands back a url and a credential NAME, and
-- record_embeddings writes the space every SEMANTIC search ranks against --
-- a user who could write vectors could poison retrieval for the deployment.
-- USAGE on the schema as well as EXECUTE on the functions, because EXECUTE
-- alone is not enough: without it the call fails with "permission denied for
-- schema aiq" -- which reads like a missing grant on the function and is not.
-- `worker` still holds no table privilege anywhere; usage on a schema grants
-- the right to NAME what it already has execute on.
grant usage on schema aiq to worker;
grant execute on function aiq.embed_batch_call(text, jsonb) to worker;
grant execute on function aiq.record_embeddings(text, jsonb) to worker;

-- ingest_target and record_ingest are granted to `worker` and NOT to
-- `authenticated`, and the asymmetry is the rule stated in schema.sql §4a
-- being applied rather than an oversight. ingest_target hands back a bucket
-- and an object key -- a storage location is a capability, and the read path
-- a user is offered is content.resolve_file() through the Content Server.
-- Worker-facing functions are authorized by their grant, because `worker` is
-- infrastructure rather than a person.

-- Datasets are org-scoped exactly as resources are, and for the same reason:
-- a dataset is a thing a tenant uploaded, and its bucket prefix is a
-- capability. dataset_files carries no org of its own -- it inherits, the way
-- chunks do, because duplicating a tenancy fact is how node_keys and nodes
-- drifted.
alter table content.datasets      enable row level security;
alter table content.dataset_files enable row level security;

create policy datasets_org_scoped on content.datasets for select
  using (org_id is null or org_id in (select aiq.current_org_ids()));

create policy dataset_files_via_dataset on content.dataset_files for select
  using (exists (select 1 from content.datasets d
                 where d.id = content.dataset_files.dataset_id));

grant select on content.datasets, content.dataset_files to authenticated, api_viewer;

select workflow.register_step_function(
    'chunks_to_embed', 'content.chunks_to_embed', array['uuid'], 30000,
    'The chunks of one resource, as rows for an embed matrix to fan out over');
select workflow.register_step_function(
    'windows_to_index', 'content.windows_to_index', array['uuid'], 30000,
    'The chunks of one resource, as windows for a graph extractor to fan out over');


do $$
declare v_bad text;
begin
    -- files must not be readable by an API role: dedup means it has no single
    -- owner, so any row-level policy on it is meaningless and a grant would
    -- leak one tenant's storage keys to another.
    select string_agg(grantee, ', ') into v_bad
    from information_schema.role_table_grants
    where table_schema = 'content' and table_name = 'files'
      and grantee in ('web_anon','authenticated','api_viewer','worker');
    if v_bad is not null then
        raise exception
            'content.files is granted to %, but it is deduped by content hash and '
            'therefore has no single owner -- reads must go through '
            'content.resolve_file(), which is scoped by the resource.', v_bad;
    end if;

    -- The corpus the query layer documents must actually be registered.
    if not exists (select 1 from aiq.lexical_sources where name = 'chunks')
       or not exists (select 1 from aiq.semantic_sources where name = 'chunks') then
        raise exception 'the "chunks" source is not registered -- TEXT/SEMANTIC/SEARCH have no corpus';
    end if;

    -- An artifact channel with an ingest_workflow would start an ingestion run
    -- every time a step offloaded its output -- an infinite-ish source of runs
    -- nobody asked for, and the kind of thing that is only ever noticed by the
    -- bill. Cheap to assert, impossible to spot by reading.
    if exists (select 1 from content.channels
               where name = 'workflow_artifacts' and config ? 'ingest_workflow') then
        raise exception
            'the workflow_artifacts channel has an ingest_workflow configured -- '
            'every artifact a step produces would start an ingestion run. Artifacts '
            'are step OUTPUT, not intake.';
    end if;

    raise notice 'world-model-ingestion self-check passed: files unexposed; chunks corpus registered; artifact channel inert';
end $$;

-- The PUBLIC default EXECUTE, revoked -- see workflow-engine/integration-rbac.sql
-- §6 for the enumeration. This one lives here because this is where the
-- function is defined: the engine owns the capability, content owns the
-- registration half, and a revoke can only be written where the signature
-- already exists.
revoke execute on function workflow.register_artifact(uuid, text, text, text, bigint, text, text, uuid) from public;
