-- Test-only fixtures for the agentic runtime experiment.
--
-- NOT part of the spec: a real deployment provisions users through
-- user-rbac's own flows. This exists so the runtime can be exercised as a
-- real `authenticated` caller with real RLS, which is the only way the
-- "runtime is just another client" claim (brief.md §5) can be checked.

insert into rbac.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'runtime@test.local')
on conflict (email) do nothing;

insert into rbac.roles (name) values ('agent_author') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'agent_author')
on conflict do nothing;

-- brief.md §6: authoring an agent is a migration, and a migration runs as
-- someone. These are the two permissions agentic.upsert_agent() and
-- agentic.upsert_tool_server() check.
insert into rbac.role_permissions (role, resource, action) values
  ('agent_author', 'agents', 'update'),
  ('agent_author', 'tool_servers', 'update')
on conflict do nothing;

-- A second user, owning nothing, for checking that a conversation is not
-- visible across tenants (sequence.md Gate 1).
insert into rbac.users (id, email) values
  ('bbbbbbbb-0000-0000-0000-000000000002', 'other@test.local')
on conflict (email) do nothing;

-- ------------------------------------------------------------
-- The reference background workflow (brief.md §3): one async http_call step
-- dispatched at the runtime's internal trigger endpoint. Deliberately the
-- smallest possible definition -- the whole point of §3 is that a scheduled
-- agent run needs no bespoke machinery, just an ordinary workflow run.
-- ------------------------------------------------------------
insert into workflow.definitions (name, version, spec) values (
  'summarize_session_window', 1,
  -- THE BODY, because without it this definition cannot work and was the
  -- shipped reference anyway (REM-126). `/internal/run` needs the task id: the
  -- runtime completes its own triggering task once the run and any chained
  -- action have finished (brief.md §3), so with no id the task is never
  -- completed, the reaper takes its lease, and the run happens again. This is
  -- the shape specs/workflow-engine/README.md documents, and `{{task.id}}`
  -- resolves as of the same change.
  '{"steps": [{"key": "dispatch", "queue": "http", "kind": "http_call",
               "input": {"url": "http://127.0.0.1:8765/internal/run",
                         "method": "POST", "mode": "async",
                         "body": {"workflow_task_id": "{{task.id}}",
                                  "input": {"agent": "{{run.agent}}",
                                            "session_id": "{{run.session_id}}",
                                            "prompt": "{{run.prompt}}"}}}}]}'::jsonb
) on conflict (name, version) do update set spec = excluded.spec;

-- ------------------------------------------------------------
-- A stand-in retrieval service for exercising citations (brief.md §5.3).
--
-- Lives in its own `demo` schema, NOT in `agentic`: the spec's schema stays
-- free of fixtures. Shaped like world-model-ingestion's resource chunks
-- (resource_type / resource_id / chunk_id) because that is what a citation
-- points at -- the shape is the part that matters, not the content.
-- ------------------------------------------------------------
create schema if not exists demo;
create table if not exists demo.chunks (
    chunk_id      uuid primary key default gen_random_uuid(),
    resource_type text not null default 'document',
    resource_id   uuid not null,
    title         text not null,
    content       text not null
);

insert into demo.chunks (resource_id, title, content)
select * from (values
  ('11111111-2222-3333-4444-555555555555'::uuid, 'incident-2026-08-14',
   'At 09:12 UTC the primary write replica ran out of connection slots. '
   'Requests queued for 40 minutes before the pool was resized.'),
  ('11111111-2222-3333-4444-555555555555'::uuid, 'incident-2026-08-14',
   'Root cause: a migration held an ACCESS EXCLUSIVE lock while a batch job '
   'opened 200 new connections. No connection limit was configured per role.'),
  ('66666666-7777-8888-9999-000000000000'::uuid, 'postmortem-2026-08-15',
   'Follow-up actions: per-role connection limits, and a pre-migration check '
   'that refuses to run while a batch job holds open transactions.')
) as v(resource_id, title, content)
where not exists (select 1 from demo.chunks);

grant usage on schema demo to authenticated, web_anon, api_viewer;
grant select on demo.chunks to authenticated, api_viewer;

-- A retrieval *operation*, not just a table: one text parameter, which is the
-- shape a real retrieval service (ai-query-layer's SEMANTIC mode) exposes and
-- the shape an LLM can actually call. Binding PostgREST's generated row filters
-- as a tool works, but the model spends its turn guessing `title=eq.x` syntax --
-- observed, and a good argument for retrieval services exposing operations
-- rather than tables.
create or replace function demo.search_chunks(p_q text)
returns setof demo.chunks
language sql stable
as $$
    -- Match ANY word of the query, not the whole phrase. A model passes a
    -- natural-language question, and an ilike of the entire question matches
    -- nothing -- which looked exactly like a working tool call returning no
    -- results, and silently emptied every citation.
    select distinct c.* from demo.chunks c,
         lateral unnest(string_to_array(lower(p_q), ' ')) as w
     where length(w) > 3
       and (c.content ilike '%' || w || '%' or c.title ilike '%' || w || '%')
     limit 5;
$$;

grant execute on function demo.search_chunks(text) to authenticated;
