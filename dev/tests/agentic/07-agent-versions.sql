-- AGENTIC SURFACE -- an agent's past versions are rows you can select (REM-983).
--
-- An agent is a row, so changing what it says is an UPDATE, and before this an
-- UPDATE kept nothing: the prompt it replaced, who replaced it and when were
-- gone. The tour this serves edits a prompt in psql, asks again, then selects
-- the agent's history. This file does the database half of that: two edits, one
-- through upsert_agent as the author and one as an operator in psql, then reads
-- both versions back.
--
-- WHAT WOULD MAKE IT FAIL. Drop trg_agents_keep_version and §1 raises "kept 0
-- versions". The policy is checked both ways in §3: another user reads none of
-- a private agent's versions, and all of them once the agent is public, so a
-- policy that hid everything would fail as surely as one that hid nothing.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

insert into rbac.users (id, email, status)
values ('00000000-0000-0000-0000-000000098301', 'rem983-author@example.com', 'active'),
       ('00000000-0000-0000-0000-000000098302', 'rem983-other@example.com', 'active')
on conflict (id) do nothing;

-- The author holds what upsert_agent asks for; the other user holds nothing on
-- agents, so only row policy can let them read one.
insert into rbac.roles (name, description) values ('rem983_author', 'test fixture')
on conflict (name) do nothing;
insert into rbac.role_permissions (role, resource, action)
select 'rem983_author', resource, action
  from rbac.permission_kinds where resource = 'agents'
on conflict do nothing;
insert into rbac.user_roles (user_id, role)
values ('00000000-0000-0000-0000-000000098301', 'rem983_author')
on conflict do nothing;

\set as_author 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-0000-0000-000000098301"}''; set local role authenticated;'
\set as_other  'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-0000-0000-000000098302"}''; set local role authenticated;'
\set as_operator 'reset role; reset request.jwt.claims; set local role app_owner;'

-- ---------------------------------------------------------------------
-- 1. TWO EDITS, TWO VERSIONS.
--
-- The author writes the agent and then changes its prompt through
-- upsert_agent; an operator then changes it again with a plain UPDATE, which is
-- what the tour does in psql. Each change keeps the row it replaced.
-- ---------------------------------------------------------------------
:as_author
select agentic.upsert_agent('{"name":"rem983-probe","system_prompt":"Answer in English."}') \g /dev/null
select agentic.upsert_agent('{"name":"rem983-probe","system_prompt":"Answer in French."}') \g /dev/null
:as_operator
update agentic.agents set system_prompt = 'Answer in Welsh.' where name = 'rem983-probe';

-- An update that changes nothing is not a version. The schema replays
-- `set model = model` on every upgrade.
update agentic.agents set model = model where name = 'rem983-probe';

:as_author
do $$
declare n int; v1 record; v2 record; now_prompt text;
begin
    select count(*) into n from agentic.agent_versions_api where name = 'rem983-probe';
    if n <> 2 then
        raise exception 'two edits kept % versions of the agent; expected 2 (REM-983)', n;
    end if;
    select * into v1 from agentic.agent_versions_api where name = 'rem983-probe' and version = 1;
    select * into v2 from agentic.agent_versions_api where name = 'rem983-probe' and version = 2;
    select system_prompt into now_prompt from agentic.agents_api where name = 'rem983-probe';

    if v1.system_prompt is distinct from 'Answer in English.'
       or v2.system_prompt is distinct from 'Answer in French.'
       or now_prompt is distinct from 'Answer in Welsh.' then
        raise exception 'versions read %, %, then the agent %; expected English, French, then Welsh',
            v1.system_prompt, v2.system_prompt, now_prompt;
    end if;
    -- Who: the author's id for the edit made through upsert_agent, and no user
    -- for the operator's, which still names the database login.
    if v1.replaced_by is distinct from '00000000-0000-0000-0000-000000098301'::uuid then
        raise exception 'the author''s edit was recorded as replaced by %', v1.replaced_by;
    end if;
    if v2.replaced_by is not null or v2.replaced_by_role is null then
        raise exception 'the operator''s edit was recorded as replaced by % (role %)',
            v2.replaced_by, v2.replaced_by_role;
    end if;
    -- When: each version held from its writing until the next one replaced it.
    if v1.replaced_at < v1.held_from or v2.held_from < v1.held_from then
        raise exception 'version times are out of order: v1 % to %, v2 from %',
            v1.held_from, v1.replaced_at, v2.held_from;
    end if;
    -- The whole row is kept, not only the prompt.
    if v1.agent->>'name' is distinct from 'rem983-probe' or v1.agent->>'id' is null then
        raise exception 'version 1 does not hold the whole row: %', v1.agent;
    end if;
    raise notice 'history -> v1 "%" replaced by the author, v2 "%" replaced by %, now "%"',
        v1.system_prompt, v2.system_prompt, v2.replaced_by_role, now_prompt;
end $$;

-- ---------------------------------------------------------------------
-- 2. NOBODY WRITES HISTORY BY HAND.
-- ---------------------------------------------------------------------
do $$
begin
    insert into agentic.agent_versions (agent_id, version, agent, held_from)
    select id, 99, '{}', now() from agentic.agents where name = 'rem983-probe';
    raise exception 'an ordinary user inserted a version of an agent';
exception when insufficient_privilege then
    raise notice 'a hand-written version -> refused';
end $$;

-- ---------------------------------------------------------------------
-- 3. THE AGENT'S ROW POLICY DECIDES WHO READS ITS VERSIONS.
--
-- A private agent's versions are hidden from another user. Made public, the
-- same read returns them, which is what shows the zero above came from the
-- policy and not from a read that could never see anything.
-- ---------------------------------------------------------------------
:as_other
do $$
declare n int;
begin
    select count(*) into n from agentic.agent_versions_api where name = 'rem983-probe';
    if n <> 0 then
        raise exception 'another user read % versions of a private agent', n;
    end if;
end $$;

:as_operator
update agentic.agents set visibility = 'public' where name = 'rem983-probe';

:as_other
do $$
declare n int;
begin
    select count(*) into n from agentic.agent_versions_api where name = 'rem983-probe';
    -- Three now: making it public was itself a change, and kept a version.
    if n <> 3 then
        raise exception 'another user read % versions of a public agent; expected 3', n;
    end if;
    raise notice 'another user reads 0 versions of the private agent and % once it is public', n;
end $$;

rollback;
