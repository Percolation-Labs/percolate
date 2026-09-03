-- 11. Five questions a walk cannot answer, and the tenancy that survives them.
--
-- GRAPH walks. These rank, bound and search -- which is the line
-- specs/ai-query-layer/graph-algorithms.md draws for compiling something into
-- the extension rather than writing it as a query. They ship OFF, so the first
-- statement here is the grant, and it rolls back with everything else.
--
-- The fixture is nine edges on purpose: every answer below is small enough to
-- check by eye against 00-harbour.sql. What the same calls cost on a graph of
-- four million edges is measured in dev/scale/graph/, not guessed at here.
select aiq.enable_graph_algorithms('authenticated') -> 'functions' as granted;

set local role authenticated;
set local request.jwt.claims = '{"orgs":["d0000000-0000-0000-0000-00000000000a"]}';

\echo '-- what is related to this ship, ranked -- not everything within n hops:'
select key, entity_type, round(score::numeric, 4) as score, budget_exhausted
from aiq.related(array['bulk harmony'], 6);

\echo '-- how is the ship connected to its ultimate parent? the two best routes:'
select p.n as route, (p.v->>'hops')::int as hops,
       round((p.v->>'cost')::numeric, 2) as cost,
       (select string_agg(k.key, ' -> ' order by j.i)
          from jsonb_array_elements_text(p.v->'nodes') with ordinality j(id, i)
          join aiq.node_keys k on k.node_id = j.id::uuid and k.kind = 'canonical') as route_taken,
       (select string_agg(h->>'relation', ', ' order by i)
          from jsonb_array_elements(p.v->'path') with ordinality x(h, i)) as relations
from (select ordinality as n, value as v
        from jsonb_array_elements(aiq.graph_paths('bulk harmony', 'meri', 2)->'paths')
             with ordinality) p;

\echo '-- the same call for a node this tenant cannot see: unresolved, not empty:'
select aiq.graph_paths('bulk harmony', 'kest', 2) - 'meta' as answer;

\echo '-- confidence over the edge weights: the registry claim, on its own edge...'
select key, confidence, support from aiq.graph_trust(array['merb'], 0.01, 4, 250, 'subsidiary_of');

\echo '-- ...and with the whole graph available, because a longer certain route wins:'
select key, confidence, support from aiq.graph_trust(array['merb'], 0.01, 4);

\echo '-- the smallest subgraph joining three things a retrieval returned:'
select jsonb_array_length(v->'nodes') as nodes,
       (v->>'connected')::int as terminals_joined,
       (select string_agg(ks.key || ' -[' || (e->>'relation') || ']- ' || kd.key, ' | ')
          from jsonb_array_elements(v->'edges') e
          join aiq.node_keys ks on ks.node_id = (e->>'src')::uuid and ks.kind = 'canonical'
          join aiq.node_keys kd on kd.node_id = (e->>'dst')::uuid and kd.kind = 'canonical') as edges
from (select aiq.graph_connect(array['bulk harmony','rotterdam','meri']) v) q;

\echo '-- what is transitively linked to what at all, before anything decides why:'
select c.size, string_agg(k.key, ', ' order by k.key) as members
from aiq.graph_components(2) c
join aiq.node_keys k on k.node_id = c.node_id and k.kind = 'canonical'
group by c.component, c.size order by c.size;

\echo '-- and the edges inside one of them, in one call rather than one per cluster:'
select ks.key as src, i.relation, kd.key as dst, round(i.weight::numeric, 2) as weight
from aiq.graph_induced(array(
        select node_id from aiq.graph_components(2) where size = 6)) i
join aiq.node_keys ks on ks.node_id = i.src_id and ks.kind = 'canonical'
join aiq.node_keys kd on kd.node_id = i.dst_id and kd.kind = 'canonical'
order by 1, 3;

\echo '-- how big is the neighbourhood, BEFORE walking it:'
--
-- The sketch is built by the caller, over the graph the caller can see. Built
-- by somebody else it would be somebody else's graph, and this tenant would get
-- `estimate: null` -- which is how the grant list came to include the build.
select aiq.graph_reach_build(3) -> 'depth' as sketch_depth;
select aiq.graph_frontier('meri', 2, true) as frontier;
