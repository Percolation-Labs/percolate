-- AN IDEMPOTENCY KEY IS THE CALLER'S, AND STARTING A WORKFLOW NEVER HANDS BACK
-- SOMEBODY ELSE'S RUN (REM-77).
--
-- `start_workflow` is idempotent on `external_id` and did not ask whose run it
-- had matched. The key is a value the CALLER picks -- a ticket reference, a
-- document id, a date -- so two people pick the same string, and the second one
-- was handed the first one's run id: an existence oracle over another tenant's
-- work, plus a run id trusted by whatever the caller did with it next. Found
-- while classifying every reachable SECURITY DEFINER function for REM-46, where
-- `rbac/14` declared it as a gap rather than a check.
--
-- TWO PEOPLE WHO REALLY EXIST. `workflow.runs.owner_id` references
-- `rbac.users`, and a tenancy probe run in a database where the second person
-- has no row is a correct answer about nobody -- the failure
-- our postmortems record twice.
-- So the two identities here are rows, inserted and rolled back with everything
-- else this file writes.
--
-- WHAT EACH SECTION MEASURES, because "it is scoped now" is three different
-- claims:
--   1. two people, one external_id: each gets their own run, neither is handed
--      the other's, and a repeat by the same person is still one run.
--   2. the scope is a CONSTRAINT, not just a predicate: one owner cannot hold
--      two runs under one key, and neither can the system.
--   3. the permission reach is real: the rule is assert_run_access's, so
--      somebody holding workflow_runs:select matches a run they may read --
--      which is what makes §1 a tenancy boundary rather than owner equality.
--   4. the engine is not a tenant: tick() fires a schedule with no identity
--      and depends on this key, so a caller with no identity still matches
--      every run under it.
\set ON_ERROR_STOP on
begin;
set local role app_owner;

insert into rbac.users (id, email) values
  ('77000000-0000-0000-0000-000000000001', 'rem77-ana@example.test'),
  ('77000000-0000-0000-0000-000000000002', 'rem77-bo@example.test'),
  ('77000000-0000-0000-0000-000000000003', 'rem77-auditor@example.test')
on conflict do nothing;

-- A workflow of its own, so the file depends on no seeded definition, and ONE
-- QUEUED STEP so nothing executes: what is under test is which run the key
-- resolves to, and a step that ran would bring its own reasons to fail.
-- Defined before any claims are set, which is where may_define()'s operator
-- branch applies.
select workflow.define_yaml($y$
name: rem77_probe
steps:
  - id: only
    work: true
$y$);

-- ---------------------------------------------------------------------
-- 1. TWO PEOPLE, ONE external_id.
-- ---------------------------------------------------------------------
do $$
declare
    v_ana   uuid := '77000000-0000-0000-0000-000000000001';
    v_bo    uuid := '77000000-0000-0000-0000-000000000002';
    v_key   text := 'ticket-4291';
    v_a     uuid; v_b uuid; v_again uuid; v_owner uuid;
begin
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_ana, 'role', 'authenticated')::text);
    v_a := workflow.start_workflow('rem77_probe', '{"who":"ana"}'::jsonb, v_key);
    select owner_id into v_owner from workflow.runs where id = v_a;
    if v_owner is distinct from v_ana then
        raise exception 'the run Ana started is owned by % rather than by her -- '
                        'this file cannot measure a tenancy boundary in a database '
                        'where the runs have no owners', v_owner;
    end if;

    -- The same key, chosen independently by somebody else.
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_bo, 'role', 'authenticated')::text);
    v_b := workflow.start_workflow('rem77_probe', '{"who":"bo"}'::jsonb, v_key);

    if v_b = v_a then
        raise exception 'start_workflow handed Bo the run Ana started (%). Naming '
                        'another person''s external_id returns their run id and says '
                        'a run under that key exists', v_a;
    end if;
    select owner_id into v_owner from workflow.runs where id = v_b;
    if v_owner is distinct from v_bo then
        raise exception 'Bo''s run is owned by % rather than by Bo', v_owner;
    end if;
    if (select input->>'who' from workflow.runs where id = v_b) is distinct from 'bo' then
        raise exception 'Bo''s run did not start from Bo''s input -- he was given a '
                        'run somebody else described';
    end if;

    -- ...AND IT IS STILL IDEMPOTENT, which is the half a scoping fix breaks by
    -- starting a fresh run every time. Bo repeats his own call.
    v_again := workflow.start_workflow('rem77_probe', '{"who":"bo"}'::jsonb, v_key);
    if v_again is distinct from v_b then
        raise exception 'a repeat of Bo''s own key started a second run (% then %) -- '
                        'idempotence is gone', v_b, v_again;
    end if;

    -- And Ana's key still resolves to Ana's run, with Bo's row now sitting on
    -- the same value.
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_ana, 'role', 'authenticated')::text);
    v_again := workflow.start_workflow('rem77_probe', '{"who":"ana"}'::jsonb, v_key);
    if v_again is distinct from v_a then
        raise exception 'Ana''s own key stopped resolving to her run once somebody '
                        'else used the same value (% then %)', v_a, v_again;
    end if;

    raise notice 'workflow/17: two people used one external_id and each got their own run (% and %), and a repeat still returns one', v_a, v_b;
end $$;

