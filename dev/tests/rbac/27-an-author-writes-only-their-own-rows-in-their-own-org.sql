-- AN AUTHOR WRITES ONLY THEIR OWN ROWS, IN AN ORG THEY BELONG TO (REM-1111, REM-1112).
--
-- rbac/24 holds agents to their owners (REM-1067). Skills, tool servers and
-- plugins are written the same way -- SECURITY DEFINER, `on conflict (name) do
-- update`, past row security -- and kept the shape REM-1067 replaced, and every
-- kind took its org_id from the spec unchecked. Each was reproduced before
-- this was written. Asserted here:
--   1. a skills:update holder cannot change another person's skill by name,
--      nor give one away;
--   2. the same for a tool server;
--   3. a plugin manifest cannot take over another person's plugin, and a
--      manifest's prune removes only the caller's own rows, even when another
--      person's row carries the plugin's name;
--   4. no agent, skill or tool server can be placed in an org the author is
--      not a member of, and a member of that org sees nothing (a manifest
--      carries no org_id key: apply_plugin refuses unknown keys);
--   5. a holder of <kind>:update_any can, and grants_all holds all three.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

\set maya  '''00000000-0000-4000-8000-000000111101'''
\set leo   '''00000000-0000-4000-8000-000000111102'''
\set admin '''00000000-0000-4000-8000-000000111103'''
\set bob   '''00000000-0000-4000-8000-000000111104'''
\set org_b '''00000000-0000-4000-8000-000000111110'''
\set as_maya  'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000111101"}''; set local role authenticated;'
\set as_leo   'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000111102"}''; set local role authenticated;'
\set as_admin 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000111103"}''; set local role authenticated;'
\set as_bob   'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000111104"}''; set local role authenticated;'

begin;
insert into rbac.users (id, email, status) values
    (:maya,  'rem1111-maya@example.test',  'active'),
    (:leo,   'rem1111-leo@example.test',   'active'),
    (:admin, 'rem1111-admin@example.test', 'active'),
    (:bob,   'rem1111-bob@example.test',   'active');
insert into rbac.orgs (id, slug, name) values (:org_b, 'rem1111-org-b', 'Org B');
insert into rbac.org_members (org_id, user_id) values (:org_b, :bob);   -- Bob is in B; Leo is not
insert into rbac.roles (name) values ('rem1111_author'), ('rem1111_admin');
insert into rbac.role_permissions (role, resource, action)
select r, k, a from (values ('rem1111_author'), ('rem1111_admin')) roles(r),
       (values ('agents'), ('skills'), ('tool_servers'), ('plugins')) kinds(k),
       (values ('update')) acts(a)
union all
select 'rem1111_admin', k, 'update_any' from (values ('agents'), ('skills'), ('tool_servers'), ('plugins')) kinds(k);
insert into rbac.user_roles (user_id, role) values
    (:maya, 'rem1111_author'), (:leo, 'rem1111_author'), (:admin, 'rem1111_admin');

create function pg_temp.refused(p_sql text, p_like text) returns void language plpgsql as $$
begin
    execute p_sql;
    raise exception 'accepted, and should have been refused: %', p_sql;
exception when others then
    if sqlerrm not like p_like then raise; end if;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

-- Maya's own: a skill, a tool server, and a plugin that installs an agent and a skill.
:as_maya
select agentic.upsert_skill('{"name":"rem1111-skill","description":"d","content":"Maya''s procedure"}') \g /dev/null
select agentic.upsert_tool_server('{"name":"rem1111-server","kind":"mcp","url":"https://maya.example.test/mcp"}') \g /dev/null
select agentic.apply_plugin('{"name":"rem1111-plugin","version":"1.0.0",
    "skills":[{"name":"rem1111-plugin-skill","description":"d","content":"from the plugin"}],
    "agents":[{"name":"rem1111-plugin-agent","system_prompt":"from the plugin"}]}') \g /dev/null

-- 1. A skill, by name, and given away.
:as_leo
select pg_temp.refused($q$select agentic.upsert_skill('{"name":"rem1111-skill","content":"Leo was here"}')$q$,
                       '%skill rem1111-skill belongs to someone else%');
select pg_temp.refused($q$select agentic.upsert_skill('{"name":"rem1111-leo-skill","description":"d","owner_id":"00000000-0000-4000-8000-000000111101"}')$q$,
                       '%only an administrator may give a skill to someone else%');
-- 2. A tool server.
select pg_temp.refused($q$select agentic.upsert_tool_server('{"name":"rem1111-server","url":"https://leo.example.test/mcp"}')$q$,
                       '%tool server rem1111-server belongs to someone else%');
-- 3. A plugin, taken over by its manifest; and a prune that reaches past the caller.
select pg_temp.refused($q$select agentic.apply_plugin('{"name":"rem1111-plugin","version":"6.6.6"}')$q$,
                       '%plugin rem1111-plugin belongs to someone else%');
