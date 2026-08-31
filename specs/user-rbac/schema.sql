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
--
-- SECURITY (fixed after empirical testing against a live PostgREST role
-- model, see ../../experiments/pg19-stack/FINDINGS.md #2): this and
-- verify_password() are now internal-only -- EXECUTE is revoked from
-- PUBLIC in §9, so they're callable only from within another
-- SECURITY DEFINER function owned by the same role (create_user_with_password,
-- change_password, attempt_login below), never directly via PostgREST RPC.
-- Confirmed empirically: with no restriction, web_anon could call
-- set_password(any_user_id, ...) with zero auth check and silently succeeded
-- purely because table-level UPDATE happened not to be granted yet -- an
-- accident of grant ordering, not a real control. Never trust that again.
create or replace function set_password(p_user_id uuid, p_plain text)
returns void as $$
    update users
    set password_hash = crypt(p_plain, gen_salt('bf', 12)), updated_at = now()
    where id = p_user_id;
$$ language sql security definer;

create or replace function verify_password(p_email text, p_plain text)
returns uuid as $$
    select id from users
    where email = p_email
      and status = 'active'
      and password_hash = crypt(p_plain, password_hash);
$$ language sql security definer;
-- security definer: callable by an unprivileged 'api_user' role via
-- PostgREST RPC without granting that role SELECT on users.password_hash.
-- Confirmed empirically: with EXECUTE left at its Postgres default (granted
-- to PUBLIC), this is an unrate-limited password-guessing oracle for anyone
-- who calls it directly, bypassing attempt_login()'s rate limiter entirely --
-- EXECUTE must be revoked from PUBLIC (§9); only attempt_login() (also
-- security definer, same owner) may call it internally.

-- The only safe way to change a password: proves identity via the OLD
-- password (self-service) rather than trusting a caller-supplied user id.
-- Public entry point -- EXECUTE granted to `authenticated` in §9.
create or replace function change_password(p_old_plain text, p_new_plain text)
returns void as $$
declare
    v_email text;
begin
    select email into v_email from users where id = current_user_id();
    if v_email is null or verify_password(v_email, p_old_plain) is null then
        raise exception 'current password incorrect';
    end if;
    perform set_password(current_user_id(), p_new_plain);
end;
$$ language plpgsql security definer;

-- Signup. The function spec.md's FastAPI example always assumed existed --
-- it didn't (empirically confirmed missing here); added to close that gap.
-- Public entry point -- EXECUTE granted to `web_anon` in §9 (signup is
-- inherently unauthenticated).
create or replace function create_user_with_password(p_email text, p_plain text)
returns uuid as $$
declare v_user_id uuid;
begin
    insert into users (email, status) values (p_email, 'pending_verification')
    returning id into v_user_id;
    perform set_password(v_user_id, p_plain);
    return v_user_id;
end;
$$ language plpgsql security definer;

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
--
-- The nullif() guards the RAW SETTING, not the extracted 'sub' field: once a
-- pooled connection (PgBouncer/pgcat) has had request.jwt.claims SET LOCAL in
-- any prior transaction, an unregistered custom GUC resets to '' (not NULL)
-- after that transaction commits -- confirmed empirically against PG19 beta3,
-- see ../../experiments/pg19-stack/FINDINGS.md §1. Casting '' straight to
-- ::json throws before a nullif() applied only to ->>'sub' ever runs; guarding
-- the raw string first avoids that, and is what makes the very next anonymous
-- request on a reused pooled connection return zero rows instead of a 500.
create or replace function current_user_id() returns uuid as $$
    select (nullif(current_setting('request.jwt.claims', true), '')::json->>'sub')::uuid;
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
-- SECURITY: internal only (EXECUTE revoked from PUBLIC in §9), never a
-- direct PostgREST RPC target. Confirmed empirically: if exposed, any
-- unauthenticated caller could mint a valid refresh token for an arbitrary
-- p_user_id with zero proof of identity -- a full account-takeover primitive,
-- not a theoretical one. Only login() below (security definer, same owner)
-- may call it, and only with the user_id ITS OWN password check just proved,
-- never a caller-supplied one.
create or replace function issue_refresh_token(p_user_id uuid, p_device_label text, p_raw_token text, p_ttl interval default interval '30 days')
returns uuid as $$
declare v_id uuid;
begin
    insert into refresh_tokens (user_id, token_hash, device_label, expires_at)
    values (p_user_id, encode(digest(p_raw_token, 'sha256'), 'hex'), p_device_label, now() + p_ttl)
    returning id into v_id;
    return v_id;
end;
$$ language plpgsql security definer;

-- security definer: self-authenticating via token possession, so safe as a
-- public entry point, but needs to INSERT/UPDATE refresh_tokens without
-- granting broad write access on that table to web_anon.
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
$$ language plpgsql security definer;

-- SECURITY: p_user_id used to be a caller-supplied parameter -- dropped.
-- Confirmed empirically (same class of bug as grant_role below): a
-- caller-supplied "whose session is this" argument is always spoofable via
-- PostgREST RPC, so any authenticated user could have revoked anyone else's
-- sessions by just passing their target's id. current_user_id() is the only
-- trustworthy source, since it's derived server-side from the verified JWT,
-- not client input. A user can only revoke their own sessions via these
-- public entry points; an admin-driven "revoke someone else's sessions"
-- would need its own has_permission()-gated function, not this one.
create or replace function revoke_session(p_refresh_token_id uuid)
returns void as $$
    update refresh_tokens set revoked_at = now()
    where id = p_refresh_token_id and user_id = current_user_id();
$$ language sql security definer;

create or replace function revoke_all_sessions() returns void as $$
    update refresh_tokens set revoked_at = now()
    where user_id = current_user_id() and revoked_at is null;
$$ language sql security definer;

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

-- security definer: self-authenticating via key possession, so safe as a
-- public entry point, but needs to UPDATE last_used_at without granting
-- broad UPDATE on api_keys to web_anon.
create or replace function verify_api_key(p_raw_key text)
returns table(key_id uuid, user_id uuid, scopes text[]) as $$
    update api_keys
    set last_used_at = now()
    where key_hash = encode(digest(p_raw_key, 'sha256'), 'hex')
      and revoked_at is null
    returning id, user_id, scopes;
$$ language sql security definer;

-- ------------------------------------------------------------
-- 5. Login throttling — reuses the WORKFLOW ENGINE's rate limiter
--    (try_consume_rate_limit / rate_limits) rather than building a
--    second one. Same token-bucket, keyed by email or IP.
--    Requires rate_limits/try_consume_rate_limit to already exist from
--    workflow_schema_v1.0.sql -- this module is not standalone-deployable
--    without it (confirmed: attempt_login() below fails outright with no
--    fallback if try_consume_rate_limit() is undefined). The bucket row
--    itself is seeded lazily inside attempt_login() on first use, not here.
-- ------------------------------------------------------------

-- security definer: needs to call verify_password() (now internal-only, §9)
-- and write auth_events without granting either directly to web_anon.
create or replace function attempt_login(p_email text, p_plain text)
returns uuid as $$
declare v_user_id uuid;
begin
    -- FIX (empirically confirmed broken, ../../experiments/pg19-stack/FINDINGS.md
    -- #2): try_consume_rate_limit() does an UPDATE against an existing
    -- rate_limits row -- with none pre-seeded, the UPDATE matches zero rows,
    -- and it fails closed (returns false). With no bucket ever created for a
    -- new email, this meant NOBODY could ever log in, for any account --
    -- confirmed directly, not a hypothetical. Seed the bucket lazily on
    -- first use rather than requiring a bucket to already exist.
    insert into rate_limits (key, capacity, tokens, refill_rate)
    values ('login:' || lower(p_email), 5, 5, 0.0167)
    on conflict (key) do nothing;

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
$$ language plpgsql security definer;

-- The actual public login entry point: attempt_login() and
-- issue_refresh_token() combined atomically, so the token is always issued
-- for the SAME user_id attempt_login() just verified -- there is no code
-- path where a caller can supply a different one. Replaces the two separate
-- RPC calls spec.md's FastAPI example used to make (attempt_login then
-- issue_refresh_token), which only worked because issue_refresh_token() used
-- to accept a caller-supplied user_id directly -- exactly the bug this
-- section fixes.
create or replace function login(p_email text, p_plain text, p_device_label text, p_raw_token text)
returns table(user_id uuid, refresh_token_id uuid) as $$
declare
    v_user_id uuid;
    v_token_id uuid;
begin
    v_user_id := attempt_login(p_email, p_plain);
    v_token_id := issue_refresh_token(v_user_id, p_device_label, p_raw_token);
    return query select v_user_id, v_token_id;
end;
$$ language plpgsql security definer;

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

-- SECURITY: this is the vulnerability that motivated this whole section --
-- confirmed empirically as a full, working privilege escalation, not a
-- theoretical one (see ../../experiments/pg19-stack/FINDINGS.md #2). p_actor_id
-- used to be a caller-supplied parameter: any authenticated non-admin user
-- could call grant_role(<a real admin's id>, <their own id>, 'admin') and the
-- has_permission() check would pass, because it was checking the ADMIN's
-- permissions, not the CALLER's -- there was nothing tying p_actor_id to who
-- was actually making the request. Once this function is security definer
-- (needed so it can write to user_roles without granting broad INSERT to
-- `authenticated`), that escalation fully succeeds end to end, confirmed by
-- reproducing it directly. current_user_id() is the only trustworthy actor.
create or replace function grant_role(p_target_user_id uuid, p_role text)
returns void as $$
begin
    if not has_permission(current_user_id(), 'users', 'admin') then
        raise exception 'not authorized to grant roles';
    end if;
    insert into user_roles (user_id, role) values (p_target_user_id, p_role)
    on conflict do nothing;
    insert into auth_events (user_id, event_type, detail)
    values (p_target_user_id, 'role_granted', jsonb_build_object('role', p_role, 'by', current_user_id()));
end;
$$ language plpgsql security definer;

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

-- ------------------------------------------------------------
-- 9. PostgREST role model, grants, and RLS -- not previously written
--    down anywhere; added after empirically confirming its absence was
--    exploitable (../../experiments/pg19-stack/FINDINGS.md #2), not just
--    incomplete. Two structural rules this section enforces:
--      a) EVERY function meant to be a PostgREST RPC entry point is
--         SECURITY DEFINER (fixed above) AND has EXECUTE explicitly
--         granted -- Postgres's default (EXECUTE granted to PUBLIC on
--         every new function) is revoked wholesale first, so a new
--         function added later is unreachable via REST until someone
--         deliberately grants it. Deny-by-default, not allow-by-omission.
--      b) NO base table gets direct INSERT/UPDATE/DELETE from web_anon or
--         authenticated. All writes to auth-sensitive tables go through
--         the checked functions above; PostgREST's auto-CRUD only ever
--         needs to expose reads (via RLS + column grants) for this module.
-- ------------------------------------------------------------
create role web_anon nologin;
create role authenticated nologin;
-- authenticator: what PostgREST's db-uri connects as; switches into
-- web_anon (no JWT) or authenticated (valid JWT) per request. LOGIN
-- credential belongs in deployment config, not this file.
create role authenticator noinherit login;
grant web_anon to authenticator;
grant authenticated to authenticator;

grant usage on schema public to web_anon, authenticated;

-- (a) Deny all function execution by default, then allow only the
-- functions actually meant to be public entry points.
revoke execute on all functions in schema public from public;

grant execute on function create_user_with_password(text, text) to web_anon;
grant execute on function login(text, text, text, text) to web_anon;
grant execute on function refresh_session(text, text) to web_anon, authenticated;
grant execute on function verify_api_key(text) to web_anon, authenticated;
grant execute on function change_password(text, text) to authenticated;
grant execute on function grant_role(uuid, text) to authenticated;
grant execute on function revoke_session(uuid) to authenticated;
grant execute on function revoke_all_sessions() to authenticated;
-- has_permission()/current_user_id() are called FROM RLS policies, which
-- always run as the querying role -- both need direct EXECUTE too, not just
-- "called internally by a security definer function" (there is no
-- security-definer indirection when Postgres evaluates a USING clause).
grant execute on function has_permission(uuid, text, text) to web_anon, authenticated;
grant execute on function current_user_id() to web_anon, authenticated;
-- set_password, verify_password, issue_refresh_token, attempt_login: stay
-- internal-only (owner-only EXECUTE), reachable only from within the
-- security-definer functions above that call them, never directly via RPC.

-- (b) RLS on every table this module owns -- deny-by-default the moment RLS
-- is enabled with no matching policy, which is exactly what anon/no-session
-- callers should get on tables this sensitive.
--
-- FORCE is not optional here, and its absence is exactly the kind of gap
-- that looks fine until tested. Confirmed empirically
-- (../../experiments/pg19-stack/FINDINGS.md #2), through a chain of three
-- successive failures before this was right: table owners bypass their own
-- RLS policies BY DEFAULT, regardless of superuser status -- this has
-- nothing to do with whether the owner happens to be a superuser (a
-- separate, also-real trap: never let the schema owner be a cluster
-- superuser either, since superusers bypass RLS unconditionally, FORCE or
-- not). Since users_api/refresh_tokens_api/api_keys_api below are plain
-- (owner-privileged) views -- required, not incidental: a security_invoker
-- view was tried first and re-requires base-table grants, defeating the
-- point -- every read through them runs with the OWNER's privileges unless
-- FORCE is set, which means RLS is silently skipped for every caller, not
-- just the owner. This was reproduced directly: without FORCE, a non-admin
-- user querying users_api saw every row in the table.
alter table users enable row level security;
alter table users force row level security;
alter table refresh_tokens enable row level security;
alter table refresh_tokens force row level security;
alter table api_keys enable row level security;
alter table api_keys force row level security;
alter table auth_events enable row level security;
alter table auth_events force row level security;
alter table user_roles enable row level security;
alter table user_roles force row level security;

create policy users_self_or_admin on users for select
  using (id = current_user_id() or has_permission(current_user_id(), 'users', 'select'));
create policy refresh_tokens_self_or_admin on refresh_tokens for select
  using (user_id = current_user_id() or has_permission(current_user_id(), 'refresh_tokens', 'select'));
create policy api_keys_self_or_admin on api_keys for select
  using (user_id = current_user_id() or has_permission(current_user_id(), 'api_keys', 'select'));
create policy auth_events_self_or_admin on auth_events for select
  using (user_id = current_user_id() or has_permission(current_user_id(), 'auth_events', 'select'));
create policy user_roles_self_or_admin on user_roles for select
  using (user_id = current_user_id() or has_permission(current_user_id(), 'user_roles', 'select'));

-- Read paths for users/refresh_tokens/api_keys are VIEWS, not column-level
-- grants on the base table -- confirmed empirically
-- (../../experiments/pg19-stack/FINDINGS.md #2) that a partial column-level
-- GRANT does NOT do what it looks like it does here: PostgREST's `GET
-- /users` issues the equivalent of `SELECT *`, and Postgres fails that
-- *entire* query with "permission denied for table users" the moment it
-- references even one ungranted column -- it does not silently drop
-- password_hash/mfa_secret and return the rest. A view whose SELECT list
-- simply never mentions the secret columns has no such failure mode: there
-- is no ungranted column for `SELECT *` (against the view) to reference.
-- RLS on the base table still applies through the view -- confirmed
-- directly -- since current_user_id() reads session state, not anything
-- owner/view-dependent. Deliberately the Postgres DEFAULT view behavior
-- (security_invoker = false / omitted), not the PG15+ security_invoker
-- option -- confirmed empirically that security_invoker actively breaks
-- this pattern: it makes the QUERYING role's own privileges on the base
-- table get re-checked, which defeats the entire point (the view exists so
-- `authenticated` never needs a base-table grant at all). The default,
-- owner-privileged view is what makes "grant SELECT on the view only" work:
-- object-level column access is checked against the view's OWNER, while
-- RLS row-filtering still uses the querying role, because current_user_id()
-- reads session state regardless of whose privileges are active for the
-- column check.
create view users_api as
  select id, email, status, created_at, updated_at from users;
create view refresh_tokens_api as
  select id, user_id, device_label, issued_at, expires_at, revoked_at from refresh_tokens;
create view api_keys_api as
  select id, user_id, label, scopes, created_at, last_used_at, revoked_at from api_keys;

grant select on users_api to authenticated;
grant select on refresh_tokens_api to authenticated;
grant select on api_keys_api to authenticated;
-- No grant on the base tables themselves to web_anon or authenticated --
-- PostgREST should be pointed at users_api/refresh_tokens_api/api_keys_api,
-- never at users/refresh_tokens/api_keys directly, for reads. Writes to all
-- three go exclusively through the functions in (a), not REST table writes,
-- so no base-table INSERT/UPDATE/DELETE grant exists at all.

grant select on auth_events to authenticated;
grant select on user_roles to authenticated;
-- roles, role_permissions: reference/catalog data, not per-row sensitive --
-- plain table grants, no RLS needed.
grant select on roles, role_permissions to authenticated;

-- web_anon gets no table access at all -- every unauthenticated interaction
-- this module supports (signup, login, refresh, API-key auth) is a function
-- call, not a table read, so it never needed one.
