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

-- ============================================================
-- THE DYNAMIC-SQL SURFACE A SIGNED-IN CALLER CAN REACH IS A LIST SOMEBODY
-- WROTE DOWN, and the install refuses to finish when it changes.
--
-- WHAT WENT WRONG. Twice, and the same shape both times: a function a person
-- can call built a statement out of text that person supplied.
--
--   * `aiq.sql_passthrough` is granted to `authenticated` and runs whatever
--     SELECT it is given. `set_config` is a legal select. So one statement
--     rewrote `request.jwt.claims` and the session read as somebody else --
--     measured: Carol saw 24 nodes, then 229, which was Alice's count
--     (user-rbac/roles.sql §6). Closed by revoking set_config from the
--     web-facing roles and refusing to install where that has not been done.
--   * `workflow.plan_probe`, SECURITY INVOKER, granted to `authenticated`,
--     whose own comment promises it "runs no step", took a workflow author's
--     statement into `execute 'explain (format json) ' || v_stmt`. EXPLAIN
--     plans the first statement of a string and does not stop plpgsql running
--     what follows the semicolon. The read branch two lines below it was
--     wrapped correctly. Closed by workflow.one_write_statement.
--
-- WHY A LIST AND NOT A PATTERN. The obvious gate -- refuse any body that
-- concatenates into EXECUTE -- was written and measured before this one, and
-- it was wrong: of the four functions it flagged on a live 0.2.0, three were
-- innocent, because `execute 'select f($1,$2)' into x using a || b` puts the
-- `||` in the USING clause, where it is an argument and not SQL. A rule that
-- is three-quarters false positives gets widened until it matches nothing.
-- Nothing in the catalog can tell safe dynamic SQL from unsafe, so this does
-- not try. It asks the one question the catalog answers exactly -- which
-- functions a signed-in caller can reach have dynamic SQL AT ALL -- and holds
-- the answer to a list, in both directions.
--
-- SO MEMBERSHIP IS NOT AN ACCUSATION. Every function below is here because it
-- is meant to be, and the install failing is the review: the extension stops
-- when this set changes, and the person adding the seventeenth-plus-one
-- either writes its name here or discovers they did not mean to build a
-- statement out of someone's argument. That is the only review this
-- collection has on the surface where a mistake is unrecoverable, and it is
-- the one kind that cannot be skipped when a day is busy.
--
-- plpgsql ONLY, and that is exact rather than a shortcut: EXECUTE is a plpgsql
-- statement, so a `language sql` body cannot run dynamic SQL whatever words
-- appear in it. `aiq.extension_boundary()` is the live example -- its text
-- says EXECUTE because it reads privileges.
-- ============================================================
do $$
declare
    -- THE THREE WEB-FACING ROLES, and the gate asks about all of them (REM-91,
    -- REM-103). Checking `authenticated` alone missed a whole seat: PostgREST's
    -- anonymous role `web_anon`, and `api_viewer` -- the role every *_api view
    -- and every person's workflow step runs as, which OWNS its functions and so
    -- holds execute on them whether or not a grant says so. That gap left
    -- `workflow.execute_as_viewer`, owned by api_viewer and the very function
    -- REM-64 is about, outside the review. has_function_privilege folds in each
    -- role's memberships and PUBLIC, so this is still what a PERSON can reach.
    v_roles constant text[] := array['authenticated', 'web_anon', 'api_viewer'];
    v_dynamic constant text[] := array[
        'aiq.expand_embed_steps(jsonb)',
        -- The judge it calls is a regproc from the operator's setting
        -- percolate.link_judge, cast before format() so it names a function
        -- that exists; the criterion goes in as %L (REM-997).
        'aiq.iterated_join(text,text,integer,integer,real,text,text[])',
        'aiq.lexical(text,text,integer)',
        'aiq.query(text,vector)',
        'aiq.render_facet(text,text)',
        'aiq.schema_p8ql(text)',
        'aiq.schema_workflow(text)',
        'aiq.search(text,text,vector,text,integer,integer)',
        'aiq.semantic_in(text,vector,text,integer)',
        'aiq.space_populated(text,text)',
        'aiq.sql_passthrough(text)',            -- read-only by TRANSACTION, not by a parser
        -- One identifier, and it is never a caller's. claims.candidates reads
        -- the embedding space of a registered model, whose table name it takes
        -- from aiq.embedding_space_name over a row in aiq.embedding_models and
        -- passes through %I; every argument a caller supplies -- the revision,
        -- the claim key, the floor, the limit and the vector -- is a bound
        -- parameter of the executed statement and none of them is interpolated.
        -- It is here because the exclusions and the ORDER BY have to be in one
        -- query: applied to aiq.semantic_in's result they would run after its
        -- LIMIT, and a caller asking for five would get however many of five
        -- survived and no sign that it had (specs/claims/graph.md §5 *Did you mean*).
        'claims.candidates(uuid,text,double precision,integer,vector,text)',
        -- The same shape as candidates (REM-998): the space's name comes from aiq.embedding_space_name over a
        -- registered model and goes through %I; the vector, limit, date and floor are bound parameters.
        'claims.find_question(vector,double precision,integer,text,timestamp with time zone)',
        'claims.questions_to_embed(text,integer)',
        -- REM-996, the same shape: a space name through %I, every caller value bound.
        'claims.facts_to_embed(text,integer)',
        'claims.facts_to_link(text,text,integer,integer)',
        'percolate.enums()',
        'workflow.define_yaml(text)',
        -- Owned by api_viewer, so api_viewer holds execute on it and no grant
        -- can take that away -- but EXECUTE is granted to app_owner alone and
        -- nobody is a member of api_viewer but app_owner, so no person reaches
        -- it. Its dynamic SQL is the wrapped write/read the workflow engine runs
        -- as the run's owner (REM-64): the statement is opened as a cursor, which
        -- the grammar holds to one INSERT/UPDATE/DELETE/MERGE or one query. It is
        -- here because api_viewer reaches it, and the reason it is safe is the
        -- cursor, not a grant.
        'workflow.execute_as_viewer(text,boolean,jsonb)'
        -- THE FIVE PLAN FUNCTIONS WERE HERE AND ARE NOT REACHABLE ANY MORE.
        -- plan_catalog, plan_defects, plan_document, plan_graph and plan_probe
        -- were declared because they are granted to `authenticated` and build
        -- SQL. REM-81 revoked those grants: all five expand a workflow's
        -- `spec`, and integration-rbac.sql §1 refuses to publish `spec` to that
        -- role -- definitions has no owner, no org and no RLS, which is why
        -- definitions_api exists and omits it. They are operator diagnostics
        -- until workflow.definitions adopts scope (REM-42).
        --
        -- Deleted rather than left: this list is of what a PERSON can reach,
        -- and the block below refuses a name that is declared and no longer
        -- reachable. That direction is what caught this -- the install failed
        -- naming all five and telling me to delete the lines, which is the gate
        -- doing exactly its job on somebody who had not read it.
        --
        -- When REM-42 lands and the grants come back, so do these five lines.
    ];
    v_new     text;
    v_gone    text;
