-- ============================================================
-- Agentic — sessions, runs, messages, agents, tool servers
--
-- The territory for `brief.md`'s §7 map. Loads after workflow-engine and
-- user-rbac (it references `workflow.tasks` and `rbac.current_user_id()`),
-- as app_owner, never as a superuser.
--
-- Three conventions inherited from this collection rather than re-decided,
-- because each was learned the hard way in `user-rbac/schema.sql`:
--
--   1. app_owner owns tables and SECURITY DEFINER functions; RLS is ENABLEd
--      but NOT FORCEd, so the trusted function path can still write.
--   2. The untrusted read path is `*_api` views owned by api_viewer -- a
--      DIFFERENT role from the table owner, which is what makes RLS actually
--      enforce through a view. PostgREST is pointed at the views.
--   3. Every SECURITY DEFINER function sets `search_path` explicitly and
--      qualifies every reference.
--
-- What is deliberately NOT here: anything the agent runtime could do itself.
-- The LLM call, the tool calls, and the SSE fan-out are outside SQL's reach
-- (brief.md §8); everything else in an agent turn is a row this file owns.
-- ============================================================

do $$
begin
    if (select usesuper from pg_user where usename = current_user) then
        raise exception
            'agentic/schema.sql must NOT be loaded as a superuser: superusers '
            'bypass RLS unconditionally, which would make every policy below '
            'silently inert (see user-rbac/schema.sql for the reproduction). '
            'Run: psql -c ''set role app_owner;'' -f schema.sql';
    end if;
end $$;

create extension if not exists pgcrypto;
create schema if not exists agentic;

