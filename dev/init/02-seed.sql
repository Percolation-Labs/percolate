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
-- 01-percolate.sql drives all of them.
-- ------------------------------------------------------------
select workflow.schedule_workflow(
    p_name     => 'content-reconcile',
    p_workflow => 'content_reconcile',
    p_cron     => '*/5 * * * *');

reset role;