begin
    -- What exists and is not declared. This is the direction that catches
    -- drift: adding the function and adding the line are two separate acts and
    -- only one of them is needed to ship (challenge-the-process §3).
    select string_agg(fn || ' (reachable by: ' || roles || ')', E'\n  ' order by fn) into v_new
      from (
        select p.oid::regprocedure::text as fn,
               (select string_agg(r, ', ' order by r) from unnest(v_roles) r
                 where pg_catalog.has_function_privilege(r, p.oid, 'execute')) as roles
          from pg_catalog.pg_proc p
          join pg_catalog.pg_language l on l.oid = p.prolang
         where l.lanname = 'plpgsql'
           and p.pronamespace in (select n.oid from pg_catalog.pg_namespace n
                                   where n.nspname in (select percolate.extension_schemas()))
           and p.prosrc ~* '(^|[^[:alnum:]_])execute[[:space:]]'
           and exists (select 1 from unnest(v_roles) r
                        where pg_catalog.has_function_privilege(r, p.oid, 'execute'))
           and p.oid::regprocedure::text <> all (v_dynamic)
      ) s;
    if v_new is not null then
        raise exception
            E'UNDECLARED DYNAMIC SQL REACHABLE BY A WEB-FACING ROLE:\n  %\n'
            'A signed-in caller, the anonymous role, or api_viewer can reach these and '
            'they build statements at run time. If the statement is built from an '
            'argument, wrap it -- through format() with an identifier or literal '
            'specifier, or through workflow.one_write_statement opened as a cursor for a '
            'write -- and then add the signature to v_dynamic in '
            'specs/identity/closing.sql. If it is not meant to be reachable, revoke it '
            'instead.', v_new;
    end if;

    -- And the other direction, so the list cannot go on naming functions that
    -- were renamed, revoked or had their dynamic SQL taken out. A declared
    -- exception that is no longer an exception reads as a decision somebody
    -- made and is a line nobody has looked at.
    select string_agg(f, ', ' order by f) into v_gone
      from unnest(v_dynamic) f
     where to_regprocedure(f) is null
        or not exists (select 1 from unnest(v_roles) r
                        where pg_catalog.has_function_privilege(r, to_regprocedure(f), 'execute'))
        or not exists (select 1 from pg_catalog.pg_proc p
                        where p.oid = to_regprocedure(f)
                          and p.prosrc ~* '(^|[^[:alnum:]_])execute[[:space:]]');
    if v_gone is not null then
        raise exception
            'declared as dynamic SQL a web-facing role reaches, and no longer: %. Either '
            'the signature changed, no named role (authenticated, web_anon, api_viewer) '
            'reaches it any more, or the dynamic SQL is -- in all three cases delete the '
            'line from v_dynamic in specs/identity/closing.sql.',
            v_gone;
    end if;

    raise notice
        '% functions build SQL at run time and are reachable by a web-facing role '
        '(authenticated, web_anon, api_viewer); all % declared',
        array_length(v_dynamic, 1), array_length(v_dynamic, 1);
end $$;

-- ------------------------------------------------------------
-- SEEDING IS OVER.
--
-- The HEADER set `percolate.seeding` so that every table holding both shipped
-- and deployment rows could default its `shipped` column from it. This runs
-- last in the generated script, so anything inserted after this point -- by a
-- deployment, by a migration, by a person -- is a deployment row and gets
-- dumped, which is the whole point.
--
-- It matters in one specific case rather than in general: a caller who runs
-- `CREATE EXTENSION percolate` and then registers their own entity tables in
-- the SAME transaction. Without this they would inherit the flag and their
-- rows would never be backed up.
-- ------------------------------------------------------------
reset percolate.seeding;
