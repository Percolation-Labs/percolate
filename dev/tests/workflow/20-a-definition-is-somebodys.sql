-- A WORKFLOW DEFINITION BELONGS TO SOMEBODY, AND STARTING ONE ASKS WHOSE IT IS
-- (REM-91 item 3, spec.md §17).
--
-- `workflow.definitions` carried no owner_id, no org_id and no RLS, so there
-- was nothing on the row for a check to read and no check could be written.
-- Measured before the fix: a plain `member` who owns nothing called
-- start_workflow() on a definition somebody else wrote and it succeeded. That
-- included the per-user `source_<id>` workflows save_api_source() compiles from
-- a private data source -- so "start somebody else's ingest" was available to
-- every signed-in caller in every tenant.
--
-- WHY THE CHECK IS NOT THE RLS POLICY, which is the part §17(a) had wrong and
-- the reason this file tests the function rather than the table.
-- start_workflow(), start_child_workflow() and schedule_workflow() are all
-- SECURITY DEFINER, and a definer function owned by the table's owner does not
-- see the table's policies. Measured on a three-line reproduction: of two rows
-- where a policy admits one, a direct select returned 1, a SECURITY INVOKER
-- function returned 1, and a SECURITY DEFINER function returned 2. So a test
-- that only asserted `select count(*) from workflow.definitions` would pass
-- over a completely open start path -- a check that cannot distinguish pass
-- from fail on the thing it is named after.
--
-- TWO PEOPLE WHO REALLY EXIST, for workflow/17's reason: owner_id references
-- rbac.users, and a tenancy probe in a database where the second person has no
-- row is a correct answer about nobody.
--
-- WHAT EACH SECTION MEASURES, because "definitions are scoped now" is five
-- different claims and four of them can hold while the fifth is broken:
--   1. the asymmetry the fix IS: an ownerless definition is the deployment's
--      and startable by anybody; one authored under a JWT is private to its
--      author. Both halves, because either alone is useless.
--   2. the boundary: Bo cannot start Ana's, and the refusal does not tell him
--      whether the name exists.
--   3. version resolution happens AMONG VISIBLE ROWS. This is the one a
--      working fix still gets wrong: filter after `order by version desc` and
--      Ana is handed Bo's newer version, then refused it -- so her own
--      workflow disappears because somebody else reused the name.
--   4. the engine is not a tenant: an identity-free caller still starts a
--      private definition, because start_child_workflow() runs as `worker` and
--      the clock runs as `scheduler`. Without this, making a workflow private
--      would silently stop its own sub-workflows.
--   5. org sharing works in both directions: a co-member may start it, a
--      member of another org may not.
\set ON_ERROR_STOP on
begin;
set local role app_owner;

insert into rbac.users (id, email) values
  ('91000000-0000-0000-0000-000000000001', 'rem91-ana@example.test'),
  ('91000000-0000-0000-0000-000000000002', 'rem91-bo@example.test'),
  ('91000000-0000-0000-0000-000000000003', 'rem91-cass@example.test')
on conflict do nothing;

insert into rbac.orgs (id, slug, name) values
  ('91000000-0000-0000-0000-0000000000aa', 'rem91-a', 'REM-91 org A'),
  ('91000000-0000-0000-0000-0000000000bb', 'rem91-b', 'REM-91 org B')
on conflict do nothing;
-- Ana and Cass share org A; Bo is in org B. So Bo is a signed-in caller in a
-- real tenancy rather than a caller with no org, which is the case that used
-- to succeed.
insert into rbac.org_members (org_id, user_id) values
  ('91000000-0000-0000-0000-0000000000aa', '91000000-0000-0000-0000-000000000001'),
  ('91000000-0000-0000-0000-0000000000aa', '91000000-0000-0000-0000-000000000003'),
  ('91000000-0000-0000-0000-0000000000bb', '91000000-0000-0000-0000-000000000002')
on conflict do nothing;