-- ------------------------------------------------------------
-- 1. Tool servers -- registered once, referenced by every agent (brief §5.2)
--
-- One row per MCP server or OpenAPI service. The runtime's entire tool
-- surface is this table plus agents.tools; there is no built-in tool, ever.
-- ------------------------------------------------------------
create table agentic.tool_servers (
    id              uuid primary key default gen_random_uuid(),
    name            text not null unique,
    kind            text not null check (kind in ('mcp', 'openapi')),
    url             text not null,
    -- An indirection, never a literal secret -- the same boundary
    -- workflow-engine's http_call draws. brief.md §9: this collection has no
    -- secrets mechanism yet, and this column is the seam one plugs into.
    credential_ref  text,
    -- brief.md §5.2/§5.3: which servers return citable retrieval results.
    -- A flag, not a tool-name convention -- ai-query-layer's server sets it,
    -- a ticketing API does not.
    emits_citations boolean not null default false,
    -- Which server is the runtime's own agent gateway (brief.md §5.1 item 3),
    -- i.e. whose tools ARE agents. Also a flag rather than a name prefix, and
    -- for a sharper reason than citations: delegation decides the persistence
    -- granularity (§2's slow path) and hands the callee a delegated-by header.
    -- Detecting it by an `agent__` prefix meant any registered MCP server could
    -- claim that namespace, and a server merely *named* `agent` produced it by
    -- accident through collision-prefixing.
    serves_agents   boolean not null default false,
    -- Non-secret headers sent on BOTH the registration fetch and every
    -- subsequent call. Not a general escape hatch and explicitly not where a
    -- secret goes -- that is `credential_ref`, one column up, and the check
    -- constraint below refuses the two header names that would carry one.
    --
    -- It exists because a base url does not always identify an OpenAPI
    -- document. This collection's own REST surface is the case that proved it:
    -- one PostgREST serves five schemas from one url and picks between them
    -- with `Accept-Profile`, so `http://postgrest:3000` resolves to the
    -- `content` document and the workflow operations an agent needs are
    -- invisible -- a bound server that looks correctly registered and is
    -- missing every tool the agent was given. §5.2's adapter is required to
    -- carry no per-service knowledge, so it cannot be taught to send that
    -- header; the row has to.
    default_headers jsonb not null default '{}'::jsonb,
    -- Synced at registration and refreshed by a scheduled workflow-engine
    -- task; NOT re-fetched per agent invocation.
    cached_tools    jsonb not null default '[]'::jsonb,
    synced_at       timestamptz,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);

-- The one thing default_headers must never become. A secret in a header is
-- the same secret in a row that credential_ref exists to keep out, and it
-- would arrive there by an entirely reasonable-looking registration, so it is
-- refused by the table rather than by a convention in a reviewer's head.
alter table agentic.tool_servers add constraint tool_servers_headers_not_secrets
    check (not exists (
        select 1 from jsonb_object_keys(default_headers) k
        where lower(k) in ('authorization', 'proxy-authorization', 'cookie')));

create trigger trg_tool_servers_updated
    before update on agentic.tool_servers
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 2. Agents -- config rows; adding one is an insert (brief §2, §6)
-- ------------------------------------------------------------
create table agentic.agents (
    id                       uuid primary key default gen_random_uuid(),
    name                     text not null unique,
    system_prompt            text not null default '',
    model                    text,
    -- References into tool_servers, never inline urls/credentials (§5.2):
    --   [{"server": "p8-query", "tools": ["semantic_search"] | null}]
    -- The optional per-server allowlist is also how an agent's delegation
    -- targets are narrowed, since the agent gateway is an ordinary MCP
    -- tool_servers row (§5.1 item 3).
    tools                    jsonb not null default '[]'::jsonb,
    structured_output_schema jsonb,
    -- {"kind": "pg_function"|"webhook", "target": "..."} (§4, §9)
    chained_action           jsonb,
    -- Who summarizes this agent's windowed-out history (§3). Null falls back
    -- to one system-wide default summarizer. Self-referencing on purpose:
    -- "who summarizes" is data, not code.
    summarizer_agent_id      uuid references agentic.agents(id),
    -- {"window_messages": int, "window_tokens": int,
    --  "summarize_after_messages": int} -- §9 leaves the numbers open, so
    -- they are per-agent data with a runtime default, not constants.
    context_policy           jsonb not null default '{}'::jsonb,

    -- ------------------------------------------------------------------
    -- Classification. Not decoration: this table is expected to hold
    -- THOUSANDS of rows, because the extractor pattern (§5.7) puts one
    -- specialist agent behind every (source, document type) pair -- the same
    -- shape as content.connectors holding hundreds of sources.
    --
    -- Once that is true, "list the agents" is useless without a filter, and
    -- an interactive UI that shows a user a thousand machine extractors is
    -- broken. `audience` is the column that fixes it and it is deliberately
    -- NOT derived from tags: whether a human may pick an agent is an access
    -- decision, and inferring it from a free-text tag would make it one a
    -- typo can change.
    -- ------------------------------------------------------------------
    audience                 text not null default 'internal'
                                 check (audience in ('user','internal','system')),
    -- What the agent is FOR. Closed, because an open list becomes a synonym
    -- pile within a month and the whole point is filtering.
    category                 text not null default 'general'
                                 check (category in
                                     ('general','extractor','summariser','classifier',
                                      'router','critic','tool_user','evaluator')),
    -- Free-text, for search rather than for control. Never load-bearing.
    tags                     text[] not null default '{}',
    -- For category='extractor': which (source, doctype) this specialist owns.
    -- Unique when set, so two extractors cannot silently claim one source.
    extracts_source          text,
    extracts_doctype         text,

    created_at               timestamptz not null default now(),
    updated_at               timestamptz not null default now()
);

-- One specialist per (source, doctype). A second registration is a conflict to
-- resolve, not a fallback to pick between at runtime.
create unique index if not exists idx_agents_extractor
    on agentic.agents (extracts_source, extracts_doctype)
    where category = 'extractor';

create index if not exists idx_agents_audience on agentic.agents (audience)
    where audience = 'user';
create index if not exists idx_agents_category on agentic.agents (category);
create index if not exists idx_agents_tags     on agentic.agents using gin (tags);

-- An extractor without a declared output shape is a model call with extra
-- steps: the shape is what makes N extractions combinable and what makes a
-- bad answer RETRYABLE rather than silently wrong (workflow schema §21).
alter table agentic.agents add constraint agents_extractor_needs_schema
    check (category <> 'extractor' or structured_output_schema is not null);

create trigger trg_agents_updated
    before update on agentic.agents
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 3. Sessions -- one AG-UI thread; the unit a conversation is owned by
-- ------------------------------------------------------------
create table agentic.sessions (
    id             uuid primary key default gen_random_uuid(),
    user_id        uuid not null default rbac.current_user_id(),
    agui_thread_id text,
    title          text,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);

create index on agentic.sessions (user_id, created_at desc);

create trigger trg_sessions_updated
    before update on agentic.sessions
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 4. Runs -- one agent invocation, delegated sub-runs included (brief §7)
--
-- The delegation tree IS the span tree: parent_span_id is the parent run's
-- own span_id, never independently maintained, and trace_id is shared across
-- an entire tree -- one trace per top-level session or scheduled trigger.
--
-- owner_id is not redundant with sessions.user_id (brief §3): a scheduled run
-- has no session, so scoping RLS through a session join would put background
-- runs outside tenant isolation entirely.
-- ------------------------------------------------------------
create table agentic.runs (
    id                      uuid primary key default gen_random_uuid(),
    session_id              uuid references agentic.sessions(id) on delete cascade,
    agent_id                uuid not null references agentic.agents(id),
    owner_id                uuid not null default rbac.current_user_id(),
    parent_run_id           uuid references agentic.runs(id) on delete cascade,
    delegated_by_message_id uuid,   -- FK added below, once messages exists
    trigger_kind            text not null default 'interactive'
                                check (trigger_kind in ('interactive','scheduled')),
    -- Set only for scheduled runs: the workflow-engine task that created this
    -- one, so retry/rate-limiting/observability come from that system's
    -- existing machinery rather than a second scheduler here (§3).
    workflow_task_id        uuid references workflow.tasks(id) on delete set null,
    trace_id                text,
    span_id                 text,
    parent_span_id          text,
    depth                   int not null default 0,
    state                   jsonb not null default '{}'::jsonb,
    status                  text not null default 'pending'
                                check (status in ('pending','running','succeeded',
                                                  'failed','cancelled','quota_exceeded')),
    created_at              timestamptz not null default now(),
    updated_at              timestamptz not null default now(),
    finished_at             timestamptz,
    constraint interactive_runs_have_a_session
        check (trigger_kind <> 'interactive' or session_id is not null),
    constraint scheduled_runs_name_their_task
        check (trigger_kind <> 'scheduled' or workflow_task_id is not null),
    constraint child_runs_are_deeper_than_their_parent
        check (parent_run_id is null or depth > 0)
);

create index on agentic.runs (session_id, created_at);
create index on agentic.runs (parent_run_id);
create index on agentic.runs (trace_id);
create index on agentic.runs (owner_id, created_at desc);
create index on agentic.runs (workflow_task_id) where workflow_task_id is not null;

create trigger trg_runs_updated
    before update on agentic.runs
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 5. Messages -- both persistence granularities in one table (brief §2)
--
-- Fast path: a user row and an assistant row, tool calls riding along as
-- JSONB. Slow path: discrete tool_call/tool_response rows -- mandatory when a
-- tool call IS a delegation, so the sub-run stays independently queryable
-- rather than buried in a blob. role='summary' is a third kind entirely: one
-- row per session, superseded rather than appended to (§3).
-- ------------------------------------------------------------
create table agentic.messages (
    id           uuid primary key default gen_random_uuid(),
    run_id       uuid references agentic.runs(id) on delete cascade,
    session_id   uuid references agentic.sessions(id) on delete cascade,
    role         text not null check (role in ('system','user','assistant',
                                               'tool_call','tool_response','summary')),
    content      text,
    tool_calls   jsonb not null default '[]'::jsonb,
    tool_call_id text,
    is_error     boolean not null default false,
    error_kind   text check (error_kind in ('tool_error','dispatch_error')),
    -- Derived by the runtime from this turn's tool_response rows, never
    -- authored by the LLM (§5.3). Tagged union, not one column meaning two
    -- things:  {"kind":"chunk","resource_type","resource_id","chunk_id"}
    --       |  {"kind":"node","node_id"}
    citations    jsonb not null default '[]'::jsonb,
    seq          bigserial,
    created_at   timestamptz not null default now(),
    constraint only_summaries_may_be_runless
        check (role = 'summary' or run_id is not null),
    constraint only_tool_responses_carry_errors
        check (role = 'tool_response' or (is_error = false and error_kind is null)),
    constraint only_assistants_carry_citations
        check (role = 'assistant' or citations = '[]'::jsonb)
);

-- One summary per session, enforced by the database rather than by the
-- application remembering to update instead of insert (§3).
create unique index one_summary_per_session
    on agentic.messages (session_id) where role = 'summary';
create index on agentic.messages (session_id, seq);
create index on agentic.messages (run_id, seq);

alter table agentic.runs
    add constraint runs_delegated_by_message_fk
    foreign key (delegated_by_message_id)
    references agentic.messages(id) on delete set null;

-- ------------------------------------------------------------
-- 6. Streaming -- NOTIFY per session, relayed as AG-UI events (brief §4)
--
-- Per session, not per run, and that is the whole trick: every run in a
-- session -- delegated sub-runs included -- publishes to the same channel
-- tagged with its own run_id, so multiplexing a delegation tree into one
-- client stream is structural rather than something the runtime arranges.
--
-- NOTIFY's payload limit is 8000 bytes, so the payload is a reference (ids +
-- role), never content: the relay reads the row back. Same discipline as
-- workflow-engine's payload_ref.
-- ------------------------------------------------------------
create or replace function agentic.channel_for(p_session_id uuid) returns text
language sql immutable as $$
    select 'agui_' || replace(p_session_id::text, '-', '');
