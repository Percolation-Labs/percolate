-- 10. An agent is a row.
--
-- No class, no decorator, no deploy. A tool server is a row naming an
-- endpoint, an agent is a row naming tools by name, and both are upserted
-- with the same call that re-syncs them.
-- Two actors, and the split is real. Registering an agent is a deploy-time
-- act needing `agents:update`; opening a session is a request from a person.
-- The first half runs with no user claim, as a migration would.
set local role app_owner;

select (agentic.upsert_tool_server($j${
  "name": "harbour-query",
  "kind": "mcp",
  "url": "http://query-mcp:8090",
  "emits_citations": true,
  "cached_tools": [{"name": "query"}, {"name": "schema"}]
}$j$::jsonb)).name as tool_server;

select (agentic.upsert_agent($j${
  "name": "harbourmaster",
  "audience": "user",
  "category": "tool_user",
  "model": "anthropic:claude-sonnet-5",
  "tags": ["harbour", "inspections"],
  "system_prompt": "You answer questions about the fleet. Start with SCHEMA, resolve names with LOOKUP, and use FUZZY LOOKUP when a name misses rather than guessing another spelling.",
  "tools": [{"server": "harbour-query", "tool": "query"}]
}$j$::jsonb)).name as agent;

\echo '-- the binding, as stored. Note it names a server and a tool by NAME:'
select a.name as agent, t->>'server' as server, t->>'tool' as tool
from agentic.agents a, jsonb_array_elements(a.tools) t
where a.name = 'harbourmaster';

\echo '-- re-registering to correct the url must NOT erase what discovery found:'
select (agentic.upsert_tool_server(
    '{"name":"harbour-query","kind":"mcp","url":"http://query-mcp:9090"}'::jsonb)
    ).cached_tools as tools_after_resync;

\echo '-- now as a person. agentic.sessions.user_id is NOT NULL, so the `sub`'
\echo '-- claim is what makes create_session work at all:'
set local request.jwt.claims = '{"sub":"80000000-0000-0000-0000-000000000001","orgs":["d0000000-0000-0000-0000-00000000000a"]}';
select (agentic.create_session('Aurora Kestrel PSC history')).id as session_id \gset
select (agentic.start_run('harbourmaster', :'session_id'::uuid)).id as run_id \gset
select r.status, r.trigger_kind, s.title
from agentic.runs r join agentic.sessions s on s.id = r.session_id
where r.id = :'run_id'::uuid;
