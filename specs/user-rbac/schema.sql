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
    -- DEFAULT 'pending_verification', because 1a's whole argument is that
    -- nothing in this collection activates an account. The default used to be
    -- 'active', which meant the policy held only for callers who remembered to
    -- spell status out -- create_user_with_password does, and every other
    -- insert path got the opposite of what the file two hundred lines below
    -- says the system does. A default is what happens when somebody forgets,
    -- so it is exactly where the safe answer belongs.
    status        text not null default 'pending_verification'
                      check (status in ('active','disabled','pending_verification')),
    mfa_secret    text,                 -- TOTP secret, set only after MFA enrollment
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

-- AND ON A DATABASE THAT ALREADY HAS THE TABLE. `create table if not exists`
-- is a no-op there, so the column default above would have applied to fresh
-- installs only -- and the upgrade script is this file replayed, which is
-- precisely the path an existing deployment takes. Idempotent, so it costs
-- nothing on the install that just created it with this default.
alter table rbac.users alter column status set default 'pending_verification';

-- `updated_at` MAINTAINED, NOT HAND-SET. It was hand-set, in exactly one
-- place -- `set_password` writes `updated_at = now()` alongside the hash -- and
-- nowhere else, so the column on the most security-relevant table in the
-- collection did not mean "when this row last changed". It meant "when this
-- password last changed", which is a different fact under a name that promises
-- the first one.
--
-- Measured before this trigger existed:
--
--     update rbac.users set status = 'disabled' -> updated_at moved: false
--     update rbac.users set email  = ...        -> updated_at moved: false
--
-- Disabling an account is the documented way to stop one (§8, and
-- verify_api_key/refresh_session now enforce it), so the single most
-- interesting change a row can undergo was the one that left no timestamp.
--
-- This is the ground rule workflow-engine/schema.sql states for exactly this
-- column on `workflow.tasks` -- "maintained by public.touch_updated_at(), not
-- hand-set at each call site" -- and rbac was the schema still doing it the
-- other way. Every other table in the collection that carries `updated_at`
-- already has this trigger; the two that do not are this one and
-- `workflow.rate_limits`, whose `updated_at` is the token bucket's refill
-- clock rather than a system field and would be actively broken by a touch.
--
-- set_password's own assignment is left alone: it now writes the same value
-- the trigger would, so it is redundant rather than wrong, and removing it
-- would make the diff about something other than this.
create or replace trigger trg_rbac_users_touch before update on rbac.users
    for each row execute function public.touch_updated_at();

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

-- WHOSE ROWS THESE ARE, SAID IN THE CATALOG SO THE CONTRACT CAN READ IT.
--
-- A role is deployment identity, not schema -- dev/init/02-seed.sql's own
-- comment says so, and grants `admin` on that basis. The extension creates this
-- table and ships NOT ONE ROW in it: a from-zero `create extension percolate`
-- leaves it empty, and every member it ever holds was put there by this
-- deployment. pg_extension_config_dump() is Postgres's own way of saying
-- exactly that -- it marks a table inside an extension whose CONTENTS are user
-- data, which is why pg_dump has to dump them rather than trusting the
-- extension script to recreate them.
--
-- It is registered here for a second reader as well. percolate.enums() reports
-- a foreign key onto a text key by reading the referenced rows, so this table's
-- contents land in percolate.contract(); its `members` column is derived from
-- pg_extension.extconfig, so registering it is what stops
-- extension/percolate/contract.json freezing one database's data as the
-- published contract. It was not registered, and contract.json duly published
-- `member` -- a row dev/tests/rbac/01 inserts and deliberately leaves behind --
-- as part of the contract, which held CI red for three commits.
--
-- Two facts, one registration, and the pg_dump one was already true and already
-- wrong. That is the whole argument for deriving this rather than listing it
-- somewhere: a table that needs the marking needs it for a reason that predates
-- the contract.
do $$
begin
    -- ONLY INSIDE `CREATE EXTENSION` / `ALTER EXTENSION UPDATE`, which is where
    -- pg_extension_config_dump() is legal -- outside one it does not no-op, it
    -- raises, and this schema is loaded raw by dev/upgrade-converges.sh, which
    -- installs the OLD version from a git tag and so cannot go through CREATE
    -- EXTENSION at all. Unguarded, that check died on line 7948 with
    -- `pg_extension_config_dump() can only be called from an SQL script executed
    -- by CREATE EXTENSION` and took the upgrade gate with it.
    --
    -- The precondition is stated rather than caught: an `exception when
    -- feature_not_supported` here would swallow the same message when it means
    -- something else. The 'e' dependency is recorded as each object is created,
    -- so by this line the table already belongs to the extension being
    -- installed, and on an update it has belonged to it since the install.
    if exists (select 1
                 from pg_catalog.pg_depend d
                where d.classid = 'pg_class'::regclass
                  and d.objid   = 'rbac.roles'::regclass
                  and d.deptype = 'e') then
        perform pg_catalog.pg_extension_config_dump('rbac.roles', '');
    end if;
end $$;

-- WHAT "ADMIN" MEANS WHEN THE VOCABULARY GROWS UNDER IT.
--
-- `bootstrap_admin()` grants its role every pair in `permission_kinds` with a
-- SELECT rather than a list of literals, and its comment says why: "a module
-- added later is covered the moment it declares its pairs, which is what the
-- admin role is supposed to mean". That sentence was false, and measured so --
-- the select runs ONCE, at bootstrap, and every pair declared afterwards is a
-- pair the administrator does not hold:
--
--     select rbac.bootstrap_admin('root@example.com', ...);
--     insert into rbac.permission_kinds values ('widgets','select','policy ...');
--     select rbac.has_permission(<root>, 'widgets', 'select');   -> false
--
-- That is not hypothetical either: `('orgs','admin')` was declared by the
-- scope work in 0.1.4, so every database bootstrapped before it has an
-- administrator who cannot administer an org and no way to tell that from
-- "this deployment has no orgs". It is the same silent failure the
-- `permission_kinds` table two hundred lines below exists to end -- a check
-- that returns false somewhere else later, rather than an error where the
-- mistake is -- reached from the one direction that table does not cover.
--
-- So the fact is a column and the maintenance is a trigger, rather than a
-- select somebody has to remember to re-run: a role marked `grants_all` holds
-- every declared pair, now and after the next module declares one.
alter table rbac.roles add column if not exists grants_all boolean not null default false;

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
    -- The policy names are the ones rbac.add_scope_policy() generates:
    -- <table>_scoped for the read and <table>_scoped_write for the write.
    ('workflow_runs',      'select', 'policy runs_scoped'),
    ('workflow_schedules', 'select', 'policy schedules_scoped'),
    -- Agents, tool servers, skills and plugins are scoped like anything else
    -- now, so each needs a read pair alongside the authoring pair below --
    -- the override for an operator who must see every tenant's configuration.
    ('agents',             'select', 'policy agents_scoped'),
    ('tool_servers',       'select', 'policy tool_servers_scoped'),
    ('skills',             'select', 'policy skills_scoped'),
    ('plugins',            'select', 'policy plugins_scoped'),
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
-- `do update`, not `do nothing`, and the difference is only visible on an
-- UPGRADED database. `checked_by` says where the pair is consulted so that it
-- can be verified, and 0.1.4 renamed the policies that consult two of these to
-- the generated `<table>_scoped`. `do nothing` leaves the row that is already
-- there exactly as it was, so a fresh install named the new policies and every
-- upgraded database went on naming `runs_owner_or_permitted` and
-- `schedules_owner_or_permitted`, which by then existed nowhere.
--
-- Nothing could see it: `dev/upgrade-converges.sh` compares the two databases
-- OBJECT by object, and this is a row. `rbac.visibilities` above already
-- writes its vocabulary this way for the same reason -- a vocabulary that
-- carries what it MEANS has to be able to correct that meaning on the way
-- through, or the meaning is whatever it was on the day the row was first
-- inserted.
on conflict (resource, action) do update set checked_by = excluded.checked_by;

