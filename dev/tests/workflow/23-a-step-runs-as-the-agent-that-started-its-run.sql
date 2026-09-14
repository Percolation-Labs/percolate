-- A STEP RUNS AS WHOEVER STARTED ITS RUN: THE AGENT, NOT ONLY THE PERSON IT WORKS FOR (REM-171).
--
-- execute_for minted `{"sub": owner, "role": "authenticated"}` for every step, and a run recorded only its owner.
-- So a run a person's agent started with a narrowed credential ran each step as the person: a human-only
-- capability passed, a scope the key lacked was not refused, and revoking the key stopped nothing. A run now keeps
-- its starter (`started_actor`, `started_credential_id`, from the verified claims) and execute_for mints them into
-- each step, so rbac.decide narrows the step as it narrowed the starter.
--
--   1. a person's run is allowed what the person is allowed;
--   2. an agent's run is refused a human-only capability and a scope its key lacks, and allowed its scope;
--   3. revoking the key refuses the run's next step, and leaves the person's own run alone;
--   4. the starter comes from the claims: an insert that names another is overwritten, a later update is ignored,
--      and tick's hand-over of a scheduled run to its schedule's owner goes through;
--   5. a schedule keeps its creator the same way.
--
-- Steps run on queue `none`, so start_workflow executes them in this transaction (as workflow/15 does).
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000023a1', 'wf23-person@example.test', 'active');
select rbac.declare_application('wf23', '1',
    '[{"resource": "publish", "action": "publish", "human_only": true},
      {"resource": "notes", "action": "read"},
      {"resource": "other", "action": "read"}]');
insert into rbac.roles (name, description) values ('wf23-writer', 'publishes and reads wf23');
insert into rbac.role_permissions (role, resource, action) values
    ('wf23-writer', 'wf23.publish', 'publish'),
    ('wf23-writer', 'wf23.notes', 'read'),
    ('wf23-writer', 'wf23.other', 'read');
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000023a1', 'wf23-writer');
-- The person's agent: a key that may read notes, and nothing else.
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000023c1', '00000000-0000-4000-8000-0000000023a1', 'wf23 agent',
     'wf23-agent-key-hash', '{wf23.notes:read}');

-- One single-step workflow per capability; each step answers rbac.decide's reason, asked inside the step.
insert into workflow.definitions (name, spec, visibility) values
('wf23_publish', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"statement":"select (rbac.decide(''wf23.publish'', ''publish'')->>''reason'') as reason"}}]}', 'public'),
('wf23_notes', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"statement":"select (rbac.decide(''wf23.notes'', ''read'')->>''reason'') as reason"}}]}', 'public'),
('wf23_other', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"statement":"select (rbac.decide(''wf23.other'', ''read'')->>''reason'') as reason"}}]}', 'public');

-- Start a workflow under the given claims and report its step: the run, its status, decide's reason, the error.
create function pg_temp.start_as(p_claims jsonb, p_name text)
returns table (run_id uuid, status text, reason text, err text) as $$
declare v_run uuid; v_out jsonb;
begin
    perform set_config('request.jwt.claims', p_claims::text, true);
    v_run := workflow.start_workflow(p_name, '{}'::jsonb);
    perform set_config('request.jwt.claims', '', true);
    select t.output->'result' into v_out from workflow.tasks t where t.run_id = v_run and t.step_key = 'q';
    return query
        select v_run, t.status, v_out->0->>'reason',
               (select e.detail#>>'{error,error}' from workflow.task_events e
                 where e.run_id = v_run and e.to_status = 'failed' order by e.at desc limit 1)
          from workflow.tasks t
         where t.run_id = v_run and t.step_key = 'q';
end $$ language plpgsql;


-- 1 and 2. The person's runs, then the agent's.
do $$
declare
    person constant jsonb := '{"sub": "00000000-0000-4000-8000-0000000023a1"}';
    agent  constant jsonb := '{"sub": "00000000-0000-4000-8000-0000000023a1", "api_key_id": "00000000-0000-4000-8000-0000000023c1"}';
    r record;
begin
    select * into r from pg_temp.start_as(person, 'wf23_publish');
    assert r.status = 'succeeded' and r.reason = 'allowed',
        format('a person''s run may publish (step %s, reason %s, error %s)', r.status, r.reason, r.err);
    assert (select started_actor = 'person' and started_credential_id is null from workflow.runs where id = r.run_id),
        'a person''s run records the person as its starter';

    select * into r from pg_temp.start_as(agent, 'wf23_publish');
    assert r.reason = 'human_only',
        format('an agent''s run was not refused a human-only capability (reason %s, error %s)', r.reason, r.err);
    assert (select started_actor = 'agent' and started_credential_id = '00000000-0000-4000-8000-0000000023c1'
              from workflow.runs where id = r.run_id),
        'an agent''s run records the agent and its credential';

    select * into r from pg_temp.start_as(agent, 'wf23_other');
    assert r.reason = 'scope_missing',
        format('an agent''s run was not refused a scope its key lacks (reason %s, error %s)', r.reason, r.err);

    select * into r from pg_temp.start_as(agent, 'wf23_notes');
    assert r.reason = 'allowed',
        format('an agent''s run was refused the scope its key holds (reason %s, error %s)', r.reason, r.err);
    perform set_config('wf23.agent_run', r.run_id::text, true);

    select * into r from pg_temp.start_as(person, 'wf23_notes');
    perform set_config('wf23.person_run', r.run_id::text, true);