-- AUTHORING IS A SEPARATE AUTHORITY FROM STARTING, and the fixture has to
-- respect that or it measures nothing. workflow.may_define() asks for
-- `workflows:update`, because a step may carry SQL that runs as the engine
-- owner -- so Ana and Bo cannot author a workflow just by being signed in.
--
-- A role of the file's own rather than the seeded `admin`, deliberately:
-- `admin` also holds `workflow_definitions:select`, the operator override this
-- change adds, so handing it to Ana and Bo would let each of them read the
-- other's rows and every section below would pass for the wrong reason. The
-- default role set has no role that may author a workflow without also being
-- able to read every tenant's -- which is correct for `admin` and is why this
-- file does not use it.
insert into rbac.roles (name, description, grants_all) values
  ('rem91_author', 'workflow/20: may author workflows, with no read override', false)
on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
  ('rem91_author', 'workflows', 'update')
on conflict do nothing;
insert into rbac.user_roles (user_id, role) values
  ('91000000-0000-0000-0000-000000000001', 'rem91_author'),
  ('91000000-0000-0000-0000-000000000002', 'rem91_author')
on conflict do nothing;

-- Every definition below is ONE QUEUED STEP so nothing executes: what is under
-- test is whether the definition resolves, and a step that ran would bring its
-- own reasons to fail.

-- ---------------------------------------------------------------------
-- 1. THE ASYMMETRY, WHICH IS THE WHOLE OF THE FIX.
--
-- Authored with no claims -- an operator, a package install, seed_load -- the
-- row has no owner, and a row with no owner at visibility 'private' is
-- readable by nobody at all, including the operator who installed it. So
-- trg_set_definition_owner promotes it to 'public': the deployment's workflow
-- is startable by the deployment. §17(c) is where that is decided.
--
-- Authored under a JWT it is private to its author, from the column default.
-- ---------------------------------------------------------------------
do $$
declare
    v_ana uuid := '91000000-0000-0000-0000-000000000001';
    v_vis text; v_owner uuid;
begin
    perform workflow.define_yaml($y$
name: rem91_deployment
steps:
  - id: only
    work: true
$y$);
    select visibility, owner_id into v_vis, v_owner
      from workflow.definitions where name = 'rem91_deployment';
    if v_owner is not null or v_vis is distinct from 'public' then
        raise exception 'a definition authored with no identity came out owner=% '
                        'visibility=%; ownerless and private is a row nobody can '
                        'read, so every package install would produce a workflow '
                        'no signed-in caller can start', v_owner, v_vis;
    end if;

    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_ana, 'role', 'authenticated')::text);
    perform workflow.define_yaml($y$
name: rem91_anas
steps:
  - id: only
    work: true
$y$);
    select visibility, owner_id into v_vis, v_owner
      from workflow.definitions where name = 'rem91_anas';
    if v_owner is distinct from v_ana or v_vis is distinct from 'private' then
        raise exception 'Ana''s definition came out owner=% visibility=% rather '
                        'than hers and private -- the trigger took an owner from '
                        'somewhere other than the verified claims, or the column '
                        'default is not private', v_owner, v_vis;
    end if;

    raise notice 'workflow/20: ownerless definitions are the deployment''s (public), authored ones are their author''s (private)';
end $$;

-- ---------------------------------------------------------------------
-- 2. THE BOUNDARY, AND A REFUSAL THAT IS NOT AN EXISTENCE ORACLE.
--
-- The two refusals must be the SAME message: distinguishing "no such workflow"
-- from "not yours" tells an unauthorised caller that a name exists, which is
-- the probe 2e5995e closed for agents (agentic.may_invoke) and the identical
-- probe here. §17(a) settles it deliberately, so it is asserted rather than
-- left to whoever edits the string next.
-- ---------------------------------------------------------------------
do $$
declare
    v_bo  uuid := '91000000-0000-0000-0000-000000000002';
    v_run uuid;
    v_denied text; v_absent text;
