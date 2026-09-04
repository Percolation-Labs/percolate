-- EVERY SECURITY DEFINER FUNCTION, ENUMERATED -- because the list that was
-- supposed to do this is maintained by hand.
--
-- `workflow-engine/integration-rbac.sql` §6 already states the rule: "SECURITY
-- DEFINER deliberately bypasses RLS, so every SECURITY DEFINER function
-- reachable by an end user MUST do its own authorization check." It was found
-- by enumerating the engine once, by hand, and fixed with nine `revoke`s.
--
-- Six functions were created AFTER `schema.sql`'s `revoke execute on all
-- functions in schema workflow from public`, which only affects functions that
-- exist when it runs. One of them was `workflow.define_yaml`, which had no
-- authorization check of its own -- and because a step may carry its own SQL
-- that runs as the engine owner, a user holding no permissions at all could
-- define a one-step workflow and read every row of `rbac.users` after being
-- refused on a direct `select`. Reproduced before this file was written.
--
-- So the rule stops being a list and becomes an assertion. Both halves below
-- are generic: they enumerate the catalog rather than naming functions, so a
-- function added next month is covered by having been added.

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- 1. NO SECURITY DEFINER FUNCTION MAY CARRY THE PUBLIC DEFAULT.
--
-- Postgres grants EXECUTE to PUBLIC on every new function unless it is taken
-- away, so an ACL reading `=X/app_owner | authenticated=X/app_owner` is the
-- explicit grant PLUS everybody -- and it is indistinguishable, at a glance,
-- from the grant alone. That is what makes this worth asserting rather than
-- reviewing: nobody was misreading the code, the code was missing a line.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(
               n.nspname || '.' || p.proname
                 || '(' || pg_get_function_identity_arguments(p.oid) || ')',
               E'\n       ' order by n.nspname, p.proname)
      into v_bad
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('workflow','aiq','rbac','content','agentic','wm')
       and p.prosecdef
       and exists (select 1 from aclexplode(p.proacl) a
                    where a.grantee = 0 and a.privilege_type = 'EXECUTE');

    if v_bad is not null then
        raise exception
            E'these SECURITY DEFINER functions are executable by PUBLIC:\n       %\n\n'
            'Each one runs as app_owner, which owns every table in this '
            'collection and is not subject to their RLS policies. Add '
            '`revoke execute on function <sig> from public;` beside the grant '
            'that names its real callers. A schema-wide '
            '`revoke ... on all functions` does NOT cover a function created '
            'after it runs, which is how this class of hole is reintroduced.',
            v_bad;
    end if;
    raise notice 'rbac/04: no SECURITY DEFINER function carries the PUBLIC default';
end $$;

-- ---------------------------------------------------------------------
-- 2. AND NONE OF THEM IS REACHABLE BY web_anon.
--
-- The generalisation of the check `content/02-ingestion.sql` has always made
-- for its own schema. `web_anon` holds USAGE on `rbac` and `agentic` for the
-- anonymous read path, so a PUBLIC default there was not merely untidy -- it
-- was an unauthenticated caller one HTTP request away from a write that runs
-- as the engine owner.
--
-- FIVE ARE MEANT TO BE HERE, and they are named rather than pattern-matched
-- because an allow-list you can read is the only kind worth having. Every one
-- is the anonymous half of authentication -- the thing an unauthenticated
-- caller must be able to do in order to stop being unauthenticated -- and each
-- carries an explicit `grant ... to web_anon`, not a PUBLIC leftover (section 1
-- already proved that). They are SECURITY DEFINER for the ordinary reason: the
-- credential tables they read are ones no end-user role may select from.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(n.nspname || '.' || p.proname, ', ' order by n.nspname, p.proname)
      into v_bad
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('workflow','aiq','rbac','content','agentic','wm')
       and p.prosecdef
       and has_function_privilege('web_anon', p.oid, 'execute')
       and has_schema_privilege('web_anon', n.nspname, 'usage')
       and (n.nspname, p.proname) not in (
             ('rbac', 'login'),                      -- password -> session
             ('rbac', 'refresh_session'),            -- refresh token -> session
             ('rbac', 'verify_api_key'),             -- api key -> identity
             ('rbac', 'create_user_with_password'),  -- signup, user-rbac spec 6
             -- Account recovery. Anonymous BY NECESSITY: somebody who has
             -- forgotten their password cannot be authenticated, which is the
             -- situation. Both are self-authenticating by token possession,
             -- exactly as refresh_session above is, and neither returns
             -- anything an anonymous caller could not already infer --
             -- request_password_reset returns void precisely so it cannot say
             -- whether the address exists.
             ('rbac', 'request_password_reset'),     -- email -> a token it does not reveal
             ('rbac', 'reset_password'),             -- reset token -> new password
             ('rbac', 'has_permission'),             -- read-only, and every policy calls it
             -- Same case as has_permission, and SECURITY DEFINER for a reason
             -- worth stating: rbac.org_members carries its own RLS policy and
             -- that policy calls this function, so invoker rights here is a
             -- two-hop recursion Postgres reports as `stack depth limit
             -- exceeded` rather than as policy recursion. It returns the
             -- caller's OWN orgs and nobody else's -- there is no argument to
             -- ask it about somebody else -- so an anonymous caller reaching
             -- it learns that it belongs to no orgs, which it already knew.
             ('rbac', 'current_org_ids'));

    if v_bad is not null then
        raise exception
            'these SECURITY DEFINER functions are callable by web_anon: %. '
            'An anonymous PostgREST request reaches them, and they run as '
            'app_owner outside RLS.', v_bad;
    end if;
    raise notice 'rbac/04: no SECURITY DEFINER function is reachable by web_anon';
end $$;

-- ---------------------------------------------------------------------
-- 3. THE INSTANCE THIS FILE CAME FROM, ASSERTED BEHAVIOURALLY.
--
-- Section 1 would catch the grant. This catches the missing check underneath
-- it, which is the half a revoke does not fix: `authenticated` is granted
-- define_yaml deliberately, so the gate has to be inside.
--
-- Run as a real user with no permissions, through `set local role` rather than
-- by reading the function body -- the same discipline `workflow/04` applies to
-- matrix_rows. `rbac.current_user_id()` reads the JWT claim, so a claims GUC
-- naming a user is the whole identity.
-- ---------------------------------------------------------------------
begin;

insert into rbac.users (id, email, password_hash, status)
values ('dddddddd-0000-0000-0000-00000000000d', 'nobody@test.invalid', 'x', 'active')
on conflict (id) do nothing;

do $$
declare v_defined boolean := false;
begin
    if rbac.has_permission('dddddddd-0000-0000-0000-00000000000d'::uuid,
                           'workflows', 'update') then
        raise exception 'the fixture user was granted workflows:update -- '
                        'this assertion needs a user who has not been';
    end if;

    set local role authenticated;
    perform set_config('request.jwt.claims',
        '{"sub":"dddddddd-0000-0000-0000-00000000000d"}', true);

    -- The refusal must be THE refusal. `when others then null` would have
    -- passed this file against a may_define() that did not exist at all --
    -- which is exactly the state an earlier run of this was in, and it looked
    -- green.
    begin
        perform workflow.define_yaml(
            E'name: t_definer_probe\nsteps:\n  - id: q\n    sql: {statement: "select 1"}\n');
        v_defined := true;
    exception when others then
        if sqlerrm !~ 'not authorized to define workflows' then
            raise exception
                'define_yaml refused, but not for the reason under test: %', sqlerrm;
        end if;
    end;

    reset role;

    if v_defined then
        raise exception
            'a user with no permissions defined a workflow. A step may carry '
            'its own SQL, which runs as the engine owner outside RLS, so this '
            'is a read of every table in the database -- workflow.may_define() '
            'is the gate and it is not holding.';
    end if;
    raise notice 'rbac/04: a caller without workflows:update cannot define a workflow';
end $$;

-- And the other half: the gate is a gate, not a wall. A caller who HAS the
-- permission still gets through -- otherwise section 3 would pass just as well
-- against a function that refuses everyone.
do $$
declare v_id uuid;
begin
    insert into rbac.roles (name) values ('admin') on conflict do nothing;
    insert into rbac.role_permissions (role, resource, action)
    values ('admin', 'workflows', 'update') on conflict do nothing;
    insert into rbac.user_roles (user_id, role)
    values ('dddddddd-0000-0000-0000-00000000000d', 'admin') on conflict do nothing;

    set local role authenticated;
    perform set_config('request.jwt.claims',
        '{"sub":"dddddddd-0000-0000-0000-00000000000d"}', true);
    v_id := workflow.define_yaml(
        E'name: t_definer_probe\nsteps:\n  - id: q\n    sql: {statement: "select 1"}\n');
    reset role;

    if v_id is null then
        raise exception 'an authorized caller could not define a workflow';
    end if;
    raise notice 'rbac/04: a caller holding workflows:update still can';
end $$;

rollback;