create table if not exists rbac.role_permissions (
    role     text not null references rbac.roles(name),
    resource text not null,
    action   text not null,
    primary key (role, resource, action),
    -- The point of the table above: a pair nothing checks cannot be granted.
    foreign key (resource, action)
        references rbac.permission_kinds (resource, action)
);

-- AND ON A DATABASE THAT ALREADY HAS THE TABLE, where the line above is a
-- no-op. `permission_kinds` and this foreign key were added to a table that
-- already existed, so every database created before them kept a
-- `role_permissions` with no constraint at all -- and the constraint IS the
-- point of the table above it: a pair nothing checks cannot be granted. An
-- upgraded deployment could grant `('admin','anything','whatever')` and
-- `has_permission` would answer true for a resource no policy consults.
--
-- Found by `dev/upgrade-converges.sh`, which diffs a fresh install against an
-- upgraded one and is the only thing that could have: build-sql.py enforces
-- idempotency for statements that CREATE, and `create table if not exists` is
-- perfectly idempotent while being silently incomplete. Same shape as the
-- `alter column status set default` in section 1.
--
-- Dropped before it is added because a constraint has neither OR REPLACE nor
-- IF NOT EXISTS -- build-sql.py's check_idempotent() refuses the pair written
-- the other way round. The name is the one Postgres generates for the inline
-- form, so a fresh install replaces its own constraint with an identical one
-- and the two paths land in the same place.
alter table rbac.role_permissions
    drop constraint if exists role_permissions_resource_action_fkey;
alter table rbac.role_permissions
    add constraint role_permissions_resource_action_fkey
    foreign key (resource, action)
        references rbac.permission_kinds (resource, action);

-- THE OTHER HALF OF `grants_all`: the pairs, kept current.
--
-- Two trigger points, because there are two ways a pair arrives and only one
-- of them is a running database. A module declaring its pairs at runtime --
-- the extensibility story `permission_kinds` states -- is an INSERT, and the
-- trigger below catches it. A module declaring them in the schema arrives on
-- an UPGRADE, where the replayed `insert ... on conflict do nothing` inserts
-- nothing for a pair that is already there, so the trigger sees no rows; the
-- statement after it is the convergent catch-up that covers that path, and it
-- is also what backfills the administrator this column was added for.
create or replace function rbac.grant_new_permission_kinds() returns trigger as $$
begin
    insert into rbac.role_permissions (role, resource, action)
    select r.name, k.resource, k.action
      from rbac.roles r cross join new_kinds k
     where r.grants_all
    on conflict do nothing;
    return null;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace trigger trg_permission_kinds_grant_all
    after insert on rbac.permission_kinds
    referencing new table as new_kinds
    for each statement execute function rbac.grant_new_permission_kinds();

-- The administrator that already exists, marked and caught up. `('users','admin')`
-- is the pair that MEANS deployment administrator -- it is what `grant_role()`
-- itself is gated on -- so a role holding it is the role `bootstrap_admin()`
-- created, whatever it was named. Convergent: on a fresh install nothing holds
-- it yet and both statements are no-ops, and the bootstrap sets the column
-- itself a moment later.
update rbac.roles r set grants_all = true
 where not r.grants_all
   and exists (select 1 from rbac.role_permissions rp
                where rp.role = r.name and rp.resource = 'users' and rp.action = 'admin');

insert into rbac.role_permissions (role, resource, action)
select r.name, k.resource, k.action
  from rbac.roles r cross join rbac.permission_kinds k
 where r.grants_all
on conflict do nothing;

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
-- A `sub` THAT IS NOT A UUID IS AN ANONYMOUS CALLER, NOT AN ERROR.
--
-- The cast used to be unconditional, so a token whose `sub` is anything but a
-- uuid raised `invalid input syntax for type uuid` -- and raised it from
-- wherever the function happened to be called, which is inside RLS policies and
-- inside triggers. Reproduced: a JWT with `sub` set to a plain string turns an
-- ordinary upload into
--
--     ERROR: invalid input syntax for type uuid: "u1"
--     CONTEXT: PL/pgSQL function workflow.set_run_owner() line 4
--
-- an error naming a trigger three subsystems away from the thing that is
-- actually wrong, which is the token. This collection already refuses that
-- shape of message everywhere else (check-references.py exists because two
-- error messages named remedies that did not work).
--
-- It matters because `sub` being a uuid is OUR convention, not the world's:
-- rbac.login returns rbac.users.id and the install guide mints a token around
-- it, but spec.md names SSO as a seam and no external identity provider issues
-- uuid subjects -- Auth0 writes `auth0|abc123`, Google writes a decimal string,
-- and an email is common. The first one of those to arrive would have taken
-- down every request rather than being unauthenticated.
--
-- Returning NULL is the same answer the function already gives for "no token",
-- and it stays FAIL-CLOSED: every RLS policy in this collection compares
-- against this value, and `owner_id = null` is NULL, which is not true, so an
-- unrecognised subject sees nothing. Refusing to answer and refusing to exist
-- are the same refusal here; only one of them is legible.
--
-- The regex is anchored and checked BEFORE the cast rather than after, because
-- there is no "after": the cast is what raises.
create or replace function rbac.current_user_id() returns uuid as $$
    select case
        when v ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        then v::uuid
    end
    from (select nullif(current_setting('request.jwt.claims', true), '')::json->>'sub') as t(v);
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

-- ------------------------------------------------------------
-- 2b. SCOPE -- who may see a row, as distinct from what a role may do.
--
-- has_permission() answers "may this kind of person do this to this kind of
-- thing". It has never been able to answer "may this person see THIS ROW",
-- and three different idioms grew up in the collection to fill that gap:
--
--   owner-only     agentic.sessions/runs  -- mine, forever, unshareable
--   owner-or-role  workflow.runs/schedules, every rbac.* table
--   org-or-null    aiq.nodes, content.resources, workflow.deposits
--
-- No two of them compose. An org-scoped table had no owner and an owner-scoped
-- table had no org, so "my private draft inside my org" and "a document my
-- whole org may read" were both unsayable, and agentic.agents/skills settled
-- for `using (true)` -- every authenticated caller in the deployment reads
-- every skill -- with a comment naming the column that did not exist.
--
-- Worse, the third idiom overloaded ONE value. `org_id is null` meant both
-- "shared reference data, deliberately global" and "nobody set it", and
-- world-model-ingestion/schema.sql records the measured consequence: an
-- ordinary tenant calling register_upload() without the optional org argument
-- wrote org_id NULL, and a DIFFERENT tenant read the row and retrieved its
-- text through TEXT search. The patch was content.may_access_org(), which
-- infers what the caller meant from whether their token happens to name any
-- org at all. That is a workaround for a missing column, and this is the
-- column.
--
-- Three values, one predicate, and the scope is stated rather than inferred:
--
--   private   the owner only                        (THE DEFAULT)
--   org       every member of the owning org
--   public    every authenticated caller
--
-- Orthogonal to roles, deliberately: a policy asks may_read() OR
-- has_permission(), so an administrator still reads what the role grants and a
-- scope never has to encode "except for admins".
--
-- NOT this: sharing with one NAMED user. spec.md §5's resource_grants is a
-- separate mechanism with its own revocation and expiry story, and it lands as
-- a fourth disjunct in may_read() when it lands. Coarse scope first.
-- ------------------------------------------------------------