begin
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_bo, 'role', 'authenticated')::text);

    -- The deployment's own workflow is startable by him: section 1's other half
    -- measured from the caller's seat, and the control that proves section 2
    -- is a boundary rather than a blanket refusal.
    v_run := workflow.start_workflow('rem91_deployment', '{}'::jsonb);
    if v_run is null then
        raise exception 'Bo could not start the deployment-wide workflow -- this '
                        'section cannot show that refusing Ana''s is about '
                        'ownership rather than about everything being refused';
    end if;

    -- The success case is recorded rather than raised from inside the handler:
    -- a `raise` in the try block is caught by this very block's `when others`
    -- and comes back out as "the refusal was <my own assertion text>", which
    -- reports a wrong message where the real finding is that there was no
    -- refusal at all. Checked by reverting may_start() to `select true`.
    v_run := null;
    begin
        v_run := workflow.start_workflow('rem91_anas', '{}'::jsonb);
    exception when others then
        v_denied := sqlerrm;
    end;
    if v_run is not null then
        raise exception 'Bo started Ana''s private workflow and got run % -- every '
                        'signed-in caller in every tenant can start every '
                        'definition, including the per-user source_<id> ingests',
                        v_run;
    end if;

    v_run := null;
    begin
        v_run := workflow.start_workflow('rem91_no_such_workflow_at_all', '{}'::jsonb);
    exception when others then
        v_absent := sqlerrm;
    end;
    if v_run is not null then
        raise exception 'starting a workflow that does not exist succeeded (run %)', v_run;
    end if;

    if v_denied !~ 'is visible to you' then
        raise exception 'the refusal for somebody else''s workflow was "%", which '
                        'is not the message §17(a) specifies', v_denied;
    end if;
    if replace(v_denied, 'rem91_anas', 'X') is distinct from
       replace(v_absent, 'rem91_no_such_workflow_at_all', 'X') then
        raise exception 'refused-because-not-yours says "%" and does-not-exist '
                        'says "%" -- the difference is an existence oracle over '
                        'another tenant''s workflow names', v_denied, v_absent;
    end if;

    raise notice 'workflow/20: Bo is refused Ana''s workflow in the same words as one that does not exist';
end $$;

-- ---------------------------------------------------------------------
-- 3. THE VERSION IS RESOLVED AMONG THE ROWS THIS CALLER MAY USE.
--
-- define_yaml() allocates max(version)+1 across EVERY row, visible or not, and
-- that is deliberate -- it runs SECURITY DEFINER, so the allocation cannot
-- collide with an invisible row on unique (name, version). The consequence is
-- that Bo reusing Ana's name takes the higher version number, and a filter
-- applied after `order by version desc` would hand Ana his row and then refuse
-- it. Her own workflow would vanish because somebody else reused the name.
-- ---------------------------------------------------------------------
do $$
declare
    v_ana uuid := '91000000-0000-0000-0000-000000000001';
    v_bo  uuid := '91000000-0000-0000-0000-000000000002';
    v_run uuid; v_got uuid; v_ver int; v_bo_ver int; v_ana_ver int;
begin
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_bo, 'role', 'authenticated')::text);
    perform workflow.define_yaml($y$
name: rem91_anas
steps:
  - id: only
    work: true
$y$);

    -- Bo's row is the newer version by construction; if it is not, this section
    -- is measuring nothing. Read into variables and the absent case named
    -- separately, because `NULL <= NULL` is NULL and `if NULL then` does not
    -- fire: a define_yaml that had quietly written no row would leave this
    -- control passing while proving nothing, which is what
    -- dev/assertion-audit.py refuses.
    select max(version) into v_bo_ver from workflow.definitions
     where name = 'rem91_anas' and owner_id = v_bo;
    select max(version) into v_ana_ver from workflow.definitions
     where name = 'rem91_anas' and owner_id = v_ana;
    if v_bo_ver is null or v_ana_ver is null then
        raise exception 'the reused name has no row for Bo (%) or none for Ana '
                        '(%), so there are not two versions to resolve between',
                        v_bo_ver, v_ana_ver;
    end if;
    if v_bo_ver <= v_ana_ver then
        raise exception 'Bo''s version of the reused name (v%) is not newer than '
                        'Ana''s (v%), so this section cannot detect the ordering '
                        'bug', v_bo_ver, v_ana_ver;
    end if;

    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_ana, 'role', 'authenticated')::text);
    v_run := workflow.start_workflow('rem91_anas', '{}'::jsonb);
    select d.owner_id, d.version into v_got, v_ver
      from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id
     where r.id = v_run;
    if v_got is distinct from v_ana then
        raise exception 'Ana started her own workflow by name and got the version '
                        'owned by % (v%) -- the visibility filter runs after the '
                        'version is chosen, so reusing a name hides the original '
                        'from its own author', v_got, v_ver;
    end if;

    raise notice 'workflow/20: Ana''s name resolves to Ana''s latest version (v%), not to the latest that exists', v_ver;
