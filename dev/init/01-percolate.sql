-- Runs once at initdb, as the bootstrap superuser.
--
-- Four lines of DBA work, and then the whole system is one CREATE EXTENSION.
-- The split is not ceremony: roles are CLUSTER-level so a non-superuser cannot
-- create them, and `vector`/`percolate_parser` are not trusted extensions so a
-- non-superuser cannot install them either. Everything after that is
-- deliberately NOT superuser work.

-- 1. Roles. Neither may ever be a superuser: superusers bypass RLS
--    unconditionally, and app_owner is about to own every table.
create role app_owner nologin;
create role api_viewer nologin;
grant api_viewer to app_owner;          -- so app_owner can hand it the views
create role web_anon nologin;
create role authenticated nologin;
create role authenticator noinherit login password 'authpass';
grant web_anon to authenticator;
grant authenticated to authenticator;
-- worker and the content server connect as themselves, so they need a login.
-- They hold NO table grants -- every interaction is a SECURITY DEFINER function
-- call -- which is what makes running them safe to hand to anyone.
create role worker login password 'workerpass';
-- LOGIN, unlike the spec's default: pg_cron runs each job over a libpq
-- connection as the job's username, so a NOLOGIN scheduler means "cron job N
-- connection failed" once a minute with the job still showing active. No
-- password: the connection is loopback inside the container, which pg_hba
-- trusts. It holds no table grants -- all three jobs are SECURITY DEFINER
-- function calls.
create role scheduler login;

-- 2. The extensions a non-superuser cannot install.
create extension if not exists vector;
create extension if not exists percolate_parser;

-- 3. Room for app_owner to create things.
-- The database name is not a psql variable in an initdb script, so this has
-- to be dynamic rather than :"POSTGRES_DB".
do $$ begin
    execute format('grant create on database %I to app_owner', current_database());
end $$;
grant create, usage on schema public to app_owner;

-- 4. The whole system, installed BY app_owner so it owns what it creates.
--    Installing this as the superuser would leave every policy inert, which is
--    why percolate.control sets superuser = false and why user-rbac's own
--    guard refuses that case rather than allowing it silently.
set role app_owner;
create extension percolate cascade;
reset role;

-- 5. The clock. ONE cron job for the whole system.
--
-- Every scheduled workflow is a row in workflow.schedules, so this never
-- changes and nobody needs rights on the cron schema to add a schedule --
-- that is an ordinary authenticated REST call to
-- POST /rpc/schedule_workflow (workflow-engine/schema.sql §19).
--
-- The two maintenance jobs the engine has always documented in comments get
-- registered here too, for the first time: promote_due_timers() is what makes
-- `timer` steps fire at all, and reap_stale_tasks() is what recovers a task
-- whose worker died. Both were speced, granted to `scheduler`, and then left
-- with nothing calling them.
--
-- Jobs run as `scheduler`, the role user-rbac/roles.sql defines for exactly
-- this and which holds no table grants: all three functions are SECURITY
-- DEFINER, so EXECUTE is the whole grant any of them needs.
select cron.schedule('workflow-tick',     '* * * * *', $$select workflow.tick()$$);
select cron.schedule('workflow-reaper',   '* * * * *', $$select workflow.reap_stale_tasks()$$);
select cron.schedule('workflow-timers',   '* * * * *', $$select workflow.promote_due_timers()$$);

update cron.job set username = 'scheduler'
 where jobname in ('workflow-tick', 'workflow-reaper', 'workflow-timers');