-- THE VOCABULARY IS A TABLE, for the reason permission_kinds is one, and it
-- carries what the vocabulary MEANS rather than only its labels.
--
-- `requires_org` is the fact that lets anything refuse `visibility = 'org'` on
-- a row with no org; without it that rule would be a CHECK constraint written
-- out once per scoped table, which is sixteen homes for one fact. `rank`
-- orders the tiers so "no more open than" is comparable rather than a case
-- expression somebody writes again each time.
--
-- Spelled `private` and not `me`: it is a property of the row, and `me` would
-- be a property of whoever is reading.
--
-- A foreign key onto this table is also what publishes the vocabulary --
-- percolate.enums() reads single-column foreign keys onto a text key and returns
-- their admissible set, so every scoped column shows up in percolate.contract() with
-- no line written in contract/schema.sql and nothing to keep in step.
create table if not exists rbac.visibilities (
    scope        text primary key,
    rank         int  not null unique,
    requires_org boolean not null,
    description  text not null
);

insert into rbac.visibilities (scope, rank, requires_org, description) values
    ('private', 0, false, 'the owner only'),
    ('org',     1, true,  'every member of the owning org'),
    ('public',  2, false, 'every authenticated caller')
on conflict (scope) do update
    set rank = excluded.rank,
        requires_org = excluded.requires_org,
        description = excluded.description;

-- ORGS AND MEMBERSHIP -- the model specs/README.md defers and
-- scenarios/round-4.md names as the open one.
--
-- Until now `aiq.current_org_ids()` read an `orgs` array off the JWT and
-- nothing in Postgres said which orgs existed or who belonged to one. That is
-- a working seam and not a tenancy system: the database could not refuse a
-- token naming an org the user had been removed from, and the service minting
-- the token had no table to read in order to fill the claim honestly. Removing
-- somebody from an org took effect when their token expired, which is the one
-- moment it must not wait for.
create table if not exists rbac.orgs (
    id          uuid primary key default gen_random_uuid(),
    slug        text not null unique,
    name        text not null,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);
create or replace trigger trg_rbac_orgs_touch before update on rbac.orgs
    for each row execute function public.touch_updated_at();

-- `role` here is the role WITHIN the org (who may administer it), and is
-- deliberately not rbac.roles: those are deployment-wide capability grants,
-- and conflating "admin of this org" with "admin of this installation" is how
-- a tenant administrator ends up holding users/admin.
create table if not exists rbac.org_members (
    org_id  uuid not null references rbac.orgs(id) on delete cascade,
    user_id uuid not null references rbac.users(id) on delete cascade,
    role    text not null default 'member' check (role in ('member','admin')),
    added_at timestamptz not null default now(),
    primary key (org_id, user_id)
);
create index if not exists idx_org_members_user on rbac.org_members (user_id);

-- THE MEMBERSHIP ROWS ARE THE TRUTH; THE TOKEN MAY ONLY NARROW THEM.
--
-- A token that carries no `orgs` claim gets the caller's full membership. A
-- token that carries one gets the INTERSECTION -- so a claim can never widen
-- reach beyond what the table grants, and revoking membership takes effect on
-- the very next request rather than at token expiry. The narrowing direction
-- is kept because it is load-bearing rather than tidy: an API key or an agent
-- token issued for one org out of a user's several is exactly a claim that
-- says less than the table does.
--
-- SECURITY DEFINER, and for the same non-obvious reason has_permission() is --
-- see its header. org_members carries its own RLS policy, and that policy
-- calls this function, so an invoker-rights read here is the identical two-hop
-- cycle: policy -> function -> table -> policy. Postgres does not report it as
-- policy recursion because the self-reference is laundered through a function;
-- it reports `stack depth limit exceeded` from inside this function with
-- nothing naming RLS at all. app_owner owns both this function and the table,
-- and a table owner bypasses RLS by default, so running as the definer breaks
-- the cycle at the first hop.
--
-- SETOF rather than uuid[], for the reason aiq.current_org_ids() gave when it
-- held this job: `org_id = any (f())` gives up the SubPlan hoisting that
-- `org_id in (select f())` gets, and at real table sizes that is the
-- difference between evaluating the membership query once and once per row
-- scanned.
--
-- The empty-string guard on the raw GUC is current_user_id()'s, for its
-- reason: a pooled connection that has had request.jwt.claims SET LOCAL in any
-- prior transaction resets an unregistered custom GUC to '' rather than NULL,
-- and casting '' to jsonb throws.
create or replace function rbac.current_org_ids() returns setof uuid as $$
    with claim as (
        select nullif(current_setting('request.jwt.claims', true), '')::jsonb -> 'orgs' as orgs
    ), member_of as (
        select m.org_id from rbac.org_members m
         where m.user_id = rbac.current_user_id()
    )
    select m.org_id
      from member_of m, claim c
     where c.orgs is null
        or m.org_id::text in (select jsonb_array_elements_text(c.orgs));
$$ language sql stable security definer set search_path = pg_catalog, public;

-- THE RULE, AS TEXT, BECAUSE A POLICY CANNOT AFFORD TO CALL IT AS A FUNCTION.
--
-- This was written first as `rbac.may_read(owner_id, org_id, visibility)` and
-- every policy called it, which is the obvious shape and is 58 times slower.
--
-- MEASURED, on 52,000 rows in one table, same query, same session, PG19:
--
--     using (rbac.may_read(owner_id, org_id, visibility))   360.574 ms  792 buffers
--     using (<the text below>)                                6.205 ms  392 buffers
--
-- The reason is structural rather than tunable. §9's InitPlan finding says an
-- argument-free STABLE call wrapped in `(select ...)` is hoisted and evaluated
-- once; a function taking ROW COLUMNS has nothing constant to hoist, so the
-- usual escape is to let Postgres INLINE the function and hoist what is inside
-- it. Postgres refuses to inline any `language sql` function whose body
-- contains a sublink -- and `org_id in (select rbac.current_org_ids())` is
-- one, necessarily, because the SubPlan is the whole point. So the two
-- optimisations are mutually exclusive: a body that can be hoisted cannot be
-- inlined, and the call therefore runs the membership query once per row
-- scanned. Confirmed from the plan, not inferred -- `Filter:
-- rbac.may_read(...)` with no InitPlan at all, against `Filter: ((visibility =
-- 'public') OR (owner_id = (InitPlan expr_1).col1) OR (... (hashed SubPlan
-- any_1) ...))`.
--
-- So the expression is GENERATED into each policy rather than called from it.
-- That keeps one home for the fact -- this function is the only place the
-- sentence is written, add_scope_policy() below is the only thing that emits
-- it, and dev/tests/rbac/02 asserts every scoped table's live policy still
-- matches what this returns -- while giving every consumer the hoisted plan.
--
-- Reading a row you own is deliberately independent of scope: `private` is a
-- statement about everybody else.
--
-- Null comparisons fail closed on their own. A null owner_id against a null
-- current_user_id() is NULL rather than true, so an anonymous caller reading
-- an unowned private row gets nothing, and workflow's rule that a system-owned
-- run is "not owned by everyone" falls out rather than needing its own clause.
create or replace function rbac.scope_predicate() returns text as $fn$
    select $q$(visibility = 'public'
       or owner_id = (select rbac.current_user_id())
       or (visibility = 'org' and org_id in (select rbac.current_org_ids())))$q$;
