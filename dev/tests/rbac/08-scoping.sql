-- SCOPE -- private / org / public, as behaviour rather than as a policy anyone
-- can read and believe.
--
-- `01-rls-isolation.sql` proves the owner-or-role shape filters. `02` proves
-- the policies are consulted at all. This file proves the thing those two
-- could not previously ask, because until scope landed there was nothing to
-- ask it about: WHO ELSE can see a row its owner did not write for themselves.
--
-- The three idioms this replaces each failed a different half of that:
--
--   owner-only     could say nobody, and nothing else. agentic.sessions.
--   owner-or-role  could say nobody or EVERY tenant, via a deployment-wide
--                  permission. workflow.runs.
--   org-or-null    could say one org or everyone -- but `org_id is null` meant
--                  both "deliberately global" and "nobody filled it in", and
--                  world-model-ingestion measured a real cross-tenant read
--                  through the second meaning.
--
-- Every assertion below fails again if the corresponding half is removed.
--
-- Real BEGIN/COMMIT per "request", like 01: this is simulating PostgREST,
-- which gives every request its own transaction with its own SET LOCAL claims.
-- A single rolled-back transaction would let one case's identity leak into the
-- next -- which is exactly the defect this suite found in content/01, where
-- `reset role` was mistaken for clearing the claims.

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- 0. Idempotent teardown, scoped to what this file OWNS.
--
-- 01's lesson, applied: this file borrows the deployment's orgs and users and
-- creates only its own probe table. Deleting `alice` because a test made a row
-- owned by her is how a suite removes the deployment's only identity.
-- ---------------------------------------------------------------------
drop table if exists scope_probe;
delete from rbac.org_members
 where user_id = 'cccc0000-0000-0000-0000-0000000000c3';
delete from rbac.users where id = 'cccc0000-0000-0000-0000-0000000000c3';

-- carol: a second member of org A who OWNS NOTHING. She is the whole point of
-- the fixture. alice owns the org-A rows, so reading them proves only that an
-- owner can read their own row -- the ownership arm short-circuits the scope
-- arm and the test passes with the org half deleted. A non-owning member is
-- the only reader whose result is evidence about `visibility = 'org'`.
insert into rbac.users (id, email, status)
values ('cccc0000-0000-0000-0000-0000000000c3', 'carol@test.com', 'active')
on conflict (id) do nothing;
insert into rbac.org_members (org_id, user_id) values
    ('a0000000-0000-0000-0000-00000000000a', 'cccc0000-0000-0000-0000-0000000000c3')
on conflict do nothing;

-- A module, in miniature: a table, the two calls that scope it, and nothing
-- else. If adding scope to a consumer needs more than this, the primitive has
-- failed at the job it exists for.
create table scope_probe (id uuid primary key default gen_random_uuid(), label text);
select rbac.add_scope_columns('public.scope_probe');
select rbac.add_scope_policy ('public.scope_probe');
grant select, insert on scope_probe to authenticated;

-- alice (org A) owns all four. bob (org B) owns none, and is the outsider.
-- rbac.shared_org_id() where this fixture used to write null. org_id is NOT
-- NULL (specs/identity/spec.md §4) and the shared tier is a row, so "no
-- tenancy" is now a value the fixture names. owner_id stays nullable and stays
-- null on the last row, which is the contrast worth keeping: `unowned` really
-- is an absence, and it is the only one of the two that ever was.
insert into scope_probe (label, owner_id, org_id, visibility) values
  ('a-private', '11111111-1111-1111-1111-111111111111', rbac.shared_org_id(), 'private'),
  ('a-org',     '11111111-1111-1111-1111-111111111111',
                'a0000000-0000-0000-0000-00000000000a', 'org'),
  ('a-public',  '11111111-1111-1111-1111-111111111111', rbac.shared_org_id(), 'public'),
  ('unowned',   null, rbac.shared_org_id(), 'public');

