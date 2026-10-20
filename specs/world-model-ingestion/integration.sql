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
on conflict (name) do update set source_table = excluded.source_table,
    shipped = excluded.shipped or semantic_sources.shipped;

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
    -- A LABEL IS NEVER AN IDENTITY (specs/identity/spec.md §5). `title` was
    -- first here, and a canonical key is UNIQUE -- so two documents that
    -- merely share a heading collided, and the second one FAILED TO INGEST
    -- with a duplicate-key error raised inside a projection trigger, naming
    -- neither document. Measured while loading this repository's own prose:
    -- two spec sections both headed "run it" stopped an ingest of 797.
    --
    -- `uri` first because it is what a person types to find a document and is
    -- unique in practice; `external_id` next because it is what a puller
    -- controls and guarantees. Title stays as the SUMMARY, which is what a
    -- label is for.
    --
    -- EXCEPT AN UPLOAD, whose uri is the CONTENT-ADDRESSED object path: the
    -- Content Server keys objects by checksum, so the same bytes uploaded twice
    -- into one org are two resources with one uri, and the second to reach
    -- `ready` died here on idx_node_keys_canonical -- the same failure the
    -- paragraph above records for titles, reached through dedup instead
    -- (scenarios/tour, re-uploading a runbook; dev/tests/content/01 §2). The
    -- object path is the FILE's identity, and a file is shared; nobody types
    -- it. A resource with a file is keyed by its own id.
    'case when n.file_id is not null then coalesce(n.external_id, n.id::text)
          else coalesce(n.uri, n.external_id, n.id::text) end',   -- canonical key
    'coalesce(n.title, n.uri)',                     -- summary
    'n.org_id',
    $$n.status = 'ready'$$,
    -- The resource's own scope (REM-962). The default reads the org alone, so
    -- a private memory with no org projected a `public` node: Leo could not
    -- read Maya's resource and could LOOKUP its title. And inside an org, a
    -- member's private document was every member's node.
    -- Read through to_jsonb, as the projection reads owner_id, because the
    -- column arrives with add_scope_columns() further down and that call writes
    -- to the table first: the trigger this regenerates fires on that write,
    -- with the column not there yet. Until it is, the old rule.
    p_visibility_expr => $$coalesce(to_jsonb(n)->>'visibility',
                                 case when rbac.is_shared_org(n.org_id) then 'public' else 'org' end)$$
);

-- `do update`, NOT `do nothing`, because these rows are the EXTENSION's
-- (REM-68). The schema is replayed on every upgrade, so `do nothing` means a
-- corrected value reaches fresh installs only and every existing database keeps
-- the old one forever -- silently, because dev/upgrade-converges.sh compares
-- OBJECTS and cannot see a row. Whose rows these are is not a judgement call:
-- specs/contract/schema.sql §4's `deployment_tables` is the list, and this
-- table is not on it. Tables that ARE on it -- rbac.role_permissions, roles --
-- keep `do nothing`, because a deployment may edit them and an update would
-- overwrite somebody's change on every upgrade.
--
-- Only the two rows named here are the extension's. A package or an application
-- that registers its own relation type is a different statement and is
-- untouched by this one, which is what makes `do update` safe on a table whose
-- rows have more than one author.
insert into aiq.relation_types (src_type, relation, dst_type, inverse_label, description) values
  ('document','derived_from','document','source_of','a document produced from another'),
  ('document','supersedes','document','superseded_by','a newer revision of the same thing')
