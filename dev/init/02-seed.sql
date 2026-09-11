-- Seed data: the example workflows and the example schedule.
--
-- This file exists because the working demo used to live only in a running
-- container. `workflow.definitions` had rows that appeared nowhere in the
-- repository, so a fresh `docker compose up` produced an empty system and the
-- examples in the docs referred to nothing. That is the same mistake
-- PACKAGING.md records for the Agent Runtime ("a shipped deployable living in
-- gitignored scratch"), one level down.
--
-- Runs as app_owner, after the extension exists.

set role app_owner;

-- ------------------------------------------------------------
-- 1. A workflow that needs nothing deployed.
--
-- Both steps are `kind: sql` (schema.sql §17): allow-listed functions,
-- executed inside Postgres by the engine itself. No worker, no queue, no
-- network. This is the honest smallest example of the claim that a
-- declarative pipeline needs no user code.
-- ------------------------------------------------------------
select workflow.define_yaml($$
name: content_reconcile
steps:
  - id: drift
    sql: {function: content_drift, args: []}
$$);

-- ------------------------------------------------------------
-- 2. A workflow that needs the standard worker and nothing else.
--
-- `rest` compiles to kind: http_call, which percolate-core's worker handles
-- with its built-in handler -- no user code, but a process and a network.
-- Seeded as a definition and deliberately NOT scheduled below: a stack that
-- starts polling the internet the moment it boots is a bad neighbour.
-- Schedule it when you want it:
--
--   select workflow.schedule_workflow('hub-poll', 'hub_smoke', '*/5 * * * *');
-- ------------------------------------------------------------
select workflow.define_yaml($$
name: hub_smoke
steps:
  - id: fetch
    rest:
      url: https://postman-echo.com/get?src=hub
      method: GET
      jsonpath: url
$$);

-- ------------------------------------------------------------
-- 3. The example schedule.
--
-- Every five minutes, reconcile the content plane. It is a real maintenance
-- job rather than a toy: content.check_drift() is what tells you an
-- embedding table and its chunks have diverged, and "reconciliation is the
-- definition of done" is the world-model spec's own rule
-- (brief.md §3) -- which until now nothing ran.
--
-- Note what is NOT here: no cron entry, no privileged call. A schedule is an
-- ordinary row, so this line is the same thing a user does over REST with
-- POST /rpc/schedule_workflow. The single pg_cron job installed by
-- dev/image-init/01-percolate.sh drives all of them.
-- ------------------------------------------------------------
select workflow.schedule_workflow(
    p_name     => 'content-reconcile',
    p_workflow => 'content_reconcile',
    p_cron     => '*/5 * * * *');

-- ------------------------------------------------------------
-- 4. The permission vocabulary the agentic plane checks against.
--
-- `agentic.upsert_agent` and `upsert_tool_server` ask
-- `rbac.has_permission(user, 'agents'|'tool_servers', 'update')`, and until
-- this file existed nothing anywhere inserted those rows -- so the resources
-- were named in a check, granted to nobody, and no end user could author an
-- agent over REST at all. `rbac.role_permissions`' own comment says a new
-- module is added by inserting rows here rather than by writing authz code;
-- this is that insert, finally made for the module that needed it.
--
-- Roles and users are deployment identity, not schema, which is why only the
-- vocabulary is seeded: grant `admin` to somebody and they can author agents.
-- The sample in 03 does not depend on this -- it runs as the table owner --
-- but every agent authored after it does.
-- ------------------------------------------------------------
-- GRANTS_ALL RATHER THAN A LIST, which is what a real install gets and what
-- this file used to approximate by hand.
--
-- The list was agents:update, tool_servers:update and workflows:update, and it
-- was right on the day it was written. Three permission kinds have been added
-- since -- agents:invoke, resources:create, skills:update -- and none reached
-- this role, so a dev and CI database quietly diverged from every deployment a
-- reader installs. It cost real time twice in one day: authoring a skill in
-- the workbench answered "not authorized to author skills" against a database
-- where nobody held skills:update, and dev/tests/rbac's upload assertions
-- failed with "not authorized to upload content" because resources:create was
-- held by nobody -- neither a defect in the code being tested.
--
-- `rbac.bootstrap_admin()` sets this column on a real install, and the trigger
-- on rbac.permission_kinds then grants every future kind to the roles that
-- carry it. Setting it here is the same statement, so the next permission kind
-- needs no edit to this file.
insert into rbac.roles (name, grants_all) values ('admin', true)
on conflict (name) do update set grants_all = true;

-- The trigger only fires for kinds inserted AFTER the role exists, so the ones
-- the extension already declared need the same catch-up bootstrap_admin runs.
insert into rbac.role_permissions (role, resource, action)
select r.name, k.resource, k.action
  from rbac.roles r cross join rbac.permission_kinds k
 where r.grants_all
on conflict do nothing;

-- `member` is an ordinary account, and these are the two pairs user-rbac's own
-- 0.1.10 backfill grants to every role that already exists, so that adding a
-- permission kind does not take a capability away from a live deployment. On a
-- fresh install that backfill matches nothing -- no roles exist yet -- and the
-- roles here are created afterwards, so it never reached them.
--
-- Without them an ordinary member cannot upload a file to their own org, which
-- dev/tests/content/01-write-path.sql asserts in as many words: "a check that
-- refuses everyone is not a check, it is an outage."
insert into rbac.roles (name) values ('member') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
    ('member', 'resources', 'create'),
    ('member', 'agents',    'invoke')
on conflict do nothing;

-- ------------------------------------------------------------
-- THE TWO SAMPLE ORGS, AND THE TWO USERS THAT BELONG TO THEM.
--
-- These uuids are not new: 04-graph-sample.sql, 05-corpus-sample.sql and four
-- test files have written `org_id = 'a0000000-...-a'` since the graph fixture
-- was added, and nothing anywhere said what an org WAS. The `orgs` array on a
-- token was the whole of it.
--
-- rbac.orgs and rbac.org_members are real tables now, and every scoped table's
-- org_id references the first of them -- so seeding these is not fixture
-- decoration, it is what stops the sample data failing its own foreign key.
-- The seeds are where they belong rather than in the graph sample, because two
-- other files and the test suite use the same two ids.
--
-- alice and bob are the deployment's two identities (dev/tests/rbac/01 records
-- why they are stable rather than recreated). One in each org is what makes
-- "a tenant sees its own and not the other's" expressible at all: before this,
-- every fixture asserted tenancy with a token that named an org and no user,
-- which under a real membership model is an anonymous caller.
insert into rbac.orgs (id, slug, name) values
    ('a0000000-0000-0000-0000-00000000000a', 'org-a', 'Org A'),
    ('a0000000-0000-0000-0000-00000000000b', 'org-b', 'Org B')
on conflict (id) do nothing;

insert into rbac.users (id, email) values
    ('11111111-1111-1111-1111-111111111111', 'alice@test.com'),
    ('22222222-2222-2222-2222-222222222222', 'bob@test.com')
on conflict (id) do nothing;

insert into rbac.org_members (org_id, user_id, role) values
    ('a0000000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'admin'),
    ('a0000000-0000-0000-0000-00000000000b', '22222222-2222-2222-2222-222222222222', 'admin')
on conflict (org_id, user_id) do nothing;

reset role;
