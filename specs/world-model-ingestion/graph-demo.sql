-- ============================================================
-- graph-demo.sql -- the worked example graph-index.md is for.
--
-- Two contracts are uploaded. A structure extractor maps each one's clauses
-- and actors as a graph. The documents are chunked and embedded for SEARCH the
-- way any upload is; the graph is what makes them CONNECTED -- and the point of
-- the last section is that a question asked of one company reaches both
-- contracts, because the two documents were never linked to each other, only
-- to the same entity.
--
-- The graphs below are LITERALS: exactly the JSON graph-index.md §2 specifies,
-- as a cheap model would return it. Using a literal is the point of this file
-- -- the model half costs money and is not what has bugs, and the database
-- half ("given this JSON, does the right graph appear") is completely testable
-- without one.
--
-- Requires: graph.sql applied, aiq.register_graph_vocabulary() run.
--
-- RUNS IN A TRANSACTION THAT ROLLS BACK, and that is not tidiness. The first
-- version committed, and it broke `dev/tests/query/06-graph-tenancy.sql` --
-- which asserts that a walk from NWND returns NOTHING, true only of the
-- committed fixture. Two shared-tier edges from this demo made it false. A
-- demonstration that mutates the fixture other tests assert against is a
-- demonstration that breaks the build, so this one shows its output and
-- leaves nothing behind.
-- ============================================================
begin;

-- ------------------------------------------------------------
-- 1. Two uploads.
--
-- status='ready' is what the `document` entity type's inclusion predicate
-- selects on, so committing these rows projects two document NODES in the same
-- transaction. Nothing else has to be called.
-- ------------------------------------------------------------
-- This demo resolves against the dev sample fixtures (dev/init/04-graph-sample
-- and 05-corpus-sample): the companies and people the contracts name have to
-- already exist as registered entities, because "an extracted name binds to a
-- row that was there first" is the whole thing being shown. Say so plainly --
-- on a stock install the first version failed with a foreign-key error on a
-- channel, which tells the reader nothing about what is actually missing.
do $$
begin
    if not exists (select 1 from aiq.node_keys where key = 'acme' and kind = 'canonical') then
        raise exception
            'this demo needs the dev sample fixtures (dev/init/04-graph-sample.sql, '
            '05-corpus-sample.sql): it shows extracted names binding to entities that '
            'already exist, and on an empty database every one of them would land as a '
            'candidate and there would be nothing to demonstrate.';
    end if;
end $$;

-- Its own channel, so the only thing it depends on is the fixture DATA.
insert into content.channels (id, name, kind)
values ('11110000-0000-0000-0000-0000000000de', 'graph-demo', 'manual')
on conflict (id) do nothing;

insert into content.resources (id, channel_id, title, status, metadata)
values
 ('33330000-0000-0000-0000-000000000001',
  '11110000-0000-0000-0000-0000000000de',
  'MSA - Northwind Capital and Acme Robotics', 'ready',
  '{"doctype":"contract"}'::jsonb),
 ('33330000-0000-0000-0000-000000000002',
  '11110000-0000-0000-0000-0000000000de',
  'Supply Agreement - Acme Robotics and Helios Freight', 'ready',
  '{"doctype":"contract"}'::jsonb)
on conflict (id) do update set title = excluded.title, status = excluded.status;

-- ------------------------------------------------------------
-- 2. Teach the graph the names people actually write.
--
-- THE CASCADE ONLY WORKS IF SOMEONE POPULATES IT, and this fixture shows why
-- that is a real step rather than a formality. demo.companies registers its
-- canonical key as `coalesce(ticker, name)`, so Acme Robotics' canonical key is
-- `acme` -- the ticker. A contract says "Acme Robotics". Nothing resolves that
-- to `acme` by exact match, so without these three rows every company in the
-- extracted graph would land as a CANDIDATE, and the demo's whole point --
-- two documents meeting at one company node -- would silently not happen.
--
-- aiq.add_node_key is the sanctioned write path (graph-identity.md): it
-- resolves the target through the ordinary cascade, refuses an ambiguous one,
-- and refuses kind='canonical' outright, because a second canonical key is not
-- a synonym, it is two names each claiming to be the derived one.
-- ------------------------------------------------------------
select aiq.add_node_key('acme', 'acme robotics',    'alias');
select aiq.add_node_key('nwnd', 'northwind capital','alias');
select aiq.add_node_key('hlfr', 'helios freight',   'alias');

-- ------------------------------------------------------------
-- 3. Contract 1, as the null extractor returns it.
--
-- Note the residences this one graph spans, all resolved by aiq.upsert_graph
-- with no help from the model:
--   * `document` and `company` and `person` are REGISTERED entity types whose
--     names resolve -> the edge lands on the real typed vertex.
--   * `clause` is a kind nothing knows -> candidates in aiq.soft_nodes.
-- The model did not have to know any of that. It named things and connected
-- them; the resolver decided what they were.
-- ------------------------------------------------------------
select 'contract 1 ->' as step, aiq.land_graph($g${
  "nodes": [
    {"k":"document","n":"MSA - Northwind Capital and Acme Robotics"},
    {"k":"company", "n":"Northwind Capital", "a":{"role":"customer"}},
    {"k":"company", "n":"Acme Robotics",     "a":{"role":"supplier"}},
    {"k":"clause",  "n":"Limitation of Liability", "a":{"cap":"12 months fees"}},
    {"k":"clause",  "n":"Indemnity",               "a":{"scope":"IP infringement"}},
    {"k":"person",  "n":"Dana Whitfield",          "a":{"title":"signatory"}}
  ],
  "edges": [
    {"s":0,"t":3,"r":"contains"},
    {"s":0,"t":4,"r":"contains"},
    {"s":0,"t":1,"r":"party_to"},
    {"s":0,"t":2,"r":"party_to"},
    {"s":3,"t":2,"r":"binds","a":{"since":"2024-01-01"}},
    {"s":4,"t":1,"r":"binds"},
    {"s":5,"t":1,"r":"affiliated_with"}
  ]}$g$::jsonb, '33330000-0000-0000-0000-000000000001'::uuid) as receipt;