-- ---------------------------------------------------------------------
-- 1. THE MATRIX. Four readers, one table, asserted as what each one sees.
--
-- Written as a single expected/actual comparison rather than four separate
-- ifs, because the failure that matters is a reader seeing ONE ROW TOO MANY
-- and a per-case count assertion reports that as a number rather than as a
-- name. `string_agg(label)` says which row leaked.
-- ---------------------------------------------------------------------
create temp table scope_expected (who text, claims text, expect text);
insert into scope_expected values
  ('alice, the owner, member of org A',
   '{"sub":"11111111-1111-1111-1111-111111111111"}',
   'a-org, a-private, a-public, unowned'),
  -- The row that proves `org` is a real tier: carol owns nothing, so a-org
  -- reaches her through membership alone. a-private does not.
  ('carol, member of org A, owner of nothing',
   '{"sub":"cccc0000-0000-0000-0000-0000000000c3"}',
   'a-org, a-public, unowned'),
  ('bob, member of org B, an outsider here',
   '{"sub":"22222222-2222-2222-2222-222222222222"}',
   'a-public, unowned'),
  -- Anonymous sees `public` and nothing else. Worth asserting explicitly: it
  -- is the case most easily forgotten, and the one where a missing policy
  -- shows up as everything rather than as nothing.
  ('an anonymous caller', '', 'a-public, unowned');

do $$
declare r record; v_got text;
begin
    for r in select * from scope_expected loop
        set local role authenticated;
        execute format('set local request.jwt.claims = %L', coalesce(r.claims, ''));
        select coalesce(string_agg(label, ', ' order by label), '(nothing)')
          into v_got from scope_probe;
        reset role;
        if v_got is distinct from r.expect then
            raise exception
                '%: reads [%] where it should read [%]',
                r.who, v_got, r.expect;
        end if;
    end loop;
    raise notice 'rbac/08: private, org and public each mean what they say, for four readers';
end $$;

-- ---------------------------------------------------------------------
-- 2. A TOKEN MAY NARROW ITS ORGS. IT MAY NEVER WIDEN THEM.
--
-- This is the property the whole membership table exists for, and the one
-- `aiq.current_org_ids()` structurally could not have: it read the `orgs`
-- array off the JWT, so the token WAS the membership. Nothing in the database
-- could refuse a token naming an org its subject had been removed from, and
-- nothing could mint one honestly either -- there was no table to read.
--
-- Both directions are asserted, because getting this right in one direction is
-- easy and useless: a claim that cannot widen but also cannot narrow makes a
-- scoped API key impossible to issue.
-- ---------------------------------------------------------------------
do $$
declare v_got text;
begin
    -- (a) WIDEN: bob claims org A, which he does not belong to. He must not
    --     get org A's row. If this passes with the intersection removed, the
    --     org claim is authoritative and the table is decoration.
    set local role authenticated;
    execute format('set local request.jwt.claims = %L', coalesce('{"sub":"22222222-2222-2222-2222-222222222222",'
        '"orgs":["a0000000-0000-0000-0000-00000000000a"]}', ''));
    select coalesce(string_agg(label, ', ' order by label), '(nothing)')
      into v_got from scope_probe;
    reset role;
    if v_got is distinct from 'a-public, unowned' then
        raise exception
            'a token WIDENED its holder''s reach: bob claimed org A and read [%]. '
            'The orgs claim must be intersected with rbac.org_members, never '
            'trusted as the membership itself', v_got;
    end if;

    -- (b) NARROW: carol belongs to org A and presents a token naming no orgs.
    --     She must lose the org tier -- this is how a scoped API key or an
    --     agent token acts for a user with less than that user's full reach.
    set local role authenticated;
    execute format('set local request.jwt.claims = %L', '{"sub":"cccc0000-0000-0000-0000-0000000000c3","orgs":[]}');
    select coalesce(string_agg(label, ', ' order by label), '(nothing)')
      into v_got from scope_probe;
    reset role;
    if v_got is distinct from 'a-public, unowned' then
        raise exception
            'a token could not NARROW: carol presented an empty orgs claim and '
            'still read [%]. Without this a token cannot be issued for fewer '
            'orgs than its subject holds', v_got;
    end if;

    -- (c) ABSENT is not the same as EMPTY. No `orgs` key at all means the full
    --     membership -- otherwise every ordinary login would be org-blind, and
    --     (b) would be indistinguishable from a function that always returns
    --     nothing.
    set local role authenticated;
    execute format('set local request.jwt.claims = %L', '{"sub":"cccc0000-0000-0000-0000-0000000000c3"}');
    select coalesce(string_agg(label, ', ' order by label), '(nothing)')
      into v_got from scope_probe;
    reset role;
    if v_got is distinct from 'a-org, a-public, unowned' then
        raise exception
            'a token with NO orgs claim was treated as a token with an EMPTY '
            'one: carol read [%] rather than her full membership', v_got;
    end if;

    raise notice 'rbac/08: an orgs claim narrows membership, never widens it, and absent is not empty';
