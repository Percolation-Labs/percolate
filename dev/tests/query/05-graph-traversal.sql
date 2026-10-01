-- GRAPH SURFACE, part 2 -- traversal and the dialect that reaches it.
--
-- `04-graph-identity.sql` builds its own fixture because it tests the WRITE
-- path. This file reads the committed one in `dev/init/04-graph-sample.sql`:
-- a walk is only interesting over a graph with a cycle, a hub, a node
-- reachable two ways, and a node reachable no way, and building all that per
-- assertion would test a fixture rather than the engine.
--
-- The characteristic failure here is the one dev/tests/README.md names for
-- this whole surface: not a crash, a WRONG ANSWER. Every assertion below
-- corresponds to a query that returned rows -- confidently, with no error --
-- that were not the rows the caller asked for.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

-- The sample is a dependency, so say so once, clearly, rather than failing
-- twelve times with something that reads like an engine bug.
do $$
begin
    if not exists (select 1 from aiq.entity_registry where entity_type = 'company'
                    and source_table = 'demo.companies') then
        raise exception
            'the graph sample is not loaded. It ships in dev/init/04-graph-sample.sql '
            'and a fresh `docker compose up` installs it; against a stack that '
            'predates it, load it by hand:  docker exec -i % psql -U p8 -d % '
            '< dev/init/04-graph-sample.sql', 'p8-experiment-pg19', 'p8experiment';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. DEPTH 1 AGREES WITH THE TABLE IT READS, AND THERE IS NO SECOND COPY.
--
-- graph-identity.md verification: depth 1 and the edge table return the same
-- id pairs for a fixture. Depth 1 was a GRAPH_TABLE match over a property
-- graph until SQL/PGQ left PostgreSQL 19 (schema.sql section 5); it is a join
-- over aiq.edges_current now, and what is asserted is the function a caller
-- uses, over every node, rather than the mechanism under it.
-- ---------------------------------------------------------------------
do $$
declare v_fn int; v_tbl int;
begin
    select count(*) into v_fn from (
        select n.id, g.neighbor_id from aiq.nodes n,
               lateral aiq.graph_neighbors(n.id, null, 100000) g
         where g.direction = 'out'
        except
        select src_id, dst_id from aiq.edges_current) x;
    select count(*) into v_tbl from (
        select src_id, dst_id from aiq.edges_current
        except
        select n.id, g.neighbor_id from aiq.nodes n,
               lateral aiq.graph_neighbors(n.id, null, 100000) g
         where g.direction = 'out') y;
    if v_fn <> 0 or v_tbl <> 0 then
        raise exception
            'graph_neighbors and aiq.edges_current disagree (% pairs only from the '
            'function, % only in the view)', v_fn, v_tbl;
    end if;
    raise notice 'query/05: graph_neighbors depth 1 returns exactly the current edges';
end $$;

-- No property graph survives in aiq: a database built on a PG19 beta had
-- aiq.knowledge_graph, and the upgrade drops it. relkind 'g' exists only on
-- servers that had SQL/PGQ, so on any other the count is trivially zero.
do $$
begin
    if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                where n.nspname = 'aiq' and c.relkind = 'g') then
        raise exception 'a property graph is still declared in aiq';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. THE REVERSE QUESTION IS FIRST-CLASS, AND ITS LABEL ROUND-TRIPS.
