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
    delete from percolate.table_kinds where schema_name = 'workflow' and table_name = 'dry_runs';
end $$;
