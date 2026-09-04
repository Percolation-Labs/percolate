-- Prove out the RLS pattern user-rbac/spec.md §2 only sketches as a comment:
--   using (owner_id = rbac.current_user_id() or rbac.has_permission(rbac.current_user_id(), '<resource>', 'select'))
-- Simulates what PostgREST actually does per-request: each request is its own
-- transaction with SET LOCAL request.jwt.claims — so each "as <user>" block
-- below is a real BEGIN/COMMIT, not a bare SET LOCAL at the top level.
--
-- Schema-namespaced version: rbac.* objects are explicitly qualified, and the
-- toy consumer table (widgets) lives in public, deliberately -- it stands in
-- for "some other subsystem's table" and so exercises the actual cross-schema
-- RLS call path (a public table's policy calling rbac.current_user_id()),
-- which is the thing worth proving, not a same-schema shortcut.

\set ON_ERROR_STOP on

-- 0. Idempotent teardown.
--
-- The rest of this file deliberately uses real BEGIN/COMMIT blocks -- it is
-- simulating PostgREST's one-transaction-per-request -- so it cannot be
-- wrapped in a single rolled-back transaction the way the other suites are.
-- That makes it commit its fixtures, and a suite that can only be run once is
-- not a suite. Clean up first instead.
-- Scoped to what this file OWNS, which it was not. The teardown used to say
-- `delete from rbac.role_permissions where role in ('admin','member')` and
-- then `delete from rbac.roles ...`, which is every permission the DEPLOYMENT
-- had granted those roles, not just the one row below. Running the suite
-- therefore removed `agents/update` and `tool_servers/update` -- seeded by
-- dev/init/02-seed.sql -- and afterwards nobody could author an agent over
-- REST at all. A green suite that quietly revokes a capability is worse than a
-- red one, and it took an agent registration failing hours later to notice.
--
-- The roles themselves are no longer dropped and recreated for the same
-- reason: `admin` and `member` are deployment vocabulary this file borrows,
-- not fixtures it invented.
drop table if exists widgets;
delete from rbac.user_roles where user_id in (
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222');
delete from rbac.role_permissions
 where role in ('admin','member') and resource = 'widgets';
delete from rbac.permission_kinds where resource = 'widgets';
-- The users are NOT deleted either, and that is the second half of the same
-- lesson. alice and bob have fixed uuids and are the only identities a dev
-- stack has, so everything anyone tries by hand ends up owned by one of them
-- -- a workflow run, an agent session. Deleting them then fails on a foreign
-- key from another subsystem's table ("still referenced from table runs"),
-- which reads as a broken RBAC test and is really the suite trying to delete
-- the deployment's only user. They are stable fixtures; making them exist is
-- the requirement, not making them new.

-- 1. Two users, one role each
insert into rbac.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.com'),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.com')
on conflict (id) do nothing;

insert into rbac.roles (name) values ('admin'), ('member') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values
  ('11111111-1111-1111-1111-111111111111', 'admin'),
  ('22222222-2222-2222-2222-222222222222', 'member')
on conflict do nothing;
-- `widgets` is a module, in miniature -- a table, a policy, and a permission
-- pair its policy consults -- so it declares that pair before granting it,
-- which is the order rbac.permission_kinds requires of any module. The grant
-- below used to be the whole step, and the foreign key rejected it: a pair
-- nothing has declared is indistinguishable from a typo, which is the entire
-- point of the table. This is what "add a module by inserting rows, not by
-- writing authz code" looks like now.
-- `checked_by` NAMES THE POLICY THIS FILE ACTUALLY CREATES. It said
-- `widgets_owner_or_permitted`, which is what the sketch in spec.md §2 calls
-- the shape and not what line 81 below names the policy -- so the miniature
-- module demonstrating how to declare a pair demonstrated the one mistake the
-- column exists to make visible. Found by rbac/10, which walks every
-- declaration of that form and asks whether the policy is there.
insert into rbac.permission_kinds (resource, action, checked_by) values
  ('widgets', 'select', 'policy select_own_or_permitted (dev/tests/rbac/01)')
on conflict (resource, action) do update set checked_by = excluded.checked_by;
insert into rbac.role_permissions (role, resource, action) values
  ('admin', 'widgets', 'select') on conflict do nothing;

-- 2. A toy owned resource, RLS applied exactly per the spec's commented pattern
create table widgets (
    id uuid primary key default gen_random_uuid(),
    owner_id uuid not null references rbac.users(id),
    label text not null
);
alter table widgets enable row level security;
create policy select_own_or_permitted on widgets for select
  using (owner_id = (select rbac.current_user_id())
         or (select rbac.has_permission(rbac.current_user_id(), 'widgets', 'select')));

insert into widgets (owner_id, label) values
  ('11111111-1111-1111-1111-111111111111', 'alice-widget'),
  ('22222222-2222-2222-2222-222222222222', 'bob-widget');

-- 3. Use the REAL `authenticated` role from schema.sql §9, not an ad-hoc test
--    role. RLS is a no-op for superusers/table owners by default (BYPASSRLS),
--    so a non-superuser role is essential -- but it must be one the schema
--    actually grants EXECUTE on rbac.current_user_id()/rbac.has_permission()
--    to. An earlier version of this test invented its own `app_user`, which
--    worked only because functions in `public` are EXECUTE-granted to PUBLIC
--    by default; once §9's `revoke execute on all functions in schema rbac
--    from public` + explicit grants took effect, that ad-hoc role correctly
--    got "permission denied for function current_user_id". Testing with the
--    role the deployment actually uses is the point -- inventing a role that
--    bypasses the grant model tests nothing real.
grant select on widgets to authenticated;

-- 4. bob (member, owns bob-widget, no explicit permission grant)
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub": "22222222-2222-2222-2222-222222222222"}';
select 'bob sees (expect: bob-widget only)' as check, label from widgets order by label;
commit;

-- 5. alice (admin, has explicit widgets:select permission via has_permission)
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
select 'alice sees (expect: BOTH via has_permission admin grant)' as check, label from widgets order by label;
commit;

-- 6. no claim at all (unauthenticated) — current_user_id() null, has_permission(null,..) false
begin;
set local role authenticated;
select 'anonymous sees (expect: EMPTY)' as check, label from widgets order by label;
commit;

-- 7. rbac.users' OWN RLS (not the toy table's): alice is admin but has no
--    'users'/'select' permission row, so both users should see only themselves
--    through users_api. Proves FORCE ROW LEVEL SECURITY is doing its job on
--    this module's own tables after the schema move, not just on widgets.
-- users_api is already granted to `authenticated` by schema.sql §9 -- no extra grant needed here,
-- which is itself worth noting: the deployment grant model covers this test as-is.
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub": "22222222-2222-2222-2222-222222222222"}';
select 'bob sees via users_api (expect: bob@test.com only)' as check, email
from rbac.users_api order by email;
commit;
