-- THE AUTH PATH, EXECUTED.
--
-- `surface.sql` reported `rbac.verify_api_key` and the login entry points as
-- present, and present is all anybody knew: nothing in this suite had ever
-- called them. A cross-reference of every capability surface.sql declares
-- against every name the tests mention found this file's subject -- signup,
-- login, throttling, refresh, revocation and API keys -- entirely unexercised,
-- in the one subsystem where a defect is a breach rather than a bug.
--
-- Everything here runs as the role that would really make the call: `web_anon`
-- for the public entry points, because "the function works" and "the caller
-- who must reach it may call it" are different questions and only the second
-- one is deployment truth. That distinction is what this file exists to pin --
-- `attempt_login` is deliberately NOT granted to web_anon, and reading the
-- grant table alone would call that a broken login.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- 1. Signup and login, as an anonymous caller.
--
-- `login()` is SECURITY DEFINER and calls `attempt_login()` and
-- `issue_refresh_token()`, neither of which web_anon may call directly. That
-- is the design: one granted entry point, the helpers reachable only through
-- it. Asserted from both ends, because a grant that is too NARROW breaks the
-- product and a grant that is too WIDE is the breach.
-- ---------------------------------------------------------------------
do $$
declare
    v_user  uuid;
    v_row   record;
    v_n     int;