$fn$ language sql immutable;

-- The WITH CHECK half. Same generation, same reason -- a bulk insert would pay
-- the membership query per row otherwise -- and the same three rules stated
-- once:
--   you may write only rows you own,
--   into an org you belong to,
--   and 'org' needs an org.
--
-- The first arm is content.may_access_org()'s, kept: a connection with no
-- request.jwt.claims at all is a service connection, a migration or a psql
-- session, and is not a caller this is about.
create or replace function rbac.scope_write_predicate() returns text as $fn$
    select $q$(nullif(current_setting('request.jwt.claims', true), '') is null
       or ((owner_id is null or owner_id = (select rbac.current_user_id()))
           and (org_id is null or org_id in (select rbac.current_org_ids()))
           and (visibility <> 'org' or org_id is not null)))$q$;
$fn$ language sql immutable;

-- THE SAME TWO RULES AS FUNCTIONS, for the callers that are not policies.
--
-- These are what a SECURITY DEFINER function calls -- once, about one row it
-- has already fetched -- where the per-row cost above does not arise and a
-- readable name is worth more than an inlined expression. may_write() is the
-- direct replacement for content.may_access_org() at its ten call sites in
-- world-model-ingestion and three in trace-field.
--
-- That function lived in the content schema and was called from trace-field's
-- policies, so the rule about who may write into which org was owned by
-- whichever subsystem happened to need it first and imported across a boundary
-- by the next. It also had to INFER the caller's intent -- "a token that names
-- no org is a single-tenant deployment, so null means ours" -- because there
-- was no column in which to say it. There is now, so the inference is gone: a
-- null org with `public` is a deliberate global write, and a null org with
-- `org` is refused by the trigger below rather than guessed about.
--
-- Not STRICT: owner_id and org_id are legitimately null on the same row (an
-- unowned public reference node), and a strict function would answer null for
-- exactly the row the rule is clearest about.
create or replace function rbac.may_read(
    p_owner_id uuid, p_org_id uuid, p_visibility text
) returns boolean as $$
    select p_visibility = 'public'
        or p_owner_id = rbac.current_user_id()
        or (p_visibility = 'org'
            and p_org_id is not null
            and p_org_id in (select rbac.current_org_ids()));
$$ language sql stable parallel safe;

create or replace function rbac.may_write(
    p_owner_id uuid, p_org_id uuid, p_visibility text
) returns boolean as $$
    select nullif(current_setting('request.jwt.claims', true), '') is null
        or ((p_owner_id is null or p_owner_id = rbac.current_user_id())
            and (p_org_id is null or p_org_id in (select rbac.current_org_ids()))
            and (p_visibility <> 'org' or p_org_id is not null));
$$ language sql stable parallel safe;

-- The org half on its own, for callers that have an org and not yet a row --
-- "may I act inside this tenancy at all". This is the direct rename of
-- content.may_access_org(), whose thirteen call sites across
-- world-model-ingestion and trace-field are what makes it worth having as a
-- name rather than as a third of may_write().
--
-- ONE ARM OF THAT FUNCTION IS DELIBERATELY GONE. It refused a null org to any
-- caller whose token named one, and the reasoning was sound for the schema it
-- was written against: `org_id is null` meant "every tenant reads this", so
-- writing one was the widest cross-tenant act available and not the absence of
-- an act. It was measured as a real disclosure, through nothing more than
-- register_upload()'s optional argument defaulting to null.
--
-- Scope removes the premise rather than the check. A null org is now just a
-- row with no tenancy; whether anyone else reads it is `visibility`, which
-- defaults to `private`. Publishing to everyone is spelled `public` and is a
-- thing somebody chose, so the act that needed refusing cannot be performed by
-- omission any more -- which is the outcome that check was standing in for.
create or replace function rbac.may_access_org(p_org_id uuid)
returns boolean as $$
    select nullif(current_setting('request.jwt.claims', true), '') is null
        or p_org_id is null
        or p_org_id in (select rbac.current_org_ids());
$$ language sql stable parallel safe;

-- WHAT A WRITE PATH SHOULD SET WHEN NOBODY SAID.
--
-- Every SECURITY DEFINER writer in this collection -- register_upload,
-- upsert_agent, upsert_skill, apply_plugin -- bypasses RLS, so the column
-- default cannot help it: it will cheerfully write a `private` row with a null
-- owner, which is a row NOBODY can read, including whoever just created it.
-- That is not a theoretical failure mode; it is what each of those functions
-- did the moment the columns existed, and the symptom is an upload that
-- succeeds and then cannot be found.
--
-- So the rule is stated once, here, and every writer calls it:
--
--   an org is named           -> org      (working inside a tenancy, whoever
--                                          is doing the working)
--   no org, no request identity -> public  (an operator installing deployment
--                                          configuration: the seeded agents,
--                                          the sample corpus, a migration)
--   no org, a caller            -> private (yours until you say otherwise)
--
-- The middle arm is the one worth arguing with, so: it is the same signal
-- may_write() already treats as trusted, it is unreachable over PostgREST
-- (which always sets the GUC), and the alternative -- seeding the extension's
-- own agents as `private` with a null owner -- installs configuration no user
-- can see and no user can fix.
create or replace function rbac.default_visibility(p_org_id uuid default null)
returns text as $$
    select case
        -- THE ORG IS CHECKED FIRST, and the order is the whole correctness of
        -- this function. Written the other way round -- claimless first -- a
        -- caller who NAMED an org and had no request identity got `public`:
        -- the migration, the seed and every test fixture that registers
        -- content on a tenant's behalf published that tenant's document to the
        -- deployment. Measured as `org B can see org A's resource row` from
        -- dev/tests/content/01, which is the exact sentence §4b's original bug
        -- was reported in, reached from the opposite direction. Naming an org
        -- is a statement about scope in any reading; nothing should override
        -- it.
        when p_org_id is not null then 'org'
        -- No org and no request identity: an operator installing deployment
        -- configuration -- the seeded agents, the sample corpus, a migration.
        -- These are for everyone by construction, and it is the only case
        -- where "for everyone" is not a decision somebody should have to make.
        when nullif(current_setting('request.jwt.claims', true), '') is null then 'public'
        else 'private'
    end;
