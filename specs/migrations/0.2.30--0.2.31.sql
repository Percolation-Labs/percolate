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
end $$;

-- REM-1163. aiq.dream_runs held each aiq.dream() pass (window, decider, receipt). A dream is now a workflow run of
-- `dream`, whose step output is the receipt and whose newest `until` is the watermark (graph.sql). The rows of a
-- scheduled dream are already there, as that run's step output; a direct call's receipt was returned to its caller
-- and has no run to belong to, so it goes with the table. The one thing it carried that a later pass reads, the
-- watermark, costs a dream that has never been scheduled one wider window, which an idempotent pass makes only slower.
drop table if exists aiq.dream_runs;
-- Its kind row too: the replay re-declares only tables that exist, so on an upgraded database this row would outlive
-- the table and the declarations would differ from a fresh install's (dev/upgrade-converges.sh).
delete from percolate.table_kinds where schema_name = 'aiq' and table_name = 'dream_runs';
