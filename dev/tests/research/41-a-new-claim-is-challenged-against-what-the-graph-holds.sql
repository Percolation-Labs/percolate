-- A new claim is challenged against what the graph already holds (REM-659, specs/claims/graph.md §5 *Did you
-- mean*). When a claim's vector lands, aiq.record_embeddings calls the claims source's on_embedded, and
-- claims.challenge_embedded puts the claim to its WRITER, as that writer, against the claims nearest it that they
-- may read. Their own agent answers through the judgement queue, and the answer is claims.assert_relation as the
-- agent, so it lands proposed. Nothing here calls a model.
--
-- The checks:
--   1. A saves, B saves a near-duplicate, and one embed run -- A's, because A saved first -- embeds both. B's claim
--      is challenged for B, with A's listed claim as its candidate and NOT A's private one, which A's run could
--      read and B cannot. A's private claim is challenged for A. A claim with nothing within the floor is not
--      challenged, and is recorded as asked. A pair is asked once, not of both sides.
--   2. Each writer sees only their own challenge; a stranger sees none.
--   3. B's agent claims it and decides same_as: the relation lands proposed, from B's claim to A's, recorded as
--      the agent's; the judgement holds its id. A relate to a claim that is not a candidate is refused, and so is a
--      verdict written onto the row with no relation asserted.
--   4. B saves the next revision with the claim unchanged: it is re-embedded and not challenged again.
--   5. With no floor for the model nothing is challenged and nothing is recorded as asked; setting the floor and
--      claims.challenge_waiting() asks it.
--   6. agrees between two claims neither of which states a period is decidable as `unstated`; `unknown` is still
--      refused, with a hint naming unstated; contradicts does not accept unstated; and unstated is refused when a
--      claim's frame states the slot.
--
-- THE WORKER IS PLAYED HERE as research/40 plays it: claim_task, texts_to_embed, record_embeddings, complete_task,
-- with a stub model whose three numbers are read off the text (memory, time, lensing). One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

insert into rbac.users (id, email, status) values
    ('00000000-0000-4000-8000-0000000659a1', 'chal-a@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000659b1', 'chal-b@example.test', 'active'),
    ('00000000-0000-4000-8000-0000000659c1', 'chal-c@example.test', 'active');
insert into rbac.roles (name, description) values ('rp-chal-lister', 'may list and read research (test)') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values
    ('rp-chal-lister', 'research', 'list'), ('rp-chal-lister', 'research', 'select') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000659a1', 'rp-chal-lister'),
                                                   ('00000000-0000-4000-8000-0000000659b1', 'rp-chal-lister'),
                                                   ('00000000-0000-4000-8000-0000000659c1', 'rp-chal-lister');
-- Each writer's connected agent: a key, so rbac.current_actor() is 'agent'.
insert into rbac.api_keys (id, user_id, label, key_hash, scopes) values
    ('00000000-0000-4000-8000-0000000659d1', '00000000-0000-4000-8000-0000000659a1', 'agent', 'chal-ka',
     '{packages:read-own,packages:create-private}'),
    ('00000000-0000-4000-8000-0000000659d2', '00000000-0000-4000-8000-0000000659b1', 'agent', 'chal-kb',
     '{packages:read-own,packages:create-private}');

update aiq.embedding_models set is_default = false where is_default;
set local role app_owner;
insert into aiq.embedding_models (name, dim, provider, endpoint, is_default, notes)
values ('chal-test-3d', 4, 'fastembed', 'stub/chal-test-3d', true, 'four dimensions, every vector a stub below');
select aiq.register_embedding_space('chal-test-3d');
reset role;
select aiq.install_source_embed_workflow(array['claims'], 'embed_sources', 't_chal_659');
-- The deployment's floor for this model. On the stub's scale B1 and A1 are 0 apart and an unrelated claim is 0.18
-- or more from everything outside its own work, so 0.05 separates them.
select claims.set_challenge_floor('chal-test-3d', 0.05, 3);

create temporary table ids (k text primary key, v text) on commit drop;
grant all on ids to authenticated, worker;
create temporary table sp (k text primary key, v jsonb) on commit drop;
grant all on sp to authenticated;
insert into sp values ('same', '{"src": "A memory store must keep the time a fact held", "dst": "Agent memory has to record when each fact became true",
    "slots": {"src": {"subject": "agent memory", "predicate": "records", "object": "when a fact held", "scope": "agents", "polarity": "positive", "modality": "normative"},
              "dst": {"subject": "agent memory", "predicate": "records", "object": "when a fact held", "scope": "agents", "polarity": "positive", "modality": "normative"}}}');