end $$;


-- 3. The key is revoked after the agent's run began: its next step is refused, and the person's run is not.
update rbac.api_keys set revoked_at = now() where id = '00000000-0000-4000-8000-0000000023c1';
do $$
declare
    step constant text := 'select (rbac.decide(''wf23.notes'', ''read'')->>''reason'') as reason';
    v    jsonb;
begin
    perform set_config('workflow.current_run_id', current_setting('wf23.agent_run'), true);
    v := workflow.execute_for('00000000-0000-4000-8000-0000000023a1', step, false, null);
    assert v->0->>'reason' = 'credential_revoked',
        format('a step of the agent''s run ran after its key was revoked (reason %s)', v->0->>'reason');

    perform set_config('workflow.current_run_id', current_setting('wf23.person_run'), true);
    v := workflow.execute_for('00000000-0000-4000-8000-0000000023a1', step, false, null);
    assert v->0->>'reason' = 'allowed',
        format('revoking the agent''s key refused the person''s own run (reason %s)', v->0->>'reason');

    perform set_config('workflow.current_run_id', '', true);
    assert coalesce(current_setting('request.jwt.claims', true), '') = '', 'the step left no claims behind';
end $$;


-- 4. The starter comes from the claims, not the row.
do $$
declare
    v_def   uuid := (select id from workflow.definitions where name = 'wf23_notes');
    v_run   uuid;
begin
    perform set_config('request.jwt.claims',
        '{"sub": "00000000-0000-4000-8000-0000000023a1", "api_key_id": "00000000-0000-4000-8000-0000000023c1"}', true);
    insert into workflow.runs (workflow_def_id, started_actor, started_credential_id)
    values (v_def, 'person', null) returning id into v_run;
    perform set_config('request.jwt.claims', '', true);
    assert (select started_actor = 'agent' and started_credential_id = '00000000-0000-4000-8000-0000000023c1'
              from workflow.runs where id = v_run),
        'an insert that names another starter is overwritten by the claims';

    update workflow.runs set started_actor = 'person', started_credential_id = null where id = v_run;
    assert (select started_actor = 'agent' from workflow.runs where id = v_run), 'a later update cannot change the starter';

    -- tick's hand-over: a run started with no claims, given to its schedule's owner with the schedule's creator.
    insert into workflow.runs (workflow_def_id) values (v_def) returning id into v_run;
    assert (select owner_id is null and started_actor is null from workflow.runs where id = v_run),
        'a run started with no claims has no owner and no starter';
    update workflow.runs
       set owner_id = '00000000-0000-4000-8000-0000000023a1',
           started_actor = 'agent', started_credential_id = '00000000-0000-4000-8000-0000000023c1'
     where id = v_run and owner_id is null;
    assert (select started_actor = 'agent' from workflow.runs where id = v_run), 'the owner hand-over carries the starter';
    update workflow.runs set started_actor = 'person' where id = v_run;
    assert (select started_actor = 'agent' from workflow.runs where id = v_run), 'and the starter stays after it';
end $$;


-- 5. A schedule keeps its creator the same way.
do $$
declare v_id uuid;
begin
    perform set_config('request.jwt.claims',
        '{"sub": "00000000-0000-4000-8000-0000000023a1", "api_key_id": "00000000-0000-4000-8000-0000000023c1"}', true);
    insert into workflow.schedules (name, workflow_name, cron_expr, created_actor)
    values ('wf23-nightly', 'wf23_notes', '0 3 * * *', 'person') returning id into v_id;
    perform set_config('request.jwt.claims', '', true);
    assert (select created_actor = 'agent' and created_credential_id = '00000000-0000-4000-8000-0000000023c1'
              from workflow.schedules where id = v_id),
        'a schedule records the agent that created it, whatever the insert named';
    update workflow.schedules set created_actor = 'person', created_credential_id = null where id = v_id;
    assert (select created_actor = 'agent' from workflow.schedules where id = v_id), 'and keeps it after an update';
    raise notice 'workflow/23: an agent''s run is refused human-only and unscoped steps, a revoked key stops its next step, and runs and schedules keep their starter';
end $$;

rollback;
