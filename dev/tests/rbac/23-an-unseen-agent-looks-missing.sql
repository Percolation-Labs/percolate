-- AN AGENT YOU CANNOT SEE AND AN AGENT THAT DOES NOT EXIST LOOK THE SAME (REM-988).
--
-- agentic.start_run is SECURITY DEFINER, so its lookup sees every agent. It
-- looked the name up before asking may_invoke, and answered "no agent named %"
-- for a name nobody uses and "not authorized to invoke agent %" for somebody
-- else's private agent: any signed-in caller could learn which private agent
-- names exist by asking. may_invoke itself already answered false for both
-- (2e5995e); start_run is the copy that still told them apart.
--
-- Bob asks for alice's private agent and for a name that was never written.
-- The two refusals must be the same sentence and the same SQLSTATE. Alice
-- asking for her own agent is the control: a function that refused everybody
-- would also make the two answers equal. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table t23 (tag text, alice_session uuid, bob_session uuid);
grant select on t23 to public;
with a as (insert into agentic.sessions (owner_id)
           values ('11111111-1111-1111-1111-111111111111') returning id),
     b as (insert into agentic.sessions (owner_id)
           values ('22222222-2222-2222-2222-222222222222') returning id)
insert into t23 select left(gen_random_uuid()::text, 8), a.id, b.id from a, b;

do $$
declare t text := (select tag from t23);
begin
    insert into rbac.user_roles (user_id, role) values
        ('11111111-1111-1111-1111-111111111111', 'member'),
        ('22222222-2222-2222-2222-222222222222', 'member')
    on conflict do nothing;
    insert into agentic.agents (name, model, system_prompt, owner_id, visibility)
    values ('t23-' || t || '-ledger', 'openai:gpt-4o-mini', 'Keep the ledger.',
            '11111111-1111-1111-1111-111111111111', 'private');
end $$;

set local role authenticated;

-- 1. Alice may start a run of her own agent: the control.
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
do $$
declare t text := (select tag from t23); s uuid := (select alice_session from t23); r agentic.runs;
begin
    r := agentic.start_run('t23-' || t || '-ledger', s);
    if r.id is null then
        raise exception 'rbac/23: alice could not start a run of her own agent';
    end if;
end $$;

-- 2. Bob asks for alice's private agent and for one that does not exist.
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
declare
    t text := (select tag from t23);
    s uuid := (select bob_session from t23);
    unseen_msg text; unseen_state text;
    missing_msg text; missing_state text;
begin
    begin
        perform agentic.start_run('t23-' || t || '-ledger', s);
    exception when others then
        unseen_msg := replace(sqlerrm, 't23-' || t || '-ledger', '<name>');
        unseen_state := sqlstate;
    end;
    begin
        perform agentic.start_run('t23-' || t || '-never-written', s);
    exception when others then
        missing_msg := replace(sqlerrm, 't23-' || t || '-never-written', '<name>');
        missing_state := sqlstate;
    end;
    if unseen_msg is null then
        raise exception 'rbac/23: bob started a run of alice''s private agent';
    end if;
    if unseen_msg is distinct from missing_msg or unseen_state is distinct from missing_state then
        raise exception 'rbac/23: an unseen agent answers "%" (%), a missing one "%" (%): '
                        'the difference says the private agent exists',
            unseen_msg, unseen_state, missing_msg, missing_state;
    end if;
    raise notice 'rbac/23: an unseen agent and a missing one both answer "%" (%)',
        unseen_msg, unseen_state;
end $$;

rollback;