--
-- No inverse edge is stored. "What points at Acme?" is answered by walking
-- dst_id, and the label comes from the catalogue at read time -- so a caller
-- sees `employs` for an inbound `works_at`.
--
-- Which was where the bug was: the label was display-only. `GRAPH "ACME" TYPE
-- employs` returned nothing, so the dialect showed a relation name it refused
-- to accept back. A result you cannot feed into the next query is half a
-- result, and this surface's whole discipline (lazy-then-load, brief.md §2) is
-- built on feeding results into the next query.
-- ---------------------------------------------------------------------
do $$
declare v_acme uuid; v_in int; v_out int;
begin
    select node_id into v_acme from aiq.lookup('ACME');

    select count(*) filter (where direction = 'in'),
           count(*) filter (where direction = 'out')
      into v_in, v_out
      from aiq.graph_neighbors(v_acme);
    if v_in = 0 or v_out = 0 then
        raise exception 'the walk is one-directional (% in, % out) -- the reverse '
                        'question is answered from dst_id, not from a second '
                        'stored edge', v_in, v_out;
    end if;

    -- the inbound subsidiaries carry the catalogue's inverse label...
    if not exists (select 1 from aiq.graph_neighbors(v_acme)
                    where key = 'cygl' and relation = 'parent_of' and direction = 'in') then
        raise exception 'an inbound edge does not carry its catalogue inverse label';
    end if;
    -- ...and that label is a usable filter
    if not exists (select 1 from aiq.graph_neighbors(v_acme, 'parent_of')) then
        raise exception
            'TYPE parent_of found nothing, though the depth-1 answer labels an '
            'edge parent_of -- the read path shows a name the query refuses';
    end if;
    -- the forward name still works, and names the same edge
    if (select count(*) from aiq.graph_neighbors(v_acme, 'subsidiary_of'))
       <> (select count(*) from aiq.graph_neighbors(v_acme, 'parent_of')) then
        raise exception 'the two names for one edge do not name the same edges';
    end if;
    raise notice 'query/05: inbound edges carry an inverse label that filters';
end $$;

-- ---------------------------------------------------------------------
-- 3. A WALK RETURNS ONE ROW PER NODE, AT ITS SHORTEST DEPTH.
--
-- Meridian is reachable from Acme at depth 2 by two routes (via Cygnus and
-- via Helios) and the fixture has it that way on purpose. Enumerating paths
-- is a different question from enumerating nodes, and this mode answers the
-- second one.
-- ---------------------------------------------------------------------
do $$
declare v_acme uuid; v_n int;
begin
    select node_id into v_acme from aiq.lookup('ACME');
    select count(*) into v_n from aiq.graph_walk(v_acme, 2) where key = 'mrdn';
    if v_n <> 1 then
        raise exception 'a node reachable by two routes came back % times -- the '
                        'walk is enumerating paths, not nodes', v_n;
    end if;
    if (select depth from aiq.graph_walk(v_acme, 2) where key = 'ndlr') is distinct from 1 then
        raise exception 'a node reachable at depth 1 and depth 2 was not reported '
                        'at its shortest distance';
    end if;
    -- the three-cycle must terminate, and must not report the seed
    if exists (select 1 from aiq.graph_walk(v_acme, 3) where node_id = v_acme) then
        raise exception 'a cycle walked back to the seed and reported it as its '
                        'own neighbour';
    end if;
    raise notice 'query/05: one row per node, at its shortest depth, cycles guarded';
end $$;