on conflict (src_type, relation, dst_type) do update
    set inverse_label = excluded.inverse_label,
        description   = excluded.description;

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
-- Two calls per table and no policy written here: rbac.add_scope_policy()
-- generates the predicate from its one home, for the reason its header gives
-- (calling the equivalent function per row measured 58x slower, and sixteen
-- hand-copies of a security predicate is how one of them drifts).
--
-- What changes for this file specifically: the shared tier no longer means
-- "everyone may read it". §4b of schema.sql measured that conflation as a real
-- cross-tenant read -- register_upload() without its optional org argument
-- wrote a null org and another tenant retrieved the text. A row nobody scoped
-- is now `private`, and global is something somebody chose.
select rbac.add_scope_columns('content.channels', 'public');
select rbac.add_scope_policy ('content.channels');
select rbac.add_scope_columns('content.resources', 'public');

-- Re-projected where a document node's scope differs from its resource's,
-- which the registration change above leaves behind on an existing database:
-- its regenerated trigger projects the next write, not the rows already there.
-- On that drift, not on every replay (REM-962). After add_scope_columns,
-- because the projection reads the column it adds.
do $$
begin
    if exists (select 1 from aiq.nodes nd join content.resources n on n.id = nd.entity_id
                where nd.entity_type = 'document' and nd.visibility is distinct from n.visibility) then
        perform aiq.rebuild_entity_type('document');
    end if;
end $$;

-- ------------------------------------------------------------
-- A ROW NOBODY CAN EVER READ IS REFUSED HERE, because writing it has now been
-- a bug three times in three different files.
--
-- `visibility = 'private'` with no owner is not a narrow row; it is a dead
-- one. rbac.may_read(null, org, 'private') is NULL on every arm -- not public,
-- not the caller's, not an org scope -- so the row is invisible to every
-- caller including the one that wrote it, and the policy these two tables
-- carry is exactly those three arms and nothing else.
--
-- The three instances, all reported as the same sentence:
--
--   REM-75  content.register_fetched wrote it, and the poller's own next
--           select found nothing.
--   REM-74  the self-model's content.sql created its channel without it.
--   REM-83  percolate.apply_package, above, for a package-declared source.
--
-- Each was repaired at the call site, which is why there were three. By our
-- rule the third
-- occurrence buys a gate rather than a fourth repair, and by
-- challenge-the-process §9 the gate belongs at the lowest layer that can
-- refuse it -- which is the table.
--
-- NOT VALID, and that is the substance rather than a performance note. It
-- refuses every NEW row while leaving existing ones alone, so an upgrade of a
-- database that already carries dead rows does not fail -- and, more to the
-- point, nothing here has to decide what those rows should have been. Turning
-- a private row public is a disclosure, and a migration is the wrong place to
-- make one on somebody's behalf. The dead rows stay dead and visible to an
-- operator who goes looking; only the fourth instance is refused.
--
-- These two tables and not the other twelve that take add_scope_columns:
-- agentic.agents/plugins/skills/tool_servers, workflow.runs and
-- workflow.schedules each carry an extra `rbac.has_permission(...)` arm on
-- their read policy, so a private ownerless row there is reachable by an
-- administrator and is not dead. aiq.nodes, aiq.soft_nodes, aiq.lake_nodes,
-- content.datasets, agentic.runs and agentic.sessions have the three-arm
-- policy and DO have the same dead shape; they are not constrained here
-- because no instance has been observed on them and each wants its own look at
-- what writes it. Recorded on REM-83 rather than done silently.
--
-- Dropped before added: a CHECK has no IF NOT EXISTS, and build-sql.py's
-- idempotency check refuses the pair written the other way round.
alter table content.channels  drop constraint if exists channels_readable_by_somebody;
alter table content.channels  add  constraint channels_readable_by_somebody
    check (not (visibility = 'private' and owner_id is null)) not valid;
alter table content.resources drop constraint if exists resources_readable_by_somebody;
alter table content.resources add  constraint resources_readable_by_somebody
    check (not (visibility = 'private' and owner_id is null)) not valid;

