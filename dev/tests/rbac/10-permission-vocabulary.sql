-- THE PERMISSION VOCABULARY, WALKED IN BOTH DIRECTIONS.
--
-- `rbac.permission_kinds` exists because `role_permissions.action` was free
-- text compared with `=`, and the failure mode of free text there is SILENCE: a
-- grant of ('workflow_runs','read') where the policy asks for 'select' inserts
-- cleanly, the role reads as populated, and every policy consulting it returns
-- false. The table closed that from one side -- a pair nothing checks can no
-- longer be granted, because `role_permissions` has a foreign key onto it.
--
-- Two directions were left open, and both fail exactly as quietly:
--
--   * A POLICY THAT ASKS FOR A PAIR NOBODY DECLARED. The foreign key cannot
--     see it: it constrains grants, not questions. `has_permission(uid,
--     'widgets', 'select')` inside a policy for a pair no row declares is a
--     check that can never be true for anyone, and nothing raises -- the table
--     simply looks empty to everybody who is not its owner.
--
--   * AN ADMINISTRATOR WHO STOPS HOLDING WHAT "ADMIN" MEANS. `bootstrap_admin`
--     grants every declared pair with a SELECT rather than a list, and its
--     comment says why: "a module added later is covered the moment it declares
--     its pairs". The select ran once. Measured on a database bootstrapped at
--     0.1.3 and upgraded to 0.1.4: the administrator held 20 of 27 declared
--     pairs and `has_permission(root, 'orgs', 'admin')` was false -- so the
--     person who installed the deployment could not administer an org, read
--     another tenant's agents, skills, plugins or tool servers, or see the
--     orgs table at all, and had no way to tell any of that from "this
--     deployment has no orgs".
--
-- `rbac.roles.grants_all` and the trigger on `permission_kinds` are the fix,
-- and section 3 is what stops it silently reverting to a select that ran once.
\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- 1. EVERY PAIR ANYTHING ASKS FOR IS DECLARED.
--
-- Read out of the live catalogue -- function bodies and policy expressions --
-- rather than from a list in this file, for the reason rbac/04 and rbac/05
-- give: a list here is a list that stops covering whatever is added next. The
-- pattern tolerates the `::text` casts Postgres renders policy expressions
-- with, which is the difference between this query finding seventeen call
-- sites and finding three.
--
-- Only literal arguments can be checked this way. `assert_run_access` and
-- `may_author` take the action as a parameter, so their pairs are declared and
-- never appear here; that is a limit of the check and not a hole in the table,
-- since the pair those functions pass is itself read from a caller that names
-- it in SQL this query does see.
-- ---------------------------------------------------------------------
do $$
declare v_missing text;
begin
    with asked as (
        select distinct m[1] as resource, m[2] as action, src
          from (
            select p.oid::regprocedure::text as src, p.prosrc as body
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname in ('rbac','workflow','agentic','aiq','content','percolate')
            union all
            select 'policy ' || policyname || ' on ' || schemaname || '.' || tablename,
                   coalesce(qual,'') || ' ' || coalesce(with_check,'')
              from pg_policies
          ) s,
          lateral regexp_matches(
            s.body,
            'has_permission\s*\([^,]+,\s*''([a-z_]+)''(?:::text)?\s*,\s*''([a-z_]+)''',
            'g') m(m)
    )
    select string_agg(format('%s / %s  asked for by %s', a.resource, a.action, a.src),
                      E'\n             ' order by a.resource, a.action)
      into v_missing
      from asked a
      left join rbac.permission_kinds k
             on k.resource = a.resource and k.action = a.action
     where k.resource is null;

    if v_missing is not null then
        raise exception E'these (resource, action) pairs are asked for and cannot be granted:\n             %\n\n%',
            v_missing,
            'role_permissions has a foreign key onto permission_kinds, so a pair '
            'that is not declared cannot be granted to anybody -- which makes the '
            'check that asks for it permanently false rather than an error. '
            'Declare the pair in rbac.permission_kinds with the site that asks '
            'for it in checked_by.';
    end if;
    raise notice 'rbac/10: every permission pair a live policy or function asks for by name is declared';
end $$;

