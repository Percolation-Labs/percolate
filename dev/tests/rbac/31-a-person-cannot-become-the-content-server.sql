-- A PERSON CANNOT BECOME THE CONTENT SERVER (REM-1118).
--
-- content.files keeps the first registrant's bucket and key for a checksum, so whoever may name a location may
-- redirect every later upload of those bytes. Only the Content Server has read the bytes it registers, and the
-- database tells it apart by role: `content_server`, reached from authenticator by SET ROLE.
--
-- SET ROLE is checked against the SESSION user, so anything logged in as authenticator -- PostgREST, an application,
-- the Content Server -- may name it. What keeps a person out is that a person never gets to: PostgREST takes the role
-- from the signed token's claim, set_config is refused to authenticated (REM-44), and the SQL passthrough runs one
-- read query. This holds that, on the path a person arrives by:
--
--   1. content_server exists, cannot log in, and acts as the person whose claims it carries (it is authenticated);
--   2. a person, as authenticated over authenticator, cannot switch to it by set_config or through the passthrough;
--   3. the Content Server, logged in as authenticator, can.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

do $$
begin
    assert exists (select 1 from pg_roles where rolname = 'content_server' and not rolcanlogin),
        'content_server exists and cannot log in';
    assert pg_has_role('content_server', 'authenticated', 'member'), 'content_server acts as authenticated';
    assert pg_has_role('authenticator', 'content_server', 'member'), 'authenticator may become content_server';
end $$;

-- 2. A person, as PostgREST makes them.
set local session authorization authenticator;
select set_config('request.jwt.claims', '{"sub": "00000000-0000-4000-8000-000000111831"}', true) \g /dev/null
set local role authenticated;
do $$
declare v_refused int := 0;
begin
    begin perform set_config('role', 'content_server', true);
    exception when insufficient_privilege then v_refused := v_refused + 1; end;
    begin perform aiq.sql_passthrough('set role content_server');
    exception when others then v_refused := v_refused + 1; end;
    assert v_refused = 2, 'set_config and the passthrough both refuse to switch a person to content_server';
    assert current_user = 'authenticated', 'and the person is still authenticated';
end $$;

-- 3. The Content Server, logged in as authenticator.
reset role;
set local role content_server;
do $$ begin assert current_user = 'content_server', 'authenticator becomes content_server'; end $$;
reset role;
reset session authorization;

rollback;
