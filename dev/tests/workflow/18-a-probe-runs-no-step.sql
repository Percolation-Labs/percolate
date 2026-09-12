-- A PROBE PLANS A STATEMENT. IT DOES NOT RUN WHAT COMES AFTER THE SEMICOLON.
--
-- `workflow.plan_probe` is SECURITY INVOKER, granted to `authenticated`, and
-- its own comment promises it "runs no step". Its write branch was
--
--     execute 'explain (format json) ' || v_stmt into v_plan;
--
-- and plpgsql's EXECUTE runs a string of several statements one after another,
-- so EXPLAIN covered the FIRST and Postgres ran the rest. Measured on a live
-- 0.2.0 before the fix: `explain (format json) insert into t values (1);
-- insert into t values (99); select 1` explained the first insert, PERFORMED
-- the second, and returned a plan with no error. The trailing `select 1`
-- matters -- without it plpgsql's INTO raises 42601 and the subtransaction
-- takes the write back, which is why a payload that ends in a query is the one
-- to assert against.
--
-- The read branch two lines below it was already wrapped as `select * from
-- (%s) t`, where nothing but a query parses. The write branch now goes through
-- workflow.one_write_statement, the same home `execute_as_viewer` asks (that
-- one is covered by workflow/15 §4b, and this file is its sibling: the rule
-- had one home and one of its two callers).
--
-- WHAT THIS ASSERTS
--   1. a second statement smuggled into a `write: true` step's statement does
--      not run, and the probe reports the step as unplannable rather than ok;
--   2. a `SET` of request.jwt.claims after an innocent first statement does not
--      change whose claims the session carries;
--   3. an ordinary write step still probes clean, so the wrapping did not close
--      the door by breaking the feature;
--   4. the same for a read step, which was never the vulnerable branch.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

create table t_probe_target (v int);
grant insert, select on t_probe_target to authenticated;

insert into rbac.users (id, email) values
('18181818-0000-4000-8000-00000000000a', 'prober@test.invalid')
on conflict (id) do nothing;
insert into rbac.user_roles (user_id, role) values
('18181818-0000-4000-8000-00000000000a', 'admin')
on conflict do nothing;

-- The three definitions, written as the owner. A workflow author would reach
-- these through define_yaml; the spec is what plan_probe reads, and writing it
-- directly keeps this file about the probe rather than about the compiler.
insert into workflow.definitions (name, spec) values
('t_probe_smuggles_a_write', '{"steps":[
    {"key":"writes", "kind":"sql", "queue":"none",
     "input":{"write":true,
              "statement":"insert into t_probe_target values (1); insert into t_probe_target values (99); select 1"}}
 ]}'),
('t_probe_smuggles_a_set', '{"steps":[
    {"key":"writes", "kind":"sql", "queue":"none",
     "input":{"write":true,
              "statement":"insert into t_probe_target values (2); set request.jwt.claims = ''{\"sub\":\"18181818-0000-4000-8000-00000000000b\"}''; select 1"}}
 ]}'),
('t_probe_ordinary', '{"steps":[
    {"key":"writes", "kind":"sql", "queue":"none",
     "input":{"write":true, "statement":"insert into t_probe_target values (3)"}},
    {"key":"reads", "kind":"sql", "queue":"none",
     "input":{"statement":"select v from t_probe_target"}}
 ]}');

