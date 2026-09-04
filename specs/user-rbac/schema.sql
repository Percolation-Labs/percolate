-- ============================================================
-- User management + RBAC — maximal Postgres pushdown v1.0
-- Philosophy: same as the workflow engine. Postgres is the
-- source of truth for identity, permissions, and sessions.
-- FastAPI is a thin proxy that mints/forwards JWTs and handles
-- the handful of things that structurally cannot live in SQL
-- (OAuth token exchange, email sending, TOTP).
-- ============================================================
--
-- Every SECURITY DEFINER function below sets `search_path = pg_catalog,
-- public` explicitly. This is standard PostgreSQL hardening (CVE-2018-1058
-- and the advisory it produced: https://wiki.postgresql.org/wiki/
-- A_Guide_to_CVE-2018-1058:_Protect_Your_Search_Path) for any SECURITY
-- DEFINER function that calls other objects by unqualified name -- without
-- it, a caller who can create an object earlier in their own session's
-- search_path (a schema they own, or in some configurations pg_temp) could
-- have a DEFINER function resolve to their malicious same-named function
-- instead of the real one, executing it with the DEFINER's privileges. One
-- specific reproduction attempt (a pg_temp function shadow against
-- grant_role's internal has_permission() call) did NOT succeed against this
-- schema's current grants (authenticated has neither CREATE on the database
-- nor on public). That's exactly the point: today's grants happening to block one
-- attempt is not a reason to skip a fix the authoritative guidance states
-- unconditionally, especially given this schema's own history of "safe by
-- accident of which grants don't exist yet" bugs (§9).
--
-- Schema namespacing (specs/README.md ground rule, executed here): every
-- table/function/view this module owns lives in the rbac schema, qualified
-- explicitly at every reference -- not just at each CREATE, and not via a
-- widened search_path either. `set search_path = pg_catalog, public` below
-- is deliberately left unchanged, not extended to include rbac: the whole
-- point of this file's existing hardening posture is never trusting implicit
-- resolution for a SECURITY DEFINER function, and adding a second schema to
-- the trusted list is exactly the kind of shortcut that posture argues
-- against, even when (as here) rbac isn't writable by an untrusted role.
-- Fully qualifying every internal reference costs nothing at runtime and
-- means this file's search_path story never needs re-reasoning about later.
-- The one cross-schema reference in this file (attempt_login()'s call into
-- workflow-engine's rate limiter) is explicitly `workflow.`-qualified for
-- the same reason. Permission-resource string literals like 'users' passed
-- to has_permission() (e.g. has_permission(uid, 'users', 'select')) are a
-- separate, deliberately un-namespaced vocabulary -- role_permissions.resource
-- tags, not object references -- and are untouched by this schema move.
-- ============================================================

create extension if not exists pgcrypto;   -- bcrypt via crypt()/gen_salt()
-- create extension if not exists pgjwt;   -- optional: mint JWTs in SQL (see §7 callout)

create schema if not exists rbac;

-- ------------------------------------------------------------
-- 1. Users
-- ------------------------------------------------------------
create table if not exists rbac.users (
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
-- model): this and verify_password() are now internal-only -- EXECUTE is revoked from
-- PUBLIC in §9, so they're callable only from within another
-- SECURITY DEFINER function owned by the same role (create_user_with_password,
-- change_password, attempt_login below), never directly via PostgREST RPC.
-- Confirmed empirically: with no restriction, web_anon could call
-- set_password(any_user_id, ...) with zero auth check and silently succeeded
-- purely because table-level UPDATE happened not to be granted yet -- an
-- accident of grant ordering, not a real control. Never trust that again.
create or replace function rbac.set_password(p_user_id uuid, p_plain text)
returns void as $$
    update rbac.users
    set password_hash = crypt(p_plain, gen_salt('bf', 12)), updated_at = now()
    where id = p_user_id;
$$ language sql security definer set search_path = pg_catalog, public;

create or replace function rbac.verify_password(p_email text, p_plain text)
returns uuid as $$
    select id from rbac.users
    where email = p_email
      and status = 'active'
      and password_hash = crypt(p_plain, password_hash);
$$ language sql security definer set search_path = pg_catalog, public;
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
create or replace function rbac.change_password(p_old_plain text, p_new_plain text)
returns void as $$
declare
    v_email text;
begin
    select email into v_email from rbac.users where id = rbac.current_user_id();
    if v_email is null or rbac.verify_password(v_email, p_old_plain) is null then
        raise exception 'current password incorrect';
    end if;
    perform rbac.set_password(rbac.current_user_id(), p_new_plain);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Signup. The function spec.md's FastAPI example always assumed existed --
-- it didn't (empirically confirmed missing here); added to close that gap.
-- Public entry point -- EXECUTE granted to `web_anon` in §9 (signup is
-- inherently unauthenticated).
-- ------------------------------------------------------------
-- 1a. SIGNUP MAKES AN ACCOUNT THAT CANNOT LOG IN, and nothing here changes
--     that. Stated because an absence and a decision look identical.
--
-- create_user_with_password() inserts `pending_verification`; verify_password()
-- requires `active`. Between them the collection ships **nothing**: no
-- verification-token table, no verify_email(), and no `send_verification_email`
-- workflow -- that name appears only in spec.md §4.1's example and in a comment
-- about trace propagation. So the documented front door creates a user who is
-- refused at the second one, with `invalid credentials`, forever.
--
-- Found by writing the first test that ever called both in one transaction
-- (dev/tests/rbac/03-auth-path.sql). It survived because every other test
-- creates its users with an INSERT and a status of its own choosing, which is
-- exactly how a fixture stops standing in for a user.
--
-- NOT fixed here, and the reason is scope rather than difficulty: an email
-- verification design is a token table, an expiry, a resend policy and a
-- delivery path, and inventing one inside a bug report is how a subsystem
-- grows a feature nobody specified. What IS fixed is the diagnosability --
-- attempt_login() now records WHY a login failed (§5) while still telling the
-- caller nothing -- and the gap is pinned by an assertion, so building
-- verification is a deliberate act that updates a test rather than a surprise.
--
-- The operator's workaround, until then, is the one the status column already
-- implies: `update rbac.users set status = 'active' where id = ...`.
-- ------------------------------------------------------------
create or replace function rbac.create_user_with_password(p_email text, p_plain text)
returns uuid as $$
declare v_user_id uuid;
begin
    insert into rbac.users (email, status) values (p_email, 'pending_verification')
    returning id into v_user_id;
    perform rbac.set_password(v_user_id, p_plain);
    return v_user_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 2. RBAC — roles and permissions as data, uniform across every
--    module (users, workflow, resource search, agentic tools).
--    This is the same table any future module's RLS policies join to.
-- ------------------------------------------------------------
create table if not exists rbac.roles (
    name        text primary key,
    description text
);

create table if not exists rbac.user_roles (
    user_id uuid not null references rbac.users(id) on delete cascade,
    role    text not null references rbac.roles(name),
    primary key (user_id, role)
);

-- THE VOCABULARY, AS A TABLE, BECAUSE FREE TEXT HERE FAILS SILENTLY.
--
-- `role_permissions.action` used to be unconstrained text, and every consumer
-- compares it with `=`. That combination has no loud failure mode: a grant of
-- ('workflow_runs','read') where the policy asks for 'select' INSERTS, the
-- role reads as populated, and every policy consulting it returns false. The
-- published install guide and `percolate auth bootstrap` both shipped exactly
-- that list, so following either produced an administrator who saw zero rows
-- in workflow.runs_api and had no way to tell that from an empty database.
--
-- A pair is either something this collection checks for, or it is a typo.
-- There is no third case, so the set is closed and role_permissions references
-- it: the wrong verb now fails at the INSERT that writes it, naming the row,
-- instead of at a policy that returns false somewhere else later.
--
-- It stays INSERTABLE, because the extensibility story is real -- a new module
-- adds its pairs here and then grants them, still without writing authz code.
-- What it can no longer do is grant a pair nothing will ever ask for.
create table if not exists rbac.permission_kinds (
    resource text not null,
    action   text not null,
    checked_by text not null,   -- where the pair is consulted, so it can be verified
    primary key (resource, action)
);

insert into rbac.permission_kinds (resource, action, checked_by) values
    -- RLS policies. Every one of these spells the read action 'select'; that
    -- is the fact the old hand-copied lists got wrong.
    ('users',              'select', 'policy users_self_or_admin'),
    ('user_roles',         'select', 'policy user_roles_self_or_admin'),
    ('api_keys',           'select', 'policy api_keys_self_or_admin'),
    ('auth_events',        'select', 'policy auth_events_self_or_admin'),
    ('refresh_tokens',     'select', 'policy refresh_tokens_self_or_admin'),
    ('password_reset_tokens', 'select', 'policy password_reset_tokens_self_or_admin'),
    ('workflow_runs',      'select', 'policy runs_owner_or_permitted'),
    ('workflow_schedules', 'select', 'policy schedules_owner_or_permitted'),
    -- Function guards.
    ('users',              'admin',  'rbac.grant_role'),
    ('workflows',          'update', 'workflow.may_define'),
    ('workflow_pools',     'update', 'workflow.pool guards'),
    ('agents',             'update', 'agentic.may_author'),
    ('tool_servers',       'update', 'agentic.may_author'),
    ('skills',             'update', 'agentic.may_author'),
    ('plugins',            'update', 'agentic.may_author'),
    -- Runs and schedules carry a verb per operation rather than a read/write
    -- pair, because cancelling somebody else's run and reading it are
    -- different authorities.
    ('workflow_runs',      'cancel', 'workflow.assert_run_access'),
    ('workflow_runs',      'signal', 'workflow.assert_run_access'),
    ('workflow_schedules', 'create', 'workflow.assert_schedule_access'),
    ('workflow_schedules', 'enable', 'workflow.assert_schedule_access'),
    ('workflow_schedules', 'delete', 'workflow.assert_schedule_access')
on conflict do nothing;

create table if not exists rbac.role_permissions (
    role     text not null references rbac.roles(name),
    resource text not null,
    action   text not null,
    primary key (role, resource, action),
    -- The point of the table above: a pair nothing checks cannot be granted.
    foreign key (resource, action)
        references rbac.permission_kinds (resource, action)
);

-- One function every module's RLS policy calls. Add a new module
-- (resource search, agentic tools) by inserting rows here, not by
-- writing new authz code.
--
-- SECURITY DEFINER, and this is load-bearing rather than incidental: without
-- it the function recurses until the backend blows its stack. The cycle is
-- two hops and neither hop looks wrong on its own --
--
--   any table's policy  ->  has_permission(uid, 'x', 'select')
--                       ->  select from rbac.user_roles      (as the CALLER)
--                       ->  user_roles_self_or_admin policy  (§9b, below)
--                       ->  has_permission(uid, 'user_roles', 'select')
--                       ->  select from rbac.user_roles  ->  ...
--
-- Postgres cannot see this as a policy cycle -- its own "infinite recursion
-- detected in policy for relation" check only catches a policy that names its
-- own table directly, and here the self-reference is laundered through a
-- function -- so the failure is `stack depth limit exceeded` from inside
-- has_permission, with nothing naming RLS at all.
--
-- Reproduced against the live PG19 beta3 stack via dev/tests/rbac/01: it needs
-- a caller who does NOT own the row being scanned AND does not hold the
-- permission, which is why the happy path hid it. A user reading their own
-- rows short-circuits on the first disjunct and never evaluates the second.
-- That is exactly the population RLS exists to constrain, so every consumer
-- table adopting the documented policy shape (§2's comment) was broken for
-- precisely the callers it was protecting against, and passing for everyone
-- else. It fails closed -- an error, not extra rows -- but it fails.
--
-- app_owner owns this function and owns user_roles/role_permissions, and a
-- table owner bypasses RLS by default (§9b's three facts, fact 1), so running
-- as the definer breaks the cycle at the first hop. `set search_path` is the
-- collection's unconditional rule for any SECURITY DEFINER function
-- (specs/README.md ground rules, CVE-2018-1058).
--
-- The tradeoff this accepts, stated rather than discovered: as a definer the
-- function answers for ANY p_user_id, so a caller holding a user's uuid can
-- learn whether that user has a given permission. It returns a boolean about
-- role grants and never a row, and the parameter is deliberately kept because
-- spec.md §5's per-resource-sharing work -- deferred, not built -- needs to
-- ask the question about somebody else. Narrowing it to self-or-admin belongs
-- with that work, not here, where it would be a second authorization rule
-- invented in passing.
create or replace function rbac.has_permission(p_user_id uuid, p_resource text, p_action text)
returns boolean as $$
    select exists (
        select 1 from rbac.user_roles ur
        join rbac.role_permissions rp on rp.role = ur.role
        where ur.user_id = p_user_id
          and rp.resource = p_resource
          and rp.action = p_action
    );
$$ language sql stable security definer set search_path = pg_catalog, public;

-- Convenience: current user id from the JWT claims PostgREST already
-- exposes via current_setting -- use this directly inside RLS policies.
--
-- The nullif() guards the RAW SETTING, not the extracted 'sub' field: once a
-- pooled connection (PgBouncer/pgcat) has had request.jwt.claims SET LOCAL in
-- any prior transaction, an unregistered custom GUC resets to '' (not NULL)
-- after that transaction commits -- confirmed empirically against PG19 beta3.
-- Casting '' straight to
-- ::json throws before a nullif() applied only to ->>'sub' ever runs; guarding
-- the raw string first avoids that, and is what makes the very next anonymous
-- request on a reused pooled connection return zero rows instead of a 500.
create or replace function rbac.current_user_id() returns uuid as $$
    select (nullif(current_setting('request.jwt.claims', true), '')::json->>'sub')::uuid;
$$ language sql stable;

-- OTel ground rule (specs/README.md): the W3C trace_id for the request this
-- function call is happening inside, not a fresh disconnected one, whenever
-- the caller already has one. Reads request.trace_id, the same "GUC PostgREST
-- sets per-request" mechanism as current_user_id() above -- bridged from the
-- standard `traceparent` HTTP header via PostgREST's db-pre-request hook (a
-- function that runs before every request and can set session GUCs from
-- request.headers), not a new mechanism. Falls back to a fresh trace_id only
-- when the caller genuinely didn't propagate one -- an auth_events row should
-- never have a null trace_id, even for a client that doesn't participate in
-- tracing. Same empty-string-after-pooled-connection-commit guard as
-- current_user_id() -- see its comment above -- applies here too.
create or replace function rbac.current_trace_id() returns text as $$
    select coalesce(
        nullif(current_setting('request.trace_id', true), ''),
        encode(gen_random_bytes(16), 'hex')
    );
$$ language sql stable;

-- Example RLS policy shape any module adopts. current_user_id()/
-- has_permission() are called from OUTSIDE rbac here (any other schema's
-- own RLS policy) -- explicitly qualified, per this file's header note,
-- not left to a search_path that would have to include rbac to work:
-- create policy select_own_or_permitted on <table> for select
--   using (owner_id = rbac.current_user_id() or rbac.has_permission(rbac.current_user_id(), '<resource>', 'select'));

-- ------------------------------------------------------------
-- 3. Refresh tokens — JWTs are stateless and can't be revoked, so
--    the revocable long-lived credential lives here. Access JWTs
--    stay short-lived (minutes) and are minted per-request from a
--    valid refresh token.
-- ------------------------------------------------------------
create table if not exists rbac.refresh_tokens (
    id           uuid primary key default gen_random_uuid(),
    user_id      uuid not null references rbac.users(id) on delete cascade,
    token_hash   text not null unique,     -- sha256 of the raw token; raw never stored
    device_label text,                     -- "Chrome on Mac", shown in session list
    issued_at    timestamptz not null default now(),
    expires_at   timestamptz not null,
    revoked_at   timestamptz,
    replaced_by  uuid references rbac.refresh_tokens(id)  -- rotation chain, for reuse detection
);
create index if not exists idx_refresh_tokens_user on rbac.refresh_tokens (user_id) where revoked_at is null;

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
create or replace function rbac.issue_refresh_token(p_user_id uuid, p_device_label text, p_raw_token text, p_ttl interval default interval '30 days')
returns uuid as $$
declare v_id uuid;
begin
    insert into rbac.refresh_tokens (user_id, token_hash, device_label, expires_at)
    values (p_user_id, encode(digest(p_raw_token, 'sha256'), 'hex'), p_device_label, now() + p_ttl)
    returning id into v_id;
    return v_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- security definer: self-authenticating via token possession, so safe as a
-- public entry point, but needs to INSERT/UPDATE refresh_tokens without
-- granting broad write access on that table to web_anon.
create or replace function rbac.refresh_session(p_raw_token text, p_new_raw_token text)
returns table(user_id uuid, new_refresh_token_id uuid) as $$
declare
    v_row rbac.refresh_tokens;
begin
    select * into v_row from rbac.refresh_tokens
    where token_hash = encode(digest(p_raw_token, 'sha256'), 'hex');

    if v_row.id is null then
        raise exception 'invalid refresh token';
    end if;

    if v_row.revoked_at is not null then
        -- reuse of a rotated-away token: possible theft. Revoke the
        -- whole chain forward from here as a precaution.
        update rbac.refresh_tokens set revoked_at = now()
        where user_id = v_row.user_id and revoked_at is null;
        raise exception 'refresh token reuse detected; all sessions revoked';
    end if;

    if v_row.expires_at < now() then
        raise exception 'refresh token expired';
    end if;

    return query
    with new_token as (
        insert into rbac.refresh_tokens (user_id, token_hash, device_label, expires_at)
        values (v_row.user_id, encode(digest(p_new_raw_token, 'sha256'), 'hex'),
                v_row.device_label, now() + interval '30 days')
        returning id
    ),
    revoke_old as (
        update rbac.refresh_tokens
        set revoked_at = now(), replaced_by = (select id from new_token)
        where id = v_row.id
    )
    select v_row.user_id, (select id from new_token);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- SECURITY: p_user_id used to be a caller-supplied parameter -- dropped.
-- Confirmed empirically (same class of bug as grant_role below): a
-- caller-supplied "whose session is this" argument is always spoofable via
-- PostgREST RPC, so any authenticated user could have revoked anyone else's
-- sessions by just passing their target's id. current_user_id() is the only
-- trustworthy source, since it's derived server-side from the verified JWT,
-- not client input. A user can only revoke their own sessions via these
-- public entry points; an admin-driven "revoke someone else's sessions"
-- would need its own has_permission()-gated function, not this one.
create or replace function rbac.revoke_session(p_refresh_token_id uuid)
returns void as $$
    update rbac.refresh_tokens set revoked_at = now()
    where id = p_refresh_token_id and user_id = rbac.current_user_id();
$$ language sql security definer set search_path = pg_catalog, public;

create or replace function rbac.revoke_all_sessions() returns void as $$
    update rbac.refresh_tokens set revoked_at = now()
    where user_id = rbac.current_user_id() and revoked_at is null;
$$ language sql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 3b. Password reset -- spec.md §5's "straightforward to add but not
--     written here", written.
-- ------------------------------------------------------------
-- The same shape as refresh_session, deliberately: a raw token the caller
-- holds, only its sha256 stored, checked for existence, revocation and expiry
-- in that order. What differs is that a reset token is SINGLE USE and short
-- lived, because the two are doing different jobs -- a refresh token proves a
-- session is still alive, a reset token proves control of an inbox once.
create table if not exists rbac.password_reset_tokens (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references rbac.users(id) on delete cascade,
    token_hash text not null unique,     -- sha256 of the raw token; raw never stored
    issued_at  timestamptz not null default now(),
    expires_at timestamptz not null,
    used_at    timestamptz
);
create index if not exists idx_password_reset_tokens_user
    on rbac.password_reset_tokens (user_id) where used_at is null;

-- ASKING FOR A RESET SUCCEEDS WHETHER OR NOT THE ADDRESS EXISTS, and returns
-- nothing about it. An endpoint that errors on an unknown email is an account
-- enumeration oracle: it answers "is this person a customer" to anybody who
-- asks, which is a disclosure the account holder never consented to. The caller
-- generates the raw token and is responsible for delivering it (the
-- email-via-workflow-task pattern in §4.1); this only records its hash.
--
-- Returns void rather than the row id for the same reason -- a caller that can
-- tell "issued" from "not issued" has the oracle back.
create or replace function rbac.request_password_reset(
    p_email text, p_raw_token text, p_ttl interval default interval '1 hour')
returns void as $$
declare v_user_id uuid;
begin
    select id into v_user_id from rbac.users where email = p_email;
    if v_user_id is null then
        return;                          -- deliberately indistinguishable
    end if;

    -- Any earlier unused token is spent now. Two live reset tokens mean two
    -- live chances for one that leaked, and the person who just asked is
    -- holding the newest.
    update rbac.password_reset_tokens
       set used_at = now()
     where user_id = v_user_id and used_at is null;

    insert into rbac.password_reset_tokens (user_id, token_hash, expires_at)
    values (v_user_id, encode(digest(p_raw_token, 'sha256'), 'hex'), now() + p_ttl);

    insert into rbac.auth_events (user_id, event_type, detail)
    values (v_user_id, 'password_reset_requested', jsonb_build_object('ttl', p_ttl::text));
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Consuming one resets the password AND ends every session, which is not an
-- extra: the reason to reset is usually that somebody else may hold the old
-- credential, and leaving their refresh tokens alive resets nothing. That is
-- the same reasoning revoke_all_sessions exists for, applied to a user who is
-- not the caller -- there is no caller identity here at all, which is why this
-- is gated on token possession rather than on rbac.current_user_id().
create or replace function rbac.reset_password(p_raw_token text, p_new_password text)
returns uuid as $$
declare v_row rbac.password_reset_tokens;
begin
    select * into v_row from rbac.password_reset_tokens
     where token_hash = encode(digest(p_raw_token, 'sha256'), 'hex');

    if v_row.id is null then
        raise exception 'invalid reset token';
    end if;
    if v_row.used_at is not null then
        raise exception 'reset token already used';
    end if;
    if v_row.expires_at < now() then
        raise exception 'reset token expired';
    end if;

    perform rbac.set_password(v_row.user_id, p_new_password);

    update rbac.password_reset_tokens set used_at = now() where id = v_row.id;
    update rbac.refresh_tokens set revoked_at = now()
     where user_id = v_row.user_id and revoked_at is null;

    insert into rbac.auth_events (user_id, event_type, detail)
    values (v_row.user_id, 'password_reset', jsonb_build_object('token_id', v_row.id));

    return v_row.user_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 4. API keys — for agents/service accounts that shouldn't hold a
--    user password/session. Scoped, revocable, no expiry by default
--    (agents are long-running), but revocation is immediate since
--    it's a DB row, not a stateless token.
-- ------------------------------------------------------------
create table if not exists rbac.api_keys (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid references rbac.users(id) on delete cascade,  -- null = service account
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
create or replace function rbac.verify_api_key(p_raw_key text)
returns table(key_id uuid, user_id uuid, scopes text[]) as $$
    update rbac.api_keys
    set last_used_at = now()
    where key_hash = encode(digest(p_raw_key, 'sha256'), 'hex')
      and revoked_at is null
    returning id, user_id, scopes;
$$ language sql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 5. Login throttling — reuses the WORKFLOW ENGINE's rate limiter
--    (try_consume_rate_limit / rate_limits) rather than building a
--    second one. Same token-bucket, keyed by email or IP. Cross-schema
--    call, explicitly qualified (workflow.*, per this file's header note) --
--    requires workflow-engine's schema.sql to already be applied; this
--    module is not standalone-deployable without it (confirmed:
--    attempt_login() below fails outright with no fallback if
--    workflow.try_consume_rate_limit() is undefined). The bucket row
--    itself is seeded lazily inside attempt_login() on first use, not here.
-- ------------------------------------------------------------

-- security definer: needs to call verify_password() (now internal-only, §9)
-- and write auth_events without granting either directly to web_anon.
--
-- A FAILED LOGIN RETURNS NULL. IT DOES NOT RAISE, AND THAT IS THE WHOLE
-- SECURITY PROPERTY OF THIS FUNCTION.
--
-- It used to raise `invalid credentials`, one statement after consuming a rate
-- limit token and writing an auth_events row. An exception aborts the
-- transaction, and PostgREST gives each RPC its own -- so **both of those
-- writes were rolled back by the failure that caused them**. Measured, not
-- reasoned: twelve wrong passwords in a row produced `throttled = false`, zero
-- rows in auth_events, and no bucket row in workflow.rate_limits at all.
--
-- Two consequences, and each is worse than it first sounds:
--
--   * The token bucket only ever decremented on SUCCESS. §5 above exists
--     because verify_password() unthrottled is "an unrate-limited
--     password-guessing oracle" -- and login(), granted to web_anon and
--     reachable over HTTP, was exactly that. The defence was written, wired,
--     commented and inert.
--   * auth_events could record `login_success` and never `login_failed`. The
--     one event an auth audit exists for was the one event it structurally
--     could not hold, on a table whose own comment promises "every
--     auth-relevant event, queryable, no separate logging infra needed".
--
-- There is no way to keep both the raise and the writes: Postgres has no
-- autonomous transaction, and the manifest deliberately ships no dblink or
-- pg_background to fake one. So the raise is what goes. A wrong password is a
-- RESULT, not an error -- login() returns no row, the caller reads that as a
-- 401, and the throttle and the audit commit because nothing aborted.
--
-- THROTTLING still raises, deliberately: by then the bucket is empty and
-- already committed, so there is nothing left to lose to a rollback, and a
-- caller genuinely needs to tell 429 from 401. The refusals it is built from
-- are each audited on their way there.
create or replace function rbac.attempt_login(p_email text, p_plain text)
returns uuid as $$
declare v_user_id uuid;
begin
    -- FIX (empirically confirmed broken): try_consume_rate_limit() does an
    -- UPDATE against an existing
    -- rate_limits row -- with none pre-seeded, the UPDATE matches zero rows,
    -- and it fails closed (returns false). With no bucket ever created for a
    -- new email, this meant NOBODY could ever log in, for any account --
    -- confirmed directly, not a hypothetical. Seed the bucket lazily on
    -- first use rather than requiring a bucket to already exist.
    insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
    values ('login:' || lower(p_email), 5, 5, 0.0167)
    on conflict (key) do nothing;

    if not workflow.try_consume_rate_limit('login:' || lower(p_email)) then
        raise exception 'too many login attempts, try again shortly';
    end if;

    v_user_id := rbac.verify_password(p_email, p_plain);

    -- WHY it failed goes in the audit, never in the answer. The caller cannot
    -- tell a wrong password from a correct password on an account that is not
    -- active, deliberately: telling them apart is account enumeration. But an
    -- operator holding a support ticket that says "my password works and it
    -- says invalid credentials" has nothing to read, and the answer is usually
    -- the second case -- create_user_with_password makes a user
    -- `pending_verification` and NOTHING IN THIS COLLECTION ACTIVATES ONE
    -- (§1a). Recorded rather than raised, so the audit can answer it and the
    -- response still cannot.
    insert into rbac.auth_events (user_id, event_type, detail)
    values (coalesce(v_user_id, (select id from rbac.users where email = p_email)),
            case when v_user_id is null then 'login_failed' else 'login_success' end,
            jsonb_build_object('email', p_email)
            || case when v_user_id is not null then '{}'::jsonb
                    else jsonb_build_object('reason', coalesce(
                        (select case when u.password_hash is null then 'no_password'
                                     when u.status <> 'active' then 'status_' || u.status
                                     else 'bad_password' end
                           from rbac.users u where u.email = p_email),
                        'no_such_user')) end);

    return v_user_id;   -- null means "no", and null is a value that commits
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- The actual public login entry point: attempt_login() and
-- issue_refresh_token() combined atomically, so the token is always issued
-- for the SAME user_id attempt_login() just verified -- there is no code
-- path where a caller can supply a different one. Replaces the two separate
-- RPC calls spec.md's FastAPI example used to make (attempt_login then
-- issue_refresh_token), which only worked because issue_refresh_token() used
-- to accept a caller-supplied user_id directly -- exactly the bug this
-- section fixes.
create or replace function rbac.login(p_email text, p_plain text, p_device_label text, p_raw_token text)
returns table(user_id uuid, refresh_token_id uuid) as $$
declare
    v_user_id uuid;
    v_token_id uuid;
begin
    v_user_id := rbac.attempt_login(p_email, p_plain);

    -- NO ROW is the failure, not an exception. attempt_login() explains why at
    -- length: an exception rolls back the rate-limit token and the auth_events
    -- row that the failed attempt just wrote, so raising here would restore the
    -- unthrottled, unaudited password oracle those two writes exist to prevent.
    -- A caller reads zero rows as 401; 429 still arrives as an exception from
    -- the throttle, which is the one refusal with nothing left to roll back.
    if v_user_id is null then
        return;
    end if;

    v_token_id := rbac.issue_refresh_token(v_user_id, p_device_label, p_raw_token);
    return query select v_user_id, v_token_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 6. Audit log — append-only, same shape as the workflow engine's
--    task_events. Every auth-relevant event, queryable, no separate
--    logging infra needed for this.
-- ------------------------------------------------------------
create table if not exists rbac.auth_events (
    id         bigint generated always as identity primary key,
    user_id    uuid,
    event_type text not null,   -- login_success, login_failed, password_changed,
                                 -- session_revoked, role_granted, role_revoked, api_key_created
    detail     jsonb,
    -- W3C Trace Context fields, specs/README.md's OTel ground rule -- current_trace_id()
    -- propagates the caller's own trace via request.trace_id when set, so a
    -- signup that triggers a send_verification_email workflow task shares one
    -- trace_id across auth_events and workflow-engine's task_events. span_id is
    -- this event's own span, generated fresh every row.
    trace_id   text not null default rbac.current_trace_id(),
    span_id    text not null default encode(gen_random_bytes(8), 'hex'),
    at         timestamptz not null default now()
);
create index if not exists idx_auth_events_user on rbac.auth_events (user_id, at);

-- SECURITY: this is the vulnerability that motivated this whole section --
-- confirmed empirically as a full, working privilege escalation, not a
-- theoretical one. p_actor_id
-- used to be a caller-supplied parameter: any authenticated non-admin user
-- could call grant_role(<a real admin's id>, <their own id>, 'admin') and the
-- has_permission() check would pass, because it was checking the ADMIN's
-- permissions, not the CALLER's -- there was nothing tying p_actor_id to who
-- was actually making the request. Once this function is security definer
-- (needed so it can write to user_roles without granting broad INSERT to
-- `authenticated`), that escalation fully succeeds end to end, confirmed by
-- reproducing it directly. current_user_id() is the only trustworthy actor.
create or replace function rbac.grant_role(p_target_user_id uuid, p_role text)
returns void as $$
begin
    if not rbac.has_permission(rbac.current_user_id(), 'users', 'admin') then
        raise exception 'not authorized to grant roles';
    end if;
    insert into rbac.user_roles (user_id, role) values (p_target_user_id, p_role)
    on conflict do nothing;
    insert into rbac.auth_events (user_id, event_type, detail)
    values (p_target_user_id, 'role_granted', jsonb_build_object('role', p_role, 'by', rbac.current_user_id()));
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 6b. THE FIRST ADMINISTRATOR.
-- ------------------------------------------------------------
-- grant_role() cannot make the first one -- it is gated on
-- has_permission(current_user_id(), 'users', 'admin'), and on an empty
-- database nobody holds that, including the person bootstrapping. So the
-- first user_roles row has to be a plain INSERT by a connection privileged
-- enough to write the table. That is a real bootstrap step, not an oversight:
-- the alternative is a function that grants 'users'/'admin' to whoever asks
-- first.
--
-- What was wrong was leaving the step as a LIST OF ROWS for a human to copy.
-- `role_permissions.action` is free text matched with `=`, so a wrong string
-- is not an error anywhere -- it inserts, the role looks populated, and every
-- policy that consults it returns false. Found the hard way: the published
-- install guide granted ('workflow_runs','read') and ('workflow_runs','write')
-- when every RLS policy in the collection asks for 'select', so following the
-- documentation exactly produced an "admin" who then saw zero rows in
-- workflow.runs_api and had no way to tell that from "my workflow never ran".
--
-- The vocabulary is derived here rather than transcribed. Every pair below is
-- one a policy or a guard actually asks for, and the reason each is spelled
-- the way it is sits next to it -- because the failure mode of this table is
-- silence, the fix is to stop hand-copying it, not to write the list down
-- somewhere else as well.
--
-- Refuses once ANY role has been granted to anyone. That is what keeps it a
-- bootstrap rather than a back door: it is reachable only while the system has
-- no administrator, which is exactly the window in which it is not an
-- escalation. EXECUTE is not granted to web_anon or authenticated (§9's
-- revoke-first rule leaves it unreachable over PostgREST); this is run from a
-- privileged local session, like the CREATE EXTENSION it follows.
create or replace function rbac.bootstrap_admin(p_email text, p_password text,
                                                p_role text default 'admin')
returns uuid as $$
declare v_uid uuid;
begin
    -- Idempotent for the caller who already ran it, refusing for everyone else.
    -- A provisioning script that reruns must not fail, but "rerun" means the
    -- SAME identity: if this email already holds this role, hand back its id
    -- and change nothing. Creating a SECOND administrator is the thing being
    -- refused, not being called twice.
    select u.id into v_uid
      from rbac.users u join rbac.user_roles ur on ur.user_id = u.id
     where u.email = p_email and ur.role = p_role;
    if found then
        return v_uid;
    end if;

    if exists (select 1 from rbac.user_roles) then
        raise exception 'rbac is already bootstrapped -- use rbac.grant_role() as an existing admin'
            using hint = 'bootstrap_admin() only runs while no role has been granted to anyone';
    end if;

    select id into v_uid from rbac.users where email = p_email;
    if not found then
        v_uid := rbac.create_user_with_password(p_email, p_password);
    end if;

    insert into rbac.roles (name, description)
    values (p_role, 'the first administrator')
    on conflict (name) do nothing;

    -- THE grant list is rbac.permission_kinds, not a copy of it. Every pair
    -- this collection checks is declared there and constrained by the foreign
    -- key on role_permissions, so "everything" is expressible as a select
    -- rather than as nineteen literals somebody has to keep in step. A module
    -- added later is covered the moment it declares its pairs, which is what
    -- the admin role is supposed to mean.
    insert into rbac.role_permissions (role, resource, action)
    select p_role, resource, action from rbac.permission_kinds
    on conflict do nothing;

    insert into rbac.user_roles (user_id, role) values (v_uid, p_role);

    insert into rbac.auth_events (user_id, event_type, detail)
    values (v_uid, 'role_granted', jsonb_build_object('role', p_role, 'by', 'bootstrap_admin'));

    return v_uid;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 7. OPTIONAL maximal-pushdown callout: mint JWTs in SQL via pgjwt,
--    so login() returns a ready-to-use access token directly.
--    Tradeoff: the signing secret lives in the DB (in a Postgres
--    setting or a small config table), which is one more place a
--    leak matters. Most teams should mint in FastAPI instead (see
--    spec) -- this is here because "maximal pushdown" was the ask.
-- ------------------------------------------------------------
-- create or replace function rbac.login_and_mint_jwt(p_email text, p_plain text)
-- returns text as $$
-- declare
--     v_user_id uuid;
--     v_role text;
-- begin
--     v_user_id := rbac.attempt_login(p_email, p_plain);
--     select role into v_role from rbac.user_roles where user_id = v_user_id limit 1;
--     return sign(
--         json_build_object(
--             'sub', v_user_id, 'role', coalesce(v_role, 'api_user'),
--             'exp', extract(epoch from now() + interval '5 minutes')::int
--         ),
--         current_setting('app.jwt_secret')
--     );
-- end;
-- $$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 8. Tie into the workflow engine: row-level ownership so a user
--    can only see/cancel their own runs unless permitted otherwise.
--    (Requires workflow-engine/schema.sql's workflow.runs table.)
-- ------------------------------------------------------------
-- alter table workflow.runs add column owner_id uuid references rbac.users(id);
--
-- alter table workflow.runs enable row level security;
-- create policy runs_owner_or_permitted on workflow.runs for select
--   using (owner_id = rbac.current_user_id() or rbac.has_permission(rbac.current_user_id(), 'workflow_runs', 'select'));
-- create policy runs_cancel on workflow.runs for update
--   using (owner_id = rbac.current_user_id() or rbac.has_permission(rbac.current_user_id(), 'workflow_runs', 'cancel'));

-- ------------------------------------------------------------
-- 9. PostgREST role model, grants, and RLS -- not previously written
--    down anywhere; added after empirically confirming its absence was
--    exploitable, not just incomplete. Two structural rules this section
--    enforces:
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
-- ROLES ARE NOT CREATED HERE -- see roles.sql, applied once by a DBA/superuser
-- before this file. Roles are CLUSTER-level objects (shared by every database),
-- while everything else in this file is schema-level and owned by a
-- non-superuser schema owner. Those are two different privilege levels and two
-- different lifecycles, so they're two different files: a non-superuser schema
-- owner cannot CREATE ROLE (lacks CREATEROLE), which is not a limitation to
-- work around -- it's the correct boundary. Confirmed empirically: with role
-- creation inlined here, this file could only ever be loaded by a superuser,
-- which is exactly the thing the assertion below refuses to allow.
--
-- ASSERTION, not a comment: the "never let the schema owner be a cluster
-- superuser" rule stated in (b) below is CHECKED here, because a rule that
-- lives only in prose is a rule that gets violated silently. Confirmed the
-- hard way against a live PG19 beta3 stack: with a superuser schema/view
-- owner, a non-admin user reading through users_api saw EVERY row in the
-- table -- correct policies in place, and those same policies provably
-- working on a direct base-table read by the same role in the same session.
-- Superusers bypass RLS unconditionally, so an owner-privileged view owned by
-- one silently disables RLS for every caller of that view. The test harness
-- had been running as a superuser owner for this schema's entire history and
-- never caught it, because no test read through the views as a non-owner
-- until one was written specifically to.
--
-- This fails loudly at load time rather than deploying a schema whose central
-- security guarantee is silently inert.
do $$
begin
    if (select rolsuper from pg_roles where rolname = current_user) then
        raise exception
            'REFUSING TO LOAD: current_user (%) is a cluster superuser. '
            'Superusers bypass RLS unconditionally, so the owner-privileged '
            'views below (users_api, refresh_tokens_api, api_keys_api) would '
            'silently return ALL rows to every caller. Apply roles.sql first, '
            'then load this file as app_owner (psql -c ''set role app_owner;'' '
            '-f schema.sql).', current_user;
    end if;
end $$;

-- PostgREST needs USAGE on every schema it exposes -- rbac for this
-- module's own objects, public for anything not yet namespaced (and for
-- objects, like public.touch_updated_at, that are deliberately shared
-- rather than owned by one schema).
grant usage on schema rbac, public to web_anon, authenticated;

-- (a) Deny all function execution by default, then allow only the
-- functions actually meant to be public entry points. Scoped to rbac,
-- where this module's functions actually live now.
revoke execute on all functions in schema rbac from public;

grant execute on function rbac.create_user_with_password(text, text) to web_anon;
grant execute on function rbac.login(text, text, text, text) to web_anon;
grant execute on function rbac.refresh_session(text, text) to web_anon, authenticated;
-- web_anon on purpose: somebody who has forgotten their password cannot be
-- authenticated, which is the whole situation. Both are self-authenticating by
-- token possession, exactly as refresh_session is.
grant execute on function rbac.request_password_reset(text, text, interval) to web_anon;
grant execute on function rbac.reset_password(text, text) to web_anon;
grant execute on function rbac.verify_api_key(text) to web_anon, authenticated;
grant execute on function rbac.change_password(text, text) to authenticated;
grant execute on function rbac.grant_role(uuid, text) to authenticated;
grant execute on function rbac.revoke_session(uuid) to authenticated;
grant execute on function rbac.revoke_all_sessions() to authenticated;
-- has_permission()/current_user_id() are called FROM RLS policies, which
-- always run as the querying role -- both need direct EXECUTE too, not just
-- "called internally by a security definer function" (there is no
-- security-definer indirection when Postgres evaluates a USING clause).
-- Every OTHER schema's RLS policy calls these explicitly qualified
-- (rbac.current_user_id(), rbac.has_permission(...)) per this file's header
-- note, so this grant is what makes those cross-schema calls work, not a
-- widened search_path anywhere.
grant execute on function rbac.has_permission(uuid, text, text) to web_anon, authenticated;
grant execute on function rbac.current_user_id() to web_anon, authenticated;
-- set_password, verify_password, issue_refresh_token, attempt_login: stay
-- internal-only (owner-only EXECUTE), reachable only from within the
-- security-definer functions above that call them, never directly via RPC.

-- (b) RLS on every table this module owns -- deny-by-default the moment RLS
-- is enabled with no matching policy, which is exactly what anon/no-session
-- callers should get on tables this sensitive.
--
-- The three facts this section is built around, each confirmed empirically
-- against a live PG19 beta3 instance rather than reasoned about:
--   1. Table owners bypass their own RLS policies BY DEFAULT, independent of
--      superuser status.
--   2. Superusers bypass RLS unconditionally -- no flag changes that. Hence
--      the load-time assertion above: never let any of these roles be one.
--   3. users_api/refresh_tokens_api/api_keys_api are plain (owner-privileged)
--      views -- required, not incidental: a security_invoker view was tried
--      first and re-requires base-table grants, defeating the point. So every
--      read through them evaluates RLS as the VIEW OWNER, not the caller.
-- Together those mean the view owner's identity, not a policy flag, is what
-- decides whether the read path is safe. See the ENABLE-not-FORCE note below.
-- ENABLE, deliberately NOT FORCE. Getting this exactly right took three
-- rounds of live failure; the reasoning is worth keeping because both
-- obvious alternatives are wrong in ways that only show up in a correctly
-- configured deployment (a superuser-owned schema hides all of it):
--
--   * WITHOUT the split-owner design below, ENABLE alone is not enough: the
--     *_api views are owner-privileged, so a read through them evaluates RLS
--     as the VIEW's owner. If that owner also owns the tables, it bypasses
--     RLS and every caller sees every row. Reproduced directly.
--   * FORCE ROW LEVEL SECURITY is the tempting fix for that, and it IS
--     wrong here: FORCE also subjects the SECURITY DEFINER functions to RLS
--     (they run as the table owner), and with only SELECT policies in place
--     and no JWT during signup/login, every write is denied -- signup,
--     login's own auth_events insert, password changes, token issuance and
--     rotation, role grants. Also reproduced directly: `insert ...
--     returning id` failed even for the table owner, because RETURNING must
--     read the new row back through the SELECT policy.
--
-- The resolution is ownership separation, not a policy flag (roles.sql §1/§2):
--   - app_owner owns the TABLES + FUNCTIONS -> bypasses RLS (no FORCE) ->
--     the SECURITY DEFINER trusted path works, including reads during login
--     before a JWT exists.
--   - api_viewer owns ONLY THE VIEWS and is NOT the table owner -> RLS
--     applies to it normally -> the untrusted read path is filtered
--     per-request by current_user_id(), exactly as intended.
-- Both are non-superusers; §10's self-check verifies all of this at load time.
alter table rbac.users enable row level security;
alter table rbac.refresh_tokens enable row level security;
alter table rbac.api_keys enable row level security;
alter table rbac.auth_events enable row level security;
alter table rbac.user_roles enable row level security;

-- Every predicate below wraps current_user_id()/has_permission() in a scalar
-- subquery -- (select ...) -- rather than calling them bare. Both are STABLE
-- and none of their arguments depend on row data, so this looks purely
-- cosmetic, but it isn't: confirmed directly via EXPLAIN that the wrapped
-- form produces a separate InitPlan the row filter just references (evaluated
-- once), while the bare form inlines the full expression into the per-row
-- Filter with no InitPlan at all -- STABLE alone does not make the planner
-- hoist it. At the tiny scale tested this doesn't show up in the numbers,
-- but has_permission() itself runs a join against user_roles/role_permissions
-- -- at real table sizes the difference is a join-per-row-scanned versus a
-- join-once. This is a documented general Postgres RLS performance pattern,
-- not specific to this schema -- worth applying to every RLS policy written
-- for any future module, not just these five.
drop policy if exists users_self_or_admin on rbac.users;
create policy users_self_or_admin on rbac.users for select
  using (id = (select rbac.current_user_id()) or (select rbac.has_permission(rbac.current_user_id(), 'users', 'select')));
-- Readable by its owner or an admin, and by nobody else. The row holds only a
-- HASH, so this is not protecting the token -- it is protecting the fact that a
-- reset was requested, which is a signal about an account either way.
alter table rbac.password_reset_tokens enable row level security;
drop policy if exists password_reset_tokens_self_or_admin on rbac.password_reset_tokens;
create policy password_reset_tokens_self_or_admin on rbac.password_reset_tokens for select
    using (user_id = (select rbac.current_user_id())
           or (select rbac.has_permission(rbac.current_user_id(), 'password_reset_tokens', 'select')));

drop policy if exists refresh_tokens_self_or_admin on rbac.refresh_tokens;
create policy refresh_tokens_self_or_admin on rbac.refresh_tokens for select
  using (user_id = (select rbac.current_user_id()) or (select rbac.has_permission(rbac.current_user_id(), 'refresh_tokens', 'select')));
drop policy if exists api_keys_self_or_admin on rbac.api_keys;
create policy api_keys_self_or_admin on rbac.api_keys for select
  using (user_id = (select rbac.current_user_id()) or (select rbac.has_permission(rbac.current_user_id(), 'api_keys', 'select')));
drop policy if exists auth_events_self_or_admin on rbac.auth_events;
create policy auth_events_self_or_admin on rbac.auth_events for select
  using (user_id = (select rbac.current_user_id()) or (select rbac.has_permission(rbac.current_user_id(), 'auth_events', 'select')));
drop policy if exists user_roles_self_or_admin on rbac.user_roles;
create policy user_roles_self_or_admin on rbac.user_roles for select
  using (user_id = (select rbac.current_user_id()) or (select rbac.has_permission(rbac.current_user_id(), 'user_roles', 'select')));

-- Read paths for users/refresh_tokens/api_keys are VIEWS, not column-level
-- grants on the base table -- confirmed empirically that a partial
-- column-level GRANT does NOT do what it looks like it does here: PostgREST's `GET
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
create or replace view rbac.users_api as
  select id, email, status, created_at, updated_at from rbac.users;
create or replace view rbac.refresh_tokens_api as
  select id, user_id, device_label, issued_at, expires_at, revoked_at from rbac.refresh_tokens;
create or replace view rbac.api_keys_api as
  select id, user_id, label, scopes, created_at, last_used_at, revoked_at from rbac.api_keys;

-- Hand the views to api_viewer -- the step that makes RLS actually enforce on
-- the read path (roles.sql §2, and the ENABLE-not-FORCE reasoning above).
-- A view owned by the TABLE owner would bypass RLS and leak every row; owned
-- by this separate non-owner role, the same view is filtered per-request.
-- api_viewer needs its own SELECT on the base tables (it is not the owner) and
-- EXECUTE on the two functions the policies call -- policies are evaluated as
-- the view owner, so the view owner is who must be able to run them.
-- Grants BEFORE the ownership transfer, not after: Postgres re-validates the
-- view against its new owner's privileges at ALTER time, so a view handed to
-- a role that cannot yet read the underlying tables fails with "permission
-- denied for schema rbac".
grant usage on schema rbac to api_viewer;
grant select on rbac.users, rbac.refresh_tokens, rbac.api_keys to api_viewer;
grant execute on function rbac.current_user_id() to api_viewer;
grant execute on function rbac.has_permission(uuid, text, text) to api_viewer;
-- has_permission() joins these two, so the view owner must be able to read
-- them for the policy predicate to evaluate at all.
grant select on rbac.user_roles, rbac.role_permissions to api_viewer;

-- Postgres additionally requires the INCOMING owner to hold CREATE on the
-- schema at the moment of an ownership transfer. Granted narrowly for the
-- transfer and revoked immediately after: api_viewer's whole purpose is to be
-- a low-privilege identity that RLS applies to, so leaving it able to create
-- objects in this schema would undercut the point of splitting it out.
grant create on schema rbac to api_viewer;

alter view rbac.users_api owner to api_viewer;
alter view rbac.refresh_tokens_api owner to api_viewer;
alter view rbac.api_keys_api owner to api_viewer;

revoke create on schema rbac from api_viewer;

grant select on rbac.users_api to authenticated;
grant select on rbac.refresh_tokens_api to authenticated;
grant select on rbac.api_keys_api to authenticated;
-- No grant on the base tables themselves to web_anon or authenticated --
-- PostgREST should be pointed at users_api/refresh_tokens_api/api_keys_api,
-- never at users/refresh_tokens/api_keys directly, for reads. Writes to all
-- three go exclusively through the functions in (a), not REST table writes,
-- so no base-table INSERT/UPDATE/DELETE grant exists at all.

grant select on rbac.auth_events to authenticated;
grant select on rbac.user_roles to authenticated;
-- roles, role_permissions, permission_kinds: reference/catalog data, not
-- per-row sensitive -- plain table grants, no RLS needed. permission_kinds is
-- the vocabulary itself, and a caller who cannot read it cannot tell a
-- permission they lack from one that does not exist.
grant select on rbac.roles, rbac.role_permissions, rbac.permission_kinds
    to authenticated;

-- web_anon gets no table access at all -- every unauthenticated interaction
-- this module supports (signup, login, refresh, API-key auth) is a function
-- call, not a table read, so it never needed one.

-- ------------------------------------------------------------
-- 10. Self-check. Rule (b) and the write-policy scoping above are only
--     defense-in-depth if BOTH layers actually hold, so verify rather than
--     assert in prose -- this file's whole history is gaps that looked fine
--     until something read the catalog instead of the comments.
-- ------------------------------------------------------------
do $$
declare
    v_bad text;
begin
    -- (b): no write grant on any base table for the PostgREST-facing roles.
    select string_agg(format('%s.%s -> %s on %s',
                             table_schema, table_name, privilege_type, grantee), ', ')
    into v_bad
    from information_schema.role_table_grants
    where table_schema = 'rbac'
      and grantee in ('web_anon', 'authenticated')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
      and table_name in ('users','refresh_tokens','api_keys','auth_events',
                         'user_roles','roles','role_permissions');
    if v_bad is not null then
        raise exception
            'RULE (b) VIOLATED: base-table write grants exist for PostgREST roles: %. '
            'All writes must go through the SECURITY DEFINER functions in (a).', v_bad;
    end if;

    -- The owner must still be non-superuser at this point (a superuser owner
    -- silently disables RLS everywhere). Belt and braces with the assertion at
    -- the top of §9 -- cheap, and catches a SET ROLE mid-file.
    if (select rolsuper from pg_roles where rolname = current_user) then
        raise exception 'schema owner (%) is a superuser -- every RLS guarantee here is inert', current_user;
    end if;

    -- THE central invariant of this module's read path: each *_api view must
    -- be owned by a NON-SUPERUSER role that is NOT the base table's owner.
    -- Same owner -> the view bypasses RLS and returns every row to every
    -- caller (reproduced directly). Superuser -> same outcome, unconditionally.
    -- Checked from the catalog rather than trusted from the ALTER VIEW
    -- statements above, so a later edit that adds a view and forgets to
    -- reassign it fails at load time instead of leaking silently in production.
    select string_agg(format('%s (view owner %s, table owner %s)',
                             v.relname,
                             pg_get_userbyid(v.relowner),
                             pg_get_userbyid(t.relowner)), ', ')
    into v_bad
    from pg_class v
    join pg_namespace n on n.oid = v.relnamespace
    join pg_class t on t.relname = replace(v.relname, '_api', '')
                   and t.relnamespace = v.relnamespace and t.relkind = 'r'
    where n.nspname = 'rbac' and v.relkind = 'v' and v.relname like '%\_api'
      and (v.relowner = t.relowner
           or (select rolsuper from pg_roles where oid = v.relowner));
    if v_bad is not null then
        raise exception
            'VIEW OWNERSHIP INVARIANT VIOLATED: %. Each *_api view must be owned '
            'by a non-superuser role distinct from the base table owner, or RLS '
            'is bypassed on every read through it (roles.sql §2).', v_bad;
    end if;

    raise notice 'user-rbac self-check passed: no base-table write grants; non-superuser owner (%); api views owned by a separate non-superuser role', current_user;
end $$;