-- ---------------------------------------------------------------------
-- 4. THE WALK IS COHERENCE-RANKED, AND THE CAP TRUNCATES THE RIGHT END.
--
-- brief.md §3.6 puts a fused coherence score in `edges.weight` and says a
-- traversal is "coherence-ranked for free" because "graph_walk orders by
-- accumulated weight along the path rather than treating every edge as
-- equally believed."
--
-- It did not. The walk ordered by node id and never read `weight` at all, so
-- the entire scoring pipeline was discarded at the read step -- which is
-- precisely the failure §3.6 exists to prevent. `path_weight` is now the
-- product of the edge weights along the path, and the row cap is applied to
-- an ordered result: a capped walk keeps the nearest and best-corroborated
-- rather than an arbitrary subset chosen by uuid.
-- ---------------------------------------------------------------------
do $$
declare v_acme uuid; v_strong real; v_weak real; r record; v_prev record;
begin
    select node_id into v_acme from aiq.lookup('ACME');

    -- Cygnus is a 0.95 subsidiary claim; Borealis a 0.35 blog rumour. Both
    -- are one hop away, so only the weight can separate them.
    select path_weight into v_strong from aiq.graph_walk(v_acme, 2) where key = 'cygl';
    select path_weight into v_weak   from aiq.graph_walk(v_acme, 2) where key = 'brls';
    if v_strong is null or v_weak is null then
        raise exception 'the walk does not report a path weight at all';
    end if;
    if not (v_strong > v_weak) then
        raise exception 'a well-corroborated hop (%) does not outrank a rumour (%)',
            v_strong, v_weak;
    end if;

    -- ...and the weight compounds along the path rather than being the last
    -- edge's: Meridian is 0.95 * 0.60, not 0.60.
    if abs((select path_weight from aiq.graph_walk(v_acme, 2) where key = 'mrdn')
           - 0.57) > 0.001 then
        raise exception 'path weight does not accumulate along the path (got %)',
            (select path_weight from aiq.graph_walk(v_acme, 2) where key = 'mrdn');
    end if;

    -- the result is ordered: depth first, then weight
    for r in select depth, path_weight from aiq.graph_walk(v_acme, 2) loop
        if v_prev is not null then
            if r.depth < v_prev.depth
               or (r.depth = v_prev.depth and r.path_weight > v_prev.path_weight) then
                raise exception 'the walk is not ordered by depth then weight';
            end if;
        end if;
        v_prev := r;
    end loop;

    -- the cap keeps the near end, not a uuid-ordered slice
    if exists (select 1 from aiq.graph_walk(v_acme, 2, null, 3) where depth > 1) then
        raise exception
            'a walk capped at 3 nodes returned a depth-2 node while depth-1 nodes '
            'were dropped -- the cap is truncating an unordered result';
    end if;
    raise notice 'query/05: the walk is weighted, ordered, and capped from the far end';
end $$;

-- ---------------------------------------------------------------------
-- 5. TYPE FILTERS, AND A RELATION NAME CROSSING TWO ENTITY TYPES.
--
-- `mentions` is catalogued twice -- event->company and event->person -- which
-- is the shape that makes a relation name, rather than a table pair, the unit
-- a caller filters on.
-- ---------------------------------------------------------------------
do $$
declare v_ev uuid;
begin
    select node_id into v_ev from aiq.lookup('Acme Q3 results');
    if (select count(distinct entity_type) from aiq.graph_neighbors(v_ev, 'mentions')) <> 2 then
        raise exception 'TYPE mentions did not cross entity types, though the '
                        'catalogue lists it for two';
    end if;
    if exists (select 1 from aiq.graph_neighbors(v_ev, 'mentions') where relation <> 'mentions') then
        raise exception 'the TYPE filter let another relation through';
    end if;
    raise notice 'query/05: one relation name spans the entity types it is catalogued for';
end $$;

-- ---------------------------------------------------------------------
-- 6. HARD LINKS ARE NOT EDGES, AND ARE STILL ANSWERABLE (D4).
--
-- The "two memories" claim, concretely: demo.events.primary_company_id is a
-- foreign key, so it is never copied into aiq.edges, and the question it
-- answers is served by an indexed join from the typed row once identity is
-- known. A design that quietly materialised FKs into `edges` would pass every
-- traversal assertion above and fail this one.
-- ---------------------------------------------------------------------
do $$
declare v_ev uuid;
begin
    select node_id into v_ev from aiq.lookup('Acme Q3 results');
    if exists (select 1 from aiq.edges e
                where e.src_id = v_ev and e.relation like 'primary%') then
        raise exception 'a foreign key has been materialised into aiq.edges (D4)';
    end if;
    if (select c.name from aiq.nodes n
          join demo.events ev on ev.id = n.entity_id
          join demo.companies c on c.id = ev.primary_company_id
         where n.id = v_ev) is distinct from 'Acme Robotics' then
        raise exception 'the hard link is not answerable from the node -- the '
                        'other half of "two memories"';
    end if;
    raise notice 'query/05: hard links stay relational and stay answerable';
end $$;

