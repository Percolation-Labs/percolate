-- A RUN BELONGS TO ITS DEFINITION'S ORG, NOT TO WHICHEVER ORG THE CALLER
-- HAPPENS TO BE IN (REM-42, spec.md §17(b)).
--
-- `workflow.definitions` gained `org_id` in REM-91, and `start_workflow` went
-- on ignoring it: a run was stamped with the deployment's shared tier whatever
-- org its workflow belonged to. Measured before this change, on the database
-- `dev/ci-database.sh` builds -- a definition with `org_id = <org A>` and
-- `visibility = 'org'`, started by a member of org A, produced a run with
-- `rbac.is_shared_org(org_id)` true.
--
-- WHY THAT IS NOT A COSMETIC FIELD. `world-model-ingestion/lake.md` §8 records
-- the same gap from the other end: "lake outputs land in the shared org, where
-- dataset names are unique across every user, and a second user's `sales` is
-- refused as not theirs. Starting a run in a named org is `workflow-engine`'s
-- to add." `content.datasets` is scoped by `org_id`, so a run with no org can
-- only write into a namespace every tenant shares.
--
-- WHAT EACH SECTION MEASURES. The derivation on its own is one line and would
-- be worth little to assert; what makes it a tenancy rule is the four things
-- around it, and each of those is a way a working-looking version gets it
-- wrong:
--   1. the derivation itself, against the shared tier it used to produce.
--   2. the CALLER'S orgs do not decide it. This is §17(b)'s whole motivation --
--      "which makes the org unambiguous when the caller is in several" -- and a
--      version that read `rbac.current_org_ids()` instead of the definition
--      would pass section 1 and fail here.
--   3. a shared-tier definition still produces a shared run. §17(b): "a
--      workflow nobody owns produces a run nobody owns". Assigning anything
--      else would have to invent a tenant.
--   4. an org supplied explicitly is not overwritten.
--   5. the run is not made org-VISIBLE. Belonging to an org and being readable
--      by everyone in it are different claims, and widening every run of a
--      shared workflow to the second one would be a disclosure nobody asked
--      for.
\set ON_ERROR_STOP on
begin;
set local role app_owner;

insert into rbac.users (id, email) values
  ('42000000-0000-0000-0000-000000000001', 'rem42-ana@example.test'),
  ('42000000-0000-0000-0000-000000000002', 'rem42-bo@example.test')
on conflict do nothing;

insert into rbac.orgs (id, slug, name) values
  ('42000000-0000-0000-0000-0000000000aa', 'rem42-a', 'REM-42 org A'),
  ('42000000-0000-0000-0000-0000000000bb', 'rem42-b', 'REM-42 org B')
on conflict do nothing;

-- ANA IS IN BOTH ORGS, which is what section 2 needs: with one membership,
-- "the definition's org" and "the caller's org" are the same value and the
-- section cannot tell a correct derivation from a wrong one.
insert into rbac.org_members (org_id, user_id) values
  ('42000000-0000-0000-0000-0000000000aa', '42000000-0000-0000-0000-000000000001'),
  ('42000000-0000-0000-0000-0000000000bb', '42000000-0000-0000-0000-000000000001'),
  ('42000000-0000-0000-0000-0000000000bb', '42000000-0000-0000-0000-000000000002')
on conflict do nothing;

