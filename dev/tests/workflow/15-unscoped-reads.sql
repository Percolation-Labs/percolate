-- AN UNSCOPED READ RUNS ONLY FOR SOMEONE WHO COULD HAVE WRITTEN IT.
--
-- workflow-engine/schema.sql, may_read_unscoped. A step's statement and every
-- p8ql mode run as the engine owner, past row-level security. The open policy
-- defends that as "anyone who may define a workflow may read anything", and
-- defining is gated. Starting was not: the tour (scenarios/tour, act 8) had a
-- member of one org start the dev stack's `ask_uploads` and read another org's
-- runbook through its SEARCH step, under either sql_policy.
--
-- What this asserts, for each door an author's read goes through -- a `sql:`
-- statement, `p8ql`, `p8ql_vec`, and a matrix's row source:
--
--   1. a run started by a member is refused, terminally, with a reason;
--   2. a run started by an admin (workflows:update) still reads;
--   3. a system run (no owner) still reads;
--   4. a member's DIRECT call to workflow.p8ql is untouched -- it runs as them,
--      under RLS, and is not what this is about.
--
-- The member's refusal is the one that failed before the fix: every one of
-- these runs succeeded.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

insert into rbac.users (id, email) values
('15151515-0000-4000-8000-00000000000a', 'admin-unscoped@test.invalid'),
('15151515-0000-4000-8000-00000000000b', 'member-unscoped@test.invalid')
on conflict (id) do nothing;
insert into rbac.user_roles (user_id, role) values
('15151515-0000-4000-8000-00000000000a', 'admin'),
('15151515-0000-4000-8000-00000000000b', 'member')
on conflict do nothing;

create table t_ur_secret (v text);
insert into t_ur_secret values ('another org''s runbook');

insert into workflow.definitions (name, spec) values
('t_ur_statement', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"statement":"select v from t_ur_secret"}}]}'),
('t_ur_p8ql', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"function":"p8ql","args":["select 1 as n"]}}]}'),
('t_ur_p8ql_vec', '{"steps":[{"key":"q","kind":"sql","queue":"none",
    "input":{"function":"p8ql_vec","args":["select 1 as n", null]}}]}'),
('t_ur_rows_fn', '{"steps":[{"key":"q","kind":"matrix","queue":"none",
    "input":{"rows":{"function":"p8ql","args":["select 1 as n"]}, "max_fanout":5,
             "template":{"kind":"work","queue":"t-ur-never"}}}]}'),
('t_ur_rows_stmt', '{"steps":[{"key":"q","kind":"matrix","queue":"none",
    "input":{"rows":{"statement":"select v from t_ur_secret"}, "max_fanout":5,
             "template":{"kind":"work","queue":"t-ur-never"}}}]}');

-- One helper: start a workflow as a given caller (null = the system) and
-- report how its only step ended, with the error if it failed.
create function pg_temp.run_as(p_user uuid, p_name text)
returns table (status text, err text) as $$
declare v_run uuid;
begin
    perform set_config('request.jwt.claims',
        case when p_user is null then '' else json_build_object('sub', p_user)::text end, true);
    v_run := workflow.start_workflow(p_name, '{}'::jsonb);
    perform set_config('request.jwt.claims', '', true);
    return query
        select t.status,
               (select e.detail#>>'{error,error}' from workflow.task_events e
                 where e.run_id = v_run and e.to_status = 'failed'
                 order by e.at desc limit 1)
          from workflow.tasks t
         where t.run_id = v_run and t.step_key = 'q';
end $$ language plpgsql;

-- ---------------------------------------------------------------------
-- 1. A MEMBER'S RUN IS REFUSED, AT EVERY DOOR.
-- ---------------------------------------------------------------------
do $$
declare
    v_name text;
    r record;
begin
    foreach v_name in array array['t_ur_statement','t_ur_p8ql','t_ur_p8ql_vec',
                                  't_ur_rows_fn','t_ur_rows_stmt'] loop
        select * into r from pg_temp.run_as('15151515-0000-4000-8000-00000000000b', v_name);
        if r.status is distinct from 'failed' then
            raise exception
                '% ran for a member, who may not define workflows (step is %). It reads '
                'as the engine owner, so it read past row-level security for them.',
                v_name, coalesce(r.status, '(no task)');
        end if;
        if coalesce(r.err, '') not like '%may not define workflows%' then
            raise exception '% failed for a member, but not for this reason: %',
                v_name, coalesce(r.err, '(none)');
        end if;
    end loop;
end $$;

-- ---------------------------------------------------------------------
-- 2 and 3. AN ADMIN'S RUN AND A SYSTEM RUN STILL READ.
--
-- A fix that refused everyone would pass §1. The trade the open policy makes
-- is kept for exactly the people it names.
-- ---------------------------------------------------------------------
do $$
declare
    v_who  uuid;
    v_name text;
    r record;
begin
    foreach v_who in array array['15151515-0000-4000-8000-00000000000a'::uuid, null::uuid] loop
        foreach v_name in array array['t_ur_statement','t_ur_p8ql','t_ur_p8ql_vec'] loop
            select * into r from pg_temp.run_as(v_who, v_name);
            if r.status is distinct from 'succeeded' then
                raise exception '% did not run for % (step is %, error %)',
                    v_name, coalesce(v_who::text, 'the system'),
                    coalesce(r.status, '(no task)'), coalesce(r.err, '(none)');
            end if;
        end loop;
        -- A matrix whose rows came back has expanded; its children wait on a
        -- queue nobody serves, which is all this needs.
        select * into r from pg_temp.run_as(v_who, 't_ur_rows_stmt');
        if r.status = 'failed' then
            raise exception 'a matrix row statement was refused for %: %',
                coalesce(v_who::text, 'the system'), coalesce(r.err, '(none)');
        end if;
    end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. THE DIRECT CALL IS UNTOUCHED.
--
-- Outside a step workflow.p8ql is SECURITY INVOKER and runs as the caller
-- under RLS. The guard keys on workflow.current_run_id, and must not evaluate
-- anything `authenticated` cannot execute: the SQL-mode guard beside it has
-- already failed that way twice (13-open-sql.sql §5b).
-- ---------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"15151515-0000-4000-8000-00000000000b"}';
do $$ begin
    if (workflow.p8ql('select 1 as n')->'rows'->0->>'n') is distinct from '1' then
        raise exception 'a member''s direct call to workflow.p8ql was refused';
    end if;
    raise notice 'workflow/15: member refused at statement, p8ql, p8ql_vec and both matrix row sources; admin, system and direct calls untouched';
end $$;

rollback;
