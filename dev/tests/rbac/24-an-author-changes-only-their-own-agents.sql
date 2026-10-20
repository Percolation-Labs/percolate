-- AN AUTHOR CHANGES ONLY THE AGENTS THEY OWN (REM-1067).
--
-- agentic.upsert_agent runs as its owner and ends in `on conflict (name) do
-- update`, and its only question was agents:update. So any holder could
-- rewrite another person's agent by naming it, take it by passing owner_id,
-- or publish it by passing visibility; the memory tutorials grant agents:update
-- to ordinary people.
--
--   1. Maya creates an agent and it is hers; she edits it;
--   2. Leo, holding the same permission, is refused her agent by name: a
--      prompt edit, a visibility change, owner_id to himself, and attach_skill;
--   3. Leo cannot create an agent owned by Maya, and Maya cannot give hers away;
--   4. a seeded agent with no owner is nobody's to edit but an administrator's;
--   5. an account administrator (users:admin) edits Maya's agent.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

\set maya  '''00000000-0000-4000-8000-000000106701'''
\set leo   '''00000000-0000-4000-8000-000000106702'''
\set admin '''00000000-0000-4000-8000-000000106703'''
\set as_maya  'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000106701"}''; set local role authenticated;'
\set as_leo   'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000106702"}''; set local role authenticated;'
\set as_admin 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000106703"}''; set local role authenticated;'

begin;
insert into rbac.users (id, email, status) values
    (:maya,  'rem1067-maya@example.test',  'active'),
    (:leo,   'rem1067-leo@example.test',   'active'),
    (:admin, 'rem1067-admin@example.test', 'active');
insert into rbac.roles (name) values ('rem1067_author'), ('rem1067_admin');
insert into rbac.role_permissions (role, resource, action) values
    ('rem1067_author', 'agents', 'update'),
    ('rem1067_admin',  'agents', 'update'),
    ('rem1067_admin',  'users',  'admin');
insert into rbac.user_roles (user_id, role) values
    (:maya, 'rem1067_author'), (:leo, 'rem1067_author'), (:admin, 'rem1067_admin');
-- A seeded agent: written by the operator, public, owned by nobody.
select agentic.upsert_agent('{"name":"rem1067-seeded","system_prompt":"seeded"}') \g /dev/null

create function pg_temp.refused(p_sql text, p_like text) returns void language plpgsql as $$
begin
    execute p_sql;
    raise exception 'accepted, and should have been refused: %', p_sql;
exception when others then
    if sqlerrm not like p_like then raise; end if;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

-- 1. Maya's own.
:as_maya
select agentic.upsert_agent('{"name":"rem1067-maya","system_prompt":"Maya''s planner"}') \g /dev/null
select agentic.upsert_agent('{"name":"rem1067-maya","system_prompt":"Maya''s planner, v2"}') \g /dev/null
reset role;
do $$
begin
    if (select owner_id from agentic.agents where name = 'rem1067-maya')
       is distinct from '00000000-0000-4000-8000-000000106701' then
        raise exception 'an agent Maya created is not hers';
    end if;
    if (select system_prompt from agentic.agents where name = 'rem1067-maya') is distinct from 'Maya''s planner, v2' then
        raise exception 'Maya could not edit her own agent';
    end if;
end $$;

-- 2. Leo, by name.
:as_leo
select pg_temp.refused($q$select agentic.upsert_agent('{"name":"rem1067-maya","system_prompt":"Leo was here"}')$q$,
                       '%rem1067-maya belongs to someone else%');
select pg_temp.refused($q$select agentic.upsert_agent('{"name":"rem1067-maya","visibility":"public"}')$q$,
                       '%rem1067-maya belongs to someone else%');
select pg_temp.refused($q$select agentic.upsert_agent('{"name":"rem1067-maya","owner_id":"00000000-0000-4000-8000-000000106702"}')$q$,
                       '%rem1067-maya belongs to someone else%');
select pg_temp.refused($q$select agentic.attach_skill('rem1067-maya', 'nonexistent-rem1067')$q$,
                       '%rem1067-maya belongs to someone else%');
-- 3. Giving away.
select pg_temp.refused($q$select agentic.upsert_agent('{"name":"rem1067-leo-for-maya","owner_id":"00000000-0000-4000-8000-000000106701"}')$q$,
                       '%only an administrator may give an agent to someone else%');
-- 4. Nobody's.
select pg_temp.refused($q$select agentic.upsert_agent('{"name":"rem1067-seeded","system_prompt":"Leo was here"}')$q$,
                       '%rem1067-seeded belongs to someone else%');
:as_maya
select pg_temp.refused($q$select agentic.upsert_agent('{"name":"rem1067-maya","owner_id":"00000000-0000-4000-8000-000000106702"}')$q$,
                       '%only an administrator may give an agent to someone else%');
reset role;
do $$
begin
    if (select system_prompt from agentic.agents where name = 'rem1067-maya') is distinct from 'Maya''s planner, v2'
       or (select owner_id from agentic.agents where name = 'rem1067-maya')
          is distinct from '00000000-0000-4000-8000-000000106701'
       or (select system_prompt from agentic.agents where name = 'rem1067-seeded') is distinct from 'seeded'
       or exists (select 1 from agentic.agents where name = 'rem1067-leo-for-maya') then
        raise exception 'a refused edit changed an agent anyway';
    end if;
end $$;

-- 5. An administrator.
:as_admin
select agentic.upsert_agent('{"name":"rem1067-maya","system_prompt":"reviewed by an admin"}') \g /dev/null
select agentic.upsert_agent('{"name":"rem1067-seeded","system_prompt":"seeded, edited"}') \g /dev/null
reset role;
do $$
begin
    if (select system_prompt from agentic.agents where name = 'rem1067-maya') is distinct from 'reviewed by an admin' then
        raise exception 'an account administrator could not edit Maya''s agent';
    end if;
end $$;

rollback;

\echo rbac/24: an author changes only their own agents -- own edit, refused by name, no giving away, seeded agents, admin override