end $$;

-- ---------------------------------------------------------------------
-- 3. THE WRITE HALF.
--
-- A read policy that is right and a write policy that is not gives you a
-- database where a tenant cannot see another tenant's rows and can create
-- them. content/01 records that exact pairing as a measured defect.
-- ---------------------------------------------------------------------
do $$
declare v_ok boolean;
begin
    -- (a) Writing into an org you do not belong to.
    set local role authenticated;
    execute format('set local request.jwt.claims = %L', '{"sub":"22222222-2222-2222-2222-222222222222"}');
    v_ok := false;
    begin
        insert into scope_probe (label, owner_id, org_id, visibility)
        values ('sneak', '22222222-2222-2222-2222-222222222222',
                'a0000000-0000-0000-0000-00000000000a', 'org');
        v_ok := true;
    exception when insufficient_privilege then null;
    end;
    reset role;
    if v_ok then
        raise exception 'bob wrote a row into org A, which he does not belong to';
    end if;

    -- (b) Writing a row owned by somebody else. This is the shape grant_role's
    --     escalation had -- a caller-supplied "who is this" -- arriving as a
    --     column rather than as an argument.
    set local role authenticated;
    execute format('set local request.jwt.claims = %L', '{"sub":"22222222-2222-2222-2222-222222222222"}');
    v_ok := false;
    begin
        insert into scope_probe (label, owner_id, visibility)
        values ('impostor', '11111111-1111-1111-1111-111111111111', 'public');
        v_ok := true;
    exception when insufficient_privilege then null;
    end;
    reset role;
    if v_ok then
        raise exception 'bob wrote a row owned by alice';
    end if;

    raise notice 'rbac/08: a caller cannot write into another org, nor under another owner';
end $$;

-- ---------------------------------------------------------------------
-- 4. `org` WITHOUT AN ORG IS REFUSED BY THE DATABASE, on every path.
--
-- The trigger and not the policy, deliberately, and this is the assertion that
-- proves the difference matters: the check runs as the TABLE OWNER, who
-- bypasses RLS entirely. Every SECURITY DEFINER write path in the collection
-- runs that way by design -- register_upload, upsert_agent, record_chunks --
-- so a rule enforced only in a policy is not enforced on the paths that have
-- historically got tenancy wrong.
--
-- A row saying `org` with no org is not merely malformed: it is invisible to
-- everyone including its owner if it has none, which is a row that exists and
-- cannot be found.
-- ---------------------------------------------------------------------
do $$
declare v_ok boolean := false;
begin
    -- as app_owner: no RLS at all, so only the trigger can refuse this
    begin
        -- rbac.shared_org_id() and not null, and the swap makes the test
        -- stronger rather than merely compatible. A null org_id is refused by
        -- the NOT NULL constraint now, so this block would go on passing with
        -- rbac.enforce_visibility() deleted -- for the wrong reason, and with
        -- a message that names a column instead of the rule. The SHARED org is
        -- the case only the trigger can catch: it is a real org, the foreign
        -- key is satisfied, the column is populated, and `visibility = 'org'`
        -- on it is still a row nobody can read.
        insert into scope_probe (label, org_id, visibility)
        values ('orgless', rbac.shared_org_id(), 'org');
        v_ok := true;
    exception when others then
        if position('requires an org_id' in sqlerrm) = 0 then raise; end if;
    end;
    if v_ok then
        raise exception
            'a row was written with visibility ''org'' and no org_id, by the table '
            'owner -- the rule lives in a policy the trusted write path bypasses, '
            'not in the trigger every path goes through';
    end if;

    -- and the vocabulary itself is closed by the foreign key, not by a CHECK
    -- somebody has to keep in step with rbac.visibilities
    v_ok := false;
    begin
        insert into scope_probe (label, visibility) values ('bogus', 'everyone');
        v_ok := true;
    exception when foreign_key_violation then null;
    end;
    if v_ok then
        raise exception 'a scope outside rbac.visibilities was accepted';
    end if;

    raise notice 'rbac/08: the trigger refuses org-without-an-org even for the table owner, and the vocabulary is closed';
