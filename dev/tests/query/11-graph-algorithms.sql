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
            'the graph algorithms are not in the installed percolate_parser. '
            'They are compiled, so a SQL reload does not carry them: rebuild the '
            'image (dev/build-image.sh) or copy the .so into the container.';
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
-- 6. THE TEMPORAL FILTER IS APPLIED, WHICH NO OTHER READ PATH DOES.
--
-- graph-identity.md records valid_from/valid_to as stored-and-never-read, and
-- pins that behaviour for `graph_neighbors`, `graph_walk` and `GRAPH_TABLE` in
-- `05` §14. This surface is the exception, so the exception is asserted here:
-- an edge whose validity has expired must disappear from an as_of walk and
-- must still be there without one.
-- ---------------------------------------------------------------------
do $$
declare v_before jsonb; v_after jsonb; v_edge uuid;
begin
    select e.id into v_edge
      from aiq.edges e
      join aiq.node_keys ks on ks.node_id = e.src_id and ks.key = 'acme' and ks.kind = 'canonical'
      join aiq.node_keys kd on kd.node_id = e.dst_id and kd.key = 'ndlr' and kd.kind = 'canonical'
     limit 1;
    if v_edge is null then
        raise exception 'the fixture no longer has the acme->ndlr edge this assertion is about';
    end if;

    update aiq.edges set valid_to = now() - interval '1 day' where id = v_edge;
    perform aiq.graph_snapshot(true);

    v_before := aiq.graph_paths('acme', 'ndlr', 1);
    v_after  := aiq.graph_paths('acme', 'ndlr', 1, p_as_of => now());

    if jsonb_array_length(v_before->'paths') = 0 then
        raise exception 'without as_of the expired edge vanished -- the default must still traverse it';
    end if;
    if (v_before->'paths'->0->>'hops')::int <> 1 then
        raise exception 'without as_of the direct edge was not used';
    end if;
    if jsonb_array_length(v_after->'paths') > 0
       and (v_after->'paths'->0->>'hops')::int = 1 then
        raise exception 'with as_of the expired edge was still traversed';
    end if;
    raise notice 'query/11: as_of excludes an expired edge that the default walk still uses';
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
-- 10. SHIPPED EXPERIMENTAL MEANS PRESENT AND UNREACHABLE.
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
-- 11. THE CACHE CANNOT CROSS A TENANT. The assertion this file exists for.
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

set local request.jwt.claims = '{"orgs":["a0000000-0000-0000-0000-00000000000a"]}';
insert into t_snap select 'a', aiq.graph_snapshot(true);

set local request.jwt.claims = '{"orgs":["a0000000-0000-0000-0000-00000000000b"]}';
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

rollback;
