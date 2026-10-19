-- A CONVERSATION WRITES WHAT IT LEARNED INTO THE GRAPH (REM-969).
--
-- A session's messages were rows in agentic.messages and nothing read them
-- back into memory. reflect_session reads a finished conversation one user
-- message at a time, through the same extractor and landing as an upload, and
-- each fact cites the session and message it came from and holds from when it
-- was said. It runs as an ordinary workflow, so the run is a trace like any
-- other. The model is stood in for here: the extraction tasks are completed
-- with the answer a model would give, which is what the engine would store.
--
-- WHAT WOULD MAKE IT FAIL. Let edge_sources_readable ignore session_id and §6
-- raises: Leo still reads a fact from a conversation Maya stopped sharing.
-- Window the assistant's turns and §2 raises. Drop the speaker from the window
-- and §3 raises: the extractor reads "I" with no one to attach it to. (§4's private conversation is
-- protected twice: its facts land on Maya's own nodes, which Leo cannot read
-- either end of, so the gate alone does not decide §4.)

\set ON_ERROR_STOP on

begin;
set local role app_owner;

insert into rbac.users (id, email, status) values
    ('00000000-0000-0000-0000-0000000969a1', 'rem969-maya@example.com', 'active'),
    ('00000000-0000-0000-0000-0000000969b1', 'rem969-leo@example.com', 'active')
on conflict (id) do nothing;
insert into rbac.roles (name, description) values ('rem969_member', 'test fixture') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rem969_member', 'agents', 'invoke')
on conflict do nothing;
insert into rbac.user_roles (user_id, role) values
    ('00000000-0000-0000-0000-0000000969a1', 'rem969_member'),
    ('00000000-0000-0000-0000-0000000969b1', 'rem969_member')
on conflict do nothing;

select agentic.upsert_agent('{"name":"rem969-planner","system_prompt":"Plan Maya''s trips."}') \g /dev/null
update agentic.agents set visibility = 'public' where name = 'rem969-planner';
select aiq.register_graph_vocabulary('[{"relation":"lives_in"},{"relation":"allergic_to"},{"relation":"works_at"}]') \g /dev/null
select aiq.install_structure_null('gpt-4o-mini') \g /dev/null
select agentic.install_reflect_workflow() \g /dev/null

-- 1. Maya talks to her planner. Two things she says are facts about her; the
--    assistant's reply is not evidence about her.
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000969a1"}';
set local role authenticated;
select (agentic.create_session('trip planning')).id as session \gset
select (agentic.start_run('rem969-planner', :'session')).id as run \gset
reset role;
set local role app_owner;
insert into agentic.messages (run_id, session_id, role, content, created_at) values
    (:'run', :'session', 'user',      'We moved to Lisbon for Harbour Health.', '2026-06-01T10:00:00Z'),
    (:'run', :'session', 'assistant', 'Noted. You live in Porto, then?',       '2026-06-01T10:00:05Z'),
    (:'run', :'session', 'user',      'No, Lisbon. And I am allergic to peanuts.', '2026-06-01T10:01:00Z');
select id as said_lisbon from agentic.messages where session_id = :'session' and content like 'We moved%' \gset

-- 2. The workflow windows only what Maya wrote.
select jsonb_array_length(agentic.session_windows(:'session')) as windows \gset
select set_config('rem969.windows', :'windows', true) \g /dev/null
do $$
begin
    if current_setting('rem969.windows')::int is distinct from 2 then
        raise exception 'the session has 2 user messages and % windows; an assistant turn is not evidence about the user',
            current_setting('rem969.windows');
    end if;
end $$;

-- 3. Reflect: start the run, and answer each extraction as a model would.
select workflow.start_workflow('reflect_session', json_build_object('session_id', :'session', 'speaker', 'Maya Okafor')::jsonb) as reflect_run \gset
-- The extractor is told who is speaking: a first-person message has no
-- subject of its own. A window with no speaker says "The person".
do $$
begin
    if not exists (select 1 from workflow.tasks t
                    where t.input->'item'->>'content' = 'Maya Okafor wrote: We moved to Lisbon for Harbour Health.') then
        raise exception 'the extraction was not told who was speaking: %',
            (select t.input->'item'->>'content' from workflow.tasks t
              where t.input->'item'->>'content' like '%We moved%' limit 1);
    end if;