-- ---------------------------------------------------------------------
-- 2. AND `checked_by` STILL POINTS AT SOMETHING.
--
-- The column's own comment is "where the pair is consulted, so it can be
-- verified", which is a promise nothing was keeping. A renamed policy leaves
-- the declaration naming a policy that no longer exists -- and the pair itself
-- stays grantable, so nothing else in the collection notices.
--
-- Only the `policy <name>` form is machine-checkable; the rest name functions
-- and, in two cases, a group of them in prose ("workflow.pool guards"). Those
-- are excluded here rather than half-checked, and the exclusion is deliberate:
-- see rbac/05's note on naming an exception being the point.
-- ---------------------------------------------------------------------
do $$
declare v_dangling text;
begin
    select string_agg(format('%s / %s -> %s', k.resource, k.action, k.checked_by), E'\n             ')
      into v_dangling
      from rbac.permission_kinds k
     where k.checked_by like 'policy %'
       -- The identifier only: a declaration may carry a note after the name
       -- (`policy select_own_or_permitted (dev/tests/rbac/01)`), and matching
       -- to end-of-string would look for a policy called "name (note)" and
       -- report every annotated row as dangling.
       and not exists (select 1 from pg_policies p
                        where p.policyname = substring(k.checked_by from 'policy ([a-z0-9_]+)'));
    if v_dangling is not null then
        raise exception E'these declarations name a policy that does not exist:\n             %',
            v_dangling;
    end if;
    raise notice 'rbac/10: every declaration that names a policy names one that exists';
end $$;

-- ---------------------------------------------------------------------
-- 3. THE FIRST ADMINISTRATOR, AND THE PAIRS DECLARED AFTER THEM.
--
-- `bootstrap_admin` refuses once any role has been granted to anyone, which is
-- what keeps it a bootstrap rather than a back door -- so exercising it at all
-- means starting from a database where nothing has been granted. Deleting
-- `user_roles` inside a transaction that rolls back is how that is reached
-- here; it is the only way to execute the function's real path, and the whole
-- file is one rolled-back transaction for exactly this reason.
-- ---------------------------------------------------------------------
delete from rbac.user_roles;

do $$
declare v_uid uuid; v_again uuid; v_refused boolean := false;
begin
    v_uid := rbac.bootstrap_admin('bootstrap-probe@test.com', 'a passphrase for root');

    -- It produces an account that can actually log in. Signup lands in
    -- `pending_verification` and `verify_password` matches only `active`, so
    -- without the activation inside that function the one account in a fresh
    -- deployment would be the one that can never sign in.
    if (select count(*) from rbac.login('bootstrap-probe@test.com',
                                        'a passphrase for root', 'cli', 'raw-boot-token')) <> 1 then
        raise exception 'the bootstrapped administrator cannot log in';
    end if;

    -- Every declared pair, and the column that says why.
    if exists (select resource, action from rbac.permission_kinds
               except
               select resource, action from rbac.role_permissions where role = 'admin') then
        raise exception 'the bootstrapped administrator does not hold every declared pair';
    end if;
    if not (select grants_all from rbac.roles where name = 'admin') then
        raise exception 'bootstrap_admin created a role that is not marked grants_all -- '
                        'the pairs it granted are a snapshot again';
    end if;

    -- Idempotent for the same identity, refusing for a second one.
    v_again := rbac.bootstrap_admin('bootstrap-probe@test.com', 'a passphrase for root');
    if v_again <> v_uid then
        raise exception 'bootstrap_admin is not idempotent: % then %', v_uid, v_again;
    end if;
    begin
        perform rbac.bootstrap_admin('second-root@test.com', 'a passphrase for two');
    exception when others then v_refused := true;
    end;
    if not v_refused then
        raise exception 'bootstrap_admin minted a SECOND administrator on a bootstrapped database';
    end if;

    -- AND THE PART THAT WAS FALSE. A module declaring its pairs later -- an
    -- upgrade, or the runtime extensibility path permission_kinds documents --
    -- must reach the administrator that already exists.
    insert into rbac.permission_kinds (resource, action, checked_by)
    values ('probe_widgets', 'select', 'policy probe_widgets_scoped');

    if not rbac.has_permission(v_uid, 'probe_widgets', 'select') then
        raise exception
            'a pair declared after the bootstrap is not held by the administrator -- '
            'every policy that consults it answers false for the one account that '
            'installed the deployment, and looks exactly like an empty table';
    end if;

    -- It is a marked role that gains them, not every role: `grants_all` is the
    -- statement, and a role that never made it is untouched.
    insert into rbac.roles (name, description) values ('probe_viewer', 'holds nothing');
    insert into rbac.permission_kinds (resource, action, checked_by)
    values ('probe_gadgets', 'select', 'policy probe_gadgets_scoped');
    if exists (select 1 from rbac.role_permissions where role = 'probe_viewer') then
        raise exception 'declaring a pair granted it to a role that is not grants_all';
    end if;

    raise notice 'rbac/10: the first administrator holds every declared pair, including '
                 'the ones declared after they were made, and no other role does';
end $$;

rollback;
