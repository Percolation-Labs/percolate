-- A TIE COMES BACK IN ONE ORDER (REM-1312).
--
-- RRF ties are ordinary: a chunk ranked 1st by words and 3rd by meaning scores 1/61 + 1/63, exactly what the chunk
-- ranked 3rd and 1st scores. aiq.search broke no tie, so tied rows came back in whatever order the plan produced:
-- on the Mem0 memory fixture (dev/evals/memory) question q21 put f02 first on one run and f19 on the next, on one
-- unchanged database, and the benchmark read 63% and then 61% hit@1. Which of two tied rows came first was decided
-- by the join the planner chose: a merge join on the chunk id handed them over in id order, a hash join in the
-- semantic side's order. Every rank and the final order now end on the chunk id. What is held:
--
--   1. the q21 shape: two chunks at lexical/semantic ranks 1/3 and 3/1 tie;
--   2. asked under each join the planner may choose (merge, hash, nested loop), the lower id comes first every
--      time. Without the tiebreak the hash join puts the other one first, so this can fail;
--   3. five chunks identical in words and vector (every rank a tie) come back in id order under each join.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into aiq.embedding_models (name, dim, provider, distance_op, is_default, notes)
values ('query66-quad', 4, null, 'vector_cosine_ops', false, 'query/66 fixture')
on conflict do nothing;
select aiq.register_embedding_space('query66-quad');
insert into content.channels (name, kind, visibility) values ('query66', 'manual', 'public');

-- `late` is registered first and so has the lower id: under a hash join the shipped function put `early`, the
-- semantic side's first, ahead of it.
select content.register_text('query66', 'query66:' || k, jsonb_build_array(jsonb_build_object('content', t)), k,
                             'query66:' || k, null, '{}')
  -- Each holds every word of the question, so each has a words rank (aiq.search matches all of them), ordered by
  -- how often it repeats them.
  from (values ('late',  'Maya worked at Northwind. Maya liked the work at Northwind'),  -- words 1st, meaning 3rd
               ('mid',   'Maya worked at Northwind and liked the work'),                 -- words 2nd, meaning 2nd
               ('early', 'Maya worked at Northwind')                                     -- words 3rd, meaning 1st
       ) v(k, t);
select content.register_text('query66', 'query66:same' || n, '[{"content": "an identical note about tea"}]',
                             'same ' || n, 'query66:same' || n, null, '{}')
  from generate_series(1, 5) n;

select aiq.record_embeddings('query66-quad', jsonb_agg(jsonb_build_object('chunk_id', c.id, 'embedding', v.e)))
  from content.resource_chunks c join content.resources r on r.id = c.resource_id
  join (values ('query66:late', '[1,1,0,0]'::jsonb), ('query66:mid', '[1,0.5,0,0]'), ('query66:early', '[1,0.1,0,0]'),
               ('query66:same1', '[0,0,1,0]'), ('query66:same2', '[0,0,1,0]'), ('query66:same3', '[0,0,1,0]'),
               ('query66:same4', '[0,0,1,0]'), ('query66:same5', '[0,0,1,0]')) v(uri, e) on v.uri = r.uri;

do $$
declare
    late uuid := (select c.id from content.resource_chunks c join content.resources r on r.id = c.resource_id
                   where r.uri = 'query66:late');
    early uuid := (select c.id from content.resource_chunks c join content.resources r on r.id = c.resource_id
                    where r.uri = 'query66:early');
    same uuid[] := array(select c.id from content.resource_chunks c join content.resources r on r.id = c.resource_id
                          where r.uri like 'query66:same%' order by c.id);
    q text := 'Where did Maya work, Northwind?';
    a record; b record; got uuid[]; plan text;
    plans text[] := array['default', 'no merge join', 'no merge or hash join'];
begin
    -- 1. The q21 shape, and the tie it makes.
    select * into a from aiq.search('chunks', q, '[1,0,0,0]', 'query66-quad', 10, 60, '{"channel": "query66"}')
     where chunk_id = late;
    select * into b from aiq.search('chunks', q, '[1,0,0,0]', 'query66-quad', 10, 60, '{"channel": "query66"}')
     where chunk_id = early;
    if (a.lexical_rank, a.semantic_rank, b.lexical_rank, b.semantic_rank) is distinct from (1, 3, 3, 1) then
        raise exception 'the fixture no longer makes the 1/3 against 3/1 tie: late %/%, early %/%',
            a.lexical_rank, a.semantic_rank, b.lexical_rank, b.semantic_rank;
    end if;
    if a.rrf_score <> b.rrf_score then
        raise exception 'ranks 1/3 and 3/1 did not tie: % and %', a.rrf_score, b.rrf_score;
    end if;

    foreach plan in array plans loop
        perform set_config('enable_mergejoin', case when plan = 'default' then 'on' else 'off' end, true);
        perform set_config('enable_hashjoin', case when plan = 'no merge or hash join' then 'off' else 'on' end, true);

        -- 2. The tie, in id order, whatever the join.
        select array_agg(s.chunk_id order by s.ord) into got
          from aiq.search('chunks', q, '[1,0,0,0]', 'query66-quad', 10, 60, '{"channel": "query66"}')
               with ordinality s(chunk_id, content, rrf_score, lexical_rank, semantic_rank, key_match, ord)
         where s.chunk_id in (late, early);
        if got is distinct from array[least(late, early), greatest(late, early)] then
            raise exception 'with %, a tie did not come back in id order: % (lower id %)', plan, got, least(late, early);
        end if;

        -- 3. Every rank a tie.
        select array_agg(s.chunk_id order by s.ord) into got
          from aiq.search('chunks', 'an identical note about tea', '[0,0,1,0]', 'query66-quad', 10, 60,
                          '{"channel": "query66"}')
               with ordinality s(chunk_id, content, rrf_score, lexical_rank, semantic_rank, key_match, ord)
         where s.chunk_id = any(same);
        if got is distinct from same then
            raise exception 'with %, five identical chunks did not come back in id order: % (ids %)', plan, got, same;
        end if;
    end loop;
    perform set_config('enable_mergejoin', 'on', true);
    perform set_config('enable_hashjoin', 'on', true);
    raise notice 'query/66: a tie comes back in id order under every join';
end $$;

rollback;
