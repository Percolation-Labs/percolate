-- A research revision records the workflow run it was written in, and nothing else (REM-237):
-- no run when no step is executing, the run itself when one is, a revision inside
-- somebody else's run or a system run is refused, a row naming a run that is not executing is a forgery, and a
-- person cannot publish a run for themselves.
--
-- The engine's step executor is what publishes workflow.current_run_id; here the superuser sets it the same
-- transaction-local way, between role switches, because a person's role may not call set_config (REM-44).
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000237a1', 'run-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000237b2', 'run-other@example.test', 'active');

-- One probe definition and three runs: the owner's, somebody else's, and a system run nobody owns.
select workflow.define_yaml($y$
name: rem237_probe
steps:
  - id: now
    sql: {function: p8ql, args: ['SELECT now()']}
$y$);
do $$
declare
    v_def     uuid := (select id from workflow.definitions where name = 'rem237_probe' order by version desc limit 1);
    v_own     uuid;
    v_foreign uuid;
    v_system  uuid;
begin
    insert into workflow.runs (workflow_def_id, owner_id) values (v_def, '00000000-0000-4000-8000-0000000237a1') returning id into v_own;
    insert into workflow.runs (workflow_def_id, owner_id) values (v_def, '00000000-0000-4000-8000-0000000237b2') returning id into v_foreign;
    insert into workflow.runs (workflow_def_id, owner_id) values (v_def, null) returning id into v_system;
    assert (select owner_id from workflow.runs where id = v_system) is null, 'a system run is owned by nobody';
    perform set_config('rp.own', v_own::text, true);
    perform set_config('rp.foreign', v_foreign::text, true);
    perform set_config('rp.system', v_system::text, true);
end $$;


-- 1. No step executing: the revision records no run.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000237a1"}';
set local role authenticated;
do $$
declare r jsonb;
begin
    r := research.submit_package('{"schema_version": "0.1", "title": "Written outside any run", "visibility": "private", "sources": [], "edges": [], "claims": []}', null, 'rp-no-run');
    assert (select run_id from research.revisions where id = (r->>'revision_id')::uuid) is null, 'no step, no run';
end $$;
reset role;


-- 2. Inside the owner's own run: submit and revise both record it.
do $$ begin perform set_config('workflow.current_run_id', current_setting('rp.own'), true); end $$;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000237a1"}';
set local role authenticated;
do $$
declare
    own uuid := current_setting('rp.own')::uuid;
    d   jsonb := '{"schema_version": "0.1", "title": "Written inside my own run", "visibility": "private", "sources": [], "edges": [], "claims": []}';
    r   jsonb;
begin
    r := research.submit_package(d, null, 'rp-in-run');
    assert (select run_id from research.revisions where id = (r->>'revision_id')::uuid) = own, 'the revision records the run it was written in';
    r := research.revise_package('rp-in-run', d || '{"title": "Revised inside my own run"}', 'draft-1');
    assert (select run_id from research.revisions where id = (r->>'revision_id')::uuid) = own, 'and so does its revision';
end $$;
reset role;


-- 3. Inside somebody else's run, and inside a system run: refused, and nothing is left behind.
do $$ begin perform set_config('workflow.current_run_id', current_setting('rp.foreign'), true); end $$;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000237a1"}';
set local role authenticated;
do $$
begin
    begin
        perform research.submit_package('{"schema_version": "0.1", "title": "Inside another person''s run", "visibility": "private", "sources": [], "edges": [], "claims": []}', null, 'rp-foreign-run');
        raise exception 'a revision was written inside somebody else''s run';
    exception when check_violation then
        if sqlerrm <> 'A revision''s workflow run belongs to its actor' then raise; end if;
    end;
    assert not exists (select 1 from research.works where public_id = 'rp-foreign-run'), 'a refused write leaves no work';
end $$;
reset role;

do $$ begin perform set_config('workflow.current_run_id', current_setting('rp.system'), true); end $$;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000237a1"}';
set local role authenticated;
do $$
begin
    begin
        perform research.submit_package('{"schema_version": "0.1", "title": "Inside a system run", "visibility": "private", "sources": [], "edges": [], "claims": []}', null, 'rp-system-run');
        raise exception 'a revision was written inside a system run nobody owns';
    exception when check_violation then
        if sqlerrm <> 'A revision''s workflow run belongs to its actor' then raise; end if;
    end;
end $$;
reset role;


-- 4. As the table owner, the way a definer writes: a row cannot name a run that is not the one executing.
do $$
declare
    own     uuid := current_setting('rp.own')::uuid;
    foreign_run uuid := current_setting('rp.foreign')::uuid;
    w       uuid := (select id from research.works where public_id = 'rp-no-run');
    a       uuid := '00000000-0000-4000-8000-0000000237a1';
begin
    perform set_config('request.jwt.claims', '{"sub": "00000000-0000-4000-8000-0000000237a1"}', true);
    perform set_config('workflow.current_run_id', '', true);
    begin
        insert into research.revisions (work_id, number, label, schema_version, document, content_hash, actor_id, actor_kind, run_id)
        values (w, 50, 'draft-50', '0.1', '{}', 'x', a, 'person', own);
        raise exception 'a revision named a run with no step executing';
    exception when check_violation then
        if sqlerrm <> 'A revision records only the workflow run it is written in' then raise; end if;
    end;
    perform set_config('workflow.current_run_id', own::text, true);
    begin
        insert into research.revisions (work_id, number, label, schema_version, document, content_hash, actor_id, actor_kind, run_id)
        values (w, 51, 'draft-51', '0.1', '{}', 'x', a, 'person', foreign_run);
        raise exception 'a revision named a run other than the one executing';
    exception when check_violation then
        if sqlerrm <> 'A revision records only the workflow run it is written in' then raise; end if;
    end;
    perform set_config('workflow.current_run_id', '', true);
end $$;


-- 5. A person cannot publish a run for themselves.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000237a1"}';
set local role authenticated;
do $$
begin
    begin
        perform set_config('workflow.current_run_id', current_setting('rp.own'), true);
        raise exception 'a person set the workflow run their writes are recorded under';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;

rollback;
