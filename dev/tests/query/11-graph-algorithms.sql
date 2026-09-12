-- GRAPH SURFACE, part 5 -- the compiled algorithms.
--
-- `05` asserts the traversal, `06` asserts who may see it. This file asserts
-- the half that runs in Rust: that the ranked, path and connecting answers are
-- the ones the fixture implies, that a budget is reported rather than silently
-- spent, and -- the assertion this file exists for -- that the backend-local
-- adjacency snapshot cannot serve one tenant's graph to another.
--
-- That last one is not a hypothetical. The snapshot is built through SPI as
-- the caller, so it is correct when it is built and stays correct only because
-- every entry point re-checks the fingerprint it was built under. Remove that
-- check and every assertion in `06` is still true while the whole graph leaks
-- through a cached array.
--
-- Reads the committed sample (`dev/init/04-graph-sample.sql`).

\set ON_ERROR_STOP on

\set org_a '''a0000000-0000-0000-0000-00000000000a'''
\set org_b '''a0000000-0000-0000-0000-00000000000b'''

begin;

do $$
begin
    if to_regprocedure('p8_graph_ppr(uuid[],float8,float8,int,int,bool,text,bigint)') is null then
        raise exception
            'the installed percolate_parser does not DECLARE the graph algorithms '
            '(percolate_parser %, on this database)',
            (select extversion from pg_extension where extname = 'percolate_parser')
            using detail =
                'This is a missing SQL declaration, not necessarily a missing '
                '.so -- the two halves ship as separate files and drift apart '
                'independently. The first version of this message said "they '
                'are compiled, so a SQL reload does not carry them: copy the '
                '.so", and it was wrong where it fired: the .so in the '
                'container held all thirty p8_graph symbols and what was '
                'missing was percolate_parser--<version>.sql.',
            hint =
                'Check the .so first (nm -D percolate_parser.so | grep p8_graph). '
                'If the symbols are there, the extension SQL is behind: '
                'percolate_parser must be reinstalled, and CREATE EXTENSION IF '
                'NOT EXISTS will not do it -- Postgres does not re-run a script '
                'for a version it already records. Otherwise rebuild: '
                'dev/build-image.sh.';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. THE SNAPSHOT REPORTS THE GRAPH IT ACTUALLY READ.
--
-- Not a tautology: the build drops any edge whose endpoint it cannot see, so
-- a snapshot with more edges than the caller can select is the first symptom
-- of the leak this file is about.
-- ---------------------------------------------------------------------
do $$
declare v jsonb; v_nodes bigint; v_edges bigint;
begin
    v := aiq.graph_snapshot(true);
    select count(*) into v_nodes from aiq.nodes;
    select count(*) into v_edges from aiq.edges;
    if (v->'snapshot'->>'nodes')::bigint <> v_nodes then
        raise exception 'snapshot holds % nodes, the table has %',
            v->'snapshot'->>'nodes', v_nodes;
    end if;
    if (v->'snapshot'->>'edges')::bigint > v_edges then
        raise exception 'snapshot holds MORE edges (%) than are visible (%)',
            v->'snapshot'->>'edges', v_edges;
    end if;
    raise notice 'query/11: snapshot matches the visible graph (% nodes, % edges)',
        v_nodes, v_edges;
end $$;

-- ---------------------------------------------------------------------
-- 2. RELATED RANKS, AND RANKS THE SEED FIRST.
--
-- The seed outranking its own neighbours is the cheapest available check that
-- the walk is a personalised one: an unpersonalised PageRank ranks the hub
-- first regardless of where you started, and on this fixture that would be a
-- different node.
-- ---------------------------------------------------------------------
do $$
declare v_top uuid; v_seed uuid; v_n int;
begin
    select node_id into v_seed from aiq.lookup('acme', false, 1);
    select node_id, count(*) over () into v_top, v_n
      from aiq.related(array['acme'], 10) limit 1;
    if v_top is distinct from v_seed then
        raise exception 'related("acme") ranked % first, not the seed %', v_top, v_seed;
    end if;
    if v_n < 3 then
        raise exception 'related("acme") returned only % rows on a fixture with a hub', v_n;
    end if;
    raise notice 'query/11: related ranks the seed first over % rows', v_n;
end $$;

-- ---------------------------------------------------------------------
-- 3. PATHS FINDS THE ONE-HOP ROUTE, AND OFFERS A SECOND.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    v := aiq.graph_paths('acme', 'ndlr', 2);
    if jsonb_array_length(v->'paths') < 1 then
        raise exception 'no path between acme and ndlr, which are directly linked';
    end if;
    if (v->'paths'->0->>'hops')::int <> 1 then
        raise exception 'the cheapest acme->ndlr path is % hops, not 1',
            v->'paths'->0->>'hops';
    end if;
    if jsonb_array_length(v->'paths') > 1
       and (v->'paths'->1->>'cost')::numeric <= (v->'paths'->0->>'cost')::numeric then
        raise exception 'the second path is not more expensive than the first -- k-shortest is not ordered';
    end if;
    raise notice 'query/11: paths returns % ordered routes acme->ndlr',
        jsonb_array_length(v->'paths');
