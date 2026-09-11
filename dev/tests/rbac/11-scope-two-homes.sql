-- ONE RULE, TWO HOMES, AND NOTHING COMPARING THEM.
--
-- spec.md §2b writes the scope rule twice on purpose, and says why. A policy
-- gets the GENERATED expression (`rbac.scope_predicate()` /
-- `rbac.scope_write_predicate()`) because calling a function on row columns
-- measured 58x slower; a SECURITY DEFINER function that has already fetched one
-- row calls `rbac.may_read()` / `rbac.may_write()` instead, because there is no
-- per-row cost there and a readable name is worth more than an inlined
-- expression.
--
-- The two are meant to say the same thing. Nothing checked that they do, and
-- the population that would notice is the one nobody sees: every definer write
-- path in the collection -- `register_upload`, `complete_task`, `upsert_agent`
-- -- bypasses RLS by design, so on those paths `may_write()` IS the rule.
-- `may_read()` is the same for the definer readers. If the generated predicate
-- and the function ever disagree, the answer a caller gets depends on which
-- door they came through, and both doors report success.
--
-- The disagreement does not have to be a mistake to happen: the visibility
-- vocabulary is a TABLE precisely so a fourth tier can be added later, and
-- adding one means editing an expression and a function that live four hundred
-- lines apart. This file is what makes that a failing test rather than a
-- tenancy leak.
--
-- It compares SETS rather than spot-checking rows: the fixture is the cross
-- product of owner x org x visibility, minus the combination the trigger
-- refuses, read once through RLS as the caller and once through the function
-- as the owner. Same identity, same rows, two doors.
\set ON_ERROR_STOP on

begin;

-- The probe table is a throwaway, adopted the way the spec tells a module to
-- adopt scope -- two calls and no hand-written policy -- so what is under test
-- is the generator, not a copy of its output pasted here.
create table public.scope_homes_probe (id int primary key, label text);
select rbac.add_scope_columns('public.scope_homes_probe');
select rbac.add_scope_policy ('public.scope_homes_probe', 'users');
grant select, insert on public.scope_homes_probe to authenticated;

select rbac.create_user_with_password('homes-member@test.com',  'a passphrase one') as member_id \gset
select rbac.create_user_with_password('homes-outsider@test.com', 'a passphrase two') as outsider_id \gset
insert into rbac.orgs (slug, name) values ('homes-org', 'homes org') returning id as org_id \gset
insert into rbac.orgs (slug, name) values ('homes-other', 'other org') returning id as other_org_id \gset
insert into rbac.org_members (org_id, user_id, role) values (:'org_id', :'member_id', 'member');

-- Neither identity holds a role, and the generated read policy ends with
-- `or has_permission(uid, 'users', 'select')` -- an operator override that
-- would admit every row and make both sides of the comparison "everything".
-- Asserted rather than assumed, because the file passes vacuously if it is
-- ever untrue.
do $$
begin
    if exists (select 1 from rbac.users u
                where u.email in ('homes-member@test.com', 'homes-outsider@test.com')
                  and rbac.has_permission(u.id, 'users', 'select')) then
        raise exception 'a probe identity holds users/select -- the override admits '
                        'every row and this file compares two copies of "everything"';
    end if;
end $$;

-- rbac.shared_org_id() where the rows below used to say null: org_id is NOT
-- NULL (specs/identity/spec.md §4) and "on no tenant in particular" is the
-- shared tier, which is a row. owner_id keeps its nulls -- an unowned row is a
-- genuine absence, and the two columns no longer look alike.
insert into public.scope_homes_probe (id, label, owner_id, org_id, visibility) values
    (1,  'mine, private',            :'member_id',   rbac.shared_org_id(), 'private'),
    (2,  'mine, in my org',          :'member_id',   :'org_id',        'org'),
    (3,  'mine, public',             :'member_id',   rbac.shared_org_id(), 'public'),
    (4,  'theirs, private',          :'outsider_id', rbac.shared_org_id(), 'private'),
    (5,  'theirs, in my org',        :'outsider_id', :'org_id',        'org'),
    (6,  'theirs, public',           :'outsider_id', rbac.shared_org_id(), 'public'),
    (7,  'theirs, in another org',   :'outsider_id', :'other_org_id',  'org'),
    (8,  'unowned, public',          null,           rbac.shared_org_id(), 'public'),
    (9,  'unowned, private',         null,           rbac.shared_org_id(), 'private'),
    (10, 'unowned, in my org',       null,           :'org_id',        'org'),
    (11, 'unowned, in another org',  null,           :'other_org_id',  'org'),
    -- An owned row carrying an org it is not scoped to: `private` wins, and
    -- both homes have to agree that the org on the row is not what admits it.
    (12, 'mine, private, in my org', :'member_id',   :'org_id',        'private'),
    (13, 'theirs, private, in my org', :'outsider_id', :'org_id',      'private');

