-- A research programme's protocols, runs and decisions are data (REM-594, core-research-programme.md §R1). A no-model
-- round trip: draft, freeze, run, a failed and a stopped run, an amendment and its own run, evaluation and a person's
-- review. A retry is the same run, a duplicate result is the same result, and a different one is refused. An agent's
-- credential cannot decide. Another person sees nothing and can do nothing. An erased cited revision leaves the export
-- complete and marks it unavailable.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000594a1', 'programme-owner@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000594b1', 'programme-stranger@example.test', 'active');
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000594c1', '00000000-0000-4000-8000-0000000594a1', 'agent', 'programme-k1',
     '{packages:read-own,packages:create-private}');

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated;

-- 1. The owner: a programme, a protocol written in one of their revisions, frozen, and runs.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000594a1"}';
set local role authenticated;
do $$
declare
    doc jsonb := '{"schema_version": "0.1", "title": "Protocol", "visibility": "private", "edges": [],
        "sources": [{"id": "S1", "title": "S", "origin": "Notes", "url": ""}],
        "claims": [{"id": "C1", "kind": "Inference", "text": "Quinces need frost.", "source_ids": ["S1"]}]}';
    rev uuid; corpus uuid; g uuid; p1 uuid; p2 uuid; a uuid; b uuid; c uuid; d uuid; h text; st text;
begin
    rev := (research.submit_package(doc, null, 'rp-programme-protocol')->>'revision_id')::uuid;
    corpus := (research.submit_package(doc || '{"title": "Corpus"}', null, 'rp-programme-corpus')->>'revision_id')::uuid;
    g := research.programme_create('Do quinces need frost?', 'measure the claim against a fixed corpus',
                                   '{"sources": ["the corpus"], "spend": 0, "stop": "any failure"}');
    p1 := research.protocol_draft(g, '{"hypothesis": "frost", "metric": "agreement"}', rev, array[corpus]);
    insert into ids values ('g', g), ('p1', p1), ('rev', rev), ('corpus', corpus);
    assert research.protocol_state(p1) = 'draft', 'a protocol starts as a draft';

    begin
        perform research.run_start(p1, 'k1', '{"seed": 1}');
        assert false, 'a run on a draft is refused';
    exception when object_not_in_prerequisite_state then null;
    end;

    h := research.protocol_freeze(p1);
    assert h = (select manifest_hash from research.protocols where id = p1) and length(h) = 64, 'freezing answers the hash';
    assert research.protocol_freeze(p1) = h, 'freezing again is the same freeze';
    assert research.protocol_state(p1) = 'frozen';

    a := research.run_start(p1, 'k1', '{"seed": 1}');
    assert research.run_start(p1, 'k1', '{"seed": 1}') = a, 'a retry is the same run';
    begin
        perform research.run_start(p1, 'k1', '{"seed": 2}');
        assert false, 'the same key with other inputs is refused';
    exception when unique_violation then null;
    end;
    assert research.run_state(a) = 'running';

    assert research.run_finish(a, 'completed', '{"agreement": 0.8}', '[]', '{"seconds": 3}') = 'completed';
    assert research.run_finish(a, 'completed', '{"agreement": 0.8}', '[]', '{"seconds": 3}') = 'completed',
        'the same result again is the same result';
    begin
        perform research.run_finish(a, 'completed', '{"agreement": 0.9}', '[]', '{"seconds": 3}');
        assert false, 'a scored result is not rewritten';
    exception when restrict_violation then null;
    end;

    b := research.run_start(p1, 'k2', '{"seed": 2}');
    perform research.run_finish(b, 'failed', '{}', '[{"step": "fetch", "error": "timeout"}]', '{"seconds": 1}');
    c := research.run_start(p1, 'k3', '{"seed": 3}');
    perform research.run_finish(c, 'stopped', '{"agreement": 0.5, "partial": true}', '[]', '{"seconds": 2}');
    assert research.run_state(b) = 'failed' and research.run_state(c) = 'stopped', 'failure and stop are states';
    assert (select outputs->>'partial' from research.run_results where run_id = c) = 'true', 'a stop keeps partial results';

    -- An amendment is a new protocol and a new run; the first protocol and its result are untouched.
    p2 := research.protocol_draft(g, '{"hypothesis": "frost", "metric": "agreement", "exclusions": ["greenhouse"]}',
                                  rev, array[corpus], p1);
    perform research.protocol_freeze(p2);
    d := research.run_start(p2, 'k1', '{"seed": 1}');
    assert d <> a, 'the same key under the amendment is a new run';
    perform research.run_finish(d, 'completed', '{"agreement": 0.7}');

    perform research.run_evaluate(a, 'fixture oracle', 'exact match', '[{"item": 1, "correct": true}]');
    begin
        perform research.run_evaluate(research.run_start(p2, 'k9', '{}'), 'fixture oracle', 'exact match');
        assert false, 'a run without a result is not evaluated';
    exception when object_not_in_prerequisite_state then null;
    end;
    perform research.run_review(a, 'supported', '{"result": "agreement 0.8"}', 'rerun on the amended corpus',
                                'a new corpus revision');
    assert research.run_state(a) = 'reviewed', 'a decision makes the run reviewed';
    insert into ids values ('a', a), ('p2', p2);

    -- Nothing here is rewritten by the owner either.
    begin
        update research.protocols set manifest = '{}' where id = p1;
        assert false, 'the owner cannot update a protocol';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;