end $$;
select agentic.session_windows(:'session')->0->>'content' as unnamed \gset
select set_config('rem969.unnamed', :'unnamed', true) \g /dev/null
do $$
begin
    if current_setting('rem969.unnamed') is distinct from 'The person wrote: We moved to Lisbon for Harbour Health.' then
        raise exception 'a window with no speaker reads %', current_setting('rem969.unnamed');
    end if;
end $$;
do $$
declare t workflow.tasks; n int := 0;
begin
    for t in select * from workflow.claim_tasks('http', 'rem969-model', 10) loop
        n := n + 1;
        perform workflow.complete_task(t.id, jsonb_build_object('result',
            case when t.input->'item'->>'content' like '%We moved%'
                 then '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"place","n":"Lisbon"}],"edges":[{"s":0,"t":1,"r":"lives_in"}]}'
                 else '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"food","n":"peanuts"}],"edges":[{"s":0,"t":1,"r":"allergic_to"}]}'
            end), 'rem969-model');
    end loop;
    if n <> 2 then raise exception 'reflect_session queued % extractions; expected one per user message (2)', n; end if;
end $$;
select workflow.drain_sql_steps(:'reflect_run') \g /dev/null

select status as reflect_status from workflow.runs where id = :'reflect_run' \gset
select set_config('rem969.status', :'reflect_status', true) \g /dev/null
do $$
begin
    if current_setting('rem969.status') is distinct from 'succeeded' then
        raise exception 'the reflect_session run ended %, not succeeded', current_setting('rem969.status');
    end if;
end $$;

-- 4. The fact cites the message it came from, holds from when it was said, and
--    is read only by whoever may read the conversation.
select set_config('rem969.said_lisbon', :'said_lisbon', true) \g /dev/null
select set_config('rem969.session', :'session', true) \g /dev/null
do $$
declare e aiq.edges;
begin
    select * into e from aiq.edges where relation = 'lives_in'
       and provenance->'sources' @> jsonb_build_array(jsonb_build_object('session_id', current_setting('rem969.session')));
    if e.id is null then
        raise exception 'the conversation left no lives_in fact';
    end if;
    if not (e.provenance->'sources' @> jsonb_build_array(jsonb_build_object(
                'message_ids', jsonb_build_array(current_setting('rem969.said_lisbon'))))) then
        raise exception 'the fact does not cite the message that said it: %', e.provenance;
    end if;
    if e.valid_from is distinct from '2026-06-01T10:00:00Z'::timestamptz then
        raise exception 'the fact holds from %, not from when Maya said it', e.valid_from;
    end if;
    raise notice 'Maya Okafor -lives_in-> Lisbon, from %, citing message %', e.valid_from::date,
        current_setting('rem969.said_lisbon');
end $$;

reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000969a1"}';
set local role authenticated;
select count(*) as maya_reads from aiq.edges
 where provenance->'sources' @> jsonb_build_array(jsonb_build_object('session_id', :'session')) \gset
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000969b1"}';
set local role authenticated;
select count(*) as leo_reads from aiq.edges
 where provenance->'sources' @> jsonb_build_array(jsonb_build_object('session_id', :'session')) \gset
reset role;
set local role app_owner;
select set_config('rem969.maya', :'maya_reads', true), set_config('rem969.leo', :'leo_reads', true) \g /dev/null
do $$
begin
    if current_setting('rem969.maya')::int is distinct from 2 or current_setting('rem969.leo')::int is distinct from 0 then
        raise exception 'Maya reads % of her conversation''s facts (expected 2) and Leo reads % (expected 0)',
            current_setting('rem969.maya'), current_setting('rem969.leo');
    end if;
    raise notice 'Maya reads 2 facts from her conversation; Leo reads 0';
end $$;