end $$;

-- ---------------------------------------------------------------------
-- 4. A NAME THAT RESOLVES TO NOTHING IS SAID, NOT SWALLOWED.
--
-- The distinction the whole dialect is built to keep: "no such node" and
-- "that node has no route" are different answers.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    v := aiq.graph_paths('no-such-entity-at-all', 'acme');
    if not (v->'unresolved' @> '["no-such-entity-at-all"]'::jsonb) then
        raise exception 'an unresolvable name came back as an empty path set, not as unresolved: %', v;
    end if;
    raise notice 'query/11: an unresolvable name is reported as unresolved';
end $$;

-- ---------------------------------------------------------------------
-- 5. EVERY ANSWER CARRIES ITS BUDGET OUTCOME.
--
-- Asserted as a presence check rather than by forcing exhaustion: the fixture
-- is fifteen edges, so nothing here CAN exhaust a budget, and a test that
-- pretended otherwise would be testing the harness. What must hold on a graph
-- of any size is that the field is there and is a boolean.
-- ---------------------------------------------------------------------
do $$
declare v jsonb; v_flag boolean;
begin
    v := p8_graph_ppr(array[(select node_id from aiq.lookup('acme', false, 1))]);
    if jsonb_typeof(v->'meta'->'exhausted') <> 'boolean' then
        raise exception 'ppr did not report whether it converged: %', v->'meta';
    end if;
    select budget_exhausted into v_flag from aiq.related(array['acme'], 1);
    if v_flag is null then
        raise exception 'aiq.related did not carry the budget outcome onto its rows';
    end if;
    raise notice 'query/11: every answer carries budget_exhausted';
end $$;

-- ---------------------------------------------------------------------
-- 6. THE TEMPORAL FILTER IS APPLIED, WITH OR WITHOUT as_of.
--
-- This asserted that a walk WITHOUT as_of still crossed an expired edge --
-- "the default must still traverse it" -- which was the defect, pinned
-- (REM-51): every caller that did not name a time got the graph's whole
-- history, retractions included, while aiq.edges_current hid them from every
-- SQL reader. The default is now the statement's now(). An explicit as_of
-- from before the retraction still crosses it, which is the half that makes
-- retraction history rather than deletion.
-- ---------------------------------------------------------------------
do $$
declare
    v_default jsonb; v_now jsonb; v_before jsonb; v_edge uuid;
    v_from timestamptz; v_to timestamptz;
begin
    select e.id into v_edge
      from aiq.edges e
      join aiq.node_keys ks on ks.node_id = e.src_id and ks.key = 'acme' and ks.kind = 'canonical'
      join aiq.node_keys kd on kd.node_id = e.dst_id and kd.key = 'ndlr' and kd.kind = 'canonical'
     limit 1;
    if v_edge is null then
        raise exception 'the fixture no longer has the acme->ndlr edge this assertion is about';
    end if;

    -- valid_from too, not only valid_to: `v_before` below reads the graph as
    -- of before the retraction, and on a fresh database the fixture was loaded
    -- minutes ago, so "two days ago" was before the edge existed at all.
    select valid_from, valid_to into v_from, v_to from aiq.edges where id = v_edge;
    update aiq.edges
       set valid_from = now() - interval '3 days', valid_to = now() - interval '1 day'
     where id = v_edge;
    perform aiq.graph_snapshot(true);

    v_default := aiq.graph_paths('acme', 'ndlr', 1);
    v_now     := aiq.graph_paths('acme', 'ndlr', 1, p_as_of => now());
    v_before  := aiq.graph_paths('acme', 'ndlr', 1, p_as_of => now() - interval '2 days');

    if jsonb_array_length(v_default->'paths') > 0
       and (v_default->'paths'->0->>'hops')::int = 1 then
        raise exception 'without as_of the expired edge was still traversed'
            using hint = 'The compiled half and the extension SQL ship as separate '
                'files and drift apart independently (see this suite''s query/11 '
                'preamble). If the percolate_parser .so on this database predates '
                'REM-51, that is the cause rather than a defect in the graph: it '
                'clears on the next parser release, or now with dev/build-image.sh. '
                'Installed: percolate_parser ' ||
                coalesce((select extversion from pg_extension where extname='percolate_parser'), '?') ||
                ', percolate ' ||
                coalesce((select extversion from pg_extension where extname='percolate'), '?') ||
                coalesce((select ', parser built at ' || commit_sha from public.percolate_build
                           where component = 'parser'), '');
    end if;
    if jsonb_array_length(v_now->'paths') > 0
       and (v_now->'paths'->0->>'hops')::int = 1 then
        raise exception 'with as_of now the expired edge was still traversed';
    end if;
    if jsonb_array_length(v_before->'paths') = 0
       or (v_before->'paths'->0->>'hops')::int <> 1 then
        raise exception 'as of before its expiry the direct edge was not used -- '
            'retraction must remain readable as history';
    end if;
    -- PUT THE FIXTURE BACK. It did not need to before: a retracted edge was
    -- still traversed, so nothing downstream could tell. Now §9 reads the same
    -- triangle and counts its edges, and a section that leaves one retracted
    -- hands the next one a different graph (REM-51).
    update aiq.edges set valid_from = v_from, valid_to = v_to where id = v_edge;
    perform aiq.graph_snapshot(true);
    raise notice 'query/11: an expired edge is excluded by default and by as_of now, and used as of before';
