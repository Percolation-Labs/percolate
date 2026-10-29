-- The moment the workers are stopped (docker compose kill worker ingest-worker), note the time and read the run's rows:
--   psql "$P8_DSN" -v run=<the run id start-live.sql printed> -f durability/during.sql
select now() as killed_at;
select status, count(*) as tasks from workflow.tasks where run_id = :'run' group by 1 order by 1;
select count(*) as reads_held from aiq.walk_reads(:'run');
