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
-- SEMANTIC and HYBRID are documented as working over "chunks", so the corpus
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
    status       text not null default 'pending'
                     check (status in ('pending','ready','failed','superseded')),
    metadata     jsonb not null default '{}'::jsonb,
    org_id       uuid,
    ingested_at  timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    unique (channel_id, external_id)
);
create index idx_resources_channel on content.resources (channel_id, ingested_at desc);
create index idx_resources_org on content.resources (org_id);
create index idx_resources_status on content.resources (status) where status <> 'ready';

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
    select id into v_channel from content.channels
    where name = p_channel and (org_id is not distinct from p_org_id or org_id is null);
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
    select id into v_channel from content.channels
    where name = p_channel and (org_id is not distinct from p_org_id or org_id is null);
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
-- SECURITY INVOKER on purpose: this is a READ on behalf of a user, so it must
-- be subject to that user's RLS. Making it DEFINER would hand any caller any
-- tenant's storage keys -- the same distinction ai-query-layer's read path
-- draws for the same reason.
create or replace function content.resolve_file(p_resource_id uuid)
returns table(bucket text, object_key text, content_type text, size_bytes bigint) as $$
    select f.bucket, f.object_key, f.content_type, f.size_bytes
    from content.resources r
    join content.files f on f.id = r.file_id
    where r.id = p_resource_id;
$$ language sql stable security invoker;

-- Record chunks produced by the ingestion workflow, and flip the resource
-- ready. One call rather than N inserts plus an update, so a resource is never
-- observably half-chunked.
create or replace function content.record_chunks(p_resource_id uuid, p_chunks jsonb)
returns int as $$
declare v_count int;
begin
    delete from content.resource_chunks where resource_id = p_resource_id;

    insert into content.resource_chunks (resource_id, ordinal, content, token_count, metadata)
    select p_resource_id,
           (ord - 1)::int,
           c->>'content',
           (c->>'token_count')::int,
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
