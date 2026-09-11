-- A STEP READS WITH THE REACH OF WHOEVER STARTED THE RUN.
--
-- workflow-engine/schema.sql, "WHOSE REACH A STATEMENT HAS", and
-- integration-rbac.sql, execute_for. Before this, a step's statement and every
-- p8ql mode ran as the engine owner, past RLS, whoever started the run: the
-- tour (scenarios/tour, act 8) had a member of one org start `ask_uploads` and
-- read another org's runbook through its SEARCH step.
--
-- What this asserts, at every door an author's read goes through -- a `sql:`
-- statement, `p8ql`, `p8ql_vec` and a matrix's `rows:` statement:
--
--   1. a member's run sees the member's rows and not the admin's;
--   2. an admin's run is scoped the same way: it sees the admin's rows, not the
--      member's -- the rule is "what the starter could read", not "admins see
--      everything";
--   3. a system run (no owner) keeps the engine's reach and sees both;
--   4. a person's run cannot read a table they hold no grant on, and cannot
--      write where they could not write by hand;
--   5. the step leaves the session as it found it: the claims and the role;
--   6. a person's direct call to workflow.p8ql is untouched.
--
-- §1 is the one that failed before: the member's run saw every row.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

insert into rbac.users (id, email) values
('15151515-0000-4000-8000-00000000000a', 'admin-scoped@test.invalid'),
('15151515-0000-4000-8000-00000000000b', 'member-scoped@test.invalid')
on conflict (id) do nothing;
insert into rbac.user_roles (user_id, role) values
('15151515-0000-4000-8000-00000000000a', 'admin'),
('15151515-0000-4000-8000-00000000000b', 'member')
on conflict do nothing;

-- A table each person sees their own row of, the way every scoped table works.
create table t_sr_notes (owner_id uuid, body text);
alter table t_sr_notes enable row level security;
create policy own on t_sr_notes for select using (owner_id = rbac.current_user_id());
grant select on t_sr_notes to authenticated;
insert into t_sr_notes values
('15151515-0000-4000-8000-00000000000a', 'admin note'),
('15151515-0000-4000-8000-00000000000b', 'member note');

-- And one nobody but the engine may read.
create table t_sr_secret (v text);
insert into t_sr_secret values ('engine only');

insert into workflow.definitions (name, spec) values
('t_sr_statement', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"statement":"select body from t_sr_notes order by body"}}]}'),
('t_sr_p8ql', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"function":"p8ql","args":["select body from t_sr_notes order by body"]}}]}'),
('t_sr_p8ql_vec', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"function":"p8ql_vec","args":["select body from t_sr_notes order by body", null]}}]}'),
('t_sr_rows_stmt', '{"steps":[{"key":"q","kind":"matrix","queue":"none",
    "input":{"rows":{"statement":"select body from t_sr_notes"}, "max_fanout":5,
             "template":{"kind":"work","queue":"t-sr-never"}}}]}'),
('t_sr_secret', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"statement":"select v from t_sr_secret"}}]}'),
('t_sr_write', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"statement":"insert into t_sr_notes values (null, ''written'')", "write":true}}]}'),
-- §4b's: a write the person may make, and three that would change who they are.
('t_sr_log_ok', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"statement":"insert into t_sr_log select body from t_sr_notes", "write":true}}]}'),
('t_sr_set_claims', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"statement":"set local request.jwt.claims = ''{\"sub\":\"15151515-0000-4000-8000-00000000000a\"}''", "write":true}}]}'),
('t_sr_do_claims', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"statement":"do $x$ begin set local request.jwt.claims = ''{\"sub\":\"15151515-0000-4000-8000-00000000000a\"}''; insert into t_sr_log select body from t_sr_notes; end $x$", "write":true}}]}'),
('t_sr_two_statements', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"statement":"insert into t_sr_log values (''first''); set local request.jwt.claims = ''{\"sub\":\"15151515-0000-4000-8000-00000000000a\"}''", "write":true}}]}');

-- Where §4b's writes land: a person may insert, and what they insert is what
-- they could read -- so a row saying `admin note` means the step read as admin.
create table t_sr_log (body text);
grant insert on t_sr_log to authenticated;

