-- Origins (REM-477, specs/claims/graph.md §3 and §10): study_key gives the application's REM-430 key, an occurrence
-- cites the origin its source names, a source naming a study two ways joins the two by a link and rewrites neither,
-- a title shared by two different documents does not make them one study, evidence counts independent studies,
-- same_study finds another work citing the study, and a stranger sees no private citation.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

-- 1. The key, on the cases related.py's study_key handles, with the answers it gives.
do $$
declare v record;
begin
    for v in select * from (values
        ('https://doi.org/10.1016/J.Cell.2020.01.001.', 'doi:10.1016/j.cell.2020.01.001'),
        ('See 10.1038/nature12373) and more', 'doi:10.1038/nature12373'),
        ('https://www.Example.com/a/b/?x=1#y', 'url:example.com/a/b'),
        ('HTTP://WWW.EXAMPLE.ORG/', 'url:example.org'),
        ('Smith & Jones (2020): A Study!', 'title:smith jones 2020 a study'),
        ('', ''), ('  !! ', '')) t(text, want) loop
        assert claims.study_key(v.text) = v.want, format('study_key(%L) = %L, not %L', v.text, claims.study_key(v.text), v.want);
    end loop;
end $$;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000477a1', 'origins-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000477b2', 'origins-stranger@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-origins-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-origins-lister', 'research', 'list') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000477a1', 'rp-origins-lister');

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;

-- 2. Three works. A cites a paper by title and address, and its data file under the same title. B cites the paper by
--    address alone. P, private, cites the paper too.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000477a1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('a', research.submit_package('{"schema_version": "0.1", "title": "Origins A", "visibility": "listed", "edges": [],
        "claims": [{"id": "A1", "kind": "Inference", "text": "Copies inflate confidence.", "source_ids": ["S1", "S2"]}],
        "sources": [{"id": "S1", "title": "The paper", "origin": "Our quillwort manuscript", "url": "https://example.org/quillwort/paper"},
                    {"id": "S2", "title": "Its data", "origin": "Our quillwort manuscript", "url": "https://example.org/quillwort/data.json"}]}',
        null, 'rp-origins-a')->>'revision_id');
    insert into ids values ('b', research.submit_package('{"schema_version": "0.1", "title": "Origins B", "visibility": "listed", "edges": [],
        "claims": [{"id": "B1", "kind": "Inference", "text": "Confidence rises with copies.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "The paper again", "origin": "", "url": "http://www.example.org/quillwort/paper/"}]}',
        null, 'rp-origins-b')->>'revision_id');
    insert into ids values ('p', research.submit_package('{"schema_version": "0.1", "title": "Origins P", "visibility": "private", "edges": [],
        "claims": [{"id": "P1", "kind": "Inference", "text": "Privately, copies inflate confidence.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "The paper", "origin": "A private reading", "url": "https://example.org/quillwort/paper"}]}',
        null, 'rp-origins-p')->>'revision_id');
end $$;
reset role;

-- 3. What was projected, as the tables' owner.
do $$
declare
    rev_a uuid := (select v::uuid from ids where k = 'a');
    paper uuid := (select id from claims.origins where key = 'url:example.org/quillwort/paper');
    data  uuid := (select id from claims.origins where key = 'url:example.org/quillwort/data.json');
    title uuid := (select id from claims.origins where key = 'title:our quillwort manuscript');
    n bigint[];
begin
    assert paper is not null and data is not null and title is not null, 'each key mints one origin';
    assert (select count(*) from claims.cites where revision_id = rev_a) = 4, 'A1 cites each source by origin and by address';
    assert (select count(*) from claims.origin_links where evidence = rev_a) = 2
       and exists (select 1 from claims.origin_links where a = least(title, paper) and b = greatest(title, paper))
       and exists (select 1 from claims.origin_links where a = least(title, data) and b = greatest(title, data)),
        'each two-key source links its two keys';
    assert claims.study_of(paper) = paper and claims.study_of(data) = data,
        'the paper and its data stay two studies, though one title labels both';
    assert claims.study_of(title) = title, 'and the shared title bridges neither';
    assert (select count(*) from claims.origins where key like 'url:example.org/quillwort/paper%') = 1,
        'an address written with scheme, www and a trailing slash is one origin';

    n := array[(select count(*) from claims.cites), (select count(*) from claims.origin_links), (select count(*) from claims.origins)];
    n := n || (select count(*) from claims.tx);
    perform research.rebuild_projection(rev_a);
    assert claims.project_cites(rev_a) = 0, 'a second projection cites nothing';
    assert array[(select count(*) from claims.cites), (select count(*) from claims.origin_links), (select count(*) from claims.origins),
                 (select count(*) from claims.tx)] = n,
        'a rebuild adds no citation, link, origin or transaction';
    begin
        update claims.origins set label = 'x' where id = paper;
        raise exception 'an origin was rewritten';
    exception when restrict_violation then null;
    end;
end $$;

-- 4. A stranger reads the listed works.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000477b2"}';
set local role authenticated;
do $$
declare
    b uuid := (select v::uuid from ids where k = 'b');
    a1 uuid := (select claim_id from claims.expresses where revision_id = (select v::uuid from ids where k = 'a') and claim_key = 'A1');
    r record;
begin
    assert (select count(*) from claims.evidence(a1)) = 2, 'A1 rests on two independent studies, the paper and its data';
    select * into r from claims.same_study(b, 'B1');
    assert r.independent_evidence = 1 and r.keys = '{url:example.org/quillwort/paper}'
       and r.works @> '[{"package_id": "rp-origins-a", "claim_key": "A1"}]',
        'B1 finds A1 citing the same paper: ' || coalesce(r::text, 'nothing');
    assert (select count(*) from claims.same_study(b, 'B1')) = 1, 'one study, however it was named';
    assert not (select coalesce(jsonb_agg(w), '[]') from claims.same_study(b, 'B1'), jsonb_array_elements(works) w)
               @> '[{"package_id": "rp-origins-p"}]', 'and never the private work citing it';
    assert not exists (select 1 from claims.cites where revision_id = (select v::uuid from ids where k = 'p')),
        'a stranger reads no private citation';
    assert not exists (select 1 from claims.origins where key = 'title:a private reading'),
        'nor an origin only a private work cites';
end $$;

rollback;