-- AND NOW resolve_file, which needs the three columns the line above adds.
-- Its home is here for that reason; schema.sql carries the pointer.
--
-- `checksum` is appended LAST. It is there so workflow.v_artifacts can take its
-- file columns from here instead of reading content.files, which no end-user
-- role may be granted (§ below); callers that select by name, like
-- percolate-core's content server, are unaffected.
--
-- NO DROP IN FRONT OF IT, although a changed return type cannot be `create or
-- replace`d. The drop that reshaped it lives in specs/migrations/0.1.6--0.2.0.sql,
-- which only a database older than 0.2.0 runs. Here it was replayed onto 0.2.0
-- by the first bump past it, where v_artifacts depends on this function, and the
-- upgrade stopped. A future reshape goes in the migration for its own hop.
create or replace function content.resolve_file(p_resource_id uuid)
returns table(bucket text, object_key text, content_type text, size_bytes bigint,
              checksum text) as $$
    -- may_read, NOT may_access_org. The org rule answers "may this person
    -- touch this tenant"; it says nothing about the ROW, so a resource marked
    -- `private` was served to anybody who could reach its org -- and on the
    -- shared tier that is everybody. `rbac.may_read(owner, org, visibility)`
    -- is the single home of the read rule and content.resources carries all
    -- three columns, so this is the same decision the `_scoped` policy on the
    -- table already makes; resolve_file was the one path that did not ask it.
    --
    -- Found by the self-model: content.resources is central (16 dependants),
    -- has broken twice, and this is the gap the graph pointed at.
    select f.bucket, f.object_key, f.content_type, f.size_bytes, f.checksum
    from content.resources r
    join content.files f on f.id = r.file_id
    where r.id = p_resource_id
      and rbac.may_read(r.owner_id, r.org_id, r.visibility);
$$ language sql stable security definer set search_path = pg_catalog, public;

-- AND chunks_to_embed / windows_to_index, for resolve_file's reason: they ask
-- rbac.may_read of owner_id and visibility, which the add_scope_columns line
-- above adds, and as LANGUAGE SQL their bodies are checked when created.
-- Moved from schema.sql rather than duplicated.
--
-- The row set an `embed:` matrix fans out over.
--
-- This function is named in workflow-engine/YAML.md §matrix as the example of
-- per-row embedding -- `rows: {function: chunks_to_embed, args: [...]}` -- and
-- it did not exist. The documented pipeline could not have run.
--
-- It returns only what the embed call needs (id and text), because every row
-- is copied verbatim onto the child task it produces: a column added here is
-- a column stored N times.
--
-- SECURITY DEFINER WITH ITS OWN CHECK, and it got here the hard way. It was
-- SECURITY INVOKER while its only caller was matrix expansion, which runs
-- inside the engine's own definer context and therefore reads as the schema
-- owner. The moment the batching embed step began calling it from the WORKER
-- -- which holds no table grants at all, by design -- every call failed with
-- "permission denied for table resource_chunks", five times per resource.
--
-- So it is definer, and because it is also granted to `authenticated` it does
-- its own authorization rather than relying on the grant: a definer function
-- that returned any resource's chunks to anyone holding its id would hand a
-- tenant's corpus to whoever guessed a uuid. The predicate is the one
-- rbac.may_read states for the row -- the read rule, whose single home it is,
-- as content.resolve_file asks it. It was may_access_org, the ORG's rule,
-- until 2026-09-11, which let a co-member or anyone on the shared tier read a
-- private resource. A claimless connection (a worker, a migration) is exempt
-- exactly as it is everywhere else in this schema.
--
-- It returns only what an embed call needs, id and text, because in the
-- fan-out shape every row is copied verbatim onto the child task it produces:
-- a column added here is a column stored N times.
create or replace function content.chunks_to_embed(p_resource_id uuid)
returns jsonb as $$
    select coalesce(jsonb_agg(jsonb_build_object('chunk_id', c.id, 'content', c.content)
                              order by c.ordinal), '[]'::jsonb)
    from content.resource_chunks c
    where c.resource_id = p_resource_id
      -- The ROW's read rule, as content.resolve_file asks it -- not
      -- may_access_org, which let anyone in the org, and on the shared tier
      -- anyone at all, read a private resource's text by naming it. The
      -- claimless arm is the worker's embed fan-out, which carries no person.
      and exists (select 1 from content.resources r
                  where r.id = p_resource_id
                    and (rbac.is_operator()
                         or rbac.may_read(r.owner_id, r.org_id, r.visibility)));
