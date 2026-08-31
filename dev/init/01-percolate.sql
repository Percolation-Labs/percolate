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
create role worker nologin;
create role scheduler nologin;

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
