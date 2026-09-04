-- THE BRANCH THAT ANNOUNCED WHAT IT HAD NOT DONE.
--
-- spec.md §2 lists "refresh-token theft detection" as one of the seven things
-- pushed into Postgres: presenting an already-rotated refresh token revokes the
-- whole chain. `rbac.refresh_session` has had that branch since the schema was
-- written, four lines that revoke every live session and then raise `refresh
-- token reuse detected; all sessions revoked`.
--
-- Nothing had ever entered it, and it did two things wrong -- neither visible
-- from outside, because the caller (spec.md §4.3) turns every error from this
-- function into the same 401:
--
--   * `where user_id = v_row.user_id` inside a function declared
--     `returns table(user_id uuid, ...)` is `column reference "user_id" is
--     ambiguous`, raised at execution. So the statement that revokes the chain
--     never ran at all, and what came back was a parse error wearing a
--     security control's clothes.
--
--   * and had it run, `raise exception` would have rolled it back. That is the
--     failure §5 of the schema records for `attempt_login` -- the throttle and
--     the audit row undone by the refusal they exist to record -- reappearing
--     in the one other place in this file that writes before it refuses. The
--     comment thirty lines below this branch had already reasoned it out for
--     the account-status case and chose to refuse WITHOUT writing; this branch
--     has to write, so it is the raise that had to go.
--
-- Measured before the fix: rotate A into A2, then present A again ->
-- `column reference "user_id" is ambiguous`, both remaining sessions still
-- live, nothing in auth_events. The message claimed all sessions were revoked
-- and none were.
--
-- So this file is written the way a theft is: one credential, presented twice.
-- The assertion that matters is not that the second presentation fails -- it
-- always did, for the wrong reason -- but what is TRUE about the database
-- afterwards.
--
-- No BEGIN/COMMIT-per-request simulation here (rbac/01 and rbac/08 do that):
-- every call below is a SECURITY DEFINER function that resolves nothing from
-- the caller's identity, which is the point of a credential that authenticates
-- by possession.
\set ON_ERROR_STOP on

begin;

-- Two accounts. The second one exists for section 4 alone: a revocation scoped
-- with `where user_id = ...` and one written `where revoked_at is null` are one
-- clause apart, and every assertion about the victim passes under both.
select rbac.create_user_with_password('rotation-a@test.com', 'a passphrase for a')  as a_id \gset
select rbac.create_user_with_password('rotation-b@test.com', 'a passphrase for b')  as b_id \gset
update rbac.users set status = 'active'
 where email in ('rotation-a@test.com', 'rotation-b@test.com');

select rbac.issue_refresh_token(:'a_id', 'a laptop',  'raw-a-laptop');
select rbac.issue_refresh_token(:'a_id', 'a phone',   'raw-a-phone');
select rbac.issue_refresh_token(:'b_id', 'b laptop',  'raw-b-laptop');

-- ---------------------------------------------------------------------
-- 1. ROTATION ITSELF, which nothing asserted either.
--
-- The old token dies, a new one lives, and the two are linked by
-- `replaced_by` -- which is the column the reuse branch below is only
-- meaningful because of. A rotation that revoked without linking would leave
-- every later assertion here passing over an unrelated pair of rows.
-- ---------------------------------------------------------------------
do $$
declare v_user uuid; v_new uuid; v_old rbac.refresh_tokens;
begin
    select r.user_id, r.new_refresh_token_id into v_user, v_new
      from rbac.refresh_session('raw-a-laptop', 'raw-a-laptop-2') r;

    if v_user is null then
        raise exception 'a live refresh token could not be rotated';
    end if;
    if v_user is distinct from (select id from rbac.users where email = 'rotation-a@test.com') then
        raise exception 'rotation returned the wrong user';
    end if;

    select * into v_old from rbac.refresh_tokens
     where token_hash = encode(digest('raw-a-laptop', 'sha256'), 'hex');
    if v_old.revoked_at is null then
        raise exception 'the rotated-away token is still live';
    end if;
    if v_old.replaced_by is distinct from v_new then
        raise exception 'the rotation chain is not recorded: replaced_by is %, the new token is %',
                        v_old.replaced_by, v_new;
    end if;
    if (select revoked_at from rbac.refresh_tokens where id = v_new) is not null then
        raise exception 'the newly issued token arrived revoked';
    end if;
    -- The device label follows the chain: a session list that renames every
    -- device to null on the first refresh is a worse answer than no list.
    if (select device_label from rbac.refresh_tokens where id = v_new) is distinct from 'a laptop' then
        raise exception 'the rotation lost the device label';
    end if;

    raise notice 'rbac/09: a live token rotates, the old one dies, and replaced_by links them';
end $$;

