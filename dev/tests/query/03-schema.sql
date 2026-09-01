-- SCHEMA -- the mode that answers "what IS this database", and the two ways
-- a self-description lies.
--
-- `ai-query-layer/schema.sql` §13. A schema document is a promise about a
-- system, which puts it in the same category as everything ../../surface.sql
-- exists for: the failure mode is not an error, it is a confident answer that
-- stopped being true. Two of those are checked here by construction rather
-- than by reading:
--
--   1. AN EXAMPLE THAT NO LONGER PARSES. Few-shot examples are the most
--      useful thing this document carries and the likeliest to rot. Every read
--      runs them through the real parser and the real compiler, so §3 asserts
--      that a deliberately broken example reports `verified: false` instead of
--      being served as authoritative.
--   2. A CALLER-SCOPED FACET THAT IS NOT SCOPED. A schema listing tables the
--      reader cannot select from is a directory of things to try and a
--      disclosure that another tenant's tables exist. §5 asserts two roles get
--      two different documents.
--
-- And the versioning claim -- that a revision is a content hash, not a number
-- somebody remembers to bump -- is asserted in §4 by making a real schema
-- change and watching the hash move.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- ---------------------------------------------------------------------
-- 1. The index: the only query answerable before you know anything.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    v := aiq.schema();
    if jsonb_array_length(v->'facets') < 4 then
        raise exception 'the schema index lists % facets, expected the four registered ones',
            jsonb_array_length(v->'facets');
    end if;
    -- The index is the bootstrap query, so it must not cost a full render of
    -- every facet. It reports names, not documents.
    if v->'facets'->0 ? 'doc' then
        raise exception
            'the index renders whole facets -- the one query an agent writes first '
            'would then be the most expensive one it ever writes';
    end if;
    -- Each row carries the query that fetches it, spelled the way the dialect
    -- is documented. %L would emit single quotes and teach a second spelling.
    if v->'facets'->0->>'query' not like 'SCHEMA "%"' then
        raise exception 'the index does not hand back a copy-pasteable query: %',
            v->'facets'->0->>'query';
    end if;
end $$;

-- An unknown facet points at the query that lists the real ones, rather than
-- doing what every other registry in this collection does and reporting only
-- that the name was wrong.
do $$
declare v_err text;
begin
    begin
        perform aiq.schema('does_not_exist');
        raise exception 'an unknown facet was accepted';
    exception when others then
        v_err := sqlerrm;
    end;
    if v_err not like '%SCHEMA with no argument%' then
        raise exception 'the unknown-facet error does not say how to list them: %', v_err;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. Derived beats declared. The legal step kinds are read off the engine's
--    own CHECK CONSTRAINT, so a kind shipped in schema.sql appears here with
--    no edit to the facet -- which is the whole reason to derive rather than
--    list. `matrix` is the worked case: it did not exist a version ago.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    v := aiq.schema('workflow')->'doc'->'derived';

    if not (v->'step_kinds' ? 'matrix') then
        raise exception
            'step_kinds does not include matrix. It is read off tasks_kind_check, so '
            'either the constraint has changed or the facet has stopped deriving and '
            'started listing: %', v->'step_kinds';
    end if;
    if not (v->'step_kinds' ? 'sql') or not (v->'step_kinds' ? 'work') then
        raise exception 'step_kinds lost a kind that is in the constraint: %', v->'step_kinds';
    end if;

    -- The allow-list, with the signatures the executor will actually look up.
    -- An agent authoring a `sql:` step reads the same row execute_sql_step does.
    if not exists (
        select 1 from jsonb_array_elements(v->'step_functions') f
        where f->>'name' = 'p8ql' and f->'arg_types' = '["text"]'::jsonb)
    then
        raise exception 'step_functions does not carry real registered signatures: %',
            v->'step_functions';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. Examples are verified by execution, not trusted.
--
-- The three-valued result matters and is asserted: true/false is a claim
-- about the example, null means this deployment cannot check. Collapsing null
-- into false would report a correct example as broken every time the compiled
-- extension lags the schema; collapsing it into true would report an unchecked
-- example as proven.
-- ---------------------------------------------------------------------
do $$
declare v jsonb; v_n int;
begin
    v := aiq.schema('p8ql')->'doc'->'examples';
    if jsonb_array_length(v) = 0 then
        raise exception 'the p8ql facet carries no examples';
    end if;
    -- Every example carries a verdict, and the verdict came from running it:
    -- a parsed one has the parser's own plan attached.
    if exists (select 1 from jsonb_array_elements(v) e where not (e ? 'verified')) then
        raise exception 'an example was served without being run';
    end if;
    if not exists (select 1 from jsonb_array_elements(v) e
                   where (e->'verified')::boolean and e->'plan'->>'mode' is not null) then
        raise exception 'no example carries the plan the parser produced for it';
    end if;
