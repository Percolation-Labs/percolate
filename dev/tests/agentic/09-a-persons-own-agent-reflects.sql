-- A PERSON'S OWN AGENT READS A CONVERSATION AND LANDS WHAT IT LEARNED (REM-1056).
--
-- reflect_session (agentic/08) makes Percolate call a model of its own to read a
-- session. A person whose agent is connected over MCP already has a reader:
-- agentic.session_messages hands that agent the windows, and
-- agentic.land_message_facts lands one message's facts as the caller's agent, by
-- reflect_session's rules: whoever may read the session may reflect on it, only
-- the user's words are evidence, and a fact cites its message and holds from
-- when it was said. No model is configured here and no task is queued: the
-- agent's answer is the graph passed in.
--
-- WHAT WOULD MAKE IT FAIL. Drop the session_readable check and §4 raises: Leo
-- lands facts on a conversation he cannot read. Drop the role check and §3
-- raises: an assistant turn becomes evidence. Record the agent as a model's
-- name and §2 raises: the agent's facts cannot be told from structure_null's.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

insert into rbac.users (id, email, status) values
    ('00000000-0000-0000-0000-000000105601', 'rem1056-maya@example.com', 'active'),
    ('00000000-0000-0000-0000-000000105602', 'rem1056-leo@example.com', 'active')
on conflict (id) do nothing;
insert into rbac.roles (name, description) values ('rem1056_member', 'test fixture') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rem1056_member', 'agents', 'invoke')
on conflict do nothing;
insert into rbac.user_roles (user_id, role) values
    ('00000000-0000-0000-0000-000000105601', 'rem1056_member'),
    ('00000000-0000-0000-0000-000000105602', 'rem1056_member')
on conflict do nothing;
select agentic.upsert_agent('{"name":"rem1056-planner","system_prompt":"Plan Maya''s trips."}') \g /dev/null
update agentic.agents set visibility = 'public' where name = 'rem1056-planner';
select aiq.register_graph_vocabulary('[{"relation":"lives_in"},{"relation":"allergic_to"}]') \g /dev/null

-- Maya's conversation: two things she said, one thing the assistant said.
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000105601"}';
set local role authenticated;
select (agentic.create_session('trip planning')).id as session \gset
select (agentic.start_run('rem1056-planner', :'session')).id as run \gset
reset role;
set local role app_owner;
insert into agentic.messages (run_id, session_id, role, content, created_at) values
    (:'run', :'session', 'user',      'We moved to Lisbon last spring.', '2026-06-01T10:00:00Z'),
    (:'run', :'session', 'assistant', 'Noted. You live in Porto, then?', '2026-06-01T10:00:05Z'),
    (:'run', :'session', 'user',      'I am allergic to peanuts.',       '2026-06-01T10:01:00Z');
select id as said_lisbon from agentic.messages where session_id = :'session' and content like 'We moved%' \gset
select id as said_porto  from agentic.messages where session_id = :'session' and role = 'assistant' \gset
select count(*) as tasks_before from workflow.tasks \gset
select set_config('t.session', :'session', true), set_config('t.lisbon', :'said_lisbon', true),
       set_config('t.porto', :'said_porto', true), set_config('t.tasks', :'tasks_before', true) \g /dev/null


-- 1. Maya's agent reads the conversation: one window per thing she wrote.
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000105601"}';
set local role authenticated;
do $$
declare w jsonb := agentic.session_messages(current_setting('t.session')::uuid);
begin
    if jsonb_array_length(w) <> 2 then
        raise exception '1 the agent was handed % windows; Maya wrote 2 messages and the assistant''s turn is not evidence',
            jsonb_array_length(w);
    end if;
    if w->0->>'message_id' is distinct from current_setting('t.lisbon') or w->0->>'said' <> 'We moved to Lisbon last spring.' then
        raise exception '1 the first window is %', w->0;
    end if;
end $$;


-- 2. It lands what it learned from the first message, as Maya's agent.
do $$
declare r jsonb := agentic.land_message_facts(current_setting('t.lisbon')::uuid,
    '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"place","n":"Lisbon"}],"edges":[{"s":0,"t":1,"r":"lives_in"}]}');
begin
    if coalesce((r->>'edges_new')::int, 0) + coalesce((r->>'edges_merged')::int, 0) <> 1 then
        raise exception '2 landing one fact wrote %', r;
    end if;
end $$;

reset role;
set local role app_owner;
do $$
declare src jsonb;
begin
    select s into src from aiq.edges e, jsonb_array_elements(e.provenance->'sources') s
     where e.relation = 'lives_in' and s->>'session_id' = current_setting('t.session');
    if src is null then
        raise exception '2 no lives_in edge cites the session';
    end if;
    if src->>'agent' is distinct from 'agent:00000000-0000-0000-0000-000000105601' then
        raise exception '2 the fact is recorded as %''s, not as Maya''s agent', src->>'agent';
    end if;
    if src->'message_ids' is distinct from jsonb_build_array(current_setting('t.lisbon')) then
        raise exception '2 the fact cites %, not the message that said it', src->'message_ids';
    end if;
    if (src->>'valid_from')::timestamptz is distinct from '2026-06-01T10:00:00Z'::timestamptz then
        raise exception '2 the fact holds from %, not from when it was said', src->>'valid_from';
    end if;
    if (select count(*) from workflow.tasks) <> current_setting('t.tasks')::bigint then
        raise exception '2 landing queued work: no model is needed when the agent is the reader';
    end if;
end $$;


-- 3. The assistant's turn is refused, by name.
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000105601"}';
set local role authenticated;
do $$
begin
    perform agentic.land_message_facts(current_setting('t.porto')::uuid,
        '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"place","n":"Porto"}],"edges":[{"s":0,"t":1,"r":"lives_in"}]}');
    raise exception '3 an assistant turn was landed as evidence about Maya';
exception when sqlstate '22023' then
    if sqlerrm not like '%only what the user wrote%' then raise; end if;
end $$;


-- 4. Leo may not read Maya's conversation, so he can neither read it nor land on it.
reset role;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000105602"}';
set local role authenticated;
do $$
begin
    if jsonb_array_length(agentic.session_messages(current_setting('t.session')::uuid)) <> 0 then
        raise exception '4 Leo was handed Maya''s conversation';
    end if;
    begin
        perform agentic.land_message_facts(current_setting('t.lisbon')::uuid,
            '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"place","n":"Madrid"}],"edges":[{"s":0,"t":1,"r":"lives_in"}]}');
        raise exception '4 Leo landed a fact on a conversation he cannot read';
    exception when insufficient_privilege then
        if sqlerrm not like '%no message % that you may read%' then raise; end if;
    end;
end $$;


-- 5. Nobody signed in, nothing lands.
reset role;
set local request.jwt.claims = '';
set local role authenticated;
do $$
begin
    perform agentic.land_message_facts(current_setting('t.lisbon')::uuid, '{"nodes":[],"edges":[]}');
    raise exception '5 an anonymous call landed facts';
exception when insufficient_privilege then
    if sqlerrm not like '%sign in first%' then raise; end if;
end $$;

reset role;
do $$ begin raise notice 'agentic/09: the person''s own agent reads a conversation and lands facts as itself, by reflect_session''s rules'; end $$;

rollback;
