-- HYBRID ORDER FOLLOWS MEANING, NOT SHORT ROWS (REM-1312).
--
-- Since REM-1145 aiq.lexical matches any of the query's words, and aiq.search fused it. RRF uses only rank, so
-- every row sharing one word got a lexical rank, the shortest first. A memory's owner is named in all of their
-- memories: on the Mem0 fixture "Which language is Maya trying to pick up?" matched all 40 of Maya's facts and
-- "Maya lives in Lisbon." outranked "Maya is learning Portuguese", which the meaning half put first. aiq.search's
-- words half now matches all of the query's words. What is held:
--
--   1. a question whose one shared word is in every row: no words rank, and the meaning half's first row is first.
--      On the any-word half the shortest row, second by meaning, came first, so this can fail;
--   2. a row holding every word of a query still gets its words rank, and comes first;
--   3. TEXT (aiq.lexical alone) still matches any word: the lexical arm on its own keeps REM-1145.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into aiq.embedding_models (name, dim, provider, distance_op, is_default, notes)
values ('query67-quad', 4, null, 'vector_cosine_ops', false, 'query/67 fixture')
on conflict do nothing;
select aiq.register_embedding_space('query67-quad');
insert into content.channels (name, kind, visibility) values ('query67', 'manual', 'public');

-- One person's memories, every one naming her. `gold` is nearest the question in meaning and the longest; the
-- others are short and share only her name with the question.
select content.register_text('query67', 'query67:' || k, jsonb_build_array(jsonb_build_object('content', t)), k,
                             'query67:' || k, null, '{}')
  from (values ('gold', 'Maya is learning Portuguese, an hour every evening, before her move abroad next spring'),
               ('f1',   'Maya lives in Lisbon.'),
               ('f2',   'Maya is allergic to peanuts.'),
               ('f3',   'Maya prefers morning workouts.'),
               ('f4',   'Maya works at Northwind Analytics.'),
               ('f5',   'Maya has a cat called Miso.')) v(k, t);

select aiq.record_embeddings('query67-quad', jsonb_agg(jsonb_build_object('chunk_id', c.id, 'embedding', v.e)))
  from content.resource_chunks c join content.resources r on r.id = c.resource_id
  join (values ('query67:gold', '[1,0.1,0,0]'::jsonb), ('query67:f1', '[1,0.2,0,0]'), ('query67:f2', '[1,0.4,0,0]'),
               ('query67:f3', '[1,0.6,0,0]'), ('query67:f4', '[1,0.8,0,0]'), ('query67:f5', '[1,1,0,0]')) v(uri, e)
    on v.uri = r.uri;

do $$
declare
    gold uuid := (select c.id from content.resource_chunks c join content.resources r on r.id = c.resource_id
                   where r.uri = 'query67:gold');
    f4 uuid := (select c.id from content.resource_chunks c join content.resources r on r.id = c.resource_id
                 where r.uri = 'query67:f4');
    got record; n int;
begin
    -- 1. One shared word, in every row.
    select * into got from aiq.search('chunks', 'Which language is Maya trying to pick up?', '[1,0,0,0]',
                                      'query67-quad', 10, 60, '{"channel": "query67"}') limit 1;
    if got.chunk_id is distinct from gold then
        raise exception 'a row sharing only the owner''s name outranked the nearest in meaning: % (lexical rank %, semantic rank %)',
            got.chunk_id, got.lexical_rank, got.semantic_rank;
    end if;
    select count(*) into n from aiq.search('chunks', 'Which language is Maya trying to pick up?', '[1,0,0,0]',
                                           'query67-quad', 10, 60, '{"channel": "query67"}')
     where lexical_rank is not null;
    if n <> 0 then raise exception '% row(s) holding only some of the words got a words rank', n; end if;

    -- 2. Every word, in one row: it ranks by words, and first, though it is fourth by meaning.
    select * into got from aiq.search('chunks', 'Where does Maya work? Northwind Analytics?', '[1,0,0,0]',
                                      'query67-quad', 10, 60, '{"channel": "query67"}') limit 1;
    if got.chunk_id is distinct from f4 or got.lexical_rank is distinct from 1 then
        raise exception 'the row holding every word is not first by words: % (lexical rank %)', got.chunk_id, got.lexical_rank;
    end if;

    -- 3. TEXT alone keeps any-word matching.
    select count(*) into n from aiq.lexical('chunks', 'Which language is Maya trying to pick up?', 10, '{"channel": "query67"}');
    if n <> 6 then raise exception 'aiq.lexical alone matched % of 6 rows sharing a word: TEXT stopped matching any word', n; end if;
    raise notice 'query/67: hybrid order follows meaning, not short rows, and TEXT still matches any word';
end $$;

rollback;
