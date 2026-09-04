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

-- ---------------------------------------------------------------------
-- 7. THE FUNCTION EVERY POLICY CALLS DOES NOT ITSELF GO THROUGH RLS.
--
-- has_permission() reads rbac.user_roles, and rbac.user_roles has a policy
-- that calls has_permission(). As SECURITY INVOKER that is a cycle Postgres
-- cannot see -- its own "infinite recursion detected in policy" check only
-- catches a policy naming its own table directly, and here the self-reference
-- is laundered through a function. The backend blows its stack instead, from
-- inside has_permission, with nothing in the error naming RLS at all.
--
-- 01-rls-isolation.sql is what actually catches a regression here, by
-- selecting as a user who neither owns the row nor holds the permission --
-- the only caller shape that reaches the second disjunct. This assertion adds
-- the diagnosis: `stack depth limit exceeded` is a long way from "somebody
-- dropped SECURITY DEFINER", and without this the next person debugs the
-- symptom rather than reading the cause.
-- ---------------------------------------------------------------------
do $$
declare v_secdef boolean; v_config text[];
begin
    select prosecdef, proconfig into v_secdef, v_config
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'rbac' and p.proname = 'has_permission';

    if not v_secdef then
        raise exception 'rbac.has_permission is SECURITY INVOKER -- it will recurse '
                        'through user_roles'' own policy until the backend runs out of '
                        'stack, for every caller who does not already own the row being '
                        'scanned. That is exactly the population RLS exists to constrain.';
    end if;
    if v_config is null or not (v_config::text like '%search_path%') then
        raise exception 'rbac.has_permission is SECURITY DEFINER with no pinned '
                        'search_path -- the CVE-2018-1058 hardening this collection '
                        'applies unconditionally (specs/README.md ground rules)';
    end if;
    raise notice 'rbac/02: has_permission runs as definer with a pinned search_path, '
                 'so the policy that calls it cannot recurse into itself';
end $$;

-- ---------------------------------------------------------------------
-- 7. rbac.current_org_ids IS SECURITY DEFINER, for the identical reason.
--
-- rbac.org_members has its own SELECT policy and that policy calls this
-- function, so invoker rights here is the same two-hop cycle laundered through
-- a function that §6 documents for has_permission. Asserted separately rather
-- than folded into §6 because the two failures look nothing alike from the
-- outside: has_permission's recursion needs a caller who owns nothing, while
-- this one fires for every caller who belongs to any org -- which after
-- multi-tenancy is most of them.
-- ---------------------------------------------------------------------
do $$
declare v_secdef boolean; v_config text[];
begin
    select prosecdef, proconfig into v_secdef, v_config
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'rbac' and p.proname = 'current_org_ids';
    if not v_secdef then
        raise exception 'rbac.current_org_ids is SECURITY INVOKER -- it will recurse '
                        'through org_members'' own policy until the backend runs out '
                        'of stack';
    end if;
    if v_config is null or not (v_config::text like '%search_path%') then
        raise exception 'rbac.current_org_ids is SECURITY DEFINER with no pinned '
                        'search_path';
    end if;
    raise notice 'rbac/02: current_org_ids runs as definer with a pinned search_path';
end $$;

-- ---------------------------------------------------------------------
-- 8. EVERY SCOPED TABLE CARRIES THE GENERATED PREDICATE, UNMODIFIED.
--
-- THE DIRECTION MATTERS, and it is the one this file was otherwise missing.
-- §3 above iterates tables that HAVE policies and checks something about them,
-- which is the direction that can only find a policy somebody wrote. It cannot
-- find the table somebody added a `visibility` column to and forgot to scope,
-- and that table reads as scoped to anyone looking at its columns while being
-- readable by everyone with a grant.
--
-- So this runs from the DATABASE outward: enumerate every table that carries
-- the scope columns, and require of each that it has the generated policy.
-- Nothing has to be kept up to date -- there is no list of scoped tables here,
-- because a list is the thing that goes stale.
--
-- Compared against rbac.scope_predicate() through a freshly generated policy
-- rather than against a string written here, for the reason
-- dev/vocab-audit.py asks p8.enums() instead of running its own catalog query:
-- an audit that restates the thing it audits is one more copy free to drift.
-- pg_get_expr returns the PARSED form -- casts explicit, whitespace
-- regularised -- so the only honest comparison is parsed-against-parsed, which
-- means generating one.
-- ---------------------------------------------------------------------
create table rls_probe_generated (id int);
select rbac.add_scope_columns('public.rls_probe_generated');
select rbac.add_scope_policy ('public.rls_probe_generated');

do $$
declare
    v_expected text;
    r record;
    v_bad text := '';
