-- QUERY SURFACE -- the dialect parses what the caller meant, and a node's
-- keys are never more visible than the node.
--
-- The characteristic failure of this surface is not a crash. It is a *wrong
-- answer* -- a query that parses differently than it reads, or returns rows a
-- tenant should not see, or silently returns none. Nothing here would be
-- caught by a smoke test asking only "did it return".

\set ON_ERROR_STOP on

begin;
set local role app_owner;

-- ---------------------------------------------------------------------
-- 1. QUOTING: '...' and "..." are interchangeable.
--
-- P8QL is always written inside a host language, and both of its hosts claim
-- the double quote first -- SQL (`aiq.query('LOOKUP ...')`) and YAML
-- (`args: ["LOOKUP ..."]`). Accepting only the double quote had a loud half
-- and a silent half, and the silent half is the reason this test exists:
-- `LOOKUP 'R7 Notice'` failed with `unexpected token 'Notice''`, but
-- `LOOKUP 'R7'` SUCCEEDED with the key `'R7'`, quotes included -- a lookup
-- that matches nothing, raises nothing, and reports a clean parse.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    if (aiq_parse('LOOKUP ''R7 Notice''') ->> 'arg') <> 'R7 Notice' then
        raise exception 'single-quoted multi-word key does not parse: %',
            aiq_parse('LOOKUP ''R7 Notice''');
    end if;

    -- the silent one
    if (aiq_parse('LOOKUP ''R7''') ->> 'arg') <> 'R7' then
        raise exception 'single-quoted key kept its quotes: %',
            aiq_parse('LOOKUP ''R7''') ->> 'arg';
    end if;

    if (aiq_parse('LOOKUP "R7 Notice"') ->> 'arg')
       <> (aiq_parse('LOOKUP ''R7 Notice''') ->> 'arg') then
        raise exception 'the two quote characters do not agree';
    end if;

    -- an unterminated quote is an error, not a key
    v := aiq_parse('LOOKUP ''R7 Notice');
    if (v ->> 'ok')::boolean is not false then
        raise exception 'unterminated quote parsed as valid: %', v;
    end if;

    raise notice 'query/02: both quote characters agree, unterminated is an error';
end $$;

-- ---------------------------------------------------------------------
-- 1b. THE GRAMMAR, as it reads rather than as it was first implemented.
--
-- Three spellings were retired. Each is asserted twice: that the new form
-- parses, and that the old one fails with a message NAMING the replacement.
-- The second half is the load-bearing one -- a rename whose error says only
-- "unknown mode" leaves everyone who reads an older document stuck.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    -- FUZZY is a prefix adjective
    if (aiq_parse('FUZZY LOOKUP "acme"') ->> 'fuzzy')::boolean is not true then
        raise exception 'FUZZY LOOKUP did not set fuzzy';
    end if;
    if (aiq_parse('LOOKUP "acme" FUZZY') ->> 'error') not like '%prefix%' then
        raise exception 'trailing FUZZY does not point at the prefix form: %',
            aiq_parse('LOOKUP "acme" FUZZY') ->> 'error';
    end if;

    -- FUZZY is trigram matching over node_keys, so it means nothing elsewhere
    if (aiq_parse('FUZZY SEARCH "x" FROM chunks') ->> 'ok')::boolean is not false then
        raise exception 'FUZZY was accepted on SEARCH, where it does nothing';
    end if;

    -- HYBRID is SEARCH
    if (aiq_parse('SEARCH "x" FROM chunks') ->> 'mode') <> 'SEARCH' then
        raise exception 'SEARCH does not parse';
    end if;
    if (aiq_parse('HYBRID "x" FROM chunks') ->> 'error') not like '%SEARCH%' then
        raise exception 'HYBRID does not point at SEARCH';
    end if;

    -- SQL has no keyword: it is recognised by how the statement starts
    if (aiq_parse('select 1 from aiq.nodes') ->> 'mode') <> 'SQL' then
        raise exception 'a bare select was not recognised as SQL';
    end if;
    if (aiq_parse('SQL select 1') ->> 'error') not like '%drop the SQL keyword%' then
        raise exception 'the SQL keyword does not explain itself';
    end if;

    -- ...and a typo stays a DIALECT error. If anything unrecognised were
    -- treated as SQL, this would come back as a SQL syntax error about a
    -- language the caller was not writing.
    if (aiq_parse('LOKUP "acme"') ->> 'error') not like '%unknown mode%' then
        raise exception 'a misspelled mode was swallowed as SQL: %',
            aiq_parse('LOKUP "acme"') ->> 'error';
    end if;

    -- LOOKUP takes a list; commas optional; a bare keyword ends it
    if (aiq_parse('LOOKUP "a", "b", "c"') -> 'args') <> '["a","b","c"]'::jsonb then
        raise exception 'comma-separated list did not parse: %',
            aiq_parse('LOOKUP "a", "b", "c"') -> 'args';
    end if;
    if (aiq_parse('LOOKUP "a" "b"') -> 'args') <> '["a","b"]'::jsonb then
        raise exception 'space-separated list did not parse';
    end if;
    v := aiq_parse('LOOKUP "a", "b" LIMIT 5');
    if (v -> 'args') <> '["a","b"]'::jsonb or (v ->> 'limit')::int <> 5 then
        raise exception 'LIMIT was swallowed into the argument list: %', v;
    end if;
    -- and only LOOKUP resolves a list
    if (aiq_parse('SEARCH "a", "b" FROM chunks') ->> 'ok')::boolean is not false then
        raise exception 'SEARCH accepted two arguments and would have ignored one';
    end if;

    raise notice 'query/02: FUZZY prefixes, SEARCH replaces HYBRID, SQL needs no '
                 'keyword, LOOKUP takes a list';