end $$;

-- ---------------------------------------------------------------------
-- 7. A SYMMETRIC RELATION IS STORED ONCE, IN ONE ORDER.
--
-- The unique index is on the ORDERED triple, so without normalisation both
-- (a,b,r) and (b,a,r) are legal rows describing one fact -- and the traversal
-- unions out-edges with in-edges, so it would see that neighbour twice: twice
-- the share of PageRank mass, a degree of two in k-core. The failure is a
-- wrong number, not an error, which is why it is asserted rather than trusted.
-- ---------------------------------------------------------------------
do $$
declare v_a uuid; v_b uuid; v_n int; v_norm boolean;
begin
    select node_id into v_a from aiq.node_keys where key = 'acme' and kind = 'canonical';
    select node_id into v_b from aiq.node_keys where key = 'ndlr' and kind = 'canonical';

    insert into aiq.relation_types (src_type, relation, dst_type, is_symmetric)
    values ('company', 'same_as', 'company', true);

    -- written high-to-low on purpose
    insert into aiq.edges (src_id, dst_id, relation)
    values (greatest(v_a, v_b), least(v_a, v_b), 'same_as');

    select src_id < dst_id into v_norm from aiq.edges where relation = 'same_as';
    if not v_norm then
        raise exception 'a symmetric edge was stored in the order it was written, not normalised';
    end if;

    -- and the other orientation is the SAME row, not a second one
    insert into aiq.edges (src_id, dst_id, relation)
    values (least(v_a, v_b), greatest(v_a, v_b), 'same_as')
    on conflict do nothing;

    select count(*) into v_n from aiq.edges where relation = 'same_as';
    if v_n <> 1 then
        raise exception 'both orientations of a symmetric relation were stored: % rows', v_n;
    end if;
    raise notice 'query/11: a symmetric relation normalises to one row in one order';
end $$;

-- ---------------------------------------------------------------------
-- 8. THE SNAPSHOT CAN BE BUILT OVER A SUBSET, AND SAYS THAT IT WAS.
--
-- A filtered snapshot answers a different question from an unfiltered one, so
-- the filter rides on every result alongside the counts. The alternative -- a
-- caller unable to tell which graph it just walked -- is the same class of
-- silent wrongness the dialect emits `plan` to prevent.
-- ---------------------------------------------------------------------
do $$
declare v_all jsonb; v_one jsonb;
begin
    v_all := aiq.graph_snapshot(true);
    v_one := aiq.graph_snapshot(true, array['competes_with']);
    if (v_one->'snapshot'->>'edges')::int >= (v_all->'snapshot'->>'edges')::int then
        raise exception 'filtering to one relation did not reduce the snapshot: % vs %',
            v_one->'snapshot'->>'edges', v_all->'snapshot'->>'edges';
    end if;
    if v_one->'snapshot'->'filter'->'relations' is null then
        raise exception 'a filtered snapshot did not report its filter';
    end if;
    if jsonb_typeof(v_all->'snapshot'->'filter') <> 'null' then
        raise exception 'an unfiltered snapshot claimed a filter: %', v_all->'snapshot'->'filter';
    end if;
    raise notice 'query/11: the snapshot builds over a subset and reports which (% -> % edges)',
        v_all->'snapshot'->>'edges', v_one->'snapshot'->>'edges';
end $$;