-- ---------------------------------------------------------------------
-- 2. THE SCOPE IS A CONSTRAINT, NOT ONLY A PREDICATE.
--
-- A match narrowed without the uniqueness narrowing with it is worse than the
-- defect: the second person's INSERT then fails on the constraint, which still
-- says the key exists and now also refuses work that should have succeeded. So
-- the guarantee is asserted where a violation is refused -- and in both
-- directions, because the null owner_id of a system-started run means SYSTEM
-- rather than "no scope", and two system runs under one key must still collide
-- (that is what tick()'s retry rests on).
-- ---------------------------------------------------------------------
do $$
declare
    v_def   uuid;
    v_ana   uuid := '77000000-0000-0000-0000-000000000001';
    v_state text;
begin
    select id into v_def from workflow.definitions
     where name = 'rem77_probe' order by version desc limit 1;

    -- One owner, one key, twice.
    begin
        insert into workflow.runs (workflow_def_id, owner_id, external_id)
        values (v_def, v_ana, 'ticket-4291');
        raise exception 'a second run under Ana''s own key was accepted: the '
                        'idempotency key is not unique per owner, so a race '
                        'between two of her calls mints two runs';
    exception when unique_violation then
        null;   -- refused, by the index
    end;

    -- Two system runs, one key. The nulls must NOT be distinct here.
    insert into workflow.runs (workflow_def_id, owner_id, external_id)
    values (v_def, null, 'schedule:rem77:2026-09-12T00:00Z');
    begin
        insert into workflow.runs (workflow_def_id, owner_id, external_id)
        values (v_def, null, 'schedule:rem77:2026-09-12T00:00Z');
        raise exception 'two system-owned runs were accepted under one key -- a '
                        'retried tick can double-fire a schedule, which is what '
                        '§19 uses external_id to prevent';
    exception when unique_violation then
        null;
    end;

    -- And a run with NO key is not a run that collides with every other one.
    insert into workflow.runs (workflow_def_id, owner_id, external_id)
    values (v_def, v_ana, null);
    insert into workflow.runs (workflow_def_id, owner_id, external_id)
    values (v_def, v_ana, null);

    raise notice 'workflow/17: the key is unique per owner at the index, for a person and for the system, and an absent key constrains nothing';
end $$;

-- ---------------------------------------------------------------------
-- 3. THE RULE IS assert_run_access'S, AND THE PERMISSION REACH IS PART OF IT.
--
-- spec.md §4: the match is among the runs the caller MAY SEE -- their own, or
-- one their permissions reach. Somebody holding workflow_runs:select can read
-- that run through runs_api already, so resolving their key to it reveals
-- nothing they did not have; what §1 refuses is the caller who holds nothing.
-- Asserted because it is the difference between a tenancy boundary and plain
-- owner equality, and because it is the branch that would silently disappear
-- if the predicate were rewritten as `owner_id = current_user_id()`.
-- ---------------------------------------------------------------------
do $$
declare
    v_auditor uuid := '77000000-0000-0000-0000-000000000003';
    v_ana     uuid := '77000000-0000-0000-0000-000000000001';
    v_ana_run uuid;
    v_got     uuid;
begin
    select id into v_ana_run from workflow.runs
     where external_id = 'ticket-4291' and owner_id = v_ana;

    insert into rbac.roles (name, description) values ('rem77_reader', 'test-only, rolled back')
    on conflict do nothing;
    insert into rbac.role_permissions (role, resource, action)
    values ('rem77_reader', 'workflow_runs', 'select') on conflict do nothing;
    insert into rbac.user_roles (user_id, role) values (v_auditor, 'rem77_reader')
    on conflict do nothing;

    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_auditor, 'role', 'authenticated')::text);
    if not workflow.may_access_run(v_ana_run, 'select') then
        raise exception 'workflow_runs:select does not reach Ana''s run, so this '
                        'section is measuring nothing about the permission branch';
    end if;
    v_got := workflow.start_workflow('rem77_probe', '{"who":"auditor"}'::jsonb, 'ticket-4291');
    if v_got is distinct from v_ana_run then
        raise exception 'a caller whose permissions reach Ana''s run matched % rather '
                        'than it -- the predicate is owner equality, not '
                        'assert_run_access''s rule', v_got;
    end if;

    raise notice 'workflow/17: the reach is the run rule''s, not owner equality -- workflow_runs:select resolves the key to the run it may read';
end $$;

-- ---------------------------------------------------------------------
-- 4. THE ENGINE IS NOT A TENANT.
--
-- tick() fires a schedule as `scheduler` with no JWT and makes the fire
-- idempotent through this key, then stamps the schedule's owner onto the run
-- afterwards (§21j) -- so by the next tick the run belongs to somebody the
-- ticker is not, and a ticker held to that person's scope would start the
-- second run for the same minute that the key exists to prevent. A caller with
-- no identity is an operator, authorized by the grant, and matches every run
-- under the key.
-- ---------------------------------------------------------------------
do $$
declare
    v_ana     uuid := '77000000-0000-0000-0000-000000000001';
    v_ana_run uuid;
    v_got     uuid;
begin
    select id into v_ana_run from workflow.runs
     where external_id = 'ticket-4291' and owner_id = v_ana;

    set local request.jwt.claims = '';
    if rbac.current_user_id() is not null or not rbac.is_operator() then
        raise exception 'this session is not the identity-free caller the section '
                        'is about (user %, operator %)',
                        rbac.current_user_id(), rbac.is_operator();
    end if;

    v_got := workflow.start_workflow('rem77_probe', '{"who":"the engine"}'::jsonb, 'ticket-4291');
    if v_got is distinct from v_ana_run then
        raise exception 'an identity-free caller started a second run under a key '
                        'that already had one (% beside %) -- a retried tick would '
                        'double-fire', v_got, v_ana_run;
    end if;

    raise notice 'workflow/17: a caller with no identity still matches every run under the key, which is what tick() rests on';
end $$;

rollback;
