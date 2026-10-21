-- EVERY FUNCTION THAT RE-MINTS THE CALLER'S CLAIMS IS DECLARED, AND SAYS WHAT
-- IT DROPS.
--
-- REM-44 closed the door a person could walk through: `set_config` is revoked
-- from PUBLIC and held only by authenticator, app_owner, worker and scheduler
-- (user-rbac/roles.sql §6). That leaves a small set of SECURITY DEFINER
-- functions that legitimately write `request.jwt.claims` on somebody's behalf
-- -- a workflow step run for its owner, a lake refine run for a task's owner.
-- The door is not the hazard any more. What each of those functions PUTS in
-- the claims is.
--
-- WHY THAT IS WORTH A GATE. A claim set is not one fact. `sub` says who, and
-- `orgs` -- when a token carries it -- narrows which of that person's
-- organisations this session may reach; rbac.current_org_ids() reads a MISSING
-- `orgs` as every membership, so dropping the key is not neutral, it widens.
-- REM-48 fixed exactly this in the agent runtime, by carrying the verified
-- claims whole instead of rebuilding `{"sub": ...}`. The three functions below
-- rebuild, and every one of them rebuilds narrower than the shape REM-48
-- settled on -- not because anyone decided they should, but because each
-- answered the question separately and nothing was holding the answer.
--
-- DECLARED, NOT INFERRED, for the reason rbac/14 gives at length: a regex over
-- a function body is a rule about prose. So each function states what it
-- writes and why, and the catalog is held to the list in both directions.
--
-- WHAT THE ANSWER IS TODAY, and it is the reason this gate is not also a fix.
-- `workflow.runs` carries `owner_id`, and since REM-171 the starter's actor and
-- credential (`started_actor`, `started_credential_id`, set from the verified
-- claims by set_run_owner), which execute_for mints back into every step -- so
-- an agent's run keeps the agent's human-only refusals, scopes and revocation.
-- It still carries no `orgs`, so an org narrowing is gone at start_workflow.
-- This file records the current answer so that the fourth function cannot
-- quietly give a different one.
--
-- Reads the catalog and rbac only; stages no spec file.
\set ON_ERROR_STOP on

begin;

create temp table t16_declared (fn text, writes text, why text) on commit drop;
insert into t16_declared values
('workflow.execute_for(uuid,text,boolean,jsonb)', 'sub, role, actor, api_key_id',
 'the run''s owner, for a step''s statement, with the actor and credential that '
 'started the run (REM-171), so rbac.decide narrows each step as it narrowed the '
 'starter. Drops orgs: a run stores owner_id and its starter, not the org '
 'narrowing of the claims it was started with.'),
('content.lake_resolve(uuid,text,text[])', 'sub',
 'the lake task''s owner, resolving dataset names as that person. Same reason '
 'as execute_for, one layer out: the scope comes from lake_task_scope(task), '
 'which reads the task, and a task carries an owner rather than claims.'),
('workflow.tick(timestamp with time zone)', 'sub, role, actor, api_key_id',
 'the schedule''s owner, with the actor and credential that created the schedule, '
 'through workflow.claims_as -- execute_for''s shape -- for the start alone, so the '
 'steps start_workflow drains run as the owner from the first (REM-1121). Restored '
 'after the start and in the per-schedule handler. Drops orgs, as execute_for does.'),
('workflow.start_child_workflow(uuid,text,jsonb)', 'sub, role, actor, api_key_id',
 'the parent run''s owner and starter, through workflow.claims_as, only when the '
 'caller carries no user (a worker completing the parent task), so the child is '
 'theirs and resolves its definition as them (REM-1121). Restored on both exit '
 'paths. Drops orgs, as execute_for does.'),
('aiq.render_facet_public(text)', 'role',
 'no user and not an operator: {"role":"web_anon"}, so a captured schema document holds '
 'only what a signed-out reader sees, never an operator''s view of private agents and '
 'definitions (REM-1122). It drops everything, which is the point; restored on both paths.'),
('content.lake_existing(uuid,uuid,text,text)', 'sub',
 'the run owner, to ask may_write about a dataset that already exists. The '
 'owner is an ARGUMENT here rather than read from a task, and the function is '
 'granted to worker alone for that reason -- a caller who could choose p_owner '
 'would be choosing who they are.');

