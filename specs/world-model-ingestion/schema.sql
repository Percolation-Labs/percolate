-- ============================================================
-- World Model Ingestion — schema v0.1
--
-- The content plane: where bytes come from, where they are registered, and
-- what gets chunked for retrieval. Implements brief.md §2-§3.
--
-- This closes a real coherence hole rather than adding a feature.
-- ai-query-layer/USAGE.md instructs a reader to run
--   select aiq.register_lexical_source('chunks', 'wm.resource_chunks');
-- and no such table shipped -- `wm` was a throwaway test fixture. TEXT,
-- SEMANTIC and SEARCH are documented as working over "chunks", so the corpus
-- they search has to be something the collection actually installs.
--
-- Applied as app_owner, after ai-query-layer. The aiq/rbac wiring lives in
-- integration.sql, same boundary discipline as everywhere else in this
-- collection: this file alone is a content store with no query layer and no
-- identity system.
-- ============================================================

create schema if not exists content;

-- ------------------------------------------------------------
-- 1. Channels — where content comes from.
--
-- Made a first-class table rather than a string column on `resource`
-- (brief.md §2): a Telegram channel is a row exactly as an SEC EDGAR feed is,
-- so adding a source kind is an insert plus a handler, not a schema change.
--
-- `kind` distinguishes who initiates, which is the only thing that actually
-- differs between them -- a push arrives as an upload, a pull is polled.
-- ------------------------------------------------------------
create table content.channels (
    id            uuid primary key default gen_random_uuid(),
    name          text not null,
    kind          text not null check (kind in
                      ('file_upload','http_pull','ftp_pull','feed','telegram','manual')),
    -- Provider-specific: url, auth reference, cursor field, parser hints.
    -- Deliberately jsonb: every provider needs different things, and a column
    -- per provider is how this table becomes unmaintainable.
    config        jsonb not null default '{}'::jsonb,
    -- Poll cadence for pull kinds. Null = not polled (upload/manual).
    poll_interval interval,
    last_polled_at timestamptz,
    org_id        uuid,
    enabled       boolean not null default true,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    unique (org_id, name)
);
create index idx_channels_pollable on content.channels (last_polled_at)
    where enabled and poll_interval is not null;

create trigger trg_channels_touch before update on content.channels
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 2. Files — the Postgres-side pointer. NEVER the bytes.
--
-- Keyed by content hash, so the same PDF uploaded twice is one object
-- (brief.md §3). That dedup is exactly why this table has NO org_id: one row
-- can legitimately be referenced by resources belonging to different tenants,
-- so there is no single owner and any owner-scoped RLS policy on it would be
-- meaningless. Tenancy lives on `resources`, which is single-owner.
--
-- Consequently this table is never exposed through PostgREST -- reads go
-- through a resource, which is scoped. See integration.sql.
-- ------------------------------------------------------------
create table content.files (
    id           uuid primary key default gen_random_uuid(),
    checksum     text not null unique,      -- sha256 of the content; the dedup key
    bucket       text not null,
    object_key   text not null,
    size_bytes   bigint not null check (size_bytes >= 0),
    content_type text,
    created_at   timestamptz not null default now(),
    unique (bucket, object_key)
);