end $$;

-- ---------------------------------------------------------------------
-- 4. THE ENGINE IS NOT A TENANT.
--
-- `worker` and `scheduler` hold no JWT, so rbac.may_read() alone answers false
-- for every definition that is not public -- and start_child_workflow()
-- resolves its definition as `worker` while the clock resolves one as
-- `scheduler`. Without is_operator() in may_start(), marking a workflow
-- private would silently stop its own sub-workflows and its own schedule, with
-- no error anywhere: for a scheduler, a job that resolves nothing is
-- indistinguishable from nothing being due.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid;
begin
    set local request.jwt.claims = '';
    if rbac.current_user_id() is not null or not rbac.is_operator() then
        raise exception 'this session is not the identity-free caller the section '
                        'is about (user %, operator %)',
                        rbac.current_user_id(), rbac.is_operator();
    end if;

    v_run := workflow.start_workflow('rem91_anas', '{}'::jsonb);
    if v_run is null then
        raise exception 'the engine could not start a private workflow, so a '
                        'private definition''s sub-workflows and schedule would '
                        'stop firing and nothing would report it';
    end if;

    raise notice 'workflow/20: an identity-free caller still starts a private definition, which is what start_child_workflow() and the clock rest on';
end $$;

-- ---------------------------------------------------------------------
-- 5. SHARING WITH AN ORG, IN BOTH DIRECTIONS.
--
-- The point of scope over bare ownership: `owner_id = current_user_id()` has
-- only two answers, nobody and everybody. Cass shares org A with Ana and may
-- start what Ana shares; Bo is in org B and still may not.
--
-- A NAME OF ITS OWN, and the first draft of this file did not have one -- it
-- reused `rem91_anas`, which section 3 has Bo authoring a version of. Bo then
-- started his OWN row and the section reported a cross-tenant breach that had
-- not happened. The name has to be one only Ana has defined, or "Bo may start
-- it" and "Bo may start Ana's" are the same observation.
-- ---------------------------------------------------------------------
do $$
declare
    v_ana  uuid := '91000000-0000-0000-0000-000000000001';
    v_bo   uuid := '91000000-0000-0000-0000-000000000002';
    v_cass uuid := '91000000-0000-0000-0000-000000000003';
    v_org  uuid := '91000000-0000-0000-0000-0000000000aa';
    v_run  uuid;
begin
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_ana, 'role', 'authenticated')::text);
    perform workflow.define_yaml($y$
name: rem91_shared
steps:
  - id: only
    work: true
$y$);
    update workflow.definitions
       set org_id = v_org, visibility = 'org'
     where name = 'rem91_shared' and owner_id = v_ana;

    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_cass, 'role', 'authenticated')::text);
    v_run := workflow.start_workflow('rem91_shared', '{}'::jsonb);
    if v_run is null then
        raise exception 'Cass shares an org with Ana and could not start what Ana '
                        'shared with it -- sharing has no effect, so the only two '
                        'answers are still nobody and everybody';
    end if;
    -- AND THE RUN IS HERS, not Ana's: starting somebody's shared workflow is
    -- not acting as them. set_run_owner() decides this and section 1 of
    -- workflow/15 is the other end of the same rule.
    if (select owner_id from workflow.runs where id = v_run) is distinct from v_cass then
        raise exception 'the run Cass started from Ana''s shared workflow is not '
                        'owned by Cass -- starting a shared definition handed her '
                        'somebody else''s identity';
    end if;

    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', v_bo, 'role', 'authenticated')::text);
    begin
        v_run := workflow.start_workflow('rem91_shared', '{}'::jsonb);
        raise exception 'Bo is in another org and started org A''s shared workflow '
                        '(run %) -- ''org'' visibility reads as ''anybody signed '
                        'in''', v_run;
    exception when sqlstate 'P0001' then
        if sqlerrm !~ 'is visible to you' then raise; end if;
    end;

    raise notice 'workflow/20: a co-member may start what an org shares and a member of another org may not';
end $$;

rollback;