$$ language sql stable security definer set search_path = pg_catalog, public;

-- The row set the GRAPH indexer fans out over.
--
-- Named `windows_to_index` because that is what graph-index.md §6.2 calls it,
-- and like chunks_to_embed it is a function the design used as an example and
-- nobody had written. A window is a chunk here: the chunker already split the
-- document on the most semantically significant boundary that fits a budget,
-- and cutting it a second way for the extractor would mean two answers to
-- "which span produced this" for the same document.
--
-- It carries THREE fields where chunks_to_embed carries two, and the extra two
-- are what aiq.land_graph_fanout reads off each child to attribute a landed
-- graph -- `resource_id` and `window_ordinal` -- so a node can be traced back
-- to the passage that named it. Same reason the embed rows are minimal: every
-- row is copied verbatim onto the child task it creates.
create or replace function content.windows_to_index(p_resource_id uuid)
returns jsonb as $$
    select coalesce(jsonb_agg(jsonb_build_object(
               'resource_id',    c.resource_id,
               'window_ordinal', c.ordinal,
               'content',        c.content) order by c.ordinal), '[]'::jsonb)
    from content.resource_chunks c
    where c.resource_id = p_resource_id
      -- The row's read rule, the same as chunks_to_embed above and for the
      -- same reason.
      and exists (select 1 from content.resources r
                  where r.id = p_resource_id
                    and (rbac.is_operator()
                         or rbac.may_read(r.owner_id, r.org_id, r.visibility)));
$$ language sql stable security definer set search_path = pg_catalog, public;

select rbac.add_scope_policy ('content.resources');

alter table content.resource_chunks enable row level security;

drop policy if exists chunks_via_resource on content.resource_chunks;
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
-- An owner deletes their own memory (REM-964): the delete policy add_scope_policy()
-- generates admits only owner_id = the caller. Chunks follow by foreign key,
-- vectors by trg_forget_vectors, graph facts by trg_forget_deleted_sources.
grant delete on content.resources to authenticated;

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
revoke execute on function content.register_upload(text,text,text,text,bigint,text,text,text,uuid,jsonb,text,text,text) from public;
revoke execute on function content.register_fetched(text,text,text,text,uuid,jsonb) from public;
revoke execute on function content.register_text(text,text,jsonb,text,text,uuid,jsonb,text) from public;
revoke execute on function content.record_chunks(uuid,jsonb) from public;
revoke execute on function content.resolve_file(uuid) from public;
revoke execute on function content.check_drift() from public;
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
grant execute on function content.register_upload(text,text,text,text,bigint,text,text,text,uuid,jsonb,text,text,text) to authenticated;
grant execute on function content.register_fetched(text,text,text,text,uuid,jsonb) to authenticated;
-- register_text to `authenticated` and not to `worker`: it is a WRITER's call,
-- made when an application publishes text it owns, and it writes as the caller
-- through may_write. A worker embeds what is already registered.
grant execute on function content.register_text(text,text,jsonb,text,text,uuid,jsonb,text) to authenticated;
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
-- 5a. An ingest run that fails leaves its resource 'failed', not 'pending'.
--
-- schema.sql §3 gives a resource that failed to parse the status 'failed', so
-- that it is visible rather than missing. Nothing wrote it. The status moves
-- to 'ready' or 'stored' inside record_ingest(), which only a parse that
-- succeeded calls; a parse that raised never got there, and the resource
-- stayed 'pending' after its run had ended. Found on 0.1.6, and reproduced on
-- 0.2.0 with two uploads naming one uri: the second parse failed terminally on
-- idx_node_keys_canonical, its run went to 'failed', and the resource read
-- 'pending' from then on -- which check_drift() reports an hour later as a
-- workflow that never finished, about a workflow that had.
--
-- The run is where the failure is recorded, so this is a trigger on
-- workflow.runs. It recognises an ingest run by the two facts
-- register_upload() writes onto it together: external_id is
-- 'ingest:' || resource_id, and the input carries that resource_id. A run
-- started any other way does not carry both, and is left alone.
--
-- ONLY 'pending' MOVES. A run can fail after its parse succeeded -- the embed
-- or graph branch failing on a missing key -- and that resource already has
-- chunks TEXT can search. Its status says whether it is retrievable, and it
-- is; the failure stays on the run, next to the step that failed. A cancelled
-- run leaves its resource as unchunked as a failed one does, so it is treated
-- the same way.
--
-- SECURITY DEFINER because a run's status is written by whichever path ended
-- it -- the worker's fail_task(), a user's cancel_run(), a matrix gate -- and
-- the resource has to be updated whichever one it was.
create or replace function content.fail_resource_of_ingest_run()
returns trigger as $$
begin
    if new.external_id = 'ingest:' || (new.input->>'resource_id')
       and pg_input_is_valid(new.input->>'resource_id', 'uuid') then
        update content.resources
           set status = 'failed', updated_at = now()
         where id = (new.input->>'resource_id')::uuid
           and status = 'pending';
    end if;
    return null;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