-- 5. Reflecting the same conversation again adds no second source.
select workflow.start_workflow('reflect_session', json_build_object('session_id', :'session')::jsonb) as reflect_again \gset
do $$
declare t workflow.tasks;
begin
    for t in select * from workflow.claim_tasks('http', 'rem969-model', 10) loop
        perform workflow.complete_task(t.id, jsonb_build_object('result',
            case when t.input->'item'->>'content' like '%We moved%'
                 then '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"place","n":"Lisbon"}],"edges":[{"s":0,"t":1,"r":"lives_in"}]}'
                 else '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"food","n":"peanuts"}],"edges":[{"s":0,"t":1,"r":"allergic_to"}]}'
            end), 'rem969-model');
    end loop;
end $$;
select workflow.drain_sql_steps(:'reflect_again') \g /dev/null
do $$
declare n int;
begin
    select jsonb_array_length(provenance->'sources') into n from aiq.edges
     where relation = 'lives_in'
       and provenance->'sources' @> jsonb_build_array(jsonb_build_object('session_id', current_setting('rem969.session')));
    if n is distinct from 1 then
        raise exception 'reflecting the conversation twice left % sources on the fact; expected 1', n;
    end if;
end $$;

-- 6. A conversation shared with an org and then made private takes its facts
--    with it. Its nodes were written with the org's scope and stay readable;
--    only the session gate on the fact decides.
insert into rbac.orgs (id, slug, name) values ('00000000-0000-0000-0000-0000000969c0', 'rem969-team', 'Team')
on conflict do nothing;
insert into rbac.org_members (org_id, user_id, role) values
    ('00000000-0000-0000-0000-0000000969c0', '00000000-0000-0000-0000-0000000969a1', 'member'),
    ('00000000-0000-0000-0000-0000000969c0', '00000000-0000-0000-0000-0000000969b1', 'member')
on conflict do nothing;
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000969a1"}';
set local role authenticated;
select (agentic.create_session('team planning')).id as shared \gset
select (agentic.start_run('rem969-planner', :'shared')).id as shared_run \gset
reset role;
set local role app_owner;
update agentic.sessions set org_id = '00000000-0000-0000-0000-0000000969c0', visibility = 'org' where id = :'shared';
insert into agentic.messages (run_id, session_id, role, content, created_at) values
    (:'shared_run', :'shared', 'user', 'I work at Northwind Analytics.', '2026-06-02T09:00:00Z');
select workflow.start_workflow('reflect_session', json_build_object('session_id', :'shared')::jsonb) as reflect_shared \gset
do $$
declare t workflow.tasks;
begin
    for t in select * from workflow.claim_tasks('http', 'rem969-model', 10) loop
        perform workflow.complete_task(t.id, jsonb_build_object('result',
            '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"company","n":"Northwind Analytics"}],"edges":[{"s":0,"t":1,"r":"works_at"}]}'),
            'rem969-model');
    end loop;
end $$;
select workflow.drain_sql_steps(:'reflect_shared') \g /dev/null

reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000969b1"}';
set local role authenticated;
select count(*) as leo_shared from aiq.edges where relation = 'works_at'
   and provenance->'sources' @> jsonb_build_array(jsonb_build_object('session_id', :'shared')) \gset
reset role;
set local role app_owner;
update agentic.sessions set visibility = 'private' where id = :'shared';
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000969b1"}';
set local role authenticated;
select count(*) as leo_unshared from aiq.edges where relation = 'works_at'
   and provenance->'sources' @> jsonb_build_array(jsonb_build_object('session_id', :'shared')) \gset
reset role;
set local role app_owner;
select set_config('rem969.shared', :'leo_shared', true), set_config('rem969.unshared', :'leo_unshared', true) \g /dev/null
do $$
begin
    if current_setting('rem969.shared')::int is distinct from 1 then
        raise exception 'Leo reads % facts from a conversation shared with his org; expected 1',
            current_setting('rem969.shared');
    end if;
    if current_setting('rem969.unshared')::int is distinct from 0 then
        raise exception 'Leo still reads % facts from a conversation Maya made private', current_setting('rem969.unshared');
    end if;
    raise notice 'Leo reads 1 fact while the conversation is shared with the org, 0 once it is private';
end $$;

rollback;