$$;

create or replace function agentic.notify_message() returns trigger as $$
begin
    perform pg_notify(
        agentic.channel_for(new.session_id),
        -- Tagged like every other event on this channel: the relay forwards
        -- AG-UI events from the runtime as-is and treats this one as a
        -- persistence checkpoint (read the row, emit it if the live delta was
        -- missed), so a late-joining or reconnecting client is never left
        -- with a gap the stream alone can't fill.
        json_build_object(
            'type',       'MESSAGE_PERSISTED',
            'message_id', new.id,
            'run_id',     new.run_id,
            'role',       new.role,
            'seq',        new.seq
        )::text
    );
    return new;
end;
$$ language plpgsql
set search_path = pg_catalog, public, agentic;

create trigger trg_notify_message
    after insert on agentic.messages
    for each row when (new.session_id is not null)
    execute function agentic.notify_message();

-- ------------------------------------------------------------
-- 7. RLS -- ENABLE, not FORCE (see header note 1)
-- ------------------------------------------------------------
alter table agentic.sessions enable row level security;
alter table agentic.runs     enable row level security;
alter table agentic.messages enable row level security;

create policy sessions_owner on agentic.sessions
    for select using (user_id = rbac.current_user_id());

-- Scoped on the run's own owner, never through the session join: a scheduled
-- run has no session, and an escape hatch for that case is how a table ends up
-- with rows nobody can see and everybody can read (brief §3).
create policy runs_owner on agentic.runs
    for select using (owner_id = rbac.current_user_id());

