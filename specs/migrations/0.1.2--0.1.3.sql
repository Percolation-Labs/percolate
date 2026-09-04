-- 0.1.2 -> 0.1.3: three words for finishing became one.
--
-- The part of this upgrade a REPLAY CANNOT EXPRESS. Everything else in
-- percolate--0.1.2--0.1.3.sql is the schema re-applied, which converges because
-- every statement in it can run twice. Rewriting rows cannot: the schema
-- describes the shape a table should have, never the values already in it.
--
-- `workflow.tasks` said 'done', `workflow.runs` said 'completed' and
-- `agentic.runs` said 'succeeded' -- one idea under three words, and because
-- both status constraints are named the same thing, the wrong vocabulary read
-- as right. 0.1.3 puts the words in one place (workflow.lifecycle_states) with
-- a foreign key from every status column into it.
--
-- ORDER MATTERS AND IS THE WHOLE FILE:
--
--   1. Drop the old CHECKs. They still say 'completed'/'done', so the UPDATE
--      below would violate the very constraint it exists to move past.
--   2. Rewrite the rows.
--   3. Let the replayed schema add the new CHECKs and the FKs into
--      lifecycle_states. Adding that FK to a table still holding a 'completed'
--      row fails, which would abort the upgrade rather than corrupt it -- loud,
--      but a database nobody can upgrade is still a database nobody can
--      upgrade.
--
-- Idempotent, like everything else here: the UPDATEs match nothing on a second
-- run, and the drops are `if exists`.
alter table workflow.runs  drop constraint if exists runs_status_check;
alter table workflow.tasks drop constraint if exists tasks_status_check;

update workflow.runs  set status = 'succeeded' where status = 'completed';
update workflow.tasks set status = 'succeeded' where status = 'done';
