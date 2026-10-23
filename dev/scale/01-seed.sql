-- Seed a deep queue. Depth is the whole point: both defects this harness found
-- are invisible on a shallow one.
--
-- This used to be twenty lines of raw INSERT against workflow.tasks, which meant
-- every scale test reinvented the column list and could get it wrong. It is now
-- one call, because a thing every scaling test needs belongs in the engine.
\set ON_ERROR_STOP on
set role app_owner;

select 'seeded run ' || workflow.seed_load('scale', :depth) as seeded;

analyze workflow.tasks;

select queue, claimable, running, oldest_wait::interval(0), workers_seen
from workflow.v_backlog;