end $$;

-- Each key in a list resolves independently -- one key''s exact hit must not
-- suppress another key''s fuzzy match, or a list would mean something
-- different from the same keys asked one at a time.
do $$
declare
    v_alone int;
    v_together int;
begin
    insert into aiq.nodes (id, entity_type, entity_id, summary) values
      ('cccccccc-0000-0000-0000-000000000001','t_co',
       'dddddddd-0000-0000-0000-000000000001','Acme'),
      ('cccccccc-0000-0000-0000-000000000002','t_co',
       'dddddddd-0000-0000-0000-000000000002','Nadler');
    insert into aiq.node_keys (node_id, entity_type, key, kind) values
      ('cccccccc-0000-0000-0000-000000000001','t_co','zz_acme','canonical'),
      ('cccccccc-0000-0000-0000-000000000002','t_co','zz_nadler','canonical');

    select count(*) into v_alone from aiq.lookup('zz_nadlr', true);
    select count(*) into v_together
    from aiq.lookup_many(array['zz_acme','zz_nadlr'], true)
    where input_key = 'zz_nadlr';

    if v_alone <> v_together then
        raise exception 'zz_nadlr matched % rows alone but % in a list -- a list '
                        'is changing what its keys mean', v_alone, v_together;
    end if;
    raise notice 'query/02: list keys resolve independently (% row(s) either way)',
        v_alone;
end $$;

-- ---------------------------------------------------------------------
-- 2. THE PARSE IS ALWAYS RETURNED ALONGSIDE THE ROWS.
-- A misparse is otherwise indistinguishable from an empty result, which is
-- the single most confusing failure a query dialect can have.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    v := aiq.query('LOOKUP "nothing-by-this-name"');
    if v -> 'plan' is null then
        raise exception 'aiq.query returned rows without the parsed plan';
    end if;
    if (v -> 'plan' ->> 'mode') <> 'LOOKUP' then
        raise exception 'plan does not report the mode it executed: %', v -> 'plan';
    end if;
    raise notice 'query/02: the plan travels with the result';
end $$;