-- ---------------------------------------------------------------------
-- 9. COMPONENTS AND INDUCED EDGES, THE TWO BULK PRIMITIVES.
--
-- The fixture's three competitors are a triangle under `competes_with`, which
-- makes it the one shape that exercises both: they must land in one component,
-- and their induced subgraph must be the three edges and nothing else.
-- ---------------------------------------------------------------------
do $$
declare v_ids uuid[]; v_comp int; v_edges int; v_members int;
begin
    perform aiq.graph_snapshot(true, array['competes_with']);
    select array_agg(node_id) into v_ids
      from aiq.node_keys where key in ('acme', 'ndlr', 'brls') and kind = 'canonical';

    select count(distinct component), count(*) into v_comp, v_members
      from aiq.graph_components(2) where node_id = any(v_ids);
    if v_members <> 3 or v_comp <> 1 then
        raise exception 'the competes_with triangle came back as % nodes in % components',
            v_members, v_comp;
    end if;

    select count(*) into v_edges from aiq.graph_induced(v_ids);
    if v_edges <> 3 then
        raise exception 'the induced subgraph of a triangle has % edges, not 3', v_edges;
    end if;
    raise notice 'query/11: components and induced agree on the triangle (1 component, 3 edges)';

    -- back to the whole graph, so later assertions are not reading a subset
    perform aiq.graph_snapshot(true);
end $$;

-- ---------------------------------------------------------------------
-- 10. THE DIALECT REACHES THEM, AND THE ENVELOPE KEEPS ITS PROMISES.
--
-- RELEVANCE is the one graph algorithm with a mode. Three things are asserted
-- rather than assumed: that DEPTH is refused (a modifier the engine would have
-- to ignore is the exact failure the dialect exists to prevent), that a name
-- resolving to nothing is reported instead of dropped, and that the budget
-- outcome rides on the envelope.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    v := aiq_parse('RELEVANCE "acme", "ndlr" LIMIT 3');
    if v->>'mode' <> 'RELEVANCE' or jsonb_array_length(v->'args') <> 2 then
        raise exception 'RELEVANCE did not parse as a two-argument mode: %', v;
    end if;
    v := aiq_parse('RELEVANCE "acme" DEPTH 2');
    if (v->>'ok')::boolean then
        raise exception 'RELEVANCE accepted DEPTH, which it would have to ignore';
    end if;

    v := aiq.query('RELEVANCE "acme", "no-such-entity-at-all" LIMIT 3');
    if not (v->'unresolved' @> '["no-such-entity-at-all"]'::jsonb) then
        raise exception 'RELEVANCE dropped an unresolvable seed instead of reporting it: %', v;
    end if;
    if jsonb_typeof(v->'exhausted') <> 'boolean' then
        raise exception 'RELEVANCE did not report its budget outcome: %', v;
    end if;
    if jsonb_array_length(v->'rows') = 0 then
        raise exception 'RELEVANCE returned nothing for a seed that resolves';
    end if;
    raise notice 'query/11: RELEVANCE parses, refuses DEPTH, and reports unresolved seeds';
end $$;

-- PATH is one mode with two arities, and the minimum is the assertion: one
-- name is neither a route nor a connecting subgraph, and whoever wrote it
-- wanted a different mode.
do $$
declare v jsonb;
begin
    v := aiq_parse('PATH "a"');
    if (v->>'ok')::boolean then
        raise exception 'PATH accepted a single name, which is neither of the things it does';
    end if;
    -- DEPTH's default is GRAPH's, and it is wrong here: a one-hop route is a
    -- direct edge. The plan must show the substituted default rather than
    -- leaving the caller to discover it from a short answer.
    if (aiq_parse('PATH "a", "b"')->>'depth')::int <> 6 then
        raise exception 'PATH did not carry its own DEPTH default into the plan';
    end if;

    v := aiq.query('PATH "acme", "ndlr" LIMIT 2');
    if jsonb_array_length(v->'rows') < 1 then
        raise exception 'PATH found no route between two directly linked nodes';
    end if;
    if jsonb_typeof(v->'exhausted') <> 'boolean' then
        raise exception 'PATH did not report its budget outcome';
    end if;

    -- Three terminals is the same mode answering the generalised question.
    v := aiq.query('PATH "acme", "ndlr", "brls"');
    if v->'rows'->0->'edges' is null then
        raise exception 'PATH with three names did not return a connecting subgraph: %', v;
    end if;
    raise notice 'query/11: PATH answers two names as routes and three as a connecting subgraph';
end $$;