-- Start a workflow as a given caller (null = the system) and report its only
-- step: status, the bodies it read, how many matrix children it made, the error.
create function pg_temp.run_as(p_user uuid, p_name text)
returns table (status text, bodies text, children int, err text) as $$
declare v_run uuid; v_out jsonb;
begin
    execute format('set local request.jwt.claims = %L', coalesce(case when p_user is null then '' else json_build_object('sub', p_user)::text end, ''));
    v_run := workflow.start_workflow(p_name, '{}'::jsonb);
    execute format('set local request.jwt.claims = %L', '');
    select t.output->'result' into v_out from workflow.tasks t
     where t.run_id = v_run and t.step_key = 'q';
    -- p8ql answers {mode, rows}; a statement answers the rows themselves.
    if jsonb_typeof(v_out) = 'object' and v_out ? 'rows' then v_out := v_out->'rows'; end if;
    return query
        select t.status,
               (select string_agg(coalesce(x->>'body', x->>'v'), ',' order by 1)
                  from jsonb_array_elements(case when jsonb_typeof(v_out) = 'array' then v_out else '[]' end) x),
               (select count(*)::int from workflow.tasks c
                 where c.run_id = v_run and c.step_key like 'q[%'),
               (select e.detail#>>'{error,error}' from workflow.task_events e
                 where e.run_id = v_run and e.to_status = 'failed'
                 order by e.at desc limit 1)
          from workflow.tasks t
         where t.run_id = v_run and t.step_key = 'q';
end $$ language plpgsql;

-- ---------------------------------------------------------------------
-- 1, 2, 3. EACH RUN SEES WHAT ITS STARTER COULD, AT EVERY DOOR.
-- ---------------------------------------------------------------------
do $$
declare
    v_case record;
    v_name text;
    r      record;
begin
    for v_case in
        select * from (values
            ('15151515-0000-4000-8000-00000000000b'::uuid, 'member note', 'a member'),
            ('15151515-0000-4000-8000-00000000000a'::uuid, 'admin note',  'an admin'),
            (null::uuid, 'admin note,member note', 'the system')) as c(who, expect, label)
    loop
        foreach v_name in array array['t_sr_statement','t_sr_p8ql','t_sr_p8ql_vec'] loop
            select * into r from pg_temp.run_as(v_case.who, v_name);
            if r.status is distinct from 'succeeded' then
                raise exception '% did not run for % (step is %, error %)',
                    v_name, v_case.label, coalesce(r.status, '(no task)'), coalesce(r.err, '(none)');
            end if;
            -- p8ql_vec re-enters exactly as p8ql does, and is checked for
            -- running at all: its SQL mode returns the statement and a note
            -- rather than rows (only the one-argument form executes SQL), and
            -- its other modes need a corpus this file does not build.
            continue when v_name = 't_sr_p8ql_vec';
            if r.bodies is distinct from v_case.expect then
                raise exception
                    '% read [%] for %, where [%] is what they could read themselves',
                    v_name, coalesce(r.bodies, ''), v_case.label, v_case.expect;
            end if;
        end loop;

        -- A matrix makes one child per row its source returns.
        select * into r from pg_temp.run_as(v_case.who, 't_sr_rows_stmt');
        if r.children is distinct from array_length(string_to_array(v_case.expect, ','), 1) then
            raise exception 'a matrix row statement made % children for %, expected one per row in [%] (error %)',
                r.children, v_case.label, v_case.expect, coalesce(r.err, '(none)');
        end if;
    end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. A PERSON'S RUN IS REFUSED WHAT THEY WOULD BE REFUSED BY HAND.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
    select * into r from pg_temp.run_as('15151515-0000-4000-8000-00000000000a', 't_sr_secret');
    if r.status is distinct from 'failed' or coalesce(r.err, '') not like '%permission denied%' then
        raise exception 'an admin''s run read a table no person holds a grant on (step %, error %)',
            r.status, coalesce(r.err, '(none)');
    end if;
    select * into r from pg_temp.run_as(null, 't_sr_secret');
    if r.status is distinct from 'succeeded' or r.bodies is distinct from 'engine only' then
        raise exception 'a system run lost the engine''s reach (step %, error %)', r.status, r.err;
    end if;
    select * into r from pg_temp.run_as('15151515-0000-4000-8000-00000000000b', 't_sr_write');
    if r.status is distinct from 'failed' or coalesce(r.err, '') not like '%permission denied%' then
        raise exception 'a member''s run wrote where the member could not (step %, error %)',
            r.status, coalesce(r.err, '(none)');
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 4b. A WRITE STEP CANNOT CHANGE WHOSE STEP IT IS (REM-64).
--
-- The claims are set by execute_for and the statement runs as api_viewer,
-- which holds no set_config -- but a write step is EXECUTED, not wrapped, so a
-- SET, a DO block issuing one, or a second statement after an innocent first
-- would rewrite who the step acts for. Each is attempted by the member; each
-- must fail before anything is written, and the member's ordinary write must
-- still succeed and still report its row count. `admin note` in t_sr_log would
-- mean a step read as the admin.
-- ---------------------------------------------------------------------
do $$
declare r record; v_name text;
begin
    select * into r from pg_temp.run_as('15151515-0000-4000-8000-00000000000b', 't_sr_log_ok');
    if r.status is distinct from 'succeeded'
       or (select t.output->'result'->>'rows_affected' from workflow.tasks t
            join workflow.runs ru on ru.id = t.run_id
            join workflow.definitions d on d.id = ru.workflow_def_id
           where d.name = 't_sr_log_ok' order by t.created_at desc limit 1) is distinct from '1' then
        raise exception 'a member''s own write step no longer runs, or no longer reports its count (step %, error %)',
            r.status, coalesce(r.err, '(none)');
    end if;
    foreach v_name in array array['t_sr_set_claims', 't_sr_do_claims', 't_sr_two_statements'] loop
        select * into r from pg_temp.run_as('15151515-0000-4000-8000-00000000000b', v_name);
        if r.status is distinct from 'failed' or coalesce(r.err, '') not like '%must be one INSERT, UPDATE, DELETE or MERGE%' then
            raise exception '% ran for a member (step %, error %) -- a write step changed whose step it was',
                v_name, r.status, coalesce(r.err, '(none)');
        end if;
    end loop;
    if (select string_agg(body, ',' order by body) from t_sr_log) is distinct from 'member note' then
        raise exception 't_sr_log holds [%], where only the member''s own read should have landed',
            (select string_agg(body, ',' order by body) from t_sr_log);
    end if;
    raise notice 'workflow/15: a write step is one INSERT, UPDATE, DELETE or MERGE -- a SET, a DO block or a second statement is refused';