end $$;

-- A broken example reports itself. Registered, read back, and removed --
-- because the assertion is about what the document does with a stale example,
-- not about leaving one behind.
do $$
declare v jsonb;
begin
    perform aiq.register_schema_example('p8ql', '_t_broken', 'p8ql',
        'LOKUP "acme"', 'deliberately wrong', 999);
    select e into v from jsonb_array_elements(
        aiq.schema('p8ql')->'doc'->'examples') e where e->>'label' = '_t_broken';

    if (v->'verified')::boolean is not false then
        raise exception
            'a broken example was served as authoritative (verified=%). An example that '
            'stops parsing must say so, or the document teaches a syntax this deployment '
            'rejects.', v->'verified';
    end if;
    if v->'plan'->>'error' is null then
        raise exception 'the failing example does not carry the parser''s reason';
    end if;
    delete from aiq.schema_examples where facet = 'p8ql' and label = '_t_broken';
end $$;

-- Workflow examples are verified by the COMPILER, not the parser -- a
-- different executor for a different kind, which is what makes adding a third
-- kind a branch in verify_example and nothing else.
do $$
declare v jsonb;
begin
    select e into v from jsonb_array_elements(
        aiq.schema('workflow')->'doc'->'examples') e where e->>'label' = 'sql-only';
    if v is null then
        raise exception 'the workflow facet lost its worked YAML';
    end if;
    -- Three-valued: null when p8_compile_workflow is absent. Either a real
    -- verdict or an explicit "cannot check" -- never a silent pass.
    if (v->'verified') = 'null'::jsonb then
        raise notice 'query/03: compiler unavailable -- workflow examples reported unchecked, not passed';
    elsif not (v->'verified')::boolean then
        raise exception 'the sql-only workflow example does not compile: %', v->>'error';
    elsif v->'compiles_to' is null then
        raise exception 'a compiled example does not carry what it compiled to';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. The version is a hash, and a real change moves it.
--
-- This is what "versioned and maintained with updates" has to mean to be
-- worth anything: not a number someone remembers to bump, but a value that
-- cannot fail to change when the thing it describes does.
-- ---------------------------------------------------------------------
do $$
declare
    v_before text;
    v_after  text;
    v_rev    int;
    v_new    int;
begin
    perform aiq.capture_schema_revisions();          -- start from captured
    if exists (select 1 from aiq.schema_drift()) then
        raise exception 'capture ran and drift remains: %',
            (select string_agg(facet, ', ') from aiq.schema_drift());
    end if;
    if (aiq.schema('workflow')->>'captured')::boolean is not true then
        raise exception 'a freshly captured facet does not report itself captured';
    end if;

    select revision, hash into v_rev, v_before from aiq.schema_revisions
    where facet = 'workflow' order by revision desc limit 1;

    -- A real change to what the facet describes: one more allow-listed
    -- function is one more thing a workflow author may call.
    create function t_schema_probe() returns jsonb as $fn$ select '{}'::jsonb $fn$ language sql;
    perform workflow.register_step_function('t_schema_probe', 't_schema_probe', '{}', 5000,
                                            'a probe registered by query/03');

    v_after := md5(aiq.render_facet('workflow', null)::text);
    if v_after = v_before then
        raise exception
            'registering a step function did not move the workflow facet''s hash. The '
            'hash IS the version, so a version that cannot notice a change is not a '
            'version.';
    end if;

    -- A read now says so, rather than serving an uncaptured document as if it
    -- were versioned.
    if (aiq.schema('workflow')->>'captured')::boolean is not false then
        raise exception 'a drifted facet reported itself as captured';
    end if;
    if not exists (select 1 from aiq.schema_drift() where facet = 'workflow') then
        raise exception 'schema_drift did not name the facet that moved';
    end if;

    -- And capture records it as the NEXT revision, so the history is a
    -- changelog rather than an overwrite.
    perform aiq.capture_schema_revisions();
    select revision into v_new from aiq.schema_revisions
    where facet = 'workflow' order by revision desc limit 1;
    if v_new <> v_rev + 1 then
        raise exception 'capture did not append a revision (was %, now %)', v_rev, v_new;
    end if;
    if not exists (select 1 from aiq.schema_revisions
                   where facet = 'workflow' and revision = v_rev) then
        raise exception 'capture overwrote the prior revision instead of appending';
    end if;

    -- Capturing again when nothing has changed writes nothing. A changelog
    -- with a row per poll is a changelog of nothing.
    if exists (select 1 from aiq.capture_schema_revisions()) then
        raise exception 'capture wrote a revision with no change to record';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. Caller-scoped means caller-scoped.