-- ------------------------------------------------------------
-- 3. Resources — the unit of ingested content.
--
-- A resource is one thing that entered the system: an uploaded document, a
-- fetched page, a Telegram post. It points at a channel (where it came from)
-- and optionally a file (if it has bytes -- a scraped JSON record may not).
-- ------------------------------------------------------------
create table content.resources (
    id           uuid primary key default gen_random_uuid(),
    channel_id   uuid not null references content.channels(id),
    file_id      uuid references content.files(id),
    -- Provider's own identifier, used to avoid re-ingesting the same item on
    -- the next poll. Unique per channel, not globally: two feeds may both
    -- number their items from 1.
    external_id  text,
    uri          text,
    title        text,
    -- 'pending' until the ingestion workflow has chunked it; 'ready' once
    -- retrievable. A resource that failed to parse stays 'failed' and is
    -- visible rather than silently absent.
    -- 'stored' is the fourth state and it is not a stage on the way to
    -- 'ready': it means "bytes registered, and there is nothing to chunk".
    -- A workflow artifact -- a rendered report, an offloaded response --
    -- is retrievable the moment it lands and is not corpus. Giving it its
    -- own status rather than reusing 'ready' closes two collisions by
    -- construction rather than by adding a predicate to each:
    --   * check_drift() below reports pending-too-long and ready-with-no-
    --     chunks. An artifact is legitimately neither, and under 'ready'
    --     every artifact ever produced would be permanent drift noise.
    --   * integration.sql registers resources as graph 'document' nodes
    --     where status = 'ready'. Machine-generated step output is exactly
    --     the data-plane volume graph-identity.md's inclusion policy keeps
    --     out of the node registry -- the same argument that excludes chunks.
    status       text not null default 'pending'
                     check (status in ('pending','ready','stored','failed','superseded')),
    metadata     jsonb not null default '{}'::jsonb,
    org_id       uuid,
    ingested_at  timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    unique (channel_id, external_id)
);
create index idx_resources_channel on content.resources (channel_id, ingested_at desc);
create index idx_resources_org on content.resources (org_id);
-- Partial on the states worth hunting for. 'stored' joins 'ready' in the
-- exclusion: both are terminal and neither is something an operator goes
-- looking for, so admitting artifacts here would grow the index without
-- making it answer anything.
--
-- Written as drop-then-create (and the check as drop-then-add) so an
-- installation that already exists picks both up: `create table` is skipped
-- when the table is there, which silently leaves the old constraint and the
-- old index in place. The workflow engine learned this the hard way with
-- tasks_kind_check.
alter table content.resources drop constraint if exists resources_status_check;
alter table content.resources add constraint resources_status_check
    check (status in ('pending','ready','stored','failed','superseded'));
drop index if exists content.idx_resources_status;
create index idx_resources_status on content.resources (status)
    where status not in ('ready','stored');

create trigger trg_resources_touch before update on content.resources
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 4. Chunks — the data plane, and what retrieval actually searches.
--
-- High volume by design. Per graph-identity.md's inclusion policy these are
-- explicitly NOT graph nodes: they are machine-generated rows that join in
-- after identity is known, never entries in the node registry. The semantic
-- path reaches them through a relational join from a resource, which is what
-- keeps the node/key tables small enough for the O(log n) lookup claim to hold.
--
-- Embeddings live in aiq.emb_<model>, keyed by chunk_id -- one table per
-- MODEL, not per dimension (ai-query-layer/schema.sql §10). No FK is possible
-- in that direction because the embedding table is generic and does not know
-- this schema; integration.sql adds the reconciliation instead.
-- ------------------------------------------------------------
create table content.resource_chunks (
    id           uuid primary key default gen_random_uuid(),
    resource_id  uuid not null references content.resources(id) on delete cascade,
    ordinal      int not null,
    content      text not null,
    -- Byte offsets into the source, so a citation can point at a span rather
    -- than just a chunk -- agentic/brief.md §5.3's citations carry chunk_id,
    -- and a reader following one wants to find it in the original.
    start_offset int,
    end_offset   int,
    token_count  int,
    metadata     jsonb not null default '{}'::jsonb,
    created_at   timestamptz not null default now(),
    unique (resource_id, ordinal)
);
create index idx_chunks_resource on content.resource_chunks (resource_id, ordinal);

