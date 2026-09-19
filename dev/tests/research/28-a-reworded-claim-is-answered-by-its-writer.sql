-- A reworded claim asks whether it is the same claim (REM-483, specs/claims/graph.md §5): the writer sees each
-- rewording with both wordings; "same" confirms the claim carried forward; "new" mints a claim, keeps the old link
-- in the history and may record that the new one supersedes it; the next revision carries the answer forward; and
-- only the owner, or their agent with research:publish, may answer a revision others can read.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000483a1', 'reword-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000483b1', 'reword-stranger@example.test', 'active');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000483c1', '00000000-0000-4000-8000-0000000483a1', 'agent', 'reword-k1',
     '{packages:read-own,packages:create-private}');

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000483a1"}';
set local role authenticated;
do $$
declare
    doc jsonb := '{"schema_version": "0.1", "title": "Reword", "visibility": "private", "edges": [],
        "sources": [{"id": "S1", "title": "S", "origin": "Notes", "url": ""}]}';
    r1 uuid; r2 uuid;
begin
    r1 := (research.submit_package(doc || '{"claims": [{"id": "C1", "kind": "Inference", "text": "Medlars ripen late.", "source_ids": ["S1"]},
        {"id": "C2", "kind": "Inference", "text": "Medlars are sweet.", "source_ids": ["S1"]}]}', null, 'rp-reword')->>'revision_id')::uuid;
    r2 := (research.revise_package('rp-reword', doc || '{"claims": [{"id": "C1", "kind": "Inference", "text": "Medlars ripen late in autumn.", "source_ids": ["S1"]},
        {"id": "C2", "kind": "Inference", "text": "Medlars are sour until bletted.", "source_ids": ["S1"]}]}', 'draft-1')->>'revision_id')::uuid;
    insert into ids values ('r1', r1::text), ('r2', r2::text);
    assert (select array_agg(claim_key || ': ' || was || ' -> ' || now order by claim_key) from claims.rewordings(r2))
         = array['C1: Medlars ripen late. -> Medlars ripen late in autumn.', 'C2: Medlars are sweet. -> Medlars are sour until bletted.'],
        'the writer sees both rewordings with both wordings';
end $$;
reset role;
insert into ids select 'old_' || lower(claim_key), claim_id::text from claims.expresses where revision_id = (select v::uuid from ids where k = 'r1');

-- On a revision others can read, the agent without a publishing delegation cannot answer; a stranger cannot see
-- or answer. (On a private draft the agent may relay the person's answer: research/34, REM-622.)
insert into research.exposures (revision_id, work_id, exposed_by)
select v.id, v.work_id, '00000000-0000-4000-8000-0000000483a1' from research.revisions v
 where v.id = (select v::uuid from ids where k = 'r2');
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000483a1", "api_key_id": "00000000-0000-4000-8000-0000000483c1"}';
set local role authenticated;
do $$ begin
    perform claims.answer_rewording((select v::uuid from ids where k = 'r2'), 'C1', 'same');
    raise exception 'an agent without research:publish answered a rewording';
exception when insufficient_privilege then null;
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000483b1"}';
set local role authenticated;
do $$ begin
    assert not exists (select 1 from claims.rewordings((select v::uuid from ids where k = 'r2'))), 'a stranger sees no rewording';
    begin
        perform claims.answer_rewording((select v::uuid from ids where k = 'r2'), 'C1', 'same');
        raise exception 'a stranger answered a rewording';
    exception when no_data_found then null;
    end;
end $$;
reset role;

-- The owner answers: C1 is the same claim, C2 is a new one that supersedes the old.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000483a1"}';
set local role authenticated;
do $$
declare
    r2 uuid := (select v::uuid from ids where k = 'r2');
    same uuid; fresh uuid;
begin
    same := claims.answer_rewording(r2, 'C1', 'same');
    assert same = (select v::uuid from ids where k = 'old_c1'), 'same keeps the claim';
    assert (select array_agg(claim_key) from claims.rewordings(r2)) = '{C2}', 'and C1 no longer waits';
    fresh := claims.answer_rewording(r2, 'C2', 'new', true);
    assert fresh <> (select v::uuid from ids where k = 'old_c2'), 'new mints a claim';
    assert not exists (select 1 from claims.rewordings(r2)), 'nothing waits now';
    begin
        perform claims.answer_rewording(r2, 'C1', 'new');
        raise exception 'an answered rewording was answered again';
    exception when check_violation then null;
    end;
    insert into ids values ('new_c2', fresh::text);
end $$;
reset role;

do $$
declare
    r2 uuid := (select v::uuid from ids where k = 'r2');
    old_c2 uuid := (select v::uuid from ids where k = 'old_c2');
    new_c2 uuid := (select v::uuid from ids where k = 'new_c2');
begin
    assert (select array_agg(claim_id::text || '/' || method || '/' || status || '/' || op order by id)
              from claims.expresses where revision_id = r2 and claim_key = 'C2')
         = array[old_c2 || '/reworded/proposed/assert', old_c2 || '/reworded/proposed/retract', new_c2 || '/new/confirmed/assert'],
        'the old link stays in the history, retracted, beside the new';
    assert exists (select 1 from claims.relations where src = new_c2 and dst = old_c2 and predicate = 'supersedes' and status = 'confirmed'),
        'and the new claim supersedes the old';
end $$;

-- The next revision carries the answers forward: C2 unchanged now expresses the new claim.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000483a1"}';
set local role authenticated;
do $$
declare r3 uuid;
begin
    -- A new title, so this is a new revision: an unchanged document returns the head it already is.
    r3 := (research.revise_package('rp-reword', '{"schema_version": "0.1", "title": "Reword, third draft", "visibility": "private", "edges": [],
        "sources": [{"id": "S1", "title": "S", "origin": "Notes", "url": ""}],
        "claims": [{"id": "C1", "kind": "Inference", "text": "Medlars ripen late in autumn.", "source_ids": ["S1"]},
                   {"id": "C2", "kind": "Inference", "text": "Medlars are sour until bletted.", "source_ids": ["S1"]}]}', 'draft-2')->>'revision_id')::uuid;
    assert (select claim_id from claims.expresses where revision_id = r3 and claim_key = 'C2') = (select v::uuid from ids where k = 'new_c2'),
        'draft-3 carries the new claim forward';
    assert r3 <> (select v::uuid from ids where k = 'r2'), 'draft-3 is a revision of its own';
    assert (select claim_id from claims.expresses where revision_id = r3 and claim_key = 'C1') = (select v::uuid from ids where k = 'old_c1'),
        'and C1 the claim it always was';
end $$;

rollback;
