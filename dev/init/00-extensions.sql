create extension if not exists pgcrypto;
create extension if not exists pg_trgm;
create extension if not exists vector;
-- pg_cron is the tick source for workflow.schedules (workflow-engine
-- schema.sql §19). It must exist in the database its background worker is
-- pointed at -- cron.database_name in docker-compose.yml -- or the jobs are
-- rows nothing ever reads.
create extension if not exists pg_cron;
-- pg_partman: still disabled, see Dockerfile.pg19