-- ---------------------------------------------------------------------
-- 7. THE DATA PLANE NEVER BECOMES NODES.
--
-- demo.filings is machine-generated, is registered nowhere, and joins in
-- after identity is known. Asserted as a count rather than a spot check: the
-- failure mode is a well-meaning registration of a high-rate table, which
-- shows up as thousands of nodes, not one.
-- ---------------------------------------------------------------------
do $$
begin
    if exists (select 1 from aiq.nodes n join demo.filings f on f.id = n.entity_id) then
        raise exception 'data-plane rows have been projected into the registry '
                        '-- the inclusion policy is the thing keeping LOOKUP '
                        'O(log n) in the CURATED set rather than in everything';
    end if;
    if exists (select 1 from aiq.entity_registry where source_table = 'demo.filings') then
        raise exception 'the data-plane table has been registered as an entity type';
    end if;
    raise notice 'query/05: the data plane is not in the registry';
end $$;

-- ---------------------------------------------------------------------
-- 8. THE DIALECT RESOLVES ITS SEED EXACTLY, AND SAYS WHICH NODE IT WALKED.
--
-- Three failures, all silent, all in one line of the dispatch:
--   select node_id ... from aiq.lookup(arg, TRUE, 1) limit 1
--
--   * fuzzy, always: GRAPH "ACMEE" walked Acme's neighbourhood and returned
--     it as though that were what was asked. The dialect makes FUZZY an
--     explicit prefix on LOOKUP and refuses it on every other mode -- GRAPH
--     was doing it unasked and with no way to turn it off.
--   * limit 1, unordered: GRAPH "borealis" -- a short key that
--     graph-identity.md's own Bakhmut example says belongs to two nodes --
--     picked one by coin flip.
--   * and the result named neither. Nothing downstream could tell which node
--     had been walked, so neither failure was observable from the answer.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    -- a typo resolves to nothing, and offers what it nearly matched
    v := aiq.query('GRAPH "ACMEE"');
    if jsonb_array_length(v->'rows') <> 0 then
        raise exception 'a misspelled seed silently walked some other node''s '
                        'neighbourhood: %', v->'rows'->0;
    end if;
    if v->>'error' is null then
        raise exception 'an unresolvable seed returned an empty result and no error';
    end if;
    if jsonb_array_length(v->'did_you_mean') = 0 then
        raise exception 'a near miss offers no suggestion, so the trigram index '
                        'this schema maintains helps nobody at the one moment '
                        'it could';
    end if;
    -- the parse travels even on the error path: this is the case where the
    -- caller most needs to see how the string was read (query/02 §2).
    if v->'plan' is null then
        raise exception 'the error path drops the plan';
    end if;

    -- an ambiguous seed is refused, with the candidates
    v := aiq.query('GRAPH "borealis"');
    if jsonb_array_length(v->'rows') <> 0 then
        raise exception 'an ambiguous seed was resolved by picking one of the '
                        'nodes it names';
    end if;
    if jsonb_array_length(v->'candidates') <> 2 then
        raise exception 'the ambiguity is refused without saying what it was between';
    end if;

    -- an exact seed reports itself
    v := aiq.query('GRAPH "ACME"');
    if v->'seed'->>'key' is null or v->'seed'->>'entity_type' <> 'company' then
        raise exception 'a successful walk does not say which node it walked: %',
            v->'seed';
    end if;
    if jsonb_array_length(v->'rows') = 0 then
        raise exception 'the exact seed found no neighbours, though the fixture has six';
    end if;

    -- a node with no edges is not the same answer as a name with no node
    v := aiq.query('GRAPH "Quill & Sons"');
    if v->>'error' is not null or v->'seed' is null then
        raise exception 'a node with no neighbours was reported as unresolvable';
    end if;
    raise notice 'query/05: the seed is exact, reported, and ambiguity is refused';
end $$;

