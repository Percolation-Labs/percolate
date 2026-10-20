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
    if v_new is distinct from v_rev + 1 then
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
    -- ONE ENTRY PER RELATION, WITH ITS PAIRS -- not one per triple. This
    -- assertion read `src_type`/`dst_type` off each element until schema.sql
    -- §13a moved the catalogue to the grouped shape, and it went red on the
    -- change, which is the assertion doing its job: the facet's contract is
    -- what an author reads to write an edge, and that contract moved.
    --
    -- What still has to be true is what an author actually needs: the relation
    -- NAME, what it means, and which (src, dst) it admits -- `* > *` where it
    -- admits every registered pair, an explicit list where it does not.
    if not exists (
        select 1 from jsonb_array_elements(v->'relations') r
        where r->>'relation' is not null
          and r->>'description' is not null
          and jsonb_array_length(r->'pairs') > 0)
    then
        raise exception 'the graph facet does not serve the edge catalogue: %', v->'relations';
    end if;
    -- And a relation that does NOT admit everything must say so specifically,
    -- or `* > *` is not a collapse, it is a wrong answer that happens to be
    -- short.
    --
    -- WALKED FROM THE CATALOGUE, NOT FROM A LITERAL. This asserted
    -- `works_at` reports exactly `["person > company"]`, which is
    -- aiq.relation_types' content on a database holding nothing but the seed --
    -- and an APPLICATION may legitimately register the same relation name
    -- between its own types. dev/tests/evals' fixture registers `works_at` for
    -- investigator > site, so the facet correctly reported two pairs and this
    -- went red about the facet while the facet was right. It is the shape
    -- ../README.md names under "prefer a test that walks the catalogue to one
    -- that walks a list": the literal made the assertion depend on what else
    -- is installed, which is not what it protects.
    --
    -- What it protects is the equality: for a relation admitting fewer than
    -- every registered pair, the facet must report that relation's OWN pairs.
    -- Asserted against aiq.relation_types for every such relation at once,
    -- which also stops being a one-relation spot check.
    declare v_bad text;
    begin
        select string_agg(format('%s: catalogue %s, facet %s',
                                 c.relation, c.pairs, coalesce(f.pairs::text,'(absent)')),
                          '; ' order by c.relation)
          into v_bad
          from (select rt.relation,
                       jsonb_agg(distinct rt.src_type || ' > ' || rt.dst_type) as pairs,
                       count(*) as n
                  from aiq.relation_types rt group by rt.relation) c
          left join (select r->>'relation' as relation, r->'pairs' as pairs
                       from jsonb_array_elements(v->'relations') r) f
                 on f.relation = c.relation
         -- Only the relations that do NOT admit every pair: a relation covering
         -- the whole cross product is the case `* > *` exists for, and asserting
         -- a list there would forbid the collapse this section is about.
         where c.n < (select count(*) from (select distinct src_type from aiq.relation_types) s
                                         , (select distinct dst_type from aiq.relation_types) d)
           and (f.pairs is null
                or (select count(*) from jsonb_array_elements_text(f.pairs)) <> c.n
                or exists (select 1 from jsonb_array_elements_text(c.pairs) p
                            where not f.pairs ? p));
        if v_bad is not null then
            raise exception
                'the graph facet does not report the pairs aiq.relation_types '
                'holds, so the collapse to `* > *` is not reading the catalogue '
                'it claims to serve -- %', v_bad;
        end if;
    end;
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

-- ---------------------------------------------------------------------
-- 8. PROGRESSIVE DISCLOSURE -- schema.sql §13a, made checkable.
--
-- The contract: L0 `SCHEMA` indexes the facets, L1 `SCHEMA "<facet>"` is the
-- VOCABULARY of one, L2 `SCHEMA "<facet>" FROM <name>` is the DETAIL of one
-- name -- and L1 must fit in a workflow step's output, because the skill
-- shipped with the sample agent tells every agent to call SCHEMA first.
--
-- This is not a size preference. Both facets that dumped L2 detail at L1 had
-- grown PAST workflow.max_payload_bytes: `SCHEMA "graph"` at 83,598 bytes and
-- `SCHEMA "sql"` at 71,482 against a 65,536 limit, so a `sql` step calling
-- either failed terminally with "this is terminal: the same response will be
-- the same size on every attempt". Two correct designs that could not both be
-- followed. Found by walking journey J1 (Mill Lane), act 6.
--
-- THE LIMIT IS READ FROM WHERE THE ENGINE READS IT, never retyped: the same
-- coalesce(current_setting(...), 65536) as workflow.enforce_payload_ref_size,
-- so raising the limit deliberately moves this test with it and a second copy
-- cannot drift.
--
-- CALLER-SCOPED FACETS ARE WIDEST FOR THE MOST PRIVILEGED ROLE, so measuring
-- as the suite's own role is the conservative direction -- `SCHEMA "sql"` is
-- 16,510 bytes as app_owner against 11,549 as authenticated. A check that
-- measured the narrow seat would pass while the wide one blew the budget.
-- ---------------------------------------------------------------------
do $$
declare
    v_max  int := coalesce(nullif(current_setting('workflow.max_payload_bytes', true), '')::int,
                           65536);
    v_bad  text;
    v_rpt  text;
