-- A ROUTER REACHES ONLY THE AGENTS ITS CALLER MAY READ (REM-971, REM-985).
--
-- Delegation is a tool call to the runtime's own agents, and the runtime builds
-- that catalogue from `agentic.agents_api` read AS THE CALLER. So who may reach
-- an agent through a router is decided by the row's scope and nothing else:
-- giving another person one agent is putting that agent in an org they belong
-- to, and keeping one from them is leaving it private. Both are rows that
-- already exist (rbac.orgs, rbac.org_members, the agent's org_id and
-- visibility); no grant mechanism of its own.
--
-- The subject is the tour's own shape: alice's router, shared with an org bob
-- is in, and alice's three private writers. Through the same router alice
-- reaches all three and bob reaches none, and bob's refusal names the agent.
-- Each refusal is paired with alice being served, so a policy that stopped
-- answering anyone cannot pass for one that answers correctly. One
-- transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table t22 (org uuid, tag text);
grant select on t22 to public;
insert into t22 values (gen_random_uuid(), left(gen_random_uuid()::text, 8));

do $$
declare o uuid := (select org from t22); t text := (select tag from t22); w text;
begin
    insert into rbac.orgs (id, slug, name) values (o, 't22-' || t, 'rbac/22 harbour office');
    insert into rbac.org_members (org_id, user_id) values
        (o, '11111111-1111-1111-1111-111111111111'),
        (o, '22222222-2222-2222-2222-222222222222');
    -- Both may use the agent system at all (agents:invoke), so what separates
    -- them below is the agents' scope and nothing else.
    insert into rbac.user_roles (user_id, role) values
        ('11111111-1111-1111-1111-111111111111', 'member'),
        ('22222222-2222-2222-2222-222222222222', 'member')
    on conflict do nothing;
    foreach w in array array['story', 'joke', 'poem'] loop
        insert into agentic.agents (name, model, system_prompt, owner_id, org_id, visibility)
        values ('t22-' || t || '-' || w, 'openai:gpt-4o-mini', 'Write a short ' || w || '.',
                '11111111-1111-1111-1111-111111111111', o, 'private');
    end loop;
    insert into agentic.agents (name, model, system_prompt, owner_id, org_id, visibility)
    values ('t22-' || t || '-router', 'openai:gpt-4o-mini', 'Hand the request to a writer.',
            '11111111-1111-1111-1111-111111111111', o, 'org');
end $$;

set local role authenticated;

-- 1. Alice reads and may invoke the router and every writer.
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
do $$
declare t text := (select tag from t22); n int;
begin
    select count(*) into n from agentic.agents_api where name like 't22-' || t || '-%';
    if n is distinct from 4 then
        raise exception 'rbac/22: alice reads % of her four agents', n;
    end if;
    if not agentic.may_invoke('t22-' || t || '-story') then
        raise exception 'rbac/22: alice may not invoke her own writer';
    end if;
end $$;

-- 2. Bob, in the router's org, reads the router and none of the writers, and
--    the catalogue a router offers him is built from exactly this read.
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
declare t text := (select tag from t22); names text[];
begin
    select array_agg(name order by name) into names
      from agentic.agents_api where name like 't22-' || t || '-%';
    if names is distinct from array['t22-' || t || '-router'] then
        raise exception 'rbac/22: bob reads %, not the router alone', names;
    end if;
    if not agentic.may_invoke('t22-' || t || '-router') then
        raise exception 'rbac/22: bob may not invoke the router shared with his org';
    end if;
    if agentic.may_invoke('t22-' || t || '-story') then
        raise exception 'rbac/22: bob may invoke alice''s private writer';
    end if;
end $$;

-- 3. A delegation bob's turn makes to a writer is refused, by the writer's name.
do $$
declare t text := (select tag from t22); refused text;
begin
    begin
        perform agentic.start_run('t22-' || t || '-joke');
    exception when others then
        refused := sqlerrm;
    end;
    if refused is distinct from 'not authorized to invoke agent t22-' || t || '-joke' then
        raise exception 'rbac/22: bob''s run of alice''s writer was not refused by name (%)', refused;
    end if;
end $$;

-- 4. Giving bob one writer is one row: that writer joins the org.
reset role;
update agentic.agents set visibility = 'org'
 where name = 't22-' || (select tag from t22) || '-poem';
set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
declare t text := (select tag from t22);
begin
    if not agentic.may_invoke('t22-' || t || '-poem') then
        raise exception 'rbac/22: the poem writer was shared with bob''s org and he still may not reach it';
    end if;
    if agentic.may_invoke('t22-' || t || '-story') then
        raise exception 'rbac/22: sharing the poem writer gave bob the story writer too';
    end if;
    raise notice 'rbac/22: through one router alice reaches three writers, bob none until one is shared with his org';
end $$;

rollback;