-- ---------------------------------------------------------------------
-- 1 + 2. THE SECOND STATEMENT DOES NOT RUN.
-- ---------------------------------------------------------------------
-- PROBED AS api_viewer, AND THAT IS THE HONEST ROLE RATHER THAN THE ALARMING
-- ONE. plan_probe is SECURITY INVOKER and granted to `authenticated`, so the
-- body has the caller's reach -- and `authenticated` holds no SELECT on
-- workflow.definitions (`{app_owner=arwdDxtm, api_viewer=r}`), so today a
-- signed-in caller over PostgREST gets `permission denied for table
-- definitions` before reaching the EXECUTE at all. The reach is api_viewer's:
-- it reads definitions, it inherits the grant through `grant authenticated to
-- api_viewer`, and it is the role every *_api view and every person's workflow
-- step already runs as.
--
-- Which is why this was worth fixing BEFORE the grant that would open it: the
-- outstanding change to workflow.definitions -- an owner_id, an org_id and a
-- scope policy, so one author cannot append a version to another's workflow
-- name -- ends with `grant select on workflow.definitions to authenticated`,
-- and on the day that lands the EXECUTE would have been reachable by anyone
-- who can sign in. An assertion written here holds whichever role gets there.
--
-- AND THE ROLE MOVED UNDER IT, WHICH IS WHAT THAT LAST SENTENCE IS FOR.
-- REM-81 revoked plan_probe from `authenticated` -- with it plan_catalog,
-- plan_defects, plan_document and plan_graph -- because all five expand a
-- workflow's `spec`, and integration-rbac.sql §1 refuses to publish `spec` to
-- that role. api_viewer inherited the grant through `grant authenticated to
-- api_viewer` and no longer has it, so the probe below now raises `permission
-- denied for function plan_probe` as that role.
--
-- So this runs as app_owner, which is who reaches plan_probe today: it is an
-- operator diagnostic until workflow.definitions adopts scope (REM-42), and on
-- the day the grants come back this goes back to api_viewer and asserts the
-- same thing. Nothing about what is being tested changes -- whether EXPLAIN
-- runs the statement after the semicolon is a property of plan_probe's body,
-- not of who called it -- and the claims are still set, because §2 asks what
-- the session's claims are after the probe.
--
-- The wrapping still matters with the grant gone: workflow.execute_as_viewer
-- shares one_write_statement and IS reached by a person's workflow step, which
-- is the sibling workflow/15 §4b covers.
set local role app_owner;
set local request.jwt.claims = '{"sub":"18181818-0000-4000-8000-00000000000a"}';

do $$
declare
    v_verdict text;
begin
    select verdict into v_verdict
      from workflow.plan_probe('t_probe_smuggles_a_write')
     where step = 'writes' and probe = 'parses';

    if (select count(*) from t_probe_target) <> 0 then
        raise exception
            'PROBING A WORKFLOW WROTE A ROW: plan_probe ran the statement after the '
            'semicolon. EXPLAIN covers the FIRST statement of the string and plpgsql '
            'runs the rest -- measured: `explain (format json) insert ...; insert ...; '
            'select 1` explained the first and performed the second. The write branch '
            'has to go through workflow.one_write_statement.';
    end if;
    if v_verdict is distinct from 'fail' then
        raise exception
            'the probe reported [%] for a statement that is two statements; it has to '
            'be unplannable, not ok', coalesce(v_verdict, '<no row>');
    end if;
end $$;

-- The same door, carrying a SET instead of a DDL: this is the one that changes
-- whose rows every later step acts on (REM-64).
do $$
declare v_sub text;
begin
    perform workflow.plan_probe('t_probe_smuggles_a_set');

    v_sub := current_setting('request.jwt.claims', true)::jsonb->>'sub';
    if v_sub is distinct from '18181818-0000-4000-8000-00000000000a' then
        raise exception
            'probing a workflow rewrote the session claims to [%] -- every later '
            'statement in this transaction would act as somebody else', coalesce(v_sub, '');
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 3 + 4. AND THE PROBE STILL PROBES.
-- ---------------------------------------------------------------------
-- The control. Without it this file passes on a plan_probe that refuses
-- everything, which is a fix nobody would notice had broken the feature.
do $$
declare v_verdict text; v_detail text;
begin
    select verdict, detail into v_verdict, v_detail
      from workflow.plan_probe('t_probe_ordinary')
     where step = 'writes' and probe = 'parses';
    if v_verdict is distinct from 'ok' then
        raise exception
            'an ordinary one-statement write no longer probes: % (%)',
            coalesce(v_verdict, '<no row>'), coalesce(v_detail, '');
    end if;

    select verdict into v_verdict
      from workflow.plan_probe('t_probe_ordinary')
     where step = 'reads' and probe = 'parses';
    if v_verdict is distinct from 'ok' then
        raise exception 'a read step no longer probes: %', coalesce(v_verdict, '<no row>');
    end if;

    if (select count(*) from t_probe_target) <> 0 then
        raise exception 'probing the ordinary workflow wrote a row';
    end if;

    raise notice 'workflow/18: a probe of a write step plans one statement and runs none -- a smuggled second write and a smuggled SET both refused, an ordinary write and a read still ok';
end $$;

rollback;