-- ---------------------------------------------------------------------
-- 3. A KEY IS NEVER MORE VISIBLE THAN ITS NODE.
--
-- node_keys and edges once *gated reads* on their own org_id, duplicating
-- what nodes already knew. The two drifted -- a rebuild updated nodes.org_id
-- while node_keys.org_id kept its old value -- and the result was the worst
-- possible shape: a visible key pointing at an invisible node, so LOOKUP
-- matched and then returned nothing.
--
-- The columns themselves still exist and should: node_keys.org_id backs the
-- canonical-key unique index, and edges.org_id is authoring provenance
-- (integration-rbac.sql:71, :89). What must never come back is a *policy*
-- reading them. Visibility is derived from aiq.nodes, so it cannot disagree
-- with aiq.nodes.
-- ---------------------------------------------------------------------
do $$
declare
    r record;
begin
    for r in
        select c.relname, p.polname, pg_get_expr(p.polqual, p.polrelid) as qual
        from pg_policy p
        join pg_class c on c.oid = p.polrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'aiq' and c.relname in ('node_keys', 'edges')
    loop
        if r.qual !~ 'aiq\.nodes|FROM nodes' then
            raise exception 'policy %.% no longer derives visibility from aiq.nodes: %',
                r.relname, r.polname, r.qual;
        end if;
        if r.qual ~ ('\m' || r.relname || '\.org_id\M') then
            raise exception 'policy %.% gates reads on its OWN org_id -- that copy '
                            'can drift from aiq.nodes, and did: %',
                r.relname, r.polname, r.qual;
        end if;
    end loop;

    if not found then
        raise exception 'aiq.node_keys / aiq.edges have no RLS policies at all';
    end if;
    raise notice 'query/02: node_keys and edges derive visibility from nodes';
end $$;

-- ---------------------------------------------------------------------
-- 4. EMBEDDING SPACES PARTITION BY MODEL, NOT DIMENSION.
--
-- Two different 768-dimension models produce vectors that are not comparable.
-- A registry keyed on dimension would happily rank them against each other and
-- return confident nonsense, so the model NAME identifies the space and the
-- dimension is merely an attribute of it.
--
-- The assertion is on the key, not on a column list: `dim` may repeat freely,
-- and the name may not.
-- ---------------------------------------------------------------------
do $$
declare v_pk text;
begin
    select pg_get_constraintdef(oid) into v_pk
    from pg_constraint
    where conrelid = 'aiq.embedding_models'::regclass and contype = 'p';

    if v_pk is distinct from 'PRIMARY KEY (name)' then
        raise exception 'aiq.embedding_models is not keyed by model name (%) -- '
                        'a space keyed on anything else can compare vectors from '
                        'two different models that happen to share a dimension', v_pk;
    end if;

    -- and nothing may make the dimension unique: two models of the same size
    -- must be able to coexist as separate spaces.
    if exists (
        select 1 from pg_index i
        join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any (i.indkey)
        where i.indrelid = 'aiq.embedding_models'::regclass
          and i.indisunique and a.attname = 'dim'
    ) then
        raise exception 'a unique index covers embedding_models.dim -- two 768-dim '
                        'models could not coexist, which is the whole point';
    end if;

    raise notice 'query/02: embedding spaces are keyed by model name, not dimension';
end $$;

-- ---------------------------------------------------------------------
-- A NUMBER THE ENGINE CANNOT HONOUR IS REFUSED, NOT ROUNDED.
--
-- GRAPH has refused `DEPTH 0` since a measured failure, with the right
-- sentence: it "asked for no traversal and would have been served a depth-1
-- one". Two siblings never got the same treatment, and both were found by
-- writing the impossible value and reading what came back:
--
--   RELEVANCE "acme" LIMIT -1  ->  rows: [], exhausted: false, unresolved: []
--
-- which is this envelope's way of saying "that entity exists and nothing is
-- related to it". It is the collapse `unresolved` exists to prevent, reached
-- from the other side -- not a name that failed to resolve, but a bound that
-- could not be honoured.
--
--   PATH "acme" "ndlr" DEPTH -3  ->  a two-hop walk, under `plan.depth: -3`
--
-- because the dispatch passed `greatest(depth, 2)` while the envelope echoed
-- what the caller wrote. The plan is the one artefact this dialect tells a
-- reader to trust, and it was reporting a bound the walk had not used.
-- ---------------------------------------------------------------------
do $$
declare
    v_q text;
    v_bad text[] := array[
        'RELEVANCE "acme" LIMIT -1',
        'RELEVANCE "acme" LIMIT 0',
        'LOOKUP "acme" LIMIT -7',
        'PATH "acme" "ndlr" DEPTH -3',
        'PATH "acme" "ndlr" DEPTH 0'];
    v_ok  boolean;
