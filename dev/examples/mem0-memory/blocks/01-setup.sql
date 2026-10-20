-- psql, as p8. 1. Who may do what: a role an ordinary person holds, and Maya and Leo with it.
insert into rbac.roles (name, description) values ('member', 'an ordinary person') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
  ('member', 'agents', 'invoke'), ('member', 'agents', 'update'), ('member', 'resources', 'create')
on conflict do nothing;
select rbac.create_user_with_password('maya@example.com', 'a long passphrase for maya') is not null as maya,
       rbac.create_user_with_password('leo@example.com',  'a long passphrase for leo')  is not null as leo;
insert into rbac.user_roles (user_id, role)
select id, 'member' from rbac.users where email in ('maya@example.com', 'leo@example.com') on conflict do nothing;

-- 2. The relations memory may use, and a channel for memories written directly, with no pipeline behind it.
select aiq.register_graph_vocabulary('[{"relation":"lives_in"},{"relation":"works_at"},
 {"relation":"diet"},{"relation":"allergic_to"},{"relation":"prefers"}]') ->> 'relations' as relations;
insert into content.channels (name, kind, config, visibility)
values ('memory', 'manual', '{"description": "memories written directly, with no pipeline"}', 'public')
on conflict do nothing;

-- 3. Search: an embedding model, called by the worker with the key it holds; uploads are embedded, not read.
insert into aiq.embedding_models (name, dim, provider, endpoint, credential_ref, is_default)
values ('text-embedding-3-small', 1536, 'openai', 'https://api.openai.com/v1/embeddings', 'LLM_API_KEY', true)
on conflict (name) do nothing;
select aiq.register_embedding_space('text-embedding-3-small') is not null as space;
select content.install_ingest_workflow(p_model => 'text-embedding-3-small') as ingest;

-- 4. The query tool the planners read through, and your own agent reads and judges with.
select (agentic.upsert_tool_server('{"name": "harbour-query", "kind": "mcp", "url": "http://query-mcp:8090"}'::jsonb)).name;
