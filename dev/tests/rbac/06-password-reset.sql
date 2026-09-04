-- ACCOUNT RECOVERY, EXECUTED.
--
-- spec.md §5 carried this as "the same shape as `refresh_session` and
-- straightforward to add" for long enough that the shape was the only thing
-- anybody had checked. The shape is the easy half: a raw token, its hash
-- stored, existence/use/expiry in order. The half that is not in the shape is
-- what an anonymous caller can LEARN, and that is what this file is mostly
-- about.
--
-- Run as `web_anon` throughout, because that is who reaches these: somebody who
-- has forgotten their password cannot be authenticated, which is the situation.
\set ON_ERROR_STOP on

begin;

select rbac.create_user_with_password('reset-me@example.com', 'the old passphrase');
-- Activated, because signup does not: create_user_with_password inserts
-- `pending_verification` and `verify_password` requires `active`, so without
-- this the assertions below would read "the new password does not work" for a
-- reason that has nothing to do with the reset. Reset itself does NOT check
-- status -- recovering a password and verifying an address are separate
-- concerns, and an account that resets but still cannot log in is the correct
-- outcome for one that was never verified.
update rbac.users set status = 'active' where email = 'reset-me@example.com';

-- ---------------------------------------------------------------------
-- 1. ASKING ABOUT AN ADDRESS THAT DOES NOT EXIST IS INDISTINGUISHABLE FROM
--    ASKING ABOUT ONE THAT DOES.
--
-- The account-enumeration oracle is the failure mode here, and it does not look
-- like a failure: an endpoint that raises "no such user" works perfectly and
-- answers "is this person a customer" to anyone who asks. Asserted from both
-- sides -- the call succeeds, AND no row appears for the address that is not
-- there, so the timing and the table agree with the return value.
-- ---------------------------------------------------------------------
do $$
declare v_before bigint; v_after bigint;
begin
    select count(*) into v_before from rbac.password_reset_tokens;

    set local role web_anon;
    perform rbac.request_password_reset('nobody@example.com', 'raw-token-for-a-ghost');
    reset role;

    select count(*) into v_after from rbac.password_reset_tokens;
    if v_after <> v_before then
        raise exception 'a reset for an unknown address wrote % row(s)', v_after - v_before;
    end if;
    raise notice 'rbac/06: an unknown address is accepted and recorded nowhere -- no enumeration oracle';
end $$;

-- ---------------------------------------------------------------------
-- 2. The happy path, and the session revocation that comes with it.
--
-- Revoking every refresh token is not an extra: the reason to reset is usually
-- that somebody else may hold the old credential, and leaving their sessions
-- alive resets nothing.
-- ---------------------------------------------------------------------
do $$
declare v_uid uuid; v_live int;
begin
    select id into v_uid from rbac.users where email = 'reset-me@example.com';
    perform rbac.issue_refresh_token(v_uid, 'a device they are still signed in on', 'live-session-token');

    set local role web_anon;
    perform rbac.request_password_reset('reset-me@example.com', 'the-emailed-token');
    if rbac.reset_password('the-emailed-token', 'the new passphrase') <> v_uid then
        raise exception 'reset_password returned the wrong user';
    end if;

    reset role;

    -- Checked as the owner, NOT as web_anon: `verify_password` is deliberately
    -- not granted to it -- the anonymous path to a password check is `login`,
    -- and the helper behind it stays unreachable. This is an assertion about
    -- state, not about what an anonymous caller may do, so it belongs outside
    -- the block above. Getting that wrong is what this file's header calls the
    -- difference between "the function works" and "the caller who must reach it
    -- may call it".
    if rbac.verify_password('reset-me@example.com', 'the new passphrase') is null then
        raise exception 'the new password does not work';
    end if;
    if rbac.verify_password('reset-me@example.com', 'the old passphrase') is not null then
        raise exception 'THE OLD PASSWORD STILL WORKS -- the reset reset nothing';
    end if;

    select count(*) into v_live from rbac.refresh_tokens
     where user_id = v_uid and revoked_at is null;
    if v_live <> 0 then
        raise exception 'a reset left % session(s) alive', v_live;
    end if;
    raise notice 'rbac/06: the password changes, the old one stops working, and every session ends';
end $$;

-- ---------------------------------------------------------------------
-- 3. Single use, and expiry. Both are refusals, so both are asserted by
--    catching them -- a test that only checks the happy path cannot tell a
--    token that expires from one that never did.
-- ---------------------------------------------------------------------
do $$
declare v_uid uuid; v_reused boolean := false; v_expired boolean := false;
begin
    select id into v_uid from rbac.users where email = 'reset-me@example.com';

    set local role web_anon;
    begin
        perform rbac.reset_password('the-emailed-token', 'a third passphrase');
    exception when others then
        v_reused := sqlerrm like '%already used%';
    end;
    reset role;
    if not v_reused then
        raise exception 'a spent reset token was accepted a second time';
    end if;

    -- Expiry, by issuing one that is already past. A test that waits for a real
    -- TTL is a test nobody runs.
    perform rbac.request_password_reset('reset-me@example.com', 'a-stale-token',
                                        interval '-1 second');
    set local role web_anon;
    begin
        perform rbac.reset_password('a-stale-token', 'a fourth passphrase');
    exception when others then
        v_expired := sqlerrm like '%expired%';
    end;
    reset role;
    if not v_expired then
        raise exception 'an expired reset token was accepted';
    end if;

    raise notice 'rbac/06: a reset token works once, and not after it expires';
end $$;

-- ---------------------------------------------------------------------
-- 4. Requesting again spends the outstanding one.
--
-- Two live tokens are two live chances for the one that leaked, and the person
-- who just asked is holding the newest.
-- ---------------------------------------------------------------------
do $$
declare v_uid uuid; v_live int;
begin
    select id into v_uid from rbac.users where email = 'reset-me@example.com';
    perform rbac.request_password_reset('reset-me@example.com', 'first-token');
    perform rbac.request_password_reset('reset-me@example.com', 'second-token');

    select count(*) into v_live from rbac.password_reset_tokens
     where user_id = v_uid and used_at is null;
    if v_live <> 1 then
        raise exception 'expected exactly one live reset token, found %', v_live;
    end if;
    raise notice 'rbac/06: asking again spends the outstanding token';
end $$;

rollback;