begin
    set local role web_anon;

    v_user := rbac.create_user_with_password('auth-probe@x.test', 'correct horse battery');
    if v_user is null then
        raise exception 'signup returned no user';
    end if;

    -- THE ACCOUNT SIGNUP MAKES CANNOT LOG IN. create_user_with_password
    -- inserts `pending_verification`, verify_password requires `active`, and
    -- this collection ships nothing between them -- no token table, no
    -- verify_email(), and no `send_verification_email` workflow (that name
    -- exists only in spec.md's example). Asserted rather than worked around
    -- silently, so building verification updates this block instead of
    -- surprising whoever writes it. schema.sql §1a carries the argument.
    select count(*) into v_n
      from rbac.login('auth-probe@x.test', 'correct horse battery',
                      'probe-device', 'raw-refresh-token-0');
    if v_n <> 0 then
        raise exception
            'a pending_verification account logged in -- if verification was built, '
            'this assertion is what needs updating';
    end if;

    -- ...and the audit says WHY, while the caller is still told nothing that
    -- distinguishes a wrong password from an unverified account.
    reset role;
    if (select detail->>'reason' from rbac.auth_events
         where detail->>'email' = 'auth-probe@x.test'
         order by id desc limit 1) is distinct from 'status_pending_verification' then
        raise exception 'the audit did not record why the login failed';
    end if;

    set local role app_owner;
    update rbac.users set status = 'active' where id = v_user;
    set local role web_anon;

    select * into v_row from rbac.login('auth-probe@x.test', 'correct horse battery',
                                        'probe-device', 'raw-refresh-token-1');
    if v_row.user_id is distinct from v_user then
        raise exception 'login returned a different user than signup created';
    end if;
    if v_row.refresh_token_id is null then
        raise exception 'login issued no refresh token';
    end if;

    -- The helpers are NOT reachable directly, and that is the point of the
    -- definer wrapper rather than an accident of ordering.
    begin
        perform rbac.attempt_login('auth-probe@x.test', 'correct horse battery');
        raise exception 'web_anon can call attempt_login directly';
    exception when insufficient_privilege then null;
    end;
    begin
        perform rbac.verify_password('auth-probe@x.test', 'correct horse battery');
        raise exception 'web_anon can call verify_password directly';
    exception when insufficient_privilege then null;
    end;

    reset role;
    raise notice 'rbac/03: signup makes an account that cannot log in until something activates it, the audit says so, and the helpers stay unreachable';
end $$;

-- ---------------------------------------------------------------------
-- 2. A WRONG PASSWORD IS A RESULT, AND THE DEFENCES SURVIVE IT.
--
-- login() used to raise `invalid credentials` one statement after consuming a
-- rate-limit token and writing an auth_events row -- and an exception rolls
-- back the transaction that wrote them. So the throttle only ever decremented
-- on SUCCESS, and the audit could hold `login_success` and never
-- `login_failed`. Measured before the fix: twelve wrong passwords produced no
-- throttle, no audit rows, and no bucket row at all.
--
-- Both halves are asserted here, because each is invisible on its own: a
-- throttle nobody counts against looks identical to a throttle nobody has hit.
-- ---------------------------------------------------------------------
do $$
declare
    v_rows      int;
    v_failed    int;
    v_throttled boolean := false;
    v_i         int;
    v_tokens    numeric;
begin
    set local role web_anon;

    select count(*) into v_rows
      from rbac.login('auth-probe@x.test', 'wrong', 'd', 'raw-token-x');
    if v_rows <> 0 then
        raise exception 'a wrong password returned a session';
    end if;

    reset role;
    select count(*) into v_failed from rbac.auth_events
     where event_type = 'login_failed' and detail->>'email' = 'auth-probe@x.test';
    if v_failed < 1 then
        raise exception
            'a failed login was not recorded -- if login() raises again, the audit row '
            'it writes is rolled back by the exception that follows it';
    end if;
    if (select detail->>'reason' from rbac.auth_events
         where event_type = 'login_failed' and detail->>'email' = 'auth-probe@x.test'
         order by id desc limit 1) is distinct from 'bad_password' then
        raise exception 'the audit did not say why the password attempt failed';
    end if;

    -- Exhaust the bucket. Capacity is five and one is already spent, so the
    -- refusal must arrive within the next few attempts -- and it must be a
    -- RAISE, because a caller has to tell 429 from 401.
    set local role web_anon;
    for v_i in 1..8 loop
        begin
            perform rbac.login('auth-probe@x.test', 'wrong', 'd', 'raw-token-' || v_i);
        exception when insufficient_privilege then raise;
        when others then
            if sqlerrm like '%too many login attempts%' then v_throttled := true; end if;
        end;
    end loop;
    reset role;

    if not v_throttled then
        raise exception
            'the login throttle never fired -- every failed attempt is rolling back the '
            'token it consumed, which makes login() an unrate-limited password oracle';
    end if;
    select tokens into v_tokens from workflow.rate_limits
     where key = 'login:auth-probe@x.test';
    if v_tokens is null then
        raise exception 'the rate-limit bucket does not exist after nine failed attempts';
    end if;
    if v_tokens > 0 then
        raise exception 'the bucket still holds % token(s) after being throttled', v_tokens;
    end if;

    raise notice 'rbac/03: a wrong password returns no session, is audited with a reason, and spends a token that survives the failure';
end $$;

-- ---------------------------------------------------------------------
-- 3. API keys: the self-authenticating entry point.
--
-- Granted to web_anon deliberately -- possession of the key IS the
-- authentication, so there is no caller to authenticate first. Six cases,
-- because the interesting ones are the inputs that are not keys at all: a
-- null or an empty string must match NOTHING rather than matching a row whose
-- hash happens to be of null.
-- ---------------------------------------------------------------------
do $$
declare
    v_user uuid;
    v_key  uuid;
    v_n    int;
    r      record;
begin
    set local role app_owner;
    select id into v_user from rbac.users where email = 'auth-probe@x.test';
    insert into rbac.api_keys (user_id, label, key_hash, scopes)
    values (v_user, 'probe key', encode(digest('sk-probe-raw-key', 'sha256'), 'hex'),
            array['workflow:trigger'])
    returning id into v_key;
    reset role;

    set local role web_anon;
    select * into r from rbac.verify_api_key('sk-probe-raw-key');
    if r.user_id is distinct from v_user then
        raise exception 'a valid key did not resolve to its user';
    end if;
    if not (r.scopes @> array['workflow:trigger']) then
        raise exception 'the key resolved without its scopes: %', r.scopes;
    end if;

    for r in select * from (values ('sk-nope'), (null), (''), ('SK-PROBE-RAW-KEY')) t(k)
    loop
        select count(*) into v_n from rbac.verify_api_key(r.k);
        if v_n <> 0 then
            raise exception 'verify_api_key accepted %L', coalesce(r.k, '<null>');
        end if;
    end loop;
    reset role;

    -- Possession is dated: last_used_at is what makes an unused key findable.
    set local role app_owner;
    if (select last_used_at from rbac.api_keys where id = v_key) is null then
        raise exception 'a verified key did not record last_used_at';
    end if;

    -- Revocation is immediate and needs no cache to expire.
    update rbac.api_keys set revoked_at = now() where id = v_key;
    reset role;
    set local role web_anon;
    select count(*) into v_n from rbac.verify_api_key('sk-probe-raw-key');
    if v_n <> 0 then
        raise exception 'a revoked key still verifies';
    end if;
    reset role;

    raise notice 'rbac/03: a key verifies once, dates itself, and stops the moment it is revoked';
end $$;

-- ---------------------------------------------------------------------
-- 4. AN API KEY NEVER EXPIRES, and that is worth asserting rather than
--    discovering.
--
-- `refresh_tokens` carries `expires_at` and is checked against it;
-- `api_keys` has no such column, so a key is valid until somebody revokes it.
-- That may well be the right design -- a machine credential with no rotation
-- story is a machine credential nobody rotates -- but it is a DECISION, and an
-- absence and a decision look identical in a schema. Pinned here so that
-- adding expiry is a deliberate act that updates this assertion.
-- ---------------------------------------------------------------------
do $$
begin
    if exists (select 1 from information_schema.columns
                where table_schema = 'rbac' and table_name = 'api_keys'
                  and column_name in ('expires_at', 'valid_until')) then
        raise exception
            'api_keys grew an expiry column -- verify_api_key must check it, and this '
            'assertion should become that check rather than being deleted';
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema = 'rbac' and table_name = 'refresh_tokens'
                      and column_name = 'expires_at') then
        raise exception 'refresh_tokens lost its expiry -- sessions would never end';
    end if;
    raise notice 'rbac/03: an API key ends by revocation only, while a session ends by clock -- deliberate, and now asserted';