$$ language sql stable parallel safe;

-- AND THE SAME RULE AT A LAYER NOTHING CAN ROUTE AROUND.
--
-- The write policy holds it for callers arriving through RLS. Every SECURITY
-- DEFINER write path in this collection bypasses RLS by design -- that is what
-- makes register_upload() and complete_task() work -- so a rule enforced only
-- in a policy is not enforced on the paths that have historically got it
-- wrong. register_upload() is precisely the function that wrote the row two
-- tenants could read.
--
-- A trigger and not a CHECK constraint, because the fact is `requires_org` in
-- rbac.visibilities and a CHECK cannot read another table. Written out inline
-- it would be sixteen copies of one sentence, and a fourth scope added later
-- would need all sixteen edited. One function, attached by
-- add_scope_columns() to every table that gets the columns, reading the
-- vocabulary -- so the day `team` is added, nothing here changes.
create or replace function rbac.enforce_visibility() returns trigger as $$
declare v_requires_org boolean;
begin
    select requires_org into v_requires_org
      from rbac.visibilities where scope = new.visibility;
    if v_requires_org and new.org_id is null then
        raise exception
            'visibility ''%'' requires an org_id, and this row has none',
            new.visibility
            using hint = 'set org_id, or use a visibility that does not '
                         'require one (see rbac.visibilities.requires_org)';
    end if;
    return new;
end;
$$ language plpgsql;