end $$;

-- ---------------------------------------------------------------------
-- 5. OWNERSHIP IS CURRENT, NOT HISTORICAL.
--
-- Transferring a row must take the old owner's access with it. Worth asserting
-- because the natural implementation of "sharing" is an additional grant and
-- the natural bug is an additional grant that is never withdrawn.
-- ---------------------------------------------------------------------
do $$
declare v_n int;
begin
    update scope_probe set owner_id = '22222222-2222-2222-2222-222222222222'
     where label = 'a-private';

    set local role authenticated;
    execute format('set local request.jwt.claims = %L', '{"sub":"11111111-1111-1111-1111-111111111111"}');
    select count(*) into v_n from scope_probe where label = 'a-private';
    reset role;
    if v_n <> 0 then
        raise exception 'the previous owner can still read a row that was transferred away';
    end if;

    set local role authenticated;
    execute format('set local request.jwt.claims = %L', '{"sub":"22222222-2222-2222-2222-222222222222"}');
    select count(*) into v_n from scope_probe where label = 'a-private';
    reset role;
    if v_n <> 1 then
        raise exception 'the new owner cannot read the row transferred to them';
    end if;

    raise notice 'rbac/08: access follows ownership rather than accumulating';
end $$;

-- ---------------------------------------------------------------------
-- 6. REVOKING MEMBERSHIP TAKES EFFECT ON THE NEXT REQUEST.
--
-- The reason the membership table is the truth and the token is not. Under the
-- old model -- the orgs array read straight off the JWT -- removing somebody
-- from an org did nothing until their token expired, and a refresh token
-- rotates into a new 30-day one, so "somebody left the company" was enforced
-- whenever their client happened to stop asking.
-- ---------------------------------------------------------------------
do $$
declare v_n int;
begin
    delete from rbac.org_members
     where user_id = 'cccc0000-0000-0000-0000-0000000000c3'
       and org_id = 'a0000000-0000-0000-0000-00000000000a';

    set local role authenticated;
    -- the SAME token as section 1, still naming her subject: nothing about the
    -- credential changed, only the row
    execute format('set local request.jwt.claims = %L', '{"sub":"cccc0000-0000-0000-0000-0000000000c3"}');
    select count(*) into v_n from scope_probe where label = 'a-org';
    reset role;
    if v_n <> 0 then
        raise exception
            'a removed member still reads the org''s rows with the token they '
            'already held -- membership is being taken from the claim rather '
            'than from rbac.org_members';
    end if;
    raise notice 'rbac/08: removing a member takes effect on their next request, not at token expiry';
end $$;

-- ---------------------------------------------------------------------
-- 7. Teardown. This file commits (see the header), so it cleans up after
--    itself rather than leaving a probe table and a carol behind.
-- ---------------------------------------------------------------------
drop table scope_probe;
delete from rbac.org_members where user_id = 'cccc0000-0000-0000-0000-0000000000c3';
delete from rbac.users where id = 'cccc0000-0000-0000-0000-0000000000c3';
