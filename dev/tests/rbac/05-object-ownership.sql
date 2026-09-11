-- RBAC SURFACE -- who OWNS the objects, which decides whether RLS applies.
--
-- `02-rls-is-actually-on.sql` asserts that no system ROLE is a superuser. This
-- asks the other half of the same question: that no OBJECT in the collection
-- is owned by one. A role can be clean while a table created later is not, and
-- ownership is where the bypass actually lives -- a table's owner is exempt
-- from its own policies unless `force row level security` is set, and a
-- superuser is exempt from everything unconditionally.
--
-- ITS CHARACTERISTIC FAILURE IS A TOOL, NOT A MIGRATION. The schema installs
-- itself as app_owner and gets this right. What goes wrong is something else
-- creating an object later, connected as whoever had the credentials:
--
--   * `aiq.register_embedding_space(model)` CREATES A TABLE. Called over a
--     superuser connection -- which is what an admin DSN usually is -- the
--     vector table ends up owned by that superuser while every other table is
--     app_owner's. Nothing complains. The load reports success, and then every
--     embed task fails with `must be owner of table emb_<model>`, because the
--     SECURITY DEFINER function that writes vectors runs as app_owner. The
--     symptom appears in a worker log, minutes later, nowhere near the cause.
--     That is exactly how this file came to exist.
--
--   * the same shape applies to any sample loader, migration runner or
--     one-off `psql` that creates something in these schemas.
--
-- So this is not a restatement of the role check. It is the assertion that
-- nothing has since been created by the wrong hand.
--
-- "These schemas" are percolate.extension_schemas(), which reads `percolate`
-- where the list typed here five times did not (REM-45), plus `tradecraft` and
-- `extract` by name: build-sql.py does not ship them, so the extension never
-- owns them, and a dev database that loaded one by hand is exactly where a
-- superuser-owned object comes from.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- 1. NO OBJECT IN THE COLLECTION IS OWNED BY A SUPERUSER.
--
-- The load-time guard refuses a superuser install; this catches everything
-- created after it. Tables, views, sequences and functions together, because
-- a SECURITY DEFINER function owned by a superuser runs as one.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(format('%s %s (owner %s)', kind, name, owner), E'\n       ')
      into v_bad
    from (
        select 'table' as kind, schemaname||'.'||tablename as name, tableowner as owner
          from pg_tables where (schemaname in (select percolate.extension_schemas())
                 or schemaname in ('tradecraft','extract'))
        union all
        select 'view', schemaname||'.'||viewname, viewowner
          from pg_views where (schemaname in (select percolate.extension_schemas())
                 or schemaname in ('tradecraft','extract'))
        union all
        select 'function', n.nspname||'.'||p.proname, pg_get_userbyid(p.proowner)
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where (n.nspname in (select percolate.extension_schemas())
                or n.nspname in ('tradecraft','extract'))
    ) o
    where exists (select 1 from pg_roles r where r.rolname = o.owner and r.rolsuper);

    if v_bad is not null then
        -- Built with format() rather than a multi-line RAISE literal: adjacent
        -- string constants with an E'' prefix do not juxtapose in this
        -- position, and the parse error is at the literal rather than at the
        -- RAISE, which is a slow thing to read.
        raise exception '%', format(
            'these objects are owned by a SUPERUSER, so RLS does not apply to them:'
            || chr(10) || '       %s' || chr(10)
            || '     Something created them over a superuser connection. Recreate '
            || 'them as app_owner, and load samples and migrations with '
            || '`set role app_owner`.', v_bad);
    end if;
    raise notice 'rbac/05: no object in the collection is owned by a superuser';
end $$;

-- ---------------------------------------------------------------------
-- 2. AND EVERY OWNER IS ONE OF THE TWO ROLES THAT ARE SUPPOSED TO OWN THINGS.
--
-- Weaker than the superuser check on its own and worth having beside it: an
-- object owned by `worker` or `authenticated` would not trip the check above,
-- and would still mean a service role owning something it can then bypass the
-- policies of. Two owners, and the split is deliberate -- api_viewer owns the
-- `_api` views precisely because it owns no tables, so it has no ownership to
-- bypass with.
-- ---------------------------------------------------------------------
do $$
declare v_bad text;
begin
    select string_agg(format('%s owned by %s', name, owner), ', ')
      into v_bad
    from (
        select schemaname||'.'||tablename as name, tableowner as owner
          from pg_tables where (schemaname in (select percolate.extension_schemas())
                 or schemaname in ('tradecraft','extract'))
        union all
        select schemaname||'.'||viewname, viewowner
          from pg_views where (schemaname in (select percolate.extension_schemas())
                 or schemaname in ('tradecraft','extract'))
    ) o
    where owner not in ('app_owner', 'api_viewer');

    if v_bad is not null then
        raise exception 'unexpected owners in the collection: %', v_bad;
    end if;
    raise notice 'rbac/05: every table and view is owned by app_owner or api_viewer';
end $$;

rollback;
