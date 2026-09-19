-- Consensus (REM-496, specs/claims/graph.md §12): the independent studies behind a claim's position are counted
-- from origin entities, one per study however many works repeat it; a proposal needs two; a caller cannot name a
-- study that is not behind the claim; only a resolver confirms, disputes or reopens; a confirmed contradiction from
-- a study the consensus did not count is reported as dissent, one from a counted study is not; and consensus never
-- enters a study's record.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000496a1', 'cons-a@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000496b1', 'cons-b@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000496c1', 'cons-reader@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000496d1', 'cons-resolver@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-cons-lister', 'may list research (test)'),
                                                  ('rp-cons-resolver', 'may resolve (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-cons-lister', 'research', 'list'),
                                                                  ('rp-cons-resolver', 'research', 'resolve') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000496a1', 'rp-cons-lister'),
                                                   ('00000000-0000-4000-8000-0000000496b1', 'rp-cons-lister'),
                                                   ('00000000-0000-4000-8000-0000000496d1', 'rp-cons-resolver');

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;

-- Four listed works. A1 and C1 cite one study (X), B1 another (Y), D1 a third (Z), and E1 cites X again.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000496a1"}';
set local role authenticated;
do $$
declare doc text := '{"schema_version": "0.1", "title": "%s", "visibility": "listed", "edges": [],
    "claims": [{"id": "%s", "kind": "Inference", "text": "%s", "source_ids": ["S1"]}],
    "sources": [{"id": "S1", "title": "S", "origin": "%s", "url": ""}]}';
begin
    insert into ids values
      ('wa', research.submit_package(format(doc, 'Cons A', 'A1', 'Rowan berries keep birds over winter.', 'https://doi.org/10.8888/Rowan.X')::jsonb, null, 'rp-cons-a')->>'revision_id'),
      ('wc', research.submit_package(format(doc, 'Cons C', 'C1', 'Birds winter on rowan.', '10.8888/rowan.x')::jsonb, null, 'rp-cons-c')->>'revision_id'),
      ('we', research.submit_package(format(doc, 'Cons E', 'E1', 'Rowan does not keep birds.', 'doi:10.8888/ROWAN.X')::jsonb, null, 'rp-cons-e')->>'revision_id');
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000496b1"}';
set local role authenticated;
do $$
declare doc text := '{"schema_version": "0.1", "title": "%s", "visibility": "listed", "edges": [],
    "claims": [{"id": "%s", "kind": "Inference", "text": "%s", "source_ids": ["S1"]}],
    "sources": [{"id": "S1", "title": "S", "origin": "%s", "url": ""}]}';
begin
    insert into ids values
      ('wb', research.submit_package(format(doc, 'Cons B', 'B1', 'Rowan feeds birds all winter.', 'https://doi.org/10.8888/Rowan.Y')::jsonb, null, 'rp-cons-b')->>'revision_id'),
      ('wd', research.submit_package(format(doc, 'Cons D', 'D1', 'Rowan runs out by January.', 'https://doi.org/10.8888/Rowan.Z')::jsonb, null, 'rp-cons-d')->>'revision_id');
end $$;
reset role;
insert into ids select 'c_' || lower(claim_key), claim_id::text from claims.expresses
 where revision_id in (select v::uuid from ids where k like 'w_');

-- A reader works it out.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000496c1"}';
set local role authenticated;
do $$
declare
    wa uuid := (select v::uuid from ids where k = 'wa');
    a1 uuid := (select v::uuid from ids where k = 'c_a1');
    fm jsonb := '{"frame_match": {"subject": "same", "outcome": "same", "evidence_type": "same", "population": "same",
                  "period": "same", "setting": "same", "comparator": "same"}, "src": "Rowan", "dst": "Rowan"}';
    c bigint;
begin
    begin
        perform claims.propose_consensus(a1, wa, 'holds', '2026-06-01');
        raise exception 'a consensus was proposed on one study';
    exception when check_violation then null;
    end;
    perform claims.assert_relation('A1', 'agrees', 'C1', wa, (select v::uuid from ids where k = 'wc'), null, fm);
    assert cardinality(claims.consensus_studies(a1)) = 1, 'C1 repeats A1''s study, so it adds nothing';
    perform claims.assert_relation('A1', 'agrees', 'B1', wa, (select v::uuid from ids where k = 'wb'), null, fm);
    assert cardinality(claims.consensus_studies(a1)) = 2, 'B1 cites another study: two, counted by origin';
    begin
        perform claims.record_consensus(a1, wa, 'holds', '2026-06-01',
            claims.consensus_studies(a1) || '00000000-0000-4000-8000-000000000001'::uuid);
        raise exception 'a consensus named a study that is not behind the claim';
    exception when check_violation then null;
    end;
    c := claims.propose_consensus(a1, wa, 'holds', '2026-06-01');
    assert (select status || '/' || cardinality(studies) from claims.consensus where id = c) = 'proposed/2', 'proposed, two studies';
    begin
        perform claims.review_consensus(c, 'confirmed');
        raise exception 'a reader confirmed a consensus';
    exception when insufficient_privilege then null;
    end;
    insert into ids values ('c', c::text);
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000496d1"}';
set local role authenticated;
select claims.review_consensus((select v::bigint from ids where k = 'c'), 'confirmed', 'two independent trials');
reset role;

-- After it is confirmed, a contradiction from a counted study is not dissent; one from a new study is.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000496c1"}';
set local role authenticated;
do $$
declare
    a1 uuid := (select v::uuid from ids where k = 'c_a1');
    fm jsonb := '{"frame_match": {"subject": "same", "outcome": "same", "evidence_type": "same", "population": "same",
                  "period": "same", "setting": "same", "comparator": "same"}, "src": "Rowan", "dst": "Rowan"}';
    s record;
begin
    select * into s from claims.consensus_of(a1);
    assert s.status = 'confirmed' and s.studies = 2 and s.dissent is null, 'confirmed, with no dissent: ' || s::text;
    perform claims.assert_relation('E1', 'contradicts', 'A1', (select v::uuid from ids where k = 'we'), (select v::uuid from ids where k = 'wa'), null, fm);
    select * into s from claims.consensus_of(a1);
    assert s.dissent is null, 'a contradiction from a study the consensus counted is not dissent';
    perform claims.assert_relation('D1', 'contradicts', 'A1', (select v::uuid from ids where k = 'wd'), (select v::uuid from ids where k = 'wa'), null, fm);
    select * into s from claims.consensus_of(a1);
    assert cardinality(s.dissent) = 1, 'a contradiction from a new study is dissent: ' || s::text;
    assert not exists (select 1 from claims.origin_record((select id from claims.origins where key = 'doi:10.8888/rowan.x'))),
        'consensus never enters a study''s record';
end $$;
reset role;

-- The resolver reopens it, and the history keeps every state.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000496d1"}';
set local role authenticated;
do $$
declare a1 uuid := (select v::uuid from ids where k = 'c_a1');
begin
    perform claims.review_consensus((select v::bigint from ids where k = 'c'), 'reopened', 'a third study disagrees');
    assert (select status from claims.consensus_of(a1)) = 'reopened', 'reopened';
    assert (select array_agg(status order by id) from claims.consensus where claim_id = a1) = '{proposed,confirmed,reopened}',
        'and every state is kept';
end $$;

rollback;