-- ADDING SCOPE TO A TABLE IS ONE CALL, not a paragraph of DDL repeated per
-- consumer -- which is the only way sixteen tables end up with identical
-- columns, an identical foreign key, an identical trigger and identical
-- indexes. The failure this prevents is specific and quiet: a table that gets
-- the `visibility` column and not the trigger accepts `org` with a null org
-- and reads as scoped while being invisible to everyone.
--
-- regclass rather than text for the argument: Postgres resolves it before the
-- function body runs, so an unknown table fails at the call rather than inside
-- a format() string, and there is no name to inject through.
--
-- The `alter column ... set default` after `add column if not exists` is §1's
-- lesson about users.status: `if not exists` is a no-op on a table that
-- already has the column, so on every database that already ran an earlier
-- version the default would silently be whatever it was before. The upgrade
-- script is this file replayed, which is exactly that path.
--
-- The indexes are created only when nothing already leads with that column.
-- agentic.runs carries (owner_id, created_at desc) and workflow.runs carries
-- idx_runs_owner; a second index on the leading column of an existing one is
-- write cost for no read.
create or replace function rbac.add_scope_columns(
    p_table regclass,
    -- WHAT EXISTING ROWS WITH NO ORG BECOME, and it is the entire upgrade
    -- story for this change, so it lives here rather than in
    -- specs/migrations/.
    --
    -- A prepended migration delta cannot express this: the delta runs BEFORE
    -- the replayed schema, so at that point the `visibility` column does not
    -- exist on the database being upgraded and there is nothing to backfill
    -- into. What CAN express it is the statement that adds the column, which
    -- is this one, and which knows whether it is adding it for the first time.
    --
    -- The value differs per table because the idiom being replaced differed:
    --
    --   'public'  for the tables that were org-or-null -- aiq.nodes,
    --             content.resources, workflow.deposits. There, `org_id is
    --             null` genuinely meant "every tenant reads this", so
    --             backfilling anything else would HIDE rows that were visible,
    --             and the sample graph's shared tier is exactly that.
    --   'public'  for agentic.agents/skills/tool_servers/plugins, whose policy
    --             was literally `using (true)`.
    --   'private' for the owner-scoped tables -- workflow.runs,
    --             agentic.sessions -- where nobody but the owner could ever
    --             see a row and 'public' would be a disclosure.
    --
    -- Rows that DO have an org always become 'org' regardless, because that is
    -- what an org_id meant on every one of those tables.
    --
    -- The default is 'private' so that a caller who does not think about it
    -- gets the fail-closed answer; the tables above each pass their own.
    p_backfill_visibility text default 'private'
) returns void as $$
declare v_tbl text; v_added boolean;
begin
    select c.relname into v_tbl from pg_class c where c.oid = p_table;

    -- Whether THIS call is the one adding the column decides whether the
    -- backfill runs. The schema is replayed on every upgrade, so a backfill
    -- that ran unconditionally would rewrite `visibility` on every existing
    -- row at every upgrade -- silently undoing every sharing decision anyone
    -- had made since. Once is a migration; every time is data loss with a
    -- changelog entry.
    v_added := not exists (
        select 1 from pg_attribute a
         where a.attrelid = p_table and a.attname = 'visibility'
           and not a.attisdropped);

    execute format(
        'alter table %s add column if not exists owner_id uuid references rbac.users(id)', p_table);
    execute format(
        'alter table %s add column if not exists org_id uuid', p_table);
    -- The org foreign key is stated separately rather than inline, because
    -- `add column if not exists` is a NO-OP on a table that already has the
    -- column -- and most of the tables adopting scope already have an org_id
    -- that was never a reference to anything. aiq.nodes, content.resources and
    -- workflow.schedules all carried a bare uuid, so an org_id naming no org
    -- was a row nobody could ever see and nothing could report.
    execute format('alter table %s drop constraint if exists %I',
                   p_table, v_tbl || '_org_id_fkey');
    execute format(
        'alter table %s add constraint %I foreign key (org_id) references rbac.orgs(id)',
        p_table, v_tbl || '_org_id_fkey');
    -- Added NULLABLE, backfilled, then made NOT NULL -- three statements where
    -- one would do on an empty table, because on a table with rows in it the
    -- one-statement form fills every row with the DEFAULT and the backfill has
    -- nowhere left to run.
    execute format(
        'alter table %s add column if not exists visibility text', p_table);
    if v_added then
        execute format(
            'update %s set visibility = case when org_id is null then %L else ''org'' end',
            p_table, p_backfill_visibility);
    end if;
    execute format(
        'update %s set visibility = %L where visibility is null',
        p_table, p_backfill_visibility);
    execute format(
        'alter table %s alter column visibility set not null', p_table);
    -- Restated after the add for §1's reason about users.status: `add column
    -- if not exists` is a no-op on a database that already has the column, so
    -- a default stated only there would apply to fresh installs alone -- and
    -- the upgrade script is this file replayed, which is precisely the path an
    -- existing deployment takes.
    execute format(
        'alter table %s alter column visibility set default ''private''', p_table);

    -- Dropped before added: a constraint has neither OR REPLACE nor IF NOT
    -- EXISTS, and build-sql.py's idempotency check refuses the pair written
    -- the other way round.
    execute format('alter table %s drop constraint if exists %I',
                   p_table, v_tbl || '_visibility_fkey');
    execute format(
        'alter table %s add constraint %I foreign key (visibility) references rbac.visibilities(scope)',
        p_table, v_tbl || '_visibility_fkey');

    if not exists (select 1 from pg_index i
                   join pg_attribute a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
                   where i.indrelid = p_table and a.attname = 'org_id') then
        execute format('create index %I on %s (org_id) where org_id is not null',
                       'idx_' || v_tbl || '_org', p_table);
    end if;
    if not exists (select 1 from pg_index i
                   join pg_attribute a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
                   where i.indrelid = p_table and a.attname = 'owner_id') then
        execute format('create index %I on %s (owner_id)',
                       'idx_' || v_tbl || '_owner', p_table);
    end if;

    execute format(
        'create or replace trigger trg_%s_visibility before insert or update on %s '
        'for each row execute function rbac.enforce_visibility()', v_tbl, p_table);
end;
$$ language plpgsql;

-- Membership administration, following grant_role()'s shape exactly --
-- including the lesson it was rewritten for: the TARGET is a parameter and the
-- ACTOR never is. p_actor_id as an argument was a working privilege escalation
-- there, and would be the identical one here.
--
-- Either a deployment-wide users/admin or an admin OF THAT ORG may write
-- membership, which is what makes tenant self-administration possible without
-- handing a tenant the installation.
create or replace function rbac.add_org_member(
    p_org_id uuid, p_user_id uuid, p_role text default 'member'
) returns void as $$
begin
    if not (rbac.has_permission(rbac.current_user_id(), 'orgs', 'admin')
            or exists (select 1 from rbac.org_members m
                        where m.org_id = p_org_id
                          and m.user_id = rbac.current_user_id()
                          and m.role = 'admin')) then
        raise exception 'not authorized to administer this org';
    end if;
    insert into rbac.org_members (org_id, user_id, role)
    values (p_org_id, p_user_id, p_role)
    on conflict (org_id, user_id) do update set role = excluded.role;
    insert into rbac.auth_events (user_id, event_type, detail)
    values (p_user_id, 'org_member_added',
            jsonb_build_object('org_id', p_org_id, 'role', p_role,
                               'by', rbac.current_user_id()));
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace function rbac.remove_org_member(p_org_id uuid, p_user_id uuid)
returns void as $$
begin
    if not (rbac.has_permission(rbac.current_user_id(), 'orgs', 'admin')
            or exists (select 1 from rbac.org_members m
                        where m.org_id = p_org_id
                          and m.user_id = rbac.current_user_id()
                          and m.role = 'admin')) then
        raise exception 'not authorized to administer this org';
    end if;
    delete from rbac.org_members where org_id = p_org_id and user_id = p_user_id;
    insert into rbac.auth_events (user_id, event_type, detail)
    values (p_user_id, 'org_member_removed',
            jsonb_build_object('org_id', p_org_id, 'by', rbac.current_user_id()));
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- The pairs the two functions and the two policies below consult, declared so
-- role_permissions' foreign key will accept them. bootstrap_admin() grants
-- every pair in permission_kinds, so the first administrator picks these up
-- with no line added there.
insert into rbac.permission_kinds (resource, action, checked_by) values
    ('orgs',        'select', 'policy orgs_member_visible'),
    ('orgs',        'admin',  'rbac.add_org_member / rbac.remove_org_member'),
    ('org_members', 'select', 'policy org_members_own_orgs')
on conflict (resource, action) do update set checked_by = excluded.checked_by;

-- ADDING SCOPE TO A TABLE IS TWO CALLS, AND NEITHER IS A POLICY SOMEBODY WROTE.
--
--     select rbac.add_scope_columns('<schema>.<table>');
--     select rbac.add_scope_policy ('<schema>.<table>', '<resource>');
--
-- That is the whole of what a consuming module writes, and the second call
-- generates exactly this, from scope_predicate() and scope_write_predicate():
--
--   create policy <t>_scoped on <schema>.<table> for select
--     using ((visibility = 'public'
--             or owner_id = (select rbac.current_user_id())
--             or (visibility = 'org' and org_id in (select rbac.current_org_ids())))
--            or (select rbac.has_permission(rbac.current_user_id(), '<resource>', 'select')));
--
-- Generated rather than written out, because it has to be written out --
-- calling may_read() from the policy measured 58x slower (see its header) --
-- and sixteen hand-copies of a security predicate is how one of them ends up
-- subtly different from the other fifteen with nothing to notice. The
-- expression has one home, every table gets that home's current text, and
-- dev/tests/rbac/02 asserts each live policy still equals what
-- scope_predicate() returns rather than trusting that nobody edited one.
--
-- Every arm is wrapped in (select ...) and none takes a row column, so §9's
-- InitPlan hoisting applies to all of them: the caller's id and org set are
-- each computed once per query rather than once per row scanned.
--
-- The `<resource>` argument is optional and omitting it means no role
-- override -- correct for a table where a deployment-wide permission to read
-- every tenant's rows should not exist at all.
--
-- A table whose visibility DERIVES from another's (tasks from runs, chunks
-- from resources, node_keys from nodes) takes neither call: it keeps its
-- `exists (select 1 from <parent> ...)` join. Two copies of one tenancy fact
-- is what let node_keys.org_id drift from nodes.org_id and made LOOKUP return
-- nothing while reporting no such key.
create or replace function rbac.add_scope_policy(
    p_table regclass, p_resource text default null
) returns void as $$
declare v_tbl text; v_using text;
begin
    select c.relname into v_tbl from pg_class c where c.oid = p_table;

    v_using := rbac.scope_predicate();
    if p_resource is not null then
        v_using := v_using || format(
            E'\n       or (select rbac.has_permission(rbac.current_user_id(), %L, ''select''))',
            p_resource);
    end if;

    execute format('alter table %s enable row level security', p_table);
    -- Dropped before created, for the reason every policy in this collection
    -- is: CREATE POLICY has no OR REPLACE, and an absent policy is not the
    -- same as a corrected one on a database that already has the old text.
    execute format('drop policy if exists %I on %s', v_tbl || '_scoped', p_table);
    execute format('create policy %I on %s for select using (%s)',
                   v_tbl || '_scoped', p_table, v_using);
    execute format('drop policy if exists %I on %s', v_tbl || '_scoped_write', p_table);
    execute format('create policy %I on %s for insert with check (%s)',
                   v_tbl || '_scoped_write', p_table, rbac.scope_write_predicate());
end;
$$ language plpgsql;

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
        -- REUSE OF A ROTATED-AWAY TOKEN: possible theft, so every live session
        -- for that user ends here. Two things about these six lines, both
        -- learned by executing them rather than by reading them, and both the
        -- reason this branch had never once done what its message claimed.
        --
        -- `t.user_id`, not `user_id`. This function RETURNS TABLE(user_id ...),
        -- so `user_id` inside its body is the output parameter, and an UPDATE
        -- whose WHERE mentions it is `column reference "user_id" is ambiguous`
        -- -- raised at execution, from the one branch nothing had ever entered.
        -- Every caller reads any error here as "session invalid" (spec.md
        -- §4.3), so the wrong error and the right one are indistinguishable
        -- from outside: theft detection reported success and revoked nothing.
        -- The alias is what makes the statement mean the column.
        --
        -- AND NO RAISE, for attempt_login's reason (§5) applied to the one
        -- other place in this file that writes before it refuses: a RAISE
        -- aborts the transaction the revocation is in, so `raise 'all sessions
        -- revoked'` was a sentence that undid itself. The status branch below
        -- already reasoned this out and chose to refuse WITHOUT writing; this
        -- branch has to write, so it is the refusal that has to go. No row is
        -- the failure, exactly as login() returns no row for a bad password,
        -- and for the identical reason.
        update rbac.refresh_tokens t set revoked_at = now()
        where t.user_id = v_row.user_id and t.revoked_at is null;
        insert into rbac.auth_events (user_id, event_type, detail)
        values (v_row.user_id, 'refresh_reuse_detected',
                jsonb_build_object('token_id', v_row.id,
                                   'device_label', v_row.device_label,
                                   'replaced_by', v_row.replaced_by));
        return;
    end if;

    if v_row.expires_at < now() then
        raise exception 'refresh token expired';
    end if;

    -- The same status hole verify_api_key had, on the other long-lived
    -- credential. Rotation issues a NEW 30-day token every time, so a session
    -- that predates a disable never expires on its own -- disabling an account
    -- stopped its password logins and left it signed in forever on every
    -- device it was already signed in on.
    --
    -- Refused rather than revoked, and the distinction is the one §5 records
    -- for attempt_login: a RAISE aborts the transaction, so revoking the chain
    -- here and then raising would roll the revocation back and leave the very
    -- state this branch exists to end. The refusal is enough -- the token
    -- cannot be exchanged while the account is not active, and re-activating
    -- restores the sessions that were legitimately open, which is the correct
    -- reading of a suspension. Ending them for good is what revoke_all_sessions
    -- is for, and it is a separate, deliberate act.
    if (select status from rbac.users where id = v_row.user_id) <> 'active' then
        raise exception 'account is not active';
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
--
-- THE CALLER SUPPLIES THE SECRET, WHICH IS WHY THIS IS NOT A PUBLIC ENDPOINT.
--
-- `p_raw_token` is the reset credential itself, chosen by whoever calls this.
-- That is correct for a TRUSTED caller -- a delivery path that mints a token,
-- stores its hash here and emails the raw one, which is the shape §4.1
-- describes -- and it is a complete account takeover for an anonymous one.
-- EXECUTE used to be granted to `web_anon` (§9), with the reasoning that it is
-- "self-authenticating by token possession, exactly as refresh_session is".
-- It is not, and the difference is the whole vulnerability: refresh_session
-- VERIFIES a token the server issued, while this one ISSUES the token the
-- caller named. So:
--
--     set role web_anon;
--     select rbac.request_password_reset('victim@example.com', 'token-i-picked');
--     select rbac.reset_password('token-i-picked', 'my new password');
--
-- took over any account whose address you knew, over HTTP, with no email
-- involved at any point. Same shape as the two spoofable-argument bugs already
-- recorded in this file (`issue_refresh_token`'s caller-supplied user_id,
-- `revoke_session`'s p_user_id), one step worse: what the caller controls here
-- is not the identity but the secret.
--
-- The grant is gone (§9). `reset_password` stays on web_anon, because that one
-- genuinely IS token possession. What this leaves is a system with no anonymous
-- way to START a reset -- deliberately, and stated rather than papered over,
-- exactly as §1a states the email-verification gap: the missing piece is a
-- delivery path, and inventing one inside a security fix is how a subsystem
-- grows a feature nobody specified. `dev/tests/rbac/06-password-reset.sql`
-- pins both halves, so building delivery is a deliberate act that updates a
-- test rather than a surprise.
--
-- THROTTLED, and before the lookup rather than after it. Minting reset tokens
-- is a write an untrusted front end can drive at whatever rate it is willing
-- to relay, each one spending the outstanding token for that address -- so an
-- unthrottled reset request is a denial of service against the account holder,
-- who never gets to use the link they were sent. The bucket is consumed before
-- `rbac.users` is consulted, so a throttled unknown address and a throttled
-- real one are still indistinguishable and the oracle stays shut.
create or replace function rbac.request_password_reset(
    p_email text, p_raw_token text, p_ttl interval default interval '1 hour')
returns void as $$
declare v_user_id uuid;
begin
    -- KEYED ON THE ADDRESS THIS FUNCTION ACTUALLY LOOKS UP, which was
    -- `lower(p_email)` while the lookup below is an exact match on a
    -- case-sensitive `text` column with a plain unique index. Two accounts
    -- differing only in case are two accounts everywhere else in this file --
    -- login, reset, role assignment all compare with `=` -- so lowercasing
    -- here alone gave them one shared bucket, and either could spend the
    -- other's allowance.
    --
    -- Whether email SHOULD be case-insensitive is a real question and a
    -- different one: it is a unique index and a comparison at every call site,
    -- which is a migration rather than a line. Recorded here rather than half
    -- applied, because a throttle that folds case while the lookup does not is
    -- the worst of both readings.
    insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
    values ('reset:' || p_email, 3, 3, 0.0056)   -- 3 burst, ~1 per 3 min
    on conflict (key) do nothing;

    if not workflow.try_consume_rate_limit('reset:' || p_email) then
        raise exception 'too many password reset requests for that address, try again shortly';
    end if;

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
--
-- THE OWNER'S STATUS IS PART OF THE CHECK, and it was not. `status` was
-- enforced in exactly one place in this file -- verify_password -- so
-- `update rbac.users set status = 'disabled'`, the only lever the column
-- offers and the one an operator reaches for when an account is compromised
-- or an employee leaves, stopped password logins and left every API key that
-- person held working indefinitely. A credential path that ignores the
-- account's own status is not a second factor, it is a bypass.
--
-- `user_id is null` is a SERVICE ACCOUNT (the column's own comment says so)
-- and has no user whose status could be consulted; its revocation is
-- revoked_at, which is already checked. Revoking a key stays the way to kill
-- one key; disabling the user is now the way to kill all of theirs at once.
create or replace function rbac.verify_api_key(p_raw_key text)
returns table(key_id uuid, user_id uuid, scopes text[]) as $$
    update rbac.api_keys
    set last_used_at = now()
    where key_hash = encode(digest(p_raw_key, 'sha256'), 'hex')
      and revoked_at is null
      and (api_keys.user_id is null
           or exists (select 1 from rbac.users u
                       where u.id = api_keys.user_id and u.status = 'active'))
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

    -- ACTIVATED, because this function's whole job is producing an account
    -- that works. create_user_with_password inserts `pending_verification`
    -- and verify_password requires `active` (§1a), so without this line
    -- bootstrap_admin accepted a password, stored it, returned an id, and
    -- handed back the one account in the system that could never log in --
    -- while §1a's stated workaround for exactly that is the UPDATE below.
    --
    -- This is NOT the email-verification gap being quietly closed. It is
    -- closed for THIS caller only, and the reason is that there is no inbox to
    -- prove control of: bootstrap_admin is unreachable over PostgREST and runs
    -- from a privileged local session, so the operator typing the address IS
    -- the verification. Every other account still goes through §1a's gap, and
    -- the assertion that pins it is untouched.
    update rbac.users set status = 'active' where id = v_uid and status <> 'active';

    -- `grants_all`, which is what makes the SELECT below stay true rather than
    -- being true once. See the column's own comment in section 2.
    insert into rbac.roles (name, description, grants_all)
    values (p_role, 'the first administrator', true)
    on conflict (name) do update set grants_all = true;

    -- THE grant list is rbac.permission_kinds, not a copy of it. Every pair
    -- this collection checks is declared there and constrained by the foreign
    -- key on role_permissions, so "everything" is expressible as a select
    -- rather than as nineteen literals somebody has to keep in step. A module
    -- added later is covered the moment it declares its pairs, which is what
    -- the admin role is supposed to mean -- and is true because of
    -- `roles.grants_all` and the trigger on `permission_kinds` (section 2),
    -- not because of this statement, which runs exactly once.
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
-- reset_password on web_anon on purpose: somebody who has forgotten their
-- password cannot be authenticated, which is the whole situation, and this one
-- IS self-authenticating by token possession, exactly as refresh_session is.
--
-- request_password_reset is NOT, and used to be granted here on the reasoning
-- that it was -- see its own header. It takes the raw token as an argument, so
-- granting it to web_anon let an anonymous caller mint a reset credential of
-- its own choosing for any address and redeem it on the next line. It stays
-- owner-only: the caller that mints and delivers is a trusted one.
grant execute on function rbac.reset_password(text, text) to web_anon;

-- AND EXPLICITLY REVOKED, because DELETING THE GRANT LINE FIXES NOTHING THAT
-- IS ALREADY BROKEN.
--
-- `create or replace function` preserves the existing ACL, and the upgrade
-- script is this schema REPLAYED -- so removing the grant above corrects a
-- fresh install and leaves every database that is already running 0.1.2
-- exactly as it was. That is every database that has the vulnerability.
--
-- MEASURED, after making precisely that mistake: install the published
-- percolate--0.1.2.sql, replay percolate--0.1.2--0.1.3.sql over it, and
-- `has_function_privilege('web_anon', 'rbac.request_password_reset(text,text,
-- interval)', 'execute')` still answered true. The security fix propagated to
-- new installs only, which is the half that never had the problem.
--
-- Same shape as the policies and constraints in this collection, which are
-- dropped before they are created for the same reason: a REVOKE has no IF NOT
-- EXISTS, an absent GRANT is not a revocation, and an idempotent script has to
-- state the removal rather than the absence. The blanket `revoke execute on
-- all functions in schema rbac from public` above does not cover this -- it
-- takes away PUBLIC's grant, and this one was made to a named role.
--
-- `authenticated` is in the list although it was never granted: this is the
-- statement of who may NOT call it, and the two PostgREST-facing roles are the
-- answer regardless of which of them happened to hold it.
revoke execute on function rbac.request_password_reset(text, text, interval)
    from web_anon, authenticated;
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
-- §2b's scope predicates, granted for exactly the reason above: they are
-- called from RLS policies in five other schemas, and a USING clause has no
-- security-definer indirection to hide behind. current_org_ids() is granted
-- rather than the membership table -- it is SECURITY DEFINER, so no caller
-- needs SELECT on rbac.org_members to be scoped by it, which is the point.
--
-- `worker` is on this list and holds no table grant anywhere (rbac/02 asserts
-- that). It needs may_write() because content's SECURITY DEFINER write path
-- calls it while running work on a user's behalf, exactly as it needed
-- content.may_access_org() before.
grant execute on function rbac.current_org_ids() to web_anon, authenticated, api_viewer, worker;
grant execute on function rbac.may_read(uuid, uuid, text) to web_anon, authenticated, api_viewer, worker;
grant execute on function rbac.may_write(uuid, uuid, text) to web_anon, authenticated, api_viewer, worker;
grant execute on function rbac.may_access_org(uuid) to web_anon, authenticated, api_viewer, worker;
-- scope_predicate/scope_write_predicate/default_visibility are NOT granted,
-- and surface.sql's reverse check is what settled it: they were, and it
-- reported them as reachable-but-undeclared, which is the right complaint.
--
-- None of the three is called at query time. The two predicates are consumed
-- by add_scope_policy() at DDL time and what ends up in a policy is their
-- expanded TEXT, not a call to them; default_visibility() is called only from
-- inside SECURITY DEFINER writers, which run as app_owner. So the grants bought
-- nothing and widened the anonymous surface by three functions -- exactly the
-- allow-by-omission this section exists to refuse.
grant execute on function rbac.add_org_member(uuid, uuid, text) to authenticated;
grant execute on function rbac.remove_org_member(uuid, uuid) to authenticated;
-- add_scope_columns() executes DDL and stays owner-only, like
-- aiq.register_entity_table(): a deployment calls it during migration, never
-- a caller over REST.

-- The vocabulary is readable by everyone, and that is not a leak -- it is the
-- published contract. percolate.enums() resolves a foreign key onto a text key by
-- READING the referenced rows, and it runs as its caller, so without this
-- grant every scoped column would come back from percolate.contract() with an empty
-- admissible set: a vocabulary reported as unconstrained rather than as
-- three values, which is the worst direction for that error to point.
-- NOT to `worker`, and the omission is a rule rather than an oversight:
-- rbac/02 §4 asserts that no service role holds a direct table grant anywhere,
-- because a worker's only reachable surface being SECURITY DEFINER functions
-- is what makes "bring your own worker" safe to offer. A worker never needs to
-- read the vocabulary -- it calls functions that enforce it.
grant select on rbac.visibilities to web_anon, authenticated, api_viewer;
-- set_password, verify_password, issue_refresh_token, attempt_login,
-- request_password_reset: stay internal-only (owner-only EXECUTE), reachable
-- only from within the security-definer functions above that call them, or
-- from a trusted local session, never directly via RPC.

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
alter table rbac.orgs enable row level security;
alter table rbac.org_members enable row level security;
-- The vocabulary gets RLS ENABLEd with an explicitly permissive policy rather
-- than left off, for agentic's reason: "no policy" reads as an oversight and a
-- policy that says true reads as a decision. There is nothing tenant-specific
-- about the fact that 'org' requires an org.
alter table rbac.visibilities enable row level security;

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

-- An org is visible to its members. Not to everyone: the list of orgs in a
-- deployment is the customer list, and `select * from orgs` answering it for
-- any authenticated caller is the same disclosure request_password_reset
-- refuses to answer for addresses.
drop policy if exists orgs_member_visible on rbac.orgs;
create policy orgs_member_visible on rbac.orgs for select
  using (id in (select rbac.current_org_ids())
         or (select rbac.has_permission(rbac.current_user_id(), 'orgs', 'select')));
-- Membership is visible for the orgs you are in -- "who else is here" is a
-- question a member of a tenant may ask, and one nobody else may. This is the
-- policy whose existence makes current_org_ids() have to be SECURITY DEFINER;
-- see its header for the recursion it would otherwise cause.
drop policy if exists org_members_own_orgs on rbac.org_members;
create policy org_members_own_orgs on rbac.org_members for select
  using (org_id in (select rbac.current_org_ids())
         or (select rbac.has_permission(rbac.current_user_id(), 'org_members', 'select')));
drop policy if exists visibilities_are_the_contract on rbac.visibilities;
create policy visibilities_are_the_contract on rbac.visibilities for select
  using (true);

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
-- Same reasoning for §2b's predicates: the *_api views are owner-privileged,
-- so every policy on a scoped table is evaluated as api_viewer.
grant execute on function rbac.current_org_ids() to api_viewer;
grant execute on function rbac.may_read(uuid, uuid, text) to api_viewer;
grant select on rbac.orgs, rbac.org_members to api_viewer;
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