end $$;

-- ---------------------------------------------------------------------
-- 5. DISABLING AN ACCOUNT DISABLES EVERY WAY INTO IT.
--
-- `rbac.users.status` was enforced in exactly one function -- verify_password.
-- So `update rbac.users set status = 'disabled'`, which is the only lever the
-- column offers and the first thing anyone reaches for when an account is
-- compromised or a person leaves, stopped password logins and left the other
-- two credential paths wide open: every API key that person held kept
-- verifying, and every refresh token they had kept minting fresh 30-day
-- sessions -- rotation issues a NEW token each time, so a session opened
-- before the disable never expires on its own.
--
-- Three doors, one lock, asserted here rather than in three places, because
-- the failure was never in any single function -- it was that "status" meant
-- something in one of them and nothing in the others. A fourth credential path
-- added later belongs in this block.
-- ---------------------------------------------------------------------
do $$
declare
    v_uid uuid;
    v_n   int;
    v_refused boolean := false;
begin
    v_uid := rbac.create_user_with_password('leaver@example.com', 'a long passphrase');
    update rbac.users set status = 'active' where id = v_uid;

    insert into rbac.api_keys (user_id, label, key_hash)
    values (v_uid, 'their laptop', encode(digest('sk-leaver-key', 'sha256'), 'hex'));
    perform rbac.issue_refresh_token(v_uid, 'their laptop', 'leaver-session');

    -- All three work while the account is active, so the assertions below are
    -- about the disable and not about a fixture that never worked.
    if rbac.verify_password('leaver@example.com', 'a long passphrase') is null then
        raise exception 'the fixture cannot log in even while active';
    end if;
    select count(*) into v_n from rbac.verify_api_key('sk-leaver-key');
    if v_n <> 1 then
        raise exception 'the fixture key does not verify even while active';
    end if;

    update rbac.users set status = 'disabled' where id = v_uid;

    if rbac.verify_password('leaver@example.com', 'a long passphrase') is not null then
        raise exception 'a disabled account can still log in with its password';
    end if;

    select count(*) into v_n from rbac.verify_api_key('sk-leaver-key');
    if v_n <> 0 then
        raise exception
            'a disabled account''s API key still verifies -- revoking every key one by '
            'one is not what an operator thinks they are doing when they disable a user';
    end if;

    begin
        perform rbac.refresh_session('leaver-session', 'leaver-session-2');
    exception when others then
        v_refused := sqlerrm like '%not active%';
    end;
    if not v_refused then
        raise exception
            'a disabled account''s refresh token still rotates -- every rotation issues '
            'a new 30-day token, so the session outlives the disable indefinitely';
    end if;

    -- Re-activating restores what was legitimately open, which is the correct
    -- reading of a suspension: refresh_session REFUSES rather than revoking,
    -- deliberately (a RAISE would roll a revocation back anyway -- see §5 of
    -- user-rbac/schema.sql). Ending sessions for good is revoke_all_sessions,
    -- and it is a separate act.
    update rbac.users set status = 'active' where id = v_uid;
    if (select count(*) from rbac.verify_api_key('sk-leaver-key')) <> 1 then
        raise exception 'reactivating the account did not restore its key';
    end if;

    raise notice 'rbac/03: disabling an account closes the password, API-key and '
                 'refresh-token doors together, and reactivating reopens them';
