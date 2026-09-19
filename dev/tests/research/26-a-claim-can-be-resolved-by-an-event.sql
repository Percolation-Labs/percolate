-- Event resolutions (REM-480, specs/claims/graph.md §12): any reader of a claim proposes one; only a person holding
-- research:resolve confirms or disputes it, and the proposal stays; a resolution is readable with its evidence;
-- confirmed resolutions are tallied per study and nothing scores them; and erasing the work takes them with it.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000480a1', 'resolve-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000480b1', 'resolve-reader@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000480c1', 'resolve-resolver@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-resolve-lister', 'may list research (test)'),
                                                  ('rp-resolver', 'may resolve claims (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-resolve-lister', 'research', 'list'),
                                                                  ('rp-resolver', 'research', 'resolve') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000480a1', 'rp-resolve-lister'),
                                                   ('00000000-0000-4000-8000-0000000480c1', 'rp-resolver');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000480d1', '00000000-0000-4000-8000-0000000480c1', 'agent', 'resolve-k1',
     '{packages:read-own,packages:create-private}');

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000480a1"}';
set local role authenticated;
do $$ begin
    insert into ids values ('w', research.submit_package('{"schema_version": "0.1", "title": "Resolve W", "visibility": "listed", "edges": [],
        "claims": [{"id": "C1", "kind": "Inference", "text": "The quince trial will replicate.", "source_ids": ["S1"]},
                   {"id": "C2", "kind": "Inference", "text": "The effect is large.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "Trial", "origin": "https://doi.org/10.7777/Quince.1", "url": ""}]}', null, 'rp-resolve-w')->>'revision_id');
    insert into ids values ('p', research.submit_package('{"schema_version": "0.1", "title": "Resolve P", "visibility": "private", "edges": [],
        "claims": [{"id": "P1", "kind": "Inference", "text": "Private.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "origin": "Notes", "url": ""}]}', null, 'rp-resolve-p')->>'revision_id');
end $$;
reset role;
insert into ids select 'c' || lower(claim_key), claim_id::text from claims.expresses
 where revision_id in ((select v::uuid from ids where k = 'w'), (select v::uuid from ids where k = 'p'));

-- 1. A reader proposes; what they cannot read, and a value outside the four, are refused.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000480b1"}';
set local role authenticated;
do $$
declare w uuid := (select v::uuid from ids where k = 'w');
begin
    insert into ids values ('r1', claims.propose_resolution((select v::uuid from ids where k = 'cc1'), w, 'held',
        'The replication was published', 'https://doi.org/10.7777/Quince.2', '2026-09-01', 'read the replication''s results table'));
    insert into ids values ('r2', claims.propose_resolution((select v::uuid from ids where k = 'cc2'), w, 'failed',
        'The pooled estimate was small', 'https://doi.org/10.7777/Quince.3', '2026-09-02', 'read the meta-analysis'));
    begin
        perform claims.propose_resolution((select v::uuid from ids where k = 'cp1'), (select v::uuid from ids where k = 'p'), 'held',
            'x', 'y', '2026-09-01', 'z');
        raise exception 'a reader resolved a claim they cannot read';
    exception when no_data_found then null;
    end;
    begin
        perform claims.propose_resolution((select v::uuid from ids where k = 'cc1'), w, 'true', 'x', 'y', '2026-09-01', 'z');
        raise exception 'a resolution outside the four values was accepted';
    exception when check_violation then null;
    end;
    begin
        perform claims.review_resolution((select v::bigint from ids where k = 'r1'), 'confirmed');
        raise exception 'a reader without research:resolve confirmed a resolution';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;

-- 2. The resolver's agent is refused; the resolver confirms one and disputes the other.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000480c1", "api_key_id": "00000000-0000-4000-8000-0000000480d1"}';
set local role authenticated;
do $$ begin
    perform claims.review_resolution((select v::bigint from ids where k = 'r1'), 'confirmed');
    raise exception 'an agent confirmed a resolution';
exception when insufficient_privilege then null;
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000480c1"}';
set local role authenticated;
do $$ begin
    perform claims.review_resolution((select v::bigint from ids where k = 'r1'), 'confirmed', 'the replication holds up');
    perform claims.review_resolution((select v::bigint from ids where k = 'r2'), 'disputed', 'the meta-analysis mixes populations');
end $$;
reset role;

-- 3. Anybody who can read the claim sees where each stands; the study's record counts only the confirmed one.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000480b1"}';
set local role authenticated;
do $$
declare
    origin uuid := (select id from claims.origins where key = 'doi:10.7777/quince.1');
begin
    assert (select status from claims.resolutions_of((select v::uuid from ids where k = 'cc1'))) = 'confirmed', 'C1 is resolved, confirmed';
    assert (select status from claims.resolutions_of((select v::uuid from ids where k = 'cc2'))) = 'disputed', 'C2''s is disputed';
    assert (select count(*) from claims.resolutions where claim_id = (select v::uuid from ids where k = 'cc1')) = 2,
        'the proposal stays beside its confirmation';
    assert (select array_agg(value || ':' || claims) from claims.origin_record(origin)) = '{held:1}',
        'the study''s record counts one confirmed held, and nothing else: ' ||
        coalesce((select array_agg(value || ':' || claims) from claims.origin_record(origin))::text, 'nothing');
    begin
        update claims.resolutions set value = 'failed' where id = (select v::bigint from ids where k = 'r1');
        raise exception 'a resolution was rewritten';
    exception when insufficient_privilege or restrict_violation then null;
    end;
end $$;
reset role;

-- 4. Erasing the work takes its resolutions, and the tombstone counts them.
do $$
declare t jsonb;
begin
    t := research.erase_work('rp-resolve-w', 'REM-480 test')->'claims_graph';
    assert (t->>'resolutions')::int = 4, 'the tombstone counts two proposals and two reviews: ' || t::text;
    assert not exists (select 1 from claims.resolutions where evidence = (select v::uuid from ids where k = 'w')), 'and they are gone';
end $$;

rollback;
