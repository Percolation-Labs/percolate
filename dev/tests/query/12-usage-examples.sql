-- USAGE.md, EXECUTED -- because a file whose contract is "worked SQL examples
-- for every query mode" should not have examples that do not run.
--
-- Two of them did not, and both were found by running the file rather than by
-- reading it:
--
--   * `select * from aiq.whoami()` has its own heading and says it "is safe in
--     any environment". It lives in `dev-helpers.sql`, which the section two
--     above it correctly calls "not part of the production load order" -- so a
--     reader who took Option 1 and scrolled down got `function aiq.whoami()
--     does not exist`.
--
--   * the "Adding a facet" example registers a provider in `tradecraft.sql`,
--     which is specified and not shipped, so it refuses.
--
-- Neither is a deep bug and that is the point: this is the document a person
-- reads first, and the cost of it being wrong is paid by whoever is newest.
--
-- WHAT THIS FILE IS AND IS NOT. It is not a doc-sync mechanism -- nothing here
-- reads USAGE.md, and nothing can from inside Postgres. It is the shipped
-- surface that document describes, exercised in the FORMS it shows, so that
-- changing a signature breaks a test with USAGE.md's name on it rather than
-- breaking a reader six weeks later. If a call here has to change, the example
-- in USAGE.md changes with it; that coupling is the whole point and it is
-- deliberately stated rather than automated.
--
-- The p8ql half needs no help: `aiq.schema_examples` holds every dialect
-- example and `SCHEMA` parses them on every read (query/03), so a p8ql string
-- that stops parsing already fails. What had nothing behind it is the SQL
-- half -- the functions USAGE.md tells a reader to call directly.
--
-- Reads the committed fixture (`dev/init/`), like every other file here.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- 1. RESOLVING A NAME -- USAGE.md "LOOKUP", every spelling it shows.
--
-- The four calls are four documented behaviours, not four ways of writing one:
-- exact, normalised, alias, and opt-in fuzzy. A regression in any of them is a
-- wrong answer rather than an error, which is this surface's failure mode.
-- ---------------------------------------------------------------------
do $$
declare v_exact uuid; v_norm uuid; v_alias uuid; v_fuzzy uuid; v_n int;
begin
    select node_id into v_exact from aiq.lookup('acme');
    select node_id into v_norm  from aiq.lookup('  ACME  ');
    select node_id into v_alias from aiq.lookup('acme robotics');
    select node_id into v_fuzzy from aiq.lookup('Acme Robotcs', true);

    if v_exact is null then
        raise exception 'aiq.lookup(''acme'') resolved nothing -- USAGE.md''s '
                        'first example, and the fixture has the key';
    end if;
    if v_norm is distinct from v_exact then
        raise exception 'lookup normalisation (lower/trim) no longer resolves '
                        '''  ACME  '' to the same node as ''acme''';
    end if;
    if v_alias is distinct from v_exact then
        raise exception 'the alias ''acme robotics'' no longer reaches the node '
                        'its canonical key does';
    end if;
    if v_fuzzy is distinct from v_exact then
        raise exception 'FUZZY lookup of a misspelling (''Acme Robotcs'') no '
                        'longer reaches ACME -- the opt-in second argument is '
                        'what USAGE.md documents it as';
    end if;

    -- The list form, one round trip rather than N.
    select count(*) into v_n from aiq.lookup_many(array['acme','nadler']);
    if v_n < 2 then
        raise exception 'lookup_many over two known keys returned % row(s)', v_n;
    end if;
    raise notice 'query/12: lookup exact/normalised/alias/fuzzy and the list form all resolve';
end $$;

-- ---------------------------------------------------------------------
-- 2. THE SET DIFFERENCE USAGE.md PROMISES: what resolved, and what did not.
--
-- "an empty result is empty" -- a key that matched nothing appears in
-- `unresolved` rather than being dropped, which is the distinction the whole
-- envelope exists to keep.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    v := aiq.query('LOOKUP "acme", "nadler", "does-not-exist"');
    if jsonb_array_length(v->'rows') < 2 then
        raise exception 'two of the three keys exist and % row(s) came back: %',
            jsonb_array_length(v->'rows'), v->'rows';
    end if;
    if not (v->'unresolved' @> '["does-not-exist"]'::jsonb) then
        raise exception
            'the key that resolved to nothing is missing from `unresolved` (%) '
            '-- USAGE.md hands the set difference over directly rather than '
            'leaving it as an exercise', v->'unresolved';
    end if;
    raise notice 'query/12: a key that matched nothing lands in unresolved, not in the floor';
end $$;

-- Both quoting forms, because USAGE.md shows both and says which is for which
-- host language: single quotes inside SQL, double inside YAML.
do $$
begin
    perform aiq.query('LOOKUP "acme"');
    perform aiq.query($q$LOOKUP 'acme'$q$);
    raise notice 'query/12: both quoting forms parse, as documented for SQL and YAML';
end $$;