create function pg_temp.stub_vector(p_text text) returns jsonb language sql immutable as $$
    select jsonb_build_array((p_text ~* 'memor')::int + 0.01, (p_text ~* 'time|when')::int + 0.01,
                             (p_text ~* 'lens|matter')::int + 0.01, (p_text ~* 'index')::int + 0.01);
$$;
-- The worker: every task on the queue, every row the space lacks, in one page each time.
create function pg_temp.drain(p_queue text) returns int language plpgsql as $$
declare
    t      workflow.tasks;
    v_rows jsonb;
    v_tot  int := 0;
begin
    loop
        select * into t from workflow.claim_task(p_queue, 'chal-stub-worker');
        exit when t.id is null;
        loop
            v_rows := aiq.texts_to_embed(t.input->>'source', 'chal-test-3d', 500);
            exit when jsonb_array_length(v_rows) = 0;
            v_tot := v_tot + aiq.record_embeddings('chal-test-3d',
                       (select jsonb_agg(jsonb_build_object('chunk_id', r->>'chunk_id',
                                                            'embedding', pg_temp.stub_vector(r->>'content')))
                          from jsonb_array_elements(v_rows) r));
        end loop;
        perform workflow.complete_task(t.id, jsonb_build_object('result', jsonb_build_object('embedded', v_tot)),
                                       'chal-stub-worker');
    end loop;
    return v_tot;
end;
$$;
grant execute on function pg_temp.drain(text), pg_temp.stub_vector(text) to worker;