-- The budget describes the CALL. Before this, it started after the snapshot
-- was fetched, so a cold first call reported 96 ms of a 2,689 ms wait -- true
-- of the walk, and the number an SLO would have been written against.
do $$
declare v jsonb; m jsonb;
begin
    perform p8_graph_snapshot_drop();
    v := p8_graph_ppr(array[(select node_id from aiq.lookup('acme', false, 1))]);
    m := v->'meta';
    if jsonb_typeof(m->'build_ms') <> 'number'
       or jsonb_typeof(m->'walk_ms') <> 'number'
       or jsonb_typeof(m->'over_budget') <> 'boolean' then
        raise exception 'the budget does not separate the call from the walk: %', m;
    end if;
    if not (m->>'snapshot_built')::boolean then
        raise exception 'a call that had to build reported that it did not';
    end if;
    if (m->>'elapsed_ms')::numeric < (m->>'walk_ms')::numeric then
        raise exception 'elapsed_ms is smaller than walk_ms, so it is not the call';
    end if;
    -- And the second call on the same snapshot pays nothing for it.
    m := p8_graph_ppr(array[(select node_id from aiq.lookup('acme', false, 1))])->'meta';
    if (m->>'snapshot_built')::boolean or (m->>'build_ms')::numeric <> 0 then
        raise exception 'a call that reused a snapshot claimed it built one: %', m;
    end if;
    raise notice 'query/11: the budget reports the call, and says which part was the build';
end $$;

-- ---------------------------------------------------------------------
-- 11. EVERY CROSSING OF THE EXTENSION BOUNDARY IS SATISFIED.
--
-- The two halves ship on different rails -- one in an image, one in a script --
-- so they diverge, and a SQL reload does not carry a .so. This asserts the
-- state is legible rather than that it is good: `ok` false is a real answer,
-- and what must never happen is a crossing nobody knew about.
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
    v := aiq.extension_boundary();
    if jsonb_array_length(v->'crossings') < 10 then
        raise exception
            'the boundary report found only % crossings, which means the '
            'derivation stopped seeing them rather than that they stopped '
            'existing', jsonb_array_length(v->'crossings');
    end if;
    if not (v->>'ok')::boolean then
        raise exception
            'the SQL half calls compiled functions this build does not provide: % '
            '-- rebuild the image (dev/build-image.sh)', v->>'missing';
    end if;
    -- The false positive that the first version of the report had: several
    -- functions raise an error whose text names aiq_parse, and a match on the
    -- mention rather than the call put four apologies in this list.
    if exists (select 1 from jsonb_array_elements(v->'crossings') c
                where c->>'caller' = 'aiq.graph_dense' and c->>'callee' = 'aiq_parse') then
        raise exception 'the boundary report is counting a mention as a call again';
    end if;
    raise notice 'query/11: all % boundary crossings are provided by this build',
        jsonb_array_length(v->'crossings');
end $$;

-- ---------------------------------------------------------------------
-- 11b. AND THE REPORT ANSWERS "CALLABLE BY ME", NOT ONLY "PRESENT".
--
-- The gap this closes: the graph algorithms ship granted to nobody, which is
-- deliberate -- so on a stock install every crossing is present, the boundary
-- said ok, `surface.sql` said SURFACE COMPLETE, and the first call as
-- `authenticated` was `permission denied for function graph_components`. A
-- consumer writing a preflight does the obvious thing, looks the function up in
-- pg_proc, and gets nine false OKs on a stack where nothing will run.
--
-- `present` and `callable by me` are different facts and the second is the one
-- a consumer needs, so `ok` now folds it in. Asserted from BOTH sides, because
-- a report that says false for everyone is as useless as one that says true.
-- ---------------------------------------------------------------------
do $$
declare v jsonb; v_c jsonb;
begin
    v := aiq.extension_boundary();
    for v_c in select jsonb_array_elements(v->'crossings') loop
        if not (v_c ? 'callable') then
            raise exception
                'a crossing reports presence and not reachability: %', v_c;
        end if;
    end loop;
    if (v->>'role') is null then
        raise exception 'the report does not say whose reachability it measured';
    end if;

    -- As the owner, who can call everything: ok is true and nothing is listed
    -- unreachable.
    if not (v->>'ok')::boolean or jsonb_array_length(v->'unreachable') <> 0 then
        raise exception
            'the owner cannot reach its own crossings, which means the privilege '
            'lookup is wrong rather than that the stack is: %', v->'unreachable';
    end if;
end $$;

do $$
declare v jsonb; v_c jsonb;
begin
    -- ...and as a role the gate is shut against. `authenticated` holds the
    -- grants integration-rbac.sql gives it, which do not include the graph
    -- algorithms until somebody asks for them.
    -- Establish the precondition AS THE OWNER: a gate an end-user role can
    -- open is not a gate, so `authenticated` cannot call this either way. On a
    -- stock install this is a no-op, and it is here so the assertion below does
    -- not depend on which order the blocks in this file have run in.
    perform aiq.enable_graph_algorithms('authenticated', false);
    set local role authenticated;
    v := aiq.extension_boundary();
    if (v->>'ok')::boolean then
        raise exception
            'the boundary reports ok to a role that cannot execute a single graph '
            'entry point -- which is the false OK this instrument exists to end';
    end if;
    select c into v_c from jsonb_array_elements(v->'crossings') c
     where not (c->>'callable')::boolean limit 1;
    if v_c->>'remedy' is null then
        raise exception 'an unreachable crossing does not carry its own remedy: %', v_c;
    end if;
    reset role;
    raise notice 'query/11: the boundary answers callable-by-me, and names the fix';
