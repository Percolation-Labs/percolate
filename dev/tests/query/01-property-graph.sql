-- Test whether PG19 beta3's SQL/PGQ (CREATE PROPERTY GRAPH + GRAPH_TABLE) works
-- the way ai-query-layer/brief.md §3 assumes: a read-only pattern-matching view
-- over ordinary relational vertex/edge tables, per ai-query-layer/ontology.md's
-- ENTITY/EDGE shape.

\set ON_ERROR_STOP on

-- Idempotent teardown: a PROPERTY GRAPH is its own catalog object in PG19 and
-- must be dropped before the tables it is defined over.
drop property graph if exists ontology_graph;
drop table if exists edges;
drop table if exists entities;

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

-- Depth-2 walk (variable-length path) — the harder case TRAVERSE DEPTH 2 needs,
-- and the one PG19 beta3 does NOT support.
--
-- Asserted as an expectation rather than left to fail at the end of the file.
-- A test that ends in a real error cannot be told apart from a broken one by
-- any runner, and "the last line always errors, that's fine" is exactly the
-- habit that hides the first genuine failure.
--
-- This passes while the limitation holds and fails, loudly and usefully, on
-- the day it is lifted -- at which point aiq.graph_walk's WITH RECURSIVE
-- fallback (ai-query-layer/brief.md §3) can be reconsidered.
do $$
begin
    perform * from graph_table (ontology_graph
      match (a is entity where a.entity_key = 'overview') -[e is links_to]->{1,2} (b is entity)
      columns (a.entity_key as from_key, b.entity_key as to_key)
    );
    raise exception 'PG19 now supports quantified path patterns -- the documented '
                    'limitation is gone, and graph_walk''s WITH RECURSIVE fallback '
                    'should be revisited (ai-query-layer/brief.md 3)';
exception
    when feature_not_supported or syntax_error then
        raise notice 'query/01: quantified path patterns still unsupported, as '
                     'documented -- DEPTH n>1 stays on WITH RECURSIVE';
end $$;
