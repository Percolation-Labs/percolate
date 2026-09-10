-- A queued agent step may use only its claimed run's owner, never input claims.
\set ON_ERROR_STOP on
begin;
set local role app_owner;

insert into rbac.users (id, email) values
('11111111-1111-1111-1111-111111111111', 'alice-agent-identity@test.invalid'),
('22222222-2222-2222-2222-222222222222', 'bob-agent-identity@test.invalid')
on conflict (id) do nothing;

insert into workflow.definitions (name, spec) values
('t_agent_identity', '{"steps":[{"key":"brief","kind":"work","queue":"t-agent-identity"}]}');

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
select workflow.start_workflow('t_agent_identity',
    '{"owner_id":"22222222-2222-2222-2222-222222222222","_agent_caller":"22222222-2222-2222-2222-222222222222"}');

do $$ begin
    if has_function_privilege('authenticated', 'workflow.task_owner(uuid,text)', 'execute')
       or has_function_privilege('web_anon', 'workflow.task_owner(uuid,text)', 'execute') then
        raise exception 'a client can obtain a task owner through the worker-only function';
    end if;
end $$;

set local role worker;
set local request.jwt.claims = '{}';
do $$
declare t uuid; owner uuid;
begin
    select id into t from workflow.claim_task('t-agent-identity', 'identity-worker');
    if t is null then raise exception 'fixture was not claimable'; end if;
    owner := workflow.task_owner(t, 'identity-worker');
    if owner is distinct from '11111111-1111-1111-1111-111111111111'::uuid then
        raise exception 'input spoofed the owner: %', owner;
    end if;
    begin
        perform workflow.task_owner(t, 'different-worker');
        raise exception 'another worker can obtain the owner';
    exception when insufficient_privilege then null;
    end;
    begin
        perform workflow.task_owner(gen_random_uuid(), 'identity-worker');
        raise exception 'a nonexistent task can obtain an owner';
    exception when insufficient_privilege then null;
    end;
    perform workflow.complete_task(t, '{"result":"ok"}'::jsonb);
    begin
        perform workflow.task_owner(t, 'identity-worker');
        raise exception 'a finished task can still obtain the owner';
    exception when insufficient_privilege then null;
    end;
end $$;

set local role app_owner;
select workflow.start_workflow('t_agent_identity',
    '{"owner_id":"11111111-1111-1111-1111-111111111111"}');
set local role worker;
do $$
declare t uuid;
begin
    select id into t from workflow.claim_task('t-agent-identity', 'identity-worker');
    if t is null then raise exception 'ownerless fixture was not claimable'; end if;
    begin
        perform workflow.task_owner(t, 'identity-worker');
        raise exception 'an ownerless run can impersonate a user from input';
    exception when insufficient_privilege then null;
    end;
    raise notice 'workflow/14: claimed run identity, client denial, stale claim and ownerless refusal passed';
end $$;
rollback;
