-- 0.2.30 -> 0.2.31: what a replay cannot express. Everything else is the schema re-applied.

-- REM-1160. workflow.dry_runs held only (shadow run, the run it estimates, start time); the pair is now
-- workflow.runs.dry_run_of on the shadow run. The column is added here as well as in the schema because this
-- runs before the replay, and the rows move before the table goes.
alter table workflow.runs add column if not exists dry_run_of uuid references workflow.runs(id) on delete cascade;
do $$
begin
    if to_regclass('workflow.dry_runs') is not null then
        update workflow.runs r set dry_run_of = d.of_run_id
          from workflow.dry_runs d where d.shadow_run_id = r.id;
        drop table workflow.dry_runs;
    end if;
    -- Its declaration goes with it: identity/declarations.sql no longer lists it, and a fresh install has no row.
    -- An upgrade from before table_kinds existed (0.1.6, say) runs this hop before the replay creates it.
    if to_regclass('percolate.table_kinds') is not null then
        delete from percolate.table_kinds where schema_name = 'workflow' and table_name = 'dry_runs';
    end if;
end $$;

-- REM-1163. aiq.dream_runs held each aiq.dream() pass (window, decider, receipt). A dream is now a workflow run of
-- `dream`, whose step output is the receipt and whose newest `until` is the watermark (graph.sql). Every row here is
-- a direct call's: aiq.schedule_dream could not be installed before 0.2.31 (it registered the step with no argument
-- types), so no scheduled dream ever ran. A direct call's receipt was returned to its caller and has no run to
-- belong to, so it goes with the table. The one thing it carried that a later pass reads, the
-- watermark, costs a dream that has never been scheduled one wider window, which an idempotent pass makes only slower.
drop table if exists aiq.dream_runs;
-- Its kind row too: the replay re-declares only tables that exist, so on an upgraded database this row would outlive
-- the table and the declarations would differ from a fresh install's (dev/upgrade-converges.sh). A database from
-- before percolate.table_kinds existed (0.1.6 upgrades straight here) has no row to delete.
do $$
begin
    if to_regclass('percolate.table_kinds') is not null then
        delete from percolate.table_kinds where schema_name = 'aiq' and table_name = 'dream_runs';
    end if;
end $$;