begin
    foreach v_q in array v_bad loop
        v_ok := false;
        begin
            perform aiq.query(v_q);
            v_ok := true;
        exception when others then
            if sqlerrm !~ '(LIMIT must be at least 1|DEPTH must be at least 1)' then
                raise exception '`%` was refused for the wrong reason: %', v_q, sqlerrm;
            end if;
        end;
        if v_ok then
            raise exception
                '`%` was answered rather than refused. A bound the engine '
                'cannot honour must not come back as an empty result or a '
                'silently different walk -- that is indistinguishable from '
                '"there is nothing to find".', v_q;
        end if;
    end loop;
    raise notice 'query/02: a LIMIT or DEPTH the engine cannot honour is refused, not rounded';
end $$;

-- And the plan reports the depth actually walked. DEPTH 1 is still clamped --
-- a route between two distinct nodes needs two hops to be worth searching --
-- but the clamp is now visible in the plan instead of silent.
do $$
declare v_plan jsonb;
begin
    v_plan := aiq.query('PATH "acme" "ndlr" DEPTH 1')->'plan';
    if (v_plan->>'depth')::int <> 2 then
        raise exception
            'PATH DEPTH 1 reports depth % in the plan, and the walk it runs is '
            'bounded at 2 -- a plan that does not say what was walked is the '
            'defect, not the clamp', v_plan->>'depth';
    end if;

    -- The default is the parser's, not the dispatcher's, and it must survive
    -- this: an unwritten DEPTH on PATH is 6, never GRAPH's 1.
    v_plan := aiq.query('PATH "acme" "ndlr"')->'plan';
    if (v_plan->>'depth')::int <> 6 then
        raise exception
            'PATH with no DEPTH reports %, expected the parser''s own default '
            'of 6 -- a one-hop default would mean "only things already '
            'adjacent", which is not what asking for a path means',
            v_plan->>'depth';
    end if;
    raise notice 'query/02: the plan reports the depth PATH actually walks';
end $$;

-- The rule SCHEMA teaches has to be the rule the parser enforces. The
-- registered example said "DEPTH applies only to GRAPH", and the parser has
-- said "DEPTH applies to GRAPH and PATH" since PATH grew a depth -- so an
-- agent reading SCHEMA before writing a query was taught not to use a modifier
-- that works.
do $$
declare v_txt text; v_refused boolean := false;
begin
    select note into v_txt from aiq.schema_examples
     where facet = 'p8ql' and label = 'graph-walk';
    if v_txt is null then
        raise exception 'the graph-walk schema example is missing -- SCHEMA '
                        'teaches the dialect and this is one of its rules';
    end if;
    if v_txt ~ 'DEPTH applies only to GRAPH' then
        raise exception
            'the graph-walk example still teaches "DEPTH applies only to '
            'GRAPH", which the parser contradicts by accepting PATH ... DEPTH';
    end if;

    begin
        perform aiq.query('LOOKUP "acme" DEPTH 2');
    exception when others then
        v_refused := true;
        if sqlerrm ~ 'RELEVANCE is not one' then
            raise exception
                'DEPTH on LOOKUP was refused by naming RELEVANCE, a mode the '
                'caller did not write: %', sqlerrm;
        end if;
    end;
    if not v_refused then
        raise exception 'DEPTH on LOOKUP was accepted';
    end if;
    raise notice 'query/02: DEPTH is refused off GRAPH/PATH, naming the mode written';
end $$;

rollback;
