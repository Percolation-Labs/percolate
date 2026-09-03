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
    -- The same flag, for the other gateway. A server with this set exposes one
    -- tool per `agentic.skills` row (plugins.md §4): calling it returns that
    -- skill's body, which is how a skill is loaded by the MODEL's choice
    -- rather than by the agent's configuration. A flag rather than a name
    -- prefix for the reason serves_agents is one, and for a sharper one here:
    -- what comes back is instructions, not an observation, so the persistence
    -- adapter has to be able to recognise it and stop windowing it away.
    serves_skills   boolean not null default false,
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
--
-- Written against the lowercased document rather than with a subquery over
-- jsonb_object_keys, because a CHECK constraint may not contain a subquery at
-- all -- Postgres refuses the natural spelling outright. `?|` tests keys only,
-- so lowercasing the values along with them changes nothing.
alter table agentic.tool_servers add constraint tool_servers_headers_not_secrets
    check (not (lower(default_headers::text)::jsonb
                ?| array['authorization', 'proxy-authorization', 'cookie']));

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
    -- PINNED skills, by name, in order (plugins.md §4). These are materialised
    -- into the system prompt at invocation -- the row holds the keys, never the
    -- text, so one skill edited once changes every agent that pins it. Skills
    -- the MODEL may choose to load instead are not here at all: those are an
    -- ordinary tool binding against a serves_skills server, and keeping the
    -- two in separate columns is deliberate, because they are separate
    -- mechanisms (prompt text vs. a tool call) and a single list that meant
    -- either would be a list nobody could read the behaviour off.
    --
    -- Validated in upsert_agent rather than by a foreign key: the check that
    -- matters is not "does the skill exist" but "does this agent bind what the
    -- skill says it needs", which no FK can express.
    skills                   text[] not null default '{}',

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
-- 2b. Skills -- capability as prose, loaded on demand (plugins.md)
--
-- A tool is something an agent CALLS; a skill is something an agent READS and
-- then follows. Both are rows and neither is code, which is why they live one
-- table apart rather than one system apart -- but they are not the same thing,
-- and the difference is the one the runtime has to act on: a tool call leaves
-- the process and comes back an observation, while a skill changes how the
-- model behaves for the rest of the turn.
--
-- A row here is the frontmatter and the body of one SKILL.md, transcribed
-- rather than reinvented (plugins.md §1): `description` is what a model reads
-- to decide whether it needs this, `content` is what it reads once it has
-- decided, and keeping them in two columns IS the mechanism -- offering a
-- thousand skills costs a thousand description lines, and the bodies cost
-- nothing until one is named.
--
-- Why this is not just more `system_prompt`: a prompt belongs to one agent.
-- The same argument that made tool_servers a table rather than inline config
-- in agents.tools (brief.md §5.2) applies unchanged to prose -- ten agents
-- that must all follow the same p8ql discipline should reference it once, not
-- carry ten copies that drift.
-- ------------------------------------------------------------
create table agentic.skills (
    id              uuid primary key default gen_random_uuid(),
    -- The key an agent lists and the model names. Constrained to the shape the
    -- Agent Skills spec uses, because this name is also a TOOL name on the
    -- skill gateway (plugins.md §4), and a tool name with a space in it is a
    -- tool no model can call.
    name            text not null unique
                        check (name ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
    -- What it does. The one field a model sees without paying for the body.
    description     text not null,
    -- When to reach for it. Separate from `description` because it answers a
    -- different question, and because it is the sentence a semantic match
    -- should be hitting -- a request rarely resembles a capability statement.
    when_to_use     text,
    -- The markdown body. Never in a listing, and never embedded (§5): it is
    -- instructions, and instructions dilute the description they would be
    -- indexed alongside.
    content         text not null,
    -- What gets embedded, and the only thing that does. Generated rather than
    -- assembled by whoever writes the embedding job, so the text that was
    -- indexed and the text a reader sees cannot drift apart.
    discovery_text  text generated always as (
                        name || ': ' || description ||
                        case when when_to_use is null then ''
                             else ' ' || when_to_use end) stored,
    -- The lexical half of the same index, and it is spelled out here rather
    -- than left to aiq.register_lexical_source() for a reason Postgres
    -- enforces: A GENERATED COLUMN CANNOT REFERENCE ANOTHER GENERATED COLUMN.
    -- That function's default expression builds a tsvector over the registered
    -- content column, which here is `discovery_text` -- generated -- so the
    -- registration fails with "cannot use generated column in column
    -- generation expression". Found by running it.
    --
    -- The fix keeps both properties rather than trading one away: this column
    -- is generated from the three BASE columns directly, which is legal and
    -- indexes exactly the same text, and the registration's `add column if not
    -- exists` then finds it already present and moves on to the index. Making
    -- discovery_text an ordinary column maintained by upsert_skill would have
    -- worked too, and would have reintroduced the drift the generation exists
    -- to make impossible.
    search_tsv      tsvector generated always as (
                        to_tsvector('english',
                            name || ': ' || description ||
                            case when when_to_use is null then ''
                                 else ' ' || when_to_use end)) stored,
    -- The tool servers this skill's instructions assume. Checked when an AGENT
    -- pins the skill, not when the skill is authored: shared config may
    -- legitimately be written before anything binds it. The Agent Skills
    -- spec's `allowed-tools` is a permission grant; there are no permission
    -- prompts here, so the useful half of that field is the dependency it
    -- implies, and this is that half.
    requires_tools  text[] not null default '{}',
    -- The same three classification columns agents carry, for the same reason
    -- and sized for the same population: a table one insert away from holding
    -- thousands is a table nobody can list without a filter.
    audience        text not null default 'internal'
                        check (audience in ('user','internal','system')),
    category        text not null default 'procedure'
                        check (category in ('procedure','reference','style','safety')),
    tags            text[] not null default '{}',
    -- Bumped by upsert_skill when the text changes, and recorded on the
    -- message that loaded it (plugins.md §8). Without it, a run whose answer
    -- rests on a skill since rewritten is unreconstructable -- the same
    -- provenance problem citations solve for retrieval, one layer along.
    version         int not null default 1,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    -- The listing is a budget, not a free-text field: this text enters every
    -- prompt that offers the skill, whether or not the skill is ever used.
    -- 1536 characters is the Agent Skills listing cap, transcribed rather than
    -- invented -- and a cap enforced by the table is the only kind that holds,
    -- since the alternative is a truncation nobody sees.
    constraint skill_listing_is_bounded
        check (length(description) + coalesce(length(when_to_use), 0) <= 1536)
);

create index if not exists idx_skills_audience on agentic.skills (audience)
    where audience = 'user';
create index if not exists idx_skills_category on agentic.skills (category);
create index if not exists idx_skills_tags     on agentic.skills using gin (tags);

create trigger trg_skills_updated
    before update on agentic.skills
    for each row execute function public.touch_updated_at();

-- Discovery over a thousand skills is the same problem as discovery over a
-- thousand chunks, so it is the same machinery and not a second one: `skills`
-- registers as an ai-query-layer semantic source over the listing text, and
-- its vectors land in that layer's per-model embedding tables keyed by the
-- skill's own id. Nothing here embeds anything -- that is an external model
-- call this collection already has one path for (aiq.embed_batch_call plus a
-- scheduled workflow-engine task), and a second one would be a second answer
-- to which model this deployment uses.
--
-- Conditional, because this schema must stay loadable without the query layer
-- installed -- the same shape workflow.plan_catalog() uses to call
-- agentic.plan_facet() only when this schema is present.
-- Registered as BOTH kinds of source, which is not symmetry for its own sake.
-- The semantic registration is the one §6 is about. The lexical one is what
-- makes matching work in a deployment with no embedding provider configured --
-- `aiq.lexical` needs nothing but Postgres, and a fleet whose listings are
-- written as "use when <the words someone would type>" is unusually well
-- suited to term matching. So an agent's matching policy degrades to TEXT
-- rather than to nothing, and `aiq.search` (RRF over both) is available to a
-- deployment that has both. Learned by having no working key on the day this
-- was measured: the fallback was hypothetical until it was the only arm that
-- could run.
--
-- register_lexical_source adds a generated `search_tsv` column and its GIN
-- index to this table, which is why it is called here rather than left to a
-- deployment: the column belongs to the table, and a table whose index depends
-- on somebody remembering a setup call is a table that is slow in exactly one
-- environment.
do $$
begin
    if to_regclass('aiq.semantic_sources') is not null then
        insert into aiq.semantic_sources (name, source_table, content_col)
        values ('skills', 'agentic.skills', 'discovery_text')
        on conflict (name) do update
           set source_table = excluded.source_table,
               content_col  = excluded.content_col;
        perform aiq.register_lexical_source('skills', 'agentic.skills', 'discovery_text');
    end if;
end $$;

-- ------------------------------------------------------------
-- 2c. Plugins -- the unit a bundle of configuration arrives and leaves as
--
-- This table names something that already existed: reference/percolate.yaml
-- registers two tool servers and one agent in one document, and applying it
-- twice is already an upsert. What it could not do is tell you afterwards
-- which rows came from it, or remove them -- so a use case installed by a
-- document was uninstalled by hand, row by row, from memory.
--
-- Hence a name, a version, and a `plugin` column on each of the three config
-- tables. That is the whole concept: a plugin is not a new kind of thing, it
-- is provenance on the things that already exist, which is exactly what makes
-- a bundle removable.
-- ------------------------------------------------------------
create table agentic.plugins (
    name         text primary key
                     check (name ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
    version      text not null default '0.0.0',
    description  text,
    author       jsonb,
    homepage     text,
    -- The document as applied, verbatim. Not read back by the runtime -- the
    -- tables are the truth -- but a re-apply has to be diffable against what
    -- is installed, and the pruning half of apply_plugin is unsafe without it.
    manifest     jsonb not null default '{}'::jsonb,
    installed_at timestamptz not null default now(),
    updated_at   timestamptz not null default now()
);

create trigger trg_plugins_updated
    before update on agentic.plugins
    for each row execute function public.touch_updated_at();

-- Declared here rather than in each table's own definition because the
-- referenced table is defined last, which is deliberate and visible rather
-- than an accident of ordering: a plugin is provenance ON config, so it cannot
-- come first.
--
-- ON DELETE RESTRICT, and that is the design rather than caution. Uninstalling
-- is `apply_plugin` with an empty manifest -- which prunes each row through
-- the path that knows what else references it and reports what it removed.
-- Deleting the plugin row on its own would leave rows whose origin nobody can
-- name, which is the state this column exists to end.
alter table agentic.tool_servers
    add column if not exists plugin text
    references agentic.plugins(name) on delete restrict;
alter table agentic.agents
    add column if not exists plugin text
    references agentic.plugins(name) on delete restrict;
alter table agentic.skills
    add column if not exists plugin text
    references agentic.plugins(name) on delete restrict;

create index if not exists idx_tool_servers_plugin on agentic.tool_servers (plugin)
    where plugin is not null;
create index if not exists idx_agents_plugin on agentic.agents (plugin)
    where plugin is not null;
create index if not exists idx_skills_plugin on agentic.skills (plugin)
    where plugin is not null;

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
-- Skills and plugins are the same kind of thing and get the same treatment,
-- including the same open consequence: a skill is prose every authenticated
-- caller can read. That is the right default for a shared procedure and the
-- wrong one for a skill encoding a customer's internal process, and this is
-- the seam that case attaches to -- same column that does not exist yet.
alter table agentic.skills       enable row level security;
alter table agentic.plugins      enable row level security;

create policy agents_are_shared_config on agentic.agents
    for select using (true);
create policy tool_servers_are_shared_config on agentic.tool_servers
    for select using (true);
create policy skills_are_shared_config on agentic.skills
    for select using (true);
create policy plugins_are_shared_config on agentic.plugins
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
-- Who may author agents and tool servers, and the case the first version of
-- this check got wrong.
--
-- The rule for an ordinary caller is unchanged: a permission row, checked
-- against the identity in the JWT. What it missed is that the FIRST agent in
-- any deployment is registered by a migration -- there is no end user at
-- initdb, `rbac.current_user_id()` is null, and a null holds no permissions,
-- so every seeded agent failed with "not authorized" and the documented write
-- path could not be used to install the sample that documents it.
--
-- The bootstrap branch is deliberately narrow: no end-user identity at all,
-- AND a session that could have written the row with a plain INSERT anyway.
-- The second half is what keeps this from being a hole -- `session_user` is
-- the login role, not the SECURITY DEFINER owner, so it is `authenticator`
-- for anything arriving over REST, and authenticator holds no table grant by
-- design. A caller who can already write the table gains nothing from being
-- refused here except a reason to bypass this function.
-- The table is a separate argument rather than derived from the resource
-- name. They happen to match today, and building one from the other would
-- make a permission-vocabulary string (an untyped tag, per user-rbac's header
-- note) silently load-bearing on a table name.
create or replace function agentic.may_author(p_resource text, p_table regclass)
returns boolean
language sql stable security definer
set search_path = pg_catalog, public
as $$
    select rbac.has_permission(rbac.current_user_id(), p_resource, 'update')
        or (rbac.current_user_id() is null
            -- `session_user` is a reserved SQL expression, not a function
            -- in a schema: qualifying it the way this file qualifies
            -- everything else fails to parse ("missing FROM-clause entry for
            -- table pg_catalog"). Bare is the only spelling, and it is safe
            -- for the same reason -- a keyword cannot be shadowed by a
            -- search_path.
            and pg_catalog.has_table_privilege(session_user, p_table, 'insert'));
$$;

create or replace function agentic.upsert_agent(p_spec jsonb)
returns agentic.agents
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_row    agentic.agents;
    v_tools  jsonb;
    v_skills jsonb;
    v_gap    text;
begin
    if not agentic.may_author('agents', 'agentic.agents'::regclass) then
        raise exception 'not authorized to author agents';
    end if;

    -- THE TOOL BINDING IS SHAPE-CHECKED HERE, because the near-miss spellings
    -- WIDEN it rather than failing.
    --
    -- A binding is {"server": "<name>", "tools": ["a","b"]}, and `tools: null`
    -- or an absent `tools` deliberately means "every tool this server
    -- exposes". So `{"server": "p8-query", "tool": "query"}` -- singular, the
    -- spelling anybody writes for one tool -- was stored verbatim, and the
    -- runtime, looking for `tools`, found nothing and handed the model the
    -- server's ENTIRE surface. One character, no error, and an allow-list that
    -- silently became its opposite. dev/examples/10-agent.sql documented this
    -- trap in a comment; a comment is not a guard, and the write path is where
    -- it belongs.
    --
    -- Unknown keys are refused for the same reason: every one of them is a
    -- narrowing the author believes they have expressed.
    if p_spec ? 'tools' and jsonb_typeof(p_spec->'tools') <> 'null' then
        if jsonb_typeof(p_spec->'tools') <> 'array' then
            raise exception
                'agent %: `tools` is %, where a list of server bindings was expected -- '
                '[{"server": "<name>", "tools": ["a","b"]}]',
                p_spec->>'name', jsonb_typeof(p_spec->'tools');
        end if;
        declare
            v_b   jsonb;
            v_bad text;
        begin
            for v_b in select * from jsonb_array_elements(p_spec->'tools') loop
                if jsonb_typeof(v_b) <> 'object' or not (v_b ? 'server')
                   or jsonb_typeof(v_b->'server') <> 'string' then
                    raise exception
                        'agent %: tool binding % names no server. Each binding is '
                        '{"server": "<name>", "tools": ["a","b"]}.',
                        p_spec->>'name', v_b;
                end if;
                select string_agg(k, ', ' order by k) into v_bad
                from jsonb_object_keys(v_b) k
                where k not in ('server', 'tools');
                if v_bad is not null then
                    raise exception
                        'agent %: tool binding for server % carries %, which this schema '
                        'does not read. The allow-list key is `tools` (a list); an entry '
                        'the runtime does not understand is not ignored, it leaves the '
                        'agent with EVERY tool that server exposes.',
                        p_spec->>'name', v_b->>'server', v_bad;
                end if;
                if v_b ? 'tools' and jsonb_typeof(v_b->'tools') not in ('array', 'null') then
                    raise exception
                        'agent %: the allow-list for server % is %, where a list of tool '
                        'names (or null for all of them) was expected.',
                        p_spec->>'name', v_b->>'server', jsonb_typeof(v_b->'tools');
                end if;
                if jsonb_typeof(v_b->'tools') = 'array'
                   and exists (select 1 from jsonb_array_elements(v_b->'tools') e
                               where jsonb_typeof(e) <> 'string') then
                    raise exception
                        'agent %: the allow-list for server % holds a non-string entry: %',
                        p_spec->>'name', v_b->>'server', v_b->'tools';
                end if;
            end loop;
        end;
    end if;

    -- THE PINNED SKILL LIST IS CHECKED HERE, and the check that earns its
    -- keep is the second one, not the first.
    --
    -- The first is ordinary: a name that matches no row is a typo, and a typo
    -- in this column is an agent that silently loses a third of its
    -- instructions -- no error, no missing tool, just a worse answer.
    --
    -- The second is the one a foreign key could never express. A skill
    -- declares the tool servers its instructions assume (skills.requires_tools),
    -- and an agent that pins "always answer retrieval questions with the
    -- `query` tool" while binding no server that offers `query` is an agent
    -- given instructions it cannot follow. That is worse than an unbound
    -- tool, because a tool it cannot see is a tool it does not try: prose it
    -- cannot act on is prose it will act on anyway, badly. Refused at author
    -- time, where the fix is one line, rather than surfaced as a confusing
    -- run three days later.
    --
    -- BOTH CHECKS RUN AGAINST THE AGENT THIS UPSERT WILL PRODUCE, not against
    -- the document it was handed, and that distinction is the whole of the
    -- second one. Written the obvious way -- validate `skills` when `skills`
    -- is present -- it passes the test it was written for and misses the edit
    -- that actually breaks an agent: `{"name": "a1", "tools": []}` carries no
    -- `skills` key at all, so the check never runs, and the agent keeps a
    -- pinned skill whose server it no longer binds. Found by trying it, one
    -- statement after the refusal above worked.
    if (p_spec ? 'skills') or (p_spec ? 'tools') then
        if p_spec ? 'skills' and jsonb_typeof(p_spec->'skills') not in ('array','null') then
            raise exception
                'agent %: `skills` is %, where a list of skill names was expected -- '
                '["p8ql-authoring", "workflow-yaml"]',
                p_spec->>'name', jsonb_typeof(p_spec->'skills');
        end if;
        if p_spec ? 'skills'
           and exists (select 1 from jsonb_array_elements(p_spec->'skills') e
                        where jsonb_typeof(e) <> 'string') then
            raise exception
                'agent %: `skills` holds a non-string entry: %. A pinned skill is '
                'named, never inlined -- the text lives in agentic.skills so that '
                'editing it once changes every agent that pins it.',
                p_spec->>'name', p_spec->'skills';
        end if;

        select coalesce(nullif(p_spec->'skills', 'null'::jsonb),
                        (select to_jsonb(a.skills) from agentic.agents a
                          where a.name = p_spec->>'name'),
                        '[]'::jsonb),
               coalesce(p_spec->'tools',
                        (select a.tools from agentic.agents a
                          where a.name = p_spec->>'name'),
                        '[]'::jsonb)
          into v_skills, v_tools;

        select string_agg(k, ', ' order by k) into v_gap
          from jsonb_array_elements_text(v_skills) k
         where not exists (select 1 from agentic.skills sk where sk.name = k);
        if v_gap is not null then
            raise exception
                'agent %: pins skill(s) % which do not exist. A pinned skill is '
                'read into the prompt at every invocation; a name that resolves to '
                'nothing is instructions the agent silently never receives.',
                p_spec->>'name', v_gap;
        end if;

        select string_agg(distinct sk.name || ' needs ' || r, ', ') into v_gap
          from jsonb_array_elements_text(v_skills) k
          join agentic.skills sk on sk.name = k
          cross join lateral unnest(sk.requires_tools) r
         where not exists (select 1 from jsonb_array_elements(v_tools) b
                            where b->>'server' = r);
        if v_gap is not null then
            raise exception
                'agent %: % -- a tool server this agent does not bind. Bind it, '
                'unpin the skill, or do not remove the binding.',
                p_spec->>'name', v_gap;
        end if;
    end if;

    -- Every column an author can set, including the classification block.
    -- Leaving audience/category out of this list -- which is how it was first
    -- written, because they were added to the table later -- does not fail: it
    -- silently defaults every agent to `internal`/`general`, so an agent
    -- authored as user-facing is accepted, reported as created, and then never
    -- appears in `agents_pickable`. A write path that cannot express a column
    -- the table has is a write path that quietly disagrees with its own schema.
    insert into agentic.agents (name, system_prompt, model, tools, skills,
                                structured_output_schema, chained_action,
                                summarizer_agent_id, context_policy,
                                audience, category, tags,
                                extracts_source, extracts_doctype, plugin)
    values (p_spec->>'name',
            coalesce(p_spec->>'system_prompt', ''),
            p_spec->>'model',
            coalesce(p_spec->'tools', '[]'::jsonb),
            coalesce((select array_agg(value)
                        from jsonb_array_elements_text(p_spec->'skills')), '{}'),
            p_spec->'structured_output_schema',
            p_spec->'chained_action',
            (p_spec->>'summarizer_agent_id')::uuid,
            coalesce(p_spec->'context_policy', '{}'::jsonb),
            coalesce(p_spec->>'audience', 'internal'),
            coalesce(p_spec->>'category', 'general'),
            coalesce((select array_agg(value)
                        from jsonb_array_elements_text(p_spec->'tags')), '{}'),
            p_spec->>'extracts_source',
            p_spec->>'extracts_doctype',
            p_spec->>'plugin')
    -- AN OMITTED KEY MEANS "LEAVE IT ALONE", NOT "SET IT TO THE DEFAULT".
    --
    -- Written the obvious way -- `set x = excluded.x` for every column -- this
    -- is a silent, total data-loss bug, and it fires on the most ordinary edit
    -- there is. `{"name": "percolate", "model": "openai:gpt-4.1-mini"}` is how
    -- anyone changes an agent's model. `excluded` carries the column DEFAULT
    -- for every key the caller did not send, so that call returned 200 and
    -- left the agent with an empty system prompt and no tools at all: the
    -- agent still existed, still resolved by name, and could do nothing.
    --
    -- Found by doing it. It is the same mistake as upsert_tool_server erasing
    -- cached_tools, which was fixed one function away and not here -- twice
    -- now this schema has shipped a partial write that reports success, so the
    -- rule is stated once and applied to every column: the presence of the KEY
    -- decides, never the emptiness of the value.
    on conflict (name) do update
       set system_prompt            = case when p_spec ? 'system_prompt'
                                      then excluded.system_prompt
                                      else agentic.agents.system_prompt end,
           model                    = case when p_spec ? 'model'
                                      then excluded.model
                                      else agentic.agents.model end,
           tools                    = case when p_spec ? 'tools'
                                      then excluded.tools
                                      else agentic.agents.tools end,
           skills                   = case when p_spec ? 'skills'
                                      then excluded.skills
                                      else agentic.agents.skills end,
           structured_output_schema = case when p_spec ? 'structured_output_schema'
                                      then excluded.structured_output_schema
                                      else agentic.agents.structured_output_schema end,
           chained_action           = case when p_spec ? 'chained_action'
                                      then excluded.chained_action
                                      else agentic.agents.chained_action end,
           summarizer_agent_id      = case when p_spec ? 'summarizer_agent_id'
                                      then excluded.summarizer_agent_id
                                      else agentic.agents.summarizer_agent_id end,
           context_policy           = case when p_spec ? 'context_policy'
                                      then excluded.context_policy
                                      else agentic.agents.context_policy end,
           audience                 = case when p_spec ? 'audience'
                                      then excluded.audience
                                      else agentic.agents.audience end,
           category                 = case when p_spec ? 'category'
                                      then excluded.category
                                      else agentic.agents.category end,
           tags                     = case when p_spec ? 'tags'
                                      then excluded.tags
                                      else agentic.agents.tags end,
           extracts_source          = case when p_spec ? 'extracts_source'
                                      then excluded.extracts_source
                                      else agentic.agents.extracts_source end,
           extracts_doctype         = case when p_spec ? 'extracts_doctype'
                                      then excluded.extracts_doctype
                                      else agentic.agents.extracts_doctype end,
           plugin                   = case when p_spec ? 'plugin'
                                      then excluded.plugin
                                      else agentic.agents.plugin end
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
    if not agentic.may_author('tool_servers', 'agentic.tool_servers'::regclass) then
        raise exception 'not authorized to register tool servers';
    end if;

    insert into agentic.tool_servers (name, kind, url, credential_ref,
                                      emits_citations, serves_agents,
                                      serves_skills, default_headers,
                                      cached_tools, synced_at, plugin)
    -- kind and url are NOT NULL, so unlike every other column here they
    -- cannot be left to the ON CONFLICT arm: the tuple has to be VALID before
    -- Postgres will even look for the conflict, and a partial registration
    -- naming only the url therefore failed with a null-constraint violation on
    -- `kind` -- from an UPDATE path that would never have touched it. The
    -- existing row supplies them, which makes "omitted means unchanged" true
    -- on both arms rather than only on the one that is easy to write.
    values (p_spec->>'name',
            coalesce(p_spec->>'kind',
                     (select s.kind from agentic.tool_servers s
                       where s.name = p_spec->>'name')),
            coalesce(p_spec->>'url',
                     (select s.url from agentic.tool_servers s
                       where s.name = p_spec->>'name')),
            p_spec->>'credential_ref',
            coalesce((p_spec->>'emits_citations')::boolean, false),
            coalesce((p_spec->>'serves_agents')::boolean, false),
            coalesce((p_spec->>'serves_skills')::boolean, false),
            coalesce(p_spec->'default_headers', '{}'::jsonb),
            coalesce(p_spec->'cached_tools', '[]'::jsonb),
            case when p_spec ? 'cached_tools' then now() end,
            p_spec->>'plugin')
    -- Same rule as upsert_agent, and it reached every column here for the
    -- same reason: `cached_tools` was fixed alone because that is the column
    -- whose loss was noticed, while a registration omitting `credential_ref`
    -- or `default_headers` was quietly clearing those too -- and an unset
    -- credential_ref is what makes the NEXT sync anonymous and half-empty.
    on conflict (name) do update
       set kind            = case when p_spec ? 'kind'
                                  then excluded.kind
                                  else agentic.tool_servers.kind end,
           url             = case when p_spec ? 'url'
                                  then excluded.url
                                  else agentic.tool_servers.url end,
           credential_ref  = case when p_spec ? 'credential_ref'
                                  then excluded.credential_ref
                                  else agentic.tool_servers.credential_ref end,
           emits_citations = case when p_spec ? 'emits_citations'
                                  then excluded.emits_citations
                                  else agentic.tool_servers.emits_citations end,
           serves_agents   = case when p_spec ? 'serves_agents'
                                  then excluded.serves_agents
                                  else agentic.tool_servers.serves_agents end,
           serves_skills   = case when p_spec ? 'serves_skills'
                                  then excluded.serves_skills
                                  else agentic.tool_servers.serves_skills end,
           plugin          = case when p_spec ? 'plugin'
                                  then excluded.plugin
                                  else agentic.tool_servers.plugin end,
           default_headers = case when p_spec ? 'default_headers'
                                  then excluded.default_headers
                                  else agentic.tool_servers.default_headers end,
           cached_tools    = case when p_spec ? 'cached_tools'
                                  then excluded.cached_tools
                                  else agentic.tool_servers.cached_tools end,
           synced_at       = coalesce(excluded.synced_at, agentic.tool_servers.synced_at)
    returning * into v_row;
    return v_row;
end;
$$;

-- Skills are written the same way agents are: authored in code or YAML,
-- applied as a migration, never edited in a running database (brief.md §6,
-- §11.8's second bullet).
--
-- `description` and `content` are NOT NULL, so they cannot be left to the ON
-- CONFLICT arm the way a nullable column can -- the tuple has to be valid
-- before Postgres will look for the conflict at all. The existing row supplies
-- them, which is what makes "an omitted key means leave it alone" true on both
-- arms rather than only on the one that is easy to write. Learned in
-- upsert_tool_server, applied here rather than rediscovered.
create or replace function agentic.upsert_skill(p_spec jsonb)
returns agentic.skills
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_row agentic.skills;
begin
    if not agentic.may_author('skills', 'agentic.skills'::regclass) then
        raise exception 'not authorized to author skills';
    end if;

    insert into agentic.skills (name, description, when_to_use, content,
                                requires_tools, audience, category, tags, plugin)
    values (p_spec->>'name',
            coalesce(p_spec->>'description',
                     (select k.description from agentic.skills k
                       where k.name = p_spec->>'name')),
            p_spec->>'when_to_use',
            coalesce(p_spec->>'content',
                     (select k.content from agentic.skills k
                       where k.name = p_spec->>'name')),
            coalesce((select array_agg(value)
                        from jsonb_array_elements_text(p_spec->'requires_tools')), '{}'),
            coalesce(p_spec->>'audience', 'internal'),
            coalesce(p_spec->>'category', 'procedure'),
            coalesce((select array_agg(value)
                        from jsonb_array_elements_text(p_spec->'tags')), '{}'),
            p_spec->>'plugin')
    on conflict (name) do update
       set description    = case when p_spec ? 'description'
                                 then excluded.description
                                 else agentic.skills.description end,
           when_to_use    = case when p_spec ? 'when_to_use'
                                 then excluded.when_to_use
                                 else agentic.skills.when_to_use end,
           content        = case when p_spec ? 'content'
                                 then excluded.content
                                 else agentic.skills.content end,
           requires_tools = case when p_spec ? 'requires_tools'
                                 then excluded.requires_tools
                                 else agentic.skills.requires_tools end,
           audience       = case when p_spec ? 'audience'
                                 then excluded.audience
                                 else agentic.skills.audience end,
           category       = case when p_spec ? 'category'
                                 then excluded.category
                                 else agentic.skills.category end,
           tags           = case when p_spec ? 'tags'
                                 then excluded.tags
                                 else agentic.skills.tags end,
           plugin         = case when p_spec ? 'plugin'
                                 then excluded.plugin
                                 else agentic.skills.plugin end,
           -- The version bump is why this is a function and not an INSERT.
           -- A body that changed while the version did not is a run whose
           -- recorded provenance points at text that no longer exists, and
           -- nothing downstream can detect that it is looking at the wrong
           -- thing. Only the three fields a model actually reads count as a
           -- change; retagging a skill is not a new version of it.
           version        = agentic.skills.version + case
               when (p_spec ? 'content'     and excluded.content     is distinct from agentic.skills.content)
                 or (p_spec ? 'description' and excluded.description is distinct from agentic.skills.description)
                 or (p_spec ? 'when_to_use' and excluded.when_to_use is distinct from agentic.skills.when_to_use)
               then 1 else 0 end
    returning * into v_row;
    return v_row;
end;
$$;

-- Attaching a skill to an agent, in the database, as ONE statement.
--
-- Without this the only way to add a fragment to an agent is read-modify-write
-- through upsert_agent: read `skills`, append, send the whole array back. That
-- is a lost update waiting to happen, and not a theoretical one -- two clients
-- attaching two different fragments to one agent both read the same array and
-- the second write silently discards the first. No error, no conflict, and an
-- agent that is missing instructions somebody watched themselves add. It is
-- the same class of failure as upsert_agent's `excluded` bug, one layer up:
-- a partial write that reports success.
--
-- Three properties, and each is a decision:
--
--   IN PLACE.   The array is appended to under a row lock (`for update`
--               below), so concurrent attaches to one agent serialize instead
--               of clobbering. This is the whole reason the function exists;
--               a version without the lock would be sugar over the bug.
--
--   ONE PATH.   It does not write `agents` itself. It computes the new array
--               and hands it to upsert_agent, so the checks that refuse an
--               unknown skill or an unbound requires_tools server (§5) run
--               here too, in exactly one place. A second write path with its
--               own copy of the validation is how the two drift apart.
--
--   IDEMPOTENT. Attaching what is already attached changes nothing and is not
--               an error. Order is meaningful -- composed fragments are
--               concatenated in listed order -- so a new one appends at the
--               end rather than being sorted in.
--
-- `p_spec` is what makes this one call rather than two: pass it and the
-- fragment is authored (or updated) and attached together, which is what the
-- REST path needs since PostgREST is one function per request.
create or replace function agentic.attach_skill(
    p_agent text, p_skill text, p_spec jsonb default null)
returns agentic.agents
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_skills text[];
begin
    -- Not upsert_agent's job to notice: called with {name, skills} for an
    -- agent that does not exist, it would happily CREATE one with an empty
    -- prompt and no tools -- an agent that resolves by name and can do
    -- nothing. Attaching to something absent is a typo, so it is refused here.
    select a.skills into v_skills
      from agentic.agents a where a.name = p_agent
      for update;
    if not found then
        raise exception
            'no agent named % -- attach_skill adds a fragment to an agent that '
            'exists, it does not create one.', p_agent;
    end if;

    if p_spec is not null then
        -- The name is an argument AND may appear in the spec. Refused rather
        -- than resolved: whichever one we picked, the other is what somebody
        -- believed they had written.
        if p_spec ? 'name' and p_spec->>'name' is distinct from p_skill then
            raise exception
                'attach_skill: the skill is named % in the argument and % in the '
                'spec. Name it once.', p_skill, p_spec->>'name';
        end if;
        perform agentic.upsert_skill(p_spec || jsonb_build_object('name', p_skill));
    end if;

    if not (p_skill = any(coalesce(v_skills, '{}'))) then
        v_skills := coalesce(v_skills, '{}') || p_skill;
    end if;

    -- Only the two keys, so every other column keeps the "an omitted key means
    -- leave it alone" behaviour upsert_agent already guarantees.
    return agentic.upsert_agent(jsonb_build_object(
        'name', p_agent,
        'skills', to_jsonb(v_skills)));
end;
$$;

-- The other half, and it exists so that removing a fragment is not the one
-- operation left doing read-modify-write. Detaching what was never attached is
-- a no-op rather than an error: the caller's intent -- that this agent does
-- not carry this fragment -- is satisfied either way.
create or replace function agentic.detach_skill(p_agent text, p_skill text)
returns agentic.agents
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_skills text[];
begin
    select a.skills into v_skills
      from agentic.agents a where a.name = p_agent
      for update;
    if not found then
        raise exception 'no agent named %', p_agent;
    end if;

    select coalesce(array_agg(s order by ord), '{}') into v_skills
      from unnest(coalesce(v_skills, '{}')) with ordinality t(s, ord)
     where s <> p_skill;

    return agentic.upsert_agent(jsonb_build_object(
        'name', p_agent,
        'skills', to_jsonb(v_skills)));
end;
$$;

-- Applying a plugin: one document, one transaction, and -- the half that did
-- not exist before -- a PRUNE.
--
-- An upsert-only apply is how a bundle rots: an agent dropped from the
-- manifest stays installed, still resolvable by name, still runnable, and now
-- nothing on disk describes it. So a row carrying this plugin's name and
-- absent from this manifest is removed, and the removals are reported rather
-- than done quietly.
--
-- WHICH MAKES AN ABSENT SECTION LOUD, deliberately: `{"name": "x"}` with no
-- `agents` key declares no agents and therefore removes every agent x
-- installed. That is what makes uninstall expressible at all -- there is no
-- second function for it -- and it is a trap for anyone writing a partial
-- document, so it is stated here and in plugins.md §9 rather than left to be
-- discovered.
--
-- Order is not cosmetic. Servers before skills before agents, because an
-- agent's pinned skills must already exist for upsert_agent to validate them,
-- and a skill's requires_tools names servers the agent must already bind.
create or replace function agentic.apply_plugin(p_manifest jsonb)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_name    text := p_manifest->>'name';
    v_servers text[];
    v_skills  text[];
    v_agents  text[];
    v_e       jsonb;
    v_gone    text[] := '{}';
    v_batch   text[];
    v_gap     text;
begin
    if v_name is null then
        raise exception
            'a plugin manifest must carry a name -- {"name": "...", "version": "...", '
            '"tool_servers": [...], "skills": [...], "agents": [...]}. The name is '
            'what makes the rows removable later.';
    end if;
    if not agentic.may_author('plugins', 'agentic.plugins'::regclass) then
        raise exception 'not authorized to install plugins';
    end if;

    v_servers := coalesce((select array_agg(e->>'name')
                             from jsonb_array_elements(
                                  coalesce(p_manifest->'tool_servers', '[]'::jsonb)) e), '{}');
    v_skills  := coalesce((select array_agg(e->>'name')
                             from jsonb_array_elements(
                                  coalesce(p_manifest->'skills', '[]'::jsonb)) e), '{}');
    v_agents  := coalesce((select array_agg(e->>'name')
                             from jsonb_array_elements(
                                  coalesce(p_manifest->'agents', '[]'::jsonb)) e), '{}');

    insert into agentic.plugins (name, version, description, author, homepage, manifest)
    values (v_name, coalesce(p_manifest->>'version', '0.0.0'),
            p_manifest->>'description', p_manifest->'author',
            p_manifest->>'homepage', p_manifest)
    on conflict (name) do update
       set version     = excluded.version,
           description = excluded.description,
           author      = excluded.author,
           homepage    = excluded.homepage,
           manifest    = excluded.manifest;

    for v_e in select * from jsonb_array_elements(
                            coalesce(p_manifest->'tool_servers', '[]'::jsonb)) loop
        perform agentic.upsert_tool_server(v_e || jsonb_build_object('plugin', v_name));
    end loop;
    for v_e in select * from jsonb_array_elements(
                            coalesce(p_manifest->'skills', '[]'::jsonb)) loop
        perform agentic.upsert_skill(v_e || jsonb_build_object('plugin', v_name));
    end loop;
    for v_e in select * from jsonb_array_elements(
                            coalesce(p_manifest->'agents', '[]'::jsonb)) loop
        perform agentic.upsert_agent(v_e || jsonb_build_object('plugin', v_name));
    end loop;

    -- Agents first: nothing in this schema references an agent except a RUN,
    -- and a run is history. Deleting an agent that has answered something is
    -- refused by the foreign key, which is correct and says so badly, so it is
    -- caught and re-raised as the thing the author actually has to decide.
    begin
        with d as (delete from agentic.agents
                    where plugin = v_name and not (name = any(v_agents))
                returning name)
        select coalesce(array_agg('agent:' || name), '{}') into v_batch from d;
        v_gone := v_gone || v_batch;
    exception when foreign_key_violation then
        raise exception
            'plugin %: an agent this manifest no longer declares has runs against it, '
            'so removing it would delete conversation history. Keep it in the manifest, '
            'or delete its runs first -- this function will not decide that for you.',
            v_name;
    end;

    -- A skill pinned by an agent from ANOTHER plugin is not this manifest's to
    -- remove. There is no foreign key to stop it: agents.skills is a list of
    -- names, which is what lets one skill serve many agents, and the price is
    -- that referential integrity is a check here rather than a constraint
    -- there. Uncaught, this is the quietest failure in the whole schema -- the
    -- agent keeps working and quietly loses a third of its instructions.
    select string_agg(distinct k.name || ' (pinned by ' || a.name || ')', ', ')
      into v_gap
      from agentic.skills k
      join agentic.agents a on k.name = any(a.skills)
     where k.plugin = v_name and not (k.name = any(v_skills));
    if v_gap is not null then
        raise exception
            'plugin %: cannot remove % -- unpin it first, or keep it in the manifest.',
            v_name, v_gap;
    end if;

    with d as (delete from agentic.skills
                where plugin = v_name and not (name = any(v_skills))
            returning name)
    select coalesce(array_agg('skill:' || name), '{}') into v_batch from d;
    v_gone := v_gone || v_batch;

    -- Same shape for servers, and the same absence of a foreign key:
    -- agents.tools holds server NAMES in JSONB.
    select string_agg(distinct t.name || ' (bound by ' || a.name || ')', ', ')
      into v_gap
      from agentic.tool_servers t
      join agentic.agents a
        on exists (select 1 from jsonb_array_elements(a.tools) b
                    where b->>'server' = t.name)
     where t.plugin = v_name and not (t.name = any(v_servers));
    if v_gap is not null then
        raise exception
            'plugin %: cannot remove % -- rebind it first, or keep it in the manifest.',
            v_name, v_gap;
    end if;

    with d as (delete from agentic.tool_servers
                where plugin = v_name and not (name = any(v_servers))
            returning name)
    select coalesce(array_agg('server:' || name), '{}') into v_batch from d;
    v_gone := v_gone || v_batch;

    return jsonb_build_object(
        'plugin',       v_name,
        'version',      coalesce(p_manifest->>'version', '0.0.0'),
        'tool_servers', to_jsonb(v_servers),
        'skills',       to_jsonb(v_skills),
        'agents',       to_jsonb(v_agents),
        'removed',      to_jsonb(v_gone));
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
-- `default_headers` is in the view for the same reason and by the same rule:
-- the constraint on the table guarantees it holds no secret, and a caller that
-- cannot see it cannot reach the document it was registered against -- the
-- identical failure, one layer along.
create view agentic.tool_servers_api as
    select id, name, kind, url, credential_ref, emits_citations, serves_agents,
           serves_skills, default_headers, cached_tools, synced_at, plugin,
           created_at
      from agentic.tool_servers;

-- Skills, through the same read path as everything else. `content` is IN this
-- view: the runtime loads a pinned skill's body over REST like every other
-- client (brief.md §10.2), so a view that showed the listing and hid the body
-- would be a view that cannot serve the one call it exists for.
--
-- What a LISTING costs is therefore a projection the caller chooses
-- (`?select=name,description,when_to_use`), not a second view -- because the
-- two differ only in columns, and a second view is a second place to forget a
-- column when one is added. discovery_text is here for the same reason the
-- embedding job needs it and nobody else does: it is generated, so it cannot
-- disagree with the columns beside it.
create view agentic.skills_api as
    select id, name, description, when_to_use, content, discovery_text,
           requires_tools, audience, category, tags, version, plugin,
           created_at, updated_at
      from agentic.skills;

-- The manifest is in the view on purpose: "what did this plugin install" is a
-- question asked when something is wrong, and answering it from the document
-- as applied rather than from the rows is how you find the row that was
-- edited in place afterwards (brief.md §11.8).
create view agentic.plugins_api as
    select name, version, description, author, homepage, manifest,
           installed_at, updated_at
      from agentic.plugins;
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

-- The classification columns are in the view because the runtime reads agents
-- through it, and they are the columns that say what an agent IS FOR. Left out
-- (as they were, having been added to the table later) a client can see every
-- agent and sort them by nothing -- the state the classification block was
-- added to end, undone one layer along.
--
-- extracts_source/extracts_doctype belong here for the same reason and were
-- missed on the first pass anyway, which is the argument for checking this
-- mechanically rather than carefully: they are how a caller answers "which
-- extractor owns this document", and surface.sql's round-trip check found them
-- the first time it ran.
-- `skills` is in this view for the reason the classification columns are, and
-- it is the same mistake one column along if it is not: the runtime reads
-- agents through this view, so a pinned skill invisible here is a pinned skill
-- the runtime never loads -- an agent configured with instructions it silently
-- does not receive, which is precisely the failure the author-time check in
-- upsert_agent exists to prevent, reintroduced at the read path.
create view agentic.agents_api as
    select id, name, system_prompt, model, tools, skills,
           structured_output_schema,
           chained_action, summarizer_agent_id, context_policy,
           audience, category, tags, extracts_source, extracts_doctype,
           plugin, created_at
      from agentic.agents;

grant select on agentic.sessions, agentic.runs, agentic.messages,
                agentic.agents, agentic.tool_servers,
                agentic.skills, agentic.plugins to api_viewer;
grant execute on function rbac.current_user_id() to api_viewer;

-- Temporary CREATE, exactly as user-rbac does it: needed only for the
-- ownership transfer, revoked immediately after.
grant create on schema agentic to api_viewer;
alter view agentic.sessions_api     owner to api_viewer;
alter view agentic.runs_api         owner to api_viewer;
alter view agentic.messages_api     owner to api_viewer;
alter view agentic.tool_servers_api owner to api_viewer;
alter view agentic.agents_api       owner to api_viewer;
alter view agentic.skills_api       owner to api_viewer;
alter view agentic.plugins_api      owner to api_viewer;
revoke create on schema agentic from api_viewer;

grant select on agentic.sessions_api, agentic.runs_api, agentic.messages_api,
                agentic.tool_servers_api, agentic.agents_api,
                agentic.skills_api, agentic.plugins_api to authenticated;

grant execute on function agentic.create_session(text) to authenticated;
grant execute on function agentic.start_run(text, uuid, uuid, uuid, text, text, text, uuid)
    to authenticated;
grant execute on function agentic.finish_run(uuid, text, jsonb) to authenticated;
grant execute on function agentic.persist_turn(jsonb) to authenticated;
grant execute on function agentic.upsert_summary(uuid, text) to authenticated;
grant execute on function agentic.apply_summary(jsonb) to authenticated;
grant execute on function agentic.upsert_agent(jsonb) to authenticated;
grant execute on function agentic.upsert_tool_server(jsonb) to authenticated;
grant execute on function agentic.upsert_skill(jsonb) to authenticated;
grant execute on function agentic.attach_skill(text, text, jsonb) to authenticated;
grant execute on function agentic.detach_skill(text, text) to authenticated;
grant execute on function agentic.apply_plugin(jsonb) to authenticated;
grant execute on function agentic.channel_for(uuid) to authenticated, api_viewer;

-- AND THE PUBLIC DEFAULT, TAKEN AWAY -- because the twelve grants above are
-- what this plane MEANS, and until this block existed they were not what it
-- SAID. Postgres grants EXECUTE on a new function to PUBLIC unless you remove
-- it, so each ACL above read `=X/app_owner | authenticated=X/app_owner`: the
-- explicit grant, plus everybody. `web_anon` holds USAGE on this schema
-- (§9, the anonymous read path), so every authoring entry point here was
-- reachable unauthenticated, with `may_author` as the only thing between an
-- anonymous request and a write that runs as the engine owner.
--
-- That check does hold -- verified by calling upsert_agent over REST with no
-- token, which returns "not authorized to author agents". Depth is the point:
-- workflow-engine/integration-rbac.sql §6 already argues that granting is not
-- the same as scoping, and this is the same argument applied to the plane that
-- was written after it. Nothing here loses a caller it had; every one of these
-- names its callers on the line above.
revoke execute on function agentic.create_session(text) from public;
revoke execute on function agentic.start_run(text, uuid, uuid, uuid, text, text, text, uuid) from public;
revoke execute on function agentic.finish_run(uuid, text, jsonb) from public;
revoke execute on function agentic.persist_turn(jsonb) from public;
revoke execute on function agentic.upsert_summary(uuid, text) from public;
revoke execute on function agentic.apply_summary(jsonb) from public;
revoke execute on function agentic.upsert_agent(jsonb) from public;
revoke execute on function agentic.upsert_tool_server(jsonb) from public;
revoke execute on function agentic.upsert_skill(jsonb) from public;
revoke execute on function agentic.attach_skill(text, text, jsonb) from public;
revoke execute on function agentic.detach_skill(text, text) from public;
revoke execute on function agentic.apply_plugin(jsonb) from public;
revoke execute on function agentic.may_author(text, regclass) from public;

-- No base-table INSERT/UPDATE/DELETE grant to any PostgREST-facing role: the
-- write path is the functions above, and nothing else.

-- ============================================================
-- 9b. The plan-graph facet -- an agent's reach, as data
--
-- A read surface like §9 above and numbered under it for that reason: these
-- two views add no capability, they answer one question about rows §9 already
-- exposes -- what does this agent reach, and can it.
--
-- workflow-engine's plan graph (workflow-engine/plan-graph.md) expands a stored
-- workflow along the entities it names, and an `agent:` step names one row in
-- this schema whose own reach is three more joins: the servers it binds, the
-- tools it is narrowed to on each, and -- through a server with
-- `serves_agents` -- the agents it may hand work to. Those joins live HERE
-- rather than in the engine, because the engine must be deployable without
-- this schema at all: workflow.plan_catalog() calls this function only if it
-- exists, the same conditional integration define_yaml already uses for
-- aiq.expand_embed_steps.
--
-- Both views read only shared configuration. `agents` and `tool_servers` carry
-- `for select using (true)` policies (§7), so nothing here can show a caller a
-- row it could not select directly, and neither view touches `sessions`,
-- `runs` or `messages` -- the three tables in this schema that are per-user.
-- ============================================================

create or replace view agentic.v_plan_agents as
select a.name,
       a.category,
       a.audience,
       a.model,
       -- THE WHOLE PROMPT, not a preview of it. An agent's intent IS its
       -- prompt, and this view exists so a plan can be read for intent -- a
       -- truncation makes every agent look like every other agent, which is
       -- the failure mode the expansion is for.
       a.system_prompt,
       -- The SHAPE it must return, curated to what a reader needs: the
       -- required keys and each property's type. The full JSON Schema is one
       -- select away and is mostly boilerplate; what tells you whether N
       -- results will combine is the key list.
       case when a.structured_output_schema is null then null else
           jsonb_build_object(
               'required', coalesce(a.structured_output_schema->'required', '[]'::jsonb),
               'properties', coalesce((
                   select jsonb_object_agg(k, coalesce(v->>'type', 'any'))
                     from jsonb_each(coalesce(
                              a.structured_output_schema->'properties', '{}'::jsonb)) e(k, v)), 
                   '{}'::jsonb))
       end as output_shape,
       a.structured_output_schema is not null as has_output_schema,
       nullif(a.context_policy, '{}'::jsonb) as context_policy,
       s.name as summarizer,
       a.tools,
       -- THE PINNED SKILL BODIES, whole, for the same reason system_prompt is
       -- whole one column up: a pinned skill IS part of this agent's prompt --
       -- the runtime concatenates it in at invocation -- so a plan that shows
       -- the name and not the text shows the citation and hides the argument.
       -- Named `skills` rather than expanded into the prompt column because a
       -- reader has to be able to see which part is shared and which part is
       -- this agent's own.
       coalesce((select jsonb_object_agg(k.name, jsonb_build_object(
                            'version', k.version,
                            'description', k.description,
                            'content', k.content))
                   from agentic.skills k
                  where k.name = any(a.skills)), '{}'::jsonb) as skills
  from agentic.agents a
  left join agentic.agents s on s.id = a.summarizer_agent_id;

create or replace view agentic.v_plan_servers as
select t.name,
       t.kind,
       t.url,
       t.emits_citations,
       t.serves_agents,
       t.serves_skills,
       t.synced_at,
       -- The tool NAMES discovery wrote, which is what an allow-list is checked
       -- against. A server that has never synced has `[]` here and a null
       -- synced_at, and the graph reports those as two different things: an
       -- empty list means "we asked and it exposes nothing", a null sync means
       -- "nobody has asked yet", and only the first is evidence about the tools.
       coalesce((select jsonb_agg(e->>'name' order by e->>'name')
                   from jsonb_array_elements(t.cached_tools) e
                  where e ? 'name'), '[]'::jsonb) as tools,
       -- WHAT EACH TOOL SAYS IT DOES, which is the half of a binding that
       -- carries intent. The description is the text the MODEL reads before
       -- deciding to call it, so a plan that shows the tool name and not this
       -- shows the part nobody needs. Parameters are named, not schema'd: the
       -- argument names are what make a tool recognisable, and the types are
       -- one fetch away for anybody who needs them.
       coalesce((select jsonb_object_agg(e->>'name', jsonb_build_object(
                            'description', e->>'description',
                            'params', coalesce((
                                select jsonb_agg(k order by k)
                                  from jsonb_object_keys(coalesce(
                                       e#>'{inputSchema,properties}',
                                       e#>'{input_schema,properties}',
                                       '{}'::jsonb)) k), '[]'::jsonb)))
                   from jsonb_array_elements(t.cached_tools) e
                  where e ? 'name'), '{}'::jsonb) as tool_detail
  from agentic.tool_servers t;

-- One object per section, keyed by name, which is the shape p8_plan_graph
-- reads. Built with jsonb_object_agg rather than handed over as rows because
-- the graph builder does lookups, not scans -- and because a section that is
-- ABSENT means "this subsystem is not installed" there, a distinction an empty
-- rowset could not carry.
create or replace function agentic.plan_facet()
returns jsonb
language sql
stable
as $$
    select jsonb_build_object(
        'agents', coalesce((
            select jsonb_object_agg(name, jsonb_strip_nulls(jsonb_build_object(
                'category', category, 'audience', audience, 'model', model,
                'system_prompt', system_prompt, 'output_shape', output_shape,
                'has_output_schema', has_output_schema,
                'context_policy', context_policy,
                'summarizer', summarizer, 'tools', tools,
                'skills', nullif(skills, '{}'::jsonb))))
              from agentic.v_plan_agents), '{}'::jsonb),
        'servers', coalesce((
            select jsonb_object_agg(name, jsonb_build_object(
                'kind', kind, 'url', url, 'emits_citations', emits_citations,
                'serves_agents', serves_agents, 'serves_skills', serves_skills,
                'synced_at', synced_at,
                'tools', tools, 'tool_detail', tool_detail))
              from agentic.v_plan_servers), '{}'::jsonb),
        -- Every skill, whether or not an agent pins it, because the population
        -- a plan reader needs to see includes the ones nobody pinned yet --
        -- that is how you notice a skill written and never bound. Listings
        -- only: the bodies of the pinned ones are already under their agent,
        -- and the rest would make this document unreadable at a thousand rows.
        'skills', coalesce((
            select jsonb_object_agg(name, jsonb_strip_nulls(jsonb_build_object(
                'description', description, 'when_to_use', when_to_use,
                'category', category, 'audience', audience,
                'version', version, 'requires_tools', to_jsonb(requires_tools))))
              from agentic.skills), '{}'::jsonb));
$$;

grant select on agentic.v_plan_agents, agentic.v_plan_servers to authenticated;
grant execute on function agentic.plan_facet() to authenticated;

comment on function agentic.plan_facet() is
    'The agentic half of workflow.plan_catalog(): every agent, tool server and '
    'skill, keyed by name, in the shape p8_plan_graph reads. Shared config only.';

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
