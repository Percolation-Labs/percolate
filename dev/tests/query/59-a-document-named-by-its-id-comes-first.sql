-- A DOCUMENT NAMED BY ITS ID COMES FIRST (REM-1273).
--
-- The parser splits `REM-571` into `rem` and `-571`, `rem` is in every card, and ts_rank has no IDF, so a card
-- searched by its own ID ranked behind the cards that mention it: 6th to 261st over the 1,271 board cards, 1,894th
-- over 17,915 history documents. A document now declares its IDs (`metadata.keys`, projected as short keys), and
-- aiq.search puts a document the query names exactly ahead of the lexical and semantic fusion. What is held:
--
--   1. without the key tier the card is not first, so this test can fail;
--   2. SEARCH "REM-571", and a question naming it, return the card first, once, with key_match;
--   3. a query naming no key keeps the fusion's order, and nothing is keyed;
--   4. keys that are not an array of strings declare nothing.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into aiq.embedding_models (name, dim, provider, distance_op, is_default, notes)
values ('query59-quad', 4, null, 'vector_cosine_ops', false, 'query/59 fixture')
on conflict do nothing;
select aiq.register_embedding_space('query59-quad');
insert into content.channels (name, kind, visibility) values ('query59', 'manual', 'public');

-- The card, and three that mention it more often than it mentions itself.
select content.register_text('query59', 'query59:card', '[{"content": "id: REM-571\ntitle: one navigation for the reading journey"}]',
                             'card', 'query59:card', null, '{"keys": ["REM-571"]}');
select content.register_text('query59', 'query59:m' || n,
                             jsonb_build_array(jsonb_build_object('content', repeat('REM-571 is still open. ', 4) || 'rem rem')),
                             'mention ' || n, 'query59:m' || n, null, '{}')
  from generate_series(1, 3) n;
select content.register_text('query59', 'query59:bad', '[{"content": "a stray note"}]', 'bad', 'query59:bad', null,
                             '{"keys": "REM-999"}');

do $$
declare
    card uuid := (select c.id from content.resource_chunks c join content.resources r on r.id = c.resource_id
                   where r.uri = 'query59:card');
    got record; n int; a uuid[]; b uuid[];
begin
    -- 1. The fusion alone ranks the mentions first.
    update aiq.lexical_sources set node_col = null where name = 'chunks';
    select array_agg(s.chunk_id order by s.ord) into a
      from aiq.search('chunks', 'REM-571', '[1,0,0,0]', 'query59-quad', 10, 60, '{"channel": "query59"}') with ordinality s(chunk_id, content, rrf_score, lexical_rank, semantic_rank, key_match, ord);
    if a[1] = card then
        raise exception 'without the key tier the card already ranks first, so this test proves nothing';
    end if;
    select array_agg(s.chunk_id order by s.ord) into b
      from aiq.search('chunks', 'still open', '[1,0,0,0]', 'query59-quad', 10, 60, '{"channel": "query59"}') with ordinality s(chunk_id, content, rrf_score, lexical_rank, semantic_rank, key_match, ord);
    update aiq.lexical_sources set node_col = 'resource_id' where name = 'chunks';

    -- 2. By its ID, and by a question naming it.
    select * into got from aiq.search('chunks', 'REM-571', '[1,0,0,0]', 'query59-quad', 10, 60, '{"channel": "query59"}') limit 1;
    if got.chunk_id is distinct from card or got.key_match is distinct from 'rem-571' then
        raise exception 'SEARCH "REM-571" did not return its card first by key: % (%)', got.chunk_id, got.key_match;
    end if;
    select * into got from aiq.search('chunks', 'why is REM-571 still open?', '[1,0,0,0]', 'query59-quad', 10, 60,
                                      '{"channel": "query59"}') limit 1;
    if got.chunk_id is distinct from card then
        raise exception 'a question naming REM-571 did not return its card first: %', got.chunk_id;
    end if;
    select count(*) into n from aiq.search('chunks', 'REM-571', '[1,0,0,0]', 'query59-quad', 10, 60, '{"channel": "query59"}')
     where chunk_id = card;
    if n <> 1 then raise exception 'the keyed card came back % times', n; end if;

    -- 3. Nothing named, nothing keyed, and the order is the fusion's.
    if exists (select 1 from aiq.search('chunks', 'still open', '[1,0,0,0]', 'query59-quad', 10, 60, '{"channel": "query59"}')
                where key_match is not null) then
        raise exception 'a query naming no key came back keyed';
    end if;
    select array_agg(s.chunk_id order by s.ord) into a
      from aiq.search('chunks', 'still open', '[1,0,0,0]', 'query59-quad', 10, 60, '{"channel": "query59"}') with ordinality s(chunk_id, content, rrf_score, lexical_rank, semantic_rank, key_match, ord);
    if a is distinct from b then raise exception 'the key tier changed an unnamed query''s order: % vs %', a, b; end if;

    -- 4. A string where an array belongs declares nothing.
    if exists (select 1 from aiq.node_keys where key = 'rem-999') then
        raise exception 'keys given as a string were projected';
    end if;
    raise notice 'query/59: a document named by its ID comes first, once, and an unnamed query keeps its order';
end $$;

rollback;