begin
    select pg_get_expr(polqual, polrelid) into v_expected
      from pg_policy p join pg_class c on c.oid = p.polrelid
     where c.relname = 'rls_probe_generated' and p.polname = 'rls_probe_generated_scoped';
    -- The OUTERMOST parens are stripped before comparing, and finding out why
    -- is worth the line: Postgres FLATTENS nested ORs when it parses a policy,
    -- so the probe's three-arm predicate comes back as `(a OR b OR c)` while a
    -- table that also carries the has_permission override comes back as
    -- `(a OR b OR c OR d)` -- not as `(a OR b OR c) OR d`. A prefix match
    -- against the parenthesised form therefore fails on the closing bracket
    -- for exactly the six tables that have an override, which is the majority
    -- of them. Compare the arms, not the punctuation.
    v_expected := left(right(v_expected, -1), -1);

    for r in
        select n.nspname as sch, c.relname as tbl
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        join pg_attribute a on a.attrelid = c.oid and a.attname = 'visibility'
                           and not a.attisdropped
        where c.relkind = 'r'
          and n.nspname in ('rbac','workflow','aiq','content','agentic')
        order by 1, 2
    loop
        -- The generated read policy is <table>_scoped, and its expression is
        -- the probe's plus, optionally, the has_permission override arm --
        -- which differs per table because it names that table's resource. So
        -- the requirement is that it STARTS WITH the generated predicate: a
        -- policy that adds an arm is a deliberate widening somebody wrote,
        -- and a policy that changes the first three arms is drift.
        if not exists (
            select 1 from pg_policy p
            join pg_class c on c.oid = p.polrelid
            join pg_namespace n2 on n2.oid = c.relnamespace
            where n2.nspname = r.sch and c.relname = r.tbl
              and p.polname = r.tbl || '_scoped'
              and pg_get_expr(p.polqual, p.polrelid) like '(' || v_expected || '%')
        then
            v_bad := v_bad || format('%s.%s ', r.sch, r.tbl);
        end if;
    end loop;

    if v_bad <> '' then
        raise exception
            'these tables carry the scope columns and not the generated scope '
            'policy: %. A `visibility` column with no policy consulting it is '
            'a table that READS as scoped and is not -- add it with '
            'rbac.add_scope_policy(), never by hand. A table that deliberately '
            'reads differently -- workflow.pools takes the columns and keeps '
            '`using (true)`, because a worker must see the queue it serves -- '
            'belongs in an exemption stated here, not in silence.', v_bad;
    end if;
    raise notice 'rbac/08 precondition: every table with a visibility column carries the generated predicate';
end $$;

-- ...and the trigger, which is the half a policy cannot do. The policy holds
-- `org needs an org` for callers arriving through RLS; every SECURITY DEFINER
-- write path bypasses RLS by design, so the trigger is the only thing standing
-- between register_upload and a row that is invisible to everyone.
do $$
declare v_bad text;
begin
    select string_agg(n.nspname || '.' || c.relname, ', ' order by n.nspname, c.relname)
      into v_bad
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attname = 'visibility'
                         and not a.attisdropped
     where c.relkind = 'r'
       and n.nspname in ('rbac','workflow','aiq','content','agentic')
       and not exists (select 1 from pg_trigger t
                        where t.tgrelid = c.oid and not t.tgisinternal
                          and t.tgfoid = 'rbac.enforce_visibility'::regproc);
    if v_bad is not null then
        raise exception
            'these scoped tables have no rbac.enforce_visibility trigger: %. '
            'They will accept visibility ''org'' with a null org_id from every '
            'SECURITY DEFINER writer, which is a row nobody can read.', v_bad;
    end if;
    raise notice 'rbac/02: every scoped table carries the enforce_visibility trigger';
end $$;

-- ---------------------------------------------------------------------
-- 9. THE RETIRED PREDICATES ARE GONE FROM EVERY POLICY, NOT MOST.
--
-- `aiq.current_org_ids()` read the orgs array off the JWT and
-- `content.may_access_org()` inferred a caller's intent from whether their
-- token named any org. Both were replaced; what this asserts is that the
-- replacement reached every policy rather than the files somebody remembered.
--
-- A partial migration here is the worst possible state: half the tables scoped
-- against membership rows and half against a claim, with no symptom until the
-- two disagree -- which is precisely when somebody has been removed from an
-- org and it matters.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(n.nspname || '.' || c.relname || ' (' || p.polname || ')',
                      ', ' order by n.nspname, c.relname)
      into v_bad
      from pg_policy p
      join pg_class c on c.oid = p.polrelid
      join pg_namespace n on n.oid = c.relnamespace
     where coalesce(pg_get_expr(p.polqual, p.polrelid), '')
             ~ '(aiq\.current_org_ids|content\.may_access_org)'
        or coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '')
             ~ '(aiq\.current_org_ids|content\.may_access_org)';
    if v_bad is not null then
        raise exception
            'these policies still call a retired predicate: %. aiq.current_org_ids '
            'trusted the token as the membership and content.may_access_org guessed '
            'intent from it -- both are rbac.current_org_ids now, which reads '
            'rbac.org_members.', v_bad;
    end if;
    raise notice 'rbac/02: no policy still scopes on the retired org predicates';
end $$;

rollback;
