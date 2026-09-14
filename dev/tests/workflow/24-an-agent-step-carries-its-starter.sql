-- AN AGENT STEP CARRIES WHOEVER STARTED ITS RUN, NOT ONLY THE PERSON IT WORKS FOR (REM-247).
--
-- The worker minted a compiled agent step's token from workflow.task_owner alone: `{"sub": owner}`. So a step in a
-- run a person's agent started called the runtime as the person. workflow.task_principal returns the run's starter
-- beside its owner, from the columns REM-171 records, and the worker mints `actor` and `api_key_id` from it.
--
--   1. an agent-started run gives the owner, actor `agent` and the agent's key; a person's run gives actor `person`
--      and no key;
--   2. the claims the worker then mints make rbac.decide refuse a human-only capability, a scope the key lacks and,
--      once revoked, the key itself; the person's own claims are allowed what the person is allowed;
--   3. the guards are task_owner's: another worker, an unknown task, a finished task and an ownerless run are
--      refused, and no client role may call it.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000247a1', 'wf24-person@example.test', 'active');
select rbac.declare_application('wf24', '1',
    '[{"resource": "publish", "action": "publish", "human_only": true},
      {"resource": "notes", "action": "read"},
      {"resource": "other", "action": "read"}]');
insert into rbac.roles (name, description) values ('wf24-writer', 'publishes and reads wf24');
insert into rbac.role_permissions (role, resource, action) values
    ('wf24-writer', 'wf24.publish', 'publish'),
    ('wf24-writer', 'wf24.notes', 'read'),
    ('wf24-writer', 'wf24.other', 'read');
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000247a1', 'wf24-writer');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000247c1', '00000000-0000-4000-8000-0000000247a1', 'wf24 agent',
     'wf24-agent-key-hash', '{wf24.notes:read}');

insert into workflow.definitions (name, spec) values
('t_wf24_agent', '{"steps":[{"key":"brief","kind":"work","queue":"t-wf24-agent"}]}'),
('t_wf24_person', '{"steps":[{"key":"brief","kind":"work","queue":"t-wf24-person"}]}');

do $$ begin
    if has_function_privilege('authenticated', 'workflow.task_principal(uuid,text)', 'execute')
       or has_function_privilege('web_anon', 'workflow.task_principal(uuid,text)', 'execute') then
        raise exception 'a client can obtain a task''s principal through the worker-only function';
    end if;
end $$;

-- The person's agent starts one run with its key; the person starts another.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000247a1", "api_key_id": "00000000-0000-4000-8000-0000000247c1"}';
select workflow.start_workflow('t_wf24_agent', '{}'::jsonb);
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000247a1"}';
select workflow.start_workflow('t_wf24_person', '{}'::jsonb);
set local request.jwt.claims = '';


-- 1 and 3. The worker reads each run's principal, under task_owner's guards.
set local role worker;
set local request.jwt.claims = '{}';
do $$
declare t uuid; p record;
begin
    select id into t from workflow.claim_task('t-wf24-agent', 'wf24-worker');
    if t is null then raise exception 'the agent fixture was not claimable'; end if;
    select * into p from workflow.task_principal(t, 'wf24-worker');
    assert p.owner_id = '00000000-0000-4000-8000-0000000247a1'
       and p.started_actor = 'agent' and p.started_credential_id = '00000000-0000-4000-8000-0000000247c1',
        format('an agent-started run gives its owner, actor agent and the key, got %s', p);
    begin
        perform workflow.task_principal(t, 'another-worker');
        raise exception 'another worker obtained the principal';
    exception when insufficient_privilege then null;
    end;
    begin
        perform workflow.task_principal(gen_random_uuid(), 'wf24-worker');
        raise exception 'an unknown task obtained a principal';
    exception when insufficient_privilege then null;
    end;
    perform workflow.complete_task(t, '{"result":"ok"}'::jsonb);
    begin
        perform workflow.task_principal(t, 'wf24-worker');
        raise exception 'a finished task still obtained its principal';
    exception when insufficient_privilege then null;
    end;

    select id into t from workflow.claim_task('t-wf24-person', 'wf24-worker');
    if t is null then raise exception 'the person fixture was not claimable'; end if;
    select * into p from workflow.task_principal(t, 'wf24-worker');
    assert p.owner_id = '00000000-0000-4000-8000-0000000247a1' and p.started_actor = 'person'
       and p.started_credential_id is null,
        format('a person''s run gives actor person and no key, got %s', p);
end $$;


-- 2. What the minted claims do at the runtime: rbac.decide narrows the agent's step, and not the person's.
set local role app_owner;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000247a1", "actor": "agent", "api_key_id": "00000000-0000-4000-8000-0000000247c1"}';
do $$
begin
    assert rbac.decide('wf24.publish', 'publish')->>'reason' = 'human_only', 'the agent step is refused a human-only capability';
    assert rbac.decide('wf24.other', 'read')->>'reason' = 'scope_missing', 'and a scope its key lacks';
    assert (rbac.decide('wf24.notes', 'read')->>'allowed')::boolean, 'and allowed the scope it has';
end $$;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000247a1"}';
do $$
begin
    assert (rbac.decide('wf24.publish', 'publish')->>'allowed')::boolean, 'the person''s own step is allowed what the person is';
end $$;
set local request.jwt.claims = '';
update rbac.api_keys set revoked_at = now() where id = '00000000-0000-4000-8000-0000000247c1';
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000247a1", "actor": "agent", "api_key_id": "00000000-0000-4000-8000-0000000247c1"}';
do $$
begin
    assert rbac.decide('wf24.notes', 'read')->>'reason' = 'credential_revoked',
        'a key revoked after the run started refuses its next agent step';
end $$;
set local request.jwt.claims = '';


-- 3. An ownerless run is refused, as task_owner refuses it.
select workflow.start_workflow('t_wf24_person', '{}'::jsonb);
set local role worker;
set local request.jwt.claims = '{}';
do $$
declare t uuid;
begin
    select id into t from workflow.claim_task('t-wf24-person', 'wf24-worker');
    if t is null then raise exception 'the ownerless fixture was not claimable'; end if;
    begin
        perform workflow.task_principal(t, 'wf24-worker');
        raise exception 'an ownerless run obtained a principal';
    exception when insufficient_privilege then null;
    end;
    raise notice 'workflow/24: the starter travels with the owner, narrows the step, and task_owner''s guards hold';
end $$;

rollback;