revoke execute on function content.fail_resource_of_ingest_run() from public;

create or replace trigger trg_ingest_run_fails_resource
    after update of status on workflow.runs
    for each row
    -- Finished without succeeding, asked of the vocabulary rather than spelled
    -- out here: a state added to workflow.lifecycle_states reaches this trigger
    -- without anybody remembering this file (REM-52).
    when (old.status = 'running'
          and workflow.is_terminal(new.status) and not workflow.is_success(new.status)
          and new.external_id like 'ingest:%')
    execute function content.fail_resource_of_ingest_run();

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
-- `public`, explicitly, and it is the channel ROW that is public rather than
-- anything written through it. Omitted, the column defaults to `private`, and
-- a private channel owned by nobody in the shared org is readable by nobody:
-- rbac.may_read(null, shared_org, 'private') returns NULL, the lookup in
-- register_upload filters the row out, and the caller is told "no channel
-- named workflow_artifacts for this org" -- a message about the org, for a
-- channel that is right there. Every artifact write failed that way.
--
-- The other global channel, sample-corpus, is public for the same reason. What
-- a step writes THROUGH this channel still takes its own visibility from
-- rbac.default_visibility(p_org_id), so nothing here publishes an artifact.
insert into content.channels (name, kind, config, visibility)
select 'workflow_artifacts', 'file_upload',
       -- No ingest_workflow: registering an artifact must not start an
       -- ingestion run. That key is what makes an upload chunk itself, and a
       -- rendered PDF that a step just produced is output, not intake. A
       -- channel with none configured registers content and starts nothing,
       -- which content.register_upload documents as a legitimate choice.
       '{"description": "bytes produced by a workflow step, refd from tasks.output"}'::jsonb,
       'public'
where not exists (
    select 1 from content.channels
     where name = 'workflow_artifacts' and org_id = rbac.shared_org_id());

