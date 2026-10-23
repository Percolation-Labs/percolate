-- THE WRITER'S AGENT SETTLES THE CHALLENGES IT IS SURE OF, AND ONLY THE UNCERTAIN REACH THE PERSON (REM-1123; Sirsh,
-- M-20261021-064032-1c2e). A challenge (research/41) goes to the writer's connected agent; with the deployment's
-- claims.challenge_floors.settle_at set, an answer whose confidence is at or above it settles the challenge -- a
-- relate lands 'settled', a none is recorded settled -- and one below it goes to the person (to_human) with the
-- agent's answer as the suggestion. Who resolved each is claims.challenge_outcomes, and a person's overturn is a
-- later row, never a rewrite. research/41 is the same flow with no settle_at, which is unchanged.
--
-- The checks:
--   1. With settle_at 0.8: B's agent relates B1 same_as A1 at 0.95 and it settles: the relation is 'settled', the
--      agent's, the judgement decided by agent:B and marked settled; a settled same_as counts in the identity set.
--   2. A relation cannot be settled any other way: an agent's assert_relation(..., 'settled') is refused, and a
--      restatement that leaves a relation settled is refused.
--   3. A tier cannot claim more than the caller is: B's agent recording its answer as human is refused, and so is a
--      person recording one as llm.
--   4. A's agent answers P1's challenge at 0.5: it reaches the person, with the answer kept as the suggestion and no
--      relation asserted; a confidence outside 0..1 is refused first. A claims it and decides none, as human; the
--      record keeps the agent's suggestion.
--   5. A's agent decides N1's challenge none at 0.9: settled, no relation.
--   6. Overturns append: B disputes the settled same_as (both rows stay, the dispute is the reading, and A1 leaves
--      B1's identity set), and A relates N1 same_as A1 after the agent said none.
--   (Before 1: a fixture account's claim is not challenged, by the save's pass or the backfill.)
--   7. claims.challenge_outcomes says who resolved each and what was overturned, in one query, and
--      claims.challenge_report gives the backfill's shares: 3 challenges, 2 settled by the agent, 1 reached the
--      person, 2 overturned; a claim's second place adds an occurrence, not a challenge.
--
-- The worker and the stub model are research/41's. One transaction, rolled back.

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

-- A third challenge, to A: N1 is near A1, B1 and P1.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('rn', research.submit_package('{"schema_version": "0.1", "title": "Chal N", "visibility": "listed", "edges": [],
        "claims": [{"id": "N1", "kind": "Inference", "text": "Memory systems must note when each fact held.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/cn", "origin": "CN"}]}', null, 'rp-chal-n')->>'revision_id');
end $$;
reset role;
reset request.jwt.claims;
insert into ids select 'n1', claim_id::text from claims.expresses where revision_id = (select v::uuid from ids where k = 'rn') and claim_key = 'N1';
set local role worker;
select pg_temp.drain('t_chal_659');
reset role;

insert into sp values ('same_n', '{"src": "Memory systems must note when each fact held", "dst": "Agent memory has to record when each fact became true",
    "slots": {"src": {"subject": "agent memory", "predicate": "records", "object": "when a fact held", "scope": "agents", "polarity": "positive", "modality": "normative"},
              "dst": {"subject": "agent memory", "predicate": "records", "object": "when a fact held", "scope": "agents", "polarity": "positive", "modality": "normative"}}}');

-- A fixture account's work is never challenged (REM-659): C is flagged as one, and its private F1 is near A1, which
-- C may read, so C would be asked about it. Neither the save's own pass nor the backfill asks, and the backfill does
-- not keep offering it either.
update rbac.users set fixture = true where id = '00000000-0000-4000-8000-0000000659c1';
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659c1"}';
set local role authenticated;
do $$
begin
    insert into ids values ('rf', research.submit_package('{"schema_version": "0.1", "title": "Chal F", "visibility": "private", "edges": [],
        "claims": [{"id": "F1", "kind": "Inference", "text": "Agent memory must record when each fact became true.", "source_ids": ["S1"]}],
        "sources": [{"id": "S1", "title": "S", "url": "https://example.com/cf", "origin": "CF"}]}', null, 'rp-chal-f')->>'revision_id');
end $$;
reset role;
reset request.jwt.claims;
set local role worker;
select pg_temp.drain('t_chal_659');
reset role;
do $$
declare
    v_wait jsonb := claims.challenge_waiting('chal-test-3d');
begin
    assert not exists (select 1 from aiq.judgements where addressee = '00000000-0000-4000-8000-0000000659c1'),
        'a fixture account is asked nothing: ' || coalesce((select string_agg(evidence::text, '; ') from aiq.judgements
                                                             where addressee = '00000000-0000-4000-8000-0000000659c1'), '');
    assert not exists (select 1 from claims.challenged d join research.claims rc on rc.id = d.claim_row
                        where rc.revision_id = (select v::uuid from ids where k = 'rf')), 'F1 is not recorded as asked';
    assert (v_wait->>'asked')::int = 0 and coalesce((v_wait->>'waiting')::int, 0) = 0,
        'and the backfill neither asks nor keeps offering it: ' || v_wait::text;
end $$;

-- The deployment lets the writer's agent settle at 0.8.
select claims.set_challenge_settle('chal-test-3d', 0.8);
do $$
begin
    assert (select count(*) from aiq.judgements where kind = 'challenge') = 3, 'three challenges: B1, P1 and N1';
    insert into ids select 'jb', id::text from aiq.judgements where kind = 'challenge' and subject_node_id = (select v::uuid from ids where k = 'b1');
    insert into ids select 'jp', id::text from aiq.judgements where kind = 'challenge' and subject_node_id = (select v::uuid from ids where k = 'p1');
    insert into ids select 'jn', id::text from aiq.judgements where kind = 'challenge' and subject_node_id = (select v::uuid from ids where k = 'n1');
    assert (select count(*) from ids where k in ('jb', 'jp', 'jn')) = 3, 'each is found';
end $$;

-- 1, 2, 3. B's agent.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659b1", "api_key_id": "00000000-0000-4000-8000-0000000659d2"}';
set local role authenticated;
do $$
declare
    v_id  uuid := (select v::uuid from ids where k = 'jb');
    v_a1  text := (select v from ids where k = 'a1');
    v_c   jsonb := aiq.claim_judgement(array['challenge'], v_id);
    v_out jsonb;
    r     claims.relations;
begin
    assert v_c->>'how_to_decide' like '%confidence%', 'how_to_decide asks for a confidence: ' || (v_c->>'how_to_decide');
    -- 3: an agent cannot record its answer as the person's.
    begin
        perform aiq.complete_judgement(v_id, jsonb_build_object('decision', 'relate', 'target', v_a1, 'predicate', 'same_as',
                                       'spans', (select v from sp where k = 'same'), 'confidence', 0.95), 'as if I were B', 'human');
        raise exception 'an agent recorded its answer as human';
    exception when insufficient_privilege then
        if sqlerrm not like '%cannot be recorded as human%' then raise; end if;
    end;
    -- 2: a relation is settled only by settling a challenge.
    begin
        perform claims.assert_relation('B1', 'same_as', 'A1', (select v::uuid from ids where k = 'rb'),
                                       (select v::uuid from ids where k = 'ra'), 'settled', (select v from sp where k = 'same'), 'self-settled');
        raise exception 'an agent settled a relation without a challenge';
    exception when insufficient_privilege then
        if sqlerrm not like '%settled only by settling%' then raise; end if;
    end;
    -- 1
    v_out := aiq.complete_judgement(v_id, jsonb_build_object('decision', 'relate', 'target', v_a1, 'predicate', 'same_as',
                                    'spans', (select v from sp where k = 'same'), 'confidence', 0.95),
                                    'B1 says what A1 says, in other words');
    assert v_out->>'status' = 'decided' and v_out->>'decided_by' = 'agent:00000000-0000-4000-8000-0000000659b1'
       and (v_out->'verdict'->>'settled')::boolean, 'settled by B''s agent: ' || v_out::text;
    select * into r from claims.relations where id = (v_out->'relation_ids'->>0)::bigint;
    assert r.predicate = 'same_as' and r.status = 'settled', 'the relation is settled: ' || coalesce(r.status, 'none');
    assert (select actor_kind from claims.tx where id = r.tx) = 'agent', 'as the agent';
    assert v_a1::uuid in (select claims.identity_set((select v::uuid from ids where k = 'b1'))),
        'a settled same_as counts: A1 is in B1''s identity set';
    -- 2: a restatement does not leave it settled.
    begin
        perform claims.restate_relation(r.id, null, false, 'still settled?');
        raise exception 'a restatement left a relation settled';
    exception when check_violation then
        if sqlerrm not like '%says what it becomes%' then raise; end if;
    end;
    insert into ids values ('rel', r.id::text);
end $$;
reset role;

-- 3: a person cannot record a decision as the platform's model.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1"}';
set local role authenticated;
do $$
declare
    v_id uuid := (select v::uuid from ids where k = 'jn');
begin
    perform aiq.claim_judgement(array['challenge'], v_id);
    begin
        perform aiq.complete_judgement(v_id, '{"decision": "none"}', 'as the model', 'llm');
        raise exception 'a person recorded a decision as llm';
    exception when insufficient_privilege then
        if sqlerrm not like '%cannot be recorded as llm%' then raise; end if;
    end;
    perform aiq.release_judgement(v_id);
end $$;
reset role;

-- 4, 5. A's agent.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1", "api_key_id": "00000000-0000-4000-8000-0000000659d1"}';
set local role authenticated;
do $$
declare
    v_jp  uuid := (select v::uuid from ids where k = 'jp');
    v_jn  uuid := (select v::uuid from ids where k = 'jn');
    v_a1  text := (select v from ids where k = 'a1');
    v_out jsonb;
    v_n   int := (select count(*) from claims.relations);
begin
    perform aiq.claim_judgement(array['challenge'], v_jp);
    begin
        perform aiq.complete_judgement(v_jp, jsonb_build_object('decision', 'relate', 'target', v_a1, 'predicate', 'same_as',
                                       'spans', (select v from sp where k = 'same'), 'confidence', 1.5), 'very sure');
        raise exception 'a confidence of 1.5 was accepted';
    exception when check_violation then
        if sqlerrm not like '%0 to 1%' then raise; end if;
    end;
    v_out := aiq.complete_judgement(v_jp, jsonb_build_object('decision', 'relate', 'target', v_a1, 'predicate', 'same_as',
                                    'spans', (select v from sp where k = 'same'), 'confidence', 0.5),
                                    'P1 may be my note of A1, but it says privately');
    assert v_out->>'status' = 'to_human', '0.5 is below 0.8, so it reaches the person: ' || v_out::text;
    assert (select count(*) from claims.relations) = v_n, 'and no relation was asserted';
    assert (select verdict->'suggested'->>'confidence' from aiq.judgements where id = v_jp) = '0.5'
       and (select verdict->>'suggested_by' from aiq.judgements where id = v_jp) = 'agent:00000000-0000-4000-8000-0000000659a1',
        'the agent''s answer is kept as the suggestion';
    -- 5
    perform aiq.claim_judgement(array['challenge'], v_jn);
    v_out := aiq.complete_judgement(v_jn, '{"decision": "none", "confidence": 0.9}', 'N1 is not what any candidate says');
    assert v_out->>'status' = 'decided' and (v_out->'verdict'->>'settled')::boolean, 'a sure none settles: ' || v_out::text;
    assert (select count(*) from claims.relations) = v_n, 'and asserts nothing';
end $$;
reset role;

-- 4 and 6, as A the person: decide what reached them, and overturn the agent's none.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659a1"}';
set local role authenticated;
do $$
declare
    v_jp  uuid := (select v::uuid from ids where k = 'jp');
    v_out jsonb;
begin
    perform aiq.claim_judgement(array['challenge'], v_jp);
    v_out := aiq.complete_judgement(v_jp, '{"decision": "none"}', 'P1 is my private note; leave it apart', 'human');
    assert v_out->>'status' = 'decided' and v_out->>'decided_by' = 'user:00000000-0000-4000-8000-0000000659a1',
        'decided by A herself: ' || v_out::text;
    assert v_out->'verdict'->'suggested'->>'decision' = 'relate', 'the record keeps the agent''s suggestion';
    perform claims.assert_relation('N1', 'same_as', 'A1', (select v::uuid from ids where k = 'rn'),
                                   (select v::uuid from ids where k = 'ra'), null, (select v from sp where k = 'same_n'),
                                   'N1 restates A1 after all');
end $$;
reset role;

-- 6, as B the person: dispute the settled same_as.
set local request.jwt.claims = '{"sub": "00000000-0000-4000-8000-0000000659b1"}';
set local role authenticated;
do $$
declare
    v_rel bigint := (select v::bigint from ids where k = 'rel');
    r     claims.relations;
begin
    perform claims.restate_relation(v_rel, 'disputed', false, 'B1 is about a store, A1 about agents');
    select * into r from claims.relations where id = v_rel;
    assert r.status = 'settled', 'the settled row stands in the history';
    assert (select count(*) from claims.relations x where x.src = r.src and x.dst = r.dst and x.predicate = r.predicate) = 2,
        'and the dispute is a second row';
    assert (select r2.status from claims.relations_at(r.src) r2 where r2.dst = r.dst and r2.predicate = 'same_as') = 'disputed',
        'the person''s later row is the reading';
    assert (select v::uuid from ids where k = 'a1') not in (select claims.identity_set(r.src)),
        'and A1 leaves B1''s identity set';
end $$;
reset role;
reset request.jwt.claims;

-- 7. Who resolved each, and the backfill's shares. A claim stated in a second place joins its open judgement rather
-- than opening another, so it adds a claims.challenged row and no judgement: here, the row challenge_embedded writes for
-- that second place, against B1's judgement. The report counts judgements, and the places apart.
insert into research.claims (id, revision_id, claim_key, kind, text)
values ('00000000-0000-4000-8000-00000065900b', (select v::uuid from ids where k = 'rn'), 'B1-again', 'Inference',
        'A memory store must keep the time a fact held.');
insert into claims.challenged (claim_row, model, candidates, judgement_id)
values ('00000000-0000-4000-8000-00000065900b', 'chal-test-3d', 1, (select v::uuid from ids where k = 'jb'));
do $$
declare
    v_rep jsonb := claims.challenge_report('chal-test-3d');
begin
    assert not exists (select 1 from claims.settling), 'each settling ended with the call that settled it';
    -- B1's judgement has a row per place it is stated, two since the second place above, and each says the same.
    assert (select array_agg(distinct resolved_by) from claims.challenge_outcomes
             where judgement_id = (select v::uuid from ids where k = 'jb'))
           = array['agent:00000000-0000-4000-8000-0000000659b1'], 'B1: the agent';
    assert (select count(*) = 2 and bool_and(settled and overturned_by = 'user:00000000-0000-4000-8000-0000000659b1')
              from claims.challenge_outcomes where judgement_id = (select v::uuid from ids where k = 'jb')),
        'B1: settled, overturned by B, in both places';
    assert (select resolved_by = 'user:00000000-0000-4000-8000-0000000659a1' and suggested_by_agent and not settled
              from claims.challenge_outcomes where judgement_id = (select v::uuid from ids where k = 'jp')),
        'P1: the person, on the agent''s suggestion';
    assert (select settled and decision = 'none' and overturned_by = 'user:00000000-0000-4000-8000-0000000659a1'
              from claims.challenge_outcomes where judgement_id = (select v::uuid from ids where k = 'jn')),
        'N1: settled none, overturned by A''s relate';
    assert (v_rep->>'challenges')::int = 3 and (v_rep->>'occurrences')::int = 4 and (v_rep->>'settled_by_agent')::int = 2
       and (v_rep->>'reached_the_person')::int = 1 and (v_rep->>'overturned')::int = 2
       and (v_rep->>'still_waiting')::int = 0, 'the report: ' || v_rep::text;
end $$;

-- A fixture's challenges leave the report even when they were asked before it was flagged (REM-659): with A
-- flagged, P1, N1 and B1's second place (all A's) go, and only B1 in B's own work is left.
update rbac.users set fixture = true where id = '00000000-0000-4000-8000-0000000659a1';
do $$
declare
    v_rep jsonb := claims.challenge_report('chal-test-3d');
begin
    assert (v_rep->>'challenges')::int = 1 and (v_rep->>'occurrences')::int = 1, 'a fixture''s are not counted: ' || v_rep::text;
end $$;

rollback;
