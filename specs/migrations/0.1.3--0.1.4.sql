-- 0.1.3 -> 0.1.4: scope, and the one thing a replay cannot express.
--
-- Almost all of this upgrade IS the replay. `rbac.add_scope_columns()` adds the
-- columns, backfills existing rows from their org, and makes the column NOT
-- NULL, all in statements that converge on a second run -- so the migration
-- that in another codebase would live here lives in that function instead, next
-- to the ALTER TABLE it belongs to. That is deliberate and not a shortcut: a
-- delta file is PREPENDED to the replayed schema, so at the moment it runs the
-- `visibility` column does not exist yet on the database being upgraded and
-- there would be nothing to backfill into.
--
-- What is left is a rename, and specifically a rename that reaches a VIEW.
--
-- `agentic.sessions.user_id` is `owner_id` in 0.1.4, because every other owned
-- table in the collection spells it that way and `rbac.scope_predicate()` --
-- the single home of the read expression every scoped policy is generated from
-- -- names that column. One table spelling its owner differently would mean a
-- second variant of a security predicate there is deliberately only one of.
--
-- The table half of that rename is guarded inside agentic/schema.sql and
-- converges fine. The view half cannot be:
--
--     ERROR: cannot change name of view column "user_id" to "owner_id"
--
-- `create or replace view` may add columns at the end and may not rename or
-- reorder the ones that are there. So the view has to be DROPPED before the
-- replayed schema recreates it, and a drop is exactly the kind of statement
-- `build-sql.py` will not accept in a schema file, because it is not something
-- you want re-running on every install.
--
-- Found by `dev/upgrade-converges.sh`. Nothing else could have found it: a
-- fresh install creates the view and never replaces one, so the entire test
-- suite, the surface audit and the round-trip check all pass on a tree that
-- cannot be upgraded onto. It is the fourth defect in this change that only
-- that script sees -- the others were a column added mid-view, an ambiguous
-- function overload, and an index built on a column that had not been renamed
-- yet -- which is a strong argument for it running in CI rather than when
-- somebody remembers.
--
-- Idempotent: `if exists`, and the replayed schema recreates the view,
-- re-transfers it to api_viewer and re-grants it a few hundred lines later.
drop view if exists agentic.sessions_api;

-- ------------------------------------------------------------
-- THE OLD POLICIES, AND WHY THIS HALF IS A SECURITY FIX RATHER THAN TIDYING.
--
-- Every scoped table's policy is now GENERATED and named `<table>_scoped`. The
-- policies it replaces had different names -- `nodes_org_scoped`,
-- `runs_owner_or_permitted`, `agents_are_shared_config` -- so the replayed
-- schema creates the new one and leaves the old one exactly where it was.
--
-- MULTIPLE PERMISSIVE POLICIES ON ONE TABLE ARE OR'ED. A leftover
-- `using (org_id is null or org_id in (select aiq.current_org_ids()))` does not
-- sit there inertly next to the new predicate: it ADDS BACK every row the new
-- one was written to withhold. On an upgraded database the whole change would
-- have been a no-op in the permissive direction -- `org_id is null` would still
-- mean "every tenant reads this", which is the conflation this release exists
-- to end, and `agents_are_shared_config` would still be a literal `true`.
--
-- A fresh install has none of this and passes every check. This is the same
-- shape as the `request_password_reset` grant that 0.1.3 "fixed" by deleting a
-- line: correct for installs that never had the problem, unchanged for every
-- database that did. `dev/upgrade-converges.sh` is the only thing in the
-- repository that can see it, and it saw it.
--
-- Dropped rather than renamed, because the new policy is not a rename of the
-- old one -- it is a different predicate over different columns.
drop policy if exists nodes_org_scoped            on aiq.nodes;
drop policy if exists soft_nodes_org_scoped       on aiq.soft_nodes;
drop policy if exists lake_nodes_org_scoped       on aiq.lake_nodes;
drop policy if exists channels_org_scoped         on content.channels;
drop policy if exists resources_org_scoped        on content.resources;
drop policy if exists datasets_org_scoped         on content.datasets;
drop policy if exists runs_owner_or_permitted     on workflow.runs;
drop policy if exists schedules_owner_or_permitted on workflow.schedules;
drop policy if exists sessions_owner              on agentic.sessions;
drop policy if exists runs_owner                  on agentic.runs;
drop policy if exists agents_are_shared_config       on agentic.agents;
drop policy if exists tool_servers_are_shared_config on agentic.tool_servers;
drop policy if exists skills_are_shared_config       on agentic.skills;
drop policy if exists plugins_are_shared_config      on agentic.plugins;
-- trace-field's two are not listed: workflow.deposits and workflow.anchors ship
-- in no released version (build-sql.py's NOT_SHIPPED), so no database being
-- upgraded has them.

-- ------------------------------------------------------------
-- THE RETIRED FUNCTIONS. Same reasoning, lower stakes: nothing calls them once
-- the policies above are gone, but leaving them is leaving a second answer to
-- "which orgs is this caller in" -- one that reads the JWT array and never
-- consults rbac.org_members. dev/tests/rbac/02 asserts no policy still names
-- them; this is what makes that assertion true on an upgraded database rather
-- than only on a fresh one.
drop function if exists aiq.current_org_ids();
drop function if exists content.may_access_org(uuid);

-- ------------------------------------------------------------
-- THE RENAME'S LEFTOVERS. `alter table ... rename column` carries the column's
-- indexes and constraints along with it and does NOT rename them, so an
-- upgraded database ends up with `sessions_user_id_created_at_idx` and
-- `sessions_user_id_not_null` describing a column called owner_id. Harmless to
-- query and wrong to read, and enough to make a fresh install and an upgraded
-- one different databases -- which is the property this whole file exists to
-- preserve.
alter index if exists agentic.sessions_user_id_created_at_idx
    rename to sessions_owner_id_created_at_idx;
do $$
begin
    if exists (select 1 from pg_constraint
                where conrelid = 'agentic.sessions'::regclass
                  and conname = 'sessions_user_id_not_null') then
        alter table agentic.sessions
            rename constraint sessions_user_id_not_null to sessions_owner_id_not_null;
    end if;
end $$;
