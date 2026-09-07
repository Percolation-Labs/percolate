-- ACCOUNT RECOVERY, EXECUTED.
--
-- spec.md §5 carried this as "the same shape as `refresh_session` and
-- straightforward to add" for long enough that the shape was the only thing
-- anybody had checked. The shape is the easy half: a raw token, its hash
-- stored, existence/use/expiry in order. The half that is not in the shape is
-- what an anonymous caller can LEARN, and that is what this file is mostly
-- about.
--
-- Run as `web_anon` where an anonymous caller genuinely reaches the function,
-- because that is who redeems a reset: somebody who has forgotten their
-- password cannot be authenticated, which is the situation.
--
-- WHICH HALF IS ANONYMOUS IS THE POINT, and this file used to have it wrong in
-- the way that mattered. It ran BOTH halves as web_anon and called the
-- sequence "the happy path":
--
--     set local role web_anon;
--     perform rbac.request_password_reset('reset-me@example.com', 'the-emailed-token');
--     rbac.reset_password('the-emailed-token', ...)
--
-- That is not a happy path, it is the exploit. `request_password_reset` takes
-- the raw token as an ARGUMENT, so an anonymous caller that may run it picks
-- the secret and redeems it on the next line -- account takeover for any
-- address you know, with no email involved anywhere. The test executed it end
-- to end and asserted it worked.
--
-- The two functions are not the same kind of thing, and §3b's grant comment
-- used to say they were ("both are self-authenticating by token possession").
-- `reset_password` VERIFIES a token the server issued. `request_password_reset`
-- ISSUES the token the caller named, and only a trusted caller may do that.
-- §1 below now asserts the boundary rather than crossing it.
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
-- 1. AN ANONYMOUS CALLER CANNOT MINT A RESET TOKEN.
--
-- The whole credential is the argument, so "who may call this" IS the security
-- property -- there is nothing else in the function to get right. Asserted as
-- a refusal, because that is the only shape that can tell a closed door from
-- one nobody tried: the exploit is two statements long and the first one is
-- this call.
-- ---------------------------------------------------------------------
do $$
declare v_denied boolean := false; v_uid uuid;
begin
    set local role web_anon;
    begin
        perform rbac.request_password_reset('reset-me@example.com', 'attacker-chosen');
    exception when insufficient_privilege then
        v_denied := true;
    end;
    reset role;

    if not v_denied then
        raise exception
            'web_anon may call request_password_reset, which takes the raw token as an '
            'argument -- so an anonymous caller can mint a reset credential for any '
            'address and redeem it with reset_password on the next line. That is '
            'account takeover, not a reset flow.';
    end if;

    -- And the door it opened is shut with it: no token exists for that
    -- address, so the redemption half has nothing to consume even if the
    -- attacker guesses the spelling.
    select id into v_uid from rbac.users where email = 'reset-me@example.com';
    if exists (select 1 from rbac.password_reset_tokens
                where user_id = v_uid
                  and token_hash = encode(digest('attacker-chosen', 'sha256'), 'hex')) then
        raise exception 'the refused call still wrote a token row';
    end if;
    raise notice 'rbac/06: web_anon cannot mint a reset token -- the secret is the argument';
end $$;

-- ---------------------------------------------------------------------
-- 1b. ASKING ABOUT AN ADDRESS THAT DOES NOT EXIST IS INDISTINGUISHABLE FROM
--     ASKING ABOUT ONE THAT DOES.
--
-- The account-enumeration oracle is the failure mode here, and it does not look
-- like a failure: an endpoint that raises "no such user" works perfectly and
-- answers "is this person a customer" to anyone who asks. Asserted from both
-- sides -- the call succeeds, AND no row appears for the address that is not
-- there, so the timing and the table agree with the return value.
--
-- Run as the trusted caller now, which is who reaches this function at all.
-- The property is unchanged and still worth holding: the delivery service is
-- as untrusted with an answer as an anonymous request was, because whatever it
-- learns it can relay.
-- ---------------------------------------------------------------------
do $$
declare v_before bigint; v_after bigint;
begin
    select count(*) into v_before from rbac.password_reset_tokens;

    perform rbac.request_password_reset('nobody@example.com', 'raw-token-for-a-ghost');

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

    -- Minting is the trusted half: the delivery path generates the token,
    -- records its hash here and emails the raw one.
    perform rbac.request_password_reset('reset-me@example.com', 'the-emailed-token');

    -- Redeeming is the anonymous half, and stays anonymous -- the person
    -- holding the emailed link has no session and cannot get one.
    set local role web_anon;
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
    --
    -- The bucket is emptied first because this file asks for more resets for
    -- one address than the throttle allows a person to -- three in a burst,
    -- then one per three minutes. That is the throttle working, not a
    -- collision to design around, so the sections that are about something
    -- else say so and reset it rather than the limit being widened to fit the
    -- test. §5 below is where the throttle itself is asserted.
    delete from workflow.rate_limits where key = 'reset:reset-me@example.com';
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
    delete from workflow.rate_limits where key = 'reset:reset-me@example.com';
    perform rbac.request_password_reset('reset-me@example.com', 'first-token');
    perform rbac.request_password_reset('reset-me@example.com', 'second-token');

    select count(*) into v_live from rbac.password_reset_tokens
     where user_id = v_uid and used_at is null;
    if v_live <> 1 then
        raise exception 'expected exactly one live reset token, found %', v_live;
    end if;
    raise notice 'rbac/06: asking again spends the outstanding token';
