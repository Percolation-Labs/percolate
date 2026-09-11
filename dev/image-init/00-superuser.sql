-- The superuser's half of installing percolate, and nothing else: the cluster's
-- roles, and the grants in THIS database that CREATE EXTENSION cannot make for
-- itself. Everything after it is app_owner's (01-percolate.sh, or the caller's
-- own `set role app_owner; create extension percolate`).
--
--     psql -v ON_ERROR_STOP=1 -d <db> -f 00-superuser.sql
--     psql ... -v auth_pw=<secret> -v worker_pw=<secret> -f 00-superuser.sql
--
-- ONE FILE, BECAUSE TEN COPIES KEPT DISAGREEING. This step was written out by
-- hand in the image hook, dev/init, reload, ci-database, currency, backup, the
-- three upgrade gates, the release rehearsal and the self-model loader, and a
-- fix made to one copy kept missing the others. On 2026-09-11, #24 put
-- `grant authenticated to api_viewer` above `create role authenticated` in two
-- of them, and under ON_ERROR_STOP the image's first start stopped at that
-- line. Now the image runs this file at initdb -- the entrypoint picks it up
-- from /docker-entrypoint-initdb.d, ahead of 01-percolate.sh -- and every
-- script copies it into its container and runs it with psql -f, so the image
-- and the scripts cannot say different things. dev/check.sh's tree gate
-- refuses a second spelling of the set_config revoke or the parser install
-- under dev/, applications/, k8s/ or scenarios/.
-- (meta/postmortems/2026-09-11-fixed-at-the-copy-that-failed.md, REM-55)
--
-- IDEMPOTENT, because most of its callers meet a cluster that already has some
-- of it: an upgrade gate on an old published image, a second database in a
-- running stack, template1. So a role is created only where it is missing,
-- by the loop get-percolate's bootstrap.sql uses, and every other statement is
-- one that can run twice. The reasoning for each role is in
-- specs/user-rbac/roles.sql, which applies the spec by including this file.

\set ON_ERROR_STOP on
-- Rerun on a cluster that has it all, every statement below says "already
-- exists" or "already a member". None of that is news; a warning is.
set client_min_messages = warning;

-- ---------------------------------------------------------------------------
-- 1. Roles. Cluster-level, so a non-superuser cannot create them -- which is
--    the whole reason this cannot be left to CREATE EXTENSION.
--
--    Neither app_owner nor api_viewer may ever be a superuser: a superuser
--    bypasses RLS unconditionally, and app_owner is about to own every table.
--    percolate.control sets superuser = false and the extension's preflight
--    refuses the superuser case rather than installing broken.
--
--    A PASSWORD IS SET ONLY ON A ROLE THIS FILE CREATES. Roles are cluster-
--    level and so are their passwords, so resetting one on a second database's
--    install would lock out the services of the first -- bootstrap.sql found
--    that as another stack's PostgREST restart-looping on "password
--    authentication failed". An explicit -v wins; then the variables the image
--    documents, which the entrypoint's psql inherits (psql's \getenv, so the
--    image needs no shell wrapper to read them); then the defaults in the
--    VALUES list, loudly, because they are printed in this file.
-- ---------------------------------------------------------------------------
\if :{?auth_pw}
\else
    \getenv auth_pw P8_AUTHENTICATOR_PASSWORD
\endif
\if :{?worker_pw}
\else
    \getenv worker_pw P8_WORKER_PASSWORD
\endif
\if :{?auth_pw}
\else
    \set auth_pw ''
\endif
\if :{?worker_pw}
\else
    \set worker_pw ''
\endif

-- Through set_config because psql does not substitute :variables inside a
-- dollar-quoted block; transaction-local, so the passwords do not outlive the
-- loop. \gset rather than a bare select, which would print them.
begin;
select set_config('bootstrap.auth_pw',   :'auth_pw',   true) as _auth_pw,
       set_config('bootstrap.worker_pw', :'worker_pw', true) as _worker_pw \gset

do $$
declare
    r  record;
    pw text;
