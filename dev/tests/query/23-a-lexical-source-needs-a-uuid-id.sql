-- A lexical source needs a uuid id (REM-1007, specs/ai-query-layer/schema.sql). Every retrieval mode returns a row's
-- id as chunk_id uuid, so a table with an integer id registered cleanly and failed only at query time, as "Returned
-- type integer does not match expected type uuid in column chunk_id". Registration now refuses it, naming the
-- column and the type it found, and registers nothing; a table with no id at all is refused the same way.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;
set local role app_owner;

create schema t23;
create table t23.int_notes (id int generated always as identity primary key, body text not null);
create table t23.no_id (key uuid primary key default gen_random_uuid(), body text not null);
create table t23.uuid_notes (id uuid primary key default gen_random_uuid(), body text not null);
insert into t23.uuid_notes (body) values ('The pilot boarded at the outer buoy');

do $$
declare
    msg  text;
    code text;
begin
    begin
        perform aiq.register_lexical_source('int_notes23', 't23.int_notes', 'body', 'english');
        raise exception 'an integer id was registered';
    exception when datatype_mismatch then
        get stacked diagnostics msg = message_text;
        assert msg = 'lexical source int_notes23 needs a uuid id column: t23.int_notes.id is integer', msg;
    end;
    assert not exists (select 1 from aiq.lexical_sources where name = 'int_notes23'), 'nothing registered';
    assert not exists (select 1 from pg_attribute where attrelid = 't23.int_notes'::regclass and attname = 'search_tsv'),
        'no tsvector column added';

    begin
        perform aiq.register_lexical_source('no_id23', 't23.no_id', 'body', 'english');
        raise exception 'a table with no id was registered';
    exception when datatype_mismatch then
        get stacked diagnostics msg = message_text;
        assert msg = 'lexical source no_id23 needs a uuid id column: t23.no_id.id is missing', msg;
    end;

    -- A uuid id registers and is searched as before.
    perform aiq.register_lexical_source('uuid_notes23', 't23.uuid_notes', 'body', 'english');
    assert (select count(*) from aiq.lexical('uuid_notes23', 'pilot')) = 1, 'a uuid source is searchable';
end $$;

rollback;