create policy messages_via_run on agentic.messages
    for select using (
        exists (select 1 from agentic.runs r
                where r.id = messages.run_id
                  and r.owner_id = rbac.current_user_id())
        or exists (select 1 from agentic.sessions s
                   where s.id = messages.session_id
                     and s.user_id = rbac.current_user_id())
    );

-- Agents and tool_servers are configuration, not tenant data: readable by any
-- authenticated caller, writable only through the functions below. RLS is
-- ENABLEd with an explicitly permissive read policy rather than left off --
-- the two are equivalent to a reader today and completely different to the next
-- person to touch this file: "no policy" reads as an oversight, a policy that
-- says `true` reads as a decision, and it is the seam per-tenant agents would
-- attach to.
--
-- OPEN, and stated because it is a real consequence rather than an accident:
-- every authenticated user can therefore see, and run, every agent -- `/chat`'s
-- `model` field is just a name. A deployment that needs per-tenant agents needs
-- a column that does not exist yet (brief.md §9).
alter table agentic.agents       enable row level security;
alter table agentic.tool_servers enable row level security;

create policy agents_are_shared_config on agentic.agents
    for select using (true);
create policy tool_servers_are_shared_config on agentic.tool_servers
    for select using (true);
-- ------------------------------------------------------------
-- 8. The write path -- SECURITY DEFINER, ownership checked explicitly
--
-- DEFINER bypasses RLS, so each function re-checks what the policy would have:
-- these are the trusted path, and a trusted path that forgets to check is
-- indistinguishable from no policy at all.
-- ------------------------------------------------------------
create or replace function agentic.create_session(p_title text default null)
returns agentic.sessions
language sql security definer
set search_path = pg_catalog, public
as $$
    insert into agentic.sessions (user_id, title)
    values (rbac.current_user_id(), p_title)
    returning *;