-- ---------------------------------------------------------------------
-- 2. THE STOLEN TOKEN, PRESENTED AFTER IT WAS ROTATED.
--
-- Four things have to be true at once, and only the first was ever checked by
-- anything: the call refuses, it refuses WITHOUT RAISING (a raise takes the
-- revocation with it), every live session for that user is gone, and the audit
-- says so. The third is the security control; the second is what makes the
-- third survive the call.
-- ---------------------------------------------------------------------
do $$
declare v_rows int; v_live int; v_events int; v_raised text := null;
begin
    begin
        select count(*) into v_rows
          from rbac.refresh_session('raw-a-laptop', 'raw-a-laptop-3');
    exception when others then
        v_raised := sqlerrm;
    end;

    if v_raised is not null then
        raise exception
            'reuse detection raised (%) instead of returning no row -- a raise '
            'aborts the transaction the revocation is written in, so the '
            'sessions this branch exists to end stay live', v_raised;
    end if;
    if v_rows <> 0 then
        raise exception 'a rotated-away token was accepted and rotated again (% row(s))', v_rows;
    end if;

    -- No new credential was minted on the way out.
    if exists (select 1 from rbac.refresh_tokens
                where token_hash = encode(digest('raw-a-laptop-3', 'sha256'), 'hex')) then
        raise exception 'reuse detection still issued the token it was asked for';
    end if;

    select count(*) into v_live from rbac.refresh_tokens
     where user_id = (select id from rbac.users where email = 'rotation-a@test.com')
       and revoked_at is null;
    if v_live <> 0 then
        raise exception
            'reuse was detected and % of that user''s sessions are still live -- '
            'the phone was never presented and is exactly what a stolen laptop '
            'token is used to keep', v_live;
    end if;

    select count(*) into v_events from rbac.auth_events
     where user_id = (select id from rbac.users where email = 'rotation-a@test.com')
       and event_type = 'refresh_reuse_detected';
    if v_events <> 1 then
        raise exception
            'the audit holds % refresh_reuse_detected rows -- an operator asked '
            '"why is everyone signed out" has nothing to read', v_events;
    end if;

    raise notice 'rbac/09: a token presented after it was rotated ends every session '
                 'for that user, is audited, and refuses without raising the '
                 'revocation away';
end $$;

-- ---------------------------------------------------------------------
-- 3. AND STOPS THERE.
--
-- `where user_id = v_row.user_id and revoked_at is null` and `where revoked_at
-- is null` differ by one clause, and section 2 passes under both. This is the
-- clause.
-- ---------------------------------------------------------------------
do $$
begin
    if (select revoked_at from rbac.refresh_tokens
         where token_hash = encode(digest('raw-b-laptop', 'sha256'), 'hex')) is not null then
        raise exception
            'one user''s reuse detection signed a different user out';
    end if;
    raise notice 'rbac/09: the revocation reaches that user''s sessions and nobody else''s';
end $$;

-- ---------------------------------------------------------------------
-- 4. THE THREE REFUSALS THAT ARE NOT A THEFT still raise, and write nothing.
--
-- The asymmetry is deliberate and worth pinning, because "refuse by raising"
-- and "refuse by returning no row" look like an inconsistency until you ask
-- what each branch has to leave behind. Only reuse detection writes; the other
-- three have nothing to lose to a rollback, and an exception is a clearer
-- answer for a caller than an empty result.
-- ---------------------------------------------------------------------
do $$
declare v_ok boolean;
begin
    -- Unknown token.
    v_ok := false;
    begin perform rbac.refresh_session('never-issued', 'whatever');
    exception when others then v_ok := true; end;
    if not v_ok then raise exception 'an unissued refresh token was accepted'; end if;

    -- Expired, and NOT revoked -- otherwise the reuse branch answers first and
    -- this section tests that one twice.
    insert into rbac.refresh_tokens (user_id, token_hash, device_label, expires_at)
    values ((select id from rbac.users where email = 'rotation-b@test.com'),
            encode(digest('raw-b-expired', 'sha256'), 'hex'), 'b old tablet',
            now() - interval '1 day');
    v_ok := false;
    begin perform rbac.refresh_session('raw-b-expired', 'raw-b-expired-2');
    exception when others then v_ok := true; end;
    if not v_ok then raise exception 'an expired refresh token was rotated'; end if;

    -- A suspended account, which §3 of the schema refuses rather than revokes:
    -- re-activating restores the sessions that were legitimately open.
    update rbac.users set status = 'disabled' where email = 'rotation-b@test.com';
    v_ok := false;
    begin perform rbac.refresh_session('raw-b-laptop', 'raw-b-laptop-2');
    exception when others then v_ok := true; end;
    if not v_ok then raise exception 'a disabled account rotated a refresh token'; end if;
    if (select revoked_at from rbac.refresh_tokens
         where token_hash = encode(digest('raw-b-laptop', 'sha256'), 'hex')) is not null then
        raise exception
            'refusing a suspended account revoked its sessions -- suspension is '
            'reversible and revocation is not';
    end if;

    raise notice 'rbac/09: unknown, expired and suspended still refuse by raising, '
                 'and the suspension leaves the session intact to come back to';
end $$;

rollback;
