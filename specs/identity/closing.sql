-- ============================================================
-- THE INSTALL'S LAST WORD ON PUBLIC EXECUTE, for every schema this extension
-- owns.
--
-- Postgres grants EXECUTE on a new function to PUBLIC unless somebody takes it
-- away, and user-rbac 9(a) makes the opposite a rule for the whole collection:
-- a function nobody has granted is unreachable over REST. Deny-by-default, not
-- allow-by-omission.
--
-- IT DID NOT HOLD, twice, and both times for the same reason: the revoke was
-- written as the end of something that went on growing.
--
--   * Four of the five schemas once revoked mid-file and then kept defining
--     functions. Measured on a clean install: forty-six functions across
--     `workflow` and `aiq` still carried EXECUTE for PUBLIC, among them
--     `workflow.p8ql` and `workflow.resolve_statement`. So the revoke moved to
--     the end of world-model-ingestion/ingestion.sql, "the last file in
--     build-sql.py's ORDER", with a comment saying "there is no later than
--     here".
--   * Six files were then added to ORDER after it -- sources, api-sources,
--     lake, contract, packages, identity/declarations -- and it named five
--     schemas typed by hand, so `percolate` was never in it at all.
--     percolate.apply_package reached a database with a NULL ACL and no
--     authorization check (meta/postmortems/2026-09-11-fixed-at-the-copy-that-
--     failed.md §2 and §4).
--
-- So this is not an ORDER entry. build-sql.py appends it after everything else
-- it emits, including the compiled contract types, and nothing can be listed
-- after it. And it asks percolate.extension_schemas() which schemas are the
-- extension's rather than carrying a list, so a seventh schema is covered by
-- existing.
--
-- identity/schema.sql's `alter default privileges` means a fresh install
-- creates nothing PUBLIC can execute, so on a fresh install the revoke below
-- finds nothing to do. It is here for the UPGRADE: `create or replace
-- function` keeps a function's existing ACL, so a database installed before
-- that line carries PUBLIC grants on every function it already had.
-- ============================================================
do $$
declare
    -- EVERYBODY'S BY DESIGN, each with `grant ... to public` where it is
    -- defined and the reason beside the grant. Named rather than inferred:
    -- nothing in the catalog tells an explicit grant to PUBLIC from the default
    -- one, so a function is public here because this line says so, and the
    -- check below holds this list to the catalog in both directions.
    v_public constant text[] := array[
        'percolate.uuidv5(uuid,text)',          -- RFC 4122 arithmetic over its arguments
        'percolate.id_namespace(text)',         -- the same, for a named namespace
        'percolate.extension_schemas()'         -- a read of pg_depend
    ];
    r         record;
    v_bad     text;
    v_missing text;
begin
    -- A script loaded with `psql -f` is not an install: nothing belongs to the
    -- extension, and the revoke and the check below would both be about an
    -- empty set. percolate.extension_schemas() refuses that case itself, by
    -- name, the first time it is read here.

    -- Per function rather than `revoke ... on all functions in schema`, because
    -- the schema-wide form would also take away the grants to public above.
    for r in
        select p.oid::regprocedure as fn
          from pg_catalog.pg_proc p
         where p.pronamespace in (select n.oid from pg_catalog.pg_namespace n
                                   where n.nspname in (select percolate.extension_schemas()))
           and p.oid::regprocedure::text <> all (v_public)
           and exists (select 1 from pg_catalog.aclexplode(
                                   coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) a
                        where a.grantee = 0 and a.privilege_type = 'EXECUTE')
    loop
        execute format('revoke execute on function %s from public', r.fn);
    end loop;

    -- And the check, which is not the loop restated: a REVOKE by a role that
    -- does not own the function is a WARNING, not an error, so a function some
    -- other role owns would survive the loop and report nothing. The ACL is read
    -- with its default filled in, because a function nobody has touched has a
    -- NULL proacl, which MEANS PUBLIC may execute, and aclexplode(NULL) is empty.
    select string_agg(p.oid::regprocedure::text, ', ' order by 1)
      into v_bad
      from pg_catalog.pg_proc p
     where p.pronamespace in (select n.oid from pg_catalog.pg_namespace n
                               where n.nspname in (select percolate.extension_schemas()))
       and p.oid::regprocedure::text <> all (v_public)
       and exists (select 1 from pg_catalog.aclexplode(
                               coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) a
                    where a.grantee = 0 and a.privilege_type = 'EXECUTE');
    if v_bad is not null then
        raise exception
            'PUBLIC EXECUTE INVARIANT VIOLATED: % still carries EXECUTE for PUBLIC. '
            'Every function this extension ships is deny-by-default; revoke it from '
            'public and grant the callers it is meant to have.', v_bad;
    end if;

    -- The other direction: every function named public above exists and IS
    -- public. Without it the list could go on naming a signature that was
    -- renamed or revoked years ago, and read as a decision.
    select string_agg(f, ', ' order by f)
      into v_missing
      from unnest(v_public) f
     where to_regprocedure(f) is null
        or not has_function_privilege('public', to_regprocedure(f), 'execute');
    if v_missing is not null then
        raise exception
            'declared everybody''s at the end of the install, and not: %. Either the '
            'function changed its signature or its grant to public is gone; fix this '
            'list or the grant.', v_missing;
    end if;

    raise notice 'no function in %, beyond the % declared everybody''s, is executable by PUBLIC',
        (select string_agg(s, ', ' order by s) from percolate.extension_schemas() s),
        array_length(v_public, 1);
end $$;
