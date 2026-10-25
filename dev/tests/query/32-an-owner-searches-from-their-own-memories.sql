-- AN OWNER'S SEARCH UNDER ROW SECURITY READS FROM THEIR OWN MEMORIES, AND RETURNS WHAT THE SCOPED SEARCH DOES
-- (REM-1186).
--
-- The chunk policy asks whether a chunk's resource is readable, and Postgres plans a policy's subquery as a filter on
-- every row, never as a join. So an owner searching with no scope read every chunk in the installation, twice per
-- semantic search (the count deciding exact ranking, then the ranking) and once more in aiq.search to fetch the
-- fused rows' content: on the BEAM load (REM-1144) a 1M owner's search cost several times the scoped one. The source
-- is now read from the caller's readable memories, and aiq.search fetches content by id.
--
--   1. as owner A, a semantic search returns the same chunks in the same order as the operator's search scoped to
--      A's agent, and so does a hybrid search, every row with its content;
--   2. the count that decides exact ranking reads A's chunks and not B's: summed over the plan, the chunk rows it
--      touches are at most twice A's, where reading every chunk would touch more than a hundred times as many.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000001186a1', 'query32-a@example.test', 'active'),
    ('00000000-0000-4000-8000-0000001186b2', 'query32-b@example.test', 'active');
insert into rbac.user_roles (user_id, role)
select u, 'member' from unnest(array['00000000-0000-4000-8000-0000001186a1',
                                     '00000000-0000-4000-8000-0000001186b2']::uuid[]) u
on conflict do nothing;
insert into content.channels (name, kind, visibility) values ('query32', 'manual', 'public');

-- A holds 30 memories of 4 chunks, B holds 5,000: 120 chunks against 20,000, all private.
insert into content.resources (channel_id, title, status, metadata, owner_id, visibility)
select (select id from content.channels where name = 'query32'), 'm', 'stored',
       jsonb_build_object('agent', 'query32-' || o.who), o.id, 'private'
  from (values ('a', '00000000-0000-4000-8000-0000001186a1'::uuid, 30),
               ('b', '00000000-0000-4000-8000-0000001186b2'::uuid, 5000)) o(who, id, n),
       generate_series(1, o.n);
insert into content.resource_chunks (resource_id, ordinal, content)
select r.id, k, 'harbour berth ' || (abs(hashtext(r.id::text || k)) % 97) || ' tide ' || k
  from content.resources r cross join generate_series(0, 3) k
 where r.channel_id = (select id from content.channels where name = 'query32');
do $$
begin
    execute format('insert into aiq.%I (chunk_id, embedding) '
                   'select c.id, array[sin(h), cos(h), sin(2 * h), cos(3 * h)]::vector from ('
                   '  select c.id, (abs(hashtext(c.id::text)) %% 10000) / 1000.0 as h from content.resource_chunks c'
                   '    join content.resources r on r.id = c.resource_id'
                   '   where r.channel_id = (select id from content.channels where name = %L)) c',
                   aiq.embedding_space_name('demo-quad-a'), 'query32');
end $$;
-- The database's own sample memories are public, and an owner rightly reads them where a scope to A's agent does
-- not: made B's and private for this transaction, so what A can read is exactly what the scope names.
update content.resources set visibility = 'private', owner_id = '00000000-0000-4000-8000-0000001186b2'
 where channel_id <> (select id from content.channels where name = 'query32')
   and (visibility <> 'private' or owner_id = '00000000-0000-4000-8000-0000001186a1');
analyze content.resources;
analyze content.resource_chunks;


-- The operator's scoped answers, the reference.
create temporary table query32_scoped on commit drop as
select 'semantic' as mode, array_agg(chunk_id order by distance, chunk_id) as ids, count(*) filter (where true) as n
  from aiq.semantic_in('chunks', '[1,0,0,0]', 'demo-quad-a', 50, '{"agent": "query32-a"}');
insert into query32_scoped
select 'hybrid', array_agg(chunk_id order by rrf_score desc, chunk_id), count(*)
  from aiq.search('chunks', 'harbour berth tide', '[1,0,0,0]', 'demo-quad-a', 50, 60, '{"agent": "query32-a"}');
grant select on query32_scoped to authenticated;


set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000001186a1"}';
set local role authenticated;
do $$
declare v_ids uuid[]; v_empty int; v_plan jsonb; v_touched numeric;
begin
    -- 1. The same answers as the scoped search.
    select array_agg(chunk_id order by distance, chunk_id) into v_ids
      from aiq.semantic_in('chunks', '[1,0,0,0]', 'demo-quad-a', 50);
    assert v_ids = (select ids from query32_scoped where mode = 'semantic') and cardinality(v_ids) = 50,
        'an owner''s semantic search returns what the search scoped to them does';
    select array_agg(chunk_id order by rrf_score desc, chunk_id), count(*) filter (where content is null)
      into v_ids, v_empty
      from aiq.search('chunks', 'harbour berth tide', '[1,0,0,0]', 'demo-quad-a', 50, 60);
    assert v_ids = (select ids from query32_scoped where mode = 'hybrid') and cardinality(v_ids) = 50,
        'and so does a hybrid search';
    assert v_empty = 0, 'every hybrid row carries its content';

    -- 2. The count reads A's chunks, not everybody's.
    execute format('explain (analyze, format json) select count(*) from (select 1 from %s c limit 20001) x',
                   aiq.scoped_source('content.resource_chunks', null)) into v_plan;
    select coalesce(sum(((n->>'Actual Rows')::numeric + coalesce((n->>'Rows Removed by Filter')::numeric, 0))
                        * (n->>'Actual Loops')::numeric), 0)
      into v_touched
      from jsonb_path_query(v_plan, 'strict $.**') n
     where jsonb_typeof(n) = 'object' and n->>'Relation Name' = 'resource_chunks';
    assert v_touched <= 240, format('the count touched %s chunk rows for an owner of 120', v_touched);
    raise notice 'query/32: an owner''s search matches the scoped one and reads % chunk rows of 20,120', v_touched;
end $$;
reset role;
set local request.jwt.claims = '';

rollback;
