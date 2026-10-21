-- A SCHEMA DOCUMENT NAMES ONLY WHAT ITS READER MAY READ (REM-1122).
--
-- SCHEMA "workflow" listed every workflow definition, so a signed-in caller
-- read the names of other people's private ones; and a capture run as an
-- operator stored the operator's view in aiq.schema_revisions, which every
-- signed-in caller may select. Asserted here:
--   1. Eve's SCHEMA "workflow" does not name Alice's private definition, and
--      Alice's does;
--   2. after an operator's capture, the stored workflow document does not
--      name it either, and schema_drift reports no drift for that facet;
--   3. the capture leaves the operator's claims as they were.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

\set alice '''00000000-0000-4000-8000-000000112201'''
\set eve   '''00000000-0000-4000-8000-000000112202'''
\set as_alice 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000112201"}''; set local role authenticated;'
\set as_eve   'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000112202"}''; set local role authenticated;'

begin;
insert into rbac.users (id, email, status) values
    (:alice, 'rem1122-alice@example.test', 'active'),
    (:eve,   'rem1122-eve@example.test',   'active');
insert into workflow.definitions (name, spec, owner_id, visibility) values
    ('rem1122_alice_private', '{"steps":[{"key":"a","kind":"work","queue":"rem1122"}]}', :alice, 'private');

-- 1.
:as_eve
do $$ begin
    if position('rem1122_alice_private' in aiq.schema_workflow()::text) > 0 then
        raise exception 'SCHEMA "workflow" named Alice''s private definition to Eve';
    end if;
end $$;
:as_alice
do $$ begin
    if position('rem1122_alice_private' in aiq.schema_workflow()::text) = 0 then
        raise exception 'SCHEMA "workflow" did not name Alice''s own definition to her';
    end if;
end $$;

-- 2 and 3. An operator's capture.
reset role;
set local request.jwt.claims = '';
select aiq.capture_schema_revisions() \g /dev/null
select coalesce(current_setting('request.jwt.claims', true), '') = '' as restored \gset
\if :restored
\else
    \echo 'query/26: capture left claims behind'
    select 1/0;
\endif
do $$ begin
    if exists (select 1 from aiq.schema_revisions where doc::text like '%rem1122_alice_private%') then
        raise exception 'a capture stored Alice''s private definition where every signed-in caller can read it';
    end if;
    if exists (select 1 from aiq.schema_drift() where facet = 'workflow') then
        raise exception 'schema_drift reports the workflow facet moved straight after a capture';
    end if;
end $$;

rollback;

\echo query/26: a schema document names only what its reader may read, and a capture stores a signed-out reader's view