-- ---------------------------------------------------------------------
-- 9. MODIFIERS ARE REFUSED WHERE THEY MEAN NOTHING, NOT DROPPED.
--
-- The rule is already stated for USING (brief.md §3): "silently dropping a
-- modifier the caller wrote is how a query quietly means something else."
-- Three more constructs were being dropped or reinterpreted by the GRAPH
-- branch, each measured.
-- ---------------------------------------------------------------------
do $$
declare v_msg text;
begin
    -- FROM names a corpus; a walk starts at a node
    begin
        perform aiq.query('GRAPH "ACME" FROM chunks');
        raise exception 'FROM was accepted on GRAPH and ignored';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%FROM%' then raise; end if;
    end;

    -- DEPTH 0 asked for no traversal and was served a depth-1 one
    begin
        perform aiq.query('GRAPH "ACME" DEPTH 0');
        raise exception 'DEPTH 0 was accepted and answered as DEPTH 1';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%at least 1%' then raise; end if;
    end;

    -- unbounded traversal is a stated non-goal and was unenforced
    begin
        perform aiq.query('GRAPH "ACME" DEPTH 1000');
        raise exception 'DEPTH 1000 was accepted -- unbounded traversal is a '
                        'stated non-goal (graph-identity.md)';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%ceiling%' then raise; end if;
    end;

    -- a relation nobody catalogued is a typo, and returning [] for it is this
    -- surface's signature failure: a wrong answer that looks like an empty one
    begin
        perform aiq.query('GRAPH "ACME" TYPE not_a_relation');
        raise exception 'an uncatalogued relation returned an empty result '
                        'instead of saying the name is not a relation';
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%catalogue%' then raise; end if;
    end;

    -- ...while a real relation that simply has no matches here is a legitimate
    -- empty answer, and must stay one.
    if (aiq.query('GRAPH "Quill & Sons" TYPE competes_with')->>'error') is not null then
        raise exception 'a catalogued relation with no matches was reported as an error';
    end if;
    raise notice 'query/05: GRAPH refuses the modifiers it cannot honour';
end $$;

-- ---------------------------------------------------------------------
-- 10. LOOKUP REPORTS WHAT IT DID NOT FIND.
--
-- lookup_many exists to answer "which of these five names resolved" -- that
-- is the entire reason it returns `input_key`, and its own comment says so.
-- It joined LATERALLY without LEFT, so a key that matched nothing produced no
-- row: the column could only ever report keys that had been found, which is
-- the one case the caller can already work out.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    if not exists (select 1 from aiq.lookup_many(array['ACME','no-such-key','NDLR'])
                    where input_key = 'no-such-key' and node_id is null) then
        raise exception 'a key that matched nothing did not come back at all, so '
                        '"which of these did you not find" is unanswerable';
    end if;
    if (select count(*) from aiq.lookup_many(array['ACME','no-such-key','NDLR'])
         where node_id is not null) <> 2 then
        raise exception 'the misses displaced the hits';
    end if;

    -- And the dialect carries it through -- in `unresolved`, not as a row.
    --
    -- This assertion used to require the miss to appear in `rows` with a null
    -- key, mirroring lookup_many above. The guarantee it was protecting is the
    -- right one and is unchanged; the mechanism was wrong one layer out. In
    -- the JSON envelope a null row makes `rows` non-empty, so a miss is
    -- indistinguishable from a hit to any consumer that does not inspect the
    -- fields -- a model asked about sterling read `rows: [{…}]`, concluded it
    -- had found the node, and answered as though it had.
    --
    -- So the two are separated: SQL callers still get one result set to
    -- filter, and the dialect answers "which of these did you not find"
    -- directly. Both halves are asserted, because dropping either one is a
    -- regression: an empty result must be empty, AND the misses must be named.
    v := aiq.query('LOOKUP "ACME", "no-such-key"');
    if not exists (select 1 from jsonb_array_elements_text(v->'unresolved') u
                    where u = 'no-such-key') then
        raise exception 'the dialect drops the keys it did not resolve';
    end if;
    if exists (select 1 from jsonb_array_elements(v->'rows') r
                where r->>'key' is null) then
        raise exception
            'a miss came back as a row: `rows` is now non-empty for a lookup '
            'that found nothing, which reads as a hit';
    end if;
    if jsonb_array_length(v->'rows') <> 1 then
        raise exception 'the hit was displaced by the miss';
    end if;
    raise notice 'query/05: a lookup list reports its misses, and only in unresolved';
end $$;

