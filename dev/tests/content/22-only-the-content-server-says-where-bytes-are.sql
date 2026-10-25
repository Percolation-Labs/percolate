-- ONLY THE CONTENT SERVER SAYS WHERE STORED BYTES ARE (REM-1118).
--
-- content.files is keyed on checksum and keeps the first registrant's bucket and key. Over PostgREST a person is
-- authenticated and could register a checksum at a location of their choosing; every later upload of those bytes then
-- resolved to it. Reproduced on main bf7da6fd: Mallory registered a checksum at mallory-bucket/mallory/owned-key, and
-- Maya's upload of the same bytes was served from there. Sirsh's decision (M-20261023-052904-d854): the Content Server
-- alone decides where a file is stored. It is told apart by role (dev/tests/rbac/31): it logs in as authenticator and
-- SETs ROLE content_server.
--
--   1. a person, as PostgREST makes them, is refused by register_upload, register_evidence and
--      register_research_image, and writes no file row;
--   2. the Content Server registers Maya's upload of the same bytes, and Maya's resource resolves to the location the
--      Content Server named.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-000000111801', 'rem1118-maya@example.test', 'active'),
    ('00000000-0000-4000-8000-000000111802', 'rem1118-mallory@example.test', 'active');
insert into rbac.roles (name) values ('rem1118_uploader');
insert into rbac.role_permissions (role, resource, action) values
    ('rem1118_uploader', 'resources', 'create'), ('rem1118_uploader', 'research', 'insert');
insert into rbac.user_roles (user_id, role) values
    ('00000000-0000-4000-8000-000000111801', 'rem1118_uploader'),
    ('00000000-0000-4000-8000-000000111802', 'rem1118_uploader');
insert into content.channels (name, kind, visibility) values ('rem1118-public', 'manual', 'public');

\set sum '''b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c'''


-- 1. Mallory, as PostgREST makes her: authenticator, her claims, authenticated.
set local session authorization authenticator;
select set_config('request.jwt.claims', '{"sub": "00000000-0000-4000-8000-000000111802"}', true) \g /dev/null
set local role authenticated;
do $$
declare v_hint text; v_hints text[] := '{}';
        v_sum text := 'b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c';
begin
    begin perform content.register_upload('rem1118-public', v_sum, 'mallory-bucket', 'mallory/owned-key', 4,
                                          'text/plain', 'bait');
    exception when insufficient_privilege then get stacked diagnostics v_hint = pg_exception_hint; v_hints := v_hints || v_hint; end;
    begin perform content.register_evidence('https://example.test/bait', v_sum, 'mallory-bucket', 'mallory/owned-key',
                                            4, 'text/html', 'bait');
    exception when insufficient_privilege then get stacked diagnostics v_hint = pg_exception_hint; v_hints := v_hints || v_hint; end;
    begin perform content.register_research_image(v_sum, 'mallory-bucket', 'mallory/owned-key', 4, 'image/png', 'bait');
    exception when insufficient_privilege then get stacked diagnostics v_hint = pg_exception_hint; v_hints := v_hints || v_hint; end;
    assert v_hints = array['content_server_only', 'content_server_only', 'content_server_only'],
        format('a person names no storage location, by any of the three; got %s', v_hints);
end $$;
reset role;


-- 2. The Content Server registers Maya's upload of the same bytes.
select set_config('request.jwt.claims', '{"sub": "00000000-0000-4000-8000-000000111801"}', true) \g /dev/null
set local role content_server;
create temporary table rem1118_maya on commit drop as
select content.register_upload('rem1118-public', :sum, 'percolate',
                               'objects/b5/' || :sum, 4, 'text/plain', 'Maya''s note') as id;
reset role;
reset session authorization;

do $$
begin
    assert (select count(*) from content.files
             where checksum = 'b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c') = 1,
        'one file row for the bytes, the Content Server''s';
    assert (select (bucket, object_key) = ('percolate'::text,
                    'objects/b5/b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c'::text)
              from content.files
             where checksum = 'b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c'),
        'Maya''s upload is stored where the Content Server said, not where Mallory asked';
end $$;

rollback;
