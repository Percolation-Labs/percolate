-- The read surface for a conversation, entered the way a caller enters it.
--
-- agentic/02 proves the conversation plane composes, but it does all of that as
-- the owner, where RLS does not apply -- so it says nothing about who may READ
-- a conversation back. That is a different promise, and it is the one a
-- stranger actually relies on: agentic.messages_api is granted to
-- `authenticated`, so any logged-in user can select from it, and only the
-- policy stands between bob and alice's messages.
--
-- It has to be tested through the view rather than the table because that is
-- where the mechanism lives: messages_api is owned by api_viewer, and RLS on a
-- view evaluates as the VIEW's owner. Selecting agentic.messages directly as
-- app_owner (or as p8) bypasses the policy entirely and passes no matter what
-- the policy says -- which is exactly the false green this file exists to
-- avoid.
--
-- Like rbac/01, this simulates PostgREST: one BEGIN/COMMIT per request with
-- SET LOCAL request.jwt.claims, because that is the only place the identity
-- comes from.

\set ON_ERROR_STOP on

\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set sess  'aaaaaaaa-0000-4000-8000-00000000ab01'
\set agent 'aaaaaaaa-0000-4000-8000-00000000ab02'
\set run   'aaaaaaaa-0000-4000-8000-00000000ab03'

-- 0. Teardown, scoped to what this file owns. The cascade from sessions takes
--    the messages with it; the users are borrowed, not created, so they stay.
delete from agentic.sessions where id = :'sess';
delete from agentic.agents   where id = :'agent';

-- 1. Fixture, as the owner: one session belonging to alice, carrying one
--    message. owner_id is given explicitly rather than defaulted, since the
--    default reads a jwt claim that is not set here.
insert into agentic.sessions (id, owner_id, title)
values (:'sess', :'alice', 'boundary probe');

-- A message needs a run unless it is a summary (only_summaries_may_be_runless),
-- so the fixture carries the whole chain the constraint asks for. That suits
-- the test: the policy has two arms -- run owner, or session owner -- and
-- alice holds both here, so a failure means the policy did not match at all
-- rather than that the fixture picked the wrong arm.
insert into agentic.agents (id, name) values (:'agent', 'boundary_probe_agent');

insert into agentic.runs (id, session_id, agent_id, owner_id)
values (:'run', :'sess', :'agent', :'alice');

insert into agentic.messages (session_id, run_id, role, content, seq)
values (:'sess', :'run', 'user', 'alice private text', 1);

-- 2. As bob: the message must not be visible, and neither must the session.
begin;
    set local role authenticated;
    set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
declare v_n int;
begin
    select count(*) into v_n from agentic.messages_api
     where session_id = 'aaaaaaaa-0000-4000-8000-00000000ab01';
    if v_n <> 0 then
        raise exception 'bob read % of alice''s messages through messages_api', v_n;
    end if;
end $$;
commit;

-- 3. As alice: the same query must return the row. A policy that hides the
--    message from everybody would pass step 2 on its own, so this is the half
--    that makes step 2 mean something.
begin;
    set local role authenticated;
    set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
do $$
declare v_txt text;
begin
    select content into v_txt from agentic.messages_api
     where session_id = 'aaaaaaaa-0000-4000-8000-00000000ab01';
    if v_txt is distinct from 'alice private text' then
        raise exception 'alice could not read her own message back: %',
                        coalesce(v_txt, '<nothing>');
    end if;
end $$;
commit;

-- 4. With no identity at all -- an unauthenticated request, where the claim is
--    absent and rbac.current_user_id() returns null. `x = null` is null, not
--    true, so this should be empty; the check is here because a policy written
--    with coalesce() somewhere would quietly turn anonymous into everyone.
begin;
    set local role authenticated;
do $$
declare v_n int;
begin
    select count(*) into v_n from agentic.messages_api
     where session_id = 'aaaaaaaa-0000-4000-8000-00000000ab01';
    if v_n <> 0 then
        raise exception 'a request with no jwt claim read % messages', v_n;
    end if;
end $$;
commit;

delete from agentic.sessions where id = :'sess';
delete from agentic.agents   where id = :'agent';

\echo 'agentic/03: messages_api shows a conversation to its owner, to nobody else, and to no one anonymous'