-- ---------------------------------------------------------------------
-- 11. THE LOOKUP CASCADE: CANONICAL, THEN SHORT/ALIAS, THEN (OPT-IN) FUZZY.
--
-- Order matters and so does stopping: an exact canonical hit must not be
-- diluted by short-key matches on the same string, and fuzzy must never run
-- unasked -- it is the only branch that can return a node the caller did not
-- name.
-- ---------------------------------------------------------------------
do $$
begin
    if (select match_kind from aiq.lookup('ACME')) is distinct from 'canonical' then
        raise exception 'an exact canonical key did not match as canonical';
    end if;
    -- 'acme' is a SHORT key for the same node; the cascade stops at canonical
    -- for 'ACME' and finds the short one for 'acme'... which is also this
    -- node's canonical key, so the assertion worth making is that one node
    -- comes back once, not that a particular kind won.
    if (select count(*) from aiq.lookup('acme')) <> 1 then
        raise exception 'a node with a canonical AND a short spelling of one '
                        'string came back more than once';
    end if;
    -- the Bakhmut case: one short key, two nodes, two types -- correct, and
    -- the reason LOOKUP is documented as returning a set
    if (select count(distinct entity_type) from aiq.lookup('borealis')) <> 2 then
        raise exception 'a short key shared by two entity types resolved to one';
    end if;
    -- fuzzy is opt-in
    if exists (select 1 from aiq.lookup('acme robotcs')) then
        raise exception 'a misspelling matched without FUZZY -- trigram matching '
                        'ran unasked';
    end if;
    if not exists (select 1 from aiq.lookup('acme robotcs', true)) then
        raise exception 'FUZZY does not reach the alias it was given for';
    end if;
    -- ...and it is one row per node, not per matching key
    if (select count(*) from aiq.lookup('acme robotic', true)) <>
       (select count(distinct node_id) from aiq.lookup('acme robotic', true)) then
        raise exception 'a node with several matching keys came back once per key';
    end if;
    raise notice 'query/05: the lookup cascade orders, stops, and dedupes';
end $$;