-- ------------------------------------------------------------
-- 4. Contract 2 -- a different document, overlapping entities.
--
-- Two overlaps to watch, and they are the two ways a graph accumulates:
--   * "Acme Robotics" resolves to the SAME company node contract 1 used, so
--     the two documents now share a vertex -- which is the entire mechanism
--     behind §7's traversal.
--   * "Limitation of Liability" is the same (kind, key) as contract 1's
--     clause, so it is the SAME candidate row, its observation updated rather
--     than a second near-identical node created.
-- ------------------------------------------------------------
select 'contract 2 ->' as step, aiq.land_graph($g${
  "nodes": [
    {"k":"document","n":"Supply Agreement - Acme Robotics and Helios Freight"},
    {"k":"company", "n":"Acme Robotics",  "a":{"role":"customer"}},
    {"k":"company", "n":"Helios Freight", "a":{"role":"carrier"}},
    {"k":"clause",  "n":"Limitation of Liability", "a":{"cap":"EUR 2m"}},
    {"k":"clause",  "n":"Force Majeure"},
    {"k":"facility","n":"Tilbury depot", "a":{"country":"GB"}}
  ],
  "edges": [
    {"s":0,"t":3,"r":"contains"},
    {"s":0,"t":4,"r":"contains"},
    {"s":0,"t":1,"r":"party_to"},
    {"s":0,"t":2,"r":"party_to"},
    {"s":2,"t":1,"r":"supplies","a":{"since":"2023-06-01"}},
    {"s":3,"t":1,"r":"binds"},
    {"s":2,"t":5,"r":"owns"}
  ]}$g$::jsonb, '33330000-0000-0000-0000-000000000002'::uuid) as receipt;

-- ------------------------------------------------------------
-- 5. What landed, by residence.
-- ------------------------------------------------------------
\echo ''
\echo '--- 5. Nodes by residence (pg = a real typed row; soft = a candidate) ---'
select n.entity_type as residence, k.key, n.summary
from aiq.nodes n join aiq.node_keys k on k.node_id = n.id and k.kind = 'canonical'
where n.id in (select src_id from aiq.edges where provenance->>'tier' = 'machine'
               union select dst_id from aiq.edges where provenance->>'tier' = 'machine')
order by 1, 2;

\echo ''
\echo '--- 5b. The same clause named by both contracts is ONE candidate ---'
select s.kind, s.key, s.label, s.attrs
from aiq.soft_nodes s order by s.kind, s.key;

-- ------------------------------------------------------------
-- 6. Corroboration -- the same edge from two documents is one row.
-- ------------------------------------------------------------
\echo ''
\echo '--- 6. Edges, with how many DISTINCT documents asserted each ---'
select ks.key as src, e.relation, kd.key as dst, e.weight,
       jsonb_array_length(e.provenance->'sources') as asserted_by
from aiq.edges e
join aiq.node_keys ks on ks.node_id = e.src_id and ks.kind = 'canonical'
join aiq.node_keys kd on kd.node_id = e.dst_id and kd.kind = 'canonical'
where e.provenance->>'tier' = 'machine'
order by asserted_by desc, ks.key, e.relation;

-- ------------------------------------------------------------
-- 7. THE TRAVERSAL -- how multiple documents link through one entity.
--
-- Nothing ever wrote an edge between the two contracts. They meet at Acme
-- Robotics, which is a company row that existed before either was uploaded,
-- and the walk finds the second contract from the first without being told
-- they are related.
-- ------------------------------------------------------------
\echo ''
\echo '--- 7a. Neighbours of Acme Robotics (native SQL/PGQ, depth 1) ---'
select w.key, w.entity_type, w.relation, w.direction, w.weight
from aiq.lookup('acme') l, lateral aiq.graph_neighbors(l.node_id) w
order by w.direction, w.relation, w.key;

\echo ''
\echo '--- 7b. Depth 2 from Acme: BOTH contracts and their clauses ---'
\echo '        path_weight is the product of edge weights -- machine edges'
\echo '        sort below authored ones without anyone filtering by hand.'
select w.depth, w.entity_type, w.key, w.path_relations, round(w.path_weight::numeric,3) as score
from aiq.lookup('acme') l, lateral aiq.graph_walk(l.node_id, 2) w
where w.depth > 0
order by w.depth, score desc, w.key;

\echo ''
\echo '--- 7c. The question the graph exists to answer: ---'
\echo '        "which documents involve this company, and through what?"'
select d.key as document, w.path_relations as via
from aiq.lookup('acme') l,
     lateral aiq.graph_walk(l.node_id, 2) w
join aiq.node_keys d on d.node_id = w.node_id and d.kind = 'canonical'
where w.entity_type = 'document'
order by d.key;

\echo ''
\echo '--- 7d. And the shared clause: one candidate, two contracts ---'
select k.key as clause,
       (select count(*) from aiq.edges e2
         where e2.dst_id = w.node_id and e2.relation = 'contains') as in_n_documents
from aiq.lookup('acme') l,
     lateral aiq.graph_walk(l.node_id, 2) w
join aiq.node_keys k on k.node_id = w.node_id and k.kind = 'canonical'
where w.entity_type = 'soft' and k.key like 'clause/%'
group by k.key, w.node_id
order by 2 desc, 1;

rollback;
\echo ''
\echo 'graph-demo: rolled back -- nothing above was committed'