-- Authoring is `workflows:update` (workflow/20's header says why this is a
-- role of the file's own rather than the seeded `admin`).
insert into rbac.roles (name, description, grants_all) values
  ('rem42_author', 'workflow/21: may author workflows, with no read override', false)
on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
  ('rem42_author', 'workflows', 'update')
on conflict do nothing;
insert into rbac.user_roles (user_id, role) values
  ('42000000-0000-0000-0000-000000000001', 'rem42_author')
on conflict do nothing;

-- ---------------------------------------------------------------------
-- 1. THE DERIVATION, AND 2. THE CALLER'S ORGS DO NOT DECIDE IT.
--
-- One block, because they share a fixture and the second is only meaningful
-- beside the first: Ana belongs to org A and org B, and the workflow is org
-- A's, so a run in org B would be a caller-derived org that happened to be
-- wrong rather than a missing feature.
--
-- Setting the definition's org with an UPDATE is the mechanism §17(d) names --
-- "the migration a deployment runs afterwards is a normal `update` on
-- `workflow.definitions` setting `org_id`, and it is theirs to write" -- not a
-- shim standing in for something unbuilt.
-- ---------------------------------------------------------------------
do $$
declare
    v_ana   uuid := '42000000-0000-0000-0000-000000000001';
    v_org_a uuid := '42000000-0000-0000-0000-0000000000aa';
    v_org_b uuid := '42000000-0000-0000-0000-0000000000bb';
    v_run   uuid;
    v_org   uuid; v_owner uuid; v_vis text;
begin
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_ana, 'role', 'authenticated')::text);
    perform workflow.define_yaml($y$
name: rem42_org_a
steps:
  - id: only
    work: true
$y$);
    update workflow.definitions
       set org_id = v_org_a, visibility = 'org'
     where name = 'rem42_org_a';

    v_run := workflow.start_workflow('rem42_org_a', '{}'::jsonb);
    select org_id, owner_id, visibility into v_org, v_owner, v_vis
      from workflow.runs where id = v_run;

    if rbac.is_shared_org(v_org) then
        raise exception 'the run of an org A workflow landed on the shared tier '
                        '-- so its lake output goes into the namespace every '
                        'tenant shares, which is lake.md §8';
    end if;
    if v_org is distinct from v_org_a then
        raise exception 'the run of an org A workflow belongs to org % -- and Ana '
                        'is a member of org B as well, so an org read from the '
                        'CALLER rather than from the definition is exactly this '
                        'answer', v_org;
    end if;
    if v_org = v_org_b then
        raise exception 'the run took org B, which is Ana''s other membership '
                        'rather than the workflow''s org';
    end if;
    -- The owner is still the caller: deriving the ORG from the definition must
    -- not also derive the person, or starting somebody's shared workflow would
    -- make the run theirs.
    if v_owner is distinct from v_ana then
        raise exception 'the run is owned by % rather than by the caller -- '
                        'deriving the org took the identity with it', v_owner;
    end if;

    raise notice 'workflow/21: a run of org A''s workflow belongs to org A, started by a member of both A and B, and is still owned by her';
end $$;

-- ---------------------------------------------------------------------
-- 3. A SHARED-TIER DEFINITION STILL PRODUCES A SHARED RUN.
--
-- §17(b): "a workflow nobody owns produces a run nobody owns." The engine has
-- no basis for choosing between Ana's two orgs here, and picking one would be
-- inventing a tenant. This is also the compatibility half -- every definition
-- on an upgraded database is shared-tier, so a version that assigned an org
-- here would silently re-tenant every existing workflow's runs.
-- ---------------------------------------------------------------------
do $$
declare
    v_ana uuid := '42000000-0000-0000-0000-000000000001';
    v_run uuid; v_org uuid;
begin
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_ana, 'role', 'authenticated')::text);
    perform workflow.define_yaml($y$
name: rem42_shared
steps:
  - id: only
    work: true
$y$);
    -- Left where define_yaml put it: the shared tier, by the column default.
    if not rbac.is_shared_org((select org_id from workflow.definitions
                                where name = 'rem42_shared')) then
        raise exception 'the fixture definition is not on the shared tier, so '
                        'this section is not measuring the shared case';
    end if;

    v_run := workflow.start_workflow('rem42_shared', '{}'::jsonb);
    select org_id into v_org from workflow.runs where id = v_run;
    if not rbac.is_shared_org(v_org) then
        raise exception 'a run of a shared-tier workflow was assigned org % -- '
                        'the engine invented a tenant, and on an upgraded '
                        'database that re-tenants every existing workflow',
                        v_org;
    end if;

    raise notice 'workflow/21: a shared-tier workflow still produces a shared-tier run';
end $$;