-- ---------------------------------------------------------------------
-- 1. THE READ HALF, for three callers.
--
-- The member is the interesting one; the outsider is what separates "the org
-- arm works" from "the org arm is true"; the claimless caller is the service
-- connection, which has no identity and must therefore see public rows only.
--
-- The function side is evaluated as the table owner, who bypasses RLS -- which
-- is exactly the position a SECURITY DEFINER function is in when it calls
-- may_read() about a row it has already fetched.
-- ---------------------------------------------------------------------
do $$
declare
    v_caller   text;
    v_sub      uuid;
    v_by_fn    text;
    v_by_rls   text;
begin
    foreach v_caller in array array['member','outsider','claimless'] loop
        select id into v_sub from rbac.users
         where email = case v_caller when 'member' then 'homes-member@test.com'
                                     when 'outsider' then 'homes-outsider@test.com'
                                     else 'nobody@test.com' end;

        if v_caller = 'claimless' then
            execute format('set local request.jwt.claims = %L', '');
        else
            execute format('set local request.jwt.claims = %L', coalesce(json_build_object('sub', v_sub)::text, ''));
        end if;

        select string_agg(id::text, ',' order by id) into v_by_fn
          from public.scope_homes_probe
         where rbac.may_read(owner_id, org_id, visibility);

        set local role authenticated;
        select string_agg(id::text, ',' order by id) into v_by_rls
          from public.scope_homes_probe;
        reset role;

        if v_by_fn is distinct from v_by_rls then
            raise exception
                E'the two homes of the read rule disagree for the % caller:\n'
                 '             may_read() admits [%]\n'
                 '             the policy admits [%]\n\n'
                 'One of rbac.may_read() and rbac.scope_predicate() has been '
                 'changed without the other. Every SECURITY DEFINER reader in the '
                 'collection uses the first and every RLS caller gets the second, '
                 'so a row in the difference is visible through one door and not '
                 'the other, with nothing raising on either.',
                v_caller, coalesce(v_by_fn,''), coalesce(v_by_rls,'');
        end if;
    end loop;

    -- And the answer is not trivially "everything" or "nothing" -- a comparison
    -- of two broken sides passes.
    execute format('set local request.jwt.claims = %L', coalesce(json_build_object('sub', (select id from rbac.users where email = 'homes-member@test.com'))::text, ''));
    set local role authenticated;
    if (select count(*) from public.scope_homes_probe) not between 1 and 12 then
        raise exception 'the member sees % of 13 rows -- the fixture is not discriminating',
                        (select count(*) from public.scope_homes_probe);
    end if;
    reset role;

    raise notice 'rbac/11: may_read() and the generated read policy admit exactly the '
                 'same rows, for a member, an outsider and a claimless connection';
end $$;

-- ---------------------------------------------------------------------
-- 2. THE WRITE HALF, which is the one with the history.
--
-- `may_write()` replaced `content.may_access_org()` at thirteen call sites, and
-- the bug that motivated scope was a write: a null org meaning both
-- "deliberately global" and "nobody filled it in". Here every candidate row is
-- offered to the policy (as the caller) and to the function (as the owner), and
-- the two answers have to match row by row -- a set comparison would let a
-- refusal on one row cancel an acceptance on another.
--
-- The insert is attempted and rolled back to a savepoint, because WITH CHECK
-- has no read-only form: the only way to ask a write policy what it thinks is
-- to write.
-- ---------------------------------------------------------------------
do $$
declare
    r         record;
    v_sub     uuid;
    v_fn      boolean;
    v_policy  boolean;
    v_next    int := 100;
