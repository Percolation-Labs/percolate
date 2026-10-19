-- THE STORE RAISES WHAT ONLY THE STORE KNOWS (REM-948).
--
-- aiq.query's retrieval modes carry `exceptions`: the result kinds of core's
-- semantic-exceptions catalogue that need a fact the envelope never held --
-- how many rows matched -- raised in the statement that ran the search, with
-- no Python round trip. Core's own adapter says TRUNCATED_AT_LIMIT "needs the
-- total the envelope does not carry"; these assertions are that total, used.
--
-- Own corpus, so the counts are known: 1,200 notes about the harbour, three
-- about a pilot, none about a zeppelin. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

create schema t17;
create table t17.notes (id uuid primary key default gen_random_uuid(), body text not null);
insert into t17.notes (body)
select 'Harbour log entry ' || g || ': berth inspected' from generate_series(1, 1200) g;
insert into t17.notes (body) values
    ('The pilot boarded at the outer buoy'),
    ('Pilot launch delayed by fog'),
    ('A second pilot was requested for the night transit');
select aiq.register_lexical_source('notes17', 't17.notes', 'body', 'english');

do $$
declare v jsonb; e jsonb;
begin
    -- 1. Fewer matches than the limit: no exception, and the list is present.
    v := aiq.query('TEXT "pilot" FROM notes17 LIMIT 5');
    if jsonb_array_length(v->'rows') is distinct from 3 then
        raise exception '1: expected 3 pilot rows, got %', jsonb_array_length(v->'rows');
    end if;
    if v->'exceptions' is distinct from '[]'::jsonb then
        raise exception '1: three of three returned raises nothing, got %', v->'exceptions';
    end if;
    if exists (select 1 from jsonb_array_elements(v->'rows') r where r ? 'n') then
        raise exception '1: a row carries the internal rank column n';
    end if;

    -- 2. The limit cut the result: the store says so, with the total.
    v := aiq.query('TEXT "pilot" FROM notes17 LIMIT 2');
    e := (select x from jsonb_array_elements(v->'exceptions') x where x->>'code' = 'TRUNCATED_AT_LIMIT');
    if e is null then
        raise exception '2: two of three returned must raise TRUNCATED_AT_LIMIT, got %', v->'exceptions';
    end if;
    if e->'evidence' is distinct from '{"returned": 2, "limit": 2, "total": 3, "capped": false}'::jsonb then
        raise exception '2: evidence %', e->'evidence';
    end if;
    if e->>'severity' is distinct from 'warning' or e->>'stage' is distinct from 'result'
       or e->>'prompt' not like 'The result filled the limit%' then
        raise exception '2: not core''s kind: %', e;
    end if;
    if jsonb_array_length(v->'rows') is distinct from 2 then
        raise exception '2: LIMIT 2 returned % rows', jsonb_array_length(v->'rows');
    end if;

    -- 3. Too many to read: TOO_BROAD, counted by a bounded probe that says it stopped.
    v := aiq.query('TEXT "harbour" FROM notes17 LIMIT 10');
    e := (select x from jsonb_array_elements(v->'exceptions') x where x->>'code' = 'TOO_BROAD');
    if e is null or e->'evidence' is distinct from '{"total": 1001, "capped": true}'::jsonb then
        raise exception '3: 1,200 matches must raise TOO_BROAD (capped at 1001), got %', v->'exceptions';
    end if;
    if not exists (select 1 from jsonb_array_elements(v->'exceptions') x
                    where x->>'code' = 'TRUNCATED_AT_LIMIT') then
        raise exception '3: ten of 1,200 is truncated as well, got %', v->'exceptions';
    end if;
    if jsonb_array_length(v->'rows') is distinct from 10 then
        raise exception '3: LIMIT 10 returned % rows', jsonb_array_length(v->'rows');
    end if;

    -- 4. Nothing at all: EMPTY, not a silent [].
    v := aiq.query('TEXT "zeppelin" FROM notes17');
    if (select array_agg(x->>'code') from jsonb_array_elements(v->'exceptions') x)
       is distinct from array['EMPTY'] then
        raise exception '4: no match must raise EMPTY alone, got %', v->'exceptions';
    end if;

    -- 5. A mode that does not search text does not pretend to have looked.
    v := aiq.query('SCHEMA');
    if v ? 'exceptions' then
        raise exception '5: SCHEMA carries exceptions it never checked';
    end if;
end $$;

select 'semantic exceptions raised by the store: ok' as result;

rollback;
