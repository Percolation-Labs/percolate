-- psql, as p8. 1. Who may do what: a role an ordinary person holds, and Ana and Leo with it.
insert into rbac.roles (name, description) values ('member', 'an ordinary person') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
  ('member', 'agents', 'invoke'), ('member', 'agents', 'update'), ('member', 'resources', 'create')
on conflict do nothing;
select rbac.create_user_with_password('ana@example.com', 'a long passphrase for ana') is not null as ana,
       rbac.create_user_with_password('leo@example.com', 'a long passphrase for leo') is not null as leo;
insert into rbac.user_roles (user_id, role)
select id, 'member' from rbac.users where email in ('ana@example.com', 'leo@example.com') on conflict do nothing;

-- 2. The relations memory may use.
select aiq.register_graph_vocabulary($v$[
  {"relation": "based_in",  "single_valued": true},
  {"relation": "works_at"},
  {"relation": "ships_via", "single_valued": true},
  {"relation": "prefers"}
]$v$) ->> 'relations' as relations;

-- 3. A channel for memories written directly, and the query tool the assistant reads through.
insert into content.channels (name, kind, config, visibility)
values ('memory', 'manual', '{"description": "memories written directly, with no pipeline"}', 'public')
on conflict do nothing;
select (agentic.upsert_tool_server('{"name": "harbour-query", "kind": "mcp", "url": "http://query-mcp:8090"}'::jsonb)).name;