$$;

create or replace function agentic.start_run(
    p_agent_name    text,
    p_session_id    uuid default null,
    p_parent_run_id uuid default null,
    p_delegated_by  uuid default null,
    p_trace_id      text default null,
    p_span_id       text default null,
    p_trigger_kind  text default 'interactive',
    p_workflow_task_id uuid default null
) returns agentic.runs
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_agent   agentic.agents;
    v_parent  agentic.runs;
    v_run     agentic.runs;
    v_owner   uuid := rbac.current_user_id();
    v_depth   int  := 0;
    v_pspan   text;
    v_trace   text := p_trace_id;
begin
    select * into v_agent from agentic.agents where name = p_agent_name;
    if not found then
        raise exception 'no agent named %', p_agent_name;
    end if;

    if p_session_id is not null then
        if not exists (select 1 from agentic.sessions
                       where id = p_session_id and user_id = v_owner) then
            raise exception 'session % is not yours', p_session_id;
        end if;

        -- One live turn per conversation. Two concurrent turns both reload the
        -- same window and both append to it, so the history each one saw is not
        -- the history that ends up stored -- a silent corruption, not an error.
        -- Delegated runs (parent_run_id set) are exempt: they happen *inside* a
        -- turn, which is the whole point.
        --
        -- Bounded by age deliberately: a runtime that dies mid-turn would
        -- otherwise leave a session wedged forever, and a stale `running` row
        -- is evidence of a crash, not of a live client.
        if p_parent_run_id is null and p_trigger_kind = 'interactive'
           and exists (
               select 1 from agentic.runs
                where session_id = p_session_id
                  and parent_run_id is null
                  and status = 'running'
                  and created_at > now() - interval '10 minutes'
           )
        then
            raise exception 'session % already has a turn in flight', p_session_id;
        end if;
    end if;

    if p_parent_run_id is not null then
        select * into v_parent from agentic.runs where id = p_parent_run_id;
        if not found or v_parent.owner_id <> v_owner then
            raise exception 'parent run % is not yours', p_parent_run_id;
        end if;
        -- The delegation tree and the trace tree are the same tree: a child's
        -- parent_span_id is simply its parent's span_id (brief §7).
        v_depth := v_parent.depth + 1;
        v_pspan := v_parent.span_id;
        v_trace := coalesce(v_trace, v_parent.trace_id);

        -- A hard ceiling, here and not only in the runtime. brief.md §9 leaves
        -- the *policy* number open and a runtime may set a lower one; this is
        -- the structural backstop, because start_run is granted to every
        -- authenticated caller and an app-side limit protects only callers who
        -- go through the app.
        if v_depth > 8 then
            raise exception 'delegation depth % exceeds the hard limit of 8', v_depth;
        end if;
    end if;

    insert into agentic.runs (session_id, agent_id, owner_id, parent_run_id,
                              delegated_by_message_id, trigger_kind,
                              workflow_task_id, trace_id, span_id,
                              parent_span_id, depth, status)
    values (p_session_id, v_agent.id, v_owner, p_parent_run_id,
            p_delegated_by, p_trigger_kind, p_workflow_task_id,
            coalesce(v_trace, encode(gen_random_bytes(16), 'hex')),
            coalesce(p_span_id, encode(gen_random_bytes(8), 'hex')),
            v_pspan, v_depth, 'running')
    returning * into v_run;
    return v_run;
end;
$$;

create or replace function agentic.finish_run(
    p_run_id uuid,
    p_status text,
    p_state  jsonb default null
) returns agentic.runs
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_run agentic.runs;
begin
    select * into v_run from agentic.runs where id = p_run_id;
    if not found or v_run.owner_id <> rbac.current_user_id() then
        raise exception 'run % is not yours', p_run_id;
    end if;

    update agentic.runs
       set status      = p_status,
           state       = coalesce(p_state, state),
           finished_at = case when p_status in ('pending','running')
                              then null else now() end
     where id = p_run_id
     returning * into v_run;
    return v_run;