-- ---------------------------------------------------------------------
-- 0. THE SUBJECT EXISTS. An empty catalog side would pass (a) on nothing.
-- ---------------------------------------------------------------------
create temp view t16_actual as
select p.oid::regprocedure::text as fn
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in (select percolate.extension_schemas())
   -- Comments stripped, or every function that merely EXPLAINS the claims --
   -- aiq.sql_passthrough carries eight lines about them and writes none --
   -- lands in the list and the list stops meaning anything.
   and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ 'set_config\s*\(\s*''request\.jwt\.claims'''
   and p.prosecdef;

do $$
begin
    if (select count(*) from t16_actual) = 0 then
        raise exception 'no definer function writes request.jwt.claims -- either this '
                        'database is not the one this file describes, or the search '
                        'below has stopped matching, and every check here would pass '
                        'on nothing';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. (a) EVERY ONE IS DECLARED. The direction that catches the fourth.
-- ---------------------------------------------------------------------
do $$
declare v_missing text;
begin
    select string_agg(fn, E'\n  ') into v_missing
      from (select fn from t16_actual except select fn from t16_declared) q;
    if v_missing is not null then
        raise exception E'a SECURITY DEFINER function re-mints request.jwt.claims and is not '
            'declared in dev/tests/rbac/16:\n  %\n'
            'Say what it writes and why. If it drops `orgs`, say what carries the '
            'narrowing instead -- rbac.current_org_ids() reads a missing `orgs` as '
            'EVERY membership, so dropping it widens the caller (REM-48, REM-89).',
            v_missing;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. (b) EVERY DECLARATION IS REAL. The direction that stops ghosts.
-- ---------------------------------------------------------------------
do $$
declare v_gone text;
begin
    select string_agg(fn, E'\n  ') into v_gone
      from (select fn from t16_declared except select fn from t16_actual) q;
    if v_gone is not null then
        raise exception E'dev/tests/rbac/16 declares a claims re-minter that no longer '
            'writes claims (or no longer exists):\n  %\nRemove the row.', v_gone;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. NONE OF THEM IS REACHABLE BY A PERSON. This is the REM-44 invariant
--    restated where it can be checked per function rather than per role: a
--    signed-in caller who could execute any of these could choose who they
--    are, and the revoke would have bought nothing.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
    for r in select fn from t16_actual loop
        if has_function_privilege('authenticated', r.fn, 'execute')
           or has_function_privilege('web_anon', r.fn, 'execute')
           or has_function_privilege('api_viewer', r.fn, 'execute') then
            raise exception '% re-mints request.jwt.claims and a signed-in role may execute '
                'it -- that is REM-44 reopened one function at a time', r.fn;
        end if;
    end loop;
    raise notice 'rbac/16: % claims re-minters, all declared, none reachable by a person',
        (select count(*) from t16_actual);
end $$;

-- ---------------------------------------------------------------------
-- 4. AND THE READING THAT MAKES DROPPING `orgs` MATTER, asserted rather
--    than described: a claim set with no `orgs` key reaches every
--    organisation its subject belongs to. If this ever stops being true,
--    the `why` column above is wrong and the declarations need re-reading.
-- ---------------------------------------------------------------------
do $$
declare
    v_user uuid := '00000000-0000-0000-0000-00000000f16a';
    v_o1   uuid := '00000000-0000-0000-0000-0000000f16a1';
    v_o2   uuid := '00000000-0000-0000-0000-0000000f16a2';
    n_all int; n_one int;
begin
    insert into rbac.users (id, email) values (v_user, 'rbac16@example.com')
      on conflict do nothing;
    insert into rbac.orgs (id, name, slug) values
      (v_o1, 'rbac16-one', 'rbac16-one'), (v_o2, 'rbac16-two', 'rbac16-two')
      on conflict do nothing;
    insert into rbac.org_members (org_id, user_id, role) values
      (v_o1, v_user, 'member'), (v_o2, v_user, 'member') on conflict do nothing;

    perform set_config('request.jwt.claims',
        jsonb_build_object('sub', v_user)::text, true);
    select count(*) into n_all from rbac.current_org_ids();

    perform set_config('request.jwt.claims',
        jsonb_build_object('sub', v_user, 'orgs', jsonb_build_array(v_o1))::text, true);
    select count(*) into n_one from rbac.current_org_ids();

    if n_all <> 2 or n_one <> 1 then
        raise exception 'the premise of this file has changed: with no `orgs` claim a '
            'member of two orgs reached %, and narrowed to one reached % -- expected '
            '2 and 1. Re-read every `why` above.', n_all, n_one;
    end if;
    raise notice 'rbac/16: a missing `orgs` claim reaches 2 of 2 orgs, a narrowed one 1 -- '
                 'so what a re-minter omits is not a detail';
end $$;

rollback;