-- ------------------------------------------------------------
-- 5. Registration — upload and fetch, as functions.
--
-- The Content Server calls these; it holds no table grants of its own, same
-- as any worker. Writing the rows is a transaction, so a half-registered
-- upload (object stored, no resource row) cannot happen through this path.
-- ------------------------------------------------------------
-- 4a. The authorization check these writers did not have.
--
-- workflow-engine/integration-rbac.sql states the rule for this whole
-- collection, in those words: "SECURITY DEFINER deliberately bypasses RLS, so
-- every SECURITY DEFINER function reachable by an end user MUST do its own
-- authorization check. Worker-facing functions are exempt because EXECUTE on
-- them is granted only to `worker`, which is infrastructure, not a user
-- identity -- their authorization IS the grant."
--
-- The three writers below are SECURITY DEFINER, granted to `authenticated`,
-- and had no check of any kind. Measured, as an ordinary logged-in user of one
-- org holding nothing but another org's resource uuid:
--
--     org B can SEE org A's resource: false
--     org B REWROTE org A's chunks
--     org B PLANTED a resource in org A's channel
--
-- record_chunks() DELETEs every chunk of the resource it is handed and inserts
-- what it is given, so that is destruction and content injection in one call,
-- into the corpus SEMANTIC and SEARCH read. An agent asking its own tenant's
-- documents a question would retrieve the attacker's text and act on it. The
-- read path was scoped correctly the whole time -- resolve_file() carries the
-- org predicate and the RLS on resources works -- which is what made it look
-- fine: every test asked what a tenant could READ.
--
-- The org comes from the CALLER for a user and from the ARGUMENT for
-- infrastructure, which is the same split rbac's issue_refresh_token bug
-- produced: a caller-supplied "who is this" argument is exactly as spoofable
-- as any other, unless the role supplying it is the deployment rather than a
-- person.
-- ------------------------------------------------------------
-- ONE PREDICATE, used by the read path and the write path.
--
-- It exists as a boolean because three callers want three different things
-- from it: register_* wants an error naming the org, record_chunks wants one
-- answer for "not yours" and "no such thing", and resolve_file wants no rows.
--
-- Sharing it also settles an asymmetry that was worse than either half. The
-- read predicate was written inline in resolve_file() and had no exemption for
-- a claimless connection, while the write check needed one -- so a service
-- connection could WRITE an org's content and not READ it, and the worker that
-- ingests a document could record its chunks but not resolve the file it was
-- meant to chunk. Whichever answer is right, it cannot be two answers.
create or replace function content.may_access_org(p_org_id uuid)
returns boolean as $$
    -- IDENTITY COMES FROM THE VERIFIED TOKEN, NOT FROM THE ROLE, and the first
    -- version of this check got that wrong in the most instructive way: it
    -- asked `pg_has_role(current_user, 'worker', ...)`, and inside a SECURITY
    -- DEFINER function current_user is the DEFINER. Every caller looked like
    -- app_owner, so the check exempted everyone and the probe that found the
    -- hole walked straight through the fix. session_user is no better -- every
    -- PostgREST request shares one login role, `authenticator`.
    --
    -- So the signal is the one aiq.current_org_ids() itself documents: an org
    -- claim rides in the request-scoped GUC PostgREST sets from a verified JWT.
    -- No claims at all means no request identity -- a service connection, a
    -- migration, psql -- which is the same exemption workflow's worker-facing
    -- functions get from their grant being the authorization.
    --
    -- A null org is the single-tenant case and the fixture case: it is readable
    -- by everyone under resources_org_scoped, so writing it is not a
    -- cross-tenant act.
    select nullif(current_setting('request.jwt.claims', true), '') is null
        or p_org_id is null
        or p_org_id in (select aiq.current_org_ids());
$$ language sql stable security definer set search_path = pg_catalog, public;

create or replace function content.assert_org_write(p_org_id uuid, p_what text)
returns void as $$
begin
    if not content.may_access_org(p_org_id) then
        raise exception 'not authorized to % for that organization', p_what;
    end if;
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

grant execute on function content.may_access_org(uuid) to authenticated, worker;

grant execute on function content.assert_org_write(uuid, text) to authenticated, worker;

-- ------------------------------------------------------------

-- Register an uploaded object. Returns the resource id.
--
-- Content-hash dedup is handled here rather than by the caller: the second
-- upload of identical bytes reuses the existing content.files row.
--
-- DEDUP IS AT THE FILE LEVEL ONLY, and the distinction matters. Two tenants
-- uploading the same public PDF get ONE object and TWO resources -- they each
-- uploaded a thing, with their own title, org and lifecycle, that happens to
-- share bytes. An earlier version used the checksum as the resource's
-- external_id, which collapsed them into one resource and quietly gave the
-- second uploader the first one's row; caught by uploading the same file twice
-- and counting. p_external_id is now the caller's own idea of identity, used
-- by pullers to avoid re-ingesting; an upload normally leaves it null and gets
-- a new resource every time.
create or replace function content.register_upload(
    p_channel     text,
    p_checksum    text,
    p_bucket      text,
    p_object_key  text,
    p_size_bytes  bigint,
    p_content_type text default null,
    p_title       text default null,
    p_uri         text default null,
    p_org_id      uuid default null,
    p_metadata    jsonb default '{}'::jsonb,
    p_external_id text default null,
    p_trace_id    text default null
) returns uuid as $$
declare
    v_channel  uuid;
    v_file     uuid;
    v_res      uuid;
    v_workflow text;
    v_run      uuid;