end;
$$;

-- One RPC, one transaction: a half-written turn is not a state this database
-- can be left in (sequence.md Gate 2). Takes both granularities -- the caller
-- decides fast or slow path, the function does not care.
create or replace function agentic.persist_turn(p_rows jsonb)
returns setof agentic.messages
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_run_ids uuid[];
begin
    select array_agg(distinct (r->>'run_id')::uuid)
      into v_run_ids
      from jsonb_array_elements(p_rows) as r
     where r->>'run_id' is not null;

    if exists (select 1 from agentic.runs
               where id = any(v_run_ids) and owner_id <> rbac.current_user_id())
    then
        raise exception 'cannot write messages into a run that is not yours';
    end if;

    return query
    insert into agentic.messages (id, run_id, session_id, role, content, tool_calls,
                                  tool_call_id, is_error, error_kind, citations)
    -- The caller may supply the id, and for the assistant row it always does:
    -- the runtime mints that id before the turn runs so its streamed
    -- TEXT_MESSAGE_* deltas and this row are the same message (brief.md §4).
    -- Letting the database assign one instead silently breaks that -- the
    -- stream refers to a message id that never existed.
    select coalesce((r->>'id')::uuid, gen_random_uuid()),
           (r->>'run_id')::uuid,
           (r->>'session_id')::uuid,
           r->>'role',
           r->>'content',
           coalesce(r->'tool_calls', '[]'::jsonb),
           r->>'tool_call_id',
           coalesce((r->>'is_error')::boolean, false),
           r->>'error_kind',
           coalesce(r->'citations', '[]'::jsonb)
      from jsonb_array_elements(p_rows) with ordinality as t(r, ord)
     -- The ORDER BY is what makes `seq` follow conversation order rather than
     -- whatever order the planner felt like emitting rows in. Postgres assigns
     -- serial values in the order the INSERT's SELECT produces them; that is
     -- relied on here deliberately, and named so the reliance is visible.
     order by t.ord
    returning *;
end;
$$;

-- Superseded, never appended to -- the partial unique index makes that a
-- database guarantee, this function makes it a single round trip (§3).
create or replace function agentic.upsert_summary(p_session_id uuid, p_content text)
returns agentic.messages
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_row agentic.messages;
begin
    if not exists (select 1 from agentic.sessions
                   where id = p_session_id and user_id = rbac.current_user_id()) then
        raise exception 'session % is not yours', p_session_id;
    end if;

    insert into agentic.messages (session_id, role, content)
    values (p_session_id, 'summary', p_content)
    on conflict (session_id) where role = 'summary'
    do update set content = excluded.content, created_at = now()
    returning * into v_row;
    return v_row;
end;
$$;

-- Configuration writes. brief.md §6 calls applying an agent a *migration*, not
-- a deploy -- these are what such a migration calls, and they are gated on the
-- same permission model everything else in this collection uses.
create or replace function agentic.upsert_agent(p_spec jsonb)
returns agentic.agents
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_row agentic.agents;
begin
    if not rbac.has_permission(rbac.current_user_id(), 'agents', 'update') then
        raise exception 'not authorized to author agents';
    end if;

    insert into agentic.agents (name, system_prompt, model, tools,
                                structured_output_schema, chained_action,
                                summarizer_agent_id, context_policy)
    values (p_spec->>'name',
            coalesce(p_spec->>'system_prompt', ''),
            p_spec->>'model',
            coalesce(p_spec->'tools', '[]'::jsonb),
            p_spec->'structured_output_schema',
            p_spec->'chained_action',
            (p_spec->>'summarizer_agent_id')::uuid,
            coalesce(p_spec->'context_policy', '{}'::jsonb))
    on conflict (name) do update
       set system_prompt            = excluded.system_prompt,
           model                    = excluded.model,
           tools                    = excluded.tools,
           structured_output_schema = excluded.structured_output_schema,
           chained_action           = excluded.chained_action,
           summarizer_agent_id      = excluded.summarizer_agent_id,
           context_policy           = excluded.context_policy
    returning * into v_row;
    return v_row;
end;
$$;

