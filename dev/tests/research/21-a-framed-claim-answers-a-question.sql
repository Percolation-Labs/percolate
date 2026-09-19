-- Frames and questions (REM-476, specs/claims/graph.md §7): a frame survives projection, two frames whose subject
-- and outcome normalise to the same words answer one question, a narrower slot answers a question that refines it,
-- claims.answers groups readable claims by stance across the refinements, frame coverage is a number, a rebuild
-- writes nothing, and a question only a private work answers is not observable.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000476a1', 'questions-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000476b2', 'questions-stranger@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-questions-lister', 'may list research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('rp-questions-lister', 'research', 'list') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000476a1', 'rp-questions-lister');

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000476a1"}';
set local role authenticated;
do $$
declare base jsonb := '{"schema_version": "0.1", "edges": [],
        "sources": [{"id": "S1", "title": "A trial", "url": "https://example.com/t", "origin": "Trial"}]}';
begin
    insert into ids values ('x', research.submit_package(base || '{"title": "Framed listed", "visibility": "listed",
        "claims": [{"id": "C1", "kind": "Inference", "text": "The tools made developers faster.", "source_ids": ["S1"],
                    "frame": {"subject": "AI coding tools", "outcome": "Developer speed", "direction": "faster"}},
                   {"id": "C2", "kind": "Inference", "text": "Seniors were slower with them.", "source_ids": ["S1"],
                    "frame": {"subject": "ai  coding tools", "outcome": "developer speed", "population": "Senior developers", "direction": "slower"}},
                   {"id": "C3", "kind": "Inference", "text": "Nobody measured quality.", "source_ids": ["S1"]},
                   {"id": "C4", "kind": "Inference", "text": "The trial ran for a month.", "source_ids": ["S1"],
                    "frame": {"subject": "AI coding tools"}}]}', null, 'rp-q-x')->>'revision_id');
    insert into ids values ('z', research.submit_package(base || '{"title": "Framed second", "visibility": "listed",
        "claims": [{"id": "Z1", "kind": "Inference", "text": "Speed rose in the second study.", "source_ids": ["S1"],
                    "frame": {"subject": "AI Coding Tools", "outcome": "Developer Speed"}}]}', null, 'rp-q-z')->>'revision_id');
    insert into ids values ('p', research.submit_package(base || '{"title": "Framed private", "visibility": "private",
        "claims": [{"id": "P1", "kind": "Inference", "text": "Output held at home.", "source_ids": ["S1"],
                    "frame": {"subject": "Remote work", "outcome": "Zelkova output"}}]}', null, 'rp-q-private')->>'revision_id');
end $$;
reset role;

-- What was projected, read as the tables' owner.
do $$
declare
    x uuid := (select v::uuid from ids where k = 'x');
    z uuid := (select v::uuid from ids where k = 'z');
    q uuid; q2 uuid; n bigint[];
begin
    assert (select array_agg(claim_key order by claim_key) from claims.frames where revision_id = x) = '{C1,C2,C4}',
        'each framed occurrence keeps its frame, and an unframed one has none';
    assert (select direction from claims.frames where revision_id = x and claim_key = 'C2') = 'slower', 'with its slots';
    select question_id into q from claims.answered where evidence = x and claim_key = 'C1';
    select question_id into q2 from claims.answered where evidence = x and claim_key = 'C2';
    assert (select question_id from claims.answered where evidence = z and claim_key = 'Z1') = q,
        'two frames that normalise to the same subject and outcome answer one question';
    assert q2 <> q and (select refines from claims.questions where id = q2) = q,
        'a narrower slot answers a question that refines the broader one';
    assert (select refinements from claims.questions where id = q2) = '{"population": "senior developers"}',
        'and the refinement is the normalised slot: ' || (select refinements::text from claims.questions where id = q2);
    assert not exists (select 1 from claims.answered where evidence = x and claim_key in ('C3', 'C4')),
        'a claim without both subject and outcome answers nothing';
    assert (select bool_and(stance = 'unknown' and status = 'confirmed') from claims.answered where evidence in (x, z)),
        'the platform asserts the question, confirmed, and leaves the stance unknown';
    insert into ids values ('q', q::text);

    n := array[(select count(*) from claims.frames), (select count(*) from claims.questions), (select count(*) from claims.answered)];
    perform research.rebuild_projection(x);
    assert claims.project_frames(x) = 0
       and array[(select count(*) from claims.frames), (select count(*) from claims.questions), (select count(*) from claims.answered)] = n,
        'a rebuild writes no frame, question or answer';
    begin
        update claims.questions set subject = 'x' where id = q;
        raise exception 'a question was rewritten';
    exception when restrict_violation then null;
    end;
end $$;

-- A stranger reads the listed works through the functions.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000476b2"}';
set local role authenticated;
do $$
declare
    q uuid := (select v::uuid from ids where k = 'q');
    a record;
    c record;
begin
    select * into a from claims.answers(q);
    assert a.stance = 'unknown' and jsonb_array_length(a.claims) = 3,
        'the question groups C1, Z1 and the refining C2 by stance: ' || coalesce(a.claims::text, 'nothing');
    assert (select count(*) from claims.answers(q)) = 1, 'one stance so far';
    select * into c from claims.frame_coverage('rp-q-x');
    assert (c.claims, c.framed, c.answering) = (4, 3, 2), 'frame coverage is a number: ' || c::text;
    assert not exists (select 1 from claims.frame_coverage('rp-q-private')), 'and says nothing about a private work';
    assert claims.claim((select claim_id from claims.expresses where revision_id = (select v::uuid from ids where k = 'x') and claim_key = 'C1'))
           ->'questions' @> to_jsonb(array[q]), 'a claim names the questions it answers';
    assert not exists (select 1 from claims.questions where subject = 'Remote work'),
        'a question only a private work answers is not observable';
    assert not exists (select 1 from claims.frames where revision_id = (select v::uuid from ids where k = 'p')),
        'nor is a private frame';
end $$;

rollback;