-- A saves a listed package and a private one; B saves a listed package with a near-duplicate of A1 and a claim
-- nothing is near. Nothing is embedded yet, so one run covers all three saves, and it is A's.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('ra', research.submit_package('{"schema_version": "0.1", "title": "Chal A", "visibility": "listed", "edges": [],
        "claims": [{"id": "A1", "kind": "Inference", "text": "Agent memory has to record when each fact became true.", "source_ids": ["S1"]},
                   {"id": "A2", "kind": "Inference", "text": "Gravitational lensing traces total matter.", "source_ids": ["S1"]},
                   {"id": "A3", "kind": "Inference", "text": "Retrieval augmented agents answer better with a temporal index.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/ca", "origin": "CA"}]}', null, 'rp-chal-a')->>'revision_id');
    insert into ids values ('rp', research.submit_package('{"schema_version": "0.1", "title": "Chal A private", "visibility": "private", "edges": [],
        "claims": [{"id": "P1", "kind": "Inference", "text": "Memory must keep when each fact held, privately noted.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/cp", "origin": "CP"}]}', null, 'rp-chal-p')->>'revision_id');
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659b1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('rb', research.submit_package('{"schema_version": "0.1", "title": "Chal B", "visibility": "listed", "edges": [],
        "claims": [{"id": "B1", "kind": "Inference", "text": "A memory store must keep the time a fact held.", "source_ids": ["S1"]},
                   {"id": "B2", "kind": "Inference", "text": "Soil bacteria fix nitrogen.", "source_ids": ["S1"]},
                   {"id": "B3", "kind": "Inference", "text": "Agents given dated records retrieve better.", "source_ids": ["S1"],
                    "frame": {"subject": "dated records", "outcome": "retrieval quality", "period": "2019-2021"}},
                   {"id": "B4", "kind": "Inference", "text": "Agents retrieve better given dated records.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/cb", "origin": "CB"}]}', null, 'rp-chal-b')->>'revision_id');
end $$;
reset role;
reset request.jwt.claims;
insert into ids select 'a1', claim_id::text from claims.expresses where revision_id = (select v::uuid from ids where k = 'ra') and claim_key = 'A1';
insert into ids select 'p1', claim_id::text from claims.expresses where revision_id = (select v::uuid from ids where k = 'rp') and claim_key = 'P1';
insert into ids select 'b1', claim_id::text from claims.expresses where revision_id = (select v::uuid from ids where k = 'rb') and claim_key = 'B1';

do $$
declare
    v_def uuid := (workflow.current_definition('embed_sources')).id;
begin
    assert (select count(*) from workflow.runs where workflow_def_id = v_def) = 1, 'three saves, one run';
    assert (select owner_id from workflow.runs where workflow_def_id = v_def)
           = '00000000-0000-4000-8000-0000000659a1', 'and it is A''s, who saved first';
    assert not exists (select 1 from aiq.judgements where kind = 'challenge'), 'a save challenges nothing: no vector yet';
end $$;

set local role worker;
insert into ids select 'drain1', pg_temp.drain('t_chal_659');
reset role;

-- 1. What the drain asked, and of whom.
do $$
declare
    v_b  aiq.judgements;
    v_p  aiq.judgements;
    v_n  int;
begin
    assert (select v from ids where k = 'drain1') = '8', 'the drain embedded eight claims';
    select * into v_b from aiq.judgements where kind = 'challenge' and subject_node_id = (select v::uuid from ids where k = 'b1');
    assert v_b.id is not null, 'B1 was challenged';
    assert v_b.addressee = '00000000-0000-4000-8000-0000000659b1', 'B1''s challenge is put to B';
    assert v_b.status = 'open', 'and waits';
    assert (select array_agg(c->>'claim_key' order by c->>'claim_key') from jsonb_array_elements(v_b.evidence->'candidates') c)
           = array['A1'],
        'B1''s candidates are what B may read -- A1, and not A''s private P1, which the run''s owner could read: '
        || (v_b.evidence->'candidates')::text;
    select * into v_p from aiq.judgements where kind = 'challenge' and subject_node_id = (select v::uuid from ids where k = 'p1');
    assert v_p.addressee = '00000000-0000-4000-8000-0000000659a1', 'A''s private claim is put to A';
    assert (select array_agg(c->>'claim_key' order by c->>'claim_key') from jsonb_array_elements(v_p.evidence->'candidates') c)
           = array['A1', 'B1'],
        'against A1, A''s own other work, and B1, which A may read: ' || coalesce((v_p.evidence->'candidates')::text, 'none');
    assert not exists (select 1 from aiq.judgements where kind = 'challenge' and subject_node_id = (select v::uuid from ids where k = 'a1')),
        'A1 is not challenged: its pair with B1 was put to B and its pair with P1 to A, each once';
    select count(*) into v_n from aiq.judgements where kind = 'challenge';
    assert v_n = 2, 'two challenges and no more: ' || v_n;
    assert exists (select 1 from claims.challenged d join research.claims rc on rc.id = d.claim_row
                    where rc.claim_key = 'B2' and d.model = 'chal-test-3d' and d.candidates = 0 and d.judgement_id is null),
        'B2, with nothing within the floor, is recorded as asked and not challenged';
    assert (select count(*) from claims.challenged where model = 'chal-test-3d') = 8, 'every embedded claim was asked';
end $$;

-- 2. Each writer sees their own; a stranger sees none.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659b1", "api_key_id": "00000000-0000-4000-8000-0000000659d2"}';
set local role authenticated;
do $$
declare
    v_l jsonb := aiq.list_judgements('open', 50);
begin
    assert jsonb_array_length(v_l) = 1, 'B sees one judgement: ' || v_l::text;
    assert v_l->0->>'kind' = 'challenge' and v_l->0->'candidate_claims'->0->>'claim_key' = 'A1',
        'B''s is the challenge to B1, listing A1: ' || v_l::text;
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1"}';
set local role authenticated;
do $$
begin
    assert (select array_agg(j->>'label') from jsonb_array_elements(aiq.list_judgements('open', 50)) j)
           = array['Memory must keep when each fact held, privately noted.'], 'A sees only her own';
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659c1"}';
set local role authenticated;
do $$
begin
    assert jsonb_array_length(aiq.list_judgements('open', 50)) = 0, 'a stranger sees no challenge';
    assert (aiq.claim_judgement(array['challenge']))->>'empty' = 'true', 'and can claim none';
end $$;
reset role;

-- 3. B's agent claims the challenge and decides same_as.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659b1", "api_key_id": "00000000-0000-4000-8000-0000000659d2"}';
set local role authenticated;
do $$
declare
    v_c   jsonb := aiq.claim_judgement(array['challenge']);
    v_id  uuid := (v_c->>'id')::uuid;
    v_a1  text := (select v from ids where k = 'a1');
    v_out jsonb;
    r     claims.relations;
begin
    assert v_c->>'kind' = 'challenge' and v_c->>'status' = 'claimed', 'B''s agent holds it: ' || v_c::text;
    assert v_c->>'how_to_decide' like '%same_as%' and v_c->>'how_to_decide' like '%' || v_a1 || '%',
        'how_to_decide names the relations and the candidate: ' || (v_c->>'how_to_decide');
    -- Not a candidate: A's private claim, which B cannot read.
    begin
        perform aiq.complete_judgement(v_id, jsonb_build_object('decision', 'relate', 'target', (select v from ids where k = 'p1'),
                                       'predicate', 'same_as', 'spans', (select v from sp where k = 'same')), 'they say the same');
        raise exception 'a relate to a claim that is not a candidate was accepted';
    exception when raise_exception then
        if sqlerrm not like '%not one you can read%' then raise; end if;
    end;
    -- A verdict written onto the row, naming a relation nobody asserted.
    begin
        update aiq.judgements set status = 'decided', reason = 'forged', tier = 'agent',
               verdict = jsonb_build_object('decision', 'relate', 'relations', jsonb_build_array(
                   jsonb_build_object('target', v_a1, 'predicate', 'same_as', 'relation_id', 1)))
         where id = v_id;
        raise exception 'a verdict naming no asserted relation was accepted';
    exception when raise_exception then
        if sqlerrm not like '%relations asserted to them%' then raise; end if;
    end;
    -- `bind` is the graph's decision, not a challenge's.
    begin
        perform aiq.complete_judgement(v_id, '{"decision": "bind", "target": "x"}', 'wrong kind');
        raise exception 'a bind on a challenge was accepted';
    exception when raise_exception then
        if sqlerrm not like '%relate or none%' then raise; end if;
    end;
    v_out := aiq.complete_judgement(v_id, jsonb_build_object('decision', 'relate', 'target', v_a1, 'predicate', 'same_as',
                                    'spans', (select v from sp where k = 'same')),
                                    'B1 "A memory store must keep the time a fact held" says what A1 "Agent memory has to record when each fact became true" says');
    assert v_out->>'status' = 'decided' and v_out->>'tier' = 'agent'
       and v_out->>'decided_by' = 'agent:00000000-0000-4000-8000-0000000659b1', 'decided by B''s agent: ' || v_out::text;
    select * into r from claims.relations where id = (v_out->'relation_ids'->>0)::bigint;
    assert r.predicate = 'same_as' and r.status = 'proposed', 'the relation landed proposed: ' || coalesce(r.status, 'none');
    assert r.src = (select v::uuid from ids where k = 'b1') and r.dst = v_a1::uuid, 'from B''s claim to A''s';
    assert (select actor_kind from claims.tx where id = r.tx) = 'agent', 'asserted as the agent';
    assert (aiq.complete_judgement(v_id, jsonb_build_object('decision', 'relate', 'target', v_a1, 'predicate', 'same_as',
                                   'spans', (select v from sp where k = 'same')), 'again'))->>'already' = 'true',
        'the same verdict again is idempotent';
    insert into ids values ('rel', r.id::text);
end $$;
reset role;

-- 4. Next revisions, the claims unchanged: re-embedded, and an answered pair is not asked again -- B's, answered
--    with a relation, and A's, answered none, which leaves no relation to exclude it.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1", "api_key_id": "00000000-0000-4000-8000-0000000659d1"}';
set local role authenticated;
do $$
declare
    v_c jsonb := aiq.claim_judgement(array['challenge']);
begin
    assert v_c->'evidence'->>'claim_key' = 'P1', 'A''s agent holds the challenge to P1: ' || v_c::text;
    assert (aiq.complete_judgement((v_c->>'id')::uuid, '{"decision": "none"}',
            'P1 is my own private note of A1, and B1 is already answered'))->>'status' = 'decided', 'A''s agent decided none';
    insert into ids values ('rp2', research.revise_package('rp-chal-p', '{"schema_version": "0.1", "title": "Chal A private, retitled", "visibility": "private", "edges": [],
        "claims": [{"id": "P1", "kind": "Inference", "text": "Memory must keep when each fact held, privately noted.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/cp", "origin": "CP"}]}',
        (select label from research.revisions where id = (select v::uuid from ids where k = 'rp')))->>'revision_id');
end $$;
reset role;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659b1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('rb2', research.revise_package('rp-chal-b', '{"schema_version": "0.1", "title": "Chal B", "visibility": "listed", "edges": [],
        "claims": [{"id": "B1", "kind": "Inference", "text": "A memory store must keep the time a fact held.", "source_ids": ["S1"]},
                   {"id": "B2", "kind": "Inference", "text": "Soil bacteria fix nitrogen.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/cb", "origin": "CB"}]}',
        (select label from research.revisions where id = (select v::uuid from ids where k = 'rb')))->>'revision_id');
