-- REGISTERING CONTENT NEVER ACTS ON ANOTHER PERSON'S RESOURCE (REM-1117).
--
-- register_text and register_upload upsert on (channel, external_id) past row
-- security. A second author who reused an external_id got the first author's
-- resource: register_text renamed it and repointed its uri (kept whenever the
-- chunks hashed the same, which is easy for text one can read), and
-- register_upload returned its id and started an ingest run on it.
-- register_text also found its channel by name alone. Asserted here:
--   1. Leo re-registering Maya's external_id is refused by both, and Maya's
--      title and uri are unchanged;
--   2. Maya re-registers her own, as before;
--   3. register_text cannot write into a private channel Leo cannot read.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

\set maya '''00000000-0000-4000-8000-000000111701'''
\set leo  '''00000000-0000-4000-8000-000000111702'''
\set as_maya 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000111701"}''; set local role authenticated;'
\set as_leo  'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-000000111702"}''; set local role authenticated;'

begin;
insert into rbac.users (id, email, status) values
    (:maya, 'rem1117-maya@example.test', 'active'),
    (:leo,  'rem1117-leo@example.test',  'active');
insert into rbac.roles (name) values ('rem1117_uploader');
insert into rbac.role_permissions (role, resource, action) values ('rem1117_uploader', 'resources', 'create');
insert into rbac.user_roles (user_id, role) values (:maya, 'rem1117_uploader'), (:leo, 'rem1117_uploader');
-- A public channel with no ingest workflow, and Maya's private one.
insert into content.channels (name, kind, visibility) values ('rem1117-public', 'manual', 'public');
insert into content.channels (name, kind, visibility, owner_id) values ('rem1117-mayas', 'manual', 'private', :maya);

create function pg_temp.refused(p_sql text, p_like text) returns void language plpgsql as $$
begin
    execute p_sql;
    raise exception 'accepted, and should have been refused: %', p_sql;
exception when others then
    if sqlerrm not like p_like then raise; end if;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

:as_maya
select content.register_text('rem1117-public', 'rem1117-text', '[{"content":"Maya wrote this."}]',
                             'Maya''s title', 'https://maya.example.test/x') \g /dev/null
select content.register_upload('rem1117-public', 'rem1117-sum', 'bucket', 'maya/key', 10,
                               p_external_id => 'rem1117-upload') \g /dev/null

-- 1. Leo, with Maya's external_ids.
:as_leo
select pg_temp.refused($q$select content.register_text('rem1117-public', 'rem1117-text', '[{"content":"Maya wrote this."}]',
                                                        'Renamed by Leo', 'https://leo.example.test/x')$q$,
                       '%already registered in this channel by someone else%');
select pg_temp.refused($q$select content.register_upload('rem1117-public', 'rem1117-sum-2', 'bucket', 'leo/key', 10,
                                                          p_external_id => 'rem1117-upload')$q$,
                       '%already registered in this channel by someone else%');
-- 3. Maya's private channel, by name.
select pg_temp.refused($q$select content.register_text('rem1117-mayas', 'rem1117-leo', '[{"content":"Leo''s"}]')$q$,
                       'no channel named rem1117-mayas');
reset role;
do $$
begin
    if (select title || ' ' || uri from content.resources where external_id = 'rem1117-text')
       is distinct from 'Maya''s title https://maya.example.test/x' then
        raise exception 'a refused re-registration renamed Maya''s resource anyway';
    end if;
    if exists (select 1 from content.resources where external_id = 'rem1117-leo') then
        raise exception 'register_text wrote into a channel its caller cannot read';
    end if;
end $$;

-- 2. Maya, her own.
:as_maya
select content.register_text('rem1117-public', 'rem1117-text', '[{"content":"Maya wrote this, again."}]',
                             'Maya''s second title') \g /dev/null
select content.register_text('rem1117-mayas', 'rem1117-own', '[{"content":"in my own channel"}]') \g /dev/null
reset role;
do $$
begin
    if (select title from content.resources where external_id = 'rem1117-text') is distinct from 'Maya''s second title' then
        raise exception 'Maya could not re-register her own text';
    end if;
    if not exists (select 1 from content.resources where external_id = 'rem1117-own') then
        raise exception 'Maya could not register into her own private channel';
    end if;
end $$;

rollback;

\echo content/20: registering never acts on another person's resource, and register_text finds only channels its caller can read