begin
    select id into v_sub from rbac.users where email = 'homes-member@test.com';
    execute format('set local request.jwt.claims = %L', coalesce(json_build_object('sub', v_sub)::text, ''));

    for r in
        select * from (values
            ('mine, private',          'member',   null,      'private'),
            ('mine, my org',           'member',   'mine',    'org'),
            ('mine, public',           'member',   null,      'public'),
            ('mine, another org',      'member',   'other',   'org'),
            ('theirs, private',        'outsider', null,      'private'),
            ('theirs, my org',         'outsider', 'mine',    'org'),
            ('unowned, public',        null,       null,      'public'),
            ('unowned, my org',        null,       'mine',    'org'),
            ('unowned, another org',   null,       'other',   'org'),
            -- `org` with no org -- which is now `org` on the SHARED org,
            -- because that is what "no org" became. The refusal arrives from
            -- rbac.enforce_visibility() rather than from the policy -- a BEFORE
            -- trigger runs first -- and that is the point rather than a
            -- blurring of two layers: what must agree is may_write() and what
            -- the write path DOES, whichever of the two says no. Without this
            -- row the third clause of both rules is unexercised, and dropping
            -- it from may_write() leaves this file green.
            ('mine, org without an org', 'member', null,      'org')
        ) as t(label, owner, org, visibility)
    loop
        declare
            v_owner uuid := case r.owner
                              when 'member' then v_sub
                              when 'outsider' then (select id from rbac.users
                                                     where email = 'homes-outsider@test.com')
                              else null end;
            -- The fallthrough is rbac.shared_org_id() and not null, and the
            -- difference is what this block exists to catch. org_id is NOT
            -- NULL (specs/identity/spec.md §4), so an INSERT of null is
            -- refused by the constraint before any policy is consulted --
            -- while rbac.may_write(owner, null, ...) reads a null ARGUMENT as
            -- "the caller did not say", which is the shared tier, and answers
            -- true. Left as null the two homes disagree on four of the eleven
            -- rows, and they disagree for a reason that is about the fixture
            -- rather than about the rule: `no org` is now a value, so the
            -- fixture has to name it.
            --
            -- Every SECURITY DEFINER writer resolves the same way, through
            -- rbac.org_or_shared() at its boundary, so this is the comparison
            -- that matches what those writers actually do.
            v_org uuid := case r.org
                            when 'mine'  then (select id from rbac.orgs where slug = 'homes-org')
                            when 'other' then (select id from rbac.orgs where slug = 'homes-other')
                            else rbac.shared_org_id() end;
        begin
            v_fn := rbac.may_write(v_owner, v_org, r.visibility);

            v_next := v_next + 1;
            begin
                set local role authenticated;
                insert into public.scope_homes_probe (id, label, owner_id, org_id, visibility)
                values (v_next, r.label, v_owner, v_org, r.visibility);
                reset role;
                v_policy := true;
            exception when others then
                reset role;
                v_policy := false;
            end;

            if v_fn is distinct from v_policy then
                raise exception
                    'the two homes of the write rule disagree on "%": may_write() says %, '
                    'the policy says %. Every SECURITY DEFINER writer in the collection '
                    'checks the first and bypasses the second, so this row is a write '
                    'one path accepts and the other refuses.',
                    r.label, v_fn, v_policy;
            end if;
        end;
    end loop;

    raise notice 'rbac/11: may_write() and the generated write policy accept and refuse '
                 'the same ten writes, owner by owner and org by org';
end $$;

