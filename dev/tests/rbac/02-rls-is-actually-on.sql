-- RBAC SURFACE -- the conditions under which row-level security is real.
--
-- `01-rls-isolation.sql` proves the policies filter correctly. This file
-- proves the policies are *consulted at all*, which is a different question
-- and the one that has actually gone wrong here. RLS does not fail loudly
-- when it is bypassed; it returns more rows and says nothing.
--
-- Four ways it has silently switched itself off in this repo, each now an
-- assertion.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

-- ---------------------------------------------------------------------
-- 1. NO ROLE IN THE SYSTEM IS A SUPERUSER.
-- A superuser bypasses every policy unconditionally, before any policy is
-- consulted. This is checked at schema load time too; it is repeated here
-- because a role can be altered long after install.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(rolname, ', ') into v_bad
    from pg_roles
    where rolsuper
      and rolname in ('app_owner','api_viewer','web_anon','authenticated',
                      'authenticator','worker','scheduler');
    if v_bad is not null then
        raise exception 'these roles are superusers and bypass all RLS: %', v_bad;
    end if;
    raise notice 'rbac/02: no system role is a superuser';
end $$;

-- ---------------------------------------------------------------------
-- 2. THE VIEW OWNER IS NOT THE TABLE OWNER.
--
-- The exploit that produced this rule: an owner-privileged view owned by the
-- table's owner bypasses the table's RLS exactly as a superuser does, so a
-- non-admin read every row through users_api and nothing complained. Reads go
-- through views owned by api_viewer, which owns no tables and therefore has
-- no ownership to bypass with.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(c.relname, ', ') into v_bad
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where c.relkind = 'v'
      and c.relname like '%\_api'
      and n.nspname in ('rbac','workflow','aiq','content','public')
      and pg_get_userbyid(c.relowner) <> 'api_viewer';
    if v_bad is not null then
        raise exception '%_api views are not owned by api_viewer (%) -- an '
                        'owner-privileged view owned by the table owner bypasses '
                        'the table''s RLS', '%', v_bad;
    end if;
    raise notice 'rbac/02: every *_api view is owned by api_viewer';
end $$;

-- ---------------------------------------------------------------------
-- 3. RLS IS ENABLED, AND DELIBERATELY NOT FORCED.
--
-- Both halves matter. Without ENABLE there are no policies. With FORCE, the
-- table owner is subjected to its own policies -- which sounds stricter and
-- is actually catastrophic here, because it puts every SECURITY DEFINER
-- function under RLS as well. When this was tried, signup, login and token
-- issuance all failed, and `INSERT ... RETURNING` failed for the table owner
-- itself.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
    for r in
        select n.nspname, c.relname, c.relrowsecurity, c.relforcerowsecurity
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where c.relkind = 'r' and n.nspname in ('rbac','workflow','aiq','content')
          and exists (select 1 from pg_policy p where p.polrelid = c.oid)
    loop
        if not r.relrowsecurity then
            raise exception '%.% has policies but RLS is not enabled -- '
                            'the policies are inert', r.nspname, r.relname;
        end if;
        if r.relforcerowsecurity then
            raise exception '%.% has FORCE ROW LEVEL SECURITY -- this subjects '
                            'SECURITY DEFINER functions to RLS and breaks every '
                            'write path in the collection', r.nspname, r.relname;
        end if;
    end loop;
    raise notice 'rbac/02: RLS enabled and not forced on every policied table';
end $$;

-- ---------------------------------------------------------------------
-- 4. NO SERVICE ROLE HOLDS A TABLE GRANT.
--
-- The whole reason "bring your own worker" is safe to offer: a worker's only
-- reachable surface is a set of SECURITY DEFINER functions. If it ever held a
-- direct table grant, a compromised worker would read whatever that grant
-- allowed, regardless of who its caller was.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(format('%s on %I.%I', privilege_type, table_schema, table_name), ', ')
    into v_bad
    from information_schema.role_table_grants
    where grantee in ('worker','scheduler')
      and table_schema in ('rbac','workflow','aiq','content');
    if v_bad is not null then
        raise exception 'a service role holds direct table grants: %', v_bad;
    end if;
    raise notice 'rbac/02: worker and scheduler hold no table grants';
end $$;

-- ---------------------------------------------------------------------
-- 5. SETTING CLAIMS WITHOUT SWITCHING ROLE PROVES NOTHING.
--
-- This is the shape of the bug found in percolate-core 0.1.1: the service set
-- request.jwt.claims and stopped, so every policy filtered on an identity the
-- query never assumed. Demonstrated rather than asserted, because the point is
-- counter-intuitive -- the claims are set correctly and the answer is still
-- wrong.
-- ---------------------------------------------------------------------
-- One session, one set of claims, two objects holding the same rows. The only
-- difference is who owns what -- and that alone decides whether the policy is
-- consulted.
do $$
declare
    v_base bigint;
    v_view bigint;
begin
    insert into rbac.users (id, email) values
      ('33333333-3333-3333-3333-333333333333', 'carol@test.com'),
      ('44444444-4444-4444-4444-444444444444', 'dave@test.com');

    perform set_config('request.jwt.claims',
        '{"sub":"33333333-3333-3333-3333-333333333333"}', true);

    -- The base table, as its own owner: ownership bypasses RLS, so the
    -- perfectly-correct claims above decide nothing at all.
    select count(*) into v_base from rbac.users;

    -- The same rows through the view api_viewer owns. Not the table's owner,
    -- so the policy applies and the claims finally matter.
    select count(*) into v_view from rbac.users_api;

    if v_base <= v_view then
        raise exception 'the base table returned % rows and the view returned % -- '
                        'the ownership split is no longer producing different '
                        'visibility, so nothing here would notice RLS being bypassed',
                        v_base, v_view;
    end if;
    raise notice 'rbac/02: identical claims, % rows from the base table (owner '
                 'bypasses RLS) vs % from the view -- which is why a service must '
                 'switch role and why api_viewer owns the views', v_base, v_view;
end $$;

-- ---------------------------------------------------------------------
-- 6. AND THE BASE TABLES ARE NOT REACHABLE AT ALL.
-- Defence in depth behind the policies: `authenticated` has no grant on the
-- base tables, only on the *_api views. So even a policy mistake does not
-- expose the table directly -- the caller cannot name it.
-- ---------------------------------------------------------------------
do $$
declare v_reached boolean := false;
begin
    set local role authenticated;
    begin
        perform 1 from rbac.users limit 1;
        v_reached := true;
    exception when insufficient_privilege then
        null;   -- expected
    end;
    reset role;

    if v_reached then
        raise exception 'authenticated can select rbac.users directly -- reads are '
                        'supposed to go through rbac.users_api, whose owner is not '
                        'the table owner';
    end if;
    raise notice 'rbac/02: base tables are not reachable, only the *_api views';
end $$;

rollback;