create or replace function agentic.upsert_tool_server(p_spec jsonb)
returns agentic.tool_servers
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_row agentic.tool_servers;
begin
    if not rbac.has_permission(rbac.current_user_id(), 'tool_servers', 'update') then
        raise exception 'not authorized to register tool servers';
    end if;

    insert into agentic.tool_servers (name, kind, url, credential_ref,
                                      emits_citations, serves_agents,
                                      cached_tools, synced_at)
    values (p_spec->>'name', p_spec->>'kind', p_spec->>'url',
            p_spec->>'credential_ref',
            coalesce((p_spec->>'emits_citations')::boolean, false),
            coalesce((p_spec->>'serves_agents')::boolean, false),
            coalesce(p_spec->'cached_tools', '[]'::jsonb),
            case when p_spec ? 'cached_tools' then now() end)
    on conflict (name) do update
       set kind            = excluded.kind,
           url             = excluded.url,
           credential_ref  = excluded.credential_ref,
           emits_citations = excluded.emits_citations,
           serves_agents   = excluded.serves_agents,
           cached_tools    = excluded.cached_tools,
           synced_at       = coalesce(excluded.synced_at, agentic.tool_servers.synced_at)
    returning * into v_row;
    return v_row;
end;
$$;

-- A chained-action target this system owns, and the reference example of the
-- shape (brief.md §4): the runtime calls <target>(jsonb) with the run's
-- structured output plus the run context that produced it --
--   {"run_id", "session_id", "agent", "trigger_kind", "output": {...}}
-- The context half is not optional: a chained action that only receives the
-- model's output cannot write anything scoped to the conversation it came
-- from, which is what both the summarizer here and §3's consolidation run need.
--
-- And `trigger_kind` is why the context needs to be more than ids. A chained
-- action fires whenever its agent produces structured output -- including when
-- that agent was invoked as somebody's *delegate* mid-conversation. The
-- summarizer delegated to by another agent would then overwrite the live
-- session's rolling summary with a compression of whatever it was asked. Found
-- by running it: an agent that delegated to the summarizer clobbered the
-- window summary of the conversation it was helping with. A session-scoped
-- write must therefore check *why* the run happened, not only where it sat.
-- The signature every chained-action target must have: jsonb in, jsonb out.
-- Not a style preference -- the runtime persists the result as an ordinary
-- tool_response message row, so it has to be JSON; a function returning a
-- composite type cannot even be decoded by the client (confirmed the hard way:
-- "text encoding of composite types is not supported").
create or replace function agentic.apply_summary(p_payload jsonb)
returns jsonb
language sql security definer
set search_path = pg_catalog, public
as $$
    select case
        when p_payload->>'trigger_kind' is distinct from 'scheduled'
            -- Not an error: the summarizer did its job, it simply was not the
            -- scheduled window-summarization run, so its output is a tool
            -- result for whoever delegated to it and nothing else.
            then jsonb_build_object('skipped', 'not a scheduled run')
        else to_jsonb(agentic.upsert_summary(
            (p_payload->>'session_id')::uuid,
            p_payload->'output'->>'summary'
        ))
    end;
$$;

-- ------------------------------------------------------------
-- 9. The read path -- *_api views owned by api_viewer (header note 2)
-- ------------------------------------------------------------
grant usage on schema agentic to web_anon, authenticated, api_viewer;

create view agentic.sessions_api as
    select id, user_id, agui_thread_id, title, created_at from agentic.sessions;
create view agentic.runs_api as
    select id, session_id, agent_id, owner_id, parent_run_id,
           delegated_by_message_id, trigger_kind, workflow_task_id,
           trace_id, span_id, parent_span_id, depth, state, status,
           created_at, finished_at
      from agentic.runs;
create view agentic.messages_api as
    select id, run_id, session_id, role, content, tool_calls, tool_call_id,
           is_error, error_kind, citations, seq, created_at
      from agentic.messages;
-- credential_ref is included, and that is deliberate rather than an oversight:
-- it is a *reference* ("env:X", "vault://path"), never the secret itself --
-- brief.md §5.2 forbids a literal secret in a row, so there is nothing here to
-- hide. Excluding it was tried first and is worse than useless: the runtime
-- reads its tool servers through this view like every other client, so hiding
-- the ref silently produced unauthenticated tool syncs -- a tool list that
-- looks correct and is missing every operation the caller's role would have
-- been allowed to see.
create view agentic.tool_servers_api as
    select id, name, kind, url, credential_ref, emits_citations, serves_agents,
           cached_tools, synced_at, created_at
      from agentic.tool_servers;