-- ---------------------------------------------------------------------
-- 3. AND THE POLICY ON THE TABLE IS STILL THE GENERATED ONE.
--
-- rbac/02 asserts this for every scoped table in the collection. Repeated here
-- for the probe table alone, because sections 1 and 2 compare the function
-- against whatever policy this table happens to carry -- and if the generator
-- stopped being what produced it, they would agree about the wrong thing.
-- ---------------------------------------------------------------------
do $$
declare v_live text; v_generated text;
begin
    -- rbac/02's technique: generate the policy again onto a THROWAWAY table
    -- and compare parsed form against parsed form. Comparing the live policy
    -- with `rbac.scope_predicate()`'s own text would compare formatting, and
    -- re-assembling the override arm here by hand would be this file checking
    -- the generator against a second copy of the generator.
    create table public.scope_homes_probe_2 (id int primary key);
    perform rbac.add_scope_columns('public.scope_homes_probe_2');
    perform rbac.add_scope_policy ('public.scope_homes_probe_2', 'users');

    select pg_get_expr(polqual, polrelid) into v_live from pg_policy
     where polrelid = 'public.scope_homes_probe'::regclass
       and polname = 'scope_homes_probe_scoped';
    select pg_get_expr(polqual, polrelid) into v_generated from pg_policy
     where polrelid = 'public.scope_homes_probe_2'::regclass
       and polname = 'scope_homes_probe_2_scoped';
    drop table public.scope_homes_probe_2;

    if v_live is null or v_generated is null then
        raise exception 'the probe table has no generated read policy';
    end if;
    if v_live is distinct from v_generated then
        raise exception
            E'the probe table\'s policy is not what the generator produces:\n'
             '             live      [%]\n'
             '             generated [%]',
            v_live, v_generated;
    end if;

    raise notice 'rbac/11: the probe table carries the generated predicate, so sections 1 '
                 'and 2 compared the function against the real policy';
end $$;

-- ---------------------------------------------------------------------
-- 4. THE ARM THAT TRUSTS A CONNECTION WITH NOTHING TO SAY.
--
-- `rbac.scope_write_predicate()` opens with `request.jwt.claims is null` and
-- means it: a connection carrying no claims at all is a service connection, a
-- migration or a psql session, and every write policy in the collection admits
-- it unconditionally. That is deliberate and it is the right reading -- but it
-- means RLS is NOT what stands between `web_anon` and a write, because an
-- anonymous PostgREST request has no JWT and therefore no claims. The grant is.
--
-- So the guarantee is the absence of a grant, and an absence is exactly what
-- nothing notices when it stops being true: one `grant insert on <table> to
-- web_anon`, added for a plausible reason, is an anonymous write that every
-- generated policy in the collection waves through. Walked over the catalogue
-- rather than over a list of tables, for rbac/05's reason.
-- ---------------------------------------------------------------------
do $$
declare v_granted text;
begin
    select string_agg(format('%s.%s: %s', n.nspname, c.relname, p.priv), E'\n             '
                      order by n.nspname, c.relname, p.priv)
      into v_granted
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      cross join lateral (values ('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE')) p(priv)
     where c.relkind in ('r','v')
       and n.nspname not in ('pg_catalog','information_schema')
       -- REACHABLE, not merely granted, and the two come apart in CI.
       --
       -- A privilege on a table in a schema the role cannot enter is not a
       -- privilege it holds: every reference to the table is refused at the
       -- schema before the table ACL is ever consulted. has_table_privilege()
       -- answers only the second half, so on its own it reports a write that
       -- cannot be attempted.
       --
       -- It reported exactly one: pg_cron grants SELECT and DELETE on
       -- cron.job_run_details to PUBLIC, web_anon is a member of PUBLIC like
       -- every role, and `cron` grants USAGE to nobody. So this failed on every
       -- database that has pg_cron and passed on every database that does not
       -- -- which is to say it failed in CI and passed locally, because
       -- dev/reload.sh deliberately skips pg_cron (cron.database_name binds it
       -- to one database) while suite.yml deliberately installs it.
       --
       -- Nothing is weakened by asking the whole question. Grant web_anon USAGE
       -- on cron and this fires again, correctly; every percolate schema
       -- already grants it, so every finding this check was written for is
       -- still a finding. And it is not this collection's business to revoke a
       -- grant pg_cron makes on its own table -- what is its business is not
       -- calling somebody else's unreachable grant an anonymous write path.
       and has_schema_privilege('web_anon', n.oid, 'usage')
       and has_table_privilege('web_anon', c.oid, p.priv);

    if v_granted is not null then
        raise exception
            E'web_anon holds write privileges:\n             %\n\n%',
            v_granted,
            'An anonymous request carries no request.jwt.claims, and the first arm '
            'of rbac.scope_write_predicate() admits a claimless caller to every '
            'scoped table -- so no RLS policy in this collection will refuse this '
            'write. Anonymous callers reach the database through the five '
            'SECURITY DEFINER entry points rbac/04 enumerates, never through a '
            'table grant.';
    end if;
    raise notice 'rbac/11: web_anon holds no write privilege it could reach anywhere, '
                 'which is what stands in for the write policy the claimless arm '
                 'waves through';
end $$;

rollback;