begin
    perform content.assert_org_write(p_org_id, 'register content');

    -- ORDER BY, because (org_id, name) is unique but this predicate matches
    -- TWO rows when a public channel and an org channel share a name -- and
    -- `select into` with no order takes whichever the plan produced. The
    -- org-specific channel wins; the public one is the fallback it was meant
    -- to be.
    select id into v_channel from content.channels
    where name = p_channel and (org_id is not distinct from p_org_id or org_id is null)
    order by (org_id is not distinct from p_org_id) desc
    limit 1;
    if v_channel is null then
        raise exception 'no channel named % for this org -- create one first', p_channel;
    end if;

    -- The dedup. ON CONFLICT on checksum, so concurrent uploads of the same
    -- bytes converge on one row rather than racing.
    insert into content.files (checksum, bucket, object_key, size_bytes, content_type)
    values (p_checksum, p_bucket, p_object_key, p_size_bytes, p_content_type)
    on conflict (checksum) do update set checksum = excluded.checksum
    returning id into v_file;

    insert into content.resources (channel_id, file_id, uri, title, org_id, metadata, external_id)
    values (v_channel, v_file, p_uri, p_title, p_org_id, p_metadata, p_external_id)
    on conflict (channel_id, external_id) do update set updated_at = now()
    returning id into v_res;

    -- START THE INGESTION WORKFLOW. This is the point of the whole function
    -- (brief.md §3.5 names it the primary use case): upload -> registered ->
    -- queryable is meant to be one flow, not three manually-wired steps. It
    -- fires here, in the same transaction as the rows, so a committed resource
    -- always has a run and a rolled-back upload leaves neither.
    --
    -- The workflow name comes from the CHANNEL, so different sources can chunk
    -- differently without this function knowing how any of them work. A channel
    -- with no ingest_workflow configured registers content and starts nothing,
    -- which is a legitimate choice rather than an error.
    select config->>'ingest_workflow' into v_workflow
    from content.channels where id = v_channel;

    if v_workflow is not null then
        -- p_trace_id propagates the caller's trace when the Content Server has
        -- one (specs/README.md's OTel ground rule), so an upload and everything
        -- it causes share one trace rather than three disconnected ones.
        v_run := workflow.start_workflow(
            v_workflow,
            jsonb_build_object('resource_id', v_res, 'file_id', v_file,
                               'org_id', p_org_id),
            'ingest:' || v_res::text,
            p_trace_id);
    end if;

    return v_res;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Register a fetched item that has no bytes of its own (a JSON record from a
-- feed, say). Same shape, no file.
create or replace function content.register_fetched(
    p_channel     text,
    p_external_id text,
    p_title       text default null,
    p_uri         text default null,
    p_org_id      uuid default null,
    p_metadata    jsonb default '{}'::jsonb
) returns uuid as $$
declare v_channel uuid; v_res uuid;
begin
    perform content.assert_org_write(p_org_id, 'register content');

    select id into v_channel from content.channels
    where name = p_channel and (org_id is not distinct from p_org_id or org_id is null)
    order by (org_id is not distinct from p_org_id) desc
    limit 1;
    if v_channel is null then
        raise exception 'no channel named % for this org', p_channel;
    end if;

    insert into content.resources (channel_id, external_id, uri, title, org_id, metadata)
    values (v_channel, p_external_id, p_uri, p_title, p_org_id, p_metadata)
    on conflict (channel_id, external_id) do nothing
    returning id into v_res;

    -- Null means "already ingested on a previous poll" -- not an error. A
    -- puller that treats it as one re-processes its whole backlog every cycle.
    return v_res;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Fetch: resolve a resource to its storage location. The Content Server
-- proxies the bytes (brief.md §3.5 -- proxied reads, not presigned URLs, for
-- one authorization path), so it needs the location and nothing else.
--
-- SECURITY DEFINER with an EXPLICIT visibility check, and the combination is
-- forced rather than chosen. This has to read content.files, which is granted
-- to nobody -- deduped by content hash, so it has no single owner and any
-- owner-scoped policy on it would be meaningless. A SECURITY INVOKER version
-- therefore cannot succeed for anyone; it failed with "permission denied for
-- table resources" the first time a containerized Content Server called it.
--
-- So authorization is done here instead of by RLS: the caller must be able to
-- see the RESOURCE, checked against exactly the predicate resources' own
-- policy uses. That keeps one rule in two places, which is a cost -- but the
-- alternative is exposing storage keys through a table that cannot be scoped.
--
-- Returns nothing when the caller may not see it, rather than raising:
-- distinguishing "not yours" from "does not exist" tells an unauthorized
-- caller that the resource exists.
create or replace function content.resolve_file(p_resource_id uuid)
returns table(bucket text, object_key text, content_type text, size_bytes bigint) as $$
    select f.bucket, f.object_key, f.content_type, f.size_bytes
    from content.resources r
    join content.files f on f.id = r.file_id
    where r.id = p_resource_id
      and content.may_access_org(r.org_id);
$$ language sql stable security definer set search_path = pg_catalog, public;

-- Record chunks produced by the ingestion workflow, and flip the resource
-- ready. One call rather than N inserts plus an update, so a resource is never
-- observably half-chunked.
create or replace function content.record_chunks(p_resource_id uuid, p_chunks jsonb)
returns int as $$
declare
    v_count int;
    v_org   uuid;
begin
    -- The org is READ OFF THE RESOURCE, never taken as an argument: this
    -- function's only parameter that identifies a tenant is the resource id,
    -- and a resource id is a bearer token for nothing.
    --
    -- ONE MESSAGE for "no such resource" and "not yours", because a caller who
    -- may not have it must not learn whether it exists -- the rule
    -- resolve_file() states and follows by returning no rows. `not found` is
    -- the plpgsql variable and not a local flag: `select ... , true into v_org,
    -- v_found` leaves v_found NULL on no rows, `if not NULL` is false, and the
    -- first version of this check fell straight through it into a foreign-key
    -- error that named the missing row.
    select r.org_id into v_org from content.resources r where r.id = p_resource_id;
    if not found or not content.may_access_org(v_org) then
        raise exception 'no such resource, or it is not yours';
    end if;

    delete from content.resource_chunks where resource_id = p_resource_id;

    -- start_offset/end_offset are read from the chunk when the chunker
    -- produced them and left null when it did not. The columns have existed
    -- since this table was written -- "so a citation can point at a span
    -- rather than just a chunk" -- and nothing had ever filled them, because
    -- the only chunker was hypothetical. semchunk returns offsets on request
    -- (ingestion.md §4), so the citation this schema promised is now
    -- reachable rather than aspirational.
    insert into content.resource_chunks
        (resource_id, ordinal, content, token_count, start_offset, end_offset, metadata)
    select p_resource_id,
           (ord - 1)::int,
           c->>'content',
           (c->>'token_count')::int,
           (c->>'start_offset')::int,
           (c->>'end_offset')::int,
           coalesce(c->'metadata', '{}'::jsonb)
    from jsonb_array_elements(p_chunks) with ordinality t(c, ord);
    get diagnostics v_count = row_count;

    update content.resources set status = 'ready', updated_at = now()
    where id = p_resource_id;
    return v_count;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 6. Reconciliation — the invariant brief.md §3 states, made checkable.
--
--   "every files row has exactly one object in storage, and no object in
--    storage lacks a files row"
--
-- The database can only see one side of that. This reports what it CAN check;
-- the storage side is a Content Server job that lists the bucket and compares.
-- Same shape as aiq.check_drift: a non-empty result is a writer bug, not a
-- routine merge.
-- ------------------------------------------------------------
create or replace function content.check_drift()
returns table(kind text, id uuid, detail text) as $$
    -- a file no resource points at: the upload transaction died after storing
    select 'orphan_file'::text, f.id, f.bucket || '/' || f.object_key
    from content.files f
    where not exists (select 1 from content.resources r where r.file_id = f.id)
    union all
    -- a resource stuck pending: the ingestion workflow never finished
    select 'unchunked_resource'::text, r.id, coalesce(r.title, r.uri, '(untitled)')
    from content.resources r
    where r.status = 'pending' and r.ingested_at < now() - interval '1 hour'
    union all
    -- a ready resource with no chunks: record_chunks was never called
    select 'ready_but_empty'::text, r.id, coalesce(r.title, r.uri, '(untitled)')
    from content.resources r
    where r.status = 'ready'
      and not exists (select 1 from content.resource_chunks c where c.resource_id = r.id);
$$ language sql stable;

-- ============================================================
-- 7. Ingestion — how bytes become chunks, and who decides.
--
-- §3 named this the primary use case ("upload -> registered -> queryable is
-- meant to be one flow") and then left one half of it hypothetical: the
-- workflow named on the channel had nothing to run, no chunker existed
-- anywhere in the collection, and `resource_chunks` was only ever filled by a
-- fixture. RELEASE-0.1.md's last unchecked worker criterion says it plainly --
-- "upload a file, and with no further action it becomes answerable by SEARCH".
--
-- WHAT LIVES HERE AND WHAT DOES NOT, because the split is the design:
--
--   * The DEFAULTS -- how a PDF differs from a WAV, which parser, how big a
--     chunk is -- live in the worker (percolate-core's `ingest` package), not
--     in a table. They are code with libraries behind them, they change with
--     those libraries, and a table of them would be a second place to be
--     wrong. `specs/world-model-ingestion/ingestion.md` is their contract.
--   * The OVERRIDES live here, because they are the deployment's and the
--     uploader's, not the library's. A channel says how its own content
--     should be handled; one upload may say something different again. Both
--     are ordinary jsonb, validated by a pydantic model on the worker side
--     the moment it reads them -- so a policy that cannot be honoured fails
--     the step by name rather than being silently half-applied.
--
-- The layering is therefore: family default (code) <- channel
-- (config.ingest_policy) <- upload (metadata.ingest_policy). Later wins, key
-- by key, at every depth.
-- ------------------------------------------------------------

-- Deep merge, because a shallow one makes the common override a footgun.
-- `||` replaces a whole object, so a channel setting
-- {"chunking": {"target_tokens": 900, "overlap": 0.15}} and an upload saying
-- {"chunking": {"target_tokens": 400}} would silently lose the overlap. Every
-- policy layer is a PATCH, and a patch that erases its siblings is not one.
create or replace function content.merge_policy(p_base jsonb, p_patch jsonb)
returns jsonb as $$
declare v_out jsonb; k text; v jsonb;
begin
    if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
        return coalesce(p_base, '{}'::jsonb);
    end if;
    if p_base is null or jsonb_typeof(p_base) <> 'object' then
        return p_patch;
    end if;
    v_out := p_base;
    for k, v in select * from jsonb_each(p_patch) loop
        if jsonb_typeof(v) = 'object' and jsonb_typeof(coalesce(v_out->k,'null'::jsonb)) = 'object' then
            v_out := jsonb_set(v_out, array[k], content.merge_policy(v_out->k, v));
        else
            v_out := jsonb_set(v_out, array[k], v, true);
        end if;
    end loop;
    return v_out;
end;
$$ language plpgsql immutable;

-- Everything the ingest worker needs about one resource, in one call.
--
-- ONE CALL rather than four, because the worker holds no table grants at all
-- (integration.sql §4) -- it cannot join resources to files to channels, and a
-- function per column would be four SECURITY DEFINER surfaces where one will
-- do. It returns jsonb for the same reason workflow.artifact does: a
-- set-returning function under a step's `to_jsonb(fn(...))` collapses "no rows"
-- into `null`, which reads as success.
--
-- Null when the caller may not see it, matching resolve_file(): "no such
-- resource" and "not yours" are deliberately one answer.
create or replace function content.ingest_target(p_resource_id uuid)
returns jsonb as $$
    select jsonb_build_object(
        'resource_id',  r.id,
        'title',        r.title,
        'uri',          r.uri,
        'status',       r.status,
        'org_id',       r.org_id,
        'channel',      c.name,
        'bucket',       f.bucket,
        'object_key',   f.object_key,
        'content_type', f.content_type,
        'size_bytes',   f.size_bytes,
        'checksum',     f.checksum,
        -- The two override layers, already merged, in the order the brief
        -- gives them. The worker merges what comes back onto the family
        -- default it holds in code; it never sees a default from here.
        'policy',       content.merge_policy(
                            coalesce(c.config->'ingest_policy', '{}'::jsonb),
                            coalesce(r.metadata->'ingest_policy', '{}'::jsonb)))
    from content.resources r
    join content.channels c on c.id = r.channel_id
    left join content.files f on f.id = r.file_id
    where r.id = p_resource_id
      and content.may_write_org(r.org_id);
$$ language sql stable security definer set search_path = pg_catalog, public;

-- What the worker calls when it is done. ONE call, so a resource is never
-- observably half-ingested: the chunks, the record of how they were produced,
-- and the status change are one transaction.
--
-- It delegates the chunk write to record_chunks() rather than repeating the
-- insert, because two functions writing the same table is how the offsets
-- above end up filled by one path and not the other.
--
-- p_outcome:
--   {"parser": "pymupdf4llm",           -- what actually read the bytes
--    "mode":   "text" | "tabular" | "store" | "skip",
--    "chunks": [{content, token_count, start_offset, end_offset, metadata}],
--    "markdown": {"bucket": …, "object_key": …, "bytes": N},  -- optional
--    "detail": {...}}                   -- anything worth keeping, e.g. a
--                                          transcript's duration and language
--
-- The parse record is kept because a chunk that reads badly is nearly always
-- the parser's fault and not the chunker's, and "which library produced this
-- text, at what version" is the first question. Storing the intermediate
-- markdown is optional and off the hot path -- it is bytes, so it goes to
-- object storage like any other bytes, and only its key lands here.
create or replace function content.record_ingest(p_resource_id uuid, p_outcome jsonb)
returns jsonb as $$
declare
    v_org    uuid;
    v_mode   text := coalesce(p_outcome->>'mode', 'text');
    v_count  int  := 0;
    v_status text;
begin
    select r.org_id into v_org from content.resources r where r.id = p_resource_id;
    if not found or not content.may_write_org(v_org) then
        raise exception 'no such resource, or it is not yours';
    end if;

    if p_outcome ? 'chunks' then
        v_count := content.record_chunks(p_resource_id, p_outcome->'chunks');
    end if;

    -- 'ready' means retrievable AS CORPUS -- something SEARCH can return. A
    -- mode that produces no chunks is deliberately NOT ready: schema §3 gives
    -- 'stored' to bytes that are registered and have nothing to chunk, and
    -- check_drift()'s `ready_but_empty` exists precisely to catch a writer
    -- that calls a chunkless resource ready.
    v_status := case when v_count > 0 then 'ready' else 'stored' end;

    update content.resources
       set status   = v_status,
           metadata = content.merge_policy(metadata, jsonb_build_object(
                          'ingest', jsonb_strip_nulls(jsonb_build_object(
                              'mode',      v_mode,
                              'parser',    p_outcome->>'parser',
                              'chunks',    v_count,
                              'markdown',  p_outcome->'markdown',
                              'detail',    p_outcome->'detail',
                              'at',        to_jsonb(now()))))),
           updated_at = now()
     where id = p_resource_id;

    -- A receipt, not the rows (workflow-engine/outputs.md §2): ids and counts,
    -- bounded by construction. The chunks themselves already have a home.
    return jsonb_build_object('resource_id', p_resource_id,
                              'chunks', v_count, 'mode', v_mode,
                              'status', v_status);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

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
-- SECURITY INVOKER, and that is not the same as scoped: matrix expansion
-- calls step functions from inside the engine's SECURITY DEFINER path, so
-- this runs as the schema owner and RLS does not apply to it. Said plainly
-- because the comfortable assumption -- "invoker, so the caller's policy
-- filters it" -- is false here and would be a bad thing to believe about a
-- function that reads a tenant's corpus. What scopes the fan-out is the
-- resource id, which comes from the run that was started by the upload.
create or replace function content.chunks_to_embed(p_resource_id uuid)
returns jsonb as $$
    select coalesce(jsonb_agg(jsonb_build_object('chunk_id', c.id, 'content', c.content)
                              order by c.ordinal), '[]'::jsonb)
    from content.resource_chunks c
    where c.resource_id = p_resource_id;
$$ language sql stable;

-- ------------------------------------------------------------
-- 7b. Datasets — the tabular path, which is not the chunking path.
--
-- A CSV is not prose and chunking it is a category error: 200 rows of a price
-- table become 200 near-identical embeddings that rank against each other and
-- answer nothing. The right home for a table is a table, so tabular uploads
-- are converted once to Parquet, left in object storage, and registered here
-- -- read by DuckDB directly from S3 when someone asks a question of them.
--
-- WHY A REGISTRY ROW AND NOT JUST AN OBJECT KEY: a dataset accumulates. The
-- second upload of this month's export is the same logical table as the first,
-- and `mode = 'append'` says so -- files land under one prefix and the reader
-- globs it, which is the whole of the "Iceberg-like" claim and deliberately
-- all of it. No manifest, no snapshot isolation, no compaction: a prefix, a
-- glob, and a row saying what the columns were. That is enough to query and
-- honest about what it is not (ingestion.md §6 names what breaks first).
create table if not exists content.datasets (
    id           uuid primary key default gen_random_uuid(),
    -- The logical table. Unique per org, so two tenants may both have `sales`.
    name         text not null,
    org_id       uuid,
    -- The prefix files land under, NOT one file: an appended dataset is many.
    bucket       text not null,
    prefix       text not null,
    format       text not null default 'parquet' check (format in ('parquet')),
    mode         text not null default 'append' check (mode in ('append','replace')),
    -- What a reader needs before it reads: [{name, type}]. Written from the
    -- Arrow schema the conversion actually produced, never from the CSV header
    -- alone -- a header is names, and a query needs types.
    columns      jsonb not null default '[]'::jsonb,
    row_count    bigint not null default 0,
    file_count   int not null default 0,
    partition_by text[] not null default '{}',
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    unique (org_id, name)
);

-- Which resources make up a dataset. A dataset is not one upload, and the
-- resource still exists in its own right -- it has bytes, an uploader, a
-- checksum and a visibility. This is the join, not a duplicate of either side.
create table if not exists content.dataset_files (
    dataset_id  uuid not null references content.datasets(id) on delete cascade,
    resource_id uuid not null references content.resources(id) on delete cascade,
    object_key  text not null,
    row_count   bigint not null default 0,
    added_at    timestamptz not null default now(),
    primary key (dataset_id, resource_id)
);

create trigger trg_datasets_touch before update on content.datasets
    for each row execute function public.touch_updated_at();

-- Register the Parquet a tabular upload was converted into.
--
-- 'replace' deletes the dataset's other members rather than the objects: the
-- bytes stay content-addressed and reachable through their own resources, and
-- an object no dataset points at is exactly what check_drift() is for. A
-- registry that deleted from a bucket would be a second deletion authority
-- over content nobody said to destroy.
create or replace function content.register_dataset(
    p_resource_id uuid,
    p_name        text,
    p_bucket      text,
    p_object_key  text,
    p_columns     jsonb,
    p_row_count   bigint,
    p_mode        text default 'append',
    p_partition_by text[] default '{}'
) returns jsonb as $$
declare
    v_org    uuid;
    v_prefix text;
    v_ds     uuid;
begin
    select r.org_id into v_org from content.resources r where r.id = p_resource_id;
    if not found or not content.may_write_org(v_org) then
        raise exception 'no such resource, or it is not yours';
    end if;

    -- The prefix is derived from the key the caller actually wrote, so the
    -- registry cannot describe a location nothing was written to.
    v_prefix := regexp_replace(p_object_key, '/[^/]+$', '');

    insert into content.datasets (name, org_id, bucket, prefix, mode, columns,
                                  partition_by)
    values (p_name, v_org, p_bucket, v_prefix, p_mode, coalesce(p_columns,'[]'::jsonb),
            coalesce(p_partition_by, '{}'))
    on conflict (org_id, name) do update
        set columns = excluded.columns, mode = excluded.mode,
            partition_by = excluded.partition_by, updated_at = now()
    returning id into v_ds;

    if p_mode = 'replace' then
        delete from content.dataset_files where dataset_id = v_ds
          and resource_id <> p_resource_id;
    end if;

    insert into content.dataset_files (dataset_id, resource_id, object_key, row_count)
    values (v_ds, p_resource_id, p_object_key, coalesce(p_row_count, 0))
    on conflict (dataset_id, resource_id) do update
        set object_key = excluded.object_key, row_count = excluded.row_count;

    update content.datasets d
       set row_count  = (select coalesce(sum(row_count),0) from content.dataset_files where dataset_id = v_ds),
           file_count = (select count(*) from content.dataset_files where dataset_id = v_ds),
           updated_at = now()
     where d.id = v_ds;

    return jsonb_build_object('dataset_id', v_ds, 'name', p_name,
                              'object_key', p_object_key, 'mode', p_mode);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- What DuckDB should read. A glob when the dataset appends, one key when it
-- does not -- so `select * from read_parquet(content.dataset_uri('sales'))`
-- is the whole reader integration and there is no client-side convention to
-- keep in step with this table.
--
-- SECURITY INVOKER: a caller who cannot see the dataset's org gets no row and
-- therefore no bucket path. A storage location is a capability.
create or replace function content.dataset_uri(p_name text)
returns text as $$
    select 's3://' || d.bucket || '/' || d.prefix || '/*.parquet'
    from content.datasets d
    where d.name = p_name
      and (d.org_id is null or d.org_id in (select aiq.current_org_ids()))
    order by d.org_id nulls last
    limit 1;
$$ language sql stable;