select agentic.upsert_skill('{"name":"rem1111-leo-stamped","description":"d","content":"Leo''s","plugin":"rem1111-plugin"}') \g /dev/null
:as_maya
select agentic.apply_plugin('{"name":"rem1111-plugin","version":"1.0.1",
    "skills":[{"name":"rem1111-plugin-skill","description":"d","content":"from the plugin"}],
    "agents":[{"name":"rem1111-plugin-agent","system_prompt":"from the plugin"}]}') \g /dev/null
-- 4. Another org.
:as_leo
select pg_temp.refused($q$select agentic.upsert_agent('{"name":"rem1111-planted","org_id":"00000000-0000-4000-8000-000000111110","visibility":"org","system_prompt":"planted"}')$q$,
                       '%agent rem1111-planted: you may not place it in an organization you are not a member of%');
select pg_temp.refused($q$select agentic.upsert_skill('{"name":"rem1111-planted","org_id":"00000000-0000-4000-8000-000000111110","visibility":"org","description":"d","content":"planted"}')$q$,
                       '%skill rem1111-planted: you may not place it in an organization%');
select pg_temp.refused($q$select agentic.upsert_tool_server('{"name":"rem1111-planted","kind":"mcp","url":"https://x.test","org_id":"00000000-0000-4000-8000-000000111110","visibility":"org"}')$q$,
                       '%tool server rem1111-planted: you may not place it in an organization%');
:as_bob
do $$
begin
    if exists (select 1 from agentic.agents_api where name = 'rem1111-planted') then
        raise exception 'a member of org B sees an agent a non-member placed there';
    end if;
end $$;
reset role;
do $$
begin
    if (select content from agentic.skills where name = 'rem1111-skill') is distinct from 'Maya''s procedure'
       or exists (select 1 from agentic.skills where name = 'rem1111-leo-skill') then
        raise exception 'a refused edit changed Maya''s skill anyway';
    end if;
    if (select url from agentic.tool_servers where name = 'rem1111-server') is distinct from 'https://maya.example.test/mcp' then
        raise exception 'a refused edit repointed Maya''s tool server anyway';
    end if;
    if (select version from agentic.plugins where name = 'rem1111-plugin') is distinct from '1.0.1'
       or (select owner_id from agentic.plugins where name = 'rem1111-plugin')
          is distinct from '00000000-0000-4000-8000-000000111101' then
        raise exception 'Maya''s plugin was taken over, or her own reapply did not land';
    end if;
    if not exists (select 1 from agentic.agents where name = 'rem1111-plugin-agent')
       or not exists (select 1 from agentic.skills where name = 'rem1111-plugin-skill') then
        raise exception 'a refused manifest pruned Maya''s plugin rows';
    end if;
    if not exists (select 1 from agentic.skills where name = 'rem1111-leo-stamped') then
        raise exception 'Maya''s manifest pruned a skill Leo owns because it carried her plugin''s name';
    end if;
    if exists (select 1 from agentic.agents where name = 'rem1111-planted')
       or exists (select 1 from agentic.skills where name = 'rem1111-planted')
       or exists (select 1 from agentic.tool_servers where name = 'rem1111-planted')
       or exists (select 1 from agentic.plugins where name = 'rem1111-planted') then
        raise exception 'a row was placed in an org its author is not a member of';
    end if;
end $$;

-- 5. <kind>:update_any.
:as_admin
select agentic.upsert_skill('{"name":"rem1111-skill","content":"reviewed by an admin"}') \g /dev/null
select agentic.upsert_tool_server('{"name":"rem1111-server","url":"https://reviewed.example.test/mcp"}') \g /dev/null
select agentic.apply_plugin('{"name":"rem1111-plugin","version":"1.0.2",
    "skills":[{"name":"rem1111-plugin-skill","description":"d","content":"from the plugin"}],
    "agents":[{"name":"rem1111-plugin-agent","system_prompt":"from the plugin"}]}') \g /dev/null
reset role;
do $$
begin
    if (select content from agentic.skills where name = 'rem1111-skill') is distinct from 'reviewed by an admin'
       or (select url from agentic.tool_servers where name = 'rem1111-server') is distinct from 'https://reviewed.example.test/mcp'
       or (select version from agentic.plugins where name = 'rem1111-plugin') is distinct from '1.0.2' then
        raise exception 'a holder of <kind>:update_any could not edit another person''s row';
    end if;
    if exists (select 1 from rbac.roles r, (values ('skills'), ('tool_servers'), ('plugins')) k(kind)
                where r.grants_all
                  and not exists (select 1 from rbac.role_permissions p where p.role = r.name
                                   and p.resource = k.kind and p.action = 'update_any')) then
        raise exception 'an administrator''s grants_all role does not hold every <kind>:update_any';
    end if;
end $$;

rollback;

\echo rbac/27: an author writes only their own skills, servers and plugins, in an org they belong to; update_any for administrators