begin
    select string_agg(format('%s: %s bytes, over the %s limit', name, bytes, v_max), E'\n       '
                      order by bytes desc) filter (where bytes > v_max),
           string_agg(format('%s %s (%s%% of budget)', name, bytes,
                             round(100.0 * bytes / v_max)), ', ' order by name)
      into v_bad, v_rpt
      from (select f.name, length(aiq.query('SCHEMA "' || f.name || '"')::text) as bytes
              from aiq.schema_facets f) z;

    if v_bad is not null then
        raise exception
            E'these SCHEMA facets do not fit in a workflow step''s output:\n       %\n\n'
            'A `sql` step calling one fails terminally, and p8ql-schema-first '
            'tells every agent to call SCHEMA first -- so the facet and the '
            'skill cannot both be followed. Move per-instance detail to L2 '
            '(SCHEMA "<facet>" FROM <name>) rather than raising the limit: '
            'schema.sql §13a says which fields belong at which level.', v_bad;
    end if;
    raise notice 'query/03: every SCHEMA facet fits a workflow step -- %', v_rpt;
end $$;

-- 8b. A FACET THAT NAMES A NARROWING OWES ONE THAT DOES SOMETHING, and the two
-- facets that narrow do DIFFERENT things -- which the first version of this
-- test got wrong by assuming one shape for both.
--
--   `sql`   DISCLOSES: `columns` and `constraints` are absent at L1 and present
--           at L2. That is what took it from 71,482 bytes to 11,549.
--   `graph` FILTERS: nothing is withheld -- the pairs are collapsed, not
--           removed -- so narrowing returns FEWER relations, not new fields.
--
-- The first version asserted `sample_keys` was L2-only for `graph` and went red,
-- correctly: sample keys are at L1 on purpose and the reason is in
-- schema.sql's own comment -- an agent that reads the catalogue but never sees
-- the SHAPE of a key guesses `sterling`, `gbp`, `gbp_usd`, `gbpusd`, gets four
-- empty results and gives up, which was observed on the first real question
-- ever put to the sample agent. Three keys is exactly the per-name fact that
-- helps a caller CHOOSE, which is the §13a test for belonging at L1.
--
-- `p8ql` and `workflow` are absent from this list on purpose: they describe a
-- dialect and an authoring format, have no per-name detail, declare no
-- narrow_with, and are 7.5KB and 16KB unnarrowed.
do $$
declare
    v_l1_n int; v_l2_n int; v_l1 text; v_l2 text;
begin
    -- Both facets that narrow must SAY they narrow.
    if exists (select 1 from (values ('graph'),('sql')) f(name)
                where not (aiq.schema(f.name) -> 'doc' -> 'declared' ? 'narrow_with')) then
        raise exception
            'a facet that narrows declares no narrow_with -- a reader has no way '
            'to reach the detail it did not print';
    end if;

    -- sql DISCLOSES: columns absent at L1, present at L2.
    v_l1 := aiq.schema('sql')::text;
    -- `resource_chunks`, not `chunks`. The dialect's OTHER modes take the
    -- registered SOURCE name (`TEXT "x" FROM chunks`), and this facet takes a
    -- RELATION name -- so the example a reader is most likely to try,
    -- `SCHEMA "sql" FROM chunks`, matches nothing and returns
    -- `relation_count: 0` with no error. Asserted below so the mismatch is
    -- recorded rather than rediscovered; whether the facet should resolve a
    -- source name to its table is a change to what FROM means here, not a
    -- fix to make while testing something else.
    v_l2 := aiq.schema('sql', 'resource_chunks')::text;
    if (v_l2 ~ '"columns"') is not true then
        raise exception
            'SCHEMA "sql" FROM resource_chunks carries no `columns` -- the narrowing '
            'pointer names a query that returns nothing the directory did not '
            'already have, which reads as a complete answer and is not one';
    end if;
    if (v_l1 ~ '"columns": \[') is not false then
        raise exception
            'SCHEMA "sql" prints every column at L1 -- per-instance detail '
            'belongs at L2 (schema.sql §13a), and this is exactly how it grew '
            'to 71,482 bytes against a 65,536 byte step limit';
    end if;

    -- graph FILTERS: same fields, strictly fewer relations.
    select jsonb_array_length(aiq.schema('graph')->'doc'->'derived'->'relations'),
           jsonb_array_length(aiq.schema('graph','company')->'doc'->'derived'->'relations')
      into v_l1_n, v_l2_n;
    if v_l1_n is null or v_l2_n is null then
        raise exception 'the graph facet served no relations at L1 (%) or L2 (%) -- '
            'a null count here would silence every comparison below it',
            v_l1_n, v_l2_n;
    end if;
    if v_l2_n >= v_l1_n then
        raise exception
            'SCHEMA "graph" FROM company returns % relations against % at L1 -- '
            'narrowing that does not narrow is a pointer to nowhere',
            v_l2_n, v_l1_n;
    end if;
    -- The source-name mismatch, pinned. A reader following the facet's own
    -- `narrow_with` with the name every other mode uses gets an empty
    -- document; if that ever starts resolving, this assertion is where the
    -- change gets noticed rather than being a silent widening.
    if (aiq.schema('sql','chunks')->'doc'->'derived'->>'relation_count') is distinct from '0' then
        raise notice
            'SCHEMA "sql" FROM chunks now resolves the SOURCE name (%) -- if that '
            'was deliberate, say so here; it used to return relation_count 0 and '
            'the mismatch with TEXT/SEMANTIC''s FROM was a documented trap',
            (aiq.schema('sql','chunks')->'doc'->'derived'->>'relation_count');
    end if;
    raise notice 'query/03: sql discloses on narrowing (columns L2-only), graph filters (% relations -> %)',
        v_l1_n, v_l2_n;
end $$;