-- The view an interactive UI reads. `audience = 'user'` is the whole point of
-- the column: a thousand extractors are invisible here without anyone having
-- to remember to filter.
create or replace view agentic.agents_pickable as
select id, name, category, tags, model, structured_output_schema is not null as has_shape
from agentic.agents
where audience = 'user'
order by category, name;

-- The extractor fleet, as an operations surface. Mirrors
-- content.v_connectors: what exists, what it covers, and whether it is
-- contracted.
create or replace view agentic.v_extractors as
select name, extracts_source as source, extracts_doctype as doctype,
       model, tags,
       structured_output_schema is not null as has_shape,
       (select count(*) from jsonb_object_keys(
           coalesce(structured_output_schema->'properties','{}'::jsonb))) as n_slots
from agentic.agents
where category = 'extractor'
order by extracts_source, extracts_doctype;

create view agentic.agents_api as
    select id, name, system_prompt, model, tools, structured_output_schema,
           chained_action, summarizer_agent_id, context_policy, created_at
      from agentic.agents;

grant select on agentic.sessions, agentic.runs, agentic.messages,
                agentic.agents, agentic.tool_servers to api_viewer;
grant execute on function rbac.current_user_id() to api_viewer;

-- Temporary CREATE, exactly as user-rbac does it: needed only for the
-- ownership transfer, revoked immediately after.
grant create on schema agentic to api_viewer;
alter view agentic.sessions_api     owner to api_viewer;
alter view agentic.runs_api         owner to api_viewer;
alter view agentic.messages_api     owner to api_viewer;
alter view agentic.tool_servers_api owner to api_viewer;
alter view agentic.agents_api       owner to api_viewer;
revoke create on schema agentic from api_viewer;

grant select on agentic.sessions_api, agentic.runs_api, agentic.messages_api,
                agentic.tool_servers_api, agentic.agents_api to authenticated;

grant execute on function agentic.create_session(text) to authenticated;
grant execute on function agentic.start_run(text, uuid, uuid, uuid, text, text, text, uuid)
    to authenticated;
grant execute on function agentic.finish_run(uuid, text, jsonb) to authenticated;
grant execute on function agentic.persist_turn(jsonb) to authenticated;
grant execute on function agentic.upsert_summary(uuid, text) to authenticated;
grant execute on function agentic.apply_summary(jsonb) to authenticated;
grant execute on function agentic.upsert_agent(jsonb) to authenticated;
grant execute on function agentic.upsert_tool_server(jsonb) to authenticated;
grant execute on function agentic.channel_for(uuid) to authenticated, api_viewer;

-- No base-table INSERT/UPDATE/DELETE grant to any PostgREST-facing role: the
-- write path is the functions above, and nothing else.

-- ------------------------------------------------------------
-- 10. Invariant self-checks -- the same two this collection has already been
--     bitten by, asserted at load time rather than trusted.
-- ------------------------------------------------------------
do $$
declare
    v_bad text;
begin
    -- (a) Every *_api view must be owned by api_viewer, NOT by the table
    -- owner: an owner-privileged view owned by the table owner bypasses RLS
    -- for every caller.
    select string_agg(c.relname, ', ')
      into v_bad
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'agentic' and c.relkind = 'v'
       and c.relname like '%\_api'
       and pg_get_userbyid(c.relowner) <> 'api_viewer';
    if v_bad is not null then
        raise exception 'VIEW OWNERSHIP INVARIANT VIOLATED: % must be owned by '
                        'api_viewer, not the table owner', v_bad;
    end if;

    -- (b) No write grant on a base table for the PostgREST-facing roles.
    select string_agg(distinct table_name, ', ')
      into v_bad
      from information_schema.role_table_grants
     where table_schema = 'agentic'
       and grantee in ('web_anon', 'authenticated')
       and privilege_type in ('INSERT', 'UPDATE', 'DELETE');
    if v_bad is not null then
        raise exception 'WRITE GRANT INVARIANT VIOLATED: % is writable directly; '
                        'the write path is the SECURITY DEFINER functions only', v_bad;
    end if;
end $$;