end $$;
reset role;
reset request.jwt.claims;
set local role worker;
insert into ids select 'drain2', pg_temp.drain('t_chal_659');
reset role;
do $$
begin
    assert (select v from ids where k = 'drain2') = '3', 'the new revisions'' three claims were embedded';
    assert (select count(*) from claims.challenged d join research.claims rc on rc.id = d.claim_row
             where rc.revision_id in (select v::uuid from ids where k in ('rb2', 'rp2')) and d.judgement_id is null) = 3,
        'all three were asked and none challenged: B1''s pair has a relation and P1''s were answered none';
    assert (select count(*) from aiq.judgements where kind = 'challenge') = 2, 'no new challenge';
end $$;

-- 5. No floor, no challenge, and nothing recorded as asked; the floor and the backfill ask it.
select claims.set_challenge_floor('chal-test-3d', null);
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659c1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('rc', research.submit_package('{"schema_version": "0.1", "title": "Chal C", "visibility": "listed", "edges": [],
        "claims": [{"id": "C1", "kind": "Inference", "text": "Memory systems should store when facts were true.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/cc", "origin": "CC"}]}', null, 'rp-chal-c')->>'revision_id');
end $$;
reset role;
reset request.jwt.claims;
set local role worker;
insert into ids select 'drain3', pg_temp.drain('t_chal_659');
reset role;
do $$
declare
    v_rc uuid := (select v::uuid from ids where k = 'rc');
    v_w  jsonb;
begin
    assert (select v from ids where k = 'drain3') = '1', 'C1 was embedded';
    assert not exists (select 1 from claims.challenged d join research.claims rc on rc.id = d.claim_row where rc.revision_id = v_rc),
        'with no floor C1 is not recorded as asked';
    perform claims.set_challenge_floor('chal-test-3d', 0.05, 3);
    v_w := claims.challenge_waiting();
    assert v_w->>'asked' = '1' and v_w->>'waiting' = '1', 'the backfill asks the one waiting: ' || v_w::text;
    assert exists (select 1 from aiq.judgements j where j.kind = 'challenge'
                    and j.addressee = '00000000-0000-4000-8000-0000000659c1'
                    and j.evidence->>'revision_id' = v_rc::text), 'C1''s challenge is put to C';
    assert (claims.challenge_waiting())->>'waiting' = '0', 'and nothing is left';
end $$;

-- 6. agrees with no period on either side.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659b1", "api_key_id": "00000000-0000-4000-8000-0000000659d2"}';
set local role authenticated;
do $$
declare
    ra uuid := (select v::uuid from ids where k = 'ra');
    rb uuid := (select v::uuid from ids where k = 'rb');
    fm jsonb := '{"subject": "same", "outcome": "same", "evidence_type": "same", "population": "unstated", "period": "unstated"}';
    sp jsonb := '{"src": "Agents retrieve better", "dst": "agents answer better"}';
    v  bigint;
    h  text;
begin
    -- Two method claims, no frame on either, compared on the slots: neither states a population or a period.
    v := claims.assert_relation('B4', 'agrees', 'A3', rb, ra, null, sp || jsonb_build_object('frame_match', fm), 'neither states a period');
    assert (select status from claims.relations where id = v) = 'proposed', 'agrees with an unstated period lands proposed';
    begin
        perform claims.assert_relation('B4', 'agrees', 'A3', rb, ra, null,
            sp || jsonb_build_object('frame_match', fm || '{"period": "unknown"}'), 'unchecked');
        raise exception 'agrees with an unknown period was accepted';
    exception when check_violation then
        if sqlerrm not like '%unstated by both%' then raise exception 'the refusal does not name unstated: %', sqlerrm; end if;
    end;
    begin
        perform claims.assert_relation('B4', 'contradicts', 'A3', rb, ra, null,
            sp || jsonb_build_object('frame_match', fm || '{"setting": "same", "comparator": "same"}'), 'opposed');
        raise exception 'contradicts across an unstated period was accepted';
    exception when check_violation then
        -- Refused by the same-question rule, whose hint says what to do instead.
        get stacked diagnostics h = pg_exception_hint;
        if sqlerrm not like 'contradicts needs the same question%' or h not like '%different_scope%' then
            raise exception 'contradicts was refused without saying what to do: % (%)', sqlerrm, h;
        end if;
    end;
    -- B3's frame states a period, so "neither states it" is false.
    begin
        perform claims.assert_relation('B3', 'agrees', 'A3', rb, ra, null,
            jsonb_build_object('src', 'retrieve better', 'dst', 'answer better', 'frame_match', fm), 'unstated?');
        raise exception 'unstated was accepted for a period B3''s frame states';
    exception when check_violation then
        if sqlerrm not like '%unstated that a claim''s frame states%' then raise; end if;
    end;
end $$;
reset role;
reset request.jwt.claims;

rollback;