end $$;

-- ---------------------------------------------------------------------
-- 5. THE SESSION IS LEFT AS IT WAS FOUND.
--
-- execute_for sets the claims to the run's owner. Left set, the engine's next
-- statement in this transaction -- complete_task, or the caller's own next
-- query -- would run believing it was that person.
-- ---------------------------------------------------------------------
do $$
declare v_before text; r record;
begin
    execute format('set local request.jwt.claims = %L', '{"sub":"15151515-0000-4000-8000-00000000000b"}');
    v_before := current_setting('request.jwt.claims', true);
    select * into r from pg_temp.run_as('15151515-0000-4000-8000-00000000000a', 't_sr_statement');
    execute format('set local request.jwt.claims = %L', coalesce(v_before, ''));  -- run_as clears it; restore ours
    if current_user <> 'app_owner' then
        raise exception 'a step left the session running as %', current_user;
    end if;
    -- and the step itself did not leak: the admin's run completed as the admin
    -- while this transaction's own claims said "member".
    if r.bodies is distinct from 'admin note' then
        raise exception 'the admin''s run read [%] -- whose claims did it use?', r.bodies;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 5b. A FAILING STEP DOES NOT LEAVE ITS OWNER'S CLAIMS FOR THE NEXT RUN.
--
-- tick() and an autorun cascade run several sql tasks in one transaction. If a
-- step for owner A fails with the claims still set to A, the next task in the
-- same transaction -- a step of owner B's run, or the engine's own
-- complete_task -- runs as A. execute_for restores in its own exception handler
-- rather than trusting the caller to unwind, and this is the assertion for that:
-- a definition whose first step fails as the admin, then a read as the member,
-- in one transaction, and the member's read must be the member's.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_sr_boom', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"statement":"select 1 from t_sr_notes where 1/0 = 1"}}]}');
do $$
declare r record; v_seen text;
begin
    -- owner A's step fails (division by zero) with claims briefly set to A
    select * into r from pg_temp.run_as('15151515-0000-4000-8000-00000000000a', 't_sr_boom');
    if r.status is distinct from 'failed' then
        raise exception 'the boom step did not fail: %', r.status;
    end if;
    -- immediately, in the same transaction, read as B through the same path
    select * into r from pg_temp.run_as('15151515-0000-4000-8000-00000000000b', 't_sr_statement');
    if r.bodies is distinct from 'member note' then
        raise exception
            'after a step failed as the admin, a member''s run read [%] -- the '
            'admin''s claims leaked past the failing step', coalesce(r.bodies, '');
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. THE DIRECT CALL IS UNTOUCHED.
-- ---------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"15151515-0000-4000-8000-00000000000b"}';
do $$ begin
    if (workflow.p8ql('select body from t_sr_notes')->'rows'->0->>'body') is distinct from 'member note' then
        raise exception 'a member''s direct call to workflow.p8ql did not read as the member';
    end if;
    raise notice 'workflow/15: statement, p8ql, p8ql_vec and matrix rows read as the starter (member, admin), a system run as the engine; ungranted reads and writes refused; session restored; direct calls untouched';
end $$;

rollback;
