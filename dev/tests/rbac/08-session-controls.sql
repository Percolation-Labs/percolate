-- The three controls a caller reaches for after a leak, none of which had a test.
--
-- rbac/07 covered who may READ keys and tokens. These are the writes: sign out
-- one device, sign out everywhere, and rotate the password. All three are
-- SECURITY DEFINER and all three scope themselves with rbac.current_user_id(),
-- which is the only thing standing between "sign me out" and "sign everyone
-- out". They were found by asking which functions an application role may
-- execute; nothing in the suite mentioned them.
--
-- revoke_session's refusal is worth naming because it does not look like one:
-- given somebody else's token id it updates zero rows and returns normally,
-- rather than raising. That is the right behaviour -- raising would confirm the
-- id exists to whoever guessed it -- but it means a broken scope would be
-- SILENT in both directions, and only a test that checks the victim's token
-- afterwards can tell the two apart.
--
-- PostgREST's shape again: one BEGIN/COMMIT per request, identity only from
-- the claim.

\set ON_ERROR_STOP on

\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set at1   'cccccccc-0000-4000-8000-00000000ad01'
\set at2   'cccccccc-0000-4000-8000-00000000ad02'
\set bt1   'cccccccc-0000-4000-8000-00000000ad03'
\set bt2   'cccccccc-0000-4000-8000-00000000ad04'

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

-- 0. Teardown scoped to this file's rows. The probe USER is deleted too, and
--    can be: it is created here, owns nothing, and so has none of the foreign
--    keys that make alice and bob permanent (see rbac/01).
delete from rbac.refresh_tokens where id in (:'at1', :'at2', :'bt1', :'bt2');
delete from rbac.users where email = 'pwprobe@test.com';

-- 1. Two live sessions for alice and two for bob. Bob needs the SECOND one:
--    the first is revoked in step 3, so without another the "did it reach
--    beyond the caller" check in step 4 would have nothing left to look at and
--    would pass no matter what revoke_all_sessions did.
insert into rbac.refresh_tokens (id, user_id, token_hash, device_label, expires_at)
values (:'at1', :'alice', 'hash-a1', 'alice laptop', now() + interval '30 days'),
       (:'at2', :'alice', 'hash-a2', 'alice phone',  now() + interval '30 days'),
       (:'bt1', :'bob',   'hash-b1', 'bob laptop',   now() + interval '30 days'),
       (:'bt2', :'bob',   'hash-b2', 'bob desktop',  now() + interval '30 days');

-- 2. bob revokes, by id, a session that is not his. It must return quietly and
--    change nothing -- the quiet part is deliberate, the nothing part is the
--    security property.
begin;
    set local role authenticated;
    set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
    select rbac.revoke_session('cccccccc-0000-4000-8000-00000000ad01');
commit;

do $$
begin
    if (select revoked_at from rbac.refresh_tokens
         where id = 'cccccccc-0000-4000-8000-00000000ad01') is not null then
        raise exception 'bob revoked one of alice''s sessions by id';
    end if;
end $$;

-- 3. His own, he may revoke. Without this the check above passes on a function
--    that revokes nothing for anybody.
begin;
    set local role authenticated;
    set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
    select rbac.revoke_session('cccccccc-0000-4000-8000-00000000ad03');
commit;

do $$
begin
    if (select revoked_at from rbac.refresh_tokens
         where id = 'cccccccc-0000-4000-8000-00000000ad03') is null then
        raise exception 'bob could not revoke his own session';
    end if;
end $$;

-- 4. Sign out everywhere: alice's two go, and nobody else's do. The second
--    half is the whole point -- `where user_id = current_user_id()` and `where
--    true` are one clause apart, and both pass a test that only counts alice's.
begin;
    set local role authenticated;
    set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
    select rbac.revoke_all_sessions();
commit;

do $$
declare v_live int;
begin
    select count(*) into v_live from rbac.refresh_tokens
     where id in ('cccccccc-0000-4000-8000-00000000ad01',
                  'cccccccc-0000-4000-8000-00000000ad02')
       and revoked_at is null;
    if v_live <> 0 then
        raise exception 'revoke_all_sessions left % of alice''s sessions live', v_live;
    end if;

    -- Bob's second session was live before the call and must still be. This is
    -- the assertion that separates `where user_id = current_user_id()` from
    -- `where true`; counting only alice's rows passes on both.
    if (select revoked_at from rbac.refresh_tokens
         where id = 'cccccccc-0000-4000-8000-00000000ad04') is not null then
        raise exception 'alice''s revoke_all_sessions revoked one of bob''s';
    end if;
end $$;

-- 5. Password rotation, on a user created for it. The old password is required,
--    and -- the half a refusal test usually forgets -- a refused attempt must
--    leave the old one working, not half-applied.
select rbac.create_user_with_password('pwprobe@test.com', 'original-pw');

do $$
declare v_id uuid; v_refused boolean := false;
begin
    select id into v_id from rbac.users where email = 'pwprobe@test.com';

    -- Signup lands in `pending_verification`, and rbac.verify_password matches
    -- only `active` rows -- so change_password cannot succeed for an account
    -- that has not been verified, whatever password it is given. That coupling
    -- is not written down anywhere else, and it is the reason this fixture
    -- needs the line below rather than being able to use a fresh signup.
    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_id)::text, true);
    begin
        perform rbac.change_password('original-pw', 'rotated-pw');
        raise exception 'an unverified account rotated its password';
    exception when others then
        if sqlerrm = 'an unverified account rotated its password' then raise; end if;
    end;
    if rbac.verify_password('pwprobe@test.com', 'rotated-pw') is not null then
        raise exception 'the unverified rotation took effect anyway';
    end if;

    update rbac.users set status = 'active' where id = v_id;

    -- Wrong current password.
    begin
        perform set_config('request.jwt.claims',
                           json_build_object('sub', v_id)::text, true);
        perform rbac.change_password('not-the-password', 'attacker-pw');
    exception when others then
        v_refused := true;
    end;
    if not v_refused then
        raise exception 'change_password accepted the wrong current password';
    end if;
    if rbac.verify_password('pwprobe@test.com', 'original-pw') is null then
        raise exception 'a refused change_password still disturbed the password';
    end if;
    if rbac.verify_password('pwprobe@test.com', 'attacker-pw') is not null then
        raise exception 'the refused new password was set anyway';
    end if;

    -- Right current password.
    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_id)::text, true);
    perform rbac.change_password('original-pw', 'rotated-pw');

    if rbac.verify_password('pwprobe@test.com', 'rotated-pw') is null then
        raise exception 'the rotated password does not work';
    end if;
    if rbac.verify_password('pwprobe@test.com', 'original-pw') is not null then
        raise exception 'the OLD password still works after a rotation';
    end if;
end $$;

delete from rbac.refresh_tokens where id in (:'at1', :'at2', :'bt1', :'bt2');
delete from rbac.users where email = 'pwprobe@test.com';

\echo 'rbac/08: a caller signs out one device or all of them and reaches nobody else, and a password rotation needs the old one'