-- ---------------------------------------------------------------------
-- 12. LOOKUP RESOLVES IDENTITY FROM THE KEY INDEX, NEVER FROM THE TYPED TABLES.
--
-- Invariant 6, and the whole scale argument: identity is a probe on a thin key
-- table, so 10^9 KEYS stays O(log n) regardless of how many rows exist. The
-- failure this guards against is a well-meaning rewrite of LOOKUP as a UNION
-- ALL over the registered entity tables -- correct, passing every other
-- assertion in this file, and the slow form of identity
-- (graph-identity.md "Read path": "Parallel Append of a global union is the
-- slow form of identity").
--
-- Two assertions, and NEITHER is "the plan says Index Scan". At fixture scale
-- the planner reads a 22-row table sequentially and is right to -- so an
-- assertion on the chosen node type would fail here for a reason that has
-- nothing to do with the design, and would have to be neutered to pass. What
-- is size-independent is (a) that the index the argument depends on exists and
-- is usable for the predicate, and (b) that no source table is touched at all.
-- ---------------------------------------------------------------------
do $$
declare
    v_line text;
    v_plan text := '';
    v_src  text;
begin
    -- (a) the index exists and the planner will use it when the table is big
    --     enough to be worth it. enable_seqscan = off is how you ask "is this
    --     predicate index-servable" without needing a million rows to prove it.
    set local enable_seqscan = off;
    for v_line in
        execute 'explain (costs off) select n.id from aiq.node_keys k '
                'join aiq.nodes n on n.id = k.node_id '
                'where k.key = ''acme'' and k.kind = ''canonical'''
    loop
        v_plan := v_plan || v_line || E'\n';
    end loop;
    if v_plan !~* 'Index (Only )?Scan|Bitmap Index Scan' then
        raise exception
            'the canonical-key predicate is not index-servable -- invariant 6 '
            'and the O(log n) claim rest on it. Plan was:%', E'\n' || v_plan;
    end if;
    reset enable_seqscan;

    -- (b) and identity is derived without reading a single typed table.
    for v_src in select source_table from aiq.entity_registry loop
        if v_plan ~* ('\m' || split_part(v_src, '.', 2) || '\M') then
            raise exception
                'resolving a key touches %, a registered source table -- LOOKUP '
                'has become a union over the data plane (invariant 6)', v_src;
        end if;
    end loop;

    -- ...and the trigram index FUZZY depends on is on the key table, not on
    -- anything wider. "Do not GIN-trigram the data plane to answer global
    -- FUZZY" (graph-identity.md "Scale").
    if not exists (
        select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
        join pg_am am on am.oid = c.relam
        where i.indrelid = 'aiq.node_keys'::regclass and am.amname = 'gin') then
        raise exception 'the trigram index on node_keys is gone -- FUZZY either '
                        'stopped working or moved somewhere wider';
    end if;
    raise notice 'query/05: identity comes from the key index, not from the typed tables';
end $$;

-- ---------------------------------------------------------------------
-- 13. THE SCHEMA FACET DESCRIBES THE GRAPH THAT IS ACTUALLY THERE.
--
-- SCHEMA "graph" is what an agent reads before writing its first edge, and
-- the failure mode of a self-description is a confident answer that stopped
-- being true. The facet had no examples at all, which is the half most likely
-- to be copied and the half most likely to rot -- so they are registered, and
-- verified by the real parser on every read.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    v := aiq.schema('graph')->'doc';
    if not exists (select 1 from jsonb_array_elements(v->'derived'->'entity_types') e
                    where e->>'entity_type' = 'company') then
        raise exception 'the graph facet does not list a registered entity type';
    end if;
    if not exists (select 1 from jsonb_array_elements(v->'derived'->'relations') r
                    where r->>'relation' = 'subsidiary_of' and r->>'inverse_label' = 'parent_of') then
        raise exception 'the facet does not carry the inverse labels the read path uses';
    end if;
    if jsonb_array_length(v->'examples') = 0 then
        raise exception 'the graph facet ships no examples -- the part an agent '
                        'copies is the part nothing checks';
    end if;
    if exists (select 1 from jsonb_array_elements(v->'examples') e
                where (e->>'verified')::boolean is not true) then
        raise exception 'a graph example no longer parses: %',
            (select e->>'example' from jsonb_array_elements(v->'examples') e
              where (e->>'verified')::boolean is not true limit 1);
    end if;
    -- the facet tells an author the COLUMN NAMES, because the catalogue alone
    -- sent the first author who read it guessing (schema.sql §13g)
    if v->'derived'->'edge_write'->'columns'->>'src_id' is null then
        raise exception 'the facet describes relations without describing how to write one';
    end if;
    raise notice 'query/05: SCHEMA "graph" describes the live graph, examples verified';
end $$;

-- ---------------------------------------------------------------------
-- 14. A RETRACTED EDGE IS NOT TRAVERSED. (Inverted, as this section asked.)
--
-- This section pinned the opposite: `valid_from` / `valid_to` were stored and
-- no read path here filtered on them, recorded as a gap in graph-identity.md
-- "Temporal validity", with the instruction to invert the assertion rather than
-- delete it on the day the filter landed. It landed with REM-51: the property
-- graph is declared over aiq.edges_current, and graph_neighbors and graph_walk
-- read it, so all three apply aiq.edge_is_current. query/15 asserts the same
-- for every other read path, including the compiled ones.
-- ---------------------------------------------------------------------
do $$
declare v_acme uuid; v_before int; v_after int;
begin
    select node_id into v_acme from aiq.lookup('ACME');
    select count(*) into v_before from aiq.graph_neighbors(v_acme, 'competes_with');
    update aiq.edges set valid_to = now() - interval '1 year' where relation = 'competes_with';
    select count(*) into v_after from aiq.graph_neighbors(v_acme, 'competes_with');
    if v_before = 0 then
        raise exception 'the fixture gives ACME no competes_with neighbours, so this proves nothing';
    end if;
    if v_after <> 0 then
        raise exception
            'graph_neighbors returned % competes_with edges after every one was retracted '
            '(% before) -- traversal has stopped applying aiq.edge_is_current', v_after, v_before;
    end if;
    raise notice 'query/05: retracted edges are not traversed (% neighbours before, 0 after)', v_before;
end $$;

rollback;