-- ---------------------------------------------------------------------
-- 4. AN ORG SUPPLIED EXPLICITLY IS NOT OVERWRITTEN.
--
-- The derivation fills a gap; it does not take the decision away from a caller
-- who has made one. `rbac.is_shared_org()` is the test rather than `is null`,
-- because the column is NOT NULL with the shared sentinel as its default --
-- "the caller did not choose" reads as the sentinel, not as a null.
-- ---------------------------------------------------------------------
do $$
declare
    v_ana   uuid := '42000000-0000-0000-0000-000000000001';
    v_org_b uuid := '42000000-0000-0000-0000-0000000000bb';
    v_def   uuid; v_run uuid; v_org uuid;
begin
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_ana, 'role', 'authenticated')::text);
    select id into v_def from workflow.definitions
     where name = 'rem42_org_a' order by version desc limit 1;
    if v_def is null then
        raise exception 'the org A definition from section 1 is missing, so '
                        'there is nothing whose org could be overridden';
    end if;

    insert into workflow.runs (workflow_def_id, org_id)
    values (v_def, v_org_b) returning id into v_run;
    select org_id into v_org from workflow.runs where id = v_run;
    if v_org is distinct from v_org_b then
        raise exception 'an explicitly supplied org (%) was replaced by % from '
                        'the definition -- the derivation overwrites a decision '
                        'instead of filling a gap', v_org_b, v_org;
    end if;

    raise notice 'workflow/21: an org supplied on the insert survives the derivation';
end $$;

-- ---------------------------------------------------------------------
-- 5. BELONGING TO AN ORG IS NOT BEING READABLE BY IT.
--
-- The run stays `private`. Two different claims, and conflating them would
-- widen every run of an org's workflow to every member of that org -- on the
-- table where `rbac.add_scope_columns` chose a 'private' backfill precisely
-- because nobody but the owner could ever see a row.
--
-- There is a mechanical reason as well, and it is worth asserting rather than
-- trusting: `trg_runs_visibility` sorts before `trg_set_run_owner`, and
-- Postgres fires BEFORE triggers in name order, so rbac.enforce_visibility()
-- has already validated the row by the time the org is derived. A version that
-- set `visibility` here would be setting it BEHIND its own check.
-- ---------------------------------------------------------------------
do $$
declare
    v_ana uuid := '42000000-0000-0000-0000-000000000001';
    v_bo  uuid := '42000000-0000-0000-0000-000000000002';
    v_run uuid; v_vis text; v_seen int;
begin
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_ana, 'role', 'authenticated')::text);
    v_run := workflow.start_workflow('rem42_org_a', '{}'::jsonb);
    select visibility into v_vis from workflow.runs where id = v_run;
    if v_vis is distinct from 'private' then
        raise exception 'the run came out visibility % rather than private -- '
                        'deriving the org also published the run to everybody '
                        'in it', v_vis;
    end if;

    -- And measured from the other seat, because a column value is not a
    -- disclosure until somebody can read it. Bo is in org B and not org A, so
    -- he must see nothing; the point is that Ana's ORG-A colleagues would not
    -- see it either, which is what 'private' means.
    --
    -- THROUGH runs_api, NOT THE TABLE. `authenticated` holds no grant on
    -- workflow.runs at all -- measured, has_table_privilege is false for the
    -- table and true for the view -- so reading the table here fails with
    -- `permission denied for table runs`, which is a true answer to a question
    -- about grants and tells you nothing about the policy. The view is owned by
    -- api_viewer rather than by the table owner precisely so that RLS applies
    -- to it (integration-rbac.sql (c2)), and it is the surface a caller
    -- actually has.
    set local role authenticated;
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_bo, 'role', 'authenticated')::text);
    select count(*) into v_seen from workflow.runs_api where id = v_run;
    if v_seen <> 0 then
        raise exception 'a member of another org can read the run (% row(s)) -- '
                        'the org derivation widened the read path', v_seen;
    end if;
    set local role app_owner;

    raise notice 'workflow/21: the run belongs to org A and is still private to its owner';
end $$;

rollback;
