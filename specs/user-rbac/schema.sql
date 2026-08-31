-- ============================================================
-- User management + RBAC — maximal Postgres pushdown v1.0
-- Philosophy: same as the workflow engine. Postgres is the
-- source of truth for identity, permissions, and sessions.
-- FastAPI is a thin proxy that mints/forwards JWTs and handles
-- the handful of things that structurally cannot live in SQL
-- (OAuth token exchange, email sending, TOTP).
-- ============================================================

create extension if not exists pgcrypto;   -- bcrypt via crypt()/gen_salt()
-- create extension if not exists pgjwt;   -- optional: mint JWTs in SQL (see §7 callout)

-- ------------------------------------------------------------
-- 1. Users
-- ------------------------------------------------------------
create table users (
    id            uuid primary key default gen_random_uuid(),
    email         text not null unique,
    password_hash text,                 -- null for API-key-only / SSO-only accounts
    status        text not null default 'active'
                      check (status in ('active','disabled','pending_verification')),
    mfa_secret    text,                 -- TOTP secret, set only after MFA enrollment
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

-- Password verification pushed to pgcrypto -- no password ever leaves
-- Postgres in plaintext, and hashing cost (bcrypt work factor) is
-- tunable independent of the app layer.
create or replace function set_password(p_user_id uuid, p_plain text)
returns void as $$
    update users
    set password_hash = crypt(p_plain, gen_salt('bf', 12)), updated_at = now()
    where id = p_user_id;
$$ language sql;

create or replace function verify_password(p_email text, p_plain text)
returns uuid as $$
    select id from users
    where email = p_email
      and status = 'active'
      and password_hash = crypt(p_plain, password_hash);
$$ language sql security definer;
-- security definer: callable by an unprivileged 'api_user' role via
-- PostgREST RPC without granting that role SELECT on users.password_hash

-- ------------------------------------------------------------
-- 2. RBAC — roles and permissions as data, uniform across every
--    module (users, workflow, resource search, agentic tools).
--    This is the same table any future module's RLS policies join to.
-- ------------------------------------------------------------
create table roles (
    name        text primary key,
    description text
);

create table user_roles (
    user_id uuid not null references users(id) on delete cascade,
    role    text not null references roles(name),
    primary key (user_id, role)
);

create table role_permissions (
    role     text not null references roles(name),
    resource text not null,     -- e.g. 'workflow_runs', 'tasks', 'users'
    action   text not null,     -- e.g. 'select', 'insert', 'cancel', 'admin'
    primary key (role, resource, action)
);

-- One function every module's RLS policy calls. Add a new module
-- (resource search, agentic tools) by inserting rows here, not by
-- writing new authz code.
create or replace function has_permission(p_user_id uuid, p_resource text, p_action text)
returns boolean as $$
    select exists (
        select 1 from user_roles ur
        join role_permissions rp on rp.role = ur.role
        where ur.user_id = p_user_id
          and rp.resource = p_resource
          and rp.action = p_action
    );
$$ language sql stable;

-- Convenience: current user id from the JWT claims PostgREST already
-- exposes via current_setting -- use this directly inside RLS policies.
create or replace function current_user_id() returns uuid as $$
    select nullif(current_setting('request.jwt.claims', true)::json->>'sub', '')::uuid;
$$ language sql stable;

-- Example RLS policy shape any module adopts:
-- create policy select_own_or_permitted on <table> for select
--   using (owner_id = current_user_id() or has_permission(current_user_id(), '<resource>', 'select'));

-- ------------------------------------------------------------
-- 3. Refresh tokens — JWTs are stateless and can't be revoked, so
--    the revocable long-lived credential lives here. Access JWTs
--    stay short-lived (minutes) and are minted per-request from a
--    valid refresh token.
-- ------------------------------------------------------------
create table refresh_tokens (
    id           uuid primary key default gen_random_uuid(),
    user_id      uuid not null references users(id) on delete cascade,
    token_hash   text not null unique,     -- sha256 of the raw token; raw never stored
    device_label text,                     -- "Chrome on Mac", shown in session list
    issued_at    timestamptz not null default now(),
    expires_at   timestamptz not null,
    revoked_at   timestamptz,
    replaced_by  uuid references refresh_tokens(id)  -- rotation chain, for reuse detection
);
create index idx_refresh_tokens_user on refresh_tokens (user_id) where revoked_at is null;

-- Rotate: issue a new refresh token, revoke the old one, link the chain.
-- If a caller ever presents an already-revoked token whose replaced_by
-- chain is populated, that's a stolen/replayed token -- revoke the
-- entire chain (see refresh_session below).
create or replace function issue_refresh_token(p_user_id uuid, p_device_label text, p_raw_token text, p_ttl interval default interval '30 days')
returns uuid as $$
declare v_id uuid;
begin
    insert into refresh_tokens (user_id, token_hash, device_label, expires_at)
    values (p_user_id, encode(digest(p_raw_token, 'sha256'), 'hex'), p_device_label, now() + p_ttl)
    returning id into v_id;
    return v_id;
end;
$$ language plpgsql;

create or replace function refresh_session(p_raw_token text, p_new_raw_token text)
returns table(user_id uuid, new_refresh_token_id uuid) as $$
declare
    v_row refresh_tokens;
begin
    select * into v_row from refresh_tokens
    where token_hash = encode(digest(p_raw_token, 'sha256'), 'hex');

    if v_row.id is null then
        raise exception 'invalid refresh token';
    end if;

    if v_row.revoked_at is not null then
        -- reuse of a rotated-away token: possible theft. Revoke the
        -- whole chain forward from here as a precaution.
        update refresh_tokens set revoked_at = now()
        where user_id = v_row.user_id and revoked_at is null;
        raise exception 'refresh token reuse detected; all sessions revoked';
    end if;

    if v_row.expires_at < now() then
        raise exception 'refresh token expired';
    end if;

    return query
    with new_token as (
        insert into refresh_tokens (user_id, token_hash, device_label, expires_at)
        values (v_row.user_id, encode(digest(p_new_raw_token, 'sha256'), 'hex'),
                v_row.device_label, now() + interval '30 days')
        returning id
    ),
    revoke_old as (
        update refresh_tokens
        set revoked_at = now(), replaced_by = (select id from new_token)
        where id = v_row.id
    )
    select v_row.user_id, (select id from new_token);
end;
$$ language plpgsql;

create or replace function revoke_session(p_refresh_token_id uuid, p_user_id uuid)
returns void as $$
    update refresh_tokens set revoked_at = now()
    where id = p_refresh_token_id and user_id = p_user_id;
$$ language sql;

create or replace function revoke_all_sessions(p_user_id uuid) returns void as $$
    update refresh_tokens set revoked_at = now()
    where user_id = p_user_id and revoked_at is null;
$$ language sql;

-- ------------------------------------------------------------
-- 4. API keys — for agents/service accounts that shouldn't hold a
--    user password/session. Scoped, revocable, no expiry by default
--    (agents are long-running), but revocation is immediate since
--    it's a DB row, not a stateless token.
-- ------------------------------------------------------------
create table api_keys (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid references users(id) on delete cascade,  -- null = service account
    label       text not null,
    key_hash    text not null unique,      -- sha256 of raw key; raw shown once at creation
    scopes      text[] not null default '{}',  -- e.g. {'workflow:trigger','workflow:read'}
    created_at  timestamptz not null default now(),
    last_used_at timestamptz,
    revoked_at  timestamptz
);

create or replace function verify_api_key(p_raw_key text)
returns table(key_id uuid, user_id uuid, scopes text[]) as $$
    update api_keys
    set last_used_at = now()
    where key_hash = encode(digest(p_raw_key, 'sha256'), 'hex')
      and revoked_at is null
    returning id, user_id, scopes;
$$ language sql;

-- ------------------------------------------------------------
-- 5. Login throttling — reuses the WORKFLOW ENGINE's rate limiter
--    (try_consume_rate_limit / rate_limits) rather than building a
--    second one. Same token-bucket, keyed by email or IP.
--    (Assumes rate_limits/try_consume_rate_limit already exist from
--     workflow_schema_v1.0.sql -- create here if this is deployed standalone.)
-- ------------------------------------------------------------
-- insert into rate_limits (key, capacity, tokens, refill_rate)
--   values ('login:'||lower($email), 5, 5, 0.0167);  -- 5 attempts, refill 1/min

create or replace function attempt_login(p_email text, p_plain text)
returns uuid as $$
declare v_user_id uuid;
begin
    if not try_consume_rate_limit('login:' || lower(p_email)) then
        raise exception 'too many login attempts, try again shortly';
    end if;

    v_user_id := verify_password(p_email, p_plain);

    insert into auth_events (user_id, event_type, detail)
    values (v_user_id, case when v_user_id is null then 'login_failed' else 'login_success' end,
            jsonb_build_object('email', p_email));

    if v_user_id is null then
        raise exception 'invalid credentials';
    end if;
    return v_user_id;
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 6. Audit log — append-only, same shape as the workflow engine's
--    task_events. Every auth-relevant event, queryable, no separate
--    logging infra needed for this.
-- ------------------------------------------------------------
create table auth_events (
    id         bigint generated always as identity primary key,
    user_id    uuid,
    event_type text not null,   -- login_success, login_failed, password_changed,
                                 -- session_revoked, role_granted, role_revoked, api_key_created
    detail     jsonb,
    at         timestamptz not null default now()
);
create index idx_auth_events_user on auth_events (user_id, at);

create or replace function grant_role(p_actor_id uuid, p_target_user_id uuid, p_role text)
returns void as $$
begin
    if not has_permission(p_actor_id, 'users', 'admin') then
        raise exception 'not authorized to grant roles';
    end if;
    insert into user_roles (user_id, role) values (p_target_user_id, p_role)
    on conflict do nothing;
    insert into auth_events (user_id, event_type, detail)
    values (p_target_user_id, 'role_granted', jsonb_build_object('role', p_role, 'by', p_actor_id));
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 7. OPTIONAL maximal-pushdown callout: mint JWTs in SQL via pgjwt,
--    so login() returns a ready-to-use access token directly.
--    Tradeoff: the signing secret lives in the DB (in a Postgres
--    setting or a small config table), which is one more place a
--    leak matters. Most teams should mint in FastAPI instead (see
--    spec) -- this is here because "maximal pushdown" was the ask.
-- ------------------------------------------------------------
-- create or replace function login_and_mint_jwt(p_email text, p_plain text)
-- returns text as $$
-- declare
--     v_user_id uuid;
--     v_role text;
-- begin
--     v_user_id := attempt_login(p_email, p_plain);
--     select role into v_role from user_roles where user_id = v_user_id limit 1;
--     return sign(
--         json_build_object(
--             'sub', v_user_id, 'role', coalesce(v_role, 'api_user'),
--             'exp', extract(epoch from now() + interval '5 minutes')::int
--         ),
--         current_setting('app.jwt_secret')
--     );
-- end;
-- $$ language plpgsql security definer;

-- ------------------------------------------------------------
-- 8. Tie into the workflow engine: row-level ownership so a user
--    can only see/cancel their own runs unless permitted otherwise.
--    (Requires workflow_schema_v1.0.sql's workflow_runs table.)
-- ------------------------------------------------------------
-- alter table workflow_runs add column owner_id uuid references users(id);
--
-- alter table workflow_runs enable row level security;
-- create policy runs_owner_or_permitted on workflow_runs for select
--   using (owner_id = current_user_id() or has_permission(current_user_id(), 'workflow_runs', 'select'));
-- create policy runs_cancel on workflow_runs for update
--   using (owner_id = current_user_id() or has_permission(current_user_id(), 'workflow_runs', 'cancel'));