-- ---------------------------------------------------------------------
-- 3. THE TRAVERSALS, CALLED THE WAY USAGE.md CALLS THEM -- with the node id
--    coming out of a lookup in the same statement.
-- ---------------------------------------------------------------------
do $$
declare v_n int; v_walk int;
begin
    select count(*) into v_n
      from aiq.graph_neighbors((select node_id from aiq.lookup('ACME')));
    if v_n = 0 then
        raise exception 'graph_neighbors from ACME returned nothing -- the '
                        'fixture has edges on it';
    end if;

    -- DEPTH n>1 is WITH RECURSIVE and a different function, which USAGE.md
    -- names explicitly as the deliberate deep walk.
    select count(*) into v_walk
      from aiq.graph_walk((select node_id from aiq.lookup('ACME')), 2);
    if v_walk < v_n then
        raise exception 'a depth-2 walk (%) reached fewer nodes than depth 1 (%)',
            v_walk, v_n;
    end if;
    raise notice 'query/12: graph_neighbors and graph_walk both answer from a lookup (% / %)',
        v_n, v_walk;
end $$;

-- ---------------------------------------------------------------------
-- 4. THE TWO RETRIEVAL HALVES, in the exact forms the file shows.
-- ---------------------------------------------------------------------
do $$
declare v_lex int; v_sem int;
begin
    select count(*) into v_lex from aiq.lexical('chunks', 'R7 arm');
    select count(*) into v_sem
      from aiq.semantic_in('chunks', '[1,0,0,0]'::vector, 'demo-quad-a', 3);
    if v_lex = 0 then
        raise exception 'the documented lexical example matched nothing';
    end if;
    if v_sem <> 3 then
        raise exception 'the documented semantic example asked for 3 and got %', v_sem;
    end if;
    raise notice 'query/12: the lexical and semantic examples both answer (% / %)',
        v_lex, v_sem;
end $$;

-- ---------------------------------------------------------------------
-- 5. SCHEMA, AT ALL THREE WIDTHS -- the index, one facet, one relation.
-- ---------------------------------------------------------------------
do $$
declare v_all jsonb; v_one jsonb; v_narrow jsonb;
begin
    v_all    := aiq.schema();
    v_one    := aiq.schema('workflow');
    v_narrow := aiq.schema('sql', 'resource_chunks');
    if v_all is null or v_one is null or v_narrow is null then
        raise exception 'one of the three documented SCHEMA widths returned null';
    end if;
    if not (v_all::text like '%p8ql%') then
        raise exception 'the schema index does not list the p8ql facet: %',
            left(v_all::text, 200);
    end if;
    raise notice 'query/12: SCHEMA answers as an index, a facet and one relation';
end $$;

-- Versioning the document: what changed, and what has moved since.
do $$
begin
    perform aiq.capture_schema_revisions();
    perform aiq.schema_drift();
    raise notice 'query/12: capture_schema_revisions and schema_drift both run';
end $$;

-- ---------------------------------------------------------------------
-- 6. THE ESCAPE HATCH, INCLUDING THE REFUSAL USAGE.md ADVERTISES.
--
-- The file shows `sql_passthrough('delete from aiq.nodes')` being refused. An
-- example whose whole point is that it fails is worth running for exactly that
-- reason -- if it ever succeeds, the paragraph beside it is a lie about a
-- boundary rather than a stale sentence.
-- ---------------------------------------------------------------------
do $$
declare v jsonb; v_wrote boolean := false;
begin
    v := aiq.query('select entity_type, count(*) from aiq.nodes group by 1');
    if jsonb_typeof(v->'rows') <> 'array' or jsonb_array_length(v->'rows') = 0 then
        raise exception 'the documented SQL passthrough through the dialect '
                        'returned no rows: %', v;
    end if;

    v := aiq.sql_passthrough('select entity_type, count(*) from aiq.nodes group by 1');
    if v is null then
        raise exception 'aiq.sql_passthrough returned null for a plain read';
    end if;

    begin
        perform aiq.sql_passthrough('delete from aiq.nodes');
        v_wrote := true;
    exception when others then
        null;   -- the refusal is the documented behaviour
    end;
    if v_wrote then
        raise exception
            'sql_passthrough accepted a DELETE. USAGE.md shows this being '
            'refused, and the read-only transaction under it is the boundary '
            '-- not the keyword check beside it.';
    end if;
    raise notice 'query/12: the escape hatch reads, and refuses to write';
end $$;

-- ---------------------------------------------------------------------
-- 7. THE HELPERS THAT ARE **NOT** SHIPPED, asserted as absent.
--
-- Backwards on purpose. `aiq.whoami()` and `aiq.dev_assume_org()` live in
-- dev-helpers.sql, which build-sql.py's NOT_SHIPPED excludes deliberately --
-- "dev conveniences, deliberately not part of what anyone installs". USAGE.md
-- documents them anyway, correctly, and used to document `whoami` under its own
-- heading with no hint of where it came from.
--
-- So this asserts the CURRENT decision. If dev-helpers is ever folded into the
-- extension this fails, and the right response is to delete this block and the
-- note in USAGE.md together -- which is the point: the two move as one.
-- ---------------------------------------------------------------------
do $$
declare v_present text;
begin
    select string_agg(p.proname, ', ' order by p.proname) into v_present
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'aiq'
       and p.proname in ('whoami', 'dev_assume', 'dev_assume_org', 'dev_anon');

    if v_present is not null then
        raise exception
            'aiq.% is installed, and dev-helpers.sql is excluded from the '
            'extension on purpose. Either it has been shipped -- in which case '
            'delete this assertion and USAGE.md''s note about where these come '
            'from -- or something loaded a dev file into a real database.',
            v_present;
    end if;
    raise notice 'query/12: the dev helpers USAGE.md documents are not in the extension';
end $$;

rollback;
