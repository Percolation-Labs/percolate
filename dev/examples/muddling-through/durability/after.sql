-- After docker compose start worker ingest-worker and the run's end. Nothing was copied aside: each task row says when it
-- finished (completed_at), how many times it ran (attempts) and when it last changed (updated_at).
--   psql "$P8_DSN" -v run=<the run id> -v killed_at='<the time during.sql printed>' -f durability/after.sql
select status from workflow.runs where id = :'run';
select count(*) filter (where completed_at < :'killed_at') as finished_before_crash,
 count(*) filter (where completed_at < :'killed_at' and attempts > 1) as redone,
 count(*) filter (where completed_at < :'killed_at' and updated_at > :'killed_at') as changed_since
 from workflow.tasks where run_id = :'run';
select step_key, attempts from workflow.tasks where run_id = :'run' and attempts > 1;
select count(*) as reads from aiq.walk_reads(:'run');
select (aiq.walk_cost(:'run')->'total')::text as jev;
