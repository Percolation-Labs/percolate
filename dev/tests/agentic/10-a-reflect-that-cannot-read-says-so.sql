-- A REFLECT THAT CAN READ NONE OF ITS SESSION SAYS SO (REM-1021).
--
-- agentic.session_windows used to filter a session the caller could not read
-- down to nothing, so reflect_session started by the wrong person read zero
-- windows, wrote nothing and reported success. A Mem0 reader whose run was
-- started as the admin got an empty facts table and no error. Now the call is
-- refused, naming the session, and one message covers "no such session" and
-- "someone else's", so the refusal reveals nothing.
--
-- WHAT WOULD MAKE IT FAIL. Filter to nothing again and §1 raises.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on
begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
    if p_ok is not true then
        raise exception 'a reflect that cannot read its session says so: %', p_what;
    end if;
end $$;

set local role app_owner;
insert into rbac.users (id, email, status) values
    ('00000000-0000-0000-0000-000000102101', 'rem1021-maya@example.com', 'active'),
    ('00000000-0000-0000-0000-000000102102', 'rem1021-leo@example.com', 'active');
insert into rbac.roles (name, description) values ('rem1021_member', 'test fixture') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rem1021_member', 'agents', 'invoke') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values
    ('00000000-0000-0000-0000-000000102101', 'rem1021_member'),
    ('00000000-0000-0000-0000-000000102102', 'rem1021_member');
select agentic.upsert_agent('{"name":"rem1021-planner","system_prompt":"Plan."}') is not null as agent;
update agentic.agents set visibility = 'public' where name = 'rem1021-planner';

-- Maya has a private conversation.
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000102101"}';
set local role authenticated;
create temp table s on commit drop as select (agentic.create_session('trip planning')).id as id;
grant select on s to authenticated, app_owner;
reset role;
set local role app_owner;
insert into agentic.messages (run_id, session_id, role, content)
select (agentic.start_run('rem1021-planner', s.id)).id, s.id, 'user', 'I am vegetarian.' from s;

-- A reflect step runs session_windows as app_owner with the starter's claims,
-- which is how it is called here.
-- §1. Leo started the reflect; he cannot read the session, and is told so by name.
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000102102"}';
set local role app_owner;
do $$
declare v_msg text;
begin
    perform agentic.session_windows((select id from s));
    raise exception 'REM-1021: no refusal';
exception when insufficient_privilege then
    v_msg := sqlerrm;
    if v_msg not like '%is not one the run''s owner can read%' then
        raise exception 'a reflect that cannot read its session says so: §1: Leo got % instead of the named refusal', v_msg;
    end if;
end $$;

-- §2. Maya started it; she reads her own windows, as before.
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000102101"}';
set local role app_owner;
select pg_temp.check(jsonb_array_length(agentic.session_windows((select id from s))) = 1,
    '§2: the session''s owner reads her one window');

rollback;