--
-- The `sql` facet's provider is SECURITY INVOKER precisely so this is true.
-- If it were DEFINER like the other three, every caller would receive
-- app_owner's view of the database -- a list of relations to try, and a
-- disclosure that another tenant's tables exist.
-- ---------------------------------------------------------------------
do $$
declare v_owner int; v_auth int; v_role text;
begin
    v_owner := (aiq.schema('sql')->'doc'->'derived'->>'relation_count')::int;

    set local role authenticated;
    v_auth := (aiq.schema('sql')->'doc'->'derived'->>'relation_count')::int;
    v_role := aiq.schema('sql')->'doc'->'derived'->>'role';
    set local role app_owner;

    if v_role <> 'authenticated' then
        raise exception
            'the sql facet reported role % to a caller running as authenticated -- it is '
            'not SECURITY INVOKER, so every caller is getting the owner''s view', v_role;
    end if;
    if v_auth >= v_owner then
        raise exception
            'authenticated sees % relations and app_owner sees % -- a caller-scoped facet '
            'that is not scoped hands one tenant a directory of another''s tables',
            v_auth, v_owner;
    end if;

    -- And it does not claim a hash it did not produce: the recorded revision
    -- is the owner's view of the database, the doc is yours, and `scoped`
    -- says which is which.
    if (aiq.schema('sql')->>'scoped')::boolean is not true then
        raise exception 'the sql facet does not declare itself scoped';
    end if;
    if aiq.schema('sql')->>'captured' is not null then
        raise exception
            'a caller-scoped facet claimed a captured/uncaptured verdict, which would be '
            'a comparison between the owner''s hash and this caller''s document';
    end if;
end $$;

-- Narrowing is the form worth having: an agent almost always wants the one
-- relation whose name it just learned.
do $$
declare v jsonb;
begin
    v := aiq.schema('sql', 'relation_types')->'doc'->'derived';
    if (v->>'relation_count')::int <> 1 then
        raise exception 'FROM <relation> did not narrow: % relations', v->>'relation_count';
    end if;
    if not exists (
        select 1 from jsonb_array_elements(v->'relations'->0->'columns') c
        where c->>'name' = 'inverse_label')
    then
        raise exception 'the narrowed document does not carry columns';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. The graph facet serves the catalogue the insert trigger ENFORCES.
--
-- An agent writing GRAPH "x" TYPE <rel> has no other way to learn which
-- relations exist, which types they run between, or what they mean --
-- aiq.relation_types carries a description column that nothing served until
-- this facet existed.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    v := aiq.schema('graph')->'doc'->'derived';
    if not exists (
        select 1 from jsonb_array_elements(v->'relations') r
        where r->>'relation' is not null and r->>'src_type' is not null
          and r->>'dst_type' is not null)
    then
        raise exception 'the graph facet does not serve the edge catalogue: %', v->'relations';
    end if;
    if not exists (select 1 from jsonb_array_elements(v->'entity_types') e
                   where e->>'source_table' is not null) then
        raise exception 'the graph facet does not serve the entity registry';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 7. The dialect route. `SCHEMA "workflow"` through aiq.query() needs the
--    parser to know the mode, and the parser ships in the compiled extension.
--    Asserted conditionally rather than skipped silently: on a deployment
--    whose .so carries the SCHEMA mode this must work end to end, and on one
--    that does not, the reason is named here rather than discovered later.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    v := aiq_parse('SCHEMA "workflow"');
    if not (v->>'ok')::boolean then
        raise notice
            'query/03: the installed parser predates the SCHEMA mode (%) -- aiq.schema() '
            'works, the dialect route lands with the next extension build', v->>'error';
        return;
    end if;
    if v->>'mode' <> 'SCHEMA' or v->>'arg' <> 'workflow' then
        raise exception 'SCHEMA parsed to the wrong plan: %', v;
    end if;
    v := aiq.query('SCHEMA "workflow"');
    if v->'schema'->'doc'->'derived'->'step_kinds' is null then
        raise exception 'the dialect route does not reach the facet: %', v;
    end if;
    -- A schema document is not a result set, so it is not returned as `rows`.
    if v ? 'rows' then
        raise exception 'SCHEMA returned a `rows` key, which would make a document look like a result set';
    end if;
end $$;

rollback;

do $$ begin
    raise notice 'query/03: the index is answerable before you know anything, and is cheap';
    raise notice 'query/03: step kinds are derived from the engine''s constraint, matrix included';
    raise notice 'query/03: examples are run on every read -- a broken one reports itself';
    raise notice 'query/03: a real change moves the hash, capture appends a revision, a no-op writes nothing';
    raise notice 'query/03: the sql facet is caller-scoped, and claims no verdict it did not produce';
    raise notice 'query/03: the graph facet serves the edge catalogue the trigger enforces';
end $$;