-- The history trigger holds even for the table owner.
do $$ begin
    update research.protocols set manifest = '{}' where id = (select v::uuid from ids where k = 'p1');
    assert false, 'a frozen protocol cannot be rewritten';
exception when restrict_violation then null;
end $$;

-- 2. The owner's agent can run the programme but not decide it.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000594a1", "api_key_id": "00000000-0000-4000-8000-0000000594c1"}';
set local role authenticated;
do $$ begin
    perform research.run_review((select v::uuid from ids where k = 'a'), 'rejected');
    assert false, 'an agent credential cannot decide';
exception when insufficient_privilege then null;
end $$;
reset role;

-- 3. Another person sees nothing and can do nothing.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000594b1"}';
set local role authenticated;
do $$
declare g uuid := (select v::uuid from ids where k = 'g'); p1 uuid := (select v::uuid from ids where k = 'p1');
begin
    assert (select count(*) from research.programmes) = 0 and (select count(*) from research.protocols) = 0
       and (select count(*) from research.programme_runs) = 0 and (select count(*) from research.run_results) = 0,
        'a stranger reads no programme row';
    assert research.programme_export(g) is null, 'nor its export';
    begin
        perform research.run_start(p1, 'k1', '{"seed": 1}');
        assert false, 'a stranger cannot start a run';
    exception when no_data_found then null;
    end;
    begin
        perform research.protocol_draft(g, '{}');
        assert false, 'nor draft a protocol';
    exception when no_data_found then null;
    end;
    begin
        perform research.protocol_draft(research.programme_create('Mine'), '{}',
                                        (select v::uuid from ids where k = 'rev'));
        assert false, 'nor cite a revision they cannot read';
    exception when no_data_found then null;
    end;
end $$;
reset role;

-- 4. The owner's export is complete; once a cited revision is erased it is unavailable, and the rest stands.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000594a1"}';
set local role authenticated;
do $$
declare x jsonb := research.programme_export((select v::uuid from ids where k = 'g'));
begin
    -- The run started inside the refused evaluation was rolled back with it, so four runs.
    assert jsonb_array_length(x->'protocols') = 2 and jsonb_array_length(x->'runs') = 4, 'two protocols, four runs';
    assert (select array_agg(r->>'protocol' || '/' || (r->>'key') || ': ' || (r->>'state') order by r->>'protocol', r->>'key')
              from jsonb_array_elements(x->'runs') r)
         = array['1/k1: reviewed', '1/k2: failed', '1/k3: stopped', '2/k1: completed'], 'every run and its state';
    assert x->'protocols'->1->>'amends' = '1', 'the amendment names the protocol it amends';
    assert x->'protocols'->0->'document'->>'work' = 'rp-programme-protocol', 'the protocol document, as its work and label';
    assert (select r->'decisions'->0->>'verdict' from jsonb_array_elements(x->'runs') r where r->>'id' = (select v from ids where k = 'a'))
         = 'supported', 'the decision is in the export';
end $$;
reset role;

select research.erase_work('rp-programme-protocol', 'REM-594 test: the protocol document is erased');

set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000594a1"}';
set local role authenticated;
do $$
declare x jsonb := research.programme_export((select v::uuid from ids where k = 'g'));
begin
    assert (x->'protocols'->0->'document'->>'unavailable')::boolean, 'an erased document is unavailable';
    assert x->'protocols'->0->'document'->>'label' is null, 'and nothing of it is shown';
    assert x->'protocols'->0->'corpus'->0->>'work' = 'rp-programme-corpus', 'the corpus still reads';
    assert x->'protocols'->0->'manifest'->>'hypothesis' = 'frost', 'the manifest stands';
    assert jsonb_array_length(x->'runs') = 4, 'and every run with it';
end $$;
reset role;

rollback;
\echo research/29: a programme keeps its protocols, runs and decisions, owner-only, and never rewrites a result
