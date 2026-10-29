-- A WALK SEARCHES ITS OWN CHANNEL (REM-1214).
--
-- A walk over one channel took aiq.search's first 2,000 hits over every chunk in the database and kept its channel's
-- afterwards. So other data moved its order and could starve it: with two BEAM conversations loaded, a 1M:35 walk saw
-- 714 of its 1,058 documents. aiq.search's scope now names a channel, and walk_start passes it. What is held:
--
--   1. unscoped, another channel's closer chunks fill the first hits, so the old way would have lost channel A;
--   2. scoped to A, the order is A's alone and is the same before and after the other channel is added;
--   3. a walk over A starts from all of A's documents, in that order, with 2,500 closer chunks elsewhere.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into aiq.embedding_models (name, dim, provider, distance_op, is_default, notes)
values ('query40-quad', 4, null, 'vector_cosine_ops', false, 'query/40 fixture')
on conflict do nothing;
select aiq.register_embedding_space('query40-quad');
-- walk_start searches with the default model, as a walk over a loaded corpus does.
update aiq.embedding_models set is_default = (name = 'query40-quad');
insert into content.channels (name, kind, visibility) values ('query40-a', 'manual', 'public'), ('query40-b', 'manual', 'public');

-- Channel A: six documents of one chunk, each a little further from the query vector [1,0,0,0].
insert into content.resources (channel_id, uri, title, status, visibility)
select (select id from content.channels where name = 'query40-a'), 'query40-a:' || n, 'a' || n, 'ready', 'public'
  from generate_series(1, 6) n;
insert into content.resource_chunks (resource_id, ordinal, content)
select r.id, 0, 'ladder rung ' || substr(r.uri, 11) from content.resources r where r.uri like 'query40-a:%';
do $$
begin
    execute format('insert into aiq.%I (chunk_id, embedding) '
                   'select c.id, array[1, substr(r.uri, 11)::int / 10.0, 0, 0]::vector '
                   '  from content.resource_chunks c join content.resources r on r.id = c.resource_id '
                   ' where r.uri like %L', aiq.embedding_space_name('query40-quad'), 'query40-a:%');
end $$;

create temporary table query40_before on commit drop as
select array_agg(h.chunk_id order by h.rrf_score desc, h.chunk_id) as ids
  from aiq.search('chunks', 'ladder rung', '[1,0,0,0]', 'query40-quad', 2000, 60, '{"channel": "query40-a"}') h;

-- Channel B: 2,500 documents nearer the query than any of A's, in its words too.
insert into content.resources (channel_id, uri, title, status, visibility)
select (select id from content.channels where name = 'query40-b'), 'query40-b:' || n, 'b' || n, 'ready', 'public'
  from generate_series(1, 2500) n;
insert into content.resource_chunks (resource_id, ordinal, content)
select r.id, 0, 'ladder rung ladder rung' from content.resources r where r.uri like 'query40-b:%';
do $$
begin
    execute format('insert into aiq.%I (chunk_id, embedding) '
                   'select c.id, array[1, 0, 0, 0]::vector '
                   '  from content.resource_chunks c join content.resources r on r.id = c.resource_id '
                   ' where r.uri like %L', aiq.embedding_space_name('query40-quad'), 'query40-b:%');
end $$;

do $$
declare
    v_ids  uuid[];
    v_a    int;
    r      uuid;
    st     jsonb;
    want   jsonb;
begin
    -- 1. The test can fail: unscoped, B fills the first 2,000 hits and A gets none of them.
    select count(*) filter (where res.uri like 'query40-a:%') into v_a
      from aiq.search('chunks', 'ladder rung', '[1,0,0,0]', 'query40-quad', 2000) h
      join content.resource_chunks c on c.id = h.chunk_id
      join content.resources res on res.id = c.resource_id;
    if v_a <> 0 then
        raise exception 'the fixture does not crowd A out of an unscoped search: % of its chunks in the first 2,000', v_a;
    end if;

    -- 2. Scoped to A: A's six chunks, in the order they had before B arrived.
    select array_agg(h.chunk_id order by h.rrf_score desc, h.chunk_id) into v_ids
      from aiq.search('chunks', 'ladder rung', '[1,0,0,0]', 'query40-quad', 2000, 60, '{"channel": "query40-a"}') h;
    if cardinality(v_ids) <> 6 or v_ids is distinct from (select ids from query40_before) then
        raise exception 'a search scoped to A moved when B was added: % against %', v_ids, (select ids from query40_before);
    end if;

    -- 3. A walk over A starts from all six of A's documents, nearest first.
    perform workflow.define_yaml($y$
name: walk_query40
steps:
  - id: hold
    sql: {statement: "select 1"}
$y$);
    r := workflow.start_workflow('walk_query40', '{"question": {"text": "ladder rung"}, "channel": "query40-a", "settings": {"stack": false, "describe": "source", "order": "p"}}');
    st := aiq.walk_start(r, '[1,0,0,0]');
    select jsonb_agg('query40-a:' || n order by n) into want from generate_series(1, 6) n;
    if st->'order' is distinct from want then
        raise exception 'a walk over A did not start from its own documents in order: %', st->'order';
    end if;
    raise notice 'query/40: a walk searches its own channel, whatever else is loaded';
end $$;

rollback;
