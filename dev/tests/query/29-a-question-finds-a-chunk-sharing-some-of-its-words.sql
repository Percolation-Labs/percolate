-- A QUESTION FINDS A CHUNK SHARING SOME OF ITS WORDS (REM-1145).
--
-- aiq.lexical ANDed every word of the query, so a question in natural language matched only a chunk holding all
-- of them, which is almost never: on LongMemEval S through Percolate it found every source for 3 of 39 held-out
-- questions within 50 reads, and aiq.search's hybrid quietly returned its semantic half alone. It now matches any
-- of the words and ranks by how many and how densely. This holds that on the corpus sample, and holds the two
-- things the old form got right: a chunk sharing no word is not matched, and a query of stop words matches nothing.

\set ON_ERROR_STOP on

begin;

do $$
declare got uuid[]; n int;
begin
    if not exists (select 1 from content.resource_chunks where id = '33330000-0000-0000-0000-000000000001') then
        raise exception 'the corpus sample is not loaded (dev/init/05-corpus-sample.sql)';
    end if;

    -- No chunk holds every one of these words; the R7 notice holds the most of them, and ranks first.
    select array_agg(chunk_id order by score desc, chunk_id) into got
      from aiq.lexical('chunks', 'Is the R7 arm going to be recalled under sustained load next year?', 10);
    if got is null then
        raise exception 'a question sharing several words with a chunk matched nothing: lexical search still ANDs';
    end if;
    if got[1] is distinct from '33330000-0000-0000-0000-000000000001' then
        raise exception 'the chunk sharing the most words (R7, arm, recall, sustained, load) is not first: %', got;
    end if;
    if '33330000-0000-0000-0000-000000000006' = any(got) then
        raise exception 'a chunk sharing no word with the question was matched';
    end if;

    -- A query of stop words has nothing to match, and says so with no rows rather than an error.
    select count(*) into n from aiq.lexical('chunks', 'is it the of to', 10);
    if n <> 0 then raise exception 'a query of stop words matched % chunk(s)', n; end if;

    -- The hybrid's lexical half is present for the question again.
    if not exists (select 1 from aiq.search('chunks', 'Is the R7 arm going to be recalled under sustained load?',
                                            '[1,0,0,0]', 'demo-quad-a', 10)
                    where chunk_id = '33330000-0000-0000-0000-000000000001' and lexical_rank is not null) then
        raise exception 'aiq.search has no lexical rank for the chunk the question shares most words with';
    end if;
    raise notice 'query/29: a question finds the chunk sharing most of its words, and nothing sharing none';
end $$;

rollback;
