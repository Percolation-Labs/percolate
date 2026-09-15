-- loads: research-platform/schema.sql
-- Every work a person saved, readable or not (REM-307). A reader saves listed
-- research; its owner then makes it private. The reader's saves still name the
-- work, marked readable = false, with nothing but its id, so Library can keep it
-- listed as unavailable (REM-196). A stranger's saves never show the reader's,
-- and a caller who is nobody is refused.
--
-- One transaction, rolled back. Claims are set as the superuser between blocks.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-000000307a01', 'rem307-reader@example.test',   'active'),
    ('00000000-0000-4000-8000-000000307a02', 'rem307-owner@example.test',    'active'),
    ('00000000-0000-4000-8000-000000307a03', 'rem307-stranger@example.test', 'active');
insert into rbac.roles (name, description) values ('rem307-lister', 'lists research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rem307-lister', 'research', 'list') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-000000307a02', 'rem307-lister');


-- 1. The owner lists a work, and the reader saves it. It is on their list, readable.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000307a02"}';
set local role authenticated;
select research.submit_package(
    '{"schema_version": "0.1", "title": "A listed reading", "summary": "Research anyone may read.",
      "claims": [{"id": "C1", "kind": "Source assertion", "text": "A listed claim.", "source_ids": ["S1"], "locator": "P1"}],
      "sources": [{"id": "S1", "title": "A listed source", "url": "https://example.com/listed", "origin": "Listed", "status": "Read", "locator": "P1"}],
      "edges": [], "visibility": "listed"}', null, 'rp-rem307-listed');
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000307a01"}';
set local role authenticated;
do $$
declare r record;
begin
    assert engagement.set_saved((select id from research.works where public_id = 'rp-rem307-listed'), true),
        'the reader saves the listed work';
    assert (select count(*) from engagement.my_saves()) = 1, 'one save';
    select * into r from engagement.my_saves();
    assert r.public_id = 'rp-rem307-listed' and r.readable and r.saved_at is not null, 'it is the listed work, readable';
end $$;
reset role;


-- 2. The owner makes it private. The reader can no longer read it, and still has the save, marked unreadable.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000307a02"}';
set local role authenticated;
select research.revise_package('rp-rem307-listed',
    '{"schema_version": "0.1", "title": "Private again", "claims": [], "sources": [], "edges": [], "visibility": "private"}',
    'draft-1');
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000307a01"}';
set local role authenticated;
do $$
declare r record;
begin
    assert research.get_package('rp-rem307-listed') is null, 'the reader can no longer read the work';
    assert not exists (select 1 from research.works where public_id = 'rp-rem307-listed'),
        'and its row is hidden, which is why a join cannot find the save';
    assert (select count(*) from engagement.my_saves()) = 1, 'the save is still listed';
    select * into r from engagement.my_saves();
    assert r.public_id = 'rp-rem307-listed' and not r.readable, 'by its id, marked unreadable';
end $$;
reset role;


-- 3. A stranger's list never holds the reader's save, and a caller who is nobody is refused.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-000000307a03"}';
set local role authenticated;
do $$
begin
    assert (select count(*) from engagement.my_saves()) = 0, 'a stranger who saved nothing sees nothing';
end $$;
reset role;
set local request.jwt.claims = '{}';
set local role authenticated;
do $$
begin
    begin
        perform * from engagement.my_saves();
        raise exception 'an anonymous caller read a list of saves';
    exception when insufficient_privilege or invalid_authorization_specification or raise_exception then
        if sqlerrm = 'an anonymous caller read a list of saves' then raise; end if;
    end;
end $$;
reset role;

rollback;
