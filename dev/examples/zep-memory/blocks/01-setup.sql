-- psql, as p8: who may do what, and what memory is made of
insert into rbac.roles (name, description) values ('member', 'an ordinary person') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
  ('member', 'agents', 'invoke'), ('member', 'agents', 'update'), ('member', 'resources', 'create')
on conflict do nothing;
select rbac.create_user_with_password('ana@example.com', 'a long passphrase for ana') is not null as ana;
insert into rbac.user_roles (user_id, role)
select id, 'member' from rbac.users where email = 'ana@example.com' on conflict do nothing;

-- the extractor's relations are read from the vocabulary when it is installed, so the vocabulary goes first
select aiq.register_graph_vocabulary($v$[
  {"relation": "lives_in",  "single_valued": true},
  {"relation": "works_at"},
  {"relation": "ships_via", "single_valued": true},
  {"relation": "prefers"}
]$v$) ->> 'relations' as relations;

insert into aiq.embedding_models (name, dim, provider, endpoint, credential_ref, is_default)
values ('text-embedding-3-small', 1536, 'openai', 'https://api.openai.com/v1/embeddings', 'LLM_API_KEY', true)
on conflict (name) do nothing;
set role app_owner;
select aiq.register_embedding_space('text-embedding-3-small') is not null as space;
reset role;
select aiq.install_structure_null('gpt-4o') is not null as extractor;
select agentic.install_reflect_workflow('gpt-4o');
insert into content.channels (name, kind, config, visibility)
values ('memory', 'manual', '{"description": "memories written directly, with no pipeline"}', 'public')
on conflict do nothing;
select (agentic.upsert_tool_server('{"name": "harbour-query", "kind": "mcp", "url": "http://query-mcp:8090"}'::jsonb)).name;
