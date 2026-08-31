-- Test whether PG19 beta3's SQL/PGQ (CREATE PROPERTY GRAPH + GRAPH_TABLE) works
-- the way ai-query-layer/brief.md §3 assumes: a read-only pattern-matching view
-- over ordinary relational vertex/edge tables, per ai-query-layer/ontology.md's
-- ENTITY/EDGE shape.

\set ON_ERROR_STOP on

create table entities (
    id uuid primary key default gen_random_uuid(),
    entity_key text unique not null,
    entity_type text not null
);

create table edges (
    id uuid primary key default gen_random_uuid(),
    source_id uuid not null references entities(id),
    target_id uuid not null references entities(id),
    relation text not null,
    weight float not null default 1.0
);

insert into entities (entity_key, entity_type) values
  ('overview', 'ontologies'), ('lookup', 'ontologies'), ('search', 'ontologies'),
  ('traverse', 'ontologies'), ('kv-store', 'ontologies');

insert into edges (source_id, target_id, relation, weight)
select e1.id, e2.id, 'links_to', 1.0
from entities e1, entities e2
where (e1.entity_key, e2.entity_key) in (
  ('overview','lookup'), ('overview','search'), ('overview','traverse'),
  ('lookup','kv-store'), ('search','kv-store'), ('traverse','kv-store')
);

-- The actual SQL/PGQ feature under test:
create property graph ontology_graph
  vertex tables (
    entities key (id) label entity properties (entity_key, entity_type)
  )
  edge tables (
    edges key (id)
          source key (source_id) references entities (id)
          destination key (target_id) references entities (id)
          label links_to properties (relation, weight)
  );

-- Depth-1 GRAPH_TABLE walk from 'overview', the exact shape
-- ai-query-layer/brief.md §3's GRAPH mode needs.
select 'depth-1 walk from overview' as check;
select *
from graph_table (ontology_graph
  match (a is entity where a.entity_key = 'overview') -[e is links_to]-> (b is entity)
  columns (a.entity_key as from_key, b.entity_key as to_key, e.relation)
);

-- Depth-2 walk (variable-length path) — the harder case TRAVERSE DEPTH 2 needs.
select 'depth <=2 walk from overview' as check;
select *
from graph_table (ontology_graph
  match (a is entity where a.entity_key = 'overview') -[e is links_to]->{1,2} (b is entity)
  columns (a.entity_key as from_key, b.entity_key as to_key)
);
