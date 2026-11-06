-- A symmetric edge merges whichever way it is stored (REM-1318).
--
-- The catalogue trigger stores a symmetric edge in uuid order. Promoting a
-- soft node moves its edges onto the target, and the target may already hold
-- the same fact. promote_soft_node asked whether it did in one orientation
-- only, so when the moved edge was re-ordered onto the target's own row the
-- unique index refused it and the whole promotion failed. Found binding twin
-- aliases in query/69 (REM-1313).
--
-- The shape: Ana (T) is affiliated_with Tagus (X), then A. Costa (C) is too,
-- created in the order T < X < C. A. Costa's edge is stored (X, C) and Ana's
-- (T, X). Moving C's edge onto T writes (X, T), which the trigger re-orders to
-- (T, X): Ana's row. The checks, as the engine:
--   1. affiliated_with is symmetric and both edges are stored as described, so
--      the test is still about the re-ordered case;
--   2. promoting A. Costa onto Ana succeeds;
--   3. one affiliated_with edge joins Ana and Tagus, carrying both landings'
--      sources, and none touches A. Costa's node.
--
-- WHAT WOULD MAKE IT FAIL. Ask the move's not-exists in one orientation only,
-- as 0.2.38 does, and 2 raises a unique violation on aiq.edges.
-- One transaction, rolled back.

\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
    if p_ok is not true then
        raise exception 'symmetric merge: %', p_what;
    end if;
end $$;

set local request.jwt.claims = '';
select aiq.upsert_graph('{"nodes":[{"k":"person","n":"Ana Costa Q71"},{"k":"company","n":"Tagus Q71"}],
  "edges":[{"s":0,"t":1,"r":"affiliated_with"}]}', '{"agent":"knit","run_id":"q71-1"}') is not null as l1 \gset
select aiq.upsert_graph('{"nodes":[{"k":"person","n":"A. Costa Q71"},{"k":"company","n":"Tagus Q71"}],
  "edges":[{"s":0,"t":1,"r":"affiliated_with"}]}', '{"agent":"knit","run_id":"q71-2"}') is not null as l2 \gset

select (select node_id from aiq.node_keys where key = 'person/ana costa q71' and kind = 'canonical') as t,
       (select node_id from aiq.node_keys where key = 'company/tagus q71' and kind = 'canonical') as x,
       (select node_id from aiq.node_keys where key = 'person/a. costa q71' and kind = 'canonical') as c,
       (select id from aiq.soft_nodes where key = 'a. costa q71') as c_soft \gset

-- 1. The case under test.
select pg_temp.check((select bool_or(coalesce(is_symmetric, false)) from aiq.relation_types
                       where relation = 'affiliated_with'),
    '1. affiliated_with is no longer symmetric, so this test no longer exercises the re-ordered edge');
select pg_temp.check(:'t'::uuid < :'x'::uuid and :'x'::uuid < :'c'::uuid,
    '1. the nodes were not created in the order Ana < Tagus < A. Costa');
select pg_temp.check(exists (select 1 from aiq.edges where src_id = :'x' and dst_id = :'c' and relation = 'affiliated_with')
                     and exists (select 1 from aiq.edges where src_id = :'t' and dst_id = :'x' and relation = 'affiliated_with'),
    '1. the two edges are not stored as (Tagus, A. Costa) and (Ana, Tagus)');

-- 2. The promotion.
select aiq.promote_soft_node(:'c_soft', :'t', 'q71', 'agent') as promoted \gset
select pg_temp.check((:'promoted'::jsonb ->> 'merged')::int = 1,
    '2. the edge onto Ana was not merged: ' || :'promoted');

-- 3. One fact, both sources, nothing left on A. Costa.
select pg_temp.check((select count(*) from aiq.edges
                       where relation = 'affiliated_with'
                         and ((src_id = :'t' and dst_id = :'x') or (src_id = :'x' and dst_id = :'t'))) = 1,
    '3. Ana and Tagus are not joined by exactly one affiliated_with edge');
select pg_temp.check((select provenance -> 'sources' @> '[{"run_id": "q71-1"}]' and provenance -> 'sources' @> '[{"run_id": "q71-2"}]'
                        from aiq.edges where src_id = :'t' and dst_id = :'x' and relation = 'affiliated_with'),
    '3. the merged edge does not carry both landings'' sources: '
    || (select provenance::text from aiq.edges where src_id = :'t' and dst_id = :'x' and relation = 'affiliated_with'));
select pg_temp.check(not exists (select 1 from aiq.edges where :'c'::uuid in (src_id, dst_id)),
    '3. an edge still touches A. Costa''s evicted node');

\echo 'query/71: a symmetric edge merges onto its target whichever way it is stored'
rollback;