end $$;

-- ---------------------------------------------------------------------
-- 12. THE TWO MEMORY LIMITS ARE SETTINGS, AND NOT THE CALLER'S TO RAISE.
--
-- Both stand between a busy pool and a cluster restart, and the right value
-- for each depends on the machine -- so compiled-in constants were the wrong
-- shape. What must hold is that they exist, that the ceiling refuses with a
-- message naming itself, and that the roles which CALL these functions cannot
-- raise them: a limit its subject can lift is not a limit.
-- ---------------------------------------------------------------------
do $$
declare v_slots int; v_mb int; v_msg text;
begin
    -- Loading the library is what defines them, and the library loads on first
    -- use rather than at startup -- so this touches a graph function first.
    perform p8_graph_snapshot(false);
    v_slots := current_setting('percolate.graph_snapshot_slots')::int;
    v_mb    := current_setting('percolate.graph_snapshot_max_mb')::int;
    if v_slots < 1 or v_mb < 16 then
        raise exception 'the snapshot limits are not registered as settings (% slots, % MB)',
            v_slots, v_mb;
    end if;

    -- The ceiling refuses, and the refusal names the setting that lifts it.
    begin
        set local percolate.graph_snapshot_max_mb = 16;
        perform p8_graph_snapshot(true);
        -- The fixture is small enough to fit 16 MB, so reaching here is fine;
        -- what must not happen is the ceiling being unreachable in principle.
    exception when others then
        get stacked diagnostics v_msg = message_text;
        if v_msg not like '%graph_snapshot_max_mb%' then
            raise exception 'the ceiling refused without naming the setting: %', v_msg;
        end if;
    end;
    reset percolate.graph_snapshot_max_mb;
    raise notice 'query/11: the snapshot limits are settings (% slots, % MB)', v_slots, v_mb;
end $$;

do $$
declare v_msg text;
begin
    set local role authenticated;
    begin
        set percolate.graph_snapshot_slots = 4096;
        raise exception 'an end-user role raised its own snapshot slot limit';
    exception when insufficient_privilege then
        null;  -- the expected outcome
    end;
    reset role;
    raise notice 'query/11: an end-user role cannot raise the limits that bound it';
end $$;

-- ---------------------------------------------------------------------
-- 13. SHIPPED EXPERIMENTAL MEANS PRESENT AND UNREACHABLE.
--
-- graph-algorithms.md ships these off by default: installed, inert, callable
-- by nobody but the owner until a deliberate grant. That is what makes an
-- experimental surface safe to put in a release, and it is worth an assertion
-- because the failure is silent in the wrong direction -- a function created
-- after integration-rbac.sql's blanket revoke keeps PUBLIC EXECUTE, and
-- nothing complains.
-- ---------------------------------------------------------------------
do $$
declare v_open text;
begin
    select string_agg(p.proname, ', ') into v_open
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where ((n.nspname = 'aiq' and p.proname in
             ('related','graph_paths','graph_connect','graph_dense','graph_trust',
              'graph_frontier','graph_snapshot','graph_reach_build',
              'graph_components','graph_induced',
              'graph_algorithms_available','enable_graph_algorithms'))
         or p.proname like 'p8\_graph\_%')
       and (has_function_privilege('authenticated', p.oid, 'execute')
         or has_function_privilege('web_anon', p.oid, 'execute'));
    if v_open is not null then
        raise exception
            'the experimental graph algorithms are reachable by an end-user role '
            'on a fresh install: %. They ship off by default; enabling them is '
            'aiq.enable_graph_algorithms(role).', v_open;
    end if;
    raise notice 'query/11: shipped off by default -- no end-user role can call them';
end $$;

-- And the gate opens, which is the other half: a posture nobody can leave is
-- not a default, it is a wall. Inside this transaction, so it rolls back.
select aiq.enable_graph_algorithms('authenticated') is not null as enabled \gset