-- MARKED BY ITS OWN STATEMENT. The insert above is guarded by `where not
-- exists`, so it does nothing on a replay -- and on an upgraded database the
-- seed would keep the `false` its column was added with, be carried into the
-- dump, and collide with the copy `CREATE EXTENSION` re-seeds on restore. The
-- five tables seeded through shared register functions get this from their
-- `on conflict do update`; the two global channels are the seeds with no
-- conflict clause to hang it on.
-- AND IT REPAIRS THE ROW, because on an upgraded database it cannot mark
-- it without doing so. Measured on 0.1.6 -> 0.2.0: both global channels
-- are there as `private` with no owner and no org. `not (visibility =
-- 'private' and owner_id is null)` was added NOT VALID, so those rows
-- survived unchecked -- and any UPDATE to one revalidates it, which is how
-- marking `shipped` found them.
--
-- They are not merely invalid, they are DEAD: rbac.may_read(null,
-- shared_org, 'private') is NULL, so the channel lookup drops the row and
-- POST /files answers "no channel named uploads for this org" -- REM-83's
-- failure, still shipping on every database upgraded rather than
-- installed. A fresh 0.2.0 seeds these public; converging the upgraded one
-- onto that is what dev/upgrade-converges.sh asks for anyway.
--
-- Visibility only. owner_id stays null because these channels have no
-- owner by design -- they are everybody's -- and `public` is what makes
-- that legible to the read path instead of unreachable.
update content.channels
   set shipped = true, visibility = 'public'
 where name = 'workflow_artifacts' and org_id = rbac.shared_org_id()
   and (not shipped or visibility is distinct from 'public');

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
--
-- DROPPED AND RECREATED, owned by api_viewer. It was owned by app_owner, the
-- owner of workflow.tasks and content.resources, so it bypassed both tables'
-- policies and joined every tenant's runs to every tenant's files for any
-- signed-in reader. Owned by api_viewer the policies apply; and the file
-- columns now come from content.resolve_file(), because api_viewer may not
-- read content.files (the invariant below) and resolve_file is the scoped
-- door to it. Its 0.2.0 reshape needed a drop, which lives in
-- specs/migrations/0.1.6--0.2.0.sql beside resolve_file's for the same reason:
-- replayed here, it would drop the view and its grants on every upgrade.
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
left join lateral content.resolve_file(r.id) f on true;

-- WORKER ONLY. It was granted to `authenticated` too, and it takes any task id
-- and asks nothing about whose run that task is in: the resource it registers
-- is keyed by (channel, task id), register_upload's conflict path hands back
-- the EXISTING resource, and the update below repoints that resource at the
-- caller's file. So a signed-in person who named another tenant's task could
-- replace that task's artifact with bytes of their own, and copy its run,
-- trace and step into their own row besides. Its one caller is the worker
-- (percolate-core worker/artifacts.py), which connects as `worker`; for a
-- worker-facing function the grant IS the authorization (integration-rbac.sql
-- in the engine), and the grant said otherwise
-- (REM-46).
grant execute on function workflow.register_artifact(uuid,text,text,text,bigint,text,text,uuid)
    to worker;
revoke execute on function workflow.register_artifact(uuid,text,text,text,bigint,text,text,uuid)
    from authenticated;
grant execute on function workflow.artifact(uuid) to worker, authenticated;
-- OWNED BY api_viewer (specs/README.md, "What it takes, concretely"); the
-- view's header says why. It reads tasks and resources, resolves the rest
-- through two functions, and needs exactly those.
grant select on workflow.tasks, content.resources to api_viewer;
grant execute on function workflow.artifact_ref(jsonb), content.resolve_file(uuid)
    to api_viewer;
grant create on schema workflow to api_viewer;
alter view workflow.v_artifacts owner to api_viewer;
revoke create on schema workflow from api_viewer;
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
-- The COLUMNS are added in schema.sql, next to content.dataset_uri() -- a
-- `language sql` body is validated at CREATE time and that one reads them, so
-- they cannot wait until this file. Only the policy is here.
select rbac.add_scope_policy ('content.datasets');
alter table content.dataset_files enable row level security;

drop policy if exists dataset_files_via_dataset on content.dataset_files;
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

