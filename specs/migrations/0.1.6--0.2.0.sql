-- 0.1.6 -> 0.2.0: the graph learns to forget on purpose.
--
-- The part of this upgrade a REPLAY CANNOT EXPRESS. Everything else is the
-- schema re-applied, which converges because every statement in it runs twice.
-- `create table if not exists` cannot narrow a column that already exists: an
-- existing database's `aiq.edges.valid_from` is nullable with no default and
-- full of nulls, and nothing in the replayed schema will change that.
--
-- WHY IT HAS TO CHANGE. `aiq.edges` has been bitemporal since it was written --
-- `valid_from` and `valid_to` are both in the original CREATE -- and neither
-- was ever populated. Across 9,502 edges in the dogfood instance the retraction
-- rate was exactly 0.00% and every single `valid_from` was null. The pair was
-- decorative.
--
-- That is the regime `research-notes/build-knit-dream-theory.pdf` §10 calls
-- running the model in its known-broken state: an append-only knowledge graph
-- has no depression term, and retraction is the balance condition the capacity
-- result depends on. §14 turns it into a test -- if the retraction rate is
-- zero, the condition is violated -- and ours was zero for the most banal
-- possible reason, which is that the derivation DELETEd what it could no longer
-- derive. A graph that forgets by deletion does not forget slowly; it forgets
-- completely, leaving nothing to audit and nothing downstream able to tell
-- that a relationship was once asserted.
--
-- ORDER MATTERS:
--
--   1. Backfill from `created_at`. It is when the row was first written, which
--      is exactly when the edge was first asserted, and it is already correct
--      for every historical row. Using now() here instead produces edges
--      asserted after they were retracted -- measured, on the first attempt.
--   2. Then the default, so every future writer dates itself.
--   3. Then NOT NULL, which can only be added once no nulls remain.
--
-- Idempotent: the UPDATE matches nothing on a second run, and both ALTERs are
-- no-ops once applied.
--
-- NO `set role` HERE, and the omission is deliberate rather than an oversight.
-- This file is PREPENDED to the upgrade script, which loads as app_owner and
-- refuses to load as a superuser at all. A `set role app_owner; ... reset role;`
-- pair looks harmless and is not: `reset role` drops the session back to the
-- superuser it started as, and every statement in the 10,000 lines that follow
-- then runs as one -- which the schema's own guard catches and refuses, having
-- been written for exactly that mistake. Neither existing migration sets a
-- role; this one inherits the caller's, like they do.

update aiq.edges set valid_from = created_at where valid_from is null;
alter table aiq.edges alter column valid_from set default now();
alter table aiq.edges alter column valid_from set not null;

-- THE RECALL COUNTERS, for the same reason as valid_from above: `create table
-- if not exists` cannot add a column to a table that already exists, and an
-- upgraded database would carry the schema without them.
--
-- `aiq.edges_current` does not need repairing here because it is new in 0.2.0:
-- an upgrade creates it fresh from the replayed schema, with the full column
-- list. A database that already had it would need a DROP, since a view cannot
-- be widened by `create or replace`.
alter table aiq.edges add column if not exists recall_count     bigint not null default 0;
alter table aiq.edges add column if not exists probe_count      bigint not null default 0;
alter table aiq.edges add column if not exists last_recalled_at timestamptz;
