-- The three rbac surfaces a logged-in stranger can reach and nothing tested.
--
-- Found by asking a different question than "is this function covered": which
-- objects can a CALLER role actually execute or select? Three answers came back
-- with no test behind them at all -- rbac.grant_role, rbac.api_keys_api and
-- rbac.refresh_tokens_api -- and they are, in order, the function that hands
-- out roles and the two views over the tables holding credentials.
--
-- All three are correctly built today. That is precisely why they are worth
-- pinning: the guard in grant_role is one `if` that a refactor can drop, and
-- the two policies are one `or` away from self-or-anybody. Nothing in the suite
-- would have said a word.
--
-- Entered as a caller for the same reason agentic/03 is: RLS does not apply to
-- the owner, so reading these tables as p8 proves nothing about who may read
-- them. One BEGIN/COMMIT per request, as PostgREST does it.

\set ON_ERROR_STOP on

\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set akey  'bbbbbbbb-0000-4000-8000-00000000ac01'
\set bkey  'bbbbbbbb-0000-4000-8000-00000000ac02'
\set atok  'bbbbbbbb-0000-4000-8000-00000000ac03'

-- The identities are BORROWED. alice and bob are created by rbac/01 and left
-- behind on purpose (its header explains why deleting them breaks other
-- subsystems' foreign keys), so this file depends on that one having run --
-- as workflow/02 and workflow/06 already do. Said out loud here because the
-- failure otherwise is a foreign-key violation on refresh_tokens, which names
-- the symptom and not the cause.
do $$
begin
    if not exists (select 1 from rbac.users
                    where id = '11111111-1111-1111-1111-111111111111')
    then
        raise exception
            'the shared fixture identities are missing -- run dev/tests/rbac/'
            '01-rls-isolation.sql first, or the whole suite via dev/tests/run.sh';
    end if;
end $$;

-- 0. Teardown scoped to this file's own rows. alice and bob are borrowed, as
--    rbac/01 explains at length; their roles are deployment vocabulary and are
--    not touched here either.
delete from rbac.api_keys       where id in (:'akey', :'bkey');
delete from rbac.refresh_tokens where id = :'atok';

-- 1. Fixture: one key each, and a refresh token for alice. The hashes are
--    obvious non-secrets -- nothing here is a credential, it just has to
--    occupy the column the views are supposed to leave out.
insert into rbac.api_keys (id, user_id, label, key_hash)
values (:'akey', :'alice', 'alice probe key', 'not-a-real-hash-alice'),
       (:'bkey', :'bob',   'bob probe key',   'not-a-real-hash-bob');

insert into rbac.refresh_tokens (id, user_id, token_hash, device_label, expires_at)
values (:'atok', :'alice', 'not-a-real-token-hash', 'alice probe device',
        now() + interval '1 day');

-- 2. As bob: he sees his own key and not alice's, and none of alice's tokens.
--    Both halves matter -- a policy that returned nothing to anyone would pass
--    the isolation check alone while breaking the feature.
begin;
    set local role authenticated;
    set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
declare v_mine int; v_theirs int; v_tok int;
begin
    select count(*) into v_mine   from rbac.api_keys_api where id = 'bbbbbbbb-0000-4000-8000-00000000ac02';
    select count(*) into v_theirs from rbac.api_keys_api where id = 'bbbbbbbb-0000-4000-8000-00000000ac01';
    select count(*) into v_tok    from rbac.refresh_tokens_api where id = 'bbbbbbbb-0000-4000-8000-00000000ac03';
    if v_mine <> 1 then
        raise exception 'bob cannot see his own api key through api_keys_api';
    end if;
    if v_theirs <> 0 then
        raise exception 'bob read alice''s api key row through api_keys_api';
    end if;
    if v_tok <> 0 then
        raise exception 'bob read alice''s refresh token row through refresh_tokens_api';
    end if;
end $$;
commit;

-- 3. The columns themselves. surface.sql's round trip already refuses a secret
--    that appears in an *_api view, but it checks the DECLARED exclusions; this
--    asks the catalog directly, so a view that gains key_hash without anyone
--    updating the exclusion list still fails here.
do $$
declare v_bad text;
begin
    select string_agg(table_name||'.'||column_name, ', ') into v_bad
      from information_schema.columns
     where table_schema = 'rbac'
       and table_name in ('api_keys_api', 'refresh_tokens_api')
       and column_name in ('key_hash', 'token_hash', 'replaced_by');
    if v_bad is not null then
        raise exception 'a credential column is exposed through an *_api view: %', v_bad;
    end if;
end $$;

-- 4. Escalation. bob is a member; grant_role must refuse him, and -- the half
--    worth writing down -- refuse him without leaving the row behind. A guard
--    that raises after the insert reads as working right up until someone
--    checks user_roles.
begin;
    set local role authenticated;
    set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
do $$
declare v_refused boolean := false;
begin
    begin
        perform rbac.grant_role('22222222-2222-2222-2222-222222222222', 'admin');
    exception when others then
        v_refused := true;
    end;
    if not v_refused then
        raise exception 'a member was allowed to call rbac.grant_role';
    end if;
end $$;
commit;

do $$
begin
    if exists (select 1 from rbac.user_roles
                where user_id = '22222222-2222-2222-2222-222222222222' and role = 'admin') then
        raise exception 'the refused grant_role left bob holding admin';
    end if;
end $$;

delete from rbac.api_keys       where id in (:'akey', :'bkey');
delete from rbac.refresh_tokens where id = :'atok';

\echo 'rbac/07: keys and tokens are visible only to their owner, carry no secret column, and a member cannot grant himself a role'