do $$
begin
    if not has_function_privilege('authenticated', 'aiq.related(text[],int,text,int,timestamptz,boolean)', 'execute') then
        raise exception 'enable_graph_algorithms did not grant aiq.related';
    end if;
    if not has_function_privilege('authenticated', 'p8_graph_ppr(uuid[],float8,float8,int,int,bool,text,bigint)', 'execute') then
        raise exception
            'enable_graph_algorithms granted the wrapper but not the compiled '
            'function under it -- the wrapper is SECURITY INVOKER, so that grant '
            'is half a grant and fails at the first call';
    end if;
    raise notice 'query/11: one call opens the gate, wrapper and compiled function together';
end $$;

-- ---------------------------------------------------------------------
-- 14. THE CACHE CANNOT CROSS A TENANT. The assertion this file exists for.
--
-- One backend, two identities, in that order. If the fingerprint check were
-- removed, the second snapshot would be the first one -- same node count, same
-- built_at -- and org B would be walking org A's graph through an array that
-- no policy is anywhere near.
-- ---------------------------------------------------------------------
-- The two answers are parked in a table rather than in psql variables: psql
-- does not substitute a variable inside a dollar-quoted body, so the obvious
-- \gset form compiles to a literal colon and fails at the DO block.
create temp table t_snap (tag text primary key, v jsonb);
grant insert, select on t_snap to authenticated;

set local role authenticated;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","orgs":["a0000000-0000-0000-0000-00000000000a"]}';
insert into t_snap select 'a', aiq.graph_snapshot(true);

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","orgs":["a0000000-0000-0000-0000-00000000000b"]}';
insert into t_snap select 'b', aiq.graph_snapshot(false);

do $$
declare a jsonb; b jsonb; v_visible bigint;
begin
    select v into a from t_snap where tag = 'a';
    select v into b from t_snap where tag = 'b';
    -- Two independent tells, because either one alone is weak: two builds can
    -- legitimately hold the same node count (if the tenants are the same size)
    -- and built_at alone was, until this test found it, a transaction
    -- timestamp that could not move inside one transaction.
    if a->'snapshot'->>'built_at' = b->'snapshot'->>'built_at' then
        raise exception
            'the snapshot built for org A was reused for org B -- a cached '
            'cross-tenant read. built_at was % for both', a->'snapshot'->>'built_at';
    end if;
    if (a->'snapshot'->>'nodes')::bigint = (b->'snapshot'->>'nodes')::bigint then
        raise exception
            'both tenants got a snapshot of % nodes; on this fixture they see '
            'different graphs, so one of them is holding the other''s',
            a->'snapshot'->>'nodes';
    end if;
    select count(*) into v_visible from aiq.nodes;
    if (b->'snapshot'->>'nodes')::bigint <> v_visible then
        raise exception 'org B holds % nodes but can see %',
            b->'snapshot'->>'nodes', v_visible;
    end if;
    raise notice 'query/11: switching tenant in one backend rebuilds the snapshot (% -> % nodes)',
        a->'snapshot'->>'nodes', b->'snapshot'->>'nodes';
end $$;

reset role;