end $$;

-- ---------------------------------------------------------------------
-- 5. AND THAT IS WHY IT IS THROTTLED.
--
-- §4 is the property an attacker uses: every request SPENDS the outstanding
-- token. So a form that relays reset requests without a limit is a denial of
-- service against the account holder -- hammer it and the link they were
-- actually sent is invalidated before they can click it, forever, and nothing
-- in the audit reads as an attack because every individual request is
-- legitimate.
--
-- Asserted the way rbac/03 asserts the login throttle: by exhausting it. The
-- bucket is consumed BEFORE rbac.users is consulted, so §1b's property is not
-- weakened -- a throttled unknown address and a throttled real one raise the
-- same thing.
-- ---------------------------------------------------------------------
do $$
declare v_throttled boolean := false;
begin
    delete from workflow.rate_limits where key = 'reset:throttle-me@example.com';
    for i in 1..8 loop
        begin
            perform rbac.request_password_reset('throttle-me@example.com', 'tok-' || i);
        exception when others then
            v_throttled := sqlerrm like '%too many password reset requests%';
            exit;
        end;
    end loop;
    if not v_throttled then
        raise exception
            'eight reset requests for one address in a row were all accepted -- each '
            'one spends the outstanding token, so an unthrottled endpoint keeps the '
            'account holder from ever using the link they were sent';
    end if;
    raise notice 'rbac/06: reset requests are throttled per address, and the throttle '
                 'is spent before the address is looked up';
end $$;

-- ---------------------------------------------------------------------
-- THE THROTTLE IS KEYED ON THE ADDRESS THIS FUNCTION LOOKS UP.
--
-- `request_password_reset` used to build its rate-limit key from
-- `lower(p_email)` while the lookup underneath is an exact match on a
-- case-sensitive column compared with `=`. Two addresses differing only in
-- case are two accounts everywhere else in this file, and they shared one
-- bucket here, so either could spend the other's allowance -- a denial of the
-- reset link, aimed at a specific account, by someone who only has to know a
-- different capitalisation of the address.
--
-- 67ef695 fixed it. Nothing tested it, and this file could not have: every
-- address in it is already lowercase, so `lower(p_email)` and `p_email` are
-- the same string and the test passes identically on the broken code.
--
-- Found by asking which claims have a definition that was committed after the
-- last commit to the file that checks them -- not by reading the diff, which
-- nobody had.
-- ---------------------------------------------------------------------
do $$
declare v_a text := 'Case-Me@example.com';
        v_b text := 'case-me@example.com';
        v_throttled boolean := false;
begin
    delete from workflow.rate_limits where key like 'reset:%ase-%e@example.com';

    -- Exhaust the bucket for the mixed-case spelling.
    for i in 1..8 loop
        begin
            perform rbac.request_password_reset(v_a, 'tok-a-' || i);
        exception when others then
            exit when sqlerrm like '%too many password reset requests%';
            raise;
        end;
    end loop;

    -- The other spelling must still have its own allowance. If the key folds
    -- case, this raises immediately and the account is unreachable.
    begin
        perform rbac.request_password_reset(v_b, 'tok-b');
    exception when others then
        v_throttled := sqlerrm like '%too many password reset requests%';
    end;

    if v_throttled then
        raise exception
            'exhausting the throttle for % also throttled %, so the rate-limit key '
            'folds case while the user lookup does not -- one address can lock '
            'another out of password reset', v_a, v_b;
    end if;
    raise notice 'rbac/06: the throttle key matches the lookup, so case-distinct '
                 'addresses hold separate allowances';
end $$;

rollback;
