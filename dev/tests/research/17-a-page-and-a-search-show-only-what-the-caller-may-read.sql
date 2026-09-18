-- research.list_listed and research.search_claims run as their owner, so row security never sees them
-- (REM-500, specs/research-platform/scale.md §2). rbac/14 proves each calls its readability predicate;
-- this proves the answer: another person's private claim is never found, a listed one is, and the owner
-- finds their own. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-00000000c501', 'rp-scale-alice@example.test', 'active'),
    ('00000000-0000-4000-8000-00000000c502', 'rp-scale-bob@example.test',   'active');
insert into rbac.roles (name, description) values ('rp-scale-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-scale-lister', 'research', 'list') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-00000000c501', 'rp-scale-lister');

-- Alice writes one private package and one listed one, each with a word nothing else in the database has.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000c501"}';
set local role authenticated;
do $$
declare
    d jsonb := '{"schema_version": "0.1", "summary": "A package for the REM-500 access test.",
                 "sources": [{"id": "S1", "title": "S", "url": "https://example.com/s", "origin": "Example", "status": "Reported", "locator": "p1"}],
                 "edges": []}';
begin
    perform research.submit_package(d || '{"title": "Alice private", "visibility": "private",
        "claims": [{"id": "C1", "kind": "Inference", "text": "zqxprivateword is only in alice private work", "source_ids": ["S1"], "locator": ""}]}',
        null, 'rp-scale-private');
    perform research.submit_package(d || '{"title": "Alice listed", "visibility": "listed",
        "claims": [{"id": "C1", "kind": "Inference", "text": "zqxlistedword is in alice listed work", "source_ids": ["S1"], "locator": ""}]}',
        null, 'rp-scale-listed');
    assert (select count(*) from research.search_claims('zqxprivateword')) = 1, 'the owner finds her own private claim';
end $$;
reset role;

-- Bob sees the listed one and never the private one, through either function.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-00000000c502"}';
set local role authenticated;
do $$
begin
    assert (select count(*) from research.search_claims('zqxprivateword')) = 0,
        'another person''s private claim is not found by search';
    assert (select count(*) from research.search_claims('zqxlistedword')) = 1,
        'a listed claim is found by anybody';
    assert not exists (select 1 from research.list_listed(null, 100) x where x->>'id' = 'rp-scale-private'),
        'another person''s private work is not in the listing';
    assert exists (select 1 from research.list_listed(null, 100) x where x->>'id' = 'rp-scale-listed'),
        'a listed work is in the listing';
    assert (select count(*) from research.list_listed(null, 1000)) <= 100,
        'a page is at most 100, whatever is asked for';
end $$;
reset role;

rollback;
\echo research/17: search and the listing return only what the caller may read, a page at a time