end $$;

-- ---------------------------------------------------------------------
-- 6. A TOKEN WHOSE `sub` IS NOT A UUID IS ANONYMOUS, NOT A 500.
--
-- `sub` being a uuid is this collection's convention, not the world's:
-- rbac.login returns rbac.users.id and the install guide mints a token around
-- it. spec.md names SSO as a seam, and no external identity provider issues
-- uuid subjects -- Auth0 writes `auth0|abc123`, Google a decimal string, and an
-- email is common.
--
-- current_user_id() used to cast unconditionally, so the first such token would
-- have raised `invalid input syntax for type uuid` from wherever the function
-- was called -- inside RLS policies and inside triggers. Reproduced before the
-- fix: an ordinary upload failed with the error naming workflow.set_run_owner,
-- a trigger three subsystems away from the token that was actually wrong.
--
-- Asserted as NULL rather than as an error, and both halves matter: NULL is the
-- same answer the function gives for no token at all, and it is fail-closed,
-- because every policy in this collection compares against it and `owner_id =
-- null` is NULL rather than true.
-- ---------------------------------------------------------------------
do $$
declare v_case text; v_got uuid;
begin
    set local role authenticated;
    foreach v_case in array array['auth0|abc123', 'someone@example.com', '',
                                  '1e0f2b8a-0000-4000-8000-00000000000', 'null']
    loop
        perform set_config('request.jwt.claims',
                           json_build_object('sub', v_case)::text, true);
        v_got := rbac.current_user_id();
        if v_got is not null then
            raise exception
                'a sub of %L resolved to a user id (%). Anything that is not a uuid is '
                'not one of our users, and treating it as one is worse than refusing it.',
                v_case, v_got;
        end if;
    end loop;

    -- And a real one still resolves, so the guard is a filter and not a wall.
    perform set_config('request.jwt.claims',
        '{"sub":"1e0f2b8a-0000-4000-8000-000000000001"}', true);
    if rbac.current_user_id() <> '1e0f2b8a-0000-4000-8000-000000000001'::uuid then
        raise exception 'a valid uuid sub no longer resolves';
    end if;
    reset role;

    raise notice 'rbac/03: a non-uuid sub reads as anonymous rather than raising a cast '
                 'error from inside whichever policy or trigger asked';
end $$;

rollback;