-- ---------------------------------------------------------------------
-- 15. AND THE FILTER DOES NOT CROSS ONE EITHER.
--
-- §14 asserts the snapshot is rebuilt for a new identity. It was, and the
-- rebuild used the PREVIOUS identity's build filter -- so one caller's
-- `graph_snapshot(true, relations => ...)` narrowed every algorithm the next
-- caller ran on that backend, and nothing in any answer said so.
-- `aiq.related('acme')` returned ten rows on a fresh connection and one row on
-- that one. Through PostgREST's pool "the previous identity on this backend" is
-- the ordinary case, not a contrived one.
--
-- Both directions are asserted, because the fix is a distinction and not a
-- removal: a filter is a caller's choice about their own graph, so it must
-- survive their own writes (the case the inheritance exists for -- an operator
-- who built over a subset because the whole graph does not fit §2.3's ceiling)
-- and must not outlive their identity.
-- ---------------------------------------------------------------------
create temp table t_filt (tag text primary key, v jsonb);
grant insert, select on t_filt to authenticated;

set local role authenticated;

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","orgs":["a0000000-0000-0000-0000-00000000000a"]}';
insert into t_filt select 'subset', aiq.graph_snapshot(true, array['knows']);

-- The graph moves under that caller. Written as the owner because
-- `authenticated` has no UPDATE on aiq.edges -- what has to change is the
-- COUNTERS the staleness check reads, not who changed them, and the identity
-- is set back before the next snapshot call. They come from the stats
-- collector, so they are forced and given a moment to land; without that this
-- section asserts nothing, because no rebuild happens at all.
reset role;
do $$
begin
    update aiq.edges set weight = weight where true;
    perform pg_stat_force_next_flush();
    perform pg_sleep(0.5);
end $$;

set local role authenticated;
insert into t_filt select 'after_own_write', aiq.graph_snapshot(false);

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","orgs":["a0000000-0000-0000-0000-00000000000b"]}';
insert into t_filt select 'other_identity', aiq.graph_snapshot(false);

do $$
declare a jsonb; b jsonb; c jsonb;
begin
    select v->'snapshot' into a from t_filt where tag = 'subset';
    select v->'snapshot' into b from t_filt where tag = 'after_own_write';
    select v->'snapshot' into c from t_filt where tag = 'other_identity';

    if a->'filter'->'relations' is null then
        raise exception 'the subset build did not record its filter: %', a;
    end if;
    if b->'filter'->'relations' is distinct from a->'filter'->'relations' then
        raise exception
            'a caller lost their own build filter across their own write '
            '(% -> %) -- an operator who built over a subset because the graph '
            'does not fit the ceiling has that undone by anyone inserting an edge',
            a->'filter'->'relations', b->'filter'->'relations';
    end if;
    if jsonb_typeof(c->'filter') <> 'null' then
        raise exception
            'a new identity inherited the previous one''s build filter (%) -- '
            'every algorithm it runs is silently answering over a subset it did '
            'not ask for and cannot see', c->'filter';
    end if;
    if (c->>'edges')::bigint <= (a->>'edges')::bigint then
        raise exception
            'the new identity holds % edges and the subset held % -- it is on '
            'the narrowed graph, whatever the filter field says',
            c->>'edges', a->>'edges';
    end if;
    raise notice
        'query/11: a build filter survives its own caller''s writes (% edges) '
        'and does not cross to the next identity (% edges)',
        b->>'edges', c->>'edges';
end $$;

reset role;

set local role app_owner;

-- ---------------------------------------------------------------------
-- AN ANSWER MARKED `exact` MUST NOT BE WRONG.
--
-- The label index stores distances as a BYTE, so a root's BFS stops at 254
-- hops. Both of the other ceilings on that build -- the time budget and the
-- entry count -- say so by clearing `complete`, which is what
-- p8_graph_distance reports as `exact`. The depth cap said nothing, so a pair
-- further apart than the cap answered "no distance, and that is proven":
--
--     a 300-node path, n1 -> n300 (299 hops)
--       -> {"distance": null, "exact": true}
--
-- The two nodes are plainly joined, along the only path there is. `exact` is
-- the field that separates a proof from an upper bound, so the one thing it
-- must never describe is a wrong answer -- and a caller who trusts it has no
-- other way to find out.
--
-- Asserted as the invariant rather than as the number: EITHER the distance is
-- right, OR the index says it is not exact. That holds for a complete index, a
-- budget-truncated one and an over-deep one alike, so it does not have to be
-- rewritten the next time a ceiling is added.
-- ---------------------------------------------------------------------
do $$
declare v_ids uuid[]; v jsonb; n int := 300;
begin
    insert into aiq.relation_types (relation, src_type, dst_type)
      values ('chain_rel','chain','chain') on conflict do nothing;
    insert into aiq.nodes (entity_type, entity_id, summary)
    select 'chain', gen_random_uuid(), 'n'||lpad(i::text,4,'0') from generate_series(1,n) i;
    select array_agg(id order by summary) into v_ids
      from aiq.nodes where entity_type='chain';
    insert into aiq.edges (src_id, dst_id, relation, weight)
    select v_ids[i], v_ids[i+1], 'chain_rel', 1.0 from generate_series(1, n-1) i;

    perform p8_graph_snapshot(true);
    perform p8_graph_labels_build(60000, 20000000);

    -- Inside the cap the index knows the answer, and it is 199 hops.
    v := p8_graph_distance(v_ids[1], v_ids[200]);
    if (v->>'exact')::boolean and (v->>'distance')::int is distinct from 199 then
        raise exception 'distance n1->n200 is %, marked exact, and the path is 199 hops',
            coalesce(v->>'distance','null');
    end if;

    -- Past it the index cannot answer, and must not pretend it did.
    v := p8_graph_distance(v_ids[1], v_ids[300]);
    if (v->>'exact')::boolean and v->>'distance' is null then
        raise exception
            'p8_graph_distance reported no distance between two nodes joined by a '
            '299-hop path AND marked the answer exact. The label index stops at 254 '
            'hops; stopping at a ceiling has to clear `complete`, the way the budget '
            'and entry ceilings already do.';
    end if;
    if (v->>'exact')::boolean and (v->>'distance')::int is distinct from 299 then
        raise exception 'distance n1->n300 is %, marked exact, and the path is 299 hops',
            coalesce(v->>'distance','null');
    end if;

    raise notice 'query/11: a distance marked exact is never wrong -- the depth ceiling '
                 'clears `complete` like the other two';
end $$;


rollback;