-- ------------------------------------------------------------
-- THE QUERY LOG: one stored row per query a caller ran, so the query layer can
-- be measured on its own traffic (percolate-core semantic_exceptions/log.py).
--
-- A query tool records what it was asked and what came back -- the p8ql string,
-- the caller's question, the plan, result statistics and row ids, the semantic
-- exceptions computed and which of them the caller was shown -- and the next
-- query in the same run is that query's outcome. The shape is declared as
-- percolate.types `content.query_event`; this file stores it, and checks only
-- what storing needs.
--
-- ROWS, NOT SCHEMA (specs/packages/rows-not-schema.md): a query event is a
-- content.resources row on a shipped channel, `stored` because there is nothing
-- to chunk, with the event as its metadata. `stored` and not `pending`, which
-- is what register_fetched would leave and check_drift would report forever,
-- and not `ready`, which integration.sql projects into the graph: these are
-- machine-generated data-plane rows, which graph-identity.md's inclusion policy
-- keeps out of aiq.nodes.
--
-- THE RECORD IS KEPT APART FROM WHAT IT DESCRIBES. A query event says what a
-- caller asked and saw; it changes no fact, no edge and no weight. Whatever
-- later learns from the log (a path that answered stored as a link, a much-used
-- question promoted) is its own write with its own provenance, so it can be
-- inspected, replayed or undone without touching this record.
-- ------------------------------------------------------------
insert into content.channels (name, kind, config, visibility)
select 'query_log', 'manual',
       jsonb_build_object('description',
           'one stored row per query run through the query layer, private to the caller (content.record_query)'),
       'public'
where not exists (select 1 from content.channels
                   where name = 'query_log' and org_id = rbac.shared_org_id());
update content.channels
   set shipped = true, visibility = 'public'
 where name = 'query_log' and org_id = rbac.shared_org_id()
   and (not shipped or visibility is distinct from 'public');

-- RECORD ONE QUERY AS THE PERSON WHO RAN IT. Owner: the caller must be signed
-- in, and the row is theirs and private, in the shared org, so nobody else
-- reads their queries and no org permission is asked or needed -- it records
-- the caller's own act and grants nothing. The event's `id` is the external id,
-- so a retried write is the same row (on conflict do nothing) and the first
-- record of an event stands. 64 KB is far above any event the query tool
-- writes (row ids are capped at 50) and keeps one caller from storing documents
-- here under the name of a query.
create or replace function content.record_query(p_event jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_user    uuid := rbac.current_user_id();
    v_channel uuid;
    v_res     uuid;
begin
    if v_user is null then
        raise insufficient_privilege using message = 'Only a signed-in caller can record a query';
    end if;
    if jsonb_typeof(p_event) is distinct from 'object'
       or coalesce(p_event->>'id', '') = '' or coalesce(p_event->>'query', '') = '' then
        raise invalid_parameter_value
            using message = 'A query event is an object with an id and the query it records';
    end if;
    if octet_length(p_event::text) > 65536 then
        raise check_violation using message = 'A query event is at most 64 KB';
    end if;
    select id into v_channel from content.channels
     where name = 'query_log' and org_id = rbac.shared_org_id();
    if v_channel is null then
        raise no_data_found using message = 'The query_log channel is missing from this installation';
    end if;
    insert into content.resources (channel_id, external_id, title, status, org_id, owner_id,
                                   visibility, metadata)
    values (v_channel, v_user::text || ':' || (p_event->>'id'),
            left(coalesce(nullif(p_event->>'question', ''), p_event->>'query'), 200),
            'stored', rbac.shared_org_id(), v_user, 'private', p_event)
    on conflict (channel_id, external_id) do nothing
    returning id into v_res;
    if v_res is null then
        select id into v_res from content.resources
         where channel_id = v_channel and external_id = v_user::text || ':' || (p_event->>'id');
    end if;
    return v_res;
end;
$$;
revoke execute on function content.record_query(jsonb) from public;
grant execute on function content.record_query(jsonb) to authenticated;
