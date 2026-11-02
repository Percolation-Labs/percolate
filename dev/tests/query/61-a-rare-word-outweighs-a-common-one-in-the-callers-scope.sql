-- A RARE WORD OUTWEIGHS A COMMON ONE, COUNTED IN THE CALLER'S SCOPE (REM-1273).
--
-- aiq.lexical ranked by ts_rank, which has no IDF: a word in every document counted as much as one in a single
-- document, so 'rem', in every board card, outweighed the '-571' that names one. It now ranks by BM25, and word
-- rarity comes from aiq.lexical_idf: pg_stats for a caller who may read the table's statistics, otherwise counted
-- over the rows the caller can see. What is held:
--
--   1. ts_rank puts the document repeating the common word first, so this test can fail;
--   2. as a caller under row security, the document holding the rare word comes first;
--   3. another owner's private rows change none of that caller's scores, though they hold the rare word 30 times:
--      rarity is counted over what the caller can read, never over the table;
--   4. a query of stop words alone still matches nothing.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into content.channels (name, kind, visibility) values ('query61', 'manual', 'public');

-- Twenty documents say 'apple'; one says it three times; one says 'kiwi' once.
select content.register_text('query61', 'query61:a' || n, jsonb_build_array(jsonb_build_object('content',
                             'apple orchard note ' || n)), 'apple ' || n, 'query61:a' || n, null, '{}')
  from generate_series(1, 20) n;
select content.register_text('query61', 'query61:apples', '[{"content": "apple apple apple"}]', 'apples',
                             'query61:apples', null, '{}');
select content.register_text('query61', 'query61:kiwi', '[{"content": "kiwi"}]', 'kiwi', 'query61:kiwi', null, '{}');

create temp table query61_scores (phase text, chunk_id uuid, score real) on commit drop;
grant all on query61_scores to authenticated;

do $$
declare
    apples uuid := (select c.id from content.resource_chunks c join content.resources r on r.id = c.resource_id
                     where r.uri = 'query61:apples');
    top uuid;
begin
    -- 1. Without IDF, the repeated common word wins.
    select c.id into top
      from content.resource_chunks c join content.resources r on r.id = c.resource_id
     where r.uri like 'query61:%' and c.search_tsv @@ to_tsquery('english', 'apple | kiwi')
     order by ts_rank(c.search_tsv, to_tsquery('english', 'apple | kiwi'), 1) desc, c.id limit 1;
    if top is distinct from apples then
        raise exception 'ts_rank already ranks the rare word first, so this test proves nothing';
    end if;
end $$;

set local role authenticated;
set local request.jwt.claims = '{"sub":"61610000-0000-0000-0000-00000000000b"}';

do $$
declare
    kiwi uuid := (select c.id from content.resource_chunks c join content.resources r on r.id = c.resource_id
                   where r.uri = 'query61:kiwi');
    got record;
begin
    if exists (select 1 from pg_stats where schemaname = 'content' and tablename = 'resource_chunks') then
        raise exception 'pg_stats is readable under row security, so this caller is not on the counted path';
    end if;
    -- 2. The rare word first.
    select * into got from aiq.lexical('chunks', 'apple kiwi', 10, '{"channel": "query61"}') limit 1;
    if got.chunk_id is distinct from kiwi then
        raise exception 'BM25 did not put the rare word first: % (%)', got.chunk_id, got.score;
    end if;
    insert into query61_scores select 'before', l.chunk_id, l.score
      from aiq.lexical('chunks', 'apple kiwi', 50, '{"channel": "query61"}') l;
end $$;

reset role;
-- Another owner's private documents in the same channel, each saying 'kiwi' 30 times.
select content.register_text('query61', 'query61:p' || n, jsonb_build_array(jsonb_build_object('content',
                             repeat('kiwi ', 30))), 'private ' || n, 'query61:p' || n, null, '{}')
  from generate_series(1, 40) n;
update content.resources set visibility = 'private', owner_id = '61610000-0000-0000-0000-00000000000a'
 where uri like 'query61:p%';
set local role authenticated;
set local request.jwt.claims = '{"sub":"61610000-0000-0000-0000-00000000000b"}';

do $$
declare n int;
begin
    if exists (select 1 from content.resources where uri like 'query61:p%') then
        raise exception 'the other owner''s private documents are visible to this caller';
    end if;
    -- 3. Nothing the caller cannot read moved a score.
    insert into query61_scores select 'after', l.chunk_id, l.score
      from aiq.lexical('chunks', 'apple kiwi', 50, '{"channel": "query61"}') l;
    select count(*) into n
      from (select chunk_id, score from query61_scores where phase = 'before') b
      full join (select chunk_id, score from query61_scores where phase = 'after') a using (chunk_id)
     where a.score is distinct from b.score;
    if n <> 0 then
        raise exception '% of the caller''s scores changed when another owner added private rows', n;
    end if;
    -- 4. Stop words alone.
    if exists (select 1 from aiq.lexical('chunks', 'the and of', 10, '{"channel": "query61"}')) then
        raise exception 'a query of stop words matched something';
    end if;
    raise notice 'query/61: a rare word outweighs a common one, counted over what the caller can read';
end $$;

rollback;
