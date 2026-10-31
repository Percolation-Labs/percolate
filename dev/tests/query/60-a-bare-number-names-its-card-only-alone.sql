-- A BARE NUMBER NAMES ITS CARD, BUT ONLY ALONE (REM-1273).
--
-- A board card's writer declares its bare number as an alias (`metadata.aliases`, projected as `alias` keys), so
-- `143` reaches REM-143. But cards REM-1 to REM-1274 have the aliases 1 to 1274, and accepted on any word of a
-- query they took 16 of 20 ordinary questions to the wrong card (p8-subsystems
-- meta/spikes/2026-10-31-bare-number-alias). What is held:
--
--   1. without the alias the card is not first for `143`, so this test can fail;
--   2. `143` and `#143` return the card first, with key_match `alias:143`;
--   3. `why did 3 tests fail` does not go to REM-3 by key, though REM-3 has the alias `3`;
--   4. aliases are written as `alias` keys, never `short`, and a string where an array belongs writes none.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into aiq.embedding_models (name, dim, provider, distance_op, is_default, notes)
values ('query60-quad', 4, null, 'vector_cosine_ops', false, 'query/60 fixture')
on conflict do nothing;
select aiq.register_embedding_space('query60-quad');
insert into content.channels (name, kind, visibility) values ('query60', 'manual', 'public');

-- REM-143 says nothing of its number; two other documents say `143` more often than it does.
select content.register_text('query60', 'query60:143', '[{"content": "id: REM-143\ntitle: shorter release notes"}]',
                             'REM-143', 'query60:143', null, '{"keys": ["REM-143"], "aliases": ["143"]}');
select content.register_text('query60', 'query60:3', '[{"content": "id: REM-3\ntitle: the first walk"}]',
                             'REM-3', 'query60:3', null, '{"keys": ["REM-3"], "aliases": ["3"]}');
select content.register_text('query60', 'query60:m' || n,
                             jsonb_build_array(jsonb_build_object('content',
                                 'tests: 143 passed, 143 run. why did 3 tests fail? 3 tests fail on 143.')),
                             'run ' || n, 'query60:m' || n, null, '{}')
  from generate_series(1, 2) n;
select content.register_text('query60', 'query60:bad', '[{"content": "a stray note"}]', 'bad', 'query60:bad', null,
                             '{"aliases": "999"}');

do $$
declare
    card uuid := (select c.id from content.resource_chunks c join content.resources r on r.id = c.resource_id
                   where r.uri = 'query60:143');
    three uuid := (select c.id from content.resource_chunks c join content.resources r on r.id = c.resource_id
                    where r.uri = 'query60:3');
    got record;
begin
    -- 1. Without the alias rows, the mentions outrank the card.
    update aiq.node_keys set kind = 'short', key = 'x-' || key where kind = 'alias' and key = '143';
    select * into got from aiq.search('chunks', '143', '[1,0,0,0]', 'query60-quad', 10, 60, '{"channel": "query60"}') limit 1;
    if got.chunk_id = card then
        raise exception 'without its alias the card already ranks first for 143, so this test proves nothing';
    end if;
    update aiq.node_keys set kind = 'alias', key = '143' where kind = 'short' and key = 'x-143';

    -- 2. Alone, with or without a mark.
    select * into got from aiq.search('chunks', '143', '[1,0,0,0]', 'query60-quad', 10, 60, '{"channel": "query60"}') limit 1;
    if got.chunk_id is distinct from card or got.key_match is distinct from 'alias:143' then
        raise exception 'SEARCH "143" did not return REM-143 first by its alias: % (%)', got.chunk_id, got.key_match;
    end if;
    select * into got from aiq.search('chunks', '#143', '[1,0,0,0]', 'query60-quad', 10, 60, '{"channel": "query60"}') limit 1;
    if got.chunk_id is distinct from card then
        raise exception 'SEARCH "#143" did not return REM-143 first: % (%)', got.chunk_id, got.key_match;
    end if;

    -- 3. In a sentence, a number is a number.
    if exists (select 1 from aiq.search('chunks', 'why did 3 tests fail', '[1,0,0,0]', 'query60-quad', 10, 60,
                                        '{"channel": "query60"}') where key_match is not null) then
        raise exception '"why did 3 tests fail" was keyed to a card by its alias';
    end if;
    select * into got from aiq.search('chunks', 'why did 3 tests fail', '[1,0,0,0]', 'query60-quad', 10, 60,
                                      '{"channel": "query60"}') limit 1;
    if got.chunk_id = three then
        raise exception '"why did 3 tests fail" went to REM-3';
    end if;

    -- 4. Written as aliases, and only from an array.
    if not exists (select 1 from aiq.node_keys where key = '143' and kind = 'alias')
       or exists (select 1 from aiq.node_keys where key in ('143', '3') and kind <> 'alias') then
        raise exception 'declared aliases were not projected as alias keys';
    end if;
    if exists (select 1 from aiq.node_keys where key = '999') then
        raise exception 'aliases given as a string were projected';
    end if;
    raise notice 'query/60: a bare number names its card alone, and a sentence''s numbers name nothing';
end $$;

rollback;