begin
    for r in
        select * from (values
            ('app_owner',     'nologin',         null,                  null),
            ('api_viewer',    'nologin',         null,                  null),
            ('web_anon',      'nologin',         null,                  null),
            ('authenticated', 'nologin',         null,                  null),
            -- noinherit: authenticator holds web_anon and authenticated but
            -- uses neither except by SET ROLE, which is what makes the
            -- per-request identity switch mean anything.
            ('authenticator', 'noinherit login', 'bootstrap.auth_pw',   'authpass'),
            -- The worker and the Content Server connect as themselves and hold
            -- NO table grants: every interaction is a SECURITY DEFINER call,
            -- which is what makes "bring your own worker" safe to offer.
            ('worker',        'login',           'bootstrap.worker_pw', 'workerpass'),
            -- LOGIN, because pg_cron runs each job over a libpq connection as
            -- the job's user, and a NOLOGIN scheduler means "cron job N
            -- connection failed" once a minute with the job still active. No
            -- password: the connection is loopback, which pg_hba trusts.
            ('scheduler',     'login',           null,                  null)
        ) as t(name, attrs, pw_setting, printed_pw)
    loop
        continue when exists (select 1 from pg_roles where rolname = r.name);
        execute format('create role %I %s', r.name, r.attrs);
        if r.pw_setting is not null then
            pw := nullif(current_setting(r.pw_setting), '');
            if pw is null then
                pw := r.printed_pw;
                raise warning 'percolate: role % gets the default password ''%'', which is '
                              'printed in this image''s source. Set P8_AUTHENTICATOR_PASSWORD '
                              'and P8_WORKER_PASSWORD for anything reachable by anyone else.',
                              r.name, pw;
            end if;
            execute format('alter role %I password %L', r.name, pw);
        end if;
    end loop;
end $$;
commit;

-- Every membership AFTER the loop, which is the ordering #24 got wrong by hand:
-- a grant naming a role two lines above its `create role` stopped the image.
grant api_viewer    to app_owner;       -- so app_owner can hand it the views
grant web_anon      to authenticator;
grant authenticated to authenticator;
-- So a workflow step can read as the person who started its run: it runs as
-- api_viewer with their claims, and needs their grants to read even that much.
-- A cluster bootstrapped before 0.2.0 lacks this, and the update refuses
-- until it has it.
grant authenticated to api_viewer;

-- ---------------------------------------------------------------------------
-- 2. Nobody a person can become may rewrite who they are. set_config writes
--    request.jwt.claims, which every row rule takes to be the caller: through
--    aiq.sql_passthrough, carol saw 24 nodes as herself and 229, alice's
--    count, after writing alice's id there (specs/user-rbac/roles.sql §6).
--    Per database,
--    because a function's ACL lives in that database's pg_proc; CREATE
--    EXTENSION percolate refuses to install or upgrade without it.
--
--    Run in template1 too (01-percolate.sh does), so a database created later
--    starts closed. That is why this section comes before the template check.
-- ---------------------------------------------------------------------------
revoke execute on function pg_catalog.set_config(text, text, boolean) from public;
grant execute on function pg_catalog.set_config(text, text, boolean)
    to authenticator, app_owner, worker, scheduler;

-- ---------------------------------------------------------------------------
-- 3. The rest is about the database percolate is going INTO, so a template
--    gets none of it. Installed into template1, the extensions would appear in
--    every database the cluster ever makes, and app_owner's CREATE on its
--    public schema would be copied into each of them.
-- ---------------------------------------------------------------------------
select datistemplate as p8_in_template
  from pg_database where datname = current_database() \gset
\if :p8_in_template
\else

-- The extensions a non-superuser cannot install (vector, percolate_parser),
-- and the two trusted ones percolate.control requires. Those two would arrive
-- by CASCADE, but currency.sh and upgrade-converges.sh load the generated
-- script with -f, where `requires` means nothing.
create extension if not exists pgcrypto;
create extension if not exists pg_trgm;
create extension if not exists vector;
create extension if not exists percolate_parser;

-- Room for app_owner to create things. Dynamic, because the database's name
-- is not a variable every caller has.
do $$ begin
    execute format('grant create on database %I to app_owner', current_database());
end $$;
grant create, usage on schema public to app_owner;

\endif
reset client_min_messages;
